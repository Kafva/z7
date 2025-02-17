const std = @import("std");
const log = @import("log.zig");

const Codeword = struct {
    /// Matches are allowed to be 3..258 long, let
    /// 0 => 3, 1 => 4, ... 255 => 258
    length: u8,
    /// Our window length is only 64 bytes so 1 byte is enough to represent the
    /// distance.
    distance: u16,
    next_char: u8,
};

/// The LZ77 algorithm is a dictionary-based compression algorithm that uses a
/// sliding window and a lookahead buffer to find and replace repeated patterns
/// in a data stream with pointers.
///
/// LZ77 is allowed to have back-references across block boundaries (32K or less
/// steps back is the limit for deflate)
///
/// About autocomplete for these parameters:
/// https://github.com/zigtools/zls/discussions/1506
pub fn Lz77(comptime T: type) type {
    return struct {
        const Self = @This();

        window_length: usize,
        lookahead_length: usize,
        allocator: std.mem.Allocator,
        compressed_stream: *T,
        decompressed_stream: *T,

        pub fn compress(self: Self, reader: anytype) !void {
            var writer = std.io.bitWriter(.little, self.compressed_stream.writer());
            var done = false;
            // Start simple, we do a brute force search in the sliding window from the
            // cursor position. We allow matches up to the lookahead_length.
            var sliding_window = try std.RingBuffer.init(self.allocator, self.window_length);
            defer sliding_window.deinit(self.allocator);

            var lookahead = [_]u8{0} ** self.lookahead_length;

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
                    const ring_index = (sliding_window.read_index + i) % self.window_length;
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
                        if (tail_index == self.window_length - 1) {
                            // The lookahead cannot fit more bytes
                            done = true;
                            break;
                        }
                    }

                    if (match_cnt == self.window_length - 1) {
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

                const codeword = Codeword{
                    .length = longest_match_cnt,
                    .distance = longest_match_distance orelse 0,
                    .next_char = lookahead[longest_match_cnt],
                };

                try self.write_codeword(&writer, codeword);
                log.debug(@src(), "code: {any}", .{codeword});
            }
        }

        pub fn decompress(reader: anytype, writer: anytype) !void {
            _ = reader;
            _ = writer;
        }

        /// Serialised format:
        ///
        /// Literal character: [ 0 bit | 8-bit character ]
        /// Pointer:           [ 1 bit | 8-bit length | 8-bit distance ]
        fn write_codeword(self: Self, writer: anytype, codeword: Codeword) !void {
            _ = self;
            if (codeword.length == 0) {
                try writer.writeBits(@as(u8, 0), 1);
                try writer.writeBits(codeword.next_char, 8);
            } else {
                try writer.writeBits(@as(u8, 1), 1);
                try writer.writeBits(codeword.length, 8);
                try writer.writeBits(codeword.distance, 8);
            }
            try writer.flushBits();
        }

        // fn read_codeword(self: Self) !void {

        // }
    };
}
