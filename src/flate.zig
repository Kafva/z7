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
};

const FlateError = error {
    UnexpectedBlockType,
    MissingTokenLiteral,
};

const FlateBlockType = enum(u2) {
    NO_COMPRESSION = 0b00,
    FIXED_HUFFMAN = 0b01,
    DYNAMIC_HUFFMAN = 0b10,
    RESERVED = 0b11,
};

const FlateContext = struct {
    sliding_window: std.RingBuffer,
    lookahead: []u8,
    /// The current type of block to write
    block_type: FlateBlockType,
    writer: std.io.AnyWriter,
    reader: std.io.AnyReader,
};

pub const Flate = struct {
    allocator: std.mem.Allocator,
    block_size: usize,

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

    fn write_token(ctx: FlateContext, token: Token) !void {
        var le_writer = std.io.bitWriter(.little, ctx.writer);
        switch (ctx.block_type) {
            FlateBlockType.NO_COMPRESSION => {
                if (token.char) |c| {
                    try le_writer.writeBits(c, 8);
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
                        try le_writer.writeBits(0b0011_0000 + char, 8);
                    }
                    else {
                        try le_writer.writeBits(0b1_1001_0000 + @as(u9, char), 9);
                    }
                }
                else {
                    // Translate the length to the corresponding code
                    const r = Flate.lookup_length(token.length);
                    if (r[0] < 256 or r[0] > 285) unreachable;

                    // 256 - 279     7          000_0000 through
                    //                          001_0111
                    // 280 - 287     8          1100_0000 through
                    //                          1100_0111
                    if (r[0] < 280) {
                        // Write the huffman encoding of 'Code'
                        const hcode: u7 = @truncate(r[0] - 256);
                        try le_writer.writeBits(0b000_0000 + hcode, 7);
                    }
                    else {
                        const hcode: u8 = @truncate(r[0] - 280);
                        try le_writer.writeBits(0b1100_0000 + hcode, 8);
                    }

                    // Write the 'Extra Bits'
                    if (r[1] != 0) {
                        try le_writer.writeBits(token.length - r[2], r[1]);
                    }
                }
            },
            else => unreachable,
        }
    }

    pub fn compress(
        self: @This(),
        instream: std.fs.File,
        outstream: std.fs.File,
    ) !void {
        var done = false;
        var ctx = FlateContext {
            // Initialize sliding window for backreferences
            .sliding_window = try std.RingBuffer.init(self.allocator, Flate.window_length),
            .lookahead = try self.allocator.alloc(u8, Flate.lookahead_length),
            .block_type = FlateBlockType.FIXED_HUFFMAN,
            .writer = outstream.writer().any(),
            .reader = instream.reader().any(),
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


            if (longest_match_length <= 3) {
                // Prefer raw characters when the match length is <= 3
                for (0..longest_match_length) |i| {
                    const token = Token {
                        .char = ctx.lookahead[i],
                        .length = 0,
                        .distance = 0
                    };
                    log.debug(@src(), "token: {any}", .{token});
                    try Flate.write_token(ctx, token);
                }
            }
            else {
                // TODO
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
    }

    fn window_write(window: *std.RingBuffer, c: u8) !void {
        if (window.isFull()) {
            _ = window.read();
        }
        try window.write(c);
    }

    pub fn decompress(
        instream: std.fs.File,
        outstream: std.fs.File,
    ) !void {
        // The input stream position should point to the last input element
        const total_bits = (try instream.getPos()) * 8;

        // Start from the first element in both streams
        try instream.seekTo(0);
        try outstream.seekTo(0);

        var reader = std.io.bitReader(.little, instream.reader());
        const writer = outstream.writer();

        var read_bits: usize = 0;
        var last_block = false;

        // Decode the stream
        while (read_bits < total_bits) {
            const bfinal = reader.readBitsNoEof(u1, 1) catch {
                return;
            };
            read_bits += 1;

            if (bfinal == 1) {
                last_block = true;
            }

            const bits = reader.readBitsNoEof(u2, 1) catch {
                return;
            };
            read_bits += 2;

            _ = reader.readBitsNoEof(u5, 5) catch {
                return;
            };
            read_bits += 5;

            const btype: FlateBlockType = @enumFromInt(bits);
            switch (btype) {
                FlateBlockType.NO_COMPRESSION => {
                    // Read block length
                    const block_size = try reader.readBitsNoEof(u16, 16);
                    // Skip over ones-complement of length
                    _ = try reader.readBitsNoEof(u16, 16);
                    // Write bytes as-is to output stream
                    for (0..block_size) |_| {
                        const b = reader.readBitsNoEof(u8, 8) catch {
                            return;
                        };
                        read_bits += 8;
                        try writer.writeByte(b);
                    }
                },
                FlateBlockType.DYNAMIC_HUFFMAN => {
                    //try huffman.decompress(instream, outstream);
                },
                FlateBlockType.FIXED_HUFFMAN => {
                },
                else => {
                    log.err(@src(), "Invalid inflate block type {b}", .{bits});
                    return FlateError.UnexpectedBlockType;
                }
            }
        }
    }
};

