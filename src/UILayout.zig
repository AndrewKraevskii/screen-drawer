const std = @import("std");
const Color = @import("raylib").Color;
const rl = @import("raylib");

position: [2]f32,
font: f32,
color: Color = .white,

pub fn drawText(self: *@This(), comptime fmt: []const u8, args: anytype) void {
    const buffer_size = 100;
    var buffer: [buffer_size]u8 = undefined;
    const str = std.fmt.bufPrintZ(&buffer, fmt, args) catch blk: {
        buffer[buffer_size - 1] = 0;
        break :blk buffer[0 .. buffer_size - 1 :0];
    };
    rl.drawText(
        str,
        @intFromFloat(self.position[0]),
        @intFromFloat(self.position[1]),
        @intFromFloat(self.font),
        self.color,
    );
    self.position[1] += self.font;
}
