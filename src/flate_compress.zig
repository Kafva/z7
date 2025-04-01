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
    /// The current type of block to write
    block_type: FlateBlockType,
    bit_writer: std.io.BitWriter(Flate.writer_endian, std.io.AnyWriter),
    reader: std.io.AnyReader,
    written_bits: usize,
    processed_bits: usize,
    sliding_window: RingBuffer(u8),
    lookahead: []u8,
};

pub const Compress = struct {
    pub fn compress(
        allocator: std.mem.Allocator,
        instream: std.fs.File,
        outstream: std.fs.File,
    ) !void {
        var ctx = CompressContext {
            .allocator = allocator,
            .block_type = FlateBlockType.FIXED_HUFFMAN,
            // XXX: Big-endian order bits need to be manually converted
            .bit_writer = std.io.bitWriter(Flate.writer_endian, outstream.writer().any()),
            .reader = instream.reader().any(),
            .written_bits = 0,
            .processed_bits = 0,
            // Initialize sliding window for backreferences
            .sliding_window = try RingBuffer(u8).init(allocator, Flate.window_length),
            .lookahead = try allocator.alloc(u8, Flate.lookahead_length),
        };

        // Write block header
        try Compress.write_bits(u1, &ctx, @as(u1, 1), 1); // XXX bfinal
        try Compress.write_bits(u2, &ctx, @as(u2, @intFromEnum(ctx.block_type)), 2);
        try Compress.write_bits(u5, &ctx, @as(u5, 0), 5);

        switch (ctx.block_type) {
            FlateBlockType.NO_COMPRESSION => {
                return FlateError.NotImplemented;
            },
            FlateBlockType.FIXED_HUFFMAN => {
                // Encode the token according to the static huffman code
                try Compress.fixed_code_compress_block(&ctx);
            },
            FlateBlockType.DYNAMIC_HUFFMAN => {
                return FlateError.NotImplemented;
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

    pub fn fixed_code_compress_block(
        ctx: *CompressContext,
    ) !void {
        var done = false;
        ctx.lookahead[0] = blk: {
            break :blk Compress.read_byte(ctx) catch {
                done = true;
                break :blk 0;
            };
        };

        while (!done) {
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
                longest_match_distance = (window_length - (ring_offset-1)) + (match_length - 1);

                if (longest_match_length == window_length) {
                    // Matched entire lookahead
                    break;
                }
                else if (longest_match_length == Flate.lookahead_length - 1) {
                    // Longest supported match
                    break;
                }

                ctx.lookahead[longest_match_length] = Compress.read_byte(ctx) catch {
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
            try Compress.fixed_code_write_match(
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
                ctx.lookahead[0] = Compress.read_byte(ctx) catch {
                    done = true;
                    break;
                };
            } else {
                // The final char from the lookahead should be passed to
                // the next iteration
                log.debug(
                    @src(),
                    "Pushing '{c}' to next iteration",
                    .{ctx.lookahead[longest_match_length]}
                );
                ctx.lookahead[0] = ctx.lookahead[longest_match_length];
            }
        }

        // End-of-block marker (with static huffman encoding: 0000_000 -> 256)
        try Compress.write_bits(u7, ctx, @as(u7, 0), 7);
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
                    try Compress.write_bits(u8, ctx, 0b0011_0000 + char, 8);
                }
                else {
                    const char_9: u9 = 0b1_1001_0000 + @as(u9, char - 144);
                    try Compress.write_bits(u9, ctx, char_9, 9);
                }
            }
        }
        else {
            // Lookup the encoding for the token length
            const enc = TokenEncoding.from_length(longest_match_length);
            log.debug(@src(), "backref(length): {any}", .{enc});

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
                try Compress.write_bits(u7, ctx, 0b000_0000 + hcode, 7);
            }
            else {
                const hcode: u8 = @truncate(enc.code - 280);
                try Compress.write_bits(u8, ctx, 0b1100_0000 + hcode, 8);
            }

            // Write the 'Extra Bits', i.e. the offset that indicate
            // the exact offset to use in the range.
            if (enc.code != 0) {
                const offset = longest_match_length - enc.range_start;
                try Compress.write_bits(
                    u16,
                    ctx,
                    offset,
                    enc.bit_count
                );
                log.debug(@src(), "backref(length-offset): {d}", .{offset});
            }

            // Write the 'Distance' encoding
            const denc = TokenEncoding.from_distance(longest_match_distance);
            log.debug(@src(), "backref(distance): {any}", .{denc});
            const denc_code: u5 = @truncate(denc.code);
            try Compress.write_bits(u5, ctx, denc_code, 5);

            // Write the offset bits for the distance
            if (denc.bit_count != 0) {
                const offset = longest_match_distance - denc.range_start;
                try Compress.write_bits(
                    u16,
                    ctx,
                    offset,
                    denc.bit_count
                );
                log.debug(@src(), "backref(distance-offset): {d}", .{offset});
            }

            // for (0..longest_match_length) |i| {
            //     const offset: i32 = @intCast(longest_match_distance + i);
            //     const c: u8 = try ctx.sliding_window.read_offset_end(offset);
            //     log.debug(@src(), "backref[{}]: '{c}'", .{i, c});
            // }
        }
    }

    fn write_bits(
        T: type,
        ctx: *CompressContext,
        value: T,
        num_bits: u16,
    ) !void {
        try ctx.bit_writer.writeBits(value, num_bits);
        util.print_bits(T, "Output write", value, num_bits);
        ctx.written_bits += num_bits;
    }

    fn read_byte(ctx: *CompressContext) !u8 {
        const b = try ctx.reader.readByte();

        ctx.processed_bits += 8;

        if (std.ascii.isPrint(b) and b != '\n') {
            log.debug(@src(), "Input read: '{c}'", .{b});
        } else {
            log.debug(@src(), "Input read: '0x{x}'", .{b});
        }

        return b;
    }
};

