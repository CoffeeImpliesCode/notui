//! Theme: a semantic token layer between an app and `Color`/`Style`.
//!
//! An app paints a `Token` — "body text", "the focused border", "the
//! background of a code block" — and the `Theme` resolves it against the
//! terminal's `ColorProfile`: 24-bit, the 256-colour cube and grayscale
//! ramp, or the 16 ANSI colours. Resolution down-samples the token's base
//! colour to the nearest entry the terminal can show and NEVER returns
//! `Color.default`, so a themed cell always paints a colour the theme
//! chose instead of silently losing it on a low-colour terminal.
//!
//! A `Theme` is a plain value: a fixed table of `Color.Rgb` values plus a
//! compile-time attribute table. It owns no memory, there is no global
//! mutable state, and resolution allocates nothing and is deterministic —
//! the same (theme, token, profile) always yields the same `Color`. An app
//! owns one theme and passes it down.
//!
//! Capability mapping (`profileFor`): `Capabilities.color` is the profile
//! an app resolved — `detect` derives it from the raw `Capabilities.rgb`
//! truecolor probe (DA1 parameter 24 or an OSC 11 reply) — and it is the
//! only source the theme reads. An app that constrains a
//! truecolor-capable terminal to fewer colours sets `color` and gets
//! exactly that; the raw probe flag never overrides it.

const std = @import("std");
const color_mod = @import("color.zig");
const Color = color_mod.Color;
const ColorProfile = color_mod.ColorProfile;
const Style = @import("style.zig").Style;
const Capabilities = @import("caps.zig").Capabilities;

/// Semantic colour roles, one per painted element. An app picks a token
/// and never a literal colour, so a theme switch repaints it everywhere.
pub const Token = enum(u8) {
    /// Body text: the app's default foreground.
    text,
    /// Secondary text: hints, timestamps, inactive labels.
    text_dim,
    /// Emphasis: headings, focused controls, key hints.
    accent,
    /// A good result: passed checks, completed steps.
    success,
    /// A recoverable problem: deprecations, retries.
    warning,
    /// A failure: errors and invalid input.
    @"error",
    /// Structural lines: panel and box outlines, dividers.
    border,
    /// The background of the selected row in a list or picker.
    selection,
    /// The background behind inline and fenced code.
    code_bg,
};

/// Which `Style` field a token's colour is written to.
pub const Role = enum {
    /// Painted as `Style.fg`.
    fg,
    /// Painted as `Style.bg`.
    bg,
};

/// The field `token` paints: surface tokens fill a background, every
/// other token fills the foreground.
pub fn roleOf(token: Token) Role {
    return switch (token) {
        .selection, .code_bg => .bg,
        else => .fg,
    };
}

/// The text attributes `token` declares. Attributes belong to the role,
/// not to the palette, so both built-in themes share them.
pub fn attrsOf(token: Token) Style.Attrs {
    return switch (token) {
        .text_dim => .{ .dim = true },
        .accent, .@"error" => .{ .bold = true },
        else => .{},
    };
}

/// One base colour per token, always truecolor. `Theme.color` down-samples
/// it for the profile the terminal reported.
pub const Palette = struct {
    text: Color.Rgb,
    text_dim: Color.Rgb,
    accent: Color.Rgb,
    success: Color.Rgb,
    warning: Color.Rgb,
    @"error": Color.Rgb,
    border: Color.Rgb,
    selection: Color.Rgb,
    code_bg: Color.Rgb,
};

/// The built-in dark palette: light ink for a terminal whose background is
/// dark.
pub const dark_palette: Palette = .{
    .text = hex(0xd4d4d8),
    .text_dim = hex(0x8a8f98),
    .accent = hex(0x7aa2f7),
    .success = hex(0x9ece6a),
    .warning = hex(0xe0af68),
    .@"error" = hex(0xf7768e),
    .border = hex(0x414868),
    .selection = hex(0x283457),
    .code_bg = hex(0x1f2335),
};

/// The built-in light palette: dark ink for a terminal whose background is
/// light.
pub const light_palette: Palette = .{
    .text = hex(0x24292f),
    .text_dim = hex(0x57606a),
    .accent = hex(0x0969da),
    .success = hex(0x1a7f37),
    .warning = hex(0x9a6700),
    .@"error" = hex(0xcf222e),
    .border = hex(0xd0d7de),
    .selection = hex(0xddf4ff),
    .code_bg = hex(0xf6f8fa),
};

/// `Color.Rgb` for a `0xRRGGBB` literal, so the palettes read as hex. The
/// palettes are `const`s, so every call is evaluated at compile time.
fn hex(rgb24: u24) Color.Rgb {
    return .{
        .r = @intCast((rgb24 >> 16) & 0xff),
        .g = @intCast((rgb24 >> 8) & 0xff),
        .b = @intCast(rgb24 & 0xff),
    };
}

/// A palette plus the token rules. A `Theme` is a value: copy `dark` or
/// `light` and edit `palette` for a custom theme, then pass it down.
pub const Theme = struct {
    /// Base colours, one per token.
    palette: Palette,

    /// Light ink for a dark terminal background.
    pub const dark: Theme = .{ .palette = dark_palette };
    /// Dark ink for a light terminal background.
    pub const light: Theme = .{ .palette = light_palette };

    /// The base truecolor value of `token`, before profile down-sampling.
    pub fn base(self: Theme, token: Token) Color.Rgb {
        return switch (token) {
            .text => self.palette.text,
            .text_dim => self.palette.text_dim,
            .accent => self.palette.accent,
            .success => self.palette.success,
            .warning => self.palette.warning,
            .@"error" => self.palette.@"error",
            .border => self.palette.border,
            .selection => self.palette.selection,
            .code_bg => self.palette.code_bg,
        };
    }

    /// Resolve `token` for `profile`.
    ///
    /// Each profile gets the nearest colour it can show: truecolor the
    /// base value exactly, ansi256 the nearest cube or grayscale entry,
    /// ansi the nearest of the 16 ANSI colours. The result is never
    /// `Color.default`.
    pub fn color(self: Theme, token: Token, profile: ColorProfile) Color {
        const rgb = self.base(token);
        return switch (profile) {
            .truecolor => .{ .rgb = rgb },
            .ansi256 => .{ .ansi256 = color_mod.rgbToAnsi256(rgb.r, rgb.g, rgb.b) },
            .ansi => .{ .ansi = color_mod.rgbToAnsi(rgb.r, rgb.g, rgb.b) },
        };
    }

    /// The style for `token`: the resolved colour in the field its role
    /// names, plus the attributes the token declares. The other colour
    /// field stays null so the app's own base style shows through
    /// `Style.merge` — a surface token never clobbers the text colour.
    pub fn style(self: Theme, token: Token, profile: ColorProfile) Style {
        const resolved = self.color(token, profile);
        const attrs = attrsOf(token);
        return switch (roleOf(token)) {
            .fg => .{ .fg = resolved, .attrs = attrs },
            .bg => .{ .bg = resolved, .attrs = attrs },
        };
    }

    /// `color` for an app that has already probed its terminal: the
    /// profile comes from `profileFor(caps)`.
    pub fn colorFor(self: Theme, token: Token, caps: Capabilities) Color {
        return self.color(token, profileFor(caps));
    }

    /// `style` for an app that has already probed its terminal.
    pub fn styleFor(self: Theme, token: Token, caps: Capabilities) Style {
        return self.style(token, profileFor(caps));
    }
};

/// The colour profile to resolve tokens against, from what the app probed.
///
/// `caps.color` is the profile an app resolved and the only source read
/// here; `caps.rgb` is the raw truecolor probe (DA1 parameter 24 or an OSC
/// 11 reply) that `detect` already folded into `color`. An app that
/// constrains a truecolor-capable terminal to a narrower profile sets
/// `color` and gets it, with no speculative override from `rgb`.
pub fn profileFor(caps: Capabilities) ColorProfile {
    return caps.color;
}

test {
    std.testing.refAllDecls(@This());
}

/// The profiles every token must resolve for.
const swept_profiles = [_]ColorProfile{ .truecolor, .ansi256, .ansi };

/// The two built-in themes.
const swept_themes = [_]Theme{ Theme.dark, Theme.light };

/// One probed terminal: the raw truecolor flag `detect` recorded, and the
/// colour profile an app resolved for it.
const ProfileCase = struct {
    caps: Capabilities,
    profile: ColorProfile,
};

/// Perceived brightness (ITU-R BT.601 weights, unscaled). Only used to
/// compare two colours, so the scale does not matter.
fn luma(rgb: Color.Rgb) u32 {
    return 299 * @as(u32, rgb.r) + 587 * @as(u32, rgb.g) + 114 * @as(u32, rgb.b);
}

/// The RGB value a resolved colour paints. `Color.default` paints nothing
/// and fails the test that asked for a colour.
fn expectRgb(c: Color) !Color.Rgb {
    return switch (c) {
        .rgb => |rgb| rgb,
        .ansi => |ansi| ansi.toRgb(),
        .ansi256 => |index| color_mod.ansi256ToRgb(index),
        .default => error.TestUnexpectedResult,
    };
}

/// Squared channel distance between two RGB values.
fn sqDist(a: Color.Rgb, b: Color.Rgb) u32 {
    const dr: i32 = @as(i32, a.r) - @as(i32, b.r);
    const dg: i32 = @as(i32, a.g) - @as(i32, b.g);
    const db: i32 = @as(i32, a.b) - @as(i32, b.b);
    return @intCast(dr * dr + dg * dg + db * db);
}

test "theme: every token resolves to a colour, never to default" {
    for (swept_themes) |theme| {
        for (std.meta.tags(Token)) |token| {
            for (swept_profiles) |profile| {
                switch (theme.color(token, profile)) {
                    .default => try std.testing.expect(false),
                    .rgb => try std.testing.expectEqual(ColorProfile.truecolor, profile),
                    .ansi256 => |index| {
                        try std.testing.expectEqual(ColorProfile.ansi256, profile);
                        // The 256-colour profile must not use the 0-15
                        // block, which is the terminal's 16-colour palette.
                        try std.testing.expect(index >= 16);
                    },
                    .ansi => try std.testing.expectEqual(ColorProfile.ansi, profile),
                }
            }
        }
    }
}

test "theme: an off-cube base colour degrades to a nearer, different entry" {
    // Both accents are off the 6x6x6 cube: dark 0x7aa2f7 has r=122 and
    // light 0x0969da has r=9, neither one of the cube levels
    // 0/95/135/175/215/255.
    for ([_]Theme{ Theme.dark, Theme.light }) |theme| {
        const base = theme.base(.accent);
        const exact = theme.color(.accent, .truecolor);
        try std.testing.expect(Color.eql(exact, .{ .rgb = base }));

        const small = try expectRgb(theme.color(.accent, .ansi256));
        const smaller = try expectRgb(theme.color(.accent, .ansi));

        // Every profile resolves the token to a value of its own...
        try std.testing.expect(!Color.eql(exact, .{ .rgb = small }));
        try std.testing.expect(!Color.eql(exact, .{ .rgb = smaller }));
        try std.testing.expect(!Color.eql(.{ .rgb = small }, .{ .rgb = smaller }));
        // ...and the 256-colour entry is the closer of the two, so the
        // wider palette is really in use.
        try std.testing.expect(sqDist(base, small) < sqDist(base, smaller));
    }
}

test "theme: style carries the attributes the token declares" {
    const dim = Theme.dark.style(.text_dim, .truecolor);
    try std.testing.expect(dim.attrs.dim);
    try std.testing.expect(!dim.attrs.bold);
    try std.testing.expect(!dim.attrs.italic);

    const accent = Theme.light.style(.accent, .ansi256);
    try std.testing.expect(accent.attrs.bold);
    try std.testing.expect(!accent.attrs.dim);

    const err = Theme.light.style(.@"error", .ansi);
    try std.testing.expect(err.attrs.bold);
    try std.testing.expect(!err.attrs.dim);

    // Tokens that declare nothing must not pick up stray attributes, and
    // a surface must not, so a selection never bolds the text merged over
    // it.
    for ([_]Token{ .text, .border, .success, .warning, .selection, .code_bg }) |token| {
        const s = Theme.dark.style(token, .truecolor);
        inline for (@typeInfo(Style.Attrs).@"struct".fields) |field| {
            try std.testing.expect(!@field(s.attrs, field.name));
        }
    }

    // A token paints either a foreground or a background, never both.
    for (swept_themes) |theme| {
        for (std.meta.tags(Token)) |token| {
            const s = theme.style(token, .ansi256);
            switch (roleOf(token)) {
                .fg => {
                    try std.testing.expect(s.fg != null);
                    try std.testing.expect(s.bg == null);
                },
                .bg => {
                    try std.testing.expect(s.fg == null);
                    try std.testing.expect(s.bg != null);
                },
            }
        }
    }
}

test "theme: switching dark for light changes resolution" {
    const switched = [_]Token{ .text, .accent, .selection, .code_bg };
    for (switched) |token| {
        for (swept_profiles) |profile| {
            try std.testing.expect(!Color.eql(
                Theme.dark.color(token, profile),
                Theme.light.color(token, profile),
            ));
        }
    }
}

test "theme: down-sampled ink stays legible against its surfaces" {
    // The dark theme's ink is lighter than the surfaces it sits on; the
    // light theme's is darker. Down-sampling must not invert that.
    try expectContrast(Theme.dark, .lighter_ink);
    try expectContrast(Theme.light, .darker_ink);
}

/// Which side of its surfaces a theme's body text must sit on.
const InkSide = enum { lighter_ink, darker_ink };

fn expectContrast(theme: Theme, side: InkSide) !void {
    for ([_]ColorProfile{ .ansi256, .ansi }) |profile| {
        const ink = luma(try expectRgb(theme.color(.text, profile)));
        for ([_]Token{ .selection, .code_bg }) |surface| {
            const bg = luma(try expectRgb(theme.color(surface, profile)));
            switch (side) {
                .lighter_ink => try std.testing.expect(ink > bg),
                .darker_ink => try std.testing.expect(ink < bg),
            }
        }
    }
}

test "theme: the caps profile, not the raw rgb probe, gates resolution" {
    // `Capabilities.color` is what the app resolved; `rgb` is only the
    // raw probe `detect` already folded into it. A truecolor terminal an
    // app holds to 16 or 256 colours must paint those colours.
    const cases = [_]ProfileCase{
        .{ .caps = .{ .rgb = true, .color = .truecolor }, .profile = .truecolor },
        .{ .caps = .{ .rgb = true, .color = .ansi256 }, .profile = .ansi256 },
        .{ .caps = .{ .rgb = true, .color = .ansi }, .profile = .ansi },
        .{ .caps = .{ .rgb = false, .color = .truecolor }, .profile = .truecolor },
        .{ .caps = .{ .rgb = false, .color = .ansi256 }, .profile = .ansi256 },
        .{ .caps = .{ .rgb = false, .color = .ansi }, .profile = .ansi },
    };

    for (cases) |c| {
        for (swept_themes) |theme| {
            for (std.meta.tags(Token)) |token| {
                switch (theme.colorFor(token, c.caps)) {
                    .default => try std.testing.expect(false),
                    .rgb => try std.testing.expectEqual(ColorProfile.truecolor, c.profile),
                    .ansi256 => try std.testing.expectEqual(ColorProfile.ansi256, c.profile),
                    .ansi => try std.testing.expectEqual(ColorProfile.ansi, c.profile),
                }
            }
        }
    }
}

test "theme: a custom palette overrides one token and inherits the rest" {
    var custom = Theme.dark;
    custom.palette.accent = hex(0xff8800);

    try std.testing.expectEqual(hex(0xff8800), custom.base(.accent));
    try std.testing.expectEqual(Theme.dark.base(.text), custom.base(.text));
    try std.testing.expect(!Color.eql(
        Theme.dark.color(.accent, .truecolor),
        custom.color(.accent, .truecolor),
    ));
}
