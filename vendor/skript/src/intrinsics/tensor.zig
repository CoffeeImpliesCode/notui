const std = @import("std");

const skript = @import("../root.zig");
const Value = skript.Value;
const Sym = skript.Sym;
const Error = skript.Error;
const Runtime = skript.Runtime;
const EvalContext = skript.EvalContext;

const intrin = @import("root.zig");
fn chargeWork(ctx: *EvalContext, count: usize) Error!void {
    const count_u64 = std.math.cast(u64, count) orelse return error.Unsupported;
    try ctx.chargeWork(count_u64, 1, .native);
}

fn chargeWorkProduct(ctx: *EvalContext, count: usize, cost: usize) Error!void {
    const count_u64 = std.math.cast(u64, count) orelse return error.Unsupported;
    const cost_u64 = std.math.cast(u64, cost) orelse return error.Unsupported;
    try ctx.chargeWork(count_u64, cost_u64, .native);
}

fn checkedMul(a: usize, b: usize) Error!usize {
    return std.math.mul(usize, a, b) catch return error.Unsupported;
}

fn checkedAdd(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch return error.Unsupported;
}

/// The homogeneous inner type of a tensor's elements (v1: no promotion).
pub const InnerType = enum(u8) {
    i64,
    f64,
    string,
    symbol,
    keyword,
    /// `(stack)` with no arguments: no elements yet, so no inner type.
    /// v1 has no growth operation, so this tag is only observable on empty
    /// tensors (via tensor-shape/tensor-rank/tensor-len and printing).
    empty,
};

/// Store-backed tensor storage. rank is always >= 1 in v1.
pub const TensorHolder = struct {
    inner: InnerType,
    rank: u32,
    /// Dimension lengths, leading axis first.
    shape: []u32,
    /// Flat COLUMN-WISE element words. The LAST axis varies fastest.
    data: []u64,
    /// Typed Store owners. Views may share these references.
    shape_ref: skript.Store.Ref = .nil,
    data_ref: skript.Store.Ref = .nil,
};

pub fn traceTensorHolder(
    data: *const anyopaque,
    extent: usize,
    visitor: *skript.Store.MarkVisitor,
) anyerror!void {
    if (extent != 1) return error.InvalidRef;
    const holder: *const TensorHolder = @ptrCast(@alignCast(data));
    try visitor.visit(holder.shape_ref);
    try visitor.visit(holder.data_ref);
    if (holder.shape.len > 0) {
        try visitor.visitSpan(
            @intFromPtr(holder.shape.ptr),
            std.math.mul(usize, holder.shape.len, @sizeOf(u32)) catch return error.InvalidRef,
        );
    }
    if (holder.data.len == 0) return;
    try visitor.visitSpan(
        @intFromPtr(holder.data.ptr),
        std.math.mul(usize, holder.data.len, @sizeOf(u64)) catch return error.InvalidRef,
    );
    if (holder.inner == .string or holder.inner == .symbol or holder.inner == .keyword) {
        for (holder.data) |word| try visitor.visitValue(wordToValue(holder.inner, word));
    }
}

/// Create a tensor. `(stack elem...)`:
///   - no args: empty rank-1 tensor (inner .empty)
///   - all scalars of one inner type: rank-1 tensor
///   - all tensors of equal shape and inner type: stacked along a NEW leading
///     axis (rank+1; equal shapes make the result rectangular by construction)
/// Mixed inner types, mixed scalars/tensors, and unequal shapes are errors.
pub fn create(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    if (args.len == 0) {
        const shape = try rt.store.allocSlice(u32, 1);
        errdefer rt.store.discardUnpublished(shape.ref) catch unreachable;
        shape.slice[0] = 0;
        return makeTensor(rt, .empty, shape.slice, &.{}, shape.ref, .nil);
    }

    try chargeWork(ctx, args.len);
    var all_tensors = true;
    for (args) |arg| {
        if (arg.typ != skript.builtins.type_tensor) {
            all_tensors = false;
            break;
        }
    }
    if (all_tensors) return stackTensors(ctx, args);

    // Scalars: all must share one inner type (a tensor arg here is a
    // scalar/tensor mix and lands in the else branch -> TypeMismatch).
    try chargeWork(ctx, args.len);
    var inner: InnerType = .empty;
    const data = try rt.store.allocSlice(u64, args.len);
    errdefer rt.store.discardUnpublished(data.ref) catch unreachable;
    for (args, 0..) |arg, i| {
        // SAFETY: scalarWord initializes the output type before it is read below.
        var arg_inner: InnerType = undefined;
        data.slice[i] = try scalarWord(arg, &arg_inner);
        if (i == 0) {
            inner = arg_inner;
        } else if (arg_inner != inner) {
            return error.TypeMismatch;
        }
    }
    const shape = try rt.store.allocSlice(u32, 1);
    errdefer rt.store.discardUnpublished(shape.ref) catch unreachable;
    shape.slice[0] = std.math.cast(u32, args.len) orelse return error.Unsupported;
    return makeTensor(rt, inner, shape.slice, data.slice, shape.ref, data.ref);
}

/// Stack equal-shaped tensors along a new leading axis.
fn stackTensors(ctx: *EvalContext, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    const first = args[0].obj.toRef().deref(TensorHolder).*;
    const inner = first.inner;
    const sub_shape = first.shape;
    try chargeWork(ctx, args.len);
    for (args[1..]) |arg| {
        const h = arg.obj.toRef().deref(TensorHolder).*;
        if (h.inner != inner) return error.TypeMismatch;
        if (h.rank != first.rank) return error.ArityMismatch;
        try chargeWork(ctx, h.shape.len);
        if (!std.mem.eql(u32, h.shape, sub_shape)) return error.ArityMismatch;
    }

    const rank = std.math.add(u32, first.rank, 1) catch return error.Unsupported;
    const shape = try rt.store.allocSlice(u32, std.math.cast(usize, rank) orelse return error.Unsupported);
    errdefer rt.store.discardUnpublished(shape.ref) catch unreachable;
    shape.slice[0] = std.math.cast(u32, args.len) orelse return error.Unsupported;
    if (sub_shape.len > 0) @memcpy(shape.slice[1..], sub_shape);

    var words_per: usize = 1;
    for (sub_shape) |dimension| {
        words_per = try checkedMul(words_per, std.math.cast(usize, dimension) orelse return error.Unsupported);
    }
    const total = try checkedMul(words_per, args.len);
    try chargeWork(ctx, total);
    const data = try rt.store.allocSlice(u64, total);
    errdefer rt.store.discardUnpublished(data.ref) catch unreachable;
    // Column-wise stacking: each sub-tensor's words land contiguously in
    // argument order.
    for (args, 0..) |arg, index| {
        const h = arg.obj.toRef().deref(TensorHolder).*;
        const offset = try checkedMul(index, words_per);
        const end = try checkedAdd(offset, words_per);
        @memcpy(data.slice[offset..end], h.data);
    }
    return makeTensor(rt, inner, shape.slice, data.slice, shape.ref, data.ref);
}

fn makeTensor(
    rt: *Runtime,
    inner: InnerType,
    shape: []u32,
    data: []u64,
    shape_ref: skript.Store.Ref,
    data_ref: skript.Store.Ref,
) Error!Value {
    const ref = try rt.store.createTraced(TensorHolder, traceTensorHolder);
    const ptr = ref.deref(TensorHolder);
    ptr.* = .{
        .inner = inner,
        .rank = @intCast(shape.len),
        .shape = shape,
        .data = data,
        .shape_ref = shape_ref,
        .data_ref = data_ref,
    };
    return .init(skript.builtins.type_tensor, ref.toObject());
}

/// The result has not escaped; only callers that allocated both buffers own it.
fn discardUnpublishedTensor(rt: *Runtime, value: Value) void {
    const ref = value.obj.toRef();
    const holder = ref.deref(TensorHolder);
    if (!holder.data_ref.isNull() and holder.data_ref != holder.shape_ref) {
        rt.store.discardUnpublished(holder.data_ref) catch unreachable;
    }
    if (!holder.shape_ref.isNull()) rt.store.discardUnpublished(holder.shape_ref) catch unreachable;
    rt.store.discardUnpublished(ref) catch unreachable;
}
/// Extract a scalar element's storage word. Any non-element type is an error.
fn scalarWord(v: Value, inner: *InnerType) Error!u64 {
    return switch (v.typ) {
        skript.builtins.type_i64 => blk: {
            inner.* = .i64;
            break :blk @bitCast(v.obj.toInt(i64));
        },
        skript.builtins.type_f64 => blk: {
            inner.* = .f64;
            break :blk @bitCast(v.obj.tof64());
        },
        skript.builtins.type_string => blk: {
            inner.* = .string;
            break :blk @intFromPtr(v.obj.toPtr([*]u8));
        },
        skript.builtins.type_symbol => blk: {
            inner.* = .symbol;
            break :blk @intFromPtr(v.obj.toPtr(Sym));
        },
        skript.builtins.type_keyword => blk: {
            inner.* = .keyword;
            break :blk @intFromPtr(v.obj.toPtr(Sym));
        },
        else => error.TypeMismatch,
    };
}

/// Reconstruct the element Value from a stored word. Never called on .empty
/// tensors (they hold no elements and tensor-get bounds-checks first).
/// Public: the printer reuses it to format elements type-aware.
pub fn wordToValue(inner: InnerType, word: u64) Value {
    return switch (inner) {
        .i64 => .i64(@bitCast(word)),
        .f64 => .f64(@bitCast(word)),
        .string => .string(.fromPtr(@as([*]u8, @ptrFromInt(@as(usize, @intCast(word)))))),
        .symbol => .symbol(@ptrFromInt(@as(usize, @intCast(word)))),
        .keyword => .keyword(@ptrFromInt(@as(usize, @intCast(word)))),
        .empty => unreachable,
    };
}

/// `(tensor-shape t)` — dimension lengths as a cons list of i64, leading
/// axis first.
pub fn tensorShape(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_tensor);
    const h = args[0].obj.toRef().deref(TensorHolder).*;
    try chargeWork(ctx, h.shape.len);
    var list = Value.nil;
    var index = h.shape.len;
    while (index > 0) {
        index -= 1;
        const ref = try rt.store.create([2]Value);
        ref.deref([2]Value).* = .{
            .i64(std.math.cast(i64, h.shape[index]) orelse return error.Unsupported),
            list,
        };
        list = .cons(ref.toObject());
    }
    return list;
}

/// `(tensor-rank t)` — number of axes.
pub fn tensorRank(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_tensor);
    const h = args[0].obj.toRef().deref(TensorHolder).*;
    return .i64(@intCast(h.rank));
}

/// `(tensor-len t)` — length of the leading axis.
pub fn tensorLen(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_tensor);
    const h = args[0].obj.toRef().deref(TensorHolder).*;
    return .i64(@intCast(h.shape[0]));
}

/// `(tensor-get t i0 [i1 ...])` — one index per axis, bounds-checked.
/// Returns the element as the appropriate Value. Out-of-bounds indices and
/// wrong arity are errors: error.Unsupported for bounds (the Error enum has
/// no OutOfBounds variant), error.ArityMismatch for index-count mismatch.
pub fn tensorGet(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    if (args.len < 2) return error.ArityMismatch;
    try intrin.typeAssert(args[0], skript.builtins.type_tensor);
    const h = args[0].obj.toRef().deref(TensorHolder).*;
    if (args.len - 1 != h.rank) return error.ArityMismatch;
    try chargeWork(ctx, h.rank);

    // Column-wise: the LAST axis varies fastest (stride_k = product of the
    // FOLLOWING shapes), so accumulate the flat index walking the axes in
    // REVERSE — the trailing stride starts at 1 and multiplies backward.
    var index: usize = 0;
    var stride: usize = 1;
    var axis = h.rank;
    while (axis > 0) {
        axis -= 1;
        const argument = args[axis + 1];
        if (argument.typ != skript.builtins.type_i64) return error.TypeMismatch;
        const coordinate = argument.obj.toInt(i64);
        const dimension = std.math.cast(i64, h.shape[axis]) orelse return error.Unsupported;
        if (coordinate < 0 or coordinate >= dimension) return error.Unsupported;
        const coordinate_index = std.math.cast(usize, coordinate) orelse return error.Unsupported;
        index = try checkedAdd(index, try checkedMul(coordinate_index, stride));
        stride = try checkedMul(stride, std.math.cast(usize, h.shape[axis]) orelse return error.Unsupported);
    }
    if (index >= h.data.len) return error.Unsupported;
    return wordToValue(h.inner, h.data[index]);
}

/// `(tensor.eq a b)` — structural equality: same rank and shape, same inner
/// type, element-wise equal (i64 bit-equal, f64 numeric, strings by content,
/// symbols/keywords by identity — they are interned).
pub fn tensorEq(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    try intrin.typeAssert(args[0], skript.builtins.type_tensor);
    try intrin.typeAssert(args[1], skript.builtins.type_tensor);
    const a = args[0].obj.toRef().deref(TensorHolder).*;
    const b = args[1].obj.toRef().deref(TensorHolder).*;
    if (a.inner != b.inner or a.rank != b.rank) return .false;
    try chargeWork(ctx, a.shape.len);
    if (!std.mem.eql(u32, a.shape, b.shape)) return .false;
    if (a.data.len != b.data.len) return .false;
    try chargeWork(ctx, a.data.len);
    for (a.data, b.data) |word_a, word_b| {
        if (!(try wordsEqual(ctx, a.inner, word_a, word_b))) return .false;
    }
    return .true;
}

/// `(iota n)` — rank-1 i64 tensor `[0 1 … n-1]` (AlgoId 8, canonical
/// `iota`; APL `⍳`, J `i.`). n < 0 => error.Unsupported; n = 0 => empty
/// rank-1. The N-D index-space form needs the Value inner-type fallback
/// (docs/tensors.md §5) and is deferred.
pub fn iota(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_i64);
    const n = args[0].obj.toInt(i64);
    if (n < 0) return error.Unsupported;
    const count = std.math.cast(usize, n) orelse return error.Unsupported;
    const dimension = std.math.cast(u32, n) orelse return error.Unsupported;
    try chargeWork(ctx, count);
    const data = try rt.store.allocSlice(u64, count);
    errdefer rt.store.discardUnpublished(data.ref) catch unreachable;
    for (0..count) |index| data.slice[index] = @bitCast(@as(i64, @intCast(index)));
    const shape = try rt.store.allocSlice(u32, 1);
    errdefer rt.store.discardUnpublished(shape.ref) catch unreachable;
    shape.slice[0] = dimension;
    return makeTensor(rt, .i64, shape.slice, data.slice, shape.ref, data.ref);
}

/// `(reshape t shape)` — restructure `t` to the given dims (collection-first
/// per DATA_ORDER.md). The flat column-wise data is reused (O(1), immutable
/// so sharing is safe); the element count must match exactly, else
/// error.ArityMismatch. `shape` is a rank-1 i64 tensor (`[2 2]`) or a cons
/// list of i64 dims (`(2 2)`).
pub fn reshape(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    try intrin.arityAssert(args, 2);
    try intrin.typeAssert(args[0], skript.builtins.type_tensor);
    const h = args[0].obj.toRef().deref(TensorHolder).*;

    var dims: std.ArrayList(u32) = .empty;
    defer dims.deinit(rt.store.allocator());
    if (args[1].typ == skript.builtins.type_tensor) {
        // Rank-1 i64 tensor shape: dims come straight from its words.
        const sh = args[1].obj.toRef().deref(TensorHolder).*;
        if (sh.rank != 1 or sh.inner != .i64) return error.TypeMismatch;
        try chargeWork(ctx, sh.data.len);
        for (sh.data) |word| {
            const dimension: i64 = @bitCast(word);
            if (dimension < 0) return error.Unsupported;
            const dimension_u32 = std.math.cast(u32, dimension) orelse return error.Unsupported;
            try dims.append(rt.store.allocator(), dimension_u32);
        }
    } else {
        var rest = args[1];
        while (rest.typ == skript.builtins.type_cons) {
            try chargeWork(ctx, 1);
            const cell = rest.obj.toRef().deref([2]Value);
            if (cell[0].typ != skript.builtins.type_i64) return error.TypeMismatch;
            const dimension = cell[0].obj.toInt(i64);
            if (dimension < 0) return error.Unsupported;
            const dimension_u32 = std.math.cast(u32, dimension) orelse return error.Unsupported;
            try dims.append(rt.store.allocator(), dimension_u32);
            rest = cell[1];
        }
        if (rest.typ != skript.builtins.type_nil) return error.TypeMismatch;
    }
    if (dims.items.len == 0) return error.ArityMismatch; // rank-0 not expressible in v1

    var total: usize = 1;
    for (dims.items) |dimension| {
        total = try checkedMul(total, std.math.cast(usize, dimension) orelse return error.Unsupported);
    }
    if (total != h.data.len) return error.ArityMismatch;

    const shape = try rt.store.allocSlice(u32, dims.items.len);
    errdefer rt.store.discardUnpublished(shape.ref) catch unreachable;
    @memcpy(shape.slice, dims.items);
    return makeTensor(rt, h.inner, shape.slice, h.data, shape.ref, h.data_ref);
}

fn wordsEqual(ctx: *EvalContext, inner: InnerType, a: u64, b: u64) Error!bool {
    return switch (inner) {
        .i64 => @as(i64, @bitCast(a)) == @as(i64, @bitCast(b)),
        .f64 => @as(f64, @bitCast(a)) == @as(f64, @bitCast(b)),
        .string => blk: {
            const a_bytes = try stringWordBytes(ctx, a);
            const b_bytes = try stringWordBytes(ctx, b);
            try chargeWork(ctx, @max(a_bytes.len, b_bytes.len));
            break :blk std.mem.eql(u8, a_bytes, b_bytes);
        },
        .symbol, .keyword => a == b,
        .empty => true, // no elements to compare
    };
}

fn stringWordBytes(ctx: *const EvalContext, word: u64) Error![:0]const u8 {
    return ctx.stringBytes(
        @as([*:0]const u8, @ptrFromInt(@as(usize, @intCast(word)))),
        std.math.maxInt(usize),
        .native,
    );
}

// --- proto operations (docs/tensors.md §3) ---
//
// Collection-first per DATA_ORDER.md; the axis-specifier form is
// `(op t k …)` with a 0-based axis, negative counts from the end. All
// results are freshly allocated; the input is immutable.

/// Resolve an axis index against a rank: negative counts from the end
/// (-1 = last axis). Out-of-range is error.Unsupported.
fn resolveAxis(rank: usize, k: i64) Error!usize {
    const r = if (k < 0) @as(i64, @intCast(rank)) + k else k;
    if (r < 0 or r >= @as(i64, @intCast(rank))) return error.Unsupported;
    return @intCast(r);
}

/// Column-wise stride of axis k: product of the FOLLOWING shapes (the
/// last axis varies fastest, stride_{rank-1} = 1).
fn axisStride(shape: []const u32, k: usize) Error!usize {
    var stride: usize = 1;
    var axis = shape.len;
    while (axis > k + 1) {
        axis -= 1;
        stride = try checkedMul(stride, std.math.cast(usize, shape[axis]) orelse return error.Unsupported);
    }
    return stride;
}

/// Flat base offsets of every cell (sub-block) when axis k is removed,
/// iterated in column-wise order of the collapsed space. `out.len` must
/// equal the product of the shapes except k.
fn fillCellBases(shape: []const u32, k: usize, out: []usize) Error!void {
    const rank = shape.len;
    if (rank <= 1) {
        if (out.len > 0) out[0] = 0;
        return;
    }
    const count = out.len;
    if (count == 0) return;
    // Column-wise order: the LAST collapsed axis is the low-order digit
    // (the result's flat order). Decompose c by walking the original axes
    // from the end (skipping k), then sum the new strides.
    var index: [max_rank]usize = undefined;
    @memset(index[0..rank], 0);
    for (0..count) |cell| {
        var base: usize = 0;
        var remainder = cell;
        var axis = rank;
        while (axis > 0) {
            axis -= 1;
            if (axis == k) continue;
            const dimension = std.math.cast(usize, shape[axis]) orelse return error.Unsupported;
            if (dimension == 0) return error.Unsupported;
            index[axis] = remainder % dimension;
            remainder /= dimension;
        }
        for (0..rank) |other_axis| {
            if (other_axis == k) continue;
            const stride = try axisStride(shape, other_axis);
            base = try checkedAdd(base, try checkedMul(index[other_axis], stride));
        }
        out[cell] = base;
    }
}

const max_rank = 8;

/// Split `(op t fn)` / `(op t k fn)` into axis + fn (fn is the last arg).
fn axisFn(args: []const Value) Error!struct { k: usize, func: Value } {
    if (args.len != 2 and args.len != 3) return error.ArityMismatch;
    try intrin.typeAssert(args[0], skript.builtins.type_tensor);
    const h = args[0].obj.toRef().deref(TensorHolder).*;
    if (args.len == 2) return .{ .k = 0, .func = args[1] };
    try intrin.typeAssert(args[1], skript.builtins.type_i64);
    return .{ .k = try resolveAxis(h.rank, args[1].obj.toInt(i64)), .func = args[2] };
}

/// `(fold t fn)` / `(fold t k fn)` — fold fn over axis k (AlgoId 1).
/// Rank-1 collapses to a scalar atom; a rank-r result drops axis k. An
/// empty axis is error.Unsupported (no identity element in v1). The
/// accumulator is a Value, so promotion (i64 -> f64 via `+`) works.
pub fn fold(ctx: *EvalContext, ns: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    const af = try axisFn(args);
    const h = args[0].obj.toRef().deref(TensorHolder).*;
    if (h.rank > max_rank) return error.Unsupported;
    const len = std.math.cast(usize, h.shape[af.k]) orelse return error.Unsupported;
    if (len == 0) return error.Unsupported;
    const stride = try axisStride(h.shape, af.k);
    const cell_count = try cellCount(h.shape, af.k);
    const fill_cost = try checkedMul(h.shape.len, h.shape.len);
    try chargeWorkProduct(ctx, cell_count, fill_cost);
    try chargeWorkProduct(ctx, cell_count, len);
    const cells = try rt.store.allocator().alloc(usize, cell_count);
    defer rt.store.allocator().free(cells);
    try fillCellBases(h.shape, af.k, cells);
    var workspace = Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();

    if (h.rank == 1) {
        var accumulator = wordToValue(h.inner, h.data[0]);
        for (1..len) |index| {
            const offset = try checkedMul(index, stride);
            accumulator = try rt.applyWithWorkspace(ctx, ns, af.func, &.{
                accumulator,
                wordToValue(h.inner, h.data[offset]),
            }, &workspace);
        }
        return accumulator;
    }

    const new_shape = try shapeWithout(rt, h.shape, af.k);
    errdefer rt.store.discardUnpublished(new_shape.ref) catch unreachable;
    const data = try rt.store.allocSlice(u64, cells.len);
    errdefer rt.store.discardUnpublished(data.ref) catch unreachable;
    var inner: InnerType = .empty;
    for (cells, 0..) |base, cell| {
        var accumulator = wordToValue(h.inner, h.data[base]);
        for (1..len) |index| {
            const offset = try checkedAdd(base, try checkedMul(index, stride));
            accumulator = try rt.applyWithWorkspace(ctx, ns, af.func, &.{
                accumulator,
                wordToValue(h.inner, h.data[offset]),
            }, &workspace);
        }
        // SAFETY: scalarWord initializes the output type before it is read below.
        var cell_inner: InnerType = undefined;
        data.slice[cell] = try scalarWord(accumulator, &cell_inner);
        if (cell == 0) inner = cell_inner else if (cell_inner != inner) return error.TypeMismatch;
    }
    return makeTensor(rt, inner, new_shape.slice, data.slice, new_shape.ref, data.ref);
}

fn cellCount(shape: []const u32, k: usize) Error!usize {
    var count: usize = 1;
    for (shape, 0..) |dimension, axis| {
        if (axis != k) {
            count = try checkedMul(count, std.math.cast(usize, dimension) orelse return error.Unsupported);
        }
    }
    return count;
}

fn shapeWithout(rt: *Runtime, shape: []const u32, k: usize) Error!skript.Store.TypedSlice(u32) {
    const out = try rt.store.allocSlice(u32, shape.len - 1);
    var q: usize = 0;
    for (shape, 0..) |d, a| if (a != k) {
        out.slice[q] = d;
        q += 1;
    };
    return out;
}

/// `(scan t fn)` / `(scan t k fn)` — inclusive prefix fold along axis k
/// (AlgoId 4). Result shape = input shape.
pub fn scan(ctx: *EvalContext, ns: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    const af = try axisFn(args);
    const h = args[0].obj.toRef().deref(TensorHolder).*;
    if (h.rank > max_rank) return error.Unsupported;
    const len = std.math.cast(usize, h.shape[af.k]) orelse return error.Unsupported;
    const stride = try axisStride(h.shape, af.k);
    const cell_count = try cellCount(h.shape, af.k);
    try chargeWorkProduct(ctx, cell_count, len);
    if (h.rank > 1) {
        const fill_cost = try checkedMul(h.shape.len, h.shape.len);
        try chargeWorkProduct(ctx, cell_count, fill_cost);
    }
    const data = try rt.store.allocSlice(u64, h.data.len);
    errdefer rt.store.discardUnpublished(data.ref) catch unreachable;
    if (h.data.len == 0) return makeTensor(rt, .empty, h.shape, data.slice, h.shape_ref, data.ref);
    const cells = try rt.store.allocator().alloc(usize, cell_count);
    defer rt.store.allocator().free(cells);
    try fillCellBases(h.shape, af.k, cells);
    var workspace = Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    var inner: InnerType = .empty;
    for (cells) |base| {
        var accumulator = wordToValue(h.inner, h.data[base]);
        var first = true;
        for (0..len) |index| {
            const offset = try checkedMul(index, stride);
            const data_index = try checkedAdd(base, offset);
            if (!first) {
                accumulator = try rt.applyWithWorkspace(ctx, ns, af.func, &.{
                    accumulator,
                    wordToValue(h.inner, h.data[data_index]),
                }, &workspace);
            }
            first = false;
            // SAFETY: scalarWord initializes the output type before the first read.
            var cell_inner: InnerType = undefined;
            data.slice[data_index] = try scalarWord(accumulator, &cell_inner);
            if (inner == .empty) inner = cell_inner else if (cell_inner != inner) return error.TypeMismatch;
        }
    }
    return makeTensor(rt, inner, h.shape, data.slice, h.shape_ref, data.ref);
}

/// `(map t fn)` / `(map t k fn)` — apply fn to each element along axis k
/// (AlgoId 2). Result shape = input shape. Reached via `map`'s
/// collection-first dispatch (src/intrinsics/map.zig).
pub fn map(ctx: *EvalContext, ns: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    const af = try axisFn(args);
    const h = args[0].obj.toRef().deref(TensorHolder).*;
    if (h.rank > max_rank) return error.Unsupported;
    const len = std.math.cast(usize, h.shape[af.k]) orelse return error.Unsupported;
    const stride = try axisStride(h.shape, af.k);
    const cell_count = try cellCount(h.shape, af.k);
    try chargeWorkProduct(ctx, cell_count, len);
    if (h.rank > 1) {
        const fill_cost = try checkedMul(h.shape.len, h.shape.len);
        try chargeWorkProduct(ctx, cell_count, fill_cost);
    }
    const data = try rt.store.allocSlice(u64, h.data.len);
    errdefer rt.store.discardUnpublished(data.ref) catch unreachable;
    if (h.data.len == 0) return makeTensor(rt, .empty, h.shape, data.slice, h.shape_ref, data.ref);
    const cells = try rt.store.allocator().alloc(usize, cell_count);
    defer rt.store.allocator().free(cells);
    try fillCellBases(h.shape, af.k, cells);
    var workspace = Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    var inner: InnerType = .empty;
    for (cells) |base| {
        for (0..len) |index| {
            const data_index = try checkedAdd(base, try checkedMul(index, stride));
            const result = try rt.applyWithWorkspace(ctx, ns, af.func, &.{
                wordToValue(h.inner, h.data[data_index]),
            }, &workspace);
            // SAFETY: scalarWord initializes the output type before the first read.
            var cell_inner: InnerType = undefined;
            data.slice[data_index] = try scalarWord(result, &cell_inner);
            if (inner == .empty) inner = cell_inner else if (cell_inner != inner) return error.TypeMismatch;
        }
    }
    return makeTensor(rt, inner, h.shape, data.slice, h.shape_ref, data.ref);
}

/// The leading-axis element j as a Value: a scalar for rank-1, a
/// sub-tensor (copy of the strided words) for rank > 1.
fn majorCell(ctx: *EvalContext, h: TensorHolder, j: usize) Error!Value {
    const rt = ctx.runtime;
    if (h.rank == 1) return wordToValue(h.inner, h.data[j]);
    const len = h.shape[0];
    const words_per = h.data.len / len;
    try chargeWork(ctx, words_per);
    const data = try rt.store.allocSlice(u64, words_per);
    errdefer rt.store.discardUnpublished(data.ref) catch unreachable;
    // Column-wise: the leading cell j is a contiguous run [j*w, (j+1)*w).
    const start = try checkedMul(j, words_per);
    const end = try checkedAdd(start, words_per);
    @memcpy(data.slice, h.data[start..end]);
    const shape = try rt.store.allocSlice(u32, h.rank - 1);
    errdefer rt.store.discardUnpublished(shape.ref) catch unreachable;
    @memcpy(shape.slice, h.shape[1..]);
    return makeTensor(rt, h.inner, shape.slice, data.slice, shape.ref, data.ref);
}

/// `(keep t pred)` — keep leading-axis cells for which pred is true
/// (AlgoId 3). Rank >= 1. The result keeps the remaining axes.
pub fn keep(ctx: *EvalContext, ns: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    try intrin.arityAssert(args, 2);
    try intrin.typeAssert(args[0], skript.builtins.type_tensor);
    const h = args[0].obj.toRef().deref(TensorHolder).*;
    const len = std.math.cast(usize, h.shape[0]) orelse return error.Unsupported;
    const words_per = if (len > 0) h.data.len / len else 0;

    // Pass 1: which leading cells survive.
    try chargeWork(ctx, len);
    const keep_mask = try rt.store.allocator().alloc(bool, len);
    defer rt.store.allocator().free(keep_mask);
    var nkeep: usize = 0;
    var workspace = Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    for (0..len) |index| {
        const result = try rt.applyWithWorkspace(ctx, ns, args[1], &.{try majorCell(ctx, h, index)}, &workspace);
        if (result.typ != skript.builtins.type_bool) return error.TypeMismatch;
        keep_mask[index] = result.obj.toBool();
        if (keep_mask[index]) nkeep = try checkedAdd(nkeep, 1);
    }

    // Pass 2: rebuild. Leading cells pack contiguously in column-wise order.
    const shape = try rt.store.allocSlice(u32, h.rank);
    errdefer rt.store.discardUnpublished(shape.ref) catch unreachable;
    shape.slice[0] = std.math.cast(u32, nkeep) orelse return error.Unsupported;
    if (h.rank > 1) @memcpy(shape.slice[1..], h.shape[1..]);
    const output_len = try checkedMul(nkeep, words_per);
    try chargeWork(ctx, output_len);
    const data = try rt.store.allocSlice(u64, output_len);
    errdefer rt.store.discardUnpublished(data.ref) catch unreachable;
    var output_index: usize = 0;
    for (0..len) |index| {
        if (!keep_mask[index]) continue;
        const output_start = try checkedMul(output_index, words_per);
        const output_end = try checkedAdd(output_start, words_per);
        const input_start = try checkedMul(index, words_per);
        const input_end = try checkedAdd(input_start, words_per);
        @memcpy(data.slice[output_start..output_end], h.data[input_start..input_end]);
        output_index = try checkedAdd(output_index, 1);
    }
    return makeTensor(rt, h.inner, shape.slice, data.slice, shape.ref, data.ref);
}

/// `(uniq t)` — remove ADJACENT duplicates of leading-axis cells (AlgoId 14,
/// POSIX `uniq`). Whole cells compare word-by-word.
pub fn uniq(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_tensor);
    const h = args[0].obj.toRef().deref(TensorHolder).*;
    const len = std.math.cast(usize, h.shape[0]) orelse return error.Unsupported;
    if (len == 0) return args[0];
    const words_per = h.data.len / len;
    try chargeWorkProduct(ctx, len - 1, words_per);

    var nkeep: usize = 1;
    for (1..len) |index| {
        var duplicate = true;
        const current_start = try checkedMul(index, words_per);
        const previous_start = try checkedMul(index - 1, words_per);
        for (0..words_per) |word| {
            const current_index = try checkedAdd(current_start, word);
            const previous_index = try checkedAdd(previous_start, word);
            if (!(try wordsEqual(ctx, h.inner, h.data[current_index], h.data[previous_index]))) {
                duplicate = false;
                break;
            }
        }
        if (!duplicate) nkeep = try checkedAdd(nkeep, 1);
    }

    const output_len = try checkedMul(nkeep, words_per);
    try chargeWorkProduct(ctx, len - 1, words_per);
    try chargeWork(ctx, len);
    try chargeWork(ctx, output_len);
    const shape = try rt.store.allocSlice(u32, h.rank);
    errdefer rt.store.discardUnpublished(shape.ref) catch unreachable;
    shape.slice[0] = std.math.cast(u32, nkeep) orelse return error.Unsupported;
    if (h.rank > 1) @memcpy(shape.slice[1..], h.shape[1..]);
    const data = try rt.store.allocSlice(u64, output_len);
    errdefer rt.store.discardUnpublished(data.ref) catch unreachable;
    var output_index: usize = 0;
    var previous_kept: usize = 0;
    for (0..len) |index| {
        if (index > 0) {
            var duplicate = true;
            const current_start = try checkedMul(index, words_per);
            const previous_start = try checkedMul(previous_kept, words_per);
            for (0..words_per) |word| {
                const current_index = try checkedAdd(current_start, word);
                const previous_index = try checkedAdd(previous_start, word);
                if (!(try wordsEqual(ctx, h.inner, h.data[current_index], h.data[previous_index]))) {
                    duplicate = false;
                    break;
                }
            }
            if (duplicate) continue;
        }
        const output_start = try checkedMul(output_index, words_per);
        const output_end = try checkedAdd(output_start, words_per);
        const input_start = try checkedMul(index, words_per);
        const input_end = try checkedAdd(input_start, words_per);
        @memcpy(data.slice[output_start..output_end], h.data[input_start..input_end]);
        previous_kept = index;
        output_index = try checkedAdd(output_index, 1);
    }
    return makeTensor(rt, h.inner, shape.slice, data.slice, shape.ref, data.ref);
}

/// `(where mask)` — indices of nonzero elements of a 1-D i64 mask
/// (AlgoId 18, APL `⍸`). Result: rank-1 i64.
pub fn where(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_tensor);
    const h = args[0].obj.toRef().deref(TensorHolder).*;
    if (h.rank != 1 or h.inner != .i64) return error.TypeMismatch;
    try chargeWorkProduct(ctx, h.data.len, 2);
    var count: usize = 0;
    for (h.data) |word| {
        if (@as(i64, @bitCast(word)) != 0) count = try checkedAdd(count, 1);
    }
    const data = try rt.store.allocSlice(u64, count);
    errdefer rt.store.discardUnpublished(data.ref) catch unreachable;
    const shape = try rt.store.allocSlice(u32, 1);
    errdefer rt.store.discardUnpublished(shape.ref) catch unreachable;
    shape.slice[0] = std.math.cast(u32, count) orelse return error.Unsupported;
    var output_index: usize = 0;
    for (h.data, 0..) |word, index| {
        if (@as(i64, @bitCast(word)) != 0) {
            const index_i64 = std.math.cast(i64, index) orelse return error.Unsupported;
            data.slice[output_index] = @bitCast(index_i64);
            output_index = try checkedAdd(output_index, 1);
        }
    }
    return makeTensor(rt, .i64, shape.slice, data.slice, shape.ref, data.ref);
}

/// Fill (in_base, out_base) pairs for the cells of `shape` with axis k
/// resized to new_len: in_base uses the input strides, out_base the output
/// strides (the lengths of axes after k change with shape[k]). Callers whose
/// output keeps the input shape must use the plain fillCellBases.
fn fillCellBases2(
    shape: []const u32,
    k: usize,
    new_len: usize,
    in_bases: []usize,
    out_bases: []usize,
) Error!void {
    const rank = shape.len;
    if (rank <= 1) {
        if (in_bases.len > 0) {
            in_bases[0] = 0;
            out_bases[0] = 0;
        }
        return;
    }
    const count = in_bases.len;
    if (count == 0) return;
    var input_stride: [max_rank]usize = undefined;
    var output_stride: [max_rank]usize = undefined;
    // Column-wise: stride_k = product of the FOLLOWING shapes (the last
    // axis varies fastest), for both the input and the resized output.
    var stride: usize = 1;
    var axis = rank;
    while (axis > 0) {
        axis -= 1;
        input_stride[axis] = stride;
        stride = try checkedMul(stride, std.math.cast(usize, shape[axis]) orelse return error.Unsupported);
    }
    stride = 1;
    axis = rank;
    while (axis > 0) {
        axis -= 1;
        output_stride[axis] = stride;
        const dimension = if (axis == k) new_len else std.math.cast(usize, shape[axis]) orelse return error.Unsupported;
        stride = try checkedMul(stride, dimension);
    }
    var index: [max_rank]usize = undefined;
    @memset(index[0..rank], 0);
    for (0..count) |cell| {
        var input_base: usize = 0;
        var output_base: usize = 0;
        var remainder = cell;
        axis = rank;
        while (axis > 0) {
            axis -= 1;
            if (axis == k) continue;
            const dimension = std.math.cast(usize, shape[axis]) orelse return error.Unsupported;
            if (dimension == 0) return error.Unsupported;
            index[axis] = remainder % dimension;
            remainder /= dimension;
        }
        for (0..rank) |other_axis| {
            if (other_axis == k) continue;
            input_base = try checkedAdd(
                input_base,
                try checkedMul(index[other_axis], input_stride[other_axis]),
            );
            output_base = try checkedAdd(
                output_base,
                try checkedMul(index[other_axis], output_stride[other_axis]),
            );
        }
        in_bases[cell] = input_base;
        out_bases[cell] = output_base;
    }
}

/// `(diff t)` / `(diff t k)` — adjacent difference along axis k (AlgoId 41):
/// result[i] = t[i+1] - t[i], length shrinks by 1. Numeric inner types only.
pub fn diff(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    if (args.len < 1 or args.len > 2) return error.ArityMismatch;
    try intrin.typeAssert(args[0], skript.builtins.type_tensor);
    const h = args[0].obj.toRef().deref(TensorHolder).*;
    const k = if (args.len == 2) blk: {
        try intrin.typeAssert(args[1], skript.builtins.type_i64);
        break :blk try resolveAxis(h.rank, args[1].obj.toInt(i64));
    } else 0;
    if (h.rank > max_rank) return error.Unsupported;
    if (h.inner != .i64 and h.inner != .f64) return error.Unsupported;
    const len = h.shape[k];
    if (len == 0) return makeTensor(rt, .empty, h.shape, h.data[0..0], h.shape_ref, .nil);
    const len_usize = std.math.cast(usize, len) orelse return error.Unsupported;
    const stride = try axisStride(h.shape, k);
    const new_len = len_usize - 1;
    const cell_count = try cellCount(h.shape, k);
    const fill_cost = try checkedMul(h.shape.len, h.shape.len);
    try chargeWorkProduct(ctx, cell_count, fill_cost);
    const output_len = try checkedMul(cell_count, new_len);
    try chargeWork(ctx, output_len);
    const cells = try rt.store.allocator().alloc(usize, cell_count);
    defer rt.store.allocator().free(cells);
    const out_bases = try rt.store.allocator().alloc(usize, cells.len);
    defer rt.store.allocator().free(out_bases);
    try fillCellBases2(h.shape, k, new_len, cells, out_bases);
    const shape = try rt.store.allocSlice(u32, h.rank);
    errdefer rt.store.discardUnpublished(shape.ref) catch unreachable;
    @memcpy(shape.slice, h.shape);
    shape.slice[k] = std.math.cast(u32, new_len) orelse return error.Unsupported;
    const data = try rt.store.allocSlice(u64, output_len);
    errdefer rt.store.discardUnpublished(data.ref) catch unreachable;
    for (cells, out_bases) |base, output_base| {
        for (0..new_len) |index| {
            const next_index = try checkedAdd(index, 1);
            const next_offset = try checkedMul(next_index, stride);
            const current_offset = try checkedMul(index, stride);
            const next = h.data[try checkedAdd(base, next_offset)];
            const current = h.data[try checkedAdd(base, current_offset)];
            const output_offset = try checkedMul(index, stride);
            data.slice[try checkedAdd(output_base, output_offset)] = wordSub(h.inner, next, current);
        }
    }
    return makeTensor(rt, h.inner, shape.slice, data.slice, shape.ref, data.ref);
}

/// i64/f64 word subtraction.
fn wordSub(inner: InnerType, a: u64, b: u64) u64 {
    return switch (inner) {
        .i64 => @bitCast(@as(i64, @bitCast(a)) - @as(i64, @bitCast(b))),
        .f64 => @bitCast(@as(f64, @bitCast(a)) - @as(f64, @bitCast(b))),
        else => unreachable,
    };
}

pub fn flat(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_tensor);
    const h = args[0].obj.toRef().deref(TensorHolder).*;
    const shape = try rt.store.allocSlice(u32, 1);
    errdefer rt.store.discardUnpublished(shape.ref) catch unreachable;
    shape.slice[0] = std.math.cast(u32, h.data.len) orelse return error.Unsupported;
    return makeTensor(rt, h.inner, shape.slice, h.data, shape.ref, h.data_ref);
}

/// `(trans t)` / `(trans t perm)` — rev the axis order, or
/// reorder by the permutation `perm` (rank-1 i64 tensor; perm[q] = old axis
/// feeding output axis q). AlgoId 22.
pub fn trans(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    if (args.len < 1 or args.len > 2) return error.ArityMismatch;
    try intrin.typeAssert(args[0], skript.builtins.type_tensor);
    const h = args[0].obj.toRef().deref(TensorHolder).*;
    const rank = std.math.cast(usize, h.rank) orelse return error.Unsupported;
    if (rank > max_rank) return error.Unsupported;
    try chargeWork(ctx, rank);

    var perm: [max_rank]usize = undefined;
    if (args.len == 2) {
        try intrin.typeAssert(args[1], skript.builtins.type_tensor);
        const p = args[1].obj.toRef().deref(TensorHolder).*;
        if (p.rank != 1 or p.inner != .i64 or p.shape[0] != h.rank) return error.TypeMismatch;
        var seen: [max_rank]bool = @splat(false);
        for (p.data, 0..) |word, output_axis| {
            const old_axis: i64 = @bitCast(word);
            const rank_i64 = std.math.cast(i64, rank) orelse return error.Unsupported;
            if (old_axis < 0 or old_axis >= rank_i64) return error.Unsupported;
            const old_axis_usize = std.math.cast(usize, old_axis) orelse return error.Unsupported;
            if (seen[old_axis_usize]) return error.Unsupported; // not a permutation
            seen[old_axis_usize] = true;
            perm[output_axis] = old_axis_usize;
        }
    } else {
        for (0..rank) |output_axis| perm[output_axis] = rank - 1 - output_axis;
    }

    const shape = try rt.store.allocSlice(u32, rank);
    errdefer rt.store.discardUnpublished(shape.ref) catch unreachable;
    var new_stride: [max_rank]usize = undefined;
    var stride: usize = 1;
    var output_axis = rank;
    while (output_axis > 0) {
        output_axis -= 1;
        shape.slice[output_axis] = h.shape[perm[output_axis]];
        new_stride[output_axis] = stride;
        stride = try checkedMul(stride, std.math.cast(usize, shape.slice[output_axis]) orelse return error.Unsupported);
    }
    var old_stride: [max_rank]usize = undefined;
    stride = 1;
    var old_axis = rank;
    while (old_axis > 0) {
        old_axis -= 1;
        old_stride[old_axis] = stride;
        stride = try checkedMul(stride, std.math.cast(usize, h.shape[old_axis]) orelse return error.Unsupported);
    }
    try chargeWorkProduct(ctx, h.data.len, rank);
    const data = try rt.store.allocSlice(u64, h.data.len);
    errdefer rt.store.discardUnpublished(data.ref) catch unreachable;
    var inverse: [max_rank]usize = undefined;
    for (0..rank) |q| inverse[perm[q]] = q;
    for (0..h.data.len) |flat_index| {
        var old_flat: usize = 0;
        for (0..rank) |axis| {
            const output_for_axis = inverse[axis];
            const dimension = std.math.cast(usize, shape.slice[output_for_axis]) orelse return error.Unsupported;
            const coordinate = flat_index / new_stride[output_for_axis] % dimension;
            old_flat = try checkedAdd(old_flat, try checkedMul(coordinate, old_stride[axis]));
        }
        data.slice[flat_index] = h.data[old_flat];
    }
    return makeTensor(rt, h.inner, shape.slice, data.slice, shape.ref, data.ref);
}

pub fn chunk(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    const rt = ctx.runtime;
    try intrin.typeAssert(args[0], skript.builtins.type_i64);
    try intrin.typeAssert(args[1], skript.builtins.type_tensor);
    const h = args[1].obj.toRef().deref(TensorHolder).*;
    const n = args[0].obj.toInt(i64);
    if (n <= 0) return error.Unsupported;
    const n_u32 = std.math.cast(u32, n) orelse return error.Unsupported;
    const len = h.shape[0];
    if (@rem(len, n_u32) != 0) return error.ArityMismatch;
    const groups = @divExact(len, n_u32);
    const rank = std.math.cast(usize, h.rank) orelse return error.Unsupported;
    const output_rank = try checkedAdd(rank, 1);
    if (output_rank > max_rank) return error.Unsupported;

    const shape = try rt.store.allocSlice(u32, output_rank);
    errdefer rt.store.discardUnpublished(shape.ref) catch unreachable;
    shape.slice[0] = groups;
    shape.slice[1] = n_u32;
    if (rank > 1) @memcpy(shape.slice[2..], h.shape[1..]);

    // Chunk reinterprets the flat column-wise data without a copy.
    return makeTensor(rt, h.inner, shape.slice, h.data, shape.ref, h.data_ref);
}

/// `(part t pred)` — split leading-axis elements by pred into a cons
/// of two tensors (passing, failing), each keeping the remaining axes
/// (AlgoId 10).
pub fn part(ctx: *EvalContext, ns: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    try intrin.arityAssert(args, 2);
    try intrin.typeAssert(args[0], skript.builtins.type_tensor);
    const h = args[0].obj.toRef().deref(TensorHolder).*;
    const len = std.math.cast(usize, h.shape[0]) orelse return error.Unsupported;
    const words_per = if (len > 0) h.data.len / len else 0;
    try chargeWork(ctx, len);
    const keep_mask = try rt.store.allocator().alloc(bool, len);
    defer rt.store.allocator().free(keep_mask);
    var nkeep: usize = 0;
    var workspace = Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    for (0..len) |index| {
        const result = try rt.applyWithWorkspace(ctx, ns, args[1], &.{try majorCell(ctx, h, index)}, &workspace);
        if (result.typ != skript.builtins.type_bool) return error.TypeMismatch;
        keep_mask[index] = result.obj.toBool();
        if (keep_mask[index]) nkeep = try checkedAdd(nkeep, 1);
    }
    const pass = blk: {
        const shape = try rt.store.allocSlice(u32, h.rank);
        errdefer rt.store.discardUnpublished(shape.ref) catch unreachable;
        shape.slice[0] = std.math.cast(u32, nkeep) orelse return error.Unsupported;
        if (h.rank > 1) @memcpy(shape.slice[1..], h.shape[1..]);
        const pass_len = try checkedMul(nkeep, words_per);
        try chargeWork(ctx, pass_len);
        const data = try rt.store.allocSlice(u64, pass_len);
        errdefer rt.store.discardUnpublished(data.ref) catch unreachable;
        var output_index: usize = 0;
        for (0..len) |index| {
            if (!keep_mask[index]) continue;
            const output_start = try checkedMul(output_index, words_per);
            const output_end = try checkedAdd(output_start, words_per);
            const input_start = try checkedMul(index, words_per);
            const input_end = try checkedAdd(input_start, words_per);
            @memcpy(data.slice[output_start..output_end], h.data[input_start..input_end]);
            output_index = try checkedAdd(output_index, 1);
        }
        break :blk try makeTensor(rt, h.inner, shape.slice, data.slice, shape.ref, data.ref);
    };
    errdefer discardUnpublishedTensor(rt, pass);

    const fail = blk: {
        const fail_count = len - nkeep;
        const shape = try rt.store.allocSlice(u32, h.rank);
        errdefer rt.store.discardUnpublished(shape.ref) catch unreachable;
        shape.slice[0] = std.math.cast(u32, fail_count) orelse return error.Unsupported;
        if (h.rank > 1) @memcpy(shape.slice[1..], h.shape[1..]);
        const fail_len = try checkedMul(fail_count, words_per);
        try chargeWork(ctx, fail_len);
        const data = try rt.store.allocSlice(u64, fail_len);
        errdefer rt.store.discardUnpublished(data.ref) catch unreachable;
        var output_index: usize = 0;
        for (0..len) |index| {
            if (keep_mask[index]) continue;
            const output_start = try checkedMul(output_index, words_per);
            const output_end = try checkedAdd(output_start, words_per);
            const input_start = try checkedMul(index, words_per);
            const input_end = try checkedAdd(input_start, words_per);
            @memcpy(data.slice[output_start..output_end], h.data[input_start..input_end]);
            output_index = try checkedAdd(output_index, 1);
        }
        break :blk try makeTensor(rt, h.inner, shape.slice, data.slice, shape.ref, data.ref);
    };
    errdefer discardUnpublishedTensor(rt, fail);

    const ref = try rt.store.create([2]Value);
    ref.deref([2]Value).* = .{ pass, fail };
    return .cons(ref.toObject());
}

/// `(take n t [k])` — keep the first n elements of axis k (AlgoId 35);
/// negative n keeps the last |n|; beyond length clips.
pub fn take(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    return sliceAxis(ctx, args, false);
}

/// `(drop n t [k])` — remove the first n elements of axis k (AlgoId 34);
/// negative n drops the last |n|. Dual of take.
pub fn drop(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    return sliceAxis(ctx, args, true);
}

/// Shared take/drop kernel: `(op n t [k])`. `is_drop` selects the
/// complementary range.
fn sliceAxis(ctx: *EvalContext, args: []const Value, is_drop: bool) Error!Value {
    const rt = ctx.runtime;
    if (args.len < 2 or args.len > 3) return error.ArityMismatch;
    try intrin.typeAssert(args[0], skript.builtins.type_i64);
    try intrin.typeAssert(args[1], skript.builtins.type_tensor);
    const h = args[1].obj.toRef().deref(TensorHolder).*;
    const n = args[0].obj.toInt(i64);
    const k = if (args.len == 3) blk: {
        try intrin.typeAssert(args[2], skript.builtins.type_i64);
        break :blk try resolveAxis(h.rank, args[2].obj.toInt(i64));
    } else 0;
    if (h.rank > max_rank) return error.Unsupported;
    const len = std.math.cast(usize, h.shape[k]) orelse return error.Unsupported;
    const len_i64 = std.math.cast(i64, len) orelse return error.Unsupported;
    var start: i64 = 0;
    var end: i64 = len_i64;
    if (n >= 0) {
        if (is_drop) {
            start = @min(n, len_i64);
        } else {
            end = @min(n, len_i64);
        }
    } else {
        const len_plus_n = std.math.add(i64, len_i64, n) catch return error.Unsupported;
        if (is_drop) {
            end = @max(len_plus_n, 0);
        } else {
            start = @max(len_plus_n, 0);
        }
    }
    const s = std.math.cast(usize, start) orelse return error.Unsupported;
    const e = std.math.cast(usize, end) orelse return error.Unsupported;
    if (e < s) return error.Unsupported;
    const new_len = e - s;
    const stride = try axisStride(h.shape, k);
    const cell_count = try cellCount(h.shape, k);
    const fill_cost = try checkedMul(h.shape.len, h.shape.len);
    try chargeWorkProduct(ctx, cell_count, fill_cost);
    const output_len = try checkedMul(cell_count, new_len);
    try chargeWork(ctx, output_len);
    const cells = try rt.store.allocator().alloc(usize, cell_count);
    defer rt.store.allocator().free(cells);
    const out_bases = try rt.store.allocator().alloc(usize, cells.len);
    defer rt.store.allocator().free(out_bases);
    try fillCellBases2(h.shape, k, new_len, cells, out_bases);
    const shape = try rt.store.allocSlice(u32, h.rank);
    errdefer rt.store.discardUnpublished(shape.ref) catch unreachable;
    @memcpy(shape.slice, h.shape);
    shape.slice[k] = std.math.cast(u32, new_len) orelse return error.Unsupported;
    const data = try rt.store.allocSlice(u64, output_len);
    errdefer rt.store.discardUnpublished(data.ref) catch unreachable;
    for (cells, out_bases) |base, output_base| {
        for (0..new_len) |index| {
            const offset = try checkedMul(index, stride);
            const source_offset = try checkedMul(try checkedAdd(s, index), stride);
            data.slice[try checkedAdd(output_base, offset)] = h.data[try checkedAdd(base, source_offset)];
        }
    }
    return makeTensor(rt, h.inner, shape.slice, data.slice, shape.ref, data.ref);
}
/// `(cat a b)` — join along the leading axis (AlgoId 42); the
/// non-leading shapes must agree exactly, inner types must match.
pub fn cat(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    try intrin.arityAssert(args, 2);
    try intrin.typeAssert(args[0], skript.builtins.type_tensor);
    try intrin.typeAssert(args[1], skript.builtins.type_tensor);
    const a = args[0].obj.toRef().deref(TensorHolder).*;
    const b = args[1].obj.toRef().deref(TensorHolder).*;
    if (a.rank != b.rank) return error.TypeMismatch;
    // An empty side carries no inner type (.empty); the result takes the
    // other side's.
    const inner = if (a.inner == .empty) b.inner else if (b.inner == .empty) a.inner else b.inner;
    if (a.inner != .empty and b.inner != .empty and a.inner != b.inner) return error.TypeMismatch;
    if (a.rank > max_rank) return error.Unsupported;
    if (a.rank > 1) {
        try chargeWork(ctx, a.shape.len - 1);
        if (!std.mem.eql(u32, a.shape[1..], b.shape[1..])) return error.ArityMismatch;
    }

    const len_a = std.math.cast(usize, a.shape[0]) orelse return error.Unsupported;
    const len_b = std.math.cast(usize, b.shape[0]) orelse return error.Unsupported;
    const leading_len = try checkedAdd(len_a, len_b);
    const shape = try rt.store.allocSlice(u32, a.rank);
    errdefer rt.store.discardUnpublished(shape.ref) catch unreachable;
    shape.slice[0] = std.math.cast(u32, leading_len) orelse return error.Unsupported;
    if (a.rank > 1) @memcpy(shape.slice[1..], a.shape[1..]);
    const output_len = try checkedAdd(a.data.len, b.data.len);
    try chargeWork(ctx, output_len);
    const data = try rt.store.allocSlice(u64, output_len);
    errdefer rt.store.discardUnpublished(data.ref) catch unreachable;
    // Column-wise: the leading cells are contiguous runs, so cat is a
    // plain concatenation of the two flat arrays.
    @memcpy(data.slice[0..a.data.len], a.data);
    @memcpy(data.slice[a.data.len..], b.data);
    return makeTensor(rt, inner, shape.slice, data.slice, shape.ref, data.ref);
}
/// `(rev t)` / `(rev t k)` — rev axis k (AlgoId 4321).
pub fn rev(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    if (args.len < 1 or args.len > 2) return error.ArityMismatch;
    try intrin.typeAssert(args[0], skript.builtins.type_tensor);
    const h = args[0].obj.toRef().deref(TensorHolder).*;
    const k = if (args.len == 2) blk: {
        try intrin.typeAssert(args[1], skript.builtins.type_i64);
        break :blk try resolveAxis(h.rank, args[1].obj.toInt(i64));
    } else 0;
    if (h.rank > max_rank) return error.Unsupported;
    const len = std.math.cast(usize, h.shape[k]) orelse return error.Unsupported;
    const stride = try axisStride(h.shape, k);
    const cell_count = try cellCount(h.shape, k);
    const fill_cost = try checkedMul(h.shape.len, h.shape.len);
    try chargeWorkProduct(ctx, cell_count, fill_cost);
    const output_len = try checkedMul(cell_count, len);
    try chargeWork(ctx, output_len);
    const cells = try rt.store.allocator().alloc(usize, cell_count);
    defer rt.store.allocator().free(cells);
    try fillCellBases(h.shape, k, cells);
    const data = try rt.store.allocSlice(u64, output_len);
    errdefer rt.store.discardUnpublished(data.ref) catch unreachable;
    for (cells) |base| {
        for (0..len) |index| {
            const offset = try checkedMul(index, stride);
            const source_index = len - 1 - index;
            const source_offset = try checkedMul(source_index, stride);
            data.slice[try checkedAdd(base, offset)] = h.data[try checkedAdd(base, source_offset)];
        }
    }
    return makeTensor(rt, h.inner, h.shape, data.slice, h.shape_ref, data.ref);
}

/// `(rot n t)` / `(rot n t k)` — circular shift of axis k by n
/// (AlgoId 4104); positive n shifts left (toward index 0), n wraps mod len.
pub fn rot(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    if (args.len < 2 or args.len > 3) return error.ArityMismatch;
    try intrin.typeAssert(args[0], skript.builtins.type_i64);
    try intrin.typeAssert(args[1], skript.builtins.type_tensor);
    const h = args[1].obj.toRef().deref(TensorHolder).*;
    const n = args[0].obj.toInt(i64);
    const k = if (args.len == 3) blk: {
        try intrin.typeAssert(args[2], skript.builtins.type_i64);
        break :blk try resolveAxis(h.rank, args[2].obj.toInt(i64));
    } else 0;
    if (h.rank > max_rank) return error.Unsupported;
    const len = std.math.cast(usize, h.shape[k]) orelse return error.Unsupported;
    if (len == 0) return args[1];

    // Output position j reads input (j + n) mod len (left = toward 0).
    const len_i64 = std.math.cast(i64, len) orelse return error.Unsupported;
    var offset = @rem(n, len_i64);
    if (offset < 0) offset += len_i64;
    const offset_usize = std.math.cast(usize, offset) orelse return error.Unsupported;
    const stride = try axisStride(h.shape, k);
    const cell_count = try cellCount(h.shape, k);
    const fill_cost = try checkedMul(h.shape.len, h.shape.len);
    try chargeWorkProduct(ctx, cell_count, fill_cost);
    const output_len = try checkedMul(cell_count, len);
    try chargeWork(ctx, output_len);
    const cells = try rt.store.allocator().alloc(usize, cell_count);
    defer rt.store.allocator().free(cells);
    try fillCellBases(h.shape, k, cells);
    const data = try rt.store.allocSlice(u64, output_len);
    errdefer rt.store.discardUnpublished(data.ref) catch unreachable;
    for (cells) |base| {
        for (0..len) |index| {
            const source = try checkedAdd(index, offset_usize) % len;
            const output_offset = try checkedMul(index, stride);
            const source_offset = try checkedMul(source, stride);
            data.slice[try checkedAdd(base, output_offset)] = h.data[try checkedAdd(base, source_offset)];
        }
    }
    return makeTensor(rt, h.inner, h.shape, data.slice, h.shape_ref, data.ref);
}

/// `(outer a b fn)` — table product (AlgoId 6): result shape =
/// shape(a) ++ shape(b), element (i,j) = fn(a[i], b[j]). Proto: rank-1
/// operands only (cell operands need the Value inner-type fallback).
pub fn outer(ctx: *EvalContext, ns: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    try intrin.arityAssert(args, 3);
    try intrin.typeAssert(args[0], skript.builtins.type_tensor);
    try intrin.typeAssert(args[1], skript.builtins.type_tensor);
    const a = args[0].obj.toRef().deref(TensorHolder).*;
    const b = args[1].obj.toRef().deref(TensorHolder).*;
    if (a.rank != 1 or b.rank != 1) return error.Unsupported;
    const la = std.math.cast(usize, a.shape[0]) orelse return error.Unsupported;
    const lb = std.math.cast(usize, b.shape[0]) orelse return error.Unsupported;
    const output_len = try checkedMul(la, lb);
    try chargeWork(ctx, la);
    try chargeWork(ctx, output_len);
    const shape = try rt.store.allocSlice(u32, 2);
    errdefer rt.store.discardUnpublished(shape.ref) catch unreachable;
    shape.slice[0] = a.shape[0];
    shape.slice[1] = b.shape[0];
    const data = try rt.store.allocSlice(u64, output_len);
    errdefer rt.store.discardUnpublished(data.ref) catch unreachable;
    var inner: InnerType = .empty;
    var workspace = Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    for (0..la) |i| {
        for (0..lb) |j| {
            const result = try rt.applyWithWorkspace(ctx, ns, args[2], &.{
                wordToValue(a.inner, a.data[i]),
                wordToValue(b.inner, b.data[j]),
            }, &workspace);
            // SAFETY: scalarWord initializes the output type before it is read below.
            var result_inner: InnerType = undefined;
            const output_index = try checkedAdd(try checkedMul(i, lb), j);
            data.slice[output_index] = try scalarWord(result, &result_inner);
            if (inner == .empty) inner = result_inner else if (result_inner != inner) return error.TypeMismatch;
        }
    }
    return makeTensor(rt, inner, shape.slice, data.slice, shape.ref, data.ref);
}
pub fn dot(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    try intrin.arityAssert(args, 2);
    try intrin.typeAssert(args[0], skript.builtins.type_tensor);
    try intrin.typeAssert(args[1], skript.builtins.type_tensor);
    const a = args[0].obj.toRef().deref(TensorHolder).*;
    const b = args[1].obj.toRef().deref(TensorHolder).*;
    if (a.inner != b.inner) return error.TypeMismatch;
    if (a.inner != .i64 and a.inner != .f64) return error.Unsupported;

    if (a.rank == 1 and b.rank == 1) {
        if (a.shape[0] != b.shape[0]) return error.ArityMismatch;
        const len = std.math.cast(usize, a.shape[0]) orelse return error.Unsupported;
        try chargeWork(ctx, len);
        var accumulator: u64 = 0;
        for (0..len) |index| {
            accumulator = wordAdd(a.inner, accumulator, wordMul(a.inner, a.data[index], b.data[index]));
        }
        return wordToValue(a.inner, accumulator);
    }
    if (a.rank == 2 and b.rank == 2) {
        const m = std.math.cast(usize, a.shape[0]) orelse return error.Unsupported;
        const n = std.math.cast(usize, a.shape[1]) orelse return error.Unsupported;
        const p = std.math.cast(usize, b.shape[1]) orelse return error.Unsupported;
        if (b.shape[0] != a.shape[1]) return error.ArityMismatch;
        const output_len = try checkedMul(m, p);
        try chargeWork(ctx, m);
        try chargeWorkProduct(ctx, output_len, n);
        try chargeWork(ctx, output_len);
        const shape = try rt.store.allocSlice(u32, 2);
        errdefer rt.store.discardUnpublished(shape.ref) catch unreachable;
        shape.slice[0] = a.shape[0];
        shape.slice[1] = b.shape[1];
        const data = try rt.store.allocSlice(u64, output_len);
        errdefer rt.store.discardUnpublished(data.ref) catch unreachable;
        // Column-wise: A(i,k) = a.data[i*n + k], B(k,j) = b.data[k*p + j]
        // (the last axis varies fastest), result C(i,j) = data[i*p + j].
        for (0..m) |i| {
            for (0..p) |j| {
                var accumulator: u64 = 0;
                for (0..n) |k| {
                    const a_index = try checkedAdd(try checkedMul(i, n), k);
                    const b_index = try checkedAdd(try checkedMul(k, p), j);
                    const av = a.data[a_index];
                    const bv = b.data[b_index];
                    accumulator = wordAdd(a.inner, accumulator, wordMul(a.inner, av, bv));
                }
                const output_index = try checkedAdd(try checkedMul(i, p), j);
                data.slice[output_index] = accumulator;
            }
        }
        return makeTensor(rt, a.inner, shape.slice, data.slice, shape.ref, data.ref);
    }
    return error.Unsupported;
}

// i64 tensor words are u64 bit patterns; wrapping either type preserves the same low 64 bits.
fn wordAdd(inner: InnerType, a: u64, b: u64) u64 {
    return switch (inner) {
        .i64 => a +% b,
        .f64 => @bitCast(@as(f64, @bitCast(a)) + @as(f64, @bitCast(b))),
        else => unreachable,
    };
}

fn wordMul(inner: InnerType, a: u64, b: u64) u64 {
    return switch (inner) {
        .i64 => a *% b,
        .f64 => @bitCast(@as(f64, @bitCast(a)) * @as(f64, @bitCast(b))),
        else => unreachable,
    };
}

/// `(zip a b)` — pair along the leading axis by stacking into a new LAST
/// axis of width 2 (AlgoId 28): shape = [len, sub…, 2], len = min(len(a),
/// len(b)); truncates, sub-shapes and inner types must match.
pub fn zip(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    try intrin.arityAssert(args, 2);
    try intrin.typeAssert(args[0], skript.builtins.type_tensor);
    try intrin.typeAssert(args[1], skript.builtins.type_tensor);
    const a = args[0].obj.toRef().deref(TensorHolder).*;
    const b = args[1].obj.toRef().deref(TensorHolder).*;
    if (a.inner != b.inner or a.rank != b.rank) return error.TypeMismatch;
    const rank = std.math.cast(usize, a.rank) orelse return error.Unsupported;
    const output_rank = try checkedAdd(rank, 1);
    if (output_rank > max_rank) return error.Unsupported;
    if (rank > 1) {
        try chargeWork(ctx, rank - 1);
        if (!std.mem.eql(u32, a.shape[1..], b.shape[1..])) return error.ArityMismatch;
    }

    const len = std.math.cast(usize, @min(a.shape[0], b.shape[0])) orelse return error.Unsupported;
    const input_len = std.math.cast(usize, a.shape[0]) orelse return error.Unsupported;
    const words_per = if (len > 0) a.data.len / input_len else 0;
    const pair_words = try checkedMul(words_per, 2);
    const output_len = try checkedMul(len, pair_words);
    try chargeWork(ctx, len);
    try chargeWork(ctx, output_len);
    const shape = try rt.store.allocSlice(u32, output_rank);
    errdefer rt.store.discardUnpublished(shape.ref) catch unreachable;
    shape.slice[0] = std.math.cast(u32, len) orelse return error.Unsupported;
    if (rank > 1) @memcpy(shape.slice[1..rank], a.shape[1..]);
    shape.slice[rank] = 2;
    const data = try rt.store.allocSlice(u64, output_len);
    errdefer rt.store.discardUnpublished(data.ref) catch unreachable;
    // Column-wise output (j, i, p): flat = j*(w*2) + i*2 + p (the pair
    // axis is the new LAST axis, fastest). Input leading cell j is the
    // contiguous run [j*w, (j+1)*w).
    for (0..len) |j| {
        const input_base = try checkedMul(j, words_per);
        const output_base = try checkedMul(j, pair_words);
        for (0..words_per) |i| {
            const input_index = try checkedAdd(input_base, i);
            const output_index = try checkedAdd(output_base, try checkedMul(i, 2));
            data.slice[output_index] = a.data[input_index];
            data.slice[try checkedAdd(output_index, 1)] = b.data[input_index];
        }
    }
    return makeTensor(rt, a.inner, shape.slice, data.slice, shape.ref, data.ref);
}

/// `(map2 a b fn)` — apply `fn` to broadcast pairs (AlgoId 30).
/// Dimensions align from the trailing axis. Equal dimensions or a singleton
/// dimension broadcast; zero with one yields zero, while zero with larger
/// dimensions is incompatible.
pub fn map2(ctx: *EvalContext, ns: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    try intrin.arityAssert(args, 3);
    try intrin.typeAssert(args[0], skript.builtins.type_tensor);
    try intrin.typeAssert(args[1], skript.builtins.type_tensor);
    const a = args[0].obj.toRef().deref(TensorHolder).*;
    const b = args[1].obj.toRef().deref(TensorHolder).*;
    const layout = try Map2Layout.init(a.shape, b.shape);
    try chargeWork(ctx, layout.rank);
    try chargeWork(ctx, layout.output_len);
    const data = try rt.store.allocSlice(u64, layout.output_len);
    errdefer rt.store.discardUnpublished(data.ref) catch unreachable;
    var inner: InnerType = .empty;
    var workspace = Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    for (0..layout.output_len) |index| {
        const input_indices = layout.inputIndices(index);
        const result = try rt.applyWithWorkspace(ctx, ns, args[2], &.{
            wordToValue(a.inner, a.data[input_indices[0]]),
            wordToValue(b.inner, b.data[input_indices[1]]),
        }, &workspace);
        // SAFETY: scalarWord initializes the output type before it is read below.
        var result_inner: InnerType = undefined;
        data.slice[index] = try scalarWord(result, &result_inner);
        if (inner == .empty) inner = result_inner else if (result_inner != inner) {
            return error.TypeMismatch;
        }
    }
    var shape = a.shape;
    var shape_ref = a.shape_ref;
    if (!layout.exact_shape) {
        const allocated = try rt.store.allocSlice(u32, layout.rank);
        errdefer rt.store.discardUnpublished(allocated.ref) catch unreachable;
        @memcpy(allocated.slice, layout.shapeSlice());
        shape = allocated.slice;
        shape_ref = allocated.ref;
    }
    return makeTensor(rt, inner, shape, data.slice, shape_ref, data.ref);
}

/// Precomputed trailing-axis strides for one broadcast map2 operation.
pub const Map2Layout = struct {
    shape: [max_rank]u32 = @splat(0),
    output_strides: [max_rank]usize = @splat(0),
    left_strides: [max_rank]usize = @splat(0),
    right_strides: [max_rank]usize = @splat(0),
    rank: usize,
    output_len: usize,
    exact_shape: bool,

    pub fn init(left_shape: []const u32, right_shape: []const u32) Error!Map2Layout {
        if (left_shape.len == 0 or right_shape.len == 0) return error.Unsupported;
        if (left_shape.len > max_rank or right_shape.len > max_rank) return error.Unsupported;
        const rank = @max(left_shape.len, right_shape.len);
        var layout: Map2Layout = .{
            .rank = rank,
            .output_len = 1,
            .exact_shape = std.mem.eql(u32, left_shape, right_shape),
        };
        if (layout.exact_shape) {
            @memcpy(layout.shape[0..rank], left_shape);
            for (left_shape) |dimension| {
                if (dimension == 0) {
                    layout.output_len = 0;
                    return layout;
                }
            }
            for (left_shape) |dimension| {
                layout.output_len = try checkedMul(
                    layout.output_len,
                    std.math.cast(usize, dimension) orelse return error.Unsupported,
                );
            }
            return layout;
        }

        const left_offset = rank - left_shape.len;
        const right_offset = rank - right_shape.len;
        for (0..rank) |axis| {
            const left_dimension = if (axis < left_offset) 1 else left_shape[axis - left_offset];
            const right_dimension = if (axis < right_offset) 1 else right_shape[axis - right_offset];
            const output_dimension = if (left_dimension == right_dimension)
                left_dimension
            else if (left_dimension == 1)
                right_dimension
            else if (right_dimension == 1)
                left_dimension
            else
                return error.Unsupported;
            layout.shape[axis] = output_dimension;
        }
        var has_zero_dimension = false;
        for (layout.shapeSlice()) |dimension| {
            if (dimension == 0) has_zero_dimension = true;
        }
        if (has_zero_dimension) {
            layout.output_len = 0;
        } else {
            for (layout.shapeSlice()) |dimension| {
                layout.output_len = try checkedMul(
                    layout.output_len,
                    std.math.cast(usize, dimension) orelse return error.Unsupported,
                );
            }
        }
        if (layout.output_len == 0) return layout;

        var left_stride: usize = 1;
        var right_stride: usize = 1;
        var output_stride: usize = 1;
        var axis = rank;
        while (axis > 0) {
            axis -= 1;
            layout.output_strides[axis] = output_stride;
            output_stride = try checkedMul(
                output_stride,
                std.math.cast(usize, layout.shape[axis]) orelse return error.Unsupported,
            );
            if (axis >= left_offset) {
                const dimension = left_shape[axis - left_offset];
                layout.left_strides[axis] = if (dimension == 1) 0 else left_stride;
                left_stride = try checkedMul(
                    left_stride,
                    std.math.cast(usize, dimension) orelse return error.Unsupported,
                );
            }
            if (axis >= right_offset) {
                const dimension = right_shape[axis - right_offset];
                layout.right_strides[axis] = if (dimension == 1) 0 else right_stride;
                right_stride = try checkedMul(
                    right_stride,
                    std.math.cast(usize, dimension) orelse return error.Unsupported,
                );
            }
        }
        return layout;
    }

    pub fn shapeSlice(self: *const Map2Layout) []const u32 {
        return self.shape[0..self.rank];
    }

    pub fn inputIndices(self: *const Map2Layout, output_index: usize) [2]usize {
        std.debug.assert(output_index < self.output_len);
        if (self.exact_shape) return .{ output_index, output_index };
        var left_index: usize = 0;
        var right_index: usize = 0;
        for (0..self.rank) |axis| {
            const dimension = @as(usize, self.shape[axis]);
            const coordinate = (output_index / self.output_strides[axis]) % dimension;
            left_index += coordinate * self.left_strides[axis];
            right_index += coordinate * self.right_strides[axis];
        }
        return .{ left_index, right_index };
    }
};

/// `(max t)` / `(max a b)` — unary: fold the leading axis to a scalar
/// (rank-1) or a rank-1-lower tensor; binary: elementwise max over equal
/// shapes (AlgoId 37). Numeric inner types only.
pub fn max(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    return minMax(ctx, args, true);
}

/// `(min t)` / `(min a b)` — mirror of max (AlgoId 38).
pub fn min(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    return minMax(ctx, args, false);
}

fn minMax(ctx: *EvalContext, args: []const Value, is_max: bool) Error!Value {
    const rt = ctx.runtime;
    if (args.len < 1 or args.len > 2) return error.ArityMismatch;
    try intrin.typeAssert(args[0], skript.builtins.type_tensor);
    const h = args[0].obj.toRef().deref(TensorHolder).*;
    if (h.inner != .i64 and h.inner != .f64) return error.Unsupported;

    if (args.len == 1) {
        if (h.rank != 1) return error.Unsupported; // proto: rank-1 unary only
        if (h.shape[0] == 0) return error.Unsupported;
        try chargeWork(ctx, h.data.len - 1);
        var accumulator = h.data[0];
        for (h.data[1..]) |word| {
            accumulator = if (is_max) wordMax(h.inner, accumulator, word) else wordMin(h.inner, accumulator, word);
        }
        return wordToValue(h.inner, accumulator);
    }
    try intrin.typeAssert(args[1], skript.builtins.type_tensor);
    const b = args[1].obj.toRef().deref(TensorHolder).*;
    if (b.inner != h.inner) return error.TypeMismatch;
    if (h.rank != b.rank) return error.Unsupported;
    try chargeWork(ctx, h.shape.len);
    if (!std.mem.eql(u32, h.shape, b.shape)) return error.Unsupported;
    const data = try rt.store.allocSlice(u64, h.data.len);
    errdefer rt.store.discardUnpublished(data.ref) catch unreachable;
    for (h.data, b.data, 0..) |wa, wb, index| {
        data.slice[index] = if (is_max) wordMax(h.inner, wa, wb) else wordMin(h.inner, wa, wb);
    }
    return makeTensor(rt, h.inner, h.shape, data.slice, h.shape_ref, data.ref);
}

fn wordMax(inner: InnerType, a: u64, b: u64) u64 {
    return switch (inner) {
        .i64 => @bitCast(@max(@as(i64, @bitCast(a)), @as(i64, @bitCast(b)))),
        .f64 => @bitCast(@max(@as(f64, @bitCast(a)), @as(f64, @bitCast(b)))),
        else => unreachable,
    };
}

fn wordMin(inner: InnerType, a: u64, b: u64) u64 {
    return switch (inner) {
        .i64 => @bitCast(@min(@as(i64, @bitCast(a)), @as(i64, @bitCast(b)))),
        .f64 => @bitCast(@min(@as(f64, @bitCast(a)), @as(f64, @bitCast(b)))),
        else => unreachable,
    };
}

// --- runtime tests --- //

const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualStrings = std.testing.expectEqualStrings;

fn newRt() !*Runtime {
    return Runtime.init(std.testing.allocator, std.testing.io);
}

fn format(rt: *Runtime, v: Value) ![]const u8 {
    const s = try intrin.print.debugFormatBuiltin(rt.context(), .nil, .nil, &.{v});
    return std.mem.sliceTo(s.obj.toPtr([*]u8), 0);
}

fn formatPretty(rt: *Runtime, v: Value) []const u8 {
    var out: std.Io.Writer.Allocating = .init(rt.store.allocator());
    const fv: intrin.print.FormatValue = .{ .value = v, .runtime = rt, .pretty = true };
    fv.format(&out.writer) catch return "format-error";
    return out.toArrayList().items;
}

test "tensor iota" {
    var runtime = try newRt();
    defer runtime.deinit();
    const v = try runtime.evalString("(iota 4)");
    try expect(Value.isTensor(v));
    const h = v.obj.toRef().deref(TensorHolder).*;
    try expectEqual(InnerType.i64, h.inner);
    try expectEqualSlices(u32, &.{4}, h.shape);
    try expectEqualSlices(u64, &.{
        @bitCast(@as(i64, 0)), @bitCast(@as(i64, 1)),
        @bitCast(@as(i64, 2)), @bitCast(@as(i64, 3)),
    }, h.data);
    try expectEqualStrings("[0 1 2 3]", try format(runtime, v));
    try expectError(error.Unsupported, runtime.evalString("(iota -1)"));
    try expectEqualStrings("[]", try format(runtime, try runtime.evalString("(iota 0)")));
}

test "tensor reshape reuses data column-wise" {
    var runtime = try newRt();
    defer runtime.deinit();
    // Bracket-free shapes: evalString is the stack-VM/Ast path, which rejects
    // the [..] literals (reader/regvm path supports them).
    const v = try runtime.evalString("(reshape (iota 4) (stack 2 2))");
    try expect(Value.isTensor(v));
    const h = v.obj.toRef().deref(TensorHolder).*;
    try expectEqual(@as(u32, 2), h.rank);
    try expectEqualSlices(u32, &.{ 2, 2 }, h.shape);
    // Restored lat-display: rank-2 renders TRANSPOSED (rows = shape[1],
    // columns = shape[0]). Column-wise flat=[0,1,2,3]: cell(r,c) =
    // flat[c*2 + r] → rows [0 2] [1 3]. Box: content width 3 → ╭ + 5
    // blanks, ╯ at 6.
    try expectEqualStrings(
        "╭─     \n╷ 0 2  \n  1 3  \n      ╯",
        formatPretty(runtime, v),
    );
    // Element count mismatch.
    try expectError(error.ArityMismatch, runtime.evalString("(reshape (iota 4) (stack 3))"));
    // Negative dims rejected.
    try expectError(error.Unsupported, runtime.evalString("(reshape (iota 4) (stack 2 -2))"));
}

test "tensor pretty printer: Uiua box layout" {
    var runtime = try newRt();
    defer runtime.deinit();

    // Rank-1: VERTICAL COLUMN, one element per line (capped at 16 + "…").
    // Content width 1 → ╭ + 3 blanks, ╯ at 4.
    try expectEqualStrings(
        "╭─   \n╷ 0  \n  1  \n  2  \n    ╯",
        formatPretty(runtime, try runtime.evalString("(iota 3)")),
    );

    // Rank-2: TRANSPOSED aligned matrix; numerics right-aligned per column
    // (rows = shape[1]: 100/2 in col 0, 3/4000 in col 1).
    try expectEqualStrings(
        "╭─          \n╷ 100    3  \n    2 4000  \n           ╯",
        formatPretty(runtime, try runtime.evalString("(stack (stack 100 2) (stack 3 4000))")),
    );

    // Rank-3: STACK of matrices along axis 0; planes separated by a dash
    // rule spanning the content width (columns aligned across planes).
    // Each plane renders transposed: plane 0 = [1 3]/[2 4], plane 1 = [5 7]/[6 8].
    const v3 = try runtime.evalString(
        "(stack (stack (stack 1 2) (stack 3 4)) (stack (stack 5 6) (stack 7 8)))",
    );
    try expectEqualStrings(
        "╭─     \n╷ 1 3  \n  2 4  \n  ---  \n  5 7  \n  6 8  \n      ╯",
        formatPretty(runtime, v3),
    );

    // Rank-4: MATRIX of submatrices (2x2 grid). Grid COLUMNS = axis0,
    // rows = axis1; each cell renders transposed (rows = shape[3],
    // cols = shape[2]); cells joined with "|" grid bars, a dash rule
    // between grid rows. Cell (i0,i1): base i0*8 + i1*4, values
    // {i0*8 + i1*4 + i2*2 + i3}: TL=[[0 2] [1 3]], TR=[[8 10] [9 11]],
    // BL=[[4 6] [5 7]], BR=[[12 14] [13 15]].
    const v4 = try runtime.evalString("(reshape (iota 16) (stack 2 2 2 2))");
    try expectEqualStrings(
        "╭─             \n╷ 0  2|8 10    \n  1  3|9 11    \n  ---------    \n   4  6|12 14  \n   5  7|13 15  \n              ╯",
        formatPretty(runtime, v4),
    );

    // Truncation: more than 16 elements in a rank-1 column appends a "…"
    // line inside the box.
    const wide = try runtime.evalString("(iota 20)");
    const pw = formatPretty(runtime, wide);
    try std.testing.expect(std.mem.startsWith(u8, pw, "╭"));
    try std.testing.expect(std.mem.indexOf(u8, pw, "…") != null);
    try std.testing.expect(std.mem.endsWith(u8, pw, "╯"));
}

test "tensor rank-1 construction" {
    var runtime = try newRt();
    defer runtime.deinit();
    const v = try runtime.evalString("(stack 1 2 3)");
    try expect(Value.isTensor(v));
    const h = v.obj.toRef().deref(TensorHolder).*;
    try expectEqual(InnerType.i64, h.inner);
    try expectEqual(@as(u32, 1), h.rank);
    try expectEqualSlices(u32, &.{3}, h.shape);
    try expectEqualSlices(u64, &.{ @bitCast(@as(i64, 1)), @bitCast(@as(i64, 2)), @bitCast(@as(i64, 3)) }, h.data);
}

test "tensor f64/string/symbol/keyword elements" {
    var runtime = try newRt();
    defer runtime.deinit();
    const f = try runtime.evalString("(stack 1.5 2.5)");
    try expectEqual(InnerType.f64, f.obj.toRef().deref(TensorHolder).inner);
    const s = try runtime.evalString("(stack \"a\" \"bb\")");
    try expectEqual(InnerType.string, s.obj.toRef().deref(TensorHolder).inner);
    const sym = try runtime.evalString("(stack 'x 'y)");
    try expectEqual(InnerType.symbol, sym.obj.toRef().deref(TensorHolder).inner);
    const kw = try runtime.evalString("(stack :k1 :k2)");
    try expectEqual(InnerType.keyword, kw.obj.toRef().deref(TensorHolder).inner);
}

test "tensor nested construction stacks along a new leading axis" {
    var runtime = try newRt();
    defer runtime.deinit();
    const v = try runtime.evalString("(stack (stack 1 2) (stack 3 4))");
    try expect(Value.isTensor(v));
    const h = v.obj.toRef().deref(TensorHolder).*;
    try expectEqual(InnerType.i64, h.inner);
    try expectEqual(@as(u32, 2), h.rank);
    try expectEqualSlices(u32, &.{ 2, 2 }, h.shape);
    // Column-wise: each sub-tensor's words land CONTIGUOUSLY — (stack c1
    // c2) is a plain concat, so the flat is [1 2 3 4].
    try expectEqualSlices(u64, &.{
        @bitCast(@as(i64, 1)), @bitCast(@as(i64, 2)),
        @bitCast(@as(i64, 3)), @bitCast(@as(i64, 4)),
    }, h.data);
}

test "tensor empty construction" {
    var runtime = try newRt();
    defer runtime.deinit();
    const v = try runtime.evalString("(stack)");
    try expect(Value.isTensor(v));
    const h = v.obj.toRef().deref(TensorHolder).*;
    try expectEqual(InnerType.empty, h.inner);
    try expectEqual(@as(u32, 1), h.rank);
    try expectEqualSlices(u32, &.{0}, h.shape);
    try expectEqual(@as(usize, 0), h.data.len);
}

test "tensor-shape tensor-rank tensor-len" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectEqual(Value.i64(1), try runtime.evalString("(tensor-rank (stack 1 2 3))"));
    try expectEqual(Value.i64(3), try runtime.evalString("(tensor-len (stack 1 2 3))"));
    try expectEqual(Value.i64(2), try runtime.evalString("(tensor-rank (stack (stack 1) (stack 2)))"));
    try expectEqual(Value.i64(2), try runtime.evalString("(tensor-len (stack (stack 1) (stack 2)))"));
    try expectEqual(Value.i64(0), try runtime.evalString("(tensor-len (stack))"));

    // shape is a cons list of i64 dims (leading axis first)
    const shapes = [_][]const u8{
        "(tensor-shape (stack 1 2 3))",
        "(tensor-shape (stack (stack 1 2) (stack 3 4)))",
        "(tensor-shape (stack (stack 1 2 3) (stack 4 5 6)))",
        "(tensor-shape (stack))",
    };
    const want = [_][]const u8{ "(3)", "(2 2)", "(2 3)", "(0)" };
    for (shapes, want) |src, w| {
        const got = try runtime.evalString(src);
        try expectEqualStrings(w, try format(runtime, got));
    }
}

test "tensor-get bounds and nesting" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectEqual(Value.i64(20), try runtime.evalString("(tensor-get (stack 10 20 30) 1)"));
    try expectEqual(Value.i64(3), try runtime.evalString("(tensor-get (stack (stack 1 2) (stack 3 4)) 1 0)"));
    try expectEqual(Value.i64(4), try runtime.evalString("(tensor-get (stack (stack 1 2) (stack 3 4)) 1 1)"));
    try expectEqual(Value.f64(2.5), try runtime.evalString("(tensor-get (stack 1.5 2.5) 1)"));

    const s = try runtime.evalString("(tensor-get (stack \"hi\" \"yo\") 0)");
    try expect(Value.isString(s));
    try expectEqualStrings("hi", std.mem.sliceTo(s.obj.toPtr([*]u8), 0));

    const k = try runtime.evalString("(tensor-get (stack :k1 :k2) 1)");
    try expectEqual(skript.builtins.type_keyword, k.typ);
    try expectEqualStrings("k2", k.obj.toPtr(Sym).*);

    const y = try runtime.evalString("(tensor-get (stack 'a 'b) 1)");
    try expectEqual(skript.builtins.type_symbol, y.typ);
    try expectEqualStrings("b", y.obj.toPtr(Sym).*);

    // out-of-bounds and bad arity
    try expectError(error.Unsupported, runtime.evalString("(tensor-get (stack 1 2) 5)"));
    try expectError(error.Unsupported, runtime.evalString("(tensor-get (stack 1 2) -1)"));
    try expectError(error.Unsupported, runtime.evalString("(tensor-get (stack) 0)"));
    try expectError(error.ArityMismatch, runtime.evalString("(tensor-get (stack 1 2) 0 0)"));
    try expectError(error.ArityMismatch, runtime.evalString("(tensor-get (stack 1 2))"));
}

test "tensor mixed inner type is an error" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectError(error.TypeMismatch, runtime.evalString("(stack 1 2.5)"));
    try expectError(error.TypeMismatch, runtime.evalString("(stack 1 \"a\")"));
    try expectError(error.TypeMismatch, runtime.evalString("(stack 1 'x)"));
    try expectError(error.TypeMismatch, runtime.evalString("(stack 1 (stack 2))"));
    try expectError(error.TypeMismatch, runtime.evalString("(stack (stack 1) (stack 1.0))"));
    try expectError(error.ArityMismatch, runtime.evalString("(stack (stack 1 2) (stack 3 4 5))"));
}

test "tensor printer round-trips" {
    var runtime = try newRt();
    defer runtime.deinit();
    const v1 = try runtime.evalString("(stack 1 2 3)");
    try expectEqualStrings("[1 2 3]", try format(runtime, v1));
    const v2 = try runtime.evalString("(stack (stack 1 2) (stack 3 4))");
    try expectEqualStrings("[[1 2] [3 4]]", try format(runtime, v2));
    const v3 = try runtime.evalString("(stack 1.5 2.5)");
    try expectEqualStrings("[1.5 2.5]", try format(runtime, v3));
    const v4 = try runtime.evalString("(stack \"a\" \"bb\")");
    try expectEqualStrings("[\"a\" \"bb\"]", try format(runtime, v4));
    const v5 = try runtime.evalString("(stack 'x 'y)");
    try expectEqualStrings("['x 'y]", try format(runtime, v5));
    const v6 = try runtime.evalString("(stack :k1 :k2)");
    try expectEqualStrings("[:k1 :k2]", try format(runtime, v6));
    const v7 = try runtime.evalString("(stack)");
    try expectEqualStrings("[]", try format(runtime, v7));
    const v8 = try runtime.evalString("(stack (stack 1 2 3) (stack 4 5 6))");
    try expectEqualStrings("[[1 2 3] [4 5 6]]", try format(runtime, v8));
    const v9 = try runtime.evalString("(stack (stack 1.0 2.0) (stack 3.0 4.0))");
    try expectEqualStrings("[[1.0 2.0] [3.0 4.0]]", try format(runtime, v9));
}

test "tensor equality via prelude instance" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectEqual(Value.true, try runtime.evalString("(= (stack 1 2) (stack 1 2))"));
    try expectEqual(Value.false, try runtime.evalString("(= (stack 1 2) (stack 1 3))"));
    try expectEqual(Value.false, try runtime.evalString("(= (stack 1) (stack 1.0))"));
    try expectEqual(Value.true, try runtime.evalString(
        "(= (stack (stack 1 2) (stack 3 4)) (stack (stack 1 2) (stack 3 4)))",
    ));
    try expectEqual(Value.false, try runtime.evalString(
        "(= (stack (stack 1 2) (stack 3 4)) (stack (stack 1 2) (stack 3 5)))",
    ));
    try expectEqual(Value.true, try runtime.evalString("(= (stack \"a\") (stack \"a\"))"));
    try expectEqual(Value.false, try runtime.evalString("(= (stack \"a\") (stack \"b\"))"));
}

test "tensor type predicate and introspection" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectEqual(Value.true, try runtime.evalString("(Tensor? (stack 1 2))"));
    try expectEqual(Value.false, try runtime.evalString("(Tensor? 42)"));
    // The mixed construction itself is an error before any predicate runs.
    try expectError(error.TypeMismatch, runtime.evalString("(Tensor? (stack 1 2.5))"));
    try expectEqual(Value.true, try runtime.evalString("(@is-core-type? @Tensor)"));
    // (type x) returns the core.tensor type value.
    const t = try runtime.evalString("(@type (stack 1))");
    try expectEqual(skript.builtins.type_type, t.typ);
    try expectEqual(skript.builtins.type_tensor, t.obj);
}

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
    }
}

test "proto: fold collapses the folded axis" {
    var runtime = try newRt();
    defer runtime.deinit();
    // Rank-1: scalar atom result.
    try expectEqual(Value.i64(6), try runtime.evalString("(fold (stack 1 2 3) +)"));
    try expectEqual(Value.i64(10), try runtime.evalString("(fold (stack 1 2 3 4) +)"));
    try expectEqual(Value.f64(4.0), try runtime.evalString("(fold (stack 1.5 2.5) +)"));
    // Mixed-type fold: the + method has no (f64, i64) instance (promotion
    // is docs/tensors.md §5 open question 1) — loud error, no coercion.
    try expectError(error.TypeMismatch, runtime.evalString("(fold (stack 1.5 6) +)"));

    // Matrix axis 0: column sums [1+3 2+4] = [4 6]; axis 1: row sums [3 7].
    try expectEqualStrings("[4 6]", try format(runtime, try runtime.evalString(
        "(fold (stack (stack 1 2) (stack 3 4)) 0 +)",
    )));
    try expectEqualStrings("[3 7]", try format(runtime, try runtime.evalString(
        "(fold (stack (stack 1 2) (stack 3 4)) 1 +)",
    )));
    // Negative axis = last.
    try expectEqualStrings("[3 7]", try format(runtime, try runtime.evalString(
        "(fold (stack (stack 1 2) (stack 3 4)) -1 +)",
    )));
    // Empty and error cases.
    try expectError(error.Unsupported, runtime.evalString("(fold (stack) +)"));
    try expectError(error.Unsupported, runtime.evalString("(fold (stack 1 2 3) 2 +)"));
    try expectError(error.ArityMismatch, runtime.evalString("(fold (stack 1 2))"));
}

test "proto: scan is the inclusive prefix fold" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectEqualStrings("[1 3 6]", try format(runtime, try runtime.evalString("(scan (stack 1 2 3) +)")));
    try expectEqualStrings("[1 3 6 10]", try format(runtime, try runtime.evalString("(scan (stack 1 2 3 4) +)")));
    // Axis 1 of a matrix: prefix over rows.
    try expectEqualStrings("[[1 3] [3 7]]", try format(runtime, try runtime.evalString(
        "(scan (stack (stack 1 2) (stack 3 4)) 1 +)",
    )));
    try expectEqualStrings("[]", try format(runtime, try runtime.evalString("(scan (stack) +)")));
}

test "proto: map dispatches on the collection type" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectEqualStrings("[2 4 6]", try format(runtime, try runtime.evalString(
        "(map (stack 1 2 3) (fn (x) (* x 2)))",
    )));
    // f64 in, i64 out via the fn.
    try expectEqualStrings("[1.0 2.0 3.0]", try format(runtime, try runtime.evalString(
        "(map (stack 1.0 2.0 3.0) (fn (x) (round x)))",
    )));
    // Axis form maps rows of a matrix.
    try expectEqualStrings("[[10 20] [30 40]]", try format(runtime, try runtime.evalString(
        "(map (stack (stack 1 2) (stack 3 4)) 1 (fn (x) (* x 10)))",
    )));
    // `map` is transform-only (collections.map: list→listMap, tensor→
    // tensor.map, else TypeMismatch). Dict construction lives in `hash-map`.
    try expectEqualStrings(":v", try format(runtime, try runtime.evalString("(map-get (hash-map :k :v) :k)")));
    try expectError(error.Unimplemented, runtime.evalString("(map (stack 1 2) 3)"));
}

test "proto: keep keeps leading-axis cells" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectEqualStrings("[3 4]", try format(runtime, try runtime.evalString(
        "(keep (stack 1 2 3 4) (fn (x) (> x 2)))",
    )));
    try expectEqualStrings("[]", try format(runtime, try runtime.evalString(
        "(keep (stack 1 2) (fn (x) (> x 9)))",
    )));
    // Filtering a matrix keeps whole rows (rank preserved).
    try expectEqualStrings("[[5 6]]", try format(runtime, try runtime.evalString(
        "(keep (stack (stack 1 2) (stack 5 6)) (fn (r) (> (fold r +) 5)))",
    )));
    try expectError(error.TypeMismatch, runtime.evalString("(keep (stack 1 2) (fn (x) 1))"));
}

test "proto: uniq removes adjacent duplicates" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectEqualStrings("[1 2 3]", try format(runtime, try runtime.evalString("(uniq (stack 1 1 2 2 2 3))")));
    // Non-adjacent duplicates survive (AlgoId 14, not 15).
    try expectEqualStrings("[1 2 1]", try format(runtime, try runtime.evalString("(uniq (stack 1 2 1))")));
    try expectEqualStrings("[]", try format(runtime, try runtime.evalString("(uniq (stack))")));
    // Cell-level: whole rows compare.
    try expectEqualStrings("[[1 2] [3 4]]", try format(runtime, try runtime.evalString(
        "(uniq (stack (stack 1 2) (stack 1 2) (stack 3 4)))",
    )));
}

test "proto: where returns nonzero indices" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectEqualStrings("[1 3]", try format(runtime, try runtime.evalString("(where (stack 0 1 0 3))")));
    try expectEqualStrings("[]", try format(runtime, try runtime.evalString("(where (stack 0 0))")));
    try expectEqualStrings("[0]", try format(runtime, try runtime.evalString("(where (stack -1))")));
    try expectError(error.TypeMismatch, runtime.evalString("(where (stack 1.0))"));
}

test "proto: diff shrinks the axis by one" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectEqualStrings("[2 3 4]", try format(runtime, try runtime.evalString("(diff (stack 1 3 6 10))")));
    try expectEqualStrings("[1.0 1.0]", try format(runtime, try runtime.evalString("(diff (stack 1.5 2.5 3.5))")));
    // Axis 1 of a matrix: column-wise diffs.
    try expectEqualStrings("[[1] [1]]", try format(runtime, try runtime.evalString(
        "(diff (stack (stack 1 2) (stack 3 4)) 1)",
    )));
    try expectError(error.Unsupported, runtime.evalString("(diff (stack \"a\" \"b\"))"));
    try expectEqualStrings("[]", try format(runtime, try runtime.evalString("(diff (stack 5))")));
}

test "proto: flat is the column-wise ravel" {
    var runtime = try newRt();
    defer runtime.deinit();
    // [[1 2] [3 4]] column-wise flat: [1 2 3 4] (the literal reading order).
    try expectEqualStrings("[1 2 3 4]", try format(runtime, try runtime.evalString(
        "(flat (stack (stack 1 2) (stack 3 4)))",
    )));
    try expectEqualStrings("[0 1 2 3]", try format(runtime, try runtime.evalString(
        "(flat (reshape (iota 4) (stack 2 2)))",
    )));
    try expectEqualStrings("[]", try format(runtime, try runtime.evalString("(flat (stack))")));
}

test "proto: trans reverses or permutes axes" {
    var runtime = try newRt();
    defer runtime.deinit();
    // 2x2 swap: [[1 2] [3 4]] -> [[1 3] [2 4]].
    try expectEqualStrings("[[1 3] [2 4]]", try format(runtime, try runtime.evalString(
        "(trans (stack (stack 1 2) (stack 3 4)))",
    )));
    // Rank-1: reversing one axis is the identity.
    try expectEqualStrings("[1 2 3]", try format(runtime, try runtime.evalString("(trans (stack 1 2 3))")));
    // Explicit permutation.
    try expectEqualStrings("[[1 3] [2 4]]", try format(runtime, try runtime.evalString(
        "(trans (stack (stack 1 2) (stack 3 4)) (stack 1 0))",
    )));
    // Rank-3: identity perm keeps data; swap perm reorders.
    const cube = "(reshape (iota 8) (stack 2 2 2))";
    try expectEqualStrings(
        try format(runtime, try runtime.evalString(cube)),
        try format(runtime, try runtime.evalString("(trans " ++ cube ++ " (stack 0 1 2))")),
    );
    try expectError(error.Unsupported, runtime.evalString(
        "(trans (stack (stack 1 2) (stack 3 4)) (stack 0 0))",
    ));
    try expectError(error.Unsupported, runtime.evalString(
        "(trans (stack (stack 1 2) (stack 3 4)) (stack 2 0))",
    ));
}

test "proto: chunk adds the group axis" {
    var runtime = try newRt();
    defer runtime.deinit();
    // Column-wise: the chunk axis is the new leading axis; leading cells
    // are contiguous runs, so chunk is a shape re-interpretation — chunk
    // 0 = [1 2], chunk 1 = [3 4].
    try expectEqualStrings("[[1 2] [3 4]]", try format(runtime, try runtime.evalString("(chunk 2 (stack 1 2 3 4))")));
    try expectEqualStrings("[[1 2 3]]", try format(runtime, try runtime.evalString("(chunk 3 (stack 1 2 3))")));
    try expectError(error.ArityMismatch, runtime.evalString("(chunk 3 (stack 1 2 3 4))"));
    try expectError(error.Unsupported, runtime.evalString("(chunk 0 (stack 1 2))"));
}

test "proto: part splits by predicate" {
    var runtime = try newRt();
    defer runtime.deinit();
    const v = try runtime.evalString("(part (stack 1 2 3 4) (fn (x) (> x 2)))");
    try expect(skript.Value.isCons(v));
    const cell = v.obj.toRef().deref([2]Value);
    try expectEqualStrings("[3 4]", try format(runtime, cell[0]));
    try expectEqualStrings("[1 2]", try format(runtime, cell[1]));
}

test "proto: take/drop slice with clipping and negatives" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectEqualStrings("[1 2]", try format(runtime, try runtime.evalString("(take 2 (stack 1 2 3 4))")));
    try expectEqualStrings("[1 2 3 4]", try format(runtime, try runtime.evalString("(take 9 (stack 1 2 3 4))")));
    try expectEqualStrings("[3 4]", try format(runtime, try runtime.evalString("(take -2 (stack 1 2 3 4))")));
    try expectEqualStrings("[]", try format(runtime, try runtime.evalString("(take 0 (stack 1 2 3 4))")));
    try expectEqualStrings("[3 4]", try format(runtime, try runtime.evalString("(drop 2 (stack 1 2 3 4))")));
    try expectEqualStrings("[]", try format(runtime, try runtime.evalString("(drop 9 (stack 1 2 3 4))")));
    try expectEqualStrings("[1 2]", try format(runtime, try runtime.evalString("(drop -2 (stack 1 2 3 4))")));
    // Axis form on a matrix: take rows / take columns.
    try expectEqualStrings("[[1 2]]", try format(runtime, try runtime.evalString(
        "(take 1 (stack (stack 1 2) (stack 3 4)))",
    )));
    try expectEqualStrings("[[1] [3]]", try format(runtime, try runtime.evalString(
        "(take 1 (stack (stack 1 2) (stack 3 4)) 1)",
    )));
}

test "proto: cat joins along the leading axis" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectEqualStrings("[1 2 3 4]", try format(runtime, try runtime.evalString(
        "(cat (stack 1 2) (stack 3 4))",
    )));
    // Column-major interleave: rows of the result keep each operand's row.
    // Column-major join: leading elements interleave word by word, so the
    // result rows stay per-operand: [[1 2] [3 4]] ++ [[5 6]].
    try expectEqualStrings("[[1 2] [3 4] [5 6]]", try format(runtime, try runtime.evalString(
        "(cat (stack (stack 1 2) (stack 3 4)) (stack (stack 5 6)))",
    )));
    try expectError(error.ArityMismatch, runtime.evalString(
        "(cat (stack (stack 1 2) (stack 3 4)) (stack (stack 5 6 7)))",
    ));
    try expectError(error.TypeMismatch, runtime.evalString("(cat (stack 1) (stack 1.5))"));
    try expectEqualStrings("[1]", try format(runtime, try runtime.evalString("(cat (stack) (stack 1))")));
}

test "proto: rev and rot along an axis" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectEqualStrings("[3 2 1]", try format(runtime, try runtime.evalString("(rev (stack 1 2 3))")));
    try expectEqualStrings("[[3 4] [1 2]]", try format(runtime, try runtime.evalString(
        "(rev (stack (stack 1 2) (stack 3 4)))",
    )));
    try expectEqualStrings("[[2 1] [4 3]]", try format(runtime, try runtime.evalString(
        "(rev (stack (stack 1 2) (stack 3 4)) 1)",
    )));
    try expectEqualStrings("[2 3 1]", try format(runtime, try runtime.evalString("(rot 1 (stack 1 2 3))")));
    try expectEqualStrings("[3 1 2]", try format(runtime, try runtime.evalString("(rot -1 (stack 1 2 3))")));
    try expectEqualStrings("[2 3 1]", try format(runtime, try runtime.evalString("(rot 4 (stack 1 2 3))")));
    try expectEqualStrings("[1 2 3]", try format(runtime, try runtime.evalString("(rot 0 (stack 1 2 3))")));
}

test "proto: outer builds the table product" {
    var runtime = try newRt();
    defer runtime.deinit();
    // (i, j) = a[i]*b[j]; column-wise: [[3 4 5] [6 8 10]].
    try expectEqualStrings("[[3 4 5] [6 8 10]]", try format(runtime, try runtime.evalString(
        "(outer (stack 1 2) (stack 3 4 5) *)",
    )));
    try expectEqualStrings("[[0 1 2] [10 11 12]]", try format(runtime, try runtime.evalString(
        "(outer (stack 0 10) (stack 0 1 2) +)",
    )));
    try expectError(error.Unsupported, runtime.evalString(
        "(outer (stack (stack 1 2)) (stack 3 4) *)",
    ));
}

test "proto: dot is the inner product" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectEqual(Value.i64(32), try runtime.evalString("(dot (stack 1 2 3) (stack 4 5 6))"));
    try expectEqual(Value.f64(32.0), try runtime.evalString("(dot (stack 1.0 2.0 3.0) (stack 4.0 5.0 6.0))"));
    try expectEqualStrings("[[19 22] [43 50]]", try format(runtime, try runtime.evalString(
        "(dot (stack (stack 1 2) (stack 3 4)) (stack (stack 5 6) (stack 7 8)))",
    )));
    try expectError(error.ArityMismatch, runtime.evalString("(dot (stack 1 2) (stack 4 5 6))"));
    // Matrix contraction mismatch: [2,2] x [3,2] — b.shape[0] != a.shape[1].
    try expectError(error.ArityMismatch, runtime.evalString(
        "(dot (stack (stack 1 2) (stack 3 4)) (stack (stack 5 6) (stack 7 8) (stack 9 1)))",
    ));
    // Vector length mismatch.
    try expectError(error.Unsupported, runtime.evalString("(dot (stack \"a\") (stack \"b\"))"));
}

test "proto: zip stacks pairs into a last axis" {
    var runtime = try newRt();
    defer runtime.deinit();
    // Column-wise: the pair axis is the new LAST axis (fastest), so each
    // pair (a[j] b[j]) is a contiguous leading slice: [[1 4] [2 5] [3 6]].
    try expectEqualStrings("[[1 4] [2 5] [3 6]]", try format(runtime, try runtime.evalString(
        "(zip (stack 1 2 3) (stack 4 5 6))",
    )));
    // Truncates to the shorter.
    try expectEqualStrings("[[1 4] [2 5]]", try format(runtime, try runtime.evalString(
        "(zip (stack 1 2) (stack 4 5 6))",
    )));
    try expectError(error.TypeMismatch, runtime.evalString("(zip (stack 1) (stack 1.5))"));
}

test "map2 broadcasts trailing axes and skips empty output callbacks" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectEqualStrings("[5 7 9]", try format(runtime, try runtime.evalString(
        "(map2 (stack 1 2 3) (stack 4 5 6) +)",
    )));
    try expectEqualStrings("[[11 22 33] [14 25 36]]", try format(runtime, try runtime.evalString(
        "(map2 [[1 2 3] [4 5 6]] [10 20 30] +)",
    )));
    try expectEqualStrings("[[11 21 31] [12 22 32]]", try format(runtime, try runtime.evalString(
        "(map2 (reshape (stack 1 2) (stack 2 1)) " ++
            "(reshape (stack 10 20 30) (stack 1 3)) +)",
    )));
    const empty = try runtime.evalString(
        "(map2 (reshape (iota 0) (stack 2 0 3)) " ++
            "(reshape (stack 10 20 30) (stack 1 1 3)) +)",
    );
    const empty_holder = empty.obj.toRef().deref(TensorHolder);
    try expectEqualSlices(u32, &.{ 2, 0, 3 }, empty_holder.shape);
    try expectEqual(InnerType.empty, empty_holder.inner);
    try expectEqual(@as(usize, 0), empty_holder.data.len);
    try expectError(error.Unsupported, runtime.evalString(
        "(map2 (reshape (iota 0) (stack 0)) (stack 1 2) +)",
    ));
    try expectError(error.Unsupported, runtime.evalString(
        "(map2 (stack 1 2) (stack 4 5 6) +)",
    ));
}

test "map2 releases temporary output when a later callback result is invalid" {
    var runtime = try newRt();
    defer runtime.deinit();

    const left = try runtime.evalString("(stack 1 2)");
    const right = try runtime.evalString("(stack 3 4)");
    const callback = try runtime.evalString("(fn (x y) (if (= x 2) (list x y) (+ x y)))");
    const raw_before = runtime.store.stats().raw_allocations;
    try expectError(error.TypeMismatch, map2(runtime.context(), runtime.root_ns, .nil, &.{ left, right, callback }));
    try expectEqual(raw_before, runtime.store.stats().raw_allocations);
}

test "tensor failures release untransferred data and preserve earlier tensors" {
    var runtime = try newRt();
    defer runtime.deinit();
    const previous = try runtime.evalString("(stack 7 8)");
    const matrix = try runtime.evalString("(stack (stack 1 2) (stack 3 4))");
    const vector = try runtime.evalString("(stack 1 2)");
    const bad_fold = try runtime.evalString("(fn (x y) (list x y))");
    const bad_scan = try runtime.evalString("(fn (x y) (list x y))");
    const bad_map = try runtime.evalString("(fn (x) (if (= x 2) (list x) x))");
    const bad_outer = try runtime.evalString("(fn (x y) (if (= y 2) (list x y) (+ x y)))");
    const raw_before = runtime.store.stats().raw_allocations;

    try expectError(error.TypeMismatch, create(runtime.context(), .nil, .nil, &.{
        .i64(1), .f64(2.0),
    }));
    try expectEqual(raw_before, runtime.store.stats().raw_allocations);
    try expectError(error.TypeMismatch, fold(runtime.context(), runtime.root_ns, .nil, &.{
        matrix, .i64(1), bad_fold,
    }));
    try expectEqual(raw_before, runtime.store.stats().raw_allocations);
    try expectError(error.TypeMismatch, scan(runtime.context(), runtime.root_ns, .nil, &.{
        vector, bad_scan,
    }));
    try expectEqual(raw_before, runtime.store.stats().raw_allocations);
    try expectError(error.TypeMismatch, map(runtime.context(), runtime.root_ns, .nil, &.{
        vector, bad_map,
    }));
    try expectEqual(raw_before, runtime.store.stats().raw_allocations);
    try expectError(error.TypeMismatch, outer(runtime.context(), runtime.root_ns, .nil, &.{
        vector, vector, bad_outer,
    }));
    try expectEqual(raw_before, runtime.store.stats().raw_allocations);
    try expectEqual(Value.i64(8), try tensorGet(runtime.context(), .nil, .nil, &.{
        previous, .i64(1),
    }));
}

test "tensor output shape is freed when work exhausts after allocation" {
    var runtime = try newRt();
    defer runtime.deinit();
    const previous = try runtime.evalString("(stack 7 8)");
    const other = try runtime.evalString("(stack 9 10)");
    const raw_before = runtime.store.stats().raw_allocations;

    {
        const Budget = EvalContext.Budget;
        var budget = Budget.init(runtime.io, 1, .{ .work = 1 });
        var lease = try Budget.Lease.root(&budget, 1);
        var ctx = runtime.context().*;
        ctx.lease = &lease;

        try expectError(error.Exhausted, cat(&ctx, .nil, .nil, &.{ previous, other }));
        const report = budget.report() orelse return error.TestUnexpectedResult;
        try expectEqual(Budget.Resource.work, report.resource);
        try expectEqual(Budget.Backend.native, report.backend);
    }

    try expectEqual(raw_before, runtime.store.stats().raw_allocations);
    try expectEqual(Value.i64(8), try tensorGet(runtime.context(), .nil, .nil, &.{
        previous, .i64(1),
    }));
}

const PartitionTestReentry = struct {
    calls: usize = 0,

    fn apply(raw: *anyopaque, _: *EvalContext, _: Value, _: Value, _: []const Value) Error!Value {
        const self: *PartitionTestReentry = @ptrCast(@alignCast(raw));
        const result = if (self.calls == 0) Value.true else Value.false;
        self.calls += 1;
        return result;
    }

    fn source(_: *anyopaque, _: *EvalContext, _: []const u8) Error!Value {
        return error.Unbound;
    }

    fn lookup(_: *anyopaque, _: *EvalContext, _: Value, _: Sym) Error!Value {
        return error.Unbound;
    }
};

test "partition releases unpublished first tensor when later work exhausts" {
    var runtime = try newRt();
    defer runtime.deinit();
    const previous = try runtime.evalString("(stack 7 8)");
    const input = try runtime.evalString("(stack 1 2)");
    const raw_before = runtime.store.stats().raw_allocations;
    const live_before = runtime.store.stats().live_objects;

    {
        const Budget = EvalContext.Budget;
        var budget = Budget.init(runtime.io, 1, .{ .work = 3 });
        var lease = try Budget.Lease.root(&budget, 3);
        var ctx = runtime.context().*;
        ctx.lease = &lease;
        var predicate: PartitionTestReentry = .{};
        ctx.reentry = .{
            .state = &predicate,
            .apply = PartitionTestReentry.apply,
            .source = PartitionTestReentry.source,
            .lookup = PartitionTestReentry.lookup,
        };

        try expectError(error.Exhausted, part(&ctx, runtime.root_ns, .nil, &.{
            input, .nil,
        }));
        try expectEqual(@as(usize, 2), predicate.calls);
        const report = budget.report() orelse return error.TestUnexpectedResult;
        try expectEqual(Budget.Resource.work, report.resource);
        try expectEqual(Budget.Backend.native, report.backend);
    }

    try expectEqual(raw_before, runtime.store.stats().raw_allocations);
    try expectEqual(live_before, runtime.store.stats().live_objects);
    try expectEqual(Value.i64(8), try tensorGet(runtime.context(), .nil, .nil, &.{
        previous, .i64(1),
    }));
}

test "proto: max/min fold and pair elementwise" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectEqual(Value.i64(3), try runtime.evalString("(max (stack 1 3 2))"));
    try expectEqual(Value.i64(1), try runtime.evalString("(min (stack 1 3 2))"));
    try expectEqual(Value.f64(2.5), try runtime.evalString("(max (stack 1.5 2.5))"));
    try expectEqualStrings("[3 5]", try format(runtime, try runtime.evalString(
        "(max (stack 1 5) (stack 3 2))",
    )));
    try expectEqualStrings("[1 2]", try format(runtime, try runtime.evalString(
        "(min (stack 1 5) (stack 3 2))",
    )));
    try expectError(error.Unsupported, runtime.evalString("(max (stack \"a\" \"b\"))"));
    try expectError(error.Unsupported, runtime.evalString("(max (stack 1 2) (stack 3 4 5))"));
}

test "proto: axis resolution rejects bad axes" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectError(error.Unsupported, runtime.evalString("(scan (stack 1 2 3) 5 +)"));
    try expectError(error.Unsupported, runtime.evalString("(scan (stack 1 2 3) -3 +)"));
    try expectError(error.Unsupported, runtime.evalString("(rot 1 (stack 1 2) 2)"));
    try expectError(error.TypeMismatch, runtime.evalString("(take 2 (stack 1 2) 1.5)"));
}
test "tensor Store backing retains string and symbol payloads" {
    var runtime = try newRt();
    defer runtime.deinit();

    const context = runtime.context();
    const string = try skript.intrinsics.string.storeString(context, "tensor-string");
    const string_tensor = try create(context, .nil, .nil, &.{string});
    const symbol = Value.symbol(try runtime.store.getsym("tensor-symbol"));
    const symbol_tensor = try create(context, .nil, .nil, &.{symbol});
    var string_root = skript.Store.Root.init(string_tensor.obj.toRef());
    var symbol_root = skript.Store.Root.init(symbol_tensor.obj.toRef());
    try runtime.store.registerRoot(&string_root);
    defer runtime.store.unregisterRoot(&string_root) catch unreachable;
    try runtime.store.registerRoot(&symbol_root);
    defer runtime.store.unregisterRoot(&symbol_root) catch unreachable;

    try std.testing.expectEqual(@as(usize, 0), runtime.store.stats().raw_allocations);
    try runtime.store.collect(runtime.store.assumeStopped());

    const string_value = wordToValue(
        .string,
        string_tensor.obj.toRef().deref(TensorHolder).data[0],
    );
    try std.testing.expectEqualStrings(
        "tensor-string",
        try context.stringBytes(
            string_value.obj.toPtr([*:0]const u8),
            std.math.maxInt(usize),
            .native,
        ),
    );
    try std.testing.expectEqual(
        symbol.obj,
        wordToValue(.symbol, symbol_tensor.obj.toRef().deref(TensorHolder).data[0]).obj,
    );
}

test "reshaped tensor keeps aliased data after the source dies" {
    var runtime = try newRt();
    defer runtime.deinit();

    const context = runtime.context();
    const source = try create(context, .nil, .nil, &.{
        Value.i64(3),
        Value.i64(4),
        Value.i64(5),
        Value.i64(6),
    });
    const dimensions = try create(context, .nil, .nil, &.{ Value.i64(2), Value.i64(2) });
    const reshaped = try reshape(context, .nil, .nil, &.{ source, dimensions });
    const source_data_address = @intFromPtr(source.obj.toRef().deref(TensorHolder).data.ptr);
    var root = skript.Store.Root.init(reshaped.obj.toRef());
    try runtime.store.registerRoot(&root);
    defer runtime.store.unregisterRoot(&root) catch unreachable;

    try std.testing.expectEqual(@as(usize, 0), runtime.store.stats().raw_allocations);
    try runtime.store.collect(runtime.store.assumeStopped());

    const result = reshaped.obj.toRef().deref(TensorHolder);
    try std.testing.expectEqual(source_data_address, @intFromPtr(result.data.ptr));
    try std.testing.expectEqual(Value.i64(5), try tensorGet(context, .nil, .nil, &.{
        reshaped,
        Value.i64(1),
        Value.i64(0),
    }));
}

test "unreachable tensor backing is reclaimed and reused" {
    var runtime = try newRt();
    defer runtime.deinit();

    var inputs: [64]Value = undefined;
    for (&inputs, 0..) |*input, index| input.* = Value.i64(@intCast(index));

    const live_before = runtime.store.stats().live_objects;
    _ = try create(runtime.context(), .nil, .nil, &inputs);
    try std.testing.expectEqual(@as(usize, 0), runtime.store.stats().raw_allocations);
    try runtime.store.collect(runtime.store.assumeStopped());
    try std.testing.expectEqual(live_before, runtime.store.stats().live_objects);

    const folios_after_collection = runtime.store.stats().folio_count;
    const replacement = try create(runtime.context(), .nil, .nil, &inputs);
    try std.testing.expectEqual(folios_after_collection, runtime.store.stats().folio_count);
    try std.testing.expectEqual(Value.i64(63), try tensorGet(
        runtime.context(),
        .nil,
        .nil,
        &.{ replacement, Value.i64(63) },
    ));
}

test "collection rejects a tensor view extending past its typed backing" {
    const runtime = try newRt();
    defer runtime.deinit();
    const shape = try runtime.store.allocSlice(u32, 1);
    shape.slice[0] = 2;
    const backing = try runtime.store.allocSlice(u64, 1);
    backing.slice[0] = 7;
    const ref = try runtime.store.createTraced(TensorHolder, traceTensorHolder);
    ref.deref(TensorHolder).* = .{
        .inner = .i64,
        .rank = 1,
        .shape = shape.slice,
        .data = backing.slice.ptr[0..2],
        .shape_ref = shape.ref,
        .data_ref = backing.ref,
    };
    var root = skript.Store.Root.init(ref);
    try runtime.store.registerRoot(&root);
    defer runtime.store.unregisterRoot(&root) catch unreachable;

    try std.testing.expectError(error.InvalidRef, runtime.collect());
    try std.testing.expectEqual(@as(u64, 7), backing.slice[0]);
}
