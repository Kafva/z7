const std = @import("std");
const log = @import("log.zig");

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

pub fn dump_hashmap(
    comptime Value: type,
    map: *const std.AutoHashMap(u8, Value),
) void {
    var keys = map.keyIterator();
    while (keys.next()) |key| {
        if (map.get(key.*)) |enc| {
            if (std.ascii.isPrint(key.*)) {
                log.debug(@src(), "(0x{x}) '{c}' -> {any}", .{key.*, key.*, enc});
            } else {
                log.debug(@src(), "(0x{x})     -> {any}", .{key.*, enc});
            }
        }
    }
}

