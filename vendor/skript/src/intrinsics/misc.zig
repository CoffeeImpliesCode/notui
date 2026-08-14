const std = @import("std");

const skript = @import("../root.zig");
const Value = skript.Value;
const Error = skript.Error;
const EvalContext = skript.EvalContext;

const intrin = @import("root.zig");
const makeWrapper = intrin.makeWrapper;

pub fn rgbaImpl(r: f64, g: f64, b: f64, a: f64) u32 {
    const red: u32 = @intFromFloat(std.math.clamp(r * 255.0, 0.0, 255.0));
    const green: u32 = @intFromFloat(std.math.clamp(g * 255.0, 0.0, 255.0));
    const blue: u32 = @intFromFloat(std.math.clamp(b * 255.0, 0.0, 255.0));
    const alpha: u32 = @intFromFloat(std.math.clamp(a * 255.0, 0.0, 255.0));
    const val = (alpha << 24) | (blue << 16) | (green << 8) | red;
    return val;
}

pub const rgba = makeWrapper(rgbaImpl);

/// Create a symbol from a string: `(symbol "name")`
pub fn makeSymbol(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_string);
    const str = try rt.stringBytes(
        args[0].obj.toPtr([*:0]const u8),
        std.math.maxInt(usize),
        .native,
    );
    try rt.chargeWork(@intCast(str.len), 1, .native);
    const trimmed = std.mem.trim(u8, str, " \t\n\r");
    const sym = try rt.runtime.store.getsym(trimmed);
    return .symbol(sym);
}

/// (@symbol.eq A B) — symbol equality. Symbols are interned, so equality is
/// object identity (the same interned Sym denotes the same symbol everywhere).
pub fn symbolEq(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    try intrin.typeAssert(args[0], skript.builtins.type_symbol);
    try intrin.typeAssert(args[1], skript.builtins.type_symbol);
    return Value.bool(args[0].obj == args[1].obj);
}

/// (@symbol.ne A B) — symbol inequality.
pub fn symbolNe(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    try intrin.typeAssert(args[0], skript.builtins.type_symbol);
    try intrin.typeAssert(args[1], skript.builtins.type_symbol);
    return Value.bool(args[0].obj != args[1].obj);
}

/// (@keyword.eq A B) — keyword equality. Keywords are interned, so equality is
/// object identity (the same interned keyword denotes the same keyword).
pub fn keywordEq(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    try intrin.typeAssert(args[0], skript.builtins.type_keyword);
    try intrin.typeAssert(args[1], skript.builtins.type_keyword);
    return Value.bool(args[0].obj == args[1].obj);
}

/// (@keyword.ne A B) — keyword inequality.
pub fn keywordNe(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    try intrin.typeAssert(args[0], skript.builtins.type_keyword);
    try intrin.typeAssert(args[1], skript.builtins.type_keyword);
    return Value.bool(args[0].obj != args[1].obj);
}

/// (@error? v) — #t when v is an error value (type_error). Total predicate.
pub fn isError(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    return Value.bool(args[0].typ == skript.builtins.type_error);
}

/// (@error-name v) — the anyerror name of an error value's payload as a
/// string (e.g. "Unbound", "Raised"). Non-error value → nil (total).
pub fn errorName(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    if (args[0].typ != skript.builtins.type_error) return .nil;
    const name = @errorName(args[0].errorCode());
    try rt.chargeWork(@intCast(name.len), 1, .native);
    const out = try rt.runtime.store.sym_alloc.allocSentinel(u8, name.len, 0);
    @memcpy(out[0..name.len], name);
    return Value.string(.fromPtr(out.ptr));
}

/// The original source line/column of a system error, or nil without source.
pub fn errorLocation(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    if (args[0].typ != skript.builtins.type_error) return .nil;
    const site = args[0].errorSite();
    if (site.line != 0) {
        return skript.Reader.buildLocAlist(ctx, .{ .line = site.line, .col = site.col });
    }
    if (site.source.isNil()) return .nil;
    const sloc = ctx.runtime.dfsNodeLocation(site.source, site.idx) orelse return .nil;
    return skript.Reader.buildLocAlist(ctx, sloc.*);
}

fn cell(ctx: *EvalContext, car: Value, cdr: Value) Error!Value {
    const ref = try ctx.runtime.store.create([2]Value);
    ref.deref([2]Value).* = .{ car, cdr };
    return Value.cons(ref.toObject());
}

fn frameAlist(ctx: *EvalContext, frame: skript.data.ErrorFrame) Error!Value {
    const sloc = if (frame.site.line != 0 or frame.site.source.isNil())
        null
    else
        ctx.runtime.dfsNodeLocation(frame.site.source, frame.site.idx);
    const function_name: []const u8 = if (frame.name) |name| name.* else "<anonymous>";
    const text = try ctx.runtime.store.sym_alloc.allocSentinel(u8, function_name.len, 0);
    @memcpy(text[0..function_name.len], function_name);
    const filename: Value = if (!frame.site.file.isNil())
        frame.site.file
    else if (sloc) |loc|
        if (loc.file) |file| Value.string(.fromPtr(file)) else .nil
    else
        .nil;
    const fields = [_]struct { []const u8, Value }{
        .{ "file", filename },
        .{ "col", .i64(if (frame.site.line != 0) frame.site.col else if (sloc) |loc| loc.col else 0) },
        .{ "line", .i64(if (frame.site.line != 0) frame.site.line else if (sloc) |loc| loc.line else 0) },
        .{ "function", .string(.fromPtr(text.ptr)) },
    };
    var alist: Value = .nil;
    for (fields) |field| {
        const key = Value.symbol(try ctx.runtime.store.getsym(field[0]));
        alist = try cell(ctx, try cell(ctx, key, field[1]), alist);
    }
    return alist;
}

/// Immutable call-site snapshots, innermost first, with function/line/col/file.
pub fn errorTrace(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    if (args[0].typ != skript.builtins.type_error) return .nil;
    const frames = args[0].errorFrames();
    try ctx.charge(.{
        .work = std.math.mul(u64, frames.len, 9) catch return error.LimitExceeded,
        .nodes = std.math.mul(u64, frames.len, 9) catch return error.LimitExceeded,
    }, .native);
    var list: Value = .nil;
    var index = frames.len;
    while (index > 0) {
        index -= 1;
        list = try cell(ctx, try frameAlist(ctx, frames[index]), list);
    }
    return list;
}

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
    }
}

test "rgba pack" {
    const expectEqual = std.testing.expectEqual;

    // (r, g, b, a) packed as ABGR: (a << 24) | (b << 16) | (g << 8) | r
    // pure red
    try expectEqual(@as(u32, 0xFF0000FF), rgbaImpl(1.0, 0.0, 0.0, 1.0));
    // pure green
    try expectEqual(@as(u32, 0xFF00FF00), rgbaImpl(0.0, 1.0, 0.0, 1.0));
    // pure blue
    try expectEqual(@as(u32, 0xFFFF0000), rgbaImpl(0.0, 0.0, 1.0, 1.0));
    // mid gray, full alpha
    try expectEqual(@as(u32, 0xFF7F7F7F), rgbaImpl(0.5, 0.5, 0.5, 1.0));
    // zero alpha
    try expectEqual(@as(u32, 0x000000FF), rgbaImpl(1.0, 0.0, 0.0, 0.0));
    // full white
    try expectEqual(@as(u32, 0xFFFFFFFF), rgbaImpl(1.0, 1.0, 1.0, 1.0));
    // full black
    try expectEqual(@as(u32, 0x00000000), rgbaImpl(0.0, 0.0, 0.0, 0.0));
}

test "rgba clamp negative" {
    const expectEqual = std.testing.expectEqual;
    // All negative → clamped to 0
    try expectEqual(@as(u32, 0x00000000), rgbaImpl(-1.0, -0.5, -0.1, -2.0));
    // Mixed negative and positive
    try expectEqual(@as(u32, 0xFF0000FF), rgbaImpl(1.0, -0.5, -0.1, 1.0));
}

test "rgba clamp overflow" {
    const expectEqual = std.testing.expectEqual;
    // All over 1.0 → clamped to 255
    try expectEqual(@as(u32, 0xFFFFFFFF), rgbaImpl(2.0, 1.5, 3.0, 1.1));
}

test "rgba fractional" {
    const expectEqual = std.testing.expectEqual;
    // 0.0039 * 255 ≈ 0.99, truncated to 0
    try expectEqual(@as(u32, 0x00000000), rgbaImpl(0.0039, 0.0, 0.0, 0.0));
    // 0.004 * 255 ≈ 1.02, truncated to 1
    try expectEqual(@as(u32, 0x00000001), rgbaImpl(0.004, 0.0, 0.0, 0.0));
}
