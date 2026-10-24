const std = @import("std");
const skript = @import("../root.zig");
const Value = skript.Value;
const EvalContext = skript.EvalContext;
const Code = skript.Code;
const Closure = skript.data.Closure;
const ClosureGuard = skript.data.ClosureGuard;
const Error = skript.Error;
const b = skript.builtins;
const forward = @import("forward.zig");

const SourceUnit = @import("../SourceUnit.zig");

const max_traced_source_units: usize = 256;
const Source = SourceUnit.SourceUnit;

const SourceUnits = struct {
    units: [max_traced_source_units]*const Source = undefined,
    len: usize = 0,

    fn trace(
        self: *SourceUnits,
        source: SourceUnit.Ref,
        visitor: *skript.Store.MarkVisitor,
    ) anyerror!void {
        const unit = source.unit orelse return;
        for (self.units[0..self.len]) |seen| {
            if (seen == unit) return;
        }
        if (self.len == self.units.len) return error.UntracedAllocation;
        self.units[self.len] = unit;
        self.len += 1;
        try visitor.visitValue(unit.datum);
        for (unit.nodes) |node| try visitor.visitValue(node.datum);
    }
};

pub fn traceCodeGraph(
    code: *const Code.Code,
    visitor: *skript.Store.MarkVisitor,
) anyerror!void {
    var source_units: SourceUnits = .{};
    for (code.functions) |function| {
        try visitor.visitValue(function.source_value);
        try visitor.visitValue(function.arglist);
        try visitor.visitValue(function.body);
        try source_units.trace(function.source, visitor);
    }
    for (code.bindings) |binding| try source_units.trace(binding.source, visitor);
    for (code.globals) |global| try source_units.trace(global.source, visitor);
    for (code.nodes) |node| {
        try source_units.trace(node.source, visitor);
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

pub fn traceClosureRef(
    closure: *const Closure,
    visitor: *skript.Store.MarkVisitor,
) anyerror!void {
    try visitor.visitAddress(@intFromPtr(closure));
}

const Guard = struct {
    runtime: *skript.Runtime,
    source: *const Closure,
    code: *const Code.Code,
    function: Code.FunctionId,
    namespace: Value,
    captures: []const Value,
    frozen: []const Value,
    inherited: ?*const ClosureGuard,
};

fn traceGuard(context: *const anyopaque, visitor: *skript.Store.MarkVisitor) anyerror!void {
    const guard: *const Guard = @ptrCast(@alignCast(context));
    try visitor.visitValue(guard.namespace);
    for (guard.captures) |value| try visitor.visitValue(value);
    for (guard.frozen) |value| try visitor.visitValue(value);
    try traceClosureRef(guard.source, visitor);
    try traceCodeGraph(guard.code, visitor);
    if (guard.inherited) |inherited| {
        const trace = inherited.trace orelse return error.UntracedAllocation;
        try visitor.visitGuard(trace, inherited.context);
    }
}

pub fn isStatic(ctx: *const EvalContext, value: Value) bool {
    if (ctx.runtime.space_registry.current().find(value.typ) != null) return false;
    return value.typ == b.type_closure or value.typ == b.type_method or value.typ == b.type_intrinsic;
}

fn check(runtime: *skript.Runtime, state: *const anyopaque) Error!void {
    const guard: *const Guard = @ptrCast(@alignCast(state));
    if (runtime != guard.runtime or guard.source.code != guard.code or
        guard.source.function_id != guard.function or
        !std.meta.eql(guard.source.parent_ns, guard.namespace)) return error.Denied;
    if (guard.source.captures.len != guard.captures.len) return error.Denied;
    for (guard.source.captures, guard.captures) |actual, expected| {
        try runtime.context().chargeWork(1, 1, .transform);
        if (!std.meta.eql(actual, expected)) return error.Denied;
    }
    if (guard.inherited) |inherited| try inherited.check(runtime, inherited.context);
}

fn checkArguments(runtime: *skript.Runtime, state: *const anyopaque, arguments: []const Value) Error!void {
    const guard: *const Guard = @ptrCast(@alignCast(state));
    try check(runtime, state);
    if (arguments.len != guard.frozen.len) return error.ArityMismatch;
    for (arguments, guard.frozen) |actual, frozen| {
        try runtime.context().chargeWork(1, 1, .transform);
        if (!frozen.isNil() and !std.meta.eql(actual, frozen)) return error.Denied;
    }
    if (guard.inherited) |inherited| {
        if (inherited.check_arguments) |check_args| try check_args(runtime, inherited.context, arguments);
    }
}

fn acquire(runtime: *skript.Runtime, state: *const anyopaque) Error!void {
    const guard: *const Guard = @ptrCast(@alignCast(state));
    try check(runtime, state);
    if (guard.inherited) |inherited| {
        if (inherited.acquire) |pin| try pin(runtime, inherited.context);
    }
}

fn release(runtime: *skript.Runtime, state: *const anyopaque) void {
    const guard: *const Guard = @ptrCast(@alignCast(state));
    if (guard.inherited) |inherited| {
        if (inherited.release) |unpin| unpin(runtime, inherited.context);
    }
}

pub fn bind(ctx: *EvalContext, source: Value, primals: []const Value) Error!Value {
    if (source.typ == b.type_closure) {
        if (source.obj == .null) return error.Unsupported;
        const closure = source.obj.toRef().deref(Closure);
        const code = closure.code orelse return error.Unsupported;
        const function = code.function(closure.function_id) orelse return error.InvalidCode;
        if (function.has_rest) return error.Unsupported;
    }
    var count: usize = 0;
    for (primals) |value| count += @intFromBool(isStatic(ctx, value));
    if (count == 0) return source;
    const bound = if (source.typ == b.type_closure)
        source
    else
        try skript.intrinsics.ad.bindCallable(ctx, source, primals.len);
    if (bound.obj == .null) return error.Unsupported;
    const original = bound.obj.toRef().deref(Closure);
    const code = original.code orelse return error.Unsupported;
    if (code.owner != @as(?*const anyopaque, ctx.runtime)) return error.Denied;
    const function = code.function(original.function_id) orelse return error.InvalidCode;
    if (function.has_rest) return error.Unsupported;
    if (function.parameter_count != primals.len) return error.ArityMismatch;
    const scope = ctx.activate();
    defer scope.deinit();
    const nodes = try ctx.runtime.static.dupe(Code.Node, code.nodes);
    const parameters = code.parameters[function.parameter_start..][0..function.parameter_count];
    for (nodes) |*node| {
        try ctx.chargeWork(1, 1, .transform);
        const binding = switch (node.operation) {
            .local_read => |value| value,
            .global_read => |cell| code.globals[@backingInt(cell)].binding,
            else => continue,
        };
        for (parameters, primals) |parameter, primal| {
            try ctx.chargeWork(1, 1, .transform);
            if (binding == parameter and isStatic(ctx, primal)) {
                node.operation = .{ .literal = primal };
                break;
            }
        }
    }
    const identity = try ctx.runtime.allocCodeIdentity();
    const specialized = try ctx.runtime.static.create(Code.Code);
    specialized.* = code.*;
    specialized.id = identity.id;
    specialized.revision = identity.revision;
    specialized.nodes = nodes;
    try specialized.validate(ctx.scratch, ctx);
    return materialize(ctx, original, specialized, primals);
}

fn materialize(
    ctx: *EvalContext,
    original: *const Closure,
    code: *const Code.Code,
    primals: []const Value,
) Error!Value {
    const source_code = original.code orelse return error.Unsupported;
    const frozen = try ctx.runtime.static.alloc(Value, primals.len);
    for (primals, frozen) |value, *slot| {
        slot.* = if (isStatic(ctx, value)) value else .nil;
    }
    const guard = try ctx.runtime.static.create(Guard);
    guard.* = .{
        .runtime = ctx.runtime,
        .source = original,
        .code = source_code,
        .function = original.function_id,
        .namespace = original.parent_ns,
        .captures = try ctx.runtime.static.dupe(Value, original.captures),
        .frozen = frozen,
        .inherited = original.guard,
    };
    const lifetime = try ctx.runtime.static.create(ClosureGuard);
    lifetime.* = .{
        .context = guard,
        .check = &check,
        .trace = &traceGuard,
        .check_arguments = &checkArguments,
        .acquire = &acquire,
        .release = &release,
    };
    const lowered = try ctx.runtime.lowerCode(ctx.scratch, code);
    const function = lowered.fns[@backingInt(original.function_id)];
    var closure = original.*;
    closure.code = code;
    closure.ir = function.ir;
    closure.constants = function.constants;
    closure.nregs = function.nregs;
    closure.zero_mask = function.zero_mask;
    closure.fns = lowered.fns;
    closure.guard = lifetime;
    const reference = try ctx.runtime.store.create(Closure);
    ctx.runtime.store.store(Closure, reference.deref(Closure), closure);
    return .closure(reference.toObject());
}

test "AD rejects variadic source closures and keeps fixed differentiation" {
    const runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();

    try std.testing.expectError(
        error.Unsupported,
        runtime.evalString("((deriv (fn (x . rest) (* x x))) 3.0)"),
    );
    try std.testing.expectEqual(
        Value.f64(6.0),
        try runtime.evalString("((deriv (fn (x) (* x x))) 3.0)"),
    );
}

test "generated derivative retains captured Values across collection" {
    const runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const source = try runtime.evalString(
        "((fn (saved) (fn (x) (* (* (fst saved) x) x))) (list 2.0))",
    );
    const derivative = try forward.generate(runtime.context(), source, 0, .derivative);
    var root: skript.Runtime.ValueRoot = .{};
    try runtime.registerValueRoot(&root, derivative);
    defer runtime.unregisterValueRoot(&root) catch unreachable;

    try runtime.collect();
    try std.testing.expectEqual(
        Value.f64(12.0),
        try runtime.apply(runtime.root_ns, derivative, &.{Value.f64(3.0)}),
    );
}

test "runtime callable inputs specialize guarded JVP and reverse programs" {
    const runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    try std.testing.expectEqual(Value.bool(true), try runtime.evalString(
        \\(begin
        \\  (def apply-one (fn (helper x) (helper x)))
        \\  (def helper-square (fn (x) (* x x)))
        \\  (def inputs (list helper-square 3.0))
        \\  (def direction (list nil 1.0))
        \\  (def forward-result (jvp apply-one inputs direction))
        \\  (def linear-result (linearize apply-one inputs))
        \\  (def reverse-result (vjp apply-one inputs))
        \\  (and (equal? forward-result (list 9.0 6.0))
        \\       (and (= ((fst (rst linear-result)) direction) 6.0)
        \\            (equal? ((fst (rst reverse-result)) 1.0) (list nil 6.0)))))
    ));
}

test "specialized callable guards reject changed targets and effectful helpers" {
    const runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const source = try runtime.evalString("(fn (helper x) (helper x))");
    const square = try runtime.evalString("(fn (x) (* x x))");
    const cube = try runtime.evalString("(fn (x) (* x (* x x)))");
    const specialized = try bind(ctx, source, &.{ square, .f64(3.0) });
    const derivative = try forward.generate(ctx, specialized, 0, .full_jvp);
    var workspace = skript.Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    var outputs: [2]Value = undefined;
    try workspace.apply(ctx, derivative, &.{ square, .f64(3.0), .nil, .f64(1.0) }, &outputs);
    try std.testing.expectEqual(Value.f64(6.0), outputs[1]);
    try std.testing.expectError(error.Denied, workspace.apply(
        ctx,
        derivative,
        &.{ cube, .f64(3.0), .nil, .f64(1.0) },
        &outputs,
    ));
    const effectful = try runtime.evalString("(fn (x) (if false (@write \"denied\") x))");
    const unsafe = try bind(ctx, source, &.{ effectful, .f64(3.0) });
    try std.testing.expectError(error.Unsupported, forward.generate(ctx, unsafe, 0, .full_jvp));
}

test "branch selected closure calls retain selected derivatives and all branch effects" {
    const runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const source = try runtime.evalString(
        "(fn (x) ((if (> x 0.0) (fn (y) (* y y)) (fn (y) (* y (* y y)))) x))",
    );
    const derivative = try forward.generate(runtime.context(), source, 0, .derivative);
    try std.testing.expectEqual(Value.f64(6.0), try runtime.apply(runtime.root_ns, derivative, &.{.f64(3.0)}));
    try std.testing.expectEqual(Value.f64(27.0), try runtime.apply(runtime.root_ns, derivative, &.{.f64(-3.0)}));
    const unsafe = try runtime.evalString(
        "(fn (x) ((if (> x 0.0) (fn (y) (* y y)) (fn (y) (begin (@write \"denied\") y))) x))",
    );
    try std.testing.expectError(
        error.Unsupported,
        forward.generate(runtime.context(), unsafe, 0, .derivative),
    );
}

test "selected callable inputs and active captured closures compose through higher AD" {
    const runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const square = try runtime.evalString("(fn (x) (* x x))");
    const cube = try runtime.evalString("(fn (x) (* x (* x x)))");
    const source = try runtime.evalString("(fn (a b x) ((if (> x 0.0) a b) x))");
    const bound = try bind(runtime.context(), source, &.{ square, cube, .f64(-3.0) });
    const jvp = try forward.generate(runtime.context(), bound, 0, .full_jvp);
    var workspace = skript.Runtime.CallWorkspace.init(runtime.context().scratch);
    defer workspace.deinit();
    var outputs: [2]Value = undefined;
    try workspace.apply(runtime.context(), jvp, &.{ square, cube, .f64(-3.0), .nil, .nil, .f64(1.0) }, &outputs);
    try std.testing.expectEqual(Value.f64(-27.0), outputs[0]);
    try std.testing.expectEqual(Value.f64(27.0), outputs[1]);
    const captured = try runtime.evalString(
        "(fn (x) ((if (> x 0.0) (fn (y) (* x y)) (fn (y) (* y (* x x)))) x))",
    );
    const first = try forward.generate(runtime.context(), captured, 0, .derivative);
    const second = try forward.generate(runtime.context(), first, 0, .derivative);
    try std.testing.expectEqual(Value.f64(2.0), try runtime.apply(runtime.root_ns, second, &.{.f64(3.0)}));
    try std.testing.expectEqual(Value.f64(-18.0), try runtime.apply(runtime.root_ns, second, &.{.f64(-3.0)}));
}

/// Return alias or incoming edge values; the caller frees them with ctx.scratch.
pub fn incoming(
    ctx: *const EvalContext,
    code: *const Code.Code,
    value: Code.ValueId,
) Error!?[]Code.ValueId {
    if (value == .invalid or @backingInt(value) >= code.values.len) return null;
    for (code.nodes) |node| {
        try ctx.chargeWork(1, 1, .transform);
        if (node.result != value) continue;
        const binding = switch (node.operation) {
            .local_read => |id| id,
            .global_read => |id| blk: {
                const cell = code.globals[@backingInt(id)];
                if (cell.binding == .invalid) return null;
                var writes: usize = 0;
                for (code.nodes) |write| {
                    try ctx.chargeWork(1, 1, .transform);
                    if (write.operation != .global_write or
                        write.operation.global_write.cell != id) continue;
                    const bound_value = code.bindings[@backingInt(cell.binding)].value;
                    if (write.operation.global_write.value != bound_value) return null;
                    writes += 1;
                }
                if (writes != 1) return null;
                break :blk cell.binding;
            },
            else => return null,
        };
        const local = code.bindings[@backingInt(binding)];
        const sources = try ctx.scratch.dupe(Code.ValueId, &.{local.value});
        return sources;
    }
    for (code.blocks) |block| {
        try ctx.chargeWork(@as(usize, block.param_count) + 1, 1, .transform);
        if (block.function != code.values[@backingInt(value)]) continue;
        const parameters = code.block_parameters[block.param_start..][0..block.param_count];
        const index = std.mem.indexOfScalar(Code.ValueId, parameters, value) orelse continue;
        const sources = try incomingEdges(ctx, code, block.id, index);
        return sources;
    }
    return null;
}

fn incomingEdges(
    ctx: *const EvalContext,
    code: *const Code.Code,
    target: Code.BlockId,
    index: usize,
) Error!?[]Code.ValueId {
    var values: std.ArrayList(Code.ValueId) = .empty;
    defer values.deinit(ctx.scratch);
    for (code.blocks) |block| {
        try ctx.chargeWork(1, 1, .transform);
        var edges: [2]Code.Edge = @splat(.{ .target = .invalid });
        switch (block.terminator) {
            .jump => |edge| edges[0] = edge,
            .branch => |branch| edges = .{ branch.then_edge, branch.else_edge },
            else => continue,
        }
        for (edges) |edge| {
            if (edge.target != target) continue;
            if (index >= edge.args.len) return error.InvalidCode;
            const offset = @as(usize, edge.args.start) + index;
            if (offset >= code.operands.len) return error.InvalidCode;
            try values.append(ctx.scratch, code.operands[offset]);
        }
    }
    if (values.items.len == 0) return null;
    const result = try values.toOwnedSlice(ctx.scratch);
    return result;
}

pub fn joinAncestors(
    allocator: std.mem.Allocator,
    ctx: *const EvalContext,
    code: *const Code.Code,
) Error![]bool {
    try ctx.chargeWork(code.values.len, 1, .transform);
    const marked = try allocator.alloc(bool, code.values.len);
    @memset(marked, false);
    const queue = try allocator.alloc(Code.ValueId, code.values.len);
    defer allocator.free(queue);
    var length: usize = 0;
    for (code.block_parameters) |value| try enqueue(marked, queue, &length, value);
    var cursor: usize = 0;
    while (cursor < length) : (cursor += 1) {
        const sources = (try incoming(ctx, code, queue[cursor])) orelse continue;
        defer ctx.scratch.free(sources);
        for (sources) |value| try enqueue(marked, queue, &length, value);
    }
    return marked;
}

fn enqueue(marked: []bool, queue: []Code.ValueId, length: *usize, value: Code.ValueId) Error!void {
    const index = @backingInt(value);
    if (index >= marked.len) return error.InvalidCode;
    if (marked[index]) return;
    std.debug.assert(length.* < queue.len);
    marked[index] = true;
    queue[length.*] = value;
    length.* += 1;
}
