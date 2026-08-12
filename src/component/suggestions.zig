//! Suggestions: a selectable completion-candidate list drawn below a
//! point (suggestion-ui-contract.md §2). Rows are drawn at (x, y),
//! (x, y+1), … up to `max_rows`, each width-truncated at a grapheme
//! boundary with the ellipsis marker; the selected row is drawn with
//! `selected_style` (default: reverse video). Scrolls a window around
//! `selected` when candidates exceed `max_rows` (the zigzag
//! `ensureVisible` rule, list.zig:341-344). Zero-alloc draw: truncation
//! writes to the caller-owned `scratch` only (the borrow model,
//! baseui-contract.md §3).

const std = @import("std");
const Buffer = @import("../buffer.zig").Buffer;
const Style = @import("../style.zig").Style;
const Width = @import("../width.zig");
const Clock = @import("component.zig").Clock;

/// Shared zero-config scratch; only written when a default-configured
/// Suggestions truncates (single-threaded UI; callers that care pass their
/// own scratch and allocator — the Text pattern, src/component/text.zig:11-13).
var default_scratch: std.ArrayList(u8) = .empty;

/// A selectable completion-candidate list drawn below a point. Rows are
/// drawn at (x, y), (x, y+1), … up to `max_rows`, each width-truncated at a
/// grapheme boundary with the ellipsis marker; the selected row is drawn
/// with `selected_style` (default: reverse video). Scrolls a window around
/// `selected` when candidates exceed `max_rows` (the zigzag `ensureVisible`
/// rule, list.zig:341-344). Zero-alloc draw: truncation writes to `scratch`
/// only. Candidates MUST NOT contain '\n' (a completion is one symbol); the
/// draw splits scratch on '\n' to find row boundaries.
pub const Suggestions = struct {
    /// Candidate strings, BORROWED (never freed, never allocated). The app
    /// owns them (e.g. the REPL's arena).
    candidates: []const []const u8 = &.{},
    /// Index of the currently-selected candidate. Clamped into range on
    /// draw.
    selected: usize = 0,
    /// Maximum rows the popup may draw; the window scrolls around
    /// `selected` when candidates exceeds this.
    max_rows: u16 = 10,
    /// Style for non-selected rows.
    style: Style = .{},
    /// Style for the selected row (default: reverse video highlight).
    selected_style: Style = .{ .attrs = .{ .reverse = true } },
    /// Truncation marker appended when a candidate exceeds the available
    /// width; null = no marker.
    ellipsis: ?[]const u8 = "…",
    /// Caller-owned scratch for truncation output (the borrow model).
    scratch: *std.ArrayList(u8) = &default_scratch,

    /// Static component: never animates.
    pub fn advance(self: *Suggestions, now: Clock) bool {
        _ = self;
        _ = now;
        return false;
    }

    /// First visible candidate index: a window of `min(candidates.len,
    /// max_rows)` rows scrolled so `selected` is always visible (the zigzag
    /// `ensureVisible` rule, list.zig:341-344).
    fn windowStart(self: *const Suggestions) usize {
        const n = self.candidates.len;
        const win = @min(@as(usize, self.max_rows), n);
        if (win == 0) return 0;
        const sel = @min(self.selected, n - 1);
        if (sel >= win) return sel - win + 1; // scrolled down; clamp below
        return 0;
    }

    /// Draw the candidate window with its top-left at (x, y). `alloc` backs
    /// `scratch` — pass the allocator that owns the scratch's memory (the
    /// Text pattern). Returns the number of ROWS the popup would occupy
    /// (`min(candidates.len, max_rows)`), so the caller can size the band;
    /// 0 when there are no candidates or nothing is drawable. Never errors
    /// for width (graceful truncation).
    pub fn draw(
        self: *Suggestions,
        alloc: std.mem.Allocator,
        buf: *Buffer,
        x: u16,
        y: u16,
        now: Clock,
    ) !u16 {
        _ = now; // static component; nothing to advance
        const n = self.candidates.len;
        if (n == 0) return 0;
        const avail: usize = buf.width -| x;
        if (avail == 0 or y >= buf.height) return 0;

        const win = @min(@as(usize, self.max_rows), n);
        const start = self.windowStart();
        const shown: u16 = @intCast(win);

        // Materialize every visible row into scratch, joined by '\n', so
        // the cells drawn below keep a stable borrow (the wrap pattern in
        // Text, src/component/text.zig:114-130). Candidates never contain
        // '\n', so the join is unambiguous.
        self.scratch.clearRetainingCapacity();
        const ellipsis = self.ellipsis orelse "";
        const ellipsis_w = Width.strWidth(ellipsis);
        var first = true;
        for (0..win) |i| {
            if (!first) try self.scratch.append(alloc, '\n');
            first = false;
            const cand = self.candidates[start + i];
            if (Width.strWidth(cand) <= avail) {
                try self.scratch.appendSlice(alloc, cand); // fits: borrow
            } else {
                // Truncate at a grapheme boundary to avail minus the marker.
                const t = try Width.truncate(alloc, cand, avail -| ellipsis_w);
                defer alloc.free(t);
                try self.scratch.appendSlice(alloc, t);
                try self.scratch.appendSlice(alloc, ellipsis);
            }
        }

        // Draw each row with its style; blank cells beyond the candidate's
        // width stay empty (the "rows may be shorter than the band width"
        // rule — Buffer.draw writes only the glyphs).
        var lines = std.mem.splitScalar(u8, self.scratch.items, '\n');
        var row: u16 = 0;
        while (lines.next()) |line| : (row += 1) {
            if (y + row >= buf.height) break;
            const st = if (start + row == self.selected) self.selected_style else self.style;
            _ = try buf.draw(st, line, x, y + row);
        }
        return shown;
    }
};

test {
    std.testing.refAllDecls(@This());
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

test "suggestions: selection highlight uses selected_style on the selected row" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var s: Suggestions = .{
        .candidates = &.{ "a", "b", "c" },
        .selected = 1,
        .style = .{ .fg = .{ .ansi = .green } },
        .scratch = &scratch,
    };
    var buf = try Buffer.init(test_alloc, 5, 3);
    defer buf.deinit();

    _ = try s.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expect(buf.get(0, 0).style.eql(.{ .fg = .{ .ansi = .green } }));
    // Row 1 is the selection: default reverse-video highlight.
    try std.testing.expect(buf.get(0, 1).style.eql(.{ .attrs = .{ .reverse = true } }));
    try std.testing.expect(buf.get(0, 2).style.eql(.{ .fg = .{ .ansi = .green } }));
}

test "suggestions: truncation cuts at a grapheme boundary with the ellipsis" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var s: Suggestions = .{ .candidates = &.{"Hello 😊 world"}, .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 8, 1);
    defer buf.deinit();

    _ = try s.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    // avail 8, ellipsis width 1 -> budget 7: the emoji (width 2) would
    // cross the budget, so it drops whole — "Hello " + "…" at columns
    // 0-6; column 7 stays the default blank cell.
    var rowbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Hello … ", rowStr(&buf, 0, &rowbuf));
}

test "suggestions: over-wide leading grapheme yields just the ellipsis" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var s: Suggestions = .{ .candidates = &.{"🚀rocket"}, .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 2, 1);
    defer buf.deinit();

    _ = try s.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    // avail 2, budget 1: the rocket (width 2) cannot even start -> "…"
    // at column 0; column 1 stays the default blank cell.
    var rowbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("… ", rowStr(&buf, 0, &rowbuf));
}

test "suggestions: scroll window keeps selected visible" {
    const cands = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b" };
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var s: Suggestions = .{
        .candidates = &cands,
        .selected = 9,
        .max_rows = 5,
        .scratch = &scratch,
    };
    var buf = try Buffer.init(test_alloc, 4, 5);
    defer buf.deinit();

    // ensureVisible: sel 9 >= win 5 -> start = 9 - 5 + 1 = 5.
    try std.testing.expectEqual(@as(usize, 5), s.windowStart());
    const shown = try s.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 5), shown);
    var rowbuf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("5   ", rowStr(&buf, 0, &rowbuf));
    try std.testing.expectEqualStrings("9   ", rowStr(&buf, 4, &rowbuf));
    try std.testing.expect(buf.get(0, 4).style.eql(.{ .attrs = .{ .reverse = true } }));
}

test "suggestions: alignment clamp truncates to avail, never past the edge" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var s: Suggestions = .{ .candidates = &.{"abcdefgh"}, .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 10, 1);
    defer buf.deinit();

    _ = try s.draw(test_alloc, &buf, 8, 0, .fromNanoseconds(0));
    // avail = 10 - 8 = 2; budget 1 -> "a" + "…" at columns 8-9, the
    // leading 8 columns stay the default blank cells.
    var rowbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("        a…", rowStr(&buf, 0, &rowbuf));
    try std.testing.expect(buf.get(9, 0).grapheme.len > 0); // ellipsis at the edge
    try std.testing.expect(buf.get(10, 0).eql(.{})); // nothing past the edge
}

test "suggestions: draw at or past the right edge draws nothing" {
    var s: Suggestions = .{ .candidates = &.{"abc"} };
    var buf = try Buffer.init(test_alloc, 4, 1);
    defer buf.deinit();

    try std.testing.expectEqual(@as(u16, 0), try s.draw(test_alloc, &buf, 4, 0, .fromNanoseconds(0)));
    try std.testing.expect(buf.get(0, 0).eql(.{}));
}

test "suggestions: return value is min(candidates, max_rows), 0 when empty" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var buf = try Buffer.init(test_alloc, 10, 6);
    defer buf.deinit();

    var s: Suggestions = .{ .candidates = &.{ "a", "b", "c" }, .scratch = &scratch };
    try std.testing.expectEqual(@as(u16, 3), try s.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0)));

    var capped: Suggestions = .{ .candidates = &.{ "a", "b", "c", "d" }, .max_rows = 2, .scratch = &scratch };
    try std.testing.expectEqual(@as(u16, 2), try capped.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0)));

    var empty: Suggestions = .{};
    try std.testing.expectEqual(@as(u16, 0), try empty.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0)));
}

test "suggestions: no allocation through the caller when every row fits" {
    var failing = std.testing.FailingAllocator.init(test_alloc, .{ .fail_index = 0 });
    const alloc = failing.allocator();
    var scratch: std.ArrayList(u8) = .empty;
    // Pre-size the scratch so the fit-path materialization never
    // allocates; the draw must then touch `alloc` zero times.
    try scratch.ensureTotalCapacity(test_alloc, 32);
    defer scratch.deinit(test_alloc);
    var s: Suggestions = .{ .candidates = &.{ "a", "bb" }, .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 10, 2);
    defer buf.deinit();

    _ = try s.draw(alloc, &buf, 0, 0, .fromNanoseconds(0)); // must not fail
}

test "suggestions: truncation allocates only through the caller allocator" {
    var failing = std.testing.FailingAllocator.init(test_alloc, .{ .fail_index = 0 });
    const alloc = failing.allocator();
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var s: Suggestions = .{ .candidates = &.{"a much longer candidate"}, .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 5, 1);
    defer buf.deinit();

    try std.testing.expectError(error.OutOfMemory, s.draw(alloc, &buf, 0, 0, .fromNanoseconds(0)));
}
