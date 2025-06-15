const print = @import("std").debug.print;
const approxEqAbs = @import("std").math.approxEqAbs;
const lerp = @import("std").math.lerp;
const animation_speed = @import("root").config.animation_speed;

pub fn expDecayWithAnimationSpeed(a: anytype, b: @TypeOf(a), dt: @TypeOf(a), animation_playing: *bool) @TypeOf(a) {
    const result = if (animation_speed) |lambda|
        lerp(a, b, 1 - @exp(-lambda * dt))
    else
        b;

    if (!approxEqAbs(@TypeOf(b), b, result, 0.00001))
        animation_playing.* = true;

    return result;
}
