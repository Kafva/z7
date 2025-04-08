const std = @import("std");
const util = @import("context_test.zig");
const TestContext = @import("context_test.zig").TestContext;
const Huffman = @import("huffman.zig").Huffman;
const Node = @import("huffman.zig").Node;

fn run(
    inputfile: []const u8,
    label: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try TestContext.init(allocator, inputfile, label);
    defer ctx.deinit();

    var freq = try Huffman.get_frequencies(ctx.allocator, ctx.in);
    defer freq.deinit();
    const huffman = try Huffman.init(ctx.allocator, &freq);

    // Reset input stream for second pass
    try ctx.in.seekTo(0);
    try huffman.compress(ctx.in, ctx.compressed, std.math.maxInt(usize));

    try ctx.log_result(try ctx.compressed.getPos());

    try huffman.decompress(ctx.compressed, ctx.decompressed);

    // Verify correct decoding
    try ctx.eql(ctx.in, ctx.decompressed);
}

////////////////////////////////////////////////////////////////////////////////

test "Huffman node sorting" {
    const size = 20;
    var arr: [size]Node = undefined;
    var prng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const random = prng.random();

    for (0..size) |i| {
       arr[i] = Node {
            .char = null,
            .weight = random.int(u4) % 4,
            .freq = random.int(usize) % 1000,
            .left_child_index = undefined,
            .right_child_index = undefined
       };
       std.sort.insertion(Node, arr[0..i+1], {}, Node.greater_than);
    }

    for (0..size-1) |i| {
        try std.testing.expect(arr[i].weight >= arr[i+1].weight);

        if (arr[i].weight == arr[i + 1].weight) {
            try std.testing.expect(arr[i].freq >= arr[i+1].freq);
        }
    }
}

// test "Huffman on empty file" {
//     try run("tests/testdata/empty", "huffman");
// }

test "Huffman on simple text" {
    try run("tests/testdata/helloworld.txt", "huffman");
}

// test "Huffman on rfc1951.txt" {
//     try run("tests/testdata/rfc1951.txt", "huffman");
// }

// test "Huffman on 9001 repeated characters" {
//     try run("tests/testdata/over_9000_a.txt", "huffman");
// }

// test "Huffman on random data" {
//     try run(TestContext.random_label, "huffman");
// }
