const std = @import("std");
const util = @import("util_test.zig");
const Huffman = @import("huffman.zig").Huffman;

const max_size = 512*1024; // 0.5 MB

fn run(inputfile: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try run_alloc(allocator, inputfile);
}

fn run_alloc(allocator: std.mem.Allocator, inputfile: []const u8) !void {
    var in_size: usize = undefined;
    var in_data = [_]u8{0} ** max_size;
    var in: std.fs.File = undefined;

    if (std.mem.eql(u8, inputfile, util.random_label)) {
        in_size = 128;
        in = try util.read_random(&in_data[0..], in_size);
    } else {
        in = try std.fs.cwd().openFile(inputfile, .{ .mode = .read_only });
        in_size = (try in.stat()).size;
        _ = try std.fs.cwd().readFile(inputfile, &in_data);
    }

    defer in.close();

    // Sanity check
    try std.testing.expect(in_size <= max_size);

    var encoded_array = [_]u8{0} ** max_size;
    var encoded = std.io.fixedBufferStream(&encoded_array);

    var decoded_array = [_]u8{0} ** max_size;
    var decoded = std.io.fixedBufferStream(&decoded_array);

    const huffman = try Huffman.init(allocator, in);

    // Reset input stream for second pass
    try in.seekTo(0);
    try huffman.encode(allocator, in, &encoded);
    try util.log_result("huffman", inputfile, in_size, encoded.pos);

    try huffman.decode(&encoded, &decoded);

    // Verify correct decoding
    try std.testing.expectEqualSlices(u8, in_data[0..in_size], decoded_array[0..in_size]);
}

fn run_dir(dirpath: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const filepaths = try util.list_files(allocator, dirpath);

    for (filepaths.items) |filepath| {
        try run_alloc(allocator, filepath);
    }
}

test "Huffman on empty file" {
    try run("tests/testdata/empty");
}

test "Huffman on simple text" {
    try run("tests/testdata/helloworld.txt");
}

test "Huffman on rfc1951.txt" {
    try run("tests/testdata/rfc1951.txt");
}

// test "Huffman on 9001 repeated characters" {
//     try run("tests/testdata/over_9000_a.txt");
// }

// test "Huffman on random data" {
//     try run(util.random_label);
// }

// test "Huffman on fuzzing testdata from zig stdlib" {
//     try run_dir("tests/testdata/zig/fuzz");
// }

// test "Huffman on block writer testdata from zig stdlib" {
//     try run_dir("tests/testdata/zig/block_writer");
// }
