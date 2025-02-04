const std = @import("std");
const Flag = @import("flags.zig").Flag;
const FlagError = @import("flags.zig").FlagError;
const FlagIterator = @import("flags.zig").FlagIterator;

const opt_a = "alpha";
const opt_b = "beta";
const opt_c = "charlie";
var opts = [_]Flag{
    .{ .short = 'a', .long = opt_a, .value = .{ .str = null } },
    .{ .short = 'b', .long = opt_b, .value = .{ .str = null } },
    .{ .short = 'c', .long = opt_c, .value = .{ .active = false } },
};

test "Parse ok flags" {
    const cmdline = "./tester --alpha alpha_argument -b beta_argument --charlie";
    const iter = std.mem.splitScalar(u8, cmdline, ' ');
    var flags = FlagIterator(std.mem.SplitIterator(u8, .scalar)){ .iter = iter };

    try flags.parse(&opts);
    try std.testing.expectEqualStrings("alpha_argument", opts[0].value.str.?);
    try std.testing.expectEqualStrings("beta_argument", opts[1].value.str.?);
    try std.testing.expect(opts[2].value.active);
}

test "Parse bad flags" {
    const cmdline = "./tester --bad";
    const iter = std.mem.splitScalar(u8, cmdline, ' ');
    var flags = FlagIterator(std.mem.SplitIterator(u8, .scalar)){ .iter = iter };

    _ = flags.parse(&opts) catch |e| {
        // TODO is this skipped on success?
        try std.testing.expectEqual(FlagError.UnexpectedArgument, e);
    };
}
