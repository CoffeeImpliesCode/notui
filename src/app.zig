//! App(Model): the Elm-style runtime loop on top of the shipped
//! primitives (framework-contract.md §5).
//!
//! Wiring: `Tty.init → makeRaw → Caps.detect → Region.init → loop →
//! Region.exit → caps.restore → tty.restore` (architecture §3), with an
//! Elm-shaped Model contract on top (`Msg`/`init`/`update`/`view`).
//! Single-threaded: the loop is fps-paced `Reader.nextTimeout` → filter
//! to Msg → update → processCmd → render-on-demand with the View
//! signature idle skip. Worker-thread patterns stay APP-level — the
//! worker publishes to a slot; the main tick reads it and calls `send`.
//! `send` from a worker thread must be guarded by a user mutex (§8).

const std = @import("std");
const posix = std.posix;
const Tty = @import("tty.zig").Tty;
const Region = @import("region.zig").Region;
const ResizeMode = @import("region.zig").ResizeMode;
const Reader = @import("input.zig").Reader;
const caps = @import("caps.zig");
const emit = @import("emit.zig");
const Event = @import("event.zig").Event;
const Key = @import("Key.zig");
const Buffer = @import("buffer.zig").Buffer;
const Parser = @import("Parser.zig");
const builtin = @import("builtin");
const view_mod = @import("view.zig");
const output = @import("output.zig");
const transcript = @import("transcript.zig");
const watchdog = @import("watchdog.zig");

/// Adaptive frame pacing: a nominal input cadence plus a ~50% duty cap.
/// The loop waits `nominal` for input; when the last frame cost more
/// than half of that, the wait grows to twice the measured cost, so
/// composing frames can occupy at most ~50% of the loop's time however
/// slow the renderer is (roadmap intro: cadence + duty cycle +
/// backpressure). A slow frame therefore costs animation smoothness,
/// never input latency.
pub const Pacer = struct {
    /// Cost of the last measured frame, in nanoseconds.
    last_cost_ns: u64 = 0,
    /// Frames measured (telemetry).
    samples: u64 = 0,
    /// Longest single frame cost seen (bench p-max).
    worst_ns: u64 = 0,

    pub fn noteFrameCost(self: *Pacer, cost_ns: u64) void {
        self.last_cost_ns = cost_ns;
        self.samples += 1;
        self.worst_ns = @max(self.worst_ns, cost_ns);
    }

    /// The input wait in milliseconds. `fps == 0` blocks on input.
    pub fn delayMs(self: *const Pacer, fps: u32) i32 {
        if (fps == 0) return -1;
        const nominal_ms: i32 = @max(1, @as(i32, @intCast(1000 / fps)));
        const nominal_ns = @as(u64, @intCast(nominal_ms)) * std.time.ns_per_ms;
        if (self.last_cost_ns * 2 <= nominal_ns) return nominal_ms;
        const wanted: u64 = (self.last_cost_ns * 2) / std.time.ns_per_ms;
        return @max(nominal_ms, @as(i32, @intCast(@min(wanted, @as(u64, std.math.maxInt(i32))))));
    }
};

/// Per-frame measurements, published by the bench and the debug server.
/// Every field is a real observation of the frame path, not an estimate.
pub const FrameStats = struct {
    /// Frames composed since the session started.
    frames: u64 = 0,
    /// Cells that differed from the previous frame: the damage the diff
    /// had to paint.
    dirty_cells: usize = 0,
    /// Bytes staged into the output queue for this frame.
    staged_bytes: usize = 0,
    /// Bytes the transport accepted for this frame.
    written_bytes: usize = 0,
    /// Largest pending output at any point in the session.
    peak_pending: usize = 0,
    /// Nanoseconds the last frame cost (composition plus submit).
    frame_cost_ns: u64 = 0,
    /// Frames deferred by output backpressure.
    deferred_frames: u64 = 0,
};

/// The framework surface, re-exported from app.zig (framework-contract.md
/// file layout): `App` itself plus the Context/View/Cmd types it threads.
pub const Context = @import("context.zig").Context;
pub const View = @import("view.zig").View;
pub const Cmd = @import("command.zig").Cmd;

/// The Model contract, comptime-checked by `App`: `Msg`, `init`, `update`
/// and `view` must all be declared. Returns the list of missing members
/// (empty when the model satisfies the contract). A module-level helper
/// so the compile-error behavior is testable.
fn modelViolations(comptime Model: type) []const []const u8 {
    var list: []const []const u8 = &.{};
    if (!@hasDecl(Model, "Msg")) list = list ++ &[_][]const u8{"Msg"};
    if (!@hasDecl(Model, "init")) list = list ++ &[_][]const u8{"init"};
    if (!@hasDecl(Model, "update")) list = list ++ &[_][]const u8{"update"};
    if (!@hasDecl(Model, "view")) list = list ++ &[_][]const u8{"view"};
    return list;
}

/// The Elm-style app runner. `Model` MUST declare (comptime-checked
/// below):
///
///   pub const Msg = <type>;                                   // the message type
///   pub fn init(allocator: std.mem.Allocator) !struct {      // initial state
///       model: Model,                                        //   + the
///       cmd: Cmd(Msg),                                       //   initial effect
///   };
///   pub fn update(self: *Model, msg: Msg, ctx: *Context) !Cmd(Msg);
///   pub fn view(self: *const Model, ctx: *Context) View;
///
/// `start` owns init: it builds the model via `Model.init(gpa)` and runs
/// the initial Cmd through the same effect path as queued msgs — an
/// init-armed `Cmd.every`/`Cmd.tick` timer is live before the first
/// loop iteration, so a demo can animate with no input.
///
/// Single-threaded. Worker-thread patterns (the REPL's eval worker
/// writing a result slot polled each tick, skript_repl.zig:379-385) stay
/// APP-level: the worker publishes to a slot; the main tick reads it and
/// calls `send`/update. `send` from a worker thread must be guarded by a
/// user mutex (the framework is otherwise single-threaded; see
/// framework-contract.md §8).
pub fn App(comptime Model: type) type {
    comptime {
        const violations = modelViolations(Model);
        if (violations.len > 0) {
            var msg: []const u8 = "Model violates the app contract; missing: ";
            for (violations) |v| msg = msg ++ v ++ " ";
            @compileError(msg);
        }
    }
    const Msg = Model.Msg;

    return struct {
        pub const Options = struct {
            /// Loop pacing. fps > 0: `Reader.nextTimeout(1000/fps)` paces
            /// timed ticks. fps == 0: block on input (`Reader.next`), no
            /// timed ticks — animation must be driven by `every` Cmds.
            fps: u32 = 60,
            /// Initial inline band height (Region.Options.height,
            /// region.zig:178).
            region_height: u16 = 3,
            /// Region space reservation (Region.Options.append_lines).
            append_lines: bool = true,
            /// Optional default event→Msg translator (also settable via
            /// setFilter).
            filter: ?*const fn (*Context, Event) ?Msg = null,
            /// Bounded output staging (roadmap B1): `capacity` is the
            /// hard bound on staged bytes, `watermark` the point at
            /// which the App stops composing frames until the terminal
            /// drains.
            output: output.OutputQueue.Options = .{},
            /// Width-change behaviour for the inline band (C2).
            resize_mode: ResizeMode = .append,
        };

        const Self = @This();
        pub const Ctx = Context;
        pub const Vw = View(Model);

        model: Model,
        opts: Options,

        // framework-owned runtime (populated by start/run)
        io: ?std.Io = null,
        gpa: std.mem.Allocator = undefined,
        tty: ?Tty = null,
        parser: Parser = .{},
        caps: ?caps.Capabilities = null,
        region: ?Region = null,
        reader: ?Reader = null,
        arena: ?std.heap.ArenaAllocator = null, // app arena (long-lived, never reset)
        scratch: ?std.heap.ArenaAllocator = null, // per-tick scratch arena
        /// Bounded pending-byte queue in front of the terminal (B1).
        /// Every frame is staged here and submitted with one nonblocking
        /// write attempt; bytes the terminal has not taken stay queued
        /// and composition stops at the watermark.
        out: ?output.OutputQueue = null,

        // loop state
        running: bool = false,
        /// Terminal modes currently active (diffed per frame).
        modes: view_mod.Modes = .{},
        /// Signature of the last rendered View (idle-frame skip).
        last_sig: u64 = std.math.maxInt(u64),
        frame_count: u64 = 0,
        frame_delta: std.Io.Duration = .zero,
        /// Set by update/view/cmds; forces a repaint this tick.
        render_requested: bool = false,
        last_tick: ?std.Io.Timestamp = null,
        msg_queue: std.ArrayListUnmanaged(Msg) = .empty,
        filter: ?*const fn (*Context, Event) ?Msg = null,
        title: ?[]const u8 = null,
        /// Absolute deadline armed by `Cmd.tick` (one-shot Msg.tick).
        tick_deadline: ?std.Io.Timestamp = null,
        /// Interval (ms) armed by `Cmd.every` (periodic Msg.tick).
        every_interval: ?u32 = null,
        /// Last periodic Msg.tick dispatch time.
        last_fire: ?std.Io.Timestamp = null,

        /// Adaptive pacing state (~50% duty cap).
        pacer: Pacer = .{},
        /// Loop watchdog (F3): the previous frame is observed BEFORE
        /// this one re-pings, so a stall inside a frame is caught rather
        /// than swallowed by the reset.
        watchdog: watchdog.Watchdog = .init(watchdog.default_budget_ns),
        /// Per-frame measurements for the bench and the debug server.
        frame_stats: FrameStats = .{},
        /// Streaming transcript (C3), allocated only by
        /// `initTranscript`. The product settles blocks; the App retires
        /// them inside the frame budget, writes each delta as one ledger
        /// batch, and commits the blocks when the transport accepted the
        /// receipt.
        transcript: ?transcript.Transcript = null,

        // ── construction ──
        /// The model is NOT passed in: `start` owns init — it calls
        /// `Model.init(gpa)` and stores the returned model (Elm-style, the
        /// runtime drives init so the initial Cmd arms effects).
        pub fn init() Self {
            return initWithOptions(.{});
        }
        pub fn initWithOptions(opts: Options) Self {
            return .{ .model = undefined, .opts = opts, .filter = opts.filter };
        }

        // ── lifecycle ──
        /// Open /dev/tty, enter raw mode, detect capabilities, init the
        /// region and the app arena. Non-TTY stdin degrades: no raw mode,
        /// no caps, a plain single frame (region sync_output = false
        /// path, region.zig:262-274).
        pub fn start(self: *Self, io: std.Io, gpa: std.mem.Allocator) !void {
            self.io = io;
            self.gpa = gpa;
            if (Tty.isTty(std.posix.STDIN_FILENO)) {
                self.tty = try Tty.init(io);
                errdefer {
                    self.tty.?.deinit();
                    self.tty = null;
                }
                try self.tty.?.makeRaw();
                try self.startTty(io, gpa);
            } else {
                try self.startPlain(gpa);
            }
            // Elm contract: init arms the initial effect. The runtime
            // (region/arena/tty) exists now, so the initial Cmd is
            // processed through the same path as queued msgs (timer Cmds
            // anchor at this moment; the first fire is one interval out).
            try self.processInit();
        }

        /// Build the initial model via `Model.init` and run its initial
        /// Cmd through the same effect path as queued msgs — so an
        /// init-armed `every`/`tick` timer is live before the first tick.
        /// Called by `start`; `w` is null in the degraded (non-TTY) path,
        /// matching `tick`'s writer rule (mode/title writes skipped).
        fn processInit(self: *Self) !void {
            const init_res = try Model.init(self.gpa);
            self.model = init_res.model;
            var ictx = self.makeCtx();
            const w: ?*std.Io.Writer = if (self.tty != null) self.tty.?.writer() else null;
            try self.processCmd(init_res.cmd, &ictx, w);
            self.render_requested = ictx.render_requested;
        }

        /// One loop iteration: timers → read one event (paced to fps) →
        /// filter to Msg → update → processCmd → view → render decision
        /// (with the View-signature idle skip) → mode diff → draw +
        /// render. Valid after `start`.
        pub fn tick(self: *Self) !void {
            // 1. Per-tick scratch: reset the scratch arena (the app arena
            //    backing `ctx.frame_arena` is NEVER reset — the frame
            //    Buffer's cells borrow their grapheme slices from it,
            //    cell.zig); render_requested clears so each frame
            //    re-declares.
            if (self.scratch) |*s| _ = s.reset(.retain_capacity);
            self.render_requested = false;

            const io = self.io.?;
            const now = std.Io.Timestamp.now(io, .awake);
            self.frame_delta = if (self.last_tick) |lt| lt.durationTo(now) else .zero;
            self.last_tick = now;
            self.frame_count += 1;

            // 1b. Watchdog: observe the PREVIOUS frame before this one
            //     re-pings, so a stall inside a frame is caught instead
            //     of being swallowed by the reset.
            if (self.watchdog.tripped(now)) try self.degradeStall();
            self.watchdog.ping(now);

            // 2. Timers: the one-shot `tick` deadline and the periodic
            //    `every` timer dispatch `Msg.tick` through the queue.
            if (self.tick_deadline) |dl| {
                if (now.nanoseconds >= dl.nanoseconds) {
                    self.tick_deadline = null;
                    try self.enqueueTick();
                }
            }
            if (self.every_interval) |interval_ms| {
                const last = self.last_fire orelse now;
                if (now.nanoseconds - last.nanoseconds >=
                    @as(i96, interval_ms) * std.time.ns_per_ms)
                {
                    self.last_fire = now;
                    try self.enqueueTick();
                }
            }

            // 3. Read one event (paced to fps; pipe EOF quits).
            var ev: ?Event = null;
            if (self.reader) |*r| {
                // Adaptive pacing: the nominal cadence, widened when the
                // last frame cost more than half of it (~50% duty cap).
                const timeout: i32 = self.pacer.delayMs(self.opts.fps);
                ev = r.nextTimeout(timeout) catch |err| blk: {
                    switch (err) {
                        error.EndOfStream => {
                            self.quit();
                            break :blk null;
                        },
                        else => return err,
                    }
                };
            }

            // 4. Dispatch the event: winsize resizes the inline region;
            //    cpr feeds the region's anchor correction (the framework
            //    owns the region — it is NOT forwarded to the model, so
            //    the model surface stays clean); other events go through
            //    the filter to a Msg (null = the event is dropped — the
            //    framework never synthesizes one).
            var dispatched = ev != null;
            if (ev) |e| switch (e) {
                .cpr => |pos| {
                    // The reply to the region's own queryCursor: correct
                    // the drift (region.zig applyCpr). Bookkeeping only —
                    // no forced repaint; the next frame renders at the
                    // corrected anchor.
                    if (self.region) |*r| try r.applyCpr(pos.row, pos.col);
                },
                .winsize => |wsz| {
                    if (self.region) |*r| try r.resize(wsz.cols, r.height);
                    self.render_requested = true;
                },
                else => {
                    if (self.filter) |f| {
                        var fctx = self.makeCtx();
                        if (f(&fctx, e)) |m| try self.msg_queue.append(self.gpa, m);
                        self.render_requested = fctx.render_requested;
                    }
                },
            };

            // 5. The output writer for this tick's effects: the tty writer
            //    when interactive; null in the degraded (non-TTY) path —
            //    that session's single plain frame is rendered by `run`
            //    at exit (§5.5), never from tick.
            const w: ?*std.Io.Writer = if (self.tty != null) self.tty.?.writer() else null;

            // 6. Drain the queue: update + processCmd per msg (batch/
            //    sequence/msg recurse inside processCmd).
            while (self.msg_queue.items.len > 0) {
                dispatched = true;
                const msg = self.msg_queue.orderedRemove(0);
                var uctx = self.makeCtx();
                const cmd = try Model.update(&self.model, msg, &uctx);
                self.render_requested = uctx.render_requested;
                try self.processCmd(cmd, &uctx, w);
                self.render_requested = uctx.render_requested;
            }

            // 7. The declarative frame.
            var ctx = self.makeCtx();
            const vw = Model.view(&self.model, &ctx);
            self.render_requested = ctx.render_requested;

            // 8. Frame-level declaration: the dynamic band height. The
            //    terminal title is staged inside the frame (step 9) so
            //    it shares the frame's single write.
            if (vw.height != 0 and vw.height != self.region.?.height) {
                try self.region.?.setHeight(vw.height);
            }

            // 9. The frame: staged into the bounded output queue and
            //    submitted once (see `renderStep`). The degraded
            //    (non-TTY) session renders its single plain frame in
            //    `run`, never from tick.
            if (self.tty != null) {
                _ = try self.renderStep(vw, &ctx, dispatched, output.Transport.from(&self.tty.?));
            }
        }

        /// One frame: stage the mode diff, the title and the band into
        /// the output queue, commit the staging, then submit it with a
        /// SINGLE nonblocking write attempt. Returns the bytes the
        /// transport accepted.
        ///
        /// Backpressure (B1): at the watermark the frame is neither
        /// composed nor committed — the render stays requested and the
        /// identical frame is retried next tick after a drain. Input is
        /// read on every tick regardless, so a slow reader costs
        /// animation latency, never responsiveness and never history.
        ///
        /// Idle tick: a tick that wants no new frame still drains the
        /// queue, so a frame the transport accepted only in part stops
        /// being half-painted without waiting for the next repaint.
        ///
        /// Failure discipline (B2): a composition that overflows the
        /// queue aborts before any frame state advances (no prev, no
        /// dirty flag, no ledger receipt, no last_sig), so the retry
        /// paints the whole frame again.
        /// Terminal modes follow the same rule: the mode diff is staged
        /// with the frame, so a failed composition restores the mode
        /// state it would have advanced and the retry re-emits it.
        ///
        /// Acknowledgement (C1): the ledger is acknowledged exactly when
        /// the transport has taken every staged byte and never before,
        /// and the transcript block behind a receipt is committed then —
        /// at enqueue time the block is merely out of the mutable view.
        ///
        /// The error set is inferred because `View.draw` is an
        /// `anyerror` callback owned by the model.
        fn renderStep(self: *Self, vw: Vw, ctx: *Context, force: bool, sink: output.Transport) !usize {
            const q = if (self.out) |*queue| queue else return 0;
            // The stats describe THIS attempt, so a deferred frame never
            // reports the previous one's bytes.
            self.frame_stats.staged_bytes = 0;
            self.frame_stats.written_bytes = 0;
            self.frame_stats.dirty_cells = 0;
            self.frame_stats.frame_cost_ns = 0;

            const sig = view_mod.signature(vw);
            const mode_pending = vw.mouse != self.modes.mouse or
                vw.hide_cursor != self.modes.hide_cursor;
            const wanted = force or self.render_requested or sig != self.last_sig or
                mode_pending or vw.print_above or self.regionPending();
            // No new frame is owed, yet an earlier one may sit in the
            // queue half-written (a short write or a would-block
            // transport accepted part of it). The idle tick drains that
            // tail — one nonblocking attempt, no draw — instead of
            // leaving the band truncated until the next repaint.
            if (!wanted) return self.drainQueued(q, sink);

            if (!q.canCompose()) {
                self.frame_stats.deferred_frames += 1;
                self.render_requested = true;
                return self.drainQueued(q, sink);
            }

            const started = std.Io.Timestamp.now(self.io.?, .awake);
            const pending_before = q.pending();
            const dirty = try self.stageFrame(vw, ctx);
            q.commitFrame();
            self.last_sig = sig;
            // This frame's own bytes, measured BEFORE the drain: a
            // drain can empty the queue entirely (accepting older
            // frames' bytes too), and `pending` would then read 0 for a
            // frame that is still pending.
            const staged = q.pending() - pending_before;

            const taken = try q.drain(sink);
            const cost_ns: u64 = @intCast(@max(
                0,
                started.durationTo(std.Io.Timestamp.now(self.io.?, .awake)).nanoseconds,
            ));
            self.pacer.noteFrameCost(cost_ns);
            self.frame_stats.frames += 1;
            self.frame_stats.dirty_cells = dirty;
            self.frame_stats.staged_bytes = staged;
            self.frame_stats.written_bytes = taken;
            self.frame_stats.peak_pending = q.peak_pending;
            self.frame_stats.frame_cost_ns = cost_ns;
            // The transport took every staged byte: the ledger receipts
            // are acknowledged exactly once (C1) and the transcript
            // blocks that produced them are committed (C3).
            if (q.pending() == 0) self.commitHistory();
            return taken;
        }

        /// Compose the frame in progress — the mode diff, the title and
        /// the band — into the output queue. Nothing is published here
        /// (`commitFrame` does that), so a failure rolls the staged
        /// bytes AND the mode state back together: the retry emits the
        /// very same mode sequences instead of declaring a mode the
        /// terminal never received. Returns the damage the frame paints.
        fn stageFrame(self: *Self, vw: Vw, ctx: *Context) !usize {
            const q = &self.out.?;
            const modes_before = self.modes;
            errdefer {
                q.abortFrame();
                self.modes = modes_before;
                self.render_requested = true;
            }
            q.beginFrame();
            const w = q.writer();
            _ = try view_mod.applyModeDiff(vw, w, &self.modes);
            if (vw.title) |vt| try self.stageTitle(vt, w);
            self.region.?.setCursorHidden(vw.hide_cursor);
            try vw.draw(&self.model, ctx, &self.region.?.cur);
            const dirty = self.region.?.dirtyCells();
            try self.retireTranscript();
            try self.region.?.render(w);
            if (q.frameOverflowed()) return error.FrameTooLarge;
            return dirty;
        }

        /// One nonblocking drain for a tick that composes no frame: the
        /// queued bytes leave, the accepted count is this attempt's
        /// `written_bytes`, and the ledger receipts are acknowledged
        /// only once the queue has taken every staged byte (C1).
        fn drainQueued(self: *Self, q: *output.OutputQueue, sink: output.Transport) !usize {
            if (q.pending() == 0) return 0;
            const taken = try q.drain(sink);
            self.frame_stats.written_bytes = taken;
            if (q.pending() == 0) self.commitHistory();
            return taken;
        }

        /// One frame without input — the headless seam the bench and the
        /// debug server drive (`tick` also reads input, so it is not
        /// usable headlessly). Runs view + draw, stages the frame into the
        /// output queue, and attempts ONE drain into `sink`. Returns the
        /// bytes the transport accepted; 0 means the frame is still
        /// pending and the next call continues it.
        pub fn frameHeadless(self: *Self, sink: output.Transport) !usize {
            if (self.scratch) |*s| _ = s.reset(.retain_capacity);
            self.render_requested = false;
            var ctx = self.makeCtx();
            const vw = Model.view(&self.model, &ctx);
            if (vw.height != 0 and vw.height != self.region.?.height) {
                try self.region.?.setHeight(vw.height);
            }
            return self.renderStep(vw, &ctx, true, sink);
        }

        /// Allocate the streaming transcript (C3). The 8 ms retirement
        /// budget and the 256-block live bound are the defaults; an app
        /// without streaming output never allocates one.
        pub fn initTranscript(self: *Self, gpa: std.mem.Allocator, opts: transcript.Transcript.Options) !void {
            self.transcript = try transcript.Transcript.init(gpa, opts);
        }

        /// Retire settled transcript blocks (C3) and stage the delta as
        /// one ledger batch. Finality is the product's decision: this only
        /// moves blocks the product settled, oldest first, within the
        /// frame's time budget, and defers the rest to the next frame.
        ///
        /// The three steps are one transaction. `retire` reserves the
        /// seal before a block leaves the mutable view and keeps an
        /// unsealed delta alive, `writeTranscript` is the only step
        /// that can fail, and a failure here aborts the frame with the
        /// delta still pending: the next frame re-emits the same rows
        /// and the same block ids, so a refused batch is retried, never
        /// lost and never written twice.
        fn retireTranscript(self: *Self) !void {
            const t = if (self.transcript) |*t| t else return;
            var delta: transcript.Transcript.Delta = .{};
            const io = self.io.?;
            try t.retire(transcript.Clock.fromIo(&io), &delta);
            if (delta.isEmpty()) return;
            const receipt = try self.region.?.writeTranscript(delta.rows);
            try t.sealDelta(receipt);
        }

        /// The queue drained empty: acknowledge the ledger receipts and
        /// commit the transcript blocks behind them. A receipt the
        /// transcript does not know is reported, never silently dropped.
        fn commitHistory(self: *Self) void {
            const receipts = if (self.region) |*r| r.acknowledgeDrained() else return;
            const t = if (self.transcript) |*t| t else return;
            for (receipts) |id| {
                t.commitReceipt(id) catch |err| std.log.scoped(.notui_app).warn(
                    "transcript receipt {d} is not pending: {s}",
                    .{ id, @errorName(err) },
                );
            }
        }

        /// start + loop until quit + teardown (Region.exit → caps.restore
        /// → tty.restore) + deinit. The framework's normal entry point.
        pub fn run(self: *Self, io: std.Io, gpa: std.mem.Allocator) !void {
            try self.start(io, gpa);
            errdefer self.deinit();
            try self.runLoop();
            if (self.tty) |*t| {
                try self.emitTeardown(t.writer());
            } else if (self.region != null) {
                // §5.5: the degraded (piped) session is one plain frame,
                // rendered here at exit.
                var stdout_w = std.Io.File.stdout().writer(io, &.{});
                try self.renderPlainFrame(&stdout_w.interface);
            }
            self.deinit();
        }

        /// The main loop. Degraded (non-TTY) mode runs one tick — the
        /// loop's update/view pass without output — then stops; the plain
        /// frame is rendered by `run` at exit (§5.5). Interactive mode
        /// runs until quit.
        fn runLoop(self: *Self) !void {
            if (self.tty != null) {
                while (self.running) try self.tick();
            } else if (self.running) {
                try self.tick();
                self.quit();
            }
        }

        /// Render the degraded (non-TTY) session's single plain frame into
        /// `w` (§5.5): fresh scratch, view, band height, draw, then the
        /// region's plain-frame render. The app's `view` runs so a
        /// non-TTY user sees the same content.
        ///
        /// The declared title is deliberately NOT written: a pipe has no
        /// window, so an OSC 0 sequence would be literal garbage in the
        /// transcript. The degraded frame carries no escape byte at all
        /// — not from the envelope, not from styles, not from here.
        fn renderPlainFrame(self: *Self, w: anytype) !void {
            if (self.scratch) |*s| _ = s.reset(.retain_capacity);
            var ctx = self.makeCtx();
            const vw = Model.view(&self.model, &ctx);
            if (vw.height != 0 and vw.height != self.region.?.height) {
                try self.region.?.setHeight(vw.height);
            }
            try vw.draw(&self.model, &ctx, &self.region.?.cur);
            try self.region.?.render(w);
            try w.flush();
        }

        /// Tear down transcript/queue/arena/scratch/region/tty.
        /// Idempotent; called by run.
        pub fn deinit(self: *Self) void {
            if (self.transcript) |*t| t.deinit();
            self.transcript = null;
            if (self.out) |*q| q.deinit();
            self.out = null;
            if (self.arena) |*a| {
                a.deinit();
                self.arena = null;
            }
            if (self.scratch) |*s| {
                s.deinit();
                self.scratch = null;
            }
            if (self.region) |*r| {
                r.deinit();
                self.region = null;
            }
            if (self.tty) |*t| {
                t.deinit();
                self.tty = null;
            }
            self.msg_queue.deinit(self.gpa);
            self.msg_queue = .empty;
            self.running = false;
        }

        // ── messages ──
        /// Enqueue a Msg for the next tick. Main-thread only unless the
        /// app guards concurrent callers with a mutex (§8).
        pub fn send(self: *Self, msg: Msg) void {
            self.msg_queue.append(self.gpa, msg) catch return;
        }

        /// Request quit; the loop breaks after the current tick.
        pub fn quit(self: *Self) void {
            self.running = false;
        }

        /// True while the loop is running (post-start, pre-quit).
        pub fn isRunning(self: *const Self) bool {
            return self.running;
        }

        /// Replace the event→Msg translator. Returning null drops the
        /// event (the framework never synthesizes a Msg from it). Ctrl+C
        /// arrives as a normal `key_press` (Key.ctrl_c) — the filter
        /// routes it to whatever Msg the app chooses (e.g. `.quit`); the
        /// library never hard-quits (input.zig:122-124).
        pub fn setFilter(self: *Self, f: *const fn (*Context, Event) ?Msg) void {
            self.filter = f;
        }

        // ── effects (framework-contract.md §6)
        /// Execute one Cmd's effect. `msg` recurses into update;
        /// batch/sequence drain each element in order — the loop is
        /// single-threaded, so each element's effects complete before the
        /// next starts (orchestrator Q2: identical path for both). `w` is
        /// null in the degraded (non-TTY) path; mode/title writes are
        /// skipped there (no terminal), the mode state still tracks.
        fn processCmd(self: *Self, cmd: Cmd(Msg), ctx: *Context, w: ?*std.Io.Writer) !void {
            switch (cmd) {
                .none => {},
                .quit => self.quit(),
                .msg => |m| {
                    const nested = try Model.update(&self.model, m, ctx);
                    self.render_requested = ctx.render_requested;
                    try self.processCmd(nested, ctx, w);
                },
                .batch => |cmds| for (cmds) |c| try self.processCmd(c, ctx, w),
                .sequence => |cmds| for (cmds) |c| try self.processCmd(c, ctx, w),
                .tick => |t| {
                    if (comptime !@hasField(Msg, "tick"))
                        @compileError("Cmd.tick requires the model's Msg to declare a `tick` field");
                    const deadline = std.Io.Timestamp.now(self.io.?, .awake)
                        .addDuration(.fromMilliseconds(@as(i64, t.delay_ms)));
                    self.tick_deadline = deadline;
                },
                .every => |t| {
                    if (comptime !@hasField(Msg, "tick"))
                        @compileError("Cmd.every requires the model's Msg to declare a `tick` field");
                    self.every_interval = t.interval_ms;
                    // Anchor at the arm moment: the first fire is one
                    // interval after this Cmd, then every interval.
                    self.last_fire = std.Io.Timestamp.now(self.io.?, .awake);
                },
                .println => |text| {
                    if (self.region) |*r| try r.append(.{ .line = text });
                    self.render_requested = true;
                },
                .set_title => |t| {
                    try self.stageTitleNow(t, w);
                    self.title = t;
                },
                .mouse => |on| {
                    // Immediate mode op; the next frame's View.mouse wins.
                    try self.stageBytes(if (on) mouse_on else mouse_off, w);
                    self.modes.mouse = on;
                },
                .cursor => |show| {
                    try self.stageBytes(if (show) emit.cursor_show else emit.cursor_hide, w);
                    self.modes.hide_cursor = show;
                },
            }
        }

        /// SGR 1006 mouse reporting on/off (the only mode ops the
        /// framework writes on demand).
        const mouse_on = "\x1b[?1006h\x1b[?1000h";
        const mouse_off = "\x1b[?1006l\x1b[?1000l";

        /// A staged byte run (a mode op).
        const StageBytes = struct {
            bytes: []const u8,
            pub fn write(self: StageBytes, out: *std.Io.Writer) error{WriteFailed}!void {
                try out.writeAll(self.bytes);
            }
        };

        /// A staged OSC 0 title change.
        const StageTitle = struct {
            title: []const u8,
            pub fn write(self: StageTitle, out: *std.Io.Writer) error{WriteFailed}!void {
                try out.writeAll("\x1b]0;");
                try out.writeAll(self.title);
                try out.writeByte(0x07);
            }
        };

        /// Stage an immediate effect (a title or a mode op) through the
        /// output queue and submit it with one nonblocking write
        /// attempt — still never blocking. Above the watermark the effect
        /// is deferred, not grown: the next frame re-applies the
        /// declaration and emits it. A session without a queue (the
        /// degraded path) writes through the writer it was handed.
        fn stageWith(
            self: *Self,
            w: ?*std.Io.Writer,
            ctx: anytype,
            comptime stage: fn (@TypeOf(ctx), *std.Io.Writer) error{WriteFailed}!void,
        ) error{ FrameTooLarge, WriteFailed }!void {
            if (self.out) |*q| {
                if (!q.canCompose()) {
                    self.render_requested = true;
                    return;
                }
                q.beginFrame();
                stage(ctx, q.writer()) catch {
                    q.abortFrame();
                    self.render_requested = true;
                    return error.FrameTooLarge;
                };
                if (q.frameOverflowed()) {
                    q.abortFrame();
                    self.render_requested = true;
                    return error.FrameTooLarge;
                }
                q.commitFrame();
                _ = try q.drain(&self.tty.?);
                return;
            }
            if (w) |ww| try stage(ctx, ww);
        }

        fn stageBytes(self: *Self, bytes: []const u8, w: ?*std.Io.Writer) error{ FrameTooLarge, WriteFailed }!void {
            try self.stageWith(w, StageBytes{ .bytes = bytes }, StageBytes.write);
        }

        /// Stage the View's declared title into the frame in progress,
        /// so the OSC 0 change shares the frame's single write instead
        /// of becoming a write of its own.
        fn stageTitle(self: *Self, title: []const u8, w: *std.Io.Writer) error{WriteFailed}!void {
            _ = self;
            try (StageTitle{ .title = title }).write(w);
        }

        /// The same OSC 0 write as an immediate effect, outside a frame.
        fn stageTitleNow(self: *Self, title: []const u8, w: ?*std.Io.Writer) error{ FrameTooLarge, WriteFailed }!void {
            try self.stageWith(w, StageTitle{ .title = title }, StageTitle.write);
        }

        // ── internals ──
        /// The interactive init sequence (contract §5.1): caps detect,
        /// region with the detected width policy, winsize resize, app
        /// arena, reader, clock anchor. Requires `self.tty` to be set and
        /// already in raw mode.
        fn startTty(self: *Self, io: std.Io, gpa: std.mem.Allocator) !void {
            self.parser = .{};
            self.caps = try caps.Capabilities.detect(gpa, &self.tty.?, &self.parser);
            self.region = try Region.init(gpa, .{
                .height = self.opts.region_height,
                .append_lines = self.opts.append_lines,
                // The B2 split: an interactive session, and DEC 2026
                // only when the terminal advertised it.
                .interactive = true,
                .sync_output = self.caps.?.sync_output,
                .resize_mode = self.opts.resize_mode,
                .width_policy = self.caps.?.widthPolicy(),
            });
            errdefer {
                self.region.?.deinit();
                self.region = null;
            }
            self.out = try output.OutputQueue.init(gpa, self.opts.output);
            errdefer {
                self.out.?.deinit();
                self.out = null;
            }
            const ws = try self.tty.?.getWinsize();
            try self.region.?.resize(ws.cols, self.region.?.height);
            self.arena = std.heap.ArenaAllocator.init(gpa);
            self.scratch = std.heap.ArenaAllocator.init(gpa);
            self.reader = Reader.init(&self.tty.?);
            self.last_tick = std.Io.Timestamp.now(io, .awake);
            self.running = true;
        }

        /// The degraded (non-TTY) init sequence (contract §5.5): no tty,
        /// no raw mode, no caps — a region with sync_output = false that
        /// emits one plain frame. Input is never read; the loop stops
        /// after that first frame.
        fn startPlain(self: *Self, gpa: std.mem.Allocator) !void {
            self.region = try Region.init(gpa, .{
                .height = self.opts.region_height,
                .append_lines = self.opts.append_lines,
                // Piped output: no envelope, one plain frame at exit.
                .interactive = false,
                .sync_output = false,
                .resize_mode = self.opts.resize_mode,
                .width_policy = caps.Capabilities.WidthPolicy.zg_unicode,
            });
            errdefer {
                self.region.?.deinit();
                self.region = null;
            }
            self.arena = std.heap.ArenaAllocator.init(gpa);
            self.scratch = std.heap.ArenaAllocator.init(gpa);
            self.running = true;
        }

        /// Emit the exit sequences in order: Region.exit (cursor,
        /// autowrap, sync) then caps.restore (contract §5.4). `run` calls
        /// this before `deinit`.
        ///
        /// An interactive session stages the teardown into the output
        /// queue and then blocks the remainder out, so the terminal never
        /// keeps an envelope half-open and nothing staged is lost.
        fn emitTeardown(self: *Self, w: anytype) !void {
            if (self.out) |*q| {
                q.beginFrame();
                self.writeTeardown(q.writer()) catch |err| {
                    q.abortFrame();
                    return err;
                };
                if (q.frameOverflowed()) {
                    q.abortFrame();
                    return error.FrameTooLarge;
                }
                q.commitFrame();
                try q.drainAll(self.tty.?.writer());
                return;
            }
            try self.writeTeardown(w);
            try w.flush();
        }

        fn writeTeardown(self: *Self, w: anytype) !void {
            if (self.region) |*r| try r.exit(w);
            if (self.caps) |*c| try c.restore(w);
        }

        /// The loop stalled (the watchdog saw a frame blow its budget).
        /// Push out what is staged, restore the terminal, stop
        /// composing, and propagate: a wedged loop must unwind, not keep
        /// painting into a terminal nobody is reading.
        fn degradeStall(self: *Self) error{ WriteFailed, FrameTooLarge, WatchdogTripped }!noreturn {
            if (self.out) |*q| q.abortFrame();
            if (self.tty) |*t| {
                const w = t.writer();
                if (self.out) |*q| {
                    q.drainAll(w) catch |err| std.log.scoped(.notui_app).warn(
                        "could not flush the output queue after a stall: {s}",
                        .{@errorName(err)},
                    );
                }
                self.writeTeardown(w) catch |err| std.log.scoped(.notui_app).warn(
                    "could not restore the terminal after a stall: {s}",
                    .{@errorName(err)},
                );
                w.flush() catch |err| std.log.scoped(.notui_app).warn(
                    "could not flush the terminal after a stall: {s}",
                    .{@errorName(err)},
                );
            }
            self.running = false;
            return error.WatchdogTripped;
        }

        /// Build a fresh Context for this tick. Call before every model
        /// call so `render_requested`/`buf` changes flow into the frame.
        fn makeCtx(self: *Self) Context {
            const r = &self.region.?;
            return .{
                .allocator = self.gpa,
                .frame_arena = self.arena.?.allocator(),
                .scratch_arena = self.scratch.?.allocator(),
                .io = self.io.?,
                .buf = &r.cur,
                .width = r.width,
                .height = r.height,
                .frame_delta = self.frame_delta,
                .frame_count = self.frame_count,
                .color_profile = if (self.caps) |*c| c.color else .ansi256,
                .render_requested = self.render_requested,
                .region = r,
            };
        }

        /// True when the region has unflushed work (first frame, a pending
        /// resize/height change, queued appends, or a ledger batch the
        /// terminal has not been sent yet) — forces a render.
        fn regionPending(self: *Self) bool {
            const r = self.region.?;
            return r.first_frame or r.width_dirty or r.height_dirty or
                r.append_queue.items.len > 0 or r.history.items.len > r.history_written;
        }

        /// Enqueue `Msg.tick` (the single periodic message name; models
        /// map it to their own timer message in update, §6).
        fn enqueueTick(self: *Self) !void {
            try self.msg_queue.append(self.gpa, @as(Msg, .tick));
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}

// ── tests ──

const testing = std.testing;

/// A minimal valid model: records msgs it sees and counts view/draw calls.
const TestModel = struct {
    pub const Msg = union(enum) { tick, inc, quit };
    count: i32 = 0,
    draws: usize = 0,

    fn init(_: std.mem.Allocator) !struct { model: TestModel, cmd: Cmd(TestModel.Msg) } {
        return .{ .model = .{}, .cmd = .none };
    }
    fn update(self: *TestModel, msg: Msg, _: *Context) !Cmd(Msg) {
        switch (msg) {
            .tick => self.count += 1,
            .inc => self.count += 1,
            .quit => return .quit,
        }
        return .none;
    }
    fn view(_: *const TestModel, _: *Context) View(TestModel) {
        return .{ .draw = &draw };
    }
    fn draw(self: *TestModel, _: *Context, buf: *Buffer) anyerror!void {
        self.draws += 1;
        _ = try buf.draw(.{}, "hi", 0, 0);
    }
};

/// A model whose update records every msg into a fixed log and recurses
/// `.a` → `.msg = .b` (for batch/sequence order assertions).
const RecModel = struct {
    pub const Msg = union(enum) { tick, a, b, quit };
    log: [16]u8 = undefined,
    log_len: usize = 0,

    fn init(_: std.mem.Allocator) !struct { model: RecModel, cmd: Cmd(RecModel.Msg) } {
        return .{ .model = .{}, .cmd = .none };
    }
    fn update(self: *RecModel, msg: Msg, _: *Context) !Cmd(Msg) {
        self.log[self.log_len] = switch (msg) {
            .tick => 't',
            .a => 'a',
            .b => 'b',
            .quit => 'q',
        };
        self.log_len += 1;
        return switch (msg) {
            .a => .{ .msg = .b }, // a recurses into b within the same tick
            else => .none,
        };
    }
    fn view(_: *const RecModel, _: *Context) View(RecModel) {
        return .{ .draw = &draw };
    }
    fn draw(_: *RecModel, _: *Context, _: *Buffer) anyerror!void {}
};

/// A model for the Ctrl+C filter test.
const CtrlModel = struct {
    pub const Msg = union(enum) { tick, quit };

    fn init(_: std.mem.Allocator) !struct { model: CtrlModel, cmd: Cmd(CtrlModel.Msg) } {
        return .{ .model = .{}, .cmd = .none };
    }
    fn update(_: *CtrlModel, msg: Msg, _: *Context) !Cmd(Msg) {
        return switch (msg) {
            .quit => .quit,
            .tick => .none,
        };
    }
    fn view(_: *const CtrlModel, _: *Context) View(CtrlModel) {
        return .{ .draw = &draw };
    }
    fn draw(_: *CtrlModel, _: *Context, buf: *Buffer) anyerror!void {
        _ = try buf.draw(.{}, "x", 0, 0);
    }
};

/// The framework never hard-quits: Ctrl+C arrives as a key_press and the
/// filter routes it. Both the kitty protocol form (Key.ctrl_c) and the
/// legacy byte form (`\x03` → ctrl+'c') are matched.
fn ctrlCFilter(_: *Context, ev: Event) ?CtrlModel.Msg {
    return switch (ev) {
        .key_press => |k| if (k.matches(Key.ctrl_c, .{}) or k.matches('c', .{ .ctrl = true })) .quit else null,
        else => null,
    };
}

/// Fixed-buffer writer for golden assertions (emit.zig TestWriter pattern).
const TestWriter = struct {
    buf: [4096]u8 = undefined,
    w: std.Io.Writer = undefined,

    fn init(self: *TestWriter) void {
        self.w = .fixed(&self.buf);
    }
    fn reset(self: *TestWriter) void {
        self.w = .fixed(&self.buf);
    }
};

/// A socketpair-backed fake tty: one fd serves both the read path (input
/// written by the test) and the tty writer (output read back by the
/// test), so interactive ticks need no terminal (the input.zig Pipe
/// pattern, extended with a writable writer). Linux socketpair supports
/// only AF_UNIX, so the raw syscall is used (the std `net.Socket`
/// createPair defaults to AF_INET, which fails with EOPNOTSUPP).
const FakeTty = struct {
    a: posix.fd_t, // the "tty" end (owned by App's Tty)
    b: posix.fd_t, // the test end (input)
    out_w: posix.fd_t, // the app's nonblocking output transport
    out_r: posix.fd_t, // the test reads output here

    fn init() !FakeTty {
        var fds: [2]posix.fd_t = undefined;
        if (builtin.link_libc) {
            const rc = std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
            if (rc != 0) return error.SystemResources;
        } else {
            const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
            if (posix.errno(rc) != .SUCCESS) return error.SystemResources;
        }
        // A real O_NONBLOCK pipe for output, so the App's drain hits a
        // real WouldBlock instead of a simulated counter.
        const pipe_fds = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true });
        return .{ .a = fds[0], .b = fds[1], .out_w = pipe_fds[1], .out_r = pipe_fds[0] };
    }

    /// Close only the test ends: end `a` and `out_w` are closed by
    /// App.deinit → Tty.deinit.
    fn deinit(self: *FakeTty) void {
        const f: std.Io.File = .{ .handle = self.b, .flags = .{ .nonblocking = false } };
        f.close(testing.io);
        const r: std.Io.File = .{ .handle = self.out_r, .flags = .{ .nonblocking = true } };
        r.close(testing.io);
        self.* = undefined;
    }

    fn tty(self: *const FakeTty) Tty {
        return .{
            .io = testing.io,
            .fd = .{ .handle = self.a, .flags = .{ .nonblocking = false } },
            .out = .{ .handle = self.out_w, .flags = .{ .nonblocking = true } },
        };
    }

    /// Write input the fake tty will read.
    fn writeInput(self: *FakeTty, bytes: []const u8) !void {
        const f: std.Io.File = .{ .handle = self.b, .flags = .{ .nonblocking = false } };
        try f.writeStreamingAll(testing.io, bytes);
    }

    /// Read whatever the App's transport wrote into the pipe. A
    /// nonblocking read: the test decides when the reader drains, which
    /// is what makes the backpressure test real.
    fn drainOutput(self: *FakeTty, buf: []u8) usize {
        const f: std.Io.File = .{ .handle = self.out_r, .flags = .{ .nonblocking = true } };
        return f.readStreaming(testing.io, &.{buf}) catch 0;
    }

    /// Drain the pipe completely, so a "terminal that is reading" can be
    /// simulated after a blocked stretch.
    fn drainAll(self: *FakeTty, sink: *std.ArrayListUnmanaged(u8)) !void {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = self.drainOutput(&buf);
            if (n == 0) break;
            try sink.appendSlice(testing.allocator, buf[0..n]);
        }
    }

    /// Stop the fake terminal from reading: fill its output buffer, so
    /// the App's next drain hits a real WouldBlock instead of a
    /// simulated one. Returns the filler byte count left queued, so a
    /// test that later drains the pipe can tell the filler from the
    /// App's own bytes. Nothing but backpressure tests need this: an
    /// empty 64 KiB pipe absorbs tens of frames, so a handful of
    /// never blocks and the deferral path would never run.
    fn stopReading(self: *FakeTty) !usize {
        const f: std.Io.File = .{ .handle = self.out_w, .flags = .{ .nonblocking = true } };
        const chunk = [_]u8{'.'} ** 4096;
        var filled: usize = 0;
        while (true) {
            const n = f.writeStreaming(testing.io, "", &.{&chunk}, 1) catch |err| switch (err) {
                error.WouldBlock => return filled,
                else => return err,
            };
            filled += n;
        }
    }
};

/// Wire an app's runtime state against a fake tty, as `start` would for a
/// real terminal (contract §5.1), minus the live caps queries (the fake
/// never replies; detection would burn 5×250 ms per test).
fn setupInteractive(comptime M: type, opts: App(M).Options) !struct { app: App(M), tty: FakeTty } {
    var fake = try FakeTty.init();
    errdefer fake.deinit();
    var app = App(M).initWithOptions(opts);
    app.io = testing.io;
    app.gpa = testing.allocator;
    app.tty = fake.tty();
    app.caps = .{};
    app.region = try Region.init(testing.allocator, .{
        .height = opts.region_height,
        .append_lines = opts.append_lines,
        .interactive = true,
        .sync_output = true,
        .resize_mode = opts.resize_mode,
    });
    errdefer app.region.?.deinit();
    try app.region.?.resize(80, opts.region_height);
    app.out = try output.OutputQueue.init(testing.allocator, opts.output);
    errdefer {
        app.out.?.deinit();
        app.out = null;
    }
    app.arena = std.heap.ArenaAllocator.init(testing.allocator);
    app.scratch = std.heap.ArenaAllocator.init(testing.allocator);
    app.reader = Reader.init(&app.tty.?);
    app.last_tick = std.Io.Timestamp.now(testing.io, .awake);
    app.running = true;
    // Mirror `start`: init builds the model and its initial Cmd is
    // processed through the normal effect path (arms init timers).
    try app.processInit();
    return .{ .app = app, .tty = fake };
}

/// A valid model (passes the contract check).
const GoodModel = struct {
    pub const Msg = union(enum) { tick };
    fn init(_: std.mem.Allocator) !struct { model: GoodModel, cmd: Cmd(GoodModel.Msg) } {
        return .{ .model = .{}, .cmd = .none };
    }
    fn update(_: *GoodModel, _: Msg, _: *Context) !Cmd(Msg) {
        return .none;
    }
    fn view(_: *const GoodModel, _: *Context) View(GoodModel) {
        return .{ .draw = &draw };
    }
    fn draw(_: *GoodModel, _: *Context, _: *Buffer) anyerror!void {}
};

/// A model missing Msg/update/view (fails the contract check).
const BadModel = struct {
    fn init(_: std.mem.Allocator) !BadModel {
        return .{};
    }
};

/// An app wired with enough runtime state (region + arena) for
/// processCmd-level tests — no tty, no reader.
fn cmdApp(comptime M: type) !App(M) {
    var app = App(M).init();
    app.model = (try M.init(testing.allocator)).model;
    app.io = testing.io;
    app.gpa = testing.allocator;
    app.region = try Region.init(testing.allocator, .{ .height = 2, .interactive = false });
    app.arena = std.heap.ArenaAllocator.init(testing.allocator);
    app.scratch = std.heap.ArenaAllocator.init(testing.allocator);
    return app;
}

test "app: Model contract check accepts a valid model and rejects missing members" {
    // The App comptime block turns violations into @compileError; the
    // helper is tested directly (a @compileError cannot be caught).
    try testing.expectEqual(@as(usize, 0), comptime modelViolations(GoodModel).len);
    try testing.expectEqual(@as(usize, 3), comptime modelViolations(BadModel).len);

    // A valid model instantiates cleanly (start owns Model.init).
    const ok = App(GoodModel).init();
    try testing.expect(!ok.isRunning());
}

test "app: degraded path renders one plain frame, no raw mode" {
    var app = App(TestModel).init();
    app.io = testing.io; // `start` sets this before routing to startPlain
    try app.startPlain(testing.allocator);
    try app.processInit(); // `start` runs init after the runtime exists
    defer app.deinit();

    try testing.expect(app.tty == null); // no raw mode, no /dev/tty
    try testing.expect(app.caps == null);
    try testing.expect(app.reader == null);
    try testing.expect(!app.region.?.opts.interactive);
    try testing.expect(app.isRunning());

    // The degraded tick runs the update/view pass but never emits output;
    // the single plain frame is rendered at run-exit (§5.5).
    try app.tick();
    try testing.expect(app.region.?.first_frame); // nothing emitted yet
    try testing.expectEqual(@as(usize, 0), app.model.draws);

    var tw: TestWriter = .{};
    tw.init();
    try app.renderPlainFrame(&tw.w);
    try testing.expect(!app.region.?.first_frame); // exactly one plain frame
    try testing.expect(std.mem.indexOf(u8, tw.w.buffered(), "hi") != null);
    // Not one escape byte: no envelope, no SGR, no cursor switch.
    try testing.expect(std.mem.indexOf(u8, tw.w.buffered(), "\x1b") == null);
}

/// A model that declares a window title and styles its text: a pipe has
/// neither a window nor a terminal, so neither may reach the bytes.
const PlainModel = struct {
    pub const Msg = union(enum) { tick };

    fn init(_: std.mem.Allocator) !struct { model: PlainModel, cmd: Cmd(Msg) } {
        return .{ .model = .{}, .cmd = .none };
    }
    fn update(_: *PlainModel, _: Msg, _: *Context) !Cmd(Msg) {
        return .none;
    }
    fn view(_: *const PlainModel, _: *Context) View(PlainModel) {
        return .{ .draw = &draw, .title = "window" };
    }
    fn draw(_: *PlainModel, _: *Context, buf: *Buffer) anyerror!void {
        _ = try buf.draw(.{ .fg = .{ .ansi = .red } }, "hi", 0, 0);
    }
};

test "app: the degraded frame drops the title and the style, not the text" {
    var app = App(PlainModel).init();
    app.io = testing.io;
    try app.startPlain(testing.allocator);
    try app.processInit();
    defer app.deinit();
    try app.tick();

    var tw: TestWriter = .{};
    tw.init();
    try app.renderPlainFrame(&tw.w);
    const out = tw.w.buffered();
    // The content is there, and nothing else rode along: no OSC 0 for
    // the declared title, no SGR for the styled cell.
    try testing.expect(std.mem.indexOf(u8, out, "hi") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b") == null);
}

test "app: run in degraded mode stops after one plain frame" {
    var app = App(TestModel).init();
    app.io = testing.io;
    try app.startPlain(testing.allocator);
    try app.processInit(); // `start` runs init after the runtime exists
    defer app.deinit();
    try app.runLoop();
    try testing.expect(!app.isRunning());
}

test "app: Ctrl+C routes through the filter to quit (never hard-quits)" {
    var setup = try setupInteractive(CtrlModel, .{ .fps = 0 });
    defer setup.app.deinit();
    defer setup.tty.deinit();
    setup.app.setFilter(&ctrlCFilter);

    try setup.tty.writeInput("\x03");
    try setup.app.tick();
    try testing.expect(!setup.app.isRunning());
}

test "app: without a filter Ctrl+C is dropped and the loop keeps running" {
    var setup = try setupInteractive(CtrlModel, .{ .fps = 0 });
    defer setup.app.deinit();
    defer setup.tty.deinit();

    try setup.tty.writeInput("\x03");
    try setup.app.tick();
    try testing.expect(setup.app.isRunning());
}

test "app: send drains next tick; quit breaks the loop; isRunning reflects state" {
    var fresh = App(TestModel).init();
    try testing.expect(!fresh.isRunning());

    var setup = try setupInteractive(TestModel, .{ .fps = 1000 });
    defer setup.app.deinit();
    defer setup.tty.deinit();

    try testing.expect(setup.app.isRunning());
    setup.app.send(.inc);
    try setup.app.tick();
    try testing.expectEqual(@as(i32, 1), setup.app.model.count);

    setup.app.send(.quit);
    try setup.app.tick();
    try testing.expect(!setup.app.isRunning());
}

test "app: unchanged View signature skips draw on idle ticks" {
    var setup = try setupInteractive(TestModel, .{ .fps = 1000 });
    defer setup.app.deinit();
    defer setup.tty.deinit();

    try setup.app.tick(); // first frame: signature change → draw
    try testing.expectEqual(@as(usize, 1), setup.app.model.draws);

    try setup.app.tick(); // idle: no event/msg, stable signature → skip
    try testing.expectEqual(@as(usize, 1), setup.app.model.draws);

    setup.app.send(.inc); // a dispatched msg forces the frame
    try setup.app.tick();
    try testing.expectEqual(@as(usize, 2), setup.app.model.draws);
}

/// A model whose drawn text is allocated from the app-lifetime
/// `frame_arena` (the frame Buffer borrows the slice, cell.zig) and
/// changes every tick — the soundness regression: with a per-tick-reset
/// frame arena, `prev` cells alias reused memory, `Cell.eql` sees stale
/// content, and changed frames never repaint.
const ArenaDrawModel = struct {
    pub const Msg = union(enum) { tick };
    frame: usize = 0,

    fn init(_: std.mem.Allocator) !struct { model: ArenaDrawModel, cmd: Cmd(ArenaDrawModel.Msg) } {
        return .{ .model = .{}, .cmd = .none };
    }
    fn update(self: *ArenaDrawModel, _: Msg, ctx: *Context) !Cmd(Msg) {
        self.frame += 1;
        ctx.render_requested = true;
        return .none;
    }
    fn view(_: *const ArenaDrawModel, _: *Context) View(ArenaDrawModel) {
        return .{ .draw = &draw };
    }
    fn draw(self: *ArenaDrawModel, ctx: *Context, buf: *Buffer) anyerror!void {
        // No space: blank cells emit no bytes (the row erase covers them),
        // so assert on the exact byte stream.
        const text = try std.fmt.allocPrint(ctx.frame_arena, "frame{d}", .{self.frame});
        _ = try buf.draw(.{}, text, 0, 0);
    }
};

test "app: frame_arena text repaints when the content changes (no prev aliasing)" {
    var setup = try setupInteractive(ArenaDrawModel, .{ .fps = 1000 });
    defer setup.app.deinit();
    defer setup.tty.deinit();

    setup.app.send(.tick);
    try setup.app.tick(); // draws "frame1"
    var out: [4096]u8 = undefined;
    const n1 = setup.tty.drainOutput(&out);
    try testing.expect(std.mem.indexOf(u8, out[0..n1], "frame1") != null);

    setup.app.send(.tick);
    try setup.app.tick(); // must repaint: the diff emits "frame2"
    const n2 = setup.tty.drainOutput(&out);
    try testing.expect(std.mem.indexOf(u8, out[0..n2], "frame2") != null);
}

test "app: teardown emits Region.exit then caps.restore" {
    var app = try cmdApp(TestModel);
    defer app.deinit();
    // Region.exit emits only for an interactive region.
    app.region.?.deinit();
    app.region = try Region.init(testing.allocator, .{ .height = 2, .interactive = true, .sync_output = true });
    app.caps = .{};

    var tw: TestWriter = .{};
    tw.init();
    try app.emitTeardown(&tw.w);
    const out = tw.w.buffered();

    // Region.exit: endSync + park below the band.
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[?2026l") != null);
    const park = std.mem.indexOf(u8, out, "\r\n\r").?;
    // caps.restore starts with the kitty keyboard pop — it must follow.
    const kitty_pop = std.mem.indexOf(u8, out, "\x1b[<u").?;
    try testing.expect(park < kitty_pop);
}

test "cmd: none is a no-op; quit sets running false" {
    var app = try cmdApp(RecModel);
    defer app.deinit();
    app.running = true; // as `start` leaves it
    var ctx = app.makeCtx();
    var tw: TestWriter = .{};
    tw.init();

    try app.processCmd(.none, &ctx, &tw.w);
    try testing.expectEqualStrings("", tw.w.buffered());
    try testing.expect(app.isRunning());

    try app.processCmd(.quit, &ctx, &tw.w);
    try testing.expect(!app.isRunning());
}

test "cmd: msg recurses into update once" {
    var app = try cmdApp(RecModel);
    defer app.deinit();
    var ctx = app.makeCtx();
    var tw: TestWriter = .{};
    tw.init();

    try app.processCmd(.{ .msg = .a }, &ctx, &tw.w);
    // update(.a) logs 'a' and returns .{ .msg = .b } → update(.b) logs 'b'.
    try testing.expectEqualStrings("ab", app.model.log[0..2]);
}

test "cmd: batch drains each element in order" {
    var app = try cmdApp(RecModel);
    defer app.deinit();
    var ctx = app.makeCtx();
    var tw: TestWriter = .{};
    tw.init();

    try app.processCmd(.{ .batch = &.{ .{ .msg = .a }, .{ .msg = .b } } }, &ctx, &tw.w);
    // .a logs 'a' and recurses .b (logs 'b'); then the batch's own .b logs 'b'.
    try testing.expectEqualStrings("abb", app.model.log[0..3]);
}

test "cmd: sequence drains each element in order (same path as batch, Q2)" {
    var app = try cmdApp(RecModel);
    defer app.deinit();
    var ctx = app.makeCtx();
    var tw: TestWriter = .{};
    tw.init();

    try app.processCmd(.{ .sequence = &.{ .{ .msg = .a }, .{ .msg = .b } } }, &ctx, &tw.w);
    try testing.expectEqualStrings("abb", app.model.log[0..3]);
}

test "cmd: tick fires Msg.tick only after the deadline" {
    var setup = try setupInteractive(TestModel, .{ .fps = 1000 });
    defer setup.app.deinit();
    defer setup.tty.deinit();
    var ctx = setup.app.makeCtx();
    var tw: TestWriter = .{};
    tw.init();

    try setup.app.processCmd(.{ .tick = .{ .delay_ms = 40 } }, &ctx, &tw.w);

    try setup.app.tick(); // before the deadline: no fire
    try testing.expectEqual(@as(i32, 0), setup.app.model.count);

    try std.Io.sleep(testing.io, .fromMilliseconds(60), .awake);
    try setup.app.tick(); // deadline elapsed: Msg.tick dispatched
    try testing.expectEqual(@as(i32, 1), setup.app.model.count);

    try setup.app.tick(); // one-shot: cleared, no repeat
    try testing.expectEqual(@as(i32, 1), setup.app.model.count);
}

test "cmd: every re-arms and fires Msg.tick periodically" {
    var setup = try setupInteractive(TestModel, .{ .fps = 1000 });
    defer setup.app.deinit();
    defer setup.tty.deinit();
    var ctx = setup.app.makeCtx();
    var tw: TestWriter = .{};
    tw.init();

    try setup.app.processCmd(.{ .every = .{ .interval_ms = 30 } }, &ctx, &tw.w);

    try setup.app.tick(); // armed this frame: first fire is one interval away
    try testing.expectEqual(@as(i32, 0), setup.app.model.count);

    try std.Io.sleep(testing.io, .fromMilliseconds(50), .awake);
    try setup.app.tick(); // due: fires and re-arms
    try testing.expectEqual(@as(i32, 1), setup.app.model.count);

    try setup.app.tick(); // just re-armed: not due again
    try testing.expectEqual(@as(i32, 1), setup.app.model.count);

    try std.Io.sleep(testing.io, .fromMilliseconds(50), .awake);
    try setup.app.tick(); // due again: the re-armed cycle continues
    try testing.expectEqual(@as(i32, 2), setup.app.model.count);
}

/// A model whose `init` arms `Cmd.every` — the framework_counter spinner
/// regression: the initial Cmd must be processed by the framework so the
/// periodic timer is live with no input (nothing ever dispatches a first
/// Msg otherwise — the pre-fix bug: `init` returned only the model, so
/// the spinner advanced only on a keypress).
const InitCmdModel = struct {
    pub const Msg = union(enum) { tick };
    ticks: usize = 0,
    draws: usize = 0,

    fn init(_: std.mem.Allocator) !struct { model: InitCmdModel, cmd: Cmd(InitCmdModel.Msg) } {
        return .{ .model = .{}, .cmd = .{ .every = .{ .interval_ms = 30 } } };
    }
    fn update(self: *InitCmdModel, msg: Msg, _: *Context) !Cmd(Msg) {
        switch (msg) {
            .tick => self.ticks += 1,
        }
        return .none;
    }
    fn view(_: *const InitCmdModel, _: *Context) View(InitCmdModel) {
        return .{ .draw = &draw };
    }
    fn draw(self: *InitCmdModel, _: *Context, buf: *Buffer) anyerror!void {
        self.draws += 1;
        _ = try buf.draw(.{}, "tick", 0, 0);
    }
};

test "app: init's every Cmd arms the timer — Msg.tick fires and renders with no input" {
    var setup = try setupInteractive(InitCmdModel, .{ .fps = 1000 });
    defer setup.app.deinit();
    defer setup.tty.deinit();

    // The initial Cmd was processed during setup (mirroring `start`):
    // the periodic timer is armed before any event/msg exists.
    try testing.expectEqual(@as(u32, 30), setup.app.every_interval.?);

    try setup.app.tick(); // armed this frame: first fire is one interval away
    try testing.expectEqual(@as(usize, 0), setup.app.model.ticks);
    try testing.expectEqual(@as(usize, 1), setup.app.model.draws); // first-frame render

    try std.Io.sleep(testing.io, .fromMilliseconds(50), .awake);
    try setup.app.tick(); // due: Msg.tick delivered and the frame re-renders
    try testing.expectEqual(@as(usize, 1), setup.app.model.ticks);
    try testing.expectEqual(@as(usize, 2), setup.app.model.draws);

    try setup.app.tick(); // just re-armed: not due again
    try testing.expectEqual(@as(usize, 1), setup.app.model.ticks);
}

test "cmd: println appends one Region.Append.line and forces a render" {
    var app = try cmdApp(RecModel);
    defer app.deinit();
    var ctx = app.makeCtx();
    var tw: TestWriter = .{};
    tw.init();

    try app.processCmd(.{ .println = "hello" }, &ctx, &tw.w);
    try testing.expectEqual(@as(usize, 1), app.region.?.append_queue.items.len);
    switch (app.region.?.append_queue.items[0]) {
        .line => |l| try testing.expectEqualStrings("hello", l),
        else => return error.TestUnexpectedResult,
    }
    try testing.expect(app.render_requested);
}

test "cmd: set_title writes OSC 0 and stores the title" {
    var app = try cmdApp(RecModel);
    defer app.deinit();
    var ctx = app.makeCtx();
    var tw: TestWriter = .{};
    tw.init();

    try app.processCmd(.{ .set_title = "counter" }, &ctx, &tw.w);
    try testing.expectEqualStrings("\x1b]0;counter\x07", tw.w.buffered());
    try testing.expectEqualStrings("counter", app.title.?);
}

test "cmd: mouse and cursor mode ops write the expected bytes" {
    var app = try cmdApp(RecModel);
    defer app.deinit();
    var ctx = app.makeCtx();
    var tw: TestWriter = .{};
    tw.init();

    try app.processCmd(.{ .mouse = true }, &ctx, &tw.w);
    try testing.expectEqualStrings("\x1b[?1006h\x1b[?1000h", tw.w.buffered());
    tw.reset();
    try app.processCmd(.{ .mouse = false }, &ctx, &tw.w);
    try testing.expectEqualStrings("\x1b[?1006l\x1b[?1000l", tw.w.buffered());
    tw.reset();
    try app.processCmd(.{ .cursor = false }, &ctx, &tw.w); // hide
    try testing.expectEqualStrings("\x1b[?25l", tw.w.buffered());
    tw.reset();
    try app.processCmd(.{ .cursor = true }, &ctx, &tw.w); // show
    try testing.expectEqualStrings("\x1b[?25h", tw.w.buffered());

    try testing.expect(!app.modes.mouse);
    try testing.expect(app.modes.hide_cursor);
}

// ── B1: the bounded frame path ────────────────────────

/// A transport that records every write attempt: one submit per frame
/// and the byte totals are read straight off it.
const CountingSink = struct {
    buf: [16384]u8 = undefined,
    len: usize = 0,
    calls: usize = 0,
    /// The reader stopped draining: every attempt would block.
    block: bool = false,
    /// The terminal accepted this many bytes of the FIRST attempt and
    /// everything after it: a short write that leaves a frame pending.
    short: ?usize = null,

    pub fn tryWrite(self: *CountingSink, bytes: []const u8) output.OutputQueue.WriteError!usize {
        self.calls += 1;
        if (self.block) return 0;
        const offer = if (self.calls == 1) self.short orelse bytes.len else bytes.len;
        const n = @min(@min(bytes.len, offer), self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], bytes[0..n]);
        self.len += n;
        return n;
    }

    fn delivered(self: *const CountingSink) []const u8 {
        return self.buf[0..self.len];
    }
};

/// An app wired for headless frames: region, arenas, queue and the
/// initial Cmd, but no tty, no reader, no input.
fn setupHeadless(comptime M: type) !App(M) {
    var app = App(M).init();
    app.io = testing.io;
    app.gpa = testing.allocator;
    app.region = try Region.init(testing.allocator, .{
        .height = 2,
        .interactive = true,
        .sync_output = true,
    });
    errdefer app.region.?.deinit();
    try app.region.?.resize(80, 2);
    app.out = try output.OutputQueue.init(testing.allocator, .{});
    errdefer {
        app.out.?.deinit();
        app.out = null;
    }
    app.arena = std.heap.ArenaAllocator.init(testing.allocator);
    app.scratch = std.heap.ArenaAllocator.init(testing.allocator);
    app.running = true;
    try app.processInit();
    return app;
}

/// Repaints a fresh marker every frame: the backpressure and headless
/// frame fixture.
const ChurnModel = struct {
    pub const Msg = union(enum) { tick };
    frame: usize = 0,
    draws: usize = 0,

    fn init(_: std.mem.Allocator) !struct { model: ChurnModel, cmd: Cmd(ChurnModel.Msg) } {
        return .{ .model = .{}, .cmd = .none };
    }
    fn update(_: *ChurnModel, _: Msg, _: *Context) !Cmd(Msg) {
        return .none;
    }
    fn view(_: *const ChurnModel, _: *Context) View(ChurnModel) {
        return .{ .draw = &draw };
    }
    fn draw(self: *ChurnModel, ctx: *Context, buf: *Buffer) anyerror!void {
        const text = try std.fmt.allocPrint(ctx.frame_arena, "f{d}", .{self.frame});
        _ = try buf.draw(.{}, text, 0, 0);
        self.draws += 1;
    }
};

test "app: headless frames stage and submit in one write each" {
    var app = try setupHeadless(ChurnModel);
    defer app.deinit();
    var sink = CountingSink{};
    const transport = output.Transport.from(&sink);

    for (0..5) |i| {
        app.model.frame = i;
        const taken = try app.frameHeadless(transport);
        try testing.expect(taken > 0);
        // The whole staged frame left in the single attempt.
        try testing.expectEqual(app.frame_stats.staged_bytes, taken);
    }
    try testing.expectEqual(@as(usize, 5), sink.calls); // one submit per frame
    try testing.expectEqual(@as(u64, 5), app.frame_stats.frames);
    // The damage measurement is real: each frame changed a cell.
    try testing.expect(app.frame_stats.dirty_cells > 0);
    try testing.expect(app.frame_stats.peak_pending > 0);
    // Every frame's marker reached the transport, in order.
    for (0..5) |i| {
        var needle: [8]u8 = undefined;
        const want = try std.fmt.bufPrint(&needle, "f{d}", .{i});
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.delivered(), want));
    }
    try testing.expectEqual(@as(usize, 0), app.out.?.pending());
}

test "app: headless frames follow a blocked transport without losing bytes" {
    var app = try setupHeadless(ChurnModel);
    defer app.deinit();
    var sink = CountingSink{ .block = true };
    const transport = output.Transport.from(&sink);

    // The transport is not draining: nothing is accepted, the frame stays
    // pending, and the App keeps composing (the queue is below its
    // watermark here, so this is the queue's own bound doing the work).
    for (0..4) |i| {
        app.model.frame = i;
        const taken = try app.frameHeadless(transport);
        try testing.expectEqual(@as(usize, 0), taken);
    }
    try testing.expect(sink.delivered().len == 0);
    try testing.expect(app.out.?.pending() > 0);
    // Bounded: the queue never grew past its declared capacity, and the
    // deferred frame is still in it, in order.
    try testing.expect(app.out.?.pending() <= app.out.?.buf.len);
    try testing.expect(
        std.mem.indexOf(u8, app.out.?.buf[app.out.?.start..app.out.?.end], "f0") != null,
    );

    // The reader catches up: the pending bytes leave in order, and the
    // queue compacts at the next frame instead of failing.
    sink.block = false;
    _ = try app.frameHeadless(transport);
    try testing.expectEqual(@as(usize, 0), app.out.?.pending());
    try testing.expect(std.mem.indexOf(u8, sink.delivered(), "f0") != null);
    try testing.expect(std.mem.indexOf(u8, sink.delivered(), "f3") != null);
}

test "app: a short-written frame drains on the next idle tick, receipts commit once" {
    var app = try setupHeadless(ChurnModel);
    defer app.deinit();
    // The terminal takes part of the first write and everything after.
    var sink = CountingSink{ .short = 5 };
    const transport = output.Transport.from(&sink);
    try app.initTranscript(testing.allocator, .{ .budget_ns = 0 });

    const block = try app.transcript.?.push(&.{"idle"});
    try app.transcript.?.settle(block);
    app.model.frame = 4;
    _ = try app.frameHeadless(transport);
    try testing.expectEqual(@as(usize, 5), sink.len);
    try testing.expect(app.out.?.pending() > 0);
    // The frame is half-written, so the receipt behind its ledger rows
    // is still outstanding and the block is still retained.
    try testing.expectEqual(@as(usize, 1), app.region.?.historyPending().len);
    try testing.expectEqual(@as(usize, 1), app.transcript.?.liveBlocks());

    // Nothing is owed a new frame — same View, same modes, no ledger
    // work — yet bytes are still queued. The idle tick drains them and
    // composes nothing.
    var ctx = app.makeCtx();
    const vw = ChurnModel.view(&app.model, &ctx);
    const frames = app.frame_stats.frames;
    const draws = app.model.draws;
    const taken = try app.renderStep(vw, &ctx, false, transport);
    try testing.expect(taken > 0);
    try testing.expectEqual(@as(usize, 0), app.out.?.pending());
    try testing.expectEqual(frames, app.frame_stats.frames);
    try testing.expectEqual(draws, app.model.draws);
    try testing.expectEqual(@as(usize, 0), app.frame_stats.staged_bytes);
    try testing.expectEqual(taken, app.frame_stats.written_bytes);

    // Every staged byte reached the terminal, the rows exactly once,
    // and the receipt was acknowledged with them (C1).
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.delivered(), "idle\r\n"));
    try testing.expectEqual(@as(usize, 0), app.region.?.historyPending().len);
    try testing.expectEqual(@as(usize, 0), app.transcript.?.liveBlocks());
    try testing.expectEqual(@as(?transcript.State, null), app.transcript.?.stateOf(block));

    // A further idle tick has nothing queued: no write attempt, no
    // draw, no second commit, no duplicated row.
    const calls = sink.calls;
    try testing.expectEqual(@as(usize, 0), try app.renderStep(vw, &ctx, false, transport));
    try testing.expectEqual(calls, sink.calls);
    try testing.expectEqual(draws, app.model.draws);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.delivered(), "idle\r\n"));
}

test "app: a terminal that stopped reading defers frames and stays bounded" {
    var setup = try setupInteractive(ChurnModel, .{
        .fps = 1000,
        .output = .{ .capacity = 2048, .watermark = 512 },
    });
    defer setup.app.deinit();
    defer setup.tty.deinit();

    // The fake terminal's buffer is full and nobody drains it, so every
    // submit would block. Each tick sends a message because a frame is
    // only owed when something asks for one: mutating the model behind
    // an unchanged View signature composes nothing at all.
    const filler = try setup.tty.stopReading();
    var staged: usize = 0;
    for (0..40) |i| {
        setup.app.send(.tick);
        setup.app.model.frame = i;
        try setup.app.tick();
        staged += setup.app.frame_stats.staged_bytes;
    }
    const q = &setup.app.out.?;
    try testing.expect(staged > 0);
    try testing.expect(setup.app.frame_stats.deferred_frames > 0);
    // The declared bound held for the whole blocked stretch: neither the
    // live pending window nor its peak exceeded the queue's capacity.
    try testing.expect(q.peak_pending <= q.buf.len);
    try testing.expect(q.pending() <= q.buf.len);

    // Bounded: the watermark, not the capacity, is what stops the App.
    // More blocked ticks compose no frame and queue no byte.
    const composed = setup.app.frame_stats.frames;
    const queued = q.pending();
    for (0..20) |_| {
        setup.app.send(.tick);
        try setup.app.tick();
    }
    try testing.expectEqual(composed, setup.app.frame_stats.frames);
    try testing.expectEqual(queued, q.pending());

    // The reader drains: every staged byte arrives, byte for byte, so
    // backpressure cost latency, never content. The filler the stopped
    // terminal left behind is not the App's and is not counted.
    var delivered: std.ArrayListUnmanaged(u8) = .empty;
    defer delivered.deinit(testing.allocator);
    for (0..20) |i| {
        try setup.tty.drainAll(&delivered);
        setup.app.send(.tick);
        setup.app.model.frame = 100 + i;
        try setup.app.tick();
        staged += setup.app.frame_stats.staged_bytes;
    }
    try setup.tty.drainAll(&delivered);
    try testing.expectEqual(staged, delivered.items.len - filler);
    try testing.expectEqual(@as(usize, 0), q.pending());
}

test "app: the pacer caps the frame duty cycle near 50%" {
    var pacer: Pacer = .{};
    // fps == 0 blocks on input; the pacer never invents a cadence.
    try testing.expectEqual(@as(i32, -1), pacer.delayMs(0));
    try testing.expectEqual(@as(i32, 16), pacer.delayMs(60));
    // A cadence faster than a millisecond still waits a millisecond:
    // 1000/4000 truncates to zero, so the nominal wait is clamped.
    try testing.expectEqual(@as(i32, 1), pacer.delayMs(4000));

    // A cheap frame leaves the cadence alone.
    pacer.noteFrameCost(std.time.ns_per_ms);
    try testing.expectEqual(@as(i32, 16), pacer.delayMs(60));
    try testing.expectEqual(@as(u64, 1), pacer.samples);

    // A frame that ate more than half the interval pushes the next wait
    // out to twice its cost, so composing cannot exceed ~50% of the loop.
    // The cap is that cost, not the fps: the same frame holds the wait at
    // 30 ms whatever cadence the app asked for.
    pacer.noteFrameCost(15 * std.time.ns_per_ms);
    try testing.expectEqual(@as(i32, 30), pacer.delayMs(60));
    try testing.expectEqual(@as(i32, 30), pacer.delayMs(4000));
    try testing.expectEqual(@as(u64, 15 * std.time.ns_per_ms), pacer.worst_ns);
}

test "app: input stays responsive while output is backed up" {
    var setup = try setupInteractive(ChurnQuitModel, .{
        .fps = 1000,
        .output = .{ .capacity = 1024, .watermark = 256 },
    });
    defer setup.app.deinit();
    defer setup.tty.deinit();
    setup.app.setFilter(&ctrlCQuitFilter);

    // The fake terminal's buffer is full and nobody drains it, so the
    // transport blocks, the watermark stops composition, and frames
    // queue up behind it.
    _ = try setup.tty.stopReading();
    for (0..40) |i| {
        setup.app.send(.tick);
        setup.app.model.frame = i;
        try setup.app.tick();
    }
    try testing.expect(setup.app.frame_stats.deferred_frames > 0);
    try testing.expect(setup.app.out.?.pending() > 0);

    // Ctrl+C is still read and dispatched while output is backed up.
    try setup.tty.writeInput("\x03");
    try setup.app.tick();
    try testing.expect(!setup.app.isRunning());
}

/// Churns a marker every frame and quits on demand: the "slow terminal,
/// responsive input" fixture.
const ChurnQuitModel = struct {
    pub const Msg = union(enum) { tick, quit };
    frame: usize = 0,

    fn init(_: std.mem.Allocator) !struct { model: ChurnQuitModel, cmd: Cmd(ChurnQuitModel.Msg) } {
        return .{ .model = .{}, .cmd = .none };
    }
    fn update(_: *ChurnQuitModel, msg: Msg, _: *Context) !Cmd(Msg) {
        return switch (msg) {
            .quit => .quit,
            .tick => .none,
        };
    }
    fn view(_: *const ChurnQuitModel, _: *Context) View(ChurnQuitModel) {
        return .{ .draw = &draw };
    }
    fn draw(self: *ChurnQuitModel, ctx: *Context, buf: *Buffer) anyerror!void {
        const text = try std.fmt.allocPrint(ctx.frame_arena, "c{d}", .{self.frame});
        _ = try buf.draw(.{}, text, 0, 0);
    }
};

/// Ctrl+C routes to the model's own quit message — the library still
/// never hard-quits. Both wire forms are matched: a terminal without the
/// kitty protocol sends the legacy `\x03` byte, which the parser reports
/// as ctrl+'c', and that is what this fake terminal sends.
fn ctrlCQuitFilter(_: *Context, ev: Event) ?ChurnQuitModel.Msg {
    return switch (ev) {
        .key_press => |k| if (k.matches(Key.ctrl_c, .{}) or
            k.matches('c', .{ .ctrl = true })) .quit else null,
        else => null,
    };
}

// ── C3: the transcript inside the App ─────────────────

test "app: settled transcript blocks reach the ledger exactly once" {
    var app = try setupHeadless(GoodModel);
    defer app.deinit();
    var sink = CountingSink{};
    const transport = output.Transport.from(&sink);
    // A zero retirement budget retires exactly one block per frame, so
    // the ledger is seen arriving as a strict prefix (transcript.zig:
    // "at least one block is retired per call so a zero budget still
    // makes progress" — with no budget, that is one).
    try app.initTranscript(testing.allocator, .{ .budget_ns = 0 });

    const a = try app.transcript.?.push(&.{"alpha"});
    const b = try app.transcript.?.push(&.{"beta"});
    // Nothing is settled yet: finality is the product's call, not a
    // function of time.
    _ = try app.frameHeadless(transport);
    try testing.expect(std.mem.indexOf(u8, sink.delivered(), "alpha") == null);

    // b before a: order holds it back until the older block settles.
    try app.transcript.?.settle(b);
    _ = try app.frameHeadless(transport);
    try testing.expect(std.mem.indexOf(u8, sink.delivered(), "beta") == null);
    try app.transcript.?.settle(a);

    // The older block retires first and its receipt is acknowledged
    // with it; the newer one still waits its turn.
    _ = try app.frameHeadless(transport);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.delivered(), "alpha\r\n"));
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, sink.delivered(), "beta\r\n"));
    try testing.expectEqual(@as(usize, 0), app.region.?.historyPending().len);
    try testing.expectEqual(@as(?transcript.State, null), app.transcript.?.stateOf(a));
    try testing.expectEqual(@as(usize, 1), app.transcript.?.liveBlocks());

    // The next frame retires `beta` behind its own receipt: both rows
    // reached the terminal and both blocks left the mutable view for
    // good.
    _ = try app.frameHeadless(transport);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.delivered(), "beta\r\n"));
    try testing.expectEqual(@as(usize, 0), app.region.?.historyPending().len);
    try testing.expectEqual(@as(?transcript.State, null), app.transcript.?.stateOf(b));
    try testing.expectEqual(@as(usize, 0), app.transcript.?.liveBlocks());

    // Exactly once: later frames find nothing to retire, so neither row
    // is ever written a second time.
    _ = try app.frameHeadless(transport);
    _ = try app.frameHeadless(transport);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.delivered(), "alpha\r\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.delivered(), "beta\r\n"));
    try testing.expectEqual(@as(usize, 0), app.region.?.historyPending().len);
    try testing.expectEqual(@as(usize, 0), app.transcript.?.liveBlocks());
}

test "app: a blocked transport defers the transcript delta, then commits once" {
    var app = try setupHeadless(GoodModel);
    defer app.deinit();
    var sink = CountingSink{ .block = true };
    const transport = output.Transport.from(&sink);
    try app.initTranscript(testing.allocator, .{ .budget_ns = 0 });

    const a = try app.transcript.?.push(&.{"held"});
    try app.transcript.?.settle(a);
    // The first frame stages the delta but the transport takes nothing.
    _ = try app.frameHeadless(transport);
    try testing.expectEqual(@as(usize, 0), sink.len);
    try testing.expectEqual(@as(usize, 1), app.transcript.?.liveBlocks());
    // The block is out of the mutable view but not committed: it is
    // retained until the receipt is accepted.
    try testing.expectEqual(@as(usize, 0), app.transcript.?.mutableBlocks());
    try testing.expectEqual(@as(usize, 1), app.region.?.historyPending().len);

    sink.block = false;
    _ = try app.frameHeadless(transport);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.delivered(), "held\r\n"));
    try testing.expectEqual(@as(usize, 0), app.transcript.?.liveBlocks());
    try testing.expectEqual(@as(usize, 0), app.region.?.historyPending().len);
}

test "app: a refused ledger enqueue retries the same delta, losing nothing" {
    var app = try setupHeadless(GoodModel);
    defer app.deinit();
    var sink = CountingSink{};
    const transport = output.Transport.from(&sink);
    try app.initTranscript(testing.allocator, .{ .budget_ns = 0 });

    const a = try app.transcript.?.push(&.{"kept"});
    try app.transcript.?.settle(a);

    // The ledger refuses the batch: the frame aborts and the delta is
    // still pending, so nothing reached the terminal and nothing was
    // committed behind a receipt that was never handed over.
    app.region.?.opts.max_history_bytes = 1;
    try testing.expectError(error.HistoryTooLarge, app.frameHeadless(transport));
    try testing.expectEqual(@as(usize, 0), sink.len);
    try testing.expectEqual(@as(usize, 0), app.region.?.historyPending().len);
    try testing.expectEqual(@as(usize, 1), app.transcript.?.liveBlocks());

    // The retry re-emits the SAME rows and the SAME block: they reach
    // the terminal exactly once, and the block is committed behind its
    // own receipt.
    app.region.?.opts.max_history_bytes = 256 * 1024;
    _ = try app.frameHeadless(transport);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.delivered(), "kept\r\n"));
    try testing.expectEqual(@as(usize, 0), app.region.?.historyPending().len);
    try testing.expectEqual(@as(?transcript.State, null), app.transcript.?.stateOf(a));
}

test "app: an overflowing frame leaves the region retryable, nothing doubled" {
    var app = try setupHeadless(ChurnModel);
    defer app.deinit();
    var sink = CountingSink{};
    const transport = output.Transport.from(&sink);

    // A queue far too small for the frame: the staging writer fails
    // instead of truncating, so not one staged byte reaches the
    // transport and the caller sees the failure.
    app.out.?.deinit();
    app.out = null;
    app.out = try output.OutputQueue.init(testing.allocator, .{ .capacity = 24, .watermark = 8 });
    app.model.frame = 7;
    try testing.expectError(error.WriteFailed, app.frameHeadless(transport));
    try testing.expectEqual(@as(usize, 0), sink.len);
    // The frame is still owed whole: the band never published, the
    // ledger never advanced and the next tick must paint again.
    try testing.expect(app.region.?.first_frame);
    try testing.expectEqual(@as(usize, 0), app.region.?.history_written);
    try testing.expect(app.render_requested);

    // The retry produces the complete frame, once.
    app.out.?.deinit();
    app.out = null;
    app.out = try output.OutputQueue.init(testing.allocator, .{});
    app.model.frame = 7;
    _ = try app.frameHeadless(transport);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.delivered(), "f7"));
    try testing.expect(!app.region.?.first_frame);
}

/// Declares a mode change and a title on demand: the frame's staged
/// header, which must never outlive a composition that failed.
const HeaderModel = struct {
    pub const Msg = union(enum) { tick };
    mouse: bool = false,
    title: ?[]const u8 = null,
    draws: usize = 0,

    fn init(_: std.mem.Allocator) !struct { model: HeaderModel, cmd: Cmd(HeaderModel.Msg) } {
        return .{ .model = .{}, .cmd = .none };
    }
    fn update(_: *HeaderModel, _: Msg, _: *Context) !Cmd(Msg) {
        return .none;
    }
    fn view(self: *const HeaderModel, _: *Context) View(HeaderModel) {
        return .{ .draw = &draw, .mouse = self.mouse, .title = self.title };
    }
    fn draw(self: *HeaderModel, _: *Context, buf: *Buffer) anyerror!void {
        self.draws += 1;
        _ = try buf.draw(.{}, "hdr", 0, 0);
    }
};

test "app: a failed mode or title stage re-emits on retry, nothing published" {
    var app = try setupHeadless(HeaderModel);
    defer app.deinit();
    var sink = CountingSink{};
    const transport = output.Transport.from(&sink);

    // A queue with room for the mode sequence but not for the title
    // behind it: the frame's header fails after the modes were applied.
    app.out.?.deinit();
    app.out = null;
    app.out = try output.OutputQueue.init(testing.allocator, .{ .capacity = 16, .watermark = 8 });
    app.model.mouse = true;
    app.model.title = "hdr";
    try testing.expectError(error.WriteFailed, app.frameHeadless(transport));
    try testing.expectEqual(@as(usize, 0), sink.len);
    // The terminal was told nothing, so the mode state must not claim
    // mouse reporting is on: the frame is still owed that sequence.
    try testing.expect(!app.modes.mouse);
    try testing.expect(app.render_requested);
    // The aborted frame staged nothing and published nothing.
    try testing.expectEqual(@as(usize, 0), app.out.?.pending());
    try testing.expect(app.region.?.first_frame);
    try testing.expectEqual(@as(usize, 0), app.model.draws);

    // The retry re-emits the mode sequence it never delivered, then the
    // title, then the band.
    app.out.?.deinit();
    app.out = null;
    app.out = try output.OutputQueue.init(testing.allocator, .{});
    _ = try app.frameHeadless(transport);
    try testing.expect(app.modes.mouse);
    try testing.expect(!app.region.?.first_frame);
    try testing.expectEqual(@as(usize, 1), app.model.draws);
    const on = "\x1b[?1006h\x1b[?1000h";
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.delivered(), on));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.delivered(), "\x1b]0;hdr\x07"));
}

// ── F3: the loop watchdog ────────────────────────────

test "app: a stalled loop trips the watchdog and stops the session" {
    var setup = try setupInteractive(GoodModel, .{ .fps = 1000 });
    defer setup.app.deinit();
    defer setup.tty.deinit();

    // The previous frame's heartbeat is ancient: `tick` observes it
    // BEFORE re-pinging, so the stall is caught rather than swallowed.
    setup.app.watchdog.budget_ns = 0;
    setup.app.watchdog.last_ping = .{ .nanoseconds = 0 };
    try testing.expectError(error.WatchdogTripped, setup.app.tick());
    try testing.expect(!setup.app.isRunning());
}

test "app: a healthy loop never trips the default watchdog budget" {
    var setup = try setupInteractive(GoodModel, .{ .fps = 1000 });
    defer setup.app.deinit();
    defer setup.tty.deinit();
    try setup.app.tick();
    try testing.expect(setup.app.watchdog.armed());
    try testing.expect(setup.app.watchdog.budget_ns == watchdog.default_budget_ns);
    try testing.expect(setup.app.isRunning());
}
