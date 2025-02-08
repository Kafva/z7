const std = @import("std");

pub var enable_debug: bool = false;

fn log(
    comptime level: std.log.Level,
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    const ansi_color = comptime switch (level) {
        .debug => "\x1b[34m",
        .info => "\x1b[32m",
        .warn => "\x1b[33m",
        .err => "\x1b[31m",
    };
    const level_text = comptime level.asText();

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    const stderr = std.io.getStdErr().writer();
    const fmt = std.fmt.comptimePrint("{s}{s}\x1b[0m: [{s}:{any}] {s}\n", .{ ansi_color, level_text, src.file, src.line, format });
    nosuspend stderr.print(fmt, args) catch return;
}

pub fn debug(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    if (!enable_debug) {
        return;
    }
    log(.debug, src, format, args);
}

pub fn info(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    log(.info, src, format, args);
}

pub fn warn(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    log(.warn, src, format, args);
}

pub fn err(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    log(.err, src, format, args);
}
