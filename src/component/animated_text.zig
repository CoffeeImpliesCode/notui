//! AnimatedText: a frame-cycling and/or color-breathing text component
//! (baseui-contract.md §4.3). Superset of Text: a single frame with no
//! gradient behaves exactly as a styled static string. Used for
//! marquee / pulsing word / blinking status. The color pulse
//! interpolates `style.fg` between `gradient_a` and `gradient_b` over
//! `gradient_period` with a sine wave (t in 0..1), merged over `style`.

const std = @import("std");
const Buffer = @import("../buffer.zig").Buffer;
const Style = @import("../style.zig").Style;
const Color = @import("../color.zig").Color;
const Clock = @import("component.zig").Clock;
const elapsedSince = @import("component.zig").elapsedSince;

pub const AnimatedText = struct {
    /// Cycling frames; empty => draw `text` (color-only animation).
    frames: []const []const u8 = &.{},
    /// Static text drawn when `frames` is empty.
    text: []const u8 = "",
    /// Nanoseconds per frame.
    interval: u64 = 200 * std.time.ns_per_ms,
    style: Style = .{},
    /// When both are set, the fg color breathes between them.
    gradient_a: ?Color = null,
    gradient_b: ?Color = null,
    /// Nanoseconds per full gradient cycle.
    gradient_period: u64 = 2 * std.time.ns_per_s,
    // state
    frame_index: usize = 0,
    last_advance: ?Clock = null,
    phase_ns: u64 = 0, // accumulated time for the gradient phase

    /// Advance the frame (time-gated, like Spinner) and always
    /// accumulate the gradient phase. Returns true only when the frame
    /// index moved.
    pub fn advance(self: *AnimatedText, now: Clock) bool {
        const elapsed = elapsedSince(now, self.last_advance, self.interval) orelse {
            // First call: anchor the clock. Before the interval:
            // accumulate, do NOT re-anchor.
            if (self.last_advance == null) self.last_advance = now;
            return false;
        };
        // The color breathes continuously — even with a single frame.
        self.phase_ns +%= elapsed;
        if (self.frames.len <= 1) {
            // Static frame: re-anchor so the next call measures a fresh
            // delta (avoids double-counting elapsed).
            self.last_advance = now;
            return false;
        }
        const n = elapsed / self.interval;
        self.frame_index = (self.frame_index + n) % self.frames.len;
        self.last_advance = now;
        return n > 0;
    }

    /// Advance to `now`, then draw the current frame (or `text` when
    /// `frames` is empty) with the effective style. Returns the columns
    /// consumed; never errors for width.
    pub fn draw(self: *AnimatedText, buf: *Buffer, x: u16, y: u16, now: Clock) !u16 {
        _ = self.advance(now);
        const avail: u16 = buf.width -| x;
        if (avail == 0 or y >= buf.height) return 0;

        var effective = self.style;
        if (self.gradient_a != null and self.gradient_b != null) {
            const period: f64 = @floatFromInt(@max(self.gradient_period, 1));
            const phase: f64 = @floatFromInt(self.phase_ns);
            const t = 0.5 * (1.0 + std.math.sin(2.0 * std.math.pi * phase / period));
            effective = (Style{ .fg = Color.interpolate(self.gradient_a.?, self.gradient_b.?, t) }).merge(self.style);
        }

        const frame: ?[]const u8 = if (self.frames.len > 0)
            self.frames[self.frame_index % self.frames.len]
        else if (self.text.len > 0)
            self.text
        else
            null;
        const s = frame orelse return 0;
        return buf.draw(effective, s, x, y);
    }
};

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
const ns = std.time.ns_per_ms;

test "animated_text: phase accumulates even with a single frame" {
    var a: AnimatedText = .{ .frames = &.{"x"}, .interval = 100 * ns };
    const t0: Clock = .fromNanoseconds(0);
    try std.testing.expect(!a.advance(t0)); // anchor
    try std.testing.expect(!a.advance(.fromNanoseconds(250 * ns))); // frame static
    try std.testing.expectEqual(@as(u64, 250 * ns), a.phase_ns);
    try std.testing.expectEqual(@as(usize, 0), a.frame_index);
    // Accumulation is a fresh delta per call, not a growing total.
    try std.testing.expect(!a.advance(.fromNanoseconds(350 * ns)));
    try std.testing.expectEqual(@as(u64, 350 * ns), a.phase_ns);
}

test "animated_text: frame_index wraps and advance reports change" {
    var a: AnimatedText = .{ .frames = &.{ "a", "b" }, .interval = 100 * ns };
    const t0: Clock = .fromNanoseconds(0);
    _ = a.advance(t0);
    try std.testing.expect(a.advance(.fromNanoseconds(250 * ns)));
    try std.testing.expectEqual(@as(usize, 0), a.frame_index); // (0 + 2) % 2
    try std.testing.expect(!a.advance(.fromNanoseconds(250 * ns))); // idempotent
    try std.testing.expect(a.advance(.fromNanoseconds(350 * ns)));
    try std.testing.expectEqual(@as(usize, 1), a.frame_index); // (0 + 1) % 2
}

test "animated_text: gradient t maps phase to colors" {
    const black: Color = .{ .rgb = .{ .r = 0, .g = 0, .b = 0 } };
    const white: Color = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } };
    var buf = try Buffer.init(test_alloc, 4, 1);
    defer buf.deinit();

    // phase = period/4 -> t = 1 -> gradient_b
    var a1: AnimatedText = .{ .text = "x", .gradient_a = black, .gradient_b = white, .gradient_period = 1000 };
    a1.phase_ns = 250;
    a1.last_advance = .fromNanoseconds(0);
    _ = try a1.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expect(buf.get(0, 0).style.fg.?.eql(white));

    // phase = 3*period/4 -> t = 0 -> gradient_a
    var a2: AnimatedText = .{ .text = "x", .gradient_a = black, .gradient_b = white, .gradient_period = 1000 };
    a2.phase_ns = 750;
    a2.last_advance = .fromNanoseconds(0);
    _ = try a2.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expect(buf.get(0, 0).style.fg.?.eql(black));

    // phase = period/2 -> t = 0.5 -> exact midpoint
    var a3: AnimatedText = .{ .text = "x", .gradient_a = black, .gradient_b = white, .gradient_period = 1000 };
    a3.phase_ns = 500;
    a3.last_advance = .fromNanoseconds(0);
    _ = try a3.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expect(buf.get(0, 0).style.fg.?.eql(.{ .rgb = .{ .r = 127, .g = 127, .b = 127 } }));
}

test "animated_text: single frame draws like styled text" {
    var a: AnimatedText = .{ .frames = &.{"hi"}, .style = .{ .fg = .{ .ansi = .red } } };
    var buf = try Buffer.init(test_alloc, 4, 1);
    defer buf.deinit();
    const consumed = try a.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 2), consumed);
    try std.testing.expect(buf.get(0, 0).style.fg.?.eql(.{ .ansi = .red }));

    var tw: TestWriter = .{};
    tw.init();
    try buf.renderAll(&tw.w);
    try std.testing.expectEqualStrings("\r\x1b[K\x1b[31mhi\x1b[0m", tw.w.buffered());
}

test "animated_text: text fallback when frames empty" {
    var a: AnimatedText = .{ .text = "breathing" };
    var buf = try Buffer.init(test_alloc, 10, 1);
    defer buf.deinit();
    const consumed = try a.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 9), consumed);
    try std.testing.expectEqualStrings("b", buf.get(0, 0).grapheme);
}

test "animated_text: nothing drawn when frames and text are empty" {
    var a: AnimatedText = .{};
    var buf = try Buffer.init(test_alloc, 4, 1);
    defer buf.deinit();
    try std.testing.expectEqual(@as(u16, 0), try a.draw(&buf, 0, 0, .fromNanoseconds(0)));
    try std.testing.expect(buf.get(0, 0).eql(.{}));
}
