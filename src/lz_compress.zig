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
    /// Inverse lookup table from start_pos -> 'key', we maintain this to easily
    /// know which keys to retire once the sliding window is full.
    start_pos_table: std.AutoHashMap(usize, u32),
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
    var match_start_pos: ?i32 = null;
    var match_length: usize = 0;
    ctx.start = ctx.cctx.processed_bytes;
    ctx.end = ctx.start + block_length;

    while (!done and ctx.cctx.processed_bytes < ctx.end) {
        // Read next byte for lookahead
        const b = read_byte(ctx.cctx) catch {
            done = true;
            break;
        };

        const old = ctx.lookahead.push(b);
        if (old) |old_b| {
            // Queue each byte that exits the lookahead onto the sliding window
            _ = ctx.sliding_window.push(old_b);
            try queue_symbol_raw(ctx.cctx, b); // Save for NO_COMPRESSION queue
        }

        if (ctx.lookahead.count() != Flate.min_length_match) {
            // We have not filled the lookahead yet, go again
            continue;
        }

        if (match_start_pos) |pos| {
            const bs = try ctx.sliding_window.read_offset_start(pos, 1);
            if (bs[0] == b) {
                // Extend match
                util.print_char(log.debug, "Extending match", b);
                match_length += 1;
            }
            else {
                // End match
                const match_length_i: i32 = @intCast(match_length);
                const processed_bytes_i: i32 = @intCast(ctx.cctx.processed_bytes);
                try queue_symbol2(
                    ctx.cctx,
                    @truncate(match_length),
                    @intCast(processed_bytes_i - match_length_i),
                );
                match_start_pos = null;
                match_length = 0;
            }
        }
        else {
            // Look for new match
            const bs = try ctx.lookahead.read_offset_end(3, 4);
            const key = bytes_to_u32(bs);

            if (ctx.lookup_table.get(key)) |item| {
                // New match
                match_start_pos = try item.best_start_pos();
                match_length = Flate.min_length_match;
                util.print_bytes("Found initial backref match", u32_to_bytes(key));
            }
            else if (old) |old_b|  {
                // No match: Queue the dropped byte as a raw literal
                try queue_symbol3(ctx.cctx, old_b);
            }
        }

        if (ctx.sliding_window.count() >= 4) {
            // Add a lookup entry for the byte that was dropped into the lookahead 
            // 8 bytes back, 4 for lookahead, 4 to get the start of the u32 value.
            const window_bs = try ctx.sliding_window.read_offset_end(3, 4);
            const window_key = bytes_to_u32(window_bs);
            try lz_save(ctx, window_key, ctx.cctx.processed_bytes - 8);
        }
    }

    // Queue up any left over literals as-is
    while (ctx.lookahead.prune(1)) |lit| {
        try queue_symbol3(ctx.cctx, lit);
        try queue_symbol_raw(ctx.cctx, lit);
    }

    return done;
}


fn lz_save(ctx: *LzContext, key: u32, start_pos: usize) !void {
    // const sliding_window_start = if (ctx.cctx.processed_bytes < Flate.window_length) 0
    //                              else ctx.cctx.processed_bytes - Flate.window_length;

    // // Remove start positions from the lookup_table which are no longer
    // // within the sliding window range
    // if (ctx.start_pos_table.get(sliding_window_start)) |k| {
    //     if (ctx.lookup_table.getPtr(k)) |ptr| {
    //         if (ptr.all_lt(sliding_window_start)) {
    //             // Drop the entry, all positions are before the start of the window
    //             _ = ctx.start_pos_table.remove(sliding_window_start);
    //             if (!ctx.lookup_table.remove(k)) {
    //                 return FlateError.InternalError;
    //             }
    //         }
    //         else {
    //             // Remove the start position furthest back in the sliding window
    //             ptr.start_pos[ptr.start_pos_cnt - 1] = -1;
    //         }
    //     }
    //     else {
    //         return FlateError.InternalError;
    //     }
    // }

    // Save the 'start_pos' -> 'key' map
    try ctx.start_pos_table.put(start_pos, key);

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
        util.print_bytes("Updated key", u32_to_bytes(key));
        log.debug(@src(), "start_pos: {any}", .{ptr.start_pos[0..ptr.start_pos_cnt]});
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
        util.print_bytes("Saved new key", u32_to_bytes(key));
        log.debug(@src(), "start_pos: {any}", .{item.start_pos[0..item.start_pos_cnt]});
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

