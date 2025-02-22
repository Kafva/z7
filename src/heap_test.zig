const std = @import("std");
const log = @import("log.zig");
const Node = @import("heap.zig").Node;
const Heap = @import("heap.zig").Heap;
const HeapError = @import("heap.zig").HeapError;

test "Heap insert" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var weights = [_]usize{0} ** 2048;
    var prng = std.Random.DefaultPrng.init(0);
    for (0..2048) |i| {
        weights[i] = @truncate(prng.next() % 2000);
    }

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
    for (0..10+1) |i| {
        const node = Node { .char = null, .weight = 1 };
        if (i == 10) {
            try std.testing.expectError(HeapError.OutOfSpace, heap.insert(node));
        }
        else {
            try heap.insert(Node { .char = null, .weight = 1 });
        }
    }
}

