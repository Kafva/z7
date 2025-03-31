const std = @import("std");

const log = @import("log.zig");
const util = @import("util_test.zig");

const FlateDecompress = @import("flate_decompress.zig").FlateDecompress;
const FlateCompress = @import("flate_compress.zig").FlateCompress;

const max_size = 40*1024;

fn check_flate(inputfile: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var compressed: std.fs.File = undefined;
    var decompressed: std.fs.File = undefined;

    try run_alloc(allocator, inputfile, &compressed, &decompressed);
    compressed.close();
    decompressed.close();
}

fn run_alloc(
    allocator: std.mem.Allocator,
    inputfile: []const u8,
    compressed: *std.fs.File,
    decompressed: *std.fs.File,
) !void {
    var in: std.fs.File = undefined;
    var in_size: usize = undefined;

    var tmp = std.testing.tmpDir(.{});
    //defer tmp.cleanup();

    try util.setup(
        allocator,
        &tmp,
        inputfile,
        &in,
        &in_size,
        compressed,
        decompressed
    );
    defer in.close();

    try FlateCompress.compress(allocator, in, compressed.*);

    try util.log_result("flate", inputfile, in_size, try compressed.getPos());

    try FlateDecompress.decompress(allocator, compressed.*, decompressed.*);

    // Verify correct decoding
    try util.eql(allocator, in, decompressed.*);
}

test "Flate simple text" {
    try check_flate("tests/testdata/flate_test.txt");
    //try check_flate("tests/testdata/helloworld.txt");
}

