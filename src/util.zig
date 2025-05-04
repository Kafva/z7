const std = @import("std");
const log = @import("log.zig");

const ctime = @cImport({
    @cInclude("time.h");
});

const cunistd = @cImport({
    @cInclude("unistd.h");
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

pub fn print_bytes(
    comptime log_fn:  fn (
        comptime src: std.builtin.SourceLocation,
        comptime format: []const u8,
        args: anytype,
    ) void,
    comptime prefix: []const u8,
    bs: [4]u8,
) void {
    var printable = true;
    for (0..4) |i| {
        if (!std.ascii.isPrint(bs[i])) {
            printable = false;
            break;
        }
    }
    if (printable) {
        log_fn(@src(), prefix ++ ": '{c}{c}{c}{c}'", .{
            bs[0], bs[1], bs[2], bs[3]
        });
    }
    else {
        log_fn(@src(), prefix ++ ": {{{d},{d},{d},{d}}}", .{
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
        log_fn(@src(), "{s}: 0x{x:0>2}", .{prefix, byte});
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

pub fn progress(
    comptime label: []const u8,
    current_bytes: usize,
    total_bytes: f64,
) !void {
    const current: f64 = @floatFromInt(current_bytes);
    const percent: f64 = 100 * (current / total_bytes);
    try std.io.getStdErr().writer().print("\r[{d:5.1} %] {s}", .{percent, label});
}

pub fn hide_cursor(f: std.fs.File) !void {
    _ = try nosuspend f.write("\x1b[?25l");
}

pub fn show_cursor(f: std.fs.File) !void {
    _ = try nosuspend f.write("\x1b[?25h");
}

pub fn tmpfile(tmpl: *[15]u8) !std.fs.File {
    const ptr: [*c]u8 = tmpl;

    const fd = cunistd.mkstemp(ptr);
    if (fd == -1) {
        log.err(@src(), "mkstemp failed", .{});
        return std.fs.File.OpenError.Unexpected;
    }
    std.posix.close(fd);

    return std.fs.cwd().openFile(tmpl[0..tmpl.len - 1], .{ .mode = .read_write });
}
