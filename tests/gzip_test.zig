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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try TestContext.init(allocator, inputfile, label);
    defer ctx.deinit();

    ctx.mode = mode;
    try runFn(&ctx);
}

/// Verify that z7 can decompress its own output (gzip)
fn check_z7_ok(ctx: *TestContext) !void {
    try gzip(
        ctx.allocator,
        ctx.inputfile,
        &ctx.in,
        &ctx.compressed,
        ctx.mode.?,
        // XXX: gzstat.py does not handle gzip flags
        @intFromEnum(GzipFlag.FNAME) | @intFromEnum(GzipFlag.FHCRC),
    );

    try ctx.log_result(try ctx.compressed.getPos());

    try gunzip(ctx.allocator, &ctx.compressed, &ctx.decompressed);

    // Verify correct decompression
    try ctx.eql(ctx.in, ctx.decompressed);
}

/// Compress with Golang and decompress with z7
fn check_go_decompress_z7(ctx: *TestContext) !void {
    const compressed_len = libflate.Gzip(
        try ctx.inputfile_s(),
        try ctx.compressed_path_s(),
        @intFromEnum(ctx.mode.?),
    );
    try std.testing.expect(compressed_len > 0);

    // try ctx.log_result(@intCast(compressed_len));

    try gunzip(ctx.allocator, &ctx.compressed, &ctx.decompressed);

    // Verify correct decompression
    try ctx.eql(ctx.in, ctx.decompressed);
}

/// Compress with z7 and decompress with Golang
fn check_z7_decompress_go(ctx: *TestContext) !void {
    try gzip(ctx.allocator, ctx.inputfile, &ctx.in, &ctx.compressed, ctx.mode.?, 0);

    // try ctx.log_result(try ctx.compressed.getPos());

    // Decompress with Go flate implementation
    const decompressed_len = libflate.Gunzip(
        try ctx.compressed_path_s(),
        try ctx.decompressed_path_s()
    );
    try std.testing.expect(decompressed_len > 0);

    // Verify correct decompression
    try ctx.eql(ctx.in, ctx.decompressed);
}

/// Verify that the Golang implementation is ok for ffi
fn check_ref_ok(ctx: *TestContext) !void {
    const compressed_len = libflate.Gzip(
        try ctx.inputfile_s(),
        try ctx.compressed_path_s(),
        @intFromEnum(ctx.mode.?),
    );
    try std.testing.expect(compressed_len > 0);

    try ctx.log_result(@intCast(compressed_len));

    const decompressed_len = libflate.Gunzip(
        try ctx.compressed_path_s(),
        try ctx.decompressed_path_s()
    );
    try std.testing.expect(decompressed_len > 0);

    // Verify correct decompression
    try ctx.eql(ctx.in, ctx.decompressed);
}

////////////////////////////////////////////////////////////////////////////////

test "Gzip check longer simple text" {
    try run("tests/testdata/flate_test.txt", "gzip-z7-only", check_z7_ok, FlateCompressMode.BEST_SPEED);
}

////////////////////////////////////////////////////////////////////////////////

// fn runall(inputfile: []const u8, mode: FlateCompressMode) !void {
//     try run(inputfile, "gzip-z7-only", check_z7_ok, mode);
//     try run(inputfile, "gzip-go-only", check_ref_ok, mode);
//     try run(inputfile, "gzip-go-decompress-z7", check_go_decompress_z7, mode);
//     try run(inputfile, "gzip-z7-decompress-go", check_z7_decompress_go, mode);
// }

// test "Gzip check simple text" {
//     try runall("tests/testdata/helloworld.txt", FlateCompressMode.BEST_SPEED);
// }

// test "Gzip check short simple text" {
//     try runall("tests/testdata/simple.txt", FlateCompressMode.BEST_SPEED);
// }

// test "Gzip check longer simple text" {
//     try runall("tests/testdata/flate_test.txt", FlateCompressMode.BEST_SPEED);
// }

// test "Gzip check 9001 repeated characters" {
//     try runall("tests/testdata/over_9000_a.txt", FlateCompressMode.BEST_SPEED);
// }

// test "Gzip check rfc1951.txt" {
//     try runall("tests/testdata/rfc1951.txt", FlateCompressMode.BEST_SPEED);
// }

// test "Gzip on random data" {
//     try runall(TestContext.random_label, FlateCompressMode.BEST_SPEED);
// }

// // test "Gzip on small image" {
// //     try runall("tests/testdata/wallpaper_small.jpg", FlateCompressMode.BEST_SPEED);
// // }

// // test "Gzip on large image" {
// //     try runall("tests/testdata/wallpaper.jpg", FlateCompressMode.BEST_SPEED);
// // }

// ////////////////////////////////////////////////////////////////////////////////

// test "Gzip best size check simple text" {
//     try runall("tests/testdata/helloworld.txt", FlateCompressMode.BEST_SIZE);
// }

// test "Gzip best size check short simple text" {
//     try runall("tests/testdata/simple.txt", FlateCompressMode.BEST_SIZE);
// }

// test "Gzip best size check longer simple text" {
//     try runall("tests/testdata/flate_test.txt", FlateCompressMode.BEST_SIZE);
// }

// test "Gzip best size check 9001 repeated characters" {
//     try runall("tests/testdata/over_9000_a.txt", FlateCompressMode.BEST_SIZE);
// }

// test "Gzip best size check rfc1951.txt" {
//     try runall("tests/testdata/rfc1951.txt", FlateCompressMode.BEST_SIZE);
// }

// test "Gzip best size on random data" {
//     try runall(TestContext.random_label, FlateCompressMode.BEST_SIZE);
// }

// ////////////////////////////////////////////////////////////////////////////////

// test "Gzip no compression check simple text" {
//     try runall("tests/testdata/helloworld.txt", FlateCompressMode.NO_COMPRESSION);
// }

// test "Gzip no compression check short simple text" {
//     try runall("tests/testdata/simple.txt", FlateCompressMode.NO_COMPRESSION);
// }

// test "Gzip no compression check longer simple text" {
//     try runall("tests/testdata/flate_test.txt", FlateCompressMode.NO_COMPRESSION);
// }

// test "Gzip no compression check 9001 repeated characters" {
//     try runall("tests/testdata/over_9000_a.txt", FlateCompressMode.NO_COMPRESSION);
// }

// test "Gzip no compression check rfc1951.txt" {
//     try runall("tests/testdata/rfc1951.txt", FlateCompressMode.NO_COMPRESSION);
// }

// test "Gzip no compression on random data" {
//     try runall(TestContext.random_label, FlateCompressMode.NO_COMPRESSION);
// }
