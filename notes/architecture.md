# notui Architecture v1

First architecture for notui: an inline-first terminal UI library for
Zig 0.16. This document is the synthesis of three parallel design proposals
(deep module / foundation kit / Elm framework) against the research in
`notes/research/tui-landscape.md`, `zig-foundations.md`, and
`tui-architectures.md`.

## 1. Direction

**Chosen shape: Foundation Kit with a deep `Region` module.** The library
exposes small composable primitives — cell `Buffer`, ANSI `Parser`, raw-mode
`Tty`, query-driven `Capabilities`, `Style`, and the inline `Region`
renderer. There is **no app framework in v0** (no Model/Update/View, no
component tree): apps own the loop and state; the library provides the
load-bearing pieces and documents how they fit.

Why this over the alternatives:

- The inline `Region` renderer *is* the deep-module proposal in one file:
  three render strategies, cursor anchoring, space reservation, append
  queue, scrollback preservation, exit — small interface, hidden behavior.
  A separate `Session`/`Frame` facade adds indirection without new power
  (P1's escape hatches are `Reader.next` + `Region.render`).
- Primitives-first is the proven two-layer design (libvaxis low-level +
  vxfw on top). The Elm framework (P3) becomes the natural **v1 layer** on
  top of these primitives; components copied from zigzag then attach to a
  proven surface. Building the framework first inverts the dependency.
- Apps that only want a spinner or a prompt should not inherit a
  comptime Model contract.

**Pitch:** terminal primitives you compose, with inline-first scrollback
preservation as the default renderer.

## 2. Module layout

```
src/root.zig        library root; re-exports the public surface (§5)
src/cell.zig        Cell: grapheme slice + Style + wide flag
src/style.zig       Style (fg/bg/attrs/hyperlink), eql/merge
src/color.zig       Color union (ansi/ansi256/rgb), AnsiColor, ColorProfile
src/buffer.zig      Buffer: cell grid, draw, wide-char handling, double-buffer diff
src/parser.zig      ANSI/DEC input state machine → Event (libvaxis Parser.zig copy)
src/key.zig         Key + Modifiers + KittyFlags + matches (libvaxis Key.zig copy)
src/mouse.zig       Mouse event (SGR 1006 + pixel 1016)
src/event.zig       Event union (incl. cpr for inline anchoring)
src/tty.zig         raw mode, winsize, SIGWINCH, panic-restore (zigzag posix.zig copy)
src/caps.zig        Capabilities: query handshake + width policy
src/emit.zig        ANSI write helpers: cursor, SGR, sync 2026, CPR, scroll regions
src/width.zig       thin zg wrapper: strWidth/graphemeWidth/wrap/truncate (THE dep seam)
src/region.zig      inline Region renderer: live region + append queue + 3 strategies
src/input.zig       Reader: blocking read + split-sequence buffering
examples/           spinner.zig, prompt.zig, statusline.zig (composition recipes)
```

Dependency direction: primitives depend only on `width.zig`; `region.zig`
composes `buffer`+`emit`+`width`; `input.zig` composes `tty`+`parser`. No
primitive depends on another to function.

## 3. Core models

**Rendering.** Immediate-mode, double-buffered cell grid. The app draws
each frame into `Buffer cur`; `Region` diffs `cur` against `prev`
(skip-by-width, style-tracking SGR deltas, wide-continuation cells nulled)
and emits only changed cells. Idle frames emit nothing when `cur == prev`.
Width comes from zg `DisplayWidth`; grapheme placement from zg `Graphemes`
(replaces libvaxis's uucode dep and zigzag's own table — zg is the sole
external dependency, pinned 0.16.2).

**Event loop.** Single-threaded, blocking-read, app-owned:
`Tty.init → makeRaw → Caps.detect → Region.init → loop { Reader.next →
switch(event) → update state → Region.render } → Region.exit`. The
`Reader` does `poll` → 256B read → prepend `pending` tail
(`incompleteTailLen` hold-back, zigzag pattern) → `Parser.parse` → one
`Event`. `nextTimeout(ms)` variant for fps/tick pacing. SIGWINCH sets an
atomic flag checked by `Tty.checkResize`; no background thread in v0.

**Input.** libvaxis `Parser.zig` (full 9-state DEC: kitty CSI-u with
release/repeat, legacy SS3/CSI, SGR + pixel mouse, bracketed paste, OSC
4/10/11/12/52, DA1, APC-G) + libvaxis `Key.zig` (kitty PUA keycodes,
modifiers, `matches`/`matchShortcut`). Required adaptation: swap the
`uucode` import for zg `Graphemes`/`Utf8View` (localized; Key.zig already
TODO-points at zg) — isolate behind thin helpers. CPR (`ESC[6n`) is
decoded as its own `Event.cpr` (diverging from libvaxis's shift+F3 trick)
— needed for inline anchoring.

**Capabilities.** Live queries, no terminfo: DA1, ?2026 (sync), ?2027
(unicode core), kitty keyboard `?u`, RGB. Drives `WidthPolicy`
(zg_unicode / wcwidth_legacy / no_zwj) — v0 defaults to zg unicode width;
the probe hook is reserved.

**State.** App-owned. Primitives carry only their own render state
(Buffer cells, Region anchor/high-water, Parser scratch, Reader pending
tail). Event text (`Key.text`, paste) is valid only until the next
`Reader.next` call — documented, apps copy into their own arena.

## 4. The Region — inline mechanics (the deep module)

The centerpiece. Model: vaxis `renderPrimary` (live region + append queue)
+ pi-tui's 3 main-screen strategies + ratatui cursor-row anchoring.

1. **Cursor anchoring.** The region occupies `height` rows at `anchor_row`
   in the main buffer. Position tracked from our own writes; `reanchor()`
   issues CPR (`ESC[6n`) on first render and after resize. Rows emitted
   with relative moves (`\r`, `\n`, CNL) — absolute CUP only when needed;
   scrollback above is never disturbed.
2. **Space reservation.** `Options.append_lines` uses `ESC[n E` (CNL) to
   push the terminal so the region owns a stable band; origin shift tracked,
   anchor re-queried when it drifts.
3. **Three render strategies.** (1) First render: append all `height`
   lines WITHOUT clearing, set high-water mark. (2) Width change / forced
   (`width_dirty`, set by resize): `ESC[J` from anchor, full re-render —
   the guard against the ratatui resize-duplicates-into-scrollback bug. (3)
   Normal: first changed row via `renderDiff`, `ESC[J`, emit changed rows
   with `eraseLine` (kills stale tail), high-water clear-on-shrink. All
   frames wrapped in CSI 2026 synchronized output.
4. **Append queue.** Before rendering, queued `Append` items flush above
   the region into scrollback: move to region top, `ESC[J`, write with
   `\n`→`\r\n`, re-fix anchor. `Append.text` = styled spans the terminal
   wraps/reflows; `Append.line` = hard-wrapped exact-layout lines (the
   vaxis AppendText/AppendWidget split). This is the print-above escape
   hatch, inline-first.
5. **Scrollback preservation.** Never clears above `anchor_row`; never
   enters the alt screen (emit.enterAltScreen is opt-in, off by default).
   First render appends without clearing; only the width-change path
   clears, bounded to the band.
6. **Resize.** `Region.resize(w,h)` reallocs buffers (overlap copied),
   sets `width_dirty`, calls `reanchor()`; next frame strategy 2 clears +
   redraws.
7. **Exit.** `Region.exit(w)`: show cursor, endSync, park `\r\n\r` below
   the last region row, no clear — the final frame stays in the transcript.
8. **Non-TTY degradation.** When piped: skip hide-cursor/CPR/sync
   sequences, emit a single plain final frame (ink/delta pattern).

## 5. Public API (v0 surface)

```zig
// cell.zig
pub const Cell = struct {
    grapheme: []const u8 = " ",   // points into app text arena; NOT copied
    style: Style = .{},
    wide: bool = false,           // continuation cell of a wide grapheme
    pub fn eql(self: Cell, other: Cell) bool;
};

// style.zig / color.zig
pub const Style = struct {
    fg: ?Color = null, bg: ?Color = null, hyperlink: ?[]const u8 = null,
    attrs: Attrs = .{},
    pub const Attrs = packed struct {
        bold: bool = false, dim: bool = false, italic: bool = false,
        underline: bool = false, blink: bool = false, reverse: bool = false,
        strikethrough: bool = false,
    };
    pub fn eql(self: Style, other: Style) bool;
    pub fn merge(self: Style, base: Style) Style;
};
pub const Color = union(enum) { ansi: AnsiColor, ansi256: u8,
    rgb: struct { r: u8, g: u8, b: u8 }, default };
pub const ColorProfile = enum { ansi, ansi256, truecolor };

// buffer.zig — cell grid + double-buffer diff (zigzag screen.zig model)
pub const Buffer = struct {
    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Buffer;
    pub fn deinit(self: *Buffer) void;
    pub fn resize(self: *Buffer, new_width: u16, new_height: u16) !void;
    pub fn clear(self: *Buffer) void;
    pub fn get(self: *const Buffer, x: u16, y: u16) Cell;
    pub fn set(self: *Buffer, x: u16, y: u16, cell: Cell) !void; // wide-char handling
    pub fn draw(self: *Buffer, style: Style, text: []const u8, x: u16, y: u16) !u16;
    pub fn renderDiff(self: *const Buffer, prev: *const Buffer, w: anytype) !void;
    pub fn renderAll(self: *const Buffer, w: anytype) !void;
};

// parser.zig — libvaxis Parser.zig copy; grapheme detection via zg
pub const Parser = struct {
    pub const Result = struct { event: ?Event, n: usize };
    pub fn parse(self: *Parser, input: []const u8,
        paste_allocator: ?std.mem.Allocator) !Result; // null+n==0 => incomplete
};

// key.zig — libvaxis Key.zig copy
pub const Key = struct {
    codepoint: u21, text: ?[]const u8 = null,
    shifted_codepoint: ?u21 = null, base_layout_codepoint: ?u21 = null,
    mods: Modifiers = .{},
    pub const Modifiers = packed struct(u8) { shift, alt, ctrl, super,
        hyper, meta, caps_lock, num_lock: bool };
    pub const KittyFlags = packed struct(u5) { disambiguate: bool = true,
        report_events: bool = false, report_alternate_keys: bool = true,
        report_all_as_ctl_seqs: bool = true, report_text: bool = true };
    pub fn matches(self: Key, cp: u21, mods: Modifiers) bool;
    pub fn matchShortcut(self: Key, cp: u21, mods: Modifiers) bool;
    pub const ctrl_c: u21 = 0x03; pub const enter: u21 = 0x0D;
    pub const tab: u21 = 0x09; pub const escape: u21 = 0x1B;
};

// event.zig
pub const Event = union(enum) {
    key_press: Key, key_release: Key, mouse: Mouse,
    focus_in, focus_out, paste: []const u8,
    color_report: Color.Report, winsize: Winsize,
    cpr: Pos, cap: Capability,
};

// tty.zig — zigzag posix.zig raw mode; libvaxis winsize/SIGWINCH/panic-restore
pub const Tty = struct {
    pub fn init(io: std.Io) !Tty;
    pub fn deinit(self: *Tty) void;
    pub fn isTty(fd: posix.fd_t) bool;
    pub fn makeRaw(self: *Tty) !void;
    pub fn restore(self: *Tty) void;
    pub fn getWinsize(self: *Tty) !Winsize;
    pub fn checkResize(self: *Tty) bool;   // SIGWINCH atomic flag
    pub fn writer(self: *Tty) *std.Io.Writer;
    pub fn read(self: *Tty, buf: []u8) !usize;
};

// caps.zig — query handshake, no terminfo
pub const Capabilities = struct {
    color: ColorProfile = .ansi256, kitty_keyboard: bool = false,
    sgr_pixels: bool = false, bracketed_paste: bool = false,
    sync_output: bool = false, unicode_core: bool = false,
    rgb: bool = false, focus_events: bool = false,
    pub const WidthPolicy = enum { zg_unicode, wcwidth_legacy, no_zwj };
    pub fn widthPolicy(self: *const Capabilities) WidthPolicy;
    pub fn detect(tty: *Tty, parser: *Parser, alloc: std.mem.Allocator) !Capabilities;
};

// emit.zig — zigzag ansi.zig constants
pub fn hideCursor(w: anytype) !void;   pub fn showCursor(w: anytype) !void;
pub fn cursorTo(w: anytype, row: u16, col: u16) !void;
pub fn eraseToEnd(w: anytype) !void;   pub fn eraseLine(w: anytype) !void;
pub fn appendLines(w: anytype, n: u16) !void; // CSI n E (space reservation)
pub fn scrollRegionUp(w: anytype, n: u16) !void;
pub fn queryCursor(w: anytype) !void;  // CSI 6n (CPR)
pub fn beginSync(w: anytype) !void;    pub fn endSync(w: anytype) !void;
pub fn enterAltScreen(w: anytype) !void; pub fn exitAltScreen(w: anytype) !void;
pub fn writeStyle(w: anytype, s: Style) !void;

// width.zig — the zg seam (sole dep)
pub fn strWidth(str: []const u8) usize;
pub fn graphemeWidth(gc: []const u8) isize;
pub fn wrap(allocator: std.mem.Allocator, str: []const u8, columns: usize,
    threshold: usize) ![]u8;
pub fn truncate(allocator: std.mem.Allocator, str: []const u8, columns: usize) ![]u8;

// region.zig — THE v0 centerpiece
pub const Region = struct {
    pub const Options = struct {
        height: u16,
        append_lines: bool = true,
        sync_output: bool = true,
        width_policy: Capabilities.WidthPolicy = .zg_unicode,
    };
    pub const Append = union(enum) { text: []const u8, line: []const u8 };
    pub fn init(gpa: std.mem.Allocator, opts: Options) !Region;
    pub fn deinit(self: *Region) void;
    pub fn resize(self: *Region, new_width: u16, new_height: u16) !void;
    pub fn render(self: *Region, w: anytype) !void;      // 3-strategy inline render
    pub fn renderFull(self: *Region, w: anytype) !void;
    pub fn append(self: *Region, item: Append) !void;    // queued output ABOVE region
    pub fn reanchor(self: *Region) !void;
    pub fn exit(self: *Region, w: anytype) !void;
};

// input.zig — blocking read + split-seq reassembly (zigzag incompleteTailLen)
pub const Reader = struct {
    pub fn init(tty: *Tty) Reader;
    pub fn next(self: *Reader) !Event;             // blocking
    pub fn nextTimeout(self: *Reader, timeout_ms: i32) !?Event;
    pub fn incompleteTailLen(data: []const u8) usize;
};
```

## 6. Copy-source map (one primary per subsystem)

| Subsystem | Copy from | Adaptation |
|---|---|---|
| ANSI emit + cell diff | zigzag `terminal/ansi.zig` + `terminal/screen.zig` (house-vendored, unit-tested) | swap `unicode.charWidth` → zg width |
| Input parser + Key | libvaxis `Parser.zig` + `Key.zig` (most complete 0.16) | swap `uucode` → zg Graphemes/Utf8View; add `Event.cpr` |
| Split-seq buffering | zigzag `input/keyboard.zig` `incompleteTailLen` | verbatim |
| Raw mode / TTY | zigzag `terminal/platform/posix.zig` | verbatim (std termios) |
| Capability queries | zigzag `terminal/terminal.zig` query fns | DA1/2027/sync/kitty only; no terminfo |
| Width/graphemes | **zg (sole dep, not copied)** | thin `width.zig` seam |

## 7. Explicit deferrals (v1+)

- App framework / component tree / Model-Update-View — the two-layer v1 on
  top of these primitives (Elm framework proposal is the design seed).
- Layout engine beyond per-line wrap/truncate (no flex/join solver).
- Alt-screen renderer + full-screen widget set (escape hatches exist in
  emit).
- Images (kitty/sixel), OSC 52 clipboard read, mouse drag/pixel API surface.
- Windows Tty (libvaxis WindowsTty is the later copy source).
- Background read thread / event queue; concurrent render.
- Subprocess fd-capture (skript pattern) — documented interaction.

## 8. Decisions (first cut)

1. Primitives-first; no App/Model/View in v0. (libvaxis two-layer)
2. Inline Region = live region + append queue flushed before the region
   each frame. (vaxis renderPrimary)
3. Parser/Key from libvaxis; split buffering from zigzag; emit/diff from
   zigzag; width from zg. (zig-foundations inventory)
4. zg is the one width engine; thin `width.zig` seam is the only import
   site. (research recommendation)
5. 3-strategy inline renderer with high-water mark; width-change clears +
   full redraws. (pi-tui; guards ratatui resize bugs)
6. Capability detection via live queries, no terminfo. (zigzag/vaxis)
7. Anchoring via tracked position + CPR reanchor, not cursor-home.
   (ratatui inline.rs)
8. Graceful truncation of over-wide lines, never a hard throw. (deliberate
   divergence from pi-tui)
9. Non-TTY degradation to a single plain frame. (ink/delta)

## 9. Risks and mitigations

1. **Primitives-composition burden** — apps wire the loop. Mitigation:
   clean init/deinit, example recipes, `Reader` removes fiddly buffering;
   thin App convenience later without breaking primitives.
2. **Anchor drift** from external fd1/fd2 writes or resize. Mitigation:
   tracked position + origin shift; reanchor on resize; docs point at
   skript fd-capture as the full solution (deferred).
3. **Scrollback duplication / stale rows on resize** (ratatui
   #2086/#2355/#2666). Mitigation: strategy 2 clear+full-redraw on width
   change; high-water clear-on-shrink; never emit more than `height` lines.
4. **Wide-glyph mis-measurement** corrupts the transcript. Mitigation:
   Buffer.set/draw enforce width via zg; graceful truncation; width_policy
   hook for ?2027/OSC 66 later.
5. **zg coupling** — thin seam + pinned 0.16.2.
6. **Parser dep swap diverges from libvaxis source.** Mitigation: isolate
   uucode usage behind local helpers; conformance vector suite of raw
   byte→Event fixtures.
7. **tmux scroll-on-clear snapshots.** Mitigation: erase from column 1,
   prefer line_clear_right/cell-diff, sync 2026 every frame.

## 10. Resolved open questions (defaults for the plan)

- No App convenience in v0 (strictly deferred).
- v0 targets Linux + macOS (zigzag posix.zig); Windows later.
- CPR reanchor on first render + resize (not per-frame).
- Mouse events surfaced (SGR 1006; pixel 1016 parsed, exposed as data).
- Append queue ships both `text` (reflow) and `line` (exact) from the start.
- fd-capture documented as a known interaction, not built.
- Ctrl+C is a normal key event (app decides); no hard quit in the library.
