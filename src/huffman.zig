const std = @import("std");
const util = @import("util.zig");
const log = @import("log.zig");

pub const color_base: u8 = 214;

pub const HuffmanError = error {
    UnexpectedCharacter,
    UnexpectedEncodedSymbol,
    BadEncoding,
    BadTreeStructure,
    MaxDepthInsufficent,
    InternalError
};

/// Represents a path in a Huffman tree as a u16 integer.
pub const HuffmanEncoding = struct {
    /// It is seldom efficient to use encodings longer than 15 (2**4 - 1) bits
    /// for a character.
    ///
    /// go/src/compress/flate/huffman_code.go
    ///   "[...] the maximum number of bits that should be used to encode any literal.
    ///   It must be less than 16."
    bit_shift: u4,
    /// The bits should be read from most-to-least-significant when traversing
    /// a Huffman tree from the top.
    bits: u16,

    pub fn format(
        self: *const @This(),
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype
    ) !void {
        if (fmt.len != 0) {
            return std.fmt.invalidFmtError(fmt, self);
        }

        return writer.print("{{ .bit_shift = {}, .bits = {b:>8} }}",
                            .{self.bit_shift, self.bits});
    }

    pub fn dump_mapping(self: *const @This(), value: u16) void {
        const istty = std.io.getStdErr().isTty();
        const prefix = "({d: >3}) ";
        const color: u8 = color_base + @as(u8, self.bit_shift);
        if (value < 256) {
            const char: u8 = @truncate(value);
            if (std.ascii.isPrint(char)) {
                if (istty) {
                    log.debug(
                        @src(),
                        prefix ++ "'{c}' -> \x1b[38;5;{d}m{any}\x1b[0m",
                        .{char, char, color, self}
                    );
                }
                else {
                    log.debug(@src(), prefix ++ "'{c}' -> {any}", .{char, char, self});
                }
            } else {
                if (istty) {
                    log.debug(
                        @src(),
                        prefix ++ "    -> \x1b[38;5;{d}m{any}\x1b[0m",
                        .{char, color, self}
                    );
                } else {
                    log.debug(@src(), prefix ++ "    -> {any}", .{char, self});
                }
            }
        }
        else {
            if (istty) {
                log.debug(
                    @src(),
                    prefix ++ "    -> \x1b[38;5;{d}m{any}\x1b[0m",
                    .{value, color, self}
                );
            } else {
                log.debug(@src(), prefix ++ "    -> {any}", .{value, self});
            }
        }
    }
};
