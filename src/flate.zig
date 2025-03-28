const std = @import("std");
const log = @import("log.zig");
const util = @import("util.zig");

const writer_endian = std.builtin.Endian.big;

const Token = struct {
    /// Valid matches are between (3..258) characters long, i.e. we acutally
    /// only need a u8 to represent this.
    length: u16,
    /// Valid distances are within (1..2**15)
    distance: u16,
    /// If a raw character has been set, ignore the length/distance values.
    char: ?u8,

    pub fn format(
        self: *const @This(),
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype
    ) !void {
        if (fmt.len != 0) {
            return std.fmt.invalidFmtError(fmt, self);
        }

        if (self.char) |char| {
            if (std.ascii.isPrint(char) and char != '\n') {
                return writer.print(
                    "{{ .length = {d}, .distance = {d}, .char = '{c}' }}",
                    .{self.length, self.distance, char}
                );
            } else {
                return writer.print(
                    "{{ .length = {d}, .distance = {d}, .char = 0x{x} }}",
                    .{self.length, self.distance, char}
                );
            }
        } else {
            return writer.print(
                "{{ .length = {d}, .distance = {d} }}",
                .{self.length, self.distance}
            );
        }
    }
};

const FlateError = error {
    NotImplemented,
    UnexpectedBlockType,
    UnexpectedEof,
    InvalidLiteralLength,
    MissingTokenLiteral,
    UndecodableBitStream,
};

const FlateBlockType = enum(u2) {
    NO_COMPRESSION = 0b00,
    FIXED_HUFFMAN = 0b01,
    DYNAMIC_HUFFMAN = 0b10,
    RESERVED = 0b11,
};

const CompressContext = struct {
    /// The current type of block to write
    block_type: FlateBlockType,
    bit_writer: std.io.BitWriter(writer_endian, std.io.AnyWriter),
    reader: std.io.AnyReader,
    written_bits: usize,
    processed_bits: usize,
    sliding_window: std.RingBuffer,
    lookahead: []u8,
};

const DecompressContext = struct {
    /// The current type of block to decode
    block_type: FlateBlockType,
    writer: std.io.AnyWriter,
    bit_reader: std.io.BitReader(writer_endian, std.io.AnyReader),
    written_bits: usize,
    processed_bits: usize,
    /// Cache of the last 32K read bytes to support backreferences
    sliding_window: std.RingBuffer,
};

pub const Flate = struct {
    allocator: std.mem.Allocator,

    const lookahead_length: usize = 258;
    const window_length: usize = std.math.pow(usize, 2, 15);

    /// Map a match length onto a `{ code, bit_count, range_start }`
    /// tuple. The end of the range is given from `range_start + 2**bit_count`.
    ///      Extra               Extra               Extra
    /// Code Bits Length(s) Code Bits Lengths   Code Bits Length(s)
    /// ---- ---- ------     ---- ---- -------   ---- ---- -------
    ///  257   0     3       267   1   15,16     277   4   67-82
    ///  258   0     4       268   1   17,18     278   4   83-98
    ///  259   0     5       269   2   19-22     279   4   99-114
    ///  260   0     6       270   2   23-26     280   4  115-130
    ///  261   0     7       271   2   27-30     281   5  131-162
    ///  262   0     8       272   2   31-34     282   5  163-194
    ///  263   0     9       273   3   35-42     283   5  195-226
    ///  264   0    10       274   3   43-50     284   5  227-257
    ///  265   1  11,12      275   3   51-58     285   0    258
    ///  266   1  13,14      276   3   59-66
    fn lookup_length(length: u16) [3]u16 {
        return switch (length) {
            3 => .{ 257, 0, 3 },
            4 => .{ 258, 0, 4 },
            5 => .{ 259, 0, 5 },
            6 => .{ 260, 0, 6 },
            7 => .{ 261, 0, 7 },
            8 => .{ 262, 0, 8 },
            9 => .{ 263, 0, 9 },
            10 => .{ 264, 0, 10 },
            11 => .{ 265, 1, 11 },
            12 => .{ 265, 1, 12 },
            13 => .{ 266, 1, 13 },
            14 => .{ 266, 1, 14 },
            15 => .{ 267, 1, 15 },
            16 => .{ 267, 1, 16 },
            17 => .{ 268, 1, 17 },
            18 => .{ 268, 1, 18 },
            19...22 => .{ 269, 2, 19 },
            23...26 => .{ 270, 2, 23 },
            27...30 => .{ 271, 2, 27 },
            31...34 => .{ 272, 2, 31 },
            35...42 => .{ 273, 3, 35 },
            43...50 => .{ 274, 3, 43 },
            51...58 => .{ 275, 3, 51 },
            59...66 => .{ 276, 3, 59 },
            67...82 => .{ 277, 4, 67 },
            83...98 => .{ 278, 4, 83 },
            99...114 => .{ 279, 4, 99 },
            115...130 => .{ 280, 4, 115 },
            131...162 => .{ 281, 5, 131 },
            163...194 => .{ 282, 5, 163 },
            195...226 => .{ 283, 5, 195 },
            227...257 => .{ 284, 5, 227 },
            258 => .{ 285, 0, 258 },
            else => unreachable,
        };
    }

    /// Map a distance onto a `{ code, bit_count, range_start }`
    ///      Extra           Extra               Extra
    /// Code Bits Dist  Code Bits   Dist     Code Bits Distance
    /// ---- ---- ----  ---- ----  ------    ---- ---- --------
    ///   0   0    1     10   4     33-48    20    9   1025-1536
    ///   1   0    2     11   4     49-64    21    9   1537-2048
    ///   2   0    3     12   5     65-96    22   10   2049-3072
    ///   3   0    4     13   5     97-128   23   10   3073-4096
    ///   4   1   5,6    14   6    129-192   24   11   4097-6144
    ///   5   1   7,8    15   6    193-256   25   11   6145-8192
    ///   6   2   9-12   16   7    257-384   26   12  8193-12288
    ///   7   2  13-16   17   7    385-512   27   12 12289-16384
    ///   8   3  17-24   18   8    513-768   28   13 16385-24576
    ///   9   3  25-32   19   8   769-1024   29   13 24577-32768
    fn lookup_distance(distance: u16) [3]u16 {
        return switch (distance) {
            1 => .{0, 0, 1},
            2 => .{1, 0, 2},
            3 => .{2, 0, 3},
            4 => .{3, 0, 4},
            5...6 => .{4, 1, 5},
            7...8 => .{5, 1, 7},
            9...12 => .{6, 2, 9},
            13...16 => .{7, 2, 13},
            17...24 => .{8, 3, 17},
            25...32 => .{9, 3, 25},
            33...48 => .{10, 4, 33},
            49...64 => .{11, 4, 49},
            65...96 => .{12, 5, 65},
            97...128 => .{13, 5, 97},
            129...192 => .{14, 6, 129},
            193...256 => .{15, 6, 193},
            257...384 => .{16, 7, 257},
            385...512 => .{17, 7, 385},
            513...768 => .{18, 8, 513},
            769...1024 => .{19, 8, 769},
            1025...1536 => .{20, 9, 1025},
            1537...2048 => .{21, 9, 1537},
            2049...3072 => .{22, 10, 2049},
            3073...4096 => .{23, 10, 3073},
            4097...6144 => .{24, 11, 4097},
            6145...8192 => .{25, 11, 6145},
            8193...12288 => .{26, 12, 8193},
            12289...16384 => .{27, 12, 12289},
            16385...24576 => .{28, 13, 16385},
            24577...32768 => .{29, 13, 24577},
            else => unreachable,
        };
    }

    /// Create a hashmap from each huffman code onto a literal.
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
    fn fixed_decoding_map(self: @This(), num_bits: u8) !std.AutoHashMap(u16, u16) {
        var huffman_map = std.AutoHashMap(u16, u16).init(self.allocator);
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

    fn read_byte(ctx: *CompressContext) !u8 {
        const b = try ctx.*.reader.readByte();
        
        ctx.*.processed_bits += 8;

        if (std.ascii.isPrint(b) and b != '\n') {
            log.debug(@src(), "Input read: '{c}'", .{b});
        } else {
            log.debug(@src(), "Input read: '0x{x}'", .{b});
        }

        return b;
    }

    fn write_bits(
        T: type,
        ctx: *CompressContext,
        value: T,
        num_bits: u16,
    ) !void {
        try ctx.bit_writer.writeBits(value, num_bits);
        Flate.print_bits(T, "Output write", value, num_bits);
        ctx.*.written_bits += num_bits;
    }

    fn write_token(ctx: *CompressContext, token: Token) !void {
        switch (ctx.block_type) {
            FlateBlockType.NO_COMPRESSION => {
                if (token.char) |c| {
                    try Flate.write_bits(u8, ctx, c, 8);
                }
                else {
                    return FlateError.MissingTokenLiteral;
                }
            },
            FlateBlockType.FIXED_HUFFMAN => {
                // Encode the token according to the static huffman code
                if (token.char) |char| {
                    // Lit Value    Bits        Codes
                    // ---------    ----        -----
                    //   0 - 143     8          00110000 through
                    //                          10111111
                    // 144 - 255     9          110010000 through
                    //                          111111111
                    if (char < 144) {
                        try Flate.write_bits(u8, ctx, 0b0011_0000 + char, 8);
                    }
                    else {
                        try Flate.write_bits(u9, ctx, 0b1_1001_0000 + @as(u9, char), 9);
                    }
                }
                else {
                    // Lookup the encoding for the token length
                    const r = Flate.lookup_length(token.length);
                    if (r[0] < 256 or r[0] > 285) {
                        return FlateError.InvalidLiteralLength;
                    }

                    // Translate the length to the corresponding code
                    //
                    // 256 - 279     7          000_0000 through
                    //                          001_0111
                    // 280 - 287     8          1100_0000 through
                    //                          1100_0111
                    if (r[0] < 280) {
                        // Write the huffman encoding of 'Code'
                        const hcode: u7 = @truncate(r[0] - 256);
                        try Flate.write_bits(u7, ctx, 0b000_0000 + hcode, 7);
                    }
                    else {
                        const hcode: u8 = @truncate(r[0] - 280);
                        try Flate.write_bits(u8, ctx, 0b1100_0000 + hcode, 8);
                    }

                    // Write the 'Extra Bits', i.e. the offset that indicate
                    // the exact offset to use in the range.
                    if (r[1] != 0) {
                        try Flate.write_bits(u16, ctx, token.length - r[2], r[1]);
                    }

                    // TODO: Write the distance encoding
                    //const d = Flate.lookup_distance(token.distance);
                    //try Flate.write_bits(u16, ctx, d[1], d[1]);
                }
            },
            FlateBlockType.DYNAMIC_HUFFMAN => {
                return FlateError.NotImplemented;
            },
            else => {
                return FlateError.UnexpectedBlockType;
            }
        }
    }

    pub fn compress(
        self: @This(),
        instream: std.fs.File,
        outstream: std.fs.File,
    ) !void {
        var done = false;
        var ctx = CompressContext {
            .block_type = FlateBlockType.FIXED_HUFFMAN,
            // XXX: Big-endian order bits need to be manually converted
            .bit_writer = std.io.bitWriter(writer_endian, outstream.writer().any()),
            .reader = instream.reader().any(),
            .written_bits = 0,
            .processed_bits = 0,
            // Initialize sliding window for backreferences
            .sliding_window = try std.RingBuffer.init(self.allocator, Flate.window_length),
            .lookahead = try self.allocator.alloc(u8, Flate.lookahead_length),
        };
        defer ctx.sliding_window.deinit(self.allocator);

        ctx.lookahead[0] = Flate.read_byte(&ctx) catch {
            return;
        };

        // Write block header
        try Flate.write_bits(u1, &ctx, @as(u1, 1), 1); // XXX bfinal
        try Flate.write_bits(u2, &ctx, @as(u2, @intFromEnum(ctx.block_type)), 2);
        try Flate.write_bits(u5, &ctx, @as(u5, 0), 5);

        while (!done) {
            // The current number of matches within the lookahead
            var match_cnt: u8 = 0;
            // Max number of matches in the lookahead this iteration
            // XXX: The byte at the `longest_match_cnt` index is not part
            // of the match!
            var longest_match_length: u8 = 0;
            var longest_match_distance: u16 = 0;

            // Look for matches in the sliding_window
            const win_len: u16 = @truncate(ctx.sliding_window.len());
            for (0..win_len) |i| {
                const ring_index = (ctx.sliding_window.read_index + i) % 
                                   Flate.window_length;
                if (ctx.lookahead[match_cnt] != ctx.sliding_window.data[ring_index]) {
                    // Reset and start matching from the beginning of the
                    // lookahead again.
                    match_cnt = 0;
                    continue;
                }

                match_cnt += 1;

                // When `match_cnt` exceeds `longest_match_cant` we
                // need to feed another byte into the lookahead.
                if (match_cnt <= longest_match_length) {
                    continue;
                }

                // Update the longest match
                longest_match_length = match_cnt;
                const win_idx: u16 = @truncate(i);
                longest_match_distance = (win_len - win_idx) + (match_cnt - 1);

                if (longest_match_length == win_len) {
                    // Lookahead is filled
                    break;
                }

                ctx.lookahead[longest_match_length] = Flate.read_byte(&ctx) catch {
                    done = true;
                    break;
                };
                log.debug(@src(), "Extending lookahead {d} item(s)", .{longest_match_length});
            }

            // Update the sliding window with the longest match
            // we will write `longest_match_length` characters in all cases
            // except for when there were no matches at all, in that case we will
            // just write a single byte.
            const end = if (longest_match_length == 0) 1 else longest_match_length;
            for (0..end) |i| {
                try Flate.window_write(&ctx.sliding_window, ctx.lookahead[i]);
            }

            if (longest_match_length <= 3) {
                // Prefer raw characters when the match length is <= 3
                for (0..end) |i| {
                    const token = Token {
                        .char = ctx.lookahead[i],
                        .length = 0,
                        .distance = 0
                    };
                    log.debug(@src(), "token(literal): {any}", .{token});
                    try Flate.write_token(&ctx, token);
                }
            }
            else {
                const token = Token {
                    .char = null,
                    .length = longest_match_length,
                    .distance = longest_match_distance
                };
                log.debug(@src(), "token(ref    ): {any}", .{token});
                try Flate.write_token(&ctx, token);
            }

            // Set starting byte for next iteration
            if (longest_match_length == 0 or
                longest_match_length == Flate.lookahead_length)
            {
                // We need a new byte
                ctx.lookahead[0] = Flate.read_byte(&ctx) catch {
                    done = true;
                    break;
                };
            } else {
                // The `next_char` should be passed to the next iteration
                ctx.lookahead[0] = ctx.lookahead[longest_match_length];
            }
        }

        // End-of-block marker (with static huffman encoding: 0000_000 -> 256)
        try Flate.write_bits(u7, &ctx, @as(u7, 0), 7);

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

    fn window_write(window: *std.RingBuffer, c: u8) !void {
        if (window.isFull()) {
            _ = window.read();
        }
        if (std.ascii.isPrint(c) and c != '\n') {
            log.debug(@src(), "Window write: '{c}'", .{c});
        } else {
            log.debug(@src(), "Window write: '0x{x}'", .{c});
        }
        try window.write(c);
    }

    fn print_bits(
        comptime T: type,
        comptime prefix: []const u8,
        bits: T,
        num_bits: usize,
    ) void {
        switch (num_bits) {
            7 => 
                log.debug(
                    @src(),
                    "{s}: 0b{b:0>7} ({d}) [{d} bits]",
                    .{prefix, bits, bits, num_bits}
                ),
            8 => 
                log.debug(
                    @src(),
                    "{s}: 0b{b:0>8} ({d}) [{d} bits]",
                    .{prefix, bits, bits, num_bits}
                ),
            else => 
                log.debug(
                    @src(),
                    "{s}: 0b{b} ({d}) [{d} bits]",
                    .{prefix, bits, bits, num_bits}
                ),
        }
    }

    fn read_bits(
        ctx: *DecompressContext,
        comptime T: type,
        num_bits: u16,
    ) !T {
        const bits = ctx.*.bit_reader.readBitsNoEof(T, num_bits) catch |e| {
            return e;
        };

        Flate.print_bits(T, "Input read", bits, num_bits);
        
        ctx.*.processed_bits += num_bits;

        return bits;
    }

    pub fn decompress(
        self: @This(),
        instream: std.fs.File,
        outstream: std.fs.File,
    ) !void {
        var done = false;
        var ctx = DecompressContext {
            .block_type = FlateBlockType.NO_COMPRESSION,
            .writer = outstream.writer().any(),
            .bit_reader = std.io.bitReader(writer_endian, instream.reader().any()),
            .written_bits = 0,
            .processed_bits = 0,
            .sliding_window = try std.RingBuffer.init(self.allocator, Flate.window_length)
        };
        defer ctx.sliding_window.deinit(self.allocator);

        // Make sure to start from the beginning in both streams
        try instream.seekTo(0);
        try outstream.seekTo(0);

        // Decode the stream
        while (!done) {
            const bfinal = Flate.read_bits(&ctx, u1, 1) catch {
                return;
            };

            if (bfinal == 1) {
                log.debug(@src(), "End-of-stream marker found", .{});
                done = true;
            }

            const block_type_bits = Flate.read_bits(&ctx, u2, 2) catch {
                return FlateError.UnexpectedEof;
            };


            // Read up to the next byte boundary
            while (ctx.processed_bits % 8 != 0) {
                _ = Flate.read_bits(&ctx, u1, 1) catch {
                    return FlateError.UnexpectedEof;
                };
            }

            ctx.block_type = @enumFromInt(block_type_bits);
            log.debug(@src(), "Decoding type-{d} block", .{block_type_bits});
            switch (ctx.block_type) {
                FlateBlockType.NO_COMPRESSION => {
                    // Read block length
                    const block_size = try Flate.read_bits(&ctx, u16, 16);
                    // Skip over ones-complement of length
                    _ = try Flate.read_bits(&ctx, u16, 16);
                    // Write bytes as-is to output stream
                    for (0..block_size) |_| {
                        const b = Flate.read_bits(&ctx, u8, 8) catch {
                            return FlateError.UnexpectedEof;
                        };
                        try Flate.window_write(&ctx.sliding_window, b);
                        try ctx.writer.writeByte(b);
                    }
                },
                FlateBlockType.FIXED_HUFFMAN => {
                    return self.decompress_fixed_code(&ctx);
                },
                FlateBlockType.DYNAMIC_HUFFMAN => {
                    return FlateError.NotImplemented;
                },
                else => {
                    return FlateError.UnexpectedBlockType;
                }
            }
        }

        log.debug(
            @src(),
            "Decompression done: {} [{} bytes] -> {} bits [{} bytes]",
            .{ctx.processed_bits, ctx.processed_bits / 8, 
              ctx.written_bits, ctx.written_bits / 8}
        );
    }

    fn decompress_fixed_code(
        self: @This(),
        ctx: *DecompressContext,
    ) !void {
        const seven_bit_decode = try self.fixed_decoding_map(7);
        const eight_bit_decode = try self.fixed_decoding_map(8);
        const nine_bit_decode = try self.fixed_decoding_map(9);
        while (true) {
            const b = blk: {
                var key = Flate.read_bits(ctx, u16, 7) catch {
                    return FlateError.UnexpectedEof;
                };

                if (seven_bit_decode.get(key)) |char| {
                    break :blk char;
                }

                // Read one more bit and try the 8-bit value
                //  0b0111100 [7 bits] -> 0b0111100(x) [8 bits]
                var bit = Flate.read_bits(ctx, u1, 1) catch {
                    return FlateError.UnexpectedEof;
                };
                key = (key << 1) | @as(u16, bit);

                if (eight_bit_decode.get(key)) |char| {
                    break :blk char;
                }

                // Read one more bit and try the 9-bit value
                //  0b01111001 [8 bits] -> 0b01111001(x) [9 bits]
                bit = Flate.read_bits(ctx, u1, 1) catch {
                    return FlateError.UnexpectedEof;
                };
                key = (key << 1) | @as(u16, bit);

                if (nine_bit_decode.get(key)) |char| {
                    break :blk char;
                }

                return FlateError.UndecodableBitStream;
            };

            if (b < 256) {
                const c: u8 = @truncate(b);
                try Flate.window_write(&ctx.sliding_window, c);
                try ctx.*.writer.writeByte(c);
            }
            else if (b == 256) {
                log.debug(@src(), "End-of-block marker found", .{});
                break;
            }
            else if (b < 285) {
                log.debug(@src(), "backref: {d}", .{b});
                // Decode 
            }
            else {
                return FlateError.InvalidLiteralLength;
            }
        }
    }
};

