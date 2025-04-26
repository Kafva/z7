const std = @import("std");
const log = @import("log.zig");
const util = @import("util.zig");

const CompressContext = @import("flate_compress.zig").CompressContext;
const Flate = @import("flate.zig").Flate;
const FlateError = @import("flate.zig").FlateError;
const FlateSymbol = @import("flate.zig").FlateSymbol;
const RangeSymbol = @import("flate.zig").RangeSymbol;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;

const read_byte = @import("flate_compress.zig").read_byte;
const queue_symbol2 = @import("flate_compress.zig").queue_symbol2;
const queue_symbol3 = @import("flate_compress.zig").queue_symbol3;
const queue_symbol_raw = @import("flate_compress.zig").queue_symbol_raw;

pub const LzContext = struct {
    /// Pointer back to the main compression context
    cctx: *CompressContext,
    start: usize,
    end: usize,
    sliding_window: RingBuffer(u8),
    /// Map from a 4 byte value in the input stream onto an array
    /// of starting positions in the sliding window where that
    /// input sequence occurs.
    lookup_table: std.AutoHashMap(u32, LzItem),
    /// 4 byte lookahead
    lookahead: RingBuffer(u8),
};

const max_match_start_pos_count = @divFloor(Flate.lookahead_length, 4);

pub const LzItem = struct {
    /// Pointer in teh lookup table to the next item
    /// E.g. ' Huff' -> 'Huff' -> 'uffm'
    ///
    /// With 4 byte keys we cannot have match chains the repeat the same key, 
    /// e.g. 'aaaa' -> 'aaaa' -> 'aaaa'.
    /// [ foo1 foo2 aaaa aaaa foo3 foo4 aaaa aaaa aaaa ]
    ///
    /// How do we keep several 'aaaa' match sequences of different lengths while keeping
    /// the quick lookup property...
    ///
    /// ....
    ///
    /// 'foo1' -> { start_pos: [0] }
    /// 'foo2' -> { start_pos: [4] }
    /// 'aaaa' -> { start_pos: [32,28,24,16,8,-1,-1...] }
    /// 'foo3' -> { start_pos: [16] }
    /// 'foo4' -> { start_pos: [20] }
    ///
    /// Prune everything that only has a start_pos behind the sliding window
    ///
    /// The starting offset in the input stream for this entry
    start_pos: [max_match_start_pos_count]i32,
    start_pos_cnt: usize,

    pub fn format(
        self: *const @This(),
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype
    ) !void {
        if (fmt.len != 0) {
            return std.fmt.invalidFmtError(fmt, self);
        }
        if (self.next) |n| {
            const bs = u32_to_bytes(n);
            return writer.print(
                "{{ .next = '{c}{c}{c}{c}', .start_pos = {d} }}",
                .{bs[0], bs[1], bs[2], bs[3], self.start_pos}
            );
        }
        else {
            return writer.print("{{ .next = null, .start_pos = {d} }}", .{self.start_pos});
        }
    }

    /// Are all `start_pos` values below `limit`?
    pub fn all_lt(self: @This(), limit: usize) bool {
        for (0..self.start_pos_cnt) |i| {
            if (self.start_pos[i] >= limit) return false;
        }
        return true;
    }

    pub fn best_start_pos(self: @This()) !i32 {
        if (self.start_pos_cnt == 0) {
            return FlateError.InternalError;
        }
        const oldest_value = self.start_pos[self.start_pos_cnt - 1];
        if (oldest_value < 0) {
            return FlateError.InternalError;
        }
        return @intCast(oldest_value);
    }
};

pub fn lz_compress(ctx: *LzContext, block_length: usize) !bool {
    // * Backreferences can not go back more than 32K.
    // * Backreferences are allowed to go back into the previous block.
    var done = false;
    var maybe_match_start_pos: ?i32 = null;
    var match_start_window_pos: i32 = 0;
    var match_length: i32 = 0;
    ctx.start = ctx.cctx.processed_bytes;
    ctx.end = ctx.start + block_length;

    while (!done and ctx.cctx.processed_bytes < ctx.end) {
        // Read next byte for lookahead
        const b = read_byte(ctx.cctx) catch {
            done = true;
            break;
        };

        const old = ctx.lookahead.push(b);

        if (ctx.lookahead.count() != Flate.min_length_match) {
            // We have not filled the lookahead yet, go again
            continue;
        }

        if (old) |old_b| {
            // Queue each byte that exits the lookahead onto the sliding window
            _ = ctx.sliding_window.push(old_b);
            // Save for NO_COMPRESSION queue
            try queue_symbol_raw(ctx.cctx, b);
        }

        if (maybe_match_start_pos) |match_start_pos| {
            // Handle match in progress
            const offset = match_start_pos + match_length;
            const bs = try ctx.sliding_window.read_offset_start(offset, 1);

            if (offset + 1 == match_start_window_pos or    // Reached the end of the window
                bs[0] != b or                              // Backref no longer matches
                match_length + 1 == Flate.lookahead_length // Maximum length match
            ) {
                // End match!
                log.debug(@src(), "Ending match @{d} ", .{offset});
                try queue_symbol2(
                    ctx.cctx,
                    @intCast(match_length),
                    @intCast(match_start_window_pos - match_start_pos),
                );
                maybe_match_start_pos = null;
                // Everything in the lookahead except the final
                // byte was made part of the backref
                for (0..3) |_| {
                    if (ctx.lookahead.prune(1)) |l| _ = ctx.sliding_window.push(l);
                }
            }
            else {
                // Extend match!
                util.print_char(log.debug, "Extending match", b);
                match_length += 1;
            }
        }
        else {
            // Look for new match
            const bs = try ctx.lookahead.read_offset_end(3, 4);
            const key = bytes_to_u32(bs);

            if (ctx.lookup_table.get(key)) |item| {
                // New match
                maybe_match_start_pos = try item.best_start_pos();
                match_start_window_pos = @intCast(ctx.sliding_window.count());
                match_length = @intCast(Flate.min_length_match);
                util.print_bytes("Found initial backref match", u32_to_bytes(key));
                log.debug(@src(), "Starting match @{d} [window @{d}]", .{
                    maybe_match_start_pos.?,
                    ctx.sliding_window.count(),
                });
            }
            if (old) |old_b|  {
                // No match: Queue the dropped byte as a raw literal
                try queue_symbol3(ctx.cctx, old_b);
            }
        }

        if (ctx.sliding_window.count() >= 4) {
            // Add a lookup entry for the byte that was dropped into the lookahead 
            const window_bs = try ctx.sliding_window.read_offset_end(3, 4);
            const window_key = bytes_to_u32(window_bs);
            try lz_save(ctx, window_key, ctx.sliding_window.count() - 4);
        }
    }

    // Finish any in-progress match
    if (maybe_match_start_pos) |match_start_pos| {
        log.debug(@src(), "Ending match due to input EOF @{d}", .{
            match_start_pos + match_length,
        });
        try queue_symbol2(
            ctx.cctx,
            @intCast(match_length),
            @intCast(match_start_window_pos - match_start_pos),
        );
        // We can only get into this branch if we were extending a match
        // in the last iteration, in that case, the entire lookahead was
        // part of the match.
        _ = ctx.lookahead.prune(4);
    }

    // Queue up any left over literals as-is
    if (ctx.lookahead.count() > 0) {
        log.debug(@src(), "Appending left-over raw bytes", .{});

        while (ctx.lookahead.prune(1)) |lit| {
            try queue_symbol3(ctx.cctx, lit);
            try queue_symbol_raw(ctx.cctx, lit);
        }
    }

    return done;
}

fn lz_save(ctx: *LzContext, key: u32, start_pos: usize) !void {
    if (ctx.lookup_table.getPtr(key)) |ptr| {
        // Update existing key
        if (ptr.start_pos_cnt == ptr.start_pos.len) {
            // TODO: overwrite the most recent value...
            ptr.start_pos[0] = @intCast(start_pos);
        }
        else {
            // TODO: inserting at worst position for sort...
            ptr.start_pos[ptr.start_pos_cnt] = @intCast(start_pos);
            ptr.start_pos_cnt += 1;
            std.sort.insertion(i32, ptr.start_pos[0..ptr.start_pos_cnt], {}, std.sort.desc(i32));
        }
    }
    else {
        // Create new key
        var item = LzItem {
            .start_pos = [_]i32{-1}**max_match_start_pos_count,
            .start_pos_cnt = 1,
        };
        item.start_pos[0] = @intCast(start_pos);
        // Save the 'key' -> 'LzItem' map
        try ctx.lookup_table.put(key, item);
    }
}

fn u32_to_bytes(int: u32) [4]u8 {
    return [_]u8{
       @as(u8, @truncate((int & 0xff00_0000) >> 24)),
       @as(u8, @truncate((int & 0x00ff_0000) >> 16)),
       @as(u8, @truncate((int & 0x0000_ff00) >> 8)),
       @as(u8, @truncate((int & 0x0000_00ff)))
    };
}

fn bytes_to_u32(bs: [4]u8) u32 {
    return @as(u32, bs[0]) << 24 |
           @as(u32, bs[1]) << 16 |
           @as(u32, bs[2]) << 8 |
           @as(u32, bs[3]);
}

