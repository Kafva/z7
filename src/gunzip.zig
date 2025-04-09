const std = @import("std");
const log = @import("log.zig");
const util = @import("util.zig");

const inflate = @import("flate_decompress.zig").decompress;
const GzipFlag = @import("gzip.zig").GzipFlag;

const GunzipError = error {
    InvalidHeader,
    TruncatedHeaderFname,
    TruncatedHeaderComment,
    InvalidExtraField,
    InvalidStringCharacter,
    CrcMismatch,
};

const GunzipContext = struct {
    instream: *const std.fs.File,
    outstream: *const std.fs.File,
    reader: std.io.AnyReader,
    crc: std.hash.Crc32,
    crch: std.hash.Crc32,
    header_size: usize,
};

pub fn decompress(
    allocator: std.mem.Allocator,
    instream: *const std.fs.File,
    outstream: *const std.fs.File,
) !void {
    var ctx = GunzipContext {
        .instream = instream,
        .outstream = outstream,
        .reader = instream.reader().any(),
        .crc = std.hash.Crc32.init(),
        .crch = std.hash.Crc32.init(),
        .header_size = 0,
    };
    var handle_fname = false;
    var handle_fextra = false;
    var handle_comment = false;
    var handle_fhcrc = false;

    // Always start from the beginning of the input stream and output stream
    try instream.seekTo(0);
    try outstream.seekTo(0);

    if (try read_hdr_byte(&ctx) != 0x1f) {
        return GunzipError.InvalidHeader;
    }
    if (try read_hdr_byte(&ctx) != 0x8b) {
        return GunzipError.InvalidHeader;
    }
    if (try read_hdr_byte(&ctx) != 0x08) {
        return GunzipError.InvalidHeader;
    }

    const flags = try read_hdr_byte(&ctx);
    if ((flags & @intFromEnum(GzipFlag.FTEXT)) != 0) {
        log.debug(@src(), "Ignoring FTEXT flag", .{});
    }
    if ((flags & @intFromEnum(GzipFlag.FHCRC)) != 0) {
        log.debug(@src(), "Handling FHCRC flag", .{});
        handle_fhcrc = true;
    }
    if ((flags & @intFromEnum(GzipFlag.FEXTRA)) != 0) {
        log.debug(@src(), "Handling FEXTRA flag", .{});
        handle_fextra = true;
    }
    if ((flags & @intFromEnum(GzipFlag.FNAME)) != 0) {
        log.debug(@src(), "Handling FNAME flag", .{});
        handle_fname = true;
    }
    if ((flags & @intFromEnum(GzipFlag.FCOMMENT)) != 0) {
        log.debug(@src(), "Handling FCOMMENT flag", .{});
        handle_comment = true;
    }

    const mtime = try read_hdr_int(&ctx, u32);
    log.debug(@src(), "Modification time: {s}", .{util.strtime(mtime)});

    const xfl = try read_hdr_byte(&ctx);
    if (xfl != 0 and xfl != 2 and xfl != 4) {
        return GunzipError.InvalidHeader;
    }
    const os = try read_hdr_byte(&ctx);
    if (os != 255) {
        log.debug(@src(), "Ignoring custom OS flag", .{});
    }

    if (handle_fextra) {
        try parse_extra_field(&ctx);
    }
    if (handle_fname) {
        try parse_string(&ctx, "Original filename");
    }
    if (handle_comment) {
        try parse_string(&ctx, "Comment");
    }
    if (handle_fhcrc) {
        const fhcrc = try ctx.reader.readInt(u16, .little);
        ctx.header_size += 2;

        const crch_value: u16 = @truncate(ctx.crch.final());
        if (fhcrc == crch_value) {
            log.debug(@src(), "CRC16: 0x{x}", .{crch_value});
        }
        else {
            log.err(
                @src(),
                "Found CRC16: 0x{x}, expected CRC16: 0x{x}",
                .{fhcrc, crch_value}
            );
            return GunzipError.CrcMismatch;
        }
    }

    try inflate(
        allocator,
        ctx.instream,
        ctx.outstream,
        ctx.header_size,
        &ctx.crc
    );

    const crc_value = ctx.crc.final();
    const crc_trailer = try ctx.reader.readInt(u32, .little);

    if (crc_trailer == crc_value) {
        log.debug(@src(), "CRC32: 0x{x}", .{crc_value});
    }
    else {
        log.err(
            @src(),
            "Found CRC32: 0x{x}, expected CRC32: 0x{x}",
            .{crc_trailer, crc_value}
        );
        return GunzipError.CrcMismatch;
    }

    const size = try ctx.reader.readInt(u32, .little);
    log.debug(@src(), "Original size: {d} bytes", .{size});
}

/// The strings in the Gzip header are zero terminated ISO-8859 strings
fn parse_string(ctx: *GunzipContext, prefix: []const u8) !void {
    const str_max = 1024;
    var str = [_]u8{0}**str_max;
    var b: u8 = 0;
    var i: usize = 0;
    while (i < str_max) {
        b = try read_hdr_byte(ctx);
        if (b >= 0xa0) { // latin1 -> utf-8
            str[i] = 0xc3;
            i += 1;
            str[i] = b - 0x40;
            i += 1;
        }
        else if (b < 0x80) { // ascii
            str[i] = b;
            i += 1;
        }
        else {
            return GunzipError.InvalidStringCharacter;
        }

        if (b == 0) {
            break;
        }
    }

    if (b != 0) {
        return GunzipError.TruncatedHeaderFname;
    }
    log.debug(@src(), "{s}: '{s}'", .{prefix, str[0..i-1]});
}

/// +---+---+---+---+---+---+==================================+
/// | XLEN  |SI1|SI2|  LEN  |... LEN bytes of subfield data ...|
/// +---+---+---+---+---+---+==================================+
fn parse_extra_field(ctx: *GunzipContext) !void {
    const xlen = try read_hdr_int(ctx, u16);
    _ = try read_hdr_byte(ctx);
    _ = try read_hdr_byte(ctx);
    const len = try read_hdr_int(ctx, u16);

    if (xlen != 4 + len) {
        log.err(@src(), "Found {d} FEXTRA subfield length, expected {d}", .{len, xlen - 4});
        return GunzipError.InvalidExtraField;
    }

    log.debug(@src(), "Skipping {d} bytes of FEXTRA subfield data", .{len});
    for (0..len) |_| {
        _ = try read_hdr_byte(ctx);
    }
}

fn read_hdr_byte(ctx: *GunzipContext) !u8 {
    const b = try ctx.reader.readByte();
    ctx.header_size += 1;
    const bytearr = [1]u8{b};
    ctx.crch.update(&bytearr);
    return b;
}

fn read_hdr_int(ctx: *GunzipContext, comptime T: type) !T {
    const value = try ctx.reader.readInt(T, .little);

    const low = [_]u8{
        @truncate(value & 0x0000_00ff),
        @truncate((value & 0x0000_ff00) >> 8),
    };
    ctx.crch.update(&low);
    ctx.header_size += 2;

    if (T == u32) {
        const high = [_]u8{
            @truncate((value & 0x00ff_0000) >> 16),
            @truncate((value & 0xff00_0000) >> 24),
        };
        ctx.crch.update(&high);
        ctx.header_size += 2;
    }

    return value;
}
