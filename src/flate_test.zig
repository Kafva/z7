const std = @import("std");

const log = @import("log.zig");
const util = @import("util_test.zig");

const Decompress = @import("flate_decompress.zig").Decompress;
const Compress = @import("flate_compress.zig").Compress;

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

    try Compress.compress(allocator, in, compressed.*);

    try util.log_result("flate", inputfile, in_size, try compressed.getPos());

    try Decompress.decompress(allocator, compressed.*, decompressed.*);

    // Verify correct decoding
    try util.eql(allocator, in, decompressed.*);
}

// test "Flate on empty file" {
//     try check_flate("tests/testdata/empty");
// }

// test "Flate on simple text" {
//     try check_flate("tests/testdata/flate_test.txt");
// }

test "Flate on short simple text" {
    try check_flate("tests/testdata/simple.txt");
}

test "Flate on 9001 repeated characters" {
    try check_flate("tests/testdata/over_9000_a.txt");
}

// test "Flate on rfc1951.txt" {
//     try check_flate("tests/testdata/rfc1951.txt");
// }

// test "Flate on random data" {
//     try check_flate(util.random_label);
// }
