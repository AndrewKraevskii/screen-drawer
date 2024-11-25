const std = @import("std");

const rl = @import("raylib");
const tracy = @import("tracy");

const Canvas = @import("Canvas.zig");
const is_debug = @import("main.zig").is_debug;
const main = @import("main.zig");
const config = main.config;
const Vec2 = main.Vector2;
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

canvas: Canvas,
old_world_position: Vec2,
old_cursor_position: Vec2,

showing_keybindings: bool = false,

cursor_trail: OverrideQueue(TrailParticle, 0x100) = .empty,
cursor_trail_enabled: bool = false,
drawing_particles: OverrideQueue(DrawingParticle, 0x100) = .empty,
drawing_particles_enabled: bool = false,

background_color: rl.Color = .blank,
background_alpha_selector: ?Bar = null,

random: std.Random.DefaultPrng,
target_zoom: f32,

save_directory: std.fs.Dir,

fn getAppDataDirEnsurePathExist(alloc: std.mem.Allocator, appname: []const u8) ![]u8 {
    const data_dir_path = try std.fs.getAppDataDir(alloc, appname);

    std.fs.makeDirAbsolute(data_dir_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => |err| return err,
    };
    return data_dir_path;
}

fn addTrailParticle(self: *@This(), pos: Vec2) void {
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
            rl.drawLineEx(@bitCast(particle.pos), @bitCast(prev.?.pos), particle.size * 2, self.brush.color);
        }
    }
}

const TrailParticle = struct {
    pos: Vec2,
    size: f32,
    time_to_live: f32,
};

const DrawingParticle = struct {
    pos: Vec2,
    size: f32,
    velocity: Vec2,
    acceleration: Vec2,
    time_to_live: f32,
};

fn addDrawingParticle(self: *@This(), pos: Vec2) void {
    const zone = tracy.initZone(@src(), .{});
    defer zone.deinit();

    self.drawing_particles.add(.{
        .pos = pos,
        .velocity = .{
            (self.random.random().float(f32) - 0.5) * 100,
            (self.random.random().float(f32) - 0.5) * 100,
        },
        .acceleration = .{
            0,
            0,
        },
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
            particle.pos = particle.pos + particle.velocity * @as(Vec2, @splat(@floatCast(rl.getFrameTime())));
            particle.velocity = particle.velocity + particle.acceleration * @as(Vec2, @splat(@floatCast(rl.getFrameTime())));
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
            rl.drawCircleV(@bitCast(particle.pos), @bitCast(particle.size), .orange);
        }
    }
}

fn debugDrawHistory(history: Canvas.History, pos: Vec2) void {
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
        rl.drawTextEx(rl.getFontDefault(), text, @bitCast(pos + Vec2{ 0, y_offset }), font_size, 2, color);
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

    const canvas = canvas: { // load canvas
        const file_zone = tracy.initZone(@src(), .{ .name = "Open file" });
        var file = try dir.openFile(config.save_file_name, .{});
        file_zone.deinit();
        defer file.close();

        var br = std.io.bufferedReader(file.reader());
        const reader = br.reader();

        break :canvas Canvas.load(gpa, reader) catch |e| {
            std.log.err("Can't load file {s}", .{@errorName(e)});

            break :canvas Canvas{};
        };
    };

    var drawer: Drawer = .{
        .target_zoom = canvas.camera.zoom,
        .gpa = gpa,
        .color_wheel = .{ .center = @splat(0), .size = 0 },
        .brush = .{
            .color = rl.Color.red,
        },
        .old_world_position = @bitCast(rl.getScreenToWorld2D(rl.getMousePosition(), canvas.camera)),
        .old_cursor_position = @bitCast(rl.getMousePosition()),
        .brush_state = .idle,
        .random = std.Random.DefaultPrng.init(0),
        .save_directory = dir,
        .canvas = canvas,
    };
    drawer.canvas.camera.offset = .init(
        @floatFromInt(@divFloor(rl.getScreenWidth(), 2)),
        @floatFromInt(@divFloor(rl.getScreenHeight(), 2)),
    );

    return drawer;
}

pub fn deinit(self: *Drawer) void {
    self.save() catch |e| {
        std.log.err("Failed to save: {s}", .{@errorName(e)});
    };
    self.save_directory.close();
    self.canvas.deinit(self.gpa);
    rl.closeWindow();
}

fn drawKeybindingsHelp(arena: std.mem.Allocator, position: Vec2) !void {
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

        fn measureText(self: @This(), text: [:0]const u8) Vec2 {
            const measurer_zone = tracy.initZone(@src(), .{ .name = "measure text" });
            defer measurer_zone.deinit();

            return @bitCast(rl.measureTextEx(
                self.font,
                text,
                self.font_size,
                self.spacing,
            ));
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
                max_width_right = @max(width_right[0], max_width_right);
            }

            const width_left = measurer.measureText(key_binding.name)[0];
            max_width_left = @max(width_left, max_width_left);
        }
        break :max_width .{ max_width_left, max_width_right };
    };

    const drawing_rect = Rectangle.init(starting_position[0], starting_position[1], max_width_left + max_width_right, help_window_height);

    rl.drawRectangleRec(
        drawing_rect.padRectangle(.{ .x = 10, .y = 10 }).toRay(),
        rl.Color.black.alpha(0.9),
    );

    inline for (comptime std.meta.declarations(config.key_bindings), 0..) |key_binding, index| {
        const name = key_binding.name;

        const y_offset: f32 = (font_size + y_spacing) * @as(f32, @floatFromInt(index));
        const pos = starting_position + Vec2{ 0, y_offset };

        {
            rl.drawTextEx(
                rl.getFontDefault(),
                name,
                @bitCast(pos),
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
                @bitCast(pos + Vec2{ max_width_left, 0 }),
                font_size,
                spacing,
                rl.Color.red,
            );
        }
    }
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
    var atomic_file = try self.save_directory.atomicFile(config.save_file_name, .{});
    defer atomic_file.deinit();
    var bw = std.io.bufferedWriter(atomic_file.file.writer());
    defer atomic_file.finish() catch |e| {
        std.log.err("Failed to copy file: {s}", .{@errorName(e)});
    };
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

    const cursor_position: Vec2 = @bitCast(rl.getMousePosition());
    const world_position: Vec2 = @bitCast(rl.getScreenToWorld2D(rl.getMousePosition(), self.canvas.camera));
    defer self.old_world_position = world_position;
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
    if (isDown(config.key_bindings.drag)) {
        self.canvas.camera.target = self.canvas.camera.target.subtract(rl.getMouseDelta().scale(1 / self.canvas.camera.zoom));
    }

    self.target_zoom *= @exp(rl.getMouseWheelMoveV().y);
    self.canvas.camera.zoom = expDecayWithAnimationSpeed(self.canvas.camera.zoom, self.target_zoom, rl.getFrameTime());

    if (isPressedRepeat(config.key_bindings.undo)) {
        if (self.canvas.history.undo()) |undo_event| {
            undo_event.undo(&self.canvas);
        }
    }
    if (isPressedRepeat(config.key_bindings.redo)) {
        if (self.canvas.history.redo()) |redo_event| {
            redo_event.redo(&self.canvas);
        }
    }

    {
        const zone = tracy.initZone(@src(), .{ .name = "Line drawing" });
        defer zone.deinit();

        self.canvas.camera.begin();
        defer self.canvas.camera.end();

        for (self.canvas.strokes.items) |stroke| {
            if (stroke.is_active and stroke.span.size >= 2) {
                const DrawType = enum {
                    none,
                    linear,
                    catmull_rom,
                };
                const draw_type: DrawType =
                    if (stroke.span.size < 4 or 1 / self.canvas.camera.zoom > stroke.width) .linear else .catmull_rom;
                switch (draw_type) {
                    .none => continue,
                    .linear => rl.drawSplineLinear(
                        @ptrCast(self.canvas.segments.items[stroke.span.start..][0..stroke.span.size]),
                        stroke.width,
                        stroke.color,
                    ),
                    .catmull_rom => {
                        rl.drawSplineCatmullRom(
                            @ptrCast(self.canvas.segments.items[stroke.span.start..][0..stroke.span.size]),
                            stroke.width,
                            stroke.color,
                        );
                    },
                }
            }
        }
    }
    // for (self.canvas.strokes.items) |stroke| {
    //     if (stroke.is_active and stroke.span.size >= 2) {
    //         const fmt_string = "{d}";
    //         var buffer: [std.fmt.count(fmt_string, .{std.math.floatMax(f32)}) + 1]u8 = undefined;
    //         const pos = rl.getWorldToScreen2D(@bitCast(self.canvas.segments.items[stroke.span.start]), self.canvas.camera);
    //         if (pos.x > -10 and pos.x < @as(f32, @floatFromInt(rl.getScreenWidth() + 100)) and
    //             pos.y > -100 and pos.y < @as(f32, @floatFromInt(rl.getScreenHeight() + 100)))
    //         {
    //             const str = try std.fmt.bufPrintZ(&buffer, fmt_string, .{stroke.width});
    //             rl.drawText(str, @intFromFloat(pos.x), @intFromFloat(pos.y), 50, .white);
    //         }
    //     }
    // }

    self.brush_state = switch (self.brush_state) {
        .idle => if (isDown(config.key_bindings.draw)) state: {
            try self.canvas.startStroke(self.gpa, self.brush.color, config.line_thickness / self.canvas.camera.zoom);
            break :state .drawing;
        } else if (isDown(config.key_bindings.eraser))
            .eraser
        else if (isPressed(config.key_bindings.picking_color)) state: {
            self.color_wheel = .{ .center = cursor_position, .size = 0 };
            break :state .picking_color;
        } else .idle,

        .drawing => state: {
            try self.canvas.addStrokePoint(
                self.gpa,
                @bitCast(world_position),
                self.canvas.camera.zoom,
            );
            break :state if (isDown(config.key_bindings.draw))
                .drawing
            else
                .idle;
        },
        .eraser => state: {
            const radius = config.eraser_thickness / 2;
            try self.canvas.erase(self.gpa, self.old_world_position, world_position, radius);

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
            20,
            10,
        });

    // Shrink color picker
    if (self.brush_state != .picking_color) {
        self.color_wheel.size = expDecayWithAnimationSpeed(self.color_wheel.size, 0, rl.getFrameTime());
        _ = self.color_wheel.draw(cursor_position);
    }

    // Draw mouse
    if (self.brush_state == .eraser) {
        rl.drawCircleLinesV(@bitCast(cursor_position), config.eraser_thickness / 2, self.brush.color);
    } else {
        rl.drawCircleV(@bitCast(cursor_position), self.brush.radius * 2, self.brush.color);
    }

    // Draw trail
    self.updateTrail();
    if (self.cursor_trail_enabled) {
        self.addTrailParticle(@bitCast(cursor_position));
        self.drawTrail();
    }

    // Draw sparks
    self.updateDrawingParticle();
    if (self.drawing_particles_enabled)
        if (self.brush_state == .drawing)
            self.addDrawingParticle(@bitCast(cursor_position));
    self.drawDrawingParticles();

    if (isDown(config.key_bindings.change_brightness)) {
        if (self.background_alpha_selector) |bar| {
            self.background_color = self.background_color.alpha(bar.draw(cursor_position));
        } else {
            self.background_alpha_selector = Bar.init(cursor_position, self.background_color.normalize().w, .{ .text = "Background alpha" });
        }
    } else {
        if (self.background_alpha_selector) |_| {
            self.background_alpha_selector = null;
        }
    }
    {
        const fmt_string = "zoom level: {d}";

        var buffer: [std.fmt.count(fmt_string, .{std.math.floatMax(f32)}) + 1]u8 = undefined;
        {
            const str = try std.fmt.bufPrintZ(&buffer, fmt_string, .{@log(self.canvas.camera.zoom)});
            rl.drawText(str, 40, 10, 50, .white);
        }
        {
            const str = try std.fmt.bufPrintZ(&buffer, fmt_string, .{1 / self.canvas.camera.zoom});
            rl.drawText(str, 40, 70, 50, .white);
        }
        const str = try std.fmt.allocPrintZ(arena.allocator(), "position: {d}x,{d}y", .{ self.canvas.camera.target.x, self.canvas.camera.target.y });
        rl.drawText(str, 40, 130, 50, .white);
    }
    if (self.showing_keybindings) {
        try drawKeybindingsHelp(arena.allocator(), .{ 100, 100 });
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

fn isPressedRepeat(keys_or_buttons: anytype) bool {
    if (!isDown(keys_or_buttons)) return false;

    inline for (keys_or_buttons) |key_or_button| {
        switch (@TypeOf(key_or_button)) {
            rl.KeyboardKey => if (rl.isKeyPressedRepeat(key_or_button) and !isModifierKey(key_or_button))
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
    center: Vec2,
    size: f32,

    fn draw(wheel: ColorWheel, pos: Vec2) rl.Color {
        if (wheel.size < 0.01) return rl.Color.blank;
        const segments = 360;
        for (0..segments) |num| {
            const frac = @as(f32, @floatFromInt(num)) / @as(f32, @floatFromInt(segments));
            const angle = frac * 360;

            const hue = frac * 360;
            rl.drawCircleSector(
                @bitCast(wheel.center),
                wheel.size,
                angle,
                angle + 360.0 / @as(comptime_float, segments),
                10,
                rl.Color.fromHSV(hue, 0.8, 0.8),
            );
        }
        const distance = @min(@sqrt(@reduce(.Add, (wheel.center - pos) * (wheel.center - pos))) / wheel.size, 1);
        const direction = pos - wheel.center;
        const angle = std.math.atan2(direction[1], direction[0]);
        return rl.Color.fromHSV(angle / std.math.tau * 360, distance, 1);
    }
};

const Bar = struct {
    orientation: Orientation,
    center: Vec2,
    min: f32,
    max: f32,
    scale: f32,
    text: [:0]const u8,
    color: rl.Color,

    const Orientation = enum {
        vertical,
        horizontal,
    };

    const Config = struct {
        min: f32 = 0,
        max: f32 = 1,
        scale: f32 = 200,
        text: [:0]const u8 = "Some ui bar",
        color: rl.Color = .gray,
        orientation: Orientation = .vertical,
    };

    fn init(pos: Vec2, value: f32, bar_config: Config) @This() {
        const top_y = pos[1] - bar_config.scale / 2;
        const persantage = (value - bar_config.min) / (bar_config.max - bar_config.min);
        return .{
            .orientation = bar_config.orientation,
            .center = .{
                pos[0] - 50,
                persantage * bar_config.scale + top_y,
            },
            .min = bar_config.min,
            .max = bar_config.max,
            .scale = bar_config.scale,
            .text = bar_config.text,
            .color = bar_config.color,
        };
    }

    fn draw(self: @This(), cursor_pos: Vec2) f32 {
        const dir_vec: Vec2 = if (self.orientation == .vertical)
            .{ 0, self.scale / 2 }
        else
            .{ self.scale / 2, 0 };

        const bar_start = self.center + dir_vec;
        const bar_end = self.center - dir_vec;
        const bar_width = 10;
        rl.drawLineEx(
            @bitCast(bar_start),
            @bitCast(bar_end),
            bar_width,
            rl.Color.gray,
        );
        const bar_size = 10;
        const clamped = std.math.clamp(cursor_pos, bar_end, bar_start);
        const bar_middle_pos: Vec2 = if (self.orientation == .vertical)
            .{ self.center[0], clamped[1] }
        else
            .{ clamped[0], self.center[1] };

        const font_size = 30;
        const text_width = rl.measureText(self.text, font_size);
        const bar_vec: Vec2 = if (self.orientation == .vertical) .{ 0, bar_size / 2 } else .{ bar_size / 2, 0 };
        if (self.orientation == .vertical)
            rl.drawText(
                self.text,
                @as(i32, @intFromFloat(self.center[0])) - text_width - bar_width,
                @as(i32, @intFromFloat(self.center[1])) - font_size / 2,
                font_size,
                .white,
            )
        else
            rl.drawText(
                self.text,
                @as(i32, @intFromFloat(self.center[0])) - @divFloor(text_width, 2),
                @as(i32, @intFromFloat(self.center[1])) - font_size - bar_width,
                font_size,
                .white,
            );
        rl.drawLineEx(
            @bitCast(bar_middle_pos + bar_vec),
            @bitCast(bar_middle_pos - bar_vec),
            bar_width,
            .red,
        );

        const scaled = (bar_start - bar_middle_pos) / @as(Vec2, @splat(self.scale));
        const selected_value = if (self.orientation == .vertical)
            scaled[1]
        else
            scaled[0];

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
