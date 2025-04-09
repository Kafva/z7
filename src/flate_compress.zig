const std = @import("std");
const log = @import("log.zig");
const util = @import("util.zig");

const Flate = @import("flate.zig").Flate;
const FlateBlockType = @import("flate.zig").FlateBlockType;
const FlateError = @import("flate.zig").FlateError;
const Token = @import("flate.zig").Token;
const TokenEncoding = @import("flate.zig").TokenEncoding;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;

const CompressContext = struct {
    allocator: std.mem.Allocator,
    crc: *std.hash.Crc32,
    /// The current type of block to write
    block_type: FlateBlockType,
    bit_writer: std.io.BitWriter(Flate.writer_endian, std.io.AnyWriter),
    reader: std.io.AnyReader,
    written_bits: usize,
    processed_bits: usize,
    sliding_window: RingBuffer(u8),
    lookahead: []u8,
};

pub fn compress(
    allocator: std.mem.Allocator,
    instream: *const std.fs.File,
    outstream: *const std.fs.File,
    crc: *std.hash.Crc32,
) !void {
    var ctx = CompressContext {
        .allocator = allocator,
        .crc = crc,
        .block_type = FlateBlockType.FIXED_HUFFMAN,
        .bit_writer = std.io.bitWriter(Flate.writer_endian, outstream.writer().any()),
        .reader = instream.reader().any(),
        .written_bits = 0,
        .processed_bits = 0,
        // Initialize sliding window for backreferences
        .sliding_window = try RingBuffer(u8).init(allocator, Flate.window_length),
        .lookahead = try allocator.alloc(u8, Flate.lookahead_length),
    };

    const st = try instream.stat();
    const insize: u16 = @truncate(st.size);

    // Write block header
    var header: u3 = 0;
    header |= @intFromEnum(ctx.block_type) << 1; // BTYPE
    header |= 1; // BFINAL

    try write_bits(&ctx, u3, header, 3);

    log.debug(@src(), "Writing type-{d} block", .{@intFromEnum(ctx.block_type)});
    switch (ctx.block_type) {
        FlateBlockType.NO_COMPRESSION => {
            try no_compression_compress_block(&ctx, insize);
        },
        FlateBlockType.FIXED_HUFFMAN => {
            try fixed_code_compress_block(&ctx, insize);
        },
        FlateBlockType.DYNAMIC_HUFFMAN => {
            try dynamic_code_compress_block(&ctx, insize);
        },
        else => unreachable
    }

    // Incomplete bytes will be padded when flushing, wait until all
    // writes are done.
    try ctx.bit_writer.flushBits();
    log.debug(
        @src(),
        "Compression done: {} [{} bytes] -> {} bits [{} bytes]",
        .{ctx.processed_bits, ctx.processed_bits / 8,
          ctx.written_bits, ctx.written_bits / 8}
    );
}

fn no_compression_compress_block(ctx: *CompressContext, length: u16) !void {
    // Fill up with zeroes to the next byte boundary
    try write_bits(ctx, u5, 0, 5);
    try write_bits(ctx, u16, length, 16);
    try write_bits(ctx, u16, ~length, 16);

    log.debug(@src(), "Compressing {d} bytes into type-0 block", .{length});
    for (0..length) |_| {
        const b = read_byte(ctx) catch {
            return FlateError.UnexpectedEof;
        };
        ctx.sliding_window.push(b);
        try write_bits(ctx, u8, b, 8);
    }
}

fn fixed_code_compress_block(ctx: *CompressContext, block_length: usize) !void {
    const end: usize = ctx.processed_bits + block_length*8;
    var done = false;
    ctx.lookahead[0] = blk: {
        break :blk read_byte(ctx) catch {
            done = true;
            break :blk 0;
        };
    };

    while (!done and ctx.processed_bits - 1 < end) {
        // The current number of matches within the lookahead
        var match_length: u16 = 0;
        // Max number of matches in the lookahead this iteration
        // XXX: The byte at the `longest_match_length` index is not part
        // of the match!
        var longest_match_length: u16 = 0;
        var longest_match_distance: u16 = 0;

        // Look for matches in the sliding_window
        const window_length: u16 = @truncate(ctx.sliding_window.len());
        var ring_offset: u16 = 0;

        while (ring_offset != window_length) {
            const ring_byte: u8 = try ctx.sliding_window.read_offset_start(@as(i32, ring_offset));
            if (ctx.lookahead[match_length] != ring_byte) {
                // Reset and start matching from the beginning of the
                // lookahead again
                //
                // Try the same index in the sliding_window again
                // if we had found a partial match, otherwise move on
                if (match_length == 0) {
                    ring_offset += 1;
                }

                match_length = 0;
                continue;
            }

            ring_offset += 1;
            match_length += 1;

            // When `match_cnt` exceeds `longest_match_cant` we
            // need to feed another byte into the lookahead.
            if (match_length <= longest_match_length) {
                continue;
            }

            // Update the longest match
            longest_match_length = match_length;
            longest_match_distance = (window_length - (ring_offset-1)) + match_length;

            if (longest_match_length == window_length) {
                // Matched entire lookahead
                break;
            }
            else if (longest_match_length == Flate.lookahead_length - 1) {
                // Longest supported match
                break;
            }

            ctx.lookahead[longest_match_length] = read_byte(ctx) catch {
                done = true;
                break;
            };
            log.debug(
                @src(),
                "Extending lookahead {d} item(s)",
                .{longest_match_length}
            );
        }

        const lookahead_end = if (longest_match_length == 0) 1
                              else longest_match_length;
        // Update the sliding window with the characters from the lookahead
        for (0..lookahead_end) |i| {
            ctx.sliding_window.push(ctx.lookahead[i]);
        }

        // Write the compressed representation of the lookahead characters
        // onto the output stream
        try fixed_code_write_match(
            ctx,
            lookahead_end,
            longest_match_length,
            longest_match_distance,
        );

        // Set starting byte for next iteration
        if (longest_match_length == 0 or
            longest_match_length == window_length or
            longest_match_length == Flate.lookahead_length - 1
        ) {
            // We need a new byte
            ctx.lookahead[0] = read_byte(ctx) catch {
                done = true;
                break;
            };
        } else {
            // The final char from the lookahead should be passed to
            // the next iteration
            util.print_char(
                "Pushing to next iteration",
                ctx.lookahead[longest_match_length]
            );
            ctx.lookahead[0] = ctx.lookahead[longest_match_length];
        }
    }

    // End-of-block marker (with static Huffman encoding: 0000_000 -> 256)
    try write_bits(ctx, u7, @as(u7, 0), 7);
}

fn dynamic_code_compress_block(ctx: *CompressContext, block_length: usize) !void {
    _ = ctx;
    _ = block_length;
}

/// Write the bits for the provided match length and distance to the output
/// stream.
fn fixed_code_write_match(
    ctx: *CompressContext,
    lookahead_end: u16,
    longest_match_length: u16,
    longest_match_distance: u16,
) !void {
    if (longest_match_length <= Flate.min_length_match) {
        // Prefer raw characters for small matches
        for (0..lookahead_end) |i| {
            const char = ctx.lookahead[i];
            // Lit Value    Bits        Codes
            // ---------    ----        -----
            //   0 - 143     8          00110000 through
            //                          10111111
            // 144 - 255     9          110010000 through
            //                          111111111
            if (char < 144) {
                try write_bits_be(ctx, u8, 0b0011_0000 + char, 8);
            }
            else {
                const char_9: u9 = 0b1_1001_0000 + @as(u9, char - 144);
                try write_bits_be(ctx, u9, char_9, 9);
            }
        }
    }
    else {
        // Lookup the encoding for the token length
        const enc = TokenEncoding.from_length(longest_match_length);
        log.debug(@src(), "backref(length): {any} ({d})", .{enc, longest_match_length});

        if (enc.code < 256 or enc.code > 285) {
            return FlateError.InvalidLiteralLength;
        }

        // Translate the length to the corresponding code
        //
        // 256 - 279     7          000_0000 through
        //                          001_0111
        // 280 - 287     8          1100_0000 through
        //                          1100_0111
        if (enc.code < 280) {
            // Write the huffman encoding of 'Code'
            const hcode: u7 = @truncate(enc.code - 256);
            try write_bits_be(ctx, u7, 0b000_0000 + hcode, 7);
        }
        else {
            const hcode: u8 = @truncate(enc.code - 280);
            try write_bits_be(ctx, u8, 0b1100_0000 + hcode, 8);
        }

        // Write the 'Extra Bits', i.e. the offset that indicate
        // the exact offset to use in the range.
        if (enc.code != 0) {
            const offset = longest_match_length - enc.range_start;
            try write_bits(
                ctx,
                u16,
                offset,
                enc.bit_count
            );
            log.debug(@src(), "backref(length-offset): {d}", .{offset});
        }

        // Write the 'Distance' encoding
        const denc = TokenEncoding.from_distance(longest_match_distance);
        log.debug(@src(), "backref(distance): {any} ({d})", .{denc, longest_match_distance});
        const denc_code: u5 = @truncate(denc.code);
        try write_bits_be(ctx, u5, denc_code, 5);

        // Write the offset bits for the distance
        if (denc.bit_count != 0) {
            const offset = longest_match_distance - denc.range_start;
            try write_bits(
                ctx,
                u16,
                offset,
                denc.bit_count
            );
            log.debug(@src(), "backref(distance-offset): {d}", .{offset});
        }
    }
}

/// Write bits with the configured bit-ordering
fn write_bits(
    ctx: *CompressContext,
    T: type,
    value: T,
    num_bits: u16,
) !void {
    try ctx.bit_writer.writeBits(value, num_bits);
    const offset = @divFloor(ctx.processed_bits, 8);
    util.print_bits(T, "Output write", value, num_bits, offset);
    ctx.written_bits += num_bits;
}

/// Write bits with the configured little-endian writer *BUT* write the bits
/// of `value` in the most-to-least-significant order.
///
/// 0b0111_1000 should be written as 11110xxx xxxxx000 to the output stream.
fn write_bits_be(
    ctx: *CompressContext,
    comptime T: type,
    value: T,
    num_bits: u16,
) !void {
    const V = switch (T) {
        u9 => u4,
        else => u3,
    };
    for (1..num_bits) |i_usize| {
        const i: V = @intCast(i_usize);
        const shift_by: V = @intCast(num_bits - i);

        const bit: u1 = @truncate((value >> shift_by) & 1);
        try write_bits(ctx, u1, bit, 1);
    }

    // Final least-significant bit
    const bit: u1 = @truncate(value & 1);
    try write_bits(ctx, u1, bit, 1);
}

fn read_byte(ctx: *CompressContext) !u8 {
    const b = try ctx.reader.readByte();
    util.print_char("Input read", b);
    ctx.processed_bits += 8;

    // The final crc should be the crc of the entire input file, update
    // it incrementally as we process each byte.
    const bytearr = [1]u8 { b };
    ctx.crc.update(&bytearr);

    return b;
}
