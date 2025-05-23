const std = @import("std");
const log = @import("log.zig");
const is_test = @import("builtin").is_test;

pub const RingBufferError = error {
    InvalidOffsetRead,
    EmptyRead,
};

pub fn RingBuffer(comptime T: type) type {
    return struct {
        data: []T,
        /// The oldest value is at this index (head)
        start_index: i32 = 0,
        /// The newest value is at this index (tail), set to `null` when the
        /// buffer is empty.
        maybe_end_index: ?i32 = null,
        /// Keep the data size as signed integer to simplify type conversions
        capacity: i32,
        /// The number of items currently in the ring buffer
        count: usize,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !@This() {
            return @This() {
                .data = try allocator.alloc(T, capacity),
                .capacity = @intCast(capacity),
                .count = 0,
                .start_index = 0,
                .maybe_end_index = null,
            };
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
            if (self.maybe_end_index) |end_index| {
                return writer.print(
                    "{{ .start_index = {d}, .end_index = {d}, .count = {d} .capacity = {d}, .data = {any} }}",
                    .{ self.start_index, end_index, self.count, self.capacity, self.data}
                );
            }
            else {
                return writer.print(
                    "{{ .start_index = {d}, .count = {d} .capacity = {d}, .data = {any} }}",
                    .{ self.start_index, self.count, self.capacity, self.data}
                );
            }
        }

        fn get_start_offset_end(
            self: *@This(),
            backward_offset: i32,
            ret_count: usize,
        ) !i32 {
            const cnt: i32 = @intCast(self.count);
            if (cnt > 0 and self.maybe_end_index != null) {
                if (backward_offset > cnt - 1 or ret_count > cnt) {
                    if (!is_test) {
                        log.err(
                            @src(),
                            "Attempting to read {d} item(s) from backward offset {d} with {d} items",
                            .{ret_count, backward_offset, cnt}
                        );
                    }
                    return RingBufferError.InvalidOffsetRead;
                }

                return @intCast(self.maybe_end_index.? - backward_offset);
            }

            return RingBufferError.EmptyRead;
        }

        /// Offset 0 will return the latest item at `end_index`
        /// Offset 1 will return the item one index before `end_index`
        /// With `ret_count=2`, Offset 1 would return [end_index - 1..end_index] inclusive.
        pub fn read_offset_end_fixed(
            self: *@This(),
            backward_offset: i32,
            comptime ret_count: usize,
        ) ![ret_count]T {
            const offset_start: i32 = try self.get_start_offset_end(backward_offset, ret_count);
            var arr = [_]T{0} ** ret_count;
            self.populate_array(&arr, offset_start, ret_count);
            return arr;
        }

        /// Push a new item onto the end of the ring buffer, if the buffer is full,
        /// overwrite the oldest item.
        pub fn push(self: *@This(), item: T) ?T {
            if (self.maybe_end_index) |end_index| {
                self.maybe_end_index = @mod(end_index + 1, self.capacity);

                const new_end_index: usize = @intCast(self.maybe_end_index.?);
                const old = self.data[new_end_index];
                self.data[new_end_index] = item;

                // We overwrote the oldest value, move the start_index forward.
                if (new_end_index == self.start_index) {
                    self.start_index = @mod(self.start_index + 1, self.capacity);
                    return old;
                }
            }
            else {
                // First item added
                self.maybe_end_index = 0;
                self.data[@intCast(self.maybe_end_index.?)] = item;
            }

            if (self.count < self.capacity) self.count += 1;
            return null;
        }

        /// Drop the `prune_cnt` oldest value from the buffer, moving the
        /// `start_index` closer to the `end_index`.
        /// Returns the oldest value that was pruned.
        pub fn prune(self: *@This(), prune_cnt: i32) ?T {
            const cnt: i32 = @intCast(self.count);
            if (cnt > 0 and cnt >= prune_cnt and self.maybe_end_index != null) {
                const item = self.data[@intCast(self.start_index)];
                self.start_index = @mod(self.start_index + prune_cnt, self.capacity);

                self.count = @intCast(cnt - prune_cnt);
                if (self.count == 0) {
                    // Reset to original state when emptied
                    self.start_index = 0;
                    self.maybe_end_index = null;
                }
                return item;
            }
            else {
                return null;
            }
        }

        fn populate_array(
            self: *@This(),
            arr: []T,
            offset_start: i32,
            ret_count: usize,
        ) void {
            for (0..ret_count) |i_usize| {
                const i: i32 = @intCast(i_usize);
                const ret_i: usize = @intCast(@mod(offset_start + i, self.capacity));
                arr[i_usize] = self.data[ret_i];
            }
        }
    };
}
