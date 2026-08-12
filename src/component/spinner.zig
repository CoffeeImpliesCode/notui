//! Spinner: a frame-cycling animation component (baseui-contract.md
//! §4.1). Time-gated advance on the zigzag spinner.zig `update` model
//! (:96-104), driven by the std.Io monotonic clock; draws borrowed frame
//! slices via Buffer.draw — no allocation, no ANSI.

const std = @import("std");
const Buffer = @import("../buffer.zig").Buffer;
const Style = @import("../style.zig").Style;
const Clock = @import("component.zig").Clock;
const elapsedSince = @import("component.zig").elapsedSince;

pub const Spinner = struct {
    /// Animation frames, borrowed (never freed, never allocated).
    frames: []const []const u8 = &default_frames,
    /// Nanoseconds per frame.
    interval: u64 = 100 * std.time.ns_per_ms,
    /// Style for the frame and (when set) the label.
    style: Style = .{ .fg = .{ .ansi = .cyan } },
    /// Optional trailing text drawn after a single space, styled with
    /// `style`.
    label: ?[]const u8 = null,
    // state
    frame_index: usize = 0,
    last_advance: ?Clock = null,

    /// The shared braille spinner set (pi-tui loader.ts:10, zigzag
    /// spinner.zig:22 — identical).
    pub const default_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

    /// Extra frame tables, ported from zigzag spinner.zig `Styles`
    /// (:21-40).
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

    /// Advance `frame_index` by the count of elapsed intervals. Returns
    /// true when the frame index moved. Idempotent per `now`.
    pub fn advance(self: *Spinner, now: Clock) bool {
        if (self.frames.len <= 1) return false;
        const elapsed = elapsedSince(now, self.last_advance, self.interval) orelse {
            // First call: anchor the clock; the first frame lands one
            // interval later. Later calls before the interval: keep
            // accumulating, do NOT re-anchor.
            if (self.last_advance == null) self.last_advance = now;
            return false;
        };
        const n = elapsed / self.interval;
        self.frame_index = (self.frame_index + n) % self.frames.len;
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

test "spinner: presets and default frames" {
    try std.testing.expectEqual(@as(usize, 10), Spinner.default_frames.len);
    try std.testing.expectEqual(@as(usize, 4), Spinner.presets.line.len);
    try std.testing.expectEqual(@as(usize, 3), Spinner.presets.globe.len);
    try std.testing.expectEqual(@as(usize, 8), Spinner.presets.dots2.len);
    // `dots` is the same table as the default.
    try std.testing.expectEqual(@as(usize, 10), Spinner.presets.dots.len);
}

test "spinner: advance is gated on the interval" {
    var s: Spinner = .{ .interval = 100 * ns };
    const t0: Clock = .fromNanoseconds(0);
    try std.testing.expect(!s.advance(t0)); // first call: anchor only
    try std.testing.expect(!s.advance(.fromNanoseconds(50 * ns)));
    try std.testing.expectEqual(@as(usize, 0), s.frame_index);
    try std.testing.expect(s.advance(.fromNanoseconds(150 * ns)));
    try std.testing.expectEqual(@as(usize, 1), s.frame_index);
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
