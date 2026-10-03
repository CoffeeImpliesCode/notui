//! AnimatedText: a frame-cycling and/or colour-breathing text
//! component, a superset of a styled static string — one frame with no
//! gradient draws exactly like plain styled text. It suits a marquee, a
//! pulsing word or a blinking status label.
//!
//! The colour pulse interpolates `style.fg` between `gradient_a` and
//! `gradient_b` over `gradient_period` along a sine, merged over
//! `style`. Everything drawn is borrowed from `frames`/`text`, so the
//! component allocates nothing and emits no ANSI.

const std = @import("std");
const Buffer = @import("../buffer.zig").Buffer;
const Style = @import("../style.zig").Style;
const Color = @import("../color.zig").Color;
const Clock = @import("component.zig").Clock;
const elapsedSince = @import("component.zig").elapsedSince;

/// Animation state for a frame table and a colour pulse: the current
/// frame, the clock the last advance measured from, and the accumulated
/// gradient phase. `draw` advances first, so one call per frame is
/// enough; `advance` alone reports whether an interval elapsed, which
/// a frame cycle uses to skip a re-render.
pub const AnimatedText = struct {
    /// Frames to cycle, BORROWED (never freed, never copied): the drawn
    /// cell keeps the current frame's bytes, so they must outlive the
    /// buffer that shows them. Empty means `text` only.
    frames: []const []const u8 = &.{},
    /// Static text drawn when `frames` is empty; borrowed like `frames`.
    text: []const u8 = "",
    /// Nanoseconds per frame; 200 ms by default. Zero is treated as 1 ns.
    interval: u64 = 200 * std.time.ns_per_ms,
    /// Base style; the pulse colour is merged over it, so attributes
    /// set here survive the animation.
    style: Style = .{},
    /// When both are set, the foreground breathes between them along a
    /// sine; either one alone leaves the colour alone.
    gradient_a: ?Color = null,
    gradient_b: ?Color = null,
    /// Nanoseconds per full gradient cycle; 0 is treated as 1ns.
    gradient_period: u64 = 2 * std.time.ns_per_s,
    /// Index into `frames`, wrapped by `advance`.
    frame_index: usize = 0,
    /// Clock of the last advance; null until the first `advance` anchors
    /// it. Never re-anchored while the interval has not elapsed, so
    /// elapsed time keeps accumulating.
    last_advance: ?Clock = null,
    /// Gradient phase accumulated from elapsed time, wrapping modulo
    /// 2^64; the sine reads it as a fraction of `gradient_period`.
    phase_ns: u64 = 0,

    /// Advance the frame (time-gated, like Spinner) and always
    /// accumulate the gradient phase. With more than one frame, returns
    /// true once an interval has elapsed: a whole number of cycles
    /// counts too, even though it leaves the index where it started. A
    /// static frame or `text` still breathes, but always returns false.
    pub fn advance(self: *AnimatedText, now: Clock) bool {
        const interval = @max(self.interval, 1);
        const elapsed = elapsedSince(now, self.last_advance, interval) orelse {
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
        const n = elapsed / interval;
        // A long stall makes `frame_index + n` exceed u64, so add with a
        // carry and fall back to the exact 128-bit sum only then; the
        // hot path stays one 64-bit add and one modulus.
        const sum, const carried = @addWithOverflow(@as(u64, self.frame_index), n);
        // `len` is u64 so the hot path stays a 64-bit modulus; each arm
        // is usize, so LLVM cannot widen it to the 128-bit fallback.
        const len: u64 = self.frames.len; // ≥ 2, never a divide by zero
        self.frame_index = if (carried == 0)
            @intCast(sum % len)
        else
            @intCast((@as(u128, self.frame_index) + n) % len);
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

test "animated_text: zero interval advances and draws on the next nanosecond" {
    var text: AnimatedText = .{ .frames = &.{ "a", "b" }, .interval = 0 };
    var buf = try Buffer.init(std.testing.allocator, 1, 1);
    defer buf.deinit();
    _ = try text.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqualStrings("a", buf.get(0, 0).grapheme);
    _ = try text.draw(&buf, 0, 0, .fromNanoseconds(1));
    try std.testing.expectEqualStrings("b", buf.get(0, 0).grapheme);
    try std.testing.expect(!text.advance(.fromNanoseconds(1)));
}

test "animated_text: maximal elapsed time keeps the modular frame" {
    var text: AnimatedText = .{ .frames = &.{ "a", "b", "c" }, .interval = 0 };
    var buf = try Buffer.init(std.testing.allocator, 1, 1);
    defer buf.deinit();
    _ = try text.draw(&buf, 0, 0, .fromNanoseconds(0));
    _ = try text.draw(&buf, 0, 0, .fromNanoseconds(1));
    _ = try text.draw(&buf, 0, 0, .fromNanoseconds(@as(i96, 1) << 64));
    try std.testing.expectEqualStrings("b", buf.get(0, 0).grapheme);
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
