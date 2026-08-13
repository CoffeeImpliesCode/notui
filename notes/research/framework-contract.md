# notui app-framework contract (two-layer v1)

The Elm-style `App(Model)` framework on top of the shipped primitives
(`Region`, `Reader`, `Tty`, `Capabilities`) and the base-ui components
(`src/component/*`). This document is the implementer's spec: read ONLY
this file plus the notui source. It is the v1 layer the architecture §7
defers ("App framework / component tree / Model-Update-View — the two-layer
v1 on top of these primitives") and turns the §8/§10 decisions into code.

**Grounding.** Every primitive signature below is copied verbatim from the
shipped source (`src/*.zig`) so the framework wraps exactly what exists —
no new primitives are introduced. The framework is single-file-per-concern
(`app.zig` / `view.zig` / `command.zig` / `context.zig`) and thin: it wires
the existing loop (`Tty.init → makeRaw → Caps.detect → Region.init → loop →
Region.exit → caps.restore → tty.restore`, architecture §3, verified in
`examples/skript_repl.zig:160-395`) and adds an Elm-shaped Model contract
on top.

---

## 1. The two-layer shape (reconciling Elm with the shipped renderer)

The Elm proposal wants a declarative `view` returning **string lines**.
notui already ships a cell `Buffer` + `Region` diff renderer and a
component layer that draws into a `Buffer` (`baseui-contract.md §3`:
`draw(buf, x, y, now) !u16`). Producing ANSI string lines would bypass the
diff and the non-TTY path — the base-ui layer already rejected that
contract (`baseui-contract.md:84-98`). **The framework therefore keeps the
Elm shape but makes `view` return a `View` that draws into the frame
`Buffer` via the shipped components.** The reconciliation:

- **`update(model, msg, ctx) !Cmd(Msg)`** — the Elm message reducer, verbatim.
  Pure-ish, zero-alloc on the fast path (the model mutates in place, as
  `skript_repl.zig` mutates `line`/`spinner` each key).
- **`view(model, ctx) View(Model)`** — the declarative frame. It does NOT
  return text; it returns a `View` carrying a `draw` callback that composes
  base-ui components into the frame `Buffer` (`View.draw(model, ctx, buf)`).
  `draw` receives the model MUTABLE (`*Model`) so components can advance their
  animation state to `now` during the frame (the shipped component contract,
  baseui-contract.md §3: `draw` advances first) — same as skript_repl's
  `drawBand` receiving `&spinner` mutable (skript_repl.zig:1122). The
  "what renders" is declared each frame (modes, band height, title); the
  "how it paints" is the shipped `Buffer.draw` + component `draw`.
- **`View` mode flags** (`alt_screen` / `mouse` / `hide_cursor` /
  `print_above`) declare the desired terminal mode **per frame**. The
  framework diffs them against the current actual mode and applies the
  transition only on change — the bubbletea-style inline↔alt-screen
  smcup/rmcup discipline (requirement 2).
- **`Cmd(Msg)`** is the effect vocabulary (`none`/`quit`/`tick`/`every`/
  `batch`/`sequence`/`msg`/`println`/`set_title`/`mouse`/`cursor`/
  `alt-screen`) — the bubbletea `Cmd` model, synchronous in v1.

**File layout (requirement 5):**

```
src/app.zig        App(Model): init/run/start/tick/send/quit/isRunning/setFilter,
                   the loop, mode diff, message dispatch, teardown, Model contract check
src/view.zig       View(Model) + signature hash + mode-diff helper
src/command.zig    Cmd(Msg) union + process() (batch/sequence/msg/tick/every/quit/println/set_title/mouse/cursor/alt-screen)
src/context.zig    Context: allocator/frame_arena/io/tty/caps/region/buf/width/height/frame_delta/frame_count/color_profile/render_requested
src/root.zig       add re-exports: pub const app = @import("app.zig"); pub const view = @import("view.zig");
                   pub const context = @import("context.zig"); pub const command = @import("command.zig");
                   (app.zig re-exports the framework surface: pub const App = ...; pub const Context = @import("context.zig").Context;
                   pub const View = @import("view.zig").View; pub const Cmd = @import("command.zig").Cmd;)
```

The four new files import ONLY existing notui modules (`region`, `buffer`,
`input`, `tty`, `caps`, `event`, `emit`, `component`, `style`, `width`) —
the zg grep-gate stays `width.zig` only (architecture §4; region.zig:28-31).

---

## 2. `Context` — what update/view see each frame

```zig
// src/context.zig
const std = @import("std");
const Tty = @import("tty.zig").Tty;
const caps = @import("caps.zig");
const Region = @import("region.zig").Region;
const Buffer = @import("buffer.zig").Buffer;

/// Everything a Model's `update` and `view` are allowed to see. Built and
/// refreshed by `App` once per `tick`; `view`/`update` must treat it as
/// read-only except for `render_requested` and the `buf`/`region` they draw
/// into. `frame_arena` is reset at the top of every tick — slices from a
/// previous frame are dead (architecture §3: Event.text/paste valid until the
/// next read; app arena for long-lived data).
pub const Context = struct {
    /// Long-lived session allocator (the gpa passed to `run`); for state the
    /// model keeps beyond the current frame. Arena memory lives for the whole
    /// session (skript_repl.zig:175-181 app-arena pattern).
    allocator: std.mem.Allocator,
    /// Per-frame scratch arena, reset each tick. For transient slices (wrapped
    /// text, formatted numbers). Never retain across frames.
    frame_arena: std.mem.Allocator,
    /// The std.Io threaded onto the tty (clock, output) — for
    /// `std.Io.Timestamp.now(io, .awake)` (component.zig:27) and `Duration`.
    io: std.Io,
    /// The raw-mode tty (read/winsize; do not deinit — App owns it).
    tty: *Tty,
    /// Detected capabilities (color profile, sync, kitty). Read-only.
    caps: *const caps.Capabilities,
    /// The inline Region renderer. In alt-screen mode it is not used for
    /// rendering (see §4) but remains allocated for the transition back.
    region: *Region,
    /// The ACTIVE frame buffer for this tick: `&region.cur` in inline mode, a
    /// framework-owned full-screen Buffer in alt-screen mode. `View.draw`
    /// and the model's components draw into THIS. Do not retain across ticks.
    buf: *Buffer,
    /// Current terminal width in columns (resized on winsize; inline mode
    /// equals `region.width`, region.zig:243).
    width: u16,
    /// Current band/frame height in rows.
    height: u16,
    /// Elapsed since the previous tick (monotonic; `std.Io.Timestamp` diff).
    frame_delta: std.Io.Duration,
    /// Tick sequence number, starting at 0.
    frame_count: u64,
    /// Detected color profile (`caps.color`, caps.zig:23-34) — the model uses
    /// it to pick the palette (statusline.zig Palette pattern).
    color_profile: caps.ColorProfile,
    /// Set true to force a repaint this tick even when the `View` signature is
    /// unchanged (e.g. a spinner advanced, a timer fired). Read-write.
    render_requested: bool = false,
};
```

Notes:
- `frame_arena: std.mem.Allocator` is `arena.allocator()`; `allocator` is the
  gpa. Two explicit allocators so the model does not accidentally retain
  per-frame scratch.
- `frame_delta` is `std.Io.Duration` (Io.zig:968-976, `.nanoseconds`),
  computed as `now - last_tick` over the monotonic `std.Io.Timestamp`
  (Io.zig:906-912).

---

## 3. `Cmd(Msg)` — the effect vocabulary

```zig
// src/command.zig
const std = @import("std");

/// An effect produced by `update`. Synchronous in v1: the App processes the
/// returned Cmd before the frame renders. `batch`/`sequence` carry borrowed
/// slices (frame-arena or app-owned); never free them — `frame_arena` resets
/// each tick.
pub fn Cmd(comptime Msg: type) type {
    return union(enum) {
        none,
        /// Stop the loop after this tick; `run` performs the teardown
        /// sequence (Region.exit → caps.restore → tty.restore).
        quit,
        /// Schedule one `Msg` (dispatched via the model's `update`) after
        /// `delay_ms` of inactivity — the bubbletea `tick` pattern.
        tick: struct { delay_ms: u32 },
        /// Re-arm a periodic tick every `interval_ms` until replaced or quit.
        /// The tick's Msg is the model's `.tick`-equivalent: the App dispatches
        /// `Msg.tick` (see §7) when `@hasField(Msg, "tick")`.
        every: struct { interval_ms: u32 },
        /// Dispatch each contained Cmd in order, same tick, each fully
        /// processed (folded into the loop) before the next.
        batch: []const Cmd(Msg),
        /// Like batch but strictly sequential: each element's effects are
        /// drained before the next element starts (see open Q2).
        sequence: []const Cmd(Msg),
        /// Dispatch `msg` immediately (recurses into `update` within this tick).
        msg: Msg,
        /// Append `text` ABOVE the region into scrollback as a plain line
        /// (the print-above escape hatch — `Region.Append.line`), forcing a
        /// render this tick.
        println: []const u8,
        /// Set the terminal title (OSC 0). Written inline by the App via the
        /// writer (`\x1b]0;{s}\x07`); no new emit primitive (constraint: wrap
        /// what exists). `set_title: []const u8`.
        set_title: []const u8,
        /// Enable/disable SGR 1006 mouse reporting immediately
        /// (`emit` CSI ?1000h/?1000l + ?1006h/?1006l; caps.restore turns it
        /// off on exit, caps.zig:58-59).
        mouse: bool,
        /// Show/hide the cursor immediately (`emit.hideCursor/showCursor`).
        cursor: bool,
        /// Enter/leave the alternate screen immediately
        /// (`emit.enterAltScreen/exitAltScreen`, emit.zig:94-102). Overridden
        /// by the next frame's `View.alt_screen` if they differ.
        alt_screen: bool,
    };
}

/// Process a Cmd produced this tick. `self: *App(Model)` is folded in via
/// method on App (see app.zig §6) rather than here; command.zig owns only the
/// union + a pure helper for sequencing.
pub fn isNoop(cmd: anytype) bool { // returns cmd == .none
    return cmd == .none;
}
```

**Precedence rule (view modes vs Cmd mode ops):** `View.alt_screen` /
`View.mouse` / `View.hide_cursor` are authoritative **per frame** and win
over any `Cmd.mouse`/`cursor`/`alt_screen` issued earlier in the same tick
(the frame's declarative target is final). Cmd mode ops exist for
one-shot/immediate transitions (e.g. from `init` or a worker-result path)
and for changes the view cannot encode; they are applied as pending modes
and then overridden by the View when it disagrees.

---

## 4. `View(Model)` — the declarative frame

```zig
// src/view.zig
const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Context = @import("context.zig").Context;
const Region = @import("region.zig").Region;

/// The per-frame declaration of WHAT to render and which terminal modes the
/// app wants. `view` returns one of these; the App diffs it against the
/// previous frame and renders only when something changed.
pub fn View(comptime Model: type) type {
    return struct {
        /// Paint the frame into `buf` (the active frame Buffer; `ctx.region.cur`
        /// inline, a full-screen Buffer in alt mode). Compose base-ui
        /// components via their `draw(buf, x, y, now)` with
        /// `now = std.Io.Timestamp.now(ctx.io, .awake)` (component.zig:27),
        /// and/or raw `Buffer.draw` (buffer.zig:128). Advance animation with
        /// component `advance(now)` and set `ctx.render_requested = true` when
        /// the frame moved so the App repaints (the spinner pattern). `model` is
        /// `*Model` (mutable) precisely so components can advance to `now` in draw.
        draw: *const fn (model: *Model, ctx: *Context, buf: *Buffer) anyerror!void,
        /// Enter the alternate screen (smcup) for this frame. Diffed against the
        /// current mode; rmcup/smcup emitted ONLY on change (§5, bubbletea-style).
        alt_screen: bool = false,
        /// Request SGR 1006 mouse reporting for this frame (diffed; enabled on
        /// change, disabled on exit via caps.restore, caps.zig:58).
        mouse: bool = false,
        /// Hide the cursor while rendering (default true; shown on exit).
        hide_cursor: bool = true,
        /// The app staged scrollback-above content this frame (via
        /// `ctx.region.append`); force a render so the region flushes the
        /// append queue above the band (region.render auto-flushes, region.zig
        /// appendQueue; this flag guarantees a render when the band itself is
        /// unchanged).
        print_above: bool = false,
        /// Desired region band height; 0 = keep the current height. A nonzero
        /// value applies `Region.setHeight` (dynamic bands: the REPL popup
        /// grows the band via setHeight, skript_repl.zig:257/366). Alt-screen
        /// mode ignores this (uses full terminal height).
        height: u16 = 0,
        /// Terminal title to set when non-null (also settable via Cmd.set_title).
        title: ?[]const u8 = null,
    };
}

/// A cheap signature of the declarative part of a View (draw fn pointer + mode
/// flags + height + title pointer value + mouse). Used to skip a frame whose
/// declaration is identical to the last (the "whole-View hash skip"); the
/// Region's own diff (region.zig scanChanges, zero-byte idle frames) is the
/// correctness backstop for content. Not a content hash.
pub fn signature(view: anytype) u64 { // folds the declarative View fields
    var h = std.hash.Wyhash.init(0);
    // fold: @intFromPtr(view.draw), alt_screen, mouse, hide_cursor, print_above,
    // height, @intFromPtr(view.title)
    return h.final();
}
```

**Why draw-into-Buffer and not string lines:** the shipped `Region.render`
diffs `cur` against `prev` and emits only changed cells (region.zig
scanChanges; idle frames emit zero bytes, region.zig:255-258). Base-ui
components already draw into `region.cur` via `Buffer.draw`
(baseui-contract.md §3; statusline.zig). A string-lines View would have to
re-parse ANSI and lose both the diff and the non-TTY path. So the frame
content is produced by the model composing components into `ctx.buf` —
exactly the `skript_repl.zig` `drawBand(aa, &region, ...)` pattern
(skript_repl.zig:1122), promoted into a returned `View.draw`.

**Frame Buffer ownership:** inline mode binds `ctx.buf = &ctx.region.cur`
(the public `Region.cur`, region.zig:240) and the App calls
`region.render(w)` (region.zig render, the 3-strategy inline renderer).
Alt-screen mode binds `ctx.buf` to a framework-owned full-size `Buffer` and
the App emits via `buffer.renderDiff(prev, w)` (buffer.zig:169) after
smcup, with `Buffer.clear` + `renderAll` (buffer.zig:198) on first entry —
a minimal full-screen path, deliberately simple (see open Q1).

---

## 5. `App(Model)` — the runtime loop

```zig
// src/app.zig
const std = @import("std");
const Tty = @import("tty.zig").Tty;
const Region = @import("region.zig").Region;
const Reader = @import("input.zig").Reader;
const caps = @import("caps.zig");
const emit = @import("emit.zig");
const Event = @import("event.zig").Event;
const Key = @import("key.zig").Key;
const Context = @import("context.zig").Context;
const View = @import("view.zig").View;
const Cmd = @import("command.zig").Cmd;

/// The Elm-style app runner. `Model` MUST declare (comptime-checked below):
///
///   pub const Msg = <type>;                                   // the message type
///   pub fn init(allocator: std.mem.Allocator) !Model;         // initial state
///   pub fn update(self: *Model, msg: Msg, ctx: *Context) !Cmd(Msg);
///   pub fn view(self: *const Model, ctx: *Context) View;
///
/// Single-threaded. Worker-thread patterns (the REPL's eval worker writing a
/// result slot polled each tick, skript_repl.zig:379-385) stay APP-level: the
/// worker publishes to a slot; the main tick reads it and calls `send`/update.
/// `send` from a worker thread must be guarded by a user mutex (the framework
/// is otherwise single-threaded; see §8).
pub fn App(comptime Model: type) type {
    const Msg = Model.Msg;

    comptime {
        if (!@hasDecl(Model, "Msg")) @compileError("Model must declare `pub const Msg`");
        if (!@hasDecl(Model, "init")) @compileError("Model must declare `pub fn init(allocator) !Model`");
        if (!@hasDecl(Model, "update")) @compileError("Model must declare `pub fn update(self, msg, ctx) !Cmd(Msg)`");
        if (!@hasDecl(Model, "view")) @compileError("Model must declare `pub fn view(self, ctx) View`");
    }

    return struct {
        pub const Options = struct {
            /// Loop pacing. fps > 0: `Reader.nextTimeout(1000/fps)` paces
            /// timed ticks. fps == 0: block on input (`Reader.next`), no
            /// timed ticks — animation must be driven by `every` Cmds.
            fps: u32 = 60,
            /// Initial inline band height (Region.Options.height, region.zig:178).
            region_height: u16 = 3,
            /// Region space reservation (Region.Options.append_lines).
            append_lines: bool = true,
            /// Optional default event→Msg translator (also settable via setFilter).
            filter: ?*const fn (*Context, Event) ?Msg = null,
        };

        const Self = @This();
        pub const Ctx = Context;
        pub const Vw = View(Model);

        model: Model,
        opts: Options,

        // framework-owned runtime (populated by start/run)
        io: ?std.Io = null,
        gpa: std.mem.Allocator = undefined,
        tty: ?Tty = null,
        parser: @import("Parser.zig") = .{},
        caps: ?caps.Capabilities = null,
        region: ?Region = null,
        reader: ?Reader = null,
        arena: ?std.heap.ArenaAllocator = null, // app arena (long-lived)

        // loop state
        running: bool = false,
        current_alt: bool = false,
        current_mouse: bool = false,
        current_hidden: bool = true,
        last_sig: u64 = std.math.maxInt(u64), // last View signature
        frame_count: u64 = 0,
        last_tick: ?std.Io.Timestamp = null,
        msg_queue: std.ArrayListUnmanaged(Msg) = .empty,
        filter: ?*const fn (*Context, Event) ?Msg = null,
        alt_buf: ?Buffer = null, // full-screen buffer, only in alt mode
        title: ?[]const u8 = null,

        // ── construction ────────────────────────────────────────────────
        pub fn init(model: Model) Self {
            return initWithOptions(model, .{});
        }
        pub fn initWithOptions(model: Model, opts: Options) Self {
            return .{ .model = model, .opts = opts, .filter = opts.filter };
        }

        // ── lifecycle ───────────────────────────────────────────────────
        /// Open /dev/tty, enter raw mode, detect capabilities, init the region
        /// and the app arena. Non-TTY stdin degrades: no raw mode, no caps, a
        /// plain single frame (region sync_output = false path, region.zig:262-274).
        pub fn start(self: *Self, io: std.Io, gpa: std.mem.Allocator) !void;
        /// One loop iteration: read one event (paced to fps) → filter to Msg →
        /// update → process Cmd → decide render → mode diff → draw + render.
        pub fn tick(self: *Self) !void;
        /// start + loop until quit + teardown (Region.exit → caps.restore →
        /// tty.restore → deinit). The framework's normal entry point.
        pub fn run(self: *Self, io: std.Io, gpa: std.mem.Allocator) !void;
        /// Tear down region/caps/tty/arena. Idempotent; called by run.
        pub fn deinit(self: *Self) void;

        // ── messages ────────────────────────────────────────────────────
        /// Enqueue a Msg for the next tick. Main-thread only unless the app
        /// guards concurrent callers with a mutex (§8).
        pub fn send(self: *Self, msg: Msg) void;
        /// Request quit; the loop breaks after the current tick.
        pub fn quit(self: *Self) void;
        /// True while the loop is running (post-start, pre-quit).
        pub fn isRunning(self: *const Self) bool;
        /// Replace the event→Msg translator. Returning null drops the event
        /// (the framework never synthesizes a Msg from it). Ctrl+C arrives as a
        /// normal `key_press` (Key.ctrl_c) — the filter routes it to whatever
        /// Msg the app chooses (e.g. `.quit`); the library never hard-quits
        /// (architecture §8.8 / §10; Reader.next doc, input.zig:122-124).
        pub fn setFilter(self: *Self, f: *const fn (*Context, Event) ?Msg) void;
    };
}
```

### 5.1 `start` — exact init sequence

```text
if !Tty.isTty(STDIN_FILENO):
    piped path: gpa-only, no tty, no raw, region with sync_output=false,
    one plain frame on exit (region.zig non-TTY branch). return.
else:
    tty = Tty.init(io); makeRaw(); defer restore on error
    parser = .{}
    caps = Capabilities.detect(gpa, &tty, &parser)
    region = Region.init(gpa, .{ .height = region_height, .append_lines, .sync_output = true,
        .width_policy = caps.widthPolicy() })
    ws = tty.getWinsize(); region.resize(ws.cols, region.height)
    arena = ArenaAllocator.init(gpa);  // long-lived app arena (skript_repl.zig:175-181)
    reader = Reader.init(&tty)
    last_tick = Timestamp.now(io, .awake)
    running = true
```

### 5.2 `tick` — the loop body (requirement 2)

```text
1. reset frame_arena (the per-tick scratch).
2. read one event: ev = if fps > 0 Reader.nextTimeout(1000/fps) else Reader.next()
   - null (timeout): proceed as a timed tick (no event).
   - error.EndOfStream (pipe EOF): quit() and return.
3. dispatch events: if ev != null:
   - if .winsize => resize active buffer (inline: region.resize(wsz.cols, region.height);
     alt: alt_buf.resize(wsz.cols, wsz.rows)); set render_requested.
   - else msg = filter(ev); if msg != null → run update(msg) (drain queue).
   - the default filter maps nothing; an unset filter drops all events
     (the app must setFilter to receive input).
4. drain msg_queue (send()ed msgs), running update(model, msg, ctx) for each.
5. process the returned Cmd (processCmd, §6) — including nested msg/batch/sequence.
6. frame_delta = now - last_tick; last_tick = now; frame_count += 1.
7. compute ctx: allocator=gpa, frame_arena=arena.allocator(), io, tty, caps, region,
   buf (inline: &region.cur; alt: &alt_buf), width, height,
   frame_delta, frame_count, color_profile=caps.color, render_requested (reset per tick).
8. view = model.view(model, &ctx).
   - apply View.height via Region.setHeight (inline) when nonzero and changed.
   - if view.title != null and != title: emit OSC 0; title = view.title.
9. render decision (render-on-demand + whole-View hash skip):
   - sig = signature(view).
   - render if: an event was dispatched (step 3/4) OR ctx.render_requested OR
     sig != last_sig OR mode transition pending (view modes != current) OR
     region has pending work (appends/flush). Else: idle — skip draw+render
     (the Region would emit zero bytes anyway; this avoids the draw call).
   - when rendering: apply the mode diff (§5.3), then:
       inline: view.draw(model, &ctx, &region.cur); region.render(w); w.flush();
       alt:    Buffer.clear if first entry; view.draw(...&alt_buf);
               alt_buf.renderDiff(prev, w) (renderAll on first entry); w.flush();
   - last_sig = sig.
10. if view.alt_screen != current_alt: this is a mode change already applied in
    step 9 (bubbletea-style); current_alt updated there.
```

### 5.3 Mode diff (bubbletea-style, only-on-change)

```text
target_alt    = view.alt_screen; target_mouse = view.mouse; target_hide = view.hide_cursor
if target_alt != current_alt:
    if target_alt: emit.enterAltScreen(w)  (emit.zig:95) else emit.exitAltScreen(w) (emit.zig:100)
    current_alt = target_alt
    switch the active ctx.buf between &region.cur and &alt_buf; resize to winsize
if target_mouse != current_mouse:
    emit CSI ?1006h + ?1000h (on) / ?1006l + ?1000l (off); current_mouse = target_mouse
    (caps.restore always disables on exit, caps.zig:58-59 — idempotent)
if target_hide != current_hidden:
    emit.hideCursor/showCursor (emit.zig:42/47); current_hidden = target_hide
```

### 5.4 `deinit` / exit sequence (requirement 2)

```text
run() after loop:
    w = tty.writer()
    if alt-screen is active: emit.exitAltScreen(w) first
    region.exit(w)      // show cursor, endSync, park below band, no clear (region.zig exit)
    caps.restore(w)     // kitty keyboard pop, bracketed-paste/mouse/focus/sync off, cursor show (caps.zig:53-76)
    w.flush()
    arena.deinit(); region.deinit(); tty.deinit()
```

This is the exact teardown `skript_repl.zig:391-394` uses
(`region.exit(w); caps.restore(w); w.flush()`), with `tty.deinit()` (which
restores termios + uninstalls signal handlers, tty.zig:57-74) completing it.

### 5.5 Non-TTY degradation

When stdin is not a tty, `start` skips `Tty.init`/`makeRaw`/`Caps.detect`
entirely (Tty.init opens /dev/tty, which fails without a controlling
terminal — the skript_repl guard, skript_repl.zig:157-159), builds a
`Region` with `sync_output = false` (the ink/delta plain-frame path,
region.zig:262-274), runs the loop WITHOUT reading input (blocked → the app
must `quit()` or the loop exits on the first tick via a `quit`/`println`
default), renders one plain frame, and exits 0. The app's `view` still runs
so a non-TTY user sees the same content (architecture §4.8 / §8.9).

---

## 6. `processCmd` — effect execution

A private method on `App(Model)` (so it can recurse into `update` and touch
loop state). `Cmd` handling:

| Cmd | Action |
|---|---|
| `none` | nothing |
| `quit` | `self.quit()` |
| `tick{delay_ms}` | arm a one-shot deadline: on the next `tick` whose elapsed `>= delay_ms`, dispatch `Msg.tick` (if `@hasField(Msg, "tick")`) and clear the deadline |
| `every{interval_ms}` | arm a periodic timer: each tick whose elapsed since the last fire `>= interval_ms` dispatches `Msg.tick` and re-arms |
| `msg` | `update(model, msg, ctx)` now, process its returned Cmd (bounded recursion — a `msg` chain is depth-limited by the model) |
| `batch` | for each element: processCmd (each fully drained before the next) |
| `sequence` | same as batch in v1 unless Q2 resolves stricter semantics; documented as in-order, each element's effects drained first |
| `println` | `region.append(.{ .line = text })` (region.zig:116) — one exact row above the band; force render this tick |
| `set_title` | write `\x1b]0;{s}\x07` to the writer; store `title` |
| `mouse`/`cursor`/`alt_screen` | apply the immediate mode op (§5.3), superseded by the frame's View flags |

`Msg.tick` is the single periodic message name; a Model that wants a
distinct timer message maps it in `update` (`update(model, .tick, ctx)`
switches to `.Tick`/`.Refresh`/whatever). `every` requires
`@hasField(Msg, "tick")` at comptime (a @compileError if the model's Msg
has no `.tick` field but an `every` Cmd is returned).

---

## 7. Component integration (requirement 3)

Model-held base-ui components compose into the frame inside `View.draw`:

```zig
fn draw(model: *Model, ctx: *Context, buf: *Buffer) !void {
    const now = std.Io.Timestamp.now(ctx.io, .awake);
    _ = try model.spinner.draw(buf, 0, 0, now);        // base-ui draw(buf,x,y,now) !u16;
                                                       // model is *Model so the spinner
                                                       // advances its frame to `now`
    var bar: component.StatusBar = .{ .left = &.{...}, .right = &.{...} };
    _ = try bar.draw(buf, 0, 1, now);                  // StatusBar draws the full row
}
```

- **Frame arena scratch:** components with wrap/truncate need a caller-owned
  scratch (`Text.scratch`, `StatusBar.scratch`) — the model stores
  `scratch: *std.ArrayList` created from the app arena, or re-created each
  tick from `ctx.frame_arena`.
- **Animation + render gating:** the model calls `comp.advance(now)` in
  `update` (or the tick handler) and sets `ctx.render_requested = true` when
  it returns true, so the framework repaints. Components' `draw` also
  advances to `now` (component.zig draw-first contract), so an `every` timer
  + `render_requested` keeps a Spinner spinning with no input.
- **Dynamic band height:** a model that needs more rows (a popup/overlay)
  returns `View.height = new_height` and the framework calls
  `Region.setHeight` (region.zig:138-183, the height-only resize that never
  wipes content below the band) — the REPL popup pattern
  (`region.setHeight(base_height + shown)`, skript_repl.zig:366). The next
  frame's `View.height = 0` keeps the height.
- **Scrollback-above output:** `ctx.region.append(.{ .line/.text = ... })` in
  `update` stages output; set `View.print_above = true` (or return a
  `Cmd.println`) to force the flush render. The Region flushes the append
  queue before rendering (region.zig appendQueue flush).

---

## 8. Threading (requirement 4)

The loop is single-threaded and blocking-read (architecture §3; no
background read thread, no concurrent render — both deferred, §7). The
framework itself spawns no threads. Worker-thread patterns stay app-level,
following the REPL's eval worker (`skript_repl.zig:379-385`):

1. On submit, spawn `std.Thread` that does the long work off the UI thread.
2. The worker publishes into a result slot (a small struct guarded by a
   `std.Thread.Mutex` or `std.atomic`).
3. Each tick, the app's `update` (or the loop before update) polls the slot;
   on a new result it calls `self.send(result_msg)` (main thread) or maps it
   to a Msg directly.

`send` is main-thread by default; a worker that must enqueue directly wraps
`send` in a user-owned mutex (the framework's `msg_queue` is otherwise
touched only on the main thread). Documented in `app.zig`; no framework
concurrency primitives are added.

---

## 9. Test requirements (per module)

Follow the existing golden pattern (fixed `Buffer` + a `TestWriter`
`renderAll`/`renderDiff` golden; synthetic clocks via
`std.Io.Timestamp.fromNanoseconds`; each file ends with
`test { std.testing.refAllDecls(@This()); }`). Drive `tick`/`run` against a
pipe-fed fake tty (the `Pipe` helper pattern in input.zig:293-310) so no
terminal is required.

**`context.zig`:**
1. `frame_delta` equals the monotonic diff between two synthetic `now`s.
2. `frame_arena` slices die across a tick boundary (arena reset).

**`command.zig`:**
1. `none`/`quit` no-op vs quit flag; `msg` recurses into update once.
2. `batch` drains each element (order asserted via a recording model).
3. `tick{delay}` fires `Msg.tick` only after the deadline; `every` re-arms.
4. `println` enqueues one `Region.Append.line` and forces a render.
5. `set_title`/`mouse`/`cursor`/`alt_screen` produce the expected writer bytes.

**`view.zig`:**
1. `signature` changes when any mode flag / height / title / draw fn changes,
   and is stable when none do (idle-frame skip works).
2. mode-diff helper: inline→alt emits smcup once, alt→inline emits rmcup,
   inline→inline emits nothing (only-on-change).

**`app.zig`:**
1. Contract check: a Model missing `Msg`/`init`/`update`/`view` fails
   `@compileError` (test via `@compileError` reference).
2. `start` non-TTY path: piped stdin → one plain frame, no raw mode, no error.
3. `tick` with a pipe-fed fake tty + `fps=0`: a written `\x03` (Ctrl+C) with
   a filter mapping `Key.ctrl_c → .quit` quits; without a filter it is
   dropped and the loop keeps running (Ctrl+C never hard-quits).
4. `send`-enqueued msgs drain next tick; `quit` breaks the loop;
   `isRunning` reflects the state.
5. `run` teardown emits `Region.exit` then `caps.restore` then `tty.restore`
   (assert writer sequence against a recording writer).
6. Alt-screen transition: a model returning `View.alt_screen = true` on a
   given tick produces `\x1b[?1049h` exactly once and renders the full
   buffer; flipping back produces `\x1b[?1049l`.

---

## 10. Example spec (implementer F2b)

**File:** `examples/framework_counter.zig` — a minimal counter/input demo.

```zig
const notui = @import("notui");
const Context = notui.context.Context;
const View = notui.view.View;
const Cmd = notui.command.Cmd;
const component = notui.component;

const Model = struct {
    pub const Msg = union(enum) { tick, inc, dec, quit };
    count: i64 = 0,
    busy: bool = false,
    spinner: component.Spinner = .{ .label = "working" },
    scratch: std.ArrayList(u8) = .empty, // Text/StatusBar truncation scratch

    pub fn init(allocator: std.mem.Allocator) !Model {
        _ = allocator;
        return .{};
    }
    pub fn update(self: *Model, msg: Msg, ctx: *Context) !Cmd(Msg) {
        switch (msg) {
            .inc => self.count += 1,
            .dec => self.count -= 1,
            .quit => return .quit,
            .tick => {
                self.busy = !self.busy;            // demo toggle; spinner animates
                if (self.busy) ctx.render_requested = true;
                return .{ .every = .{ .interval_ms = 200 } }; // keep spinning
            },
        }
        return .none;
    }
    pub fn view(self: *const Model, ctx: *Context) View {
        return .{
            .draw = draw,
            .height = 3,
            .title = "notui counter",
        };
    }
    fn draw(model: *Model, ctx: *Context, buf: *Buffer) !void {
        const now = std.Io.Timestamp.now(ctx.io, .awake);
        var count_txt: component.Text = .{ .style = .{ .fg = .{ .ansi = .cyan } } };
        count_txt.text = std.fmt.allocPrint(ctx.frame_arena, "count: {d}   [i]nc [d]ec [q]uit", .{model.count}) catch return;
        _ = try count_txt.draw(buf, 0, 0, now);
        _ = try model.spinner.draw(buf, 0, 1, now);        // Text + Spinner rows
        var bar: component.StatusBar = .{
            .left = &.{ .{ .text = "counter", .style = .{ .fg = .{ .ansi = .green } } } },
            .right = &.{ .{ .text = "inline mode", .style = .{} } },
        };
        _ = try bar.draw(buf, 0, 2, now);                  // StatusBar row
    }
};

pub fn main(init: std.process.Init) !void {
    const model = try Model.init(init.gpa);
    var app = notui.app.App(Model).init(model);
    app.setFilter(&filter);
    try app.run(init.io, init.gpa);
}

fn filter(_: *Context, ev: Event) ?Model.Msg {
    // Route keys to Msgs; Ctrl+C (a normal key_press, Key.ctrl_c) → .quit —
    // the library never hard-quits (architecture §8.8 / §10).
    return switch (ev) {
        .key_press => |k| {
            if (k.matches('q', .{})) return .quit;
            if (k.matches('i', .{})) return .inc;
            if (k.matches('d', .{})) return .dec;
            if (k.matches(Key.ctrl_c, .{})) return .quit;
            return null;
        },
        else => null,
    };
}
```

**Demonstrates:** `App(Model)` + `init`/`setFilter`/`run`; the Elm contract
(`Msg`/`init`/`update`/`view`); base-ui `Text` + `Spinner` + `StatusBar`
composed into the frame via `View.draw`; inline default mode; the
Ctrl+C-routed-as-Msg quit convention (`q` and `^C` both → `.quit`); an
`every` Cmd driving animation.

**build.zig:** add a `framework_counter` entry to the `examples` tuple
(`.{ .name = "framework_counter", .file = "examples/framework_counter.zig" }`),
which auto-wires the executable, install, and `run-example-framework_counter`
step (mirroring the existing `spinner`/`prompt`/`statusline` entries,
build.zig:82-109). The example imports `notui` + the zg trio like the other
examples.

**README:** replace the "There is no app framework — you drive the
primitives in a plain event loop" sentence (README.md:9-10) with a
**"App framework"** section: two lines on the Elm-style `App(Model)` layer
on top of the primitives, one link to `notes/research/framework-contract.md`,
and the one-liner `zig build run-example-framework_counter`.

---

## 11. Open questions for the orchestrator

1. **Alt-screen scope (architecture §7 defers the full-screen renderer).**
   The contract ships a minimal alt-screen path (full-size `Buffer` +
   `renderDiff`/`renderAll` + smcup/rmcup on change). Is that in v1
   framework scope, or should `alt_screen` mode be a documented no-op/refusal
   until the real alt-screen renderer lands? The inline↔alt diff machinery
   (§5.3) is needed either way and is cheap to keep.
2. **`Cmd.sequence` semantics.** Is strict sequential draining (each
   element's effects fully processed before the next starts) required, or is
   in-order `batch` dispatch sufficient for v1? `sequence` vs `batch` differ
   only when an element's effects must complete before the next's start.
3. **`Context` surface width.** The contract exposes the framework-owned
   `buf`/`region` to `View.draw` (needed to compose into the frame Buffer).
   Prefer this full surface, or a narrower one (only `width`/`height` + an
   `appendAbove` helper) to keep framework render internals private — at the
   cost of the components drawing into an opaque frame?
