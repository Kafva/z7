const std = @import("std");
const log = @import("log.zig");
const util = @import("util.zig");

const Flate = @import("flate.zig").Flate;
const FlateBlockType = @import("flate.zig").FlateBlockType;
const FlateError = @import("flate.zig").FlateError;
const FlateSymbol = @import("flate.zig").FlateSymbol;
const Token = @import("flate.zig").Token;
const RangeSymbol = @import("flate.zig").RangeSymbol;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;
const HuffmanEncoding = @import("huffman.zig").HuffmanEncoding;
const huffman_build_encoding = @import("huffman_compress.zig").build_encoding;

const symbol_max: usize = 286;
const block_length_max: usize = Flate.window_length;

const CompressContext = struct {
    allocator: std.mem.Allocator,
    crc: *std.hash.Crc32,
    /// The current type of block to write
    block_type: FlateBlockType,
    bit_writer: std.io.BitWriter(Flate.writer_endian, std.io.AnyWriter),
    reader: std.io.AnyReader,
    written_bits: usize,
    processed_bits: usize,
    /// Left over input byte to use from previous block
    next_byte: ?u8,
    sliding_window: RingBuffer(u8),
    lookahead: []u8,
    /// Queue of symbols to write to the output stream, we need to keep this
    /// in memory so that we can create huffman trees for these symbols in
    /// block type-2.
    write_queue: []FlateSymbol,
    write_queue_index: usize,
    /// Literal/Length Huffman encoding mappings for block type-2
    ll_enc_map: []?HuffmanEncoding,
    /// Distance Huffman encoding mappings for block type-2
    d_enc_map: []?HuffmanEncoding,
};

pub const FlateCompressMode = enum {
	NoCompression,
	BestSpeed,   
	BestCompression,
};

pub fn compress(
    allocator: std.mem.Allocator,
    instream: *const std.fs.File,
    outstream: *const std.fs.File,
    mode: FlateCompressMode,
    crc: *std.hash.Crc32,
) !void {
    var ctx = CompressContext {
        .allocator = allocator,
        .crc = crc,
        .block_type = FlateBlockType.RESERVED,
        .bit_writer = std.io.bitWriter(Flate.writer_endian, outstream.writer().any()),
        .reader = instream.reader().any(),
        .written_bits = 0,
        .processed_bits = 0,
        .next_byte = null,
        // Initialize sliding window for backreferences
        .sliding_window = try RingBuffer(u8).init(allocator, Flate.window_length),
        .lookahead = try allocator.alloc(u8, Flate.lookahead_length),
        .write_queue = try allocator.alloc(FlateSymbol, block_length_max),
        .write_queue_index = 0,
        .ll_enc_map = try allocator.alloc(?HuffmanEncoding, symbol_max),
        .d_enc_map = try allocator.alloc(?HuffmanEncoding, 31),
    };

    switch (mode) {
        .NoCompression => ctx.block_type = FlateBlockType.NO_COMPRESSION,
        .BestCompression => ctx.block_type = FlateBlockType.FIXED_HUFFMAN,
        .BestSpeed => ctx.block_type = FlateBlockType.FIXED_HUFFMAN,
    }

    var done = false;
    while (!done) {
        // Always use `window_length` as the block length to ensure that type-0
        // blocks can be generated.
        done = try write_block(&ctx, Flate.window_length);
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

/// Go over `block_length` bytes in the input stream with lzss and store
/// the resulting `FlateSymbol` objects into the write queue.
fn lzss(ctx: *CompressContext, block_length: usize) !bool {
    const start: usize = ctx.processed_bits * 8;
    const end: usize = ctx.processed_bits + block_length*8;
    var done = false;
    ctx.lookahead[0] = blk: {
        if (ctx.next_byte) |b| {
            ctx.next_byte = null;
            break :blk b;
        }
        break :blk read_byte(ctx) catch {
            done = true;
            break :blk 0;
        };
    };

    while (!done and ctx.processed_bits < end) {
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

        // Save the symbols for the characters in the lookahead
        try queue_symbol(
            ctx,
            lookahead_end,
            longest_match_length,
            longest_match_distance
        );

        // Set starting byte for next iteration
        if (longest_match_length == 0 or
            longest_match_length == window_length or
            longest_match_length == Flate.lookahead_length - 1) {
            // We need a new byte
            ctx.lookahead[0] = read_byte(ctx) catch {
                done = true;
                break;
            };
        }
        else {
            // The final char from the lookahead should be passed to
            // the next iteration.
            util.print_char(
                "Pushing to next iteration",
                ctx.lookahead[longest_match_length]
            );
            ctx.lookahead[0] = ctx.lookahead[longest_match_length];
        }
    }

    // Save starting byte for next block
    log.debug(
        @src(),
        "Done processing input for new block [{}+{} bytes]",
        .{start, block_length}
    );
    util.print_char("Saving for next block", ctx.lookahead[0]);
    ctx.next_byte = ctx.lookahead[0];

    return done;
}

fn write_block(ctx: *CompressContext, block_length: usize) !bool {
    // Populate the write_queue
    const done = try lzss(ctx, block_length);

    // TODO: analyze write queue and decide which type to use

    log.debug(
        @src(),
        "Writing type-{d} block{s}",
        .{@intFromEnum(ctx.block_type), if (done) " (final)" else ""}
    );

    // Write block header
    var header: u3 = 0;
    header |= @intFromEnum(ctx.block_type) << 1; // BTYPE
    header |= @intFromBool(done);                // BFINAL
    try write_bits(ctx, u3, header, 3);

    // Encode everything from the write queue onto the output stream
    switch (ctx.block_type) {
        FlateBlockType.NO_COMPRESSION => {
            if (block_length > Flate.window_length) {
                return FlateError.InvalidBlockLength;
            }
            // Fill up with zeroes to the next byte boundary
            while (ctx.written_bits % 8 != 0) {
                try write_bits(ctx, u1, 0, 1);
            }
            // Write length header
            const len: u16 = @truncate(block_length);
            try write_bits(ctx, u16, len, 16);
            try write_bits(ctx, u16, ~len, 16);
            // Write the uncompressed content from the write_queue
            try no_compression_dequeue_symbols(ctx);
        },
        FlateBlockType.FIXED_HUFFMAN => {
            for (0..ctx.write_queue_index) |i| {
                try fixed_code_write_symbol(ctx, ctx.write_queue[i]);
            }
        },
        FlateBlockType.DYNAMIC_HUFFMAN => {
            // Generate `ll_enc_map` and `d_enc_map` based on the current
            // `write_queue` content.
            try dynamic_huffman_code_gen(ctx);
            // TODO: write dynamic block header
            // TODO: write encoded ll_enc_map and d_enc_map

            for (0..ctx.write_queue_index) |i| {
                try dynamic_code_write_symbol(ctx, ctx.write_queue[i]);
            }
        },
        FlateBlockType.RESERVED => {
            return FlateError.UnexpectedBlockType;
        }
    }
    ctx.write_queue_index = 0;

    // Write end-of-block marker
    try write_bits(ctx, u7, @as(u7, 0), 7);
    return done;
}

fn queue_symbol(
    ctx: *CompressContext,
    lookahead_end: u16,
    longest_match_length: u16,
    longest_match_distance: u16,
) !void {
    if (longest_match_length <= Flate.min_length_match) {
        // Prefer raw characters for small matches
        for (0..lookahead_end) |i| {
            if (ctx.write_queue_index + 1 >= block_length_max) {
                return FlateError.OutOfQueueSpace;
            }
            const symbol = FlateSymbol { .char = ctx.lookahead[i] };
            ctx.write_queue[ctx.write_queue_index] = symbol;
            ctx.write_queue_index += 1;
        }
    }
    else {
        if (ctx.write_queue_index + 2 >= block_length_max) {
            return FlateError.OutOfQueueSpace;
        }

        // Add the length symbol for the back-reference
        const lenc = RangeSymbol.from_length(longest_match_length);
        const lsymbol = FlateSymbol { .length = lenc };
        ctx.write_queue[ctx.write_queue_index] = lsymbol;
        ctx.write_queue_index += 1;

        // Add the distance symbol for the back-reference
        const denc = RangeSymbol.from_distance(longest_match_distance);
        const dsymbol = FlateSymbol { .distance = denc };
        ctx.write_queue[ctx.write_queue_index] = dsymbol;
        ctx.write_queue_index += 1;
    }
}

fn dynamic_huffman_code_gen(ctx: *CompressContext) !void {
    var ll_freq = try ctx.allocator.alloc(usize, 286);
    var d_freq = try ctx.allocator.alloc(usize, 31);
    var ll_cnt: usize = 0;
    var d_cnt: usize = 0;
    @memset(ll_freq, 0);
    @memset(d_freq, 0);

    // Calculate the frequency of each `FlateSymbol`
    for (0..ctx.write_queue_index) |i| {
        const sym = ctx.write_queue[i];
        switch (sym) {
            .length => {
                if (sym.length.value) |v| {
                    if (ll_freq[v] == 0) {
                        ll_cnt += 1;
                    }
                    ll_freq[v] += 1;
                }
            },
            .distance => {
                if (sym.distance.value) |v| {
                    if (d_freq[v] == 0) {
                        d_cnt += 1;
                    }
                    d_freq[v] += 1;
                }
            },
            .char => {
                if (ll_freq[sym.char] == 0) {
                    ll_cnt += 1;
                }
                ll_freq[sym.char] += 1;
            }
        }
    }

    try huffman_build_encoding(ctx.allocator, &ctx.ll_enc_map, ll_freq, ll_cnt);
    try huffman_build_encoding(ctx.allocator, &ctx.d_enc_map, d_freq, d_cnt);
}

fn dynamic_code_write_symbol(ctx: *CompressContext, sym: FlateSymbol) !void {
    const enc: ?HuffmanEncoding = blk: {
        switch (sym) {
            .length => {
                break :blk ctx.ll_enc_map[sym.length.value.?];
            },
            .distance => {
                break :blk ctx.d_enc_map[sym.distance.value.?];
            },
            .char => {
                break :blk ctx.ll_enc_map[@intCast(sym.char)];
            },
        }
    };

    // Write the encoded symbol
    if (enc) |v| {
        if (v.bit_shift == 9) {
            try write_bits_be(ctx, u9, @truncate(v.bits), v.bit_shift);
        }
        else if (v.bit_shift <= 8) {
            try write_bits_be(ctx, u8, @truncate(v.bits), v.bit_shift);
        }
        else unreachable;
    } else {
        return FlateError.InvalidSymbol;
    }

    // Write the offset bits
    switch (sym) {
        .length => {
            if (sym.length.code != 0) {
                const offset = sym.length.value.? - sym.length.range_start;
                try write_bits(
                    ctx,
                    u16,
                    offset,
                    sym.length.bit_count
                );
                log.debug(@src(), "backref(length-offset): {d}", .{offset});
            }
        },
        .distance => {
            if (sym.distance.bit_count != 0) {
                const offset = sym.distance.value.? - sym.distance.range_start;
                try write_bits(
                    ctx,
                    u16,
                    offset,
                    sym.distance.bit_count
                );
                log.debug(@src(), "backref(distance-offset): {d}", .{offset});
            }
        },
        else => {}
    }
}

/// Write the bits for the provided match length and distance to the output
/// stream.
fn no_compression_dequeue_symbols(ctx: *CompressContext) !void {
    var length: u16 = 0;
    for (0..ctx.write_queue_index) |i| {
        const sym = ctx.write_queue[i];
        switch (sym) {
            .char => {
                try write_bits(ctx, u8, sym.char, 8);
            },
            .length => {
                length = sym.length.value.?;
            },
            .distance => {
                // Write the `length` number of symbols at the provided
                // distance back into the `sliding_window`
                // This is basically type-01 decompression.
                if (length == 0) {
                    return FlateError.InvalidLength;
                }
                const distance = sym.distance.value.?;
                for (0..length) |_| {
                    // use the base offset that was present when this match was found
                    const offset: i32 = @intCast((ctx.write_queue_index - i) + distance - 1);
                    const c: u8 = try ctx.sliding_window.read_offset_end(offset);
                    try write_bits(ctx, u8, c, 8);
                }
            },
        }
    }
}

/// Write the bits for the provided match length and distance to the output
/// stream.
fn fixed_code_write_symbol(ctx: *CompressContext, sym: FlateSymbol) !void {
    switch (sym) {
        .char => {
            // Lit Value    Bits        Codes
            // ---------    ----        -----
            //   0 - 143     8          00110000 through
            //                          10111111
            // 144 - 255     9          110010000 through
            //                          111111111
            if (sym.char < 144) {
                try write_bits_be(ctx, u8, 0b0011_0000 + sym.char, 8);
            }
            else {
                const char_9: u9 = 0b1_1001_0000 + @as(u9, sym.char - 144);
                try write_bits_be(ctx, u9, char_9, 9);
            }
        },
        .length => {
            // Translate the length to the corresponding code
            //
            // 256 - 279     7          000_0000 through
            //                          001_0111
            // 280 - 287     8          1100_0000 through
            //                          1100_0111
            if (sym.length.code < 280) {
                // Write the Huffman encoding of 'Code'
                const hcode: u7 = @truncate(sym.length.code - 256);
                try write_bits_be(ctx, u7, 0b000_0000 + hcode, 7);
            }
            else {
                const hcode: u8 = @truncate(sym.length.code - 280);
                try write_bits_be(ctx, u8, 0b1100_0000 + hcode, 8);
            }
            log.debug(@src(), "backref(length): {any}", .{sym.length});

            // Write the 'Extra Bits', i.e. the offset that indicate
            // the exact offset to use in the range.
            if (sym.length.code != 0) {
                const offset = sym.length.value.? - sym.length.range_start;
                try write_bits(
                    ctx,
                    u16,
                    offset,
                    sym.length.bit_count
                );
                log.debug(@src(), "backref(length-offset): {d}", .{offset});
            }
        },
        .distance => {
            const denc_code: u5 = @truncate(sym.distance.code);
            try write_bits_be(ctx, u5, denc_code, 5);
            log.debug(@src(), "backref(distance): {any}", .{sym.distance});

            // Write the offset bits for the distance
            if (sym.distance.bit_count != 0) {
                const offset = sym.distance.value.? - sym.distance.range_start;
                try write_bits(
                    ctx,
                    u16,
                    offset,
                    sym.distance.bit_count
                );
                log.debug(@src(), "backref(distance-offset): {d}", .{offset});
            }
        },
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
    const offset = @divFloor(ctx.written_bits, 8);
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
