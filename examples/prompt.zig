//! Prompt: echo, backspace, Enter-to-scrollback, resize, clean exit
//! (plan T7.3).
//!
//! The region shows a one-line "prompt > " band with the typed echo.
//! Typed keys are COPIED into an app-owned arena before the next read
//! (the §3 lifetime contract: `Key.text` is valid only until the next
//! `Reader.next` call). Enter appends the typed line to the append
//! queue as `.line` entries, so each entry lands ABOVE the band in
//! scrollback; backspace edits the line; ctrl+c clears it (a normal key
//! event — the app never hard-quits); the app quits only on an
//! empty-line `q` or on ctrl+d. Resizes go through `Tty.checkResize` →
//! `Region.resize` with the terminal's real columns AND rows, so a
//! physical shrink repaints the surviving band (strategy-2 clear +
//! redraw) while the height stays the intended constant below.

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

/// Band height: the prompt row alone. The terminal's own row count is a
/// SEPARATE fact, handed to `Region.resize` as its second argument; the
/// intended height is this constant, so a band the physical shrink
/// clipped comes back in full when the terminal grows again.
const band_height: u16 = 1;

/// The prompt prefix drawn in the region band.
const prompt_text = "prompt > ";

/// Ctrl+D, the app's quit key (Key defines only ctrl_c among the ASCII
/// control chars).
const ctrl_d: u21 = 0x04;

const tick_ms: i32 = 100;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // Non-TTY degradation (same as spinner): one plain frame, no tty.
    if (!Tty.isTty(std.posix.STDIN_FILENO)) {
        return runPlain(io);
    }

    var tty = try Tty.init(io);
    defer tty.deinit();
    try tty.makeRaw();
    defer tty.restore();

    var parser: notui.parser = .{};
    const caps = try notui.caps.Capabilities.detect(gpa, &tty, &parser);

    var region = try Region.init(gpa, .{ .height = band_height });
    defer region.deinit();

    const ws = try tty.getWinsize();
    try region.resize(ws.cols, ws.rows, band_height);

    // App-owned arena: typed text lives here for the whole session.
    // Enter-queued `.line` slices also point into it and stay valid
    // until the region flushes them on the next render (and beyond).
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    // The line being typed (grows in the arena).
    var line: std.ArrayList(u8) = .empty;

    var reader = Reader.init(&tty);
    const w = tty.writer();

    while (true) {
        const ev = reader.nextTimeout(tick_ms) catch break;
        if (ev) |e| switch (e) {
            .key_press => |k| {
                if (isCtrlC(k)) {
                    // Normal key event: clear the line, keep running.
                    line.clearRetainingCapacity();
                } else if (isCtrlD(k)) {
                    break; // ctrl+d always quits
                } else if (k.matches('q', .{}) and line.items.len == 0) {
                    break; // `q` quits only on an empty line — else text
                } else if (k.matches(Key.enter, .{})) {
                    try pushLine(aa, &region, line.items);
                    line.clearRetainingCapacity();
                } else if (k.matches(Key.backspace, .{})) {
                    line.items = popCodepoint(line.items);
                } else if (k.matches(Key.escape, .{})) {
                    // Ignore.
                } else {
                    try appendKeyText(aa, &line, k);
                }
            },
            .winsize => |wsz| try region.resize(wsz.cols, wsz.rows, band_height),
            .cpr => |pos| try region.applyCpr(pos.row, pos.col),
            else => {},
        };

        if (tty.checkResize()) {
            const wsz = try tty.getWinsize();
            try region.resize(wsz.cols, wsz.rows, band_height);
        }

        try drawPrompt(&region, line.items);
        try region.render(w);
        try w.flush();
    }

    try region.exit(w);
    try caps.restore(w); // disable kitty keyboard — leave the user's terminal clean
    try w.flush();
}

/// Paint the band: prompt prefix + echoed input. Over-wide input drops
/// at the right edge (`Buffer.draw` truncates gracefully — §8.8).
fn drawPrompt(region: *Region, line: []const u8) !void {
    region.cur.clear();
    const n = try region.cur.draw(.{}, prompt_text, 0, 0);
    _ = try region.cur.draw(.{}, line, n, 0);
}

/// Queue the typed line above the band as `.line` entries, split into
/// terminal-width rows so each occupies exactly one row: an over-wide
/// `.line` would wrap at the terminal and drift the region's anchor
/// accounting. Chunks are arena-owned (never freed until exit), so the
/// queued slices stay valid until the next render flushes them.
fn pushLine(aa: std.mem.Allocator, region: *Region, text: []const u8) !void {
    var rest = text;
    while (rest.len > 0) {
        const chunk = try notui.width.truncate(aa, rest, region.width);
        if (chunk.len == 0) break; // a single over-wide grapheme: drop
        try region.append(.{ .line = chunk });
        rest = rest[chunk.len..];
    }
}

/// True for a ctrl+c keypress in either decoding: kitty CSI-u reports
/// the control character itself (0x03); the legacy ground-state path
/// maps byte 0x03 to 'c' + ctrl (parser.zig parseGround, libvaxis
/// convention). The examples must accept both.
fn isCtrlC(k: Key) bool {
    return k.matches(Key.ctrl_c, .{}) or k.matches('c', .{ .ctrl = true });
}

/// Same for ctrl+d (0x04 → 'd' + ctrl in legacy ground state).
fn isCtrlD(k: Key) bool {
    return k.matches(ctrl_d, .{}) or k.matches('d', .{ .ctrl = true });
}

/// Copy the key's text into the app arena — the §3 lifetime contract:
/// `Key.text` is valid only until the next read, so it must be copied
/// before that. Keys without text (control chars, PUA function /
/// navigation keys, the multicodepoint marker) produce nothing.
fn appendKeyText(aa: std.mem.Allocator, line: *std.ArrayList(u8), k: Key) !void {
    if (k.text) |t| {
        try line.appendSlice(aa, t);
        return;
    }
    // No text: encode the codepoint only for genuinely printable keys.
    const cp = k.codepoint;
    if (cp < 0x20 or cp == 0x7F or (cp >= 0xE000 and cp <= 0xF8FF) or cp > 0x10FFFF) return;
    var buf: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(cp, &buf);
    try line.appendSlice(aa, buf[0..n]);
}

/// Remove the last UTF-8 codepoint (backspace). Codepoint-level: a
/// combining mark is removed on its own — grapheme-aware backspace is
/// out of scope for the example.
fn popCodepoint(buf: []u8) []u8 {
    var end = buf.len;
    if (end == 0) return buf;
    end -= 1;
    // Walk back over continuation bytes to the sequence's lead byte.
    while (end > 0 and (buf[end] & 0xC0) == 0x80) end -= 1;
    return buf[0..end];
}

/// One plain frame (the empty prompt), no interactive sequences.
fn runPlain(io: std.Io) !void {
    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io, prompt_text);
    try stdout.writeStreamingAll(io, "\n");
}
