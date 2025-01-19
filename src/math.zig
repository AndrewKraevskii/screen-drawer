const lerp = @import("std").math.lerp;
const animation_speed = @import("root").config.animation_speed;

pub fn expDecayWithAnimationSpeed(a: anytype, b: @TypeOf(a), dt: @TypeOf(a)) @TypeOf(a) {
    return if (animation_speed) |lambda|
        lerp(a, b, 1 - @exp(-lambda * dt))
    else
        b;
}
