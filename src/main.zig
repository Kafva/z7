const std = @import("std");
const build_options = @import("build_options");

const log = @import("log.zig");
const Flag = @import("flags.zig").Flag;
const FlagIterator = @import("flags.zig").FlagIterator;
const Flate = @import("flate.zig").Flate;

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
const flag_h = 0;
const flag_V = 1;
const flag_v = 2;
const flag_d = 3;
const flag_c = 4;

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

    if (opts[flag_h].value.active) {
        try stdout.writeAll(usage);
        return 0;
    }
    if (opts[flag_V].value.active) {
        try stdout.writeAll(build_options.version);
        try stdout.writeAll("\n");
        return 0;
    }
    log.enable_debug = opts[flag_v].value.active;
    log.debug(@src(), "Starting z7 {s}", .{build_options.version});

    if (first_arg) |inputfile| {
        const flate = Flate {
            .allocator = allocator,
            .lookahead_length = 32,
            .window_length = 128,
        };
        const instream = blk: {
            if (std.mem.eql(u8, inputfile, "-")) {
                break :blk std.io.getStdIn();
            }
            else {
                const file = try std.fs.cwd().openFile(inputfile, .{});
                break :blk file;
            }
        };
        defer instream.close();

        const outstream = blk: {
            if (opts[flag_c].value.active) {
                break :blk std.io.getStdOut();
            }
            else {
                const outfile = inner_blk: {
                    if (opts[flag_d].value.active) {
                        if (inputfile.len <= 3) {
                            log.err(@src(), "Input file is missing .gz extension", .{});
                            return 1;
                        }
                        const suffix = inputfile[inputfile.len - 2..];
                        if (!std.mem.eql(u8, suffix, ".gz")) {
                            log.err(@src(), "Input file is missing .gz extension", .{});
                            return 1;
                        }
                        break :inner_blk inputfile[0..inputfile.len - 3];
                    } else {
                        break :inner_blk try std.fmt.allocPrint(allocator,
                                                                "{s}.gz", .{inputfile});
                    }
                };
                break :blk try std.fs.cwd().openFile(outfile, .{});
            }
        };
        defer outstream.close();

        if (opts[flag_d].value.active) {
            log.debug(@src(), "Decompressing: {s}", .{inputfile});
            try flate.decompress(instream, outstream);
        } else {
            log.debug(@src(), "Compressing: {s}", .{inputfile});
            try flate.compress(instream, outstream);
        }
    } else {
        try stdout.writeAll(usage);
    }

    return 0;
}
