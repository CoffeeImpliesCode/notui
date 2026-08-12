# notui v0 — Implementation Plan

First implementation plan for notui: an inline-first terminal UI library for
Zig 0.16. The architecture contract is `notes/architecture.md` (v1, just
committed). This plan implements **exactly** its §5 public API surface —
no API additions, no app framework, no images. All signatures below are
from architecture.md §5 unless stated otherwise; where this plan adds an
internal type or resolves an under-specified point, it is flagged.

## 0. Working rules (apply to every task)

- **zg is the sole dependency** (pinned v0.16.2 in build.zig.zon). No
  std.c, no libc, no terminfo, no new deps. The only import site for
  `zg`/`DisplayWidth`/`Graphemes` in library modules is `src/width.zig`;
  the existing zg smoke tests in `src/root.zig` move into `width.zig`
  tests in P0. Grep-gate: `@import("DisplayWidth")` / `@import("Graphemes")`
  / `@import("zg")` may appear only in `src/width.zig` (root.zig may still
  re-export via `pub const width`).
- **Gate discipline.** While building a phase, skip all gates: do not run
  `zig build`, `zig build test`, `zig fmt`, or `zlint` between tasks. The
  orchestrator runs them **once per phase**; the phase is green only when
  `zig build test` passes. `zig fmt --check` at phase boundaries too, so
  drift never accumulates.
- **Tiger style.** Explicit allocators everywhere; `init` takes a named
  `gpa`/`allocator` parameter; `defer`/`errdefer` for every acquisition;
  no hidden or global allocation. The single sanctioned global is the
  SIGWINCH atomic flag + panic-restore tty handle (copied from libvaxis,
  documented exception).
- **Zig 0.16 idioms.** Unmanaged containers / plain slices (no
  `std.ArrayList` unmanaged dance where a slice + len suffices); struct
  defaults via `.{}`/`.empty`; `std.Io` threaded through `Tty.init(io)`;
  packed bool structs for flag sets; no async, no threads in v0.
- **Graceful truncation, never a hard throw.** Over-wide lines are
  truncated or dropped at the cell boundary (deliberate divergence from
  pi-tui's hard-throw contract — architecture §8.8). `Buffer.draw` and
  `width.truncate` never return errors for width; the region never emits
  more than `height` lines.
- **No backwards-compat layers.** Copy sources are adapted in place; no
  shims, aliases, or re-export ladders. Each file starts fresh from its
  copy source with only the listed adaptations.
- **Conformance before substitution** for the parser swap (risk §9.6):
  P2 ports the libvaxis byte→Event fixture suite *alongside* the adapted
  code before any new divergence lands.

## 1. Phase map

| Phase | Name | Tasks | Depends on | Gate |
|---|---|---|---|---|
| P0 | Test harness + width seam | 2 | — | `zig build test` |
| P1 | color / style / cell / emit | 3 | P0 | `zig build test` |
| P2 | parser / key / mouse / event | 3 | — (parallel to P1) | `zig build test` |
| P3 | tty / caps | 2 | P2 (caps consumes parser) | `zig build test` |
| P4 | buffer | 2 | P0 (width), P1 (cell/style/emit) | `zig build test` |
| P5 | region (centerpiece) | 6 | P4, P1 | `zig build test` |
| P6 | input reader | 2 | P2, P3 | `zig build test` |
| P7 | examples + docs | 4 | P5, P6 | `zig build test` + manual run |

Order rationale: parser (P2) precedes tty/caps (P3) because
`Caps.detect(tty, parser, …)` consumes parser-decoded capability replies.
Buffer (P4) precedes region (P5) because region composes it. Reader (P6)
needs tty + parser. P1 and P2 are independent and may be worked in
parallel (two agents).

---

## P0 — Test harness + width seam

Goal: every later phase lands on a green `zig build test`; zg is sealed
behind `width.zig`.

### T0.1 — src/width.zig: the zg seam
- **File:** `src/width.zig` (new), `src/root.zig` (edit), `src/build.zig` (no change needed — zg already wired in lib + test modules).
- **Implement:** §5 width.zig surface:
  - `pub fn strWidth(str: []const u8) usize` — delegate `DisplayWidth.strWidth`.
  - `pub fn graphemeWidth(gc: []const u8) isize` — delegate `DisplayWidth.graphemeWidth`.
  - `pub fn wrap(allocator, str, columns, threshold) ![]u8` — delegate `DisplayWidth.wrap` (zg `DisplayWidth.zig:359`, threshold semantics: wrap when the last word crosses the threshold).
  - `pub fn truncate(allocator, str, columns) ![]u8` — **no zg equivalent** (verified: zg DisplayWidth.zig has center/pad/wrap only); hand-roll: iterate `Graphemes.iterator(str)`, accumulate `strWidth`, stop before the grapheme that would exceed `columns`; caller frees. Graceful: never error on width, returns prefix (possibly empty).
  - Move the two zg smoke tests from `src/root.zig` into `width.zig` tests; add `pub const width = @import("width.zig");` to root.zig.
- **Copy source:** zg `DisplayWidth.zig` (graphemeWidth :61, strWidth :88, wrap :359), zg `Graphemes.zig` (iterator :39, Grapheme.bytes :83). Reference only — zg is a dep, not copied.
- **Tests:** strWidth ascii/emoji/ZWJ (`"Hello 😊"` = 8); graphemeWidth (`"👨‍🌾"` = 2); wrap threshold boundary cases (word crossing threshold wraps, long unbreakable word stays on one line); truncate: fits → verbatim, cuts at grapheme boundary (`"👨‍🌾x"` at 2 cols → `"👨‍🌾"` not half bytes), empty when first grapheme over-wide, never error for any input.
- **Acceptance:** grep-gate passes (only width.zig imports zg/DisplayWidth/Graphemes); `zig build test` green.

### T0.2 — build.zig test harness + module skeleton
- **File:** `build.zig` (edit), `src/root.zig` (edit).
- **Implement:** verify the existing `test` step covers every future module: switch the unit-test root to `refAllDecls` over the re-exported modules (already the pattern in root.zig) so each new `pub const m = @import("m.zig")` is automatically pulled into the test binary. Keep the exe (`src/main.zig`) untouched.
- **Tests:** none new — acceptance is `zig build` + `zig build test` + `zig fmt --check` all green on the current tree.
- **Acceptance:** three gates green.

---

## P1 — color / style / cell / emit

Goal: the styling + ANSI-writing primitives every later phase emits
through. Headless-testable (fake writers, no tty).

### T1.1 — src/color.zig
- **File:** `src/color.zig` (new), `src/root.zig` (re-export).
- **Implement:** §5 color.zig surface:
  - `pub const Color = union(enum) { ansi: AnsiColor, ansi256: u8, rgb: struct { r: u8, g: u8, b: u8 }, default }` — zigzag `style/color.zig:10` shape; add `pub const Report` (copy libvaxis `Cell.zig:137` — `kind: Kind, value: [3]u8`; Kind = osc4/osc10/osc11/osc12) and `pub fn rgbFromSpec(spec: []const u8) !Color` adapted from libvaxis `Cell.zig:182` (parse `rgb:RRRR/GGGG/BBBB` OSC 11 response into `Color.rgb`).
  - `pub const AnsiColor = enum(u8)` with `fgCode`/`bgCode`/`toRgb` — zigzag `color.zig:140-211` (fgCode :158, bgCode :163, ansi256→RGB cube :194-207).
  - `pub const ColorProfile = enum { ansi, ansi256, truecolor }` with `supportsTrueColor`/`supports256`/`supportsColor` — zigzag `color.zig:246-295` (trim `.ascii`, keep the three §5 values).
- **Copy source:** zigzag `style/color.zig`, libvaxis `Cell.zig`.
- **Adaptation points:** rgbFromSpec is a uucode-free pure parse (no dep work); Report.value is 8-bit per channel (libvaxis keeps 16-bit spec — downshift by shifting the two-digit chunks).
- **Tests:** eql across all tags; hex/color256/gray helpers; rgbFromSpec vectors (`rgb:aaaa/bbbb/cccc` → 0xAA/0xBB/0xCC, invalid specs error); ansi256→RGB cube corners; AnsiColor fg/bg code math.
- **Acceptance:** all tests green; no zg import in this file.

### T1.2 — src/style.zig
- **File:** `src/style.zig` (new), `src/root.zig` (re-export).
- **Implement:** §5 style.zig surface verbatim: `Style` (fg/bg/hyperlink/attrs), `Attrs` packed struct (7 bools), `eql` (hyperlink compared by `std.mem.eql`), `merge(self, base)` — non-null fields of `self` override `base`, null fields inherit `base` (documented precedence).
- **Copy source:** none verbatim — shape from architecture §5; merge semantics from zigzag Style-builder inheritance (tui-architectures §2 zigzag row) simplified to per-field.
- **Tests:** eql true/false across every field; merge precedence matrix (self overrides base per field, defaults fall through); `@sizeOf(Attrs) == 1`.
- **Acceptance:** all tests green.

### T1.3 — src/cell.zig + src/emit.zig
- **File:** `src/cell.zig` (new), `src/emit.zig` (new), `src/root.zig` (re-export both).
- **Implement:**
  - `Cell` (§5): `grapheme: []const u8 = " "`, `style: Style = .{}`, `wide: bool = false`; `eql` = slice eql + style eql + wide. NOTE: architecture's Cell stores a grapheme *slice* (not a `u21` codepoint as in zigzag screen.zig:11) — the adaptation is structural; `Buffer.draw` fills it from zg grapheme iteration.
  - `emit.zig` (§5): `hideCursor`/`showCursor`, `cursorTo(w, row, col)` (1-indexed, zigzag `ansi.zig:66`), `eraseToEnd` (CSI J — the strategy-2 clear), `eraseLine` (CSI K), `appendLines(w, n)` (CSI n E — space reservation, §4.2), `scrollRegionUp(w, n)` (CSI n S), `queryCursor` (CSI 6n — CPR), `beginSync`/`endSync` (CSI ?2026h/l), `enterAltScreen`/`exitAltScreen` (?1049h/l), `writeStyle(w, s)`.
- **Copy source:** zigzag `terminal/ansi.zig` constants (:8-63) + cursor/SGR writers (:66-122, :294-321); OSC 52/8 functions are **not** copied (deferred).
- **Adaptation points:** all writers take `w: anytype` (std.Io.Writer-compatible) instead of zigzag's `*Writer`; `writeStyle` is the SGR-delta core used by `renderDiff` — emits only non-default fields; color emission is **profile-gated**: `ColorProfile.ansi256` downsamples rgb via ansi256ToRgb inverse (zigzag `color.zig:194`), `.ansi` maps to nearest base color; a `writeStyle` that ends in default emits `CSI 0m`.
- **Tests:** fake `std.Io.Writer` (StringWriter pattern, like libvaxis TestTty / zigzag snapshot style) capturing exact bytes: cursorTo goldens (`\x1b[5;10H`), appendLines, sync wrap, CPR, alt-screen; writeStyle goldens: bold red → `\x1b[1;31m`, rgb fg on truecolor → `\x1b[38;2;r;g;bm`, rgb on ansi256 profile → downsampled `38;5;Nm`, empty style → `\x1b[0m`.
- **Acceptance:** all tests green; emit.zig contains no zg import (pure ANSI bytes).

---

## P2 — parser / key / mouse / event

Goal: full input decoding, libvaxis-copied, uucode→zg-swapped, with the
CPR divergence and a conformance vector suite. Headless: pure functions,
no tty. Independent of P1.

### T2.1 — src/event.zig + src/key.zig
- **File:** `src/event.zig` (new), `src/key.zig` (new), `src/root.zig` (re-export).
- **Implement:**
  - `Event` (§5) — libvaxis `event.zig` copy adapted: keep `key_press`, `key_release`, `mouse`, `focus_in`, `focus_out`, `paste: []const u8`, `color_report: Color.Report`, `winsize: Winsize`; add `cpr: Pos` (the divergence, §3); replace the 8 individual `cap_*` tags with one `cap: Capability`. Drop `paste_start`/`paste_end`/`mouse_leave`/`color_scheme` (not in §5).
  - `pub const Pos = struct { row: u16, col: u16 }` (1-indexed, DEC CPR convention) — new internal type in event.zig.
  - `pub const Capability = enum { kitty_keyboard, sgr_pixels, bracketed_paste, sync_output, unicode_core, rgb, focus_events }` — **defined in event.zig** (not caps.zig) to keep the import DAG acyclic: parser→event, caps→parser+event. This is a placement resolution, not an API addition.
  - `Winsize` = libvaxis `{ rows: u16, cols: u16, x_pixel: u16, y_pixel: u16 }`.
  - `Key` (§5) — libvaxis `Key.zig` copy: `Modifiers` packed struct(u8) (:7), `KittyFlags` packed struct(u5) (:25), PUA consts (:179-285), `name_map` (:287), `matches` (:59), `matchShortcut` (:82), `matchExact`/`matchesAny`/`matchShiftedCodepoint`/`matchText`/`isModifier`. Add `pub const ctrl_c: u21 = 0x03` (§5 lists it; libvaxis lacks it — add next to `tab`/`enter`/`escape` :167-169).
- **Copy source:** libvaxis `Key.zig` (no uucode import — verified clean), libvaxis `event.zig`, libvaxis `Cell.zig` (Color.Report :137).
- **Adaptation points:** Key.zig is a verbatim copy (zero dep work); event.zig changes are the union-shape edits above.
- **Tests:** port libvaxis Key.zig tests (matches/matchShortcut incl. caps-lock/num-lock stripping, alt-layout); modifiers eql; PUA constants spot-checked against kitty spec values (f1=57364, up=57352); ctrl_c == 0x03.
- **Acceptance:** tests green; no zg import.

### T2.2 — src/mouse.zig
- **File:** `src/mouse.zig` (new), `src/root.zig` (re-export).
- **Implement:** §5 mouse.zig surface — libvaxis `Mouse.zig` verbatim (55 ln): `Shape`, `Button` (incl. wheel 64-67, buttons 128-131), `Modifiers` packed struct(u3), `Type` (press/release/motion/drag), fields `col/row/xoffset/yoffset/button/mods/type` (SGR 1006 + pixel 1016 payloads).
- **Copy source:** libvaxis `Mouse.zig` (verbatim).
- **Tests:** refAllDecls; Button/modifier bit values; field defaults (`xoffset`/`yoffset` = 0).
- **Acceptance:** tests green.

### T2.3 — src/parser.zig (the dep-swap core)
- **File:** `src/parser.zig` (new), `src/root.zig` (re-export).
- **Implement:** §5 parser.zig surface: `Parser` with `buf` scratch (libvaxis :44-50 pattern), `pub const Result = struct { event: ?Event, n: usize }`, `pub fn parse(self: *Parser, input: []const u8, paste_allocator: ?std.mem.Allocator) !Result` (null event + n==0 ⇒ incomplete). Copy the 9-state machine from libvaxis `Parser.zig` (1332 ln): `parse` dispatch (:53), `parseGround` (:99), `parseSs3` (:151), `parseCsi` (:329) with kitty CSI-u + modifiers + event types (:446+), legacy keys, `parseOsc` (:235) with OSC 52 paste decode (:315-323), OSC 4/10/11/12 color reports, `parseApc` (:65), `skipUntilST` (DCS/SOS/PM/APC), bracketed paste 200~/201~ (:447-448), kitty keyboard cap reply (:561), multi-cursor cap (:667).
- **Copy source:** libvaxis `Parser.zig`.
- **Adaptation points (the uucode→zg swap, localized to `parseGround` :108-141):**
  1. Replace `uucode.utf8.Iterator.init(input)` with `std.unicode.Utf8View.init(input)` iteration for the first codepoint (`InvalidUTF8` behavior preserved via `Utf8View.init` error).
  2. Replace `uucode.grapheme.Iterator(uucode.utf8.Iterator)` with `Graphemes.iterator(input)`: first grapheme's byte span comes from its `.offset`/`.len` (zg Graphemes.zig :83 `bytes`); `n = first_grapheme.len`; count codepoints inside the first grapheme with `std.unicode` to preserve the `cp_count > 1 → Key.multicodepoint` rule.
  3. CPR divergence: `parseCsi` currently maps final `'R'` to legacy F3 (:347, :370). When final == `'R'` **and** the sequence carries numeric parameters (`\x1b[{row};{col}R`), return `Event{ .cpr = Pos{ .row, .col } }`; bare `\x1b[R` (no params) stays F3. This replaces libvaxis's out-of-band shift+F3 decode trick (vaxis app-loop level; architecture §3).
  4. Map cap replies to the single `Event.cap: Capability` tag; drop mouse_leave/paste_start/paste_end.
  5. Imports change from libvaxis's internal `@import("main.zig")` style to direct local imports (`Key.zig`, `Mouse.zig`, `event.zig`, `color.zig`).
- **Conformance vectors (risk §9.6 — the suite is the acceptance bar):** port the entire libvaxis Parser.zig test block (parse: paste_start :894, paste_end :905, osc52 paste :916, kitty shift+a :955, alt+shift+a :972, a-without-text :988, release :1002, multi-cursor :1154, plus all CSI/SS3/OSC fixtures, ~30 tests) **unchanged**, then add: cpr vectors (`\x1b[5;10R` → cpr{5,10}, `\x1b[R` → F3, `\x1b[1;1R`); ground-state grapheme vectors (ZWJ family `👨‍🌾` → key_press with text + multicodepoint, combining mark `e\u{301}` → multicodepoint, plain ascii passthrough); incomplete input (`\x1b[` alone, half a kitty seq) → event null + n==0.
- **Acceptance:** full vector suite green; every byte-sequence that libvaxis tests cover produces the identical event except the documented divergences (cpr, cap union, dropped tags) — verified by diffing the ported fixture expectations.

---

## P3 — tty / caps

Goal: raw mode, winsize/SIGWINCH, panic-restore, and live capability
queries (no terminfo).

### T3.1 — src/tty.zig
- **File:** `src/tty.zig` (new), `src/root.zig` (re-export).
- **Implement:** §5 tty.zig surface:
  - `pub fn init(io: std.Io) !Tty` — open `/dev/tty` (libvaxis `tty.zig:57` pattern) for input, thread `io` for output; install SIGWINCH handler setting an atomic flag (zigzag `posix.zig:185-204`); register `global_tty` for panic restore (libvaxis `tty.zig:24-27`).
  - `pub fn deinit(self: *Tty) void` — restore + uninstall handler (libvaxis :105-109 resetSignalHandlerLocked).
  - `pub fn isTty(fd: posix.fd_t) bool` — TIOCGWINSZ ioctl probe (zigzag `posix.zig:44-47`).
  - `pub fn makeRaw(self: *Tty) !void` / `pub fn restore(self: *Tty) void` — termios: ICANON/ECHO/ISIG/IEXTEN/IXON off, MIN=0/TIME=1, save original (zigzag `posix.zig:67-122`).
  - `pub fn getWinsize(self: *Tty) !Winsize` — ioctl TIOCGWINSZ (libvaxis `tty.zig:205-221`), graceful fallback 80x24 on error.
  - `pub fn checkResize(self: *Tty) bool` — atomic flag swap (zigzag `posix.zig:202`).
  - `pub fn writer(self: *Tty) *std.Io.Writer` and `pub fn read(self: *Tty, buf: []u8) !usize`.
- **Copy source:** zigzag `terminal/platform/posix.zig` (raw mode, isTty, SIGWINCH flag, poll), libvaxis `tty.zig` (winsize struct, panic-restore global, /dev/tty open).
- **Adaptation points:** zigzag is fd-based; add the `std.Io` handle per §5 and libvaxis's open-/dev/tty + panic-restore; drop Windows paths and the notifyWinsize callback registry (v0 uses one atomic flag).
- **Tests:** `isTty` on /dev/null → false; `getWinsize` error path returns fallback; raw-mode flag assembly extracted as a pure fn (`rawTermios(orig) termios`) with unit vectors (ICANON/ECHO cleared, MIN/TIME set); `checkResize` false until flag set; deinit restores termios (via a real PTY pair when available, else [UNVERIFIED] skip).
- **Acceptance:** tests green; `zig build test` runs headless (no tty needed).

### T3.2 — src/caps.zig
- **File:** `src/caps.zig` (new), `src/root.zig` (re-export).
- **Implement:** §5 caps.zig surface:
  - `Capabilities` struct (9 bools + profile default `.ansi256`).
  - `pub const WidthPolicy = enum { zg_unicode, wcwidth_legacy, no_zwj }` + `widthPolicy()` — v0 returns `.zg_unicode` unless ?2027 reports unsupported (then `.wcwidth_legacy`); the `no_zwj` branch is reserved (architecture §3: "probe hook is reserved").
  - `pub fn detect(tty: *Tty, parser: *Parser, alloc: std.mem.Allocator) !Capabilities` — sequential live queries, each: write query bytes → poll with a per-query deadline (e.g. 250ms) → read → `parser.parse` → match `Event.cap`/`color_report` replies. Queries: DA1 (`\x1b[c`) for sixel-param + rgb; `?2026` sync (DECRPM `\x1b[?2026;1$y`); `?2027` unicode-core (DECRPM); kitty keyboard `\x1b[>1u` (reply `\x1b[>1;…u`); RGB via OSC 11 background query → `color_report` with rgb kind. Failed/timeout query = feature off, no error (queries are best-effort).
- **Copy source:** zigzag `terminal/terminal.zig` query fns: `queryMode2027Support` :1556, `parseMode2027Response` :1583 (DECRPM `\x1b[?2027;{d}$y` → bool), DA1 parse :1514-1546, `selectWidthStrategy` :1618; libvaxis `ctlseqs.zig` for query strings (sync ?2026, kitty ?u, OSC 11).
- **Adaptation points:** queries reuse the *parser* for decode (no hand-rolled response scanning except tiny DECRPM/DA1 splitters); drain input between queries (zigzag `drainInput` :1394 pattern) so stale replies don't alias.
- **Tests:** pure response parsers (DECRPM 2026/2027 true/false vectors, DA1 param extraction, `rgbFromSpec` integration); detect() against a canned fake tty/reader script (query bytes in → canned replies → expected Capabilities struct); timeout path → defaults, no hang.
- **Acceptance:** tests green; no terminfo anywhere.

---

## P4 — buffer

Goal: the cell grid + double-buffer diff renderer (zigzag screen.zig
model) with zg width enforcement and graceful truncation.

### T4.1 — src/buffer.zig: grid + draw
- **File:** `src/buffer.zig` (new), `src/root.zig` (re-export).
- **Implement:** §5 buffer.zig surface: `init(allocator, width, height) !Buffer` (flat `[]Cell` — zigzag `screen.zig:70-85`), `deinit`, `resize` (alloc new, copy overlap — zigzag :88-117), `clear` (@memset Cell{}), `get(x, y) Cell` (bounds-checked, returns empty Cell out of bounds), `set(x, y, cell) !void` with wide-char handling — zigzag `setCell` :115-154 adapted: overwriting a wide continuation nulls its left half; overwriting a wide lead nulls its continuation; a width-2 grapheme sets `wide` continuation carrying the style. Width source: `width.graphemeWidth` (replaces `unicode.charWidth`). `draw(style, text, x, y) !u16` — grapheme-aware write (zigzag `writeString` :157-188 adapted to iterate zg graphemes, set `grapheme` slice + `wide` flag), **graceful truncation**: grapheme that doesn't fit at the row end is dropped (never error, never partial bytes); zero-width graphemes skipped; returns cells written.
- **Copy source:** zigzag `terminal/screen.zig`.
- **Adaptation points:** Cell is slice-based (`grapheme: []const u8`) not codepoint-based (screen.zig:11 `char: u21`) — set stores the slice (borrowed, not copied, per §3 "points into app text arena"); width from `width.zig` not `unicode.charWidth`; `set` returns error only for alloc-independent invariants (none — signature kept `!void` for §5 parity, no throw paths in v0 [UNVERIFIED: kept for API stability]).
- **Tests:** wide glyph placement (lead + styled continuation); overwrite continuation → lead nulled; overwrite lead → continuation nulled; draw of `"ab👨‍🌾cd"` at x=3 with a wide glyph crossing the edge → dropped gracefully; zero-width/combining marks advance no column; resize overlap copy (smaller + larger); clear.
- **Acceptance:** tests green; buffer.zig's only width source is `width.zig`.

### T4.2 — src/buffer.zig: renderDiff + renderAll
- **File:** `src/buffer.zig` (edit).
- **Implement:** §5 `renderDiff(self: *const Buffer, prev: *const Buffer, w: anytype) !void` and `renderAll(self: *const Buffer, w: anytype) !void`:
  - **renderAll**: hideCursor→cursorTo row 1? No — renderAll is band-scoped: emit each row from the anchor with `\r` + eraseLine + cells (region strategy 2 uses it after `ESC[J`). Style-tracking SGR deltas: emit `writeStyle` only when the current emitted style differs from the cell's (libvaxis DAM pattern); skip cells equal to the previous emitted cell; wide-continuation cells never emit text.
  - **renderDiff**: walk rows; first changed row via `\r` + CNL/`\n` relative moves; erase the stale tail with `\r` then `eraseLine` (**column-1 erase — the tmux scroll-on-clear mitigation, §9.7**); emit only changed cells with style deltas; idle frame (cur == prev) emits **nothing** (§3: idle frames emit nothing).
  - Both write through `w: anytype` (std.Io.Writer-compatible); both wrap nothing (sync wrapping is the region's job).
- **Copy source:** zigzag `terminal/screen.zig` diff section (:190-306 [UNVERIFIED exact range — the renderDiff/render loop]), libvaxis DAM style-tracking pattern.
- **Tests:** fake-writer goldens: full row set → exact byte string; one-cell change → only that cell's bytes; style-only change → SGR delta only; prev == cur → zero bytes; wide-cell emission skips continuation; column-1 erase golden (`\r\x1b[K` before changed rows).
- **Acceptance:** tests green; renderDiff is the only cursor-movement/erase writer the region uses (contract with P5).

---

## P5 — region (the centerpiece)

Goal: the inline Region renderer — 3 strategies, append queue, anchoring,
exit, non-TTY degradation. Six sub-steps, each landing on `zig build test`.

Design resolutions before the first task (under-specification in §4/§5,
resolved here, no API change):
- **Anchor + CPR wiring.** §5 gives no channel for a CPR reply to reach
  Region (render only receives a writer). Resolution: Region's anchor is
  **tracked from its own writes** — it only ever emits relative moves
  (`\r`, `\n`, CNL), never absolute CUP (libvaxis primary-screen
  pattern), so its accounting is exact absent external writes.
  `reanchor()` sets `anchor_dirty`; the next `render()` emits
  `queryCursor` at frame start (on first render and after resize, per §10
  "CPR reanchor on first render + resize"). The reply surfaces as
  `Event.cpr` for the app; v0 Region does not consume it — drift
  correction is deferred with fd-capture (§9.2). [INFERENCE — plan-level
  resolution, flagged for the orchestrator.]
- **Non-TTY degradation** (§4.8) maps onto the existing
  `Options.sync_output` knob: when false, Region skips the §4.8 sequence
  set (hideCursor, beginSync/endSync, CPR query) and renders one plain
  frame; the app recipe (P7) sets it from `tty.isTty(stdin_fd)` and skips
  `makeRaw`. No API addition. [INFERENCE — flagged.]
- **Cursor hygiene:** Region hides the cursor on the first interactive
  render (only when sync_output is on) and shows it in `exit`.

### T5.1 — Region skeleton + anchor state
- **File:** `src/region.zig` (new), `src/root.zig` (re-export).
- **Implement:** §5 region.zig types: `Options` (height, append_lines,
  sync_output, width_policy — defaults per §5), `Append` union
  (text/line), `Region` struct holding: `gpa`, `cur`/`prev` Buffers,
  `opts`, `anchor_row: u16`, `high_water: u16`, `anchor_dirty: bool`,
  `width_dirty: bool`, `first_frame: bool`, `append_queue` (array list of
  Append), `height`/`width`. `init(gpa, opts) !Region` (buffers sized
  width=0 initially — first resize/render sizes them; or 80xopts.height
  [UNVERIFIED: orchestrator picks]), `deinit` (free buffers + queue,
  allocator hygiene via testing.allocator in tests).
- **Tests:** init/deinit under `testing.allocator` (no leaks); Options
  defaults; append queue append/list round-trip.
- **Acceptance:** tests green; region.zig imports only buffer, emit,
  width (no zg direct, no tty — Region is writer-agnostic).

### T5.2 — strategies 1 + 3 (first render, normal diff)
- **File:** `src/region.zig` (edit).
- **Implement:** `render(w) !void` main flow + strategy selection:
  - **Strategy 1 (first render):** append all `height` lines WITHOUT
    clearing, writing rows from the tracked anchor via `\r` + CNL;
    set `high_water = height`; `first_frame = false`. (Scrollback
    preservation: nothing above the anchor is ever cleared, §4.5.)
  - **Strategy 3 (normal):** find first changed row (Buffer
    renderDiff-style scan against `prev`), move there with relative
    moves, `\r` + `eraseLine` (column-1 erase, §9.7), emit changed rows
    with `renderDiff`-style style-tracking; **high-water clear-on-shrink**:
    if the new content is shorter than `high_water`, erase the rows
    between content end and `high_water` (`\r` + eraseLine per row, or
    eraseToEnd after the last content row), then `high_water = len`.
  - Frame wrap: when `opts.sync_output`, beginSync before, endSync after
    (§4.3: all frames wrapped).
  - Idle: `cur == prev` and no pending work → emit nothing (after the
    first frame).
- **Tests:** fake-writer goldens per scenario: first render byte-exact
  (height lines, no clear); changed-middle-row diff; shrink clears the
  stale tail; idle frame → zero bytes; sync wrap present/absent per
  opts; wide-glyph row diff (continuation never emitted).
- **Acceptance:** tests green; strategy 2 not yet wired (width_dirty
  path returns strategy-1 fallback until T5.3).

### T5.3 — strategy 2 (width change / forced full redraw)
- **File:** `src/region.zig` (edit).
- **Implement:** when `width_dirty` (set by `resize`, or a forced flag):
  `eraseToEnd` from the anchor row (`ESC[J` — bounded to the band by the
  anchor, never above it), then full re-render of all `height` rows via
  `renderAll`; clear `width_dirty`. This is **the guard against the
  ratatui resize-duplicates-into-scrollback bug** (§9.3): on width change
  the old width's rows are erased before new-width rows emit, so no stale
  tails survive to scroll up. `resize(new_width, new_height) !void`:
  realloc both buffers (overlap copied — Buffer.resize), set
  `width_dirty = true` and `anchor_dirty = true`.
- **Tests:** fake-writer goldens: resize 20→40 cols emits ESC[J + full
  row set, no partial-width leftovers; resize taller/shorter re-emits
  exactly `height` lines (never more — §9.3 "never emit more than height
  lines"); width_dirty clear after render; consecutive resizes.
- **Acceptance:** tests green; strategy selection: width_dirty → 2,
  first_frame → 1, else → 3.

### T5.4 — append queue (print-above escape hatch)
- **File:** `src/region.zig` (edit).
- **Implement:** `append(self, item: Append) !void` queues (Append.text /
  Append.line). Before the region renders each frame, flush the queue
  (§4.4): move cursor to region top (relative move up `height` rows),
  `ESC[J`, write each item with `\n` → `\r\n` translation, then re-fix
  the anchor (the region top moved: tracked anchor shifts up by the
  number of terminal rows the appends consumed — for `text` items the
  terminal's own wrap decides rows, so the anchor is re-queried next
  frame via `anchor_dirty`; for `line` items the row count is known
  exactly and the anchor shifts deterministically). `Append.line` is
  written verbatim (exact hard-wrapped layout, vaxis AppendWidget split);
  `Append.text` passes through as styled spans the terminal reflows.
- **Tests:** fake-writer goldens: queued text flushes before region rows;
  `\n` becomes `\r\n`; line items byte-identical; anchor shift bookkeeping
  for line items; empty queue → no flush bytes; queue drains per frame.
- **Acceptance:** tests green; flush only ever writes at/above the region
  band (grep-gate: no `2J` full-screen clear in region.zig — the tmux
  snapshot guard, §9.7).

### T5.5 — reanchor + CPR emission
- **File:** `src/region.zig` (edit).
- **Implement:** `reanchor(self) !void` sets `anchor_dirty = true` (the
  §5 signature has no writer — the query fires from render, per the
  resolution above). `render()` start: if `anchor_dirty` and
  `opts.sync_output`, emit `queryCursor` (CPR) into `w`, clear the flag.
  Also wire the §4.2 origin-shift accounting: when
  `opts.append_lines`, reserve the band with `appendLines(w, height)`
  once (first render); origin drift after appends/scroll is detected by
  the tracked-anchor mismatch and triggers `anchor_dirty` again.
- **Tests:** first render emits `\x1b[6n` before content; resize re-queries;
  steady-state frames emit no CPR; sync_output=false → no CPR.
- **Acceptance:** tests green; anchor is never derived from an absolute
  CUP — grep-gate: no `cursorTo` call inside region.zig.

### T5.6 — exit + non-TTY degradation
- **File:** `src/region.zig` (edit).
- **Implement:** `exit(w) !void` (§4.7): showCursor (only if hidden),
  endSync (if sync_output), park `\r\n\r` below the last region row
  (anchor + height), **no clear** — the final frame stays in the
  transcript. Non-TTY path (§4.8, per resolution): with
  `sync_output = false`, render behaves as strategy-1-once + no
  hide/CPR/sync; exit parks nothing (a plain final frame was the only
  output — ink/delta pattern).
- **Tests:** exit golden bytes (`\r\n\r` park, cursor shown, sync closed);
  exit idempotent; piped-mode render+exit emits no control sequences
  beyond the frame bytes and the park is absent.
- **Acceptance:** tests green; P5 complete → `zig build test` green.

---

## P6 — input reader

Goal: blocking read + split-sequence reassembly (zigzag
`incompleteTailLen` verbatim).

### T6.1 — src/input.zig: Reader core
- **File:** `src/input.zig` (new), `src/root.zig` (re-export).
- **Implement:** §5 input.zig surface:
  - `pub fn init(tty: *Tty) Reader` — holds tty, `pending: []u8` (fixed
    512B buffer, libvaxis/vaxis 256B read + hold-back pattern), scratch.
  - `pub fn incompleteTailLen(data: []const u8) usize` — zigzag
    `input/keyboard.zig:320` verbatim (last ESC byte; everything after is
    a possibly-incomplete sequence).
  - `pub fn next(self: *Reader) !Event` — `poll` on the tty fd (zigzag
    posix.zig `readInput` :158-175), read ≤256B, prepend the previous
    `pending` tail, call `Parser.parse`, hold back `incompleteTailLen`
    bytes into `pending` (so kitty CSI-u / paste / OSC tails never leak
    as literal chars), return the single Event. Contract (documented):
    `Key.text`/`paste` point into the read buffer and are valid only
    until the next `next()` call — apps copy into their own arena (§3).
- **Copy source:** zigzag `input/keyboard.zig` (`incompleteTailLen` :320
  verbatim; split-seq reassembly pattern), zigzag `terminal/platform/posix.zig`
  (`readInput` poll :158-175).
- **Tests:** split-sequence vectors: `"\x1b["` then `"1;5u"` across two
  reads → one kitty key event, no literal `[`; escape alone vs
  escape-prefixed (gate in Parser.parse :56); multibyte UTF-8 cut at the
  256B boundary reassembles; paste tail held across reads;
  incompleteTailLen edge cases (empty, all-escape, full valid sequence →
  0).
- **Acceptance:** tests green; Reader is the only user of the tty fd in
  the input path.

### T6.2 — nextTimeout + event loop integration
- **File:** `src/input.zig` (edit).
- **Implement:** `pub fn nextTimeout(self: *Reader, timeout_ms: i32) !?Event`
  — same as next but `poll` with a deadline; null on timeout (tick
  pacing for spinner-style apps, bubbletea fps pattern). Ctrl+C arrives
  as a normal key event (`Key.ctrl_c`); the library never quits (§10:
  "no hard quit").
- **Tests:** timeout path returns null without consuming input; pending
  tail survives a timeout (a sequence split across a tick boundary still
  reassembles); ctrl+c decodes as `key_press` with codepoint 0x03;
  integration via a pipe-fed fake fd pair (write bytes to the pipe, read
  through Reader) — no tty required (zigzag custom-I/O pattern,
  tui-architectures §2 zigzag).
- **Acceptance:** tests green; P6 complete → `zig build test` green.

---

## P7 — examples + docs

Goal: three composition recipes proving the primitives compose (risk
§9.1 mitigation), plus docs. Ends the v0.

### T7.1 — build.zig example steps
- **File:** `build.zig` (edit).
- **Implement:** for each of `examples/spinner.zig`, `examples/prompt.zig`,
  `examples/statusline.zig`: `addExecutable` with imports `notui` + zg
  trio (same wiring as the lib module), install artifact, and a
  `run-example-*` step. Leave `src/main.zig` (version banner) untouched;
  `zig build run` stays as-is.
- **Tests:** none — acceptance is `zig build` green and
  `zig build run-example-spinner -- --help`-style dry run
  (orchestrator executes interactively).
- **Acceptance:** three example artifacts build.

### T7.2 — examples/spinner.zig
- **File:** `examples/spinner.zig` (new).
- **Implement:** the minimal recipe: `Tty.init(io)` → `makeRaw` →
  `Caps.detect` → `Region.init` with a fixed `Options` → loop {
  `Reader.nextTimeout(100)` → switch: `.key_press` ctrl_c/q → break;
  `.winsize`/`Tty.checkResize()` → `Region.resize` } → `Region.render`
  with a 1-line spinner frame (rotating glyphs from a `const []const []const u8`
  table, drawn via `Buffer.draw` + `renderDiff`) → `Region.exit` →
  `Tty.restore`.
- **Acceptance (manual):** spins at the tick rate; `q`/ctrl+c exits;
  after exit the spinner's last frame stays visible in the transcript
  with the cursor parked below it (no clear); no duplicate rows when the
  terminal is resized mid-run.

### T7.3 — examples/prompt.zig
- **File:** `examples/prompt.zig` (new).
- **Implement:** prompt recipe: region shows a "prompt > " line + echo;
  typed keys append to an app-owned arena (copied out of `Key.text`
  before the next read — demonstrates the §3 lifetime contract);
  Enter appends the typed line to the **append queue** (`Region.append`
  `.line`) so each entry lands above the region in scrollback; resize
  handled via `Tty.checkResize` → `Region.resize` (strategy-2 clear+redraw);
  backspace edits; ctrl+c = normal key event (clears the line) — the app
  decides to quit only on explicit `q` or `ctrl+d`.
- **Acceptance (manual):** typed input echoes in-band; each Enter pushes
  the line into scrollback above the region; resizing mid-session leaves
  no duplicated/stale rows in the transcript; exit parks cleanly.

### T7.4 — examples/statusline.zig + docs
- **File:** `examples/statusline.zig` (new), `README.md` (edit/new),
  `notes/README.md` (edit — link the plan).
- **Implement:** statusline recipe demonstrating composition breadth:
  styled segments (fg/bg/attrs via `Style` + `writeStyle`-driven
  `Buffer.draw`), `width.truncate` + `width.wrap` for segment text,
  ColorProfile fallback (rgb style on an ansi256 profile), and the
  **non-TTY path**: when `!tty.isTty(stdin_fd)` (piped), skip `makeRaw`,
  build `Region.Options{ .sync_output = false }`, render one plain frame,
  exit without parking. Also documents the fd-capture interaction (§9.2:
  external fd1/fd2 writes can drift the anchor — known, deferred).
- **Acceptance (manual):** styled segments render; narrowing the terminal
  truncates segments gracefully (no over-wide rows, no crash — §8.8);
  `zig build run-example-statusline < /dev/null | cat` prints exactly one
  plain frame and exits 0 with no interactive control sequences and no
  hang.
- **Tests:** none beyond existing; acceptance is the manual + piped
  checklist above.

---

## 2. Risk → task fold map (architecture §9)

| Risk | Folded into |
|---|---|
| R1 primitives-composition burden | P7 examples (recipes) + T6.2 Reader removes buffering fiddliness |
| R2 anchor drift | T5.5 tracked-anchor accounting + reanchor-on-resize; documented in T7.4 |
| R3 scrollback duplication on resize | T5.3 strategy-2 clear+full-redraw tests (≤height lines invariant) |
| R4 wide-glyph mis-measurement | T0.1 width seam, T4.1 width-enforced set/draw + graceful truncation |
| R5 zg coupling | T0.1 seam-only-import grep-gate; pinned 0.16.2 |
| R6 parser dep swap | T2.3 conformance vector suite ported before divergence |
| R7 tmux scroll-on-clear | T4.2/T5.2 column-1 erase (`\r` + `ESC[K`); T5.4 grep-gate on `2J`; sync wrap every frame |

## 3. Whole-v0 verification checklist (orchestrator)

Run after P7, in order; every item must pass:

1. `zig build` (Debug) — compiles lib, exe, three examples.
2. `zig build test` — full unit suite green (all P0–P6 tests).
3. `zig fmt --check` (repo root) — zero diffs (run per phase during
   building, final pass here).
4. `zlint` — repo has `zlint.json` (unused-decls / suppressed-errors /
   avoid-as, all `warn`); orchestrator runs the project's zlint
   invocation and confirms no rule **errors**; warnings reviewed
   [UNVERIFIED: exact CLI flags for this repo's zlint setup — check
   devenv.nix/AGENTS.md before first run].
5. Interactive smoke, one per example:
   - `zig build run-example-spinner` — spins, quits on q/ctrl+c, last
     frame stays in transcript, cursor parked below, no resize dupes.
   - `zig build run-example-prompt` — echo + backspace + Enter appends
     lines to scrollback above the region, resize clean, clean exit.
   - `zig build run-example-statusline` — styled segments, graceful
     truncation on narrow width, clean exit.
6. Piped/non-TTY smoke:
   - `zig build run-example-spinner < /dev/null | cat` and the same for
     prompt/statusline: exit 0, no hang, single plain frame, no
     interactive control-sequence garbage (spinner emits one frame;
     prompt/statusline emit their one-frame content).
7. Grep-gates re-checked across `src/`: zg imports only in `width.zig`;
   no `2J` in `region.zig`; no `cursorTo` in `region.zig`.

**"Done" per example app** = items 5a/5b/5c respectively pass end to end
(frame behavior, input, resize, exit state in the transcript) AND the
piped variant (6) passes — that is the observable definition of the v0
contract: inline-first scrollback preservation by default, graceful
non-TTY degradation, no hard quits.
