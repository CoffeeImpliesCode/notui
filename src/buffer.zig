//! Buffer: a flat cell grid with wide-glyph handling, grapheme-aware
//! drawing, and the double-buffer diff renderers (renderDiff/renderAll).
//!
//! Adapted from zigzag `terminal/screen.zig` (grid :70-85, resize
//! :88-117, setCell wide handling :115-154, writeString :157-188, diff
//! render :190-306). The structural adaptation from the copy source:
//! `Cell.grapheme` is a borrowed `[]const u8` slice (architecture §3 —
//! points into the app's text arena, never copied), not zigzag's `char:
//! u21`; width comes exclusively from `width.zig` (the zg seam, plan §0
//! grep-gate), never from zg directly. Style tracking follows the
//! libvaxis DAM pattern: SGR is written only when the emitted style
//! changes, and wide continuations never emit text.

const std = @import("std");
const Cell = @import("cell.zig").Cell;
const Style = @import("style.zig").Style;
const emit = @import("emit.zig");
const Width = @import("width.zig");

/// A cell grid plus the delta renderer for double-buffered output.
///
/// Cells are stored flat, row-major: `cells[y * self.width + x]`.
pub const Buffer = struct {
    allocator: std.mem.Allocator,
    cells: []Cell,
    width: u16,
    height: u16,

    /// Allocate a `width` x `height` grid of empty cells.
    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Buffer {
        const cells = try allocator.alloc(Cell, @as(usize, width) * @as(usize, height));
        @memset(cells, Cell{});
        return .{
            .allocator = allocator,
            .cells = cells,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.cells);
    }

    /// Reallocate to `new_width` x `new_height`, copying the overlapping
    /// region row by row (zigzag screen.zig :88-117); the new area is
    /// empty cells.
    pub fn resize(self: *Buffer, new_width: u16, new_height: u16) !void {
        const new_size = @as(usize, new_width) * @as(usize, new_height);
        const new_cells = try self.allocator.alloc(Cell, new_size);
        @memset(new_cells, Cell{});

        const copy_height: usize = @min(self.height, new_height);
        const copy_width: usize = @min(self.width, new_width);
        for (0..copy_height) |y| {
            @memcpy(
                new_cells[y * new_width ..][0..copy_width],
                self.cells[y * self.width ..][0..copy_width],
            );
        }

        self.allocator.free(self.cells);
        self.cells = new_cells;
        self.width = new_width;
        self.height = new_height;
    }

    /// Reset every cell to the default empty cell.
    pub fn clear(self: *Buffer) void {
        @memset(self.cells, Cell{});
    }

    /// Bounds-checked read; returns the empty cell out of bounds.
    pub fn get(self: *const Buffer, x: u16, y: u16) Cell {
        if (x >= self.width or y >= self.height) return Cell{};
        return self.cells[@as(usize, y) * @as(usize, self.width) + x];
    }

    /// Set one cell with wide-glyph handling (zigzag setCell :115-154):
    /// - overwriting a wide continuation nulls its left half;
    /// - overwriting a wide lead nulls its continuation;
    /// - a width-2 grapheme writes a `wide` continuation cell carrying
    ///   the same style (empty grapheme, `wide = true`).
    ///
    /// Out of bounds is a no-op; never errors (plan §0: graceful
    /// truncation, no throw paths).
    pub fn set(self: *Buffer, x: u16, y: u16, cell: Cell) !void {
        if (x >= self.width or y >= self.height) return;
        const idx = @as(usize, y) * @as(usize, self.width) + x;

        // Overwriting a wide continuation cell: its lead is at x - 1.
        if (self.cells[idx].wide and x > 0) {
            self.cells[idx - 1] = Cell{};
        }
        // Overwriting the left half of a wide char: null the continuation.
        // A wide continuation is always placed at lead + 1, so a `wide`
        // cell at idx + 1 can only belong to idx.
        if (!self.cells[idx].wide and x + 1 < self.width and self.cells[idx + 1].wide) {
            self.cells[idx + 1] = Cell{};
        }

        self.cells[idx] = cell;

        // A wide grapheme occupies the next column too. The continuation
        // never emits text (renderers skip it) and carries the style so a
        // styled wide glyph paints both columns.
        if (!cell.wide and x + 1 < self.width and Width.graphemeWidth(cell.grapheme) >= 2) {
            self.cells[idx + 1] = .{
                .grapheme = "",
                .style = cell.style,
                .wide = true,
            };
        }
    }

    /// Draw `text` with `style` at (x, y), grapheme-aware.
    ///
    /// Iterates grapheme clusters through the width seam
    /// (`Width.firstGraphemeLen` + `Width.graphemeWidth`; no zg import).
    /// Zero-width clusters (combining marks) advance no column; a wide
    /// glyph that would cross the right edge drops, and with it the rest
    /// of the line (graceful truncation — never an error). Returns the
    /// number of columns consumed.
    pub fn draw(self: *Buffer, style: Style, text: []const u8, x: u16, y: u16) !u16 {
        if (y >= self.height or text.len == 0) return 0;

        var col: u16 = x;
        var off: usize = 0;
        while (off < text.len) {
            const glen = Width.firstGraphemeLen(text[off..]);
            if (glen == 0) break; // defensive: no progress possible
            const gc = text[off..][0..glen];
            off += glen;

            const cw = Width.graphemeWidth(gc);
            if (cw <= 0) continue; // zero-width: advance no column

            const cwu: u16 = if (cw >= 2) 2 else 1;
            if (@as(u32, col) + cwu > self.width) break; // over-wide: drop the rest
            try self.set(col, y, .{ .grapheme = gc, .style = style });
            col += cwu;
        }
        return col - x;
    }

    /// Emit the difference between `self` (current frame) and `prev`
    /// (previous frame) to `w` (a std.Io.Writer-compatible writer).
    ///
    /// Cursor contract: on entry the cursor is at the band anchor —
    /// column 0 of row 0. The caller re-establishes it between frames
    /// (Region's tracked anchor); this function never emits absolute CUP
    /// and never moves above the band. After the call the cursor sits at
    /// the end of the last emitted row.
    ///
    /// An idle frame (`self` == `prev`) emits NOTHING (architecture §3).
    /// Changed rows in [first..last] are each written as `\r` (+ `\n`
    /// relative moves) then a column-1 `eraseLine` (`\r\x1b[K` — the
    /// tmux scroll-on-clear mitigation, §9.7), which blanks the row and
    /// kills any stale tail. Within a row, wide continuations and blank
    /// cells emit nothing (blank-cell skips advance with CUF); SGR is
    /// written only when the style changes (libvaxis DAM pattern). The
    /// frame ends with an SGR reset when the last emitted style was
    /// non-default, so the terminal's active style is always default at
    /// a frame boundary — the next frame's delta tracking starts clean.
    pub fn renderDiff(self: *const Buffer, prev: *const Buffer, w: anytype) !void {
        const changed = self.firstLastChanged(prev) orelse return; // idle: nothing

        var cur_row: usize = 0;
        var tracked = Style{};
        var y = changed.first;
        while (y <= changed.last) : (y += 1) {
            if (self.rowEqual(prev, y)) continue; // unchanged row: leave as-is

            // Move down to this row (relative moves only), then erase at
            // column 1: `\r` + n x `\n` lands on column 1 of row y.
            try w.writeAll("\r");
            var down = y - cur_row;
            while (down > 0) : (down -= 1) try w.writeByte('\n');
            cur_row = y;
            try emit.eraseLine(w);

            try self.writeRow(w, y, &tracked);
        }

        // Frame-boundary hygiene: leave the terminal SGR state default.
        if (!tracked.eql(Style{})) try w.writeAll(emit.reset);
    }

    /// Emit the full buffer band to `w` (band-scoped, no absolute CUP).
    /// Used for the width-change full redraw (region strategy 2) after
    /// `ESC[J`; the cursor sits at the anchor (column 0 of row 0). Each
    /// row: `\r`(+`\n`) + column-1 eraseLine, then the row's cells with
    /// the same style-tracking rules as `renderDiff`.
    pub fn renderAll(self: *const Buffer, w: anytype) !void {
        var tracked = Style{};
        for (0..self.height) |y| {
            if (y == 0) {
                try w.writeAll("\r");
            } else {
                try w.writeAll("\r\n");
            }
            try emit.eraseLine(w);
            try self.writeRow(w, y, &tracked);
        }
        if (!tracked.eql(Style{})) try w.writeAll(emit.reset);
    }

    /// Rows that differ from `prev`, or null when the buffers are equal
    /// (idle frame).
    const ChangedRange = struct { first: usize, last: usize };

    fn firstLastChanged(self: *const Buffer, prev: *const Buffer) ?ChangedRange {
        var first: ?usize = null;
        var last: usize = 0;
        for (0..self.height) |y| {
            if (self.rowEqual(prev, y)) continue;
            if (first == null) first = y;
            last = y;
        }
        const f = first orelse return null;
        return .{ .first = f, .last = last };
    }

    /// Whether row `y` is cell-for-cell equal to `prev`'s row `y`.
    fn rowEqual(self: *const Buffer, prev: *const Buffer, y: usize) bool {
        if (y >= prev.height or self.width > prev.width) return false;
        for (0..self.width) |x| {
            if (!self.cells[y * self.width + x].eql(prev.cells[y * prev.width + x])) return false;
        }
        return true;
    }

    /// Emit one row (just erased at column 1) to `w`. Wide continuations
    /// and blank cells never emit text; blank-cell skips advance the
    /// cursor with CUF. SGR is written only when the style changes from
    /// the last emitted style (`tracked`); a style change first resets,
    /// because `emit.writeStyle` emits only non-default fields and a
    /// field that turns off (e.g. bold) would otherwise leak.
    fn writeRow(self: *const Buffer, w: anytype, y: usize, tracked: *Style) !void {
        var x: usize = 0;
        var phys_col: usize = 0; // terminal cursor column, 0-indexed
        while (x < self.width) {
            const cell = self.cells[y * self.width + x];

            // Wide continuations never emit text; their column was
            // covered by the lead's write (which advances 2).
            if (cell.wide or cell.grapheme.len == 0) {
                x += 1;
                continue;
            }
            // Blank cells are already blank after the erase; skip them.
            if (cell.eql(Cell{})) {
                x += 1;
                continue;
            }

            const wg = Width.graphemeWidth(cell.grapheme);
            const wcell: usize = if (wg >= 2) 2 else 1;
            // A wide glyph at the last column has no continuation cell;
            // drop it (graceful — over-wide never errors).
            if (x + wcell > self.width) {
                x += 1;
                continue;
            }

            if (x > phys_col) {
                try w.print("\x1b[{d}C", .{x - phys_col});
            }
            try writeCellStyle(w, tracked, cell.style);
            try w.writeAll(cell.grapheme);
            phys_col = x + wcell;
            x += wcell;
        }
    }
};

/// Emit SGR for `style` only when it differs from the last emitted
/// style (`tracked`), updating `tracked` on change. Turning fields off
/// requires a full reset first (`emit.writeStyle` emits only non-default
/// fields, so without the reset a dropped field would leak into the new
/// style); a fully-default target style emits just the reset.
fn writeCellStyle(w: anytype, tracked: *Style, style: Style) !void {
    if (tracked.eql(style)) return;
    if (!tracked.eql(Style{})) try w.writeAll(emit.reset);
    if (!style.eql(Style{})) try emit.writeStyle(w, style);
    tracked.* = style;
}

test {
    std.testing.refAllDecls(@This());
}

/// Fixed-buffer writer for golden tests. `init` must run in place —
/// the writer borrows `buf`, so the struct must not move afterwards
/// (same pattern as emit.zig).
const TestWriter = struct {
    buf: [1024]u8 = undefined,
    w: std.Io.Writer = undefined,

    fn init(self: *TestWriter) void {
        self.w = .fixed(&self.buf);
    }
};

// ── grid ────────────────────────────────────────────────────

test "buffer: init yields an all-empty grid" {
    var buf = try Buffer.init(std.testing.allocator, 4, 2);
    defer buf.deinit();
    try std.testing.expectEqual(@as(u16, 4), buf.width);
    try std.testing.expectEqual(@as(u16, 2), buf.height);
    try std.testing.expect(buf.get(0, 0).eql(Cell{}));
    try std.testing.expect(buf.get(3, 1).eql(Cell{}));
}

test "buffer: get is bounds-checked, set out of bounds is a no-op" {
    var buf = try Buffer.init(std.testing.allocator, 6, 3);
    defer buf.deinit();

    try std.testing.expect(buf.get(6, 0).eql(Cell{})); // x == width
    try std.testing.expect(buf.get(0, 3).eql(Cell{})); // y == height
    try std.testing.expect(buf.get(99, 99).eql(Cell{}));

    try buf.set(99, 0, .{ .grapheme = "z" }); // no-op, no error
    try buf.set(0, 99, .{ .grapheme = "z" });
    try std.testing.expect(buf.get(0, 0).eql(Cell{}));
    try std.testing.expect(buf.get(5, 2).eql(Cell{}));
}

test "buffer: set/get round-trip" {
    var buf = try Buffer.init(std.testing.allocator, 6, 3);
    defer buf.deinit();

    const cell = Cell{ .grapheme = "x", .style = .{ .fg = .{ .ansi = .red } } };
    try buf.set(4, 2, cell);
    const got = buf.get(4, 2);
    try std.testing.expect(got.eql(cell));
    try std.testing.expect(!got.wide);
    try std.testing.expect(buf.get(5, 2).eql(Cell{})); // neighbors untouched
    try std.testing.expect(buf.get(3, 2).eql(Cell{}));
}

test "buffer: wide glyph placement writes a styled continuation" {
    var buf = try Buffer.init(std.testing.allocator, 6, 3);
    defer buf.deinit();

    const style = Style{ .fg = .{ .ansi = .red } };
    try buf.set(2, 0, .{ .grapheme = "👨‍🌾", .style = style });

    const lead = buf.get(2, 0);
    try std.testing.expectEqualStrings("👨‍🌾", lead.grapheme);
    try std.testing.expect(lead.style.eql(style));
    try std.testing.expect(!lead.wide);

    const cont = buf.get(3, 0);
    try std.testing.expectEqualStrings("", cont.grapheme);
    try std.testing.expect(cont.style.eql(style));
    try std.testing.expect(cont.wide);
}

test "buffer: overwriting a wide continuation nulls its lead" {
    var buf = try Buffer.init(std.testing.allocator, 6, 3);
    defer buf.deinit();

    try buf.set(2, 0, .{ .grapheme = "👨‍🌾" });
    try buf.set(3, 0, .{ .grapheme = "x" }); // writes onto the continuation

    try std.testing.expect(buf.get(2, 0).eql(Cell{})); // lead nulled
    try std.testing.expectEqualStrings("x", buf.get(3, 0).grapheme);
    try std.testing.expect(!buf.get(3, 0).wide);
}

test "buffer: overwriting a wide lead nulls its continuation" {
    var buf = try Buffer.init(std.testing.allocator, 6, 3);
    defer buf.deinit();

    try buf.set(2, 0, .{ .grapheme = "👨‍🌾" });
    try buf.set(2, 0, .{ .grapheme = "y" }); // overwrite the lead

    try std.testing.expect(buf.get(3, 0).eql(Cell{})); // continuation nulled
    try std.testing.expectEqualStrings("y", buf.get(2, 0).grapheme);
    try std.testing.expect(!buf.get(2, 0).wide);
}

test "buffer: wide glyph at the last column sets no continuation" {
    var buf = try Buffer.init(std.testing.allocator, 6, 3);
    defer buf.deinit();

    try buf.set(5, 0, .{ .grapheme = "👨‍🌾" }); // x + 1 == width
    const lead = buf.get(5, 0);
    try std.testing.expectEqualStrings("👨‍🌾", lead.grapheme);
    try std.testing.expect(!lead.wide);
    try std.testing.expect(buf.get(4, 0).eql(Cell{}));
}

test "buffer: draw places graphemes and returns columns consumed" {
    var buf = try Buffer.init(std.testing.allocator, 10, 1);
    defer buf.deinit();

    const n = try buf.draw(Style{}, "Hello", 2, 0);
    try std.testing.expectEqual(@as(u16, 5), n);
    try std.testing.expectEqualStrings("H", buf.get(2, 0).grapheme);
    try std.testing.expectEqualStrings("o", buf.get(6, 0).grapheme);
    try std.testing.expect(buf.get(1, 0).eql(Cell{})); // before x untouched
    try std.testing.expect(buf.get(7, 0).eql(Cell{}));
}

test "buffer: draw drops a wide glyph crossing the right edge gracefully" {
    var buf = try Buffer.init(std.testing.allocator, 5, 1);
    defer buf.deinit();

    // "ab" at cols 3-4; the wide glyph needs cols 5-6 and is dropped,
    // along with everything after it ("cd").
    const n = try buf.draw(Style{}, "ab👨‍🌾cd", 3, 0);
    try std.testing.expectEqual(@as(u16, 2), n);
    try std.testing.expectEqualStrings("a", buf.get(3, 0).grapheme);
    try std.testing.expectEqualStrings("b", buf.get(4, 0).grapheme);
    try std.testing.expect(buf.get(0, 0).eql(Cell{}));
    try std.testing.expect(!buf.get(4, 0).wide);
}

test "buffer: zero-width combining marks advance no column" {
    var buf = try Buffer.init(std.testing.allocator, 6, 1);
    defer buf.deinit();

    const n = try buf.draw(Style{}, "e\u{301}x", 2, 0);
    try std.testing.expectEqual(@as(u16, 2), n); // two display columns
    try std.testing.expectEqualStrings("e\u{301}", buf.get(2, 0).grapheme);
    try std.testing.expectEqualStrings("x", buf.get(3, 0).grapheme);
    try std.testing.expect(buf.get(4, 0).eql(Cell{}));
}

test "buffer: draw out of bounds returns 0" {
    var buf = try Buffer.init(std.testing.allocator, 6, 3);
    defer buf.deinit();

    try std.testing.expectEqual(@as(u16, 0), try buf.draw(Style{}, "abc", 0, 3));
    try std.testing.expectEqual(@as(u16, 0), try buf.draw(Style{}, "abc", 7, 0));
    try std.testing.expectEqual(@as(u16, 0), try buf.draw(Style{}, "", 0, 0));
    try std.testing.expect(buf.get(0, 0).eql(Cell{}));
}

test "buffer: resize smaller copies the overlap" {
    var buf = try Buffer.init(std.testing.allocator, 6, 3);
    defer buf.deinit();
    _ = try buf.draw(Style{}, "abcdef", 0, 0);
    _ = try buf.draw(Style{}, "ghijkl", 0, 1);

    try buf.resize(4, 2);
    try std.testing.expectEqual(@as(u16, 4), buf.width);
    try std.testing.expectEqual(@as(u16, 2), buf.height);
    try std.testing.expectEqualStrings("a", buf.get(0, 0).grapheme);
    try std.testing.expectEqualStrings("d", buf.get(3, 0).grapheme);
    try std.testing.expect(buf.get(4, 0).eql(Cell{})); // cut off
    try std.testing.expectEqualStrings("g", buf.get(0, 1).grapheme);
    try std.testing.expectEqualStrings("j", buf.get(3, 1).grapheme);
}

test "buffer: resize larger keeps the overlap, new area empty" {
    var buf = try Buffer.init(std.testing.allocator, 4, 2);
    defer buf.deinit();
    _ = try buf.draw(Style{}, "abcd", 0, 0);

    try buf.resize(6, 3);
    try std.testing.expectEqual(@as(u16, 6), buf.width);
    try std.testing.expectEqual(@as(u16, 3), buf.height);
    try std.testing.expectEqualStrings("a", buf.get(0, 0).grapheme);
    try std.testing.expectEqualStrings("d", buf.get(3, 0).grapheme);
    try std.testing.expect(buf.get(4, 0).eql(Cell{}));
    try std.testing.expect(buf.get(0, 2).eql(Cell{}));
}

test "buffer: clear resets every cell" {
    var buf = try Buffer.init(std.testing.allocator, 4, 2);
    defer buf.deinit();
    _ = try buf.draw(Style{}, "abcd", 0, 0);

    buf.clear();
    try std.testing.expect(buf.get(0, 0).eql(Cell{}));
    try std.testing.expect(buf.get(3, 0).eql(Cell{}));
    try std.testing.expect(buf.get(3, 1).eql(Cell{}));
}

// ── renderDiff goldens ──────────────────────────────────────

test "renderDiff: full row set emits the exact byte string" {
    var prev = try Buffer.init(std.testing.allocator, 6, 3);
    defer prev.deinit();
    var cur = try Buffer.init(std.testing.allocator, 6, 3);
    defer cur.deinit();
    _ = try cur.draw(Style{}, "hi", 0, 0);
    _ = try cur.draw(Style{}, "yo", 0, 1);

    var t = TestWriter{};
    t.init();
    try cur.renderDiff(&prev, &t.w);
    // Row 0: `\r` + column-1 erase + cells; row 1: `\r\n` + erase +
    // cells; row 2 unchanged and not emitted; default styles, so no SGR
    // and no trailing reset.
    try std.testing.expectEqualStrings("\r\x1b[Khi\r\n\x1b[Kyo", t.w.buffered());
}

test "renderDiff: one-cell change emits only that cell's bytes" {
    var prev = try Buffer.init(std.testing.allocator, 6, 3);
    defer prev.deinit();
    try prev.set(2, 1, .{ .grapheme = "a" });
    var cur = try Buffer.init(std.testing.allocator, 6, 3);
    defer cur.deinit();
    try cur.set(2, 1, .{ .grapheme = "b" });

    var t = TestWriter{};
    t.init();
    try cur.renderDiff(&prev, &t.w);
    // Row 0 and the blank cells of row 1 are never re-emitted: the only
    // cell bytes are "b", reached by `\r\n` + erase + CUF 2.
    try std.testing.expectEqualStrings("\r\n\x1b[K\x1b[2Cb", t.w.buffered());
}

test "renderDiff: style-only change emits only the SGR delta" {
    var prev = try Buffer.init(std.testing.allocator, 6, 3);
    defer prev.deinit();
    try prev.set(2, 1, .{ .grapheme = "a" });
    var cur = try Buffer.init(std.testing.allocator, 6, 3);
    defer cur.deinit();
    try cur.set(2, 1, .{ .grapheme = "a", .style = .{ .fg = .{ .ansi = .red } } });

    var t = TestWriter{};
    t.init();
    try cur.renderDiff(&prev, &t.w);
    // Same text, new style: SGR `\x1b[31m` + the cell, then the
    // frame-boundary reset (last emitted style was non-default).
    try std.testing.expectEqualStrings("\r\n\x1b[K\x1b[2C\x1b[31ma\x1b[0m", t.w.buffered());
}

test "renderDiff: idle frame (cur == prev) emits zero bytes" {
    var prev = try Buffer.init(std.testing.allocator, 6, 3);
    defer prev.deinit();
    var cur = try Buffer.init(std.testing.allocator, 6, 3);
    defer cur.deinit();
    _ = try prev.draw(Style{}, "hi", 0, 0);
    _ = try cur.draw(Style{}, "hi", 0, 0);

    var t = TestWriter{};
    t.init();
    try cur.renderDiff(&prev, &t.w);
    try std.testing.expectEqualStrings("", t.w.buffered());
}

test "renderDiff: wide continuation is never emitted" {
    var prev = try Buffer.init(std.testing.allocator, 6, 3);
    defer prev.deinit();
    var cur = try Buffer.init(std.testing.allocator, 6, 3);
    defer cur.deinit();
    _ = try cur.draw(Style{}, "a👨‍🌾b", 0, 0);

    var t = TestWriter{};
    t.init();
    try cur.renderDiff(&prev, &t.w);
    // The continuation cell (column 2) emits nothing: the glyph appears
    // exactly once and the walk jumps straight from the lead to "b".
    try std.testing.expectEqualStrings("\r\x1b[Ka👨‍🌾b", t.w.buffered());
}

test "renderDiff: column-1 erase precedes a changed row below the first" {
    var prev = try Buffer.init(std.testing.allocator, 6, 3);
    defer prev.deinit();
    var cur = try Buffer.init(std.testing.allocator, 6, 3);
    defer cur.deinit();
    try cur.set(0, 2, .{ .grapheme = "z" });

    var t = TestWriter{};
    t.init();
    try cur.renderDiff(&prev, &t.w);
    // First changed row is 2: `\r` + two `\n` moves, then the erase at
    // column 1 — the `\r\x1b[K` column-1 erase pattern.
    try std.testing.expectEqualStrings("\r\n\n\x1b[Kz", t.w.buffered());
}

test "renderDiff: unchanged rows between changed rows are not touched" {
    var prev = try Buffer.init(std.testing.allocator, 6, 3);
    defer prev.deinit();
    _ = try prev.draw(Style{}, "aaaaaaaaaa", 0, 0); // truncated to width 6
    _ = try prev.draw(Style{}, "bbbbbbbbbb", 0, 2);
    var cur = try Buffer.init(std.testing.allocator, 6, 3);
    defer cur.deinit();
    _ = try cur.draw(Style{}, "aaaaaaaaaa", 0, 0);
    _ = try cur.draw(Style{}, "bbbbbbbbbb", 0, 2);
    try cur.set(5, 2, .{ .grapheme = "!" }); // only change: row 2, col 5

    var t = TestWriter{};
    t.init();
    try cur.renderDiff(&prev, &t.w);
    // Row 0 is identical and never re-emitted; row 2 is erased then
    // rewritten ("bbbbb" unchanged but blanked by the erase, "!" new).
    try std.testing.expectEqualStrings("\r\n\n\x1b[Kbbbbb!", t.w.buffered());
}

// ── renderAll goldens ───────────────────────────────────────

test "renderAll: full band plain" {
    var buf = try Buffer.init(std.testing.allocator, 4, 2);
    defer buf.deinit();
    _ = try buf.draw(Style{}, "ab", 0, 0);
    _ = try buf.draw(Style{}, "cd", 0, 1);

    var t = TestWriter{};
    t.init();
    try buf.renderAll(&t.w);
    try std.testing.expectEqualStrings("\r\x1b[Kab\r\n\x1b[Kcd", t.w.buffered());
}

test "renderAll: style deltas and wide glyphs" {
    var buf = try Buffer.init(std.testing.allocator, 4, 2);
    defer buf.deinit();
    const red = Style{ .fg = .{ .ansi = .red } };
    _ = try buf.draw(red, "a", 0, 0);
    _ = try buf.draw(Style{}, "b", 1, 0);
    _ = try buf.draw(red, "👨‍🌾", 0, 1);
    _ = try buf.draw(Style{}, "c", 2, 1);

    var t = TestWriter{};
    t.init();
    try buf.renderAll(&t.w);
    try std.testing.expectEqualStrings(
        "\r\x1b[K\x1b[31ma\x1b[0mb\r\n\x1b[K\x1b[31m👨‍🌾\x1b[0mc",
        t.w.buffered(),
    );
}

test "renderAll: empty band emits the row erases only" {
    var buf = try Buffer.init(std.testing.allocator, 4, 2);
    defer buf.deinit();

    var t = TestWriter{};
    t.init();
    try buf.renderAll(&t.w);
    try std.testing.expectEqualStrings("\r\x1b[K\r\n\x1b[K", t.w.buffered());
}
