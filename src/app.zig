//! The Elm-style runtime loop over the notui primitives: the terminal
//! session, capability detection, the region renderer and the message pump a
//! model plugs into.
//!
//! `App(Model)` is the published entry point; `Context`, `View` and `Cmd` are
//! re-exported here so a model needs one import.
//!
//! A session is `start` (open the terminal, enter raw mode, detect
//! capabilities, build the region, the arenas and the message queue, then run
//! `Model.init` and its initial command), the loop (`tick`: read one event,
//! translate it through the filter to a `Msg`, run `update`, run the returned
//! command, then paint a frame when one is owed) and teardown (`Region.exit`,
//! `Capabilities.restore`, `Tty.deinit`, `App.deinit`). `start` covers the
//! whole acquisition: if any step fails, including a failing `Model.init`,
//! everything already acquired is released and the terminal modes are
//! restored before the error reaches the caller.
//!
//! `Pacer` and `FrameStats` are published on their own: a headless driver
//! (`frameHeadless`) reads the same measurements without a terminal.
//!
//! The loop is single-threaded. A worker-thread pattern stays at the
//! application level: the worker publishes into a slot the main tick reads and
//! hands to `send`, which is not synchronized and must be guarded by the
//! caller when more than one thread can reach it.

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
const width = @import("width.zig");
/// Adaptive frame pacing: a nominal input cadence plus a ~50% duty cap.
///
/// The loop waits `nominal` for input; when the last frame cost more than
/// half of that, the wait grows to twice the measured cost, so composing
/// frames can occupy at most ~50% of the loop's time however slow the
/// renderer is. A slow frame therefore costs animation smoothness, never
/// input latency.
///
/// The pacer holds plain counters: it allocates nothing, reads no clock, and
/// is only meaningful on the thread that drives the loop.
pub const Pacer = struct {
    /// Cost of the last measured frame, in nanoseconds.
    last_cost_ns: u64 = 0,
    /// Frames measured (telemetry).
    samples: u64 = 0,
    /// Longest single frame cost seen (bench p-max).
    worst_ns: u64 = 0,

    /// Record the cost of one frame, in nanoseconds, and update the
    /// telemetry counters. Called by the App after every composed frame.
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

/// The per-frame state a model receives. Re-export of `context.zig`;
/// see that type for the frame arena split and the borrow rules.
pub const Context = @import("context.zig").Context;
/// The per-frame declaration and its paint callback. Re-export of
/// `view.zig`; see that type for the closed `DrawError` rule.
pub const View = @import("view.zig").View;
/// The effect vocabulary `update` returns. Re-export of `command.zig`; see
/// that type for the timer payloads and the borrowed slices.
pub const Cmd = @import("command.zig").Cmd;

/// The declarations `App` requires of a model: `Msg`, `init`, `update` and
/// `view`. Returns the missing names, empty when the model satisfies the
/// contract. Module-level so the list is testable; `App` turns a non-empty
/// result into a compile error.
fn modelViolations(comptime Model: type) []const []const u8 {
    var list: []const []const u8 = &.{};
    if (!@hasDecl(Model, "Msg")) list = list ++ &[_][]const u8{"Msg"};
    if (!@hasDecl(Model, "init")) list = list ++ &[_][]const u8{"init"};
    if (!@hasDecl(Model, "update")) list = list ++ &[_][]const u8{"update"};
    if (!@hasDecl(Model, "view")) list = list ++ &[_][]const u8{"view"};
    return list;
}

/// One session of one model: the terminal, the renderer, the message pump and
/// the loop that connects them.
///
/// `Model` MUST declare (checked at comptime):
///
///   pub const Msg = <type>;                              // the message type
///   pub fn init(allocator: std.mem.Allocator) !struct { // initial state plus
///       model: Model,                                   //   its first effect
///       cmd: Cmd(Msg),
///   };
///   pub fn update(self: *Model, msg: Msg, ctx: *Context) !Cmd(Msg);
///   pub fn view(self: *const Model, ctx: *Context) View(Model);
///
/// `Model` MAY declare `pub const DrawError: <error set>` to widen the paint
/// error set past `std.mem.Allocator.Error`; see `view.zig`.
///
/// `Model` MAY declare `pub fn deinit(self: *Model, gpa: std.mem.Allocator)
/// void`. The App calls it exactly once per successful `Model.init` — also
/// when the initial command or a later startup step fails — and never for a
/// model that was not built. It is how a model that owns memory releases it;
/// a model that owns nothing omits it.
///
/// One instance owns everything it acquired: the model, the tty descriptors
/// and the terminal mode state, the region, the output queue, both arenas,
/// the transcript and the message queue. `deinit` releases all of it and is
/// safe to call more than once on the same instance. Copies share allocations but copy
/// ownership state by value; only one instance may be operated and disposed.
/// Keep its address stable after `start`: its reader borrows the embedded tty.
///
/// Serialize `send`, ticks and lifecycle operations, not merely concurrent send calls.
/// `run` takes no lock; workers should publish into a synchronized application slot
/// that the loop reads before calling `send`.
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
        /// How one session is built. Read once at `start`; a later change to
        /// the struct the caller kept has no effect on the running session.
        pub const Options = struct {
            /// Loop pacing in frames per second. Above zero the loop waits
            /// `1000 / fps` milliseconds for input each tick, widened by the
            /// pacer; zero blocks until input arrives, so animation must then
            /// come from an armed timer.
            fps: u32 = 60,
            /// Initial inline band height in rows, and the height a resize
            /// keeps until a `View` asks for another.
            region_height: u16 = 3,
            /// Reserve scrollback space above the band for appended content.
            /// With this off the region relies on the terminal's own
            /// scrolling when a line is appended.
            append_lines: bool = true,
            /// The default event→`Msg` translator, installed by `start`. The
            /// same slot is writable later through `setFilter`. `null` means
            /// no translation: every event the framework handles itself is
            /// handled and the rest are dropped, and no message is ever
            /// synthesized from them.
            filter: ?*const fn (*Context, Event) ?Msg = null,
            /// Bounds for the output queue in front of the terminal:
            /// `capacity` is the hard byte bound on staged output and
            /// `watermark` the pending level above which the loop stops
            /// composing frames until the transport drains.
            output: output.OutputQueue.Options = .{},
            /// What a width change does to the band's own content.
            resize_mode: ResizeMode = .append,
            /// The terminal's declared reflow profile. The default rewraps
            /// non-cursor rows on a width change with unbounded retention,
            /// as current terminals do; declare `.none` for a terminal that
            /// never rewraps. See `Region.TerminalReflow`.
            terminal_reflow: Region.TerminalReflow = .rewrapping,
        };

        const Self = @This();
        /// Alias for the frame state type; `App(M).Ctx` is `Context`.
        pub const Ctx = Context;
        /// Alias for this model's frame type; `App(M).Vw` is `View(Model)`.
        pub const Vw = View(Model);

        /// One armed one-shot timer: the instant the deadline passes and the
        /// message enqueued when it does. `Cmd.tick` copies both into the
        /// session; `null` when no one-shot timer is armed.
        const TickTimer = struct {
            deadline: std.Io.Timestamp,
            msg: Msg,
        };

        /// One armed periodic timer: the interval in milliseconds, the instant
        /// the current cycle started, and the message enqueued every interval.
        /// `Cmd.every` copies all three into the session; `null` when no
        /// periodic timer is armed.
        const EveryTimer = struct {
            interval_ms: u32,
            last_fire: std.Io.Timestamp,
            msg: Msg,
        };

        /// The model. `undefined` until `start` runs `Model.init`; the loop
        /// reads and writes it in place, so a pointer taken by a paint
        /// callback is stable for the session. `deinit` releases what the
        /// model owns through the model's own optional `deinit` hook.
        model: Model,
        /// Whether this instance holds a live model. It is false before
        /// `Model.init` has returned, true from then until the model is
        /// disposed, and false again afterwards — including when a startup
        /// step after `Model.init` failed and the model was released with
        /// everything else.
        ///
        /// Read it to tell a session that owns a model from one that owns
        /// nothing; only the App's own startup and teardown set it, and
        /// setting it by hand makes `deinit` call a model hook on a model
        /// that was never built.
        model_ready: bool = false,
        /// The options `start` was called with.
        opts: Options,

        /// The session `std.Io`, stored by `start` and handed to the model
        /// through `Context.io`. `null` before `start`.
        io: ?std.Io = null,
        /// The session allocator, stored by `start`. It owns the model, the
        /// region, the queue, the arenas and the message queue, and `deinit`
        /// releases all of them through it. Undefined before `start`.
        gpa: std.mem.Allocator = undefined,
        /// The opened terminal: descriptors, original termios and raw-mode
        /// state. `null` in a degraded session and after `deinit`.
        tty: ?Tty = null,
        /// The capability-detection parser. Reset at the start of an
        /// interactive session; its decode scratch lives inside the value,
        /// so the parser keeps this address for the session.
        parser: Parser = .{},
        /// What the terminal reported it supports; `null` in a degraded
        /// session, where detection never ran.
        caps: ?caps.Capabilities = null,
        /// The inline band and its scrollback; `null` before `start` and after
        /// `deinit`. A `Context` points at this value.
        region: ?Region = null,
        /// The input reader, borrowed from `tty`. `null` in a degraded
        /// session, which never reads input.
        reader: ?Reader = null,
        /// The session arena behind `Context.frame_arena`, released by
        /// `deinit` and never reset while the session runs: the cells of the
        /// previous frame still borrow its memory.
        arena: ?std.heap.ArenaAllocator = null,
        /// The per-frame arena behind `Context.scratch_arena`. Reset with its
        /// capacity retained at the top of every frame, so a slice taken from
        /// it dies with the frame that took it.
        scratch: ?std.heap.ArenaAllocator = null,
        /// The bounded byte queue in front of the terminal. Every frame is
        /// staged here and submitted with one nonblocking write attempt;
        /// bytes the transport has not taken stay queued and composition stops
        /// at the watermark. `null` in a degraded session and after `deinit`.
        out: ?output.OutputQueue = null,

        /// True between `start` and the loop's exit. `quit` clears it; a
        /// failed `start` leaves it false.
        running: bool = false,
        /// The terminal modes currently active, diffed against each frame's
        /// declaration so a mode sequence is written only on a change.
        modes: view_mod.Modes = .{},
        /// Whether this session's exit sequences have already gone out. Set
        /// by the finished path and by the unwinding one, so a terminal is
        /// restored once however many times the cleanup runs.
        terminal_restored: bool = false,
        /// The signature of the last composed frame; a frame with the same one
        /// is not composed again. Seeded to a value no frame can hash to.
        last_sig: u64 = std.math.maxInt(u64),
        /// Ticks entered in this session, including the current one: 1 during
        /// the first tick's callbacks. Zero before the first tick,
        /// `frameHeadless` does not advance it, and `deinit` resets it.
        frame_count: u64 = 0,
        /// Time since the previous frame; `.zero` on the first one.
        frame_delta: std.Io.Duration = .zero,
        /// Set by `update`, `view` or a command to force a repaint this frame.
        /// Cleared at the top of every frame.
        render_requested: bool = false,
        /// The instant the previous frame started, on the session clock.
        last_tick: ?std.Io.Timestamp = null,
        /// Messages waiting for `update`, in arrival order. Owned by the App
        /// and released by `deinit`; the `Msg` values themselves are copied
        /// in, and whatever they point at stays the sender's.
        msg_queue: std.ArrayList(Msg) = .empty,
        /// The live event→`Msg` translator; `null` drops every event the
        /// framework does not handle itself.
        filter: ?*const fn (*Context, Event) ?Msg = null,
        /// The one-shot timer armed by `Cmd.tick`, with the message it will
        /// enqueue; `null` when none is armed.
        tick_timer: ?TickTimer = null,
        /// The periodic timer armed by `Cmd.every`, with the message it will
        /// enqueue each interval; `null` when none is armed.
        every_timer: ?EveryTimer = null,

        /// Adaptive pacing state: the last frame cost and the duty cap.
        pacer: Pacer = .{},
        /// The loop watchdog. Each frame observes the previous heartbeat
        /// before re-pinging, so a stall inside a frame is reported instead
        /// of being swallowed by the reset.
        watchdog: watchdog.Watchdog = .init(watchdog.default_budget_ns),
        /// Per-frame measurements for a headless driver and the debug server.
        frame_stats: FrameStats = .{},
        /// The streaming transcript, allocated only by `initTranscript`. The
        /// product settles blocks; the App retires settled ones inside the
        /// frame budget, writes each delta as one ledger batch, and commits a
        /// block once the transport accepted the receipt behind its rows.
        transcript: ?transcript.Transcript = null,

        // ── construction ──
        /// A session with default options and no resources acquired yet.
        ///
        /// The model is not a parameter: `start` owns init, because the
        /// initial command can only be processed once the region and the
        /// arenas exist. `model` is `undefined` until it returns, so nothing
        /// may read or write the model between `init` and `start`.
        pub fn init() Self {
            return initWithOptions(.{});
        }

        /// A session with `opts`, and with `opts.filter` installed as the
        /// event→`Msg` translator. Resources are acquired only by `start`.
        pub fn initWithOptions(opts: Options) Self {
            return .{ .model = undefined, .opts = opts, .filter = opts.filter };
        }

        // ── lifecycle ──
        /// Acquire the whole session and build the model, so the instance is
        /// ready for `tick` when this returns.
        ///
        /// With a terminal on stdin it opens `/dev/tty` twice (a blocking
        /// descriptor for input and termios, a nonblocking one for frames),
        /// enters raw mode, detects capabilities, and builds the region, the
        /// output queue, both arenas and the reader. Without one it degrades:
        /// no tty, no raw mode, no detection, one region that emits a single
        /// plain frame and no input.
        ///
        /// It then runs `Model.init(gpa)` and processes the command that
        /// returns, so a timer armed by `init` is live before the first tick.
        ///
        /// The whole acquisition is covered: any failure — a refused open, a
        /// raw-mode failure, an exhausted allocator, a failing `Model.init` —
        /// runs the same teardown a finished session would. The terminal modes
        /// are restored, every owned resource is released and `running` stays
        /// false, so the instance owns nothing afterwards and `deinit` is safe
        /// to call again.
        ///
        /// The instance keeps `io` and `gpa` after a failure, and a later
        /// `start` may be attempted on the same instance.
        pub fn start(self: *Self, io: std.Io, gpa: std.mem.Allocator) !void {
            return self.acquire(io, gpa, Tty.isTty(std.posix.STDIN_FILENO));
        }

        /// The whole acquisition, once `start` has decided which session it is
        /// opening. Storing `io` and `gpa` is the first step and the single
        /// cleanup is registered before the next one, so a failure at any
        /// point releases everything acquired before it.
        ///
        /// `interactive` selects the route: open the terminal, enter raw mode
        /// and detect capabilities, or degrade to a region that emits one
        /// plain frame and never reads input.
        fn acquire(self: *Self, io: std.Io, gpa: std.mem.Allocator, interactive: bool) !void {
            self.io = io;
            self.gpa = gpa;
            errdefer self.abortSession();
            if (interactive) {
                self.tty = try Tty.init(io);
                try self.tty.?.makeRaw();
                try self.startTty(io, gpa);
            } else {
                try self.startPlain(gpa);
            }
            // The runtime exists now, so the initial command takes the same
            // path as a queued message: a timer anchors at this instant and
            // its first fire is one interval out.
            try self.processInit();
        }

        /// Release everything `start` or the loop acquired, and put the
        /// terminal back the way it was: queued bytes first, then
        /// `Region.exit`, `Capabilities.restore` and the original termios.
        ///
        /// Every step is best-effort and reports nothing, because every caller
        /// is already propagating the error that started the unwind. It is
        /// used both by a failed `start` and by a failed `run`.
        fn abortSession(self: *Self) void {
            self.releaseTerminal();
            self.deinit();
        }

        /// Write out what is queued and restore the terminal's modes, without
        /// reporting anything. The termios goes back one step later, when
        /// `deinit` releases the tty. Does nothing when no terminal was
        /// opened, so a degraded session skips it, and nothing when the
        /// sequences already went out, so a stall that restored the terminal
        /// is not restored twice.
        fn releaseTerminal(self: *Self) void {
            const t = if (self.tty) |*t| t else return;
            if (self.terminal_restored) return;
            self.terminal_restored = true;
            const w = t.writer();
            if (self.out) |*q| {
                // The frame in progress was never committed: it is dropped
                // rather than flushed, because its bytes may contradict the
                // state the teardown writes next.
                q.abortFrame();
                q.drainAll(w) catch |err| std.log.scoped(.notui_app).warn(
                    "could not flush the output queue while unwinding: {s}",
                    .{@errorName(err)},
                );
            }
            self.writeTeardown(w) catch |err| std.log.scoped(.notui_app).warn(
                "could not restore the terminal while unwinding: {s}",
                .{@errorName(err)},
            );
            w.flush() catch |err| std.log.scoped(.notui_app).warn(
                "could not flush the terminal while unwinding: {s}",
                .{@errorName(err)},
            );
        }

        /// Build the initial model through `Model.init` and run its command on
        /// the same path a queued message takes. Called by `acquire` once the
        /// runtime exists. The writer is null in a degraded session, where
        /// mode and title writes are skipped because there is no terminal.
        fn processInit(self: *Self) !void {
            const init_res = try Model.init(self.gpa);
            self.model = init_res.model;
            // Armed before the command runs: an initial command that fails
            // must still release the model it was built for.
            self.model_ready = true;
            var ictx = self.makeCtx();
            const w: ?*std.Io.Writer = if (self.tty != null) self.tty.?.writer() else null;
            try self.processCmd(init_res.cmd, &ictx, w);
            self.render_requested = ictx.render_requested;
        }

        /// Release what the model owns, through the model's own `deinit` when
        /// it declares one. Called exactly once per successful `Model.init`: a
        /// model that was never built is not disposed, and one that was
        /// already disposed is not disposed twice.
        ///
        /// The hook is the model's own release path, so a model that owns no
        /// memory omits it and needs nothing here. It returns nothing: a
        /// cleanup cannot report a failure to a caller that is already
        /// unwinding or returning.
        fn disposeModel(self: *Self) void {
            if (!self.model_ready) return;
            self.model_ready = false;
            if (@hasDecl(Model, "deinit")) Model.deinit(&self.model, self.gpa);
        }

        /// One loop iteration: arm checks, one input event (paced to `fps`),
        /// filter to a message, `update` per queued message, the returned
        /// commands, then the frame — composed only when one is owed, mode
        /// diff first, then paint and submit. Valid after `start`.
        ///
        /// It blocks in the reader for up to the paced timeout, and returns
        /// `error.EndOfStream` only as a quit request: the loop stops and no
        /// error escapes. Every other failure — a paint error, a full output
        /// queue, an exhausted allocator, a watchdog trip — is returned, and
        /// `run` then unwinds through the teardown.
        ///
        /// A due timer keeps its deadline and cycle anchor if enqueue returns
        /// `error.OutOfMemory`. A caller that drives `tick` may handle that error
        /// and retry. `run` instead returns the error and tears down the session.
        pub fn tick(self: *Self) !void {
            // 1. Per-frame scratch: reset it, capacity retained. The session
            //    arena behind `ctx.frame_arena` is never reset — the previous
            //    frame's cells still borrow its memory — and
            //    `render_requested` clears so each frame re-declares.
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

            // 2. Timers enqueue the message they were armed with.
            // The state advances only after enqueue succeeds, so a caller that
            // handles the error can retry the timer on another tick.
            if (self.tick_timer) |timer| {
                if (now.nanoseconds >= timer.deadline.nanoseconds) {
                    try self.send(timer.msg);
                    self.tick_timer = null;
                }
            }
            if (self.every_timer) |*timer| {
                if (now.nanoseconds - timer.last_fire.nanoseconds >=
                    @as(i96, timer.interval_ms) * std.time.ns_per_ms)
                {
                    try self.send(timer.msg);
                    timer.last_fire = now;
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

            // 4. Dispatch the event. A winsize resizes the inline band, and a
            //    cursor-position report corrects the region's anchor; the
            //    framework owns the region, so neither reaches the model.
            //    Every other event goes through the filter, and a null from
            //    the filter drops it: the framework never invents a message.
            var dispatched = ev != null;
            if (ev) |e| switch (e) {
                .cpr => |pos| {
                    // `dispatched` forces a frame even at fps zero.
                    // A discarded old-geometry reply can therefore
                    // trigger the fresh query without a model message.
                    if (self.region) |*r| try r.applyCpr(pos.row, pos.col);
                },
                .winsize => |wsz| {
                    // `wsz.rows` is the terminal's screen, not the band:
                    // the band's own height stays logical, so a later
                    // winsize that grows the screen restores the full
                    // band instead of the remnant the short screen left.
                    if (self.region) |*r| try r.resize(wsz.cols, wsz.rows, r.height);
                    self.render_requested = true;
                },
                else => {
                    if (self.filter) |f| {
                        var fctx = self.makeCtx();
                        if (f(&fctx, e)) |m| try self.send(m);
                        self.render_requested = fctx.render_requested;
                    }
                },
            };
            // 4b. A terminal reports a resize with SIGWINCH, not on its input
            //     stream (an in-band `winsize` is the exception), so the
            //     signal flag is polled every tick and the band re-laid out
            //     at the size the terminal now has.
            if (self.tty) |*t| {
                if (t.checkResize()) {
                    const wsz = try t.getWinsize();
                    if (self.region) |*r| {
                        try r.resize(wsz.cols, wsz.rows, r.height);
                        // The signal may stand for several sizes; the
                        // terminal may have cut rows at one of them.
                        r.repaintAll();
                    }
                    self.render_requested = true;
                    dispatched = true;
                }
            }

            // 5. The writer this frame's immediate effects use: the tty's
            //    buffered writer when there is a terminal, null in a degraded
            //    session, whose single plain frame is painted by `run` at exit.
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

            // 7. The declaration for this frame, read after every message was
            //    processed so it sees the final model state.
            var ctx = self.makeCtx();
            const vw = Model.view(&self.model, &ctx);
            self.render_requested = ctx.render_requested;

            // 8. The declared band height, applied before the frame is
            //    painted. The declared title is staged inside the frame itself
            //    so it shares the frame's single write.
            if (vw.height != 0 and vw.height != self.region.?.height) {
                try self.region.?.setHeight(vw.height);
            }

            // 9. The frame: staged into the bounded output queue and submitted
            //    once (see `renderStep`). A degraded session has no terminal
            //    and paints its one plain frame in `run`, never here.
            if (self.tty != null) {
                _ = try self.renderStep(vw, &ctx, dispatched, output.Transport.from(&self.tty.?));
            }
        }

        /// One frame: stage the mode diff, the declared title and the band
        /// into the output queue, commit the staging, then submit it with a
        /// single nonblocking write attempt. Returns the bytes the transport
        /// accepted; 0 means the frame is still queued.
        ///
        /// Backpressure: at the watermark the frame is neither composed nor
        /// committed — the render stays requested and the identical frame is
        /// retried on a later frame after a drain. Input is read every frame
        /// regardless, so a slow terminal costs animation latency, never
        /// responsiveness and never history.
        ///
        /// Idle frame: a frame that owes nothing still drains the queue, so a
        /// frame the transport accepted only in part stops being half-painted
        /// without waiting for the next repaint.
        ///
        /// Failure discipline: a composition that overflows the queue, or a
        /// `draw` that fails, aborts before any frame state advances (no
        /// previous snapshot, no dirty flag, no ledger receipt, no
        /// `last_sig`), so the retry paints the whole frame again. Terminal
        /// modes follow the same rule: the diff is staged with the frame, so a
        /// failed composition rolls the mode state back and the retry re-emits
        /// what the terminal never received.
        ///
        /// Acknowledgement: the ledger is acknowledged exactly when the
        /// transport has taken every staged byte and never before, and the
        /// transcript block behind a receipt is committed then.
        ///
        /// Returns `error.FrameTooLarge` for an overflow and the queue
        /// writer's error when it cannot take the bytes, beside the model's
        /// `View.DrawError` from `draw`.
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
            // The transport took every staged byte: the ledger receipts are
            // acknowledged exactly once, and the transcript blocks behind them
            // are committed.
            if (q.pending() == 0) self.commitHistory();
            return taken;
        }

        /// Compose the frame in progress — the mode diff, the declared title
        /// and the band — into the output queue. Nothing is published here
        /// (`commitFrame` does that), so any failure rolls the staged bytes
        /// and the mode state back together and the retry re-emits exactly
        /// the sequences the terminal never received. Returns the number of
        /// cells the frame changes.
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
            // Every frame is painted from a blank buffer: `cur` still holds
            // the previous frame's cells, and text that got shorter would
            // otherwise keep the old tail (`count: 10` -> `count: 9` left a
            // stale last character).
            self.region.?.cur.clear();
            try vw.draw(&self.model, ctx, &self.region.?.cur);
            const dirty = self.region.?.dirtyCells();
            try self.retireTranscript();
            try self.region.?.render(w);
            if (q.frameOverflowed()) return error.FrameTooLarge;
            return dirty;
        }

        /// One nonblocking drain for a frame that composes nothing: the queued
        /// bytes leave, the accepted count is this attempt's `written_bytes`,
        /// and the ledger is acknowledged only once the queue has taken every
        /// staged byte.
        fn drainQueued(self: *Self, q: *output.OutputQueue, sink: output.Transport) !usize {
            if (q.pending() == 0) return 0;
            const taken = try q.drain(sink);
            self.frame_stats.written_bytes = taken;
            if (q.pending() == 0) self.commitHistory();
            return taken;
        }

        /// One frame with no input read: the seam a headless driver uses,
        /// because `tick` blocks on the reader. It resets `Context.scratch_arena`,
        /// reads the declaration, applies its band height and runs the same
        /// frame path as `tick`, then attempts one drain into `sink`.
        ///
        /// Valid on a live runtime: a region and both arenas, which every
        /// `start` route builds before `Model.init` runs. The output queue is
        /// not part of it — interactive startup installs one, a degraded
        /// session does not, and its single plain frame is painted by `run` at
        /// exit rather than staged here.
        ///
        /// Returns the bytes `sink` accepted. Zero can mean no bytes were
        /// staged, a drain the transport blocked, or no output queue at all;
        /// when `out` is present, inspect its `pending()` count for bytes
        /// still queued.
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

        /// Allocate the streaming transcript and hand it to the App, which
        /// retires settled blocks inside each frame and releases it in
        /// `deinit`. `gpa` must be the allocator that outlives the App.
        ///
        /// An instance that already has a transcript is released first, so any
        /// block it had not committed is dropped: call this once, before the
        /// first frame.
        pub fn initTranscript(
            self: *Self,
            gpa: std.mem.Allocator,
            opts: transcript.Transcript.Options,
        ) !void {
            if (self.transcript) |*t| {
                t.deinit();
                self.transcript = null;
            }
            self.transcript = try transcript.Transcript.init(gpa, opts);
        }

        /// Retire settled transcript blocks and stage the delta as one ledger
        /// batch. Finality is the product's decision: only blocks the product
        /// settled move, oldest first, within this frame's time budget, and
        /// the rest wait for the next frame.
        ///
        /// Whether anything is pending is the transcript's own answer through
        /// `Delta.isEmpty`, never a row count: a block that settled with no
        /// rows of its own is still retired and still needs its receipt.
        ///
        /// The three steps are one transaction. `retire` reserves the seal
        /// before a block leaves the mutable view and keeps an unsealed delta
        /// alive, `writeTranscript` is the only step that can fail, and a
        /// failure aborts the frame with the delta still pending: the next
        /// frame re-emits the same rows under the same block ids, so a
        /// refused batch is retried, never lost and never written twice.
        fn retireTranscript(self: *Self) !void {
            const t = if (self.transcript) |*t| t else return;
            var delta: transcript.Delta = .{};
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

        /// The normal entry point: `start`, the loop until quit, the exit
        /// sequence, then `deinit`.
        ///
        /// An interactive session writes `Region.exit` and
        /// `Capabilities.restore` through the output queue and blocks until
        /// every staged byte has left. A degraded session has no terminal and
        /// instead paints its one plain frame to standard output.
        ///
        /// A failure anywhere after `start` unwinds through the same release
        /// a finished session performs — queued bytes, terminal modes, termios,
        /// then every owned resource — so an error never leaves a raw terminal
        /// behind. `start`'s own failure releases everything it had acquired.
        /// The allocator and `io` are borrowed for the call and not retained
        /// beyond the resources the App now owns.
        pub fn run(self: *Self, io: std.Io, gpa: std.mem.Allocator) !void {
            try self.start(io, gpa);
            errdefer self.abortSession();
            try self.runLoop();
            if (self.tty) |*t| {
                try self.emitTeardown(t.writer());
            } else if (self.region != null) {
                // A degraded session produces its single plain frame here, at
                // exit, where a pipe consumer is waiting for it.
                var stdout_w = std.Io.File.stdout().writer(io, &.{});
                try self.renderPlainFrame(&stdout_w.interface);
            }
            self.deinit();
        }

        /// The main loop. An interactive session runs until `quit` clears
        /// `running`. A degraded one runs a single frame — the update and
        /// declaration pass with no output — and stops, because its only frame
        /// is painted by `run` at exit.
        fn runLoop(self: *Self) !void {
            if (self.tty != null) {
                while (self.running) try self.tick();
            } else if (self.running) {
                try self.tick();
                self.quit();
            }
        }

        /// Paint the degraded session's single plain frame into `w`: reset
        /// `Context.scratch_arena`, read the model's declaration and band height,
        /// call `draw`, then render the region's plain frame and flush.
        /// The loop has ended by then, so a piped consumer reads the one frame
        /// a degraded session produces.
        ///
        /// The declared title is deliberately not written: a pipe has no
        /// window, so an OSC 0 sequence would be literal garbage in the
        /// transcript. The frame carries no escape byte at all — not from the
        /// envelope, not from styles, not from here. `w` is the caller's and is
        /// left flushed on success.
        fn renderPlainFrame(self: *Self, w: anytype) !void {
            if (self.scratch) |*s| _ = s.reset(.retain_capacity);
            var ctx = self.makeCtx();
            const vw = Model.view(&self.model, &ctx);
            if (vw.height != 0 and vw.height != self.region.?.height) {
                try self.region.?.setHeight(vw.height);
            }
            self.region.?.cur.clear();
            try vw.draw(&self.model, &ctx, &self.region.?.cur);
            try self.region.?.render(w);
            try w.flush();
        }

        /// Release every resource this instance owns: the model, the
        /// transcript, the output queue, the session and frame arenas, the
        /// region, the tty (which restores the original termios and closes
        /// both descriptors) and the message queue.
        ///
        /// It does not write the terminal's exit sequences: a session that ran
        /// does that itself, and a session that is unwinding does it in
        /// `abortSession`. The caller owns `gpa` and `io`, which are not
        /// released here, nor `opts` and `filter`.
        ///
        /// Every owned field is cleared and the loop state is reset, so a
        /// second call on the same instance does nothing and `start` may be
        /// called again. The model goes first: it is the only thing that may
        /// still hold memory of its own, and it is disposed through its own
        /// hook exactly once.
        pub fn deinit(self: *Self) void {
            self.disposeModel();
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
            self.terminal_restored = false;
            // `gpa` is undefined until `start`, and a queue that never grew
            // holds nothing to release.
            if (self.msg_queue.capacity != 0) self.msg_queue.deinit(self.gpa);
            self.msg_queue = .empty;
            self.reader = null;
            self.caps = null;
            self.tick_timer = null;
            self.every_timer = null;
            self.modes = .{};
            self.last_sig = std.math.maxInt(u64);
            self.frame_count = 0;
            self.frame_delta = .zero;
            self.last_tick = null;
            self.watchdog.last_ping = null;
            self.pacer = .{};
            self.frame_stats = .{};
            self.render_requested = false;
            self.running = false;
        }

        // ── messages ──
        /// Enqueue `msg` for `update` on a later frame. The queue copies the value.
        /// Keep referenced payloads live until `update` consumes them or the session ends.
        ///
        /// Returns `error.OutOfMemory` when the queue cannot grow. Nothing is
        /// enqueued and nothing else changes, so the caller decides whether to
        /// retry or to give up: a message is never dropped silently.
        ///
        /// Valid after a successful `start`. Serialize this call with ticks and
        /// lifecycle operations, not only other senders. `run` takes no lock.
        /// Workers should publish into a synchronized slot that the loop reads.
        pub fn send(self: *Self, msg: Msg) std.mem.Allocator.Error!void {
            try self.msg_queue.append(self.gpa, msg);
        }

        /// Ask the loop to stop. The current frame runs to its end, `run`
        /// writes the exit sequence and releases the session.
        pub fn quit(self: *Self) void {
            self.running = false;
        }

        /// True between a successful `start` and the exit `quit` requested.
        pub fn isRunning(self: *const Self) bool {
            return self.running;
        }

        /// Replace the event→`Msg` translator. Returning null drops the event:
        /// the framework never synthesizes a message from it. Ctrl+C arrives
        /// as an ordinary `key_press` (`Key.ctrl_c`), so the filter routes it
        /// to whatever message the app chooses; the library never quits by
        /// itself.
        ///
        /// The function and everything it closes over must outlive the
        /// session. It runs on the loop thread inside the frame, before
        /// `update` for that frame, and may read `Context` but must not
        /// reenter the App.
        pub fn setFilter(self: *Self, f: *const fn (*Context, Event) ?Msg) void {
            self.filter = f;
        }

        // ── effects ──
        /// Execute one command's effect and run what it returns, in order.
        ///
        /// `msg` re-enters `update` within this frame and processes the
        /// command that returns next; `batch` and `sequence` take the same
        /// in-order path, so each element's effects complete before the next
        /// element starts. `tick` and `every` copy their message into the
        /// session's timers, replacing whatever those timers held. `println`
        /// queues a line above the band, `set_title` writes OSC 0, and
        /// `mouse`/`cursor` write their mode sequences immediately.
        ///
        /// `w` is null in a degraded session, where there is no terminal to
        /// write to: mode and title effects are skipped and only the mode
        /// state tracks them.
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
                    const deadline = std.Io.Timestamp.now(self.io.?, .awake)
                        .addDuration(.fromMilliseconds(@as(i64, t.delay_ms)));
                    self.tick_timer = .{ .deadline = deadline, .msg = t.msg };
                },
                .every => |t| {
                    self.every_timer = .{
                        .interval_ms = t.interval_ms,
                        // Anchored at the arm moment: the first fire is one
                        // interval out, and each fire starts the next cycle.
                        .last_fire = std.Io.Timestamp.now(self.io.?, .awake),
                        .msg = t.msg,
                    };
                },
                .println => |text| {
                    if (self.region) |*r| try r.append(.{ .line = text });
                    self.render_requested = true;
                },
                .set_title => |text| {
                    _ = try self.stageTitleNow(text, w);
                },
                .mouse => |on| {
                    // Immediate mode op; the next frame's View.mouse wins.
                    if (try self.stageBytes(if (on) mouse_on else mouse_off, w)) {
                        self.modes.mouse = on;
                    }
                },
                .cursor => |show| {
                    if (try self.stageBytes(if (show) emit.cursor_show else emit.cursor_hide, w)) {
                        self.modes.hide_cursor = show;
                    }
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

        /// Stage an immediate effect (a title or a mode op) through the output
        /// queue and submit it with one nonblocking write attempt. Returns
        /// whether the bytes were staged.
        ///
        /// A false result means the watermark stopped composition: the effect
        /// was not staged and the mode state is left alone, so the frame this
        /// marked for repaint re-emits the declaration the terminal has not
        /// seen. An app that relies on an imperative mode op must therefore
        /// also declare it in the `View` it returns.
        ///
        /// A session without a queue (a degraded session) writes through the
        /// writer it was handed and reports staged: there is no terminal and
        /// nothing to defer to.
        fn stageWith(
            self: *Self,
            w: ?*std.Io.Writer,
            ctx: anytype,
            comptime stage: fn (@TypeOf(ctx), *std.Io.Writer) error{WriteFailed}!void,
        ) error{ FrameTooLarge, WriteFailed }!bool {
            if (self.out) |*q| {
                if (!q.canCompose()) {
                    self.render_requested = true;
                    return false;
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
                return true;
            }
            if (w) |ww| try stage(ctx, ww);
            return true;
        }

        /// Stage `bytes` as one immediate effect. See `stageWith` for what the
        /// result means.
        fn stageBytes(
            self: *Self,
            bytes: []const u8,
            w: ?*std.Io.Writer,
        ) error{ FrameTooLarge, WriteFailed }!bool {
            return self.stageWith(w, StageBytes{ .bytes = bytes }, StageBytes.write);
        }

        /// Write the frame's declared title into the frame in progress, so the
        /// OSC 0 change shares that frame's single write instead of becoming a
        /// write of its own.
        fn stageTitle(self: *Self, title: []const u8, w: *std.Io.Writer) error{WriteFailed}!void {
            _ = self;
            try (StageTitle{ .title = title }).write(w);
        }

        /// The same OSC 0 write as an immediate effect, outside a frame. See
        /// `stageWith` for what the result means.
        fn stageTitleNow(
            self: *Self,
            title: []const u8,
            w: ?*std.Io.Writer,
        ) error{ FrameTooLarge, WriteFailed }!bool {
            return self.stageWith(w, StageTitle{ .title = title }, StageTitle.write);
        }

        // ── internals ──
        /// The interactive half of `start`, after the tty is open and raw:
        /// capability detection, the region, the output queue, the window
        /// size, both arenas, the reader and the clock anchor. Each step that
        /// allocates registers its own cleanup, and `start` covers the whole
        /// sequence.
        fn startTty(self: *Self, io: std.Io, gpa: std.mem.Allocator) !void {
            self.parser = .{};
            self.caps = try caps.Capabilities.detect(gpa, &self.tty.?, &self.parser);
            width.setMode(if (self.caps.?.unicode_core) .grapheme else .codepoint);
            self.region = try Region.init(gpa, .{
                .height = self.opts.region_height,
                .append_lines = self.opts.append_lines,
                // The B2 split: an interactive session, and DEC 2026
                // only when the terminal advertised it.
                .interactive = true,
                .sync_output = self.caps.?.sync_output,
                .resize_mode = self.opts.resize_mode,
                .terminal_reflow = self.opts.terminal_reflow,
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
            try self.region.?.resize(ws.cols, ws.rows, self.opts.region_height);
            self.arena = std.heap.ArenaAllocator.init(gpa);
            self.scratch = std.heap.ArenaAllocator.init(gpa);
            self.reader = Reader.init(&self.tty.?);
            self.last_tick = std.Io.Timestamp.now(io, .awake);
            self.running = true;
        }

        /// The degraded half of `start`, used when stdin is not a terminal: no
        /// tty, no raw mode and no capability detection, a region that emits
        /// one plain frame with no envelope, both arenas, and no reader. The
        /// loop runs a single frame and stops; `run` paints it at exit.
        fn startPlain(self: *Self, gpa: std.mem.Allocator) !void {
            self.region = try Region.init(gpa, .{
                .height = self.opts.region_height,
                .append_lines = self.opts.append_lines,
                // Piped output: no envelope, one plain frame at exit.
                .interactive = false,
                .sync_output = false,
                .resize_mode = self.opts.resize_mode,
                .terminal_reflow = self.opts.terminal_reflow,
            });
            errdefer {
                self.region.?.deinit();
                self.region = null;
            }
            self.arena = std.heap.ArenaAllocator.init(gpa);
            self.scratch = std.heap.ArenaAllocator.init(gpa);
            self.running = true;
        }

        /// Write the exit sequences in order — `Region.exit`, then
        /// `Capabilities.restore` — and get them out. An interactive session
        /// stages them into the output queue and then blocks until every byte
        /// has left, so the terminal never keeps an envelope half-open and
        /// nothing staged is lost.
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
                // The tty writer buffers: without the flush the exit
                // sequences stay in its buffer and the shell inherits a
                // hidden cursor and a prompt written over the band.
                const tw = self.tty.?.writer();
                try q.drainAll(tw);
                try tw.flush();
                self.terminal_restored = true;
                return;
            }
            try self.writeTeardown(w);
            try w.flush();
            self.terminal_restored = true;
        }

        fn writeTeardown(self: *Self, w: anytype) !void {
            if (self.region) |*r| try r.exit(w);
            if (self.caps) |*c| try c.restore(w);
        }

        /// The loop stalled: a frame blew the watchdog budget. Push out what
        /// was staged, restore the terminal, stop composing and return
        /// `error.WatchdogTripped`, so a wedged loop unwinds instead of
        /// painting into a terminal nobody is reading. `run` then unwinds
        /// through its own teardown.
        fn degradeStall(self: *Self) error{WatchdogTripped}!noreturn {
            self.releaseTerminal();
            self.running = false;
            return error.WatchdogTripped;
        }

        /// A fresh `Context` for one model call. Called before each of them so
        /// `render_requested` and the frame buffer changes flow into the frame;
        /// the returned value lives on the caller's stack.
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

        /// True when the region still owes output: a first frame, a pending
        /// resize or height change, queued appends, or a ledger batch the
        /// terminal has not been sent. Such a frame is composed even when the
        /// declaration did not change.
        fn regionPending(self: *Self) bool {
            const r = self.region.?;
            return r.first_frame or r.width_dirty or r.height_dirty or
                r.append_queue.items.len > 0 or r.history.items.len > r.history_written;
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

    pub fn init(_: std.mem.Allocator) !struct { model: TestModel, cmd: Cmd(TestModel.Msg) } {
        return .{ .model = .{}, .cmd = .none };
    }
    pub fn update(self: *TestModel, msg: Msg, _: *Context) !Cmd(Msg) {
        switch (msg) {
            .tick => self.count += 1,
            .inc => self.count += 1,
            .quit => return .quit,
        }
        return .none;
    }
    pub fn view(_: *const TestModel, _: *Context) View(TestModel) {
        return .{ .draw = &draw };
    }
    fn draw(self: *TestModel, _: *Context, buf: *Buffer) !void {
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

    pub fn init(_: std.mem.Allocator) !struct { model: RecModel, cmd: Cmd(RecModel.Msg) } {
        return .{ .model = .{}, .cmd = .none };
    }
    pub fn update(self: *RecModel, msg: Msg, _: *Context) !Cmd(Msg) {
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
    pub fn view(_: *const RecModel, _: *Context) View(RecModel) {
        return .{ .draw = &draw };
    }
    fn draw(_: *RecModel, _: *Context, _: *Buffer) !void {}
};

/// A model for the Ctrl+C filter test.
const CtrlModel = struct {
    pub const Msg = union(enum) { tick, quit };

    pub fn init(_: std.mem.Allocator) !struct { model: CtrlModel, cmd: Cmd(CtrlModel.Msg) } {
        return .{ .model = .{}, .cmd = .none };
    }
    pub fn update(_: *CtrlModel, msg: Msg, _: *Context) !Cmd(Msg) {
        return switch (msg) {
            .quit => .quit,
            .tick => .none,
        };
    }
    pub fn view(_: *const CtrlModel, _: *Context) View(CtrlModel) {
        return .{ .draw = &draw };
    }
    fn draw(_: *CtrlModel, _: *Context, buf: *Buffer) !void {
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
    fn drainAll(self: *FakeTty, sink: *std.ArrayList(u8)) !void {
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
        const chunk: [4096]u8 = @splat('.');
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

/// The fake-tty session `setupInteractive` builds: the app under test and the
/// test's end of the fake tty.
///
/// Construct in the caller's final storage: the reader borrows the App's embedded
/// tty, so returning an initialized fixture by value would leave a dangling pointer.
fn InteractiveFixture(comptime M: type) type {
    return struct {
        const Self = @This();
        app: App(M),
        tty: FakeTty,

        /// Release the app before the test ends of its fake tty; invalidate the fixture.
        fn deinit(self: *Self) void {
            self.app.deinit();
            self.tty.deinit();
            self.* = undefined;
        }
    };
}

/// Wire an app's runtime state against a fake tty, as `start` would for a real
/// terminal, minus the live capability queries (the fake never replies;
/// detection would burn five 250 ms deadlines per test).
///
/// The caller supplies stable storage and releases initialized resources with `deinit`.
fn setupInteractive(
    comptime M: type,
    fixture: *InteractiveFixture(M),
    opts: App(M).Options,
) !void {
    fixture.tty = try FakeTty.init();
    errdefer fixture.tty.deinit();

    // Built in place, so the reader below borrows this tty's final address.
    fixture.app = App(M).initWithOptions(opts);
    const app = &fixture.app;
    app.io = testing.io;
    app.gpa = testing.allocator;
    app.tty = fixture.tty.tty();
    errdefer app.deinit();
    app.caps = .{};
    app.region = try Region.init(testing.allocator, .{
        .height = opts.region_height,
        .append_lines = opts.append_lines,
        .interactive = true,
        .sync_output = true,
        .resize_mode = opts.resize_mode,
        .terminal_reflow = opts.terminal_reflow,
    });
    // The fake tty has no screen: the band's own rows are the whole
    // visible viewport, so no row is ever physically clipped here.
    try app.region.?.resize(80, opts.region_height, opts.region_height);
    app.out = try output.OutputQueue.init(testing.allocator, opts.output);
    app.arena = std.heap.ArenaAllocator.init(testing.allocator);
    app.scratch = std.heap.ArenaAllocator.init(testing.allocator);
    app.reader = Reader.init(&app.tty.?);
    app.last_tick = std.Io.Timestamp.now(testing.io, .awake);
    app.running = true;
    // Mirror `start`: init builds the model and its initial Cmd is
    // processed through the normal effect path (arms init timers).
    try app.processInit();
}

/// A valid model (passes the contract check).
const GoodModel = struct {
    pub const Msg = union(enum) { tick };
    pub fn init(_: std.mem.Allocator) !struct { model: GoodModel, cmd: Cmd(GoodModel.Msg) } {
        return .{ .model = .{}, .cmd = .none };
    }
    pub fn update(_: *GoodModel, _: Msg, _: *Context) !Cmd(Msg) {
        return .none;
    }
    pub fn view(_: *const GoodModel, _: *Context) View(GoodModel) {
        return .{ .draw = &draw };
    }
    fn draw(_: *GoodModel, _: *Context, _: *Buffer) !void {}
};

/// A model missing Msg/update/view (fails the contract check).
const BadModel = struct {
    pub fn init(_: std.mem.Allocator) !BadModel {
        return .{};
    }
};

/// An app wired with enough runtime state (region + arena) for
/// processCmd-level tests — no tty, no reader.
fn cmdApp(comptime M: type) !App(M) {
    var app = App(M).init();
    app.model = (try M.init(testing.allocator)).model;
    // The model exists, so `deinit` owns its release, exactly as after a
    // real `start`.
    app.model_ready = true;
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
    // the single plain frame is painted by `run` at exit.
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

    pub fn init(_: std.mem.Allocator) !struct { model: PlainModel, cmd: Cmd(Msg) } {
        return .{ .model = .{}, .cmd = .none };
    }
    pub fn update(_: *PlainModel, _: Msg, _: *Context) !Cmd(Msg) {
        return .none;
    }
    pub fn view(_: *const PlainModel, _: *Context) View(PlainModel) {
        return .{ .draw = &draw, .title = "window" };
    }
    fn draw(_: *PlainModel, _: *Context, buf: *Buffer) !void {
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

/// A model whose `init` refuses: the runtime is already built when it runs, so
/// its failure is the one that must still release everything.
const RefusedInitModel = struct {
    pub const Msg = union(enum) { pulse };

    pub fn init(_: std.mem.Allocator) !struct { model: RefusedInitModel, cmd: Cmd(Msg) } {
        return error.InitRefused;
    }
    pub fn update(_: *RefusedInitModel, _: Msg, _: *Context) !Cmd(Msg) {
        return .none;
    }
    pub fn view(_: *const RefusedInitModel, _: *Context) View(RefusedInitModel) {
        return .{ .draw = &draw };
    }
    fn draw(_: *RefusedInitModel, _: *Context, buf: *Buffer) !void {
        _ = try buf.draw(.{}, "x", 0, 0);
    }
};

/// The degraded acquisition, for the allocation-failure sweep. It owns a
/// local App, so the run either returns with everything released or fails
/// with the same cleanup `start` installed.
fn acquireDegraded(gpa: std.mem.Allocator) !void {
    var app = App(TestModel).init();
    try app.acquire(testing.io, gpa, false);
    app.deinit();
}

test "app: a failed Model.init leaves nothing owned and no loop running" {
    var app = App(RefusedInitModel).init();
    // The degraded route: no terminal to make raw, but the same single
    // cleanup every route installs, with the runtime already built.
    try testing.expectError(error.InitRefused, app.acquire(testing.io, testing.allocator, false));

    try testing.expect(app.region == null);
    try testing.expect(app.arena == null);
    try testing.expect(app.scratch == null);
    try testing.expect(app.out == null);
    try testing.expect(app.transcript == null);
    try testing.expect(app.reader == null);
    try testing.expect(app.caps == null);
    try testing.expect(app.tty == null);
    try testing.expectEqual(@as(usize, 0), app.msg_queue.capacity);
    try testing.expect(!app.isRunning());

    // Releasing again is a no-op on the same instance.
    app.deinit();
    try testing.expect(!app.isRunning());
}

test "app: restarting does not inherit a stale heartbeat or session measurements" {
    // The first session is a live runtime with an output queue, so its frame
    // really composes: the counters the restart has to clear start from a
    // measured frame, not from a runtime that never painted anything.
    var app = try setupHeadless(TestModel);
    defer app.deinit();
    var sink: CountingSink = .{};
    const transport = output.Transport.from(&sink);

    app.watchdog.budget_ns = 3 * watchdog.default_budget_ns;
    try app.send(.inc);
    try app.tick();
    try testing.expectEqual(@as(i32, 1), app.model.count);
    const taken = try app.frameHeadless(transport);
    try testing.expect(taken > 0);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.delivered(), "hi"));
    try testing.expectEqual(@as(u64, 1), app.frame_stats.frames);
    try testing.expectEqual(@as(u64, 1), app.pacer.samples);

    // A heartbeat older than the budget: exactly what must not survive the
    // restart, and armed, so the reset is observable rather than assumed.
    const now = std.Io.Timestamp.now(testing.io, .awake);
    app.watchdog.ping(.fromNanoseconds(
        now.nanoseconds - @as(i96, app.watchdog.budget_ns) - 1,
    ));
    try testing.expect(app.watchdog.tripped(now));
    app.deinit();
    try testing.expect(!app.watchdog.armed());

    // The second session is the degraded route: a live runtime — region and
    // arenas — but no output queue, so a headless frame composes nothing and
    // every counter the first session filled is gone.
    try app.acquire(testing.io, testing.allocator, false);
    try testing.expect(app.out == null);
    try app.send(.inc);
    // An inherited heartbeat this stale would stall the frame right here.
    try app.tick();
    try testing.expect(app.watchdog.armed());
    try testing.expectEqual(@as(i32, 1), app.model.count);
    try testing.expectEqual(@as(usize, 0), try app.frameHeadless(transport));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.delivered(), "hi"));
    try testing.expectEqual(@as(u64, 0), app.frame_stats.frames);
    try testing.expectEqual(@as(u64, 0), app.pacer.samples);
    // The budget is configuration, not session state, so it outlives deinit.
    try testing.expectEqual(3 * watchdog.default_budget_ns, app.watchdog.budget_ns);
}

/// A model that owns memory from the session allocator and returns a command
/// that allocates too, so a startup failure can land on either side of the
/// model existing.
const OwnedModel = struct {
    pub const Msg = union(enum) { tick };
    buf: []u8 = &.{},
    disposals: usize = 0,

    pub fn init(gpa: std.mem.Allocator) !struct { model: OwnedModel, cmd: Cmd(Msg) } {
        return .{
            .model = .{ .buf = try gpa.alloc(u8, 64) },
            .cmd = .{ .println = "note" },
        };
    }

    /// The model's own release path. The App calls this exactly once per
    /// successful `init`.
    pub fn deinit(self: *OwnedModel, gpa: std.mem.Allocator) void {
        self.disposals += 1;
        if (self.buf.len != 0) gpa.free(self.buf);
        self.buf = &.{};
    }

    pub fn update(_: *OwnedModel, _: Msg, _: *Context) !Cmd(Msg) {
        return .none;
    }
    pub fn view(_: *const OwnedModel, _: *Context) View(OwnedModel) {
        return .{ .draw = &draw };
    }
    fn draw(_: *OwnedModel, _: *Context, buf: *Buffer) !void {
        _ = try buf.draw(.{}, "o", 0, 0);
    }
};

/// The same acquisition driven by the owning model, for the sweep below.
fn acquireOwned(gpa: std.mem.Allocator) !void {
    var app = App(OwnedModel).init();
    try app.acquire(testing.io, gpa, false);
    app.deinit();
}

test "app: the model is disposed once, and only when it was built" {
    var app = App(OwnedModel).init();
    try app.acquire(testing.io, testing.allocator, false);
    try testing.expect(app.model_ready);

    app.deinit();
    try testing.expectEqual(@as(usize, 1), app.model.disposals);
    try testing.expect(!app.model_ready);

    // The same instance, released again: nothing is disposed twice.
    app.deinit();
    try testing.expectEqual(@as(usize, 1), app.model.disposals);
}

test "app: a model that never started is not disposed" {
    // A refusing `init` returns no model, so there is nothing to release and
    // nothing may reach for one.
    var app = App(RefusedInitModel).init();
    try testing.expectError(error.InitRefused, app.acquire(testing.io, testing.allocator, false));
    try testing.expect(!app.model_ready);
}

test "app: an allocation failure anywhere in startup releases the model too" {
    // Failing every allocation index in turn reaches the case where the model
    // was built and its initial command then failed: that memory is the
    // model's, and only the model's own hook can give it back.
    try testing.checkAllAllocationFailures(testing.allocator, acquireOwned, .{});
}

test "app: an allocation failure anywhere in startup releases what came before" {
    // Every allocation index is failed in turn: a step whose cleanup was
    // registered too late leaks here.
    try testing.checkAllAllocationFailures(testing.allocator, acquireDegraded, .{});
}

test "app: send reports the allocator failure and keeps the message deliverable" {
    var setup: InteractiveFixture(TimerModel) = undefined;
    try setupInteractive(TimerModel, &setup, .{ .fps = 1000 });
    defer setup.deinit();

    // The queue cannot grow: the message is not enqueued, the failure is
    // reported, and the model has not seen anything.
    setup.app.gpa = testing.failing_allocator;
    defer setup.app.gpa = testing.allocator;
    try testing.expectError(error.OutOfMemory, setup.app.send(.pulse));
    try testing.expectEqual(@as(usize, 0), setup.app.msg_queue.items.len);

    // Nothing was consumed on the way out, so the same call succeeds. The
    // session allocator is restored HERE, not at scope exit: everything below
    // is the success path and has to run on an allocator that still works.
    setup.app.gpa = testing.allocator;
    try setup.app.send(.pulse);
    try setup.app.tick();
    try testing.expectEqualStrings("p", setup.app.model.seen[0..1]);
}

test "app: Ctrl+C routes through the filter to quit (never hard-quits)" {
    var setup: InteractiveFixture(CtrlModel) = undefined;
    try setupInteractive(CtrlModel, &setup, .{ .fps = 0 });
    defer setup.deinit();
    setup.app.setFilter(&ctrlCFilter);

    try setup.tty.writeInput("\x03");
    try setup.app.tick();
    try testing.expect(!setup.app.isRunning());
}

test "app: without a filter Ctrl+C is dropped and the loop keeps running" {
    var setup: InteractiveFixture(CtrlModel) = undefined;
    try setupInteractive(CtrlModel, &setup, .{ .fps = 0 });
    defer setup.deinit();

    try setup.tty.writeInput("\x03");
    try setup.app.tick();
    try testing.expect(setup.app.isRunning());
}

test "app: fps-zero replaces a stale geometry query without a model message" {
    var setup: InteractiveFixture(TestModel) = undefined;
    try setupInteractive(TestModel, &setup, .{ .fps = 0 });
    defer setup.deinit();
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);

    try setup.tty.writeInput("x");
    try setup.app.tick();
    try setup.tty.drainAll(&captured);
    try testing.expect(std.mem.indexOf(u8, captured.items, "\x1b[6n") != null);
    captured.clearRetainingCapacity();

    try setup.tty.writeInput("\x1b[48;6;80t");
    try setup.app.tick();
    try setup.tty.drainAll(&captured);
    try testing.expect(std.mem.indexOf(u8, captured.items, "\x1b[6n") == null);
    captured.clearRetainingCapacity();

    try setup.tty.writeInput("\x1b[3;1R");
    try setup.app.tick();
    try setup.tty.drainAll(&captured);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, captured.items, "\x1b[6n"));
    try testing.expectEqual(@as(u16, 0), setup.app.region.?.anchorRow());

    try setup.tty.writeInput("\x1b[3;1R");
    try setup.app.tick();
    try testing.expectEqual(@as(u16, 1), setup.app.region.?.anchorRow());
    try testing.expectEqual(@as(i32, 0), setup.app.model.count);
}

test "app: send drains next tick; quit breaks the loop; isRunning reflects state" {
    var fresh = App(TestModel).init();
    try testing.expect(!fresh.isRunning());

    var setup: InteractiveFixture(TestModel) = undefined;
    try setupInteractive(TestModel, &setup, .{ .fps = 1000 });
    defer setup.deinit();

    try testing.expect(setup.app.isRunning());
    try setup.app.send(.inc);
    try setup.app.tick();
    try testing.expectEqual(@as(i32, 1), setup.app.model.count);

    try setup.app.send(.quit);
    try setup.app.tick();
    try testing.expect(!setup.app.isRunning());
}

test "app: unchanged View signature skips draw on idle ticks" {
    var setup: InteractiveFixture(TestModel) = undefined;
    try setupInteractive(TestModel, &setup, .{ .fps = 1000 });
    defer setup.deinit();

    try setup.app.tick(); // first frame: signature change → draw
    try testing.expectEqual(@as(usize, 1), setup.app.model.draws);

    try setup.app.tick(); // idle: no event/msg, stable signature → skip
    try testing.expectEqual(@as(usize, 1), setup.app.model.draws);

    try setup.app.send(.inc); // a dispatched msg forces the frame
    try setup.app.tick();
    try testing.expectEqual(@as(usize, 2), setup.app.model.draws);
}

/// A model whose drawn text is allocated from the session `frame_arena`, which
/// the frame Buffer's cells borrow, and which changes every frame. With a
/// per-frame reset the previous frame's cells would alias reused memory, the
/// comparison would see stale content, and changed frames would never repaint.
const ArenaDrawModel = struct {
    pub const Msg = union(enum) { tick };
    frame: usize = 0,

    pub fn init(_: std.mem.Allocator) !struct { model: ArenaDrawModel, cmd: Cmd(ArenaDrawModel.Msg) } {
        return .{ .model = .{}, .cmd = .none };
    }
    pub fn update(self: *ArenaDrawModel, _: Msg, ctx: *Context) !Cmd(Msg) {
        self.frame += 1;
        ctx.render_requested = true;
        return .none;
    }
    pub fn view(_: *const ArenaDrawModel, _: *Context) View(ArenaDrawModel) {
        return .{ .draw = &draw };
    }
    fn draw(self: *ArenaDrawModel, ctx: *Context, buf: *Buffer) !void {
        // No space: blank cells emit no bytes (the row erase covers them),
        // so assert on the exact byte stream.
        const text = try std.fmt.allocPrint(ctx.frame_arena, "frame{d}", .{self.frame});
        _ = try buf.draw(.{}, text, 0, 0);
    }
};

/// Draws a long row on its first frame and a short one afterwards.
const ShrinkModel = struct {
    pub const Msg = union(enum) { tick };
    frame: usize = 0,

    pub fn init(_: std.mem.Allocator) !struct { model: ShrinkModel, cmd: Cmd(ShrinkModel.Msg) } {
        return .{ .model = .{}, .cmd = .none };
    }
    pub fn update(self: *ShrinkModel, _: Msg, ctx: *Context) !Cmd(Msg) {
        self.frame += 1;
        ctx.render_requested = true;
        return .none;
    }
    pub fn view(_: *const ShrinkModel, _: *Context) View(ShrinkModel) {
        return .{ .draw = &draw };
    }
    fn draw(self: *ShrinkModel, _: *Context, buf: *Buffer) !void {
        _ = try buf.draw(.{}, if (self.frame == 1) "count: 10 quit" else "count: 9 quit", 0, 0);
    }
};

test "app: a frame that draws shorter text leaves no tail of the previous one" {
    var setup: InteractiveFixture(ShrinkModel) = undefined;
    try setupInteractive(ShrinkModel, &setup, .{ .fps = 1000 });
    defer setup.deinit();

    try setup.app.send(.tick);
    try setup.app.tick();
    try setup.app.send(.tick);
    try setup.app.tick();
    // The second frame drew 13 cells; the 14th held the first frame's `t`.
    const cur = &setup.app.region.?.cur;
    try testing.expectEqualStrings("t", cur.get(12, 0).grapheme);
    try testing.expectEqualStrings(" ", cur.get(13, 0).grapheme);
}

test "app: frame_arena text repaints when the content changes (no prev aliasing)" {
    var setup: InteractiveFixture(ArenaDrawModel) = undefined;
    try setupInteractive(ArenaDrawModel, &setup, .{ .fps = 1000 });
    defer setup.deinit();

    try setup.app.send(.tick);
    try setup.app.tick(); // draws "frame1"
    var out: [4096]u8 = undefined;
    const n1 = setup.tty.drainOutput(&out);
    try testing.expect(std.mem.indexOf(u8, out[0..n1], "frame1") != null);

    try setup.app.send(.tick);
    try setup.app.tick(); // must repaint: the diff emits "frame2"
    const n2 = setup.tty.drainOutput(&out);
    try testing.expect(std.mem.indexOf(u8, out[0..n2], "frame2") != null);
}

test "app: a SIGWINCH resizes the band on the next tick" {
    var setup: InteractiveFixture(ArenaDrawModel) = undefined;
    try setupInteractive(ArenaDrawModel, &setup, .{ .fps = 1000 });
    defer setup.deinit();
    try setup.app.region.?.resize(40, 24, 2);
    try setup.app.send(.tick);
    try setup.app.tick();
    try testing.expectEqual(@as(u16, 40), setup.app.region.?.width);

    // The fake tty is a socket, so `getWinsize` reports its 80x24
    // fallback: the band must take that width without an in-band report.
    setup.app.tty.?.markResized();
    try setup.app.tick();
    try testing.expectEqual(@as(u16, 80), setup.app.region.?.width);
}

test "app: an interactive teardown reaches the terminal" {
    var setup: InteractiveFixture(ArenaDrawModel) = undefined;
    try setupInteractive(ArenaDrawModel, &setup, .{ .fps = 1000 });
    defer setup.deinit();

    try setup.app.send(.tick);
    try setup.app.tick();
    var out: [4096]u8 = undefined;
    _ = setup.tty.drainOutput(&out);

    // The same call `run` makes after its loop: the exit sequences must be
    // on the wire when it returns, not parked in the tty's write buffer.
    // `Tty.writer` writes the terminal descriptor, whose far end is `b`.
    try setup.app.emitTeardown(setup.app.tty.?.writer());
    var pfd = [_]posix.pollfd{.{ .fd = setup.tty.b, .events = posix.POLL.IN, .revents = 0 }};
    const ready = try posix.poll(&pfd, 0);
    const far: std.Io.File = .{ .handle = setup.tty.b, .flags = .{ .nonblocking = false } };
    const n = if (ready > 0) try far.readStreaming(testing.io, &.{&out}) else 0;
    const bytes = out[0..n];
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?25h") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\r\n") != null);
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

test "cmd: sequence drains each element in order, on the batch path" {
    var app = try cmdApp(RecModel);
    defer app.deinit();
    var ctx = app.makeCtx();
    var tw: TestWriter = .{};
    tw.init();

    try app.processCmd(.{ .sequence = &.{ .{ .msg = .a }, .{ .msg = .b } } }, &ctx, &tw.w);
    try testing.expectEqualStrings("abb", app.model.log[0..3]);
}

/// A model whose `Msg` has no `tick` payload at all: a timer carries the
/// message it will deliver, so nothing requires a conventionally named field.
const TimerModel = struct {
    pub const Msg = union(enum) { pulse, beat, stop };
    seen: [8]u8 = undefined,
    seen_len: usize = 0,

    pub fn init(_: std.mem.Allocator) !struct { model: TimerModel, cmd: Cmd(TimerModel.Msg) } {
        return .{ .model = .{}, .cmd = .none };
    }
    pub fn update(self: *TimerModel, msg: Msg, _: *Context) !Cmd(Msg) {
        self.seen[self.seen_len] = switch (msg) {
            .pulse => 'p',
            .beat => 'b',
            .stop => 's',
        };
        self.seen_len += 1;
        return .none;
    }
    pub fn view(_: *const TimerModel, _: *Context) View(TimerModel) {
        return .{ .draw = &draw };
    }
    fn draw(_: *TimerModel, _: *Context, buf: *Buffer) !void {
        _ = try buf.draw(.{}, "t", 0, 0);
    }
};

test "cmd: tick delivers exactly the message it was armed with, once" {
    // The premise: this model's message type has no `tick` field, so a timer
    // that worked would have to carry its own payload.
    try testing.expect(!@hasField(TimerModel.Msg, "tick"));

    var setup: InteractiveFixture(TimerModel) = undefined;
    try setupInteractive(TimerModel, &setup, .{ .fps = 1000 });
    defer setup.deinit();
    var ctx = setup.app.makeCtx();
    var tw: TestWriter = .{};
    tw.init();

    try setup.app.processCmd(.{ .tick = .{ .delay_ms = 40, .msg = .pulse } }, &ctx, &tw.w);
    try testing.expect(setup.app.tick_timer != null);

    try setup.app.tick(); // before the deadline: nothing delivered
    try testing.expectEqual(@as(usize, 0), setup.app.model.seen_len);

    try std.Io.sleep(testing.io, .fromMilliseconds(60), .awake);
    try setup.app.tick(); // deadline passed: its own message, not a `tick`
    try testing.expectEqualStrings("p", setup.app.model.seen[0..1]);

    try setup.app.tick(); // one-shot: disarmed, nothing more
    try testing.expectEqual(@as(usize, 1), setup.app.model.seen_len);
    try testing.expect(setup.app.tick_timer == null);
}

test "cmd: every delivers its own message each interval, and re-arming replaces it" {
    var setup: InteractiveFixture(TimerModel) = undefined;
    try setupInteractive(TimerModel, &setup, .{ .fps = 1000 });
    defer setup.deinit();
    var ctx = setup.app.makeCtx();
    var tw: TestWriter = .{};
    tw.init();

    try setup.app.processCmd(.{ .every = .{ .interval_ms = 30, .msg = .beat } }, &ctx, &tw.w);

    try setup.app.tick(); // armed this frame: the first fire is one interval out
    try testing.expectEqual(@as(usize, 0), setup.app.model.seen_len);

    try std.Io.sleep(testing.io, .fromMilliseconds(50), .awake);
    try setup.app.tick(); // due: delivers the armed message and starts a cycle
    try testing.expectEqualStrings("b", setup.app.model.seen[0..1]);

    try setup.app.tick(); // just re-armed: not due again
    try testing.expectEqual(@as(usize, 1), setup.app.model.seen_len);

    // Re-arming replaces the message, the interval and the cycle anchor.
    try setup.app.processCmd(.{ .every = .{ .interval_ms = 10, .msg = .pulse } }, &ctx, &tw.w);
    try std.Io.sleep(testing.io, .fromMilliseconds(50), .awake);
    try setup.app.tick();
    try testing.expectEqualStrings("bp", setup.app.model.seen[0..2]);

    try std.Io.sleep(testing.io, .fromMilliseconds(50), .awake);
    try setup.app.tick();
    try testing.expectEqualStrings("bpp", setup.app.model.seen[0..3]);
}

test "cmd: a due timer that cannot enqueue keeps its slot and retries" {
    var setup: InteractiveFixture(TimerModel) = undefined;
    try setupInteractive(TimerModel, &setup, .{ .fps = 1000 });
    defer setup.deinit();
    var ctx = setup.app.makeCtx();
    var tw: TestWriter = .{};
    tw.init();

    try setup.app.processCmd(.{ .tick = .{ .delay_ms = 1, .msg = .pulse } }, &ctx, &tw.w);
    try std.Io.sleep(testing.io, .fromMilliseconds(20), .awake);

    // The queue cannot grow, so the message is not delivered and the failure
    // is reported rather than swallowed.
    setup.app.gpa = testing.failing_allocator;
    defer setup.app.gpa = testing.allocator;
    try testing.expectError(error.OutOfMemory, setup.app.tick());
    try testing.expectEqual(@as(usize, 0), setup.app.model.seen_len);
    // The timer is still armed, so the message is retried rather than lost.
    try testing.expect(setup.app.tick_timer != null);

    // Back on the session allocator: the retry below must find a queue that
    // can grow, which is the whole point of the timer keeping its slot.
    setup.app.gpa = testing.allocator;
    try setup.app.tick();
    try testing.expectEqualStrings("p", setup.app.model.seen[0..1]);
    try testing.expect(setup.app.tick_timer == null);
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

    pub fn init(_: std.mem.Allocator) !struct { model: InitCmdModel, cmd: Cmd(InitCmdModel.Msg) } {
        return .{ .model = .{}, .cmd = .{ .every = .{ .interval_ms = 30, .msg = .tick } } };
    }
    pub fn update(self: *InitCmdModel, msg: Msg, _: *Context) !Cmd(Msg) {
        switch (msg) {
            .tick => self.ticks += 1,
        }
        return .none;
    }
    pub fn view(_: *const InitCmdModel, _: *Context) View(InitCmdModel) {
        return .{ .draw = &draw };
    }
    fn draw(self: *InitCmdModel, _: *Context, buf: *Buffer) !void {
        self.draws += 1;
        _ = try buf.draw(.{}, "tick", 0, 0);
    }
};

test "app: init's every Cmd arms the timer — Msg.tick fires and renders with no input" {
    var setup: InteractiveFixture(InitCmdModel) = undefined;
    try setupInteractive(InitCmdModel, &setup, .{ .fps = 1000 });
    defer setup.deinit();

    // The initial Cmd was processed during setup (mirroring `start`):
    // the periodic timer is armed before any event/msg exists.
    try testing.expectEqual(@as(u32, 30), setup.app.every_timer.?.interval_ms);

    try setup.app.tick(); // armed this frame: first fire is one interval away
    try testing.expectEqual(@as(usize, 0), setup.app.model.ticks);
    try testing.expectEqual(@as(usize, 1), setup.app.model.draws); // first-frame render

    try std.Io.sleep(testing.io, .fromMilliseconds(50), .awake);
    try setup.app.tick(); // due: Msg.tick delivered and the frame re-renders
    try testing.expectEqual(@as(usize, 1), setup.app.model.ticks);
    try testing.expectEqual(@as(usize, 2), setup.app.model.draws);
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

test "cmd: set_title writes OSC 0" {
    var app = try cmdApp(RecModel);
    defer app.deinit();
    var ctx = app.makeCtx();
    var tw: TestWriter = .{};
    tw.init();

    try app.processCmd(.{ .set_title = "counter" }, &ctx, &tw.w);
    try testing.expectEqualStrings("\x1b]0;counter\x07", tw.w.buffered());
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
    // Headless: band-only viewport, as in `setupInteractive`.
    try app.region.?.resize(80, 2, 2);
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

    pub fn init(_: std.mem.Allocator) !struct { model: ChurnModel, cmd: Cmd(ChurnModel.Msg) } {
        return .{ .model = .{}, .cmd = .none };
    }
    pub fn update(_: *ChurnModel, _: Msg, _: *Context) !Cmd(Msg) {
        return .none;
    }
    pub fn view(_: *const ChurnModel, _: *Context) View(ChurnModel) {
        return .{ .draw = &draw };
    }
    fn draw(self: *ChurnModel, ctx: *Context, buf: *Buffer) !void {
        const text = try std.fmt.allocPrint(ctx.frame_arena, "f{d}", .{self.frame});
        _ = try buf.draw(.{}, text, 0, 0);
        self.draws += 1;
    }
};

test "app: headless frames stage and submit in one write each" {
    var app = try setupHeadless(ChurnModel);
    defer app.deinit();
    var sink: CountingSink = .{};
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
    var sink: CountingSink = .{ .block = true };
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
    var sink: CountingSink = .{ .short = 5 };
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
    try testing.expectEqual(@as(usize, 1), (try app.region.?.historyPending()).len);
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
    // and the receipt was acknowledged with them.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.delivered(), "idle\r\n"));
    try testing.expectEqual(@as(usize, 0), (try app.region.?.historyPending()).len);
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
    var setup: InteractiveFixture(ChurnModel) = undefined;
    try setupInteractive(ChurnModel, &setup, .{
        .fps = 1000,
        .output = .{ .capacity = 2048, .watermark = 512 },
    });
    defer setup.deinit();

    // The fake terminal's buffer is full and nobody drains it, so every
    // submit would block. Each tick sends a message because a frame is
    // only owed when something asks for one: mutating the model behind
    // an unchanged View signature composes nothing at all.
    const filler = try setup.tty.stopReading();
    var staged: usize = 0;
    for (0..40) |i| {
        try setup.app.send(.tick);
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
        try setup.app.send(.tick);
        try setup.app.tick();
    }
    try testing.expectEqual(composed, setup.app.frame_stats.frames);
    try testing.expectEqual(queued, q.pending());

    // The reader drains: every staged byte arrives, byte for byte, so
    // backpressure cost latency, never content. The filler the stopped
    // terminal left behind is not the App's and is not counted.
    var delivered: std.ArrayList(u8) = .empty;
    defer delivered.deinit(testing.allocator);
    for (0..20) |i| {
        try setup.tty.drainAll(&delivered);
        try setup.app.send(.tick);
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
    var setup: InteractiveFixture(ChurnQuitModel) = undefined;
    try setupInteractive(ChurnQuitModel, &setup, .{
        .fps = 1000,
        .output = .{ .capacity = 1024, .watermark = 256 },
    });
    defer setup.deinit();
    setup.app.setFilter(&ctrlCQuitFilter);

    // The fake terminal's buffer is full and nobody drains it, so the
    // transport blocks, the watermark stops composition, and frames
    // queue up behind it.
    _ = try setup.tty.stopReading();
    for (0..40) |i| {
        try setup.app.send(.tick);
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

    pub fn init(_: std.mem.Allocator) !struct { model: ChurnQuitModel, cmd: Cmd(ChurnQuitModel.Msg) } {
        return .{ .model = .{}, .cmd = .none };
    }
    pub fn update(_: *ChurnQuitModel, msg: Msg, _: *Context) !Cmd(Msg) {
        return switch (msg) {
            .quit => .quit,
            .tick => .none,
        };
    }
    pub fn view(_: *const ChurnQuitModel, _: *Context) View(ChurnQuitModel) {
        return .{ .draw = &draw };
    }
    fn draw(self: *ChurnQuitModel, ctx: *Context, buf: *Buffer) !void {
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
    var sink: CountingSink = .{};
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
    try testing.expectEqual(@as(usize, 0), (try app.region.?.historyPending()).len);
    try testing.expectEqual(@as(?transcript.State, null), app.transcript.?.stateOf(a));
    try testing.expectEqual(@as(usize, 1), app.transcript.?.liveBlocks());

    // The next frame retires `beta` behind its own receipt: both rows
    // reached the terminal and both blocks left the mutable view for
    // good.
    _ = try app.frameHeadless(transport);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.delivered(), "beta\r\n"));
    try testing.expectEqual(@as(usize, 0), (try app.region.?.historyPending()).len);
    try testing.expectEqual(@as(?transcript.State, null), app.transcript.?.stateOf(b));
    try testing.expectEqual(@as(usize, 0), app.transcript.?.liveBlocks());

    // Exactly once: later frames find nothing to retire, so neither row
    // is ever written a second time.
    _ = try app.frameHeadless(transport);
    _ = try app.frameHeadless(transport);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.delivered(), "alpha\r\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.delivered(), "beta\r\n"));
    try testing.expectEqual(@as(usize, 0), (try app.region.?.historyPending()).len);
    try testing.expectEqual(@as(usize, 0), app.transcript.?.liveBlocks());
}

test "app: a blocked transport defers the transcript delta, then commits once" {
    var app = try setupHeadless(GoodModel);
    defer app.deinit();
    var sink: CountingSink = .{ .block = true };
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
    try testing.expectEqual(@as(usize, 1), (try app.region.?.historyPending()).len);

    sink.block = false;
    _ = try app.frameHeadless(transport);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.delivered(), "held\r\n"));
    try testing.expectEqual(@as(usize, 0), app.transcript.?.liveBlocks());
    try testing.expectEqual(@as(usize, 0), (try app.region.?.historyPending()).len);
}

test "app: a refused ledger enqueue retries the same delta, losing nothing" {
    var app = try setupHeadless(GoodModel);
    defer app.deinit();
    var sink: CountingSink = .{};
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
    try testing.expectEqual(@as(usize, 0), (try app.region.?.historyPending()).len);
    try testing.expectEqual(@as(usize, 1), app.transcript.?.liveBlocks());

    // The retry re-emits the SAME rows and the SAME block: they reach
    // the terminal exactly once, and the block is committed behind its
    // own receipt.
    app.region.?.opts.max_history_bytes = 256 * 1024;
    _ = try app.frameHeadless(transport);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.delivered(), "kept\r\n"));
    try testing.expectEqual(@as(usize, 0), (try app.region.?.historyPending()).len);
    try testing.expectEqual(@as(?transcript.State, null), app.transcript.?.stateOf(a));
}

test "app: an overflowing frame leaves the region retryable, nothing doubled" {
    var app = try setupHeadless(ChurnModel);
    defer app.deinit();
    var sink: CountingSink = .{};
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

    pub fn init(_: std.mem.Allocator) !struct { model: HeaderModel, cmd: Cmd(HeaderModel.Msg) } {
        return .{ .model = .{}, .cmd = .none };
    }
    pub fn update(_: *HeaderModel, _: Msg, _: *Context) !Cmd(Msg) {
        return .none;
    }
    pub fn view(self: *const HeaderModel, _: *Context) View(HeaderModel) {
        return .{ .draw = &draw, .mouse = self.mouse, .title = self.title };
    }
    fn draw(self: *HeaderModel, _: *Context, buf: *Buffer) !void {
        self.draws += 1;
        _ = try buf.draw(.{}, "hdr", 0, 0);
    }
};

test "app: a failed mode or title stage re-emits on retry, nothing published" {
    var app = try setupHeadless(HeaderModel);
    defer app.deinit();
    var sink: CountingSink = .{};
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

/// Declares its own paint errors, so the View's error set is the model's and
/// not the allocator's.
const PaintFailModel = struct {
    pub const Msg = union(enum) { tick };
    pub const DrawError = std.mem.Allocator.Error || error{NoGlyph};
    fail: bool = false,
    draws: usize = 0,

    pub fn init(_: std.mem.Allocator) !struct { model: PaintFailModel, cmd: Cmd(PaintFailModel.Msg) } {
        return .{ .model = .{}, .cmd = .none };
    }
    pub fn update(_: *PaintFailModel, _: Msg, _: *Context) !Cmd(Msg) {
        return .none;
    }
    pub fn view(_: *const PaintFailModel, _: *Context) View(PaintFailModel) {
        return .{ .draw = &draw };
    }
    fn draw(self: *PaintFailModel, _: *Context, buf: *Buffer) DrawError!void {
        self.draws += 1;
        if (self.fail) return error.NoGlyph;
        _ = try buf.draw(.{}, "glyph", 0, 0);
    }
};

test "app: a model's own paint error aborts the frame and reaches the caller" {
    var app = try setupHeadless(PaintFailModel);
    defer app.deinit();
    var sink: CountingSink = .{};
    const transport = output.Transport.from(&sink);

    app.model.fail = true;
    try testing.expectError(error.NoGlyph, app.frameHeadless(transport));
    try testing.expectEqual(@as(usize, 0), sink.len);
    // Nothing was published and the frame is still owed whole.
    try testing.expect(app.region.?.first_frame);
    try testing.expect(app.render_requested);

    // The retry paints the complete frame, once.
    app.model.fail = false;
    _ = try app.frameHeadless(transport);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.delivered(), "glyph"));
    try testing.expect(!app.region.?.first_frame);
}

test "cmd: a mode op the watermark deferred leaves the mode state honest" {
    var setup: InteractiveFixture(HeaderModel) = undefined;
    try setupInteractive(HeaderModel, &setup, .{
        .fps = 1000,
        .output = .{ .capacity = 64, .watermark = 16 },
    });
    defer setup.deinit();

    // The terminal stopped reading, so the queue fills and composition stops.
    _ = try setup.tty.stopReading();
    for (0..20) |_| {
        try setup.app.send(.tick);
        try setup.app.tick();
    }
    try testing.expect(!setup.app.out.?.canCompose());
    const queued = setup.app.out.?.pending();

    var ctx = setup.app.makeCtx();
    try setup.app.processCmd(.{ .mouse = true }, &ctx, setup.app.tty.?.writer());

    // The bytes were not staged, so the App must not claim the terminal has
    // mouse reporting on, and the frame is still owed that sequence.
    try testing.expect(!setup.app.modes.mouse);
    try testing.expect(setup.app.render_requested);
    try testing.expectEqual(queued, setup.app.out.?.pending());
}

// ── F3: the loop watchdog ────────────────────────────

test "app: a stalled loop trips the watchdog and stops the session" {
    var setup: InteractiveFixture(GoodModel) = undefined;
    try setupInteractive(GoodModel, &setup, .{ .fps = 1000 });
    defer setup.deinit();

    // The previous frame's heartbeat is ancient: `tick` observes it
    // BEFORE re-pinging, so the stall is caught rather than swallowed.
    setup.app.watchdog.budget_ns = 0;
    setup.app.watchdog.last_ping = .{ .nanoseconds = 0 };
    try testing.expectError(error.WatchdogTripped, setup.app.tick());
    try testing.expect(!setup.app.isRunning());
}

test "app: a healthy loop never trips the default watchdog budget" {
    var setup: InteractiveFixture(GoodModel) = undefined;
    try setupInteractive(GoodModel, &setup, .{ .fps = 1000 });
    defer setup.deinit();
    try setup.app.tick();
    try testing.expect(setup.app.watchdog.armed());
    try testing.expect(setup.app.watchdog.budget_ns == watchdog.default_budget_ns);
    try testing.expect(setup.app.isRunning());
}
