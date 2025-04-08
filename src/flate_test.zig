const std = @import("std");

const log = @import("log.zig");
const TestContext = @import("context_test.zig").TestContext;

const decompress = @import("flate_decompress.zig").decompress;
const compress = @import("flate_compress.zig").compress;

const libflate = @cImport({
    @cInclude("libflate.h");
});

fn run(
    inputfile: []const u8,
    label: []const u8,
    runFn: fn (*TestContext) @typeInfo(@TypeOf(check_z7_ok)).@"fn".return_type.?,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try TestContext.init(allocator, inputfile, label);
    defer ctx.deinit();

    try runFn(&ctx);
}

/// Verify that z7 can decompress its own output
fn check_z7_ok(ctx: *TestContext) !void {
    var crc = std.hash.Crc32.init();
    try compress(ctx.allocator, &ctx.in, &ctx.compressed, &crc);

    try ctx.log_result(try ctx.compressed.getPos());

    var crcd = std.hash.Crc32.init();
    try decompress(ctx.allocator, &ctx.compressed, &ctx.decompressed, 0, &crcd);

    // Verify correct decompression
    try ctx.eql(ctx.in, ctx.decompressed);
}

/// Verify that the Golang flate implementation can decompress z7 output
fn check_z7_decompress_ref(ctx: *TestContext) !void {
    var crc = std.hash.Crc32.init();
    try compress(ctx.allocator, &ctx.in, &ctx.compressed, &crc);

    try ctx.log_result(try ctx.compressed.getPos());

    // Decompress with Go flate implementation
    const decompressed_len = libflate.FlateDecompress(
        try ctx.compressed_path_s(),
        try ctx.decompressed_path_s()
    );
    try std.testing.expect(decompressed_len > 0);

    // Verify correct decompression
    try ctx.eql(ctx.in, ctx.decompressed);
}

/// Verify that z7 can decompress output from the Golang flate implementation
fn check_z7_compress_ref(ctx: *TestContext) !void {
    const compressed_len = libflate.FlateCompress(ctx.inputfile_s(), try ctx.compressed_path_s());
    try std.testing.expect(compressed_len > 0);

    try ctx.log_result(@intCast(compressed_len));

    var crcd = std.hash.Crc32.init();
    try decompress(ctx.allocator, &ctx.compressed, &ctx.decompressed, 0, &crcd);

    // Verify correct decompression
    try ctx.eql(ctx.in, ctx.decompressed);
}

/// Verify that the Golang implementation is ok for ffi
fn check_ref_ok(ctx: *TestContext) !void {
    const compressed_len = libflate.FlateCompress(ctx.inputfile_s(), try ctx.compressed_path_s());
    try std.testing.expect(compressed_len > 0);

    try ctx.log_result(@intCast(compressed_len));

    const decompressed_len = libflate.FlateDecompress(
        try ctx.compressed_path_s(),
        try ctx.decompressed_path_s()
    );
    try std.testing.expect(decompressed_len > 0);

    // Verify correct decompression
    try ctx.eql(ctx.in, ctx.decompressed);
}

////////////////////////////////////////////////////////////////////////////////

fn runall(inputfile: []const u8) !void {
    try run(inputfile, "flate-z7-only", check_z7_ok);
    // try run(inputfile, "flate-go-only", check_ref_ok);
    // try run(inputfile, "flate-go-decompress-z7", check_z7_decompress_ref);
    // try run(inputfile, "flate-z7-decompress-go", check_z7_compress_ref);
}

test "[Flate] check empty file" {
    try run("tests/testdata/empty", "flate-z7-only", check_z7_ok);
}

test "[Flate] check random data" {
    try run(TestContext.random_label, "flate-z7-only", check_z7_ok);
}

test "[Flate] check simple text" {
    try runall("tests/testdata/helloworld.txt");
}

test "[Flate] check short simple text" {
    try runall("tests/testdata/simple.txt");
}

test "[Flate] check longer simple text" {
    try runall("tests/testdata/flate_test.txt");
}

test "[Flate] check 9001 repeated characters" {
    try runall("tests/testdata/over_9000_a.txt");
}

test "[Flate] check rfc1951.txt" {
    try runall("tests/testdata/rfc1951.txt");
}
