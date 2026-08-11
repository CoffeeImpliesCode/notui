# TUI Architectures — Chart of the 7 Inspirations

Architecture, API surface, and feature set of every named inspiration
library, charted for `notui` design. Sources: local clones / vendored
sources, verified 2026-08-11 (7 parallel research passes, file:line refs in
each section). Companions: `notes/research/tui-landscape.md` (screen
ownership), `notes/research/zig-foundations.md` (foundational APIs).

## 1. Comparison matrix

| | ratatui (Rust) | bubbletea v2 (Go) | vaxis (Go) | Textual (Python) | pi-tui (TS) | zigzag (Zig 0.16) | libvaxis (Zig 0.16) |
|---|---|---|---|---|---|---|---|
| License | MIT | MIT | Apache-2.0 | MIT | MIT | MIT | MIT |
| Rendering model | immediate-mode, double-buffered cell grid, cell diff | Elm MUV, cell buffer, frame sized to content | cell buffer, double-buffer diff, live region | retained widget tree + CSS + z-compositor | line-array differential (`render(width)→string[]`) | Elm MUV, cursor-home repaint (screen owner) | cell buffer diff (DAM) + vxfw widget tree |
| Event loop | none in core (app-side) | channel select + goroutine cmds + fps ticker | parser goroutine → input goroutine → channel → main | asyncio MessagePump per node + input thread | Node stdin → StdinBuffer → listeners | tick(): 256B read → parse → dispatch → render-on-demand | Loop(T) 512-queue + tty thread; App 60fps deadline |
| Layout | kasuari Cassowary solver, Strength-ordered constraints | none (bubbles) | Window viewport (positional), vxfw flex / ui tree | box model, flex-like `layout_resolve` (Fractions) | alt-screen only (VStack/HStack/ScrollView); none inline | join / place / layer / flexbox | Window child()+print; vxfw constraint tree |
| State | app-owned (StatefulWidget) | Model in Elm loop | app-owned | reactive descriptors + CSS | component-owned caches | Model in Elm loop | vxfw user Model |
| Input | none in core (backend/app) | delegated to ultraviolet | own DEC parser + full kitty | own XTermParser + kitty keys | own keys.ts (kitty + legacy + modifyOtherKeys) | own keyboard.zig (kitty partial) | own Parser.zig (full kitty) |
| Styling | per-cell Style, no cascade | lipgloss (separate) | Style w/ hyperlinks, cap-gated underlines | TCSS cascade + specificity | theme = style-function objects, ANSI strings | Lipgloss-style builder + ranges | per-cell Style, SGR colon/legacy |
| Images | none (CellDiffOption interop) | none in core | kitty + sixel + half-block | no (Rich renders) | kitty + iTerm2 (env detect) | kitty/iTerm2/sixel + live probe | kitty (zigimg decode) |
| Inline mode | Viewport::Inline (cursor-anchored, append_lines) | default (frame in main buffer) | PrimaryScreen (region + append queue) | run(inline=True) (driver swap) | TuiMainScreen default (3 strategies) | none (alt_screen=false still repaints) | primary-screen path (relative moves, prettyPrint) |
| Components | 17 (Block, List, Table, Paragraph…) | none (bubbles) | none core; widgets/, vxfw, ui/ | 40+ (DataTable, Tree, Input…) | 17 (Editor, Markdown, SelectList…) | 40+ (CodeView, DataTable, form…) | vxfw 16 + specialized 10 |
| Width/graphemes | unicode-width + segmentation (deps) | go-runewidth/uniseg (indirect) | go-uucode + 3-method policy | rich.cells | get-east-asian-width | own Unicode 16 table | own gwidth over uucode tables |
| Testing story | TestBackend | — | — | HeadlessDriver | VirtualTerminal (@xterm/headless) | snapshot tests + custom I/O | TestTty + embedded VT emulator |
| Best inline precedent | cursor anchoring + insert_before | content-height frame + print-above | **append queue + live region** | :inline CSS + driver swap | 3 render strategies + width contract | (screen owner — no) | primary-screen relative rendering |

## 2. Per-library charts

### ratatui — immediate-mode cell grid (Rust)

**Architecture.** Immediate-mode over a double-buffered cell grid. Each
`draw` pass fully re-renders into the current Buffer, diffs against the
previous (`BufferDiff`, zero-alloc, wide-char/VS16 aware), writes only
changed cells, swaps. No retained widget tree; no input layer in core
(backend/app reads crossterm). Layout via kasuari Cassowary solver:
constraint priority = solver Strength ordering
(Min>Max>Length>Percentage>Ratio>Fill), results cached (LruCache 500).
Async: none in core; apps wire threads + channels.

**API.** `Viewport{Fullscreen, Inline(u16), Fixed(Rect)}` ·
`Terminal<B: Backend>{draw, try_draw, resize, autoresize, insert_before,
flush}` · `Frame{render_widget, render_stateful_widget,
set_cursor_position, area()}` · `Backend{draw(cells), append_lines,
scroll_region_up/down, cursor ops, clear_region, size}` ·
`Layout::vertical/horizontal().split(area)/areas()` ·
`Constraint{Min,Max,Length,Percentage,Ratio,Fill}` · `Flex{Legacy,Start,
End,Center,SpaceBetween,SpaceAround,SpaceEvenly}` ·
`Widget{render(self, area, buf)}` + `StatefulWidget` · `Cell{symbol, fg,
bg, modifier, CellDiffOption}`.

**Features.** Widgets: BarChart, Block, Calendar, Canvas, Chart, Clear,
Fill, Gauge, LineGauge, List, Paragraph, Scrollbar, Sparkline, Table,
Tabs + borders + symbols (braille/half-block). Styling per-cell (no
cascade); Span/Line/Text model; `WordWrapper` reflow. `CellDiffOption`
(Skip/AlwaysUpdate/ForcedWidth) interoperates with external
escape-sequence renderers (images/links). TestBackend.

**Screen ownership.** Fullscreen default; `Inline(h)`: anchored to cursor
row, full width, space reserved via `Backend::append_lines`, origin shifts
up when the terminal scrolls, cursor-relative offset preserved on resize.
`insert_before` writes lines above into scrollback (flicker-free only with
opt-in `scrolling-regions` feature). `init_with_options`: raw mode but **no
alt screen**. `Fixed` needs manual resize.

**Design gems.** (1) Viewport-as-value: layout builds from `frame.area()`,
identical code runs fullscreen/inline/fixed. (2) Constraint priorities as
solver Strengths — composable layout semantics, no ad-hoc branches. (3)
Zero-alloc cell diff + swap-buffer reset = O(changed) output. (4)
`CellDiffOption` escape hatch for image/escape overlays.

**Gaps.** No input layer; no images built-in; `insert_before` flickers
without scrolling-regions; inline is full-width only; `Terminal::clear`
clears past the viewport in inline; Fixed no autoresize.

### bubbletea v2 — Elm over channels (Go)

**Architecture.** Elm MUV with full message passing. `Msg = uv.Event`
(input parsing fully delegated to ultraviolet); `Cmd = func() Msg` runs on
goroutines (Batch concurrent, Sequence serial, Tick/Every timers). Central
eventLoop: select → translateInputEvent → optional filter → special-msg
switch (quit/interrupt/suspend/capabilities/mouse/printLine) → `model.Update`
→ `p.render`. FPS render throttle (default 60, cap 120). `Program.Send`
injects external messages.

**API.** `type Model interface { Init() Cmd; Update(Msg) (Model, Cmd);
View() View }` · `NewProgram(model, opts...)` · `Run()` · `Send()` ·
**`View` struct** `{Content, OnMouse, Cursor, Background/ForegroundColor,
WindowTitle, ProgressBar, AltScreen bool, ReportFocus,
DisableBracketedPasteMode, MouseMode, KeyboardEnhancements}` ·
`Batch/Sequence/Every/Tick` · `Println/Printf` (print-above) · `Raw` ·
`Key{Text, Mod, Code, ShiftedCode, BaseCode, IsRepeat}` · `PasteMsg`.

**Features.** No built-in widgets (bubbles is separate); lipgloss styling.
Kitty keyboard via `View.KeyboardEnhancements` (+modifyOtherKeys
fallback); SGR mouse w/ X10 fallback, Click/Release/Wheel/Motion split;
bracketed paste; focus reporting; colorprofile detect + downsampling;
clipboard; sync 2026 + unicode-core 2027 auto-negotiation; native progress
bar; window title/cursor shape.

**Screen ownership.** **Inline by default** (`SetFullscreen(false)` always
at start). Frame height = content height (buffer sized to content, grows/
shrinks). `View.AltScreen = true` is a declarative opt-in (fullscreen,
absolute positioning). Cursor hygiene: hidden cursor at last column moves
to next line to avoid wrap artifacts. `tea.Println` → `insertAbove`:
persistent lines scrolled in above the frame, wrapped in sync 2026; no-op
in alt screen.

**Design gems.** (1) Declarative View struct: renderer diffs old vs new
View and emits only mode-transition sequences — idempotent mode control,
clean inline↔alt cutover. (2) Inline-first frame sized to content: you
render exactly the live region. (3) Touched-lines cell diff + relative
cursor moves (SetRelativeCursor). (4) print-above built into the renderer
for log-above-live-UI.

**Gaps.** Println no-ops in alt screen; insertAbove bypasses the diff
buffer (desync risk mid-render); parser internals live in ultraviolet
(not local); goroutine leaks on shutdown; cell/width math delegated.

### vaxis — live region + append queue (Go)

**Architecture.** Cell buffer, double-buffer diff: `Render()` walks rows,
emits CUP + SGR deltas, skips unchanged via `advance()` (wide-glyph
continuation cells nulled); frames wrapped in hideCursor + sync 2026.
Three threads: parser goroutine (DEC state machine port of Paul Flo
Williams' parser, grapheme segmentation via uucode, ASCII fast path) →
input-loop goroutine (decodes sequences → events, services SIGWINCH) →
main thread (app loop, mutates `screenNext`, `Render`). 3s capability
handshake at startup (DA1 + XTGETTCAP + DECRQM + XTVERSION). No core layout
tree: `Window` is a positional viewport; flex lives in vxfw, widget tree
in ui/.

**API.** `Options{PrimaryScreen: *PrimaryScreenOptions{RegionHeight},
EnableSGRPixels, DisableKittyKeyboard, EventQueueSize, ...}` · `New(opts)`
· `Events()/PollEvent()/PostEvent/SyncFunc` · `Window(){New, Print, Wrap,
Println, PrintTruncate, SetCell}` · `Render/Refresh/Resize` ·
`Append/AppendString/AppendWriter` (panic unless PrimaryScreen) ·
`SetPrimaryScreenRegionHeight` · `CanRGB/CanKittyGraphics/CanSixel/
CanKittyKeyboard/...` · `Key{Text, Keycode, ShiftedCode, BaseLayoutCode,
Modifiers, EventType}` + `Matches` · `Mouse{Button, Row, Col, XPixel,
YPixel}` · `NewImage` (fullBlock/halfBlock/sixel/kitty) · ui.`EventContext
{AppendText, AppendTextLn, AppendWidget, ...}` · `WithPrimaryScreen/
WithDynamicPrimaryScreen`.

**Features.** Full kitty keyboard (CSI-u, ghostty/foot shift+space
workaround); bracketed paste; SGR + pixel mouse (1016); focus +
visibility + color-theme events. Style w/ hyperlinks, SGR `:` subparams,
capability-gated styled underlines, RGB→indexed fallback. Width policy:
`wcwidth` / `noZWJ` / `unicodeStd` selected by queried caps, per-grapheme
cache, `VAXIS_FORCE_*` env overrides, quirks (kitty→noZWJ, tmux→unicodeCore),
explicit-width OSC 66. Images: kitty (async re-encode on resize), sixel,
half/full-block fallback. `SegmentWrapper` Unicode line-break wrapping
preserving OSC 8 ids across splits. OSC 52/9/777/2/7/176/22. No terminfo.

**Screen ownership.** Default: alternate screen. `PrimaryScreen
{RegionHeight}`: model = fixed live region at top + terminal-owned
scrollback. `Append*` queues raw output; `renderPrimary` moves cursor to
region start, `ESC[J` clear, writes queued appends (`\n`→`\r\n`), then
diffs only changed region rows. On resize the region repaints; appended
content reflows at the terminal's whim. Exit parks `\r\n\r` below region.
`WithDynamicPrimaryScreen` = RegionHeight 1 + per-frame measure of root
widget height → `SetPrimaryScreenRegionHeight`.

**Design gems.** (1) **Live region + append queue flushed before the
region on every Render** — the cleanest inline primitive in the set. (2)
AppendText (styled spans, terminal wraps/reflows) vs AppendWidget
(offscreen snapshot, hard-wrapped) — one API split answering "logs reflow,
tables get exact layout". (3) Skip-by-width cell diff + explicit-width OSC
66. (4) Queried capability negotiation drives the width policy — the
terminal tells you how to measure.

**Gaps.** No `Window.Split` (positional only); appended content untracked
(no restore/reflow accounting); render main-thread-only; no IME path; no
terminfo fallback; sixel ≤255 colors.

### Textual — DOM + CSS + compositor (Python)

**Architecture.** Retained widget tree (DOM) + CSS cascade + z-ordered
compositor. Every widget is a MessagePump: an asyncio coroutine with a
per-node queue; messages dispatch down, bubble up, supersede, and get Idle
injection. Layout: per-widget algorithms over a box model, shared
flex-like `layout_resolve` with Fraction arithmetic (size/fraction/
min_size). Compositor: z-order tuples `(layer_index, z, layer_order)`,
paint front-to-back, "first segment per x-cut wins", dirty-region chop
updates. Drivers (Linux/Windows/Headless) run an input thread feeding the
XTermParser.

**API.** `App{CSS/DEFAULT_CSS, TITLE, BINDINGS, MODES, SCREENS,
INLINE_PADDING, run(headless=False, inline=False, ...), run_async,
compose, mount, query, exit, is_inline}` · `Widget{compose, render,
refresh(regions, repaint/layout/recompose), mount}` · `DOMNode{query*,
walk_children, watch, set_class*}` · `Reactive{default, layout, repaint,
compute, recompose, init}` (descriptor auto-runs watchers) ·
`Driver{write, flush, start/stop_application_mode}`.

**Features.** 40+ widgets (Button, Checkbox, Collapsible, DataTable,
DirectoryTree, Footer, Header, Input, ListView, Log, Markdown,
MaskedInput, OptionList, ProgressBar, RadioSet, RichLog, Select,
SelectionList, Sparkline, Static, Switch, TabbedContent, Tabs, TextArea,
Tooltip, Tree...). TCSS: tokenizer (types/classes/ids/nested/variables/
scalars fr/%/vw/vh/colors), specificity (id,class,type) + tie-breaker.
Reactive state w/ watch/compute + repaint triggers; workers (@work/@thread);
devtools + command palette; animations. XTermParser: SGR mouse regex,
kitty extended keys, legacy ANSI.

**Screen ownership.** Fullscreen default: alt screen ?1049h + raw termios
+ application mode. `inline=True` → LinuxInlineDriver: no alt screen, no
application mode, cursor hidden, `INLINE_PADDING` blank lines, kitty keys
+ focus, height capped by inline height, `:inline` CSS pseudo-class, exit
rewinds padding. Windows unsupported.

**Design gems.** (1) Compositor map + paint-front-to-back = overlays
without a cell buffer; dirty-region chops for incremental redraws. (2)
Flexible-box layout resolve as a pure function with Fractions. (3)
MessagePump-per-node async with bubbling + Idle. (4) Inline is a driver
swap, not a renderer fork — same compositor, minimal special-casing.

**Gaps.** Inline Windows-unsupported; fullscreen default; heavy stack
(DOM+CSS+compositor+drivers+Rich pipeline); not a flat cell model;
workers add complexity.

### pi-tui — line-array differential (TypeScript)

**Architecture.** Component contract is pure: `render(width) → string[]`,
one string per terminal line; **each line must be ≤ width or the renderer
throws** (writes a crash log first). No cell buffer, no retained tree —
components cache their lines by width. Differential diff of previous vs
new line arrays. Dual renderers behind one `TUI` interface. Render
scheduling: throttled timer (MIN_RENDER_INTERVAL_MS = 16) with immediate
bypass for keyboard input. Both renderers wrap updates in CSI 2026. Input:
raw stdin → `StdinBuffer` sequence reassembly → chainable listeners →
focused component's `handleInput`. Focus + overlay stack with
ANSI/grapheme-aware line compositing.

**API.** `interface Component { render(width): string[]; handleInput?;
wantsKeyRelease?; invalidate() }` · `interface TUI { mode, addChild,
setFocus, showOverlay, start, stop, renderNow, requestRender,
addInputListener, queryTerminalBackgroundColor, ... }` · `interface
Terminal { start/stop/write/columns/rows/moveBy/hideCursor/clearLine/
clearFromCursor/setTitle/kittyProtocolActive }` · `matchesKey(data,
KeyId)` + `Key` helpers (`ctrl('c')`, `shift`, `alt`, combos).

**Features.** 17 components: Container, Box, Text, TruncatedText, Input,
Editor (79KB), Markdown (marked), Loader, CancellableLoader, SelectList,
SettingsList, Spacer, Image, VStack, HStack, ScrollView. Themes = plain
style-function objects (compositional). Dual-mode keyboard (kitty +
legacy + modifyOtherKeys fallback); `matchesKey` handles all three.
Declarative keybinding registry with conflict detection. Images: kitty +
iTerm2, env/heuristic detection (tmux/screen disabled). OSC 11 background
+ color-scheme queries; OSC 133 zones consumed (prompt navigation). Fuzzy
autocomplete, kill-ring, undo, word navigation.

**Screen ownership.** `TuiMainScreen` (default — pi CLI's everyday mode):
main buffer, scrollback preserved, **3 render strategies** — (1) first
render: emit all lines without clearing; (2) width change / content above:
clear + full re-render; (3) normal: move to first changed line, clear to
end, render changed lines. High-water `maxLinesRendered` for the
clear-on-shrink heuristic. On stop, park cursor below content, no clear.
`TuiAltScreen` (opt-in): alt buffer viewport, VStack/HStack/ScrollView
layout, row-diff updates, OSC 133 prompt navigation, restores the document
on exit. App-owned scrolling is deliberately unavailable on main screen.

**Design gems.** (1) The three main-screen strategies + high-water mark —
bound when clearing is needed. (2) Line-width contract enforced at the
renderer with a crash log — mis-measured width never silently corrupts a
transcript. (3) Zero-width APC cursor marker: components emit it at the
fake cursor, renderer strips and positions the hardware cursor (IME
candidate windows for free). (4) Width-aware ANSI slicing for overlays
without breaking SGR/OSC 8.

**Gaps.** Main screen has no layout/viewport semantics; over-wide line =
hard throw; styles don't carry across lines (full SGR reset per line);
diff is O(n) string equality; synchronous render; image caps env-detected,
no runtime probe.

### zigzag — Elm MUV, comptime-parameterized (Zig 0.16)

**Architecture.** `Program(comptime Model)` verifies the Model contract
via `@hasDecl` + `@compileError`. Tick loop: reset frame arena → 256B
non-blocking read → parse all events → dispatch (with optional message
filter) → render on demand (skips when Wyhash of view unchanged). Cmd
union side effects in `processCommand`. SubProgram wraps child Models;
AsyncRunner spawns threads but is NOT wired into tick (manual poll).
Layout: join (horizontal/vertical, ANSI-aware measure), place (2D/float),
layer (z-sorted cell compositing w/ transparency), flex (Flexbox
constraints).

**API.** `Program(Model).initWithOptions(allocator, io, environ_map,
Options)` · `Cmd(Msg)` tagged union (quit/tick/every/batch/sequence/send/
perform/enter_alt_screen/println/image_*) · `Context{allocator,
persistent_allocator, io, width/height, frame/elapsed/delta,
render_requested, color_profile, theme, setClipboard,
supportsKittyGraphics}` · `Options{fps=60, mouse, cursor, alt_screen=true,
bracketed_paste, kitty_keyboard, osc52, custom input/output, log_file,
suspend}` · `Key` union + `KeyEvent{Modifiers, event_type}` · `Style`
builder (fg/bg/attrs/padding/margin/border/align/overflow/transform/
unset/inherit/inline_style) · `Color{ansi, ansi256, rgb}` + AdaptiveColor
+ ColorProfile · `Border` 9 styles · `FocusGroup`/`KeyBinding`/`KeyMap` ·
Model contract: `Msg` type, `init/update/view`.

**Features.** 40+ components: code_area, text_area, text_input, list,
table, data_table, sortable_table, viewport, virtual_list, tree, tab_group,
form, dropdown, checkbox, radio_group, slider, menu_bar, context_menu,
command_palette, modal, tooltip, toast, notification, confirm, file_picker,
calendar, help, paginator, status_bar, breadcrumb, stepper, split_pane,
markdown, rich_log, diff_view, code_view, progress, gauge, spinner,
sparkline, chart, bar_chart, heatmap, canvas, braille_canvas, styled_list.
Style ranges + highlights; overflow policies. Kitty keyboard (partial
CSI-u) + bracketed paste + SGR mouse; images kitty/iTerm2/sixel with live
APC-G probe; OSC 52/8; sync 2026; snapshot testing; custom I/O streams.

**Screen ownership.** Fullscreen-first: `alt_screen = true` default,
runtime toggle via commands. With `alt_screen = false` it still owns
stdout — `render()` repaints from cursor_home with line_clear_right
(a region owner, not a scrollback writer). `.println` = cursor save/home/
print/restore (print above, doesn't scroll user output). Custom
input/output enables pipe testing.

**Design gems.** (1) Render-on-demand + whole-view Wyhash skip — idle app
pays nothing (critical for inline coexistence). (2) 256B read +
`incompleteTailLen` split-sequence buffering — kitty CSI-u / paste tails
never leak as literal chars; reuse verbatim. (3) Boot-clock frame pacing
with rebase on overrun/suspend. (4) `inline_style(true)` — styled
fragments that render without newlines; components are largely
screen-owner-agnostic. (5) The house fork is patched (CodeView `.skript`).
(6) `terminal/screen.zig` ships a complete but **unused** double-buffer
cell diff renderer — ready to copy for the inline path. (7) Runtime
unicode-width strategy switch driven by 2027 detection.

**Gaps.** No true inline/scrollback mode; AsyncRunner not wired + unlocked;
SubProgram drops child cmds; parse events frame-allocated (copy to
persistent); Ctrl+C hard-quits before the model; mouse needs a Msg field.

### libvaxis — two-layer: cell lib + vxfw (Zig 0.16)

**Architecture.** Low-level: flat `[]Cell` screen, diff renderer (DAM,
tracks current emitted style — only SGR/osc8 deltas), 9-state DEC parser,
tty abstraction (PosixTty/WindowsTty/TestTty via comptime switch).
High-level `vxfw`: Flutter-like retained widget tree, constraint-
propagation layout (DrawContext min/max), Surface tree with z-index.
`Loop(T)`: 512-deep queue fed by a background tty thread (1024B reads →
parser.parse → postEvent); `App.run` sleeps to a 60fps deadline, drains,
routes through focus/mouse handlers, redraws only if `ctx.redraw`.
Capability responses intercepted in-loop (explicit-width probes decoded as
shift+F3/alt+F3 key events — the key parser doubles as a position-report
decoder).

**API.** `Vaxis.init(io, alloc, env_map, opts)` · `window()` ·
`enterAltScreen/exitAltScreen` · `render(tty)` · `queryTerminal/
enableDetectedFeatures` · `prettyPrint` · `setMouseMode/setBracketedPaste/
notify/setTitle/setMouseShape` · `loadImage/freeImage/copyToSystemClipboard`
· `Screen{width, height, width_pix, height_pix, buf: []Cell, cursor}` ·
`Window{child, writeCell, print(segments, PrintOptions{wrap: grapheme/
word/none})}` · `Cell{Character{grapheme, width}, Style, Color, Hyperlink}`
· `Parser.parse(input, paste_allocator) → Result{event, n}` · `Key
{matches/matchShortcut/matchText}` + KittyFlags · `Loop(T){init/start/
stop/nextEvent/postEvent}` · `Tty PosixTty{makeRaw, getWinsize,
notifyWinsize}` · vxfw: `Widget{userdata, capture/eventHandlers, drawFn →
Surface}`, `App.run(widget, opts)`, `EventContext{phase, consume_event,
redraw, quit, cmds, requestFocus, copyToClipboard}`, `DrawContext{arena,
min, max}`, `Surface{size, widget, cursor, buffer, children:[]SubSurface
{z_index}}`.

**Features.** vxfw widgets: Border, Button, Center, FlexColumn, FlexRow,
ListView, Padding, RichText, ScrollView, ScrollBars, SizedBox, SplitView,
Spinner, Text, TextField, Image; specialized: Table, LineNumbers,
TextView, CodeView, TextInput, View, alignment, Scrollbar, **Terminal**.
Per-cell Style with underline styles, SGR colon/legacy + conpty
workaround. Full kitty keyboard; mouse SGR 1006 + pixel 1016 + legacy
10-bit; bracketed paste; OSC 52/22/9/777. Capabilities model via queries
with env overrides. Kitty images (transmit/placement, scale, z-index).
gwidth: 3 methods (unicode/wcwidth/no_zwj) over uucode tables +
GraphemeCache ring (zero-alloc Key.text across the event boundary); mode
2027 + OSC 66 + scaled text. **Embedded terminal emulator widget**: real
child on a PTY (Linux), own DEC parser, screen w/ 500-row scrollback,
front/back double-buffer, CSI-u keyboard encode back to the child.

**Screen ownership.** Alt screen optional (`enterAltScreen` just emits
smcup/rmcup). On the primary screen rendering avoids absolute positioning
— `\r`, `\n`/RI, cuf relative moves, autowrap-aware (`cell.wrapped`).
`prettyPrint` = sequential styled output to the primary buffer
(`error.NotInPrimaryScreen` while in alt). vxfw App defaults to alt;
low-level API is fully primary-screen capable.

**Design gems.** (1) Query-based capabilities (no terminfo) incl. the
key-parser-as-position-report trick. (2) Pure parser + TestTty —
headless-testable input machinery; the pattern to copy. (3) GraphemeCache
zero-alloc slice retention across threads. (4) Diff renderer tracking the
current emitted style. (5) Embedded emulator reusing the same
gwidth/grapheme machinery — a test oracle for an inline TUI.

**Gaps.** No append-to-scrollback API (embedded Terminal scrollback has a
TODO); uucode + zigimg deps; PTY Linux-only; pixel mouse off by default in
vxfw; prettyPrint forbidden in alt; primary-screen cursor relocation is a
TODO; query futex can time out (falls back to wcwidth).

## 3. What notui should steal (convergence map)

**Rendering core (inline-first):**
- **vaxis `PrimaryScreen` model**: live region + append queue flushed
  before the region each frame — the load-bearing inline idea
  (vaxis: renderPrimary).
- **pi-tui 3-strategy main-screen renderer**: first-render append-no-clear,
  width-change full clear+redraw, normal diff from first changed line +
  high-water mark for clear-on-shrink (pi-tui: tui-main-screen.ts).
- **ratatui cursor-anchored inline viewport**: append_lines space
  reservation, origin shift on scroll, cursor-relative offset preserved on
  resize (ratatui: inline.rs compute_inline_size).
- **bubbletea content-height frame** + print-above (insertAbove) for
  log-above-live-UI, wrapped in sync 2026.

**Cell/diff model:** ratatui zero-alloc BufferDiff + swap-buffer reset;
zigzag's unused terminal/screen.zig diff renderer is the ready-made Zig
copy source; libvaxis style-tracking SGR delta emission.

**Input:** libvaxis Parser.zig + Key.zig (full kitty, pixel mouse, paste,
OSC decode) — the most complete Zig source; zigzag's incompleteTailLen
split-buffering; pi-tui's matchesKey three-way (kitty/legacy/
modifyOtherKeys).

**Layout:** zigzag flex/join/layer (Zig, ready) or ratatui's
Strength-ordered constraints (semantics worth copying); textual's pure
flex resolve with Fractions is the algorithm to imitate for inline
(terminal owns scrollback — layout is bounded by width only).

**Mode control:** bubbletea declarative View struct — renderer diffs old
vs new view and emits only mode transitions (inline↔alt cutover for free);
textual `:inline` CSS-style pseudo-selector as the driver-swap pattern.

**Testing:** libvaxis TestTty + pure parser (headless); zigzag snapshot
tests; pi-tui VirtualTerminal; ratatui TestBackend.

**Width/unicode:** zg as the sole dep (already pinned); adopt libvaxis's
3-method width policy (unicode/wcwidth/no_zwj) driven by queried
capabilities (2027 + OSC 66).

**Deliberately skip:** textual DOM+CSS machinery (complexity), bubbletea's
delegated parser (needs own), pi-tui's hard-throw width contract (graceful
truncation instead), terminfo (queries instead).

## 4. Sources

Local clones: `~/projects/github-ratatui-ratatui`,
`github-charmbracelet-bubbletea`, `github-rockorager-vaxis`,
`github-Textualize-textual`, `github-earendil-works-pi/packages/tui`,
`~/projects/libvaxis`, vendored zigzag at
`~/projects/skript/third_party/zigzag`. Full file:line evidence
in each agent pass (history://ArchRatatui, ArchBubbletea, ArchVaxis,
ArchTextual, ArchPiTui, ArchZigzag, ArchLibvaxis).
