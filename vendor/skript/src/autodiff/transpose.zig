//! Structural transposition for already-linear bound Code.
const std = @import("std");
const skript = @import("../root.zig");
const Code = @import("../code.zig");
const Primitive = @import("../primitive.zig");
const SourceRef = @import("../SourceUnit.zig").Ref;
const Effects = @import("../ad_effects.zig");
const rules = @import("rules.zig");
const tree = @import("tree.zig");
const space = @import("space.zig");
const linearization = @import("linearize.zig");

const Allocator = std.mem.Allocator;
const Closure = skript.data.Closure;
const Error = skript.Error;
const EvalContext = skript.EvalContext;
const Object = skript.Object;
const Runtime = skript.Runtime;
const Sym = skript.Sym;
const Value = skript.Value;
const b = skript.builtins;
const tensor_intrin = skript.intrinsics.tensor;
const forward_ad = @import("forward.zig");
const callables = @import("callable.zig");

const max_analysis_depth: usize = 256;

pub const Spaces = struct {
    region: *linearization.Region,
    inputs: []const space.SpaceSpec,
    outputs: []const space.SpaceSpec,
};

fn declaredSpace(algebra: *const space.SpaceSpec) bool {
    return algebra.usesRegisteredAlgebra();
}

const ValueClass = enum { constant, linear };

const ConstantKind = enum { none, literal, quote, global, capture, operation };

const FiniteParameters = std.StaticBitSet(256);

const SourceValue = struct {
    class: ValueClass = .constant,
    prototype: ?Value = null,
    known: ?Value = null,
    alias: Code.ValueId = .invalid,
    definition: Code.BoundNodeId = .invalid,
    constant_kind: ConstantKind = .none,
    primitive: ?Primitive.PrimitiveId = null,
    zero: bool = false,
    primal_parameter: ?u8 = null,
    algebra: ?*const space.SpaceSpec = null,
};

const SourceInfo = struct {
    closure: *const Closure,
    code: *const Code.Code,
    function: *const Code.Function,
};

const PrimitiveInfo = struct {
    spec: *const Primitive.Spec,
    descriptor: ?rules.Descriptor,
    rule: ?*const rules.PrimitiveRule,
};

const Analysis = struct {
    source: *const Code.Code,
    function_id: Code.FunctionId,
    function: *const Code.Function,
    block: *const Code.Block,
    values: []SourceValue,
    returns: []Code.ValueId,
    input_prototypes: []const Value,
    terminal: ?Code.Node = null,
    constant_parameters: usize = 0,
    partial: bool = false,
    primal_result: Code.ValueId = .invalid,
};

fn sameValue(left: Value, right: Value) bool {
    return left.typ == right.typ and left.obj == right.obj;
}

fn sourceInfo(runtime: *Runtime, source: Value) Error!SourceInfo {
    if (source.typ != b.type_closure or source.obj == .null) return error.TypeMismatch;
    const closure = source.obj.toRef().deref(Closure);
    if (closure.guard) |guard| try guard.check(runtime, guard.context);
    const code = closure.code orelse return error.Unsupported;
    if (code.owner != @as(?*const anyopaque, runtime)) return error.Denied;
    if (code.id == 0 or code.revision == 0) return error.InvalidCode;
    if (closure.function_id == .invalid) return error.InvalidCode;
    const function = code.function(closure.function_id) orelse return error.InvalidCode;
    if (function.has_rest) return error.Unsupported;
    if (closure.arglist.len != function.parameter_count) return error.InvalidCode;
    if (closure.captures.len != function.capture_count) return error.InvalidCode;
    if (closure.result_count != function.result_count) return error.InvalidCode;
    return .{ .closure = closure, .code = code, .function = function };
}

fn safePrimitive(spec: *const Primitive.Spec) Error!void {
    const effects = spec.effects;
    if (effects.state_write or effects.io or effects.clock or effects.random or
        effects.process or effects.module or effects.ffi or effects.dynamic_loader or
        effects.host or effects.unknown)
    {
        return error.Unsupported;
    }
    if (effects.state_read and !spec.reads_argument_state) return error.Unsupported;
    switch (spec.callbacks) {
        .none => {},
        else => return error.Unsupported,
    }
    switch (spec.resources) {
        .fixed, .bounded, .native => {},
        .unknown, .denied => return error.Unsupported,
    }
    switch (spec.suspension) {
        .never => {},
        else => return error.Unsupported,
    }
}

fn primitiveInfo(
    ctx: *EvalContext,
    snapshot: *const rules.RegistryVersion,
    primitive: Primitive.PrimitiveId,
) Error!PrimitiveInfo {
    const spec = ctx.registry.spec(primitive) orelse return error.Unsupported;
    try safePrimitive(spec);
    const descriptor = rules.descriptorForInvocation(spec.invoke);
    const rule = snapshot.find(primitive);
    if (descriptor == null and rule == null) return error.Unsupported;
    return .{ .spec = spec, .descriptor = descriptor, .rule = rule };
}

fn operationResultId(node: Code.Node) Error!Code.ValueId {
    if (node.result == .invalid or node.resultCount() != 1) return error.Unsupported;
    return node.result;
}

fn operandSlice(code: *const Code.Code, range: Code.OperandRange) Error![]const Code.ValueId {
    const start: usize = range.start;
    const end = std.math.add(usize, start, @as(usize, range.len)) catch return error.InvalidCode;
    if (end > code.operands.len) return error.InvalidCode;
    return code.operands[start..end];
}

fn valueInfo(values: []const SourceValue, value: Code.ValueId) Error!SourceValue {
    if (value == .invalid) return error.InvalidCode;
    const index = @backingInt(value);
    if (index >= values.len) return error.InvalidCode;
    return values[index];
}

fn setValue(values: []SourceValue, value: Code.ValueId, info: SourceValue) Error!void {
    if (value == .invalid) return error.InvalidCode;
    const index = @backingInt(value);
    if (index >= values.len) return error.InvalidCode;
    values[index] = info;
}

fn numericZero(value: Value) bool {
    if (value.typ == b.type_i8) return value.obj.toInt(i8) == 0;
    if (value.typ == b.type_i16) return value.obj.toInt(i16) == 0;
    if (value.typ == b.type_i32) return value.obj.toInt(i32) == 0;
    if (value.typ == b.type_i64) return value.obj.toInt(i64) == 0;
    if (value.typ == b.type_u8) return value.obj.toInt(u8) == 0;
    if (value.typ == b.type_u16) return value.obj.toInt(u16) == 0;
    if (value.typ == b.type_u32) return value.obj.toInt(u32) == 0;
    if (value.typ == b.type_u64) return value.obj.toInt(u64) == 0;
    if (value.typ == b.type_f16) return value.obj.tof16() == 0.0;
    if (value.typ == b.type_f32) return value.obj.tof32() == 0.0;
    if (value.typ == b.type_f64) return value.obj.tof64() == 0.0;
    return false;
}

fn zeroValue(ctx: *EvalContext, value: Value, depth: usize) Error!bool {
    if (depth >= max_analysis_depth) return error.Unsupported;
    try ctx.chargeWork(1, 1, .transform);
    if (value.isNil() or numericZero(value)) return true;
    if (value.typ == b.type_cons) {
        const pair = value.obj.toRef().deref([2]Value);
        return try zeroValue(ctx, pair[0], depth + 1) and try zeroValue(ctx, pair[1], depth + 1);
    }
    if (value.typ == b.type_tensor) {
        const holder = value.obj.toRef().deref(tensor_intrin.TensorHolder);
        try ctx.chargeWork(@intCast(holder.data.len), 1, .transform);
        for (holder.data) |word| if (!numericZero(tensor_intrin.wordToValue(holder.inner, word))) return false;
        return true;
    }
    if (value.typ == b.type_map and value.obj != .null) {
        const entries = skript.intrinsics.map.equalityView(value);
        try ctx.chargeWork(@intCast(entries.count()), 1, .transform);
        var iterator = entries.iterator();
        while (iterator.next()) |entry| {
            if (!try zeroValue(ctx, entry.value, depth + 1)) return false;
        }
        return true;
    }
    return false;
}

fn isComplexType(runtime_type: Object) bool {
    return runtime_type == b.type_c16 or runtime_type == b.type_c32 or runtime_type == b.type_c64;
}

fn listHead(value: Value) ?Value {
    if (value.typ != b.type_cons or value.obj == .null) return null;
    return value.obj.toRef().deref([2]Value).*[0];
}

fn listRest(value: Value) ?Value {
    if (value.typ != b.type_cons or value.obj == .null) return null;
    return value.obj.toRef().deref([2]Value).*[1];
}

fn makeListValue(runtime: *Runtime, values: []const Value) Error!Value {
    var result: Value = .nil;
    var index = values.len;
    while (index > 0) {
        index -= 1;
        const cell = try runtime.store.create([2]Value);
        cell.deref([2]Value).* = .{ values[index], result };
        result = .cons(cell.toObject());
    }
    return result;
}

fn shapeList(runtime: *Runtime, value: Value) Error!Value {
    if (value.typ != b.type_tensor or value.obj == .null) return error.TypeMismatch;
    const holder = value.obj.toRef().deref(tensor_intrin.TensorHolder);
    const dimensions = try runtime.static.alloc(Value, holder.shape.len);
    defer runtime.static.free(dimensions);
    for (dimensions, holder.shape) |*dimension, raw| {
        dimension.* = .i64(std.math.cast(i64, raw) orelse return error.Unsupported);
    }
    return makeListValue(runtime, dimensions);
}

fn zeroLikeValue(ctx: *EvalContext, value: Value, depth: usize) Error!Value {
    if (depth >= max_analysis_depth) return error.Unsupported;
    const runtime = ctx.runtime;
    if (tree.numericKind(value.typ) != null) return tree.zero(value.typ);
    if (value.typ == b.type_c16) return .c16(.{ 0.0, 0.0 });
    if (value.typ == b.type_c32) return .c32(.{ 0.0, 0.0 });
    if (value.typ == b.type_c64) {
        const reference = try runtime.store.create([2]f64);
        reference.deref([2]f64).* = .{ 0.0, 0.0 };
        return .c64(reference.toObject());
    }
    if (value.typ == b.type_nil) return .nil;
    if (value.typ == b.type_cons) {
        const head = listHead(value) orelse return error.TypeMismatch;
        const rest = listRest(value) orelse return error.TypeMismatch;
        const zero_head = try zeroLikeValue(ctx, head, depth + 1);
        const zero_rest = try zeroLikeValue(ctx, rest, depth + 1);
        return skript.intrinsics.list.cons(ctx, .nil, .nil, &.{ zero_head, zero_rest });
    }
    if (value.typ == b.type_tensor and value.obj != .null) {
        const holder = value.obj.toRef().deref(tensor_intrin.TensorHolder);
        const shape = try runtime.store.allocSlice(u32, holder.shape.len);
        errdefer runtime.store.discardUnpublished(shape.ref) catch unreachable;
        @memcpy(shape.slice, holder.shape);
        const data = try runtime.store.allocSlice(u64, holder.data.len);
        errdefer runtime.store.discardUnpublished(data.ref) catch unreachable;
        @memset(data.slice, switch (holder.inner) {
            .i64 => @bitCast(@as(i64, 0)),
            .f64 => @bitCast(@as(f64, 0.0)),
            else => return error.Unsupported,
        });
        const reference = try runtime.store.createTraced(
            tensor_intrin.TensorHolder,
            tensor_intrin.traceTensorHolder,
        );
        reference.deref(tensor_intrin.TensorHolder).* = .{
            .inner = holder.inner,
            .rank = holder.rank,
            .shape = shape.slice,
            .data = data.slice,
            .shape_ref = shape.ref,
            .data_ref = data.ref,
        };
        return .init(b.type_tensor, reference.toObject());
    }
    return error.Unsupported;
}

fn cloneFrozenValue(ctx: *EvalContext, value: Value, depth: usize) Error!Value {
    if (depth >= max_analysis_depth) return error.Unsupported;
    const runtime = ctx.runtime;
    if (tree.numericKind(value.typ) != null or value.typ == b.type_bool or
        value.typ == b.type_nil or value.typ == b.type_symbol or value.typ == b.type_keyword or
        value.typ == b.type_string or value.typ == b.type_type or value.typ == b.type_intrinsic or
        isComplexType(value.typ))
    {
        if (value.typ == b.type_c64 and value.obj != .null) {
            const source = value.obj.toRef().deref([2]f64);
            const copy = try runtime.store.create([2]f64);
            copy.deref([2]f64).* = source.*;
            return .c64(copy.toObject());
        }
        return value;
    }
    if (value.typ == b.type_cons) {
        const head = listHead(value) orelse return error.TypeMismatch;
        const rest = listRest(value) orelse return error.TypeMismatch;
        const copy_head = try cloneFrozenValue(ctx, head, depth + 1);
        const copy_rest = try cloneFrozenValue(ctx, rest, depth + 1);
        return skript.intrinsics.list.cons(ctx, .nil, .nil, &.{ copy_head, copy_rest });
    }
    if (value.typ == b.type_tensor and value.obj != .null) {
        const source = value.obj.toRef().deref(tensor_intrin.TensorHolder);
        const shape = try runtime.store.allocSlice(u32, source.shape.len);
        errdefer runtime.store.discardUnpublished(shape.ref) catch unreachable;
        @memcpy(shape.slice, source.shape);
        const data = try runtime.store.allocSlice(u64, source.data.len);
        errdefer runtime.store.discardUnpublished(data.ref) catch unreachable;
        @memcpy(data.slice, source.data);
        const copy = try runtime.store.createTraced(
            tensor_intrin.TensorHolder,
            tensor_intrin.traceTensorHolder,
        );
        copy.deref(tensor_intrin.TensorHolder).* = .{
            .inner = source.inner,
            .rank = source.rank,
            .shape = shape.slice,
            .data = data.slice,
            .shape_ref = shape.ref,
            .data_ref = data.ref,
        };
        return .init(b.type_tensor, copy.toObject());
    }
    // Mutable maps and callable captures are not frozen coefficients.
    return error.Unsupported;
}

fn samePrototype(left: Value, right: Value, depth: usize) bool {
    if (depth >= max_analysis_depth or left.typ != right.typ) return false;
    if (left.typ == b.type_tensor) {
        if (left.obj == .null or right.obj == .null) return false;
        const a = left.obj.toRef().deref(tensor_intrin.TensorHolder);
        const c = right.obj.toRef().deref(tensor_intrin.TensorHolder);
        return a.inner == c.inner and a.rank == c.rank and std.mem.eql(u32, a.shape, c.shape);
    }
    if (left.typ == b.type_cons) {
        if (left.obj == .null or right.obj == .null) return false;
        const left_head = listHead(left) orelse return false;
        const right_head = listHead(right) orelse return false;
        const left_rest = listRest(left) orelse return false;
        const right_rest = listRest(right) orelse return false;
        return samePrototype(left_head, right_head, depth + 1) and
            samePrototype(left_rest, right_rest, depth + 1);
    }
    if (left.typ == b.type_map) {
        if (left.obj == .null or right.obj == .null) return false;
        const a = skript.intrinsics.map.equalityView(left);
        const c = skript.intrinsics.map.equalityView(right);
        if (a.count() != c.count()) return false;
        var iterator = a.iterator();
        while (iterator.next()) |entry| {
            const other = c.map.get(entry.key) orelse return false;
            if (!samePrototype(entry.value, other, depth + 1)) return false;
        }
    }
    return true;
}
fn checkFiniteTangent(ctx: *const EvalContext, value: Value, depth: usize) Error!void {
    if (depth >= max_analysis_depth) return error.Unsupported;
    if (value.typ == b.type_f16) {
        if (!std.math.isFinite(value.obj.tof16())) return error.Unsupported;
        return;
    }
    if (value.typ == b.type_f32) {
        if (!std.math.isFinite(value.obj.tof32())) return error.Unsupported;
        return;
    }
    if (value.typ == b.type_f64) {
        if (!std.math.isFinite(value.obj.tof64())) return error.Unsupported;
        return;
    }
    if (value.typ == b.type_c16) {
        const components = value.obj.as([4]f16);
        if (!std.math.isFinite(components[0]) or !std.math.isFinite(components[1])) return error.Unsupported;
        return;
    }
    if (value.typ == b.type_c32) {
        const components = value.obj.as([2]f32);
        if (!std.math.isFinite(components[0]) or !std.math.isFinite(components[1])) return error.Unsupported;
        return;
    }
    if (value.typ == b.type_c64) {
        if (value.obj == .null) return error.Unsupported;
        const components = value.obj.toRef().deref([2]f64).*;
        if (!std.math.isFinite(components[0]) or !std.math.isFinite(components[1])) return error.Unsupported;
        return;
    }
    if (value.typ == b.type_tensor and value.obj != .null) {
        const holder = value.obj.toRef().deref(tensor_intrin.TensorHolder);
        if (holder.inner == .f64) {
            try ctx.chargeWork(@intCast(holder.data.len), 1, .transform);
            for (holder.data) |word| {
                if (!std.math.isFinite(@as(f64, @bitCast(word)))) return error.Unsupported;
            }
        }
        return;
    }
    if (value.typ == b.type_cons) {
        try checkFiniteTangent(ctx, listHead(value) orelse return error.TypeMismatch, depth + 1);
        try checkFiniteTangent(ctx, listRest(value) orelse return error.TypeMismatch, depth + 1);
    }
}

fn primitiveId(ctx: *EvalContext, native: skript.FuncPtr) Error!Primitive.PrimitiveId {
    return ctx.registry.idForNative(native) orelse return error.Unsupported;
}

fn scalarTag(value: Value) ?rules.ScalarOp {
    if (value.typ != b.type_i64) return null;
    const raw = value.obj.toInt(i64);
    if (raw < @backingInt(rules.ScalarOp.add) or
        raw > @backingInt(rules.ScalarOp.realize_tangent))
    {
        return null;
    }
    return @fromBackingInt(@intCast(raw));
}

fn sourcePrimitive(
    ctx: *EvalContext,
    snapshot: *const rules.RegistryVersion,
    values: []const SourceValue,
    primitive: Primitive.PrimitiveId,
    args: []const Code.ValueId,
) Error!PrimitiveInfo {
    const info = try primitiveInfo(ctx, snapshot, primitive);
    if (info.descriptor) |descriptor| {
        if (descriptor.rule == .dispatch) {
            if (args.len == 0) return error.ArityMismatch;
            const tag = try valueInfo(values, args[0]);
            if (tag.class != .constant) return error.Unsupported;
            const known = tag.known orelse return error.Unsupported;
            if (scalarTag(known) == null) return error.Unsupported;
        }
    }
    return info;
}

fn binaryClass(
    left: SourceValue,
    right: SourceValue,
    operation: rules.BuiltinJvp,
) Error!ValueClass {
    if (left.class == .constant and right.class == .constant) return .constant;
    if (operation == .add or operation == .sub) {
        if (left.class == .linear and right.class == .linear) return .linear;
        if (left.class == .linear and right.class == .constant and left.known == null) {
            if (right.zero) return .linear;
            if (right.known) |value| if (numericZero(value)) return .linear;
        }
        if (right.class == .linear and left.class == .constant and right.known == null) {
            if (left.zero) return .linear;
            if (left.known) |value| if (numericZero(value)) return .linear;
        }
        return error.Unsupported;
    }
    if (operation == .mul) {
        if (left.class == .linear and right.class == .constant) return .linear;
        if (right.class == .linear and left.class == .constant) return .linear;
        return error.Unsupported;
    }
    if (operation == .div) {
        if (left.class == .linear and right.class == .constant) return .linear;
        return error.Unsupported;
    }
    return error.Unsupported;
}

fn prototypeStack(ctx: *EvalContext, args: []const SourceValue) ?Value {
    const prototypes = ctx.scratch.alloc(Value, args.len) catch return null;
    defer ctx.scratch.free(prototypes);
    for (args, prototypes) |arg, *prototype| prototype.* = arg.prototype orelse return null;
    return tensor_intrin.create(ctx, .nil, .nil, prototypes) catch null;
}

fn prototypeList(ctx: *EvalContext, args: []const SourceValue) ?Value {
    const prototypes = ctx.scratch.alloc(Value, args.len) catch return null;
    defer ctx.scratch.free(prototypes);
    for (args, prototypes) |arg, *prototype| prototype.* = arg.prototype orelse return null;
    return makeListValue(ctx.runtime, prototypes) catch null;
}

fn prototypeReshape(ctx: *EvalContext, source: ?Value, shape: ?Value) ?Value {
    const source_value = source orelse return null;
    const shape_value = shape orelse return null;
    return tensor_intrin.reshape(ctx, .nil, .nil, &.{ source_value, shape_value }) catch null;
}

fn prototypeTranspose(
    ctx: *EvalContext,
    source: ?Value,
    permutation: ?Value,
    explicit_permutation: bool,
) Error!?Value {
    const source_value = source orelse return null;
    if (explicit_permutation) {
        const permutation_value = permutation orelse return null;
        const result = try tensor_intrin.trans(ctx, .nil, .nil, &.{ source_value, permutation_value });
        return result;
    }
    const result = try tensor_intrin.trans(ctx, .nil, .nil, &.{source_value});
    return result;
}

fn prototypeTensorElement(value: ?Value) ?Value {
    const input = value orelse return null;
    if (input.typ != b.type_tensor or input.obj == .null) return null;
    const holder = input.obj.toRef().deref(tensor_intrin.TensorHolder);
    return switch (holder.inner) {
        .i64 => .i64(0),
        .f64 => .f64(0.0),
        else => null,
    };
}

fn prototypeDot(ctx: *EvalContext, left: ?Value, right: ?Value) ?Value {
    const left_value = left orelse return null;
    const right_value = right orelse return null;
    return tensor_intrin.dot(ctx, .nil, .nil, &.{ left_value, right_value }) catch null;
}

fn prototypeMap(ctx: *EvalContext, args: []const SourceValue) Error!?Value {
    if (args.len % 2 != 0) return error.ArityMismatch;
    const pairs = try ctx.scratch.alloc(Value, args.len);
    defer ctx.scratch.free(pairs);
    for (args, 0..) |arg, index| {
        pairs[index] = if (index % 2 == 0)
            arg.known orelse return null
        else
            arg.prototype orelse return null;
    }
    const value = try skript.intrinsics.map.create(ctx, .nil, .nil, pairs);
    return value;
}

const Analyzer = struct {
    ctx: *EvalContext,
    scratch: Allocator,
    source: *const Code.Code,
    closure: *const Closure,
    function_id: Code.FunctionId,
    function: *const Code.Function,
    input_prototypes: []const Value,
    output_prototypes: []const Value,
    snapshot: *const rules.RegistryVersion,
    values: []SourceValue,
    returns: []Code.ValueId,
    constant_parameters: usize = 0,
    partial: bool = false,
    spaces: ?Spaces = null,
    finite_primal_parameters: FiniteParameters = .empty,
    candidate_region: ?*linearization.Region = null,

    fn init(
        scratch: Allocator,
        ctx: *EvalContext,
        info: SourceInfo,
        input_prototypes: []const Value,
        output_prototypes: []const Value,
        snapshot: *const rules.RegistryVersion,
    ) Error!Analyzer {
        const values = try scratch.alloc(SourceValue, info.code.values.len);
        @memset(values, .{});
        const returns = try scratch.alloc(Code.ValueId, output_prototypes.len);
        @memset(returns, .invalid);
        return .{
            .ctx = ctx,
            .scratch = scratch,
            .source = info.code,
            .closure = info.closure,
            .function_id = info.closure.function_id,
            .function = info.function,
            .input_prototypes = input_prototypes,
            .output_prototypes = output_prototypes,
            .snapshot = snapshot,
            .values = values,
            .returns = returns,
        };
    }
    fn tensorLinearInfo(self: *const Analyzer, id: u64) Error!linearization.TensorLinearInfo {
        if (self.candidate_region) |region| {
            return linearization.Region.tensorLinearInfoIn(self.ctx, id, region);
        }
        return linearization.tensorLinearInfo(self.ctx, id);
    }

    fn markParameters(self: *Analyzer) Error!void {
        const first: usize = self.function.parameter_start;
        const last = std.math.add(usize, first, @as(usize, self.function.parameter_count)) catch
            return error.InvalidCode;
        if (last > self.source.parameters.len or self.input_prototypes.len != self.function.parameter_count) {
            return error.ArityMismatch;
        }
        for (self.source.parameters[first..last], 0..) |binding_id, index| {
            const binding_index = @backingInt(binding_id);
            if (binding_index >= self.source.bindings.len) return error.InvalidCode;
            const binding = self.source.bindings[binding_index];
            try setValue(self.values, binding.value, .{
                .class = if (index < self.constant_parameters) .constant else .linear,
                .prototype = self.input_prototypes[index],
                .primal_parameter = if (index < self.constant_parameters)
                    @as(u8, @intCast(index))
                else
                    null,
                .algebra = if (self.spaces) |domains|
                    if (declaredSpace(&domains.inputs[index])) &domains.inputs[index] else null
                else
                    null,
            });
        }

        const capture_first: usize = self.function.capture_start;
        const capture_last = std.math.add(usize, capture_first, @as(usize, self.function.capture_count)) catch
            return error.InvalidCode;
        if (capture_last > self.source.captures.len or capture_last > self.source.capture_values.len) {
            return error.InvalidCode;
        }
        for (self.source.capture_values[capture_first..capture_last], 0..) |value_id, index| {
            if (index >= self.closure.captures.len) return error.InvalidCode;
            try setValue(self.values, value_id, .{
                .class = .constant,
                .prototype = self.closure.captures[index],
                .known = self.closure.captures[index],
                .constant_kind = .capture,
            });
        }
    }

    fn resolvePrimitive(self: *Analyzer, callable: Value, arguments: []const Code.ValueId) Error!Primitive.PrimitiveId {
        var selected = callable;
        if (selected.typ == b.type_method) {
            const prototypes = try self.ctx.scratch.alloc(Value, arguments.len);
            defer self.ctx.scratch.free(prototypes);
            for (arguments, prototypes) |argument, *prototype| {
                const info = try valueInfo(self.values, argument);
                prototype.* = info.known orelse info.prototype orelse return error.Unsupported;
            }
            selected = try selected.obj.toRef().deref(skript.data.Method).get(self.ctx.runtime, prototypes);
        }
        if (selected.typ != b.type_intrinsic) return error.Unsupported;
        return self.ctx.registry.idForNative(selected.obj.toPtr(skript.FuncPtr)) orelse error.Unsupported;
    }

    fn requireFiniteZeroOperand(self: *Analyzer, operand: SourceValue) Error!void {
        if (operand.zero) return;
        if (operand.known) |known| return checkFiniteTangent(self.ctx, known, 0);
        if (operand.primal_parameter) |index| {
            // Coefficient kernels are reused for later elements of the same type.
            self.finite_primal_parameters.set(index);
            return;
        }
        // A computed constant can overflow even when its inputs are finite.
        return error.Unsupported;
    }

    fn binaryZero(
        self: *Analyzer,
        left: SourceValue,
        right: SourceValue,
        operation: rules.BuiltinJvp,
    ) Error!bool {
        return switch (operation) {
            .add, .sub => left.zero and right.zero,
            .mul => blk: {
                // Linear operands may produce non-finite values despite a zero
                // factor; their class is sufficient to retain the output.
                if (left.class == .linear or right.class == .linear) break :blk false;
                if (left.zero) try self.requireFiniteZeroOperand(right);
                if (right.zero) try self.requireFiniteZeroOperand(left);
                break :blk left.zero or right.zero;
            },
            else => false,
        };
    }

    fn analyzeArithmetic(self: *Analyzer, node: Code.Node, arithmetic: Code.Arithmetic) Error!SourceValue {
        if (arithmetic.callee == .invalid or arithmetic.expected_callee.isNil()) return error.Unsupported;
        const primitive = try self.resolvePrimitive(
            arithmetic.expected_callee,
            &.{ arithmetic.left, arithmetic.right },
        );
        const info = try primitiveInfo(self.ctx, self.snapshot, primitive);
        const descriptor = info.descriptor orelse return error.Unsupported;
        const expected = switch (arithmetic.op) {
            .add => rules.BuiltinJvp.add,
            .sub => rules.BuiltinJvp.sub,
            .mul => rules.BuiltinJvp.mul,
            .div => rules.BuiltinJvp.div,
            .equal, .less, .greater => rules.BuiltinJvp.predicate,
        };
        if (descriptor.rule != expected) return error.Unsupported;
        const left = try valueInfo(self.values, arithmetic.left);
        const right = try valueInfo(self.values, arithmetic.right);
        const class = if (arithmetic.op == .equal or arithmetic.op == .less or arithmetic.op == .greater) blk: {
            if (left.class == .linear or right.class == .linear) return error.Unsupported;
            break :blk ValueClass.constant;
        } else try binaryClass(left, right, expected);
        return .{
            .class = class,
            .prototype = if (left.prototype) |prototype| prototype else right.prototype,
            .definition = node.id,
            .constant_kind = if (class == .constant) .operation else .none,
            .zero = try self.binaryZero(left, right, expected),
        };
    }

    fn analyzePrimitive(self: *Analyzer, node: Code.Node, call: Code.PrimitiveCall) Error!SourceValue {
        const args = try operandSlice(self.source, call.args);
        const info = try sourcePrimitive(self.ctx, self.snapshot, self.values, call.primitive, args);
        const descriptor = info.descriptor orelse {
            var active = false;
            for (args) |arg| active = active or (try valueInfo(self.values, arg)).class == .linear;
            if (!active) return .{ .class = .constant, .definition = node.id, .constant_kind = .operation };
            const rule = info.rule orelse return error.Unsupported;
            if (rule.metadata.linearity != .linear) return error.Unsupported;
            return .{
                .class = .linear,
                .prototype = resultPrototypeFromArgs(self.values, args),
                .definition = node.id,
            };
        };

        var actual_args = args;
        var scalar_operation: ?rules.ScalarOp = null;
        if (descriptor.rule == .dispatch) {
            if (args.len == 0) return error.ArityMismatch;
            const tag = (try valueInfo(self.values, args[0])).known orelse return error.Unsupported;
            scalar_operation = scalarTag(tag) orelse return error.Unsupported;
            actual_args = args[1..];
        }
        const classes = try self.ctx.scratch.alloc(SourceValue, actual_args.len);
        defer self.ctx.scratch.free(classes);
        for (actual_args, classes) |arg, *entry| entry.* = try valueInfo(self.values, arg);

        const selected = scalar_operation orelse null;
        const operation = if (selected) |scalar|
            rules.scalarJvp(scalar) orelse return error.Unsupported
        else
            descriptor.rule;
        var class: ValueClass = .constant;
        var prototype: ?Value = null;
        var algebra: ?*const space.SpaceSpec = null;
        var zero = scalar_operation == .zero_like;
        switch (operation) {
            .runtime_owned_output => {
                if (classes.len != 1) return error.ArityMismatch;
                class = classes[0].class;
                prototype = classes[0].prototype;
                zero = classes[0].zero;
                algebra = classes[0].algebra;
            },
            .tensor_linear_apply, .tensor_linear_transpose => {
                if (classes.len < 2 or classes[0].class != .constant) return error.Unsupported;
                const record_id = classes[0].known orelse return error.Unsupported;
                if (record_id.typ != b.type_i64 or record_id.obj.toInt(i64) <= 0) return error.TypeMismatch;
                var record = try self.tensorLinearInfo(@intCast(record_id.obj.toInt(i64)));
                defer record.deinit();
                if (operation == .tensor_linear_apply) {
                    if (classes.len != record.input_count + 1) return error.ArityMismatch;
                    for (classes[1..]) |entry| {
                        if (entry.class == .linear) class = .linear;
                    }
                    prototype = record.output;
                } else {
                    if (classes.len != 2) return error.ArityMismatch;
                    class = classes[1].class;
                    prototype = try makeListValue(self.ctx.runtime, record.input_prototypes);
                }
            },
            .constant, .predicate => {
                for (classes) |entry| if (entry.class == .linear) return error.Unsupported;
            },
            .construct => {
                if (scalar_operation == .coerce_tangent or scalar_operation == .realize_tangent) {
                    if (classes.len != 2 or classes[0].class != .constant) return error.Unsupported;
                    class = classes[1].class;
                    prototype = if (classes[0].prototype) |primal_prototype|
                        if (tree.numericKind(primal_prototype.typ) != null)
                            classes[0].prototype
                        else
                            classes[1].prototype
                    else
                        classes[1].prototype;
                    if (self.spaces) |domains| {
                        const primal = classes[0].known orelse return error.Unsupported;
                        const resolved = try domains.region.resolveSpace(self.ctx, primal);
                        prototype = try resolved.tangentZero(self.ctx);
                        if (declaredSpace(&resolved)) {
                            const retained = try self.scratch.create(space.SpaceSpec);
                            retained.* = resolved;
                            algebra = retained;
                            if (classes[1].algebra == null and !tree.isNumeric(prototype.?)) {
                                self.values[@backingInt(actual_args[1])].algebra = retained;
                            }
                        }
                    }
                    zero = classes[1].zero;
                } else {
                    if (classes.len != 1) return error.ArityMismatch;
                    class = classes[0].class;
                    prototype = classes[0].prototype;
                    zero = classes[0].zero;
                }
            },
            .add, .sub, .mul, .div => {
                if (classes.len != 2) return error.ArityMismatch;
                class = try binaryClass(classes[0], classes[1], operation);
                prototype = if (classes[0].prototype) |value| value else classes[1].prototype;
                zero = try self.binaryZero(classes[0], classes[1], operation);
            },
            .neg => {
                if (classes.len != 1) return error.ArityMismatch;
                class = classes[0].class;
                prototype = classes[0].prototype;
                zero = classes[0].zero;
            },
            .cons => {
                if (classes.len != 2) return error.ArityMismatch;
                class = if (classes[0].class == .linear or classes[1].class == .linear) .linear else .constant;
                if (classes[0].prototype) |left| {
                    if (classes[1].prototype) |right| {
                        prototype = try skript.intrinsics.list.cons(
                            self.ctx,
                            .nil,
                            .nil,
                            &.{ left, right },
                        );
                    }
                }
            },
            .fst, .rst => {
                if (classes.len != 1) return error.ArityMismatch;
                class = classes[0].class;
                prototype = classes[0].prototype;
                if (prototype) |value| {
                    prototype = if (operation == .fst) listHead(value) else listRest(value);
                }
            },
            .list => {
                if (classes.len == 0) return error.ArityMismatch;
                for (classes) |entry| {
                    if (entry.class == .linear) class = .linear;
                }
                prototype = prototypeList(self.ctx, classes);
            },
            .map_create => {
                if (classes.len % 2 != 0) return error.ArityMismatch;
                var index: usize = 0;
                while (index < classes.len) : (index += 2) {
                    if (classes[index].class == .linear) return error.Unsupported;
                    if (classes[index + 1].class == .linear) class = .linear;
                    const key = classes[index].known orelse return error.Unsupported;
                    const map_key = try skript.intrinsics.map.keyOf(self.ctx, key);
                    var previous: usize = 0;
                    while (previous < index) : (previous += 2) {
                        const prior = classes[previous].known orelse return error.Unsupported;
                        const prior_key = try skript.intrinsics.map.keyOf(self.ctx, prior);
                        if (skript.data.MapKey.Context.eql(.{}, map_key, prior_key)) return error.Unsupported;
                    }
                }
                prototype = try prototypeMap(self.ctx, classes);
            },
            .map_get => {
                if (classes.len != 2) return error.ArityMismatch;
                if (classes[1].class != .constant) return error.Unsupported;
                class = classes[0].class;
                const input = classes[0].prototype orelse return error.Unsupported;
                const key = classes[1].known orelse return error.Unsupported;
                if (input.typ != b.type_map or input.obj == .null) return error.TypeMismatch;
                const map_key = try skript.intrinsics.map.keyOf(self.ctx, key);
                prototype = skript.intrinsics.map.equalityView(input).map.get(map_key) orelse
                    return error.Unsupported;
            },
            .stack => {
                if (classes.len == 0) return error.ArityMismatch;
                for (classes) |entry| {
                    if (entry.class == .linear) class = .linear;
                }
                prototype = prototypeStack(self.ctx, classes);
            },
            .tensor_get => {
                if (classes.len < 2) return error.ArityMismatch;
                if (classes[0].class == .linear) class = .linear;
                for (classes[1..]) |entry| if (entry.class == .linear) return error.Unsupported;
                prototype = prototypeTensorElement(classes[0].prototype);
            },
            .reshape => {
                if (classes.len != 2) return error.ArityMismatch;
                if (classes[1].class == .linear) return error.Unsupported;
                class = classes[0].class;
                prototype = prototypeReshape(self.ctx, classes[0].prototype, classes[1].prototype);
            },
            .transpose => {
                if (classes.len < 1 or classes.len > 2) return error.ArityMismatch;
                const explicit_permutation = classes.len == 2;
                if (explicit_permutation and classes[1].class == .linear) return error.Unsupported;
                class = classes[0].class;
                prototype = try prototypeTranspose(
                    self.ctx,
                    classes[0].prototype,
                    if (explicit_permutation) classes[1].prototype else null,
                    explicit_permutation,
                );
            },
            .dot => {
                if (classes.len != 2) return error.ArityMismatch;
                if (classes[0].class == .linear and classes[1].class == .linear) return error.Unsupported;
                class = if (classes[0].class == .constant and classes[1].class == .constant) .constant else .linear;
                if (classes[0].class == .linear and classes[1].class != .constant) return error.Unsupported;
                if (classes[1].class == .linear and classes[0].class != .constant) return error.Unsupported;
                prototype = prototypeDot(self.ctx, classes[0].prototype, classes[1].prototype);
            },
            else => {
                for (classes) |entry| if (entry.class == .linear) return error.Unsupported;
            },
        }
        return .{
            .class = class,
            .prototype = prototype,
            .definition = node.id,
            .constant_kind = if (class == .constant) .operation else .none,
            .zero = zero,
            .algebra = algebra,
        };
    }

    fn analyzeCellWrite(self: *Analyzer, cell: Code.GlobalCellId, value: Code.ValueId) Error!void {
        const cell_index = @backingInt(cell);
        if (cell_index >= self.source.globals.len) return error.InvalidCode;
        const target = self.source.globals[cell_index];
        if (target.binding == .invalid) return error.Unsupported;
        const binding_index = @backingInt(target.binding);
        if (binding_index >= self.source.bindings.len) return error.InvalidCode;
        const definition = self.source.bindings[binding_index];
        if (definition.kind != .let and definition.kind != .definition) return error.Unsupported;
        if (definition.function != self.function_id) return error.Unsupported;
        const written = try valueInfo(self.values, value);
        try setValue(self.values, definition.value, written);
    }

    fn analyzeNode(self: *Analyzer, node: Code.Node) Error!void {
        if (node.function != self.function_id) return error.InvalidCode;
        switch (node.operation) {
            .global_write => |write| {
                if (write.assign_existing) return error.Unsupported;
                return self.analyzeCellWrite(write.cell, write.value);
            },
            .ns_push, .ns_pop => return,
            else => {},
        }
        const result = try operationResultId(node);
        var info: SourceValue = undefined;
        switch (node.operation) {
            .literal => |value| info = .{
                .class = .constant,
                .prototype = value,
                .known = value,
                .definition = node.id,
                .constant_kind = .literal,
                .zero = try zeroValue(self.ctx, value, 0),
            },
            .quote => |value| info = .{
                .class = .constant,
                .prototype = value,
                .known = value,
                .definition = node.id,
                .constant_kind = .quote,
                .zero = try zeroValue(self.ctx, value, 0),
            },
            .local_read => |binding| {
                if (@backingInt(binding) >= self.source.bindings.len) return error.InvalidCode;
                const definition = self.source.bindings[@backingInt(binding)];
                const target = if (definition.function == self.function_id) definition.value else blk: {
                    const first = self.function.capture_start;
                    const last = first + self.function.capture_count;
                    for (self.source.captures[first..last], self.source.capture_values[first..last]) |captured, value| {
                        if (captured == binding) break :blk value;
                    }
                    return error.InvalidCode;
                };
                const target_info = try valueInfo(self.values, target);
                info = target_info;
                info.alias = target;
                info.definition = node.id;
            },
            .global_read => |global| {
                if (@backingInt(global) >= self.source.globals.len) return error.InvalidCode;
                const cell = self.source.globals[@backingInt(global)];
                if (cell.binding != .invalid) {
                    const binding_index = @backingInt(cell.binding);
                    if (binding_index >= self.source.bindings.len) return error.InvalidCode;
                    const definition = self.source.bindings[binding_index];
                    if ((definition.kind == .let or definition.kind == .definition) and
                        definition.function == self.function_id)
                    {
                        const target_info = try valueInfo(self.values, definition.value);
                        info = target_info;
                        info.alias = definition.value;
                        info.definition = node.id;
                    } else return error.Unsupported;
                } else {
                    const known = try self.ctx.runtime.nsGet(self.closure.parent_ns, cell.name);
                    info = .{
                        .class = .constant,
                        .known = known,
                        .prototype = known,
                        .definition = node.id,
                        .constant_kind = .global,
                    };
                }
            },
            .global_write => unreachable,
            .ns_push, .ns_pop => unreachable,
            .try_begin, .try_end, .make_closure => return error.Unsupported,
            .arithmetic => |arithmetic| info = try self.analyzeArithmetic(node, arithmetic),
            .primitive_call => |call| info = try self.analyzePrimitive(node, call),
            .dynamic_call => |call| {
                const callable = (try valueInfo(self.values, call.callee)).known orelse return error.Unsupported;
                const primitive = try self.resolvePrimitive(callable, try operandSlice(self.source, call.args));
                info = try self.analyzePrimitive(
                    node,
                    .{ .primitive = primitive, .args = call.args, .result_count = call.result_count },
                );
                info.primitive = primitive;
            },
            .direct_call => return error.Unsupported,
        }
        try setValue(self.values, result, info);
    }

    fn run(self: *Analyzer) Error!Analysis {
        try self.markParameters();
        const block_start: usize = self.function.block_start;
        const block_end = std.math.add(usize, block_start, @as(usize, self.function.block_count)) catch
            return error.InvalidCode;
        if (self.function.block_count != 1 or block_end > self.source.function_blocks.len) {
            return error.Unsupported;
        }
        const block_id = self.source.function_blocks[block_start];
        const block_index = @backingInt(block_id);
        if (block_index >= self.source.blocks.len) return error.InvalidCode;
        const block = &self.source.blocks[block_index];
        if (block.function != self.function_id or block.param_count != 0) return error.Unsupported;
        const node_start: usize = block.node_start;
        const node_end = std.math.add(usize, node_start, @as(usize, block.node_count)) catch
            return error.InvalidCode;
        if (node_end > self.source.block_nodes.len) return error.InvalidCode;
        for (self.source.block_nodes[node_start..node_end]) |node_id| {
            const node_index = @backingInt(node_id);
            if (node_index >= self.source.nodes.len) return error.InvalidCode;
            try self.analyzeNode(self.source.nodes[node_index]);
        }
        if (block.terminator == .tail_call) {
            const call = block.terminator.tail_call;
            if (call.result_count != 1 or self.output_prototypes.len != 1) return error.Unsupported;
            const callable = (try valueInfo(self.values, call.callee)).known orelse return error.Unsupported;
            const primitive = try self.resolvePrimitive(callable, try operandSlice(self.source, call.args));
            const terminal: Code.Node = .{
                .id = .invalid,
                .function = self.function_id,
                .block = block.id,
                .operation = .{ .primitive_call = .{ .primitive = primitive, .args = call.args, .result_count = 1 } },
                .source = self.function.source,
            };
            const entry = try self.analyzePrimitive(terminal, terminal.operation.primitive_call);
            if (entry.class != .linear and !entry.zero) return error.Unsupported;
            if (!samePrototype(
                entry.prototype orelse return error.TypeMismatch,
                self.output_prototypes[0],
                0,
            )) return error.TypeMismatch;
            return .{
                .source = self.source,
                .function_id = self.function_id,
                .function = self.function,
                .block = block,
                .values = self.values,
                .returns = self.returns,
                .input_prototypes = self.input_prototypes,
                .terminal = terminal,
                .constant_parameters = self.constant_parameters,
                .partial = self.partial,
            };
        }

        const returned = switch (block.terminator) {
            .return_values => |range| try operandSlice(self.source, range),
            else => return error.Unsupported,
        };
        if (returned.len != self.output_prototypes.len or returned.len != self.function.result_count) {
            return error.ArityMismatch;
        }
        for (returned, self.returns, self.output_prototypes, 0..) |value, *slot, prototype, index| {
            const entry = try valueInfo(self.values, value);
            const actual = entry.prototype;
            const is_primal = self.constant_parameters != 0 and index == 0;
            if (self.partial) {
                if (entry.class != .constant and entry.class != .linear and !entry.zero) {
                    return error.Unsupported;
                }
            } else if (is_primal) {
                if (entry.class != .constant) return error.Unsupported;
            } else if (entry.class != .linear and !entry.zero) {
                return error.Unsupported;
            }
            const actual_value = actual orelse return error.TypeMismatch;
            if (!samePrototype(actual_value, prototype, 0)) return error.TypeMismatch;
            slot.* = value;
        }
        return .{
            .source = self.source,
            .function_id = self.function_id,
            .function = self.function,
            .block = block,
            .values = self.values,
            .returns = if (self.partial)
                self.returns
            else
                self.returns[if (self.constant_parameters == 0) 0 else 1..],
            .input_prototypes = self.input_prototypes,
            .constant_parameters = self.constant_parameters,
            .partial = self.partial,
            .primal_result = if (self.partial or self.constant_parameters == 0)
                .invalid
            else
                self.returns[0],
        };
    }
};

const GenerationMode = enum { coefficients, partial };

fn resultPrototypeFromArgs(values: []const SourceValue, args: []const Code.ValueId) ?Value {
    for (args) |arg| {
        const info = valueInfo(values, arg) catch continue;
        if (info.prototype) |prototype| return prototype;
    }
    return null;
}

fn validateStructuralRule(
    ctx: *EvalContext,
    snapshot: *const rules.RegistryVersion,
    body: rules.CodeRule,
) Error!void {
    if (body.code.owner != @as(?*const anyopaque, ctx.runtime)) return error.Denied;
    if (body.function == .invalid or body.arity == 0) return error.Unsupported;
    const function = body.code.function(body.function) orelse return error.InvalidCode;
    if (function.has_rest or function.parameter_count != body.arity or function.result_count != 1) {
        return error.Unsupported;
    }
    try body.code.validate(ctx.scratch, ctx);
    if (function.capture_count != 0 and body.callable.isNil()) return error.Unsupported;
    _ = snapshot;
    // A registered body is still subject to this transformer's structural pass.
    // The complete operand and control checks run when it is transformed.
}

const Transposer = struct {
    ctx: *EvalContext,
    runtime: *Runtime,
    source: *const Code.Code,
    source_closure: *const Closure,
    analysis: Analysis,
    snapshot: *const rules.RegistryVersion,
    builder: Code.Builder,
    function_id: Code.FunctionId,
    block_id: Code.BlockId,
    generated_values: []Code.ValueId,
    adjoints: []Code.ValueId,
    output_parameters: []Code.ValueId,
    parameter_bindings: []const Code.BindingId,
    scalar_add_helper: Code.FunctionId = .invalid,
    scalar_mul_helper: Code.FunctionId = .invalid,
    scalar_neg_helper: Code.FunctionId = .invalid,
    spaces: ?Spaces = null,
    space_ids: []u64,

    fn algebraForValue(self: *Transposer, value: Code.ValueId) Error!space.SpaceSpec {
        const info = try self.sourceValue(value);
        if (info.algebra) |algebra| return algebra.*;
        const prototype = info.prototype orelse return error.Unsupported;
        if (!tree.isNumeric(prototype)) return error.Unsupported;
        return space.scalar(prototype.typ);
    }

    fn retainSpace(self: *Transposer, algebra: space.SpaceSpec, source: SourceRef) Error!Code.ValueId {
        const domains = self.spaces orelse return error.Unsupported;
        const id = try domains.region.addSpace(self.ctx, algebra);
        return self.emitLiteral(Value.u64(id), source);
    }

    fn valueSpaceId(self: *Transposer, value: Code.ValueId, source: SourceRef) Error!Code.ValueId {
        const index = @backingInt(value);
        if (index >= self.space_ids.len) return error.InvalidCode;
        if (self.space_ids[index] == 0) {
            const domains = self.spaces orelse return error.Unsupported;
            self.space_ids[index] = try domains.region.addSpace(self.ctx, try self.algebraForValue(value));
        }
        return self.emitLiteral(Value.u64(self.space_ids[index]), source);
    }

    fn pullScalar(
        self: *Transposer,
        input: Code.ValueId,
        output: SourceValue,
        coefficient: ?Code.ValueId,
        cotangent: Code.ValueId,
        source: SourceRef,
    ) Error!Code.ValueId {
        const input_info = try self.sourceValue(input);
        if (input_info.algebra == null and output.algebra == null) {
            return if (coefficient) |factor| self.emitScale(cotangent, factor, source) else cotangent;
        }
        const input_algebra = try self.algebraForValue(input);
        const output_algebra = if (output.algebra) |algebra| algebra.* else blk: {
            const prototype = output.prototype orelse return error.Unsupported;
            if (!tree.isNumeric(prototype)) return error.Unsupported;
            break :blk space.scalar(prototype.typ);
        };
        if (coefficient == null and linearization.sameLinearSpace(&input_algebra, &output_algebra)) {
            return cotangent;
        }
        const input_id = try self.valueSpaceId(input, source);
        const output_id = try self.retainSpace(output_algebra, source);
        const factor = coefficient orelse try self.emitLiteral(Value.i64(1), source);
        return self.emitPrimitive(
            try primitiveId(self.ctx, &linearization.scalarAdjoint),
            &.{ input_id, output_id, factor, cotangent },
            source,
        );
    }

    fn operationValue(self: *Transposer, node: Code.Node) Error!SourceValue {
        if (node.result != .invalid) return self.sourceValue(node.result);
        if (self.spaces) |domains| {
            if (domains.outputs.len != 1) return error.ArityMismatch;
            return .{
                .class = .linear,
                .prototype = try domains.outputs[0].tangentZero(self.ctx),
                .algebra = if (declaredSpace(&domains.outputs[0])) &domains.outputs[0] else null,
            };
        }
        return .{};
    }

    fn sourceValue(self: *const Transposer, value: Code.ValueId) Error!SourceValue {
        return valueInfo(self.analysis.values, value);
    }
    fn emitNode(self: *Transposer, operation: Code.Operation, source: SourceRef) Error!Code.ValueId {
        return self.builder.addNode(self.function_id, self.block_id, operation, source);
    }
    fn emitLiteral(self: *Transposer, value: Value, source: SourceRef) Error!Code.ValueId {
        const frozen = try cloneFrozenValue(self.ctx, value, 0);
        return self.emitNode(.{ .literal = frozen }, source);
    }
    fn emitConstant(self: *Transposer, value: Code.ValueId, depth: usize) Error!Code.ValueId {
        if (depth >= max_analysis_depth) return error.Unsupported;
        if (value == .invalid) return error.InvalidCode;
        const index = @backingInt(value);
        if (index >= self.generated_values.len) return error.InvalidCode;
        if (self.generated_values[index] != .invalid) return self.generated_values[index];
        const info = self.analysis.values[index];
        if (info.class != .constant) return error.Unsupported;
        if (info.constant_kind == .capture) {
            const literal = info.known orelse return error.Unsupported;
            const result = try self.emitLiteral(literal, self.analysis.function.source);
            self.generated_values[index] = result;
            return result;
        }
        if (info.alias != .invalid) {
            const result = try self.emitConstant(info.alias, depth + 1);
            self.generated_values[index] = result;
            return result;
        }
        const node_id = info.definition;
        if (node_id == .invalid) return error.Unsupported;
        const node_index = @backingInt(node_id);
        if (node_index >= self.source.nodes.len) return error.InvalidCode;
        const node = self.source.nodes[node_index];
        const result = switch (node.operation) {
            .literal => |literal| try self.emitLiteral(literal, node.source),
            .quote => |quoted| self.emitNode(.{ .quote = quoted }, node.source) catch return error.OutOfMemory,
            .global_read => |global| blk: {
                const cell = self.source.globals[@backingInt(global)];
                if (cell.binding != .invalid) {
                    const binding_index = @backingInt(cell.binding);
                    if (binding_index >= self.source.bindings.len) return error.InvalidCode;
                    const definition = self.source.bindings[binding_index];
                    if ((definition.kind != .let and definition.kind != .definition) or
                        definition.function != self.function_id) return error.Unsupported;
                    break :blk try self.emitConstant(definition.value, depth + 1);
                }
                const generated_global = try self.builder.addGlobal(cell.name, cell.source);
                break :blk try self.emitNode(.{ .global_read = generated_global }, node.source);
            },
            .local_read => |binding| blk: {
                if (@backingInt(binding) >= self.source.bindings.len) return error.InvalidCode;
                break :blk try self.emitConstant(self.source.bindings[@backingInt(binding)].value, depth + 1);
            },
            .arithmetic => |arithmetic| blk: {
                const left = try self.emitConstant(arithmetic.left, depth + 1);
                const right = try self.emitConstant(arithmetic.right, depth + 1);
                const callee = if (arithmetic.expected_callee.typ == b.type_intrinsic)
                    try self.emitLiteral(arithmetic.expected_callee, node.source)
                else
                    try self.emitConstant(arithmetic.callee, depth + 1);
                break :blk try self.emitNode(.{ .arithmetic = .{
                    .op = arithmetic.op,
                    .left = left,
                    .right = right,
                    .callee = callee,
                    .expected_callee = arithmetic.expected_callee,
                    .left_types = arithmetic.left_types,
                    .right_types = arithmetic.right_types,
                } }, node.source);
            },
            .primitive_call => |call| blk: {
                const args = try operandSlice(self.source, call.args);
                var generated = std.ArrayList(Code.ValueId).empty;
                defer generated.deinit(self.ctx.scratch);
                for (args) |arg| try generated.append(self.ctx.scratch, try self.emitConstant(arg, depth + 1));
                break :blk try self.emitNode(.{ .primitive_call = .{
                    .primitive = call.primitive,
                    .args = try self.builder.addOperands(generated.items),
                    .result_count = 1,
                    .tail = call.tail,
                } }, node.source);
            },
            .dynamic_call => |call| blk: {
                const args = try operandSlice(self.source, call.args);
                const generated = try self.ctx.scratch.alloc(Code.ValueId, args.len);
                defer self.ctx.scratch.free(generated);
                for (args, generated) |argument, *slot| slot.* = try self.emitConstant(argument, depth + 1);
                break :blk try self.emitNode(.{ .primitive_call = .{
                    .primitive = info.primitive orelse return error.Unsupported,
                    .args = try self.builder.addOperands(generated),
                } }, node.source);
            },
            else => return error.Unsupported,
        };
        self.generated_values[index] = result;
        return result;
    }

    fn emitPrimitive(
        self: *Transposer,
        primitive: Primitive.PrimitiveId,
        args: []const Code.ValueId,
        source: SourceRef,
    ) Error!Code.ValueId {
        return self.emitNode(.{ .primitive_call = .{
            .primitive = primitive,
            .args = try self.builder.addOperands(args),
            .result_count = 1,
        } }, source);
    }

    fn emitScalar(
        self: *Transposer,
        operation: rules.ScalarOp,
        args: []const Code.ValueId,
        source: SourceRef,
    ) Error!Code.ValueId {
        const primitive = try primitiveId(self.ctx, &rules.scalarDispatch);
        const tag = try self.emitNode(.{ .literal = .i64(@backingInt(operation)) }, source);
        var operands = std.ArrayList(Code.ValueId).empty;
        defer operands.deinit(self.ctx.scratch);
        try operands.append(self.ctx.scratch, tag);
        try operands.appendSlice(self.ctx.scratch, args);
        return self.emitPrimitive(primitive, operands.items, source);
    }

    fn scalarHelper(self: *Transposer, operation: rules.ScalarOp) Error!Code.FunctionId {
        const slot = switch (operation) {
            .add => &self.scalar_add_helper,
            .mul => &self.scalar_mul_helper,
            .neg => &self.scalar_neg_helper,
            else => return error.Unsupported,
        };
        if (slot.* != .invalid) return slot.*;
        const helper = try self.builder.addFunction(null, self.analysis.function.source);
        self.builder.functions.items[@backingInt(helper)].result_count = 1;
        const block = try self.builder.addBlock(helper);
        const first_name = try self.runtime.store.getsym("$__skript_ad_scalar_left");
        const second_name = try self.runtime.store.getsym("$__skript_ad_scalar_right");
        const first_binding = try self.builder.addBinding(
            helper,
            first_name,
            .parameter,
            self.analysis.function.source,
        );
        const first_value = try self.builder.addValue(helper);
        self.builder.bindings.items[@backingInt(first_binding)].value = first_value;
        try self.builder.addParameter(helper, first_binding);
        var args: [2]Code.ValueId = undefined;
        if (operation == .neg) {
            args[0] = first_value;
        } else {
            const second_binding = try self.builder.addBinding(
                helper,
                second_name,
                .parameter,
                self.analysis.function.source,
            );
            const second_value = try self.builder.addValue(helper);
            self.builder.bindings.items[@backingInt(second_binding)].value = second_value;
            try self.builder.addParameter(helper, second_binding);
            args = .{ first_value, second_value };
        }
        const value = try self.emitHelperNode(helper, block, operation, &args, self.analysis.function.source);
        try self.builder.setTerminator(block, .{ .return_values = try self.builder.addOperands(&.{value}) });
        slot.* = helper;
        return helper;
    }

    fn emitHelperNode(
        self: *Transposer,
        function: Code.FunctionId,
        block: Code.BlockId,
        operation: rules.ScalarOp,
        args: []const Code.ValueId,
        source: SourceRef,
    ) Error!Code.ValueId {
        const primitive = try primitiveId(self.ctx, &rules.scalarDispatch);
        const tag = try self.builder.addNode(function, block, .{ .literal = .i64(@backingInt(operation)) }, source);
        var operands = std.ArrayList(Code.ValueId).empty;
        defer operands.deinit(self.ctx.scratch);
        try operands.append(self.ctx.scratch, tag);
        try operands.appendSlice(self.ctx.scratch, args);
        return self.builder.addNode(function, block, .{ .primitive_call = .{
            .primitive = primitive,
            .args = try self.builder.addOperands(operands.items),
            .result_count = 1,
        } }, source);
    }

    fn emitMap2(
        self: *Transposer,
        left: Code.ValueId,
        right: Code.ValueId,
        operation: rules.ScalarOp,
        source: SourceRef,
    ) Error!Code.ValueId {
        const helper = try self.scalarHelper(operation);
        const closure = try self.emitNode(.{ .make_closure = .{
            .function = helper,
            .captures = .empty(),
        } }, source);
        const map2 = try primitiveId(self.ctx, &tensor_intrin.map2);
        return self.emitPrimitive(map2, &.{ left, right, closure }, source);
    }

    fn emitListOp(
        self: *Transposer,
        native: skript.FuncPtr,
        args: []const Code.ValueId,
        source: SourceRef,
    ) Error!Code.ValueId {
        return self.emitPrimitive(try primitiveId(self.ctx, native), args, source);
    }

    fn emitMapKey(self: *Transposer, key: Value, source: SourceRef) Error!Code.ValueId {
        return self.emitNode(.{ .quote = key }, source);
    }

    fn emitZeroLike(self: *Transposer, prototype: Value, source: SourceRef, depth: usize) Error!Code.ValueId {
        if (depth >= max_analysis_depth) return error.Unsupported;
        if (prototype.typ == b.type_cons) {
            const head = try self.emitZeroLike(listHead(prototype) orelse return error.TypeMismatch, source, depth + 1);
            const rest = try self.emitZeroLike(listRest(prototype) orelse return error.TypeMismatch, source, depth + 1);
            return self.emitListOp(&skript.intrinsics.list.cons, &.{ head, rest }, source);
        }
        if (prototype.typ == b.type_map and prototype.obj != .null) {
            const entries = skript.intrinsics.map.equalityView(prototype);
            try self.ctx.chargeWork(@intCast(entries.count()), 1, .transform);
            const count = std.math.mul(usize, entries.count(), 2) catch return error.Unsupported;
            const args = try self.ctx.scratch.alloc(Code.ValueId, count);
            defer self.ctx.scratch.free(args);
            var iterator = entries.iterator();
            var index: usize = 0;
            while (iterator.next()) |entry| {
                args[index] = try self.emitMapKey(skript.intrinsics.map.keyValue(entry.key), source);
                args[index + 1] = try self.emitZeroLike(entry.value, source, depth + 1);
                index += 2;
            }
            return self.emitListOp(&skript.intrinsics.map.create, args, source);
        }
        return self.emitLiteral(try zeroLikeValue(self.ctx, prototype, depth), source);
    }

    fn emitMapProjection(
        self: *Transposer,
        prototype: Value,
        key: Value,
        cotangent: Code.ValueId,
        source: SourceRef,
    ) Error!Code.ValueId {
        if (prototype.typ != b.type_map or prototype.obj == .null) return error.TypeMismatch;
        const selected = try skript.intrinsics.map.keyOf(self.ctx, key);
        const entries = skript.intrinsics.map.equalityView(prototype);
        try self.ctx.chargeWork(@intCast(entries.count()), 1, .transform);
        const count = std.math.mul(usize, entries.count(), 2) catch return error.Unsupported;
        const args = try self.ctx.scratch.alloc(Code.ValueId, count);
        defer self.ctx.scratch.free(args);
        var iterator = entries.iterator();
        var index: usize = 0;
        var found = false;
        while (iterator.next()) |entry| {
            args[index] = try self.emitMapKey(skript.intrinsics.map.keyValue(entry.key), source);
            if (skript.data.MapKey.Context.eql(.{}, entry.key, selected)) {
                args[index + 1] = cotangent;
                found = true;
            } else {
                args[index + 1] = try self.emitZeroLike(entry.value, source, 0);
            }
            index += 2;
        }
        if (!found) return error.Unsupported;
        return self.emitListOp(&skript.intrinsics.map.create, args, source);
    }

    fn emitMapAdd(
        self: *Transposer,
        prototype: Value,
        left: Code.ValueId,
        right: Code.ValueId,
        source: SourceRef,
    ) Error!Code.ValueId {
        if (prototype.typ != b.type_map or prototype.obj == .null) return error.TypeMismatch;
        const entries = skript.intrinsics.map.equalityView(prototype);
        try self.ctx.chargeWork(@intCast(entries.count()), 1, .transform);
        const count = std.math.mul(usize, entries.count(), 2) catch return error.Unsupported;
        const args = try self.ctx.scratch.alloc(Code.ValueId, count);
        defer self.ctx.scratch.free(args);
        var iterator = entries.iterator();
        var index: usize = 0;
        while (iterator.next()) |entry| {
            const key = try self.emitMapKey(skript.intrinsics.map.keyValue(entry.key), source);
            const left_value = try self.emitListOp(&skript.intrinsics.map.get, &.{ left, key }, source);
            const right_value = try self.emitListOp(&skript.intrinsics.map.get, &.{ right, key }, source);
            args[index] = key;
            args[index + 1] = try self.emitAdd(entry.value, left_value, right_value, source);
            index += 2;
        }
        return self.emitListOp(&skript.intrinsics.map.create, args, source);
    }

    fn emitAdd(
        self: *Transposer,
        prototype: ?Value,
        left: Code.ValueId,
        right: Code.ValueId,
        source: SourceRef,
    ) Error!Code.ValueId {
        if (prototype) |value| {
            if (value.isNil()) return self.emitLiteral(.nil, source);
            if (value.typ == b.type_cons) {
                const left_head = try self.emitListOp(&skript.intrinsics.list.fst, &.{left}, source);
                const right_head = try self.emitListOp(&skript.intrinsics.list.fst, &.{right}, source);
                const left_rest = try self.emitListOp(&skript.intrinsics.list.rst, &.{left}, source);
                const right_rest = try self.emitListOp(&skript.intrinsics.list.rst, &.{right}, source);
                const head = try self.emitAdd(listHead(value), left_head, right_head, source);
                const rest = try self.emitAdd(listRest(value), left_rest, right_rest, source);
                return self.emitListOp(&skript.intrinsics.list.cons, &.{ head, rest }, source);
            }
            if (value.typ == b.type_map) return self.emitMapAdd(value, left, right, source);
            if (value.typ == b.type_tensor) return self.emitMap2(left, right, .add, source);
        }
        return self.emitScalar(.add, &.{ left, right }, source);
    }

    fn emitNeg(self: *Transposer, value: Code.ValueId, source: SourceRef) Error!Code.ValueId {
        return self.emitScalar(.neg, &.{value}, source);
    }

    fn emitScale(self: *Transposer, value: Code.ValueId, factor: Code.ValueId, source: SourceRef) Error!Code.ValueId {
        return self.emitScalar(.mul, &.{ value, factor }, source);
    }

    fn addAdjoint(self: *Transposer, source_value: Code.ValueId, contribution: Code.ValueId) Error!void {
        const index = @backingInt(source_value);
        if (index >= self.adjoints.len) return error.InvalidCode;
        if (self.analysis.values[index].class == .constant) return;
        if (self.adjoints[index] == .invalid) {
            self.adjoints[index] = contribution;
            return;
        }
        if (self.analysis.values[index].algebra != null) {
            const id = try self.valueSpaceId(source_value, self.analysis.function.source);
            self.adjoints[index] = try self.emitPrimitive(
                try primitiveId(self.ctx, &linearization.cotangentAdd),
                &.{ id, self.adjoints[index], contribution },
                self.analysis.function.source,
            );
            return;
        }
        const prototype = self.analysis.values[index].prototype;
        self.adjoints[index] = try self.emitAdd(
            prototype,
            self.adjoints[index],
            contribution,
            self.analysis.function.source,
        );
    }

    fn listProjection(self: *Transposer, value: Code.ValueId, index: usize, source: SourceRef) Error!Code.ValueId {
        var result = value;
        for (0..index) |_| result = try self.emitListOp(&skript.intrinsics.list.rst, &.{result}, source);
        return self.emitListOp(&skript.intrinsics.list.fst, &.{result}, source);
    }

    fn tensorIndex(self: *Transposer, value: Code.ValueId, index: usize, source: SourceRef) Error!Code.ValueId {
        const index_value = try self.emitLiteral(
            .i64(std.math.cast(i64, index) orelse return error.Unsupported),
            source,
        );
        return self.emitListOp(&tensor_intrin.tensorGet, &.{ value, index_value }, source);
    }

    fn tensorFlatIndex(prototype: Value, indices: []const Code.ValueId, values: []const SourceValue) Error!usize {
        if (prototype.typ != b.type_tensor or prototype.obj == .null) return error.TypeMismatch;
        const holder = prototype.obj.toRef().deref(tensor_intrin.TensorHolder);
        if (indices.len != holder.rank) return error.ArityMismatch;
        var flat: usize = 0;
        var stride: usize = 1;
        var axis = holder.shape.len;
        while (axis > 0) {
            axis -= 1;
            const entry = try valueInfo(values, indices[axis]);
            if (entry.class != .constant) return error.Unsupported;
            const known = entry.known orelse return error.Unsupported;
            if (known.typ != b.type_i64) return error.Unsupported;
            const coordinate = known.obj.toInt(i64);
            const dimension = std.math.cast(i64, holder.shape[axis]) orelse return error.Unsupported;
            if (coordinate < 0 or coordinate >= dimension) return error.Unsupported;
            const coordinate_usize = std.math.cast(usize, coordinate) orelse return error.Unsupported;
            flat = std.math.add(
                usize,
                flat,
                std.math.mul(usize, coordinate_usize, stride) catch return error.Unsupported,
            ) catch return error.Unsupported;
            stride = std.math.mul(
                usize,
                stride,
                std.math.cast(usize, holder.shape[axis]) orelse return error.Unsupported,
            ) catch return error.Unsupported;
        }
        return flat;
    }

    fn tensorScatter(
        self: *Transposer,
        prototype: Value,
        indices: []const Code.ValueId,
        cotangent: Code.ValueId,
        source: SourceRef,
    ) Error!Code.ValueId {
        if (prototype.typ != b.type_tensor or prototype.obj == .null) return error.Unsupported;
        const holder = prototype.obj.toRef().deref(tensor_intrin.TensorHolder);
        const target = try tensorFlatIndex(prototype, indices, self.analysis.values);
        const zero = switch (holder.inner) {
            .i64 => Value.i64(0),
            .f64 => Value.f64(0.0),
            else => return error.Unsupported,
        };
        const elements = std.math.cast(usize, holder.data.len) orelse return error.Unsupported;
        const leaves = try self.ctx.scratch.alloc(Code.ValueId, elements);
        defer self.ctx.scratch.free(leaves);
        for (leaves, 0..) |*leaf, index| {
            leaf.* = if (index == target) cotangent else try self.emitLiteral(zero, source);
        }
        const stack = try primitiveId(self.ctx, &tensor_intrin.create);
        const flat = try self.emitPrimitive(stack, leaves, source);
        const shape = try self.emitLiteral(try shapeList(self.runtime, prototype), source);
        return self.emitPrimitive(try primitiveId(self.ctx, &tensor_intrin.reshape), &.{ flat, shape }, source);
    }

    fn mapScale(self: *Transposer, tensor: Code.ValueId, factor: Code.ValueId, source: SourceRef) Error!Code.ValueId {
        const helper = try self.builder.addFunction(null, self.analysis.function.source);
        self.builder.functions.items[@backingInt(helper)].result_count = 1;
        const block = try self.builder.addBlock(helper);
        const parameter_name = try self.runtime.store.getsym("$__skript_ad_map_value");
        const parameter_binding = try self.builder.addBinding(
            helper,
            parameter_name,
            .parameter,
            self.analysis.function.source,
        );
        const parameter = try self.builder.addValue(helper);
        self.builder.bindings.items[@backingInt(parameter_binding)].value = parameter;
        try self.builder.addParameter(helper, parameter_binding);
        const capture_name = try self.runtime.store.getsym("$__skript_ad_map_factor");
        const capture_binding = try self.builder.addBinding(
            self.function_id,
            capture_name,
            .let,
            self.analysis.function.source,
        );
        self.builder.bindings.items[@backingInt(capture_binding)].value = factor;
        const captured = try self.builder.addCapture(helper, capture_binding);
        const result = try self.emitHelperNode(helper, block, .mul, &.{ captured, parameter }, source);
        try self.builder.setTerminator(block, .{ .return_values = try self.builder.addOperands(&.{result}) });
        const closure = try self.emitNode(.{ .make_closure = .{
            .function = helper,
            .captures = try self.builder.addOperands(&.{factor}),
        } }, source);
        return self.emitPrimitive(
            try primitiveId(self.ctx, &skript.intrinsics.collections.map),
            &.{ tensor, closure },
            source,
        );
    }
    fn inversePermutation(
        self: *Transposer,
        permutation: Value,
        expected_rank: usize,
        source: SourceRef,
    ) Error!Code.ValueId {
        if (permutation.typ != b.type_tensor or permutation.obj == .null) {
            return error.TypeMismatch;
        }
        const holder = permutation.obj.toRef().deref(tensor_intrin.TensorHolder);
        if (holder.rank != 1 or holder.inner != .i64 or holder.shape.len != 1) {
            return error.TypeMismatch;
        }
        const rank = std.math.cast(usize, holder.shape[0]) orelse return error.Unsupported;
        if (rank != expected_rank or rank != holder.data.len) return error.TypeMismatch;
        const max_transpose_rank: usize = 8;
        if (rank > max_transpose_rank) return error.Unsupported;
        try self.ctx.chargeWork(@intCast(rank), 1, .transform);
        var seen: [max_transpose_rank]bool = @splat(false);
        var inverse: [max_transpose_rank]Value = @splat(Value.nil);
        const rank_i64 = std.math.cast(i64, rank) orelse return error.Unsupported;
        for (holder.data, 0..) |word, output_axis| {
            const old_axis: i64 = @bitCast(word);
            if (old_axis < 0 or old_axis >= rank_i64) return error.Unsupported;
            const old_index = std.math.cast(usize, old_axis) orelse return error.Unsupported;
            if (seen[old_index]) return error.Unsupported;
            seen[old_index] = true;
            inverse[old_index] = .i64(std.math.cast(i64, output_axis) orelse return error.Unsupported);
        }
        const inverse_value = try tensor_intrin.create(self.ctx, .nil, .nil, inverse[0..rank]);
        return self.emitLiteral(inverse_value, source);
    }

    fn emitCustomTranspose(
        self: *Transposer,
        rule: rules.CodeRule,
        cotangent: Code.ValueId,
        source: SourceRef,
    ) Error!Code.ValueId {
        try validateStructuralRule(self.ctx, self.snapshot, rule);
        const callable = if (!rule.callable.isNil()) rule.callable else blk: {
            const function = rule.code.function(rule.function) orelse return error.InvalidCode;
            if (function.capture_count != 0) return error.Unsupported;
            const program = try self.runtime.lowerCode(self.ctx.scratch, rule.code);
            const index = @backingInt(rule.function);
            if (index >= program.fns.len) return error.InvalidCode;
            const lowered = program.fns[index];
            const reference = try self.runtime.store.create(Closure);
            const args = try self.runtime.store.allocSlice(Sym, lowered.arglist.len);
            @memcpy(args.slice, lowered.arglist);
            reference.deref(Closure).* = .{
                .parent_ns = self.runtime.root_ns,
                .arglist = args.slice,
                .ir = lowered.ir,
                .constants = lowered.constants,
                .nregs = lowered.nregs,
                .result_count = lowered.result_count,
                .zero_mask = lowered.zero_mask,
                .capture_syms = lowered.capture_syms,
                .captures = &.{},
                .code = rule.code,
                .function_id = rule.function,
                .fns = program.fns,
            };
            break :blk Value.closure(reference.toObject());
        };
        return self.emitNode(.{ .dynamic_call = .{
            .callee = try self.emitLiteral(callable, source),
            .args = try self.builder.addOperands(&.{cotangent}),
            .result_count = 1,
        } }, source);
    }

    fn reverseArithmetic(
        self: *Transposer,
        node: Code.Node,
        operation: Code.Arithmetic,
        cotangent: Code.ValueId,
    ) Error!void {
        const left = try self.sourceValue(operation.left);
        const right = try self.sourceValue(operation.right);
        const output = try self.operationValue(node);
        switch (operation.op) {
            .add => {
                if (left.class == .linear) try self.addAdjoint(
                    operation.left,
                    try self.pullScalar(operation.left, output, null, cotangent, node.source),
                );
                if (right.class == .linear) try self.addAdjoint(
                    operation.right,
                    try self.pullScalar(operation.right, output, null, cotangent, node.source),
                );
            },
            .sub => {
                if (left.class == .linear) try self.addAdjoint(
                    operation.left,
                    try self.pullScalar(operation.left, output, null, cotangent, node.source),
                );
                if (right.class == .linear) {
                    const negative_one = try self.emitLiteral(Value.i64(-1), node.source);
                    try self.addAdjoint(
                        operation.right,
                        try self.pullScalar(operation.right, output, negative_one, cotangent, node.source),
                    );
                }
            },
            .mul => {
                if (left.class == .linear) {
                    const coefficient = try self.emitConstant(operation.right, 0);
                    try self.addAdjoint(
                        operation.left,
                        try self.pullScalar(operation.left, output, coefficient, cotangent, node.source),
                    );
                }
                if (right.class == .linear) {
                    const coefficient = try self.emitConstant(operation.left, 0);
                    try self.addAdjoint(
                        operation.right,
                        try self.pullScalar(operation.right, output, coefficient, cotangent, node.source),
                    );
                }
            },
            .div => {
                if (left.class != .linear or right.class != .constant) return error.Unsupported;
                const denominator = try self.emitConstant(operation.right, 0);
                const contribution = if (left.algebra == null and output.algebra == null)
                    try self.emitScalar(.div, &.{ cotangent, denominator }, node.source)
                else blk: {
                    const one = try self.emitLiteral(Value.f64(1.0), node.source);
                    const reciprocal = try self.emitScalar(.div, &.{ one, denominator }, node.source);
                    break :blk try self.pullScalar(operation.left, output, reciprocal, cotangent, node.source);
                };
                try self.addAdjoint(operation.left, contribution);
            },
            .equal, .less, .greater => return error.Unsupported,
        }
    }

    fn reversePrimitive(
        self: *Transposer,
        node: Code.Node,
        call: Code.PrimitiveCall,
        cotangent: Code.ValueId,
    ) Error!void {
        const args = try operandSlice(self.source, call.args);
        const info = try sourcePrimitive(self.ctx, self.snapshot, self.analysis.values, call.primitive, args);
        const descriptor = info.descriptor orelse {
            const rule = info.rule orelse return error.Unsupported;
            if (rule.transpose_linear) |transpose_rule| {
                if (args.len != 1) return error.Unsupported;
                try self.addAdjoint(args[0], try self.emitCustomTranspose(transpose_rule, cotangent, node.source));
                return;
            }
            return error.Unsupported;
        };
        var actual_args = args;
        var scalar_operation: ?rules.ScalarOp = null;
        if (descriptor.rule == .dispatch) {
            if (args.len == 0) return error.ArityMismatch;
            scalar_operation = scalarTag((try self.sourceValue(args[0])).known orelse return error.Unsupported);
            actual_args = args[1..];
        }
        const operation = if (scalar_operation) |scalar|
            rules.scalarJvp(scalar) orelse return error.Unsupported
        else
            descriptor.rule;
        switch (operation) {
            .runtime_owned_output => {
                if (actual_args.len != 1) return error.ArityMismatch;
                if ((try self.sourceValue(actual_args[0])).class == .linear) {
                    try self.addAdjoint(
                        actual_args[0],
                        try self.pullScalar(
                            actual_args[0],
                            try self.operationValue(node),
                            null,
                            cotangent,
                            node.source,
                        ),
                    );
                }
            },
            .tensor_linear_apply => {
                if (actual_args.len < 2) return error.ArityMismatch;
                const id_value = (try self.sourceValue(actual_args[0])).known orelse return error.Unsupported;
                if (id_value.typ != b.type_i64 or id_value.obj.toInt(i64) <= 0) return error.TypeMismatch;
                try skript.autodiff_linearize.prepareTensorTranspose(
                    self.ctx,
                    @intCast(id_value.obj.toInt(i64)),
                );
                const record = try self.emitConstant(actual_args[0], 0);
                var remaining = try self.emitPrimitive(
                    try primitiveId(self.ctx, &skript.autodiff_linearize.tensorLinearTranspose),
                    &.{ record, cotangent },
                    node.source,
                );
                for (actual_args[1..]) |argument| {
                    if ((try self.sourceValue(argument)).class == .linear) {
                        const contribution = try self.emitListOp(
                            &skript.intrinsics.list.fst,
                            &.{remaining},
                            node.source,
                        );
                        try self.addAdjoint(argument, contribution);
                    }
                    remaining = try self.emitListOp(&skript.intrinsics.list.rst, &.{remaining}, node.source);
                }
            },
            .tensor_linear_transpose => {
                if (actual_args.len != 2) return error.ArityMismatch;
                const id_value = (try self.sourceValue(actual_args[0])).known orelse return error.Unsupported;
                if (id_value.typ != b.type_i64 or id_value.obj.toInt(i64) <= 0) return error.TypeMismatch;
                var record = try skript.autodiff_linearize.tensorLinearInfo(
                    self.ctx,
                    @intCast(id_value.obj.toInt(i64)),
                );
                defer record.deinit();
                const operands = try self.ctx.scratch.alloc(Code.ValueId, record.input_count + 1);
                defer self.ctx.scratch.free(operands);
                operands[0] = try self.emitConstant(actual_args[0], 0);
                var remaining = cotangent;
                for (operands[1..]) |*operand| {
                    operand.* = try self.emitListOp(&skript.intrinsics.list.fst, &.{remaining}, node.source);
                    remaining = try self.emitListOp(&skript.intrinsics.list.rst, &.{remaining}, node.source);
                }
                if ((try self.sourceValue(actual_args[1])).class == .linear) {
                    try self.addAdjoint(
                        actual_args[1],
                        try self.emitPrimitive(
                            try primitiveId(self.ctx, &skript.autodiff_linearize.tensorLinearApply),
                            operands,
                            node.source,
                        ),
                    );
                }
            },
            .add => {
                if (actual_args.len != 2) return error.ArityMismatch;
                if ((try self.sourceValue(actual_args[0])).class == .linear)
                    try self.addAdjoint(actual_args[0], cotangent);
                if ((try self.sourceValue(actual_args[1])).class == .linear)
                    try self.addAdjoint(actual_args[1], cotangent);
            },
            .sub => {
                if (actual_args.len != 2) return error.ArityMismatch;
                if ((try self.sourceValue(actual_args[0])).class == .linear)
                    try self.addAdjoint(actual_args[0], cotangent);
                if ((try self.sourceValue(actual_args[1])).class == .linear) {
                    try self.addAdjoint(actual_args[1], try self.emitNeg(cotangent, node.source));
                }
            },
            .mul => {
                if (actual_args.len != 2) return error.ArityMismatch;
                const left = try self.sourceValue(actual_args[0]);
                const right = try self.sourceValue(actual_args[1]);
                if (left.class == .linear and right.class == .constant) {
                    try self.addAdjoint(
                        actual_args[0],
                        try self.emitScale(
                            cotangent,
                            try self.emitConstant(actual_args[1], 0),
                            node.source,
                        ),
                    );
                } else if (right.class == .linear and left.class == .constant) {
                    try self.addAdjoint(
                        actual_args[1],
                        try self.emitScale(
                            cotangent,
                            try self.emitConstant(actual_args[0], 0),
                            node.source,
                        ),
                    );
                } else return error.Unsupported;
            },
            .div => {
                if (actual_args.len != 2) return error.ArityMismatch;
                const left = try self.sourceValue(actual_args[0]);
                const right = try self.sourceValue(actual_args[1]);
                if (left.class != .linear or right.class != .constant) return error.Unsupported;
                try self.addAdjoint(
                    actual_args[0],
                    try self.emitScalar(
                        .div,
                        &.{ cotangent, try self.emitConstant(actual_args[1], 0) },
                        node.source,
                    ),
                );
            },
            .construct => {
                if (scalar_operation == .coerce_tangent or scalar_operation == .realize_tangent) {
                    if (actual_args.len != 2) return error.ArityMismatch;
                    if ((try self.sourceValue(actual_args[1])).class == .linear) {
                        try self.addAdjoint(
                            actual_args[1],
                            try self.pullScalar(
                                actual_args[1],
                                try self.operationValue(node),
                                null,
                                cotangent,
                                node.source,
                            ),
                        );
                    }
                } else {
                    if (actual_args.len != 1) return error.ArityMismatch;
                    if ((try self.sourceValue(actual_args[0])).class == .linear) {
                        try self.addAdjoint(
                            actual_args[0],
                            try self.pullScalar(
                                actual_args[0],
                                try self.operationValue(node),
                                null,
                                cotangent,
                                node.source,
                            ),
                        );
                    }
                }
            },
            .neg => {
                if (actual_args.len != 1) return error.ArityMismatch;
                if ((try self.sourceValue(actual_args[0])).class == .linear) {
                    const negative_one = try self.emitLiteral(Value.i64(-1), node.source);
                    try self.addAdjoint(
                        actual_args[0],
                        try self.pullScalar(
                            actual_args[0],
                            try self.operationValue(node),
                            negative_one,
                            cotangent,
                            node.source,
                        ),
                    );
                }
            },
            .cons => {
                if (actual_args.len != 2) return error.ArityMismatch;
                const head = try self.emitListOp(&skript.intrinsics.list.fst, &.{cotangent}, node.source);
                const rest = try self.emitListOp(&skript.intrinsics.list.rst, &.{cotangent}, node.source);
                if ((try self.sourceValue(actual_args[0])).class == .linear) try self.addAdjoint(actual_args[0], head);
                if ((try self.sourceValue(actual_args[1])).class == .linear) try self.addAdjoint(actual_args[1], rest);
            },
            .fst, .rst => {
                if (actual_args.len != 1) return error.ArityMismatch;
                const input = try self.sourceValue(actual_args[0]);
                if (input.class != .linear or input.prototype == null) return error.Unsupported;
                const prototype = input.prototype.?;
                const selected = if (operation == .fst)
                    try self.emitListOp(
                        &skript.intrinsics.list.cons,
                        &.{
                            cotangent,
                            try self.emitLiteral(
                                try zeroLikeValue(
                                    self.ctx,
                                    listRest(prototype) orelse return error.TypeMismatch,
                                    0,
                                ),
                                node.source,
                            ),
                        },
                        node.source,
                    )
                else
                    try self.emitListOp(&skript.intrinsics.list.cons, &.{
                        try self.emitLiteral(
                            try zeroLikeValue(
                                self.ctx,
                                listHead(prototype) orelse return error.TypeMismatch,
                                0,
                            ),
                            node.source,
                        ),
                        cotangent,
                    }, node.source);
                try self.addAdjoint(actual_args[0], selected);
            },
            .list => {
                if (actual_args.len == 0) return error.ArityMismatch;
                for (actual_args, 0..) |arg, index| {
                    if ((try self.sourceValue(arg)).class == .linear) {
                        try self.addAdjoint(arg, try self.listProjection(cotangent, index, node.source));
                    }
                }
            },
            .stack => {
                if (actual_args.len == 0) return error.ArityMismatch;
                const output = try self.operationValue(node);
                const output_shape: ?[]const u32 = if (output.prototype) |out|
                    if (out.typ == b.type_tensor and out.obj != .null)
                        out.obj.toRef().deref(tensor_intrin.TensorHolder).shape
                    else
                        null
                else
                    null;
                if (output_shape) |shape| {
                    if (shape.len == 0) return error.TypeMismatch;
                    const leading = std.math.cast(usize, shape[0]) orelse return error.TypeMismatch;
                    if (leading != actual_args.len) return error.TypeMismatch;
                }
                for (actual_args, 0..) |arg, index| {
                    const arg_info = try self.sourceValue(arg);
                    if (arg_info.class != .linear) continue;
                    const prototype = arg_info.prototype orelse continue;
                    if (prototype.typ != b.type_tensor or prototype.obj == .null) {
                        try self.addAdjoint(arg, try self.tensorIndex(cotangent, index, node.source));
                        continue;
                    }
                    const operand_shape = prototype.obj.toRef().deref(tensor_intrin.TensorHolder).shape;
                    if (output_shape) |shape| {
                        if (!std.mem.eql(u32, operand_shape, shape[1..])) return error.TypeMismatch;
                    }
                    const index_lit = try self.emitLiteral(
                        .i64(std.math.cast(i64, index) orelse return error.Unsupported),
                        node.source,
                    );
                    const dropped = try self.emitPrimitive(
                        try primitiveId(self.ctx, &skript.intrinsics.collections.drop),
                        &.{ index_lit, cotangent },
                        node.source,
                    );
                    const one = try self.emitLiteral(.i64(1), node.source);
                    const taken = try self.emitPrimitive(
                        try primitiveId(self.ctx, &skript.intrinsics.collections.take),
                        &.{ one, dropped },
                        node.source,
                    );
                    const shape_value = try self.emitLiteral(try shapeList(self.runtime, prototype), node.source);
                    const piece = try self.emitPrimitive(
                        try primitiveId(self.ctx, &tensor_intrin.reshape),
                        &.{ taken, shape_value },
                        node.source,
                    );
                    try self.addAdjoint(arg, piece);
                }
            },
            .map_create => {
                if (actual_args.len == 0 or actual_args.len % 2 != 0) return error.ArityMismatch;
                var index: usize = 0;
                while (index < actual_args.len) : (index += 2) {
                    const key = try self.emitConstant(actual_args[index], 0);
                    if ((try self.sourceValue(actual_args[index + 1])).class == .linear) {
                        const contribution = try self.emitPrimitive(
                            try primitiveId(self.ctx, &skript.intrinsics.map.get),
                            &.{ cotangent, key },
                            node.source,
                        );
                        try self.addAdjoint(actual_args[index + 1], contribution);
                    }
                }
            },
            .map_get => {
                if (actual_args.len != 2) return error.ArityMismatch;
                const input = try self.sourceValue(actual_args[0]);
                if (input.class != .linear) return error.Unsupported;
                const prototype = input.prototype orelse return error.Unsupported;
                const key = (try self.sourceValue(actual_args[1])).known orelse return error.Unsupported;
                try self.addAdjoint(
                    actual_args[0],
                    try self.emitMapProjection(prototype, key, cotangent, node.source),
                );
            },
            .tensor_get => {
                if (actual_args.len < 2) return error.ArityMismatch;
                const tensor = try self.sourceValue(actual_args[0]);
                if (tensor.class != .linear or tensor.prototype == null) return error.Unsupported;
                try self.addAdjoint(
                    actual_args[0],
                    try self.tensorScatter(tensor.prototype.?, actual_args[1..], cotangent, node.source),
                );
            },
            .reshape => {
                if (actual_args.len != 2) return error.ArityMismatch;
                const tensor = try self.sourceValue(actual_args[0]);
                if (tensor.class != .linear or tensor.prototype == null) return error.Unsupported;
                try self.addAdjoint(
                    actual_args[0],
                    try self.emitPrimitive(
                        try primitiveId(self.ctx, &tensor_intrin.reshape),
                        &.{
                            cotangent,
                            try self.emitLiteral(
                                try shapeList(self.runtime, tensor.prototype.?),
                                node.source,
                            ),
                        },
                        node.source,
                    ),
                );
            },
            .transpose => {
                if (actual_args.len < 1 or actual_args.len > 2) return error.ArityMismatch;
                const tensor = try self.sourceValue(actual_args[0]);
                if (tensor.class != .linear) return error.Unsupported;
                const inverse = if (actual_args.len == 2) blk: {
                    const constant = (try self.sourceValue(actual_args[1])).known orelse return error.Unsupported;
                    const prototype = tensor.prototype orelse return error.Unsupported;
                    if (prototype.typ != b.type_tensor or prototype.obj == .null) return error.TypeMismatch;
                    const holder = prototype.obj.toRef().deref(tensor_intrin.TensorHolder);
                    const rank = std.math.cast(usize, holder.rank) orelse return error.Unsupported;
                    break :blk try self.inversePermutation(constant, rank, node.source);
                } else null;
                const result = if (inverse) |value|
                    try self.emitPrimitive(
                        try primitiveId(self.ctx, &tensor_intrin.trans),
                        &.{ cotangent, value },
                        node.source,
                    )
                else
                    try self.emitPrimitive(try primitiveId(self.ctx, &tensor_intrin.trans), &.{cotangent}, node.source);
                try self.addAdjoint(actual_args[0], result);
            },
            .dot => {
                if (actual_args.len != 2) return error.ArityMismatch;
                const left = try self.sourceValue(actual_args[0]);
                const right = try self.sourceValue(actual_args[1]);
                if (left.class == .linear and right.class == .constant) {
                    const coefficient = try self.emitConstant(actual_args[1], 0);
                    const prototype = left.prototype orelse return error.Unsupported;
                    const holder = if (prototype.typ == b.type_tensor and prototype.obj != .null)
                        prototype.obj.toRef().deref(tensor_intrin.TensorHolder)
                    else
                        return error.Unsupported;
                    if (holder.rank == 1) {
                        try self.addAdjoint(actual_args[0], try self.mapScale(coefficient, cotangent, node.source));
                    } else if (holder.rank == 2) {
                        const transposed = try self.emitPrimitive(
                            try primitiveId(self.ctx, &tensor_intrin.trans),
                            &.{coefficient},
                            node.source,
                        );
                        try self.addAdjoint(
                            actual_args[0],
                            try self.emitPrimitive(
                                try primitiveId(self.ctx, &tensor_intrin.dot),
                                &.{ cotangent, transposed },
                                node.source,
                            ),
                        );
                    } else return error.Unsupported;
                } else if (right.class == .linear and left.class == .constant) {
                    const coefficient = try self.emitConstant(actual_args[0], 0);
                    const prototype = right.prototype orelse return error.Unsupported;
                    const holder = if (prototype.typ == b.type_tensor and prototype.obj != .null)
                        prototype.obj.toRef().deref(tensor_intrin.TensorHolder)
                    else
                        return error.Unsupported;
                    if (holder.rank == 1) {
                        try self.addAdjoint(actual_args[1], try self.mapScale(coefficient, cotangent, node.source));
                    } else if (holder.rank == 2) {
                        const transposed = try self.emitPrimitive(
                            try primitiveId(self.ctx, &tensor_intrin.trans),
                            &.{coefficient},
                            node.source,
                        );
                        try self.addAdjoint(
                            actual_args[1],
                            try self.emitPrimitive(
                                try primitiveId(self.ctx, &tensor_intrin.dot),
                                &.{ transposed, cotangent },
                                node.source,
                            ),
                        );
                    } else return error.Unsupported;
                } else return error.Unsupported;
            },
            else => return error.Unsupported,
        }
    }
    fn reverseNode(self: *Transposer, node: Code.Node) Error!void {
        switch (node.operation) {
            .global_write => |write| {
                if (write.assign_existing) return error.Unsupported;
                return;
            },
            .ns_push, .ns_pop => return,
            else => {},
        }
        const result_index = @backingInt(node.result);
        if (result_index >= self.adjoints.len) return error.InvalidCode;
        const cotangent = self.adjoints[result_index];
        if (cotangent == .invalid) return;
        switch (node.operation) {
            .global_read => |global| {
                const cell = self.source.globals[@backingInt(global)];
                if (cell.binding == .invalid) return;
                const alias = self.analysis.values[@backingInt(node.result)].alias;
                if (alias != .invalid) try self.addAdjoint(alias, cotangent);
            },
            .local_read => |binding| {
                const binding_index = @backingInt(binding);
                if (binding_index >= self.source.bindings.len) return error.InvalidCode;
                try self.addAdjoint(self.analysis.values[@backingInt(node.result)].alias, cotangent);
            },
            .arithmetic => |arithmetic| try self.reverseArithmetic(node, arithmetic, cotangent),
            .primitive_call => |call| try self.reversePrimitive(node, call, cotangent),
            .dynamic_call => |call| {
                const primitive = (try self.sourceValue(node.result)).primitive orelse return error.Unsupported;
                try self.reversePrimitive(
                    node,
                    .{ .primitive = primitive, .args = call.args, .result_count = call.result_count },
                    cotangent,
                );
            },
            else => return error.Unsupported,
        }
    }

    fn build(self: *Transposer) Error!void {
        var primal: Code.ValueId = .invalid;
        const block = self.analysis.block;
        if (self.analysis.partial) {
            for (self.source.block_nodes[block.node_start..][0..block.node_count]) |id| {
                const node = self.source.nodes[@backingInt(id)];
                if (node.result != .invalid and
                    self.analysis.values[@backingInt(node.result)].constant_kind == .operation)
                {
                    _ = try self.emitConstant(node.result, 0);
                }
            }
        } else if (self.analysis.primal_result != .invalid) {
            for (self.source.block_nodes[block.node_start..][0..block.node_count]) |id| {
                const node = self.source.nodes[@backingInt(id)];
                if (node.result != .invalid and
                    self.analysis.values[@backingInt(node.result)].constant_kind == .operation)
                {
                    _ = try self.emitConstant(node.result, 0);
                }
            }
            primal = try self.emitConstant(self.analysis.primal_result, 0);
            self.output_parameters[0] = try self.emitScalar(.one_like, &.{primal}, self.analysis.function.source);
        }
        if (self.analysis.terminal) |terminal| {
            try self.reversePrimitive(terminal, terminal.operation.primitive_call, self.output_parameters[0]);
        } else {
            for (self.analysis.returns, self.output_parameters, 0..) |returned, output, index| {
                if ((try self.sourceValue(returned)).class == .constant) continue;
                const contribution = if (self.spaces) |domains| blk: {
                    const algebra = &domains.outputs[index];
                    break :blk try self.pullScalar(returned, .{
                        .prototype = try algebra.tangentZero(self.ctx),
                        .algebra = if (declaredSpace(algebra)) algebra else null,
                    }, null, output, self.analysis.function.source);
                } else output;
                try self.addAdjoint(returned, contribution);
            }
        }
        const node_start: usize = self.analysis.block.node_start;
        const node_end = std.math.add(usize, node_start, @as(usize, self.analysis.block.node_count)) catch
            return error.InvalidCode;
        if (node_end > self.source.block_nodes.len) return error.InvalidCode;
        var node_index = node_end;
        while (node_index > node_start) {
            node_index -= 1;
            const id = self.source.block_nodes[node_index];
            const node = self.source.nodes[@backingInt(id)];
            try self.reverseNode(node);
        }
        const prefix: usize = if (primal == .invalid) 0 else 1;
        const first = self.analysis.constant_parameters;
        const results = try self.ctx.scratch.alloc(Code.ValueId, self.parameter_bindings.len - first + prefix);
        defer self.ctx.scratch.free(results);
        if (prefix != 0) results[0] = primal;
        for (self.parameter_bindings[first..], results[prefix..], first..) |binding, *result, index| {
            const value = self.source.bindings[@backingInt(binding)].value;
            result.* = self.adjoints[@backingInt(value)];
            if (result.* == .invalid) {
                if ((try self.sourceValue(value)).algebra != null) {
                    const id = try self.valueSpaceId(value, self.analysis.function.source);
                    result.* = try self.emitPrimitive(
                        try primitiveId(self.ctx, &linearization.cotangentZero),
                        &.{id},
                        self.analysis.function.source,
                    );
                } else {
                    result.* = try self.emitZeroLike(
                        self.analysis.input_prototypes[index],
                        self.analysis.function.source,
                        0,
                    );
                }
            }
        }
        const output_primitive = try primitiveId(self.ctx, &linearization.materializeOutput);
        for (results) |*result| {
            result.* = try self.emitPrimitive(output_primitive, &.{result.*}, self.analysis.function.source);
        }
        try self.builder.setTerminator(self.block_id, .{ .return_values = try self.builder.addOperands(results) });
    }
};

const DependencyGuard = struct {
    runtime: *Runtime,
    registry: *const Primitive.RegistryVersion,
    rules_version: *const rules.RegistryVersion,
    code: *const Code.Code,
    source_code: *const Code.Code,
    source: *const Closure,
    expected_captures: []const Value,
    expected_arguments: []const Value,
    reads: []const Effects.Read,
    inherited: ?*const skript.data.ClosureGuard,
    region: ?*linearization.Region,
    argument_count: usize,
    finite_arguments: bool = true,
    finite_primal_parameters: FiniteParameters = .empty,
};

fn traceRead(read: Effects.Read, visitor: *skript.Store.MarkVisitor) anyerror!void {
    switch (read) {
        .cell => |cell| {
            try visitor.visitValue(cell.namespace);
            try visitor.visitValue(cell.snapshot.value);
        },
        .method => |method| try visitor.visitValue(method.value),
        .primitive => |primitive| switch (primitive.invoke) {
            .closure => |value| try visitor.visitValue(value),
            .native => {},
        },
    }
}

fn traceGuard(context: *const anyopaque, visitor: *skript.Store.MarkVisitor) anyerror!void {
    const guard: *const DependencyGuard = @ptrCast(@alignCast(context));
    try visitor.visitValue(guard.source.parent_ns);
    for (guard.expected_captures) |value| try visitor.visitValue(value);
    for (guard.expected_arguments) |value| try visitor.visitValue(value);
    try callables.traceClosureRef(guard.source, visitor);
    try callables.traceCodeGraph(guard.code, visitor);
    try callables.traceCodeGraph(guard.source_code, visitor);
    for (guard.reads) |read| try traceRead(read, visitor);
    if (guard.region) |region| try linearization.traceRegion(region, visitor);
    if (guard.inherited) |inherited| {
        const trace = inherited.trace orelse return error.UntracedAllocation;
        try visitor.visitGuard(trace, inherited.context);
    }
}

fn checkGuard(runtime: *Runtime, state: *const anyopaque) Error!void {
    const guard: *const DependencyGuard = @ptrCast(@alignCast(state));
    if (runtime != guard.runtime) return error.Denied;
    const ctx = runtime.context();
    try ctx.check();
    if (guard.region) |region| try region.check(ctx);
    if (ctx.registry != guard.registry) return error.Denied;
    if (runtime.intrinsics.registryVersion() != guard.registry) return error.Denied;
    if (!guard.rules_version.validFor(guard.registry)) return error.Denied;
    const owner = if (runtime.ad_rules) |*rules_owner| rules_owner else return error.Unsupported;
    if (!owner.ownsCurrent(guard.rules_version)) return error.Unsupported;
    if (guard.code.owner != @as(?*const anyopaque, runtime)) return error.Denied;
    if (guard.source.code != guard.source_code or guard.source.function_id == .invalid) return error.Denied;
    if (guard.source.captures.len != guard.expected_captures.len) return error.Denied;
    try ctx.chargeWork(@intCast(guard.reads.len + guard.expected_captures.len), 1, .code);
    for (guard.source.captures, guard.expected_captures) |actual, expected| {
        if (!sameValue(actual, expected)) return error.Denied;
    }
    if (guard.inherited) |parent| try parent.check(runtime, parent.context);
    for (guard.reads) |read| if (!read.valid(runtime)) return error.Unsupported;
}

fn acquireGuard(runtime: *Runtime, state: *const anyopaque) Error!void {
    const guard: *const DependencyGuard = @ptrCast(@alignCast(state));
    try checkGuard(runtime, state);
    if (guard.inherited) |parent| {
        if (parent.acquire) |acquire| try acquire(runtime, parent.context);
    }
    errdefer if (guard.inherited) |parent| {
        if (parent.release) |release| release(runtime, parent.context);
    };
    if (guard.region) |region| try region.acquire();
}

fn releaseGuard(runtime: *Runtime, state: *const anyopaque) void {
    const guard: *const DependencyGuard = @ptrCast(@alignCast(state));
    if (guard.region) |region| region.release();
    if (guard.inherited) |parent| {
        if (parent.release) |release| release(runtime, parent.context);
    }
}
fn checkGuardArguments(runtime: *Runtime, state: *const anyopaque, args: []const Value) Error!void {
    const guard: *const DependencyGuard = @ptrCast(@alignCast(state));
    if (args.len != guard.argument_count or args.len != guard.expected_arguments.len) return error.ArityMismatch;
    const ctx = runtime.context();
    for (args, guard.expected_arguments, 0..) |actual, expected, index| {
        if (!samePrototype(actual, expected, 0)) return error.Denied;
        if (guard.finite_arguments or guard.finite_primal_parameters.isSet(index)) {
            try checkFiniteTangent(ctx, actual, 0);
        }
    }
}

fn materialize(
    runtime: *Runtime,
    source: *const Closure,
    code: *const Code.Code,
    program: Runtime.RegProgram,
    function: Code.FunctionId,
    guard: *const skript.data.ClosureGuard,
    captures: []const Value,
) Error!Value {
    const index = @backingInt(function);
    if (index >= program.fns.len) return error.InvalidCode;
    const lowered = program.fns[index];
    if (lowered.capture_syms.len != captures.len) return error.InvalidCode;
    const reference = try runtime.store.create(Closure);
    const arguments = try runtime.store.allocSlice(Sym, lowered.arglist.len);
    @memcpy(arguments.slice, lowered.arglist);
    const captured = try runtime.store.allocSlice(Value, captures.len);
    @memcpy(captured.slice, captures);
    runtime.store.store(Closure, reference.deref(Closure), .{
        .parent_ns = source.parent_ns,
        .arglist = arguments.slice,
        .source = source.source,
        .source_ref = source.source_ref,
        .ir = lowered.ir,
        .constants = lowered.constants,
        .nregs = lowered.nregs,
        .result_count = lowered.result_count,
        .zero_mask = lowered.zero_mask,
        .capture_syms = lowered.capture_syms,
        .captures = captured.slice,
        .guard = guard,
        .code = code,
        .function_id = function,
        .environment_id = source.environment_id,
        .fns = program.fns,
    });
    return .closure(reference.toObject());
}

pub fn generate(
    ctx: *EvalContext,
    source: Value,
    input_prototypes: []const Value,
    output_prototypes: []const Value,
    spaces: ?Spaces,
) Error!Value {
    return generateWithConstants(
        ctx,
        source,
        input_prototypes,
        output_prototypes,
        0,
        spaces,
        .coefficients,
    );
}

/// Generate a transpose that binds fixed coefficient inputs and accepts every
/// source-output cotangent as a runtime argument. Constant source outputs are
/// ignored; results contain only cotangents for the remaining source inputs.
pub fn generatePartial(
    ctx: *EvalContext,
    source: Value,
    input_prototypes: []const Value,
    output_prototypes: []const Value,
    constant_parameters: usize,
) Error!Value {
    if (constant_parameters == 0 or constant_parameters >= input_prototypes.len) {
        return error.ArityMismatch;
    }
    const argument_count = std.math.add(usize, constant_parameters, output_prototypes.len) catch
        return error.ArityMismatch;
    if (argument_count >= std.math.maxInt(u8)) return error.ArityMismatch;
    return generateWithConstants(
        ctx,
        source,
        input_prototypes,
        output_prototypes,
        constant_parameters,
        null,
        .partial,
    );
}

/// Validate that a generated closure is structurally linear without building
/// its transpose. This keeps linearization's publication boundary independent
/// of transpose capability availability.
pub fn validateLinear(
    ctx: *EvalContext,
    source: Value,
    input_prototypes: []const Value,
    output_prototypes: []const Value,
    candidate_region: ?*linearization.Region,
) Error!void {
    const scope = ctx.activate();
    defer scope.deinit();
    if (source.typ != b.type_closure or source.obj == .null) return error.TypeMismatch;
    const source_closure = source.obj.toRef().deref(Closure);
    if (source_closure.guard) |guard| {
        try guard.check(ctx.runtime, guard.context);
        if (guard.acquire) |acquire| try acquire(ctx.runtime, guard.context);
    }
    defer if (source_closure.guard) |guard| {
        if (guard.release) |release| release(ctx.runtime, guard.context);
    };
    try ctx.check();
    const info = try sourceInfo(ctx.runtime, source);
    if (!info.function.allows_ad) return error.Unsupported;
    if (input_prototypes.len != info.function.parameter_count or
        output_prototypes.len != info.function.result_count)
    {
        return error.ArityMismatch;
    }
    if (ctx.registry != ctx.runtime.intrinsics.registryVersion()) return error.Denied;
    if (info.closure.guard) |guard| try guard.check(ctx.runtime, guard.context);
    try info.code.validate(ctx.scratch, ctx);
    const reads = try Effects.collectReads(ctx.runtime, info.closure.parent_ns, source, ctx.scratch);
    defer ctx.scratch.free(reads);
    const owner = try rules.registry(ctx);
    const snapshot = owner.current();
    var arena = std.heap.ArenaAllocator.init(ctx.scratch);
    defer arena.deinit();
    var analyzer = try Analyzer.init(
        arena.allocator(),
        ctx,
        info,
        input_prototypes,
        output_prototypes,
        snapshot,
    );
    analyzer.candidate_region = candidate_region;
    _ = try analyzer.run();
}
/// Compile one scalar primal call plus all callback partials into result slots.
pub fn generateCoefficients(ctx: *EvalContext, source: Value, primals: []const Value) Error!Value {
    if (primals.len == 0 or primals.len >= std.math.maxInt(u8)) return error.ArityMismatch;
    const prototypes = try ctx.scratch.alloc(Value, primals.len * 2);
    defer ctx.scratch.free(prototypes);
    @memcpy(prototypes[0..primals.len], primals);
    @memcpy(prototypes[primals.len..], primals);
    return generateWithConstants(
        ctx,
        source,
        prototypes,
        &.{ primals[0], primals[0] },
        primals.len,
        null,
        .coefficients,
    );
}

fn generateWithConstants(
    ctx: *EvalContext,
    source: Value,
    input_prototypes: []const Value,
    output_prototypes: []const Value,
    constant_parameters: usize,
    spaces: ?Spaces,
    mode: GenerationMode,
) Error!Value {
    const scope = ctx.activate();
    defer scope.deinit();
    if (source.typ != b.type_closure or source.obj == .null) return error.TypeMismatch;
    const source_guard = source.obj.toRef().deref(Closure).guard;
    if (source_guard) |guard| {
        try guard.check(ctx.runtime, guard.context);
        if (guard.acquire) |acquire| try acquire(ctx.runtime, guard.context);
    }
    defer if (source_guard) |guard| {
        if (guard.release) |release| release(ctx.runtime, guard.context);
    };
    try ctx.check();
    const info = try sourceInfo(ctx.runtime, source);
    if (!info.function.allows_ad) return error.Unsupported;
    if (input_prototypes.len != info.function.parameter_count or
        output_prototypes.len != info.function.result_count)
    {
        return error.ArityMismatch;
    }
    if (spaces) |domains| {
        if (domains.inputs.len != input_prototypes.len or domains.outputs.len != output_prototypes.len) {
            return error.ArityMismatch;
        }
        if (domains.region.runtime != ctx.runtime) return error.Denied;
    }
    if (ctx.registry != ctx.runtime.intrinsics.registryVersion()) return error.Denied;
    if (info.closure.guard) |guard| try guard.check(ctx.runtime, guard.context);
    try info.code.validate(ctx.scratch, ctx);
    const reads = try Effects.collectReads(ctx.runtime, info.closure.parent_ns, source, ctx.scratch);
    defer ctx.scratch.free(reads);
    const owner = try rules.registry(ctx);
    const snapshot = owner.current();

    var arena = std.heap.ArenaAllocator.init(ctx.scratch);
    defer arena.deinit();
    const scratch = arena.allocator();
    var analyzer = try Analyzer.init(scratch, ctx, info, input_prototypes, output_prototypes, snapshot);
    analyzer.constant_parameters = constant_parameters;
    const analyzer_mode = mode == .partial;
    analyzer.partial = analyzer_mode;
    analyzer.spaces = spaces;
    if (spaces) |domains| analyzer.candidate_region = domains.region;
    const analysis = try analyzer.run();

    const identity = try ctx.runtime.allocCodeIdentity();
    var builder = Code.Builder.init(ctx.runtime.static, ctx);
    builder.id = identity.id;
    builder.revision = identity.revision;
    const function_id = try builder.addFunction(null, info.function.source);
    const generated_function = &builder.functions.items[@backingInt(function_id)];
    const result_count = if (mode == .partial)
        input_prototypes.len - constant_parameters
    else if (constant_parameters == 0)
        input_prototypes.len
    else
        constant_parameters + 1;
    if (result_count == 0 or result_count > std.math.maxInt(u8)) return error.ArityMismatch;
    generated_function.result_count = @intCast(result_count);
    generated_function.ad_level = std.math.add(u16, info.function.ad_level, 1) catch return error.Unsupported;
    generated_function.allows_ad = info.function.allows_ad;
    generated_function.origin = .{ .code = info.code, .function = info.function.id };
    const block_id = try builder.addBlock(function_id);

    const output_parameter_count = if (mode == .partial)
        output_prototypes.len
    else if (constant_parameters == 0)
        output_prototypes.len
    else
        1;
    const output_parameters = try scratch.alloc(Code.ValueId, output_parameter_count);
    @memset(output_parameters, .invalid);
    const parameter_bindings = info.code.parameters[info.function.parameter_start..][0..info.function.parameter_count];
    const arguments = if (mode == .partial) blk: {
        const count = std.math.add(usize, constant_parameters, output_prototypes.len) catch
            return error.ArityMismatch;
        const values = try scratch.alloc(Value, count);
        @memcpy(values[0..constant_parameters], input_prototypes[0..constant_parameters]);
        @memcpy(values[constant_parameters..], output_prototypes);
        break :blk values;
    } else if (constant_parameters == 0) blk: {
        if (spaces) |domains| {
            const cotangents = try scratch.alloc(Value, domains.outputs.len);
            for (domains.outputs, cotangents) |*algebra, *prototype| {
                prototype.* = try algebra.cotangentZero(ctx);
            }
            break :blk cotangents;
        }
        break :blk output_prototypes;
    } else input_prototypes[0..constant_parameters];
    const input_values = try scratch.alloc(Code.ValueId, arguments.len);
    for (input_values, 0..) |*value, index| {
        var name_buffer: [96]u8 = undefined;
        const name_text = std.fmt.bufPrint(&name_buffer, "$__skript_ad_cotangent_{d}", .{index}) catch
            return error.Unsupported;
        const name = try ctx.runtime.store.getsym(name_text);
        const binding = try builder.addBinding(function_id, name, .parameter, info.function.source);
        value.* = try builder.addValue(function_id);
        builder.bindings.items[@backingInt(binding)].value = value.*;
        try builder.addParameter(function_id, binding);
    }

    const generated_values = try scratch.alloc(Code.ValueId, info.code.values.len);
    const adjoints = try scratch.alloc(Code.ValueId, info.code.values.len);
    const space_ids = try scratch.alloc(u64, info.code.values.len);
    var transposer: Transposer = .{
        .ctx = ctx,
        .runtime = ctx.runtime,
        .source = info.code,
        .source_closure = info.closure,
        .analysis = analysis,
        .snapshot = snapshot,
        .builder = builder,
        .function_id = function_id,
        .block_id = block_id,
        .generated_values = generated_values,
        .adjoints = adjoints,
        .output_parameters = output_parameters,
        .parameter_bindings = parameter_bindings,
        .spaces = spaces,
        .space_ids = space_ids,
    };
    @memset(transposer.generated_values, .invalid);
    @memset(transposer.adjoints, .invalid);
    @memset(transposer.space_ids, 0);
    if (constant_parameters != 0) {
        for (parameter_bindings[0..constant_parameters], input_values[0..constant_parameters]) |binding, value| {
            transposer.generated_values[@backingInt(info.code.bindings[@backingInt(binding)].value)] = value;
        }
    }
    if (mode == .partial) {
        @memcpy(transposer.output_parameters, input_values[constant_parameters..]);
    } else if (constant_parameters == 0) {
        @memcpy(transposer.output_parameters, input_values);
    }
    try transposer.build();
    const code = try transposer.builder.finish(ctx.scratch);
    code.owner = ctx.runtime;
    const program = try ctx.runtime.lowerCode(ctx.scratch, code);
    const retained_reads = try ctx.runtime.static.dupe(Effects.Read, reads);
    const expected_captures = try ctx.runtime.static.dupe(Value, info.closure.captures);
    const expected_arguments = try ctx.runtime.static.dupe(Value, arguments);
    const guard_context = try ctx.runtime.static.create(DependencyGuard);
    guard_context.* = .{
        .runtime = ctx.runtime,
        .registry = ctx.registry,
        .rules_version = snapshot,
        .code = code,
        .source_code = info.code,
        .source = info.closure,
        .expected_captures = expected_captures,
        .expected_arguments = expected_arguments,
        .reads = retained_reads,
        .inherited = info.closure.guard,
        .region = if (spaces) |domains| domains.region else null,
        .argument_count = arguments.len,
        .finite_arguments = mode == .partial or constant_parameters == 0,
        .finite_primal_parameters = analyzer.finite_primal_parameters,
    };
    const guard = try ctx.runtime.static.create(skript.data.ClosureGuard);
    guard.* = .{
        .context = guard_context,
        .check = &checkGuard,
        .trace = &traceGuard,
        .check_arguments = &checkGuardArguments,
        .acquire = &acquireGuard,
        .release = &releaseGuard,
    };
    return materialize(ctx.runtime, info.closure, code, program, function_id, guard, &.{});
}

fn expectTensorF64(expected_shape: []const u32, expected: []const f64, actual: Value) !void {
    try std.testing.expectEqual(b.type_tensor, actual.typ);
    const tensor = actual.obj.toRef().deref(tensor_intrin.TensorHolder);
    try std.testing.expectEqualSlices(u32, expected_shape, tensor.shape);
    try std.testing.expectEqual(expected.len, tensor.data.len);
    for (expected, tensor.data) |want, word| {
        try std.testing.expectApproxEqAbs(want, @as(f64, @bitCast(word)), 1e-12);
    }
}

test "transpose generation rejects malformed concrete permutations before publication" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const matrix = try runtime.evalString(
        "(stack (stack 0.0 0.0) (stack 0.0 0.0))",
    );

    _ = try runtime.evalString("(def bad-perm (stack 0 0))");
    const duplicate = try runtime.evalString(
        "(fn (x) (let ((y (trans x bad-perm))) y))",
    );
    try std.testing.expectError(
        error.Unsupported,
        generate(runtime.context(), duplicate, &.{matrix}, &.{matrix}, null),
    );

    _ = try runtime.evalString("(def bad-perm-range (stack 2 0))");
    const out_of_range = try runtime.evalString(
        "(fn (x) (let ((y (trans x bad-perm-range))) y))",
    );
    try std.testing.expectError(
        error.Unsupported,
        generate(runtime.context(), out_of_range, &.{matrix}, &.{matrix}, null),
    );

    _ = try runtime.evalString("(def bad-perm-rank (stack (stack 0 1)))");
    const wrong_rank = try runtime.evalString(
        "(fn (x) (let ((y (trans x bad-perm-rank))) y))",
    );
    try std.testing.expectError(
        error.TypeMismatch,
        generate(runtime.context(), wrong_rank, &.{matrix}, &.{matrix}, null),
    );

    _ = try runtime.evalString("(def bad-perm-len (stack 0 1 2))");
    const bad_length = try runtime.evalString(
        "(fn (x) (let ((y (trans x bad-perm-len))) y))",
    );
    try std.testing.expectError(
        error.TypeMismatch,
        generate(runtime.context(), bad_length, &.{matrix}, &.{matrix}, null),
    );

    _ = try runtime.evalString("(def bad-perm-short (stack 0))");
    const short_length = try runtime.evalString(
        "(fn (x) (let ((y (trans x bad-perm-short))) y))",
    );
    try std.testing.expectError(
        error.TypeMismatch,
        generate(runtime.context(), short_length, &.{matrix}, &.{matrix}, null),
    );

    const shape9 = try runtime.store.allocSlice(u32, 9);
    @memset(shape9.slice, 1);
    const data9 = try runtime.store.allocSlice(u64, 1);
    data9.slice[0] = @bitCast(@as(f64, 0.0));
    const holder9 = try runtime.store.createTraced(
        tensor_intrin.TensorHolder,
        tensor_intrin.traceTensorHolder,
    );
    holder9.deref(tensor_intrin.TensorHolder).* = .{
        .inner = .f64,
        .rank = 9,
        .shape = shape9.slice,
        .data = data9.slice,
        .shape_ref = shape9.ref,
        .data_ref = data9.ref,
    };
    const rank9 = Value.init(b.type_tensor, holder9.toObject());
    _ = try runtime.evalString("(def bad-perm-wide (stack 0 1 2 3 4 5 6 7 8))");
    const too_wide = try runtime.evalString(
        "(fn (x) (let ((y (trans x bad-perm-wide))) y))",
    );
    try std.testing.expectError(
        error.Unsupported,
        generate(runtime.context(), too_wide, &.{rank9}, &.{rank9}, null),
    );
}

test "transpose generation preserves explicit permutation values" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const prototype = try runtime.evalString(
        "(stack (stack 0.0 0.0) (stack 0.0 0.0))",
    );
    const cotangent = try runtime.evalString(
        "(stack (stack 1.0 2.0) (stack 3.0 4.0))",
    );
    var workspace = Runtime.CallWorkspace.init(std.testing.allocator);
    defer workspace.deinit();
    var outputs: [1]Value = undefined;

    _ = try runtime.evalString("(def transpose-perm (stack 0 1))");
    const identity_source = try runtime.evalString(
        "(fn (x) (let ((y (trans x transpose-perm))) y))",
    );
    const identity = try generate(
        runtime.context(),
        identity_source,
        &.{prototype},
        &.{prototype},
        null,
    );
    try workspace.apply(runtime.context(), identity, &.{cotangent}, &outputs);
    try expectTensorF64(&.{ 2, 2 }, &.{ 1.0, 2.0, 3.0, 4.0 }, outputs[0]);

    _ = try runtime.evalString("(def transpose-perm (stack 1 0))");
    const swapped_source = try runtime.evalString(
        "(fn (x) (let ((y (trans x transpose-perm))) y))",
    );
    const swapped = try generate(
        runtime.context(),
        swapped_source,
        &.{prototype},
        &.{prototype},
        null,
    );
    try workspace.apply(runtime.context(), swapped, &.{cotangent}, &outputs);
    try expectTensorF64(&.{ 2, 2 }, &.{ 1.0, 3.0, 2.0, 4.0 }, outputs[0]);
}

test "transpose finite tensor guard consumes the caller work budget" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const element_count: usize = 4_096;
    const elements = try std.testing.allocator.alloc(Value, element_count);
    defer std.testing.allocator.free(elements);
    @memset(elements, Value.f64(1.0));
    const tensor = try tensor_intrin.create(runtime.context(), .nil, .nil, elements);
    const source = try runtime.evalString("(fn (x) x)");
    const transposed = try generate(
        runtime.context(),
        source,
        &.{tensor},
        &.{tensor},
        null,
    );

    const work_limit: u64 = 128;
    var budget = EvalContext.Budget.init(runtime.io, 9_201, .{ .work = work_limit });
    var lease = try EvalContext.Budget.Lease.root(&budget, work_limit);
    var account = EvalContext.Budget.AccountAllocator.init(
        std.testing.allocator,
        &lease,
        .transform,
    );
    var output_bytes: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_bytes);
    var context = try EvalContext.limited(
        runtime,
        runtime.intrinsics.registryVersion(),
        &account,
        .{ .writer = &writer, .bounded_memory = true },
        .{ .effects = .{ .state_read = .allow } },
    );
    var workspace = Runtime.CallWorkspace.init(std.testing.allocator);
    defer workspace.deinit();
    var outputs: [1]Value = undefined;
    try std.testing.expectError(
        error.Exhausted,
        workspace.apply(&context, transposed, &.{tensor}, &outputs),
    );
    const report = budget.report() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(EvalContext.Budget.Resource.work, report.resource);
    try std.testing.expectEqual(EvalContext.Budget.Backend.transform, report.backend);
}

test "transpose preserves the scalar pairing" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const linear = try runtime.evalString("(fn (x) (* 2.0 x))");
    const transposed = try generate(runtime.context(), linear, &.{Value.f64(0.0)}, &.{Value.f64(0.0)}, null);
    var workspace = Runtime.CallWorkspace.init(std.testing.allocator);
    defer workspace.deinit();
    var outputs: [1]Value = undefined;
    try workspace.apply(runtime.context(), transposed, &.{Value.f64(3.0)}, &outputs);
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), outputs[0].obj.tof64(), 1e-12);
}

test "transpose ignores mutation in a sibling closure sharing source Code" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const linear = try runtime.evalString(
        "(let ((calls 0)) (let ((unused (fn () (set! calls (+ calls 1))))) (fn (x) (* 2.0 x))))",
    );
    try validateLinear(runtime.context(), linear, &.{Value.f64(0.0)}, &.{Value.f64(0.0)}, null);
    const transposed = try generate(runtime.context(), linear, &.{Value.f64(0.0)}, &.{Value.f64(0.0)}, null);
    var workspace = Runtime.CallWorkspace.init(std.testing.allocator);
    defer workspace.deinit();
    var outputs: [1]Value = undefined;
    try workspace.apply(runtime.context(), transposed, &.{Value.f64(3.0)}, &outputs);
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), outputs[0].obj.tof64(), 1e-12);
}

test "transpose rejects assignment inside the source even when AD is flagged available" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const source = try runtime.evalString(
        "(let ((calls 0)) (fn (x) (begin (set! calls (+ calls 1)) (+ x calls))))",
    );
    @constCast((try sourceInfo(runtime, source)).function).allows_ad = true;
    try std.testing.expectError(
        error.Unsupported,
        validateLinear(runtime.context(), source, &.{Value.i64(0)}, &.{Value.i64(0)}, null),
    );
    try std.testing.expectError(
        error.Unsupported,
        generate(runtime.context(), source, &.{Value.i64(0)}, &.{Value.i64(0)}, null),
    );
}

test "transpose preserves multiple input and result slots" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const linear = try runtime.evalString("(fn (x y) (list (+ x y) (* 2.0 x)))");
    const output_prototype = try runtime.evalString("(list 0.0 0.0)");
    const output_cotangent = try runtime.evalString("(list 3.0 5.0)");
    const transposed = try generate(
        runtime.context(),
        linear,
        &.{ Value.f64(0.0), Value.f64(0.0) },
        &.{output_prototype},
        null,
    );
    var workspace = Runtime.CallWorkspace.init(std.testing.allocator);
    defer workspace.deinit();
    var outputs: [2]Value = undefined;
    try workspace.apply(runtime.context(), transposed, &.{output_cotangent}, &outputs);
    try std.testing.expectApproxEqAbs(@as(f64, 13.0), outputs[0].obj.tof64(), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), outputs[1].obj.tof64(), 1e-12);
}

test "transpose scatters tensor views in last-axis-fastest order" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const input = try runtime.evalString("(stack 0.0 0.0 0.0 0.0)");
    const linear = try runtime.evalString(
        "(fn (x) (+ (tensor-get (reshape x '(2 2)) 0 1) " ++
            "(tensor-get (reshape x '(2 2)) 0 1)))",
    );
    const transposed = try generate(runtime.context(), linear, &.{input}, &.{Value.f64(0.0)}, null);
    var workspace = Runtime.CallWorkspace.init(std.testing.allocator);
    defer workspace.deinit();
    var outputs: [1]Value = undefined;
    try workspace.apply(runtime.context(), transposed, &.{Value.f64(4.0)}, &outputs);
    try expectTensorF64(&.{4}, &.{ 0.0, 8.0, 0.0, 0.0 }, outputs[0]);
}

test "transpose handles tensor transpose and frozen dot operands" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const vector = try runtime.evalString("(stack 0.0 0.0)");
    const linear = try runtime.evalString(
        "((fn (coefficient) (fn (x) (dot (trans (reshape x '(2 1))) coefficient))) " ++
            "(stack (stack 2.0) (stack 3.0)))",
    );
    const output_prototype = try runtime.evalString("(reshape (stack 0.0) '(1 1))");
    const cotangent = try runtime.evalString("(reshape (stack 5.0) '(1 1))");
    const transposed = try generate(runtime.context(), linear, &.{vector}, &.{output_prototype}, null);
    var workspace = Runtime.CallWorkspace.init(std.testing.allocator);
    defer workspace.deinit();
    var outputs: [1]Value = undefined;
    try workspace.apply(runtime.context(), transposed, &.{cotangent}, &outputs);
    try expectTensorF64(&.{2}, &.{ 10.0, 15.0 }, outputs[0]);
}

test "transpose reconstructs list structure while reversing projections" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const input = try runtime.evalString("(list 0.0 0.0)");
    const linear = try runtime.evalString("(fn (xs) (list (rst xs) (fst xs)))");
    const output = try runtime.evalString("(list (list 0.0) 0.0)");
    const cotangent = try runtime.evalString("(list (list 7.0) 11.0)");
    const transposed = try generate(runtime.context(), linear, &.{input}, &.{output}, null);
    var workspace = Runtime.CallWorkspace.init(std.testing.allocator);
    defer workspace.deinit();
    var results: [1]Value = undefined;
    try workspace.apply(runtime.context(), transposed, &.{cotangent}, &results);
    const expected = try runtime.evalString("(list 11.0 7.0)");
    var expected_tree = try tree.flatten(
        std.testing.allocator,
        runtime.context(),
        runtime.tree_registry.current(),
        expected,
        tree.Limits.generic,
    );
    defer expected_tree.deinit();
    try expected_tree.check(std.testing.allocator, runtime.context(), results[0]);
    const first = results[0].obj.toRef().deref([2]Value);
    try std.testing.expectApproxEqAbs(@as(f64, 11.0), first[0].obj.tof64(), 1e-12);
    const second = first[1].obj.toRef().deref([2]Value);
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), second[0].obj.tof64(), 1e-12);
}

test "transpose adds repeated map projections and retains inactive keys" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const input = try runtime.evalString("(hash-map :x 0.0 :unused 0.0)");
    const linear = try runtime.evalString("(fn (m) (+ (map-get m :x) (map-get m :x)))");
    const transposed = try generate(runtime.context(), linear, &.{input}, &.{Value.f64(0.0)}, null);
    var workspace = Runtime.CallWorkspace.init(std.testing.allocator);
    defer workspace.deinit();
    var results: [1]Value = undefined;
    try workspace.apply(runtime.context(), transposed, &.{Value.f64(4.0)}, &results);
    const expected = try runtime.evalString("(hash-map :x 8.0 :unused 0.0)");
    var expected_tree = try tree.flatten(
        std.testing.allocator,
        runtime.context(),
        runtime.tree_registry.current(),
        expected,
        tree.Limits.generic,
    );
    defer expected_tree.deinit();
    try expected_tree.check(std.testing.allocator, runtime.context(), results[0]);
    const selected = try runtime.evalString(":x");
    const unused = try runtime.evalString(":unused");
    const actual_x = try skript.intrinsics.map.get(runtime.context(), .nil, .nil, &.{ results[0], selected });
    const actual_unused = try skript.intrinsics.map.get(runtime.context(), .nil, .nil, &.{ results[0], unused });
    try std.testing.expectEqual(Value.f64(8.0), actual_x);
    try std.testing.expectEqual(Value.f64(0.0), actual_unused);
}

test "transpose differentiates a pure unary tensor callback" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const cotangent = try runtime.evalString(
        "((fst (rst (vjp " ++
            "(fn (xs) (map xs (fn (element) (+ (* element element) (* 3.0 element))))) " ++
            "[1.0 2.0]))) [5.0 6.0])",
    );
    try expectTensorF64(&.{2}, &.{ 25.0, 42.0 }, cotangent);
}

test "transpose rejects nonlinear effects and tangent control structurally" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const nonlinear = try runtime.evalString("(fn (x y) (* x y))");
    try std.testing.expectError(error.Unsupported, generate(
        runtime.context(),
        nonlinear,
        &.{ Value.f64(0.0), Value.f64(0.0) },
        &.{Value.f64(0.0)},
        null,
    ));
    const effectful = try runtime.evalString("(fn (x) (write x) x)");
    try std.testing.expectError(error.Unsupported, generate(
        runtime.context(),
        effectful,
        &.{Value.f64(0.0)},
        &.{Value.f64(0.0)},
        null,
    ));
    const tangent_control = try runtime.evalString("(fn (x) (if x x x))");
    try std.testing.expectError(error.Unsupported, generate(
        runtime.context(),
        tangent_control,
        &.{Value.f64(0.0)},
        &.{Value.f64(0.0)},
        null,
    ));
}

test "transpose dependency guards reject stale residuals" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    _ = try runtime.evalString("(def transpose-coefficient 2.0)");
    const linear = try runtime.evalString("(fn (x) (* transpose-coefficient x))");
    const transposed = try generate(runtime.context(), linear, &.{Value.f64(0.0)}, &.{Value.f64(0.0)}, null);
    _ = try runtime.evalString("(def transpose-coefficient 3.0)");
    var workspace = Runtime.CallWorkspace.init(std.testing.allocator);
    defer workspace.deinit();
    var outputs: [1]Value = undefined;
    try std.testing.expectError(
        error.Unsupported,
        workspace.apply(runtime.context(), transposed, &.{Value.f64(1.0)}, &outputs),
    );
}

test "transpose closures support repeated fresh workspaces" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const linear = try runtime.evalString("(fn (x) (* 4.0 x))");
    const transposed = try generate(runtime.context(), linear, &.{Value.f64(0.0)}, &.{Value.f64(0.0)}, null);
    for ([_]f64{ 1.0, 2.0, 3.0 }) |seed| {
        var workspace = Runtime.CallWorkspace.init(std.testing.allocator);
        defer workspace.deinit();
        var outputs: [1]Value = undefined;
        try workspace.apply(runtime.context(), transposed, &.{Value.f64(seed)}, &outputs);
        try std.testing.expectApproxEqAbs(@as(f64, 4.0) * seed, outputs[0].obj.tof64(), 1e-12);
    }
}

test "partial transpose keeps coefficients and seeds every output slot" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const source = try runtime.evalString("(fn (x) (* x x))");
    const differentiated = try forward_ad.generate(
        runtime.context(),
        source,
        0,
        .full_jvp,
    );
    const partial = try generatePartial(
        runtime.context(),
        differentiated,
        &.{ Value.f64(0.0), Value.f64(0.0) },
        &.{ Value.f64(0.0), Value.f64(0.0) },
        1,
    );
    var workspace = Runtime.CallWorkspace.init(std.testing.allocator);
    defer workspace.deinit();
    var outputs: [1]Value = undefined;
    try workspace.apply(
        runtime.context(),
        partial,
        &.{ Value.f64(3.0), Value.f64(97.0), Value.f64(4.0) },
        &outputs,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 24.0), outputs[0].obj.tof64(), 1e-12);
    try workspace.apply(
        runtime.context(),
        partial,
        &.{ Value.f64(5.0), Value.f64(-101.0), Value.f64(2.0) },
        &outputs,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), outputs[0].obj.tof64(), 1e-12);
}
test "partial transpose preserves nonlinear jet coefficients" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const source = try runtime.evalString("(fn (x) (* x x))");
    const first = try forward_ad.generate(runtime.context(), source, 0, .full_jvp);
    const nested = try forward_ad.generate(runtime.context(), first, 0, .full_jvp);
    const partial = try generatePartial(
        runtime.context(),
        nested,
        &.{ Value.f64(0.0), Value.f64(0.0), Value.f64(0.0), Value.f64(0.0) },
        &.{
            Value.f64(0.0),
            Value.f64(0.0),
            Value.f64(0.0),
            Value.f64(0.0),
        },
        2,
    );
    var workspace = Runtime.CallWorkspace.init(std.testing.allocator);
    defer workspace.deinit();
    var outputs: [2]Value = undefined;
    try workspace.apply(
        runtime.context(),
        partial,
        &.{
            Value.f64(3.0),
            Value.f64(5.0),
            Value.f64(0.0),
            Value.f64(0.0),
            Value.f64(0.0),
            Value.f64(1.0),
        },
        &outputs,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), outputs[0].obj.tof64(), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), outputs[1].obj.tof64(), 1e-12);
}
test "transpose rejects variadic closures instead of fixed-arity lowering" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const source = try runtime.evalString("(fn (first . rest) first)");
    try std.testing.expectError(
        error.Unsupported,
        generate(
            runtime.context(),
            source,
            &.{ Value.f64(1.0), Value.f64(2.0) },
            &.{Value.f64(0.0)},
            null,
        ),
    );
}
