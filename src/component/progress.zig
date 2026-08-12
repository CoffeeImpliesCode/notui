//! Progress: a ratio bar with styled fill/empty segments, an optional
//! per-cell fill gradient, and an optional percent suffix
//! (baseui-contract.md §4.4). Static — `advance` is always false.

const std = @import("std");
const Buffer = @import("../buffer.zig").Buffer;
const Style = @import("../style.zig").Style;
const Color = @import("../color.zig").Color;
const Clock = @import("component.zig").Clock;

pub const Progress = struct {
    value: f64 = 0,
    total: f64 = 100,
    /// Bar length in cells.
    width: u16 = 40,
    full_char: []const u8 = "█",
    empty_char: []const u8 = "░",
    /// Char at the fill edge when the bar is partially filled.
    head_char: ?[]const u8 = null,
    full_style: Style = .{ .fg = .{ .ansi = .cyan } },
    empty_style: Style = .{ .fg = .{ .ansi256 = 245 } },
    /// Styled " 42%" suffix; null => no percent.
    percent_style: ?Style = null,
    /// When both are set, the filled cells get a per-cell gradient
    /// (interpolateColor over the fill range).
    gradient_a: ?Color = null,
    gradient_b: ?Color = null,
    /// Scratch for the percent suffix: `draw` formats into this field
    /// and the cells borrow it, so the component must not move between
    /// `draw` and the buffer render (same pattern as Text.scratch).
    percent_buf: [8]u8 = undefined,

    /// Progress never animates.
    pub fn advance(self: *Progress, now: Clock) bool {
        _ = self;
        _ = now;
        return false;
    }

    /// Draw the bar at (x, y), truncating to `buf.width - x`. Returns
    /// the columns consumed (bar + optional percent suffix); never
    /// errors for width.
    pub fn draw(self: *Progress, buf: *Buffer, x: u16, y: u16, now: Clock) !u16 {
        _ = self.advance(now);
        const avail: u16 = buf.width -| x;
        if (avail == 0 or y >= buf.height) return 0;

        const ratio = if (self.total > 0) clamp01(self.value / self.total) else 0;
        const filled_all: usize = @intFromFloat(@floor(ratio * @as(f64, @floatFromInt(self.width))));
        const bar_cells: u16 = @min(self.width, avail);
        const filled: u16 = @intCast(@min(filled_all, @as(usize, bar_cells)));
        const empty: u16 = bar_cells - filled;
        var consumed: u16 = 0;

        // Filled portion; the last filled cell is the head char when
        // the bar is not full (zigzag progress.zig:119-121).
        var col: u16 = 0;
        while (col < filled) : (col += 1) {
            const ch = if (self.head_char != null and col == filled - 1 and empty > 0)
                self.head_char.?
            else
                self.full_char;
            var cell_style = self.full_style;
            if (self.gradient_a != null and self.gradient_b != null) {
                const t = @as(f64, @floatFromInt(col)) /
                    @as(f64, @floatFromInt(@max(@as(usize, 1), filled - 1)));
                cell_style.fg = Color.interpolate(self.gradient_a.?, self.gradient_b.?, t);
            }
            consumed +|= try buf.draw(cell_style, ch, x + col, y);
        }

        // Empty portion.
        while (col < bar_cells) : (col += 1) {
            consumed +|= try buf.draw(self.empty_style, self.empty_char, x + col, y);
        }

        // Percent suffix, truncated to avail by Buffer.draw. The string
        // is formatted into the component-owned `percent_buf` because
        // cells borrow their graphemes (no allocation, stable lifetime).
        if (self.percent_style) |pstyle| {
            const pct = try std.fmt.bufPrint(&self.percent_buf, " {d:.0}%", .{ratio * 100.0});
            consumed +|= try buf.draw(pstyle, pct, x + consumed, y);
        }
        return consumed;
    }

    /// Set progress value, clamped to [0, total] (zigzag progress.zig:98-101).
    pub fn setValue(self: *Progress, value: f64) void {
        self.value = @max(0, @min(value, self.total));
    }

    /// Set progress as a percentage (0-100).
    pub fn setPercent(self: *Progress, pct: f64) void {
        self.value = (pct / 100.0) * self.total;
    }

    /// Increment progress.
    pub fn increment(self: *Progress, amount: f64) void {
        self.setValue(self.value + amount);
    }

    /// Set the total.
    pub fn setTotal(self: *Progress, total: f64) void {
        self.total = total;
    }

    /// Set the bar length in cells.
    pub fn setWidth(self: *Progress, width: u16) void {
        self.width = width;
    }
};

fn clamp01(x: f64) f64 {
    return @max(0, @min(1, x));
}

test {
    std.testing.refAllDecls(@This());
}

/// Fixed-buffer writer for golden tests (same pattern as src/buffer.zig).
const TestWriter = struct {
    buf: [1024]u8 = undefined,
    w: std.Io.Writer = undefined,

    fn init(self: *TestWriter) void {
        self.w = .fixed(&self.buf);
    }
};

const test_alloc = std.testing.allocator;

test "progress: ratio fills cells, full and empty styles differ" {
    var p: Progress = .{ .value = 50, .width = 10 };
    var buf = try Buffer.init(test_alloc, 10, 1);
    defer buf.deinit();
    const consumed = try p.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 10), consumed);
    try std.testing.expectEqualStrings("█", buf.get(0, 0).grapheme);
    try std.testing.expect(buf.get(0, 0).style.fg.?.eql(.{ .ansi = .cyan }));
    try std.testing.expectEqualStrings("░", buf.get(9, 0).grapheme);
    try std.testing.expect(buf.get(9, 0).style.fg.?.eql(.{ .ansi256 = 245 }));

    var tw: TestWriter = .{};
    tw.init();
    try buf.renderAll(&tw.w);
    try std.testing.expectEqualStrings(
        "\r\x1b[K\x1b[36m█████\x1b[0m\x1b[38;5;245m░░░░░\x1b[0m",
        tw.w.buffered(),
    );
}

test "progress: head char sits at the fill edge" {
    var p: Progress = .{ .value = 50, .width = 10, .head_char = ">" };
    var buf = try Buffer.init(test_alloc, 10, 1);
    defer buf.deinit();
    _ = try p.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqualStrings("█", buf.get(3, 0).grapheme);
    try std.testing.expectEqualStrings(">", buf.get(4, 0).grapheme);
    try std.testing.expectEqualStrings("░", buf.get(5, 0).grapheme);
    // No head char when the bar is full.
    p.value = 100;
    _ = try p.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqualStrings("█", buf.get(9, 0).grapheme);
}

test "progress: ratio is clamped" {
    var p: Progress = .{ .value = 200, .width = 10 };
    var buf = try Buffer.init(test_alloc, 10, 1);
    defer buf.deinit();
    _ = try p.draw(&buf, 0, 0, .fromNanoseconds(0));
    for (0..10) |i| {
        try std.testing.expectEqualStrings("█", buf.get(@intCast(i), 0).grapheme);
    }

    p.value = -10;
    buf.clear();
    _ = try p.draw(&buf, 0, 0, .fromNanoseconds(0));
    for (0..10) |i| {
        try std.testing.expectEqualStrings("░", buf.get(@intCast(i), 0).grapheme);
    }
}

test "progress: total 0 renders all empty" {
    var p: Progress = .{ .total = 0, .value = 5, .width = 4 };
    var buf = try Buffer.init(test_alloc, 4, 1);
    defer buf.deinit();
    _ = try p.draw(&buf, 0, 0, .fromNanoseconds(0));
    for (0..4) |i| {
        try std.testing.expectEqualStrings("░", buf.get(@intCast(i), 0).grapheme);
    }
}

test "progress: bar truncates to avail" {
    var p: Progress = .{ .value = 50, .width = 40 };
    var buf = try Buffer.init(test_alloc, 6, 1);
    defer buf.deinit();
    const consumed = try p.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 6), consumed);
    // The visible window is entirely within the filled portion.
    for (0..6) |i| {
        try std.testing.expectEqualStrings("█", buf.get(@intCast(i), 0).grapheme);
    }
}

test "progress: percent suffix drawn after the bar" {
    var p: Progress = .{ .value = 50, .width = 2, .percent_style = .{} };
    var buf = try Buffer.init(test_alloc, 12, 1);
    defer buf.deinit();
    const consumed = try p.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 6), consumed); // "█░" + " 50%"
    try std.testing.expectEqualStrings(" ", buf.get(2, 0).grapheme);
    try std.testing.expectEqualStrings("5", buf.get(3, 0).grapheme);
    try std.testing.expectEqualStrings("%", buf.get(5, 0).grapheme);
}

test "progress: percent suffix truncates at the edge" {
    var p: Progress = .{ .value = 50, .width = 2, .percent_style = .{} };
    var buf = try Buffer.init(test_alloc, 4, 1);
    defer buf.deinit();
    const consumed = try p.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 4), consumed); // "█░ " + "5"
    try std.testing.expectEqualStrings("█", buf.get(0, 0).grapheme);
    try std.testing.expectEqualStrings("5", buf.get(3, 0).grapheme);
    try std.testing.expect(buf.get(3, 0).style.eql(.{})); // percent style applied
}

test "progress: per-cell fill gradient" {
    const black: Color = .{ .rgb = .{ .r = 0, .g = 0, .b = 0 } };
    const white: Color = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } };
    var p: Progress = .{ .value = 100, .width = 5, .gradient_a = black, .gradient_b = white };
    var buf = try Buffer.init(test_alloc, 5, 1);
    defer buf.deinit();
    _ = try p.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expect(buf.get(0, 0).style.fg.?.eql(black)); // t = 0
    try std.testing.expect(buf.get(2, 0).style.fg.?.eql(.{ .rgb = .{ .r = 127, .g = 127, .b = 127 } }));
    try std.testing.expect(buf.get(4, 0).style.fg.?.eql(white)); // t = 1
}

test "progress: advance is always false and helpers clamp" {
    var p: Progress = .{};
    try std.testing.expect(!p.advance(.fromNanoseconds(0)));

    p.setValue(150); // clamps to total
    try std.testing.expectEqual(@as(f64, 100), p.value);
    p.setValue(-5);
    try std.testing.expectEqual(@as(f64, 0), p.value);

    p.setPercent(50);
    try std.testing.expectEqual(@as(f64, 50), p.value);

    p.increment(10);
    try std.testing.expectEqual(@as(f64, 60), p.value);

    p.setTotal(200);
    try std.testing.expectEqual(@as(f64, 200), p.total);

    p.setWidth(12);
    try std.testing.expectEqual(@as(u16, 12), p.width);
}
