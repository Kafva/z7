const std = @import("std");
const z7 = @import("z7");

const TestContext = @import("context_test.zig").TestContext;

const HuffmanTreeNode = z7.huffman_compress.HuffmanTreeNode;
const compress = z7.huffman_compress.compress;
const decompress = z7.huffman_decompress.decompress;

fn run(inputfile: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try TestContext.init(allocator, inputfile, "huffman");
    defer ctx.deinit();

    var enc_len: usize = 0;
    const dec_map = try compress(ctx.allocator, &enc_len, 256, ctx.in, ctx.compressed);
    const compressed_size = try ctx.compressed.getPos();
    ctx.end_time_compress = @floatFromInt(std.time.nanoTimestamp());
    // Decompress from the start of the stream
    try ctx.compressed.seekTo(0);

    try decompress(
        &dec_map,
        enc_len,
        ctx.compressed,
        ctx.decompressed
    );

    try ctx.log_result(compressed_size);

    // Verify correct decoding
    try ctx.eql(ctx.in, ctx.decompressed);
}

////////////////////////////////////////////////////////////////////////////////

test "Huffman node sorting" {
    const size = 20;
    var arr: [size]HuffmanTreeNode = undefined;
    var prng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const random = prng.random();

    for (0..size) |i| {
       arr[i] = HuffmanTreeNode {
            .maybe_value = null,
            .weight = random.int(u4) % 4,
            .freq = random.int(usize) % 1000,
            .maybe_left_child_index = undefined,
            .maybe_right_child_index = undefined
       };
       std.sort.insertion(HuffmanTreeNode, arr[0..i+1], {}, HuffmanTreeNode.greater_than);
    }

    for (0..size-1) |i| {
        try std.testing.expect(arr[i].weight >= arr[i+1].weight);

        if (arr[i].weight == arr[i + 1].weight) {
            try std.testing.expect(arr[i].freq >= arr[i+1].freq);
        }
    }
}

test "Huffman check simple text" {
    try run("tests/testdata/helloworld.txt");
}

test "Huffman check short simple text" {
    try run("tests/testdata/simple.txt");
}

test "Huffman check longer simple text" {
    try run("tests/testdata/flate_test.txt");
}

test "Huffman check 9001 repeated characters" {
    try run("tests/testdata/over_9000_a.txt");
}

test "Huffman check rfc1951.txt" {
    try run("tests/testdata/rfc1951.txt");
}

