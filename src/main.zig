const std = @import("std");
const rl = @import("raylib");
const Allocator = std.mem.Allocator;
const ImageStorage = @import("ImageStorage.zig");

const app_name = "screen-drawer";

const key_bindings = struct {
    // zig fmt: off
    pub const draw            = .{ rl.MouseButton.mouse_button_left };
    pub const confirm         = .{ rl.MouseButton.mouse_button_left };
    pub const draw_line       = .{ rl.MouseButton.mouse_button_right };
    pub const picking_color   = .{ rl.KeyboardKey.key_left_control, rl.KeyboardKey.key_equal };
    pub const save            = .{ rl.KeyboardKey.key_left_control, rl.KeyboardKey.key_s };
    pub const clear           = .{ rl.KeyboardKey.key_c };

    pub const view_all_images = .{ rl.KeyboardKey.key_left_bracket };
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

/// Set to std.math.inf(f32) to disable animations.
const animation_speed = 10;

pub const std_options = std.Options{
    .log_level = .debug,
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
    });

    rl.initWindow(0, 0, "Drawer");
    defer rl.closeWindow();

    const width: u31 = @intCast(rl.getScreenWidth());
    const height: u31 = @intCast(rl.getScreenHeight());
    std.log.info("screen size {d}x{d}", .{ width, height });

    const save_directory = try getAppDataDirEnsurePathExist(gpa, app_name);
    defer gpa.free(save_directory);
    var image_loader = try ImageStorage.init(gpa, save_directory);
    defer image_loader.deinit();
    try image_loader.startLoading();

    const line_thickness = 4;
    const wheel_target_size = 100;

    var color_wheel: ColorWheel = .{ .center = rl.Vector2.zero(), .size = 0 };
    var drawing_state: union(enum) {
        idle,
        drawing: rl.Vector2,
        drawing_line: rl.Vector2,
        picking_color,
        view_all_images,
    } = .view_all_images;
    var editing: ?usize = 0;
    var color: rl.Color = rl.Color.red;
    const canvas = rl.loadRenderTexture(width, height);
    defer canvas.unload();

    while (!rl.windowShouldClose() and rl.isWindowFocused()) {
        rl.beginDrawing();
        rl.clearBackground(rl.Color.blank);

        const mouse_pos = rl.getMousePosition();
        if (drawing_state != .view_all_images)
            rl.drawTextureRec(canvas.texture, .{
                .x = 0,
                .y = 0,
                .width = @as(f32, @floatFromInt(canvas.texture.width)),
                .height = -@as(f32, @floatFromInt(canvas.texture.height)), // negative to flip image verticaly
            }, rl.Vector2.zero(), rl.Color.white);

        drawing_state = switch (drawing_state) {
            .idle => if (isDown(key_bindings.draw))
                .{ .drawing = mouse_pos }
            else if (isDown(key_bindings.draw_line))
                .{ .drawing_line = mouse_pos }
            else if (isPressed(key_bindings.picking_color)) blk: {
                color_wheel = .{ .center = mouse_pos, .size = 0 };
                break :blk .picking_color;
            } else if (isPressed(key_bindings.view_all_images)) blk: {
                if (editing) |old_level| {
                    std.log.info("Stored textue {?d}", .{editing});
                    try image_loader.setTexture(old_level, canvas.texture);
                }
                break :blk .view_all_images;
            } else .idle,

            .drawing => |old_position| blk: {
                canvas.begin();
                rl.drawLineEx(old_position, mouse_pos, line_thickness, color);
                canvas.end();
                break :blk if (isDown(key_bindings.draw))
                    .{ .drawing = mouse_pos }
                else
                    .idle;
            },
            .drawing_line => |old_position| blk: {
                drawNiceLine(old_position, mouse_pos, line_thickness, color);
                if (!isDown(key_bindings.draw_line)) {
                    canvas.begin();
                    drawNiceLine(old_position, mouse_pos, line_thickness, color);
                    canvas.end();
                    break :blk .idle;
                }
                break :blk drawing_state;
            },
            .picking_color => blk: {
                color = color_wheel.draw(mouse_pos);
                break :blk if (isPressed(key_bindings.picking_color))
                    .idle
                else {
                    color_wheel.size = expDecay(color_wheel.size, wheel_target_size, animation_speed, rl.getFrameTime());
                    break :blk .picking_color;
                };
            },
            .view_all_images => blk: {
                const padding = rl.Vector2.init(50, 50);
                const screen_size = rl.Vector2.init(@floatFromInt(width), @floatFromInt(height));

                const images_on_one_row = 8;

                const texture_size = screen_size.subtract(padding).scale(1.0 / @as(f32, @floatFromInt(images_on_one_row))).subtract(padding);
                const scale = texture_size.x / @as(f32, @floatFromInt(width));

                const num_of_images = image_loader.len();
                for (0..num_of_images) |index| {
                    const maybe_texture = try image_loader.getTexture(index);
                    const col = index % images_on_one_row;
                    const row = index / images_on_one_row;
                    const pos = padding.add(
                        rl.Vector2.init(@floatFromInt(col), @floatFromInt(row))
                            .multiply(texture_size.add(padding.scale(2))),
                    );

                    const actual_texture_size = if (maybe_texture) |texture| rl.Vector2.init(@floatFromInt(texture.width), @floatFromInt(texture.height)) else texture_size;

                    const border_size = rl.Vector2{ .x = 10, .y = 10 };
                    const backdrop_size = actual_texture_size.scale(scale).add(border_size.scale(2));
                    const backdrop_pos = pos.subtract(border_size);
                    const backdrop_rect = rl.Rectangle{
                        .x = backdrop_pos.x,
                        .y = backdrop_pos.y,
                        .width = backdrop_size.x,
                        .height = backdrop_size.y,
                    };

                    const border_color = if (rectanglePointColision(mouse_pos, backdrop_rect))
                        rl.Color.light_gray
                    else
                        rl.Color.gray;

                    if (rectanglePointColision(mouse_pos, backdrop_rect) and isPressed(key_bindings.confirm)) {
                        editing = index;
                        std.log.info("Now editing {d} level", .{index});
                        canvas.begin();
                        rl.clearBackground(rl.Color.blank);
                        if (maybe_texture) |texture| texture.draw(0, 0, rl.Color.white);
                        canvas.end();
                        break :blk .idle;
                    }

                    rl.drawRectangleRec(backdrop_rect, rl.Color.black.alpha(0.6));
                    rl.drawRectangleLinesEx(backdrop_rect, 3, border_color);

                    if (maybe_texture) |t| t.drawEx(pos, 0, scale, rl.Color.white);
                    flushRaylib();
                }

                break :blk .view_all_images;
            },
        };
        if (drawing_state != .picking_color) {
            color_wheel.size = expDecay(color_wheel.size, 0, animation_speed, rl.getFrameTime());
            _ = color_wheel.draw(mouse_pos);
        }

        if (isDown(key_bindings.clear)) {
            canvas.begin();
            rl.clearBackground(rl.Color.blank);
            canvas.end();
        }
        rl.drawCircleV(mouse_pos, line_thickness * 2, color);

        rl.drawFPS(0, 0);
        rl.endDrawing();
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
    const horisontal = rl.Vector2{
        .x = end.x,
        .y = start.y,
    };
    const vertical = rl.Vector2{
        .x = start.x,
        .y = end.y,
    };
    return if (start.subtract(horisontal).lengthSqr() > start.subtract(vertical).lengthSqr()) horisontal else vertical;
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

/// True if isDown(kb) true and at least one button pressed on this frame
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

fn rectanglePointColision(point: rl.Vector2, rect: rl.Rectangle) bool {
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
