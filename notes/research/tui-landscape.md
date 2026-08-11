# TUI Landscape — Screen Ownership and Inline Modes

Scope: terminal UI libraries across Rust, Go, TS, Python, C, and Zig, with a
focus on **flexibility of screen ownership** — libraries that can render
in-line (into the terminal scrollback, without owning the full screen) as a
first-class mode. Feeds the design of `notui`.

All facts verified against primary sources (repo READMEs, docs, source code)
on 2026-08-11 unless marked `[UNVERIFIED]`.

## The core question

Terminal apps differ in **who owns the screen**:

- **Full-screen owners** enter the alternate screen buffer (`smcup`/`?1049h`),
  own scrolling, and restore the previous content on exit.
- **Inline renderers** draw N lines into the main buffer; the terminal owns
  scrolling; prior output stays above and scrollback is preserved.

For REPLs, prompts, live status lines, and agent transcripts, inline is the
right default. Most classic TUI libs are full-screen owners; a handful make
inline a first-class mode.

## Screen-ownership spectrum

### Tier 0 — Building blocks (no screen-ownership model at all)

| Lib | Lang | What it gives | License |
|---|---|---|---|
| crossterm | Rust | raw mode, ANSI, cursor, events, synchronized updates, scrolling regions | MIT |
| mibu (`xyaman/mibu`) | Zig 0.16 | raw mode, ANSI styles, keys, mouse; zero deps | MIT |
| `ziglibs/ansi_term` | Zig 0.16 | ANSI escape/styling | MIT |
| lipgloss | Go | styling only (no screen model) | MIT |

### Tier 1 — Inline-only (never own the screen)

| Lib | Lang | Model | Notes |
|---|---|---|---|
| Rich `Live` | Python | region overwrite in place, cursor restoration; `screen=False` default | no input/component layer |
| starship | Rust | prints a single prompt line to stdout, never raw mode | the inline pattern to emulate, not a lib |
| linenoise | C | single-line repaint: `\r ESC[0K` erase-to-EOL, redraw, `\r ESC[N C` restore | the reference line editor |
| reedline / rustyline | Rust | in-place prompt repaint with clear-below + synchronized output; tmux `scroll-on-clear` workaround (reedline #1062) | nushell's editor |

### Tier 2 — Dual-mode, inline first-class

| Lib | Lang | Inline mechanism | Fullscreen is | License |
|---|---|---|---|---|
| **pi-tui** (`@earendil-works/pi-tui`) | TS | `TuiMainScreen` — renders into main buffer, **preserves scrollback**; 3 strategies (first render: append w/o clearing; width change: clear+full re-render; normal: move to first changed line, clear-to-end, render changed); CSI 2026 synchronized output | `TuiAltScreen`, opt-in; **pi CLI default is inline** (`tuiMode: "regular"`) | MIT |
| **bubbletea** | Go | default mode: content-height frame in main buffer, cell-diff repaint; `tea.Println` inserts lines above frame | `View.AltScreen` (v2) / `WithAltScreen()` (v1), opt-in | MIT |
| **prompt_toolkit** | Python | `PromptSession`/`Application(full_screen=False)` — readline-style inline prompt; `print_formatted_text` prints above the running app | `full_screen=True`, opt-in | BSD-3 |
| **ink** | JS | in-place diff (hide cursor, erase, rewrite); `alternateScreen` default false, only active when `interactive && isTTY`; CI/non-TTY → writes single final frame with no ANSI | opt-in | MIT |
| **ratatui** | Rust | `Viewport::Inline(h)` since v0.21.0 (2023): anchored to cursor row, full width, `append_lines(n)` reserves space, **no alternate screen** (`try_init_with_options` skips it); `insert_before` writes lines above into scrollback (scrolling-regions in 0.29+) | `Viewport::Fullscreen` (default) | MIT |
| **notcurses** | C | `ncdirect` — inline mode interleaved with printf, scrollback preserved, `ncdirect_readline()` | `NCOPTION_CLI_MODE`/`NO_ALTERNATE_SCREEN` inhibit alt screen; runtime swap via enter/leave | Apache-2.0 |
| **ncurses** | C | `filter()` → `LINES=1` one-line pipeline mode, disables cursor addressing; `newterm` per terminal | alt screen via smcup for full apps | MIT/X11 |
| **Textual** | Python | `App.run(inline=True)` since v0.55.0 — full widget/DOM stack writes into main buffer below prompt; `:inline` CSS pseudo-selector; not on Windows | default (application mode) | MIT |

### Tier 3 — Full-screen owners

| Lib | Lang | Why | License |
|---|---|---|---|
| termbox-go / termbox2 | Go/C | enter alternate screen (`smcup`/`?1049h`) **unconditionally** on init; no inline mode | MIT / zlib |
| zigzag | Zig 0.16 | `alt_screen: bool = true` default; toggleable off but render() still repaints from cursor-home/line-clear — a region owner, not a scrollback writer | MIT |
| libvaxis | Zig 0.16 | alt screen optional; primary-screen path exists (`prettyPrint` → `error.NotInPrimaryScreen` in alt) but cell-buffer live region only, no append-to-scrollback API | MIT |
| urwid | Python | curses-based full-screen apps; weak inline/scrollback story | MIT |
| Textual (default), notcurses (default) | — | full-screen is the default, inline is opt-in | — |

## Key precedents for inline done right

- **ratatui `Viewport::Inline`** — the Rust reference. Open issues to learn
  from: viewport duplicated into scrollback on resize (#2086/#2355/#2666),
  cursor save/restore (#2694), insert_before flicker w/o scrolling-regions
  (#584). Real users: OpenAI Codex CLI TUI (`scrolling-regions` feature,
  viewport anchored to cursor row), official `examples/apps/inline`.
- **Go vaxis `PrimaryScreen`** — closest precedent to "leave output in
  scrollback with a live region": `Window` = live region; `Append*` queues
  output written **before** the live region on next render;
  `WithDynamicPrimaryScreen()` auto-sizes region. (Apache-2.0, Go.)
- **pi-tui `TuiMainScreen`** — the only lib with a named main-buffer renderer
  preserving scrollback, and it is the pi coding agent's **default** mode.
  Deliberate design: app-owned scrolling (VStack/HStack/ScrollView) is
  *unavailable* inline — the terminal owns scrollback.
- **bubbletea default** — no alt screen unless asked; README: "either
  inline, full-window, or a mix of both."
- **ink CI mode** — non-TTY: no erase/cursor/sync sequences, single final
  frame. Inline libs must degrade to plain output when piped.
- **delta** — line-buffered filter; pager (alt screen) only when stdout is a
  TTY, else plain ANSI to stdout.
- **fzf `--height`** — renders below the cursor in the main buffer.

## What "inline mode" requires (engineering patterns)

1. **Alt screen optional, inline default** (bubbletea, pi-tui, prompt_toolkit).
2. **Cursor-row anchoring** — start viewport at current cursor row (CPR query
   or assumed position; ratatui tracks last-known position for resize).
3. **Space reservation** — `append_lines(n)` pushes the terminal; origin
   shifts up by scrolled count (ratatui `compute_inline_size`).
4. **Repaint strategies** — erase-to-EOL + redraw (linenoise); clear-from-
   cursor-down + repaint (reedline); cell-diff (ratatui, bubbletea);
   differential line diff + synchronized output CSI 2026 (pi-tui); terminal
   scrolling regions (ratatui `insert_before` + crossterm `scroll_region_up`).
5. **Print-above escape hatch** — `tea.Println`, prompt_toolkit
   `print_formatted_text`, zigzag `.println` command (cursor save/home/restore).
6. **Scrollback preservation** — first render appends without clearing;
   width-change path must clear + full re-render (pi-tui strategy #2).
7. **Non-TTY degradation** — no erase/cursor sequences when piped (ink, delta).
8. **Known traps** — tmux `scroll-on-clear` snapshots on repaint (reedline
   erases from column 1 at row 0); resize can duplicate the live region into
   scrollback (ratatui issues); stdout-owning libs corrupt the escape stream
   if subprocesses write to fd 1/2 (skript REPL fd-capture).

## Zig 0.16 reality

No Zig 0.16 TUI library has a first-class scrollback/inline mode:

| Lib | Version | Model | Inline verdict |
|---|---|---|---|
| zigzag | 0.1.2, min 0.16, MIT, zero deps | Elm MUV, 34+ components, styles, kitty keyboard, images | full-screen owner; `alt_screen=false` exists but repaints from cursor-home — no scrollback mode |
| libvaxis | 0.6.0, min 0.16, MIT | low-level cell `Screen` + `vxfw` widget framework; alt screen optional | primary-screen live region possible, no append-to-scrollback API |
| mibu | 0.0.1-dev, min 0.16, MIT | raw mode, ANSI, keys, mouse | building block |
| ansi_term | 0.3.0, min 0.16 | ANSI styling | building block |
| notcurses / linenoise / ncurses via @cImport | C | ncdirect / filter() are inline | usable via translate-c (arocc risk on 0.16, cf. GTK) |

### House prior work

- **skript `repl.zig`** — full-screen zigzag dashboard (alt screen), not
  inline: history + input joined vertically, tree-sitter highlighting mapped
  onto CodeView, width-aware hanging indent for tensor answers, and
  **fd-capture of library stdout/stderr** (extern `pipe/dup/dup2`, restore
  fds first) so raylib log lines land in a muted block instead of corrupting
  the escape stream. The capture pattern is directly reusable inline.
- **skript `third_party/zigzag`** — vendored + patched (CSI splitting);
  upstream meszmate/zigzag.
- **nogui `app_framework.zig`** (SDL3 immediate-mode GPU UI) and **wayland
  renderer** (pixman canvas, glyph engine) — not terminal, orthogonal.

## Gap and options for notui

Gap: a Zig 0.16 inline-capable TUI does not exist. Options:

1. **Inline mode on zigzag** — add a scrollback renderer to the vendored
   framework (cursor-row anchor + append_lines equivalent + line diff).
   Cheapest: framework, components, styling already exist; renderer is the
   missing piece. Risk: fighting the program's buffer-repaint assumptions.
2. **Inline-first framework on mibu** — build the renderer layer from
   scratch over the building block, modeled on pi-tui `TuiMainScreen`
   (3 strategies) / Go vaxis `PrimaryScreen` (live region + append queue) /
   ratatui `Viewport` enum. Most control, most work.
3. **C via translate-c** — notcurses ncdirect or linenoise for the line
   editor only; arocc/header risk on 0.16.

## Sources

- ratatui: github.com/ratatui/ratatui (src/terminal/viewport.rs, inline.rs,
  backend.rs; CHANGELOG v0.21.0 #114, v0.29.0 #1341; examples/apps/inline;
  init.rs try_init_with_options)
- pi-tui: github.com/earendil-works/pi/packages/tui (README; interactive-mode.ts;
  settings-manager.ts `tuiMode`), npm @earendil-works/pi-tui 0.84.1
- bubbletea: github.com/charmbracelet/bubbletea (README, tea.go `AltScreen`,
  cursed_renderer.go, UPGRADE_GUIDE_V2.md)
- Go vaxis: github.com/rockorager/vaxis README (PrimaryScreen); Zig libvaxis:
  github.com/rockorager/libvaxis (build.zig.zon 0.6.0, Vaxis.zig prettyPrint)
- Textual: github.com/Textualize/textual docs/guide/app.md (inline since
  0.55.0), docs/how-to/style-inline-apps.md; prompt_toolkit:
  src/prompt_toolkit/application/application.py `full_screen`, shortcuts/utils.py;
  Rich: rich/live.py `screen: bool = False`
- ink: github.com/vadimdemedes/ink src/ink.tsx (resolveAlternateScreenOption,
  non-interactive path)
- notcurses: github.com/dankamongmen/notcurses doc/man/man3/notcurses.3.md,
  USAGE.md NCOPTION_CLI_MODE, doc/examples/src/directmode.md
- ncurses: man curs_initscr.3x (newterm), curs_util.3x (filter)
- termbox: nsf/termbox-go api.go, termbox/termbox2 termbox2.h send_init_escape_codes
- line editors: antirez/linenoise linenoise.c refreshSingleLine;
  nushell/reedline src/painting/painter.rs; kkawakam/rustyline src/edit.rs
- starship: src/main.rs; fzf: README --height; delta: src/main.rs, src/cli.rs
- zigzag: skript/third_party/zigzag (core/context.zig alt_screen, program.zig
  render/println, build.zig.zon 0.1.2); mibu: github.com/xyaman/mibu;
  ansi_term: github.com/ziglibs/ansi_term
- skript repl: skript/src/repl.zig, skript/src/highlight.zig
