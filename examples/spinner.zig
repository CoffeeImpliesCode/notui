//! Spinner: the minimal interactive recipe (plan T7.2).
//!
//! Tty.init(io) → makeRaw → Caps.detect → Region.init → loop {
//! Reader.nextTimeout(100) → switch: ctrl_c/q quit, winsize/checkResize
//! → Region.resize } → Region.render with a rotating 1-line glyph →
//! Region.exit → Tty.restore.
//!
//! Piped / non-TTY stdin degrades to one plain frame (architecture §4.8):
//! the tty is never touched, so the piped run emits exactly one frame and
//! exits 0 — no interactive control sequences, no hang.

const std = @import("std");
const notui = @import("notui");

const Tty = notui.tty.Tty;
const Region = notui.region.Region;
const Key = notui.key;
const Reader = notui.input.Reader;

/// Rotating braille glyphs, each exactly one column wide.
const frames = [_][]const u8{
    "⠋",
    "⠙",
    "⠹",
    "⠸",
    "⠼",
    "⠴",
    "⠦",
    "⠧",
    "⠇",
    "⠏",
};

/// Loop pacing: nextTimeout returns null on timeout, advancing one tick.
const tick_ms: i32 = 100;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // Non-TTY degradation: when stdin is not a terminal, skip the tty
    // entirely (Tty.init opens /dev/tty, which is wrong and can fail
    // without a controlling terminal) and print one plain frame.
    if (!Tty.isTty(std.posix.STDIN_FILENO)) {
        return runPlain(gpa, io);
    }

    var tty = try Tty.init(io);
    defer tty.deinit();
    try tty.makeRaw();
    defer tty.restore();

    var parser: notui.parser = .{};
    const caps = try notui.caps.Capabilities.detect(gpa, &tty, &parser);

    var region = try Region.init(gpa, .{ .height = 1 });
    defer region.deinit();

    // Size the band to the terminal before the first frame. This sets
    // width_dirty, but the first render (strategy 1) takes priority over
    // it, so no stray clear is emitted before anything painted.
    const ws = try tty.getWinsize();
    try region.resize(ws.cols, region.height);

    var reader = Reader.init(&tty);
    const w = tty.writer();

    var frame: usize = 0;
    while (true) {
        const ev = reader.nextTimeout(tick_ms) catch break;
        if (ev) |e| switch (e) {
            .key_press => |k| {
                // Ctrl+C arrives as a normal key event (raw mode: ISIG
                // off); the app decides to quit. Its decoding depends on
                // the terminal protocol: kitty CSI-u reports the control
                // char itself (0x03); legacy ground state maps byte 0x03
                // to 'c' + ctrl (parser.zig parseGround, libvaxis
                // convention). Check both forms.
                if (k.matches(Key.ctrl_c, .{}) or k.matches('c', .{ .ctrl = true })) break;
                if (k.matches('q', .{})) break;
            },
            .winsize => |wsz| try region.resize(wsz.cols, region.height),
            else => {},
        };

        // SIGWINCH: re-measure and rebuild the band (strategy 2 clears
        // the old-width rows before repainting — no resize dupes).
        if (tty.checkResize()) {
            const wsz = try tty.getWinsize();
            try region.resize(wsz.cols, region.height);
        }

        region.cur.clear();
        _ = try region.cur.draw(.{}, frames[frame % frames.len], 0, 0);
        try region.render(w);
        try w.flush();
        frame += 1;
    }

    // Park the cursor below the band; the last frame stays in the
    // transcript (nothing is cleared).
    try region.exit(w);
    try caps.restore(w); // disable kitty keyboard etc. — leave the user's terminal clean
    try w.flush();
}

/// One plain frame, no interactive sequences: `glyph\n` (piped run).
fn runPlain(gpa: std.mem.Allocator, io: std.Io) !void {
    var region = try Region.init(gpa, .{
        .height = 1,
        .append_lines = false,
        .sync_output = false,
    });
    defer region.deinit();

    _ = try region.cur.draw(.{}, frames[0], 0, 0);

    var buf: [1024]u8 = undefined;
    var fw = std.Io.File.stdout().writerStreaming(io, &buf);
    const w = &fw.interface;
    try region.render(w);
    try region.exit(w);
    try w.flush();
}
