// zig fmt: off
const std = @import("std");

pub const FlagError = error{UnexpectedArgument};

pub const Flag = struct {
    short: u8,
    long: []const u8,
    value: union(enum) {
        str: ?[]const u8,
        active: bool
    }
};

pub fn FlagIterator(comptime T: type) type {
    return struct {
        iter: T,

        /// Generic iterator to enable testing without std.process.ArgIterator
        pub fn next(self: @This()) ?([:0] const u8) {
            return self.iter.next();
        }

        pub fn parse(self: @This(), comptime flags: []Flag) FlagError!void {
            // Deconstify the iterator
            var iter = @constCast(&self.iter);

            // Skip program name
            _ = iter.next();

            var argIdx: ?usize = null;
            while (iter.next()) |arg| {
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
    };
}
