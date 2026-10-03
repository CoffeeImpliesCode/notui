//! The effect vocabulary an `update` returns.
//!
//! A `Cmd(Msg)` is one effect the loop runs after `update` has returned and
//! before the frame renders. What a payload borrows, and for how long, is
//! per tag: `batch`, `sequence`, `set_title` and `msg` are read only while the
//! command is being processed, which ends inside the same frame; a `println`
//! payload stays borrowed by the scrollback queue until that queue is flushed
//! or the session ends, which a terminal that stopped reading can defer
//! indefinitely; a timer copies its `Msg` and holds it until the timer fires or
//! is replaced. Each tag states its own rule.
//!
//! `App` owns the processing (`processCmd` in app.zig): it recurses into
//! `update` and touches loop state. This module owns only the union and its
//! pure helpers, and allocates nothing.

const std = @import("std");

/// One effect returned by `update`, parameterized by the model's `Msg` type.
///
/// The union owns nothing and allocates nothing, so a `Cmd` is copied freely by
/// the caller; every payload it carries is either copied or borrowed, under the
/// lifetime each tag states.
pub fn Cmd(comptime Msg: type) type {
    return union(enum) {
        /// No effect. The only tag `isNoop` reports.
        none,
        /// Stop the loop after this tick. The App then writes the teardown
        /// sequence (`Region.exit`, `caps.restore`, `Tty.restore`) and releases
        /// the session.
        quit,
        /// Arm a one-shot timer: `msg` is copied into the session and
        /// enqueued for `update` once `delay_ms` have passed. Arming again
        /// replaces the pending deadline and its message; there is at most
        /// one one-shot timer.
        ///
        /// `msg` is copied, not deep-copied: any memory it points at stays
        /// the caller's responsibility until the timer fires, until another
        /// `tick` (or `quit`) replaces it, or until the session ends.
        tick: struct { delay_ms: u32, msg: Msg },
        /// Arm a periodic timer: `msg` is copied into the session and enqueued
        /// for `update` once per `interval_ms`. Arming again replaces the
        /// running interval, its anchor and its message; there is at most one
        /// periodic timer. `interval_ms` of 0 fires on every tick that observes
        /// it.
        ///
        /// `msg` follows the same rule as `tick`: it is copied, and what it
        /// points at must stay valid until the timer is replaced, until the
        /// session ends, or until the caller can prove no further fire is
        /// possible.
        every: struct { interval_ms: u32, msg: Msg },
        /// Run each contained command in order within this frame, each one
        /// fully processed before the next starts. Borrows the slice of
        /// commands for the processing only, which ends inside this frame.
        batch: []const Cmd(Msg),
        /// The same in-order path as `batch`; the loop is single-threaded, so
        /// each element's effects complete before the next element begins.
        /// Borrows the slice for the same window.
        sequence: []const Cmd(Msg),
        /// Dispatch `msg` immediately: `update` is re-entered within this
        /// tick and the command it returns is processed next.
        msg: Msg,
        /// Append `text` above the band into scrollback as one plain line,
        /// forcing a render this frame.
        ///
        /// The queue borrows `text`: it must stay alive and unchanged until
        /// the region has flushed that line or the session ends, and a frame
        /// the terminal has not accepted can defer that indefinitely. A
        /// payload the model wants to release sooner must live in the session
        /// arena instead.
        println: []const u8,
        /// Write the terminal title (OSC 0) as an immediate effect outside the
        /// frame. `text` is borrowed for that write only, and the App keeps no
        /// reference afterwards.
        set_title: []const u8,
        /// Enable or disable SGR 1006 mouse reporting immediately; the next
        /// frame's `View.mouse` overrides it when the two disagree.
        mouse: bool,
        /// Show or hide the cursor immediately. The next frame's
        /// `View.hide_cursor` overrides it when the two disagree.
        cursor: bool,
    };
}

/// True when `cmd` is the `none` tag.
pub fn isNoop(cmd: anytype) bool {
    return std.meta.activeTag(cmd) == .none;
}

test {
    std.testing.refAllDecls(@This());
}

test "cmd: none is the only no-op tag" {
    const M = enum { a };
    const C = Cmd(M);
    const testing = std.testing;
    try testing.expect(isNoop(@as(C, .none)));
    try testing.expect(!isNoop(@as(C, .quit)));
    try testing.expect(!isNoop(@as(C, .{ .msg = .a })));
    try testing.expect(!isNoop(@as(C, .{ .batch = &.{} })));
    try testing.expect(!isNoop(@as(C, .{ .set_title = "" })));
    try testing.expect(!isNoop(@as(C, .{ .tick = .{ .delay_ms = 1, .msg = .a } })));
    try testing.expect(!isNoop(@as(C, .{ .every = .{ .interval_ms = 1, .msg = .a } })));
}
