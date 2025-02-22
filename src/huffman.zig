const std = @import("std");
const log = @import("log.zig");

const Node = struct {
    /// Only leaf nodes contain a character
    char: ?u8,
    weight: usize,

    fn is_greater(lhs: Node, rhs: Node) bool {
        return lhs.weight > rhs.weight;
    }
};

const HeapError = error{OutOfSpace};

pub fn Heap(comptime T: type) type {
    return struct {
        array: []T,
        count: usize = 0,
        is_greater: fn (lhs: T, rhs: T) bool,

        pub fn init(array: []T, count: usize, is_greater: fn (lhs: T, rhs: T) bool) @This() {
            return @This() { .array = array, .count = count, .is_greater = is_greater };

        }

        pub fn insert(self: *@This(), node: T) !void {
            if (self.count == self.array.len) {
                return HeapError.OutOfSpace;
            }

            // Add the node to the end of the array
            const idx = self.count;
            self.array[idx] = node;
            self.count += 1;

            // Swap it with its parent until it has found its place
            while (true) {
                if (idx == 0) {
                    // Reached root
                    break;
                }

                const parent_idx = (idx - 1) / 2;
                if (self.is_greater(self.array[parent_idx], node)) {
                    // Parent is greater
                    break;
                }

                std.mem.swap(T, &self.array[parent_idx], &self.array[idx]);
                idx = parent_idx;
            }
        }
    };
}

pub const Huffman = struct {
    pub fn init(allocator: std.mem.Allocator, reader: anytype) !@This() {
        var frequencies = std.AutoHashMap(u8, Node).init(allocator);
        defer frequencies.deinit();
        var cnt: usize = 0;

        // Calculate the frequencies for each character in the input stream.
        // This does not scale for large input streams.
        while (true) {
            const c = reader.readByte() catch {
                break;
            };

            if (frequencies.get(c)) |current_node| {
                @constCast(&current_node).weight += 1;
                try frequencies.put(c, current_node);
            } else {
                const new_node = Node{ .char = c, .weight = 1 };
                try frequencies.put(c, new_node);
                cnt += 1;
            }
        }

        log.debug(@src(), "initial node count: {}", .{cnt});
        // var array: []Node = try allocator.alloc(Node, 256);

        // comptime var heap = Heap(Node){ .array = &array, .is_greater = Node.is_greater };
        // for (frequencies) |node| {
        //     heap.insert(node);
        // }

        return @This(){};
    }
};
