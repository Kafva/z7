const std = @import("std");
const util = @import("util.zig");
const log = @import("log.zig");

const HuffmanEncoding = @import("huffman.zig").HuffmanEncoding;
const HuffmanError = @import("huffman.zig").HuffmanError;
const HuffmanContext = @import("huffman.zig").HuffmanContext;

const HuffmanDecompressContext = struct {
    dec_map: *const std.AutoHashMap(HuffmanEncoding, u16),
    instream: *const std.fs.File,
    outstream: *const std.fs.File,
    /// Decompression requires a bit_reader
    bit_reader: std.io.BitReader(.little, std.io.AnyReader),
    writer: std.io.AnyWriter,
    processed_bits: usize,
};

pub fn decompress(
    dec_map: *const std.AutoHashMap(HuffmanEncoding, u16),
    encoded_length: usize,
    instream: *const std.fs.File,
    outstream: *const std.fs.File,
) !void {
    var ctx = HuffmanDecompressContext {
        .instream = instream,
        .outstream = outstream,
        .bit_reader = std.io.bitReader(.little, instream.reader().any()),
        .writer = outstream.writer().any(),
        .processed_bits = 0,
        .dec_map = dec_map,
    };

    // Start from the first element in both streams
    try ctx.instream.seekTo(0);
    try ctx.outstream.seekTo(0);

    var enc = HuffmanEncoding {
        .bits = 0,
        .bit_shift = 0,
    };
    while (ctx.processed_bits < encoded_length) {
        const bit = read_bit(&ctx) catch {
            break;
        };
        if (enc.bit_shift == 15) {
            return HuffmanError.BadEncoding;
        }

        // The most-significant bit is read first
        enc.bits = (enc.bits << 1) | bit;
        enc.bit_shift += 1;

        if (ctx.dec_map.get(enc)) |v| {
            if (v >= 256) {
                return HuffmanError.BadEncoding;
            }
            const c: u8 = @truncate(v);
            try ctx.writer.writeByte(c);
            util.print_char("Output write", c);
            enc.bits = 0;
            enc.bit_shift = 0;
        }
    }
}

fn read_bit(ctx: *HuffmanDecompressContext) !u16 {
    const bit = try ctx.bit_reader.readBitsNoEof(u16, 1);
    util.print_bits(u16, "Input read", bit, 1, ctx.processed_bits);
    ctx.processed_bits += 1;
    return bit;
}
