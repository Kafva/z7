const std = @import("std");
const util = @import("util.zig");
const log = @import("log.zig");

const HuffmanEncoding = @import("huffman.zig").HuffmanEncoding;
const HuffmanError = @import("huffman.zig").HuffmanError;
const HuffmanContext = @import("huffman.zig").HuffmanContext;

/// The metadata provided to re-create the Huffman encoding used during
/// block type-2 compression is essentially an array of these items, i.e.
/// a symbol and a description of how long its Huffman code should be.
pub const HuffmanCLToken = struct {
    symbol_value: u16,
    bit_shift: u4,

    /// Priority sort comparison method (ascending):
    ///
    /// First: Sort based on symbol_value (ascending, lesser first)
    /// Second: Sort based on bit_shift (ascending, lesser first)
    /// Example:
    ///
    /// { .symbol_value = 0, .bit_shift = 2,  }
    /// { .symbol_value = 2, .bit_shift = 3,  }
    /// { .symbol_value = 3, .bit_shift = 3,  }
    /// { .symbol_value = 4, .bit_shift = 3,  }
    /// { .symbol_value = 5, .bit_shift = 2,  }
    /// { .symbol_value = 6, .bit_shift = 3,  }
    ///
    /// Returns true if `lhs` should be placed before `rhs`.
    pub fn less_than(_: void, lhs: @This(), rhs: @This()) bool {
        if (lhs.symbol_value == rhs.symbol_value) {
            // Smaller bit_shift, should be before `rhs`
            return lhs.bit_shift < rhs.bit_shift;
        }
        // Ignore bit_shift if symbol_value differs
        return lhs.symbol_value < rhs.symbol_value;
    }

};

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
            util.print_char(log.debug, "Output write", c);
            enc.bits = 0;
            enc.bit_shift = 0;
        }
    }
}

fn read_bit(ctx: *HuffmanDecompressContext) !u16 {
    const bit = try ctx.bit_reader.readBitsNoEof(u16, 1);
    util.print_bits(log.trace, u16, "Input read", bit, 1, ctx.processed_bits);
    ctx.processed_bits += 1;
    return bit;
}

/// Given an array of code lengths for each symbol in ascending order from 
/// `[0, symbol_max]`, construct the corresponding canonical Huffman code for 
/// decoding according to the algorithm in 3.2.2 of the DEFLATE RFC.
pub fn reconstruct_canonical_code(
    allocator: *const std.mem.Allocator,
    dec_map: *std.AutoHashMap(HuffmanEncoding, u16),
    code_lengths: []const u4,
    symbol_max: usize
) !void {
    if (symbol_max > code_lengths.len) {
        return HuffmanError.InternalError;
    }

    var sorted_code_lengths = try allocator.alloc(HuffmanCLToken, symbol_max);

    // Create a sorted version of the code_length array
    for (0..symbol_max) |i| {
        sorted_code_lengths[i] = HuffmanCLToken {
            .symbol_value = @truncate(i),
            .bit_shift = code_lengths[i]
        };
    }
    std.sort.insertion(HuffmanCLToken, sorted_code_lengths, {}, HuffmanCLToken.less_than);

    // 1. Count how many entries there are for each code length (bit length)
    var max_seen_bits: u4 = 0;
    var bit_length_counts = try allocator.*.alloc(u16, sorted_code_lengths.len);
    @memset(bit_length_counts, 0);

    for (sorted_code_lengths) |t| {
        if (t.bit_shift == 0) continue;
        if (t.bit_shift > max_seen_bits) max_seen_bits = t.bit_shift;

        bit_length_counts[t.bit_shift] += 1;
    }

    // 2. For each bit length (up to the maximum we observed in step 1),
    // determine the starting code value.
    var next_code = try allocator.*.alloc(u16, sorted_code_lengths.len);
    @memset(next_code, 0);

    var code: u16 = 0;
    for (1..max_seen_bits + 1) |i| {
        // Starting code is based of previous bit length code
        code = (code + bit_length_counts[i-1]) << 1;
        next_code[i] = code;
    }

    // 3. Assign numerical values to all codes, using consecutive values for
    // all codes of the same length with the base values determined at the
    // previous step
    for (sorted_code_lengths) |cl| {
        if (cl.bit_shift == 0) continue;

        const enc = HuffmanEncoding {
            .bits = next_code[cl.bit_shift],
            .bit_shift = cl.bit_shift,
        };
        try dec_map.*.putNoClobber(enc, cl.symbol_value);

        next_code[cl.bit_shift] += 1;
    }

    log.debug(@src(), "Canonical decoding [0..{d}]:", .{symbol_max});
    dump_decodings(dec_map, symbol_max);
}

fn dump_decodings(
    dec_map: *const std.AutoHashMap(HuffmanEncoding, u16),
    symbol_max: usize,
) void {
    var lowest: u16 = 0;
    // Hack to print decodings in ascending order, do not run this on release
    while (lowest < symbol_max) {
        var found: bool = false;
        var keys = dec_map.keyIterator();
        while (keys.next()) |enc| {
            if (dec_map.get(enc.*)) |symbol| {
                if (symbol == lowest) {
                    enc.dump_mapping(symbol);
                    found = true;
                    lowest += 1;
                }
            }
        }
        if (!found) lowest += 1;
    }
}
