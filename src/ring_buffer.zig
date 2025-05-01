const std = @import("std");
const log = @import("log.zig");

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

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !@This() {
            return @This() {
                .data = try allocator.alloc(T, capacity),
                .capacity = @intCast(capacity),
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
                    .{ self.start_index, end_index, self.count(), self.capacity, self.data}
                );
            }
            else {
                return writer.print(
                    "{{ .start_index = {d}, .count = {d} .capacity = {d}, .data = {any} }}",
                    .{ self.start_index, self.count(), self.capacity, self.data}
                );
            }
        }

        /// The number of items currently in the ring buffer
        pub fn count(self: @This()) usize {
            if (self.maybe_end_index) |end_index| {
                const diff = -1*(self.start_index - end_index);
                // +1 for the count
                return @intCast(@mod(diff, self.capacity) + 1); 
            } else {
                return 0;
            }
        }

        /// Return the internal index in the ring buffer `backward_offset` steps
        /// backwards.
        pub fn index_offset_end(self: @This(), backward_offset: i32) !usize {
            const cnt: i32 = @intCast(self.count());
            if (cnt > 0 and self.maybe_end_index != null) {
                if (backward_offset > cnt - 1) {
                    log.err(@src(), "Attempting to retrieve index for backward offset {d} with {d} items", .{
                        backward_offset,
                        cnt,
                    });
                    return RingBufferError.InvalidOffsetRead;
                }

                const offset_index: i32 = @mod(self.maybe_end_index.? - backward_offset, self.capacity);
                return @intCast(offset_index);
            }

            return RingBufferError.EmptyRead;

        }

        /// Offset 0 will return the latest item at `end_index`
        /// Offset 1 will return the item one index before `end_index`
        /// With `ret_count=2`, Offset 1 would return [end_index - 1..end_index] inclusive.
        pub fn read_offset_end(
            self: *@This(),
            backward_offset: i32,
            comptime ret_count: usize,
        ) ![ret_count]T {
            const cnt: i32 = @intCast(self.count());
            if (cnt > 0 and self.maybe_end_index != null) {
                if (backward_offset > cnt - 1 or ret_count > cnt) {
                    log.err(@src(), "Attempting to read from backward offset {d} with {d} items", .{
                        backward_offset,
                        cnt,
                    });
                    return RingBufferError.InvalidOffsetRead;
                }

                const offset_start: i32 = self.maybe_end_index.? - backward_offset;
                return self.return_array(offset_start, ret_count);
            }

            return RingBufferError.EmptyRead;
        }

        /// Offset 0 will return the first item at `start_index`
        /// Offset 1 will return the item one index after `start_index`
        /// With `ret_count=2`, Offset 1 would return [start_index..start_index + 1] inclusive.
        pub fn read_offset_start(
            self: *@This(),
            forward_offset: i32,
            comptime ret_count: usize,
        ) ![ret_count]T {
            const cnt: i32 = @intCast(self.count());
            if (cnt > 0 and self.maybe_end_index != null) {
                if (forward_offset > cnt - 1 or ret_count > cnt) {
                    log.err(@src(), "Attempting to read from forward offset {d} with {d} items", .{
                        forward_offset,
                        cnt,
                    });
                    return RingBufferError.InvalidOffsetRead;
                }

                const offset_start: i32 = self.start_index + forward_offset;
                return self.return_array(offset_start, ret_count);
            }

            return RingBufferError.EmptyRead;
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

            return null;
        }

        /// Drop the `prune_cnt` oldest value from the buffer, moving the
        /// `start_index` closer to the `end_index`.
        /// Returns the oldest value that was pruned.
        pub fn prune(self: *@This(), prune_cnt: i32) ?T {
            const cnt: i32 = @intCast(self.count());
            if (cnt > 0 and cnt >= prune_cnt and self.maybe_end_index != null) {
                const item = self.data[@intCast(self.start_index)];
                self.start_index = @mod(self.start_index + prune_cnt, self.capacity);

                if (cnt - prune_cnt == 0) {
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

        fn return_array(
            self: *@This(),
            offset_start: i32,
            comptime ret_count: usize,
        ) ![ret_count]T {
            var r = [_]T{0}**ret_count;
            for (0..ret_count) |i_usize| {
                const i: i32 = @intCast(i_usize);
                const ret_i: usize = @intCast(@mod(offset_start + i, self.capacity));
                r[i_usize] = self.data[ret_i];
            }
            return r;
        }
    };
}
