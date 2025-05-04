const std = @import("std");
const log = @import("log.zig");
const util = @import("util.zig");

const Flate = @import("flate.zig").Flate;
const ClSymbol = @import("flate.zig").ClSymbol;
const FlateBlockType = @import("flate.zig").FlateBlockType;
const FlateError = @import("flate.zig").FlateError;
const Token = @import("flate.zig").Token;
const RangeSymbol = @import("flate.zig").RangeSymbol;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;
const HuffmanEncoding = @import("huffman.zig").HuffmanEncoding;
const HuffmanError = @import("huffman.zig").HuffmanError;
const HuffmanCodeLengthToken = @import("huffman_decompress.zig").HuffmanCLToken;
const reconstruct_canonical_code = @import("huffman_decompress.zig").reconstruct_canonical_code;

const DecompressError = error {
    UndecodableBitStream,
    UnexpectedNLenBytes
};

const DecompressContext = struct {
    allocator: std.mem.Allocator,
    /// Show progress?
    progress: bool,
    maybe_inputfile_size: ?f64,
    crc: *std.hash.Crc32,
    /// The current type of block to decode
    block_type: FlateBlockType,
    block_cnt: usize,
    writer: std.io.AnyWriter,
    bit_reader: std.io.BitReader(Flate.writer_endian, std.io.AnyReader),
    start_offset: usize,
    written_bytes: usize,
    processed_bits: usize,
    /// Cache of the last 32K read bytes to support backreferences
    sliding_window: RingBuffer(u8),
    /// Decoding maps for block type-1
    seven_bit_decode: std.AutoHashMap(u16, u16),
    eight_bit_decode: std.AutoHashMap(u16, u16),
    nine_bit_decode: std.AutoHashMap(u16, u16),
    /// Literal/Length Huffman decoding mappings for block type-2
    ll_dec_map: std.AutoHashMap(HuffmanEncoding, u16),
    /// Distance Huffman decoding mappings for block type-2
    d_dec_map: std.AutoHashMap(HuffmanEncoding, u16),
    /// Code length Huffman decoding mappings for block type-2, maps from
    /// a huffman encoding onto a [0,18] value.
    cl_dec_map: std.AutoHashMap(HuffmanEncoding, u16),
};

pub fn decompress(
    allocator: std.mem.Allocator,
    instream: *const std.fs.File,
    outstream: *const std.fs.File,
    instream_offset: usize,
    progress: bool,
    crc: *std.hash.Crc32,
) !void {
    var done = false;
    var ctx = DecompressContext {
        .allocator = allocator,
        .progress = progress,
        .maybe_inputfile_size =  blk: {
            const st = instream.stat() catch {
                break :blk null;
            };
            break :blk @floatFromInt(st.size);
        },
        .crc = crc,
        .block_type = FlateBlockType.RESERVED,
        .block_cnt = 0,
        .writer = outstream.writer().any(),
        .bit_reader = std.io.bitReader(Flate.writer_endian, instream.reader().any()),
        .start_offset = instream_offset,
        .written_bytes = 0,
        .processed_bits = 0,
        .sliding_window = try RingBuffer(u8).init(allocator, Flate.window_length),
        .seven_bit_decode = try fixed_code_decoding_map(7),
        .eight_bit_decode = try fixed_code_decoding_map(8),
        .nine_bit_decode = try fixed_code_decoding_map(9),
        .ll_dec_map = std.AutoHashMap(HuffmanEncoding, u16).init(allocator),
        .d_dec_map = std.AutoHashMap(HuffmanEncoding, u16).init(allocator),
        .cl_dec_map = std.AutoHashMap(HuffmanEncoding, u16).init(allocator),
    };

    // Decode the stream
    while (!done) {
        const header = try read_bits(&ctx, u3, 3);
        done = (header & 1) == 1;

        const block_type_int: u2 = @truncate(header >> 1);
        ctx.block_type = @enumFromInt(block_type_int);

        log.debug(@src(), "Reading type-{d} block{s} #{d}", .{
            block_type_int,
            if (done) " (final)" else "",
            ctx.block_cnt
        });

        switch (ctx.block_type) {
            FlateBlockType.NO_COMPRESSION => {
                try no_compression_decompress_block(&ctx);
            },
            FlateBlockType.FIXED_HUFFMAN => {
                try fixed_code_decompress_block(&ctx);
            },
            FlateBlockType.DYNAMIC_HUFFMAN => {
                try dynamic_code_decompress_block(&ctx);
            },
            else => {
                return FlateError.UnexpectedBlockType;
            }
        }
        log.debug(@src(), "Done decompressing block #{d} [{d} bytes]", .{
            ctx.block_cnt,
            ctx.written_bytes,
        });
        ctx.block_cnt += 1;
    }

    log.debug(
        @src(),
        "Decompression done: {} -> {} bytes",
        .{@divFloor(ctx.processed_bits, 8), ctx.written_bytes}
    );
}

fn no_compression_decompress_block(ctx: *DecompressContext) !void {
    // Shift out zeroes up until the next byte boundary
    while (ctx.processed_bits % 8 != 0) {
        const b = try read_bits(ctx, u1, 1);
        if (b != 0) {
            log.err(
                @src(),
                "Found non-zero padding bit at {} bit offset",
                .{ctx.processed_bits}
            );
        }
    }

    // Read block length
    const block_size = try read_bits(ctx, u16, 16);
    const block_size_compl = try read_bits(ctx, u16, 16);
    if (~block_size != block_size_compl) {
        return DecompressError.UnexpectedNLenBytes;
    }
    log.debug(@src(), "Decompressing {d} bytes from type-0 block", .{block_size});

    // Write bytes as-is to output stream in bulk
    const buf = try ctx.allocator.alloc(u8, block_size);
    const cnt = try read_bytes(ctx, buf);

    for (buf[0..cnt]) |b| {
        _ = ctx.sliding_window.push(b);
    }
    try write_bytes(ctx, buf[0..cnt]);

    ctx.allocator.free(buf);
}

fn fixed_code_decompress_block(ctx: *DecompressContext) !void {
    var buf = [_]u8{0} ** Flate.write_bufsize;
    var bufidx: usize = 0;

    while (true) {
        const v = blk: {
            var key = read_bits_be(ctx, 7) catch {
                return FlateError.UnexpectedEof;
            };

            if (ctx.seven_bit_decode.get(key)) |char| {
                log.trace(@src(), "Matched 0b{b:0>7}", .{key});
                break :blk char;
            }

            // Read one more bit and try the 8-bit value
            //   0111100    [7 bits]
            //   0111100(x) [8 bits]
            var bit = read_bits(ctx, u1, 1) catch {
                return FlateError.UnexpectedEof;
            };
            key <<= 1;
            key |= bit;

            if (ctx.eight_bit_decode.get(key)) |char| {
                log.trace(@src(), "Matched 0b{b:0>8}", .{key});
                break :blk char;
            }

            // Read one more bit and try the 9-bit value
            //  01111001    [8 bits]
            //  01111001(x) [9 bits]
            bit = read_bits(ctx, u1, 1) catch {
                return FlateError.UnexpectedEof;
            };
            key <<= 1;
            key |= bit;

            if (ctx.nine_bit_decode.get(key)) |char| {
                log.trace(@src(), "Matched 0b{b:0>9}", .{key});
                break :blk char;
            }

            return DecompressError.UndecodableBitStream;
        };

        if (v < 256) {
            try write_byte_match(ctx, &buf, &bufidx, @truncate(v));
        }
        else if (v == 256) {
            log.debug(@src(), "End-of-block marker found", .{});
            break;
        }
        else if (v < Flate.ll_symbol_max) {
            // Determine the length of the match
            const length = try read_symbol_backref_length(ctx, v);

            // Determine the distance for the match
            const distance_code = read_bits_be(ctx, 5) catch {
                return FlateError.UnexpectedEof;
            };
            const distance = try read_symbol_backref_distance(ctx, distance_code);

            // Write the backreferences to the output stream
            try write_backref_match(ctx, &buf, &bufidx, length, distance);
        }
        else {
            return FlateError.InvalidLiteralLength;
        }
    }

    // Flush any left-over data
    if (bufidx != 0) {
        try write_bytes(ctx, buf[0..bufidx]);
    }
}

/// Create a hashmap from each Huffman code onto a literal.
/// We need a separate map for each bit-length,
///  0b0111100 [7] ~= 0b00111100 [8]
/// Same numerical value, but not the same bit-stream.
///
/// Lit Value    Bits        Codes
/// ---------    ----        -----
///   0 - 143     8          00110000 through
///                          10111111
/// 144 - 255     9          110010000 through
///                          111111111
/// 256 - 279     7          0000000 through
///                          0010111
/// 280 - 287     8          11000000 through
///                          11000111
fn fixed_code_decoding_map(comptime num_bits: u8) !std.AutoHashMap(u16, u16) {
    var huffman_map = std.AutoHashMap(u16, u16).init(std.heap.page_allocator);
    switch (num_bits) {
        7 => {
            for (0..(280-256)) |c| {
                const i: u16 = @intCast(c);
                try huffman_map.putNoClobber(0b000_0000 + i, 256 + i);
            }
        },
        8 => {
            for (0..(144-0)) |c| {
                const i: u16 = @intCast(c);
                try huffman_map.putNoClobber(0b0011_0000 + i, 0 + i);
            }
            for (0..(288-280)) |c| {
                const i: u16 = @intCast(c);
                try huffman_map.putNoClobber(0b1100_0000 + i, 280 + i);
            }
        },
        9 => {
            for (0..(256-144)) |c| {
                const i: u16 = @intCast(c);
                try huffman_map.putNoClobber(0b1_1001_0000 + i, 144 + i);
            }
        },
        else => unreachable,
    }
    return huffman_map;
}

fn dynamic_code_decompress_block(ctx: *DecompressContext) !void {
    var buf = [_]u8{0} ** Flate.write_bufsize;
    var bufidx: usize = 0;

    // Extract the Huffman trees, i.e. `ll_dec_map` and `d_dec_map` from
    // the initial metadata.
    try dynamic_code_decompress_metadata(ctx);

    var match_length: ?u16 = null;
    var enc = HuffmanEncoding {
        .bits = 0,
        .bit_shift = 0,
    };

    // Decode the stream using the `ll_dec_map` and `d_dec_map`
    while (true) {
        const bit = read_bits(ctx, u1, 1) catch {
            break;
        };
        if (enc.bit_shift == 15) {
            log.err(@src(), "Huffman tree too deep", .{});
            return HuffmanError.BadEncoding;
        }

        // The most-significant bit is read first
        enc.bits = (enc.bits << 1) | bit;
        enc.bit_shift += 1;

        if (match_length) |length| {
            if (ctx.d_dec_map.get(enc)) |v| {
                if (v > Flate.d_symbol_max) {
                    log.err(@src(), "Invalid distance symbol: {d}", .{v});
                    return FlateError.InternalError;
                }

                // Decode distance of match
                const distance = try read_symbol_backref_distance(ctx, v);

                // Write match to output stream
                try write_backref_match(ctx, &buf, &bufidx, length, distance);

                enc.bits = 0;
                enc.bit_shift = 0;
                match_length = null;
            }
            continue;
        }

        if (ctx.ll_dec_map.get(enc)) |v| {
            if (v < 256) {
                try write_byte_match(ctx, &buf, &bufidx, @truncate(v));
            }
            else if (v == 256) {
                log.debug(@src(), "End-of-block marker found", .{});
                break;
            }
            else if (v < Flate.ll_symbol_max) {
                // Decode length of match
                match_length = try read_symbol_backref_length(ctx, v);
            }
            else {
                return FlateError.InvalidLiteralLength;
            }

            enc.bits = 0;
            enc.bit_shift = 0;
        }
    }

    // Flush any left-over data
    if (bufidx != 0) {
        try write_bytes(ctx, buf[0..bufidx]);
    }

    // Clear mappings for next iteration
    ctx.cl_dec_map.clearRetainingCapacity();
    ctx.ll_dec_map.clearRetainingCapacity();
    ctx.d_dec_map.clearRetainingCapacity();
}

fn dynamic_code_decompress_metadata(ctx: *DecompressContext) !void {
    log.debug(@src(), "Reading block type-2 header", .{});

    const hlit = try read_bits(ctx, u16, 5);
    const hdist = try read_bits(ctx, u8, 5);
    const hclen = try read_bits(ctx, u8, 4);

    const ll_symbols_total: u16 = hlit + 257;
    const d_symbols_total: u8 = hdist + 1;
    const cl_symbols_total: u8 = hclen + 4;

    log.debug(@src(), "HLIT: {d} -> {d}, HDIST: {d} -> {d}, HCLEN: {d} -> {d}", .{
        hlit,
        ll_symbols_total,
        hdist,
        d_symbols_total,
        hclen,
        cl_symbols_total
    });

    log.debug(@src(), "Reading block type-2 metadata", .{});

    // Reconstruct the decoding map for the CL symbols
    var cl_code_lengths = [_]u4{0}**Flate.cl_symbol_max;
    for (0..cl_symbols_total) |i| {
        const bit_len = try read_bits(ctx, u3, 3);
        cl_code_lengths[Flate.cl_code_order[i]] = bit_len;
    }
    try reconstruct_canonical_code(
        &ctx.allocator,
        &ctx.cl_dec_map,
        &cl_code_lengths,
        Flate.cl_symbol_max
    );

    // Decode the stream of CL symbols into actual code lengths
    // that we can use to reconstruct the LL and DIST Huffman codes.
    var ll_code_lengths = [_]u4{0}**Flate.ll_symbol_max;
    var d_code_lengths = [_]u4{0}**Flate.d_symbol_max;
    try dynamic_code_decompress_cl_symbols(
        ctx,
        &ll_code_lengths,
        &d_code_lengths,
        ll_symbols_total,
        d_symbols_total
    );

    // Reconstruct the decoding map for the LL symbols
    try reconstruct_canonical_code(
        &ctx.allocator,
        &ctx.ll_dec_map,
        &ll_code_lengths,
        Flate.ll_symbol_max,
    );

    // Reconstruct the decoding map for the distance symbols
    try reconstruct_canonical_code(
        &ctx.allocator,
        &ctx.d_dec_map,
        &d_code_lengths,
        Flate.d_symbol_max,
    );

    log.debug(@src(), "Done reading Huffman metadata for block #{d}", .{ctx.block_cnt});
}

fn dynamic_code_decompress_cl_symbols(
    ctx: *DecompressContext,
    ll_code_lengths: *[Flate.ll_symbol_max]u4,
    d_code_lengths: *[Flate.d_symbol_max]u4,
    ll_symbols_total: usize,
    d_symbols_total: usize,
) !void {
    var prev_bit_length: ?u4 = null;
    var codes_done: usize = 0;
    var enc = HuffmanEncoding {
        .bits = 0,
        .bit_shift = 0,
    };

    while (codes_done < ll_symbols_total + d_symbols_total) {
        const bit = read_bits(ctx, u1, 1) catch {
            break;
        };

        if (enc.bit_shift == 15) {
            return HuffmanError.BadEncoding;
        }

        // The most-significant bit is read first
        enc.bits = (enc.bits << 1) | bit;
        enc.bit_shift += 1;

        if (ctx.cl_dec_map.get(enc)) |v| {
            var repeat_length: ?u8 = null;
            var repeat_value: u4 = 0;

            switch (v) {
                0...15 => {
                    const bit_len: u4 = @truncate(v);
                    if (codes_done < ll_symbols_total) {
                        ll_code_lengths.*[codes_done] = bit_len;
                    }
                    else {
                        d_code_lengths.*[codes_done - ll_symbols_total] = bit_len;
                    }
                    prev_bit_length = bit_len;
                },
                16 => {
                    const bits = read_bits(ctx, u8, 2) catch {
                        break;
                    };
                    repeat_length = 3 + bits;

                    if (prev_bit_length) |bl| {
                        repeat_value = bl;
                    }
                    else {
                        log.err(@src(), "Unexpected CL symbol 16", .{});
                        return FlateError.InvalidCLSymbol;
                    }
                },
                17 => {
                    const bits = read_bits(ctx, u8, 3) catch {
                        break;
                    };
                    repeat_length = 3 + bits;
                },
                18 => {
                    const bits = read_bits(ctx, u8, 7) catch {
                        break;
                    };
                    repeat_length = 11 + bits;
                },
                else => return FlateError.InvalidCLSymbol,
            }

            if (repeat_length) |repeat| {
                log.debug(@src(), "[{d}] Symbol {d} [repeat {d}]", .{codes_done, v, repeat});
                if (codes_done < ll_symbols_total) {
                    for (0..repeat) |_| {
                        ll_code_lengths.*[codes_done] = repeat_value;
                        codes_done += 1;
                    }
                }
                else {
                    for (0..repeat) |_| {
                        d_code_lengths.*[codes_done - ll_symbols_total] = repeat_value;
                        codes_done += 1;
                    }
                }

            }
            else {
                log.debug(@src(), "[{d}] Symbol {d}", .{codes_done, v});
                codes_done += 1;
            }

            enc.bits = 0;
            enc.bit_shift = 0;
        }
    }
}

fn read_symbol_backref_length(ctx: *DecompressContext, v: u16) !u16 {
    log.debug(@src(), "backref(length-code): {d}", .{v});

    // Get the corresponding `RangeSymbol` for the 'Code'
    const rsym = try RangeSymbol.from_length_code(v);

    // Determine the length of the match
    const length: u16 = blk: {
        if (rsym.bit_count != 0) {
            // Parse extra bits for the offset
            const offset = read_bits(ctx, u16, rsym.bit_count) catch {
                return FlateError.UnexpectedEof;
            };
            log.debug(@src(), "backref(length-offset): {d}", .{offset});
            break :blk rsym.range_start + offset;
        } else {
            log.debug(@src(), "backref(length-offset): 0", .{});
            break :blk rsym.range_start;
        }
    };
    log.debug(@src(), "backref(length): {d}", .{length});
    return length;
}

fn read_symbol_backref_distance(ctx: *DecompressContext, v: u16) !u16 {
    const denc = try RangeSymbol.from_distance_code(@truncate(v));
    log.debug(@src(), "backref(distance-code): {d}", .{v});

    const distance: u16 = blk: {
        if (denc.bit_count != 0) {
            // Parse extra bits for the offset
            const offset = read_bits(ctx, u16, denc.bit_count) catch {
                return FlateError.UnexpectedEof;
            };
            log.debug(@src(), "backref(distance-offset): {d}", .{offset});
            break :blk denc.range_start + offset;
        } else {
            log.debug(@src(), "backref(distance-offset): 0", .{});
            break :blk denc.range_start;
        }
    };
    log.debug(@src(), "backref(distance): {d}", .{distance});
    return distance;
}

fn write_byte_match(ctx: *DecompressContext, buf: []u8, bufidx: *usize, b: u8) !void {
    _ = ctx.sliding_window.push(b);
    util.print_char(log.debug, "literal", b);

    buf[bufidx.*] = b;
    bufidx.* += 1;

    if (bufidx.* == buf.len) {
        // Flush the buffer once its filled
        try write_bytes(ctx, buf[0..bufidx.*]);
        bufidx.* = 0;
    }
}

fn write_backref_match(
    ctx: *DecompressContext,
    buf: []u8,
    bufidx: *usize,
    length: u16,
    distance: u16,
) !void {
    // Note: an LZ stream can looks like this:
    //  ('a', [258:1] )
    // In this scenario the [258:1] backreference will not be available in the
    // sliding window immediately, we need to write to the sliding window
    // incrementally as we are creating the backref.
    for (0..length) |_| {
        // Since we add one byte every iteration the offset is always equal to the distance
        const bs: [1]u8 = try ctx.sliding_window.read_offset_end_fixed(distance - 1, 1);
        _ = ctx.sliding_window.push(bs[0]);
        buf[bufidx.*] = bs[0];
        bufidx.* += 1;

        if (bufidx.* == buf.len) {
            // Flush the buffer once its filled
            try write_bytes(ctx, buf[0..bufidx.*]);
            bufidx.* = 0;
        }
    }
}

fn read_bytes(ctx: *DecompressContext, buf: []u8) !usize {
    const cnt = try ctx.bit_reader.reader.readAll(buf);
    ctx.processed_bits  += cnt * 8;

    try print_progress(ctx);
    return cnt;
}

/// Read bits with the configured bit-ordering from the input stream
fn read_bits(ctx: *DecompressContext, comptime T: type, num_bits: u16) !T {
    const bits = try ctx.bit_reader.readBitsNoEof(T, num_bits);
    ctx.processed_bits += num_bits;

    try print_progress(ctx);

    return bits;
}

/// This stream: 11110xxx xxxxx000 should be interpreted as 0b01111_000
fn read_bits_be(ctx: *DecompressContext, num_bits: u16) !u16 {
    var out: u16 = 0;
    for (1..num_bits) |i_usize| {
        const i: u4 = @intCast(i_usize);
        const shift_by: u4 = @intCast(num_bits - i);

        const bit = try read_bits(ctx, u16, 1);
        out |= bit << shift_by;
    }

    // Final bit
    const bit = try read_bits(ctx, u16, 1);
    out |= bit;

    return out;
}

fn write_bytes(ctx: *DecompressContext, buf: []u8) !void {
    try ctx.writer.writeAll(buf);
    ctx.written_bytes += buf.len;

    // The crc in the trailer of the gzip format is performed on the
    // original input file, calculate the crc for the output file we are
    // writing incrementally as we process each byte.
    ctx.crc.update(buf);
}

fn print_progress(ctx: *DecompressContext) !void {
    if (!ctx.progress) {
        return;
    }
    if (ctx.maybe_inputfile_size) |input_filesize| {
        const current_bytes = @divFloor(ctx.processed_bits, 8);
        try util.progress(
            "Decompressing...",
            ctx.start_offset + current_bytes,
            input_filesize - 8 // Exclude trailer bytes
        );
    }
}
