/// gzip is just a file format.
/// gzip: https://www.ietf.org/rfc/rfc1952.txt
///
/// The actual compression is done with the DEFLATE algorithm.
/// deflate: https://www.ietf.org/rfc/rfc1951.txt
///
/// The deflate algorithm uses a variant of Huffman encoding and LZ77.
/// The exact implentation for LZ77 (Lempel-Ziv) is not part of the RFC.
///
/// Deflate performs compression on a per-block basis, the block sizes are
/// *arbitrary* but an uncompressed block can not be larger than 2**16 (2 byte
/// integer max value)
///
///
/// DEFLATE
/// =======
/// Each block is compressed individually.
/// Each block contains two Huffman trees and compressed data.
///
/// The compressed data has two types:
///     * Literal byte (0..255) sequences (that do not appear in the prior 32K)
///     * (length, backward distance) pointers to previous sequences
///
/// Deflate limits:
///     literal = (0..255)
///     length = (3..258)
///     backward distance = (1..32K)
///
/// The literal and length alphabehts are merged into one: (0..285)
///     0..255:   literal bytes
///     256:      end-of-block
///     257..285: length codes, these can include 0-5 extra bits
///               which is neccessary to express all lengths 3-258.
///
///
/// --------------------------
/// first bit       BFINAL
/// next 2 bits     BTYPE
/// ...
/// --------------------------
///
/// BFINAL: set on the final block
/// BTYPE:
///     00 - no compression
///     01 - compressed with fixed Huffman codes
///     10 - compressed with dynamic Huffman codes
///     11 - reserved (error)
///
/// BTYPE=00:
///  0   1   2   3   4...
///  +---+---+---+---+================================+
///  |  LEN  | NLEN  |... LEN bytes of literal data...|
///  +---+---+---+---+================================+
///
///  All remaining bits up until the next byte boundary from the header are
///  skipped.
///  NLEN is one's complement of LEN.
///
/// BTYPE=01:
///     Hardcoded huffman encoding, see RFC
///
/// BTYPE=10
///     5 Bits: HLIT, # of Literal/Length codes - 257 (257 - 286)
///     5 Bits: HDIST, # of Distance codes - 1        (1 - 32)
///     4 Bits: HCLEN, # of Code Length codes - 4     (4 - 19)
///             (HCLEN + 4) x 3 bits: code lengths for the code length
///                alphabet given just above, in the order: 16, 17, 18,
///                0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15
///
///                These code lengths are interpreted as 3-bit integers
///                (0-7); as above, a code length of 0 means the
///                corresponding symbol (literal/length or distance code
///                length) is not used.
///
///             HLIT + 257 code lengths for the literal/length alphabet,
///                encoded using the code length Huffman code
///
///             HDIST + 1 code lengths for the distance alphabet,
///                encoded using the code length Huffman code
///
///             The actual compressed data of the block,
///                encoded using the literal/length and distance Huffman
///                codes
///
///             The literal/length symbol 256 (end of data),
///                  encoded using the literal/length Huffman code
///
///
const std = @import("std");
const log = @import("log.zig");
const Huffman = @import("huffman.zig").Huffman;

const FlateCodeword = struct {
    length: u8,
    distance: u16,
    char: u8,
};

const FlateError = error {
    UnexpectedBlockType,
};

const FlateBlockType = enum(u2) {
    NO_COMPRESSION = 0b00,
    FIXED_HUFFMAN = 0b01,
    DYNAMIC_HUFFMAN = 0b10,
    RESERVED = 0b11,
};

const FlateContext = struct {
    sliding_window: std.RingBuffer,
    lookahead: []u8
};

pub const Flate = struct {
    allocator: std.mem.Allocator,
    block_size: usize,
    window_length: usize,
    lookahead_length: usize,


    fn compress_block_no_compression(
        self: @This(),
        reader: anytype,
        bit_writer: anytype,

    ) !void {
        // Write length of bytes
        const len: usize = if (last_block) (total_bits - done_bits)/8 else self.block_size;

        if (len > self.block_size) unreachable;
        const blen: u16 = @truncate(len);

        try writer.writeBits(blen, 16);
        try writer.writeBits(~blen, 16);

        // Write bytes unmodified to output stream for this block
        for (0..self.block_size) |_| {
            const b = reader.readByte() catch {
                break;
            };
            try bit_writer.writeBits(b, 8);
        }
    }
    pub fn compress(
        self: @This(),
        instream: std.fs.File,
        outstream: std.fs.File,
    ) !void {
        var ctx = FlateContext {
            // Initialize sliding window for backreferences
            .sliding_window = try std.RingBuffer.init(self.allocator, self.window_length),
            .lookahead = try self.allocator.alloc(u8, self.lookahead_length),
        };
        defer ctx.sliding_window.deinit(self.allocator);

        while (try self.compress_block(ctx, instream, outstream)) {}
    }

    /// Super basic block type decision, if there is at least one character
    /// with more than 3 occurences, use dynamic huffman.
    fn compress_block_type_decision(
        self: @This(),
        freqs: std.AutoHashMap(u8, usize),
    ) !FlateBlockType {
        _ = self;
        var keys = freqs.keyIterator();
        while (keys.next()) |key| {
            const freq = freqs.get(key.*).?;
            if (freq > 3) {
                return FlateBlockType.DYNAMIC_HUFFMAN;
            }
        }
        return FlateBlockType.NO_COMPRESSION;
    }

    /// 1. Calculate the frequencies for the next X bytes in the inpustream
    /// 2. Decide which block type compression to use
    /// 3. Write BFINAL + BTYPE
    /// 4. Write the data:
    /// 4a. No compression
    ///     Save the next X bytes into the sliding window and dump them as-is
    ///     to the output stream
    /// 4b. Fixed huffman encoding
    ///     Read the next `lookahead_length` bytes and create a `FlateCodeword`.
    ///     Write the huffman encoded version of the `FlateCodeword` to the output stream
    ///     Continue doing this until we have read X bytes from the input.
    ///     Write the end-of-block marker.
    /// 4c. Dynamic huffman encoding
    ///     Write the serialised version of the huffman tree for this block to the output stream.
    ///     < Same as 3b. >
    /// 5. Continue to next block.
    fn compress_block(
        self: @This(),
        ctx: FlateContext,
        instream: std.fs.File,
        outstream: std.fs.File,
    ) !bool {
        // Pass over input stream to calculate frequencies (WRONG)
        // We should calculate the frequency upon the lz77 codewords for this block instead!
        var block_read_bytes = 0;
        var freqs = try Huffman.get_frequencies(
            self.allocator,
            instream,
            self.block_size,
            &block_read_bytes
        );
        defer freqs.deinit();
        // Reset input stream to the start of the block
        try instream.seekBy(-1 * block_read_bytes);

        const block_type = try self.compress_block_type_decision(freqs);

        var bit_writer = std.io.bitWriter(.little, outstream.writer());
        const reader = instream.reader();

        // Number of bits from the input stream that have been procssed
        var done_bits: usize = 0;
        // Number of bits written to the output stream so far
        var written_bits: usize = 0;

        while (done_bits < (block_read_bytes / 8)) {
            // Write BFINAL (TODO always set to 0 for now)
            try bit_writer.writeBits(@as(u1, 0), 0);
            written_bits += 1;

            // Write BTYPE
            try bit_writer.writeBits(@intFromEnum(block_type), 2);
            written_bits += 2;

            // Fill up to next byte boundary
            const left_to_boundary: u3 = (written_bits) % 8;
            if (left_to_boundary != 0) {
                try bit_writer.writeBits(@as(u3, 0), left_to_boundary);
            }

            // Read `win_len` bytes

            // Read in the first byte
            lookahead[0] = reader.readByte() catch {
                return;
            };

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
                    done_bits = total_bits;
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
            const codeword = FlateCodeword {
                .length = longest_match_cnt,
                .distance = longest_match_distance,
                .char = lookahead[char_index],
            };

            log.debug(@src(), "code: {any}", .{codeword});

            // Set starting byte for next iteration
            if (longest_match_cnt == 0 or
                longest_match_cnt == self.lookahead_length)
            {
                // We need a new byte
                lookahead[0] = reader.readByte() catch {
                    done_bits = total_bits;
                    break;
                };
            } else {
                // The `next_char` should be passed to the next iteration
                lookahead[0] = lookahead[longest_match_cnt];
            }


            switch (block_type) {
                FlateBlockType.NO_COMPRESSION => {
                    try self.compress_block_no_compression(reader, bit_writer);
                },
                FlateBlockType.DYNAMIC_HUFFMAN => {
                    // Write compressed block
                    const huffman = try Huffman.init(self.allocator, &freq);
                    try huffman.compress(instream, outstream, self.block_size);
                },
                FlateBlockType.FIXED_HUFFMAN => {

                },
                else => {
                    log.err(@src(), "Invalid deflate block type {b}", .{block_type});
                    return FlateError.UnexpectedBlockType;
                }
            }

            done_bits += self.block_size;
        }
    }

    fn window_write(self: @This(), window: *std.RingBuffer, c: u8) !void {
        _ = self;
        if (window.isFull()) {
            _ = window.read();
        }
        try window.write(c);
    }

    pub fn decompress(
        instream: std.fs.File,
        outstream: std.fs.File,
    ) !void {
        // The input stream position should point to the last input element
        const total_bits = (try instream.getPos()) * 8;

        // Start from the first element in both streams
        try instream.seekTo(0);
        try outstream.seekTo(0);

        var reader = std.io.bitReader(.little, instream.reader());
        var writer = outstream.writer();

        var read_bits: usize = 0;
        var last_block = false;

        // Decode the stream
        while (read_bits < total_bits) {
            const bfinal = reader.readBitsNoEof(u1, 1) catch {
                return;
            };
            read_bits += 1;

            if (bfinal == 1) {
                last_block = true;
            }

            const bits = reader.readBitsNoEof(u2, 1) catch {
                return;
            };
            read_bits += 2;

            _ = reader.readBitsNoEof(u5, 5) catch {
                return;
            };
            read_bits += 5;

            const btype: FlateBlockType = @enumFromInt(bits);
            switch (btype) {
                FlateBlockType.NO_COMPRESSION => {
                    // Read block length
                    const block_size = try reader.readBitsNoEof(u16, 16);
                    // Skip over ones-complement of length
                    _ = try reader.readBitsNoEof(u16, 16);
                    // Write bytes as-is to output stream
                    for (0..block_size) |_| {
                        const b = reader.readBitsNoEof(u8, 8) catch {
                            return;
                        };
                        read_bits += 8;
                        try writer.writeByte(b);
                    }
                },
                FlateBlockType.DYNAMIC_HUFFMAN => {
                    //try huffman.decompress(instream, outstream);
                },
                FlateBlockType.FIXED_HUFFMAN => {
                },
                else => {
                    log.err(@src(), "Invalid inflate block type {b}", .{bits});
                    return FlateError.UnexpectedBlockType;
                }
            }
        }
    }
};

