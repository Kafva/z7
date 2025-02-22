const std = @import("std");
const log = @import("log.zig");
const Node = @import("heap.zig").Node;
const Heap = @import("heap.zig").Heap;
const HeapError = @import("heap.zig").HeapError;

test "Heap insert" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var weights = [_]usize{ 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 3, 4, 4, 7, 11 };
    var prng = std.Random.DefaultPrng.init(0);
    prng.random().shuffle(usize, weights[0..]);

    const nodes = try allocator.alloc(Node, weights.len);

    // Insert nodes with weights in random order
    var heap = Heap { .array = nodes };
    for (weights) |weight| {
        const node = Node { .char = null, .weight = weight };
        try heap.insert(node);
    }

    for (0.., heap.array) |i, node| {
        weights[i] = node.weight;
    }

    log.debug(@src(), "heap: {any}", .{weights});

    // Verify that every child has a smaller or equal weight to its parent
    for (0..weights.len) |i| {
        const parent_weight = heap.array[i].weight;

        if (heap.left_child(i)) |child| {
            try std.testing.expect(parent_weight >= child.weight);
        }
        if (heap.right_child(i)) |child| {
            try std.testing.expect(parent_weight >= child.weight);
        }
    }
}

test "Heap out of space" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const nodes = try allocator.alloc(Node, 10);

    // Insert nodes with weights in random order
    var heap = Heap { .array = nodes };
    for (0..12) |i| {
        const node = Node { .char = null, .weight = 1 };
        if (i == 12) {
            std.testing.expectError(.{HeapError.OutOfSpace}, try heap.insert(node));
        }
        else {
            try heap.insert(Node { .char = null, .weight = 1 });
        }
    }
}

