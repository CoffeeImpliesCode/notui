//! Cmd(Msg): the effect vocabulary an `update` returns
//! (framework-contract.md §3).
//!
//! Effects are synchronous in v1: the App processes the returned Cmd
//! before the frame renders. `batch`/`sequence` carry borrowed slices
//! (frame-arena or app-owned); never free them — `frame_arena` resets
//! each tick. The processing logic itself lives on `App(Model)`
//! (`processCmd`, app.zig) because it recurses into `update` and touches
//! loop state; this module owns only the union and its pure helpers.

const std = @import("std");

/// An effect produced by `update`.
pub fn Cmd(comptime Msg: type) type {
    return union(enum) {
        none,
        /// Stop the loop after this tick; `run` performs the teardown
        /// sequence (Region.exit → caps.restore → tty.restore).
        quit,
        /// Schedule one `Msg` (dispatched via the model's `update`) after
        /// `delay_ms` of inactivity — the bubbletea `tick` pattern. The
        /// scheduled message is the model's `.tick` (requires the field).
        tick: struct { delay_ms: u32 },
        /// Re-arm a periodic tick every `interval_ms` until replaced or
        /// quit. The tick's Msg is the model's `.tick` (requires the
        /// field); the App dispatches it once per interval.
        every: struct { interval_ms: u32 },
        /// Dispatch each contained Cmd in order, same tick, each fully
        /// processed (folded into the loop) before the next.
        batch: []const Cmd(Msg),
        /// Like batch but strictly sequential: each element's effects are
        /// drained before the next element starts. The v1 loop is
        /// single-threaded, so both take the same in-order path
        /// (orchestrator Q2).
        sequence: []const Cmd(Msg),
        /// Dispatch `msg` immediately (recurses into `update` within this
        /// tick).
        msg: Msg,
        /// Append `text` ABOVE the region into scrollback as a plain line
        /// (the print-above escape hatch — `Region.Append.line`), forcing
        /// a render this tick.
        println: []const u8,
        /// Set the terminal title (OSC 0): written inline by the App via
        /// the writer (`\x1b]0;{s}\x07`).
        set_title: []const u8,
        /// Enable/disable SGR 1006 mouse reporting immediately (CSI
        /// ?1006h/?1006l + ?1000h/?1000l; caps.restore turns it off on
        /// exit, caps.zig:58-59). Overridden by the next frame's
        /// `View.mouse` if they differ.
        mouse: bool,
        /// Show/hide the cursor immediately (`emit.hideCursor/showCursor`).
        cursor: bool,
    };
}

/// True when `cmd` is the no-op `none` tag.
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
}
