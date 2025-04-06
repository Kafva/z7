const std = @import("std");
const util = @import("context_test.zig");
const Huffman = @import("huffman.zig").Huffman;
const Node = @import("huffman.zig").Node;

const max_size = 512*1024; // 0.5 MB

fn run(inputfile: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try run_alloc(allocator, inputfile);
}

fn run_alloc(allocator: std.mem.Allocator, inputfile: []const u8) !void {
    var compressed: std.fs.File = undefined;
    var decompressed: std.fs.File = undefined;
    var in: std.fs.File = undefined;
    var in_size: usize = undefined;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try util.setup(allocator, &tmp, inputfile, &in, &in_size, &compressed, &decompressed);
    defer in.close();

    var freq = try Huffman.get_frequencies(allocator, in);
    defer freq.deinit();
    const huffman = try Huffman.init(allocator, &freq);

    // Reset input stream for second pass
    try in.seekTo(0);
    try huffman.compress(in, compressed, std.math.maxInt(usize));
    try util.log_result("huffman", inputfile, in_size, try compressed.getPos());

    try huffman.decompress(compressed, decompressed);

    // Verify correct decoding
    try util.eql(allocator, in, decompressed);
}

fn run_dir(dirpath: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const filepaths = try util.list_files(allocator, dirpath);

    for (filepaths.items) |filepath| {
        try run_alloc(allocator, filepath);
    }
}

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

test "Huffman on empty file" {
    try run("tests/testdata/empty");
}

test "Huffman on simple text" {
    try run("tests/testdata/helloworld.txt");
}

test "Huffman on rfc1951.txt" {
    try run("tests/testdata/rfc1951.txt");
}

test "Huffman on 9001 repeated characters" {
    try run("tests/testdata/over_9000_a.txt");
}

// test "Huffman on random data" {
//     try run(util.random_label);
// }
// 
// test "Huffman on fuzzing testdata from zig stdlib" {
//     try run_dir("tests/testdata/zig/fuzz");
// }
// 
// test "Huffman on block writer testdata from zig stdlib" {
//     try run_dir("tests/testdata/zig/block_writer");
// }
