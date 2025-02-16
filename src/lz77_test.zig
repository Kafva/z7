const std = @import("std");
const lz77_compress = @import("lz77.zig").compress;
const lz77_decompress = @import("lz77.zig").decompress;

fn run(inputfile: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const in = try std.fs.cwd().openFile(inputfile, .{ .mode = .read_only });
    defer in.close();
    const in_size = (try in.stat()).size;
    const reader = in.reader();

    var compressed = std.ArrayList(u8).init(allocator);
    try lz77_compress(allocator, reader, compressed.writer());

    std.debug.print("compressed: {any} ({d} -> {d})\n", .{ compressed.items[0..10], in_size, compressed.items.len });

    var decompressed = std.ArrayList(u8).init(allocator);
    try lz77_decompress(allocator, std.io.fixedBufferStream(compressed.items), decompressed.writer());
}

test "lz77 on simple text" {
    try run("tests/testdata/simple.txt");
}

test "lz77 on rfc1951.txt" {
    try run("tests/testdata/rfc1951.txt");
}
