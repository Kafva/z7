const std = @import("std");
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

    pub fn dump(self: @This(), level: usize, pos: []const u8) void {
        if (self.char) |char| {
            log.debug(@src(), "#{d} [{s}]: {{ .weight = {d}, .char = '{c}' }}",
                              .{level, pos, self.weight, char});
        } else {
            log.debug(@src(), "#{d} [{s}]: {{ .weight = {d} }}",
                              .{level, pos, self.weight});
        }
    }
};

const HuffmanError = error {
    UnexpectedCharacter,
    UnexpectedBitCount,
};

const NodeEncoding = struct {
    bit_count: u8,
    value: u8
};

pub const Huffman = struct {
    const Self = @This();

    array: std.ArrayList(Node),
    translation: std.AutoHashMap(u8, NodeEncoding),
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

        // 3. Create the tree
        log.debug(@src(), "initial node count: {}", .{queue_cnt});

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

        log.debug(@src(), "tree node count: {}", .{array_cnt});

        // 4. Create the translation map from 1 byte characters onto
        // encoded huffman symbols.
        const translation = std.AutoHashMap(u8, NodeEncoding).init(allocator);

        return @This(){ .array = array, .root_index = array_cnt - 1, .translation = translation };
    }

    pub fn encode(self: Self, reader: anytype, outstream: anytype) !void {
        var writer = std.io.bitWriter(.little, outstream.writer());

        while (true) {
            const c = reader.readByte() catch {
                return;
            };

            if (self.translation.get(c)) |c_enc| {
                switch (c_enc.bit_count) {
                    1 => try writer.writeBits(@as(u1, c_enc.value), 1),
                    2 => try writer.writeBits(@as(u2, c_enc.value), 2),
                    3 => try writer.writeBits(@as(u3, c_enc.value), 3),
                    4 => try writer.writeBits(@as(u4, c_enc.value), 4),
                    5 => try writer.writeBits(@as(u5, c_enc.value), 5),
                    6 => try writer.writeBits(@as(u6, c_enc.value), 6),
                    7 => try writer.writeBits(@as(u7, c_enc.value), 7),
                    8 => try writer.writeBits(@as(u8, c_enc.value), 8),
                    else => return HuffmanError.UnexpectedBitCount
                }
            } else {
                return HuffmanError.UnexpectedCharacter;
            }

        }

    }


    pub fn dump(self: Self, level: usize, idx: usize) void {
        if (idx == self.root_index) {
            const node = self.array.items[idx];
            node.dump(level, "root");
        }

        if (self.array.items[idx].left_child_index) |child_index| {
            const node = self.array.items[child_index];
            node.dump(level + 1, "left");
            self.dump(level + 1, child_index);
        }
        if (self.array.items[idx].right_child_index) |child_index| {
            const node = self.array.items[child_index];
            node.dump(level + 1, "right");
            self.dump(level + 1, child_index);
        }
    }
};
