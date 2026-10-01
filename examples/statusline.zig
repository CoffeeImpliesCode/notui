//! Statusline example: the base-ui layer dogfood — a StatusBar, a
//! live Gauge, and a wrapped Text row — plus the non-TTY degradation
//! path.
//!
//! Demonstrates (plan T7.4 / baseui-improvements.md §4):
//! - `component.StatusBar`: left/center/right segments with width-aware
//!   truncation (right group anchors to the edge, then the center
//!   floats; left is kept whole);
//! - `component.Gauge`: fractional block fill, threshold colors, label
//!   + percent suffix — value driven by the app each tick;
//! - `component.Text.wrap` for the message row;
//! - ColorProfile fallback: rgb accents on a truecolor terminal,
//!   palette colors on weaker profiles (the emit layer downsamples rgb
//!   via `writeStyleProfile` for direct users — see `Palette`);
//! - the non-TTY path: with piped stdin, skip `makeRaw` + capability
//!   detection, render one plain frame with `interactive = false`, and
//!   exit without parking. The same frame renders styled on a tty and
//!   plain in a pipe (no SGR, no interactive sequences).
//!
//! fd-capture interaction (architecture §9.2 — known, deferred): the
//! Region's anchor is tracked from its OWN writes only. Any external
//! write to fd 1/2 between frames (a log line, another component)
//! drifts the terminal cursor and with it the tracked anchor. v0 does
//! not consume the CPR reply, so `reanchor()` buys a re-query but no
//! correction — apps must not write to the tty outside the region, or
//! must call `reanchor()` and accept one frame of drift.

const std = @import("std");
const notui = @import("notui");

/// Restore the terminal on panic: defers never run for a panicking
/// process, and a raw/hidden-cursor/kitty-mode terminal is what forces a
/// hard reset. Re-raises the default panic after cleanup.
pub const panic = std.debug.FullPanic(struct {
    pub fn call(msg: []const u8, ra: ?usize) noreturn {
        notui.tty.restoreTerminal();
        std.debug.defaultPanic(msg, ra);
    }
}.call);

const Region = notui.region.Region;
const Style = notui.style.Style;
const Color = notui.color.Color;
const ColorProfile = notui.color.ColorProfile;
const Key = notui.key;
const component = notui.component;

/// Region height: StatusBar, Gauge, and one wrapped-message row.
const region_height: u16 = 3;

/// Monotonic anchor for the gauge's elapsed-time animation (module
/// state, the components' scratch pattern, src/component/text.zig).
var frame_anchor: ?component.Clock = null;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    if (!notui.tty.Tty.isTty(std.posix.STDIN_FILENO)) {
        // Piped stdin: there is no terminal to query or put into raw
        // mode. Render one plain frame to stdout (fd 1 — the pipe) and
        // exit without parking.
        return runPiped(gpa, io);
    }
    try runInteractive(gpa, io);
}

/// Non-TTY path: no Tty is opened, no makeRaw, no Caps.detect — the
/// region degrades to one plain frame (`interactive = false`, §4.8).
/// The default 80-column buffer is the frame width (no winsize to ask).
fn runPiped(gpa: std.mem.Allocator, io: std.Io) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var region = try Region.init(gpa, .{
        .height = region_height,
        .interactive = false,
    });
    defer region.deinit();

    // `profile = null` renders the same frame plain: every cell carries
    // the default style (no SGR) and the region's plain painter writes
    // blank cells as spaces, so the piped output is escape-free.
    // The gauge is caller-owned: its percent_buf must outlive the
    // frame build (the cells borrow it until `render`).
    var gauge: component.Gauge = .{ .width = 30, .label = "scan" };
    const now: component.Clock = std.Io.Timestamp.now(io, .awake);
    try buildFrame(arena.allocator(), &region, null, now, &gauge);

    var stdout = std.Io.File.stdout();
    var out_buf: [4096]u8 = undefined;
    var out = stdout.writerStreaming(io, &out_buf);
    try region.render(&out.interface);
    // exit() parks nothing in non-TTY mode — the plain frame was the
    // only output (ink/delta pattern).
    try region.exit(&out.interface);
    try out.interface.flush();
}

/// Interactive path: raw mode, live capability detection, and a
/// tick-driven repaint loop. The region's band is 3 rows; narrowing
/// the terminal triggers a strategy-2 clear + full redraw via
/// `Region.resize`, so stale wide rows never survive (plan §9.3). The
/// gauge animates because the frame is rebuilt once per loop iteration
/// (each tick advances the sin-driven value).
fn runInteractive(gpa: std.mem.Allocator, io: std.Io) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var tty = try notui.tty.Tty.init(io);
    defer tty.deinit();
    try tty.makeRaw();
    defer tty.restore();

    var parser: notui.parser = .{};
    const caps = try notui.caps.Capabilities.detect(gpa, &tty, &parser);

    var region = try Region.init(gpa, .{
        .height = region_height,
        .sync_output = caps.sync_output,
        .width_policy = caps.widthPolicy(),
    });
    defer region.deinit();

    const ws = try tty.getWinsize();
    try region.resize(ws.cols, region_height);

    var reader = notui.input.Reader.init(&tty);
    const w = tty.writer();

    // Caller-owned gauge: its percent_buf must outlive each frame
    // build (the cells borrow it until `render`).
    var gauge: component.Gauge = .{ .width = 30, .label = "scan" };

    var need_redraw = true; // first frame
    while (true) {
        if (tty.checkResize()) {
            const nws = try tty.getWinsize();
            try region.resize(nws.cols, region_height);
            need_redraw = true;
        }

        if (need_redraw) {
            // The monotonic clock, sampled once per loop iteration —
            // the gauge's drive signal (v1 clock model, component.zig).
            const now: component.Clock = std.Io.Timestamp.now(io, .awake);
            try buildFrame(arena.allocator(), &region, caps.color, now, &gauge);
            try region.render(w);
            try w.flush();
            need_redraw = false;
        }

        const ev = try reader.nextTimeout(100);
        if (ev) |e| switch (e) {
            .key_press => |k| {
                // Ctrl+C arrives as a normal key event (raw mode: ISIG
                // off). Kitty CSI-u reports 0x03 directly; legacy ground
                // state maps byte 0x03 to 'c' + ctrl — check both forms.
                if (k.matches(Key.ctrl_c, .{}) or k.matches('c', .{ .ctrl = true }) or
                    k.matches('q', .{})) break;
            },
            else => {},
        };

        // Animate the gauge: redraw once per tick so the sin-driven
        // value keeps moving even with no input (the one behavioral
        // change beyond refactoring).
        need_redraw = true;
    }

    // Park the cursor below the band; the final frame stays in the
    // transcript (nothing is cleared).
    try region.exit(w);
    try caps.restore(w); // disable kitty keyboard — leave the user's terminal clean
    try w.flush();
}

/// Draw one frame into `region.cur` with the base-ui components: row 0
/// a StatusBar (left segments + right-aligned tail), row 1 a Gauge
/// (label, thresholds, percent), row 2 the first wrapped line of a
/// message (Text.wrap). The components are static (`advance` false);
/// the gauge's value follows the elapsed monotonic clock, so the app
/// redraws each tick to animate it. The gauge is caller-owned (its
/// percent_buf must outlive this call — the cells borrow it, §2.2).
///
/// All drawn text is allocated from `arena` (the cells borrow the
/// slices, architecture §3 — the arena lives for the whole session, so
/// the previous frame's slices in `prev` stay valid for diffing).
fn buildFrame(
    arena: std.mem.Allocator,
    region: *Region,
    profile: ?ColorProfile,
    now: component.Clock,
    gauge: *component.Gauge,
) !void {
    region.cur.clear();
    const palette = Palette.init(profile);

    // Row 0 — StatusBar: left segments joined by " │ " (the badge's
    // leading/trailing space is baked into its text), right-aligned
    // tail. StatusBar owns the right alignment and truncation now.
    const tail = try std.fmt.allocPrint(arena, "v{s}  col {d}", .{ notui.version, region.width });
    var bar: component.StatusBar = .{
        .left = &.{
            .{ .text = " NORMAL ", .style = palette.badge },
            .{ .text = "notui", .style = palette.app },
            .{ .text = "main*", .style = palette.branch },
        },
        .right = &.{.{ .text = tail, .style = palette.tail }},
        .separator = " │ ",
    };
    _ = try bar.draw(&region.cur, 0, 0, now);

    // Row 1 — Gauge: a live meter, value driven by the app from the
    // elapsed monotonic clock (not component-animated). Fill styles
    // come from the palette (all-default in the plain frame — a set
    // color would emit SGR into the pipe); thresholds are dropped in
    // the plain frame for the same reason.
    gauge.label_style = palette.app;
    gauge.percent_style = palette.tail;
    gauge.full_style = palette.branch;
    gauge.empty_style = palette.dim;
    gauge.thresholds = if (profile == null) &.{} else &.{
        .{ .value = 50, .color = .{ .ansi = .yellow } },
        .{ .value = 85, .color = .{ .ansi = .red } },
    };
    gauge.setValue(50.0 + 45.0 * @sin(elapsedSeconds(now)));
    _ = try gauge.draw(&region.cur, 0, 1, now);

    // Row 2 — Text.wrap: the wrapped-message row. The scratch is
    // arena-backed, so the cells it holds borrow valid memory past
    // this call (the borrow model, architecture §3).
    const message = "the quick brown fox jumps over the lazy dog — width.wrap breaks " ++
        "long text at the region width and Buffer.draw renders it grapheme-safe";
    var scratch: std.ArrayList(u8) = .empty;
    var msg: component.Text = .{ .text = message, .wrap = true, .style = palette.message, .scratch = &scratch };
    _ = try msg.draw(arena, &region.cur, 0, 2, now);
}

/// Seconds since the first frame — the gauge's drive signal.
fn elapsedSeconds(now: component.Clock) f64 {
    const a = frame_anchor orelse {
        frame_anchor = now;
        return 0;
    };
    const d = now.nanoseconds - a.nanoseconds;
    return @as(f64, @floatFromInt(d)) / @as(f64, std.time.ns_per_s);
}

/// Profile-driven palette. `init(.truecolor)` returns rgb accents; a
/// weaker profile falls back to palette indexes — the app-side
/// ColorProfile fallback. (The emit layer performs the same fallback
/// for direct users: `emit.writeStyleProfile` downsamples an rgb style
/// to `38;5;N` on an ansi256 profile and to the nearest ANSI color on
/// an ansi profile. The Region's own path writes rgb at truecolor
/// fidelity, so profile-gated apps either pick colors here, as this
/// example does, or drive `emit` directly.)
const Palette = struct {
    badge: Style,
    app: Style,
    branch: Style,
    dim: Style,
    tail: Style,
    message: Style,

    /// All-default palette: the plain frame of the non-TTY path.
    const plain: Palette = .{
        .badge = .{},
        .app = .{},
        .branch = .{},
        .dim = .{},
        .tail = .{},
        .message = .{},
    };

    fn init(profile: ?ColorProfile) Palette {
        const p = profile orelse return plain;
        const accent: Color = if (p.supportsTrueColor())
            Color.fromRgb(88, 166, 255)
        else
            .{ .ansi256 = 75 };
        const green: Color = if (p.supportsTrueColor())
            Color.fromRgb(122, 200, 122)
        else
            .{ .ansi256 = 78 };
        const dim: Color = if (p.supports256())
            .{ .ansi256 = 245 }
        else
            .{ .ansi = .bright_black };
        return .{
            .badge = .{ .fg = .{ .ansi = .white }, .bg = accent, .attrs = .{ .bold = true } },
            .app = .{ .fg = accent, .attrs = .{ .bold = true } },
            .branch = .{ .fg = green },
            .dim = .{ .fg = dim },
            .tail = .{ .fg = accent },
            .message = .{ .attrs = .{ .italic = true } },
        };
    }
};
