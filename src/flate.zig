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

const FlateError = error {
    UnexpectedBlockYype,
};

const FlateBlockType = enum(u2) {
    NO_COMPRESSION = 0b00,
    FIXED_HUFFMAN = 0b01,
    DYNAMIC_HUFFMAN = 0b10,
    RESERVD = 0b11,
};

pub const Flate = struct {
    pub fn compress(
        allocator: std.mem.Allocator,
        instream: std.fs.File,
        outstream: std.fs.File,
    ) !Huffman {
        const block_size = 4096;
        const block_type = FlateBlockType.NO_COMPRESSION;

        // Pass over input stream to calculate frequencies
        var freq = try Huffman.get_frequencies(allocator, instream);
        defer freq.deinit();
        const huffman = try Huffman.init(allocator, &freq);

        var writer = std.io.bitWriter(.little, outstream.writer());

        const total_bytes = try instream.getPos();

        // Reset input stream for second pass
        try instream.seekTo(0);

        const reader = instream.reader();

        var done_bytes: usize = 0;

        while (done_bytes < total_bytes) {
            // Write BFINAL
            const last_block = done_bytes + block_size >= total_bytes;
            if (last_block) {
                try writer.writeBits(@as(u1, 1), 1);
            }
            else {
                try writer.writeBits(@as(u1, 0), 1);
            }

            // Write BTYPE
            try writer.writeBits(@intFromEnum(block_type), 2);

            // Fill up to next byte boundary
            try writer.writeBits(@as(u5, 0), 5);

            switch (block_type) {
                FlateBlockType.NO_COMPRESSION => {
                    // Write length of bytes
                    const len: usize = if (last_block) total_bytes - done_bytes else block_size;

                    if (len > block_size) unreachable;
                    const blen: u16 = @truncate(len);

                    try writer.writeBits(blen, 16);
                    try writer.writeBits(~blen, 16);

                    // Write bytes unmodified to output stream for this block
                    for (0..block_size) |_| {
                        const b = reader.readByte() catch {
                            break;
                        };
                        try writer.writeBits(b, 8);
                    }
                },
                FlateBlockType.DYNAMIC_HUFFMAN => {
                    // Write compressed block
                    try huffman.compress(instream, outstream, block_size);
                },
                FlateBlockType.FIXED_HUFFMAN => {

                },
                else => {
                    log.err(@src(), "Invalid deflate block type {b}", .{block_type});
                    return FlateError.UnexpectedBlockYype;
                }
            }

            done_bytes += block_size;
        }


        return huffman;
    }

    pub fn decompress(
        huffman: Huffman,
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
                    try huffman.decompress(instream, outstream);
                },
                FlateBlockType.FIXED_HUFFMAN => {
                },
                else => {
                    log.err(@src(), "Invalid inflate block type {b}", .{bits});
                    return FlateError.UnexpectedBlockYype;
                }
            }
        }
    }
};

