const std = @import("std");

pub fn main() !void {
    // For one-shot programs, an arena allocator is useful, it allows us
    // to do allocations and free everything at once with
    // arena.deinit() at the end of the program instead of keeping track
    // of each malloc().
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Setup stdout
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    var args = try std.process.argsWithAllocator(allocator);
    _ = args.next(); // Skip program name

    while (args.next()) |arg| {
        try stdout.print("{s}\n", .{arg});
        try bw.flush();
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
