const std = @import("std");
const log = @import("log.zig");
const Huffman = @import("huffman.zig").Huffman;
const Heap = @import("huffman.zig").Heap;

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

    // const in_data = try std.fs.cwd().readFileAlloc(allocator, inputfile, max_size);
    // var compressed_array = [_]u8{0} ** max_size;
    // var compressed = std.io.fixedBufferStream(&compressed_array);

    // var decompressed_array = [_]u8{0} ** max_size;
    // var decompressed = std.io.fixedBufferStream(&decompressed_array);

    // zig fmt: off
    const huffman = try Huffman.init(allocator, reader);
    // zig fmt: on
    _ = huffman;
}

fn gt(lhs: u8, rhs: u8) bool {
    return lhs > rhs;
}

test "Heap insert" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const sorted_arr = [_]u8{ 11, 4, 7, 2, 2, 3, 4, 1, 1, 1, 1, 2, 2, 1, 1 };
    const arr = [_]u8{ 2, 11, 1, 2, 3, 1, 1, 2, 4, 1, 2, 1, 7, 4, 1 };
    const array = try allocator.alloc(u8, arr.len);
    const heap = try Heap(u8){ .array = array, .is_greater = gt };

    for (arr) |item| {
        try heap.insert(item);
    }

    // Verify correct decompression
    try std.testing.expectEqualSlices(u8, sorted_arr, arr);
}

test "Huffman encode simple text" {
    try run("tests/testdata/helloworld.txt");
}
