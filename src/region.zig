//! Region: the inline renderer — the v0 centerpiece.
//!
//! A `Region` owns a fixed `height`-row band in the terminal's main
//! buffer (never the alt screen) and repaints it in place with three
//! strategies, an append queue that flushes ABOVE the band into
//! scrollback, cursor anchoring, and a clean exit that leaves the final
//! frame in the transcript.
//!
//! Mechanics (architecture §4, plan P5 T5.1–T5.6):
//!
//! - **Anchor.** The band top is the anchor. Between frames the cursor
//!   sits at the band bottom (column 1 of the last row); each frame
//!   returns to the anchor with `\r` + CUU (`\x1b[{n}A` — the single
//!   upward relative move, the libvaxis primary-screen pattern). No
//!   absolute CUP is ever emitted, so the accounting is exact absent
//!   external writes; the anchor's absolute row is bookkeeping only
//!   (`anchor_row`, shifted by append flushes). CPR (`ESC[6n`) is
//!   re-queried on the first render, after resize, and on `reanchor()`;
//!   v0 does not consume the reply (it surfaces as `Event.cpr` for the
//!   app — drift correction deferred, architecture §9.2).
//!
//! - **Three strategies.** (1) First render: append all `height` rows
//!   WITHOUT clearing, reserving the band with `appendLines` (CNL) when
//!   `opts.append_lines`; sets the high-water mark. (2) Width change /
//!   forced (`width_dirty`, set by `resize`): `ESC[J` from the anchor
//!   (bounded below it — never clears above), then a full re-render of
//!   exactly `height` rows — the guard against the ratatui
//!   resize-duplicates-into-scrollback bug (§9.3). (3) Normal: diff
//!   `cur` against `prev` (buffer `renderDiff`, column-1 erase), then
//!   high-water clear-on-shrink erases rows the previous frames emitted
//!   below the current content end that the diff never revisits.
//!   Idle frames emit zero bytes.
//!
//! - **Append queue.** `append()` queues items flushed before the region
//!   renders each frame: move to the band top, `ESC[J`, write items
//!   (text `\n`→`\r\n`, line verbatim), then full repaint (the flush's
//!   `ESC[J` wiped the band). Line items shift the anchor by their exact
//!   row count; text items let the terminal decide the wrap, so the
//!   anchor is re-queried next frame (`anchor_dirty`).
//!
//! - **Exit / non-TTY.** `exit()` shows the cursor (if hidden), closes
//!   sync output, parks `\r\n\r` below the band, and clears nothing —
//!   the final frame stays in the transcript. With
//!   `opts.sync_output = false` the region degrades (architecture §4.8,
//!   plan resolution): one plain frame, no hide/CPR/sync/erase/CNL, no
//!   park — the ink/delta piped-output pattern.
//!
//! Writer-agnostic: imports only buffer, emit, width, caps (the
//! `WidthPolicy` type). No tty, no zg — the zg import grep-gate is
//! `width.zig` only.

const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Cell = @import("cell.zig").Cell;
const Style = @import("style.zig").Style;
const emit = @import("emit.zig");
const Width = @import("width.zig");
const caps = @import("caps.zig");

/// The inline Region renderer.
pub const Region = struct {
    pub const Options = struct {
        /// Number of terminal rows the region owns.
        height: u16,
        /// Reserve the band on the first render with `ESC[n E` (CNL),
        /// pushing the terminal so the region owns a stable band.
        append_lines: bool = true,
        /// Interactive terminal output: synchronized output wrapping,
        /// CPR re-queries, cursor hiding, and the exit park. When false
        /// the region degrades to one plain frame (non-TTY / piped).
        sync_output: bool = true,
        /// Width measurement policy; passed through to the width seam
        /// consumers (Buffer.draw enforces width via zg).
        width_policy: caps.Capabilities.WidthPolicy = .zg_unicode,
    };

    /// Queued output written ABOVE the region into scrollback before the
    /// next render (the print-above escape hatch, §4.4).
    pub const Append = union(enum) {
        /// Free text; the terminal reflows/wraps it. Internal `\n` is
        /// written as `\r\n`. The row count is terminal-decided, so the
        /// anchor is re-queried next frame.
        text: []const u8,
        /// One hard-wrapped exact-layout terminal row (vaxis
        /// AppendWidget split). Written verbatim, occupies exactly one
        /// row — the anchor shifts deterministically.
        line: []const u8,
    };

    gpa: std.mem.Allocator,
    /// Current frame the app draws into; public so apps can draw.
    cur: Buffer,
    /// Previous frame, diffed against on strategy-3 frames.
    prev: Buffer,
    opts: Options,

    /// Tracked terminal row of the band top (bookkeeping only — never
    /// used for absolute positioning; shifted by append flushes).
    anchor_row: u16 = 0,
    /// Highest row index ever emitted since the last clear; the shrink
    /// path erases stale rows between the content end and this mark.
    high_water: u16 = 0,
    /// A CPR re-query is due at the next render start (first render,
    /// resize, reanchor, or a text-item append flush).
    anchor_dirty: bool = true,
    /// A width change / forced full redraw (strategy 2) is due.
    width_dirty: bool = false,
    /// The region has not rendered yet (strategy 1 pending).
    first_frame: bool = true,
    /// The cursor was hidden by the first interactive render.
    cursor_hidden: bool = false,
    /// `exit()` already ran (idempotence).
    exited: bool = false,
    /// Pending appends, flushed before the region renders each frame.
    append_queue: std.ArrayListUnmanaged(Append) = .empty,

    /// Buffer width (mirrors `cur.width`; default 80 until the app
    /// resizes from the terminal winsize).
    width: u16,
    /// Buffer height (mirrors `cur.height`; from `opts.height`).
    height: u16,

    /// Allocate the double buffer and the append queue.
    ///
    /// Buffers start 80 columns wide — zero-width buffers would silently
    /// drop the first frame's draws until a resize arrives; the app
    /// resizes from the terminal winsize before or during the first
    /// frame ([UNVERIFIED: default width chosen by the implementer, plan
    /// T5.1 leaves it open]).
    pub fn init(gpa: std.mem.Allocator, opts: Options) !Region {
        var cur = try Buffer.init(gpa, 80, opts.height);
        errdefer cur.deinit();
        var prev = try Buffer.init(gpa, 80, opts.height);
        errdefer prev.deinit();
        return .{
            .gpa = gpa,
            .cur = cur,
            .prev = prev,
            .opts = opts,
            .height = opts.height,
            .width = 80,
        };
    }

    pub fn deinit(self: *Region) void {
        self.append_queue.deinit(self.gpa);
        self.cur.deinit();
        self.prev.deinit();
    }

    /// Realloc both buffers (overlap copied by `Buffer.resize`), then
    /// mark the next frame for a strategy-2 clear + full redraw and a
    /// CPR re-query.
    pub fn resize(self: *Region, new_width: u16, new_height: u16) !void {
        try self.cur.resize(new_width, new_height);
        try self.prev.resize(new_width, new_height);
        self.width = new_width;
        self.height = new_height;
        self.width_dirty = true;
        self.anchor_dirty = true;
    }

    /// Queue `item` to flush ABOVE the region on the next render.
    pub fn append(self: *Region, item: Append) !void {
        try self.append_queue.append(self.gpa, item);
    }

    /// Force a strategy-2 full redraw on the next render.
    pub fn renderFull(self: *Region, w: anytype) !void {
        self.width_dirty = true;
        try self.render(w);
    }

    /// Mark the anchor as suspect; the next render re-queries CPR
    /// (the reply surfaces as `Event.cpr` for the app — v0 does not
    /// consume it).
    pub fn reanchor(self: *Region) !void {
        self.anchor_dirty = true;
    }

    /// Render one frame into `w` (a std.Io.Writer-compatible writer).
    ///
    /// Frame flow: CPR re-query (when due) → append flush (when queued)
    /// → strategy 1 / 2 / 3 → synchronized-output wrap (interactive
    /// frames only). Idle frames (no changes, no pending work) emit
    /// zero bytes. After the frame the cursor sits at the band bottom
    /// (column 1 of the last row).
    pub fn render(self: *Region, w: anytype) !void {
        const tty = self.opts.sync_output;

        // Non-TTY degradation (§4.8 / plan resolution): one plain frame
        // with no interactive sequences; every later frame emits
        // nothing (the plain frame was the only output — ink/delta).
        if (!tty) {
            if (!self.first_frame) return;
            self.first_frame = false;
            var tracked = Style{};
            for (0..self.height) |y| {
                if (y > 0) try w.writeByte('\n');
                try self.writeRow(w, y, &tracked);
            }
            if (!tracked.eql(Style{})) try w.writeAll(emit.reset);
            try w.writeByte('\n');
            return;
        }

        const cpr = self.anchor_dirty;
        const flush = self.append_queue.items.len > 0;
        const diff = self.scanChanges();
        const changed = self.first_frame or self.width_dirty or flush or
            (diff != null);
        if (!cpr and !changed) return; // idle: emit nothing (§3)
        if (cpr) self.anchor_dirty = false;

        try emit.beginSync(w);
        if (cpr) try emit.queryCursor(w);

        if (self.first_frame) {
            // Strategy 1: append all `height` lines WITHOUT clearing
            // (scrollback preservation, §4.5); first-frame priority over
            // width_dirty — a strategy-2 clear before anything rendered
            // would erase the shell's output below the cursor.
            self.first_frame = false;
            self.width_dirty = false;
            if (flush) try self.flushAtCursor(w);
            try self.paintFirst(w);
        } else if (flush) {
            // Append flush (§4.4): write the queue above the band, then
            // repaint every row (the flush's ESC[J wiped the band, so a
            // partial diff would leave holes).
            try self.moveToBandTop(w);
            try emit.eraseToEnd(w);
            try self.writeAppends(w);
            try self.paintAll(w);
            self.width_dirty = false;
        } else if (self.width_dirty) {
            // Strategy 2: width change / forced full redraw — clear from
            // the anchor down, then re-render exactly `height` rows.
            try self.moveToBandTop(w);
            try emit.eraseToEnd(w);
            try self.paintAll(w);
            self.width_dirty = false;
        } else if (diff) |ch| {
            // Strategy 3: normal diff. A CPR-only frame (`diff == null`)
            // falls through with just the query.
            try self.renderDiffFrame(w, ch);
        }

        self.syncPrev();
        try emit.endSync(w);
    }

    /// Exit the interactive session: show the cursor, close sync output,
    /// and park `\r\n\r` below the last region row — the final frame
    /// stays in the transcript, nothing is cleared. Idempotent. In
    /// non-TTY mode exits without emitting anything.
    pub fn exit(self: *Region, w: anytype) !void {
        if (self.exited) return;
        self.exited = true;
        if (!self.opts.sync_output) return;
        if (self.cursor_hidden) try emit.showCursor(w);
        try emit.endSync(w);
        try w.writeAll("\r\n\r");
    }

    // ── frame painters ─────────────────────────────────────

    /// Strategy 1: reserve the band (CNL, when configured), hide the
    /// cursor, and append all `height` rows without clearing. Ends with
    /// the cursor at the band bottom.
    fn paintFirst(self: *Region, w: anytype) !void {
        if (self.opts.append_lines) {
            try emit.appendLines(w, self.height);
            self.anchor_row +|= self.height;
        }
        // Cursor hygiene: hidden for the interactive session, shown in
        // exit().
        try emit.hideCursor(w);
        self.cursor_hidden = true;

        var tracked = Style{};
        for (0..self.height) |y| {
            // Row 0: column 1 regardless of where the app left the
            // cursor (after appendLines the CNL already lands on column
            // 1; `\r` is then redundant but harmless). Rows 1+: `\r\n`.
            if (y > 0) {
                try w.writeAll("\r\n");
            } else {
                try w.writeAll("\r");
            }
            try self.writeRow(w, y, &tracked);
        }
        if (!tracked.eql(Style{})) try w.writeAll(emit.reset);
        try w.writeAll("\r");
        self.high_water = self.height;
    }

    /// Full repaint of every row after a clear (strategy 2, or the
    /// post-flush repaint). Entry: cursor at the band top (column 1 of
    /// row 0). `renderAll` erases each row at column 1 before writing;
    /// never emits more than `height` rows.
    fn paintAll(self: *Region, w: anytype) !void {
        try self.cur.renderAll(w);
        try w.writeAll("\r");
        self.high_water = self.height;
    }

    /// Strategy 3: diff against `prev` from the anchor, then the
    /// high-water clear-on-shrink. Ends with the cursor at the band
    /// bottom.
    fn renderDiffFrame(self: *Region, w: anytype, ch: RowRange) !void {
        try self.moveToBandTop(w);
        try self.cur.renderDiff(&self.prev, w);

        // High-water clear-on-shrink: rows the previous frames emitted
        // below the current content end can hold stale bytes the diff
        // never revisits (unchanged rows are left as-is). Erase that
        // tail once and drop the mark.
        var bottom_row: usize = ch.last;
        const content_len = self.contentLen();
        if (content_len < self.high_water) {
            const hw = self.high_water;
            const tail_start = @max(content_len, ch.last + 1);
            if (tail_start < hw) {
                // Move from the end of the last emitted row to the tail.
                try w.writeAll("\r");
                var down = tail_start - ch.last;
                while (down > 0) : (down -= 1) try w.writeByte('\n');
                var y = tail_start;
                while (y < hw) : (y += 1) {
                    try emit.eraseLine(w);
                    if (y + 1 < hw) try w.writeAll("\r\n");
                }
                bottom_row = hw - 1;
            }
            self.high_water = @intCast(content_len);
        }

        // Return to the band bottom (column 1 of the last row).
        try w.writeAll("\r");
        var rest = self.height - 1 - @as(u16, @intCast(bottom_row));
        while (rest > 0) : (rest -= 1) try w.writeByte('\n');
    }

    // ── append flush ───────────────────────────────────────

    /// First-frame flush: nothing rendered yet, so the appends go at the
    /// current cursor position, above the band the first render is about
    /// to append below.
    fn flushAtCursor(self: *Region, w: anytype) !void {
        try self.writeAppends(w);
    }

    /// Write every queued item, translating text `\n` to `\r\n` and
    /// writing lines verbatim; each item is followed by `\r\n` so the
    /// next item (or the repaint) starts at column 1 of the next row.
    /// Drains the queue.
    fn writeAppends(self: *Region, w: anytype) !void {
        var rows: u16 = 0;
        for (self.append_queue.items) |item| {
            switch (item) {
                .line => |l| {
                    try w.writeAll(l);
                    try w.writeAll("\r\n");
                    rows += 1;
                },
                .text => |t| {
                    var it = std.mem.splitScalar(u8, t, '\n');
                    var first_seg = true;
                    while (it.next()) |seg| {
                        if (!first_seg) try w.writeAll("\r\n");
                        first_seg = false;
                        try w.writeAll(seg);
                    }
                    if (!std.mem.endsWith(u8, t, "\n")) try w.writeAll("\r\n");
                    // The terminal's own wrap decides the row count:
                    // re-query the anchor next frame.
                    self.anchor_dirty = true;
                },
            }
        }
        self.anchor_row +|= rows;
        self.append_queue.clearRetainingCapacity();
    }

    // ── cursor moves (relative only) ───────────────────────

    /// Move from the band bottom to the band top: `\r` + CUU. The one
    /// upward relative move; the anchor is never positioned absolutely
    /// (grep-gate: no absolute cursor-positioning call in this file).
    fn moveToBandTop(self: *const Region, w: anytype) !void {
        try w.writeAll("\r");
        if (self.height > 1) try w.print("\x1b[{d}A", .{self.height - 1});
    }

    // ── diff bookkeeping ───────────────────────────────────

    const RowRange = struct { first: usize, last: usize };

    /// Rows of `cur` that differ from `prev`, or null when equal (idle).
    fn scanChanges(self: *const Region) ?RowRange {
        var first: ?usize = null;
        var last: usize = 0;
        for (0..self.cur.height) |y| {
            if (self.rowEqual(y)) continue;
            if (first == null) first = y;
            last = y;
        }
        const f = first orelse return null;
        return .{ .first = f, .last = last };
    }

    fn rowEqual(self: *const Region, y: usize) bool {
        for (0..self.cur.width) |x| {
            if (!self.cur.get(@intCast(x), @intCast(y)).eql(self.prev.get(@intCast(x), @intCast(y)))) return false;
        }
        return true;
    }

    /// Number of rows the current frame occupies: index of the last
    /// non-empty row plus one (0 when the band is empty).
    fn contentLen(self: *const Region) usize {
        var y = self.cur.height;
        while (y > 0) {
            y -= 1;
            if (self.rowNonEmpty(y)) return y + 1;
        }
        return 0;
    }

    fn rowNonEmpty(self: *const Region, y: usize) bool {
        for (0..self.cur.width) |x| {
            if (!self.cur.get(@intCast(x), @intCast(y)).eql(Cell{})) return true;
        }
        return false;
    }

    /// The next frame diffs against this one.
    fn syncPrev(self: *Region) void {
        @memcpy(self.prev.cells, self.cur.cells);
    }

    // ── row emission ───────────────────────────────────────

    /// Write one row's cells (entry: cursor at column 1 of the row).
    /// Mirrors `Buffer.writeRow`: wide continuations and blank cells
    /// never emit text (blank skips advance with CUF); SGR is written
    /// only on style change (libvaxis DAM pattern). Used by the
    /// non-clearing strategy-1 / non-TTY paths — `renderDiff` and
    /// `renderAll` own the erasing paths.
    fn writeRow(self: *const Region, w: anytype, y: usize, tracked: *Style) !void {
        var x: usize = 0;
        var phys_col: usize = 0; // terminal cursor column, 0-indexed
        while (x < self.cur.width) {
            const cell = self.cur.get(@intCast(x), @intCast(y));

            // Wide continuations never emit text; their column was
            // covered by the lead's write (which advances 2).
            if (cell.wide or cell.grapheme.len == 0) {
                x += 1;
                continue;
            }
            // Blank cells are already blank; skip them.
            if (cell.eql(Cell{})) {
                x += 1;
                continue;
            }

            const wg = Width.graphemeWidth(cell.grapheme);
            const wcell: usize = if (wg >= 2) 2 else 1;
            // A wide glyph at the last column has no continuation cell;
            // drop it (graceful — over-wide never errors, plan §0).
            if (x + wcell > self.cur.width) {
                x += 1;
                continue;
            }

            if (x > phys_col) try w.print("\x1b[{d}C", .{x - phys_col});
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
/// fields); a fully-default target style emits just the reset.
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
/// (same pattern as buffer.zig / emit.zig).
const TestWriter = struct {
    buf: [4096]u8 = undefined,
    w: std.Io.Writer = undefined,

    fn init(self: *TestWriter) void {
        self.w = .fixed(&self.buf);
    }
};

fn makeRegion(h: u16, sync: bool, append_lines: bool) !Region {
    return Region.init(std.testing.allocator, .{
        .height = h,
        .sync_output = sync,
        .append_lines = append_lines,
    });
}

fn drawRow(buf: *Buffer, y: u16, text: []const u8) !void {
    _ = try buf.draw(Style{}, text, 0, y);
}

fn clearRow(buf: *Buffer, y: u16, cols: u16) !void {
    for (0..cols) |x| try buf.set(@intCast(x), y, .{});
}

// ── T5.1 skeleton ─────────────────────────────────────────

test "region: init/deinit leak nothing, queue frees with items" {
    var r = try Region.init(std.testing.allocator, .{ .height = 3 });
    defer r.deinit();
    try r.append(.{ .text = "one" });
    try r.append(.{ .line = "two" });
    try r.append(.{ .line = "three" });
}

test "region: Options defaults" {
    const o = Region.Options{ .height = 3 };
    try std.testing.expect(o.append_lines);
    try std.testing.expect(o.sync_output);
    try std.testing.expectEqual(caps.Capabilities.WidthPolicy.zg_unicode, o.width_policy);
}

test "region: append queue round-trips into the first frame flush" {
    var r = try makeRegion(2, true, false);
    defer r.deinit();
    try r.append(.{ .line = "L" });
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");

    var t = TestWriter{};
    t.init();
    try r.render(&t.w);
    // Line item flushed verbatim at the cursor (first frame: no move, no
    // ESC[J — nothing rendered yet), then strategy 1 appends the rows.
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\x1b[6nL\r\n\x1b[?25l\rab\r\ncd\r\x1b[?2026l",
        t.w.buffered(),
    );
}

// ── T5.2 strategies 1 + 3 ─────────────────────────────────

test "region: first render appends height lines without clearing" {
    var r = try makeRegion(2, true, true);
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");

    var t = TestWriter{};
    t.init();
    try r.render(&t.w);
    // sync wrap + CPR re-query + CNL band reservation + hide cursor +
    // rows appended with relative moves only; no erase anywhere.
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\x1b[6n\x1b[2E\x1b[?25l\rab\r\ncd\r\x1b[?2026l",
        t.w.buffered(),
    );
    try std.testing.expect(std.mem.indexOf(u8, t.w.buffered(), "\x1b[K") == null);
    try std.testing.expect(std.mem.indexOf(u8, t.w.buffered(), "\x1b[J") == null);
    try std.testing.expectEqual(@as(u16, 2), r.high_water);
}

test "region: first render without append_lines emits no CNL" {
    var r = try makeRegion(2, true, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");

    var t = TestWriter{};
    t.init();
    try r.render(&t.w);
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\x1b[6n\x1b[?25l\rab\r\ncd\r\x1b[?2026l",
        t.w.buffered(),
    );
}

test "region: changed middle row emits a minimal diff" {
    var r = try makeRegion(3, true, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "aaa");
    try drawRow(&r.cur, 1, "bbb");
    try drawRow(&r.cur, 2, "ccc");

    var t1 = TestWriter{};
    t1.init();
    try r.render(&t1.w);
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\x1b[6n\x1b[?25l\raaa\r\nbbb\r\nccc\r\x1b[?2026l",
        t1.w.buffered(),
    );

    // Frame 2: only row 1 changes.
    try clearRow(&r.cur, 1, 3);
    try drawRow(&r.cur, 1, "BB");
    var t2 = TestWriter{};
    t2.init();
    try r.render(&t2.w);
    // moveToBandTop (`\r` + CUU 2) + renderDiff (`\r\n` + column-1
    // erase + row 1 cells) + return to the band bottom (`\r\n`).
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\r\x1b[2A\r\n\x1b[KBB\r\n\x1b[?2026l",
        t2.w.buffered(),
    );
}

test "region: shrink clears the stale tail (high-water)" {
    var r = try makeRegion(3, true, false);
    defer r.deinit();
    // Frame 1: only row 0 has content; strategy 1 still appends all 3
    // rows (rows 1-2 blank), high_water = 3.
    try drawRow(&r.cur, 0, "aaa");

    var t1 = TestWriter{};
    t1.init();
    try r.render(&t1.w);
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\x1b[6n\x1b[?25l\raaa\r\n\r\n\r\x1b[?2026l",
        t1.w.buffered(),
    );

    // Frame 2: row 0 changes, rows 1-2 stay blank (unchanged — the diff
    // never re-emits them, but they are beyond the content end).
    try clearRow(&r.cur, 0, 3);
    try drawRow(&r.cur, 0, "aa");
    var t2 = TestWriter{};
    t2.init();
    try r.render(&t2.w);
    // diff row 0, then the high-water tail [1,3) is erased row by row.
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\r\x1b[2A\r\x1b[Kaa\r\n\x1b[K\r\n\x1b[K\r\x1b[?2026l",
        t2.w.buffered(),
    );
    try std.testing.expectEqual(@as(u16, 1), r.high_water);
}

test "region: idle frame emits zero bytes" {
    var r = try makeRegion(2, true, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");

    var t1 = TestWriter{};
    t1.init();
    try r.render(&t1.w);

    var t2 = TestWriter{};
    t2.init();
    try r.render(&t2.w);
    try std.testing.expectEqualStrings("", t2.w.buffered());
}

test "region: sync_output off emits one plain unwrapped frame" {
    var r = try makeRegion(2, false, true);
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");

    var t = TestWriter{};
    t.init();
    try r.render(&t.w);
    // No sync, no CPR, no hide, no CNL reservation — plain rows only.
    try std.testing.expectEqualStrings("ab\ncd\n", t.w.buffered());
}

test "region: wide glyph row diff never emits the continuation" {
    var r = try makeRegion(1, true, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "a👨‍🌾b");

    var t1 = TestWriter{};
    t1.init();
    try r.render(&t1.w);
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\x1b[6n\x1b[?25l\ra👨‍🌾b\r\x1b[?2026l",
        t1.w.buffered(),
    );

    try clearRow(&r.cur, 0, 5);
    try drawRow(&r.cur, 0, "a👨‍🌾c");
    var t2 = TestWriter{};
    t2.init();
    try r.render(&t2.w);
    // The continuation cell (column 2) emits nothing: the glyph appears
    // exactly once.
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\r\r\x1b[Ka👨‍🌾c\r\x1b[?2026l",
        t2.w.buffered(),
    );
}

// ── T5.3 strategy 2 ───────────────────────────────────────

test "region: resize emits ESC[J then re-renders every row, never more than height" {
    var r = try makeRegion(3, true, false);
    defer r.deinit();
    try r.resize(20, 3);
    try drawRow(&r.cur, 0, &([_]u8{'a'} ** 20));
    try drawRow(&r.cur, 1, &([_]u8{'b'} ** 20));
    try drawRow(&r.cur, 2, &([_]u8{'c'} ** 20));

    var t1 = TestWriter{};
    t1.init();
    try r.render(&t1.w);
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\x1b[6n\x1b[?25l\r" ++ ("a" ** 20) ++ "\r\n" ++ ("b" ** 20) ++ "\r\n" ++ ("c" ** 20) ++ "\r\x1b[?2026l",
        t1.w.buffered(),
    );

    // Widen to 40: strategy 2 — CPR re-query, move to the anchor, ESC[J,
    // full row set at the new width. No partial-width leftovers.
    try r.resize(40, 3);
    try clearRow(&r.cur, 0, 40);
    try clearRow(&r.cur, 1, 40);
    try clearRow(&r.cur, 2, 40);
    try drawRow(&r.cur, 0, &([_]u8{'a'} ** 40));
    try drawRow(&r.cur, 1, &([_]u8{'b'} ** 40));
    try drawRow(&r.cur, 2, &([_]u8{'c'} ** 40));
    var t2 = TestWriter{};
    t2.init();
    try r.render(&t2.w);
    const expected =
        "\x1b[?2026h\x1b[6n\r\x1b[2A\x1b[J\r\x1b[K" ++ ("a" ** 40) ++
        "\r\n\x1b[K" ++ ("b" ** 40) ++ "\r\n\x1b[K" ++ ("c" ** 40) ++ "\r\x1b[?2026l";
    try std.testing.expectEqualStrings(expected, t2.w.buffered());
    // Exactly `height` rows were cleared and rewritten.
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, t2.w.buffered(), "\x1b[K"));
    try std.testing.expect(!r.width_dirty);
}

test "region: resize taller and shorter re-emits exactly height rows" {
    var r = try makeRegion(2, true, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    var t1 = TestWriter{};
    t1.init();
    try r.render(&t1.w);

    try r.resize(30, 4);
    try drawRow(&r.cur, 2, "ef");
    try drawRow(&r.cur, 3, "gh");
    var t2 = TestWriter{};
    t2.init();
    try r.render(&t2.w);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, t2.w.buffered(), "\x1b[K"));

    try r.resize(30, 1);
    var t3 = TestWriter{};
    t3.init();
    try r.render(&t3.w);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, t3.w.buffered(), "\x1b[K"));
}

test "region: width_dirty clears after the strategy-2 render" {
    var r = try makeRegion(2, true, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    var t1 = TestWriter{};
    t1.init();
    try r.render(&t1.w);

    try r.resize(40, 2);
    var t2 = TestWriter{};
    t2.init();
    try r.render(&t2.w);
    try std.testing.expect(!r.width_dirty);

    var t3 = TestWriter{};
    t3.init();
    try r.render(&t3.w);
    try std.testing.expectEqualStrings("", t3.w.buffered());
}

test "region: consecutive resizes each trigger a full redraw" {
    var r = try makeRegion(2, true, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    var t0 = TestWriter{};
    t0.init();
    try r.render(&t0.w);

    try r.resize(10, 2);
    var t1 = TestWriter{};
    t1.init();
    try r.render(&t1.w);
    try std.testing.expect(std.mem.indexOf(u8, t1.w.buffered(), "\x1b[J") != null);

    try r.resize(20, 2);
    var t2 = TestWriter{};
    t2.init();
    try r.render(&t2.w);
    try std.testing.expect(std.mem.indexOf(u8, t2.w.buffered(), "\x1b[J") != null);

    try r.resize(20, 3);
    var t3 = TestWriter{};
    t3.init();
    try r.render(&t3.w);
    try std.testing.expect(std.mem.indexOf(u8, t3.w.buffered(), "\x1b[J") != null);
}

// ── T5.4 append queue ─────────────────────────────────────

test "region: queued text flushes before the region rows" {
    var r = try makeRegion(2, true, false);
    defer r.deinit();
    try r.append(.{ .text = "hi" });
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");

    var t = TestWriter{};
    t.init();
    try r.render(&t.w);
    // First frame: the text item is flushed at the cursor (with its
    // `\r\n` terminator) before strategy 1 appends the region rows.
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\x1b[6nhi\r\n\x1b[?25l\rab\r\ncd\r\x1b[?2026l",
        t.w.buffered(),
    );
}

test "region: text newlines become CRLF in the flush" {
    var r = try makeRegion(3, true, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "aaa");
    try drawRow(&r.cur, 1, "bbb");
    try drawRow(&r.cur, 2, "ccc");
    var t1 = TestWriter{};
    t1.init();
    try r.render(&t1.w);

    try r.append(.{ .text = "a\nb" });
    var t2 = TestWriter{};
    t2.init();
    try r.render(&t2.w);
    // Steady-state flush: move to the band top, ESC[J, write the item
    // with `\n` translated to `\r\n`, then repaint every row.
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\r\x1b[2A\x1b[Ja\r\nb\r\n\r\x1b[Kaaa\r\n\x1b[Kbbb\r\n\x1b[Kccc\r\x1b[?2026l",
        t2.w.buffered(),
    );
    // The queue drains per frame; text wrap is terminal-decided, so the
    // anchor must be re-queried next frame.
    try std.testing.expectEqual(@as(usize, 0), r.append_queue.items.len);
    try std.testing.expect(r.anchor_dirty);
}

test "region: line items flush verbatim" {
    var r = try makeRegion(3, true, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "aaa");
    try drawRow(&r.cur, 1, "bbb");
    try drawRow(&r.cur, 2, "ccc");
    var t1 = TestWriter{};
    t1.init();
    try r.render(&t1.w);

    try r.append(.{ .line = "exact-line" });
    var t2 = TestWriter{};
    t2.init();
    try r.render(&t2.w);
    // The item bytes are written unchanged (only the flush's own `\r\n`
    // terminator is appended).
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\r\x1b[2A\x1b[Jexact-line\r\n\r\x1b[Kaaa\r\n\x1b[Kbbb\r\n\x1b[Kccc\r\x1b[?2026l",
        t2.w.buffered(),
    );
    // A line item occupies exactly one row: no anchor re-query.
    try std.testing.expect(!r.anchor_dirty);
}

test "region: line items shift the anchor deterministically" {
    var r = try makeRegion(3, true, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "aaa");
    try drawRow(&r.cur, 1, "bbb");
    try drawRow(&r.cur, 2, "ccc");
    var t1 = TestWriter{};
    t1.init();
    try r.render(&t1.w);
    try std.testing.expectEqual(@as(u16, 0), r.anchor_row);

    try r.append(.{ .line = "one" });
    var t2 = TestWriter{};
    t2.init();
    try r.render(&t2.w);
    try std.testing.expectEqual(@as(u16, 1), r.anchor_row);

    try r.append(.{ .line = "two" });
    try r.append(.{ .line = "three" });
    var t3 = TestWriter{};
    t3.init();
    try r.render(&t3.w);
    try std.testing.expectEqual(@as(u16, 3), r.anchor_row);
}

test "region: empty queue flushes nothing" {
    var r = try makeRegion(3, true, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "aaa");
    try drawRow(&r.cur, 1, "bbb");
    try drawRow(&r.cur, 2, "ccc");
    var t1 = TestWriter{};
    t1.init();
    try r.render(&t1.w);

    // A normal diff frame with no pending appends: no ESC[J, no flush
    // bytes — the strategy-3 path only.
    try clearRow(&r.cur, 0, 3);
    try drawRow(&r.cur, 0, "aa");
    var t2 = TestWriter{};
    t2.init();
    try r.render(&t2.w);
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\r\x1b[2A\r\x1b[Kaa\r\n\n\x1b[?2026l",
        t2.w.buffered(),
    );
    try std.testing.expectEqual(@as(usize, 0), r.append_queue.items.len);
}

// ── T5.5 reanchor + CPR ───────────────────────────────────

test "region: CPR on first render and resize, never in steady state" {
    var r = try makeRegion(2, true, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");

    var t1 = TestWriter{};
    t1.init();
    try r.render(&t1.w);
    try std.testing.expect(std.mem.indexOf(u8, t1.w.buffered(), "\x1b[6n") != null);

    // Steady state: changed frames carry no CPR query.
    try clearRow(&r.cur, 0, 2);
    try drawRow(&r.cur, 0, "aa");
    var t2 = TestWriter{};
    t2.init();
    try r.render(&t2.w);
    try std.testing.expect(std.mem.indexOf(u8, t2.w.buffered(), "\x1b[6n") == null);

    try clearRow(&r.cur, 1, 2);
    try drawRow(&r.cur, 1, "dd");
    var t3 = TestWriter{};
    t3.init();
    try r.render(&t3.w);
    try std.testing.expect(std.mem.indexOf(u8, t3.w.buffered(), "\x1b[6n") == null);

    // Resize re-queries (the strategy-2 golden in the T5.3 tests also
    // carries `\x1b[6n` after the first frame's).
    try r.resize(30, 2);
    var t4 = TestWriter{};
    t4.init();
    try r.render(&t4.w);
    try std.testing.expect(std.mem.indexOf(u8, t4.w.buffered(), "\x1b[6n") != null);
}

test "region: reanchor() re-queries on the next render" {
    var r = try makeRegion(2, true, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    var t1 = TestWriter{};
    t1.init();
    try r.render(&t1.w);

    var t2 = TestWriter{};
    t2.init();
    try r.render(&t2.w); // idle: zero bytes
    try std.testing.expectEqualStrings("", t2.w.buffered());

    try r.reanchor();
    var t3 = TestWriter{};
    t3.init();
    try r.render(&t3.w);
    // An idle frame with a pending re-anchor emits the CPR query only.
    try std.testing.expectEqualStrings("\x1b[?2026h\x1b[6n\x1b[?2026l", t3.w.buffered());
}

test "region: no CPR when sync_output is off" {
    var r = try makeRegion(2, false, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    var t = TestWriter{};
    t.init();
    try r.render(&t.w);
    try std.testing.expect(std.mem.indexOf(u8, t.w.buffered(), "\x1b[") == null);
}

// ── T5.6 exit + non-TTY ───────────────────────────────────

test "region: exit restores the cursor, closes sync, parks below the band" {
    var r = try makeRegion(2, true, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    var t1 = TestWriter{};
    t1.init();
    try r.render(&t1.w);

    var t2 = TestWriter{};
    t2.init();
    try r.exit(&t2.w);
    try std.testing.expectEqualStrings("\x1b[?25h\x1b[?2026l\r\n\r", t2.w.buffered());
}

test "region: exit is idempotent" {
    var r = try makeRegion(2, true, false);
    defer r.deinit();
    var t1 = TestWriter{};
    t1.init();
    try r.exit(&t1.w);
    try std.testing.expectEqualStrings("\x1b[?2026l\r\n\r", t1.w.buffered());

    var t2 = TestWriter{};
    t2.init();
    try r.exit(&t2.w);
    try std.testing.expectEqualStrings("", t2.w.buffered());
}

test "region: piped mode emits one plain frame, no interactive sequences" {
    var r = try makeRegion(2, false, true);
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");

    var t1 = TestWriter{};
    t1.init();
    try r.render(&t1.w);
    try std.testing.expectEqualStrings("ab\ncd\n", t1.w.buffered());
    try std.testing.expect(std.mem.indexOf(u8, t1.w.buffered(), "\x1b[") == null);

    // Later frames change nothing in a pipe: no repaint, no erase.
    try clearRow(&r.cur, 0, 2);
    try drawRow(&r.cur, 0, "zz");
    var t2 = TestWriter{};
    t2.init();
    try r.render(&t2.w);
    try std.testing.expectEqualStrings("", t2.w.buffered());

    // Exit parks nothing in piped mode.
    var t3 = TestWriter{};
    t3.init();
    try r.exit(&t3.w);
    try std.testing.expectEqualStrings("", t3.w.buffered());
}
