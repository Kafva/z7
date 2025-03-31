const std = @import("std");
const log = @import("log.zig");
const util = @import("util.zig");

const Flate = @import("flate.zig").Flate;
const FlateBlockType = @import("flate.zig").FlateBlockType;
const FlateError = @import("flate.zig").FlateError;
const Token = @import("flate.zig").Token;
const TokenEncoding = @import("flate.zig").TokenEncoding;

const CompressContext = struct {
    allocator: std.mem.Allocator,
    /// The current type of block to write
    block_type: FlateBlockType,
    bit_writer: std.io.BitWriter(Flate.writer_endian, std.io.AnyWriter),
    reader: std.io.AnyReader,
    written_bits: usize,
    processed_bits: usize,
    sliding_window: std.RingBuffer,
    lookahead: []u8,
};

pub const FlateCompress = struct {
    pub fn compress(
        allocator: std.mem.Allocator,
        instream: std.fs.File,
        outstream: std.fs.File,
    ) !void {
        var done = false;
        var ctx = CompressContext {
            .allocator = allocator,
            .block_type = FlateBlockType.FIXED_HUFFMAN,
            // XXX: Big-endian order bits need to be manually converted
            .bit_writer = std.io.bitWriter(Flate.writer_endian, outstream.writer().any()),
            .reader = instream.reader().any(),
            .written_bits = 0,
            .processed_bits = 0,
            // Initialize sliding window for backreferences
            .sliding_window = try std.RingBuffer.init(allocator, Flate.window_length),
            .lookahead = try allocator.alloc(u8, Flate.lookahead_length),
        };
        defer ctx.sliding_window.deinit(allocator);

        ctx.lookahead[0] = FlateCompress.read_byte(&ctx) catch {
            return;
        };

        // Write block header
        try FlateCompress.write_bits(u1, &ctx, @as(u1, 1), 1); // XXX bfinal
        try FlateCompress.write_bits(u2, &ctx, @as(u2, @intFromEnum(ctx.block_type)), 2);
        try FlateCompress.write_bits(u5, &ctx, @as(u5, 0), 5);

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

                ctx.lookahead[longest_match_length] = FlateCompress.read_byte(&ctx) catch {
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
                    try FlateCompress.write_token(&ctx, token);
                }
            }
            else {
                const token = Token {
                    .char = null,
                    .length = longest_match_length,
                    .distance = longest_match_distance
                };
                log.debug(@src(), "token(ref    ): {any}", .{token});
                try FlateCompress.write_token(&ctx, token);
            }

            // Set starting byte for next iteration
            if (longest_match_length == 0 or
                longest_match_length == Flate.lookahead_length)
            {
                // We need a new byte
                ctx.lookahead[0] = FlateCompress.read_byte(&ctx) catch {
                    done = true;
                    break;
                };
            } else {
                // The `next_char` should be passed to the next iteration
                ctx.lookahead[0] = ctx.lookahead[longest_match_length];
            }
        }

        // End-of-block marker (with static huffman encoding: 0000_000 -> 256)
        try FlateCompress.write_bits(u7, &ctx, @as(u7, 0), 7);

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

    fn write_bits(
        T: type,
        ctx: *CompressContext,
        value: T,
        num_bits: u16,
    ) !void {
        try ctx.bit_writer.writeBits(value, num_bits);
        util.print_bits(T, "Output write", value, num_bits);
        ctx.*.written_bits += num_bits;
    }

    fn write_token(ctx: *CompressContext, token: Token) !void {
        switch (ctx.block_type) {
            FlateBlockType.NO_COMPRESSION => {
                if (token.char) |c| {
                    try FlateCompress.write_bits(u8, ctx, c, 8);
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
                        try FlateCompress.write_bits(u8, ctx, 0b0011_0000 + char, 8);
                    }
                    else {
                        try FlateCompress.write_bits(u9, ctx, 0b1_1001_0000 + @as(u9, char), 9);
                    }
                }
                else {
                    // Lookup the encoding for the token length
                    const enc = token.lookup_length();
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
                        try FlateCompress.write_bits(u7, ctx, 0b000_0000 + hcode, 7);
                    }
                    else {
                        const hcode: u8 = @truncate(enc.code - 280);
                        try FlateCompress.write_bits(u8, ctx, 0b1100_0000 + hcode, 8);
                    }

                    // Write the 'Extra Bits', i.e. the offset that indicate
                    // the exact offset to use in the range.
                    if (enc.code != 0) {
                        try FlateCompress.write_bits(
                            u16,
                            ctx,
                            token.length - enc.range_start,
                            enc.bit_count
                        );
                    }

                    // Write the 'Distance' encoding
                    const denc = token.lookup_distance();
                    const denc_code: u5 = @truncate(denc.code);
                    try FlateCompress.write_bits(u5, ctx, denc_code, 5);

                    // Write the offset bits for the distance
                    if (denc.bit_count != 0) {
                        try FlateCompress.write_bits(
                            u16,
                            ctx,
                            token.distance - denc.range_start,
                            denc.bit_count
                        );
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
};

