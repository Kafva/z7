const std = @import("std");

pub const FlagError = error{ UnexpectedArgument };

pub const Flag = struct { short: u8, long: *const [7:0]u8, reqArg: bool, value: union { str: ?*u8, active: bool } };

pub fn parse(args: *std.process.ArgIterator, comptime flags: []Flag) FlagError!void {
    _ = args.next(); // Skip program name

    var flagArgIndex: i8 = -1;
    while (args.next()) |arg| {
        for (0.., flags) |i, flag| {
            const is_short = arg.len == 2 and arg[0] == '-' and flag.short == arg[1];
            const is_long = arg.len > 2 and arg[0] == '-' and arg[1] == '-' and
                std.mem.eql(u8, arg[2..], flag.long);
            if (is_short or is_long) {
                if (flagArgIndex != -1) {
                    return FlagError.UnexpectedArgument;
                } else if (flag.reqArg) {
                    flagArgIndex = @intCast(i);
                } else {
                    flags[i].value.active = true;
                }
            } else if (flagArgIndex != -1) {
                flags[i].value.str = @ptrCast(@constCast(arg));
                flagArgIndex = -1;
            } else {
                // No more flags
                break;
            }
        }
    }
}
