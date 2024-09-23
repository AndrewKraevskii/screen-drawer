const std = @import("std");
const rl = @import("raylib");
const Drawer = @import("Drawer.zig");

pub const config = struct {
    pub const app_name = "screen-drawer";

    pub const key_bindings = struct {
        // zig fmt: off
        pub const draw            = .{ rl.MouseButton.mouse_button_left };
        pub const undo            = .{ rl.KeyboardKey.key_left_control, rl.KeyboardKey.key_minus };
        pub const redo            = .{ rl.KeyboardKey.key_left_control, rl.KeyboardKey.key_equal };
        pub const picking_color   = .{ rl.KeyboardKey.key_left_bracket };
        pub const eraser          = .{ rl.MouseButton.mouse_button_right };
        pub const confirm         = .{ rl.MouseButton.mouse_button_left };
        pub const scroll_up       = .{ rl.KeyboardKey.key_left_control, rl.KeyboardKey.key_equal };
        pub const scroll_down     = .{ rl.KeyboardKey.key_left_control, rl.KeyboardKey.key_minus };
        pub const new_canvas      = .{ rl.KeyboardKey.key_n };
        // zig fmt: on

        comptime {
            for (std.meta.declarations(@This())) |decl| {
                for (@field(key_bindings, decl.name), 0..) |key, index| {
                    if (@TypeOf(key) == rl.MouseButton or @TypeOf(key) == rl.KeyboardKey) continue;
                    @compileError("Key bindings should include rl.MouseButton or rl.KeyboardKey found: " ++
                        @typeName(@TypeOf(key)) ++ std.fmt.comptimePrint(" on position {d} in", .{index}) ++ decl.name);
                }
            }
        }
    };

    /// Set to null to disable animations.
    pub const animation_speed: ?comptime_int = 10;

    pub const exit_on_unfocus = true;
    pub const line_thickness = 4;
    pub const eraser_thickness = 40;
    pub const color_wheel_size = 100;
    pub const images_on_one_row = 4;
};

pub const is_debug = @import("builtin").mode == .Debug;

pub const std_options = std.Options{
    .log_level = if (is_debug) .debug else .warn,
};

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();

    var drawer = try Drawer.init(gpa_impl.allocator());
    try drawer.run();
    drawer.deinit();
}

test {
    _ = std.testing.refAllDecls(@This());
}
