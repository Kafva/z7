const std = @import("std");
const flags = @import("flags.zig");

const opt_version = "version";
var opts = [_]flags.Flag{
    .{ .short = 'V', .long = opt_version, .value = .{ .active = false } },
};

const verbose: bool = false;
const usage =
    \\Usage: z7 [OPTION]... [FILE]...
    \\Compress or uncompress FILEs (by default, compress FILES in-place).
    \\
    \\  -c, --stdout      write on standard output, keep original files unchanged
    \\  -d, --decompress  decompress
    \\  -h, --help        give this help
    \\  -v, --verbose     verbose mode
    \\  -V, --version     display version number
;

// gzip is based of DEFLATE which uses LZ77 and Huffman coding.
//
// DEFLATE: https://www.ietf.org/rfc/rfc1951.txt
pub fn main() !void {
    // For one-shot programs, an arena allocator is useful, it allows us
    // to do allocations and free everything at once with
    // arena.deinit() at the end of the program instead of keeping track
    // of each malloc().
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsWithAllocator(allocator);
    try flags.parse(@constCast(&args), &opts);

    std.debug.print("{any}\n", .{opts[0].value.active});
    std.debug.print("{any}\n", .{opts});
}
