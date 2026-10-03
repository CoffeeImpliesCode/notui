# Porting notui

A porting contract for whoever moves notui's TUI into another codebase. The
concrete consumer is **zomp**, whose Phase 6 is "port the TUI from notui"
(`ROADMAP.md`, phase A). Every claim cites a notui source file by path or
names the upstream document it comes from; no line numbers, they move.

## Provenance

- Upstream: `https://github.com/CoffeeImpliesCode/notui`. Fetch it with jj:

  ```bash
  jj git clone --colocate https://github.com/CoffeeImpliesCode/notui.git notui
  cd notui
  jj bookmark track main@origin
  ```

- Port `main`. An uncommitted working copy is not a port source.
- Record the full immutable commit id of the source you port, beside the
  ported code in the consumer. Obtain it with:

  ```bash
  jj log -r main --no-graph -T 'commit_id ++ "\n"'
  ```

  A bookmark or jj change id can move. Neither is an immutable source pin.
  Re-pin deliberately and record the changed contracts in the same migration.
  Verification belongs to the pinned tree and the commands actually run;
  an old gate result does not certify a later source.

## The four-rule frame contract

Quoted once here so both sides share one text, from **pi-tui**'s `tui.ts` —
the `HistoryBatch {id, rows, kind}` channel plus viewport, written once and
acknowledged once, next to a primary-buffer renderer — and stated verbatim in
**zomp**'s design doc (`docs/zomp-design.md`).

1. A monotonic history batch id is written exactly once and then acknowledged.
2. Finality is a product decision, never inferred from a row crossing the top
   of the screen.
3. A `replay` batch is the complete logical ledger in one atomic write.
4. The renderer never probes terminal scroll position.

In notui's shape:

- **The ledger channel.** `Region.HistoryBatch` carries a monotonic `id`,
  hard-wrapped `rows` and `kind: append | replay` (`src/region.zig`).
  `writeHistory` queues it and rejects a repeated id (`DuplicateHistoryId`);
  `acknowledgeHistory` releases a batch once the transport has taken its
  bytes and `acknowledgeDrained` acknowledges everything just accepted;
  `try historyPending()` reports retained ids without treating allocation
  failure as an empty ledger; `historyWatermark` is the highest accepted id,
  not a pending count. `writeTranscript` assigns an id to an append delta. A replay
  uses `writeHistory` with `kind = .replay` and supplies the complete ledger,
  never a viewport-derived subset. A stream may accept the transaction in
  parts; ordering is preserved and DEC 2026 gives visual atomicity where supported.
- **Write once, then acknowledge.** A frame is staged as one contiguous
  transaction in `src/output.zig`: short writes and `WouldBlock` keep the
  remaining bytes in order, no frame interleaves inside it, and nothing is
  recomposed merely because the reader is slow.
- **The app-facing path.** Transcript content is queued above the band:
  `Context.appendAbove` (`src/context.zig`), `Cmd.println`
  (`src/command.zig`), `Region.append` with `Append.line` (one exact row,
  known anchor shift) or `Append.text` (the terminal decides the rows, so the
  anchor is re-queried) — `src/region.zig`.
- **Finality is the app's.** `transcript.Transcript` moves a live block
  `active → settled → committed` by product decision (`push`, `settle`,
  `retire`, `sealDelta`, `commitReceipt`), never because a row crossed the top
  of the screen. The
  renderer asks the terminal only for its cursor position (`ESC[6n` →
  `Event.cpr` → `Region.applyCpr`), never for scroll position
  (`src/region.zig`, `src/emit.zig`).

## Stable port surface

`STABLE` = safe to port against, used as-is. `INTERNAL` = free to change
without notice; never depend on it. (Roadmap item A2.)

| Type | Status | What a port must preserve |
|---|---|---|
| `buffer.Buffer`, `cell.Cell` | STABLE | `draw` returns columns consumed and never writes past `width`; `renderDiff` writes SGR only when the emitted style changes and emits no text for wide-glyph continuations; `renderAll` erases each row at column 1 first. A cell's grapheme slice is borrowed, never copied — drawn text must outlive the frame. `src/buffer.zig`, `src/cell.zig` |
| `region.Region` | STABLE | A fixed logical-height band in the main buffer. Seven strategies: first, ledger, resize, physical, height, collapse, diff. Idle frames emit zero bytes. `resize` records visible terminal rows separately from logical band height. Queued append slices stay borrowed until a successful flush, which can be deferred indefinitely; `writeHistory` copies them. `prev` owns graphemes but borrows hyperlink bytes. `exit` parks below the band; `deinit` releases memory. `src/region.zig` |
| `app.App(Model)` | STABLE | Model contract is `Msg` / `init` / `update` / `view`, with optional resource `deinit`. Failed startup rolls back runtime acquisition. `send` propagates allocation errors. Timers deliver the `msg` stored in the command, with no required Msg tag name. The app owns terminal teardown and fixed-capacity output staging; `frameHeadless` takes a transport. `src/app.zig` |
| `view.View(Model)` | STABLE | A `draw` callback that paints into `ctx.buf`, not a description of the frame; the declarative fields (band height, mouse, cursor visibility, title, print-above) are diffed against the previous frame. There is no alt-screen field: the frame is always inline. `src/view.zig` |
| `command.Cmd(Msg)` | STABLE | The effect vocabulary `update` returns; borrowed slices are never freed by the framework, and effects run before the frame renders. `src/command.zig` |
| `context.Context` | STABLE | Session-lived `frame_arena` and per-tick `scratch_arena` have different lifetimes. Drawn strings must remain live through render; scratch cannot supply retained cell text. `region` is a borrowed framework view. `src/context.zig` |
| `event.Event` with `Key`, `Mouse`, `Pos`, `Winsize`, `Capability` | STABLE | Direct `Parser.parse` paste results use its supplied allocator; `Reader` paste/key text borrows scratch until the next read call. Ground key text can borrow input, CSI text parser storage. Copy retained events. Route `cpr` to `Region.applyCpr`. `src/event.zig`, `src/Key.zig`, `src/Mouse.zig` |
| `component.*` | STABLE | Components paint cells, not ANSI. `Text` and `Suggestions` take an allocator and required caller scratch; others use their documented draw signatures and return units. `advance` reports animation changes. Cell text and hyperlinks must stay live through emission; mutable editor state uses its stored allocator. `src/component/root.zig` |
| `style.Style`, `color.Color`, `color.ColorProfile` | STABLE | `Style` merges per field with null inheriting; `Color` downsamples to the detected `ColorProfile` (`ansi` / `ansi256` / `truecolor`). Components and buffers set these; they never write escape bytes themselves. `src/style.zig`, `src/color.zig` |
| `width` seam (`strWidth`, `graphemeWidth`, `firstGraphemeLen`, `wrap`, `truncate`, `toUpper`) | STABLE | The single point where Unicode width and grapheme knowledge enters the library. A port may replace the backend, but must keep the seam single and grapheme-safe. `src/width.zig` |
| `tty.Tty`, `input.Reader` | STABLE | Session lifecycle: raw mode, winsize, panic-safe restore; `Reader` holds back a trailing incomplete escape so a sequence split across reads does not leak into the stream. `src/tty.zig`, `src/input.zig` |
| `image.kitty` | STABLE (optional) | Transmit / place / delete over APC-G. `Region.placeAt` requires a measured usable anchor and returns `error.AnchorUnmeasured` without output otherwise. Images and terminal cache ids are caller-managed. `src/image.zig` |
| `output.OutputQueue` | STABLE | The backpressure seam: every byte a frame produces is staged in one fixed buffer, so a frame reaches the terminal as one contiguous write attempt, pending bytes stay bounded by `Options.capacity`, and `canCompose` is the signal to stop composing and retry. A frame that does not fit is refused (`frameOverflowed` / `abortFrame`), never truncated. `src/output.zig` |
| `Region.HistoryBatch`, `transcript` | STABLE | Region owns write-once batch ids and acknowledgements; transcript owns product-driven retirement, not terminal position. `src/region.zig`, `src/transcript.zig` |
| `keybindings.Keymap`, `component.fuzzy`, `theme.Theme`, `markdown` | STABLE | Matching and hints use one binding declaration; fuzzy ranks Unicode grapheme subsequences; semantic theme tokens resolve through the selected `ColorProfile`; Markdown produces styled rows through the shared control/escape sanitizer. `src/keybindings.zig`, `src/component/fuzzy.zig`, `src/theme.zig`, `src/markdown.zig` |
| `caps.Capabilities` | INTERNAL | The flags are consumed by the app wiring, but probe order, query strings and the restore sequence may change. Consume `color` (a `ColorProfile`), `sync_output`, `kitty_keyboard`, `bracketed_paste`; do not depend on the rest. `src/caps.zig` |
| `emit` helpers, `Parser` internals | INTERNAL | Escape constants, small ANSI writers and the decoder's `parse` shape are free to change; call through `Region` / `Buffer` / `Reader` instead. `src/emit.zig`, `src/Parser.zig` |
| `view.Modes`, `view.signature`, `view.applyModeDiff` | INTERNAL | The idle-frame skip hash and the mode diff belong to `App`. `src/view.zig` |
| measurement only | INTERNAL | The SIMD rasterizer used by `examples/formula_tui.zig`, the loop watchdog, the read-only TCP frame snapshot and the golden-frame harness exist to measure and test notui, not to be ported. `src/coverage.zig`, `src/watchdog.zig`, `src/debug_server.zig`, `src/testing/frame.zig` |

## What a port must not do

- **Switch to the alt screen.** The renderer owns a band in the main buffer
  so scrollback survives, and the port surface has no alt-screen path to
  reach for: no alt-screen field on the frame declaration, no alt-screen
  effect, no smcup/rmcup writer (`src/view.zig`, `src/command.zig`,
  `src/emit.zig`).
- **Emit a screen-wide erase.** Nothing in `src/` emits ED2 (`ESC[2J`). The
  only erases are ED0 from the band top downward (`ESC[J`, the `append`
  resize mode and the append-flush path) and EL (`ESC[K`) scoped to one row:
  the diff render, the full repaint, the `rebuild` and `preserve` resize
  modes, the height-shrink walk and the stale high-water rows (`src/region.zig`,
  `src/buffer.zig`). The first frame and a band collapsed to zero rows erase
  nothing. tmux and the Windows conhost archive an erase into scrollback
  instead of discarding it, so **ED2 before ED3**: a display erase must
  precede the scroll-region erase, never follow it.
- **Probe terminal scroll position.** The renderer re-anchors with a Cursor
  Position Report (`ESC[6n` → `Event.cpr` → `Region.applyCpr`) and otherwise
  tracks rows itself (`src/region.zig`, `src/emit.zig`). It never asks where
  the viewport starts, and never derives ledger state from screen position
  (frame-contract rule 2).

## Flicker rules

**The paint envelope** — one frame, one write, four things in order:

1. Hide the cursor for the interactive session (`ESC[?25l` at the first frame,
   `ESC[?25h` on exit; `Region.setCursorHidden` drives it mid-session) —
   `src/region.zig`, `src/emit.zig`.
2. Disable autowrap, DECAWM (`ESC[?7l` … `ESC[?7h`) around the frame: a write
   into the last column under autowrap defers a wrap and scrolls the band out
   from under its own anchor. Bytes: `emit.autowrap_off` / `autowrap_on`
   (`src/emit.zig`).
3. Wrap the frame in synchronized output, DEC 2026 (`ESC[?2026h` … `ESC[?2026l`)
   when the terminal advertises it (`caps.sync_output`, `src/caps.zig`).
   `Region.Options` keeps `interactive` and `sync_output` separate for
   exactly this reason: a terminal that is interactive but lacks DEC 2026
   still gets the cursor, autowrap and anchoring, only without the wrap.
4. One write per frame: mode diff, `View.draw`, the band repaint and any
   history batch are composed into the staging queue and leave as a single
   write attempt (`src/output.zig`, driven from `src/app.zig`).

**Settled content** is handed to the terminal once and never repainted:

- A settled batch is transcript. It is written above the band
  (`Region.append`, `Context.appendAbove`, `Cmd.println` — `src/region.zig`,
  `src/context.zig`, `src/command.zig`), acknowledged once its bytes are
  accepted, and never part of a later frame. A `.line` append is one exact row
  (known anchor shift); a `.text` append is wrapped by the terminal, so the
  anchor is re-queried next frame.
- Retirement is the app's decision, never a screen-position inference (rule 2).
  A diff frame repaints only changed rows; a frame with nothing changed emits
  zero bytes (`Buffer.renderDiff`, `Region.render`).

## Where to read notui, in order

1. `src/app.zig` — the loop, the render decision, the teardown order.
2. `src/region.zig` — the band, the seven strategies, the anchor, the queue.
3. `src/buffer.zig` — cells, `draw`, `renderDiff`; then `src/view.zig`,
   `src/context.zig`, `src/command.zig` for the model contract.
4. `src/output.zig`, `src/transcript.zig` — one write per frame, the
   acknowledgement, replay, retirement.
5. `examples/framework_counter.zig` — smallest end-to-end app;
   `examples/formula_tui.zig` — heaviest.