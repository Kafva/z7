const std = @import("std");
const log = @import("log.zig");
const util = @import("util.zig");

const Flate = @import("flate.zig").Flate;
const FlateError = @import("flate.zig").FlateError;
const FlateSymbol = @import("flate.zig").FlateSymbol;
const RangeSymbol = @import("flate.zig").RangeSymbol;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;
const FlateCompressMode = @import("flate_compress.zig").FlateCompressMode;
const CompressContext = @import("flate_compress.zig").CompressContext;

pub const LzContext = struct {
    /// Pointer back to the main compression context
    cctx: *CompressContext,
    reader: std.io.AnyReader,
    /// The *total* number of bytes processed into the sliding window
    processed_bytes_sliding_window: i32,
    /// Starting position of a backref match relative to the start of the input stream
    maybe_match_start_pos: ?i32,
    /// Length of current match
    match_length: i32,
    /// Backreference distance of current match
    /// * can not go back more than 32K
    /// * allowed to go back into the previous block
    match_distance: i32,
    maybe_sliding_window_min_index: ?usize,
    sliding_window: RingBuffer(u8),
    /// Map from a 4 byte value in the input stream onto an array
    /// of starting positions in the sliding window where that
    /// input sequence occurs.
    lookup_table: std.AutoHashMap(u32, LzItem),
    /// 4 byte lookahead
    lookahead: RingBuffer(u8),
    /// Sum of all match lengths
    backref_lengths_sum: usize,
    /// Number of back reference matches encountered
    backref_total_count: usize,

    pub fn backref_average_length(self: @This()) usize {
        if (self.backref_total_count == 0)
            return 0;
        return @divFloor(self.backref_lengths_sum, self.backref_total_count);
    }
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
        // first occurrence of 'aaaa'.
        const idx = LzItem.start_indices_max - self.start_indices_cnt;
        const oldest_value = self.start_indices[idx];
        if (oldest_value < 0) {
            return null;
        }
        return @intCast(oldest_value);
    }
};

pub fn lz_compress(ctx: *LzContext) !bool {
    var done = false;
    const end: usize = ctx.cctx.processed_bytes + ctx.cctx.block_length;

    // Slack space to able to fill out with left-over bytes
    while (!done and ctx.cctx.processed_bytes < end - 4) {
        // Read next byte for lookahead
        const b = read_byte(ctx.cctx) catch {
            done = true;
            break;
        };

        const maybe_old = ctx.lookahead.push(b);

        if (ctx.lookahead.count != Flate.min_length_match) {
            // We have not filled the lookahead yet, go again
            continue;
        }

        if (maybe_old) |old| {
            // Queue each byte that exits the lookahead onto the sliding window
            try sliding_window_push(ctx, old);
        }

        if (ctx.cctx.mode == FlateCompressMode.NO_COMPRESSION) {
            // No need to check for back references
            continue;
        }

        if (ctx.maybe_match_start_pos) |match_start_pos| {
            // Handle match in progress

            // The backward offset will be the initial distance to the match from where
            // the window was when the match started excluding the match length.
            // This distance remains the same since we are adding bytes to the window
            // as we go (at the same time as we increase the match length)
            const backward_offset: i32 = ctx.match_distance - 4;
            const bs = try ctx.sliding_window.read_offset_end_fixed(backward_offset, 1);

            if (ctx.match_length == ctx.match_distance or          // Reached the end of the window
                ctx.match_length + 1 == Flate.lookahead_length or  // Maximum length match
                bs[0] != b                                         // Backref no longer matches
            ) {
                // End match!
                log.debug(@src(), "Ending match @{d}", .{match_start_pos + ctx.match_length});
                try queue_push_range(
                    ctx.cctx,
                    @intCast(ctx.match_length),
                    @intCast(ctx.match_distance),
                );
                ctx.backref_total_count += 1;
                ctx.backref_lengths_sum += @intCast(ctx.match_length);

                ctx.maybe_match_start_pos = null;

                // Everything in the lookahead except the final byte was made part of the backref
                for (0..3) |_| {
                    if (ctx.lookahead.prune(1)) |l| {
                        try sliding_window_push(ctx, l);
                    }
                }
            }
            else {
                // Extend match!
                util.print_char(log.trace, "Extending match", b);
                ctx.match_length += 1;
            }
        }
        else {
            // Queue the dropped byte as a raw literal
            if (maybe_old) |old|  {
                if (ctx.cctx.mode != FlateCompressMode.NO_COMPRESSION) {
                    try queue_push_char(ctx.cctx, old);
                }
            }

            // Look for new match
            const bs = try ctx.lookahead.read_offset_end_fixed(3, 4);
            const key = bytes_to_u32(bs);

            if (ctx.lookup_table.getPtr(key)) |ptr| {
                // New match: Save the distance and length and continue the match

                // Remove start positions past the sliding window
                if (ctx.maybe_sliding_window_min_index) |sliding_window_min_index| {
                    ptr.prune(sliding_window_min_index);
                }

                if (ptr.start_indices_cnt > 0) {
                    // There was a match, but it may have been outside the sliding window
                    ctx.maybe_match_start_pos = ptr.best_start_pos();
                    if (ctx.maybe_match_start_pos) |match_start_pos| {
                        ctx.match_length = @intCast(Flate.min_length_match);
                        if (match_start_pos > ctx.processed_bytes_sliding_window) {
                            log.err(@src(), "Invalid backreference position: @{d} [sliding window @{d}]", .{
                                match_start_pos,
                                ctx.processed_bytes_sliding_window,
                            });
                            return FlateError.InternalError;
                        }
                        ctx.match_distance = ctx.processed_bytes_sliding_window - match_start_pos;

                        util.print_bytes(log.debug, "Found initial backref match", bs);
                        log.debug(@src(), "Starting match @{d} [sliding window @{d}]", .{
                            match_start_pos,
                            ctx.processed_bytes_sliding_window,
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
    if (ctx.maybe_match_start_pos) |_| {
        log.debug(@src(), "Ending match due to input EOB/EOF @{d}", .{
            ctx.processed_bytes_sliding_window,
        });

        try queue_push_range(
            ctx.cctx,
            @intCast(ctx.match_length),
            @intCast(ctx.match_distance),
        );
        ctx.backref_total_count += 1;
        ctx.backref_lengths_sum += @intCast(ctx.match_length);
        ctx.maybe_match_start_pos = null;

        // We can only get into this branch if we were extending a match
        // in the last iteration, in that case, the entire lookahead was
        // part of the match.
        while (ctx.lookahead.prune(1)) |lit| {
            try sliding_window_push(ctx, lit);
        }
    }

    // Queue up any left over literals as-is
    if (ctx.lookahead.count > 0) {
        log.debug(@src(), "Appending left-over lookahead bytes", .{});

        while (ctx.lookahead.prune(1)) |lit| {
            try sliding_window_push(ctx, lit);
            if (ctx.cctx.mode != FlateCompressMode.NO_COMPRESSION) {
                try queue_push_char(ctx.cctx, lit);
            }
        }
    }

    // Fill up the desired block length with raw bytes once the lookahead
    // is empty if necessary
    if (!done and ctx.cctx.processed_bytes < end) {
        log.debug(@src(), "Appending {d} byte(s) to reach EOB", .{
            end - ctx.cctx.processed_bytes,
        });
    }
    while (!done and ctx.cctx.processed_bytes < end) {
        const b = read_byte(ctx.cctx) catch {
            done = true;
            break;
        };
        try sliding_window_push(ctx, b);
        if (ctx.cctx.mode != FlateCompressMode.NO_COMPRESSION) {
            try queue_push_char(ctx.cctx, b);
        }
    }

    return done;
}

fn sliding_window_push(ctx: *LzContext, b: u8) !void {
    _ = ctx.sliding_window.push(b);
    ctx.processed_bytes_sliding_window += 1;

    // Save for NO_COMPRESSION queue
    try raw_queue_push_char(ctx.cctx, b);

    if (ctx.cctx.mode != FlateCompressMode.NO_COMPRESSION and ctx.sliding_window.count >= 4) {
        // Add a lookup entry for the byte that was dropped into the lookahead
        // (no need to maintain lookup table for NO_COMPRESSION mode
        const window_bs = try ctx.sliding_window.read_offset_end_fixed(3, 4);
        const window_key = bytes_to_u32(window_bs);
        // The global start index of the match in the input stream!
        const start_idx = ctx.processed_bytes_sliding_window - 4;

        if (ctx.lookup_table.getPtr(window_key)) |ptr| {
            // Update key with new start position
            ptr.add(@intCast(start_idx));
        }
        else {
            // Save the 'key' -> 'LzItem' map
            try ctx.lookup_table.put(window_key, LzItem.init(@intCast(start_idx)));
        }
    }

    if (ctx.sliding_window.count == Flate.window_length) {
        // Once the sliding window is filled, slide it one byte forward every iteration
        ctx.maybe_sliding_window_min_index =
            if (ctx.maybe_sliding_window_min_index) |s| s + 1 else 1;
    }
}

fn queue_push_range(
    ctx: *CompressContext,
    match_length: u16,
    match_backward_offset: u16,
) !void {
    if (ctx.write_queue_count + 2 > ctx.write_queue.len) {
        return FlateError.OutOfQueueSpace;
    }

    // Add the length symbol for the back-reference
    const lenc = try RangeSymbol.from_length(match_length);
    const lsymbol = FlateSymbol {
        .value = .{
            .range = .{
                .value = match_length,
                .sym = lenc,
            },
        },
        .typing = .LENGTH,
    };
    ctx.write_queue[ctx.write_queue_count] = lsymbol;
    ctx.write_queue_count += 1;
    log.debug(@src(), "Queued length [{d}]: {any}", .{match_length, lenc});

    // Add the distance symbol for the back-reference
    const denc = try RangeSymbol.from_distance(match_backward_offset);
    const dsymbol = FlateSymbol {
        .value = .{
            .range = .{
                .value = match_backward_offset,
                .sym = denc,
            },
        },
        .typing = .DISTANCE,
    };
    ctx.write_queue[ctx.write_queue_count] = dsymbol;
    ctx.write_queue_count += 1;
    log.debug(@src(), "Queued distance [{d}]: {any}", .{match_backward_offset, denc});
}

fn queue_push_char(
    ctx: *CompressContext,
    byte: u8,
) !void {
    if (ctx.write_queue_count + 1 > ctx.write_queue.len) {
        return FlateError.OutOfQueueSpace;
    }

    const symbol = FlateSymbol {
        .value = .{ .char = byte },
        .typing = .LITERAL,
    };
    ctx.write_queue[ctx.write_queue_count] = symbol;
    ctx.write_queue_count += 1;
    util.print_char(log.debug, "Queued literal", byte);
}

/// Save for NO_COMPRESSION queue
fn raw_queue_push_char(
    ctx: *CompressContext,
    byte: u8,
) !void {
    if (ctx.block_length > Flate.no_compression_block_length_max) {
        // The block length is too large for NO_COMPRESSION, skip
        return;
    }
    if (ctx.write_queue_raw_count + 1 > ctx.write_queue_raw.len) {
        return FlateError.OutOfQueueSpace;
    }

    ctx.write_queue_raw[ctx.write_queue_raw_count] = byte;
    ctx.write_queue_raw_count += 1;
}

fn read_byte(ctx: *CompressContext) !u8 {
    const b = try ctx.lz.reader.readByte();
    util.print_char(log.trace, "Input read", b);
    ctx.processed_bytes += 1;

    // The final crc should be the crc of the entire input file, update
    // it incrementally as we process each byte.
    const bytearr = [1]u8 { b };
    ctx.crc.update(&bytearr);

    if (ctx.progress) {
        if (ctx.maybe_inputfile_size) |inputfile_size| {
            try util.progress("Compressing...  ", ctx.processed_bytes, inputfile_size);
        }
    }

    return b;
}

fn bytes_to_u32(bs: [4]u8) u32 {
    return @as(u32, bs[0]) << 24 |
           @as(u32, bs[1]) << 16 |
           @as(u32, bs[2]) << 8 |
           @as(u32, bs[3]);
}
