const std = @import("std");
const log = @import("log.zig");
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

    //const in_data = try std.fs.cwd().readFileAlloc(allocator, inputfile, max_size);
    var encoded_array = [_]u8{0} ** max_size;
    const encoded = std.io.fixedBufferStream(&encoded_array);

    // var decompressed_array = [_]u8{0} ** max_size;
    // var decompressed = std.io.fixedBufferStream(&decompressed_array);

    const huffman = try Huffman.init(allocator, reader);

    huffman.dump(0, huffman.root_index);

    try in.seekTo(0);
    try huffman.encode(reader, encoded);
}


test "Huffman encode simple text" {
    try run("tests/testdata/helloworld.txt");
}
