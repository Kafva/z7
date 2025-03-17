const std = @import("std");
const util = @import("util.zig");
const log = @import("log.zig");

const HuffmanError = error {
    UnexpectedCharacter,
    UnexpectedEncodedSymbol,
    BadTreeStructure,
    InternalError,
    MaxDepthInsufficent,
};

const NodeEncoding = struct {
    /// It is seldom efficient to use encodings longer than 15 (2**4 - 1) bits
    /// for a character.
    ///
    /// go/src/compress/flate/huffman_code.go
    ///   "[...] the maximum number of bits that should be used to encode any literal.
    ///   It must be less than 16."
    bit_shift: u4,
    bits: u16,

    pub fn format(
        self: *const @This(),
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype
    ) !void {
        if (fmt.len != 0) {
            return std.fmt.invalidFmtError(fmt, self);
        }

        return writer.print("{{ .bit_shift = {}, .bits = 0x{b} }}",
                            .{self.bit_shift, self.bits});
    }
};

pub const Node = struct {
    /// Only leaf nodes contain a character
    char: ?u8,
    weight: usize,
    /// Level in the tree, root node is at level 0
    level: u4,
    left_child_index: ?usize,
    right_child_index: ?usize,

    /// Priority sort comparison method:
    ///
    /// First: Sort based on level (ascending, lowest first)
    /// Second: Sort based on weight (descending, highest first)
    /// Example:
    ///
    /// [
    ///     { .level = 0, .weight = 3 },
    ///     { .level = 0, .weight = 2 },
    ///     { .level = 0, .weight = 1 },
    ///     { .level = 1, .weight = 3 },
    ///     { .level = 1, .weight = 2 },
    ///     { .level = 1, .weight = 1 },
    /// ]
    ///
    /// When constructing the tree we want to pop items from the tail of the queue.
    /// We exhaust the highest remaning level with the lowest weights first.
    pub fn prio(_:void, lhs: @This(), rhs: @This()) bool {
        // Returns true if the item should be placed closer to the start of the array
        if (lhs.level == rhs.level) {
            return lhs.weight > rhs.weight;
        }
        else {
            return lhs.level < rhs.level;
        }
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

        if (self.char) |char| {
            if (std.ascii.isPrint(char) and char != '\n') {
                return writer.print("{{ .level = {d}, .weight = {d}, .char = '{c}' }}",
                                  .{self.level, self.weight, char});
            } else {
                return writer.print("{{ .level = {d}, .weight = {d}, .char = 0x{x} }}",
                                  .{self.level, self.weight, char});
            }
        } else {
            return writer.print("{{ .weight = {d} }}", .{self.weight});
        }
    }

    pub fn dump(self: @This(), comptime level: u4, pos: []const u8) void {
        const prefix = util.repeat('-', level) catch unreachable;
        log.debug(@src(), "`{s}{s}: {any} [{d}]", .{prefix, pos, self, level});
        std.heap.page_allocator.free(prefix);
    }

    /// Calculate how many child levels are below the current node recursively
    pub fn levels_below(self: @This(), array: *const []Node) u4 {
        var child_levels_left = 0;
        var child_levels_right = 0;

        if (self.left_child_index) |idx| {
            child_levels_left += array.*[idx].levels_below(array);
        }
        if (self.right_child_index) |idx| {
            child_levels_right += array.*[idx].levels_below(array);
        }

        // Pick the largest side
        return if (child_levels_right > child_levels_left) child_levels_right
               else child_levels_left;
    }
};

pub const Huffman = struct {
    /// Backing array for Huffman tree nodes
    array: std.ArrayList(Node),

    /// Mappings from 1 byte symbols onto 256-bit encodings
    enc_map: []?NodeEncoding,

    /// Initialize a Huffman tree from the input of the provided `reader`
    pub fn init(
        allocator: std.mem.Allocator,
        frequencies: *const std.AutoHashMap(u8, usize),
    ) !@This() {
        log.debug(@src(), "frequencies:", .{});
        util.dump_hashmap(usize, frequencies);

        // 2. Create a queue of nodes to place into the tree
        const queue_cnt: usize = frequencies.count();
        var queue = try allocator.alloc(Node, queue_cnt);

        // The array will grow if the capacity turns out to be too low
        var array = try std.ArrayList(Node).initCapacity(allocator, 2*queue_cnt);

        var keys = frequencies.*.keyIterator();
        var index: usize = 0;
        while (keys.next()) |key| {
            const weight = frequencies.*.get(key.*).?;
            queue[index] = Node {
                .char = key.*,
                .level = 15, // placeholder
                .weight = weight,
                .left_child_index = undefined,
                .right_child_index = undefined
            };
            // Sort in descending order with the largest node first
            std.sort.insertion(Node, queue[0..index], {}, Node.prio);
            index += 1;
        }

        log.debug(@src(), "initial node count: {}", .{queue_cnt});

        // 3. Create the tree, we need to make sure that we do not grow
        // the tree deeper than 15 levels so that every leaf can be encoded
        // with a u16.
        //
        // Level 0: 2^0 nodes
        // Level 1: 2^1 nodes
        // Level 2: 2^2 nodes
        // ...
        // Level 15: 2^15 nodes
        //
        // Iterative approach, try to create a tree with all slots filled up to level 2
        // On failure, try again with all slots up to level 3, etc.
        for (2..15) |i| {
            construct_max_depth_tree(&queue, queue_cnt, &array, @truncate(i)) catch |e| {
                if (e == HuffmanError.MaxDepthInsufficent) {
                    continue;
                }
                return e;
            };
            break;
        }

        var enc_map = try allocator.alloc(?NodeEncoding, 256);
        try build_canonical_encoding(&array, &enc_map);

        return @This(){ .array = array, .enc_map = enc_map };
    }

    /// Construct a Huffman tree from `queue` into `array` which does not
    /// exceed the provided `max_level`, returns an error if the provided
    /// `max_level` is insufficient.
    fn construct_max_depth_tree(
        queue: *[]Node,
        queue_initial_cnt: usize,
        array: *std.ArrayList(Node),
        max_level: u4,
    ) !void {
        var queue_cnt: usize = queue_initial_cnt;
        var array_cnt: usize = 0;
        var filled_cnt: usize = 0;
        var current_level: u4 = max_level;

        // Let all nodes start at the bottom
        for (0..queue_initial_cnt) |i| {
            queue.*[i].level = max_level;
            std.debug.print("queue: {any}\n", .{queue.*[i]});
        }


        while (queue_cnt > 0) {
            if (current_level == 0) {
                if (queue_cnt > 1) {
                    log.debug(
                        @src(),
                        "failed to construct {}-depth tree: {} nodes left",
                        .{max_level, queue_cnt}
                    );
                    return HuffmanError.MaxDepthInsufficent;
                }
            }

            if (queue_cnt == 1) {
                // OK: last node from the priority queue has already been given children,
                // just save it and quit.
                try array.*.append(queue.*[0]);
                queue_cnt -= 1;
                array_cnt += 1;
                continue;
            }

            if (filled_cnt == std.math.pow(usize, 2, current_level)) {
                // OK: current level has been filled
                filled_cnt = 0;
                current_level -= 1;
                continue;
            }

            // Current level has not been filled, pick the two nodes with the lowest weight
            // from the current level
            const left_child = queue.*[queue_cnt - 2];
            const right_child = queue.*[queue_cnt - 1];

            // If the nodes are at a higher level than expected we have an internal error
            if (left_child.level > current_level) {
                log.err(@src(), "bad level of left node: {}", .{left_child.level});
                return HuffmanError.InternalError;
            }
            if (right_child.level > current_level) {
                log.err(@src(), "bad level of right node: {}", .{right_child.level});
                return HuffmanError.InternalError;
            }

            // Save the children from the queue into the backing array
            // XXX: the backing array is unsorted, the tree structure is derived from each `Node`
            try array.*.append(left_child);
            try array.*.append(right_child);
            array_cnt += 2;
            filled_cnt += 2;

            // Create the parent node
            // We always create parent node with both child positions filled,
            // the child pointers of this node will not change after creation.
            const parent_node = Node {
                .char = undefined,
                .weight = left_child.weight + right_child.weight,
                // The parent will be one level higher than the children
                .level = current_level - 1,
                .left_child_index = array_cnt - 2,
                .right_child_index = array_cnt - 1
            };

            // Insert the parent node into the priority queue, overwriting
            // one of the children and dropping the other
            queue_cnt -= 1;
            queue.*[queue_cnt - 1] = parent_node;
            std.sort.insertion(Node, queue.*[0..queue_cnt], {}, Node.prio);
        }
    }

    /// Convert the Huffman tree stored in `array` into its canonical form, it
    /// is enough to know the code length of every symbol in the alphabet to
    /// encode/decode on the canonical form.
    fn build_canonical_encoding(array: *std.ArrayList(Node), enc_map: *[]?NodeEncoding) !void {
        // Make sure all encodings start as null
        for (0..enc_map.len) |i| {
            enc_map.*[i] = null;
        }
        if (array.items.len == 0) {
            return;
        }

        // Create the initial translation map from 1 byte characters onto encoded Huffman symbols.
        try walk_generate_translation(array, enc_map, array.items.len - 1, 0, 0);

        // 1. Count how many entries there are for each code length (bit length)
        // We only allow code lengths that fit into a u16
        var bit_length_counts = [_]u16{0} ** 256;
        var max_seen_bits: u4 = 0;
        for (0..enc_map.len) |i| {
            if (enc_map.*[i]) |enc| {
                bit_length_counts[enc.bit_shift] += 1;

                if (enc.bit_shift > max_seen_bits) {
                    max_seen_bits = enc.bit_shift;
                }
            }
        }

        for (0..bit_length_counts.len) |i| {
            if (bit_length_counts[i] != 0) {
                log.debug(@src(), "bit_length_counts[{}] = {}", .{i, bit_length_counts[i]});
            }
        }

        // 2. For each bit length (up to the maximum we observed in step 1),
        // determine the starting code value.
        var next_code = [_]u16{0} ** 256;

        var code: u16 = 0;
        const end: usize = @intCast(max_seen_bits);
        for (1..end + 1) |i| {
            // Starting code is based of previous bit length code
            code = (code + bit_length_counts[i-1]) << 1;
            next_code[i] = code;
            if (next_code[i] != 0) {
                log.debug(@src(), "next_code[{}] = {}", .{i, next_code[i]});
            }
        }

        // 3. Assign numerical values to all codes, using consecutive values for
        // all codes of the same length with the base values determined at step
        for (0..enc_map.len) |i| {
            if (enc_map.*[i]) |enc| {
                const new_enc = NodeEncoding {
                    .bit_shift = enc.bit_shift,
                    .bits = next_code[enc.bit_shift]
                };
                enc_map.*[i] = new_enc;
                next_code[enc.bit_shift] += 1;
            }
        }
    }

    /// Count the occurrences of each byte in `instream`
    pub fn get_frequencies(allocator: std.mem.Allocator, instream: std.fs.File) !std.AutoHashMap(u8, usize) {
        var frequencies = std.AutoHashMap(u8, usize).init(allocator);
        var cnt: usize = 0;
        const reader = instream.reader();

        // 1. Calculate the frequencies for each character in the input stream.
        while (true) {
            const c = reader.readByte() catch {
                break;
            };

            if (frequencies.get(c)) |weight| {
                try frequencies.put(c, weight + 1);
            } else {
                try frequencies.put(c, 1);
                cnt += 1;
            }
        }

        return frequencies;
    }

    pub fn compress(
        self: @This(),
        instream: std.fs.File,
        outstream: std.fs.File
    ) !void {
        if (self.array.items.len == 0) {
            return;
        }
        var writer = std.io.bitWriter(.little, outstream.writer());
        var written_bits: usize = 0;
        const reader = instream.reader();

        // Dump tree for debugging
        self.dump_tree(0, self.array.items.len - 1);
        self.dump_encodings();

        while (true) {
            const c = reader.readByte() catch {
                break;
            };

            if (self.enc_map[@intCast(c)]) |enc| {
                if (enc.bit_shift >= 15) {
                    log.err(@src(), "unexpected bit shift: {any}", .{enc});
                    return HuffmanError.BadTreeStructure;
                }
                // Write the translation to the output stream
                try writer.writeBits(enc.bits, enc.bit_shift + 1);
                written_bits += enc.bit_shift + 1;
            } else {
                log.err(@src(), "unexpected byte: 0x{x}", .{c});
                return HuffmanError.UnexpectedCharacter;
            }
        }

        try writer.flushBits();
        log.debug(@src(), "wrote {} bits [{} bytes]", .{written_bits, written_bits / 8});
    }

    pub fn decompress(self: @This(), instream: std.fs.File, outstream: std.fs.File) !void {
        if (self.array.items.len == 0) {
            return;
        }
        // The input stream position should point to the last input element
        const end = (try instream.getPos()) * 8;
        var pos: usize = 0;

        // Start from the first element in both streams
        try instream.seekTo(0);
        try outstream.seekTo(0);

        var reader = std.io.bitReader(.little, instream.reader());
        var writer = outstream.writer();

        // Decode the stream
        while (pos < end) {
            const char = self.walk_decode(self.array.items.len - 1, &reader, &pos) catch |err| {
                log.err(@src(), "decoding error: {any}", .{err});
                break;
            };

            if (char) |c| {
                try writer.writeByte(c);
            } else {
                break;
            }
        }
    }

    /// Read bits from the `reader` and return decoded bytes.
    fn walk_decode(
        self: @This(),
        index: usize,
        reader: anytype,
        read_bits: *usize,
    ) !?u8 {
        const bit = reader.readBitsNoEof(u1, 1) catch {
            return null;
        };
        read_bits.* += 1;

        const left_child_index = self.array.items[index].left_child_index;
        const right_child_index = self.array.items[index].right_child_index;

        if (left_child_index == null and right_child_index == null) {
            // Reached leaf
            if (self.array.items[index].char) |char| {
                return char;
            } else {
                log.err(@src(), "missing character from leaf node", .{});
                return HuffmanError.BadTreeStructure;
            }

        } else {
            switch (bit) {
                0 => {
                    if (left_child_index) |child_index| {
                        return try self.walk_decode(child_index, reader, read_bits);
                    } else {
                        return HuffmanError.UnexpectedEncodedSymbol;
                    }
                },
                1 => {
                    if (right_child_index) |child_index| {
                        return try self.walk_decode(child_index, reader, read_bits);
                    } else {
                        return HuffmanError.UnexpectedEncodedSymbol;
                    }
                }
            }
        }
    }

    /// Walk the tree and setup the byte -> encoding mappings used for encoding.
    fn walk_generate_translation(
        array: *std.ArrayList(Node),
        enc_map: *[]?NodeEncoding,
        index: usize,
        bits: u16,
        bit_shift: u4,
    ) !void {
        const left_child_index = array.items[index].left_child_index;
        const right_child_index = array.items[index].right_child_index;

        if (bit_shift >= 15) {
            log.err(@src(), "huffman tree too deep: node requires {} bits", .{bit_shift});
            return HuffmanError.BadTreeStructure;
        }

        if (left_child_index == null and right_child_index == null) {
            // Reached leaf
            if (array.items[index].char) |char| {
                const enc = NodeEncoding { .bit_shift = bit_shift, .bits = bits };
                enc_map.*[char] = enc;
            } else {
                log.err(@src(), "missing character from leaf node", .{});
                return HuffmanError.BadTreeStructure;
            }
        } else {
            if (left_child_index) |child_index| {
                // left: 0
                // Nothing to do, all bits start initialised to 0
                try walk_generate_translation(array, enc_map, child_index, bits, bit_shift + 1);
            }
            if (right_child_index) |child_index| {
                // right: 1
                const one: u16 = 1;
                const shift: u4 = @intCast(bit_shift);
                const new_bit: u16 = one << shift;
                try walk_generate_translation(
                    array,
                    enc_map,
                    child_index,
                    bits | new_bit,
                    bit_shift + 1
                );
            }
        }
    }

    fn dump_tree(self: @This(), comptime level: u4, index: usize) void {
        // Compile time generated strings are built based on the level
        if (level >= 15) {
            log.err(@src(), "reached maximum depth: {d}", .{level});
            return;
        }

        if (index == self.array.items.len - 1) {
            log.debug(@src(), "complete tree node count: {}", .{self.array.items.len});
            const node = self.array.items[index];
            node.dump(0, "root");
        }

        if (self.array.items[index].left_child_index) |child_index| {
            const node = self.array.items[child_index];
            node.dump(level + 1, "0");
            self.dump_tree(level + 1, child_index);
        }
        if (self.array.items[index].right_child_index) |child_index| {
            const node = self.array.items[child_index];
            node.dump(level + 1, "1");
            self.dump_tree(level + 1, child_index);
        }
    }

    fn dump_encodings(
        self: @This(),
    ) void {
        for (0..self.enc_map.len) |i| {
            const char: u8 = @truncate(i);
            if (self.enc_map[i]) |enc| {
                if (std.ascii.isPrint(char)) {
                    log.debug(@src(), "(0x{x}) '{c}' -> {any}", .{char, char, enc});
                } else {
                    log.debug(@src(), "(0x{x})     -> {any}", .{char, enc});
                }
            }
        }
    }
};
