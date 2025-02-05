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

fn setup(cmdline: []const u8) std.mem.TokenIterator(u8, .scalar) {
    opts[0].value.str = null;
    opts[1].value.str = null;
    opts[2].value.active = false;

    return std.mem.tokenizeScalar(u8, cmdline, ' ');
}

fn run(iter: *std.mem.TokenIterator(u8, .scalar)) FlagError!?([]const u8) {
    var flags = FlagIterator(std.mem.TokenIterator(u8, .scalar)){ .iter = iter };
    return flags.parse(&opts);
}

test "Parse ok flags" {
    const cmdline = "./tester --alpha alpha_argument -b beta_argument --charlie";
    var iter = setup(cmdline);
    const first_arg = try run(&iter);

    try std.testing.expectEqual(null, first_arg);
    try std.testing.expectEqual(null, iter.next());

    try std.testing.expectEqualStrings("alpha_argument", opts[0].value.str.?);
    try std.testing.expectEqualStrings("beta_argument", opts[1].value.str.?);
    try std.testing.expect(opts[2].value.active);
}

test "Parse ok arguments without flags" {
    const cmdline = "./tester a bb ccc";
    var iter = setup(cmdline);
    const first_arg = try run(&iter);

    try std.testing.expectEqualStrings("a", first_arg.?);
    try std.testing.expectEqualStrings("bb", iter.next().?);
    try std.testing.expectEqualStrings("ccc", iter.next().?);
    try std.testing.expectEqual(null, iter.next());
}

test "Parse ok flags followed by arguments" {
    const cmdline = "./tester --charlie -a alpha_argument a bb ccc";
    var iter = setup(cmdline);
    const first_arg = try run(&iter);

    try std.testing.expectEqualStrings("a", first_arg.?);
    try std.testing.expectEqualStrings("bb", iter.next().?);
    try std.testing.expectEqualStrings("ccc", iter.next().?);
    try std.testing.expectEqual(null, iter.next());

    try std.testing.expectEqualStrings("alpha_argument", opts[0].value.str.?);
    try std.testing.expectEqual(null, opts[1].value.str);
    try std.testing.expect(opts[2].value.active);
}

test "Stop parsing flags after --" {
    const cmdline = "./tester --charlie -a alpha_argument -- -b";
    var iter = setup(cmdline);

    const first_arg = try run(&iter);

    try std.testing.expectEqualStrings("-b", first_arg.?);
    try std.testing.expectEqual(null, iter.next());

    try std.testing.expectEqualStrings("alpha_argument", opts[0].value.str.?);
    try std.testing.expectEqual(null, opts[1].value.str);
    try std.testing.expect(opts[2].value.active);
}

test "Handle unexpected short flag" {
    const cmdline = "./tester --charlie -q";
    var iter = setup(cmdline);
    const r = run(&iter);
    try std.testing.expectError(FlagError.UnexpectedFlag, r);
}

test "Handle unexpected long flag" {
    const cmdline = "./tester -c --quiet";
    var iter = setup(cmdline);
    const r = run(&iter);
    try std.testing.expectError(FlagError.UnexpectedFlag, r);
}
