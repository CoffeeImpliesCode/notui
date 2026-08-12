# notui

Inline-first terminal UI primitives for Zig 0.16.

notui is a small library of TUI building blocks: a cell buffer with
grapheme-aware drawing, an inline `Region` renderer that repaints a fixed
band in the terminal's main buffer (never the alt screen, so scrollback
survives), live terminal capability detection, and an input reader with
split-sequence reassembly. There is no app framework — you drive the
primitives in a plain event loop. The only dependency is
[zg](https://codeberg.org/atman/zg) (Unicode 16 width/graphemes), sealed
behind the `width` module.

## Quick start

A minimal spinner (full recipes live in [`examples/`](examples/)):

```zig
const std = @import("std");
const notui = @import("notui");

pub fn main(init: std.process.Init) !void {
    var tty = try notui.tty.Tty.init(init.io);
    defer tty.deinit();
    try tty.makeRaw();

    var parser: notui.parser = .{};
    const caps = try notui.caps.Capabilities.detect(&tty, &parser, init.gpa);

    var region = try notui.region.Region.init(init.gpa, .{
        .height = 1,
        .sync_output = caps.sync_output,
    });
    defer region.deinit();
    try region.resize((try tty.getWinsize()).cols, 1);

    var reader = notui.input.Reader.init(&tty);
    const w = tty.writer();
    const frames = [_][]const u8{ "|", "/", "-", "\\" };
    var i: usize = 0;
    while (true) {
        region.cur.clear();
        _ = try region.cur.draw(.{}, frames[i % frames.len], 0, 0);
        try region.render(w);
        try w.flush();
        i += 1;

        const ev = try reader.nextTimeout(100);
        if (ev) |e| switch (e) {
            .key_press => |k| {
                if (k.codepoint == notui.key.ctrl_c or k.codepoint == 'q') break;
            },
            else => {},
        };
    }
    try region.exit(w);
}
```

Draw into `region.cur`, render the diff, read events. `Region.render`
repaints in place with relative cursor moves only; `Region.exit` parks
the cursor below the band and leaves the final frame in the transcript.
With piped stdin (`sync_output = false`) the region degrades to one
plain frame — no interactive escape sequences.

## Modules

| Module   | Purpose |
|----------|---------|
| `width`  | zg seam: `strWidth`, `graphemeWidth`, `wrap`, `truncate` (grapheme-safe) |
| `color`  | `Color` (ansi / ansi256 / rgb / default), `ColorProfile`, palette downsampling |
| `style`  | `Style`, `Attrs` (bold, italic, underline, …), `merge` precedence |
| `cell`   | `Cell`: borrowed grapheme slice + style + wide-glyph continuation |
| `emit`   | ANSI writers: cursor, erasure, sync output, alt screen, profile-gated SGR |
| `event`  | `Event` union, `Key`, `Mouse`, `Winsize`, `Pos`, `Capability` |
| `key`    | key codes and modifiers, `matches` / `matchShortcut` |
| `mouse`  | mouse events (SGR 1006 + pixels 1016) |
| `parser` | terminal input decoder (kitty keyboard, OSC, paste, CPR) |
| `tty`    | raw mode, winsize, SIGWINCH flag, `isTty`, panic-restore |
| `caps`   | live capability detection (best-effort queries, no terminfo) |
| `buffer` | cell grid: `draw`, `renderDiff` / `renderAll` (style-tracking, wide-safe) |
| `region` | the inline renderer: 3 strategies, append queue, anchoring, non-TTY path |
| `input`  | `Reader`: blocking read with split-sequence reassembly |

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

- [notes/architecture.md](notes/architecture.md) — the v0 contract: API
  surface (§5), the inline-first model (§4), risks (§9)
- [notes/implementation-plan.md](notes/implementation-plan.md) — the
  phased build plan (P0–P7) and verification checklist
- [notes/research/](notes/research/) — TUI-landscape and zig-foundation
  research behind the design
