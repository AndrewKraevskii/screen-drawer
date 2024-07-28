const std = @import("std");
const rl = @import("raylib");

pub fn main() !void {
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

    const line_thickness = 4;
    var old_position: ?rl.Vector2 = null;
    var start_of_horisontal: ?rl.Vector2 = null;
    var color = rl.Color.red;
    const canvas = rl.loadRenderTexture(width, height);
    defer canvas.unload();

    while (!rl.windowShouldClose() and rl.isWindowFocused()) {
        rl.beginDrawing();
        rl.clearBackground(rl.Color.blank);

        if (isNextButtonPressed()) {
            color = getColorHash(color);
        }

        const pos = rl.getMousePosition();
        {
            canvas.begin();
            if (rl.isMouseButtonDown(.mouse_button_left) and !rl.isMouseButtonDown(.mouse_button_right)) {
                if (old_position) |old| {
                    rl.drawLineEx(old, pos, line_thickness, color);
                } else {}
                old_position = pos;
            } else {
                old_position = null;
            }

            canvas.end();
        }
        if (rl.isMouseButtonPressed(.mouse_button_right)) {
            start_of_horisontal = pos;
        }
        if (rl.isMouseButtonReleased(.mouse_button_right)) {
            if (start_of_horisontal) |start| {
                canvas.begin();
                drawNiceLine(start, pos, line_thickness, color);
                canvas.end();
            }
            start_of_horisontal = null;
        }

        if (start_of_horisontal) |start| {
            drawNiceLine(start, pos, line_thickness, color);
        }
        rl.drawTextureRec(canvas.texture, .{
            .x = 0,
            .y = 0,
            .width = @as(f32, @floatFromInt(canvas.texture.width)),
            .height = -@as(f32, @floatFromInt(canvas.texture.height)),
        }, rl.Vector2.zero(), rl.Color.white);
        rl.drawCircleV(pos, line_thickness * 2, color);
        rl.endDrawing();
    }
}

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
