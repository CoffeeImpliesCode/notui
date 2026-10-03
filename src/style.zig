//! Cell styling: foreground and background colour, hyperlink target, and
//! the text attribute flags.
//!
//! `emit` turns a `Style` into SGR parameters; nothing in this module writes
//! bytes.

const std = @import("std");
const Color = @import("color.zig").Color;

/// The style one cell paints with.
///
/// `Style` owns nothing: `hyperlink` is a borrowed slice, so a copy of a
/// `Style` copies the borrow, not the bytes, and both must outlive whatever
/// reads the copy.
pub const Style = struct {
    /// Foreground colour. `null` inherits `base.fg` in `merge`, and emits
    /// nothing on its own — which is not the same as `Color.default`, which
    /// asks for the terminal's own foreground.
    fg: ?Color = null,
    /// Background colour, with the same `null` meaning as `fg`.
    bg: ?Color = null,
    /// The OSC 8 hyperlink target, borrowed from the caller.
    ///
    /// This package does not emit OSC 8, so the value never reaches the
    /// terminal; it is carried on a `Style` so a hyperlink change is visible
    /// to `eql` and to the frame differ.
    hyperlink: ?[]const u8 = null,
    /// The attribute flags.
    attrs: Attrs = .{},

    /// The SGR attributes, packed into one byte.
    pub const Attrs = packed struct {
        bold: bool = false,
        dim: bool = false,
        italic: bool = false,
        underline: bool = false,
        blink: bool = false,
        reverse: bool = false,
        strikethrough: bool = false,
    };

    /// True when the two styles would emit the same SGR parameters and carry
    /// the same hyperlink: colours compare by tag, `hyperlink` compares by
    /// content, and an unset field is not the same as `Color.default`.
    ///
    /// Two hyperlinks that are equal in content but different slices are
    /// equal here, so a caller that mutates a URI in place can hide a style
    /// change from the frame differ.
    pub fn eql(self: Style, other: Style) bool {
        if (!colorEql(self.fg, other.fg)) return false;
        if (!colorEql(self.bg, other.bg)) return false;
        if (!hyperlinkEql(self.hyperlink, other.hyperlink)) return false;
        return self.attrs == other.attrs;
    }

    /// `self` layered over `base`: a non-null `fg`, `bg` or `hyperlink` in
    /// `self` wins, and a null one inherits `base`'s value. Attributes merge
    /// per flag and can only be turned on, never off, so a merged style can
    /// carry attributes neither input had on its own.
    ///
    /// The result borrows `hyperlink` from whichever argument supplied it.
    pub fn merge(self: Style, base: Style) Style {
        return .{
            .fg = self.fg orelse base.fg,
            .bg = self.bg orelse base.bg,
            .hyperlink = self.hyperlink orelse base.hyperlink,
            .attrs = .{
                .bold = self.attrs.bold or base.attrs.bold,
                .dim = self.attrs.dim or base.attrs.dim,
                .italic = self.attrs.italic or base.attrs.italic,
                .underline = self.attrs.underline or base.attrs.underline,
                .blink = self.attrs.blink or base.attrs.blink,
                .reverse = self.attrs.reverse or base.attrs.reverse,
                .strikethrough = self.attrs.strikethrough or base.attrs.strikethrough,
            },
        };
    }
};

fn colorEql(a: ?Color, b: ?Color) bool {
    if (a) |ca| {
        if (b) |cb| return Color.eql(ca, cb);
        return false;
    }
    return b == null;
}

fn hyperlinkEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |sa| {
        if (b) |sb| return std.mem.eql(u8, sa, sb);
        return false;
    }
    return b == null;
}

test {
    std.testing.refAllDecls(@This());
}

test "style: eql identical" {
    const s: Style = .{
        .fg = .{ .ansi = .red },
        .bg = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
        .hyperlink = "https://example.com",
        .attrs = .{ .bold = true, .italic = true, .strikethrough = true },
    };
    try std.testing.expect(s.eql(s));
    try std.testing.expect((Style{}).eql(Style{}));
}

test "style: eql differs per field" {
    const base: Style = .{
        .fg = .{ .ansi = .red },
        .bg = .{ .ansi256 = 42 },
        .hyperlink = "u",
        .attrs = .{ .bold = true },
    };

    // fg
    try std.testing.expect(!base.eql(Style{
        .fg = .{ .ansi = .blue },
        .bg = base.bg,
        .hyperlink = base.hyperlink,
        .attrs = base.attrs,
    }));
    try std.testing.expect(!base.eql(Style{
        .fg = null,
        .bg = base.bg,
        .hyperlink = base.hyperlink,
        .attrs = base.attrs,
    }));
    // bg
    try std.testing.expect(!base.eql(Style{
        .fg = base.fg,
        .bg = .{ .ansi256 = 43 },
        .hyperlink = base.hyperlink,
        .attrs = base.attrs,
    }));
    // hyperlink: value vs value, null vs value
    try std.testing.expect(!base.eql(Style{ .fg = base.fg, .bg = base.bg, .hyperlink = "v", .attrs = base.attrs }));
    try std.testing.expect(!base.eql(Style{ .fg = base.fg, .bg = base.bg, .hyperlink = null, .attrs = base.attrs }));
    try std.testing.expect(!(Style{}).eql(Style{ .hyperlink = "" }));
    // same hyperlink content in different slices is equal
    const heap_like: []const u8 = "u";
    try std.testing.expect(base.eql(Style{
        .fg = base.fg,
        .bg = base.bg,
        .hyperlink = heap_like,
        .attrs = base.attrs,
    }));
    // attrs
    try std.testing.expect(!base.eql(Style{ .fg = base.fg, .bg = base.bg, .hyperlink = base.hyperlink, .attrs = .{} }));
    try std.testing.expect(!base.eql(Style{
        .fg = base.fg,
        .bg = base.bg,
        .hyperlink = base.hyperlink,
        .attrs = .{ .dim = true },
    }));
    try std.testing.expect(!base.eql(Style{
        .fg = base.fg,
        .bg = base.bg,
        .hyperlink = base.hyperlink,
        .attrs = .{ .bold = true, .underline = true },
    }));
}

test "style: merge self overrides base per field" {
    const base: Style = .{
        .fg = .{ .ansi = .blue },
        .bg = .{ .ansi256 = 21 },
        .hyperlink = "base",
        .attrs = .{ .bold = true, .dim = true },
    };
    const self: Style = .{
        .fg = .{ .ansi = .red },
        .hyperlink = "self",
        .attrs = .{ .bold = true, .italic = true },
    };

    const m = self.merge(base);
    try std.testing.expectEqual(Color{ .ansi = .red }, m.fg.?);
    try std.testing.expectEqual(Color{ .ansi256 = 21 }, m.bg.?);
    try std.testing.expectEqualStrings("self", m.hyperlink.?);
    try std.testing.expect(m.attrs.bold);
    try std.testing.expect(m.attrs.dim); // base dim falls through
    try std.testing.expect(m.attrs.italic);
    try std.testing.expect(!m.attrs.underline);
}

test "style: merge defaults fall through" {
    const base: Style = .{
        .fg = .{ .ansi = .green },
        .bg = .{ .rgb = .{ .r = 9, .g = 9, .b = 9 } },
        .hyperlink = "base",
        .attrs = .{ .underline = true, .reverse = true },
    };
    // An empty self inherits everything from base.
    const m = (Style{}).merge(base);
    try std.testing.expectEqual(Color{ .ansi = .green }, m.fg.?);
    try std.testing.expectEqual(Color{ .rgb = .{ .r = 9, .g = 9, .b = 9 } }, m.bg.?);
    try std.testing.expectEqualStrings("base", m.hyperlink.?);
    try std.testing.expect(m.attrs.underline);
    try std.testing.expect(m.attrs.reverse);
    try std.testing.expect(!m.attrs.bold);
}

test "style: merge attrs precedence matrix" {
    // A flag set in self always wins; a flag unset in self inherits base.
    try std.testing.expect(
        (Style{ .attrs = .{ .bold = true } }).merge(Style{ .attrs = .{ .bold = false } }).attrs.bold,
    );
    try std.testing.expect(
        (Style{ .attrs = .{ .bold = true } }).merge(Style{ .attrs = .{ .bold = true } }).attrs.bold,
    );
    try std.testing.expect(
        (Style{ .attrs = .{ .bold = false } }).merge(Style{ .attrs = .{ .bold = true } }).attrs.bold,
    );
    try std.testing.expect(
        !(Style{ .attrs = .{ .bold = false } }).merge(Style{ .attrs = .{ .bold = false } }).attrs.bold,
    );

    // Full 7-field matrix: each attr of self or-ing with base.
    const base: Style = .{ .attrs = .{ .bold = true, .italic = true, .blink = true, .strikethrough = true } };
    const self: Style = .{ .attrs = .{ .bold = true, .dim = true, .underline = true, .reverse = true } };
    const m = self.merge(base);
    try std.testing.expect(m.attrs.bold);
    try std.testing.expect(m.attrs.dim);
    try std.testing.expect(m.attrs.italic);
    try std.testing.expect(m.attrs.underline);
    try std.testing.expect(m.attrs.blink);
    try std.testing.expect(m.attrs.reverse);
    try std.testing.expect(m.attrs.strikethrough);
}
