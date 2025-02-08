const std = @import("std");
const libflate = @cImport({
    @cInclude("libflate.h");
});

test "Try ffi" {
    // This should be compressible xD
    const input_data = [_]libflate.GoUint8{'A'} ** 256;

    var compressed_data = [_]libflate.GoUint8{0} ** 256;
    var compressed_len: libflate.GoInt = -1;

    // var decompressed_data = [_]libflate.GoUint8{0} ** 256;
    // var decompressed_len: libflate.GoInt = 256;

    // zig fmt: off
    const input = libflate.GoSlice{
        .data = @ptrCast(@constCast(&input_data)),
        .len = input_data.len,
        .cap = input_data.len
    };
    const compressed = libflate.GoSlice{
        .data = @ptrCast(@constCast(&compressed_data)),
        .len = compressed_data.len,
        .cap = compressed_data.len
    };
    // const decompressed = libflate.GoSlice{
    //     .data = @ptrCast(@constCast(&decompressed_data)),
    //     .len = decompressed_data.len,
    //     .cap = decompressed_data.len
    // };
    // zig fmt: on

    std.debug.print("before: {any}\n", .{compressed_data});

    compressed_len = libflate.DeflateHuffmanOnly(input, compressed);
    try std.testing.expect(compressed_len > 10);

    std.debug.print("after: {any}\n", .{compressed_data});

    // decompressed_len = libflate.InflateHuffmanOnly(compressed, decompressed);
    // try std.testing.expectEqual(256, decompressed_len);
}
