# Zig 0.16 Terminal Foundations — API Landscape

Scope: the foundational APIs for building an inline-first TUI in Zig 0.16:
text/unicode, pty, terminal, ansi, input, kitty graphics protocol, and the
testing story. Companion to `notes/research/tui-landscape.md` (screen
ownership). All facts verified against local sources (zig 0.16.0 std,
vendored zigzag, libvaxis fork) and primary remote sources on 2026-08-11
unless marked `[UNVERIFIED]`.

## std 0.16 audit — what the standard library gives and withholds

Verified against `/nix/store/.../lib/zig/std` (0.16.0).

**std gives (for free):**
- `std.unicode` — fast UTF-8/UTF-16/WTF-8 codecs only: `Utf8View`,
  `Utf8Iterator` (codepoint iteration), `utf8Encode/Decode`,
  `utf8ValidateSlice`, `utf8CountCodepoints`, converters. No graphemes.
- `std.posix` — `termios` (:198), `winsize` (:255), `tcgetattr` (:1163),
  `tcsetattr` (:1178), `tcgetpgrp`/`tcsetpgrp`; `T.IOCSWINSZ`/`IOCGWINSZ`
  (os/linux.zig:5135); `std.os.linux.ioctl` (:2759). termios flags are
  packed bool structs (os/linux.zig:7629) — raw mode is flipping
  ICANON/ECHO/ISIG/IEXTEN yourself.
- `std.process` — `Child`, `spawn`/`spawnPath`, `StdIo` pipe redirection
  (inherit/file/ignore/pipe/close), `Environ`, `Args`.
- `std.Io` — async sleep/timers (`io.sleep`), `Clock.now`, random, `Group`
  (thread pool), net, `File.isTty`, `supportsAnsiEscapeCodes`.
- `std.heap` — arena/pool/debug allocators; `std.mem` slice utilities.

**std withholds (TUI must source elsewhere):**
1. Display width / wcwidth / east-asian width — grep across all of std:
   zero hits.
2. Grapheme segmentation, emoji/ZWJ/combining tables — zero hits.
3. Unicode case mapping / normalization — ASCII-only (`std.ascii`).
4. Raw-mode helper — no one-call `raw()`; termios flag assembly is DIY.
5. Terminfo — nothing.
6. PTY helpers (`openpty`/`forkpty`/`login_tty`, `ptsname`/`grantpt`/
   `unlockpt`) — absent from `std.posix`; only reachable via `std.c`/libc.
7. Winsize application — no helper; raw `ioctl(fd, IOCSWINSZ, &ws)`.
8. Input/key parsing (CSI/SS3, kitty, bracketed paste) — nothing.
9. `Io/Terminal.zig` is color-only (15 SGR values, `Mode.detect` honoring
   NO_COLOR/CLICOLOR_FORCE) — no cursor, no queries.
10. `std.fmt` padding is **byte-based** (`Io/Writer.zig:1014`
    `buffer.len`), misaligns multibyte text — own display-width aligner.

## Ecosystem by category

### Text / Unicode

| Lib | Repo | 0.16 | License | Capability |
|---|---|---|---|---|
| **zg** | codeberg atman/zg, v0.16.3 | ✅ | MIT | The complete answer: `DisplayWidth` (strWidth, graphemeWidth, center/pad, **wrap**), `Graphemes` (fwd/rev iterators, UAX#29), Unicode 16 tables (GeneralCategories, Scripts, Emoji, LetterCasing, Normalize NFC/NFD/NFKC/NFKD, CaselessMatch); active (2026-08-01) |
| zig-wcwidth | joachimschmidt557/zig-wcwidth, v0.2.0 | ✅ | MIT | codepoint-level `wcwidth(u21) isize` (-1 controls), `wcswidth`, `sliceWidth`; no graphemes/emoji |
| uucode | jacobsandlund/uucode, v0.2.0 | ✅ | MIT | micro-configurable UCD tables (gencat, EAW, case, emoji), `grapheme.Iterator`, opt-in wcwidth field |
| zig-string | JakubSzark/zig-string, v0.10.0 | ✅ (min 0.16.1) | MIT | growable UTF-8 builder only; no width/graphemes |
| ziglyph | jecolon/ziglyph | ❌ | MIT | FROZEN 2023, superseded by zg |
| zig-unicode-ucd | nektro | ⚠️ no .zon | MIT | raw Unicode 17 tables (incl east_asian_width.zig), zigmod-only |

**Gaps:** text shaping (harfbuzz bindings ≤0.15; irrelevant for a TUI),
standalone word-wrap/truncate (only zg has wrap), standalone
east-asian-width (folded into the wcwidth libs).

### PTY

| Lib | Repo | 0.16 | License | Notes |
|---|---|---|---|---|
| zigpty | pithings/zigpty (★123) | ✅ min 0.16.0 | MIT | Cross-platform (Linux/macOS/Android/Windows ConPTY): openpty-equiv, spawn, resize, waitFor. Node.js-first but usable as standalone Zig pkg |
| zmux | smithersai/zmux (★62) | [UNVERIFIED] | — | tmux-style PTY session daemon; overkill |
| libvaxis `Pty.zig` | local fork | ✅ | vendored | Linux-only (`/dev/ptmx` + IOCSPTLCK/IOCGPTN + IOCSWINSZ), `@compileError` elsewhere; copyable verbatim |
| std.posix | — | — | — | **none** — openpty/forkpty only via `std.c` |

### Terminal / ANSI emit

| Lib | Repo | 0.16 | License | Capability |
|---|---|---|---|---|
| mibu | xyaman/mibu (★151) | ✅ 0.16.0 Linux+Win | MIT | raw mode, styles, 8/16/truecolor, cursor, clear, keys (codepoints/mods/special), mouse click/scroll/release (drag TODO), termbg detection. **Lacks:** queries/DA1/CPR, kitty keyboard/graphics, OSC 52/8, sync output — emit-only |
| ansi_term | ziglibs/ansi_term v0.3.0 | ✅ 0.16.0 | MIT | cursor, clear, SGR (+ parse), alt screen ?1049, sync ?2026, title, setSize; **no** raw mode/input/mouse/pty |

### VT parsing

| Lib | Repo | 0.16 | License | Notes |
|---|---|---|---|---|
| libvaxis `Parser.zig` | local fork | ✅ | vendored | Full 9-state DEC ANSI state machine → Event union: keys (legacy + kitty CSI-u), SGR/pixel mouse, bracketed paste, OSC 4/10/11/12 + 52 decode, APC-G cap, DA1 |
| libghostty-vt | Ghostty main (via termscope) | ✅ | MPL-2.0 | Ghostty's production parser as a lib — only reachable as a dependency |

### Kitty graphics / sixel / iTerm2

| Lib | Repo | 0.16 | License | Notes |
|---|---|---|---|---|
| kitty-graphics-zig | remorses (★1) | ⚠️ 0.14-era | MIT | base64 + POSIX shm transfer, RGB24/RGBA32, 4KB chunking; no capability query, no cache/placement mgmt |
| zixel | daredemo (★7) | ⚠️ 0.14-era | MIT | sixel encoder via zigimg; image-import only |
| **zigzag terminal.zig** | vendored | ✅ | MIT | **The mature impl**: transmit/place/delete with cache ids, chunked base64 (m=1/m=0), z_index, unicode placeholder, auto protocol kitty > iTerm2 > sixel (img2sixel subprocess), live probes (APC-G, iTerm2 Capabilities, DA1 param 4), env fallbacks (KITTY_WINDOW_ID/TERM_PROGRAM) |
| libvaxis `Image.zig` | local fork | ✅ | vendored | kitty transmit (file/temp/shm media), placement with scale (none/fill/fit/contain), clip, z_index; needs zigimg only for PNG decode |

### Kitty keyboard protocol

**No standalone zig lib exists** (GitHub search: empty). Implementations to
copy:
- libvaxis `Key.zig` — full: PUA keycodes (f1-35, kp_0-27, media, locks…),
  `Modifiers` (shift/alt/ctrl/super/hyper/meta/caps/num), `KittyFlags`
  (disambiguate, report_events, alternate keys, all-as-ctl, text),
  alt-layout aware `matches`/matchShortcut. Parser side in `Parser.zig`
  (CSI-u with `:event_type` repeat/release).
- zigzag `input/keyboard.zig` — smaller: CSI-u codepoint, event types,
  mods, `incompleteTailLen` split-seq buffering; bracketed paste 200~/201~.
- pi-tui `keys.ts` — legacy + kitty, `matchesKey(data, Key.ctrl('c'))`.

### OSC (52 clipboard, 8 hyperlinks, colors)

**No standalone zig lib.** Copyable:
- zigzag `terminal/ansi.zig` — OSC 52 **write and query-read** (base64,
  BEL|ST terminator, tmux/DCS passthrough, ESC-escaping, unit-tested);
  OSC 8 hyperlink.
- libvaxis `ctlseqs.zig` — OSC 52 copy + request, OSC 8 + clear, OSC
  4/10/11/12 query/set/reset, title/CWD/notify/mouse-shape.
- libvaxis `Parser.zig` — OSC 52 paste decode → `paste` event.
- Dead references: rockorager/tintin (OSC color query) and
  rockorager/termimg no longer exist (GitHub API: Not Found).

### Terminfo

Only two 0★ parsers (JackoCoolio/terminfo, asumbek/termilium), both
0.16-unverified, single-dev. Practice in zigzag/vaxis: skip terminfo;
capability detection via OSC/CSI live queries (DA1, APC-G, ?2027, ?2026,
OSC 66).

### Testing (headless terminals)

| Lib | Repo | 0.16 | License | Notes |
|---|---|---|---|---|
| termscope | mwunsch/termscope (★18) | ✅ | MPL-2.0 | headless emulator CLI on libghostty-vt: feed/observe VT output |
| libvaxis `widgets/terminal/` | local fork | ✅ | vendored | **Best embeddable target**: in-process VT emulator — spawns child on a PTY thread, DEC parser, pri/alt screens, 500-row scrollback, tab stops, sync-2026 aware, CSI-u keyboard encode back to child, title/CWD/bell events, SIGCHLD |

## Reusable local inventory — zero new deps

The vendored **zigzag** (`~/projects/skript/third_party/zigzag`) and the
**libvaxis** fork (`~/projects/libvaxis`) together cover the entire
foundation layer; everything below is copyable (MIT/vendored):

| Piece | Best source | What you get |
|---|---|---|
| Escape constants + OSC 52/8 + kitty APC-G + iTerm2 1337 | zigzag `terminal/ansi.zig` (373 ln, unit-tested) | sync ?2026, kitty `>1u`/`<u`, 2027, CPR, scroll regions, osc52 write/query, osc8 |
| Raw mode + TTY + SIGWINCH | zigzag `terminal/platform/posix.zig` or libvaxis `tty.zig` | termios raw (ICANON/ECHO/ISIG/IEXTEN/IXON off, MIN=0/TIME=1), isTty via TIOCGWINSZ ioctl, resize, panic restore (libvaxis) |
| Live capability queries | zigzag `terminal.terminal.zig` (1914 ln) | kitty-graphics probe, iTerm2 probe, DA1 + sixel param, ?2027, kitty text-sizing, OSC 52 read |
| Input parsing | libvaxis `Parser.zig` (full DEC) or zigzag `input/keyboard.zig` (smaller) | keys incl. kitty CSI-u, paste, SGR mouse (+pixel 1016), split-seq buffering |
| Display width | zigzag `unicode/display_width.zig` (own Unicode 16.0 table, 678 ln) or zg | wcwidth (-1/0/1/2), runtime legacy/unicode strategy switch (zigzag `unicode.zig`) |
| Grapheme width | libvaxis `gwidth.zig` (+uucode dep) | emoji VS16/ZWJ/RI/skin-tone, zero-width marks; note: pulls uucode |
| Double-buffer diff renderer | zigzag `terminal/screen.zig` | Cell model with wide-continuation, renderDiff, SGR diff |
| Color/theme | zigzag `style/color.zig` | ColorProfile detect, ansi256→RGB cube, contrast |
| Images | zigzag terminal.zig (pure zig) / libvaxis Image.zig | kitty transmit/place/delete, cache ids, auto protocol |
| PTY | zigpty (cross-platform) or libvaxis `Pty.zig` (Linux) | — |
| Embedded emulator for tests | libvaxis `widgets/terminal/Terminal.zig` | headless VT emulator + CSI-u encode |

## Consensus from the six foreign clones

Every real TUI (ratatui, bubbletea, vaxis, textual, pi-tui, libvaxis)
outsources exactly one foundation: **display width** (unicode-width /
go-runewidth / go-uucode / rich.cells / get-east-asian-width). Raw mode is
a small dep (crossterm, x/term) or own ioctl. ANSI/kitty parsing is
delegated by bubbletea (x/ansi) and textual (own `_xterm_parser.py` +
rich cells), hand-rolled by vaxis, pi-tui, libvaxis. Layout, buffer diff,
wrapping, and the renderer are **always self-implemented**. pi-tui is the
near-zero-dep reference: exactly 2 runtime deps (`get-east-asian-width`
for width, `marked` for Markdown), everything else hand-rolled.

## Recommendation for notui (inline-first, Zig 0.16)

1. **Display width** — the one non-negotiable. Either zg (v0.16.3, active,
   full Unicode 16 incl. graphemes+wrap) or the vendored zigzag table
   (zero-dep, house style, but static Unicode 16.0 without the surrounding
   unicode APIs). zg is the better library foundation; the zigzag table is
   the better zero-dep fallback.
2. **Raw mode / termios** — std gives termios + tcsetattr; copy zigzag's
   platform/posix.zig (~100 ln) — no dep needed.
3. **Input** — copy libvaxis `Parser.zig` + `Key.zig` (full kitty keyboard,
   pixel mouse, paste, OSC decode) — the most complete 0.16 source.
4. **Emit** — copy zigzag `ansi.zig` (constants, OSC 52/8, sync 2026) and
   `screen.zig` (diff renderer) — the inline renderer then builds on this.
5. **Capability detection** — copy zigzag's query functions; skip terminfo.
6. **Images** — zigzag's kitty API when needed (or libvaxis Image.zig if
   zigimg is acceptable).
7. **PTY + emulator** — zigpty (cross-platform) or libvaxis Pty.zig for
   tests; libvaxis's embedded Terminal widget as the headless test target.
8. **Skip** — terminfo libs (dead), standalone kitty-keyboard/OSC-52
   (don't exist), shaping (irrelevant for terminals).

## Sources

- std 0.16.0: /nix/store/d0kkd93aji32klh4npp5fzq82lb84p85-zig-0.16.0/lib/zig/std
  (unicode.zig, posix.zig:198/1163, os/linux.zig:5135/7629, process.zig:408,
  Io.zig:232, Io/Terminal.zig, Io/Writer.zig:1014, ascii.zig)
- zg: codeberg atman/zg (v0.16.3); zig-wcwidth: github.com/joachimschmidt557;
  uucode: github.com/jacobsandlund; zig-string: github.com/JakubSzark;
  zigpty: github.com/pithings/zigpty; mibu: github.com/xyaman/mibu;
  ansi_term: github.com/ziglibs/ansi_term v0.3.0; kitty-graphics-zig:
  github.com/remorses; zixel: github.com/daredemo; termscope:
  github.com/mwunsch/termscope; terminfo: github.com/JackoCoolio,
  github.com/asumbek
- zigzag (vendored): ~/projects/skript/third_party/zigzag/src/
  (terminal/ansi.zig, terminal/terminal.zig, terminal/screen.zig,
  terminal/platform/posix.zig, input/keyboard.zig, input/mouse.zig,
  unicode/display_width.zig, style/color.zig)
- libvaxis fork: ~/projects/libvaxis/src/ (Parser.zig, Key.zig,
  event.zig, Mouse.zig, tty.zig, ctlseqs.zig, gwidth.zig, GraphemeCache.zig,
  Image.zig, widgets/terminal/)
- Foreign clones: ~/projects/{github-ratatui-ratatui,
  github-charmbracelet-bubbletea, github-rockorager-vaxis,
  github-Textualize-textual, github-earendil-works-pi/packages/tui, libvaxis}
