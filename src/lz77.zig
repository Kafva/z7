const std = @import("std");

const Lz77Item = struct {
    /// Matches are allowed to be 3..258, let
    /// 0 => 3, 1 => 4, ... 255 => 258
    length: u8,
    /// Maximum allowed distance is 16K
    distance: u16,
    next_char: u8,

    fn encode(self: @This()) []const u8 {
        _ = self;
    }
};

const lookahead_length = 3;
const buffer_length = 64;

/// The LZ77 algorithm is a dictionary-based compression algorithm that uses a
/// sliding window and a lookahead buffer to find and replace repeated patterns
/// in a data stream with pointers.
///
/// LZ77 is allowed to have back-references across block boundaries (32K or less
/// steps back is the limit for deflate)
///
/// About autocomplete for these parameters:
/// https://github.com/zigtools/zls/discussions/1506
pub fn compress(allocator: std.mem.Allocator, reader: anytype, writer: anytype) !void {
    var done = false;
    var lookahead = [_]u8{0} ** lookahead_length;

    var table = std.AutoHashMap([lookahead_length]u8, Lz77Item).init(allocator);
    defer table.deinit();

    while (true) {
        // Read the lookahead ammount of new bytes
        for (0..lookahead_length) |i| {
            lookahead[i] = reader.readByte() catch {
                done = true;
                break;
            };
        }

        if (done) {
            break;
        }

        // Check if the lookhead value already exists in the lookup table
        //
        // The lookup table maps a 1-3 byte sequence onto a Lz77Item
        // https://stackoverflow.com/a/6886259/9033629

        //table.put(lookahead, .{ .length = 3, .distance = 0, next_char =  })

        for (0..lookahead_length) |i| {
            try writer.writeByte(lookahead[i]);
        }
    }
}
