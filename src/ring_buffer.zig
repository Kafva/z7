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
        /// The newest value is at this index (tail), `null` when the buffer is
        /// empty.
        end_index: ?usize = null,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !@This() {
            return @This() {
                .data = try allocator.alloc(T, capacity),
                .start_index = 0,
                .end_index = null,
            };
        }

        /// Offset 0 will return the latest item at `end_index`
        /// Offset 1 will return the item one index before `end_index`
        /// XXX: no read outside bounds check!
        pub fn read(self: *@This(), backward_offset: i64) !T {
            if (self.end_index) |end_index| {
                const data_len_i: i64 = @intCast(self.data.len);
                const end_index_i: i64 = @intCast(end_index);
                const offset_start_index_i: i64 = end_index_i - backward_offset;

                const denominator: usize = @intCast(data_len_i + offset_start_index_i);
                const ring_index: usize = denominator % self.data.len;

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
