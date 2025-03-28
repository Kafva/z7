const std = @import("std");
const build_options = @import("build_options");

pub var enable_debug: bool = false;

fn log(
    comptime level: std.log.Level,
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    if (std.io.getStdErr().isTty()) {
        const ansi_color = comptime switch (level) {
            .debug => "\x1b[34m",
            .info => "\x1b[32m",
            .warn => "\x1b[33m",
            .err => "\x1b[31m",
        };
        log_write(level, src, ansi_color, "\x1b[0m", format, args);
    }
    else {
        log_write(level, src, "", "", format, args);
    }
}

fn log_write(
    comptime level: std.log.Level,
    comptime src: std.builtin.SourceLocation,
    comptime ansi_pre: []const u8,
    comptime ansi_post: []const u8,
    comptime format: []const u8,
    args: anytype,
) void {
    const level_text = comptime level.asText();

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    const writer = std.io.getStdErr().writer();
    const fmt = std.fmt.comptimePrint("{s}{s}{s}: [{s}:{any}] {s}\n", .{
        ansi_pre,
        level_text,
        ansi_post,
        src.file,
        src.line,
        format
    });
    nosuspend writer.print(fmt, args) catch return;
}

pub fn debug(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    if (build_options.debug or enable_debug) {
        log(.debug, src, format, args);
    }
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
