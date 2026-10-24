const std = @import("std");

const skript = @import("../root.zig");
const Value = skript.Value;
const Sym = skript.Sym;
const Error = skript.Error;
const Runtime = skript.Runtime;
const EvalContext = skript.EvalContext;

const intrin = @import("root.zig");
const tracy = @import("tracy");

pub fn cons(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    const z = tracy.Zone.begin(.{ .name = "cons", .src = @src() });
    defer z.end();
    try intrin.arityAssert(args, 2);
    const ref = try ctx.runtime.store.create([2]Value);
    const ptr = ref.deref([2]Value);
    ptr[0] = args[0];
    ptr[1] = args[1];
    return Value.cons(ref.toObject());
}

pub fn fst(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    const obj = args[0];
    try intrin.typeAssert(obj, skript.builtins.type_cons);
    const ref = obj.obj.toRef();
    const ptr = ref.deref([2]Value);
    return ptr[0];
}

pub fn rst(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    const obj = args[0];
    try intrin.typeAssert(obj, skript.builtins.type_cons);
    const ref = obj.obj.toRef();
    const ptr = ref.deref([2]Value);
    return ptr[1];
}

pub fn list(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    if (args.len == 0) return .nil;
    try chargeWork(ctx, args.len);
    const ref = try ctx.runtime.store.create([2]Value);
    const start = Value.cons(ref.toObject());
    var cell = ref.deref([2]Value);
    cell[0] = args[0];
    for (args[1..]) |arg| {
        const next_ref = try ctx.runtime.store.create([2]Value);
        cell[1] = Value.cons(next_ref.toObject());
        cell = next_ref.deref([2]Value);
        cell[0] = arg;
    }
    cell[1] = .nil;
    return start;
}

/// The inline values borrow caller storage; only `owned` survives a suspended call.
pub const ApplyArguments = struct {
    target: Value,
    values: []Value,
    owned: []Value = &.{},
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ApplyArguments) void {
        if (self.owned.len != 0) self.allocator.free(self.owned);
        self.* = undefined;
    }
};

/// `(apply target arg ... final-list)` expands only the final, finite proper list.
/// Work is charged once per traversed cell, including on malformed and cyclic input.
pub fn expandApplyArguments(
    ctx: *EvalContext,
    args: []const Value,
    inline_storage: []Value,
) Error!ApplyArguments {
    if (args.len < 2) return error.ArityMismatch;
    var slow = args[args.len - 1];
    var fast = slow;
    var spread_count: usize = 0;
    while (slow.typ == skript.builtins.type_cons) {
        try chargeWork(ctx, 1);
        if (slow.obj == .null) return error.TypeMismatch;
        spread_count = std.math.add(usize, spread_count, 1) catch return error.Unsupported;
        slow = slow.obj.toRef().deref([2]Value)[1];
        if (fast.typ == skript.builtins.type_cons) {
            if (fast.obj == .null) return error.TypeMismatch;
            fast = fast.obj.toRef().deref([2]Value)[1];
            if (fast.typ == skript.builtins.type_cons) {
                if (fast.obj == .null) return error.TypeMismatch;
                fast = fast.obj.toRef().deref([2]Value)[1];
            } else if (fast.typ != skript.builtins.type_nil) return error.TypeMismatch;
        } else if (fast.typ != skript.builtins.type_nil) return error.TypeMismatch;
        if (fast.typ == skript.builtins.type_cons and
            slow.typ == skript.builtins.type_cons and fast.obj == slow.obj)
        {
            return error.TypeMismatch;
        }
    }
    if (slow.typ != skript.builtins.type_nil) return error.TypeMismatch;
    const positional_count = args.len - 2;
    const total = std.math.add(usize, positional_count, spread_count) catch return error.Unsupported;
    const owned = if (total > inline_storage.len)
        try ctx.scratch.alloc(Value, total)
    else
        @as([]Value, &.{});
    const values = if (owned.len != 0) owned else inline_storage[0..total];
    @memcpy(values[0..positional_count], args[1 .. args.len - 1]);
    var cursor = args[args.len - 1];
    for (values[positional_count..]) |*out| {
        const pair = cursor.obj.toRef().deref([2]Value);
        out.* = pair[0];
        cursor = pair[1];
    }
    return .{ .target = args[0], .values = values, .owned = owned, .allocator = ctx.scratch };
}

/// Synchronous host callback path. The register VM intercepts this intrinsic
/// before native dispatch so a suspended target never replays argument expansion.
pub fn apply(ctx: *EvalContext, ns: Value, _: Value, args: []const Value) Error!Value {
    var inline_storage: [32]Value = undefined;
    var expanded = try expandApplyArguments(ctx, args, &inline_storage);
    defer expanded.deinit();
    return ctx.apply(ns, expanded.target, expanded.values);
}

// --- collection algorithms (03-collections-algorithms.md TIER-1) ---
// All kernels take proper cons lists: nil is a valid empty list everywhere
// (spec §0.3). A cdr that is neither cons nor nil (improper list) is
// error.TypeMismatch. Results are freshly allocated; inputs never mutated.

fn chargeWork(ctx: *EvalContext, count: usize) Error!void {
    const count_u64 = std.math.cast(u64, count) orelse return error.Unsupported;
    try ctx.chargeWork(count_u64, 1, .native);
}

/// True for a proper-list argument: nil or a cons cell (spec §0.3).
fn isListVal(v: Value) bool {
    return v.typ == skript.builtins.type_cons or v.typ == skript.builtins.type_nil;
}

/// Walk the cdr chain once and return the element count. Improper tail or a
/// non-list argument → error.TypeMismatch. nil → 0.
fn listLength(ctx: *EvalContext, value: Value) Error!usize {
    var current = value;
    var count: usize = 0;
    while (current.typ == skript.builtins.type_cons) {
        try chargeWork(ctx, 1);
        count = std.math.add(usize, count, 1) catch return error.Unsupported;
        current = current.obj.toRef().deref([2]Value)[1];
    }
    if (current.typ != skript.builtins.type_nil) return error.TypeMismatch;
    return count;
}

/// Read the complete NUL-terminated bytes of a string Value.
fn valueStringBytes(ctx: *const EvalContext, value: Value) Error![:0]const u8 {
    return ctx.stringBytes(
        value.obj.toPtr([*:0]const u8),
        std.math.maxInt(usize),
        .native,
    );
}

/// Cons-cell walk cap for `elemEqual` (cyclic lists → error.Unsupported;
/// unreachable through the language — cons cells are immutable — defensive).
const elem_equal_walk_cap: usize = 10_000;

/// Same-type element equality (spec §0.5; the `equal?` workstream gap 14
/// will reimplement this on top of itself). No cross-type coercion (gap 16).
/// - integers/floats: value-equal within the same type tag
/// - bool: equal; string: content equal; symbol/keyword: interned identity
/// - nil: equal; cons: recursive car/cdr walk under the walk cap
/// - tensor: delegates to tensor.tensorEq
/// - everything else: object identity
fn elemEqual(ctx: *EvalContext, a: Value, b: Value, budget: *usize) Error!bool {
    if (a.typ != b.typ) return false;
    switch (a.typ) {
        skript.builtins.type_i64 => return a.obj.toInt(i64) == b.obj.toInt(i64),
        skript.builtins.type_i32 => return a.obj.toInt(i32) == b.obj.toInt(i32),
        skript.builtins.type_i16 => return a.obj.toInt(i16) == b.obj.toInt(i16),
        skript.builtins.type_i8 => return a.obj.toInt(i8) == b.obj.toInt(i8),
        skript.builtins.type_u64 => return a.obj.toInt(u64) == b.obj.toInt(u64),
        skript.builtins.type_u32 => return a.obj.toInt(u32) == b.obj.toInt(u32),
        skript.builtins.type_u16 => return a.obj.toInt(u16) == b.obj.toInt(u16),
        skript.builtins.type_u8 => return a.obj.toInt(u8) == b.obj.toInt(u8),
        skript.builtins.type_f64 => return a.obj.tof64() == b.obj.tof64(),
        skript.builtins.type_f32 => return a.obj.tof32() == b.obj.tof32(),
        skript.builtins.type_f16 => return a.obj.tof16() == b.obj.tof16(),
        skript.builtins.type_bool => return a.obj.toBool() == b.obj.toBool(),
        skript.builtins.type_string => {
            const a_bytes = try valueStringBytes(ctx, a);
            const b_bytes = try valueStringBytes(ctx, b);
            try chargeWork(ctx, @max(a_bytes.len, b_bytes.len));
            return std.mem.eql(u8, a_bytes, b_bytes);
        },
        skript.builtins.type_symbol, skript.builtins.type_keyword => {
            return a.obj.toPtr(Sym) == b.obj.toPtr(Sym);
        },
        skript.builtins.type_nil => return true,
        skript.builtins.type_cons => {
            if (budget.* == 0) return error.Unsupported;
            try chargeWork(ctx, 1);
            budget.* -= 1;
            const a_pair = a.obj.toRef().deref([2]Value).*;
            const b_pair = b.obj.toRef().deref([2]Value).*;
            var car_context = try ctx.enter(.native);
            if (!try elemEqual(&car_context, a_pair[0], b_pair[0], budget)) return false;
            var cdr_context = try ctx.enter(.native);
            return elemEqual(&cdr_context, a_pair[1], b_pair[1], budget);
        },
        skript.builtins.type_tensor => {
            const result = try intrin.tensor.tensorEq(ctx, .nil, .nil, &.{ a, b });
            return result.obj.toBool();
        },
        // Stored/callable values (map, closure, intrinsic, method, namespace,
        // pid, opaque, …): object identity.
        else => return a.obj == b.obj,
    }
}

fn orderToI8(o: std.math.Order) i8 {
    return switch (o) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

/// Total ordering for sort (spec §0.5): same-type i64/f64 numeric, string /
/// symbol / keyword by name bytes, bool false < true. The caller validates
/// that both values have the same sortable type before comparison.
/// Compare is total: < 0 iff less, 0 iff equal, > 0 iff greater.
fn elemCmp(a: Value, b: Value, a_bytes: []const u8, b_bytes: []const u8) i8 {
    std.debug.assert(a.typ == b.typ);
    switch (a.typ) {
        skript.builtins.type_i64 => {
            const x = a.obj.toInt(i64);
            const y = b.obj.toInt(i64);
            return if (x < y) -1 else if (x > y) 1 else 0;
        },
        skript.builtins.type_f64 => {
            const x = a.obj.tof64();
            const y = b.obj.tof64();
            return if (x < y) -1 else if (x > y) 1 else 0;
        },
        skript.builtins.type_string,
        skript.builtins.type_symbol,
        skript.builtins.type_keyword,
        => return orderToI8(std.mem.order(u8, a_bytes, b_bytes)),
        skript.builtins.type_bool => {
            const x = a.obj.toBool();
            const y = b.obj.toBool();
            return if (x == y) 0 else if (!x) -1 else 1; // false < true
        },
        else => unreachable,
    }
}

/// `(fold lst fn)` / `(fold lst init fn)` — left fold. Without init, the
/// accumulator starts with the first element. With init, it starts with init
/// and applies fn to every element from left to right.
/// `(fold nil fn)` returns Unsupported; `(fold nil init fn)` returns init.
/// The callback is the final argument.
pub fn listFold(ctx: *EvalContext, ns: Value, _: Value, args: []const Value) Error!Value {
    if (args.len < 2 or args.len > 3) return error.ArityMismatch;
    if (!isListVal(args[0])) return error.TypeMismatch;
    if (args[0].typ == skript.builtins.type_nil) {
        if (args.len == 2) return error.Unsupported;
        return args[1];
    }
    const func = if (args.len == 3) args[2] else args[1];
    var accumulator: Value = undefined;
    var current: Value = undefined;
    if (args.len == 3) {
        accumulator = args[1];
        current = args[0];
    } else {
        const first = args[0].obj.toRef().deref([2]Value).*;
        accumulator = first[0];
        current = first[1];
    }
    while (current.typ == skript.builtins.type_cons) {
        try chargeWork(ctx, 1);
        const pair = current.obj.toRef().deref([2]Value).*;
        accumulator = try ctx.apply(ns, func, &.{ accumulator, pair[0] });
        current = pair[1];
    }
    if (current.typ != skript.builtins.type_nil) return error.TypeMismatch;
    return accumulator;
}

/// `(scan lst fn)` — inclusive prefix fold (scanl1, AlgoId 4): result
/// element i is the fold of elements 0..i. Seeds the accumulator with the
/// first element (fn is never called for it); `(scan nil fn)` → nil; a
/// single-element list yields that element. Improper list → TypeMismatch.
pub fn listScan(ctx: *EvalContext, ns: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    if (!isListVal(args[0])) return error.TypeMismatch;
    if (args[0].typ == skript.builtins.type_nil) return .nil;
    const head_ref = try ctx.runtime.store.create([2]Value);
    const head = Value.cons(head_ref.toObject());
    var cell = head_ref.deref([2]Value);
    // SAFETY: the non-empty-list check guarantees assignment on the first loop iteration.
    var accumulator: Value = undefined;
    var first = true;
    var current = args[0];
    while (current.typ == skript.builtins.type_cons) {
        try chargeWork(ctx, 1);
        const pair = current.obj.toRef().deref([2]Value).*;
        if (first) {
            accumulator = pair[0];
            first = false;
        } else {
            accumulator = try ctx.apply(ns, args[1], &.{ accumulator, pair[0] });
        }
        cell[0] = accumulator;
        current = pair[1];
        if (current.typ == skript.builtins.type_cons) {
            const next_ref = try ctx.runtime.store.create([2]Value);
            cell[1] = Value.cons(next_ref.toObject());
            cell = next_ref.deref([2]Value);
        } else if (current.typ == skript.builtins.type_nil) {
            cell[1] = .nil;
        } else {
            return error.TypeMismatch;
        }
    }
    return head;
}

/// `(map lst fn)` — apply fn to each element left-to-right (AlgoId 2).
/// `ctx.apply` raises (error.Unimplemented), matching the tensor contract.
pub fn listMap(ctx: *EvalContext, ns: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    if (!isListVal(args[0])) return error.TypeMismatch;
    if (args[0].typ == skript.builtins.type_nil) return .nil;
    const head_ref = try ctx.runtime.store.create([2]Value);
    const head = Value.cons(head_ref.toObject());
    var cell = head_ref.deref([2]Value);
    var current = args[0];
    while (current.typ == skript.builtins.type_cons) {
        try chargeWork(ctx, 1);
        const pair = current.obj.toRef().deref([2]Value).*;
        cell[0] = try ctx.apply(ns, args[1], &.{pair[0]});
        current = pair[1];
        if (current.typ == skript.builtins.type_cons) {
            const next_ref = try ctx.runtime.store.create([2]Value);
            cell[1] = Value.cons(next_ref.toObject());
            cell = next_ref.deref([2]Value);
        } else if (current.typ == skript.builtins.type_nil) {
            cell[1] = .nil;
        } else {
            return error.TypeMismatch;
        }
    }
    return head;
}

/// `(keep lst pred)` — keep elements for which `(pred elem)` is #t
/// (AlgoId 3, canonical name for filter). Predicate must return type_bool
/// (§0.6) → else error.TypeMismatch (same rule as tensor.keep). Order
/// preserved.
pub fn listKeep(ctx: *EvalContext, ns: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    if (!isListVal(args[0])) return error.TypeMismatch;
    if (args[0].typ == skript.builtins.type_nil) return .nil;
    var head: Value = .nil;
    var tail: *Value = &head;
    var current = args[0];
    while (current.typ == skript.builtins.type_cons) {
        try chargeWork(ctx, 1);
        const pair = current.obj.toRef().deref([2]Value).*;
        const result = try ctx.apply(ns, args[1], &.{pair[0]});
        if (result.typ != skript.builtins.type_bool) return error.TypeMismatch;
        if (result.obj.toBool()) {
            const ref = try ctx.runtime.store.create([2]Value);
            const cell = ref.deref([2]Value);
            cell[0] = pair[0];
            tail.* = Value.cons(ref.toObject());
            tail = &cell[1];
        }
        current = pair[1];
        if (current.typ != skript.builtins.type_cons and current.typ != skript.builtins.type_nil) {
            return error.TypeMismatch;
        }
    }
    tail.* = .nil;
    return head;
}

/// `(concat a b ...)` — N-ary list append (AlgoId 42). `(concat)` → nil;
/// `(concat a)` validates and returns `a`. Prefix cells of all but the last
/// list are copied; the last list is shared by reference.
/// Non-list or improper-list operand → error.TypeMismatch.
pub fn listConcat(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    if (args.len == 0) return .nil;
    for (args) |arg| _ = try listLength(ctx, arg);
    if (args.len == 1) return args[0];
    const last = args[args.len - 1];
    var head: Value = .nil;
    var tail: *Value = &head;
    for (args[0 .. args.len - 1]) |arg| {
        var current = arg;
        while (current.typ == skript.builtins.type_cons) {
            try chargeWork(ctx, 1);
            const pair = current.obj.toRef().deref([2]Value).*;
            const ref = try ctx.runtime.store.create([2]Value);
            const cell = ref.deref([2]Value);
            cell[0] = pair[0];
            tail.* = Value.cons(ref.toObject());
            tail = &cell[1];
            current = pair[1];
        }
    }
    tail.* = last;
    return head;
}

/// `(reverse lst)` — reverse element order (AlgoId 4321). All cells are
/// copied (input immutable; result shares nothing).
pub fn listReverse(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    if (!isListVal(args[0])) return error.TypeMismatch;
    var accumulator: Value = .nil;
    var current = args[0];
    while (current.typ == skript.builtins.type_cons) {
        try chargeWork(ctx, 1);
        const pair = current.obj.toRef().deref([2]Value).*;
        const ref = try ctx.runtime.store.create([2]Value);
        ref.deref([2]Value).* = .{ pair[0], accumulator };
        accumulator = Value.cons(ref.toObject());
        current = pair[1];
    }
    if (current.typ != skript.builtins.type_nil) return error.TypeMismatch;
    return accumulator;
}

pub fn listTake(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    try intrin.typeAssert(args[0], skript.builtins.type_i64);
    if (!isListVal(args[1])) return error.TypeMismatch;
    const n = args[0].obj.toInt(i64);
    const len: i64 = std.math.cast(i64, try listLength(ctx, args[1])) orelse return error.Unsupported;
    var start: i64 = 0;
    var end: i64 = len;
    if (n >= 0) {
        end = @min(n, len);
    } else {
        const len_plus_n = std.math.add(i64, len, n) catch return error.Unsupported;
        start = @max(len_plus_n, 0);
    }
    if (start >= end) return .nil;
    var current = args[1];
    var index: i64 = 0;
    while (index < start) : (index += 1) {
        try chargeWork(ctx, 1);
        current = current.obj.toRef().deref([2]Value)[1];
    }
    var head: Value = .nil;
    var tail: *Value = &head;
    while (index < end) : (index += 1) {
        try chargeWork(ctx, 1);
        const pair = current.obj.toRef().deref([2]Value).*;
        const ref = try ctx.runtime.store.create([2]Value);
        const cell = ref.deref([2]Value);
        cell[0] = pair[0];
        tail.* = Value.cons(ref.toObject());
        tail = &cell[1];
        current = pair[1];
    }
    // Prefix copy: the result terminates at nil — do NOT share the source
    // suffix (that would extend take to the whole remainder).
    tail.* = .nil;
    return head;
}
pub fn listDrop(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    try intrin.typeAssert(args[0], skript.builtins.type_i64);
    if (!isListVal(args[1])) return error.TypeMismatch;
    const n = args[0].obj.toInt(i64);
    const len: i64 = std.math.cast(i64, try listLength(ctx, args[1])) orelse return error.Unsupported;
    if (n >= 0) {
        if (n >= len) return .nil;
        var current = args[1];
        var index: i64 = 0;
        while (index < n) : (index += 1) {
            try chargeWork(ctx, 1);
            current = current.obj.toRef().deref([2]Value)[1];
        }
        return current; // share the remaining tail cells
    }
    const len_plus_n = std.math.add(i64, len, n) catch return error.Unsupported;
    const end = @max(len_plus_n, 0);
    if (end <= 0) return .nil;
    var head: Value = .nil;
    var tail: *Value = &head;
    var current = args[1];
    var index: i64 = 0;
    while (index < end) : (index += 1) {
        try chargeWork(ctx, 1);
        const pair = current.obj.toRef().deref([2]Value).*;
        const ref = try ctx.runtime.store.create([2]Value);
        const cell = ref.deref([2]Value);
        cell[0] = pair[0];
        tail.* = Value.cons(ref.toObject());
        tail = &cell[1];
        current = pair[1];
    }
    tail.* = .nil; // truncate the dropped suffix
    return head;
}

/// `(length lst)` — element count, one left-to-right walk. nil → 0;
/// improper list or non-list → error.TypeMismatch. List-only (registered
/// directly under `length`); the tensor size op is `tensor-len`.
pub fn length(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    const count = try listLength(ctx, args[0]);
    return .i64(std.math.cast(i64, count) orelse return error.Unsupported);
}

/// `(range n)` / `(range a b)` — i64 list [0, n) or [a, b), step 1 (AlgoId 8;
/// the ID-8 majority name `range`; tensor `iota` keeps the rank-1 tensor
/// form). Empty result when n <= 0 or a >= b. Non-i64 args → TypeMismatch.
pub fn range(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    if (args.len < 1 or args.len > 2) return error.ArityMismatch;
    for (args) |arg| try intrin.typeAssert(arg, skript.builtins.type_i64);
    const start = if (args.len == 2) args[0].obj.toInt(i64) else 0;
    const end = if (args.len == 2) args[1].obj.toInt(i64) else args[0].obj.toInt(i64);
    if (start >= end) return .nil;
    const span = std.math.sub(i64, end, start) catch return error.Unsupported;
    const count = std.math.cast(usize, span) orelse return error.Unsupported;
    try chargeWork(ctx, count);
    var head: Value = .nil;
    var tail: *Value = &head;
    var value = start;
    for (0..count) |_| {
        const ref = try ctx.runtime.store.create([2]Value);
        const cell = ref.deref([2]Value);
        cell[0] = .i64(value);
        tail.* = Value.cons(ref.toObject());
        tail = &cell[1];
        value += 1;
    }
    tail.* = .nil;
    return head;
}

/// `(contains? lst x)` — #t iff some element is `elemEqual` to x (AlgoId 17).
/// Left-to-right walk with early exit. No cross-type coercion
/// (`(contains? (list 1.0) 1)` → #f, gap 16); strings compare by content.
pub fn contains(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    if (!isListVal(args[0])) return error.TypeMismatch;
    var current = args[0];
    while (current.typ == skript.builtins.type_cons) {
        try chargeWork(ctx, 1);
        const pair = current.obj.toRef().deref([2]Value).*;
        var budget: usize = elem_equal_walk_cap;
        if (try elemEqual(ctx, pair[0], args[1], &budget)) return .true;
        current = pair[1];
    }
    if (current.typ != skript.builtins.type_nil) return error.TypeMismatch;
    return .false;
}

/// Shared sort comparator; sortImpl pre-validates both values to have the
/// same sortable type tag before std.sort invokes this non-failing callback.
const SortElement = struct {
    value: Value,
    bytes: []const u8,
};

fn sortLessThan(is_desc: bool, a: SortElement, b: SortElement) bool {
    const c = elemCmp(a.value, b.value, a.bytes, b.bytes);
    return if (is_desc) c > 0 else c < 0;
}

/// `(sort-up lst)` / `(sort-dn lst)` — new list sorted by `elemCmp`
/// (AlgoIds 40/39; value-sort reading). Stable (std.sort.block; equal
/// elements keep input order). Mixed types or unordered element types →
/// error.Unsupported (gap 16). nil → nil; singleton → fresh copy.
fn sortImpl(ctx: *EvalContext, args: []const Value, is_desc: bool) Error!Value {
    try intrin.arityAssert(args, 1);
    if (!isListVal(args[0])) return error.TypeMismatch;
    const len = try listLength(ctx, args[0]);
    if (len == 0) return .nil;
    if (len == 1) {
        const pair = args[0].obj.toRef().deref([2]Value).*;
        const ref = try ctx.runtime.store.create([2]Value);
        ref.deref([2]Value).* = .{ pair[0], .nil };
        return .cons(ref.toObject());
    }
    const elems = try ctx.runtime.store.allocator().alloc(SortElement, len);
    defer ctx.runtime.store.allocator().free(elems);
    var current = args[0];
    for (elems) |*element| {
        try chargeWork(ctx, 1);
        const pair = current.obj.toRef().deref([2]Value).*;
        element.value = pair[0];
        element.bytes = switch (pair[0].typ) {
            skript.builtins.type_string => try valueStringBytes(ctx, pair[0]),
            skript.builtins.type_symbol, skript.builtins.type_keyword => pair[0].obj.toPtr(Sym).*,
            else => "",
        };
        current = pair[1];
    }
    // Same-type ordering only: all elements must share one sortable tag.
    const tag = elems[0].value.typ;
    switch (tag) {
        skript.builtins.type_i64,
        skript.builtins.type_f64,
        skript.builtins.type_string,
        skript.builtins.type_symbol,
        skript.builtins.type_keyword,
        skript.builtins.type_bool,
        => {},
        else => return error.Unsupported,
    }
    for (elems[1..]) |element| if (element.value.typ != tag) return error.Unsupported;
    // The comparator is a non-failing std.sort callback, so reserve a
    // quadratic comparison bound before entering the sort.
    const comparison_count: u64 = @intCast(len);
    var comparison_cost: u64 = comparison_count;
    if (tag == skript.builtins.type_string or
        tag == skript.builtins.type_symbol or
        tag == skript.builtins.type_keyword)
    {
        for (elems) |element| comparison_cost = @max(comparison_cost, @as(u64, @intCast(element.bytes.len)));
    }
    try ctx.chargeWork(comparison_count, comparison_cost, .native);
    std.mem.sort(SortElement, elems, is_desc, sortLessThan);
    var head: Value = .nil;
    var tail: *Value = &head;
    for (elems) |element| {
        try chargeWork(ctx, 1);
        const ref = try ctx.runtime.store.create([2]Value);
        const cell = ref.deref([2]Value);
        cell[0] = element.value;
        tail.* = Value.cons(ref.toObject());
        tail = &cell[1];
    }
    tail.* = .nil;
    return head;
}

pub fn sortUp(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    return sortImpl(ctx, args, false);
}

pub fn sortDn(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    return sortImpl(ctx, args, true);
}

// --- runtime tests (tensor.zig proto style: full-language evalString) --- //

const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

fn newRt() !*Runtime {
    return Runtime.init(std.testing.allocator, std.testing.io);
}

fn format(rt: *Runtime, v: Value) ![]const u8 {
    const s = try intrin.print.debugFormatBuiltin(rt.context(), .nil, .nil, &.{v});
    return std.mem.sliceTo(s.obj.toPtr([*]u8), 0);
}

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
    }
}

test "apply expands positional values and a proper list without owning inline storage" {
    var runtime = try newRt();
    defer runtime.deinit();
    const ctx = runtime.context();
    const target = try runtime.evalString("(fn (a b c) (+ a (+ b c)))");
    const spread = try list(ctx, .nil, .nil, &.{ Value.i64(2), Value.i64(3) });
    const arguments = [_]Value{ target, Value.i64(1), spread };
    var inline_storage: [4]Value = undefined;
    var expanded = try expandApplyArguments(ctx, &arguments, &inline_storage);
    defer expanded.deinit();
    try expectEqual(target, expanded.target);
    try expectEqual(@as(usize, 0), expanded.owned.len);
    try std.testing.expectEqualSlices(Value, &.{ Value.i64(1), Value.i64(2), Value.i64(3) }, expanded.values);
    try expectEqual(Value.i64(6), try apply(ctx, runtime.root_ns, .nil, &arguments));
    try expectEqual(
        Value.i64(6),
        try apply(ctx, runtime.root_ns, .nil, &.{ target, Value.i64(6), Value.i64(0), Value.i64(0), .nil }),
    );
}

test "apply expands long lists into one owned argument array without an argument byte limit" {
    var runtime = try newRt();
    defer runtime.deinit();
    const ctx = runtime.context();
    const elements: [300]Value = @splat(Value.i64(7));
    const spread = try list(ctx, .nil, .nil, &elements);
    var inline_storage: [2]Value = undefined;
    var expanded = try expandApplyArguments(ctx, &.{ Value.intrinsic(&list), spread }, &inline_storage);
    defer expanded.deinit();
    try expectEqual(@as(usize, 300), expanded.values.len);
    try expectEqual(@as(usize, 300), expanded.owned.len);
    for (expanded.values) |value| try expectEqual(Value.i64(7), value);
}

test "apply rejects missing, improper, and cyclic spreads" {
    var runtime = try newRt();
    defer runtime.deinit();
    const ctx = runtime.context();
    var inline_storage: [4]Value = undefined;
    try expectError(error.ArityMismatch, expandApplyArguments(ctx, &.{Value.intrinsic(&list)}, &inline_storage));
    try expectError(
        error.TypeMismatch,
        expandApplyArguments(ctx, &.{ Value.intrinsic(&list), Value.i64(4) }, &inline_storage),
    );
    try expectError(
        error.TypeMismatch,
        expandApplyArguments(ctx, &.{ Value.intrinsic(&list), Value.cons(.null) }, &inline_storage),
    );
    const improper = try cons(ctx, .nil, .nil, &.{ Value.i64(1), Value.i64(2) });
    try expectError(
        error.TypeMismatch,
        expandApplyArguments(ctx, &.{ Value.intrinsic(&list), improper }, &inline_storage),
    );
    const ref = try runtime.store.create([2]Value);
    const cyclic = Value.cons(ref.toObject());
    ref.deref([2]Value).* = .{ Value.i64(1), cyclic };
    try expectError(
        error.TypeMismatch,
        expandApplyArguments(ctx, &.{ Value.intrinsic(&list), cyclic }, &inline_storage),
    );
}

test "apply traversal exhausts the supplied work budget" {
    var runtime = try newRt();
    defer runtime.deinit();
    const spread = try list(runtime.context(), .nil, .nil, &.{ Value.i64(1), Value.i64(2), Value.i64(3) });
    var budget = EvalContext.Budget.init(runtime.io, 19_541, .{ .work = 2 });
    var lease = try EvalContext.Budget.Lease.root(&budget, 2);
    var account = EvalContext.Budget.AccountAllocator.init(std.testing.allocator, &lease, .native);
    var output_bytes: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_bytes);
    var bounded = try EvalContext.limited(
        runtime,
        runtime.intrinsics.registryVersion(),
        &account,
        .{ .writer = &writer },
        .{},
    );
    var inline_storage: [4]Value = undefined;
    try expectError(
        error.Exhausted,
        expandApplyArguments(&bounded, &.{ Value.intrinsic(&list), spread }, &inline_storage),
    );
    try expect(budget.isExhausted());
}

test "proto: fold dispatches list and tensor" {
    var runtime = try newRt();
    defer runtime.deinit();
    // List folds keep the collection first and the function last; the
    // tensor kernel retains its collection-axis-function form.
    try expectEqual(Value.i64(6), try runtime.evalString("(fold (list 1 2 3) +)"));
    try expectEqual(Value.i64(16), try runtime.evalString("(fold (list 1 2 3) 10 +)"));
    try expectEqual(Value.i64(85), try runtime.evalString("(fold (list 10 3 2) 100 -)"));
    try expectError(error.Unsupported, runtime.evalString("(fold nil +)"));
    try expectEqual(Value.i64(5), try runtime.evalString("(fold nil 5 +)"));
    try expectEqual(Value.i64(6), try runtime.evalString("(fold (stack 1 2 3) +)"));
    try expectEqualStrings("(10 7 5)", try format(runtime, try runtime.evalString("(scan (list 10 3 2) -)")));
    try expectError(error.ArityMismatch, runtime.evalString("(fold 42)"));
    try expectError(error.ArityMismatch, runtime.evalString("(fold (list 1) 0 + 9)"));
}

test "proto: fold rejects improper input" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectError(error.TypeMismatch, runtime.evalString("(fold (cons 1 2) 0 +)"));
}

test "proto: map over cons lists" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectEqualStrings("(2 4 6)", try format(runtime, try runtime.evalString(
        "(map (list 1 2 3) (fn (x) (* x 2)))",
    )));
    // Heterogeneous results: elements are 2-element lists.
    try expectEqualStrings("((1 1) (2 2))", try format(runtime, try runtime.evalString(
        "(map (list 1 2) (fn (x) (list x x)))",
    )));
    try expect(Value.isNil(try runtime.evalString("(map nil (fn (x) x))")));
    // Non-callable fn on the list path: the same error ctx.apply raises
    // (mirrors the tensor test (map (stack 1 2) 3) → error.Unimplemented).
    try expectError(error.Unimplemented, runtime.evalString("(map (list 1 2) 3)"));
}

test "proto: keep filters cons lists" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectEqualStrings("(3 4)", try format(runtime, try runtime.evalString(
        "(keep (list 1 2 3 4) (fn (x) (> x 2)))",
    )));
    try expectEqualStrings("(2 4)", try format(runtime, try runtime.evalString(
        "(keep (list 1 2 3 4) even?)",
    )));
    try expect(Value.isNil(try runtime.evalString("(keep (list 1 2) (fn (x) (> x 9)))")));
    // Predicate must return bool (§0.6) → TypeMismatch.
    try expectError(error.TypeMismatch, runtime.evalString("(keep (list 1 2 3) (fn (x) 1))"));
    try expect(Value.isNil(try runtime.evalString("(keep nil (fn (x) #t))")));
}

test "proto: concat appends cons lists" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectEqualStrings("(1 2 3)", try format(runtime, try runtime.evalString("(concat (list 1 2) (list 3))")));
    try expectEqualStrings("(1 2 3 4)", try format(runtime, try runtime.evalString(
        "(concat (list 1) (list 2) (list 3 4))",
    )));
    try expect(Value.isNil(try runtime.evalString("(concat)")));
    try expectEqualStrings("(1 2)", try format(runtime, try runtime.evalString("(concat (list 1 2))")));
    // Scheme-family alias.
    try expectEqualStrings("(1 2 3)", try format(runtime, try runtime.evalString("(append (list 1) (list 2 3))")));
    // nil operands are transparent.
    try expectEqualStrings("(1)", try format(runtime, try runtime.evalString("(concat nil (list 1))")));
    try expectError(error.TypeMismatch, runtime.evalString("(concat (list 1) 2)"));
    try expectError(error.TypeMismatch, runtime.evalString("(concat (cons 1 2))"));
}

test "proto: reverse copies cons lists" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectEqualStrings("(3 2 1)", try format(runtime, try runtime.evalString("(reverse (list 1 2 3))")));
    try expect(Value.isNil(try runtime.evalString("(reverse nil)")));
    try expectEqualStrings("('a)", try format(runtime, try runtime.evalString("(reverse (list 'a))")));
    try expectEqual(Value.i64(3), try runtime.evalString("(fst (reverse (list 1 2 3)))"));
}

test "proto: take clips and handles negatives" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectEqualStrings("(1 2)", try format(runtime, try runtime.evalString("(take 2 (list 1 2 3 4))")));
    try expectEqualStrings("(1 2 3 4)", try format(runtime, try runtime.evalString("(take 9 (list 1 2 3 4))")));
    try expectEqualStrings("(3 4)", try format(runtime, try runtime.evalString("(take -2 (list 1 2 3 4))")));
    try expect(Value.isNil(try runtime.evalString("(take 0 (list 1 2 3))")));
    try expectError(error.TypeMismatch, runtime.evalString("(take 1.5 (list 1 2))"));
}

test "proto: drop is the mirror of take" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectEqualStrings("(3 4)", try format(runtime, try runtime.evalString("(drop 2 (list 1 2 3 4))")));
    try expect(Value.isNil(try runtime.evalString("(drop 9 (list 1 2))")));
    try expectEqualStrings("(1 2)", try format(runtime, try runtime.evalString("(drop -2 (list 1 2 3 4))")));
    // (drop 0 lst) returns the same object.
    const v = try runtime.evalString("(drop 0 (list 1 2))");
    try expectEqualStrings("(1 2)", try format(runtime, v));
    try expectEqualStrings("(2 3)", try format(runtime, try runtime.evalString("(drop 1 (list 1 2 3))")));
}

test "proto: length counts cons cells" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectEqual(Value.i64(3), try runtime.evalString("(length (list 1 2 3))"));
    try expectEqual(Value.i64(0), try runtime.evalString("(length nil)"));
    // Shallow: nested lists count as one element.
    try expectEqual(Value.i64(2), try runtime.evalString("(length (list (list 1) (list 2 3)))"));
    try expectError(error.TypeMismatch, runtime.evalString("(length 42)"));
}

test "proto: range generates i64 lists" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectEqualStrings("(0 1 2 3)", try format(runtime, try runtime.evalString("(range 4)")));
    try expectEqualStrings("(2 3 4)", try format(runtime, try runtime.evalString("(range 2 5)")));
    try expect(Value.isNil(try runtime.evalString("(range 0)")));
    try expect(Value.isNil(try runtime.evalString("(range -3)")));
    try expect(Value.isNil(try runtime.evalString("(range 4 4)")));
    try expect(Value.isNil(try runtime.evalString("(range 5 2)")));
    try expectError(error.TypeMismatch, runtime.evalString("(range 1.5)"));
}

test "proto: contains? uses same-type element equality" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expect(Value.isBool(try runtime.evalString("(contains? (list 1 2 3) 2)")));
    try expectEqual(Value.true, try runtime.evalString("(contains? (list 1 2 3) 2)"));
    try expectEqual(Value.false, try runtime.evalString("(contains? (list 1 2 3) 9)"));
    // Strings compare by content, not identity.
    try expectEqual(Value.true, try runtime.evalString("(contains? (list \"a\" \"b\") \"a\")"));
    try expectEqual(Value.false, try runtime.evalString("(contains? nil 1)"));
    // No cross-type coercion (gap 16).
    try expectEqual(Value.false, try runtime.evalString("(contains? (list 1.0) 1)"));
    // Symbols by identity (interned), nested lists by structure.
    try expectEqual(Value.true, try runtime.evalString("(contains? (list 'a 'b) 'b)"));
    try expectEqual(Value.false, try runtime.evalString("(contains? (list 'a) :a)"));
    try expectEqual(Value.true, try runtime.evalString("(contains? (list (list 1 2) (list 3)) (list 1 2))"));
}

test "proto: sort-up and sort-dn by elemCmp" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectEqualStrings("(1 2 3)", try format(runtime, try runtime.evalString("(sort-up (list 3 1 2))")));
    try expectEqualStrings("(\"a\" \"b\" \"c\")", try format(runtime, try runtime.evalString(
        "(sort-up (list \"b\" \"a\" \"c\"))",
    )));
    try expectEqualStrings("('a 'b 'c)", try format(runtime, try runtime.evalString("(sort-up (list 'b 'a 'c))")));
    try expectEqualStrings("(#f #f #t)", try format(runtime, try runtime.evalString("(sort-up (list #f #t #f))")));
    try expect(Value.isNil(try runtime.evalString("(sort-up nil)")));
    // Stable: duplicates keep input order.
    try expectEqualStrings("(1 2 2)", try format(runtime, try runtime.evalString("(sort-up (list 2 1 2))")));
    // Mixed numeric types are unordered (gap 16).
    try expectError(error.Unsupported, runtime.evalString("(sort-up (list 1 2.5))"));
    try expectEqualStrings("(3 2 1)", try format(runtime, try runtime.evalString("(sort-dn (list 3 1 2))")));
    try expectEqualStrings("(\"c\" \"b\" \"a\")", try format(runtime, try runtime.evalString(
        "(sort-dn (list \"a\" \"c\" \"b\"))",
    )));
    try expect(Value.isNil(try runtime.evalString("(sort-dn nil)")));
    try expectEqualStrings("(2 1)", try format(runtime, try runtime.evalString("(sort-dn (list 1 2))")));
}

test "proto: compose is right-to-left function composition" {
    var runtime = try newRt();
    defer runtime.deinit();
    try expectEqual(Value.i64(12), try runtime.evalString(
        "((compose (fn (x) (* x 2)) (fn (x) (+ x 1))) 5)",
    ));
    try expectEqual(Value.i64(7), try runtime.evalString(
        "((compose (fn (x) x) (fn (x) x)) 7)",
    ));
}
