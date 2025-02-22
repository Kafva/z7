const std = @import("std");
const log = @import("log.zig");

pub const Node = struct {
    /// Only leaf nodes contain a character
    char: ?u8,
    weight: usize,
    left_child: *?@This(),
    right_child: *?@This(),

    pub fn gt(_:void, lhs: @This(), rhs: @This()) bool {
        return lhs.weight > rhs.weight;
    }
};

pub const Huffman = struct {
    pub fn init(allocator: std.mem.Allocator, reader: anytype) !@This() {
        var frequencies = std.AutoHashMap(u8, Node).init(allocator);
        defer frequencies.deinit();
        var cnt: usize = 0;

        // Calculate the frequencies for each character in the input stream.
        // TODO: This does not scale for large input streams.
        while (true) {
            const c = reader.readByte() catch {
                break;
            };

            if (frequencies.get(c)) |current_node| {
                @constCast(&current_node).weight += 1;
                try frequencies.put(c, current_node);
            } else {
                const new_node = Node{
                    .char = c,
                    .weight = 1,
                    .left_child = undefined,
                    .right_child = undefined
                };
                try frequencies.put(c, new_node);
                cnt += 1;
            }
        }

        log.debug(@src(), "initial node count: {}", .{cnt});
        const nodes = try allocator.alloc(Node, 2*cnt);

        var keys = frequencies.keyIterator();
        var index: usize = 0;
        while (keys.next()) |key| {
            const node = frequencies.get(key.*).?;
            nodes[index] = node;
            std.sort.insertion(Node, nodes[0..index], {}, Node.gt);
            index += 1;
        }

        std.debug.print("{any}\n", .{nodes[0..cnt]});

        return @This(){};
    }
};
