const std = @import("std");
const log = @import("log.zig");

pub const random_label = "RANDOM";

pub fn log_result(
    name: []const u8,
    inputfile: []const u8,
    in_size: usize,
    new_size: usize
) !void {
    const filename = std.fs.path.basename(inputfile);
    var k: f64 = undefined;
    var sign: []const u8 = undefined;

    if (new_size > in_size) {
        k = @floatFromInt(new_size - in_size);
        sign = "\x1b[91m+";
    } else {
        k = @floatFromInt(in_size - new_size);
        sign = "\x1b[92m-";
    }
    const m: f64 = @floatFromInt(in_size);
    const percent = if (m == 0) 0.0 else 100 * (k / m);
    std.debug.print("{d:8} -> {d:8} ({s}{d:4.1}\x1b[0m %) [{s}({s})]\n",
                    .{in_size, new_size, sign, percent, name, filename});
}

pub fn read_random(data: *const []u8, count: usize) !std.fs.File {
    var in: std.fs.File = undefined;

    var prng = std.rand.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const random = prng.random();

    std.Random.bytes(random, data.*[0..count]);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var infile = try tmp.dir.createFile("random.bin", .{});
    try infile.writeAll(data.*[0..count]);
    infile.close();

    in = try tmp.dir.openFile("random.bin", .{ .mode = .read_only });

    return in;
}

