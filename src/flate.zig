const std = @import("std");
const log = @import("log.zig");

/// Contains either a literal, a length encoding or a distance encoding.
pub const FlateSymbol = union(enum) {
    char: u8,
    length: RangeSymbol,
    distance: RangeSymbol,
};

pub const RangeSymbol = struct {
    /// The exact length or distance that this symbol represents
    value: ?u16,
    /// The symbol used to encode a length or distance (1..2**15)
    code: u16,
    /// The number of extra bits available for this code to represent more values
    bit_count: u8,
    /// The start of the length or distance range for this token, the range ends
    /// at `range_start + 2**bit_count`.
    range_start: u16,

    pub fn format(
        self: *const @This(),
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype
    ) !void {
        if (fmt.len != 0) {
            return std.fmt.invalidFmtError(fmt, self);
        }
        if (self.value) |v| {
            return writer.print(
                "{{ .value = {d}, .code = {d}, .bit_count = {d}, .range_start = {d} }}",
                .{v, self.code, self.bit_count, self.range_start}
            );
        }
        else {
            return writer.print(
                "{{ .code = {d}, .bit_count = {d}, .range_start = {d} }}",
                .{self.code, self.bit_count, self.range_start}
            );
        }
    }

    /// Map a length onto a `RangeSymbol`
    ///      Extra               Extra               Extra
    /// Code Bits Length(s) Code Bits Lengths   Code Bits Length(s)
    /// ---- ---- ------     ---- ---- -------   ---- ---- -------
    ///  257   0     3       267   1   15,16     277   4   67-82
    ///  258   0     4       268   1   17,18     278   4   83-98
    ///  259   0     5       269   2   19-22     279   4   99-114
    ///  260   0     6       270   2   23-26     280   4  115-130
    ///  261   0     7       271   2   27-30     281   5  131-162
    ///  262   0     8       272   2   31-34     282   5  163-194
    ///  263   0     9       273   3   35-42     283   5  195-226
    ///  264   0    10       274   3   43-50     284   5  227-257
    ///  265   1  11,12      275   3   51-58     285   0    258
    ///  266   1  13,14      276   3   59-66
    pub fn from_length(length: u16) RangeSymbol {
        const r: [3]u16 = switch (length) {
            3 => .{ 257, 0, 3 },
            4 => .{ 258, 0, 4 },
            5 => .{ 259, 0, 5 },
            6 => .{ 260, 0, 6 },
            7 => .{ 261, 0, 7 },
            8 => .{ 262, 0, 8 },
            9 => .{ 263, 0, 9 },
            10 => .{ 264, 0, 10 },
            11...12 => .{ 265, 1, 11 },
            13...14 => .{ 266, 1, 13 },
            15...16 => .{ 267, 1, 15 },
            17...18 => .{ 268, 1, 17 },
            19...22 => .{ 269, 2, 19 },
            23...26 => .{ 270, 2, 23 },
            27...30 => .{ 271, 2, 27 },
            31...34 => .{ 272, 2, 31 },
            35...42 => .{ 273, 3, 35 },
            43...50 => .{ 274, 3, 43 },
            51...58 => .{ 275, 3, 51 },
            59...66 => .{ 276, 3, 59 },
            67...82 => .{ 277, 4, 67 },
            83...98 => .{ 278, 4, 83 },
            99...114 => .{ 279, 4, 99 },
            115...130 => .{ 280, 4, 115 },
            131...162 => .{ 281, 5, 131 },
            163...194 => .{ 282, 5, 163 },
            195...226 => .{ 283, 5, 195 },
            227...257 => .{ 284, 5, 227 },
            258 => .{ 285, 0, 258 },
            else => unreachable,
        };
        return RangeSymbol {
            .value = length,
            .code = r[0],
            .bit_count = @truncate(r[1]),
            .range_start = r[2]
        };
    }

    /// Map a distance onto a `RangeSymbol`
    ///      Extra           Extra               Extra
    /// Code Bits Dist  Code Bits   Dist     Code Bits Distance
    /// ---- ---- ----  ---- ----  ------    ---- ---- --------
    ///   0   0    1     10   4     33-48    20    9   1025-1536
    ///   1   0    2     11   4     49-64    21    9   1537-2048
    ///   2   0    3     12   5     65-96    22   10   2049-3072
    ///   3   0    4     13   5     97-128   23   10   3073-4096
    ///   4   1   5,6    14   6    129-192   24   11   4097-6144
    ///   5   1   7,8    15   6    193-256   25   11   6145-8192
    ///   6   2   9-12   16   7    257-384   26   12  8193-12288
    ///   7   2  13-16   17   7    385-512   27   12 12289-16384
    ///   8   3  17-24   18   8    513-768   28   13 16385-24576
    ///   9   3  25-32   19   8   769-1024   29   13 24577-32768
    pub fn from_distance(distance: u16) RangeSymbol {
        const r: [3]u16 = switch (distance) {
            1 => .{0, 0, 1},
            2 => .{1, 0, 2},
            3 => .{2, 0, 3},
            4 => .{3, 0, 4},
            5...6 => .{4, 1, 5},
            7...8 => .{5, 1, 7},
            9...12 => .{6, 2, 9},
            13...16 => .{7, 2, 13},
            17...24 => .{8, 3, 17},
            25...32 => .{9, 3, 25},
            33...48 => .{10, 4, 33},
            49...64 => .{11, 4, 49},
            65...96 => .{12, 5, 65},
            97...128 => .{13, 5, 97},
            129...192 => .{14, 6, 129},
            193...256 => .{15, 6, 193},
            257...384 => .{16, 7, 257},
            385...512 => .{17, 7, 385},
            513...768 => .{18, 8, 513},
            769...1024 => .{19, 8, 769},
            1025...1536 => .{20, 9, 1025},
            1537...2048 => .{21, 9, 1537},
            2049...3072 => .{22, 10, 2049},
            3073...4096 => .{23, 10, 3073},
            4097...6144 => .{24, 11, 4097},
            6145...8192 => .{25, 11, 6145},
            8193...12288 => .{26, 12, 8193},
            12289...16384 => .{27, 12, 12289},
            16385...24576 => .{28, 13, 16385},
            24577...32768 => .{29, 13, 24577},
            else => unreachable,
        };
        return RangeSymbol {
            .value = distance,
            .code = r[0],
            .bit_count = @truncate(r[1]),
            .range_start = r[2]
        };
    }

    /// Fetch the `RangeSymbol` for a given length 'Code'.
    pub fn from_length_code(length_code: u16) RangeSymbol {
        const r: [2]u16 = switch (length_code) {
            257 => .{ 0, 3 },
            258 => .{ 0, 4 },
            259 => .{ 0, 5 },
            260 => .{ 0, 6 },
            261 => .{ 0, 7 },
            262 => .{ 0, 8 },
            263 => .{ 0, 9 },
            264 => .{ 0, 10 },
            265 => .{ 1, 11 },
            266 => .{ 1, 13 },
            267 => .{ 1, 15 },
            268 => .{ 1, 17 },
            269 => .{ 2, 19 },
            270 => .{ 2, 23 },
            271 => .{ 2, 27 },
            272 => .{ 2, 31 },
            273 => .{ 3, 35 },
            274 => .{ 3, 43 },
            275 => .{ 3, 51 },
            276 => .{ 3, 59 },
            277 => .{ 4, 67 },
            278 => .{ 4, 83 },
            279 => .{ 4, 99 },
            280 => .{ 4, 115 },
            281 => .{ 5, 131 },
            282 => .{ 5, 163 },
            283 => .{ 5, 195 },
            284 => .{ 5, 227 },
            285 => .{ 0, 258 },
            else => unreachable,
        };
        return RangeSymbol {
            .value = null,
            .code = length_code,
            .bit_count = @truncate(r[0]),
            .range_start = r[1]
        };
    }

    /// Fetch the `RangeSymbol` for a given distance 'Code'.
    pub fn from_distance_code(distance_code: u5) RangeSymbol {
        const r: [2]u16 = switch (distance_code) {
            0 => .{0, 1},
            1 => .{0, 2},
            2 => .{0, 3},
            3 => .{0, 4},
            4 => .{1, 5},
            5 => .{1, 7},
            6 => .{2, 9},
            7 => .{2, 13},
            8 => .{3, 17},
            9 => .{3, 25},
            10 => .{4, 33},
            11 => .{4, 49},
            12 => .{5, 65},
            13 => .{5, 97},
            14 => .{6, 129},
            15 => .{6, 193},
            16 => .{7, 257},
            17 => .{7, 385},
            18 => .{8, 513},
            19 => .{8, 769},
            20 => .{9, 1025},
            21 => .{9, 1537},
            22 => .{10, 2049},
            23 => .{10, 3073},
            24 => .{11, 4097},
            25 => .{11, 6145},
            26 => .{12, 8193},
            27 => .{12, 12289},
            28 => .{13, 16385},
            29 => .{13, 24577},
            else => unreachable,
        };
        return RangeSymbol {
            .value = null,
            .code = distance_code,
            .bit_count = @truncate(r[0]),
            .range_start = r[1]
        };
    }
};

pub const FlateError = error {
    NotImplemented,
    UnexpectedBlockType,
    UnexpectedEof,
    InvalidLiteralLength,
    InternalError,
    InvalidSymbol,
    InvalidDistance,
    InvalidLength,
    InvalidBlockLength,
    MissingTokenLiteral,
    OutOfQueueSpace,
};

pub const FlateBlockType = enum(u2) {
    NO_COMPRESSION = 0,
    FIXED_HUFFMAN = 1,
    DYNAMIC_HUFFMAN = 2,
    RESERVED = 3,
};

pub const Flate = struct {
    /// *Bit-numbering* endian mode for bit readers and writers.
    ///
    /// for ([1,1,1,1, 0,0,1,0]) |b|
    ///     writeBits(b)
    /// => 0b1111_0010 (.big)
    /// => 0b0100_1111 (.little)
    ///
    pub const writer_endian = std.builtin.Endian.little;
    /// The minimum length of a match required to use a back reference
    pub const min_length_match: usize = 3;
    /// Valid matches are between (3..258) characters long, i.e. we actually
    /// only need a u8 to represent this.
    pub const lookahead_length: usize = 258;
    /// Valid distances must be within the window length, i.e. (1..2**15)
    pub const window_length: usize = std.math.pow(usize, 2, 15);
    /// Maximum block size for type-0 blocks
    pub const block_length_max: usize = std.math.pow(usize, 2, 16);
    /// Maximum value for deflate symbols
    pub const symbol_max: usize = 286;

};
