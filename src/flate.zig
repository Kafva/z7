const std = @import("std");
const log = @import("log.zig");

const FlateCodeword = struct {
    length: u8,
    distance: u16,
    char: u8,
};

const FlateError = error {
    UnexpectedBlockType,
};

const FlateBlockType = enum(u2) {
    NO_COMPRESSION = 0b00,
    FIXED_HUFFMAN = 0b01,
    DYNAMIC_HUFFMAN = 0b10,
    RESERVED = 0b11,
};

const FlateContext = struct {
    sliding_window: std.RingBuffer,
    lookahead: []u8
};

pub const Flate = struct {
    allocator: std.mem.Allocator,
    block_size: usize,
    window_length: usize,
    lookahead_length: usize,

    pub fn compress(
        self: @This(),
        instream: std.fs.File,
        outstream: std.fs.File,
    ) !void {
        var ctx = FlateContext {
            // Initialize sliding window for backreferences
            .sliding_window = try std.RingBuffer.init(self.allocator, self.window_length),
            .lookahead = try self.allocator.alloc(u8, self.lookahead_length),
        };
        defer ctx.sliding_window.deinit(self.allocator);

        while (try self.compress_block(ctx, instream, outstream)) {}
    }

    fn compress_block(
        self: @This(),
        ctx: FlateContext,
        instream: std.fs.File,
        outstream: std.fs.File,
    ) !bool {
        // var bit_writer = std.io.bitWriter(.little, outstream.writer());
        // const reader = instream.reader();
        _ = self;
        _ = ctx;
        _ = instream;
        _ = outstream;

        return false;
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
        var writer = outstream.writer();

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

