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

### Package routes and support

This package supports native Zig 0.16.0. The manifest's `minimum_zig_version`
is a floor, not a claim about later compiler lines or every target.
Pure drawing and formula operations do not open a terminal. Terminal input,
raw mode, and pipe capture require native POSIX descriptors and a compatible
live `std.Io` provider; replacing `Io` does not replace direct POSIX calls.
There is no C ABI or mirrored-header contract.

Add the module you use to your own build graph:

```zig
const dep = b.dependency("notui", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("notui", dep.module("notui"));
```

| Registered module | Consumer import | Purpose |
|---|---|---|
| `notui` | `@import("notui")` | Toolkit namespaces listed below |
| `ztex` | `@import("ztex")` | Parse/layout/SVG facade and font context |
| `ztex.atom` | `@import("ztex.atom")` | Formula AST and packed payload codecs |
| `ztex.parse` | `@import("ztex.parse")` | Source parsing and structured diagnostics |
| `ztex.layout` | `@import("ztex.layout")` | Metrics-driven draw-list construction |
| `ztex.svg` | `@import("ztex.svg")` | Draw-list serialization |

Register each extra import explicitly; module import tables are not transitive.
For example, add `dep.module("ztex")` under `"ztex"` for the formula facade.
Its namespaces expose the types used by its signatures; the four lower-level
module routes also support direct consumers. Vendored `skript` is an example
dependency, not a toolkit export.

`zig build check` compiles toolkit, REPL, and formula test paths.
`zig build test` executes them; `zig build test-formula` isolates formula tests.
`zig build` also builds the shipped examples. Generic bodies still need a caller
to instantiate them; none of these commands certifies every possible instantiation.
`zig build docs` generates each registered root under `zig-out/docs/<module>/`.

### API repair migration

These are clean contract changes, with no legacy aliases:

- `Text.scratch` and `Suggestions.scratch` are required caller-owned lists.
  Keep a separate stable list for each component whose drawn cells coexist.
  Do not mutate or free it until rendering consumes those cells. Pass its
  owning allocator to `draw`, then deinitialize the list with that allocator.
  `StatusBar.scratch` was unused and is removed; segment text remains borrowed.
- The unused no-op `Component` template is removed. Call each concrete
  component's `draw`; its declaration gives the allocator and return unit.
- `width.fitPrefixLen` returns a borrowed prefix boundary without allocation.
  Components and `width.truncate` use the same grapheme-budget rule.
  The component helper is removed. Formula boxes use `num_children == 0`
  to identify a leaf; the unused `null_child` index sentinel is removed.
- `Cmd(Msg).tick` takes `{ delay_ms, msg }`; `every` takes `{ interval_ms, msg }`.
  The runtime delivers that explicit message. A timer-free `Msg` needs no
  `.tick` member. References inside a scheduled message remain caller-owned.
- `App.send` and `Region.historyPending` return allocation errors.
  Use `try` or handle `error.OutOfMemory`; failure is not a dropped message
  or a false empty ledger. Pending-id results borrow query storage.
- `View(Model)` uses `Model.DrawError` when declared, otherwise
  `std.mem.Allocator.Error`. A custom paint error must be in that closed set;
  unconstrained `anyerror` callbacks are not supported.
- `App.start` rolls back runtime acquisition on failure. Optional
  `Model.deinit(self, gpa)` releases successfully initialized model resources.
  `App.deinit` is idempotent for the same instance, not for copied owners.
  Restart clears the heartbeat, pacing samples, and frame statistics.
  The configured watchdog budget survives disposal and restart.
- `Region.placeAt` returns `error.AnchorUnmeasured` without output when its
  absolute anchor is unusable. Route CPR replies through `applyCpr` first.
- `Region.writeTranscript` returns `error.HistoryIdExhausted` if the accepted
  history id is already `maxInt(u64)`. Zero-row deltas still carry block receipts.
- `Buffer.rowFootprint(gpa, y, wide_columns, null_gaps)` puts the tape allocator
  before the row index, like the other allocating Buffer operations.
- Kitty image transmission rejects zero geometry or empty PNG payloads with
  `error.DegenerateImage`, and wrong-sized raw pixels with `error.ImageSizeMismatch`.
  Both checks precede output. Placements with zero cell extents return `error.CellOutOfRange`.
- `ztex.Context.init(gpa, io)` and `FontContext.init(gpa, io)` borrow a live
  caller provider for font discovery. Keep it and `gpa` live until one disposal.
  `FontContext.metrics` retains a face's pointer identity in its cache.
  Keep an external face alive, unmodified, and at a stable address until context disposal.
  `ztex.render` with static metrics remains I/O-free.
- `ztex.parse.Info.span` is optional. Depth failures carry `.depth_exceeded`;
  allocation failures carry `.out_of_memory` with no source span.
  The diagnostic is filled on every parse failure and untouched on success.
- `component.editor` publishes `Editor`, `Options`, `Error`, and the default limits.
  `component.Editor` remains the existing short type route.
  Setting a history depth to zero stops new recording, not access to retained entries.
  Editing errors preserve logical text and cursor, but can end an edit sequence.
  A failed yank can invalidate an old text borrow after a successful buffer growth.
- A zero `Spinner.interval` or `AnimatedText.interval` acts as one nanosecond.
  Their `advance` result means an interval elapsed, including a complete frame cycle.
- `Region.Options.width_policy`, `Capabilities.WidthPolicy`, and `widthPolicy` are removed.
  Remove those settings and calls. Toolkit widths use `zg` Unicode 16 data.
  Terminal `unicode_core` detection remains informational.
- Formula and coverage quadratic curves now have an `extern` representation:
  `p0`, `p1`, `p2`, each `[2]f32` in `[x, y]` order.
  Existing casts remain zero-copy. `FontFace.glyphOutline` accepts a const face.
- A Markdown highlighter uses the supplied arena or static storage for replacement slices.
  Keep replacements valid through the returned block's lifetime. Hyperlinks remain caller borrows.

The owning declarations document callback reentry, failure residue, option
defaults, and slice invalidation. Copies of storage owners share resources;
they are not a second disposal obligation. `Buffer` borrows drawn graphemes
and style hyperlinks. `Region.prev` copies graphemes but still borrows hyperlink
bytes until a successful replacement snapshot or disposal.

### API repair decisions

This is the `evolve` branch: change the supported contract and migrate its callers
without compatibility shims. The working-copy repair starts from
`34c238162fe984db60e9708c3d8092ba6cc4c7f7`; that is a baseline, not a commit of
the result. Scope: the six registered native roots above, on Zig 0.16.0.

These are this repair's contextual judgments, not recovered historical motives.
Their taste grade is **analyst-inferred**, attributed to the implementing assistant:

- **Caller scratch:** prioritize independent components in one frame because cells
  retain drawn bytes. Callers hold separate lists, pass their allocators, and free
  each list after its last frame. Per-component owned storage would win for an
  application that wants self-contained, long-lived component instances, at the
  cost of an allocator and disposal lifecycle per instance.
- **Explicit timer messages:** prioritize model-independent timers because each
  model defines its own `Msg`. Callers supply the payload and keep its referenced
  data live until delivery or session end. A conventional `.tick` message would
  win for homogeneous models that all use the same timer meaning.
- **Stored font `Io`:** prioritize repeated discovery through one live provider.
  The font context borrows that provider and the allocator through disposal.
  Passing `Io` per operation would win when callers must change providers between
  lookups; it adds plumbing to each lookup instead of a context-lifetime obligation.
- **Closed paint errors:** prioritize a declared failure contract for typed model
  callbacks. Models with custom paint errors declare `DrawError`. A catch-all would
  win for unconstrained plug-in callbacks, but would no longer declare which errors
  this typed framework can return.
- **Allocator order:** prioritize consistency with the allocating Buffer operations.
  Footprint callers move `gpa` before `y`. Geometry-first order would win for an API
  that uniformly groups positional arguments before operation capabilities.
- **Editor namespace:** prioritize nameable configuration and error types without flattening
  the component root. Callers use `component.editor.Options` and `.Error`.
  Root-level names would win for a small library without component-specific namespaces.
- **One width source:** prioritize a contract that matches actual toolkit geometry.
  Callers remove an option that never affected width calculation.
  A selectable width policy would win when terminal-specific widths are implemented
  across measurement, wrapping, and painting. That implementation does not exist here.
- **Curve representation:** prioritize the existing zero-copy formula-to-coverage path.
  Callers keep the declared field order and `[x, y]` coordinates.
  Explicit conversion would win for incompatible foreign layouts, but adds work here.
- **Zero animation interval:** prioritize a defined result for a publicly mutable interval.
  Zero means one nanosecond, with no new error channel.
  Treating zero as disabled would win for an API that uses its interval as an enable switch.

Rollback, exact allocation release, diagnostic residue, geometry validation, and
borrow validity are **safety-fixed obligations**, not competing style preferences.
Zig copies do not create independent ownership or enforce exactly-once disposal.

### API repair verification

**Runtime observation, native Linux x86-64, Zig 0.16.0:** 801/801 tests passed in
Debug and ReleaseSafe: 757 toolkit, 15 REPL, and 29 formula tests.
`zig build test check docs install` completed 81/81 steps.
`zig build test check -Doptimize=ReleaseSafe` completed 47/47 steps.
The ReleaseSafe example build completed 60/60 steps. Formatting passed for toolkit,
example, and formula sources. AST checks passed for 71 files; zlint passed for the
56-file non-vendor analyzer scope.
The counter and statusline emitted the same plain frames in Debug and ReleaseSafe.
The formula's 30-by-12 fraction raster matched in Debug, ReleaseSafe, and ReleaseFast.

An external consumer imported all six roots and ran in Debug and ReleaseSafe.
It exercised allocator failures and exact release, independent component storage,
history receipts including zero-row blocks, formula diagnostics and SVG output,
caller-owned font `Io`, explicit timers, fallible send, and model disposal.
A PTY run observed failed startup restoring the original termios and releasing
the runtime. Rendered component smoke covered the widest labelled Progress,
filtered selection, and an oversized aligned Text marker.
The shipped counter emitted its plain frame. The ReleaseFast benchmark's ten
case invariants and real App/TCP snapshot path passed; this was integration proof,
not a controlled performance comparison.

The boundary consumer passed in Debug, ReleaseSafe, and ReleaseFast. It checked
retained Editor history, allocation-failure residue, and rendered text.
It also checked zero and maximal elapsed animation intervals, malformed DECRPM
consumption, a const font outline, and zero-copy curve rasterization.
The highlighter returned both static and arena-backed replacements, including
language, URL, and hyperlink data. Both results matched the consumer's expected bytes.

**Exercised compilation:** both `anyerror` and non-error `Model.DrawError`
declarations were rejected by their intended guards. All six registered roots
generated documentation. An external caller named `Buffer.RowFootprint` and its
`NullGap`, then called the allocator-first footprint API.

**Analyzer assessment, refreshed 2026-10-13 at `22e88c5cbd8b`:** all 126 diagnostic
occurrences were reviewed. There are 75 false positives and 51 intentional test
assertions. No reported finding exposed a confirmed runtime defect.

| Analyzer report | Count | Assessment |
|---|---:|---|
| ziglint: public type exposure | 4 | `Buffer.RowFootprint` is public |
| ziglint: incomplete disposal | 1 | Test fixture frees its buffer and retains its observation counter |
| zwanzig: optional unwrap | 109 | 58 guarded or constructed values, 51 intentional test assertions |
| zwanzig: resource store | 11 | Arena-owned allocations, a loop-scoped `defer`, and test helpers closing raw descriptors |
| zwanzig: identifier style | 1 | `View.DrawError` is a type alias |

The unwrap assessment relies on documented lifecycle and non-reentry contracts.
It does not cover arbitrary mutation of runtime fields or every possible consumer.
[`ANALYZER-TRIAGE.json`](ANALYZER-TRIAGE.json) records every occurrence and its
source evidence, including the duplicate ziglint report. The tools were ziglint
`0.5.3-1+66709a4` and the 2026-10-05 build of zwanzig `0.15.1` (Zig 0.16.0
frontend) with `--max-states-per-point 2000`. At the default limit of 50, zwanzig
stops on `Region.render`, `caps.detectWithTimeout` and two coverage tests; at 2000
they complete and add no finding. That build no longer reports 18 sites of the
previous ledger (12 identifier-style, 4 optional-unwrap, 1 unreachable-code,
1 swallowed-error); the ledger's `integration_note` lists their ids.

A live sanitizer probe rejected an invalid cluster after its valid prefix advanced
the escape state. `Sanitizer.acceptCluster` now documents this residue. Its behavior
is unchanged and matched the copying sanitizer on the probe input.

**Verification limits:** `zig-gate --no-cross --no-zbc` still exits 1 on these
reviewed reports. No warning was suppressed and no global analyzer was changed.
A previous serial `zbc --jobs=1` attempt crashed in its binding cache with exit 134.
There is no completed current zbc verdict.

No cross-target or other compiler-line execution is claimed. Generic coverage is
limited to reached consumers, and generated doc navigation was not browser-tested.
The working-copy evidence is `zig-out/visual/api-contract-repair/verification.json`;
that local verification artifact is not part of the published package.


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
| `parser` | terminal input decoder (kitty keyboard, OSC, paste, CPR); the paste allocator is optional |
| `tty`    | Blocking input, independent nonblocking output, raw mode, winsize, panic restore |
| `caps`   | live capability detection (best-effort queries, no terminfo) |
| `buffer` | cell grid: `draw`, `renderDiff` / `renderAll` (style-tracking, wide-safe) |
| `region` | Inline renderer: seven strategies, acknowledged history batches, resize modes, anchoring |
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

Allocator-first APIs:

- `markdown.Highlighter`: `fn(arena, ctx, lang, lines) Error!void`.
- `frame_testing.Harness.init(gpa, io)` and `Session.init(gpa, io, opts)`.
- `Harness.readGolden(gpa, name)`.
- Transcript retirement data is `transcript.Delta`, not `Transcript.Delta`.

### Contracts callers must read

- `Parser.parse(input, paste_allocator: ?std.mem.Allocator) !Result`. The
  allocator is optional and `null` is a supported value, not an error
  path: a **complete** OSC 52 sequence is still consumed byte for byte
  and yields no event, an incomplete one consumes nothing (`n == 0`) so
  the caller can feed the same prefix again, and whatever key the
  terminal sent after it parses normally.
  [`src/Parser.zig`](src/Parser.zig).
- `Region.resize(columns: u16, terminal_rows: u16, logical_band_height: u16) !void`
  (`src/region.zig`). `terminal_rows` is what the
  terminal **visibly** has (`winsize` rows); `logical_band_height` is the
  band the app wants. `terminal_rows` 0 records no viewport, and only
  `resize` records one. `Region.setHeight(new_height)` stays LOGICAL only.
  See [Physical height changes](#physical-height-changes).


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

### Physical height changes

A terminal loses rows without the app asking. A resize makes the screen
shorter, the terminal keeps the cursor's line, and the top of the band
scrolls into scrollback. No relative cursor move reaches those rows
again, so a diff computed against `prev` — which still holds their text —
paints from a screen that no longer exists.

`resize` records that it happened and the next frame takes the `physical`
strategy (`src/region.zig`) instead of diffing:

- the walk up to the re-based band top stops at
  `min(painted_rows, terminal_rows)` rows, so no byte reaches a row above
  the band and the transcript is never touched;
- the band re-anchors on the cursor and repaints **every surviving row**,
  not just the ones `prev` disagrees about;
- the rows the band gives up while the screen still shows them are
  blanked, so they cannot linger as settled content.
- clipped prefix rows remain tracked as **retired**, not committed history. On growth they
  can return from scrollback above the live band. After a fresh CPR establishes which rows
  are visible, a subsequent frame erases only the retired rows with EL and returns the
  cursor to the band bottom. Committed rows and blank gaps retain their positions.

The physical path does not clamp the new logical height. `resize` takes
the band height the app asked for; how much of it fits is the app's
decision. The REPL spends what is left after its input and status rows on
the popup with `bandHeight(term_rows, popup_rows)`
([`examples/skript_repl.zig:92`](examples/skript_repl.zig)); an example
with a fixed band height can still ask for more rows than a short
terminal has, and the band is then simply taller than the screen.

Height changes coalesce. `setHeight` and `resize` both settle on the net
difference from the extent already on screen, so a run that shrinks and
regrows a band between two renders (a popup opening and closing inside
one tick) owes nothing, and a run that returns to the extent on screen
emits no bytes at all.

### Erase discipline and multiplexers

No strategy emits screen-wide ED2 (`ESC[2J`) or ED3 (`ESC[3J`).
All display erasure begins at the band anchor or is scoped to one row:

| Strategy | Erasure and movement |
|---|---|
| First frame | Reserve the band with CRLF when configured; append rows without erasure |
| Physical height change | Re-anchor on the cursor, repaint every surviving row, blank the rows the band gives up |
| Height-only change | Reserve added rows or EL removed rows, then diff; collapse to zero erases nothing |
| History/append flush | ED0 from the band anchor, emit history, repaint the live band |
| Width change / forced redraw | `append`: anchored ED0; `rebuild`: row-local EL full repaint; `preserve`: row-local EL diff |
| Normal diff | EL on changed rows; erase stale high-water rows within the old band |

tmux and conhost can archive display erasure into scrollback. A caller that
owns a separate full-screen policy must order ED2 before ED3; notui emits
neither and never clears above its anchor. DEC 2026 support changes only
the paint wrapper, not the renderer's interactive mode.

`emit.appendLines(w, n)` reserves `n` rows with `n` CRLFs, and `n == 0` emits
nothing. CSI `n E` cannot do that job: a cursor-down move stops at the last
visible row, so CNL reserves nothing once the band grows while it sits on the
screen's last row. LF at the bottom scrolls instead, so the screen gives up rows
at the top and the committed transcript above the band lands in scrollback.

**Width-reflow limitation:** xterm can split and merge existing hard rows when its width changes,
even with DECAWM disabled. That moves rows relative to the cursor without notifying `Region`.
The cursor-relative band anchor can then miss old live rows, leaving stale content above it.
The native probe in `zig-out/visual/stress/native-reflow-evidence.json` reproduces that movement
without notui. It establishes the emulator behavior; it does not excuse the renderer's anchor
assumption. Height-only coalescing is repaired separately from this width-reflow limitation.
Height restoration is repaired independently of width reflow. The old
[`postfix-height-evidence.json`](zig-out/visual/final-qa-complete-1790888329357/postfix-height-evidence.json)
shows four uncommitted popup-prefix rows that the shrink moved into scrollback and the
growth returned above the live band. The existing retirement ledger now reclaims them,
without ED2/ED3 or erasing committed transcript. The independent native model exercises
97×28 → 97×6 → 97×28 with both default and declared-native profiles, proves that the
archived prefix actually returns to the viewport, and checks one copy of every live row
and committed marker after cleanup.

The 2026-10-13 ttyd/Chromium capture validates that same round trip with the current static
REPL in both profiles:
[`resize-evidence.json`](zig-out/visual/height-restore-2026-10-13/resize-evidence.json)
records the declared-native run;
[`default-height-evidence.json`](zig-out/visual/height-restore-2026-10-13/default-height-evidence.json)
records the default run, all 36 history markers exactly once at every checkpoint, the
third candidate still selected, one restored input/popup/status group, and exit `rc=0`.
[`height-summary.json`](zig-out/visual/height-restore-2026-10-13/height-summary.json)
identifies the default run's archived input at buffer row 41, four rows above the short
viewport, and its removal on restore while the live input remains at buffer row 45.
The cleanup is not instantaneous: until a fresh post-resize CPR arrives, the renderer
cannot safely address those rows and leaves them tracked rather than guessing.

Logical band-height changes do not have the same graphics-anchor risk.
`Region.anchorRow()` derives the band top from the tracked cursor and the painted band extent.
The byte regression `region: graphic placement follows the band buffer row through height changes`
checks `placeAt` before and after growth and shrink through both `setHeight` and same-width `resize`.
It checks exact CUP/APC bytes with and without viewport scrolling, cursor restoration,
row-scoped shrink erasure, preserved history, and a byte-empty idle frame.
Existing placements [scroll with the text](https://sw.kovidgoyal.net/kitty/graphics-protocol/)
under the kitty protocol. This byte test does not replace a live graphics-terminal UI pass.


## Local scratch storage

Bulk temporary files and caches belong on a local scratch volume with room to
spare, not on NFS or a small system temporary filesystem. `devenv.nix` reads the
root from `NOTUI_SCRATCH_ROOT`, falling back to `$HOST_SCRATCH_ROOT/notui`, and
refuses to evaluate without one. Under it, the shell keeps `zig-global/`,
`zig-local/` and `zig-pkg/`; the repository's `zig-pkg` is a symlink to the
latter, re-pointed on every shell entry because the volume is per host. Zig 0.16
always unpacks packages into project-local `zig-pkg/`, and on NFS that fails with
`illegal file type 'unknown'` because readdir reports no file type there.

Clean up periodically during work, after capture/build waves, and before handoff. Review
ownership and live use first. Remove only our inactive caches and throwaway probes; preserve
source, active/shared caches, and necessary screenshots, recordings, and reports.


## Terminal screenshots

The devenv shell includes VHS, termshot, Freeze (`freeze`), ttyd and FFmpeg.
VHS uses headless Chromium, supplied by its Nix package; notui does not
require a browser. The shell supplies Fontconfig configuration with DejaVu,
Noto CJK, and Noto color emoji fonts for reproducible captures, plus the Latin
Modern text and math faces that the vendored ztex tests load from disk.

```bash
devenv --no-tui shell -- zig build
mkdir -p zig-out/visual
devenv --no-tui shell -- vhs examples/framework_counter.tape
```

The tape runs the real counter app, waits for count `0`, increments to `3`,
decrements to `2`, then quits. Inspect `counter-initial.png`,
`counter-updated.png` and `counter-exit.png` in `zig-out/visual/` to check
the frame, preserved scrollback banner and successful exit marker.
The same directory contains `counter.gif`.

### Visual stress captures

These recipes drive real example binaries through a ttyd PTY and Chromium.
They save images for manual inspection, not automated visual verdicts.
Each VHS checkpoint settles before capture because xterm's buffer can precede its canvas paint.

```bash
devenv --no-tui shell -- zig build
mkdir -p zig-out/visual/stress
devenv --no-tui shell -- vhs examples/visual_unicode.tape
devenv --no-tui shell -- vhs examples/visual_statusline_wide.tape
devenv --no-tui shell -- vhs examples/visual_statusline_narrow.tape
devenv --no-tui shell -- vhs examples/visual_editor.tape
devenv --no-tui shell -- vhs examples/visual_repl_multiline.tape
```

| Recipe | PNGs | Checkpoints |
|---|---:|---|
| `visual_unicode.tape` | 10 | Unicode, deletion, clipping, wrapping, overflow, exit |
| `visual_statusline_{wide,narrow}.tape` | 8 | Status bar, changing gauges, exit |
| `visual_editor.tape` | 23 | Completion, Unicode/cursor edits, history, exit |
| `visual_repl_multiline.tape` | 8 | Continuation, syntax colors, result `60`, history, exit |
| `visual_resize.js` | 16 | Live width/height resize, numbered history, short-terminal popup, exit |

All 65 PNGs are in `zig-out/visual/stress/` — that is the 2026-10-01 baseline, kept
exactly as it was captured, defects included. The repaired pass is a separate directory;
see [Post-repair deep QA](#post-repair-deep-qa-2026-10-0102). VHS also saves GIFs there.
Inspect every checkpoint, including bad frames. Successful capture does not mean correct rendering.
The recipes retain defects instead of waiting indefinitely for ideal text.
VHS control chords use lowercase letters. Its `Wait+Line` reads the current cursor row.
Its `Wait+Screen` can read old scrollback after overflow, so these tapes do not use it.

For live resize, start ttyd from the repo root in a separate terminal:

```bash
devenv --no-tui shell -- ttyd -i 127.0.0.1 -p 17789 -W \
  -t rendererType=canvas -t 'fontFamily="DejaVu Sans Mono"' -t fontSize=20 \
  -t cursorBlink=false -t scrollback=20000 -t disableResizeOverlay=true \
  -t disableLeaveAlert=true -t disableReconnect=true bash --noprofile --norc
```

Start Chromium from the same font environment in another terminal.
This command uses the nixpkgs revision recorded in `devenv.lock`:

```bash
devenv --no-tui shell -- \
  nix run github:NixOS/nixpkgs/54ba4bcec4043e72a4006d825e0d7aff5562008f#chromium -- \
  --headless --remote-debugging-address=127.0.0.1 --remote-debugging-port=17790 \
  --user-data-dir="$TMPDIR/notui-resize-chromium" --no-first-run \
  --no-default-browser-check --disable-dev-shm-usage about:blank
```

Run this JavaScript from the repo root through the managed `browser` handle:

```javascript
const { runResizeStress } = await import(`${process.cwd()}/examples/visual_resize.js`);
const report = await runResizeStress(browser, {
  baseUrl: 'http://127.0.0.1:17789',
  outputDir: 'zig-out/visual/stress',
  app: { cdp_url: 'http://127.0.0.1:17790' },
});
await Bun.write(`${report.outputDir}/resize-evidence.json`, JSON.stringify(report, null, 2));
display(report);
```

The driver changes the real viewport. xterm fits the grid and ttyd delivers SIGWINCH to the app.
The report records actual columns, rows, screen text, cursor, and retained history.
It reads `window.term` through the page main world, not an isolated `page.evaluate`.
The driver releases managed tabs. Stop both services after capture.

### Temporal capture

`runTemporalStress` is the same driver asking a different question. It hooks the real
`window.term.onRender` in the page main world and records every observed render event:
its text, its cell styles and the input stage in flight. Same ttyd, same Chromium:

```javascript
const { runTemporalStress } = await import(`${process.cwd()}/examples/visual_resize.js`);
const report = await runTemporalStress(browser, {
  baseUrl: 'http://127.0.0.1:17789',
  outputDir: 'zig-out/visual/final-qa-complete-1790888329357',
  app: { cdp_url: 'http://127.0.0.1:17790' },
});
display(report);
```

The driver already writes `temporal-report.json` into `outputDir`. Read
`report.checkpoints[].file` for the PNGs and `report.timelines[].file` / `.video` for the
frame log and the recording, then read every file those name.

| Scenario | PNG checkpoints | Video | Timeline |
|---|---:|---|---|
| `statusline` | 6 | `temporal-statusline.webm` | `temporal-statusline-timeline.json` |
| `repl` | 6 | `temporal-repl.webm` | `temporal-repl-timeline.json` |

Twelve temporal PNGs and two videos, alongside the sixteen geometry PNGs from
`runResizeStress`. Options beyond the geometry driver's: `scenarios` (default both,
either alone runs), `maxRenders` (default 20 000 frames), `maxBufferRows` (default 512
non-empty buffer rows per snapshot), `keyGapMs` (default 10; keys are spaced 10–20 ms
apart), `midlineCycles` (default 8) and `animationMs` (default 1500).

What a temporal run does and does not prove:

- `onRender` fires per **observed render event**, not per app write. xterm coalesces, so
  one event can stand for several writes. The count is a floor on frames — it is never a
  write log, and an app that writes twice between two paints is invisible here.
- `stages[]` is a per-input render index (`{ stage, renders, first }`) recorded for every
  key and refit the run sent, so any input is addressable by name. It marks which input
  was in flight when a render was observed; it does **not** establish which key caused a
  paint. A stage with `renders: 0` is a real observation — the input was sent and no
  render followed — and is reported rather than dropped.
- `payloads` is smaller than `renders` because consecutive identical payloads are stored
  once and the later entries point at it with `same`. It measures distinct screens, not
  distinct writes.
- Styles are run-length encoded per visible cell, blanks included, so a timeline proves
  which cells carry which attributes. It is not a byte-level record of what went out.
- The two bounds fail closed. Past `maxRenders` nothing further is captured at all; past
  `maxBufferRows` a snapshot keeps its newest rows and marks its own `bufferTotal` /
  `bufferKept` / `bufferDropped`. Either bound failing fails the scenario *after* its JSON
  is on disk and says which bound it was, so the artifacts survive the failure.
- `recordStop` is awaited with a **180 s** deadline
  ([`examples/visual_resize.js:1402`](examples/visual_resize.js)). A recording that
  outlives it fails the scenario, and the PNGs and timeline are still saved — but the
  video then proves only what was captured before the deadline.
- The video supplements the PNGs rather than replacing them: it keeps the half-drawn band
  between two refits, which a settled screenshot never shows.

One artifact in the deep-QA directory is **non-probative** and must not be read as proof
of anything. `ffprobe` reports `postfix-height-boundaries.webm` at 1200×82, and its
content does not reproduce the boundary frames the PNGs show. No mechanism for the
difference is claimed or reconstructed, and nothing about the height-boundary pass rests on
that file. The boundary proof is `postfix-popup-*.png` and `postfix-height-evidence.json`
only.

### Baseline visual findings (2026-10-01, historical, before repairs)

Historical: this subsection is the 2026-10-01 pass, kept as the "before" half of the
before/after record. Nothing in it was re-photographed and no defect listed here is
claimed gone. What the repairs changed is in
[Post-repair deep QA](#post-repair-deep-qa-2026-10-0102).

That pass covered all 65 PNGs. All eight capture sessions showed successful exits.
The live grids measured 97×28, 41×28, 41×6, and 97×6.
Product code was unchanged during that baseline. The following defects were observed before repairs:

- **Mid-line redraw:** Insert and Backspace corrupt visible digits.
  The logical query still evaluates to `42`.
  Evidence: `editor-16b-midline-insert.png`, `editor-16c-backspace-undo.png`,
  and `editor-19-answer.png`.
  The baseline drew right-side syntax segments at the same column in
  `examples/skript_repl.zig`. Its Region owned the previous frame's glyph copies
  in `src/region.zig`, so borrowed-text aliasing was not the cause.
- **Popup height transitions:** Old prompt and candidate rows survive above the collapsed input band.
  Evidence: `editor-10-esc-token-gone.png` and `editor-15-line-cleared.png`.
- **Width resize:** An old status-bar row survives both narrow and restored-wide frames.
  Evidence: `resize-statusline-narrow.png` and `resize-statusline-wide-restored.png`.
  This is a terminal-width reflow interaction, not a canvas capture race.
  [INFERENCE] xterm reflow moves old rows above the cursor-relative repaint anchor.
  This pass did not isolate library versus emulator ownership.
- **Escape dismissal:** Escape reopens the same candidates and resets selection.
  Live resize also leaves a duplicate status row.
  Evidence: `editor-09-esc-after.png` and `resize-repl-popup-dismissed.png`.
- **Short-terminal popup:** A 10-row band exceeds the six-row terminal.
  The prompt and selected candidate disappear above the viewport.
  Evidence: `resize-repl-popup-short.png`.
- **In-string completion:** Cursor movement inside a quoted string opens symbol suggestions.
  The baseline REPL prefix heuristic had no string context (`examples/skript_repl.zig`).
  Evidence: `editor-13-cursor-grapheme.png` and `editor-14-backspace-codepoint.png`.

The baseline popup residue also had a source-level cause.
Escape shrank and regrew the band before one render.
The former `Region.paintGrow` reserved the last delta, not the net change from
the painted extent. Later frames could not erase the rows left above the band.
The Escape branch lacked the suppression flag used by Tab in `examples/skript_repl.zig`.
The baseline example also ignored terminal rows during resize, causing the short-terminal defect.

Checks without observed defects:

- Native and notui Unicode rows match, including the same emoji rendering limits.
- Backspace removes the combining acute alone. These examples edit UTF-8 codepoints, not graphemes.
- Right-edge clipping, shortened-input tail removal, wrapped commits, and numbered overflow
  remain correct.
- Fixed wide/narrow status bars and changing gauge colors remain correct.
- Completion navigation and Tab acceptance work before the defective dismissal/collapse paths.
- Multiline continuation, syntax colors, result `60`, and history recall remain correct.
- The one-row prompt preserves pending Unicode text across width and height changes.
- All 36 numbered history rows occur exactly once before and after resize in `resize-evidence.json`.

The native baseline separates font/emulator limits from notui output.
The 500 ms pre-capture settle separates canvas timing from persistent product defects.

Historical, same pass: the baseline gate printed passes for format, build, unit tests,
AST checks, and zlint. It exited with code 1 because ziglint reported 1118 diagnostics,
including vendored code. The colored zlint summary was not counted correctly, and the
advisory zbc summary hid warnings. That is why the gate checks exit codes and
strips ANSI before counting — see [Gate diagnostics and zbc triage](#gate-diagnostics-and-zbc-triage).

### Post-repair deep QA (2026-10-01/02)

This is the "after" half of the record and overwrites none of it. Post-repair evidence lives in
`zig-out/visual/final-qa-complete-1790888329357/`; every bare file name below is in it.

| Phase | Evidence |
|---|---|
| before all repairs | `zig-out/visual/stress/`: 65 PNGs, `resize-evidence.json`, `native-reflow-evidence.json`, `gate-smoke-evidence.json` |
| classified pre-physical-repair | `resize-evidence.json`, `temporal-report.json`, `manual-contract-evidence.json`, `consumer-evidence-summary.json` |
| post-physical-repair | `postfix-height-evidence.json`, `postfix-live-band-summary.json` |
| before the bottom-row reservation repair | `bottom-red-ui.json`, `bottom-red-popup.png`, `bottom-red-boot.webp` |
| after the bottom-row reservation repair | `bottom-green-ui.json`, `bottom-green-popup.png`, `bottom-green-one-row-edited-restored.png` |

`resize-evidence.json`, `temporal-report.json` and `bottom-red-ui.json` record no build identity, so
their phase is classified, not proven: the basis is capture order, PNG timestamps, and the same 97×6
REPL popup broken in one file and correct in the other. Labels are not build fingerprints;
only the bottom-green smoke records its SHA-256.

#### Repairs covered

| Change | Where |
|---|---|
| `resize` records the visible row count, the next frame re-bases on the cursor and repaints every surviving row instead of diffing against `prev`, and `setHeight` and `resize` settle on the net difference from the extent on screen | `src/region.zig`, `src/Parser.zig` |
| `parse` with a null `paste_allocator` consumes a complete OSC 52 sequence without an event | `src/Parser.zig` |
| The REPL sizes its band with `bandHeight(term_rows, popup_rows)`, paints the three query spans in one scan, gives Escape the hold flag Tab uses, and gates the completion prefix on string context | `examples/skript_repl.zig` |

| Run | Result |
|---|---|
| native resize integration, Debug | `zig build test` 726/726: 711 library (including the independent native terminal model and the released/collapse retirement regressions) plus 15 REPL |
| native resize integration, ReleaseSafe | timed out after 1200 s (`zig build -Doptimize=ReleaseSafe test`); Debug-passing tree, not re-attempted in this pass |
| before the native resize integration (historical) | `663/663`: 648 library plus 15 REPL |
| before the bottom-row repair (historical) | `662/664`: 647 library pass, 2 library fail — `region: a band that grows onto the last screen row scrolls, never overwrites` and `region: a popup that fills a short screen keeps the rows it scrolls past` — and 15 REPL pass |
| before the repairs (historical) | `658/661`: one physical-height failure, two null-allocator aborts |

The two historical failures above are inside the library tests that now pass. No full-gate pass is claimed:
see [Gate diagnostics and zbc triage](#gate-diagnostics-and-zbc-triage).

#### Bottom-row band growth: before and after

A band that grows on the screen's last row cannot get room from a cursor-down move, and CRLF scrolls
instead — which is exactly what `emit.appendLines` reserves with.

Before, `bottom-red-ui.json` and `bottom-red-popup.png` record a 97×6 screen that printed
`REPRO-HIST-01` through `REPRO-HIST-36`; typing `d` opened the popup and the buffer then held
only through `REPRO-HIST-32`, the last four committed rows overwritten instead of scrolled off.

After, `bottom-green-ui.json` names its Debug binary and drives the same 97×6 screen through 6, 1
and 6 rows. All 36 `GREEN-HIST` markers survive exactly once where the red binary held 32. Escape
holds the popup closed across the 650 ms requested idle wait (742.638 ms measured); the one-row edit
keeps its text, completion resumes, and a mid-line Tab turns `(de 99)` into `(def 99)`. Exit `rc=0`.

#### Evidence and its limits

| File | Reading |
|---|---|
| `resize-evidence.json` | 16 geometry checkpoints (4 statusline, 7 prompt, 5 repl) at 97×28, 41×28, 41×6 and 97×6 tally 11 pass and 5 fail. The short viewport measured 1200×156 with 10 px of page chrome at a 24 px cell, a measurement and not a calibrated constant. Only `history-wide` and `restored-wide` carry a recorded buffer, and each of the two holds all 36 numbered history rows exactly once with both banner rows intact, so the count is an endpoint pair and not a per-refit reading; the pending Unicode line keeps its wide cells, clipped at 41 columns and byte-identical after the restore. Failing: `statusline/narrow` and `statusline/wide-restored` (a tail-less status row above the re-anchored band), `repl/popup-short` (no band input row or candidate head), `repl/popup-restored` (`diff` twice across a three-row gap) and `repl/popup-dismissed` (four candidate rows left after Escape) |
| `temporal-report.json` | 577 observed render events, 310 in `statusline` and 267 in `repl`, none dropped or truncated and both bounds far from their defaults. `stages[]` names every input and refit, including the six that produced no observed render. A render event is a floor on observed frames, not an app write. See [Temporal capture](#temporal-capture) |
| `manual-contract-evidence.json` | A real REPL over a live ttyd PTY at 97×28 on a binary that declares itself pre-repair, so it covers behavior the height repair did not change. The styled mid-line tail survives insert and Backspace, Escape holds the popup closed through an idle wait and a height round trip, Tab accepts `(de 99)` as `(def 99)` with the ` 99)` suffix intact, and `MANUAL_QA_EXIT rc=0`. The REPL paints its caret as a styled cell, so the recorded cursor parks on the band's last row and the caret is read from the inverse-attributed cell. The 650 ms idle wait comes from the driving transcript, and the JSON stores no timestamps |
| `parser-consumer-smoke.json` | A standalone program linked against the built library, not a test binary. With a null paste allocator it consumed a complete OSC 52 sequence in 16 bytes in the BEL form and 17 in the ST form, the following `Q` survived both, an unterminated prefix was retained whole, and the same sequence with an allocator decoded `hello`. Exit code 0 |
| `bottom-green-ui.json` | Names its binary (`zig-out/bin/example-skript-repl`, Debug, sha256 `3300dd00750479458e5549d74f940b8ac4ce476a2fb6b06efd4d7b626312e563`) and records every snapshot of the sequence as a buffer record — `boot`, `popup`, `selected`, `escape`, `one`, `editedOne`, `restored`, `tabBefore`, `tabAfter`, `styleBefore`, `exit` — with asserted `checks` and `exitCode 0`. Each of the 36 `GREEN-HIST` markers occurs exactly once at every one of those snapshots. The caret is a neutral inverse cell by design (`cur_style`), not a syntax-token color: the number cells keep the number foreground and the string cells on both sides keep the string foreground, so a probe that demanded the token color on the caret recorded an invalid expectation, not a regression |

`postfix-height-evidence.json` records the original 6/3/2/1/6/28 boundary run; the bottom-green
smoke independently verifies 6/1/6 after the reservation repair. The REPL ran at 97 columns: six
rows hold the input on row 0, four popup rows, `deg->rad` inverse on row 3 and the status on row 5,
and that layout returns with its selection after the 1-row state; three rows keep input, candidate
and status; two keep input and status; one keeps the input alone; twenty-eight show the archived
input on row 4 and `deg->rad` inverse on row 7 above the live input on row 8 with its selection on
row 11. Three states have no PNG, so their buffer record is the only evidence; the run ends `rc=0`.

#### Remaining risks

- **Width reflow.** xterm splits and merges hard rows when the width changes, so the cursor-relative band anchor can miss old live rows and they survive above it. The emulator half is reproduced without notui in `zig-out/visual/stress/native-reflow-evidence.json`. No width round trip was captured after the physical-height repair, so its status is untested, and `consumer-evidence-summary.json` lists it under `knownFailures`.
- **Height-restore cleanup waits for CPR.** The historical archived-popup residue is repaired
  by the existing retirement ledger, validated by the 2026-10-13 model and live captures
  above. A geometry change invalidates the old measured reach; retired rows can be visible
  until the fresh CPR is applied and the next frame runs. If a consumer never routes that
  reply through `Region.applyCpr`, cleanup cannot safely erase above the band. This is a
  bounded addressing requirement, not an emulator limitation requiring transcript erasure.
- **`postfix-height-boundaries.webm` proves nothing, and a render event is not an app write.** The 577 figure is a floor on observed frames. See [Temporal capture](#temporal-capture).
- **Analyzer coverage is bounded.** 27 unresolved import lookups limit what zbc could check, as [Gate diagnostics and zbc triage](#gate-diagnostics-and-zbc-triage) records.
- **Graphics UI coverage.** The earlier height-growth claim cited `f.anchor_add +=`,
  which the current `Region.settleExtent` does not contain.
  The byte regression `region: graphic placement follows the band buffer row through height changes`
  passes without a production change. Placement targets keep the same band buffer row through
  logical growth and shrink, including growth that scrolls the viewport.
  No live kitty graphics UI pass covers retained placements or physical resize/width reflow.

### Zwanzig baseline triage (historical)

The first full zwanzig run reported 120 findings. These counts are historical
and predate the API repair. A later pre-repair strict run reported 114 findings.
See [Gate diagnostics and zbc triage](#gate-diagnostics-and-zbc-triage) for that pass,
and [API repair verification](#api-repair-verification) for the current assessment.
The first pass had this breakdown:

| Class | Count | Triage |
|---|---:|---|
| optional | 101 | Guarded lifecycle or test premises — 56 in test code, 45 outside it. One of them was a real bug: the unguarded `Parser` null allocator, now repaired and covered. |
| identifier | 14 | 3 real, 11 false positives |
| unused | 1 | Removed |
| store | 1 | Removed |
| duplicate import | 1 | Removed |
| unreachable | 1 | Left valid, not removed: the `comptime` passing guard is not a defect |
| swallowed error | 1 | Left valid, not removed: the documented UTF-8 rejection path is not a defect |

The three real identifier findings were the `width` module's namespace (now
`unicode_width`), `lane`'s count field (now `lane_count`) and the vector type (now `Vec`).
The eleven false positives are the eight `notui.key` references in the example binaries, which
resolve the `Key` type — `@This()` in `src/Key.zig`, a type alias that must stay PascalCase — plus
the `Base64Decoder`, `Base64Encoder` and `NONBLOCK3` value aliases, which must stay lowercase.
Also removed as dead weight: `view.drawB`, an `errdefer` over `invalid`, and duplicate `Color`
imports.

The 100 optional findings that were not the parser bug are guarded lifecycle and test
premises. A valid `comptime` passing guard and the documented UTF-8 rejection path were
left alone: neither is a defect, and changing them to quiet an analyzer would be
suppression by another name. The gate's own parsing and exit-code policy is exercised
separately against stub tools and passes 14/14 under the current strict policy
(`zig-out/visual/deep-qa/gate-smoke-current.json`). That is a test of the gate harness,
not a verdict on the repository.

The zbc table below and its 27 unresolved import lookups come from the same pass and are
retained unchanged, along with the seven false-positive underflow sites and the decision
to suppress nothing.

### Gate diagnostics and zbc triage

The historical gate excluded vendored packages with `GATE_EXCLUDE='^./vendor/'`.
That pass checked 54 owned Zig files. The current analyzer assessment covers 56
non-vendor files. No lint rule was disabled.

The `zig-gate` script now checks analyzer exit codes.
It strips ANSI colors before it counts the zlint summary.
It reports zbc warnings separately from errors.
Four stub-tool smoke cases verified these decisions:

| Case | Gate exit |
|---|---:|
| ziglint cannot start, exit 2 | 1 |
| Colored zlint summary reports three warnings, exit 0 | 1 |
| zbc reports one warning, advisory mode | 0 |
| Same zbc warning, `ZBC_STRICT=1` | 1 |

Evidence: `zig-out/visual/stress/gate-smoke-evidence.json`.

The inspected full zbc report analyzed all 54 owned files without parser failures.
Its seven index-underflow warnings have the following source preconditions:

| Site | Verdict and evidence |
|---|---|
| `component/fuzzy.zig`, `extend` | False positive. Both callers have `j >= 2`. The needle bound also bounds the position array. |
| `keybindings.zig`, `Keymap.bind` | False positive. A successful `groups.append` precedes `items[len - 1]`. |
| `markdown.zig`, `Sanitizer.copy` | False positive. A valid UTF-8 sequence advances `i` by at least one before `src[i - 1]`. |
| `markdown.zig`, `Renderer` line assembly | False positive. `out.items.len != 0` guards the last-item access. |
| `markdown.zig`, test hook `run` | False positive. The hook increments `calls` before it indexes `calls - 1`. |
| `output.zig`, `stageDrain` | False positive. The Writer drain contract requires nonempty `data`. The function also asserts it. |
| `testing/frame.zig`, `Sink.drain` | False positive. The same Writer contract applies. The indexed expression also occurs inside a `data` loop. |

The Writer contract is explicit in Zig 0.16 `std/Io/Writer.zig`.
The report also records 27 unresolved import lookups.
That count limits analyzer coverage. It does not prove those imports safe.
No warning was suppressed, and no source guard was added just to change analyzer output.

Before this API repair, `zig-gate --no-cross --no-zbc` (277.12 s) passed
format, build, tests, AST checks, ziglint and zlint, then failed on the strict zwanzig stage with
114 findings: 101 `optional-unwrap`, 11 `identifier-style`, 1 `unreachable-code-engine` and
1 `swallowed-error`. `zwanzig-current-report.json` carries the raw list and
`zwanzig-current-triage.json` carries all 114 as per-site classifications with their proofs. Under
the documented contract none of them is an owned-source defect: 101 guarded lifecycle and test
premises, 11 valid names (the `Key` type the examples reach through `notui.key`, plus the lowercase
codec and flag values), the `comptime` invariant guard, and the fail-closed UTF-8 reject path.
One proposed counterexample, a headless `App.tick` panic, was withdrawn: it called
`tick` on a hand-wired headless app, which the public contract forbids.
That historical stage failed on 114 findings without suppression or a policy waiver.

Before this API repair, `zbc` ran over the 54 owned files, serial and explicit
(`zbc --jobs=1`, 35.10 s): 54 analyzed, 0 parser failures, 7 index-underflow warning
sites and 27 unresolved import lookups, exit 1 advisory. `zbc-current-summary.json` holds that
summary, the 54-file list and the seven sites. No full `zig-gate` verdict is claimed: the initial
full run hit its 600 s outer timeout, entered zbc without a verdict and never reached zwanzig.
At that stage, the installed CLI finished on a single file with
`zbc --jobs=1 src/emit.zig`; this is historical evidence, not a current verdict.

## Measurement and verification

```bash
zig build test
zig build bench -Doptimize=ReleaseFast
gate                              # zig-gate, then the same benchmark
```

Historical test totals before the API repair, in run order. `zig build` completed 58/58 steps and
`662/662` tests passed in Debug and ReleaseSafe (647 library plus 15 REPL in each) on the
tree that carried the physical-height and parser repairs. Two bottom-row tests were added
after that run, and the next `zig build test` reported 662 of 664 with those two failing.
Before this API repair, `zig build test` passed 663/663 in Debug (`zig build` 58/58 steps) and in
ReleaseSafe (44/44 steps), 648 library plus 15 REPL in each.
[Post-repair deep QA](#post-repair-deep-qa-2026-10-0102) names them and records the gate
state.

The benchmark reports p50/p99 frame time, emitted bytes per frame and
allocations per frame at 80×24 and 200×60 for static and streaming content.
Static steady-state frames must write zero bytes. Rendering allocations
are counted rather than assumed.

Historical measurement on this host (`zig build bench`, ReleaseFast, Zig 0.16;
timing floor clock p50 73 ns / p99 80 ns):

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
