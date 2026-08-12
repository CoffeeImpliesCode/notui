//! Cell: a grapheme slice, its style, and the wide-glyph continuation
//! flag. Shape from architecture §5 (slice-based, unlike zigzag
//! screen.zig's `char: u21`). No zg import.

const std = @import("std");
const Style = @import("style.zig").Style;

/// A single cell in the buffer grid.
///
/// `grapheme` points into the app's text arena; it is borrowed, never
/// copied (architecture §3). A wide grapheme occupies two columns: the
/// lead cell carries the grapheme with `wide = false`; the continuation
/// cell carries the same style, an empty grapheme, and `wide = true`.
pub const Cell = struct {
    /// Grapheme text, borrowed from the caller.
    grapheme: []const u8 = " ",
    /// Cell style.
    style: Style = .{},
    /// True for the continuation cell of a wide grapheme.
    wide: bool = false,

    /// Structural equality: slice eql + style eql + wide flag.
    pub fn eql(self: Cell, other: Cell) bool {
        return self.wide == other.wide and
            std.mem.eql(u8, self.grapheme, other.grapheme) and
            self.style.eql(other.style);
    }
};

test {
    std.testing.refAllDecls(@This());
}

test "cell: defaults" {
    const c: Cell = .{};
    try std.testing.expectEqualStrings(" ", c.grapheme);
    try std.testing.expectEqual(Style{}, c.style);
    try std.testing.expect(!c.wide);
}

test "cell: eql" {
    const base: Cell = .{
        .grapheme = "a",
        .style = .{ .fg = .{ .ansi = .red }, .attrs = .{ .bold = true } },
        .wide = false,
    };
    try std.testing.expect(base.eql(base));
    try std.testing.expect((Cell{}).eql(Cell{}));

    // Same content in different slices is equal (content-based).
    const copy: []const u8 = "a";
    try std.testing.expect(base.eql(.{ .grapheme = copy, .style = base.style, .wide = base.wide }));

    // Different grapheme.
    try std.testing.expect(!base.eql(.{ .grapheme = "b", .style = base.style, .wide = base.wide }));
    // Empty vs space.
    try std.testing.expect(!(Cell{}).eql(.{ .grapheme = "" }));
    // Different style.
    try std.testing.expect(!base.eql(.{ .grapheme = base.grapheme, .style = .{}, .wide = base.wide }));
    try std.testing.expect(!base.eql(.{
        .grapheme = base.grapheme,
        .style = .{ .bg = .{ .ansi256 = 1 } },
        .wide = base.wide,
    }));
    // Different wide flag.
    try std.testing.expect(!base.eql(.{ .grapheme = base.grapheme, .style = base.style, .wide = true }));
}
