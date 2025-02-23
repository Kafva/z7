const std = @import("std");

/// Create an array with `c` repeated `count` times
pub fn repeat(comptime c: u8, comptime count: u8) ![]const u8 {
    if (count == 0) return "";

    var result = std.ArrayList(u8).init(std.heap.page_allocator);
    defer result.deinit();

    for (0..count) |_| {
        try result.append(c);
    }
    return result.toOwnedSlice();
}

