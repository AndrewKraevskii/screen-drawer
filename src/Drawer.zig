const std = @import("std");

const rl = @import("raylib");
const tracy = @import("tracy");

const Canvas = @import("Canvas.zig");
const is_debug = @import("main.zig").is_debug;
const main = @import("main.zig");
const config = main.config;
const OverrideQueue = @import("override_queue.zig").OverrideQueue;
const Rectangle = @import("Rectangle.zig");

const Drawer = @This();

gpa: std.mem.Allocator,

brush_state: union(enum) {
    idle,
    drawing,
    eraser,
    picking_color,
},

color_wheel: ColorWheel,
brush: struct {
    radius: f32 = config.line_thickness,
    color: rl.Color,
},

canvas: Canvas = .{},
old_cursor_position: rl.Vector2,

showing_keybindings: bool = false,

cursor_trail: OverrideQueue(TrailParticle, 0x100) = .empty,
cursor_trail_enabled: bool = false,
drawing_particles: OverrideQueue(DrawingParticle, 0x100) = .empty,
drawing_particles_enabled: bool = false,

background_color: rl.Color = .blank,
background_alpha_selector: ?Bar = null,

random: std.Random.DefaultPrng,

save_directory: std.fs.Dir,

fn getAppDataDirEnsurePathExist(alloc: std.mem.Allocator, appname: []const u8) ![]u8 {
    const data_dir_path = try std.fs.getAppDataDir(alloc, appname);

    std.fs.makeDirAbsolute(data_dir_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => |err| return err,
    };
    return data_dir_path;
}

fn addTrailParticle(self: *@This(), pos: rl.Vector2) void {
    const zone = tracy.initZone(@src(), .{});
    defer zone.deinit();

    self.cursor_trail.add(.{
        .pos = pos,
        .time_to_live = 0.2,
        .size = self.brush.radius,
    });
}

fn updateTrail(self: *@This()) void {
    const zone = tracy.initZone(@src(), .{});
    defer zone.deinit();

    inline for (self.cursor_trail.orderedSlices()) |slice| {
        for (slice) |*particle| {
            particle.size *= 0.9;
            particle.time_to_live -= rl.getFrameTime();
        }
    }
}

fn drawTrail(self: *@This()) void {
    const zone = tracy.initZone(@src(), .{});
    defer zone.deinit();

    if (self.cursor_trail.count == 0) return;
    var prev: ?TrailParticle = null;
    inline for (self.cursor_trail.orderedSlices()) |slice| {
        for (slice) |*particle| {
            if (particle.time_to_live < 0) continue;
            if (prev == null) {
                prev = particle.*;
                continue;
            }
            defer prev = particle.*;
            rl.drawLineEx(particle.pos, prev.?.pos, particle.size * 2, self.brush.color);
        }
    }
}

const TrailParticle = struct {
    pos: rl.Vector2,
    size: f32,
    time_to_live: f32,
};

const DrawingParticle = struct {
    pos: rl.Vector2,
    size: f32,
    velocity: rl.Vector2,
    acceleration: rl.Vector2,
    time_to_live: f32,
};

fn addDrawingParticle(self: *@This(), pos: rl.Vector2) void {
    const zone = tracy.initZone(@src(), .{});
    defer zone.deinit();

    self.drawing_particles.add(.{
        .pos = pos,
        .velocity = .init(
            (self.random.random().float(f32) - 0.5) * 100,
            (self.random.random().float(f32) - 0.5) * 100,
        ),
        .acceleration = .init(
            0,
            0,
        ),
        .size = 3,
        .time_to_live = 0.5,
    });
}

fn updateDrawingParticle(self: *@This()) void {
    const zone = tracy.initZone(@src(), .{});
    defer zone.deinit();

    inline for (self.drawing_particles.orderedSlices()) |slice| {
        for (slice) |*particle| {
            particle.time_to_live -= rl.getFrameTime();
            particle.pos = particle.pos.add(particle.velocity.scale(@floatCast(rl.getFrameTime())));
            particle.velocity = particle.velocity.add(particle.acceleration.scale(@floatCast(rl.getFrameTime())));
            particle.time_to_live -= rl.getFrameTime();
        }
    }
}

fn drawDrawingParticles(self: *@This()) void {
    const zone = tracy.initZone(@src(), .{});
    defer zone.deinit();

    inline for (self.drawing_particles.orderedSlices()) |slice| {
        for (slice) |*particle| {
            if (particle.time_to_live < 0) continue;
            rl.drawCircleV(particle.pos, particle.size, .orange);
        }
    }
}

fn debugDrawHistory(history: Canvas.History, pos: rl.Vector2) void {
    const font_size = 20;
    const y_spacing = 10;
    for (history.events.items, 0..) |entry, index| {
        const alpha: f32 = if (index >= history.events.items.len - history.undone) 0.4 else 1;
        var buffer: [100]u8 = undefined;
        const y_offset: f32 = (font_size + y_spacing) * @as(f32, @floatFromInt(index));
        const text, const color = switch (entry) {
            .drawn => |i| .{ std.fmt.bufPrintZ(&buffer, "drawn1 {d}", .{i}) catch unreachable, rl.Color.green.alpha(alpha) },
            .erased => |i| .{ std.fmt.bufPrintZ(&buffer, "erased {d}", .{i}) catch unreachable, rl.Color.red.alpha(alpha) },
        };
        rl.drawTextEx(rl.getFontDefault(), text, pos.add(.{
            .x = 0,
            .y = y_offset,
        }), font_size, 2, color);
    }
}

pub fn init(gpa: std.mem.Allocator) !Drawer {
    const zone = tracy.initZone(@src(), .{});
    defer zone.deinit();

    rl.setConfigFlags(.{
        .window_topmost = config.is_topmost,
        .window_transparent = true,
        .window_undecorated = true,
        .window_maximized = true,
        .vsync_hint = true,
        .msaa_4x_hint = true,
    });
    rl.setTraceLogLevel(if (is_debug) .log_debug else .log_warning);
    rl.initWindow(0, 0, config.app_name);
    errdefer rl.closeWindow();

    const dir_path = try getAppDataDirEnsurePathExist(gpa, config.save_folder_name);
    defer gpa.free(dir_path);

    var dir = try std.fs.openDirAbsolute(dir_path, .{});
    errdefer dir.close();

    var drawer: Drawer = .{
        .gpa = gpa,
        .color_wheel = .{ .center = rl.Vector2.zero(), .size = 0 },
        .brush = .{
            .color = rl.Color.red,
        },
        .old_cursor_position = rl.getMousePosition(),
        .brush_state = .idle,
        .random = std.Random.DefaultPrng.init(0),
        .save_directory = dir,
    };

    { // load canvas
        const file_zone = tracy.initZone(@src(), .{ .name = "Open file" });
        var file = try dir.openFile(config.save_file_name, .{});
        file_zone.deinit();
        defer file.close();

        var br = std.io.bufferedReader(file.reader());
        const reader = br.reader();

        drawer.canvas = Canvas.load(gpa, reader) catch |e| canvas: {
            std.log.err("Can't load file {s}", .{@errorName(e)});

            break :canvas Canvas{};
        };
    }

    return drawer;
}

fn drawKeybindingsHelp(arena: std.mem.Allocator, position: rl.Vector2) !void {
    const zone = tracy.initZone(@src(), .{ .name = "drawKeybindingsHelp" });
    defer zone.deinit();

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

        fn measureText(self: @This(), text: [:0]const u8) rl.Vector2 {
            const measurer_zone = tracy.initZone(@src(), .{ .name = "measure text" });
            defer measurer_zone.deinit();

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

    const drawing_rect = Rectangle.init(starting_position.x, starting_position.y, max_width_left + max_width_right, help_window_height);

    rl.drawRectangleRec(
        drawing_rect.padRectangle(.{ .x = 10, .y = 10 }).toRay(),
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
    self.save() catch |e| {
        std.log.err("Failed to save: {s}", .{@errorName(e)});
    };
    self.save_directory.close();
    self.canvas.deinit(self.gpa);
    rl.closeWindow();
}

pub fn run(self: *Drawer) !void {
    while (!(rl.windowShouldClose() or
        (config.exit_on_unfocus and !rl.isWindowFocused())))
    {
        tracy.frameMark();
        try tick(self);
    }
}

fn save(self: *@This()) !void {
    var file = try self.save_directory.createFile(config.save_file_name, .{});
    defer file.close();
    var bw = std.io.bufferedWriter(file.writer());
    defer bw.flush() catch |e| {
        std.log.err("Failed to save: {s}", .{@errorName(e)});
    };
    const writer = bw.writer();

    try self.canvas.save(writer);
}

fn tick(self: *Drawer) !void {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();

    rl.beginDrawing();
    rl.clearBackground(self.background_color);

    tracy.plot(i64, "history size", @intCast(self.canvas.history.events.items.len));
    tracy.plot(i64, "strokes size", @intCast(self.canvas.strokes.items.len));
    tracy.plot(i64, "segments size", @intCast(self.canvas.segments.items.len));

    const cursor_position = rl.getMousePosition();
    defer self.old_cursor_position = cursor_position;

    // :global input
    if (isPressed(config.key_bindings.toggle_keybindings)) {
        self.showing_keybindings = !self.showing_keybindings;
    }
    if (isPressed(config.key_bindings.enable_cursor_trail)) {
        self.cursor_trail_enabled = !self.cursor_trail_enabled;
    }
    if (isPressed(config.key_bindings.save)) {
        try self.save();
        std.log.info("Saved image", .{});
    }

    {
        const zone = tracy.initZone(@src(), .{ .name = "Line drawing" });
        defer zone.deinit();

        for (self.canvas.strokes.items) |stroke| {
            if (stroke.is_active) {
                if (stroke.span.size < 2) continue;
                var iter = std.mem.window(
                    rl.Vector2,
                    self.canvas.segments.items[stroke.span.start..][0..stroke.span.size],
                    2,
                    1,
                );
                while (iter.next()) |line| {
                    rl.drawLineEx(line[0], line[1], self.brush.radius, stroke.color);
                }
            }
        }
    }
    if (isPressed(config.key_bindings.undo)) {
        if (self.canvas.history.undo()) |undo_event| {
            undo_event.undo(&self.canvas);
        }
    }
    if (isPressed(config.key_bindings.redo)) {
        if (self.canvas.history.redo()) |redo_event| {
            redo_event.redo(&self.canvas);
        }
    }

    self.brush_state = switch (self.brush_state) {
        .idle => if (isDown(config.key_bindings.draw)) state: {
            try self.canvas.startStroke(self.gpa, self.brush.color);
            break :state .drawing;
        } else if (isDown(config.key_bindings.eraser))
            .eraser
        else if (isPressed(config.key_bindings.picking_color)) state: {
            self.color_wheel = .{ .center = cursor_position, .size = 0 };
            break :state .picking_color;
        } else .idle,

        .drawing => state: {
            try self.canvas.addStrokePoint(self.gpa, rl.getMousePosition());
            break :state if (isDown(config.key_bindings.draw))
                .drawing
            else
                .idle;
        },
        .eraser => state: {
            const radius = config.eraser_thickness / 2;
            try self.canvas.erase(self.gpa, self.old_cursor_position, rl.getMousePosition(), radius);

            break :state if (isDown(config.key_bindings.eraser)) .eraser else .idle;
        },
        .picking_color => state: {
            self.brush.color = self.color_wheel.draw(cursor_position);
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

    if (is_debug)
        debugDrawHistory(self.canvas.history, .{
            .x = 20,
            .y = 10,
        });

    // Shrink color picker
    if (self.brush_state != .picking_color) {
        self.color_wheel.size = expDecayWithAnimationSpeed(self.color_wheel.size, 0, rl.getFrameTime());
        _ = self.color_wheel.draw(cursor_position);
    }

    // Draw mouse
    if (self.brush_state == .eraser) {
        rl.drawCircleLinesV(cursor_position, config.eraser_thickness / 2, self.brush.color);
    } else {
        rl.drawCircleV(cursor_position, self.brush.radius * 2, self.brush.color);
    }

    // Draw trail
    self.updateTrail();
    if (self.cursor_trail_enabled) {
        self.addTrailParticle(cursor_position);
        self.drawTrail();
    }

    // Draw sparks
    self.updateDrawingParticle();
    if (self.drawing_particles_enabled)
        if (self.brush_state == .drawing)
            self.addDrawingParticle(cursor_position);
    self.drawDrawingParticles();

    if (isDown(config.key_bindings.change_brightness)) {
        if (self.background_alpha_selector) |bar| {
            self.background_color = self.background_color.alpha(bar.draw(cursor_position));
        } else {
            self.background_alpha_selector = Bar.new(cursor_position, self.background_color.normalize().w, .{ .text = "Background alpha" });
        }
    } else {
        if (self.background_alpha_selector) |_| {
            self.background_alpha_selector = null;
        }
    }

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

    fn draw(wheel: ColorWheel, pos: rl.Vector2) rl.Color {
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

const Bar = struct {
    center: rl.Vector2,
    min: f32,
    max: f32,
    scale: f32,
    text: [:0]const u8,
    color: rl.Color,

    const Config = struct {
        min: f32 = 0,
        max: f32 = 1,
        scale: f32 = 200,
        text: [:0]const u8 = "Some ui bar",
        color: rl.Color = .gray,
    };

    fn new(pos: rl.Vector2, value: f32, bar_config: Config) @This() {
        const top_y = pos.y - bar_config.scale / 2;
        const persantage = (value - bar_config.min) / (bar_config.max - bar_config.min);
        return .{
            .center = .init(
                pos.x - 50,
                persantage * bar_config.scale + top_y,
            ),
            .min = bar_config.min,
            .max = bar_config.max,
            .scale = bar_config.scale,
            .text = bar_config.text,
            .color = bar_config.color,
        };
    }

    fn draw(self: @This(), cursor_pos: rl.Vector2) f32 {
        const bar_top = self.center.add(.init(0, self.scale / 2));
        const bar_bottom = self.center.subtract(.init(0, self.scale / 2));
        const bar_width = 10;
        rl.drawLineEx(
            bar_top,
            bar_bottom,
            bar_width,
            rl.Color.gray,
        );
        const bar_size = 10;
        const bar_middle_pos = rl.Vector2.init(self.center.x, std.math.clamp(cursor_pos.y, bar_bottom.y, bar_top.y));
        const font_size = 30;
        const text_width = rl.measureText(self.text, font_size);
        rl.drawText(
            self.text,
            @as(i32, @intFromFloat(self.center.x)) - text_width - bar_width,
            @as(i32, @intFromFloat(self.center.y)) - font_size / 2,
            font_size,
            .white,
        );
        rl.drawLineEx(
            bar_middle_pos.add(.init(0, bar_size / 2)),
            bar_middle_pos.subtract(.init(0, bar_size / 2)),
            bar_width,
            rl.Color.black,
        );

        const selected_value = (bar_top.y - bar_middle_pos.y) / self.scale;
        return selected_value * (self.max - self.min) + self.min;
    }
};

fn expDecay(a: anytype, b: @TypeOf(a), lambda: @TypeOf(a), dt: @TypeOf(a)) @TypeOf(a) {
    return std.math.lerp(a, b, 1 - @exp(-lambda * dt));
}

fn expDecayWithAnimationSpeed(a: anytype, b: @TypeOf(a), dt: @TypeOf(a)) @TypeOf(a) {
    return if (config.animation_speed) |lambda|
        std.math.lerp(a, b, 1 - @exp(-lambda * dt))
    else
        b;
}
