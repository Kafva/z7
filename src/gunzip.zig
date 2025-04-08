const std = @import("std");
const log = @import("log.zig");
const util = @import("util.zig");

const GzipFlag = @import("gzip.zig").GzipFlag;
const Decompress = @import("flate_decompress.zig").Decompress;

const GunzipError = error {
    InvalidHeader,
    TruncatedHeaderFname,
};

pub const Gunzip = struct {
    pub fn decompress(
        allocator: std.mem.Allocator,
        instream: std.fs.File,
        outstream: std.fs.File,
    ) !void {
        const fname_max = 1024;
        var handle_fname = false;
        var fname = [_]u8{0}**fname_max;
        var fname_length: usize = 0;
        const reader = instream.reader();

        // Always start from the beginning of the input stream
        try instream.seekTo(0);

        if (try reader.readByte() != 0x1f) {
            return GunzipError.InvalidHeader;
        }
        if (try reader.readByte() != 0x8b) {
            return GunzipError.InvalidHeader;
        }
        if (try reader.readByte() != 0x08) {
            return GunzipError.InvalidHeader;
        }

        const flg = try reader.readByte();
        if ((flg & @intFromEnum(GzipFlag.FTEXT)) == 1) {
            log.debug(@src(), "Ignoring FTEXT flag", .{});
        }
        if ((flg & @intFromEnum(GzipFlag.FHCRC)) == 1) {
            log.debug(@src(), "Ignoring FHCRC flag", .{});
        }
        if ((flg & @intFromEnum(GzipFlag.FEXTRA)) == 1) {
            log.debug(@src(), "Ignoring FEXTRA flag", .{});
        }
        if ((flg & @intFromEnum(GzipFlag.FNAME)) == 1) {
            handle_fname = true;
        }
        if ((flg & @intFromEnum(GzipFlag.FCOMMENT)) == 1) {
            log.debug(@src(), "Ignoring FCOMMENT flag", .{});
        }

        const mtime = try reader.readInt(u32, .little);
        log.debug(@src(), "Modification time: {s}", .{util.strtime(mtime)});

        const xfl = try reader.readByte();
        if (xfl != 0 and xfl != 2 and xfl != 4) {
            return GunzipError.InvalidHeader;
        }
        const os = try reader.readByte();
        if (os != 255) {
            log.debug(@src(), "Ignoring custom OS flag", .{});
        }

        if (handle_fname) {
            var b: u8 = 0;
            for (0..fname_max) |i| {
                b = try reader.readByte();
                fname[i] = b;
                fname_length += 1;
                if (b == 0) {
                    break;
                }
            }

            if (b != 0) {
                return GunzipError.TruncatedHeaderFname;
            }
            log.debug(@src(), "Original filename: '{s}'", .{fname});
        }

        const read_bytes = 10 + fname_length;
        try Decompress.decompress(allocator, instream, outstream, read_bytes);

        const crc = try reader.readInt(u32, .little);
        const size = try reader.readInt(u32, .little);
        log.debug(@src(), "Original data CRC32: 0x{x}", .{crc});
        log.debug(@src(), "Original size: {d} bytes", .{size});
    }
};

