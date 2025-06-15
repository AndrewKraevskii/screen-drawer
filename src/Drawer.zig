const std = @import("std");

const rl = @import("raylib");

const Canvas = @import("Canvas.zig");
const input = @import("input.zig");
const is_debug = @import("main.zig").is_debug;
const main = @import("main.zig");
const config = main.config;
const Vec2 = main.Vector2;
const animation = @import("animation.zig");
const Rectangle = @import("Rectangle.zig");
const UILayout = @import("UILayout.zig");

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
    radius: f32,
    color: rl.Color,
},

canvases: Canvases,
selected_canvas: ?usize,
old_world_position: Vec2,
old_cursor_position: Vec2,

flags: Flags,
background_color: rl.Color,
background_alpha_selector: ?Bar,

target_zoom: f32,

selection_start_position: ?Vec2,
selection: std.ArrayListUnmanaged(u64),

save_directory: std.fs.Dir,
random: std.Random.DefaultPrng,

const Flags = struct {
    showing_keybindings: bool,
    draw_grid: bool,
};

const Canvases = std.StringArrayHashMapUnmanaged(Canvas);

pub fn init(gpa: std.mem.Allocator) !Drawer {
    rl.setConfigFlags(.{
        .window_topmost = config.is_topmost,
        .window_transparent = true,
        .window_undecorated = true,
        .window_maximized = true,
        // .vsync_hint = true,
        .msaa_4x_hint = true,
    });
    rl.setTraceLogLevel(if (is_debug) .debug else .warning);

    rl.initWindow(0, 0, config.app_name);
    rl.enableEventWaiting();

    errdefer rl.closeWindow();

    const dir_path = try getAppDataDirEnsurePathExist(gpa, config.save_folder_name);
    defer gpa.free(dir_path);

    var dir = try std.fs.openDirAbsolute(dir_path, .{
        .iterate = true,
    });
    errdefer dir.close();

    const canvases = canvases: {
        var canvases: Canvases = .empty;
        errdefer {
            for (canvases.values(), canvases.keys()) |*canvas, name| {
                canvas.deinit(gpa);
                gpa.free(name);
            }
            canvases.deinit(gpa);
        }

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file or
                !std.mem.eql(u8, std.fs.path.extension(entry.name), "." ++ config.save_format_magic)) continue;
            const name_without_extension = entry.name[0 .. entry.name.len - ("." ++ config.save_format_magic).len];

            const canvas = loadCanvas(gpa, dir, entry.name) catch continue;
            try canvases.putNoClobber(gpa, try gpa.dupe(u8, name_without_extension), canvas);
        }

        break :canvases canvases;
    };

    const canvas = if (canvases.values().len != 0) canvas: {
        const canvas = &canvases.values()[0];

        // initial position of mouse is 0,0 so we need to reset it
        canvas.camera.target = canvas.camera.target.subtract(canvas.camera.offset.scale(1 / canvas.camera.zoom));
        canvas.camera.offset = .{ .x = 0, .y = 0 };
        break :canvas canvas;
    } else &Canvas.init;

    const drawer: Drawer = .{
        .background_color = .blank,
        .background_alpha_selector = null,
        .flags = .{
            .draw_grid = false,
            .showing_keybindings = false,
        },
        .random = .init(std.crypto.random.int(u64)),
        .selection_start_position = null,
        .selection = .{},
        .target_zoom = canvas.camera.zoom,
        .gpa = gpa,
        .color_wheel = .{ .center = @splat(0), .size = 0 },
        .brush = .{
            .color = .red,
            .radius = config.line_thickness,
        },
        .old_world_position = @bitCast(rl.getScreenToWorld2D(rl.getMousePosition(), canvas.camera)),
        .old_cursor_position = @bitCast(rl.getMousePosition()),
        .brush_state = .idle,
        .save_directory = dir,
        .selected_canvas = if (canvases.values().len != 0) 0 else null,
        .canvases = canvases,
    };

    return drawer;
}

pub fn getMouseDelta(self: *const Drawer) rl.Vector2 {
    return @bitCast(@as(Vec2, @bitCast(rl.getMousePosition())) - self.old_cursor_position);
}

pub fn deinit(self: *Drawer) void {
    rl.disableEventWaiting();
    for (self.canvases.values(), self.canvases.keys()) |*canvas, name| {
        var name_with_extension_buffer: [std.fs.max_name_bytes]u8 = undefined;
        const name_with_extension = std.fmt.bufPrint(&name_with_extension_buffer, "{s}.{s}", .{ name, config.save_format_magic }) catch unreachable;

        saveCanvas(self.save_directory, name_with_extension, canvas) catch |e| {
            std.log.err("Failed to save: {s}", .{@errorName(e)});
        };
        canvas.deinit(self.gpa);
        self.gpa.free(name);
    }
    self.save_directory.close();
    self.canvases.deinit(self.gpa);
    self.selection.deinit(self.gpa);
    rl.closeWindow();

    self.* = undefined;
}

fn drawKeybindingsHelp(arena: std.mem.Allocator, position: Vec2) !void {
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
            return @bitCast(rl.measureTextEx(
                self.font,
                text,
                self.font_size,
                self.spacing,
            ));
        }
    } = .{ .font = rl.getFontDefault() catch @panic("font should be there"), .spacing = spacing, .font_size = font_size };

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
                rl.getFontDefault() catch @panic("font should be there"),
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
                rl.getFontDefault() catch @panic("font should be there"),
                string_builder.items[0 .. string_builder.items.len - 1 :0],
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
        try updateAndRender(self);
    }
}

fn saveCanvas(dir: std.fs.Dir, name: []const u8, canvas: *Canvas) !void {
    var atomic_file = try dir.atomicFile(name, .{});
    defer atomic_file.deinit();

    var bw = std.io.bufferedWriter(atomic_file.file.writer());
    const writer = bw.writer();

    try canvas.save(writer);

    bw.flush() catch |e| {
        std.log.err("Failed to save: {s}", .{@errorName(e)});
    };
    atomic_file.finish() catch |e| {
        std.log.err("Failed to copy file: {s}", .{@errorName(e)});
    };
}

fn loadCanvas(alloc: std.mem.Allocator, dir: std.fs.Dir, file_path: []const u8) !Canvas {
    var file = try dir.openFile(file_path, .{});
    defer file.close();

    var br = std.io.bufferedReader(file.reader());
    const reader = br.reader();

    return Canvas.load(alloc, reader) catch |e| {
        std.log.err("Can't load file {s}", .{@errorName(e)});
        return e;
    };
}

fn updateAndRender(drawer: *Drawer) !void {
    var maybe_canvas: ?*Canvas = if (drawer.selected_canvas) |selected_canvas|
        &drawer.canvases.values()[selected_canvas]
    else
        null;

    var arena = std.heap.ArenaAllocator.init(drawer.gpa);
    defer arena.deinit();

    rl.beginDrawing();
    rl.clearBackground(drawer.background_color);

    var animation_playing = false;
    // global input
    {
        const key_bindings = config.key_bindings;

        if (input.isPressed(key_bindings.toggle_keybindings)) {
            drawer.flags.showing_keybindings = !drawer.flags.showing_keybindings;
        } else if (input.isPressed(key_bindings.grid)) {
            drawer.flags.draw_grid = !drawer.flags.draw_grid;
        } else if (input.isPressed(key_bindings.reset_canvas)) {
            if (maybe_canvas) |canvas| {
                drawer.selection.clearRetainingCapacity();
                canvas.deinit(drawer.gpa);
                canvas.* = .init;
                canvas.camera.offset = .init(
                    @floatFromInt(@divFloor(rl.getScreenWidth(), 2)),
                    @floatFromInt(@divFloor(rl.getScreenHeight(), 2)),
                );
                drawer.target_zoom = canvas.camera.zoom;
                std.debug.print("{any}\n", .{canvas});
            }
        } else if (input.isPressed(key_bindings.save)) {
            if (drawer.selected_canvas) |canvas_index|
                try saveCanvas(
                    drawer.save_directory,
                    drawer.canvases.keys()[canvas_index],
                    &drawer.canvases.values()[canvas_index],
                );
            std.log.info("Saved image", .{});
        } else if (input.isPressed(key_bindings.@"export")) {
            if (drawer.selected_canvas) |canvas_index| {
                const file = try std.fs.cwd().createFile("exported.excalidraw", .{});
                defer file.close();

                var buffered = std.io.bufferedWriter(file.writer());
                defer buffered.flush() catch {};

                try @import("excalidraw.zig").@"export"(
                    &drawer.canvases.values()[canvas_index],
                    buffered.writer(),
                );
            }
            std.log.info("Saved image", .{});
        } else if (maybe_canvas) |canvas| {
            if (input.isPressedOrRepeat(key_bindings.undo)) {
                if (canvas.history.undo()) |undo_event| {
                    undo_event.undo(canvas);
                }
            }
            if (input.isPressedOrRepeat(key_bindings.redo)) {
                if (canvas.history.redo()) |redo_event| {
                    redo_event.redo(canvas);
                }
            }
        }
        if (rl.isKeyPressed(.n)) {
            try drawer.canvases.ensureUnusedCapacity(drawer.gpa, 1);
            const name = generateBase64String(11, drawer.random.random());
            std.log.info("Created new canvas: {s}", .{name});

            drawer.canvases.putAssumeCapacityNoClobber(
                try drawer.gpa.dupe(u8, &name),
                .init,
            );
            drawer.selected_canvas = drawer.canvases.count() - 1;
            maybe_canvas = &drawer.canvases.values()[drawer.selected_canvas.?];
        }
    }
    const cursor_position: Vec2 = @bitCast(rl.getMousePosition());
    if (maybe_canvas) |canvas| {
        const world_position: Vec2 = @bitCast(rl.getScreenToWorld2D(rl.getMousePosition(), canvas.camera));
        defer drawer.old_world_position = world_position;
        defer drawer.old_cursor_position = cursor_position;
        {
            if (input.isDown(config.key_bindings.drag)) {
                canvas.camera.target = canvas.camera.target.subtract(drawer.getMouseDelta().scale(1 / canvas.camera.zoom));
            }
            // move camera zoom
            const board_padding = 100000000;
            clampCameraPosition(
                &canvas.camera,
                board_padding,
            );
            const min_zoom = 1.0 / 10000.0;
            const max_zoom = 0.07;

            drawer.target_zoom *= @exp(rl.getMouseWheelMoveV().y);
            drawer.target_zoom = std.math.clamp(drawer.target_zoom, min_zoom, max_zoom);
            const new_zoom = animation.expDecayWithAnimationSpeed(canvas.camera.zoom, drawer.target_zoom, rl.getFrameTime(), &animation_playing);
            canvas.camera.target = canvas.camera.target.subtract(drawer.getMouseDelta().scale(-1 / canvas.camera.zoom));
            canvas.camera.offset = rl.getMousePosition();
            canvas.camera.zoom = new_zoom;
        }

        { // draw canvas
            // rl.loadRenderTexture();
            canvas.camera.begin();
            defer canvas.camera.end();
            drawCanvas(canvas);
        }

        drawer.brush_state = switch (drawer.brush_state) {
            .idle => if (input.isDown(config.key_bindings.select)) state: {
                drawer.selection_start_position = @as(Vec2, @bitCast(rl.getMousePosition()));
                break :state .selecting;
            } else if (input.isDown(config.key_bindings.eraser))
                .eraser
            else if (input.isPressed(config.key_bindings.picking_color)) state: {
                drawer.color_wheel = .{ .center = cursor_position, .size = 0 };
                break :state .picking_color;
            } else if (input.isDown(config.key_bindings.draw)) state: {
                try canvas.startStroke(drawer.gpa, drawer.brush.color, config.line_thickness / canvas.camera.zoom);
                break :state .drawing;
            } else .idle,

            .drawing => state: {
                try canvas.addStrokePoint(
                    drawer.gpa,
                    @bitCast(world_position),
                    canvas.camera.zoom,
                );
                break :state if (input.isDown(config.key_bindings.draw))
                    .drawing
                else
                    .idle;
            },
            .eraser => state: {
                const radius = config.eraser_thickness / 2;
                std.log.debug("eraser strokes {d}", .{canvas.strokes.items.len});
                std.log.debug("eraser segments {d}", .{canvas.segments.items.len});
                try canvas.erase(drawer.gpa, drawer.old_world_position, world_position, radius);
                std.log.debug("eraser strokes {d}", .{canvas.strokes.items.len});
                std.log.debug("eraser segments {d}", .{canvas.segments.items.len});

                break :state if (input.isDown(config.key_bindings.eraser)) .eraser else .idle;
            },
            .picking_color => state: {
                drawer.brush.color = drawer.color_wheel.draw(cursor_position);
                break :state if (!input.isDown(config.key_bindings.picking_color))
                    .idle
                else {
                    drawer.color_wheel.size = animation.expDecayWithAnimationSpeed(
                        drawer.color_wheel.size,
                        config.color_wheel_size,
                        rl.getFrameTime(),
                        &animation_playing,
                    );
                    break :state .picking_color;
                };
            },
            .selecting => if (input.isDown(config.key_bindings.select))
                .selecting
            else blk: {
                break :blk .selected;
            },
            .selected => if (input.isPressed(config.key_bindings.drag)) blk: {
                drawer.selection.clearRetainingCapacity();
                break :blk .idle;
            } else .selected,
        };

        if (is_debug)
            debugDrawHistory(canvas.history, .{
                20,
                10,
            });

        // Draw grid
        if (drawer.flags.draw_grid) {
            for (0..8) |i| {
                drawGridScale(canvas.camera, std.math.pow(f32, 10, @floatFromInt(i)));
            }
        }

        // Shrink and draw color picker
        if (drawer.brush_state != .picking_color) {
            drawer.color_wheel.size = animation.expDecayWithAnimationSpeed(drawer.color_wheel.size, 0, rl.getFrameTime(), &animation_playing);
            _ = drawer.color_wheel.draw(cursor_position);
        }

        // Draw selection
        if (drawer.brush_state == .selecting) draw_selection: {
            std.log.debug("Selection", .{});
            const start = drawer.selection_start_position orelse break :draw_selection;
            const selection_rect: Rectangle = .fromPoints(start, @bitCast(rl.getMousePosition()));
            const selection_rect_world = selection_rect.toWorld(canvas.camera);
            rl.drawRectangleLinesEx(selection_rect.toRay(), 3, .gray);

            canvas.camera.begin();
            defer canvas.camera.end();

            drawer.selection.clearRetainingCapacity();
            var mega_bounding_box: ?Canvas.BoundingBox = null;
            for (canvas.strokes.items, 0..) |stroke, index| {
                if (!stroke.is_active) continue;
                const bounding_box = canvas.calculateBoundingBoxForStroke(stroke);
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
                        rl.drawRectangleLinesEx(collision, config.line_thickness / 2 / canvas.camera.zoom, .red);
                        rl.drawRectangleLinesEx(ray_rect, config.line_thickness / 2 / canvas.camera.zoom, .blue);
                        try drawer.selection.append(drawer.gpa, index);
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
                rl.drawRectangleLinesEx(rect, config.line_thickness / 2 / canvas.camera.zoom, .gray);
            }
        } else if (drawer.brush_state == .selected) {
            canvas.camera.begin();
            defer canvas.camera.end();

            var mega_bounding_box: ?Canvas.BoundingBox = null;
            const diff: Vec2 = @bitCast(drawer.getMouseDelta());
            for (drawer.selection.items) |selection_index| {
                std.log.debug("strokes {d}", .{canvas.strokes.items.len});
                std.log.debug("segments {d}", .{canvas.segments.items.len});
                const stroke = canvas.strokes.items[selection_index];
                if (input.isDown(config.key_bindings.draw)) {
                    for (canvas.segments.items[stroke.span.start..][0..stroke.span.size]) |*segment| {
                        segment.* = @as(Vec2, segment.*) + diff * @as(Vec2, @splat(1 / canvas.camera.zoom));
                    }
                }
                const bounding_box = canvas.calculateBoundingBoxForStroke(stroke);
                mega_bounding_box = bounding_box.merge(mega_bounding_box);
                const ray_rect = rl.Rectangle{
                    .x = bounding_box.min[0],
                    .y = bounding_box.min[1],
                    .width = bounding_box.max[0] - bounding_box.min[0],
                    .height = bounding_box.max[1] - bounding_box.min[1],
                };
                std.log.debug("Selected", .{});
                rl.drawRectangleLinesEx(ray_rect, config.line_thickness / 2 / canvas.camera.zoom, .blue);
            }
            if (mega_bounding_box) |bounding_box| {
                const rect = rl.Rectangle{
                    .x = bounding_box.min[0],
                    .y = bounding_box.min[1],
                    .width = bounding_box.max[0] - bounding_box.min[0],
                    .height = bounding_box.max[1] - bounding_box.min[1],
                };
                rl.drawRectangleLinesEx(rect, config.line_thickness / 2 / canvas.camera.zoom, .gray);
            }
        }
    }

    // Draw mouse
    if (drawer.brush_state == .eraser) {
        rl.drawCircleLinesV(@bitCast(cursor_position), config.eraser_thickness / 2, drawer.brush.color);
    } else {
        rl.drawCircleV(@bitCast(cursor_position), drawer.brush.radius * 2, drawer.brush.color);
    }

    if (input.isDown(config.key_bindings.change_brightness)) {
        if (drawer.background_alpha_selector) |bar| {
            drawer.background_color = drawer.background_color.alpha(bar.draw(cursor_position));
        } else {
            drawer.background_alpha_selector = Bar.init(cursor_position, drawer.background_color.normalize().w, .{ .text = "Background alpha" });
        }
    } else {
        drawer.background_alpha_selector = null;
    }

    if (drawer.flags.showing_keybindings) {
        try drawKeybindingsHelp(arena.allocator(), .{ 100, 100 });
    }

    if (is_debug) {
        var layout: UILayout = .{
            .position = .{ 10, 50 },
            .font = 40,
        };
        if (maybe_canvas) |canvas| {
            layout.drawText("zoom level: {d}", .{@log(canvas.camera.zoom)});
            layout.drawText("zoom level: {d}", .{1 / canvas.camera.zoom});
            layout.drawText("position: {d}x,{d}y", .{ canvas.camera.target.x, canvas.camera.target.y });
            layout.drawText("canvas name {s}", .{drawer.canvases.keys()[drawer.selected_canvas.?]});
        }
        rl.drawFPS(0, 0);
    }

    if (animation_playing) {
        rl.disableEventWaiting();
    } else {
        rl.enableEventWaiting();
    }

    rl.endDrawing();
}

fn generateBase64String(comptime output_size: usize, random: std.Random) [output_size]u8 {
    var output: [output_size]u8 = undefined;
    for (&output) |*char| {
        char.* = std.base64.url_safe_alphabet_chars[random.intRangeLessThan(usize, 0, 64)];
    }
    return output;
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

    fn draw(bar: @This(), cursor_pos: Vec2) f32 {
        const dir_vec: Vec2 = if (bar.orientation == .vertical)
            .{ 0, bar.scale / 2 }
        else
            .{ bar.scale / 2, 0 };

        const bar_start = bar.center + dir_vec;
        const bar_end = bar.center - dir_vec;
        const bar_width = 10;
        rl.drawLineEx(
            @bitCast(bar_start),
            @bitCast(bar_end),
            bar_width,
            rl.Color.gray,
        );
        const bar_size = 10;
        const clamped = std.math.clamp(cursor_pos, bar_end, bar_start);
        const bar_middle_pos: Vec2 = if (bar.orientation == .vertical)
            .{ bar.center[0], clamped[1] }
        else
            .{ clamped[0], bar.center[1] };

        const font_size = 30;
        const text_width = rl.measureText(bar.text, font_size);
        const bar_vec: Vec2 = if (bar.orientation == .vertical) .{ 0, bar_size / 2 } else .{ bar_size / 2, 0 };
        if (bar.orientation == .vertical)
            rl.drawText(
                bar.text,
                @as(i32, @intFromFloat(bar.center[0])) - text_width - bar_width,
                @as(i32, @intFromFloat(bar.center[1])) - font_size / 2,
                font_size,
                .white,
            )
        else
            rl.drawText(
                bar.text,
                @as(i32, @intFromFloat(bar.center[0])) - @divFloor(text_width, 2),
                @as(i32, @intFromFloat(bar.center[1])) - font_size - bar_width,
                font_size,
                .white,
            );
        rl.drawLineEx(
            @bitCast(bar_middle_pos + bar_vec),
            @bitCast(bar_middle_pos - bar_vec),
            bar_width,
            .red,
        );

        const scaled = (bar_start - bar_middle_pos) / @as(Vec2, @splat(bar.scale));
        const selected_value = if (bar.orientation == .vertical)
            scaled[1]
        else
            scaled[0];

        return selected_value * (bar.max - bar.min) + bar.min;
    }
};

const screen_grid_size_min = 10;
const screen_grid_size_max = 1000;

fn drawGridScale(camera: rl.Camera2D, zoom: f32) void {
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

fn drawCanvas(canvas: *Canvas) void {
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
}

fn clampCameraPosition(camera: *rl.Camera2D, board_padding: f32) void {
    const target = &camera.target;
    const offset = &camera.offset;
    const zoom = camera.zoom;

    if (target.x - offset.x / zoom < -board_padding) {
        target.x = -board_padding + offset.x / zoom;
    }
    if (target.y - offset.y / zoom < -board_padding) {
        target.y = -board_padding + offset.y / zoom;
    }
    if (target.x - offset.x / zoom > board_padding) {
        target.x = board_padding + offset.x / zoom;
    }
    if (target.y - offset.y / zoom > board_padding) {
        target.y = board_padding + offset.y / zoom;
    }
}

fn cameraRect(camera: rl.Camera2D) rl.Rectangle {
    return .{
        .x = camera.target.x - camera.offset.x / camera.zoom,
        .y = camera.target.y - camera.offset.y / camera.zoom,
        .width = @as(f32, @floatFromInt(rl.getScreenWidth())) / camera.zoom,
        .height = @as(f32, @floatFromInt(rl.getScreenHeight())) / camera.zoom,
    };
}

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
        rl.drawTextEx(rl.getFontDefault() catch @panic("font should be there"), text, @bitCast(pos + Vec2{ 0, y_offset }), font_size, 2, color);
    }
}
