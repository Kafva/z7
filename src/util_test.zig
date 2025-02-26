const std = @import("std");
const log = @import("log.zig");

pub const random_label = "RANDOM";

pub fn log_result(name: []const u8, inputfile: []const u8, new_size: usize) !void {
    var in_size: usize = 0;

    if (!std.mem.eql(u8, inputfile, random_label)) {
        const in = try std.fs.cwd().openFile(inputfile, .{ .mode = .read_only });
        defer in.close();
        const st = try in.stat();
        in_size = st.size;
    }

    // Sanity check
    try std.testing.expect(in_size >= new_size);

    const k: f64 = @floatFromInt(in_size - new_size);
    const m: f64 = @floatFromInt(in_size);
    const percent: f64 = if (m == 0) 0.0 else 100 * (k / m);
    const filename = std.fs.path.basename(inputfile);
    log.info(@src(), "{d:8} -> {d:8} ({d:4.1} %) [{s}({s})]",
                     .{in_size, new_size, percent, name, filename});
}

pub fn read_random(data: *const []u8, size: *usize) !std.fs.File {
    var in: std.fs.File = undefined;

    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    size.* = data.*.len;
    std.Random.bytes(random, data.*);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var infile = try tmp.dir.createFile("random.bin", .{});
    try infile.writeAll(data.*);
    infile.close();

    in = try tmp.dir.openFile("random.bin", .{ .mode = .read_only });

    return in;
}

