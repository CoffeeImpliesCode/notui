//! Shared monotonic clock and elapsed-time helpers for presentation components.
//!
//! Each component has its own draw signature and return unit. Most take
//! `(buf, x, y, now)` and return consumed columns. `Text` and `Suggestions`
//! also take the allocator that owns their caller-provided scratch.
//! `Suggestions.draw` returns popup rows, not columns. No base type or
//! vtable imposes a uniform draw signature.
//!
//! Drawn cells borrow text. Keep caller scratch and component-owned formatted
//! bytes stable until the buffer has rendered. `advance` updates animation
//! without drawing and reports whether a frame changed.
//!
//! `now` is the monotonic clock: `std.Io.Timestamp.now(io, .awake)`.
//! Components take it as a parameter so they stay pure and testable
//! (tests pass synthetic values via `std.Io.Timestamp.fromNanoseconds`).

const std = @import("std");

/// The monotonic clock a component reads.
pub const Clock = std.Io.Timestamp;

/// Elapsed nanoseconds since `last`, when at least `interval` ns have
/// passed; the time gate an animated component applies in `advance`.
///
/// Returns null when `last` is unset (first call — the caller anchors
/// its clock) or when the interval has not yet elapsed. The caller must
/// not re-anchor `last` on a null, or elapsed time stops accumulating.
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
