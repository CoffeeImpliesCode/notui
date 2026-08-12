//! Statusline example: styled segments, width truncation/wrapping, and
//! the non-TTY degradation path.
//!
//! Demonstrates (plan T7.4):
//! - styled segments: fg/bg/attrs via `Style` + `Buffer.draw`;
//! - `width.truncate` + `width.wrap` for segment text;
//! - ColorProfile fallback: rgb accents on a truecolor terminal,
//!   palette colors on weaker profiles (the emit layer downsamples rgb
//!   via `writeStyleProfile` for direct users — see `Palette`);
//! - the non-TTY path: with piped stdin, skip `makeRaw` + capability
//!   detection, render one plain frame with `sync_output = false`, and
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
const width = notui.width;
const Key = notui.key;

/// Region height: one segment row plus one wrapped-message row.
const region_height: u16 = 2;

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
/// region degrades to one plain frame (`sync_output = false`, §4.8).
/// The default 80-column buffer is the frame width (no winsize to ask).
fn runPiped(gpa: std.mem.Allocator, io: std.Io) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var region = try Region.init(gpa, .{
        .height = region_height,
        .sync_output = false, // non-TTY degradation (§4.8)
    });
    defer region.deinit();

    // `profile = null` renders the same frame plain: every cell carries
    // the default style (no SGR) and the region's plain painter writes
    // blank cells as spaces, so the piped output is escape-free.
    try buildFrame(arena.allocator(), &region, null);

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
/// resize-driven repaint loop. The region's band is 2 rows; narrowing
/// the terminal triggers a strategy-2 clear + full redraw via
/// `Region.resize`, so stale wide rows never survive (plan §9.3).
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

    var need_redraw = true; // first frame
    while (true) {
        if (tty.checkResize()) {
            const nws = try tty.getWinsize();
            try region.resize(nws.cols, region_height);
            need_redraw = true;
        }

        if (need_redraw) {
            try buildFrame(arena.allocator(), &region, caps.color);
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
    }

    // Park the cursor below the band; the final frame stays in the
    // transcript (nothing is cleared).
    try region.exit(w);
    try caps.restore(w); // disable kitty keyboard — leave the user's terminal clean
    try w.flush();
}

/// Draw one frame into `region.cur`: row 0 holds left-aligned styled
/// segments (mode badge, app name, branch, truncated path) plus a
/// right-aligned tail, and row 1 the first wrapped line of a message
/// (`width.wrap`). `width.truncate` guards the narrow-width case.
///
/// All drawn text is allocated from `arena` (the cells borrow the
/// slices, architecture §3 — the arena lives for the whole session, so
/// the previous frame's slices in `prev` stay valid for diffing).
fn buildFrame(arena: std.mem.Allocator, region: *Region, profile: ?ColorProfile) !void {
    region.cur.clear();
    const palette = Palette.init(profile);

    var x: u16 = 0;

    // Mode badge — background accent, bold.
    x += try region.cur.draw(palette.badge, " NORMAL ", x, 0);
    x += try region.cur.draw(Style{}, " ", x, 0);
    // App name.
    x += try region.cur.draw(palette.app, "notui", x, 0);
    x += try region.cur.draw(Style{}, " │ ", x, 0);
    // Branch.
    x += try region.cur.draw(palette.branch, "main*", x, 0);
    x += try region.cur.draw(Style{}, " │ ", x, 0);

    // Path segment — the width.truncate demo: cut at a grapheme
    // boundary to fit `path_cols`, with a visible ellipsis.
    const path = "~/projects/notui/src/region.zig";
    const path_cols: usize = 22;
    if (width.strWidth(path) > path_cols) {
        const cut = try width.truncate(arena, path, path_cols - 1);
        x += try region.cur.draw(palette.dim, cut, x, 0);
        x += try region.cur.draw(palette.dim, "…", x, 0);
    } else {
        x += try region.cur.draw(palette.dim, path, x, 0);
    }

    // Right-aligned tail, ending at the right edge. Truncated when the
    // left segments leave too little room; drawn at the current position
    // when even that is too tight (over-wide drops gracefully, §8.8).
    // The gap between the left segments and the tail is left empty — the
    // region advances it with CUF, which is invisible after the
    // interactive erase.
    const tail = try std.fmt.allocPrint(arena, "v{s}  col {d}", .{ notui.version, region.width });
    const avail: i32 = @as(i32, region.width) - @as(i32, x);
    if (avail > 0) {
        const tail_w: i32 = @intCast(width.strWidth(tail));
        const tail_used = if (tail_w > avail)
            try width.truncate(arena, tail, @intCast(avail))
        else
            tail;
        const used: u16 = @intCast(width.strWidth(tail_used));
        const tail_x: u16 = region.width - used;
        if (tail_x >= x) {
            _ = try region.cur.draw(palette.tail, tail_used, tail_x, 0);
        } else {
            x += try region.cur.draw(palette.tail, tail_used, x, 0);
        }
    }

    // Message row — the width.wrap demo: wrap the message to the
    // region width and draw the first line (over-wide rows drop
    // gracefully, plan §8.8).
    const message = "the quick brown fox jumps over the lazy dog — width.wrap breaks " ++
        "long text at the region width and Buffer.draw renders it grapheme-safe";
    const wrapped = try width.wrap(arena, message, region.width, 1);
    const first_line_end = std.mem.indexOfScalar(u8, wrapped, '\n') orelse wrapped.len;
    _ = try region.cur.draw(palette.message, wrapped[0..first_line_end], 0, 1);
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
