const std = @import("std");
const skript = @import("root.zig");
const Context = @import("EvalContext.zig");
const Domain = @import("eval_domain.zig");
const Value = skript.Value;
const b = skript.builtins;
const Self = @This();
const Model = Self;

version: Context.Version,
lift_literal: skript.Value,
invoke_primitive: skript.Value,
decide_branch: skript.Value,
join: skript.Value,

pub fn validate(self: Model, context: *const Context) skript.Error!void {
    try context.check();
    if (self.version.id == 0 or self.version.revision == 0) return error.Denied;
    if (context.model) |selected| {
        if (!selected.eql(self.version)) return error.Denied;
    }
    inline for (.{ "lift_literal", "invoke_primitive", "decide_branch", "join" }, .{ 1, 2, 1, 2 }) |name, arity| {
        try context.charge(.{ .work = 1 }, .code);
        const value = @field(self, name);
        if (value.typ != skript.builtins.type_closure) return error.TypeMismatch;
        const closure = value.obj.toRef().deref(skript.data.Closure);
        const code = closure.code orelse return error.Unsupported;
        if (code.owner != @as(?*const anyopaque, context.runtime)) return error.Denied;
        if (closure.arglist.len != arity) return error.ArityMismatch;
    }
    inline for (std.meta.fields(Context.EffectDecisionTable)) |field| {
        if (@field(context.effects, field.name) == .model) {
            if (!@field(context.effects, field.name).model.eql(self.version)) return error.Denied;
        }
    }
}

pub fn authorizes(self: Model, context: *const Context, effects: skript.Primitive.EffectSet) bool {
    if (effects._reserved != 0) return false;
    inline for (std.meta.fields(Context.EffectDecisionTable)) |field| {
        if (@field(effects, field.name)) {
            switch (@field(context.effects, field.name)) {
                .model => |version| if (!version.eql(self.version)) return false,
                .allow => {},
                .deny => return false,
            }
        }
    }
    return true;
}

pub fn encodeUnknown(ctx: *Context, facts: Domain.Unknown) skript.Error!Value {
    return makeMap(ctx, &.{
        try key(ctx, "kind"),               try key(ctx, "unknown"),
        try key(ctx, "identity"),           Value.u64(facts.identity),
        try key(ctx, "type"),               if (facts.typ) |typ| Value.typeValue(typ) else Value.nil,
        try key(ctx, "i64-range"),
        if (facts.i64_range) |range|
            try makeList(ctx, &.{ .i64(range.lower), .i64(range.upper) })
        else
            Value.nil,
        try key(ctx, "float-facts"),        try encodeFloat(ctx, facts.float_facts),
        try key(ctx, "tensor-inner"),       if (facts.tensor_inner) |inner| try key(ctx, @tagName(inner)) else .nil,
        try key(ctx, "shape"),              try encodeShape(ctx, facts.shape),
        try key(ctx, "may-overflow"),       Value.bool(facts.may_overflow),
        try key(ctx, "may-divide-by-zero"), Value.bool(facts.may_divide_by_zero),
    });
}

pub fn decodeUnknown(
    ctx: *Context,
    allocator: std.mem.Allocator,
    value: Value,
    identity: u32,
) skript.Error!Domain.Unknown {
    try ctx.charge(.{ .work = 1, .nodes = 1 }, .code);
    if (value.isNil()) return .{ .identity = identity };
    if (value.typ == b.type_type) return .{ .identity = identity, .typ = value.obj };
    if (value.typ != b.type_map) return error.TypeMismatch;
    const typ = try getField(ctx, value, "type");
    if (!typ.isNil() and typ.typ != b.type_type) return error.TypeMismatch;
    var result: Domain.Unknown = .{
        .identity = identity,
        .typ = if (typ.isNil()) null else typ.obj,
        .may_overflow = try flag(ctx, value, "may-overflow"),
        .may_divide_by_zero = try flag(ctx, value, "may-divide-by-zero"),
    };
    const integer_range = try getField(ctx, value, "i64-range");
    if (!integer_range.isNil()) {
        if (result.typ != b.type_i64) return error.TypeMismatch;
        const bounds = try pair(integer_range);
        if (bounds[0].typ != b.type_i64 or bounds[1].typ != b.type_i64) return error.TypeMismatch;
        const lower = bounds[0].obj.toInt(i64);
        const upper = bounds[1].obj.toInt(i64);
        if (lower > upper) return error.TypeMismatch;
        result.i64_range = .{ .lower = lower, .upper = upper };
    }
    const floats = try getField(ctx, value, "float-facts");
    if (!floats.isNil()) {
        if (result.typ != b.type_f16 and
            result.typ != b.type_f32 and
            result.typ != b.type_f64)
        {
            return error.TypeMismatch;
        }
        result.float_facts = try decodeFloat(ctx, floats);
    }
    const inner = try getField(ctx, value, "tensor-inner");
    if (!inner.isNil()) {
        if (result.typ != b.type_tensor or inner.typ != b.type_keyword) {
            return error.TypeMismatch;
        }
        result.tensor_inner = std.meta.stringToEnum(
            skript.intrinsics.tensor.InnerType,
            inner.obj.toPtr(skript.Sym).*,
        ) orelse return error.TypeMismatch;
    }
    const shape = try getField(ctx, value, "shape");
    if (!shape.isNil()) {
        if (result.typ != b.type_tensor) return error.TypeMismatch;
        result.shape = try decodeShape(ctx, allocator, shape);
    }
    return result;
}

fn key(ctx: *Context, name: []const u8) skript.Error!Value {
    try ctx.chargeWork(name.len, 1, .code);
    return .keyword(try ctx.runtime.store.getsym(name));
}

fn getField(ctx: *Context, record: Value, name: []const u8) skript.Error!Value {
    return skript.intrinsics.map.get(ctx, .nil, .nil, &.{ record, try key(ctx, name) });
}

fn flag(ctx: *Context, record: Value, name: []const u8) skript.Error!bool {
    const value = try getField(ctx, record, name);
    if (value.isNil()) return false;
    if (value.typ != b.type_bool) return error.TypeMismatch;
    return value.obj.toBool();
}

fn makeMap(ctx: *Context, values: []const Value) skript.Error!Value {
    try ctx.charge(.{ .nodes = 1 }, .code);
    return skript.intrinsics.map.create(ctx, .nil, .nil, values);
}

fn makeList(ctx: *Context, values: []const Value) skript.Error!Value {
    try ctx.charge(.{ .nodes = @intCast(values.len) }, .code);
    return skript.intrinsics.list.list(ctx, .nil, .nil, values);
}

fn pair(value: Value) skript.Error![2]Value {
    if (value.typ != b.type_cons) return error.TypeMismatch;
    const first = value.obj.toRef().deref([2]Value).*;
    if (first[1].typ != b.type_cons) return error.ArityMismatch;
    const second = first[1].obj.toRef().deref([2]Value).*;
    if (!second[1].isNil()) return error.ArityMismatch;
    return .{ first[0], second[0] };
}

fn encodeFloat(ctx: *Context, facts: ?Domain.FloatFacts) skript.Error!Value {
    const value = facts orelse return .nil;
    return makeMap(ctx, &.{
        try key(ctx, "range"),
        if (value.range) |range|
            try makeList(ctx, &.{ .f64(range.lower), .f64(range.upper) })
        else
            Value.nil,
        try key(ctx, "may-nan"),
        Value.bool(value.may_nan),
        try key(ctx, "may-positive-zero"),
        Value.bool(value.may_positive_zero),
        try key(ctx, "may-negative-zero"),
        Value.bool(value.may_negative_zero),
    });
}

fn decodeFloat(ctx: *Context, record: Value) skript.Error!Domain.FloatFacts {
    var result: Domain.FloatFacts = .{
        .may_nan = try flag(ctx, record, "may-nan"),
        .may_positive_zero = try flag(ctx, record, "may-positive-zero"),
        .may_negative_zero = try flag(ctx, record, "may-negative-zero"),
    };
    const interval = try getField(ctx, record, "range");
    if (interval.isNil()) {
        if (!result.may_nan or result.may_positive_zero or result.may_negative_zero) return error.TypeMismatch;
        return result;
    }
    const bounds = try pair(interval);
    const lower = try floatNumber(bounds[0]);
    const upper = try floatNumber(bounds[1]);
    if (std.math.isNan(lower) or std.math.isNan(upper) or lower > upper) return error.TypeMismatch;
    if (lower > 0 or upper < 0) {
        if (result.may_positive_zero or result.may_negative_zero) return error.TypeMismatch;
    } else if (!result.may_positive_zero and !result.may_negative_zero) {
        result.may_positive_zero = true;
        result.may_negative_zero = true;
    }
    result.range = .{ .lower = lower, .upper = upper };
    return result;
}

fn floatNumber(value: Value) skript.Error!f64 {
    return switch (value.typ) {
        b.type_f16 => value.obj.tof16(),
        b.type_f32 => value.obj.tof32(),
        b.type_f64 => value.obj.tof64(),
        else => error.TypeMismatch,
    };
}

fn encodeShape(ctx: *Context, shape: ?[]const u32) skript.Error!Value {
    const dimensions = shape orelse return .nil;
    if (dimensions.len == 0 or dimensions.len > Domain.shape_rank_max) return error.Unsupported;
    try ctx.chargeWork(dimensions.len, 1, .code);
    const values = try ctx.scratch.alloc(Value, dimensions.len);
    defer ctx.scratch.free(values);
    for (dimensions, values) |dimension, *out| out.* = .u64(dimension);
    return makeList(ctx, values);
}

fn decodeShape(ctx: *Context, allocator: std.mem.Allocator, value: Value) skript.Error![]const u32 {
    var cursor = value;
    var count: usize = 0;
    while (!cursor.isNil()) {
        if (count == Domain.shape_rank_max) return error.Unsupported;
        try ctx.charge(.{ .work = 1 }, .code);
        if (cursor.typ != b.type_cons) return error.TypeMismatch;
        const cell = cursor.obj.toRef().deref([2]Value).*;
        if (cell[0].typ != b.type_i64 and cell[0].typ != b.type_u64) return error.TypeMismatch;
        const dimension = if (cell[0].typ == b.type_i64)
            std.math.cast(u64, cell[0].obj.toInt(i64)) orelse return error.TypeMismatch
        else
            cell[0].obj.toInt(u64);
        if (dimension > std.math.maxInt(u32)) return error.TypeMismatch;
        cursor = cell[1];
        count += 1;
    }
    const dimensions = try allocator.alloc(u32, count);
    errdefer allocator.free(dimensions);
    try ctx.chargeWork(count, 1, .code);
    cursor = value;
    for (dimensions) |*out| {
        const cell = cursor.obj.toRef().deref([2]Value).*;
        out.* = if (cell[0].typ == b.type_i64) @intCast(cell[0].obj.toInt(i64)) else @intCast(cell[0].obj.toInt(u64));
        cursor = cell[1];
    }
    return dimensions;
}
