// zig fmt: off
const std = @import("std");

pub const FlagError = error{UnexpectedArgument};

pub const Flag = struct {
    short: u8,
    long: []const u8,
    value: union(enum) {
        str: ?*u8,
        active: bool
    }
};

pub fn parse(args: *std.process.ArgIterator, comptime flags: []Flag) FlagError!void {
    _ = args.next(); // Skip program name

    var argIdx: ?usize = null;
    while (args.next()) |arg| {
        const is_short = arg.len == 2 and arg[0] == '-';
        const is_long = arg.len > 2 and arg[0] == '-' and arg[1] == '-';

        if (argIdx != null) {
            if (is_short or is_long) {
                // Flag with argument followed by flag encountered
                return FlagError.UnexpectedArgument;
            }
            switch (flags[argIdx.?].value) {
                .active => unreachable,
                .str => flags[argIdx.?].value.str = @ptrCast(@constCast(arg))
            }
            argIdx = null;
        }

        for (0.., flags) |i, flag| {
            if (flag.short == arg[1] or std.mem.eql(u8, arg[2..], flag.long)) {
                switch (flag.value) {
                    .active => flags[i].value.active = true,
                    .str => argIdx = @intCast(i)
                }
                break;
            }
        }
    }
}


test "Parse ok flags" {
    const opt_version = "version";
    const opt_alpha = "alpha";
    const opt_beta = "beta";
    var opts = [_]Flag{
        .{ .short = 'V', .long = opt_version, .value = .{ .active = false } },
        .{ .short = 'a', .long = opt_alpha, .value = .{ .str = null } },
        .{ .short = 'b', .long = opt_beta, .value = .{ .str = null } },
    };
    const args = [_][]const u8{
        "--alpha",
        "alpha_argument",
        "-b",
        "beta_argument"
    };

    try parse(args, &opts);

    try std.testing.expectEqualStrings(opts[1].value.str, args[1]);
}
