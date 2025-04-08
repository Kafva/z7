const std = @import("std");
const log = @import("log.zig");
const util = @import("util.zig");

const Decompress = @import("flate_decompress.zig").Decompress;
const GzipFlag = @import("gzip.zig").GzipFlag;

const GunzipError = error {
    InvalidHeader,
    TruncatedHeaderFname,
    TruncatedHeaderComment,
    InvalidExtraField,
    CrcMismatch,
};

pub const Gunzip = struct {
    allocator: std.mem.Allocator,
    instream: *const std.fs.File,
    outstream: *const std.fs.File,
    reader: std.io.AnyReader,
    crc: std.hash.Crc32,
    crch: std.hash.Crc32,
    header_size: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        instream: *const std.fs.File,
        outstream: *const std.fs.File,
    ) @This() {
        return @This() {
            .allocator = allocator,
            .instream = instream,
            .outstream = outstream,
            .reader = instream.reader().any(),
            .crc = std.hash.Crc32.init(),
            .crch = std.hash.Crc32.init(),
            .header_size = 0,
        };
    }

    pub fn decompress(self: *@This()) !void {
        var handle_fname = false;
        var handle_fextra = false;
        var handle_comment = false;
        var handle_fhcrc = false;

        // Always start from the beginning of the input stream and output stream
        try self.instream.seekTo(0);
        try self.outstream.seekTo(0);

        if (try self.read_hdr_byte() != 0x1f) {
            return GunzipError.InvalidHeader;
        }
        if (try self.read_hdr_byte() != 0x8b) {
            return GunzipError.InvalidHeader;
        }
        if (try self.read_hdr_byte() != 0x08) {
            return GunzipError.InvalidHeader;
        }

        const flg = try self.read_hdr_byte();
        if ((flg & @intFromEnum(GzipFlag.FTEXT)) != 0) {
            log.debug(@src(), "Ignoring FTEXT flag", .{});
        }
        if ((flg & @intFromEnum(GzipFlag.FHCRC)) != 0) {
            log.debug(@src(), "Handling FHCRC flag", .{});
            handle_fhcrc = true;
        }
        if ((flg & @intFromEnum(GzipFlag.FEXTRA)) != 0) {
            log.debug(@src(), "Handling FEXTRA flag", .{});
            handle_fextra = true;
        }
        if ((flg & @intFromEnum(GzipFlag.FNAME)) != 0) {
            log.debug(@src(), "Handling FNAME flag", .{});
            handle_fname = true;
        }
        if ((flg & @intFromEnum(GzipFlag.FCOMMENT)) != 0) {
            log.debug(@src(), "Handling FCOMMENT flag", .{});
            handle_comment = true;
        }

        const mtime = try self.read_hdr_u32();
        log.debug(@src(), "Modification time: {s}", .{util.strtime(mtime)});

        const xfl = try self.read_hdr_byte();
        if (xfl != 0 and xfl != 2 and xfl != 4) {
            return GunzipError.InvalidHeader;
        }
        const os = try self.read_hdr_byte();
        if (os != 255) {
            log.debug(@src(), "Ignoring custom OS flag", .{});
        }

        if (handle_fextra) {
            try self.parse_extra_field();
        }
        if (handle_fname) {
            try self.parse_string("Original filename");
        }
        if (handle_comment) {
            try self.parse_string("Comment");
        }
        if (handle_fhcrc) {
            const fhcrc = try self.reader.readInt(u16, .little);
            self.header_size += 2;

            const crch_value = self.crch.final();
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

        var inflate = try Decompress.init(
            self.allocator,
            self.instream,
            self.outstream,
            self.header_size,
            &self.crc
        );
        try inflate.decompress();

        const crc_value = self.crc.final();
        const crc_trailer = try self.reader.readInt(u32, .little);

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

        const size = try self.reader.readInt(u32, .little);
        log.debug(@src(), "Original size: {d} bytes", .{size});
    }

    fn parse_string(self: *@This(), prefix: []const u8) !void {
        const str_max = 1024;
        var str = [_]u8{0}**str_max;
        var b: u8 = 0;
        for (0..str_max) |i| {
            b = try self.read_hdr_byte();
            str[i] = b;
            if (b == 0) {
                break;
            }
        }

        if (b != 0) {
            return GunzipError.TruncatedHeaderFname;
        }
        log.debug(@src(), "{s}: '{s}'", .{prefix, str});
    }

    /// +---+---+---+---+---+---+==================================+
    /// | XLEN  |SI1|SI2|  LEN  |... LEN bytes of subfield data ...|
    /// +---+---+---+---+---+---+==================================+
    fn parse_extra_field(self: *@This()) !void {
        const xlen = try self.read_hdr_u16();
        _ = try self.read_hdr_byte();
        _ = try self.read_hdr_byte();
        const len = try self.read_hdr_u16();

        if (xlen != 4 + len) {
            log.err(@src(), "Found {d} FEXTRA subfield length, expected {d}", .{len, xlen - 4});
            return GunzipError.InvalidExtraField;
        }

        log.debug(@src(), "Skipping {d} bytes of FEXTRA subfield data", .{len});
        try self.instream.seekBy(len);
    }

    fn read_hdr_byte(self: *@This()) !u8 {
        const b = try self.reader.readByte();
        self.header_size += 1;
        const bytearr = [1]u8{b};
        self.crch.update(&bytearr);
        return b;
    }

    fn read_hdr_u16(self: *@This()) !u16 {
        const int = try self.reader.readInt(u16, .little);
        self.header_size += 2;
        const bytearr = [2]u8{
            @truncate(int & 0x0000_00ff),
            @truncate((int & 0x0000_ff00) >> 8),
        };
        self.crch.update(&bytearr);
        return int;
    }

    fn read_hdr_u32(self: *@This()) !u32 {
        const int = try self.reader.readInt(u32, .little);
        self.header_size += 4;
        const bytearr = [4]u8{
            @truncate(int & 0x0000_00ff),
            @truncate((int & 0x0000_ff00) >> 8),
            @truncate((int & 0x00ff_0000) >> 16),
            @truncate((int & 0xff00_0000) >> 24),
        };
        self.crch.update(&bytearr);
        return int;
    }
};

