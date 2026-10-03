//! One decoded mouse event: the position the terminal reported, the
//! button, the modifiers, and the pixel offsets within the cell when the
//! terminal reports them.
//!
//! `Mouse` owns nothing; a copy is independent and trivially so.

const std = @import("std");
pub const Mouse = @This();

/// The cursor shape to request for this event; the terminal keeps the last
/// one set.
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

/// Which button produced the event. The values are the SGR 1006 button codes:
/// 0-3 are left, middle, right and "no button" (motion), 64-67 are the four
/// wheel directions, and 128-131 are buttons 8-11.
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

/// The modifier keys held during the event.
pub const Modifiers = packed struct(u3) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
};

/// What the event reports. `press` and `release` name the button transition;
/// `motion` is movement with no button held and `drag` is movement with one.
pub const Type = enum {
    press,
    release,
    motion,
    drag,
};

/// Zero-indexed column from the left edge, from the SGR 1006 parameters with
/// no clamp: it is signed, so a terminal reporting a 0-based column yields
/// `-1`. Only the legacy `CSI M` path clamps at 0.
col: i16,

/// Zero-indexed row from the top edge, signed and unclamped like `col`; the
/// legacy `CSI M` path clamps at 0.
row: i16,

/// Offset in pixels from `col`'s left edge, when the terminal reports pixel
/// positions (SGR 1016); 0 otherwise.
xoffset: u16 = 0,

/// Offset in pixels from `row`'s top edge, when the terminal reports pixel
/// positions (SGR 1016); 0 otherwise.
yoffset: u16 = 0,

/// The button this event is about. `.none` for `motion`.
button: Button,

/// The modifiers held during the event.
mods: Modifiers,

/// What kind of event this is.
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
