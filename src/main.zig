const std = @import("std");

const rl = @import("raylib");
const tracy = @import("tracy");

const Drawer = @import("Drawer.zig");

pub const Vector2 = @Vector(2, f32);

pub const config = struct {
    pub const app_name = "screen-drawer";
    pub const save_folder_name = "screen_drawer_vector";
    pub const save_file_name = "save" ++ "." ++ save_format_magic;
    pub const save_format_magic = "sdv";

    pub const key_bindings = struct {
        // zig fmt: off
        pub const draw                = .{ rl.MouseButton.mouse_button_left };
        pub const undo                = .{ rl.KeyboardKey.key_left_control, rl.KeyboardKey.key_minus };
        pub const redo                = .{ rl.KeyboardKey.key_left_control, rl.KeyboardKey.key_equal };
        pub const picking_color       = .{ rl.KeyboardKey.key_left_bracket };
        pub const eraser              = .{ rl.KeyboardKey.key_e };
        pub const drag                = .{ rl.MouseButton.mouse_button_right };
        pub const toggle_keybindings  = .{ rl.KeyboardKey.key_h };
        pub const select              = .{ rl.KeyboardKey.key_left_control, rl.MouseButton.mouse_button_left };
        pub const change_brightness   = .{ rl.KeyboardKey.key_b };
        pub const save                = .{ rl.KeyboardKey.key_left_control, rl.KeyboardKey.key_s };
        pub const grid                = .{ rl.KeyboardKey.key_g };
        pub const reset_canvas        = .{ rl.KeyboardKey.key_r };
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

    pub const exit_on_unfocus = !@import("options").tracy_enable;
    pub const is_topmost = !@import("options").tracy_enable;
    pub const line_thickness = 4;
    pub const eraser_thickness = 40;
    pub const color_wheel_size = 100;
};

pub const is_debug = @import("builtin").mode == .Debug;

pub const std_options = std.Options{
    .log_level = if (is_debug) .debug else .warn,
};

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    var tracing_alloc = tracy.TracingAllocator.init(gpa_impl.allocator());

    var drawer = try Drawer.init(tracing_alloc.allocator());
    defer drawer.deinit();
    try drawer.run();
}

test {
    _ = std.testing.refAllDecls(@This());
}
