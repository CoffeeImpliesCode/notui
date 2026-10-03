//! cards.zig — collapsible tool-call cards and diff rendering.
//!
//! Two standalone components, both drawn into a caller-owned `Buffer`
//! and both on the house shape (`draw(buf, x, y, now) !u16`,
//! `advance(now) bool`): `Card`, a titled tool-call card with a state
//! on a three-rung collapse ladder, and `Diff`, unified or
//! side-by-side rendering over caller-owned hunks, with
//! `parseUnified` for the unified-diff text form.
//!
//! Untrusted text. `markdown.Sanitizer` is the library's ONE escape
//! parser, and `Pen` runs every grapheme that reaches a cell through
//! it: no cell can carry ESC, a CSI/OSC/DCS/APC body, a C0 or DEL
//! codepoint, an encoded C1 control, or invalid UTF-8. A component
//! must filter while it draws, borrowing the caller's graphemes with
//! no allocation, so this file calls `acceptCluster` and keeps none of
//! its own: `src/markdown.zig` owns the rule, its allocating
//! `sanitize` and this file's `draw` are the same rule. The state
//! persists across clusters and row breaks, so a sequence split over a
//! line still consumes as one and no orphan tail such as `1m`
//! survives. A TAB passes the filter but cannot live in a cell, so
//! `Pen` expands it to spaces up to the next tab stop.
//!
//! Zero allocation in `draw`: every drawn grapheme borrows the
//! caller's title, body, or diff text, and the only formatted bytes
//! are `Card.note_buf`, a fixed-size struct field (cells borrow it,
//! so the card must not move between `draw` and the buffer render —
//! the same rule `Progress.percent_buf` follows).
//!
//! Layout obeys the same rule: a box is sized on the columns the
//! sanitiser KEEPS, and the pieces a header paints are measured as ONE
//! stream, so a title that swallows its own state glyph cannot leave a
//! box full of dead columns.

const std = @import("std");
const Buffer = @import("../buffer.zig").Buffer;
const Style = @import("../style.zig").Style;
const Width = @import("../width.zig");
const Clock = @import("component.zig").Clock;
const markdown = @import("../markdown.zig");
const Region = @import("../region.zig").Region;

/// Number of `Card.State` variants; the width of `Card.Look.states`.
const state_count = @typeInfo(Card.State).@"enum".fields.len;

/// Tab stops for a TAB in untrusted text: a cell buffer cannot carry a
/// tab byte (it would move the cursor), so a TAB becomes spaces up to
/// the next stop.
const tab_width: usize = 4;

/// A titled tool-call card with a state and a three-rung collapse
/// ladder: rung 0 shows `▸ title`, rung 1 adds a body preview, rung 2
/// shows the whole body with no truncation. Static — `advance` is
/// always false; the ladder is app-driven, not time-driven.
pub const Card = struct {
    /// Card title, BORROWED and sanitised at draw: the drawn cells keep
    /// the surviving bytes, so it must outlive the buffer that shows
    /// them.
    title: []const u8 = "",
    /// Card body, BORROWED like `title`; split on '\n' at draw and
    /// sanitised as ONE stream with the header — `draw` runs the title,
    /// every body row and the truncation note through a single `Pen`, so
    /// filter state carries across row breaks and an unterminated escape
    /// swallows the start of the next row. Each row is measured on its
    /// own stream, so a box can be sized for bytes no cell paints.
    body: []const u8 = "",
    /// Lifecycle state; drives the header glyph and its colour.
    state: State = .pending,
    /// Rung on the collapse ladder (0..ladder_max); `collapseLadder`
    /// keeps it in range.
    rung: u8 = 0,
    /// Body rows shown at rung 1. Rung 2 shows every line; 0 shows no
    /// body row at all (only the "… +N more" note that says so).
    preview_lines: u16 = 6,
    /// Draw the surrounding box. false = bare rows, one per line.
    boxed: bool = true,
    /// Scratch for the "… +N more" note. Cells borrow it, so the card
    /// must not move between `draw` and the buffer render.
    note_buf: [24]u8 = undefined,
    /// Every style the card paints; see `Look`.
    look: Look = .{},
    /// Card lifecycle state.
    pub const State = enum { pending, running, ok, @"error" };

    /// Highest rung on the collapse ladder.
    pub const ladder_max: u8 = 2;

    /// Marker for the collapsed ladder rung.
    pub const collapsed_marker: []const u8 = "▸";
    /// Marker for both expanded rungs.
    pub const expanded_marker: []const u8 = "▾";

    /// Every style the card paints, so a theme layer can supply them.
    pub const Look = struct {
        title: Style = .{ .attrs = .{ .bold = true } },
        body: Style = .{},
        border: Style = .{ .fg = .{ .ansi256 = 245 } },
        marker: Style = .{ .attrs = .{ .dim = true } },
        /// The "… +N more" note under a truncated preview.
        hidden: Style = .{ .attrs = .{ .dim = true } },
        /// Indexed by `State`; the header glyph takes this style.
        states: [state_count]Style = .{
            .{ .fg = .{ .ansi = .bright_black } }, // pending
            .{ .fg = .{ .ansi = .yellow } }, // running
            .{ .fg = .{ .ansi = .green } }, // ok
            .{ .fg = .{ .ansi = .red } }, // error
        },
    };

    const state_glyphs = [state_count][]const u8{ "○", "◐", "●", "✕" };

    /// The card is static: the ladder is app-driven, not time-driven.
    pub fn advance(self: *Card, now: Clock) bool {
        _ = self;
        _ = now;
        return false;
    }

    /// Step the collapse ladder by `delta` rungs, clamped to
    /// 0..ladder_max: positive expands (1 = preview, 2 = full body),
    /// negative collapses. Stepping past either end is a no-op, so a
    /// full expand is idempotent — the frame at `ladder_max` does not
    /// change however many further steps arrive.
    pub fn collapseLadder(self: *Card, delta: i8) void {
        const cur: i32 = @intCast(self.rung);
        self.rung = @intCast(std.math.clamp(cur + delta, 0, @as(i32, ladder_max)));
    }

    /// True when the card shows anything past its title.
    pub fn expanded(self: *const Card) bool {
        return self.rung > 0;
    }

    /// Rows the card wants at `avail` columns: header, the body rows
    /// this rung shows, the truncation note when one is due, and the
    /// bottom border. Reports the UNCLIPPED height, so a caller
    /// stacking cards in one band can lay them out before drawing;
    /// `draw` clips to the buffer.
    pub fn rows(self: *const Card, avail: usize) usize {
        var n: usize = 1; // header
        if (self.rung > 0 and self.body.len > 0) {
            n += self.bodyRows() + @as(usize, @intFromBool(self.rowsHidden() > 0));
        }
        if (self.boxed and avail >= 4) n += 1; // bottom border
        return n;
    }

    /// Draw the card at (x, y), clipping to the buffer. Returns the
    /// columns consumed (the box width, or the content width when
    /// `boxed` is false) — never more than `buf.width - x`.
    pub fn draw(self: *Card, buf: *Buffer, x: u16, y: u16, now: Clock) !u16 {
        _ = self.advance(now);
        const avail: u16 = buf.width -| x;
        if (avail == 0 or y >= buf.height) return 0;

        // A box frame costs 4 columns ("│ " and " │"). Below that the
        // frame would eat the content, so the card degrades to bare
        // rows rather than drawing a sliver.
        const boxed = self.boxed and avail >= 4;
        const frame: usize = if (boxed) 4 else 0;
        const budget: usize = @as(usize, avail) - frame;
        const frame_inset: u16 = if (boxed) 2 else 0;
        const inner_x: u16 = x + frame_inset;

        const hidden = self.rowsHidden();
        const note: ?[]const u8 = if (hidden > 0) try self.formatHidden(hidden) else null;

        var pen: Pen = .{ .buf = buf };
        var content_w = @max(self.headerWidth(inner_x, budget), self.bodyWidth(inner_x, budget));
        if (note) |n| content_w = @max(content_w, Width.strWidth(n));
        content_w = @min(content_w, budget);
        const width: u16 = @intCast(content_w + frame);

        var row = y;
        if (boxed) try self.drawRule(buf, x, row, width, "╭", "╮");
        // Header: `▸ title ○`. The state glyph trails the title so the
        // collapsed prefix stays the ladder marker's alone.
        var used: u16 = 0;
        used = try pen.put(self.look.marker, self.marker(), inner_x, row, used, content_w);
        used = try pen.put(self.look.marker, " ", inner_x, row, used, content_w);
        used = try pen.put(self.look.title, self.title, inner_x, row, used, content_w);
        used = try pen.put(self.look.marker, " ", inner_x, row, used, content_w);
        const state_style = self.look.states[@intFromEnum(self.state)];
        const glyph = state_glyphs[@intFromEnum(self.state)];
        _ = try pen.put(state_style, glyph, inner_x, row, used, content_w);
        row += 1;

        if (self.rung > 0 and self.body.len > 0) {
            const limit = self.bodyRows();
            var shown: usize = 0;
            var lines = std.mem.splitScalar(u8, self.body, '\n');
            while (lines.next()) |text| {
                if (shown >= limit) break;
                if (row >= buf.height) break; // clipped by the buffer
                if (boxed) try self.drawSides(buf, x, row, width);
                _ = try pen.put(self.look.body, text, inner_x, row, 0, content_w);
                shown += 1;
                row += 1;
            }
            // The preview rung says on its own row how much it held
            // back. A card cut short by the buffer edge stays silent:
            // the band, not the card, owns what is off-screen.
            if (note) |n| {
                if (shown == limit and row < buf.height) {
                    if (boxed) try self.drawSides(buf, x, row, width);
                    _ = try pen.put(self.look.hidden, n, inner_x, row, 0, content_w);
                    row += 1;
                }
            }
        }

        if (boxed and row < buf.height) {
            try self.drawRule(buf, x, row, width, "╰", "╯");
        }
        return width;
    }

    /// The ladder marker for the current rung.
    fn marker(self: *const Card) []const u8 {
        return if (self.rung == 0) collapsed_marker else expanded_marker;
    }

    /// Body rows this rung shows: every line at the top rung, at most
    /// `preview_lines` below it, and none while collapsed.
    fn bodyRows(self: *const Card) usize {
        if (self.rung == 0 or self.body.len == 0) return 0;
        const total = std.mem.count(u8, self.body, "\n") + 1;
        return if (self.rung == ladder_max) total else @min(total, @as(usize, self.preview_lines));
    }

    /// Body rows the preview rung holds back.
    fn rowsHidden(self: *const Card) usize {
        if (self.rung == 0 or self.rung == ladder_max or self.body.len == 0) return 0;
        const total = std.mem.count(u8, self.body, "\n") + 1;
        return total - self.bodyRows();
    }

    /// Columns the header occupies at (x0, cap): the marker, the space
    /// after it, the title, the space before the state glyph, and the
    /// glyph — measured as ONE stream through `markdown.Sanitizer`, the
    /// way `draw` feeds them to `Pen`. A title whose escape sequence
    /// never terminates leaves the machine armed, so the space and the
    /// glyph behind it are consumed; sizing from pieces measured apart
    /// would keep columns the header never paints. Saturates at `cap`.
    fn headerWidth(self: *const Card, x0: u16, cap: usize) usize {
        return textWidthParts(
            &.{
                self.marker(),
                " ",
                self.title,
                " ",
                state_glyphs[@intFromEnum(self.state)],
            },
            x0,
            cap,
        );
    }

    /// Widest body row this rung shows, saturating at `cap` — a box
    /// never needs more, so a huge body costs no more than `cap`
    /// columns of measurement.
    fn bodyWidth(self: *const Card, x0: u16, cap: usize) usize {
        const limit = self.bodyRows();
        var widest: usize = 0;
        var seen: usize = 0;
        var lines = std.mem.splitScalar(u8, self.body, '\n');
        while (lines.next()) |text| {
            if (seen >= limit) break;
            seen += 1;
            widest = @max(widest, textWidth(text, x0, cap));
            if (widest >= cap) return cap;
        }
        return widest;
    }

    /// Format the truncation note into `note_buf` (borrowed by cells,
    /// so the buffer lives in the struct). A count too large for the
    /// buffer degrades to the bare ellipsis rather than failing.
    fn formatHidden(self: *Card, hidden: usize) ![]const u8 {
        return std.fmt.bufPrint(&self.note_buf, "… +{d} more", .{hidden}) catch "…";
    }

    /// Draw the left and right border glyphs of row `y`.
    fn drawSides(self: *const Card, buf: *Buffer, x: u16, y: u16, width: u16) !void {
        _ = try buf.draw(self.look.border, "│", x, y);
        _ = try buf.draw(self.look.border, "│", x + width - 1, y);
    }

    /// Draw a top or bottom rule: `left`, `width - 2` horizontal cells,
    /// `right`. The header row is drawn over the middle afterwards.
    fn drawRule(
        self: *const Card,
        buf: *Buffer,
        x: u16,
        y: u16,
        width: u16,
        left: []const u8,
        right: []const u8,
    ) !void {
        _ = try buf.draw(self.look.border, left, x, y);
        var i: u16 = 1;
        while (i < width - 1) : (i += 1) {
            _ = try buf.draw(self.look.border, "─", x + i, y);
        }
        _ = try buf.draw(self.look.border, right, x + width - 1, y);
    }
};

/// One diff line's kind.
pub const LineKind = enum { context, addition, deletion, meta };

/// One diff line. `text` is the payload without the leading `+`, `-`,
/// or space, and is BORROWED from the parsed source.
pub const Line = struct {
    kind: LineKind,
    text: []const u8 = "",
};

/// One `@@` block. The hunk owns its line storage; `parseUnified`
/// appends into it and `deinitHunks` frees it. The caller owns the
/// list of hunks, and a `Diff` only borrows it.
pub const Hunk = struct {
    /// The `@@ -old,oc +new,nc @@ heading` line, borrowed.
    header: []const u8 = "",
    /// First line of the block in the old file (0 when unknown).
    old_start: u32 = 0,
    /// Old-file line count; a header may omit it, which means 1.
    old_count: u32 = 1,
    /// First line of the block in the new file (0 when unknown).
    new_start: u32 = 0,
    /// New-file line count; a header may omit it, which means 1.
    new_count: u32 = 1,
    /// The hunk's rows in order; `parseUnified` appends to this list and
    /// `deinitHunks` frees its storage with `gpa`.
    lines: std.ArrayList(Line) = .empty,
};

/// Failures `parseUnified` reports instead of trapping: a header or a
/// hunk-body line that does not match the unified-diff grammar.
pub const ParseError = error{
    /// A `@@` line that does not have the
    /// `-old[,count] +new[,count] @@` shape.
    MalformedHunkHeader,
    /// A line inside a hunk whose first byte classifies as none of
    /// `+`, `-`, ` `, `\` (an empty line is an empty context row).
    MalformedHunkLine,
    /// Appending a hunk or one of its lines could not allocate.
    OutOfMemory,
};

/// Parse a minimal unified diff into caller-owned hunks.
///
/// Accepted: `---`/`+++` file headers and any other pre-hunk noise
/// (`index`, `diff --git`, mode lines) are skipped;
/// `@@ -old[,count] +new[,count] @@[ heading]` opens a hunk; inside a
/// hunk a leading `+`, `-`, ` `, or `\` classifies the line and the
/// rest is the payload, while a bare empty line is an empty context
/// row (what git writes for one). An omitted count means 1. A
/// `\`-prefixed note ("\ No newline at end of file") is kept verbatim
/// as `meta`. A trailing newline is the end of input, not a row.
///
/// On failure the hunks parsed so far stay in the list: the caller
/// frees them either way, with `deinitHunks`.
pub fn parseUnified(
    gpa: std.mem.Allocator,
    text: []const u8,
    hunks: *std.ArrayList(Hunk),
) ParseError!void {
    // The split below yields a trailing empty segment for a final
    // newline; that is the end of input, not an empty context row.
    const body = if (text.len > 0 and text[text.len - 1] == '\n') text[0 .. text.len - 1] else text;

    var open: ?usize = null; // index of the hunk being filled
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r"); // CRLF-safe
        if (std.mem.startsWith(u8, line, "@@")) {
            const parsed = parseHeader(line) orelse return error.MalformedHunkHeader;
            open = hunks.items.len;
            try hunks.append(gpa, parsed);
            continue;
        }
        const at = open orelse continue; // pre-hunk noise: skipped
        const entry: Line = if (line.len == 0)
            .{ .kind = .context, .text = "" }
        else switch (line[0]) {
            '+' => .{ .kind = .addition, .text = line[1..] },
            '-' => .{ .kind = .deletion, .text = line[1..] },
            ' ' => .{ .kind = .context, .text = line[1..] },
            '\\' => .{ .kind = .meta, .text = line },
            else => return error.MalformedHunkLine,
        };
        try hunks.items[at].lines.append(gpa, entry);
    }
}

/// Free every hunk's line storage and then the list itself.
pub fn deinitHunks(gpa: std.mem.Allocator, hunks: *std.ArrayList(Hunk)) void {
    for (hunks.items) |*hunk| hunk.lines.deinit(gpa);
    hunks.deinit(gpa);
}

/// Parse `@@ -old[,count] +new[,count] @@[ heading]`; null when the
/// header does not have that exact shape. Nothing is allocated and no
/// index runs off the end: every scanner stops at the line end.
fn parseHeader(line: []const u8) ?Hunk {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') i += 1;
    if (!std.mem.startsWith(u8, line[i..], "@@ ")) return null;
    i += 3;

    const old = parseRange(line, &i, '-') orelse return null;
    // The two ranges are one space apart, exactly as git writes them.
    if (i >= line.len or line[i] != ' ') return null;
    i += 1;
    const new = parseRange(line, &i, '+') orelse return null;
    if (!std.mem.startsWith(u8, line[i..], " @@")) return null;

    return .{
        .header = std.mem.trim(u8, line, " "),
        .old_start = old.start,
        .old_count = old.count,
        .new_start = new.start,
        .new_count = new.count,
    };
}

/// A hunk's `-start,count` or `+start,count` range.
const Range = struct { start: u32, count: u32 };

/// Parse `sign start[,count]` at `i`, advancing `i` past it. null
/// when the sign is missing, a start is not a number, or a number
/// overflows u32 — an unrepresentable range is a malformed header,
/// not a truncated one.
fn parseRange(line: []const u8, i: *usize, sign: u8) ?Range {
    if (i.* >= line.len or line[i.*] != sign) return null;
    i.* += 1;
    const start = parseUint(line, i) orelse return null;
    var count: u32 = 1;
    if (i.* < line.len and line[i.*] == ',') {
        i.* += 1;
        count = parseUint(line, i) orelse return null;
    }
    return .{ .start = start, .count = count };
}

/// Parse decimal digits at `i`, advancing `i` past them; null when
/// there are none or they overflow u32.
fn parseUint(line: []const u8, i: *usize) ?u32 {
    const start = i.*;
    while (i.* < line.len and std.ascii.isDigit(line[i.*])) i.* += 1;
    if (i.* == start) return null;
    return std.fmt.parseUnsigned(u32, line[start..i.*], 10) catch null;
}

/// A diff rendered from caller-owned hunks: one row per line, unified
/// or side-by-side, clipped to the buffer. Static — `advance` is
/// always false.
pub const Diff = struct {
    /// Hunks to render, BORROWED. Each owns its line storage.
    hunks: []const Hunk = &.{},
    /// Row layout; see `Layout`. Side-by-side pairs a removal with the
    /// addition that follows it.
    layout: Layout = .unified,
    /// Draw the `@@` header row above each hunk's lines.
    show_headers: bool = true,
    look: Look = .{},

    /// How rows are laid out.
    pub const Layout = enum {
        /// One row per line, prefixed with `+`, `-`, or a space.
        unified,
        /// Two columns: a removal pairs with the addition that follows.
        side_by_side,
    };

    /// Line-level counts over every hunk.
    pub const Stats = struct {
        /// Lines counted as additions.
        added: usize = 0,
        /// Lines counted as deletions.
        removed: usize = 0,
        /// Longest run of consecutive added-or-removed lines. A
        /// context row or a note ends a run.
        longest_run: usize = 0,
    };

    /// Every style the diff paints, so a theme layer can supply them.
    pub const Look = struct {
        /// Style for an added line and its `+` marker.
        add: Style = .{ .fg = .{ .ansi = .green } },
        /// Style for a removed line and its `-` marker.
        del: Style = .{ .fg = .{ .ansi = .red } },
        /// Style for a context line and its leading space.
        context: Style = .{},
        /// Style for hunk headers and `\`-prefixed notes.
        meta: Style = .{ .fg = .{ .ansi256 = 245 }, .attrs = .{ .dim = true } },
    };

    /// The diff is static: `hunks` changes, the clock does not.
    pub fn advance(self: *Diff, now: Clock) bool {
        _ = self;
        _ = now;
        return false;
    }

    /// Draw the diff at (x, y), one row per line, clipped to the
    /// buffer. Returns the widest row's columns; never more than
    /// `buf.width - x`.
    pub fn draw(self: *Diff, buf: *Buffer, x: u16, y: u16, now: Clock) !u16 {
        _ = self.advance(now);
        const avail: u16 = buf.width -| x;
        if (avail == 0 or y >= buf.height) return 0;

        var pen: Pen = .{ .buf = buf };
        var row = y;
        var widest: u16 = 0;
        switch (self.layout) {
            .unified => for (self.hunks) |hunk| {
                if (self.show_headers and hunk.header.len > 0) {
                    if (row >= buf.height) return widest;
                    const head = try pen.put(self.look.meta, hunk.header, x, row, 0, avail);
                    widest = @max(widest, head);
                    row += 1;
                }
                for (hunk.lines.items) |line| {
                    if (row >= buf.height) return widest;
                    widest = @max(widest, try self.drawRow(&pen, line, x, row, avail));
                    row += 1;
                }
            },
            .side_by_side => {
                // Two columns and a one-column gap; below three columns
                // there is no room for the gap and the rows keep
                // whatever fits.
                const gap: u16 = if (avail >= 3) 1 else 0;
                const left_budget: u16 = (avail - gap) / 2;
                const right_budget: u16 = avail - gap - left_budget;
                for (self.hunks) |hunk| {
                    if (self.show_headers and hunk.header.len > 0) {
                        if (row >= buf.height) return widest;
                        const head = try pen.put(self.look.meta, hunk.header, x, row, 0, avail);
                        widest = @max(widest, head);
                        row += 1;
                    }
                    var i: usize = 0;
                    const lines = hunk.lines.items;
                    while (i < lines.len) {
                        if (row >= buf.height) return widest;
                        const left = lines[i];
                        // A removal pairs with the addition that follows
                        // it, which is the only order a unified diff
                        // gives a replacement. A lone removal or
                        // addition takes the left column alone.
                        var right: ?Line = null;
                        var step: usize = 1;
                        if (left.kind == .deletion and i + 1 < lines.len and
                            lines[i + 1].kind == .addition)
                        {
                            right = lines[i + 1];
                            step = 2;
                        }
                        const lstyle = self.lineStyle(left.kind);
                        const left_used = try pen.put(lstyle, left.text, x, row, 0, left_budget);
                        widest = @max(widest, left_used);
                        if (right) |pair| {
                            // The right column starts at a fixed
                            // offset, so columns stay aligned however
                            // short the left one is.
                            const right_x = x + left_budget + gap;
                            const rs = self.lineStyle(pair.kind);
                            const rw = try pen.put(rs, pair.text, right_x, row, 0, right_budget);
                            widest = @max(widest, right_x - x + rw);
                        }
                        i += step;
                        row += 1;
                    }
                }
            },
        }
        return widest;
    }

    /// Line-level counts: additions, deletions, and the longest run of
    /// consecutive changed lines. A header is not a line at all, and a
    /// note row ends a run, because the changed rows around it are
    /// not adjacent in the source.
    pub fn stats(self: *const Diff) Stats {
        var out: Stats = .{};
        var run: usize = 0;
        for (self.hunks) |hunk| {
            for (hunk.lines.items) |line| {
                switch (line.kind) {
                    .addition => out.added += 1,
                    .deletion => out.removed += 1,
                    .context, .meta => {},
                }
                switch (line.kind) {
                    .addition, .deletion => {
                        run += 1;
                        out.longest_run = @max(out.longest_run, run);
                    },
                    .context, .meta => run = 0,
                }
            }
        }
        return out;
    }

    /// One unified row: the kind marker, then the payload, both in the
    /// kind's style.
    fn drawRow(self: *const Diff, pen: *Pen, line: Line, x: u16, y: u16, budget: u16) !u16 {
        const style = self.lineStyle(line.kind);
        var used: u16 = 0;
        switch (line.kind) {
            .addition => used = try pen.put(style, "+", x, y, used, budget),
            .deletion => used = try pen.put(style, "-", x, y, used, budget),
            .context => used = try pen.put(style, " ", x, y, used, budget),
            .meta => {},
        }
        return pen.put(style, line.text, x, y, used, budget);
    }

    fn lineStyle(self: *const Diff, kind: LineKind) Style {
        return switch (kind) {
            .addition => self.look.add,
            .deletion => self.look.del,
            .context => self.look.context,
            .meta => self.look.meta,
        };
    }
};

/// The row-writing cursor: the buffer plus the sanitiser state. Every
/// grapheme a component paints goes through `Pen`, so no draw path can
/// route around `markdown.Sanitizer` — the library's one escape parser.
const Pen = struct {
    buf: *Buffer,
    san: markdown.Sanitizer = .{},

    /// Append `text` at column `x + used` within `budget` columns and
    /// return the new `used`. Text past the budget, and every cluster
    /// the sanitiser rejects, is dropped.
    fn put(
        self: *Pen,
        style: Style,
        text: []const u8,
        x: u16,
        y: u16,
        used: u16,
        budget: usize,
    ) !u16 {
        var col = used;
        var off: usize = 0;
        while (off < text.len) {
            const glen = Width.firstGraphemeLen(text[off..]);
            if (glen == 0) break; // defensive: no progress possible
            const gc = text[off..][0..glen];
            off += glen;

            if (!self.san.acceptCluster(gc)) continue;

            // A tab byte cannot live in a cell: it would move the
            // cursor. Expand it to spaces up to the next tab stop.
            if (gc.len == 1 and gc[0] == '\t') {
                var n = tab_width - (@as(usize, x) + @as(usize, col)) % tab_width;
                while (n > 0 and @as(usize, col) < budget) : (n -= 1) {
                    try self.buf.set(x + col, y, .{ .grapheme = " ", .style = style });
                    col += 1;
                }
                continue;
            }

            const cw = Width.graphemeWidth(gc);
            if (cw <= 0) continue; // zero-width: advances no column
            const cwu: u16 = if (cw >= 2) 2 else 1;
            if (@as(usize, col) + cwu > budget) break; // over-wide: drop the rest
            try self.buf.set(x + col, y, .{ .grapheme = gc, .style = style });
            col += cwu;
        }
        return col;
    }
};

/// Columns `text` occupies after `markdown.Sanitizer`, starting at
/// column `x0` and saturating at `cap`. Measures the same clusters
/// `Pen.put` keeps, tabs included, so a box sized with it fits its
/// content.
fn textWidth(text: []const u8, x0: u16, cap: usize) usize {
    return textWidthParts(&.{text}, x0, cap);
}

/// `textWidth` over several pieces fed as ONE stream: they share a
/// sanitiser, so a sequence opened in an earlier piece swallows the
/// rest, exactly as `Pen` swallows the paint behind it. Measuring
/// pieces apart would size a layout for text that never reaches a cell.
fn textWidthParts(parts: []const []const u8, x0: u16, cap: usize) usize {
    var san: markdown.Sanitizer = .{};
    var width: usize = 0;
    for (parts) |text| {
        var off: usize = 0;
        while (off < text.len) {
            const glen = Width.firstGraphemeLen(text[off..]);
            if (glen == 0) break;
            const gc = text[off..][0..glen];
            off += glen;

            if (!san.acceptCluster(gc)) continue;

            if (gc.len == 1 and gc[0] == '\t') {
                width += tab_width - (@as(usize, x0) + width) % tab_width;
                if (width > cap) return cap;
                continue;
            }
            const cw = Width.graphemeWidth(gc);
            if (cw <= 0) continue;
            width += @intCast(cw);
            if (width > cap) return cap;
        }
    }
    return width;
}

test {
    std.testing.refAllDecls(@This());
}

const test_alloc = std.testing.allocator;

/// Fixed-buffer writer for byte-exact Region assertions (the
/// `region.zig`/`emit.zig` pattern). `init` runs in place: the writer
/// borrows `buf`.
const TestWriter = struct {
    buf: [4096]u8 = undefined,
    w: std.Io.Writer = undefined,

    fn init(self: *TestWriter) void {
        self.w = .fixed(&self.buf);
    }

    fn bytes(self: *const TestWriter) []const u8 {
        return self.w.buffered();
    }
};

/// Concatenate row `y`'s graphemes into `out` and trim the trailing
/// blank cells: what a reader of the frame sees, without the padding.
/// A row too long for `out` returns a marker instead of a truncated
/// prefix, so an undersized scratch fails its assertion, never passes
/// it. Four bytes per column of `buf.width` always suffices.
fn rowText(buf: *const Buffer, y: usize, out: []u8) []const u8 {
    var n: usize = 0;
    var x: usize = 0;
    while (x < buf.width) : (x += 1) {
        const cell = buf.get(@intCast(x), @intCast(y));
        if (cell.wide or cell.grapheme.len == 0) continue;
        if (n + cell.grapheme.len > out.len) return "row too long for its buffer";
        @memcpy(out[n..][0..cell.grapheme.len], cell.grapheme);
        n += cell.grapheme.len;
    }
    var end = n;
    while (end > 0 and out[end - 1] == ' ') end -= 1;
    return out[0..end];
}

/// Column of the row's rightmost painted cell, or null when the row is
/// blank.
fn rightEdge(buf: *const Buffer, y: usize) ?u16 {
    var x: usize = buf.width;
    while (x > 0) {
        x -= 1;
        const cell = buf.get(@intCast(x), @intCast(y));
        const blank = cell.grapheme.len == 0 or
            (cell.grapheme.len == 1 and cell.grapheme[0] == ' ');
        if (!cell.wide and !blank) return @intCast(x);
    }
    return null;
}

/// Number of rows of `buf` that hold something other than blanks.
fn paintedRows(buf: *const Buffer) usize {
    var n: usize = 0;
    var y: usize = 0;
    while (y < buf.height) : (y += 1) {
        if (rightEdge(buf, y) != null) n += 1;
    }
    return n;
}

test "card: the collapse ladder clamps at both ends and a full expand is idempotent" {
    var card: Card = .{ .title = "bash", .body = "l1\nl2\nl3", .preview_lines = 2 };
    try std.testing.expect(!card.expanded());

    card.collapseLadder(-1);
    try std.testing.expectEqual(@as(u8, 0), card.rung); // bottom clamp
    try std.testing.expect(!card.expanded());

    card.collapseLadder(1);
    try std.testing.expectEqual(@as(u8, 1), card.rung);
    try std.testing.expect(card.expanded());

    card.collapseLadder(1);
    try std.testing.expectEqual(Card.ladder_max, card.rung);

    // Two more steps at the top: same rung, same frame.
    var before = try Buffer.init(test_alloc, 20, 6);
    defer before.deinit();
    const width = try card.draw(&before, 0, 0, .fromNanoseconds(0));
    card.collapseLadder(1);
    card.collapseLadder(4);
    try std.testing.expectEqual(Card.ladder_max, card.rung);

    var after = try Buffer.init(test_alloc, 20, 6);
    defer after.deinit();
    try std.testing.expectEqual(width, try card.draw(&after, 0, 0, .fromNanoseconds(1)));
    for (0..before.height) |y| {
        for (0..before.width) |x| {
            const a = before.get(@intCast(x), @intCast(y));
            const b = after.get(@intCast(x), @intCast(y));
            try std.testing.expect(a.eql(b));
        }
    }

    // Rung 2 shows the whole body: header, three rows, bottom border.
    // The header content "▾ bash ○" is 8 columns in a 12-column box.
    var row: [128]u8 = undefined;
    try std.testing.expectEqual(@as(u16, 12), width);
    try std.testing.expectEqualStrings("╭─▾ bash ○─╮", rowText(&after, 0, &row));
    try std.testing.expect(std.mem.startsWith(u8, rowText(&after, 1, &row), "│ l1"));
    try std.testing.expect(std.mem.startsWith(u8, rowText(&after, 2, &row), "│ l2"));
    try std.testing.expect(std.mem.startsWith(u8, rowText(&after, 3, &row), "│ l3"));
    try std.testing.expectEqualStrings("╰──────────╯", rowText(&after, 4, &row));
    for (0..5) |y| {
        try std.testing.expectEqual(@as(?u16, 11), rightEdge(&after, y)); // right border
    }
    try std.testing.expectEqual(@as(usize, 5), card.rows(20));
    try std.testing.expectEqual(@as(usize, 5), paintedRows(&after));

    // The bottom rung is a frame of its own, not an empty card: the
    // title alone, the collapsed marker, no body row and no note. It
    // keeps the header's own width — 8 content columns — where rung 2
    // is the same 8 plus the body rows.
    card.collapseLadder(-5);
    try std.testing.expectEqual(@as(u8, 0), card.rung);
    try std.testing.expect(!card.expanded());
    var collapsed = try Buffer.init(test_alloc, 20, 6);
    defer collapsed.deinit();
    try std.testing.expectEqual(@as(u16, 12), try card.draw(&collapsed, 0, 0, .fromNanoseconds(2)));
    try std.testing.expectEqualStrings("╭─▸ bash ○─╮", rowText(&collapsed, 0, &row));
    try std.testing.expectEqualStrings("╰──────────╯", rowText(&collapsed, 1, &row));
    try std.testing.expectEqual(@as(usize, 2), card.rows(20));
    try std.testing.expectEqual(@as(usize, 2), paintedRows(&collapsed));
}

test "card: the preview rung truncates the body and says how much it held back" {
    var card: Card = .{ .title = "bash", .body = "l1\nl2\nl3\nl4", .preview_lines = 2 };
    card.collapseLadder(1);

    var buf = try Buffer.init(test_alloc, 20, 6);
    defer buf.deinit();
    // The note (9 columns) is the widest row, so the box grows to hold it.
    try std.testing.expectEqual(@as(u16, 13), try card.draw(&buf, 0, 0, .fromNanoseconds(0)));

    var row: [128]u8 = undefined;
    try std.testing.expectEqualStrings("╭─▾ bash ○──╮", rowText(&buf, 0, &row));
    try std.testing.expect(std.mem.startsWith(u8, rowText(&buf, 1, &row), "│ l1"));
    try std.testing.expect(std.mem.startsWith(u8, rowText(&buf, 2, &row), "│ l2"));
    try std.testing.expectEqualStrings("│ … +2 more │", rowText(&buf, 3, &row));
    try std.testing.expectEqualStrings("╰───────────╯", rowText(&buf, 4, &row));
    // The note borrows `note_buf`, and the assertion above read it back.
    try std.testing.expectEqual(@as(usize, 5), card.rows(20));
    try std.testing.expectEqual(@as(usize, 5), paintedRows(&buf));
}

test "card: a card taller than the remaining buffer clips without trapping" {
    var card: Card = .{ .title = "tool", .body = "1\n2\n3\n4\n5\n6\n7\n8", .rung = 2 };
    try std.testing.expectEqual(@as(usize, 10), card.rows(40)); // unclipped

    // One row left: only the header row lands. Rung 2 is expanded, so
    // the header carries the expanded marker.
    var thin = try Buffer.init(test_alloc, 40, 3);
    defer thin.deinit();
    try std.testing.expectEqual(@as(u16, 12), try card.draw(&thin, 0, 2, .fromNanoseconds(0)));
    var row: [128]u8 = undefined;
    try std.testing.expectEqualStrings("╭─▾ tool ○─╮", rowText(&thin, 2, &row));
    try std.testing.expectEqual(@as(usize, 1), paintedRows(&thin));

    // Three rows left: header plus two body rows, no bottom border.
    var short = try Buffer.init(test_alloc, 40, 4);
    defer short.deinit();
    _ = try card.draw(&short, 0, 1, .fromNanoseconds(0));
    try std.testing.expectEqualStrings("╭─▾ tool ○─╮", rowText(&short, 1, &row));
    try std.testing.expect(std.mem.startsWith(u8, rowText(&short, 2, &row), "│ 1"));
    try std.testing.expect(std.mem.startsWith(u8, rowText(&short, 3, &row), "│ 2"));
    try std.testing.expectEqual(@as(usize, 3), paintedRows(&short));

    // Past the bottom edge: nothing at all, and no error.
    try std.testing.expectEqual(@as(u16, 0), try card.draw(&short, 0, 4, .fromNanoseconds(0)));
    // Too narrow for the frame: bare rows, and `rows` agrees.
    var narrow = try Buffer.init(test_alloc, 3, 2);
    defer narrow.deinit();
    _ = try card.draw(&narrow, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqualStrings("▾ t", rowText(&narrow, 0, &row));
    try std.testing.expectEqual(@as(usize, 9), card.rows(3)); // no bottom border
}

test "card: an ESC sequence in the title or body never reaches a cell" {
    var card: Card = .{ .title = "shell\x1b[2J", .body = "run\x1b[31mred\x07\n\tindented\x08" };
    card.collapseLadder(1);

    var buf = try Buffer.init(test_alloc, 40, 4);
    defer buf.deinit();
    _ = try card.draw(&buf, 0, 0, .fromNanoseconds(0));

    // The CSI bodies are consumed whole: no "[2J", no orphan "31m".
    var row: [128]u8 = undefined;
    const header = rowText(&buf, 0, &row);
    try std.testing.expect(std.mem.indexOfScalar(u8, header, 0x1b) == null);
    try std.testing.expectEqualStrings("╭─▾ shell ○──╮", header);
    try std.testing.expect(std.mem.startsWith(u8, rowText(&buf, 1, &row), "│ runred"));
    // A tab becomes spaces up to the next stop (column 2 -> 2 spaces),
    // behind the frame's own inner blank column; BS is gone.
    try std.testing.expect(std.mem.startsWith(u8, rowText(&buf, 2, &row), "│   indented"));

    for (0..buf.width) |i| {
        for (0..buf.height) |j| {
            const grapheme = buf.get(@intCast(i), @intCast(j)).grapheme;
            var probe: markdown.Sanitizer = .{};
            try std.testing.expect(probe.acceptCluster(grapheme));
        }
    }
}

test "card: an unterminated escape in the title sizes the box to what it paints" {
    // The OSC never terminates, so the sanitiser stays armed through the
    // space and the state glyph behind the title: the header paints the
    // marker and its space — two columns — and nothing else. The box is
    // exactly those two columns plus the four of frame. A title
    // measured apart from the glyph it eats would leave dead columns of
    // border and a state mark that never renders.
    var card: Card = .{ .title = "\x1b]0;never terminated", .body = "held back" };
    var buf = try Buffer.init(test_alloc, 40, 4);
    defer buf.deinit();
    try std.testing.expectEqual(@as(u16, 6), try card.draw(&buf, 0, 0, .fromNanoseconds(0)));

    var row: [128]u8 = undefined;
    try std.testing.expectEqualStrings("╭─▸ ─╮", rowText(&buf, 0, &row));
    try std.testing.expectEqualStrings("╰────╯", rowText(&buf, 1, &row));
    for (0..2) |y| try std.testing.expectEqual(@as(?u16, 5), rightEdge(&buf, y));
    // A collapsed card shows no body row, so the body costs no columns.
    try std.testing.expectEqual(@as(usize, 2), card.rows(40));
    try std.testing.expectEqual(@as(usize, 2), paintedRows(&buf));
}

test "diff: stats on a hand-built hunk are exact" {
    var hunk: Hunk = .{ .header = "@@ -1,6 +1,7 @@ fn", .old_count = 6, .new_count = 7 };
    try hunk.lines.appendSlice(test_alloc, &.{
        .{ .kind = .context, .text = "keep" },
        .{ .kind = .addition, .text = "a1" },
        .{ .kind = .addition, .text = "a2" },
        .{ .kind = .deletion, .text = "d1" },
        .{ .kind = .context, .text = "keep2" },
        .{ .kind = .addition, .text = "a3" },
        .{ .kind = .meta, .text = "\\ No newline at end of file" },
    });
    defer hunk.lines.deinit(test_alloc);

    const hunks = [_]Hunk{hunk};
    const d: Diff = .{ .hunks = &hunks };
    const s = d.stats();
    try std.testing.expectEqual(@as(usize, 3), s.added);
    try std.testing.expectEqual(@as(usize, 1), s.removed);
    // a1,a2,d1 is the longest run: `d1` is a changed row too, and only
    // the context row after it ends the run. a3 stands alone.
    try std.testing.expectEqual(@as(usize, 3), s.longest_run);
}

test "diff: an ESC sequence in a diff line renders no escape bytes" {
    var hunk: Hunk = .{};
    try hunk.lines.appendSlice(test_alloc, &.{
        .{ .kind = .addition, .text = "before\x1b[31mred\x07" },
        .{ .kind = .deletion, .text = "\x1b]0;title\x07after" },
    });
    defer hunk.lines.deinit(test_alloc);

    const hunks = [_]Hunk{hunk};
    var d: Diff = .{ .hunks = &hunks };
    var buf = try Buffer.init(test_alloc, 40, 2);
    defer buf.deinit();
    _ = try d.draw(&buf, 0, 0, .fromNanoseconds(0));

    var row: [128]u8 = undefined;
    const first = rowText(&buf, 0, &row);
    try std.testing.expect(std.mem.indexOfScalar(u8, first, 0x1b) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, first, 0x07) == null);
    try std.testing.expectEqualStrings("+beforered", first);
    try std.testing.expectEqualStrings("-after", rowText(&buf, 1, &row));

    // Assert on the cells a terminal would receive, not on bytes.
    for (0..buf.width) |i| {
        for (0..buf.height) |j| {
            const grapheme = buf.get(@intCast(i), @intCast(j)).grapheme;
            var probe: markdown.Sanitizer = .{};
            try std.testing.expect(probe.acceptCluster(grapheme));
        }
    }
}

test "diff: a sequence split over a row break consumes the next row's marker" {
    var hunk: Hunk = .{};
    try hunk.lines.appendSlice(test_alloc, &.{
        .{ .kind = .addition, .text = "a\x1b[3" },
        .{ .kind = .addition, .text = "1mb" },
    });
    defer hunk.lines.deinit(test_alloc);

    const hunks = [_]Hunk{hunk};
    var d: Diff = .{ .hunks = &hunks };
    var buf = try Buffer.init(test_alloc, 40, 2);
    defer buf.deinit();
    _ = try d.draw(&buf, 0, 0, .fromNanoseconds(0));

    // One `Pen` for the whole diff, so the CSI opened on row 0 is still
    // armed when row 1 starts: it eats that row's marker and the orphan
    // tail with it. No byte of the sequence reaches a cell, and no byte
    // inside it is rendered as if the sequence had ended.
    var row: [128]u8 = undefined;
    try std.testing.expectEqualStrings("+a", rowText(&buf, 0, &row));
    try std.testing.expectEqualStrings("b", rowText(&buf, 1, &row));
}

test "diff: unified rows carry a marker in the kind's style" {
    var hunk: Hunk = .{ .header = "@@ -1 +1 @@" };
    try hunk.lines.appendSlice(test_alloc, &.{
        .{ .kind = .context, .text = "same" },
        .{ .kind = .addition, .text = "new" },
        .{ .kind = .deletion, .text = "old" },
    });
    defer hunk.lines.deinit(test_alloc);

    const hunks = [_]Hunk{hunk};
    var d: Diff = .{ .hunks = &hunks, .show_headers = false };
    var buf = try Buffer.init(test_alloc, 20, 3);
    defer buf.deinit();
    _ = try d.draw(&buf, 0, 0, .fromNanoseconds(0));

    var row: [128]u8 = undefined;
    try std.testing.expectEqualStrings(" same", rowText(&buf, 0, &row));
    try std.testing.expectEqualStrings("+new", rowText(&buf, 1, &row));
    try std.testing.expectEqualStrings("-old", rowText(&buf, 2, &row));
    try std.testing.expect(buf.get(0, 0).style.eql(d.look.context));
    try std.testing.expect(buf.get(0, 1).style.eql(d.look.add));
    try std.testing.expect(buf.get(0, 2).style.eql(d.look.del));
}

test "diff: side-by-side pairs a removal with the addition that follows it" {
    var hunk: Hunk = .{};
    try hunk.lines.appendSlice(test_alloc, &.{
        .{ .kind = .context, .text = "same" },
        .{ .kind = .deletion, .text = "old" },
        .{ .kind = .addition, .text = "new" },
        .{ .kind = .deletion, .text = "gone" },
    });
    defer hunk.lines.deinit(test_alloc);

    const hunks = [_]Hunk{hunk};
    var d: Diff = .{ .hunks = &hunks, .layout = .side_by_side, .show_headers = false };
    var buf = try Buffer.init(test_alloc, 21, 4);
    defer buf.deinit();
    _ = try d.draw(&buf, 0, 0, .fromNanoseconds(0));

    // avail 21: gap 1, left 10, right column starting at column 11.
    var row: [128]u8 = undefined;
    try std.testing.expectEqualStrings("same", rowText(&buf, 0, &row));
    try std.testing.expect(std.mem.startsWith(u8, rowText(&buf, 1, &row), "old"));
    try std.testing.expectEqualStrings("n", buf.get(11, 1).grapheme);
    try std.testing.expectEqualStrings("w", buf.get(13, 1).grapheme);
    try std.testing.expectEqualStrings("gone", rowText(&buf, 2, &row));
    // The pair shares one row, and the lone removal keeps the left one.
    try std.testing.expectEqual(@as(usize, 3), paintedRows(&buf));
}

test "diff: parseUnified reads hunks, header ranges, and every line kind" {
    const src = "diff --git a/f b/f\n" ++
        "index 111..222 100644\n" ++
        "--- a/f\n" ++
        "+++ b/f\n" ++
        "@@ -10,4 +10,5 @@ fn main()\n" ++
        " context\n" ++
        "-gone\n" ++
        "+fresh\n" ++
        " tail\n" ++
        "\\ No newline at end of file\n";

    var hunks: std.ArrayList(Hunk) = .empty;
    defer deinitHunks(test_alloc, &hunks);
    try parseUnified(test_alloc, src, &hunks);

    try std.testing.expectEqual(@as(usize, 1), hunks.items.len);
    const hunk = hunks.items[0];
    try std.testing.expectEqualStrings("@@ -10,4 +10,5 @@ fn main()", hunk.header);
    try std.testing.expectEqual(@as(u32, 10), hunk.old_start);
    try std.testing.expectEqual(@as(u32, 4), hunk.old_count);
    try std.testing.expectEqual(@as(u32, 10), hunk.new_start);
    try std.testing.expectEqual(@as(u32, 5), hunk.new_count);
    // The trailing newline is the end of input, not an empty context row.
    try std.testing.expectEqual(@as(usize, 5), hunk.lines.items.len);
    try std.testing.expectEqual(LineKind.context, hunk.lines.items[0].kind);
    try std.testing.expectEqualStrings("context", hunk.lines.items[0].text);
    try std.testing.expectEqual(LineKind.deletion, hunk.lines.items[1].kind);
    try std.testing.expectEqualStrings("gone", hunk.lines.items[1].text);
    try std.testing.expectEqual(LineKind.addition, hunk.lines.items[2].kind);
    try std.testing.expectEqualStrings("fresh", hunk.lines.items[2].text);
    try std.testing.expectEqual(LineKind.context, hunk.lines.items[3].kind);
    try std.testing.expectEqualStrings("tail", hunk.lines.items[3].text);
    try std.testing.expectEqual(LineKind.meta, hunk.lines.items[4].kind);
    try std.testing.expectEqualStrings("\\ No newline at end of file", hunk.lines.items[4].text);

    var d: Diff = .{ .hunks = hunks.items };
    const s = d.stats();
    try std.testing.expectEqual(@as(usize, 1), s.added);
    try std.testing.expectEqual(@as(usize, 1), s.removed);
    // "-gone" and "+fresh" are adjacent changed rows — a replacement —
    // so the run between the context rows is two long.
    try std.testing.expectEqual(@as(usize, 2), s.longest_run);

    var buf = try Buffer.init(test_alloc, 30, 8);
    defer buf.deinit();
    _ = try d.draw(&buf, 0, 0, .fromNanoseconds(0));
    var row: [128]u8 = undefined;
    try std.testing.expectEqualStrings("@@ -10,4 +10,5 @@ fn main()", rowText(&buf, 0, &row));
    try std.testing.expectEqualStrings(" context", rowText(&buf, 1, &row));
    try std.testing.expectEqualStrings("-gone", rowText(&buf, 2, &row));
    try std.testing.expectEqualStrings("+fresh", rowText(&buf, 3, &row));
    try std.testing.expectEqualStrings(" tail", rowText(&buf, 4, &row));
    try std.testing.expectEqualStrings("\\ No newline at end of file", rowText(&buf, 5, &row));
}

test "diff: a header without counts means one line" {
    const src = "@@ -7 +9 @@ heading\r\n-a\r\n+b\r\n";
    var hunks: std.ArrayList(Hunk) = .empty;
    defer deinitHunks(test_alloc, &hunks);
    try parseUnified(test_alloc, src, &hunks);

    try std.testing.expectEqual(@as(usize, 1), hunks.items.len);
    try std.testing.expectEqualStrings("@@ -7 +9 @@ heading", hunks.items[0].header);
    try std.testing.expectEqual(@as(u32, 7), hunks.items[0].old_start);
    try std.testing.expectEqual(@as(u32, 1), hunks.items[0].old_count);
    try std.testing.expectEqual(@as(u32, 9), hunks.items[0].new_start);
    try std.testing.expectEqual(@as(u32, 1), hunks.items[0].new_count);
    try std.testing.expectEqual(@as(usize, 2), hunks.items[0].lines.items.len);
    try std.testing.expectEqualStrings("b", hunks.items[0].lines.items[1].text);
}

test "diff: a malformed hunk header is an error and renders nothing" {
    const bad = [_][]const u8{
        "@@",
        "@@ -1,2 +3,4",
        "@@ 1,2 +3,4 @@",
        "@@ -x +1 @@",
        "@@ -1,2 @@",
        "@@ -1,+1 @@",
        "@@ -1,2 -3,4 @@",
        "@@ -99999999999999999 +1 @@",
        "@@@ -1 +1 @@",
    };

    var hunks: std.ArrayList(Hunk) = .empty;
    defer deinitHunks(test_alloc, &hunks);
    var buf = try Buffer.init(test_alloc, 10, 2);
    defer buf.deinit();

    for (bad) |text| {
        hunks.clearRetainingCapacity();
        buf.clear();
        try std.testing.expectError(
            error.MalformedHunkHeader,
            parseUnified(test_alloc, text, &hunks),
        );
        try std.testing.expectEqual(@as(usize, 0), hunks.items.len);

        // An empty hunk list renders nothing, not a broken row.
        var d: Diff = .{ .hunks = hunks.items };
        try std.testing.expectEqual(@as(u16, 0), try d.draw(&buf, 0, 0, .fromNanoseconds(0)));
        try std.testing.expectEqual(@as(usize, 0), paintedRows(&buf));
    }
}

test "diff: a malformed hunk-body line is an error, pre-hunk noise is not" {
    var hunks: std.ArrayList(Hunk) = .empty;
    defer deinitHunks(test_alloc, &hunks);

    // Extended headers and a file header are noise, not corruption.
    const noise = "diff --git a/f b/f\nnew file mode 100644\n--- /dev/null\n";
    try parseUnified(test_alloc, noise, &hunks);
    try std.testing.expectEqual(@as(usize, 0), hunks.items.len);

    try std.testing.expectError(
        error.MalformedHunkLine,
        parseUnified(test_alloc, "@@ -1 +1 @@\nnot a diff line\n", &hunks),
    );
    // The header before the bad line is still the caller's to free.
    try std.testing.expectEqual(@as(usize, 1), hunks.items.len);
    try std.testing.expectEqual(@as(usize, 0), hunks.items[0].lines.items.len);
}

test "cards: draw never allocates (FailingAllocator guard)" {
    var failing = std.testing.FailingAllocator.init(test_alloc, .{ .fail_index = 1 });
    const alloc = failing.allocator();
    // Allocation 0 (Buffer.init) succeeds; any allocation inside a draw
    // would trip the guard with OutOfMemory.
    var buf = try Buffer.init(alloc, 24, 8);
    defer buf.deinit();

    var card: Card = .{ .title = "bash", .body = "a\nb\nc\nd", .preview_lines = 2 };
    card.collapseLadder(1);
    _ = try card.draw(&buf, 0, 0, .fromNanoseconds(0));
    card.collapseLadder(1);
    _ = try card.draw(&buf, 0, 0, .fromNanoseconds(0));

    var hunk: Hunk = .{ .header = "@@ -1 +1 @@" };
    try hunk.lines.appendSlice(test_alloc, &.{
        .{ .kind = .addition, .text = "a very long added line" },
        .{ .kind = .deletion, .text = "a very long removed line" },
        .{ .kind = .context, .text = "a very long context line" },
    });
    defer hunk.lines.deinit(test_alloc);

    const hunks = [_]Hunk{hunk};
    var d: Diff = .{ .hunks = &hunks };
    _ = try d.draw(&buf, 0, 4, .fromNanoseconds(0));
    var paired: Diff = .{ .hunks = &hunks, .layout = .side_by_side };
    _ = try paired.draw(&buf, 0, 4, .fromNanoseconds(0));
}

test "diff: a Region band carries the styled cells and keeps source escapes out of the bytes" {
    // Five rows exercise horizontal and vertical clipping. A later
    // expanded frame brings the malicious OSC and split CSI into view.
    var hunk: Hunk = .{ .header = "@@ -3,4 +3,5 @@ fn main()" };
    try hunk.lines.appendSlice(test_alloc, &.{
        .{ .kind = .context, .text = "keep" },
        .{ .kind = .deletion, .text = "old" },
        .{ .kind = .addition, .text = "caf\u{e9} \u{4e00}" },
        .{ .kind = .addition, .text = "a rather long added line that clips" },
        .{ .kind = .deletion, .text = "\x1b]0;window title\x07payload" },
        .{ .kind = .addition, .text = "a\x1b[3" },
        .{ .kind = .addition, .text = "1mb" },
    });
    defer hunk.lines.deinit(test_alloc);

    const hunks = [_]Hunk{hunk};
    var d: Diff = .{ .hunks = &hunks, .look = .{ .context = .{ .fg = .{ .ansi256 = 244 } } } };

    var region = try Region.init(test_alloc, .{
        .height = 5,
        .append_lines = false,
        .sync_output = false,
    });
    defer region.deinit();
    // Band-only viewport: the test sink is no screen, so the band's own
    // rows are the visible geometry.
    try region.resize(24, 5, 5);
    _ = try d.draw(&region.cur, 0, 0, .fromNanoseconds(0));

    // The cells the band will emit: the header in the meta style, the
    // context marker in the style the app configured, and the addition
    // in the add style — a card-specific Look, not a default.
    try std.testing.expect(region.cur.get(0, 0).style.eql(d.look.meta));
    try std.testing.expect(region.cur.get(0, 1).style.eql(d.look.context));
    try std.testing.expect(region.cur.get(0, 2).style.eql(d.look.del));
    try std.testing.expect(region.cur.get(0, 3).style.eql(d.look.add));
    // The wide grapheme holds two columns; the combining cluster holds
    // one, glued to its base.
    try std.testing.expectEqualStrings("\u{4e00}", region.cur.get(6, 3).grapheme);
    try std.testing.expect(region.cur.get(7, 3).wide);

    var tw: TestWriter = .{};
    tw.init();
    try region.render(&tw.w);
    const out = tw.bytes();

    // The band is 24 columns and the header is 25, so the header row is
    // clipped exactly like the long addition below it.
    // Required payload: the band rows reach the wire, clipped at the
    // geometry, and the meta/context/add/del styles are emitted as SGR.
    try std.testing.expect(std.mem.indexOf(u8, out, "@@ -3,4 +3,5 @@ fn main(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " keep") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "-old") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+caf\u{e9} \u{4e00}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "38;5;244") != null); // context fg
    try std.testing.expect(std.mem.indexOf(u8, out, "38;5;9") != null or
        std.mem.indexOf(u8, out, "31m") != null); // del fg
    try std.testing.expect(std.mem.indexOf(u8, out, "32m") != null); // add fg

    // Clip geometry: the long addition stops at the band edge and the
    // row past the bottom never paints.
    try std.testing.expect(std.mem.indexOf(u8, out, "+a rather long added lin") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "clips") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "payload") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "1mb") == null);

    // Every escape in the frame is one the renderer wrote: the paint
    // envelope and the SGR/CUF runs. The injected OSC, its BEL and its
    // title text are gone, and the split CSI left no orphan tail.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b]") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x07") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "window title") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[?1049h") == null);
    var esc: usize = 0;
    var start: usize = 0;
    while (std.mem.findScalarPos(u8, out, start, 0x1b)) |at| {
        esc += 1;
        try std.testing.expect(at + 1 < out.len);
        try std.testing.expect(out[at + 1] == '[');
        start = at + 1;
    }
    try std.testing.expect(esc > 0);

    // No history corruption: the frame staged no ledger batch, and the
    // band's own cells are the ones the app drew.
    try std.testing.expectEqual(@as(usize, 0), region.historyBytes());
    try std.testing.expectEqual(@as(usize, 0), (try region.historyPending()).len);
    try std.testing.expect(region.cur.get(0, 0).style.eql(d.look.meta));

    // Bring every source row into the band. The sanitizer must remove
    // the escape bodies, not merely hide them below the clipping edge.
    try region.resize(24, 8, 8);
    _ = try d.draw(&region.cur, 0, 0, .fromNanoseconds(0));
    var expanded: TestWriter = .{};
    expanded.init();
    try region.render(&expanded.w);
    try std.testing.expect(std.mem.indexOf(u8, expanded.bytes(), "payload") != null);
    try std.testing.expect(std.mem.indexOf(u8, expanded.bytes(), "window title") == null);
    try std.testing.expect(std.mem.indexOf(u8, expanded.bytes(), "\x1b]") == null);
    try std.testing.expect(std.mem.indexOf(u8, expanded.bytes(), "\x07") == null);
    try std.testing.expect(std.mem.indexOf(u8, expanded.bytes(), "1mb") == null);
    try std.testing.expectEqualStrings("b", region.cur.get(0, 7).grapheme);
}

test "diff: a Region writes its ledger above the band and never erases above it" {
    var hunk: Hunk = .{ .header = "@@ -1 +1 @@" };
    try hunk.lines.appendSlice(test_alloc, &.{
        .{ .kind = .context, .text = "keep" },
        .{ .kind = .addition, .text = "new" },
    });
    defer hunk.lines.deinit(test_alloc);

    const hunks = [_]Hunk{hunk};
    var d: Diff = .{ .hunks = &hunks };

    var region = try Region.init(test_alloc, .{
        .height = 2,
        .append_lines = false,
        .sync_output = false,
    });
    defer region.deinit();
    try region.resize(24, 2, 2);

    // First frame: the band paints, no ledger row yet.
    _ = try d.draw(&region.cur, 0, 0, .fromNanoseconds(0));
    var tw: TestWriter = .{};
    tw.init();
    try region.render(&tw.w);
    // Two band rows carry the header and the first diff row; the
    // addition row is below the band and never painted. The context
    // marker is a blank cell, so the wire carries a cursor move and
    // then the row's text.
    try std.testing.expect(std.mem.indexOf(u8, tw.bytes(), "keep") != null);

    // Queue a ledger row and an append. Both land ABOVE the band; the
    // diff stays painted underneath.
    const id = try region.writeTranscript(&.{"ledger row"});
    try region.append(.{ .line = "queued row" });
    var tw2: TestWriter = .{};
    tw2.init();
    try region.render(&tw2.w);
    const out = tw2.bytes();

    try std.testing.expect(std.mem.indexOf(u8, out, "ledger row") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "queued row") != null);
    // The band is repainted under the ledger rows: its header and its
    // first diff row are both still on the wire.
    try std.testing.expect(std.mem.indexOf(u8, out, "@@ -1 +1 @@") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "keep") != null);
    // The ledger flush erases to end of screen from the band top (ED0),
    // never above it: no ED1/ED2/ED3 and no ED with an absolute row.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1J") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[3J") == null);

    // A replay batch supersedes what was staged, and the transport's
    // acknowledgement frees the retained copy exactly once.
    try std.testing.expectEqualSlices(u64, &.{id}, try region.historyPending());
    try region.acknowledgeHistory(id);
    try std.testing.expectEqual(@as(usize, 0), region.historyBytes());
    try std.testing.expectError(error.UnknownHistoryId, region.acknowledgeHistory(id));
    try std.testing.expectError(
        error.DuplicateHistoryId,
        region.writeHistory(.{ .id = id, .rows = &.{"again"}, .kind = .append }),
    );
}
