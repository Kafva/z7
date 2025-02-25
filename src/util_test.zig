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

/// Read the content and size of a file
pub fn read_input(inputfile: []const u8, in_data: *const []u8, in_size: *usize) !std.fs.File {
    var in: std.fs.File = undefined;

    if (std.mem.eql(u8, inputfile, random_label)) {
        var prng = std.Random.DefaultPrng.init(0);
        const random = prng.random();

        in_size.* = in_data.*.len;
        std.Random.bytes(random, in_data.*);

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        var infile = try tmp.dir.createFile("random.bin", .{});
        try infile.writeAll(in_data.*);
        infile.close();

        in = try tmp.dir.openFile("random.bin", .{ .mode = .read_only });

    } else {
        in = try std.fs.cwd().openFile(inputfile, .{ .mode = .read_only });

        const st = try in.stat();
        in_size.* = st.size;
        _ = try std.fs.cwd().readFile(inputfile, in_data.*);

    }

    return in;
}
