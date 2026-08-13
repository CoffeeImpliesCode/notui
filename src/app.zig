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
const Reader = @import("input.zig").Reader;
const caps = @import("caps.zig");
const emit = @import("emit.zig");
const Event = @import("event.zig").Event;
const Key = @import("Key.zig");
const Buffer = @import("buffer.zig").Buffer;
const Parser = @import("Parser.zig");
const builtin = @import("builtin");
const view_mod = @import("view.zig");

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
///   pub fn init(allocator: std.mem.Allocator) !Model;         // initial state
///   pub fn update(self: *Model, msg: Msg, ctx: *Context) !Cmd(Msg);
///   pub fn view(self: *const Model, ctx: *Context) View;
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

        // loop state
        running: bool = false,
        /// Terminal modes currently active (alt_screen tracked but never
        /// emitted in v1, orchestrator Q1).
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

        // ── construction ──
        pub fn init(model: Model) Self {
            return initWithOptions(model, .{});
        }
        pub fn initWithOptions(model: Model, opts: Options) Self {
            return .{ .model = model, .opts = opts, .filter = opts.filter };
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
                const timeout: i32 = if (self.opts.fps > 0)
                    @intCast(1000 / self.opts.fps)
                else
                    -1;
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
            //    other events go through the filter to a Msg (null = the
            //    event is dropped — the framework never synthesizes one).
            var dispatched = ev != null;
            if (ev) |e| switch (e) {
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

            // 8. Frame-level modes: dynamic band height (inline only) and
            //    the terminal title (on content change, every tick).
            if (vw.height != 0 and vw.height != self.region.?.height) {
                try self.region.?.setHeight(vw.height);
            }
            if (vw.title) |vt| {
                if (self.title == null or !std.mem.eql(u8, vt, self.title.?)) {
                    if (w) |ww| try self.writeTitle(vt, ww);
                    self.title = vt;
                }
            }

            // 9. Render decision (render-on-demand + whole-View hash
            //    skip): an event/msg was dispatched, the frame asked for a
            //    repaint, the declaration changed, a mode transition is
            //    pending, print_above is set, or the region has pending
            //    work (first frame / resize / height change / appends).
            //    Else: idle — skip draw+render (the Region would emit
            //    zero bytes anyway; this avoids the draw call). The
            //    degraded (non-TTY) path never renders from tick.
            const sig = view_mod.signature(vw);
            const mode_pending = vw.alt_screen != self.modes.alt_screen or
                vw.mouse != self.modes.mouse or
                vw.hide_cursor != self.modes.hide_cursor;
            const region_pending = self.regionPending();
            if (self.tty != null and
                (dispatched or self.render_requested or sig != self.last_sig or
                    mode_pending or vw.print_above or region_pending))
            {
                _ = try view_mod.applyModeDiff(vw, w.?, &self.modes);
                try vw.draw(&self.model, &ctx, &self.region.?.cur);
                try self.region.?.render(w.?);
                self.last_sig = sig;
            }
            if (w) |ww| try ww.flush();
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
        /// `w` (§5.5): fresh scratch, view, band height, title, draw, then
        /// the region's plain-frame render. The app's `view` runs so a
        /// non-TTY user sees the same content.
        fn renderPlainFrame(self: *Self, w: anytype) !void {
            if (self.scratch) |*s| _ = s.reset(.retain_capacity);
            var ctx = self.makeCtx();
            const vw = Model.view(&self.model, &ctx);
            if (vw.height != 0 and vw.height != self.region.?.height) {
                try self.region.?.setHeight(vw.height);
            }
            if (vw.title) |vt| try self.writeTitle(vt, w);
            try vw.draw(&self.model, &ctx, &self.region.?.cur);
            try self.region.?.render(w);
            try w.flush();
        }

        /// Tear down arena/scratch/region/tty. Idempotent; called by run.
        pub fn deinit(self: *Self) void {
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
                    if (w) |ww| try self.writeTitle(t, ww);
                    self.title = t;
                },
                .mouse => |on| {
                    // Immediate mode op; the next frame's View.mouse wins.
                    if (w) |ww| {
                        if (on) {
                            try ww.writeAll("\x1b[?1006h\x1b[?1000h");
                        } else {
                            try ww.writeAll("\x1b[?1006l\x1b[?1000l");
                        }
                    }
                    self.modes.mouse = on;
                },
                .cursor => |show| {
                    if (w) |ww| {
                        if (show) try emit.showCursor(ww) else try emit.hideCursor(ww);
                    }
                    self.modes.hide_cursor = show;
                },
                .alt_screen => |alt| {
                    // Parsed-but-noop in v1 (Q1): tracked for the
                    // signature/mode gating; the full-screen renderer is
                    // the deferred architecture §7 item.
                    self.modes.alt_screen = alt;
                },
            }
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
                .sync_output = true,
                .width_policy = self.caps.?.widthPolicy(),
            });
            errdefer {
                self.region.?.deinit();
                self.region = null;
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
                .sync_output = false,
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

        /// Emit the exit sequences in order: Region.exit then caps.restore
        /// (contract §5.4; the alt-screen exit is skipped — alt is a no-op
        /// in v1, Q1). `run` calls this before `deinit`.
        fn emitTeardown(self: *Self, w: anytype) !void {
            if (self.region) |*r| try r.exit(w);
            if (self.caps) |*c| try c.restore(w);
            try w.flush();
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
        /// resize/height change, or queued appends) — forces a render.
        fn regionPending(self: *Self) bool {
            const r = &self.region.?;
            return r.first_frame or r.width_dirty or r.height_dirty or
                r.append_queue.items.len > 0;
        }

        /// Enqueue `Msg.tick` (the single periodic message name; models
        /// map it to their own timer message in update, §6).
        fn enqueueTick(self: *Self) !void {
            try self.msg_queue.append(self.gpa, @as(Msg, .tick));
        }

        /// Write an OSC 0 title change (`\x1b]0;{s}\x07`).
        fn writeTitle(self: *Self, title: []const u8, w: anytype) !void {
            _ = self;
            try w.writeAll("\x1b]0;");
            try w.writeAll(title);
            try w.writeAll("\x07");
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

    fn init(_: std.mem.Allocator) !TestModel {
        return .{};
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

    fn init(_: std.mem.Allocator) !RecModel {
        return .{};
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

/// A model whose view declares the alt-screen target (a no-op in v1).
const AltModel = struct {
    pub const Msg = union(enum) { tick };
    alt: bool = false,

    fn init(_: std.mem.Allocator) !AltModel {
        return .{};
    }
    fn update(_: *AltModel, _: Msg, _: *Context) !Cmd(Msg) {
        return .none;
    }
    fn view(self: *const AltModel, _: *Context) View(AltModel) {
        return .{ .draw = &draw, .alt_screen = self.alt };
    }
    fn draw(_: *AltModel, _: *Context, buf: *Buffer) anyerror!void {
        _ = try buf.draw(.{}, "alt", 0, 0);
    }
};

/// A model for the Ctrl+C filter test.
const CtrlModel = struct {
    pub const Msg = union(enum) { tick, quit };

    fn init(_: std.mem.Allocator) !CtrlModel {
        return .{};
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
    b: posix.fd_t, // the test end

    fn init() !FakeTty {
        var fds: [2]posix.fd_t = undefined;
        if (builtin.link_libc) {
            const rc = std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
            if (rc != 0) return error.SystemResources;
        } else {
            const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
            if (posix.errno(rc) != .SUCCESS) return error.SystemResources;
        }
        return .{ .a = fds[0], .b = fds[1] };
    }

    /// Close only the test end: end `a` is closed by App.deinit →
    /// Tty.deinit.
    fn deinit(self: *FakeTty) void {
        const f: std.Io.File = .{ .handle = self.b, .flags = .{ .nonblocking = false } };
        f.close(testing.io);
        self.* = undefined;
    }

    fn tty(self: *const FakeTty) Tty {
        return .{
            .io = testing.io,
            .fd = .{ .handle = self.a, .flags = .{ .nonblocking = false } },
        };
    }

    /// Write input the fake tty will read.
    fn writeInput(self: *FakeTty, bytes: []const u8) !void {
        const f: std.Io.File = .{ .handle = self.b, .flags = .{ .nonblocking = false } };
        try f.writeStreamingAll(testing.io, bytes);
    }

    /// Read whatever output the app flushed into the socket (poll 0, then
    /// a blocking read — the data is present after a flush).
    fn drainOutput(self: *FakeTty, buf: []u8) usize {
        var pollfds = [_]posix.pollfd{.{
            .fd = self.b,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const n = posix.poll(&pollfds, 0) catch return 0;
        if (n == 0 or (pollfds[0].revents & posix.POLL.IN) == 0) return 0;
        const f: std.Io.File = .{ .handle = self.b, .flags = .{ .nonblocking = false } };
        return f.readStreaming(testing.io, &.{buf}) catch 0;
    }
};

/// Wire an app's runtime state against a fake tty, as `start` would for a
/// real terminal (contract §5.1), minus the live caps queries (the fake
/// never replies; detection would burn 5×250 ms per test).
fn setupInteractive(comptime M: type, opts: App(M).Options) !struct { app: App(M), tty: FakeTty } {
    var fake = try FakeTty.init();
    errdefer fake.deinit();
    var app = App(M).initWithOptions(try M.init(testing.allocator), opts);
    app.io = testing.io;
    app.gpa = testing.allocator;
    app.tty = fake.tty();
    app.caps = .{};
    app.region = try Region.init(testing.allocator, .{
        .height = opts.region_height,
        .append_lines = opts.append_lines,
        .sync_output = true,
    });
    errdefer app.region.?.deinit();
    try app.region.?.resize(80, opts.region_height);
    app.arena = std.heap.ArenaAllocator.init(testing.allocator);
    app.scratch = std.heap.ArenaAllocator.init(testing.allocator);
    app.reader = Reader.init(&app.tty.?);
    app.last_tick = std.Io.Timestamp.now(testing.io, .awake);
    app.running = true;
    return .{ .app = app, .tty = fake };
}

/// A valid model (passes the contract check).
const GoodModel = struct {
    pub const Msg = union(enum) { tick };
    fn init(_: std.mem.Allocator) !GoodModel {
        return .{};
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
    var app = App(M).init(try M.init(testing.allocator));
    app.io = testing.io;
    app.gpa = testing.allocator;
    app.region = try Region.init(testing.allocator, .{ .height = 2, .sync_output = false });
    app.arena = std.heap.ArenaAllocator.init(testing.allocator);
    app.scratch = std.heap.ArenaAllocator.init(testing.allocator);
    return app;
}

test "app: Model contract check accepts a valid model and rejects missing members" {
    // The App comptime block turns violations into @compileError; the
    // helper is tested directly (a @compileError cannot be caught).
    try testing.expectEqual(@as(usize, 0), comptime modelViolations(GoodModel).len);
    try testing.expectEqual(@as(usize, 3), comptime modelViolations(BadModel).len);

    // A valid model instantiates cleanly.
    const ok = App(GoodModel).init(try GoodModel.init(testing.allocator));
    try testing.expect(!ok.isRunning());
}

test "app: degraded path renders one plain frame, no raw mode" {
    var app = App(TestModel).init(try TestModel.init(testing.allocator));
    app.io = testing.io; // `start` sets this before routing to startPlain
    try app.startPlain(testing.allocator);
    defer app.deinit();

    try testing.expect(app.tty == null); // no raw mode, no /dev/tty
    try testing.expect(app.caps == null);
    try testing.expect(app.reader == null);
    try testing.expect(!app.region.?.opts.sync_output);
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
    try testing.expect(std.mem.indexOf(u8, tw.w.buffered(), "\x1b[?25l") == null); // no interactive sequences
}

test "app: run in degraded mode stops after one plain frame" {
    var app = App(TestModel).init(try TestModel.init(testing.allocator));
    app.io = testing.io;
    try app.startPlain(testing.allocator);
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
    var fresh = App(TestModel).init(try TestModel.init(testing.allocator));
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

test "app: alt_screen is parsed but a no-op — no smcup/rmcup (Q1)" {
    var setup = try setupInteractive(AltModel, .{ .fps = 1000 });
    defer setup.app.deinit();
    defer setup.tty.deinit();
    setup.app.model.alt = true;

    try setup.app.tick(); // alt declared: renders normally, no smcup
    var out: [4096]u8 = undefined;
    const n = setup.tty.drainOutput(&out);
    try testing.expect(n > 0); // the frame WAS rendered
    try testing.expect(std.mem.indexOf(u8, out[0..n], "\x1b[?1049h") == null);
    try testing.expect(std.mem.indexOf(u8, out[0..n], "\x1b[?1049l") == null);
    try testing.expect(setup.app.modes.alt_screen);

    setup.app.model.alt = false;
    try setup.app.tick(); // flipping back: still no rmcup
    const n2 = setup.tty.drainOutput(&out);
    try testing.expect(std.mem.indexOf(u8, out[0..n2], "\x1b[?1049h") == null);
    try testing.expect(std.mem.indexOf(u8, out[0..n2], "\x1b[?1049l") == null);
    try testing.expect(!setup.app.modes.alt_screen);
}

/// A model whose drawn text is allocated from the app-lifetime
/// `frame_arena` (the frame Buffer borrows the slice, cell.zig) and
/// changes every tick — the soundness regression: with a per-tick-reset
/// frame arena, `prev` cells alias reused memory, `Cell.eql` sees stale
/// content, and changed frames never repaint.
const ArenaDrawModel = struct {
    pub const Msg = union(enum) { tick };
    frame: usize = 0,

    fn init(_: std.mem.Allocator) !ArenaDrawModel {
        return .{};
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
    // Region.exit emits only for interactive regions (sync_output).
    app.region.?.deinit();
    app.region = try Region.init(testing.allocator, .{ .height = 2, .sync_output = true });
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

test "cmd: alt_screen mode op is tracked, not emitted (Q1)" {
    var app = try cmdApp(RecModel);
    defer app.deinit();
    var ctx = app.makeCtx();
    var tw: TestWriter = .{};
    tw.init();

    try app.processCmd(.{ .alt_screen = true }, &ctx, &tw.w);
    try testing.expectEqualStrings("", tw.w.buffered());
    try testing.expect(app.modes.alt_screen);

    try app.processCmd(.{ .alt_screen = false }, &ctx, &tw.w);
    try testing.expectEqualStrings("", tw.w.buffered());
    try testing.expect(!app.modes.alt_screen);
}
