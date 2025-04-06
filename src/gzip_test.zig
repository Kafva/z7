const std = @import("std");

const log = @import("log.zig");
const util = @import("context_test.zig");

const TestContext = @import("context_test.zig").TestContext;
const Gzip = @import("gzip.zig").Gzip;

const libflate = @cImport({
    @cInclude("libflate.h");
});

fn run(
    inputfile: []const u8,
    label: []const u8,
    runFn: fn (*TestContext) @typeInfo(@TypeOf(check_z7_gzip_ok)).@"fn".return_type.?,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try TestContext.init(allocator, inputfile, label);
    defer ctx.deinit();

    try runFn(&ctx);
}


/// Verify that z7 can decompress its own output (gzip)
fn check_z7_gzip_ok(ctx: *TestContext) !void {
    try Gzip.compress(ctx.allocator, ctx.inputfile, ctx.compressed, 0);

    try ctx.log_result(try ctx.compressed.getPos());

    try Gzip.decompress(ctx.allocator, ctx.compressed, ctx.decompressed);

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

test "Gzip on simple text" {
    try run("tests/testdata/helloworld.txt", "z7-gzip", check_z7_gzip_ok);
    //try run("tests/testdata/helloworld.txt", "go-gzip", check_ref_ok);
}
