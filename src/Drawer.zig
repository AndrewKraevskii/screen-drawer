const std = @import("std");
const rl = @import("raylib");
const Allocator = std.mem.Allocator;
const AssetLoader = @import("AssetLoader.zig");
const main = @import("main.zig");
const getAppDataDirEnsurePathExist = main.getAppDataDirEnsurePathExist;
const config = main.config;
const is_debug = @import("builtin").mode == .Debug;

gpa: std.mem.Allocator,
thread_pool: *std.Thread.Pool,
save_directory: []const u8,
asset_loader: AssetLoader,
drawing_state: union(enum) {
    idle,
    drawing,
    drawing_line: rl.Vector2,
    eraser,
    picking_color,
    view_all_images,
} = .view_all_images,
color_wheel: ColorWheel,
painting_color: rl.Color,
editing: ?usize = null,
scrolling: struct {
    target: f32 = 0,
    current: f32 = 0,
} = .{},
canvas: rl.RenderTexture,
old_mouse_position: rl.Vector2,

pub fn init(gpa: std.mem.Allocator, thread_pool: *std.Thread.Pool) !@This() {
    rl.setConfigFlags(.{
        .window_topmost = true,
        .window_transparent = true,
        .window_undecorated = true,
        .window_maximized = true,
        .vsync_hint = true,
    });

    rl.setTraceLogLevel(if (is_debug) .log_debug else .log_warning);

    rl.initWindow(0, 0, "Drawer");
    if (main.config.hide_cursor)
        rl.hideCursor();

    const save_directory = try getAppDataDirEnsurePathExist(gpa, config.app_name);

    const asset_loader = try AssetLoader.init(gpa, thread_pool, save_directory);

    const width: u31 = @intCast(rl.getScreenWidth());
    const height: u31 = @intCast(rl.getScreenHeight());
    const canvas = rl.loadRenderTexture(width, height);
    return .{
        .gpa = gpa,
        .save_directory = save_directory,
        .thread_pool = thread_pool,
        .asset_loader = asset_loader,
        .color_wheel = .{ .center = rl.Vector2.zero(), .size = 0 },
        .painting_color = rl.Color.red,
        .canvas = canvas,
        .old_mouse_position = rl.getMousePosition(),
    };
}

pub fn deinit(self: *@This()) void {
    self.gpa.free(self.save_directory);
    self.asset_loader.deinit();
    self.canvas.unload();
    rl.closeWindow();
}

pub fn run(self: *@This()) !void {
    while (!rl.windowShouldClose() and rl.isWindowFocused()) {
        try tick(self);
    }

    if (self.editing) |level| {
        std.log.info("Stored texture {d}", .{level});
        try self.asset_loader.setTexture(level, self.canvas.texture);
    }
}

pub fn tick(self: *@This()) !void {
    rl.beginDrawing();
    rl.clearBackground(rl.Color.blank);

    const mouse_position = rl.getMousePosition();
    defer self.old_mouse_position = mouse_position;

    if (self.drawing_state == .view_all_images) {
        var scroll = rl.getMouseWheelMoveV().y;
        if (std.math.approxEqAbs(f32, scroll, 0, 0.1)) {
            scroll += @floatFromInt(@intFromBool(isPressed(config.key_bindings.scroll_up)));
            scroll -= @floatFromInt(@intFromBool(isPressed(config.key_bindings.scroll_down)));
        }
        self.scrolling.target -= scroll;
        self.scrolling.current = expDecayWithAnimationSpeed(self.scrolling.current, self.scrolling.target, rl.getFrameTime());
    } else {
        rl.drawTextureRec(self.canvas.texture, .{
            .x = 0,
            .y = 0,
            .width = @as(f32, @floatFromInt(self.canvas.texture.width)),
            .height = -@as(f32, @floatFromInt(self.canvas.texture.height)), // negative to flip image vertically
        }, rl.Vector2.zero(), rl.Color.white);
    }

    self.drawing_state = switch (self.drawing_state) {
        .idle => if (isDown(config.key_bindings.draw))
            .drawing
        else if (isDown(config.key_bindings.draw_line))
            .{ .drawing_line = mouse_position }
        else if (isDown(config.key_bindings.eraser))
            .eraser
        else if (isPressed(config.key_bindings.picking_color)) blk: {
            self.color_wheel = .{ .center = mouse_position, .size = 0 };
            break :blk .picking_color;
        } else if (isPressed(config.key_bindings.view_all_images)) blk: {
            if (self.editing) |old_level| {
                std.log.info("Stored texture {?d}", .{self.editing});
                try self.asset_loader.setTexture(old_level, self.canvas.texture);
                self.canvas.begin();
                rl.clearBackground(rl.Color.blank);
                self.canvas.end();
                self.editing = null;
            }
            break :blk .view_all_images;
        } else .idle,
        .drawing => blk: {
            self.canvas.begin();
            rl.drawLineEx(self.old_mouse_position, mouse_position, config.line_thickness, self.painting_color);
            self.canvas.end();
            break :blk if (isDown(config.key_bindings.draw))
                .drawing
            else
                .idle;
        },
        .eraser => blk: {
            const radius = config.eraser_thickness / 2;
            self.canvas.begin();

            {
                rl.drawCircleV(self.old_mouse_position, radius, rl.Color.white);

                rl.beginBlendMode(.blend_subtract_colors);
                rl.gl.rlSetBlendFactors(0, 0, 0);
                {
                    rl.drawCircleV(self.old_mouse_position, radius, rl.Color.white);
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
                rl.drawLineEx(self.old_mouse_position, mouse_position, config.eraser_thickness, self.painting_color);

                rl.beginBlendMode(.blend_subtract_colors);
                rl.gl.rlSetBlendFactors(0, 0, 0);
                {
                    rl.drawLineEx(self.old_mouse_position, mouse_position, config.eraser_thickness, self.painting_color);
                }
                rl.endBlendMode();
            }
            self.canvas.end();

            break :blk if (isDown(config.key_bindings.eraser)) .eraser else .idle;
        },
        .drawing_line => |old_position| blk: {
            drawNiceLine(old_position, mouse_position, config.line_thickness, self.painting_color);
            if (!isDown(config.key_bindings.draw_line)) {
                self.canvas.begin();
                drawNiceLine(old_position, mouse_position, config.line_thickness, self.painting_color);
                self.canvas.end();
                break :blk .idle;
            }
            break :blk self.drawing_state;
        },
        .picking_color => blk: {
            self.painting_color = self.color_wheel.draw(mouse_position);
            break :blk if (!isDown(config.key_bindings.picking_color))
                .idle
            else {
                self.color_wheel.size = expDecayWithAnimationSpeed(
                    self.color_wheel.size,
                    config.wheel_target_size,
                    rl.getFrameTime(),
                );
                break :blk .picking_color;
            };
        },
        .view_all_images => blk: {
            if (isPressed(config.key_bindings.new_canvas)) {
                try self.asset_loader.addTexture(self.canvas.texture);
            }
            const padding = rl.Vector2.one().scale(50);
            const screen_size = rl.Vector2.init(@floatFromInt(rl.getScreenWidth()), @floatFromInt(rl.getScreenHeight()));

            const images_on_one_row = 4;

            const texture_size = screen_size.subtract(padding).scale(1.0 / @as(f32, @floatFromInt(images_on_one_row))).subtract(padding);
            const start_image: usize = @as(usize, @intFromFloat(@floor(@max(0, self.scrolling.current)))) * images_on_one_row;
            const num_of_images = self.asset_loader.images.items.len;
            const number_of_rows_including_add_button = std.math.divCeil(
                usize,
                num_of_images + 1,
                images_on_one_row,
            ) catch unreachable;

            self.scrolling.target = std.math.clamp(
                self.scrolling.target,
                0,
                @as(f32, @floatFromInt(number_of_rows_including_add_button - 1)),
            );

            const images_to_display = images_on_one_row * images_on_one_row * 2;

            var index: usize = @intCast(@max(0, start_image));
            while (index <= @min(start_image + images_to_display, self.asset_loader.images.items.len)) : (index += 1) {
                const rect: rl.Rectangle = rect: {
                    const col = index % images_on_one_row;
                    const row = @as(f32, @floatFromInt(index / images_on_one_row)) - self.scrolling.current;
                    const pos = padding.add(
                        rl.Vector2.init(@floatFromInt(col), row)
                            .multiply(texture_size.add(padding)),
                    );
                    const border_size = rl.Vector2{ .x = 10, .y = 10 };
                    const backdrop_size = texture_size.add(border_size.scale(2));
                    const backdrop_pos = pos.subtract(border_size);
                    break :rect .{
                        .x = backdrop_pos.x,
                        .y = backdrop_pos.y,
                        .width = backdrop_size.x,
                        .height = backdrop_size.y,
                    };
                };
                if (index != self.asset_loader.images.items.len) {
                    const maybe_texture = self.asset_loader.getTexture(index);
                    switch (gui.item(rect, maybe_texture)) {
                        .idle => {},
                        .delete => {
                            // flush or else texture removing would case raylib to draw wrong texture.
                            flushRaylib();
                            try self.asset_loader.removeTexture(index);
                        },
                        .select => {
                            self.editing = index;
                            std.log.info("Now editing {d} level", .{index});
                            self.canvas.begin();
                            rl.clearBackground(rl.Color.blank);
                            if (maybe_texture) |texture| texture.draw(0, 0, rl.Color.white);
                            self.canvas.end();
                            break :blk .idle;
                        },
                    }
                } else { // Draw add new textures
                    if (gui.new(rect)) {
                        try self.asset_loader.addTexture(self.canvas.texture);
                    }
                }
            }

            break :blk .view_all_images;
        },
    };
    if (self.drawing_state != .picking_color) {
        self.color_wheel.size = expDecayWithAnimationSpeed(self.color_wheel.size, 0, rl.getFrameTime());
        _ = self.color_wheel.draw(mouse_position);
    }

    if (isDown(config.key_bindings.clear)) {
        self.canvas.begin();
        rl.clearBackground(rl.Color.blank);
        self.canvas.end();
    }
    if (self.drawing_state == .eraser) {
        rl.drawCircleLinesV(mouse_position, config.eraser_thickness / 2, self.painting_color);
    } else {
        rl.drawCircleV(mouse_position, config.line_thickness * 2, self.painting_color);
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

const gui = struct {
    fn cross(
        rect: rl.Rectangle,
        thickness: f32,
    ) bool {
        const mouse_position = rl.getMousePosition();
        const hovering_cross = rectanglePointCollision(mouse_position, rect);
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

    fn new(rect: rl.Rectangle) bool {
        const hovering_rectangle = rectanglePointCollision(rl.getMousePosition(), rect);

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
        const hovering_rectangle = rectanglePointCollision(mouse_position, rect);

        const cross_rectangle = resizeRectangle(rect, rl.Vector2.one().scale(40), .{
            .x = 1, // top right conner
            .y = 0,
        });
        const hovering_cross = rectanglePointCollision(mouse_position, cross_rectangle);

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

fn rectanglePointCollision(point: rl.Vector2, rect: rl.Rectangle) bool {
    return point.x >= rect.x and point.y > rect.y and
        point.x < rect.x + rect.width and point.y < rect.y + rect.height;
}

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
