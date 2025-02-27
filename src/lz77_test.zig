const std = @import("std");
const util = @import("util_test.zig");
const Lz77 = @import("lz77.zig").Lz77;

const max_size = 50000;

fn run(inputfile: []const u8, lookahead_length: usize, window_length: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var in_size: usize = undefined;
    var in_data = [_]u8{0} ** max_size;
    var in: std.fs.File = undefined;

    if (std.mem.eql(u8, inputfile, util.random_label)) {
        // The "compressed" output from this is larger than the input!
        in_size = 128;
        in = try util.read_random(&in_data[0..], in_size);
    } else {
        in = try std.fs.cwd().openFile(inputfile, .{ .mode = .read_only });
        in_size = (try in.stat()).size;
        _ = try std.fs.cwd().readFile(inputfile, &in_data);
    }

    defer in.close();
    const reader = in.reader();

    // Sanity check
    try std.testing.expect(in_size <= max_size);

    var compressed_array = [_]u8{0} ** max_size;
    var compressed = std.io.fixedBufferStream(&compressed_array);

    var decompressed_array = [_]u8{0} ** max_size;
    var decompressed = std.io.fixedBufferStream(&decompressed_array);

    const lz77 = Lz77 {
        .allocator = allocator,
        .lookahead_length = lookahead_length,
        .window_length = window_length,
    };

    try lz77.compress(reader, &compressed);
    try util.log_result("lz77", inputfile, in_size, compressed.pos);

    try lz77.decompress(&compressed, &decompressed);

    // Verify correct decompression
    try std.testing.expectEqualSlices(u8, in_data[0..in_size], decompressed_array[0..in_size]);
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
