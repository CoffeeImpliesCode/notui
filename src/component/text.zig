//! Text: a styled, width-aware single- or multi-line text component.
//!
//! Single-line mode truncates `text` at a grapheme boundary, appending
//! the `ellipsis` marker when the text does not fit, and aligns what is
//! drawn left, center or right in the columns left from `x`. Wrap mode
//! wraps to `wrap_width` cells and draws one row per line, starting
//! every line at `x`; an over-wide last line gets the single-line
//! truncation, cut to the wrap budget and marked with `ellipsis`.
//!
//! A drawn cell borrows the bytes of the grapheme it shows, so every
//! truncated or wrapped string outlives `draw`: those bytes live in
//! `scratch`, a caller-owned `std.ArrayList(u8)`. `scratch` is REQUIRED
//! and must not be shared between components — two components drawn
//! into one frame would otherwise overwrite each other's rows — and the
//! caller keeps it alive and unmodified until the buffer that borrows
//! it has been rendered.
//!
//! `draw` allocates only through its `alloc` argument: the buffer the
//! wrap produces, and any growth of `scratch`. That is the allocator
//! which owns (or will own) the scratch's memory, and it must stay the
//! same for the component's lifetime; capacity is retained between
//! frames. `text` must not point into `scratch`.

const std = @import("std");
const Buffer = @import("../buffer.zig").Buffer;
const Style = @import("../style.zig").Style;
const Width = @import("../width.zig");
const Clock = @import("component.zig").Clock;
const fitPrefixLen = Width.fitPrefixLen;

/// Styled borrowed text with caller-provided frame storage; a literal is ready once
/// `scratch` is supplied. Copies share that scratch: serialize draws and do not use
/// a copy for another component whose cells coexist. The module defines borrow duties.
pub const Text = struct {
    /// Text to draw, BORROWED and never freed here. A string that fits
    /// the available width is drawn straight from this slice, with no
    /// copy into `scratch`.
    text: []const u8 = "",
    /// Style for every cell this component draws.
    style: Style = .{},
    /// Marker appended when the text does not fit, clipped at a grapheme boundary
    /// to the column budget. Null draws no marker and spends the budget on text.
    ellipsis: ?[]const u8 = "…",
    /// True: wrap to `wrap_width` and draw one row per line. False: one
    /// row, truncated to the columns available from `x`.
    wrap: bool = false,
    /// Wrap budget in cells; 0 means the columns available from `x`.
    wrap_width: u16 = 0,
    /// Horizontal alignment within the available width. Single-line
    /// mode only — wrap mode starts every line at `x`. `align` is a Zig
    /// keyword, so the field is spelled `@"align"`.
    @"align": enum { left, center, right } = .left,
    /// Caller-owned storage for the truncated or wrapped bytes the drawn
    /// cells borrow. Required, and never shared between components.
    scratch: *std.ArrayList(u8),

    /// Text never animates; `advance` is always false.
    pub fn advance(self: *Text, now: Clock) bool {
        _ = self;
        _ = now;
        return false;
    }

    /// Draw `text` with its top-left at (x, y) and return the columns
    /// consumed: the drawn width in single-line mode, the widest row in
    /// wrap mode. Never more than `buf.width - x`.
    ///
    /// `alloc` backs the wrap buffer and any growth of `scratch`; it is
    /// the allocator that owns the scratch's memory and must not change
    /// between calls. The only error is `error.OutOfMemory`, from the
    /// wrap or from growing the scratch. Failure writes no cells, but scratch
    /// contents and capacity may change, invalidating earlier scratch borrows.
    /// Finish rendering those borrows before drawing again with this scratch.
    pub fn draw(self: *Text, alloc: std.mem.Allocator, buf: *Buffer, x: u16, y: u16, now: Clock) !u16 {
        _ = now; // static component; nothing to advance
        const avail: usize = buf.width -| x;
        if (self.text.len == 0 or avail == 0 or y >= buf.height) return 0;

        if (!self.wrap) {
            const s = try self.fit(alloc, avail);
            if (self.@"align" == .left) return buf.draw(self.style, s, x, y);
            // Align within the available width; `w <= avail` by
            // construction (fit already truncated), so no underflow.
            // The consumed columns stay `w` either way.
            const w = Width.strWidth(s);
            const x0: u16 = @intCast(x + switch (self.@"align") {
                .left => 0,
                .center => (avail - w) / 2,
                .right => avail - w,
            });
            return buf.draw(self.style, s, x0, y);
        }

        const ww: usize = if (self.wrap_width == 0) avail else self.wrap_width;
        const wrapped = try Width.wrap(alloc, self.text, ww, 1);
        defer alloc.free(wrapped);

        // Cells borrow their graphemes, so the rows must outlive this
        // call: they are copied into the caller-owned scratch. An
        // over-wide last line is ellipsized on the way in, measured and
        // copied from `wrapped` — this call's own allocation — so the
        // copy never reads bytes that growing the scratch could move.
        var last_start: usize = 0;
        {
            var find = std.mem.splitScalar(u8, wrapped, '\n');
            while (find.next()) |line| last_start = wrapped.len - line.len;
        }
        const last = wrapped[last_start..];
        // The over-wide last row is cut to the budget the wrap was
        // given, which the buffer can always show and an explicit
        // `wrap_width` can make narrower than the free columns.
        const budget: usize = @min(ww, avail);
        const marker = self.ellipsis orelse "";
        const e = marker[0..fitPrefixLen(marker, budget)];
        const kept = if (Width.strWidth(last) > budget)
            fitPrefixLen(last, budget -| Width.strWidth(e))
        else
            last.len;

        self.scratch.clearRetainingCapacity();
        try self.scratch.appendSlice(alloc, wrapped[0..last_start]);
        try self.scratch.appendSlice(alloc, last[0..kept]);
        if (kept != last.len) try self.scratch.appendSlice(alloc, e);

        var widest: u16 = 0;
        var row: u16 = 0;
        var lines = std.mem.splitScalar(u8, self.scratch.items, '\n');
        while (lines.next()) |line| {
            if (y + row >= buf.height) break;
            widest = @max(widest, try buf.draw(self.style, line, x, y + row));
            row += 1;
        }
        return widest;
    }

    /// What single-line mode draws for `self.text` in `avail` columns:
    /// `self.text` borrowed as-is when it fits, else its truncation in
    /// `scratch` (which the next `draw` overwrites).
    fn fit(self: *Text, alloc: std.mem.Allocator, avail: usize) ![]const u8 {
        if (Width.strWidth(self.text) <= avail) return self.text;
        self.scratch.clearRetainingCapacity();
        return self.appendFit(alloc, self.text, avail);
    }

    /// Append the truncation of `s` to the end of `scratch` — the
    /// grapheme-boundary prefix that fits `avail` columns minus the
    /// marker, then the marker — and return the appended slice. `s` must
    /// not borrow `scratch`: growth may move the list under it.
    fn appendFit(self: *Text, alloc: std.mem.Allocator, s: []const u8, avail: usize) ![]const u8 {
        const marker = self.ellipsis orelse "";
        const e = marker[0..fitPrefixLen(marker, avail)];
        const kept = fitPrefixLen(s, avail -| Width.strWidth(e));
        const start = self.scratch.items.len;
        try self.scratch.ensureUnusedCapacity(alloc, kept + e.len);
        self.scratch.appendSliceAssumeCapacity(s[0..kept]);
        self.scratch.appendSliceAssumeCapacity(e);
        return self.scratch.items[start..];
    }
};

test {
    std.testing.refAllDecls(@This());
}

/// Fixed-buffer writer for golden tests (same pattern as src/buffer.zig).
const TestWriter = struct {
    buf: [1024]u8 = undefined,
    w: std.Io.Writer = undefined,

    fn init(self: *TestWriter) void {
        self.w = .fixed(&self.buf);
    }
};

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

/// Whether each non-default text cell borrows from `owner`. Blank grid padding
/// has static storage and is not a component borrow. A row pointing into another
/// component's scratch would be rewritten by its next draw.
fn rowBorrowsFrom(buf: *const Buffer, y: usize, owner: []const u8) bool {
    const lo = @intFromPtr(owner.ptr);
    const hi = lo + owner.len;
    var x: usize = 0;
    while (x < buf.width) : (x += 1) {
        const cell = buf.get(@intCast(x), @intCast(y));
        if (cell.wide or cell.grapheme.len == 0 or cell.eql(.{})) continue;
        const at = @intFromPtr(cell.grapheme.ptr);
        if (at < lo or at + cell.grapheme.len > hi) return false;
    }
    return true;
}

test "text: fitting text is borrowed, scratch untouched" {
    var scratch: std.ArrayList(u8) = .empty;
    var t: Text = .{ .text = "Hello", .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 10, 1);
    defer buf.deinit();

    const consumed = try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 5), consumed);
    try std.testing.expectEqual(@as(usize, 0), scratch.items.len); // no allocation
    try std.testing.expectEqualStrings("H", buf.get(0, 0).grapheme);
    try std.testing.expectEqualStrings("o", buf.get(4, 0).grapheme);
}

test "text: truncates at a grapheme boundary with ellipsis" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var t: Text = .{ .text = "Hello 😊", .scratch = &scratch }; // width 8
    var buf = try Buffer.init(test_alloc, 5, 1);
    defer buf.deinit();

    const consumed = try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 5), consumed);
    // budget = 5 - 1 (ellipsis) = 4 -> "Hell" + "…"
    var rowbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Hell…", rowStr(&buf, 0, &rowbuf));
    try std.testing.expectEqualStrings("Hell…", scratch.items);
}

test "text: wide grapheme is never split mid-bytes" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var t: Text = .{ .text = "👨‍🌾xx", .scratch = &scratch }; // width 4
    var buf = try Buffer.init(test_alloc, 3, 1);
    defer buf.deinit();

    const consumed = try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 3), consumed);
    // budget = 3 - 1 = 2 -> the full family, never half its bytes.
    var rowbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("👨‍🌾…", rowStr(&buf, 0, &rowbuf));
}

test "text: ellipsis null appends no marker" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var t: Text = .{ .text = "abcdef", .ellipsis = null, .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 4, 1);
    defer buf.deinit();

    const consumed = try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 4), consumed);
    var rowbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("abcd", rowStr(&buf, 0, &rowbuf));
}

test "text: wrap draws each line at an increasing row" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var t: Text = .{ .text = "The quick brown fox", .wrap = true, .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 10, 3);
    defer buf.deinit();

    const consumed = try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 10), consumed); // widest row
    var rowbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("The quick ", rowStr(&buf, 0, &rowbuf));
    try std.testing.expectEqualStrings("brown fox ", rowStr(&buf, 1, &rowbuf));
    try std.testing.expect(buf.get(0, 2).eql(.{})); // nothing on row 2
}

test "text: the over-wide last wrapped line is ellipsized on its own row" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var t: Text = .{ .text = "abc supercalifragilistic", .wrap = true, .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 10, 3);
    defer buf.deinit();

    const consumed = try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 10), consumed); // the marked row
    var rowbuf: [64]u8 = undefined;
    // The 20-cell word does not fit beside "abc", so it keeps a row of
    // its own: the last one, and one this buffer can still show. That
    // row — not the row above it — gets the single-line truncation.
    try std.testing.expect(std.mem.startsWith(u8, rowStr(&buf, 0, &rowbuf), "abc"));
    try std.testing.expect(std.mem.endsWith(u8, rowStr(&buf, 1, &rowbuf), "…"));
    try std.testing.expectEqual(@as(usize, 10), Width.strWidth(rowStr(&buf, 1, &rowbuf)));
    try std.testing.expect(buf.get(0, 2).eql(.{})); // nothing on row 2
    // Both rows borrow the one scratch the caller owns, never the wrap
    // buffer this call allocated and freed.
    try std.testing.expect(rowBorrowsFrom(&buf, 0, scratch.items));
    try std.testing.expect(rowBorrowsFrom(&buf, 1, scratch.items));
}

test "text: wrapping cuts the over-wide last line at a grapheme boundary" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    // The last word is 6 cells of ZWJ clusters, wider than the 5-cell
    // budget, so it keeps a row of its own and is marked down to 5.
    var t: Text = .{ .text = "aa 👨‍🌾👨‍🌾👨‍🌾", .wrap = true, .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 5, 3);
    defer buf.deinit();

    try std.testing.expectEqual(
        @as(u16, 5),
        try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0)),
    );
    // Every printed cell of that row is a whole cluster or the marker:
    // a partial ZWJ sequence never reaches the grid.
    var printed: usize = 0;
    var x: usize = 0;
    while (x < buf.width) : (x += 1) {
        const cell = buf.get(@intCast(x), 1);
        if (cell.wide or cell.grapheme.len == 0) continue;
        try std.testing.expect(
            std.mem.eql(u8, cell.grapheme, "👨‍🌾") or std.mem.eql(u8, cell.grapheme, "…"),
        );
        printed += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), printed); // two clusters, then the marker
    try std.testing.expect(rowBorrowsFrom(&buf, 1, scratch.items));
}

test "text: an explicit wrap_width caps the ellipsized last row" {
    var narrow_scratch: std.ArrayList(u8) = .empty;
    defer narrow_scratch.deinit(test_alloc);
    var buf = try Buffer.init(test_alloc, 10, 3);
    defer buf.deinit();

    // A 4-cell wrap budget with 10 free columns: the marked row is cut to
    // the budget, not to the buffer's edge.
    var narrow: Text = .{
        .text = "aa supercalifragilistic",
        .wrap = true,
        .wrap_width = 4,
        .scratch = &narrow_scratch,
    };
    try std.testing.expectEqual(
        @as(u16, 4),
        try narrow.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0)),
    );
    try std.testing.expectEqualStrings("s", buf.get(0, 1).grapheme);
    try std.testing.expectEqualStrings("…", buf.get(3, 1).grapheme);
    try std.testing.expect(buf.get(4, 1).eql(.{})); // no text beyond the explicit budget
}

test "text: oversized ellipsis respects alignment and explicit wrap budgets" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var buf = try Buffer.init(test_alloc, 10, 3);
    defer buf.deinit();
    const now: Clock = .fromNanoseconds(0);

    inline for (.{ .center, .right }) |alignment| {
        var single: Text = .{
            .text = "overlong text",
            .ellipsis = "long",
            .@"align" = alignment,
            .scratch = &scratch,
        };
        try std.testing.expectEqual(@as(u16, 2), try single.draw(test_alloc, &buf, 8, 0, now));
        try std.testing.expectEqualStrings("l", buf.get(8, 0).grapheme);
        try std.testing.expectEqualStrings("o", buf.get(9, 0).grapheme);
    }

    buf.clear();
    var wrapped: Text = .{
        .text = "a overlong",
        .ellipsis = "long",
        .wrap = true,
        .wrap_width = 2,
        .scratch = &scratch,
    };
    try std.testing.expectEqual(@as(u16, 2), try wrapped.draw(test_alloc, &buf, 0, 0, now));
    try std.testing.expectEqualStrings("l", buf.get(0, 1).grapheme);
    try std.testing.expectEqualStrings("o", buf.get(1, 1).grapheme);
    try std.testing.expect(buf.get(2, 1).eql(.{}));
}

test "text: styled cells carry the component style" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var t: Text = .{ .text = "Hi", .style = .{ .fg = .{ .ansi = .red } }, .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 4, 1);
    defer buf.deinit();
    _ = try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expect(buf.get(0, 0).style.fg.?.eql(.{ .ansi = .red }));

    var tw: TestWriter = .{};
    tw.init();
    try buf.renderAll(&tw.w);
    try std.testing.expectEqualStrings("\r\x1b[K\x1b[31mHi\x1b[0m", tw.w.buffered());
}

test "text: no allocation when the text fits" {
    var failing = std.testing.FailingAllocator.init(test_alloc, .{ .fail_index = 0 });
    const alloc = failing.allocator();
    var scratch: std.ArrayList(u8) = .empty;
    var t: Text = .{ .text = "short", .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 10, 1);
    defer buf.deinit();

    _ = try t.draw(alloc, &buf, 0, 0, .fromNanoseconds(0)); // must not fail
    try std.testing.expectEqual(@as(usize, 0), scratch.items.len);
}

test "text: truncation allocates through the caller allocator" {
    var failing = std.testing.FailingAllocator.init(test_alloc, .{ .fail_index = 0 });
    const alloc = failing.allocator();
    var scratch: std.ArrayList(u8) = .empty;
    var t: Text = .{ .text = "a much longer string", .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 5, 1);
    defer buf.deinit();

    try std.testing.expectError(error.OutOfMemory, t.draw(alloc, &buf, 0, 0, .fromNanoseconds(0)));
}

test "text: empty text draws nothing" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var t: Text = .{ .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 6, 1);
    defer buf.deinit();
    try std.testing.expectEqual(@as(u16, 0), try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0)));
    try std.testing.expect(buf.get(0, 0).eql(.{}));
}

test "text: right alignment places the last glyph at x + avail - 1" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var t: Text = .{ .text = "Hi", .@"align" = .right, .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 10, 1);
    defer buf.deinit();
    const consumed = try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 2), consumed);
    try std.testing.expectEqualStrings("H", buf.get(8, 0).grapheme);
    try std.testing.expectEqualStrings("i", buf.get(9, 0).grapheme);
    try std.testing.expect(buf.get(0, 0).eql(.{})); // leading gap empty
}

test "text: center alignment centers within the available width" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var t: Text = .{ .text = "Hi", .@"align" = .center, .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 10, 1);
    defer buf.deinit();
    _ = try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqualStrings("H", buf.get(4, 0).grapheme); // (10-2)/2
    try std.testing.expectEqualStrings("i", buf.get(5, 0).grapheme);
}

test "text: left alignment is unchanged" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var t: Text = .{ .text = "Hi", .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 10, 1);
    defer buf.deinit();
    _ = try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqualStrings("H", buf.get(0, 0).grapheme);
}

test "text: truncated text aligns at x" {
    // The fitted string fills `avail`, so every alignment computes
    // x0 = x (no room to shift into).
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var t: Text = .{ .text = "a very long line", .@"align" = .right, .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 8, 1);
    defer buf.deinit();
    _ = try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqualStrings("a", buf.get(0, 0).grapheme);

    var t2: Text = .{ .text = "a very long line", .@"align" = .center, .scratch = &scratch };
    var buf2 = try Buffer.init(test_alloc, 8, 1);
    defer buf2.deinit();
    _ = try t2.draw(test_alloc, &buf2, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqualStrings("a", buf2.get(0, 0).grapheme);
}

test "text: wrap mode ignores alignment" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var t: Text = .{ .text = "The quick brown fox", .wrap = true, .@"align" = .right, .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 10, 3);
    defer buf.deinit();
    _ = try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    var rowbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("The quick ", rowStr(&buf, 0, &rowbuf)); // starts at x
}

test "text: two components drawn into one frame keep their own rows" {
    // Each row's cells borrow their own component's scratch, so the
    // second draw cannot rewrite the first row. This is why `scratch` is
    // a caller-supplied pointer with no shared default.
    var a_scratch: std.ArrayList(u8) = .empty;
    defer a_scratch.deinit(test_alloc);
    var b_scratch: std.ArrayList(u8) = .empty;
    defer b_scratch.deinit(test_alloc);

    var a: Text = .{ .text = "AAAAA", .scratch = &a_scratch };
    var b: Text = .{ .text = "BBBBB", .scratch = &b_scratch };
    var buf = try Buffer.init(test_alloc, 3, 2);
    defer buf.deinit();

    _ = try a.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    _ = try b.draw(test_alloc, &buf, 0, 1, .fromNanoseconds(0));

    var rowbuf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("AA…", rowStr(&buf, 0, &rowbuf));
    try std.testing.expectEqualStrings("BB…", rowStr(&buf, 1, &rowbuf));
    // The rows sit in different storage: neither borrow reaches into the
    // other component's memory, so neither draw can rewrite the other.
    try std.testing.expect(rowBorrowsFrom(&buf, 0, a_scratch.items));
    try std.testing.expect(rowBorrowsFrom(&buf, 1, b_scratch.items));
    try std.testing.expect(!rowBorrowsFrom(&buf, 0, b_scratch.items));
    try std.testing.expect(!rowBorrowsFrom(&buf, 1, a_scratch.items));
}

test "text: wrapped rows survive a second component's draw" {
    // The wrap path copies into the scratch too, so the same per-
    // component rule applies to a multi-row draw. The claims are which
    // memory each row borrows and where each word lands — not how many
    // trailing columns of a row the grid leaves blank.
    var a_scratch: std.ArrayList(u8) = .empty;
    defer a_scratch.deinit(test_alloc);
    var b_scratch: std.ArrayList(u8) = .empty;
    defer b_scratch.deinit(test_alloc);

    var a: Text = .{ .text = "alpha beta", .wrap = true, .scratch = &a_scratch };
    var b: Text = .{ .text = "gamma delta", .wrap = true, .scratch = &b_scratch };
    var buf = try Buffer.init(test_alloc, 6, 4);
    defer buf.deinit();

    _ = try a.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    _ = try b.draw(test_alloc, &buf, 0, 2, .fromNanoseconds(0));

    var rowbuf: [32]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, rowStr(&buf, 0, &rowbuf), "alpha"));
    try std.testing.expect(std.mem.indexOf(u8, rowStr(&buf, 1, &rowbuf), "beta") != null);
    try std.testing.expect(std.mem.startsWith(u8, rowStr(&buf, 2, &rowbuf), "gamma"));
    try std.testing.expect(std.mem.indexOf(u8, rowStr(&buf, 3, &rowbuf), "delta") != null);
    // Rows 0-1 borrow the first component's scratch and rows 2-3 the
    // second's; no row reaches into the other component's memory.
    for (0..2) |row| {
        try std.testing.expect(rowBorrowsFrom(&buf, row, a_scratch.items));
        try std.testing.expect(rowBorrowsFrom(&buf, row + 2, b_scratch.items));
        try std.testing.expect(!rowBorrowsFrom(&buf, row, b_scratch.items));
        try std.testing.expect(!rowBorrowsFrom(&buf, row + 2, a_scratch.items));
    }

    // What the terminal receives proves the same thing end to end: each
    // word reaches it once, in row order, with no row rewritten.
    var tw: TestWriter = .{};
    tw.init();
    try buf.renderAll(&tw.w);
    const out = tw.w.buffered();
    var after: usize = 0;
    for ([_][]const u8{ "alpha", "beta", "gamma", "delta" }) |word| {
        const at = std.mem.indexOf(u8, out, word).?;
        try std.testing.expect(at >= after);
        try std.testing.expectEqual(at, std.mem.lastIndexOf(u8, out, word).?);
        after = at + word.len;
    }
}

test "text: u16 origins stay inside the buffer" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    const now: Clock = .fromNanoseconds(0);
    const far: u16 = std.math.maxInt(u16); // the largest origin a caller can pass
    var buf = try Buffer.init(test_alloc, 4, 2);
    defer buf.deinit();

    var t: Text = .{ .text = "abcdefgh", .scratch = &scratch };
    // x at the right edge leaves no columns and y past the bottom edge no
    // row; the largest u16 origin cannot wrap the arithmetic around.
    try std.testing.expectEqual(@as(u16, 0), try t.draw(test_alloc, &buf, 4, 0, now));
    try std.testing.expectEqual(@as(u16, 0), try t.draw(test_alloc, &buf, far, 0, now));
    try std.testing.expectEqual(@as(u16, 0), try t.draw(test_alloc, &buf, 0, 2, now));
    try std.testing.expectEqual(@as(u16, 0), try t.draw(test_alloc, &buf, 0, far, now));

    // Right alignment at the last column, then a bare combining mark
    // whose zero width lands the origin one past the edge: both stay
    // inside the grid, and the mark leaves the drawn row unchanged.
    var right: Text = .{ .text = "ab", .@"align" = .right, .scratch = &scratch };
    try std.testing.expectEqual(@as(u16, 2), try right.draw(test_alloc, &buf, 2, 0, now));
    try std.testing.expectEqualStrings("b", buf.get(3, 0).grapheme);

    var mark: Text = .{ .text = "\u{301}", .@"align" = .right, .scratch = &scratch };
    try std.testing.expectEqual(@as(u16, 0), try mark.draw(test_alloc, &buf, 0, 0, now));
    try std.testing.expect(buf.get(0, 0).eql(.{}));
    try std.testing.expectEqualStrings("b", buf.get(3, 0).grapheme); // untouched

    // Wrap mode stops at the bottom edge instead of walking past it.
    var wrapped: Text = .{ .text = "alpha beta gamma", .wrap = true, .scratch = &scratch };
    try std.testing.expectEqual(@as(u16, 0), try wrapped.draw(test_alloc, &buf, 0, far, now));
    try std.testing.expectEqual(@as(u16, 4), try wrapped.draw(test_alloc, &buf, 0, 1, now));
    try std.testing.expect(buf.get(0, 0).eql(.{}));
    try std.testing.expectEqualStrings("a", buf.get(0, 1).grapheme);
}

test "text: the draw allocator is only used to grow the scratch" {
    // A scratch with room reserved draws a truncation with an allocator
    // that cannot allocate at all: `alloc` exists for scratch growth,
    // not for the bytes themselves.
    var scratch: std.ArrayList(u8) = .empty;
    try scratch.ensureTotalCapacity(test_alloc, 64);
    defer scratch.deinit(test_alloc);
    var failing = std.testing.FailingAllocator.init(test_alloc, .{
        .fail_index = 0,
        .resize_fail_index = 0,
    });
    var t: Text = .{ .text = "a much longer string", .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 5, 1);
    defer buf.deinit();

    try std.testing.expectEqual(
        @as(u16, 5),
        try t.draw(failing.allocator(), &buf, 0, 0, .fromNanoseconds(0)),
    );
    var rowbuf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("a mu…", rowStr(&buf, 0, &rowbuf));
}
