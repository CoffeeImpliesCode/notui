//! Gauge: a fractional block-bar meter with thresholds and an optional
//! label + percent suffix (baseui-improvements.md §2.2). The fill is
//! `width` cells of eighth-block steps (`blocks`), so partial fills
//! render as smooth fractional cells instead of integer char cells.
//! Thresholds recolor the fill; a per-cell gradient overrides them.
//! Static — `advance` is always false; the app drives `value`.

const std = @import("std");
const Buffer = @import("../buffer.zig").Buffer;
const Style = @import("../style.zig").Style;
const Color = @import("../color.zig").Color;
const Width = @import("../width.zig");
const Clock = @import("component.zig").Clock;

pub const Gauge = struct {
    value: f64 = 0,
    min: f64 = 0,
    max: f64 = 100,
    /// Bar length in cells.
    width: u16 = 40,
    /// Optional prefix "label " before the bar (styled with label_style).
    label: ?[]const u8 = null,
    label_style: Style = .{},
    /// Draw a " 42%" suffix after the bar.
    show_percent: bool = true,
    percent_style: ?Style = null, // null => default Style
    full_style: Style = .{ .fg = .{ .ansi = .green } },
    empty_style: Style = .{ .fg = .{ .ansi256 = 245 } },
    /// Thresholds: the LAST with value <= self.value wins.
    thresholds: []const Threshold = &.{},
    /// When both set, per-cell fill gradient (overrides threshold fg).
    gradient_a: ?Color = null,
    gradient_b: ?Color = null,
    /// Scratch for the percent suffix (cells borrow it), like Progress.
    percent_buf: [8]u8 = undefined,

    pub const Threshold = struct { value: f64, color: Color };

    /// Fractional block fill chars, least to most filled: index i is
    /// (i+1)/8 of a full cell.
    pub const blocks = [_][]const u8{ "▏", "▎", "▍", "▌", "▋", "▊", "▉" };

    /// Gauges never animate; `advance` is always false.
    pub fn advance(self: *Gauge, now: Clock) bool {
        _ = self;
        _ = now;
        return false;
    }

    /// Fill ratio clamped to 0..1; `max <= min` yields 0.
    pub fn ratio(self: *const Gauge) f64 {
        if (self.max <= self.min) return 0;
        return clamp01((self.value - self.min) / (self.max - self.min));
    }

    /// Draw the gauge at (x, y): an optional "label " prefix, the
    /// block bar, and an optional " 42%" suffix. Truncates to
    /// `buf.width - x` (Buffer.draw drops over-wide glyphs). Returns
    /// the columns consumed; never errors for width; never allocates.
    pub fn draw(self: *Gauge, buf: *Buffer, x: u16, y: u16, now: Clock) !u16 {
        _ = self.advance(now);
        const avail: u16 = buf.width -| x;
        if (avail == 0 or y >= buf.height) return 0;
        var consumed: u16 = 0;

        if (self.label) |l| {
            consumed +|= try buf.draw(self.label_style, l, x + consumed, y);
            consumed +|= try buf.draw(self.label_style, " ", x + consumed, y);
        }

        // Threshold color: the last threshold with value <= self.value
        // wins; the gradient (when set) overrides the fg per filled
        // cell below.
        var fill = self.full_style;
        for (self.thresholds) |t| {
            if (self.value >= t.value) fill.fg = t.color;
        }

        const r = self.ratio();
        const total_units: usize = @as(usize, self.width) * 8;
        const filled_units: usize = @intFromFloat(@round(r * @as(f64, @floatFromInt(total_units))));
        const full_cells: usize = filled_units / 8;
        const partial: usize = filled_units % 8;

        const bar_cells: u16 = @min(self.width, avail -| consumed);
        const filled_visible: usize = @min(full_cells + @intFromBool(partial > 0), @as(usize, bar_cells));
        const bar_x: u16 = x + consumed;

        var col: u16 = 0;
        while (col < bar_cells) : (col += 1) {
            const ci: usize = col;
            if (ci < full_cells or (ci == full_cells and partial > 0)) {
                // Full cells use the block char; the fill edge uses the
                // matching fractional block when not cell-aligned.
                const ch = if (ci < full_cells) "█" else blocks[partial - 1];
                var cell_style = fill;
                if (self.gradient_a != null and self.gradient_b != null) {
                    const t = @as(f64, @floatFromInt(ci)) /
                        @as(f64, @floatFromInt(@max(@as(usize, 1), filled_visible - 1)));
                    cell_style.fg = Color.interpolate(self.gradient_a.?, self.gradient_b.?, t);
                }
                consumed +|= try buf.draw(cell_style, ch, bar_x + col, y);
            } else {
                consumed +|= try buf.draw(self.empty_style, "░", bar_x + col, y);
            }
        }

        // Percent suffix, truncated to avail by Buffer.draw. The string
        // is formatted into the component-owned `percent_buf` because
        // cells borrow their graphemes (no allocation, stable lifetime).
        if (self.show_percent) {
            const pct = try std.fmt.bufPrint(&self.percent_buf, " {d:.0}%", .{r * 100.0});
            const pstyle = self.percent_style orelse Style{};
            consumed +|= try buf.draw(pstyle, pct, x + consumed, y);
        }
        return consumed;
    }

    /// Set the value, clamped to [min, max].
    pub fn setValue(self: *Gauge, value: f64) void {
        self.value = @max(self.min, @min(value, self.max));
    }

    /// Set the minimum.
    pub fn setMin(self: *Gauge, min: f64) void {
        self.min = min;
    }

    /// Set the maximum.
    pub fn setMax(self: *Gauge, max: f64) void {
        self.max = max;
    }

    /// Set the bar length in cells.
    pub fn setWidth(self: *Gauge, width: u16) void {
        self.width = width;
    }
};

fn clamp01(x: f64) f64 {
    return @max(0, @min(1, x));
}

test {
    std.testing.refAllDecls(@This());
}

/// Concatenate one row exactly as the Region's plain painter writes it
/// (spaces for blank cells, graphemes verbatim, no styles) — the
/// non-TTY frame a pipe sees.
fn plainRow(buf: *const Buffer, y: usize, out: []u8) []const u8 {
    var n: usize = 0;
    var x: usize = 0;
    while (x < buf.width) : (x += 1) {
        const cell = buf.get(@intCast(x), @intCast(y));
        if (cell.wide) continue; // covered by the lead's column
        if (cell.grapheme.len == 0 or cell.eql(.{})) {
            out[n] = ' ';
            n += 1;
            continue;
        }
        const wg = Width.graphemeWidth(cell.grapheme);
        const wcell: usize = if (wg >= 2) 2 else 1;
        if (x + wcell > buf.width) { // over-wide at the edge: reserve the column
            out[n] = ' ';
            n += 1;
            continue;
        }
        @memcpy(out[n..][0..cell.grapheme.len], cell.grapheme);
        n += cell.grapheme.len;
        x += wcell - 1;
    }
    return out[0..n];
}

const test_alloc = std.testing.allocator;

test "gauge: fractional partial block sits at the fill edge" {
    var g: Gauge = .{ .value = 37.5, .width = 4, .show_percent = false };
    // ratio 0.375 -> 12 units -> 1 full cell + 4/8 partial (blocks[3]).
    var buf = try Buffer.init(test_alloc, 4, 1);
    defer buf.deinit();
    const consumed = try g.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 4), consumed);
    try std.testing.expectEqualStrings("█", buf.get(0, 0).grapheme);
    try std.testing.expectEqualStrings("▌", buf.get(1, 0).grapheme);
    try std.testing.expectEqualStrings("░", buf.get(2, 0).grapheme);
    try std.testing.expectEqualStrings("░", buf.get(3, 0).grapheme);
}

test "gauge: cell-aligned fill uses full blocks only" {
    var g: Gauge = .{ .value = 50, .width = 4, .show_percent = false };
    // ratio 0.5 -> 16 units -> exactly 2 full cells.
    var buf = try Buffer.init(test_alloc, 4, 1);
    defer buf.deinit();
    _ = try g.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqualStrings("█", buf.get(1, 0).grapheme);
    try std.testing.expectEqualStrings("░", buf.get(2, 0).grapheme);
}

test "gauge: threshold color switches the fill; last match wins" {
    var g: Gauge = .{
        .value = 60,
        .width = 4,
        .show_percent = false,
        .thresholds = &.{
            .{ .value = 50, .color = .{ .ansi = .yellow } },
            .{ .value = 85, .color = .{ .ansi = .red } },
        },
    };
    var buf = try Buffer.init(test_alloc, 4, 1);
    defer buf.deinit();
    _ = try g.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expect(buf.get(0, 0).style.fg.?.eql(.{ .ansi = .yellow }));

    // Past the second threshold: the LAST match wins (red, not yellow).
    g.value = 90;
    buf.clear();
    _ = try g.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expect(buf.get(0, 0).style.fg.?.eql(.{ .ansi = .red }));

    // Below every threshold: the default full style.
    g.value = 10;
    buf.clear();
    _ = try g.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expect(buf.get(0, 0).style.fg.?.eql(.{ .ansi = .green }));
}

test "gauge: ratio clamps" {
    var g: Gauge = .{ .value = 200, .max = 100 };
    try std.testing.expectEqual(@as(f64, 1), g.ratio());
    g.value = -5;
    try std.testing.expectEqual(@as(f64, 0), g.ratio());
    g = .{ .value = 10, .min = 20, .max = 5 };
    try std.testing.expectEqual(@as(f64, 0), g.ratio()); // max <= min
}

test "gauge: label and percent suffix" {
    var g: Gauge = .{
        .value = 50,
        .width = 2,
        .label = "scan",
        .label_style = .{ .fg = .{ .ansi = .blue } },
        .percent_style = .{},
    };
    var buf = try Buffer.init(test_alloc, 12, 1);
    defer buf.deinit();
    const consumed = try g.draw(&buf, 0, 0, .fromNanoseconds(0));
    // "scan" + " " + "█░" + " 50%" = 4 + 1 + 2 + 4.
    try std.testing.expectEqual(@as(u16, 11), consumed);
    try std.testing.expectEqualStrings("s", buf.get(0, 0).grapheme);
    try std.testing.expect(buf.get(0, 0).style.fg.?.eql(.{ .ansi = .blue }));
    try std.testing.expectEqualStrings("█", buf.get(5, 0).grapheme); // bar after "scan "
    try std.testing.expectEqualStrings("%", buf.get(10, 0).grapheme);

    g.show_percent = false;
    buf.clear();
    const c2 = try g.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 7), c2); // "scan █░"
}

test "gauge: width truncation caps at the buffer edge" {
    var g: Gauge = .{ .value = 50, .width = 40, .percent_style = .{} };
    var buf = try Buffer.init(test_alloc, 6, 1);
    defer buf.deinit();
    const consumed = try g.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 6), consumed); // bar capped, percent dropped
    for (0..6) |i| {
        try std.testing.expectEqualStrings("█", buf.get(@intCast(i), 0).grapheme);
    }
}

test "gauge: per-cell fill gradient" {
    const black: Color = .{ .rgb = .{ .r = 0, .g = 0, .b = 0 } };
    const white: Color = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } };
    var g: Gauge = .{ .value = 100, .width = 5, .show_percent = false, .gradient_a = black, .gradient_b = white };
    var buf = try Buffer.init(test_alloc, 5, 1);
    defer buf.deinit();
    _ = try g.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expect(buf.get(0, 0).style.fg.?.eql(black)); // t = 0
    try std.testing.expect(buf.get(4, 0).style.fg.?.eql(white)); // t = 1
}

test "gauge: default-style render is escape-free (plain frame)" {
    var g: Gauge = .{ .value = 50, .width = 4, .label = "scan" };
    var buf = try Buffer.init(test_alloc, 14, 1);
    defer buf.deinit();
    _ = try g.draw(&buf, 0, 0, .fromNanoseconds(0));
    // Rebuild the row exactly as the Region's plain painter writes it
    // (spaces for blank cells, graphemes verbatim, no styles) — the
    // piped frame must carry no escapes.
    var rowbuf: [64]u8 = undefined;
    const row = plainRow(&buf, 0, &rowbuf);
    try std.testing.expectEqualStrings("scan ██░░ 50% ", row);
    try std.testing.expect(std.mem.indexOfScalar(u8, row, 0x1b) == null);
}

test "gauge: draw never allocates (FailingAllocator guard)" {
    var failing = std.testing.FailingAllocator.init(test_alloc, .{ .fail_index = 1 });
    const alloc = failing.allocator();
    // Allocation 0 backs the buffer; any allocation during `draw`
    // would be allocation 1 and trip the guard with OutOfMemory.
    var g: Gauge = .{ .value = 37.5, .width = 4, .label = "scan", .percent_style = .{} };
    var buf = try Buffer.init(alloc, 12, 1);
    defer buf.deinit();
    _ = try g.draw(&buf, 0, 0, .fromNanoseconds(0)); // must not fail
}

test "gauge: advance is always false and helpers clamp" {
    var g: Gauge = .{};
    try std.testing.expect(!g.advance(.fromNanoseconds(0)));

    g.setValue(150); // clamps to max
    try std.testing.expectEqual(@as(f64, 100), g.value);
    g.setValue(-5); // clamps to min
    try std.testing.expectEqual(@as(f64, 0), g.value);

    g.setMin(10);
    g.setMax(50);
    g.setValue(100);
    try std.testing.expectEqual(@as(f64, 50), g.value);

    g.setWidth(12);
    try std.testing.expectEqual(@as(u16, 12), g.width);
}
