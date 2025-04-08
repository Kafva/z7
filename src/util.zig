const std = @import("std");
const log = @import("log.zig");

const ctime = @cImport({
    @cInclude("time.h");
});

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
    offset: usize,
) void {
    const suffix =  " ({d}) [{d} bits] @{d}";
    switch (num_bits) {
        2 =>
            log.debug(
                @src(),
                "{s}: 0b{b:0>2}" ++ suffix,
                .{prefix, bits, bits, num_bits, offset}
            ),
        3 =>
            log.debug(
                @src(),
                "{s}: 0b{b:0>3}" ++ suffix,
                .{prefix, bits, bits, num_bits, offset}
            ),
        4 =>
            log.debug(
                @src(),
                "{s}: 0b{b:0>4}" ++ suffix,
                .{prefix, bits, bits, num_bits, offset}
            ),
        5 =>
            log.debug(
                @src(),
                "{s}: 0b{b:0>5}" ++ suffix,
                .{prefix, bits, bits, num_bits, offset}
            ),
        6 =>
            log.debug(
                @src(),
                "{s}: 0b{b:0>6}" ++ suffix,
                .{prefix, bits, bits, num_bits, offset}
            ),
        7 =>
            log.debug(
                @src(),
                "{s}: 0b{b:0>7}" ++ suffix,
                .{prefix, bits, bits, num_bits, offset}
            ),
        8 =>
            log.debug(
                @src(),
                "{s}: 0b{b:0>8}" ++ suffix,
                .{prefix, bits, bits, num_bits, offset}
            ),
        16 =>
            log.debug(
                @src(),
                "{s}: 0b{b:0>16}" ++ suffix,
                .{prefix, bits, bits, num_bits, offset}
            ),
        else =>
            log.debug(
                @src(),
                "{s}: 0b{b}" ++ suffix,
                .{prefix, bits, bits, num_bits, offset}
            ),
    }
}

pub fn print_char(
    comptime prefix: []const u8,
    byte: u8,
) void {
    if (std.ascii.isPrint(byte) and byte != '\n') {
        log.debug(@src(), "{s}: '{c}'", .{prefix, byte});
    } else {
        log.debug(@src(), "{s}: '0x{x}'", .{prefix, byte});
    }
}

pub fn strtime(epoch: u32) [*c]u8 {
    const c_epoch: ctime.time_t = epoch;
    const timeinfo = ctime.localtime(&c_epoch);
    var s = ctime.asctime(timeinfo);
    const len = std.mem.len(s);
    s[len - 1] = 0;
    return s;
}
