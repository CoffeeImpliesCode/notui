//! Dispatch layer for the shared algorithm names
//! (03-collections-algorithms.md §0.4). One visible dispatcher per shared
//! name; the per-type kernels stay in their own modules (list.zig,
//! tensor.zig, map.zig). Tensor kernels are reached with the SAME arg slice
//! they had before re-pointing, so tensor behavior is unchanged (the tensor
//! proto suite is the regression gate).
//!
//! Dispatch rules:
//! - collection-first ops (`keep`, `map`, `concat`, `reverse`) dispatch on
//!   args[0]: cons/nil → list kernel; tensor → tensor kernel.
//! - count-first ops (`take`, `drop`) dispatch on args[1] — the collection —
//!   and forward `(n coll [k])` unchanged to the matching list or tensor kernel.
//! - `cat`/`rev` are the tensor short names and re-point here unchanged.
//! - `fold`/`scan` dispatch on args[0]: cons/nil → list kernel; tensor →
//!   tensor axis kernel. List fold is `(fold lst fn)` or `(fold lst init fn)`.
//!   Tensor fold remains `(fold t fn)` or `(fold t k fn)`. Both forms keep
//!   callbacks last without changing tensor axis semantics.
//! - `length` and `sort-up`/`sort-dn` are list-only and registered directly
//!   to the list kernels in intrinsics.zig.

const std = @import("std");

const skript = @import("../root.zig");
const Value = skript.Value;
const Error = skript.Error;
const Runtime = skript.Runtime;
const EvalContext = skript.EvalContext;

const intrin = @import("root.zig");

/// A proper-list argument: nil or a cons cell (spec §0.3).
fn isList(v: Value) bool {
    return v.typ == skript.builtins.type_cons or v.typ == skript.builtins.type_nil;
}

/// List folds use `(fold lst fn)` or `(fold lst init fn)`. Tensor folds use
/// `(fold t fn)` or `(fold t k fn)`; both keep the callback last.
pub fn fold(ctx: *EvalContext, ns: Value, self: Value, args: []const Value) Error!Value {
    if (args.len < 2 or args.len > 3) return error.ArityMismatch;
    if (isList(args[0])) return intrin.list.listFold(ctx, ns, self, args);
    if (args[0].typ == skript.builtins.type_tensor) return intrin.tensor.fold(ctx, ns, self, args);
    return error.TypeMismatch;
}

/// `(scan coll fn [k])` — inclusive prefix fold. Lists accept two args;
/// tensors retain the optional axis argument.
pub fn scan(ctx: *EvalContext, ns: Value, self: Value, args: []const Value) Error!Value {
    if (args.len < 2 or args.len > 3) return error.ArityMismatch;
    if (isList(args[0])) return intrin.list.listScan(ctx, ns, self, args);
    if (args[0].typ == skript.builtins.type_tensor) return intrin.tensor.scan(ctx, ns, self, args);
    return error.TypeMismatch;
}

/// `(keep coll pred)` — cons/nil uses the list filter; tensors filter
/// leading-axis cells. The predicate is the final argument.
pub fn keep(ctx: *EvalContext, ns: Value, self: Value, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (isList(args[0])) return intrin.list.listKeep(ctx, ns, self, args);
    if (args[0].typ == skript.builtins.type_tensor) return intrin.tensor.keep(ctx, ns, self, args);
    return error.TypeMismatch;
}

/// `(take n coll [k])` — AlgoId 35; COUNT-FIRST (the restored pre-wave
/// tensor order, shared by list take). Dispatch on args[1] — the collection
/// — and forward the unchanged `(n coll [k])` slice to the kernels:
/// cons/nil → list prefix walk; tensor → the tensor slice kernel
/// (identical range math).
pub fn take(ctx: *EvalContext, ns: Value, self: Value, args: []const Value) Error!Value {
    if (args.len < 2 or args.len > 3) return error.ArityMismatch;
    if (isList(args[1])) return intrin.list.listTake(ctx, ns, self, args);
    if (args[1].typ == skript.builtins.type_tensor) return intrin.tensor.take(ctx, ns, self, args);
    return error.TypeMismatch;
}

/// `(drop n coll [k])` — AlgoId 34; COUNT-FIRST mirror of take.
pub fn drop(ctx: *EvalContext, ns: Value, self: Value, args: []const Value) Error!Value {
    if (args.len < 2 or args.len > 3) return error.ArityMismatch;
    if (isList(args[1])) return intrin.list.listDrop(ctx, ns, self, args);
    if (args[1].typ == skript.builtins.type_tensor) return intrin.tensor.drop(ctx, ns, self, args);
    return error.TypeMismatch;
}

/// `(concat a b ...)` — AlgoId 42; N-ary list append. Tensors keep the
/// binary join semantics of the existing `cat` kernel (`(concat)` with no
/// args is the empty list).
pub fn concat(ctx: *EvalContext, ns: Value, self: Value, args: []const Value) Error!Value {
    if (args.len == 0) return intrin.list.listConcat(ctx, ns, self, args);
    if (isList(args[0])) return intrin.list.listConcat(ctx, ns, self, args);
    if (args[0].typ == skript.builtins.type_tensor) return intrin.tensor.cat(ctx, ns, self, args);
    return error.TypeMismatch;
}

/// `(map coll fn [k])` — transform-only dispatch. Lists accept two args;
/// tensors retain the optional axis argument. Dict construction uses
/// `hash-map`.
pub fn map(ctx: *EvalContext, ns: Value, self: Value, args: []const Value) Error!Value {
    if (args.len < 2 or args.len > 3) return error.ArityMismatch;
    if (isList(args[0])) return intrin.list.listMap(ctx, ns, self, args);
    if (args[0].typ == skript.builtins.type_tensor) return intrin.tensor.map(ctx, ns, self, args);
    return error.TypeMismatch;
}

/// `(reverse coll [k])` — AlgoId 4321. cons/nil → list reverse (fresh
/// copy); tensor → the tensor rev kernel (axis-k reversal).
pub fn reverse(ctx: *EvalContext, ns: Value, self: Value, args: []const Value) Error!Value {
    if (args.len == 0) return error.ArityMismatch;
    if (isList(args[0])) return intrin.list.listReverse(ctx, ns, self, args);
    if (args[0].typ == skript.builtins.type_tensor) return intrin.tensor.rev(ctx, ns, self, args);
    return error.TypeMismatch;
}

// --- runtime tests: dispatch routing (stack forwarding is the tensor
// proto suite's job; these pin the list routes and the error fallbacks) --- //

const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
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

test "proto: shared names route list vs tensor (count-first take/drop)" {
    var runtime = try newRt();
    defer runtime.deinit();
    // Lists route to the list kernels through the dispatchers.
    try expectEqualStrings("(3 4)", try format(runtime, try runtime.evalString(
        "(keep (list 1 2 3 4) (fn (x) (> x 2)))",
    )));
    try expectEqualStrings("(1 2)", try format(runtime, try runtime.evalString("(take 2 (list 1 2 3 4))")));
    try expectEqualStrings("(3 4)", try format(runtime, try runtime.evalString("(drop 2 (list 1 2 3 4))")));
    try expectEqualStrings("(1 2 3)", try format(runtime, try runtime.evalString("(concat (list 1) (list 2 3))")));
    try expectEqualStrings("(3 2 1)", try format(runtime, try runtime.evalString("(reverse (list 1 2 3))")));
    // Tensors still forward to the tensor kernels (same slices as before:
    // count-first `(op n t [k])`).
    try expectEqualStrings("[3 4]", try format(runtime, try runtime.evalString(
        "(keep (stack 1 2 3 4) (fn (x) (> x 2)))",
    )));
    try expectEqualStrings("[1 2]", try format(runtime, try runtime.evalString("(take 2 (stack 1 2 3 4))")));
    try expectEqualStrings("[3 4]", try format(runtime, try runtime.evalString("(drop 2 (stack 1 2 3 4))")));
    try expectEqualStrings("[1 2 3 4]", try format(runtime, try runtime.evalString("(cat (stack 1 2) (stack 3 4))")));
    try expectEqualStrings("[3 2 1]", try format(runtime, try runtime.evalString("(rev (stack 1 2 3))")));
}

test "proto: length is list-only" {
    var runtime = try newRt();
    defer runtime.deinit();
    // List: cons count.
    try expectEqual(Value.i64(3), try runtime.evalString("(length (list 1 2 3))"));
    try expectEqual(Value.i64(0), try runtime.evalString("(length nil)"));
    // Tensor size is `tensor-len`, NOT `length` (list-only).
    try expectError(error.TypeMismatch, runtime.evalString("(length (stack 1 2 3))"));
    // Map size is `map-size`, NOT `length`.
    try expectError(error.TypeMismatch, runtime.evalString("(length (hash-map 'a 1 :b 2))"));
    // Legacy aliases still work.
    try expectEqual(Value.i64(3), try runtime.evalString("(tensor-len (stack 1 2 3))"));
    try expectEqual(Value.i64(2), try runtime.evalString("(map-size (hash-map 'a 1 :b 2))"));
    // Non-collection → TypeMismatch.
    try expectError(error.TypeMismatch, runtime.evalString("(length 42)"));
    try expectError(error.ArityMismatch, runtime.evalString("(length)"));
}

test "proto: dispatcher error fallbacks" {
    var runtime = try newRt();
    defer runtime.deinit();
    // Non-collection first arg → TypeMismatch (§0.2).
    try expectError(error.TypeMismatch, runtime.evalString("(keep 5 (fn (x) #t))"));
    try expectError(error.TypeMismatch, runtime.evalString("(concat (list 1) 2)"));
    try expectError(error.TypeMismatch, runtime.evalString("(reverse 5)"));
    // Count-first take/drop: non-collection second arg → TypeMismatch;
    // missing collection → ArityMismatch.
    try expectError(error.TypeMismatch, runtime.evalString("(take 2 5)"));
    try expectError(error.TypeMismatch, runtime.evalString("(drop 2 5)"));
    try expectError(error.ArityMismatch, runtime.evalString("(take 2)"));
    try expectError(error.ArityMismatch, runtime.evalString("(drop 2)"));
    try expectError(error.ArityMismatch, runtime.evalString("(fold 5)"));
    try expectError(error.ArityMismatch, runtime.evalString("(scan 5)"));
    try expectError(error.ArityMismatch, runtime.evalString("(map 5)"));
    try expectError(error.ArityMismatch, runtime.evalString("(keep 5)"));
}
