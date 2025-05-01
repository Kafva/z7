const std = @import("std");
const z7 = @import("z7");

const TestContext = @import("context_test.zig").TestContext;

const log = z7.log;
const GzipFlag = z7.gzip.GzipFlag;
const FlateCompressMode = z7.flate_compress.FlateCompressMode;
const gzip = z7.gzip.compress;
const gunzip = z7.gunzip.decompress;

const libflate = @cImport({
    @cInclude("libflate.h");
});

fn run(
    inputfile: []const u8,
    label: []const u8,
    runFn: fn (*TestContext) @typeInfo(@TypeOf(check_z7_ok)).@"fn".return_type.?,
    mode: FlateCompressMode,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try TestContext.init(allocator, inputfile, label);
    defer ctx.deinit();

    ctx.maybe_mode = mode;
    try runFn(&ctx);
}

/// Verify that z7 can decompress its own output (gzip)
fn check_z7_ok(ctx: *TestContext) !void {
    try gzip(
        ctx.allocator,
        ctx.inputfile,
        &ctx.in,
        &ctx.compressed,
        ctx.maybe_mode.?,
        // XXX: gzstat.py does not handle gzip flags
        @intFromEnum(GzipFlag.FNAME) | @intFromEnum(GzipFlag.FHCRC),
        false,
    );
    ctx.end_time_compress = @floatFromInt(std.time.nanoTimestamp());

    try gunzip(ctx.allocator, &ctx.compressed, &ctx.decompressed, false);

    try ctx.log_result(try ctx.compressed.getPos());

    // Verify correct decompression
    try ctx.eql(ctx.in, ctx.decompressed);
}

/// Compress with Golang and decompress with z7
fn check_go_decompress_z7(ctx: *TestContext) !void {
    const compressed_len = libflate.Gzip(
        try ctx.inputfile_s(),
        try ctx.compressed_path_s(),
        @intFromEnum(ctx.maybe_mode.?),
    );
    ctx.end_time_compress = @floatFromInt(std.time.nanoTimestamp());

    try std.testing.expect(compressed_len > 0);

    try gunzip(ctx.allocator, &ctx.compressed, &ctx.decompressed, false);

    // Verify correct decompression
    try ctx.eql(ctx.in, ctx.decompressed);
}

/// Compress with z7 and decompress with Golang
fn check_z7_decompress_go(ctx: *TestContext) !void {
    try gzip(ctx.allocator, ctx.inputfile, &ctx.in, &ctx.compressed, ctx.maybe_mode.?, 0, false);
    ctx.end_time_compress = @floatFromInt(std.time.nanoTimestamp());

    // Decompress with Go flate implementation
    _ = libflate.Gunzip(
        try ctx.compressed_path_s(),
        try ctx.decompressed_path_s()
    );

    // Verify correct decompression
    try ctx.eql(ctx.in, ctx.decompressed);
}

/// Verify that the Golang implementation is ok for ffi
fn check_ref_ok(ctx: *TestContext) !void {
    const compressed_len = libflate.Gzip(
        try ctx.inputfile_s(),
        try ctx.compressed_path_s(),
        @intFromEnum(ctx.maybe_mode.?),
    );
    ctx.end_time_compress = @floatFromInt(std.time.nanoTimestamp());

    _ = libflate.Gunzip(
        try ctx.compressed_path_s(),
        try ctx.decompressed_path_s()
    );

    try ctx.log_result(@intCast(compressed_len));

    // Verify correct decompression
    try ctx.eql(ctx.in, ctx.decompressed);
}

////////////////////////////////////////////////////////////////////////////////

test "Gzip tmp" {
    // try run("tests/testdata/wallpaper.jpg", "gzip-z7", check_z7_ok, FlateCompressMode.NO_COMPRESSION);
    // try run("tests/testdata/wallpaper.jpg", "gzip-z7", check_z7_ok, FlateCompressMode.BEST_SIZE);


    // try run("tests/testdata/wallpaper.jpg", "gzip-go", check_ref_ok, FlateCompressMode.NO_COMPRESSION);
    // try run("tests/testdata/wallpaper.jpg", "gzip-go", check_ref_ok, FlateCompressMode.BEST_SIZE);

    //try run("/Users/jonas/Downloads/cemu-2.6-macos-12-x64.dmg", "gzip-z7", check_z7_ok, FlateCompressMode.BEST_SIZE);
    // try run("tests/testdata/over_9000_a.txt", "gzip-z7", check_z7_ok, FlateCompressMode.BEST_SPEED);
    // try run("tests/testdata/rfc1951.txt", "gzip-z7", check_z7_ok, FlateCompressMode.BEST_SPEED);
    // try run(TestContext.random_label, "gzip-z7", check_z7_ok, FlateCompressMode.BEST_SPEED);
    //try run("tests/testdata/image.jpg", "gzip-z7", check_z7_ok, FlateCompressMode.NO_COMPRESSION);
    //try run("tests/testdata/image.jpg", "gzip-z7", check_z7_ok, FlateCompressMode.BEST_SIZE);
    //try run("tests/testdata/image.jpg", "gzip-z7", check_z7_ok, FlateCompressMode.BEST_SPEED);
}

////////////////////////////////////////////////////////////////////////////////

fn run_all_types(inputfile: []const u8, mode: FlateCompressMode) !void {
    try run(inputfile, "gzip-z7", check_z7_ok, mode);
    try run(inputfile, "gzip-go", check_ref_ok, mode);
    try run(inputfile, "gzip-go-decompress-z7", check_go_decompress_z7, mode);
    try run(inputfile, "gzip-z7-decompress-go", check_z7_decompress_go, mode);
}

fn run_all_types_and_modes(inputfile: []const u8) !void {
    const modes = [_]FlateCompressMode{
        FlateCompressMode.NO_COMPRESSION,
        FlateCompressMode.BEST_SPEED,
        FlateCompressMode.BEST_SIZE,
    };
    for (modes) |mode| {
        try run_all_types(inputfile, mode);
    }
}

fn run_all_z7_modes(inputfile: []const u8) !void {
    const modes = [_]FlateCompressMode{
        FlateCompressMode.NO_COMPRESSION,
        FlateCompressMode.BEST_SPEED,
        FlateCompressMode.BEST_SIZE,
    };
    for (modes) |mode| {
        try run(inputfile, "gzip-z7", check_z7_ok, mode);
        try run(inputfile, "gzip-z7-decompress-go", check_z7_decompress_go, mode);
    }
}

fn run_dir(dirpath: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const filepaths = try TestContext.list_files(allocator, dirpath);

    for (filepaths.items) |filepath| {
        try run_all_z7_modes(filepath);
    }
}

////////////////////////////////////////////////////////////////////////////////

// test "Gzip on zig fuzz data" {
//     try run_dir("tests/testdata/zig/fuzz");
// }

// test "Gzip on zig block_writer data" {
//     try run_dir("tests/testdata/zig/block_writer");
// }

test "Gzip check empty" {
    try run_all_types_and_modes("tests/testdata/empty");
}

test "Gzip check simple text" {
    try run_all_types_and_modes("tests/testdata/helloworld.txt");
}

test "Gzip check short simple text" {
    try run_all_types_and_modes("tests/testdata/simple.txt");
}

test "Gzip check longer simple text" {
    try run_all_types_and_modes("tests/testdata/flate_test.txt");
}

test "Gzip check 9001 repeated characters" {
    try run_all_types_and_modes("tests/testdata/over_9000_a.txt");
}

test "Gzip check rfc1951.txt" {
    try run_all_types_and_modes("tests/testdata/rfc1951.txt");
}

test "Gzip on random data" {
    try run_all_types_and_modes(TestContext.random_label);
}

test "Gzip on small image" {
    try run_all_types_and_modes("tests/testdata/wallpaper_small.jpg");
}
