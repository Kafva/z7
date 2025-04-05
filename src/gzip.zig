const std = @import("std");
const log = @import("log.zig");
const util = @import("util.zig");

const Decompress = @import("flate_decompress.zig").Decompress;
const Compress = @import("flate_compress.zig").Compress;

/// +---+---+---+---+---+---+---+---+---+---+
/// |ID1|ID2|CM |FLG|     MTIME     |XFL|OS | (more-->)
/// +---+---+---+---+---+---+---+---+---+---+
pub const Gzip = struct {

    pub fn compress(
        allocator: std.mem.Allocator,
        inputfile: []const u8,
        outstream: std.fs.File,
    ) !void {
        const instream = try std.fs.cwd().openFile(inputfile, .{ .mode = .read_only });
        const filename = std.fs.path.basename(inputfile);
        defer instream.close();

        const st = try instream.stat();
        const mtime: u32 = @intCast(st.mtime & 0xffff_ffff);

        // TODO: calculate crc incrementally
        const uncompressed_data = try instream.readToEndAlloc(allocator, 40*1024);
        try instream.seekTo(0);
        const crc = std.hash.Crc32.hash(uncompressed_data);

        const writer = outstream.writer();
        try writer.writeByte(0x1f); // ID1
        try writer.writeByte(0x8b); // ID2
        try writer.writeByte(0x08); // CM (deflate)
        // FLG
        // bit 0   FTEXT
        // bit 1   FHCRC
        // bit 2   FEXTRA
        // bit 3   FNAME        [X]
        // bit 4   FCOMMENT
        // bit 5   reserved
        // bit 6   reserved
        // bit 7   reserved
        try writer.writeByte(0b0000_1000);
        // MTIME
        try writer.writeInt(u32, mtime, .little);
        // XFL = 2 - compressor used maximum compression, slowest algorithm
        try writer.writeByte(2);
        try writer.writeByte(255); // OS (unknown)

        _ = try writer.write(filename);
        try writer.writeByte(0x0);

        // Compressed data block
        try Compress.compress(allocator, instream, outstream);

        // Trailer
        try writer.writeInt(u32, crc, .little);
    }
};

