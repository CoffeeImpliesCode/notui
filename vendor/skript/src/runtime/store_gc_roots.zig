const std = @import("std");
const skript = @import("../root.zig");
const Runtime = @import("../Runtime.zig");
const Store = skript.Store;
const SourceUnit = @import("../SourceUnit.zig");
const Code = @import("../code.zig");
const Value = skript.Value;
const Object = skript.Object;
const EvalContext = skript.EvalContext;
const intrin = skript.intrinsics;
const FnTableEntry = Runtime.FnTableEntry;
const Fiber = Runtime.Fiber;
const FrameReg = Runtime.FrameReg;
const frame_size = Runtime.frame_size;
const SourceRoots = std.AutoHashMapUnmanaged(*const SourceUnit, void);

fn traceSourceUnit(
    visitor: *Store.MarkVisitor,
    seen: *SourceRoots,
    source: SourceUnit.Ref,
) anyerror!void {
    const unit = source.unit orelse return;
    const result = try seen.getOrPut(visitor.store.backingAllocator(), unit);
    if (result.found_existing) return;
    try visitor.visitValue(unit.datum);
    for (unit.nodes) |node| try visitor.visitValue(node.datum);
}

fn traceCode(
    visitor: *Store.MarkVisitor,
    seen: *SourceRoots,
    code: *const Code.Code,
) anyerror!void {
    for (code.functions) |function| {
        try visitor.visitValue(function.source_value);
        try visitor.visitValue(function.arglist);
        try visitor.visitValue(function.body);
        try traceSourceUnit(visitor, seen, function.source);
    }
    for (code.bindings) |binding| try traceSourceUnit(visitor, seen, binding.source);
    for (code.globals) |global| try traceSourceUnit(visitor, seen, global.source);
    for (code.nodes) |node| {
        try traceSourceUnit(visitor, seen, node.source);
        switch (node.operation) {
            .literal, .quote => |value| try visitor.visitValue(value),
            .arithmetic => |arithmetic| try visitor.visitValue(arithmetic.expected_callee),
            .local_read,
            .global_read,
            .global_write,
            .primitive_call,
            .dynamic_call,
            .direct_call,
            .make_closure,
            .try_begin,
            .try_end,
            .ns_push,
            .ns_pop,
            => {},
        }
    }
}

fn traceFunctionTable(
    visitor: *Store.MarkVisitor,
    seen: *SourceRoots,
    functions: []const FnTableEntry,
) anyerror!void {
    for (functions) |function| {
        try visitor.visitValue(function.source);
        try visitor.visitValue(function.body);
        try traceSourceUnit(visitor, seen, function.source_ref);
        for (function.constants) |value| try visitor.visitValue(value);
    }
}

fn traceFiber(visitor: *Store.MarkVisitor, seen: *SourceRoots, fiber: *const Fiber) anyerror!void {
    try visitor.visitValue(fiber.ns);
    try visitor.visitValue(fiber.raised);
    try visitor.visitValue(fiber.pending_error);
    if (fiber.pending_apply) |*pending| {
        try visitor.visitValue(pending.target);
        for (pending.args()) |argument| try visitor.visitValue(argument);
    }
    if (fiber.current_closure) |closure| try visitor.visitAddress(@intFromPtr(closure));
    for (fiber.consts) |value| try visitor.visitValue(value);
    try traceFunctionTable(visitor, seen, fiber.fns);
    for (fiber.exn_stack.items) |frame| {
        try visitor.visitValue(frame.ns);
        if (frame.current_closure) |closure| try visitor.visitAddress(@intFromPtr(closure));
        for (frame.consts) |value| try visitor.visitValue(value);
        try traceFunctionTable(visitor, seen, frame.fns);
    }

    var fp = fiber.fp;
    var nregs: usize = fiber.activeNregs();
    while (true) {
        if (fp > fiber.stack.len or frame_size > fiber.stack.len - fp) return error.InvalidRef;
        const register_start = fp + frame_size;
        if (nregs > (fiber.stack.len - register_start) / 2) return error.InvalidRef;
        for (0..nregs) |index| {
            const slot = register_start + index * 2;
            const typ = fiber.stack[slot];
            if (typ != .null) {
                try visitor.visitValue(.init(typ, fiber.stack[slot + 1]));
            }
        }
        const frame: *const FrameReg = @ptrCast(@alignCast(fiber.stack[fp..].ptr));
        if (frame.ret_addr == null) break;
        try visitor.visitValue(frame.ns);
        if (frame.prev_closure) |closure| try visitor.visitAddress(@intFromPtr(closure));
        for (frame.consts) |value| try visitor.visitValue(value);
        try traceFunctionTable(visitor, seen, frame.prev_fns);
        if (fp == 0) break;
        if (frame.prev_fp >= fp) return error.InvalidRef;
        fp = frame.prev_fp;
        nregs = frame.prev_nregs;
    }
}

fn traceTypeObject(visitor: *Store.MarkVisitor, object: Object) anyerror!void {
    if (object != .null) try visitor.visitValue(Value.typeValue(object));
}

fn traceTreeSpec(visitor: *Store.MarkVisitor, spec: *const skript.autodiff_tree.TreeSpec) anyerror!void {
    for (spec.nodes) |node| {
        try traceTypeObject(visitor, node.runtime_type);
        try visitor.visitValue(node.original);
        switch (node.kind) {
            .custom => |custom| {
                try visitor.visitValue(custom.namespace);
                try visitor.visitValue(custom.metadata);
                try visitor.visitValue(custom.unflatten_hook);
            },
            else => {},
        }
    }
    for (spec.map_keys) |value| try visitor.visitValue(value);
    for (spec.leaves) |leaf| {
        try traceTypeObject(visitor, leaf.runtime_type);
        try visitor.visitValue(leaf.primal);
    }
}

fn traceLinearOps(visitor: *Store.MarkVisitor, ops: skript.autodiff_space.LinearOps) anyerror!void {
    try traceTypeObject(visitor, ops.representation_type);
    try visitor.visitValue(ops.namespace);
    if (ops.native.context != null) return error.UntracedAllocation;
    if (ops.zero_hook) |value| try visitor.visitValue(value);
    if (ops.add_hook) |value| try visitor.visitValue(value);
    if (ops.scale_hook) |value| try visitor.visitValue(value);
    if (ops.check_hook) |value| try visitor.visitValue(value);
    if (ops.basis_hook) |value| try visitor.visitValue(value);
    if (ops.construct_hook) |value| try visitor.visitValue(value);
}

fn traceSpaceSpec(visitor: *Store.MarkVisitor, spec: *const skript.autodiff_space.SpaceSpec) anyerror!void {
    try traceTypeObject(visitor, spec.primal_type);
    if (spec.tree_spec) |tree| try traceTreeSpec(visitor, tree);
    try traceLinearOps(visitor, spec.tangent);
    try traceLinearOps(visitor, spec.cotangent);
    try visitor.visitValue(spec.pairing.namespace);
    if (spec.pairing.hook) |value| try visitor.visitValue(value);
    if (spec.pairing.native) |native| {
        if (native.context != null) return error.UntracedAllocation;
    }
    switch (spec.metric) {
        .native => |native| if (native.context != null) return error.UntracedAllocation,
        .hook => |hook| {
            try visitor.visitValue(hook.namespace);
            try visitor.visitValue(hook.function);
        },
        else => {},
    }
}

fn traceCodeRule(
    visitor: *Store.MarkVisitor,
    seen: *SourceRoots,
    rule: skript.autodiff_rules.CodeRule,
) anyerror!void {
    try visitor.visitValue(rule.callable);
    try traceCode(visitor, seen, rule.code);
}

fn traceRuntimeRegistries(
    self: *Runtime,
    visitor: *Store.MarkVisitor,
    seen: *SourceRoots,
) anyerror!void {
    var primitives = self.intrinsics.registry.snapshots;
    while (primitives) |node| : (primitives = node.next) {
        for (node.snapshot.specs) |spec| {
            switch (spec.invoke) {
                .closure => |value| try visitor.visitValue(value),
                .native => {},
            }
        }
    }
    var trees = self.tree_registry.snapshots;
    while (trees) |node| : (trees = node.next) {
        for (node.snapshot.specs) |spec| {
            try traceTypeObject(visitor, spec.runtime_type);
            try visitor.visitValue(spec.namespace);
            try visitor.visitValue(spec.flatten_hook);
            try visitor.visitValue(spec.unflatten_hook);
        }
    }
    var spaces = self.space_registry.snapshots;
    while (spaces) |node| : (spaces = node.next) {
        for (node.snapshot.specs) |*spec| try traceSpaceSpec(visitor, spec);
    }
    if (self.ad_rules) |*owner| {
        var rules = owner.snapshots;
        while (rules) |node| : (rules = node.next) {
            for (node.snapshot.rules) |rule| {
                if (rule.jvp) |jvp| switch (jvp) {
                    .builtin => {},
                    .code => |code_rule| try traceCodeRule(visitor, seen, code_rule),
                    .hook => |hook| {
                        try visitor.visitValue(hook.namespace);
                        try visitor.visitValue(hook.callable);
                    },
                };
                if (rule.linearize) |code_rule| try traceCodeRule(visitor, seen, code_rule);
                if (rule.transpose_linear) |code_rule| try traceCodeRule(visitor, seen, code_rule);
            }
        }
    }
}

fn traceLinearizationState(self: *Runtime, visitor: *Store.MarkVisitor) anyerror!void {
    var region = self.linearization_state.head.load(.acquire);
    while (region) |current| : (region = current.next) {
        // A closed tombstone keeps its identity, but its arena-backed slices
        // no longer exist. Live regions retain all residual Value edges.
        if (current.storage.load(.acquire) == null) continue;
        if (current.inherited) |guard| {
            const trace = guard.trace orelse return error.UntracedAllocation;
            try visitor.visitGuard(trace, guard.context);
        }
        for (current.expected_arguments) |value| try visitor.visitValue(value);
        for (current.argument_spaces) |*spec| try traceSpaceSpec(visitor, spec);
        for (current.space_reads.items) |edge| switch (edge) {
            .cell => |cell| {
                try visitor.visitValue(cell.namespace);
                try visitor.visitValue(cell.snapshot.value);
            },
            .method => |method| try visitor.visitValue(method.value),
            .primitive => {},
        };
        for (current.space_hooks.items) |hook| {
            try visitor.visitValue(hook.value);
            for (hook.captures) |value| try visitor.visitValue(value);
        }
        for (current.space_values.items) |snapshot| {
            try visitor.visitValue(snapshot.value);
            try traceTreeSpec(visitor, &snapshot.structure);
        }
        var space_record = current.spaces.load(.acquire);
        while (space_record) |record| : (space_record = record.next) {
            try traceSpaceSpec(visitor, &record.algebra);
        }
        var record = current.records;
        while (record) |entry| : (record = entry.next) {
            try visitor.visitValue(entry.kernel);
            for (entry.inputs) |value| try visitor.visitValue(value);
            for (entry.input_prototypes) |value| try visitor.visitValue(value);
            try visitor.visitValue(entry.output);
            for (entry.prefixes) |value| try visitor.visitValue(value);
            if (entry.pullback.load(.acquire)) |value| try visitor.visitValue(value.*);
        }
    }
}

/// Visit Runtime-owned Store roots while the host has stopped all mutators.
pub fn traceRuntimeRoots(root_context: *anyopaque, visitor: *Store.MarkVisitor) anyerror!void {
    const self: *Runtime = @ptrCast(@alignCast(root_context));
    var seen_sources: SourceRoots = .empty;
    defer seen_sources.deinit(visitor.store.backingAllocator());
    for (self.compiled_codes.items) |code| try traceCode(visitor, &seen_sources, code);
    try traceRuntimeRegistries(self, visitor, &seen_sources);
    try traceLinearizationState(self, visitor);
    try visitor.visitValue(self.root_ns);
    try visitor.visitValue(self.prelude_ns);
    for (self.constants.values()) |value| try visitor.visitValue(value);
    for (self.predefined_types.items) |typ| try visitor.visitAddress(@intFromPtr(typ));
    var dependencies = self.dependency_cells.iterator();
    while (dependencies.next()) |entry| {
        if (entry.key_ptr.namespace != .null) {
            try visitor.visitValue(Value.namespace(entry.key_ptr.namespace));
        }
        try visitor.visitValue(entry.value_ptr.value);
    }
    for (self.modules.entries.items) |entry| try visitor.visitValue(entry.ns);
    var cache = self.ad_cache.map.valueIterator();
    while (cache.next()) |value| try visitor.visitValue(value.*);
    if (comptime intrin.ffi_enabled) {
        var function: ?*intrin.ffi.Function = if (self.ffi_plan_head) |head|
            @ptrCast(@alignCast(head))
        else
            null;
        while (function) |current| {
            try visitor.visitAddress(@intFromPtr(current));
            function = current.next_plan;
        }
    }
    if (comptime intrin.dynlib_enabled) try intrin.dynlib.traceRuntimeRoots(self, visitor);
    for (self.scheduler.processes.items) |process| {
        try visitor.visitValue(process.result);
        try visitor.visitValue(process.raised);
        if (process.future_obj.load(.acquire)) |future| {
            try visitor.visitAddress(@intFromPtr(future));
        }
        var mail = process.mailbox_head.load(.acquire);
        while (mail) |node| : (mail = node.next.load(.acquire)) {
            try visitor.visitValue(node.msg);
        }
        try traceFiber(visitor, &seen_sources, &process.fib);
    }
}

/// Collect at an explicit host safepoint. The host must exclude all other
/// direct Runtime and Store calls until this returns. Holding the scheduler
/// mutex blocks the runner before it dispatches another VM quantum; an active
/// quantum reports Busy rather than claiming the world is stopped.
pub fn collect(self: *Runtime) anyerror!void {
    if (EvalContext.active) |active| {
        if (active.runtime == self) return error.Busy;
    }
    self.scheduler.mutex.lockUncancelable(self.io);
    defer self.scheduler.mutex.unlock(self.io);
    if (self.scheduler.running_process != null) return error.Busy;
    try self.store.collect(self.store.assumeStopped());
}
