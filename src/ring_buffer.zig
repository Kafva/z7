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

        pub fn len(self: *@This()) usize {
            if (self.end_index) |end_index| {
                const data_len_i: i32 = @intCast(self.data.len);
                const start_index_i: i32 = @intCast(self.start_index);
                const end_index_i: i32 = @intCast(end_index);

                const numerator = -1*(start_index_i - end_index_i);
                const cnt: usize = @intCast(@mod(numerator, data_len_i)); 
                return cnt;
            } else {
                return 0;
            }
        }

        /// Offset 0 will return the latest item at `end_index`
        /// Offset 1 will return the item one index before `end_index`
        /// etc.
        pub fn read_offset_end(self: *@This(), backward_offset: i32) !T {
            if (self.end_index) |end_index| {
                const length = self.len();
                const data_len_i: i32 = @intCast(self.data.len);
                const end_index_i: i32 = @intCast(end_index);

                if (backward_offset > length) {
                    return RingBufferError.InvalidOffsetRead;
                }

                const offset_start_index_i: i32 = end_index_i - backward_offset;
                const ring_index: usize = @intCast(@mod(offset_start_index_i, data_len_i));

                return self.data[ring_index];
            }
            else {
                return RingBufferError.EmptyRead;
            }
        }

        /// Offset 0 will return the first item at `start_index`
        /// Offset 1 will return the item one index after `start_index`
        /// etc.
        pub fn read_offset_start(self: *@This(), forward_offset: i32) !T {
            if (self.end_index) |_| {
                const length = self.len();
                const data_len_i: i32 = @intCast(self.data.len);
                const start_index_i: i32 = @intCast(self.start_index);

                if (forward_offset > length) {
                    return RingBufferError.InvalidOffsetRead;
                }

                const offset_start_index_i: i32 = start_index_i + forward_offset;
                const ring_index: usize = @intCast(@mod(offset_start_index_i, data_len_i));

                return self.data[ring_index];
            }
            else {
                return RingBufferError.EmptyRead;
            }
        }

        /// Push a new item onto the end of the ring buffer, if the buffer is full,
        /// overwrite the oldest item.
        pub fn push(self: *@This(), item: T) void {
            if (self.end_index) |end_index| {
                self.end_index = (end_index + 1) % self.data.len;

                self.data[self.end_index.?] = item;

                // We overwrote the oldest value, move the start_index forward.
                if (self.end_index.? == self.start_index) {
                    self.start_index += 1;
                    self.start_index %= self.data.len;
                }
            }
            else {
                // First item added
                self.end_index = 0;
                self.data[self.end_index.?] = item;
            }
        }
    };
}
