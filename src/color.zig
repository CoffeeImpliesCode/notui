//! Terminal colours: the 16 ANSI names, the 256-colour palette, 24-bit RGB,
//! and the XParseColor `rgb:` form terminal replies use.
//!
//! Nothing here writes bytes; `emit` turns a `Style` into SGR and
//! `ColorProfile` says how far the terminal's palette reaches. No zg import.

const std = @import("std");

/// One terminal colour, in whichever form the caller has it.
///
/// The tags are alternatives, not layers: `.rgb` is the only tag that
/// carries more precision than the terminal can be assumed to have, and
/// `emit.writeStyleProfile` is what narrows it to a `ColorProfile`. A
/// `Color` owns nothing and copies freely.
pub const Color = union(enum) {
    /// One of the 16 `AnsiColor` entries.
    ansi: AnsiColor,
    /// 256-colour palette index, 0-255.
    ansi256: u8,
    /// 24-bit colour; the widest this package represents.
    rgb: Rgb,
    /// "Whatever the terminal uses for unset"; writes no colour bytes.
    default,

    /// 8 bits per channel.
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

    /// `.rgb` with the three channel values.
    pub fn fromRgb(r: u8, g: u8, b: u8) Color {
        return .{ .rgb = .{ .r = r, .g = g, .b = b } };
    }

    /// `.rgb` parsed from `"#RRGGBB"` or `"RRGGBB"`, or `.default` when `str`
    /// is not six hex digits after an optional leading `'#'`. `.default`
    /// is also the value a well-formed "terminal default" request parses to,
    /// so a caller that must tell the two apart checks `str` itself.
    pub fn hex(str: []const u8) Color {
        const s = if (str.len > 0 and str[0] == '#') str[1..] else str;

        if (s.len != 6) return .default;

        const r = std.fmt.parseInt(u8, s[0..2], 16) catch return .default;
        const g = std.fmt.parseInt(u8, s[2..4], 16) catch return .default;
        const b = std.fmt.parseInt(u8, s[4..6], 16) catch return .default;

        return .{ .rgb = .{ .r = r, .g = g, .b = b } };
    }

    /// `.ansi256` with palette index `n`; 0-15 select an `AnsiColor`.
    pub fn color256(n: u8) Color {
        return .{ .ansi256 = n };
    }

    /// `.ansi256` grayscale ramp entry for `level`, where 0 is the darkest
    /// and 23 the lightest. A `level` above 23 clamps to the lightest.
    pub fn gray(level: u8) Color {
        if (level > 23) return .{ .ansi256 = 255 };
        return .{ .ansi256 = 232 + level };
    }

    /// Parse an XParseColor spec of the form `rgb:RRRR/GGGG/BBBB`, the form
    /// an OSC 4/10/11/12 reply carries, into `.rgb`.
    ///
    /// Each channel is four hex digits (16 bits) and is downshifted to its
    /// high byte. The whole spec must be consumed: a wrong prefix, a missing
    /// or extra channel, a channel that is not exactly four hex digits, or
    /// anything after the third channel is `error.InvalidColorSpec`.
    /// Other prefixes, including `rgbi:`, are unsupported.
    pub fn rgbFromSpec(spec: []const u8) !Color {
        var fields = std.mem.splitScalar(u8, spec, ':');
        const prefix = fields.next() orelse return error.InvalidColorSpec;
        if (!std.mem.eql(u8, "rgb", prefix)) return error.InvalidColorSpec;
        const body = fields.next() orelse return error.InvalidColorSpec;
        if (fields.next() != null) return error.InvalidColorSpec;

        var channels = std.mem.splitScalar(u8, body, '/');
        var rgb: Color.Rgb = undefined;
        inline for ([_]*u8{ &rgb.r, &rgb.g, &rgb.b }) |ch| {
            const raw = channels.next() orelse return error.InvalidColorSpec;
            if (raw.len != 4) return error.InvalidColorSpec;
            // All four digits are parsed, so a non-hex low byte ("ffzz") is
            // rejected instead of being dropped by the downshift.
            const v = std.fmt.parseUnsigned(u16, raw, 16) catch return error.InvalidColorSpec;
            ch.* = @truncate(v >> 8);
        }
        if (channels.next() != null) return error.InvalidColorSpec;

        return .{ .rgb = rgb };
    }

    /// `.rgb` lerp from `self` to `b` at `t`, with `t` clamped to 0..1.
    ///
    /// Both ends are converted to RGB first, so an `.ansi` or `.ansi256`
    /// end interpolates from its converted value. `.default` is not
    /// convertible, and an end that is `.default` yields `self` unchanged.
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

    /// A comptime ramp of `steps` colours from `self` to `end`, evenly
    /// spaced with `self` first and `end` last. `steps` must be 1..=8;
    /// anything else is a compile error.
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

/// The 16 ANSI colours, in SGR order: `.black`..`.white` are 0-7 and the
/// `bright_` variants are 8-15. The enum's integer value is the index a
/// `.ansi256` colour carries.
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
        const base: u8 = @backingInt(self);
        return if (base < 8) 30 + base else 90 + base - 8;
    }

    /// SGR background code (40-47, 100-107).
    pub fn bgCode(self: AnsiColor) u8 {
        const base: u8 = @backingInt(self);
        return if (base < 8) 40 + base else 100 + base - 8;
    }

    /// The conventional RGB rendering of this colour, used when an
    /// `.ansi` colour has to be interpolated or downsampled numerically.
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

/// The RGB the 256-colour palette entry `n` renders as: 0-15 through the
/// `AnsiColor` palette, 16-231 through the 6x6x6 cube, 232-255 through the
/// grayscale ramp (8, 18, ..., 238).
pub fn ansi256ToRgb(n: u8) Color.Rgb {
    if (n < 16) {
        // Standard colors
        return @as(AnsiColor, @fromBackingInt(@intCast(n))).toRgb();
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

/// The 256-colour palette index nearest to the RGB triple: the nearest
/// 6x6x6 cube entry or grayscale ramp entry by squared distance.
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

/// The nearest of the 16 `AnsiColor`s by squared RGB distance; ties resolve
/// to the lower index.
pub fn rgbToAnsi(r: u8, g: u8, b: u8) AnsiColor {
    var best: AnsiColor = .black;
    var best_dist: u32 = std.math.maxInt(u32);
    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        const c: AnsiColor = @fromBackingInt(@intCast(i));
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

/// How far the terminal's own palette reaches. Every profile renders at
/// least the 16 ANSI colours, so the profile only decides what an `.rgb`
/// colour is downsampled to when it is written.
pub const ColorProfile = enum {
    /// The 16 `AnsiColor` entries; an `.rgb` colour maps to the nearest one.
    ansi,
    /// The 256-colour palette; an `.rgb` colour maps to the nearest index.
    ansi256,
    /// 24-bit colour, written through unchanged.
    truecolor,

    /// True only for `.truecolor`, the one profile that emits `38;2` / `48;2`.
    pub fn supportsTrueColor(self: ColorProfile) bool {
        return self == .truecolor;
    }

    /// True when the terminal has the 256-colour palette, so an `.ansi256`
    /// index needs no downsampling and an `.rgb` colour may use `38;5;N`.
    pub fn supports256(self: ColorProfile) bool {
        return self == .truecolor or self == .ansi256;
    }

    /// Always true: `.ansi` already renders the 16 ANSI colours, and every
    /// other profile renders those too. It answers "can this terminal show
    /// any colour at all", which is a question about the terminal rather
    /// than about which palette it holds; use `supports256` or
    /// `supportsTrueColor` for that.
    pub fn supportsColor(self: ColorProfile) bool {
        _ = self;
        return true;
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

test "color: rgbFromSpec accepts the complete 4-digit channel form" {
    const c = try Color.rgbFromSpec("rgb:aaaa/bbbb/cccc");
    try std.testing.expectEqual(@as(u8, 0xAA), c.rgb.r);
    try std.testing.expectEqual(@as(u8, 0xBB), c.rgb.g);
    try std.testing.expectEqual(@as(u8, 0xCC), c.rgb.b);

    // Each 16-bit channel downshifts to its high byte; the low byte must
    // still be hex for the spec to be complete.
    const downshifted = try Color.rgbFromSpec("rgb:ff00/0f00/00ff");
    try std.testing.expectEqual(@as(u8, 0xFF), downshifted.rgb.r);
    try std.testing.expectEqual(@as(u8, 0x0F), downshifted.rgb.g);
    try std.testing.expectEqual(@as(u8, 0x00), downshifted.rgb.b);

    const zeros = try Color.rgbFromSpec("rgb:0000/0000/0000");
    try std.testing.expectEqual(@as(u8, 0), zeros.rgb.r);

    // Uppercase hex is the same spec.
    const upper = try Color.rgbFromSpec("rgb:FFFF/0000/8080");
    try std.testing.expectEqual(@as(u8, 0xFF), upper.rgb.r);
    try std.testing.expectEqual(@as(u8, 0x80), upper.rgb.b);
}

test "color: rgbFromSpec rejects a spec it does not fully consume" {
    // Each of these has to be rejected rather than parsed as a prefix:
    // a terminal that answers with a malformed spec must not be reported
    // as if it had answered correctly.
    const malformed = [_][]const u8{
        "", // empty
        "rgb", // no channels
        "rgb:", // empty body
        "xyz:aaaa/bbbb/cccc", // wrong prefix
        "RGBA:aaaa/bbbb/cccc", // wrong prefix
        "rgbi:aaaa/bbbb/cccc/aaaa", // alpha form: no field to carry it
        "rgb:aaaa/bbbb", // missing a channel
        "rgb:aa/bb/cc", // channels are 16 bits
        "rgb:aaaaa/bbbb/cccc", // wrong channel length
        "rgb:zzzz/bbbb/cccc", // non-hex high byte
        "rgb:ffzz/bbbb/cccc", // non-hex low byte, dropped by the downshift
        "rgb:aaaa/bbbb/cccc/dddd", // extra channel
        "rgb:aaaa/bbbb/cccc/", // empty trailing channel
        "rgb:aaaa/bbbb/cccc:1", // trailing parameter
        " rgb:aaaa/bbbb/cccc", // leading space
        "rgb:aaaa/bbbb/cccc ", // trailing space
    };
    for (malformed) |spec| {
        try std.testing.expectError(error.InvalidColorSpec, Color.rgbFromSpec(spec));
    }
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

    // Every profile renders colour: `.ansi` is the 16-colour palette, not
    // a monochrome terminal.
    for ([_]ColorProfile{ .ansi, .ansi256, .truecolor }) |p| {
        try std.testing.expect(p.supportsColor());
    }
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
    // 255 * 0.5 + 0 * 0.5 = 127.5, truncated to 127.
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
