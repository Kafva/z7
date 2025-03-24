const std = @import("std");
const log = @import("log.zig");


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
                return writer.print("{{ .length = {d}, .distance = {d}, .char = '{c}' }}",
                                  .{self.length, self.distance, char});
            } else {
                return writer.print("{{ .length = {d}, .distance = {d}, .char = 0x{x} }}",
                                  .{self.length, self.distance, char});
            }
        } else {
            return writer.print("{{ .length = {d}, .distance = {d} }}", .{self.length, self.distance});
        }
    }
};

const FlateError = error {
    NotImplemented,
    UnexpectedBlockType,
    UnexpectedEof,
    InvalidLiteralLength,
    MissingTokenLiteral,
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
    writer: std.io.AnyWriter,
    reader: std.io.AnyReader,
    written_bits: usize,
    sliding_window: std.RingBuffer,
    lookahead: []u8,
};

const DecompressContext = struct {
    /// The current type of block to decode
    block_type: FlateBlockType,
    writer: std.io.AnyWriter,
    reader: std.io.AnyReader,
    written_bits: usize,
    read_bits: usize,
    /// Cache of the last 32K read bytes to support backreferences
    sliding_window: std.RingBuffer,
};

pub const Flate = struct {
    allocator: std.mem.Allocator,

    const lookahead_length: usize = 258;
    const window_length: usize = std.math.pow(usize, 2, 15);

    /// Map a match length onto a `{ encoded_value, bit_count, range_start }`
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

    fn write_bits(
        ctx: *CompressContext,
        comptime endian: std.builtin.Endian,
        value: anytype,
        num_bits: u16,
    ) !void {
        var bit_writer = std.io.bitWriter(endian, ctx.*.writer);
        try bit_writer.writeBits(value, num_bits);
        ctx.*.written_bits += num_bits;
    }

    fn write_token(ctx: *CompressContext, token: Token) !void {
        switch (ctx.block_type) {
            FlateBlockType.NO_COMPRESSION => {
                if (token.char) |c| {
                    try Flate.write_bits(ctx, .little, c, 8);
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
                        try Flate.write_bits(ctx, .little, 0b0011_0000 + char, 8);
                    }
                    else {
                        try Flate.write_bits(ctx, .little, 0b1_1001_0000 + @as(u9, char), 9);
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
                        try Flate.write_bits(ctx, .little, 0b000_0000 + hcode, 7);
                    }
                    else {
                        const hcode: u8 = @truncate(r[0] - 280);
                        try Flate.write_bits(ctx, .little, 0b1100_0000 + hcode, 8);
                    }

                    // Write the 'Extra Bits'
                    if (r[1] != 0) {
                        try Flate.write_bits(ctx, .little, token.length - r[2], r[1]);
                    }
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
            .writer = outstream.writer().any(),
            .reader = instream.reader().any(),
            .written_bits = 0,
            // Initialize sliding window for backreferences
            .sliding_window = try std.RingBuffer.init(self.allocator, Flate.window_length),
            .lookahead = try self.allocator.alloc(u8, Flate.lookahead_length),
        };
        defer ctx.sliding_window.deinit(self.allocator);

        ctx.lookahead[0] = ctx.reader.readByte() catch {
            return;
        };

        while (!done) {
            // The current number of matches within the lookahead
            var match_cnt: u8 = 0;
            // Max number of matches in the lookahead this iteration
            // XXX: The byte at the `longest_match_cnt` index is not part
            // of the match!
            var longest_match_length: u8 = 0;
            var longest_match_distance: u16 = 0;

            // Look for matches in the sliding_window
            const win_len: u8 = @truncate(ctx.sliding_window.len());
            for (0..win_len) |i| {
                const ring_index = (ctx.sliding_window.read_index + i) % Flate.window_length;
                if (ctx.lookahead[match_cnt] != ctx.sliding_window.data[ring_index]) {
                    // Reset and start matching from the beginning of the
                    // lookahead again.
                    match_cnt = 0;
                    continue;
                }

                match_cnt += 1;

                if (match_cnt <= longest_match_length) {
                    continue;
                }

                // Update the longest match
                longest_match_length = match_cnt;
                const win_index: u8 = @truncate(i);
                longest_match_distance = (win_len - win_index) + (match_cnt - 1);

                if (longest_match_length == Flate.lookahead_length) {
                    // Lookahead is filled
                    break;
                }

                // When `match_cnt` exceeds `longest_match_cant` we
                // need to feed another byte into the lookahead.
                ctx.lookahead[longest_match_length] = ctx.reader.readByte() catch {
                    done = true;
                    break;
                };
            }

            // Update the sliding window with the longest match
            // we will write `longest_match_length` characters in all cases
            // except for when there were no matches at all, in that case we will
            // just write a single byte.
            const end = if (longest_match_length == 0) 1 else longest_match_length;
            for (0..end) |i| {
                try Flate.window_write(&ctx.sliding_window, ctx.lookahead[i]);
            }

            if (ctx.block_type == FlateBlockType.NO_COMPRESSION or 
                longest_match_length <= 3) {
                // TODO write block headers

                // Prefer raw characters when the match length is <= 3
                for (0..longest_match_length) |i| {
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
                ctx.lookahead[0] = ctx.reader.readByte() catch {
                    done = true;
                    break;
                };
            } else {
                // The `next_char` should be passed to the next iteration
                ctx.lookahead[0] = ctx.lookahead[longest_match_length];
            }
        }

        // Incomplete bytes will be padded when flushing, wait until all
        // writes are done.
        var le_writer = std.io.bitWriter(.little, ctx.writer);
        try le_writer.flushBits();
        log.debug(@src(), "Wrote {} bits [{} bytes]", .{ctx.written_bits, ctx.written_bits / 8});
    }

    fn window_write(window: *std.RingBuffer, c: u8) !void {
        if (window.isFull()) {
            _ = window.read();
        }
        try window.write(c);
    }

    fn read_bits(
        ctx: *DecompressContext,
        comptime endian: std.builtin.Endian,
        comptime T: type,
        num_bits: u16,
    ) !T {
        var bit_reader = std.io.bitReader(endian, ctx.*.reader);
        const bits = bit_reader.readBitsNoEof(T, num_bits) catch |e| {
            return e;
        };
        ctx.*.read_bits += num_bits;

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
            .reader = instream.reader().any(),
            .written_bits = 0,
            .read_bits = 0,
            .sliding_window = try std.RingBuffer.init(self.allocator, Flate.window_length)
        };
        defer ctx.sliding_window.deinit(self.allocator);

        // Make sure to start from the beginning in both streams
        try instream.seekTo(0);
        try outstream.seekTo(0);

        // Decode the stream
        while (!done) {
            const bfinal = Flate.read_bits(&ctx, .little, u1, 1) catch {
                return;
            };

            if (bfinal == 1) {
                log.debug(@src(), "End-of-stream marker found", .{});
                done = true;
            }

            const bits = Flate.read_bits(&ctx, .little, u2, 2) catch {
                return FlateError.UnexpectedEof;
            };


            // Read up to the next byte boundary
            while (ctx.read_bits % 8 != 0) {
                _ = Flate.read_bits(&ctx, .little, u1, 1) catch {
                    return FlateError.UnexpectedEof;
                };
            }

            ctx.block_type = @enumFromInt(bits);
            log.debug(@src(), "Decoding 0b{b} block", .{bits});
            switch (ctx.block_type) {
                FlateBlockType.NO_COMPRESSION => {
                    // Read block length
                    const block_size = try Flate.read_bits(&ctx, .little, u16, 16);
                    // Skip over ones-complement of length
                    _ = try Flate.read_bits(&ctx, .little, u16, 16);
                    // Write bytes as-is to output stream
                    for (0..block_size) |_| {
                        const b = Flate.read_bits(&ctx, .little, u8, 8) catch {
                            return FlateError.UnexpectedEof;
                        };
                        try Flate.window_write(&ctx.sliding_window, b);
                        try ctx.writer.writeByte(b);
                    }
                },
                FlateBlockType.FIXED_HUFFMAN => {
                    // loop (until end of block code recognized)
                    //    decode literal/length value from input stream
                    //    if value < 256
                    //       copy value (literal byte) to output stream
                    //    otherwise
                    //       if value = end of block (256)
                    //          break from loop
                    //       otherwise (value = 257..285)
                    //          decode distance from input stream

                    //          move backwards distance bytes in the output
                    //          stream, and copy length bytes from this
                    //          position to the output stream.
                    // end loop


                    // while (true) {
                    //     const bit = Flate.read_bits(&ctx, .little, u1, 1) catch {
                    //         return FlateError.UnexpectedEof;
                    //     };

                    //     try Flate.window_write(&ctx.*.sliding_window, b);
                    // }
                    return FlateError.NotImplemented;
                },
                FlateBlockType.DYNAMIC_HUFFMAN => {
                    return FlateError.NotImplemented;
                },
                else => {
                    return FlateError.UnexpectedBlockType;
                }
            }
        }

        var le_writer = std.io.bitWriter(.little, ctx.writer);
        try le_writer.flushBits();
        log.debug(@src(), "Read {} bits [{} bytes]", .{ctx.read_bits, ctx.read_bits / 8});
        log.debug(@src(), "Wrote {} bits [{} bytes]", .{ctx.written_bits, ctx.written_bits / 8});
    }
};

