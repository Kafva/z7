const std = @import("std");
const Lz77 = @import("lz77.zig").Lz77;

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

    var decompressed_array = [_]u8{0} ** 8192;
    var decompressed = std.io.fixedBufferStream(&decompressed_array);

    const lz77 = try Lz77(@TypeOf(compressed)) {
        .allocator = allocator,
        .lookahead_length = 4,
        .window_length = 64,
        .compressed_stream = &compressed,
        .decompressed_stream = &decompressed
    };

    try lz77.compress(reader);

    // zig fmt: off
    std.debug.print("compressed: {any} ({d} -> {d})\n",
                    .{ compressed_array[0..10], in_size,
                       compressed.pos });
    // zig fmt: on

    // const decompressed_writer = std.io.bitWriter(.little, decompressed.writer());

    // try lz77_decompress(allocator, compressed_reader, decompressed_writer);
}

test "lz77 on simple text" {
    try run("tests/testdata/simple.txt");
}

// test "lz77 on rfc1951.txt" {
//     try run("tests/testdata/rfc1951.txt");
// }
