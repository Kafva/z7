const std = @import("std");
const log = @import("log.zig");
const util = @import("util.zig");

const Flate = @import("flate.zig").Flate;
const FlateBlockType = @import("flate.zig").FlateBlockType;
const FlateError = @import("flate.zig").FlateError;
const Token = @import("flate.zig").Token;
const TokenEncoding = @import("flate.zig").TokenEncoding;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;

const DecompressError = error {
    UndecodableBitStream,
};

const DecompressContext = struct {
    allocator: std.mem.Allocator,
    /// The current type of block to decode
    block_type: FlateBlockType,
    writer: std.io.AnyWriter,
    bit_reader: std.io.BitReader(Flate.writer_endian, std.io.AnyReader),
    written_bits: usize,
    processed_bits: usize,
    /// Cache of the last 32K read bytes to support backreferences
    sliding_window: RingBuffer(u8),
};

pub const Decompress = struct {
    pub fn decompress(
        allocator: std.mem.Allocator,
        instream: std.fs.File,
        outstream: std.fs.File,
    ) !void {
        var done = false;
        var ctx = DecompressContext {
            .allocator = allocator,
            .block_type = FlateBlockType.NO_COMPRESSION,
            .writer = outstream.writer().any(),
            .bit_reader = std.io.bitReader(Flate.writer_endian, instream.reader().any()),
            .written_bits = 0,
            .processed_bits = 0,
            .sliding_window = try RingBuffer(u8).init(allocator, Flate.window_length)
        };

        // Make sure to start from the beginning in both streams
        try instream.seekTo(0);
        try outstream.seekTo(0);

        // Decode the stream
        while (!done) {
            const bfinal = Decompress.read_bits(&ctx, u1, 1) catch {
                return;
            };

            if (bfinal == 1) {
                log.debug(@src(), "Last block marker found", .{});
                done = true;
            }

            const block_type_int = Decompress.read_bits_integer(&ctx, u2, u1, 2) catch {
                return FlateError.UnexpectedEof;
            };

            // Read up to the next byte boundary
            while (ctx.processed_bits % 8 != 0) {
                _ = Decompress.read_bits(&ctx, u1, 1) catch {
                    return FlateError.UnexpectedEof;
                };
            }

            ctx.block_type = @enumFromInt(block_type_int);
            log.debug(@src(), "Decoding type-{d} block", .{block_type_int});
            switch (ctx.block_type) {
                FlateBlockType.NO_COMPRESSION => {
                    // Read block length
                    const block_size = try Decompress.read_bits(&ctx, u16, 16);
                    // Skip over ones-complement of length
                    _ = try Decompress.read_bits(&ctx, u16, 16);
                    // Write bytes as-is to output stream
                    for (0..block_size) |_| {
                        const b = Decompress.read_bits(&ctx, u8, 8) catch {
                            return FlateError.UnexpectedEof;
                        };
                        ctx.sliding_window.push(b);
                        try ctx.writer.writeByte(b);
                    }
                },
                FlateBlockType.FIXED_HUFFMAN => {
                    return Decompress.fixed_code_decompress_block(&ctx);
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

    fn fixed_code_decompress_block(
        ctx: *DecompressContext,
    ) !void {
        const seven_bit_decode = try Decompress.fixed_code_decoding_map(ctx, 7);
        const eight_bit_decode = try Decompress.fixed_code_decoding_map(ctx, 8);
        const nine_bit_decode = try Decompress.fixed_code_decoding_map(ctx, 9);
        while (true) {
            const b = blk: {
                var key = Decompress.read_bits(ctx, u16, 7) catch {
                    return FlateError.UnexpectedEof;
                };

                if (seven_bit_decode.get(key)) |char| {
                    break :blk char;
                }

                // Read one more bit and try the 8-bit value
                //  0b0111100 [7 bits] -> 0b0111100(x) [8 bits]
                var bit = Decompress.read_bits(ctx, u1, 1) catch {
                    return FlateError.UnexpectedEof;
                };
                key = (key << 1) | @as(u16, bit);

                if (eight_bit_decode.get(key)) |char| {
                    break :blk char;
                }

                // Read one more bit and try the 9-bit value
                //  0b01111001 [8 bits] -> 0b01111001(x) [9 bits]
                bit = Decompress.read_bits(ctx, u1, 1) catch {
                    return FlateError.UnexpectedEof;
                };
                key = (key << 1) | @as(u16, bit);

                if (nine_bit_decode.get(key)) |char| {
                    break :blk char;
                }

                return DecompressError.UndecodableBitStream;
            };

            if (b < 256) {
                const c: u8 = @truncate(b);
                ctx.sliding_window.push(c);
                try ctx.writer.writeByte(c);
            }
            else if (b == 256) {
                log.debug(@src(), "End-of-block marker found", .{});
                break;
            }
            else if (b < 285) {
                log.debug(@src(), "backref(length-code): {d}", .{b});

                // Get the corresponding `TokenEncoding` for the 'Code'
                const enc = TokenEncoding.from_length_code(b);

                // 2. Determine the length of the match
                const length: u16 = blk: {
                    if (enc.bit_count != 0) {
                        // Parse extra bits for the offset
                        const offset = Decompress.read_bits_integer(ctx, u16, u4, enc.bit_count) catch {
                            return FlateError.UnexpectedEof;
                        };
                        log.debug(@src(), "backref(length-offset): {d}", .{offset});
                        break :blk enc.range_start + offset;
                    } else {
                        log.debug(@src(), "backref(length-offset): 0", .{});
                        break :blk enc.range_start;
                    }
                };
                log.debug(@src(), "backref(length): {d}", .{length});

                // 3. Determine the distance for the match
                const distance_code = Decompress.read_bits(ctx, u5, 5) catch {
                    return FlateError.UnexpectedEof;
                };
                const denc = TokenEncoding.from_distance_code(distance_code);
                log.debug(@src(), "backref(distance-code): {d}", .{distance_code});

                const distance: u16 = blk: {
                    if (denc.bit_count != 0) {
                        // Parse extra bits for the offset
                        const offset = Decompress.read_bits_integer(ctx, u16, u4, denc.bit_count) catch {
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

                for (0..length) |i| {
                    // Since we add one byte every iteration the offset is
                    // always equal to the distance
                    const c: u8 = try ctx.sliding_window.read_offset_end(distance);
                    // Write each byte to the output stream AND the the sliding window
                    try ctx.writer.writeByte(c);
                    ctx.sliding_window.push(c);
                    log.debug(@src(), "backref[{} - {}]: '{c}'", .{distance, i, c});
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
    fn fixed_code_decoding_map(
        ctx: *DecompressContext,
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

    fn read_bits(
        ctx: *DecompressContext,
        comptime T: type,
        num_bits: u16,
    ) !T {
        const bits = ctx.bit_reader.readBitsNoEof(T, num_bits) catch |e| {
            return e;
        };

        util.print_bits(T, "Input read", bits, num_bits);
        ctx.processed_bits += num_bits;

        return bits;
    }

    /// Read `num_bits` bits from the input stream interpreted as a
    /// `.little` endian integer, the bit_writer is assumed to be a `.big`
    /// endian reader.
    /// E.g. The bit stream [0,1,1] will be interpreted as a 0b110 (6)
    fn read_bits_integer(
        ctx: *DecompressContext,
        comptime T: type,
        comptime V: type,
        num_bits: u16,
    ) !T {
        const one: T = 1;
        var integer: T = 0;
        var i: u16 = 0;
        while (i < num_bits) {
            const bit = ctx.bit_reader.readBitsNoEof(u1, 1) catch |e| {
                return e;
            };
            if (bit == 1) {
                // Each read bit will be more significant, shift with a higher
                // value for each iteration.
                const shift: V = @intCast(i);
                integer |= (one << shift);
            }

            i += 1;
        }

        util.print_bits(T, "Input read little-endian integer", integer, num_bits);
        ctx.processed_bits += num_bits;

        return integer;
    }
};

