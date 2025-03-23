const std = @import("std");
const util = @import("util_test.zig");
const Lz77 = @import("lz77.zig").Lz77;

fn run(inputfile: []const u8, lookahead_length: usize, window_length: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try run_alloc(allocator, inputfile, lookahead_length, window_length);
}

fn run_alloc(
    allocator: std.mem.Allocator,
    inputfile: []const u8,
    lookahead_length: usize,
    window_length: usize
) !void {
    var compressed: std.fs.File = undefined;
    var decompressed: std.fs.File = undefined;
    var in: std.fs.File = undefined;
    var in_size: usize = undefined;
    const lz77 = Lz77 {
        .allocator = allocator,
        .lookahead_length = lookahead_length,
        .window_length = window_length,
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.setup(allocator, &tmp, inputfile, &in, &in_size, &compressed, &decompressed);
    defer in.close();
    defer compressed.close();
    defer decompressed.close();

    try lz77.compress(in, compressed);
    try util.log_result("lz77", inputfile, in_size, try compressed.getPos());

    try lz77.decompress(compressed, decompressed);

    // Verify correct decompression
    try util.eql(allocator, in, decompressed);
}

fn run_dir(
    dirpath: []const u8,
    lookahead_length: usize,
    window_length: usize
) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const filepaths = try util.list_files(allocator, dirpath);

    for (filepaths.items) |filepath| {
        try run_alloc(allocator, filepath, lookahead_length, window_length);
    }
}

test "lz77 on empty file" {
    try run("tests/testdata/empty", 4, 6);
}

test "lz77 on simple text" {
    try run("tests/testdata/simple.txt", 4, 6);
}

test "lz77 on 9001 repeated characters" {
    try run("tests/testdata/over_9000_a.txt", 32, 128);
}

test "lz77 on rfc1951.txt" {
    try run("tests/testdata/rfc1951.txt", 8, 64);
}

test "lz77 on random data" {
    try run(util.random_label, 4, 6);
}

// test "lz77 on fuzzing testdata from zig stdlib" {
//     try run_dir("tests/testdata/zig/fuzz", 8, 64);
// }

// test "lz77 on block writer testdata from zig stdlib" {
//     try run_dir("tests/testdata/zig/block_writer", 8, 64);
// }
