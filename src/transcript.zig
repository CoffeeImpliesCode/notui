//! Streaming transcript retirement: `active → settled → committed`
//! (roadmap C3, zomp's Phase-6 contract).
//!
//! A transcript block is a chunk of streaming output (a tool call, a
//! stream of tokens, a diff). It moves through three states:
//!
//! - `active` — the product is still writing it. It is part of the
//!   mutable view and may be repainted.
//! - `settled` — THE PRODUCT said its content is final (`settle`).
//!   Finality is never inferred from a block crossing the top of the
//!   screen or from an idle frame; only this call moves a block.
//! - `committed` — the rows reached the terminal and the transport
//!   accepted them. The block leaves the mutable view and its bytes are
//!   freed, so it can never be repainted.
//!
//! Retirement is budgeted: `retire` walks the blocks in order and stops
//! when `Options.budget_ns` is spent, leaving the rest for the next
//! frame. Order is never broken — a single unsettled block holds back
//! everything behind it, so the ledger stays a prefix.
//!
//! Bounds: at most `Options.max_live_blocks` blocks are retained at
//! once (live plus retired-but-unacknowledged). A product that never
//! settles trips `error.LiveCapacityExceeded` rather than letting the
//! transcript guess finality.
//!
//! Integration: the caller stages the delta as one history batch
//! (`Region.writeHistory` / `Region.writeTranscript`) and seals it with
//! the returned receipt id; when the transport accepts that receipt the
//! caller calls `commitReceipt`, which frees EXACTLY the blocks that
//! receipt covers. Retirement and acknowledgement are the same contract
//! as `Region.acknowledgeDrained`.
//!
//! Retry is the caller's half of that contract and it is exact: an
//! unsealed delta is still this frame's, so `retire` re-emits it
//! unchanged until `sealDelta` takes it, and a ledger sink that refuses
//! the batch loses nothing. `retire` reserves the seal slot before a
//! block leaves the mutable view, so `sealDelta` cannot fail.
//!
//! Reach through `@import("notui").transcript`: `init`, `push`, `settle`, `retire`,
//! seal the accepted delta, then `commitReceipt`; dispose the remaining owner once.
//! This module owns copied rows, not terminal output or the clock provider.

const std = @import("std");

/// Monotonic nanosecond source, injected so the budget is deterministic
/// under test. Production uses `Clock.fromIo`.
/// Copies retain the same borrowed context; it and callback code must outlive clock use.
/// `retire` invokes the callback synchronously on its calling thread, without reentry
/// into that transcript. No default provider is selected.
pub const Clock = struct {
    /// Borrowed provider context; must remain live whenever `now` can be called.
    ctx: *const anyopaque,
    /// Monotonic nanoseconds from `ctx`; borrow lasts only for each call.
    now_ns: *const fn (ctx: *const anyopaque) u64,

    /// Sample the injected monotonic clock without retaining or releasing its context.
    pub fn now(self: Clock) u64 {
        return self.now_ns(self.ctx);
    }

    /// The process clock: `std.Io.Timestamp` nanoseconds. The caller
    /// keeps the `Io` alive for as long as the clock is used.
    pub fn fromIo(io: *const std.Io) Clock {
        return .{ .ctx = io, .now_ns = ioNow };
    }

    fn ioNow(ctx: *const anyopaque) u64 {
        const p: *const std.Io = @ptrCast(@alignCast(ctx));
        return @intCast(std.Io.Timestamp.now(p.*, .awake).nanoseconds);
    }
};

/// Where a block is in the retirement machine.
pub const State = enum {
    /// Product-writable content; the initial state of each pushed block.
    active,
    /// Product-declared final content, eligible for ordered retirement.
    settled,
    /// Transport-accepted content whose storage has been released.
    committed,
};

/// One frame's retirement delta: the rows to write and the block ids
/// they came from, in order. Borrowed from the transcript: copy the slice arrays before
/// a later `retire` assembles another delta. Row bytes remain valid only until their
/// receipt is committed or the transcript is disposed. Retrying an unsealed delta
/// preserves its arrays and bytes. Copies of a delta create no ownership duty.
pub const Delta = struct {
    /// Borrowed row views in retirement order; empty for a zero-row block.
    rows: []const []const u8 = &.{},
    /// Borrowed retired block ids, including blocks that contain no rows.
    ids: []const u64 = &.{},
    /// Retired block count, equal to `ids.len` for deltas returned by `retire`.
    blocks: usize = 0,

    /// Whether no block awaits commitment. A zero-row block still requires a receipt.
    pub fn isEmpty(self: Delta) bool {
        return self.blocks == 0;
    }

    /// Total row bytes in the delta (frame-cost accounting).
    pub fn byteLen(self: Delta) usize {
        var n: usize = 0;
        for (self.rows) |row| n += row.len;
        return n;
    }
};

/// Copied-row retirement owner. Construct with `init`; keep its allocator live through
/// one `deinit`. Copies alias storage and must not be separately disposed.
/// Use on one thread without clock reentry. Reachable state fields are read-only.
/// Row views survive pushes and retirement, but not commitment of their block or teardown.
pub const Transcript = struct {
    /// Retirement limits. Defaults bound retained work to 256 blocks and budget each
    /// call to 8 ms; zero budget still allows one eligible block to make progress.
    pub const Options = struct {
        /// Retirement time budget per frame (8 ms — the reference
        /// budget). Exceeding it defers the remainder to the next
        /// frame instead of stalling the loop; at least one block is
        /// retired per call so the ledger always progresses.
        budget_ns: u64 = 8 * std.time.ns_per_ms,
        /// Hard bound on retained blocks (live + retired but not
        /// acknowledged). Exceeding it is an error, never a guess.
        max_live_blocks: usize = 256,
    };

    /// One Transcript-owned row array. Copies share bytes; only the Transcript releases them.
    const Block = struct {
        /// Monotonically assigned block id; only the Transcript chooses it.
        id: u64,
        /// Owned row copies — a push copies, so the caller may reuse
        /// its staging buffer immediately.
        rows: [][]u8,
        /// Product-declared state; starts active and changes through transcript methods.
        state: State = .active,
    };

    /// Receipt-to-block inclusive id range owned by the Transcript, with no separate cleanup.
    const Seal = struct {
        /// Caller-provided history receipt, unique among outstanding seals.
        receipt: u64,
        /// The block ids this receipt owns. Ids are unique and never
        /// reused, so the pair names an exact block range even when
        /// receipts arrive out of write order.
        first: u64,
        last: u64,
    };

    /// Push refusal or allocation failure; no block id or partial payload is admitted.
    pub const PushError = error{ LiveCapacityExceeded, OutOfMemory };
    /// The block is absent or no longer active; no state changes on this error.
    pub const SettleError = error{UnknownBlock};
    /// Sealing a delta that is not pending: empty, or already handed to
    /// a ledger sink. Never an allocation failure.
    pub const SealError = error{DeltaNotPending};

    /// Stored row/container allocator; read-only and live until disposal.
    gpa: std.mem.Allocator,
    /// Stored retirement limits; read-only after construction.
    opts: Options,
    /// Retained blocks in creation order. `[0..staged)` are retired and
    /// waiting for a receipt; the rest are still in the mutable view.
    blocks: std.ArrayListUnmanaged(Block) = .empty,
    staged: usize = 0,
    next_id: u64 = 1,
    /// Reused between frames: no allocation in steady state.
    delta_rows: std.ArrayListUnmanaged([]const u8) = .empty,
    delta_ids: std.ArrayListUnmanaged(u64) = .empty,
    /// Receipts of deltas handed to a ledger sink, in order.
    seals: std.ArrayListUnmanaged(Seal) = .empty,
    delta_blocks: usize = 0,
    /// False between the `retire` that produced a delta and the
    /// `sealDelta` that handed it to a ledger sink. While it is false
    /// the delta is still this frame's, and `retire` re-emits it.
    delta_sealed: bool = true,
    /// Blocks retired over the session (telemetry). A block that `retire`
    /// handed to a delta keeps counting here after its receipt commits it,
    /// so this is not a count of committed blocks.
    retired: usize = 0,

    /// Construct an allocation-free empty owner. `max_live_blocks > 0` is a caller
    /// precondition in every mode; debug assertions are not ReleaseFast validation.
    /// The error set is empty for the lifecycle interface.
    pub fn init(gpa: std.mem.Allocator, opts: Options) !Transcript {
        std.debug.assert(opts.max_live_blocks > 0);
        return .{ .gpa = gpa, .opts = opts };
    }

    /// Release all copied rows and metadata through the stored allocator.
    /// Invalidates every row and delta view; repeated disposal or disposing a copy is invalid.
    pub fn deinit(self: *Transcript) void {
        for (self.blocks.items) |b| self.freeBlock(b);
        self.blocks.deinit(self.gpa);
        self.delta_rows.deinit(self.gpa);
        self.delta_ids.deinit(self.gpa);
        self.seals.deinit(self.gpa);
        self.* = undefined;
    }

    /// Append a block of rows. The rows are copied, so the caller owns
    /// its slice again as soon as this returns. The new block is
    /// `active`: the product owns finality.
    ///
    /// `error.LiveCapacityExceeded` when the retained-block bound is
    /// reached — settle and commit, do not expect a guess.
    /// `error.OutOfMemory` admits no block and leaves existing rows and ids unchanged;
    /// reusable metadata capacity may have grown. Ids must not exhaust `u64`.
    pub fn push(self: *Transcript, rows: []const []const u8) PushError!u64 {
        if (self.blocks.items.len >= self.opts.max_live_blocks) return error.LiveCapacityExceeded;
        // Reserve every fallible step before taking ownership of
        // anything. `rows` is the CALLER's memory and is never freed here
        // on any path: only the copies this call makes are released.
        try self.blocks.ensureUnusedCapacity(self.gpa, 1);
        const owned = try self.gpa.alloc([]u8, rows.len);
        var filled: usize = 0;
        errdefer {
            // `filled` counts the copies that exist; the rest of the
            // array was never written.
            for (owned[0..filled]) |row| self.gpa.free(row);
            self.gpa.free(owned);
        }
        while (filled < rows.len) : (filled += 1) {
            owned[filled] = try self.gpa.dupe(u8, rows[filled]);
        }
        // Nothing below can fail.
        const id = self.next_id;
        self.next_id += 1;
        self.blocks.appendAssumeCapacity(.{ .id = id, .rows = owned });
        return id;
    }

    /// The product declares this block final. Idempotence is refused on
    /// purpose: a second settle is a product bug, and a settle of an
    /// already-committed block would resurrect terminal bytes.
    pub fn settle(self: *Transcript, id: u64) SettleError!void {
        for (self.blocks.items) |*b| {
            if (b.id != id) continue;
            if (b.state != .active) return error.UnknownBlock;
            b.state = .settled;
            return;
        }
        return error.UnknownBlock;
    }

    /// Retire settled blocks into `out` while the budget holds. The
    /// delta is replaced every call — it is THIS frame's delta, not an
    /// accumulator. At least one block is retired per call, so a zero
    /// budget still makes progress.
    ///
    /// A delta that no `sealDelta` has taken yet is still this frame's:
    /// the call re-emits it unchanged and the staged cursor does not
    /// move, so a caller whose ledger sink refused the batch retries
    /// with the same rows instead of losing or duplicating them.
    ///
    /// Order is preserved: the walk stops at the first block that is
    /// not settled, so the ledger is always a prefix of the stream.
    /// OOM leaves no new delta and no block newly retired; previous sealed arrays may
    /// be invalidated and reusable capacity may change. `out` is empty on failure.
    /// The clock context stays caller-owned and is borrowed only during this call.
    pub fn retire(self: *Transcript, clock: Clock, out: *Delta) std.mem.Allocator.Error!void {
        if (self.heldDelta()) |held| {
            out.* = held;
            return;
        }
        // No delta is pending: the previous one was sealed (or there was
        // none), so the reused buffers start empty again.
        self.clearDelta();
        out.* = .{};
        // Reserve the seal slot BEFORE a block leaves the mutable view:
        // sealing is then infallible, so the caller's ledger enqueue is
        // the only step that can still fail, and failing it leaves the
        // delta pending and retryable.
        try self.seals.ensureUnusedCapacity(self.gpa, 1);
        const started_ns = clock.now();
        var i = self.staged;
        while (i < self.blocks.items.len) : (i += 1) {
            const b = self.blocks.items[i];
            if (b.state != .settled) break;
            if (i > self.staged and clock.now() -| started_ns >= self.opts.budget_ns) break;
            // A partial delta is never observable: on failure the delta
            // is emptied and `staged` never moves, so the blocks retire
            // again (in the same order) on the next call.
            self.delta_rows.appendSlice(self.gpa, b.rows) catch {
                self.clearDelta();
                return error.OutOfMemory;
            };
            self.delta_ids.append(self.gpa, b.id) catch {
                self.clearDelta();
                return error.OutOfMemory;
            };
            self.delta_blocks += 1;
        }
        self.staged = i;
        self.retired += self.delta_blocks;
        self.delta_sealed = self.delta_blocks == 0;
        out.* = self.heldDelta() orelse .{};
    }

    /// Record that this frame's delta was handed to a ledger sink under
    /// `receipt`. The blocks stay retained until `commitReceipt`, and
    /// the receipt owns exactly this delta's blocks.
    ///
    /// Infallible by construction: `retire` reserved the slot before
    /// the blocks left the mutable view. The only error is a caller that
    /// seals a delta that is not pending — a product bug, reported.
    /// `receipt` must be unique among outstanding seals; a duplicate is a caller error.
    pub fn sealDelta(self: *Transcript, receipt: u64) SealError!void {
        if (self.delta_blocks == 0 or self.delta_sealed) return error.DeltaNotPending;
        self.seals.appendAssumeCapacity(.{
            .receipt = receipt,
            .first = self.delta_ids.items[0],
            .last = self.delta_ids.items[self.delta_ids.items.len - 1],
        });
        self.delta_sealed = true;
    }

    /// The transport accepted `receipt`: commit exactly the blocks that
    /// receipt sealed, free their rows, drop them from the mutable view.
    /// Receipts may arrive in any order — a later receipt never frees
    /// the blocks of an earlier one, and every other block waits for
    /// its own.
    /// `error.UnknownReceipt` changes nothing. Success invalidates views of those rows.
    pub fn commitReceipt(self: *Transcript, receipt: u64) error{UnknownReceipt}!void {
        for (self.seals.items, 0..) |seal, i| {
            if (seal.receipt != receipt) continue;
            _ = self.seals.orderedRemove(i);
            self.commitRange(seal.first, seal.last);
            return;
        }
        return error.UnknownReceipt;
    }

    /// The unsealed delta, or null when there is none: a delta is live
    /// from the `retire` that produced it until `sealDelta` takes it.
    fn heldDelta(self: *const Transcript) ?Delta {
        if (self.delta_blocks == 0 or self.delta_sealed) return null;
        return .{
            .rows = self.delta_rows.items,
            .ids = self.delta_ids.items,
            .blocks = self.delta_blocks,
        };
    }

    /// Free the retired blocks whose ids lie in `[first, last]`. Only
    /// sealed blocks are ever removed, and sealed blocks are always
    /// retired, so every removal shortens the retired prefix.
    fn commitRange(self: *Transcript, first: u64, last: u64) void {
        var i: usize = 0;
        while (i < self.blocks.items.len) {
            const id = self.blocks.items[i].id;
            if (id < first) {
                i += 1;
                continue;
            }
            if (id > last) break;
            std.debug.assert(self.staged > 0);
            self.freeBlock(self.blocks.orderedRemove(i));
            self.staged -= 1;
        }
    }

    /// Blocks currently retained: live plus retired-not-yet-acknowledged.
    pub fn liveBlocks(self: *const Transcript) usize {
        return self.blocks.items.len;
    }

    /// Blocks still in the mutable view (never retired). These are the
    /// only ones a repaint may touch.
    pub fn mutableBlocks(self: *const Transcript) usize {
        return self.blocks.items.len - self.staged;
    }

    /// Rows of a retained block, or null once it has been committed.
    /// The view survives metadata growth, but not that block's commitment or `deinit`.
    pub fn rowsOf(self: *const Transcript, id: u64) ?[]const []const u8 {
        for (self.blocks.items) |b| {
            if (b.id == id) return b.rows;
        }
        return null;
    }

    /// The retained state of `id`; `null` when never pushed or already committed and released.
    pub fn stateOf(self: *const Transcript, id: u64) ?State {
        for (self.blocks.items) |b| {
            if (b.id == id) return b.state;
        }
        return null;
    }

    /// Options in force (the budget and the bound are part of the
    /// contract a port cites).
    pub fn options(self: *const Transcript) Options {
        return self.opts;
    }
    /// Empty the frame delta, keeping the buffers for reuse. The write
    /// cursor (`staged`) is deliberately NOT touched: a delta that
    /// failed to assemble must retire again, in the same order, on the
    /// next call. Nothing is pending afterwards, so the next `retire`
    /// assembles a fresh delta.
    fn clearDelta(self: *Transcript) void {
        self.delta_rows.clearRetainingCapacity();
        self.delta_ids.clearRetainingCapacity();
        self.delta_blocks = 0;
        self.delta_sealed = true;
    }

    fn freeBlock(self: *Transcript, b: Block) void {
        for (b.rows) |row| self.gpa.free(row);
        self.gpa.free(b.rows);
    }
};

test {
    std.testing.refAllDecls(@This());
}

const testing = std.testing;

/// A deterministic clock: every reading advances by a fixed step, so
/// the budget is exact and the test never sleeps.
const FakeClock = struct {
    base_ns: u64 = 1_000,
    step_ns: u64,
    reads: usize = 0,

    fn clock(self: *FakeClock) Clock {
        return .{ .ctx = self, .now_ns = now };
    }

    fn now(ctx: *const anyopaque) u64 {
        const self: *FakeClock = @ptrCast(@alignCast(@constCast(ctx)));
        const ns = self.base_ns + self.reads * self.step_ns;
        self.reads += 1;
        return ns;
    }
};

fn makeTranscript(opts: Transcript.Options) !Transcript {
    return Transcript.init(testing.allocator, opts);
}

test "transcript: a block walks active -> settled -> committed" {
    var t = try makeTranscript(.{});
    defer t.deinit();

    const id = try t.push(&.{ "one", "two" });
    try testing.expectEqual(@as(?State, .active), t.stateOf(id));
    // The rows were copied: the caller's slice is free again.
    var one = "one".*;
    var two = "two".*;
    const caller = [_][]const u8{ &one, &two };
    _ = try t.push(&caller);
    one[0] = 'X';

    try t.settle(id);
    try testing.expectEqual(@as(?State, .settled), t.stateOf(id));

    var delta: Delta = .{};
    var clock: FakeClock = .{ .step_ns = 1_000_000 };
    try t.retire(clock.clock(), &delta);
    try testing.expectEqual(@as(usize, 1), delta.blocks);
    try testing.expectEqualStrings("one", delta.rows[0]);
    try testing.expectEqualStrings("two", delta.rows[1]);
    // The second block is still active, so it is not in the delta and it
    // is still in the mutable view.
    try testing.expectEqual(@as(usize, 2), delta.rows.len);
    try testing.expectEqual(@as(usize, 1), t.mutableBlocks());

    try t.sealDelta(7);
    try t.commitReceipt(7);
    try testing.expectEqual(@as(?State, null), t.stateOf(id));
    try testing.expectEqual(@as(usize, 1), t.liveBlocks());
}

test "transcript: retirement never crosses an unsettled block" {
    var t = try makeTranscript(.{});
    defer t.deinit();
    const a = try t.push(&.{"a"});
    const b = try t.push(&.{"b"});
    const c = try t.push(&.{"c"});

    // The product settled b and c but not a: order means nothing leaves.
    try t.settle(b);
    try t.settle(c);
    var delta: Delta = .{};
    var clock: FakeClock = .{ .step_ns = 1_000_000 };
    try t.retire(clock.clock(), &delta);
    try testing.expect(delta.isEmpty());
    try testing.expectEqual(@as(usize, 3), t.mutableBlocks());

    // Settling a releases the prefix, in order.
    try t.settle(a);
    try t.retire(clock.clock(), &delta);
    try testing.expectEqual(@as(usize, 3), delta.blocks);
    try testing.expectEqual(a, delta.ids[0]);
    try testing.expectEqual(b, delta.ids[1]);
    try testing.expectEqual(c, delta.ids[2]);
    try testing.expectEqualStrings("a", delta.rows[0]);
    try testing.expectEqualStrings("c", delta.rows[2]);
    try testing.expectEqual(@as(usize, 0), t.mutableBlocks());
}

test "transcript: the budget defers the remainder, order intact" {
    // 4 ms per reading with an 8 ms budget: two blocks per frame.
    var t = try makeTranscript(.{ .budget_ns = 8 * std.time.ns_per_ms });
    defer t.deinit();
    for (0..5) |i| {
        const text = try std.fmt.allocPrint(testing.allocator, "row{d}", .{i});
        defer testing.allocator.free(text);
        const id = try t.push(&.{text});
        try t.settle(id);
    }

    var clock: FakeClock = .{ .step_ns = 4 * std.time.ns_per_ms };
    var delta: Delta = .{};
    var frame: u64 = 0;
    try t.retire(clock.clock(), &delta);
    try testing.expectEqual(@as(usize, 2), delta.blocks);
    try testing.expectEqualStrings("row0", delta.rows[0]);
    try testing.expectEqualStrings("row1", delta.rows[1]);
    try t.sealDelta(frame);

    // The next frame's delta continues where the budget stopped — it
    // never re-sends and never reorders.
    frame += 1;
    try t.retire(clock.clock(), &delta);
    try testing.expectEqual(@as(usize, 2), delta.blocks);
    try testing.expectEqualStrings("row2", delta.rows[0]);
    try testing.expectEqualStrings("row3", delta.rows[1]);
    try t.sealDelta(frame);

    frame += 1;
    try t.retire(clock.clock(), &delta);
    try testing.expectEqual(@as(usize, 1), delta.blocks);
    try testing.expectEqualStrings("row4", delta.rows[0]);
    try t.sealDelta(frame);

    frame += 1;
    try t.retire(clock.clock(), &delta);
    try testing.expect(delta.isEmpty());
}

test "transcript: a zero budget still retires one block per frame" {
    var t = try makeTranscript(.{ .budget_ns = 0 });
    defer t.deinit();
    for (0..3) |_| {
        const id = try t.push(&.{"r"});
        try t.settle(id);
    }
    var clock: FakeClock = .{ .step_ns = 0 };
    var delta: Delta = .{};
    for (0..3) |i| {
        try t.retire(clock.clock(), &delta);
        try testing.expectEqual(@as(usize, 1), delta.blocks);
        try testing.expectEqual(i + 1, delta.ids[0]);
        try t.sealDelta(@as(u64, i) + 1);
    }
    try t.retire(clock.clock(), &delta);
    try testing.expect(delta.isEmpty());
}

test "transcript: a block settled after retirement reaches the NEXT frame" {
    var t = try makeTranscript(.{ .budget_ns = 0 });
    defer t.deinit();
    var clock: FakeClock = .{ .step_ns = 0 };
    var delta: Delta = .{};

    const a = try t.push(&.{"a"});
    try t.settle(a);
    try t.retire(clock.clock(), &delta);
    try testing.expectEqual(@as(usize, 1), delta.blocks);
    try t.sealDelta(1);

    // Streaming continues while a is retired; the delta is replaced,
    // not appended to.
    const b = try t.push(&.{"b"});
    try t.settle(b);
    try t.retire(clock.clock(), &delta);
    try testing.expectEqual(@as(usize, 1), delta.blocks);
    try testing.expectEqual(b, delta.ids[0]);
    try testing.expectEqualStrings("b", delta.rows[0]);
}

test "transcript: a delta nobody sealed is re-emitted, not replaced" {
    var t = try makeTranscript(.{ .budget_ns = 0 });
    defer t.deinit();
    var clock: FakeClock = .{ .step_ns = 0 };
    var delta: Delta = .{};

    const a = try t.push(&.{"a"});
    try t.settle(a);
    try t.retire(clock.clock(), &delta);
    try testing.expectEqual(@as(usize, 1), delta.blocks);

    // The ledger sink refused the batch, so nothing was sealed. More
    // blocks settle while the caller retries: the unsealed delta is
    // still this frame's, so the retry hands back the SAME rows and
    // the staged cursor does not move.
    const b = try t.push(&.{"b"});
    try t.settle(b);
    var retry: Delta = .{};
    try t.retire(clock.clock(), &retry);
    try testing.expectEqual(@as(usize, 1), retry.blocks);
    try testing.expectEqual(a, retry.ids[0]);
    try testing.expectEqualStrings("a", retry.rows[0]);
    try testing.expectEqual(@as(usize, 1), t.mutableBlocks());

    // A seal of that delta takes it; only then does the next frame
    // advance to the block that settled while the caller was retrying.
    try t.sealDelta(1);
    try t.retire(clock.clock(), &delta);
    try testing.expectEqual(@as(usize, 1), delta.blocks);
    try testing.expectEqual(b, delta.ids[0]);
    try testing.expectEqualStrings("b", delta.rows[0]);

    // Sealing the same delta twice is a caller bug, not a second
    // receipt over the same blocks.
    try t.sealDelta(2);
    try testing.expectError(error.DeltaNotPending, t.sealDelta(2));
}

test "transcript: a live block that is never settled trips the bound" {
    var t = try makeTranscript(.{ .max_live_blocks = 2, .budget_ns = 0 });
    defer t.deinit();
    const a = try t.push(&.{"a"});
    const b = try t.push(&.{"b"});
    // The transcript does NOT settle for the product: it reports the
    // bound instead of guessing finality.
    try testing.expectError(error.LiveCapacityExceeded, t.push(&.{"c"}));
    try testing.expectEqual(@as(usize, 2), t.liveBlocks());
    try testing.expectEqual(@as(?State, .active), t.stateOf(b));

    // Settling only the newer block does not help: order holds the
    // prefix back, so the bound stays.
    try t.settle(b);
    var clock: FakeClock = .{ .step_ns = 0 };
    var delta: Delta = .{};
    try t.retire(clock.clock(), &delta);
    try testing.expect(delta.isEmpty());
    try testing.expectError(error.LiveCapacityExceeded, t.push(&.{"c"}));

    // Settling the older block releases the prefix; the receipt frees it.
    // A zero budget still retires one block per frame, so the commit
    // frees exactly that one.
    try t.settle(a);
    try t.retire(clock.clock(), &delta);
    try testing.expectEqual(@as(usize, 1), delta.blocks);
    try testing.expectEqualStrings("a", delta.rows[0]);
    try t.sealDelta(1);
    try t.commitReceipt(1);
    try testing.expectEqual(@as(usize, 1), t.liveBlocks());
    // Ids are monotonic and never reused, even after a commit.
    const c = try t.push(&.{"c"});
    try testing.expectEqual(@as(u64, 3), c);
}

test "transcript: each receipt owns exactly the blocks it sealed" {
    var t = try makeTranscript(.{ .budget_ns = 0 });
    defer t.deinit();
    var clock: FakeClock = .{ .step_ns = 0 };
    var delta: Delta = .{};
    const rows = [_][]const u8{ "r1", "r2", "r3", "r4" };
    for (rows) |row| {
        const id = try t.push(&.{row});
        try t.settle(id);
        try t.retire(clock.clock(), &delta);
        try t.sealDelta(id);
    }
    try testing.expectEqual(@as(usize, 4), t.liveBlocks());
    try testing.expectError(error.UnknownReceipt, t.commitReceipt(999));

    // Receipts arrive out of write order, and each one frees ITS block
    // only: the rows of every other retired block stay owned and
    // readable until their own receipt lands.
    try t.commitReceipt(3);
    try testing.expectEqual(@as(?State, null), t.stateOf(3));
    try testing.expectEqual(@as(usize, 3), t.liveBlocks());
    for ([_]u64{ 1, 2, 4 }) |id| {
        try testing.expectEqual(@as(?State, .settled), t.stateOf(id));
        try testing.expectEqual(@as(usize, 1), t.rowsOf(id).?.len);
    }

    try t.commitReceipt(4);
    try t.commitReceipt(1);
    try testing.expectEqual(@as(usize, 1), t.liveBlocks());
    try testing.expect(t.rowsOf(2) != null);
    try t.commitReceipt(2);
    try testing.expectEqual(@as(usize, 0), t.liveBlocks());
    try testing.expectEqual(@as(usize, 0), t.mutableBlocks());
    // A receipt is consumed once: replaying it frees nothing.
    try testing.expectError(error.UnknownReceipt, t.commitReceipt(2));
}

test "transcript: an unknown or already-settled id is refused" {
    var t = try makeTranscript(.{});
    defer t.deinit();
    try testing.expectError(error.UnknownBlock, t.settle(42));
    const id = try t.push(&.{"a"});
    try t.settle(id);
    try testing.expectError(error.UnknownBlock, t.settle(id));
    try testing.expectEqual(@as(?State, .settled), t.stateOf(id));
}

test "transcript: sealing an empty delta is not a receipt" {
    var t = try makeTranscript(.{ .budget_ns = 0 });
    defer t.deinit();
    var clock: FakeClock = .{ .step_ns = 0 };
    var delta: Delta = .{};
    try t.retire(clock.clock(), &delta);
    try testing.expect(delta.isEmpty());
    try testing.expectError(error.DeltaNotPending, t.sealDelta(1));
    try testing.expectError(error.UnknownReceipt, t.commitReceipt(1));
    try testing.expectEqual(@as(usize, 0), t.liveBlocks());
}

test "transcript: the delta accounts for its own byte cost" {
    var t = try makeTranscript(.{ .budget_ns = 0 });
    defer t.deinit();
    var clock: FakeClock = .{ .step_ns = 0 };
    var delta: Delta = .{};
    const id = try t.push(&.{ "abcd", "ef" });
    try t.settle(id);
    try t.retire(clock.clock(), &delta);
    try testing.expectEqual(@as(usize, 6), delta.byteLen());
}

// A settled block with no rows still needs a receipt before its storage slot is released.
test "transcript: zero-row blocks produce a commit-capable delta" {
    var t = try makeTranscript(.{});
    defer t.deinit();
    const id = try t.push(&.{});
    try t.settle(id);
    var clock: FakeClock = .{ .step_ns = 0 };
    var delta: Delta = .{};
    try t.retire(clock.clock(), &delta);
    try testing.expect(!delta.isEmpty());
    try testing.expectEqualSlices(u64, &.{id}, delta.ids);
    try t.sealDelta(9);
    try t.commitReceipt(9);
    try testing.expectEqual(@as(usize, 0), t.liveBlocks());
}
