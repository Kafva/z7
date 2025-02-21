const std = @import("std");
const Lz77 = @import("lz77.zig").Lz77;

const max_size = 50000;

fn run(inputfile: []const u8, lookahead_length: usize, window_length: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const in = try std.fs.cwd().openFile(inputfile, .{ .mode = .read_only });
    defer in.close();
    const in_size = (try in.stat()).size;
    const reader = in.reader();

    const in_data = try std.fs.cwd().readFileAlloc(allocator, inputfile, max_size);

    // Sanity check
    try std.testing.expect(in_size <= max_size);

    var compressed_array = [_]u8{0} ** max_size;
    var compressed = std.io.fixedBufferStream(&compressed_array);

    var decompressed_array = [_]u8{0} ** max_size;
    var decompressed = std.io.fixedBufferStream(&decompressed_array);

    // zig fmt: off
    const lz77 = Lz77(@TypeOf(compressed)) {
        .allocator = allocator,
        .lookahead_length = lookahead_length,
        .window_length = window_length,
    };

    try lz77.compress(reader, &compressed);

    std.debug.print("compressed: {any} ({d} -> {d})\n",
                    .{ compressed_array[0..compressed.pos], in_size,
                       compressed.pos });
    // zig fmt: on

    try lz77.decompress(&compressed, &decompressed);

    // Verify correct decompression
    try std.testing.expectEqualSlices(u8, in_data[0..in_size], decompressed_array[0..in_size]);
}

test "lz77 on simple text" {
    try run("tests/testdata/simple.txt", 4, 6);
}

// test "lz77 on rfc1951.txt" {
//     try run("tests/testdata/rfc1951.txt", 8, 64);
// }
