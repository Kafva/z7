const std = @import("std");
const log = @import("log.zig");
const util = @import("util.zig");

const Flate = @import("flate.zig").Flate;
const FlateBlockType = @import("flate.zig").FlateBlockType;
const FlateError = @import("flate.zig").FlateError;
const FlateSymbol = @import("flate.zig").FlateSymbol;
const Token = @import("flate.zig").Token;
const RangeSymbol = @import("flate.zig").RangeSymbol;
const ClSymbol = @import("flate.zig").ClSymbol;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;
const HuffmanEncoding = @import("huffman.zig").HuffmanEncoding;
const huffman_build_encoding = @import("huffman_compress.zig").build_encoding;

const CompressContext = struct {
    allocator: std.mem.Allocator,
    rng: std.Random.Xoshiro256,
    mode: FlateCompressMode,
    crc: *std.hash.Crc32,
    /// The current type of block to write
    block_type: FlateBlockType,
    block_cnt: usize,
    bit_writer: std.io.BitWriter(Flate.writer_endian, std.io.AnyWriter),
    reader: std.io.AnyReader,
    written_bits: usize,
    processed_bytes: usize,
    block_start: usize,
    /// Initial offset into the input stream
    instream_offset: usize,
    /// Left over input byte to use from previous block
    next_byte: ?u8,
    /// Sliding window for back-references in LZSS
    sliding_window: RingBuffer(u8),
    lookahead: []u8,
    /// Queue of symbols to write to the output stream, we need to keep this
    /// in memory so that we can create Huffman trees for these symbols in
    /// block type-2.
    write_queue: []FlateSymbol,
    write_queue_index: usize,
    /// Queue of raw bytes for type-0 blocks.
    write_queue_raw: []u8,
    write_queue_raw_index: usize,
    /// Queue of CL symbols, we need a write queue for these symbols so that
    /// we can perform frequency analysis and decide upon a Huffman encoding
    write_queue_cl: []ClSymbol,
    write_queue_cl_index: usize,
    /// Literal/Length Huffman encoding mappings for block type-2
    ll_enc_map: []?HuffmanEncoding,
    /// Distance Huffman encoding mappings for block type-2
    d_enc_map: []?HuffmanEncoding,
    /// Code length Huffman encoding mapping for block type-2
    cl_enc_map: []?HuffmanEncoding,
};

/// Integer representation needs to match enums in Golang for unit tests!
///   src/compress/flate/deflate.go
pub const FlateCompressMode = enum(u8) {
    NO_COMPRESSION = 0,
    BEST_SPEED = 1,
    BEST_SIZE = 9,
};

pub fn compress(
    allocator: std.mem.Allocator,
    instream: *const std.fs.File,
    outstream: *const std.fs.File,
    instream_offset: usize,
    mode: FlateCompressMode,
    crc: *std.hash.Crc32,
) !void {
    const cl_queue_max = Flate.ll_symbol_max + Flate.d_symbol_max;
    var ctx = CompressContext {
        .allocator = allocator,
        .rng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp())),
        .mode = mode,
        .crc = crc,
        .block_type = FlateBlockType.RESERVED,
        .block_cnt = 0,
        .bit_writer = std.io.bitWriter(Flate.writer_endian, outstream.writer().any()),
        .reader = instream.reader().any(),
        .written_bits = 0,
        .processed_bytes = 0,
        .block_start = 0,
        .instream_offset = instream_offset,
        .next_byte = null,
        .sliding_window = try RingBuffer(u8).init(allocator, Flate.window_length),
        .lookahead = try allocator.alloc(u8, Flate.lookahead_length),
        .write_queue = try allocator.alloc(FlateSymbol, Flate.block_length_max),
        .write_queue_index = 0,
        .write_queue_raw = try allocator.alloc(u8, Flate.block_length_max),
        .write_queue_raw_index = 0,
        .write_queue_cl = try allocator.alloc(ClSymbol, cl_queue_max),
        .write_queue_cl_index = 0,
        .ll_enc_map = try allocator.alloc(?HuffmanEncoding, Flate.ll_symbol_max),
        .d_enc_map = try allocator.alloc(?HuffmanEncoding, Flate.d_symbol_max),
        .cl_enc_map = try allocator.alloc(?HuffmanEncoding, Flate.cl_symbol_max),
    };

    var done = false;
    while (!done) {
        // TODO: fixed block length
        done = try write_block(&ctx, Flate.block_length_max);
        //done = try write_block(&ctx, 256);
    }

    // Incomplete bytes will be padded when flushing, wait until all
    // writes are done.
    try ctx.bit_writer.flushBits();
    log.debug(
        @src(),
        "Compression done: {} -> {} bytes",
        .{ctx.processed_bytes, @divFloor(ctx.written_bits, 8)}
    );
}

/// Go over `block_length` bytes in the input stream with lzss and store
/// the resulting `FlateSymbol` objects into the write queue.
fn lzss(ctx: *CompressContext, block_length: usize) !bool {
    ctx.block_start = ctx.processed_bytes;
    const end: usize = ctx.processed_bytes + block_length;
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

    while (!done and ctx.processed_bytes < end) {
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
            log.trace(@src(), "Extending lookahead to {d}", .{longest_match_length});
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
            util.print_char(log.trace, "Saving for next pass", ctx.lookahead[longest_match_length]);
            ctx.lookahead[0] = ctx.lookahead[longest_match_length];
        }
    }

    // Save starting byte for next block
    if (!done) {
        util.print_char(log.debug, "Saving for next block", ctx.lookahead[0]);
        ctx.next_byte = ctx.lookahead[0];
    }

    log.debug(
        @src(),
        "Done processing input for new block [{}+{} bytes]",
        .{ctx.block_start, ctx.processed_bytes - ctx.block_start}
    );

    if (done and ctx.next_byte != null) {
        util.print_char(log.err, "Reached eof with extra byte present", ctx.next_byte.?);
        return FlateError.InternalError;
    }

    return done;
}

fn write_block(ctx: *CompressContext, block_length: usize) !bool {
    // Populate the write_queue
    // We will always have a saved `next_byte` after this call except for
    // when we reach eof in the input stream.
    const done = try lzss(ctx, block_length);

    // TODO: analyze write queue and decide which type to use
    ctx.block_type = switch (ctx.mode) {
        .NO_COMPRESSION => FlateBlockType.NO_COMPRESSION,
        .BEST_SPEED => FlateBlockType.DYNAMIC_HUFFMAN,
        else =>
            //@enumFromInt(ctx.rng.random().intRangeAtMost(u2, 0, 3)),
            @enumFromInt(ctx.block_cnt % 2)
            //FlateBlockType.FIXED_HUFFMAN
    };
    const btype: u3 = @intFromEnum(ctx.block_type);

    log.debug(@src(), "Writing type-{d} block{s} #{}", .{
        @intFromEnum(ctx.block_type),
        if (done) " (final)" else "",
        ctx.block_cnt
    });

    // Write block header
    var header: u3 = 0;
    header |= btype << 1;         // BTYPE
    header |= @intFromBool(done); // BFINAL
    try write_bits(ctx, u3, header, 3);

    // Encode everything from the write queue onto the output stream
    switch (ctx.block_type) {
        FlateBlockType.NO_COMPRESSION => {
            try no_compression_write_block(ctx, block_length);
        },
        FlateBlockType.FIXED_HUFFMAN => {
            // Write encoded data
            for (0..ctx.write_queue_index) |i| {
                try fixed_code_write_symbol(ctx, ctx.write_queue[i]);
            }
            // Write end-of-block marker
            try write_bits(ctx, u7, @as(u7, 0), 7);
        },
        FlateBlockType.DYNAMIC_HUFFMAN => {
            // Write metadata for the decompressor to reconstruct the Huffman codes.
            try dynamic_code_write_metadata(ctx);

            // Write encoded data
            for (0..ctx.write_queue_index) |i| {
                try dynamic_code_write_symbol(ctx, ctx.write_queue[i]);
            }
            // Write end-of-block marker
            try dynamic_code_write_eob(ctx);
        },
        FlateBlockType.RESERVED => {
            return FlateError.UnexpectedBlockType;
        }
    }
    log.debug(@src(), "Done compressing block #{d} [{d} bytes]", .{
        ctx.block_cnt,
        if (ctx.next_byte) |_| ctx.processed_bytes - 1 else ctx.processed_bytes,
    });
    ctx.write_queue_index = 0;
    ctx.write_queue_raw_index = 0;
    ctx.block_cnt += 1;
    return done;
}

fn queue_symbol(
    ctx: *CompressContext,
    lookahead_end: u16,
    longest_match_length: u16,
    longest_match_distance: u16,
) !void {
    // Save everything for the raw write queue
    for (0..lookahead_end) |i| {
        ctx.write_queue_raw[ctx.write_queue_raw_index] = ctx.lookahead[i];
        ctx.write_queue_raw_index += 1;
    }

    if (longest_match_length <= Flate.min_length_match) {
        // Prefer raw characters for small matches
        for (0..lookahead_end) |i| {
            if (ctx.write_queue_index + 1 >= Flate.block_length_max) {
                return FlateError.OutOfQueueSpace;
            }
            const symbol = FlateSymbol { .char = ctx.lookahead[i] };
            ctx.write_queue[ctx.write_queue_index] = symbol;
            ctx.write_queue_index += 1;
        }
    }
    else {
        if (ctx.write_queue_index + 2 >= Flate.block_length_max) {
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

fn no_compression_write_block(ctx: *CompressContext, block_length: usize) !void {
    if (block_length > Flate.block_length_max) {
        return FlateError.InvalidBlockLength;
    }
    // Fill up with zeroes to the next byte boundary
    while (ctx.written_bits % 8 != 0) {
        try write_bits(ctx, u1, 0, 1);
    }

    // Write length header
    const len: u16 = @truncate(ctx.write_queue_raw_index);
    log.debug(@src(), "Writing LEN: {d}", .{len});
    try write_bits(ctx, u16, len, 16);
    try write_bits(ctx, u16, ~len, 16);

    // Write the uncompressed content from the write_queue
    for (0..ctx.write_queue_raw_index) |i| {
        try write_bits(ctx, u8, ctx.write_queue_raw[i], 8);
    }
}

fn dynamic_code_gen_enc_maps(ctx: *CompressContext) !void {
    var ll_freq = try ctx.allocator.alloc(usize, Flate.ll_symbol_max);
    var d_freq = try ctx.allocator.alloc(usize, Flate.d_symbol_max);
    var ll_cnt: usize = 0;
    var d_cnt: usize = 0;
    @memset(ll_freq, 0);
    @memset(d_freq, 0);

    // Calculate the frequency of each `FlateSymbol`
    for (0..ctx.write_queue_index) |i| {
        const sym = ctx.write_queue[i];
        switch (sym) {
            .length => {
                if (ll_freq[sym.length.code] == 0) {
                    ll_cnt += 1;
                }
                ll_freq[sym.length.code] += 1;
            },
            .distance => {
                if (d_freq[sym.distance.code] == 0) {
                    d_cnt += 1;
                }
                d_freq[sym.distance.code] += 1;
            },
            .char => {
                if (ll_freq[sym.char] == 0) {
                    ll_cnt += 1;
                }
                ll_freq[sym.char] += 1;
            }
        }
    }

    // EOB marker is not part of the write_queue, add a frequency value for it
    // so that we get an encoding for it.
    ll_freq[256] = 1;
    ll_cnt += 1;

    try huffman_build_encoding(ctx.allocator, &ctx.ll_enc_map, ll_freq, ll_cnt);
    try huffman_build_encoding(ctx.allocator, &ctx.d_enc_map, d_freq, d_cnt);
}

fn dynamic_code_enqueue_cl_symbols(ctx: *CompressContext) ![2]usize {
    // Each enc_map is simply a 'Symbol -> Huffman bits' mapping
    // The decompresser knows the order of the symbols, it does not know
    // the length of each 'Huffman bits' sequence
    //
    // We do not transmit the actual Huffman bits, we transfer the *LENGTH* for
    // the 'Huffman bits' of each symbol. Recall that since the Huffman code is
    // canonical the decompressor can reconstruct the Huffman code by just
    // knowing which symbols have which lengths, the length values are
    // limited to be 0-15 (the possible range of 'Huffman bits').

    // Instead of transmitting the length for each symbol encoding ("code
    // length") in order as is, We use an encoding for these, this is the "cl code"
    //
    // [k bits]     0-15: Encodes the length 0 - 15 raw
    // [k + 2 bits] 16: Repeat the previous (0-15) length x + 3 times (x being the two extra bits)
    // [k + 3 bits] 17: Repeat the '0 length' x + 3 times (x being the three extra bits)
    // [k + 7 bits] 18: Repeat the '0 length' x + 11 times (x being the seven extra bits)
    //
    // 'k' is dependant on the Huffman code that is generated.
    // +3 etc. makes sense since we would never want to encode less than 3 repetitions of something.
    //
    // NOW, we don't just write the CL symbols as is to the output stream, no, we check the
    // frequency for each CL symbol (i.e. 0-18) and construct a new Huffman code for these,
    // THIS is what we write to the output stream.
    var cl_freq = try ctx.allocator.alloc(usize, Flate.cl_symbol_max);
    var cl_cnt: usize = 0;
    var ll_cuts: usize = 0;
    var d_cuts: usize = 0;
    @memset(cl_freq, 0);

    // Populate the `write_queue_cl` with CL symbols based on the *LENGTH* of the
    // encodings in the ll and distance maps.
    var idx: usize = 0;
    var repeat_length: usize = 0;
    var cl_value: u8 = 0;
    var bit_length: u4 = 0;

    while (idx < Flate.ll_symbol_max + Flate.d_symbol_max) {
        if (idx < Flate.ll_symbol_max) {
            bit_length = if (ctx.ll_enc_map[idx]) |enc| enc.bit_shift else 0;
        }
        else {
            bit_length = if (ctx.d_enc_map[idx - Flate.ll_symbol_max]) |enc| enc.bit_shift else 0;
        }
        // Match from one position after the current index
        idx += 1;

        // Cut of the LEN or DIST symbols early if we find a run of zeroes
        // up until the end of `ll_enc_map` or `d_enc_map`
        const map = if (idx < Flate.ll_symbol_max) ctx.ll_enc_map else ctx.d_enc_map;
        const end = if (idx < Flate.ll_symbol_max) Flate.ll_symbol_max else Flate.d_symbol_max;
        const start_idx = if (idx < Flate.ll_symbol_max) idx else idx - Flate.ll_symbol_max;

        if (bit_length == 0) {
            if (dynamic_code_cut_zeroes(map, start_idx, end)) |cut_len| {
                idx += cut_len;
                // Save the cut length for the header
                if (idx <= Flate.ll_symbol_max) {
                    log.debug(@src(), "Cutting {d} trailing zeros from LL code lengths", .{cut_len});
                    ll_cuts = cut_len;
                }
                else {
                    log.debug(@src(), "Cutting {d} trailing zeros from distance code lengths", .{cut_len});
                    d_cuts = cut_len;
                }
                continue;
            }
        }

        repeat_length = dynamic_code_lookahead_eql(ctx, idx, bit_length);
        idx += repeat_length;

        if (repeat_length >= 138) {
            log.err(@src(), "Invalid CL repeat length: {d}", .{repeat_length});
            return FlateError.InternalError;
        }
        else if (repeat_length >= 3 and bit_length != 0) {
            cl_value = 16;
        }
        else if (repeat_length >= 3 and repeat_length <= 10 and bit_length == 0) {
            cl_value = 17;
        }
        else if (repeat_length > 10 and bit_length == 0) {
            cl_value = 18;
        }
        else {
            cl_value = bit_length;
            repeat_length = 0;
        }

        ctx.write_queue_cl[ctx.write_queue_cl_index] = ClSymbol {
            .value = cl_value,
            .repeat_length = @truncate(repeat_length),
        };
        log.debug(@src(), "Enqueued: {any}", .{ctx.write_queue_cl[ctx.write_queue_cl_index]});
        ctx.write_queue_cl_index += 1;
    }

    // Calculate the frequency of each `ClSymbol`
    for (0..ctx.write_queue_cl_index) |i| {
        const v = ctx.write_queue_cl[i].value;
        if (cl_freq[v] == 0) {
            cl_cnt += 1;
        }
        cl_freq[v] += 1;
    }

    try huffman_build_encoding(ctx.allocator, &ctx.cl_enc_map, cl_freq, cl_cnt);

    return [_]usize{ ll_cuts, d_cuts };
}

fn dynamic_code_write_metadata(ctx: *CompressContext) !void {
    // Generate `ll_enc_map` and `d_enc_map` based on the current
    // `write_queue` content.
    try dynamic_code_gen_enc_maps(ctx);

    // Enqueue the CL symbols used to encode the `ll_enc_map` and `d_enc_map`
    const cuts = try dynamic_code_enqueue_cl_symbols(ctx);

    // Write the code *lengths* of the CL symbols
    const cl_cut = try dynamic_code_write_cl_header(ctx);

    log.debug(@src(), "Writing block type-2 header", .{});

    const ll_symbols_total: usize = Flate.ll_symbol_max - cuts[0];
    const d_symbols_total: usize  = Flate.d_symbol_max - cuts[1];
    const cl_symbols_total: usize = Flate.cl_symbol_max - cl_cut;
    log.debug(@src(), "LL: {d} -> {d}, DIST: {d} -> {d}, CL: {d} -> {d}", .{
        Flate.ll_symbol_max,
        ll_symbols_total,
        Flate.d_symbol_max,
        d_symbols_total,
        Flate.cl_symbol_max,
        cl_symbols_total,
    });

    const hlit: u5 = @truncate(ll_symbols_total - 257);
    const hdist: u5 = @truncate(d_symbols_total - 1);
    const hclen: u4 = @truncate(cl_symbols_total - 4);
    log.debug(@src(), "HLIT: {d}, HDIST: {d}, HCLEN: {d}", .{
        hlit,
        hdist,
        hclen,
    });

    try write_bits(ctx, u5, hlit, 5);
    try write_bits(ctx, u5, hdist, 5);
    try write_bits(ctx, u4, hclen, 4);


    // Dequeue everything from the CL queue
    for (0..ctx.write_queue_cl_index) |i| {
        try dynamic_code_write_cl_symbol(ctx, ctx.write_queue_cl[i]);
    }
    log.debug(@src(), "Wrote CL symbols ({})", .{ctx.write_queue_cl_index});
    ctx.write_queue_cl_index = 0;

    log.debug(@src(), "Done writing Huffman metadata for block #{d} @{d}", .{
        ctx.block_cnt,
        ctx.instream_offset + @divFloor(ctx.written_bits, 8)
    });
}

fn dynamic_code_write_eob(ctx: *CompressContext) !void {
    const enc: ?HuffmanEncoding = ctx.ll_enc_map[256];
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
}

fn dynamic_code_write_symbol(ctx: *CompressContext, sym: FlateSymbol) !void {
    const enc: ?HuffmanEncoding = blk: {
        switch (sym) {
            .length => {
                break :blk ctx.ll_enc_map[sym.length.code];
            },
            .distance => {
                break :blk ctx.d_enc_map[sym.distance.code];
            },
            .char => {
                util.print_char(log.trace, "literal", @intCast(sym.char));
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
                log.trace(@src(), "backref(length-offset): {d}", .{offset});
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
                log.trace(@src(), "backref(distance-offset): {d}", .{offset});
            }
        },
        else => {}
    }
}

fn dynamic_code_cut_zeroes(arr: []?HuffmanEncoding, start_idx: usize, end: usize) ?usize {
    var match_cnt: usize = 0;
    while (start_idx + match_cnt < end) {
        if (arr[start_idx + match_cnt]) |_| { // Not zero
            break;
        }
        else {
            match_cnt += 1;
        }
    }

    if (start_idx + match_cnt == end) {
        return match_cnt;
    }
    return null;
}

fn dynamic_code_cut_zeroes_cl_header(ctx: *CompressContext, start_idx: usize) ?usize {
    var match_cnt: usize = 0;
    while (start_idx + match_cnt < Flate.cl_symbol_max) {
        const idx = Flate.cl_code_order[start_idx + match_cnt];
        if (ctx.cl_enc_map[idx]) |_| { // Not zero
            break;
        }
        else {
            match_cnt += 1;
        }
    }

    if (start_idx + match_cnt == Flate.cl_symbol_max) {
        return match_cnt;
    }
    return null;
}

/// Return the number of symbols starting at `idx` that match the provided `value`.
/// We look in the `ll_enc_map` followed by `d_enc_map` for matches, matches are allowed
/// to overlap between the maps!
fn dynamic_code_lookahead_eql(ctx: *CompressContext, idx: usize, value: u4) usize {
    var match_cnt: usize = 0;
    const match_cnt_max: usize = if (value == 0) 138 else 6;

    while (idx + match_cnt < Flate.ll_symbol_max + Flate.d_symbol_max) {
        const i = idx + match_cnt;
        const v: u4 = blk: {
            if (i < Flate.ll_symbol_max) {
                if (ctx.ll_enc_map[i]) |enc| {
                    break :blk enc.bit_shift;
                }
            }
            else {
                if (ctx.d_enc_map[i - Flate.ll_symbol_max]) |enc| {
                    break :blk enc.bit_shift;
                }
            }

            break :blk 0;
        };

        if (v == value) match_cnt += 1
        else break;

        if (match_cnt == match_cnt_max) break;
    }
    return match_cnt;
}

/// Write the code *lengths* of the CL symbols the special cl_code order, this
/// provides the decompressor with the information needed to decompress the
/// queued `ClSymbol` objects that hold the `ll_enc_map` and `d_enc_map`.
fn dynamic_code_write_cl_header(ctx: *CompressContext) !usize {
    for (Flate.cl_code_order) |i| {
        if (ctx.cl_enc_map[i]) |v| {
            // XXX: Write the length of the encoding
            try write_bits(ctx, u3, @truncate(v.bit_shift), 3);
            log.trace(@src(), "Wrote CL header code: {d} => 0b{b} ({d})", .{
                i, v.bits, v.bit_shift
            });
        }
        else {
            if (dynamic_code_cut_zeroes_cl_header(ctx, i)) |cut_len| {
                return cut_len;
            }
            try write_bits(ctx, u3, 0, 3);
        }
    }

    return 0;
}

fn dynamic_code_write_cl_symbol(ctx: *CompressContext, sym: ClSymbol) !void {
    // Write symbol
    if (ctx.cl_enc_map[sym.value]) |enc| {
        if (enc.bit_shift > 4) {
            log.err(@src(), "Invalid symbol: {d} => {any}", .{sym.value, enc});
            return FlateError.InternalError;
        }

        try write_bits_be(ctx, u4, @truncate(enc.bits), enc.bit_shift);
        log.debug(@src(), "Wrote symbol: {d} => {any}", .{
            sym.value,
            enc
        });
    }
    else {
        log.err(@src(), "Missing encoding for CL symbol {d}", .{sym.value});
        return FlateError.InternalError;
    }

    // Write extra bits
    switch (sym.value) {
        16 => {
            if (sym.repeat_length < 3 or sym.repeat_length > 6) {
                log.err(@src(), "Bad repeat length for CL symbol: {any}", .{sym});
                return FlateError.InternalError;
            }
            const r: u8 = sym.repeat_length - 3;
            const repeat_length: u2 = @truncate(r);
            try write_bits(ctx, u2, repeat_length, 2);
        },
        17 => {
            if (sym.repeat_length < 3 or sym.repeat_length > 10) {
                log.err(@src(), "Bad repeat length for CL symbol: {any}", .{sym});
                return FlateError.InternalError;
            }
            const r: u8 = sym.repeat_length - 3;
            const repeat_length: u3 = @truncate(r);
            try write_bits(ctx, u3, repeat_length, 3);
        },
        18 => {
            if (sym.repeat_length < 11 or sym.repeat_length > 138) {
                log.err(@src(), "Bad repeat length for CL symbol: {any}", .{sym});
                return FlateError.InternalError;
            }
            const r: u8 = sym.repeat_length - 10;
            const repeat_length: u7 = @truncate(r);
            try write_bits(ctx, u7, repeat_length, 7);
        },
        else => {},
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
            util.print_char(log.debug, "Output write literal", sym.char);
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
    if (T == u8 and num_bits == 8) {
        util.print_char(log.debug, "Output write", value);
    }
    else {
        const offset = ctx.instream_offset + @divFloor(ctx.written_bits, 8);
        util.print_bits(log.trace, T, "Output write", value, num_bits, offset);
    }
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
        u8, u7 => u3,
        u6, u5, u4, u3 => u2,
        else => u1
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
    util.print_char(log.trace, "Input read", b);
    ctx.processed_bytes += 1;

    // The final crc should be the crc of the entire input file, update
    // it incrementally as we process each byte.
    const bytearr = [1]u8 { b };
    ctx.crc.update(&bytearr);

    return b;
}
