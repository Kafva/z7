const std = @import("std");
const z7 = @import("z7");
const log = z7.log; 
const RingBuffer = z7.ring_buffer.RingBuffer;
const RingBufferError = z7.ring_buffer.RingBufferError;

test "Ring buffer push" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var rbuf = try RingBuffer(u8).init(allocator, 10);
    for (0..12) |i| {
        rbuf.push(@truncate(i));
    }

    const expected = [_]u8{10,11,2, 3,4,5, 6,7,8, 9};
    // end_index: ~~~~~~~~~~~~^
    // start_index: ~~~~~~~~~~~~~^
    //
    try std.testing.expectEqualDeep(@constCast(&expected), rbuf.data);
    try std.testing.expectEqual(2, rbuf.start_index);
    try std.testing.expectEqual(1, rbuf.end_index);
}

test "Ring buffer read" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var rbuf = try RingBuffer(u8).init(allocator, 10);
    for (0..12) |i| {
        rbuf.push(@truncate(i));
    }

    try std.testing.expectEqual(11, try rbuf.read_offset_end(0));
    try std.testing.expectEqual(10, try rbuf.read_offset_end(1));
    try std.testing.expectEqual(9, try rbuf.read_offset_end(2));
    try std.testing.expectEqual(8, try rbuf.read_offset_end(3));
    try std.testing.expectEqual(7, try rbuf.read_offset_end(4));
}

test "Ring buffer OOB read" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var rbuf = try RingBuffer(u8).init(allocator, 10);

    try std.testing.expectError(
         RingBufferError.EmptyRead,
        rbuf.read_offset_end(0)
    );

    for (0..2) |i| {
        rbuf.push(@truncate(i));
    }

    try std.testing.expectError(
         RingBufferError.InvalidOffsetRead,
         rbuf.read_offset_end(2)
    );

    rbuf.push(@truncate(2));

    try std.testing.expectEqual(0, try rbuf.read_offset_end(2));
    try std.testing.expectEqual(1, try rbuf.read_offset_end(1));
    try std.testing.expectEqual(2, try rbuf.read_offset_end(0));

    try std.testing.expectEqual(0, try rbuf.read_offset_start(0));
    try std.testing.expectEqual(1, try rbuf.read_offset_start(1));
    try std.testing.expectEqual(2, try rbuf.read_offset_start(2));

    try std.testing.expectError(
         RingBufferError.InvalidOffsetRead,
        rbuf.read_offset_end(111)
    );
}
