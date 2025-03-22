const std = @import("std");
const log = @import("log.zig");
const build_options = @import("build_options");

const libflate = @cImport({
    @cInclude("libflate.h");
});

pub const random_label = "RANDOM";
const max_size = 512*1024; // 0.5 MB

pub fn setup(
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    inputfile: []const u8,
    in: *std.fs.File,
    in_size: *usize,
    compressed: *std.fs.File,
    decompressed: *std.fs.File,
) !void {
    compressed.* = try tmp.dir.createFile("compressed.bin", .{ .read = true });
    decompressed.* = try tmp.dir.createFile("decompressed.bin", .{ .read = true });

    in.* = blk: {
        if (std.mem.eql(u8, inputfile, random_label)) {
            break :blk try read_random(allocator, tmp, 128);
        } else {
            break :blk try std.fs.cwd().openFile(inputfile, .{ .mode = .read_only });
        }
    };
    in_size.* = (try in.stat()).size;
}

pub fn list_files(
    allocator: std.mem.Allocator,
    dirpath: []const u8,
) !std.ArrayList([]const u8) {
    var dir = try std.fs.cwd().openDir(dirpath, .{});
    defer dir.close();
    var iter = dir.iterate();

    var list = std.ArrayList([]const u8).init(allocator);

    while (try iter.next()) |entry| {
        if (entry.kind != .file) {
            continue;
        }
        const buf = try std.fmt.allocPrint(allocator, "{s}/{s}", .{dirpath, entry.name});
        try list.append(buf);
    }

    return list;
}

/// Create a GoString for `filename` under `tmp.dir`
pub fn go_str_tmp_filepath(
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    filename: []const u8,
) !libflate.GoString {
    const null_terminator = [_]u8 {0};
    const buf = try allocator.alloc(u8, 512);
    for (0..512) |i| {
        buf[i] = 0;
    }

    _ = try tmp.dir.realpath(filename, buf);

    // Make sure to exclude everything after the first \0 in the
    // byte array from the length.
    const len = std.mem.indexOf(u8, buf, &null_terminator).?;
    return libflate.GoString{
        .p = buf.ptr,
        .n = @intCast(len)
    };
}

pub fn log_result(
    name: []const u8,
    inputfile: []const u8,
    in_size: usize,
    new_size: usize
) !void {
    if (!build_options.verbose) {
        return;
    }

    const filename = std.fs.path.basename(inputfile);
    var k: f64 = undefined;
    var sign: []const u8 = undefined;

    if (new_size == in_size) {
        k = 0.0;
        sign = "";
    }
    else if (new_size > in_size) {
        k = @floatFromInt(new_size - in_size);
        sign = "\x1b[91m+";
    } else {
        k = @floatFromInt(in_size - new_size);
        sign = "\x1b[92m-";
    }
    const m: f64 = @floatFromInt(in_size);
    const percent = if (m == 0) 0.0 else 100 * (k / m);
    std.debug.print("{d:<7} -> {d:<7} ({s}{d:4.1}\x1b[0m %) [{s}({s})]\n",
                    .{in_size, new_size, sign, percent, name, filename});
}

pub fn eql(allocator: std.mem.Allocator, lhs: std.fs.File, rhs: std.fs.File) !void {
    const lhs_data = try lhs.readToEndAlloc(allocator, max_size);
    const rhs_data = try rhs.readToEndAlloc(allocator, max_size);
    try std.testing.expectEqualSlices(u8, lhs_data, rhs_data);
}

fn read_random(
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    count: usize
) !std.fs.File {
    var prng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const random = prng.random();

    const data = try allocator.alloc(u8, count);
    std.Random.bytes(random, data);

    var infile = try tmp.dir.createFile("random.bin", .{});
    try infile.writeAll(data);
    infile.close();

    return try tmp.dir.openFile("random.bin", .{ .mode = .read_only });
}
