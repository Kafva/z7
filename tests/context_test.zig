const std = @import("std");
const z7 = @import("z7");
const build_options = z7.build_options;

const log = z7.log;
const FlateCompressMode = z7.flate_compress.FlateCompressMode;

const libflate = @cImport({
    @cInclude("libflate.h");
});

pub const TestContext = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    inputfile: []const u8,
    in: std.fs.File,
    in_size: usize,
    start_time_compress: f64,
    end_time_compress: f64,
    compressed: std.fs.File,
    decompressed: std.fs.File,
    label: []const u8,
    maybe_mode: ?FlateCompressMode,

    /// Maximum input/output file size to handle (7 MB)
    const max_size = 7*1024*1024;
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
                break :blk try TestContext.read_random(allocator, &tmp, 40*1024);
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
            .start_time_compress = @floatFromInt(std.time.nanoTimestamp()),
            .end_time_compress = 0,
            .compressed = compressed,
            .decompressed = decompressed,
            .label = label,
            .maybe_mode = null,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.in.close();
        self.compressed.close();
        self.decompressed.close();
        if (build_options.cleanup) {
            self.tmp.cleanup();
        }
    }

    pub fn log_result(self: *@This(), new_size: usize) !void {
        const time_taken_compress: f64 = (self.end_time_compress - self.start_time_compress) / 1_000_000_000;
        const end_time_decompress: f64 = @floatFromInt(std.time.nanoTimestamp());
        const time_taken_decompress: f64 = (end_time_decompress - self.end_time_compress) / 1_000_000_000;

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
        std.debug.print("{d:<7} -> {d:<7} ({s}{d:5.1}{s} %) ({d: >6.1} sec, {d: >6.1} sec) [{s}({s})] {s}\n",
                        .{
                            self.in_size,
                            new_size,
                            sign,
                            percent,
                            ansi_post,
                            time_taken_compress,
                            time_taken_decompress,
                            self.label,
                            filename,
                            if (self.maybe_mode) |mode| @tagName(mode) else "",
                        });
    }

    pub fn compressed_path_s(self: *@This()) !libflate.GoString {
        return self.go_str_tmp_filepath("compressed.bin");
    }

    pub fn decompressed_path_s(self: *@This()) !libflate.GoString {
        return self.go_str_tmp_filepath("decompressed.bin");
    }

    pub fn inputfile_s(self: *@This()) !libflate.GoString {
        if (std.mem.eql(u8, self.inputfile, random_label)) {
            return self.go_str_tmp_filepath("random.bin");
        }
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

    pub fn list_files(
        allocator: std.mem.Allocator,
        dirpath: []const u8,
    ) !std.ArrayList([]const u8) {
        var dir = try std.fs.cwd().openDir(dirpath, .{ .iterate = true });
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
