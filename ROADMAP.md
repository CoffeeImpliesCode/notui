# notui roadmap

Derived from four surveys (2026-10-01): **pi-tui** (the TypeScript TUI inside
`oh-my-pi`, which `omp` drives), **zomp** (the Zig reimplementation of that
agent, whose Phase 6 is "port the TUI from notui"), **notui** itself, and the
external fast-TUI landscape (ratatui, Bubble Tea, Textual, Ink, OpenTUI,
libvaxis).

Each item names the evidence it comes from, the concrete deliverable, and the
check that closes it. Items are ordered by what unblocks the most: F first
because it gates the rest, B because it is correctness, C because it is
zomp's Phase-6 gate, D/E because they are app content.

## What the reference does that notui does not

| Reference behaviour | Planning baseline (`0791fe1`) |
|---|---|
| Two output channels: `HistoryBatch{id, rows, kind}` + viewport, acknowledged once (`tui.ts:159-187`, `tui.ts:3259-3263`) | `Region` has an append queue with no batch id, no ack, no replay |
| Paint envelope: hide cursor + DEC 2026 + DECAWM off, one write per frame (`tui.ts:85-93`, `tui.ts:3224`) | sync-output option and emit helpers exist; no per-frame envelope |
| Row-level damage over prepared lines, memoized by content (`tui.ts:599-609`, `tui.ts:3436-3502`) | `Buffer.renderDiff` already skipped equal rows, but scanned rows twice and had no emitted-SGR memo |
| Adaptive scheduling: cadence + ~50% duty cycle + output backpressure (`tui.ts:866-889`, `tui.ts:2457-2506`) | fixed `fps` in `App.Options`, render-on-demand, no backpressure |
| Streaming retirement `active → settled → committed` with an 8 ms budget (`transcript-container.ts:68-116`) | none; apps re-render live content themselves |
| Never a screen-wide erase; ED2 before ED3, for tmux/conhost history (`tui.ts:2989-3110`) | `Region` has five frame strategies; erase discipline unaudited against multiplexers |
| Editor, fuzzy autocomplete, keybindings + hints, overlays/pickers, theme | components are `Text/Spinner/AnimatedText/Progress/Gauge/StatusBar/Suggestions` — display only |
| Golden-frame bench and debug server (`bench/`, `debug-server.ts`) | no in-tree frame-capture harness; no bench step |

Landscape cross-checks that hold for the same items: every mature renderer is
damage-based and returns early when nothing was touched (ultraviolet
`terminal_renderer.go`, libvaxis `Vaxis.zig`, ratatui `Terminal`); synchronized
output is the universal atomic-frame primitive, gated per library, and Textual
disables it inline; per-frame allocation discipline is explicit (libvaxis
arena reset, ultraviolet "a steady stream of frames allocates nothing").

## Phase F — measurement first

Measurement is the acceptance prerequisite for the pipeline and content phases.

| id | deliverable | closes on |
|---|---|---|
| F1 | Golden-frame harness: feed stdin bytes, capture stdout bytes, assert (plus a record mode). One test drives `Parser` → `Region` → bytes | a test that asserts an exact byte stream for a scripted session, and one that asserts "frame that changed nothing writes nothing" |
| F2 | `bench` build step: frame time (p50/p99), bytes per frame, allocations per frame, at 80×24 and 200×60, for a static frame and a streaming frame | published numbers in `README.md`, re-runnable from the gate |
| F3 | Loop watchdog + debug server parity with `pi-tui` (render a frame on a TCP port, inspect state) | bench harness can drive a real loop without a pty |

## Phase B — frame pipeline correctness

| id | deliverable | evidence | closes on |
|---|---|---|---|
| B1 | Output backpressure: track pending bytes, refuse to compose above a watermark, retry on drain | `tui.ts:888`, `tui.ts:2496-2506` | a slow-reader test proves frames defer and memory stays bounded |
| B2 | Paint envelope: hide cursor + DEC 2026 + DECAWM off around every frame, one write; restore on teardown | `tui.ts:85-93`; landscape sync-output agreement | byte-exact envelope test; behaviour unchanged when sync output is unsupported |
| B3 | Erase discipline audit: no screen-wide erase, ED2 before ED3, document what each of the five `Region` strategies emits under tmux | `tui.ts:2989-3110` | strategy-by-strategy byte test; a note in `README.md` |
| B4 | Row-granular early-out in `Buffer.renderDiff` plus an emitted-SGR memo | `tui.ts:599-609`, `tui.ts:3436-3502`; landscape per-row `FirstCell/LastCell` | F2 shows bytes/frame down on a mostly-static frame with no pixel change |

## Phase C — scrollback ledger (zomp Phase-6 gate)

zomp's contract, verbatim from `docs/zomp-design.md:136-139`: a monotonic
history batch id written exactly once then acked; finality is a product
decision, never inferred from a row crossing the top of the screen; a
`replay` batch is the complete logical ledger in one atomic write; the
renderer never probes terminal scroll position.

| id | deliverable | closes on |
|---|---|---|
| C1 | `HistoryBatch{id, rows, kind: append\|replay}` + `acknowledgeHistory`, on `Region` | a test that a batch is written once and acked once; a replay reproduces the ledger |
| C2 | Resize modes `append \| rebuild \| preserve`; reflow of settled content that does not rewrite history | mid-stream resize reflows the band while scrollback keeps its rows |
| C3 | Streaming retirement: `active → settled → committed` with a time budget | a delta reaches the terminal within one frame; settled rows are never repainted |

## Phase D — input and app-facing widgets

zomp ships its own `editor.zig` (8029 lines across `src/tui/`) and has **no**
approval screen — its approval hook denies every question by default
(`src/run_cmd.zig:11-19`). These belong in the library.

| id | deliverable | evidence | closes on |
|---|---|---|---|
| D1 | `component.editor`: codepoint/grapheme motion, kill ring, bracketed paste, undo | zomp `src/tui/editor.zig`; `pi-tui` `kill-ring.ts` | zomp deletes its editor and passes its gate |
| D2 | Fuzzy matcher + suggestion list bound to `component.Suggestions` | `pi-tui` `fuzzy.ts`, `autocomplete.ts` | matcher tests on ordering and unicode input |
| D3 | Keybinding declaration and hint rendering | `pi-tui` `keybindings.ts`, `key-hint-format.ts` | a keymap round-trip test; hints render from the same declaration |
| D4 | Overlay and picker primitives (select/approve, modal, anchored popover) | zomp §6.7 "overlays"; `uiContext.select` in `omp-architecture.md:789` | a test that an approval picker returns the chosen index |

## Phase E — content rendering

| id | deliverable | evidence | closes on |
|---|---|---|---|
| E1 | Markdown → rows with an untrusted-bytes sanitiser | zomp `src/tui/markdown.zig`; `pi-tui` `hotkeys-markdown.ts` | fuzz/ANSI-injection test: control bytes in source never reach the terminal |
| E2 | Diff rendering and collapsible tool cards | zomp `src/tui/cards.zig`, `crates/pi-diff` | card collapse ladder test; diff renders inside a `Region` band |
| E3 | Theme tokens with `caps.ColorProfile` gating | `pi-tui` `theme/`; notui has profile gating but no token layer | a theme switch test at two colour profiles |

## Phase A — provenance (do this first, it costs an hour)

`zomp/docs/BLOCKERS.md` §1 records that the notui checkout was absent and its
remote was never written into the provenance table, so Phase 6 was built from
a behavioural specification instead of a port. That is no longer true: the
remote is `https://github.com/CoffeeImpliesCode/notui` (private).

| id | deliverable | closes on |
|---|---|---|
| A1 | `PORTING.md`: remote URL, the commit Phase 6 was ported from, and the four-rule frame contract quoted once for both sides | zomp's blocker §1 updated with a verifiable commit id |
| A2 | Mark which public types are stable port surface (`Buffer`, `Region`, `App`, `View`, `Cmd`, `Context`, `event`) and which are internal | a doc section the port can cite; no API change |

## Status

Every item above is implemented and verified on this host. The evidence:

- `zig build test` — 625/625 pass in Debug and ReleaseSafe.
- `zig-gate` — formatting, build, tests, AST checks, and zlint pass.
- ReleaseSafe `Parser`→`Editor` smoke — 36 scenarios cover Unicode fallback,
  reported-field precedence, controls, named keys, and scalar boundaries.
- A standalone path-dependency consumer at
  `../.notui-roadmap-consumer` builds against `src/root.zig` alone and
  asserts the shipped behaviour end to end: dependency module graph,
  `Parser`→`Editor`→`Region`→pipe, undo/kill/yank, an unchanged frame
  writing zero bytes, golden record and no-clobber, parsed approval
  selecting an exact index, fuzzy optimal run, key hints derived from the
  declaration, sanitized Markdown, diff and card bands, two theme
  profiles, and a piped plain frame with no escape byte.
- `zig build bench` — the ten-case table and the pty-free loop numbers in
  `README.md`.
- A source port of the editor into `../zomp` (`src/tui/text_editor.zig`)
  passes that tree's 198-test shard, and a ReleaseSafe executable over the
  live file exercised capture/kill/yank/yank-pop/undo/redo and the
  grapheme cursor boundary.

No implementation items remain open. `NEXT.md` records the key text
synthesis contract and explains the advisory `zbc` reports.

## Non-goals

- **Alt-screen / full-screen.** zomp's D7 rejects it (no termios layer to
  restore with) and notui is inline-first by design; the old no-op
  `View.alt_screen` and `Cmd.alt_screen` fields are removed, not implemented.
- **FFI to a Rust or Go TUI.** zomp's D13 lists no new dependencies and names
  this as its own project if ever wanted.
- **A layout solver** (Cassowary, Yoga, TCSS). A single inline band does not
  need one; ratatui, Bubble Tea and low-level libvaxis do not have one either.
  Revisit only if a consumer needs panels.
- **Virtualized widget trees.** Only Textual ships one (`SpatialMap`), and an
  inline band has no scrollable viewport yet.
- **Terminal emulation.** Out of scope; `Parser` decodes what terminals send.

## Known cleanup, not roadmap

Resolved: `emit.zig`'s unused `enterAltScreen`, `exitAltScreen` and
`scrollRegionUp` are deleted. The port surface has no alt-screen path
(`src/view.zig` has no `alt_screen` field, `src/command.zig` no
`alt_screen` effect), so keeping the writers invited a path nothing
tested.
