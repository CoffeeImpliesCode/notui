//! Style: foreground/background colors, hyperlink, and text attributes.
//!
//! Shape from architecture §5; merge semantics simplified from zigzag
//! Style-builder inheritance to per-field precedence. No zg import.

const std = @import("std");
const Color = @import("color.zig").Color;

/// Text styling for a cell.
pub const Style = struct {
    /// Foreground color; null inherits from `base` on merge.
    fg: ?Color = null,
    /// Background color; null inherits from `base` on merge.
    bg: ?Color = null,
    /// Hyperlink URI (OSC 8). Emission is deferred (not written by
    /// emit.writeStyle).
    hyperlink: ?[]const u8 = null,
    /// Text attributes.
    attrs: Attrs = .{},

    /// Packed text attribute flags. `@sizeOf(Attrs) == 1`.
    pub const Attrs = packed struct {
        bold: bool = false,
        dim: bool = false,
        italic: bool = false,
        underline: bool = false,
        blink: bool = false,
        reverse: bool = false,
        strikethrough: bool = false,
    };

    /// Structural equality. Hyperlinks compare by `std.mem.eql`; an
    /// unset field (`null`) differs from a set one, and `Color.default`
    /// differs from `null`.
    pub fn eql(self: Style, other: Style) bool {
        if (!colorEql(self.fg, other.fg)) return false;
        if (!colorEql(self.bg, other.bg)) return false;
        if (!hyperlinkEql(self.hyperlink, other.hyperlink)) return false;
        return self.attrs == other.attrs;
    }

    /// Merge `self` over `base` with documented precedence: non-null
    /// fields of `self` override `base`; null fields inherit `base`.
    /// Attributes merge per field — a flag set in `self` wins, otherwise
    /// `base`'s flag shows through (merging can only turn a flag on).
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
    const s = Style{
        .fg = .{ .ansi = .red },
        .bg = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
        .hyperlink = "https://example.com",
        .attrs = .{ .bold = true, .italic = true, .strikethrough = true },
    };
    try std.testing.expect(s.eql(s));
    try std.testing.expect((Style{}).eql(Style{}));
}

test "style: eql differs per field" {
    const base = Style{ .fg = .{ .ansi = .red }, .bg = .{ .ansi256 = 42 }, .hyperlink = "u", .attrs = .{ .bold = true } };

    // fg
    try std.testing.expect(!base.eql(Style{ .fg = .{ .ansi = .blue }, .bg = base.bg, .hyperlink = base.hyperlink, .attrs = base.attrs }));
    try std.testing.expect(!base.eql(Style{ .fg = null, .bg = base.bg, .hyperlink = base.hyperlink, .attrs = base.attrs }));
    // bg
    try std.testing.expect(!base.eql(Style{ .fg = base.fg, .bg = .{ .ansi256 = 43 }, .hyperlink = base.hyperlink, .attrs = base.attrs }));
    // hyperlink: value vs value, null vs value
    try std.testing.expect(!base.eql(Style{ .fg = base.fg, .bg = base.bg, .hyperlink = "v", .attrs = base.attrs }));
    try std.testing.expect(!base.eql(Style{ .fg = base.fg, .bg = base.bg, .hyperlink = null, .attrs = base.attrs }));
    try std.testing.expect(!(Style{}).eql(Style{ .hyperlink = "" }));
    // same hyperlink content in different slices is equal
    const heap_like: []const u8 = "u";
    try std.testing.expect(base.eql(Style{ .fg = base.fg, .bg = base.bg, .hyperlink = heap_like, .attrs = base.attrs }));
    // attrs
    try std.testing.expect(!base.eql(Style{ .fg = base.fg, .bg = base.bg, .hyperlink = base.hyperlink, .attrs = .{} }));
    try std.testing.expect(!base.eql(Style{ .fg = base.fg, .bg = base.bg, .hyperlink = base.hyperlink, .attrs = .{ .dim = true } }));
    try std.testing.expect(!base.eql(Style{ .fg = base.fg, .bg = base.bg, .hyperlink = base.hyperlink, .attrs = .{ .bold = true, .underline = true } }));
}

test "style: merge self overrides base per field" {
    const base = Style{
        .fg = .{ .ansi = .blue },
        .bg = .{ .ansi256 = 21 },
        .hyperlink = "base",
        .attrs = .{ .bold = true, .dim = true },
    };
    const self = Style{
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
    const base = Style{
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
    try std.testing.expect((Style{ .attrs = .{ .bold = true } }).merge(Style{ .attrs = .{ .bold = false } }).attrs.bold);
    try std.testing.expect((Style{ .attrs = .{ .bold = true } }).merge(Style{ .attrs = .{ .bold = true } }).attrs.bold);
    try std.testing.expect((Style{ .attrs = .{ .bold = false } }).merge(Style{ .attrs = .{ .bold = true } }).attrs.bold);
    try std.testing.expect(!(Style{ .attrs = .{ .bold = false } }).merge(Style{ .attrs = .{ .bold = false } }).attrs.bold);

    // Full 7-field matrix: each attr of self or-ing with base.
    const base = Style{ .attrs = .{ .bold = true, .italic = true, .blink = true, .strikethrough = true } };
    const self = Style{ .attrs = .{ .bold = true, .dim = true, .underline = true, .reverse = true } };
    const m = self.merge(base);
    try std.testing.expect(m.attrs.bold);
    try std.testing.expect(m.attrs.dim);
    try std.testing.expect(m.attrs.italic);
    try std.testing.expect(m.attrs.underline);
    try std.testing.expect(m.attrs.blink);
    try std.testing.expect(m.attrs.reverse);
    try std.testing.expect(m.attrs.strikethrough);
}

test "style: @sizeOf(Attrs) == 1" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(Style.Attrs));
}
