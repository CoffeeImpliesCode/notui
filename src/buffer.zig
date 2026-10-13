//! Buffer: a flat cell grid with wide-glyph handling, grapheme-aware
//! drawing, and the double-buffer diff renderers (renderDiff/renderAll).
//!
//! Adapted from zigzag `terminal/screen.zig` (grid :70-85, resize
//! :88-117, setCell wide handling :115-154, writeString :157-188, diff
//! render :190-306). The structural adaptation from the copy source:
//! `Cell.grapheme` is a borrowed `[]const u8` interface, not zigzag's
//! `char: u21`. The grid stores one-byte ASCII by value. Other graphemes
//! borrow the caller's text. Width comes only from `width.zig`, the zg
//! seam. Style tracking follows the libvaxis DAM pattern: SGR changes
//! only when the emitted style changes, and wide continuations emit no text.
//!
//! `Cell` is the interface value, not the storage. The grid keeps a
//! 16-byte hot slot per cell (grapheme head, flags, packed style).
//! Borrowed slices live in cold side arrays, which hot passes read only
//! when a slot's flags require them.
//!
//! ROADMAP B4: damage is row-granular and decided in a single pass (each
//! row is compared exactly once, an unchanged row costs no bytes at all),
//! and the SGR that goes with it is memoized in a fixed-size
//! allocation-free cache of encoded transitions keyed by the style the
//! terminal actually receives.
//!
//! Reach through `@import("notui").buffer`: `init`, `draw` or `set`, then render into
//! the caller's writer. One `deinit` releases the grid, not the strings its cells borrow.
//! Terminal modes, transport, and committed text snapshots belong to `Region` or the caller.

const std = @import("std");
const builtin = @import("builtin");
const Cell = @import("cell.zig").Cell;
const Color = @import("color.zig").Color;
const AnsiColor = @import("color.zig").AnsiColor;
const Style = @import("style.zig").Style;
const emit = @import("emit.zig");
const Width = @import("width.zig");

/// The default emitted style: no colour, no attribute. Every frame
/// starts and ends here, so the terminal's active SGR is default at a
/// frame boundary and every row's erase paints the default background.
const default_style: Emitted = .{};

/// A cell grid plus the delta renderer for double-buffered output.
///
/// Storage is split by how each pass reads it. `slots` holds one 16-byte
/// hot record per cell, row-major (`slots[y * width + x]`): the
/// grapheme's first bytes, its length and flags, and the exact packed
/// style. Drawing, the damage compare, snapshot copies and row emission
/// read `slots` alone, and two bit-equal slots are equal cells unless
/// the slot is `deep` (a grapheme longer than the slot holds, or a
/// hyperlink). `text` and `links` are cold, one entry per cell, valid
/// only where the slot's `borrowed` / `link` flag is set; nothing reads
/// them for printable one-byte ASCII.
///
/// Construct with `init`; zero dimensions are valid empty grids. The stored allocator
/// stays live through one `deinit`. Copies alias the allocation and are not new owners.
/// Cell graphemes and style hyperlinks are borrowed and must stay live and unchanged while
/// retained or compared, except printable one-byte ASCII graphemes, which are stored by
/// value. A shallow previous grid does not preserve mutable text. Use serially without
/// writer reentry. Read and write cells through `get`, `set` and `draw`; the storage
/// fields are this module's and `Region`'s. Cell values expire on resize.
pub const Buffer = struct {
    allocator: std.mem.Allocator,
    slots: []Slot,
    text: [][]const u8,
    links: [][]const u8,
    width: u16,
    height: u16,
    /// Some slot stored since the last `clear` has cold data. Copies skip
    /// the cold arrays while this is false.
    any_cold: bool = false,
    /// Some slot stored since the last `clear` is `deep`. The damage
    /// compare trusts a bit-equal row while this is false.
    any_deep: bool = false,

    /// One cell's hot record. `extern` fixes a padding-free layout, so two
    /// slots compare bit for bit.
    pub const Slot = extern struct {
        /// The grapheme's first `@min(len, 4)` bytes, byte 0 lowest,
        /// zero-filled.
        glyph: u32,
        meta: Meta,
        /// The cell's style without its hyperlink, packed exactly
        /// (`packStyle`).
        style: u64,

        pub const Meta = packed struct(u32) {
            /// Grapheme byte length, saturating at 0xffff.
            len: u16,
            /// The continuation half of a wide grapheme.
            wide: bool = false,
            /// The grapheme is `text[i]`; otherwise it is empty or the
            /// one ASCII byte in `glyph`.
            borrowed: bool = false,
            /// The style carries the hyperlink `links[i]`.
            link: bool = false,
            /// Bit equality is not enough: the grapheme is longer than
            /// `glyph`, or there is a hyperlink to compare.
            deep: bool = false,
            _pad: u12 = 0,
        };

        /// The default cell, `Cell{}`: one space, default style.
        pub const blank: Slot = .{ .glyph = ' ', .meta = .{ .len = 1 }, .style = 0 };

        fn bits(self: Slot) u128 {
            return @bitCast(self);
        }

        pub fn isBlank(self: Slot) bool {
            return self.bits() == blank.bits();
        }

        /// What a renderer prints for this slot: nothing for a wide
        /// continuation, an empty grapheme or a default blank.
        pub fn paints(self: Slot) bool {
            return !self.meta.wide and self.meta.len != 0 and !self.isBlank();
        }

        /// Meta bits of a slot with cold data.
        pub const cold: u32 = @bitCast(Meta{ .len = 0, .borrowed = true, .link = true });
        /// Meta bit of a slot whose grapheme is in `text`.
        pub const borrowed_bit: u32 = @bitCast(Meta{ .len = 0, .borrowed = true });
        /// Meta bit of a slot that bit equality does not settle.
        pub const deep_bit: u32 = @bitCast(Meta{ .len = 0, .deep = true });
        /// Meta bit of a wide continuation.
        pub const wide_bit: u32 = @bitCast(Meta{ .len = 0, .wide = true });

        /// The indices of `slots` whose meta has a bit of `mask`, found
        /// eight slots per step: the eight meta words are gathered from
        /// one 128-byte load with a shuffle and tested at once, so a run
        /// of slots without the flags costs one compare per eight.
        pub const Flagged = struct {
            slots: []const Slot,
            mask: u32,
            chunk: usize = 0,
            hits: u8 = 0,
            at: usize = 0,

            pub fn next(self: *Flagged) ?usize {
                while (self.hits == 0) {
                    if (self.chunk >= self.slots.len) return null;
                    self.at = self.chunk;
                    const rest = self.slots[self.chunk..];
                    if (rest.len >= 8) {
                        self.hits = metaHits(rest[0..8], self.mask);
                        self.chunk += 8;
                    } else {
                        for (rest, 0..) |s, k| {
                            if (@as(u32, @bitCast(s.meta)) & self.mask != 0) {
                                self.hits |= @as(u8, 1) << @intCast(k);
                            }
                        }
                        self.chunk = self.slots.len;
                    }
                }
                const k = @ctz(self.hits);
                self.hits &= self.hits - 1;
                return self.at + k;
            }

            /// Bit k set when slot k's meta has a bit of `mask`.
            fn metaHits(chunk: *const [8]Slot, mask: u32) u8 {
                const words: @Vector(32, u32) = @as(*const [32]u32, @ptrCast(chunk)).*;
                const metas = @shuffle(
                    u32,
                    words,
                    undefined,
                    [8]i32{ 1, 5, 9, 13, 17, 21, 25, 29 },
                );
                const hit = metas & @as(@Vector(8, u32), @splat(mask)) !=
                    @as(@Vector(8, u32), @splat(0));
                return Slot.maskBits(hit);
            }
        };

        /// Normalize vector lanes to low-to-high bits on either byte order.
        fn maskBits(flags: @Vector(8, bool)) u8 {
            const raw_mask: u8 = @bitCast(flags);
            return if (builtin.target.cpu.arch.endian() == .big) @bitReverse(raw_mask) else raw_mask;
        }

        /// For eight slots, which paint (`paints()`) and which of those
        /// hold borrowed text, as bit masks, from one 128-byte load: each
        /// field is gathered across the slots with a shuffle and tested
        /// in one vector compare.
        pub fn paintHits(chunk: *const [8]Slot) struct { paints: u8, borrowed: u8 } {
            const V = @Vector(8, u32);
            const words: @Vector(32, u32) = @as(*const [32]u32, @ptrCast(chunk)).*;
            const glyph = @shuffle(u32, words, undefined, [8]i32{ 0, 4, 8, 12, 16, 20, 24, 28 });
            const meta = @shuffle(u32, words, undefined, [8]i32{ 1, 5, 9, 13, 17, 21, 25, 29 });
            const lo = @shuffle(u32, words, undefined, [8]i32{ 2, 6, 10, 14, 18, 22, 26, 30 });
            const hi = @shuffle(u32, words, undefined, [8]i32{ 3, 7, 11, 15, 19, 23, 27, 31 });
            const blank_meta: u32 = @bitCast(blank.meta);
            const zero: V = @splat(0);
            const diff = (glyph ^ @as(V, @splat(blank.glyph))) |
                (meta ^ @as(V, @splat(blank_meta))) | lo | hi;
            const blank_m = maskBits(diff == zero);
            const wide_m = maskBits(meta & @as(V, @splat(wide_bit)) != zero);
            const empty_m = maskBits(meta & @as(V, @splat(0xffff)) == zero);
            const borrowed_m = maskBits(meta & @as(V, @splat(borrowed_bit)) != zero);
            const paints_m = ~(blank_m | wide_m | empty_m);
            return .{ .paints = paints_m, .borrowed = borrowed_m & paints_m };
        }
    };

    /// Bytes one cell takes across the three arrays.
    const cell_bytes = @sizeOf(Slot) + 2 * @sizeOf([]const u8);

    /// Allocate a `width` x `height` grid of empty cells, in one allocation:
    /// the hot slots first, then the two cold arrays.
    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Buffer {
        const n = @as(usize, width) * @as(usize, height);
        const block = try allocator.alignedAlloc(u8, .of(Slot), n * cell_bytes);
        const slots = @as([*]Slot, @ptrCast(block.ptr))[0..n];
        const cold: [*][]const u8 = @ptrCast(@alignCast(block.ptr + n * @sizeOf(Slot)));
        @memset(slots, Slot.blank);
        return .{
            .allocator = allocator,
            .slots = slots,
            .text = cold[0..n],
            .links = cold[n..][0..n],
            .width = width,
            .height = height,
        };
    }

    /// Release the grid through its stored allocator, not its borrowed strings.
    /// Invalidates all grid views; repeated disposal or disposing a copy is invalid.
    pub fn deinit(self: *Buffer) void {
        const block: [*]align(@alignOf(Slot)) u8 = @ptrCast(self.slots.ptr);
        self.allocator.free(block[0 .. self.slots.len * cell_bytes]);
        self.* = undefined;
    }

    /// Reallocate to `new_width` x `new_height`, copying the overlapping
    /// region row by row (zigzag screen.zig :88-117); the new area is
    /// empty cells.
    /// `error.OutOfMemory` preserves the old grid. Success invalidates all cell values,
    /// but copied cell payloads still borrow the same caller strings.
    pub fn resize(self: *Buffer, new_width: u16, new_height: u16) !void {
        var next = try Buffer.init(self.allocator, new_width, new_height);
        next.copyFrom(self);
        self.deinit();
        self.* = next;
    }

    /// Copy the rectangle `self` and `src` share, cell for cell, borrows
    /// included; cells outside it keep their content.
    pub fn copyFrom(self: *Buffer, src: *const Buffer) void {
        const h: usize = @min(self.height, src.height);
        const w: usize = @min(self.width, src.width);
        if (h == 0 or w == 0) return;
        const whole = self.width == src.width and self.height == src.height;
        if (self.width == src.width) {
            self.copyRun(src, 0, 0, h * w);
        } else for (0..h) |y| {
            self.copyRun(src, y * self.width, y * src.width, w);
        }
        // A whole copy holds exactly `src`'s cells; a partial one keeps
        // some of its own, so its flags can only grow.
        self.any_cold = src.any_cold or (!whole and self.any_cold);
        self.any_deep = src.any_deep or (!whole and self.any_deep);
    }

    fn copyRun(self: *Buffer, src: *const Buffer, at: usize, from: usize, n: usize) void {
        @memcpy(self.slots[at..][0..n], src.slots[from..][0..n]);
        if (!src.any_cold) return;
        var cold: Slot.Flagged = .{ .slots = src.slots[from..][0..n], .mask = Slot.cold };
        while (cold.next()) |i| {
            const m = src.slots[from + i].meta;
            if (m.borrowed) self.text[at + i] = src.text[from + i];
            if (m.link) self.links[at + i] = src.links[from + i];
        }
    }

    /// Reset every cell to the default empty cell.
    pub fn clear(self: *Buffer) void {
        @memset(self.slots, Slot.blank);
        self.any_cold = false;
        self.any_deep = false;
    }

    /// Bounds-checked read; returns the empty cell out of bounds.
    /// A borrowed grapheme or hyperlink is the caller's slice; a one-byte
    /// ASCII grapheme is a static one.
    pub fn get(self: *const Buffer, x: u16, y: u16) Cell {
        if (x >= self.width or y >= self.height) return .{};
        return self.cellAt(@as(usize, y) * @as(usize, self.width) + x);
    }

    fn cellAt(self: *const Buffer, i: usize) Cell {
        const s = self.slots[i];
        const grapheme: []const u8 = if (s.meta.borrowed)
            self.text[i]
        else if (s.meta.len == 0)
            ""
        else
            Cell.asciiGrapheme(@truncate(s.glyph));
        return .{ .grapheme = grapheme, .style = self.styleAt(i), .wide = s.meta.wide };
    }

    /// The full style of cell `i` (a flat index), hyperlink included.
    pub fn styleAt(self: *const Buffer, i: usize) Style {
        const s = self.slots[i];
        var style = unpackStyle(s.style);
        if (s.meta.link) style.hyperlink = self.links[i];
        return style;
    }

    /// Write cell `i` from its parts. A one-byte ASCII grapheme is kept by
    /// value; anything else is borrowed into `text`.
    fn store(
        self: *Buffer,
        i: usize,
        grapheme: []const u8,
        style: u64,
        link: ?[]const u8,
        wide: bool,
    ) void {
        var glyph: u32 = 0;
        for (grapheme[0..@min(grapheme.len, 4)], 0..) |b, k| {
            glyph |= @as(u32, b) << @intCast(8 * k);
        }
        const borrowed = grapheme.len > 1 or (grapheme.len == 1 and grapheme[0] >= 0x80);
        const deep = grapheme.len > 4 or link != null;
        if (borrowed) self.text[i] = grapheme;
        if (link) |l| self.links[i] = l;
        self.any_cold = self.any_cold or borrowed or link != null;
        self.any_deep = self.any_deep or deep;
        self.slots[i] = .{
            .glyph = glyph,
            .meta = .{
                .len = @intCast(@min(grapheme.len, 0xffff)),
                .wide = wide,
                .borrowed = borrowed,
                .link = link != null,
                .deep = deep,
            },
            .style = style,
        };
    }

    /// Whether deep slots `i` of `self` and `j` of `other`, already bit
    /// equal, also hold equal cold content.
    fn deepEqual(self: *const Buffer, i: usize, other: *const Buffer, j: usize) bool {
        const m = self.slots[i].meta;
        if (m.len > 4 and !std.mem.eql(u8, self.text[i], other.text[j])) return false;
        if (m.link and !std.mem.eql(u8, self.links[i], other.links[j])) return false;
        return true;
    }

    /// Set one cell with wide-glyph handling (zigzag setCell :115-154):
    /// - overwriting a wide continuation nulls its left half;
    /// - overwriting a wide lead nulls its continuation;
    /// - a width-2 grapheme writes a `wide` continuation cell carrying
    ///   the same style (empty grapheme, `wide = true`).
    ///
    /// Out of bounds is a no-op; never errors (plan §0: graceful
    /// truncation, no throw paths).
    /// In codepoint mode a supplied Unicode grapheme is split into terminal
    /// cell clusters, truncated at the right edge as in `draw`.
    /// Retains `cell`'s non-ASCII grapheme and style hyperlink without copying; the type
    /// states their lifetime.
    pub fn set(self: *Buffer, x: u16, y: u16, cell: Cell) error{}!void {
        if (x >= self.width or y >= self.height) return;
        if (!cell.wide and Width.getMode() == .codepoint and
            Width.firstCellLen(cell.grapheme) < cell.grapheme.len)
        {
            _ = try self.draw(cell.style, cell.grapheme, x, y);
            return;
        }
        const cw: u16 = if (!cell.wide and Width.graphemeWidth(cell.grapheme) >= 2) 2 else 1;
        self.place(x, y, cell.grapheme, packStyle(cell.style), cell.style.hyperlink, cell.wide, cw);
    }

    /// Store one cell at (x, y), in bounds, already measured as `cw` columns
    /// (1 or 2) and segmented as one cell cluster. Shared by `set` and
    /// `draw`, which knows both and must not pay for them twice.
    fn place(
        self: *Buffer,
        x: u16,
        y: u16,
        grapheme: []const u8,
        style: u64,
        link: ?[]const u8,
        wide: bool,
        cw: u16,
    ) void {
        const idx = @as(usize, y) * @as(usize, self.width) + x;

        // Overwriting a wide continuation cell: its lead is at x - 1.
        // A continuation at column 0 has no lead (a width-2 glyph can
        // never start at the last column), so the subtraction is
        // defensive-only.
        if (self.slots[idx].meta.wide and idx > 0) {
            self.slots[idx - 1] = Slot.blank;
        }
        // Overwriting the left half of a wide char: null the continuation.
        // A wide continuation is always placed at lead + 1, so a `wide`
        // cell at idx + 1 can only belong to idx.
        if (!self.slots[idx].meta.wide and x + 1 < self.width and
            self.slots[idx + 1].meta.wide)
        {
            self.slots[idx + 1] = Slot.blank;
        }

        self.store(idx, grapheme, style, link, wide);

        // A wide grapheme occupies the next column too. The continuation
        // never emits text (renderers skip it) and carries the style so a
        // styled wide glyph paints both columns.
        if (cw >= 2 and x + 1 < self.width) {
            self.store(idx + 1, "", style, link, true);
        }
    }

    /// Draw `text` with `style` at (x, y), grapheme-aware.
    ///
    /// Iterates terminal cell clusters through the selected width policy
    /// (`Width.firstCellLen` + `Width.graphemeWidth`; no zg import).
    /// Zero-width clusters (combining marks) advance no column; a wide
    /// glyph that would cross the right edge drops, and with it the rest
    /// of the line (graceful truncation — never an error). Returns the
    /// number of columns consumed.
    /// Retains slices of `text` and any style hyperlink until cells are replaced or released.
    /// Printable one-byte ASCII graphemes are stored by value instead, so they borrow
    /// nothing and `get` returns them as static slices.
    /// The error set is empty for the common component drawing interface.
    pub fn draw(self: *Buffer, style: Style, text: []const u8, x: u16, y: u16) !u16 {
        if (y >= self.height or text.len == 0) return 0;

        const packed_style = packStyle(style);
        var col: u16 = x;
        var off: usize = 0;
        outer: while (off < text.len) {
            // Printable ASCII is one byte and one column in every mode, so
            // a run of it is stored in one pass; other text goes through
            // one segmenter walk until the next such run.
            const run = Width.asciiSingleRun(text[off..]);
            if (run > 0) {
                if (col >= self.width) break; // over-wide: drop the rest
                const n: u16 = @intCast(@min(run, self.width - col));
                self.fillAscii(col, y, packed_style, style.hyperlink, text[off..][0..n]);
                col += n;
                off += n;
                if (n < run) break;
                continue;
            }
            // Common scripts (box drawing, CJK, Latin letters, ...): one
            // codepoint per cluster, decided without the segmenter, for as
            // long as the text stays in them.
            if (Width.simpleCluster(text[off..])) |first| {
                var c = first;
                while (true) {
                    const cwu: u16 = if (c.width >= 2) 2 else 1;
                    if (@as(u32, col) + cwu > self.width) break :outer; // over-wide
                    const grapheme = text[off..][0..c.len];
                    self.place(col, y, grapheme, packed_style, style.hyperlink, false, cwu);
                    col += cwu;
                    off += c.len;
                    c = Width.simpleCluster(text[off..]) orelse break;
                }
                continue;
            }
            const start = off;
            var cells = Width.CellIterator.init(text[start..]);
            while (cells.next()) |c| {
                const gc = text[start + c.offset ..][0..c.len];
                off = start + c.offset + c.len;
                // A zero-width cluster advances no column.
                if (c.width > 0) {
                    const cwu: u16 = if (c.width >= 2) 2 else 1;
                    // Over-wide: drop the rest.
                    if (@as(u32, col) + cwu > self.width) break :outer;
                    self.place(col, y, gc, packed_style, style.hyperlink, false, cwu);
                    col += cwu;
                }
                if (Width.asciiSingle(text[off..])) continue :outer;
            }
            break; // the walk reached the end, or input it cannot advance over
        }
        return col - x;
    }

    /// Store the one-cell ASCII graphemes `bytes` from (x, y) on, all in
    /// bounds: what `place` does cell by cell, decided once per run. Inside
    /// the run every overwritten wide pair is overwritten whole, so only
    /// the two ends can split one: a continuation at the start loses its
    /// lead, and a continuation just past the end loses its own cell.
    fn fillAscii(
        self: *Buffer,
        x: u16,
        y: u16,
        style: u64,
        link: ?[]const u8,
        bytes: []const u8,
    ) void {
        const start = @as(usize, y) * @as(usize, self.width) + x;
        const end = start + bytes.len;
        if (self.slots[start].meta.wide and start > 0) self.slots[start - 1] = Slot.blank;
        if (x + bytes.len < self.width and self.slots[end].meta.wide) {
            self.slots[end] = Slot.blank;
        }
        const meta: Slot.Meta = .{ .len = 1, .link = link != null, .deep = link != null };
        for (self.slots[start..end], bytes) |*slot, b| {
            slot.* = .{ .glyph = b, .meta = meta, .style = style };
        }
        if (link) |l| {
            @memset(self.links[start..end], l);
            self.any_cold = true;
            self.any_deep = true;
        }
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
    /// Does not retain the writer or modify either grid. Writer failure may emit a prefix;
    /// discard staged output or restore the terminal before retrying.
    pub fn renderDiff(self: *const Buffer, prev: *const Buffer, w: anytype) !void {
        var styles: SgrCache = .empty();
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
    /// Does not retain the writer or modify the grid. Writer failure may emit a prefix;
    /// discard staged output or restore the terminal before retrying.
    pub fn renderAll(self: *const Buffer, w: anytype) !void {
        var styles: SgrCache = .empty();
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

    /// Flat slice of row `y`'s slots; the caller must have checked
    /// `y < height`.
    fn rowSlots(self: *const Buffer, y: usize) []const Slot {
        return self.slots[y * @as(usize, self.width) ..][0..self.width];
    }

    /// Whether row `y` differs from `prev`'s row `y`: the whole
    /// row-granular damage test. A row past `prev`'s height — or any row
    /// once the band grew wider — is damage, because the new columns have
    /// never been painted.
    ///
    /// The compare is by content. A slot holds every byte of a grapheme
    /// up to four bytes long and the whole style but its hyperlink, and it
    /// has no padding, so unequal slot bits are unequal cells and equal
    /// bits are equal cells unless the slot is `deep`; only those read
    /// the cold text and hyperlink. Longer graphemes and hyperlinks are
    /// compared over the bytes they point at right now, which is right
    /// only while `prev` holds the previous frame's CONTENT: `Region`
    /// owns `prev`'s text for exactly that reason, and a caller whose
    /// `prev` borrows text it rewrites in place hides that change.
    pub fn rowChanged(self: *const Buffer, prev: *const Buffer, y: usize) bool {
        if (y >= prev.height or self.width > prev.width) return true;
        const cur = self.rowSlots(y);
        const old = prev.rowSlots(y)[0..cur.len];
        if (!std.mem.eql(u8, std.mem.sliceAsBytes(cur), std.mem.sliceAsBytes(old))) return true;
        // Bit-equal slots are equal cells unless deep, and a deep slot is
        // bit-equal only to another deep slot.
        if (!self.any_deep) return false;
        const base = y * @as(usize, self.width);
        const prev_base = y * @as(usize, prev.width);
        var deep: Slot.Flagged = .{ .slots = cur, .mask = Slot.deep_bit };
        while (deep.next()) |x| {
            if (!self.deepEqual(base + x, prev, prev_base + x)) return true;
        }
        return false;
    }

    /// Emit one row (just erased at column 1) to `w`. Wide continuations
    /// and default-styled blanks never emit text; blank-cell skips
    /// advance the cursor with CUF, and a styled blank does emit so its
    /// background paints. SGR is written only when the emitted style
    /// changes from `tracked`, through the per-frame memo. Consecutive
    /// one-byte cells in one style go out in one write.
    fn writeRow(
        self: *const Buffer,
        w: anytype,
        y: usize,
        tracked: *Emitted,
        styles: *SgrCache,
    ) !void {
        const row = self.rowSlots(y);
        const base = y * @as(usize, self.width);
        // The emitted key of the last packed style seen: neighbouring
        // cells nearly always share one, so it is derived once per run.
        var key_style: u64 = 0;
        var key: Emitted = default_style;
        var run: [128]u8 = undefined;
        var x: usize = 0;
        var phys_col: usize = 0; // terminal cursor column, 0-indexed
        while (x < row.len) {
            const s = row[x];
            // Wide continuations never emit text (their column was
            // covered by the lead's write, which advances 2), and default
            // blanks are already blank after the erase.
            if (!s.paints()) {
                x += 1;
                continue;
            }

            const wide = s.meta.borrowed and Width.graphemeWidth(self.text[base + x]) >= 2;
            const wcell: usize = if (wide) 2 else 1;
            // A wide glyph at the last column has no continuation cell;
            // drop it (graceful — over-wide never errors).
            if (x + wcell > row.len) {
                x += 1;
                continue;
            }

            if (x > phys_col) {
                try w.print("\x1b[{d}C", .{x - phys_col});
            }
            if (s.style != key_style) {
                key_style = s.style;
                key = Emitted.ofPacked(s.style);
            }
            try styles.emit(w, tracked, key);
            if (s.meta.borrowed) {
                try w.writeAll(self.text[base + x]);
                x += wcell;
            } else {
                // A by-value slot is one byte, one column; so is every
                // following one that prints in the same style.
                var n: usize = 0;
                while (x < row.len and n < run.len) : (n += 1) {
                    const t = row[x];
                    if (t.style != s.style or t.meta.borrowed or !t.paints()) break;
                    run[n] = @truncate(t.glyph);
                    x += 1;
                }
                try w.writeAll(run[0..n]);
            }
            phys_col = x;
        }
    }

    /// Emitted row geometry: painted end, wide leads, and unprinted gaps.
    ///
    /// Wide leads determine whole-glyph packing. Unprinted gaps differ
    /// from printed spaces when clipping or erasing a suffix removes the
    /// row's last glyph: the terminal trims trailing null cells, but
    /// keeps spaces. Both tapes belong to the caller and can be reused.
    /// Dense narrow-glyph rows append nothing and allocate nothing.
    /// The default is a blank row with no tape entries. Copies share tape indices, not storage.
    /// Query arguments must contain this record's full sorted, in-range, nonoverlapping
    /// tape ranges. Keep the tape contents unchanged while the footprint is queried.
    pub const RowFootprint = struct {
        /// One past the last column this row paints; zero paints
        /// nothing. Trailing default blanks are NOT counted, because
        /// the erase already left them blank, while a blank the
        /// renderer had to skip between two glyphs IS: it is a column
        /// of the row the terminal is still showing.
        columns: u16 = 0,
        /// Index of this row's first width-2 glyph in the tape.
        wide_start: usize = 0,
        /// The width-2 glyphs this row paints, in ascending column
        /// order, at `wide_columns[wide_start..][0..wide_count]`. The
        /// positions are the shape a packer cannot rebuild from a count,
        /// so they are kept verbatim.
        wide_count: usize = 0,
        /// Unprinted intervals in the caller's separate gap tape.
        /// A prefix shares the source slice; intersect intervals with
        /// `columns` when copying or rebasing that prefix.
        null_start: usize = 0,
        null_count: usize = 0,

        /// Half-open unprinted column interval. `start < end` and both are within the row.
        pub const NullGap = struct {
            start: u16,
            end: u16,
        };

        /// End of the last painted cell before a logical column cut.
        /// The cut must not split a wide glyph; `prefixRows` supplies
        /// whole-glyph cuts. This does not change the existing physical
        /// chunk count. It supplies the trimmed end for later reflow.
        pub fn paintedPrefixColumns(
            self: RowFootprint,
            null_gaps: []const NullGap,
            before: u16,
        ) u16 {
            const end = @min(before, self.columns);
            const gaps = null_gaps[self.null_start..][0..self.null_count];
            var lo: usize = 0;
            var hi: usize = gaps.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (gaps[mid].start < end) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            if (lo == 0) return end;
            const gap = gaps[lo - 1];
            return if (end <= gap.end) gap.start else end;
        }

        /// The narrowest width this projection packs at. An
        /// xterm-style terminal reflows down to two columns and no
        /// further: a caller may ask for less, but a wide glyph still
        /// occupies both of its columns, so the packing does not
        /// narrow. This is the declared contract of the native reflow
        /// mode, not a guarantee every terminal makes.
        const min_reflow_columns: u16 = 2;

        /// How many physical rows this logical row occupies once the
        /// terminal reflows it to `cols` columns.
        ///
        /// Greedy whole-glyph packing: columns are consumed left to
        /// right, and a width-2 glyph with only one column left in the
        /// chunk moves DOWN whole instead of being split, which is why
        /// this is not a ceiling division. Every other column counts as
        /// one, whatever it holds: a narrow glyph, a skipped blank, a
        /// null gap. A chunk's last glyph alone decides where the next
        /// chunk starts, so the columns an odd width leaves over are
        /// padding, not cells the next row inherits.
        ///
        /// A row that paints nothing is one blank physical row, and the
        /// count is a `u32` because a 65535-column row reflowed to two
        /// columns is 32768 rows deep.
        pub fn rowsAt(self: RowFootprint, wide_columns: []const u16, cols: u16) u32 {
            if (self.columns == 0) return 1; // a blank row is still a row
            const width: u32 = @max(@as(u32, cols), min_reflow_columns);
            // Without a wide glyph nothing can move down, so the row is
            // exactly its ceiling division: a 65535-column row at two
            // columns answers without walking a single cell.
            if (self.wide_count == 0) return (@as(u32, self.columns) + width - 1) / width;
            return self.packChunks(wide_columns, cols, std.math.maxInt(u32)).rows;
        }

        /// The logical prefix the first `rows` physical chunks cover.
        ///
        /// Erasing a retired suffix leaves the rows above it, and what
        /// stays has to be described in the same terms it was captured
        /// in. The prefix ends at the last glyph of the last retained
        /// chunk, never in the columns an odd width padded it with,
        /// because padding is neither a glyph nor a null gap. Zero rows
        /// take nothing; `rows` at or past `rowsAt` is the whole row,
        /// which keeps an untruncated band off the prefix path.
        pub fn prefixRows(
            self: RowFootprint,
            wide_columns: []const u16,
            cols: u16,
            rows: u32,
        ) RowFootprint {
            if (rows == 0) return .{}; // no chunk, no logical cells
            if (self.columns == 0) return self; // one blank chunk
            const prefix = self.packChunks(wide_columns, cols, rows);
            // Fewer chunks than asked for means the whole row fit.
            if (prefix.rows < rows) return self;
            return .{
                .columns = prefix.columns,
                .wide_start = self.wide_start,
                .wide_count = prefix.wide_count,
                .null_start = self.null_start,
                .null_count = self.null_count,
            };
        }

        /// One packing walk, shared by both queries above so they
        /// cannot answer differently about the same row: greedy
        /// chunking of the logical columns, stopped after `stop_after`
        /// chunks (a maxInt walk simply runs to the row's end). The
        /// walk steps lead to lead, never cell to cell: the run of
        /// one-cell columns before the next lead is arithmetic, which
        /// keeps a maximum-width row off a 65535-step loop.
        const Packed = struct {
            /// Physical chunks this prefix covers. A walk stopped at
            /// `stop_after` reports the chunks it kept, never the one
            /// it refused to fill, so `prefixRows` can tell a cut from a
            /// row that simply ended first.
            rows: u32,
            /// Logical columns the last completed chunk covered: the
            /// end of its last glyph, padding excluded.
            columns: u16,
            /// Width-2 glyphs the completed chunks consumed.
            wide_count: usize,
        };

        fn packChunks(
            self: RowFootprint,
            wide_columns: []const u16,
            cols: u16,
            stop_after: u32,
        ) Packed {
            // At least one wide glyph fits every chunk, so no chunk is
            // ever opened empty and a narrower ask cannot loop.
            const limit: u32 = self.columns;
            const width: u32 = @max(@as(u32, cols), min_reflow_columns);
            var out: Packed = .{ .rows = 1, .columns = 0, .wide_count = 0 };
            var used: u32 = 0; // columns filled in the chunk being built
            var x: u32 = 0; // the next logical column
            var wide: usize = 0; // index into this row's wide positions
            while (x < limit) {
                const lead = self.wideAt(wide_columns, wide);
                const run_end: u32 = if (lead) |col| @min(col, limit) else limit;
                if (run_end > x) {
                    // Every column before the next lead is one cell:
                    // a narrow glyph, a skipped blank, a null gap. They
                    // fill the room left in this chunk and then whole
                    // chunks of their own, so the run costs arithmetic
                    // rather than one step per column.
                    const room: u32 = width - used;
                    const first: u32 = @min(run_end - x, room);
                    const rest: u32 = (run_end - x) - first;
                    const extra: u32 = (rest + width - 1) / width;
                    if (out.rows + extra > stop_after) {
                        // The prefix stops inside the run. Every chunk
                        // after the first is full, so its boundary is
                        // arithmetic too: the retained prefix ends at
                        // the last glyph of the last kept chunk.
                        const kept: u32 = stop_after - out.rows + 1;
                        out.rows = stop_after;
                        out.columns = @intCast(x + first + (kept - 1) * width);
                        return out;
                    }
                    out.rows += extra;
                    used = if (extra == 0) used + first else rest - (extra - 1) * width;
                    x = run_end;
                    out.columns = @intCast(x);
                    continue;
                }
                // A lead spans two columns and moves down whole.
                if (used + 2 > width) {
                    out.rows += 1;
                    if (out.rows > stop_after) {
                        // The chunk the lead would have opened is not
                        // part of the prefix; the boundary and the row
                        // count stay with the chunks already kept.
                        out.rows = stop_after;
                        return out;
                    }
                    used = 0;
                }
                used += 2;
                x += 2;
                wide += 1;
                out.columns = @intCast(x);
                out.wide_count = wide;
            }
            return out;
        }

        /// The column this row's `index`-th width-2 glyph starts at, or
        /// null when the row holds no further one. The tape is retained
        /// metadata the owner vouches for: sorted, in range, and long
        /// enough for `wide_count`. Re-checking it here would turn a
        /// broken record into a quietly short row, so it is indexed
        /// directly.
        fn wideAt(self: RowFootprint, wide_columns: []const u16, index: usize) ?u32 {
            if (index >= self.wide_count) return null;
            return wide_columns[self.wide_start + index];
        }
    };

    /// Record `writeRow` geometry without copying text or retaining cells.
    /// Wide leads and unprinted gaps use separate caller-owned tapes.
    /// Printed spaces are content, not null cells. Dense narrow-glyph
    /// rows touch neither tape nor allocator.
    ///
    /// The skip rules are `writeRow`'s own, cell for cell: a wide
    /// continuation, an empty grapheme and a default-styled blank paint
    /// nothing; a wide lead with no continuation column to own is
    /// dropped; a styled blank paints even at the tail. What is
    /// recorded is therefore exactly the geometry the terminal ends up
    /// with, and nothing here changes what is emitted.
    ///
    /// Both tapes append row-local positions. The footprint names each
    /// row's slice. On allocation failure both lengths return to their
    /// original values; any capacity increase remains reusable.
    /// `gpa` must own both tapes and stay live until the caller deinitializes them.
    pub fn rowFootprint(
        self: *const Buffer,
        gpa: std.mem.Allocator,
        y: u16,
        wide_columns: *std.ArrayList(u16),
        null_gaps: *std.ArrayList(RowFootprint.NullGap),
    ) error{OutOfMemory}!RowFootprint {
        const start = wide_columns.items.len;
        const null_start = null_gaps.items.len;
        if (y >= self.height) return .{}; // no such row paints nothing
        errdefer {
            wide_columns.shrinkRetainingCapacity(start);
            null_gaps.shrinkRetainingCapacity(null_start);
        }

        const row = self.rowSlots(y);
        const base = @as(usize, y) * @as(usize, self.width);
        var x: usize = 0;
        var end: usize = 0; // past the last cell the row paints
        while (x < row.len) {
            // Eight cells at a time while none is borrowed: every painting
            // cell is then one column, so the chunk's paint mask alone
            // gives its runs and the gaps between them.
            const chunk_end = x + 8;
            if (chunk_end <= row.len) {
                const hits = Slot.paintHits(row[x..][0..8]);
                if (hits.borrowed == 0) {
                    var p: u16 = hits.paints;
                    while (p != 0) {
                        const first = @ctz(p);
                        const run = @ctz(~(p >> @intCast(first)));
                        const at = x + first;
                        if (at > end) try null_gaps.append(gpa, .{
                            .start = @intCast(end),
                            .end = @intCast(at),
                        });
                        end = at + run;
                        p &= ~((@as(u16, 1) << @intCast(first + run)) - 1);
                    }
                    x = chunk_end;
                    continue;
                }
            }
            // A chunk with borrowed text, or the row's tail: cell by cell
            // (a wide glyph may carry `x` one past the chunk).
            const stop = @min(chunk_end, row.len);
            while (x < stop) {
                const s = row[x];
                if (!s.paints()) {
                    x += 1;
                    continue;
                }

                const wide = s.meta.borrowed and Width.graphemeWidth(self.text[base + x]) >= 2;
                const wcell: usize = if (wide) 2 else 1;
                if (x + wcell > row.len) {
                    x += 1;
                    continue; // dropped lead: nothing was painted here
                }

                if (wcell == 2) try wide_columns.append(gpa, @intCast(x));
                if (x > end) try null_gaps.append(gpa, .{
                    .start = @intCast(end),
                    .end = @intCast(x),
                });
                x += wcell;
                end = x;
            }
        }
        return .{
            .columns = @intCast(end),
            .wide_start = start,
            .wide_count = wide_columns.items.len - start,
            .null_start = null_start,
            .null_count = null_gaps.items.len - null_start,
        };
    }
};

/// Colour kinds in a packed style: 3 bits above a 24-bit payload. Zero is
/// an unset (`null`) colour, which is not `Color.default`.
const colour_bits = 27;
const colour_mask: u64 = (1 << colour_bits) - 1;
const payload_mask: u64 = (1 << 24) - 1;
const kind_default: u64 = 1;
const kind_ansi: u64 = 2;
const kind_256: u64 = 3;
const kind_rgb: u64 = 4;

/// A `Style` without its hyperlink, packed exactly into one word:
/// `[ attrs:7 | bg:27 | fg:27 ]`, so equal words are equal styles.
fn packStyle(style: Style) u64 {
    const attrs: u7 = @bitCast(style.attrs);
    return packColour(style.fg) | packColour(style.bg) << colour_bits |
        @as(u64, attrs) << (2 * colour_bits);
}

fn packColour(colour: ?Color) u64 {
    const c = colour orelse return 0;
    return switch (c) {
        .default => kind_default << 24,
        .ansi => |a| kind_ansi << 24 | @intFromEnum(a),
        .ansi256 => |n| kind_256 << 24 | n,
        .rgb => |v| kind_rgb << 24 | @as(u64, v.r) << 16 | @as(u64, v.g) << 8 | v.b,
    };
}

/// Inverse of `packStyle`, hyperlink unset.
fn unpackStyle(word: u64) Style {
    return .{
        .fg = unpackColour(word & colour_mask),
        .bg = unpackColour(word >> colour_bits & colour_mask),
        .attrs = @bitCast(@as(u7, @truncate(word >> (2 * colour_bits)))),
    };
}

fn unpackColour(bits: u64) ?Color {
    const payload = bits & payload_mask;
    return switch (bits >> 24) {
        0 => null,
        kind_default => .default,
        kind_ansi => .{ .ansi = @enumFromInt(@as(u8, @truncate(payload))) },
        kind_256 => .{ .ansi256 = @truncate(payload) },
        kind_rgb => .{ .rgb = .{
            .r = @truncate(payload >> 16),
            .g = @truncate(payload >> 8),
            .b = @truncate(payload),
        } },
        else => unreachable, // only packColour writes these bits
    };
}

/// The style a cell's `Style` actually puts on the wire, packed into one
/// comparable word: `[ fg:26 | bg:26 | attrs:7 ]`, zero being default.
///
/// A `Style` carries three things the terminal never sees: a `null`
/// colour and `Color.default` both emit nothing, and a hyperlink is not
/// emitted at all (OSC 8 is deferred, emit.zig:6). Keying the memo on
/// this view instead of on `Style.eql` is what stops a null-vs-default
/// colour or a hyperlink swap from spending a reset that repaints the
/// same pixels. The key contains no borrowed slices. Changes to borrowed
/// graphemes or hyperlinks cannot change the key.
const Emitted = struct {
    key: u64 = 0,

    const bg_shift: u6 = 26;
    const attr_shift: u6 = 52;
    const key_colour_mask: u64 = (1 << 26) - 1;

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
        return ofPacked(packStyle(style));
    }

    /// The emitted view of a `packStyle` word. `Style.Attrs` is packed in
    /// SGR attribute order, so the attribute bits carry over unchanged.
    fn ofPacked(word: u64) Emitted {
        return .{ .key = emittedColour(word & colour_mask, false) |
            emittedColour(word >> colour_bits & colour_mask, true) << bg_shift |
            (word >> (2 * colour_bits)) << attr_shift };
    }

    fn eql(a: Emitted, b: Emitted) bool {
        return a.key == b.key;
    }

    fn isDefault(a: Emitted) bool {
        return a.key == 0;
    }

    fn fg(a: Emitted) u32 {
        return @truncate(a.key & key_colour_mask);
    }

    fn bg(a: Emitted) u32 {
        return @truncate((a.key >> bg_shift) & key_colour_mask);
    }

    fn attrs(a: Emitted) u8 {
        return @truncate(a.key >> attr_shift);
    }
};

/// A packed colour as it prints, in 26 bits: kind in the top two, payload
/// below. Kind 0 — a `null` field or `Color.default` — is the all-zero
/// word and emits nothing. An `ansi` colour stores the SGR parameter it
/// prints, so the encoder never has to re-derive it.
fn emittedColour(bits: u64, background: bool) u64 {
    const payload = bits & payload_mask;
    return switch (bits >> 24) {
        0, kind_default => 0,
        kind_ansi => {
            const a: AnsiColor = @enumFromInt(@as(u8, @truncate(payload)));
            return 1 << 24 | @as(u64, if (background) a.bgCode() else a.fgCode());
        },
        kind_256 => 2 << 24 | payload,
        kind_rgb => 3 << 24 | payload,
        else => unreachable, // only packColour writes these bits
    };
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
///
/// Start one with `empty()`: only the occupancy mask is initialized, so a
/// frame does not pay to clear 1.5 KiB of slots it may never touch.
const SgrCache = struct {
    used: SlotMask,
    from_keys: [sgr_cache_slots]u64,
    to_keys: [sgr_cache_slots]u64,
    lens: [sgr_cache_slots]u8,
    bytes: [sgr_cache_slots][max_sgr_bytes]u8,

    const SlotMask = @Int(.unsigned, sgr_cache_slots);

    fn empty() SgrCache {
        var cache: SgrCache = undefined;
        cache.used = 0;
        return cache;
    }

    fn bit(slot: usize) SlotMask {
        return @as(SlotMask, 1) << @intCast(slot);
    }

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
        return self.used & bit(slot) != 0 and
            self.from_keys[slot] == from.key and
            self.to_keys[slot] == to.key;
    }

    fn store(self: *SgrCache, slot: usize, from: Emitted, to: Emitted) void {
        const len = encodeTransition(&self.bytes[slot], from, to);
        self.lens[slot] = len;
        self.from_keys[slot] = from.key;
        self.to_keys[slot] = to.key;
        self.used |= bit(slot);
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

test "buffer: the eight-slot flag scan finds exactly the flagged slots" {
    // Lengths around the eight-slot step, a flag pattern that hits chunk
    // edges and the scalar tail.
    var slots: [40]Buffer.Slot = undefined;
    for (0..slots.len + 1) |len| {
        for (slots[0..len], 0..) |*s, i| {
            s.* = Buffer.Slot.blank;
            s.meta.borrowed = i % 7 == 0 or i % 8 == 7;
            s.meta.deep = i % 5 == 3;
        }
        for ([_]u32{ Buffer.Slot.borrowed_bit, Buffer.Slot.deep_bit }) |mask| {
            var it: Buffer.Slot.Flagged = .{ .slots = slots[0..len], .mask = mask };
            var want: usize = 0;
            while (it.next()) |i| : (want += 1) {
                while (@as(u32, @bitCast(slots[want].meta)) & mask == 0) want += 1;
                try std.testing.expectEqual(want, i);
            }
            while (want < len) : (want += 1) {
                try std.testing.expect(@as(u32, @bitCast(slots[want].meta)) & mask == 0);
            }
        }
    }
}

test "buffer: copyFrom carries borrowed text and links across chunk edges" {
    // Source rows mix by-value ASCII, borrowed clusters and hyperlinks in a
    // pattern that lands on eight-cell chunk edges and the scalar tail; the
    // target starts with other borrowed text. Same, wider and narrower
    // widths take the whole-grid and the per-row copy. All clusters are one
    // column wide, so no wide pair straddles the copied rectangle's edge.
    const borrowed = "e\u{301}\u{301}";
    const other = "a\u{301}\u{301}\u{301}";
    const gpa = std.testing.allocator;
    const link: Style = .{ .hyperlink = "https://example.com" };
    for (5..22) |w0| {
        const w: u16 = @intCast(w0);
        var src = try Buffer.init(gpa, w, 3);
        defer src.deinit();
        for (0..3) |y| for (0..w) |x| {
            const k = x * 3 + y;
            const cell: Cell = if (k % 7 == 0)
                .{ .grapheme = borrowed }
            else if (k % 5 == 2)
                .{ .grapheme = "x", .style = link }
            else
                .{ .grapheme = Cell.asciiGrapheme(@intCast('a' + k % 26)) };
            try src.set(@intCast(x), @intCast(y), cell);
        };
        for ([_]u16{ w, w + 3, w - 2 }) |dw| {
            var dst = try Buffer.init(gpa, dw, 4);
            defer dst.deinit();
            for (0..4) |y| for (0..dw) |x| {
                try dst.set(@intCast(x), @intCast(y), .{ .grapheme = other });
            };
            dst.copyFrom(&src);
            for (0..4) |y| for (0..dw) |x| {
                const got = dst.get(@intCast(x), @intCast(y));
                const want: Cell = if (y < 3 and x < w)
                    src.get(@intCast(x), @intCast(y))
                else
                    .{ .grapheme = other };
                try std.testing.expect(got.eql(want));
            };
        }
    }
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

test "buffer: every colour kind, attribute and hyperlink survives the packed slot" {
    var buf = try Buffer.init(std.testing.allocator, 2, 1);
    defer buf.deinit();
    const colours = [_]?Color{
        null,
        .default,
        .{ .ansi = .black },
        .{ .ansi = .bright_white },
        .{ .ansi256 = 0 },
        .{ .ansi256 = 255 },
        .{ .rgb = .{ .r = 0, .g = 0, .b = 0 } },
        .{ .rgb = .{ .r = 255, .g = 1, .b = 254 } },
    };
    for (colours) |fg| for (colours) |bg| for ([_]u7{ 0, 1, 0x2a, 0x7f }) |attrs| {
        const style: Style = .{
            .fg = fg,
            .bg = bg,
            .attrs = @bitCast(attrs),
            .hyperlink = if (attrs == 1) "https://example.com" else null,
        };
        _ = try buf.draw(style, "a", 0, 0);
        try buf.set(1, 0, .{ .grapheme = "é", .style = style });
        try std.testing.expect(buf.get(0, 0).style.eql(style));
        try std.testing.expect(buf.get(1, 0).style.eql(style));
        // Null and `default` differ for `eql`, but print the same.
        try std.testing.expect(Emitted.of(buf.get(0, 0).style).eql(Emitted.of(style)));
    };
}

test "buffer: rowChanged decides like a cell-by-cell Cell.eql" {
    // Each pair is drawn into `cur` and `prev` from separate storage:
    // the long grapheme and the hyperlink live outside the slot, so only
    // their content may decide.
    const Case = struct { a: Cell, b: Cell };
    const long_a = "e\u{301}\u{302}"; // five bytes
    const long_b = "e\u{301}\u{303}"; // differs only in its fifth byte
    const cases = [_]Case{
        .{ .a = .{ .grapheme = long_a }, .b = .{ .grapheme = long_a } },
        .{ .a = .{ .grapheme = long_a }, .b = .{ .grapheme = long_b } },
        .{ .a = .{ .grapheme = "é" }, .b = .{ .grapheme = "è" } },
        .{
            .a = .{ .grapheme = "x", .style = .{ .hyperlink = "https://a" } },
            .b = .{ .grapheme = "x", .style = .{ .hyperlink = "https://a" } },
        },
        .{
            .a = .{ .grapheme = "x", .style = .{ .hyperlink = "https://a" } },
            .b = .{ .grapheme = "x", .style = .{ .hyperlink = "https://b" } },
        },
        .{
            .a = .{ .grapheme = "x", .style = .{ .hyperlink = "https://a" } },
            .b = .{ .grapheme = "x" },
        },
        .{ .a = .{ .style = .{ .fg = .default } }, .b = .{} },
    };
    for (cases) |c| {
        var cur = try Buffer.init(std.testing.allocator, 3, 1);
        defer cur.deinit();
        var prev = try Buffer.init(std.testing.allocator, 3, 1);
        defer prev.deinit();
        // Copies in separate storage, so equal content never shares a pointer.
        var a_text: [16]u8 = undefined;
        var b_text: [16]u8 = undefined;
        var a_link: [16]u8 = undefined;
        var b_link: [16]u8 = undefined;
        var a = c.a;
        var b = c.b;
        @memcpy(a_text[0..a.grapheme.len], a.grapheme);
        a.grapheme = a_text[0..a.grapheme.len];
        @memcpy(b_text[0..b.grapheme.len], b.grapheme);
        b.grapheme = b_text[0..b.grapheme.len];
        if (a.style.hyperlink) |l| {
            @memcpy(a_link[0..l.len], l);
            a.style.hyperlink = a_link[0..l.len];
        }
        if (b.style.hyperlink) |l| {
            @memcpy(b_link[0..l.len], l);
            b.style.hyperlink = b_link[0..l.len];
        }
        try cur.set(1, 0, a);
        try prev.set(1, 0, b);
        try std.testing.expectEqual(!a.eql(b), cur.rowChanged(&prev, 0));
    }
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

test "buffer: an ASCII run over wide pairs matches cell-by-cell placement" {
    // Wide pairs at columns 1-2, 5-6 and 17-18; every run start and length
    // that fits, drawn in one call, must leave the grid `set` would leave
    // one cell at a time — including a run ending on a lead or starting on
    // a continuation, with both short and long runs. The style carries a
    // hyperlink, so the comparison covers both hot slots and cold data.
    const text = "abcdefghijklmnopqrstuvwx";
    const style: Style = .{
        .fg = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
        .attrs = .{ .bold = true },
        .hyperlink = "https://example.com",
    };
    for (0..text.len) |x0| {
        for (1..text.len - x0 + 1) |len| {
            var got = try Buffer.init(std.testing.allocator, text.len, 2);
            defer got.deinit();
            var want = try Buffer.init(std.testing.allocator, text.len, 2);
            defer want.deinit();
            for ([_]*Buffer{ &got, &want }) |b| {
                try b.set(1, 1, .{ .grapheme = "日" });
                try b.set(5, 1, .{ .grapheme = "本" });
                try b.set(17, 1, .{ .grapheme = "語" });
            }
            const x: u16 = @intCast(x0);
            _ = try got.draw(style, text[0..len], x, 1);
            for (text[0..len], 0..) |b, i| {
                try want.set(x + @as(u16, @intCast(i)), 1, .{
                    .grapheme = Cell.asciiGrapheme(b),
                    .style = style,
                });
            }
            for (got.slots, want.slots, 0..) |g, w, i| {
                try std.testing.expectEqual(g.bits(), w.bits());
                try std.testing.expect(got.cellAt(i).eql(want.cellAt(i)));
            }
        }
    }
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
        self.* = undefined;
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
        const len = Width.firstCellLen(rest);
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

// ── row footprints (native width reflow) ─────────────────

test "rowFootprint: interior gaps are columns, trailing blanks are not" {
    const gpa = std.testing.allocator;
    var buf = try Buffer.init(gpa, 10, 1);
    defer buf.deinit();
    _ = try buf.draw(Style{}, "a", 0, 0);
    _ = try buf.draw(Style{}, "b", 4, 0); // columns 1..3 stay blank
    var tape: std.ArrayList(u16) = .empty;
    defer tape.deinit(gpa);
    var null_gaps: std.ArrayList(Buffer.RowFootprint.NullGap) = .empty;
    defer null_gaps.deinit(gpa);

    const fp = try buf.rowFootprint(gpa, 0, &tape, &null_gaps);
    // The erase left columns 5..9 blank, so they are not part of the
    // row. The blanks the renderer SKIPPED between the two glyphs are:
    // they are columns the terminal still shows.
    try std.testing.expectEqual(@as(u16, 5), fp.columns);
    try std.testing.expectEqual(@as(usize, 0), fp.wide_count);
    try std.testing.expectEqual(@as(u32, 1), fp.rowsAt(tape.items, 10));
    // At three columns the five pack as three plus two; a record that
    // compressed the blanks away would call this a single row.
    try std.testing.expectEqual(@as(u32, 2), fp.rowsAt(tape.items, 3));
    try std.testing.expectEqual(@as(u16, 3), fp.prefixRows(tape.items, 3, 1).columns);
}

test "rowFootprint: a styled tail blank counts, a default one does not" {
    const gpa = std.testing.allocator;
    const shaded: Style = .{ .bg = .{ .ansi = .blue } };
    var buf = try Buffer.init(gpa, 6, 1);
    defer buf.deinit();
    _ = try buf.draw(Style{}, "ab", 0, 0);
    var tape: std.ArrayList(u16) = .empty;
    defer tape.deinit(gpa);
    var null_gaps: std.ArrayList(Buffer.RowFootprint.NullGap) = .empty;
    defer null_gaps.deinit(gpa);

    try std.testing.expectEqual(
        @as(u16, 2),
        (try buf.rowFootprint(gpa, 0, &tape, &null_gaps)).columns,
    );

    // A styled blank emits so its background paints, and `draw` takes
    // the style it is handed: a row that ends in one is that wide even
    // though the erase already blanked the column.
    _ = try buf.draw(shaded, " ", 4, 0);
    const fp = try buf.rowFootprint(gpa, 0, &tape, &null_gaps);
    try std.testing.expectEqual(@as(u16, 5), fp.columns);
    try std.testing.expectEqual(@as(u32, 1), fp.rowsAt(tape.items, 5));
}

test "rowFootprint: continuations, empty graphemes and dropped leads emit nothing" {
    const gpa = std.testing.allocator;
    var buf = try Buffer.init(gpa, 4, 2);
    defer buf.deinit();
    _ = try buf.draw(Style{}, "a界", 0, 0);
    var tape: std.ArrayList(u16) = .empty;
    defer tape.deinit(gpa);
    var null_gaps: std.ArrayList(Buffer.RowFootprint.NullGap) = .empty;
    defer null_gaps.deinit(gpa);

    // The wide glyph at column 1 is painted by one write covering two
    // columns; its continuation at column 2 emits nothing of its own.
    const painted = try buf.rowFootprint(gpa, 0, &tape, &null_gaps);
    try std.testing.expectEqual(@as(u16, 3), painted.columns);
    try std.testing.expectEqualSlices(u16, &.{1}, tape.items);

    // Row 1: a styled empty grapheme, a stray continuation carrying
    // text, and a wide lead at the last column with no continuation
    // cell to own. None of them reaches the wire, so the row paints
    // nothing and adds no positions to the shared tape.
    try buf.set(0, 1, .{ .grapheme = "", .style = .{ .fg = .{ .ansi = .red } } });
    try buf.set(1, 1, .{ .grapheme = "z", .wide = true });
    try buf.set(3, 1, .{ .grapheme = "界" });
    const blank = try buf.rowFootprint(gpa, 1, &tape, &null_gaps);
    try std.testing.expectEqual(@as(u16, 0), blank.columns);
    try std.testing.expectEqual(@as(usize, 0), blank.wide_count);
    try std.testing.expectEqual(@as(usize, 1), blank.wide_start);
    try std.testing.expectEqualSlices(u16, &.{1}, tape.items);
    try std.testing.expectEqual(@as(u32, 1), blank.rowsAt(tape.items, 4));
}

test "rowsAt: whole-grapheme packing, not a ceiling division" {
    const gpa = std.testing.allocator;
    var buf = try Buffer.init(gpa, 8, 1);
    defer buf.deinit();
    _ = try buf.draw(Style{}, "界界界界", 0, 0);
    var tape: std.ArrayList(u16) = .empty;
    defer tape.deinit(gpa);
    var null_gaps: std.ArrayList(Buffer.RowFootprint.NullGap) = .empty;
    defer null_gaps.deinit(gpa);
    const fp = try buf.rowFootprint(gpa, 0, &tape, &null_gaps);

    try std.testing.expectEqual(@as(u16, 8), fp.columns);
    try std.testing.expectEqualSlices(u16, &.{ 0, 2, 4, 6 }, tape.items);
    try std.testing.expectEqual(fp.wide_start + fp.wide_count, tape.items.len);

    // ceil(8 / w) answers 1, 3, 2, 1. Packing whole glyphs answers
    // 1, 4, 2, 1: at three columns a wide glyph leaves one column of
    // padding it may not use, so it moves down whole.
    try std.testing.expectEqual(@as(u32, 1), fp.rowsAt(tape.items, 10));
    try std.testing.expectEqual(@as(u32, 4), fp.rowsAt(tape.items, 3));
    try std.testing.expectEqual(@as(u32, 2), fp.rowsAt(tape.items, 5));

    // Two columns is the floor this projection declares for an
    // xterm-style terminal; a narrower ask reflows no further.
    try std.testing.expectEqual(@as(u32, 4), fp.rowsAt(tape.items, 1));
    try std.testing.expectEqual(@as(u32, 4), fp.rowsAt(tape.items, 0));
}

test "prefixRows: a chunk ends at its last glyph, never in its padding" {
    const gpa = std.testing.allocator;
    var buf = try Buffer.init(gpa, 8, 1);
    defer buf.deinit();
    _ = try buf.draw(Style{}, "界界界界", 0, 0);
    var tape: std.ArrayList(u16) = .empty;
    defer tape.deinit(gpa);
    var null_gaps: std.ArrayList(Buffer.RowFootprint.NullGap) = .empty;
    defer null_gaps.deinit(gpa);
    const fp = try buf.rowFootprint(gpa, 0, &tape, &null_gaps);

    // Three columns hold one wide glyph and one column of padding. That
    // padding is neither a glyph nor a null gap, so the prefix of the
    // first chunk is the two painted columns.
    const one = fp.prefixRows(tape.items, 3, 1);
    try std.testing.expectEqual(@as(u16, 2), one.columns);
    try std.testing.expectEqual(@as(usize, 1), one.wide_count);
    try std.testing.expectEqual(fp.wide_start, one.wide_start);
    // The prefix is a footprint of its own: it still packs to one row.
    try std.testing.expectEqual(@as(u32, 1), one.rowsAt(tape.items, 3));

    const two = fp.prefixRows(tape.items, 3, 2);
    try std.testing.expectEqual(@as(u16, 4), two.columns);
    try std.testing.expectEqual(@as(usize, 2), two.wide_count);

    // Nothing taken, everything taken, and more than the row holds.
    try std.testing.expectEqual(@as(u16, 0), fp.prefixRows(tape.items, 3, 0).columns);
    try std.testing.expectEqual(@as(usize, 0), fp.prefixRows(tape.items, 3, 0).wide_count);
    try std.testing.expectEqual(fp.columns, fp.prefixRows(tape.items, 3, 4).columns);
    try std.testing.expectEqual(fp.wide_count, fp.prefixRows(tape.items, 3, 4).wide_count);
    try std.testing.expectEqual(fp.columns, fp.prefixRows(tape.items, 3, 99).columns);
}

test "prefixRows: a cut inside a one-cell run keeps whole chunks" {
    const gpa = std.testing.allocator;
    var buf = try Buffer.init(gpa, 40, 2);
    defer buf.deinit();
    _ = try buf.draw(Style{}, "x" ** 40, 0, 0);
    _ = try buf.draw(Style{}, "界" ++ "x" ** 20, 0, 1);
    var tape: std.ArrayList(u16) = .empty;
    defer tape.deinit(gpa);
    var null_gaps: std.ArrayList(Buffer.RowFootprint.NullGap) = .empty;
    defer null_gaps.deinit(gpa);

    // Forty plain columns are four chunks of ten, and nothing in them
    // can move down, so a cut after two chunks is exactly the end of
    // the second: twenty columns, still two chunks.
    const ascii = try buf.rowFootprint(gpa, 0, &tape, &null_gaps);
    try std.testing.expectEqual(@as(u16, 40), ascii.columns);
    try std.testing.expectEqual(@as(u32, 4), ascii.rowsAt(tape.items, 10));
    const cut = ascii.prefixRows(tape.items, 10, 2);
    try std.testing.expectEqual(@as(u16, 20), cut.columns);
    try std.testing.expectEqual(@as(usize, 0), cut.wide_count);
    try std.testing.expectEqual(@as(u32, 2), cut.rowsAt(tape.items, 10));

    // One wide lead and twenty one-cell columns: the lead plus three
    // narrow cells fill the first chunk of five, so five more chunks
    // take the rest and the cut below lands inside that run. The
    // boundary must still be a whole chunk, and the prefix must still
    // be a footprint of its own.
    const mixed = try buf.rowFootprint(gpa, 1, &tape, &null_gaps);
    try std.testing.expectEqual(@as(u16, 22), mixed.columns);
    try std.testing.expectEqual(@as(u32, 5), mixed.rowsAt(tape.items, 5));
    const two = mixed.prefixRows(tape.items, 5, 2);
    try std.testing.expectEqual(@as(u16, 10), two.columns);
    try std.testing.expectEqual(@as(usize, 1), two.wide_count);
    try std.testing.expectEqual(@as(u32, 2), two.rowsAt(tape.items, 5));
    const three = mixed.prefixRows(tape.items, 5, 3);
    try std.testing.expectEqual(@as(u16, 15), three.columns);
    try std.testing.expectEqual(@as(usize, 1), three.wide_count);
    try std.testing.expectEqual(@as(u32, 3), three.rowsAt(tape.items, 5));
}

test "rowsAt: the wide positions decide the packing, not their count" {
    const gpa = std.testing.allocator;
    var buf = try Buffer.init(gpa, 6, 2);
    defer buf.deinit();
    var tape: std.ArrayList(u16) = .empty;
    defer tape.deinit(gpa);
    var null_gaps: std.ArrayList(Buffer.RowFootprint.NullGap) = .empty;
    defer null_gaps.deinit(gpa);

    // Row 0: 界界xx — the two leads two columns apart, then two narrow
    // cells. Positions are row-local, so the first row's slice starts
    // the tape at 0.
    _ = try buf.draw(Style{}, "界界xx", 0, 0);
    const tight = try buf.rowFootprint(gpa, 0, &tape, &null_gaps);
    try std.testing.expectEqual(@as(u16, 6), tight.columns);
    try std.testing.expectEqualSlices(u16, &.{ 0, 2 }, tape.items);

    // Row 1: 界x界x — the same six painted columns and the same two
    // wide glyphs, but a narrow cell between the leads. Its positions
    // are its own 0 and 3, appended after the first row's.
    _ = try buf.draw(Style{}, "界x界x", 0, 1);
    const sparse = try buf.rowFootprint(gpa, 1, &tape, &null_gaps);
    try std.testing.expectEqualSlices(u16, &.{ 0, 3 }, tape.items[2..]);
    try std.testing.expectEqual(tight.columns, sparse.columns);
    try std.testing.expectEqual(tight.wide_count, sparse.wide_count);

    // At three columns the two still reflow differently, which is what
    // a count-only record could not see: the tight row carries a lead
    // down and fills the rest of its chunk with a narrow cell, while
    // the sparse row rides the lead down and packs two narrow cells
    // beside it.
    try std.testing.expectEqual(@as(u32, 3), tight.rowsAt(tape.items, 3));
    try std.testing.expectEqual(@as(u32, 2), sparse.rowsAt(tape.items, 3));
}

test "prefixRows: a boundary falls before or after a wide glyph" {
    const gpa = std.testing.allocator;
    var buf = try Buffer.init(gpa, 6, 1);
    defer buf.deinit();
    _ = try buf.draw(Style{}, "ab界", 0, 0);
    var tape: std.ArrayList(u16) = .empty;
    defer tape.deinit(gpa);
    var null_gaps: std.ArrayList(Buffer.RowFootprint.NullGap) = .empty;
    defer null_gaps.deinit(gpa);
    const fp = try buf.rowFootprint(gpa, 0, &tape, &null_gaps);
    try std.testing.expectEqual(@as(u16, 4), fp.columns);
    try std.testing.expectEqualSlices(u16, &.{2}, tape.items);

    // Three columns take "ab" and leave the wide glyph one column
    // short; that leftover is padding, not a logical cell, so the first
    // prefix is exactly the two painted narrow glyphs.
    try std.testing.expectEqual(@as(u32, 2), fp.rowsAt(tape.items, 3));
    const before = fp.prefixRows(tape.items, 3, 1);
    try std.testing.expectEqual(@as(u16, 2), before.columns);
    try std.testing.expectEqual(@as(usize, 0), before.wide_count);
    try std.testing.expectEqual(@as(u32, 1), before.rowsAt(tape.items, 3));

    // The second chunk is the wide glyph's own two columns.
    const after = fp.prefixRows(tape.items, 3, 2);
    try std.testing.expectEqual(@as(u16, 4), after.columns);
    try std.testing.expectEqual(@as(usize, 1), after.wide_count);
}

test "rowsAt: a row that paints nothing is one blank physical row" {
    const gpa = std.testing.allocator;
    var buf = try Buffer.init(gpa, 4, 2);
    defer buf.deinit();
    var tape: std.ArrayList(u16) = .empty;
    defer tape.deinit(gpa);
    var null_gaps: std.ArrayList(Buffer.RowFootprint.NullGap) = .empty;
    defer null_gaps.deinit(gpa);

    const blank = try buf.rowFootprint(gpa, 0, &tape, &null_gaps);
    try std.testing.expectEqual(@as(u16, 0), blank.columns);
    try std.testing.expectEqual(@as(u32, 1), blank.rowsAt(tape.items, 4));
    try std.testing.expectEqual(@as(u32, 1), blank.rowsAt(tape.items, 1));
    try std.testing.expectEqual(@as(u16, 0), blank.prefixRows(tape.items, 4, 0).columns);
    try std.testing.expectEqual(blank.columns, blank.prefixRows(tape.items, 4, 1).columns);

    // A row past the band paints nothing and records no positions.
    const past = try buf.rowFootprint(gpa, 9, &tape, &null_gaps);
    try std.testing.expectEqual(@as(u16, 0), past.columns);
    try std.testing.expectEqual(@as(usize, 0), past.wide_count);
    try std.testing.expectEqual(@as(usize, 0), tape.items.len);
}

test "rowFootprint: capture never allocates once both geometry tapes have room" {
    const gpa = std.testing.allocator;
    var buf = try Buffer.init(gpa, 12, 2);
    defer buf.deinit();
    _ = try buf.draw(Style{}, "plain ascii", 0, 0);
    _ = try buf.draw(Style{}, "界界", 0, 1);
    var tape: std.ArrayList(u16) = .empty;
    defer tape.deinit(gpa);
    var null_gaps: std.ArrayList(Buffer.RowFootprint.NullGap) = .empty;
    defer null_gaps.deinit(gpa);
    try tape.ensureTotalCapacity(gpa, 8);
    try null_gaps.ensureTotalCapacity(gpa, 2);

    // The next allocation of any size fails, so a capture that touched
    // the allocator at all would surface as OutOfMemory here.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const alloc = failing.allocator();

    const ascii = try buf.rowFootprint(alloc, 0, &tape, &null_gaps);
    try std.testing.expectEqual(@as(u16, 11), ascii.columns);
    try std.testing.expectEqual(@as(usize, 0), tape.items.len); // ASCII appends nothing

    const wide = try buf.rowFootprint(alloc, 1, &tape, &null_gaps);
    try std.testing.expectEqual(@as(u16, 4), wide.columns);
    try std.testing.expectEqual(@as(usize, 0), wide.wide_start);
    try std.testing.expectEqualSlices(u16, &.{ 0, 2 }, tape.items);
}

test "rowFootprint: a failed capture hands the tape back unchanged" {
    const gpa = std.testing.allocator;
    var buf = try Buffer.init(gpa, 18, 1);
    defer buf.deinit();
    _ = try buf.draw(Style{}, "界界界界界界界界界", 0, 0); // nine leads, 18 columns

    // A tape with exactly one free slot, holding a position an earlier
    // row's capture left behind. The row's first wide lead fits that
    // slot; the second is the one that has to grow the tape, so the
    // failure arrives with one of this row's positions already written.
    var tape: std.ArrayList(u16) = try .initCapacity(gpa, 2);
    defer tape.deinit(gpa);
    try tape.append(gpa, 99);
    var null_gaps: std.ArrayList(Buffer.RowFootprint.NullGap) = .empty;
    defer null_gaps.deinit(gpa);

    // Both ways the tape could grow are denied, so the growth cannot
    // slip past as an in-place remap. The roll-back then has to drop
    // the position the failed capture appended, or the caller's next
    // row would start from a column this row never painted.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    failing.resize_fail_index = 0; // a remap must not sneak past either
    try std.testing.expectError(
        error.OutOfMemory,
        buf.rowFootprint(failing.allocator(), 0, &tape, &null_gaps),
    );
    try std.testing.expectEqualSlices(u16, &.{99}, tape.items);

    const fp = try buf.rowFootprint(gpa, 0, &tape, &null_gaps);
    try std.testing.expectEqual(@as(u16, 18), fp.columns);
    try std.testing.expectEqual(@as(usize, 1), fp.wide_start);
    try std.testing.expectEqual(@as(usize, 9), fp.wide_count);
    try std.testing.expectEqualSlices(u16, &.{ 99, 0, 2, 4, 6, 8, 10, 12, 14, 16 }, tape.items);
}

test "rowsAt: a full-width row counts physical rows without overflowing" {
    const gpa = std.testing.allocator;
    var tape: std.ArrayList(u16) = .empty;
    defer tape.deinit(gpa);
    // The widest row a u16 column count can name: 65535 painted
    // columns with a wide lead at each end. Capturing it from a real
    // grid would build the same record over a megabyte of cells.
    try tape.appendSlice(gpa, &.{ 0, std.math.maxInt(u16) - 2 });
    const fp: Buffer.RowFootprint = .{
        .columns = std.math.maxInt(u16),
        .wide_start = 0,
        .wide_count = 2,
    };
    try std.testing.expectEqual(@as(u32, 1), fp.rowsAt(tape.items, std.math.maxInt(u16)));
    // Two columns per chunk whatever the glyph is.
    try std.testing.expectEqual(@as(u32, 32768), fp.rowsAt(tape.items, 2));
    try std.testing.expectEqual(@as(u32, 32768), fp.rowsAt(tape.items, 0));

    const first = fp.prefixRows(tape.items, 2, 1);
    try std.testing.expectEqual(@as(u16, 2), first.columns);
    try std.testing.expectEqual(@as(usize, 1), first.wide_count);
    try std.testing.expectEqual(fp.columns, fp.prefixRows(tape.items, 2, 32768).columns);
    try std.testing.expectEqual(fp.wide_count, fp.prefixRows(tape.items, 2, 99_999).wide_count);
}

test "rowFootprint: the captured end is where the frame stops painting" {
    const gpa = std.testing.allocator;
    const red: Style = .{ .fg = .{ .ansi = .red } };
    var buf = try Buffer.init(gpa, 9, 1);
    defer buf.deinit();
    _ = try buf.draw(Style{}, "ab", 0, 0);
    _ = try buf.draw(Style{}, "界x", 4, 0);
    // A blank gap the renderer skips with a cursor move, and a styled
    // blank after the glyphs that it emits.
    _ = try buf.draw(red, " ", 7, 0);
    var tape: std.ArrayList(u16) = .empty;
    defer tape.deinit(gpa);
    var null_gaps: std.ArrayList(Buffer.RowFootprint.NullGap) = .empty;
    defer null_gaps.deinit(gpa);
    const fp = try buf.rowFootprint(gpa, 0, &tape, &null_gaps);
    try std.testing.expectEqual(@as(u16, 8), fp.columns);
    try std.testing.expectEqualSlices(u16, &.{4}, tape.items);

    // Replaying the frame leaves the cursor just past the last painted
    // cell. Capture and renderer must agree on that column, or a reflow
    // would be measured against geometry nobody ever painted.
    var t: TestWriter = .{};
    t.init();
    try buf.renderAll(&t.w);
    var model = try FrameModel.init(gpa, &buf, t.w.buffered());
    defer model.deinit(gpa);
    try model.replay();
    try std.testing.expectEqual(@as(usize, 8), model.col);
}

test "rowFootprint: removing a suffix distinguishes null gaps from printed spaces" {
    const gpa = std.testing.allocator;
    var buf = try Buffer.init(gpa, 130, 2);
    defer buf.deinit();
    _ = try buf.draw(.{}, "a" ** 100 ++ "界", 0, 0);
    _ = try buf.draw(.{}, "界", 100, 1);
    var tape: std.ArrayList(u16) = .empty;
    defer tape.deinit(gpa);
    var null_gaps: std.ArrayList(Buffer.RowFootprint.NullGap) = .empty;
    defer null_gaps.deinit(gpa);

    const dense = try buf.rowFootprint(gpa, 0, &tape, &null_gaps);
    const sparse = try buf.rowFootprint(gpa, 1, &tape, &null_gaps);
    var dense_prefix = dense.prefixRows(tape.items, 55, 1);
    var sparse_prefix = sparse.prefixRows(tape.items, 55, 1);
    dense_prefix.columns = dense_prefix.paintedPrefixColumns(null_gaps.items, 55);
    sparse_prefix.columns = sparse_prefix.paintedPrefixColumns(null_gaps.items, 55);
    try std.testing.expectEqual(@as(u32, 19), dense_prefix.rowsAt(tape.items, 3));
    try std.testing.expectEqual(@as(u32, 1), sparse_prefix.rowsAt(tape.items, 3));

    _ = try buf.draw(.{ .bg = .{ .ansi = .blue } }, " ", 20, 1);
    const painted_space = try buf.rowFootprint(gpa, 1, &tape, &null_gaps);
    try std.testing.expectEqual(
        @as(u16, 21),
        painted_space.paintedPrefixColumns(null_gaps.items, 55),
    );
    try std.testing.expectEqual(
        @as(u16, 0),
        painted_space.paintedPrefixColumns(null_gaps.items, 20),
    );
}

test "rowFootprint: the eight-cell walk records what a cell-by-cell walk records" {
    // Rows mixing blanks, styled blanks, empty graphemes, narrow ASCII,
    // borrowed narrow text and wide glyphs (some cut by the right edge),
    // at widths around the eight-cell step. The reference is the plain
    // per-cell rule over decoded cells.
    const gpa = std.testing.allocator;
    const red: Style = .{ .fg = .{ .ansi = .red } };
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();
    var tape: std.ArrayList(u16) = .empty;
    defer tape.deinit(gpa);
    var gaps: std.ArrayList(Buffer.RowFootprint.NullGap) = .empty;
    defer gaps.deinit(gpa);
    var want_tape: std.ArrayList(u16) = .empty;
    defer want_tape.deinit(gpa);
    var want_gaps: std.ArrayList(Buffer.RowFootprint.NullGap) = .empty;
    defer want_gaps.deinit(gpa);
    for (1..41) |width| for (0..20) |_| {
        var buf = try Buffer.init(gpa, @intCast(width), 1);
        defer buf.deinit();
        for (0..width) |x| {
            const ux: u16 = @intCast(x);
            switch (rand.uintLessThan(u8, 8)) {
                0, 1 => {}, // default blank
                2 => try buf.set(ux, 0, .{ .grapheme = " ", .style = red }),
                3 => try buf.set(ux, 0, .{ .grapheme = "" }),
                4, 5 => _ = try buf.draw(Style{}, "a", ux, 0),
                6 => try buf.set(ux, 0, .{ .grapheme = "é" }),
                else => try buf.set(ux, 0, .{ .grapheme = "界" }),
            }
        }
        tape.clearRetainingCapacity();
        gaps.clearRetainingCapacity();
        const got = try buf.rowFootprint(gpa, 0, &tape, &gaps);

        want_tape.clearRetainingCapacity();
        want_gaps.clearRetainingCapacity();
        var x: usize = 0;
        var end: usize = 0;
        while (x < width) {
            const cell = buf.get(@intCast(x), 0);
            if (cell.wide or cell.grapheme.len == 0 or cell.eql(.{})) {
                x += 1;
                continue;
            }
            const wcell: usize = if (Width.graphemeWidth(cell.grapheme) >= 2) 2 else 1;
            if (x + wcell > width) {
                x += 1;
                continue;
            }
            if (wcell == 2) try want_tape.append(gpa, @intCast(x));
            if (x > end) try want_gaps.append(gpa, .{ .start = @intCast(end), .end = @intCast(x) });
            x += wcell;
            end = x;
        }
        try std.testing.expectEqual(@as(u16, @intCast(end)), got.columns);
        try std.testing.expectEqualSlices(u16, want_tape.items, tape.items);
        try std.testing.expectEqualSlices(
            Buffer.RowFootprint.NullGap,
            want_gaps.items,
            gaps.items,
        );
    };
}

test "rowFootprint: gap allocation failure restores both tapes for retry" {
    const gpa = std.testing.allocator;
    const NullGap = Buffer.RowFootprint.NullGap;
    var buf = try Buffer.init(gpa, 12, 1);
    defer buf.deinit();
    _ = try buf.draw(.{}, "界", 0, 0);
    _ = try buf.draw(.{}, "x", 5, 0);
    _ = try buf.draw(.{}, "y", 9, 0);
    var tape: std.ArrayList(u16) = try .initCapacity(gpa, 2);
    defer tape.deinit(gpa);
    try tape.append(gpa, 99);
    var null_gaps: std.ArrayList(NullGap) = try .initCapacity(gpa, 2);
    defer null_gaps.deinit(gpa);
    const sentinel: NullGap = .{ .start = 10, .end = 11 };
    try null_gaps.append(gpa, sentinel);
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    failing.resize_fail_index = 0;

    try std.testing.expectError(
        error.OutOfMemory,
        buf.rowFootprint(failing.allocator(), 0, &tape, &null_gaps),
    );
    try std.testing.expectEqualSlices(u16, &.{99}, tape.items);
    try std.testing.expectEqual(@as(usize, 1), null_gaps.items.len);
    try std.testing.expectEqualDeep(sentinel, null_gaps.items[0]);

    const fp = try buf.rowFootprint(gpa, 0, &tape, &null_gaps);
    try std.testing.expectEqual(@as(u16, 6), fp.paintedPrefixColumns(null_gaps.items, 8));
    try std.testing.expectEqualSlices(u16, &.{ 99, 0 }, tape.items);
    try std.testing.expectEqualDeep(sentinel, null_gaps.items[0]);
}

test "Buffer.draw: codepoint ZWJ sequence occupies four cells before following text" {
    Width.setMode(.codepoint);
    defer Width.setMode(.grapheme);
    var buf = try Buffer.init(std.testing.allocator, 12, 1);
    defer buf.deinit();
    try std.testing.expectEqual(@as(u16, 12), try buf.draw(.{}, "👩‍💻 aligned", 0, 0));
    try std.testing.expectEqualStrings("👩‍", buf.get(0, 0).grapheme);
    try std.testing.expect(buf.get(1, 0).wide);
    try std.testing.expectEqualStrings("💻", buf.get(2, 0).grapheme);
    try std.testing.expect(buf.get(3, 0).wide);
    try std.testing.expectEqualStrings(" ", buf.get(4, 0).grapheme);
    try std.testing.expectEqualStrings("a", buf.get(5, 0).grapheme);
    try std.testing.expectEqualStrings("d", buf.get(11, 0).grapheme);
}

test "Buffer.set: codepoint mode splits a supplied Unicode grapheme into cells" {
    Width.setMode(.codepoint);
    defer Width.setMode(.grapheme);
    var buf = try Buffer.init(std.testing.allocator, 5, 1);
    defer buf.deinit();
    try buf.set(0, 0, .{ .grapheme = "👩‍💻" });
    try buf.set(4, 0, .{ .grapheme = "x" });
    try std.testing.expectEqualStrings("👩‍", buf.get(0, 0).grapheme);
    try std.testing.expect(buf.get(1, 0).wide);
    try std.testing.expectEqualStrings("💻", buf.get(2, 0).grapheme);
    try std.testing.expect(buf.get(3, 0).wide);
    try std.testing.expectEqualStrings("x", buf.get(4, 0).grapheme);
}
