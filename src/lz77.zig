const std = @import("std");
const log = @import("log.zig");

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

//const lookahead_length = 3;
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
    // Start simple, we do a brute force search in the sliding window from the
    // cursor position, we let the lookahead be equal to the size of the sliding
    // window (why would we stop eariler?).

    var sliding_window = try std.ArrayList(u8).initCapacity(allocator, buffer_length);
    defer sliding_window.deinit();
    log.debug(@src(), "xd: {any}", .{sliding_window.items.len});
    try sliding_window.append(18);
    log.debug(@src(), "xd: {any}", .{sliding_window.items.len});

    while (true) {
        const c = reader.readByte() catch {
            break;
        };

        // var longest_match_index = 0;
        // var longest_match_len = 0;

        for (0..sliding_window.items.len) |i| {
            _ = i;
        }

        try writer.writeByte(c);
    }
}
