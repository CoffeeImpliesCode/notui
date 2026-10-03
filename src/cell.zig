//! One buffer cell: a borrowed grapheme slice, its style, and the flag that
//! marks the continuation half of a wide grapheme.

const std = @import("std");
const Style = @import("style.zig").Style;

/// What one grid position paints.
///
/// A wide grapheme occupies two columns: the lead cell carries the grapheme
/// with `wide = false`, and the column after it carries the same `style`, an
/// empty `grapheme`, and `wide = true`.
pub const Cell = struct {
    /// The grapheme to paint, borrowed from whoever drew it and never
    /// copied. The bytes must stay alive and unchanged for as long as the
    /// cell is read: a `Buffer` retains the slice, so the caller's text (a
    /// component's scratch, a model arena) has to outlive the cell.
    ///
    /// The default, `" "`, is the blank cell: it paints one space.
    grapheme: []const u8 = " ",
    /// The style to paint the grapheme with. Its `hyperlink`, when set, is
    /// borrowed on the same terms as `grapheme`.
    style: Style = .{},
    /// True for the continuation cell of a wide grapheme: it carries no
    /// grapheme of its own and is skipped when rendering.
    wide: bool = false,

    /// True when the two cells would paint identically: the same grapheme
    /// bytes, an equal `style`, and the same `wide` flag.
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
