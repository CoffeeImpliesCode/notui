//! Public automatic differentiation over immutable bound Code.
const std = @import("std");
const skript = @import("../root.zig");
const Code = skript.Code;
const Primitive = skript.Primitive;
const Runtime = skript.Runtime;
const EvalContext = skript.EvalContext;
const Value = skript.Value;
const Closure = skript.data.Closure;
const Error = skript.Error;
const b = skript.builtins;
const effects = @import("../ad_effects.zig");
const forward = @import("../autodiff/forward.zig");
const callables = @import("../autodiff/callable.zig");
const rules = @import("../autodiff/rules.zig");
const tree = @import("../autodiff/tree.zig");
const space = @import("../autodiff/space.zig");
const ad_gradient = @import("ad_gradient.zig");

pub const AdCache = struct {
    pub const Kind = enum { derivative, jvp, full_jvp, gradient, value_gradient };
    pub const Origin = union(enum) {
        code: struct { id: u32, revision: u64, function: Code.FunctionId },
        primitive: struct { id: Primitive.PrimitiveId, implementation_revision: u64 },
        method: struct { id: u64, revision: u64 },
    };
    pub const Key = struct {
        origin: Origin,
        kind: Kind,
        parameter: u32,
        environment: u64,
        primitive_revision: u64,
        rule_revision: u64,
        tree_revision: u64,
        space_revision: u64,
        mode: EvalContext.Mode,
        execution: EvalContext.Execution,
        effects: EvalContext.EffectDecisionTable,
        model: ?EvalContext.Version,
        schedule: EvalContext.Budget.Schedule,
        compiler: Runtime.CompilerOpts,
    };

    map: std.AutoHashMapUnmanaged(Key, Value) = .empty,
    next_environment_id: u64 = 1,

    pub fn deinit(self: *AdCache, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
        self.* = undefined;
    }

    pub fn get(self: *const AdCache, key: Key) ?Value {
        return self.map.get(key);
    }

    pub fn put(self: *AdCache, allocator: std.mem.Allocator, key: Key, value: Value) Error!void {
        try self.map.put(allocator, key, value);
    }

    pub fn getValidated(self: *const AdCache, ctx: *EvalContext, key: Key) Error!?Value {
        const value = self.get(key) orelse return null;
        if (value.typ != b.type_closure) return error.InvalidCode;
        const closure = value.obj.toRef().deref(Closure);
        if (closure.guard) |guard| guard.check(ctx.runtime, guard.context) catch |err| switch (err) {
            error.Unsupported, error.Denied => return null,
            else => return err,
        };
        return value;
    }
};

pub fn preflight(runtime: *Runtime, namespace: Value, callable: Value) Error!void {
    if (callable.typ == b.type_closure) {
        const closure = callable.obj.toRef().deref(Closure);
        if (closure.guard) |guard| try guard.check(runtime, guard.context);
    }
    try effects.preflight(runtime, namespace, callable);
}
pub fn requireFixedSourceClosure(closure: *const Closure) Error!void {
    if (closure.code) |code| {
        const function = code.function(closure.function_id) orelse return error.InvalidCode;
        if (function.has_rest) return error.Unsupported;
        return;
    }
    return error.Unsupported;
}

pub fn cacheKeyFor(runtime: *Runtime, callable: Value, kind: AdCache.Kind, parameter: u32) Error!AdCache.Key {
    const ctx = runtime.context();
    try ctx.check();
    var environment: u64 = 0;
    const origin: AdCache.Origin = switch (callable.typ) {
        b.type_closure => blk: {
            const closure = callable.obj.toRef().deref(Closure);
            const code = closure.code orelse return error.Unsupported;
            if (code.owner != @as(?*const anyopaque, runtime)) return error.Denied;
            try requireFixedSourceClosure(closure);
            if (closure.function_id == .invalid) return error.InvalidCode;
            if (closure.environment_id == 0) {
                if (runtime.ad_cache.next_environment_id == std.math.maxInt(u64)) return error.Unsupported;
                closure.environment_id = runtime.ad_cache.next_environment_id;
                runtime.ad_cache.next_environment_id += 1;
            }
            environment = closure.environment_id;
            break :blk .{ .code = .{ .id = code.id, .revision = code.revision, .function = closure.function_id } };
        },
        b.type_intrinsic => blk: {
            const id = ctx.registry.idForNative(callable.obj.toPtr(skript.FuncPtr)) orelse return error.Unsupported;
            const spec = ctx.registry.spec(id) orelse return error.Unsupported;
            break :blk .{ .primitive = .{ .id = id, .implementation_revision = spec.implementation_revision } };
        },
        b.type_method => blk: {
            const method = callable.obj.toRef().deref(skript.data.Method);
            if (method.id == 0) return error.Unsupported;
            break :blk .{ .method = .{ .id = method.id, .revision = method.revision } };
        },
        else => return error.TypeMismatch,
    };
    return .{
        .origin = origin,
        .kind = kind,
        .parameter = parameter,
        .environment = environment,
        .primitive_revision = ctx.registry.version,
        .rule_revision = (try rules.builtinSnapshot(ctx)).version,
        .tree_revision = runtime.tree_registry.current().version,
        .space_revision = runtime.space_registry.current().version,
        .mode = ctx.mode,
        .execution = ctx.execution,
        .effects = ctx.effects,
        .model = ctx.model,
        .schedule = if (ctx.budget()) |budget| budget.schedule else .{},
        .compiler = runtime.compiler_opts.effective(),
    };
}

/// Give a resolved callable a bound body without parsing generated source.
pub fn bindCallable(ctx: *EvalContext, callable: Value, arity: usize) Error!Value {
    const runtime = ctx.runtime;
    if (arity == 0 or arity > 255) return error.ArityMismatch;
    if (callable.typ == b.type_closure) {
        if (callable.obj == .null) return error.Unsupported;
        try requireFixedSourceClosure(callable.obj.toRef().deref(Closure));
    }
    var builder = Code.Builder.init(runtime.static, ctx);
    const identity = try runtime.allocCodeIdentity();
    builder.id = identity.id;
    builder.revision = identity.revision;
    const module = try builder.addFunction(null, .{});
    const entry = try builder.addBlock(module);
    builder.functions.items[@intFromEnum(module)].module_entry = true;
    const function = try builder.addFunction(null, .{});
    const body = try builder.addBlock(function);
    var arguments: [255]Code.ValueId = undefined;
    for (arguments[0..arity], 0..) |*argument, index| {
        var name: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&name, "arg_{d}", .{index}) catch return error.Unsupported;
        const binding = try builder.addBinding(function, try runtime.store.getsym(text), .parameter, .{});
        argument.* = try builder.addValue(function);
        builder.bindings.items[@intFromEnum(binding)].value = argument.*;
        try builder.addParameter(function, binding);
    }
    const callee = try builder.addNode(function, body, .{ .literal = callable }, .{});
    const result = try builder.addNode(function, body, .{ .dynamic_call = .{
        .callee = callee,
        .args = try builder.addOperands(arguments[0..arity]),
    } }, .{});
    try builder.setTerminator(body, .{ .return_values = try builder.addOperands(&.{result}) });
    const exported = try builder.addNode(module, entry, .{ .make_closure = .{ .function = function } }, .{});
    try builder.setTerminator(entry, .{ .return_values = try builder.addOperands(&.{exported}) });
    const code = try builder.finish(ctx.scratch);
    code.owner = runtime;
    const program = try runtime.lowerCode(ctx.scratch, code);
    const lowered = program.fns[@intFromEnum(function)];
    const reference = try runtime.store.create(Closure);
    runtime.store.store(Closure, reference.deref(Closure), .{
        .parent_ns = runtime.root_ns,
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

fn generate(ctx: *EvalContext, source: Value, parameter: u16, mode: forward.Mode) Error!Value {
    const scope = ctx.activate();
    defer scope.deinit();
    if (source.typ == b.type_closure) {
        try requireFixedSourceClosure(source.obj.toRef().deref(Closure));
    }
    try preflight(ctx.runtime, ctx.runtime.root_ns, source);
    const kind: AdCache.Kind = switch (mode) {
        .derivative => .derivative,
        .jvp => .jvp,
        .full_jvp => .full_jvp,
    };
    const key = try cacheKeyFor(ctx.runtime, source, kind, parameter);
    if (try ctx.runtime.ad_cache.getValidated(ctx, key)) |cached| return cached;
    const bound = if (source.typ == b.type_closure)
        source
    else
        try bindCallable(ctx, source, try argumentCount(ctx, source));
    const result = try forward.generate(ctx, bound, parameter, mode);
    try ctx.runtime.ad_cache.put(ctx.runtime.gpa, key, result);
    return result;
}

pub fn jvpClosure(ctx: *EvalContext, primal: Value, parameter: usize) Error!Value {
    const index = std.math.cast(u16, parameter) orelse return error.ArityMismatch;
    return generate(ctx, primal, index, .jvp);
}

fn parameterIndex(closure: *const Closure, selector: ?Value) Error!u16 {
    if (closure.arglist.len == 0) return error.ArityMismatch;
    const value = selector orelse return 0;
    if (value.typ == b.type_i64) {
        const index = std.math.cast(u16, value.obj.toInt(i64)) orelse return error.InvalidSelector;
        if (index >= closure.arglist.len) return error.InvalidSelector;
        return index;
    }
    if (value.typ != b.type_symbol) return error.TypeMismatch;
    const symbol = value.obj.toPtr(skript.Sym);
    for (closure.arglist, 0..) |candidate, index| {
        if (candidate == symbol) return std.math.cast(u16, index) orelse error.ArityMismatch;
    }
    return error.InvalidSelector;
}

/// Methods retain a snapshot of their instance implementations, as before.
pub fn deriv(ctx: *EvalContext, ns: Value, _: Value, args: []const Value) Error!Value {
    if (args.len == 0 or args.len > 2) return error.ArityMismatch;
    const source = args[0];
    if (source.typ == b.type_method) {
        if (args.len != 1) return error.ArityMismatch;
        try preflight(ctx.runtime, ns, source);
        const method = source.obj.toRef().deref(skript.data.Method);
        var check_iterator = method.resolved.valueIterator();
        while (check_iterator.next()) |instance| {
            if (instance.*.typ == b.type_closure) {
                try requireFixedSourceClosure(instance.*.obj.toRef().deref(Closure));
            }
        }
        const reference = try ctx.runtime.store.create(skript.data.Method);
        const result = reference.deref(skript.data.Method);
        result.* = .{
            .id = try ctx.runtime.store.allocMethodId(),
            .revision = 1,
            .resolved = .init(ctx.runtime.static),
            .locked = false,
        };
        var iterator = method.resolved.iterator();
        while (iterator.next()) |entry| {
            try ctx.chargeWork(1, 1, .transform);
            try result.resolved.put(entry.key_ptr.*, try deriv(ctx, ns, .nil, &.{entry.value_ptr.*}));
        }
        return .method(reference.toObject());
    }
    if (source.typ == b.type_closure) {
        try requireFixedSourceClosure(source.obj.toRef().deref(Closure));
    }
    const index = if (source.typ == b.type_closure)
        try parameterIndex(source.obj.toRef().deref(Closure), if (args.len == 2) args[1] else null)
    else if (source.typ == b.type_intrinsic and args.len == 1)
        @as(u16, 0)
    else
        return error.TypeMismatch;
    return generate(ctx, source, index, .derivative);
}

pub fn argumentCount(ctx: *EvalContext, source: Value) Error!usize {
    if (source.typ == b.type_closure) {
        const closure = source.obj.toRef().deref(Closure);
        try requireFixedSourceClosure(closure);
        return closure.arglist.len;
    }
    if (source.typ == b.type_intrinsic) {
        const primitive = ctx.registry.idForNative(source.obj.toPtr(skript.FuncPtr)) orelse return error.Unsupported;
        const rule = (try rules.builtinSnapshot(ctx)).find(primitive) orelse return error.Unsupported;
        return rule.metadata.arity orelse error.Unsupported;
    }
    if (source.typ == b.type_method) {
        var iterator = source.obj.toRef().deref(skript.data.Method).resolved.valueIterator();
        var count: ?usize = null;
        while (iterator.next()) |instance| {
            const arity = try argumentCount(ctx, instance.*);
            if (count) |expected| {
                if (expected != arity) return error.ArityMismatch;
            } else count = arity;
        }
        return count orelse error.Unsupported;
    }
    return error.TypeMismatch;
}

pub fn unpackArguments(value: Value, destination: []Value) Error!void {
    if (destination.len == 1) {
        destination[0] = value;
        return;
    }
    var cursor = value;
    for (destination) |*slot| {
        if (cursor.typ != b.type_cons) return error.ArityMismatch;
        const cell = cursor.obj.toRef().deref([2]Value);
        slot.* = cell[0];
        cursor = cell[1];
    }
    if (!cursor.isNil()) return error.ArityMismatch;
}

pub fn checkTangent(ctx: *EvalContext, primal: Value, tangent: Value) Error!void {
    if (callables.isStatic(ctx, primal)) {
        if (!tangent.isNil()) return error.Unsupported;
        return;
    }
    if (ctx.runtime.space_registry.current().find(primal.typ)) |spec| {
        return spec.tangentCheck(ctx, tangent);
    }
    var spec = try tree.flatten(ctx.scratch, ctx, ctx.runtime.tree_registry.current(), primal, tree.Limits.generic);
    defer spec.deinit();
    const vector_space = try space.resolve(ctx, &spec);
    try vector_space.tangentCheck(ctx, tangent);
}

/// `(jvp f x v)` returns `(list y dy)`; multi-argument f takes lists x and v.
pub fn jvp(ctx: *EvalContext, ns: Value, _: Value, args: []const Value) Error!Value {
    if (args.len != 3) return error.ArityMismatch;
    const count = try argumentCount(ctx, args[0]);
    if (count == 0 or count > 127) return error.ArityMismatch;
    var arguments: [254]Value = undefined;
    const primals = arguments[0..count];
    const tangents = arguments[count..][0..count];
    try unpackArguments(args[1], primals);
    try unpackArguments(args[2], tangents);
    for (primals, tangents) |primal, tangent| try checkTangent(ctx, primal, tangent);
    const source = if (args[0].typ == b.type_method)
        try args[0].obj.toRef().deref(skript.data.Method).get(ctx.runtime, primals)
    else
        args[0];
    const pushforward = try generate(ctx, try callables.bind(ctx, source, primals), 0, .full_jvp);
    var outputs: [2]Value = undefined;
    var workspace = Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    try workspace.apply(ctx, pushforward, arguments[0 .. count * 2], &outputs);
    for (outputs) |value| if (value.typ == b.type_error) return value.errorCode();
    try checkTangent(ctx, outputs[0], outputs[1]);
    return skript.intrinsics.list.list(ctx, ns, .nil, &outputs);
}

pub fn gradient(ctx: *EvalContext, ns: Value, user: Value, args: []const Value) Error!Value {
    return ad_gradient.gradient(ctx, ns, user, args);
}

pub fn valueAndGradient(ctx: *EvalContext, ns: Value, user: Value, args: []const Value) Error!Value {
    return ad_gradient.valueAndGradient(ctx, ns, user, args);
}
