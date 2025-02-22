const std = @import("std");
const log = @import("log.zig");
const Node = @import("heap.zig").Node;

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

        var array: []Node = try allocator.alloc(Node, cnt);
        var idx: usize = 0;

        var keys = frequencies.keyIterator();
        while (keys.next()) |key| {
            array[idx] = frequencies.get(key.*).?;
            idx += 1;
        }

        // Sort into a max heap
        // std.sort.heap(Node, array, {}, Node.order);

        // log.debug(@src(), "{any}", .{array});

        // std.sort.insertion()

        // var array: []Node = try allocator.alloc(Node, 256);
        // comptime var heap = Heap(Node){ .array = &array, .is_greater = Node.is_greater };
        // for (frequencies) |node| {
        //     heap.insert(node);
        // }

        return @This(){};
    }
};
