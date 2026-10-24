const std = @import("std");
const skript = @import("root.zig");
const tensor = skript.intrinsics.tensor;
const Intrinsics = @import("intrinsics.zig");
const Code = @import("code.zig");

const b = skript.builtins;
pub const shape_rank_max: usize = 1024;

pub const I64Range = struct {
    lower: i64,
    upper: i64,
};

pub const FloatRange = struct {
    lower: f64,
    upper: f64,
};

/// Facts for the ordered, non-NaN part of a floating-point value.
/// A null range with may_nan set describes a NaN-only value. A null
/// FloatFacts field on Unknown means that no floating-point facts are known.
pub const FloatFacts = struct {
    range: ?FloatRange = null,
    may_nan: bool = false,
    may_positive_zero: bool = false,
    may_negative_zero: bool = false,

    fn top() FloatFacts {
        return .{
            .range = .{
                .lower = -std.math.inf(f64),
                .upper = std.math.inf(f64),
            },
            .may_nan = true,
            .may_positive_zero = true,
            .may_negative_zero = true,
        };
    }
};

pub const Unknown = struct {
    identity: u32,
    typ: ?skript.Object = null,
    i64_range: ?I64Range = null,
    float_facts: ?FloatFacts = null,
    tensor_inner: ?tensor.InnerType = null,
    shape: ?[]const u32 = null,
    may_overflow: bool = false,
    may_divide_by_zero: bool = false,
};

pub const Slot = union(enum) {
    empty,
    known: skript.Value,
    unknown: Unknown,

    pub fn requireKnown(self: Slot) skript.Error!skript.Value {
        return switch (self) {
            .known => |value| value,
            .unknown => error.Unsupported,
            .empty => error.InvalidCode,
        };
    }
};

pub fn describe(
    allocator: std.mem.Allocator,
    ctx: *skript.EvalContext,
    value: skript.Value,
    identity: u32,
) skript.Error!Unknown {
    try chargeWork(ctx, 1);
    try ctx.charge(.{ .nodes = 1 }, .code);

    var result: Unknown = try summarizeKnown(ctx, value, identity);
    if (result.shape) |shape| result.shape = try copyShape(allocator, ctx, shape);
    return result;
}

pub fn join(
    allocator: std.mem.Allocator,
    ctx: *skript.EvalContext,
    left: Slot,
    right: Slot,
    identity: u32,
) skript.Error!Slot {
    try chargeWork(ctx, 1);
    try ctx.charge(.{ .nodes = 1 }, .code);
    if (knownScalarMatch(left, right)) |value| return .{ .known = value };

    const left_summary = try summarizeSlot(ctx, left) orelse return error.InvalidCode;
    const right_summary = try summarizeSlot(ctx, right) orelse return error.InvalidCode;
    const result_identity = if (sameUnknownIdentity(left, right))
        left_summary.identity
    else
        identity;

    var result: Unknown = .{
        .identity = result_identity,
        .may_overflow = left_summary.may_overflow or right_summary.may_overflow,
        .may_divide_by_zero = left_summary.may_divide_by_zero or
            right_summary.may_divide_by_zero,
    };

    if (left_summary.typ != null and left_summary.typ == right_summary.typ) {
        result.typ = left_summary.typ;
    }

    if (result.typ == b.type_i64) {
        result.i64_range = joinI64Ranges(left_summary.i64_range, right_summary.i64_range);
    } else if (isFloatType(result.typ)) {
        result.float_facts = joinFloatFacts(
            left_summary.float_facts,
            right_summary.float_facts,
        );
    } else if (result.typ == b.type_tensor) {
        if (left_summary.tensor_inner != null and
            left_summary.tensor_inner == right_summary.tensor_inner)
        {
            result.tensor_inner = left_summary.tensor_inner;
        }
        result.shape = try joinShapes(
            allocator,
            ctx,
            left_summary.shape,
            right_summary.shape,
        );
    }

    return .{ .unknown = result };
}

pub fn primitive(
    ctx: *skript.EvalContext,
    spec: *const skript.Primitive.Spec,
    arguments: []const Slot,
    identity: u32,
) skript.Error!?Slot {
    if (arguments.len != 2) return null;
    if (arguments[0] != .unknown and arguments[1] != .unknown) return null;
    if (!spec.effects.eql(.none) or spec.invoke != .native) return null;
    if (spec.resources == .unknown or spec.resources == .denied) return null;
    const Rule = struct {
        builtin: Intrinsics.Intrinsic,
        op: Code.ArithOp,
        typ: skript.Object,
    };
    const rules = [_]Rule{
        .{ .builtin = .@"i64.add", .op = .add, .typ = b.type_i64 },
        .{ .builtin = .@"i64.sub", .op = .sub, .typ = b.type_i64 },
        .{ .builtin = .@"i64.mul", .op = .mul, .typ = b.type_i64 },
        .{ .builtin = .@"i64.div", .op = .div, .typ = b.type_i64 },
        .{ .builtin = .@"i64.eq", .op = .equal, .typ = b.type_i64 },
        .{ .builtin = .@"i64.lt", .op = .less, .typ = b.type_i64 },
        .{ .builtin = .@"f64.add", .op = .add, .typ = b.type_f64 },
        .{ .builtin = .@"f64.sub", .op = .sub, .typ = b.type_f64 },
        .{ .builtin = .@"f64.mul", .op = .mul, .typ = b.type_f64 },
        .{ .builtin = .@"f64.div", .op = .div, .typ = b.type_f64 },
        .{ .builtin = .@"f64.eq", .op = .equal, .typ = b.type_f64 },
        .{ .builtin = .@"f64.lt", .op = .less, .typ = b.type_f64 },
        .{ .builtin = .@"f32.add", .op = .add, .typ = b.type_f32 },
        .{ .builtin = .@"f32.sub", .op = .sub, .typ = b.type_f32 },
        .{ .builtin = .@"f32.mul", .op = .mul, .typ = b.type_f32 },
        .{ .builtin = .@"f32.div", .op = .div, .typ = b.type_f32 },
        .{ .builtin = .@"f32.eq", .op = .equal, .typ = b.type_f32 },
        .{ .builtin = .@"f32.lt", .op = .less, .typ = b.type_f32 },
    };
    try chargeWork(ctx, rules.len);
    const intrinsics = &ctx.runtime.intrinsics;
    for (rules) |rule| {
        if (spec.id != intrinsics.primitiveId(rule.builtin)) continue;
        if (spec.invoke.native != intrinsics.funcs[@backingInt(rule.builtin)]) return null;
        for (arguments) |argument| {
            const typ = switch (argument) {
                .known => |value| value.typ,
                .unknown => |value| value.typ orelse return null,
                .empty => return error.InvalidCode,
            };
            if (typ != rule.typ) return null;
        }
        const result = try arithmetic(ctx, rule.op, arguments[0], arguments[1], identity);
        return result;
    }
    return null;
}

pub fn arithmetic(
    ctx: *skript.EvalContext,
    op: Code.ArithOp,
    left: Slot,
    right: Slot,
    identity: u32,
) skript.Error!Slot {
    try chargeWork(ctx, 1);
    try ctx.charge(.{ .nodes = 1 }, .code);
    if (isEmpty(left) or isEmpty(right)) return error.InvalidCode;
    if (!isUnknown(left) and !isUnknown(right)) return error.InvalidCode;

    const left_summary = try summarizeSlot(ctx, left) orelse return error.InvalidCode;
    const right_summary = try summarizeSlot(ctx, right) orelse return error.InvalidCode;
    const numeric_type = numericJoinType(left_summary.typ, right_summary.typ) orelse
        return error.Unsupported;

    var result: Unknown = .{
        .identity = identity,
        .typ = switch (op) {
            .equal, .less, .greater => b.type_bool,
            .add, .sub, .mul, .div => numeric_type,
        },
        .may_overflow = left_summary.may_overflow or right_summary.may_overflow,
        .may_divide_by_zero = left_summary.may_divide_by_zero or
            right_summary.may_divide_by_zero,
    };

    switch (op) {
        .add, .sub, .mul, .div => {
            if (numeric_type == b.type_i64 and
                left_summary.typ == b.type_i64 and
                right_summary.typ == b.type_i64)
            {
                const transfer = i64Arithmetic(
                    op,
                    usableI64Range(left_summary.i64_range),
                    usableI64Range(right_summary.i64_range),
                );
                result.i64_range = transfer.range;
                result.may_overflow = result.may_overflow or transfer.may_overflow;
                result.may_divide_by_zero = result.may_divide_by_zero or
                    transfer.may_divide_by_zero;
            } else if (isFloatType(numeric_type) and
                left_summary.typ == numeric_type and
                right_summary.typ == numeric_type)
            {
                result.float_facts = floatArithmeticForType(
                    numeric_type,
                    op,
                    floatFactsOrTop(left_summary.float_facts),
                    floatFactsOrTop(right_summary.float_facts),
                );
            } else {
                addConservativeIntegerRisks(&result, numeric_type, op);
            }
        },
        .equal, .less, .greater => {
            if (!result.may_overflow and !result.may_divide_by_zero) {
                const same_identity = sameUnknownIdentity(left, right);
                const known = if (left_summary.typ == b.type_i64 and
                    right_summary.typ == b.type_i64)
                    compareI64(
                        op,
                        usableI64Range(left_summary.i64_range),
                        usableI64Range(right_summary.i64_range),
                        same_identity,
                    )
                else if (left_summary.typ != null and
                    left_summary.typ == right_summary.typ and
                    isFloatType(left_summary.typ))
                    compareFloat(
                        op,
                        floatFactsOrTop(left_summary.float_facts),
                        floatFactsOrTop(right_summary.float_facts),
                        same_identity,
                    )
                else
                    null;
                if (known) |value| return .{ .known = skript.Value.bool(value) };
            }
        },
    }

    return .{ .unknown = result };
}

fn chargeWork(ctx: *skript.EvalContext, count: usize) skript.Error!void {
    try ctx.check();
    const count_u64 = std.math.cast(u64, count) orelse return error.Unsupported;
    try ctx.chargeWork(count_u64, 1, .code);
}

fn copyShape(
    allocator: std.mem.Allocator,
    ctx: *skript.EvalContext,
    shape: []const u32,
) skript.Error![]const u32 {
    try chargeWork(ctx, shape.len);
    const copy = allocator.dupe(u32, shape) catch |err| {
        try ctx.check();
        return err;
    };
    return copy;
}

fn summarizeSlot(ctx: *skript.EvalContext, slot: Slot) skript.Error!?Unknown {
    return switch (slot) {
        .known => |value| try summarizeKnown(ctx, value, 0),
        .unknown => |unknown| unknown,
        .empty => null,
    };
}

fn summarizeKnown(
    ctx: *skript.EvalContext,
    value: skript.Value,
    identity: u32,
) skript.Error!Unknown {
    var result: Unknown = .{ .identity = identity, .typ = value.typ };
    if (value.typ == b.type_i64) {
        const number = value.obj.toInt(i64);
        result.i64_range = .{ .lower = number, .upper = number };
    } else if (value.typ == b.type_f16) {
        result.float_facts = floatPoint(value.obj.tof16());
    } else if (value.typ == b.type_f32) {
        result.float_facts = floatPoint(value.obj.tof32());
    } else if (value.typ == b.type_f64) {
        result.float_facts = floatPoint(value.obj.tof64());
    } else if (value.typ == b.type_tensor) {
        if (value.obj == .null) return error.Unsupported;
        const holder = value.obj.toRef().deref(tensor.TensorHolder);
        result.tensor_inner = holder.inner;
        result.shape = try tensorShape(ctx, holder);
    }
    return result;
}

fn tensorShape(
    ctx: *skript.EvalContext,
    holder: *const tensor.TensorHolder,
) skript.Error!?[]const u32 {
    if (holder.rank == 0) return error.Unsupported;
    const rank = std.math.cast(usize, holder.rank) orelse return error.Unsupported;
    if (rank != holder.shape.len or rank > shape_rank_max) return error.Unsupported;

    try chargeWork(ctx, rank);
    var element_count: usize = 1;
    for (holder.shape) |dimension| {
        element_count = std.math.mul(
            usize,
            element_count,
            std.math.cast(usize, dimension) orelse return error.Unsupported,
        ) catch return error.Unsupported;
    }
    if (element_count != holder.data.len) return error.Unsupported;
    if (holder.inner == .empty and holder.data.len != 0) return error.Unsupported;
    return holder.shape;
}

fn isEmpty(slot: Slot) bool {
    return switch (slot) {
        .empty => true,
        else => false,
    };
}

fn isUnknown(slot: Slot) bool {
    return switch (slot) {
        .unknown => true,
        else => false,
    };
}

fn sameUnknownIdentity(left: Slot, right: Slot) bool {
    const left_identity = switch (left) {
        .unknown => |unknown| unknown.identity,
        else => return false,
    };
    return switch (right) {
        .unknown => |unknown| unknown.identity == left_identity,
        else => false,
    };
}

fn knownScalarMatch(left: Slot, right: Slot) ?skript.Value {
    const left_value = switch (left) {
        .known => |value| value,
        else => return null,
    };
    const right_value = switch (right) {
        .known => |value| value,
        else => return null,
    };
    if (!isImmutableScalar(left_value.typ)) return null;
    if (left_value.typ != right_value.typ or left_value.obj != right_value.obj) return null;
    return left_value;
}

fn isImmutableScalar(typ: skript.Object) bool {
    return typ == b.type_nil or
        typ == b.type_bool or
        typ == b.type_symbol or
        typ == b.type_keyword or
        typ == b.type_f8 or
        typ == b.type_f16 or
        typ == b.type_f32 or
        typ == b.type_f64 or
        typ == b.type_u8 or
        typ == b.type_u16 or
        typ == b.type_u32 or
        typ == b.type_u64 or
        typ == b.type_i8 or
        typ == b.type_i16 or
        typ == b.type_i32 or
        typ == b.type_i64 or
        typ == b.type_c8 or
        typ == b.type_c16 or
        typ == b.type_c32;
}

fn joinI64Ranges(left: ?I64Range, right: ?I64Range) ?I64Range {
    const left_range = validI64Range(left) orelse return null;
    const right_range = validI64Range(right) orelse return null;
    return .{
        .lower = @min(left_range.lower, right_range.lower),
        .upper = @max(left_range.upper, right_range.upper),
    };
}

fn validI64Range(range: ?I64Range) ?I64Range {
    const value = range orelse return null;
    return if (value.lower <= value.upper) value else null;
}

fn usableI64Range(range: ?I64Range) I64Range {
    return validI64Range(range) orelse .{
        .lower = std.math.minInt(i64),
        .upper = std.math.maxInt(i64),
    };
}

fn joinFloatFacts(left: ?FloatFacts, right: ?FloatFacts) ?FloatFacts {
    const left_facts = normalizeFloatFacts(left orelse return null) orelse return null;
    const right_facts = normalizeFloatFacts(right orelse return null) orelse return null;

    var result: FloatFacts = .{
        .may_nan = left_facts.may_nan or right_facts.may_nan,
        .may_positive_zero = left_facts.may_positive_zero or
            right_facts.may_positive_zero,
        .may_negative_zero = left_facts.may_negative_zero or
            right_facts.may_negative_zero,
    };
    result.range = if (left_facts.range) |left_range|
        if (right_facts.range) |right_range|
            FloatRange{
                .lower = @min(left_range.lower, right_range.lower),
                .upper = @max(left_range.upper, right_range.upper),
            }
        else
            left_range
    else
        right_facts.range;
    return normalizeFloatFacts(result);
}

fn normalizeFloatFacts(raw: FloatFacts) ?FloatFacts {
    var facts = raw;
    if (facts.range) |range| {
        if (std.math.isNan(range.lower) or
            std.math.isNan(range.upper) or
            range.lower > range.upper)
        {
            return null;
        }
        const spans_signed_zero = range.lower == 0.0 and
            range.upper == 0.0 and
            std.math.signbit(range.lower) != std.math.signbit(range.upper);
        if (floatRangeContainsZero(range)) {
            if (range.lower != 0.0 or range.upper != 0.0 or
                spans_signed_zero or
                (!facts.may_positive_zero and !facts.may_negative_zero))
            {
                facts.may_positive_zero = true;
                facts.may_negative_zero = true;
            }
        } else {
            facts.may_positive_zero = false;
            facts.may_negative_zero = false;
        }
    } else {
        facts.may_positive_zero = false;
        facts.may_negative_zero = false;
        if (!facts.may_nan) return null;
    }
    return facts;
}

fn floatFactsOrTop(facts: ?FloatFacts) FloatFacts {
    return if (facts) |raw| normalizeFloatFacts(raw) orelse FloatFacts.top() else FloatFacts.top();
}

fn joinShapes(
    allocator: std.mem.Allocator,
    ctx: *skript.EvalContext,
    left: ?[]const u32,
    right: ?[]const u32,
) skript.Error!?[]const u32 {
    const left_shape = left orelse return null;
    const right_shape = right orelse return null;
    if (left_shape.len == 0 or
        left_shape.len != right_shape.len or
        left_shape.len > shape_rank_max)
    {
        return null;
    }
    try chargeWork(ctx, left_shape.len);
    if (!std.mem.eql(u32, left_shape, right_shape)) return null;
    const result = try copyShape(allocator, ctx, left_shape);
    return result;
}

const I64Transfer = struct {
    range: ?I64Range = null,
    may_overflow: bool = false,
    may_divide_by_zero: bool = false,
};

fn i64Arithmetic(
    op: Code.ArithOp,
    left: I64Range,
    right: I64Range,
) I64Transfer {
    return switch (op) {
        .add => i64Add(left, right),
        .sub => i64Sub(left, right),
        .mul => i64Mul(left, right),
        .div => i64Div(left, right),
        .equal, .less, .greater => unreachable,
    };
}

fn i64Add(left: I64Range, right: I64Range) I64Transfer {
    const lower = std.math.add(i64, left.lower, right.lower) catch
        return .{ .may_overflow = true };
    const upper = std.math.add(i64, left.upper, right.upper) catch
        return .{ .may_overflow = true };
    return .{ .range = .{ .lower = lower, .upper = upper } };
}

fn i64Sub(left: I64Range, right: I64Range) I64Transfer {
    const lower = std.math.sub(i64, left.lower, right.upper) catch
        return .{ .may_overflow = true };
    const upper = std.math.sub(i64, left.upper, right.lower) catch
        return .{ .may_overflow = true };
    return .{ .range = .{ .lower = lower, .upper = upper } };
}

fn i64Mul(left: I64Range, right: I64Range) I64Transfer {
    const a = @as(i128, left.lower) * @as(i128, right.lower);
    const c = @as(i128, left.lower) * @as(i128, right.upper);
    const d = @as(i128, left.upper) * @as(i128, right.lower);
    const e = @as(i128, left.upper) * @as(i128, right.upper);
    const lower = @min(@min(a, c), @min(d, e));
    const upper = @max(@max(a, c), @max(d, e));
    if (lower < std.math.minInt(i64) or upper > std.math.maxInt(i64)) {
        return .{ .may_overflow = true };
    }
    return .{ .range = .{
        .lower = @intCast(lower),
        .upper = @intCast(upper),
    } };
}

fn i64Div(left: I64Range, right: I64Range) I64Transfer {
    var result: I64Transfer = .{};
    if (right.lower <= 0 and right.upper >= 0) result.may_divide_by_zero = true;
    if (left.lower == std.math.minInt(i64) and
        right.lower <= -1 and right.upper >= -1)
    {
        result.may_overflow = true;
    }
    if (result.may_divide_by_zero or result.may_overflow) return result;

    const a = @divTrunc(@as(i128, left.lower), @as(i128, right.lower));
    const c = @divTrunc(@as(i128, left.lower), @as(i128, right.upper));
    const d = @divTrunc(@as(i128, left.upper), @as(i128, right.lower));
    const e = @divTrunc(@as(i128, left.upper), @as(i128, right.upper));
    return .{ .range = .{
        .lower = @intCast(@min(@min(a, c), @min(d, e))),
        .upper = @intCast(@max(@max(a, c), @max(d, e))),
    } };
}

fn compareI64(
    op: Code.ArithOp,
    left: I64Range,
    right: I64Range,
    same_identity: bool,
) ?bool {
    return switch (op) {
        .equal => if (same_identity)
            true
        else if (left.upper < right.lower or right.upper < left.lower)
            false
        else if (left.lower == left.upper and
            right.lower == right.upper and
            left.lower == right.lower)
            true
        else
            null,
        .less => if (same_identity)
            false
        else if (left.upper < right.lower)
            true
        else if (left.lower >= right.upper)
            false
        else
            null,
        .greater => if (same_identity)
            false
        else if (left.lower > right.upper)
            true
        else if (left.upper <= right.lower)
            false
        else
            null,
        .add, .sub, .mul, .div => unreachable,
    };
}

fn floatPoint(value: anytype) FloatFacts {
    if (std.math.isNan(value)) return .{ .may_nan = true };
    const widened: f64 = @floatCast(value);
    const is_zero = value == 0.0;
    return .{
        .range = .{ .lower = widened, .upper = widened },
        .may_positive_zero = is_zero and !std.math.signbit(value),
        .may_negative_zero = is_zero and std.math.signbit(value),
    };
}

fn floatArithmeticForType(
    typ: skript.Object,
    op: Code.ArithOp,
    left: FloatFacts,
    right: FloatFacts,
) FloatFacts {
    if (typ == b.type_f16) return floatArithmetic(f16, op, left, right);
    if (typ == b.type_f32) return floatArithmetic(f32, op, left, right);
    if (typ == b.type_f64) return floatArithmetic(f64, op, left, right);
    unreachable;
}

fn floatArithmetic(
    comptime Float: type,
    op: Code.ArithOp,
    left: FloatFacts,
    right: FloatFacts,
) FloatFacts {
    if (floatSingleton(Float, left)) |left_value| {
        if (floatSingleton(Float, right)) |right_value| {
            return floatPoint(floatOperation(Float, op, left_value, right_value));
        }
    }

    const left_range = left.range orelse return .{ .may_nan = true };
    const right_range = right.range orelse return .{ .may_nan = true };
    const creates_nan = floatOperationMayCreateNan(op, left_range, right_range);
    const may_nan = left.may_nan or right.may_nan or creates_nan;
    if (creates_nan or
        (op == .div and floatRangeContainsZero(right_range)))
    {
        return orderedFloatTop(may_nan);
    }

    const left_lower = narrowFloat(Float, left_range.lower) orelse return FloatFacts.top();
    const left_upper = narrowFloat(Float, left_range.upper) orelse return FloatFacts.top();
    const right_lower = narrowFloat(Float, right_range.lower) orelse return FloatFacts.top();
    const right_upper = narrowFloat(Float, right_range.upper) orelse return FloatFacts.top();

    const a = floatOperation(Float, op, left_lower, right_lower);
    const c = floatOperation(Float, op, left_lower, right_upper);
    const d = floatOperation(Float, op, left_upper, right_lower);
    const e = floatOperation(Float, op, left_upper, right_upper);
    if (std.math.isNan(a) or std.math.isNan(c) or
        std.math.isNan(d) or std.math.isNan(e))
    {
        return FloatFacts.top();
    }

    const lower: f64 = @floatCast(@min(@min(a, c), @min(d, e)));
    const upper: f64 = @floatCast(@max(@max(a, c), @max(d, e)));
    return normalizeFloatFacts(.{
        .range = .{ .lower = lower, .upper = upper },
        .may_nan = may_nan,
    }) orelse FloatFacts.top();
}

fn floatSingleton(comptime Float: type, facts: FloatFacts) ?Float {
    if (facts.may_nan) return null;
    const range = facts.range orelse return null;
    if (range.lower != range.upper) return null;
    if (range.lower == 0.0) {
        if (facts.may_positive_zero == facts.may_negative_zero) return null;
        const zero: Float = 0.0;
        return if (facts.may_negative_zero) -zero else zero;
    }
    return narrowFloat(Float, range.lower);
}

fn narrowFloat(comptime Float: type, value: f64) ?Float {
    if (std.math.isNan(value)) return null;
    const narrowed: Float = @floatCast(value);
    const widened: f64 = @floatCast(narrowed);
    if (widened != value) return null;
    if (value == 0.0 and std.math.signbit(widened) != std.math.signbit(value)) return null;
    return narrowed;
}

fn floatOperation(
    comptime Float: type,
    op: Code.ArithOp,
    left: Float,
    right: Float,
) Float {
    return switch (op) {
        .add => left + right,
        .sub => left - right,
        .mul => left * right,
        .div => left / right,
        .equal, .less, .greater => unreachable,
    };
}

fn floatOperationMayCreateNan(
    op: Code.ArithOp,
    left: FloatRange,
    right: FloatRange,
) bool {
    const left_positive_inf = left.upper == std.math.inf(f64);
    const left_negative_inf = left.lower == -std.math.inf(f64);
    const right_positive_inf = right.upper == std.math.inf(f64);
    const right_negative_inf = right.lower == -std.math.inf(f64);
    const left_inf = left_positive_inf or left_negative_inf;
    const right_inf = right_positive_inf or right_negative_inf;
    const left_zero = floatRangeContainsZero(left);
    const right_zero = floatRangeContainsZero(right);

    return switch (op) {
        .add => (left_positive_inf and right_negative_inf) or
            (left_negative_inf and right_positive_inf),
        .sub => (left_positive_inf and right_positive_inf) or
            (left_negative_inf and right_negative_inf),
        .mul => (left_zero and right_inf) or (right_zero and left_inf),
        .div => (left_zero and right_zero) or (left_inf and right_inf),
        .equal, .less, .greater => unreachable,
    };
}

fn orderedFloatTop(may_nan: bool) FloatFacts {
    return .{
        .range = .{
            .lower = -std.math.inf(f64),
            .upper = std.math.inf(f64),
        },
        .may_nan = may_nan,
        .may_positive_zero = true,
        .may_negative_zero = true,
    };
}

fn compareFloat(
    op: Code.ArithOp,
    left: FloatFacts,
    right: FloatFacts,
    same_identity: bool,
) ?bool {
    return switch (op) {
        .equal => if (same_identity)
            if (left.range == null and right.range == null)
                false
            else if (!left.may_nan and !right.may_nan)
                true
            else
                null
        else if (left.range == null or right.range == null)
            false
        else if (left.range.?.upper < right.range.?.lower or
            right.range.?.upper < left.range.?.lower)
            false
        else if (!left.may_nan and !right.may_nan and
            left.range.?.lower == left.range.?.upper and
            right.range.?.lower == right.range.?.upper and
            left.range.?.lower == right.range.?.lower)
            true
        else
            null,
        .less => if (same_identity)
            false
        else if (left.range == null or right.range == null)
            false
        else if (!left.may_nan and !right.may_nan and
            left.range.?.upper < right.range.?.lower)
            true
        else if (left.range.?.lower >= right.range.?.upper)
            false
        else
            null,
        .greater => if (same_identity)
            false
        else if (left.range == null or right.range == null)
            false
        else if (!left.may_nan and !right.may_nan and
            left.range.?.lower > right.range.?.upper)
            true
        else if (left.range.?.upper <= right.range.?.lower)
            false
        else
            null,
        .add, .sub, .mul, .div => unreachable,
    };
}

fn floatRangeContainsZero(range: FloatRange) bool {
    return range.lower <= 0.0 and range.upper >= 0.0;
}

fn isFloatType(typ: ?skript.Object) bool {
    const value = typ orelse return false;
    return value == b.type_f16 or value == b.type_f32 or value == b.type_f64;
}

fn isIntegerType(typ: skript.Object) bool {
    return typ == b.type_i8 or
        typ == b.type_i16 or
        typ == b.type_i32 or
        typ == b.type_i64 or
        typ == b.type_u8 or
        typ == b.type_u16 or
        typ == b.type_u32 or
        typ == b.type_u64;
}

fn isSignedIntegerType(typ: skript.Object) bool {
    return typ == b.type_i8 or
        typ == b.type_i16 or
        typ == b.type_i32 or
        typ == b.type_i64;
}

fn numericJoinType(left: ?skript.Object, right: ?skript.Object) ?skript.Object {
    const left_type = left orelse return null;
    const right_type = right orelse return null;
    const args = [_]skript.Value{
        .init(left_type, .null),
        .init(right_type, .null),
    };
    return skript.intrinsics.numericJoin(&args);
}

fn addConservativeIntegerRisks(
    result: *Unknown,
    numeric_type: ?skript.Object,
    op: Code.ArithOp,
) void {
    const typ = numeric_type orelse {
        result.may_overflow = true;
        if (op == .div) result.may_divide_by_zero = true;
        return;
    };
    if (!isIntegerType(typ)) return;
    switch (op) {
        .add, .sub, .mul => result.may_overflow = true,
        .div => {
            result.may_divide_by_zero = true;
            if (isSignedIntegerType(typ)) result.may_overflow = true;
        },
        .equal, .less, .greater => unreachable,
    }
}

fn initTestRuntime() !*skript.Runtime {
    return skript.Runtime.init(std.testing.allocator, std.testing.io);
}

test "describe preserves i64 values above f64 precision" {
    const runtime = try initTestRuntime();
    defer runtime.deinit();

    const value: i64 = 9_007_199_254_740_993;
    const summary = try describe(std.testing.allocator, runtime.context(), .i64(value), 7);
    const range = summary.i64_range orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(value, range.lower);
    try std.testing.expectEqual(value, range.upper);
}

test "integer transfer preserves overflow and division uncertainty" {
    const runtime = try initTestRuntime();
    defer runtime.deinit();
    const ctx = runtime.context();

    const near_max: Slot = .{ .unknown = .{
        .identity = 1,
        .typ = b.type_i64,
        .i64_range = .{
            .lower = std.math.maxInt(i64) - 1,
            .upper = std.math.maxInt(i64),
        },
    } };
    const sum = try arithmetic(ctx, .add, near_max, .{
        .known = .i64(1),
    }, 2);
    switch (sum) {
        .unknown => |unknown| {
            try std.testing.expect(unknown.may_overflow);
            try std.testing.expectEqual(@as(?I64Range, null), unknown.i64_range);
        },
        else => return error.TestUnexpectedResult,
    }

    const uncertain_divisor: Slot = .{ .unknown = .{
        .identity = 3,
        .typ = b.type_i64,
        .i64_range = .{ .lower = -1, .upper = 1 },
    } };
    const quotient = try arithmetic(ctx, .div, .{
        .known = .i64(8),
    }, uncertain_divisor, 4);
    switch (quotient) {
        .unknown => |unknown| try std.testing.expect(unknown.may_divide_by_zero),
        else => return error.TestUnexpectedResult,
    }

    const minimum: Slot = .{ .unknown = .{
        .identity = 5,
        .typ = b.type_i64,
        .i64_range = .{
            .lower = std.math.minInt(i64),
            .upper = std.math.minInt(i64),
        },
    } };
    const division_overflow = try arithmetic(ctx, .div, minimum, .{
        .known = .i64(-1),
    }, 6);
    switch (division_overflow) {
        .unknown => |unknown| try std.testing.expect(unknown.may_overflow),
        else => return error.TestUnexpectedResult,
    }
    const combined_errors = try arithmetic(ctx, .div, minimum, .{
        .unknown = .{
            .identity = 7,
            .typ = b.type_i64,
            .i64_range = .{ .lower = -1, .upper = 0 },
        },
    }, 8);
    switch (combined_errors) {
        .unknown => |unknown| {
            try std.testing.expect(unknown.may_overflow);
            try std.testing.expect(unknown.may_divide_by_zero);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "float comparisons keep NaN and signed-zero alternatives" {
    const runtime = try initTestRuntime();
    defer runtime.deinit();
    const ctx = runtime.context();

    const maybe_nan: Slot = .{ .unknown = .{
        .identity = 1,
        .typ = b.type_f64,
        .float_facts = .{
            .range = .{ .lower = 0.0, .upper = 0.0 },
            .may_nan = true,
            .may_positive_zero = true,
        },
    } };
    const comparison = try arithmetic(ctx, .less, maybe_nan, .{
        .known = .f64(1.0),
    }, 2);
    switch (comparison) {
        .unknown => {},
        else => return error.TestUnexpectedResult,
    }

    const self_comparison = try arithmetic(ctx, .less, maybe_nan, maybe_nan, 3);
    switch (self_comparison) {
        .known => |value| try std.testing.expectEqual(skript.Value.false, value),
        else => return error.TestUnexpectedResult,
    }

    const zero_join = try join(std.testing.allocator, ctx, .{
        .known = .f64(0.0),
    }, .{
        .known = .f64(-0.0),
    }, 4);
    switch (zero_join) {
        .unknown => |unknown| {
            const facts = unknown.float_facts orelse return error.TestUnexpectedResult;
            try std.testing.expect(facts.may_positive_zero);
            try std.testing.expect(facts.may_negative_zero);
        },
        else => return error.TestUnexpectedResult,
    }

    const zero_equal = try arithmetic(ctx, .equal, zero_join, .{
        .known = .f64(0.0),
    }, 5);
    switch (zero_equal) {
        .known => |value| try std.testing.expectEqual(skript.Value.true, value),
        else => return error.TestUnexpectedResult,
    }
}

test "greater resolves i64 ranges and refuses to fold across an overlap" {
    const runtime = try initTestRuntime();
    defer runtime.deinit();
    const ctx = runtime.context();

    // Disjoint and ordered: every left value exceeds every right value.
    const high: Slot = .{ .unknown = .{
        .identity = 11,
        .typ = b.type_i64,
        .i64_range = .{ .lower = 10, .upper = 20 },
    } };
    const low: Slot = .{ .unknown = .{
        .identity = 12,
        .typ = b.type_i64,
        .i64_range = .{ .lower = 0, .upper = 5 },
    } };
    const definitely_greater = try arithmetic(ctx, .greater, high, low, 1);
    switch (definitely_greater) {
        .known => |value| try std.testing.expectEqual(skript.Value.true, value),
        else => return error.TestUnexpectedResult,
    }

    // Touching at a single point is still strictly greater on the left.
    const touching: Slot = .{ .unknown = .{
        .identity = 13,
        .typ = b.type_i64,
        .i64_range = .{ .lower = 6, .upper = 6 },
    } };
    const above_touching = try arithmetic(ctx, .greater, high, touching, 2);
    switch (above_touching) {
        .known => |value| try std.testing.expectEqual(skript.Value.true, value),
        else => return error.TestUnexpectedResult,
    }

    // Disjoint but the other way round: always false.
    const definitely_less = try arithmetic(ctx, .greater, low, high, 3);
    switch (definitely_less) {
        .known => |value| try std.testing.expectEqual(skript.Value.false, value),
        else => return error.TestUnexpectedResult,
    }

    // Equal singleton ranges are not strictly greater.
    const equal_points = try arithmetic(ctx, .greater, touching, .{
        .known = .i64(6),
    }, 4);
    switch (equal_points) {
        .known => |value| try std.testing.expectEqual(skript.Value.false, value),
        else => return error.TestUnexpectedResult,
    }

    // Overlapping ranges admit both outcomes; folding either way is a
    // miscompile, so the domain must stay unknown.
    const overlapping: Slot = .{ .unknown = .{
        .identity = 14,
        .typ = b.type_i64,
        .i64_range = .{ .lower = 15, .upper = 25 },
    } };
    const ambiguous = try arithmetic(ctx, .greater, high, overlapping, 5);
    switch (ambiguous) {
        .unknown => {},
        else => return error.TestUnexpectedResult,
    }

    // The same identity can never be strictly greater than itself.
    const self_comparison = try arithmetic(ctx, .greater, high, high, 6);
    switch (self_comparison) {
        .known => |value| try std.testing.expectEqual(skript.Value.false, value),
        else => return error.TestUnexpectedResult,
    }
}

test "greater on floats is guarded by may_nan on the true branch only" {
    const runtime = try initTestRuntime();
    defer runtime.deinit();
    const ctx = runtime.context();

    const ordered: Slot = .{ .unknown = .{
        .identity = 21,
        .typ = b.type_f64,
        .float_facts = .{
            .range = .{ .lower = 5.0, .upper = 10.0 },
            .may_positive_zero = false,
            .may_negative_zero = false,
        },
    } };
    const below: Slot = .{ .unknown = .{
        .identity = 22,
        .typ = b.type_f64,
        .float_facts = .{
            .range = .{ .lower = 0.0, .upper = 1.0 },
            .may_positive_zero = false,
            .may_negative_zero = false,
        },
    } };

    // Without NaN the ranges alone decide: true.
    const ordered_greater = try arithmetic(ctx, .greater, ordered, below, 1);
    switch (ordered_greater) {
        .known => |value| try std.testing.expectEqual(skript.Value.true, value),
        else => return error.TestUnexpectedResult,
    }

    // The decisive case: identical ranges, but the left may be NaN. The
    // range test would say `true`; IEEE says NaN > x is false, so the answer
    // must be unknown. Dropping the may_nan guard here folds a comparison to a
    // constant the runtime does not agree with.
    const nan_capable: Slot = .{ .unknown = .{
        .identity = 23,
        .typ = b.type_f64,
        .float_facts = .{
            .range = .{ .lower = 5.0, .upper = 10.0 },
            .may_nan = true,
            .may_positive_zero = false,
            .may_negative_zero = false,
        },
    } };
    const nan_guarded = try arithmetic(ctx, .greater, nan_capable, below, 2);
    switch (nan_guarded) {
        .unknown => {},
        else => return error.TestUnexpectedResult,
    }

    // A NaN-capable RIGHT operand blocks the true branch for the same reason.
    const nan_right: Slot = .{ .unknown = .{
        .identity = 24,
        .typ = b.type_f64,
        .float_facts = .{
            .range = .{ .lower = 0.0, .upper = 1.0 },
            .may_nan = true,
            .may_positive_zero = false,
            .may_negative_zero = false,
        },
    } };
    const nan_right_guarded = try arithmetic(ctx, .greater, ordered, nan_right, 3);
    switch (nan_right_guarded) {
        .unknown => {},
        else => return error.TestUnexpectedResult,
    }

    // The false branch needs no guard: a NaN on either side also compares
    // false, so `below > ordered` is false even with NaN possible.
    const nan_left: Slot = .{ .unknown = .{
        .identity = 25,
        .typ = b.type_f64,
        .float_facts = .{
            .range = .{ .lower = 0.0, .upper = 1.0 },
            .may_nan = true,
            .may_positive_zero = false,
            .may_negative_zero = false,
        },
    } };
    const false_despite_nan = try arithmetic(ctx, .greater, nan_left, ordered, 4);
    switch (false_despite_nan) {
        .known => |value| try std.testing.expectEqual(skript.Value.false, value),
        else => return error.TestUnexpectedResult,
    }

    // NaN against itself, mirroring the existing `.less` self-comparison.
    const self_comparison = try arithmetic(ctx, .greater, nan_capable, nan_capable, 5);
    switch (self_comparison) {
        .known => |value| try std.testing.expectEqual(skript.Value.false, value),
        else => return error.TestUnexpectedResult,
    }
}

test "tensor join keeps only common copied shape facts" {
    const runtime = try initTestRuntime();
    defer runtime.deinit();
    const ctx = runtime.context();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const left_shape = [_]u32{ 2, 3 };
    const same_shape = [_]u32{ 2, 3 };
    const other_shape = [_]u32{ 2, 4 };
    const left: Slot = .{ .unknown = .{
        .identity = 1,
        .typ = b.type_tensor,
        .tensor_inner = .f64,
        .shape = left_shape[0..],
    } };
    const same: Slot = .{ .unknown = .{
        .identity = 2,
        .typ = b.type_tensor,
        .tensor_inner = .f64,
        .shape = same_shape[0..],
    } };
    const joined = try join(arena.allocator(), ctx, left, same, 3);
    switch (joined) {
        .unknown => |unknown| {
            try std.testing.expectEqual(tensor.InnerType.f64, unknown.tensor_inner.?);
            const shape = unknown.shape orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualSlices(u32, left_shape[0..], shape);
            try std.testing.expect(@intFromPtr(shape.ptr) != @intFromPtr(left_shape[0..].ptr));
        },
        else => return error.TestUnexpectedResult,
    }

    const different: Slot = .{ .unknown = .{
        .identity = 4,
        .typ = b.type_tensor,
        .tensor_inner = .f64,
        .shape = other_shape[0..],
    } };
    const widened = try join(arena.allocator(), ctx, left, different, 5);
    switch (widened) {
        .unknown => |unknown| {
            try std.testing.expectEqual(tensor.InnerType.f64, unknown.tensor_inner.?);
            try std.testing.expectEqual(@as(?[]const u32, null), unknown.shape);
        },
        else => return error.TestUnexpectedResult,
    }

    const mutable_alias = skript.Value.init(b.type_map, @fromBackingInt(@intCast(1)));
    const alias_join = try join(arena.allocator(), ctx, .{
        .known = mutable_alias,
    }, .{
        .known = mutable_alias,
    }, 6);
    switch (alias_join) {
        .unknown => {},
        else => return error.TestUnexpectedResult,
    }
}
