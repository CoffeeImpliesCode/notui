//! Loop watchdog: a render loop must never block forever. The loop calls
//! `ping` each iteration; `tripped` reports, against the injected monotonic
//! clock, that the loop has gone quiet — a stuck probe or a blocked reader.

const std = @import("std");
/// The monotonic clock the watchdog reads: the same `std.Io.Timestamp` a
/// component's `draw` and `advance` callbacks are handed. Tests feed synthetic
/// values through `std.Io.Timestamp.fromNanoseconds`.
pub const Clock = std.Io.Timestamp;

/// Default heartbeat budget: 2 seconds, allowing bounded terminal-probe work.
pub const default_budget_ns: u64 = 2 * std.time.ns_per_s;

/// Liveness guard for a render loop: `ping` at the top of every iteration,
/// then ask `tripped` from the same iteration or from a supervisor.
///
/// All state is plain values: the watchdog never allocates, opens a timer or
/// reads the clock itself. The caller samples time and serializes access to the guard;
/// a watchdog reports a late heartbeat only when checked, not during a blocked call.
pub const Watchdog = struct {
    /// Budget in nanoseconds between two pings; see `default_budget_ns`.
    budget_ns: u64 = default_budget_ns,
    /// Instant of the last ping; null until the loop pings once.
    last_ping: ?Clock = null,

    /// A watchdog with an explicit budget, for a loop with a known frame
    /// cadence or for tests. `Watchdog{}` uses `default_budget_ns`.
    pub fn init(budget_ns: u64) Watchdog {
        return .{ .budget_ns = budget_ns };
    }

    /// Record that the loop is alive at `now`. Ping once when the loop starts,
    /// so the guard also covers a stall in the first iteration.
    pub fn ping(self: *Watchdog, now: Clock) void {
        self.last_ping = now;
    }

    /// True once the loop pinged at least once.
    pub fn armed(self: *const Watchdog) bool {
        return self.last_ping != null;
    }

    /// Nanoseconds since the last ping at `now`. Zero before the first ping
    /// and when `now` precedes the last ping (a monotonic clock never does, so
    /// the subtraction saturates instead of wrapping). Saturates at the
    /// `u64` maximum.
    pub fn age(self: *const Watchdog, now: Clock) u64 {
        const last = self.last_ping orelse return 0;
        // Saturating: a `now` before the last ping yields zero, never a
        // negative delta (or a panicking cast).
        const d = now.nanoseconds -| last.nanoseconds;
        if (d <= 0) return 0;
        return @intCast(@min(d, std.math.maxInt(u64)));
    }

    /// True when the loop is armed and more than `budget_ns` passed since the
    /// last ping. Exactly the budget is NOT a trip; one nanosecond more is.
    /// A watchdog that never pinged never trips: there is no stall to report
    /// before the loop's first iteration.
    pub fn tripped(self: *const Watchdog, now: Clock) bool {
        if (!self.armed()) return false;
        return self.age(now) > self.budget_ns;
    }
};

test {
    std.testing.refAllDecls(@This());
}

const testing = std.testing;
const ns_per_ms = std.time.ns_per_ms;

/// A clock reading far from zero, so a bug that compares absolute instants
/// instead of the delta cannot hide behind a zero.
fn clockAt(ns: i96) Clock {
    return .fromNanoseconds(ns);
}

test "watchdog: never trips before the first ping" {
    const w: Watchdog = .{ .budget_ns = 1 };
    try testing.expect(!w.armed());
    try testing.expect(!w.tripped(clockAt(5 * ns_per_ms)));
    try testing.expectEqual(@as(u64, 0), w.age(clockAt(5 * ns_per_ms)));
}

test "watchdog: trip boundary is strictly past the budget" {
    var w = Watchdog.init(1000);
    const t0 = clockAt(5 * ns_per_ms);
    w.ping(t0);
    try testing.expect(w.armed());
    try testing.expect(!w.tripped(clockAt(5 * ns_per_ms + 999))); // just under
    try testing.expect(!w.tripped(clockAt(5 * ns_per_ms + 1000))); // exactly at the budget
    try testing.expect(w.tripped(clockAt(5 * ns_per_ms + 1001))); // just over
    try testing.expectEqual(@as(u64, 1001), w.age(clockAt(5 * ns_per_ms + 1001)));
}

test "watchdog: ping re-arms the budget" {
    var w = Watchdog.init(1000);
    w.ping(clockAt(0));
    try testing.expect(w.tripped(clockAt(1001)));
    w.ping(clockAt(50 * ns_per_ms)); // the loop recovered
    try testing.expect(!w.tripped(clockAt(50 * ns_per_ms)));
    try testing.expect(!w.tripped(clockAt(50 * ns_per_ms + 1000)));
    try testing.expect(w.tripped(clockAt(50 * ns_per_ms + 1001)));
}

test "watchdog: a now before the last ping does not trip" {
    var w = Watchdog.init(0);
    w.ping(clockAt(10_000));
    try testing.expect(!w.tripped(clockAt(9_000))); // saturates to zero
    try testing.expect(!w.tripped(clockAt(10_000))); // zero budget, zero age
    try testing.expect(w.tripped(clockAt(10_001))); // one nanosecond over
}

test "watchdog: a stalled loop trips until it pings again" {
    // The consumer shape a render loop uses: ping, work, then check the
    // *previous* heartbeat before the next ping resets it. A frame that
    // blocked is already in the clock, so the stall is reported once instead
    // of being swallowed by re-pinging.
    var w = Watchdog.init(1000);
    w.ping(clockAt(0));
    try testing.expect(!w.tripped(clockAt(999)));

    // The loop stalled for 10 ms inside one iteration.
    try testing.expect(w.tripped(clockAt(10_000)));
    try testing.expect(w.tripped(clockAt(10_001))); // still stalled
    w.ping(clockAt(10_001)); // the loop is alive again: the stall clears
    try testing.expect(!w.tripped(clockAt(10_001)));
    try testing.expect(!w.tripped(clockAt(11_001))); // exactly the budget again
}
