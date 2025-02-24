const std = @import("std");
const util = @import("util_test.zig");
const Huffman = @import("huffman.zig").Huffman;

const max_size = 50000;

fn run(inputfile: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const in = try std.fs.cwd().openFile(inputfile, .{ .mode = .read_only });
    defer in.close();
    const in_size = (try in.stat()).size;
    const reader = in.reader();

    // Sanity check
    try std.testing.expect(in_size <= max_size);

    const in_data = try std.fs.cwd().readFileAlloc(allocator, inputfile, max_size);
    var encoded_array = [_]u8{0} ** max_size;
    var encoded = std.io.fixedBufferStream(&encoded_array);

    var decoded_array = [_]u8{0} ** max_size;
    var decoded = std.io.fixedBufferStream(&decoded_array);

    const huffman = try Huffman.init(allocator, reader);

    // Reset input stream for second pass
    try in.seekTo(0);
    try huffman.encode(allocator, reader, &encoded);
    try util.log_result("huffman", inputfile, encoded.pos);

    try huffman.decode(&encoded, &decoded);

    // Verify correct decoding
    try std.testing.expectEqualSlices(u8, in_data[0..in_size], decoded_array[0..in_size]);
}

test "Huffman on empty file" {
    try run("tests/testdata/empty");
}

test "Huffman on simple text" {
    try run("tests/testdata/helloworld.txt");
}

test "Huffman on 9001 repeated characters" {
    try run("tests/testdata/over_9000_a.txt");
}

test "Huffman on rfc1951.txt" {
    try run("tests/testdata/rfc1951.txt");
}

