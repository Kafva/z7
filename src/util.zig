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
    comptime Key: type,
    comptime Value: type,
    map: *const std.AutoHashMap(Key, Value),
) void {
    var keys = map.keyIterator();
    while (keys.next()) |key| {
        if (map.get(key.*)) |enc| {
            log.debug(@src(), "0b{b} ({d}) -> {any}", .{key.*, key.*, enc});
        }
    }
}

pub fn print_bits(
    comptime T: type,
    comptime prefix: []const u8,
    bits: T,
    num_bits: usize,
) void {
    switch (num_bits) {
        7 =>
            log.debug(
                @src(),
                "{s}: 0b{b:0>7} ({d}) [{d} bits]",
                .{prefix, bits, bits, num_bits}
            ),
        8 =>
            log.debug(
                @src(),
                "{s}: 0b{b:0>8} ({d}) [{d} bits]",
                .{prefix, bits, bits, num_bits}
            ),
        else =>
            log.debug(
                @src(),
                "{s}: 0b{b} ({d}) [{d} bits]",
                .{prefix, bits, bits, num_bits}
            ),
    }
}

