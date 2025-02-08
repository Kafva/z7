const std = @import("std");
const libflate = @cImport({
    @cInclude("libflate.h");
});

test "Try ffi" {
    // This should be compressible xD
    const input_data = [_]libflate.GoUint8{'A'} ** 256;
    const input = libflate.GoSlice{ .data = @ptrCast(@constCast(&input_data)), .len = input_data.len, .cap = input_data.len };

    const output_data = [_]libflate.GoUint8{0} ** 256;
    const output = libflate.GoSlice{ .data = @ptrCast(@constCast(&output_data)), .len = output_data.len, .cap = output_data.len };

    const r: libflate.GoInt = libflate.FlateHuffmanOnly(input, output);

    try std.testing.expectEqual(0, r);
}
