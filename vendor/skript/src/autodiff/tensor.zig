const std = @import("std");
const skript = @import("../root.zig");
const Code = @import("../code.zig");

const Error = skript.Error;
const EvalContext = skript.EvalContext;
const Runtime = skript.Runtime;
const Value = skript.Value;
const b = skript.builtins;
const tensor_intrin = skript.intrinsics.tensor;
const InnerType = tensor_intrin.InnerType;
const TensorHolder = tensor_intrin.TensorHolder;

const TestKernelKind = enum {
    unary_double,
    binary_add,
    binary_mul,
    impure,
    binary_impure,
    tangent_error,
};

const TestGuardState = struct {
    valid: bool,
};

fn checkTestGuard(_: *Runtime, raw: *const anyopaque) Error!void {
    const state: *const TestGuardState = @ptrCast(@alignCast(raw));
    if (!state.valid) return error.Denied;
}

fn addTestParameter(
    builder: *Code.Builder,
    runtime: *Runtime,
    function: Code.FunctionId,
    block: Code.BlockId,
    name: []const u8,
) !Code.ValueId {
    const binding = try builder.addBinding(
        function,
        try runtime.store.getsym(name),
        .parameter,
        .{},
    );
    builder.bindings.items[@backingInt(binding)].value = try builder.addValue(function);
    try builder.addParameter(function, binding);
    return builder.addNode(function, block, .{ .local_read = binding }, .{});
}

fn addTestArithmetic(
    builder: *Code.Builder,
    function: Code.FunctionId,
    block: Code.BlockId,
    operation: Code.ArithOp,
    left: Code.ValueId,
    right: Code.ValueId,
) !Code.ValueId {
    return builder.addNode(function, block, .{ .arithmetic = .{
        .op = operation,
        .left = left,
        .right = right,
    } }, .{});
}

fn makeTestKernel(runtime: *Runtime, kind: TestKernelKind, guard_valid: bool) !Value {
    var builder = Code.Builder.init(runtime.static, runtime.context());
    const identity = try runtime.allocCodeIdentity();
    builder.id = identity.id;
    builder.revision = identity.revision;
    const function = try builder.addFunction(null, .{});
    builder.functions.items[@backingInt(function)].result_count = 2;
    const block = try builder.addBlock(function);
    const arity: usize = switch (kind) {
        .unary_double, .tangent_error => 2,
        .binary_add, .binary_mul, .binary_impure => 4,
        .impure => 2,
    };
    const names = [_][]const u8{ "p0", "p1", "t0", "t1" };
    var parameters: [4]Code.ValueId = undefined;
    for (names[0..arity], 0..) |name, index| {
        parameters[index] = try addTestParameter(&builder, runtime, function, block, name);
    }

    const results: [2]Code.ValueId = switch (kind) {
        .unary_double => .{
            try addTestArithmetic(&builder, function, block, .add, parameters[0], parameters[0]),
            try addTestArithmetic(&builder, function, block, .add, parameters[1], parameters[1]),
        },
        .binary_add => .{
            try addTestArithmetic(&builder, function, block, .add, parameters[0], parameters[1]),
            try addTestArithmetic(&builder, function, block, .add, parameters[2], parameters[3]),
        },
        .binary_mul => blk: {
            const primal = try addTestArithmetic(
                &builder,
                function,
                block,
                .mul,
                parameters[0],
                parameters[1],
            );
            const tangent_left = try addTestArithmetic(
                &builder,
                function,
                block,
                .mul,
                parameters[2],
                parameters[1],
            );
            const tangent_right = try addTestArithmetic(
                &builder,
                function,
                block,
                .mul,
                parameters[0],
                parameters[3],
            );
            break :blk .{
                primal,
                try addTestArithmetic(
                    &builder,
                    function,
                    block,
                    .add,
                    tangent_left,
                    tangent_right,
                ),
            };
        },
        .impure => blk: {
            const primitive = runtime.intrinsics.registryVersion().idForNative(
                &skript.intrinsics.print.write,
            ) orelse return error.TestUnexpectedResult;
            _ = try builder.addNode(function, block, .{ .primitive_call = .{
                .primitive = primitive,
                .args = try builder.addOperands(parameters[0..1]),
            } }, .{});
            break :blk .{ parameters[0], parameters[1] };
        },
        .binary_impure => blk: {
            const primitive = runtime.intrinsics.registryVersion().idForNative(
                &skript.intrinsics.print.write,
            ) orelse return error.TestUnexpectedResult;
            _ = try builder.addNode(function, block, .{ .primitive_call = .{
                .primitive = primitive,
                .args = try builder.addOperands(parameters[0..1]),
            } }, .{});
            break :blk .{ parameters[0], parameters[2] };
        },
        .tangent_error => .{
            parameters[0],
            try builder.addNode(
                function,
                block,
                .{ .literal = Value.err(error.Unsupported) },
                .{},
            ),
        },
    };
    try builder.setTerminator(
        block,
        .{ .return_values = try builder.addOperands(&results) },
    );
    const code = try builder.finish(runtime.context().scratch);
    code.owner = runtime;
    const program = try runtime.lowerCode(runtime.context().scratch, code);
    const lowered = program.fns[@backingInt(function)];

    const guard_state = try runtime.static.create(TestGuardState);
    guard_state.* = .{ .valid = guard_valid };
    const guard = try runtime.static.create(skript.data.ClosureGuard);
    guard.* = .{ .context = guard_state, .check = &checkTestGuard };
    const reference = try runtime.store.create(skript.data.Closure);
    runtime.store.store(skript.data.Closure, reference.deref(skript.data.Closure), .{
        .parent_ns = runtime.root_ns,
        .arglist = lowered.arglist,
        .ir = lowered.ir,
        .constants = lowered.constants,
        .nregs = lowered.nregs,
        .result_count = lowered.result_count,
        .zero_mask = lowered.zero_mask,
        .guard = guard,
        .code = code,
        .function_id = function,
        .fns = program.fns,
    });
    return .closure(reference.toObject());
}

fn makeI64Tensor(ctx: *EvalContext, values: []const i64) !Value {
    const arguments = try ctx.scratch.alloc(Value, values.len);
    defer ctx.scratch.free(arguments);
    for (arguments, values) |*argument, value| argument.* = .i64(value);
    return tensor_intrin.create(ctx, .nil, .nil, arguments);
}

fn makeF64Tensor(ctx: *EvalContext, values: []const f64) !Value {
    const arguments = try ctx.scratch.alloc(Value, values.len);
    defer ctx.scratch.free(arguments);
    for (arguments, values) |*argument, value| argument.* = .f64(value);
    return tensor_intrin.create(ctx, .nil, .nil, arguments);
}

fn reshapeForTest(ctx: *EvalContext, flat: Value, dimensions: []const i64) !Value {
    const shape = try makeI64Tensor(ctx, dimensions);
    return tensor_intrin.reshape(ctx, .nil, .nil, &.{ flat, shape });
}

fn expectI64Tensor(value: Value, shape: []const u32, expected: []const i64) !void {
    try std.testing.expectEqual(b.type_tensor, value.typ);
    const holder = value.obj.toRef().deref(TensorHolder);
    try std.testing.expectEqual(InnerType.i64, holder.inner);
    try std.testing.expectEqualSlices(u32, shape, holder.shape);
    try std.testing.expectEqual(expected.len, holder.data.len);
    for (holder.data, expected) |word, item| {
        try std.testing.expectEqual(item, @as(i64, @bitCast(word)));
    }
}

fn expectF64Tensor(value: Value, shape: []const u32, expected: []const f64) !void {
    try std.testing.expectEqual(b.type_tensor, value.typ);
    const holder = value.obj.toRef().deref(TensorHolder);
    try std.testing.expectEqual(InnerType.f64, holder.inner);
    try std.testing.expectEqualSlices(u32, shape, holder.shape);
    try std.testing.expectEqual(expected.len, holder.data.len);
    for (holder.data, expected) |word, item| {
        try std.testing.expectApproxEqAbs(item, @as(f64, @bitCast(word)), 1e-12);
    }
}
const tree = @import("tree.zig");
const effects = @import("../ad_effects.zig");
const Closure = skript.data.Closure;

/// Tensor operations lowered by bound-Code forward mode.
///
/// The enum is intentionally named rather than ordinally interpreted by
/// callers. `dispatch` carries the tag as an i64 because that is the native
/// primitive ABI used by generated Code.
pub const Operation = enum(i64) {
    stack,
    tensor_get,
    reshape,
    transpose,
    dot,
    map,
    map2,
    outer,
    fold,
    scan,
};

const max_rank = 8;

/// Nested callback jets use one lane for each subset of derivative levels.
/// Six levels keep binary callback arguments within the byte-sized VM ABI.
pub const max_nested_order: u8 = 6;
pub const max_nested_lanes: usize = 1 << max_nested_order;
pub const max_nested_registers: usize = std.math.maxInt(u8);

const TensorView = struct {
    holder: TensorHolder,
    tangent: ?TensorHolder,
};

const CallbackResult = struct {
    primal: Value,
    tangent: Value,
};

fn nestedLaneCount(order: u8) Error!usize {
    if (order > max_nested_order) return error.Unsupported;
    return @as(usize, 1) << @intCast(order);
}

fn checkedMul(left: usize, right: usize) Error!usize {
    return std.math.mul(usize, left, right) catch error.Unsupported;
}

fn checkedAdd(left: usize, right: usize) Error!usize {
    return std.math.add(usize, left, right) catch error.Unsupported;
}

fn chargeWork(ctx: *EvalContext, count: usize) Error!void {
    try ctx.chargeWork(std.math.cast(u64, count) orelse return error.Unsupported, 1, .native);
}

fn chargeWorkProduct(ctx: *EvalContext, count: usize, cost: usize) Error!void {
    try ctx.chargeWork(
        std.math.cast(u64, count) orelse return error.Unsupported,
        std.math.cast(u64, cost) orelse return error.Unsupported,
        .native,
    );
}

fn isNumericInner(inner: InnerType) bool {
    return inner == .i64 or inner == .f64;
}

fn validateTensor(holder: TensorHolder) Error!void {
    if (holder.rank == 0) return error.TypeMismatch;
    const rank = std.math.cast(usize, holder.rank) orelse return error.Unsupported;
    if (holder.shape.len != rank) return error.TypeMismatch;
    var count: usize = 1;
    for (holder.shape) |dimension| {
        count = try checkedMul(count, std.math.cast(usize, dimension) orelse return error.Unsupported);
    }
    if (count != holder.data.len) return error.Unsupported;
    if (holder.data.len > 0 and !isNumericInner(holder.inner)) return error.Unsupported;
    if (holder.data.len == 0 and holder.inner != .empty and !isNumericInner(holder.inner)) {
        return error.Unsupported;
    }
}

fn tensorView(value: Value, tangent: Value) Error!TensorView {
    if (value.typ != b.type_tensor or value.obj == .null) return error.TypeMismatch;
    const holder = value.obj.toRef().deref(TensorHolder).*;
    try validateTensor(holder);
    if (Value.isNil(tangent)) return .{ .holder = holder, .tangent = null };
    if (tangent.typ != b.type_tensor or tangent.obj == .null) return error.TypeMismatch;
    const tangent_holder = tangent.obj.toRef().deref(TensorHolder).*;
    try validateTensor(tangent_holder);
    if (tangent_holder.rank != holder.rank) return error.TypeMismatch;
    if (!std.mem.eql(u32, tangent_holder.shape, holder.shape)) return error.TypeMismatch;
    if (tangent_holder.data.len != holder.data.len) return error.TypeMismatch;
    if (tangent_holder.data.len > 0 and !isNumericInner(tangent_holder.inner)) {
        return error.TypeMismatch;
    }
    return .{ .holder = holder, .tangent = tangent_holder };
}

fn scalarWord(value: Value, inner: *InnerType) Error!u64 {
    return switch (value.typ) {
        b.type_i64 => blk: {
            inner.* = .i64;
            break :blk @bitCast(value.obj.toInt(i64));
        },
        b.type_f64 => blk: {
            inner.* = .f64;
            break :blk @bitCast(value.obj.tof64());
        },
        else => error.TypeMismatch,
    };
}

fn wordValue(inner: InnerType, word: u64) Value {
    return tensor_intrin.wordToValue(inner, word);
}

fn tangentWord(inner: InnerType, tangent: Value) Error!u64 {
    if (Value.isNil(tangent)) return 0;
    const target = if (inner == .i64) b.type_i64 else if (inner == .f64) b.type_f64 else {
        return error.TypeMismatch;
    };
    const converted = try tree.coerceNumeric(target, tangent);
    return switch (inner) {
        .i64 => @bitCast(converted.obj.toInt(i64)),
        .f64 => @bitCast(converted.obj.tof64()),
        else => unreachable,
    };
}

fn outputWord(inner: InnerType, value: Value) Error!u64 {
    if (Value.isNil(value)) return 0;
    if (value.typ == b.type_error) return value.errorCode();
    return switch (inner) {
        .i64 => @bitCast((try tree.coerceNumeric(b.type_i64, value)).obj.toInt(i64)),
        .f64 => @bitCast((try tree.coerceNumeric(b.type_f64, value)).obj.tof64()),
        else => error.TypeMismatch,
    };
}

fn allocTensorBacking(comptime T: type, rt: *Runtime, count: usize) Error![]T {
    return (try rt.store.allocSlice(T, count)).slice;
}

fn dupeTensorBacking(comptime T: type, rt: *Runtime, source: []const T) Error![]T {
    const allocation = try rt.store.allocSlice(T, source.len);
    @memcpy(allocation.slice, source);
    return allocation.slice;
}

fn makeTensor(rt: *Runtime, inner: InnerType, shape: []u32, data: []u64) Error!Value {
    const reference = try rt.store.createTraced(TensorHolder, tensor_intrin.traceTensorHolder);
    reference.deref(TensorHolder).* = .{
        .inner = inner,
        .rank = @intCast(shape.len),
        .shape = shape,
        .data = data,
    };
    return .tensor(reference.toObject());
}

pub fn addTangents(ctx: *EvalContext, left: Value, right: Value) Error!Value {
    const scope = ctx.activate();
    defer scope.deinit();
    const lhs = (try tensorView(left, .nil)).holder;
    const rhs = (try tensorView(right, .nil)).holder;
    if (lhs.inner != rhs.inner or lhs.rank != rhs.rank or
        lhs.data.len != rhs.data.len or !std.mem.eql(u32, lhs.shape, rhs.shape))
    {
        return error.TypeMismatch;
    }
    try chargeWork(ctx, lhs.data.len);
    const shape = try ctx.runtime.store.allocSlice(u32, lhs.shape.len);
    @memcpy(shape.slice, lhs.shape);
    const data = try ctx.runtime.store.allocSlice(u64, lhs.data.len);
    for (lhs.data, rhs.data, data.slice) |a, bword, *out| {
        out.* = try addWord(lhs.inner, a, bword);
    }
    return makeTensor(ctx.runtime, lhs.inner, shape.slice, data.slice);
}

fn makeTensorPair(
    rt: *Runtime,
    inner: InnerType,
    shape: []u32,
    primal_data: []u64,
    tangent_data: []u64,
) Error![2]Value {
    return .{
        try makeTensor(rt, inner, shape, primal_data),
        try makeTensor(rt, inner, shape, tangent_data),
    };
}

fn validateTangentArity(primals: []const Value, tangents: []const Value) Error!void {
    if (primals.len != tangents.len) return error.ArityMismatch;
}

fn requireNoKernel(kernel: ?Value) Error!void {
    if (kernel) |value| {
        if (!Value.isNil(value)) return error.TypeMismatch;
    }
}

fn resolveAxis(rank: usize, value: Value) Error!usize {
    if (value.typ != b.type_i64) return error.TypeMismatch;
    const raw = value.obj.toInt(i64);
    const resolved = if (raw < 0) std.math.add(i64, @intCast(rank), raw) catch return error.Unsupported else raw;
    if (resolved < 0 or resolved >= @as(i64, @intCast(rank))) return error.Unsupported;
    return @intCast(resolved);
}

fn axisArgument(
    primals: []const Value,
    tangents: []const Value,
    rank: usize,
) Error!usize {
    if (primals.len == 1) return 0;
    if (tangents.len != primals.len) return error.ArityMismatch;
    if (!Value.isNil(tangents[1])) return error.TypeMismatch;
    if (Value.isNil(primals[1])) return 0;
    return resolveAxis(rank, primals[1]);
}

fn strides(shape: []const u32, out: *[max_rank]usize) Error!void {
    if (shape.len > max_rank) return error.Unsupported;
    var stride: usize = 1;
    var axis = shape.len;
    while (axis > 0) {
        axis -= 1;
        out[axis] = stride;
        stride = try checkedMul(
            stride,
            std.math.cast(usize, shape[axis]) orelse return error.Unsupported,
        );
    }
}

fn cellCount(shape: []const u32, axis: usize) Error!usize {
    var count: usize = 1;
    for (shape, 0..) |dimension, current_axis| {
        if (current_axis == axis) continue;
        count = try checkedMul(count, std.math.cast(usize, dimension) orelse return error.Unsupported);
    }
    return count;
}

/// Return the contiguous base of one axis cell without allocating a cell list.
fn cellBase(
    shape: []const u32,
    axis: usize,
    cell: usize,
    axis_strides: *const [max_rank]usize,
) Error!usize {
    var remainder = cell;
    var base: usize = 0;
    var current_axis = shape.len;
    while (current_axis > 0) {
        current_axis -= 1;
        if (current_axis == axis) continue;
        const dimension = std.math.cast(usize, shape[current_axis]) orelse return error.Unsupported;
        if (dimension == 0) return error.Unsupported;
        const coordinate = remainder % dimension;
        remainder /= dimension;
        base = try checkedAdd(base, try checkedMul(coordinate, axis_strides[current_axis]));
    }
    if (remainder != 0) return error.Unsupported;
    return base;
}

fn rejectVariadicKernel(closure: *const Closure) Error!void {
    if (closure.code) |code| {
        if (code.function(closure.function_id)) |function| {
            if (function.has_rest) return error.Unsupported;
        }
    }
}

fn validateKernel(
    ctx: *EvalContext,
    kernel: ?Value,
    callback_arity: usize,
) Error!Value {
    try ctx.check();
    if (ctx.mode != .concrete or ctx.reentry != null) return error.Unsupported;
    const value = kernel orelse return error.TypeMismatch;
    if (Value.isNil(value)) return error.TypeMismatch;
    if (value.typ != b.type_closure or value.obj == .null) return error.TypeMismatch;
    const closure = value.obj.toRef().deref(Closure);
    try rejectVariadicKernel(closure);
    const expected_arity = try checkedMul(callback_arity, 2);
    if (closure.arglist.len != expected_arity) return error.ArityMismatch;
    if (closure.result_count != 2) return error.ArityMismatch;
    if (closure.code == null or closure.code.?.owner != @as(?*const anyopaque, ctx.runtime)) {
        return error.InvalidCode;
    }
    if (closure.function_id == .invalid or closure.ir.len == 0 or closure.nregs == 0) {
        return error.InvalidCode;
    }
    const function = closure.code.?.function(closure.function_id) orelse return error.InvalidCode;
    if (function.parameter_count != expected_arity or function.result_count != 2) {
        return error.InvalidCode;
    }
    const guard = closure.guard orelse return error.InvalidCode;
    try guard.check(ctx.runtime, guard.context);
    try effects.preflight(ctx.runtime, closure.parent_ns, value);
    return value;
}

fn callKernel(
    ctx: *EvalContext,
    workspace: *Runtime.CallWorkspace,
    kernel: Value,
    call_args: []const Value,
    call_outputs: *[2]Value,
) Error!CallbackResult {
    try workspace.apply(ctx, kernel, call_args, call_outputs);
    const primal_result = call_outputs[0].unwrapError();
    const tangent_result = call_outputs[1].unwrapError();
    const primal = try primal_result;
    const tangent = try tangent_result;
    return .{ .primal = primal, .tangent = tangent };
}

fn validateNestedKernel(
    ctx: *EvalContext,
    kernel: ?Value,
    callback_arity: usize,
    order: u8,
    lane_count: usize,
) Error!Value {
    try ctx.check();
    if (ctx.mode != .concrete or ctx.reentry != null) return error.Unsupported;
    if (lane_count != try nestedLaneCount(order)) return error.Unsupported;
    const value = kernel orelse return error.TypeMismatch;
    if (Value.isNil(value)) return error.TypeMismatch;
    if (value.typ != b.type_closure or value.obj == .null) return error.TypeMismatch;
    const closure = value.obj.toRef().deref(Closure);
    try rejectVariadicKernel(closure);
    const expected_arity = try checkedMul(callback_arity, lane_count);
    if (expected_arity > max_nested_registers) return error.Unsupported;
    if (closure.arglist.len != expected_arity) return error.ArityMismatch;
    if (closure.result_count != lane_count) return error.ArityMismatch;
    if (closure.nregs == 0 or closure.nregs > max_nested_registers) {
        return error.InvalidCode;
    }
    if (closure.code == null or closure.code.?.owner != @as(?*const anyopaque, ctx.runtime)) {
        return error.InvalidCode;
    }
    if (closure.function_id == .invalid) return error.InvalidCode;
    const function = closure.code.?.function(closure.function_id) orelse return error.InvalidCode;
    if (function.parameter_count != expected_arity or function.result_count != lane_count) {
        return error.InvalidCode;
    }
    const guard = closure.guard orelse return error.InvalidCode;
    try guard.check(ctx.runtime, guard.context);
    try effects.preflight(ctx.runtime, closure.parent_ns, value);
    return value;
}

fn callKernelNested(
    ctx: *EvalContext,
    workspace: *Runtime.CallWorkspace,
    kernel: Value,
    call_args: []const Value,
    call_outputs: []Value,
    lane_count: usize,
    order: u8,
    expected_inner: ?InnerType,
    output_inner: *InnerType,
    output_words: *[max_nested_lanes]u64,
    output_active: *[max_nested_lanes]bool,
) Error!void {
    if (call_args.len > max_nested_registers or call_outputs.len != lane_count) {
        return error.Unsupported;
    }
    try workspace.apply(ctx, kernel, call_args, call_outputs);
    for (call_outputs[0..lane_count]) |*output| output.* = try output.*.unwrapError();
    // SAFETY: scalarWord initializes result_inner before the first read.
    var result_inner: InnerType = undefined;
    const primal = try scalarWord(call_outputs[0], &result_inner);
    if (!isNumericInner(result_inner)) return error.TypeMismatch;
    const inner = expected_inner orelse result_inner;
    if (inner != result_inner) return error.TypeMismatch;
    output_inner.* = inner;
    var raw_words: [max_nested_lanes]u64 = undefined;
    var raw_active: [max_nested_lanes]bool = undefined;
    raw_words[0] = primal;
    raw_active[0] = !Value.isNil(call_outputs[0]);
    var lane: usize = 1;
    while (lane < lane_count) : (lane += 1) {
        raw_words[lane] = try outputWord(inner, call_outputs[lane]);
        raw_active[lane] = !Value.isNil(call_outputs[lane]);
    }
    lane = 0;
    while (lane < lane_count) : (lane += 1) {
        var raw_index = lane;
        var remaining = order;
        var normalized_index: usize = 0;
        while (remaining > 0) : (remaining -= 1) {
            normalized_index = (normalized_index << 1) | (raw_index & 1);
            raw_index >>= 1;
        }
        output_words[lane] = raw_words[normalized_index];
        output_active[lane] = raw_active[normalized_index];
    }
}

fn nestedTensorWord(
    inner: InnerType,
    source: ?TensorHolder,
    index: usize,
) Error!Value {
    const holder = source orelse return .nil;
    const value = wordValue(holder.inner, holder.data[index]);
    if (holder.inner == inner) return value;
    return wordValue(inner, try tangentWord(inner, value));
}

fn nestedOutputData(
    ctx: *EvalContext,
    inner: InnerType,
    shape: []u32,
    data: []u64,
    output_len: usize,
    lane_count: usize,
    active: *const [max_nested_lanes]bool,
    outputs: *[max_nested_lanes]Value,
) Error!void {
    var lane: usize = 0;
    while (lane < lane_count) : (lane += 1) {
        if (!active[lane]) {
            outputs[lane] = .nil;
            continue;
        }
        const offset = try checkedMul(lane, output_len);
        const end = try checkedAdd(offset, output_len);
        outputs[lane] = try makeTensor(ctx.runtime, inner, shape, data[offset..end]);
    }
}

fn nestedPayloadCount(
    operation: Operation,
    lane_count: usize,
    payload_len: usize,
) Error!usize {
    if (lane_count == 0 or payload_len == 0 or payload_len % lane_count != 0) {
        return error.ArityMismatch;
    }
    const count = payload_len / lane_count;
    switch (operation) {
        .map, .fold, .scan => {
            if (count != 1 and count != 2) return error.ArityMismatch;
        },
        .map2, .outer => {
            if (count != 2) return error.ArityMismatch;
        },
        else => return error.Unsupported,
    }
    return count;
}

fn nestedAxis(
    payload: []const Value,
    lane_count: usize,
    payload_count: usize,
    rank: usize,
) Error!usize {
    if (payload_count == 1) {
        if (payload.len != lane_count) return error.Unsupported;
        return 0;
    }
    const axis = try resolveAxis(rank, payload[1]);
    var lane: usize = 1;
    while (lane < lane_count) : (lane += 1) {
        if (!Value.isNil(payload[lane * payload_count + 1])) return error.TypeMismatch;
    }
    return axis;
}

fn nestedTensorHolder(value: Value, expected: ?TensorHolder) Error!?TensorHolder {
    if (Value.isNil(value)) return null;
    if (value.typ != b.type_tensor or value.obj == .null) return error.TypeMismatch;
    const holder = value.obj.toRef().deref(TensorHolder).*;
    try validateTensor(holder);
    if (expected) |reference| {
        if (holder.rank != reference.rank) return error.TypeMismatch;
        if (!std.mem.eql(u32, holder.shape, reference.shape)) return error.TypeMismatch;
        if (holder.data.len != reference.data.len) return error.TypeMismatch;
    }
    if (holder.data.len > 0 and !isNumericInner(holder.inner)) return error.TypeMismatch;
    return holder;
}

fn isZeroStatic(ctx: *EvalContext, value: Value, depth: usize) Error!bool {
    if (depth >= 32) return error.Unsupported;
    try chargeWork(ctx, 1);
    if (Value.isNil(value)) return true;
    if (value.typ == b.type_i64) return value.obj.toInt(i64) == 0;
    if (value.typ == b.type_f64) return value.obj.tof64() == 0.0;
    if (value.typ == b.type_cons and value.obj != .null) {
        const pair = value.obj.toRef().deref([2]Value);
        if (!try isZeroStatic(ctx, pair[0], depth + 1)) return false;
        return isZeroStatic(ctx, pair[1], depth + 1);
    }
    if (value.typ == b.type_tensor and value.obj != .null) {
        const holder = value.obj.toRef().deref(TensorHolder).*;
        try validateTensor(holder);
        try chargeWork(ctx, holder.data.len);
        for (holder.data) |word| {
            const scalar = wordValue(holder.inner, word);
            if (!try isZeroStatic(ctx, scalar, depth + 1)) return false;
        }
        return true;
    }
    return false;
}

fn tangentAt(inner: InnerType, source: ?TensorHolder, index: usize) Error!u64 {
    const holder = source orelse return 0;
    if (holder.inner == inner) return holder.data[index];
    return tangentWord(inner, wordValue(holder.inner, holder.data[index]));
}

fn executeStack(
    ctx: *EvalContext,
    primals: []const Value,
    tangents: []const Value,
    outputs: *[2]Value,
) Error!void {
    const rt = ctx.runtime;
    if (primals.len == 0) {
        const shape = try allocTensorBacking(u32, rt, 1);
        shape[0] = 0;
        const tangent_shape = try allocTensorBacking(u32, rt, 1);
        tangent_shape[0] = 0;
        outputs.* = .{
            try makeTensor(rt, .empty, shape, &.{}),
            try makeTensor(rt, .empty, tangent_shape, &.{}),
        };
        return;
    }
    var all_tensors = true;
    for (primals) |value| {
        if (value.typ != b.type_tensor) {
            all_tensors = false;
            break;
        }
    }
    if (all_tensors) {
        const first = try tensorView(primals[0], tangents[0]);
        if (!isNumericInner(first.holder.inner) and first.holder.data.len != 0) {
            return error.Unsupported;
        }
        const rank = std.math.cast(usize, first.holder.rank) orelse return error.Unsupported;
        const result_rank = try checkedAdd(rank, 1);
        const outer_dimension = std.math.cast(u32, primals.len) orelse return error.Unsupported;
        const inner = first.holder.inner;
        for (primals, tangents) |primal, tangent| {
            const view = try tensorView(primal, tangent);
            if (view.holder.rank != first.holder.rank) return error.ArityMismatch;
            if (!std.mem.eql(u32, view.holder.shape, first.holder.shape)) return error.ArityMismatch;
            if (view.holder.inner != inner) return error.TypeMismatch;
        }
        const shape = try allocTensorBacking(u32, rt, result_rank);
        shape[0] = outer_dimension;
        @memcpy(shape[1..], first.holder.shape);
        const words_per = first.holder.data.len;
        const output_len = try checkedMul(words_per, primals.len);
        try chargeWork(ctx, primals.len);
        try chargeWork(ctx, output_len);
        const primal_data = try allocTensorBacking(u64, rt, output_len);
        const tangent_data = try allocTensorBacking(u64, rt, output_len);
        for (primals, tangents, 0..) |primal, tangent, index| {
            const view = try tensorView(primal, tangent);
            const offset = try checkedMul(index, words_per);
            const end = try checkedAdd(offset, words_per);
            @memcpy(primal_data[offset..end], view.holder.data);
            for (view.holder.data, 0..) |_, word_index| {
                tangent_data[try checkedAdd(offset, word_index)] =
                    try tangentAt(inner, view.tangent, word_index);
            }
        }
        const pair = try makeTensorPair(rt, inner, shape, primal_data, tangent_data);
        outputs.* = pair;
        return;
    }

    var inner: InnerType = .empty;
    for (primals, tangents) |primal, tangent| {
        // SAFETY: scalarWord initializes item_inner before the first read.
        var item_inner: InnerType = undefined;
        _ = try scalarWord(primal, &item_inner);
        if (inner == .empty) {
            inner = item_inner;
        } else if (item_inner != inner) {
            return error.TypeMismatch;
        }
        _ = try tangentWord(inner, tangent);
    }
    try chargeWork(ctx, primals.len);
    const primal_data = try allocTensorBacking(u64, rt, primals.len);
    const tangent_data = try allocTensorBacking(u64, rt, primals.len);
    for (primals, tangents, 0..) |primal, tangent, index| {
        // SAFETY: scalarWord initializes item_inner before the first read.
        var item_inner: InnerType = undefined;
        primal_data[index] = try scalarWord(primal, &item_inner);
        tangent_data[index] = try tangentWord(inner, tangent);
    }
    const shape = try allocTensorBacking(u32, rt, 1);
    shape[0] = std.math.cast(u32, primals.len) orelse return error.Unsupported;
    outputs.* = try makeTensorPair(rt, inner, shape, primal_data, tangent_data);
}

fn executeTensorGet(
    ctx: *EvalContext,
    primals: []const Value,
    tangents: []const Value,
    outputs: *[2]Value,
) Error!void {
    if (primals.len < 2) return error.ArityMismatch;
    const view = try tensorView(primals[0], tangents[0]);
    const rank = std.math.cast(usize, view.holder.rank) orelse return error.Unsupported;
    if (primals.len - 1 != rank) return error.ArityMismatch;
    for (tangents[1..]) |tangent| {
        if (!try isZeroStatic(ctx, tangent, 0)) return error.Unsupported;
    }
    try chargeWork(ctx, rank);
    var index: usize = 0;
    var stride: usize = 1;
    var axis = rank;
    while (axis > 0) {
        axis -= 1;
        if (primals[axis + 1].typ != b.type_i64) return error.TypeMismatch;
        const coordinate = primals[axis + 1].obj.toInt(i64);
        const dimension = std.math.cast(i64, view.holder.shape[axis]) orelse return error.Unsupported;
        if (coordinate < 0 or coordinate >= dimension) return error.Unsupported;
        const coordinate_index = std.math.cast(usize, coordinate) orelse return error.Unsupported;
        index = try checkedAdd(index, try checkedMul(coordinate_index, stride));
        stride = try checkedMul(
            stride,
            std.math.cast(usize, view.holder.shape[axis]) orelse return error.Unsupported,
        );
    }
    if (index >= view.holder.data.len) return error.Unsupported;
    const primal = wordValue(view.holder.inner, view.holder.data[index]);
    const tangent = wordValue(
        view.holder.inner,
        try tangentAt(view.holder.inner, view.tangent, index),
    );
    outputs.* = .{ primal, tangent };
}

fn shapeDimensions(ctx: *EvalContext, value: Value) Error![]const u32 {
    if (value.typ == b.type_tensor) {
        if (value.obj == .null) return error.TypeMismatch;
        const shape_tensor = value.obj.toRef().deref(TensorHolder).*;
        try validateTensor(shape_tensor);
        if (shape_tensor.rank != 1 or shape_tensor.inner != .i64) return error.TypeMismatch;
        try chargeWork(ctx, shape_tensor.data.len);
        const dimensions = try ctx.scratch.alloc(u32, shape_tensor.data.len);
        errdefer ctx.scratch.free(dimensions);
        for (shape_tensor.data, 0..) |word, index| {
            const dimension: i64 = @bitCast(word);
            if (dimension < 0) return error.Unsupported;
            dimensions[index] = std.math.cast(u32, dimension) orelse return error.Unsupported;
        }
        return dimensions;
    }
    var count: usize = 0;
    var cursor = value;
    while (cursor.typ == b.type_cons) {
        try ctx.check();
        try chargeWork(ctx, 1);
        count = try checkedAdd(count, 1);
        if (count > 1024) return error.Unsupported;
        cursor = cursor.obj.toRef().deref([2]Value)[1];
    }
    if (cursor.typ != b.type_nil) return error.TypeMismatch;
    if (count == 0) return error.ArityMismatch;
    const dimensions = try ctx.scratch.alloc(u32, count);
    errdefer ctx.scratch.free(dimensions);
    cursor = value;
    var index: usize = 0;
    while (cursor.typ == b.type_cons) {
        try chargeWork(ctx, 1);
        const cell = cursor.obj.toRef().deref([2]Value);
        if (cell[0].typ != b.type_i64) return error.TypeMismatch;
        const dimension = cell[0].obj.toInt(i64);
        if (dimension < 0) return error.Unsupported;
        dimensions[index] = std.math.cast(u32, dimension) orelse return error.Unsupported;
        index += 1;
        cursor = cell[1];
    }
    return dimensions;
}

fn executeReshape(
    ctx: *EvalContext,
    primals: []const Value,
    tangents: []const Value,
    outputs: *[2]Value,
) Error!void {
    if (primals.len != 2) return error.ArityMismatch;
    if (!try isZeroStatic(ctx, tangents[1], 0)) return error.Unsupported;
    const view = try tensorView(primals[0], tangents[0]);
    const dimensions = try shapeDimensions(ctx, primals[1]);
    defer ctx.scratch.free(dimensions);
    if (dimensions.len == 0) return error.ArityMismatch;
    var total: usize = 1;
    try chargeWork(ctx, dimensions.len);
    for (dimensions) |dimension| {
        total = try checkedMul(total, std.math.cast(usize, dimension) orelse return error.Unsupported);
    }
    if (total != view.holder.data.len) return error.ArityMismatch;
    try chargeWork(ctx, view.holder.data.len);
    const shape = try dupeTensorBacking(u32, ctx.runtime, dimensions);
    const tangent_data = try allocTensorBacking(u64, ctx.runtime, view.holder.data.len);
    if (view.tangent) |tangent_holder| {
        for (tangent_holder.data, 0..) |_, index| {
            tangent_data[index] = try tangentAt(view.holder.inner, tangent_holder, index);
        }
    } else {
        @memset(tangent_data, 0);
    }
    outputs.* = try makeTensorPair(
        ctx.runtime,
        view.holder.inner,
        shape,
        view.holder.data,
        tangent_data,
    );
}

fn permutation(
    _: *EvalContext,
    primals: []const Value,
    rank: usize,
    out: *[max_rank]usize,
) Error!void {
    if (rank > max_rank) return error.Unsupported;
    if (primals.len == 1) {
        for (0..rank) |axis| out[axis] = rank - 1 - axis;
        return;
    }
    if (primals.len != 2) return error.ArityMismatch;
    const permutation_tensor = primals[1];
    if (permutation_tensor.typ != b.type_tensor or permutation_tensor.obj == .null) {
        return error.TypeMismatch;
    }
    const holder = permutation_tensor.obj.toRef().deref(TensorHolder).*;
    try validateTensor(holder);
    if (holder.rank != 1 or holder.inner != .i64 or holder.shape[0] != @as(u32, @intCast(rank))) {
        return error.TypeMismatch;
    }
    var seen: [max_rank]bool = @splat(false);
    for (holder.data, 0..) |word, output_axis| {
        const old_axis: i64 = @bitCast(word);
        if (old_axis < 0 or old_axis >= @as(i64, @intCast(rank))) return error.Unsupported;
        const axis = std.math.cast(usize, old_axis) orelse return error.Unsupported;
        if (seen[axis]) return error.Unsupported;
        seen[axis] = true;
        out[output_axis] = axis;
    }
}

fn transposeData(
    source: []const u64,
    source_inner: InnerType,
    target_inner: ?InnerType,
    source_shape: []const u32,
    output_shape: []const u32,
    perm: *const [max_rank]usize,
    output: []u64,
) Error!void {
    var new_stride: [max_rank]usize = undefined;
    var old_stride: [max_rank]usize = undefined;
    try strides(output_shape, &new_stride);
    try strides(source_shape, &old_stride);
    var inverse: [max_rank]usize = undefined;
    for (0..source_shape.len) |output_axis| inverse[perm[output_axis]] = output_axis;
    for (0..output.len) |flat_index| {
        var old_flat: usize = 0;
        for (0..source_shape.len) |axis| {
            const output_axis = inverse[axis];
            const dimension = std.math.cast(usize, output_shape[output_axis]) orelse return error.Unsupported;
            if (dimension == 0) return error.Unsupported;
            const coordinate = flat_index / new_stride[output_axis] % dimension;
            old_flat = try checkedAdd(old_flat, try checkedMul(coordinate, old_stride[axis]));
        }
        const word = source[old_flat];
        output[flat_index] = if (target_inner) |inner|
            try tangentWord(inner, wordValue(source_inner, word))
        else
            word;
    }
}

fn executeTranspose(
    ctx: *EvalContext,
    primals: []const Value,
    tangents: []const Value,
    outputs: *[2]Value,
) Error!void {
    if (primals.len < 1 or primals.len > 2) return error.ArityMismatch;
    if (tangents.len != primals.len) return error.ArityMismatch;
    if (primals.len == 2 and !Value.isNil(tangents[1])) return error.TypeMismatch;
    const view = try tensorView(primals[0], tangents[0]);
    const rank = std.math.cast(usize, view.holder.rank) orelse return error.Unsupported;
    if (rank > max_rank) return error.Unsupported;
    try chargeWork(ctx, rank);
    var perm: [max_rank]usize = undefined;
    try permutation(ctx, primals, rank, &perm);
    try chargeWorkProduct(ctx, view.holder.data.len, rank);
    const shape = try allocTensorBacking(u32, ctx.runtime, rank);
    for (0..rank) |output_axis| shape[output_axis] = view.holder.shape[perm[output_axis]];
    const primal_data = try allocTensorBacking(u64, ctx.runtime, view.holder.data.len);
    const tangent_data = try allocTensorBacking(u64, ctx.runtime, view.holder.data.len);
    try transposeData(
        view.holder.data,
        view.holder.inner,
        null,
        view.holder.shape,
        shape,
        &perm,
        primal_data,
    );
    if (view.tangent) |tangent_holder| {
        try transposeData(
            tangent_holder.data,
            tangent_holder.inner,
            view.holder.inner,
            tangent_holder.shape,
            shape,
            &perm,
            tangent_data,
        );
    } else {
        @memset(tangent_data, 0);
    }
    outputs.* = try makeTensorPair(ctx.runtime, view.holder.inner, shape, primal_data, tangent_data);
}

fn addWord(inner: InnerType, left: u64, right: u64) Error!u64 {
    return switch (inner) {
        .i64 => @bitCast(std.math.add(i64, @bitCast(left), @bitCast(right)) catch return error.Unsupported),
        .f64 => @bitCast(@as(f64, @bitCast(left)) + @as(f64, @bitCast(right))),
        else => error.TypeMismatch,
    };
}

fn mulWord(inner: InnerType, left: u64, right: u64) Error!u64 {
    return switch (inner) {
        .i64 => @bitCast(std.math.mul(i64, @bitCast(left), @bitCast(right)) catch return error.Unsupported),
        .f64 => @bitCast(@as(f64, @bitCast(left)) * @as(f64, @bitCast(right))),
        else => error.TypeMismatch,
    };
}

fn dotTerm(inner: InnerType, left: u64, right: u64, left_tangent: u64, right_tangent: u64) Error!struct {
    primal: u64,
    tangent: u64,
} {
    const primal = try mulWord(inner, left, right);
    const left_term = try mulWord(inner, left_tangent, right);
    const right_term = try mulWord(inner, left, right_tangent);
    return .{
        .primal = primal,
        .tangent = try addWord(inner, left_term, right_term),
    };
}

fn executeDot(
    ctx: *EvalContext,
    primals: []const Value,
    tangents: []const Value,
    outputs: *[2]Value,
) Error!void {
    if (primals.len != 2) return error.ArityMismatch;
    const left = try tensorView(primals[0], tangents[0]);
    const right = try tensorView(primals[1], tangents[1]);
    if (left.holder.inner != right.holder.inner) return error.TypeMismatch;
    if (!isNumericInner(left.holder.inner)) return error.Unsupported;
    const inner = left.holder.inner;
    if (left.holder.rank == 1 and right.holder.rank == 1) {
        if (left.holder.shape[0] != right.holder.shape[0]) return error.ArityMismatch;
        const length = std.math.cast(usize, left.holder.shape[0]) orelse return error.Unsupported;
        try chargeWork(ctx, length);
        var primal: u64 = 0;
        var tangent: u64 = 0;
        for (0..length) |index| {
            const left_tangent = try tangentAt(inner, left.tangent, index);
            const right_tangent = try tangentAt(inner, right.tangent, index);
            const term = try dotTerm(
                inner,
                left.holder.data[index],
                right.holder.data[index],
                left_tangent,
                right_tangent,
            );
            primal = try addWord(inner, primal, term.primal);
            tangent = try addWord(inner, tangent, term.tangent);
        }
        outputs.* = .{ wordValue(inner, primal), wordValue(inner, tangent) };
        return;
    }
    if (left.holder.rank != 2 or right.holder.rank != 2) return error.Unsupported;
    const rows = std.math.cast(usize, left.holder.shape[0]) orelse return error.Unsupported;
    const shared = std.math.cast(usize, left.holder.shape[1]) orelse return error.Unsupported;
    const right_shared = std.math.cast(usize, right.holder.shape[0]) orelse return error.Unsupported;
    if (right_shared != shared) return error.ArityMismatch;
    const columns = std.math.cast(usize, right.holder.shape[1]) orelse return error.Unsupported;
    const output_len = try checkedMul(rows, columns);
    try chargeWork(ctx, rows);
    try chargeWorkProduct(ctx, output_len, shared);
    const shape = try allocTensorBacking(u32, ctx.runtime, 2);
    shape[0] = left.holder.shape[0];
    shape[1] = right.holder.shape[1];
    const primal_data = try allocTensorBacking(u64, ctx.runtime, output_len);
    const tangent_data = try allocTensorBacking(u64, ctx.runtime, output_len);
    for (0..rows) |row| {
        for (0..columns) |column| {
            var primal: u64 = 0;
            var tangent: u64 = 0;
            for (0..shared) |shared_index| {
                const left_index = try checkedAdd(try checkedMul(row, shared), shared_index);
                const right_index = try checkedAdd(try checkedMul(shared_index, columns), column);
                const left_tangent = try tangentAt(inner, left.tangent, left_index);
                const right_tangent = try tangentAt(inner, right.tangent, right_index);
                const term = try dotTerm(
                    inner,
                    left.holder.data[left_index],
                    right.holder.data[right_index],
                    left_tangent,
                    right_tangent,
                );
                primal = try addWord(inner, primal, term.primal);
                tangent = try addWord(inner, tangent, term.tangent);
            }
            const output_index = try checkedAdd(try checkedMul(row, columns), column);
            primal_data[output_index] = primal;
            tangent_data[output_index] = tangent;
        }
    }
    outputs.* = try makeTensorPair(ctx.runtime, inner, shape, primal_data, tangent_data);
}

fn callbackInner(
    result: CallbackResult,
    expected_inner: ?InnerType,
) Error!struct { inner: InnerType, primal: u64, tangent: u64 } {
    // SAFETY: scalarWord initializes result_inner before the first read.
    var result_inner: InnerType = undefined;
    const primal = try scalarWord(result.primal, &result_inner);
    if (!isNumericInner(result_inner)) return error.TypeMismatch;
    const inner = expected_inner orelse result_inner;
    if (inner != result_inner) return error.TypeMismatch;
    return .{
        .inner = inner,
        .primal = primal,
        .tangent = try outputWord(inner, result.tangent),
    };
}

fn mapBaseData(
    holder: TensorHolder,
    axis: usize,
    callback_arity: usize,
    ctx: *EvalContext,
    kernel: Value,
    tangent_holder: ?TensorHolder,
    output: []u64,
    tangent_output: []u64,
) Error!InnerType {
    const rank = std.math.cast(usize, holder.rank) orelse return error.Unsupported;
    var axis_strides: [max_rank]usize = undefined;
    try strides(holder.shape, &axis_strides);
    const length = std.math.cast(usize, holder.shape[axis]) orelse return error.Unsupported;
    const cells = try cellCount(holder.shape, axis);
    const work = try checkedMul(cells, length);
    try chargeWorkProduct(ctx, work, 1);
    if (rank > 1) try chargeWorkProduct(ctx, cells, try checkedMul(rank, rank));
    var workspace = Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    var call_args: [4]Value = undefined;
    var call_outputs: [2]Value = undefined;
    var output_inner: ?InnerType = null;
    var cell: usize = 0;
    while (cell < cells) : (cell += 1) {
        const base = try cellBase(holder.shape, axis, cell, &axis_strides);
        var index: usize = 0;
        while (index < length) : (index += 1) {
            const data_index = try checkedAdd(
                base,
                try checkedMul(index, axis_strides[axis]),
            );
            const primal = wordValue(holder.inner, holder.data[data_index]);
            const tangent = wordValue(
                holder.inner,
                try tangentAt(holder.inner, tangent_holder, data_index),
            );
            call_args[0] = primal;
            call_args[1] = tangent;
            const result = try callKernel(ctx, &workspace, kernel, call_args[0..callback_arity], &call_outputs);
            const converted = try callbackInner(result, output_inner);
            output_inner = converted.inner;
            output[data_index] = converted.primal;
            tangent_output[data_index] = converted.tangent;
        }
    }
    return output_inner orelse .empty;
}

fn executeMap(
    ctx: *EvalContext,
    primals: []const Value,
    tangents: []const Value,
    kernel: ?Value,
    outputs: *[2]Value,
) Error!void {
    if (primals.len != 1 and primals.len != 2) return error.ArityMismatch;
    const view = try tensorView(primals[0], tangents[0]);
    const rank = std.math.cast(usize, view.holder.rank) orelse return error.Unsupported;
    if (rank > max_rank) return error.Unsupported;
    const axis = try axisArgument(primals, tangents, rank);
    const callable = try validateKernel(ctx, kernel, 1);
    const data = try allocTensorBacking(u64, ctx.runtime, view.holder.data.len);
    const tangent_data = try allocTensorBacking(u64, ctx.runtime, view.holder.data.len);
    const inner = try mapBaseData(
        view.holder,
        axis,
        2,
        ctx,
        callable,
        view.tangent,
        data,
        tangent_data,
    );
    const shape = try dupeTensorBacking(u32, ctx.runtime, view.holder.shape);
    outputs.* = try makeTensorPair(ctx.runtime, inner, shape, data, tangent_data);
}

fn executeMap2(
    ctx: *EvalContext,
    primals: []const Value,
    tangents: []const Value,
    kernel: ?Value,
    outputs: *[2]Value,
) Error!void {
    if (primals.len != 2) return error.ArityMismatch;
    const left = try tensorView(primals[0], tangents[0]);
    const right = try tensorView(primals[1], tangents[1]);
    const layout = try tensor_intrin.Map2Layout.init(left.holder.shape, right.holder.shape);
    try chargeWork(ctx, layout.rank);
    const callable = try validateKernel(ctx, kernel, 2);
    const output_len = layout.output_len;
    try chargeWork(ctx, output_len);
    const primal_data = try allocTensorBacking(u64, ctx.runtime, output_len);
    const tangent_data = try allocTensorBacking(u64, ctx.runtime, output_len);
    var workspace = Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    var call_args: [4]Value = undefined;
    var call_outputs: [2]Value = undefined;
    var output_inner: ?InnerType = null;
    for (0..output_len) |index| {
        const input_indices = layout.inputIndices(index);
        call_args[0] = wordValue(left.holder.inner, left.holder.data[input_indices[0]]);
        call_args[1] = wordValue(right.holder.inner, right.holder.data[input_indices[1]]);
        call_args[2] = wordValue(
            left.holder.inner,
            try tangentAt(left.holder.inner, left.tangent, input_indices[0]),
        );
        call_args[3] = wordValue(
            right.holder.inner,
            try tangentAt(right.holder.inner, right.tangent, input_indices[1]),
        );
        const result = try callKernel(ctx, &workspace, callable, call_args[0..4], &call_outputs);
        const converted = try callbackInner(result, output_inner);
        output_inner = converted.inner;
        primal_data[index] = converted.primal;
        tangent_data[index] = converted.tangent;
    }
    const shape = try dupeTensorBacking(u32, ctx.runtime, layout.shapeSlice());
    outputs.* = try makeTensorPair(
        ctx.runtime,
        output_inner orelse .empty,
        shape,
        primal_data,
        tangent_data,
    );
}

fn executeOuter(
    ctx: *EvalContext,
    primals: []const Value,
    tangents: []const Value,
    kernel: ?Value,
    outputs: *[2]Value,
) Error!void {
    if (primals.len != 2) return error.ArityMismatch;
    const left = try tensorView(primals[0], tangents[0]);
    const right = try tensorView(primals[1], tangents[1]);
    if (left.holder.rank != 1 or right.holder.rank != 1) return error.Unsupported;
    const callable = try validateKernel(ctx, kernel, 2);
    const left_len = std.math.cast(usize, left.holder.shape[0]) orelse return error.Unsupported;
    const right_len = std.math.cast(usize, right.holder.shape[0]) orelse return error.Unsupported;
    const output_len = try checkedMul(left_len, right_len);
    try chargeWork(ctx, left_len);
    try chargeWork(ctx, output_len);
    const primal_data = try allocTensorBacking(u64, ctx.runtime, output_len);
    const tangent_data = try allocTensorBacking(u64, ctx.runtime, output_len);
    var workspace = Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    var call_args: [4]Value = undefined;
    var call_outputs: [2]Value = undefined;
    var output_inner: ?InnerType = null;
    for (0..left_len) |left_index| {
        for (0..right_len) |right_index| {
            call_args[0] = wordValue(left.holder.inner, left.holder.data[left_index]);
            call_args[1] = wordValue(right.holder.inner, right.holder.data[right_index]);
            call_args[2] = wordValue(
                left.holder.inner,
                try tangentAt(left.holder.inner, left.tangent, left_index),
            );
            call_args[3] = wordValue(
                right.holder.inner,
                try tangentAt(right.holder.inner, right.tangent, right_index),
            );
            const result = try callKernel(ctx, &workspace, callable, call_args[0..4], &call_outputs);
            const converted = try callbackInner(result, output_inner);
            output_inner = converted.inner;
            const output_index = try checkedAdd(try checkedMul(left_index, right_len), right_index);
            primal_data[output_index] = converted.primal;
            tangent_data[output_index] = converted.tangent;
        }
    }
    const shape = try allocTensorBacking(u32, ctx.runtime, 2);
    shape[0] = left.holder.shape[0];
    shape[1] = right.holder.shape[0];
    outputs.* = try makeTensorPair(
        ctx.runtime,
        output_inner orelse .empty,
        shape,
        primal_data,
        tangent_data,
    );
}

fn executeFold(
    ctx: *EvalContext,
    primals: []const Value,
    tangents: []const Value,
    kernel: ?Value,
    outputs: *[2]Value,
) Error!void {
    if (primals.len != 1 and primals.len != 2) return error.ArityMismatch;
    const view = try tensorView(primals[0], tangents[0]);
    const rank = std.math.cast(usize, view.holder.rank) orelse return error.Unsupported;
    if (rank > max_rank) return error.Unsupported;
    const axis = try axisArgument(primals, tangents, rank);
    const length = std.math.cast(usize, view.holder.shape[axis]) orelse return error.Unsupported;
    if (length == 0) return error.Unsupported;
    const callable = try validateKernel(ctx, kernel, 2);
    var axis_strides: [max_rank]usize = undefined;
    try strides(view.holder.shape, &axis_strides);
    const cells = try cellCount(view.holder.shape, axis);
    try chargeWorkProduct(ctx, cells, length);
    try chargeWorkProduct(ctx, cells, try checkedMul(rank, rank));
    var workspace = Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    var call_args: [4]Value = undefined;

    var call_outputs: [2]Value = undefined;
    if (rank == 1) {
        const base = try cellBase(view.holder.shape, axis, 0, &axis_strides);
        var accumulator = wordValue(view.holder.inner, view.holder.data[base]);
        var accumulator_tangent = wordValue(
            view.holder.inner,
            try tangentAt(view.holder.inner, view.tangent, base),
        );
        for (1..length) |index| {
            const data_index = try checkedAdd(base, try checkedMul(index, axis_strides[axis]));
            call_args[0] = accumulator;
            call_args[1] = wordValue(view.holder.inner, view.holder.data[data_index]);
            call_args[2] = accumulator_tangent;
            call_args[3] = wordValue(
                view.holder.inner,
                try tangentAt(view.holder.inner, view.tangent, data_index),
            );
            const result = try callKernel(ctx, &workspace, callable, call_args[0..4], &call_outputs);
            // SAFETY: scalarWord initializes result_inner before the first read.
            var result_inner: InnerType = undefined;
            const result_primal = try scalarWord(result.primal, &result_inner);
            const result_tangent = try outputWord(result_inner, result.tangent);
            accumulator = wordValue(result_inner, result_primal);
            accumulator_tangent = wordValue(result_inner, result_tangent);
        }
        outputs.* = .{ accumulator, accumulator_tangent };
        return;
    }
    const output_shape = try allocTensorBacking(u32, ctx.runtime, rank - 1);
    var shape_index: usize = 0;
    for (view.holder.shape, 0..) |dimension, current_axis| {
        if (current_axis == axis) continue;
        output_shape[shape_index] = dimension;
        shape_index += 1;
    }
    const primal_data = try allocTensorBacking(u64, ctx.runtime, cells);
    const tangent_data = try allocTensorBacking(u64, ctx.runtime, cells);
    var output_inner: ?InnerType = null;
    for (0..cells) |cell| {
        const base = try cellBase(view.holder.shape, axis, cell, &axis_strides);
        var accumulator = wordValue(view.holder.inner, view.holder.data[base]);
        var accumulator_tangent = wordValue(
            view.holder.inner,
            try tangentAt(view.holder.inner, view.tangent, base),
        );
        for (1..length) |index| {
            const data_index = try checkedAdd(base, try checkedMul(index, axis_strides[axis]));
            call_args[0] = accumulator;
            call_args[1] = wordValue(view.holder.inner, view.holder.data[data_index]);
            call_args[2] = accumulator_tangent;
            call_args[3] = wordValue(
                view.holder.inner,
                try tangentAt(view.holder.inner, view.tangent, data_index),
            );
            const result = try callKernel(ctx, &workspace, callable, call_args[0..4], &call_outputs);
            const converted = try callbackInner(result, null);
            accumulator = wordValue(converted.inner, converted.primal);
            accumulator_tangent = wordValue(converted.inner, converted.tangent);
        }
        const final = try callbackInner(
            .{ .primal = accumulator, .tangent = accumulator_tangent },
            output_inner,
        );
        output_inner = final.inner;
        primal_data[cell] = final.primal;
        tangent_data[cell] = final.tangent;
    }
    outputs.* = try makeTensorPair(
        ctx.runtime,
        output_inner orelse .empty,
        output_shape,
        primal_data,
        tangent_data,
    );
}

fn executeScan(
    ctx: *EvalContext,
    primals: []const Value,
    tangents: []const Value,
    kernel: ?Value,
    outputs: *[2]Value,
) Error!void {
    if (primals.len != 1 and primals.len != 2) return error.ArityMismatch;
    const view = try tensorView(primals[0], tangents[0]);
    const rank = std.math.cast(usize, view.holder.rank) orelse return error.Unsupported;
    if (rank > max_rank) return error.Unsupported;
    const axis = try axisArgument(primals, tangents, rank);
    const length = std.math.cast(usize, view.holder.shape[axis]) orelse return error.Unsupported;
    const callable = try validateKernel(ctx, kernel, 2);
    var axis_strides: [max_rank]usize = undefined;
    try strides(view.holder.shape, &axis_strides);
    const cells = try cellCount(view.holder.shape, axis);
    try chargeWorkProduct(ctx, cells, length);
    if (rank > 1) try chargeWorkProduct(ctx, cells, try checkedMul(rank, rank));
    const primal_data = try allocTensorBacking(u64, ctx.runtime, view.holder.data.len);
    const tangent_data = try allocTensorBacking(u64, ctx.runtime, view.holder.data.len);
    if (view.holder.data.len == 0) {
        const shape = try dupeTensorBacking(u32, ctx.runtime, view.holder.shape);
        outputs.* = try makeTensorPair(ctx.runtime, .empty, shape, primal_data, tangent_data);
        return;
    }
    var workspace = Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    var call_args: [4]Value = undefined;
    var call_outputs: [2]Value = undefined;
    var output_inner: ?InnerType = null;
    for (0..cells) |cell| {
        const base = try cellBase(view.holder.shape, axis, cell, &axis_strides);
        var accumulator = wordValue(view.holder.inner, view.holder.data[base]);
        var accumulator_tangent = wordValue(
            view.holder.inner,
            try tangentAt(view.holder.inner, view.tangent, base),
        );
        const first = try callbackInner(
            .{ .primal = accumulator, .tangent = accumulator_tangent },
            output_inner,
        );
        output_inner = first.inner;
        primal_data[base] = first.primal;
        tangent_data[base] = first.tangent;
        for (1..length) |index| {
            const data_index = try checkedAdd(base, try checkedMul(index, axis_strides[axis]));
            call_args[0] = accumulator;
            call_args[1] = wordValue(view.holder.inner, view.holder.data[data_index]);
            call_args[2] = accumulator_tangent;
            call_args[3] = wordValue(
                view.holder.inner,
                try tangentAt(view.holder.inner, view.tangent, data_index),
            );
            const result = try callKernel(ctx, &workspace, callable, call_args[0..4], &call_outputs);
            const converted = try callbackInner(result, output_inner);
            output_inner = converted.inner;
            accumulator = wordValue(converted.inner, converted.primal);
            accumulator_tangent = wordValue(converted.inner, converted.tangent);
            primal_data[data_index] = converted.primal;
            tangent_data[data_index] = converted.tangent;
        }
    }
    const shape = try dupeTensorBacking(u32, ctx.runtime, view.holder.shape);
    outputs.* = try makeTensorPair(
        ctx.runtime,
        output_inner orelse .empty,
        shape,
        primal_data,
        tangent_data,
    );
}

fn executeNestedMap(
    ctx: *EvalContext,
    payload: []const Value,
    lane_count: usize,
    order: u8,
    kernel: Value,
    outputs: *[max_nested_lanes]Value,
) Error!void {
    const payload_count = try nestedPayloadCount(.map, lane_count, payload.len);
    const first = try nestedTensorHolder(payload[0], null) orelse return error.TypeMismatch;
    const rank = std.math.cast(usize, first.rank) orelse return error.Unsupported;
    if (rank > max_rank) return error.Unsupported;
    const axis = try nestedAxis(payload, lane_count, payload_count, rank);
    var holders: [max_nested_lanes]?TensorHolder = @splat(null);
    var lane: usize = 0;
    while (lane < lane_count) : (lane += 1) {
        holders[lane] = try nestedTensorHolder(
            payload[lane * payload_count],
            first,
        );
    }
    const length = std.math.cast(usize, first.shape[axis]) orelse return error.Unsupported;
    const cells = try cellCount(first.shape, axis);
    try chargeWorkProduct(ctx, try checkedMul(cells, length), 1);
    if (rank > 1) try chargeWorkProduct(ctx, cells, try checkedMul(rank, rank));
    const output_len = first.data.len;
    const data_len = try checkedMul(output_len, lane_count);
    const data = try allocTensorBacking(u64, ctx.runtime, data_len);
    var active: [max_nested_lanes]bool = @splat(false);
    if (output_len == 0) {
        @memset(data, 0);
        @memset(active[0..lane_count], true);
    }
    var axis_strides: [max_rank]usize = undefined;
    try strides(first.shape, &axis_strides);
    var workspace = Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    var call_args: [max_nested_lanes]Value = undefined;
    var call_outputs: [max_nested_lanes]Value = undefined;
    var output_words: [max_nested_lanes]u64 = undefined;
    var output_active: [max_nested_lanes]bool = undefined;
    var output_inner: InnerType = .empty;
    var cell: usize = 0;
    while (cell < cells) : (cell += 1) {
        const base = try cellBase(first.shape, axis, cell, &axis_strides);
        var index: usize = 0;
        while (index < length) : (index += 1) {
            const data_index = try checkedAdd(base, try checkedMul(index, axis_strides[axis]));
            lane = 0;
            while (lane < lane_count) : (lane += 1) {
                call_args[lane] = try nestedTensorWord(
                    first.inner,
                    holders[lane],
                    data_index,
                );
            }
            try callKernelNested(
                ctx,
                &workspace,
                kernel,
                call_args[0..lane_count],
                call_outputs[0..lane_count],
                lane_count,
                order,
                if (output_inner == .empty) null else output_inner,
                &output_inner,
                &output_words,
                &output_active,
            );
            lane = 0;
            while (lane < lane_count) : (lane += 1) {
                const offset = try checkedAdd(
                    try checkedMul(lane, output_len),
                    data_index,
                );
                data[offset] = output_words[lane];
                active[lane] = active[lane] or output_active[lane];
            }
        }
    }
    const shape = try dupeTensorBacking(u32, ctx.runtime, first.shape);
    try nestedOutputData(ctx, output_inner, shape, data, output_len, lane_count, &active, outputs);
}

fn executeNestedMap2(
    ctx: *EvalContext,
    payload: []const Value,
    lane_count: usize,
    order: u8,
    kernel: Value,
    outputs: *[max_nested_lanes]Value,
) Error!void {
    _ = try nestedPayloadCount(.map2, lane_count, payload.len);
    const first_left = try nestedTensorHolder(payload[0], null) orelse return error.TypeMismatch;
    const first_right = try nestedTensorHolder(payload[1], null) orelse return error.TypeMismatch;
    if (first_left.rank > max_rank or first_right.rank > max_rank) return error.Unsupported;
    const layout = try tensor_intrin.Map2Layout.init(first_left.shape, first_right.shape);
    var left_holders: [max_nested_lanes]?TensorHolder = @splat(null);
    var right_holders: [max_nested_lanes]?TensorHolder = @splat(null);
    var lane: usize = 0;
    while (lane < lane_count) : (lane += 1) {
        const offset = lane * 2;
        left_holders[lane] = try nestedTensorHolder(payload[offset], first_left);
        right_holders[lane] = try nestedTensorHolder(payload[offset + 1], first_right);
    }
    try chargeWork(ctx, layout.rank);
    const output_len = layout.output_len;
    try chargeWork(ctx, output_len);
    const data = try allocTensorBacking(
        u64,
        ctx.runtime,
        try checkedMul(output_len, lane_count),
    );
    var active: [max_nested_lanes]bool = @splat(false);
    if (output_len == 0) {
        @memset(data, 0);
        @memset(active[0..lane_count], true);
    }
    var workspace = Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    var call_args: [max_nested_lanes * 2]Value = undefined;
    var call_outputs: [max_nested_lanes]Value = undefined;
    var output_words: [max_nested_lanes]u64 = undefined;
    var output_active: [max_nested_lanes]bool = undefined;
    var output_inner: InnerType = .empty;
    var index: usize = 0;
    while (index < output_len) : (index += 1) {
        const input_indices = layout.inputIndices(index);
        lane = 0;
        while (lane < lane_count) : (lane += 1) {
            const argument_offset = lane * 2;
            call_args[argument_offset] = try nestedTensorWord(
                first_left.inner,
                left_holders[lane],
                input_indices[0],
            );
            call_args[argument_offset + 1] = try nestedTensorWord(
                first_right.inner,
                right_holders[lane],
                input_indices[1],
            );
        }
        try callKernelNested(
            ctx,
            &workspace,
            kernel,
            call_args[0 .. lane_count * 2],
            call_outputs[0..lane_count],
            lane_count,
            order,
            if (output_inner == .empty) null else output_inner,
            &output_inner,
            &output_words,
            &output_active,
        );
        lane = 0;
        while (lane < lane_count) : (lane += 1) {
            data[try checkedAdd(try checkedMul(lane, output_len), index)] = output_words[lane];
            active[lane] = active[lane] or output_active[lane];
        }
    }
    const shape = try dupeTensorBacking(u32, ctx.runtime, layout.shapeSlice());
    try nestedOutputData(ctx, output_inner, shape, data, output_len, lane_count, &active, outputs);
}

fn executeNestedOuter(
    ctx: *EvalContext,
    payload: []const Value,
    lane_count: usize,
    order: u8,
    kernel: Value,
    outputs: *[max_nested_lanes]Value,
) Error!void {
    _ = try nestedPayloadCount(.outer, lane_count, payload.len);
    const first_left = try nestedTensorHolder(payload[0], null) orelse return error.TypeMismatch;
    const first_right = try nestedTensorHolder(payload[1], null) orelse return error.TypeMismatch;
    if (first_left.rank != 1 or first_right.rank != 1) return error.Unsupported;
    var left_holders: [max_nested_lanes]?TensorHolder = @splat(null);
    var right_holders: [max_nested_lanes]?TensorHolder = @splat(null);
    var lane: usize = 0;
    while (lane < lane_count) : (lane += 1) {
        const offset = lane * 2;
        left_holders[lane] = try nestedTensorHolder(payload[offset], first_left);
        right_holders[lane] = try nestedTensorHolder(payload[offset + 1], first_right);
    }
    const left_len = std.math.cast(usize, first_left.shape[0]) orelse return error.Unsupported;
    const right_len = std.math.cast(usize, first_right.shape[0]) orelse return error.Unsupported;
    const output_len = try checkedMul(left_len, right_len);
    try chargeWork(ctx, left_len);
    try chargeWork(ctx, output_len);
    const data = try allocTensorBacking(
        u64,
        ctx.runtime,
        try checkedMul(output_len, lane_count),
    );
    var active: [max_nested_lanes]bool = @splat(false);
    if (output_len == 0) {
        @memset(data, 0);
        @memset(active[0..lane_count], true);
    }
    var workspace = Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    var call_args: [max_nested_lanes * 2]Value = undefined;
    var call_outputs: [max_nested_lanes]Value = undefined;
    var output_words: [max_nested_lanes]u64 = undefined;
    var output_active: [max_nested_lanes]bool = undefined;
    var output_inner: InnerType = .empty;
    var left_index: usize = 0;
    while (left_index < left_len) : (left_index += 1) {
        var right_index: usize = 0;
        while (right_index < right_len) : (right_index += 1) {
            lane = 0;
            while (lane < lane_count) : (lane += 1) {
                const argument_offset = lane * 2;
                call_args[argument_offset] = try nestedTensorWord(
                    first_left.inner,
                    left_holders[lane],
                    left_index,
                );
                call_args[argument_offset + 1] = try nestedTensorWord(
                    first_right.inner,
                    right_holders[lane],
                    right_index,
                );
            }
            try callKernelNested(
                ctx,
                &workspace,
                kernel,
                call_args[0 .. lane_count * 2],
                call_outputs[0..lane_count],
                lane_count,
                order,
                if (output_inner == .empty) null else output_inner,
                &output_inner,
                &output_words,
                &output_active,
            );
            const output_index = try checkedAdd(
                try checkedMul(left_index, right_len),
                right_index,
            );
            lane = 0;
            while (lane < lane_count) : (lane += 1) {
                data[try checkedAdd(try checkedMul(lane, output_len), output_index)] =
                    output_words[lane];
                active[lane] = active[lane] or output_active[lane];
            }
        }
    }
    const shape = try allocTensorBacking(u32, ctx.runtime, 2);
    shape[0] = first_left.shape[0];
    shape[1] = first_right.shape[0];
    try nestedOutputData(ctx, output_inner, shape, data, output_len, lane_count, &active, outputs);
}

fn executeNestedFoldLike(
    ctx: *EvalContext,
    payload: []const Value,
    lane_count: usize,
    order: u8,
    kernel: Value,
    scan: bool,
    outputs: *[max_nested_lanes]Value,
    prefixes: ?[]Value,
) Error!void {
    const operation: Operation = if (scan) .scan else .fold;
    const payload_count = try nestedPayloadCount(operation, lane_count, payload.len);
    const first = try nestedTensorHolder(payload[0], null) orelse return error.TypeMismatch;
    const rank = std.math.cast(usize, first.rank) orelse return error.Unsupported;
    const axis = try nestedAxis(payload, lane_count, payload_count, rank);
    if (payload_count == 1 and payload.len != lane_count) return error.Unsupported;
    const length = std.math.cast(usize, first.shape[axis]) orelse return error.Unsupported;
    if (!scan and length == 0) return error.Unsupported;
    if (prefixes) |values| {
        if (values.len != try checkedMul(first.data.len, lane_count / 2)) return error.ArityMismatch;
        @memset(values, .nil);
    }
    var holders: [max_nested_lanes]?TensorHolder = @splat(null);
    var lane: usize = 0;
    while (lane < lane_count) : (lane += 1) {
        holders[lane] = try nestedTensorHolder(
            payload[lane * payload_count],
            first,
        );
    }
    var axis_strides: [max_rank]usize = undefined;
    try strides(first.shape, &axis_strides);
    const cells = try cellCount(first.shape, axis);
    try chargeWorkProduct(ctx, cells, length);
    if (scan and rank > 1) try chargeWorkProduct(ctx, cells, try checkedMul(rank, rank));

    if (!scan and rank == 1) {
        const base = try cellBase(first.shape, axis, 0, &axis_strides);
        var accumulators: [max_nested_lanes]Value = undefined;
        var active: [max_nested_lanes]bool = @splat(false);
        lane = 0;
        while (lane < lane_count) : (lane += 1) {
            accumulators[lane] = try nestedTensorWord(first.inner, holders[lane], base);
            active[lane] = !Value.isNil(accumulators[lane]);
        }
        var workspace = Runtime.CallWorkspace.init(ctx.scratch);
        defer workspace.deinit();
        var call_args: [max_nested_lanes * 2]Value = undefined;
        var call_outputs: [max_nested_lanes]Value = undefined;
        var output_words: [max_nested_lanes]u64 = undefined;
        var output_active: [max_nested_lanes]bool = undefined;
        var output_inner: InnerType = first.inner;
        for (1..length) |index| {
            const data_index = try checkedAdd(base, try checkedMul(index, axis_strides[axis]));
            if (prefixes) |values| {
                try chargeWork(ctx, lane_count / 2);
                @memcpy(
                    values[data_index * (lane_count / 2) ..][0 .. lane_count / 2],
                    accumulators[0 .. lane_count / 2],
                );
            }
            lane = 0;
            while (lane < lane_count) : (lane += 1) {
                const argument_offset = lane * 2;
                call_args[argument_offset] = accumulators[lane];
                call_args[argument_offset + 1] = try nestedTensorWord(
                    first.inner,
                    holders[lane],
                    data_index,
                );
            }
            try callKernelNested(
                ctx,
                &workspace,
                kernel,
                call_args[0 .. lane_count * 2],
                call_outputs[0..lane_count],
                lane_count,
                order,
                output_inner,
                &output_inner,
                &output_words,
                &output_active,
            );
            lane = 0;
            while (lane < lane_count) : (lane += 1) {
                accumulators[lane] = if (output_active[lane])
                    wordValue(output_inner, output_words[lane])
                else
                    .nil;
                active[lane] = active[lane] or output_active[lane];
            }
        }
        lane = 0;
        while (lane < lane_count) : (lane += 1) {
            outputs[lane] = accumulators[lane];
        }
        return;
    }

    const output_len = if (scan) first.data.len else cells;
    const data = try allocTensorBacking(
        u64,
        ctx.runtime,
        try checkedMul(output_len, lane_count),
    );
    var active: [max_nested_lanes]bool = @splat(false);
    if (output_len == 0) {
        @memset(data, 0);
        @memset(active[0..lane_count], true);
    }
    const output_shape = if (scan)
        try dupeTensorBacking(u32, ctx.runtime, first.shape)
    else blk: {
        const shape = try allocTensorBacking(u32, ctx.runtime, rank - 1);
        var shape_index: usize = 0;
        for (first.shape, 0..) |dimension, current_axis| {
            if (current_axis == axis) continue;
            shape[shape_index] = dimension;
            shape_index += 1;
        }
        break :blk shape;
    };
    if (first.data.len == 0 and scan) {
        var empty_active: [max_nested_lanes]bool = @splat(false);
        @memset(empty_active[0..lane_count], true);
        try nestedOutputData(
            ctx,
            .empty,
            output_shape,
            data,
            output_len,
            lane_count,
            &empty_active,
            outputs,
        );
        return;
    }

    var workspace = Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    var call_args: [max_nested_lanes * 2]Value = undefined;
    var call_outputs: [max_nested_lanes]Value = undefined;
    var output_words: [max_nested_lanes]u64 = undefined;
    var output_active: [max_nested_lanes]bool = undefined;
    var output_inner: InnerType = if (scan) first.inner else .empty;
    var cell: usize = 0;
    while (cell < cells) : (cell += 1) {
        const base = try cellBase(first.shape, axis, cell, &axis_strides);
        var accumulators: [max_nested_lanes]Value = undefined;
        lane = 0;
        while (lane < lane_count) : (lane += 1) {
            accumulators[lane] = try nestedTensorWord(first.inner, holders[lane], base);
            active[lane] = active[lane] or !Value.isNil(accumulators[lane]);
            if (scan) {
                data[try checkedAdd(try checkedMul(lane, output_len), base)] =
                    if (Value.isNil(accumulators[lane])) 0 else try scalarWord(
                        accumulators[lane],
                        &output_inner,
                    );
            }
        }
        for (1..length) |index| {
            const data_index = try checkedAdd(base, try checkedMul(index, axis_strides[axis]));
            if (prefixes) |values| {
                try chargeWork(ctx, lane_count / 2);
                @memcpy(
                    values[data_index * (lane_count / 2) ..][0 .. lane_count / 2],
                    accumulators[0 .. lane_count / 2],
                );
            }
            lane = 0;
            while (lane < lane_count) : (lane += 1) {
                const argument_offset = lane * 2;
                call_args[argument_offset] = accumulators[lane];
                call_args[argument_offset + 1] = try nestedTensorWord(
                    first.inner,
                    holders[lane],
                    data_index,
                );
            }
            try callKernelNested(
                ctx,
                &workspace,
                kernel,
                call_args[0 .. lane_count * 2],
                call_outputs[0..lane_count],
                lane_count,
                order,
                if (output_inner == .empty) null else output_inner,
                &output_inner,
                &output_words,
                &output_active,
            );
            lane = 0;
            while (lane < lane_count) : (lane += 1) {
                accumulators[lane] = if (output_active[lane])
                    wordValue(output_inner, output_words[lane])
                else
                    .nil;
                active[lane] = active[lane] or output_active[lane];
                if (scan) {
                    data[try checkedAdd(try checkedMul(lane, output_len), data_index)] =
                        output_words[lane];
                }
            }
        }
        if (!scan) {
            lane = 0;
            while (lane < lane_count) : (lane += 1) {
                data[try checkedAdd(try checkedMul(lane, output_len), cell)] =
                    if (Value.isNil(accumulators[lane])) 0 else try scalarWord(
                        accumulators[lane],
                        &output_inner,
                    );
            }
        }
    }
    try nestedOutputData(
        ctx,
        output_inner,
        output_shape,
        data,
        output_len,
        lane_count,
        &active,
        outputs,
    );
}
pub fn execute(
    ctx: *EvalContext,
    operation: Operation,
    primals: []const Value,
    tangents: []const Value,
    kernel: ?Value,
    outputs: *[2]Value,
) Error!void {
    const scope = ctx.activate();
    defer scope.deinit();
    try ctx.check();
    try validateTangentArity(primals, tangents);
    switch (operation) {
        .stack => {
            try requireNoKernel(kernel);
            return executeStack(ctx, primals, tangents, outputs);
        },
        .tensor_get => {
            try requireNoKernel(kernel);
            return executeTensorGet(ctx, primals, tangents, outputs);
        },
        .reshape => {
            try requireNoKernel(kernel);
            return executeReshape(ctx, primals, tangents, outputs);
        },
        .transpose => {
            try requireNoKernel(kernel);
            return executeTranspose(ctx, primals, tangents, outputs);
        },
        .dot => {
            try requireNoKernel(kernel);
            return executeDot(ctx, primals, tangents, outputs);
        },
        .map => return executeMap(ctx, primals, tangents, kernel, outputs),
        .map2 => return executeMap2(ctx, primals, tangents, kernel, outputs),
        .outer => return executeOuter(ctx, primals, tangents, kernel, outputs),
        .fold => return executeFold(ctx, primals, tangents, kernel, outputs),
        .scan => return executeScan(ctx, primals, tangents, kernel, outputs),
    }
}

pub fn executeNested(
    ctx: *EvalContext,
    operation: Operation,
    order: u8,
    lane_count: usize,
    payload: []const Value,
    kernel: ?Value,
    outputs: *[max_nested_lanes]Value,
    prefixes: ?[]Value,
) Error!void {
    const scope = ctx.activate();
    defer scope.deinit();
    try ctx.check();
    if (lane_count != try nestedLaneCount(order)) return error.ArityMismatch;
    if (prefixes != null and operation != .fold and operation != .scan) return error.Unsupported;
    const callback_arity: usize = switch (operation) {
        .map => 1,
        .map2, .outer, .fold, .scan => 2,
        else => return error.Unsupported,
    };
    const callable = try validateNestedKernel(
        ctx,
        kernel,
        callback_arity,
        order,
        lane_count,
    );
    switch (operation) {
        .map => try executeNestedMap(ctx, payload, lane_count, order, callable, outputs),
        .map2 => try executeNestedMap2(ctx, payload, lane_count, order, callable, outputs),
        .outer => try executeNestedOuter(ctx, payload, lane_count, order, callable, outputs),
        .fold => try executeNestedFoldLike(ctx, payload, lane_count, order, callable, false, outputs, prefixes),
        .scan => try executeNestedFoldLike(ctx, payload, lane_count, order, callable, true, outputs, prefixes),
        else => return error.Unsupported,
    }
}

fn nestedResultList(
    rt: *Runtime,
    outputs: *const [max_nested_lanes]Value,
    lane_count: usize,
) Error!Value {
    if (lane_count == 0 or lane_count > max_nested_lanes) return error.Unsupported;
    var result: Value = .nil;
    var lane = lane_count;
    while (lane > 0) {
        lane -= 1;
        const reference = try rt.store.create([2]Value);
        reference.deref([2]Value).* = .{ outputs[lane], result };
        result = .cons(reference.toObject());
    }
    return result;
}

fn resultList(rt: *Runtime, outputs: [2]Value) Error!Value {
    const tail_reference = try rt.store.create([2]Value);
    tail_reference.deref([2]Value).* = .{ outputs[1], .nil };
    const head_reference = try rt.store.create([2]Value);
    head_reference.deref([2]Value).* = .{
        outputs[0],
        .cons(tail_reference.toObject()),
    };
    return .cons(head_reference.toObject());
}

/// Cold native bridge: `(operation kernel primals... tangents...)`.
pub fn dispatch(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    @branchHint(.cold);
    try ctx.check();
    if (args.len < 2) return error.ArityMismatch;
    if (args[0].typ != b.type_i64) return error.TypeMismatch;
    const raw_operation = args[0].obj.toInt(i64);
    if (raw_operation < @backingInt(Operation.stack) or
        raw_operation > @backingInt(Operation.scan))
    {
        return error.TypeMismatch;
    }
    const operation: Operation = @fromBackingInt(@intCast(raw_operation));
    const kernel = if (Value.isNil(args[1])) null else args[1];
    const payload = args[2..];
    if (payload.len % 2 != 0) return error.ArityMismatch;
    const count = payload.len / 2;
    var outputs: [2]Value = undefined;
    try execute(ctx, operation, payload[0..count], payload[count..], kernel, &outputs);
    return resultList(ctx.runtime, outputs);
}

pub fn dispatchNested(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    @branchHint(.cold);
    try ctx.check();
    if (args.len < 4) return error.ArityMismatch;
    if (args[0].typ != b.type_i64 or args[2].typ != b.type_i64 or args[3].typ != b.type_i64) {
        return error.TypeMismatch;
    }
    const raw_operation = args[0].obj.toInt(i64);
    if (raw_operation < @backingInt(Operation.stack) or
        raw_operation > @backingInt(Operation.scan))
    {
        return error.TypeMismatch;
    }
    const raw_order = args[2].obj.toInt(i64);
    const order = std.math.cast(u8, raw_order) orelse return error.Unsupported;
    const lane_count = std.math.cast(usize, args[3].obj.toInt(i64)) orelse
        return error.Unsupported;
    if (lane_count > max_nested_lanes) return error.Unsupported;
    const operation: Operation = @fromBackingInt(@intCast(raw_operation));
    const kernel = if (Value.isNil(args[1])) null else args[1];
    var outputs: [max_nested_lanes]Value = undefined;
    try executeNested(ctx, operation, order, lane_count, args[4..], kernel, &outputs, null);
    return nestedResultList(ctx.runtime, &outputs, lane_count);
}

test "tensor JVP maps use one two-result Code callback per element" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const unary = try makeTestKernel(runtime, .unary_double, true);
    const binary = try makeTestKernel(runtime, .binary_mul, true);
    const input = try makeF64Tensor(ctx, &.{ 1.0, 2.0, 3.0 });
    const tangent = try makeF64Tensor(ctx, &.{ 0.5, 1.0, 1.5 });
    var outputs: [2]Value = undefined;

    try execute(ctx, .map, &.{input}, &.{tangent}, unary, &outputs);
    try expectF64Tensor(outputs[0], &.{3}, &.{ 2.0, 4.0, 6.0 });
    try expectF64Tensor(outputs[1], &.{3}, &.{ 1.0, 2.0, 3.0 });

    const right = try makeF64Tensor(ctx, &.{ 4.0, 5.0, 6.0 });
    try execute(ctx, .map2, &.{ input, right }, &.{ tangent, .nil }, binary, &outputs);
    try expectF64Tensor(outputs[0], &.{3}, &.{ 4.0, 10.0, 18.0 });
    try expectF64Tensor(outputs[1], &.{3}, &.{ 2.0, 5.0, 9.0 });

    const outer_left = try makeI64Tensor(ctx, &.{ 1, 2 });
    const outer_right = try makeI64Tensor(ctx, &.{ 3, 4 });
    const outer_tangent = try makeI64Tensor(ctx, &.{ 1, 1 });
    try execute(
        ctx,
        .outer,
        &.{ outer_left, outer_right },
        &.{ .nil, outer_tangent },
        binary,
        &outputs,
    );
    try expectI64Tensor(outputs[0], &.{ 2, 2 }, &.{ 3, 4, 6, 8 });
    try expectI64Tensor(outputs[1], &.{ 2, 2 }, &.{ 1, 1, 2, 2 });
}

test "tensor JVP map2 broadcasts matrix-vector inputs and reductions" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const multiply = try makeTestKernel(runtime, .binary_mul, true);
    const left = try reshapeForTest(ctx, try makeF64Tensor(ctx, &.{
        1.0, 2.0, 3.0, 4.0, 5.0, 6.0,
    }), &.{ 2, 3 });
    const right = try makeF64Tensor(ctx, &.{ 10.0, 20.0, 30.0 });
    const left_tangent = try reshapeForTest(ctx, try makeF64Tensor(ctx, &.{
        1.0, 2.0, 3.0, 4.0, 5.0, 6.0,
    }), &.{ 2, 3 });
    const right_tangent = try makeF64Tensor(ctx, &.{ 2.0, 3.0, 4.0 });
    var outputs: [2]Value = undefined;
    try execute(
        ctx,
        .map2,
        &.{ left, right },
        &.{ left_tangent, right_tangent },
        multiply,
        &outputs,
    );
    try expectF64Tensor(outputs[0], &.{ 2, 3 }, &.{ 10.0, 40.0, 90.0, 40.0, 100.0, 180.0 });
    try expectF64Tensor(outputs[1], &.{ 2, 3 }, &.{ 12.0, 46.0, 102.0, 48.0, 115.0, 204.0 });

    const empty = try reshapeForTest(
        ctx,
        try tensor_intrin.iota(ctx, .nil, .nil, &.{Value.i64(0)}),
        &.{ 2, 0, 3 },
    );
    const empty_right = try reshapeForTest(
        ctx,
        try makeF64Tensor(ctx, &.{ 10.0, 20.0, 30.0 }),
        &.{ 1, 1, 3 },
    );
    try execute(ctx, .map2, &.{ empty, empty_right }, &.{ .nil, .nil }, multiply, &outputs);
    for (outputs) |output| {
        const holder = output.obj.toRef().deref(TensorHolder);
        try std.testing.expectEqualSlices(u32, &.{ 2, 0, 3 }, holder.shape);
        try std.testing.expectEqual(InnerType.empty, holder.inner);
        try std.testing.expectEqual(@as(usize, 0), holder.data.len);
    }
}

test "nested tensor JVP map2 broadcasts two singleton axes" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const add = try makeTestKernel(runtime, .binary_add, true);
    const left = try reshapeForTest(ctx, try makeI64Tensor(ctx, &.{ 1, 2 }), &.{ 2, 1 });
    const right = try reshapeForTest(ctx, try makeI64Tensor(ctx, &.{ 10, 20, 30 }), &.{ 1, 3 });
    const left_tangent = try reshapeForTest(ctx, try makeI64Tensor(ctx, &.{ 10, 20 }), &.{ 2, 1 });
    const right_tangent = try reshapeForTest(ctx, try makeI64Tensor(ctx, &.{ 1, 2, 3 }), &.{ 1, 3 });
    const payload = [_]Value{ left, right, left_tangent, right_tangent };
    var outputs: [max_nested_lanes]Value = undefined;
    try executeNested(ctx, .map2, 1, 2, &payload, add, &outputs, null);
    try expectI64Tensor(outputs[0], &.{ 2, 3 }, &.{ 11, 21, 31, 12, 22, 32 });
    try expectI64Tensor(outputs[1], &.{ 2, 3 }, &.{ 11, 12, 13, 21, 22, 23 });
}

test "tensor JVP fold and scan use grouped primal then tangent seeds" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const add = try makeTestKernel(runtime, .binary_add, true);
    const flat = try makeI64Tensor(ctx, &.{ 1, 2, 3, 4 });
    const input = try reshapeForTest(ctx, flat, &.{ 2, 2 });
    const tangent_flat = try makeI64Tensor(ctx, &.{ 10, 20, 30, 40 });
    const tangent = try reshapeForTest(ctx, tangent_flat, &.{ 2, 2 });
    var outputs: [2]Value = undefined;

    try execute(
        ctx,
        .fold,
        &.{ input, Value.i64(0) },
        &.{ tangent, .nil },
        add,
        &outputs,
    );
    try expectI64Tensor(outputs[0], &.{2}, &.{ 4, 6 });
    try expectI64Tensor(outputs[1], &.{2}, &.{ 40, 60 });

    try execute(
        ctx,
        .scan,
        &.{ input, Value.i64(1) },
        &.{ .nil, .nil },
        add,
        &outputs,
    );
    try expectI64Tensor(outputs[0], &.{ 2, 2 }, &.{ 1, 3, 3, 7 });
    try expectI64Tensor(outputs[1], &.{ 2, 2 }, &.{ 0, 0, 0, 0 });

    const singleton = try makeI64Tensor(ctx, &.{17});
    try execute(ctx, .fold, &.{singleton}, &.{.nil}, add, &outputs);
    try std.testing.expectEqual(Value.i64(17), outputs[0]);
    try std.testing.expectEqual(Value.i64(0), outputs[1]);
}

test "tensor JVP structural kernels preserve layout and exact i64 values" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const exact: i64 = 9_007_199_254_740_993;
    var outputs: [2]Value = undefined;

    try execute(
        ctx,
        .stack,
        &.{ Value.i64(exact), Value.i64(2), Value.i64(3), Value.i64(4) },
        &.{ Value.i64(7), .nil, .nil, .nil },
        null,
        &outputs,
    );
    try expectI64Tensor(outputs[0], &.{4}, &.{ exact, 2, 3, 4 });
    try expectI64Tensor(outputs[1], &.{4}, &.{ 7, 0, 0, 0 });
    const flat_primal = outputs[0];
    const flat_tangent = outputs[1];

    const shape = try makeI64Tensor(ctx, &.{ 2, 2 });
    try execute(
        ctx,
        .reshape,
        &.{ flat_primal, shape },
        &.{ flat_tangent, .nil },
        null,
        &outputs,
    );
    try expectI64Tensor(outputs[0], &.{ 2, 2 }, &.{ exact, 2, 3, 4 });
    const matrix_primal = outputs[0];
    const matrix_tangent = outputs[1];

    try execute(ctx, .transpose, &.{matrix_primal}, &.{matrix_tangent}, null, &outputs);
    try expectI64Tensor(outputs[0], &.{ 2, 2 }, &.{ exact, 3, 2, 4 });
    try expectI64Tensor(outputs[1], &.{ 2, 2 }, &.{ 7, 0, 0, 0 });

    try execute(
        ctx,
        .tensor_get,
        &.{ matrix_primal, Value.i64(0), Value.i64(1) },
        &.{ matrix_tangent, .nil, .nil },
        null,
        &outputs,
    );
    try std.testing.expectEqual(Value.i64(2), outputs[0]);
    try std.testing.expectEqual(Value.i64(0), outputs[1]);
}

test "tensor JVP dot is fused and exact for vectors and matrices" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const exact: i64 = 9_007_199_254_740_993;
    const left = try makeI64Tensor(ctx, &.{ exact, 1 });
    const right = try makeI64Tensor(ctx, &.{ 1, 2 });
    const left_tangent = try makeI64Tensor(ctx, &.{ 3, 4 });
    var outputs: [2]Value = undefined;

    try execute(
        ctx,
        .dot,
        &.{ left, right },
        &.{ left_tangent, .nil },
        null,
        &outputs,
    );
    try std.testing.expectEqual(Value.i64(exact + 2), outputs[0]);
    try std.testing.expectEqual(Value.i64(11), outputs[1]);

    const matrix_left = try reshapeForTest(
        ctx,
        try makeF64Tensor(ctx, &.{ 1.0, 2.0, 3.0, 4.0 }),
        &.{ 2, 2 },
    );
    const matrix_right = try reshapeForTest(
        ctx,
        try makeF64Tensor(ctx, &.{ 5.0, 6.0, 7.0, 8.0 }),
        &.{ 2, 2 },
    );
    try execute(
        ctx,
        .dot,
        &.{ matrix_left, matrix_right },
        &.{ .nil, .nil },
        null,
        &outputs,
    );
    try expectF64Tensor(outputs[0], &.{ 2, 2 }, &.{ 19.0, 22.0, 43.0, 50.0 });
    try expectF64Tensor(outputs[1], &.{ 2, 2 }, &.{ 0.0, 0.0, 0.0, 0.0 });

    const overflowing = try makeI64Tensor(ctx, &.{std.math.maxInt(i64)});
    const two = try makeI64Tensor(ctx, &.{2});
    try std.testing.expectError(
        error.Unsupported,
        execute(ctx, .dot, &.{ overflowing, two }, &.{ .nil, .nil }, null, &outputs),
    );
}

test "tensor JVP rejects malformed shapes tangents kernels and guards before loops" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const input = try makeI64Tensor(ctx, &.{ 1, 2, 3 });
    const short_tangent = try makeI64Tensor(ctx, &.{ 1, 2 });
    const fractional = try makeF64Tensor(ctx, &.{ 0.0, 0.5, 0.0 });
    const unary = try makeTestKernel(runtime, .unary_double, true);
    const rejected_guard = try makeTestKernel(runtime, .unary_double, false);
    const impure = try makeTestKernel(runtime, .impure, true);
    const tangent_error = try makeTestKernel(runtime, .tangent_error, true);
    var outputs: [2]Value = .{ Value.i64(91), Value.i64(92) };

    try std.testing.expectError(
        error.TypeMismatch,
        execute(ctx, .map, &.{input}, &.{short_tangent}, unary, &outputs),
    );
    try std.testing.expectError(
        error.Unsupported,
        execute(ctx, .map, &.{input}, &.{fractional}, unary, &outputs),
    );
    const bad_shape = try makeI64Tensor(ctx, &.{2});
    try std.testing.expectError(
        error.ArityMismatch,
        execute(
            ctx,
            .reshape,
            &.{ input, bad_shape },
            &.{ .nil, .nil },
            null,
            &outputs,
        ),
    );
    const matrix = try reshapeForTest(
        ctx,
        try makeI64Tensor(ctx, &.{ 1, 2, 3, 4 }),
        &.{ 2, 2 },
    );
    const bad_permutation = try makeI64Tensor(ctx, &.{ 0, 0 });
    try std.testing.expectError(
        error.Unsupported,
        execute(
            ctx,
            .transpose,
            &.{ matrix, bad_permutation },
            &.{ .nil, .nil },
            null,
            &outputs,
        ),
    );

    const before_guard = runtime.store.stats().live_objects;
    try std.testing.expectError(
        error.Denied,
        execute(ctx, .map, &.{input}, &.{.nil}, rejected_guard, &outputs),
    );
    try std.testing.expectEqual(before_guard, runtime.store.stats().live_objects);
    try std.testing.expectError(
        error.Unsupported,
        execute(ctx, .map, &.{input}, &.{.nil}, impure, &outputs),
    );
    try std.testing.expectEqual(before_guard, runtime.store.stats().live_objects);
    try std.testing.expectError(
        error.Unsupported,
        execute(ctx, .map, &.{input}, &.{.nil}, tangent_error, &outputs),
    );
    try std.testing.expectEqual(Value.i64(91), outputs[0]);
    try std.testing.expectEqual(Value.i64(92), outputs[1]);
}

const AllocationSample = struct {
    scratch_requests: usize,
    store_objects: u32,
};

fn allocationSample(
    runtime: *Runtime,
    kernel: Value,
    input: Value,
) !AllocationSample {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var context = runtime.context().*;
    context.scratch = failing.allocator();
    context.scratch_base = context.scratch;
    const objects_before = runtime.store.stats().live_objects;
    var outputs: [2]Value = undefined;
    try execute(&context, .map, &.{input}, &.{.nil}, kernel, &outputs);
    return .{
        .scratch_requests = failing.alloc_index,
        .store_objects = runtime.store.stats().live_objects - objects_before,
    };
}

test "tensor JVP map administrative allocations do not scale with element count" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const kernel = try makeTestKernel(runtime, .unary_double, true);
    const small = try makeI64Tensor(runtime.context(), &.{1});
    const large = try tensor_intrin.iota(
        runtime.context(),
        .nil,
        .nil,
        &.{Value.i64(4096)},
    );
    const small_sample = try allocationSample(runtime, kernel, small);
    const large_sample = try allocationSample(runtime, kernel, large);
    try std.testing.expectEqual(small_sample.scratch_requests, large_sample.scratch_requests);
    try std.testing.expect(small_sample.store_objects >= 2);
    try std.testing.expectEqual(small_sample.store_objects, large_sample.store_objects);
}

const LimitedHarness = struct {
    const Budget = EvalContext.Budget;

    budget: Budget,
    lease: Budget.Lease,
    account: Budget.AccountAllocator,
    output_bytes: [64]u8,
    writer: std.Io.Writer,
    context: EvalContext,

    fn init(self: *LimitedHarness, runtime: *Runtime, work: u64) !void {
        self.budget = Budget.init(runtime.io, 77, .{ .work = work });
        self.lease = try Budget.Lease.root(&self.budget, work);
        self.account = Budget.AccountAllocator.init(
            std.testing.allocator,
            &self.lease,
            .native,
        );
        self.writer = .fixed(&self.output_bytes);
        self.context = try EvalContext.limited(
            runtime,
            runtime.intrinsics.registryVersion(),
            &self.account,
            .{ .writer = &self.writer, .bounded_memory = true },
            .{ .effects = .{ .state_read = .allow } },
        );
    }
};

test "tensor JVP callbacks retain terminal shared budget exhaustion" {
    const runtime = try Runtime.initWithConfig(std.testing.allocator, std.testing.io, .{
        .max_heap_size = 8 * 1024 * 1024,
    });
    defer runtime.deinit();
    const kernel = try makeTestKernel(runtime, .unary_double, true);
    const input = try tensor_intrin.iota(
        runtime.context(),
        .nil,
        .nil,
        &.{Value.i64(1024)},
    );
    var limited: LimitedHarness = undefined;
    try limited.init(runtime, 2048);
    var outputs: [2]Value = undefined;
    try std.testing.expectError(
        error.Exhausted,
        execute(&limited.context, .map, &.{input}, &.{.nil}, kernel, &outputs),
    );
    const report = limited.budget.report() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(EvalContext.Budget.Resource.work, report.resource);
    try std.testing.expectError(
        error.Exhausted,
        execute(&limited.context, .map, &.{input}, &.{.nil}, kernel, &outputs),
    );
    try std.testing.expectEqualDeep(report, limited.budget.report().?);
}

test "tensor JVP map2 enforces callback effects and shared work budgets" {
    const runtime = try Runtime.initWithConfig(std.testing.allocator, std.testing.io, .{
        .max_heap_size = 8 * 1024 * 1024,
    });
    defer runtime.deinit();
    const ctx = runtime.context();
    const input = try tensor_intrin.iota(ctx, .nil, .nil, &.{Value.i64(1024)});
    const singleton = try makeI64Tensor(ctx, &.{5});
    const impure = try makeTestKernel(runtime, .binary_impure, true);
    var outputs: [2]Value = .{ Value.i64(91), Value.i64(92) };
    try std.testing.expectError(
        error.Unsupported,
        execute(ctx, .map2, &.{ input, singleton }, &.{ .nil, .nil }, impure, &outputs),
    );
    try std.testing.expectEqual(Value.i64(91), outputs[0]);
    try std.testing.expectEqual(Value.i64(92), outputs[1]);

    const add = try makeTestKernel(runtime, .binary_add, true);
    var limited: LimitedHarness = undefined;
    try limited.init(runtime, 2048);
    try std.testing.expectError(
        error.Exhausted,
        execute(
            &limited.context,
            .map2,
            &.{ input, singleton },
            &.{ .nil, .nil },
            add,
            &outputs,
        ),
    );
    const report = limited.budget.report() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(EvalContext.Budget.Resource.work, report.resource);
    try std.testing.expectError(
        error.Exhausted,
        execute(
            &limited.context,
            .map2,
            &.{ input, singleton },
            &.{ .nil, .nil },
            add,
            &outputs,
        ),
    );
    try std.testing.expectEqualDeep(report, limited.budget.report().?);
}

test "tensor JVP native dispatch boxes one proper result pair" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const result = try dispatch(runtime.context(), .nil, .nil, &.{
        Value.i64(@backingInt(Operation.stack)),
        .nil,
        Value.i64(1),
        Value.i64(2),
        Value.i64(10),
        .nil,
    });
    try std.testing.expectEqual(b.type_cons, result.typ);
    const first = result.obj.toRef().deref([2]Value).*;
    try expectI64Tensor(first[0], &.{2}, &.{ 1, 2 });
    try std.testing.expectEqual(b.type_cons, first[1].typ);
    const second = first[1].obj.toRef().deref([2]Value).*;
    try expectI64Tensor(second[0], &.{2}, &.{ 10, 0 });
    try std.testing.expect(Value.isNil(second[1]));

    var outputs: [2]Value = undefined;
    try std.testing.expectError(
        error.ArityMismatch,
        execute(runtime.context(), .dot, &.{first[0]}, &.{.nil}, null, &outputs),
    );
    try std.testing.expectError(
        error.TypeMismatch,
        dispatch(runtime.context(), .nil, .nil, &.{ Value.i64(9999), .nil }),
    );
    try std.testing.expectError(
        error.ArityMismatch,
        dispatch(runtime.context(), .nil, .nil, &.{
            Value.i64(@backingInt(Operation.stack)),
            .nil,
            Value.i64(1),
        }),
    );
}

test "matrix dot JVP adds both active operand contributions" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const tangent = try runtime.evalString(
        "(fst (rst (jvp (fn (a b) (dot a b)) " ++
            "(list (reshape [2.0] [1 1]) (reshape [3.0] [1 1])) " ++
            "(list (reshape [5.0] [1 1]) (reshape [7.0] [1 1])))))",
    );
    try expectF64Tensor(tangent, &.{ 1, 1 }, &.{29.0});
    try std.testing.expectEqual(Value.f64(8.0), try runtime.evalString(
        "(hvp (fn (x) (tensor-get " ++
            "(dot (reshape (stack x) [1 1]) (reshape (stack x) [1 1])) 0 0)) 3.0 4.0)",
    ));
}

test "matrix dot JVP rejects an unrepresentable integer tangent sum" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    try std.testing.expectError(error.Unsupported, runtime.evalString(
        "(jvp (fn (a b) (dot a b)) " ++
            "(list (reshape [1] [1 1]) (reshape [1] [1 1])) " ++
            "(list (reshape [9223372036854775807] [1 1]) (reshape [1] [1 1])))",
    ));
}

test "tensor reshape charges tangent data and shape conversion work" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const input = try tensor_intrin.iota(runtime.context(), .nil, .nil, &.{Value.i64(128)});
    const shape = try makeI64Tensor(runtime.context(), &.{128});
    var limited: LimitedHarness = undefined;
    try limited.init(runtime, 32);
    var outputs: [2]Value = undefined;
    try std.testing.expectError(
        error.Exhausted,
        execute(&limited.context, .reshape, &.{ input, shape }, &.{ .nil, .nil }, null, &outputs),
    );
    try std.testing.expectEqual(EvalContext.Budget.Resource.work, limited.budget.report().?.resource);

    const single = try makeI64Tensor(runtime.context(), &.{1});
    const dimensions: [128]i64 = @splat(1);
    const long_shape = try makeI64Tensor(runtime.context(), &dimensions);
    var shape_limit: LimitedHarness = undefined;
    try shape_limit.init(runtime, 32);
    try std.testing.expectError(
        error.Exhausted,
        execute(&shape_limit.context, .reshape, &.{ single, long_shape }, &.{ .nil, .nil }, null, &outputs),
    );
    try std.testing.expectEqual(EvalContext.Budget.Resource.work, shape_limit.budget.report().?.resource);
}
