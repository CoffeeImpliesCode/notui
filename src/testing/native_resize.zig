//! An independent reflowing terminal model, and the consumer regressions
//! that drive the real `Region` into it.
//!
//! Native opt-in declares non-cursor reflow, exact scrollback capacity,
//! a transcript-tail band, and source-preserving oldest-row-only eviction.
//! The user approved the last requirement after installed xterm was shown
//! to corrupt later committed rows during capped width reflow.
//! This model implements the conforming contract, not that xterm defect.
//! Safe installed-xterm readings ground packing, cursor and NULL rules:
//!
//! - `bounded-scrollback-reflow-alignment-probe.json` — 131 columns of
//!   55 ASCII plus 38 width-two glyphs repack to 55/54/22 at 55 columns;
//!   capacity 100 drops the ASCII head, capacity 200 keeps it, and the
//!   surviving prefix is 33 rows at width 3 or 23 depending on which.
//! - `native-null-offset-controlled-probe.json` — the controlled reading
//!   that settles NULL handling: one glyph behind 100 and 130 columns of
//!   CUF are 2 and 3 chunks at 55, and after the visible glyph chunk is
//!   erased the survivors are 1 and 19 rows at width 3, 1 and 1 at 66,
//!   1 and 1 back at 3.
//! - `null-gap-prefix-trim-probe.json` and
//!   `multichunk-null-prefix-trim-probe.json` — the same shape read the
//!   other way round: a group that painted NOTHING reflows to one row
//!   while its printed twin needs nineteen.
//! - `cursor-group-exemption-not-screen-row-probe.json` — a cursor group
//!   that is exempt is not a cursor screen row that stays put.
//! - `full-line-erase-wrap-boundary-probe.json` — EL2 clears `isWrapped`.
//! - `undeclared-tail-information-probe.json` — the same geometry and the
//!   same three CPR replies retain different prefixes depending on rows
//!   below the band that this Region never wrote.
//!
//! The model derives its cells, its chunks and its trim points from the
//! bytes the Region actually emitted. It never calls
//! `Buffer.rowFootprint`, `Region.rowsAt` or any other producer
//! arithmetic: those are the thing under test, and a model built out of
//! them could only ever agree with them.
//!
//! ## What the model implements
//!
//! Printed: CR, LF, BS, TAB, UTF-8 text, CUU/CUD/CUF/CUB, CNL, CPL, CHA,
//! CUP, ED 0/1/2, EL 0/1/2, SGR (parsed, no visual effect), DSR (parsed,
//! never answered by the terminal itself), DEC private set/reset for
//! `?7` (DECAWM) with `?25`/`?2026`/`?1049` parsed and ignored, OSC/APC/
//! DCS skipped to their string terminator, and `CSI 6 n`, whose reply is
//! queued for the harness to route back through `Region.applyCpr`.
//!
//! Character vocabulary: ASCII is one cell wide; CJK, Hangul, fullwidth
//! forms and the CJK compatibility blocks are two; combining marks are
//! zero; anything else is one. Fixtures use ASCII and `界`, and the model
//! says so instead of pretending to be a complete VT emulator.
//!
//! Reflow on a width change, for a hard group (a run of rows joined by
//! `isWrapped`) the cursor is not inside:
//!
//!   - every non-final row contributes its full physical width except a
//!     one-cell no-fit pad before the next row's leading wide glyph;
//!     only the final row trims trailing NULLs. Printed spaces are content;
//!   - cells are placed POSITIONALLY into `new_cols`-wide rows — a NULL
//!     cell keeps its column — and a width-2 glyph that does not fit in
//!     what is left of a row starts the next one, so a row can end early
//!     and the padding that leaves is not source. An orphaned
//!     continuation is dropped;
//!   - the first chunk is a hard row and the rest are continuations;
//!   - expansion consumes unused terminal-generated hard blank tail rows
//!     before source-preserving front eviction removes the oldest chunks;
//!   - the cursor's own line index follows the rows the groups above it
//!     gained or lost, and only `ybase` moves with it.
//!
//! The measured non-corrupting sequences agree with these packing rules:
//! controlled NULL offsets included: 130 NULL columns ahead of one glyph
//! are three chunks at 55 and, after the glyph chunk is erased, two
//! all-NULL chunks worth 55 logical columns — 19 rows at width 3, one at
//! 66, one again at 3 — while 100 NULL columns leave one all-NULL chunk
//! worth nothing and therefore a single row.
//!
//! Two limits are real, and the tests stay inside them:
//!
//! 1. Anything below the parked band that this Region never wrote. The
//!    fixtures keep the rows below the band blank, including mid-window
//!    rows the band never used, because that is the case whose invariant
//!    the evidence supports; the sentinel rows a test protects sit ABOVE
//!    the band, which is the Region's own. No test claims an erase over
//!    unowned content is safe.
//! 2. Unused means terminal-generated padding, not rows left behind by
//!    cursor traversal, erasure or foreign writes. Width expansion consumes
//!    this tail; viewport adjustment runs before reflow, as Buffer.resize
//!    does. The buffer is then padded back to the visible height.
//!
//! What the model also reproduces exactly, because it is measured and
//! unambiguous: a scroll past the declared capacity drops the OLDEST
//! row; a row growth pulls one row back from scrollback per added row
//! while the cursor's absolute line holds, then pads with fresh blank
//! rows; a row shrink pops from the end while the cursor allows.

const std = @import("std");

const Allocator = std.mem.Allocator;

const Region = @import("../region.zig").Region;
const ResizeMode = @import("../region.zig").ResizeMode;
const HistoryBatch = @import("../region.zig").HistoryBatch;
const Style = @import("../style.zig").Style;

const testing = std.testing;

// Cells.

/// One terminal cell. A cell nothing ever wrote is NOT a space: it is
/// the terminal's NULL cell, and telling the two apart is most of what a
/// committed row's logical footprint is made of — a printed space stays
/// occupied through an erase and a later reflow, a NULL cell does not.
const Cell = struct {
    code: u21 = 0,
    kind: enum(u8) { none, glyph, wide, tail } = .none,

    /// Columns this cell and its continuation occupy.
    fn columns(self: Cell) usize {
        return if (self.kind == .wide) 2 else 1;
    }
};

const Line = struct {
    cells: std.ArrayList(Cell) = .empty,
    /// True when this row is a soft-wrap continuation of the row above.
    wrapped: bool = false,

    /// Columns past the last cell carrying anything: 0 for a row that was
    /// erased, never written, or holds only NULL cells.
    fn painted(self: Line) usize {
        var n = self.cells.items.len;
        while (n > 0) {
            n -= 1;
            if (self.cells.items[n].kind != .none) return n + 1;
        }
        return 0;
    }
};

/// A CPR reply, in the bytes a terminal actually sends.
const Reply = struct { row: u16, col: u16 };

/// Display width of one code point over the vocabulary declared above.
fn cellWidth(cp: u21) u8 {
    if (cp < 0x300) return 1; // ASCII, Latin-1, Latin Extended
    if (cp <= 0x36f) return 0; // combining marks
    if (cp >= 0x1100 and cp <= 0x115f) return 2; // Hangul Jamo
    if (cp >= 0x2e80 and cp <= 0xa4cf) return 2; // CJK .. Yi
    if (cp >= 0xac00 and cp <= 0xd7a3) return 2; // Hangul syllables
    if (cp >= 0xf900 and cp <= 0xfaff) return 2; // CJK compatibility
    if (cp >= 0xfe30 and cp <= 0xfe6f) return 2; // compatibility forms
    if (cp >= 0xff00 and cp <= 0xff60) return 2; // fullwidth forms
    if (cp >= 0xffe0 and cp <= 0xffe6) return 2; // fullwidth signs
    if (cp >= 0x20000 and cp <= 0x3fffd) return 2; // CJK extensions
    return 1;
}

// The terminal.

const Model = struct {
    gpa: Allocator,
    lines: std.ArrayList(Line) = .empty,
    cols: usize = 80,
    rows: usize = 24,
    scrollback: usize = 0,
    /// Index of the first row the window shows.
    ybase: usize = 0,
    /// Cursor row inside the window, 0-based (xterm's `y`).
    y: usize = 0,
    /// Cursor column, which may equal `cols` in the deferred-wrap state.
    x: usize = 0,
    autowrap: bool = true,

    replies: std.ArrayList(Reply) = .empty,

    st: enum { ground, esc, csi, string } = .ground,
    params: [8]u16 = [_]u16{0} ** 8,
    seen: usize = 0,
    cur: usize = 0,
    priv: bool = false,
    pend: [4]u8 = undefined,
    pend_len: usize = 0,
    pend_need: usize = 1,

    fn init(gpa: Allocator, cols: u16, rows: u16, scrollback: u32) !Model {
        std.debug.assert(cols >= 2);
        std.debug.assert(rows >= 1);
        var self: Model = .{
            .gpa = gpa,
            .cols = cols,
            .rows = rows,
            .scrollback = scrollback,
        };
        errdefer self.deinit();
        // A fresh terminal already shows a full screen of blank rows.
        while (self.lines.items.len < self.rows) try self.appendLine();
        return self;
    }

    fn deinit(self: *Model) void {
        for (self.lines.items) |*l| l.cells.deinit(self.gpa);
        self.lines.deinit(self.gpa);
        self.replies.deinit(self.gpa);
        self.* = undefined;
    }

    /// Rows the buffer may hold: the declared scrollback plus the screen.
    /// Saturates: a 32-bit `usize` cannot hold `maxInt(u32)` plus the rows.
    fn capacity(self: *const Model) usize {
        return @as(usize, self.scrollback) +| self.rows;
    }

    /// Highest row the window may start on while still showing `rows`.
    fn backstop(self: *const Model) usize {
        if (self.lines.items.len <= self.rows) return 0;
        return self.lines.items.len - self.rows;
    }

    /// The cursor's row inside the window, 1-based: what `CSI 6 n`
    /// answers and what a band anchor is derived from. NOT its absolute
    /// buffer index — `ybase` moves under the window.
    fn cursorRow(self: *const Model) u16 {
        return @intCast(@min(self.y, self.rows - 1) + 1);
    }

    fn lineCount(self: *const Model) usize {
        return self.lines.items.len;
    }

    fn takeReply(self: *Model) ?Reply {
        if (self.replies.items.len == 0) return null;
        return self.replies.orderedRemove(0);
    }

    fn cells(self: *const Model, index: usize) []const Cell {
        return self.lines.items[index].cells.items;
    }

    fn painted(self: *const Model, index: usize) usize {
        return self.lines.items[index].painted();
    }

    fn isWrapped(self: *const Model, index: usize) bool {
        return self.lines.items[index].wrapped;
    }

    fn feed(self: *Model, bytes: []const u8) !void {
        for (bytes) |b| try self.byte(b);
    }

    // Observation.

    /// Append the PRINTED content of row `index`: a NULL cell contributes
    /// nothing, so a printed space and a gap stay distinguishable.
    fn writeText(self: *const Model, index: usize, out: *std.ArrayList(u8)) !void {
        var buf: [4]u8 = undefined;
        for (self.lines.items[index].cells.items) |c| {
            if (c.kind == .none or c.kind == .tail) continue;
            const n = std.unicode.utf8Encode(c.code, &buf) catch continue;
            try out.appendSlice(self.gpa, buf[0..n]);
        }
    }

    /// One past the last row of the hard group that starts at `first`.
    fn groupEnd(self: *const Model, first: usize) usize {
        var end = first + 1;
        while (end < self.lines.items.len and self.lines.items[end].wrapped) : (end += 1) {}
        return end;
    }

    /// The printed content of the whole hard group that starts at
    /// `first`, joined as one logical row: what a reader sees of that
    /// piece of output however many physical rows it occupies now.
    fn writeGroup(self: *const Model, first: usize, out: *std.ArrayList(u8)) !void {
        const end = self.groupEnd(first);
        for (first..end) |i| try self.writeText(i, out);
    }

    fn groupRows(self: *const Model, first: usize) usize {
        return self.groupEnd(first) - first;
    }

    /// The window row a buffer row is shown on, 1-based, which is what
    /// CUP takes.
    fn screenRow(self: *const Model, index: usize) usize {
        return index - self.ybase + 1;
    }

    // Geometry.

    /// Apply a window geometry change the way the measured terminal does:
    /// the row count, then the front trim, then the reflow, then the new
    /// width on every row. The cursor's line survives all of it.
    fn resize(self: *Model, cols: u16, rows: u16) !void {
        std.debug.assert(cols >= 2);
        std.debug.assert(rows >= 1);
        const new_cols: usize = cols;
        const new_rows: usize = rows;
        if (new_cols == self.cols and new_rows == self.rows) return;
        const old_cols = self.cols;
        if (new_rows != self.rows) {
            try self.resizeRows(new_rows);
            self.trimFront();
        }
        if (new_cols != old_cols) {
            const cursor_new = try self.reflow(new_cols, self.ybase + self.y);
            // Growth uses unused tail before moving the viewport; widening
            // pulls history first and pads below only after reaching its head.
            const want = cursor_new -| self.y;
            self.ybase = @min(want, self.backstop());
            self.y = @min(cursor_new -| self.ybase, self.rows - 1);
        }
        for (self.lines.items) |*l| {
            const old_len = l.cells.items.len;
            try l.cells.resize(self.gpa, new_cols);
            if (new_cols > old_len) {
                for (l.cells.items[old_len..]) |*c| c.* = .{};
            } else if (l.cells.items[new_cols - 1].kind == .wide) {
                l.cells.items[new_cols - 1] = .{};
            }
        }
        self.cols = new_cols;
        self.x = @min(self.x, new_cols - 1);
        while (self.lines.items.len < self.ybase + self.rows) try self.appendLine();
    }

    /// Add and remove rows: pull one back from scrollback per added row
    /// while the cursor's absolute line still leaves room, then pad with
    /// fresh blank rows; pop from the end while the cursor allows.
    fn resizeRows(self: *Model, rows: usize) !void {
        var old = self.rows;
        var pulled: usize = 0;
        while (rows > old) : (old += 1) {
            if (self.lines.items.len >= rows + self.ybase) continue;
            if (self.ybase > 0 and
                self.lines.items.len <= self.ybase + self.y + pulled + 1)
            {
                self.ybase -= 1;
                pulled += 1;
            } else {
                try self.appendLine();
            }
        }
        while (rows < old) : (old -= 1) {
            if (self.lines.items.len <= rows + self.ybase) continue;
            if (self.lines.items.len > self.ybase + self.y + 1) {
                var l = self.lines.pop().?;
                l.cells.deinit(self.gpa);
            } else {
                self.ybase += 1;
            }
        }
        self.rows = rows;
        self.y = @min(self.y, rows - 1) + pulled;
    }

    /// Drop the oldest rows the declared capacity no longer holds. This
    /// is the irreversible loss; a taller window cannot give them back.
    ///
    /// The cursor being on the last row is the ORDINARY case for a full
    /// buffer, not a reason to keep the oldest row: the window moves down
    /// with the drop while it can, and the cursor's own row index moves
    /// once the window is already at the top.
    fn trimFront(self: *Model) void {
        while (self.lines.items.len > self.capacity()) {
            var l = self.lines.orderedRemove(0);
            l.cells.deinit(self.gpa);
            if (self.ybase > 0) {
                self.ybase -= 1;
            } else if (self.y > 0) {
                self.y -= 1;
            }
        }
    }

    /// Repack every hard group the cursor is not inside, and report where
    /// the cursor's own line ended up.
    ///
    /// The entire group is packed before retention removes oldest chunks.
    /// Never cap a group's FIRST chunks: that invents a different source.
    fn reflow(self: *Model, new_cols: usize, cursor_old: usize) !usize {
        var out: std.ArrayList(Line) = .empty;
        errdefer {
            for (out.items) |*l| l.cells.deinit(self.gpa);
            out.deinit(self.gpa);
        }
        try out.ensureTotalCapacity(self.gpa, self.lines.items.len);

        const cap = self.capacity();
        var cursor_new: usize = cursor_old;
        var i: usize = 0;
        while (i < self.lines.items.len) {
            var end = i + 1;
            while (end < self.lines.items.len and self.lines.items[end].wrapped) : (end += 1) {}
            const before = out.items.len;
            const single = end == i + 1;
            const already_fits = single and self.lines.items[i].painted() <= new_cols;
            const in_cursor_group = cursor_old >= i and cursor_old < end;
            if (in_cursor_group or already_fits) {
                try out.ensureUnusedCapacity(self.gpa, end - i);
                for (self.lines.items[i..end]) |*l| {
                    out.appendAssumeCapacity(l.*);
                    l.cells = .empty; // ownership moved into `out`
                }
            } else {
                try self.repack(&out, i, end, new_cols);
                for (self.lines.items[i..end]) |*l| l.cells.deinit(self.gpa);
            }
            // A group entirely above the cursor's line moved the cursor's
            // line by exactly what it gained or lost.
            if (cursor_old >= end) {
                const grew: isize = @as(isize, @intCast(out.items.len - before)) -
                    @as(isize, @intCast(end - i));
                cursor_new = @intCast(@as(isize, @intCast(cursor_new)) + grew);
            }
            i = end;
        }
        // The profile's unused hard tail is padding, not transcript data.
        // Expansion consumes it before any source rows can be evicted.
        var growth = cursor_new -| cursor_old;
        while (growth > 0 and out.items.len > cursor_new + 1) : (growth -= 1) {
            const last = out.items[out.items.len - 1];
            if (last.wrapped or last.painted() != 0) break;
            var l = out.pop().?;
            l.cells.deinit(self.gpa);
        }
        // A buffer already over its declared capacity gives up its oldest
        // rows here, exactly as a scroll does.
        while (out.items.len > cap) {
            var l = out.orderedRemove(0);
            l.cells.deinit(self.gpa);
            if (cursor_new > 0) cursor_new -= 1;
        }
        self.lines.deinit(self.gpa);
        self.lines = out;
        return cursor_new;
    }

    /// Pack the group's full cell stream independently of retention.
    /// A non-final row is full except for the one-cell no-fit wide pad;
    /// the last row trims trailing NULLs. This preserves leading gaps and
    /// multi-chunk NULL survivors without using the producer's footprint.
    ///
    /// Cells are placed POSITIONALLY — a NULL cell keeps its column — and
    /// a width-2 glyph that does not fit in what is left of a row starts
    /// the next row, so the row ends early and the padding that leaves is
    /// not source. Only the last row's trailing NULLs are trimmed, and a
    /// printed space is content, not a NULL.
    fn repack(
        self: *Model,
        out: *std.ArrayList(Line),
        first: usize,
        last: usize,
        new_cols: usize,
    ) !void {
        const gpa = self.gpa;
        var stream: std.ArrayList(Cell) = .empty;
        defer stream.deinit(gpa);
        const count = last - first;
        for (self.lines.items[first..last], 0..) |l, idx| {
            var take = l.painted();
            if (idx + 1 < count) {
                take = self.cols;
                const tail = l.cells.items[self.cols - 1];
                const next = self.lines.items[first + idx + 1].cells.items[0];
                if (tail.kind == .none and next.kind == .wide) take -= 1;
            }
            try stream.appendSlice(gpa, l.cells.items[0..take]);
        }

        var pos: usize = 0;
        var rows: usize = 0;
        while (pos < stream.items.len) {
            var l: Line = .{ .cells = .empty, .wrapped = rows > 0 };
            errdefer l.cells.deinit(gpa);
            try l.cells.resize(gpa, new_cols);
            for (l.cells.items) |*c| c.* = .{};
            var used: usize = 0;
            while (pos < stream.items.len and used < new_cols) {
                const c = stream.items[pos];
                if (c.kind == .none) {
                    used += 1; // a NULL cell keeps its column
                    pos += 1;
                    continue;
                }
                if (c.kind == .tail) {
                    pos += 1; // an orphaned continuation
                    continue;
                }
                const w = c.columns();
                if (used + w > new_cols) {
                    if (used == 0) pos += 1; // wider than one whole row
                    break;
                }
                l.cells.items[used] = c;
                if (w == 2) l.cells.items[used + 1] = .{ .code = c.code, .kind = .tail };
                used += w;
                pos += w;
            }
            try out.append(gpa, l);
            rows += 1;
        }
        if (rows == 0) {
            // A group that packs to nothing still occupies one row.
            var l: Line = .{ .cells = .empty, .wrapped = false };
            errdefer l.cells.deinit(gpa);
            try l.cells.resize(gpa, new_cols);
            for (l.cells.items) |*c| c.* = .{};
            try out.append(gpa, l);
        }
    }

    // The byte path.

    fn appendLine(self: *Model) !void {
        var l: Line = .{ .cells = .empty };
        errdefer l.cells.deinit(self.gpa);
        try l.cells.resize(self.gpa, self.cols);
        for (l.cells.items) |*c| c.* = .{};
        try self.lines.append(self.gpa, l);
    }

    fn lineAt(self: *Model, y: usize) *Line {
        return &self.lines.items[self.ybase + y];
    }

    fn byte(self: *Model, b: u8) !void {
        switch (self.st) {
            .ground => try self.ground(b),
            .esc => switch (b) {
                '[' => {
                    self.st = .csi;
                    self.params = [_]u16{0} ** 8;
                    self.seen = 0;
                    self.cur = 0;
                    self.priv = false;
                },
                ']', 'P', '^', '_', 'X' => self.st = .string,
                else => self.st = .ground,
            },
            .csi => try self.csiByte(b),
            .string => switch (b) {
                0x07, '\\' => self.st = .ground,
                else => {},
            },
        }
    }

    fn csiByte(self: *Model, b: u8) !void {
        if (b >= '0' and b <= '9') {
            if (self.cur < self.params.len) {
                self.params[self.cur] = self.params[self.cur] * 10 + (b - '0');
            }
            self.seen = @max(self.seen, self.cur + 1);
            return;
        }
        if (b == ';') {
            if (self.cur + 1 < self.params.len) {
                self.cur += 1;
                self.params[self.cur] = 0;
                self.seen = @max(self.seen, self.cur + 1);
            }
            return;
        }
        if (b == '?' or b == '>' or b == '<' or b == '=') {
            self.priv = true;
            return;
        }
        self.st = .ground;
        try self.csi(b);
    }

    fn csi(self: *Model, final: u8) !void {
        const raw: u16 = if (self.seen == 0) 0 else self.params[0];
        const n: usize = if (raw == 0) 1 else raw;
        switch (final) {
            'A' => self.y = if (self.y > n) self.y - n else 0,
            'B' => self.y = @min(self.y + n, self.rows - 1),
            'C' => self.x = @min(self.x + n, self.cols - 1),
            'D' => self.x = if (self.x > n) self.x - n else 0,
            'E' => {
                self.y = @min(self.y + n, self.rows - 1);
                self.x = 0;
            },
            'F' => {
                self.y = if (self.y > n) self.y - n else 0;
                self.x = 0;
            },
            'G' => self.x = @min(if (raw == 0) 1 else raw, self.cols) - 1,
            'H', 'f' => {
                const row_arg: usize = if (self.seen == 0) 1 else n;
                const col_arg: usize = if (self.seen < 2)
                    1
                else if (self.params[1] == 0) 1 else self.params[1];
                self.y = @min(row_arg - 1, self.rows - 1);
                self.x = @min(col_arg - 1, self.cols - 1);
            },
            'J' => self.eraseDisplay(raw),
            'K' => self.eraseLine(raw),
            'n' => if (!self.priv and raw == 6) {
                try self.replies.append(self.gpa, .{
                    .row = self.cursorRow(),
                    .col = @intCast(@min(self.x, self.cols - 1) + 1),
                });
            },
            'm', 'r', 's', 't', 'u' => {},
            'h', 'l' => if (self.priv and raw == 7) {
                self.autowrap = final == 'h';
            },
            else => {},
        }
    }

    fn eraseDisplay(self: *Model, mode: u16) void {
        if (self.lines.items.len == 0) return;
        const here = @min(self.ybase + self.y, self.lines.items.len - 1);
        const last = @min(self.ybase + self.rows, self.lines.items.len);
        switch (mode) {
            0 => {
                for (self.lines.items[here..last]) |*l| blankAll(l);
                blankFrom(&self.lines.items[here], self.x);
            },
            1 => {
                for (self.lines.items[self.ybase .. here + 1]) |*l| blankAll(l);
                blankTo(&self.lines.items[here], self.x);
            },
            2 => for (self.lines.items[self.ybase..last]) |*l| {
                blankAll(l);
            },
            else => {},
        }
    }

    fn eraseLine(self: *Model, mode: u16) void {
        const l = self.lineAt(self.y);
        switch (mode) {
            0 => {
                blankFrom(l, self.x);
                if (self.x == 0) l.wrapped = false;
            },
            1 => blankTo(l, self.x),
            // A full-line erase also ends the continuation the row was
            // part of: the row becomes a hard boundary of its own.
            2 => {
                blankAll(l);
                l.wrapped = false;
            },
            else => {},
        }
    }

    // Cells.

    fn blankAll(l: *Line) void {
        for (l.cells.items) |*c| c.* = .{};
    }

    fn blankFrom(l: *Line, x: usize) void {
        if (x >= l.cells.items.len) return;
        blankOne(l, x);
        for (l.cells.items[x + 1 ..]) |*c| c.* = .{};
    }

    fn blankTo(l: *Line, x: usize) void {
        if (x >= l.cells.items.len) return;
        blankOne(l, x);
        for (l.cells.items[0..x]) |*c| c.* = .{};
    }

    /// Clear the cell at `x` together with the other half of the wide
    /// glyph it shares a row with, so a lead never outlives its tail.
    fn blankOne(l: *Line, x: usize) void {
        switch (l.cells.items[x].kind) {
            .wide => {
                if (x + 1 < l.cells.items.len) l.cells.items[x + 1] = .{};
            },
            .tail => {
                if (x > 0) l.cells.items[x - 1] = .{};
            },
            else => {},
        }
        l.cells.items[x] = .{};
    }

    fn ground(self: *Model, b: u8) !void {
        switch (b) {
            0x1b => {
                self.st = .esc;
                return;
            },
            '\r' => {
                self.x = 0;
                return;
            },
            '\n' => {
                try self.lineFeed();
                return;
            },
            0x08 => {
                self.x = if (self.x > 0) self.x - 1 else 0;
                return;
            },
            '\t' => {
                self.x = @min((self.x / 8 + 1) * 8, self.cols - 1);
                return;
            },
            else => {},
        }
        if (b < 0x20 or b == 0x7f) return;
        if (self.pend_len == 0) {
            const n = std.unicode.utf8ByteSequenceLength(b) catch return;
            self.pend[0] = b;
            if (n == 1) {
                try self.print(b, 1);
                return;
            }
            self.pend_need = n;
            self.pend_len = 1;
            return;
        }
        self.pend[self.pend_len] = b;
        self.pend_len += 1;
        if (self.pend_len < self.pend_need) return;
        const cp = (switch (self.pend_need) {
            2 => std.unicode.utf8Decode2(self.pend[0..2].*),
            3 => std.unicode.utf8Decode3(self.pend[0..3].*),
            4 => std.unicode.utf8Decode4(self.pend[0..4].*),
            else => unreachable,
        }) catch {
            self.pend_len = 0;
            return;
        };
        self.pend_len = 0;
        try self.print(cp, cellWidth(cp));
    }

    fn lineFeed(self: *Model) !void {
        self.y += 1;
        if (self.y >= self.rows) {
            try self.scroll();
        } else {
            // LF lands on a hard row, never a continuation.
            self.lineAt(self.y).wrapped = false;
        }
        if (self.x >= self.cols) self.x -= 1;
    }

    fn scroll(self: *Model) !void {
        self.y = self.rows - 1;
        self.ybase += 1;
        try self.appendLine();
        while (self.lines.items.len > self.capacity()) {
            var l = self.lines.orderedRemove(0);
            l.cells.deinit(self.gpa);
            if (self.ybase > 0) self.ybase -= 1;
        }
    }

    fn print(self: *Model, cp: u21, w: u8) !void {
        if (w == 0) return;
        if (self.x + w > self.cols) {
            // DECAWM off: the glyph does not fit, so it is not printed.
            // A width-2 lead with one column left is dropped whole.
            if (!self.autowrap) return;
            self.y += 1;
            if (self.y >= self.rows) try self.scroll();
            self.lineAt(self.y).wrapped = true;
            self.x = 0;
        }
        const l = self.lineAt(self.y);
        const x = @min(self.x, self.cols - 1);
        blankOne(l, x);
        l.cells.items[x] = .{ .code = cp, .kind = if (w == 2) .wide else .glyph };
        if (w == 2) l.cells.items[x + 1] = .{ .code = cp, .kind = .tail };
        self.x = x + w;
    }
};

// ── Region under the conforming independent model ──────────────

/// The window changes before Region observes it. The model processes the
/// emitted bytes and answers the actual post-paint cursor query.
const Rig = struct {
    const Options = struct {
        cols: u16 = 40,
        rows: u16 = 12,
        scrollback: u32 = 100,
        height: u16 = 2,
        mode: ResizeMode = .preserve,
        append_lines: bool = true,
        native_reflow: bool = true,
    };

    gpa: Allocator,
    region: Region,
    term: Model,
    out: std.Io.Writer.Allocating,

    fn init(gpa: Allocator, o: Options) !Rig {
        var term = try Model.init(gpa, o.cols, o.rows, o.scrollback);
        errdefer term.deinit();
        var region = try Region.init(gpa, .{
            .height = o.height,
            .append_lines = o.append_lines,
            .resize_mode = o.mode,
            .terminal_reflow = if (o.native_reflow)
                .{ .non_cursor_rows = .{ .scrollback_rows = o.scrollback } }
            else
                .none,
        });
        errdefer region.deinit();
        try region.resize(o.cols, o.rows, o.height);
        return .{ .gpa = gpa, .region = region, .term = term, .out = .init(gpa) };
    }

    fn deinit(self: *Rig) void {
        self.out.deinit();
        self.region.deinit();
        self.term.deinit();
        self.* = undefined;
    }

    /// Lay the band out: clear it, then draw `rows[i]` at row `i`.
    fn draw(self: *Rig, rows: []const []const u8) !void {
        self.region.cur.clear();
        for (rows, 0..) |text, y| {
            if (y < self.region.cur.height) {
                _ = try self.region.cur.draw(Style{}, text, 0, @intCast(y));
            }
        }
    }

    /// Draw one string at (x, y) leaving the rest of the row as the
    /// terminal's NULL cells — the shape a row with an interior gap
    /// really has on screen.
    fn drawAt(self: *Rig, x: u16, y: u16, text: []const u8) !void {
        _ = try self.region.cur.draw(Style{}, text, x, y);
    }

    fn append(self: *Rig, item: Region.Append) !void {
        try self.region.append(item);
    }

    fn commit(
        self: *Rig,
        id: u64,
        rows: []const []const u8,
        kind: @FieldType(HistoryBatch, "kind"),
    ) !void {
        try self.region.writeHistory(.{ .id = id, .rows = rows, .kind = kind });
    }

    fn render(self: *Rig) !void {
        self.out.clearRetainingCapacity();
        try self.region.render(&self.out.writer);
        try self.term.feed(self.out.written());
        try self.pump();
    }

    /// Route the terminal's own CPR replies into the Region, in the order
    /// the terminal would have answered them.
    fn pump(self: *Rig) !void {
        while (self.term.takeReply()) |r| try self.region.applyCpr(r.row, r.col);
    }

    /// The terminal changed shape; the Region learns about it after.
    fn resize(self: *Rig, cols: u16, rows: u16) !void {
        try self.term.resize(cols, rows);
        try self.region.resize(cols, rows, self.region.height);
        try self.pump();
    }

    fn setHeight(self: *Rig, h: u16) !void {
        try self.region.setHeight(h);
    }

    // ── what the terminal can be asked ────────────────────────

    /// The band top the terminal really shows: the cursor parks on the
    /// band bottom, so the band is the `height` rows ending there.
    fn bandTop(self: *const Rig) u16 {
        const rows = self.region.cur.height;
        if (rows == 0 or rows > self.term.rows) return 0;
        const bottom: usize = self.term.cursorRow();
        if (bottom < rows) return 0;
        return @intCast(bottom - rows + 1);
    }

    /// Buffer row of the terminal screen row `screen` (1-based).
    fn rowOf(self: *const Rig, screen: u16) !usize {
        const y: usize = @as(usize, screen) - 1;
        if (y >= self.term.rows) return error.RowOffScreen;
        const index = self.term.ybase + y;
        if (index >= self.term.lineCount()) return error.RowOffScreen;
        return index;
    }

    fn textOf(self: *const Rig, index: usize) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);
        try self.term.writeText(index, &out);
        return out.toOwnedSlice(self.gpa);
    }

    /// How many rows in the whole buffer print `needle`. A committed
    /// marker has to appear exactly once: a duplicated or resurrected
    /// one shows up here.
    fn countRows(self: *const Rig, needle: []const u8) !usize {
        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(self.gpa);
        var found: usize = 0;
        for (0..self.term.lineCount()) |i| {
            scratch.clearRetainingCapacity();
            try self.term.writeText(i, &scratch);
            if (std.mem.indexOf(u8, scratch.items, needle) != null) found += 1;
        }
        return found;
    }

    fn indexOfRow(self: *const Rig, needle: []const u8) !?usize {
        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(self.gpa);
        for (0..self.term.lineCount()) |i| {
            scratch.clearRetainingCapacity();
            try self.term.writeText(i, &scratch);
            if (std.mem.indexOf(u8, scratch.items, needle) != null) return i;
        }
        return null;
    }

    /// The hard group the first row printing `needle` belongs to: walk
    /// back over the continuations. A group whose head the terminal
    /// dropped starts at the buffer's first row.
    fn groupStartOf(self: *const Rig, needle: []const u8) !usize {
        var start = (try self.indexOfRow(needle)) orelse return error.NotFound;
        while (start > 0 and self.term.isWrapped(start)) start -= 1;
        return start;
    }

    /// The geometry change as the terminal sees it and as the Region is
    /// told about it, with no frame in between — a coalesced burst.
    fn observe(self: *Rig, cols: u16, rows: u16) !void {
        try self.term.resize(cols, rows);
        try self.region.resize(cols, rows, self.region.height);
    }
};

// Fixtures.

/// 55 ASCII columns then 38 width-two glyphs: 131 columns in one hard
/// row, the measured native fixture.
const mixed131: [169]u8 = blk: {
    var b: [169]u8 = undefined;
    var i: usize = 0;
    for (0..55) |_| {
        b[i] = 'a';
        i += 1;
    }
    for (0..38) |_| {
        b[i] = 0xe7;
        b[i + 1] = 0x95;
        b[i + 2] = 0x8c;
        i += 3;
    }
    break :blk b;
};

const glyph: []const u8 = "界";

/// Thirteen width-two glyphs: 26 columns that no byte count and no
/// ASCII projection can stand in for, which is the point of a row that
/// has to be re-projected at a narrower width.
const glyph_run: [13 * 3]u8 = blk: {
    var b: [13 * 3]u8 = undefined;
    for (0..13) |k| @memcpy(b[k * 3 ..][0..3], glyph);
    break :blk b;
};

/// The former cursor row, whole: 8 ASCII columns, 13 width-two glyphs
/// and 5 more ASCII — 39 painted columns inside the 40-column window,
/// where it is ONE hard row, and THREE at 14 columns (the splits fall
/// on glyph boundaries, so no chunk is dropped). Held as one slice so
/// the rejoin oracle compares the whole source and never a piece of it.
///
/// Space-free on purpose: the renderer skips default-styled blanks
/// (the row's erase plus CUF covers them), so a printed space reaches
/// the terminal as an erased NULL and `Model.writeText` — which skips
/// NULLs to keep them distinguishable — never shows it. An oracle that
/// names a space can never match; the geometry (39 columns, wide splits)
/// is what this source is for.
const long_source: [8 + glyph_run.len + 5]u8 = blk: {
    var b: [8 + glyph_run.len + 5]u8 = undefined;
    @memcpy(b[0..8], "job#41--");
    @memcpy(b[8..][0..glyph_run.len], glyph_run[0..]);
    @memcpy(b[8 + glyph_run.len ..][0..5], "-ok!?");
    break :blk b;
};

/// The marker a search finds the source by: its first six columns,
/// which live on the group's FIRST physical row and nowhere else.
/// Space-free for the same reason as `long_source`.
const long_head: []const u8 = "job#41";

/// Ten rows already on the screen before the app starts: the
/// pre-existing transcript a declared scrollback capacity has to keep.
const pre_rows: [10][]const u8 = .{
    "P00", "P01", "P02", "P03", "P04", "P05", "P06", "P07", "P08", "P09",
};

const band_rows: [2][]const u8 = .{ "B0", "B1" };

/// The message row the statusline paints: longer than every window this
/// file drives, so the wrapped row really is clipped or reflowed at each
/// of them rather than always fitting.
const statusline_message: []const u8 =
    "the quick brown fox jumps over the lazy dog while a statusline " ++
    "re-lays its own gauge and reports the columns it really has";

/// The left group a statusbar keeps whole, and the tail it right-aligns
/// at the window's edge. The stretch between them is what the renderer
/// never printed: an interior NULL gap, not a run of spaces.
const statusbar_left: []const u8 = " NORMAL  │ notui │ main*";

/// A gauge row of plain width-one glyphs: short enough to stay one
/// physical row at every width here, so the reflow below is entirely the
/// statusbar's and the message's work.
const gauge_row: []const u8 = "scan ##########.......... 50%";

/// The right-aligned tail, as a format rather than a literal: the width
/// it reports is the width the app really has, so it is built per frame
/// into storage the CALLER owns.
const statusline_tail = "v0.0.0  col {d}";

// Assertions shared by the tests.

/// The Region and the terminal must agree on where the band is. Every
/// consumer-visible claim about the live band rests on this one number:
/// an anchor the terminal does not confirm puts every later absolute
/// placement, and every retirement erase, on the wrong row.
fn expectAnchored(rig: *const Rig) !void {
    const want = rig.bandTop();
    if (want == 0) return testing.expectEqual(@as(u16, 0), rig.region.anchorRow());
    try testing.expectEqual(want, rig.region.anchorRow());
}

fn expectMarkerOnce(rig: *const Rig, marker: []const u8) !void {
    try testing.expectEqual(@as(usize, 1), try rig.countRows(marker));
}

/// A retired row is still in the terminal's own buffer. Nothing has
/// settled it and nothing may erase it while the reach is unmeasured,
/// so the claim available at a clip or a release is presence, never a
/// count: the band's own uncommitted text is not a committed marker and
/// two copies of it are not a duplicate on their own.
fn expectRetiredPresent(rig: *const Rig, marker: []const u8) !void {
    try testing.expect((try rig.countRows(marker)) > 0);
}

/// Every copy of a retired row is gone from the buffer. The take-back
/// erased what the reach showed rather than part of it, because the copy
/// a terminal hands back with its scrollback is the one that would read
/// twice.
fn expectRetiredGone(rig: *const Rig, marker: []const u8) !void {
    try testing.expectEqual(@as(usize, 0), try rig.countRows(marker));
}

fn expectGroup(rig: *const Rig, first: usize, want: []const u8) !void {
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(rig.gpa);
    for (first..rig.term.groupEnd(first)) |i| try rig.term.writeText(i, &got);
    try testing.expectEqualStrings(want, got.items);
}

/// One hard group, exactly `rows` physical rows tall, holding exactly
/// `want` when its rows are joined — and the only group in the whole
/// buffer that prints `needle`.
///
/// The row count is the part a substring count cannot see. A source
/// whose chunk was erased, or whose group was split in two, still
/// prints its head on the row that kept it: only the joined text and
/// the group's own extent say whether the row is still whole.
fn expectJoinedOnce(
    rig: *const Rig,
    needle: []const u8,
    rows: usize,
    want: []const u8,
) !void {
    try testing.expectEqual(@as(usize, 1), try rig.countRows(needle));
    const first = (try rig.indexOfRow(needle)) orelse return error.NotFound;
    try testing.expectEqual(rows, rig.term.groupRows(first));
    try expectGroup(rig, first, want);
}

/// The screen row (1-based) of the first terminal row printing `needle`.
/// The model's own answer, and the one `Region.anchorRow` has to agree
/// with: under a declared model a band row can be several physical rows
/// tall, so the band's top is no fixed distance below the cursor.
fn screenRowOf(rig: *const Rig, needle: []const u8) !u16 {
    const at = (try rig.indexOfRow(needle)) orelse return error.NotFound;
    return @intCast(at - rig.term.ybase + 1);
}

/// One terminal row's printed content, compared without leaving an
/// allocation behind.
fn expectRowText(rig: *const Rig, index: usize, want: []const u8) !void {
    const got = try rig.textOf(index);
    defer rig.gpa.free(got);
    try testing.expectEqualStrings(want, got);
}

fn expectBandRow(rig: *const Rig, band_row: usize, want: []const u8) !void {
    const top = rig.bandTop();
    if (top == 0) return error.NoBand;
    try expectRowText(rig, try rig.rowOf(@intCast(top + band_row)), want);
}

// ── calibration: the model against the recorded xterm readings ──

test "native model: the measured 131-column group repacks 55/54/22 then 65/66" {
    // bounded-scrollback-reflow-alignment-probe.json. 55 ASCII columns
    // and 38 width-two glyphs, one hard row at 131 columns.
    var t = try Model.init(testing.allocator, 131, 6, 200);
    defer t.deinit();
    try t.feed(mixed131[0..] ++ "\r\nT");
    try testing.expectEqual(@as(usize, 1), t.groupRows(0));
    try testing.expectEqual(@as(usize, 131), t.painted(0));

    try t.resize(55, 6);
    try testing.expectEqual(@as(usize, 3), t.groupRows(0));
    try testing.expectEqual(@as(usize, 55), t.painted(0));
    try testing.expectEqual(@as(usize, 54), t.painted(1));
    try testing.expectEqual(@as(usize, 22), t.painted(2));
    try testing.expect(!t.isWrapped(0));
    try testing.expect(t.isWrapped(1));
    try testing.expect(t.isWrapped(2));

    // The cursor's group is exempt, and the cursor's LINE follows the
    // rows the group above it gained.
    try testing.expectEqual(@as(usize, 1), t.groupRows(3));
    try testing.expectEqual(@as(u16, 4), t.cursorRow());

    try t.resize(66, 6);
    try testing.expectEqual(@as(usize, 2), t.groupRows(0));
    // Widening rejoins the group: the ASCII head and five glyphs take
    // 65 columns, the remaining 33 glyphs take the other 66.
    try testing.expectEqual(@as(usize, 65), t.painted(0));
    try testing.expectEqual(@as(usize, 66), t.painted(1));
    try testing.expectEqual(@as(u16, 3), t.cursorRow());
}

test "native model: the 65-column prefix needs 23 rows and the 33-glyph one 33" {
    // The two halves of the capacity counterexample. Neither is an
    // assertion about how many columns survived: both are assertions
    // that the same width-3 terminal lays two different logical rows out
    // differently, which is the difference a width change has to keep.
    var prefix = try Model.init(testing.allocator, 66, 100, 200);
    defer prefix.deinit();
    try prefix.feed("a" ** 55 ++ glyph ** 5 ++ "\r\nT");
    try testing.expectEqual(@as(usize, 65), prefix.painted(0));
    try prefix.resize(3, 100);
    // 18 rows of three ASCII columns, then the last ASCII column sharing
    // a row with the first glyph, then one row per remaining glyph.
    try testing.expectEqual(@as(usize, 23), prefix.groupRows(0));
    try testing.expectEqual(@as(usize, 3), prefix.painted(0));
    try testing.expectEqual(@as(usize, 3), prefix.painted(18));
    try testing.expectEqual(@as(usize, 2), prefix.painted(22));

    var wide = try Model.init(testing.allocator, 66, 100, 200);
    defer wide.deinit();
    try wide.feed(glyph ** 33 ++ "\r\nT");
    try testing.expectEqual(@as(usize, 66), wide.painted(0));
    try wide.resize(3, 100);
    // Every row holds exactly one glyph: at three columns two of them
    // never fit.
    try testing.expectEqual(@as(usize, 33), wide.groupRows(0));
    for (0..33) |i| try testing.expectEqual(@as(usize, 2), wide.painted(i));
}

test "native model: capacity drops the oldest row and never gives it back" {
    var t = try Model.init(testing.allocator, 131, 1, 100);
    defer t.deinit();
    try t.feed(mixed131[0..] ++ "\r\nT");
    try t.resize(55, 1);
    try testing.expectEqual(@as(usize, 3), t.groupRows(0));

    // The 102nd row drops only the oldest of the 101 retained rows.
    for (0..98) |_| try t.feed("\r\nh");
    try testing.expectEqual(@as(usize, 101), t.lineCount());

    // The ASCII head of the group is gone and the group now starts
    // inside itself, so its surviving width is the wide tail.
    try testing.expect(t.isWrapped(0));
    try testing.expectEqual(@as(usize, 54), t.painted(0));
    try testing.expectEqual(@as(usize, 22), t.painted(1));

    // A taller window hands the HIDDEN rows back. A wider one cannot
    // bring back what was dropped, because it was not hidden.
    try t.resize(55, 100);
    try testing.expectEqual(@as(usize, 101), t.lineCount());
    try testing.expectEqual(@as(usize, 2), t.groupRows(0));
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    try t.writeGroup(0, &scratch);
    try testing.expectEqual(@as(usize, glyph.len * 38), scratch.items.len);
}

test "native model: a full-line erase ends the continuation it belonged to" {
    var t = try Model.init(testing.allocator, 131, 4, 100);
    defer t.deinit();
    try t.feed(mixed131[0..] ++ "\r\nT");
    try t.resize(55, 4);
    try testing.expectEqual(@as(usize, 3), t.groupRows(0));

    // EL2 on the chunk that is on screen: the row keeps its place but
    // stops being a continuation, so it is a hard row of its own and the
    // group it was part of shrinks.
    const tail: usize = 2;
    var cpr: [16]u8 = undefined;
    const seq = try std.fmt.bufPrint(&cpr, "\x1b[{d};1H\x1b[2K", .{t.screenRow(tail)});
    try t.feed(seq);
    try testing.expectEqual(@as(usize, 0), t.painted(tail));
    try testing.expectEqual(@as(usize, 2), t.groupRows(0));
    try testing.expect(!t.isWrapped(tail));
}

test "native model: a width change repacks the unused tail below the cursor" {
    // cursor-group-exemption-not-screen-row-probe.json, and the rows6
    // reading behind it: across 55 -> 131 the cursor moves two rows down
    // and back while the blank rows below it go 4 -> 2 -> 4. The unused
    // tail is real rows that a width change consumes and creates; it is
    // not width-invariant, and a model that held it fixed would put the
    // cursor on the wrong row after the next row change.
    var t = try Model.init(testing.allocator, 131, 6, 0);
    defer t.deinit();
    try t.feed(mixed131[0..] ++ "\r\nT");
    const start = t.cursorRow();
    try testing.expectEqual(@as(usize, 4), t.lines.items.len - (t.ybase + t.y + 1));

    try t.resize(55, 6);
    try testing.expectEqual(start + 2, t.cursorRow());
    try testing.expectEqual(@as(usize, 2), t.lines.items.len - (t.ybase + t.y + 1));
    // The exempt group is one row of one column at both widths.
    try testing.expectEqual(@as(usize, 1), t.groupRows(t.ybase + t.y));

    try t.resize(131, 6);
    try testing.expectEqual(start, t.cursorRow());
    try testing.expectEqual(@as(usize, 4), t.lines.items.len - (t.ybase + t.y + 1));
    try testing.expectEqual(@as(usize, 1), t.groupRows(t.ybase + t.y));
}

test "native model: conforming capped reflow keeps the source tail and later hard rows" {
    var t = try Model.init(testing.allocator, 131, 1, 6);
    defer t.deinit();
    try t.feed(mixed131[0..] ++ "\r\nh00\r\nh01\r\nh02\r\nT\r");
    for ([_]u16{ 55, 66, 3 }) |cols| try t.resize(cols, 1);
    try testing.expectEqual(@as(usize, 7), t.lineCount());
    try testing.expectEqual(@as(usize, 3), t.groupRows(0));
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    for (0..3) |i| {
        scratch.clearRetainingCapacity();
        try t.writeText(i, &scratch);
        try testing.expectEqualStrings(glyph, scratch.items);
    }
    for ([_][]const u8{ "h00", "h01", "h02", "T" }, 3..) |text, i| {
        scratch.clearRetainingCapacity();
        try t.writeText(i, &scratch);
        try testing.expectEqualStrings(text, scratch.items);
    }
    try t.resize(10, 1);
    scratch.clearRetainingCapacity();
    try t.writeGroup(0, &scratch);
    try testing.expectEqualStrings(glyph ** 3, scratch.items);
}

test "native model: the controlled NULL offsets reflow as measured" {
    // native-null-offset-controlled-probe.json: the same 160x2 screen,
    // the same capacity, one glyph behind 100 or 130 columns of cursor
    // forward. Both keep the NULL run's columns — a NULL cell is a
    // column, not something to drop — and only the group's last row
    // trims its trailing NULLs.
    var near = try Model.init(testing.allocator, 160, 2, 400);
    defer near.deinit();
    var far = try Model.init(testing.allocator, 160, 2, 400);
    defer far.deinit();
    try near.feed("\x1b[100C" ++ glyph);
    try far.feed("\x1b[130C" ++ glyph);
    for ([_]*Model{ &near, &far }) |t| try t.feed("\r\nT");
    try testing.expectEqual(@as(usize, 102), near.painted(0));
    try testing.expectEqual(@as(usize, 132), far.painted(0));

    // 100 columns of NULL and one glyph: two chunks at 55, the first all
    // NULL and the second 45 NULL columns plus the glyph.
    try near.resize(55, 2);
    try testing.expectEqual(@as(usize, 2), near.groupRows(0));
    try testing.expectEqual(@as(usize, 0), near.painted(0));
    try testing.expectEqual(@as(usize, 47), near.painted(1));
    try testing.expect(near.isWrapped(1));
    // 130 columns: three chunks, the third 20 NULL columns plus the glyph.
    try far.resize(55, 2);
    try testing.expectEqual(@as(usize, 3), far.groupRows(0));
    try testing.expectEqual(@as(usize, 0), far.painted(0));
    try testing.expectEqual(@as(usize, 0), far.painted(1));
    try testing.expectEqual(@as(usize, 22), far.painted(2));

    // Erase the chunk the glyph is on. A full-line erase ends the
    // continuation, so the survivor is a hard group of its own: one
    // all-NULL chunk for the near offset, two for the far one.
    try near.feed("\x1b[1;1H\x1b[2K");
    try far.feed("\x1b[1;1H\x1b[2K");
    try testing.expectEqual(@as(usize, 1), near.groupRows(0));
    try testing.expectEqual(@as(usize, 2), far.groupRows(0));
    try testing.expect(!near.isWrapped(1));
    try testing.expect(!far.isWrapped(2));

    // 1 and 19 rows at width 3, 1 and 1 at 66, 1 and 1 back at 3.
    try near.resize(3, 2);
    try far.resize(3, 2);
    try testing.expectEqual(@as(usize, 1), near.groupRows(0));
    try testing.expectEqual(@as(usize, 19), far.groupRows(0));
    try testing.expect(!far.isWrapped(0));
    try testing.expect(far.isWrapped(1));

    try near.resize(66, 2);
    try far.resize(66, 2);
    try testing.expectEqual(@as(usize, 1), near.groupRows(0));
    try testing.expectEqual(@as(usize, 1), far.groupRows(0));
    try testing.expectEqual(@as(usize, 0), far.painted(0));

    try near.resize(3, 2);
    try far.resize(3, 2);
    try testing.expectEqual(@as(usize, 1), near.groupRows(0));
    try testing.expectEqual(@as(usize, 1), far.groupRows(0));
}

// Consumer regressions.

test "native: a width round trip keeps one live band and every marker" {
    var rig = try Rig.init(testing.allocator, .{
        .cols = 131,
        .rows = 12,
        .scrollback = 100,
        .height = 2,
    });
    defer rig.deinit();
    try rig.commit(1, &.{ mixed131[0..], "H1" }, .append);
    try rig.draw(&band_rows);
    try rig.render();

    try expectAnchored(&rig);
    try expectMarkerOnce(&rig, "H1");
    try expectGroup(&rig, 0, mixed131[0..]);
    try testing.expectEqual(@as(usize, 1), rig.term.groupRows(0));

    // Narrow: the group repacks, the marker above it stays where it was,
    // and the band is repainted at the new width.
    try rig.resize(55, 12);
    try rig.draw(&band_rows);
    try rig.render();

    try expectAnchored(&rig);
    try expectMarkerOnce(&rig, "H1");
    try expectGroup(&rig, 0, mixed131[0..]);
    try testing.expectEqual(@as(usize, 3), rig.term.groupRows(0));
    try expectBandRow(&rig, 0, "B0");
    try expectBandRow(&rig, 1, "B1");

    // Widen back: the group joins again and nothing is duplicated.
    try rig.resize(131, 12);
    try rig.draw(&band_rows);
    try rig.render();

    try expectAnchored(&rig);
    try expectMarkerOnce(&rig, "H1");
    try expectGroup(&rig, 0, mixed131[0..]);
    try testing.expectEqual(@as(usize, 1), rig.term.groupRows(0));
    try expectBandRow(&rig, 0, "B0");
    try expectBandRow(&rig, 1, "B1");
}

test "native: an interior gap and an odd-column glyph survive a round trip" {
    var rig = try Rig.init(testing.allocator, .{
        .cols = 131,
        .rows = 12,
        .height = 1,
    });
    defer rig.deinit();
    try rig.commit(1, &.{"H1"}, .append);

    rig.region.cur.clear();
    try rig.drawAt(0, 0, "head");
    try rig.drawAt(100, 0, glyph);
    try rig.render();

    try expectAnchored(&rig);
    try expectMarkerOnce(&rig, "H1");
    const wide_line = try rig.rowOf(rig.bandTop());
    try expectRowText(&rig, wide_line, "head" ++ glyph);
    try testing.expectEqual(@as(usize, 102), rig.term.painted(wide_line));

    // Narrow past the glyph's own chunk. The Region re-lays the row out
    // at the new width and the gap stays a gap.
    try rig.resize(14, 12);
    rig.region.cur.clear();
    try rig.drawAt(0, 0, "head");
    try rig.drawAt(11, 0, glyph);
    try rig.render();

    try expectAnchored(&rig);
    try expectMarkerOnce(&rig, "H1");
    const narrow_line = try rig.rowOf(rig.bandTop());
    try expectRowText(&rig, narrow_line, "head" ++ glyph);
    // The logical row ends at the glyph's tail, not at the margin, so
    // the seven columns the Region never printed are still NULL. A
    // printed space would have survived the erase and the repack.
    try testing.expectEqual(@as(usize, 13), rig.term.painted(narrow_line));
    for (4..11) |col| try testing.expectEqual(Cell{}, rig.term.cells(narrow_line)[col]);

    // Back to the wide window, and the glyph goes where the app put it.
    try rig.resize(131, 12);
    rig.region.cur.clear();
    try rig.drawAt(0, 0, "head");
    try rig.drawAt(100, 0, glyph);
    try rig.render();

    try expectAnchored(&rig);
    try expectMarkerOnce(&rig, "H1");
    try expectRowText(&rig, try rig.rowOf(rig.bandTop()), "head" ++ glyph);
}

test "native: width and height clipping restores what a shorter window hid" {
    var rig = try Rig.init(testing.allocator, .{
        .cols = 131,
        .rows = 8,
        .scrollback = 100,
        .height = 3,
    });
    defer rig.deinit();
    try rig.commit(1, &.{ mixed131[0..], "H1", "H2" }, .append);
    try rig.draw(&.{ "B0", "B1", "B2" });
    try rig.render();

    try expectAnchored(&rig);
    try expectMarkerOnce(&rig, "H1");
    try expectGroup(&rig, 0, mixed131[0..]);

    // A window too short for the band clips it. The top of the band goes
    // into scrollback where no cursor move can reach it, so the repaint
    // has to write every surviving row again.
    try rig.resize(55, 4);
    try rig.draw(&.{ "B0", "B1", "B2" });
    try rig.render();

    try expectAnchored(&rig);
    try expectMarkerOnce(&rig, "H1");
    try expectMarkerOnce(&rig, "H2");
    try expectGroup(&rig, 0, mixed131[0..]);

    // Churn real differences under the short window before restoring it:
    // a constant band would leave an erase that is never needed, and a
    // repaint that is never re-laid out, both untested.
    try rig.draw(&.{ "C0", "C1", "C2" });
    try rig.render();
    try rig.draw(&.{ "D0", "D1", "D2" });
    try rig.render();
    try expectAnchored(&rig);
    try expectBandRow(&rig, 0, "D0");
    try expectBandRow(&rig, 1, "D1");
    try expectBandRow(&rig, 2, "D2");

    // A taller window hands the clipped rows back: they were hidden, not
    // discarded, and the transcript above them is untouched.
    try rig.resize(55, 12);
    try rig.draw(&.{ "E0", "E1", "E2" });
    try rig.render();

    try expectAnchored(&rig);
    try expectMarkerOnce(&rig, "H1");
    try expectMarkerOnce(&rig, "H2");
    try expectGroup(&rig, 0, mixed131[0..]);
    try expectBandRow(&rig, 0, "E0");
    try expectBandRow(&rig, 1, "E1");
    try expectBandRow(&rig, 2, "E2");
}

test "native: a retired wide row survives every named geometry" {
    // The measured sequence, with the wide row RETIRED by a physical
    // clip rather than committed: a two-row band on a one-row window
    // pushes its top row into scrollback, and that is where the reflow
    // numbers come from. Capacity 100 leaves 33 glyph rows at width 3;
    // capacity 200 with ten pre-existing rows keeps the 65-column prefix
    // and needs 23.
    try retiredWide(100, 33);
    try retiredWide(200, 23);
}

fn retiredWide(scrollback: u32, want_rows: usize) !void {
    var rig = try Rig.init(testing.allocator, .{
        .cols = 131,
        .rows = 1,
        .scrollback = scrollback,
        .height = 2,
    });
    defer rig.deinit();
    if (scrollback >= 200) try rig.commit(1, pre_rows[0..], .append);

    // Two band rows on a one-row window: the wide row is clipped into
    // scrollback, where the Region no longer owns a relative move to it.
    try rig.draw(&.{ mixed131[0..], "T" });
    try rig.render();

    // The band shrinks to the one row the app still wants.
    try rig.setHeight(1);
    try rig.draw(&.{"T"});
    try rig.render();
    try expectAnchored(&rig);

    try rig.resize(55, 1);
    try rig.draw(&.{"T"});
    try rig.render();
    try expectAnchored(&rig);

    // 98 late committed rows, each one rendered.
    for (0..98) |i| {
        var tag: [8]u8 = undefined;
        const text = try std.fmt.bufPrint(&tag, "h{d:0>2}", .{i});
        try rig.commit(@intCast(i + 2), &.{text}, .append);
        try rig.render();
    }
    for (0..98) |i| {
        const tag = try std.fmt.allocPrint(testing.allocator, "h{d:0>2}", .{i});
        defer testing.allocator.free(tag);
        try expectMarkerOnce(&rig, tag);
    }
    if (scrollback >= 200) {
        for (0..10) |i| {
            const tag = try std.fmt.allocPrint(testing.allocator, "P{d:0>2}", .{i});
            defer testing.allocator.free(tag);
            try expectMarkerOnce(&rig, tag);
        }
    }

    try rig.resize(66, 1);
    try rig.draw(&.{"T"});
    try rig.render();
    try rig.resize(66, 100);
    try rig.draw(&.{"T"});
    try rig.render();
    try rig.render(); // retirement follows the post-paint measurement
    try expectAnchored(&rig);

    try rig.resize(3, 100);
    try rig.draw(&.{"T"});
    try rig.render();
    try expectAnchored(&rig);
    // The retired row's surviving prefix takes exactly the rows the
    // measured reading gives it at width 3.
    const alpha = try rig.groupStartOf(if (scrollback >= 200) "a" else glyph);
    try testing.expectEqual(want_rows, rig.term.groupRows(alpha));
    for (0..98) |i| {
        const tag = try std.fmt.allocPrint(testing.allocator, "h{d:0>2}", .{i});
        defer testing.allocator.free(tag);
        try expectMarkerOnce(&rig, tag);
    }

    // The whole buffer visible again: the prefix is still the same
    // logical row, and nothing the terminal dropped comes back.
    try rig.resize(3, 150);
    try rig.draw(&.{"T"});
    try rig.render();
    try expectAnchored(&rig);
    try rig.render();
    try testing.expectEqual(@as(usize, 0), try rig.countRows("a"));
    try testing.expectEqual(@as(usize, 0), try rig.countRows(glyph));
    for (0..98) |i| {
        const tag = try std.fmt.allocPrint(testing.allocator, "h{d:0>2}", .{i});
        defer testing.allocator.free(tag);
        try expectMarkerOnce(&rig, tag);
    }
    try expectBandRow(&rig, 0, "T");
}

test "native: a zero scrollback keeps nothing above the screen" {
    var rig = try Rig.init(testing.allocator, .{
        .cols = 40,
        .rows = 6,
        .scrollback = 0,
        .height = 2,
    });
    defer rig.deinit();
    try rig.commit(1, &.{"Z0"}, .append);
    try rig.draw(&band_rows);
    try rig.render();
    try expectAnchored(&rig);
    try expectMarkerOnce(&rig, "Z0");

    for (0..10) |i| {
        var tag: [8]u8 = undefined;
        const text = try std.fmt.bufPrint(&tag, "Z{d}", .{i + 1});
        try rig.commit(@intCast(i + 2), &.{text}, .append);
        try rig.render();
    }

    // The screen keeps its six rows and nothing above them, so the
    // first commit is gone while the Region still holds its copy of it.
    try testing.expectEqual(@as(usize, 0), try rig.countRows("Z0"));
    try testing.expect(rig.region.historyRetained(1));
    try expectAnchored(&rig);
    // Nothing is duplicated either: the newest commit is on screen once,
    // and no earlier one reappears in a row of its own.
    try expectMarkerOnce(&rig, "Z10");
    try testing.expect(rig.term.lineCount() <= 6);
    for (0..10) |i| {
        const tag = try std.fmt.allocPrint(testing.allocator, "Z{d}", .{i + 1});
        defer testing.allocator.free(tag);
        try testing.expect(try rig.countRows(tag) <= 1);
    }

    // Widening cannot resurrect a row the terminal dropped.
    try rig.resize(80, 6);
    try rig.render();
    try testing.expectEqual(@as(usize, 0), try rig.countRows("Z0"));
    try expectAnchored(&rig);
}

test "native: an exhausted scrollback discards the head for good" {
    // Four rows of capacity, a window of six, and far more committed
    // history than either can hold.
    var rig = try Rig.init(testing.allocator, .{
        .cols = 40,
        .rows = 6,
        .scrollback = 4,
        .height = 2,
    });
    defer rig.deinit();
    for (0..24) |i| {
        var tag: [8]u8 = undefined;
        const text = try std.fmt.bufPrint(&tag, "L{d:0>2}", .{i});
        try rig.commit(@intCast(i + 1), &.{text}, .append);
        try rig.draw(&band_rows);
        try rig.render();
    }

    try expectAnchored(&rig);
    try expectBandRow(&rig, 0, "B0");
    try expectBandRow(&rig, 1, "B1");
    // The oldest commits are gone from the terminal and only they.
    try testing.expectEqual(@as(usize, 0), try rig.countRows("L00"));
    try testing.expectEqual(@as(usize, 0), try rig.countRows("L05"));
    try expectMarkerOnce(&rig, "L23");
    // The Region still owns every row it was handed.
    try testing.expect(rig.region.historyRetained(1));
    try testing.expect(rig.region.historyRetained(24));

    // A widening is not a resurrection.
    try rig.resize(90, 6);
    try rig.draw(&band_rows);
    try rig.render();
    try testing.expectEqual(@as(usize, 0), try rig.countRows("L00"));
    try expectMarkerOnce(&rig, "L23");
    try expectAnchored(&rig);
}

test "native: a coalesced burst is accounted at every observed width" {
    // Seven rows of capacity over a one-row window: a retired wide row,
    // three late committed rows and the live band. Every width in the
    // burst is handed to the Region as its own observed transition with
    // no frame in between, because the terminal applies every one of
    // them and a Region that only looked at the last would skip the
    // capacity the intermediates cost.
    var rig = try Rig.init(testing.allocator, .{
        .cols = 131,
        .rows = 1,
        .scrollback = 6,
        .height = 2,
    });
    defer rig.deinit();

    // A two-row band on a one-row window retires its top row.
    try rig.draw(&.{ mixed131[0..], "T" });
    try rig.render();
    try rig.setHeight(1);
    try rig.draw(&.{"T"});
    try rig.render();

    for (0..3) |i| {
        var tag: [8]u8 = undefined;
        const text = try std.fmt.bufPrint(&tag, "h{d}", .{i});
        try rig.commit(@intCast(i + 1), &.{text}, .append);
        try rig.render();
    }

    try rig.observe(55, 1);
    try rig.observe(66, 1);
    try rig.observe(3, 1);
    // Only the three youngest glyph chunks fit beside h0/h1/h2/T.
    const alpha = try rig.groupStartOf(glyph);
    try testing.expectEqual(@as(usize, 3), rig.term.groupRows(alpha));
    try expectGroup(&rig, alpha, glyph ** 3);
    try rig.observe(131, 1);
    try rig.pump();

    try rig.draw(&.{"T"});
    try rig.render();
    try expectAnchored(&rig);
    // The three late rows are still there exactly once, and the widen
    // did not resurrect a prefix the terminal had already dropped.
    try expectMarkerOnce(&rig, "h0");
    try expectMarkerOnce(&rig, "h1");
    try expectMarkerOnce(&rig, "h2");
    try expectGroup(&rig, try rig.groupStartOf(glyph), glyph ** 3);

    try rig.setHeight(1);
    try rig.draw(&.{"T"});
    try rig.render();
    try expectAnchored(&rig);
    try expectMarkerOnce(&rig, "h0");
    try expectMarkerOnce(&rig, "h1");
    try expectMarkerOnce(&rig, "h2");
    try expectBandRow(&rig, 0, "T");
}

test "native: a preserve resize leaves a sentinel above the band alone" {
    var rig = try Rig.init(testing.allocator, .{
        .cols = 60,
        .rows = 12,
        .scrollback = 100,
        .height = 2,
        .mode = .preserve,
    });
    defer rig.deinit();
    try rig.commit(1, &.{ "SENTINEL", "H1" }, .append);
    try rig.draw(&band_rows);
    try rig.render();

    const sentinel = (try rig.indexOfRow("SENTINEL")).?;
    try expectMarkerOnce(&rig, "SENTINEL");
    try expectAnchored(&rig);
    try testing.expect(sentinel < try rig.rowOf(rig.bandTop()));

    // `.preserve` erases row-scoped inside the band, so a row above the
    // band top that this Region never painted comes through untouched,
    // its NULL tail included.
    try rig.resize(30, 12);
    try rig.draw(&band_rows);
    try rig.render();

    try expectAnchored(&rig);
    try testing.expectEqual(sentinel, (try rig.indexOfRow("SENTINEL")).?);
    try expectMarkerOnce(&rig, "SENTINEL");
    try expectMarkerOnce(&rig, "H1");
    try testing.expectEqual(@as(usize, 8), rig.term.painted(sentinel));
    for (8..30) |col| try testing.expectEqual(Cell{}, rig.term.cells(sentinel)[col]);
    try expectBandRow(&rig, 0, "B0");
}

test "native: an append resize keeps the committed rows above the band" {
    var rig = try Rig.init(testing.allocator, .{
        .cols = 60,
        .rows = 12,
        .scrollback = 100,
        .height = 2,
        .mode = .append,
    });
    defer rig.deinit();
    try rig.commit(1, &.{ "H1", "H2" }, .append);
    try rig.draw(&band_rows);
    try rig.render();
    const h1 = (try rig.indexOfRow("H1")).?;

    // `.append` clears from the band anchor and repaints in place, so the
    // two committed rows above it must come through untouched.
    try rig.resize(30, 12);
    try rig.draw(&band_rows);
    try rig.render();

    try expectAnchored(&rig);
    try testing.expectEqual(h1, (try rig.indexOfRow("H1")).?);
    try expectMarkerOnce(&rig, "H1");
    try expectMarkerOnce(&rig, "H2");
    try expectBandRow(&rig, 0, "B0");
    try expectBandRow(&rig, 1, "B1");
}

test "native: a rebuild resize settles the old band and re-anchors" {
    var rig = try Rig.init(testing.allocator, .{
        .cols = 60,
        .rows = 14,
        .scrollback = 100,
        .height = 3,
        .mode = .rebuild,
    });
    defer rig.deinit();
    try rig.commit(1, &.{"H1"}, .append);
    try rig.draw(&.{ "B0", "B1", "B2" });
    try rig.render();
    try expectAnchored(&rig);

    // Rebuild settles the old prefix above a different current band.
    try rig.resize(30, 14);
    try rig.draw(&.{ "C0", "C1", "C2" });
    try rig.render();

    try expectAnchored(&rig);
    try expectMarkerOnce(&rig, "H1");
    try expectMarkerOnce(&rig, "B0");
    try expectMarkerOnce(&rig, "B1");
    try testing.expectEqual(@as(usize, 0), try rig.countRows("B2"));
    try expectBandRow(&rig, 0, "C0");
    try expectBandRow(&rig, 1, "C1");
    try expectBandRow(&rig, 2, "C2");
}

/// The three rows the statusline example paints at `cols`: a statusbar
/// with a right-aligned tail across a long interior stretch nothing ever
/// printed, a short gauge row, and a wrapped message longer than the
/// window. Re-laid out for every frame, the way the example re-runs its
/// components each tick.
///
/// `tail` is the caller's storage for the formatted tail and it outlives
/// every frame that borrows it. The Buffer keeps a slice of each string
/// it is handed and the next render reads those bytes back — a row
/// footprint compares graphemes, not cells — so a tail that died with
/// this call was a use-after-free by the time the band was measured.
fn drawStatusline(rig: *Rig, cols: u16, tail: []u8) !void {
    rig.region.cur.clear();
    try rig.drawAt(0, 0, statusbar_left);
    const text = try std.fmt.bufPrint(tail, statusline_tail, .{cols});
    try rig.drawAt(cols -| @as(u16, @intCast(text.len)), 0, text);
    try rig.drawAt(0, 1, gauge_row);
    try rig.drawAt(0, 2, statusline_message);
}

/// A three-row band whose BOTTOM row is the long source: the shape the
/// release test needs, because a release settles every row the screen
/// still shows — the cursor's own row included — and a re-created band
/// then pushes its reservation past it. `top` and `mid` are the band's
/// two short rows, named apart by the caller so a clip's two retired
/// sources can be told apart.
fn drawRetiring(rig: *Rig, top: []const u8, mid: []const u8) !void {
    rig.region.cur.clear();
    try rig.drawAt(0, 0, top);
    try rig.drawAt(0, 1, mid);
    try rig.drawAt(0, 2, long_source[0..8]);
    try rig.drawAt(8, 2, glyph_run[0..]);
    try rig.drawAt(8 + 2 * 13, 2, long_source[long_source.len - 5 ..]);
}

test "native: a right-aligned statusbar row leaves no old ASCII prefix above the band" {
    // The statusline's own shape, on a declared profile, over thirty
    // committed marker rows no frame may touch.
    //
    // The interior gap is what makes this row interesting: a row that
    // merely LEFT those columns blank and a row that SPANNED them have
    // the same painted column count and the same width-2 positions, and
    // only the unprinted-interval record tells the repack which is which.
    // A paint origin computed from the wrong extent leaves the old
    // ASCII left group stranded ABOVE the live band — the residue the
    // 130x36 -> 55x31 capture showed, two rows above the new band —
    // while an extent computed from the right columns but the wrong
    // residue would invent rows the screen never held.
    var rig = try Rig.init(testing.allocator, .{
        .cols = 130,
        .rows = 36,
        .scrollback = 200,
        .height = 3,
        .mode = .append,
    });
    defer rig.deinit();
    var tags: [30][3]u8 = undefined;
    var lines: [30][]const u8 = undefined;
    for (&tags, &lines, 0..) |*tag, *line, i| {
        line.* = try std.fmt.bufPrint(tag, "M{d:0>2}", .{i});
    }
    try rig.commit(1, &lines, .append);
    // The tail's storage belongs to this frame chain, not to the draw:
    // the band borrows the bytes and every render below reads them back.
    var tail: [32]u8 = undefined;
    try drawStatusline(&rig, 130, &tail);
    try rig.render();

    // Space-free oracles: the renderer skips default blanks (erase + CUF),
    // so printed spaces are NULLs in the model and `writeText` never shows
    // them. `130` names the right-aligned tail the app believes it has;
    // each token below is unique to its row.
    try testing.expectEqual(@as(usize, 1), try rig.countRows("130"));
    try testing.expectEqual(
        try screenRowOf(&rig, "130"),
        rig.region.anchorRow(),
    );
    for (lines) |line| try expectMarkerOnce(&rig, line);

    // Narrow to 55 columns under a shorter window: the statusbar repacks
    // into three physical rows, the gauge stays one and the message row
    // is the cursor's own group.
    try rig.resize(55, 31);
    try drawStatusline(&rig, 55, &tail);
    try rig.render();

    // The app reports the width it really has, and the one it no longer
    // has is gone from every row of the buffer.
    try testing.expectEqual(@as(usize, 1), try rig.countRows("55"));
    try testing.expectEqual(@as(usize, 0), try rig.countRows("130"));
    // Every string the band paints is on exactly ONE row: the old ASCII
    // left group, the old right tail and the old gauge are all gone
    // rather than stranded above the live band.
    try testing.expectEqual(@as(usize, 1), try rig.countRows("notui"));
    try testing.expectEqual(@as(usize, 1), try rig.countRows("main*"));
    try testing.expectEqual(@as(usize, 1), try rig.countRows("NORMAL"));
    try testing.expectEqual(@as(usize, 1), try rig.countRows("scan"));
    try testing.expectEqual(@as(usize, 1), try rig.countRows("quick"));
    try testing.expectEqual(
        try screenRowOf(&rig, "55"),
        rig.region.anchorRow(),
    );
    for (lines) |line| try expectMarkerOnce(&rig, line);

    // And back to the wide window: the band is on its own rows again,
    // nothing is duplicated and nothing of the narrow layout survives.
    try rig.resize(130, 31);
    try drawStatusline(&rig, 130, &tail);
    try rig.render();

    try testing.expectEqual(@as(usize, 1), try rig.countRows("130"));
    try testing.expectEqual(@as(usize, 0), try rig.countRows("55"));
    try testing.expectEqual(@as(usize, 1), try rig.countRows("notui"));
    try testing.expectEqual(@as(usize, 1), try rig.countRows("scan"));
    try testing.expectEqual(@as(usize, 1), try rig.countRows("quick"));
    try testing.expectEqual(
        try screenRowOf(&rig, "130"),
        rig.region.anchorRow(),
    );
    for (lines) |line| try expectMarkerOnce(&rig, line);
}

test "height restore: 97x28 to 97x6 to 97x28 reclaims only the retired popup prefix" {
    // Same height-only geometry as the historical live REPL capture.
    // The eight-candidate popup owns ten rows at full height and six when
    // clipped. Its four old prefix rows leave the viewport, then return
    // above the live band when xterm pulls scrollback back on growth.
    for ([_]bool{ false, true }) |native_reflow| {
        var rig = try Rig.init(testing.allocator, .{
            .cols = 97,
            .rows = 28,
            .height = 10,
            .native_reflow = native_reflow,
        });
        defer rig.deinit();
        const popup = [_][]const u8{
            "skript>d",    "candidate-0", "candidate-1", "candidate-2", "candidate-3",
            "candidate-4", "candidate-5", "candidate-6", "candidate-7", "status",
        };
        const transcript = [_][]const u8{ "COMMITTED-0", "COMMITTED-1", "COMMITTED-2" };
        // Put the cursor at the bottom, as a transcript overflowing the
        // initial viewport does, without relying on Region's bookkeeping.
        for (0..36) |_| try rig.term.feed("prelaunch-history\r\n");
        try rig.commit(1, &transcript, .append);
        try rig.draw(&popup);
        try rig.render();
        try expectAnchored(&rig);

        try rig.term.resize(97, 6);
        try rig.region.resize(97, 6, 6);
        try rig.draw(&.{ popup[0], popup[1], popup[2], popup[3], popup[4], popup[9] });
        try rig.render();
        try expectAnchored(&rig);
        for (transcript) |row| try expectMarkerOnce(&rig, row);
        // Independent terminal evidence: the clipped prefix is still
        // in scrollback, not magically deleted by the resize.
        try testing.expectEqual(@as(usize, 2), try rig.countRows(popup[0]));
        const archived_input = (try rig.indexOfRow(popup[0])).?;
        try testing.expect(archived_input < rig.term.ybase);

        try rig.term.resize(97, 28);
        // The model must actually reveal the archived rows; otherwise a
        // no-residue assertion after rendering would be vacuous.
        try testing.expect(archived_input >= rig.term.ybase);
        try rig.region.resize(97, 28, 10);
        try rig.draw(&popup);
        try rig.render(); // asks CPR; no guessed erase above the band
        try rig.render(); // uses the reply to reclaim the visible prefix
        try expectAnchored(&rig);
        for (popup, 0..) |row, y| {
            try expectMarkerOnce(&rig, row);
            try expectBandRow(&rig, y, row);
        }
        for (transcript) |row| try expectMarkerOnce(&rig, row);
        try testing.expect(std.mem.indexOf(u8, rig.out.written(), "\x1b[2J") == null);
        try testing.expect(std.mem.indexOf(u8, rig.out.written(), "\x1b[3J") == null);
        try rig.render();
        try testing.expectEqual(@as(usize, 0), rig.out.written().len);
    }
}

test "native: a band shrinks and grows inside the window" {
    var rig = try Rig.init(testing.allocator, .{
        .cols = 40,
        .rows = 12,
        .height = 3,
    });
    defer rig.deinit();
    try rig.draw(&.{ "B0", "B1", "B2" });
    try rig.render();
    try expectAnchored(&rig);

    try rig.setHeight(1);
    try rig.draw(&.{"B0"});
    try rig.render();
    try expectAnchored(&rig);
    try expectBandRow(&rig, 0, "B0");

    try rig.setHeight(4);
    try rig.draw(&.{ "B0", "B1", "B2", "B3" });
    try rig.render();
    try expectAnchored(&rig);
    for (0..4) |i| try expectBandRow(&rig, i, band_long[i]);
}

const band_long: [4][]const u8 = .{ "B0", "B1", "B2", "B3" };

test "native: a collapsed band releases its rows and a reopened one reserves" {
    var rig = try Rig.init(testing.allocator, .{
        .cols = 40,
        .rows = 12,
        .height = 2,
    });
    defer rig.deinit();
    try rig.commit(1, &.{"H1"}, .append);
    try rig.draw(&band_rows);
    try rig.render();
    try expectAnchored(&rig);

    // Height 0 leaves the rows on screen as settled content and leaves
    // no band to place anything against, so the anchor is unusable.
    try rig.setHeight(0);
    try rig.render();
    try testing.expectEqual(@as(u16, 0), rig.region.anchorRow());
    try expectMarkerOnce(&rig, "H1");
    try expectMarkerOnce(&rig, "B0");

    // Reopening reserves its own rows again: the settled content is
    // still on screen and the new band is below it.
    try rig.setHeight(2);
    try rig.draw(&.{ "C0", "C1" });
    try rig.render();
    try expectAnchored(&rig);
    try expectMarkerOnce(&rig, "H1");
    try expectMarkerOnce(&rig, "C0");
    try expectBandRow(&rig, 0, "C0");
    try expectBandRow(&rig, 1, "C1");
}

test "native: retired rows are cleanable after the band is released" {
    // A clip, a release and a reopen, with the retirement owed in
    // between. A release settles the rows the screen still shows as
    // history and hands the rest of the band over as RETIRED — still
    // the band's own uncommitted text, still erasable, and never erased
    // on a guessed reach: the frame that can walk to them is the one
    // after a reply has measured the cursor again.
    //
    // The two frames name their rows apart, because a clip leaves the
    // band's own text on screen TWICE and the two copies are the
    // region's in different ways. The shrink stranded `B0`: no cursor
    // move reaches it any more, so the re-base hands that row over as
    // RETIRED. The repaint then wrote the new top row where the walk
    // clamped and the terminal scrolled `C0` out as well — but that row
    // is still the band's own top, so the clip cannot retire it, and a
    // release has to leave it the band's too rather than call history
    // out of reach. Neither is a committed marker: the band's own
    // uncommitted text is not one. What the clip can claim is that both
    // are still in the buffer, and what the take-back has to prove is
    // that it took BOTH — the copy a terminal hands back with its
    // scrollback is the one that would read twice.
    var rig = try Rig.init(testing.allocator, .{
        .cols = 40,
        .rows = 8,
        .scrollback = 100,
        .height = 3,
    });
    defer rig.deinit();
    try rig.commit(1, &.{"H1"}, .append);
    try rig.draw(&.{ "B0", "B1", "B2" });
    try rig.render();
    try expectAnchored(&rig);
    try expectMarkerOnce(&rig, "H1");
    try expectMarkerOnce(&rig, "B0");

    // A two-row window cannot hold a three-row band: the top row becomes
    // scrollback no cursor move can reach, so it retires.
    try rig.resize(40, 2);
    try rig.draw(&.{ "C0", "C1", "C2" });
    try rig.render();
    try expectAnchored(&rig);
    try expectRetiredPresent(&rig, "B0");
    try expectRetiredPresent(&rig, "C0");
    // What the window still shows is the live band's own rows, one row
    // each, and the rows the re-based repaint wrote over are really gone
    // rather than left beside their replacements.
    try expectMarkerOnce(&rig, "C1");
    try expectMarkerOnce(&rig, "C2");
    try testing.expectEqual(@as(usize, 0), try rig.countRows("B1"));
    try testing.expectEqual(@as(usize, 0), try rig.countRows("B2"));

    // The band is released: the rows the screen still shows settle as
    // history, and the retired ones are neither settled nor erased.
    try rig.setHeight(0);
    try rig.render();
    try testing.expectEqual(@as(u16, 0), rig.region.anchorRow());
    try expectMarkerOnce(&rig, "H1");
    try expectMarkerOnce(&rig, "C1");
    try expectMarkerOnce(&rig, "C2");
    try expectRetiredPresent(&rig, "B0");
    try expectRetiredPresent(&rig, "C0");

    // Reopening reserves its own rows again, and the frame after the
    // reply that re-established the reach takes every retired row back.
    //
    // The window is tall enough for that reservation to land BELOW the
    // cursor: a band re-created after a release starts a row below it,
    // and a reservation made on the window's last row scrolls — which
    // buries the rows the frame was about to walk to and leaves a
    // retirement that is tracked, unerased and unreachable. That is the
    // rule this test is not about; a window that still shows them is.
    try rig.resize(40, 12);
    try rig.setHeight(3);
    try rig.draw(&.{ "D0", "D1", "D2" });
    try rig.render();
    try rig.render();

    try expectAnchored(&rig);
    try expectRetiredGone(&rig, "B0");
    try expectRetiredGone(&rig, "C0");
    // The settled rows and the committed history are what the take-back
    // walked past: still on screen, exactly once each.
    try expectMarkerOnce(&rig, "C1");
    try expectMarkerOnce(&rig, "C2");
    try expectMarkerOnce(&rig, "H1");
    try expectBandRow(&rig, 0, "D0");
    try expectBandRow(&rig, 1, "D1");
    try expectBandRow(&rig, 2, "D2");
}

test "native: a released cursor row rejoins whole after the window narrows" {
    // The other half of the release, at a width that moves. A release
    // hands every row the screen still shows to the ledger — the cursor's
    // own row among them, because a row nothing owns is a row no reflow
    // can project — and a band re-created afterwards reserves its rows by
    // pushing PAST that content. The push is a gap, and a gap is only as
    // good as the rows it is not: a row a gap swallowed is recorded as
    // blank, which is one physical row at any width and no reflow at all.
    //
    // That row is not blank. It is the band's own bottom row, with its
    // own extent, so give it one worth projecting: 39 columns of ASCII
    // and width-two glyphs inside the 40-column window — one hard row
    // there — and THREE rows at 14 columns, the splits falling on glyph
    // boundaries so no chunk is dropped. Once it repacks, every offset
    // the ledger kept above it has to follow, and the take-back that runs
    // after the narrowing's reply walks exactly those offsets: it must
    // reach the two retired rows and nothing else. A gap that stood in
    // for the source instead would move every one of them by the rows the
    // source gained, and the frame would erase the source's own chunk and
    // a row that was never retired while a retired row stayed on screen.
    //
    // The consumer claim is the WHOLE source, joined, on one hard group
    // of the physical width the window gives it: not its head, not a
    // count of rows holding part of it. A source that lost a chunk still
    // prints its head on the rows that kept it, so only the joined text
    // and the group's own row count can tell a whole row from a
    // fragment — and the take-back must not have bought the cleanup by
    // erasing part of it.
    //
    // The narrowing follows the reopen, and the retirement is still owed
    // when it happens: a terminal exempts the CURSOR's own group from a
    // width reflow, and while the band is released the cursor is parked
    // on that row, so nothing repacks it until the cursor moves off it —
    // which the re-created band is what does. One frame only on the way
    // in, because the reply that frame asks for measures the cursor and
    // the frame after THAT is the one the take-back would run in; the
    // narrowing has to invalidate that reach first, so the cleanup runs
    // against the narrowing's own reply, which is the reach it must be
    // measured against.
    var rig = try Rig.init(testing.allocator, .{
        .cols = 40,
        .rows = 8,
        .scrollback = 100,
        .height = 3,
    });
    defer rig.deinit();
    try rig.commit(1, &.{"H1"}, .append);
    try drawRetiring(&rig, "B0", "B1");
    try rig.render();
    try expectAnchored(&rig);
    try expectBandRow(&rig, 2, long_source[0..]);
    try expectJoinedOnce(&rig, long_head, 1, long_source[0..]);

    // A two-row window cannot hold a three-row band: the row the shrink
    // stranded retires with the re-base, and the band's own top row is
    // left where nothing can reach it either.
    try rig.resize(40, 2);
    try drawRetiring(&rig, "C0", "C1");
    try rig.render();
    try expectAnchored(&rig);
    try expectRetiredPresent(&rig, "B0");
    try expectRetiredPresent(&rig, "C0");
    try expectMarkerOnce(&rig, "C1");
    try expectJoinedOnce(&rig, long_head, 1, long_source[0..]);

    // Released: every row the screen still shows is transcript now, the
    // long source included, and the two rows the clip stranded are still
    // on the buffer, neither settled as history nor erased.
    try rig.setHeight(0);
    try rig.render();
    try testing.expectEqual(@as(u16, 0), rig.region.anchorRow());
    try expectMarkerOnce(&rig, "H1");
    try expectMarkerOnce(&rig, "C1");
    try expectRetiredPresent(&rig, "B0");
    try expectRetiredPresent(&rig, "C0");
    try expectJoinedOnce(&rig, long_head, 1, long_source[0..]);

    // A window tall enough that the re-created band's reservation lands
    // inside it instead of scrolling, and that the reach covers every row
    // above the new band top. One frame only: the reply it asks for
    // measures the cursor, and the frame after THAT is the one the
    // take-back would run in — the narrowing below has to invalidate
    // that reach first.
    try rig.resize(40, 13);
    try rig.setHeight(3);
    try rig.draw(&.{ "D0", "D1", "D2" });
    try rig.render();

    try expectAnchored(&rig);
    try expectMarkerOnce(&rig, "H1");
    try expectMarkerOnce(&rig, "C1");
    try expectRetiredPresent(&rig, "B0");
    try expectRetiredPresent(&rig, "C0");
    try expectJoinedOnce(&rig, long_head, 1, long_source[0..]);

    // Now the width moves: the source is a non-cursor row, so the
    // terminal packs it onto three physical rows and the ledger has to
    // agree about how many rows it is worth. The frames after the
    // narrowing's own reply are the ones the take-back runs in, and the
    // offsets it walks are the ones the gap mis-counted.
    try rig.resize(14, 13);
    try rig.render();
    try rig.render();

    try expectAnchored(&rig);
    try expectRetiredGone(&rig, "B0");
    try expectRetiredGone(&rig, "C0");
    try expectJoinedOnce(&rig, long_head, 3, long_source[0..]);
    try expectMarkerOnce(&rig, "H1");
    try expectMarkerOnce(&rig, "C1");
    try expectBandRow(&rig, 0, "D0");
    try expectBandRow(&rig, 1, "D1");
    try expectBandRow(&rig, 2, "D2");
}

test "native: a trailing newline flushes one committed row, not two" {
    // A `.text` that ends in a newline writes ONE hard row: the `\r\n`
    // that newline contributes IS the row move, so the empty segment
    // after it never reaches the wire and must never reach the ledger
    // either. A phantom row would be invisible here and visible later —
    // every offset above the band top counts through it, so the
    // retirement erase below would land a row low, on the row the
    // caller just wrote.
    var rig = try Rig.init(testing.allocator, .{
        .cols = 40,
        .rows = 8,
        .scrollback = 100,
        .height = 3,
    });
    defer rig.deinit();
    try rig.commit(1, &.{"H1"}, .append);
    try rig.draw(&.{ "B0", "B1", "B2" });
    try rig.render();
    try expectAnchored(&rig);

    // A two-row window cannot hold a three-row band: the top row becomes
    // scrollback no cursor move can reach, so it retires.
    try rig.resize(40, 2);
    try rig.draw(&.{ "B0", "B1", "B2" });
    try rig.render();
    try expectAnchored(&rig);
    try rig.setHeight(1);
    try rig.draw(&.{"C0"});
    try rig.render();
    try expectAnchored(&rig);
    try expectMarkerOnce(&rig, "C0");

    // The flushed row lands above the band, exactly once.
    try rig.append(.{ .text = "late-a\n" });
    try rig.render();
    try expectAnchored(&rig);
    try expectMarkerOnce(&rig, "late-a");

    // The window reveals everything: the retired band row is taken back
    // and the written row is left exactly where the flush put it, which
    // is only true when the ledger counted the flush exactly.
    try rig.resize(40, 8);
    try rig.draw(&.{"C0"});
    try rig.render();
    try rig.render();
    try expectAnchored(&rig);
    try testing.expectEqual(@as(usize, 0), try rig.countRows("B0"));
    try expectMarkerOnce(&rig, "late-a");
    try expectMarkerOnce(&rig, "H1");
    try expectBandRow(&rig, 0, "C0");
}

test "native: a replay supersedes queued appends and reaches the terminal alone" {
    var rig = try Rig.init(testing.allocator, .{
        .cols = 40,
        .rows = 12,
        .height = 2,
    });
    defer rig.deinit();
    try rig.append(.{ .line = "OLD1" });
    try rig.append(.{ .line = "OLD2" });
    try rig.draw(&band_rows);
    try rig.commit(1, &.{ "NEW1", "NEW2" }, .replay);
    try rig.render();

    // The replay is the complete ledger: the queued appends never reach
    // the wire, and no row of the replay appears twice.
    try testing.expectEqual(@as(usize, 0), try rig.countRows("OLD1"));
    try testing.expectEqual(@as(usize, 0), try rig.countRows("OLD2"));
    try expectMarkerOnce(&rig, "NEW1");
    try expectMarkerOnce(&rig, "NEW2");
    try expectAnchored(&rig);
    try expectBandRow(&rig, 0, "B0");
}

test "native: a refused frame leaves nothing behind and the retry is exact" {
    var rig = try Rig.init(testing.allocator, .{
        .cols = 60,
        .rows = 12,
        .scrollback = 100,
        .height = 2,
    });
    defer rig.deinit();
    try rig.commit(1, &.{"H1"}, .append);
    try rig.draw(&band_rows);
    try rig.render();
    try expectAnchored(&rig);

    // A bounded staging writer refuses the frame part-way through. The
    // transport took nothing, so the Region must still describe exactly
    // the frame that was not written.
    try rig.commit(2, &.{"H2"}, .append);
    try rig.resize(30, 12);
    rig.region.cur.clear();
    try rig.draw(&.{ "B9", "C9" });
    const damage = rig.region.dirtyCells();
    var small: [24]u8 = undefined;
    var refusing: std.Io.Writer = .fixed(&small);
    try testing.expectError(error.WriteFailed, rig.region.render(&refusing));
    try testing.expectEqual(damage, rig.region.dirtyCells());
    try expectBandRow(&rig, 0, "B0");
    try expectBandRow(&rig, 1, "B1");
    try testing.expectError(error.UnknownHistoryId, rig.region.acknowledgeHistory(2));

    // The retry writes the whole frame and the terminal ends up where
    // the Region says it is.
    try rig.resize(45, 12);
    try rig.render();
    try rig.render(); // the resize frame precedes the pending ledger flush
    try expectAnchored(&rig);
    try expectMarkerOnce(&rig, "H1");
    try expectMarkerOnce(&rig, "B9");
    try expectBandRow(&rig, 0, "B9");
    try expectBandRow(&rig, 1, "C9");
    try expectMarkerOnce(&rig, "H2");
    try rig.region.acknowledgeHistory(2);
}

test "native: a ledger batch that cannot be staged changes nothing" {
    var region = try Region.init(testing.allocator, .{
        .height = 1,
        .max_history_bytes = 16,
        .terminal_reflow = .{ .non_cursor_rows = .{ .scrollback_rows = 10 } },
    });
    defer region.deinit();
    try region.writeHistory(.{ .id = 1, .rows = &.{"kept"}, .kind = .append });

    // The retained-byte bound refuses the batch before anything moves.
    try testing.expectError(
        error.HistoryTooLarge,
        region.writeHistory(.{ .id = 2, .rows = &.{"a-far-too-long-row"}, .kind = .append }),
    );
    try testing.expectEqual(@as(u64, 1), region.historyWatermark());
    try testing.expect(region.historyRetained(1));
    try testing.expect(!region.historyRetained(2));
}

test "native: failed geometry allocation preserves the committed frame and retries once" {
    var fa: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var region = try Region.init(fa.allocator(), .{
        .height = 1,
        .terminal_reflow = .{ .non_cursor_rows = .{ .scrollback_rows = 4 } },
    });
    defer region.deinit();
    var term = try Model.init(testing.allocator, 60, 8, 4);
    defer term.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try region.resize(60, 8, 1);
    _ = try region.cur.draw(Style{}, "B0", 0, 0);
    try region.render(&out.writer);
    try term.feed(out.written());
    while (term.takeReply()) |reply| try region.applyCpr(reply.row, reply.col);
    const anchor = region.anchorRow();
    try testing.expectEqual(term.cursorRow(), anchor);
    try testing.expectEqual(@as(u16, 60), region.paintedWidth());

    try term.resize(30, 8);
    out.clearRetainingCapacity();
    fa.fail_index = fa.alloc_index;
    fa.resize_fail_index = fa.resize_index;
    try testing.expectError(error.OutOfMemory, region.resize(30, 8, 1));
    try testing.expectEqual(@as(u16, 60), region.paintedWidth());
    try testing.expectEqual(anchor, region.anchorRow());

    fa.fail_index = std.math.maxInt(usize);
    fa.resize_fail_index = std.math.maxInt(usize);
    try region.resize(30, 8, 1);
    try testing.expectEqual(@as(u16, 60), region.paintedWidth());
    _ = try region.cur.draw(Style{}, "B1", 0, 0);
    try region.render(&out.writer);
    try term.feed(out.written());
    while (term.takeReply()) |reply| try region.applyCpr(reply.row, reply.col);
    try testing.expectEqual(@as(u16, 30), region.paintedWidth());
    try testing.expectEqual(term.cursorRow(), region.anchorRow());
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try term.writeText(term.ybase + term.y, &text);
    try testing.expectEqualStrings("B1", text.items);
}

test "native: two unprinted prefix chunks reflow 19 to 1 to 1 after partial erasure" {
    var rig = try Rig.init(testing.allocator, .{
        .cols = 160,
        .rows = 1,
        .scrollback = 400,
        .height = 2,
    });
    defer rig.deinit();
    try rig.term.feed("S\r\n");
    rig.region.cur.clear();
    try rig.drawAt(130, 0, glyph);
    try rig.drawAt(0, 1, "T");
    try rig.render();
    const prefix = try rig.groupStartOf(glyph);
    try rig.setHeight(1);
    try rig.draw(&.{"T"});
    try rig.render();
    try rig.resize(55, 1);
    try rig.render();
    for (0..98) |i| {
        var tag: [3]u8 = undefined;
        const text = try std.fmt.bufPrint(&tag, "h{d:0>2}", .{i});
        try rig.commit(@intCast(i + 1), &.{text}, .append);
        try rig.render();
    }
    try rig.resize(55, 100);
    try rig.render();
    try rig.render(); // the fresh CPR permits the retirement erase
    try testing.expectEqual(@as(usize, 0), try rig.countRows(glyph));
    try testing.expectEqual(@as(usize, 2), rig.term.groupRows(prefix));

    for ([_]struct { cols: u16, chunks: usize }{
        .{ .cols = 3, .chunks = 19 },
        .{ .cols = 66, .chunks = 1 },
        .{ .cols = 3, .chunks = 1 },
    }) |step| {
        try rig.resize(step.cols, 100);
        try rig.render();
        try rig.render();
        try testing.expectEqual(step.chunks, rig.term.groupRows(prefix));
        try expectMarkerOnce(&rig, "S");
        for (0..98) |i| {
            var tag: [3]u8 = undefined;
            try expectMarkerOnce(&rig, try std.fmt.bufPrint(&tag, "h{d:0>2}", .{i}));
        }
        try expectBandRow(&rig, 0, "T");
        try expectAnchored(&rig);
    }
    try rig.resize(3, 150);
    try rig.render();
    try rig.render();
    try expectMarkerOnce(&rig, "S");
    try expectBandRow(&rig, 0, "T");
}

test "native: clipping a cursor row before collapse does not archive its lost tail" {
    var rig = try Rig.init(testing.allocator, .{
        .cols = 131,
        .rows = 8,
        .height = 1,
    });
    defer rig.deinit();
    try rig.commit(1, &.{"H"}, .append);
    try rig.draw(&.{mixed131[0..]});
    try rig.render();
    try rig.resize(3, 8);
    try rig.setHeight(0);
    try rig.render();
    try rig.setHeight(1);
    try rig.draw(&.{"Z"});
    try rig.render();
    try rig.resize(131, 8);
    try rig.draw(&.{"Z"});
    try rig.render();
    try expectAnchored(&rig);
    try expectMarkerOnce(&rig, "H");
    try expectMarkerOnce(&rig, "aaa");
    try expectMarkerOnce(&rig, "Z");
    try testing.expectEqual(@as(usize, 0), try rig.countRows(glyph));
}

test "native: maximum declared capacity does not wrap the viewport budget" {
    var rig = try Rig.init(testing.allocator, .{
        .cols = 131,
        .rows = 6,
        .scrollback = std.math.maxInt(u32),
    });
    defer rig.deinit();
    try rig.commit(1, &.{"H"}, .append);
    try rig.draw(&band_rows);
    try rig.render();
    try rig.resize(55, 6);
    try rig.draw(&band_rows);
    try rig.render();
    try expectAnchored(&rig);
    try expectMarkerOnce(&rig, "H");
    try expectBandRow(&rig, 0, "B0");
    try expectBandRow(&rig, 1, "B1");
}

test "native: live-band head loss retires the hidden prefix in every resize mode" {
    for ([_]ResizeMode{ .preserve, .append, .rebuild }) |mode| {
        var rig = try Rig.init(testing.allocator, .{
            .cols = 131,
            .rows = 1,
            .scrollback = 2,
            .height = 2,
            .mode = mode,
        });
        defer rig.deinit();
        try rig.draw(&.{ mixed131[0..], "T" });
        try rig.render();
        try rig.observe(55, 1); // discard the live row's ASCII head
        try rig.observe(66, 2);
        try rig.setHeight(1);
        try rig.draw(&.{"T"});
        try rig.render();

        var tags: [98][3]u8 = undefined;
        var lines: [98][]const u8 = undefined;
        for (&tags, &lines, 0..) |*tag, *line, i| {
            line.* = try std.fmt.bufPrint(tag, "h{d:0>2}", .{i});
        }
        try rig.resize(66, 100);
        try rig.commit(1, &lines, .append);
        try rig.render(); // bury the retirement before accepting the new CPR
        try rig.observe(3, 150);
        try rig.render();
        try rig.render();
        // Physical safety wins over the resize mode here: the old extent
        // is 2 rows on a 1-row window, so no mode's ordinary resize walk
        // can reach the prefix. The hidden rows are the LIVE band's own
        // uncommitted text, so they are retired and erased once the
        // viewport reveals them — a `.rebuild` must never settle
        // inaccessible rows as committed history.
        try testing.expectEqual(@as(usize, 0), try rig.countRows(glyph));
        try testing.expectEqual(@as(usize, 0), try rig.countRows("a"));
        for (lines) |line| try expectMarkerOnce(&rig, line);
        try expectBandRow(&rig, 0, "T");
        try expectAnchored(&rig);
    }
}

test "native: idle clipped bands do not strand another copy" {
    for ([_]u32{ 0, 2 }) |capacity| {
        var rig = try Rig.init(testing.allocator, .{
            .cols = 131,
            .rows = 1,
            .scrollback = capacity,
            .height = 2,
        });
        defer rig.deinit();
        try rig.draw(&.{ mixed131[0..], "T" });
        try rig.render();
        for (0..4) |_| {
            try rig.render();
            try testing.expectEqual(@as(usize, 0), rig.out.written().len);
        }
        const kept: usize = if (capacity == 0) 0 else 1;
        try testing.expectEqual(kept, try rig.countRows(glyph));
        try expectMarkerOnce(&rig, "T");
        try expectAnchored(&rig);
    }
}
