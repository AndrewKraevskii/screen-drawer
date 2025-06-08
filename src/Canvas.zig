//! Contains data required for single canvas entry.

const std = @import("std");

const rl = @import("raylib");

const HistoryStorage = @import("history.zig").History;
const main = @import("main.zig");
const config = main.config;
const Vector2 = main.Vector2;

pub const History = HistoryStorage(EventTypes);

const Canvas = @This();

strokes: std.ArrayListUnmanaged(Stroke),
segments: std.ArrayListUnmanaged([2]f32),
history: History,
camera: rl.Camera2D,

pub const init: Canvas = .{
    .strokes = .{},
    .segments = .{},
    .history = .{},
    .camera = .{
        .zoom = 1,
        .target = .{ .x = 0, .y = 0 },
        .offset = .{ .x = 0, .y = 0 },
        .rotation = 0,
    },
};

const EventTypes = union(enum) {
    drawn: usize,
    erased: usize,

    pub fn redo(event: EventTypes, canvas: *Canvas) void {
        switch (event) {
            .drawn => |index| canvas.strokes.items[index].is_active = true,
            .erased => |index| canvas.strokes.items[index].is_active = false,
        }
    }
    pub fn undo(event: EventTypes, canvas: *Canvas) void {
        switch (event) {
            .erased => |index| canvas.strokes.items[index].is_active = true,
            .drawn => |index| canvas.strokes.items[index].is_active = false,
        }
    }
};

pub const BoundingBox = struct {
    min: Vector2,
    max: Vector2,

    pub fn merge(self: BoundingBox, other: ?BoundingBox) BoundingBox {
        if (other == null) return self;
        return .{
            .min = @min(self.min, other.?.min),
            .max = @max(self.max, other.?.max),
        };
    }
};

pub fn calculateBoundingBoxForStroke(canvas: Canvas, stroke: Canvas.Stroke) BoundingBox {
    var segment_min: Vector2 = @splat(std.math.floatMax(f32));
    var segment_max: Vector2 = @splat(-std.math.floatMax(f32));

    for (canvas.segments.items[stroke.span.start..][0..stroke.span.size]) |segment| {
        segment_min = @min(segment_min, @as(Vector2, segment));
        segment_max = @max(segment_max, @as(Vector2, segment));
    }

    return .{
        .min = segment_min,
        .max = segment_max,
    };
}

pub const Stroke = extern struct {
    is_active: bool = true,
    span: Span,
    color: rl.Color,
    width: f32,
};

const Span = extern struct {
    start: u64,
    size: u64,
};

pub fn startStroke(
    canvas: *@This(),
    gpa: std.mem.Allocator,
    color: rl.Color,
    thickness: f32,
) error{OutOfMemory}!void {
    try canvas.history.addHistoryEntry(gpa, .{ .drawn = canvas.strokes.items.len });

    try canvas.strokes.append(gpa, .{
        .span = .{
            .start = canvas.segments.items.len,
            .size = 0,
        },
        .color = color,
        .width = thickness,
    });
}

fn addStrokePointRaw(canvas: *@This(), gpa: std.mem.Allocator, pos: [2]f32, min_distance: f32) error{OutOfMemory}!void {
    std.debug.assert(canvas.strokes.items.len != 0);
    // if previous segment is to small update it instead of adding new.
    // const min_distance = 10;
    const min_distance_squared = min_distance * min_distance;
    if (canvas.strokes.items[canvas.strokes.items.len - 1].span.size >= 2 and canvas.segments.items.len >= 2) {
        const start: Vector2 = canvas.segments.items[canvas.segments.items.len - 2];
        const end: Vector2 = canvas.segments.items[canvas.segments.items.len - 1];
        if (@reduce(.Add, (start - end) * (start - end)) < min_distance_squared) {
            canvas.segments.items[canvas.segments.items.len - 1] = pos;
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

pub fn addStrokePoint(canvas: *@This(), gpa: std.mem.Allocator, pos: [2]f32, min_distance: f32) error{OutOfMemory}!void {
    const last_stroke = &canvas.strokes.items[canvas.strokes.items.len - 1];
    if (last_stroke.span.size > 50) {
        try addStrokePointRaw(
            canvas,
            gpa,
            pos,
            0,
        );
        try canvas.startStroke(gpa, last_stroke.color, last_stroke.width);
    }

    try addStrokePointRaw(
        canvas,
        gpa,
        pos,
        min_distance,
    );
}

pub fn erase(canvas: *@This(), gpa: std.mem.Allocator, start: Vector2, end: Vector2, radius: f32) error{OutOfMemory}!void {
    for (canvas.strokes.items, 0..) |*stroke, index| {
        if (stroke.is_active) {
            var iter = std.mem.window(
                [2]f32,
                canvas.segments.items[stroke.span.start..][0..stroke.span.size],
                2,
                1,
            );
            while (iter.next()) |line| {
                if (line.len == 0) continue;
                const line_intersects_cursor, const line_intersects_cursor_line = if (line.len > 1) blk: {
                    const line_intersects_cursor = rl.checkCollisionCircleLine(@bitCast(end), radius, @bitCast(line[0]), @bitCast(line[1]));
                    var collision_point: rl.Vector2 = undefined;
                    const line_intersects_cursor_line = rl.checkCollisionLines(@bitCast(end), @bitCast(start), @bitCast(line[0]), @bitCast(line[1]), &collision_point);
                    break :blk .{ line_intersects_cursor, line_intersects_cursor_line };
                } else blk: {
                    const line_intersects_cursor = rl.checkCollisionPointCircle(@bitCast(line[0]), @bitCast(end), radius);
                    const line_intersects_cursor_line = rl.checkCollisionPointLine(@bitCast(line[0]), @bitCast(end), @bitCast(start), config.eraser_thickness);
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
    try writer.writeAll(config.save_format_magic); // magic
    inline for (.{ "segments", "strokes" }) |field| {
        try writer.writeInt(u64, @field(canvas, field).items.len, .little);
        try writer.writeAll(std.mem.sliceAsBytes(@field(canvas, field).items));
    }
    try writer.writeInt(u64, canvas.history.events.items.len, .little);
    try writer.writeAll(std.mem.sliceAsBytes(canvas.history.events.items));
    try writer.writeAll(std.mem.asBytes(&canvas.camera));
}

pub fn load(gpa: std.mem.Allocator, reader: anytype) !Canvas {
    var buf: [3]u8 = undefined;
    try reader.readNoEof(&buf); // magic
    if (!std.mem.eql(u8, &buf, config.save_format_magic)) return error.MagicNotFound;

    var canvas: Canvas = .init;
    errdefer canvas.deinit(gpa);

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
    try reader.readNoEof(std.mem.asBytes(&canvas.camera));

    try integrityCheck(&canvas);

    return canvas;
}

pub fn integrityCheck(canvas: *Canvas) !void {
    const number_of_segments = canvas.segments.items.len;
    for (canvas.strokes.items) |segment| {
        if (segment.is_active and
            number_of_segments < segment.span.start +| segment.span.size)
        {
            std.log.err("number of segments: {d}\nspan: {d}-{d}", .{
                number_of_segments,
                segment.span.start,
                segment.span.start +| segment.span.size,
            });
            return error.SpanPointsToFar;
        }
    }
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

    var canvas: Canvas = .init;
    defer canvas.deinit(alloc);

    var file = std.ArrayList(u8).init(alloc);
    defer file.deinit();

    try canvas.startStroke(alloc, @bitCast(random.random().int(u32)), 10);
    for (0..100_000) |_| {
        thing_to_do: switch (rand.weightedIndex(
            u16,
            &.{ 1000, 10, 100, 1, 1 },
        )) {
            0 => try canvas.addStrokePoint(alloc, .{
                rand.float(f32),
                rand.float(f32),
            }, 10),
            1 => try canvas.startStroke(alloc, @bitCast(random.random().int(u32)), 10),
            2 => try canvas.erase(alloc, .{
                rand.float(f32),
                rand.float(f32),
            }, .{
                rand.float(f32),
                rand.float(f32),
            }, 10),
            3 => {
                try canvas.save(file.writer());
            },
            4 => {
                if (file.items.len == 0) {
                    continue :thing_to_do 3;
                }
                var fbr = std.io.fixedBufferStream(file.items);
                const new_canvas = try Canvas.load(alloc, fbr.reader());
                canvas.deinit(alloc);
                canvas = new_canvas;
            },
            else => unreachable,
        }
    }
}

test "Check leaks canvas" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        pub fn foo(alloc: std.mem.Allocator) !void {
            var random = std.Random.DefaultPrng.init(std.testing.random_seed);
            const rand = random.random();

            var canvas: Canvas = .init;
            defer canvas.deinit(alloc);

            var file = std.ArrayList(u8).init(alloc);
            defer file.deinit();

            try canvas.startStroke(alloc, @bitCast(random.random().int(u32)), 10);
            for (0..100_000) |_| {
                thing_to_do: switch (rand.weightedIndex(
                    u16,
                    &.{ 1000, 10, 100, 1, 1 },
                )) {
                    0 => try canvas.addStrokePoint(alloc, .{
                        rand.float(f32),
                        rand.float(f32),
                    }, 10),
                    1 => try canvas.startStroke(alloc, @bitCast(random.random().int(u32)), 10),
                    2 => try canvas.erase(alloc, .{
                        rand.float(f32),
                        rand.float(f32),
                    }, .{
                        rand.float(f32),
                        rand.float(f32),
                    }, 10),
                    3 => {
                        try canvas.save(file.writer());
                    },
                    4 => {
                        if (file.items.len == 0) {
                            continue :thing_to_do 3;
                        }
                        var fbr = std.io.fixedBufferStream(file.items);
                        const new_canvas = try Canvas.load(alloc, fbr.reader());
                        canvas.deinit(alloc);
                        canvas = new_canvas;
                    },
                    else => unreachable,
                }
            }
        }
    }.foo, .{});
}
