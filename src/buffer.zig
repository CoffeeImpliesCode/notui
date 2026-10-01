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
//!
//! ROADMAP B4: damage is row-granular and decided in a single pass (each
//! row is compared exactly once, an unchanged row costs no bytes at all),
//! and the SGR that goes with it is memoized in a fixed-size
//! allocation-free cache of encoded transitions keyed by the style the
//! terminal actually receives.

const std = @import("std");
const Cell = @import("cell.zig").Cell;
const Color = @import("color.zig").Color;
const Style = @import("style.zig").Style;
const emit = @import("emit.zig");
const Width = @import("width.zig");

/// The default emitted style: no colour, no attribute. Every frame
/// starts and ends here, so the terminal's active SGR is default at a
/// frame boundary and every row's erase paints the default background.
const default_style: Emitted = .{};

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
        self.* = undefined;
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
        if (x >= self.width or y >= self.height) return .{};
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
        // A continuation at column 0 has no lead (a width-2 glyph can
        // never start at the last column), so the subtraction is
        // defensive-only.
        if (self.cells[idx].wide and idx > 0) {
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
    /// One pass over the grid decides and paints (ROADMAP B4): every row
    /// is compared exactly once, and a row equal to `prev` is skipped
    /// whole — no cursor move, no erase, no SGR. An idle frame therefore
    /// writes NOTHING (architecture §3) and pays only the comparison.
    ///
    /// A changed row is written as `\r` (+ `\n` relative moves) then a
    /// column-1 `eraseLine` (`\r\x1b[K` — the tmux scroll-on-clear
    /// mitigation, §9.7), which blanks the row and kills any stale tail.
    /// The erase runs under a default background, because EL paints with
    /// the *active* background: without the reset a blank tail would
    /// inherit the previous row's colour. A foreground-only style needs
    /// no reset — its erase already paints the default background.
    /// Within a row, wide continuations and default-styled blanks emit
    /// nothing (blank skips advance with CUF) while a styled blank still
    /// emits, so its background paints. SGR is written only when the
    /// *emitted* style changes (libvaxis DAM pattern), encoded as the
    /// shorter of a combined transition and reset-then-set. The frame
    /// ends with a reset when the last emitted style was non-default, so
    /// the terminal's active style is always default at a frame boundary
    /// and the next frame starts clean.
    pub fn renderDiff(self: *const Buffer, prev: *const Buffer, w: anytype) !void {
        var styles: SgrCache = .{};
        var tracked: Emitted = default_style;
        var cur_row: usize = 0;
        const rows: usize = self.height;
        for (0..rows) |y| {
            if (!self.rowChanged(prev, y)) continue; // unchanged row: leave as-is

            // Move down to this row (relative moves only), then erase at
            // column 1: `\r` + n x `\n` lands on column 1 of row y.
            try w.writeAll("\r");
            var down = y - cur_row;
            while (down > 0) : (down -= 1) try w.writeByte('\n');
            cur_row = y;
            // EL fills with the *active* background, so a row that
            // follows a background-coloured one resets first. A
            // foreground-only style needs nothing: its erase already
            // paints the default background.
            if (tracked.bg() != 0) try styles.emit(w, &tracked, default_style);
            try emit.eraseLine(w);

            try self.writeRow(w, y, &tracked, &styles);
        }

        // Frame-boundary hygiene: leave the terminal SGR state default.
        try styles.emit(w, &tracked, default_style);
    }

    /// Emit the full buffer band to `w` (band-scoped, no absolute CUP).
    /// Used for the width-change full redraw (region strategy 2) after
    /// `ESC[J`; the cursor sits at the anchor (column 0 of row 0). Each
    /// row: `\r`(+`\n`) + column-1 eraseLine, then the row's cells with
    /// the same style-tracking rules as `renderDiff`.
    pub fn renderAll(self: *const Buffer, w: anytype) !void {
        var styles: SgrCache = .{};
        var tracked: Emitted = default_style;
        const rows: usize = self.height;
        for (0..rows) |y| {
            try w.writeAll(if (y == 0) "\r" else "\r\n");
            if (tracked.bg() != 0) try styles.emit(w, &tracked, default_style);
            try emit.eraseLine(w);
            try self.writeRow(w, y, &tracked, &styles);
        }
        // Frame-boundary hygiene: leave the terminal SGR state default.
        try styles.emit(w, &tracked, default_style);
    }

    /// Flat slice of row `y`'s cells; the caller must have checked
    /// `y < height`.
    fn rowCells(self: *const Buffer, y: usize) []const Cell {
        return self.cells[y * @as(usize, self.width) ..][0..self.width];
    }

    /// Whether row `y` differs from `prev`'s row `y`: the whole
    /// row-granular damage test. A row past `prev`'s height — or any row
    /// once the band grew wider — is damage, because the new columns have
    /// never been painted.
    ///
    /// The compare is by content, over the bytes each cell points at
    /// right now. That answers the right question only when `prev` holds
    /// the previous frame's CONTENT rather than a view of storage the app
    /// has since rewritten: `Region` owns `prev`'s text in its own arena
    /// for exactly that reason, and a caller that keeps a `prev` built by
    /// shallow cell copies inherits the same defect — an in-place rewrite
    /// looks unchanged to this test and to `Cell.eql` alike.
    ///
    /// Content, never pointer identity: `prev` legitimately points at
    /// different storage holding equal bytes, so a pointer compare would
    /// report damage on every frame and defeat the early-out. The byte
    /// compare below is a fast path for the content test, not a hash:
    /// equal bytes are cells `Cell.eql` would also call equal, so it can
    /// never accept a row the exact per-cell compare would call changed.
    /// A mismatch falls through to that compare, which decides.
    fn rowChanged(self: *const Buffer, prev: *const Buffer, y: usize) bool {
        if (y >= prev.height or self.width > prev.width) return true;
        const cur = self.rowCells(y);
        const old = prev.rowCells(y);
        if (std.mem.eql(u8, rowBytes(cur), rowBytes(old))) return false;
        var x: usize = 0;
        while (x < cur.len) : (x += 1) {
            if (!cur[x].eql(old[x])) return true;
        }
        return false;
    }

    /// Emit one row (just erased at column 1) to `w`. Wide continuations
    /// and default-styled blanks never emit text; blank-cell skips
    /// advance the cursor with CUF, and a styled blank does emit so its
    /// background paints. SGR is written only when the emitted style
    /// changes from `tracked`, through the per-frame memo.
    fn writeRow(
        self: *const Buffer,
        w: anytype,
        y: usize,
        tracked: *Emitted,
        styles: *SgrCache,
    ) !void {
        const row = self.rowCells(y);
        var x: usize = 0;
        var phys_col: usize = 0; // terminal cursor column, 0-indexed
        while (x < row.len) {
            const cell = row[x];

            // Wide continuations never emit text; their column was
            // covered by the lead's write (which advances 2).
            if (cell.wide or cell.grapheme.len == 0) {
                x += 1;
                continue;
            }
            // Default-styled blanks are already blank after the erase.
            if (cell.eql(Cell{})) {
                x += 1;
                continue;
            }

            const wg = Width.graphemeWidth(cell.grapheme);
            const wcell: usize = if (wg >= 2) 2 else 1;
            // A wide glyph at the last column has no continuation cell;
            // drop it (graceful — over-wide never errors).
            if (x + wcell > row.len) {
                x += 1;
                continue;
            }

            if (x > phys_col) {
                try w.print("\x1b[{d}C", .{x - phys_col});
            }
            try styles.emit(w, tracked, Emitted.of(cell.style));
            try w.writeAll(cell.grapheme);
            phys_col = x + wcell;
            x += wcell;
        }
    }
};

/// A row of cells as raw bytes, for the damage test's fast path. A cell
/// holds no pointer the compare dereferences: equal bytes are cells that
/// `Cell.eql` would also call equal, so the fast path can only ever
/// accept a truly unchanged row.
fn rowBytes(row: []const Cell) []const u8 {
    return @as([*]const u8, @ptrCast(row.ptr))[0 .. row.len * @sizeOf(Cell)];
}

/// The style a cell's `Style` actually puts on the wire, packed into one
/// comparable word: `[ fg:26 | bg:26 | attrs:7 ]`, zero being default.
///
/// A `Style` carries three things the terminal never sees: a `null`
/// colour and `Color.default` both emit nothing, and a hyperlink is not
/// emitted at all (OSC 8 is deferred, emit.zig:6). Keying the memo on
/// this view instead of on `Style.eql` is what stops a null-vs-default
/// colour or a hyperlink swap from spending a reset that repaints the
/// same pixels. No borrowed bytes reach this word — cell graphemes are
/// the only borrowed data — so a key can never go stale under a caller
/// that mutates its arena.
const Emitted = struct {
    key: u64 = 0,

    const bg_shift: u6 = 26;
    const attr_shift: u6 = 52;
    const colour_mask: u64 = (1 << 26) - 1;

    // Attribute bit order matches emit.writeStyleProfile: bold, dim,
    // italic, underline, blink, reverse, strikethrough.
    const bold: u8 = 1 << 0;
    const dim: u8 = 1 << 1;

    /// SGR parameter that turns each attribute on.
    const attr_on = [7]u8{ 1, 2, 3, 4, 5, 7, 9 };
    /// SGR parameter that turns each attribute off. ECMA-48 has no
    /// separate "not bold" or "not dim": 22 ("normal intensity") clears
    /// both, so both bits map to it and `appendTransition` re-sets
    /// whichever of the two survives the transition.
    const attr_off = [7]u8{ 22, 22, 23, 24, 25, 27, 29 };

    /// The emitted view of `style`: colours normalised to what they
    /// print, attributes to bits, hyperlink dropped.
    fn of(style: Style) Emitted {
        return .{ .key = @as(u64, colourBits(style.fg, false)) |
            @as(u64, colourBits(style.bg, true)) << bg_shift |
            @as(u64, attrBits(style.attrs)) << attr_shift };
    }

    fn eql(a: Emitted, b: Emitted) bool {
        return a.key == b.key;
    }

    fn isDefault(a: Emitted) bool {
        return a.key == 0;
    }

    fn fg(a: Emitted) u32 {
        return @truncate(a.key & colour_mask);
    }

    fn bg(a: Emitted) u32 {
        return @truncate((a.key >> bg_shift) & colour_mask);
    }

    fn attrs(a: Emitted) u8 {
        return @truncate(a.key >> attr_shift);
    }
};

/// Pack a `Style` colour into 26 bits: kind in the top two, payload
/// below. Kind 0 — a `null` field or `Color.default` — is the all-zero
/// word and emits nothing. An `ansi` colour stores the SGR parameter it
/// prints, so the encoder never has to re-derive it.
fn colourBits(colour: ?Color, background: bool) u32 {
    const c = colour orelse return 0;
    return switch (c) {
        .default => 0,
        .ansi => |a| (1 << 24) | @as(u32, if (background) a.bgCode() else a.fgCode()),
        .ansi256 => |n| (@as(u32, 2) << 24) | n,
        .rgb => |rgb| (3 << 24) | (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b,
    };
}

fn attrBits(a: Style.Attrs) u8 {
    var bits: u8 = 0;
    if (a.bold) bits |= Emitted.bold;
    if (a.dim) bits |= Emitted.dim;
    if (a.italic) bits |= 1 << 2;
    if (a.underline) bits |= 1 << 3;
    if (a.blink) bits |= 1 << 4;
    if (a.reverse) bits |= 1 << 5;
    if (a.strikethrough) bits |= 1 << 6;
    return bits;
}

/// Transitions one frame keeps encoded. A frame repeats the same handful
/// of style changes on every row, so the encoded bytes earn their keep
/// well inside this bound; a frame with more distinct transitions than
/// slots still encodes every one of them correctly, it just re-encodes.
const sgr_cache_slots = 16;

/// Longest SGR the encoder can produce: one CSI carrying the
/// off-parameters followed by the on-parameters.
const max_sgr_bytes = 80;

/// Worst-case SGR the encoder can produce: one CSI carrying every
/// off-parameter followed by every on-parameter. The intensity re-set
/// behind a 22 shares the on-parameter budget with the rest: the
/// on-list is always a subset of the target style's own attributes.
const sgr_worst_case: usize = 2 + // "\x1b["
    3 * 8 + //      eight off-parameters, ';' plus two digits each
    2 * 7 + //      seven attribute on-parameters, ';' plus one digit each
    18 + 18 + //    truecolor fg and bg, each with a leading ';'
    1; //           'm'

comptime {
    if (sgr_worst_case > max_sgr_bytes) {
        @compileError("buffer: max_sgr_bytes must hold the worst-case SGR");
    }
    if (!std.math.isPowerOfTwo(sgr_cache_slots)) {
        @compileError("buffer: sgr_cache_slots must be a power of two");
    }
}

/// Fixed-size, allocation-free memo of encoded SGR transitions.
///
/// A slot holds the two packed words that name a transition plus the
/// bytes it encodes. The slot index is a hash of those two words and is
/// never trusted: a hit re-compares both keys, so a colliding entry costs
/// a re-encode, never a wrong sequence, and nothing hashed here can go
/// stale — a key is a function of the style alone, never of borrowed
/// bytes. One cache per frame means there is nothing to persist and
/// nothing to invalidate.
const SgrCache = struct {
    used: [sgr_cache_slots]bool = @splat(false),
    from_keys: [sgr_cache_slots]u64 = undefined,
    to_keys: [sgr_cache_slots]u64 = undefined,
    lens: [sgr_cache_slots]u8 = undefined,
    bytes: [sgr_cache_slots][max_sgr_bytes]u8 = undefined,

    /// Move the terminal from `tracked.*` to `to`, writing nothing when
    /// the two already describe the same bytes on the wire.
    fn emit(self: *SgrCache, w: anytype, tracked: *Emitted, to: Emitted) !void {
        if (tracked.eql(to)) return; // the terminal already shows `to`
        const from = tracked.*;
        const slot = slotFor(from, to);
        if (self.holds(slot, from, to)) {
            try w.writeAll(self.bytes[slot][0..self.lens[slot]]);
        } else {
            self.store(slot, from, to);
            try w.writeAll(self.bytes[slot][0..self.lens[slot]]);
        }
        tracked.* = to;
    }

    fn holds(self: *const SgrCache, slot: usize, from: Emitted, to: Emitted) bool {
        return self.used[slot] and
            self.from_keys[slot] == from.key and
            self.to_keys[slot] == to.key;
    }

    fn store(self: *SgrCache, slot: usize, from: Emitted, to: Emitted) void {
        const len = encodeTransition(&self.bytes[slot], from, to);
        self.lens[slot] = len;
        self.from_keys[slot] = from.key;
        self.to_keys[slot] = to.key;
        self.used[slot] = true;
    }

    /// The bucket a transition lands in. Only the choice is hashed; the
    /// hit itself is the exact key compare in `holds`.
    fn slotFor(from: Emitted, to: Emitted) usize {
        var hash = from.key *% 0x9e37_79b9_7f4a_7c15;
        hash ^= to.key *% 0x1656_67b1_9e37_79f9;
        hash ^= hash >> 33;
        return @as(usize, @truncate(hash)) & (sgr_cache_slots - 1);
    }
};

/// Encode `from` -> `to` into `buf` and return its length. Two
/// candidates, shortest wins:
/// 1. one CSI carrying the off-parameters (`22`, `39`, ...) followed by
///    the on-parameters, so a field that survives the transition is never
///    re-sent and a dropped field never costs a full reset. Intensity is
///    the one field that cannot survive untouched: 22 clears bold and
///    dim together, so the one `to` keeps is re-set behind the clear;
/// 2. the pre-B4 stream, `CSI 0m` then the whole target style, for the
///    pairs where listing every off-parameter runs longer than a reset
///    (two dropped attributes plus a new 256-colour index).
///
/// The result is never longer than (2), so no transition can grow.
fn encodeTransition(buf: *[max_sgr_bytes]u8, from: Emitted, to: Emitted) u8 {
    var reset_form: [max_sgr_bytes]u8 = undefined;
    const combined_len = appendTransition(buf, from, to);
    const reset_len = appendResetThenSet(&reset_form, to);
    if (reset_len < combined_len) {
        @memcpy(buf[0..reset_len], reset_form[0..reset_len]);
        return @intCast(reset_len);
    }
    return @intCast(combined_len);
}

/// Candidate 1: the off-parameters, then the on-parameters, in one CSI.
fn appendTransition(buf: *[max_sgr_bytes]u8, from: Emitted, to: Emitted) usize {
    @memcpy(buf[0..emit.csi.len], emit.csi);
    var len: usize = emit.csi.len;
    var has_param = false;

    // Off: every field `from` had that `to` does not. 22 clears bold
    // and dim together, so whichever of the two `to` keeps joins the
    // on-list below — it goes down with the dropped one otherwise.
    const dropped: u8 = from.attrs() & ~to.attrs();
    var added: u8 = to.attrs() & ~from.attrs();
    if (dropped & (Emitted.bold | Emitted.dim) != 0) {
        len = appendParam(buf, len, &has_param, 22);
        added |= to.attrs() & (Emitted.bold | Emitted.dim);
    }
    for (Emitted.attr_off, 0..) |code, bit| {
        if (bit < 2) continue; // bold and dim clear together, above
        if (dropped & (@as(u8, 1) << @intCast(bit)) == 0) continue;
        len = appendParam(buf, len, &has_param, code);
    }
    const fg_differs = from.fg() != to.fg();
    const bg_differs = from.bg() != to.bg();
    // A colour is only worth clearing when one was actually set: `39`
    // on an already-default foreground is three bytes of nothing.
    if (from.fg() != 0 and fg_differs) len = appendParam(buf, len, &has_param, 39);
    if (from.bg() != 0 and bg_differs) len = appendParam(buf, len, &has_param, 49);

    // On: every field `to` has that `from` did not, plus the intensity
    // 22 took down with it (see the off-list above).
    for (Emitted.attr_on, 0..) |code, bit| {
        if (added & (@as(u8, 1) << @intCast(bit)) == 0) continue;
        len = appendParam(buf, len, &has_param, code);
    }
    if (fg_differs) len = appendColour(buf, len, &has_param, to.fg(), 38);
    if (bg_differs) len = appendColour(buf, len, &has_param, to.bg(), 48);

    if (!has_param) return 0; // unreachable: unequal keys mean a field changed
    buf[len] = 'm';
    return len + 1;
}

/// Candidate 2: the full reset, then every non-default field of `to` —
/// the pre-B4 stream, in the same parameter order.
fn appendResetThenSet(buf: *[max_sgr_bytes]u8, to: Emitted) usize {
    @memcpy(buf[0..emit.reset.len], emit.reset);
    var len: usize = emit.reset.len;
    if (to.isDefault()) return len;

    var has_param = false;
    @memcpy(buf[len..][0..emit.csi.len], emit.csi);
    len += emit.csi.len;
    for (Emitted.attr_on, 0..) |code, bit| {
        if (to.attrs() & (@as(u8, 1) << @intCast(bit)) == 0) continue;
        len = appendParam(buf, len, &has_param, code);
    }
    len = appendColour(buf, len, &has_param, to.fg(), 38);
    len = appendColour(buf, len, &has_param, to.bg(), 48);
    buf[len] = 'm';
    return len + 1;
}

/// Append a packed colour's parameters: `base` (`38` or `48`) plus the
/// kind-specific tail. Kind 0 appends nothing — that is the default.
/// Each payload component is masked to a byte before it is widened to
/// the parameter width: the packed word carries the components
/// side by side, so an unmasked shift would hand the next parameter
/// the neighbouring component's bits.
fn appendColour(buf: *[max_sgr_bytes]u8, len: usize, has_param: *bool, bits: u32, base: u8) usize {
    const kind = bits >> 24;
    const payload = bits & 0x00ff_ffff;
    switch (kind) {
        0 => return len,
        1 => return appendParam(buf, len, has_param, @intCast(payload & 0xff)),
        2 => {
            var at = appendParam(buf, len, has_param, base);
            at = appendParam(buf, at, has_param, 5);
            return appendParam(buf, at, has_param, @intCast(payload & 0xff));
        },
        3 => {
            var at = appendParam(buf, len, has_param, base);
            at = appendParam(buf, at, has_param, 2);
            at = appendParam(buf, at, has_param, @intCast((payload >> 16) & 0xff));
            at = appendParam(buf, at, has_param, @intCast((payload >> 8) & 0xff));
            return appendParam(buf, at, has_param, @intCast(payload & 0xff));
        },
        else => unreachable, // colourBits never builds another kind
    }
}

/// Append one SGR parameter, prefixed with `;` unless it is the first.
/// The value is `u16`, not `u8`: an RGB component runs to 255, and a
/// parameter truncated to its low eight bits would repaint the wrong
/// colour. Leading zeros are dropped, so a two-digit or one-digit
/// parameter still costs the bytes it always cost.
fn appendParam(buf: *[max_sgr_bytes]u8, len: usize, has_param: *bool, value: u16) usize {
    var at = len;
    if (has_param.*) {
        buf[at] = ';';
        at += 1;
    } else {
        has_param.* = true;
    }
    var digits: [3]u8 = undefined;
    digits[2] = '0' + @as(u8, @intCast(value % 10));
    digits[1] = '0' + @as(u8, @intCast(value / 10 % 10));
    digits[0] = '0' + @as(u8, @intCast(value / 100));
    var first: usize = 0;
    while (first < 2 and digits[first] == '0') : (first += 1) {}
    @memcpy(buf[at..][0 .. 3 - first], digits[first..]);
    return at + (3 - first);
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

// ── grid ───────────────────────────────────

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

    const cell: Cell = .{ .grapheme = "x", .style = .{ .fg = .{ .ansi = .red } } };
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

    const style: Style = .{ .fg = .{ .ansi = .red } };
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

// ── renderDiff goldens ──────────────────────────────

test "renderDiff: full row set emits the exact byte string" {
    var prev = try Buffer.init(std.testing.allocator, 6, 3);
    defer prev.deinit();
    var cur = try Buffer.init(std.testing.allocator, 6, 3);
    defer cur.deinit();
    _ = try cur.draw(Style{}, "hi", 0, 0);
    _ = try cur.draw(Style{}, "yo", 0, 1);

    var t: TestWriter = .{};
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

    var t: TestWriter = .{};
    t.init();
    try cur.renderDiff(&prev, &t.w);
    // Row 0 and the blank cells of row 1 are never re-emitted: the only
    // cell bytes are "b", reached by `\r\n` + erase + CUF 2.
    try std.testing.expectEqualStrings("\r\n\x1b[K\x1b[2Cb", t.w.buffered());
}

test "renderDiff: a style-only change repaints the cell in the new style" {
    const gpa = std.testing.allocator;
    var prev = try Buffer.init(gpa, 6, 3);
    defer prev.deinit();
    try prev.set(2, 1, .{ .grapheme = "a" });
    var cur = try Buffer.init(gpa, 6, 3);
    defer cur.deinit();
    try cur.set(2, 1, .{ .grapheme = "a", .style = .{ .fg = .{ .ansi = .red } } });

    var t: TestWriter = .{};
    t.init();
    try cur.renderDiff(&prev, &t.w);
    const out = t.w.buffered();
    // The damage is the style, so the one cell is rewritten and lands
    // red — the text and the rest of the row are never re-emitted.
    var model = try FrameModel.init(gpa, &cur, out);
    defer model.deinit(gpa);
    try model.replay();
    // The frame's only full reset is the one that hands the next frame
    // a default style.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, emit.reset));
}

test "renderDiff: idle frame (cur == prev) emits zero bytes" {
    var prev = try Buffer.init(std.testing.allocator, 6, 3);
    defer prev.deinit();
    var cur = try Buffer.init(std.testing.allocator, 6, 3);
    defer cur.deinit();
    _ = try prev.draw(Style{}, "hi", 0, 0);
    _ = try cur.draw(Style{}, "hi", 0, 0);

    var t: TestWriter = .{};
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

    var t: TestWriter = .{};
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

    var t: TestWriter = .{};
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

    var t: TestWriter = .{};
    t.init();
    try cur.renderDiff(&prev, &t.w);
    // Row 0 is identical and never re-emitted; row 2 is erased then
    // rewritten ("bbbbb" unchanged but blanked by the erase, "!" new).
    try std.testing.expectEqualStrings("\r\n\n\x1b[Kbbbbb!", t.w.buffered());
}

// ── renderAll goldens ──────────────────────────────

test "renderAll: full band plain" {
    var buf = try Buffer.init(std.testing.allocator, 4, 2);
    defer buf.deinit();
    _ = try buf.draw(Style{}, "ab", 0, 0);
    _ = try buf.draw(Style{}, "cd", 0, 1);

    var t: TestWriter = .{};
    t.init();
    try buf.renderAll(&t.w);
    try std.testing.expectEqualStrings("\r\x1b[Kab\r\n\x1b[Kcd", t.w.buffered());
}

test "renderAll: style deltas and wide glyphs" {
    const gpa = std.testing.allocator;
    var buf = try Buffer.init(gpa, 4, 2);
    defer buf.deinit();
    const red: Style = .{ .fg = .{ .ansi = .red } };
    _ = try buf.draw(red, "a", 0, 0);
    _ = try buf.draw(Style{}, "b", 1, 0);
    _ = try buf.draw(red, "👨‍🌾", 0, 1);
    _ = try buf.draw(Style{}, "c", 2, 1);

    var t: TestWriter = .{};
    t.init();
    try buf.renderAll(&t.w);
    // Red run, plain cell, wide glyph in red (drawn once, continuation
    // covered) and a plain cell: the replay checks each grapheme lands
    // with the buffer's style and on the buffer's cell.
    var model = try FrameModel.init(gpa, &buf, t.w.buffered());
    defer model.deinit(gpa);
    try model.replay();
}

test "renderAll: empty band emits the row erases only" {
    var buf = try Buffer.init(std.testing.allocator, 4, 2);
    defer buf.deinit();

    var t: TestWriter = .{};
    t.init();
    try buf.renderAll(&t.w);
    try std.testing.expectEqualStrings("\r\x1b[K\r\n\x1b[K", t.w.buffered());
}

// ── B4: row damage and the emitted-SGR memo ───────────────

test "renderDiff: one damaged row in a tall band emits that row alone" {
    const gpa = std.testing.allocator;
    var prev = try Buffer.init(gpa, 6, 8);
    defer prev.deinit();
    var cur = try Buffer.init(gpa, 6, 8);
    defer cur.deinit();
    for (0..8) |y| {
        _ = try prev.draw(Style{}, "aaaaaa", 0, @intCast(y));
        _ = try cur.draw(Style{}, "aaaaaa", 0, @intCast(y));
    }
    try cur.set(1, 5, .{ .grapheme = "B" });

    var t: TestWriter = .{};
    t.init();
    try cur.renderDiff(&prev, &t.w);
    // Damage is row-granular: five newlines down to row 5, the
    // column-1 erase, then that whole row — the seven untouched rows
    // emit nothing at all, and the row's own unchanged cells are
    // rewritten because the erase blanked them.
    try std.testing.expectEqualStrings("\r\n\n\n\n\n\x1b[KaBaaaa", t.w.buffered());
}

test "renderDiff: a row after a background-coloured row erases with the default background" {
    const gpa = std.testing.allocator;
    const shaded: Style = .{ .fg = .{ .ansi = .white }, .bg = .{ .ansi = .blue } };
    var prev = try Buffer.init(gpa, 4, 2);
    defer prev.deinit();
    try prev.set(0, 0, .{ .grapheme = "a", .style = shaded });
    try prev.set(0, 1, .{ .grapheme = "x" });
    var cur = try Buffer.init(gpa, 4, 2);
    defer cur.deinit();
    try cur.set(0, 0, .{ .grapheme = "b", .style = shaded });
    try cur.set(0, 1, .{ .grapheme = "y" });

    var t: TestWriter = .{};
    t.init();
    try cur.renderDiff(&prev, &t.w);
    const out = t.w.buffered();
    // Row 0 leaves a blue background active. EL fills with the active
    // background, so the replay asserts row 1's erase runs under the
    // default one — without it the three blank cells at the end of row
    // 1 paint blue.
    var model = try FrameModel.init(gpa, &cur, out);
    defer model.deinit(gpa);
    try model.replay();
    // One full reset in the frame, and it is the one that hands row 1's
    // erase the default background; the row-0 erase needs none.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, emit.reset));
}

test "renderDiff: a foreground-only row hands the next row an erase with no reset" {
    const gpa = std.testing.allocator;
    const red: Style = .{ .fg = .{ .ansi = .red } };
    var prev = try Buffer.init(gpa, 4, 2);
    defer prev.deinit();
    try prev.set(0, 0, .{ .grapheme = "a", .style = red });
    try prev.set(0, 1, .{ .grapheme = "x" });
    var cur = try Buffer.init(gpa, 4, 2);
    defer cur.deinit();
    try cur.set(0, 0, .{ .grapheme = "b", .style = red });
    try cur.set(0, 1, .{ .grapheme = "y" });

    var t: TestWriter = .{};
    t.init();
    try cur.renderDiff(&prev, &t.w);
    const out = t.w.buffered();
    var model = try FrameModel.init(gpa, &cur, out);
    defer model.deinit(gpa);
    try model.replay();
    // A foreground-only style paints no background, so its erase already
    // fills with the default one: the reset before EL would be four bytes
    // of nothing.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, emit.reset));
}

test "renderDiff: styles that print the same SGR never spend a reset" {
    const gpa = std.testing.allocator;
    const uri_a = "https://a.example";
    const uri_b = "https://b.example";
    var prev = try Buffer.init(gpa, 4, 1);
    defer prev.deinit();
    try prev.set(0, 0, .{
        .grapheme = "a",
        .style = .{ .fg = .{ .ansi = .red }, .hyperlink = uri_a },
    });
    try prev.set(1, 0, .{
        .grapheme = "b",
        .style = .{ .fg = .{ .ansi = .red }, .hyperlink = uri_a },
    });
    try prev.set(2, 0, .{ .grapheme = "c", .style = .{ .fg = .default, .bg = .default } });
    try prev.set(3, 0, .{ .grapheme = "d" });
    var cur = try Buffer.init(gpa, 4, 1);
    defer cur.deinit();
    // Every cell's Style differs from `prev`, so the row is damaged — and
    // none of the differences reach the terminal: the hyperlink is never
    // emitted (OSC 8 deferred, emit.zig:6) and `null` and `Color.default`
    // both print nothing.
    try cur.set(0, 0, .{
        .grapheme = "a",
        .style = .{ .fg = .{ .ansi = .red }, .hyperlink = uri_b },
    });
    try cur.set(1, 0, .{
        .grapheme = "b",
        .style = .{ .fg = .{ .ansi = .red }, .hyperlink = uri_b },
    });
    try cur.set(2, 0, .{ .grapheme = "c" });
    try cur.set(3, 0, .{ .grapheme = "d", .style = .{ .fg = .default, .bg = .default } });

    var t: TestWriter = .{};
    t.init();
    try cur.renderDiff(&prev, &t.w);
    const out = t.w.buffered();
    // The frame paints the red run and the plain tail, and the style
    // each cell lands with is the buffer's own.
    var model = try FrameModel.init(gpa, &cur, out);
    defer model.deinit(gpa);
    try model.replay();
    // None of the four style changes reached the terminal, so nothing
    // but the frame-boundary reset is a full `CSI 0m`.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, emit.reset));
}

test "renderAll: a repeated styled run costs a parameter, not a reset" {
    const gpa = std.testing.allocator;
    var buf = try Buffer.init(gpa, 16, 1);
    defer buf.deinit();
    const red: Style = .{ .fg = .{ .ansi = .red } };
    const bold_red: Style = .{ .fg = .{ .ansi = .red }, .attrs = .{ .bold = true } };
    for (0..8) |i| {
        const style = if (i % 2 == 0) red else bold_red;
        _ = try buf.draw(style, "aa", @intCast(i * 2), 0);
    }

    var t: TestWriter = .{};
    t.init();
    try buf.renderAll(&t.w);
    const out = t.w.buffered();
    // The terminal shows what the buffer holds: every run lands with
    // its own boldness over the shared colour.
    var model = try FrameModel.init(gpa, &buf, out);
    defer model.deinit(gpa);
    try model.replay();
    // The alternation is an attribute delta, not a reset: the shared
    // colour is never re-sent, and only the frame-boundary reset is a
    // full `CSI 0m`.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, emit.reset));
}

test "renderAll: bold and dim survive a transition that clears the other" {
    // 22 is the only off-parameter for either intensity: it takes bold
    // and dim down together, so a run that keeps one of them must get
    // it back — otherwise the terminal paints it with neither.
    const gpa = std.testing.allocator;
    const both: Style = .{ .fg = .{ .ansi = .red }, .attrs = .{ .bold = true, .dim = true } };
    const dim: Style = .{ .fg = .{ .ansi = .red }, .attrs = .{ .dim = true } };
    const bold: Style = .{ .fg = .{ .ansi = .red }, .attrs = .{ .bold = true } };
    const busy: Style = .{
        .fg = .{ .ansi = .red },
        .attrs = .{ .bold = true, .dim = true, .italic = true },
    };
    var buf = try Buffer.init(gpa, 20, 1);
    defer buf.deinit();
    _ = try buf.draw(both, "abcd", 0, 0);
    _ = try buf.draw(dim, "efgh", 4, 0);
    _ = try buf.draw(bold, "ijkl", 8, 0);
    _ = try buf.draw(busy, "mnop", 12, 0);
    _ = try buf.draw(.{}, "qrst", 16, 0);

    var t: TestWriter = .{};
    t.init();
    try buf.renderAll(&t.w);
    // Every run lands with the style the buffer holds: dim after the
    // first clear, bold after the second, both behind the italic.
    var model = try FrameModel.init(gpa, &buf, t.w.buffered());
    defer model.deinit(gpa);
    try model.replay();
}

test "renderDiff: a repainted row keeps the intensity its style asks for" {
    // The diff path runs the same encoder, on rows whose only damage
    // is the intensity: bold|dim -> dim, and plain -> bold.
    const gpa = std.testing.allocator;
    var prev = try Buffer.init(gpa, 4, 2);
    defer prev.deinit();
    _ = try prev.draw(.{ .attrs = .{ .bold = true, .dim = true } }, "ab", 0, 0);
    _ = try prev.draw(.{}, "cd", 0, 1);
    var cur = try Buffer.init(gpa, 4, 2);
    defer cur.deinit();
    _ = try cur.draw(.{ .attrs = .{ .dim = true } }, "ab", 0, 0);
    _ = try cur.draw(.{ .attrs = .{ .bold = true } }, "cd", 0, 1);

    var t: TestWriter = .{};
    t.init();
    try cur.renderDiff(&prev, &t.w);
    // Both rows are damaged and both are repainted: row 0 lands dim,
    // row 1 lands bold, neither lands bare.
    var model = try FrameModel.init(gpa, &cur, t.w.buffered());
    defer model.deinit(gpa);
    try model.replay();
}

test "renderAll: a dropped attribute clears only itself" {
    // Every attribute has its own off-parameter except the pair bold
    // and dim. A strikethrough-off that paints a full reset, or a
    // reverse-off sent as 29, takes the colour and the retained
    // attributes down with it and the run shows up bare.
    const gpa = std.testing.allocator;
    const red: Style = .{ .fg = .{ .ansi = .red } };
    const bold_red: Style = .{ .fg = .{ .ansi = .red }, .attrs = .{ .bold = true } };
    const struck_bold: Style = .{
        .fg = .{ .ansi = .red },
        .attrs = .{ .bold = true, .strikethrough = true },
    };
    const reverse_red: Style = .{ .fg = .{ .ansi = .red }, .attrs = .{ .reverse = true } };
    var buf = try Buffer.init(gpa, 10, 1);
    defer buf.deinit();
    _ = try buf.draw(struck_bold, "ab", 0, 0);
    _ = try buf.draw(bold_red, "cd", 2, 0);
    _ = try buf.draw(red, "ef", 4, 0);
    _ = try buf.draw(reverse_red, "gh", 6, 0);
    _ = try buf.draw(red, "ij", 8, 0);

    var t: TestWriter = .{};
    t.init();
    try buf.renderAll(&t.w);
    var model = try FrameModel.init(gpa, &buf, t.w.buffered());
    defer model.deinit(gpa);
    try model.replay();
}

test "renderAll: a style matrix lands every run, whichever transition wins" {
    // Row 0 walks the styles forward, row 1 walks them back, so every
    // ordered pair of styles is a transition the frame has to survive —
    // whether the encoder sends the field delta or falls back to a full
    // reset, the terminal must end up showing the buffer's style.
    const gpa = std.testing.allocator;
    const styles = [_]Style{
        .{},
        .{ .fg = .{ .ansi = .red } },
        .{ .fg = .{ .ansi = .bright_blue } },
        .{ .fg = .{ .ansi256 = 245 } },
        .{ .fg = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } } },
        .{ .bg = .{ .ansi256 = 21 }, .attrs = .{ .bold = true, .underline = true } },
        .{
            .fg = .{ .ansi = .white },
            .bg = .{ .ansi = .blue },
            .attrs = .{ .dim = true, .italic = true, .strikethrough = true },
        },
        .{ .attrs = .{ .blink = true, .reverse = true } },
    };
    var buf = try Buffer.init(gpa, 16, 2);
    defer buf.deinit();
    for (styles, 0..) |style, i| {
        _ = try buf.draw(style, "ab", @intCast(i * 2), 0);
        _ = try buf.draw(styles[styles.len - 1 - i], "ab", @intCast(i * 2), 1);
    }

    var t: TestWriter = .{};
    t.init();
    try buf.renderAll(&t.w);
    var model = try FrameModel.init(gpa, &buf, t.w.buffered());
    defer model.deinit(gpa);
    try model.replay();
}

test "renderAll: a frame with more transitions than memo slots lands every run" {
    // Seventeen distinct colour transitions against `sgr_cache_slots`
    // (16): the memo must overflow, and an overflowing frame may only
    // re-encode a transition — never paint a run with another run's
    // sequence.
    const gpa = std.testing.allocator;
    var buf = try Buffer.init(gpa, 17, 1);
    defer buf.deinit();
    for (0..17) |i| {
        try buf.set(@intCast(i), 0, .{
            .grapheme = "a",
            .style = .{ .fg = .{ .ansi256 = @intCast(i) } },
        });
    }

    var t: TestWriter = .{};
    t.init();
    try buf.renderAll(&t.w);
    var model = try FrameModel.init(gpa, &buf, t.w.buffered());
    defer model.deinit(gpa);
    try model.replay();
}

test "renderAll: the emitted frame shows the colours, attrs and blank tails the buffer holds" {
    const gpa = std.testing.allocator;
    var buf = try Buffer.init(gpa, 24, 3);
    defer buf.deinit();
    const red: Style = .{ .fg = .{ .ansi = .red } };
    const bold_blue: Style = .{ .fg = .{ .ansi = .blue }, .attrs = .{ .bold = true } };
    const shaded: Style = .{ .bg = .{ .ansi256 = 21 }, .attrs = .{ .dim = true } };
    const warm: Style = .{
        .fg = .{ .rgb = .{ .r = 200, .g = 100, .b = 50 } },
        .bg = .{ .ansi = .white },
    };
    _ = try buf.draw(red, "ab", 0, 0);
    _ = try buf.draw(bold_blue, "cd", 2, 0);
    _ = try buf.draw(red, "ef", 4, 0);
    // A styled blank must still emit: its background is the point.
    try buf.set(6, 0, .{ .grapheme = " ", .style = shaded });
    _ = try buf.draw(bold_blue, "👨‍🌾", 8, 0);
    _ = try buf.draw(warm, "gh", 10, 0);
    _ = try buf.draw(Style{}, "ij", 0, 1);
    _ = try buf.draw(Style{}, "kl", 5, 1);
    _ = try buf.draw(red, "mn", 0, 2);

    var t: TestWriter = .{};
    t.init();
    try buf.renderAll(&t.w);
    var model = try FrameModel.init(gpa, &buf, t.w.buffered());
    defer model.deinit(gpa);
    try model.replay();

    // The same band as a diff frame: one cell changes, row 0 repaints,
    // rows 1 and 2 stay on screen untouched.
    var prev = try Buffer.init(gpa, 24, 3);
    defer prev.deinit();
    _ = try prev.draw(red, "ab", 0, 0);
    _ = try prev.draw(bold_blue, "cd", 2, 0);
    _ = try prev.draw(red, "ef", 4, 0);
    try prev.set(6, 0, .{ .grapheme = " ", .style = shaded });
    _ = try prev.draw(bold_blue, "👨‍🌾", 8, 0);
    _ = try prev.draw(warm, "gh", 10, 0);
    _ = try prev.draw(Style{}, "ij", 0, 1);
    _ = try prev.draw(Style{}, "kl", 5, 1);
    _ = try prev.draw(red, "mn", 0, 2);
    try buf.set(10, 0, .{ .grapheme = "G", .style = warm });

    var t2: TestWriter = .{};
    t2.init();
    try buf.renderDiff(&prev, &t2.w);
    var model2 = try FrameModel.init(gpa, &buf, t2.w.buffered());
    defer model2.deinit(gpa);
    try model2.replay();
}

/// A minimal terminal: it replays an emitted frame and checks the
/// result against the buffer the frame came from. It asserts on what a
/// terminal would show — the style every written grapheme lands with,
/// wide-glyph coverage, the background each erase painted its tail with
/// — instead of on the escape bytes the frame took.
const FrameModel = struct {
    buf: *const Buffer,
    bytes: []const u8,
    index: usize = 0,
    row: usize = 0,
    col: usize = 0,
    style: Style = .{},
    /// Column each row's erase started at; null for a row the frame
    /// never repainted.
    erase_col: []?usize,
    /// Whether a cell took a grapheme (a wide lead or its continuation).
    written: []bool,

    fn init(
        gpa: std.mem.Allocator,
        buf: *const Buffer,
        bytes: []const u8,
    ) !FrameModel {
        const width: usize = buf.width;
        const height: usize = buf.height;
        const erase_col = try gpa.alloc(?usize, height);
        errdefer gpa.free(erase_col);
        const written = try gpa.alloc(bool, width * height);
        @memset(erase_col, null);
        @memset(written, false);
        return .{
            .buf = buf,
            .bytes = bytes,
            .erase_col = erase_col,
            .written = written,
        };
    }

    fn deinit(self: *FrameModel, gpa: std.mem.Allocator) void {
        gpa.free(self.erase_col);
        gpa.free(self.written);
    }

    fn replay(self: *FrameModel) !void {
        while (self.index < self.bytes.len) {
            switch (self.bytes[self.index]) {
                '\r' => {
                    self.col = 0;
                    self.index += 1;
                },
                '\n' => {
                    self.row += 1;
                    self.index += 1;
                },
                0x1b => try self.esc(),
                else => try self.text(),
            }
        }
        // The frame hands the next one a default SGR.
        try std.testing.expect(Emitted.of(self.style).isDefault());
        try self.expectTail();
    }

    /// One CSI sequence: `K` (erase to end of line), `C` (cursor
    /// forward) or `m` (select graphic rendition).
    fn esc(self: *FrameModel) !void {
        try std.testing.expect(self.index + 2 <= self.bytes.len);
        try std.testing.expectEqual(@as(u8, '['), self.bytes[self.index + 1]);
        var at = self.index + 2;
        // Wide enough for the longest sequence the encoder can build:
        // eight off-parameters plus fifteen on-parameters.
        var params: [24]u16 = undefined;
        var count: usize = 0;
        while (at < self.bytes.len and !isCsiFinal(self.bytes[at])) {
            if (std.ascii.isDigit(self.bytes[at])) {
                var value: u16 = 0;
                while (at < self.bytes.len and std.ascii.isDigit(self.bytes[at])) {
                    value = value * 10 + @as(u16, self.bytes[at] - '0');
                    at += 1;
                }
                try std.testing.expect(count < params.len);
                params[count] = value;
                count += 1;
            } else {
                at += 1; // the ';' between parameters
            }
        }
        try std.testing.expect(at < self.bytes.len);
        const final = self.bytes[at];
        at += 1;
        switch (final) {
            'K' => try self.eraseLine(),
            'C' => self.col += @as(usize, params[0]),
            'm' => self.sgr(params[0..count]),
            else => unreachable, // the renderers emit no other CSI
        }
        self.index = at;
    }

    fn eraseLine(self: *FrameModel) !void {
        try std.testing.expect(self.row < @as(usize, self.buf.height));
        // EL fills with the active background: a frame must hand it the
        // default one or the row's blank tail inherits a colour.
        try std.testing.expect(Emitted.of(self.style).bg() == 0);
        self.erase_col[self.row] = self.col;
    }

    /// One printable grapheme: it must land on the cell the buffer
    /// holds, carrying the style the terminal had active.
    fn text(self: *FrameModel) !void {
        const rest = self.bytes[self.index..];
        const len = Width.firstGraphemeLen(rest);
        try std.testing.expect(len > 0);
        const glyph = rest[0..len];
        try std.testing.expect(self.row < @as(usize, self.buf.height));
        try std.testing.expect(self.col < @as(usize, self.buf.width));
        const cell = self.buf.get(@intCast(self.col), @intCast(self.row));
        try std.testing.expectEqualStrings(glyph, cell.grapheme);
        try std.testing.expect(Emitted.of(cell.style).eql(Emitted.of(self.style)));

        const width: usize = @intCast(@max(1, Width.graphemeWidth(glyph)));
        self.mark(self.col);
        if (width == 2) {
            try std.testing.expect(self.col + 1 < @as(usize, self.buf.width));
            try std.testing.expect(self.buf.get(@intCast(self.col + 1), @intCast(self.row)).wide);
            self.mark(self.col + 1);
        }
        self.col += width;
        self.index += len;
    }

    fn mark(self: *FrameModel, col: usize) void {
        self.written[self.row * @as(usize, self.buf.width) + col] = true;
    }

    /// Every cell from a repainted row's erase column to its end either
    /// took a grapheme or is one the renderer may skip: a default-styled
    /// blank or a wide continuation.
    fn expectTail(self: *FrameModel) !void {
        const width: usize = self.buf.width;
        for (0..@as(usize, self.buf.height)) |y| {
            const start = self.erase_col[y] orelse continue;
            for (start..width) |x| {
                if (self.written[y * width + x]) continue;
                const cell = self.buf.get(@intCast(x), @intCast(y));
                try std.testing.expect(cell.wide or cell.grapheme.len == 0 or cell.eql(Cell{}));
            }
        }
    }

    /// Fold one SGR sequence into the active style. Covers every
    /// parameter the renderer emits: the attribute on/off pairs, the
    /// `39`/`49` defaults and the 38/48 colour forms.
    fn sgr(self: *FrameModel, params: []const u16) void {
        var at: usize = 0;
        while (at < params.len) {
            const p = params[at];
            if (p == 0) {
                self.style = .{};
            } else if (p == 1) {
                self.style.attrs.bold = true;
            } else if (p == 2) {
                self.style.attrs.dim = true;
            } else if (p == 3) {
                self.style.attrs.italic = true;
            } else if (p == 4) {
                self.style.attrs.underline = true;
            } else if (p == 5) {
                self.style.attrs.blink = true;
            } else if (p == 7) {
                self.style.attrs.reverse = true;
            } else if (p == 9) {
                self.style.attrs.strikethrough = true;
            } else if (p == 22) {
                self.style.attrs.bold = false;
                self.style.attrs.dim = false;
            } else if (p == 23) {
                self.style.attrs.italic = false;
            } else if (p == 24) {
                self.style.attrs.underline = false;
            } else if (p == 25) {
                self.style.attrs.blink = false;
            } else if (p == 27) {
                self.style.attrs.reverse = false;
            } else if (p == 29) {
                self.style.attrs.strikethrough = false;
            } else if (p == 39) {
                self.style.fg = null;
            } else if (p == 49) {
                self.style.bg = null;
            } else if (p == 38 or p == 48) {
                // `38;5;n` (256-colour) or `38;2;r;g;b` (truecolor).
                const mode = params[at + 1];
                const colour: Color = if (mode == 5) blk: {
                    break :blk .{ .ansi256 = @intCast(params[at + 2]) };
                } else if (mode == 2) blk: {
                    break :blk .{ .rgb = .{
                        .r = @intCast(params[at + 2]),
                        .g = @intCast(params[at + 3]),
                        .b = @intCast(params[at + 4]),
                    } };
                } else unreachable; // the renderers emit no other form
                at += if (mode == 5) @as(usize, 2) else 4;
                if (p == 38) {
                    self.style.fg = colour;
                } else {
                    self.style.bg = colour;
                }
            } else if (p >= 30 and p <= 37) {
                self.style.fg = .{ .ansi = @enumFromInt(p - 30) };
            } else if (p >= 40 and p <= 47) {
                self.style.bg = .{ .ansi = @enumFromInt(p - 40) };
            } else if (p >= 90 and p <= 97) {
                self.style.fg = .{ .ansi = @enumFromInt(p - 90 + 8) };
            } else if (p >= 100 and p <= 107) {
                self.style.bg = .{ .ansi = @enumFromInt(p - 100 + 8) };
            } else {
                unreachable; // the renderers emit no other parameter
            }
            at += 1;
        }
    }
};

/// A CSI final byte is 0x40..0x7E; no SGR parameter or digit lands in
/// that range, so the parameter scan stops on the first one.
fn isCsiFinal(byte: u8) bool {
    return byte >= 0x40 and byte <= 0x7e;
}
