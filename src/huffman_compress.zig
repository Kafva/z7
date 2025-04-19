const std = @import("std");
const util = @import("util.zig");
const log = @import("log.zig");

const HuffmanTreeNode = @import("huffman.zig").HuffmanTreeNode;
const HuffmanEncoding = @import("huffman.zig").HuffmanEncoding;
const HuffmanError = @import("huffman.zig").HuffmanError;

const HuffmanCompressContext = struct {
    allocator: std.mem.Allocator,
    /// The maximum value of symbols from the input stream, 256 for regular
    /// input from a file, 286 for deflate.
    symbol_max: u16,
    instream: ?*const std.fs.File,
    reader: ?std.io.AnyReader,
    bit_writer: ?std.io.BitWriter(.little, std.io.AnyWriter),
    written_bits: usize,
    /// The frequency of each byte value to rely on when constructing the
    /// Huffman code
    frequencies: []usize,
    /// Mappings from symbols onto Huffman encodings
    enc_map: []?HuffmanEncoding,
    /// Backing array for Huffman tree nodes
    array: std.ArrayList(HuffmanTreeNode),
};

pub fn compress(
    allocator: std.mem.Allocator,
    enc_len: *usize,
    symbol_max: u16,
    instream: *const std.fs.File,
    outstream: *const std.fs.File,
) !std.AutoHashMap(HuffmanEncoding, u16) {
    var ctx = HuffmanCompressContext {
        .allocator = allocator,
        .symbol_max = symbol_max,
        .instream = instream,
        .reader = instream.reader().any(),
        .bit_writer = std.io.bitWriter(.little, outstream.writer().any()),
        .written_bits = 0,
        .frequencies = try allocator.alloc(usize, symbol_max),
        .enc_map = try allocator.alloc(?HuffmanEncoding, symbol_max),
        // The array will grow if the capacity turns out to be too low
        .array = try std.ArrayList(HuffmanTreeNode).initCapacity(allocator, 2*symbol_max),
    };
    @memset(ctx.frequencies, 0);

    // Get frequencies from the input stream
    const symbol_count = try calculate_frequencies(&ctx);
    dump_frequencies(&ctx);

    const dec_map = try build_huffman_tree(&ctx, symbol_count);

    if (ctx.array.items.len == 0) {
        log.debug(@src(), "Nothing to compress", .{});
        return dec_map;
    }

    // Write the translations to the output stream
    while (true) {
        const c = ctx.reader.?.readByte() catch {
            break;
        };
        if (ctx.enc_map[@intCast(c)]) |enc| {
            try write_bits_be(&ctx, enc.bits, enc.bit_shift);
            util.print_char(log.debug, "Encoded", c);
        } else {
            log.err(@src(), "Unexpected byte: 0x{x}", .{c});
            return HuffmanError.UnexpectedCharacter;
        }
    }

    try ctx.bit_writer.?.flushBits();
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
        .instream = null,
        .reader = null,
        .bit_writer = null,
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
            .value = v,
            .weight = 15, // placeholder
            .freq = ctx.frequencies[v],
            .left_child_index = undefined,
            .right_child_index = undefined
        };
        // Sort in descending order with the highest frequency+weight first
        index += 1;
        std.sort.insertion(HuffmanTreeNode, queue[0..index], {}, HuffmanTreeNode.greater_than);
    }
    log.debug(@src(), "Initial node count: {}", .{symbol_count});

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
    log.debug(@src(), "Complete tree node count: {}", .{ctx.array.items.len});

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
        log.debug(@src(), "Non-canonical tree:", .{});
        dump_tree(ctx, 0, ctx.array.items.len - 1);

        log.debug(@src(), "Canonical encodings:", .{});
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
            .value = queue_initial.*[i].value,
            .weight = 0,
            .freq = queue_initial.*[i].freq,
            .left_child_index = undefined,
            .right_child_index = undefined
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
            .value = undefined,
            .freq = left_child.freq + right_child.freq,
            .weight = parent_weight,
            .left_child_index = array_cnt - 2,
            .right_child_index = array_cnt - 1
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
            log.debug(@src(), "aaa {d}: {any}", .{i, enc});
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
    const left_child_index = ctx.array.items[index].left_child_index;
    const right_child_index = ctx.array.items[index].right_child_index;

    if (bit_shift >= 15) {
        log.err(@src(), "Huffman tree too deep: node requires {} bits", .{bit_shift});
        return HuffmanError.BadTreeStructure;
    }

    if (left_child_index == null and right_child_index == null) {
        // Reached leaf
        if (ctx.array.items[index].value) |value| {
            const shift = if (bit_shift == 0) 1 else bit_shift;
            const enc = HuffmanEncoding { .bit_shift = shift, .bits = bits };
            ctx.enc_map[value] = enc;
        } else {
            log.err(@src(), "Missing character from leaf node", .{});
            return HuffmanError.BadTreeStructure;
        }
    } else {
        if (left_child_index) |child_index| {
            // left: 0
            // Append the new bit to the END of the bit-string
            try walk_generate_translation(ctx, child_index, (bits << 1), bit_shift + 1);
        }
        if (right_child_index) |child_index| {
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

fn write_bits_be(ctx: *HuffmanCompressContext, value: u16, num_bits: u16) !void {
    for (1..num_bits) |i_usize| {
        const i: u4 = @intCast(i_usize);
        const shift_by: u4 = @intCast(num_bits - i);

        const bit: u1 = @truncate((value >> shift_by) & 1);
        try write_bit(ctx, bit);
    }

    // Final least-significant bit
    const bit: u1 = @truncate(value & 1);
    try write_bit(ctx, bit);
}

fn write_bit(ctx: *HuffmanCompressContext, bit: u1) !void {
    try ctx.bit_writer.?.writeBits(bit, 1);
    util.print_bits(log.trace, u16, "Output write", bit, 1, ctx.written_bits);
    ctx.written_bits += 1;
}

/// Count the occurrences of each byte in `instream`
fn calculate_frequencies(ctx: *HuffmanCompressContext) !usize {
    var cnt: usize = 0;
    while (true) {
        const c = ctx.reader.?.readByte() catch {
            break;
        };
        if (ctx.frequencies[c] == 0) {
            cnt += 1;
        }
        ctx.frequencies[c] += 1;
    }
    // Reset the positiion in the input stream
    try ctx.instream.?.seekTo(0);
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

    if (ctx.array.items[index].left_child_index) |child_index| {
        const node = ctx.array.items[child_index];
        node.dump(depth + 1, "0");
        dump_tree(ctx, depth + 1, child_index);
    }
    if (ctx.array.items[index].right_child_index) |child_index| {
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
