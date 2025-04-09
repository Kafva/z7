const std = @import("std");
const log = @import("log.zig");

const Node = @import("huffman.zig").Node;
const NodeEncoding = @import("huffman.zig").NodeEncoding;
const HuffmanError = @import("huffman.zig").HuffmanError;
const HuffmanContext = @import("huffman.zig").HuffmanContext;

const HuffmanDecompressContext = struct {
    /// Backing array for Huffman tree nodes
    array: *const std.ArrayList(Node),
    instream: *const std.fs.File,
    outstream: *const std.fs.File,
    /// Decompression requires a bit_reader
    bit_reader: std.io.BitReader(.little, std.io.AnyReader),
    writer: std.io.AnyWriter,
    processed_bits: usize,
};

pub fn decompress(
    array: *const std.ArrayList(Node),
    instream: *const std.fs.File,
    outstream: *const std.fs.File,
) !void {
    var ctx = HuffmanDecompressContext {
        .instream = instream,
        .outstream = outstream,
        .bit_reader = std.io.bitReader(.little, instream.reader().any()),
        .writer = outstream.writer().any(),
        .processed_bits = 0,
        .array = array
    };

    // Start from the first element in both streams
    try ctx.instream.seekTo(0);
    try ctx.outstream.seekTo(0);

    if (ctx.array.items.len == 0) {
        return;
    }

    while (true) {
        const char = walk_decode(&ctx, ctx.array.items.len - 1) catch |err| {
            log.err(@src(), "Decoding error: {any}", .{err});
            break;
        };

        if (char) |c| {
            try ctx.writer.writeByte(c);
        } else {
            break;
        }
    }
}

/// Read bits from the `reader` and return decoded bytes.
fn walk_decode(ctx: *HuffmanDecompressContext, index: usize) !?u8 {
    const bit = ctx.bit_reader.readBitsNoEof(u1, 1) catch {
        return null;
    };
    ctx.processed_bits += 1;

    const left_child_index = ctx.array.items[index].left_child_index;
    const right_child_index = ctx.array.items[index].right_child_index;

    if (left_child_index == null and right_child_index == null) {
        // Reached leaf
        if (ctx.array.items[index].char) |char| {
            return char;
        } else {
            log.err(@src(), "Missing character from leaf node", .{});
            return HuffmanError.BadTreeStructure;
        }

    } else {
        switch (bit) {
            0 => {
                if (left_child_index) |child_index| {
                    return try walk_decode(ctx, child_index);
                } else {
                    return HuffmanError.UnexpectedEncodedSymbol;
                }
            },
            1 => {
                if (right_child_index) |child_index| {
                    return try walk_decode(ctx, child_index);
                } else {
                    return HuffmanError.UnexpectedEncodedSymbol;
                }
            }
        }
    }
}
