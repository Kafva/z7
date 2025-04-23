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
    /// Map from a 4 byte value in the input stream onto an array
    /// of starting positions in the sliding window where that
    /// input sequence occurs.
    lookup_table: std.AutoHashMap(u32, LzItem),
    /// Inverse lookup table from start_pos -> 'key', we maintain this to easily
    /// know which keys to retire once the sliding window is full.
    start_pos_table: std.AutoHashMap(usize, u32),
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

    /// Are all `start_pos` values below or equal to `limit`?
    pub fn all_le(self: @This(), limit: usize) bool {
        for (0..self.start_pos_cnt) |i| {
            if (self.start_pos[i] > limit) return false;
        }
        return true;
    }

    pub fn best_start_pos(self: @This()) !usize {
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
    ctx.start = ctx.cctx.processed_bytes;
    ctx.end = ctx.start + block_length;

    while (!done and ctx.cctx.processed_bytes < ctx.end) {
        const b = read_byte(ctx.cctx) catch {
            done = true;
            break;
        };

        const lit = ctx.lookahead.push(b);
        // This literal will never take part in a match, time to queue it as a raw byte
        if (lit) |l| {
            try queue_symbol3(ctx.cctx, l);
            try queue_symbol_raw(ctx.cctx, l);
        }
        else {
            // We have not filled the lookahead yet, go again
            continue;
        }

        const bs = try ctx.lookahead.read_offset_end(3, 4);
        const key = bytes_to_u32(bs);

        if (ctx.lookup_table.get(key)) |item| {
            // Found match: Keep going until the match ends and place it in the queue
            done = try lz_queue_match(ctx, key, item);
        }
        else {
            // No match: Save current key into lookup table
            try lz_save(ctx, key, ctx.cctx.processed_bytes - ctx.start);
        }
    }

    // Queue up all literals that are left
    while (ctx.lookahead.prune(1)) |lit| {
        try queue_symbol3(ctx.cctx, lit);
        try queue_symbol_raw(ctx.cctx, lit);
    }

    return done;
}

fn lz_queue_match(ctx: *LzContext, key: u32, item: LzItem) !bool {
    const match_backward_offset = ctx.cctx.processed_bytes - try item.best_start_pos();
    var match_length = Flate.min_length_match;
    var iter_item: LzItem = item;
    var new_b: ?u8 = null;
    var done = false;
    var new_keys = try std.ArrayList([2]usize).initCapacity(ctx.cctx.allocator, Flate.lookahead_length);

    util.print_bytes("Found initial backref match", u32_to_bytes(key));

    // TODO: Keep on checking the 'next' pointer until the match ends
    while (iter_item.next) |next| {
        const bs_to_match = u32_to_bytes(next);
        new_b = read_byte(ctx.cctx) catch {
            done = true;
            break;
        };

        // The oldest byte that we drop here will be part of the back-reference
        if (ctx.lookahead.push(new_b.?)) |b| {
            try queue_symbol_raw(ctx.cctx, b); // Save for NO_COMPRESSION queue
        }

        const new_bs = try ctx.lookahead.read_offset_end(3, 4);
        const new_key = bytes_to_u32(new_bs);
        // Wait until we are done matching before saving any keys,
        // when we actually have matches our new keys will overwrite
        // previous entries.
        const new_dist = ctx.cctx.processed_bytes - ctx.start;
        try new_keys.append(.{new_key, new_dist});

        // Only the final byte in the 'next' object is actually new
        if (bs_to_match[3] != new_b.?) {
            // No match
            break;
        }
        match_length += 1;
        util.print_char(log.debug, "Extending match", new_b.?);
        new_b = null;

        iter_item = blk: {
            if (ctx.lookup_table.get(next)) |v| {
                break :blk v;
            }
            return FlateError.InternalError;
        };
    }

    // Insert the match into the write_queue
    try queue_symbol2(
        ctx.cctx,
        @truncate(match_length),
        @truncate(match_backward_offset)
    );

    // Everything currently in `lookahead` except the final byte was
    // part of the backreference, clear them out
    const prune_cnt: usize = if (new_b != null) 3 else 4;
    _ = ctx.lookahead.prune(prune_cnt);

    // Update the lookup table with the new keys from this match
    for (new_keys.items) |tpl| {
        try lz_save(ctx, @truncate(tpl[0]), tpl[1]);
    }

    return done;
}

fn lz_save(ctx: *LzContext, key: u32, start_pos: usize) !void {
    const sliding_window_start = ctx.cctx.processed_bytes - Flate.window_length;

    // Remove start positions from the lookup_table which are no longer
    // within the sliding window range
    if (ctx.start_pos_table.get(sliding_window_start - 1)) |k| {
        if (ctx.lookup_table.getPtr(k)) |ptr| {
            if (ptr.all_le(start_pos)) {
                // Drop the entry, all positions are before the start of the window
                ctx.start_pos_table.remove(sliding_window_start);
                ctx.lookup_table.remove(k);
            }
            else {
                // Remove the start position furthest back in the sliding window
                ptr.start_pos[ptr.start_pos_cnt - 1] = -1;
            }
        }
        else {
            return FlateError.InternalError;
        }
    }

    // Save the 'start_pos' -> 'key' map
    ctx.start_pos_table.put(start_pos, key);

    const lzitem = blk: {
        if (ctx.lookup_table.getPtr(key)) |ptr| {
            // Update existing key
            if (ptr.start_pos_cnt == ptr.start_pos.len) {
                // TODO: overwrite the most recent value...
                ptr.start_pos[0] = start_pos;
            }
            else {
                // TODO: inserting at worst position for sort...
                ptr.start_pos[ptr.start_pos_cnt] = start_pos;
                ptr.start_pos_cnt += 1;
                std.sort.insertion(usize, ptr.start_pos[0..ptr.start_pos_cnt], {}, std.sort.desc);
            }
        }
        else {
            // Create new key
            var item = LzItem {
                .start_pos = [_]i32{-1}**max_match_start_pos_count,
                .start_pos_cnt = 1,
            };
            item.start_pos[0] = start_pos;
            break :blk item;
        }
    };

    // Save the 'key' -> 'LzItem' map
    try ctx.lookup_table.put(key, lzitem);
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

