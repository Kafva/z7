const std = @import("std");
const lz77_compress = @import("lz77.zig").compress;

test "lz77" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const f = try std.fs.cwd().openFile("tests/testdata/rfc1951.txt", .{ .mode = .read_only });
    defer f.close();
    const reader = f.reader();

    var out = std.ArrayList(u8).init(allocator);
    const writer = out.writer();

    try lz77_compress(allocator, reader, writer);

    //std.debug.print("{s}\n", .{out.items[0..20]});
}
