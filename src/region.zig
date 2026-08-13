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
//!   the reply surfaces as `Event.cpr` and is consumed by the app via
//!   `applyCpr` — the drift correction deferred in architecture §9.2.
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

    /// Tracked terminal row of the band top (1-indexed, DEC CPR
    /// convention; shifted by append flushes). Bookkeeping maintained by
    /// `applyCpr`/`setAnchorRow` and exposed via `anchorRow` so apps can
    /// place absolute-row content (kitty graphics) at band rows.
    anchor_row: u16 = 0,
    /// Highest row index ever emitted since the last clear; the shrink
    /// path erases stale rows between the content end and this mark.
    high_water: u16 = 0,
    /// A CPR re-query is due at the next render start (first render,
    /// resize, reanchor, or a text-item append flush).
    anchor_dirty: bool = true,
    /// A width change / forced full redraw (strategy 2) is due.
    width_dirty: bool = false,
    /// A height-only change is pending (the height_dirty strategy is due).
    height_dirty: bool = false,
    /// Rows added by the last setHeight (0 unless growing); reserved + diffed
    /// on the next frame.
    grow_rows: u16 = 0,
    /// Rows removed by the last setHeight (0 unless shrinking); erased on the
    /// next frame.
    shrink_rows: u16 = 0,
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
        self.* = undefined;
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

    /// Height-only resize. Reallocs both buffers to `new_height` keeping the
    /// current width, and marks the next frame for a height change. Unlike
    /// `resize`, does NOT set `width_dirty`: the width is unchanged, so there
    /// is no `ESC[J` width-clear. Growth reserves the extra rows below the band
    /// (CNL) and paints them via the normal diff (they are empty in `prev`);
    /// shrink erases the removed tail rows row by row (`eraseLine` — the
    /// self-scoped alternative the requirement allows, never wiping content
    /// below the band) and corrects the anchor (see the `height_dirty`
    /// strategy in render). No-op when `new_height` is the current height.
    /// Call this OR `resize` in a frame gap — not both.
    pub fn setHeight(self: *Region, new_height: u16) !void {
        const old_height = self.height;
        if (new_height == old_height) return;
        try self.cur.resize(self.width, new_height);
        try self.prev.resize(self.width, new_height);
        self.height = new_height;
        self.height_dirty = true;
        // Delta bookkeeping consumed by the height_dirty strategy in render.
        self.grow_rows = if (new_height > old_height) new_height - old_height else 0;
        self.shrink_rows = if (new_height < old_height) old_height - new_height else 0;
        // Bookkeeping only (anchor_row is never used for positioning); keep it
        // tracking the reserved band height across grow/shrink cycles.
        if (new_height > old_height) {
            self.anchor_row +|= new_height - old_height;
        } else {
            self.anchor_row -|= old_height - new_height;
        }
        // On grow the diff will paint the new rows (they are empty in prev);
        // raise the high-water mark so a later shrink erases them correctly.
        if (new_height > old_height) self.high_water = new_height;
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
    /// (the reply surfaces as `Event.cpr` for the app — see
    /// `applyCpr`).
    pub fn reanchor(self: *Region) !void {
        self.anchor_dirty = true;
    }

    /// Apply a Cursor Position Report (CPR) reply, correcting the
    /// bookkeeping `anchor_row` from the terminal's answer to the last
    /// `queryCursor` (emitted at the start of every `anchor_dirty`
    /// frame). Between frames the cursor sits at the band bottom —
    /// column 1 of the last row (every painter parks with `\r` + `\n`
    /// walks) — so the reply's 1-indexed row IS that bottom row and
    /// the band top is `height - 1` rows above it:
    /// `anchor_row = row -| (height - 1)`, clamped to 0. `col` is
    /// ignored: the parking is always column 1.
    ///
    /// The reply is asynchronous — if it lands while a frame is
    /// mid-render (first frame, resize, append flush) it describes the
    /// pre-render cursor, so the correction applies at the next frame.
    /// Painting is cursor-relative (`moveToBandTop` + CUU), so the next
    /// render's diff repaints at the corrected rows with no forced full
    /// redraw. Clears `anchor_dirty` (the query was answered).
    pub fn applyCpr(self: *Region, row: u16, col: u16) !void {
        _ = col;
        self.anchor_row = row -| (self.height -| 1);
        self.anchor_dirty = false;
    }

    /// The tracked absolute terminal row of the band top (1-indexed,
    /// DEC CPR convention; 0 until the first CPR reply anchors it).
    /// Apps place absolute-row content — kitty graphics — at
    /// `anchorRow() + <band row>`.
    pub fn anchorRow(self: *const Region) u16 {
        return self.anchor_row;
    }

    /// DIRECT top-based anchor set: records `row` as the band top.
    /// Complements `applyCpr` (bottom-based, steady-state). The FIRST
    /// CPR reply answers the query emitted at the first render start,
    /// BEFORE the first paint — the cursor then sits at the band's
    /// future top, so the reply's 1-indexed row IS the band top and
    /// needs no height correction. Later replies are steady-state (the
    /// cursor parks at the band bottom after every frame) and go to
    /// `applyCpr`.
    ///
    /// Leaves `anchor_dirty` untouched: the render already cleared it
    /// when it emitted the query, and the caller consumes this reply
    /// immediately after. If a re-query is due anyway, the next reply
    /// is steady-state and belongs to `applyCpr`.
    pub fn setAnchorRow(self: *Region, row: u16) void {
        self.anchor_row = row;
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
            var tracked: Style = .{};
            for (0..self.height) |y| {
                if (y > 0) try w.writeByte('\n');
                try self.writeRow(w, y, &tracked, true);
            }
            if (!tracked.eql(Style{})) try w.writeAll(emit.reset);
            try w.writeByte('\n');
            return;
        }

        const cpr = self.anchor_dirty;
        const flush = self.append_queue.items.len > 0;
        const diff = self.scanChanges();
        const changed = self.first_frame or self.width_dirty or
            self.height_dirty or flush or (diff != null);
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
            self.height_dirty = false;
            self.grow_rows = 0;
            self.shrink_rows = 0;
            if (flush) try self.flushAtCursor(w);
            try self.paintFirst(w);
        } else if (self.height_dirty) {
            // Strategy "height": a height-only change. No width-clear.
            self.height_dirty = false;
            const grow = self.grow_rows;
            const shrink = self.shrink_rows;
            self.grow_rows = 0;
            self.shrink_rows = 0;

            if (grow > 0) {
                // Reserve the extra rows below the band (CNL), then paint
                // them via the normal diff (they are empty in prev).
                // Cursor: old band bottom -> new band bottom after CNL;
                // renderDiffFrame's moveToBandTop (CUU new-1) climbs to
                // row 0.
                if (self.opts.append_lines) try emit.appendLines(w, grow);
                self.high_water = self.height;
            } else {
                // Shrink. The cursor sits at the OLD band bottom (row
                // `shrink` below the new bottom) and the removed rows
                // [new..old) are still on screen. Walk back up through
                // them erasing each row with `eraseLine` (self-scoped —
                // ESC[K touches only the current row, never content below
                // the band; the tmux/column-1 discipline), then climb to
                // the new band bottom so the diff below starts at the
                // correct anchor.
                try w.writeAll("\r");
                var erased: u16 = 0;
                while (erased < shrink) : (erased += 1) {
                    try emit.eraseLine(w);
                    if (erased + 1 < shrink) try w.writeAll("\x1b[1A");
                }
                try w.writeAll("\r");
                try w.writeAll("\x1b[1A"); // first removed row -> new band bottom
                self.high_water = self.height;
            }

            // The band rows [0..new) are unchanged in content (grow keeps
            // them; shrink erased only the removed tail), so diff the
            // changed rows against prev. renderDiffFrame re-establishes
            // the anchor (moveToBandTop) and returns the cursor to the
            // band bottom.
            if (diff) |ch| {
                try self.renderDiffFrame(w, ch);
            } else {
                // Reserve/erase-only frame (no row changed): the pre-step
                // above already left the cursor at the new band bottom
                // (column 1 of the last row); return to column 1 to close
                // the frame.
                try w.writeAll("\r");
            }
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

    // ── frame painters ──────────────────────────────

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

        var tracked: Style = .{};
        for (0..self.height) |y| {
            // Row 0: column 1 regardless of where the app left the
            // cursor (after appendLines the CNL already lands on column
            // 1; `\r` is then redundant but harmless). Rows 1+: `\r\n`.
            if (y > 0) {
                try w.writeAll("\r\n");
            } else {
                try w.writeAll("\r");
            }
            try self.writeRow(w, y, &tracked, false);
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

    // ── append flush ───────────────────────────────

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

    // ── diff bookkeeping ─────────────────────────────

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

    // ── row emission ───────────────────────────────

    /// Write one row's cells (entry: cursor at column 1 of the row).
    /// Mirrors `Buffer.writeRow`: wide continuations never emit text
    /// (their column was covered by the lead's write); SGR is written
    /// only on style change (libvaxis DAM pattern). Interactive rows
    /// (`plain = false`) skip blank cells — the row's erase or the next
    /// cell's CUF covers the gap — while plain (non-TTY) rows write
    /// literal spaces: a pipe has no cursor state for CUF to move, so
    /// skipped blanks would vanish from the byte stream (raw `ESC[n C`
    /// garbage instead of the spaces). Used by the non-clearing
    /// strategy-1 / non-TTY paths — `renderDiff` and `renderAll` own
    /// the erasing paths.
    fn writeRow(self: *const Region, w: anytype, y: usize, tracked: *Style, plain: bool) !void {
        var x: usize = 0;
        var phys_col: usize = 0; // terminal cursor column, 0-indexed
        while (x < self.cur.width) {
            const cell = self.cur.get(@intCast(x), @intCast(y));

            // Wide continuations never emit text; their column was
            // covered by the lead's write (which advances 2).
            if (cell.wide) {
                x += 1;
                continue;
            }
            // Blank cells (default `Cell{}` carries a " " grapheme, and
            // empty-grapheme cells are blank too). Interactive rows skip
            // them; plain rows write the space byte — a pipe has no
            // cursor state for CUF to skip over, so the blanks would
            // otherwise vanish from the output.
            if (cell.grapheme.len == 0 or cell.eql(Cell{})) {
                if (plain) {
                    try w.writeByte(' ');
                    phys_col += 1;
                }
                x += 1;
                continue;
            }

            const wg = Width.graphemeWidth(cell.grapheme);
            const wcell: usize = if (wg >= 2) 2 else 1;
            // A wide glyph at the last column has no continuation cell;
            // drop it (graceful — over-wide never errors, plan §0). A
            // plain row still reserves the column as a space so the
            // byte stream stays width-aligned.
            if (x + wcell > self.cur.width) {
                if (plain) {
                    try w.writeByte(' ');
                    phys_col += 1;
                }
                x += 1;
                continue;
            }

            // CUF is an interactive-only cursor move — it presumes live
            // terminal state, which a pipe lacks (and the space writes
            // above keep `phys_col == x`, so no gap exists to skip).
            if (!plain and x > phys_col) try w.print("\x1b[{d}C", .{x - phys_col});
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

// ── T5.1 skeleton ────────────────────────────────

test "region: init/deinit leak nothing, queue frees with items" {
    var r = try Region.init(std.testing.allocator, .{ .height = 3 });
    defer r.deinit();
    try r.append(.{ .text = "one" });
    try r.append(.{ .line = "two" });
    try r.append(.{ .line = "three" });
}

test "region: Options defaults" {
    const o: Region.Options = .{ .height = 3 };
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

    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    // Line item flushed verbatim at the cursor (first frame: no move, no
    // ESC[J — nothing rendered yet), then strategy 1 appends the rows.
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\x1b[6nL\r\n\x1b[?25l\rab\r\ncd\r\x1b[?2026l",
        t.w.buffered(),
    );
}

// ── T5.2 strategies 1 + 3 ─────────────────────────────

test "region: first render appends height lines without clearing" {
    var r = try makeRegion(2, true, true);
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");

    var t: TestWriter = .{};
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

    var t: TestWriter = .{};
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

    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\x1b[6n\x1b[?25l\raaa\r\nbbb\r\nccc\r\x1b[?2026l",
        t1.w.buffered(),
    );

    // Frame 2: only row 1 changes.
    try clearRow(&r.cur, 1, 3);
    try drawRow(&r.cur, 1, "BB");
    var t2: TestWriter = .{};
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

    var t1: TestWriter = .{};
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
    var t2: TestWriter = .{};
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

    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try std.testing.expectEqualStrings("", t2.w.buffered());
}

test "region: sync_output off emits one plain unwrapped frame" {
    var r = try makeRegion(2, false, true);
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");

    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    // No sync, no CPR, no hide, no CNL reservation — plain rows only.
    // Blank cells are written as spaces (a pipe has no cursor state for
    // CUF), so each row is the full buffer width.
    try std.testing.expectEqualStrings(
        "ab" ++ " " ** 78 ++ "\n" ++ "cd" ++ " " ** 78 ++ "\n",
        t.w.buffered(),
    );
}

test "region: wide glyph row diff never emits the continuation" {
    var r = try makeRegion(1, true, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "a👨‍🌾b");

    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\x1b[6n\x1b[?25l\ra👨‍🌾b\r\x1b[?2026l",
        t1.w.buffered(),
    );

    try clearRow(&r.cur, 0, 5);
    try drawRow(&r.cur, 0, "a👨‍🌾c");
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    // The continuation cell (column 2) emits nothing: the glyph appears
    // exactly once.
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\r\r\x1b[Ka👨‍🌾c\r\x1b[?2026l",
        t2.w.buffered(),
    );
}

// ── T5.3 strategy 2 ───────────────────────────────

test "region: resize emits ESC[J then re-renders every row, never more than height" {
    var r = try makeRegion(3, true, false);
    defer r.deinit();
    try r.resize(20, 3);
    try drawRow(&r.cur, 0, &([_]u8{'a'} ** 20));
    try drawRow(&r.cur, 1, &([_]u8{'b'} ** 20));
    try drawRow(&r.cur, 2, &([_]u8{'c'} ** 20));

    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\x1b[6n\x1b[?25l\r" ++ ("a" ** 20) ++ "\r\n" ++ ("b" ** 20) ++
            "\r\n" ++ ("c" ** 20) ++ "\r\x1b[?2026l",
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
    var t2: TestWriter = .{};
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
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    try r.resize(30, 4);
    try drawRow(&r.cur, 2, "ef");
    try drawRow(&r.cur, 3, "gh");
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, t2.w.buffered(), "\x1b[K"));

    try r.resize(30, 1);
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, t3.w.buffered(), "\x1b[K"));
}

test "region: width_dirty clears after the strategy-2 render" {
    var r = try makeRegion(2, true, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    try r.resize(40, 2);
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try std.testing.expect(!r.width_dirty);

    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    try std.testing.expectEqualStrings("", t3.w.buffered());
}

test "region: consecutive resizes each trigger a full redraw" {
    var r = try makeRegion(2, true, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    var t0: TestWriter = .{};
    t0.init();
    try r.render(&t0.w);

    try r.resize(10, 2);
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    try std.testing.expect(std.mem.indexOf(u8, t1.w.buffered(), "\x1b[J") != null);

    try r.resize(20, 2);
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try std.testing.expect(std.mem.indexOf(u8, t2.w.buffered(), "\x1b[J") != null);

    try r.resize(20, 3);
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    try std.testing.expect(std.mem.indexOf(u8, t3.w.buffered(), "\x1b[J") != null);
}

// ── T5.4 append queue ──────────────────────────────

test "region: queued text flushes before the region rows" {
    var r = try makeRegion(2, true, false);
    defer r.deinit();
    try r.append(.{ .text = "hi" });
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");

    var t: TestWriter = .{};
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
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    try r.append(.{ .text = "a\nb" });
    var t2: TestWriter = .{};
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
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    try r.append(.{ .line = "exact-line" });
    var t2: TestWriter = .{};
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
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    try std.testing.expectEqual(@as(u16, 0), r.anchor_row);

    try r.append(.{ .line = "one" });
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try std.testing.expectEqual(@as(u16, 1), r.anchor_row);

    try r.append(.{ .line = "two" });
    try r.append(.{ .line = "three" });
    var t3: TestWriter = .{};
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
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    // A normal diff frame with no pending appends: no ESC[J, no flush
    // bytes — the strategy-3 path only.
    try clearRow(&r.cur, 0, 3);
    try drawRow(&r.cur, 0, "aa");
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\r\x1b[2A\r\x1b[Kaa\r\n\n\x1b[?2026l",
        t2.w.buffered(),
    );
    try std.testing.expectEqual(@as(usize, 0), r.append_queue.items.len);
}

// ── T5.5 reanchor + CPR ──────────────────────────────

test "region: CPR on first render and resize, never in steady state" {
    var r = try makeRegion(2, true, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");

    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    try std.testing.expect(std.mem.indexOf(u8, t1.w.buffered(), "\x1b[6n") != null);

    // Steady state: changed frames carry no CPR query.
    try clearRow(&r.cur, 0, 2);
    try drawRow(&r.cur, 0, "aa");
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try std.testing.expect(std.mem.indexOf(u8, t2.w.buffered(), "\x1b[6n") == null);

    try clearRow(&r.cur, 1, 2);
    try drawRow(&r.cur, 1, "dd");
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    try std.testing.expect(std.mem.indexOf(u8, t3.w.buffered(), "\x1b[6n") == null);

    // Resize re-queries (the strategy-2 golden in the T5.3 tests also
    // carries `\x1b[6n` after the first frame's).
    try r.resize(30, 2);
    var t4: TestWriter = .{};
    t4.init();
    try r.render(&t4.w);
    try std.testing.expect(std.mem.indexOf(u8, t4.w.buffered(), "\x1b[6n") != null);
}

test "region: reanchor() re-queries on the next render" {
    var r = try makeRegion(2, true, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w); // idle: zero bytes
    try std.testing.expectEqualStrings("", t2.w.buffered());

    try r.reanchor();
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    // An idle frame with a pending re-anchor emits the CPR query only.
    try std.testing.expectEqualStrings("\x1b[?2026h\x1b[6n\x1b[?2026l", t3.w.buffered());
}

test "region: applyCpr corrects anchor_row from the reply" {
    var r = try makeRegion(3, true, false);
    defer r.deinit();
    // Cursor parked at the band bottom, 1-indexed row 12; the band top
    // is height - 1 rows above it: 12 - (3-1) = 10.
    r.anchor_row = 10;
    try r.applyCpr(12, 1);
    try std.testing.expectEqual(@as(u16, 10), r.anchor_row);
}

test "region: applyCpr clamps the anchor to 0" {
    var r = try makeRegion(3, true, false);
    defer r.deinit();
    // A reply above the band height saturates the subtraction to 0.
    try r.applyCpr(1, 1);
    try std.testing.expectEqual(@as(u16, 0), r.anchor_row);
    try r.applyCpr(2, 1);
    try std.testing.expectEqual(@as(u16, 0), r.anchor_row);
    // A single-row band anchors exactly at the reply row.
    var r1 = try makeRegion(1, true, false);
    defer r1.deinit();
    try r1.applyCpr(7, 1);
    try std.testing.expectEqual(@as(u16, 7), r1.anchor_row);
}

test "region: applyCpr clears anchor_dirty (the query was answered)" {
    var r = try makeRegion(2, true, false);
    defer r.deinit();
    r.anchor_dirty = true;
    try r.applyCpr(4, 1);
    try std.testing.expect(!r.anchor_dirty);
}

test "region: anchorRow exposes the tracked band top" {
    var r = try makeRegion(3, true, false);
    defer r.deinit();
    // Unanchored before the first CPR reply.
    try std.testing.expectEqual(@as(u16, 0), r.anchorRow());
    r.anchor_row = 10;
    try std.testing.expectEqual(@as(u16, 10), r.anchorRow());
}

test "region: setAnchorRow records the first-reply band top directly" {
    var r = try makeRegion(3, true, false);
    defer r.deinit();
    // The FIRST reply answers the query emitted before the first paint,
    // when the cursor sat at the band's future top: the 1-indexed reply
    // row IS the band top, no height correction (applyCpr's bottom-based
    // formula would be wrong here).
    r.setAnchorRow(7);
    try std.testing.expectEqual(@as(u16, 7), r.anchorRow());
    // anchor_dirty is left as-is: the render cleared it when it emitted
    // the query; the caller consumes this reply right after. The two
    // formulas agree: height 3, steady-state reply at the band bottom
    // (row 9) corrects to the same 7.
    r.anchor_dirty = true;
    r.setAnchorRow(7);
    try std.testing.expect(r.anchor_dirty);
    try r.applyCpr(9, 1);
    try std.testing.expectEqual(@as(u16, 7), r.anchorRow());
}

test "region: drift corrected by applyCpr; the next diff repaints at the corrected anchor" {
    var r = try makeRegion(3, true, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "aaa");
    try drawRow(&r.cur, 1, "bbb");
    try drawRow(&r.cur, 2, "ccc");
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    // An external fd-1/fd-2 write scrolled the terminal while the region
    // was idle, leaving the bookkeeping stale: the parked cursor (the
    // band bottom) moved from row 15 to row 13. The reanchor's CPR
    // reply reports 13; applyCpr corrects 12 -> 11 (13 - (3-1)).
    r.anchor_row = 12; // stale bookkeeping (the drift, simulated)
    try r.reanchor();
    try r.applyCpr(13, 1);
    try std.testing.expectEqual(@as(u16, 11), r.anchor_row);
    try std.testing.expect(!r.anchor_dirty);

    // The next changed frame emits the same cursor-relative diff an
    // undrifted region would — the repaint targets the corrected band.
    try clearRow(&r.cur, 1, 3);
    try drawRow(&r.cur, 1, "BB");
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\r\x1b[2A\r\n\x1b[KBB\r\n\x1b[?2026l",
        t2.w.buffered(),
    );
}

test "region: no CPR when sync_output is off" {
    var r = try makeRegion(2, false, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    try std.testing.expect(std.mem.indexOf(u8, t.w.buffered(), "\x1b[") == null);
}

// ── T5.6 exit + non-TTY ──────────────────────────────

test "region: exit restores the cursor, closes sync, parks below the band" {
    var r = try makeRegion(2, true, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    var t2: TestWriter = .{};
    t2.init();
    try r.exit(&t2.w);
    try std.testing.expectEqualStrings("\x1b[?25h\x1b[?2026l\r\n\r", t2.w.buffered());
}

test "region: exit is idempotent" {
    var r = try makeRegion(2, true, false);
    defer r.deinit();
    var t1: TestWriter = .{};
    t1.init();
    try r.exit(&t1.w);
    try std.testing.expectEqualStrings("\x1b[?2026l\r\n\r", t1.w.buffered());

    var t2: TestWriter = .{};
    t2.init();
    try r.exit(&t2.w);
    try std.testing.expectEqualStrings("", t2.w.buffered());
}

test "region: piped mode emits one plain frame, no interactive sequences" {
    var r = try makeRegion(2, false, true);
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");

    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    // Blank cells are written as spaces (no CUF in a pipe): each row is
    // the full buffer width.
    try std.testing.expectEqualStrings(
        "ab" ++ " " ** 78 ++ "\n" ++ "cd" ++ " " ** 78 ++ "\n",
        t1.w.buffered(),
    );
    try std.testing.expect(std.mem.indexOf(u8, t1.w.buffered(), "\x1b[") == null);

    // Later frames change nothing in a pipe: no repaint, no erase.
    try clearRow(&r.cur, 0, 2);
    try drawRow(&r.cur, 0, "zz");
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try std.testing.expectEqualStrings("", t2.w.buffered());

    // Exit parks nothing in piped mode.
    var t3: TestWriter = .{};
    t3.init();
    try r.exit(&t3.w);
    try std.testing.expectEqualStrings("", t3.w.buffered());
}

test "region: non-TTY blank cells are written as spaces, never CUF" {
    // P5 bug regression: a blank run between glyphs was skipped with
    // CUF (`ESC[n C`), so piped output carried raw escape garbage
    // instead of the spaces — an interactive-only cursor move a pipe
    // has no cursor state to honor.
    var r = try makeRegion(2, false, true);
    defer r.deinit();
    try drawRow(&r.cur, 0, "a  b");
    // Row 1 stays fully blank (default cells, grapheme " ").

    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    const out = t.w.buffered();

    // No ESC sequences at all: the blanks are literal spaces.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[") == null);
    // The blank run survives as real bytes, not a cursor move.
    try std.testing.expectEqualStrings("a  b", out[0..4]);
    // The fully blank row is the full buffer width of spaces; a pipe
    // must receive the blanks. Layout: row 0 (80 bytes) + '\n' + row 1
    // (80 spaces) + '\n'.
    try std.testing.expectEqual(' ', out[81]);
    try std.testing.expectEqual(' ', out[160]);
    try std.testing.expectEqual('\n', out[161]);
    try std.testing.expectEqual(@as(usize, 162), out.len);

    // The same frame interactive may skip the blanks with CUF — the
    // terminal's erase state covers them; TTY behavior is unchanged.
    var r2 = try makeRegion(2, true, false);
    defer r2.deinit();
    try drawRow(&r2.cur, 0, "a  b");
    var t2: TestWriter = .{};
    t2.init();
    try r2.render(&t2.w);
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\x1b[6n\x1b[?25l\ra\x1b[2Cb\r\n\r\x1b[?2026l",
        t2.w.buffered(),
    );
}

// ── T5.7 setHeight (height-only resize) ──────────────

test "region: setHeight grow reserves with CNL and diffs the new rows, no width-clear" {
    var r = try makeRegion(2, true, true);
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");

    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\x1b[6n\x1b[2E\x1b[?25l\rab\r\ncd\r\x1b[?2026l",
        t1.w.buffered(),
    );

    // One-shot grow 2 -> 4 with two suggestion rows: the frame emits the
    // CNL reservation then a strategy-3 diff of rows 2-3 — no ESC[J
    // anywhere (strategy 2 never runs on a height-only change).
    try r.setHeight(4);
    try drawRow(&r.cur, 2, "ef");
    try drawRow(&r.cur, 3, "gh");
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\x1b[2E\r\x1b[3A\r\n\n\x1b[Kef\r\n\x1b[Kgh\r\x1b[?2026l",
        t2.w.buffered(),
    );
    try std.testing.expect(std.mem.indexOf(u8, t2.w.buffered(), "\x1b[J") == null);
    try std.testing.expect(!r.width_dirty);
}

test "region: setHeight shrink erases the removed tail row by row, then diffs" {
    var r = try makeRegion(5, true, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    try drawRow(&r.cur, 2, "ef");
    try drawRow(&r.cur, 3, "gh");
    try drawRow(&r.cur, 4, "ij");
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\x1b[6n\x1b[?25l\rab\r\ncd\r\nef\r\ngh\r\nij\r\x1b[?2026l",
        t1.w.buffered(),
    );

    // Shrink 5 -> 2: per-row eraseLine walk over the removed rows
    // [2..5) (erase the old band bottom, walk back one row, erase —
    // self-scoped, never ESC[J), then climb to the new band bottom and
    // diff the changed status row.
    try r.setHeight(2);
    try clearRow(&r.cur, 1, 2);
    try drawRow(&r.cur, 1, "XY");
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\r\x1b[K\x1b[1A\x1b[K\x1b[1A\x1b[K\r\x1b[1A\r\x1b[1A\r\n\x1b[KXY\r\x1b[?2026l",
        t2.w.buffered(),
    );
    // 3 row-erases in the walk + 1 for the diffed status row.
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, t2.w.buffered(), "\x1b[K"));
    try std.testing.expect(std.mem.indexOf(u8, t2.w.buffered(), "\x1b[J") == null);
    try std.testing.expect(!r.width_dirty);
}

test "region: setHeight grow-then-shrink round-trip leaves the smaller band" {
    var r = try makeRegion(2, true, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    // Grow to 5 with three suggestion rows, then dismiss back to 2.
    try r.setHeight(5);
    try drawRow(&r.cur, 2, "ef");
    try drawRow(&r.cur, 3, "gh");
    try drawRow(&r.cur, 4, "ij");
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);

    try r.setHeight(2);
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    // The removed rows [2..5) are erased row by row; rows [0..2) are
    // unchanged, so this is an erase-only frame (no diff, no repaint) —
    // exactly the `diff == null` shrink the height_dirty gate exists for.
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\r\x1b[K\x1b[1A\x1b[K\x1b[1A\x1b[K\r\x1b[1A\r\x1b[?2026l",
        t3.w.buffered(),
    );
    try std.testing.expectEqual(@as(u16, 2), r.height);

    // Follow-up idle frame emits nothing.
    var t4: TestWriter = .{};
    t4.init();
    try r.render(&t4.w);
    try std.testing.expectEqualStrings("", t4.w.buffered());
}

test "region: setHeight never clears width; resize still does" {
    var r = try makeRegion(2, true, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    // Grow with no new content: reserve-only frame, still no ESC[J.
    try r.setHeight(3);
    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try std.testing.expect(std.mem.indexOf(u8, t2.w.buffered(), "\x1b[J") == null);
    try std.testing.expect(!r.width_dirty);

    // A real width change keeps its strategy-2 ESC[J + full repaint.
    try r.resize(40, 3);
    var t3: TestWriter = .{};
    t3.init();
    try r.render(&t3.w);
    try std.testing.expect(std.mem.indexOf(u8, t3.w.buffered(), "\x1b[J") != null);
    try std.testing.expect(!r.width_dirty);
}

test "region: setHeight with the same height is a no-op" {
    var r = try makeRegion(2, true, false);
    defer r.deinit();
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    var t1: TestWriter = .{};
    t1.init();
    try r.render(&t1.w);

    try r.setHeight(2);
    try std.testing.expect(!r.height_dirty);
    try std.testing.expectEqual(@as(u16, 0), r.grow_rows);
    try std.testing.expectEqual(@as(u16, 0), r.shrink_rows);

    var t2: TestWriter = .{};
    t2.init();
    try r.render(&t2.w);
    try std.testing.expectEqualStrings("", t2.w.buffered());
}

test "region: setHeight before the first render just sets the initial band" {
    var r = try makeRegion(2, true, true);
    defer r.deinit();
    try r.setHeight(4);
    try std.testing.expect(r.height_dirty);
    try drawRow(&r.cur, 0, "ab");
    try drawRow(&r.cur, 1, "cd");
    try drawRow(&r.cur, 2, "ef");
    try drawRow(&r.cur, 3, "gh");

    var t: TestWriter = .{};
    t.init();
    try r.render(&t.w);
    // First-frame path wins: paintFirst appends all 4 rows; the
    // height_dirty flags are cleared and no grow reservation runs
    // (nothing was on screen).
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\x1b[6n\x1b[4E\x1b[?25l\rab\r\ncd\r\nef\r\ngh\r\x1b[?2026l",
        t.w.buffered(),
    );
    try std.testing.expect(!r.height_dirty);
    try std.testing.expectEqual(@as(u16, 0), r.grow_rows);
}
