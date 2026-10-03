//! Spinner: a frame-cycling animation component. `draw` advances to
//! `now` and then paints one borrowed frame (plus an optional label
//! after a single space) into a `Buffer` at (x, y); it emits no ANSI
//! and allocates nothing, because the frames, the label and the space
//! are all caller-owned slices the drawn cells borrow.
//!
//! The animation is time-gated, not tick-counted: the frame index moves
//! by one per elapsed `interval`, so a frame that took twice as long
//! skips ahead instead of running slow, and the first `advance` only
//! anchors the clock (the first frame change lands one interval later).
//! Calling `advance` without drawing reports whether an interval
//! elapsed, which is what an app uses to skip a re-render.

const std = @import("std");
const Buffer = @import("../buffer.zig").Buffer;
const Style = @import("../style.zig").Style;
const Clock = @import("component.zig").Clock;
const elapsedSince = @import("component.zig").elapsedSince;

/// An animation state machine over a caller-owned frame table: which
/// frame is current, and when the clock last moved it. `draw` and
/// `advance` are the whole surface; neither emits ANSI nor allocates.
pub const Spinner = struct {
    /// Frames to cycle, BORROWED (never freed, never copied): the
    /// drawn cell borrows the current frame's bytes, so they must
    /// outlive the buffer that shows them. An empty table draws
    /// nothing.
    frames: []const []const u8 = &default_frames,
    /// Nanoseconds per frame; 100 ms by default. Zero is treated as 1 ns.
    interval: u64 = 100 * std.time.ns_per_ms,
    /// Style for the frame and (when set) the label.
    style: Style = .{ .fg = .{ .ansi = .cyan } },
    /// Optional trailing text drawn after a single space, styled with
    /// `style` and borrowed like `frames`; null draws the frame alone.
    label: ?[]const u8 = null,
    /// Index into `frames`, wrapped by `advance`.
    frame_index: usize = 0,
    /// Clock of the last advance that moved the frame; null until the
    /// first `advance` anchors it. Never re-anchored while the
    /// interval has not elapsed, so elapsed time keeps accumulating.
    last_advance: ?Clock = null,

    /// The braille spinner set `frames` defaults to.
    pub const default_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

    /// Alternative frame tables, one per spinner style (`line`, `dots`,
    /// `dots2`, … `pulse`); assign one to `frames`. Every table is a
    /// comptime constant, so passing one allocates nothing.
    pub const presets = struct {
        pub const line = &[_][]const u8{ "|", "/", "-", "\\" };
        pub const dots = &default_frames;
        pub const dots2 = &[_][]const u8{ "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" };
        pub const dots3 = &[_][]const u8{ "⠋", "⠙", "⠚", "⠞", "⠖", "⠦", "⠴", "⠲", "⠳", "⠓" };
        pub const globe = &[_][]const u8{ "🌍", "🌎", "🌏" };
        pub const moon = &[_][]const u8{ "🌑", "🌒", "🌓", "🌔", "🌕", "🌖", "🌗", "🌘" };
        pub const circle = &[_][]const u8{ "◐", "◓", "◑", "◒" };
        pub const square = &[_][]const u8{ "◰", "◳", "◲", "◱" };
        pub const arrow = &[_][]const u8{ "←", "↖", "↑", "↗", "→", "↘", "↓", "↙" };
        pub const bounce = &[_][]const u8{ "⠁", "⠂", "⠄", "⠂" };
        pub const box_bounce = &[_][]const u8{ "▖", "▘", "▝", "▗" };
        pub const triangle = &[_][]const u8{ "◢", "◣", "◤", "◥" };
        pub const arc = &[_][]const u8{ "◜", "◠", "◝", "◞", "◡", "◟" };
        pub const pipe = &[_][]const u8{ "┤", "┘", "┴", "└", "├", "┌", "┬", "┐" };
        pub const simple_dots = &[_][]const u8{ ".  ", ".. ", "...", " ..", "  .", "   " };
        pub const pulse = &[_][]const u8{ "█", "▓", "▒", "░", "▒", "▓" };
    };

    /// Advance `frame_index` by the count of elapsed intervals. With
    /// more than one frame, returns true once an interval has elapsed:
    /// a whole number of cycles counts too, even though it leaves the
    /// index where it started. One frame or none: always false.
    /// Idempotent per `now`.
    pub fn advance(self: *Spinner, now: Clock) bool {
        if (self.frames.len <= 1) return false;
        const interval = @max(self.interval, 1);
        const elapsed = elapsedSince(now, self.last_advance, interval) orelse {
            // First call: anchor the clock; the first frame lands one
            // interval later. Later calls before the interval: keep
            // accumulating, do NOT re-anchor.
            if (self.last_advance == null) self.last_advance = now;
            return false;
        };
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

    /// Advance to `now`, then draw the current frame (and optional
    /// label). Returns the columns consumed, capped at `buf.width - x`;
    /// never errors for width.
    pub fn draw(self: *Spinner, buf: *Buffer, x: u16, y: u16, now: Clock) !u16 {
        _ = self.advance(now);
        if (self.frames.len == 0) return 0;
        const avail: u16 = buf.width -| x;
        if (avail == 0 or y >= buf.height) return 0;

        const frame = self.frames[self.frame_index % self.frames.len];
        const fw = try buf.draw(self.style, frame, x, y);

        const label = self.label orelse return fw;
        if (fw >= avail) return fw;
        _ = try buf.draw(self.style, " ", x + fw, y);
        const lw = try buf.draw(self.style, label, x + fw + 1, y);
        return fw + 1 + lw;
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

test "spinner: advance is gated on the interval" {
    var s: Spinner = .{ .interval = 100 * ns };
    const t0: Clock = .fromNanoseconds(0);
    try std.testing.expect(!s.advance(t0)); // first call: anchor only
    try std.testing.expect(!s.advance(.fromNanoseconds(50 * ns)));
    try std.testing.expectEqual(@as(usize, 0), s.frame_index);
    try std.testing.expect(s.advance(.fromNanoseconds(150 * ns)));
    try std.testing.expectEqual(@as(usize, 1), s.frame_index);
}

test "spinner: zero interval advances and draws on the next nanosecond" {
    var spinner: Spinner = .{ .frames = &.{ "a", "b" }, .interval = 0 };
    var buf = try Buffer.init(test_alloc, 1, 1);
    defer buf.deinit();
    _ = try spinner.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqualStrings("a", buf.get(0, 0).grapheme);
    _ = try spinner.draw(&buf, 0, 0, .fromNanoseconds(1));
    try std.testing.expectEqualStrings("b", buf.get(0, 0).grapheme);
    try std.testing.expect(!spinner.advance(.fromNanoseconds(1)));
}

test "spinner: maximal elapsed time keeps the modular frame" {
    var spinner: Spinner = .{ .frames = &.{ "a", "b", "c" }, .interval = 0 };
    var buf = try Buffer.init(test_alloc, 1, 1);
    defer buf.deinit();
    _ = try spinner.draw(&buf, 0, 0, .fromNanoseconds(0));
    _ = try spinner.draw(&buf, 0, 0, .fromNanoseconds(1));
    _ = try spinner.draw(&buf, 0, 0, .fromNanoseconds(@as(i96, 1) << 64));
    try std.testing.expectEqualStrings("b", buf.get(0, 0).grapheme);
}

test "spinner: advance is idempotent for the same now" {
    var s: Spinner = .{ .interval = 100 * ns };
    const t0: Clock = .fromNanoseconds(0);
    const t1: Clock = .fromNanoseconds(150 * ns);
    _ = s.advance(t0);
    try std.testing.expect(s.advance(t1));
    try std.testing.expectEqual(@as(usize, 1), s.frame_index);
    try std.testing.expect(!s.advance(t1)); // same now: no second advance
    try std.testing.expectEqual(@as(usize, 1), s.frame_index);
}

test "spinner: frame_index catches up and wraps modulo frames.len" {
    var s: Spinner = .{ .frames = &.{ "a", "b" }, .interval = 100 * ns };
    const t0: Clock = .fromNanoseconds(0);
    _ = s.advance(t0);
    // 350 ms: three intervals elapsed in one call.
    try std.testing.expect(s.advance(.fromNanoseconds(350 * ns)));
    try std.testing.expectEqual(@as(usize, 1), s.frame_index); // (0 + 3) % 2
    try std.testing.expect(s.advance(.fromNanoseconds(450 * ns)));
    try std.testing.expectEqual(@as(usize, 0), s.frame_index); // (1 + 1) % 2
}

test "spinner: zero or one frame never advances; empty frames draw nothing" {
    var empty: Spinner = .{ .frames = &.{} };
    try std.testing.expect(!empty.advance(.fromNanoseconds(10 * ns)));

    var buf = try Buffer.init(test_alloc, 4, 1);
    defer buf.deinit();
    try std.testing.expectEqual(@as(u16, 0), try empty.draw(&buf, 0, 0, .fromNanoseconds(10 * ns)));

    var one: Spinner = .{ .frames = &.{"x"}, .interval = 10 * ns };
    try std.testing.expect(!one.advance(.fromNanoseconds(100 * ns)));
    try std.testing.expectEqual(@as(usize, 0), one.frame_index);
}

test "spinner: draw renders the current frame with style" {
    var s: Spinner = .{ .frames = &.{"⠋"} };
    var buf = try Buffer.init(test_alloc, 4, 1);
    defer buf.deinit();
    const consumed = try s.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 1), consumed);
    try std.testing.expectEqualStrings("⠋", buf.get(0, 0).grapheme);
    try std.testing.expect(buf.get(0, 0).style.fg.?.eql(.{ .ansi = .cyan }));

    var t: TestWriter = .{};
    t.init();
    try buf.renderAll(&t.w);
    try std.testing.expectEqualStrings("\r\x1b[K\x1b[36m⠋\x1b[0m", t.w.buffered());
}

test "spinner: label drawn after frame and space" {
    var s: Spinner = .{ .frames = &.{"x"}, .label = "loading" };
    var buf = try Buffer.init(test_alloc, 12, 1);
    defer buf.deinit();
    const consumed = try s.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 9), consumed); // 1 + 1 + 7
    try std.testing.expectEqualStrings("x", buf.get(0, 0).grapheme);
    try std.testing.expectEqualStrings(" ", buf.get(1, 0).grapheme);
    try std.testing.expectEqualStrings("l", buf.get(2, 0).grapheme);
    try std.testing.expectEqualStrings("g", buf.get(8, 0).grapheme);
}

test "spinner: label truncates at the buffer edge" {
    var s: Spinner = .{ .frames = &.{"x"}, .label = "abcdef" };
    var buf = try Buffer.init(test_alloc, 3, 1);
    defer buf.deinit();
    const consumed = try s.draw(&buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 3), consumed); // x + ' ' + 'a'
    try std.testing.expectEqualStrings("a", buf.get(2, 0).grapheme);
    try std.testing.expect(buf.get(0, 0).style.fg.?.eql(.{ .ansi = .cyan }));
}

test "spinner: wide frame at the last column drops gracefully" {
    var s: Spinner = .{ .frames = Spinner.presets.globe };
    var buf = try Buffer.init(test_alloc, 3, 1);
    defer buf.deinit();
    // x = 2: the 2-wide globe cannot start at the last column.
    const consumed = try s.draw(&buf, 2, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 0), consumed);
    try std.testing.expect(buf.get(2, 0).eql(.{}));
}

test "spinner: x += draw composes left-to-right" {
    var buf = try Buffer.init(test_alloc, 6, 1);
    defer buf.deinit();
    var a: Spinner = .{ .frames = &.{"a"} };
    var b: Spinner = .{ .frames = &.{"b"} };
    var x: u16 = 0;
    x += try a.draw(&buf, x, 0, .fromNanoseconds(0));
    x += try b.draw(&buf, x, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 2), x);
    try std.testing.expectEqualStrings("a", buf.get(0, 0).grapheme);
    try std.testing.expectEqualStrings("b", buf.get(1, 0).grapheme);
}
