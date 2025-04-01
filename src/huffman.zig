const std = @import("std");
const util = @import("util.zig");
const log = @import("log.zig");

const color_base: u8 = 214;

const HuffmanError = error {
    UnexpectedCharacter,
    UnexpectedEncodedSymbol,
    BadTreeStructure,
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
    freq: usize,
    /// A lower weight has lower priority (minimum weight is 0).
    /// The maximum weight represents the maximum depth of the tree,
    /// a higher weight should be placed higher up in the tree.
    weight: u4,
    left_child_index: ?usize,
    right_child_index: ?usize,

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
        // If a the lhs node has the same values as the rhs, move it up as more recent,
        // this is needed for the fixed huffman construction to be correct.
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

        if (self.char) |char| {
            if (std.ascii.isPrint(char) and char != '\n') {
                return writer.print("{{ .weight = {d}, .freq = {d}, .char = '{c}' }}",
                                  .{self.weight, self.freq, char});
            } else {
                return writer.print("{{ .weight = {d}, .freq = {d}, .char = 0x{x} }}",
                                  .{self.weight, self.freq, char});
            }
        } else {
            return writer.print("{{ .weight = {d}, .freq = {d} }}", .{self.weight, self.freq});
        }
    }

    pub fn dump(self: @This(), comptime weight: u4, pos: []const u8) void {
        const prefix = util.repeat('-', weight) catch unreachable;
        const side_color: u8 = if (std.mem.eql(u8, "1", pos)) 37 else 97;
        const color: u8 = color_base + @as(u8, weight);
        log.debug(
            @src(),
            "\x1b[{d}m`{s}{s}\x1b[0m: \x1b[38;5;{d}m{any}\x1b[0m",
            .{side_color, prefix, pos, color, self}
        );
        std.heap.page_allocator.free(prefix);
    }
};

pub const Huffman = struct {
    /// Backing array for Huffman tree nodes
    array: std.ArrayList(Node),

    /// Mappings from 1 byte symbols onto 256-bit encodings
    enc_map: []?NodeEncoding,

    /// Initialize a Huffman tree from the provided symbol `frequencies`
    pub fn init(
        allocator: std.mem.Allocator,
        frequencies: *const std.AutoHashMap(u8, usize),
    ) !@This() {
        log.debug(@src(), "Frequencies:", .{});
        util.dump_hashmap(u8, usize, frequencies);

        // 2. Create a queue of nodes to place into the tree
        const queue_cnt: usize = frequencies.count();
        var queue = try allocator.alloc(Node, queue_cnt);

        // The array will grow if the capacity turns out to be too low
        var array = try std.ArrayList(Node).initCapacity(allocator, 2*queue_cnt);

        var keys = frequencies.*.keyIterator();
        var index: usize = 0;
        while (keys.next()) |key| {
            const freq = frequencies.*.get(key.*).?;
            queue[index] = Node {
                .char = key.*,
                .weight = 15, // placeholder
                .freq = freq,
                .left_child_index = undefined,
                .right_child_index = undefined
            };
            // Sort in descending order with the highest frequency+weight first
            index += 1;
            std.sort.insertion(Node, queue[0..index], {}, Node.greater_than);
        }

        log.debug(@src(), "Initial node count: {}", .{queue_cnt});

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
        // Iterative approach, try to create a tree with all slots filled up to depth x
        // On failure, try again with all slots up to depth x+1, etc.
        const maxdepth_start = blk: {
            if (queue_cnt == 0) {
                break :blk 0;
            }
            // log2(queue_count) + 1 will give us the maxdepth at which all of our nodes
            // fit on the lowest depth, we start from one depth before this.
            break :blk std.math.log2(queue_cnt);
        };
        for (maxdepth_start..16) |i| {
            construct_max_depth_tree(
                allocator,
                &queue,
                queue_cnt,
                &array,
                @truncate(i)
            ) catch |e| {
                if (e == HuffmanError.MaxDepthInsufficent and i < 15) {
                    continue;
                }
                return e;
            };
            log.debug(@src(), "Successfully constructed Huffman tree (maxdepth {})", .{i});
            break;
        }

        var enc_map = try allocator.alloc(?NodeEncoding, 256);
        try build_canonical_encoding(&array, &enc_map);

        return @This(){ .array = array, .enc_map = enc_map };
    }


    // fn construct_fixed_tree(
    //     allocator: std.mem.Allocator,
    //     queue_initial: *[]Node,
    //     queue_initial_cnt: usize,
    //     array: *std.ArrayList(Node),
    // ) !void {
    //     // Pop the last two elements from the queue (largest weight)
    //     // and create a new parent node, insert it back into the queue with a lower weight
    // }


    /// Count the occurrences of each byte in `instream`
    pub fn get_frequencies(
        allocator: std.mem.Allocator,
        instream: std.fs.File,
    ) !std.AutoHashMap(u8, usize) {
        var frequencies = std.AutoHashMap(u8, usize).init(allocator);
        var cnt: usize = 0;
        const reader = instream.reader();

        while (true) {
            const c = reader.readByte() catch {
                break;
            };

            if (frequencies.get(c)) |freq| {
                try frequencies.put(c, freq + 1);
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
        outstream: std.fs.File,
        max_length: usize,
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

        for (0..max_length) |_| {
            const c = reader.readByte() catch {
                break;
            };

            if (self.enc_map[@intCast(c)]) |enc| {
                if (enc.bit_shift >= 15) {
                    log.err(@src(), "Unexpected bit shift: {any}", .{enc});
                    return HuffmanError.BadTreeStructure;
                }
                // Write the translation to the output stream
                try writer.writeBits(enc.bits, enc.bit_shift + 1);
                written_bits += enc.bit_shift + 1;
            } else {
                log.err(@src(), "Unexpected byte: 0x{x}", .{c});
                return HuffmanError.UnexpectedCharacter;
            }
        }

        try writer.flushBits();
        log.debug(@src(), "Wrote {} bits [{} bytes]", .{written_bits, written_bits / 8});
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
                log.err(@src(), "Decoding error: {any}", .{err});
                break;
            };

            if (char) |c| {
                try writer.writeByte(c);
            } else {
                break;
            }
        }
    }



    /// Construct a Huffman tree from `queue_initial` into `array` which does
    /// not exceed the provided `max_depth`, returns an error if the provided
    /// `max_depth` is insufficient.
    fn construct_max_depth_tree(
        allocator: std.mem.Allocator,
        queue_initial: *[]Node,
        queue_initial_cnt: usize,
        array: *std.ArrayList(Node),
        max_depth: u4,
    ) !void {
        var queue_cnt: usize = queue_initial_cnt;
        var array_cnt: usize = 0;
        var filled_cnt: usize = 0;
        var current_depth: u4 = max_depth;
        var queue = try allocator.alloc(Node, queue_initial_cnt);

        // Start from an empty array
        array.*.clearRetainingCapacity();

        // Let all nodes start at the bottom (lowest possible weight value)
        for (0..queue_initial_cnt) |i| {
            queue[i] = Node {
                .char = queue_initial.*[i].char,
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
                try array.*.append(queue[0]);
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
            // XXX: the backing array is unsorted, the tree structure is derived from each `Node`
            try array.*.append(left_child);
            try array.*.append(right_child);
            array_cnt += 2;
            filled_cnt += 2;

            // Create the parent node
            // We always create parent nodes with both child positions filled,
            // the child pointers of this node will not change after creation.
            const parent_node = Node {
                .char = undefined,
                .freq = left_child.freq + right_child.freq,
                .weight = parent_weight,
                .left_child_index = array_cnt - 2,
                .right_child_index = array_cnt - 1
            };

            // Insert the parent node into the priority queue, overwriting
            // one of the children and dropping the other
            queue_cnt -= 1;
            queue[queue_cnt - 1] = parent_node;
            std.sort.insertion(Node, queue[0..queue_cnt], {}, Node.greater_than);
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

        // 2. For each bit length (up to the maximum we observed in step 1),
        // determine the starting code value.
        var next_code = [_]u16{0} ** 256;

        var code: u16 = 0;
        const end: usize = @intCast(max_seen_bits);
        for (1..end + 1) |i| {
            // Starting code is based of previous bit length code
            code = (code + bit_length_counts[i-1]) << 1;
            next_code[i] = code;
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
                log.err(@src(), "Missing character from leaf node", .{});
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
            log.err(@src(), "Huffman tree too deep: node requires {} bits", .{bit_shift});
            return HuffmanError.BadTreeStructure;
        }

        if (left_child_index == null and right_child_index == null) {
            // Reached leaf
            if (array.items[index].char) |char| {
                const enc = NodeEncoding { .bit_shift = bit_shift, .bits = bits };
                enc_map.*[char] = enc;
            } else {
                log.err(@src(), "Missing character from leaf node", .{});
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

    fn dump_tree(self: @This(), comptime depth: u4, index: usize) void {
        // Compile time generated strings are built based on the depth
        if (depth >= 15) {
            log.err(@src(), "Reached maximum depth: {d}", .{depth});
            return;
        }

        if (index == self.array.items.len - 1) {
            log.debug(@src(), "Complete tree node count: {}", .{self.array.items.len});
            const node = self.array.items[index];
            node.dump(0, "root");
        }

        if (self.array.items[index].left_child_index) |child_index| {
            const node = self.array.items[child_index];
            node.dump(depth + 1, "0");
            self.dump_tree(depth + 1, child_index);
        }
        if (self.array.items[index].right_child_index) |child_index| {
            const node = self.array.items[child_index];
            node.dump(depth + 1, "1");
            self.dump_tree(depth + 1, child_index);
        }
    }

    fn dump_encodings(
        self: @This(),
    ) void {
        for (0..self.enc_map.len) |i| {
            const char: u8 = @truncate(i);
            if (self.enc_map[i]) |enc| {
                const color: u8 = color_base + @as(u8, enc.bit_shift);
                if (std.ascii.isPrint(char)) {
                    log.debug(@src(), "(0x{x}) '{c}' -> \x1b[38;5;{d}m{any}\x1b[0m", .{char, char, color, enc});
                } else {
                    log.debug(@src(), "(0x{x}) ' ' -> \x1b[38;5;{d}m{any}\x1b[0m", .{char, color, enc});
                }
            }
        }
    }
};
