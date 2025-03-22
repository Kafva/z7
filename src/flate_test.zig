const std = @import("std");
const libflate = @cImport({
    @cInclude("libflate.h");
});

const log = @import("log.zig");
const util = @import("util_test.zig");
const Huffman = @import("huffman.zig").Huffman;

const max_size = 40*1024;

/// Compress and decompress with z7 and reference implementation, compare 
/// compressed and decompressed output between them.
fn check_reference(inputfile: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var compressed: std.fs.File = undefined;
    var decompressed: std.fs.File = undefined;
    var compressed_ref: std.fs.File = undefined;
    var decompressed_ref: std.fs.File = undefined;

    try util.run_flate_alloc(allocator, inputfile, &compressed, &decompressed);
    defer compressed.close();
    defer decompressed.close();

    try run_ref_impl(allocator, inputfile, &compressed_ref, &decompressed_ref);
    defer compressed_ref.close();
    defer decompressed_ref.close();

    try util.eql(allocator, decompressed_ref, decompressed);

    // try compressed.seekTo(0);
    // try util.eql(allocator, compressed_ref, compressed);
}

fn check_deflate(inputfile: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var compressed: std.fs.File = undefined;
    var decompressed: std.fs.File = undefined;
    var decompressed_ref: std.fs.File = undefined;

    try util.run_flate_alloc(allocator, inputfile, &compressed, &decompressed);
    defer compressed.close();
    defer decompressed.close();

    // Try to decompress z7 compressed input with go implementation (hangs)
    try compressed.seekTo(0);
    try run_ref_deflate(allocator, inputfile, &compressed, &decompressed_ref);
    defer decompressed_ref.close();

    try util.eql(allocator, decompressed_ref, decompressed);
}

fn check_flate(inputfile: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var compressed: std.fs.File = undefined;
    var decompressed: std.fs.File = undefined;

    try util.run_flate_alloc(allocator, inputfile, &compressed, &decompressed);
    compressed.close();
    decompressed.close();
}

fn run_ref_deflate(
    allocator: std.mem.Allocator,
    inputfile: []const u8,
    compressed_input: *std.fs.File,
    decompressed: *std.fs.File,
) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const in = try std.fs.cwd().openFile(inputfile, .{ .mode = .read_only });
    const input_data = try in.readToEndAlloc(allocator, max_size);
    in.close();

    const compressed_name = "c.bin";
    const decompressed_name = "d.bin";

    // Copy compressed input into a known filepath
    const compressed = try tmp.dir.createFile(compressed_name, .{});
    const compressed_path_s = try util.go_str_tmp_filepath(allocator, &tmp, compressed_name);
    try compressed.writeFileAll(compressed_input.*, .{});

    // Decompress
    decompressed.* = try tmp.dir.createFile(decompressed_name, .{ .read = true });
    const decompressed_path_s = try util.go_str_tmp_filepath(allocator, &tmp, decompressed_name);

    const decompressed_len = libflate.InflateHuffmanOnly(compressed_path_s, decompressed_path_s);
    try std.testing.expect(decompressed_len > 0);

    try decompressed.seekTo(0);
    const decompressed_data = try decompressed.readToEndAlloc(allocator, max_size);

    // Verify that the decompressed output and original input are equal
    try std.testing.expectEqualSlices(
        u8,
        input_data,
        decompressed_data
    );
}

fn run_ref_impl(
    allocator: std.mem.Allocator,
    inputfile: []const u8,
    compressed: *std.fs.File,
    decompressed: *std.fs.File,
) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const compressed_name = "c.bin";
    const decompressed_name = "d.bin";
    const inputfile_s = libflate.GoString{
        .p = inputfile.ptr,
        .n = @intCast(inputfile.len)
    };

    const in = try std.fs.cwd().openFile(inputfile, .{ .mode = .read_only });
    const in_size = (try in.stat()).size;
    const input_data = try in.readToEndAlloc(allocator, max_size);
    in.close();

    // Compress
    compressed.* = try tmp.dir.createFile(compressed_name, .{ .read = true });
    const compressed_path_s = try util.go_str_tmp_filepath(allocator, &tmp, compressed_name);

    const compressed_len = libflate.DeflateHuffmanOnly(inputfile_s, compressed_path_s);
    try std.testing.expect(compressed_len > 0);

    try util.log_result("go/flate", inputfile, in_size, @intCast(compressed_len));

    // Decompress
    decompressed.* = try tmp.dir.createFile(decompressed_name, .{ .read = true });
    const decompressed_path_s = try util.go_str_tmp_filepath(allocator, &tmp, decompressed_name);

    const decompressed_len = libflate.InflateHuffmanOnly(compressed_path_s, decompressed_path_s);
    try std.testing.expect(decompressed_len > 0);

    try decompressed.seekTo(0);
    const decompressed_data = try decompressed.readToEndAlloc(allocator, max_size);

    // Verify that the decompressed output and original input are equal
    try std.testing.expectEqualSlices(
        u8,
        input_data,
        decompressed_data
    );
}

test "Flate reference implementation ok" {
    try check_reference("tests/testdata/helloworld.txt");
}

test "Flate reference implementation simple text" {
    try check_reference("tests/testdata/flate_test.txt");
}

test "Flate single block" {
    try check_flate("tests/testdata/helloworld.txt");
}

test "Flate simple text" {
    try check_flate("tests/testdata/flate_test.txt");
}
