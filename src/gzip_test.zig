const std = @import("std");

const log = @import("log.zig");
const util = @import("context_test.zig");

const TestContext = @import("context_test.zig").TestContext;
const GzipFlag = @import("gzip.zig").GzipFlag;
const gzip = @import("gzip.zig").compress;
const gunzip = @import("gunzip.zig").decompress;

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

/// Verify that z7 can decompress its own output (gzip)
fn check_z7_ok(ctx: *TestContext) !void {
    try gzip(
        ctx.allocator,
        ctx.inputfile,
        &ctx.in,
        &ctx.compressed,
        @intFromEnum(GzipFlag.FNAME) | @intFromEnum(GzipFlag.FHCRC),
    );

    try ctx.log_result(try ctx.compressed.getPos());

    try gunzip(ctx.allocator, &ctx.compressed, &ctx.decompressed);

    // Verify correct decompression
    try ctx.eql(ctx.in, ctx.decompressed);
}

/// Compress with Golang and decompress with z7
fn check_go_decompress_z7(ctx: *TestContext) !void {
    const compressed_len = libflate.Gzip(ctx.inputfile_s(), try ctx.compressed_path_s());
    try std.testing.expect(compressed_len > 0);

    try ctx.log_result(@intCast(compressed_len));

    try gunzip(ctx.allocator, &ctx.compressed, &ctx.decompressed);

    // Verify correct decompression
    try ctx.eql(ctx.in, ctx.decompressed);
}

/// Compress with z7 and decompress with Golang
fn check_z7_decompress_go(ctx: *TestContext) !void {
    try gzip(ctx.allocator, ctx.inputfile, &ctx.in, &ctx.compressed, 0);

    try ctx.log_result(try ctx.compressed.getPos());

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
    const compressed_len = libflate.Gzip(ctx.inputfile_s(), try ctx.compressed_path_s());
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

fn runall(inputfile: []const u8) !void {
    try run(inputfile, "gzip-z7-only", check_z7_ok);
    try run(inputfile, "gzip-go-only", check_ref_ok);
    // TODO: block type 2
    // try run(inputfile, "gzip-go-decompress-z7", check_go_decompress_z7);
    try run(inputfile, "gzip-z7-decompress-go", check_z7_decompress_go);
}

test "[Gzip] check simple text" {
    try runall("tests/testdata/helloworld.txt");
}

test "[Gzip] check short simple text" {
    try runall("tests/testdata/simple.txt");
}

test "[Gzip] check longer simple text" {
    try runall("tests/testdata/flate_test.txt");
}

test "[Gzip] check 9001 repeated characters" {
    try runall("tests/testdata/over_9000_a.txt");
}

test "[Gzip] check rfc1951.txt" {
    try runall("tests/testdata/rfc1951.txt");
}

