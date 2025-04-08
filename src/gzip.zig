const std = @import("std");
const log = @import("log.zig");
const util = @import("util.zig");

const Compress = @import("flate_compress.zig").Compress;

pub const GzipFlag = enum(u8) {
    FTEXT = 0b1,
    FHCRC = 0b10,
    FEXTRA = 0b100,
    FNAME = 0b1000,
    FCOMMENT = 0b10000,
};

/// +---+---+---+---+---+---+---+---+---+---+
/// |ID1|ID2|CM |FLG|     MTIME     |XFL|OS | (more-->)
/// +---+---+---+---+---+---+---+---+---+---+
pub const Gzip = struct {
    pub fn compress(
        allocator: std.mem.Allocator,
        inputfile: []const u8,
        instream: *const std.fs.File,
        outstream: *const std.fs.File,
        flags: u8,
    ) !void {
        var crc = std.hash.Crc32.init();
        const writer = outstream.writer();
        var mtime: u32 = 0;
        var size: u32 = 0;
        blk: {
            // Use zero size and mtime if stat() fails
            const st = instream.stat() catch break :blk;
            const mtime_sec = @divFloor(st.mtime, std.math.pow(i128, 10, 9));
            mtime = @intCast(mtime_sec & 0xffff_ffff);
            size = @truncate(st.size);
        }

        try writer.writeByte(0x1f); // ID1
        try writer.writeByte(0x8b); // ID2
        try writer.writeByte(0x08); // CM (deflate)
        try writer.writeByte(flags);
        // MTIME
        try writer.writeInt(u32, mtime, .little);
        // XFL = 2 - compressor used maximum compression, slowest algorithm
        try writer.writeByte(2);
        try writer.writeByte(255); // OS (unknown)

        if ((flags & @intFromEnum(GzipFlag.FNAME)) == 1) {
            log.debug(@src(), "Handling FNAME flag", .{});
            const filename = std.fs.path.basename(inputfile);
            // TODO: Filename should be encoded as latin1
            _ = try writer.write(filename);
            try writer.writeByte(0x0);
        }

        // Compressed data block
        try Compress.compress(allocator, instream, outstream, &crc);

        // Trailer
        const crc_value = crc.final();
        log.debug(@src(), "Writing CRC: 0x{x}", .{crc_value});
        try writer.writeInt(u32, crc_value, .little);

        log.debug(@src(), "Writing ISIZE: {d}", .{size});
        try writer.writeInt(u32, size, .little);
    }
};

