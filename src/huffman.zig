const std = @import("std");
const util = @import("util.zig");
const log = @import("log.zig");

const HuffmanError = error {
    UnexpectedCharacter,
    UnexpectedEncodedSymbol,
    BadTreeStructure,
};

/// The maximum possible encoding length for a character will be 2**8
/// I.e. in the worst-case we need to store a 256-bit value
const NodeEncoding = struct {
    bit_shift: u8,
    bits: [4]u64,

    pub fn format(
        self: *const @This(),
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype
    ) !void {
        if (fmt.len != 0) {
            return std.fmt.invalidFmtError(fmt, self);
        }

        if (self.bits[1] == 0 and
            self.bits[2] == 0 and
            self.bits[3] == 0) {
            return writer.print("{{ .bit_shift = {}, .bits = {{ 0b{b} }} }}",
                                .{self.bit_shift, self.bits[0]});
        } else {
            return writer.print("{{ .bit_shift = {}, .bits = {{ 0x{x}, 0x{x}, 0x{x}, 0x{x} }} }}",
                                .{self.bit_shift, self.bits[0], self.bits[1], self.bits[2], self.bits[3]});
        }
    }
};

pub const Node = struct {
    /// Only leaf nodes contain a character
    char: ?u8,
    weight: usize,
    left_child_index: ?usize,
    right_child_index: ?usize,

    /// Descending sort comparison method
    pub fn desc(_:void, lhs: @This(), rhs: @This()) bool {
        return lhs.weight > rhs.weight;
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
                return writer.print("{{ .weight = {d}, .char = '{c}' }}",
                                  .{self.weight, char});
            } else {
                return writer.print("{{ .weight = {d}, .char = 0x{x} }}",
                                  .{self.weight, char});
            }
        } else {
            return writer.print("{{ .weight = {d} }}", .{self.weight});
        }
    }

    pub fn dump(self: @This(), comptime level: u8, pos: []const u8) void {
        const prefix = util.repeat('-', level) catch unreachable;
        log.debug(@src(), "`{s}{s}: {any} [{d}]", .{prefix, pos, self, level});
        std.heap.page_allocator.free(prefix);
    }
};

pub const Huffman = struct {
    /// Backing array for Huffman tree nodes
    array: std.ArrayList(Node),

    /// Mappings from 1 byte symbols onto 256-bit encodings
    enc_map: []?NodeEncoding,

    /// Initialize a Huffman tree from the input of the provided `reader`
    pub fn init(allocator: std.mem.Allocator, instream: std.fs.File) !@This() {
        var frequencies = std.AutoHashMap(u8, usize).init(allocator);
        var cnt: usize = 0;
        defer frequencies.deinit();
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

        log.debug(@src(), "frequencies:", .{});
        util.dump_hashmap(usize, &frequencies);

        // 2. Create a queue of nodes to place into the tree
        var queue_cnt: usize = cnt;
        const queue = try allocator.alloc(Node, queue_cnt);

        var array_cnt: usize = 0;
        // The array will grow if the capacity turns out to be too low
        var array = try std.ArrayList(Node).initCapacity(allocator, 2*queue_cnt);

        var keys = frequencies.keyIterator();
        var index: usize = 0;
        while (keys.next()) |key| {
            const weight = frequencies.get(key.*).?;
            queue[index] = Node {
                .char = key.*,
                .weight = weight,
                .left_child_index = undefined,
                .right_child_index = undefined
            };
            // Sort in descending order with the largest node first
            std.sort.insertion(Node, queue[0..index], {}, Node.desc);
            index += 1;
        }

        log.debug(@src(), "initial node count: {}", .{queue_cnt});

        // 3. Create the tree
        while (queue_cnt > 0) {
            if (queue_cnt == 1) {
                // The root node will always be the last item
                try array.append(queue[queue_cnt - 1]);
                queue_cnt -= 1;
                array_cnt += 1;
                continue;
            }

            // Pick the two elements from the queue with the lowest weight
            const left_child = queue[queue_cnt - 2];
            const right_child = queue[queue_cnt - 1];

            // Save the children from the queue into the backing array
            try array.append(left_child);
            try array.append(right_child);
            array_cnt += 2;

            // Create the parent node
            const parent_weight = left_child.weight + right_child.weight;
            const parent_node = Node {
                .char = undefined,
                .weight = parent_weight,
                .left_child_index = array_cnt - 2,
                .right_child_index = array_cnt - 1
            };

            // Insert the parent node into the priority queue, overwriting
            // one of the children and dropping the other
            queue_cnt -= 1;
            queue[queue_cnt - 1] = parent_node;
            std.sort.insertion(Node, queue[0..queue_cnt], {}, Node.desc);
        }

        var enc_map = try allocator.alloc(?NodeEncoding, 256);
        try build_canonical_encoding(&array, &enc_map);

        return @This(){ .array = array, .enc_map = enc_map };
    }

    /// Convert the Huffman tree stored in `array` into its canonical form, it
    /// is enough to know the code length of every symbol in the alphabet to
    /// encode/decode on the canonical form.
    fn build_canonical_encoding(array: *std.ArrayList(Node), enc_map: *[]?NodeEncoding) !void {
        // Make sure all encodings start as null
        for (0..enc_map.len) |i| {
            enc_map.*[i] = null;
        }
        // Create the initial translation map from 1 byte characters onto encoded Huffman symbols.
        try walk_generate_translation(array, enc_map, array.items.len - 1, .{0, 0, 0, 0}, 0);

        // 1. Count how many entries there are for each code length (bit length)
        // 256 entries, maximum bit length of an encoded symbol
        var bit_length_counts = [_]u8{0} ** 256;
        var max_seen_bits: u8 = 0;
        for (0..enc_map.len) |i| {
            if (enc_map.*[i]) |enc| {
                if (enc.bit_shift >= 256) unreachable;
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
        var next_code = [_][4]u64{ .{0,0,0,0}  } ** 256;

        var code: u8 = 0;
        for (1..max_seen_bits + 1) |i| {
            // Starting code is based of previous bit length code
            code = (code + bit_length_counts[i-1]) << 1;
            next_code[i][0] = code;
            if (next_code[i][0] != 0) {
                log.debug(@src(), "next_code[{}] = {}", .{i, next_code[i][0]});
            }
        }

        // 3. Assign numerical values to all codes, using consecutive values for
        // all codes of the same length with the base values determined at step
        // 2
        for (0..enc_map.len) |i| {
            if (enc_map.*[i]) |enc| {
                const new_enc = NodeEncoding {
                    .bit_shift = enc.bit_shift,
                    .bits = .{
                        next_code[enc.bit_shift][0],
                        next_code[enc.bit_shift][1],
                        next_code[enc.bit_shift][2],
                        next_code[enc.bit_shift][3],
                    }
                };
                enc_map.*[i] = new_enc;
                next_code[enc.bit_shift][0] += 1;
            }
        }
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
                // Write the translation to the output stream
                switch (enc.bit_shift) {
                    0...63 => {
                        const shift: u6 = @truncate(enc.bit_shift);
                        try writer.writeBits(enc.bits[0], shift + 1);
                    },
                    64...127 => {
                        const shift: u6 = @intCast(enc.bit_shift - 64);
                        try writer.writeBits(enc.bits[0], 64);
                        try writer.writeBits(enc.bits[1], shift + 1);
                    },
                    128...191 => {
                        const shift: u6 = @intCast(enc.bit_shift - 128);
                        try writer.writeBits(enc.bits[0], 64);
                        try writer.writeBits(enc.bits[1], 64);
                        try writer.writeBits(enc.bits[2], shift + 1);
                    },
                    192...255 => {
                        const shift: u6 = @intCast(enc.bit_shift - 192);
                        try writer.writeBits(enc.bits[0], 64);
                        try writer.writeBits(enc.bits[1], 64);
                        try writer.writeBits(enc.bits[2], 64);
                        try writer.writeBits(enc.bits[3], shift + 1);
                    },
                }
                written_bits += enc.bit_shift;
            } else {
                log.err(@src(), "Unexpected byte: 0x{x}", .{c});
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
        node_bits: [4]u64,
        bit_shift: u8,
    ) !void {
        const left_child_index = array.items[index].left_child_index;
        const right_child_index = array.items[index].right_child_index;
        // Create a mutable copy
        var bits = .{
            node_bits[0],
            node_bits[1],
            node_bits[2],
            node_bits[3],
        };

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
                const one: u64 = 1;
                switch (bit_shift) {
                    0...63 => {
                        const shift: u6 = @intCast(bit_shift);
                        const new_bit: u64 = one << shift;
                        bits[0] = bits[0] | new_bit;
                    },
                    64...127 => {
                        const shift: u6 = @intCast(bit_shift - 64);
                        const new_bit: u64 = one << shift;
                        bits[1] = bits[1] | new_bit;
                    },
                    128...191 => {
                        const shift: u6 = @intCast(bit_shift - 128);
                        const new_bit: u64 = one << shift;
                        bits[2] = bits[2] | new_bit;
                    },
                    192...255 => {
                        const shift: u6 = @intCast(bit_shift - 192);
                        const new_bit: u64 = one << shift;
                        bits[3] = bits[3] | new_bit;
                    },
                }
                try walk_generate_translation(array, enc_map, child_index, bits, bit_shift + 1);
            }
        }
    }

    fn dump_tree(self: @This(), comptime level: u8, index: usize) void {
        // Compile time generated strings are built based on the level
        if (level == 255) unreachable;

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
