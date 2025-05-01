const std = @import("std");
const z7 = @import("z7");
const log = z7.log;
const RingBuffer = z7.ring_buffer.RingBuffer;
const RingBufferError = z7.ring_buffer.RingBufferError;

test "Ring buffer push" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var rbuf = try RingBuffer(u8).init(allocator, 10);
    for (0..12) |i| {
        _ = rbuf.push(@truncate(i));
    }
    try std.testing.expectEqual(10, rbuf.count);

    const expected = [_]u8{10,11,2, 3,4,5, 6,7,8, 9};
    // end_index: ~~~~~~~~~~~~^
    // start_index: ~~~~~~~~~~~~~^
    //
    try std.testing.expectEqualDeep(@constCast(&expected), rbuf.data);
    try std.testing.expectEqual(2, rbuf.start_index);
    try std.testing.expectEqual(1, rbuf.maybe_end_index.?);
}

test "Ring buffer read" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var rbuf = try RingBuffer(u8).init(allocator, 10);
    for (0..12) |i| {
        _ = rbuf.push(@truncate(i));
    }
    try std.testing.expectEqual(10, rbuf.count);

    try std.testing.expectEqual(.{11}, try rbuf.read_offset_end(0,1));
    try std.testing.expectEqual(.{10}, try rbuf.read_offset_end(1,1));
    try std.testing.expectEqual(.{9,10}, try rbuf.read_offset_end(2,2));
    try std.testing.expectEqual(.{8}, try rbuf.read_offset_end(3,1));
    try std.testing.expectEqual(.{7,8,9}, try rbuf.read_offset_end(4,3));
}

test "Ring buffer OOB read" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var rbuf = try RingBuffer(u8).init(allocator, 10);

    try std.testing.expectError(
         RingBufferError.EmptyRead,
        rbuf.read_offset_end(0,1)
    );

    for (0..2) |i| {
        _ = rbuf.push(@truncate(i));
    }
    try std.testing.expectEqual(2, rbuf.count);

    try std.testing.expectError(
         RingBufferError.InvalidOffsetRead,
         rbuf.read_offset_end(2,1)
    );

    try std.testing.expectError(
         RingBufferError.InvalidOffsetRead,
        rbuf.read_offset_end(1,3)
    );

    _ = rbuf.push(@truncate(2));

    try std.testing.expectEqual(.{0}, try rbuf.read_offset_end(2,1));
    try std.testing.expectEqual(.{1}, try rbuf.read_offset_end(1,1));
    try std.testing.expectEqual(.{2}, try rbuf.read_offset_end(0,1));

    try std.testing.expectEqual(.{0}, try rbuf.read_offset_start(0,1));
    try std.testing.expectEqual(.{1}, try rbuf.read_offset_start(1,1));
    try std.testing.expectEqual(.{2}, try rbuf.read_offset_start(2,1));

    try std.testing.expectError(
         RingBufferError.InvalidOffsetRead,
        rbuf.read_offset_end(111, 1)
    );
}

test "Ring buffer prune" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var rbuf = try RingBuffer(u8).init(allocator, 4);
    for (0..4) |i| {
        _ = rbuf.push(@truncate(i));
    }
    try std.testing.expectEqual(4, rbuf.count);
    try std.testing.expectEqual(0, rbuf.prune(1));

    try std.testing.expectEqual(3, rbuf.count);
    try std.testing.expectEqual(1, rbuf.prune(1));

    try std.testing.expectEqual(2, rbuf.count);
    try std.testing.expectEqual(2, rbuf.prune(1));

    try std.testing.expectEqual(1, rbuf.count);
    try std.testing.expectEqual(3, rbuf.prune(1));

    try std.testing.expectEqual(0, rbuf.count);
    try std.testing.expectEqual(null, rbuf.prune(1));
}

test "Ring buffer prune multiple" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var rbuf = try RingBuffer(u8).init(allocator, 4);
    for (0..4) |i| {
        _ = rbuf.push(@truncate(i));
    }
    try std.testing.expectEqual(4, rbuf.count);
    try std.testing.expectEqual(0, rbuf.prune(4));
    try std.testing.expectEqual(0, rbuf.count);
}

test "Ring buffer push after prune" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var rbuf = try RingBuffer(u8).init(allocator, 4);
    for (0..4) |i| {
        _ = rbuf.push(@truncate(i));
    }
    try std.testing.expectEqual(0, rbuf.prune(4));

    for (0..4) |i| {
        try std.testing.expectEqual(null, rbuf.push(@truncate(i)));
    }
    try std.testing.expectEqual(0, rbuf.push(11));
    try std.testing.expectEqual(1, rbuf.push(12));
    try std.testing.expectEqual(2, rbuf.push(13));
    try std.testing.expectEqual(3, rbuf.push(14));
    try std.testing.expectEqual(11, rbuf.push(15));
}
