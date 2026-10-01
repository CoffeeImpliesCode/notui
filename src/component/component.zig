//! Component contract: the common `draw`/`advance` surface and the
//! shared time-gated advance helper for the base-ui presentation layer
//! (baseui-contract.md §3).
//!
//! A component is a plain stateful struct that owns its configuration
//! and animation state. It draws grapheme cells into a `Buffer` (the
//! same contract `Region.renderDiff` consumes) at an explicit (x, y),
//! never emits ANSI, and never allocates during `draw`. `draw` advances
//! animation state to `now` first, so one call per frame is enough;
//! `advance` alone lets an app time-animate without redrawing and
//! reports whether the frame changed (for render gating).
//!
//! `now` is the monotonic clock: `std.Io.Timestamp.now(io, .awake)`.
//! Components take it as a parameter so they stay pure and testable
//! (tests pass synthetic values via `std.Io.Timestamp.fromNanoseconds`).

const std = @import("std");
const Buffer = @import("../buffer.zig").Buffer;

/// The monotonic clock a component reads.
pub const Clock = std.Io.Timestamp;

/// The template surface every component implements. Components do NOT
/// inherit this struct; each is a standalone struct exposing `draw` and
/// `advance` with these shapes (duck-typed, no vtable).
pub const Component = struct {
    /// Draw into `buf` with the top-left at (x, y); return the number of
    /// COLUMNS consumed (width-aware truncation: never exceeds
    /// `buf.width`, per Buffer.draw). May draw multiple rows (a wrapped
    /// Text); consumed = widest row. Advances animation state to `now`
    /// first, so a frame that calls `draw` reflects the current time.
    pub fn draw(self: *Component, buf: *Buffer, x: u16, y: u16, now: Clock) !u16 {
        _ = self;
        _ = buf;
        _ = x;
        _ = y;
        _ = now;
        return 0;
    }

    /// Advance animation to `now` WITHOUT drawing. Returns true when the
    /// frame changed (the app may use it to skip re-renders). Idempotent:
    /// calling twice with the same `now` advances at most once.
    pub fn advance(self: *Component, now: Clock) bool {
        _ = self;
        _ = now;
        return false;
    }
};

/// Elapsed nanoseconds since `last`, when at least `interval` ns have
/// passed (zigzag spinner.zig update model, baseui-contract.md §3).
/// Returns null when `last` is unset (first call — the caller should
/// anchor its clock) or when the interval has not yet elapsed (the
/// caller must NOT re-anchor, so elapsed keeps accumulating).
pub fn elapsedSince(now: Clock, last: ?Clock, interval: u64) ?u64 {
    const l = last orelse return null;
    const d = now.nanoseconds -| l.nanoseconds; // monotonic: safe
    if (d < 0) return null;
    const du: u64 = @intCast(d);
    return if (du >= interval) du else null;
}

test {
    std.testing.refAllDecls(@This());
}

test "component: elapsedSince first call returns null (anchor)" {
    const now: Clock = .fromNanoseconds(1_000);
    try std.testing.expect(elapsedSince(now, null, 100) == null);
}

test "component: elapsedSince gated on the interval" {
    const last: Clock = .fromNanoseconds(0);
    try std.testing.expect(elapsedSince(.fromNanoseconds(50), last, 100) == null);
    try std.testing.expect(elapsedSince(.fromNanoseconds(100), last, 100) != null);
    try std.testing.expectEqual(@as(u64, 250), elapsedSince(.fromNanoseconds(250), last, 100).?);
}

test "component: elapsedSince equal timestamps yield null (idempotent)" {
    const last: Clock = .fromNanoseconds(250);
    try std.testing.expect(elapsedSince(.fromNanoseconds(250), last, 100) == null);
}
