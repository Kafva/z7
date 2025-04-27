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
    maybe_sliding_window_min_index: ?usize,
    sliding_window_index: usize,
    sliding_window: RingBuffer(u8),
    /// Map from a 4 byte value in the input stream onto an array
    /// of starting positions in the sliding window where that
    /// input sequence occurs.
    lookup_table: std.AutoHashMap(u32, LzItem),
    /// 4 byte lookahead
    lookahead: RingBuffer(u8),
};

pub const LzItem = struct {
    /// Maximum number of start indices to maintain for one `LzItem`
    const start_indices_max: usize = @divFloor(Flate.lookahead_length, 4);
    /// The starting offset(s) in the input stream for this entry
    /// Example:
    ///
    /// [ foo1 foo2 aaaa aaaa foo3 foo4 aaaa aaaa aaaa ]
    ///
    /// =>
    ///
    /// 'foo1' -> { start_indices: [0] }
    /// 'foo2' -> { start_indices: [4] }
    /// 'aaaa' -> { start_indices: [-1,-1,...,8,16,24,28,32] }
    /// 'foo3' -> { start_indices: [16] }
    /// 'foo4' -> { start_indices: [20] }
    ///
    /// Note: These indices are relative to the *start of the input stream*!
    start_indices: [LzItem.start_indices_max]i32,
    start_indices_cnt: usize,

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
                "{{ .next = '{c}{c}{c}{c}', .start_indices = {d} }}",
                .{bs[0], bs[1], bs[2], bs[3], self.start_indices}
            );
        }
        else {
            return writer.print("{{ .next = null, .start_indices = {d} }}", .{self.start_indices});
        }
    }

    pub fn init(start_index: usize) @This() {
        var item = LzItem {
            .start_indices = [_]i32{-1}**LzItem.start_indices_max,
            .start_indices_cnt = 1,
        };
        item.start_indices[LzItem.start_indices_max - 1] = @intCast(start_index);

        return item;
    }

    /// Remove all starting positions below the `low_limit`
    pub fn prune(self: *@This(), low_limit: usize) void {
        const idx = LzItem.start_indices_max - self.start_indices_cnt;
        for (idx..self.start_indices.len) |i| {
            if (self.start_indices[i] != -1 and self.start_indices[i] < low_limit) {
                log.debug(@src(), "Pruning start index: {d}", .{self.start_indices[i]});
                self.start_indices[i] = -1;
                self.start_indices_cnt -= 1;
            }
        }
        std.sort.insertion(i32, self.start_indices[0..], {}, std.sort.asc(i32));
    }

    pub fn add(self: *@This(), new_start_pos: i32) void {
        if (self.start_indices_cnt == self.start_indices.len) {
            // Keep overwriting the newest value
            self.start_indices[self.start_indices_cnt - 1] = @intCast(new_start_pos);
        }
        else {
            // Insert at tail of array and keep it sorted in ascending order
            self.start_indices_cnt += 1;

            const idx = LzItem.start_indices_max - self.start_indices_cnt;
            self.start_indices[idx] = @intCast(new_start_pos);
            std.sort.insertion(i32, self.start_indices[0..], {}, std.sort.asc(i32));
        }
    }

    pub fn best_start_pos(self: @This()) ?i32 {
        if (self.start_indices_cnt == 0) {
            return null;
        }
        // Always take the match furthest in the past, this optimizes for long
        // runs of the same character, e.g. 'aaaa' -> 'aaaa' -> 'aaaa', we pick the
        // first occurence of 'aaaa'.
        const idx = LzItem.start_indices_max - self.start_indices_cnt;
        const oldest_value = self.start_indices[idx];
        if (oldest_value < 0) {
            log.debug(@src(), "{any}", .{self.start_indices});
            return null;
        }
        return @intCast(oldest_value);
    }
};

pub fn lz_compress(ctx: *LzContext, block_length: usize) !bool {
    // * Backreferences can not go back more than 32K.
    // * Backreferences are allowed to go back into the previous block.
    var done = false;
    // Starting position of a backref match relative to the start of the input stream
    var maybe_match_start_pos: ?i32 = null;
    var match_length: i32 = 0;
    // The distance to the end of the sliding window from the start of a new match.
    // The length of a match can not exceed this value
    var dist_to_sliding_window_end: i32 = 0;
    ctx.start = ctx.cctx.processed_bytes;
    ctx.end = ctx.start + block_length;
    ctx.sliding_window_index = ctx.start;

    while (!done and ctx.cctx.processed_bytes < ctx.end) {
        // Read next byte for lookahead
        const b = read_byte(ctx.cctx) catch {
            done = true;
            break;
        };

        const maybe_old = ctx.lookahead.push(b);

        if (ctx.lookahead.count() != Flate.min_length_match) {
            // We have not filled the lookahead yet, go again
            continue;
        }

        if (maybe_old) |old| {
            // Queue each byte that exits the lookahead onto the sliding window
            _ = ctx.sliding_window.push(old);
            ctx.sliding_window_index += 1;
            // Save for NO_COMPRESSION queue
            try queue_symbol_raw(ctx.cctx, b);

            if (ctx.sliding_window.count() >= 4) {
                // Add a lookup entry for the byte that was dropped into the lookahead
                const window_bs = try ctx.sliding_window.read_offset_end(3, 4);
                const window_key = bytes_to_u32(window_bs);
                const start_idx = ctx.sliding_window.count() - 4;

                if (ctx.lookup_table.getPtr(window_key)) |ptr| {
                    // Update key with new start position
                    ptr.add(@intCast(start_idx));
                }
                else {
                    // Save the 'key' -> 'LzItem' map
                    try ctx.lookup_table.put(window_key, LzItem.init(start_idx));
                }
            }
        }

        if (ctx.sliding_window.count() == Flate.window_length) {
            // Once the sliding window is filled, slide it one byte forward every iteration.
            ctx.maybe_sliding_window_min_index =
                if (ctx.maybe_sliding_window_min_index) |s| s + 1 else 1;
        }

        if (maybe_match_start_pos) |match_start_pos| {
            // Handle match in progress
            const offset = match_start_pos + match_length;
            const bs = try ctx.sliding_window.read_offset_start(offset, 1);

            if (match_length == dist_to_sliding_window_end or      // Reached the end of the window
                match_length + 1 == Flate.lookahead_length or      // Maximum length match
                bs[0] != b                                         // Backref no longer matches
            ) {
                // End match!
                log.debug(@src(), "Ending match @{d} ", .{offset});

                const processed_bytes_i: i32 = @intCast(ctx.cctx.processed_bytes);
                const backref_dist: u16 = @intCast(processed_bytes_i - 1 - match_length - match_start_pos);
                try queue_symbol2(
                    ctx.cctx,
                    @intCast(match_length),
                    backref_dist
                );
                maybe_match_start_pos = null;
                // Everything in the lookahead except the final byte was made part of the backref
                for (0..3) |_| {
                    if (ctx.lookahead.prune(1)) |l| {
                        _ = ctx.sliding_window.push(l);
                        ctx.sliding_window_index += 1;
                        // Add a lookup entry for each one
                        if (ctx.sliding_window.count() >= 4) {
                            const window_bs = try ctx.sliding_window.read_offset_end(3, 4);
                            const window_key = bytes_to_u32(window_bs);
                            const start_idx = ctx.sliding_window.count() - 4;

                            if (ctx.lookup_table.getPtr(window_key)) |ptr| {
                                ptr.add(@intCast(start_idx));
                            }
                            else {
                                try ctx.lookup_table.put(window_key, LzItem.init(start_idx));
                            }
                        }
                    }
                }
            }
            else {
                // Extend match!
                util.print_char(log.debug, "Extending match", b);
                match_length += 1;
            }
        }
        else {
            // Queue the dropped byte as a raw literal
            if (maybe_old) |old|  {
                try queue_symbol3(ctx.cctx, old);
            }

            // Look for new match
            const bs = try ctx.lookahead.read_offset_end(3, 4);
            const key = bytes_to_u32(bs);

            if (ctx.lookup_table.getPtr(key)) |ptr| {
                // New match: Save the distance and length and continue the match

                // Remove start positions past the sliding window
                if (ctx.maybe_sliding_window_min_index) |sliding_window_min_index| {
                    ptr.prune(sliding_window_min_index);
                }

                if (ptr.start_indices_cnt > 0) {
                    // There was a match, but it may have been outside the sliding window
                    maybe_match_start_pos = ptr.best_start_pos();
                    if (maybe_match_start_pos) |match_start_pos| {
                        match_length = @intCast(Flate.min_length_match);

                        const processed_bytes_i: i32 = @intCast(ctx.cctx.processed_bytes);
                        // We need to make sure that the match does not go past where the
                        // sliding window was during the start of the match
                        dist_to_sliding_window_end = processed_bytes_i - match_length - match_start_pos;

                        util.print_bytes(log.debug, "Found initial backref match", bs);
                        log.debug(@src(), "Starting match @{d} [distance to window end: {d}]", .{
                            match_start_pos,
                            dist_to_sliding_window_end,
                        });
                    }
                    else {
                        util.print_bytes(log.warn, "No start position for match", bs);
                    }
                }
                else {
                    // There are no references left for this key in the sliding window, delete it
                    if (!ctx.lookup_table.remove(key)) {
                        util.print_bytes(log.err, "Failed to remove key", bs);
                        return FlateError.InternalError;
                    }
                    util.print_bytes(log.debug, "Deleted key", bs);
                }
            }
        }
    }

    // Finish any in-progress match
    if (maybe_match_start_pos) |match_start_pos| {
        log.debug(@src(), "Ending match due to input EOF @{d}", .{
            match_start_pos + match_length,
        });
        const processed_bytes_i: i32 = @intCast(ctx.cctx.processed_bytes);
        const backref_dist: u16 = @intCast(processed_bytes_i - match_length - match_start_pos);
        try queue_symbol2(
            ctx.cctx,
            @intCast(match_length),
            backref_dist
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

