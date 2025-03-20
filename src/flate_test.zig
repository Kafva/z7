const std = @import("std");
const libflate = @cImport({
    @cInclude("libflate.h");
});

const log = @import("log.zig");
const util = @import("util_test.zig");
const Huffman = @import("huffman.zig").Huffman;

const max_size = 40*1024;

test "Reference implementation ok" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const inputfile = "tests/testdata/rfc1951.txt";
    const inputfile_s = libflate.GoString{
        .p = inputfile,
        .n = @intCast(inputfile.len)
    };

    const in = try std.fs.cwd().openFile(inputfile, .{ .mode = .read_only });
    const in_size = (try in.stat()).size;

    const decompressed = try tmp.dir.createFile("decompressed.bin", .{ .read = true });
    decompressed.close();
    const decompressed_names = [_][]u8 {try tmp.parent_dir.realpath(), @constCast("decompressed.bin")};
    const decompressed_path = try std.fs.path.join(allocator, &decompressed_names);
    std.debug.print("x: {s}\n", .{decompressed_path});
    const decompressed_path_s = libflate.GoString{
        .p = @ptrCast(decompressed_path),
        .n = @intCast(decompressed_path.len)
    };

    const compressed = try tmp.dir.createFile("compressed.bin", .{ .read = true });
    compressed.close();
    const compressed_names = [_][]u8 {try tmp.parent_dir.realpath(), @constCast("compressed.bin")};
    const compressed_path = try std.fs.path.join(allocator, &compressed_names);
    std.debug.print("y: {s}\n", .{compressed_path});
    const compressed_path_s = libflate.GoString{
        .p = @ptrCast(compressed_path),
        .n = @intCast(compressed_path.len)
    };

    // Compress
    const compressed_len = libflate.DeflateHuffmanOnly(inputfile_s, compressed_path_s);
    try std.testing.expect(compressed_len > 0);

    try util.log_result("go/flate", inputfile, in_size, @intCast(compressed_len));

    // Decompress
    const decompressed_len = libflate.InflateHuffmanOnly(compressed_path_s, decompressed_path_s);
    try std.testing.expect(decompressed_len > 0);
    log.warn(@src(), "l: {d}", .{decompressed_len});


    try in.seekTo(0);
    const input_data = try in.readToEndAlloc(allocator, max_size);
    try decompressed.seekTo(0);
    const decompressed_data = try decompressed.readToEndAlloc(allocator, max_size);

    // Verify that the decompressed output and original input are equal
    try std.testing.expectEqualSlices(
        u8,
        input_data,
        decompressed_data
    );
}

// test "Huffman only deflate" {
//     var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
//     defer arena.deinit();
//     const allocator = arena.allocator();

//     // py -c 'for i in list("Hello World"): print(f"{ord(i)} ", end="")'; echo
//     const inputfile = "tests/testdata/rfc1951.txt";
//     var compressed: std.fs.File = undefined;
//     var in: std.fs.File = undefined;
//     var in_size: usize = undefined;

//     var tmp = std.testing.tmpDir(.{});
//     defer tmp.cleanup();

//     in = try std.fs.cwd().openFile(inputfile, .{ .mode = .read_only });
//     in_size = (try in.stat()).size;
//     compressed = try tmp.dir.createFile("compressed.bin", .{ .read = true });
//     defer in.close();
//     defer compressed.close();

//     var freq = try Huffman.get_frequencies(allocator, in);
//     defer freq.deinit();
//     const huffman = try Huffman.init(allocator, &freq);

//     // Reset input stream for second pass
//     try in.seekTo(0);
//     try huffman.compress(in, compressed);
//     try util.log_result("huffman", inputfile, in_size, try compressed.getPos());

//     try compressed.seekTo(0);
//     const z7_bytes = try compressed.readToEndAlloc(allocator, max_size);
//     log.debug(@src(), "z7: {any}", .{z7_bytes[0..64]});


//     // Reset input stream to read into array for reference implementation
//     try in.seekTo(0);
//     const bytes = try in.readToEndAlloc(allocator, max_size);
//     var input_data = [_]libflate.GoUint8{0} ** max_size;
//     for (0..bytes.len) |i| {
//         input_data[i] = bytes[i];
//     }

//     var compressed_data = [_]libflate.GoUint8{0} ** max_size;
//     var compressed_len: libflate.GoInt = -1;
//     const inputsize: libflate.GoInt = @intCast(bytes.len);

//     // zig fmt: off
//     const input = libflate.GoSlice{
//         .data = @ptrCast(@constCast(&input_data)),
//         .len = input_data.len,
//         .cap = input_data.len
//     };
//     const compressed_ref = libflate.GoSlice{
//         .data = @ptrCast(@constCast(&compressed_data)),
//         .len = compressed_data.len,
//         .cap = compressed_data.len
//     };
//     // zig fmt: on

//     // Compress
//     compressed_len = libflate.DeflateHuffmanOnly(input, inputsize,  compressed_ref);
//     log.debug(@src(), "go: {any}", .{compressed_data[0..64]});
// }

