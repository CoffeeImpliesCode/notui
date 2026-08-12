# base-ui layer contract (v1)

The presentation / building-blocks layer of notui, sitting between the v0
primitives (`Buffer`, `Style`, `Color`, `width`, `Region`) and future app
frameworks. This document is the implementer's spec: read ONLY this file
plus the notui source. It stays deliberately thin — a small set of
stateful drawing components plus styling sugar, NOT a widget framework.

The layer's job: take the hand-rolled "component" pattern from
`examples/statusline.zig` (styled segments drawn into `region.cur` via
`Buffer.draw`) and make it reusable. Components draw into a `Buffer` at a
position, are width-aware, and advance themselves by elapsed time.

---

## 1. Reference comparison

Studied sources (local clones; line cites are file:line in each repo):

| Component | Contract shape | Animation model | Styling model | Worth stealing |
|---|---|---|---|---|
| **pi-tui Text** (`packages/tui/src/components/text.ts`) | `render(width): string[]` returns pre-rendered ANSI lines (`text.ts:81`) | none (stateless) | color closures (`customBgFn`), margins/padding | padding + width-accounting before wrap; empty-text short-circuit (`text.ts:96`) |
| **pi-tui Loader** (`loader.ts`) | `extends Text`; `render(width)`; `start()/stop()` | `setInterval`, `currentFrame = (frame+1) % frames.len` (`loader.ts:88`), `intervalMs` 80ms default (`loader.ts:11`) | `spinnerColorFn(frame)` + `messageColorFn(message)` closures (`loader.ts:42-43`) | default braille frame table (`loader.ts:10`); frame/interval as config; spinner+space+message composition (`loader.ts:104`) |
| **pi-tui CancellableLoader** (`cancellable-loader.ts`) | loader + AbortSignal + `handleInput` | — | — | OUT: needs event/loop wiring (not a v1 primitive) |
| **pi-tui Box / Stack** (`box.ts`, `stack.ts`) | container: render children, apply padding/bg; Stack is a grow/shrink/basis layout solver | none | `bgFn` | OUT: layout engine — explicitly deferred (architecture §7) |
| **zigzag Spinner** (`src/components/spinner.zig`) | retained struct; `view(allocator) ![]const u8` returns one styled line | **elapsed-time driven**: `update(elapsed_ns: i64) bool` advances only when `elapsed - last_tick >= ns_per_s/fps` (`spinner.zig:96-104`); `tick()` wraps `% frames.len` (`spinner.zig:90-93`); default `fps 10` | `spinner_style: style.Style` field (`spinner.zig:16`), set via `setStyle` | **time-gated advance** (`spinner.zig:96-104`) is the model to copy; rich preset frame table `Styles` (`spinner.zig:21-40`); spinner+title composition `viewWithTitle` (`spinner.zig:108-120`) |
| **zigzag Progress** (`progress.zig`) | retained struct; `view(allocator)` renders bar | none (state `current/total`) | `full_style`/`empty_style`/`percent_style` (`progress.zig:18-20`); gradient via `interpolateColor` (`progress.zig:151-159`) | filled/empty width from ratio (`progress.zig:114-117`); head-char at fill edge (`progress.zig:119-121`); **`interpolateColor(start,end,t) -> Color` RGB lerp** (`progress.zig:255-266`, re-exported root.zig:374) — the animation-color primitive |
| **zigzag Gauge** (`gauge.zig`) | retained struct; `view(allocator)`; `ratio()` (`gauge.zig:118-123`); threshold colors | none | `activeColor` via thresholds (`gauge.zig:125-131`); per-cell fill style | fractional block chars (▏▎▍▌▋▊▉, `gauge.zig:200-214`) for smooth fill — nice-to-have, not v1 |
| **zigzag StatusBar** (`status_bar.zig`) | retained; `view(allocator)` single padded line; left/center/right segment groups (`status_bar.zig:30-32`) | none | per-segment `Segment{text, style}` (`status_bar.zig:24-27`) | OUT: multi-segment layout — v1 Progress/Text cover the demo need; left/right alignment is app-side |
| **zigzag TextInput** (`text_input.zig`) | retained; full cursor/editing state | — | per-part styles | OUT: input widgets are v1 app-framework material (needs focus/event loop) |
| **bubbles spinner** | — (bubbles NOT vendored locally; README links it) | README reference only (`github-charmbracelet-bubbletea/README.md:317`) | — | default braille frames already matched by pi-tui/zigzag; nothing extra to lift |
| **libvaxis vxfw** (`src/vxfw/vxfw.zig`) | retained-widget tree; `Widget{userdata, eventHandler, drawFn}` (`vxfw.zig:283-310`); `DrawContext{arena, min, max}` | `Tick` command schedules via `std.Io.Timestamp.now(io, .awake)` (`vxfw.zig:76-77`) | cells carry style | OUT: retained widget tree + constraints solver. **KEEP the clock model**: `std.Io.Timestamp.now(io, .awake)` + `.addDuration(.fromMilliseconds(ms))` (`vxfw.zig:76-84`) is the std.Io monotonic clock for time-gated advance |

### Decisions extracted

1. **Not the `render(width) → string[]` contract** (pi-tui). notui already
   has a cell `Buffer` and the `Region` diff renderer; producing ANSI
   strings would bypass the diff and the non-TTY path. Components must draw
   into `Buffer` cells so `Region.renderDiff` stays the single output path.
2. **Not the `view(allocator) → []const u8` contract** (zigzag). Same
   reason: allocating styled strings is the diff-less model. Copy the
   *animation timing* and *style-field* design, not the render output.
3. **Not the retained-widget tree** (vxfw). No `Widget` vtable, no
   `DrawContext` constraints, no event handlers in v1. Components are
   plain stateful structs with a `draw` method.
4. **Time-gated animation** (zigzag `update`) is the advance model, driven
   by the **std.Io clock** (vxfw `Tick`) so a component knows elapsed time
   without the app threading a frame counter.

---

## 2. Scope decision

### In v1 — the component list

| Component | Why it earns a slot |
|---|---|
| **Spinner** | The most-copied primitive; every reference ships one (pi-tui Loader, zigzag Spinner, bubbles, vxfw Spinner). Small, self-contained, needs only a frame table + time advance. Directly absorbs the `examples/statusline.zig` gap: nothing animates today. |
| **Text** | Absorbs the styled-segment pattern from `examples/statusline.zig` (Palette + `Buffer.draw`). Covers truncate + optional wrap + ellipsis. The building block every app draws first. |
| **AnimatedText** | The "glam" piece: frame-cycling text (marquee / pulse / blinking word) and **color interpolation** over time. Lifts zigzag `interpolateColor` for a "breathing" gradient word. Pure superset of Text (Text = AnimatedText with a single frame). |
| **Progress** | The other universally-shared primitive (zigzag Progress/Gauge). Ratio → filled/empty bar with a styled fill, optional gradient. Covers status bars / install meters. |

### OUT of v1 (deferred, not silently omitted)

- **Input widgets** (TextInput, field, editor): need focus + a key/event
  loop — the app framework's job (architecture §7). The v0 `Reader`/`Key`
  surface exists; widgets that mutate on keys come with v1+.
- **Lists** (ListView, virtual_list, select_list, scroll_view): need a
  viewport/scroll contract. App-level.
- **Layout** (Stack/Box/HStack/VStack, Padding, SizedBox, SplitView,
  Center, FlexColumn/Row): the flex/join solver is explicitly deferred
  (architecture §7). v1 components position by explicit `(x, y)`; the app
  composes rows like `statusline.zig` already does.
- **Containers / trees / retained widgets** (vxfw Widget, Button, Image,
  SplitView): framework material.
- **StatusBar**: not needed as a component — `Progress` + `Text` compose
  one. Multi-segment left/center/right is app-side.
- **Gauge**: `Progress` covers the bar case; threshold colors and
  fractional blocks are nice-to-haves the implementer MAY add later.

---

## 3. Component contract

A component is a **plain stateful struct** that owns its configuration and
its animation state, and exposes a small fixed surface:

```zig
// src/component/component.zig
const std = @import("std");
const Buffer = @import("../buffer.zig").Buffer;
const Style = @import("../style.zig").Style;
const Clock = std.Io.Timestamp;

pub const Component = struct {
    /// Draw this component into `buf` with its top-left at (x, y).
    /// Returns the number of COLUMNS consumed (width-aware truncation:
    /// never exceeds `buf.width`, per Buffer.draw). May draw multiple
    /// rows (a wrapped Text); consumed = widest row. Advances internal
    /// animation state to `now` first, so a frame that calls `draw`
    /// reflects the current time.
    pub fn draw(self: *Component, buf: *Buffer, x: u16, y: u16, now: Clock) !u16 { _ = self; _ = buf; _ = x; _ = y; _ = now; return 0; }

    /// Advance animation to `now` WITHOUT drawing. Returns true when the
    /// frame changed (the app may use it to skip re-renders). Idempotent:
    /// calling twice with the same `now` advances at most once.
    pub fn advance(self: *Component, now: Clock) bool { _ = self; _ = now; return false; }
};
```

Rationale and rules:

- **`draw` is the only render path.** It writes grapheme cells via
  `Buffer.draw` (src/buffer.zig:128) — the same contract the Region diff
  consumes. Components never emit ANSI and never allocate a string.
- **Return `columns used`** (mirroring `Buffer.draw`'s `!u16`, src/buffer.zig:129)
  so the app can compose components left-to-right:
  `x += comp.draw(buf, x, y, now);` — exactly the pattern
  `examples/statusline.zig` `buildFrame` uses with raw `Buffer.draw`
  (`x += try region.cur.draw(...)`).
- **`draw` first calls `advance(now)`**, so the caller never calls both.
  `advance` is separate so an app that only wants to time-animate (and
  not redraw) can skip the draw. `advance` returning `true` on change lets
  a caller gate `Region.render` on "did anything move".
- **`now: std.Io.Timestamp`** is the monotonic clock from `std.Io.Timestamp.now(io, .awake)`
  (the vxfw `Tick` pattern, libvaxis vxfw.zig:76-84). Passing it in keeps
  components pure/testable (no global clock) and matches how notui already
  threads `std.Io` through `Tty`/`Region`.
- **Style is a field** on every component (e.g. `style: Style = .{}`),
  using the existing `Style` (src/style.zig) with its `fg`/`bg`/`attrs`/
  `hyperlink` and `merge`. Style is drawn per-cell via `Buffer.draw`'s
  style argument; the Region's SGR diff does the dedup.
- **Width-aware truncation is mandatory.** No component may write past the
  buffer edge. Truncate with `width.truncate` (src/width.zig) at grapheme
  boundaries; `Buffer.draw` already drops over-wide glyphs gracefully
  (src/buffer.zig:140-146), so a component that truncates to `buf.width - x`
  is safe by construction. `avail = buf.width -| x` is the hard cap.
- **No allocation during draw.** Components draw borrowed text slices into
  cells (Cell.grapheme borrows, src/cell.zig). If a component must
  materialize text (wrapped/truncated/ellipsized), it uses a caller-owned
  scratch buffer (see Text spec). This keeps `draw` infallible on OOM and
  preserves the borrow model (architecture §3).
- **Zero-component-size default**: every component can be `init()`ed to a
  sensible default and used with no further config (like zigzag's
  `Spinner.init()` and `Progress.init()`).

### Advance timing

Time-gated, per zigzag `spinner.zig:96-104`: a component stores
`last_advance: ?Clock` and advances its frame/color index only when
`now.nanoseconds - last_advance >= interval_ns`. A component with a
single frame (plain Text) never advances and `advance` returns `false`.

```zig
fn elapsedSince(self: *const @This(), now: Clock, last: ?Clock) ?u64 {
    const l = last orelse return null; // first call: don't advance yet
    const d = now.nanoseconds -| l.nanoseconds; // monotonic: safe
    return if (d >= self.interval) d else null;
}
```

---

## 4. Per-component spec

### 4.1 `Spinner`

```zig
// src/component/spinner.zig
pub const Spinner = struct {
    frames: []const []const u8 = &default_frames, // borrowed, never freed
    interval: u64 = 100 * std.time.ns_per_ms,     // 100 ms/frame
    style: Style = .{ .fg = .{ .ansi = .cyan } },
    label: ?[]const u8 = null,                    // optional trailing text, styled with `style`
    // state
    frame_index: usize = 0,
    last_advance: ?std.Io.Timestamp = null,

    pub const default_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
};
```

- Default braille frames are the shared set from pi-tui `loader.ts:10`
  and zigzag `spinner.zig:22` (identical). Optional extra presets mirroring
  zigzag `Styles` (line, dots2, globe, moon, arc, pipe, pulse —
  `spinner.zig:21-40`): implement `Spinner.presets.line/.dots/.globe/...`
  as `pub const` tables. Keep the full zigzag list as a copy-source
  reference for the implementer to port directly.
- `draw`: `advance(now)`, then `frame = frames[frame_index % frames.len]`,
  then `buf.draw(style, frame, x, y)`; if `label` is set, draw a single
  space then the label at `x + frame_width`. Return columns consumed
  (frame width + optional space+label, capped at `avail`).
- Guard: `frames.len == 0` → draw nothing (return 0). Never divide by zero.
- `advance`: if `frames.len <= 1` return `false` immediately (nothing to
  animate). Else advance `frame_index` by the count of elapsed intervals
  (`n = elapsed / interval`, `frame_index = (frame_index + n) % frames.len`),
  set `last_advance = now`, return `n > 0`.

### 4.2 `Text`

```zig
// src/component/text.zig
pub const Text = struct {
    text: []const u8 = "",
    style: Style = .{},
    /// Truncation mode: cut at grapheme boundary; append `ellipsis` when
    /// the text didn't fit. If `ellipsis` is null, no marker is added.
    ellipsis: ?[]const u8 = "…",
    /// True: wrap to `wrap_width` (may draw multiple rows). False: single
    /// line, truncated.
    wrap: bool = false,
    wrap_width: u16 = 0, // 0 => `avail` (buf.width - x)
    /// Caller-owned scratch for wrap/truncate output (the borrow model).
    scratch: *std.ArrayListUnmanaged(u8) = &.{},

    fn fit(self: *Text, alloc: std.mem.Allocator, avail: usize) ![]const u8;
};
```

- `draw`: resolve the display string via `fit` (below), then draw it and
  return consumed columns.
- `fit`:
  - If `width.strWidth(text) <= avail` → return `text` as-is (borrowed).
  - **truncate mode**: `width.truncate(alloc, text, avail - ellipsis_w)`
    then append `ellipsis` (src/width.zig:54). Allocated from `scratch`.
  - **wrap mode**: `width.wrap(alloc, text, wrap_width or avail, 1)`
    (src/width.zig:27), split on `\n`, draw each line at `(x, y + row)`,
    return the widest consumed row. Truncate the last wrapped line if it
    still overflows.
- The ellipsis is a single "…" by default; the statusline example already
  hand-rolls this (`examples/statusline.zig` `buildFrame`: truncate to
  `path_cols - 1` then draw "…").
- Styled via `style`; every line drawn with the same `style`.

### 4.3 `AnimatedText`

```zig
// src/component/animated.zig
pub const AnimatedText = struct {
    frames: []const []const u8 = &.{},   // 0 => animate color only
    interval: u64 = 200 * std.time.ns_per_ms,
    style: Style = .{},
    /// Color pulse (overrides `style.fg` when set): cycles fg between
    /// `gradient_a` and `gradient_b` over `gradient_period`.
    gradient_a: ?Color = null,
    gradient_b: ?Color = null,
    gradient_period: u64 = 2 * std.time.ns_per_s,
    // state
    frame_index: usize = 0,
    last_advance: ?std.Io.Timestamp = null,
    phase_ns: u64 = 0, // accumulated time for gradient phase
};
```

- Superset of Text: with a single frame and no gradient it behaves as a
  styled `Text`. Used for marquee / pulsing word / blinking status.
- `draw`: advance, then:
  - pick `frame = frames.len == 0 ? null : frames[frame_index % frames.len]`;
  - if `gradient_a`/`gradient_b` set, compute
    `t = 0.5 * (1 + sin(2π * phase_ns / gradient_period))` and set
    `effective.fg = interpolateColor(gradient_a, gradient_b, t)` merged over
    `style` (via `style.merge`), else `effective = style`;
  - draw the frame (or `text` if no frames) with `effective`, truncating
    to `avail`.
- `advance`: advance `frame_index` time-gated as Spinner; always accumulate
  `phase_ns += elapsed` (the color breathes even with one frame).

### 4.4 `Progress`

```zig
// src/component/progress.zig
pub const Progress = struct {
    value: f64 = 0,
    total: f64 = 100,
    width: u16 = 40,             // bar length in cells
    full_char: []const u8 = "█",
    empty_char: []const u8 = "░",
    head_char: ?[]const u8 = null, // char at the fill edge when filling
    full_style: Style = .{ .fg = .{ .ansi = .cyan } },
    empty_style: Style = .{ .fg = .{ .ansi256 = 245 } },
    percent_style: ?Style = null,  // styled " 42%" suffix; null => no percent
    gradient_a: ?Color = null,     // per-cell fill gradient (interpolateColor)
    gradient_b: ?Color = null,
};
```

- `ratio = if total > 0 then clamp(value/total, 0, 1) else 0` (the
  `setValue` clamp from zigzag `progress.zig:98-101`).
- `filled = floor(ratio * width)`, `empty = width - filled` (zigzag
  `progress.zig:114-117`).
- Draw `filled` full chars (last one = `head_char` when set and `empty > 0`,
  zigzag `progress.zig:119-121`), then `empty` empty chars, each at
  `x + col, y` with the per-cell style.
- **Gradient**: when both `gradient_a`/`gradient_b` set, per filled cell
  `t = col / max(1, filled-1)` and
  `cell_style.fg = interpolateColor(gradient_a, gradient_b, t)` (zigzag
  `progress.zig:151-159`). No alloc: build the Style inline.
- **Percent suffix**: if `percent_style` set, draw `" {d:.0}%"` after the
  bar with `percent_style`, truncated to `avail`.
- No animation (no `last_advance`); `advance` always returns `false`.
  `setValue`/`setPercent`/`increment`/`setTotal`/`setWidth` helpers
  mirror zigzag `progress.zig:97-112`.

---

## 5. Styling sugar ("glam")

Small, mostly free functions — no framework. Everything below is a thin
addition on top of `Style`/`Color`.

```zig
// src/style.zig additions (or src/glam.zig if it grows; keep in style.zig)
pub fn fg(self: Style, c: Color) Style;     // self but fg=c  (copy-on-return, no mutation)
pub fn bg(self: Style, c: Color) Style;
pub fn bold(self: Style) Style;             // attrs.bold=true
pub fn italic(self: Style) Style;
pub fn dim(self: Style) Style;
pub fn underline(self: Style) Style;
```

- **Style convenience constructors** (`fg`/`bg`/`bold`/`italic`/`dim`/
  `underline`) returning a copy. Directly ports the zigzag builder style
  (`spinner.zig:48-53` `s = s.fg(.cyan); s = s.inline_style(true)`) onto
  notui's immutable `Style`. These make component config terse:
  `.style = Style{}.fg(.cyan).bold()`.

```zig
// src/color.zig additions
pub fn interpolate(a: Color, b: Color, t: f64) Color;  // RGB lerp, clamps t
pub fn gradient(start: Color, end: Color, steps: usize) [8]Color; // comptime steps<=8
```

- **Color interpolation**: `interpolate(a, b, t) → Color`, RGB lerp per
  channel with `t` clamped to 0..1, falling back to `a` when either end is
  non-rgb-convertible. Direct port of zigzag `interpolateColor`
  (`progress.zig:255-266`, re-exported `root.zig:374`); it already has
  `toRgb` equivalents in notui (`color.zig`: `AnsiColor.toRgb`,
  `ansi256ToRgb`). Also a `gradient(start, end, steps)` helper that returns
  a comptime array for static ramp palettes.
- **Do NOT add**: a theming system, a style registry, named-color
  palettes, adaptive-color resolution. `ColorProfile` fallback is already
  the emit layer's job (`emit.writeStyleProfile` downsamples rgb); the app
  picks colors by profile exactly as `examples/statusline.zig` `Palette`
  does. Keep glam to the four constructors + two color helpers above.

---

## 6. Module layout

```
src/component/component.zig   Component contract + shared advance helper
src/component/spinner.zig     Spinner
src/component/text.zig        Text
src/component/animated.zig    AnimatedText
src/component/progress.zig    Progress
src/component/root.zig        pub const exports (see below)
src/root.zig                  add: pub const component = @import("component/root.zig");
```

- `src/component/root.zig`:
  ```zig
  pub const Component = @import("component.zig").Component;
  pub const Spinner = @import("spinner.zig").Spinner;
  pub const Text = @import("text.zig").Text;
  pub const AnimatedText = @import("animated.zig").AnimatedText;
  pub const Progress = @import("progress.zig").Progress;
  ```
- **Dependency direction**: components import ONLY `buffer`, `style`,
  `color`, `width` — the existing primitives. They never import `region`,
  `tty`, `caps`, or each other. This keeps the layer a pure presentation
  set an app can use against any `Buffer` (region-cur, a test buffer, a
  standalone render).
- `src/root.zig` gains one line:
  `pub const component = @import("component/root.zig");` (matching the
  existing flat re-export style, src/root.zig).
- Add `examples/components.zig` later (not in this contract) to demo
  Spinner + Progress in a live Region.

---

## 7. Test requirements

Every component gets golden tests against a fixed-size test `Buffer`,
using the existing `TestWriter`/buffer-cell goldens pattern from
`src/buffer.zig` (fixed scratch buffer writer, `expectEqualStrings`).
All tests deterministic: pass an explicit `now` (`std.Io.Timestamp`
from a synthetic ns value, never the real clock).

1. **Width truncation**
   - Text truncates to `avail` at a grapheme boundary; ellipsis appended
     only when text didn't fit; emoji/ZWJ never split mid-bytes.
   - Text wrap draws each line at increasing `y`; widest row returned;
     last line truncated if over-wide.
   - Progress bar never exceeds `buf.width - x`; narrow avail truncates
     the percent suffix.
   - Spinner with a wide frame (globe 🌍, width 2) at the last column
     drops gracefully (never errors).
2. **Tick advancement**
   - Spinner: `advance(now)` with `now` before interval → `false`,
     frame unchanged; `now` past `interval` → `true`, `frame_index` wraps
     `% frames.len`; two advances with the same `now` advance at most once.
   - `frames.len == 0` or `<= 1` → `advance` always `false`, `draw` no-op.
   - AnimatedText: phase advances even with a single frame; frame_index
     wraps; `t` stays in 0..1.
   - Progress: `advance` always `false`.
3. **Style emission**
   - Cells drawn carry the component's `Style`; `Buffer.draw` per-cell
     style verified via a `renderAll`/`renderDiff` golden (the Region's
     SGR path, not component output). E.g. Spinner draws
     `.{.fg = .cyan}` cells; Progress full vs empty cells differ.
   - Gradient Progress: cell at col 0 ≈ `gradient_a`, col `filled-1` ≈
     `gradient_b` (compare interpolated `Color.eql`, or a render golden).
4. **No-allocation during draw**: `draw` uses only the caller scratch; no
   hidden `allocator.alloc` in the hot path (enforced by using a
   `std.heap.FailingAllocator` in a test that asserts no allocation fails).
5. **Composition**: `x += draw(...)` chains left-to-right and consumed
   widths sum correctly against a fixed buffer.

Each component file ends with `test { std.testing.refAllDecls(@This()); }`
(matching src/buffer.zig / src/style.zig).

---

## 8. Open questions for the orchestrator

1. **`advance` inside `draw` vs caller-driven**: should `draw` mutate
   animation state automatically (this contract: yes, so a frame redraw is
   one call), or should the app call `advance`/`draw` separately for
   render-gating? Auto-advance is simpler but couples "did the frame
   change" detection to a redraw. Confirm auto-advance is acceptable.
2. **Borrowed `frames`/`text` vs owned**: this contract borrows slices
   (no alloc in components). Is that acceptable for `AnimatedText.frames`
   (apps may want to mutate frames at runtime), or should components own a
   list via an allocator? Borrowed keeps the Cell-grapheme borrow model;
   owned adds allocator plumbing to every component.
3. **Ellipsis default**: is a hardcoded "…" ellipsis default acceptable,
   or should truncation append a styled/width-accounted marker only when
   the caller opts in? (This contract defaults to "…" with `null` to
   disable, mirroring `examples/statusline.zig`.)
