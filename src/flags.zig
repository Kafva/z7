const std = @import("std");

pub const Flag = struct {
    short: u8,
    long: *const u8,
    reqArg: bool,
    value: ?*u8,
};

pub fn parse(args: *std.process.ArgIterator, comptime flags: []const Flag) void {
    _ = args.next(); // Skip program name

    while (args.next()) |arg| {
        std.debug.print("arg: {s}\n", .{arg});
    }

    for (flags) |obj| {
        std.debug.print("flag: {any}\n", .{obj});
    }
}
