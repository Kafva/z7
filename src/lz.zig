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

const LzItem = struct {
    next: ?u32,
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

const LzContext = struct {
    cctx: *CompressContext,
    start: usize,
    end: usize,
    /// Map from a past 4 byte value in the input stream onto the
    /// next 4 byte value that occured in the input stream
    lookup_table: std.AutoHashMap(u32, LzItem),
    queue: RingBuffer(u32),
    bytes: RingBuffer(u8),
    head_key: ?u32,
};

pub fn lz(cctx: *CompressContext, block_length: usize) !bool {
    // Restriction: Backreferences can not go back more than 32K.
    // Backreferences are allowed to go back into the previous block.
    var ctx = LzContext {
        .cctx = cctx,
        .start = cctx.processed_bytes,
        .end = cctx.processed_bytes + block_length,
        .lookup_table = std.AutoHashMap(u32, LzItem).init(cctx.allocator),
        .queue = try RingBuffer(u32).init(cctx.allocator, Flate.window_length),
        .bytes = try RingBuffer(u8).init(cctx.allocator, Flate.min_length_match),
        .head_key = null,
    };
    var done = false;
    var no_match_cnt: usize = 0; 

    // Read initial 4 bytes to fill up `bytes`
    for (0..4) |_| {
        const b = read_byte(cctx) catch {
            done = true;
            break;
        };
        _ = ctx.bytes.push(b);
    }
    // Save first entry of the lookup table
    try lz_save(&ctx, try bytes_to_u32_key(&ctx));

    while (!done and cctx.processed_bytes < ctx.end) {
        const b = read_byte(cctx) catch {
            done = true;
            break;
        };

        const lit = ctx.bytes.push(b);
        // This literal will never take part in a match, time to queue it as a raw byte
        if (lit) |l| {
            try queue_symbol3(ctx.cctx, l);
        }

        const key = try bytes_to_u32_key(&ctx);

        if (ctx.lookup_table.get(key)) |item| {
            // OK: 'key' is a backreference match
            const match_backward_offset = ctx.cctx.processed_bytes - item.start_pos;
            var match_length = Flate.min_length_match;
            log_u32("Found initial backref match", key);

            // Keep on checking the 'next' pointer until the match ends
            var iter_item: LzItem = item;
            var new_b: ?u8 = null;
            while (iter_item.next) |next| {
                const next_bs = u32_to_bytes(next);
                new_b = read_byte(cctx) catch {
                    done = true;
                    break;
                };

                //const old_lit = ctx.bytes.push(new_b.?);
                _ = ctx.bytes.push(new_b.?);
                const new_key = try bytes_to_u32_key(&ctx);

                // Only the final byte in the 'next' object is actually new
                if (next_bs[3] != new_b.?) {
                    // No match
                    break;
                }
                match_length += 1;
                util.print_char(log.debug, "Extending match", new_b.?);
                new_b = null;

                if (ctx.lookup_table.get(next)) |v| {
                    if (v.next == null) {
                        log_u32("Reached end of sliding window", next);
                    }
                    iter_item = v;
                    // Wait with saving the new key until *after* fetching the next
                    // item, if we actually have a match the value we overwrite
                    // with `lz_save()` will be the next value!
                    try lz_save(&ctx, new_key);
                }
                else {
                    return FlateError.InternalError;
                }
            }

            // OK: insert the match into the write_queue
            try queue_symbol2(
                ctx.cctx,
                @truncate(match_length),
                @truncate(match_backward_offset)
            );

            // Save the final byte that was read but not part of the match
            if (new_b) |c| {
                try lz_save(&ctx, key);
                try queue_symbol3(ctx.cctx, c);
            }

            no_match_cnt = 0;
        }
        else {
            // No match: Save current key into lookup table
            try lz_save(&ctx, key);
        }
    }

    return done;
}

fn bytes_to_u32_key(ctx: *LzContext) !u32 {
    const bs = try ctx.bytes.read_offset_end(Flate.min_length_match - 1, Flate.min_length_match);
    const key = bytes_to_u32(bs);
    return key;
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

fn log_u32(comptime prefix: []const u8, key: u32) void {
    const bs = u32_to_bytes(key);
    var printable = true;
    for (0..4) |i| {
        if (!std.ascii.isPrint(bs[i])) {
            printable = false;
            break;
        }
    }
    if (printable) {
        log.debug(@src(), prefix ++ ": '{c}{c}{c}{c}'", .{
            bs[0], bs[1], bs[2], bs[3]
        });
    }
    else {
        log.debug(@src(), prefix ++ ": {{{d},{d},{d},{d}}}", .{
            bs[0], bs[1], bs[2], bs[3]
        });
    }
}

fn queue_symbol2(
    ctx: *CompressContext,
    match_length: u16,
    match_backward_offset: u16,
) !void {
    if (ctx.write_queue_index + 2 >= Flate.block_length_max) {
        return FlateError.OutOfQueueSpace;
    }

    // Add the length symbol for the back-reference
    const lenc = RangeSymbol.from_length(match_length);
    const lsymbol = FlateSymbol { .length = lenc };
    ctx.write_queue[ctx.write_queue_index] = lsymbol;
    ctx.write_queue_index += 1;
    log.debug(@src(), "Queued length [{d}]: {any}", .{match_length, lenc});

    // Add the distance symbol for the back-reference
    const denc = RangeSymbol.from_distance(match_backward_offset);
    const dsymbol = FlateSymbol { .distance = denc };
    ctx.write_queue[ctx.write_queue_index] = dsymbol;
    ctx.write_queue_index += 1;
    log.debug(@src(), "Queued distance [{d}]: {any}", .{match_backward_offset, denc});
}

fn queue_symbol3(
    ctx: *CompressContext,
    byte: u8,
) !void {
    if (ctx.write_queue_index + 1 >= Flate.block_length_max) {
        return FlateError.OutOfQueueSpace;
    }

    const symbol = FlateSymbol { .char = byte };
    ctx.write_queue[ctx.write_queue_index] = symbol;
    ctx.write_queue_index += 1;
    util.print_char(log.debug, "Queued literal", symbol.char);
}
