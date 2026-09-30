//! Color types for terminal styling.
//!
//! Supports ANSI 16, 256, and TrueColor (24-bit) colors, plus terminal
//! color-profile detection helpers. Adapted from zigzag
//! `style/color.zig` and libvaxis `Cell.zig` (Report, rgbFromSpec) for the
//! notui §5 surface. No zg import.

const std = @import("std");

/// Color representation supporting multiple color modes.
pub const Color = union(enum) {
    /// Basic ANSI colors (0-15).
    ansi: AnsiColor,
    /// 256-color palette (0-255).
    ansi256: u8,
    /// True color (24-bit RGB).
    rgb: Rgb,
    /// Terminal default color (emit nothing).
    default,

    pub const Rgb = struct {
        r: u8,
        g: u8,
        b: u8,
    };

    // Basic ANSI colors
    pub const black: Color = .{ .ansi = .black };
    pub const red: Color = .{ .ansi = .red };
    pub const green: Color = .{ .ansi = .green };
    pub const yellow: Color = .{ .ansi = .yellow };
    pub const blue: Color = .{ .ansi = .blue };
    pub const magenta: Color = .{ .ansi = .magenta };
    pub const cyan: Color = .{ .ansi = .cyan };
    pub const white: Color = .{ .ansi = .white };

    // Bright ANSI colors
    pub const bright_black: Color = .{ .ansi = .bright_black };
    pub const bright_red: Color = .{ .ansi = .bright_red };
    pub const bright_green: Color = .{ .ansi = .bright_green };
    pub const bright_yellow: Color = .{ .ansi = .bright_yellow };
    pub const bright_blue: Color = .{ .ansi = .bright_blue };
    pub const bright_magenta: Color = .{ .ansi = .bright_magenta };
    pub const bright_cyan: Color = .{ .ansi = .bright_cyan };
    pub const bright_white: Color = .{ .ansi = .bright_white };

    /// A color report from the terminal, answering an OSC 4/10/11/12 query.
    pub const Report = struct {
        /// Which query this report answers.
        kind: Kind,
        /// 8-bit per channel value.
        value: [3]u8,
    };

    /// The OSC query a color report answers.
    pub const Kind = enum(u8) {
        /// OSC 4: palette entry color.
        osc4,
        /// OSC 10: default foreground.
        osc10,
        /// OSC 11: default background.
        osc11,
        /// OSC 12: text cursor color.
        osc12,
    };

    /// Structural equality across all tags.
    pub fn eql(a: Color, b: Color) bool {
        return switch (a) {
            .ansi => |ca| switch (b) {
                .ansi => |cb| ca == cb,
                else => false,
            },
            .ansi256 => |na| switch (b) {
                .ansi256 => |nb| na == nb,
                else => false,
            },
            .rgb => |ra| switch (b) {
                .rgb => |rb| ra.r == rb.r and ra.g == rb.g and ra.b == rb.b,
                else => false,
            },
            .default => switch (b) {
                .default => true,
                else => false,
            },
        };
    }

    /// Create a color from RGB values.
    pub fn fromRgb(r: u8, g: u8, b: u8) Color {
        return .{ .rgb = .{ .r = r, .g = g, .b = b } };
    }

    /// Create a color from a hex string (e.g. `"#FF5733"` or `"FF5733"`).
    /// Returns `.default` on malformed input.
    pub fn hex(str: []const u8) Color {
        const s = if (str.len > 0 and str[0] == '#') str[1..] else str;

        if (s.len != 6) return .default;

        const r = std.fmt.parseInt(u8, s[0..2], 16) catch return .default;
        const g = std.fmt.parseInt(u8, s[2..4], 16) catch return .default;
        const b = std.fmt.parseInt(u8, s[4..6], 16) catch return .default;

        return .{ .rgb = .{ .r = r, .g = g, .b = b } };
    }

    /// Create a color from the 256-color palette.
    pub fn color256(n: u8) Color {
        return .{ .ansi256 = n };
    }

    /// Create a grayscale color (0-23, where 0 is dark and 23 is light).
    /// Levels above 23 clamp to the lightest gray.
    pub fn gray(level: u8) Color {
        if (level > 23) return .{ .ansi256 = 255 };
        return .{ .ansi256 = 232 + level };
    }

    /// Parse an XParseColor-style rgb specification into a `Color.rgb`.
    ///
    /// The spec is of the form `rgb:RRRR/GGGG/BBBB` (16 bits per channel,
    /// as sent by OSC 11 responses). Each channel is downshifted to 8 bits
    /// by taking the high byte; malformed specs return
    /// `error.InvalidColorSpec`.
    pub fn rgbFromSpec(spec: []const u8) !Color {
        var iter = std.mem.splitScalar(u8, spec, ':');
        const prefix = iter.next() orelse return error.InvalidColorSpec;
        if (!std.mem.eql(u8, "rgb", prefix)) return error.InvalidColorSpec;

        const spec_str = iter.next() orelse return error.InvalidColorSpec;

        var spec_iter = std.mem.splitScalar(u8, spec_str, '/');

        const r_raw = spec_iter.next() orelse return error.InvalidColorSpec;
        if (r_raw.len != 4) return error.InvalidColorSpec;

        const g_raw = spec_iter.next() orelse return error.InvalidColorSpec;
        if (g_raw.len != 4) return error.InvalidColorSpec;

        const b_raw = spec_iter.next() orelse return error.InvalidColorSpec;
        if (b_raw.len != 4) return error.InvalidColorSpec;

        const r = std.fmt.parseUnsigned(u8, r_raw[0..2], 16) catch return error.InvalidColorSpec;
        const g = std.fmt.parseUnsigned(u8, g_raw[0..2], 16) catch return error.InvalidColorSpec;
        const b = std.fmt.parseUnsigned(u8, b_raw[0..2], 16) catch return error.InvalidColorSpec;

        return .{ .rgb = .{ .r = r, .g = g, .b = b } };
    }

    /// Interpolate between `self` and `b` with an RGB lerp; `t` is
    /// clamped to 0..1. Falls back to `self` when either end is not
    /// rgb-convertible (baseui-contract.md §5; direct port of zigzag
    /// `interpolateColor`, progress.zig:255-266).
    pub fn interpolate(self: Color, b: Color, t: f64) Color {
        const ar = toRgb(self) orelse return self;
        const br = toRgb(b) orelse return self;
        const tt = clamp01(t);
        return .{ .rgb = .{
            .r = lerpChannel(ar.r, br.r, tt),
            .g = lerpChannel(ar.g, br.g, tt),
            .b = lerpChannel(ar.b, br.b, tt),
        } };
    }

    /// A comptime ramp of `steps` colors from `self` to `end` (1..=8
    /// steps) for static palettes.
    pub fn gradient(self: Color, comptime steps: usize, end: Color) [steps]Color {
        if (steps == 0) @compileError("gradient: steps must be >= 1");
        if (steps > 8) @compileError("gradient: steps must be <= 8");
        var ramp: [steps]Color = undefined;
        for (0..steps) |i| {
            const t: f64 = if (steps == 1) 0 else @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps - 1));
            ramp[i] = self.interpolate(end, t);
        }
        return ramp;
    }
};

/// Basic ANSI colors (0-15).
pub const AnsiColor = enum(u8) {
    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,
    bright_black = 8,
    bright_red = 9,
    bright_green = 10,
    bright_yellow = 11,
    bright_blue = 12,
    bright_magenta = 13,
    bright_cyan = 14,
    bright_white = 15,

    /// SGR foreground code (30-37, 90-97).
    pub fn fgCode(self: AnsiColor) u8 {
        const base: u8 = @intFromEnum(self);
        return if (base < 8) 30 + base else 90 + base - 8;
    }

    /// SGR background code (40-47, 100-107).
    pub fn bgCode(self: AnsiColor) u8 {
        const base: u8 = @intFromEnum(self);
        return if (base < 8) 40 + base else 100 + base - 8;
    }

    /// Approximate RGB for this color (the 16-color palette's
    /// conventional values).
    pub fn toRgb(self: AnsiColor) Color.Rgb {
        return switch (self) {
            .black => .{ .r = 0, .g = 0, .b = 0 },
            .red => .{ .r = 128, .g = 0, .b = 0 },
            .green => .{ .r = 0, .g = 128, .b = 0 },
            .yellow => .{ .r = 128, .g = 128, .b = 0 },
            .blue => .{ .r = 0, .g = 0, .b = 128 },
            .magenta => .{ .r = 128, .g = 0, .b = 128 },
            .cyan => .{ .r = 0, .g = 128, .b = 128 },
            .white => .{ .r = 192, .g = 192, .b = 192 },
            .bright_black => .{ .r = 128, .g = 128, .b = 128 },
            .bright_red => .{ .r = 255, .g = 0, .b = 0 },
            .bright_green => .{ .r = 0, .g = 255, .b = 0 },
            .bright_yellow => .{ .r = 255, .g = 255, .b = 0 },
            .bright_blue => .{ .r = 0, .g = 0, .b = 255 },
            .bright_magenta => .{ .r = 255, .g = 0, .b = 255 },
            .bright_cyan => .{ .r = 0, .g = 255, .b = 255 },
            .bright_white => .{ .r = 255, .g = 255, .b = 255 },
        };
    }
};

/// Convert a 256-color index to RGB.
///
/// Indexes 0-15 map through the ANSI palette, 16-231 through the 6x6x6
/// color cube, 232-255 through the grayscale ramp.
pub fn ansi256ToRgb(n: u8) Color.Rgb {
    if (n < 16) {
        // Standard colors
        return @as(AnsiColor, @enumFromInt(n)).toRgb();
    } else if (n < 232) {
        // 6x6x6 color cube
        const idx = n - 16;
        const r: u8 = @intCast((idx / 36) % 6);
        const g: u8 = @intCast((idx / 6) % 6);
        const b: u8 = @intCast(idx % 6);
        return .{
            .r = if (r == 0) 0 else r * 40 + 55,
            .g = if (g == 0) 0 else g * 40 + 55,
            .b = if (b == 0) 0 else b * 40 + 55,
        };
    } else {
        // Grayscale
        const gray: u8 = (n - 232) * 10 + 8;
        return .{ .r = gray, .g = gray, .b = gray };
    }
}

/// Downsample RGB to the nearest 256-color index (the inverse of
/// `ansi256ToRgb`): nearest 6x6x6 cube entry or grayscale ramp entry.
pub fn rgbToAnsi256(r: u8, g: u8, b: u8) u8 {
    const ri = nearestCubeLevel(r);
    const gi = nearestCubeLevel(g);
    const bi = nearestCubeLevel(b);
    const cube_idx: u8 = 16 + 36 * ri + 6 * gi + bi;
    const cube = ansi256ToRgb(cube_idx);
    var best_idx = cube_idx;
    var best_dist = sqDist(r, g, b, cube.r, cube.g, cube.b);

    // Grayscale ramp 232..255 (values 8, 18, ..., 238).
    var k: u8 = 0;
    while (k < 24) : (k += 1) {
        const gv: u8 = 8 + 10 * k;
        const d = sqDist(r, g, b, gv, gv, gv);
        if (d < best_dist) {
            best_dist = d;
            best_idx = 232 + k;
        }
    }
    return best_idx;
}

/// Downsample RGB to the nearest of the 16 ANSI colors.
pub fn rgbToAnsi(r: u8, g: u8, b: u8) AnsiColor {
    var best: AnsiColor = .black;
    var best_dist: u32 = std.math.maxInt(u32);
    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        const c: AnsiColor = @enumFromInt(i);
        const rgb = c.toRgb();
        const d = sqDist(r, g, b, rgb.r, rgb.g, rgb.b);
        if (d < best_dist) {
            best_dist = d;
            best = c;
        }
    }
    return best;
}

/// Nearest of the six cube levels for one channel (0, 95, 135, 175, 215,
/// 255), chosen by midpoint thresholds.
fn nearestCubeLevel(c: u8) u8 {
    if (c < 48) return 0;
    if (c < 115) return 1;
    if (c < 155) return 2;
    if (c < 195) return 3;
    if (c < 235) return 4;
    return 5;
}

fn sqDist(a: u8, b: u8, c: u8, x: u8, y: u8, z: u8) u32 {
    const dr: i32 = @as(i32, a) - @as(i32, x);
    const dg: i32 = @as(i32, b) - @as(i32, y);
    const db: i32 = @as(i32, c) - @as(i32, z);
    const r2: u32 = @intCast(dr * dr);
    const g2: u32 = @intCast(dg * dg);
    const b2: u32 = @intCast(db * db);
    return r2 + g2 + b2;
}

/// Color profile representing terminal color capabilities.
pub const ColorProfile = enum {
    /// 16-color (ANSI) only.
    ansi,
    /// 256-color palette.
    ansi256,
    /// 24-bit true color.
    truecolor,

    /// Check if this profile supports true color.
    pub fn supportsTrueColor(self: ColorProfile) bool {
        return self == .truecolor;
    }

    /// Check if this profile supports the 256-color palette.
    pub fn supports256(self: ColorProfile) bool {
        return self == .truecolor or self == .ansi256;
    }

    /// Check if this profile supports any color.
    pub fn supportsColor(self: ColorProfile) bool {
        return self != .ansi;
    }
};

/// RGB view of a color; null when the color is not rgb-convertible.
fn toRgb(c: Color) ?Color.Rgb {
    return switch (c) {
        .rgb => |rgb| rgb,
        .ansi => |ac| ac.toRgb(),
        .ansi256 => |n| ansi256ToRgb(n),
        .default => null,
    };
}

fn clamp01(x: f64) f64 {
    return @max(0, @min(1, x));
}

fn lerpChannel(x: u8, y: u8, t: f64) u8 {
    // `t` is 0..1 (`interpolate` runs `clamp01`) and `x`/`y` are u8, so the
    // mix is 0..255 up to the rounding of its two products: truncation maps
    // that last ulp onto 255, so the clamp states the range and is a no-op.
    const v = @as(f64, @floatFromInt(x)) * (1.0 - t) + @as(f64, @floatFromInt(y)) * t;
    return @intFromFloat(std.math.clamp(v, 0.0, 255.0));
}

test {
    std.testing.refAllDecls(@This());
}

test "color: eql across all tags" {
    try std.testing.expect(Color.eql(.{ .ansi = .red }, .{ .ansi = .red }));
    try std.testing.expect(!Color.eql(.{ .ansi = .red }, .{ .ansi = .blue }));
    try std.testing.expect(!Color.eql(.{ .ansi = .red }, .{ .ansi256 = 1 }));
    try std.testing.expect(Color.eql(.{ .ansi256 = 42 }, .{ .ansi256 = 42 }));
    try std.testing.expect(!Color.eql(.{ .ansi256 = 42 }, .{ .ansi256 = 43 }));
    try std.testing.expect(!Color.eql(.{ .ansi256 = 42 }, .{ .rgb = .{ .r = 42, .g = 42, .b = 42 } }));
    try std.testing.expect(Color.eql(.{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }));
    try std.testing.expect(!Color.eql(
        .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
        .{ .rgb = .{ .r = 3, .g = 2, .b = 1 } },
    ));
    try std.testing.expect(Color.eql(.default, .default));
    try std.testing.expect(!Color.eql(.default, .{ .ansi = .black }));
    try std.testing.expect(!Color.eql(.{ .ansi = .black }, .default));
}

test "color: hex" {
    const c = Color.hex("#FF5733");
    try std.testing.expectEqual(@as(u8, 0xFF), c.rgb.r);
    try std.testing.expectEqual(@as(u8, 0x57), c.rgb.g);
    try std.testing.expectEqual(@as(u8, 0x33), c.rgb.b);

    const no_hash = Color.hex("FF5733");
    try std.testing.expect(Color.eql(c, no_hash));

    try std.testing.expectEqual(Color.default, Color.hex("abc"));
    try std.testing.expectEqual(Color.default, Color.hex("zzzzzz"));
    try std.testing.expectEqual(Color.default, Color.hex("#"));
    try std.testing.expectEqual(Color.default, Color.hex(""));
}

test "color: color256 and gray helpers" {
    try std.testing.expectEqual(Color{ .ansi256 = 42 }, Color.color256(42));
    try std.testing.expectEqual(Color{ .ansi256 = 232 }, Color.gray(0));
    try std.testing.expectEqual(Color{ .ansi256 = 255 }, Color.gray(23));
    try std.testing.expectEqual(Color{ .ansi256 = 255 }, Color.gray(24));
    try std.testing.expectEqual(Color{ .ansi256 = 237 }, Color.gray(5));
}

test "color: rgbFromSpec vectors" {
    const c = try Color.rgbFromSpec("rgb:aaaa/bbbb/cccc");
    try std.testing.expectEqual(@as(u8, 0xAA), c.rgb.r);
    try std.testing.expectEqual(@as(u8, 0xBB), c.rgb.g);
    try std.testing.expectEqual(@as(u8, 0xCC), c.rgb.b);

    // 16-bit channels downshift to their high byte.
    const downshifted = try Color.rgbFromSpec("rgb:ff00/0f00/00ff");
    try std.testing.expectEqual(@as(u8, 0xFF), downshifted.rgb.r);
    try std.testing.expectEqual(@as(u8, 0x0F), downshifted.rgb.g);
    try std.testing.expectEqual(@as(u8, 0x00), downshifted.rgb.b);

    const zeros = try Color.rgbFromSpec("rgb:0000/0000/0000");
    try std.testing.expectEqual(@as(u8, 0), zeros.rgb.r);

    try std.testing.expectError(error.InvalidColorSpec, Color.rgbFromSpec("xyz:aaaa/bbbb/cccc"));
    try std.testing.expectError(error.InvalidColorSpec, Color.rgbFromSpec("rgb:aaaa/bbbb"));
    try std.testing.expectError(error.InvalidColorSpec, Color.rgbFromSpec("rgb:aa/bb/cc"));
    try std.testing.expectError(error.InvalidColorSpec, Color.rgbFromSpec("rgb:zzzz/bbbb/cccc"));
    try std.testing.expectError(error.InvalidColorSpec, Color.rgbFromSpec(""));
}

test "color: ansi256ToRgb cube corners" {
    try std.testing.expectEqual(Color.Rgb{ .r = 0, .g = 0, .b = 0 }, ansi256ToRgb(16));
    try std.testing.expectEqual(Color.Rgb{ .r = 0, .g = 0, .b = 255 }, ansi256ToRgb(21));
    try std.testing.expectEqual(Color.Rgb{ .r = 255, .g = 0, .b = 0 }, ansi256ToRgb(196));
    try std.testing.expectEqual(Color.Rgb{ .r = 255, .g = 255, .b = 255 }, ansi256ToRgb(231));
    try std.testing.expectEqual(Color.Rgb{ .r = 8, .g = 8, .b = 8 }, ansi256ToRgb(232));
    try std.testing.expectEqual(Color.Rgb{ .r = 238, .g = 238, .b = 238 }, ansi256ToRgb(255));

    // Indexes 0-15 map through the ANSI palette.
    try std.testing.expectEqual(Color.Rgb{ .r = 0, .g = 0, .b = 0 }, ansi256ToRgb(0));
    try std.testing.expectEqual(Color.Rgb{ .r = 255, .g = 255, .b = 255 }, ansi256ToRgb(15));
}

test "color: rgbToAnsi256 downsampling" {
    try std.testing.expectEqual(@as(u8, 16), rgbToAnsi256(0, 0, 0));
    try std.testing.expectEqual(@as(u8, 231), rgbToAnsi256(255, 255, 255));
    try std.testing.expectEqual(@as(u8, 196), rgbToAnsi256(255, 0, 0));
    try std.testing.expectEqual(@as(u8, 88), rgbToAnsi256(128, 0, 0));
    // Mid-gray prefers the grayscale ramp over the cube.
    try std.testing.expectEqual(@as(u8, 244), rgbToAnsi256(128, 128, 128));
}

test "color: rgbToAnsi nearest base" {
    try std.testing.expectEqual(AnsiColor.black, rgbToAnsi(0, 0, 0));
    try std.testing.expectEqual(AnsiColor.bright_red, rgbToAnsi(255, 0, 0));
    try std.testing.expectEqual(AnsiColor.bright_green, rgbToAnsi(0, 255, 0));
    try std.testing.expectEqual(AnsiColor.red, rgbToAnsi(100, 0, 0));
    try std.testing.expectEqual(AnsiColor.white, rgbToAnsi(200, 200, 200));
    try std.testing.expectEqual(AnsiColor.bright_white, rgbToAnsi(250, 250, 250));
}

test "color: AnsiColor fg/bg code math" {
    try std.testing.expectEqual(@as(u8, 30), AnsiColor.black.fgCode());
    try std.testing.expectEqual(@as(u8, 31), AnsiColor.red.fgCode());
    try std.testing.expectEqual(@as(u8, 37), AnsiColor.white.fgCode());
    try std.testing.expectEqual(@as(u8, 90), AnsiColor.bright_black.fgCode());
    try std.testing.expectEqual(@as(u8, 97), AnsiColor.bright_white.fgCode());

    try std.testing.expectEqual(@as(u8, 40), AnsiColor.black.bgCode());
    try std.testing.expectEqual(@as(u8, 47), AnsiColor.white.bgCode());
    try std.testing.expectEqual(@as(u8, 100), AnsiColor.bright_black.bgCode());
    try std.testing.expectEqual(@as(u8, 107), AnsiColor.bright_white.bgCode());

    try std.testing.expectEqual(Color.Rgb{ .r = 128, .g = 0, .b = 0 }, AnsiColor.red.toRgb());
    try std.testing.expectEqual(Color.Rgb{ .r = 255, .g = 255, .b = 0 }, AnsiColor.bright_yellow.toRgb());
}

test "color: ColorProfile support matrix" {
    try std.testing.expect(!ColorProfile.ansi.supportsTrueColor());
    try std.testing.expect(!ColorProfile.ansi256.supportsTrueColor());
    try std.testing.expect(ColorProfile.truecolor.supportsTrueColor());

    try std.testing.expect(!ColorProfile.ansi.supports256());
    try std.testing.expect(ColorProfile.ansi256.supports256());
    try std.testing.expect(ColorProfile.truecolor.supports256());

    try std.testing.expect(!ColorProfile.ansi.supportsColor());
    try std.testing.expect(ColorProfile.ansi256.supportsColor());
    try std.testing.expect(ColorProfile.truecolor.supportsColor());
}

test "color: interpolate clamps t to 0..1" {
    const black: Color = .{ .rgb = .{ .r = 0, .g = 0, .b = 0 } };
    const white: Color = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } };
    try std.testing.expect(Color.eql(black, black.interpolate(white, -1.0)));
    try std.testing.expect(Color.eql(white, black.interpolate(white, 2.0)));
    try std.testing.expect(Color.eql(black, black.interpolate(white, 0.0)));
    try std.testing.expect(Color.eql(white, black.interpolate(white, 1.0)));
}

test "color: interpolate midpoint lerps each channel" {
    const red: Color = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } };
    const blue: Color = .{ .rgb = .{ .r = 0, .g = 0, .b = 255 } };
    // 255 * 0.5 + 0 * 0.5 = 127.5 -> 127 (truncating cast, like zigzag).
    try std.testing.expect(Color.eql(
        .{ .rgb = .{ .r = 127, .g = 0, .b = 127 } },
        red.interpolate(blue, 0.5),
    ));
}

test "color: interpolate converts ansi and ansi256 ends" {
    const red: Color = .{ .ansi = .red }; // (128, 0, 0)
    const blue: Color = .{ .ansi = .blue }; // (0, 0, 128)
    try std.testing.expect(Color.eql(
        .{ .rgb = .{ .r = 64, .g = 0, .b = 64 } },
        red.interpolate(blue, 0.5),
    ));

    const c0: Color = .{ .ansi256 = 16 }; // black cube corner
    const c231: Color = .{ .ansi256 = 231 }; // white cube corner
    try std.testing.expect(Color.eql(
        .{ .rgb = .{ .r = 127, .g = 127, .b = 127 } },
        c0.interpolate(c231, 0.5),
    ));
}

test "color: interpolate falls back to self on non-rgb-convertible ends" {
    const def: Color = .default;
    try std.testing.expect(Color.eql(.default, def.interpolate(.{ .ansi = .red }, 0.5)));
    try std.testing.expect(Color.eql(.{ .ansi = .red }, (Color{ .ansi = .red }).interpolate(.default, 0.5)));
}

test "color: gradient builds a comptime ramp" {
    const black: Color = .{ .rgb = .{ .r = 0, .g = 0, .b = 0 } };
    const white: Color = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } };
    const ramp = black.gradient(3, white);
    try std.testing.expectEqual(@as(usize, 3), ramp.len);
    try std.testing.expect(Color.eql(black, ramp[0]));
    try std.testing.expect(Color.eql(.{ .rgb = .{ .r = 127, .g = 127, .b = 127 } }, ramp[1]));
    try std.testing.expect(Color.eql(white, ramp[2]));

    const two = black.gradient(2, white);
    try std.testing.expect(Color.eql(black, two[0]));
    try std.testing.expect(Color.eql(white, two[1]));

    const one = black.gradient(1, white);
    try std.testing.expect(Color.eql(black, one[0]));
}
