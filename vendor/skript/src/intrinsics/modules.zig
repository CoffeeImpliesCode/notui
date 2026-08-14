//! Module intrinsics (Phase D): (load PATH).
//!
//! Suspend/resume contract: a load dispatches the module's evaluation into
//! its OWN process (spawnEvalWithNsContext) and returns `error.WouldBlock` — evalReg
//! rewinds the ip and suspends the caller, and the scheduler runner picks up
//! the module process from the ready queue. When the module process
//! completes, the scheduler's wakeWaitersLocked re-enqueues this process;
//! the re-dispatched call finds the registry entry transitioned (loading →
//! loaded/failed) and returns the module's namespace, or the module's crash
//! propagated as a Zig error into the loader's own crash. A spurious wake (a
//! send) re-suspends via the still-loading arm.
//!
//! Registry protocol: all registry access runs under the scheduler mutex.
//! The miss path RELEASES the mutex across the module spawn (spawnEvalWithNsContext
//! takes the mutex internally — the mutex is not re-entrant), so the lock is
//! block-scoped rather than function-wide. The entry inserted on a miss is
//! the load-once barrier: v1 has ONE runner, so only the currently-running
//! process performs loads, and it fills the entry's process + waiter linkage
//! before suspending — a `.loading` entry with a null process is never
//! observable.

const std = @import("std");

const skript = @import("../root.zig");
const Value = skript.Value;
const Error = skript.Error;
const Runtime = skript.Runtime;
const Process = skript.scheduler.Process;
const EvalContext = skript.EvalContext;
const ModuleEntry = @import("../modules.zig").ModuleEntry;
const ExportSpec = @import("../modules.zig").ExportSpec;
const Status = @import("../modules.zig").Status;

const intrin = @import("root.zig");
const Referral = struct {
    public: skript.Sym,
    local: skript.Sym,
};
const RawUseSpec = struct {
    path: []const u8,
    alias: ?skript.Sym,
    referrals: []const Referral,
};

const UseSpec = struct {
    canonical: []const u8,
    alias: ?skript.Sym,
    referrals: []const Referral,
    owner: usize,
    entry: ?*ModuleEntry = null,
    loaded_ns: ?Value = null,
    is_miss: bool = false,
};

const PreparedModule = struct {
    entry: *ModuleEntry,
    canonical: []const u8,
    source: []const u8,
    namespace: Value,
};

/// (load PATH) — load the module at PATH once per canonical path and return
/// its namespace. PATH resolves against the calling module's directory (or
/// the process cwd for an anonymous eval). Repeat loads return the SAME
/// namespace value (load-once identity). The calling process suspends until
/// the module process completes; a module crash (or a failed read/compile)
/// crashes the loader with the same error, and a failed module stays failed.
/// A load cycle (A→B→A, or a module loading itself) crashes the loader with
/// error.CircularLoad.
pub fn load(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    try requireTrustedConcrete(ctx);
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_string);

    // Host context (--stack, or a direct host call): no scheduler process to
    // suspend — fail loudly, mirroring the process intrinsics.
    const proc = skript.scheduler.current_process orelse return error.Unimplemented;
    // stringBytes meters the bounded scan, includes the NUL check, and returns
    // a sentinel slice whose length excludes the terminator.
    const path_arg = try ctx.stringBytes(
        args[0].obj.toPtr([*:0]const u8),
        1024,
        .native,
    );
    if (path_arg.len == 0) return error.Unbound;
    const canonical = try resolveCanonical(rt, proc, path_arg);
    // Native callback evaluations have no resumable module continuation,
    // even when their enclosing scheduler process is still on this thread.
    const may_suspend = ctx.allow_suspend and !ctx.native_reentry;

    // Registry entries keep stable addresses across unlock/spawn/relock.
    const miss_entry = miss: {
        rt.scheduler.mutex.lockUncancelable(rt.io);
        defer rt.scheduler.mutex.unlock(rt.io);

        if (may_suspend) rt.scheduler.clearWaitEdgesLocked(proc);
        if (rt.modules.findLocked(canonical)) |entry| {
            switch (entry.status) {
                .loaded => {
                    return entry.ns;
                },
                .failed => {
                    return entry.err orelse error.InvalidCode;
                },
                .loading => {
                    if (!may_suspend) return error.Denied;
                    const target = entry.process orelse return error.InvalidCode;
                    if (target.completed.load(.acquire)) {
                        return publishLoaded(rt, entry, target);
                    }
                    if (try rt.scheduler.hasWaitPathLocked(ctx, target, proc)) {
                        return error.CircularLoad;
                    }
                    try rt.scheduler.addWaitEdgesLocked(rt.static, proc, &.{target});
                    return error.WouldBlock;
                },
            }
        }

        if (!may_suspend) return error.Denied;
        // MISS: insert the load-once barrier. The current runner does not
        // dispatch another evaluator until this process suspends.
        break :miss try rt.modules.insertLocked(rt.static, canonical, null);
    };

    // File IO and process creation run outside the scheduler mutex.
    const src = readModuleSource(rt, canonical) catch |err| {
        failEntry(rt, miss_entry, err);
        return err;
    };
    const module_ns = createModuleNamespace(rt) catch |err| {
        failEntry(rt, miss_entry, err);
        return err;
    };
    const mod_proc = rt.spawnEvalWithNsContext(ctx, src, module_ns, canonical) catch |err| {
        failEntry(rt, miss_entry, err);
        return err;
    };

    {
        rt.scheduler.mutex.lockUncancelable(rt.io);
        defer rt.scheduler.mutex.unlock(rt.io);
        miss_entry.process = mod_proc;
        try rt.scheduler.addWaitEdgesLocked(rt.static, proc, &.{mod_proc});
    }
    return error.WouldBlock;
}

/// Declare each `(local external)` or `(alias public external)` export.
/// Source validation is deferred until module completion so declarations can
/// precede definitions and imports.
pub fn moduleExport(ctx: *EvalContext, ns: Value, _: Value, args: []const Value) Error!Value {
    try ctx.check();
    if (ctx.mode != .concrete or ctx.execution != .trusted or
        ctx.effects.state_write != .allow or ctx.effects.module != .allow)
    {
        return error.Denied;
    }
    const process = skript.scheduler.current_process orelse return error.Unimplemented;
    if (process.module_path == null or ns.typ != skript.builtins.type_namespace or
        ns.obj != process.fib.ns.obj)
    {
        return error.Denied;
    }
    if (args.len == 0) return error.ArityMismatch;
    if (args.len > 1024 or process.exported.items.len > 1024 - args.len) {
        return error.LimitExceeded;
    }
    const declarations = try ctx.scratch.alloc(ExportSpec, args.len);
    defer ctx.scratch.free(declarations);
    for (args, 0..) |arg, index| {
        var elements: [3]Value = undefined;
        const count = try fixedList(ctx, arg, &elements);
        if (count != 2 and count != 3) return error.MalformedAst;
        const external = try planSymbol(ctx, elements[if (count == 2) 1 else 2]);
        if (Runtime.isSealedName(external)) return error.NameConflict;
        const source: ExportSpec.Source = if (count == 2)
            .{ .local = try planSymbol(ctx, elements[0]) }
        else
            .{ .reexport = .{
                .alias = try planSymbol(ctx, elements[0]),
                .public = try planSymbol(ctx, elements[1]),
            } };
        for (process.exported.items) |previous| {
            try ctx.charge(.{ .work = 1 }, .native);
            if (previous.external == external) return error.NameConflict;
        }
        for (declarations[0..index]) |previous| {
            try ctx.charge(.{ .work = 1 }, .native);
            if (previous.external == external) return error.NameConflict;
        }
        declarations[index] = .{ .external = external, .source = source };
    }
    try process.exported.ensureUnusedCapacity(ctx.runtime.static, declarations.len);
    for (declarations) |declaration| process.exported.appendAssumeCapacity(declaration);
    return .nil;
}

/// Each argument is `(canonical-path-string alias-symbol referrals-list)`.
/// Every referral is `(public-symbol local-symbol)`.
pub fn useMulti(ctx: *EvalContext, ns: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    try requireTrustedConcrete(ctx);
    if (args.len > 1024) return error.LimitExceeded;
    const proc = skript.scheduler.current_process orelse return error.Unimplemented;
    if (args.len == 0) return .nil;
    if (ns.typ != skript.builtins.type_namespace) return error.TypeMismatch;
    const ns_table = ns.obj.toRef().deref(skript.Namespace);
    if (ns_table.get != skript.HashMapNamespace.vtable.get) return error.Denied;

    const raw_specs = try ctx.scratch.alloc(RawUseSpec, args.len);
    defer ctx.scratch.free(raw_specs);
    const specs = try ctx.scratch.alloc(UseSpec, args.len);
    defer ctx.scratch.free(specs);
    const prepared = try ctx.scratch.alloc(PreparedModule, args.len);
    defer ctx.scratch.free(prepared);
    const wait_targets = try ctx.scratch.alloc(*Process, args.len);
    defer ctx.scratch.free(wait_targets);
    var referral_storage = std.heap.ArenaAllocator.init(ctx.scratch);
    defer referral_storage.deinit();
    var destinations = std.AutoHashMap(skript.Sym, void).init(ctx.scratch);
    defer destinations.deinit();

    // Validate every destination before resolving paths or loading modules.
    for (args, 0..) |arg, i| {
        var elements: [3]Value = undefined;
        if (try fixedList(ctx, arg, &elements) != 3) return error.MalformedAst;
        try intrin.typeAssert(elements[0], skript.builtins.type_string);
        const path = try boundedString(ctx, elements[0]);
        if (path.len == 0) return error.Unbound;
        const alias: ?skript.Sym = if (elements[1].typ == skript.builtins.type_nil)
            null
        else
            try planSymbol(ctx, elements[1]);
        if (alias) |name| try validateDestination(ctx, ns, &destinations, name);
        const referrals = try parseReferrals(referral_storage.allocator(), ctx, elements[2]);
        for (referrals) |referral| {
            try validateDestination(ctx, ns, &destinations, referral.local);
        }
        raw_specs[i] = .{ .path = path, .alias = alias, .referrals = referrals };
    }

    // Canonicalize before touching the registry. Equal paths share one load
    // entry, but each spec retains its own alias and selected names.
    for (raw_specs, 0..) |raw, i| {
        const canonical = try resolveUseCanonical(rt, proc, raw.path);
        var owner = i;
        for (specs[0..i], 0..) |previous, index| {
            try ctx.charge(.{ .work = 1 }, .native);
            if (std.mem.eql(u8, previous.canonical, canonical)) {
                owner = index;
                break;
            }
        }
        specs[i] = .{
            .canonical = canonical,
            .alias = raw.alias,
            .referrals = raw.referrals,
            .owner = owner,
        };
    }

    // A direct native reentry cannot wait for a module or publish a new one.
    // Completed cache hits may still bind aliases synchronously. Check every
    // path before any alias is written, without touching the caller's waits.
    if (!ctx.allow_suspend or ctx.native_reentry) {
        {
            rt.scheduler.mutex.lockUncancelable(rt.io);
            defer rt.scheduler.mutex.unlock(rt.io);
            for (specs, 0..) |*spec, i| {
                if (spec.owner != i) continue;
                const entry = rt.modules.findLocked(spec.canonical) orelse return error.Denied;
                switch (entry.status) {
                    .loaded => spec.loaded_ns = entry.ns,
                    .failed => return entry.err orelse error.InvalidCode,
                    .loading => return error.Denied,
                }
            }
            for (specs, 0..) |*spec, i| {
                if (spec.owner != i) spec.loaded_ns = specs[spec.owner].loaded_ns;
            }
        }
        try publishImportGroup(ctx, ns, specs);
        return .nil;
    }

    var prepared_count: usize = 0;
    var wait_count: usize = 0;
    {
        rt.scheduler.mutex.lockUncancelable(rt.io);
        defer rt.scheduler.mutex.unlock(rt.io);
        rt.scheduler.clearWaitEdgesLocked(proc);

        var first_err: ?Error = null;
        for (specs, 0..) |*spec, i| {
            if (spec.owner != i) continue;
            if (rt.modules.findLocked(spec.canonical)) |entry| {
                spec.entry = entry;
                switch (entry.status) {
                    .loaded => spec.loaded_ns = entry.ns,
                    .failed => {
                        if (first_err == null) first_err = entry.err orelse error.InvalidCode;
                    },
                    .loading => {
                        const target = entry.process orelse return error.InvalidCode;
                        if (target.completed.load(.acquire)) {
                            spec.loaded_ns = publishLoaded(rt, entry, target) catch |err| blk: {
                                if (first_err == null) first_err = err;
                                break :blk null;
                            };
                        } else {
                            wait_targets[wait_count] = target;
                            wait_count += 1;
                        }
                    },
                }
            } else {
                spec.is_miss = true;
                prepared_count += 1;
            }
        }
        if (first_err) |err| return err;

        for (wait_targets[0..wait_count]) |target| {
            if (try rt.scheduler.hasWaitPathLocked(ctx, target, proc)) {
                return error.CircularLoad;
            }
        }

        try rt.modules.entries.ensureUnusedCapacity(rt.static, prepared_count);
        for (specs, 0..) |*spec, i| {
            if (spec.owner != i or !spec.is_miss) continue;
            const entry = try rt.static.create(ModuleEntry);
            entry.* = .{ .path = spec.canonical };
            spec.entry = entry;
        }
        for (specs, 0..) |*spec, i| {
            if (spec.owner == i and spec.is_miss) {
                rt.modules.entries.appendAssumeCapacity(spec.entry.?);
            }
        }
        for (specs, 0..) |*spec, i| {
            if (spec.owner != i) {
                spec.entry = specs[spec.owner].entry;
                spec.loaded_ns = specs[spec.owner].loaded_ns;
            }
        }
    }

    // Read and create every new module before spawning any process. A failure
    // therefore cannot leave an earlier member queued with no registry owner.
    var prepared_index: usize = 0;
    for (specs, 0..) |spec, i| {
        if (spec.owner != i or !spec.is_miss) continue;
        const entry = spec.entry orelse return error.InvalidCode;
        const source = readModuleSource(rt, spec.canonical) catch |err| {
            failMisses(rt, specs, err);
            return err;
        };
        const module_ns = createModuleNamespace(rt) catch |err| {
            failMisses(rt, specs, err);
            return err;
        };
        prepared[prepared_index] = .{
            .entry = entry,
            .canonical = spec.canonical,
            .source = source,
            .namespace = module_ns,
        };
        prepared_index += 1;
    }

    for (prepared[0..prepared_index]) |module| {
        const mod_proc = rt.spawnEvalWithNsContext(
            ctx,
            module.source,
            module.namespace,
            module.canonical,
        ) catch |err| {
            failUnstartedMisses(rt, specs, err);
            return err;
        };
        rt.scheduler.mutex.lockUncancelable(rt.io);
        module.entry.process = mod_proc;
        rt.scheduler.mutex.unlock(rt.io);
    }

    {
        rt.scheduler.mutex.lockUncancelable(rt.io);
        defer rt.scheduler.mutex.unlock(rt.io);

        var first_err: ?Error = null;
        wait_count = 0;
        for (specs, 0..) |*spec, i| {
            if (spec.owner != i) continue;
            const entry = spec.entry orelse return error.InvalidCode;
            switch (entry.status) {
                .loaded => spec.loaded_ns = entry.ns,
                .failed => {
                    if (first_err == null) first_err = entry.err orelse error.InvalidCode;
                },
                .loading => {
                    const target = entry.process orelse return error.InvalidCode;
                    if (target.completed.load(.acquire)) {
                        spec.loaded_ns = publishLoaded(rt, entry, target) catch |err| blk: {
                            if (first_err == null) first_err = err;
                            break :blk null;
                        };
                    } else {
                        wait_targets[wait_count] = target;
                        wait_count += 1;
                    }
                },
            }
        }
        if (first_err) |err| return err;

        for (wait_targets[0..wait_count]) |target| {
            if (try rt.scheduler.hasWaitPathLocked(ctx, target, proc)) {
                return error.CircularLoad;
            }
        }
        try rt.scheduler.addWaitEdgesLocked(
            rt.static,
            proc,
            wait_targets[0..wait_count],
        );
        for (specs, 0..) |*spec, i| {
            if (spec.owner != i) spec.loaded_ns = specs[spec.owner].loaded_ns;
        }
        if (wait_count > 0) return error.WouldBlock;
    }

    try publishImportGroup(ctx, ns, specs);
    return .nil;
}

/// Reserve both maps and validate every source before inserting any caller
/// binding. The final two insertion loops cannot fail or suspend.
fn publishImportGroup(ctx: *EvalContext, ns: Value, specs: []const UseSpec) Error!void {
    const rt = ctx.runtime;
    const table = ns.obj.toRef().deref(skript.Namespace);
    const caller: *skript.HashMapNamespace = @ptrCast(@alignCast(table.data));
    var alias_count: usize = 0;
    var referral_count: usize = 0;
    for (specs) |spec| {
        const view = spec.loaded_ns orelse return error.InvalidCode;
        if (view.typ != skript.builtins.type_namespace) return error.InvalidCode;
        const exported = view.obj.toRef().deref(skript.Namespace);
        if (exported.get != skript.data.ExportNamespace.vtable.get) return error.InvalidCode;
        if (spec.alias != null) alias_count += 1;
        referral_count = std.math.add(usize, referral_count, spec.referrals.len) catch {
            return error.LimitExceeded;
        };
        for (spec.referrals) |referral| {
            try ctx.charge(.{ .work = 1 }, .native);
            if (!rt.nsContains(view, referral.public)) return error.Unbound;
            _ = try rt.nsGet(view, referral.public);
        }
    }
    try caller.bindings.ensureUnusedCapacity(@intCast(alias_count));
    try caller.imports.ensureUnusedCapacity(rt.static, @intCast(referral_count));
    for (specs) |spec| {
        const view = spec.loaded_ns.?;
        if (spec.alias) |alias| caller.bindings.putAssumeCapacityNoClobber(alias, view);
        for (spec.referrals) |referral| {
            caller.imports.putAssumeCapacityNoClobber(referral.local, .{
                .namespace = view,
                .name = referral.public,
            });
        }
    }
}

/// Publish an export-only live view after a module finishes successfully.
/// Caller holds the scheduler lock; failed declarations are memoized.
fn publishLoaded(rt: *Runtime, entry: *ModuleEntry, target: *Process) Error!Value {
    if (target.result.typ == skript.builtins.type_error) {
        const err = target.result.errorCode();
        entry.status = .failed;
        entry.err = err;
        return err;
    }
    const exposed = rt.moduleExportView(target) catch |err| {
        entry.status = .failed;
        entry.err = err;
        return err;
    };
    entry.ns = exposed;
    entry.status = .loaded;
    return exposed;
}

fn boundedString(ctx: *EvalContext, value: Value) Error![]const u8 {
    const bytes = try ctx.stringBytes(
        value.obj.toPtr([*:0]const u8),
        1024,
        .native,
    );
    return bytes;
}

fn fixedList(ctx: *EvalContext, input: Value, elements: *[3]Value) Error!usize {
    var cursor = input;
    var count: usize = 0;
    while (cursor.typ == skript.builtins.type_cons) {
        if (count == elements.len) return error.MalformedAst;
        try ctx.charge(.{ .work = 1 }, .native);
        const pair = cursor.obj.toRef().deref([2]Value);
        elements[count] = pair[0];
        count += 1;
        cursor = pair[1];
    }
    if (cursor.typ != skript.builtins.type_nil) return error.MalformedAst;
    return count;
}

fn planSymbol(ctx: *EvalContext, value: Value) Error!skript.Sym {
    if (value.typ != skript.builtins.type_symbol) return error.MalformedAst;
    const name = value.obj.toPtr(skript.Sym);
    if (name.*.len == 0) return error.MalformedAst;
    if (name.*.len > 1024) return error.Unsupported;
    if (name.*[0] == '@' or Runtime.isQualified(name)) return error.MalformedAst;
    try ctx.chargeWork(@intCast(name.*.len + 1), 1, .native);
    return name;
}

fn parseReferrals(
    allocator: std.mem.Allocator,
    ctx: *EvalContext,
    input: Value,
) Error![]const Referral {
    var cursor = input;
    var count: usize = 0;
    while (cursor.typ == skript.builtins.type_cons) {
        if (count == 1024) return error.LimitExceeded;
        try ctx.charge(.{ .work = 1 }, .native);
        count += 1;
        cursor = cursor.obj.toRef().deref([2]Value)[1];
    }
    if (cursor.typ != skript.builtins.type_nil) return error.MalformedAst;
    const referrals = try allocator.alloc(Referral, count);
    cursor = input;
    for (referrals) |*referral| {
        const pair = cursor.obj.toRef().deref([2]Value);
        var elements: [3]Value = undefined;
        if (try fixedList(ctx, pair[0], &elements) != 2) return error.MalformedAst;
        referral.* = .{
            .public = try planSymbol(ctx, elements[0]),
            .local = try planSymbol(ctx, elements[1]),
        };
        cursor = pair[1];
    }
    return referrals;
}

fn validateDestination(
    ctx: *EvalContext,
    ns: Value,
    destinations: *std.AutoHashMap(skript.Sym, void),
    name: skript.Sym,
) Error!void {
    const rt = ctx.runtime;
    if (Runtime.isSealedName(name) or destinations.contains(name) or
        rt.nsContains(rt.prelude_ns, name))
    {
        return error.NameConflict;
    }
    var cursor = ns;
    for (0..64) |_| {
        if (cursor.typ != skript.builtins.type_namespace) break;
        try ctx.charge(.{ .work = 1 }, .native);
        if (rt.nsContains(cursor, name)) return error.NameConflict;
        const table = cursor.obj.toRef().deref(skript.Namespace);
        cursor = table.parent(rt, table, cursor.obj);
    }
    if (cursor.typ == skript.builtins.type_namespace) return error.Unsupported;
    try destinations.put(name, {});
}

fn resolveUseCanonical(rt: *Runtime, proc: *Process, path: []const u8) Error![]const u8 {
    if (std.mem.endsWith(u8, path, ".pt")) {
        return resolveCanonical(rt, proc, path);
    }
    if (std.fs.path.isAbsolute(path)) {
        const with_ext = try std.mem.concat(rt.static, u8, &.{ path, ".pt" });
        if (std.Io.Dir.cwd().realPathFileAlloc(rt.io, with_ext, rt.static)) |canonical| {
            return canonical;
        } else |_| {}
        if (std.Io.Dir.cwd().realPathFileAlloc(rt.io, path, rt.static)) |canonical| {
            return canonical;
        } else |_| {}
        return error.Unbound;
    }
    return resolveModuleCanonical(rt, proc.module_path, path);
}

fn failMisses(rt: *Runtime, specs: []const UseSpec, err: Error) void {
    rt.scheduler.mutex.lockUncancelable(rt.io);
    defer rt.scheduler.mutex.unlock(rt.io);
    for (specs, 0..) |spec, i| {
        if (spec.owner != i or !spec.is_miss) continue;
        const entry = spec.entry orelse continue;
        entry.status = .failed;
        entry.err = err;
    }
}

fn failUnstartedMisses(rt: *Runtime, specs: []const UseSpec, err: Error) void {
    rt.scheduler.mutex.lockUncancelable(rt.io);
    defer rt.scheduler.mutex.unlock(rt.io);
    for (specs, 0..) |spec, i| {
        if (spec.owner != i or !spec.is_miss) continue;
        const entry = spec.entry orelse continue;
        if (entry.process != null) continue;
        entry.status = .failed;
        entry.err = err;
    }
}

fn requireTrustedConcrete(ctx: *EvalContext) Error!void {
    try ctx.check();
    if (ctx.mode != .concrete or ctx.execution != .trusted) return error.Denied;
    if (ctx.effects.state_read != .allow or ctx.effects.state_write != .allow or
        ctx.effects.io != .allow or ctx.effects.process != .allow or
        ctx.effects.module != .allow or ctx.effects.host != .allow or
        ctx.effects.unknown != .allow)
    {
        return error.Denied;
    }
}

pub fn resolveModuleCanonical(rt: *Runtime, importer_path: ?[]const u8, mod_text: []const u8) Error![]const u8 {
    if (mod_text.len == 0) return error.Unbound;
    var seg_iter = std.mem.splitScalar(u8, mod_text, '/');
    while (seg_iter.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) {
            return error.Unbound;
        }
    }
    const base = moduleBase(rt, importer_path);
    const joined_rel = if (base.len > 0)
        try std.fs.path.join(rt.static, &.{ base, mod_text })
    else
        mod_text;

    // Probe (a): <base>/<segs>.pt via realPathFileAlloc
    const file_with_ext = try std.mem.concat(rt.static, u8, &.{ joined_rel, ".pt" });
    if (std.Io.Dir.cwd().realPathFileAlloc(rt.io, file_with_ext, rt.static)) |canonical_file| {
        return canonical_file;
    } else |_| {}

    // Probe (b): <base>/<segs> via realPathFileAlloc + openDir succeeds -> folder module
    if (std.Io.Dir.cwd().realPathFileAlloc(rt.io, joined_rel, rt.static)) |canonical_dir| {
        if (std.Io.Dir.cwd().openDir(rt.io, canonical_dir, .{ .iterate = true })) |dir| {
            var d = dir;
            d.close(rt.io);
            return canonical_dir;
        } else |_| {}
    } else |_| {}

    return error.Unbound;
}

fn readModuleSource(rt: *Runtime, canonical: []const u8) Error![]const u8 {
    if (std.Io.Dir.cwd().openDir(rt.io, canonical, .{ .iterate = true })) |dir| {
        var d = dir;
        defer d.close(rt.io);
        var entries: std.ArrayList([]const u8) = .empty;
        var it = d.iterate();
        while (it.next(rt.io) catch |err| return intrin.mapFileError(err)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".pt")) {
                const name_copy = rt.static.dupe(u8, entry.name) catch return error.OutOfMemory;
                try entries.append(rt.static, name_copy);
            }
        }
        std.mem.sort([]const u8, entries.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        var contents: std.ArrayList([]const u8) = .empty;
        for (entries.items) |name| {
            const file_src = d.readFileAlloc(rt.io, name, rt.static, .unlimited) catch |err| {
                return intrin.mapFileError(err);
            };
            try contents.append(rt.static, file_src);
        }
        return std.mem.join(rt.static, "\n", contents.items) catch return error.OutOfMemory;
    } else |_| {
        return std.Io.Dir.cwd().readFileAlloc(rt.io, canonical, rt.static, .unlimited) catch |err| {
            return intrin.mapFileError(err);
        };
    }
}

/// Resolve a load path against the calling module's directory (or cwd for an
/// anonymous eval) and canonicalize it. Realpath is best-effort: when the
/// file exists it yields the canonical absolute path (the load-once identity
/// key); on ANY failure (missing file, platform limits) the joined path is
/// used as-is — the subsequent read then reports the real error.
fn resolveCanonical(rt: *Runtime, proc: *Process, path_arg: []const u8) Error![]const u8 {
    // An absolute argument is used verbatim — joining it onto the caller's
    // base would produce a nonsense path ("base//abs"). Relative args
    // resolve against the calling module's directory (cwd for anonymous
    // evals and stdin).
    if (std.fs.path.isAbsolute(path_arg)) {
        return std.Io.Dir.cwd().realPathFileAlloc(rt.io, path_arg, rt.static) catch path_arg;
    }
    const base = moduleBase(rt, proc.module_path);
    const joined = try std.fs.path.join(rt.static, &.{ base, path_arg });
    return std.Io.Dir.cwd().realPathFileAlloc(rt.io, joined, rt.static) catch joined;
}

fn moduleBase(rt: *Runtime, importer_path: ?[]const u8) []const u8 {
    const path = importer_path orelse return "";
    if (std.Io.Dir.cwd().openDir(rt.io, path, .{})) |dir| {
        var opened = dir;
        opened.close(rt.io);
        return path;
    } else |_| {}
    return std.fs.path.dirname(path) orelse "";
}

/// A module runs in a private namespace whose parent is the prelude snapshot.
/// Its own definitions shadow prelude names and remain implicitly visible to
/// qualified lookups. The importer never becomes the module's parent.
fn createModuleNamespace(rt: *Runtime) Error!Value {
    const ns_ref = try rt.store.create(skript.Namespace);
    const ns_obj = ns_ref.toObject();
    rt.store.store(skript.Namespace, ns_ref.deref(skript.Namespace), skript.HashMapNamespace.vtable);
    const hashmap = try rt.static.create(skript.HashMapNamespace);
    ns_ref.deref(skript.Namespace).data = @ptrCast(hashmap);
    hashmap.* = try skript.HashMapNamespace.init(rt.static, rt.prelude_ns);
    return Value.namespace(ns_obj);
}

/// Mark an entry failed under the scheduler mutex: a module that fails to
/// read, compile, or spawn stays failed, and later loads surface the same
/// error instead of dereferencing the null process of the load-once barrier.
fn failEntry(rt: *Runtime, entry: *ModuleEntry, err: skript.Error) void {
    rt.scheduler.mutex.lockUncancelable(rt.io);
    defer rt.scheduler.mutex.unlock(rt.io);
    entry.status = .failed;
    entry.err = err;
}

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
    }
}
const UseRefer = struct {
    public: []const u8,
    local: []const u8,
};
const UseInput = struct {
    path: []const u8,
    alias: ?[]const u8,
    refs: []const UseRefer = &.{},
};

const ModuleTestDir = struct {
    dir: []u8,
    allocator: std.mem.Allocator,
    var sequence: std.atomic.Value(u32) = .init(0);

    fn init(allocator: std.mem.Allocator, io: std.Io) !ModuleTestDir {
        const id = sequence.fetchAdd(1, .monotonic);
        const now = std.Io.Clock.awake.now(io).nanoseconds;
        const dir = try std.fmt.allocPrint(allocator, "/tmp/skript-module-contract-{d}-{d}", .{ now, id });
        errdefer allocator.free(dir);
        try std.Io.Dir.cwd().createDirPath(io, dir);
        return .{ .dir = dir, .allocator = allocator };
    }

    fn deinit(self: *ModuleTestDir, io: std.Io) void {
        std.Io.Dir.cwd().deleteTree(io, self.dir) catch |err| @panic(@errorName(err));
        self.allocator.free(self.dir);
        self.* = undefined;
    }

    fn path(self: *ModuleTestDir, name: []const u8) ![]u8 {
        return std.fs.path.join(self.allocator, &.{ self.dir, name });
    }

    fn write(self: *ModuleTestDir, io: std.Io, name: []const u8, source: []const u8) ![:0]u8 {
        const full_path = try self.path(name);
        defer self.allocator.free(full_path);
        if (std.fs.path.dirname(full_path)) |parent| {
            if (parent.len > self.dir.len) try std.Io.Dir.cwd().createDirPath(io, parent);
        }
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = full_path, .data = source });
        return std.Io.Dir.cwd().realPathFileAlloc(io, full_path, self.allocator);
    }
};

fn useMultiSource(allocator: std.mem.Allocator, specs: []const UseInput) ![]u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(allocator);
    try source.appendSlice(allocator, "(@use-multi");
    for (specs) |spec| {
        try source.appendSlice(allocator, " '(\"");
        for (spec.path) |ch| {
            if (ch == '\\') try source.append(allocator, '\\');
            try source.append(allocator, ch);
        }
        try source.appendSlice(allocator, "\" ");
        if (spec.alias) |alias| {
            try source.appendSlice(allocator, alias);
        } else {
            try source.appendSlice(allocator, "()");
        }
        try source.appendSlice(allocator, " (");
        for (spec.refs, 0..) |ref, index| {
            if (index != 0) try source.append(allocator, ' ');
            try source.appendSlice(allocator, "(");
            try source.appendSlice(allocator, ref.public);
            try source.append(allocator, ' ');
            try source.appendSlice(allocator, ref.local);
            try source.append(allocator, ')');
        }
        try source.appendSlice(allocator, "))");
    }
    try source.append(allocator, ')');
    return source.toOwnedSlice(allocator);
}

fn runUseMulti(rt: *Runtime, source: []const u8, module_path: []const u8) Error!Value {
    const process = try rt.spawnEvalWithNs(source, rt.root_ns, module_path);
    return rt.awaitProcess(process);
}

test "use-multi reuses one canonical namespace and keeps each alias" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var temp = try ModuleTestDir.init(std.testing.allocator, rt.io);
    defer temp.deinit(rt.io);

    const path = try temp.write(rt.io, "library.pt", "(def value 42) (export value)");
    defer std.testing.allocator.free(path);
    const main_path = try temp.path("main.pt");
    defer std.testing.allocator.free(main_path);

    const first_source = try useMultiSource(std.testing.allocator, &.{
        .{ .path = path, .alias = "first" },
        .{ .path = path, .alias = "second" },
    });
    defer std.testing.allocator.free(first_source);
    try std.testing.expectEqual(Value.nil, try runUseMulti(rt, first_source, main_path));

    const first = try rt.nsGet(rt.root_ns, try rt.store.getsym("first"));
    const second = try rt.nsGet(rt.root_ns, try rt.store.getsym("second"));
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(Value.i64(42), try rt.nsGet(first, try rt.store.getsym("value")));

    const third_source = try useMultiSource(std.testing.allocator, &.{
        .{ .path = path, .alias = "third" },
    });
    defer std.testing.allocator.free(third_source);
    try std.testing.expectEqual(Value.nil, try runUseMulti(rt, third_source, main_path));
    const third = try rt.nsGet(rt.root_ns, try rt.store.getsym("third"));
    try std.testing.expectEqual(first, third);

    rt.scheduler.mutex.lockUncancelable(rt.io);
    defer rt.scheduler.mutex.unlock(rt.io);
    const entry = rt.modules.findLocked(path) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Status.loaded, entry.status);
    var module_processes: usize = 0;
    for (rt.scheduler.processes.items) |process| {
        if (process.module_path) |loaded_path| {
            if (std.mem.eql(u8, loaded_path, path)) module_processes += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), module_processes);
}

test "use-multi bounds path and alias scans and rejects bad aliases before registry writes" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var temp = try ModuleTestDir.init(std.testing.allocator, rt.io);
    defer temp.deinit(rt.io);

    const path = try temp.write(rt.io, "library.pt", "(def value 42) (export value)");
    defer std.testing.allocator.free(path);
    const main_path = try temp.path("main.pt");
    defer std.testing.allocator.free(main_path);

    const long_path = try std.testing.allocator.alloc(u8, 1025);
    defer std.testing.allocator.free(long_path);
    @memset(long_path, 'p');
    const path_source = try useMultiSource(std.testing.allocator, &.{
        .{ .path = long_path, .alias = "too-long-path" },
    });
    defer std.testing.allocator.free(path_source);
    const path_process = try rt.spawnEvalWithNs(path_source, rt.root_ns, main_path);
    try std.testing.expectError(error.Unsupported, rt.awaitProcess(path_process));

    const long_alias = try std.testing.allocator.alloc(u8, 1025);
    defer std.testing.allocator.free(long_alias);
    @memset(long_alias, 'a');
    const alias_source = try useMultiSource(std.testing.allocator, &.{
        .{ .path = path, .alias = long_alias },
    });
    defer std.testing.allocator.free(alias_source);
    const alias_process = try rt.spawnEvalWithNs(alias_source, rt.root_ns, main_path);
    try std.testing.expectError(error.Unsupported, rt.awaitProcess(alias_process));

    const malformed_source = try useMultiSource(std.testing.allocator, &.{
        .{ .path = path, .alias = "bad/alias" },
    });
    defer std.testing.allocator.free(malformed_source);
    const malformed_process = try rt.spawnEvalWithNs(malformed_source, rt.root_ns, main_path);
    try std.testing.expectError(error.MalformedAst, rt.awaitProcess(malformed_process));

    const missing = try temp.path("missing.pt");
    defer std.testing.allocator.free(missing);
    const duplicate_source = try useMultiSource(std.testing.allocator, &.{
        .{ .path = missing, .alias = "same" },
        .{ .path = path, .alias = "same" },
    });
    defer std.testing.allocator.free(duplicate_source);
    const duplicate_process = try rt.spawnEvalWithNs(duplicate_source, rt.root_ns, main_path);
    try std.testing.expectError(error.NameConflict, rt.awaitProcess(duplicate_process));

    rt.scheduler.mutex.lockUncancelable(rt.io);
    defer rt.scheduler.mutex.unlock(rt.io);
    try std.testing.expectEqual(@as(usize, 0), rt.modules.entries.items.len);
}

test "use-multi accepts a 1024-byte alias and memoizes missing modules without partial groups" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var temp = try ModuleTestDir.init(std.testing.allocator, rt.io);
    defer temp.deinit(rt.io);

    const path = try temp.write(rt.io, "library.pt", "(def value 42) (export value)");
    defer std.testing.allocator.free(path);
    const main_path = try temp.path("main.pt");
    defer std.testing.allocator.free(main_path);

    const max_alias = try std.testing.allocator.alloc(u8, 1024);
    defer std.testing.allocator.free(max_alias);
    @memset(max_alias, 'a');
    const boundary_source = try useMultiSource(std.testing.allocator, &.{
        .{ .path = path, .alias = max_alias },
    });
    defer std.testing.allocator.free(boundary_source);
    try std.testing.expectEqual(Value.nil, try runUseMulti(rt, boundary_source, main_path));
    const boundary_ns = try rt.nsGet(rt.root_ns, try rt.store.getsym(max_alias));
    try std.testing.expectEqual(Value.i64(42), try rt.nsGet(boundary_ns, try rt.store.getsym("value")));

    const group_good = try temp.write(rt.io, "group-good.pt", "(def value 5) (export value)");
    defer std.testing.allocator.free(group_good);
    const missing = try temp.path("missing.pt");
    defer std.testing.allocator.free(missing);
    const partial_source = try useMultiSource(std.testing.allocator, &.{
        .{ .path = group_good, .alias = "good-alias" },
        .{ .path = missing, .alias = "missing-alias" },
    });
    defer std.testing.allocator.free(partial_source);
    const first_process = try rt.spawnEvalWithNs(partial_source, rt.root_ns, main_path);
    try std.testing.expectError(error.Unbound, rt.awaitProcess(first_process));
    try std.testing.expectError(error.Unbound, rt.nsGet(rt.root_ns, try rt.store.getsym("good-alias")));

    rt.scheduler.mutex.lockUncancelable(rt.io);
    {
        defer rt.scheduler.mutex.unlock(rt.io);
        const cached = rt.modules.findLocked(missing) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(Status.failed, cached.status);
        try std.testing.expectEqual(@as(?Error, error.Unbound), cached.err);
        try std.testing.expect(cached.process == null);
    }

    const created = try temp.write(rt.io, "missing.pt", "(def value 7) (export value)");
    defer std.testing.allocator.free(created);
    const retry = try rt.spawnEvalWithNs(partial_source, rt.root_ns, main_path);
    try std.testing.expectError(error.Unbound, rt.awaitProcess(retry));

    rt.scheduler.mutex.lockUncancelable(rt.io);
    defer rt.scheduler.mutex.unlock(rt.io);
    try std.testing.expectEqual(@as(usize, 3), rt.modules.entries.items.len);
    for (rt.modules.entries.items) |entry| {
        if (std.mem.eql(u8, entry.path, path)) {
            try std.testing.expectEqual(Status.loaded, entry.status);
        } else {
            try std.testing.expectEqual(Status.failed, entry.status);
            try std.testing.expect(entry.process == null);
        }
    }
}

test "module exports expose only local names while private code can read the prelude" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var temp = try ModuleTestDir.init(std.testing.allocator, rt.io);
    defer temp.deinit(rt.io);

    const path = try temp.write(
        rt.io,
        "shadow.pt",
        "(def prelude-u64 u64) (def prelude-type type) (def u64 41) " ++
            "(def local-shadow u64) (export u64 prelude-u64 prelude-type local-shadow)",
    );
    defer std.testing.allocator.free(path);
    const main_path = try temp.path("main.pt");
    defer std.testing.allocator.free(main_path);
    const use_source = try useMultiSource(std.testing.allocator, &.{
        .{ .path = path, .alias = "shadow" },
    });
    defer std.testing.allocator.free(use_source);
    const source = try std.fmt.allocPrint(
        std.testing.allocator,
        "(def u64 99) {s} shadow/u64",
        .{use_source},
    );
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(Value.i64(41), try runUseMulti(rt, source, main_path));

    const prelude_lookup = try rt.spawnEvalWithNs("shadow/type", rt.root_ns, main_path);
    try std.testing.expectError(error.Unbound, rt.awaitProcess(prelude_lookup));
    const u64_sym = try rt.store.getsym("u64");
    const module_ns = try rt.nsGet(rt.root_ns, try rt.store.getsym("shadow"));
    const prelude_u64 = try rt.nsGet(rt.prelude_ns, u64_sym);
    try std.testing.expectEqual(Value.i64(99), try rt.nsGet(rt.root_ns, u64_sym));
    try std.testing.expectEqual(Value.i64(41), try rt.nsGet(module_ns, u64_sym));
    try std.testing.expectEqual(prelude_u64, try rt.nsGet(module_ns, try rt.store.getsym("prelude-u64")));
    try std.testing.expectEqual(Value.i64(41), try rt.nsGet(module_ns, try rt.store.getsym("local-shadow")));
    try std.testing.expectEqual(
        try rt.nsGet(rt.prelude_ns, try rt.store.getsym("type")),
        try rt.nsGet(module_ns, try rt.store.getsym("prelude-type")),
    );
    try std.testing.expectError(error.Unbound, rt.nsGet(module_ns, try rt.store.getsym("type")));
}

test "use-multi detects cycles through every group edge and folder aliases" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var temp = try ModuleTestDir.init(std.testing.allocator, rt.io);
    defer temp.deinit(rt.io);

    const a_path = try temp.write(rt.io, "a.pt", "(use (c :as cycle-folder) (b :as blocked-b))");
    defer std.testing.allocator.free(a_path);
    const b_path = try temp.write(rt.io, "b.pt", "(receive)");
    defer std.testing.allocator.free(b_path);
    // A folder resolves public `use` paths from c/, so a bare `a` would name c/a.pt.
    // Use the same canonical file plan the binder emits for the sibling module.
    const c_source = try useMultiSource(std.testing.allocator, &.{
        .{ .path = a_path, .alias = "cycle-a" },
    });
    defer std.testing.allocator.free(c_source);
    const c_file = try temp.write(rt.io, "c/part.pt", c_source);
    defer std.testing.allocator.free(c_file);
    const c_path = try temp.path("c");
    defer std.testing.allocator.free(c_path);
    const main_path = try temp.path("main.pt");
    defer std.testing.allocator.free(main_path);

    const source = try useMultiSource(std.testing.allocator, &.{
        .{ .path = a_path, .alias = "a" },
        .{ .path = b_path, .alias = "b" },
        .{ .path = c_path, .alias = "c" },
    });
    defer std.testing.allocator.free(source);
    const top = try rt.spawnEvalWithNs(source, rt.root_ns, main_path);
    try std.testing.expectError(error.CircularLoad, rt.awaitProcess(top));

    rt.scheduler.mutex.lockUncancelable(rt.io);
    defer rt.scheduler.mutex.unlock(rt.io);
    for (rt.scheduler.processes.items) |process| {
        try std.testing.expectEqual(@as(usize, 0), process.waiting_on.items.len);
        try std.testing.expectEqual(@as(usize, 0), process.waiters.items.len);
    }
}

test "use-multi memoizes a module deleted after path resolution" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var temp = try ModuleTestDir.init(std.testing.allocator, rt.io);
    defer temp.deinit(rt.io);

    const path = try temp.write(rt.io, "deleted/library.pt", "(def value 42)");
    defer std.testing.allocator.free(path);
    const deleted_dir = try temp.path("deleted");
    defer std.testing.allocator.free(deleted_dir);
    const main_path = try temp.path("main.pt");
    defer std.testing.allocator.free(main_path);
    const source = try useMultiSource(std.testing.allocator, &.{
        .{ .path = path, .alias = "deleted" },
    });
    defer std.testing.allocator.free(source);

    try std.Io.Dir.cwd().deleteTree(rt.io, deleted_dir);
    const process = try rt.spawnEvalWithNs(source, rt.root_ns, main_path);
    try std.testing.expectError(error.Unbound, rt.awaitProcess(process));

    rt.scheduler.mutex.lockUncancelable(rt.io);
    defer rt.scheduler.mutex.unlock(rt.io);
    const entry = rt.modules.findLocked(path) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Status.failed, entry.status);
    try std.testing.expectEqual(@as(?Error, error.Unbound), entry.err);
    try std.testing.expect(entry.process == null);
}

test "selected import reads live renamed public cells and remains read-only" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var temp = try ModuleTestDir.init(std.testing.allocator, rt.io);
    defer temp.deinit(rt.io);
    const path = try temp.write(
        rt.io,
        "source.pt",
        "(def private 1) (defn (change n) (set! private n)) " ++
            "(@module-export '(private public) '(change change))",
    );
    defer std.testing.allocator.free(path);
    const main_path = try temp.path("main.pt");
    defer std.testing.allocator.free(main_path);
    const source = try useMultiSource(std.testing.allocator, &.{
        .{ .path = path, .alias = "lib", .refs = &.{.{ .public = "public", .local = "selected" }} },
    });
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(Value.nil, try runUseMulti(rt, source, main_path));
    const alias = try rt.nsGet(rt.root_ns, try rt.store.getsym("lib"));
    try std.testing.expectEqual(Value.i64(1), try rt.nsGet(alias, try rt.store.getsym("public")));
    try std.testing.expectError(error.Unbound, rt.nsGet(alias, try rt.store.getsym("private")));
    try std.testing.expectEqual(Value.i64(1), try rt.nsGet(rt.root_ns, try rt.store.getsym("selected")));
    const change = try rt.nsGet(alias, try rt.store.getsym("change"));
    _ = try rt.apply(rt.root_ns, change, &.{.i64(9)});
    try std.testing.expectEqual(Value.i64(9), try rt.nsGet(rt.root_ns, try rt.store.getsym("selected")));
    try std.testing.expectEqual(Value.i64(9), try rt.nsGet(alias, try rt.store.getsym("public")));
    const selected = try rt.store.getsym("selected");
    try std.testing.expectError(error.Denied, rt.nsSet(rt.root_ns, selected, .i64(4)));
    try std.testing.expectError(error.Denied, rt.nsBind(rt.root_ns, selected, .i64(4)));
    try std.testing.expectError(error.Denied, rt.nsAssign(rt.root_ns, selected, .i64(4)));
    try std.testing.expectError(error.Denied, rt.nsUnbind(rt.root_ns, selected));
}

test "module exports live reexports through an imported public alias" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var temp = try ModuleTestDir.init(std.testing.allocator, rt.io);
    defer temp.deinit(rt.io);
    const base = try temp.write(
        rt.io,
        "base.pt",
        "(def value 3) (defn (change n) (set! value n)) " ++
            "(@module-export '(value visible) '(change change))",
    );
    defer std.testing.allocator.free(base);
    const relay = try temp.write(
        rt.io,
        "relay.pt",
        "(use (base :as origin)) (@module-export '(origin visible renamed))",
    );
    defer std.testing.allocator.free(relay);
    const main_path = try temp.path("main.pt");
    defer std.testing.allocator.free(main_path);
    const source = try useMultiSource(std.testing.allocator, &.{
        .{ .path = relay, .alias = "relay", .refs = &.{.{ .public = "renamed", .local = "picked" }} },
        .{ .path = base, .alias = "base" },
    });
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(Value.nil, try runUseMulti(rt, source, main_path));
    const relay_ns = try rt.nsGet(rt.root_ns, try rt.store.getsym("relay"));
    const base_ns = try rt.nsGet(rt.root_ns, try rt.store.getsym("base"));
    try std.testing.expectEqual(Value.i64(3), try rt.nsGet(relay_ns, try rt.store.getsym("renamed")));
    const change = try rt.nsGet(base_ns, try rt.store.getsym("change"));
    _ = try rt.apply(rt.root_ns, change, &.{.i64(19)});
    try std.testing.expectEqual(Value.i64(19), try rt.nsGet(relay_ns, try rt.store.getsym("renamed")));
    try std.testing.expectEqual(Value.i64(19), try rt.nsGet(rt.root_ns, try rt.store.getsym("picked")));
    try std.testing.expectError(error.Unbound, rt.nsGet(relay_ns, try rt.store.getsym("visible")));
    try std.testing.expectError(error.Denied, rt.nsSet(relay_ns, try rt.store.getsym("renamed"), .i64(1)));
}

test "use-multi rejects all destination conflicts before publishing the group" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var temp = try ModuleTestDir.init(std.testing.allocator, rt.io);
    defer temp.deinit(rt.io);
    const path = try temp.write(rt.io, "first.pt", "(def x 8) (export x)");
    defer std.testing.allocator.free(path);
    const missing_path = try temp.path("missing.pt");
    defer std.testing.allocator.free(missing_path);
    const main_path = try temp.path("main.pt");
    defer std.testing.allocator.free(main_path);

    const same_group = try useMultiSource(std.testing.allocator, &.{
        .{ .path = path, .alias = "first", .refs = &.{.{ .public = "x", .local = "same" }} },
        .{ .path = missing_path, .alias = "same" },
    });
    defer std.testing.allocator.free(same_group);
    try std.testing.expectError(error.NameConflict, runUseMulti(rt, same_group, main_path));
    try std.testing.expectError(error.Unbound, rt.nsGet(rt.root_ns, try rt.store.getsym("first")));

    try rt.nsBind(rt.root_ns, try rt.store.getsym("taken"), .i64(12));
    const preexisting = try useMultiSource(std.testing.allocator, &.{
        .{ .path = path, .alias = "first", .refs = &.{.{ .public = "x", .local = "taken" }} },
    });
    defer std.testing.allocator.free(preexisting);
    try std.testing.expectError(error.NameConflict, runUseMulti(rt, preexisting, main_path));
    try std.testing.expectEqual(Value.i64(12), try rt.nsGet(rt.root_ns, try rt.store.getsym("taken")));
    try std.testing.expectError(error.Unbound, rt.nsGet(rt.root_ns, try rt.store.getsym("first")));

    const sealed = try useMultiSource(std.testing.allocator, &.{
        .{ .path = path, .alias = "first", .refs = &.{.{ .public = "x", .local = "i64" }} },
    });
    defer std.testing.allocator.free(sealed);
    try std.testing.expectError(error.NameConflict, runUseMulti(rt, sealed, main_path));
    const prelude = try useMultiSource(std.testing.allocator, &.{
        .{ .path = path, .alias = "first", .refs = &.{.{ .public = "x", .local = "type" }} },
    });
    defer std.testing.allocator.free(prelude);
    try std.testing.expectError(error.NameConflict, runUseMulti(rt, prelude, main_path));
    try std.testing.expectError(error.Unbound, rt.nsGet(rt.root_ns, try rt.store.getsym("first")));
}

test "unavailable selected export leaves the caller untouched after loading its sibling" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var temp = try ModuleTestDir.init(std.testing.allocator, rt.io);
    defer temp.deinit(rt.io);
    const first = try temp.write(rt.io, "first.pt", "(def x 8) (export x)");
    defer std.testing.allocator.free(first);
    const second = try temp.write(rt.io, "second.pt", "(def y 9) (export y)");
    defer std.testing.allocator.free(second);
    const main_path = try temp.path("main.pt");
    defer std.testing.allocator.free(main_path);
    const source = try useMultiSource(std.testing.allocator, &.{
        .{ .path = first, .alias = "first", .refs = &.{.{ .public = "x", .local = "first-x" }} },
        .{ .path = second, .alias = "second", .refs = &.{.{ .public = "missing", .local = "missing" }} },
    });
    defer std.testing.allocator.free(source);
    try std.testing.expectError(error.Unbound, runUseMulti(rt, source, main_path));
    try std.testing.expectError(error.Unbound, rt.nsGet(rt.root_ns, try rt.store.getsym("first")));
    try std.testing.expectError(error.Unbound, rt.nsGet(rt.root_ns, try rt.store.getsym("first-x")));
    try std.testing.expectError(error.Unbound, rt.nsGet(rt.root_ns, try rt.store.getsym("second")));
    const changed = try temp.write(rt.io, "first.pt", "(def x 999) (export x)");
    defer std.testing.allocator.free(changed);
    const retry = try useMultiSource(std.testing.allocator, &.{.{ .path = first, .alias = "loaded" }});
    defer std.testing.allocator.free(retry);
    try std.testing.expectEqual(Value.nil, try runUseMulti(rt, retry, main_path));
    try std.testing.expectEqual(Value.i64(8), try rt.nsGet(
        try rt.nsGet(rt.root_ns, try rt.store.getsym("loaded")),
        try rt.store.getsym("x"),
    ));
}

test "folder module sees sibling paths and reads only immediate sorted regular pt files" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var temp = try ModuleTestDir.init(std.testing.allocator, rt.io);
    defer temp.deinit(rt.io);
    const child = try temp.write(rt.io, "pack/folder/child/part.pt", "(def value 2) (export value)");
    defer std.testing.allocator.free(child);
    const first = try temp.write(rt.io, "pack/folder/z.pt", "(def result (+ child/value base)) (export result)");
    defer std.testing.allocator.free(first);
    const second = try temp.write(rt.io, "pack/folder/a.pt", "(use (child :as child)) (def base 40)");
    defer std.testing.allocator.free(second);
    const nested = try temp.write(rt.io, "pack/folder/nested/ignore.pt", "(raise 0)");
    defer std.testing.allocator.free(nested);
    const pt_directory_child = try temp.write(rt.io, "pack/folder/skip.pt/nested.pt", "(raise 0)");
    defer std.testing.allocator.free(pt_directory_child);
    const folder = try temp.path("pack/folder");
    defer std.testing.allocator.free(folder);
    const main_path = try temp.path("main.pt");
    defer std.testing.allocator.free(main_path);
    const source = try useMultiSource(std.testing.allocator, &.{.{ .path = folder, .alias = "folder" }});
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(Value.nil, try runUseMulti(rt, source, main_path));
    const view = try rt.nsGet(rt.root_ns, try rt.store.getsym("folder"));
    try std.testing.expectEqual(Value.i64(42), try rt.nsGet(view, try rt.store.getsym("result")));
}

test "file module takes precedence over folder module of the same name" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var temp = try ModuleTestDir.init(std.testing.allocator, rt.io);
    defer temp.deinit(rt.io);
    const file = try temp.write(rt.io, "same.pt", "(def value 31) (export value)");
    defer std.testing.allocator.free(file);
    const folder_file = try temp.write(rt.io, "same/part.pt", "(def value 99) (export value)");
    defer std.testing.allocator.free(folder_file);
    const main_path = try temp.path("main.pt");
    defer std.testing.allocator.free(main_path);
    const source = try useMultiSource(std.testing.allocator, &.{.{ .path = "same", .alias = "same" }});
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(Value.nil, try runUseMulti(rt, source, main_path));
    try std.testing.expectEqual(Value.i64(31), try rt.nsGet(
        try rt.nsGet(rt.root_ns, try rt.store.getsym("same")),
        try rt.store.getsym("value"),
    ));
}

test "export declarations resolve later local definitions at module completion" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var temp = try ModuleTestDir.init(std.testing.allocator, rt.io);
    defer temp.deinit(rt.io);
    const path = try temp.write(rt.io, "late.pt", "(@module-export '(later public)) (def later 27)");
    defer std.testing.allocator.free(path);
    const main_path = try temp.path("main.pt");
    defer std.testing.allocator.free(main_path);
    const source = try useMultiSource(std.testing.allocator, &.{.{ .path = path, .alias = "late" }});
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(Value.nil, try runUseMulti(rt, source, main_path));
    const view = try rt.nsGet(rt.root_ns, try rt.store.getsym("late"));
    try std.testing.expectEqual(Value.i64(27), try rt.nsGet(view, try rt.store.getsym("public")));
    try std.testing.expectError(error.Unbound, rt.nsGet(view, try rt.store.getsym("later")));
}

test "unresolved export source and duplicate public names fail without caller publication" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var temp = try ModuleTestDir.init(std.testing.allocator, rt.io);
    defer temp.deinit(rt.io);
    const missing = try temp.write(rt.io, "missing.pt", "(@module-export '(absent public))");
    defer std.testing.allocator.free(missing);
    const duplicate = try temp.write(
        rt.io,
        "duplicate.pt",
        "(@module-export '(first public) '(second public)) (def first 1) (def second 2)",
    );
    defer std.testing.allocator.free(duplicate);
    const main_path = try temp.path("main.pt");
    defer std.testing.allocator.free(main_path);
    const missing_source = try useMultiSource(std.testing.allocator, &.{
        .{ .path = missing, .alias = "not-published" },
    });
    defer std.testing.allocator.free(missing_source);
    try std.testing.expectError(error.Unbound, runUseMulti(rt, missing_source, main_path));
    try std.testing.expectError(
        error.Unbound,
        rt.nsGet(rt.root_ns, try rt.store.getsym("not-published")),
    );
    const duplicate_source = try useMultiSource(std.testing.allocator, &.{
        .{ .path = duplicate, .alias = "also-not-published" },
    });
    defer std.testing.allocator.free(duplicate_source);
    try std.testing.expectError(error.NameConflict, runUseMulti(rt, duplicate_source, main_path));
    try std.testing.expectError(
        error.Unbound,
        rt.nsGet(rt.root_ns, try rt.store.getsym("also-not-published")),
    );
}

test "selected-only use plan binds no implicit namespace alias" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var temp = try ModuleTestDir.init(std.testing.allocator, rt.io);
    defer temp.deinit(rt.io);
    const path = try temp.write(rt.io, "library.pt", "(def value 14) (export value)");
    defer std.testing.allocator.free(path);
    const main_path = try temp.path("main.pt");
    defer std.testing.allocator.free(main_path);
    const source = try useMultiSource(std.testing.allocator, &.{
        .{ .path = path, .alias = null, .refs = &.{.{ .public = "value", .local = "selected" }} },
    });
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(Value.nil, try runUseMulti(rt, source, main_path));
    try std.testing.expectEqual(Value.i64(14), try rt.nsGet(rt.root_ns, try rt.store.getsym("selected")));
    try std.testing.expectError(error.Unbound, rt.nsGet(rt.root_ns, try rt.store.getsym("library")));
}
