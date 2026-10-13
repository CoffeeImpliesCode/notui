# Changelog

## Unreleased

### Breaking changes

- `Buffer.cells` is removed. Use `get`, `set`, `draw` and `copyFrom`.
  `Cell` remains the interface value. The grid uses hot slots and cold side arrays.
- `Buffer.set` and `Buffer.draw` store one-byte ASCII graphemes by value.
  Reads return static slices. Other graphemes and all hyperlinks remain caller borrows.

### Fixes

- Preserve SIMD lane order on big-endian targets. ASCII prefix scans, cold-text
  copies and row footprints now select the correct slots.
- Return the DA1 truecolor flag by value. Capability detection no longer reads
  a slice of the query function's expired stack buffer.
- Remove the timer test's immediate second-call timing assumption.
  Its message-delivery and render assertions remain.

### Performance

- Scan printable ASCII in 32-byte vectors and store each run in one pass.
- Keep glyph heads, flags and packed styles in 16-byte hot slots.
  Damage scans, copies and row emission read cold text only when flags require it.
- Segment non-ASCII stretches with one iterator. A checked BMP bitset skips
  segmentation for common Latin, Greek, Cyrillic, kana, CJK and symbol clusters.
  Other clusters still use zg.
- Scan cold flags and row footprints eight slots at a time.
- Use an occupancy mask for the SGR memo instead of clearing its full storage each frame.
- Drop experimental vector slot construction and block copies of cold slices.
  Neither gave a repeatable gain across the benchmark cases.

ReleaseFast against 0.1.0, five interleaved runs on the same CPU:
static 200×60 minimum 145 030 → 48 833 ns, stream 200×60 160 661 → 50 128 ns,
and Region h24 median p50 154 608 → 35 314 ns.
Buffer cases retain zero allocations per frame. Static and Region idle frames emit zero bytes.
See README "Measurement and verification" for all cases and the benchmark-reference timing caveat.

## 0.1.0

First tagged release. Changes since `main` at `38634f2b`.

### Breaking changes

- `Region.Options.terminal_reflow` and `App.Options.terminal_reflow` default to
  `.rewrapping`. xterm.js, VTE, kitty, iTerm2, WezTerm, foot and tmux rewrap old rows
  on a width change. A terminal that never rewraps must declare `.none`.
- The paint envelope no longer turns DECAWM off around band writes. A frame that
  reaches a terminal after it narrowed now soft-wraps instead of overwriting
  committed scrollback at the last column.
- `Buffer.draw` stores printable one-byte ASCII graphemes as static slices
  (`Cell.asciiGrapheme`), not slices of the caller's text. Code that checks where a
  cell's bytes live must skip `Cell.isStaticGrapheme` cells.

### Fixes

- Region: paint the first band on the rows it reserves; repaint the whole band after
  every resize signal; reclaim retired rows that return contiguous with the band;
  keep scrollback in submission order; wrap long and styled lines by display width;
  record every erased gap row when a clipped prefix is handed over.
- App: paint every frame from a blank buffer, flush the teardown, resize the band on
  SIGWINCH.
- Overlay: clear the box before drawing a Select, Modal or Popover.
- Width: lay text out per codepoint where the terminal does not cluster.
- Caps: read a reply that is already waiting when its window opens.
- Examples: REPL cursor and grapheme movement, formula preview and error hint, and
  agent_demo layout in tiny bands.

### Additions

- `examples/agent_demo`, a coding-agent chat built from every component.
- Resize tests: App-like resize bursts with delayed CPR replies, and width reflow under
  the default profile.
- Gate: a cross-test profile; zwanzig finishes every function.

### Performance

ReleaseFast, medians of per-run `min` ns against `38634f2b` on the same host:
static 80×24 193 171 → 47 077, static 200×60 1 013 303 → 305 788, stream 80×24
197 313 → 61 392, styles 81 156 → 56 850. Bytes and allocations per frame did not
grow. See README "Measurement and verification" for the full table.

- `width.zig`: ASCII fast paths in segmentation, width and prefix fitting.
- `Buffer.draw`: static ASCII graphemes and no second measurement per cell.
- `Region`: snapshots own static graphemes without copying; row damage reuses
  `Buffer.rowChanged`'s whole-row byte compare; `Cell.eql` accepts the same slice
  without reading its bytes.
