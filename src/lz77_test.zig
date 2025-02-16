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

    var compressed_array = [_]u8{0} ** 8192;
    var compressed = std.io.fixedBufferStream(&compressed_array);
    const compressed_writer = std.io.bitWriter(.little, compressed.writer());
    // const compressed_reader = std.io.bitReader(.little, compressed.reader());

    // const xd: u8 = 111;
    // try @constCast(&compressed_writer).*.writeBits(xd, 8);

    try lz77_compress(allocator, reader, compressed_writer);

    std.debug.print("compressed: {any} ({d} -> {d})\n", .{ compressed_array[0..10], in_size, compressed.pos });

    // var decompressed_array = [_]u8{0} ** 8192;
    // var decompressed = std.io.fixedBufferStream(&decompressed_array);
    // const decompressed_writer = std.io.bitWriter(.little, decompressed.writer());

    // try lz77_decompress(allocator, compressed_reader, decompressed_writer);
}

test "lz77 on simple text" {
    try run("tests/testdata/simple.txt");
}

// test "lz77 on rfc1951.txt" {
//     try run("tests/testdata/rfc1951.txt");
// }
