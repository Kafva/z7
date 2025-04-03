const std = @import("std");

const log = @import("log.zig");
const util = @import("util_test.zig");

const Decompress = @import("flate_decompress.zig").Decompress;
const Compress = @import("flate_compress.zig").Compress;

const libflate = @cImport({
    @cInclude("libflate.h");
});

const cleanup_tmpdir = false;
const max_size = 40*1024;
const ret_type = @typeInfo(@TypeOf(check_z7_flate)).@"fn".return_type.?;

fn run(
    inputfile: []const u8,
    runFn: fn (std.mem.Allocator, []const u8, *std.fs.File, *std.fs.File) ret_type,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var compressed: std.fs.File = undefined;
    var decompressed: std.fs.File = undefined;

    try runFn(allocator, inputfile, &compressed, &decompressed);
    compressed.close();
    decompressed.close();
}

/// Verify that z7 can decompress its own output
fn check_z7_flate(
    allocator: std.mem.Allocator,
    inputfile: []const u8,
    compressed: *std.fs.File,
    decompressed: *std.fs.File,
) !void {
    var in: std.fs.File = undefined;
    var in_size: usize = undefined;

    var tmp = std.testing.tmpDir(.{});
    if (cleanup_tmpdir) {
        defer tmp.cleanup();
    }

    try util.setup(
        allocator,
        &tmp,
        inputfile,
        &in,
        &in_size,
        compressed,
        decompressed
    );
    defer in.close();

    try Compress.compress(allocator, in, compressed.*);

    try util.log_result("z7", inputfile, in_size, try compressed.getPos());

    try Decompress.decompress(allocator, compressed.*, decompressed.*, 0);

    // Verify correct decompression
    try util.eql(allocator, in, decompressed.*);
}

/// Verify that the Golang flate implementation can decompress z7 output
fn check_flate_decompress_go(
    allocator: std.mem.Allocator,
    inputfile: []const u8,
    compressed: *std.fs.File,
    decompressed: *std.fs.File,
) !void {
    var in: std.fs.File = undefined;
    var in_size: usize = undefined;

    var tmp = std.testing.tmpDir(.{});
    if (cleanup_tmpdir) {
        defer tmp.cleanup();
    }

    try util.setup(
        allocator,
        &tmp,
        inputfile,
        &in,
        &in_size,
        compressed,
        decompressed
    );
    defer in.close();

    try Compress.compress(allocator, in, compressed.*);

    try util.log_result("z7", inputfile, in_size, try compressed.getPos());

    // Decompress with Go flate implementation
    const compressed_path_s = try util.go_str_tmp_filepath(allocator, &tmp, "compressed.bin");
    const decompressed_path_s = try util.go_str_tmp_filepath(allocator, &tmp, "decompressed.bin");

    const decompressed_len = libflate.FlateDecompress(compressed_path_s, decompressed_path_s);
    try std.testing.expect(decompressed_len > 0);

    // Verify correct decompression
    try util.eql(allocator, in, decompressed.*);
}

/// Verify that the Golang implementation is ok for ffi
fn check_flate_reference_ok(
    allocator: std.mem.Allocator,
    inputfile: []const u8,
    compressed: *std.fs.File,
    decompressed: *std.fs.File,
) !void {
    var in: std.fs.File = undefined;
    var in_size: usize = undefined;

    var tmp = std.testing.tmpDir(.{});
    if (cleanup_tmpdir) {
        defer tmp.cleanup();
    }

    try util.setup(
        allocator,
        &tmp,
        inputfile,
        &in,
        &in_size,
        compressed,
        decompressed
    );
    defer in.close();

    const inputfile_s = libflate.GoString{
        .p = inputfile.ptr,
        .n = @intCast(inputfile.len)
    };

    const compressed_path_s = try util.go_str_tmp_filepath(allocator, &tmp, "compressed.bin");
    const compressed_len = libflate.FlateCompress(inputfile_s, compressed_path_s);
    try std.testing.expect(compressed_len > 0);

    try util.log_result("go", inputfile, in_size, @intCast(compressed_len));

    const decompressed_path_s = try util.go_str_tmp_filepath(allocator, &tmp, "decompressed.bin");
    const decompressed_len = libflate.FlateDecompress(compressed_path_s, decompressed_path_s);
    try std.testing.expect(decompressed_len > 0);

    // Verify correct decompression
    try util.eql(allocator, in, decompressed.*);
}

test "Flate on empty file" {
    try run("tests/testdata/empty", check_z7_flate);
    // try run("tests/testdata/empty", check_flate_reference_ok);
}

test "Flate on simple text" {
    try run("tests/testdata/flate_test.txt", check_z7_flate);
    try run("tests/testdata/flate_test.txt", check_flate_reference_ok);
}

test "Flate on short simple text" {
    try run("tests/testdata/simple.txt", check_z7_flate);
    try run("tests/testdata/simple.txt", check_flate_reference_ok);
    //try run("tests/testdata/simple.txt", check_flate_decompress_go);
}

test "Flate on 9001 repeated characters" {
    try run("tests/testdata/over_9000_a.txt", check_z7_flate);
    try run("tests/testdata/over_9000_a.txt", check_flate_reference_ok);
}

test "Flate on rfc1951.txt" {
    try run("tests/testdata/rfc1951.txt", check_z7_flate);
    try run("tests/testdata/rfc1951.txt", check_flate_reference_ok);
}

test "Flate on random data" {
    try run(util.random_label, check_z7_flate);
}
