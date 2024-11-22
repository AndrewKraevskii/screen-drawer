//! Contains data required for single canvas entry.

const std = @import("std");

const rl = @import("raylib");
const tracy = @import("tracy");

const HistoryStorage = @import("history.zig").History;
const main = @import("main.zig");
const config = main.config;

const Canvas = @This();

pub const History = HistoryStorage(EventTypes);

const EventTypes = union(enum) {
    drawn: usize,
    erased: usize,

    pub fn redo(event: EventTypes, canvas: *Canvas) void {
        tracy.message("redo");
        switch (event) {
            .drawn => |index| canvas.strokes.items[index].is_active = true,
            .erased => |index| canvas.strokes.items[index].is_active = false,
        }
    }
    pub fn undo(event: EventTypes, canvas: *Canvas) void {
        tracy.message("undo");
        switch (event) {
            .erased => |index| canvas.strokes.items[index].is_active = true,
            .drawn => |index| canvas.strokes.items[index].is_active = false,
        }
    }
};

const Stroke = struct {
    is_active: bool = true,
    span: Span,
    color: rl.Color,
};

const Span = struct {
    start: u64,
    size: u64,
};

strokes: std.ArrayListUnmanaged(Stroke) = .{},
segments: std.ArrayListUnmanaged(rl.Vector2) = .{},
history: History = .{},

pub fn startStroke(
    canvas: *@This(),
    gpa: std.mem.Allocator,
    color: rl.Color,
) error{OutOfMemory}!void {
    try canvas.history.addHistoryEntry(gpa, .{ .drawn = canvas.strokes.items.len });

    try canvas.strokes.append(gpa, .{ .span = .{
        .start = canvas.segments.items.len,
        .size = 0,
    }, .color = color });
}

pub fn addStrokePoint(canvas: *@This(), gpa: std.mem.Allocator, pos: rl.Vector2) error{OutOfMemory}!void {
    std.debug.assert(canvas.strokes.items.len != 0);
    // if previous segment is to small update it instead of adding new.
    const min_distance = 10;
    const min_distance_squared = min_distance * min_distance;
    if (canvas.strokes.items[canvas.strokes.items.len - 1].span.size >= 1 and canvas.segments.items.len >= 2) {
        const start = canvas.segments.items[canvas.segments.items.len - 2];
        const end = &canvas.segments.items[canvas.segments.items.len - 1];
        if (start.distanceSqr(end.*) < min_distance_squared) {
            end.* = pos;
            return;
        }
    }

    // add new stroke point
    canvas.strokes.items[canvas.strokes.items.len - 1].span.size += 1;

    try canvas.segments.append(
        gpa,
        pos,
    );
}

pub fn erase(canvas: *@This(), gpa: std.mem.Allocator, start: rl.Vector2, end: rl.Vector2, radius: f32) error{OutOfMemory}!void {
    for (canvas.strokes.items, 0..) |*stroke, index| {
        if (stroke.is_active) {
            var iter = std.mem.window(
                rl.Vector2,
                canvas.segments.items[stroke.span.start..][0..stroke.span.size],
                2,
                1,
            );
            while (iter.next()) |line| {
                if (line.len == 0) continue;
                const line_intersects_cursor, const line_intersects_cursor_line = if (line.len > 1) blk: {
                    const line_intersects_cursor = rl.checkCollisionCircleLine(end, radius, line[0], line[1]);
                    var collision_point: rl.Vector2 = undefined;
                    const line_intersects_cursor_line = rl.checkCollisionLines(end, start, line[0], line[1], &collision_point);
                    break :blk .{ line_intersects_cursor, line_intersects_cursor_line };
                } else blk: {
                    const line_intersects_cursor = rl.checkCollisionPointCircle(line[0], end, radius);
                    const line_intersects_cursor_line = rl.checkCollisionPointLine(line[0], end, start, config.eraser_thickness);
                    break :blk .{ line_intersects_cursor, line_intersects_cursor_line };
                };

                if (line_intersects_cursor or line_intersects_cursor_line) {
                    try canvas.history.addHistoryEntry(gpa, .{ .erased = index });
                    stroke.is_active = false;
                    break;
                }
            }
        }
    }
}

pub fn save(canvas: *Canvas, writer: anytype) !void {
    const zone = tracy.initZone(@src(), .{});
    defer zone.deinit();

    try writer.writeAll(config.save_format_magic); // magic
    inline for (.{ "segments", "strokes" }) |field| {
        try writer.writeInt(u64, @field(canvas, field).items.len, .little);
        try writer.writeAll(std.mem.sliceAsBytes(@field(canvas, field).items));
    }
    try writer.writeInt(u64, canvas.history.events.items.len, .little);
    try writer.writeAll(std.mem.sliceAsBytes(canvas.history.events.items));
}

pub fn load(gpa: std.mem.Allocator, reader: anytype) !Canvas {
    var buf: [3]u8 = undefined;
    try reader.readNoEof(&buf); // magic
    if (!std.mem.eql(u8, &buf, config.save_format_magic)) return error.MagicNotFound;

    var canvas = Canvas{};

    inline for (.{ "segments", "strokes" }) |field| {
        const size = try reader.readInt(u64, .little);
        try @field(canvas, field).resize(gpa, size);
        try reader.readNoEof(std.mem.sliceAsBytes(@field(canvas, field).items));
    }
    {
        const size = try reader.readInt(u64, .little);
        try canvas.history.events.resize(gpa, size);
        try reader.readNoEof(std.mem.sliceAsBytes(canvas.history.events.items));
    }
    return canvas;
}

pub fn deinit(canvas: *Canvas, gpa: std.mem.Allocator) void {
    canvas.strokes.deinit(gpa);
    canvas.segments.deinit(gpa);
    canvas.history.deinit(gpa);
}

test Canvas {
    const alloc = std.testing.allocator;
    var random = std.Random.DefaultPrng.init(std.testing.random_seed);
    const rand = random.random();

    var canvas = Canvas{};
    defer canvas.deinit(alloc);

    try canvas.startStroke(alloc, @bitCast(random.random().int(u32)));
    for (0..100_000) |_| {
        switch (rand.weightedIndex(
            u16,
            &.{ 1000, 10, 100, 1 },
        )) {
            0 => try canvas.addStrokePoint(alloc, .init(
                rand.float(f32),
                rand.float(f32),
            )),
            1 => try canvas.startStroke(alloc, @bitCast(random.random().int(u32))),
            2 => try canvas.erase(alloc, .init(
                rand.float(f32),
                rand.float(f32),
            ), .init(
                rand.float(f32),
                rand.float(f32),
            ), 10),
            3 => try canvas.save(std.io.null_writer),
            else => unreachable,
        }
    }
}
