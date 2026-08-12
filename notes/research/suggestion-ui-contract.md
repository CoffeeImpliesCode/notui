# TUI-side inline-suggestion contract (Round 1, C1)

Two parallel contracts feed the skript REPL inline-autocomplete feature.
**This file is C1 (TUI side)**: the infra notui needs to render a
completion-candidate popup directly below the input cursor. The REPL-side
contract is C2 (`notes/research/repl-suggestions-contract.md`, written in
parallel). This is the implementer's spec: read ONLY this file plus the
notui source it cites. It is self-contained — no codebase archaeology
required.

The feature: while the user types a symbol in the REPL, a list of candidate
completions appears in rows directly below the input line, aligned under the
cursor column, navigable with ↑/↓ (Tab accepts, Esc dismisses). Two infra
pieces are needed:

1. **`Region.setHeight`** — grow/shrink the region's band height *without*
   the full width-clear churn of `Region.resize`.
2. **`Suggestions`** — a base-ui component that draws a selectable candidate
   list below a point.

Scope guard: this is a popup list + a height knob, NOT a layout system. No
overlay, no layout engine, no focus tree, no input handling.

---

## 1. `Region.setHeight(new_height)`

### 1.1 Goal

`Region.resize` (src/region.zig:141-150) currently reallocs both buffers to
a new width+height, sets `width_dirty = true`, and the next frame runs
strategy 2: `ESC[J` from the anchor + a full re-render of every row
(src/region.zig:212-222). That full-width clear is the "churn" we must avoid
for a height-only change: the popup appears/disappears repeatedly and a
width-clear each time would visibly flash the whole band.

`setHeight` is a **height-only** variant of `resize`:

- reallocs `cur`/`prev` to `(self.width, new_height)` keeping the width
  unchanged (`Buffer.resize`, src/buffer.zig:45-65 — overlap copied row by
  row, new area empty);
- does **NOT** set `width_dirty` (no `ESC[J` width-clear);
- sets a `height_dirty` flag the next render uses to reserve-then-diff on
  grow and erase-the-tail + correct-the-anchor on shrink.

### 1.2 The exact fn

```zig
// src/region.zig — add to the Region struct.
/// Height-only resize. Reallocs both buffers to `new_height` keeping the
/// current width, and marks the next frame for a height change. Unlike
/// `resize`, does NOT set `width_dirty`: the width is unchanged, so there
/// is no `ESC[J` width-clear. Growth reserves the extra rows below the band
/// (CNL) and paints them via the normal diff (they are empty in `prev`);
/// shrink erases the removed tail rows and corrects the anchor (see the
/// `height_dirty` strategy in render). No-op when `new_height` is the
/// current height. Call this OR `resize` in a frame gap — not both.
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
    if (new_height > old_height) self.anchor_row +|= new_height - old_height
    else self.anchor_row -|= old_height - new_height;
    // On grow the diff will paint the new rows (they are empty in prev);
    // raise the high-water mark so a later shrink erases them correctly.
    if (new_height > old_height) self.high_water = new_height;
}
```

New fields:

```zig
/// A height-only change is pending (the height_dirty strategy is due).
height_dirty: bool = false,
/// Rows added by the last setHeight (0 unless growing); reserved + diffed
/// on the next frame.
grow_rows: u16 = 0,
/// Rows removed by the last setHeight (0 unless shrinking); erased on the
/// next frame.
shrink_rows: u16 = 0,
```

`init` (src/region.zig:118-139) gains the three zero-initialized fields.

### 1.3 Why grow needs no erase but DOES need a reservation

- **Grow** (`new > old`): `Buffer.resize` grows `prev` too, so prev's new
  bottom rows are empty `Cell{}`. The next frame's `scanChanges`
  (src/region.zig:426-437) loops `0..cur.height` and sees those rows differ
  (cur has suggestion text, prev is empty) → returns a `RowRange` covering
  them → the normal strategy-3 diff paints them (they are empty in prev, so
  the requirement "new bottom rows paint via the normal diff" holds).
- **BUT** the extra rows extend BELOW the band the terminal reserved on the
  first render (CNL, src/region.zig:246-250). Writing them without reserving
  would push the band into scrollback — the same failure the region's width
  strategy 2 guards against (src/region.zig:34-37). So grow must first emit
  `emit.appendLines(w, grow_rows)` (CNL, src/emit.zig:69-71) to extend the
  reservation, THEN diff-paint. This mirrors `paintFirst`'s reservation
  (src/region.zig:246-249).
- After `appendLines(grow)` from the old band bottom (row `old-1`), the
  cursor lands at row `new-1` (new band bottom); `renderDiffFrame`'s
  `moveToBandTop` (CUU `new-1`, src/region.zig:418-423) then climbs to row 0
  correctly.

### 1.4 Why shrink cannot reuse strategy 3 as-is

Two problems on shrink (`new < old`):

1. **The anchor is wrong.** After the previous frame the cursor sits at the
   OLD band bottom (row `old-1`). The next `moveToBandTop` uses the NEW
   height (`\r` + CUU `new-1`), which from row `old-1` lands at row
   `old-new` (≥ 1), NOT the band top. The diff's relative row arithmetic
   (`renderDiff`'s `y - cur_row`, src/buffer.zig:196-214) would underflow.
2. **The removed rows are never revisited.** `cur`/`prev` were realloc'd to
   `new` rows; rows `[new..old)` no longer exist in either buffer, so no
   diff row covers them. Their stale bytes stay on screen.

### 1.5 The `height_dirty` strategy in render

Insert a new branch in `render` (src/region.zig:186-235) between the
`first_frame` branch and the `flush` branch, and extend the `changed` gate
to include `height_dirty`:

```zig
const changed = self.first_frame or self.width_dirty or
    self.height_dirty or flush or (diff != null);
```

`height_dirty` MUST be in `changed`: a shrink that only removes blank tail
rows (no `[0..new)` row changed) yields `diff == null`, but the removed rows
still need erasing — the frame must not early-return (src/region.zig:198).

Strategy dispatch — insert after the `first_frame` block (which must clear
the three new flags: `height_dirty = false; grow_rows = 0; shrink_rows = 0;`
— on the first render nothing is on screen, `paintFirst` already appends the
new `self.height` rows):

```zig
} else if (self.height_dirty) {
    // Strategy "height": a height-only change. No width-clear.
    self.height_dirty = false;
    const grow = self.grow_rows;
    const shrink = self.shrink_rows;
    self.grow_rows = 0;
    self.shrink_rows = 0;

    if (grow > 0) {
        // Reserve the extra rows below the band, then paint them via the
        // normal diff (they are empty in prev). Cursor: old bottom -> new
        // bottom after CNL; moveToBandTop (CUU new-1) climbs to row 0.
        if (self.opts.append_lines) try emit.appendLines(w, grow);
        self.high_water = self.height;
    } else {
        // Shrink. The cursor sits at the OLD band bottom (row `shrink`
        // below the new bottom) and the removed rows [new..old) are still
        // on screen. Move up to the first REMOVED row (`new`), ESC[J from
        // there wipes rows [new..] (preserving rows 0..new-1 — the new
        // band), then climb back to the new band bottom so the diff below
        // starts at the correct anchor.
        try w.writeAll("\r");
        if (shrink > 1) try w.print("\x1b[{d}A", .{shrink - 1}); // old-1 -> new
        try emit.eraseToEnd(w);                                   // wipe [new..]
        try w.writeAll("\r");
        try w.writeAll("\x1b[1A");                                 // new -> new-1
        self.high_water = self.height;
    }

    // The band rows [0..new) are unchanged in content (grow keeps them;
    // shrink's ESC[J erased only the removed tail), so diff the changed
    // rows against prev. renderDiffFrame re-establishes the anchor
    // (moveToBandTop) and returns the cursor to the band bottom.
    if (diff) |ch| {
        try self.renderDiffFrame(w, ch);
    } else {
        // Reserve/erase-only frame (no row changed): return to the new
        // band bottom.
        try w.writeAll("\r");
        var rest = self.height - 1;
        while (rest > 0) : (rest -= 1) try w.writeByte('\n');
    }
}
```

Mechanism notes (grounded in the source):

- `emit.appendLines(w, n)` is CNL `ESC[n E`, emits nothing for `n == 0`
  (src/emit.zig:69-71). `emit.eraseToEnd(w)` is `ESC[J`, the same "bounded
  below the anchor, never above" clear strategy 2 already uses
  (src/region.zig:212-222, src/emit.zig:57-60). `emit.eraseLine` is `ESC[K`
  (src/emit.zig:62-65).
- **`renderDiffFrame` (src/region.zig:329-363) does the actual tail
  work-free diff**: after our pre-step the cursor is at the new band bottom,
  so `renderDiffFrame`'s `moveToBandTop` (CUU `new-1`, src/region.zig:418-423)
  lands exactly on row 0; `cur.renderDiff(&prev, w)` (src/buffer.zig:186-216)
  erases-and-rewrites only changed rows in `[0..new)`. Its internal high-water
  tail-erase (src/region.zig:341-357) is a no-op because we set
  `high_water = self.height`.
- **Shrink erase choice**: `ESC[J` from the first removed row (`new`) wipes
  exactly `[new..)`, preserving the new band's last row (`new-1`, the status
  line). Using `ESC[J` from row `new-1` (the requirement's "from the new last
  row" phrasing) would also wipe the status row; we intentionally start one
  row lower so an unchanged status row survives without a repaint. This is
  consistent with strategy 2's existing use of `ESC[J` (the region already
  assumes it owns down to the screen end / nothing meaningful below).
- **`first_frame` interaction**: `setHeight` before the first render just
  changes `opts.height`'s effective value; `paintFirst` appends `self.height`
  rows (src/region.zig:236-265). The flags are cleared in the first_frame
  branch; no reservation/erase runs (nothing on screen).
- **`flush`/`width_dirty` interaction**: the spec forbids calling `setHeight`
  and `resize` in the same frame gap (§1.6), so `height_dirty` and
  `width_dirty` do not coexist in practice. If the app calls `setHeight`
  while appends are queued, the appends flush on the *following* frame (the
  height branch doesn't drain `append_queue`); the queue persists and the
  flush branch then runs with the corrected geometry. This one-frame deferral
  is acceptable for the popup use case (see open Q2).

### 1.6 `resize` stays for real width changes

`Region.resize` (src/region.zig:141-150) is UNCHANGED: it still sets
`width_dirty`, and the next frame does `ESC[J` + full repaint. `setHeight`
is the narrow height-only path. The REPL uses `resize` on terminal
width/height changes and `setHeight` for popup show/hide; it never calls both
in one gap. This keeps the two strategies disjoint and simple.

---

## 2. `Suggestions` component

### 2.1 Where it lives

- New file `src/component/suggestions.zig`.
- Register in `src/component/root.zig` (src/component/root.zig:15-23 pattern):
  `pub const Suggestions = @import("suggestions.zig").Suggestions;`.

### 2.2 The exact Zig shape

Follows the v1 base-ui contract (baseui-contract.md §3): a plain stateful
struct with `draw`/`advance`, width-aware, zero-alloc draw via a caller-owned
`scratch` (the borrow model, mirroring `Text`, src/component/text.zig). The
selection/scrolling model is lifted from zigzag `list.zig`
(`ensureVisible`, list.zig:341-344; the cursor window in `view`,
list.zig:378-411) — stolen for the SELECTION/SCROLL semantics, NOT the layout
(notui has no overlay/layout).

```zig
// src/component/suggestions.zig
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
```

Notes on the shape:

- **`draw` takes `alloc`** (like `Text.draw`, src/component/text.zig:61) —
  truncation needs the allocator that owns `scratch`. This is the one
  deliberate deviation from the v1 `draw(buf, x, y, now)` template
  (baseui-contract.md §3); Text already established the `alloc`-first
  precedent.
- **Return value = rows used** (the popup height), NOT columns — a list has
  no meaningful "widest consumed" column and the caller needs the row count
  to size the band (C2: `band_height = 2 + rows_used`).
- **Zero-alloc**: when every visible candidate fits `avail`, `scratch`
  allocates (to hold the copies) but nothing beyond the caller allocator;
  a `FailingAllocator` guard asserts no allocation outside `scratch`'s own
  growth (test §4.2).
- **Selection highlight** = `selected_style` (default `.attrs.reverse` —
  src/style.zig:17-25 packed `Attrs` with `reverse`). The app can override
  to a colored style. The whole selected ROW is styled, not just a marker.
- **Scroll window** = the zigzag `ensureVisible` rule (list.zig:341-344):
  if `selected < start` → `start = selected`; else if `selected >= start +
  max_rows` → `start = selected - max_rows + 1`. `windowStart` folds that
  into a deterministic local (no stored `y_offset`, so it can't drift from
  app-set `selected`).
- **No `prefix`/`x_offset` field**: alignment-under-cursor is the CALLER's
  job (it computes the clamped `x`, §3). The component draws at exactly the
  `(x, y)` it is given.

---

## 3. Alignment-under-cursor rule

The popup aligns under the cursor column, clamped into the band:

```zig
// REPL side (C2 owns the exact formula; this is the contract C1 defines).
const popup_x: u16 = @min(cursor_col, buf.width);
const rows = try suggestions.draw(alloc, &region.cur, popup_x, 1, now);
```

- `cursor_col` is the completion anchor column (the skript popup already
  computes `px = 1 + anchor.col`, src/repl.zig:852-860 — same idea, minus the
  `1` box-border offset; notui has no border box).
- `@min(cursor_col, buf.width)` ensures the popup never starts past the right
  edge. If `popup_x == buf.width`, `avail == 0` and `draw` returns 0 (draws
  nothing) — the empty-past-edge case degrades gracefully.
- The component truncates each row to `avail = buf.width -| popup_x`
  (§2.2), so rows never overflow the band. Rows shorter than the candidate
  leave a blank tail (Buffer.draw writes only the glyphs; the region diff's
  erase + writeRow blanks the rest, src/buffer.zig:141-146).

C2's assumed 2-row band grows to `2 + rows` when suggestions are active:
row 0 = input, rows 1..=rows = suggestions at `popup_x`, row `rows+1` = status
(moved down); on dismiss `setHeight(2)` shrinks back.

---

## 4. Test requirements

Follow the existing golden pattern (fixed `TestWriter`, `renderAll`/region
goldens; synthetic `now` via `std.Io.Timestamp.fromNanoseconds`). Each file
ends with `test { std.testing.refAllDecls(@This()); }`.

### 4.1 Region `setHeight` (add to src/region.zig test section)

1. **Grow paints new rows via the diff, no width-clear.** Height 2, first
   frame (input+status), then `setHeight(4)` + draw two suggestion rows;
   next render emits the CNL reservation (`\x1b[2E`) + a DIFF of rows 2-3
   (erase + cells) and NO `\x1b[J` anywhere. Assert `grow` runs strategy 3,
   not strategy 2.
2. **Shrink erases the tail.** Height 5 (input + 3 suggestions + status),
   `setHeight(2)` + redraw status; next render emits the shrink pre-step
   (`\r` + CUU + `\x1b[J` + `\r\x1b[1A`) then a diff of the changed status
   row. Assert the removed rows are erased (the `\x1b[J`) and the new band
   top is re-established (CUU uses the NEW height).
3. **No width-clear when width unchanged.** Both grow and shrink frames
   above contain no `\x1b[J` from strategy 2 (the only `\x1b[J` on shrink is
   the tail-erase, which is intended and distinct).
4. **Width-clear still happens on a real width change.** `resize(40, 3)`
   still sets `width_dirty` → strategy 2 → `\x1b[J` + full repaint
   (regression guard on src/region.zig:212-222).
5. **Grow-then-shrink round-trip.** Height 2 → 5 → 2; after the final shrink
   the screen equals the 2-row band (no stale suggestion rows), and a
   follow-up idle frame emits nothing.
6. **`setHeight` same height is a no-op.** No flags set, next frame idle.

### 4.2 `Suggestions` (add to src/component/suggestions.zig test section)

1. **Selection highlight.** `candidates = {"a","b","c"}`, `selected = 1`;
   row 1 (at y+1) drawn with `selected_style` (reverse), rows 0,2 with
   `style`. Assert cell styles via `buf.get(...).style`.
2. **Truncation.** A candidate wider than `avail` is cut at a grapheme
   boundary with the "…" marker (`Width.truncate` semantics, src/width.zig:54-87);
   an over-wide leading grapheme yields just "…".
3. **Scroll window.** `candidates.len = 12`, `max_rows = 5`, `selected = 9`
   → `windowStart == 5`, rows 5..9 drawn, row 9 highlighted.
4. **Alignment clamp.** `x` near `buf.width`; rows truncated to `avail =
   buf.width -| x`; no cell past `buf.width` (Buffer.draw already guards,
   src/buffer.zig:141-146 — assert no out-of-bounds and the row content).
5. **Return value.** Returns `min(candidates.len, max_rows)` (the popup
   height) when candidates exist, 0 when empty.
6. **Zero-alloc guard.** `FailingAllocator` (fail_index 0): draw only
   allocates through `scratch`; a draw that never truncates succeeds; one
   that truncates fails at the expected OOM only through the caller allocator
   (the Text pattern, src/component/text.zig:262-273).

---

## 5. Open questions for the orchestrator (max 3)

1. **Band bottom assumption.** Strategy 2 already emits `ESC[J` from the band
   top (src/region.zig:212-222), and the new shrink tail-erase emits `ESC[J`
   from the first removed row — both assume the region owns (or nothing
   meaningful sits) below the band. Is the REPL band bottom-anchored in the
   terminal, so `ESC[J` never wipes unrelated content below? If not, the
   shrink should switch to per-row `eraseLine` (the alternative the
   requirement allows), which adds a cursor-walk-back but stays self-scoped.
2. **One-shot vs incremental growth.** Is `setHeight` called with the final
   `2+N` height in one shot when the popup opens (assumed), or once per
   candidate row? One-shot keeps the CNL reservation + diff on a single
   frame; incremental re-reserves per row and would visibly step.
3. **Zero-candidate popup frame.** When the popup is logically open but the
   filtered candidate list is empty, should the band grow to draw an empty
   popup box (a blank `max_rows` block), or is "zero candidates" exactly
   "dismiss / shrink to 2" (assumed)? This decides whether `Suggestions`
   needs an `always_show`/`show_empty` knob.
