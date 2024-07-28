const std = @import("std");
const rl = @import("raylib");

const self_name = "screen-drawer";

const key_bindings = struct {
    // zig fmt: off
    pub const draw          = .{ rl.MouseButton.mouse_button_left };
    pub const draw_line     = .{ rl.MouseButton.mouse_button_right };
    pub const picking_color = .{ rl.KeyboardKey.key_left_control, rl.KeyboardKey.key_equal };
    pub const save          = .{ rl.KeyboardKey.key_left_control, rl.KeyboardKey.key_s };
    pub const clear         = .{ rl.KeyboardKey.key_c };
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
    var not_saving = std.Thread.ResetEvent{};
    defer not_saving.wait();
    not_saving.set();

    rl.initWindow(0, 0, "Drawer");
    defer rl.closeWindow();

    const width = rl.getScreenWidth();
    const height = rl.getScreenHeight();
    std.log.info("screen size {d}x{d}", .{ width, height });

    const picture_name = "drawing.png";
    const line_thickness = 4;
    const wheel_target_size = 100;

    var color_wheel: ColorWheel = .{ .center = rl.Vector2.zero(), .size = 0 };
    var drawing_state: union(enum) {
        idle,
        drawing: rl.Vector2,
        drawing_line: rl.Vector2,
        picking_color,
    } = .idle;
    var color: rl.Color = rl.Color.red;
    const canvas = rl.loadRenderTexture(width, height);

    if (loadCanvas(picture_name)) |texture| {
        canvas.begin();
        defer canvas.end();
        rl.drawTextureRec(texture, .{
            .x = 0,
            .y = 0,
            .width = @as(f32, @floatFromInt(texture.width)),
            .height = -@as(f32, @floatFromInt(texture.height)), // negative to flip image verticaly
        }, rl.Vector2.zero(), rl.Color.white);
    } else |e| switch (e) {
        error.FileNotFound => {
            std.log.info("no old images saves", .{});
        },
        else => return e,
    }
    defer canvas.unload();

    while (!rl.windowShouldClose() and rl.isWindowFocused()) {
        rl.beginDrawing();
        rl.clearBackground(rl.Color.blank);

        const current_pos = rl.getMousePosition();
        rl.drawTextureRec(canvas.texture, .{
            .x = 0,
            .y = 0,
            .width = @as(f32, @floatFromInt(canvas.texture.width)),
            .height = -@as(f32, @floatFromInt(canvas.texture.height)), // negative to flip image verticaly
        }, rl.Vector2.zero(), rl.Color.white);

        drawing_state = switch (drawing_state) {
            .idle => if (isDown(key_bindings.draw))
                .{ .drawing = current_pos }
            else if (isDown(key_bindings.draw_line))
                .{ .drawing_line = current_pos }
            else if (isDown(key_bindings.picking_color)) res: {
                color_wheel = .{ .center = current_pos, .size = 0 };
                break :res .picking_color;
            } else .idle,

            .drawing => |old_position| res: {
                canvas.begin();
                rl.drawLineEx(old_position, current_pos, line_thickness, color);
                canvas.end();
                break :res if (isDown(key_bindings.draw))
                    .{ .drawing = current_pos }
                else
                    .idle;
            },
            .drawing_line => |old_position| res: {
                drawNiceLine(old_position, current_pos, line_thickness, color);
                if (!isDown(key_bindings.draw_line)) {
                    canvas.begin();
                    drawNiceLine(old_position, current_pos, line_thickness, color);
                    canvas.end();
                    break :res .idle;
                }
                break :res drawing_state;
            },
            .picking_color => res: {
                color = drawColorWheel(color_wheel.center, current_pos, color_wheel.size);
                break :res if (!isDown(key_bindings.picking_color))
                    .idle
                else {
                    color_wheel.size = expDecay(color_wheel.size, wheel_target_size, animation_speed, rl.getFrameTime());
                    break :res .picking_color;
                };
            },
        };
        if (drawing_state != .picking_color) {
            color_wheel.size = expDecay(color_wheel.size, 0, animation_speed, rl.getFrameTime());
            _ = drawColorWheel(color_wheel.center, current_pos, color_wheel.size);
        }

        const saving_now = !not_saving.isSet();
        if (isDown(key_bindings.save) and !saving_now) {
            not_saving.reset();
            try exportCanvas(gpa, canvas.texture, picture_name, &not_saving);
        }

        if (saving_now) {
            rl.drawCircle(30, 30, 20, rl.Color.red);
        }

        if (isDown(key_bindings.clear)) {
            canvas.begin();
            rl.clearBackground(rl.Color.blank);
            canvas.end();
        }
        rl.drawCircleV(current_pos, line_thickness * 2, color);

        rl.endDrawing();
    }
    not_saving.wait();
    not_saving.reset();
    try exportCanvas(gpa, canvas.texture, picture_name, &not_saving);
}

fn exportCanvas(alloc: std.mem.Allocator, texture: rl.Texture, name: []const u8, saving: *std.Thread.ResetEvent) !void {
    var buffer: [std.fs.max_path_bytes * 2]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const data_dir_path = try getAppDataDirEnsurePathExist(fba.allocator(), self_name);
    const picture_path = try std.fs.path.joinZ(alloc, &.{ data_dir_path, name });

    const screenshot = rl.loadImageFromTexture(texture);
    std.log.info("Loaded image from texture", .{});

    const thread = try std.Thread.spawn(.{
        .allocator = std.heap.page_allocator,
        .stack_size = 1024 * 1024,
    }, struct {
        pub fn foo(_alloc: std.mem.Allocator, image: rl.Image, path: [:0]const u8, cond: *std.Thread.ResetEvent) void {
            const buff = rl.exportImage(image, path);
            if (buff)
                std.log.info("Written image to {s}", .{path})
            else
                std.log.err("Failed to write {s}", .{path});
            image.unload();
            _alloc.free(path);
            cond.set();
        }
    }.foo, .{ alloc, screenshot, picture_path, saving });
    _ = thread.detach();
}

fn loadCanvas(name: []const u8) !rl.Texture {
    var buffer: [std.fs.max_path_bytes * 2]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const alloc = fba.allocator();

    const data_dir_path = try getAppDataDirEnsurePathExist(alloc, self_name);
    const picture_path = try std.fs.path.joinZ(alloc, &.{ data_dir_path, name });

    const image = rl.loadImage(picture_path);
    defer image.unload();
    return rl.Texture.fromImage(image);
}

pub fn getAppDataDirEnsurePathExist(alloc: std.mem.Allocator, appname: []const u8) ![]u8 {
    const data_dir_path = try std.fs.getAppDataDir(alloc, appname);

    std.fs.makeDirAbsolute(data_dir_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => |err| return err,
    };
    return data_dir_path;
}

const ColorWheel = struct {
    center: rl.Vector2,
    size: f32,
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

fn drawColorWheel(center: rl.Vector2, pos: rl.Vector2, radius: f32) rl.Color {
    const segments = 360;
    for (0..segments) |num| {
        const frac = @as(f32, @floatFromInt(num)) / @as(f32, @floatFromInt(segments));
        const angle = frac * 360;

        const hue = frac * 360;
        rl.drawCircleSector(
            center,
            radius,
            angle,
            angle + 360.0 / @as(comptime_float, segments),
            10,
            rl.Color.fromHSV(hue, 0.8, 0.8),
        );
    }
    return rl.Color.fromHSV(-center.lineAngle(pos) / std.math.tau * 360, 1, 1);
}

fn expDecay(a: anytype, b: @TypeOf(a), lambda: @TypeOf(a), dt: @TypeOf(a)) @TypeOf(a) {
    return std.math.lerp(a, b, 1 - @exp(-lambda * dt));
}

fn isDown(keys_or_buttons: anytype) bool {
    inline for (keys_or_buttons) |key_or_button| {
        switch (@TypeOf(key_or_button)) {
            rl.KeyboardKey => {
                const key: rl.KeyboardKey = key_or_button;
                if (!rl.isKeyDown(key)) return false;
            },
            rl.MouseButton => {
                const button: rl.MouseButton = key_or_button;
                if (!rl.isMouseButtonDown(button)) return false;
            },
            else => @panic("Wrong type passed"),
        }
    }

    return true;
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
