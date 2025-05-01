const std = @import("std");
const build_options = @import("build_options");

const util = @import("util.zig");
const log = @import("log.zig");
const Flag = @import("flags.zig").Flag;
const FlagIterator = @import("flags.zig").FlagIterator;
const FlateCompressMode = @import("flate_compress.zig").FlateCompressMode;
const GzipFlag = @import("gzip.zig").GzipFlag;
const gzip = @import("gzip.zig").compress;
const gunzip = @import("gunzip.zig").decompress;

var opts = [_]?Flag{null} ** 256;

const usage =
    \\Usage: z7 [OPTION]... [FILE]...
    \\Compress or uncompress FILEs (by default, compress FILES in-place).
    \\
    \\  -c, --stdout      write on standard output, keep original files unchanged
    \\  -d, --decompress  decompress
    \\  -p, --progress    show progress
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

    opts['h'] = .{ .short = 'h', .long = "help", .value = .{ .active = false } };
    opts['V'] = .{ .short = 'V', .long = "version", .value = .{ .active = false } };
    opts['p'] = .{ .short = 'p', .long = "progress", .value = .{ .active = false } };
    opts['v'] = .{ .short = 'v', .long = "verbose", .value = .{ .active = false } };
    opts['d'] = .{ .short = 'd', .long = "decompress", .value = .{ .active = false } };
    opts['c'] = .{ .short = 'c', .long = "stdout", .value = .{ .active = false } };
    opts['k'] = .{ .short = 'k', .long = "keep", .value = .{ .active = false } };
    opts['0'] = .{ .short = '0', .long = "zero", .value = .{ .active = false } };
    opts['1'] = .{ .short = '1', .long = "fast", .value = .{ .active = false } };
    opts['9'] = .{ .short = '9', .long = "best", .value = .{ .active = false } };

    const stdout = std.io.getStdOut().writer();

    var args = try std.process.argsWithAllocator(allocator);
    var flags = FlagIterator(std.process.ArgIterator){ .iter = &args };
    const first_arg = try flags.parse(&opts);

    if (opts['h'].?.value.active) {
        try stdout.writeAll(usage);
        return 0;
    }

    const progress = opts['p'].?.value.active;
    const keep = opts['k'].?.value.active;
    const gzip_flags = @intFromEnum(GzipFlag.FNAME) | @intFromEnum(GzipFlag.FHCRC);
    const mode: FlateCompressMode = blk: {
        if (opts['0'].?.value.active) break :blk FlateCompressMode.NO_COMPRESSION;
        if (opts['1'].?.value.active) break :blk FlateCompressMode.BEST_SPEED;
        break :blk FlateCompressMode.BEST_SIZE;
    };
    log.enable_debug = opts['v'].?.value.active;

    // Make sure to restore cursor if --progress option was passed
    // and we quit out with ctrl-c
    if (progress) {
        var act: std.posix.Sigaction = .{
            .handler = .{ .sigaction = signal_handler },
            .mask = std.posix.empty_sigset,
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
    }

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

        if (progress) {
            try util.hide_cursor();
        }

        if (opts['d'].?.value.active) {
            try gunzip(allocator, &instream, &outstream, progress);
        } else {
            try gzip(
                allocator,
                inputfile,
                &instream,
                &outstream,
                mode,
                gzip_flags,
                progress
            );
        }

        if (progress) {
            _ = try std.io.getStdOut().write("\n");
            try util.show_cursor();
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
    if (opts['c'].?.value.active) {
        return std.io.getStdOut();
    }
    else {
        const outfile = blk: {
            if (opts['d'].?.value.active) {
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

fn signal_handler(
    _: i32,
    _: *const std.posix.siginfo_t,
    _: ?*anyopaque,
) callconv(.c) noreturn {
    _ = std.io.getStdOut().write("\n") catch {};
    util.show_cursor() catch {};
    std.process.exit(4);
}
