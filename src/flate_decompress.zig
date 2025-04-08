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
    UnexpectedNLenBytes
};

pub const Decompress = struct {
    allocator: std.mem.Allocator,
    crc: *std.hash.Crc32,
    instream: *const std.fs.File,
    outstream: *const std.fs.File,
    /// The current type of block to decode
    block_type: FlateBlockType,
    writer: std.io.AnyWriter,
    bit_reader: std.io.BitReader(Flate.writer_endian, std.io.AnyReader),
    start_offset: usize,
    written_bits: usize,
    processed_bits: usize,
    /// Cache of the last 32K read bytes to support backreferences
    sliding_window: RingBuffer(u8),
    /// Fixed huffman decoding maps
    seven_bit_decode: std.AutoHashMap(u16, u16),
    eight_bit_decode: std.AutoHashMap(u16, u16),
    nine_bit_decode: std.AutoHashMap(u16, u16),

    pub fn init(
        allocator: std.mem.Allocator,
        instream: *const std.fs.File,
        outstream: *const std.fs.File,
        start_offset: usize,
        crc: *std.hash.Crc32,
    ) !@This() {
        return @This() {
            .allocator = allocator,
            .crc = crc,
            .instream = instream,
            .outstream = outstream,
            .block_type = FlateBlockType.RESERVED,
            .writer = outstream.writer().any(),
            .bit_reader = std.io.bitReader(Flate.writer_endian, instream.reader().any()),
            .start_offset = start_offset,
            .written_bits = 0,
            .processed_bits = 0,
            .sliding_window = try RingBuffer(u8).init(allocator, Flate.window_length),
            .seven_bit_decode = try Decompress.fixed_code_decoding_map(allocator, 7),
            .eight_bit_decode = try Decompress.fixed_code_decoding_map(allocator, 8),
            .nine_bit_decode = try Decompress.fixed_code_decoding_map(allocator, 9),
        };
    }

    pub fn decompress(self: *@This()) !void {
        var done = false;

        // We may want to start from an offset in the input stream
        log.debug(@src(), "Seeking to {} byte offset", .{self.start_offset});
        try self.instream.seekTo(self.start_offset);

        // Always start from the beginning in the output stream
        try self.outstream.seekTo(0);

        while (!done) {
            const header = try self.read_bits(u3, 3);

            if ((header & 1) == 1) {
                log.debug(@src(), "Last block marker found", .{});
                done = true;
            }

            const block_type_int: u2 = @truncate(header >> 1);
            self.block_type = @enumFromInt(block_type_int);

            log.debug(@src(), "Reading type-{d} block", .{block_type_int});
            switch (self.block_type) {
                FlateBlockType.NO_COMPRESSION => {
                    try self.no_compression_decompress_block();
                },
                FlateBlockType.FIXED_HUFFMAN => {
                    try self.fixed_code_decompress_block();
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
            .{self.processed_bits, self.processed_bits / 8,
              self.written_bits, self.written_bits / 8}
        );
    }

    fn no_compression_decompress_block(
        self: *@This(),
    ) !void {
        // Shift out zeroes up until the next byte boundary
        while (self.processed_bits % 8 != 0) {
            const b = try self.read_bits(u1, 1);
            if (b != 0) {
                log.err(
                    @src(),
                    "Found non-zero padding bit at {} bit offset",
                    .{self.processed_bits}
                );
            }
        }

        // Read block length
        const block_size = try self.read_bits(u16, 16);
        const block_size_compl = try self.read_bits(u16, 16);
        if (~block_size != block_size_compl) {
            return DecompressError.UnexpectedNLenBytes;
        }
        log.debug(@src(), "Decompressing {d} bytes from type-0 block", .{block_size});

        // Write bytes as-is to output stream
        for (0..block_size) |_| {
            const b = self.read_bits(u8, 8) catch {
                return FlateError.UnexpectedEof;
            };
            try self.write_byte(b);
        }
    }

    fn fixed_code_decompress_block(
        self: *@This(),
    ) !void {
        while (true) {
            const b = blk: {
                var key = self.read_bits_be(7) catch {
                    return FlateError.UnexpectedEof;
                };

                if (self.seven_bit_decode.get(key)) |char| {
                    log.debug(@src(), "Matched 0b{b:0>7}", .{key});
                    break :blk char;
                }

                // Read one more bit and try the 8-bit value
                //   0111100    [7 bits]
                //   0111100(x) [8 bits]
                var bit = self.read_bits(u1, 1) catch {
                    return FlateError.UnexpectedEof;
                };
                key <<= 1;
                key |= bit;

                if (self.eight_bit_decode.get(key)) |char| {
                    log.debug(@src(), "Matched 0b{b:0>8}", .{key});
                    break :blk char;
                }

                // Read one more bit and try the 9-bit value
                //  01111001    [8 bits]
                //  01111001(x) [9 bits]
                bit = self.read_bits(u1, 1) catch {
                    return FlateError.UnexpectedEof;
                };
                key <<= 1;
                key |= bit;

                if (self.nine_bit_decode.get(key)) |char| {
                    log.debug(@src(), "Matched 0b{b:0>9}", .{key});
                    break :blk char;
                }

                return DecompressError.UndecodableBitStream;
            };

            if (b < 256) {
                const c: u8 = @truncate(b);
                try self.write_byte(c);
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
                        const offset = self.read_bits(u16, enc.bit_count) catch {
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
                const distance_code = self.read_bits(u5, 5) catch {
                    return FlateError.UnexpectedEof;
                };
                const denc = TokenEncoding.from_distance_code(distance_code);
                log.debug(@src(), "backref(distance-code): {d}", .{distance_code});

                const distance: u16 = blk: {
                    if (denc.bit_count != 0) {
                        // Parse extra bits for the offset
                        const offset = self.read_bits(u16, denc.bit_count) catch {
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
                    const c: u8 = try self.sliding_window.read_offset_end(distance);
                    // Write each byte to the output stream AND the the sliding window
                    try self.write_byte(c);
                    log.debug(@src(), "backref[{} - {}]: '{c}'", .{distance, i, c});
                }
            }
            else {
                return FlateError.InvalidLiteralLength;
            }
        }
    }

    /// Read bits with the configured bit-ordering from the input stream
    fn read_bits(
        self: *@This(),
        comptime T: type,
        num_bits: u16,
    ) !T {
        const bits = self.bit_reader.readBitsNoEof(T, num_bits) catch |e| {
            return e;
        };
        const offset = self.start_offset + @divFloor(self.processed_bits, 8);
        util.print_bits(T, "Input read", bits, num_bits, offset);
        self.processed_bits += num_bits;
        return bits;
    }

    /// This stream: 11110xxx xxxxx000 should be interpreted as 0b01111_000
    fn read_bits_be(
        self: *@This(),
        num_bits: u16,
    ) !u16 {
        var out: u16 = 0;
        for (1..num_bits) |i_usize| {
            const i: u4 = @intCast(i_usize);
            const shift_by: u4 = @intCast(num_bits - i);

            const bit = try self.read_bits(u16, 1);
            out |= bit << shift_by;
        }

        // Final bit
        const bit = try self.read_bits(u16, 1);
        out |= bit;

        return out;
    }

    fn write_byte(self: *@This(), c: u8) !void {
        self.sliding_window.push(c);
        try self.writer.writeByte(c);
        util.print_char("Output write", c);
        self.written_bits += 8;

        // The crc in the trailer of the gzip format is performed on the
        // original input file calculate the crc for the output file we are
        // writing incrementally as we process each byte.
        const bytearr = [1]u8 { c };
        self.crc.update(&bytearr);
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
    fn fixed_code_decoding_map(
        allocator: std.mem.Allocator,
        num_bits: u8,
    ) !std.AutoHashMap(u16, u16) {
        var huffman_map = std.AutoHashMap(u16, u16).init(allocator);
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
};

