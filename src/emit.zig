//! ANSI emit helpers: cursor movement, erasure, line reservation, sync
//! output, alt screen, and profile-gated SGR style writing.
//!
//! Adapted from zigzag `terminal/ansi.zig` constants (:8-63) and cursor /
//! SGR writers (:66-122, :294-321). OSC 52/8 functions are NOT copied
//! (deferred per plan). Every writer is `w: anytype` and must be
//! `std.Io.Writer`-compatible. No zg import — pure ANSI bytes.

const std = @import("std");
const Color = @import("color.zig").Color;
const ColorProfile = @import("color.zig").ColorProfile;
const rgbToAnsi = @import("color.zig").rgbToAnsi;
const rgbToAnsi256 = @import("color.zig").rgbToAnsi256;
const Style = @import("style.zig").Style;

/// ANSI escape codes.
pub const ESC = "\x1b";
pub const CSI = ESC ++ "[";
pub const OSC = ESC ++ "]";
pub const ST = ESC ++ "\\";

// Cursor control
pub const cursor_hide = CSI ++ "?25l";
pub const cursor_show = CSI ++ "?25h";

// Screen / line control
pub const screen_clear_below = CSI ++ "J";
pub const line_clear_right = CSI ++ "K";

// Alternate screen buffer
pub const alt_screen_enter = CSI ++ "?1049h";
pub const alt_screen_exit = CSI ++ "?1049l";

// Text attributes reset
pub const reset = CSI ++ "0m";

// Synchronized output (prevents tearing)
pub const sync_start = CSI ++ "?2026h";
pub const sync_end = CSI ++ "?2026l";

/// Hide the cursor.
pub fn hideCursor(w: anytype) !void {
    try w.writeAll(cursor_hide);
}

/// Show the cursor.
pub fn showCursor(w: anytype) !void {
    try w.writeAll(cursor_show);
}

/// Move the cursor to row/col, both 1-indexed (DEC convention).
pub fn cursorTo(w: anytype, row: u16, col: u16) !void {
    try w.print(CSI ++ "{d};{d}H", .{ row, col });
}

/// Erase from the cursor to the end of the screen (strategy-2 clear;
/// bounded below the band anchor — never erases above it).
pub fn eraseToEnd(w: anytype) !void {
    try w.writeAll(screen_clear_below);
}

/// Erase from the cursor to the end of the line.
pub fn eraseLine(w: anytype) !void {
    try w.writeAll(line_clear_right);
}

/// Reserve `n` lines below the cursor (CSI n E, CNL) — space reservation.
/// Emits nothing for `n == 0`.
pub fn appendLines(w: anytype, n: u16) !void {
    if (n > 0) try w.print(CSI ++ "{d}E", .{n});
}

/// Scroll the region up by `n` lines (content moves up, blank lines at
/// the bottom). Emits nothing for `n == 0`.
pub fn scrollRegionUp(w: anytype, n: u16) !void {
    if (n > 0) try w.print(CSI ++ "{d}S", .{n});
}

/// Query the cursor position (CPR); the reply arrives as `Event.cpr`.
pub fn queryCursor(w: anytype) !void {
    try w.writeAll(CSI ++ "6n");
}

/// Start synchronized output (CSI ?2026h).
pub fn beginSync(w: anytype) !void {
    try w.writeAll(sync_start);
}

/// End synchronized output (CSI ?2026l).
pub fn endSync(w: anytype) !void {
    try w.writeAll(sync_end);
}

/// Enter the alternate screen buffer (CSI ?1049h).
pub fn enterAltScreen(w: anytype) !void {
    try w.writeAll(alt_screen_enter);
}

/// Exit the alternate screen buffer (CSI ?1049l).
pub fn exitAltScreen(w: anytype) !void {
    try w.writeAll(alt_screen_exit);
}

/// Emit SGR for `s` assuming a truecolor profile (maximum fidelity).
/// Emits only non-default fields; a fully default style emits `CSI 0m`.
pub fn writeStyle(w: anytype, s: Style) !void {
    try writeStyleProfile(w, s, .truecolor);
}

/// Emit SGR for `s` with profile-gated color emission:
/// - `truecolor`: rgb emits `38;2;r;g;b` / `48;2;r;g;b`.
/// - `ansi256`: rgb downsamples via `rgbToAnsi256` to `38;5;N` / `48;5;N`.
/// - `ansi`: rgb maps to the nearest base color (`30-37` / `40-47`,
///   `90-97` / `100-107`).
///
/// Only non-default fields are emitted; a fully default style emits
/// `CSI 0m`. Hyperlinks (OSC 8) are not emitted (deferred).
pub fn writeStyleProfile(w: anytype, s: Style, profile: ColorProfile) !void {
    var count: usize = 0;
    const a = s.attrs;
    if (a.bold) count = try emitCode(w, count, 1);
    if (a.dim) count = try emitCode(w, count, 2);
    if (a.italic) count = try emitCode(w, count, 3);
    if (a.underline) count = try emitCode(w, count, 4);
    if (a.blink) count = try emitCode(w, count, 5);
    if (a.reverse) count = try emitCode(w, count, 7);
    if (a.strikethrough) count = try emitCode(w, count, 9);

    count = try writeFg(w, count, s.fg, profile);
    count = try writeBg(w, count, s.bg, profile);

    if (count == 0) {
        try w.writeAll(reset);
        return;
    }
    try w.writeByte('m');
}

/// Write one SGR parameter, prefixing `CSI` (first) or `;` (subsequent).
fn emitCode(w: anytype, count: usize, code: u16) !usize {
    if (count == 0) {
        try w.writeAll(CSI);
    } else {
        try w.writeByte(';');
    }
    try w.print("{d}", .{code});
    return count + 1;
}

fn writeFg(w: anytype, count: usize, c: ?Color, profile: ColorProfile) !usize {
    const color = c orelse return count;
    var n = count;
    return switch (color) {
        .default => n,
        .ansi => |ac| try emitCode(w, n, ac.fgCode()),
        .ansi256 => |idx| blk: {
            n = try emitCode(w, n, 38);
            n = try emitCode(w, n, 5);
            break :blk try emitCode(w, n, idx);
        },
        .rgb => |rgb| switch (profile) {
            .truecolor => blk: {
                n = try emitCode(w, n, 38);
                n = try emitCode(w, n, 2);
                n = try emitCode(w, n, rgb.r);
                n = try emitCode(w, n, rgb.g);
                break :blk try emitCode(w, n, rgb.b);
            },
            .ansi256 => blk: {
                n = try emitCode(w, n, 38);
                n = try emitCode(w, n, 5);
                break :blk try emitCode(w, n, rgbToAnsi256(rgb.r, rgb.g, rgb.b));
            },
            .ansi => try emitCode(w, n, rgbToAnsi(rgb.r, rgb.g, rgb.b).fgCode()),
        },
    };
}

fn writeBg(w: anytype, count: usize, c: ?Color, profile: ColorProfile) !usize {
    const color = c orelse return count;
    var n = count;
    return switch (color) {
        .default => n,
        .ansi => |ac| try emitCode(w, n, ac.bgCode()),
        .ansi256 => |idx| blk: {
            n = try emitCode(w, n, 48);
            n = try emitCode(w, n, 5);
            break :blk try emitCode(w, n, idx);
        },
        .rgb => |rgb| switch (profile) {
            .truecolor => blk: {
                n = try emitCode(w, n, 48);
                n = try emitCode(w, n, 2);
                n = try emitCode(w, n, rgb.r);
                n = try emitCode(w, n, rgb.g);
                break :blk try emitCode(w, n, rgb.b);
            },
            .ansi256 => blk: {
                n = try emitCode(w, n, 48);
                n = try emitCode(w, n, 5);
                break :blk try emitCode(w, n, rgbToAnsi256(rgb.r, rgb.g, rgb.b));
            },
            .ansi => try emitCode(w, n, rgbToAnsi(rgb.r, rgb.g, rgb.b).bgCode()),
        },
    };
}

test {
    std.testing.refAllDecls(@This());
}

/// Fixed-buffer writer for golden tests. `init` must run in place —
/// the writer borrows `buf`, so the struct must not move afterwards.
const TestWriter = struct {
    buf: [128]u8 = undefined,
    w: std.Io.Writer = undefined,

    fn init(self: *TestWriter) void {
        self.w = .fixed(&self.buf);
    }
};

test "emit: cursor visibility and positioning" {
    var t = TestWriter{};
    t.init();
    try hideCursor(&t.w);
    try std.testing.expectEqualStrings("\x1b[?25l", t.w.buffered());

    var t2 = TestWriter{};
    t2.init();
    try showCursor(&t2.w);
    try std.testing.expectEqualStrings("\x1b[?25h", t2.w.buffered());

    var t3 = TestWriter{};
    t3.init();
    try cursorTo(&t3.w, 5, 10);
    try std.testing.expectEqualStrings("\x1b[5;10H", t3.w.buffered());

    var t4 = TestWriter{};
    t4.init();
    try cursorTo(&t4.w, 1, 1);
    try std.testing.expectEqualStrings("\x1b[1;1H", t4.w.buffered());
}

test "emit: erasure" {
    var t = TestWriter{};
    t.init();
    try eraseToEnd(&t.w);
    try std.testing.expectEqualStrings("\x1b[J", t.w.buffered());

    var t2 = TestWriter{};
    t2.init();
    try eraseLine(&t2.w);
    try std.testing.expectEqualStrings("\x1b[K", t2.w.buffered());
}

test "emit: line reservation and scroll" {
    var t = TestWriter{};
    t.init();
    try appendLines(&t.w, 3);
    try std.testing.expectEqualStrings("\x1b[3E", t.w.buffered());

    var t2 = TestWriter{};
    t2.init();
    try appendLines(&t2.w, 1);
    try std.testing.expectEqualStrings("\x1b[1E", t2.w.buffered());

    // n == 0 emits nothing (zigzag guard convention).
    var t3 = TestWriter{};
    t3.init();
    try appendLines(&t3.w, 0);
    try std.testing.expectEqualStrings("", t3.w.buffered());

    var t4 = TestWriter{};
    t4.init();
    try scrollRegionUp(&t4.w, 2);
    try std.testing.expectEqualStrings("\x1b[2S", t4.w.buffered());

    var t5 = TestWriter{};
    t5.init();
    try scrollRegionUp(&t5.w, 0);
    try std.testing.expectEqualStrings("", t5.w.buffered());
}

test "emit: sync wrap, CPR, alt screen" {
    var t = TestWriter{};
    t.init();
    try beginSync(&t.w);
    try endSync(&t.w);
    try std.testing.expectEqualStrings("\x1b[?2026h\x1b[?2026l", t.w.buffered());

    var t2 = TestWriter{};
    t2.init();
    try queryCursor(&t2.w);
    try std.testing.expectEqualStrings("\x1b[6n", t2.w.buffered());

    var t3 = TestWriter{};
    t3.init();
    try enterAltScreen(&t3.w);
    try exitAltScreen(&t3.w);
    try std.testing.expectEqualStrings("\x1b[?1049h\x1b[?1049l", t3.w.buffered());
}

test "emit: writeStyle attrs" {
    var t = TestWriter{};
    t.init();
    try writeStyle(&t.w, .{ .fg = .{ .ansi = .red }, .attrs = .{ .bold = true } });
    try std.testing.expectEqualStrings("\x1b[1;31m", t.w.buffered());

    var t2 = TestWriter{};
    t2.init();
    try writeStyle(&t2.w, .{ .attrs = .{ .bold = true, .italic = true, .underline = true } });
    try std.testing.expectEqualStrings("\x1b[1;3;4m", t2.w.buffered());

    var t3 = TestWriter{};
    t3.init();
    try writeStyle(&t3.w, .{ .attrs = .{ .dim = true, .strikethrough = true } });
    try std.testing.expectEqualStrings("\x1b[2;9m", t3.w.buffered());
}

test "emit: writeStyle colors on truecolor" {
    var t = TestWriter{};
    t.init();
    try writeStyle(&t.w, .{ .fg = .{ .rgb = .{ .r = 255, .g = 0, .b = 128 } } });
    try std.testing.expectEqualStrings("\x1b[38;2;255;0;128m", t.w.buffered());

    var t2 = TestWriter{};
    t2.init();
    try writeStyle(&t2.w, .{ .bg = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } } });
    try std.testing.expectEqualStrings("\x1b[48;2;1;2;3m", t2.w.buffered());

    var t3 = TestWriter{};
    t3.init();
    try writeStyle(&t3.w, .{ .fg = .{ .ansi = .bright_cyan } });
    try std.testing.expectEqualStrings("\x1b[96m", t3.w.buffered());

    var t4 = TestWriter{};
    t4.init();
    try writeStyle(&t4.w, .{ .bg = .{ .ansi = .red } });
    try std.testing.expectEqualStrings("\x1b[41m", t4.w.buffered());

    var t5 = TestWriter{};
    t5.init();
    try writeStyle(&t5.w, .{ .fg = .{ .ansi256 = 200 } });
    try std.testing.expectEqualStrings("\x1b[38;5;200m", t5.w.buffered());
}

test "emit: writeStyle profile gating" {
    // rgb on ansi256 profile downsamples to the nearest palette index.
    var t = TestWriter{};
    t.init();
    try writeStyleProfile(&t.w, .{ .fg = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } } }, .ansi256);
    try std.testing.expectEqualStrings("\x1b[38;5;196m", t.w.buffered());

    var t2 = TestWriter{};
    t2.init();
    try writeStyleProfile(&t2.w, .{ .bg = .{ .rgb = .{ .r = 0, .g = 0, .b = 0 } } }, .ansi256);
    try std.testing.expectEqualStrings("\x1b[48;5;16m", t2.w.buffered());

    // rgb on ansi profile maps to the nearest base color.
    var t3 = TestWriter{};
    t3.init();
    try writeStyleProfile(&t3.w, .{ .fg = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } } }, .ansi);
    try std.testing.expectEqualStrings("\x1b[91m", t3.w.buffered());

    var t4 = TestWriter{};
    t4.init();
    try writeStyleProfile(&t4.w, .{ .bg = .{ .rgb = .{ .r = 0, .g = 0, .b = 0 } } }, .ansi);
    try std.testing.expectEqualStrings("\x1b[40m", t4.w.buffered());

    // Explicit ansi/ansi256 colors pass through unchanged on any profile.
    var t5 = TestWriter{};
    t5.init();
    try writeStyleProfile(&t5.w, .{ .fg = .{ .ansi = .red }, .bg = .{ .ansi256 = 21 } }, .ansi);
    try std.testing.expectEqualStrings("\x1b[31;48;5;21m", t5.w.buffered());

    // writeStyle defaults to the truecolor profile.
    var t6 = TestWriter{};
    t6.init();
    try writeStyle(&t6.w, .{ .fg = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } } });
    try std.testing.expectEqualStrings("\x1b[38;2;255;0;0m", t6.w.buffered());
}

test "emit: writeStyle empty resets" {
    var t = TestWriter{};
    t.init();
    try writeStyle(&t.w, .{});
    try std.testing.expectEqualStrings("\x1b[0m", t.w.buffered());

    // Explicit .default colors are not emitted either.
    var t2 = TestWriter{};
    t2.init();
    try writeStyle(&t2.w, .{ .fg = .default, .bg = .default });
    try std.testing.expectEqualStrings("\x1b[0m", t2.w.buffered());

    // Hyperlinks are not emitted (OSC 8 deferred).
    var t3 = TestWriter{};
    t3.init();
    try writeStyle(&t3.w, .{ .hyperlink = "https://example.com" });
    try std.testing.expectEqualStrings("\x1b[0m", t3.w.buffered());
}

test "emit: writeStyle combined sequence" {
    var t = TestWriter{};
    t.init();
    try writeStyle(&t.w, .{
        .fg = .{ .ansi256 = 200 },
        .bg = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
        .attrs = .{ .bold = true, .dim = true, .italic = true, .underline = true, .blink = true, .reverse = true, .strikethrough = true },
    });
    try std.testing.expectEqualStrings("\x1b[1;2;3;4;5;7;9;38;5;200;48;2;1;2;3m", t.w.buffered());
}
