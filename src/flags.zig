// zig fmt: off
const std = @import("std");

pub const FlagError = error{
    UnexpectedArgument,
    UnexpectedFlag,
};

pub const Flag = struct {
    short: u8,
    long: []const u8,
    value: union(enum) {
        str: ?[]const u8,
        active: bool
    }
};

/// Generic iterator to enable testing without `std.process.ArgIterator`
pub fn FlagIterator(comptime T: type) type {
    return struct {
        iter: *T,

        pub fn next(self: @This()) ?([] const u8) {
            return self.iter.next();
        }

        /// Returns the first non flag argument if any, additional non-flag
        /// arguments remain in `iter`.
        pub fn parse(self: @This(), comptime flags: []?Flag) FlagError!?([] const u8) {
            // Skip program name
            _ = self.iter.*.next();

            var arg_index: ?usize = null;
            while (self.iter.*.next()) |arg| {
                const is_short = arg.len == 2 and arg[0] == '-';
                const is_long = arg.len > 2 and arg[0] == '-' and arg[1] == '-';

                if (arg_index) |idx| {
                    // Parse as argument for previous flag
                    if (is_short or is_long) {
                        // Flag with argument followed by flag encountered
                        return FlagError.UnexpectedArgument;
                    }
                    if (flags[idx]) |flag| {
                        switch (flag.value) {
                            .active => unreachable,
                            .str => flags[idx].?.value.str = @ptrCast(@constCast(arg))
                        }
                    }
                    arg_index = null;
                }
                else if (std.mem.eql(u8, arg, "--")) {
                    // Stop parsing flags
                    return self.iter.*.next();
                }
                else if (is_short or is_long) {
                    // Parse as a new flag
                    for (0.., flags) |i, maybe_flag| {
                        if (maybe_flag) |flag| {
                            const match_short = flag.short == arg[1];
                            const match_long = std.mem.eql(u8, arg[2..], flag.long);
                            if (match_short or match_long) {
                                switch (flag.value) {
                                    .active => flags[i].?.value.active = true,
                                    .str => arg_index = @intCast(i)
                                }
                                break;
                            }
                        }
                        if (i == flags.len - 1) {
                            return FlagError.UnexpectedFlag;
                        }
                    }
                }
                else {
                    // No more flags
                    return arg;
                }
            }

            return null;
        }
    };
}
