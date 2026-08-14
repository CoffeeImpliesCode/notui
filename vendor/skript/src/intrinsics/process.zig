//! Process intrinsics (Phase C): spawn / send / receive / self / alive? / sleep /
//! process-info / exit-reason / timeout-sentinel.
//!
//! Suspend/resume contract: the blocking intrinsics (receive, sleep) return
//! `error.WouldBlock` on first call — evalReg rewinds the ip to the call and
//! returns `.suspended`, and the runner leaves the process OFF the ready
//! queue. A send re-enqueues it (mailbox delivery, plus the scheduler wake
//! event) or the runner's idle path re-enqueues it when its deadline fires
//! (sleep). The re-dispatched call observes the in-flight state — the message
//! in the mailbox, or the cleared deadline — and completes normally.

const std = @import("std");

const skript = @import("../root.zig");
const Value = skript.Value;
const Error = skript.Error;
const Runtime = skript.Runtime;
const EvalContext = skript.EvalContext;
const Process = skript.scheduler.Process;

const intrin = @import("root.zig");
const ad_effects = @import("../ad_effects.zig");

/// (spawn CLOSURE) — run CLOSURE in a new process; returns the new process's
/// pid. The closure is invoked with zero arguments (a closure with params is
/// an arity error, mirroring the .call path).
pub fn spawn(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    try requireProcess(ctx, true, false);
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_closure);
    const proc = try rt.spawnClosure(args[0]);
    return Value.pid(.fromPtr(proc));
}

/// (send PID MSG) — deliver MSG to PID's mailbox; returns MSG (Erlang send
/// semantics). Wakes the receiver: a suspended process is off the ready
/// queue, so enqueue it and set the scheduler event to un-park the idle
/// runner. A running process needs no wake — its own receive finds the
/// message (self-send); a completed process is left alone (message dropped).
pub fn send(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    try requireProcess(ctx, true, false);
    try intrin.arityAssert(args, 2);
    try intrin.typeAssert(args[0], skript.builtins.type_pid);
    const proc = args[0].obj.toPtr(*Process);
    rt.scheduler.mutex.lockUncancelable(rt.io);
    defer rt.scheduler.mutex.unlock(rt.io);
    try proc.mailPushLocked(rt.static, args[1]);
    if (proc != skript.scheduler.current_process and !proc.queued and !proc.completed.load(.acquire)) {
        rt.scheduler.enqueueLocked(proc);
        std.Io.Event.set(&rt.scheduler.event, rt.io);
    }
    return args[1];
}

/// (receive) — block until a message arrives; returns the next message.
/// (receive PRED) — return the first message for which (PRED MSG) is truthy
/// (nil-only falsy, like branch conditions); non-matching messages stay in
/// the mailbox.
/// (receive PRED MS) — selective receive with a timeout: give up after MS
/// milliseconds and return the `timeout-sentinel` (a dedicated OPAQUE value,
/// see `timeoutSentinelValue`). The sentinel is distinct from every user
/// message: a user cannot mint opaque values, so it can never collide with a
/// real message of any spelling (the old `:timeout` keyword was
/// indistinguishable from a genuine `:timeout` message). Test with
/// `(= (receive (fn (m) #f) MS) (timeout-sentinel))`. The timeout is anchored
/// to the receive call, not to the predicate's execution time.
/// (receive MS) — timeout-only: pop the front message or time out.
/// First call with no matching message suspends (WouldBlock, arming the
/// timeout deadline when given); the re-dispatched call re-scans. A
/// predicate may synchronously receive, but cannot suspend: a blocking
/// nested receive or sleep returns Denied without taking the outer message.
pub fn receive(ctx: *EvalContext, ns: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    try requireProcess(ctx, true, true);
    if (ctx.effects.clock != .allow) return error.Denied;
    if (args.len > 2) return error.ArityMismatch;
    var pred: ?Value = null;
    var timeout_ns: ?i128 = null;
    if (args.len >= 1) {
        if (args[0].typ == skript.builtins.type_closure or
            args[0].typ == skript.builtins.type_intrinsic or
            args[0].typ == skript.builtins.type_method)
        {
            pred = args[0];
            if (args.len == 2) {
                try intrin.typeAssert(args[1], skript.builtins.type_i64);
                timeout_ns = @as(i128, @max(args[1].obj.toInt(i64), 0)) * std.time.ns_per_ms;
            }
        } else if (args[0].typ == skript.builtins.type_i64) {
            if (args.len == 2) return error.ArityMismatch;
            timeout_ns = @as(i128, @max(args[0].obj.toInt(i64), 0)) * std.time.ns_per_ms;
        } else return error.TypeMismatch;
    }
    if (ctx.execution != .trusted) {
        if (pred) |predicate| try ad_effects.preflight(rt, ns, predicate);
    }
    const proc = skript.scheduler.current_process orelse return error.Unimplemented;
    // On re-dispatch, check the receive's saved deadline before scanning.
    // A timeout wake must win over a late message or predicate result.
    if (proc.recv_deadline) |d| {
        const now_ns: i128 = @intCast(std.Io.Clock.awake.now(rt.io).nanoseconds);
        if (now_ns >= d) {
            proc.deadline = null;
            proc.recv_deadline = null;
            return timeoutSentinelValue();
        }
    }
    // Arm before scanning so a predicate's synchronous work counts toward
    // this receive's original timeout. A predicate cannot suspend.
    if (proc.recv_deadline == null) {
        if (timeout_ns) |t| {
            const now_ns: i128 = @intCast(std.Io.Clock.awake.now(rt.io).nanoseconds);
            proc.recv_deadline = now_ns + t;
            proc.deadline = proc.recv_deadline;
        }
    }
    // Scan: a delivered message beats a not-yet-elapsed timeout.
    if (try proc.mailMatch(rt, ns, pred)) |m| {
        proc.deadline = null; // drop any armed receive-timeout
        proc.recv_deadline = null;
        return m;
    }
    if (proc.recv_deadline != null) {
        // Early send wake, no match yet: keep the original deadline and
        // re-suspend (a non-matching message does not restart the timer).
        return error.WouldBlock;
    }
    return error.WouldBlock;
}

/// (@pid.eq A B) — pid identity.
pub fn pidEq(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    try intrin.typeAssert(args[0], skript.builtins.type_pid);
    try intrin.typeAssert(args[1], skript.builtins.type_pid);
    return Value.bool(args[0].obj == args[1].obj);
}

/// (@pid.ne A B) — pid inequality.
pub fn pidNe(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    try intrin.typeAssert(args[0], skript.builtins.type_pid);
    try intrin.typeAssert(args[1], skript.builtins.type_pid);
    return Value.bool(args[0].obj != args[1].obj);
}

/// (self) — the calling process's pid.
pub fn self(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try requireProcess(ctx, false, false);
    try intrin.arityAssert(args, 0);
    const proc = skript.scheduler.current_process orelse return error.Unimplemented;
    return Value.pid(.fromPtr(proc));
}

/// (alive? PID) — #t while the process has not completed.
pub fn @"alive?"(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try requireProcess(ctx, false, false);
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_pid);
    const proc = args[0].obj.toPtr(*Process);
    return Value.bool(!proc.completed.load(.acquire));
}

/// (sleep MS) — suspend the calling process for MS milliseconds (resumed by
/// the scheduler's deadline scan). First call sets the absolute `.awake`
/// clock deadline and suspends (WouldBlock); the re-dispatched call returns
/// nil only once the deadline has passed. A send that wakes the process
/// early does NOT interrupt the sleep (unlike a receive) — the process
/// re-suspends with its deadline intact, mirroring the receive-timeout
/// resume path. Negative MS is clamped to 0.
pub fn sleep(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    try requireProcess(ctx, true, true);
    if (ctx.effects.clock != .allow) return error.Denied;
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_i64);
    const proc = skript.scheduler.current_process orelse return error.Unimplemented;
    if (proc.deadline) |d| {
        // Resume path: woken by a send or the deadline. Only a deadline
        // firing completes the sleep; an early send re-suspends with the
        // deadline intact.
        const now_ns: i128 = @intCast(std.Io.Clock.awake.now(rt.io).nanoseconds);
        if (now_ns >= d) {
            proc.deadline = null;
            return .nil;
        }
        return error.WouldBlock;
    }
    const ms = @max(args[0].obj.toInt(i64), 0);
    const now_ns: i128 = @intCast(std.Io.Clock.awake.now(rt.io).nanoseconds);
    proc.deadline = now_ns + @as(i128, ms) * 1_000_000;
    return error.WouldBlock;
}

/// A unique marker whose ADDRESS is the receive-timeout sentinel's opaque
/// payload. A module-level constant gives it a stable identity for the whole
/// process image, so every `(timeout-sentinel)` call and every receive-timeout
/// returns the SAME opaque value. `=`/`equal?` compare opaque by object
/// identity (the prelude registers `(instance = Opaque Opaque @equal?)`), and
/// opaque values are not constructible in the language, so the sentinel can
/// never be produced by a user or collide with ANY message of any spelling.
const timeout_marker: u8 = 0;

/// The receive-timeout sentinel: a dedicated OPAQUE value returned by
/// `receive` on timeout and by the `(timeout-sentinel)` intrinsic. Distinct
/// from every user message — it replaced the old `:timeout` keyword, which a
/// receiver could not distinguish from a real `:timeout` message. Public so
/// host tests can assert on the returned value.
pub fn timeoutSentinelValue() Value {
    return Value.opaq(.fromPtr(&timeout_marker));
}

/// (timeout-sentinel) — the opaque value `receive` returns when it gives up
/// on a timeout. Stable singleton per process image: every call returns the
/// identical object, so `(= (timeout-sentinel) v)` tests whether `v` is the
/// timeout sentinel.
pub fn timeoutSentinel(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 0);
    return timeoutSentinelValue();
}

/// (exit-reason PID) — nil while PID is alive or after a clean exit. After
/// an uncaught `(raise X)`, return the raw payload X. For a system crash,
/// return the process's rich @Error result, including its source context.
pub fn exitReason(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try requireProcess(ctx, false, false);
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_pid);
    const proc = args[0].obj.toPtr(*Process);
    // Gate on the atomic completed flag (acquire): `raised`/`result` are
    // written by the runner BEFORE its release-store, so reading them after
    // an observing acquire-load is well-defined.
    if (!proc.completed.load(.acquire)) return .nil;
    if (proc.result.typ != skript.builtins.type_error) return .nil;
    return if (proc.result.errorCode() == error.Raised) proc.raised else proc.result;
}

/// A cons cell `(car . cdr)`, arena-allocated (rt.static via store.create).
fn cell(rt: *Runtime, car: Value, cdr: Value) Error!Value {
    const ref = try rt.store.create([2]Value);
    ref.deref([2]Value).* = .{ car, cdr };
    return Value.cons(ref.toObject());
}

/// (process-info PID) — a snapshot of PID's lifecycle state as a proper cons
/// list of `(:key . value)` pairs:
///   (:alive BOOL)    — #t while the process has not completed
///   (:status KW)     — :running | :queued | :suspended | :done | :crashed
///   (:raised PAYLOAD) — raw uncaught (raise X) payload; nil otherwise
///   (:error @Error)  — uncaught system error value; nil otherwise
/// Takes the scheduler mutex so the snapshot's queued/completed/running
/// fields are read atomically (mirrors Scheduler.snapshotProcesses).
pub fn processInfo(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    try requireProcess(ctx, false, false);
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_pid);
    const proc = args[0].obj.toPtr(*Process);
    rt.scheduler.mutex.lockUncancelable(rt.io);
    defer rt.scheduler.mutex.unlock(rt.io);
    const running = skript.scheduler.current_process orelse rt.scheduler.running_process;
    const completed = proc.completed.load(.acquire);
    const status: []const u8 = if (running != null and proc == running.?)
        "running"
    else if (completed)
        (if (proc.result.typ == skript.builtins.type_error) "crashed" else "done")
    else if (proc.queued)
        "queued"
    else
        "suspended";
    // `raised` and `result` are published before the completed release-store.
    const raised = if (completed) proc.raised else Value.nil;
    const system_error = if (completed and proc.result.typ == skript.builtins.type_error and
        proc.result.errorCode() != error.Raised)
        proc.result
    else
        Value.nil;
    const alive_pair = try cell(rt, .keyword(try rt.store.getsym("alive")), .bool(!completed));
    const status_pair = try cell(
        rt,
        .keyword(try rt.store.getsym("status")),
        Value.keyword(try rt.store.getsym(status)),
    );
    const raised_pair = try cell(rt, .keyword(try rt.store.getsym("raised")), raised);
    const error_pair = try cell(rt, .keyword(try rt.store.getsym("error")), system_error);
    return cell(
        rt,
        alive_pair,
        try cell(rt, status_pair, try cell(rt, raised_pair, try cell(rt, error_pair, .nil))),
    );
}

fn requireProcess(ctx: *EvalContext, writes: bool, suspends: bool) Error!void {
    try ctx.check();
    if (ctx.mode != .concrete or ctx.execution == .pure_limited or ctx.effects.process != .allow) return error.Denied;
    if (writes and ctx.effects.state_write != .allow) return error.Denied;
    if (!writes and ctx.effects.state_read != .allow) return error.Denied;
    if (suspends and (!ctx.allow_suspend or ctx.native_reentry)) return error.Denied;
}

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
    }
}
