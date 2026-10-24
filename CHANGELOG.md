# Changelog

## Unreleased

- Require Zig 0.17.0 and pin zg to its upstream Zig 0.17 compatibility PR, with Unicode 18 data.
- Remove `Buffer.cells`. Use `get`, `set`, `draw`, and `copyFrom`.
- Store one-byte ASCII graphemes by value. Other graphemes and hyperlinks remain caller borrows.
- Replace `width.simpleCluster` with the borrowed, allocation-free `width.SimpleIterator`.
- Keep SIMD lane masks in logical lane order on all target byte orders.
- Return the DA1 truecolor flag by value instead of borrowing a query stack buffer.
- Remove the timer test's immediate second-call timing assumption.
- Scan printable ASCII in 32-byte vectors and store each run in one pass.
- Store glyph heads, flags, and packed styles in 16-byte hot slots with cold slice arrays.
- Segment each non-ASCII stretch with one iterator and retain common-script lookahead.
- Scan cold flags and row footprints eight slots at a time.
- Track occupied SGR memo slots instead of clearing all storage per frame.

## 0.1.0

- Default terminal width reflow to `.rewrapping`. Non-rewrapping terminals must declare `.none`.
- Leave autowrap enabled so frames in flight across a resize preserve committed text.
- Store printable one-byte ASCII graphemes in static slices.
- Paint the first band on its reserved rows and repaint the band after resize signals.
- Reclaim retired rows that return beside the live band without erasing committed history.
- Preserve scrollback submission order and wrap appended lines by display width.
- Record erased gap rows when a clipped prefix leaves the band.
- Clear the App buffer per frame, flush teardown output, and process SIGWINCH.
- Clear overlay boxes before drawing Select, Modal, or Popover components.
- Use codepoint widths when the terminal does not cluster text.
- Read capability replies that arrive before their query window opens.
- Improve REPL cursor motion, formula diagnostics, and tiny-band example layout.
- Add the `agent_demo` example, resize tests, and a cross-test profile.
- Add ASCII fast paths and reuse row-level damage checks for snapshots and rendering.
