const std = @import("std");
const util = @import("util.zig");
const log = @import("log.zig");

pub const Node = struct {
    /// Only leaf nodes contain a character
    char: ?u8,
    weight: usize,
    left_child_index: ?usize,
    right_child_index: ?usize,

    pub fn desc(_:void, lhs: @This(), rhs: @This()) bool {
        return lhs.weight > rhs.weight;
    }

    pub fn dump(self: @This(), comptime level: u8, pos: []const u8) void {
        const prefix = util.repeat('-', level) catch unreachable;
        if (self.char) |char| {
            log.debug(@src(), "`{s}{s}: {{ .weight = {d}, .char = '{c}' }}",
                              .{prefix, pos, self.weight, char});
        } else {
            log.debug(@src(), "`{s}{s}: {{ .weight = {d} }}",
                              .{prefix, pos, self.weight});
        }
    }
};

const HuffmanError = error {
    UnexpectedCharacter,
    BadTreeStructure,
};

const NodeEncoding = struct {
    /// A shift within [0..7] is enough to index all parts of an 8 byte value
    bit_shift: u3,
    value: u8
};

pub const Huffman = struct {
    const Self = @This();

    array: std.ArrayList(Node),
    root_index: usize,

    /// Initialize a Huffman tree from the input of the provided `reader`
    pub fn init(allocator: std.mem.Allocator, reader: anytype) !@This() {
        var frequencies = std.AutoHashMap(u8, usize).init(allocator);
        var cnt: usize = 0;
        defer frequencies.deinit();

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

        return @This(){ .array = array, .root_index = array_cnt - 1 };
    }

    pub fn encode(
        self: Self,
        allocator: std.mem.Allocator,
        reader: anytype,
        outstream: anytype
    ) !void {
        var writer = std.io.bitWriter(.little, outstream.writer());
        var written_bits: usize = 0;

        // Create the translation map from 1 byte characters onto encoded Huffman symbols.
        var translation = std.AutoHashMap(u8, NodeEncoding).init(allocator);
        // Root node should be at the last position
        try self.walk(self.array.items.len - 1, &translation, 0, 0);

        while (true) {
            const c = reader.readByte() catch {
                break;
            };

            if (translation.get(c)) |c_enc| {
                switch (c_enc.bit_shift) {
                    0 => {
                        const value: u1 = @intCast(c_enc.value);
                        try writer.writeBits(value, c_enc.bit_shift);
                    },
                    1 => {
                        const value: u2 = @intCast(c_enc.value);
                        try writer.writeBits(value, c_enc.bit_shift);
                    },
                    2 => {
                        const value: u3 = @intCast(c_enc.value);
                        try writer.writeBits(value, c_enc.bit_shift);
                    },
                    3 => {
                        const value: u4 = @intCast(c_enc.value);
                        try writer.writeBits(value, c_enc.bit_shift);
                    },
                    4 => {
                        const value: u5 = @intCast(c_enc.value);
                        try writer.writeBits(value, c_enc.bit_shift);
                    },
                    5 => {
                        const value: u6 = @intCast(c_enc.value);
                        try writer.writeBits(value, c_enc.bit_shift);
                    },
                    6 => {
                        const value: u7 = @intCast(c_enc.value);
                        try writer.writeBits(value, c_enc.bit_shift);
                    },
                    7 => {
                        const value: u8 = @intCast(c_enc.value);
                        try writer.writeBits(value, c_enc.bit_shift);
                    },
                }
                written_bits += c_enc.bit_shift;

            } else {
                log.err(@src(), "Unexpected byte: 0x{x}", .{c});
                return HuffmanError.UnexpectedCharacter;
            }
        }

        try writer.flushBits();
        log.debug(@src(), "wrote {} bits [{} bytes]", .{written_bits, written_bits / 8});
    }

    pub fn dump(self: Self, comptime level: u8, index: usize) void {
        // Compile time generated strings are built based on the level
        if (level == 255) unreachable;

        if (index == self.root_index) {
            log.debug(@src(), "node count: {}", .{self.array.items.len});
            const node = self.array.items[index];
            node.dump(0, "root");
        }

        if (self.array.items[index].left_child_index) |child_index| {
            const node = self.array.items[child_index];
            node.dump(level + 1, "0");
            self.dump(level + 1, child_index);
        }
        if (self.array.items[index].right_child_index) |child_index| {
            const node = self.array.items[child_index];
            node.dump(level + 1, "1");
            self.dump(level + 1, child_index);
        }
    }

    fn walk(
        self: Self,
        index: usize,
        translation: *std.AutoHashMap(u8, NodeEncoding),
        value: u8,
        bit_shift: u3
    ) !void {
        const left_child_index = self.array.items[index].left_child_index;
        const right_child_index = self.array.items[index].right_child_index;

        if (left_child_index) |child_index| {
            // left: 0
            try self.walk(child_index, translation, value, bit_shift + 1);
        }
        if (right_child_index) |child_index| {
            // right: 1
            if (bit_shift > 7) unreachable;
            const one: u8 = 1;
            const new_bit: u8 = one << bit_shift;
            const new_bits = value & new_bit;
            try self.walk(child_index, translation, new_bits, bit_shift + 1);
        }

        if (left_child_index == null and right_child_index == null) {
            // Reached leaf
            if (self.array.items[index].char) |char| {
                const c_enc = NodeEncoding { .bit_shift = bit_shift, .value = value };
                try translation.put(char, c_enc);
            } else {
                log.err(@src(), "Missing character from leaf node", .{});
                return HuffmanError.BadTreeStructure;
            }
        }
    }

};
