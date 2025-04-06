const std = @import("std");

const log = @import("log.zig");
const util = @import("util_test.zig");
const TestContext = @import("util_test.zig").TestContext;

const Decompress = @import("flate_decompress.zig").Decompress;
const Compress = @import("flate_compress.zig").Compress;
const Gzip = @import("gzip.zig").Gzip;

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
    try Compress.compress(ctx.allocator, ctx.in, ctx.compressed);

    try ctx.log_result(try ctx.compressed.getPos());

    try Decompress.decompress(ctx.allocator, ctx.compressed, ctx.decompressed, 0);

    // Verify correct decompression
    try ctx.eql(ctx.in, ctx.decompressed);
}

/// Verify that the Golang flate implementation can decompress z7 output
fn check_z7_decompress_ref(ctx: *TestContext) !void {
    try Compress.compress(ctx.allocator, ctx.in, ctx.compressed);

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

    try Decompress.decompress(ctx.allocator, ctx.compressed, ctx.decompressed, 0);

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

test "[Flate] check empty file" {
    try run("tests/testdata/empty", "z7-flate", check_z7_ok);
}

test "[Flate] check simple text" {
    try run("tests/testdata/flate_test.txt", "z7-flate", check_z7_ok);
    try run("tests/testdata/flate_test.txt", "go-flate", check_ref_ok);
}

test "[Flate] check short simple text" {
    try run("tests/testdata/simple.txt", "z7-flate", check_z7_ok);
    try run("tests/testdata/simple.txt", "go-flate", check_ref_ok);
}

test "[Flate] check 9001 repeated characters" {
    try run("tests/testdata/over_9000_a.txt", "z7-flate", check_z7_ok);
    try run("tests/testdata/over_9000_a.txt", "go-flate", check_ref_ok);
}

test "[Flate] check rfc1951.txt" {
    try run("tests/testdata/rfc1951.txt", "z7-flate", check_z7_ok);
    try run("tests/testdata/rfc1951.txt", "go-flate", check_ref_ok);
}

test "[Flate]: check random data" {
    try run(util.random_label, "z7-flate", check_z7_ok);
}

// test "[Flate]: Decompress z7 output with reference implementation" {
//     try run("tests/testdata/simple.txt", "z7-flate", check_z7_decompress_ref);
// }

// test "[Flate]: Decompress reference implementation output with z7" {
//     try run("tests/testdata/simple.txt", "go-flate", check_z7_decompress_ref);
// }
