//! Context: everything a Model's `update` and `view` see each frame
//! (framework-contract.md §2).
//!
//! Built and refreshed by `App` once per `tick`; `update`/`view` treat it
//! as read-only except for `render_requested` and the frame `buf` they
//! draw into. TWO allocators, with a strict lifetime split (the frame
//! buffer's cells BORROW their grapheme slices — cell.zig: "grapheme is
//! borrowed, never copied" — so drawn content must outlive the frame):
//! `frame_arena` is the persistent app-lifetime arena (never reset;
//! skript_repl.zig:175-181 app-arena pattern) and is the ONLY place text
//! that lands in `buf` cells may come from; `scratch_arena` is the
//! per-tick arena, reset at the top of every tick, for transient work
//! that is not retained.
//!
//! The surface is deliberately narrow (orchestrator Q3): the raw
//! tty/caps internals are NOT exposed; the frame `buf`, the geometry, the
//! allocators, `io`, the color profile, and the `appendAbove` escape
//! hatch cover what a Model may touch.

const std = @import("std");
const Region = @import("region.zig").Region;
const Buffer = @import("buffer.zig").Buffer;
const ColorProfile = @import("color.zig").ColorProfile;

/// Everything a Model's `update` and `view` see each frame.
pub const Context = struct {
    /// Long-lived session allocator (the gpa passed to `run`); for state
    /// the model keeps beyond the current frame (arena memory lives for
    /// the whole session).
    allocator: std.mem.Allocator,
    /// The app-lifetime arena. PERSISTENT — never reset: the frame
    /// Buffer's cells borrow their grapheme slices from here (cell.zig,
    /// architecture §3), so wrapped/truncated text and formatted numbers
    /// that go INTO the frame buffer must be allocated here
    /// (skript_repl.zig:175-181 app-arena pattern). A per-tick reset
    /// would alias the `prev` frame's cells with reused memory — frames
    /// would never repaint. Retaining across frames is safe.
    frame_arena: std.mem.Allocator,
    /// Per-frame scratch arena, reset at the top of every tick. For
    /// TRANSIENT work only (temporary formatting, sorting, layout) —
    /// anything stored into `buf` cells MUST come from `frame_arena`.
    /// Slices from a previous frame are dead.
    scratch_arena: std.mem.Allocator,
    /// The std.Io threaded onto the tty (clock, output) — for
    /// `std.Io.Timestamp.now(io, .awake)` (component.zig:27) and
    /// `Duration`.
    io: std.Io,
    /// The ACTIVE frame buffer for this tick — the inline Region's `cur`
    /// (in v1 the inline Region owns the primary screen; alt-screen is a
    /// parsed-but-noop, orchestrator Q1). `View.draw` and the model's
    /// components draw into THIS. Do not retain across ticks.
    buf: *Buffer,
    /// Current terminal width in columns (resized on winsize; equals
    /// `region.width`).
    width: u16,
    /// Current band/frame height in rows.
    height: u16,
    /// Elapsed since the previous tick (monotonic; `std.Io.Timestamp`
    /// diff). `.zero` on the first tick.
    frame_delta: std.Io.Duration,
    /// Tick sequence number, starting at 0.
    frame_count: u64,
    /// Detected color profile (`caps.color`, caps.zig:23-34) — the model
    /// uses it to pick the palette (statusline.zig Palette pattern).
    color_profile: ColorProfile,
    /// Set true to force a repaint this tick even when the `View`
    /// signature is unchanged (e.g. a spinner advanced, a timer fired).
    /// Read-write.
    render_requested: bool = false,

    /// Framework-internal: the inline Region backing `buf` and the append
    /// queue. Not part of the model-facing surface (orchestrator Q3);
    /// `App` fills it and `appendAbove` drains it — models must not touch
    /// it.
    region: *Region,

    /// Append `text` ABOVE the region into scrollback as one plain row
    /// (the print-above escape hatch — wraps `Region.Append.line`,
    /// region.zig:116). Forces a render this tick so the append queue
    /// flushes above the band.
    pub fn appendAbove(self: *Context, text: []const u8) !void {
        try self.region.append(.{ .line = text });
        self.render_requested = true;
    }
};

test {
    std.testing.refAllDecls(@This());
}

const testing = std.testing;

/// A Context with enough runtime state for unit tests (no tty).
fn testCtx(arena: *std.heap.ArenaAllocator, scratch: *std.heap.ArenaAllocator, region: *Region) Context {
    return .{
        .allocator = testing.allocator,
        .frame_arena = arena.allocator(),
        .scratch_arena = scratch.allocator(),
        .io = testing.io,
        .buf = &region.cur,
        .width = region.width,
        .height = region.height,
        .frame_delta = .zero,
        .frame_count = 0,
        .color_profile = .ansi256,
        .region = region,
    };
}

test "context: frame_delta is the monotonic diff of two timestamps" {
    var region = try Region.init(testing.allocator, .{ .height = 2, .sync_output = false });
    defer region.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    // The diff the App computes per tick (§5.2 step 6): the monotonic
    // `now - last_tick` over `std.Io.Timestamp`.
    const t0 = std.Io.Timestamp.fromNanoseconds(1_000_000);
    const t1 = std.Io.Timestamp.fromNanoseconds(4_000_000);
    var ctx = testCtx(&arena, &scratch, &region);
    ctx.frame_delta = t0.durationTo(t1);
    ctx.frame_count = 7;

    try testing.expectEqual(@as(i96, 3_000_000), ctx.frame_delta.nanoseconds);
    try testing.expectEqual(@as(u64, 7), ctx.frame_count);
}

test "context: frame_arena is persistent — slices survive across ticks" {
    var region = try Region.init(testing.allocator, .{ .height = 2, .sync_output = false });
    defer region.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    var ctx = testCtx(&arena, &scratch, &region);
    // Drawn text: the frame Buffer's cells borrow this slice (cell.zig),
    // so it must survive the tick boundary — the app arena is never reset.
    const frame_text = try ctx.frame_arena.dupe(u8, "drawn");
    _ = scratch.reset(.retain_capacity); // the tick boundary resets scratch only
    const more = try ctx.frame_arena.dupe(u8, "more");
    try testing.expectEqualStrings("drawn", frame_text); // still alive
    try testing.expect(@intFromPtr(more.ptr) != @intFromPtr(frame_text.ptr)); // both live
}

test "context: scratch_arena slices die across a tick boundary (arena reset)" {
    var region = try Region.init(testing.allocator, .{ .height = 2, .sync_output = false });
    defer region.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    var ctx = testCtx(&arena, &scratch, &region);
    const scratch_a = try ctx.scratch_arena.alloc(u8, 64);

    // Simulate the next tick: the scratch arena resets, so the previous
    // frame's transient slice is dead — a fresh allocation lands at the
    // same address (the retained buffer is reused).
    _ = scratch.reset(.retain_capacity);
    const scratch_b = try ctx.scratch_arena.alloc(u8, 64);

    try testing.expectEqual(@intFromPtr(scratch_a.ptr), @intFromPtr(scratch_b.ptr));
}

test "context: appendAbove queues one Region.Append.line and forces a render" {
    var region = try Region.init(testing.allocator, .{ .height = 2, .sync_output = false });
    defer region.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    var ctx = testCtx(&arena, &scratch, &region);
    try ctx.appendAbove("hello");

    try testing.expectEqual(@as(usize, 1), region.append_queue.items.len);
    switch (region.append_queue.items[0]) {
        .line => |l| try testing.expectEqualStrings("hello", l),
        else => return error.TestUnexpectedResult,
    }
    try testing.expect(ctx.render_requested);
}
