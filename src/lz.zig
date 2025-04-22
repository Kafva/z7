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
    /// Map from a past 4 byte value in the input stream onto the
    /// next 4 byte value that occured in the input stream
    lookup_table: std.AutoHashMap(u32, LzItem),
    /// Queue of all 4 byte tuples in the input stream, we maintain
    /// this array so that we know how to retire the oldest value
    /// from the `lookup_table` when neccessary.
    queue: RingBuffer(u32),
    lookahead: RingBuffer(u8),
    head_key: ?u32,
};

pub const LzItem = struct {
    /// Pointer in teh lookup table to the next item
    /// E.g. ' Huff' -> 'Huff' -> 'uffm'
    next: ?u32,
    /// The starting offset in the input stream for this entry
    start_pos: usize,

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
            // Found match: Queue it into the write queue
            done = try lz_queue_match(ctx, key, item);
        }
        else {
            // No match: Save current key into lookup table
            try lz_save(ctx, key);
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
    const match_backward_offset = ctx.cctx.processed_bytes - item.start_pos;
    var match_length = Flate.min_length_match;
    var iter_item: LzItem = item;
    var new_b: ?u8 = null;
    var done = false;

    util.print_bytes("Found initial backref match", u32_to_bytes(key));

    // Keep on checking the 'next' pointer until the match ends
    while (iter_item.next) |next| {
        const next_bs = u32_to_bytes(next);
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

        // Only the final byte in the 'next' object is actually new
        if (next_bs[3] != new_b.?) {
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

        // Wait with saving the new key until *after* fetching the next
        // item, if we actually have a match the value we overwrite
        // with `lz_save()` will be the next value!
        try lz_save(ctx, new_key);
    }

    // Insert the match into the write_queue
    try queue_symbol2(
        ctx.cctx,
        @truncate(match_length),
        @truncate(match_backward_offset)
    );

    // Everything currently in `lookahead` except the final byte was
    // part of the backreference, clear out these values.
    const prune_cnt: usize = if (new_b != null) 3 else 4;
    _ = ctx.lookahead.prune(prune_cnt);

    return done;
}

fn lz_save(ctx: *LzContext, key: u32) !void {
    // Push the new u32 key into the queue
    const delkey = ctx.queue.push(key);
    if (delkey) |k| {
        // Delete oldest key if necessary
        if (!ctx.lookup_table.remove(k)) {
            log.err(@src(), "Failed to remove key: {d}", .{k});
            return FlateError.InternalError;
        }
    }

    // Create the value for the new 'key', this is the newest
    // entry so no 'next' value yet.
    const lzitem = LzItem {
        .next = null,
        .start_pos = ctx.cctx.processed_bytes - ctx.start,
    };

    if (ctx.head_key) |head| {
        // Overwrite the 'next' field of the current head to point to
        // the new entry.
        const head_item = ctx.lookup_table.get(head);
        const new_head = LzItem {
            .next = key,
            .start_pos = head_item.?.start_pos,
        };
        try ctx.lookup_table.put(head, new_head);
    }

    // Insert the new value
    try ctx.lookup_table.put(key, lzitem);

    // Repoint head to the new entry
    ctx.head_key = key;
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

