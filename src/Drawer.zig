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
    selecting,
    selected,
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
draw_grid: bool = false,

background_color: rl.Color = .blank,
background_alpha_selector: ?Bar = null,

random: std.Random.DefaultPrng,
target_zoom: f32,

start_position: ?Vec2,
selection: std.ArrayListUnmanaged(u64),

save_directory: std.fs.Dir,

fn getAppDataDirEnsurePathExist(alloc: std.mem.Allocator, appname: []const u8) ![]u8 {
    const data_dir_path = try std.fs.getAppDataDir(alloc, appname);

    std.fs.makeDirAbsolute(data_dir_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => |err| return err,
    };
    return data_dir_path;
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
        var file = dir.openFile(config.save_file_name, .{}) catch |err| switch (err) {
            error.FileNotFound => break :canvas Canvas.init,
            else => return err,
        };
        file_zone.deinit();
        defer file.close();

        var br = std.io.bufferedReader(file.reader());
        const reader = br.reader();

        break :canvas Canvas.load(gpa, reader) catch |e| {
            std.log.err("Can't load file {s}", .{@errorName(e)});

            break :canvas Canvas.init;
        };
    };

    var drawer: Drawer = .{
        .start_position = null,
        .selection = .{},
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
    drawer.canvas.camera.target = drawer.canvas.camera.target.subtract(drawer.canvas.camera.offset.subtract(rl.getMousePosition()).scale(drawer.canvas.camera.zoom));
    drawer.canvas.camera.offset = rl.getMousePosition();

    return drawer;
}

pub fn deinit(self: *Drawer) void {
    self.save() catch |e| {
        std.log.err("Failed to save: {s}", .{@errorName(e)});
    };
    self.save_directory.close();
    self.canvas.deinit(self.gpa);
    self.selection.deinit(self.gpa);
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
        const zone = tracy.initZone(@src(), .{ .name = "Tick" });
        defer zone.deinit();
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
    {
        const key_bindings = config.key_bindings;

        if (isPressed(key_bindings.toggle_keybindings)) {
            self.showing_keybindings = !self.showing_keybindings;
        } else if (isPressed(key_bindings.grid)) {
            self.draw_grid = !self.draw_grid;
        } else if (isPressed(key_bindings.reset_canvas)) {
            self.canvas.deinit(self.gpa);
            self.canvas = .init;
            self.canvas.camera.offset = .init(
                @floatFromInt(@divFloor(rl.getScreenWidth(), 2)),
                @floatFromInt(@divFloor(rl.getScreenHeight(), 2)),
            );
            self.target_zoom = self.canvas.camera.zoom;
            std.debug.print("{any}\n", .{self.canvas});
        } else if (isPressed(key_bindings.save)) {
            try self.save();
            std.log.info("Saved image", .{});
        } else if (isDown(key_bindings.drag)) {
            self.canvas.camera.target = self.canvas.camera.target.subtract(rl.getMouseDelta().scale(1 / self.canvas.camera.zoom));
        }
        const board_padding = 100000000;
        if (self.canvas.camera.target.x - self.canvas.camera.offset.x / self.canvas.camera.zoom < -board_padding) {
            self.canvas.camera.target.x = -board_padding + self.canvas.camera.offset.x / self.canvas.camera.zoom;
        }
        if (self.canvas.camera.target.y - self.canvas.camera.offset.y / self.canvas.camera.zoom < -board_padding) {
            self.canvas.camera.target.y = -board_padding + self.canvas.camera.offset.y / self.canvas.camera.zoom;
        }
        if (self.canvas.camera.target.x - self.canvas.camera.offset.x / self.canvas.camera.zoom > board_padding) {
            self.canvas.camera.target.x = board_padding + self.canvas.camera.offset.x / self.canvas.camera.zoom;
        }
        if (self.canvas.camera.target.y - self.canvas.camera.offset.y / self.canvas.camera.zoom > board_padding) {
            self.canvas.camera.target.y = board_padding + self.canvas.camera.offset.y / self.canvas.camera.zoom;
        }
        if (isPressedOrRepeat(key_bindings.undo)) {
            if (self.canvas.history.undo()) |undo_event| {
                undo_event.undo(&self.canvas);
            }
        }
        if (isPressedOrRepeat(key_bindings.redo)) {
            if (self.canvas.history.redo()) |redo_event| {
                redo_event.redo(&self.canvas);
            }
        }
    }

    const min_zoom = 1.0 / 10000.0;
    const max_zoom = 0.07;

    { // camera zoom
        self.target_zoom *= @exp(rl.getMouseWheelMoveV().y);
        self.target_zoom = std.math.clamp(self.target_zoom, min_zoom, max_zoom);
        const new_zoom = expDecayWithAnimationSpeed(self.canvas.camera.zoom, self.target_zoom, rl.getFrameTime());
        self.canvas.camera.target = self.canvas.camera.target.subtract(rl.getMouseDelta().scale(-1 / self.canvas.camera.zoom));
        self.canvas.camera.offset = rl.getMousePosition();
        self.canvas.camera.zoom = new_zoom;
    }
    {
        self.canvas.camera.begin();
        defer self.canvas.camera.end();
        {
            const zone = tracy.initZone(@src(), .{ .name = "Line drawing" });
            defer zone.deinit();

            drawCanvas(&self.canvas);
        }

        {
            const zone = tracy.initZone(@src(), .{ .name = "Draw bounding box" });
            defer zone.deinit();

            const camera_rect = cameraRect(self.canvas.camera);
            for (self.canvas.strokes.items) |stroke| {
                const bounding_box = self.canvas.calculateBoundingBoxForStroke(stroke);
                const ray_rect = rl.Rectangle{
                    .x = bounding_box.min[0],
                    .y = bounding_box.min[1],
                    .width = bounding_box.max[0] - bounding_box.min[0],
                    .height = bounding_box.max[1] - bounding_box.min[1],
                };
                if (rl.checkCollisionRecs(camera_rect, ray_rect)) {
                    // rl.drawRectangleLinesEx(ray_rect, config.line_thickness / 2 / self.canvas.camera.zoom, if (!stroke.is_active) .yellow else .blue);
                }
            }
        }
    }

    self.brush_state = switch (self.brush_state) {
        .idle => if (isDown(config.key_bindings.select)) state: {
            self.start_position = @as(Vec2, @bitCast(rl.getMousePosition()));
            break :state .selecting;
        } else if (isDown(config.key_bindings.eraser))
            .eraser
        else if (isPressed(config.key_bindings.picking_color)) state: {
            self.color_wheel = .{ .center = cursor_position, .size = 0 };
            break :state .picking_color;
        } else if (isDown(config.key_bindings.draw)) state: {
            try self.canvas.startStroke(self.gpa, self.brush.color, config.line_thickness / self.canvas.camera.zoom);
            break :state .drawing;
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
        .selecting => if (isDown(config.key_bindings.select))
            .selecting
        else blk: {
            break :blk .selected;
        },
        .selected => if (isPressed(config.key_bindings.drag)) blk: {
            self.selection.clearRetainingCapacity();
            break :blk .idle;
        } else .selected,
    };

    if (is_debug)
        debugDrawHistory(self.canvas.history, .{
            20,
            10,
        });

    // Draw grid
    if (self.draw_grid) {
        const zone = tracy.initZone(@src(), .{ .name = "Draw grid" });
        defer zone.deinit();
        for (0..8) |i| {
            drawGridScale(self.canvas.camera, std.math.pow(f32, 10, @floatFromInt(i)));
        }
    }

    // Shrink and draw color picker
    if (self.brush_state != .picking_color) {
        self.color_wheel.size = expDecayWithAnimationSpeed(self.color_wheel.size, 0, rl.getFrameTime());
        _ = self.color_wheel.draw(cursor_position);
    }

    // Draw selection
    if (self.brush_state == .selecting) draw_selection: {
        std.log.debug("Selection", .{});
        const start = self.start_position orelse break :draw_selection;
        const selection_rect: Rectangle = .fromPoints(start, @bitCast(rl.getMousePosition()));
        const selection_rect_world = selection_rect.toWorld(self.canvas.camera);
        rl.drawRectangleLinesEx(selection_rect.toRay(), 3, .gray);

        self.canvas.camera.begin();
        defer self.canvas.camera.end();

        self.selection.clearRetainingCapacity();
        var mega_bounding_box: ?Canvas.BoundingBox = null;
        for (self.canvas.strokes.items, 0..) |stroke, index| {
            if (!stroke.is_active) continue;
            const bounding_box = self.canvas.calculateBoundingBoxForStroke(stroke);
            const ray_rect = rl.Rectangle{
                .x = bounding_box.min[0],
                .y = bounding_box.min[1],
                .width = bounding_box.max[0] - bounding_box.min[0],
                .height = bounding_box.max[1] - bounding_box.min[1],
            };
            if (rl.checkCollisionRecs(ray_rect, selection_rect_world.toRay())) {
                const collision = rl.getCollisionRec(ray_rect, selection_rect_world.toRay());
                if (std.meta.eql(ray_rect, collision)) {
                    std.log.debug("Selected", .{});
                    mega_bounding_box = bounding_box.merge(mega_bounding_box);
                    rl.drawRectangleLinesEx(collision, config.line_thickness / 2 / self.canvas.camera.zoom, .red);
                    rl.drawRectangleLinesEx(ray_rect, config.line_thickness / 2 / self.canvas.camera.zoom, .blue);
                    try self.selection.append(self.gpa, index);
                }
            }
        }
        if (mega_bounding_box) |bounding_box| {
            const rect = rl.Rectangle{
                .x = bounding_box.min[0],
                .y = bounding_box.min[1],
                .width = bounding_box.max[0] - bounding_box.min[0],
                .height = bounding_box.max[1] - bounding_box.min[1],
            };
            rl.drawRectangleLinesEx(rect, config.line_thickness / 2 / self.canvas.camera.zoom, .gray);
        }
    } else if (self.brush_state == .selected) {
        self.canvas.camera.begin();
        defer self.canvas.camera.end();

        var mega_bounding_box: ?Canvas.BoundingBox = null;
        const diff: Vec2 = @bitCast(rl.getMouseDelta());
        for (self.selection.items) |selection_index| {
            const stroke = self.canvas.strokes.items[selection_index];
            if (isDown(config.key_bindings.draw)) {
                for (self.canvas.segments.items[stroke.span.start..][0..stroke.span.size]) |*segment| {
                    segment.* = @as(Vec2, segment.*) + diff * @as(Vec2, @splat(1 / self.canvas.camera.zoom));
                }
            }
            const bounding_box = self.canvas.calculateBoundingBoxForStroke(stroke);
            mega_bounding_box = bounding_box.merge(mega_bounding_box);
            const ray_rect = rl.Rectangle{
                .x = bounding_box.min[0],
                .y = bounding_box.min[1],
                .width = bounding_box.max[0] - bounding_box.min[0],
                .height = bounding_box.max[1] - bounding_box.min[1],
            };
            std.log.debug("Selected", .{});
            rl.drawRectangleLinesEx(ray_rect, config.line_thickness / 2 / self.canvas.camera.zoom, .blue);
        }
        if (mega_bounding_box) |bounding_box| {
            const rect = rl.Rectangle{
                .x = bounding_box.min[0],
                .y = bounding_box.min[1],
                .width = bounding_box.max[0] - bounding_box.min[0],
                .height = bounding_box.max[1] - bounding_box.min[1],
            };
            rl.drawRectangleLinesEx(rect, config.line_thickness / 2 / self.canvas.camera.zoom, .gray);
        }
    }
    std.debug.print("{any}\n", .{self.selection.items});

    // Draw mouse
    if (self.brush_state == .eraser) {
        rl.drawCircleLinesV(@bitCast(cursor_position), config.eraser_thickness / 2, self.brush.color);
    } else {
        rl.drawCircleV(@bitCast(cursor_position), self.brush.radius * 2, self.brush.color);
    }

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

        var buffer: [std.fmt.count(fmt_string, .{std.math.floatMax(f32)}) + 100]u8 = undefined;
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

    const zone = tracy.initZone(@src(), .{ .name = "End drawing" });
    defer zone.deinit();
    rl.endDrawing();
}

fn drawLabels(canvas: *Canvas) void {
    for (canvas.strokes.items) |stroke| {
        if (stroke.is_active and stroke.span.size >= 2) {
            const fmt_string = "{d}";
            var buffer: [std.fmt.count(fmt_string, .{std.math.floatMax(f32)}) + 100]u8 = undefined;
            const pos = rl.getWorldToScreen2D(@bitCast(canvas.segments.items[stroke.span.start]), canvas.camera);
            if (pos.x > -10 and pos.x < @as(f32, @floatFromInt(rl.getScreenWidth() + 100)) and
                pos.y > -100 and pos.y < @as(f32, @floatFromInt(rl.getScreenHeight() + 100)))
            {
                const str = try std.fmt.bufPrintZ(&buffer, fmt_string, .{stroke.width});
                rl.drawText(str, @intFromFloat(pos.x), @intFromFloat(pos.y), 50, .white);
            }
        }
    }
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

fn isPressedOrRepeat(keys_or_buttons: anytype) bool {
    return isPressedRepeat(keys_or_buttons) or isPressed(keys_or_buttons);
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

const screen_grid_size_min = 10;
const screen_grid_size_max = 1000;

pub fn drawGridScale(camera: rl.Camera2D, zoom: f32) void {
    const grid_scale: f32 = camera.zoom * zoom;
    if (screen_grid_size_min <= grid_scale and grid_scale <= screen_grid_size_max) {
        var x: f32 = @mod((-camera.target.x) * camera.zoom + camera.offset.x, grid_scale);
        var y: f32 = @mod((-camera.target.y) * camera.zoom + camera.offset.y, grid_scale);

        const color = rl.Color.white.alpha(@sqrt(grid_scale / screen_grid_size_max));

        const width: f32 = @floatFromInt(rl.getScreenWidth());
        const height: f32 = @floatFromInt(rl.getScreenHeight());

        while (x < width) : (x += grid_scale) {
            rl.drawLineV(.init(x, 0), .init(x, height), color);
        }
        while (y < height) : (y += grid_scale) {
            rl.drawLineV(.init(0, y), .init(width, y), color);
        }
    }
}

pub fn drawCanvas(canvas: *Canvas) void {
    // var buffer: [100]u8 = undefined;
    // _ = buffer; // autofix
    var counter: u32 = 0;
    const camera_rect = cameraRect(canvas.camera);
    for (canvas.strokes.items) |stroke| {
        if (stroke.is_active and stroke.span.size >= 2 and stroke.width >= 0.25 / canvas.camera.zoom) {
            // TODO: figure out how to draw nicer lines without terrible performance.
            const bounding_box = canvas.calculateBoundingBoxForStroke(stroke);
            const ray_rect = rl.Rectangle{
                .x = bounding_box.min[0],
                .y = bounding_box.min[1],
                .width = bounding_box.max[0] - bounding_box.min[0],
                .height = bounding_box.max[1] - bounding_box.min[1],
            };
            // const text = std.fmt.bufPrintZ(&buffer, "{d}", .{stroke.width}) catch "???";
            // rl.drawText(text, @intFromFloat(ray_rect.x), @intFromFloat(ray_rect.y), @intFromFloat(30 / canvas.camera.zoom), .white);
            if (!rl.checkCollisionRecs(camera_rect, ray_rect)) continue;

            counter += 1;

            const DrawType = enum {
                none,
                linear,
                catmull_rom,
            };
            const draw_type: DrawType = .linear;
            // if (stroke.span.size < 4 or 1 / canvas.camera.zoom > stroke.width) .linear else .catmull_rom;
            switch (draw_type) {
                .none => continue,
                .linear => rl.drawSplineLinear(
                    @ptrCast(canvas.segments.items[stroke.span.start..][0..stroke.span.size]),
                    stroke.width,
                    stroke.color,
                ),
                .catmull_rom => {
                    rl.drawSplineCatmullRom(
                        @ptrCast(canvas.segments.items[stroke.span.start..][0..stroke.span.size]),
                        stroke.width,
                        stroke.color,
                    );
                },
            }
        }
    }
    std.debug.print("counter {d}\n", .{counter});
    tracy.plot(u32, "Strokes drawn", counter);
}

pub fn cameraRect(camera: rl.Camera2D) rl.Rectangle {
    return .{
        .x = camera.target.x - camera.offset.x / camera.zoom,
        .y = camera.target.y - camera.offset.y / camera.zoom,
        .width = @as(f32, @floatFromInt(rl.getScreenWidth())) / camera.zoom,
        .height = @as(f32, @floatFromInt(rl.getScreenHeight())) / camera.zoom,
    };
}
