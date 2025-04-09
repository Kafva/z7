const std = @import("std");
const util = @import("util.zig");
const log = @import("log.zig");

const color_base: u8 = 214;

pub const HuffmanError = error {
    UnexpectedCharacter,
    UnexpectedEncodedSymbol,
    BadTreeStructure,
    MaxDepthInsufficent,
};

pub const NodeEncoding = struct {
    /// It is seldom efficient to use encodings longer than 15 (2**4 - 1) bits
    /// for a character.
    ///
    /// go/src/compress/flate/huffman_code.go
    ///   "[...] the maximum number of bits that should be used to encode any literal.
    ///   It must be less than 16."
    bit_shift: u4,
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

        return writer.print("{{ .bit_shift = {}, .bits = 0x{b} }}",
                            .{self.bit_shift, self.bits});
    }

    pub fn dump_mapping(self: *const @This(), char: u8) void {
        const color: u8 = color_base + @as(u8, self.bit_shift);
        if (std.ascii.isPrint(char)) {
            log.debug(@src(), "(0x{x}) '{c}' -> \x1b[38;5;{d}m{any}\x1b[0m", .{char, char, color, self});
        } else {
            log.debug(@src(), "(0x{x}) ' ' -> \x1b[38;5;{d}m{any}\x1b[0m", .{char, color, self});
        }
    }
};

pub const Node = struct {
    /// Only leaf nodes contain a character
    char: ?u8,
    freq: usize,
    /// A lower weight has lower priority (minimum weight is 0).
    /// The maximum weight represents the maximum depth of the tree,
    /// a higher weight should be placed higher up in the tree.
    weight: u4,
    left_child_index: ?usize,
    right_child_index: ?usize,

    /// Priority sort comparison method (descending):
    ///
    /// First: Sort based on weight (descending, greater first)
    /// Second: Sort based on frequency (descending, greater first)
    /// Example:
    /// [
    ///     { .weight = 1, .freq = 3 },
    ///     { .weight = 1, .freq = 2 },
    ///     { .weight = 1, .freq = 1 },
    ///     { .weight = 0, .freq = 3 },
    ///     { .weight = 0, .freq = 2 },
    ///     { .weight = 0, .freq = 1 },
    /// ]
    ///
    /// When constructing the tree we want to pop items from the *tail* of the queue.
    /// We exhaust the nodes with lowest remaining weight with the lowest frequency first.
    /// Returns true if `lhs` should be placed before `rhs`.
    pub fn greater_than(_: void, lhs: @This(), rhs: @This()) bool {
        // If a the lhs node has the same values as the rhs, move it up as more recent,
        // this is needed for the fixed huffman construction to be correct.
        if (lhs.weight == rhs.weight) {
            // Greater frequency further in the front
            return lhs.freq >= rhs.freq;
        }
        // Ignore frequency if the weights differ
        return lhs.weight >= rhs.weight;
    }

    pub fn format(
        self: *const @This(),
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype
    ) !void {
        if (fmt.len != 0) {
            return std.fmt.invalidFmtError(fmt, self);
        }

        if (self.char) |char| {
            if (std.ascii.isPrint(char) and char != '\n') {
                return writer.print("{{ .weight = {d}, .freq = {d}, .char = '{c}' }}",
                                  .{self.weight, self.freq, char});
            } else {
                return writer.print("{{ .weight = {d}, .freq = {d}, .char = 0x{x} }}",
                                  .{self.weight, self.freq, char});
            }
        } else {
            return writer.print("{{ .weight = {d}, .freq = {d} }}", .{self.weight, self.freq});
        }
    }

    pub fn dump(self: @This(), comptime weight: u4, pos: []const u8) void {
        const prefix = util.repeat('-', weight) catch unreachable;
        const side_color: u8 = if (std.mem.eql(u8, "1", pos)) 37 else 97;
        const color: u8 = color_base + @as(u8, weight);
        log.debug(
            @src(),
            "\x1b[{d}m`{s}{s}\x1b[0m: \x1b[38;5;{d}m{any}\x1b[0m",
            .{side_color, prefix, pos, color, self}
        );
        std.heap.page_allocator.free(prefix);
    }
};
