# base-ui improvements contract (round 2)

Focused round on the base-ui layer (`src/component/*`, shipped in round 1 per
`notes/research/baseui-contract.md`). The v1 layer shipped `Spinner`, `Text`,
`AnimatedText`, `Progress` (src/component/{component,spinner,text,
animated_text,progress,root}.zig). This round ADDS two components that v1
explicitly deferred — **StatusBar** (multi-segment left/center/right line) and
**Gauge** (fractional block-bar with thresholds) — plus two cheap
improvements to v1 components. It also migrates the hand-rolled
`examples/statusline.zig` onto the layer to dogfood StatusBar + Gauge + Text.

This is the implementer's spec. Read ONLY this file plus the notui source
(`src/component/*`, `src/buffer.zig`, `src/style.zig`, `src/color.zig`,
`src/width.zig`, `src/region.zig`, `examples/statusline.zig`, `build.zig`).
Keep it SIMPLE — a thin presentation layer, not a framework.

---

## 1. Gap list vs v1

| # | Gap | Why it exists now | v1 status |
|---|---|---|---|
| G1 | **No StatusBar component.** The statusline example hand-rolls left-aligned styled segments + a right-aligned tail with raw `Buffer.draw` and a manual `Palette` (examples/statusline.zig `buildFrame`). v1 deferred StatusBar (`baseui-contract.md:76-78`). | Round-2 dogfood mandate: the example SHOULD migrate to a real component, and every reference ships one (zigzag `status_bar.zig:30-32` left/center/right `Segment` lists). | deferred in v1 → **IN this round** |
| G2 | **No Gauge component.** v1 `Progress` draws integer `█`/`░` cells only; smooth fractional fill and threshold colors were marked nice-to-have (`baseui-contract.md:78-80`). | zigzag `gauge.zig:200-214` fractional block chars (▏▎▍▌▋▊▉) give a smooth meter; `activeColor` thresholds (`gauge.zig:125-131`) are the standard meter pattern. | deferred in v1 → **IN this round** |
| G3 | **No text alignment.** `Text` draws left-aligned only (src/component/text.zig). Right/center alignment is a common standalone need and is currently app-side (`buildFrame` hand-rolls the right-aligned tail). | Cheap: reuses the existing `fit`+`avail` math; one `enum` field. | absent → **IN this round** |
| G4 | **No Progress label.** `Progress` has a percent suffix but no prefix label (src/component/progress.zig). | Cheap prefix + space; mirrors the label every reference bar carries (zigzag gauge.zig label). | absent → **IN this round** |
| G5 | **No dogfood.** No example uses the v1 components (`examples/spinner.zig`, `prompt.zig`, `statusline.zig` all hand-roll). | Round-2 goal: prove the layer replaces hand-rolled code. | absent → **IN this round** (statusline migration, §4) |
| — | Spinner fps config | Already covered: `Spinner.interval` IS the ms/frame knob (src/component/spinner.zig:21-22). No `fps` field needed. | **no change** |
| — | AnimatedText marquee | Grapheme-safe windowing (skip N leading columns) needs a new `width` primitive or grapheme iterator; components must import only buffer/style/color/width (root.zig:5-8). Not cheap. | **OUT** (§3) |

---

## 2. Per-component spec

### 2.1 `StatusBar` — NEW

```zig
// src/component/status_bar.zig
pub const StatusBar = struct {
    /// Left/center/right segment groups, BORROWED (never freed, never
    /// allocated) — the app rebuilds or mutates them each frame.
    left: []const Segment = &.{},
    center: []const Segment = &.{},
    right: []const Segment = &.{},
    /// Drawn between consecutive segments WITHIN a group; null = none.
    separator: ?[]const u8 = " ",
    /// Style for separator and inter-group gap cells.
    gap_style: Style = .{},
    /// Caller-owned scratch for truncation output (the borrow model,
    /// same as Text.scratch, src/component/text.zig:19-20).
    scratch: *std.ArrayList(u8) = &default_scratch,

    pub const Segment = struct {
        text: []const u8,
        style: Style = .{},
    };

    pub fn advance(self: *StatusBar, now: Clock) bool; // always false (static)
    pub fn draw(self: *StatusBar, buf: *Buffer, x: u16, y: u16, now: Clock) !u16;
};
```

- File: `src/component/status_bar.zig`. Register in `src/component/root.zig`
  (add `pub const StatusBar = @import("status_bar.zig").StatusBar;`).
- `draw` shape matches the v1 contract (`draw(buf,x,y,now) !u16`,
  baseui-contract.md §3). `now` ignored (static); `advance` returns `false`.
- **Alignment** (port of zigzag `status_bar.zig` `view()` layout, but drawn
  into cells and made truncation-safe):
  1. `avail = buf.width -| x`; if `avail == 0 or y >= buf.height` return 0.
  2. `lw`/`cw`/`rw` = display widths of the joined left/center/right groups
     (segments joined by `separator`; width via `width.strWidth`).
  3. **Left first (highest priority, kept whole):** if `lw >= avail`,
     truncate LEFT to `avail`, draw at `(x, y)`, return `avail` (center and
     right dropped).
  4. **Right** (anchored to the right edge): `right_used = min(rw, avail - lw)`.
     Draw right truncated to `right_used`, right-aligned ending at
     `x + avail` (i.e. start = `x + avail - right_used`).
  5. **Center** (floats between left and right): `middle = avail - lw - right_used`.
     `cw_used = min(cw, middle)`; if `cw_used == 0` nothing; else start at
     `x + lw + (middle - cw_used)/2`; when `cw > middle` truncate to `middle`.
  6. Left group drawn at `x` (whole). Blank cells between groups are left
     empty. Return `avail` (a StatusBar consumes the full line).
- **Within-group truncation rule** (deterministic, simple): drop trailing
  segments first; the last surviving segment is ellipsized via
  `Width.truncate` (src/width.zig:54) into `scratch` + "…" (the v1 Text
  ellipsis pattern, src/component/text.zig `appendFit`). This favors the
  leading segments of each group — acceptable for v1; noted in caveats.
- **Separator**: drawn with `gap_style` before each segment when `i > 0` and
  `separator != null`. Separators are width-accounted and skipped when they
  would overflow the remaining budget.
- **No allocation during draw**: truncation writes to `scratch` only; cells
  borrow from `scratch` (same lifetime rule as Text). `default_scratch` is a
  module `var std.ArrayList(u8) = .empty` like Text (src/component/text.zig:13-14).

### 2.2 `Gauge` — NEW

```zig
// src/component/gauge.zig
pub const Gauge = struct {
    value: f64 = 0,
    min: f64 = 0,
    max: f64 = 100,
    /// Bar length in cells.
    width: u16 = 40,
    /// Optional prefix "label " before the bar (styled with label_style).
    label: ?[]const u8 = null,
    label_style: Style = .{},
    /// Draw a " 42%" suffix after the bar.
    show_percent: bool = true,
    percent_style: ?Style = null, // null => default Style
    full_style: Style = .{ .fg = .{ .ansi = .green } },
    empty_style: Style = .{ .fg = .{ .ansi256 = 245 } },
    /// Thresholds: the LAST with value <= self.value wins (gauge.zig:125-131).
    thresholds: []const Threshold = &.{},
    /// When both set, per-cell fill gradient (overrides threshold fg).
    gradient_a: ?Color = null,
    gradient_b: ?Color = null,
    /// Scratch for the percent suffix (cells borrow it), like Progress.
    percent_buf: [8]u8 = undefined,

    pub const Threshold = struct { value: f64, color: Color };

    /// Fractional block fill chars, least to most filled (zigzag
    /// gauge.zig:200-214): index i = (i+1)/8 of a full cell.
    pub const blocks = [_][]const u8{ "▏", "▎", "▍", "▌", "▋", "▊", "▉" };

    pub fn advance(self: *Gauge, now: Clock) bool; // always false (static)
    pub fn ratio(self: *const Gauge) f64;          // clamp01((value-min)/(max-min)); max<=min => 0
    pub fn draw(self: *Gauge, buf: *Buffer, x: u16, y: u16, now: Clock) !u16;
};
```

- File: `src/component/gauge.zig`. Register in `src/component/root.zig`.
- **Fill model** — `ratio()` clamps to 0..1 (`max - min <= 0` → 0, the zigzag
  `ratio`, gauge.zig:118-123). `total_units = width * 8`;
  `filled_units = round(ratio * total_units)`; `full_cells = filled_units / 8`;
  `partial = filled_units % 8`. Per column:
  - `col < full_cells` → `"█"` (full), fill style.
  - `col == full_cells and partial > 0` → `blocks[partial - 1]` (fractional
    partial cell), fill style. A full-width cell never uses a partial block
    (the full char covers it).
  - else → `empty_char` ("░"), empty style.
- **Threshold color**: `var fill = self.full_style; for (self.thresholds) |t|
  { if (self.value >= t.value) fill.fg = t.color; }` — last match wins
  (gauge.zig:125-131). Gradient, when both `gradient_a`/`gradient_b` set,
  overrides `fill.fg` per filled cell via `Color.interpolate`
  (src/color.zig:155), same t-map as Progress (src/component/progress.zig).
- **Label**: if set, draw `label` with `label_style` then one space at
  `(x, y)`; advance consumed.
- **Percent suffix**: if `show_percent`, draw `" {d:.0}%"` (`ratio * 100`)
  formatted into `percent_buf` (cells borrow it; never move the component
  between draw and render — same rule as Progress.percent_buf). Style =
  `percent_style orelse .{}`. Truncated to avail by `Buffer.draw`.
- `advance` returns `false` (static). Add `setValue`/`setMin`/`setMax`/
  `setWidth` helpers clamped like Progress (src/component/progress.zig) —
  `setValue` clamps to `[min, max]` (gauge.zig:118-123).

### 2.3 `Text` — add `align`

```zig
// src/component/text.zig (edit)
pub const Text = struct {
    // ...existing fields...
    /// Horizontal alignment within the available width (single-line mode).
    align: enum { left, center, right } = .left,
};
```

- After `fit` resolves the display string `s` (width `w`, already truncated
  to `avail`), when `!wrap` and `align != .left`:
  `x0 = x + (switch (align) { .center => (avail - w) / 2, .right => avail - w,
  .left => 0 })`. `w <= avail` by construction, so no underflow. Draw at
  `(x0, y)`; return `w` (consumed columns unchanged). Wrap mode ignores
  `align`.
- Default `.left` preserves existing behavior; no test churn.

### 2.4 `Progress` — add `label`

```zig
// src/component/progress.zig (edit)
pub const Progress = struct {
    // ...existing fields...
    /// Optional prefix "label " before the bar.
    label: ?[]const u8 = null,
    label_style: Style = .{},
};
```

- In `draw`, before the bar: if `label` set, draw `label` with `label_style`
  then one space at `(x, y)`, add to `consumed`. Bar and percent suffix
  unchanged. Cheap symmetry with Gauge.

---

## 3. OUT (one-line reasons)

- **AnimatedText marquee** — grapheme-safe leading-column windowing needs a
  new `width` primitive or a grapheme iterator; components import only
  buffer/style/color/width (root.zig:5-8), so it is not cheap. Keep the v1
  frame-cycle/pulse as-is.
- **Spinner fps field** — `interval` is already the configurable ms/frame
  knob (src/component/spinner.zig:21-22); an `fps` alias adds surface for no
  behavior.
- **StatusBar base_style / whole-bar background** (zigzag
  `status_bar.zig:33-38`) — notui has no box/background primitive; per-segment
  `Segment.style` covers the dogfood need (the example's `Palette` feeds it).
- **Gauge level_meter / blocks display modes** (gauge.zig:127-137,
  `renderLevelMeter`/`renderBlocks`) — `.bar` is the single useful mode here;
  the other two are presentation garnish.
- **Gauge `value_prefix`/`value_suffix` fmt strings** (gauge.zig:180-186) —
  over-engineering for v1; `label` + `percent` cover it.
- **StatusBar growable segment lists with `addLeft`/`setLeft` mutation API**
  (zigzag `status_bar.zig:52-92`) — the borrow-model slices (`left: []const
  Segment`) plus per-frame reassignment is simpler and matches the no-alloc
  layer contract.

---

## 4. Statusline migration spec

Rewrite `examples/statusline.zig` to use the layer. **Keep the Palette logic**
(profile-driven accent fallback) — it feeds per-segment `Segment.style`.

Target shape:

- `region_height: u16 = 3` (was 2).
- **Row 0 — StatusBar** spanning the region width:
  ```zig
  var bar: component.StatusBar = .{
      .left   = &.{
          .{ .text = " NORMAL ", .style = palette.badge },
          .{ .text = "notui",    .style = palette.app },
          .{ .text = "main*",    .style = palette.branch },
      },
      .right  = &.{ .{ .text = tail, .style = palette.tail } }, // "v0.0.0  col N"
      .separator = " │ ",
  };
  _ = try bar.draw(&region.cur, 0, 0, now);
  ```
  - `tail` built as before via `std.fmt.allocPrint(arena, "v{s}  col {d}", ...)`
    (the old right-aligned tail code — `buildFrame`'s `avail`/`tail_x`
    block — is deleted; StatusBar owns right-alignment + truncation now).
  - `separator = " │ "` reproduces the original `" │ "` joins between
    left-group segments (the badge↔app gap was a bare space; the app/branch
    gap was `" │ "` — the example bakes the single-space case into the badge
    text `" NORMAL "` and uses one `" │ "` separator, see §6 open Q1).
- **Row 1 — Gauge** (dogfood): a live meter, value derived from elapsed time
  (not component-animated; the app drives `value`):
  ```zig
  var gauge: component.Gauge = .{
      .width = 30,
      .label = "scan",
      .label_style = palette.app,
      .percent_style = palette.tail,
      .thresholds = &.{
          .{ .value = 50, .color = <yellow> },
          .{ .value = 85, .color = <red> },
      },
  };
  gauge.setValue(50.0 + 45.0 * @sin(elapsed_s));
  _ = try gauge.draw(&region.cur, 0, 1, now);
  ```
  - `elapsed_s` from a monotonic clock sampled once per loop iteration
    (`std.Io.Timestamp.now(io, .awake)` — the v1 clock model, component.zig).
- **Row 2 — Text** (dogfood `Text.wrap`): the old wrapped-message row becomes
  ```zig
  var msg: component.Text = .{ .text = message, .wrap = true,
      .style = palette.message, .scratch = &scratch };
  _ = try msg.draw(arena.allocator(), &region.cur, 0, 2, now);
  ```
  (replaces the `width.wrap` + `first_line_end` + `region.cur.draw` block).
- **Interactive loop**: redraw once per `nextTimeout(100)` iteration to
  animate the gauge (advance the sin value and set `need_redraw = true` every
  tick, in addition to the existing resize path). This is the one behavioral
  change beyond refactoring — the old loop only redrew on resize.
- **Piped/non-TTY path unchanged**: `runPiped` builds the same 3-row frame
  with `profile = null` (all-default `Palette.plain`, no SGR), renders one
  plain frame, exits without parking. Same for the `buildFrame` signature
  (`arena`, `region`, `profile`); inside it now composes the three
  components. `Palette` stays.
- Keep the fd-capture caveat comment (architecture §9.2).

---

## 5. Test requirements

Follow the existing golden pattern: fixed test `Buffer` + `TestWriter`
(`renderAll` goldens), synthetic `now` via `std.Io.Timestamp.fromNanoseconds`,
each file ending with `test { std.testing.refAllDecls(@This()); }` and a
`FailingAllocator` guard that `draw` never allocates beyond `scratch`.

**StatusBar** (`status_bar.zig`):
1. Left + right: `draw` returns `avail`; left segments start at `x`; right
   group's last cell lands at `x + avail - 1` (right-aligned).
2. Center: with `center` set, its midpoint sits near `avail/2` and it never
   overlaps left or right.
3. Truncation priority: shrinking `buf.width` truncates RIGHT first, then
   CENTER; LEFT is truncated only when `lw >= avail`. Ellipsis "…" appears on
   the last surviving truncated segment.
4. Separator: `separator = " │ "` joins adjacent left segments; `separator =
   null` draws them adjacent.
5. Empty groups: empty `center`/`right` → left-only line, blank tail.
6. **Plain render**: with a default-style bar, `renderAll` emits NO SGR
   (assert the output contains no `\x1b[`).

**Gauge** (`gauge.zig`):
1. Partial block at the fill edge: `ratio` such that `filled_units % 8 != 0`
   puts `blocks[partial-1]` in the fill-edge column; full cells use `"█"`.
2. Threshold color: `value` crossing a threshold switches the fill cells'
   fg; the LAST matching threshold wins.
3. `ratio` clamps: `value > max` → 1; `value < min` → 0; `max <= min` → 0.
4. Label + percent: label drawn before the bar with `label_style`; `" {d:.0}%"`
   after; `show_percent = false` omits it.
5. Width truncation: `buf.width - x` caps the whole gauge; percent suffix
   truncates at the edge.

**Text alignment** (`text.zig`):
1. `align = .right` places the last glyph at `x + avail - 1`; `.center`
   centers; `.left` unchanged; truncated text (width > avail) draws at `x`.

**Progress label** (`progress.zig`):
1. `label` drawn before the bar with `label_style`; bar/percent unchanged.

**Migration / non-TTY** (`examples/statusline.zig` — build-level):
1. `zig build run-example-statusline < /dev/null | cat` prints exactly one
   plain 3-row frame (no `\x1b[`, no interactive sequences) and exits 0.
   (Existing manual acceptance, plan T7.4 / README:96 — extend it to assert
   the three rows and gauge text are present.)
2. A unit golden in `status_bar.zig`/`gauge.zig` asserting a `profile = null`
   (default-style) render of the migrated frame is escape-free covers the
   "plain frame, no escapes" contract at the component layer; the example's
   piped run is the end-to-end proof.

---

## 6. Open questions for the orchestrator (max 3)

1. **StatusBar separator granularity.** The example mixes a bare space
   (badge→app) and `" │ "` (app→branch) within the SAME left group. A single
   `separator` field can't reproduce both — I propose baking the space into
   the badge text (`" NORMAL "`) and using `separator = " │ "`. Is that
   acceptable, or should `Segment` gain an optional per-segment separator?
2. **Gauge in the migrated example?** Adding the live Gauge row grows
   `region_height` 2→3 and makes the interactive loop redraw every tick (a
   behavior change). Keep the Gauge dogfood, or migrate only StatusBar + Text
   and leave Gauge to a unit test?
3. **Right-group truncation direction.** For a too-wide right group I truncate
   from its trailing end (drop/ellipsize the last segment, favoring the
   left). Anchoring the right edge and dropping the leftmost segment would be
   more natural for a right-aligned tail but costs a start-offset walk. Is
   trailing-truncation acceptable for v1?
