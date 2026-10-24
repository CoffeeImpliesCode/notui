//! Forward-mode gradient and value-and-gradient wrappers.
//!
//! These wrappers use one analytic JVP sweep per numeric leaf. They do not
//! construct dual values and they do not use finite differences. Input lists,
//! tensors, and maps are treated as bounded pytrees; each gradient preserves
//! the input structure and tensor shape.

const std = @import("std");
const Code = @import("../code.zig");
const skript = @import("../root.zig");
const Value = skript.Value;
const Error = skript.Error;
const EvalContext = skript.EvalContext;
const Runtime = skript.Runtime;
const Closure = skript.data.Closure;
const Allocator = std.mem.Allocator;
const TensorHolder = skript.intrinsics.tensor.TensorHolder;
const TensorInner = skript.intrinsics.tensor.InnerType;
const map_intrin = skript.intrinsics.map;
const ad = @import("ad.zig");
const tree = @import("../autodiff/tree.zig");
const space = @import("../autodiff/space.zig");
const effects = @import("../ad_effects.zig");
const max_sweeps: usize = tree.Limits.gradient.max_leaves;

const DependencyGuard = struct {
    runtime: *Runtime,
    inherited: ?*const skript.data.ClosureGuard,
    reads: []const effects.Read,
    rules: *const skript.autodiff_rules.RegistryVersion,
};

fn traceDependencies(context: *const anyopaque, visitor: *skript.Store.MarkVisitor) anyerror!void {
    const state: *const DependencyGuard = @ptrCast(@alignCast(context));
    for (state.reads) |dependency| switch (dependency) {
        .cell => |cell| {
            try visitor.visitValue(cell.namespace);
            try visitor.visitValue(cell.snapshot.value);
        },
        .method => |method| try visitor.visitValue(method.value),
        .primitive => |primitive| switch (primitive.invoke) {
            .closure => |value| try visitor.visitValue(value),
            .native => {},
        },
    };
    if (state.inherited) |inherited| {
        const trace = inherited.trace orelse return error.UntracedAllocation;
        try visitor.visitGuard(trace, inherited.context);
    }
}

fn checkDependencies(runtime: *Runtime, context: *const anyopaque) Error!void {
    const state: *const DependencyGuard = @ptrCast(@alignCast(context));
    if (runtime != state.runtime) return error.Denied;
    const ctx = runtime.context();
    try ctx.check();
    const registry = if (runtime.ad_rules) |*owner| owner else return error.Unsupported;
    if (!registry.ownsCurrent(state.rules)) return error.Unsupported;
    if (state.inherited) |parent| try parent.check(runtime, parent.context);
    try ctx.chargeWork(@intCast(state.reads.len), 1, .code);
    for (state.reads) |dependency| if (!dependency.valid(runtime)) return error.Unsupported;
}

fn snapshotDependencies(ctx: *EvalContext, primal: Value) Error!*const skript.data.ClosureGuard {
    const runtime = ctx.runtime;
    const closure = primal.obj.toRef().deref(Closure);
    // Unsupported targets remain deferred until argument shapes are checked.
    const reads = effects.collectReads(runtime, closure.parent_ns, primal, runtime.static) catch |err| switch (err) {
        error.Unsupported => &.{},
        else => return err,
    };
    const state = try runtime.static.create(DependencyGuard);
    state.* = .{
        .runtime = runtime,
        .inherited = closure.guard,
        .reads = reads,
        .rules = try skript.autodiff_rules.builtinSnapshot(ctx),
    };
    const guard = try runtime.static.create(skript.data.ClosureGuard);
    guard.* = .{
        .context = state,
        .check = &checkDependencies,
        .trace = &traceDependencies,
    };
    return guard;
}

fn activeContext(rt: *Runtime) ?*EvalContext {
    return EvalContext.currentForStore(rt.store);
}

fn chargeWork(rt: *Runtime, count: usize) Error!void {
    const context = activeContext(rt) orelse return;
    const count_u64 = std.math.cast(u64, count) orelse return error.Unsupported;
    try context.chargeWork(count_u64, 1, .transform);
}

/// A reusable private seed records where one numeric leaf lives in its tree.
/// Composite seed storage is allocated once and never returned to callers.
const SeedLeaf = union(enum) {
    value: struct {
        slot: *Value,
        zero: Value,
        one: Value,
    },
    map: struct {
        map: Value,
        key: Value,
        zero: Value,
        one: Value,
    },
    tensor: struct {
        data: []u64,
        index: usize,
        inner: TensorInner,
    },
};

const MapSeedTarget = struct {
    map: Value,
    key: Value,
};

const SeedWorkspace = struct {
    value: Value,
    leaves: []SeedLeaf,

    fn setLeaf(
        self: *const SeedWorkspace,
        ctx: *EvalContext,
        index: usize,
        active: bool,
    ) Error!void {
        if (index >= self.leaves.len) return error.Unsupported;
        switch (self.leaves[index]) {
            .value => |leaf| {
                leaf.slot.* = if (active) leaf.one else leaf.zero;
            },
            .map => |leaf| {
                const value = if (active) leaf.one else leaf.zero;
                _ = try map_intrin.set(
                    ctx,
                    .nil,
                    .nil,
                    &.{ leaf.map, leaf.key, value },
                );
            },
            .tensor => |leaf| {
                const seed_value = if (active) switch (leaf.inner) {
                    .i64 => Value.i64(1),
                    .f64 => Value.f64(1.0),
                    .empty => return error.TypeMismatch,
                    else => return error.TypeMismatch,
                } else switch (leaf.inner) {
                    .i64 => Value.i64(0),
                    .f64 => Value.f64(0.0),
                    .empty => return error.TypeMismatch,
                    else => return error.TypeMismatch,
                };
                leaf.data[leaf.index] = try tree.tensorWord(leaf.inner, seed_value);
            },
        }
    }
};

fn isRealNumeric(value: Value) bool {
    return tree.isNumeric(value);
}

fn buildReusableSeed(
    allocator: Allocator,
    rt: *Runtime,
    spec: *const tree.TreeSpec,
    node_id: tree.NodeId,
    leaves: []SeedLeaf,
    cursor: *usize,
    slot: ?*Value,
    map_target: ?MapSeedTarget,
) Error!Value {
    if (activeContext(rt)) |context| {
        var child_context = try context.enter(.transform);
        const scope = child_context.activate();
        defer scope.deinit();
        return buildReusableSeedImpl(
            allocator,
            rt,
            spec,
            node_id,
            leaves,
            cursor,
            slot,
            map_target,
        );
    }
    return buildReusableSeedImpl(
        allocator,
        rt,
        spec,
        node_id,
        leaves,
        cursor,
        slot,
        map_target,
    );
}

fn buildReusableSeedImpl(
    allocator: Allocator,
    rt: *Runtime,
    spec: *const tree.TreeSpec,
    node_id: tree.NodeId,
    leaves: []SeedLeaf,
    cursor: *usize,
    slot: ?*Value,
    map_target: ?MapSeedTarget,
) Error!Value {
    const context = activeContext(rt) orelse rt.context();
    try chargeWork(rt, 1);
    const node = spec.node(node_id);
    switch (node.kind) {
        .scalar => {
            if (cursor.* >= leaves.len) return error.Unsupported;
            const zero = try tree.zero(node.runtime_type);
            const one = try tree.one(node.runtime_type);
            if (map_target) |target| {
                leaves[cursor.*] = .{ .map = .{
                    .map = target.map,
                    .key = target.key,
                    .zero = zero,
                    .one = one,
                } };
            } else {
                const value_slot = if (slot) |existing| existing else try allocator.create(Value);
                value_slot.* = zero;
                leaves[cursor.*] = .{ .value = .{
                    .slot = value_slot,
                    .zero = zero,
                    .one = one,
                } };
            }
            cursor.* = std.math.add(usize, cursor.*, 1) catch return error.Unsupported;
            return zero;
        },
        .tensor => |tensor| {
            const holder = node.original.obj.toRef().deref(TensorHolder).*;
            const seed_shape = try rt.store.allocSlice(u32, holder.shape.len);
            if (seed_shape.slice.len > 0) @memcpy(seed_shape.slice, holder.shape);
            const seed_data = try rt.store.allocSlice(u64, holder.data.len);
            @memset(seed_data.slice, 0);
            const ref = try rt.store.createTraced(
                TensorHolder,
                skript.intrinsics.tensor.traceTensorHolder,
            );
            ref.deref(TensorHolder).* = .{
                .inner = tensor.inner,
                .rank = holder.rank,
                .shape = seed_shape.slice,
                .data = seed_data.slice,
                .shape_ref = seed_shape.ref,
                .data_ref = seed_data.ref,
            };
            const seed = Value.tensor(ref.toObject());
            for (0..seed_data.slice.len) |index| {
                try chargeWork(rt, 1);
                if (cursor.* >= leaves.len) return error.Unsupported;
                leaves[cursor.*] = .{ .tensor = .{
                    .data = seed_data.slice,
                    .index = index,
                    .inner = tensor.inner,
                } };
                cursor.* = std.math.add(usize, cursor.*, 1) catch return error.Unsupported;
            }
            return seed;
        },
        .list => {
            var result: Value = .nil;
            var tail: ?*[2]Value = null;
            for (spec.children(node)) |child_id| {
                try chargeWork(rt, 1);
                const ref = try rt.store.create([2]Value);
                const cell = ref.deref([2]Value);
                cell[0] = try buildReusableSeed(
                    allocator,
                    rt,
                    spec,
                    child_id,
                    leaves,
                    cursor,
                    &cell[0],
                    null,
                );
                cell[1] = .nil;
                const cell_value = Value.cons(ref.toObject());
                if (tail) |last| last[1] = cell_value else result = cell_value;
                tail = cell;
            }
            return result;
        },
        .map => {
            const seed_map = try map_intrin.create(context, .nil, .nil, &.{});
            for (spec.children(node), spec.keys(node)) |child_id, key| {
                try chargeWork(rt, 1);
                const target: ?MapSeedTarget = switch (spec.node(child_id).kind) {
                    .scalar => .{ .map = seed_map, .key = key },
                    else => null,
                };
                const child_value = try buildReusableSeed(
                    allocator,
                    rt,
                    spec,
                    child_id,
                    leaves,
                    cursor,
                    null,
                    target,
                );
                _ = try map_intrin.set(context, .nil, .nil, &.{ seed_map, key, child_value });
            }
            return seed_map;
        },
        .custom => return error.Unsupported,
    }
}

fn consCell(rt: *Runtime, car_value: Value, cdr_value: Value) Error!Value {
    const ref = try rt.store.create([2]Value);
    ref.deref([2]Value).* = .{ car_value, cdr_value };
    return .cons(ref.toObject());
}

fn makeList(rt: *Runtime, values: []const Value) Error!Value {
    var result: Value = .nil;
    var index = values.len;
    while (index > 0) {
        try chargeWork(rt, 1);
        index -= 1;
        result = try consCell(rt, values[index], result);
    }
    return result;
}

fn callJvp(
    ctx: *EvalContext,
    workspace: *Runtime.CallWorkspace,
    jvp: Value,
    original_args: []const Value,
    tangent: Value,
    call_args: []Value,
    outputs: []Value,
) Error!void {
    const expected_args = std.math.add(
        usize,
        original_args.len,
        1,
    ) catch return error.Unsupported;
    if (call_args.len != expected_args) return error.ArityMismatch;
    if (outputs.len != 2) return error.ArityMismatch;
    try chargeWork(ctx.runtime, call_args.len);
    @memcpy(call_args[0..original_args.len], original_args);
    call_args[original_args.len] = tangent;
    try workspace.apply(ctx, jvp, call_args, outputs);
    outputs[0] = try outputs[0].unwrapError();
    outputs[1] = try outputs[1].unwrapError();
    if (!isRealNumeric(outputs[0])) return error.TypeMismatch;
    if (!isRealNumeric(outputs[1])) return error.TypeMismatch;
}

fn requireRealNumeric(value: Value) Error!Value {
    const unwrapped = try value.unwrapError();
    if (!isRealNumeric(unwrapped)) return error.TypeMismatch;
    return unwrapped;
}

/// Preparation completes all tree checks and JVP compilation before primal
/// evaluation. The plan is arena-owned for one gradient callback.
const GradientPlan = struct {
    primal: Value,
    spaces: []space.SpaceSpec,
    jvps: []Value,
    total_sweeps: usize,
};
fn prepareGradient(
    allocator: Allocator,
    ctx: *EvalContext,
    ns: Value,
    primal_value: Value,
    original_args: []const Value,
) Error!GradientPlan {
    const rt = ctx.runtime;
    if (primal_value.typ != skript.builtins.type_closure) return error.TypeMismatch;
    const primal = primal_value.obj.toRef().deref(Closure);
    try ad.requireFixedSourceClosure(primal);
    if (primal.arglist.len != original_args.len) return error.ArityMismatch;
    if (primal.arglist.len == 0) return error.ArityMismatch;
    const spaces = try allocator.alloc(space.SpaceSpec, original_args.len);
    var total_sweeps: usize = 0;
    for (spaces, original_args) |*space_spec, argument| {
        try chargeWork(rt, 1);
        if (rt.space_registry.current().find(argument.typ)) |registered| {
            space_spec.* = registered.*;
        } else {
            const spec = try allocator.create(tree.TreeSpec);
            spec.* = try tree.flatten(allocator, ctx, rt.tree_registry.current(), argument, tree.Limits.gradient);
            space_spec.* = try space.resolve(ctx, spec);
        }
        const dimension = space_spec.dimension orelse return error.Unsupported;
        if (space_spec.metric == .none) return error.Unsupported;
        total_sweeps = std.math.add(usize, total_sweeps, dimension) catch
            return error.LimitExceeded;
        if (total_sweeps > max_sweeps) return error.LimitExceeded;
    }
    try ad.preflight(rt, ns, primal_value);

    const jvps = try allocator.alloc(Value, original_args.len);
    for (jvps, 0..) |*jvp, parameter_index| {
        try chargeWork(rt, 1);
        jvp.* = try ad.jvpClosure(ctx, primal_value, parameter_index);
    }
    return .{
        .primal = primal_value,
        .spaces = spaces,
        .jvps = jvps,
        .total_sweeps = total_sweeps,
    };
}

fn prepareSeeds(allocator: Allocator, ctx: *EvalContext, plan: *const GradientPlan) Error![]?SeedWorkspace {
    const seeds = try allocator.alloc(?SeedWorkspace, plan.spaces.len);
    @memset(seeds, null);
    for (seeds, plan.spaces) |*optional_seed, algebra| {
        const spec = algebra.tree_spec orelse continue;
        if (spec.containsCustom()) continue;
        const leaves = try allocator.alloc(SeedLeaf, spec.leaves.len);
        optional_seed.* = .{ .value = .nil, .leaves = leaves };
        const seed = &optional_seed.*.?;
        var cursor: usize = 0;
        seed.value = try buildReusableSeed(
            allocator,
            ctx.runtime,
            spec,
            spec.root,
            leaves,
            &cursor,
            &seed.value,
            null,
        );
        if (cursor != spec.leaves.len) return error.InvalidCode;
    }
    return seeds;
}

fn sweepParameter(
    ctx: *EvalContext,
    workspace: *Runtime.CallWorkspace,
    jvp: Value,
    original_args: []const Value,
    call_args: []Value,
    seed: ?*const SeedWorkspace,
    algebra: *const space.SpaceSpec,
    derivatives: []Value,
    primal: *?Value,
) Error!void {
    for (derivatives, 0..) |*derivative, basis| {
        const tangent = if (seed) |reusable| blk: {
            try reusable.setLeaf(ctx, basis, true);
            break :blk reusable.value;
        } else try algebra.tangentBasis(ctx, basis);
        var outputs: [2]Value = undefined;
        callJvp(ctx, workspace, jvp, original_args, tangent, call_args, &outputs) catch |err| {
            if (seed) |reusable| try reusable.setLeaf(ctx, basis, false);
            return err;
        };
        if (seed) |reusable| try reusable.setLeaf(ctx, basis, false);
        if (primal.* == null) primal.* = outputs[0];
        derivative.* = outputs[1];
    }
}

fn computeGradientForResult(
    allocator: Allocator,
    ctx: *EvalContext,
    ns: Value,
    original_args: []const Value,
    plan: *const GradientPlan,
    primal_result_out: *Value,
) Error!Value {
    const gradient_values = try allocator.alloc(Value, original_args.len);
    const jvp_args = try allocator.alloc(
        Value,
        std.math.add(usize, original_args.len, 1) catch return error.Unsupported,
    );
    const derivatives = try allocator.alloc(Value, plan.total_sweeps);
    const seeds = try prepareSeeds(allocator, ctx, plan);
    var primal: ?Value = if (plan.total_sweeps == 0)
        try requireRealNumeric(try ctx.apply(ns, plan.primal, original_args))
    else
        null;
    var workspace = Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    var offset: usize = 0;
    for (plan.spaces, plan.jvps, seeds) |*algebra, jvp, *seed| {
        const dimension = algebra.dimension orelse return error.Unsupported;
        const coordinates = derivatives[offset..][0..dimension];
        try sweepParameter(
            ctx,
            &workspace,
            jvp,
            original_args,
            jvp_args,
            if (seed.*) |*reusable| reusable else null,
            algebra,
            coordinates,
            &primal,
        );
        offset += dimension;
    }
    if (offset != plan.total_sweeps) return error.InvalidCode;
    offset = 0;
    for (plan.spaces, gradient_values) |*algebra, *gradient_value| {
        const dimension = algebra.dimension orelse return error.Unsupported;
        const cotangent = try algebra.cotangentFromCoordinates(ctx, derivatives[offset..][0..dimension]);
        gradient_value.* = try algebra.gradientFromCotangent(ctx, cotangent);
        offset += dimension;
    }
    primal_result_out.* = primal orelse return error.InvalidCode;
    return if (gradient_values.len == 1) gradient_values[0] else makeList(ctx.runtime, gradient_values);
}

fn computeGradient(
    ctx: *EvalContext,
    ns: Value,
    primal_value: Value,
    original_args: []const Value,
) Error!Value {
    var arena = std.heap.ArenaAllocator.init(ctx.scratch);
    defer arena.deinit();
    const allocator = arena.allocator();
    const plan = try prepareGradient(allocator, ctx, ns, primal_value, original_args);
    var primal_result: Value = .nil;
    return computeGradientForResult(
        allocator,
        ctx,
        ns,
        original_args,
        &plan,
        &primal_result,
    );
}

fn computeValueAndGradient(
    ctx: *EvalContext,
    ns: Value,
    primal_value: Value,
    original_args: []const Value,
) Error!Value {
    const rt = ctx.runtime;
    var arena = std.heap.ArenaAllocator.init(ctx.scratch);
    defer arena.deinit();
    const allocator = arena.allocator();
    const plan = try prepareGradient(allocator, ctx, ns, primal_value, original_args);
    var value: Value = .nil;
    const gradient_value = try computeGradientForResult(
        allocator,
        ctx,
        ns,
        original_args,
        &plan,
        &value,
    );
    return consCell(rt, value, gradient_value);
}
fn compileWrapper(
    rt: *Runtime,
    ns: Value,
    primal_value: Value,
    callback: skript.FuncPtr,
) Error!Value {
    if (primal_value.typ != skript.builtins.type_closure) return error.TypeMismatch;
    const primal = primal_value.obj.toRef().deref(Closure);

    const ctx = rt.context();
    const callback_id = ctx.registry.idForNative(callback) orelse return error.Unsupported;
    const identity = try rt.allocCodeIdentity();
    var builder = Code.Builder.init(rt.static, ctx);
    builder.id = identity.id;
    builder.revision = identity.revision;

    const source_function = if (primal.code) |code|
        code.function(primal.function_id)
    else
        null;
    const function_name = if (source_function) |function_info| function_info.name else null;
    if (source_function) |function_info| {
        if (function_info.has_rest) return error.Unsupported;
    }
    const function = try builder.addFunction(function_name, primal.source_ref);
    builder.functions.items[@backingInt(function)].has_rest = false;
    builder.functions.items[@backingInt(function)].source_value = primal.source;
    if (source_function) |function_info| {
        builder.functions.items[@backingInt(function)].origin = .{
            .code = primal.code orelse return error.InvalidCode,
            .function = primal.function_id,
        };
        builder.functions.items[@backingInt(function)].ad_level =
            std.math.add(u16, function_info.ad_level, 1) catch return error.Unsupported;
        builder.functions.items[@backingInt(function)].arglist = function_info.arglist;
        builder.functions.items[@backingInt(function)].body = function_info.body;
    }
    const block = try builder.addBlock(function);
    const parameter_values = try ctx.scratch.alloc(Code.ValueId, primal.arglist.len);
    defer ctx.scratch.free(parameter_values);
    for (primal.arglist, parameter_values) |symbol, *parameter_value| {
        const binding = try builder.addBinding(function, symbol, .parameter, .{});
        parameter_value.* = try builder.addValue(function);
        builder.bindings.items[@backingInt(binding)].value = parameter_value.*;
        try builder.addParameter(function, binding);
    }

    const primal_node = try builder.addNode(
        function,
        block,
        .{ .literal = primal_value },
        .{},
    );
    const call_arg_count = std.math.add(
        usize,
        primal.arglist.len,
        1,
    ) catch return error.Unsupported;
    const call_args = try ctx.scratch.alloc(Code.ValueId, call_arg_count);
    defer ctx.scratch.free(call_args);
    call_args[0] = primal_node;
    @memcpy(call_args[1..], parameter_values);
    const result = try builder.addNode(
        function,
        block,
        .{ .primitive_call = .{
            .primitive = callback_id,
            .args = try builder.addOperands(call_args),
        } },
        .{},
    );
    try builder.setTerminator(
        block,
        .{ .return_values = try builder.addOperands(&.{result}) },
    );

    const code = try builder.finish(ctx.scratch);
    code.owner = rt;
    const program = try rt.lowerCode(ctx.scratch, code);
    const function_index = @backingInt(function);
    if (function_index >= program.fns.len) return error.InvalidCode;
    const lowered = program.fns[function_index];
    const guard = try snapshotDependencies(ctx, primal_value);
    const reference = try rt.store.create(Closure);
    rt.store.store(Closure, reference.deref(Closure), .{
        .parent_ns = ns,
        .arglist = lowered.arglist,
        .source = lowered.source,
        .source_ref = lowered.source_ref,
        .ir = lowered.ir,
        .constants = lowered.constants,
        .nregs = lowered.nregs,
        .result_count = lowered.result_count,
        .zero_mask = lowered.zero_mask,
        .capture_syms = lowered.capture_syms,
        .captures = &.{},
        .code = code,
        .environment_id = primal.environment_id,
        .function_id = function,
        .fns = program.fns,
        .guard = guard,
    });
    return .closure(reference.toObject());
}

/// `(gradient f)` returns a wrapper that performs one forward JVP sweep per
/// numeric input leaf. A single formal argument returns its matching pytree;
/// multiple formal arguments return a list of matching pytrees.
pub fn gradient(ctx: *EvalContext, ns: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    if (args.len != 1) return error.ArityMismatch;
    const primal_value = args[0];
    if (primal_value.typ == skript.builtins.type_intrinsic or
        primal_value.typ == skript.builtins.type_method)
    {
        return ad.deriv(ctx, ns, .nil, args);
    }
    if (primal_value.typ != skript.builtins.type_closure) return error.TypeMismatch;
    const primal = primal_value.obj.toRef().deref(Closure);
    try ad.requireFixedSourceClosure(primal);
    if (primal.arglist.len == 0) return error.ArityMismatch;
    const key = try ad.cacheKeyFor(rt, primal_value, .gradient, 0);
    if (try rt.ad_cache.getValidated(ctx, key)) |cached| return cached;
    const wrapper = try compileWrapper(rt, primal.parent_ns, primal_value, &gradientCallback);
    try rt.ad_cache.put(rt.gpa, key, wrapper);
    return wrapper;
}

/// `(value-and-gradient f)` returns a wrapper that conses the scalar primal
/// result with the structure-preserving forward gradient.
pub fn valueAndGradient(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    if (args.len != 1) return error.ArityMismatch;
    const primal_value = args[0];
    if (primal_value.typ != skript.builtins.type_closure) return error.TypeMismatch;
    const primal = primal_value.obj.toRef().deref(Closure);
    try ad.requireFixedSourceClosure(primal);
    if (primal.arglist.len == 0) return error.ArityMismatch;

    const key = try ad.cacheKeyFor(rt, primal_value, .value_gradient, 0);
    if (try rt.ad_cache.getValidated(ctx, key)) |cached| return cached;
    const wrapper = try compileWrapper(rt, primal.parent_ns, primal_value, &valueGradientCallback);
    try rt.ad_cache.put(rt.gpa, key, wrapper);
    return wrapper;
}

pub fn gradientCallback(ctx: *EvalContext, ns: Value, _: Value, args: []const Value) Error!Value {
    if (args.len < 1) return error.ArityMismatch;
    return computeGradient(ctx, ns, args[0], args[1..]);
}

pub fn valueGradientCallback(ctx: *EvalContext, ns: Value, _: Value, args: []const Value) Error!Value {
    if (args.len < 1) return error.ArityMismatch;
    return computeValueAndGradient(ctx, ns, args[0], args[1..]);
}

fn makeCodeOnlySecondProjection(rt: *Runtime) !Value {
    const ctx = rt.context();
    const identity = try rt.allocCodeIdentity();
    var builder = Code.Builder.init(rt.static, ctx);
    builder.id = identity.id;
    builder.revision = identity.revision;

    const function = try builder.addFunction(null, .{});
    const block = try builder.addBlock(function);
    const binding = try builder.addBinding(
        function,
        try rt.store.getsym("tree"),
        .parameter,
        .{},
    );
    const parameter = try builder.addValue(function);
    builder.bindings.items[@backingInt(binding)].value = parameter;
    try builder.addParameter(function, binding);

    const rst_primitive = ctx.registry.idForNative(
        &skript.intrinsics.list.rst,
    ) orelse return error.Unsupported;
    const tail = try builder.addNode(function, block, .{ .primitive_call = .{
        .primitive = rst_primitive,
        .args = try builder.addOperands(&.{parameter}),
    } }, .{});
    const fst_primitive = ctx.registry.idForNative(
        &skript.intrinsics.list.fst,
    ) orelse return error.Unsupported;
    const result = try builder.addNode(function, block, .{ .primitive_call = .{
        .primitive = fst_primitive,
        .args = try builder.addOperands(&.{tail}),
    } }, .{});
    try builder.setTerminator(
        block,
        .{ .return_values = try builder.addOperands(&.{result}) },
    );

    const code = try builder.finish(ctx.scratch);
    code.owner = rt;
    const program = try rt.lowerCode(ctx.scratch, code);
    const function_index = @backingInt(function);
    if (function_index >= program.fns.len) return error.InvalidCode;
    const lowered = program.fns[function_index];
    const reference = try rt.store.create(Closure);
    rt.store.store(Closure, reference.deref(Closure), .{
        .parent_ns = rt.root_ns,
        .arglist = lowered.arglist,
        .source = lowered.source,
        .source_ref = lowered.source_ref,
        .ir = lowered.ir,
        .constants = lowered.constants,
        .nregs = lowered.nregs,
        .result_count = lowered.result_count,
        .zero_mask = lowered.zero_mask,
        .capture_syms = lowered.capture_syms,
        .captures = &.{},
        .code = code,
        .function_id = function,
        .fns = program.fns,
    });
    return .closure(reference.toObject());
}

fn expectSecondProjectionGradient(value: Value) !void {
    try std.testing.expectEqual(skript.builtins.type_cons, value.typ);
    const first = value.obj.toRef().deref([2]Value);
    try std.testing.expectEqual(Value.f64(0.0), first[0]);
    try std.testing.expectEqual(skript.builtins.type_cons, first[1].typ);
    const second = first[1].obj.toRef().deref([2]Value);
    try std.testing.expectEqual(Value.i64(1), second[0]);
    try std.testing.expectEqual(Value.nil, second[1]);
}

test "Code-only wrappers preserve structured exact i64 primals and gradients" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const callable = try makeCodeOnlySecondProjection(rt);
    const exact = Value.i64(9_007_199_254_740_993);
    const input = try consCell(rt, Value.f64(3.0), try consCell(rt, exact, .nil));

    const gradient_wrapper = try gradient(
        rt.context(),
        rt.root_ns,
        .nil,
        &.{callable},
    );
    const gradient_result = try rt.apply(rt.root_ns, gradient_wrapper, &.{input});
    try expectSecondProjectionGradient(gradient_result);

    const value_gradient_wrapper = try valueAndGradient(
        rt.context(),
        rt.root_ns,
        .nil,
        &.{callable},
    );
    const value_gradient = try rt.apply(
        rt.root_ns,
        value_gradient_wrapper,
        &.{input},
    );
    try std.testing.expectEqual(skript.builtins.type_cons, value_gradient.typ);
    const pair = value_gradient.obj.toRef().deref([2]Value);
    try std.testing.expectEqual(exact, pair[0]);
    try expectSecondProjectionGradient(pair[1]);
}

test "generated gradient calls resume their caller" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const value = try runtime.evalString("(list 1 ((gradient (fn (x) (* x x))) 3.0) 2)");
    var cursor = value;
    for ([_]Value{ .i64(1), .f64(6.0), .i64(2) }) |expected| {
        try std.testing.expectEqual(skript.builtins.type_cons, cursor.typ);
        const cell = cursor.obj.toRef().deref([2]Value);
        try std.testing.expectEqual(expected, cell[0]);
        cursor = cell[1];
    }
    try std.testing.expectEqual(Value.nil, cursor);
}
