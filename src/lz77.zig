const std = @import("std");
const log = @import("log.zig");

const Codeword = struct {
    /// Matches are allowed to be 3..258 long, let
    /// 0 => 3, 1 => 4, ... 255 => 258
    length: u8,
    /// Our window length is only 64 bytes so 1 byte is enough to represent the
    /// distance.
    distance: u16,
    /// Raw character to write.
    char: u8,
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
            var done = false;
            var writer = std.io.bitWriter(.little, self.compressed_stream.writer());

            var sliding_window = try std.RingBuffer.init(self.allocator, self.window_length);
            defer sliding_window.deinit(self.allocator);

            var lookahead = try self.allocator.alloc(u8, self.lookahead_length);
            // Read in the first byte
            lookahead[0] = try reader.readByte();

            while (!done) {
                // The current number of matches within the lookahead
                var match_cnt: u8 = 0;
                // Max number of matches in the lookahead this iteration
                // XXX: The byte at the `longest_match_cnt` index is not part
                // of the match!
                var longest_match_cnt: u8 = 0;
                var longest_match_distance: u16 = 0;

                // Look for matches in the sliding_window
                const win_len: u8 = @truncate(sliding_window.len());
                for (0..win_len) |i| {
                    const ring_index = (sliding_window.read_index + i) % self.window_length;
                    if (lookahead[match_cnt] != sliding_window.data[ring_index]) {
                        // Reset and start matching from the beginning of the
                        // lookahead again.
                        match_cnt = 0;
                        continue;
                    }

                    match_cnt += 1;

                    if (match_cnt <= longest_match_cnt) {
                        continue;
                    }

                    // Update the longest match
                    longest_match_cnt = match_cnt;
                    const win_index: u16 = @truncate(i);
                    longest_match_distance = (win_len - win_index) + (match_cnt - 1);

                    if (longest_match_cnt == self.lookahead_length) {
                        // Lookahead is filled
                        break;
                    }

                    // When `match_cnt` exceeds `longest_match_cnt` we
                    // need to feed another byte into the lookahead.
                    lookahead[longest_match_cnt] = reader.readByte() catch {
                        done = true;
                        break;
                    };
                }

                // Update the sliding window
                const end = if (longest_match_cnt == 0) 1 else longest_match_cnt;
                for (0..end) |i| {
                    if (sliding_window.isFull()) {
                        _ = sliding_window.read();
                    }
                    try sliding_window.write(lookahead[i]);
                }

                // The `char` is only used when length <= 1
                const char_index = if (longest_match_cnt <= 1) 0 else longest_match_cnt - 1;

                // Write codeword to output stream
                const codeword = Codeword{
                    .length = longest_match_cnt,
                    .distance = longest_match_distance,
                    .char = lookahead[char_index],
                };

                try self.write_codeword(&writer, codeword);
                log.debug(@src(), "code: {any}", .{codeword});

                // Set starting byte for next iteration
                if (longest_match_cnt == 0 or
                    longest_match_cnt == self.lookahead_length)
                {
                    // We need a new byte
                    lookahead[0] = reader.readByte() catch {
                        done = true;
                        break;
                    };
                } else {
                    // The `next_char` should be passed to the next iteration
                    lookahead[0] = lookahead[longest_match_cnt];
                }
            }

            // Incomplete bytes will be padded when flushing, wait until all
            // writes are done.
            try writer.flushBits();
        }

        pub fn decompress(reader: anytype, writer: anytype) !void {
            _ = reader;
            _ = writer;
        }

        /// Serialised format:
        ///
        /// Literal character: [ 0 bit | 8-bit character ]
        /// Pointer:           [ 1 bit | 7-bit length | 8-bit distance ]
        fn write_codeword(self: Self, writer: anytype, codeword: Codeword) !void {
            _ = self;
            // Write references of length 1 as regular bytes instead, takes
            // up less space.
            if (codeword.length <= 1) {
                try writer.writeBits(@as(u8, 0), 1);
                try writer.writeBits(codeword.char, 8);
            } else {
                try writer.writeBits(@as(u8, 1), 1);
                try writer.writeBits(codeword.length, 7);
                try writer.writeBits(codeword.distance, 8);
            }
        }

        // fn read_codeword(self: Self) !void {

        // }
    };
}
