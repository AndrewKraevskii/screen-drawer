const std = @import("std");
const rl = @import("raylib");
const Allocator = std.mem.Allocator;
const TextureLoader = @import("TextureLoader.zig");

const config = struct {
    pub const app_name = "screen-drawer";

    const key_bindings = struct {
        // zig fmt: off
        pub const draw          = .{ rl.MouseButton.mouse_button_left };
        pub const draw_line     = .{ rl.KeyboardKey.key_left_control, rl.KeyboardKey.key_minus };       
        pub const eraser        = .{ rl.MouseButton.mouse_button_right };
        pub const confirm       = .{ rl.MouseButton.mouse_button_left };
        pub const picking_color = .{ rl.KeyboardKey.key_left_control, rl.KeyboardKey.key_equal };
        pub const clear         = .{ rl.KeyboardKey.key_right_bracket };
        pub const scroll_up     = .{ rl.KeyboardKey.key_left_control, rl.KeyboardKey.key_equal };
        pub const scroll_down   = .{ rl.KeyboardKey.key_left_control, rl.KeyboardKey.key_minus };
        
        pub const view_all_images = .{rl.KeyboardKey.key_left_bracket};
        pub const new_canvas = .{rl.KeyboardKey.key_n};
        // zig fmt: on

        comptime {
            for (@typeInfo(@This()).Struct.decls) |decl| {
                for (@field(key_bindings, decl.name), 0..) |key, index| {
                    if (@TypeOf(key) == rl.MouseButton or @TypeOf(key) == rl.KeyboardKey) continue;
                    @compileError("Key bindings should include rl.MouseButton or rl.KeyboardKey found: " ++
                        @typeName(@TypeOf(key)) ++ std.fmt.comptimePrint(" on position {d} in", .{index}) ++ decl.name);
                }
            }
        }
    };

    /// Set to null to disable animations.
    const animation_speed: ?comptime_int = 10;

    const hide_cursor = true;
};

const is_debug = @import("builtin").mode == .Debug;

pub const std_options = std.Options{
    .log_level = if (is_debug) .debug else .warn,
};

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    rl.setConfigFlags(.{
        .window_topmost = true,
        .window_transparent = true,
        .window_undecorated = true,
        .window_maximized = true,
        .vsync_hint = true,
    });

    rl.setTraceLogLevel(if (is_debug) .log_debug else .log_warning);

    rl.initWindow(0, 0, "Drawer");

    if (config.hide_cursor)
        rl.hideCursor();
    defer rl.closeWindow();

    const width: u31 = @intCast(rl.getScreenWidth());
    const height: u31 = @intCast(rl.getScreenHeight());

    const save_directory = try getAppDataDirEnsurePathExist(gpa, config.app_name);
    defer gpa.free(save_directory);

    var thread_pool: std.Thread.Pool = undefined;
    try thread_pool.init(.{
        .allocator = gpa,
        .n_jobs = 1,
    });
    defer thread_pool.deinit();

    var texture_loader = try TextureLoader.init(gpa, &thread_pool, save_directory);
    defer texture_loader.deinit();

    const line_thickness = 4;
    const eraser_thickness = 40;
    const wheel_target_size = 100;

    var color_wheel: ColorWheel = .{ .center = rl.Vector2.zero(), .size = 0 };
    var drawing_state: union(enum) {
        idle,
        drawing,
        drawing_line: rl.Vector2,
        eraser,
        picking_color,
        view_all_images,
    } = .view_all_images;
    var editing: ?usize = null;
    var color: rl.Color = rl.Color.red;
    const canvas = rl.loadRenderTexture(width, height);
    defer canvas.unload();

    var target_scrolling_position: i32 = 0;
    var scrolling_position: f32 = 0;

    var old_mouse_position = rl.getMousePosition();

    while (!rl.windowShouldClose() and rl.isWindowFocused()) {
        rl.beginDrawing();
        rl.clearBackground(rl.Color.blank);

        const mouse_position = rl.getMousePosition();
        defer old_mouse_position = mouse_position;

        const mouse_scroll = switch (std.math.order(rl.getMouseWheelMoveV().y, 0.0)) {
            .eq => if (isPressed(config.key_bindings.scroll_up)) std.math.Order.gt else if (isPressed(config.key_bindings.scroll_down)) std.math.Order.lt else std.math.Order.eq,
            else => |other| other,
        };

        switch (mouse_scroll) {
            .lt => target_scrolling_position += 1,
            .gt => target_scrolling_position -|= 1,
            .eq => {},
        }

        scrolling_position = expDecayWithAnimationSpeed(scrolling_position, @floatFromInt(target_scrolling_position), rl.getFrameTime());

        if (drawing_state != .view_all_images)
            rl.drawTextureRec(canvas.texture, .{
                .x = 0,
                .y = 0,
                .width = @as(f32, @floatFromInt(canvas.texture.width)),
                .height = -@as(f32, @floatFromInt(canvas.texture.height)), // negative to flip image vertically
            }, rl.Vector2.zero(), rl.Color.white);

        drawing_state = switch (drawing_state) {
            .idle => if (isDown(config.key_bindings.draw))
                .drawing
            else if (isDown(config.key_bindings.draw_line))
                .{ .drawing_line = mouse_position }
            else if (isDown(config.key_bindings.eraser))
                .eraser
            else if (isPressed(config.key_bindings.picking_color)) blk: {
                color_wheel = .{ .center = mouse_position, .size = 0 };
                break :blk .picking_color;
            } else if (isPressed(config.key_bindings.view_all_images)) blk: {
                if (editing) |old_level| {
                    std.log.info("Stored texture {?d}", .{editing});
                    try texture_loader.setTexture(old_level, canvas.texture);
                    canvas.begin();
                    rl.clearBackground(rl.Color.blank);
                    canvas.end();
                    editing = null;
                }
                break :blk .view_all_images;
            } else .idle,
            .drawing => blk: {
                canvas.begin();
                rl.drawLineEx(old_mouse_position, mouse_position, line_thickness, color);
                canvas.end();
                break :blk if (isDown(config.key_bindings.draw))
                    .drawing
                else
                    .idle;
            },
            .eraser => blk: {
                const radius = eraser_thickness / 2;
                canvas.begin();

                {
                    rl.drawCircleV(old_mouse_position, radius, rl.Color.white);

                    rl.beginBlendMode(.blend_subtract_colors);
                    rl.gl.rlSetBlendFactors(0, 0, 0);
                    {
                        rl.drawCircleV(old_mouse_position, radius, rl.Color.white);
                    }
                    rl.endBlendMode();
                }
                {
                    rl.drawCircleV(mouse_position, radius, rl.Color.white);

                    rl.beginBlendMode(.blend_subtract_colors);
                    rl.gl.rlSetBlendFactors(0, 0, 0);
                    {
                        rl.drawCircleV(mouse_position, radius, rl.Color.white);
                    }
                    rl.endBlendMode();
                }
                {
                    rl.drawLineEx(old_mouse_position, mouse_position, eraser_thickness, color);

                    rl.beginBlendMode(.blend_subtract_colors);
                    rl.gl.rlSetBlendFactors(0, 0, 0);
                    {
                        rl.drawLineEx(old_mouse_position, mouse_position, eraser_thickness, color);
                    }
                    rl.endBlendMode();
                }
                canvas.end();

                break :blk if (isDown(config.key_bindings.eraser)) .eraser else .idle;
            },
            .drawing_line => |old_position| blk: {
                drawNiceLine(old_position, mouse_position, line_thickness, color);
                if (!isDown(config.key_bindings.draw_line)) {
                    canvas.begin();
                    drawNiceLine(old_position, mouse_position, line_thickness, color);
                    canvas.end();
                    break :blk .idle;
                }
                break :blk drawing_state;
            },
            .picking_color => blk: {
                color = color_wheel.draw(mouse_position);
                break :blk if (isPressed(config.key_bindings.picking_color))
                    .idle
                else {
                    color_wheel.size = expDecayWithAnimationSpeed(color_wheel.size, wheel_target_size, rl.getFrameTime());
                    break :blk .picking_color;
                };
            },
            .view_all_images => blk: {
                if (isPressed(config.key_bindings.new_canvas)) {
                    try texture_loader.addTexture(canvas.texture);
                }
                const padding = rl.Vector2.init(50, 50);
                const screen_size = rl.Vector2.init(@floatFromInt(width), @floatFromInt(height));

                const images_on_one_row = 4;

                const texture_size = screen_size.subtract(padding).scale(1.0 / @as(f32, @floatFromInt(images_on_one_row))).subtract(padding);
                const start_image: usize = @min(@abs(@max(0, target_scrolling_position)), @as(usize, @intFromFloat(@max(@floor(scrolling_position), 0))) -| 1) * images_on_one_row;

                if (target_scrolling_position < 0) {
                    target_scrolling_position = 0;
                }

                const num_of_images = texture_loader.images.items.len;
                const number_of_rows_including_add_button = std.math.divCeil(
                    usize,
                    num_of_images + 1,
                    images_on_one_row,
                ) catch unreachable;
                if (target_scrolling_position >= number_of_rows_including_add_button) {
                    target_scrolling_position = @intCast(number_of_rows_including_add_button - 1);
                }
                const images_to_display = images_on_one_row * images_on_one_row;
                var index: usize = @intCast(@max(0, start_image));
                while (index < @min(start_image + images_to_display, texture_loader.images.items.len)) : (index += 1) {
                    const col = index % images_on_one_row;
                    const row = @as(f32, @floatFromInt(index / images_on_one_row)) - scrolling_position;
                    const pos = padding.add(
                        rl.Vector2.init(@floatFromInt(col), row)
                            .multiply(texture_size.add(padding)),
                    );

                    const maybe_texture = texture_loader.getTexture(index);

                    const border_size = rl.Vector2{ .x = 10, .y = 10 };
                    const backdrop_size = texture_size.add(border_size.scale(2));
                    const backdrop_pos = pos.subtract(border_size);
                    const backdrop_rect = rl.Rectangle{
                        .x = backdrop_pos.x,
                        .y = backdrop_pos.y,
                        .width = backdrop_size.x,
                        .height = backdrop_size.y,
                    };

                    const cross_size = 40;
                    const cross_rectangle = rl.Rectangle{
                        .x = backdrop_pos.x + backdrop_size.x - cross_size,
                        .y = backdrop_pos.y,
                        .width = cross_size,
                        .height = cross_size,
                    };

                    const hovering_cross = rectanglePointCollision(mouse_position, cross_rectangle);
                    const hovering_rectangle = rectanglePointCollision(mouse_position, backdrop_rect);

                    if (hovering_cross and isPressed(config.key_bindings.confirm)) {
                        try texture_loader.removeTexture(index);
                        continue;
                    }

                    if (hovering_rectangle and isPressed(config.key_bindings.confirm)) {
                        editing = index;
                        std.log.info("Now editing {d} level", .{index});
                        canvas.begin();
                        rl.clearBackground(rl.Color.blank);
                        if (maybe_texture) |texture| texture.draw(0, 0, rl.Color.white);
                        canvas.end();
                        break :blk .idle;
                    }

                    const border_color = if (hovering_rectangle and !hovering_cross)
                        rl.Color.light_gray
                    else
                        rl.Color.gray;

                    rl.drawRectangleRec(backdrop_rect, rl.Color.black.alpha(0.6));
                    rl.drawRectangleLinesEx(backdrop_rect, 3, border_color);

                    if (maybe_texture) |t| t.drawPro(.{
                        .x = 0,
                        .y = 0,
                        .width = @floatFromInt(t.width),
                        .height = @floatFromInt(t.height),
                    }, .{
                        .x = pos.x,
                        .y = pos.y,
                        .width = texture_size.x,
                        .height = texture_size.y,
                    }, rl.Vector2.zero(), 0, rl.Color.white);

                    { // Draw cross
                        rl.drawRectangleRec(cross_rectangle, rl.Color.red);
                        const thickness = 3;
                        const cross_color = if (hovering_cross) rl.Color.white else rl.Color.black;
                        rl.drawLineEx(.{
                            .x = cross_rectangle.x,
                            .y = cross_rectangle.y,
                        }, .{
                            .x = cross_rectangle.x + cross_size,
                            .y = cross_rectangle.y + cross_size,
                        }, thickness, cross_color);
                        rl.drawLineEx(.{
                            .x = cross_rectangle.x + cross_size,
                            .y = cross_rectangle.y,
                        }, .{
                            .x = cross_rectangle.x,
                            .y = cross_rectangle.y + cross_size,
                        }, thickness, cross_color);
                    }
                    flushRaylib();
                }
                const col = index % images_on_one_row;
                const row = @as(f32, @floatFromInt(index / images_on_one_row)) - scrolling_position;
                const pos = padding.add(
                    rl.Vector2.init(@floatFromInt(col), row)
                        .multiply(texture_size.add(padding)),
                );

                const border_size = rl.Vector2{ .x = 10, .y = 10 };
                const backdrop_size = texture_size.add(border_size.scale(2));
                const backdrop_pos = pos.subtract(border_size);
                const backdrop_rect = rl.Rectangle{
                    .x = backdrop_pos.x,
                    .y = backdrop_pos.y,
                    .width = backdrop_size.x,
                    .height = backdrop_size.y,
                };

                const hovering_rectangle = rectanglePointCollision(mouse_position, backdrop_rect);
                if (hovering_rectangle and isPressed(config.key_bindings.confirm)) {
                    try texture_loader.addTexture(canvas.texture);
                }

                rl.drawRectangleLinesEx(backdrop_rect, 3, if (hovering_rectangle)
                    rl.Color.light_gray
                else
                    rl.Color.gray);

                {
                    const cross_color = rl.Color.white;
                    const middle_pos = rl.Vector2.init(backdrop_rect.x + backdrop_rect.width / 2, backdrop_rect.y + backdrop_rect.height / 2);
                    const thickness = 3;
                    const half_plus_size = 10;
                    const half_backdrop_size = 30;
                    rl.drawRectangleRec(.{
                        .x = middle_pos.x - half_backdrop_size,
                        .y = middle_pos.y - half_backdrop_size,
                        .width = half_backdrop_size * 2,
                        .height = half_backdrop_size * 2,
                    }, rl.Color.dark_gray);
                    rl.drawLineEx(.{
                        .x = middle_pos.x - half_plus_size,
                        .y = middle_pos.y,
                    }, .{
                        .x = middle_pos.x + half_plus_size,
                        .y = middle_pos.y,
                    }, thickness, cross_color);
                    rl.drawLineEx(.{
                        .x = middle_pos.x,
                        .y = middle_pos.y - half_plus_size,
                    }, .{
                        .x = middle_pos.x,
                        .y = middle_pos.y + half_plus_size,
                    }, thickness, cross_color);
                }
                flushRaylib();

                break :blk .view_all_images;
            },
        };
        if (drawing_state != .picking_color) {
            color_wheel.size = expDecayWithAnimationSpeed(color_wheel.size, 0, rl.getFrameTime());
            _ = color_wheel.draw(mouse_position);
        }

        if (isDown(config.key_bindings.clear)) {
            canvas.begin();
            rl.clearBackground(rl.Color.blank);
            canvas.end();
        }
        if (drawing_state == .eraser) {
            rl.drawCircleLinesV(mouse_position, eraser_thickness / 2, color);
        } else {
            rl.drawCircleV(mouse_position, line_thickness * 2, color);
        }

        if (@import("builtin").mode == .Debug)
            rl.drawFPS(0, 0);
        rl.endDrawing();
    }

    if (editing) |level| {
        std.log.info("Stored texture {d}", .{level});
        try texture_loader.setTexture(level, canvas.texture);
    }
}

const ColorWheel = struct {
    center: rl.Vector2,
    size: f32,

    pub fn draw(wheel: ColorWheel, pos: rl.Vector2) rl.Color {
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
        return rl.Color.fromHSV(-wheel.center.lineAngle(pos) / std.math.tau * 360, 1, 1);
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

fn getColorHash(value: anytype) rl.Color {
    const hash = std.hash.Fnv1a_32.hash(std.mem.asBytes(&value));
    const color: rl.Color = @bitCast(hash);
    const hsv = color.toHSV();
    return rl.Color.fromHSV(hsv.x, hsv.y, 1);
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

fn rectanglePointCollision(point: rl.Vector2, rect: rl.Rectangle) bool {
    return point.x >= rect.x and point.y > rect.y and
        point.x < rect.x + rect.width and point.y < rect.y + rect.height;
}

fn flushRaylib() void {
    rl.beginMode2D(std.mem.zeroes(rl.Camera2D));
    rl.endMode2D();
}

fn getAppDataDirEnsurePathExist(alloc: Allocator, appname: []const u8) ![]u8 {
    const data_dir_path = try std.fs.getAppDataDir(alloc, appname);

    std.fs.makeDirAbsolute(data_dir_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => |err| return err,
    };
    return data_dir_path;
}

test {
    _ = std.testing.refAllDecls(@This());
}
