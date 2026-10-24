//! Public linear maps and reverse-mode composition over bound Code.
const std = @import("std");
const skript = @import("../root.zig");
const Code = skript.Code;
const Value = skript.Value;
const Runtime = skript.Runtime;
const EvalContext = skript.EvalContext;
const Error = skript.Error;
const Closure = skript.data.Closure;
const ClosureGuard = skript.data.ClosureGuard;
const b = skript.builtins;
const ad = @import("ad.zig");
const forward = @import("../autodiff/forward.zig");
const callables = @import("../autodiff/callable.zig");
const linear = @import("../autodiff/linearize.zig");
const transposition = @import("../autodiff/transpose.zig");
const tree = @import("../autodiff/tree.zig");
const space = @import("../autodiff/space.zig");

const max_arguments = 127;

const Handle = struct {
    runtime: *Runtime,
    region: *linear.Region,
    lifetime: *const ClosureGuard,
    raw: Value,
    inputs: []const Value,
    outputs: []const Value,
    input_spaces: []const space.SpaceSpec,
    output_spaces: []const space.SpaceSpec,
    transpose_of: ?*const Handle = null,
};

fn traceHandle(context: *const anyopaque, visitor: *skript.Store.MarkVisitor) anyerror!void {
    var handles: [skript.Store.MarkVisitor.max_guard_depth]*const Handle = undefined;
    var handle_count: usize = 0;
    var current: ?*const Handle = handleContext(context);
    while (current) |handle| {
        if (handle_count == handles.len) return error.UntracedAllocation;
        for (handles[0..handle_count]) |seen| {
            if (seen == handle) return error.UntracedAllocation;
        }
        handles[handle_count] = handle;
        handle_count += 1;
        try visitor.visitValue(handle.raw);
        const region_context: *const anyopaque = @ptrCast(handle.region);
        if (handle.lifetime.context != region_context) return error.UntracedAllocation;
        const trace = handle.lifetime.trace orelse return error.UntracedAllocation;
        try visitor.visitGuard(trace, handle.lifetime.context);
        handle.region.acquire() catch |err| switch (err) {
            error.Expired => {
                current = handle.transpose_of;
                continue;
            },
            else => return err,
        };
        {
            defer handle.region.release();
            for (handle.inputs) |value| try visitor.visitValue(value);
            for (handle.outputs) |value| try visitor.visitValue(value);
            for (handle.input_spaces) |*algebra| try linear.traceSpaceSpec(visitor, algebra);
            for (handle.output_spaces) |*algebra| try linear.traceSpaceSpec(visitor, algebra);
        }
        current = handle.transpose_of;
    }
}

fn handleContext(state: *const anyopaque) *const Handle {
    return @ptrCast(@alignCast(state));
}

fn checkHandle(runtime: *Runtime, state: *const anyopaque) Error!void {
    const handle = handleContext(state);
    if (runtime != handle.runtime) return error.Denied;
    if (handle.region.isClosed()) return error.Expired;
    try handle.lifetime.check(runtime, handle.lifetime.context);
    const closure = handle.raw.obj.toRef().deref(Closure);
    if (closure.guard) |guard| try guard.check(runtime, guard.context);
}

fn acquireHandle(runtime: *Runtime, state: *const anyopaque) Error!void {
    const handle = handleContext(state);
    try checkHandle(runtime, state);
    const acquire = handle.lifetime.acquire orelse return error.InvalidCode;
    try acquire(runtime, handle.lifetime.context);
}

fn releaseHandle(runtime: *Runtime, state: *const anyopaque) void {
    const handle = handleContext(state);
    const release = handle.lifetime.release orelse unreachable;
    release(runtime, handle.lifetime.context);
}

fn checkArguments(runtime: *Runtime, state: *const anyopaque, arguments: []const Value) Error!void {
    const handle = handleContext(state);
    try handle.region.acquire();
    defer handle.region.release();
    if (arguments.len != 1) return error.ArityMismatch;
    if (handle.inputs.len > max_arguments) return error.ArityMismatch;
    var values: [max_arguments]Value = undefined;
    try ad.unpackArguments(arguments[0], values[0..handle.inputs.len]);
    for (handle.input_spaces, values[0..handle.inputs.len]) |*algebra, value| {
        if (handle.transpose_of != null) {
            try algebra.cotangentCheck(runtime.context(), value);
        } else {
            try algebra.tangentCheck(runtime.context(), value);
        }
    }
}

fn getHandle(ctx: *EvalContext, value: Value) Error!*const Handle {
    if (value.typ != b.type_closure or value.obj == .null) return error.TypeMismatch;
    const closure = value.obj.toRef().deref(Closure);
    const guard = closure.guard orelse return error.TypeMismatch;
    if (guard.check != &checkHandle) return error.TypeMismatch;
    const handle = handleContext(guard.context);
    if (handle.runtime != ctx.runtime) return error.Denied;
    return handle;
}

fn emitNative(
    ctx: *EvalContext,
    builder: *Code.Builder,
    function: Code.FunctionId,
    block: Code.BlockId,
    native: skript.FuncPtr,
    arguments: []const Code.ValueId,
) Error!Code.ValueId {
    const primitive = ctx.registry.idForNative(native) orelse return error.Unsupported;
    return builder.addNode(function, block, .{ .primitive_call = .{
        .primitive = primitive,
        .args = try builder.addOperands(arguments),
    } }, .{});
}

fn addParameter(ctx: *EvalContext, builder: *Code.Builder, function: Code.FunctionId, index: usize) Error!Code.ValueId {
    var text: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&text, "linear_arg_{d}", .{index}) catch return error.Unsupported;
    const binding = try builder.addBinding(function, try ctx.runtime.store.getsym(name), .parameter, .{});
    const value = try builder.addValue(function);
    builder.bindings.items[@backingInt(binding)].value = value;
    try builder.addParameter(function, binding);
    return value;
}

fn finishCallable(
    ctx: *EvalContext,
    builder: *Code.Builder,
    function: Code.FunctionId,
    source: *const Closure,
    guard: ?*const ClosureGuard,
) Error!Value {
    const code = try builder.finish(ctx.scratch);
    code.owner = ctx.runtime;
    const program = try ctx.runtime.lowerCode(ctx.scratch, code);
    const lowered = program.fns[@backingInt(function)];
    const reference = try ctx.runtime.store.create(Closure);
    ctx.runtime.store.store(Closure, reference.deref(Closure), .{
        .parent_ns = source.parent_ns,
        .arglist = lowered.arglist,
        .source = source.source,
        .source_ref = source.source_ref,
        .ir = lowered.ir,
        .constants = lowered.constants,
        .nregs = lowered.nregs,
        .result_count = lowered.result_count,
        .zero_mask = lowered.zero_mask,
        .capture_syms = lowered.capture_syms,
        .captures = &.{},
        .guard = guard,
        .code = code,
        .function_id = function,
        .fns = program.fns,
    });
    return .closure(reference.toObject());
}

fn wrapHandle(ctx: *EvalContext, handle: *const Handle) Error!Value {
    const source = handle.raw.obj.toRef().deref(Closure);
    const code = source.code orelse return error.InvalidCode;
    const metadata = code.function(source.function_id) orelse return error.InvalidCode;
    if (metadata.has_rest) return error.Unsupported;
    if (source.arglist.len != handle.inputs.len or source.result_count != handle.outputs.len) {
        return error.InvalidCode;
    }
    for (handle.input_spaces) |*algebra| try algebra.validate();
    for (handle.output_spaces) |*algebra| try algebra.validate();
    if (handle.inputs.len > max_arguments or handle.outputs.len > max_arguments) return error.ArityMismatch;
    var builder = Code.Builder.init(ctx.runtime.static, ctx);
    const identity = try ctx.runtime.allocCodeIdentity();
    builder.id = identity.id;
    builder.revision = identity.revision;
    const function = try builder.addFunction(null, source.source_ref);
    builder.functions.items[@backingInt(function)].has_rest = false;
    builder.functions.items[@backingInt(function)].ad_level = metadata.ad_level;
    builder.functions.items[@backingInt(function)].allows_ad = metadata.allows_ad;
    builder.functions.items[@backingInt(function)].origin = .{ .code = code, .function = source.function_id };
    const block = try builder.addBlock(function);
    const seed = try addParameter(ctx, &builder, function, 0);
    var arguments: [max_arguments]Code.ValueId = undefined;
    if (handle.inputs.len == 1) {
        arguments[0] = seed;
    } else {
        var cursor = seed;
        for (arguments[0..handle.inputs.len]) |*argument| {
            argument.* = try emitNative(ctx, &builder, function, block, &skript.intrinsics.list.fst, &.{cursor});
            cursor = try emitNative(ctx, &builder, function, block, &skript.intrinsics.list.rst, &.{cursor});
        }
    }
    const callee = try builder.addNode(function, block, .{ .literal = handle.raw }, .{});
    const first = try builder.addNode(function, block, .{ .dynamic_call = .{
        .callee = callee,
        .args = try builder.addOperands(arguments[0..handle.inputs.len]),
        .result_count = @intCast(handle.outputs.len),
    } }, .{});
    var outputs: [max_arguments]Code.ValueId = undefined;
    for (outputs[0..handle.outputs.len], 0..) |*output, index| {
        output.* = @fromBackingInt(@intCast(@backingInt(first) + @as(u32, @intCast(index))));
    }
    const result = if (handle.outputs.len == 1)
        first
    else
        try emitNative(
            ctx,
            &builder,
            function,
            block,
            &skript.intrinsics.list.list,
            outputs[0..handle.outputs.len],
        );
    try builder.setTerminator(block, .{ .return_values = try builder.addOperands(&.{result}) });
    const guard = try ctx.runtime.static.create(ClosureGuard);
    guard.* = .{
        .context = handle,
        .check = &checkHandle,
        .trace = &traceHandle,
        .check_arguments = &checkArguments,
        .acquire = &acquireHandle,
        .release = &releaseHandle,
    };
    return finishCallable(ctx, &builder, function, source, guard);
}

const Prepared = struct {
    primal: Value,
    handle: *const Handle,
};

fn prepare(ctx: *EvalContext, callable: Value, argument: Value) Error!Prepared {
    if (callable.typ == b.type_closure) {
        if (callable.obj == .null) return error.TypeMismatch;
        try ad.requireFixedSourceClosure(callable.obj.toRef().deref(Closure));
    }
    const count = try ad.argumentCount(ctx, callable);
    if (count == 0 or count > max_arguments) return error.ArityMismatch;
    var primals: [max_arguments]Value = undefined;
    try ad.unpackArguments(argument, primals[0..count]);
    const selected = if (callable.typ == b.type_method)
        try callable.obj.toRef().deref(skript.data.Method).get(ctx.runtime, primals[0..count])
    else
        callable;
    const bound = if (selected.typ == b.type_closure) selected else try ad.bindCallable(ctx, selected, count);
    const result = try linear.linearize(ctx, bound, primals[0..count]);
    errdefer result.region.close();
    const raw = result.linear.obj.toRef().deref(Closure);
    const lifetime = raw.guard orelse return error.InvalidCode;
    const outputs = try ctx.runtime.static.alloc(Value, 1);
    const output_spaces = try ctx.runtime.static.alloc(space.SpaceSpec, 1);
    output_spaces[0] = try result.region.resolveSpace(ctx, result.primal);
    outputs[0] = try result.region.tangentPrototype(ctx, &output_spaces[0], result.primal);
    const handle = try ctx.runtime.static.create(Handle);
    handle.* = .{
        .runtime = ctx.runtime,
        .region = result.region,
        .lifetime = lifetime,
        .raw = result.linear,
        .inputs = result.region.expected_arguments,
        .outputs = outputs,
        .input_spaces = result.region.argument_spaces,
        .output_spaces = output_spaces,
    };
    return .{ .primal = result.primal, .handle = handle };
}

fn transposeHandle(ctx: *EvalContext, source: *const Handle) Error!*const Handle {
    try checkHandle(ctx.runtime, source);
    try source.region.acquire();
    defer source.region.release();
    if (source.transpose_of) |original| return original;
    const raw = try transposition.generate(ctx, source.raw, source.inputs, source.outputs, .{
        .region = source.region,
        .inputs = source.input_spaces,
        .outputs = source.output_spaces,
    });
    const inputs = try ctx.runtime.static.alloc(Value, source.outputs.len);
    for (source.output_spaces, inputs) |*algebra, *prototype| prototype.* = try algebra.cotangentZero(ctx);
    const outputs = try ctx.runtime.static.alloc(Value, source.inputs.len);
    for (source.input_spaces, outputs) |*algebra, *prototype| prototype.* = try algebra.cotangentZero(ctx);
    const result = try ctx.runtime.static.create(Handle);
    result.* = .{
        .runtime = ctx.runtime,
        .region = source.region,
        .lifetime = source.lifetime,
        .raw = raw,
        .inputs = inputs,
        .outputs = outputs,
        .transpose_of = source,
        .input_spaces = source.output_spaces,
        .output_spaces = source.input_spaces,
    };
    return result;
}

pub fn linearize(ctx: *EvalContext, ns: Value, _: Value, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    const prepared = try prepare(ctx, args[0], args[1]);
    errdefer prepared.handle.region.close();
    const callable = try wrapHandle(ctx, prepared.handle);
    return skript.intrinsics.list.list(ctx, ns, .nil, &.{ prepared.primal, callable });
}

pub fn transpose(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    return wrapHandle(ctx, try transposeHandle(ctx, try getHandle(ctx, args[0])));
}

pub fn vjp(ctx: *EvalContext, ns: Value, _: Value, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    const prepared = try prepare(ctx, args[0], args[1]);
    errdefer prepared.handle.region.close();
    const pullback = try wrapHandle(ctx, try transposeHandle(ctx, prepared.handle));
    return skript.intrinsics.list.list(ctx, ns, .nil, &.{ prepared.primal, pullback });
}

pub fn closeLinear(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    const handle = try getHandle(ctx, args[0]);
    const was_open = !handle.region.isClosed();
    handle.region.close();
    return .bool(was_open);
}

fn applyRaw(ctx: *EvalContext, handle: *const Handle, seed: Value, workspace: *Runtime.CallWorkspace) Error!Value {
    try checkHandle(ctx.runtime, handle);
    if (handle.inputs.len != 1 or handle.outputs.len > max_arguments) return error.ArityMismatch;
    var outputs: [max_arguments]Value = undefined;
    try workspace.apply(ctx, handle.raw, &.{seed}, outputs[0..handle.outputs.len]);
    for (outputs[0..handle.outputs.len]) |output| if (output.typ == b.type_error) return output.errorCode();
    return if (handle.outputs.len == 1)
        outputs[0]
    else
        skript.intrinsics.list.list(
            ctx,
            ctx.runtime.root_ns,
            .nil,
            outputs[0..handle.outputs.len],
        );
}

/// Rows follow the output TreeSpec leaf order; each row is an input cotangent tree.
pub fn jacobian(ctx: *EvalContext, ns: Value, _: Value, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    const prepared = try prepare(ctx, args[0], args[1]);
    defer prepared.handle.region.close();
    const pullback = try transposeHandle(ctx, prepared.handle);
    const vector_space = prepared.handle.output_spaces[0];
    const count = vector_space.dimension orelse return error.Unsupported;
    const rows = try ctx.scratch.alloc(Value, count);
    defer ctx.scratch.free(rows);
    var workspace = Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    for (rows, 0..) |*row, index| {
        try ctx.chargeWork(1, 1, .transform);
        row.* = try applyRaw(ctx, pullback, try vector_space.cotangentBasis(ctx, index), &workspace);
    }
    return skript.intrinsics.list.list(ctx, ns, .nil, rows);
}

test "Jacobian rejects missing and extra arguments before evaluation" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    try std.testing.expectError(error.ArityMismatch, runtime.evalString("(jacobian)"));
    try std.testing.expectError(error.ArityMismatch, runtime.evalString("(jacobian (fn (x) x))"));
    try std.testing.expectError(error.ArityMismatch, runtime.evalString("(jacobian (fn (x) x) 1.0 2.0)"));
}

test "reverse AD rejects variadic closures before publishing handles" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();

    try std.testing.expectError(
        error.Unsupported,
        runtime.evalString(
            "(linearize (fn (x . rest) (* x x)) (list 3.0 4.0))",
        ),
    );
    try std.testing.expectError(
        error.Unsupported,
        runtime.evalString("(vjp (fn (x . rest) (* x x)) (list 3.0 4.0))"),
    );
}

fn directional(ctx: *EvalContext, source: Value, seeds: []const Value) Error!Value {
    if (source.typ == b.type_closure) {
        if (source.obj == .null) return error.TypeMismatch;
        try ad.requireFixedSourceClosure(source.obj.toRef().deref(Closure));
    }
    const bound = if (source.typ == b.type_closure) source else try ad.bindCallable(ctx, source, seeds.len);
    const differentiated = try forward.generate(ctx, bound, 0, .full_jvp);
    const closure = differentiated.obj.toRef().deref(Closure);
    var builder = Code.Builder.init(ctx.runtime.static, ctx);
    const identity = try ctx.runtime.allocCodeIdentity();
    builder.id = identity.id;
    builder.revision = identity.revision;
    const function = try builder.addFunction(null, closure.source_ref);
    builder.functions.items[@backingInt(function)].has_rest = false;
    const code = closure.code orelse return error.InvalidCode;
    const metadata = code.function(closure.function_id) orelse return error.InvalidCode;
    builder.functions.items[@backingInt(function)].ad_level = metadata.ad_level;
    builder.functions.items[@backingInt(function)].allows_ad = metadata.allows_ad;
    builder.functions.items[@backingInt(function)].origin = .{
        .code = code,
        .function = closure.function_id,
    };
    const block = try builder.addBlock(function);
    var arguments: [max_arguments * 2]Code.ValueId = undefined;
    for (seeds, 0..) |seed, index| {
        arguments[index] = try addParameter(ctx, &builder, function, index);
        arguments[seeds.len + index] = try builder.addNode(function, block, .{ .literal = seed }, .{});
    }
    const callee = try builder.addNode(function, block, .{ .literal = differentiated }, .{});
    const result = try builder.addNode(function, block, .{ .dynamic_call = .{
        .callee = callee,
        .args = try builder.addOperands(arguments[0 .. seeds.len * 2]),
        .result_count = 2,
    } }, .{});
    const tangent: Code.ValueId = @fromBackingInt(@intCast(@backingInt(result) + 1));
    try builder.setTerminator(block, .{ .return_values = try builder.addOperands(&.{tangent}) });
    const guard = try ctx.runtime.static.create(ClosureGuard);
    const source_guard = closure.guard orelse return error.InvalidCode;
    guard.* = source_guard.*;
    guard.check_arguments = null;
    guard.trace = source_guard.trace;
    return finishCallable(ctx, &builder, function, closure, guard);
}

pub fn hvp(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    if (args.len != 3) return error.ArityMismatch;
    if (args[0].typ == b.type_closure) {
        if (args[0].obj == .null) return error.TypeMismatch;
        try ad.requireFixedSourceClosure(args[0].obj.toRef().deref(Closure));
    }
    const count = try ad.argumentCount(ctx, args[0]);
    if (count == 0 or count > max_arguments) return error.ArityMismatch;
    var primals: [max_arguments]Value = undefined;
    var seeds: [max_arguments]Value = undefined;
    try ad.unpackArguments(args[1], primals[0..count]);
    try ad.unpackArguments(args[2], seeds[0..count]);
    for (primals[0..count], seeds[0..count]) |primal, seed| try ad.checkTangent(ctx, primal, seed);
    const source = if (args[0].typ == b.type_method)
        try args[0].obj.toRef().deref(skript.data.Method).get(ctx.runtime, primals[0..count])
    else
        args[0];
    const specialized = try callables.bind(ctx, source, primals[0..count]);
    const prepared = try prepare(ctx, try directional(ctx, specialized, seeds[0..count]), args[1]);
    defer prepared.handle.region.close();
    if (!tree.isNumeric(prepared.primal)) return error.TypeMismatch;
    const pullback = try transposeHandle(ctx, prepared.handle);
    var workspace = Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    const cotangent = try applyRaw(ctx, pullback, try tree.one(prepared.primal.typ), &workspace);
    var components: [max_arguments]Value = undefined;
    try ad.unpackArguments(cotangent, components[0..count]);
    for (prepared.handle.input_spaces, components[0..count]) |*algebra, *component| {
        component.* = try algebra.gradientFromCotangent(ctx, component.*);
    }
    return if (count == 1)
        components[0]
    else
        skript.intrinsics.list.list(
            ctx,
            ctx.runtime.root_ns,
            .nil,
            components[0..count],
        );
}

fn testPointValue(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    const descriptor = try ctx.runtime.nsGet(ctx.runtime.root_ns, try ctx.runtime.store.getsym("DualPoint"));
    if (!descriptor.isType() or args[0].typ != descriptor.obj or args[0].obj == .null) return error.TypeMismatch;
    return .f64(args[0].obj.toRef().deref(f64).*);
}

fn installDualPoint(runtime: *Runtime) !Value {
    const registry = try runtime.intrinsics.publish(&.{.{
        .stable_name = "test.reverse.point-value",
        .invoke = .nativePtr(&testPointValue),
        .effects = .{ .state_read = true },
        .reads_argument_state = true,
        .callbacks = .none,
        .resources = .native,
        .suspension = .never,
    }});
    if (registry.idForNative(&testPointValue) == null) return error.InvalidCode;
    const name = try runtime.store.getsym("DualPoint");
    const type_ref = try runtime.store.create(skript.Type);
    runtime.store.store(skript.Type, type_ref.deref(skript.Type), .{
        .meta = b.type_type,
        .name = skript.Object.fromPtr(name),
    });
    try runtime.nsBind(runtime.root_ns, name, .typeValue(type_ref.toObject()));
    try runtime.nsBind(runtime.root_ns, try runtime.store.getsym("point-value"), .intrinsic(&testPointValue));
    const value_ref = try runtime.store.create(f64);
    value_ref.deref(f64).* = 3.0;
    const point = Value.init(type_ref.toObject(), value_ref.toObject());
    try runtime.nsBind(runtime.root_ns, try runtime.store.getsym("dual-point"), point);
    const published = try runtime.evalString(
        \\(register-ad-space DualPoint 1 1 (type 0.0) (type (list 0.0))
        \\  (fn (coordinates) (fst coordinates))
        \\  (fn (coordinates) (list (/ (fst coordinates) 3.0)))
        \\  (fn () 0.0) (fn (x y) (+ x y)) (fn (x k) (* x k)) nil
        \\  (fn () (list 0.0))
        \\  (fn (x y) (list (+ (fst x) (fst y))))
        \\  (fn (x k) (list (* (fst x) k))) nil
        \\  (fn (direction cotangent) (* 3.0 (* direction (fst cotangent))))
        \\  (hash-map :tangent-basis (fn (index) 1.0)))
        \\(register-ad-rule
        \\  :{:primitive point-value :implementation-revision 1 :rule-revision 1
        \\    :capabilities (list :jvp)
        \\    :metadata :{:arity 1 :linearity :linear :allocation :none :higher-order #t}
        \\    :jvp :{:kind :hook :revision 1
        \\      :callable (fn (primals tangents)
        \\        (list (point-value (fst primals)) (fst tangents)))}})
    );
    if (published.typ != b.type_i64) return error.InvalidCode;
    return point;
}

test "public VJP uses non-self-dual cotangents without a metric" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const point = try installDualPoint(runtime);
    const primal = try runtime.evalString(
        \\(def point-result (vjp (fn (p) (* (point-value p) (point-value p))) dual-point))
        \\(def point-pullback (fst (rst point-result)))
        \\(fst point-result)
    );
    try std.testing.expectEqual(Value.f64(9.0), primal);
    const pulled = try runtime.evalString("(point-pullback 5.0)");
    const component = try skript.intrinsics.list.fst(runtime.context(), runtime.root_ns, .nil, &.{pulled});
    try std.testing.expectEqual(Value.f64(10.0), component);
    const algebra = runtime.space_registry.current().find(point.typ) orelse return error.TestUnexpectedResult;
    const paired = try algebra.pair(runtime.context(), .f64(7.0), pulled);
    try std.testing.expectEqual(Value.f64(210.0), paired);
    try std.testing.expectError(error.Unsupported, algebra.gradientFromCotangent(runtime.context(), pulled));
    try std.testing.expectError(error.Unsupported, runtime.evalString(
        "((gradient (fn (p) (* (point-value p) (point-value p)))) dual-point)",
    ));
    try std.testing.expectEqual(Value.f64(2.0), try runtime.evalString(
        "(fst (fst (jacobian (fn (p) (* (point-value p) (point-value p))) dual-point)))",
    ));
    try std.testing.expectEqual(Value.f64(4.0), try runtime.evalString("(fst (point-pullback 2.0))"));
    try std.testing.expectError(error.TypeMismatch, runtime.evalString("(point-pullback (list 5.0))"));
    const zero = try runtime.evalString(
        \\(def point-zero (fst (rst (vjp (fn (p) 7.0) dual-point))))
        \\(fst (point-zero 1.0))
    );
    try std.testing.expectEqual(Value.f64(0.0), zero);
}

test "double transpose restores the tangent domain of a custom space" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const point = try installDualPoint(runtime);
    const result = try runtime.evalString(
        \\(def point-linear (fst (rst (linearize (fn (p) p) dual-point))))
        \\(def point-transposed (transpose point-linear))
        \\(def point-restored (transpose point-transposed))
        \\(point-restored 2.0)
    );
    try std.testing.expectEqual(Value.f64(2.0), result);
    const pulled = try runtime.evalString("(point-transposed (list 5.0))");
    const algebra = runtime.space_registry.current().find(point.typ) orelse return error.TestUnexpectedResult;
    try algebra.cotangentCheck(runtime.context(), pulled);
    try std.testing.expectEqual(Value.f64(5.0), try runtime.evalString("(fst (point-transposed (list 5.0)))"));
    try std.testing.expectEqual(Value.bool(true), try runtime.evalString("(close-linear point-linear)"));
    try std.testing.expectError(error.Expired, runtime.evalString("(point-restored 2.0)"));
}

test "retained pullbacks reject mutation inside algebra hook dependencies" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const point = try installDualPoint(runtime);
    const prepared = try prepare(runtime.context(), try runtime.evalString(
        "(fn (p) (* (point-value p) (point-value p)))",
    ), point);
    defer prepared.handle.region.close();
    const pullback = try transposeHandle(runtime.context(), prepared.handle);
    var workspace = Runtime.CallWorkspace.init(std.testing.allocator);
    defer workspace.deinit();
    const initial = try applyRaw(runtime.context(), pullback, .f64(1.0), &workspace);
    try prepared.handle.input_spaces[0].cotangentCheck(runtime.context(), initial);
    const prior = runtime.space_registry.current().find(point.typ) orelse return error.TestUnexpectedResult;
    const revision = try runtime.space_registry.publish(&.{.{
        .primal_type = point.typ,
        .implementation_revision = prior.implementation_revision + 1,
        .dimension = prior.dimension,
        .tangent = prior.tangent,
        .cotangent = prior.cotangent,
        .pairing = prior.pairing,
        .metric = prior.metric,
    }});
    if (revision.find(point.typ) == null) return error.InvalidCode;
    try std.testing.expectError(error.Unsupported, applyRaw(runtime.context(), pullback, .f64(1.0), &workspace));
}

test "gradient and HVP identify a nominal cotangent through its metric" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const point = try installDualPoint(runtime);
    const prior = runtime.space_registry.current().find(point.typ) orelse return error.TestUnexpectedResult;
    const metric = try runtime.evalString("(fn (cotangent) (* 3.0 (fst cotangent)))");
    const registered = try runtime.space_registry.publish(&.{.{
        .primal_type = point.typ,
        .implementation_revision = 2,
        .dimension = prior.dimension,
        .tangent = prior.tangent,
        .cotangent = prior.cotangent,
        .pairing = prior.pairing,
        .metric = .{ .hook = .{ .namespace = runtime.root_ns, .function = metric } },
    }});
    if (registered.find(point.typ) == null) return error.InvalidCode;
    try std.testing.expectEqual(Value.f64(6.0), try runtime.evalString(
        "((gradient (fn (p) (* (point-value p) (point-value p)))) dual-point)",
    ));
    try std.testing.expectEqual(Value.f64(8.0), try runtime.evalString(
        "(hvp (fn (x) (* x x)) 3.0 4.0)",
    ));
}

test "reverse pullback retains captured dependencies across collection" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const source = try runtime.evalString(
        "((fn (saved) (fn (x) (* (* (fst saved) x) x))) (list 2.0))",
    );
    const prepared = try prepare(runtime.context(), source, Value.f64(3.0));
    defer prepared.handle.region.close();
    const pullback = try wrapHandle(
        runtime.context(),
        try transposeHandle(runtime.context(), prepared.handle),
    );
    var root: Runtime.ValueRoot = .{};
    try runtime.registerValueRoot(&root, pullback);
    defer runtime.unregisterValueRoot(&root) catch unreachable;

    try runtime.collect();
    try std.testing.expectEqual(
        Value.f64(12.0),
        try runtime.apply(runtime.root_ns, pullback, &.{Value.f64(1.0)}),
    );
}

test "closed public linear handles remain safe to trace after collection" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    try std.testing.expectEqual(Value.bool(true), try runtime.evalString(
        \\(def closed-linear (fst (rst (linearize (fn (x) (* x x)) 3.0))))
        \\(def closed-transpose (transpose closed-linear))
        \\(close-linear closed-linear)
    ));
    try runtime.collect();
    try std.testing.expectError(error.Expired, runtime.evalString("(closed-linear 1.0)"));
    try std.testing.expectError(error.Expired, runtime.evalString("(closed-transpose 1.0)"));
}
