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

const Z7Context = struct {
    allocator: std.mem.Allocator, 
    /// Unset if reading from stdin
    maybe_inputfile: ?[]const u8,
    stdout: bool,
    progress: bool,
    decompress: bool,
    keep: bool,
    mode: FlateCompressMode,
    /// A temporary output file needs to be used during decompression if
    /// the input file does not have a .gz extension
    use_tmp_outputfile: bool,
};

pub fn main() !u8 {
    // For one-shot programs, an arena allocator is useful, it allows us
    // to do allocations and free everything at once with
    // arena.deinit() at the end of the program instead of keeping track
    // of each malloc().
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx: Z7Context = parse_cmdline(allocator) catch |err| {
        log.err(@src(), "Error parsing command line: {any}", .{err});
        return 1;
    };

    // Make sure to restore cursor if --progress option was passed
    // and we quit out with ctrl-c
    if (ctx.progress) {
        var act: std.posix.Sigaction = .{
            .handler = .{ .sigaction = signal_handler },
            .mask = std.posix.empty_sigset,
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
    }

    log.debug(@src(), "Starting z7 {s}", .{build_options.version});

    var instream = open_input(&ctx) catch |err| {
        log.err(@src(), "Failed to open input stream: {s}", .{@errorName(err)});
        return 1;
    };
    defer instream.close();

    const outstream = open_output(&ctx) catch |err| {
        log.err(@src(), "Failed to open output file: {s}", .{@errorName(err)});
        return 1;
    };
    defer outstream.close();

    if (ctx.progress) {
        util.hide_cursor() catch |err| {
            log.err(@src(), "Failed to hide cursor: {s}", .{@errorName(err)});
            return 1;
        };
        defer cleanup_progress();
    }

    if (ctx.decompress) {
        gunzip(allocator, &instream, &outstream, ctx.progress) catch |err| {
            log.err(@src(), "Decompression error: {s}", .{@errorName(err)});
            return 1;
        };
    } else {
        gzip(
            ctx.allocator,
            if (ctx.maybe_inputfile) |f| f else "-",
            &instream,
            &outstream,
            ctx.mode,
            @intFromEnum(GzipFlag.FNAME) | @intFromEnum(GzipFlag.FHCRC),
            ctx.progress
        ) catch |err| {
            log.err(@src(), "Compression error: {s}", .{@errorName(err)});
            return 1;
        };
    }

    if (ctx.progress) {
        _ = std.io.getStdOut().write("\n") catch {};
        util.show_cursor() catch {};
    }

    if (!ctx.keep) {
        if (ctx.maybe_inputfile) |inputfile| {
            std.fs.Dir.deleteFile(std.fs.cwd(), inputfile) catch |err| {
                log.err(@src(), "Failed to delete input file: {s}", .{@errorName(err)});
                return 1;
            };
        }
    }

    if (ctx.maybe_inputfile) |inputfile| {
        if (ctx.use_tmp_outputfile) {
            save_tmp_output(inputfile, &instream, outstream) catch |err| {
                log.err(
                    @src(),
                    "Failed to overwrite input file with decompressed data: {s}",
                    .{@errorName(err)}
                );
                return 1;
            };
        }
    }

    return 0;
}

fn parse_cmdline(allocator: std.mem.Allocator) !Z7Context {
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

    var args = try std.process.argsWithAllocator(allocator);
    var flag_iter = FlagIterator(std.process.ArgIterator){ .iter = &args };
    const maybe_first_arg = try flag_iter.parse(&opts);
    const stdout = std.io.getStdOut();

    log.enable_debug = opts['v'].?.value.active;

    if (opts['h'].?.value.active) {
        try stdout.writeAll(usage);
        std.process.exit(0);
    }
    if (opts['V'].?.value.active) {
        try stdout.writeAll(build_options.version ++ "\n");
        std.process.exit(0);
    }

    return Z7Context {
        .allocator = allocator,
        .maybe_inputfile = maybe_first_arg,
        .stdout = opts['c'].?.value.active,
        .progress = opts['p'].?.value.active,
        .decompress = opts['d'].?.value.active,
        .keep = opts['k'].?.value.active,
        .mode =  blk: {
            if (opts['0'].?.value.active) break :blk FlateCompressMode.NO_COMPRESSION;
            if (opts['1'].?.value.active) break :blk FlateCompressMode.BEST_SPEED;
            break :blk FlateCompressMode.BEST_SIZE;
        },
        .use_tmp_outputfile = blk: {
            // No need for a temporary filename when compressing, just add .gz
            if (!opts['d'].?.value.active) {
                break :blk false;
            }

            if (maybe_first_arg) |first_arg| {
                // Input file lacks a .gz extension, use temporary file
                if (first_arg.len <= 3) {
                    break :blk true;
                }
                const suffix = first_arg[first_arg.len - 3..];
                if (!std.mem.eql(u8, suffix, ".gz")) {
                    break :blk true;
                }
            }
            // Input file has .gz extension
            break :blk false;
        }
    };
}

fn open_input(ctx: *Z7Context) !std.fs.File {
    if (ctx.maybe_inputfile) |inputfile| {
        if (std.mem.eql(u8, inputfile, "-")) {
            return std.io.getStdIn();
        }
        else {
            return try std.fs.cwd().openFile(inputfile, .{ .mode = .read_only });
        }
    }
    return std.io.getStdIn();
}

fn open_output(ctx: *Z7Context) !std.fs.File {
    if (ctx.maybe_inputfile) |inputfile| {
        if (ctx.stdout or std.mem.eql(u8, inputfile, "-")) {
            return std.io.getStdOut();
        }
        const outfile = blk: {
            if (ctx.decompress) {
                if (ctx.use_tmp_outputfile) {
                    return try util.tmpfile();
                }
                else {
                    break :blk inputfile[0..inputfile.len - 3];
                }
            } else {
                break :blk try std.fmt.allocPrint(ctx.allocator, "{s}.gz", .{inputfile});
            }
        };
        return try std.fs.cwd().createFile(outfile, .{});
    }
    else {
        return std.io.getStdOut();
    }
}

fn save_tmp_output(
    inputfile: []const u8,
    instream: *std.fs.File,
    outstream: std.fs.File,
) !void {
    // Reopen the input file, truncated
    instream.close();
    instream.* = try std.fs.cwd().createFile(inputfile, .{ .truncate = true });

    var buf = [_]u8{0} ** 8192;
    var read_bytes: usize = 0;
    const end = try outstream.getEndPos();

    // Overwrite it with the content from the temporary output file
    try outstream.seekTo(0);
    while (read_bytes < end) {
        const cnt = try outstream.readAll(&buf);
        read_bytes += cnt;

        try instream.writeAll(buf[0..cnt]);

        if (cnt < buf.len) {
            break;
        }
    }
}

fn cleanup_progress() void {
    util.show_cursor() catch {};
}

fn signal_handler(
    _: i32,
    _: *const std.posix.siginfo_t,
    _: ?*anyopaque,
) callconv(.c) noreturn {
    cleanup_progress();
    std.process.exit(4);
}
