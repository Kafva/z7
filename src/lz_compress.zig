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

const max_match_start_pos_count = @divFloor(Flate.lookahead_length, 4);

pub const LzContext = struct {
    /// Pointer back to the main compression context
    cctx: *CompressContext,
    start: usize,
    end: usize,
    sliding_window_min_index: usize,
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
    /// The starting offset(s) in the input stream for this entry
    /// Example:
    ///
    /// [ foo1 foo2 aaaa aaaa foo3 foo4 aaaa aaaa aaaa ]
    ///
    /// =>
    ///
    /// 'foo1' -> { start_indices: [0] }
    /// 'foo2' -> { start_indices: [4] }
    /// 'aaaa' -> { start_indices: [32,28,24,16,8,-1,-1...] }
    /// 'aaaa' -> { start_indices: [-1,-1,...,8,16,24,28,32] }
    /// 'foo3' -> { start_indices: [16] }
    /// 'foo4' -> { start_indices: [20] }
    ///
    /// Prune everything that only has a start_indices behind the sliding window
    start_indices: [max_match_start_pos_count]i32,
    start_indices_cnt: usize,

    pub fn init(start_indices: usize) @This() {
        var item = LzItem {
            .start_indices = [_]i32{-1}**max_match_start_pos_count,
            .start_indices_cnt = 1,
        };
        item.start_indices[max_match_start_pos_count - 1] = @intCast(start_indices);
        return item;
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

    /// Remove all starting positions below the `low_limit`
    pub fn prune(self: *@This(), low_limit: usize) void {
        const idx = max_match_start_pos_count - self.start_indices_cnt;
        for (idx..self.start_indices.len) |i| {
            if (self.start_indices[i] != -1 and self.start_indices[i] < low_limit) {
                log.debug(@src(), "Pruning start index: {d}", .{self.start_indices[i]});
                self.start_indices[i] = -1;
            }
        }
        std.sort.insertion(i32, self.start_indices[idx..], {}, std.sort.asc(i32));
    }

    pub fn add(self: *@This(), new_start_pos: i32) void {
        if (self.start_indices_cnt == self.start_indices.len) {
            // Keep overwriting the newest value
            self.start_indices[self.start_indices_cnt - 1] = @intCast(new_start_pos);
        }
        else {
            // Insert at tail of array and keep it sorted in ascending order
            self.start_indices[self.start_indices_cnt] = @intCast(new_start_pos);
            self.start_indices_cnt += 1;
            std.sort.insertion(i32, self.start_indices[0..self.start_indices_cnt], {}, std.sort.asc(i32));
        }
    }

    pub fn best_start_pos(self: @This()) ?i32 {
        if (self.start_indices_cnt == 0) {
            return null;
        }
        // Always take the oldest match (furthest to the front)
        const idx = max_match_start_pos_count - self.start_indices_cnt;
        const oldest_value = self.start_indices[idx];
        if (oldest_value < 0) {
            return null;
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
    ctx.sliding_window_min_index = ctx.start;
    ctx.sliding_window_index = ctx.start;

    while (!done and ctx.cctx.processed_bytes < ctx.end) {
        // Read next byte for lookahead
        const b = read_byte(ctx.cctx) catch {
            done = true;
            break;
        };

        if (ctx.sliding_window.count() == Flate.window_length) {
            // Slide the window forward once we reach the end of the first section.
            ctx.sliding_window_min_index += 1;
            log.debug(@src(), "Bumped window index {d}", .{ctx.sliding_window_min_index});
        }

        const old = ctx.lookahead.push(b);

        if (ctx.lookahead.count() != Flate.min_length_match) {
            // We have not filled the lookahead yet, go again
            continue;
        }

        if (old) |old_b| {
            // Queue each byte that exits the lookahead onto the sliding window
            _ = ctx.sliding_window.push(old_b);
            ctx.sliding_window_index += 1;
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
                    if (ctx.lookahead.prune(1)) |l| {
                        _ = ctx.sliding_window.push(l);
                        ctx.sliding_window_index += 1;
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
            // Look for new match
            const bs = try ctx.lookahead.read_offset_end(3, 4);
            const key = bytes_to_u32(bs);

            if (ctx.lookup_table.getPtr(key)) |ptr| { // New match
                // Remove start positions past the sliding window,
                // this could cause us to no longer have a match!
                ptr.prune(ctx.sliding_window_min_index);
                maybe_match_start_pos = ptr.best_start_pos();

                if (maybe_match_start_pos) |match_start_pos| {
                    match_start_window_pos = @intCast(ctx.sliding_window.count());
                    match_length = @intCast(Flate.min_length_match);
                    util.print_bytes("Found initial backref match", u32_to_bytes(key));
                    log.debug(@src(), "Starting match @{d} [window @{d}]", .{
                        match_start_pos,
                        ctx.sliding_window.count(),
                    });
                }
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

