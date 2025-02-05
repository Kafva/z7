const std = @import("std");

const Flag = @import("flags.zig").Flag;
const FlagIterator = @import("flags.zig").FlagIterator;

const opt_h = "help";
const opt_V = "version";
const opt_v = "verbose";
const opt_d = "decompress";
const opt_c = "stdout";
var opts = [_]Flag{
    .{ .short = 'h', .long = opt_h, .value = .{ .active = false } },
    .{ .short = 'V', .long = opt_V, .value = .{ .active = false } },
    .{ .short = 'v', .long = opt_v, .value = .{ .active = false } },
    .{ .short = 'd', .long = opt_d, .value = .{ .active = false } },
    .{ .short = 'c', .long = opt_c, .value = .{ .active = false } },
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

    var args = try std.process.argsWithAllocator(allocator);
    var flags = FlagIterator(std.process.ArgIterator){ .iter = &args };
    const first_arg = try flags.parse(&opts);

    if (first_arg) |a| {
        std.debug.print("arg: {s}\n", .{a});
    }
    std.debug.print("{any}\n", .{opts[0].value.active});
    std.debug.print("{any}\n", .{opts});
}
