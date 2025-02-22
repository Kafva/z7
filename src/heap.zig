const std = @import("std");

pub const Node = struct {
    /// Only leaf nodes contain a character
    char: ?u8,
    weight: usize,
};

pub const HeapError = error{OutOfSpace};

pub const Heap = struct {
    array: []Node,
    count: usize = 0,

    pub fn insert(self: *@This(), node: Node) !void {
        if (self.count == self.array.len) {
            return HeapError.OutOfSpace;
        }

        // Add the node to the end of the array
        var idx = self.count;
        self.array[idx] = node;
        self.count += 1;

        // Swap it with its parent until it has found its place
        while (true) {
            if (idx == 0) {
                // Reached root
                break;
            }

            const parent_index = (idx - 1) / 2;
            if (self.array[parent_index].weight >= self.array[idx].weight) {
                // Parent is greater or equal
                break;
            }

            std.mem.swap(Node, &self.array[parent_index], &self.array[idx]);
            idx = parent_index;
        }
    }

    pub fn left_child(self: @This(), idx: usize) ?Node {
        return self.child(idx, true);
    }

    pub fn right_child(self: @This(), idx: usize) ?Node {
        return self.child(idx, false);
    }

    fn child(self: @This(), idx: usize, left: bool) ?Node {
        const child_index = if (left) 2 * idx + 1 else 2 * idx + 2;
        if (child_index > self.count - 1) {
            return null;
        }

        return self.array[child_index];
    }
};

