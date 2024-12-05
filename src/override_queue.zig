const std = @import("std");

// Data Structure what supports only add operation and overwrite oldest element if overflows.

pub fn OverrideQueue(comptime T: type, comptime size: usize) type {
    return struct {
        buf: [size]T,
        count: usize,
        head: usize,

        pub const empty: @This() = .{ .buf = undefined, .count = 0, .head = 0 };

        pub fn add(self: *@This(), value: T) void {
            std.debug.assert(self.count <= self.buf.len);
            if (self.count < self.buf.len) {
                self.count += 1;
                self.buf[(self.head + self.count) % size] = value;
            } else {
                self.buf[self.head] = value;
                self.head = (self.head + 1) % self.buf.len;
            }
        }

        pub fn slice(self: *@This()) []T {
            return self.buf[0..self.count];
        }

        pub fn orderedSlices(self: *@This()) struct { []T, []T } {
            std.debug.assert(self.head == 0 or self.count == self.buf.len);
            return .{
                self.buf[self.head..self.count],
                self.buf[0..self.head],
            };
        }
    };
}
