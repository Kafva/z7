const std = @import("std");
const build_options = @import("build_options");

const log = @import("log.zig");
const Flag = @import("flags.zig").Flag;
const FlagIterator = @import("flags.zig").FlagIterator;
const FlateCompressMode = @import("flate_compress.zig").FlateCompressMode;
const GzipFlag = @import("gzip.zig").GzipFlag;
const gzip = @import("gzip.zig").compress;
const gunzip = @import("gunzip.zig").decompress;

const opt_h = "help";
const opt_V = "version";
const opt_v = "verbose";
const opt_d = "decompress";
const opt_c = "stdout";
const opt_k = "keep";
const opt_0 = "zero";
const opt_1 = "fast";
const opt_9 = "best";
var opts = [_]Flag{
    .{ .short = 'h', .long = opt_h, .value = .{ .active = false } },
    .{ .short = 'V', .long = opt_V, .value = .{ .active = false } },
    .{ .short = 'v', .long = opt_v, .value = .{ .active = false } },
    .{ .short = 'd', .long = opt_d, .value = .{ .active = false } },
    .{ .short = 'c', .long = opt_c, .value = .{ .active = false } },
    .{ .short = 'k', .long = opt_k, .value = .{ .active = false } },
    .{ .short = '0', .long = opt_0, .value = .{ .active = false } },
    .{ .short = '1', .long = opt_1, .value = .{ .active = false } },
    .{ .short = '9', .long = opt_9, .value = .{ .active = false } },
};
const flag_h = 0;
const flag_V = 1;
const flag_v = 2;
const flag_d = 3;
const flag_c = 4;
const flag_k = 5;
const flag_0 = 6;
const flag_1 = 7;
const flag_9 = 8;

const usage =
    \\Usage: z7 [OPTION]... [FILE]...
    \\Compress or uncompress FILEs (by default, compress FILES in-place).
    \\
    \\  -c, --stdout      write on standard output, keep original files unchanged
    \\  -d, --decompress  decompress
    \\  -h, --help        give this help
    \\  -v, --verbose     verbose mode
    \\  -V, --version     display version number
    \\  -k, --keep        keep (don't delete) input files
    \\  -0, --zero        no compression
    \\  -1, --fast        compress faster
    \\  -9, --best        compress better
    \\
;

const Z7Error = error {
    InputFileMissingExtension
};

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

    const keep = opts[flag_k].value.active;
    const gzip_flags = @intFromEnum(GzipFlag.FNAME) | @intFromEnum(GzipFlag.FHCRC);
    const mode: FlateCompressMode = blk: {
        if (opts[flag_0].value.active) break :blk FlateCompressMode.NO_COMPRESSION;
        if (opts[flag_1].value.active) break :blk FlateCompressMode.BEST_SPEED;
        break :blk FlateCompressMode.BEST_SIZE;
    };
    log.enable_debug = opts[flag_v].value.active;
    log.debug(@src(), "Starting z7 {s}", .{build_options.version});

    if (first_arg) |inputfile| {
        const instream = blk: {
            if (std.mem.eql(u8, inputfile, "-")) {
                break :blk std.io.getStdIn();
            }
            else {
                const file = std.fs.cwd().openFile(inputfile, .{}) catch |err| {
                    log.err(@src(), "Failed to open input file: {any}", .{err});
                    return 1;
                };
                break :blk file;
            }
        };
        defer instream.close();

        const outstream = open_output(allocator, inputfile) catch |err| {
            switch (err) {
                Z7Error.InputFileMissingExtension =>
                    log.err(@src(), "Input file is missing .gz extension", .{}),
                else => {
                    log.err(@src(), "Failed to open output file: {any}", .{err});
                }
            }
            return 1;
        };
        defer outstream.close();

        if (opts[flag_d].value.active) {
            try gunzip(allocator, &instream, &outstream);
        } else {
            try gzip(allocator, inputfile, &instream, &outstream, mode, gzip_flags);
        }
        if (!keep) {
            try std.fs.Dir.deleteFile(std.fs.cwd(), inputfile);
        }
    } else {
        try stdout.writeAll(usage);
    }

    return 0;
}

fn open_output(allocator: std.mem.Allocator, inputfile: []const u8) !std.fs.File {
    if (opts[flag_c].value.active) {
        return std.io.getStdOut();
    }
    else {
        const outfile = blk: {
            if (opts[flag_d].value.active) {
                if (inputfile.len <= 3) {
                    return Z7Error.InputFileMissingExtension;
                }
                const suffix = inputfile[inputfile.len - 3..];
                if (!std.mem.eql(u8, suffix, ".gz")) {
                    return Z7Error.InputFileMissingExtension;
                }
                break :blk inputfile[0..inputfile.len - 3];
            } else {
                break :blk try std.fmt.allocPrint(allocator,
                                                  "{s}.gz", .{inputfile});
            }
        };
        return try std.fs.cwd().createFile(outfile, .{});
    }
}
