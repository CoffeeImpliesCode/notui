//! ANSI byte writers: cursor movement, erasure, line reservation,
//! synchronized output, autowrap, and SGR style output.
//!
//! Every writer takes `w: anytype` and calls `writeAll`/`print` on it, so it
//! works with any `std.Io.Writer`-compatible sink. Writes are not
//! transactional: a writer error leaves whatever had already been written on
//! the wire.

const std = @import("std");
const Color = @import("color.zig").Color;
const ColorProfile = @import("color.zig").ColorProfile;
const rgbToAnsi = @import("color.zig").rgbToAnsi;
const rgbToAnsi256 = @import("color.zig").rgbToAnsi256;
const Style = @import("style.zig").Style;

/// `ESC`; the introducer every escape sequence below starts with.
pub const esc = "\x1b";

/// `CSI`, `ESC [`: the introducer for a control sequence.
pub const csi = esc ++ "[";

/// Hides the cursor: `CSI ?25l`.
pub const cursor_hide = csi ++ "?25l";

/// Shows the cursor: `CSI ?25h`.
pub const cursor_show = csi ++ "?25h";

/// Erases from the cursor to the end of the screen: `CSI J`.
pub const screen_clear_below = csi ++ "J";

/// Erases from the cursor to the end of the line: `CSI K`.
pub const line_clear_right = csi ++ "K";

/// Turns autowrap off (DECAWM): `CSI ?7l`.
pub const autowrap_off = csi ++ "?7l";

/// Turns autowrap back on (DECAWM): `CSI ?7h`.
pub const autowrap_on = csi ++ "?7h";

/// Resets every SGR attribute and colour: `CSI 0m`.
pub const reset = csi ++ "0m";

/// Begins a synchronized-output frame: `CSI ?2026h`.
pub const sync_start = csi ++ "?2026h";

/// Ends a synchronized-output frame: `CSI ?2026l`.
pub const sync_end = csi ++ "?2026l";

/// Hide the cursor.
pub fn hideCursor(w: anytype) !void {
    try w.writeAll(cursor_hide);
}

/// Show the cursor.
pub fn showCursor(w: anytype) !void {
    try w.writeAll(cursor_show);
}

/// Erases from the cursor to the end of the screen.
pub fn eraseToEnd(w: anytype) !void {
    try w.writeAll(screen_clear_below);
}

/// Erase from the cursor to the end of the line.
pub fn eraseLine(w: anytype) !void {
    try w.writeAll(line_clear_right);
}

/// Reserve `n` new rows below the cursor by writing `n` CRLFs.
/// Emits nothing for `n == 0`.
///
/// CRLF, not CNL (`CSI n E`): a cursor move stops at the last visible
/// row, so a band that sits on the screen's bottom reserves NOTHING when
/// it grows and the rows the app asked for land on rows it does not own.
/// LF on that row scrolls instead, the one motion a terminal answers
/// with rows: the screen gives up its top rows into scrollback and the
/// committed transcript above the band goes there with them.
pub fn appendLines(w: anytype, n: u16) !void {
    var left = n;
    while (left > 0) : (left -= 1) try w.writeAll("\r\n");
}

/// Turns autowrap off, so a frame that writes into the last column cannot
/// defer-wrap and scroll the band it is painting.
pub fn autowrapOff(w: anytype) !void {
    try w.writeAll(autowrap_off);
}

/// Turns autowrap back on; a frame that turned it off must restore it.
pub fn autowrapOn(w: anytype) !void {
    try w.writeAll(autowrap_on);
}

/// Queries the cursor position; the reply arrives as `Event.cpr`.
pub fn queryCursor(w: anytype) !void {
    try w.writeAll(csi ++ "6n");
}

/// Start synchronized output (CSI ?2026h).
pub fn beginSync(w: anytype) !void {
    try w.writeAll(sync_start);
}

/// End synchronized output (CSI ?2026l).
pub fn endSync(w: anytype) !void {
    try w.writeAll(sync_end);
}

/// Emit SGR for `s` as a truecolor terminal renders it, with no downsampling.
/// See `writeStyleProfile` for what is emitted and when.
pub fn writeStyle(w: anytype, s: Style) !void {
    try writeStyleProfile(w, s, .truecolor);
}

/// Emit SGR for `s`, narrowing `.rgb` colours to what `profile` can show.
///
/// Under `.truecolor` an `.rgb` colour is written as `38;2;r;g;b` /
/// `48;2;r;g;b`; under `.ansi256` it is downsampled to the nearest palette
/// index and written as `38;5;N` / `48;5;N`; under `.ansi` it maps to the
/// nearest `AnsiColor`. An `.ansi` or `.ansi256` colour is written unchanged
/// under every profile, and `.default` writes nothing — so a style with
/// nothing to write emits `CSI 0m`.
///
/// `Style.hyperlink` is not emitted: this package writes no OSC 8.
///
/// A writer error leaves a partial SGR sequence on the wire.
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
        try w.writeAll(csi);
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

test "emit: cursor visibility" {
    var t: TestWriter = .{};
    t.init();
    try hideCursor(&t.w);
    try std.testing.expectEqualStrings("\x1b[?25l", t.w.buffered());

    var t2: TestWriter = .{};
    t2.init();
    try showCursor(&t2.w);
    try std.testing.expectEqualStrings("\x1b[?25h", t2.w.buffered());
}

test "emit: erasure" {
    var t: TestWriter = .{};
    t.init();
    try eraseToEnd(&t.w);
    try std.testing.expectEqualStrings("\x1b[J", t.w.buffered());

    var t2: TestWriter = .{};
    t2.init();
    try eraseLine(&t2.w);
    try std.testing.expectEqualStrings("\x1b[K", t2.w.buffered());
}

test "emit: autowrap toggles" {
    var t: TestWriter = .{};
    t.init();
    try autowrapOff(&t.w);
    try autowrapOn(&t.w);
    try std.testing.expectEqualStrings("\x1b[?7l\x1b[?7h", t.w.buffered());
}

test "emit: sync wrap and CPR" {
    var t: TestWriter = .{};
    t.init();
    try beginSync(&t.w);
    try endSync(&t.w);
    try std.testing.expectEqualStrings("\x1b[?2026h\x1b[?2026l", t.w.buffered());

    var t2: TestWriter = .{};
    t2.init();
    try queryCursor(&t2.w);
    try std.testing.expectEqualStrings("\x1b[6n", t2.w.buffered());
}

test "emit: writeStyle attrs" {
    var t: TestWriter = .{};
    t.init();
    try writeStyle(&t.w, .{ .fg = .{ .ansi = .red }, .attrs = .{ .bold = true } });
    try std.testing.expectEqualStrings("\x1b[1;31m", t.w.buffered());

    var t2: TestWriter = .{};
    t2.init();
    try writeStyle(&t2.w, .{ .attrs = .{ .bold = true, .italic = true, .underline = true } });
    try std.testing.expectEqualStrings("\x1b[1;3;4m", t2.w.buffered());

    var t3: TestWriter = .{};
    t3.init();
    try writeStyle(&t3.w, .{ .attrs = .{ .dim = true, .strikethrough = true } });
    try std.testing.expectEqualStrings("\x1b[2;9m", t3.w.buffered());
}

test "emit: writeStyle colors on truecolor" {
    var t: TestWriter = .{};
    t.init();
    try writeStyle(&t.w, .{ .fg = .{ .rgb = .{ .r = 255, .g = 0, .b = 128 } } });
    try std.testing.expectEqualStrings("\x1b[38;2;255;0;128m", t.w.buffered());

    var t2: TestWriter = .{};
    t2.init();
    try writeStyle(&t2.w, .{ .bg = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } } });
    try std.testing.expectEqualStrings("\x1b[48;2;1;2;3m", t2.w.buffered());

    var t3: TestWriter = .{};
    t3.init();
    try writeStyle(&t3.w, .{ .fg = .{ .ansi = .bright_cyan } });
    try std.testing.expectEqualStrings("\x1b[96m", t3.w.buffered());

    var t4: TestWriter = .{};
    t4.init();
    try writeStyle(&t4.w, .{ .bg = .{ .ansi = .red } });
    try std.testing.expectEqualStrings("\x1b[41m", t4.w.buffered());

    var t5: TestWriter = .{};
    t5.init();
    try writeStyle(&t5.w, .{ .fg = .{ .ansi256 = 200 } });
    try std.testing.expectEqualStrings("\x1b[38;5;200m", t5.w.buffered());
}

test "emit: writeStyle profile gating" {
    // rgb on ansi256 profile downsamples to the nearest palette index.
    var t: TestWriter = .{};
    t.init();
    try writeStyleProfile(&t.w, .{ .fg = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } } }, .ansi256);
    try std.testing.expectEqualStrings("\x1b[38;5;196m", t.w.buffered());

    var t2: TestWriter = .{};
    t2.init();
    try writeStyleProfile(&t2.w, .{ .bg = .{ .rgb = .{ .r = 0, .g = 0, .b = 0 } } }, .ansi256);
    try std.testing.expectEqualStrings("\x1b[48;5;16m", t2.w.buffered());

    // rgb on ansi profile maps to the nearest base color.
    var t3: TestWriter = .{};
    t3.init();
    try writeStyleProfile(&t3.w, .{ .fg = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } } }, .ansi);
    try std.testing.expectEqualStrings("\x1b[91m", t3.w.buffered());

    var t4: TestWriter = .{};
    t4.init();
    try writeStyleProfile(&t4.w, .{ .bg = .{ .rgb = .{ .r = 0, .g = 0, .b = 0 } } }, .ansi);
    try std.testing.expectEqualStrings("\x1b[40m", t4.w.buffered());

    // Explicit ansi/ansi256 colors pass through unchanged on any profile.
    var t5: TestWriter = .{};
    t5.init();
    try writeStyleProfile(&t5.w, .{ .fg = .{ .ansi = .red }, .bg = .{ .ansi256 = 21 } }, .ansi);
    try std.testing.expectEqualStrings("\x1b[31;48;5;21m", t5.w.buffered());

    // writeStyle defaults to the truecolor profile.
    var t6: TestWriter = .{};
    t6.init();
    try writeStyle(&t6.w, .{ .fg = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } } });
    try std.testing.expectEqualStrings("\x1b[38;2;255;0;0m", t6.w.buffered());
}

test "emit: writeStyle empty resets" {
    var t: TestWriter = .{};
    t.init();
    try writeStyle(&t.w, .{});
    try std.testing.expectEqualStrings("\x1b[0m", t.w.buffered());

    // Explicit .default colors are not emitted either.
    var t2: TestWriter = .{};
    t2.init();
    try writeStyle(&t2.w, .{ .fg = .default, .bg = .default });
    try std.testing.expectEqualStrings("\x1b[0m", t2.w.buffered());

    // Hyperlinks are not emitted (OSC 8 deferred).
    var t3: TestWriter = .{};
    t3.init();
    try writeStyle(&t3.w, .{ .hyperlink = "https://example.com" });
    try std.testing.expectEqualStrings("\x1b[0m", t3.w.buffered());
}

test "emit: writeStyle combined sequence" {
    var t: TestWriter = .{};
    t.init();
    try writeStyle(&t.w, .{
        .fg = .{ .ansi256 = 200 },
        .bg = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
        .attrs = .{
            .bold = true,
            .dim = true,
            .italic = true,
            .underline = true,
            .blink = true,
            .reverse = true,
            .strikethrough = true,
        },
    });
    try std.testing.expectEqualStrings("\x1b[1;2;3;4;5;7;9;38;5;200;48;2;1;2;3m", t.w.buffered());
}
