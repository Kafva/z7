const std = @import("std");
const build_options = @import("build_options");

const log = @import("log.zig");
const Flag = @import("flags.zig").Flag;
const FlagIterator = @import("flags.zig").FlagIterator;
const deflate = @import("deflate.zig");

const opt_h = "help";
const opt_V = "version";
const opt_v = "verbose";
const opt_d = "decompress";
const opt_c = "stdout";
var opts = [_]Flag{
    .{ .short = 'h', .long = opt_h, .value = .{ .active = false } },
    .{ .short = 'V', .long = opt_V, .value = .{ .active = false } },
    .{ .short = 'v', .long = opt_v, .value = .{ .active = false } },
    .{ .short = 'd', .long = opt_d, .value = .{ .active = false } },
    .{ .short = 'c', .long = opt_c, .value = .{ .active = false } },
};

const usage =
    \\Usage: z7 [OPTION]... [FILE]...
    \\Compress or uncompress FILEs (by default, compress FILES in-place).
    \\
    \\  -c, --stdout      write on standard output, keep original files unchanged
    \\  -d, --decompress  decompress
    \\  -h, --help        give this help
    \\  -v, --verbose     verbose mode
    \\  -V, --version     display version number
    \\
;

pub fn main() !u8 {
    // For one-shot programs, an arena allocator is useful, it allows us
    // to do allocations and free everything at once with
    // arena.deinit() at the end of the program instead of keeping track
    // of each malloc().
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const stdout = std.io.getStdOut().writer();

    var args = try std.process.argsWithAllocator(allocator);
    var flags = FlagIterator(std.process.ArgIterator){ .iter = &args };
    const first_arg = try flags.parse(&opts);

    if (opts[0].value.active) {
        try stdout.writeAll(usage);
        return 0;
    }
    if (opts[1].value.active) {
        try stdout.writeAll(build_options.version);
        try stdout.writeAll("\n");
        return 0;
    }
    log.enable_debug = opts[2].value.active;
    log.debug(@src(), "Starting z7 {s}", .{build_options.version});

    if (first_arg) |a| {
        const file = try std.fs.cwd().openFile(a, .{});
        defer file.close();

        const buffer_size = 1024;
        const buf = file.readToEndAlloc(allocator, buffer_size) catch |err| {
            log.err(@src(), "Error reading {s}: {any}", .{ a, err });
            return 1;
        };

        if (opts[4].value.active) {
            try deflate.inflate(buf);
        } else {
            try deflate.deflate(buf);
        }
    } else {
        try stdout.writeAll(usage);
    }

    return 0;
}
