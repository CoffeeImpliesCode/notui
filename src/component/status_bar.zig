//! StatusBar: a single-line status bar with left, center and right
//! segment groups. Segments are BORROWED — the app rebuilds or mutates
//! the slices each frame. `draw` never allocates: within-group
//! truncation borrows a grapheme-boundary prefix of the segment's own
//! text and the ellipsis marker is a constant, so every drawn cell
//! borrows bytes the caller already owns. Static — `advance` is always
//! false.

const std = @import("std");
const Buffer = @import("../buffer.zig").Buffer;
const Style = @import("../style.zig").Style;
const Width = @import("../width.zig");
const Clock = @import("component.zig").Clock;
const fitPrefixLen = Width.fitPrefixLen;

/// Allocation-free segment layout; the empty literal leaves destination cells untouched.
/// Copies share borrowed segments, text and styles, not owned storage. Keep their
/// payloads live through rendering and serialize access to each destination buffer.
pub const StatusBar = struct {
    /// Left/center/right segment groups, BORROWED (never freed, never
    /// allocated) — the app rebuilds or mutates them each frame.
    left: []const Segment = &.{},
    center: []const Segment = &.{},
    right: []const Segment = &.{},
    /// Drawn between consecutive segments WITHIN a group; null = none.
    separator: ?[]const u8 = " ",
    /// Style for separator and inter-group gap cells.
    gap_style: Style = .{},

    /// One label in a group, BORROWED like the group itself: `text` is
    /// never freed or copied here, and the drawn cells keep its bytes,
    /// so it must stay valid until the buffer that shows them has been
    /// rendered.
    pub const Segment = struct {
        /// The label as shown.
        text: []const u8,
        /// Style for this segment's cells.
        style: Style = .{},
    };

    /// Status bars never animate; `advance` is always false.
    pub fn advance(self: *StatusBar, now: Clock) bool {
        _ = self;
        _ = now;
        return false;
    }

    /// Draw the bar at (x, y), consuming the full line
    /// (`buf.width - x` columns). Alignment priority: left first (kept
    /// whole; truncated only when it alone overflows), then right
    /// (anchored to the right edge), then center (floats in the
    /// middle). Within a group, trailing segments drop first and the
    /// last surviving segment is ellipsized. Never errors for width;
    /// never allocates.
    pub fn draw(self: *StatusBar, buf: *Buffer, x: u16, y: u16, now: Clock) !u16 {
        _ = self.advance(now);
        const avail: usize = buf.width -| x;
        if (avail == 0 or y >= buf.height) return 0;

        const lw = self.groupWidth(self.left);
        const cw = self.groupWidth(self.center);
        const rw = self.groupWidth(self.right);

        // Left first (highest priority): kept whole; the center and
        // right groups are dropped when it alone overflows the line.
        if (lw >= avail) {
            _ = try self.drawGroup(buf, self.left, avail, x, y);
            return @intCast(avail);
        }

        // Right, anchored to the right edge: `right_used` columns
        // ending at x + avail (start = x + avail - right_used).
        const right_used: usize = @min(rw, avail - lw);
        if (right_used > 0) {
            const right_x: u16 = @intCast(x + avail - right_used);
            _ = try self.drawGroup(buf, self.right, right_used, right_x, y);
        }

        // Center, floating between left and right.
        const middle: usize = avail - lw - right_used;
        const cw_used: usize = @min(cw, middle);
        if (cw_used > 0) {
            const cx: u16 = @intCast(x + lw + (middle - cw_used) / 2);
            _ = try self.drawGroup(buf, self.center, cw_used, cx, y);
        }

        // Left group drawn whole at x. The blank cells between groups
        // are left empty (the renderer skips them).
        _ = try self.drawGroup(buf, self.left, lw, x, y);
        return @intCast(avail);
    }

    /// Display width of the group joined by `separator`.
    fn groupWidth(self: *const StatusBar, segments: []const Segment) usize {
        var w: usize = 0;
        for (segments, 0..) |seg, i| {
            w += Width.strWidth(seg.text);
            if (i > 0 and self.separator != null) w += Width.strWidth(self.separator.?);
        }
        return w;
    }

    /// Draw `segments` at `out_x`, truncated to `budget` columns.
    /// Within-group rule: trailing segments drop first; the last
    /// surviving segment is ellipsized. Returns the columns used.
    fn drawGroup(
        self: *const StatusBar,
        buf: *Buffer,
        segments: []const Segment,
        budget: usize,
        out_x: u16,
        y: u16,
    ) !u16 {
        if (segments.len == 0 or budget == 0) return 0;
        const sep: []const u8 = self.separator orelse "";
        const has_sep = self.separator != null;
        const sep_w: usize = Width.strWidth(sep);

        // Natural width of the joined group; draw whole when it fits.
        var natural: usize = 0;
        for (segments, 0..) |seg, i| {
            natural += Width.strWidth(seg.text);
            if (i > 0 and has_sep) natural += sep_w;
        }
        if (natural <= budget) {
            var col: u16 = out_x;
            for (segments, 0..) |seg, i| {
                if (i > 0 and has_sep) {
                    _ = try buf.draw(self.gap_style, sep, col, y);
                    col += @intCast(sep_w);
                }
                col += try buf.draw(seg.style, seg.text, col, y);
            }
            return col - out_x;
        }

        // Overflow: keep whole leading segments, ellipsize the last
        // survivor. The truncated prefix is a grapheme-boundary borrow
        // of the segment's own text and the marker is a constant, so
        // nothing is allocated.
        var col: u16 = out_x;
        var used: usize = 0;
        for (segments, 0..) |seg, i| {
            const seg_w: usize = Width.strWidth(seg.text);
            const lead: usize = if (i == 0) 0 else sep_w;
            if (used + lead + seg_w <= budget) {
                if (i > 0 and has_sep) {
                    _ = try buf.draw(self.gap_style, sep, col, y);
                    col += @intCast(sep_w);
                }
                col += try buf.draw(seg.style, seg.text, col, y);
                used += lead + seg_w;
            } else {
                // Ellipsize `seg` into the remaining budget. The
                // separator is skipped when it would crowd out the
                // marker (no dangling join).
                var rest = budget - used;
                if (i > 0 and has_sep and rest > sep_w) {
                    _ = try buf.draw(self.gap_style, sep, col, y);
                    col += @intCast(sep_w);
                    rest -= sep_w;
                }
                col += try self.drawEllipsized(buf, seg, rest, col, y);
                break;
            }
        }
        return col - out_x;
    }

    /// Draw `seg` truncated to `budget` columns with the ellipsis
    /// marker: a grapheme-safe prefix of `seg.text` (borrowed, so the
    /// cells stay valid without a scratch) plus "…" (a constant).
    /// Returns the columns consumed.
    fn drawEllipsized(self: *const StatusBar, buf: *Buffer, seg: Segment, budget: usize, x: u16, y: u16) !u16 {
        _ = self;
        const e: []const u8 = "…";
        const ell_w: usize = Width.strWidth(e);
        if (budget == 0) return 0;

        const end = fitPrefixLen(seg.text, budget -| ell_w);
        const width = Width.strWidth(seg.text[0..end]);
        var consumed: u16 = 0;
        if (end > 0) consumed += try buf.draw(seg.style, seg.text[0..end], x, y);
        if (budget > width) consumed += try buf.draw(seg.style, e, x + consumed, y);
        return consumed;
    }
};

test {
    std.testing.refAllDecls(@This());
}

/// Concatenate one row exactly as the Region's plain painter writes it
/// (spaces for blank cells, graphemes verbatim, no styles) — the
/// non-TTY frame a pipe sees.
fn plainRow(buf: *const Buffer, y: usize, out: []u8) []const u8 {
    var n: usize = 0;
    var x: usize = 0;
    while (x < buf.width) : (x += 1) {
        const cell = buf.get(@intCast(x), @intCast(y));
        if (cell.wide) continue; // covered by the lead's column
        if (cell.grapheme.len == 0 or cell.eql(.{})) {
            out[n] = ' ';
            n += 1;
            continue;
        }
        const wg = Width.graphemeWidth(cell.grapheme);
        const wcell: usize = if (wg >= 2) 2 else 1;
        if (x + wcell > buf.width) { // over-wide at the edge: reserve the column
            out[n] = ' ';
            n += 1;
            continue;
        }
        @memcpy(out[n..][0..cell.grapheme.len], cell.grapheme);
        n += cell.grapheme.len;
        x += wcell - 1;
    }
    return out[0..n];
}

const test_alloc = std.testing.allocator;

/// Concatenate one row's graphemes into `out` for test assertions
/// (wide continuations emit nothing, matching the renderer).
fn rowStr(buf: *const Buffer, y: usize, out: []u8) []const u8 {
    var n: usize = 0;
    var x: usize = 0;
    while (x < buf.width) : (x += 1) {
        const cell = buf.get(@intCast(x), @intCast(y));
        if (cell.wide or cell.grapheme.len == 0) continue;
        @memcpy(out[n..][0..cell.grapheme.len], cell.grapheme);
        n += cell.grapheme.len;
    }
    return out[0..n];
}

test "status_bar: left + right groups, right anchored to the edge" {
    var bar: StatusBar = .{
        .left = &.{ .{ .text = " NORMAL " }, .{ .text = "notui" } },
        .right = &.{.{ .text = "tail" }},
        .separator = " ",
    };
    var buf = try Buffer.init(test_alloc, 20, 1);
    defer buf.deinit();
    const consumed = try bar.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 20), consumed); // full line
    // Left group starts at x.
    try std.testing.expectEqualStrings(" ", buf.get(0, 0).grapheme);
    // Right group's last cell lands at x + avail - 1.
    try std.testing.expectEqualStrings("l", buf.get(19, 0).grapheme);
    try std.testing.expect(buf.get(14, 0).eql(.{})); // inter-group gap empty
}

test "status_bar: center group floats between left and right" {
    var bar: StatusBar = .{
        .left = &.{.{ .text = "L" }},
        .center = &.{.{ .text = "CCCC" }},
        .right = &.{.{ .text = "R" }},
        .separator = " ",
    };
    var buf = try Buffer.init(test_alloc, 20, 1);
    defer buf.deinit();
    _ = try bar.draw(&buf, 0, 0, .fromNanoseconds(0));
    // lw = 1, rw = 1, middle = 18, cw_used = 4, start = 1 + (18-4)/2 = 8.
    try std.testing.expectEqualStrings("L", buf.get(0, 0).grapheme);
    try std.testing.expectEqualStrings("C", buf.get(8, 0).grapheme);
    try std.testing.expectEqualStrings("C", buf.get(11, 0).grapheme);
    try std.testing.expectEqualStrings("R", buf.get(19, 0).grapheme);
    try std.testing.expect(buf.get(6, 0).eql(.{})); // gap left empty
}

test "status_bar: center-only line centers near the middle" {
    var bar: StatusBar = .{ .center = &.{.{ .text = "MID" }} };
    var buf = try Buffer.init(test_alloc, 20, 1);
    defer buf.deinit();
    _ = try bar.draw(&buf, 0, 0, .fromNanoseconds(0));
    // middle = 20, cw_used = 3, start = (20-3)/2 = 8.
    try std.testing.expectEqualStrings("M", buf.get(8, 0).grapheme);
    try std.testing.expectEqualStrings("D", buf.get(10, 0).grapheme);
}

test "status_bar: truncation priority drops right, then center, then left" {
    // lw = 4+1+4 = 9 (sep " "), cw = 4, rw = 4.
    var bar: StatusBar = .{
        .left = &.{ .{ .text = "AAAA" }, .{ .text = "BBBB" } },
        .center = &.{.{ .text = "CCCC" }},
        .right = &.{.{ .text = "DDDD" }},
        .separator = " ",
    };

    // Width 20: everything fits; center floats, right anchored.
    {
        var buf = try Buffer.init(test_alloc, 20, 1);
        defer buf.deinit();
        _ = try bar.draw(&buf, 0, 0, .fromNanoseconds(0));
        try std.testing.expectEqualStrings("A", buf.get(0, 0).grapheme);
        try std.testing.expectEqualStrings("C", buf.get(10, 0).grapheme); // 9 + (7-4)/2
        try std.testing.expectEqualStrings("D", buf.get(16, 0).grapheme);
    }
    // Width 12: right truncated (right_used = min(4, 3) = 3), center
    // dropped (middle = 0).
    {
        var buf = try Buffer.init(test_alloc, 12, 1);
        defer buf.deinit();
        _ = try bar.draw(&buf, 0, 0, .fromNanoseconds(0));
        try std.testing.expectEqualStrings("A", buf.get(0, 0).grapheme);
        try std.testing.expectEqualStrings("D", buf.get(9, 0).grapheme); // right at 9..11
        try std.testing.expectEqualStrings("…", buf.get(11, 0).grapheme);
        var rowbuf: [64]u8 = undefined;
        const row = rowStr(&buf, 0, &rowbuf);
        try std.testing.expect(std.mem.indexOfScalar(u8, row, 'C') == null); // center gone
    }
    // Width 8: left alone overflows (lw = 9 >= 8) — it is truncated
    // and the other groups are dropped.
    {
        var buf = try Buffer.init(test_alloc, 8, 1);
        defer buf.deinit();
        _ = try bar.draw(&buf, 0, 0, .fromNanoseconds(0));
        var rowbuf: [64]u8 = undefined;
        try std.testing.expectEqualStrings("AAAA BB…", rowStr(&buf, 0, &rowbuf));
    }
    // Width 5: the second left segment ellipsizes into one column
    // (separator skipped — it would crowd out the marker).
    {
        var buf = try Buffer.init(test_alloc, 5, 1);
        defer buf.deinit();
        _ = try bar.draw(&buf, 0, 0, .fromNanoseconds(0));
        var rowbuf: [64]u8 = undefined;
        try std.testing.expectEqualStrings("AAAA…", rowStr(&buf, 0, &rowbuf));
    }
}

test "status_bar: ellipsis marks the last surviving truncated segment" {
    var bar: StatusBar = .{
        .left = &.{ .{ .text = "AAAA" }, .{ .text = "BBBBBBBB" } },
        .separator = " ",
    };
    var buf = try Buffer.init(test_alloc, 9, 1);
    defer buf.deinit();
    _ = try bar.draw(&buf, 0, 0, .fromNanoseconds(0));
    // lw = 13 >= 9: keep "AAAA " whole, ellipsize B into 4 columns.
    var rowbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("AAAA BBB…", rowStr(&buf, 0, &rowbuf));
}

test "status_bar: separator joins adjacent segments; null draws them adjacent" {
    var bar: StatusBar = .{
        .left = &.{ .{ .text = "ab" }, .{ .text = "cd" } },
        .separator = " │ ",
    };
    var buf = try Buffer.init(test_alloc, 10, 1);
    defer buf.deinit();
    _ = try bar.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqualStrings("a", buf.get(0, 0).grapheme);
    try std.testing.expectEqualStrings("│", buf.get(3, 0).grapheme); // " │ " at 2..4
    try std.testing.expectEqualStrings("c", buf.get(5, 0).grapheme);

    bar.separator = null;
    buf.clear();
    _ = try bar.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqualStrings("a", buf.get(0, 0).grapheme);
    try std.testing.expectEqualStrings("c", buf.get(2, 0).grapheme);
}

test "status_bar: empty center/right leaves a left-only line" {
    var bar: StatusBar = .{ .left = &.{.{ .text = "hi" }} };
    var buf = try Buffer.init(test_alloc, 8, 1);
    defer buf.deinit();
    const consumed = try bar.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 8), consumed);
    try std.testing.expectEqualStrings("h", buf.get(0, 0).grapheme);
    try std.testing.expectEqualStrings("i", buf.get(1, 0).grapheme);
    try std.testing.expect(buf.get(2, 0).eql(.{})); // blank tail
}

test "status_bar: default-style render is escape-free (plain frame)" {
    var bar: StatusBar = .{
        .left = &.{ .{ .text = " NORMAL " }, .{ .text = "notui" } },
        .right = &.{.{ .text = "v0.0.0  col 80" }},
        .separator = " ",
    };
    var buf = try Buffer.init(test_alloc, 30, 1);
    defer buf.deinit();
    _ = try bar.draw(&buf, 0, 0, .fromNanoseconds(0));
    // Rebuild the row exactly as the Region's plain painter writes it
    // (spaces for blank cells, graphemes verbatim, no styles) — the
    // piped frame must carry no escapes.
    var rowbuf: [64]u8 = undefined;
    const row = plainRow(&buf, 0, &rowbuf);
    try std.testing.expectEqualStrings(" NORMAL  notui  v0.0.0  col 80", row);
    try std.testing.expect(std.mem.indexOfScalar(u8, row, 0x1b) == null);
}

test "status_bar: an ellipsized segment is drawn from the caller's own bytes" {
    // The component takes no allocator and owns no scratch: the
    // truncated prefix borrows the segment text the caller supplied, so
    // the cells stay valid after the draw with no copy anywhere.
    const text = "a very long left segment that must be ellipsized";
    var bar: StatusBar = .{ .left = &.{.{ .text = text }} };
    var buf = try Buffer.init(test_alloc, 10, 1);
    defer buf.deinit();
    _ = try bar.draw(&buf, 0, 0, .fromNanoseconds(0));

    var rowbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a very lo…", rowStr(&buf, 0, &rowbuf));

    // The nine kept cells point inside `text`; the tenth is the constant
    // marker the component appends itself.
    const lo = @intFromPtr(text.ptr);
    for (0..9) |x| {
        const g = buf.get(@intCast(x), 0).grapheme;
        const at = @intFromPtr(g.ptr);
        try std.testing.expect(at >= lo and at + g.len <= lo + text.len);
    }
    try std.testing.expectEqualStrings("…", buf.get(9, 0).grapheme);
}
