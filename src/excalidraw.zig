pub fn @"export"(canvas: *const Canvas, writer: anytype) !void {
    var stream = std.json.writeStream(writer, .{
        .whitespace = .indent_2,
    });
    try stream.beginObject();
    defer stream.endObject() catch {};

    try stream.objectField("type");
    try stream.write("excalidraw");

    try stream.objectField("version");
    try stream.write(2);

    try stream.objectField("source");
    try stream.write("https://excalidraw.com");

    try stream.objectField("elements");

    {
        try stream.beginArray();
        defer stream.endArray() catch {};

        for (canvas.strokes.items) |stroke| {
            if (!stroke.is_active) continue;

            const bounding_box = canvas.calculateBoundingBoxForStroke(stroke);
            const color = colorToHex(stroke.color);

            try stream.beginObject();
            defer stream.endObject() catch {};

            try stream.objectField("id");
            try stream.write("3S58bw_Tg16w_xJeDjeSm");
            try stream.objectField("type");
            try stream.write("freedraw");
            try stream.objectField("x");
            try stream.write(bounding_box.min[0]);
            try stream.objectField("y");
            try stream.write(bounding_box.min[1]);
            try stream.objectField("width");
            try stream.write(bounding_box.max[0] - bounding_box.min[0]);
            try stream.objectField("height");
            try stream.write(bounding_box.max[1] - bounding_box.min[1]);
            try stream.objectField("angle");
            try stream.write(0);
            try stream.objectField("strokeColor");
            try stream.write(color);
            try stream.objectField("backgroundColor");
            try stream.write("transparent");
            try stream.objectField("fillStyle");
            try stream.write("solid");
            try stream.objectField("strokeWidth");
            try stream.write(2);
            try stream.objectField("strokeStyle");
            try stream.write("solid");
            try stream.objectField("roughness");
            try stream.write(1);
            try stream.objectField("opacity");
            try stream.write(100);
            try stream.objectField("groupIds");
            try stream.write(&[_]f32{});
            try stream.objectField("frameId");
            try stream.write(null);
            try stream.objectField("index");
            try stream.write("a0");
            try stream.objectField("roundness");
            try stream.write(null);
            try stream.objectField("seed");
            try stream.write(848197444);
            try stream.objectField("version");
            try stream.write(168);
            try stream.objectField("versionNonce");
            try stream.write(2086505796);
            try stream.objectField("isDeleted");
            try stream.write(!stroke.is_active);
            try stream.objectField("boundElements");
            try stream.write(null);
            try stream.objectField("updated");
            try stream.write(1745262287964);
            try stream.objectField("link");
            try stream.write(null);
            try stream.objectField("locked");
            try stream.write(false);
            try stream.objectField("simulatePressure");
            try stream.write(true);

            try stream.objectField("points");

            {
                try stream.beginArray();
                defer stream.endArray() catch {};

                for (canvas.segments.items[stroke.span.start..][0..stroke.span.size]) |point| {
                    try stream.write([2]f32{
                        point[0] - bounding_box.min[0],
                        point[1] - bounding_box.min[1],
                    });
                }
            }
        }
    }
}

fn colorToHex(color: @FieldType(Canvas.Stroke, "color")) [7]u8 {
    var result: [7]u8 = undefined;
    _ = std.fmt.bufPrint(&result, "#{x:0>2}{x:0>2}{x:0>2}", .{
        color.r,
        color.g,
        color.b,
    }) catch unreachable;
    return result;
}

const std = @import("std");
const Canvas = @import("Canvas.zig");
