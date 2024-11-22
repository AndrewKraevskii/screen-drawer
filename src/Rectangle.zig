const rl = @import("raylib");

x: f32,
y: f32,
width: f32,
height: f32,

const Rectangle = @This();

pub fn init(x: f32, y: f32, width: f32, height: f32) Rectangle {
    return Rectangle{ .x = x, .y = y, .width = width, .height = height };
}

/// Check collision between two rectangles
pub fn checkCollision(self: Rectangle, rec2: Rectangle) bool {
    return rl.checkCollisionRecs(self, rec2);
}

/// Get collision rectangle for two rectangles collision
pub fn getCollision(self: Rectangle, rec2: Rectangle) Rectangle {
    return rl.getCollisionRec(self, rec2);
}

pub fn scaleRectangleCenter(rect: Rectangle, scale: rl.Vector2) Rectangle {
    return resizeRectangleCenter(rect, scale.multiply(rectangleSize(rect)));
}

pub fn scaleRectangle(rect: Rectangle, scale: rl.Vector2, origin: rl.Vector2) Rectangle {
    return resizeRectangle(rect, scale.multiply(rectangleSize(rect)), origin);
}

pub fn resizeRectangleCenter(rect: Rectangle, size: rl.Vector2) Rectangle {
    return resizeRectangle(rect, size, .{
        .x = 0.5,
        .y = 0.5,
    });
}

pub fn padRectangle(rect: Rectangle, padding: rl.Vector2) Rectangle {
    return .{
        .x = rect.x - padding.x,
        .y = rect.y - padding.y,
        .width = rect.width + 2 * padding.x,
        .height = rect.height + 2 * padding.y,
    };
}

pub fn resizeRectangle(rect: Rectangle, size: rl.Vector2, origin: rl.Vector2) Rectangle {
    return .{
        .x = rect.x + (rect.width - size.x) * origin.x,
        .y = rect.y + (rect.height - size.y) * origin.y,
        .width = size.x,
        .height = size.y,
    };
}

pub fn rectangleSize(rect: Rectangle) rl.Vector2 {
    return .{
        .x = rect.width,
        .y = rect.height,
    };
}

pub fn toRay(rect: Rectangle) rl.Rectangle {
    return .{
        .x = rect.x,
        .y = rect.y,
        .width = rect.width,
        .height = rect.height,
    };
}