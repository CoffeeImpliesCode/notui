# notui

Inline-first terminal UI primitives for Zig 0.16.

notui is a small library of TUI building blocks: a cell buffer with
grapheme-aware drawing, an inline `Region` renderer that repaints a fixed
band in the terminal's main buffer (never the alt screen, so scrollback
survives), live terminal capability detection, and an input reader with
split-sequence reassembly. The only dependency is
[zg](https://codeberg.org/atman/zg) (Unicode 16 width/graphemes), sealed
behind the `width` module.

## App framework

On top of those primitives, notui ships an Elm-style `App(Model)` layer:
your `Model` declares a `Msg` union plus `init` / `update(model, msg,
ctx) !Cmd(Msg)` / `view(model, ctx) View`, and the framework owns the
event loop, terminal modes, and rendering (sources:
[`src/app.zig`](src/app.zig), [`src/view.zig`](src/view.zig),
[`src/command.zig`](src/command.zig), [`src/context.zig`](src/context.zig)).
A minimal shape:

```zig
const notui = @import("notui");
const Cmd = notui.command.Cmd;
const View = notui.view.View;

const Model = struct {
    count: u32 = 0,

    pub const Msg = union(enum) { inc, dec, quit };

    pub fn init(allocator: std.mem.Allocator) !Model {
        _ = allocator;
        return .{};
    }
    pub fn update(self: *Model, msg: Msg, ctx: *notui.context.Context) !Cmd(Msg) {
        _ = ctx;
        switch (msg) {
            .inc => self.count += 1,
            .dec => self.count -= 1,
            .quit => return .quit,
        }
        return .none;
    }
    pub fn view(self: *const Model, ctx: *notui.context.Context) View(Model) {
        _ = self;
        _ = ctx;
        return .{ .draw = draw }; // paint the frame in `draw`
    }
};

pub fn main(init: std.process.Init) !void {
    const model = try Model.init(init.gpa);
    var app = notui.app.App(Model).init(model);
    app.setFilter(&filter); // event → Msg; q / ^C → .quit
    try app.run(init.io, init.gpa);
}
```

The full counter demo — `Text` + `Spinner` + `StatusBar` composed into
the frame via `View.draw`, keys wired through a filter, `every`-Cmd
animation — is [`examples/framework_counter.zig`](examples/framework_counter.zig):

```bash
zig build run-example-framework_counter
```

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
| `image`  | kitty graphics: transmit / place / delete (APC-G, a=t / a=p / a=d) |
| `coverage` | SIMD row-intersection rasterizer for the formula example |
| `component` | base-ui: `Text`, `Spinner`, `AnimatedText`, `Progress`, `Gauge`, `StatusBar`, `Suggestions` |
| `context` / `command` / `view` | framework: runtime context, the `Cmd(Msg)` effect type, the frame closure |
| `app`    | `App(Model)`: event loop, terminal modes, inline rendering |

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
