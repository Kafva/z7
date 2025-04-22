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

pub fn print_bits(
    comptime log_fn:  fn (
        comptime src: std.builtin.SourceLocation,
        comptime format: []const u8,
        args: anytype,
    ) void,
    comptime T: type,
    comptime prefix: []const u8,
    bits: T,
    num_bits: usize,
    offset: usize,
) void {
    const suffix =  " ({d}) [{d} bits] @{d}";
    switch (num_bits) {
        2 =>
            log_fn(
                @src(),
                "{s}: 0b{b:0>2}" ++ suffix,
                .{prefix, bits, bits, num_bits, offset}
            ),
        3 =>
            log_fn(
                @src(),
                "{s}: 0b{b:0>3}" ++ suffix,
                .{prefix, bits, bits, num_bits, offset}
            ),
        4 =>
            log_fn(
                @src(),
                "{s}: 0b{b:0>4}" ++ suffix,
                .{prefix, bits, bits, num_bits, offset}
            ),
        5 =>
            log_fn(
                @src(),
                "{s}: 0b{b:0>5}" ++ suffix,
                .{prefix, bits, bits, num_bits, offset}
            ),
        6 =>
            log_fn(
                @src(),
                "{s}: 0b{b:0>6}" ++ suffix,
                .{prefix, bits, bits, num_bits, offset}
            ),
        7 =>
            log_fn(
                @src(),
                "{s}: 0b{b:0>7}" ++ suffix,
                .{prefix, bits, bits, num_bits, offset}
            ),
        8 =>
            log_fn(
                @src(),
                "{s}: 0b{b:0>8}" ++ suffix,
                .{prefix, bits, bits, num_bits, offset}
            ),
        16 =>
            log_fn(
                @src(),
                "{s}: 0b{b:0>16}" ++ suffix,
                .{prefix, bits, bits, num_bits, offset}
            ),
        else =>
            log_fn(
                @src(),
                "{s}: 0b{b}" ++ suffix,
                .{prefix, bits, bits, num_bits, offset}
            ),
    }
}

pub fn print_bytes(comptime prefix: []const u8, bs: [4]u8) void {
    var printable = true;
    for (0..4) |i| {
        if (!std.ascii.isPrint(bs[i])) {
            printable = false;
            break;
        }
    }
    if (printable) {
        log.debug(@src(), prefix ++ ": '{c}{c}{c}{c}'", .{
            bs[0], bs[1], bs[2], bs[3]
        });
    }
    else {
        log.debug(@src(), prefix ++ ": {{{d},{d},{d},{d}}}", .{
            bs[0], bs[1], bs[2], bs[3]
        });
    }
}

pub fn print_char(
    comptime log_fn:  fn (
        comptime src: std.builtin.SourceLocation,
        comptime format: []const u8,
        args: anytype,
    ) void,
    comptime prefix: []const u8,
    byte: u8,
) void {
    if (std.ascii.isPrint(byte) and byte != '\n') {
        log_fn(@src(), "{s}: '{c}'", .{prefix, byte});
    } else {
        log_fn(@src(), "{s}: 0x{x}", .{prefix, byte});
    }
}

pub fn strtime(epoch: u32) [*c]u8 {
    const c_epoch: ctime.time_t = epoch;
    const tm = ctime.localtime(&c_epoch);
    var s = ctime.asctime(tm);
    const len = std.mem.len(s);
    s[len - 1] = 0;
    return s;
}
