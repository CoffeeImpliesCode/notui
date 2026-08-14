//! Phase B of the skript process scheduler: a cooperative single-runner
//! scheduler for register-VM fibers, plus the host API surface
//! (Runtime.spawnEval / awaitProcess / pollProcess).
//!
//! Invariants (v1):
//! - ONE runner at a time, the runtime's permanent servant (it parks when
//!   the queue is quiet and is woken by spawnEval/send; it exits only at
//!   shutdown or when its target crashes).
//! - The host's awaitProcess observes completions by polling the FutureObj,
//!   so the host is NOT parked while the runner executes. The scheduler's
//!   mutable state (ready queue, process registry, mailboxes) is guarded by
//!   Scheduler.mutex — every accessor is the *Locked variant and callers
//!   hold the mutex. Cross-thread completion signaling goes through the
//!   atomics on Process/FutureObj.
//! - The static arena is touched by the runner (fiber growth, mailbox
//!   nodes, let namespaces) and by the host only outside the runner's
//!   critical sections; the mutex serializes the shared structures.

const std = @import("std");
const skript = @import("root.zig");
const modules = @import("modules.zig");

/// The process currently executing on THIS thread — the runner sets it
/// around evalReg, so the blocking intrinsics (receive/self/sleep) read it.
/// Thread-local: the host thread's copy is always null, so the host's send
/// guard never mistakes a stale runner value for a self-send (the runner may
/// outlive the host's awaitProcess poll loop).
pub threadlocal var current_process: ?*Process = null;

/// Instructions per process run before the scheduler re-dispatches: an
/// evalReg `.yielded` re-enqueues the process at the back of the FIFO.
pub const quantum: u32 = 10_000;

/// A skript process: a resumable regvm fiber plus process identity.
pub const Process = struct {
    pid: u32,
    /// Register-mode fiber. NOTE: fib.stack is a growable slice owned by the
    /// runtime arena; evalReg grows it (via rt.static.realloc) on the runner
    /// thread while the host is parked in await.
    fib: skript.Runtime.Fiber,
    eval_context: ?skript.EvalContext = null,
    lease: ?skript.EvalContext.Budget.Lease = null,
    scratch_account: ?skript.EvalContext.Budget.AccountAllocator = null,
    /// Set to true (release) by the runner once `result` is valid.
    completed: std.atomic.Value(bool) = .init(false),
    /// The process's final value; valid when `completed` is true (synchronized
    /// through the release/acquire pair on `completed`).
    result: skript.Value = .nil,
    /// The raw payload of an uncaught `(raise X)`, copied from fib.raised
    /// only for error.Raised (nil for system errors or normal completion).
    raised: skript.Value = .nil,
    /// Host-published FutureObj; the runner reads it to publish completion.
    future_obj: std.atomic.Value(?*FutureObj) = .init(null),
    /// The Io future of this process's runner; it resolves only when the
    /// RUNNER exits (shutdown or this process crashing as its target) — not
    /// when the process completes (the runner is a permanent servant). The
    /// deinit drain consumes it; nothing awaits it in v1. Null for processes
    /// spawned INSIDE another process (spawnClosure from the spawn
    /// intrinsic): no per-process runner, completion observed via the
    /// FutureObj (poll).
    io_future: ?std.Io.Future(skript.Error!skript.Value) = null,
    /// FIFO message queue (Phase C). Singly-linked arena nodes: immutable
    /// after push, so the receive scan reads them lock-free while senders
    /// append under the scheduler mutex. The receiving process is the only
    /// unlinker, so no concurrent removal can race the scan.
    /// FIFO message queue (Phase C). Singly-linked arena nodes: immutable
    /// after push, so the receive scan reads them lock-free while senders
    /// append under the scheduler mutex. The head and the per-node next are
    /// atomics: the scan (lock-free) and the locked push/unlink run on
    /// different threads. The receiving process is the only unlinker, so no
    /// concurrent removal can race the scan.
    mailbox_head: std.atomic.Value(?*MailNode) = .init(null),
    mailbox_tail: ?*MailNode = null,
    /// True while this process is on the scheduler's ready queue.
    queued: bool = false,
    /// True while the process is suspended off-queue waiting for a wake
    /// source (a send or its deadline).
    suspended: bool = false,
    /// Absolute wake deadline in nanoseconds on the `.awake` clock
    /// (CLOCK_MONOTONIC on Linux); null when no sleep is pending. The idle
    /// path parks on `event` until `earliestDeadline`, then `wakeDue`
    /// re-enqueues the process; the resumed process's blocking intrinsic
    /// (sleep / receive-timeout resume path) clears it.
    deadline: ?i128 = null,
    /// The receive's saved timeout, checked before a resumed call scans the
    /// mailbox. It stays fixed across wakes from non-matching sends.
    recv_deadline: ?i128 = null,
    /// The canonical path of the module this process is running as, or null
    /// for an anonymous eval. Arena-owned — the loader (the module system)
    /// sets it; the load intrinsic resolves relative load paths against its
    /// dirname.
    module_path: ?[]const u8 = null,
    /// Module declarations are validated and mapped to live source cells
    /// after evaluation, before the public view is published.
    exported: std.ArrayList(modules.ExportSpec) = .empty,
    /// Module processes this process is suspended on. One use group can wait
    /// for several modules at once. The scheduler lock protects this graph.
    waiting_on: std.ArrayList(*Process) = .empty,
    /// Scratch fields for allocation-free, bounded wait-graph searches under
    /// the scheduler lock.
    wait_search_epoch: u64 = 0,
    wait_search_next: ?*Process = null,

    /// Processes suspended while waiting on THIS process. The scheduler
    /// removes each waiter when it wakes or cancels its wait group.
    waiters: std.ArrayList(*Process) = .empty,

    /// Append `msg` at the back of the mailbox. Caller holds the scheduler
    /// mutex.
    pub fn mailPushLocked(self: *Process, alloc: std.mem.Allocator, msg: skript.Value) !void {
        const node = try alloc.create(MailNode);
        node.* = .{ .msg = msg, .next = .init(null) };
        if (self.mailbox_tail) |t| {
            t.next.store(node, .release);
        } else {
            self.mailbox_head.store(node, .release);
        }
        self.mailbox_tail = node;
    }

    /// Number of unread messages. Caller holds the scheduler mutex.
    pub fn mailLenLocked(self: *Process) usize {
        var n: usize = 0;
        var cur = self.mailbox_head.load(.acquire);
        while (cur) |c| : (cur = c.next.load(.acquire)) n += 1;
        return n;
    }

    /// Scan the mailbox from the head for the first message matching `pred`
    /// (or the front message when pred is null), unlink it, and return it.
    /// Non-matching messages stay in the mailbox. The scan reads the
    /// immutable nodes lock-free (only this receiver unlinks); the unlink
    /// takes the scheduler mutex (senders append under it). The pred runs
    /// with apply — a truthy result means a match (nil-or-#f falsy, like
    /// branch conditions).
    ///
    /// A predicate may synchronously receive a message, but it cannot
    /// suspend. A successful nested receive may unlink a node this scan
    /// passed. Before unlinking under the mutex, re-walk the chain to find
    /// cur's CURRENT predecessor and confirm that cur is still linked. If
    /// the nested receive consumed cur, restart from the head.
    pub fn mailMatch(
        self: *Process,
        rt: *skript.Runtime,
        ns: skript.Value,
        pred: ?skript.Value,
    ) skript.Error!?skript.Value {
        const ctx = rt.context();
        var prev: ?*MailNode = null;
        var cur = self.mailbox_head.load(.acquire);
        while (cur) |c| {
            try ctx.charge(.{ .work = 1 }, .scheduler);
            const msg = c.msg;
            if (pred) |p| {
                const ok = try ctx.apply(ns, p, &.{msg});
                // An error VALUE is not a truthy match. Keep its raw raised
                // payload and rich context on the VM fiber that called receive.
                if (ok.typ == skript.builtins.type_error) {
                    const fiber = rt.activeFiber() orelse &self.fib;
                    fiber.raised = ok.errorRaised();
                    fiber.pending_error = ok;
                    return ok.errorCode();
                }
                if (!skript.Value.isTruthy(ok)) {
                    prev = c;
                    cur = c.next.load(.acquire);
                    continue;
                }
            }
            // Match: unlink under the mutex (the chain may have grown since
            // the scan started). RE-VALIDATE first: a nested receive inside
            // the pred may have consumed or reordered the chain, so the
            // scan's prev/cur are no longer trustworthy. Walk from the head
            // to locate cur's CURRENT predecessor.
            rt.scheduler.mutex.lockUncancelable(rt.io);
            defer rt.scheduler.mutex.unlock(rt.io);
            var new_prev: ?*MailNode = null;
            var node = self.mailbox_head.load(.acquire);
            while (node) |n| {
                try ctx.charge(.{ .work = 1 }, .scheduler);
                if (n == c) break;
                new_prev = n;
                node = n.next.load(.acquire);
            }
            if (node == null) {
                // A nested receive consumed cur itself: do NOT return it.
                // Restart the scan from the head — the pred re-evaluates on
                // the remaining messages.
                prev = null;
                cur = self.mailbox_head.load(.acquire);
                continue;
            }
            // cur is still reachable: unlink it using its current
            // predecessor (which may differ from the scan's stale prev).
            if (new_prev) |p| {
                p.next.store(c.next.load(.acquire), .release);
            } else {
                self.mailbox_head.store(c.next.load(.acquire), .release);
            }
            if (self.mailbox_tail == c) self.mailbox_tail = new_prev;
            return msg;
        }
        return null;
    }
};
fn hasWaitEdge(waiter: *const Process, target: *const Process) bool {
    for (waiter.waiting_on.items) |edge| if (edge == target) return true;
    return false;
}

fn containsProcess(processes: []const *Process, target: *const Process) bool {
    for (processes) |process| if (process == target) return true;
    return false;
}

fn removeWaiter(target: *Process, waiter: *Process) void {
    var index = target.waiters.items.len;
    while (index > 0) {
        index -= 1;
        if (target.waiters.items[index] == waiter) {
            _ = target.waiters.swapRemove(index);
            return;
        }
    }
}

/// A mailbox node: the message is immutable after push; the next pointer is
/// an atomic so the lock-free receive scan and the locked push/unlink (which
/// run on different threads) are data-race-free.
const MailNode = struct {
    msg: skript.Value,
    next: std.atomic.Value(?*MailNode),
};

/// The host-visible future: a STORE object (GC heap) so pids/futures can be
/// skript values later. awaitProcess polls `done` (it never touches the
/// fields below); deinit's runner drain is what actually awaits the Io
/// future.
pub const FutureObj = struct {
    done: std.atomic.Value(bool) = .init(false),
    /// Written BEFORE `done.store(true, .release)`.
    result: skript.Value = .nil,
    /// The Io future of this process's runner (same value as the Process
    /// slot); only the deinit drain awaits it — host polls never do.
    /// Null for processes spawned from inside another process (v1
    /// single-runner — no per-process runner, completion observed through
    /// the done flag).
    io_future: ?*std.Io.Future(skript.Error!skript.Value) = null,
};

/// Host snapshot of one registered process (REPL fibers panel). Filled by
/// Scheduler.snapshotProcesses under the scheduler mutex.
pub const ProcessInfo = struct {
    pid: u32,
    status: Status,
    /// Absolute wake deadline in `.awake` clock nanoseconds; null when
    /// no sleep is pending. (The host renders it as relative ms.)
    deadline: ?i128,
    /// Number of unread messages in the mailbox.
    mailbox: usize,
    /// The canonical path of the module this process runs as, or null
    /// for an anonymous eval. Arena-owned; valid for the runtime
    /// lifetime.
    module_path: ?[]const u8,

    pub const Status = enum { running, queued, suspended, done, crashed };
};

/// Cooperative scheduler for the regvm runner: ready FIFO plus the Phase C
/// process registry, wake event, and deadline scans.
pub const Scheduler = struct {
    alloc: std.mem.Allocator,
    /// Guards the ready queue, the process registry, the mailbox nodes, and
    /// the runner registry. Every *Locked accessor requires the caller to
    /// hold it. The runner's evalReg runs WITHOUT the lock (the intrinsics
    /// acquire it briefly for mailbox/deadline ops); no code holds it across
    /// an evalReg or an Io park.
    mutex: std.Io.Mutex = .init,
    /// Ready queue: append back, pop front.
    ready: std.ArrayList(*Process),
    /// Process id counter. ATOMIC: the host's spawnEval and the runner's
    /// spawnClosure (the spawn intrinsic) increment it from different
    /// threads (the runner is a permanent servant); a plain RMW could mint
    /// duplicate pids.
    next_pid: std.atomic.Value(u32) = .init(1),
    /// Registry of ALL live processes (appended at spawn, never removed in
    /// v1 — arena lifetime). Scanned by `wakeDue`/`earliestDeadline`.
    processes: std.ArrayList(*Process) = .empty,
    /// Generation used by allocation-free wait-graph traversals.
    wait_search_epoch: u64 = 0,
    /// Wake primitive for the runner's idle park. The host sets it to wake
    /// the runner (v1: a host-side send); the idle path arms it with the
    /// earliest deadline so timer firings re-drain without a host
    /// round-trip.
    event: std.Io.Event = .unset,
    /// Set by Runtime.deinit BEFORE any memory is freed: parked runners wake,
    /// see this at their next loop top, and exit; deinit awaits each runner
    /// future so no worker touches freed runtime memory.
    shutdown: std.atomic.Value(bool) = .init(false),
    /// True while a runner task is live. The host dispatches a runner only
    /// when this is false (v1: ONE runner at a time); the runner clears it
    /// (release) on every exit path BEFORE returning, and the host's dispatch
    /// stores true (release) before io.concurrent, so a runner that exits
    /// before the dispatch returns still publishes its clear afterwards.
    runner_active: std.atomic.Value(bool) = .init(false),
    /// The process the runner is currently executing, published for the
    /// host (the REPL's fibers panel). The runner writes it under the
    /// mutex right after a pop and clears it at the end of the switch (and
    /// on every runner exit path); it is null while the runner is parked
    /// or between dispatches. The host reads it under the mutex — never
    /// without (snapshotProcesses does it for you).
    running_process: ?*Process = null,
    /// Every dispatched runner future, so deinit can drain them.
    runners: std.ArrayList(std.Io.Future(skript.Error!skript.Value)) = .empty,

    pub fn init(alloc: std.mem.Allocator) Scheduler {
        return .{
            .alloc = alloc,
            .ready = .empty,
            .processes = .empty,
            .event = .unset,
            .runners = .empty,
            .mutex = .init,
            .next_pid = .init(1),
        };
    }

    pub fn deinit(self: *Scheduler) void {
        self.ready.deinit(self.alloc);
        self.processes.deinit(self.alloc);
        self.runners.deinit(self.alloc);
        self.* = undefined;
    }

    /// Append a registered process using capacity reserved by registerLocked.
    /// Caller holds the mutex. A process has at most one ready-queue entry.
    pub fn enqueueLocked(self: *Scheduler, p: *Process) void {
        if (p.queued) return;
        std.debug.assert(self.ready.capacity >= self.processes.items.len);
        std.debug.assert(self.ready.items.len < self.processes.items.len);
        self.ready.appendAssumeCapacity(p);
        p.queued = true;
    }

    /// FIFO front pop; null when the queue is empty. Caller holds the mutex.
    pub fn popLocked(self: *Scheduler) ?*Process {
        if (self.ready.items.len == 0) return null;
        const p = self.ready.orderedRemove(0);
        p.queued = false;
        p.suspended = false;
        return p;
    }

    /// Register a process at spawn. Caller holds the mutex. Pass the same
    /// allocator that `deinit` frees with (the scheduler's gpa).
    pub fn registerLocked(self: *Scheduler, alloc: std.mem.Allocator, proc: *Process) !void {
        try self.ready.ensureTotalCapacity(self.alloc, self.processes.items.len + 1);
        try self.processes.append(alloc, proc);
    }

    fn exhaustLineageLocked(self: *Scheduler, rt: *skript.Runtime, budget: *skript.EvalContext.Budget) void {
        for (self.processes.items) |process| {
            const ctx = if (process.eval_context) |*value| value else continue;
            if (ctx.budget() != budget or process.completed.load(.acquire)) continue;
            process.deadline = null;
            process.recv_deadline = null;
            process.suspended = false;
            self.clearWaitEdgesLocked(process);
            completeProcess(rt, process, skript.Value.err(error.Exhausted));
            self.wakeWaitersLocked(rt, process);
        }
    }

    /// Enqueue every process whose deadline has passed. The deadline is NOT
    /// cleared for resumed processes: the resumed process's blocking
    /// intrinsic (sleep / receive-timeout resume path) clears it. Clearing
    /// here would make the re-dispatched intrinsic look like a fresh call and
    /// re-arm the deadline (infinite sleep). Completed processes with a stale
    /// deadline (a crash with an armed timer) get their deadline cleared and
    /// are never re-woken.
    pub fn wakeDueLocked(self: *Scheduler, now_ns: i128) void {
        for (self.processes.items) |proc| {
            const d = proc.deadline orelse continue;
            if (proc.completed.load(.acquire)) {
                proc.deadline = null;
                continue;
            }
            if (d <= now_ns and !proc.queued) {
                self.enqueueLocked(proc);
            }
        }
    }

    /// Find whether `start` waits on `destination`, through any number of
    /// concurrent use edges. Caller holds the scheduler mutex.
    pub fn hasWaitPathLocked(
        self: *Scheduler,
        ctx: *skript.EvalContext,
        start: *Process,
        destination: *Process,
    ) skript.Error!bool {
        if (start == destination) return true;

        self.wait_search_epoch +%= 1;
        if (self.wait_search_epoch == 0) {
            for (self.processes.items) |process| {
                process.wait_search_epoch = 0;
                process.wait_search_next = null;
            }
            self.wait_search_epoch = 1;
        }
        const epoch = self.wait_search_epoch;
        start.wait_search_epoch = epoch;
        start.wait_search_next = null;

        var head: ?*Process = start;
        var tail: ?*Process = start;
        defer {
            while (head) |process| {
                head = process.wait_search_next;
                process.wait_search_next = null;
            }
        }

        while (head) |process| {
            head = process.wait_search_next;
            if (head == null) tail = null;
            process.wait_search_next = null;
            try ctx.charge(.{ .work = 1 }, .scheduler);
            for (process.waiting_on.items) |next| {
                try ctx.charge(.{ .work = 1 }, .scheduler);
                if (next == destination) return true;
                if (next.wait_search_epoch == epoch) continue;
                next.wait_search_epoch = epoch;
                next.wait_search_next = null;
                if (tail) |last| {
                    last.wait_search_next = next;
                } else {
                    head = next;
                }
                tail = next;
            }
        }
        return false;
    }

    /// Add all distinct wait edges after reserving every required slot.
    /// Caller holds the scheduler mutex.
    pub fn addWaitEdgesLocked(
        self: *Scheduler,
        alloc: std.mem.Allocator,
        waiter: *Process,
        targets: []const *Process,
    ) !void {
        var edge_count: usize = 0;
        for (targets, 0..) |target, index| {
            if (hasWaitEdge(waiter, target) or containsProcess(targets[0..index], target)) continue;
            edge_count += 1;
        }
        try waiter.waiting_on.ensureUnusedCapacity(alloc, edge_count);
        for (targets, 0..) |target, index| {
            if (hasWaitEdge(waiter, target) or containsProcess(targets[0..index], target)) continue;
            try target.waiters.ensureUnusedCapacity(alloc, 1);
        }
        for (targets, 0..) |target, index| {
            if (hasWaitEdge(waiter, target) or containsProcess(targets[0..index], target)) continue;
            waiter.waiting_on.appendAssumeCapacity(target);
            target.waiters.appendAssumeCapacity(waiter);
        }
        _ = self;
    }

    /// Remove this process from each target's waiter list, then clear all
    /// outgoing wait edges. Caller holds the scheduler mutex.
    pub fn clearWaitEdgesLocked(self: *Scheduler, waiter: *Process) void {
        for (waiter.waiting_on.items) |target| {
            removeWaiter(target, waiter);
        }
        waiter.waiting_on.clearRetainingCapacity();
        _ = self;
    }

    /// Wake each unique waiter and remove its complete wait group before
    /// re-dispatch. Registration reserves queue capacity before suspension.
    pub fn wakeWaitersLocked(self: *Scheduler, rt: *skript.Runtime, p: *Process) void {
        while (p.waiters.items.len != 0) {
            const w = p.waiters.pop().?;
            self.clearWaitEdgesLocked(w);
            if (!w.queued and !w.completed.load(.acquire)) {
                self.enqueueLocked(w);
            }
        }
        self.event.set(rt.io);
    }

    /// Minimum non-null deadline across all processes; null when none sleep.
    pub fn earliestDeadlineLocked(self: *Scheduler) ?i128 {
        var best: ?i128 = null;
        for (self.processes.items) |proc| {
            const d = proc.deadline orelse continue;
            if (best == null or d < best.?) best = d;
        }
        return best;
    }

    /// Snapshot every registered process for the host (REPL). Takes the
    /// mutex; the caller frees `out` (allocated from `alloc`). `io` is the
    /// caller's Io instance (the mutex lock needs it). `running` is the
    /// process the runner is currently executing — pass null to let the
    /// snapshot read `self.running_process` itself under the mutex (the
    /// REPL's fibers panel does; a test can force a specific pointer). A
    /// process is .running when it is `running`; otherwise a completed
    /// process is .done — or .crashed when its result is an error value
    /// (completeProcess records a crash as an error value) — a queued
    /// process is .queued, and everything else is .suspended. The mailbox
    /// count walks the process's node chain; the walk is safe under the
    /// mutex (push and unlink both take it).
    pub fn snapshotProcesses(
        self: *Scheduler,
        alloc: std.mem.Allocator,
        io: std.Io,
        running: ?*Process,
    ) ![]ProcessInfo {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const running_proc = running orelse self.running_process;
        const infos = try alloc.alloc(ProcessInfo, self.processes.items.len);
        errdefer alloc.free(infos);
        for (self.processes.items, 0..) |proc, i| {
            const status: ProcessInfo.Status = if (running_proc != null and proc == running_proc.?)
                .running
            else if (proc.completed.load(.acquire))
                (if (proc.result.typ == skript.builtins.type_error) .crashed else .done)
            else if (proc.queued)
                .queued
            else
                .suspended;
            infos[i] = .{
                .pid = proc.pid,
                .status = status,
                .deadline = proc.deadline,
                .mailbox = proc.mailLenLocked(),
                .module_path = proc.module_path,
            };
        }
        return infos;
    }
};

/// The runner task: drain the ready queue round-robin (quantum per process)
/// until `target` completes, then return its result — which resolves the
/// target's Io future and unparks the host thread parked in awaitProcess.
/// When the queue empties with the target still incomplete, the runner waits
/// for a wake source instead of busy-looping: a send (from a running process
/// or the host, via `event`) or a sleep deadline firing.
/// Publish a process's final result: write `result` (release-ordered via
/// `completed`), then the FutureObj flag. Used by the done and crash paths.
fn completeProcess(rt: *skript.Runtime, p: *Process, result: skript.Value) void {
    rt.releaseFiberGuards(&p.fib);
    p.result = result;
    p.completed.store(true, .release);
    if (p.future_obj.load(.acquire)) |f| {
        f.result = result;
        f.done.store(true, .release);
    }
}

/// The runner task: drain the ready queue round-robin (quantum per process)
/// until shutdown. The runner is the runtime's permanent servant — it never
/// exits on a quiet queue (a settle-exit raced with spawnEval's enqueue and
/// could starve a fresh process: the host's runner_active load saw the old
/// runner still alive, skipped the dispatch, and the runner returned
/// immediately after). Instead it parks on the scheduler event (or the
/// earliest deadline) and spawnEval/send wake it. A process crash (evalReg
/// error) marks the process crashed and the loop continues (crash
/// isolation); only a TARGET crash terminates the runner (the host already
/// received the error through its poll).
pub fn runOne(rt: *skript.Runtime, sched: *Scheduler, target: *Process) skript.Error!skript.Value {
    while (true) {
        if (sched.shutdown.load(.acquire)) {
            // running_process is already null (cleared at the end of the
            // last switch), but clear it again on the shutdown-exit path —
            // a runner must never exit with a stale executing-process
            // pointer published.
            sched.mutex.lockUncancelable(rt.io);
            sched.running_process = null;
            sched.mutex.unlock(rt.io);
            sched.runner_active.store(false, .release);
            return target.result;
        }
        sched.mutex.lockUncancelable(rt.io);
        const p = sched.popLocked();
        // Publish the executing process for the host (REPL fibers panel):
        // null while the runner parks, the popped process otherwise.
        // Written under the mutex (the host reads it under the same mutex)
        // and cleared at the end of the switch and on the exit paths below.
        sched.running_process = p;
        sched.mutex.unlock(rt.io);
        const p_opt = p orelse {
            // Ready queue empty: park for a wake source (a send, a spawn, or
            // a deadline firing).
            const now_ns: i128 = @intCast(std.Io.Clock.awake.now(rt.io).nanoseconds);
            sched.mutex.lockUncancelable(rt.io);
            const d_opt = sched.earliestDeadlineLocked();
            sched.mutex.unlock(rt.io);
            if (d_opt) |d| {
                if (d <= now_ns) {
                    sched.mutex.lockUncancelable(rt.io);
                    sched.wakeDueLocked(now_ns);
                    sched.mutex.unlock(rt.io);
                    continue; // re-drain immediately
                }
                // Park on the event until the earliest deadline. The
                // deadline is absolute (Uring: IORING_TIMEOUT_ABS), so a
                // send that sets the event wakes us early regardless. Reset
                // first — a set event would make waitTimeout return
                // immediately and busy-loop. The host never parks on the
                // event (awaitProcess polls on a timer), so the runner is
                // the only waiter and reset's "no pending wait" assumption
                // holds. Re-check the queue after the reset: a send's
                // enqueue+set can land between the pop-empty and the reset,
                // and the reset would clobber that set (lost wake).
                sched.event.reset();
                sched.mutex.lockUncancelable(rt.io);
                const has_work = sched.ready.items.len > 0;
                sched.mutex.unlock(rt.io);
                if (has_work) continue;
                // The deinit's shutdown set can land before this reset and
                // be clobbered — re-check the flag so a shutdown wake is
                // never lost.
                if (sched.shutdown.load(.acquire)) continue;
                sched.event.waitTimeout(rt.io, .{
                    .deadline = .{
                        .raw = std.Io.Timestamp.fromNanoseconds(@intCast(d)),
                        .clock = .awake,
                    },
                }) catch |err| switch (err) {
                    error.Timeout => {}, // deadline elapsed: wakeDue below
                    error.Canceled => {}, // runner canceled: re-drain, loop exits via shutdown/target
                };
                // Timed out (or the event was set): re-check deadlines and
                // re-drain. Processes whose deadline passed are enqueued by
                // wakeDue; a set event left the queue unchanged and the loop
                // pops whatever is now runnable.
                sched.mutex.lockUncancelable(rt.io);
                sched.wakeDueLocked(@intCast(std.Io.Clock.awake.now(rt.io).nanoseconds));
                sched.mutex.unlock(rt.io);
                continue;
            } else {
                // No deadline: park until an event fires. A process blocked
                // forever on receive with no sender parks here —
                // Erlang-consistent: the host await hangs, no busy loop.
                sched.event.reset();
                sched.mutex.lockUncancelable(rt.io);
                const has_work = sched.ready.items.len > 0;
                sched.mutex.unlock(rt.io);
                if (has_work) continue;
                // See the waitTimeout branch: a shutdown set clobbered by
                // the reset must not leave the runner parked forever.
                if (sched.shutdown.load(.acquire)) continue;
                sched.event.wait(rt.io) catch |err| switch (err) {
                    error.Canceled => {}, // runner canceled: loop exits via shutdown
                };
                continue;
            }
        };
        const run = p_opt;
        current_process = run;
        // Cleared at the end of this iteration — a while-body defer fires
        // per iteration (also on `continue` above and on evalReg error), so
        // a spawn from inside this process's evaluation sees null outside.
        defer current_process = null;
        if (run.completed.load(.acquire)) continue;
        const eval_context = if (run.eval_context) |*value| value else rt.context();
        const context_scope = eval_context.activate();
        defer context_scope.deinit();
        const status = rt.evalReg(rt.root_ns, &run.fib, quantum) catch |err| {
            // Crash isolation: a process error does not take down the
            // scheduler. Mark the process crashed (completed with an error
            // value), drop any armed timer, and keep draining; only the
            // target's crash propagates to its awaiter.
            run.deadline = null;
            // Only an uncaught user raise has a raw payload.
            run.raised = if (err == error.Raised) run.fib.raised else .nil;
            completeProcess(rt, run, skript.Value.err(err));
            // Wake the module's loaders so they observe the crash and fail
            // with the same error (crash isolation composes). On a target
            // crash the runner exits right after — the wake still runs so a
            // loader of the crashed module is not left suspended.
            sched.mutex.lockUncancelable(rt.io);
            if (err == error.Exhausted) {
                if (eval_context.budget()) |budget| sched.exhaustLineageLocked(rt, budget);
            }
            sched.clearWaitEdgesLocked(run);
            sched.wakeWaitersLocked(rt, run);
            sched.running_process = null;
            sched.mutex.unlock(rt.io);
            if (run == target) {
                sched.runner_active.store(false, .release);
                return err;
            }
            continue;
        };
        switch (status) {
            .done => {
                // A raw uncaught raise is distinct from a system error:
                // both finish with an error value, but only the former
                // publishes fib.raised. Do this before completeProcess's
                // release-store so observers see the matching result.
                const result = run.fib.getReg(0);
                run.raised = if (result.typ == skript.builtins.type_error and
                    result.errorCode() == error.Raised)
                    run.fib.raised
                else
                    .nil;
                completeProcess(rt, run, result);
                // Wake the module's loaders (processes suspended in a load on
                // this process) so they observe the result; the event.set
                // inside also covers any host parked in awaitProcess's poll
                // loop.
                sched.mutex.lockUncancelable(rt.io);
                sched.clearWaitEdgesLocked(run);
                sched.wakeWaitersLocked(rt, run);
                sched.running_process = null;
                sched.mutex.unlock(rt.io);
                // Errors-as-values: an uncaught skript error completes the
                // process with an error VALUE (not a Zig error), so the old
                // target-crash exit is reached here for the TARGET only. A
                // target error exits the runner (the awaiter already got the
                // value through pollProcess's unwrapError; the next spawn
                // dispatches fresh); a successful target and any non-target
                // completion keep the runner alive (back-to-back spawns,
                // crash isolation).
                if (run == target and run.result.typ == skript.builtins.type_error) {
                    sched.runner_active.store(false, .release);
                    return target.result;
                }
            },
            .yielded => {
                // A send from another process may have enqueued us while we
                // were running (we were popped, so queued was false); the
                // enqueue guard keeps a single queue entry per quantum.
                sched.mutex.lockUncancelable(rt.io);
                defer sched.mutex.unlock(rt.io);
                sched.enqueueLocked(run);
            },
            // Suspended: the process stays OFF the queue. Its wake source —
            // a send or its deadline firing — re-enqueues it.
            .suspended => run.suspended = true,
        }
        // The process is done, crashed, suspended, or yielded-re-enqueued:
        // nothing executes anymore. Clear the published pointer under the
        // mutex (the host reads it under the mutex).
        sched.mutex.lockUncancelable(rt.io);
        sched.running_process = null;
        sched.mutex.unlock(rt.io);
    }
}

test "Phase B: spawnEval + awaitProcess roundtrip" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const proc = try rt.spawnEval("(defn (f x) (* x x)) (f 7)");
    // With eager execution (async fallback) completion may already be
    // visible: poll may return the value OR null before await — assert only
    // that it does not crash.
    _ = rt.pollProcess(proc);
    // The await must return the eval result regardless of eager or pool
    // execution.
    try std.testing.expectEqual(skript.Value.i64(49), try rt.awaitProcess(proc));
    // After await the runner has published to the FutureObj: poll MUST now
    // report the value.
    const polled = rt.pollProcess(proc) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(skript.Value.i64(49), try polled);
}

test "Process mailbox: FIFO push/pop via linked nodes" {
    const alloc = std.testing.allocator;
    // Nodes are normally arena-allocated (rt.static, never freed); use an
    // arena here so the leak checker sees a clean slate.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const node_alloc = arena.allocator();
    var sched = Scheduler.init(alloc);
    defer sched.deinit();
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var proc: Process = .{ .pid = 1, .fib = undefined };

    sched.mutex.lockUncancelable(std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), proc.mailLenLocked());
    try proc.mailPushLocked(node_alloc, skript.Value.i64(1));
    try proc.mailPushLocked(node_alloc, skript.Value.i64(2));
    try proc.mailPushLocked(node_alloc, skript.Value.i64(3));
    try std.testing.expectEqual(@as(usize, 3), proc.mailLenLocked());
    sched.mutex.unlock(std.testing.io);
    // The production pop path: mailMatch with a null predicate.
    try std.testing.expectEqual(skript.Value.i64(1), (try proc.mailMatch(rt, .nil, null)).?);
    try std.testing.expectEqual(skript.Value.i64(2), (try proc.mailMatch(rt, .nil, null)).?);
    sched.mutex.lockUncancelable(std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), proc.mailLenLocked());
    sched.mutex.unlock(std.testing.io);
    try std.testing.expectEqual(skript.Value.i64(3), (try proc.mailMatch(rt, .nil, null)).?);
    try std.testing.expect((try proc.mailMatch(rt, .nil, null)) == null);
    sched.mutex.lockUncancelable(std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), proc.mailLenLocked());
    // Push after full drain still works.
    try proc.mailPushLocked(node_alloc, skript.Value.i64(4));
    sched.mutex.unlock(std.testing.io);
    try std.testing.expectEqual(skript.Value.i64(4), (try proc.mailMatch(rt, .nil, null)).?);
}

test "Process mailbox: a receive inside a predicate must not duplicate the matched message" {
    // Regression for the re-entrant mailMatch: a nested (receive) inside a
    // receive-predicate consumes messages during the outer lock-free scan,
    // so the scan's prev/cur go stale. The outer unlink used to write
    // through the stale (now detached) prev — a no-op on the live chain —
    // leaving the matched message in the mailbox: a duplicated delivery
    // (the smoke printed 223 instead of 23). The re-validation walk must
    // unlink the matched node from its CURRENT predecessor.
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const node_alloc = arena.allocator();
    var sched = Scheduler.init(alloc);
    defer sched.deinit();
    // Init: prelude constants are resolved via Runtime.init.
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var proc: Process = .{ .pid = 1, .fib = undefined };

    sched.mutex.lockUncancelable(std.testing.io);
    try proc.mailPushLocked(node_alloc, skript.Value.i64(1));
    try proc.mailPushLocked(node_alloc, skript.Value.i64(2));
    try proc.mailPushLocked(node_alloc, skript.Value.i64(3));
    sched.mutex.unlock(std.testing.io);

    // The pred: skip 1; for any other message run a nested (receive), which
    // pops the mailbox head (msg 1) DURING the outer scan and returns it —
    // a truthy result, so the outer scan matches msg 2. The matched msg 2
    // must then be unlinked from its current predecessor (the head) and NOT
    // remain in the mailbox.
    const pred = try rt.evalString("(fn (m) (if (@i64.eq m 1) #f (receive)))");
    skript.scheduler.current_process = &proc;
    defer skript.scheduler.current_process = null;
    try std.testing.expectEqual(skript.Value.i64(2), (try proc.mailMatch(rt, .nil, pred)).?);
    sched.mutex.lockUncancelable(std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), proc.mailLenLocked());
    sched.mutex.unlock(std.testing.io);
    // Only msg 3 remains: msg 1 went to the nested receive, msg 2 was the
    // match — nothing was duplicated back into the mailbox.
    try std.testing.expectEqual(skript.Value.i64(3), (try proc.mailMatch(rt, .nil, null)).?);
    try std.testing.expect((try proc.mailMatch(rt, .nil, null)) == null);
}

test "Process mailbox: a predicate that consumes the matched node restarts the scan" {
    // The re-validation's restart branch: a predicate that receives the
    // message it is testing (the head) consumes cur itself before the outer
    // unlink can run. mailMatch must NOT return the consumed node; it
    // restarts the scan from the head and the pred re-evaluates on the
    // remaining messages. Here every message is consumed by its own
    // predicate's nested receive, so mailMatch returns null with an empty
    // mailbox — no message is delivered twice and none is lost to a stale
    // unlink.
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const node_alloc = arena.allocator();
    var sched = Scheduler.init(alloc);
    defer sched.deinit();
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var proc: Process = .{ .pid = 1, .fib = undefined };

    sched.mutex.lockUncancelable(std.testing.io);
    try proc.mailPushLocked(node_alloc, skript.Value.i64(1));
    try proc.mailPushLocked(node_alloc, skript.Value.i64(2));
    try proc.mailPushLocked(node_alloc, skript.Value.i64(3));
    sched.mutex.unlock(std.testing.io);

    const pred = try rt.evalString("(fn (m) (receive))");
    skript.scheduler.current_process = &proc;
    defer skript.scheduler.current_process = null;
    try std.testing.expect((try proc.mailMatch(rt, .nil, pred)) == null);
    sched.mutex.lockUncancelable(std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), proc.mailLenLocked());
    sched.mutex.unlock(std.testing.io);
}

test "Scheduler: earliestDeadline and wakeDue fire only due processes" {
    const alloc = std.testing.allocator;
    var sched = Scheduler.init(alloc);
    defer sched.deinit();

    var due: Process = .{ .pid = 1, .fib = undefined, .deadline = 100 };
    var later: Process = .{ .pid = 2, .fib = undefined, .deadline = 200 };
    var no_deadline: Process = .{ .pid = 3, .fib = undefined };
    sched.mutex.lockUncancelable(std.testing.io);
    defer sched.mutex.unlock(std.testing.io);
    try sched.registerLocked(alloc, &due);
    try sched.registerLocked(alloc, &later);
    try sched.registerLocked(alloc, &no_deadline);

    try std.testing.expectEqual(@as(?i128, 100), sched.earliestDeadlineLocked());

    sched.wakeDueLocked(150); // due fires; later and no_deadline stay untouched
    // The deadline is NOT cleared by wakeDue: the resumed process's blocking
    // intrinsic (sleep's resume path) clears it on re-dispatch. Clearing here
    // would re-arm the deadline (infinite sleep).
    try std.testing.expectEqual(@as(?i128, 100), due.deadline);
    try std.testing.expect(due.queued);
    try std.testing.expectEqual(@as(?i128, 200), later.deadline);
    try std.testing.expect(!later.queued);
    try std.testing.expectEqual(@as(?i128, 100), sched.earliestDeadlineLocked());
    // The ready queue holds exactly the woken process.
    try std.testing.expect(sched.popLocked() == &due);
    try std.testing.expect(!due.queued);
    // The resumed process's blocking intrinsic clears its own deadline on
    // re-dispatch (sleep's resume path) — simulate that here.
    due.deadline = null;

    sched.wakeDueLocked(300); // later is now due too
    try std.testing.expectEqual(@as(?i128, 200), later.deadline);
    try std.testing.expect(later.queued);
    try std.testing.expectEqual(@as(?i128, 200), sched.earliestDeadlineLocked());
}

test "Scheduler: registered deadlines wake when further allocation is refused" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var sched = Scheduler.init(failing.allocator());
    defer sched.deinit();
    var due: Process = .{
        .pid = 1,
        .fib = .{ .stack = &.{}, .ip = &.{} },
        .deadline = 100,
    };
    sched.mutex.lockUncancelable(std.testing.io);
    defer sched.mutex.unlock(std.testing.io);
    try sched.registerLocked(failing.allocator(), &due);
    failing.fail_index = failing.alloc_index;

    sched.wakeDueLocked(100);

    try std.testing.expect(sched.popLocked() == &due);
}

test "Scheduler: wake event initializes unset" {
    const alloc = std.testing.allocator;
    var sched = Scheduler.init(alloc);
    defer sched.deinit();
    try std.testing.expect(!sched.event.isSet());
    sched.event.set(std.testing.io);
    try std.testing.expect(sched.event.isSet());
    sched.event.reset();
    try std.testing.expect(!sched.event.isSet());
}

test "Scheduler: snapshotProcesses reports status, mailbox, deadline, module_path" {
    const alloc = std.testing.allocator;
    var sched = Scheduler.init(alloc);
    defer sched.deinit();
    // Mailbox nodes are normally arena-allocated (rt.static); use an arena
    // here so the leak checker sees a clean slate.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const node_alloc = arena.allocator();

    var running: Process = .{ .pid = 1, .fib = undefined };
    var done: Process = .{ .pid = 2, .fib = undefined };
    var crashed: Process = .{ .pid = 3, .fib = undefined };
    var queued: Process = .{ .pid = 4, .fib = undefined, .deadline = 1234 };
    var suspended: Process = .{ .pid = 5, .fib = undefined };
    done.completed.store(true, .release);
    done.result = skript.Value.i64(42);
    crashed.completed.store(true, .release);
    crashed.result = skript.Value.err(error.Unimplemented);
    queued.queued = true;
    suspended.module_path = "somedir/mod.pt";

    sched.mutex.lockUncancelable(std.testing.io);
    try sched.registerLocked(alloc, &running);
    try sched.registerLocked(alloc, &done);
    try sched.registerLocked(alloc, &crashed);
    try sched.registerLocked(alloc, &queued);
    try sched.registerLocked(alloc, &suspended);
    try crashed.mailPushLocked(node_alloc, skript.Value.i64(1));
    try crashed.mailPushLocked(node_alloc, skript.Value.i64(2));
    sched.running_process = &running; // the runner publishes this under the mutex
    sched.mutex.unlock(std.testing.io);

    // running = null: the snapshot reads sched.running_process itself.
    const snap = try sched.snapshotProcesses(alloc, std.testing.io, null);
    defer alloc.free(snap);
    try std.testing.expectEqual(@as(usize, 5), snap.len);
    try std.testing.expectEqual(ProcessInfo.Status.running, snap[0].status);
    try std.testing.expectEqual(@as(u32, 1), snap[0].pid);
    try std.testing.expect(snap[0].module_path == null);
    try std.testing.expectEqual(ProcessInfo.Status.done, snap[1].status);
    try std.testing.expectEqual(ProcessInfo.Status.crashed, snap[2].status);
    try std.testing.expectEqual(@as(usize, 2), snap[2].mailbox);
    try std.testing.expectEqual(ProcessInfo.Status.queued, snap[3].status);
    try std.testing.expectEqual(@as(?i128, 1234), snap[3].deadline);
    try std.testing.expectEqual(ProcessInfo.Status.suspended, snap[4].status);
    try std.testing.expect(snap[4].deadline == null);
    try std.testing.expectEqualStrings("somedir/mod.pt", snap[4].module_path.?);

    // An explicit `running` argument wins over sched.running_process.
    const snap2 = try sched.snapshotProcesses(alloc, std.testing.io, &done);
    defer alloc.free(snap2);
    try std.testing.expectEqual(ProcessInfo.Status.running, snap2[1].status);
    try std.testing.expectEqual(ProcessInfo.Status.suspended, snap2[0].status);
}

test "Scheduler: wait graph traverses concurrent edges and repeated nodes" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    var a: Process = .{ .pid = 1, .fib = undefined };
    var b: Process = .{ .pid = 2, .fib = undefined };
    var c: Process = .{ .pid = 3, .fib = undefined };
    var unrelated: Process = .{ .pid = 4, .fib = undefined };

    rt.scheduler.mutex.lockUncancelable(rt.io);
    defer rt.scheduler.mutex.unlock(rt.io);
    try rt.scheduler.addWaitEdgesLocked(rt.static, &a, &.{ &b, &c });
    try rt.scheduler.addWaitEdgesLocked(rt.static, &b, &.{&a});
    try rt.scheduler.addWaitEdgesLocked(rt.static, &c, &.{&a});

    const ctx = rt.context();
    try std.testing.expect(try rt.scheduler.hasWaitPathLocked(ctx, &a, &c));
    try std.testing.expect(!(try rt.scheduler.hasWaitPathLocked(ctx, &a, &unrelated)));

    rt.scheduler.clearWaitEdgesLocked(&a);
    try std.testing.expectEqual(@as(usize, 0), a.waiting_on.items.len);
    try std.testing.expectEqual(@as(usize, 0), b.waiters.items.len);
    try std.testing.expectEqual(@as(usize, 0), c.waiters.items.len);
    rt.scheduler.clearWaitEdgesLocked(&b);
    rt.scheduler.clearWaitEdgesLocked(&c);
    try std.testing.expectEqual(@as(usize, 0), a.waiters.items.len);
}

test "Scheduler: completion wakes all waiters and clears their other dependencies" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    var completed: Process = .{ .pid = 1, .fib = undefined };
    var other: Process = .{ .pid = 2, .fib = undefined };
    var first: Process = .{ .pid = 3, .fib = undefined };
    var second: Process = .{ .pid = 4, .fib = undefined };

    rt.scheduler.mutex.lockUncancelable(rt.io);
    defer rt.scheduler.mutex.unlock(rt.io);
    defer rt.scheduler.processes.clearRetainingCapacity();
    for ([_]*Process{ &completed, &other, &first, &second }) |process| {
        try rt.scheduler.registerLocked(rt.scheduler.alloc, process);
    }
    try rt.scheduler.addWaitEdgesLocked(rt.static, &first, &.{ &completed, &other });
    try rt.scheduler.addWaitEdgesLocked(rt.static, &second, &.{ &completed, &other });
    rt.scheduler.wakeWaitersLocked(rt, &completed);

    try std.testing.expectEqual(@as(usize, 0), completed.waiters.items.len);
    try std.testing.expectEqual(@as(usize, 0), other.waiters.items.len);
    try std.testing.expectEqual(@as(usize, 0), first.waiting_on.items.len);
    try std.testing.expectEqual(@as(usize, 0), second.waiting_on.items.len);
    try std.testing.expectEqual(@as(usize, 2), rt.scheduler.ready.items.len);
    try std.testing.expect(rt.scheduler.popLocked() == &second);
    try std.testing.expect(rt.scheduler.popLocked() == &first);
}
