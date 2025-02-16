const std = @import("std");
const log = @import("log.zig");

const Codeword = struct {
    /// Matches are allowed to be 3..258, let
    /// 0 => 3, 1 => 4, ... 255 => 258
    length: u8,
    /// Maximum allowed distance is 16K
    distance: u16,
    next_char: u8,

    fn encode(self: @This()) [4]u8 {
        const d_high: u8 = @truncate(self.distance & 0xff00);
        const d_low: u8 = @truncate(self.distance);
        return [_]u8{ self.length, d_low, d_high, self.next_char };
    }
};

const window_length = 64;

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
    var sliding_window = try std.RingBuffer.init(allocator, window_length);
    defer sliding_window.deinit(allocator);

    var lookahead = [_]u8{0} ** window_length;

    while (!done) {
        var longest_match_distance: ?u8 = null;
        var longest_match_cnt: u8 = 0;
        // The index of the last byte in the lookahead buffer.
        var tail_index: u8 = 0;
        // The number of matches within the lookahead
        // match_cnt=0, tail_index=0: No Codeword
        // match_cnt=1, tail_index=1: Codeword(..., .next_char = lookahead[1])
        // match_cnt=2, tail_index=2: Codeword(..., .next_char = lookahead[2])
        // ...
        var match_cnt: u8 = 0;

        // Read the first byte into the lookahead
        lookahead[tail_index] = reader.readByte() catch {
            break;
        };

        // Look for matches in the sliding_window
        const win_len: u8 = @truncate(sliding_window.len());
        for (0..win_len) |i| {
            const ring_index = (sliding_window.read_index + i) % window_length;
            if (lookahead[match_cnt] != sliding_window.data[ring_index]) {
                // Reset and start matching from the beginning of the lookahead again.
                match_cnt = 0;
                continue;
            }

            match_cnt += 1;

            // Update the longest match
            if (match_cnt > longest_match_cnt) {
                longest_match_cnt = match_cnt;

                // The distance from the *start of the match* in the sliding_window
                // to the start of the lookahead.
                const win_index: u8 = @truncate(i);
                longest_match_distance = (win_len - win_index) + (match_cnt - 1);
            }

            // Matched up to the tail of the lookahead, read another byte
            if (match_cnt > tail_index) {
                tail_index += 1;
                lookahead[tail_index] = reader.readByte() catch {
                    tail_index -= 1; // TODO
                    done = true;
                    break;
                };
                if (tail_index == window_length - 1) {
                    // The lookahead cannot fit more bytes
                    done = true;
                    break;
                }
            }

            if (match_cnt == window_length - 1) {
                // Longest possible match found.
                break;
            }
        }

        // Update the sliding window
        for (0..tail_index + 1) |i| {
            if (sliding_window.isFull()) {
                _ = sliding_window.read();
            }
            try sliding_window.write(lookahead[i]);
        }

        if (longest_match_distance) |distance| {
            // Write codeword
            const codeword = Codeword{
                .length = longest_match_cnt,
                .distance = distance,
                .next_char = lookahead[longest_match_cnt],
            };

            try writer.writeAll(codeword.encode()[0..]);
            log.debug(@src(), "code: {any}", .{codeword});
        } else {
            // Write the byte as is to the output stream
            const codeword = Codeword{
                .length = 0,
                .distance = 0,
                .next_char = lookahead[0],
            };

            try writer.writeByte(lookahead[0]);
            log.debug(@src(), "code: {any}", .{codeword});
        }
    }
}

pub fn decompress(allocator: std.mem.Allocator, reader: anytype, writer: anytype) !void {
    _ = allocator;
    _ = reader;
    _ = writer;
}
