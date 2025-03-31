const std = @import("std");
const log = @import("log.zig");
const RingBuffer = @import("ring_buffer.zig").RingBuffer;
const RingBufferError = @import("ring_buffer.zig").RingBufferError;


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

    try std.testing.expectEqual(11, try rbuf.read(0));
    try std.testing.expectEqual(10, try rbuf.read(1));
    try std.testing.expectEqual(9, try rbuf.read(2));
    try std.testing.expectEqual(8, try rbuf.read(3));
    try std.testing.expectEqual(7, try rbuf.read(4));
}
