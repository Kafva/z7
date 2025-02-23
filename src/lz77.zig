const std = @import("std");
const log = @import("log.zig");

pub const Lz77Error = error{
    InvalidDistance,
    MalformedInput,
};

const Codeword = struct {
    /// XXX: Limit to u7 for now
    length: u8,
    /// XXX: Limit to u8 for now
    distance: u8,
    /// Raw character to write
    char: u8,
};

/// The LZ77 algorithm is a dictionary-based compression algorithm that uses a
/// sliding window and a lookahead buffer to find and replace repeated patterns
/// in a data stream with pointers.
///
/// LZ77 is allowed to have back-references across block boundaries (32K or less
/// steps back is the limit for deflate)
///
/// About autocomplete for 'anytype'
/// https://github.com/zigtools/zls/discussions/1506
pub const Lz77 = struct {
    window_length: usize,
    lookahead_length: usize,
    allocator: std.mem.Allocator,

    pub fn compress(self: @This(), reader: anytype, outstream: anytype) !void {
        var done = false;
        var writer = std.io.bitWriter(.little, outstream.writer());

        var sliding_window = try std.RingBuffer.init(self.allocator, self.window_length);
        defer sliding_window.deinit(self.allocator);

        var lookahead = try self.allocator.alloc(u8, self.lookahead_length);
        // Read in the first byte
        lookahead[0] = reader.readByte() catch {
            return;
        };

        while (!done) {
            // The current number of matches within the lookahead
            var match_cnt: u8 = 0;
            // Max number of matches in the lookahead this iteration
            // XXX: The byte at the `longest_match_cnt` index is not part
            // of the match!
            var longest_match_cnt: u8 = 0;
            var longest_match_distance: u8 = 0;

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
                const win_index: u8 = @truncate(i);
                longest_match_distance = (win_len - win_index) + (match_cnt - 1);

                if (longest_match_cnt == self.lookahead_length) {
                    // Lookahead is filled
                    break;
                }

                // When `match_cnt` exceeds `longest_match_cant` we
                // need to feed another byte into the lookahead.
                lookahead[longest_match_cnt] = reader.readByte() catch {
                    done = true;
                    break;
                };
            }

            // Update the sliding window
            const end = if (longest_match_cnt == 0) 1 else longest_match_cnt;
            for (0..end) |i| {
                try self.window_write(&sliding_window, lookahead[i]);
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

    pub fn decompress(self: @This(), instream: anytype, outstream: anytype) !void {
        // The input stream position should point to the last input element
        const end = instream.pos * 8;

        // Start from the first element in both streams
        try instream.seekTo(0);
        try outstream.seekTo(0);

        var reader = std.io.bitReader(.little, instream.reader());
        var writer = outstream.writer();

        var sliding_window = try std.RingBuffer.init(self.allocator, self.window_length);
        defer sliding_window.deinit(self.allocator);

        var pos: usize = 0;
        var type_bit: u1 = 0;

        while (pos < end) {
            type_bit = reader.readBitsNoEof(u1, 1) catch {
                return;
            };
            pos += 1;

            switch (type_bit) {
                0 => {
                    const c = reader.readBitsNoEof(u8, 8) catch {
                        return;
                    };
                    pos += 8;

                    // Update sliding window
                    try self.window_write(&sliding_window, c);
                    // Write raw byte to output stream
                    try writer.writeByte(c);
                    log.debug(@src(), "raw(.char = {})", .{c});
                },
                1 => {
                    const length = reader.readBitsNoEof(u7, 7) catch {
                        return;
                    };
                    pos += 7;

                    const distance = reader.readBitsNoEof(u8, 8) catch {
                        return Lz77Error.MalformedInput;
                    };
                    pos += 8;

                    // Write `length` bytes starting from the `distance`
                    // offset backwards from the `write_index`.
                    const write_index = sliding_window.write_index;
                    const start_index = try self.window_start_index(write_index, distance);

                    for (0..length) |i| {
                        const ring_index = (start_index + i) % self.window_length;
                        const c = sliding_window.data[ring_index];
                        // Update sliding window
                        try self.window_write(&sliding_window, c);
                        // Write to output stream
                        try writer.writeByte(c);
                        log.debug(@src(), "ref(.length = {}, .distance = {}, .char = {})", .{ length, distance, c });
                    }
                },
            }
        }
    }

    /// Get the starting index of a back reference at `distance` backwards
    /// into the sliding window.
    fn window_start_index(self: @This(), write_index: usize, distance: u8) !usize {
        if (distance > self.window_length) {
            log.err(@src(), "distance too large: {d} >= {d}", .{ distance, self.window_length });
            return Lz77Error.InvalidDistance;
        }

        const write_index_i: i32 = @intCast(write_index);
        const distance_i: i32 = @intCast(distance);
        const window_length_i: i32 = @intCast(self.window_length);

        const s: i32 = write_index_i - distance_i;

        const s_usize: usize = @intCast(s + window_length_i);

        return s_usize % self.window_length;
    }

    fn window_write(self: @This(), window: *std.RingBuffer, c: u8) !void {
        _ = self;
        if (window.isFull()) {
            _ = window.read();
        }
        try window.write(c);
    }

    /// Serialised format:
    ///
    /// Literal character: [ 0 bit | 8-bit character ]
    /// Pointer:           [ 1 bit | 7-bit length | 8-bit distance ]
    fn write_codeword(self: @This(), writer: anytype, codeword: Codeword) !void {
        _ = self;
        // Write references of length 1 as regular bytes instead, takes
        // up less space.
        if (codeword.length <= 1) {
            try writer.writeBits(@as(u1, 0), 1);
            try writer.writeBits(codeword.char, 8);
        } else {
            const len: u7 = @intCast(codeword.length);
            try writer.writeBits(@as(u1, 1), 1);
            try writer.writeBits(len, 7);
            try writer.writeBits(codeword.distance, 8);
        }
    }
};
