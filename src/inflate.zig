const std = @import("std");
const log = @import("log.zig");
const util = @import("util.zig");

const Flate = @import("flate.zig").Flate;
const FlateBlockType = @import("flate.zig").FlateBlockType;
const FlateError = @import("flate.zig").FlateError;
const Token = @import("flate.zig").Token;
const TokenEncoding = @import("flate.zig").TokenEncoding;

const InflateError = error {
    UndecodableBitStream,
};

const InflateContext = struct {
    allocator: std.mem.Allocator,
    /// The current type of block to decode
    block_type: FlateBlockType,
    writer: std.io.AnyWriter,
    bit_reader: std.io.BitReader(Flate.writer_endian, std.io.AnyReader),
    written_bits: usize,
    processed_bits: usize,
    /// Cache of the last 32K read bytes to support backreferences
    sliding_window: std.RingBuffer,
};

pub const Inflate = struct {
    pub fn decompress(
        allocator: std.mem.Allocator,
        instream: std.fs.File,
        outstream: std.fs.File,
    ) !void {
        var done = false;
        var ctx = InflateContext {
            .allocator = allocator,
            .block_type = FlateBlockType.NO_COMPRESSION,
            .writer = outstream.writer().any(),
            .bit_reader = std.io.bitReader(Flate.writer_endian, instream.reader().any()),
            .written_bits = 0,
            .processed_bits = 0,
            .sliding_window = try std.RingBuffer.init(allocator, Flate.window_length)
        };
        defer ctx.sliding_window.deinit(allocator);

        // Make sure to start from the beginning in both streams
        try instream.seekTo(0);
        try outstream.seekTo(0);

        // Decode the stream
        while (!done) {
            const bfinal = Inflate.read_bits(&ctx, u1, 1) catch {
                return;
            };

            if (bfinal == 1) {
                log.debug(@src(), "End-of-stream marker found", .{});
                done = true;
            }

            const block_type_bits = Inflate.read_bits(&ctx, u2, 2) catch {
                return FlateError.UnexpectedEof;
            };


            // Read up to the next byte boundary
            while (ctx.processed_bits % 8 != 0) {
                _ = Inflate.read_bits(&ctx, u1, 1) catch {
                    return FlateError.UnexpectedEof;
                };
            }

            ctx.block_type = @enumFromInt(block_type_bits);
            log.debug(@src(), "Decoding type-{d} block", .{block_type_bits});
            switch (ctx.block_type) {
                FlateBlockType.NO_COMPRESSION => {
                    // Read block length
                    const block_size = try Inflate.read_bits(&ctx, u16, 16);
                    // Skip over ones-complement of length
                    _ = try Inflate.read_bits(&ctx, u16, 16);
                    // Write bytes as-is to output stream
                    for (0..block_size) |_| {
                        const b = Inflate.read_bits(&ctx, u8, 8) catch {
                            return FlateError.UnexpectedEof;
                        };
                        try Flate.window_write(&ctx.sliding_window, b);
                        try ctx.writer.writeByte(b);
                    }
                },
                FlateBlockType.FIXED_HUFFMAN => {
                    return Inflate.decompress_fixed_code(&ctx);
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
        ctx: *InflateContext,
    ) !void {
        const seven_bit_decode = try Inflate.fixed_literal_length_decoding(ctx, 7);
        const eight_bit_decode = try Inflate.fixed_literal_length_decoding(ctx, 8);
        const nine_bit_decode = try Inflate.fixed_literal_length_decoding(ctx, 9);
        while (true) {
            const b = blk: {
                var key = Inflate.read_bits(ctx, u16, 7) catch {
                    return FlateError.UnexpectedEof;
                };

                if (seven_bit_decode.get(key)) |char| {
                    break :blk char;
                }

                // Read one more bit and try the 8-bit value
                //  0b0111100 [7 bits] -> 0b0111100(x) [8 bits]
                var bit = Inflate.read_bits(ctx, u1, 1) catch {
                    return FlateError.UnexpectedEof;
                };
                key = (key << 1) | @as(u16, bit);

                if (eight_bit_decode.get(key)) |char| {
                    break :blk char;
                }

                // Read one more bit and try the 9-bit value
                //  0b01111001 [8 bits] -> 0b01111001(x) [9 bits]
                bit = Inflate.read_bits(ctx, u1, 1) catch {
                    return FlateError.UnexpectedEof;
                };
                key = (key << 1) | @as(u16, bit);

                if (nine_bit_decode.get(key)) |char| {
                    break :blk char;
                }

                return InflateError.UndecodableBitStream;
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

                // Get the corresponding `TokenEncoding` for the 'Code'
                const enc = TokenEncoding.from_length_code(b);

                // 2. Determine the length of the match
                const length: u16 = blk: {
                    if (enc.bit_count != 0) {
                        // Parse extra bits for the offset
                        const bits = Inflate.read_bits(ctx, u16, enc.bit_count) catch {
                            return FlateError.UnexpectedEof;
                        };
                        const offset: u16 = @intCast(bits);
                        break :blk enc.range_start + offset;
                    } else {
                        break :blk enc.range_start;
                    }
                };

                // 3. Determine the distance for the match
                const distance_code = Inflate.read_bits(ctx, u5, 5) catch {
                    return FlateError.UnexpectedEof;
                };
                const denc = TokenEncoding.from_distance_code(distance_code);

                const distance: u16 = blk: {
                    if (denc.bit_count != 0) {
                        // Parse extra bits for the offset
                        const bits = Inflate.read_bits(ctx, u16, denc.bit_count) catch {
                            return FlateError.UnexpectedEof;
                        };
                        const offset: u16 = @intCast(bits);
                        break :blk denc.range_start + offset;
                    } else {
                        break :blk denc.range_start;
                    }
                };

                const write_index = ctx.sliding_window.write_index;
                const start_index = try Inflate.window_start_index(write_index, distance);
                for (start_index..start_index + length) |i| {
                    const c: u8 = ctx.sliding_window.data[i];
                    try ctx.*.writer.writeByte(c);
                    log.debug(@src(), "backref[{}]: '{c}'", .{i, c});
                }
                

            }
            else {
                return FlateError.InvalidLiteralLength;
            }
        }
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
    fn fixed_literal_length_decoding(
        ctx: *InflateContext,
        num_bits: u8,
    ) !std.AutoHashMap(u16, u16) {
        var huffman_map = std.AutoHashMap(u16, u16).init(ctx.allocator);
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

    /// Get the starting index of a back reference at `distance` backwards
    /// into the sliding window.
    fn window_start_index(write_index: usize, distance: u16) !usize {
        if (distance > Flate.window_length) {
            log.err(@src(), "Distance too large: {d} >= {d}", .{ distance, Flate.window_length });
            return FlateError.InvalidDistance;
        }

        const write_index_i: i64 = @intCast(write_index);
        const distance_i: i64 = @intCast(distance);
        const window_length_i: i64 = @intCast(Flate.window_length);

        const s: i64 = write_index_i - distance_i;

        const s_usize: usize = @intCast(s + window_length_i);

        return s_usize % Flate.window_length;
    }

    fn read_bits(
        ctx: *InflateContext,
        comptime T: type,
        num_bits: u16,
    ) !T {
        const bits = ctx.*.bit_reader.readBitsNoEof(T, num_bits) catch |e| {
            return e;
        };

        util.print_bits(T, "Input read", bits, num_bits);

        ctx.*.processed_bits += num_bits;

        return bits;
    }
};

