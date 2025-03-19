const std = @import("std");
const libflate = @cImport({
    @cInclude("libflate.h");
});

const log = @import("log.zig");
const util = @import("util_test.zig");
const Huffman = @import("huffman.zig").Huffman;

fn run(inputfile: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try run_alloc(allocator, inputfile);
}

fn run_alloc(allocator: std.mem.Allocator, inputfile: []const u8) !void {
    var compressed: std.fs.File = undefined;
    var decompressed: std.fs.File = undefined;
    var in: std.fs.File = undefined;
    var in_size: usize = undefined;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.setup(allocator, &tmp, inputfile, &in, &in_size, &compressed, &decompressed);
    defer in.close();
    defer compressed.close();
    defer decompressed.close();

    var freq = try Huffman.get_frequencies(allocator, in);
    defer freq.deinit();
    const huffman = try Huffman.init(allocator, &freq);

    // Reset input stream for second pass
    try in.seekTo(0);
    try huffman.compress(in, compressed);
    try util.log_result("huffman", inputfile, in_size, try compressed.getPos());

    try huffman.decompress(compressed, decompressed);

    // Verify correct decoding
    try util.eql(allocator, in, decompressed);
}

test "Reference implementation ok" {
    const input_data = [_]libflate.GoUint8{'A'} ** 256;

    var compressed_data = [_]libflate.GoUint8{0} ** 256;
    var compressed_len: libflate.GoInt = -1;

    var decompressed_data = [_]libflate.GoUint8{0} ** 256;
    var decompressed_len: libflate.GoInt = 256;

    // zig fmt: off
    const input = libflate.GoSlice{
        .data = @ptrCast(@constCast(&input_data)),
        .len = input_data.len,
        .cap = input_data.len
    };
    const compressed = libflate.GoSlice{
        .data = @ptrCast(@constCast(&compressed_data)),
        .len = compressed_data.len,
        .cap = compressed_data.len
    };
    const decompressed = libflate.GoSlice{
        .data = @ptrCast(@constCast(&decompressed_data)),
        .len = decompressed_data.len,
        .cap = decompressed_data.len
    };
    // zig fmt: on

    // Compress
    compressed_len = libflate.DeflateHuffmanOnly(input, compressed);
    // Sanity check
    try std.testing.expect(250 > compressed_len and compressed_len > 1);

    // Decompress
    decompressed_len = libflate.InflateHuffmanOnly(compressed, decompressed);
    // Verify that the decompressed output and original input are equal
    try std.testing.expectEqualSlices(u8, &input_data, &decompressed_data);
}

test "Huffman only deflate" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const inputfile = "tests/testdata/helloworld.txt";
    var compressed: std.fs.File = undefined;
    var in: std.fs.File = undefined;
    var in_size: usize = undefined;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    in = try std.fs.cwd().openFile(inputfile, .{ .mode = .read_only });
    in_size = (try in.stat()).size;
    compressed = try tmp.dir.createFile("compressed.bin", .{ .read = true });
    defer in.close();
    defer compressed.close();

    var freq = try Huffman.get_frequencies(allocator, in);
    defer freq.deinit();
    const huffman = try Huffman.init(allocator, &freq);

    // Reset input stream for second pass
    try in.seekTo(0);
    try huffman.compress(in, compressed);
    try util.log_result("huffman", inputfile, in_size, try compressed.getPos());


    // Reset input stream to read into array for reference implementation
    try in.seekTo(0);
    const bytes = try in.readToEndAlloc(allocator, 256);
    var input_data = [_]libflate.GoUint8{0} ** 256;
    for (0..bytes.len) |i| {
        input_data[i] = bytes[i];
    }

    var compressed_data = [_]libflate.GoUint8{0} ** 256;
    var compressed_len: libflate.GoInt = -1;

    // zig fmt: off
    const input = libflate.GoSlice{
        .data = @ptrCast(@constCast(&input_data)),
        .len = input_data.len,
        .cap = input_data.len
    };
    const compressed_ref = libflate.GoSlice{
        .data = @ptrCast(@constCast(&compressed_data)),
        .len = compressed_data.len,
        .cap = compressed_data.len
    };
    // zig fmt: on

    // Compress
    compressed_len = libflate.DeflateHuffmanOnly(input, compressed_ref);
    log.debug(@src(), "{any}", .{compressed_ref});
}

