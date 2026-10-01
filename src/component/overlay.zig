//! overlay.zig — picker and overlay primitives (roadmap D4).
//!
//! Three standalone components drawn INTO a caller-owned `Buffer`:
//! `Select` (a vertical list with a moving highlight and its own
//! keyboard driver), `Modal` (a box with title, body and footer,
//! centred in the space it is given) and `Popover` (a box anchored to
//! a point). notui is inline-first and owns no screen, so an overlay
//! is not a special draw mode: it is cells in the buffer the app
//! already paints, and `Region` clips the band. Every primitive here
//! therefore clamps its own geometry to `buf` and emits no ANSI — it
//! only sets `Style` on cells.
//!
//! All three are static (`advance` is always false) and `draw`
//! allocates nothing: text is truncated by walking graphemes through
//! the `width.zig` seam straight into the caller's cells, so the draw
//! path needs no allocator and no scratch list. Item, body and line
//! storage is caller-owned — the app fills a `[]const []const u8`
//! from its own arena and hands the slice over.
//!
//! Titles, bodies and items are UNTRUSTED at draw: they routinely carry
//! model or peer output. Every grapheme that reaches a cell therefore
//! passes `markdown.Sanitizer` first — the library's one escape parser —
//! so no source byte can become a terminal command. The width seam
//! alone cannot do it: it reads a raw 0x9B byte as U+FFFD at width 1 and
//! an ESC sequence body as printable text. Filter state persists across
//! the rows of one logical body, so a sequence split over a row break is
//! consumed as one, and resets between unrelated fields: the box title,
//! body and footer, each picker option, and each popover line.
//!
//! Filtering comes BEFORE the width decision, so an ellipsis is offered
//! for the text that survives rather than for bytes that never render:
//! an item carrying a colour change is cut as the text it leaves
//! behind. Tab and newline are the only control scalars the machine
//! admits, and neither may sit in a cell — a tab expands to spaces up
//! to the next stop, a line break drops, because one call paints one
//! row.

const std = @import("std");
const Buffer = @import("../buffer.zig").Buffer;
const Style = @import("../style.zig").Style;
const Width = @import("../width.zig");
const Clock = @import("component.zig").Clock;
const Key = @import("../Key.zig");
const Event = @import("../event.zig").Event;
const markdown = @import("../markdown.zig");

/// The box-drawing graphemes, one cell each.
const Glyphs = struct {
    const top_left = "┌";
    const top_right = "┐";
    const bottom_left = "└";
    const bottom_right = "┘";
    const horizontal = "─";
    const vertical = "│";
};

/// Columns a tab advances to. The library's one tab rule, shared with
/// `component/cards.zig`: the escape machine admits tab, and a tab byte
/// in a cell would move the cursor when the row is written.
const tab_width: usize = 4;

/// A vertical list with a moving highlight, drawn as a box into the
/// caller's buffer.
///
/// Item strings are BORROWED from the app (its arena); the component
/// owns no memory and `draw` allocates nothing. An empty list is
/// legal: nothing draws, `selected()` is null, and the box never
/// appears.
///
/// Keyboard: up/`k` and down/`j` WRAP at both ends, home/end jump to
/// the ends, a digit key jumps to that 0-based index, enter confirms
/// and escape cancels. `resolve` is the one-call approval-prompt
/// helper over the same rules.
pub const Select = struct {
    /// Items, borrowed.
    items: []const []const u8 = &.{},
    /// Highlighted index, raw. Read it through `selected()`, which
    /// clamps: an app that assigns the field directly after shrinking
    /// `items` is still safe.
    cursor: usize = 0,
    /// False once the user has confirmed or cancelled.
    open: bool = true,
    /// True when the picker closed by CONFIRMING (enter). False after
    /// escape; meaningless while `open` is true.
    confirmed: bool = false,
    /// Preferred outer width in columns; the drawn box never exceeds
    /// the columns available at the draw position.
    width: u16 = 24,
    /// Index of the first drawn item. Render state maintained by
    /// `draw`; the window sticks and only scrolls when the highlight
    /// leaves it.
    offset: usize = 0,
    /// Style for unselected items.
    style: Style = .{},
    /// Style for the highlighted item (default: reverse video).
    selected_style: Style = .{ .attrs = .{ .reverse = true } },
    /// Style for the box.
    border_style: Style = .{},
    /// Marker written where an item was cut; null = no marker.
    ellipsis: ?[]const u8 = "…",

    /// A list never animates; `advance` is always false.
    pub fn advance(self: *Select, now: Clock) bool {
        _ = self;
        _ = now;
        return false;
    }

    /// The highlighted index, or null when there are no items. The
    /// stored value is clamped, so the result is always a valid index.
    pub fn selected(self: *const Select) ?usize {
        if (self.items.len == 0) return null;
        return @min(self.cursor, self.items.len - 1);
    }

    /// Move the highlight by `delta` items, CLAMPED to the item
    /// range: a step past either end lands on that end. A magnitude
    /// longer than one lap is treated as exactly one lap, so no
    /// intermediate can overflow. An empty list is a no-op.
    pub fn move(self: *Select, delta: isize) void {
        const n = self.items.len;
        if (n == 0) return;
        const cur: usize = @min(self.cursor, n - 1);
        const mag: usize = @min(@abs(delta), n);
        const next: usize = if (delta < 0)
            (if (mag > cur) 0 else cur - mag)
        else
            @min(cur + mag, n - 1);
        self.cursor = next;
    }

    /// Move the highlight by `delta` items, WRAPPING at both ends: up
    /// from the first item lands on the last and down from the last
    /// lands on the first. Longer steps take their remainder, so
    /// `wrapBy(1001)` over five items moves by one.
    pub fn wrapBy(self: *Select, delta: isize) void {
        const n = self.items.len;
        if (n == 0) return;
        const cur: usize = @min(self.cursor, n - 1);
        const rem: usize = @abs(delta) % n;
        const next: usize = if (delta < 0)
            (if (rem > cur) n - (rem - cur) else cur - rem)
        else blk: {
            const sum = cur + rem; // both < n, so sum < 2n
            break :blk if (sum >= n) sum - n else sum;
        };
        self.cursor = next;
    }

    /// Feed one input event. Returns true when the event was consumed:
    /// a navigation key, a digit jump, enter or escape. A digit at or
    /// past the item count, and any other key, is left for the app.
    /// A closed picker accepts nothing but enter and escape, so a
    /// leftover event cannot reopen navigation by accident.
    pub fn key(self: *Select, ev: Event) !bool {
        return switch (ev) {
            .key_press => |k| self.keyPress(k),
            else => false,
        };
    }

    /// One-call approval prompt: feed events in, act when the picker
    /// closes. Enter returns the selected index, escape returns null,
    /// and a navigation key returns null with the picker still open —
    /// read `open` to tell "still deciding" from "cancelled".
    pub fn resolve(self: *Select, ev: Event) !?usize {
        _ = try self.key(ev);
        if (self.open or !self.confirmed) return null;
        return self.selected();
    }

    fn keyPress(self: *Select, k: Key) bool {
        if (k.matches(Key.enter, .{}) or k.matches(Key.kp_enter, .{})) {
            self.open = false;
            self.confirmed = true;
            return true;
        }
        if (k.matches(Key.escape, .{})) {
            self.open = false;
            self.confirmed = false;
            return true;
        }
        if (!self.open) return false; // a closed picker takes no navigation
        if (self.items.len == 0) return k.matchesAny(&up_keys, .{}) or
            k.matchesAny(&down_keys, .{}) or
            k.matchesAny(&home_keys, .{}) or
            k.matchesAny(&end_keys, .{});

        if (k.matchesAny(&up_keys, .{})) {
            self.wrapBy(-1);
            return true;
        }
        if (k.matchesAny(&down_keys, .{})) {
            self.wrapBy(1);
            return true;
        }
        if (k.matchesAny(&home_keys, .{})) {
            self.cursor = 0; // in range by construction
            return true;
        }
        if (k.matchesAny(&end_keys, .{})) {
            self.cursor = self.items.len - 1;
            return true;
        }
        // A digit jumps to that 0-based index. `matchExact` keeps a
        // modified digit (ctrl-3, alt-4) out of the jump path.
        const cp = k.codepoint;
        if (cp >= '0' and cp <= '9' and k.matchExact(cp, .{})) {
            const idx: usize = cp - '0';
            if (idx < self.items.len) {
                self.cursor = idx;
                return true;
            }
            return false;
        }
        return false;
    }

    /// The first item index a `rows`-tall window should show, chosen
    /// so the highlight is inside it. The window starts where the last
    /// draw left it and only moves when the highlight would fall out.
    pub fn windowStart(self: *const Select, rows: u16) usize {
        const n = self.items.len;
        if (n == 0 or rows == 0) return 0;
        const win: usize = @min(rows, n);
        const sel = @min(self.cursor, n - 1);
        var start = @min(self.offset, n - win);
        if (sel < start) start = sel;
        if (sel >= start + win) start = sel - win + 1;
        return start;
    }

    /// Draw the framed list with its top-left at (x, y) and return the
    /// columns it occupies. The box shrinks to the columns and rows
    /// available at (x, y), scrolling so the highlight is always on
    /// screen; rows and columns past the buffer edge are dropped, and
    /// an empty list draws nothing at all. A space too small for a
    /// frame (fewer than 2 columns, or fewer than 3 rows) draws its
    /// items unframed rather than lose them to a border. Every option
    /// is filtered on its own, so a sequence in one item cannot consume
    /// the next, and the ellipsis marks a cut measured on the text that
    /// survives. Never allocates.
    pub fn draw(self: *Select, buf: *Buffer, x: u16, y: u16, now: Clock) !u16 {
        _ = self.advance(now);
        const avail_w: u16 = buf.width -| x;
        const avail_h: u16 = buf.height -| y;
        if (self.items.len == 0 or avail_w == 0 or avail_h == 0) return 0;
        // Clamp once, so the highlight test below compares against a
        // real index even when the app assigned the field directly.
        self.cursor = @min(self.cursor, self.items.len - 1);

        // A frame costs 2 columns and 2 rows, and a framed box with no
        // interior row is pointless, so anything narrower than 2x3
        // draws its items bare.
        const framed: bool = avail_w >= 2 and avail_h >= 3;
        const pad: u16 = if (framed) 1 else 0;
        const outer_w: u16 = @min(self.width, avail_w);
        const inner_w: u16 = outer_w -| 2 * pad;
        const rows: u16 = @min(avail_h -| 2 * pad, narrow(self.items.len));
        if (rows == 0) return 0;

        const start = self.windowStart(rows);
        self.offset = start;
        if (framed) try drawFrame(buf, self.border_style, x, y, outer_w, rows + 2);

        const y0: u16 = y + pad;
        const x0: u16 = x + pad;
        const marker = self.ellipsis orelse "";
        // The marker is untrusted text too: reserve what the filter
        // leaves of it, or a marker carrying an escape would claim
        // columns the marker's real glyphs never fill.
        const marker_w: u16 = narrow(textWidth(marker, x0, inner_w));
        var row: u16 = 0;
        while (row < rows) : (row += 1) {
            const idx: usize = start + @as(usize, row);
            const text = self.items[idx];
            const st = if (idx == self.cursor) self.selected_style else self.style;
            const by = y0 + row;
            // Each option is its own label, so each starts armed down:
            // a sequence in one item cannot swallow the next item's
            // text. The cut is decided by the filtered walk below, on
            // the graphemes that reach cells.
            var san: markdown.Sanitizer = .{};
            _ = try drawBounded(buf, &san, st, text, x0, by, inner_w, marker, marker_w);
        }
        return outer_w;
    }
};

const up_keys = [_]u21{ Key.up, Key.kp_up, 'k' };
const down_keys = [_]u21{ Key.down, Key.kp_down, 'j' };
const home_keys = [_]u21{ Key.home, Key.kp_home };
const end_keys = [_]u21{ Key.end, Key.kp_end };

/// A box with a title, a body and a footer, centred in the space the
/// buffer gives it. Text is BORROWED; `draw` allocates nothing.
///
/// The box SHRINKS to the available columns and rows instead of
/// overflowing, and the row budget drops content least-important
/// first: a field keeps its row only when it has text, so the title
/// takes its row, the footer keeps its row whenever there is one to
/// spare, and the body takes what is left (so a box one row tall
/// shows the title and nothing else). A space too small for a border
/// shows the title bare. A zero-sized buffer draws nothing.
pub const Modal = struct {
    title: []const u8 = "",
    /// Body text; '\n' starts a new row inside the box.
    body: []const u8 = "",
    footer: []const u8 = "",
    /// Preferred outer size, clamped down to what the buffer has.
    width: u16 = 40,
    height: u16 = 10,
    /// Style for the body text, and for the title when the box has no
    /// room for a border.
    style: Style = .{},
    title_style: Style = .{ .attrs = .{ .bold = true } },
    footer_style: Style = .{},
    border_style: Style = .{},

    /// A modal never animates; `advance` is always false.
    pub fn advance(self: *Modal, now: Clock) bool {
        _ = self;
        _ = now;
        return false;
    }

    /// Draw the box centred in the rectangle from (x, y) to the
    /// buffer's edge, and return the columns it occupies. The title,
    /// body and footer are truncated at a grapheme boundary to the
    /// box's interior; nothing is written outside the buffer, and
    /// `buf` with no room at all draws nothing. Each of the three is a
    /// separate field: an escape in the title cannot consume the body,
    /// while the body's rows share one filter, so a sequence split
    /// over a row break is consumed whole. Never allocates.
    pub fn draw(self: *Modal, buf: *Buffer, x: u16, y: u16, now: Clock) !u16 {
        _ = self.advance(now);
        const avail_w: u16 = buf.width -| x;
        const avail_h: u16 = buf.height -| y;
        if (avail_w == 0 or avail_h == 0) return 0;

        // Shrink to fit, then centre what is left in the space that
        // remains: a box bigger than the buffer becomes the buffer.
        const outer_w: u16 = @min(self.width, avail_w);
        const outer_h: u16 = @min(self.height, avail_h);
        const x0: u16 = x + (avail_w - outer_w) / 2;
        const y0: u16 = y + (avail_h - outer_h) / 2;
        if (outer_w < 2 or outer_h < 2) {
            var san: markdown.Sanitizer = .{};
            return drawBounded(buf, &san, self.style, self.firstLine(), x0, y0, outer_w, "", 0);
        }

        try drawFrame(buf, self.border_style, x0, y0, outer_w, outer_h);
        const inner_w: u16 = outer_w - 2;
        const inner_h: u16 = outer_h - 2;
        if (inner_w == 0 or inner_h == 0) return outer_w;

        // Row budget, most important first: the title, then the body,
        // then the footer. A field with no text keeps no row: an
        // untitled box gives its first interior row to the body, the
        // way `firstLine` gives it to the title when there is no body.
        const has_title: bool = self.title.len > 0;
        const has_footer: bool = self.footer.len > 0 and inner_h >= 2;
        var title_san: markdown.Sanitizer = .{};
        _ = try drawBounded(
            buf,
            &title_san,
            self.title_style,
            self.title,
            x0 + 1,
            y0 + 1,
            inner_w,
            "",
            0,
        );
        const body_y: u16 = y0 + 1 + @as(u16, @intFromBool(has_title));
        const body_rows: u16 = inner_h -| @as(u16, @intFromBool(has_title)) -|
            @as(u16, @intFromBool(has_footer));
        // The body is one field spread over rows: one filter for all of
        // them, so `ESC ] 0;title` on one row swallows its payload on
        // the next instead of leaking half a sequence into a cell.
        var body_san: markdown.Sanitizer = .{};
        var lines = std.mem.splitScalar(u8, self.body, '\n');
        var row: u16 = 0;
        while (lines.next()) |line| {
            if (row >= body_rows) break;
            _ = try drawBounded(
                buf,
                &body_san,
                self.style,
                line,
                x0 + 1,
                body_y + row,
                inner_w,
                "",
                0,
            );
            row += 1;
        }
        if (has_footer) {
            const fy: u16 = y0 + outer_h - 2;
            var footer_san: markdown.Sanitizer = .{};
            _ = try drawBounded(
                buf,
                &footer_san,
                self.footer_style,
                self.footer,
                x0 + 1,
                fy,
                inner_w,
                "",
                0,
            );
        }
        return outer_w;
    }

    /// The one line a box with no room for a border shows: the title,
    /// or the body's first line when there is no title.
    fn firstLine(self: *const Modal) []const u8 {
        if (self.title.len > 0) return self.title;
        if (self.body.len == 0) return self.footer;
        const nl = std.mem.indexOfScalar(u8, self.body, '\n') orelse return self.body;
        return self.body[0..nl];
    }
};

/// A box anchored to a point, for transient content the app draws
/// over the band (a hovered detail, a context menu). Lines are
/// BORROWED; `draw` allocates nothing.
///
/// The anchor is CLAMPED into the buffer: a point past the right or
/// bottom edge slides the box back until it fits whole. The box never
/// wraps around to the far side, so an anchor that could not fit on
/// its preferred side is still readable in place. Content lines are
/// drawn top-down into the interior, cut at a grapheme boundary when
/// they overrun it.
pub const Popover = struct {
    /// Preferred outer width, clamped to the buffer width.
    width: u16 = 24,
    /// Preferred outer height; 0 = fit the content (two border rows
    /// plus one row per line). Clamped to the buffer height.
    height: u16 = 0,
    /// Content lines, borrowed.
    lines: []const []const u8 = &.{},
    style: Style = .{},
    border_style: Style = .{},

    /// A popover never animates; `advance` is always false.
    pub fn advance(self: *Popover, now: Clock) bool {
        _ = self;
        _ = now;
        return false;
    }

    /// Draw the box anchored at (x, y) and return the columns it
    /// occupies. A space with no room for a border (fewer than 2
    /// columns or 2 rows) draws nothing. Every line is its own field,
    /// so a sequence in one line never consumes the next. Never
    /// allocates.
    pub fn draw(self: *Popover, buf: *Buffer, x: u16, y: u16, now: Clock) !u16 {
        _ = self.advance(now);
        const outer_w: u16 = @min(self.width, buf.width);
        const want: u16 = if (self.height == 0) narrow(self.lines.len + 2) else self.height;
        const outer_h: u16 = @min(want, buf.height);
        if (outer_w < 2 or outer_h < 2) return 0;

        // Clamp, never wrap: buf.width - outer_w cannot underflow
        // because outer_w is already capped at buf.width.
        const x0: u16 = @min(x, buf.width - outer_w);
        const y0: u16 = @min(y, buf.height - outer_h);
        try drawFrame(buf, self.border_style, x0, y0, outer_w, outer_h);

        const inner_w: u16 = outer_w - 2;
        const inner_h: u16 = outer_h - 2;
        const rows: u16 = @min(inner_h, narrow(self.lines.len));
        const x0i: u16 = x0 + 1;
        const y0i: u16 = y0 + 1;
        var row: u16 = 0;
        while (row < rows) : (row += 1) {
            var san: markdown.Sanitizer = .{};
            _ = try drawBounded(
                buf,
                &san,
                self.style,
                self.lines[row],
                x0i,
                y0i + row,
                inner_w,
                "",
                0,
            );
        }
        return outer_w;
    }
};

/// Narrow a count to u16, saturating. Item and line counts can exceed
/// the buffer's cell count, and the answer is always "as many as the
/// buffer can show", so a saturation is exact, not a guess.
fn narrow(v: usize) u16 {
    return if (v > std.math.maxInt(u16)) std.math.maxInt(u16) else @intCast(v);
}

/// Write one single-cell grapheme. `Buffer.set` drops an out-of-bounds
/// target, so a box clipped by a band edge loses its far side instead
/// of wrapping.
fn put(buf: *Buffer, style: Style, glyph: []const u8, x: u16, y: u16) !void {
    try buf.set(x, y, .{ .grapheme = glyph, .style = style });
}

/// Draw a `w` x `h` box with its top-left corner at (x, y). Anything
/// outside the buffer is dropped by `Buffer.set`. A box under 2x2 has
/// no interior and draws nothing.
fn drawFrame(buf: *Buffer, style: Style, x: u16, y: u16, w: u16, h: u16) !void {
    if (w < 2 or h < 2) return;
    const right: u16 = x + (w - 1);
    const bottom: u16 = y + (h - 1);
    try put(buf, style, Glyphs.top_left, x, y);
    try put(buf, style, Glyphs.top_right, right, y);
    try put(buf, style, Glyphs.bottom_left, x, bottom);
    try put(buf, style, Glyphs.bottom_right, right, bottom);
    var col: u16 = x + 1;
    while (col < right) : (col += 1) {
        try put(buf, style, Glyphs.horizontal, col, y);
        try put(buf, style, Glyphs.horizontal, col, bottom);
    }
    var row: u16 = y + 1;
    while (row < bottom) : (row += 1) {
        try put(buf, style, Glyphs.vertical, x, row);
        try put(buf, style, Glyphs.vertical, right, row);
    }
}

/// Draw `text` at (x, y) in at most `max_cols` columns, grapheme-aware
/// and escape-filtered, and return the columns written.
///
/// The same rules as `Buffer.draw` — zero-width clusters advance no
/// column, a cluster that would cross the budget drops whole and ends
/// the run — except the budget is the caller's, not the buffer edge.
/// That is what keeps an item from spilling over a frame's right
/// border. Never allocates: cells borrow their graphemes from `text`.
///
/// `san` is the filter's state, held by the caller: it carries from one
/// call to the next only where one field spans them (a modal body's
/// rows). Every cluster is offered to it BEFORE it is measured or
/// stored, so no sequence body, control byte or invalid byte reaches a
/// cell, and a refused cluster still advances the machine. Tab and
/// newline are the only control scalars it admits; a tab expands to
/// spaces up to the next stop and a line break drops, since one call
/// paints one row and neither byte may sit in a cell.
///
/// Text that overruns the budget is cut at a grapheme boundary. When
/// `marker` is non-empty the cut leaves `marker_w` columns free at the
/// right edge and the marker goes there — decided by this walk, on the
/// filtered text, so an item that fits is never shortened for a marker
/// it does not need and an item that only overruns because of dropped
/// bytes is not cut at all.
fn drawBounded(
    buf: *Buffer,
    san: *markdown.Sanitizer,
    style: Style,
    text: []const u8,
    x: u16,
    y: u16,
    max_cols: u16,
    marker: []const u8,
    marker_w: u16,
) !u16 {
    if (max_cols == 0 or y >= buf.height) return 0;
    const budget: u16 = max_cols -| marker_w;
    var col: u16 = 0;
    var off: usize = 0;
    var cut = false;
    while (off < text.len) {
        const glen = Width.firstGraphemeLen(text[off..]);
        // No cluster here at all (an unformable byte): step one byte so
        // the rest of the field still draws, and let the machine drop
        // it — the same verdict `sanitize` gives that byte.
        const gc = if (glen == 0) text[off..][0..1] else text[off..][0..glen];
        off += gc.len;
        if (!san.acceptCluster(gc)) continue;

        if (gc.len == 1 and gc[0] == '\t') {
            var n = tab_width - (@as(usize, x) + @as(usize, col)) % tab_width;
            while (n > 0 and col < budget) : (n -= 1) {
                try buf.set(x + col, y, .{ .grapheme = " ", .style = style });
                col += 1;
            }
            continue;
        }
        if (gc.len == 1 and gc[0] == '\n') continue; // one call, one row

        const cw = Width.graphemeWidth(gc);
        if (cw <= 0) continue; // zero-width: advance no column
        const cwu: u16 = if (cw >= 2) 2 else 1;
        if (@as(u32, col) + cwu > budget) {
            cut = true; // over budget: drop the rest
            break;
        }
        try buf.set(x +| col, y, .{ .grapheme = gc, .style = style });
        col += cwu;
    }
    if (cut and marker_w > 0) {
        // The marker is the app's own field: its own machine, so what
        // the marker ends with cannot eat the field drawn after it.
        var marker_san: markdown.Sanitizer = .{};
        _ = try drawBounded(
            buf,
            &marker_san,
            style,
            marker,
            x + max_cols - marker_w,
            y,
            marker_w,
            "",
            0,
        );
    }
    return col;
}

/// Columns `text` occupies after the filter, starting at column `x0`
/// and saturating at `cap`. Measures exactly the clusters
/// `drawBounded` keeps — tabs expanded, line breaks and refused
/// clusters dropped, a wide glyph two columns — so a reservation cut
/// on it matches what reaches the cells.
fn textWidth(text: []const u8, x0: u16, cap: usize) usize {
    var san: markdown.Sanitizer = .{};
    var width: usize = 0;
    var off: usize = 0;
    while (off < text.len and width < cap) {
        const glen = Width.firstGraphemeLen(text[off..]);
        const gc = if (glen == 0) text[off..][0..1] else text[off..][0..glen];
        off += gc.len;
        if (!san.acceptCluster(gc)) continue;
        if (gc.len == 1 and gc[0] == '\t') {
            width += tab_width - (@as(usize, x0) + width) % tab_width;
            continue;
        }
        const cw = Width.graphemeWidth(gc);
        if (cw <= 0) continue;
        width += if (cw >= 2) @as(usize, 2) else 1;
    }
    return @min(width, cap);
}

test {
    std.testing.refAllDecls(@This());
}

const test_alloc = std.testing.allocator;
const at0: Clock = .fromNanoseconds(0);

/// Concatenate one row's graphemes into `out` (wide continuations
/// emit nothing, matching the renderer) so a test can compare a drawn
/// box as text. Every cell of the row is emitted, blanks included: a
/// test compares the whole row, padding and all.
///
/// `out` must hold the whole row: a cell is one grapheme of up to four
/// bytes, so four times `buf.width` always suffices. A row that does
/// not fit returns a marker instead of a truncated prefix, so an
/// undersized buffer fails the assertion it was handed to instead of
/// quietly passing it.
fn rowStr(buf: *const Buffer, y: usize, out: []u8) []const u8 {
    var n: usize = 0;
    var x: usize = 0;
    while (x < buf.width) : (x += 1) {
        const cell = buf.get(@intCast(x), @intCast(y));
        if (cell.wide) continue; // covered by the lead's column
        const piece: []const u8 = if (cell.grapheme.len == 0) " " else cell.grapheme;
        if (n + piece.len > out.len) return "row too long for its buffer";
        @memcpy(out[n..][0..piece.len], piece);
        n += piece.len;
    }
    return out[0..n];
}

/// A bare `key_press` with no modifiers: what the parser hands an app
/// for a plain letter, arrow or escape.
fn press(cp: u21) Event {
    return .{ .key_press = .{ .codepoint = cp } };
}

/// The real band, for the injection tests. Piped output carries no
/// escape sequences of its own, so any control byte in a rendered
/// frame is one that arrived from a caller's text.
const Region = @import("../region.zig").Region;

/// Fixed-buffer writer for the frame tests. `init` must run in place —
/// the writer borrows `buf`, so the struct must not move afterwards
/// (same pattern as `src/buffer.zig`).
const TestWriter = struct {
    buf: [4096]u8 = undefined,
    w: std.Io.Writer = undefined,

    fn init(self: *TestWriter) void {
        self.w = .fixed(&self.buf);
    }
};

/// Fail when any cell in the band carries a byte no grapheme may
/// contain: a C0 control, DEL or invalid UTF-8. A wide continuation
/// holds no bytes by design, so it is skipped. The escape machine
/// admits only tab (expanded to spaces) and newline (dropped), so a
/// cell that trips this rule took a byte straight from the caller's
/// text.
fn expectNoControlCells(buf: *const Buffer) !void {
    for (0..buf.height) |y| {
        for (0..buf.width) |x| {
            const cell = buf.get(@intCast(x), @intCast(y));
            if (cell.wide) continue;
            for (cell.grapheme) |b| {
                try std.testing.expect(b >= 0x20 and b != 0x7F);
            }
            try std.testing.expect(std.unicode.utf8ValidateSlice(cell.grapheme));
        }
    }
}

const ten = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" };

// Select: motion.

test "select: move clamps to the item range at both ends" {
    const items = [_][]const u8{ "a", "b", "c" };
    var s: Select = .{ .items = &items };
    s.move(5);
    try std.testing.expectEqual(@as(usize, 2), s.selected().?);
    s.move(-5);
    try std.testing.expectEqual(@as(usize, 0), s.selected().?);
    s.move(1);
    try std.testing.expectEqual(@as(usize, 1), s.selected().?);
    s.move(1);
    try std.testing.expectEqual(@as(usize, 2), s.selected().?);
    s.move(1);
    try std.testing.expectEqual(@as(usize, 2), s.selected().?); // stays at the end

    // A one-item list can never leave its item, in either direction.
    var one: Select = .{ .items = items[0..1] };
    one.move(7);
    try std.testing.expectEqual(@as(usize, 0), one.selected().?);
    one.move(-7);
    try std.testing.expectEqual(@as(usize, 0), one.selected().?);
}

test "select: wrapBy wraps at both ends and takes the remainder" {
    const items = [_][]const u8{ "a", "b", "c", "d", "e" };
    var s: Select = .{ .items = &items, .cursor = 0 };
    s.wrapBy(-1);
    try std.testing.expectEqual(@as(usize, 4), s.selected().?); // up wraps to the end
    s.wrapBy(1);
    try std.testing.expectEqual(@as(usize, 0), s.selected().?); // down wraps to the start
    s.wrapBy(3);
    try std.testing.expectEqual(@as(usize, 3), s.selected().?);
    // Longer steps wrap by their remainder, not by their magnitude.
    s.wrapBy(1001);
    try std.testing.expectEqual(@as(usize, 4), s.selected().?); // 3 + 1001 == 4 mod 5
    s.wrapBy(-1003);
    try std.testing.expectEqual(@as(usize, 1), s.selected().?); // 4 - 1003 == 1 mod 5
}

test "select: an out-of-range stored index never escapes the items" {
    const items = [_][]const u8{ "a", "b" };
    var s: Select = .{ .items = &items, .cursor = 99 };
    try std.testing.expectEqual(@as(usize, 1), s.selected().?);
    // The window covers both items, so it starts at 0 however high the
    // raw field is.
    try std.testing.expectEqual(@as(usize, 0), s.windowStart(2));
    var buf = try Buffer.init(test_alloc, 6, 3);
    defer buf.deinit();
    _ = try s.draw(&buf, 0, 0, at0);
    var row: [32]u8 = undefined;
    try std.testing.expectEqualStrings("│b   │", rowStr(&buf, 1, &row));
    try std.testing.expect(buf.get(1, 1).style.eql(s.selected_style));
    // The draw clamped the field itself, so the next frame agrees.
    try std.testing.expectEqual(@as(usize, 1), s.cursor);
}

test "select: an empty list has no selection, moves nothing and draws nothing" {
    var s: Select = .{};
    var buf = try Buffer.init(test_alloc, 8, 4);
    defer buf.deinit();

    try std.testing.expect(s.selected() == null);
    s.move(1);
    s.wrapBy(-1);
    try std.testing.expect(s.selected() == null);
    try std.testing.expectEqual(@as(u16, 0), try s.draw(&buf, 0, 0, at0));
    for (0..4) |y| {
        for (0..8) |x| {
            try std.testing.expect(buf.get(@intCast(x), @intCast(y)).eql(.{}));
        }
    }
    // Navigation is still consumed so a caller can close an empty
    // picker, but there is no index to return.
    try std.testing.expect(try s.key(press('j')));
    try std.testing.expect(s.open);
    try std.testing.expect(try s.resolve(press(Key.enter)) == null);
    try std.testing.expect(!s.open);
    try std.testing.expect(s.selected() == null);
}

// Select: keys.

test "select: key navigates, wraps and jumps" {
    var s: Select = .{ .items = &ten };
    try std.testing.expect(try s.key(press(Key.down)));
    try std.testing.expectEqual(@as(usize, 1), s.selected().?);
    try std.testing.expect(try s.key(press('j')));
    try std.testing.expectEqual(@as(usize, 2), s.selected().?);
    try std.testing.expect(try s.key(press('k')));
    try std.testing.expectEqual(@as(usize, 1), s.selected().?);
    try std.testing.expect(try s.key(press(Key.up)));
    try std.testing.expectEqual(@as(usize, 0), s.selected().?);
    // Up from the first item wraps to the last.
    try std.testing.expect(try s.key(press('k')));
    try std.testing.expectEqual(@as(usize, 9), s.selected().?);
    try std.testing.expect(try s.key(press(Key.end)));
    try std.testing.expectEqual(@as(usize, 9), s.selected().?);
    try std.testing.expect(try s.key(press(Key.home)));
    try std.testing.expectEqual(@as(usize, 0), s.selected().?);
    // A digit jumps to that 0-based index.
    try std.testing.expect(try s.key(press('7')));
    try std.testing.expectEqual(@as(usize, 7), s.selected().?);
    try std.testing.expect(try s.key(press('0')));
    try std.testing.expectEqual(@as(usize, 0), s.selected().?);
    // A digit past the end is not the picker's to handle, and the
    // highlight must not move. `ten` holds ten items, so index 5 is a
    // valid jump there: a five-item list is what puts it past the end.
    const five = [_][]const u8{ "0", "1", "2", "3", "4" };
    s.items = &five;
    const past_end = try s.key(press('5'));
    try std.testing.expect(!past_end);
    try std.testing.expectEqual(@as(usize, 0), s.selected().?);
    s.cursor = 4;
    const still_past = try s.key(press('5'));
    try std.testing.expect(!still_past);
    try std.testing.expectEqual(@as(usize, 4), s.selected().?);
}

test "select: a modified key is not a navigation key" {
    var s: Select = .{ .items = &ten };
    // A modified letter or digit is not a jump: `matchExact` keeps
    // the modifiers out.
    const ctrl_j: Event = .{ .key_press = .{ .codepoint = 'j', .mods = .{ .ctrl = true } } };
    try std.testing.expect(!try s.key(ctrl_j));
    const alt_3: Event = .{ .key_press = .{ .codepoint = '3', .mods = .{ .alt = true } } };
    try std.testing.expect(!try s.key(alt_3));
    try std.testing.expectEqual(@as(usize, 0), s.selected().?);
    // Events that are not key presses are ignored.
    try std.testing.expect(!try s.key(.focus_in));
    const resized: Event = .{ .winsize = .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 } };
    try std.testing.expect(!try s.key(resized));
    try std.testing.expect(try s.key(press('j')));
    try std.testing.expectEqual(@as(usize, 1), s.selected().?);
}

test "select: a closed picker stops navigating until the app reopens it" {
    var s: Select = .{ .items = &ten, .cursor = 5 };
    try std.testing.expect(try s.key(press(Key.escape)));
    try std.testing.expect(!s.open);
    const nav = try s.key(press('j'));
    try std.testing.expect(!nav);
    const jump = try s.key(press('4'));
    try std.testing.expect(!jump);
    try std.testing.expectEqual(@as(usize, 5), s.selected().?);
    // The app reopens it by clearing the decision fields.
    s.open = true;
    s.confirmed = false;
    try std.testing.expect(try s.key(press('j')));
    try std.testing.expectEqual(@as(usize, 6), s.selected().?);
}

test "select: resolve turns enter into the index and escape into null" {
    var s: Select = .{ .items = &ten };
    // Navigation is not a decision: null, and the picker stays open.
    try std.testing.expect(try s.resolve(press('3')) == null);
    try std.testing.expect(s.open);
    try std.testing.expectEqual(@as(usize, 3), s.selected().?);
    try std.testing.expect(try s.resolve(press('j')) == null);
    try std.testing.expect(s.open);
    // Enter confirms the highlighted item and closes.
    try std.testing.expectEqual(@as(?usize, 4), try s.resolve(press(Key.enter)));
    try std.testing.expect(!s.open);
    try std.testing.expect(s.confirmed);

    var cancelled: Select = .{ .items = &ten, .cursor = 2 };
    try std.testing.expect(try cancelled.resolve(press(Key.escape)) == null);
    try std.testing.expect(!cancelled.open);
    try std.testing.expect(!cancelled.confirmed);
    // The highlight survives a cancel, for a prompt that re-opens.
    try std.testing.expectEqual(@as(usize, 2), cancelled.selected().?);
}

// Select: draw.

test "select: a 3-row box scrolls so the highlight is always the drawn item" {
    var s: Select = .{ .items = &ten, .width = 4 };
    var buf = try Buffer.init(test_alloc, 4, 3);
    defer buf.deinit();
    var row: [32]u8 = undefined;

    var i: usize = 0;
    while (i < ten.len) : (i += 1) {
        if (i > 0) s.move(1);
        try std.testing.expectEqual(@as(u16, 4), try s.draw(&buf, 0, 0, at0));
        // The frame holds: the one interior row carries the selection
        // and nothing leaks onto the border rows.
        try std.testing.expectEqualStrings("┌──┐", rowStr(&buf, 0, &row));
        try std.testing.expectEqualStrings("└──┘", rowStr(&buf, 2, &row));
        try std.testing.expectEqualStrings("│", buf.get(0, 1).grapheme);
        try std.testing.expectEqualStrings("│", buf.get(3, 1).grapheme);
        try std.testing.expectEqualStrings(ten[i], buf.get(1, 1).grapheme);
        try std.testing.expect(buf.get(1, 1).style.eql(s.selected_style));
    }
}

test "select: the window sticks and only scrolls when the highlight leaves it" {
    var s: Select = .{ .items = &ten, .width = 4 };
    // 7 rows: 2 of frame leave a 5-row window over 10 items.
    var buf = try Buffer.init(test_alloc, 4, 7);
    defer buf.deinit();
    var row: [32]u8 = undefined;

    // The highlight is inside the window, so the window holds still.
    s.move(2);
    _ = try s.draw(&buf, 0, 0, at0);
    try std.testing.expectEqual(@as(usize, 0), s.offset);
    try std.testing.expectEqualStrings("│0 │", rowStr(&buf, 1, &row));
    try std.testing.expectEqualStrings("│4 │", rowStr(&buf, 5, &row));

    // One step past the last visible row scrolls by exactly one.
    s.move(3);
    _ = try s.draw(&buf, 0, 0, at0);
    try std.testing.expectEqual(@as(usize, 1), s.offset);
    try std.testing.expectEqualStrings("│1 │", rowStr(&buf, 1, &row));
    try std.testing.expectEqualStrings("│5 │", rowStr(&buf, 5, &row));

    // The highlight is above the window now, so the window snaps to it.
    s.move(-5);
    _ = try s.draw(&buf, 0, 0, at0);
    try std.testing.expectEqual(@as(usize, 0), s.offset);
    try std.testing.expectEqualStrings("│0 │", rowStr(&buf, 1, &row));
    try std.testing.expectEqualStrings("│4 │", rowStr(&buf, 5, &row));

    // The end of the list pins the window to the last full page.
    s.move(20);
    _ = try s.draw(&buf, 0, 0, at0);
    try std.testing.expectEqual(@as(usize, 5), s.offset);
    try std.testing.expectEqualStrings("│5 │", rowStr(&buf, 1, &row));
    try std.testing.expectEqualStrings("│9 │", rowStr(&buf, 5, &row));

    // Walking back up holds the window while the highlight stays in it.
    s.move(-1);
    _ = try s.draw(&buf, 0, 0, at0);
    try std.testing.expectEqual(@as(usize, 5), s.offset);
    try std.testing.expectEqualStrings("│5 │", rowStr(&buf, 1, &row));
    try std.testing.expectEqualStrings("│9 │", rowStr(&buf, 5, &row));

    // One more row up and the window follows the highlight.
    s.move(-4);
    _ = try s.draw(&buf, 0, 0, at0);
    try std.testing.expectEqual(@as(usize, 4), s.offset);
    try std.testing.expectEqualStrings("│4 │", rowStr(&buf, 1, &row));
    try std.testing.expectEqualStrings("│8 │", rowStr(&buf, 5, &row));
}

test "select: an item is cut at a grapheme boundary inside the frame" {
    const items = [_][]const u8{ "0123456789abcdef", "ab👨‍🌾cd" };
    var s: Select = .{ .items = &items, .width = 7 };
    var buf = try Buffer.init(test_alloc, 7, 3);
    defer buf.deinit();
    var row: [32]u8 = undefined;

    _ = try s.draw(&buf, 0, 0, at0);
    // Interior 5 wide, marker 1: "0123" then the marker, frame intact.
    try std.testing.expectEqualStrings("┌─────┐", rowStr(&buf, 0, &row));
    try std.testing.expectEqualStrings("│0123…│", rowStr(&buf, 1, &row));

    // The family emoji is two cells: it either fits whole or drops
    // whole, and the right border is never overwritten.
    buf.clear();
    s.cursor = 1;
    _ = try s.draw(&buf, 0, 0, at0);
    try std.testing.expectEqualStrings("│ab👨‍🌾…│", rowStr(&buf, 1, &row));
    try std.testing.expectEqualStrings("│", buf.get(6, 1).grapheme);
    // The wide glyph's continuation cell belongs to it and emits no
    // text of its own.
    try std.testing.expect(buf.get(4, 1).wide);
    try std.testing.expectEqualStrings("", buf.get(4, 1).grapheme);
}

test "select: the box clips to the buffer instead of drawing past it" {
    const items = [_][]const u8{ "abcdefghij", "second" };
    var s: Select = .{ .items = &items, .width = 20, .ellipsis = null };
    var buf = try Buffer.init(test_alloc, 8, 4);
    defer buf.deinit();
    var row: [64]u8 = undefined;

    // Three columns left at x = 5: the box is exactly those three, and
    // each item is cut to the one interior column.
    const w = try s.draw(&buf, 5, 0, at0);
    try std.testing.expectEqual(@as(u16, 3), w);
    try std.testing.expectEqualStrings("     ┌─┐", rowStr(&buf, 0, &row));
    try std.testing.expectEqualStrings("     │a│", rowStr(&buf, 1, &row));
    try std.testing.expectEqualStrings("     │s│", rowStr(&buf, 2, &row));
    try std.testing.expectEqualStrings("     └─┘", rowStr(&buf, 3, &row));

    // Two rows left at y = 2: no room for a frame, so the items draw
    // bare into what is left and nothing reaches rows 0 and 1.
    buf.clear();
    s.cursor = 1;
    try std.testing.expectEqual(@as(u16, 8), try s.draw(&buf, 0, 2, at0));
    try std.testing.expectEqualStrings("        ", rowStr(&buf, 0, &row));
    try std.testing.expectEqualStrings("        ", rowStr(&buf, 1, &row));
    try std.testing.expectEqualStrings("abcdefgh", rowStr(&buf, 2, &row));
    try std.testing.expectEqualStrings("second  ", rowStr(&buf, 3, &row));

    // A draw position past the last cell has no room at all.
    try std.testing.expectEqual(@as(u16, 0), try s.draw(&buf, 8, 0, at0));
    try std.testing.expectEqual(@as(u16, 0), try s.draw(&buf, 0, 4, at0));
}

test "select: the cut follows the filtered width, not the raw byte count" {
    // Interior 5, marker 1: the text budget is 4 columns, and it is
    // measured on what the filter leaves behind.
    const items = [_][]const u8{
        "ab\x1b[31mc\xffd", // filtered to "abcd": exactly the budget
        "ab\x1b[31mcd\xffe", // filtered to "abcde": one column over
    };
    var s: Select = .{ .items = &items, .width = 7 };
    var buf = try Buffer.init(test_alloc, 7, 4);
    defer buf.deinit();
    var row: [32]u8 = undefined;

    // Four columns fit a 5-column interior: no marker is drawn, and the
    // invalid byte is gone rather than counted as a column of its own.
    _ = try s.draw(&buf, 0, 0, at0);
    try std.testing.expectEqualStrings("│abcd │", rowStr(&buf, 1, &row));
    try expectNoControlCells(&buf);

    // Five do not: the cut lands on a grapheme boundary and the marker
    // takes the column the cut left free at the right edge.
    buf.clear();
    s.cursor = 1;
    _ = try s.draw(&buf, 0, 0, at0);
    try std.testing.expectEqualStrings("│abcd…│", rowStr(&buf, 2, &row));
    try expectNoControlCells(&buf);
}

test "select: a wide glyph is cut on the filtered stream" {
    // The colour change ahead of the family emoji contributes no
    // column, so the cut still falls where the visible text ends.
    const items = [_][]const u8{"ab\x1b[31m👨‍🌾cd"};
    var s: Select = .{ .items = &items, .width = 7 };
    var buf = try Buffer.init(test_alloc, 7, 3);
    defer buf.deinit();
    var row: [32]u8 = undefined;

    _ = try s.draw(&buf, 0, 0, at0);
    try std.testing.expectEqualStrings("│ab👨‍🌾…│", rowStr(&buf, 1, &row));
    // The emoji keeps both of its columns; the marker took the next.
    try std.testing.expect(buf.get(4, 1).wide);
    try std.testing.expectEqualStrings("", buf.get(4, 1).grapheme);
    try expectNoControlCells(&buf);
}

test "select: an option's sequence does not swallow the next option" {
    // Each option is its own label. This one ends inside an
    // unterminated OSC, and the next option still draws its text.
    const items = [_][]const u8{ "a\x1b]0;owned", "b" };
    var s: Select = .{ .items = &items, .width = 6 };
    var buf = try Buffer.init(test_alloc, 6, 4);
    defer buf.deinit();
    var row: [32]u8 = undefined;

    _ = try s.draw(&buf, 0, 0, at0);
    try std.testing.expectEqualStrings("│a   │", rowStr(&buf, 1, &row));
    try std.testing.expectEqualStrings("│b   │", rowStr(&buf, 2, &row));
    try expectNoControlCells(&buf);
}

test "select: index, confirm and cancel survive the options shrinking" {
    var s: Select = .{ .items = &ten, .width = 4 };
    var buf = try Buffer.init(test_alloc, 4, 7);
    defer buf.deinit();
    var row: [32]u8 = undefined;

    // Walk the highlight to the end; the window follows it to the last
    // full page.
    s.wrapBy(-1);
    _ = try s.draw(&buf, 0, 0, at0);
    try std.testing.expectEqual(@as(usize, 9), s.selected().?);
    try std.testing.expectEqual(@as(usize, 5), s.offset);

    // The app rebuilds its list and three options are left. The stored
    // index is repaired and the window comes back to hold it.
    s.items = ten[0..3];
    _ = try s.draw(&buf, 0, 0, at0);
    try std.testing.expectEqual(@as(usize, 2), s.selected().?);
    try std.testing.expectEqual(@as(usize, 0), s.offset);
    try std.testing.expectEqualStrings("│2 │", rowStr(&buf, 3, &row));

    // Enter confirms an index that still names an option.
    try std.testing.expectEqual(@as(?usize, 2), try s.resolve(press(Key.enter)));
    try std.testing.expect(!s.open);
    try std.testing.expect(s.confirmed);

    // Escape cancels and keeps the highlight, for a prompt that reopens.
    var c: Select = .{ .items = &ten, .cursor = 7 };
    c.items = ten[0..2];
    _ = try c.draw(&buf, 0, 0, at0);
    try std.testing.expect(try c.resolve(press(Key.escape)) == null);
    try std.testing.expect(!c.open);
    try std.testing.expect(!c.confirmed);
    try std.testing.expectEqual(@as(usize, 1), c.selected().?);

    // Reopened on the short list, the keys still drive it and the
    // window still holds the highlight.
    c.open = true;
    c.confirmed = false;
    try std.testing.expect(try c.key(press('j'))); // wraps 1 -> 0
    _ = try c.draw(&buf, 0, 0, at0);
    try std.testing.expectEqual(@as(usize, 0), c.selected().?);
    try std.testing.expectEqualStrings("│0 │", rowStr(&buf, 1, &row));
    try std.testing.expectEqualStrings("│1 │", rowStr(&buf, 2, &row));
    try std.testing.expect(buf.get(1, 1).style.eql(c.selected_style));
}

// Modal.

test "modal: centres the box in the space it is given" {
    var m: Modal = .{
        .title = "Approve",
        .body = "run rm -rf",
        .footer = "[y] yes",
        .width = 12,
        .height = 5,
    };
    var buf = try Buffer.init(test_alloc, 20, 9);
    defer buf.deinit();
    var row: [64]u8 = undefined;

    try std.testing.expectEqual(@as(u16, 12), try m.draw(&buf, 0, 0, at0));
    // (20 - 12) / 2 = 4 across, (9 - 5) / 2 = 2 down.
    try std.testing.expectEqualStrings("                    ", rowStr(&buf, 1, &row));
    try std.testing.expectEqualStrings("    ┌──────────┐    ", rowStr(&buf, 2, &row));
    try std.testing.expectEqualStrings("    │Approve   │    ", rowStr(&buf, 3, &row));
    try std.testing.expectEqualStrings("    │run rm -rf│    ", rowStr(&buf, 4, &row));
    try std.testing.expectEqualStrings("    │[y] yes   │    ", rowStr(&buf, 5, &row));
    try std.testing.expectEqualStrings("    └──────────┘    ", rowStr(&buf, 6, &row));
    try std.testing.expectEqualStrings("                    ", rowStr(&buf, 7, &row));
    // The title is bold, the body is not.
    try std.testing.expect(buf.get(5, 3).style.eql(m.title_style));
    try std.testing.expect(buf.get(5, 4).style.eql(m.style));
}

test "modal: a buffer too small for the preferred size shrinks instead of overflowing" {
    var m: Modal = .{
        .title = "Approve",
        .body = "run rm -rf",
        .footer = "[y]",
        .width = 40,
        .height = 10,
    };
    var buf = try Buffer.init(test_alloc, 8, 5);
    defer buf.deinit();
    var row: [64]u8 = undefined;

    // 8x5 is all the box there is: it takes every cell.
    try std.testing.expectEqual(@as(u16, 8), try m.draw(&buf, 0, 0, at0));
    try std.testing.expectEqualStrings("┌──────┐", rowStr(&buf, 0, &row));
    try std.testing.expectEqualStrings("│Approv│", rowStr(&buf, 1, &row));
    try std.testing.expectEqualStrings("│run rm│", rowStr(&buf, 2, &row));
    try std.testing.expectEqualStrings("│[y]   │", rowStr(&buf, 3, &row));
    try std.testing.expectEqualStrings("└──────┘", rowStr(&buf, 4, &row));

    // A single row cannot hold a border: the title still shows, and
    // the return value is what it actually occupied.
    var thin: Buffer = try Buffer.init(test_alloc, 8, 1);
    defer thin.deinit();
    try std.testing.expectEqual(@as(u16, 7), try m.draw(&thin, 0, 0, at0));
    try std.testing.expectEqualStrings("Approve ", rowStr(&thin, 0, &row));
}

test "modal: a zero-sized buffer draws nothing and does not trap" {
    var m: Modal = .{ .title = "Approve", .body = "body", .footer = "[y]" };
    var empty: Buffer = try Buffer.init(test_alloc, 0, 0);
    defer empty.deinit();
    try std.testing.expectEqual(@as(u16, 0), try m.draw(&empty, 0, 0, at0));

    var flat: Buffer = try Buffer.init(test_alloc, 6, 0);
    defer flat.deinit();
    try std.testing.expectEqual(@as(u16, 0), try m.draw(&flat, 0, 0, at0));

    var thin_w: Buffer = try Buffer.init(test_alloc, 0, 6);
    defer thin_w.deinit();
    try std.testing.expectEqual(@as(u16, 0), try m.draw(&thin_w, 0, 0, at0));

    var m2: Modal = m;
    m2.title = "";
    m2.body = "";
    m2.footer = "";
    try std.testing.expectEqual(@as(u16, 0), try m2.draw(&empty, 0, 0, at0));
}

test "modal: the row budget keeps the title, then the body, then the footer" {
    var m: Modal = .{ .title = "T", .body = "b1\nb2", .footer = "F", .width = 4 };
    var row: [32]u8 = undefined;

    // One interior row: the title, and nothing else.
    var one: Buffer = try Buffer.init(test_alloc, 4, 3);
    defer one.deinit();
    m.height = 3;
    _ = try m.draw(&one, 0, 0, at0);
    try std.testing.expectEqualStrings("┌──┐", rowStr(&one, 0, &row));
    try std.testing.expectEqualStrings("│T │", rowStr(&one, 1, &row));
    try std.testing.expectEqualStrings("└──┘", rowStr(&one, 2, &row));

    // Two interior rows: the footer takes the one the body cannot have.
    var two: Buffer = try Buffer.init(test_alloc, 4, 4);
    defer two.deinit();
    m.height = 4;
    _ = try m.draw(&two, 0, 0, at0);
    try std.testing.expectEqualStrings("│T │", rowStr(&two, 1, &row));
    try std.testing.expectEqualStrings("│F │", rowStr(&two, 2, &row));
    try std.testing.expectEqualStrings("└──┘", rowStr(&two, 3, &row));

    // Three interior rows: the body gets the middle one, and "b2" is
    // dropped rather than pushing the footer out.
    var three: Buffer = try Buffer.init(test_alloc, 4, 5);
    defer three.deinit();
    m.height = 5;
    _ = try m.draw(&three, 0, 0, at0);
    try std.testing.expectEqualStrings("│T │", rowStr(&three, 1, &row));
    try std.testing.expectEqualStrings("│b1│", rowStr(&three, 2, &row));
    try std.testing.expectEqualStrings("│F │", rowStr(&three, 3, &row));
    try std.testing.expectEqualStrings("└──┘", rowStr(&three, 4, &row));
}

test "modal: the body draws one line per interior row, in order" {
    var m: Modal = .{ .body = "one\ntwo\nthree", .width = 6, .height = 6 };
    var buf = try Buffer.init(test_alloc, 6, 6);
    defer buf.deinit();
    var row: [32]u8 = undefined;

    // Four interior rows, no title and no footer: all three body lines
    // get one, the last cut at the interior edge.
    _ = try m.draw(&buf, 0, 0, at0);
    try std.testing.expectEqualStrings("┌────┐", rowStr(&buf, 0, &row));
    try std.testing.expectEqualStrings("│one │", rowStr(&buf, 1, &row));
    try std.testing.expectEqualStrings("│two │", rowStr(&buf, 2, &row));
    try std.testing.expectEqualStrings("│thre│", rowStr(&buf, 3, &row));
    try std.testing.expectEqualStrings("│    │", rowStr(&buf, 4, &row));
    try std.testing.expectEqualStrings("└────┘", rowStr(&buf, 5, &row));
}

test "modal: a sequence split across body rows is consumed whole" {
    var m: Modal = .{
        .body = "one\x1b]\ntwo more",
        .footer = "go",
        .width = 12,
        .height = 6,
    };
    var buf = try Buffer.init(test_alloc, 12, 6);
    defer buf.deinit();
    var row: [64]u8 = undefined; // a 12-column row of box glyphs is 36 bytes

    _ = try m.draw(&buf, 0, 0, at0);
    try std.testing.expectEqualStrings("┌──────────┐", rowStr(&buf, 0, &row));
    // No title, so the body starts on the first interior row: `ESC ]`
    // opens on it, which makes the NEXT row that string's payload, so
    // none of it reaches a cell.
    try std.testing.expectEqualStrings("│one       │", rowStr(&buf, 1, &row));
    try std.testing.expectEqualStrings("│          │", rowStr(&buf, 2, &row));
    try std.testing.expectEqualStrings("│          │", rowStr(&buf, 3, &row));
    // The footer is another field, so it is not still inside the string.
    try std.testing.expectEqualStrings("│go        │", rowStr(&buf, 4, &row));
    try std.testing.expectEqualStrings("└──────────┘", rowStr(&buf, 5, &row));
    try expectNoControlCells(&buf);

    // A box with no room for a border shows its one filtered line.
    var thin: Buffer = try Buffer.init(test_alloc, 8, 1);
    defer thin.deinit();
    m.title = "\x1b[1mOnly\x1b[0m";
    m.body = "";
    m.footer = "";
    try std.testing.expectEqual(@as(u16, 4), try m.draw(&thin, 0, 0, at0));
    try std.testing.expectEqualStrings("Only    ", rowStr(&thin, 0, &row));
    try expectNoControlCells(&thin);
}

// Popover.

test "popover: draws its box and content at the anchor" {
    const lines = [_][]const u8{ "line one", "line two" };
    var p: Popover = .{ .width = 8, .lines = &lines };
    var buf = try Buffer.init(test_alloc, 20, 6);
    defer buf.deinit();
    var row: [64]u8 = undefined;

    try std.testing.expectEqual(@as(u16, 8), try p.draw(&buf, 4, 1, at0));
    try std.testing.expectEqualStrings("    ┌──────┐        ", rowStr(&buf, 1, &row));
    try std.testing.expectEqualStrings("    │line o│        ", rowStr(&buf, 2, &row));
    try std.testing.expectEqualStrings("    │line t│        ", rowStr(&buf, 3, &row));
    try std.testing.expectEqualStrings("    └──────┘        ", rowStr(&buf, 4, &row));
    // The auto height hugged the content: two border rows plus two
    // lines, and nothing spilled onto row 5.
    try std.testing.expectEqualStrings("                    ", rowStr(&buf, 5, &row));
}

test "popover: an anchor past the right edge slides back, it does not wrap around" {
    var p: Popover = .{ .width = 6, .height = 3, .lines = &.{"x"} };
    var buf = try Buffer.init(test_alloc, 12, 4);
    defer buf.deinit();
    var row: [64]u8 = undefined;

    // Wrapping would put the box at column 0; clamping keeps it whole
    // against the edge it was anchored past.
    try std.testing.expectEqual(@as(u16, 6), try p.draw(&buf, 12, 0, at0));
    try std.testing.expectEqualStrings("      ┌────┐", rowStr(&buf, 0, &row));
    try std.testing.expectEqualStrings("      │x   │", rowStr(&buf, 1, &row));
    try std.testing.expectEqualStrings("      └────┘", rowStr(&buf, 2, &row));
    try std.testing.expectEqualStrings("            ", rowStr(&buf, 3, &row));
}

test "popover: an anchor off every edge stays inside the buffer" {
    var p: Popover = .{ .width = 6, .height = 4, .lines = &.{ "x", "y" } };
    var buf = try Buffer.init(test_alloc, 12, 6);
    defer buf.deinit();
    var row: [64]u8 = undefined;

    try std.testing.expectEqual(@as(u16, 6), try p.draw(&buf, 5000, 5000, at0));
    try std.testing.expectEqualStrings("            ", rowStr(&buf, 0, &row));
    try std.testing.expectEqualStrings("            ", rowStr(&buf, 1, &row));
    try std.testing.expectEqualStrings("      ┌────┐", rowStr(&buf, 2, &row));
    try std.testing.expectEqualStrings("      │x   │", rowStr(&buf, 3, &row));
    try std.testing.expectEqualStrings("      │y   │", rowStr(&buf, 4, &row));
    try std.testing.expectEqualStrings("      └────┘", rowStr(&buf, 5, &row));
    // Every cell the box wrote is a border glyph or its content: the
    // far edge is the buffer edge, so nothing was dropped.
    try std.testing.expectEqualStrings("┐", buf.get(11, 2).grapheme);
    try std.testing.expectEqualStrings("┘", buf.get(11, 5).grapheme);
    try std.testing.expectEqualStrings(" ", buf.get(11, 0).grapheme);
}

test "popover: a box bigger than the buffer is clamped to it" {
    var p: Popover = .{ .width = 40, .height = 40, .lines = &.{ "a", "b" } };
    var buf = try Buffer.init(test_alloc, 5, 3);
    defer buf.deinit();
    var row: [64]u8 = undefined;

    try std.testing.expectEqual(@as(u16, 5), try p.draw(&buf, 0, 0, at0));
    try std.testing.expectEqualStrings("┌───┐", rowStr(&buf, 0, &row));
    try std.testing.expectEqualStrings("│a  │", rowStr(&buf, 1, &row));
    try std.testing.expectEqualStrings("└───┘", rowStr(&buf, 2, &row));

    // No room for a border: nothing is drawn at all.
    var tiny: Popover = .{ .width = 1, .height = 1, .lines = &.{"a"} };
    buf.clear();
    try std.testing.expectEqual(@as(u16, 0), try tiny.draw(&buf, 0, 0, at0));
    try std.testing.expectEqualStrings("     ", rowStr(&buf, 0, &row));

    var empty: Buffer = try Buffer.init(test_alloc, 0, 0);
    defer empty.deinit();
    try std.testing.expectEqual(@as(u16, 0), try p.draw(&empty, 0, 0, at0));
}

test "popover: one line's sequence does not swallow the next line" {
    // Each line is its own field: this one ends inside an unterminated
    // OSC, and the line under it still draws its text.
    const lines = [_][]const u8{ "a\x1b]0;owned", "b" };
    var p: Popover = .{ .width = 6, .lines = &lines };
    var buf = try Buffer.init(test_alloc, 8, 4);
    defer buf.deinit();
    var row: [32]u8 = undefined;

    _ = try p.draw(&buf, 0, 0, at0);
    // The box is six columns in an eight-column buffer: the row carries
    // the two blank cells the box leaves to its right.
    try std.testing.expectEqualStrings("┌────┐  ", rowStr(&buf, 0, &row));
    try std.testing.expectEqualStrings("│a   │  ", rowStr(&buf, 1, &row));
    try std.testing.expectEqualStrings("│b   │  ", rowStr(&buf, 2, &row));
    try expectNoControlCells(&buf);
}

// The rendered band.

test "overlay: no source control sequence reaches a rendered Region" {
    // The real band, not a source-text check: every field carries the
    // sequences model and peer output really produce — an SGR change,
    // a BEL-terminated OSC, a raw C1 byte, a DCS opened and closed by
    // ST, a C0 control.
    const items = [_][]const u8{ "a\x1b[31mred", "\x1b]0;owned\x07b" };
    var s: Select = .{ .items = &items, .width = 12 };
    var m: Modal = .{
        .title = "\x1b[1mT\x1b[0m",
        .body = "line\x1b[31m\nmore\x9bZ",
        .footer = "\x07go",
        .width = 12,
        .height = 6,
    };
    const lines = [_][]const u8{ "\x1bP+q544e\x1b\\payload", "\x1b]2;t\x07tip" };
    var p: Popover = .{ .width = 12, .lines = &lines };

    // Piped output: no envelope, no SGR of its own, one plain frame.
    var r = try Region.init(test_alloc, .{ .height = 20, .interactive = false });
    defer r.deinit();
    // Three boxes on one band, none overlapping: picker on rows 0..3,
    // popover on 4..7, and the modal centred below on 11..16.
    _ = try s.draw(&r.cur, 0, 0, at0);
    _ = try p.draw(&r.cur, 0, 4, at0);
    _ = try m.draw(&r.cur, 0, 8, at0);
    try expectNoControlCells(&r.cur);

    var tw: TestWriter = .{};
    tw.init();
    try r.render(&tw.w);
    const out = tw.w.buffered();

    // Piped frames carry no escape sequences of their own, so every
    // byte below 0x20 in here came from a caller's text — and there is
    // none of it.
    for (out) |b| try std.testing.expect(b >= 0x20 or b == '\n');
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x07") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x9b") == null); // raw CSI
    try std.testing.expect(std.mem.indexOf(u8, out, "\xc2\x9b") == null); // U+009B

    // What the fields leave behind: the sequence bodies are gone, the
    // printable text around them is not.
    try std.testing.expect(std.mem.indexOf(u8, out, "ared") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "owned") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "payload") != null); // ST ended it
    try std.testing.expect(std.mem.indexOf(u8, out, "moreZ") != null); // raw C1 dropped
    try std.testing.expect(std.mem.indexOf(u8, out, "go") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "tip") != null);
}

// Draw allocation checks.

test "overlay: draw allocates nothing" {
    // Unarmed until the buffer exists: the guard goes live on the next
    // allocation, whatever the buffer itself needed to get there.
    var failing = std.testing.FailingAllocator.init(test_alloc, .{
        .fail_index = std.math.maxInt(usize),
    });
    const alloc = failing.allocator();
    const items = [_][]const u8{ "alpha", "beta", "gamma" };
    const lines = [_][]const u8{ "one", "a much longer line" };

    // One allocation, for the buffer's cells. From here on every
    // allocation fails, so a draw that allocated would not be ignored.
    var buf = try Buffer.init(alloc, 12, 6);
    defer buf.deinit();
    failing.fail_index = failing.alloc_index;

    var s: Select = .{ .items = &items, .width = 6 };
    var m: Modal = .{ .title = "t", .body = "b", .footer = "f", .width = 8, .height = 4 };
    var p: Popover = .{ .width = 6, .lines = &lines };
    _ = try s.draw(&buf, 0, 0, at0);
    _ = try m.draw(&buf, 0, 0, at0);
    _ = try p.draw(&buf, 1, 1, at0);
    try std.testing.expect(!s.advance(at0));
    try std.testing.expect(!m.advance(at0));
    try std.testing.expect(!p.advance(at0));
}
