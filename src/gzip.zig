const std = @import("std");
const log = @import("log.zig");
const util = @import("util.zig");

const deflate = @import("flate_compress.zig").compress;
const FlateCompressMode = @import("flate_compress.zig").FlateCompressMode;

const GzipError = error {
    InvalidStringCharacter,
};

pub const GzipFlag = enum(u8) {
    FTEXT = 0b1,
    FHCRC = 0b10,
    FEXTRA = 0b100,
    FNAME = 0b1000,
    FCOMMENT = 0b10000,
};

const GzipContext = struct {
    writer: std.io.AnyWriter,
    crch: std.hash.Crc32,
};

/// +---+---+---+---+---+---+---+---+---+---+
/// |ID1|ID2|CM |FLG|     MTIME     |XFL|OS |
/// +---+---+---+---+---+---+---+---+---+---+
pub fn compress(
    allocator: std.mem.Allocator,
    inputfile: []const u8,
    instream: *const std.fs.File,
    outstream: *const std.fs.File,
    mode: FlateCompressMode,
    flags: u8,
) !void {
    var ctx = GzipContext {
        .writer = outstream.writer().any(),
        .crch = std.hash.Crc32.init(),
    };
    var crc = std.hash.Crc32.init();
    var size: u32 = 0;

    try write_hdr_byte(&ctx, 0x1f); // ID1
    try write_hdr_byte(&ctx, 0x8b); // ID2
    try write_hdr_byte(&ctx, 0x08); // CM (deflate)
    try write_hdr_byte(&ctx, flags);
    // MTIME
    var mtime: u32 = 0;
    blk: {
        // Use zero size as mtime if stat() fails
        const st = instream.stat() catch break :blk;
        const mtime_sec = @divFloor(st.mtime, std.math.pow(i128, 10, 9));
        mtime = @intCast(mtime_sec);
        size = @truncate(st.size);
    }
    try write_hdr_int(&ctx, u32, mtime);
    if (mode == FlateCompressMode.BEST_SIZE) {
        // XFL = 2 - compressor used maximum compression, slowest algorithm
        try write_hdr_byte(&ctx, 2);
    }
    else {
        // XFL = 4 - compressor used fastest algorithm
        try write_hdr_byte(&ctx, 4);
    }
    try write_hdr_byte(&ctx, 255); // OS (unknown)
    // FLG
    if ((flags & @intFromEnum(GzipFlag.FEXTRA)) != 0) {
        log.debug(@src(), "Ignoring FEXTRA flag", .{});
    }
    if ((flags & @intFromEnum(GzipFlag.FNAME)) != 0) {
        log.debug(@src(), "Handling FNAME flag", .{});
        const filename = std.fs.path.basename(inputfile);
        try write_string(&ctx, filename);
    }
    if ((flags & @intFromEnum(GzipFlag.FTEXT)) != 0) {
        log.debug(@src(), "Ignoring FTEXT flag", .{});
    }
    if ((flags & @intFromEnum(GzipFlag.FCOMMENT)) != 0) {
        log.debug(@src(), "Ignoring FCOMMENT flag", .{});
    }
    if ((flags & @intFromEnum(GzipFlag.FHCRC)) != 0) {
        log.debug(@src(), "Handling FHCRC flag", .{});
        const crch_value: u16 = @truncate(ctx.crch.final());
        try write_hdr_int(&ctx, u16, crch_value);
    }

    // Compressed data block
    try deflate(allocator, instream, outstream, mode, &crc);

    // Trailer
    const crc_value = crc.final();
    log.debug(@src(), "Writing CRC32: 0x{x}", .{crc_value});
    try write_hdr_int(&ctx, u32, crc_value);

    log.debug(@src(), "Writing ISIZE: {d}", .{size});
    try write_hdr_int(&ctx, u32, size);
}

/// The strings in the Gzip header are zero terminated ISO-8859 strings
fn write_string(ctx: *GzipContext, str: []const u8) !void {
    var i: usize = 0;
    while (i < str.len) {
        if (str[i] < 0x80) { // ascii
            _ = try write_hdr_byte(ctx, str[i]);
            i += 1;
        }
        else if (str[i] == 0xc3) { // utf8 to latin1
            i += 1;
            if (str[i] < 0x80 or str[i] > 0xbf) {
                return GzipError.InvalidStringCharacter;
            }

            _ = try write_hdr_byte(ctx, str[i] - 0x40);
            i += 1;
        }
    }

    try write_hdr_byte(ctx, 0x0);
}

fn write_hdr_byte(ctx: *GzipContext, b: u8) !void {
    try ctx.writer.writeByte(b);
    const bytearr = [1]u8{b};
    ctx.crch.update(&bytearr);
}


fn write_hdr_int(ctx: *GzipContext, comptime T: type, value: T) !void {
    try ctx.writer.writeInt(T, value, .little);

    const low = [_]u8{
        @truncate(value & 0x0000_00ff),
        @truncate((value & 0x0000_ff00) >> 8),
    };
    ctx.crch.update(&low);

    if (T == u32) {
        const high = [_]u8{
            @truncate((value & 0x00ff_0000) >> 16),
            @truncate((value & 0xff00_0000) >> 24),
        };
        ctx.crch.update(&high);
    }
}

