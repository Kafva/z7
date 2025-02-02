const std = @import("std");

pub const Flag = struct {
    /// 2:0, 2 bytes with null termination
    short: *const [2:0]u8,
    long: *const [9:0]u8,
    reqArg: bool,
    value: ?*u8,
};

pub fn parse(args: *std.process.ArgIterator, comptime flags: *const [1]Flag) void {
    _ = args.next(); // Skip program name

    while (args.next()) |arg| {
        std.debug.print("arg: {s}\n", .{arg});
    }

    for (flags) |obj| {
        std.debug.print("flag: {any}\n", .{obj});
    }
}
