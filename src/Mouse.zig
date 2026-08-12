/// A mouse event
const std = @import("std");
pub const Mouse = @This();

pub const Shape = enum {
    default,
    text,
    pointer,
    help,
    progress,
    wait,
    @"ew-resize",
    @"ns-resize",
    cell,
};

pub const Button = enum(u8) {
    left,
    middle,
    right,
    none,
    wheel_up = 64,
    wheel_down = 65,
    wheel_right = 66,
    wheel_left = 67,
    button_8 = 128,
    button_9 = 129,
    button_10 = 130,
    button_11 = 131,
};

pub const Modifiers = packed struct(u3) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
};

pub const Type = enum {
    press,
    release,
    motion,
    drag,
};

col: i16,
row: i16,
xoffset: u16 = 0,
yoffset: u16 = 0,
button: Button,
mods: Modifiers,
type: Type,

test "button and modifier bit values" {
    const testing = std.testing;

    try testing.expectEqual(@as(u8, 0), @intFromEnum(Button.left));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(Button.middle));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(Button.right));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(Button.none));
    try testing.expectEqual(@as(u8, 64), @intFromEnum(Button.wheel_up));
    try testing.expectEqual(@as(u8, 65), @intFromEnum(Button.wheel_down));
    try testing.expectEqual(@as(u8, 66), @intFromEnum(Button.wheel_right));
    try testing.expectEqual(@as(u8, 67), @intFromEnum(Button.wheel_left));
    try testing.expectEqual(@as(u8, 128), @intFromEnum(Button.button_8));
    try testing.expectEqual(@as(u8, 131), @intFromEnum(Button.button_11));

    const mods: Modifiers = .{ .shift = true, .ctrl = true };
    const bits: u3 = @bitCast(mods);
    try testing.expectEqual(@as(u3, 0b101), bits);
}

test "field defaults: pixel offsets are zero" {
    const testing = std.testing;

    const m: Mouse = .{
        .col = 0,
        .row = 0,
        .button = .left,
        .mods = .{},
        .type = .press,
    };
    try testing.expectEqual(@as(u16, 0), m.xoffset);
    try testing.expectEqual(@as(u16, 0), m.yoffset);
}

test {
    std.testing.refAllDecls(@This());
}
