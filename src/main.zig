const std = @import("std");
const rl = @import("raylib");

const self_name = "screen-drawer";

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_impl.allocator();
    _ = gpa; // autofix

    rl.setConfigFlags(.{
        .window_topmost = true,
        .window_transparent = true,
        .window_undecorated = true,
        .window_maximized = true,
    });
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
        drawing_line: rl.Vector2,
        drawing_straght_line: rl.Vector2,
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

        if (isNextButtonPressed()) {
            color = getColorHash(color);
        }

        const current_pos = rl.getMousePosition();
        rl.drawTextureRec(canvas.texture, .{
            .x = 0,
            .y = 0,
            .width = @as(f32, @floatFromInt(canvas.texture.width)),
            .height = -@as(f32, @floatFromInt(canvas.texture.height)), // negative to flip image verticaly
        }, rl.Vector2.zero(), rl.Color.white);

        drawing_state = switch (drawing_state) {
            .idle => if (rl.isMouseButtonDown(.mouse_button_left))
                .{ .drawing_line = current_pos }
            else if (rl.isMouseButtonDown(.mouse_button_right))
                .{ .drawing_straght_line = current_pos }
            else if (isNextButtonPressed()) res: {
                color_wheel = .{ .center = current_pos, .size = 0 };
                break :res .picking_color;
            } else .idle,

            .drawing_line => |old_position| res: {
                canvas.begin();
                rl.drawLineEx(old_position, current_pos, line_thickness, color);
                canvas.end();
                break :res if (rl.isMouseButtonDown(.mouse_button_left))
                    .{ .drawing_line = current_pos }
                else
                    .idle;
            },
            .drawing_straght_line => |old_position| res: {
                drawNiceLine(old_position, current_pos, line_thickness, color);
                if (rl.isMouseButtonReleased(.mouse_button_right)) {
                    canvas.begin();
                    drawNiceLine(old_position, current_pos, line_thickness, color);
                    canvas.end();
                    break :res .idle;
                }
                break :res drawing_state;
            },
            .picking_color => res: {
                color = drawColorWheel(color_wheel.center, current_pos, color_wheel.size);
                break :res if (isNextButtonPressed())
                    .idle
                else {
                    color_wheel.size = expDecay(color_wheel.size, wheel_target_size, 10, rl.getFrameTime());
                    break :res .picking_color;
                };
            },
        };

        if (drawing_state != .picking_color) {
            color_wheel.size = expDecay(color_wheel.size, 0, 10, rl.getFrameTime());
            _ = drawColorWheel(color_wheel.center, current_pos, color_wheel.size);
        }

        if (rl.isKeyDown(.key_left_control) and rl.isKeyPressed(.key_s)) {
            try exportCanvas(canvas.texture, picture_name);
        }

        if (rl.isKeyPressed(.key_c)) {
            canvas.begin();
            rl.clearBackground(rl.Color.blank);
            canvas.end();
        }
        rl.drawCircleV(current_pos, line_thickness * 2, color);

        rl.endDrawing();
    }
}

fn exportCanvas(texture: rl.Texture, name: []const u8) !void {
    var buffer: [std.fs.max_path_bytes * 2]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const alloc = fba.allocator();

    const data_dir_path = try getAppDataDirEnsurePathExist(alloc, self_name);
    const picture_path = try std.fs.path.joinZ(alloc, &.{ data_dir_path, name });

    const screenshot = rl.loadImageFromTexture(texture);

    if (rl.exportImage(screenshot, picture_path))
        std.log.info("Written image to {s}", .{picture_path})
    else
        std.log.err("Failed to write {s}", .{picture_path});
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

fn isNextButtonPressed() bool {
    return rl.isKeyDown(.key_left_control) and rl.isKeyPressed(.key_equal);
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
