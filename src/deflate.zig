/// gzip is just a file format.
/// gzip: https://www.ietf.org/rfc/rfc1952.txt
///
/// The actual compression is done with the DEFLATE algorithm.
/// deflate: https://www.ietf.org/rfc/rfc1951.txt
///
/// The deflate algorithm uses a variant Huffman encoding and LZ77.
/// There is no rfc for LZ77 (Lempel-Ziv), it is an old algorithm from the '70s.
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
/// To make the Huffman trees canonical the Huffman encoding used in deflate
/// has some special rules:
///     * Codes of the same length should encode values in the order of the
///     alphabeht, so e.g.
///     NOK [A: 011, B: 010]
///     OK  [A: 010, B: 011]  (A encoding should be lower than B encoding)
///
///     * Shorter codes precede longer codes
///     NOK [A: 111, B: 10]
///     OK  [A: 10, B: 111]
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
/// LZ77
/// ======
/// The LZ77 algorithm is a dictionary-based compression algorithm that uses a
/// sliding window and a lookahead buffer to find and replace repeated patterns
/// in a data stream with pointers.
///
/// LZ77 is allowed to have back-references across block boundaries (32K or less
/// steps back is the limit)
///
///
///
pub fn deflate(buf: []const u8) !void {
    _ = buf;
}

pub fn huffman_encode(buf: []const u8) !void {
    _ = buf;
}
