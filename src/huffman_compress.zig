const std = @import("std");
const util = @import("util.zig");
const log = @import("log.zig");

const HuffmanEncoding = @import("huffman.zig").HuffmanEncoding;
const HuffmanError = @import("huffman.zig").HuffmanError;
const color_base = @import("huffman.zig").color_base;

pub const HuffmanTreeNode = struct {
    /// Only leaf nodes contain a character
    maybe_value: ?u16,
    freq: usize,
    /// A lower weight has lower priority (minimum weight is 0).
    /// The maximum weight represents the maximum depth of the tree,
    /// a higher weight should be placed higher up in the tree.
    weight: u4,
    maybe_left_child_index: ?usize,
    maybe_right_child_index: ?usize,

    /// Priority sort comparison method (descending):
    ///
    /// First: Sort based on weight (descending, greater first)
    /// Second: Sort based on frequency (descending, greater first)
    /// Example:
    /// [
    ///     { .weight = 1, .freq = 3 },
    ///     { .weight = 1, .freq = 2 },
    ///     { .weight = 1, .freq = 1 },
    ///     { .weight = 0, .freq = 3 },
    ///     { .weight = 0, .freq = 2 },
    ///     { .weight = 0, .freq = 1 },
    /// ]
    ///
    /// When constructing the tree we want to pop items from the *tail* of the queue.
    /// We exhaust the nodes with lowest remaining weight with the lowest frequency first.
    /// Returns true if `lhs` should be placed before `rhs`.
    pub fn greater_than(_: void, lhs: @This(), rhs: @This()) bool {
        // If the lhs node has the same values as the rhs, move it up as more recent,
        // this is needed for the fixed Huffman construction to be correct.
        if (lhs.weight == rhs.weight) {
            // Greater frequency further in the front
            return lhs.freq >= rhs.freq;
        }
        // Ignore frequency if the weights differ
        return lhs.weight >= rhs.weight;
    }

    pub fn format(
        self: *const @This(),
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype
    ) !void {
        if (fmt.len != 0) {
            return std.fmt.invalidFmtError(fmt, self);
        }

        if (self.maybe_value) |value| {
            if (value < 256) {
                const char: u8 = @truncate(value);
                if (std.ascii.isPrint(char) and char != '\n') {
                    return writer.print("{{ .weight = {d}, .freq = {d}, .value = '{c}' }}",
                                      .{self.weight, self.freq, char});
                } else {
                    return writer.print("{{ .weight = {d}, .freq = {d}, .value = 0x{x} }}",
                                      .{self.weight, self.freq, char});
                }
            }
            else {
                return writer.print("{{ .weight = {d}, .freq = {d}, .value = 0x{x} }}",
                                  .{self.weight, self.freq, value});
            }
        } else {
            return writer.print("{{ .weight = {d}, .freq = {d} }}", .{self.weight, self.freq});
        }
    }

    pub fn dump(self: @This(), comptime weight: u4, pos: []const u8) void {
        const istty = std.io.getStdErr().isTty();
        const prefix = util.repeat('-', weight) catch unreachable;
        if (istty) {
            const side_color: u8 = if (std.mem.eql(u8, "1", pos)) 37 else 97;
            const color: u8 = color_base + @as(u8, weight);
            log.debug(
                @src(),
                "\x1b[{d}m`{s}{s}\x1b[0m: \x1b[38;5;{d}m{any}\x1b[0m",
                .{side_color, prefix, pos, color, self}
            );
        }
        else {
            log.debug(@src(), "`{s}{s}: {any}", .{prefix, pos, self});
        }
        std.heap.page_allocator.free(prefix);
    }
};

const HuffmanCompressContext = struct {
    allocator: std.mem.Allocator,
    /// The maximum value of symbols from the input stream, 256 for regular
    /// input from a file, 286 for deflate literal/lengths.
    symbol_max: u16,
    written_bits: usize,
    /// The frequency of each symbol to use when constructing the code
    frequencies: []usize,
    /// Mappings from symbols onto Huffman encodings, the index
    /// represents the original symbol value.
    enc_map: []?HuffmanEncoding,
    /// Backing array for Huffman tree nodes
    array: std.ArrayList(HuffmanTreeNode),
};

pub fn compress(
    allocator: std.mem.Allocator,
    enc_len: *usize,
    symbol_max: u16,
    instream: std.fs.File,
    outstream: std.fs.File,
) !std.AutoHashMap(HuffmanEncoding, u16) {
    const reader = instream.reader();
    var bit_writer = std.io.bitWriter(.little, outstream.writer().any());
    var ctx = HuffmanCompressContext {
        .allocator = allocator,
        .symbol_max = symbol_max,
        .written_bits = 0,
        .frequencies = try allocator.alloc(usize, symbol_max),
        .enc_map = try allocator.alloc(?HuffmanEncoding, symbol_max),
        // The array will grow if the capacity turns out to be too low
        .array = try std.ArrayList(HuffmanTreeNode).initCapacity(allocator, 2*symbol_max),
    };
    @memset(ctx.frequencies, 0);

    // Get frequencies from the input stream
    const symbol_count = try calculate_frequencies(&ctx, instream, reader);
    dump_frequencies(&ctx);

    const dec_map = try build_huffman_tree(&ctx, symbol_count);

    if (ctx.array.items.len == 0) {
        log.debug(@src(), "Nothing to compress", .{});
        return dec_map;
    }

    // Write the translations to the output stream
    while (true) {
        const c = reader.readByte() catch {
            break;
        };
        if (ctx.enc_map[@intCast(c)]) |enc| {
            try write_bits_be(&ctx, &bit_writer, enc.bits, enc.bit_shift);
            util.print_char(log.debug, "Encoded", c);
        } else {
            log.err(@src(), "Unexpected byte: 0x{x}", .{c});
            return HuffmanError.UnexpectedCharacter;
        }
    }

    try bit_writer.flushBits();
    log.debug(@src(), "Wrote {} bits [{} bytes]", .{ctx.written_bits, ctx.written_bits / 8});

    // The decoder needs to know the exact number of bits, otherwise the extra
    // padding from flushing to a full byte will be read as garbage.
    enc_len.* = ctx.written_bits;
    return dec_map;
}

pub fn build_encoding(
    allocator: std.mem.Allocator,
    enc_map: *[]?HuffmanEncoding,
    frequencies: []usize,
    frequencies_cnt: usize,
) !void {
    const symbol_max: u16 = @intCast(frequencies.len);
    var ctx = HuffmanCompressContext {
        .allocator = allocator,
        .symbol_max = symbol_max,
        .written_bits = 0,
        .frequencies = frequencies,
        .enc_map = try allocator.alloc(?HuffmanEncoding, symbol_max),
        .array = try std.ArrayList(HuffmanTreeNode).initCapacity(allocator, 2*symbol_max),
    };

    log.debug(@src(), "Building encoding for {{0..{d}}}", .{symbol_max});
    _ = try build_huffman_tree(&ctx, frequencies_cnt);

    // Save the encoding
    for (0..ctx.enc_map.len) |i| {
        enc_map.*[i] = ctx.enc_map[i];
    }
}

/// Assumes that `ctx.frequencies` has already been populated
fn build_huffman_tree(
    ctx: *HuffmanCompressContext,
    symbol_count: usize,
) !std.AutoHashMap(HuffmanEncoding, u16) {
    // Create a queue of nodes to place into the tree
    var queue = try ctx.allocator.alloc(HuffmanTreeNode, symbol_count);
    var index: usize = 0;
    for (0..ctx.frequencies.len) |i| {
        const v: u16 = @truncate(i);
        if (ctx.frequencies[v] == 0) {
            continue;
        }
        queue[index] = HuffmanTreeNode {
            .maybe_value = v,
            .weight = 15, // placeholder
            .freq = ctx.frequencies[v],
            .maybe_left_child_index = undefined,
            .maybe_right_child_index = undefined
        };
        // Sort in descending order with the highest frequency+weight first
        index += 1;
        std.sort.insertion(HuffmanTreeNode, queue[0..index], {}, HuffmanTreeNode.greater_than);
    }
    log.debug(@src(), "{{0..{d}}}: Initial node count: {}", .{ctx.symbol_max, symbol_count});

    // Create the tree, we need to make sure that we do not grow
    // the tree deeper than 15 levels so that every leaf can be encoded
    // with a u16.
    //
    // Level 0: 2^0 nodes
    // Level 1: 2^1 nodes
    // Level 2: 2^2 nodes
    // ...
    // Level 15: 2^15 nodes
    //
    // Iterative approach, try to create a tree with all slots filled up to depth x
    // On failure, try again with all slots up to depth x+1, etc.
    const maxdepth_start = blk: {
        if (symbol_count == 0) {
            break :blk 0;
        }
        // log2(queue_count) + 1 will give us the maxdepth at which all of our nodes
        // fit on the lowest depth, we start from one depth before this.
        break :blk std.math.log2(symbol_count);
    };
    for (maxdepth_start..16) |i| {
        construct_max_depth_tree(ctx, &queue, symbol_count, @truncate(i)) catch |e| {
            if (e == HuffmanError.MaxDepthInsufficent and i < 15) {
                continue;
            }
            return e;
        };
        log.debug(@src(), "Successfully constructed Huffman tree (maxdepth {})", .{i});
        break;
    }
    log.debug(@src(), "{{0..{d}}}: Complete tree node count: {}", .{ctx.symbol_max, ctx.array.items.len});

    // Build the canonical version of the encoding
    try build_canonical_encoding(ctx);

    // Return the decoding map
    var dec_map = std.AutoHashMap(HuffmanEncoding, u16).init(ctx.allocator);
    // enc_map: Symbol       -> Huffman bits
    // dec_map: Huffman bits -> Symbol
    for (0..ctx.enc_map.len) |i| {
        if (ctx.enc_map[i]) |enc| {
            const v: u16 = @truncate(i);
            try dec_map.putNoClobber(enc, v);
        }
    }

    if (ctx.array.items.len > 0) {
        log.debug(@src(), "{{0..{d}}}: Non-canonical tree:", .{ctx.symbol_max});
        dump_tree(ctx, 0, ctx.array.items.len - 1);

        log.debug(@src(), "{{0..{d}}}: Canonical encodings:", .{ctx.symbol_max});
        dump_encodings(ctx.enc_map);
    }

    return dec_map;
}

/// Construct a Huffman tree from `queue_initial` into `array` which does
/// not exceed the provided `max_depth`, returns an error if the provided
/// `max_depth` is insufficient.
fn construct_max_depth_tree(
    ctx: *HuffmanCompressContext,
    queue_initial: *[]HuffmanTreeNode,
    queue_initial_cnt: usize,
    max_depth: u4,
) !void {
    var queue_cnt: usize = queue_initial_cnt;
    var array_cnt: usize = 0;
    var filled_cnt: usize = 0;
    var current_depth: u4 = max_depth;
    var queue = try ctx.allocator.alloc(HuffmanTreeNode, queue_initial_cnt);

    // Start from an empty array
    ctx.array.clearRetainingCapacity();

    // Let all nodes start at the bottom (lowest possible weight value)
    for (0..queue_initial_cnt) |i| {
        queue[i] = HuffmanTreeNode {
            .maybe_value = queue_initial.*[i].maybe_value,
            .weight = 0,
            .freq = queue_initial.*[i].freq,
            .maybe_left_child_index = null,
            .maybe_right_child_index = null
        };
    }

    while (queue_cnt > 0) {
        if (current_depth == 0) {
            if (queue_cnt > 1) {
                log.debug(
                    @src(),
                    "Huffman tree depth of {} is insufficient: {} nodes left",
                    .{max_depth, queue_cnt}
                );
                return HuffmanError.MaxDepthInsufficent;
            }
        }

        if (queue_cnt == 1) {
            // OK: last node from the priority queue has already been given children,
            // just save it and quit.
            try ctx.array.append(queue[0]);
            queue_cnt -= 1;
            array_cnt += 1;
            continue;
        }

        if (filled_cnt == std.math.pow(usize, 2, current_depth)) {
            // OK: current depth has been filled
            filled_cnt = 0;
            current_depth -= 1;
            continue;
        }

        // Current depth has not been filled, pick the two nodes with the lowest frequency
        // for the current depth value
        const left_child = queue[queue_cnt - 2];
        const right_child = queue[queue_cnt - 1];

        // The parent node will be one level higher than the children (child weight + 1)
        // Pick the child with the weight closest to the top (max_depth)
        const parent_weight = if (left_child.weight > right_child.weight) left_child.weight + 1
                             else right_child.weight + 1;

        // Save the children from the queue into the backing array
        // XXX: the backing array is unsorted, the tree structure is derived from each `HuffmanTreeNode`
        try ctx.array.append(left_child);
        try ctx.array.append(right_child);
        array_cnt += 2;
        filled_cnt += 2;

        // Create the parent node
        // We always create parent nodes with both child positions filled,
        // the child pointers of this node will not change after creation.
        const parent_node = HuffmanTreeNode {
            .maybe_value = null,
            .freq = left_child.freq + right_child.freq,
            .weight = parent_weight,
            .maybe_left_child_index = array_cnt - 2,
            .maybe_right_child_index = array_cnt - 1
        };

        // Insert the parent node into the priority queue, overwriting
        // one of the children and dropping the other
        queue_cnt -= 1;
        queue[queue_cnt - 1] = parent_node;
        std.sort.insertion(HuffmanTreeNode, queue[0..queue_cnt], {}, HuffmanTreeNode.greater_than);
    }
}

/// Convert the Huffman tree stored in `array` into its canonical form, it
/// is enough to know the code length of every symbol in the alphabet to
/// encode/decode on the canonical form.
fn build_canonical_encoding(ctx: *HuffmanCompressContext) !void {
    // Make sure all encodings start as null
    for (0..ctx.enc_map.len) |i| {
        ctx.enc_map[i] = null;
    }
    if (ctx.array.items.len == 0) {
        return;
    }

    // Create the initial translation map from stream symbols onto encoded
    // Huffman symbols.
    try walk_generate_translation(ctx, ctx.array.items.len - 1, 0, 0);

    // 1. Count how many entries there are for each code length (bit length)
    var bit_length_counts = try ctx.allocator.alloc(u16, ctx.symbol_max);
    @memset(bit_length_counts, 0);

    var max_seen_bits: u4 = 0;
    for (0..ctx.enc_map.len) |i| {
        if (ctx.enc_map[i]) |enc| {
            bit_length_counts[enc.bit_shift] += 1;

            if (enc.bit_shift > max_seen_bits) {
                max_seen_bits = enc.bit_shift;
            }
        }
    }

    // 2. For each bit length (up to the maximum we observed in step 1),
    // determine the starting code value.
    var next_code = try ctx.allocator.alloc(u16, ctx.symbol_max);
    @memset(next_code, 0);

    var code: u16 = 0;
    const end: usize = @intCast(max_seen_bits);
    for (1..end + 1) |i| {
        // Starting code is based of previous bit length code
        code = (code + bit_length_counts[i-1]) << 1;
        next_code[i] = code;
    }

    // 3. Assign numerical values to all codes, using consecutive values for
    // all codes of the same length with the base values determined at the
    // previous step
    for (0..ctx.enc_map.len) |i| {
        if (ctx.enc_map[i]) |enc| {
            const new_enc = HuffmanEncoding {
                .bit_shift = enc.bit_shift,
                .bits = next_code[enc.bit_shift]
            };
            ctx.enc_map[i] = new_enc;
            next_code[enc.bit_shift] += 1;
        }
    }
}

/// Walk the tree and setup the byte -> encoding mappings used for encoding.
fn walk_generate_translation(
    ctx: *HuffmanCompressContext,
    index: usize,
    bits: u16,
    bit_shift: u4,
) !void {
    const maybe_left_child_index = ctx.array.items[index].maybe_left_child_index;
    const maybe_right_child_index = ctx.array.items[index].maybe_right_child_index;

    if (bit_shift >= 15) {
        log.err(@src(), "Huffman tree too deep: node requires {} bits", .{bit_shift});
        return HuffmanError.BadEncoding;
    }

    if (maybe_left_child_index == null and maybe_right_child_index == null) {
        // Reached leaf
        if (ctx.array.items[index].maybe_value) |value| {
            const shift = if (bit_shift == 0) 1 else bit_shift;
            const enc = HuffmanEncoding { .bit_shift = shift, .bits = bits };
            ctx.enc_map[value] = enc;
        } else {
            log.err(@src(), "Missing character from leaf node", .{});
            return HuffmanError.BadEncoding;
        }
    } else {
        if (maybe_left_child_index) |child_index| {
            // left: 0
            // Append the new bit to the END of the bit-string
            try walk_generate_translation(ctx, child_index, (bits << 1), bit_shift + 1);
        }
        if (maybe_right_child_index) |child_index| {
            // right: 1
            try walk_generate_translation(
                ctx,
                child_index,
                // Append the new bit to the END of the bit-string
                (bits << 1) | 1,
                bit_shift + 1
            );
        }
    }
}

fn write_bits_be(
    ctx: *HuffmanCompressContext,
    bit_writer: *std.io.BitWriter(.little, std.io.AnyWriter),
    value: u16,
    num_bits: u16,
) !void {
    for (1..num_bits) |i_usize| {
        const i: u4 = @intCast(i_usize);
        const shift_by: u4 = @intCast(num_bits - i);

        const bit: u1 = @truncate((value >> shift_by) & 1);
        try write_bit(ctx, bit_writer, bit);
    }

    // Final least-significant bit
    const bit: u1 = @truncate(value & 1);
    try write_bit(ctx, bit_writer, bit);
}

fn write_bit(
    ctx: *HuffmanCompressContext,
    bit_writer: *std.io.BitWriter(.little, std.io.AnyWriter),
    bit: u1,
) !void {
    try bit_writer.writeBits(bit, 1);
    util.print_bits(log.trace, u16, "Output write", bit, 1, ctx.written_bits);
    ctx.written_bits += 1;
}

/// Count the occurrences of each byte in `instream`
fn calculate_frequencies(ctx: *HuffmanCompressContext, instream: std.fs.File, reader: anytype) !usize {
    var cnt: usize = 0;
    while (true) {
        const c = reader.readByte() catch {
            break;
        };
        if (ctx.frequencies[c] == 0) {
            cnt += 1;
        }
        ctx.frequencies[c] += 1;
    }
    // Reset the positiion in the input stream
    try instream.seekTo(0);
    return cnt;
}

fn dump_frequencies(ctx: *HuffmanCompressContext) void {
    log.debug(@src(), "Frequencies:", .{});
    for (0..ctx.frequencies.len) |i| {
        if (ctx.frequencies[i] == 0) {
            continue;
        }
        if (i < 256) {
            const c: u8 = @truncate(i);
            if (std.ascii.isPrint(c) and c != '\n') {
                log.debug(
                    @src(),
                    "{d}: {d} ('{c}')",
                    .{c, ctx.frequencies[i], c}
                );
            } else {
                log.debug(@src(), "{d}: {d}", .{c, ctx.frequencies[i]});
            }
        }
        else {
            log.debug(@src(), "{d}: {d}", .{i, ctx.frequencies[i]});
        }
    }
}

fn dump_tree(ctx: *HuffmanCompressContext, comptime depth: u4, index: usize) void {
    // Compile time generated strings are built based on the depth
    if (depth >= 15) {
        log.err(@src(), "Reached maximum depth: {d}", .{depth});
        return;
    }

    if (index == ctx.array.items.len - 1) {
        const node = ctx.array.items[index];
        node.dump(0, "root");
    }

    if (ctx.array.items[index].maybe_left_child_index) |child_index| {
        const node = ctx.array.items[child_index];
        node.dump(depth + 1, "0");
        dump_tree(ctx, depth + 1, child_index);
    }
    if (ctx.array.items[index].maybe_right_child_index) |child_index| {
        const node = ctx.array.items[child_index];
        node.dump(depth + 1, "1");
        dump_tree(ctx, depth + 1, child_index);
    }
}

fn dump_encodings(enc_map: []?HuffmanEncoding) void {
    for (0..enc_map.len) |i| {
        if (enc_map[i]) |enc| {
            const v: u16 = @truncate(i);
            enc.dump_mapping(v);
        }
    }
}
