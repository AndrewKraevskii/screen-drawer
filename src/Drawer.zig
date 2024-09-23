const std = @import("std");
const rl = @import("raylib");
const Allocator = std.mem.Allocator;
const main = @import("main.zig");
const config = main.config;
const is_debug = @import("main.zig").is_debug;

gpa: std.mem.Allocator,

state: union(enum) {
    editing: struct {
        index: usize,
        brush_state: union(enum) {
            idle,
            drawing,
            eraser,
            picking_color,
        },
    },
},

color_wheel: ColorWheel,
brush: struct {
    radius: f32 = config.line_thickness,
    color: rl.Color,
},

strokes: std.ArrayListUnmanaged(Stroke) = .{},
segments: std.ArrayListUnmanaged([2]rl.Vector2) = .{},
history: History = .{},

old_mouse_position: rl.Vector2,

showing_keybindings: bool = false,

const History = struct {
    events: std.ArrayListUnmanaged(Entry) = .{},
    undone: usize = 0,

    const Entry = union(enum) {
        drawn: usize,
        erased: usize,
    };

    fn undo(history: *History, strokes: *std.ArrayListUnmanaged(Stroke)) bool {
        std.debug.assert(history.undone <= history.events.items.len);
        if (history.undone == history.events.items.len) {
            return false;
        }
        history.undone += 1;
        const event_to_undo = history.events.items[history.events.items.len - history.undone];

        switch (event_to_undo) {
            .drawn => |index| {
                strokes.items[index].is_active = false;
            },
            .erased => |index| {
                strokes.items[index].is_active = true;
            },
        }
        return true;
    }

    fn redo(history: *History, strokes: *std.ArrayListUnmanaged(Stroke)) bool {
        if (history.undone == 0) return false;
        const event_to_redo = history.events.items[history.events.items.len - history.undone];
        history.undone -= 1;
        switch (event_to_redo) {
            .drawn => |index| {
                strokes.items[index].is_active = true;
            },
            .erased => |index| {
                strokes.items[index].is_active = false;
            },
        }
        return true;
    }

    fn debugDraw(history: History, pos: rl.Vector2) void {
        const font_size = 20;
        const y_spacing = 10;
        for (history.events.items, 0..) |entry, index| {
            const alpha: f32 = if (index >= history.events.items.len - history.undone) 0.4 else 1;
            var buffer: [100]u8 = undefined;
            const y_offset: f32 = (font_size + y_spacing) * @as(f32, @floatFromInt(index));
            switch (entry) {
                .drawn => |i| {
                    rl.drawTextEx(rl.getFontDefault(), std.fmt.bufPrintZ(&buffer, "drawn {d}", .{i}) catch unreachable, pos.add(.{
                        .x = 0,
                        .y = y_offset,
                    }), font_size, 2, rl.Color.green.alpha(alpha));
                },
                .erased => |i| {
                    rl.drawTextEx(rl.getFontDefault(), std.fmt.bufPrintZ(&buffer, "erased {d}", .{i}) catch unreachable, pos.add(.{
                        .x = 0,
                        .y = y_offset,
                    }), font_size, 2, rl.Color.red.alpha(alpha));
                },
            }
        }
    }

    fn addHistoryEntry(
        history: *History,
        gpa: Allocator,
        entry: Entry,
    ) !void {
        if (history.undone != 0) {
            history.events.shrinkRetainingCapacity(history.events.items.len - history.undone);
            history.undone = 0;
        }

        try history.events.append(
            gpa,
            entry,
        );
    }

    fn deinit(history: *History, gpa: Allocator) void {
        history.events.deinit(gpa);
    }
};

const Stroke = struct {
    is_active: bool = true,
    span: Span,
    color: rl.Color,
};

const Span = struct {
    start: usize,
    size: usize,
};

const Drawer = @This();

pub fn init(gpa: std.mem.Allocator) !Drawer {
    rl.setConfigFlags(.{
        .window_topmost = true,
        .window_transparent = true,
        .window_undecorated = true,
        .window_maximized = true,
        .vsync_hint = true,
    });
    rl.setTraceLogLevel(if (is_debug) .log_debug else .log_warning);
    rl.initWindow(0, 0, "Drawer");
    errdefer rl.closeWindow();

    const save_directory = try getAppDataDirEnsurePathExist(gpa, config.app_name);
    defer gpa.free(save_directory);

    return .{
        .gpa = gpa,
        .color_wheel = .{ .center = rl.Vector2.zero(), .size = 0 },
        .brush = .{
            .color = rl.Color.red,
        },
        .old_mouse_position = rl.getMousePosition(),
        .state = .{
            .editing = .{
                .index = 0,
                .brush_state = .idle,
            },
        },
    };
}

pub fn padRectangle(rect: rl.Rectangle, padding: rl.Vector2) rl.Rectangle {
    return .{
        .x = rect.x - padding.x,
        .y = rect.y - padding.y,
        .width = rect.width + 2 * padding.x,
        .height = rect.height + 2 * padding.y,
    };
}

pub fn drawKeybindingsHelp(arena: std.mem.Allocator, position: rl.Vector2) !void {
    const starting_position = position;
    const font_size = 20;
    const spacing = 3;
    const y_spacing = 1;
    const dash_string = " - ";
    const keys_join_string = " + ";

    const help_window_height = (font_size + y_spacing) * @as(f32, @floatFromInt(std.meta.declarations(config.key_bindings).len));

    const measurer: struct {
        font: rl.Font,
        spacing: f32,
        font_size: f32,

        pub fn measureText(self: @This(), text: [:0]const u8) rl.Vector2 {
            return rl.measureTextEx(
                self.font,
                text,
                self.font_size,
                self.spacing,
            );
        }
    } = .{ .font = rl.getFontDefault(), .spacing = spacing, .font_size = font_size };

    const max_width_left, const max_width_right = max_width: {
        var max_width_left: f32 = 0;
        var max_width_right: f32 = 0;
        inline for (comptime std.meta.declarations(config.key_bindings)) |key_binding| {
            const keys = @field(config.key_bindings, key_binding.name);
            {
                var string_builder = std.ArrayList(u8).init(arena);
                defer string_builder.deinit();
                try string_builder.appendSlice(dash_string);
                inline for (keys, 0..) |key, key_index| {
                    try string_builder.appendSlice(@tagName(key));
                    if (key_index + 1 != keys.len)
                        try string_builder.appendSlice(keys_join_string);
                }
                try string_builder.append(0);
                const width_right = measurer.measureText(@ptrCast(string_builder.items));
                max_width_right = @max(width_right.x, max_width_right);
            }

            const width_left = measurer.measureText(key_binding.name).x;
            max_width_left = @max(width_left, max_width_left);
        }
        break :max_width .{ max_width_left, max_width_right };
    };

    const drawing_rect = rl.Rectangle.init(starting_position.x, starting_position.y, max_width_left + max_width_right, help_window_height);

    rl.drawRectangleRec(
        padRectangle(drawing_rect, .{ .x = 10, .y = 10 }),
        rl.Color.black.alpha(0.9),
    );

    inline for (comptime std.meta.declarations(config.key_bindings), 0..) |key_binding, index| {
        const name = key_binding.name;

        const y_offset: f32 = (font_size + y_spacing) * @as(f32, @floatFromInt(index));
        const pos = starting_position.add(.{
            .x = 0,
            .y = y_offset,
        });

        {
            rl.drawTextEx(
                rl.getFontDefault(),
                name,
                pos,
                font_size,
                spacing,
                rl.Color.green,
            );
        }
        {
            var string_builder = std.ArrayList(u8).init(arena);
            defer string_builder.deinit();
            try string_builder.appendSlice(dash_string);

            const keys = @field(config.key_bindings, name);
            inline for (keys, 0..) |key, key_index| {
                try string_builder.appendSlice(@tagName(key));
                if (key_index + 1 != keys.len)
                    try string_builder.appendSlice(keys_join_string);
            }
            try string_builder.append(0);
            rl.drawTextEx(
                rl.getFontDefault(),
                @ptrCast(string_builder.items.ptr),
                pos.add(.{ .x = max_width_left, .y = 0 }),
                font_size,
                spacing,
                rl.Color.red,
            );
        }
    }
}

pub fn deinit(self: *Drawer) void {
    self.strokes.deinit(self.gpa);
    self.history.deinit(self.gpa);
    self.segments.deinit(self.gpa);
    rl.closeWindow();
}

pub fn run(self: *Drawer) !void {
    while (!rl.windowShouldClose() and (!config.exit_on_unfocus or rl.isWindowFocused())) {
        try tick(self);
    }
}

pub fn tick(self: *Drawer) !void {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();

    rl.beginDrawing();
    rl.clearBackground(rl.Color.blank);

    const mouse_position = rl.getMousePosition();
    defer self.old_mouse_position = mouse_position;

    if (isPressed(config.key_bindings.toggle_keybindings)) {
        self.showing_keybindings = !self.showing_keybindings;
    }

    self.state = switch (self.state) {
        .editing => |*state| blk: {
            rl.hideCursor();

            for (self.strokes.items) |stroke| {
                if (stroke.is_active) {
                    for (self.segments.items[stroke.span.start..][0..stroke.span.size]) |line| {
                        rl.drawLineEx(line[0], line[1], self.brush.radius, stroke.color);
                    }
                }
            }
            if (isPressed(config.key_bindings.undo))
                _ = self.history.undo(&self.strokes);
            if (isPressed(config.key_bindings.redo))
                _ = self.history.redo(&self.strokes);

            state.brush_state = switch (state.brush_state) {
                .idle => if (isDown(config.key_bindings.draw)) state: {
                    try self.history.addHistoryEntry(self.gpa, .{ .drawn = self.strokes.items.len });

                    try self.strokes.append(self.gpa, .{ .span = .{
                        .start = self.segments.items.len,
                        .size = 0,
                    }, .color = self.brush.color });
                    break :state .drawing;
                } else if (isDown(config.key_bindings.eraser))
                    .eraser
                else if (isPressed(config.key_bindings.picking_color)) state: {
                    self.color_wheel = .{ .center = mouse_position, .size = 0 };
                    break :state .picking_color;
                } else .idle,

                .drawing => state: {
                    if (self.strokes.items.len == 0) {
                        try self.strokes.append(self.gpa, .{
                            .span = .{
                                .start = 0,
                                .size = 0,
                            },
                            .color = self.brush.color,
                        });
                    }

                    self.strokes.items[self.strokes.items.len - 1].span.size += 1;
                    self.strokes.items[self.strokes.items.len - 1].color = self.brush.color;

                    try self.segments.append(self.gpa, .{
                        self.old_mouse_position,
                        rl.getMousePosition(),
                    });

                    break :state if (isDown(config.key_bindings.draw))
                        .drawing
                    else
                        .idle;
                },
                .eraser => state: {
                    const radius = config.eraser_thickness / 2;

                    for (self.strokes.items, 0..) |*stroke, index| {
                        if (stroke.is_active) {
                            for (self.segments.items[stroke.span.start..][0..stroke.span.size]) |line| {
                                if (rl.checkCollisionCircleLine(rl.getMousePosition(), radius, line[0], line[1])) {
                                    try self.history.addHistoryEntry(self.gpa, .{ .erased = index });
                                    stroke.is_active = false;
                                    break;
                                }
                            }
                        }
                    }

                    break :state if (isDown(config.key_bindings.eraser)) .eraser else .idle;
                },
                .picking_color => state: {
                    self.brush.color = self.color_wheel.draw(mouse_position);
                    break :state if (!isDown(config.key_bindings.picking_color))
                        .idle
                    else {
                        self.color_wheel.size = expDecayWithAnimationSpeed(
                            self.color_wheel.size,
                            config.color_wheel_size,
                            rl.getFrameTime(),
                        );
                        break :state .picking_color;
                    };
                },
            };

            self.history.debugDraw(.{
                .x = 20,
                .y = 10,
            });

            // Shrink color picker
            if (state.brush_state != .picking_color) {
                self.color_wheel.size = expDecayWithAnimationSpeed(self.color_wheel.size, 0, rl.getFrameTime());
                _ = self.color_wheel.draw(mouse_position);
            }
            // Draw cursor
            if (state.brush_state == .eraser) {
                rl.drawCircleLinesV(mouse_position, config.eraser_thickness / 2, self.brush.color);
            } else {
                rl.drawCircleV(mouse_position, self.brush.radius * 2, self.brush.color);
            }

            break :blk self.state;
        },
    };

    if (self.showing_keybindings) {
        try drawKeybindingsHelp(arena.allocator(), .init(100, 100));
    }
    if (@import("builtin").mode == .Debug)
        rl.drawFPS(0, 0);

    rl.endDrawing();
}

/// True if all passed keys and buttons are down
fn isDown(keys_or_buttons: anytype) bool {
    inline for (keys_or_buttons) |key_or_button| {
        switch (@TypeOf(key_or_button)) {
            rl.KeyboardKey => if (!rl.isKeyDown(key_or_button))
                return false,
            rl.MouseButton => if (!rl.isMouseButtonDown(key_or_button))
                return false,

            else => @panic("Wrong type passed"),
        }
    }

    return true;
}

/// True if isDown(keys_or_buttons) true and at least one of key_or_button pressed on this frame
fn isPressed(keys_or_buttons: anytype) bool {
    if (!isDown(keys_or_buttons)) return false;

    inline for (keys_or_buttons) |key_or_button| {
        switch (@TypeOf(key_or_button)) {
            rl.KeyboardKey => if (rl.isKeyPressed(key_or_button) and !isModifierKey(key_or_button))
                return true,
            rl.MouseButton => if (rl.isMouseButtonPressed(key_or_button))
                return true,
            else => unreachable, // since we checked it in isDown
        }
    }

    return false;
}

fn isModifierKey(key: rl.KeyboardKey) bool {
    return switch (key) {
        .key_left_control,
        .key_left_alt,
        .key_left_shift,
        .key_right_control,
        .key_right_alt,
        .key_right_shift,
        => true,
        else => false,
    };
}

const ColorWheel = struct {
    center: rl.Vector2,
    size: f32,

    pub fn draw(wheel: ColorWheel, pos: rl.Vector2) rl.Color {
        if (wheel.size < 0.01) return rl.Color.blank;
        const segments = 360;
        for (0..segments) |num| {
            const frac = @as(f32, @floatFromInt(num)) / @as(f32, @floatFromInt(segments));
            const angle = frac * 360;

            const hue = frac * 360;
            rl.drawCircleSector(
                wheel.center,
                wheel.size,
                angle,
                angle + 360.0 / @as(comptime_float, segments),
                10,
                rl.Color.fromHSV(hue, 0.8, 0.8),
            );
        }
        const distance = @min(wheel.center.distance(pos) / wheel.size, 1);
        return rl.Color.fromHSV(-wheel.center.lineAngle(pos) / std.math.tau * 360, distance, 1);
    }
};

const gui = struct {
    fn cross(
        rect: rl.Rectangle,
        thickness: f32,
    ) bool {
        const mouse_position = rl.getMousePosition();
        const hovering_cross = rl.checkCollisionPointRec(mouse_position, rect);
        const color = if (hovering_cross) rl.Color.white else rl.Color.black;
        rl.drawRectangleRec(rect, rl.Color.red);
        rl.drawLineEx(.{
            .x = rect.x,
            .y = rect.y,
        }, .{
            .x = rect.x + rect.width,
            .y = rect.y + rect.height,
        }, thickness, color);
        rl.drawLineEx(.{
            .x = rect.x + rect.width,
            .y = rect.y,
        }, .{
            .x = rect.x,
            .y = rect.y + rect.height,
        }, thickness, color);
        return hovering_cross and isPressed(config.key_bindings.confirm);
    }

    fn drawPlus(rect: rl.Rectangle, thickness: f32, color: rl.Color) void {
        rl.drawLineEx(.{
            .x = rect.x,
            .y = rect.y + rect.height / 2,
        }, .{
            .x = rect.x + rect.width,
            .y = rect.y + rect.height / 2,
        }, thickness, color);
        rl.drawLineEx(.{
            .x = rect.x + rect.width / 2,
            .y = rect.y,
        }, .{
            .x = rect.x + rect.width / 2,
            .y = rect.y + rect.height,
        }, thickness, color);
    }

    fn add(rect: rl.Rectangle) bool {
        const hovering_rectangle = rl.checkCollisionPointRec(rl.getMousePosition(), rect);

        rl.drawRectangleLinesEx(rect, 3, if (hovering_rectangle)
            rl.Color.light_gray
        else
            rl.Color.gray);

        {
            rl.drawRectangleRec(
                resizeRectangleCenter(rect, rl.Vector2.one().scale(60)),
                rl.Color.dark_gray,
            );
            drawPlus(
                resizeRectangleCenter(rect, rl.Vector2.one().scale(20)),
                3,
                rl.Color.white,
            );
        }
        return hovering_rectangle and isPressed(config.key_bindings.confirm);
    }

    fn item(rect: rl.Rectangle, texture: ?rl.Texture) enum {
        select,
        delete,
        idle,
    } {
        const mouse_position = rl.getMousePosition();
        const hovering_rectangle = rl.checkCollisionPointRec(mouse_position, rect);

        const cross_rectangle = resizeRectangle(rect, rl.Vector2.one().scale(40), .{
            .x = 1, // top right conner
            .y = 0,
        });
        const hovering_cross = rl.checkCollisionPointRec(mouse_position, cross_rectangle);

        const border_color = if (hovering_rectangle and !hovering_cross)
            rl.Color.light_gray
        else
            rl.Color.gray;
        rl.drawRectangleRec(rect, rl.Color.black.alpha(0.6));
        rl.drawRectangleLinesEx(rect, 3, border_color);

        if (texture) |t| t.drawPro(
            .{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(t.width),
                .height = @floatFromInt(t.height),
            },
            rect,
            rl.Vector2.zero(),
            0,
            rl.Color.white,
        );

        if (cross(cross_rectangle, 3)) {
            return .delete;
        }
        if (isPressed(config.key_bindings.confirm)) {
            if (hovering_rectangle) {
                return .select;
            }
        }
        return .idle;
    }
};

fn drawNiceLine(start: rl.Vector2, end: rl.Vector2, thickness: f32, color: rl.Color) void {
    const projected_end = projectToClosestLine(start, end);
    rl.drawLineEx(start, projected_end, thickness, color);
}

fn projectToClosestLine(start: rl.Vector2, end: rl.Vector2) rl.Vector2 {
    const horizontal = rl.Vector2{
        .x = end.x,
        .y = start.y,
    };
    const vertical = rl.Vector2{
        .x = start.x,
        .y = end.y,
    };
    return if (start.subtract(horizontal).lengthSqr() > start.subtract(vertical).lengthSqr()) horizontal else vertical;
}

fn expDecay(a: anytype, b: @TypeOf(a), lambda: @TypeOf(a), dt: @TypeOf(a)) @TypeOf(a) {
    return std.math.lerp(a, b, 1 - @exp(-lambda * dt));
}

fn expDecayWithAnimationSpeed(a: anytype, b: @TypeOf(a), dt: @TypeOf(a)) @TypeOf(a) {
    return if (config.animation_speed) |lambda|
        std.math.lerp(a, b, 1 - @exp(-lambda * dt))
    else
        b;
}

fn scaleRectangleCenter(rect: rl.Rectangle, scale: rl.Vector2) rl.Rectangle {
    return resizeRectangleCenter(rect, scale.multiply(rectangleSize(rect)));
}

fn scaleRectangle(rect: rl.Rectangle, scale: rl.Vector2, origin: rl.Vector2) rl.Rectangle {
    return resizeRectangle(rect, scale.multiply(rectangleSize(rect)), origin);
}

fn resizeRectangleCenter(rect: rl.Rectangle, size: rl.Vector2) rl.Rectangle {
    return resizeRectangle(rect, size, .{
        .x = 0.5,
        .y = 0.5,
    });
}

fn resizeRectangle(rect: rl.Rectangle, size: rl.Vector2, origin: rl.Vector2) rl.Rectangle {
    return .{
        .x = rect.x + (rect.width - size.x) * origin.x,
        .y = rect.y + (rect.height - size.y) * origin.y,
        .width = size.x,
        .height = size.y,
    };
}

fn rectangleSize(rect: rl.Rectangle) rl.Vector2 {
    return .{
        .x = rect.width,
        .y = rect.height,
    };
}

fn flushRaylib() void {
    rl.beginMode2D(std.mem.zeroes(rl.Camera2D));
    rl.endMode2D();
}

fn getAppDataDirEnsurePathExist(alloc: std.mem.Allocator, appname: []const u8) ![]u8 {
    const data_dir_path = try std.fs.getAppDataDir(alloc, appname);

    std.fs.makeDirAbsolute(data_dir_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => |err| return err,
    };
    return data_dir_path;
}
