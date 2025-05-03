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
    \\Usage: z7 [OPTION]... [FILE]
    \\Compress or uncompress FILE (by default, compress in-place).
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
    ///
    /// This array holds the template for the temp file, NULL terminated.
    tmp_outputfile: [15]u8,
};

pub fn main() u8 {
    // For one-shot programs, an arena allocator is useful, it allows us
    // to do allocations and free everything at once with
    // arena.deinit() at the end of the program instead of keeping track
    // of each alloc().
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
    const start_time: f64 = @floatFromInt(std.time.nanoTimestamp());

    var instream = open_input(&ctx) catch |err| {
        log.err(@src(), "Failed to open input stream: {s}", .{@errorName(err)});
        return 1;
    };
    defer instream.close();

    const outstream = open_output(&ctx) catch |err| {
        log.err(@src(), "Failed to open output file: {s}", .{@errorName(err)});
        return 1;
    };
    defer cleanup_tmp_file(&ctx);
    defer outstream.close();

    if (ctx.progress) {
        hide_cursor(outstream) catch |err| {
            log.err(@src(), "Failed to hide cursor: {s}", .{@errorName(err)});
                return 1;
        };
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
        print_stats(ctx.decompress, start_time, instream, outstream) catch {};

        show_cursor(outstream) catch |err| {
            log.err(@src(), "Failed to restore cursor: {s}", .{@errorName(err)});
                return 1;
        };
    }

    if (!ctx.keep) {
        if (ctx.maybe_inputfile) |inputfile| {
            std.fs.Dir.deleteFile(std.fs.cwd(), inputfile) catch |err| {
                log.err(@src(), "Failed to delete input file: {s}", .{@errorName(err)});
                return 1;
            };
        }
    }

    if (ctx.tmp_outputfile[0] != 0) {
        if (ctx.maybe_inputfile) |inputfile| {
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
    const stderr = std.io.getStdErr();

    log.enable_debug = opts['v'].?.value.active;

    if (opts['h'].?.value.active) {
        try stderr.writeAll(usage);
        std.process.exit(0);
    }
    if (opts['V'].?.value.active) {
        try stderr.writeAll(build_options.version ++ "\n");
        std.process.exit(0);
    }
    if (opts['p'].?.value.active and opts['v'].?.value.active) {
        log.err(@src(), "The --progress and --verbose options are mutually exclusive", .{});
        std.process.exit(1);
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
        .tmp_outputfile = .{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
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

        if (!ctx.decompress) {
            const name = try std.fmt.allocPrint(ctx.allocator, "{s}.gz", .{inputfile});
            return try std.fs.cwd().createFile(name, .{});
        }

        // No need for a temporary file if there is a .gz extension
        const len = inputfile.len;
        if (len > 3 and std.mem.eql(u8, inputfile[len - 3..], ".gz")) {
            return try std.fs.cwd().createFile(inputfile[0..len - 3], .{});
        }
        // Replace .tgz extension with .tar for output file
        if (len > 4 and std.mem.eql(u8, inputfile[len - 4..], ".tgz")) {
            const name = try std.fmt.allocPrint(ctx.allocator, "{s}.tar", .{inputfile[0..len - 4]});
            return try std.fs.cwd().createFile(name, .{});
        }

        // Otherwise, create a unique temporary file
        @memcpy(ctx.tmp_outputfile[0..ctx.tmp_outputfile.len - 1], "/tmp/z7.XXXXXX");
        const tmpfile = try util.tmpfile(&ctx.tmp_outputfile);

        log.debug(@src(), "Writing decompressed data to: {s}", .{ctx.tmp_outputfile});
        return tmpfile;
    }

    return std.io.getStdOut();
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

fn hide_cursor(outstream: std.fs.File) !void {
    try util.hide_cursor(std.io.getStdErr());

    if (outstream.handle != std.io.getStdOut().handle) {
        try util.hide_cursor(std.io.getStdOut());
    }
}

fn show_cursor(maybe_outstream: ?std.fs.File) !void {
    _ = std.io.getStdErr().write("\n") catch {};

    try util.show_cursor(std.io.getStdErr());

    if (maybe_outstream) |outstream| {
        if (outstream.handle != std.io.getStdOut().handle) {
            try util.show_cursor(std.io.getStdOut());
        }
    }
}

fn cleanup_tmp_file(ctx: *Z7Context) void {
    if (ctx.tmp_outputfile[0] == 0) return;

    // Remove the temporary output file
    const outfile = ctx.tmp_outputfile[0..ctx.tmp_outputfile.len - 1];
    std.fs.cwd().deleteFile(outfile) catch |err| {
        log.err(@src(), "Failed to remove '{s}': {s}", .{outfile, @errorName(err)});
    };
}

fn print_stats(
    decompressing: bool,
    start_time: f64,
    instream: std.fs.File,
    outstream: std.fs.File,
) !void {
    const input_size: u64 = try instream.getEndPos();
    const output_size: u64 = try outstream.getEndPos();

    const istty = std.io.getStdErr().isTty();
    const end_time: f64 = @floatFromInt(std.time.nanoTimestamp());
    const time_taken: f64 = (end_time - start_time) / 1_000_000_000;

    const m: f64 = @floatFromInt(input_size);
    var k: f64 = undefined;
    var sign: []const u8 = undefined;

    if (input_size == output_size) {
        k = 0.0;
        sign = " ";
    }
    else if (output_size > input_size) {
        k = @floatFromInt(output_size - input_size);
        sign = if (istty and !decompressing) "\x1b[91m+" else "+";
    } else {
        k = @floatFromInt(input_size - output_size);
        sign = if (istty) "\x1b[92m-" else "-";
    }
    const percent = if (m == 0) 0 else 100 * (k / m);
    const ansi_post = if (istty) "\x1b[0m" else "";

    _ = try std.io.getStdErr().writer().print(" => {s}{d:5.1}{s} %, {d: >6.1} sec", .{
        sign,
        percent,
        ansi_post,
        time_taken,
    });
}

fn signal_handler(
    _: i32,
    _: *const std.posix.siginfo_t,
    _: ?*anyopaque,
) callconv(.c) noreturn {
    show_cursor(null) catch {};
    std.process.exit(4);
}
