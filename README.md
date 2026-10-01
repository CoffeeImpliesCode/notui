# notui

Inline-first terminal UI primitives for Zig 0.16.

notui provides a grapheme-aware cell buffer, an inline `Region` renderer,
an Elm-style app loop, editing and selection components, and Markdown,
diff and tool-card rendering. The renderer owns a band in the terminal's
main buffer, never the alternate screen, so scrollback survives.
The only library dependency is
[zg](https://codeberg.org/atman/zg) (Unicode 16 width/graphemes), sealed
behind the `width` module.

## App framework

On top of those primitives, notui ships an Elm-style `App(Model)` layer:
your `Model` declares a `Msg` union plus `init` / `update(model, msg,
ctx) !Cmd(Msg)` / `view(model, ctx) View`, and the framework owns the
event loop, terminal modes, and rendering (sources:
[`src/app.zig`](src/app.zig), [`src/view.zig`](src/view.zig),
[`src/command.zig`](src/command.zig), [`src/context.zig`](src/context.zig)).
`Model.init(gpa)` returns `{ model, cmd }`. Construct the framework with
`App(Model).init()` or `initWithOptions(options)`, install an event-to-message
filter, and call `run(io, gpa)`. The framework invokes the model initializer.

The full counter demo — `Text` + `Spinner` + `StatusBar` composed into
the frame via `View.draw`, keys wired through a filter, `every`-Cmd
animation — is [`examples/framework_counter.zig`](examples/framework_counter.zig):

```bash
zig build run-example-framework_counter
```

## Quick start

Run a complete recipe:

```bash
zig build run-example-spinner
```

[`examples/spinner.zig`](examples/spinner.zig) handles capability detection,
input, frame painting and terminal restoration. The
[`framework counter`](examples/framework_counter.zig) uses the app-owned
output queue; [`prompt`](examples/prompt.zig) shows append-to-scrollback input.

Draw into `region.cur`, render the diff, read events. `Region.render`
repaints in place with relative cursor moves only; `Region.exit` parks
the cursor below the band and leaves the final frame in the transcript.
With piped stdin (`interactive = false`) the region emits one plain
frame, with no interactive escape sequences. `sync_output = false`
only disables DEC 2026; an interactive terminal still renders in place.

## Modules

| Module   | Purpose |
|----------|---------|
| `width`  | zg seam: `strWidth`, `graphemeWidth`, `wrap`, `truncate` (grapheme-safe) |
| `color`  | `Color` (ansi / ansi256 / rgb / default), `ColorProfile`, palette downsampling |
| `style`  | `Style`, `Attrs` (bold, italic, underline, …), `merge` precedence |
| `cell`   | `Cell`: borrowed grapheme slice + style + wide-glyph continuation |
| `emit`   | Internal ANSI writers: cursor, band erasure, sync output, autowrap, profile-gated SGR |
| `event`  | `Event` union, `Key`, `Mouse`, `Winsize`, `Pos`, `Capability` |
| `key`    | key codes and modifiers, `matches` / `matchShortcut` |
| `mouse`  | mouse events (SGR 1006 + pixels 1016) |
| `parser` | terminal input decoder (kitty keyboard, OSC, paste, CPR) |
| `tty`    | Blocking input, independent nonblocking output, raw mode, winsize, panic restore |
| `caps`   | live capability detection (best-effort queries, no terminfo) |
| `buffer` | cell grid: `draw`, `renderDiff` / `renderAll` (style-tracking, wide-safe) |
| `region` | Inline renderer: five strategies, acknowledged history batches, resize modes, anchoring |
| `input`  | `Reader`: blocking read with split-sequence reassembly |
| `image`  | kitty graphics: transmit / place / delete (APC-G, a=t / a=p / a=d) |
| `coverage` | SIMD row-intersection rasterizer for the formula example |
| `component` | Display components plus `Editor`, fuzzy `Suggestions`, `Select`, `Modal`, `Popover`, `Card`, `Diff` |
| `context` / `command` / `view` | framework: runtime context, the `Cmd(Msg)` effect type, the frame closure |
| `app`    | `App(Model)`: input/effect loop, bounded output queue, adaptive pacing, inline rendering |
| `output` | Fixed-capacity output staging, short-write retry and composition watermark |
| `transcript` | Product-driven active → settled → committed retirement |
| `keybindings` | Keymap declarations, chord matching and hints from the same bindings |
| `markdown` | Styled rows and a shared untrusted-input escape/control sanitizer |
| `theme` | Semantic tokens resolved through `caps.ColorProfile` |
| `frame_testing` | Scripted input/output capture and deliberate golden recording |
| `watchdog` / `debug_server` | Headless loop liveness and read-only TCP frame inspection |

## Frame and scrollback contract

Every interactive paint has a cursor-hide prologue, optional DEC 2026,
and DECAWM off/on around the band writes. Idle frames emit zero bytes.
`App` stages the frame into one contiguous pending byte stream before
attempting transport output. A short write or `WouldBlock` retains the
remaining bytes in order; it does not discard or recompose the frame.
Above the output watermark, composition waits for a drain.

History is a separate channel:
`Region.HistoryBatch { id, rows, kind = append | replay }`.
Ids are monotonic. Rows are hard-wrapped logical lines; a replay is the
complete logical ledger, not a slice inferred from terminal position.
Transport completion produces receipts; product acknowledgement releases
retained batch storage. Finality is a product decision, not a row leaving
the viewport. Resize modes `append`, `rebuild` and `preserve` change the
live band without rewriting committed history.

### Erase discipline and multiplexers

No strategy emits screen-wide ED2 (`ESC[2J`) or ED3 (`ESC[3J`).
All display erasure begins at the band anchor or is scoped to one row:

| Strategy | Erasure and movement |
|---|---|
| First frame | Reserve the band with CNL when configured; append rows without erasure |
| Height-only change | Reserve added rows or EL removed rows, then diff; collapse to zero erases nothing |
| History/append flush | ED0 from the band anchor, emit history, repaint the live band |
| Width change / forced redraw | `append`: anchored ED0; `rebuild`: row-local EL full repaint; `preserve`: row-local EL diff |
| Normal diff | EL on changed rows; erase stale high-water rows within the old band |

tmux and conhost can archive display erasure into scrollback. A caller that
owns a separate full-screen policy must order ED2 before ED3; notui emits
neither and never clears above its anchor. DEC 2026 support changes only
the paint wrapper, not the renderer's interactive mode.

## Measurement and verification

```bash
zig build test
zig build bench -Doptimize=ReleaseFast
gate                              # house zig-gate, then the same benchmark
```

The benchmark reports p50/p99 frame time, emitted bytes per frame and
allocations per frame at 80×24 and 200×60 for static and streaming content.
Static steady-state frames must write zero bytes. Rendering allocations
are counted rather than assumed.

Measured on this host (`zig build bench`, ReleaseFast, Zig 0.16; timing
floor clock p50 73 ns / p99 80 ns):

| case | p50 ns | p99 ns | bytes/frame | allocs/frame |
|---|---|---|---|---|
| static 80×24 | 92 872 | 122 841 | 0 | 0.000 |
| static 200×60 | 477 838 | 694 499 | 0 | 0.000 |
| stream 80×24 | 82 459 | 251 120 | 230 | 0.000 |
| stream 200×60 | 402 786 | 498 005 | 427 | 0.000 |
| damage 80×24 | 26 861 | 37 720 | 104 | 0.000 |
| damage 200×60 | 152 584 | 248 611 | 227 | 0.000 |
| styles 80×24 | 31 493 | 39 471 | 170 | 0.000 |
| region h1 | 3 927 | 10 363 | 81 | 0.667 |
| region h4 | 14 546 | 21 143 | 184 | 0.667 |
| region h24 | 88 427 | 149 200 | 851 | 0.667 |

The SGR memo's byte saving is measured against the pre-B4 stream: 170 vs
206 bytes/frame on the style case (17.5%), 227 vs 231 on the 200×60 damage
case (1.7%), and no change on 80×24 damage, where a transition is rare
enough that the memo never repays its bookkeeping.

The same step drives a real loop with no pty: two frames through
`App.frameHeadless`, published over TCP by the debug server and read back.
The App's own `written_bytes` and the transport's independent byte count
agree per frame, and the idle strategy emits zero bytes at every band
height.

[`PORTING.md`](PORTING.md) defines the stable port surface, internal
modules, immutable source pin and the shared four-rule frame contract.


## Examples

```bash
zig build run-example-spinner      # spinning frame; q / ctrl+c exits
zig build run-example-prompt       # echo + backspace + Enter appends to scrollback
zig build run-example-statusline   # styled segments; resize truncates gracefully
```

Piped (non-TTY) smoke — one plain frame, no interactive sequences:

```bash
zig build run-example-statusline < /dev/null | cat
```

## Design

- Inline-first: [`src/region.zig`](src/region.zig) repaints a fixed band
  in the terminal's main buffer, so scrollback survives and the band
  anchors correctly across repaints, resizes, and CPR replies.
- One dependency, one seam: `zg` is reached only through
  [`src/width.zig`](src/width.zig); every grapheme and column decision
  funnels there.
- The framework stays dumb: `App(Model)` owns the loop, the terminal
  modes, and rendering. `update` returns a `Cmd`, `view` paints into the
  buffer, and the app never reads the terminal directly.
- [`FAST_COVERAGE.md`](FAST_COVERAGE.md) — the fast row-intersection
  rasterizer behind [`examples/formula_tui.zig`](examples/formula_tui.zig)
  ([`src/coverage.zig`](src/coverage.zig)).
- Open work, known gaps, and what closes them:
  [`NEXT.md`](NEXT.md).
- What comes next, and the reference implementations it is derived from:
  [`ROADMAP.md`](ROADMAP.md).
