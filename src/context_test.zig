const std = @import("std");
const log = @import("log.zig");
const build_options = @import("build_options");

const FlateCompressMode = @import("flate_compress.zig").FlateCompressMode;

const libflate = @cImport({
    @cInclude("libflate.h");
});

/// Manually disable to keep tmpdir output for debugging
const cleanup_tmpdir = false;

pub const TestContext = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    inputfile: []const u8,
    in: std.fs.File,
    in_size: usize,
    compressed: std.fs.File,
    decompressed: std.fs.File,
    label: []const u8,
    mode: ?FlateCompressMode,

    /// Maximum input/output file size to handle (0.5 MB)
    const max_size = 512*1024;
    pub const random_label = "RANDOM";

    pub fn init(
        allocator: std.mem.Allocator,
        inputfile: []const u8,
        label: []const u8,
    ) !@This() {
        const tmp = std.testing.tmpDir(.{});
        const flgs: std.fs.File.CreateFlags = .{ .read = true, .truncate = true, .mode = 0o644 };
        const compressed = try tmp.dir.createFile("compressed.bin", flgs);
        const decompressed = try tmp.dir.createFile("decompressed.bin", flgs);

        const in = blk: {
            if (std.mem.eql(u8, inputfile, random_label)) {
                break :blk try TestContext.read_random(allocator, &tmp, 128);
            } else {
                break :blk try std.fs.cwd().openFile(inputfile, .{ .mode = .read_only });
            }
        };
        const in_size = (try in.stat()).size;

        return @This() {
            .allocator = allocator,
            .tmp = tmp,
            .inputfile = inputfile,
            .in = in,
            .in_size = in_size,
            .compressed = compressed,
            .decompressed = decompressed,
            .label = label,
            .mode = null,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.in.close();
        self.compressed.close();
        self.decompressed.close();
        if (cleanup_tmpdir) {
            self.tmp.cleanup();
        }
    }

    pub fn log_result(self: *@This(), new_size: usize) !void {
        if (build_options.quiet) {
            return;
        }

        const istty = std.io.getStdErr().isTty();
        const filename = std.fs.path.basename(self.inputfile);
        var k: f64 = undefined;
        var sign: []const u8 = undefined;

        if (new_size == self.in_size) {
            k = 0.0;
            sign = " ";
        }
        else if (new_size > self.in_size) {
            k = @floatFromInt(new_size - self.in_size);
            sign = if (istty) "\x1b[91m+" else "+";
        } else {
            k = @floatFromInt(self.in_size - new_size);
            sign = if (istty) "\x1b[92m-" else "-";
        }
        const m: f64 = @floatFromInt(self.in_size);
        const percent = if (m == 0) 0 else 100 * (k / m);
        const ansi_post = if (istty) "\x1b[0m" else "";
        std.debug.print("{d:<7} -> {d:<7} ({s}{d:5.1}{s} %) [{s}({s})] {s}\n",
                        .{
                            self.in_size,
                            new_size,
                            sign,
                            percent,
                            ansi_post,
                            self.label,
                            filename,
                            if (self.mode) |mode| @tagName(mode) else "",
                        });
    }

    pub fn compressed_path_s(self: *@This()) !libflate.GoString {
        return self.go_str_tmp_filepath("compressed.bin");
    }

    pub fn decompressed_path_s(self: *@This()) !libflate.GoString {
        return self.go_str_tmp_filepath("decompressed.bin");
    }

    pub fn inputfile_s(self: @This()) libflate.GoString {
        return libflate.GoString{
            .p = self.inputfile.ptr,
            .n = @intCast(self.inputfile.len)
        };
    }

    pub fn eql(self: *@This(), lhs: std.fs.File, rhs: std.fs.File) !void {
        try lhs.seekTo(0);
        try rhs.seekTo(0);
        const lhs_data = try lhs.readToEndAlloc(self.allocator, TestContext.max_size);
        const rhs_data = try rhs.readToEndAlloc(self.allocator, TestContext.max_size);
        try std.testing.expectEqualSlices(u8, lhs_data, rhs_data);
    }

    fn read_random(
        allocator: std.mem.Allocator,
        tmp: *const std.testing.TmpDir,
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

    /// Create a GoString for `filename` under `tmp.dir`
    fn go_str_tmp_filepath(
        self: *@This(),
        filename: []const u8,
    ) !libflate.GoString {
        const null_terminator = [_]u8 {0};
        const buf = try self.allocator.alloc(u8, 512);
        for (0..512) |i| {
            buf[i] = 0;
        }

        _ = try self.tmp.dir.realpath(filename, buf);

        // Make sure to exclude everything after the first \0 in the
        // byte array from the length.
        const len = std.mem.indexOf(u8, buf, &null_terminator).?;
        return libflate.GoString{
            .p = buf.ptr,
            .n = @intCast(len)
        };
    }
};
