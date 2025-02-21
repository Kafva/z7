const std = @import("std");
const log = @import("log.zig");
const Lz77 = @import("lz77.zig").Lz77;

const max_size = 50000;

fn log_result(in_size: usize, new_size: usize) void {
    const k: f64 = @floatFromInt(in_size - new_size);
    const m: f64 = @floatFromInt(in_size);
    const percent: f64 = 100*(k / m);
    log.info(@src(), "compressed: {d} -> {d} ({d:.1} %)", .{ in_size, new_size, percent });
}

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
    // zig fmt: on

    try lz77.compress(reader, &compressed);
    log_result(in_size, compressed.pos);

    try lz77.decompress(&compressed, &decompressed);

    // Verify correct decompression
    try std.testing.expectEqualSlices(u8, in_data[0..in_size], decompressed_array[0..in_size]);
}

test "lz77 on simple text" {
    try run("tests/testdata/simple.txt", 4, 6);
}

test "lz77 on rfc1951.txt" {
    try run("tests/testdata/rfc1951.txt", 8, 64);
}
