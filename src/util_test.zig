const std = @import("std");
const log = @import("log.zig");

pub fn log_result(name: []const u8, inputfile: []const u8, new_size: usize) !void {
    const in = try std.fs.cwd().openFile(inputfile, .{ .mode = .read_only });
    defer in.close();
    const in_size = (try in.stat()).size;

    // Sanity check
    try std.testing.expect(in_size >= new_size);

    const k: f64 = @floatFromInt(in_size - new_size);
    const m: f64 = @floatFromInt(in_size);
    const percent: f64 = if (m == 0) 0.0 else 100 * (k / m);
    const filename = std.fs.path.basename(inputfile);
    log.info(@src(), "{d:8} -> {d:8} ({d:4.1} %) [{s}({s})]",
                     .{in_size, new_size, percent, name, filename});
}

