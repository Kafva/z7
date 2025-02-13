const std = @import("std");
const log = @import("log.zig");

const Codeword = struct {
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
    var done = false;
    // Start simple, we do a brute force search in the sliding window from the
    // cursor position. We allow matches up to the sliding_window length - 1
    var sliding_window = try std.RingBuffer.init(allocator, buffer_length);
    defer sliding_window.deinit(allocator);

    var lookahead = try std.RingBuffer.init(allocator, buffer_length - 1);
    defer lookahead.deinit(allocator);

    while (!done) {
        var longest_match_distance: ?u8 = null;
        var longest_match_len: u8 = 0;
        var match_len: u8 = 0;
        var next_index: u8 = 0;
        var lookahead_read: u8 = 0;

        const c = reader.readByte() catch {
            break;
        };
        try lookahead.write(c);

        // Look for matches in the sliding_window
        for (0.., sliding_window.data) |i, window_c| {
            if (TODO != window_c) {
                // The next character from the sliding window does not match the lookahead,
                // reset and start matching from the beginning of the lookahead again.
                next_index = 0;
                match_len = 0;
                continue;
            }

            // The next character in the sliding window matches
            // the character from the lookahead buffer.
            match_len += 1;

            if (match_len > longest_match_len) {
                longest_match_len = match_len;

                if (sliding_window.len() > 0xff or i > 0xff) {
                    unreachable;
                }
                const len: u8 = @truncate(sliding_window.len());
                const idx: u8 = @truncate(i);

                // The distance from the cursor position to the *start*
                // of the match in the sliding window.
                longest_match_distance = len - idx - match_len;
            }

            // Read one more byte into the lookahead and continue matching The
            // `lookahead_read` index in the lookahead should always be a byte
            // that is *not* part of the match.
            next_index += 1;
            if (next_index > lookahead_read) {
                lookahead[next_index] = reader.readByte() catch {
                    done = true;
                    break;
                };
                lookahead_read += 1;
            }

            if (longest_match_len == buffer_length - 1) {
                // Longest possible match found.
                break;
            }
        }

        // Update the sliding window
        for (lookahead) |c| {
            try sliding_window.write(c);
        }

        if (longest_match_distance) |distance| {
            // Write codeword
            const codeword = Codeword{
                .length = longest_match_len,
                .distance = distance,
                .next_char = lookahead[lookahead_read],
            };
            try writer.writeStruct(codeword);
        } else {
            // No match, write the byte as is to the output stream
            try writer.writeByte(lookahead[0]);
        }
    }
}
