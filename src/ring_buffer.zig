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
        start_index: usize = 0,
        /// The newest value is at this index (tail), set to `null` when the 
        /// buffer is empty.
        end_index: ?usize = null,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !@This() {
            return @This() {
                .data = try allocator.alloc(T, capacity),
                .start_index = 0,
                .end_index = null,
            };
        }

        /// The number of items currently in the ring buffer
        pub fn count(self: @This()) usize {
            if (self.end_index) |end_index| {
                const data_len_i: i32 = @intCast(self.data.len);
                const start_index_i: i32 = @intCast(self.start_index);
                const end_index_i: i32 = @intCast(end_index);

                const diff = -1*(start_index_i - (end_index_i));
                // +1 for the count
                return @intCast(@mod(diff, data_len_i) + 1); 
            } else {
                return 0;
            }
        }

        /// Offset 0 will return the latest item at `end_index`
        /// Offset 1 will return the item one index before `end_index`
        /// With `ret_count=2`, Offset 1 would return [end_index - 1..end_index] inclusive.
        pub fn read_offset_end(
            self: *@This(),
            backward_offset: i32,
            comptime ret_count: usize,
        ) ![ret_count]T {
            const cnt = self.count();
            if (cnt > 0 and self.end_index != null) {
                const data_len_i: i32 = @intCast(self.data.len);
                const end_index_i: i32 = @intCast(self.end_index.?);

                if (backward_offset > cnt - 1 or ret_count > cnt) {
                    return RingBufferError.InvalidOffsetRead;
                }

                const offset_start_i: i32 = end_index_i - backward_offset;

                var r = [_]T{0}**ret_count;
                for (0..ret_count) |i| {
                    const i_i: i32 = @intCast(i);
                    const ri: usize = @intCast(@mod(offset_start_i + i_i, data_len_i));
                    r[i] = self.data[ri];
                }
                return r;
            }

            return RingBufferError.EmptyRead;
        }

        /// Offset 0 will return the first item at `start_index`
        /// Offset 1 will return the item one index after `start_index`
        /// etc.
        pub fn read_offset_start(self: *@This(), forward_offset: i32) !T {
            const cnt = self.count();
            if (cnt > 0 and self.end_index != null) {
                const data_len_i: i32 = @intCast(self.data.len);
                const start_index_i: i32 = @intCast(self.start_index);

                if (forward_offset > cnt - 1) {
                    return RingBufferError.InvalidOffsetRead;
                }

                const offset_start_i: i32 = start_index_i + forward_offset;
                const ring_index: usize = @intCast(@mod(offset_start_i, data_len_i));

                return self.data[ring_index];
            }

            return RingBufferError.EmptyRead;
        }

        /// Push a new item onto the end of the ring buffer, if the buffer is full,
        /// overwrite the oldest item.
        pub fn push(self: *@This(), item: T) ?T {
            if (self.end_index) |end_index| {
                self.end_index = (end_index + 1) % self.data.len;

                const old = self.data[self.end_index.?];
                self.data[self.end_index.?] = item;

                // We overwrote the oldest value, move the start_index forward.
                if (self.end_index.? == self.start_index) {
                    self.start_index += 1;
                    self.start_index %= self.data.len;
                    return old;
                }
            }
            else {
                // First item added
                self.end_index = 0;
                self.data[self.end_index.?] = item;
            }

            return null;
        }
    };
}
