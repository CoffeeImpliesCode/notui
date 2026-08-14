//! kitty_image: proves kitty graphics as a notui capability.
//!
//! After Caps.detect, if the terminal advertises kitty graphics
//! (`caps.kitty_graphics`), a tiny 4x4 RGBA checkerboard is transmitted
//! inline (`notui.image.kitty.transmit`) and placed at the band's
//! top-left cell (`region.placeAt`); the image is dropped again on quit
//! (`notui.image.kitty.delete`). A one-line hint shows the outcome:
//! "kitty images: ON" or "kitty images: unsupported". q / Ctrl+C quit.
//!
//! Piped / non-TTY stdin degrades to one plain frame (architecture §4.8):
//! the tty is never touched and no image sequences are emitted — the
//! piped run prints exactly one frame and exits 0.

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

const Tty = notui.tty.Tty;
const Region = notui.region.Region;
const Key = notui.key;
const Reader = notui.input.Reader;

/// 4x4 RGBA checkerboard (2x2 blocks of red/blue, opaque): 4·4·4 = 64
/// bytes, small enough to transmit inline in a single chunk.
const checkerboard = blk: {
    @setEvalBranchQuota(1_000);
    var px: [64]u8 = undefined;
    for (0..4) |row| {
        for (0..4) |col| {
            const red_block = (row < 2) == (col < 2);
            const i = (row * 4 + col) * 4;
            px[i + 0] = if (red_block) 0xff else 0x00; // R
            px[i + 1] = 0x00; // G
            px[i + 2] = if (red_block) 0x00 else 0xff; // B
            px[i + 3] = 0xff; // A
        }
    }
    break :blk px;
};

/// The image id this demo transmits under (explicit, so `place` can
/// address it).
const image_id: u32 = 0;

/// Loop pacing: nextTimeout returns null on timeout, redrawing the hint.
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

    // Size the band to the terminal before the first frame.
    const ws = try tty.getWinsize();
    try region.resize(ws.cols, region.height);

    const w = tty.writer();

    // Transmit once up front (position-independent). The placement needs
    // the band's ABSOLUTE screen row, which is only known once the first
    // CPR reply anchors the band (see the `.cpr` arm below):
    // `region.placeAt` CUP's to the absolute cell (band row 0), places,
    // then parks back at the band bottom.
    if (caps.kitty_graphics) {
        try notui.image.kitty.transmit(w, .{
            .format = .rgba,
            .width = 4,
            .height = 4,
            .id = image_id,
        }, &checkerboard);
        try w.flush();
    }

    // The hint sits clear of the image (which occupies the top-left
    // corner of row 0) when the image is present.
    const hint = if (caps.kitty_graphics)
        "kitty images: ON"
    else
        "kitty images: unsupported";

    var reader = Reader.init(&tty);
    // The band's absolute top row is unknown until the FIRST CPR reply
    // (the query fires before the first paint; see `.cpr` below).
    var anchor_known: bool = false;
    while (true) {
        const ev = reader.nextTimeout(tick_ms) catch break;
        if (ev) |e| switch (e) {
            .key_press => |k| {
                // Ctrl+C arrives as a normal key event (raw mode: ISIG
                // off); the app decides to quit. Its decoding depends on
                // the terminal protocol: kitty CSI-u reports the control
                // char itself (0x03); legacy ground state maps byte 0x03
                // to 'c' + ctrl. Check both forms.
                if (k.matches(Key.ctrl_c, .{}) or k.matches('c', .{ .ctrl = true })) break;
                if (k.matches('q', .{})) break;
            },
            .cpr => |pos| {
                if (!anchor_known) {
                    // The FIRST reply answers the query emitted at the
                    // first render start, BEFORE the first paint — the
                    // cursor then sat at the pre-frame row. The
                    // region's bookkeeping already holds every shift
                    // applied since (the CNL reservation), so
                    // applyFirstCpr re-anchors exactly. Anchor it, then
                    // place the image at the band's top-left cell via
                    // `region.placeAt` (band row 0, col 1).
                    region.applyFirstCpr(pos.row);
                    anchor_known = true;
                    if (caps.kitty_graphics) {
                        try region.placeAt(w, 0, 1, .{
                            .id = image_id,
                            .placement = image_id,
                        });
                    }
                } else {
                    // Steady-state: the cursor parks at the band bottom
                    // after every frame, so the bottom-based correction
                    // applies.
                    try region.applyCpr(pos.row, pos.col);
                }
            },
            .winsize => |wsz| try region.resize(wsz.cols, region.height),
            else => {},
        };

        // SIGWINCH: re-measure and rebuild the band.
        if (tty.checkResize()) {
            const wsz = try tty.getWinsize();
            try region.resize(wsz.cols, region.height);
        }

        region.cur.clear();
        _ = try region.cur.draw(.{}, hint, if (caps.kitty_graphics) 2 else 0, 0);
        try region.render(w);
        try w.flush();
    }

    // Park the cursor below the band; the last frame stays in the
    // transcript (nothing is cleared). Then disable the terminal modes
    // detect() enabled and drop the transmitted image.
    try region.exit(w);
    try caps.restore(w);
    if (caps.kitty_graphics) try notui.image.kitty.delete(w, image_id);
    try w.flush();
}

/// One plain frame, no interactive sequences: the hint line (piped run).
fn runPlain(gpa: std.mem.Allocator, io: std.Io) !void {
    var region = try Region.init(gpa, .{
        .height = 1,
        .append_lines = false,
        .sync_output = false,
    });
    defer region.deinit();

    _ = try region.cur.draw(.{}, "kitty images: unsupported", 0, 0);

    var buf: [1024]u8 = undefined;
    var fw = std.Io.File.stdout().writerStreaming(io, &buf);
    const w = &fw.interface;
    try region.render(w);
    try region.exit(w);
    try w.flush();
}
