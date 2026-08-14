const builtin = @import("builtin");
const platform = @import("platform");
const options = @import("options");

const std = @import("std");

const skript = @import("../root.zig");
const Value = skript.Value;
const Object = skript.Object;
const Error = skript.Error;
const Func = skript.Func;
const Runtime = skript.Runtime;
const EvalContext = skript.EvalContext;
const Closure = skript.data.Closure;

pub const dynlib_supported = platform.dynLibSupported(builtin.target);
pub const dynlib_enabled = dynlib_supported and (builtin.link_mode != .static);
const dynlib_impl = @import("dynlib.zig");
const no_dynlib_impl = @import("no_dynlib.zig");
const ffi_impl = @import("ffi.zig");
const no_ffi_impl = @import("no_ffi.zig");

pub const dynlib = if (dynlib_enabled) dynlib_impl else no_dynlib_impl;

pub const ffi_supported = platform.ffiSupported(builtin.target);
pub const ffi_enabled = ffi_supported and (builtin.link_mode != .static) and options.ffi_enabled;
pub const ffi = if (ffi_enabled) ffi_impl else no_ffi_impl;

pub const print = @import("print.zig");
pub const float = @import("float.zig");
pub const complex = @import("complex.zig");
pub const @"bool" = @import("bool.zig");
pub const list = @import("list.zig");
pub const misc = @import("misc.zig");
pub const process = @import("process.zig");
pub const modules = @import("modules.zig");
pub const int = @import("int.zig");
pub const map = @import("map.zig");
pub const tensor = @import("tensor.zig");
pub const widget = @import("widget.zig");
pub const string = @import("string.zig");
pub const collections = @import("collections.zig");
pub const equal = @import("equal.zig");
pub const ad = @import("ad.zig");
pub const ad_reverse = @import("ad_reverse.zig");
pub const symbolic = @import("symbolic.zig");
pub const evaluator = @import("evaluator.zig");
pub const bytes = @import("bytes.zig");
pub const input = @import("input.zig");
pub const file = @import("file.zig");

/// Map host file errors onto the public Skript error set.
pub fn mapFileError(err: anyerror) skript.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => error.Unbound,
        else => error.Unsupported,
    };
}

/// Assert that `ok` is true. Returns `error.Assertion` otherwise. Logs a message
/// that includes the caller's source location.
pub fn assert(comptime src: std.builtin.SourceLocation, comptime err_msg: []const u8, ok: bool) Error!void {
    if (!ok) {
        std.log.err(src.module ++ "." ++ src.fn_name ++ ": " ++ err_msg, .{});
        return error.Assertion;
    }
}

/// Assert that `lhs == rhs`. Returns `error.Assertion` otherwise. Logs with
/// `err_fmt` which receives `{lhs, rhs}`.
pub fn assertEq(
    comptime src: std.builtin.SourceLocation,
    comptime err_fmt: []const u8,
    lhs: anytype,
    rhs: anytype,
) Error!void {
    if (lhs != rhs) {
        std.log.err(src.fn_name ++ ": " ++ err_fmt, .{ lhs, rhs });
        return error.Assertion;
    }
}

fn convertIntToInt(comptime Dst: type, src_typ: Object, obj: Object) Dst {
    return switch (src_typ) {
        skript.builtins.type_i64 => switch (Dst) {
            // Same-width i64 → u64 wraps modulo 2^64 (two's complement) —
            // the documented fixed-width tie-break for i64+u64 joins
            // (types-numeric spec §1.3/§1.4). @intCast would trap on
            // negative values in safe builds, violating "dispatch coercion
            // never traps".
            u64 => @bitCast(obj.toInt(i64)),
            else => @as(Dst, @intCast(obj.toInt(i64))),
        },
        skript.builtins.type_i32 => @as(Dst, @intCast(obj.toInt(i32))),
        skript.builtins.type_i16 => @as(Dst, @intCast(obj.toInt(i32))),
        skript.builtins.type_i8 => @as(Dst, @intCast(obj.toInt(i32))),
        skript.builtins.type_u64 => @as(Dst, @intCast(obj.toInt(u64))),
        skript.builtins.type_u32 => @as(Dst, @intCast(obj.toInt(u32))),
        skript.builtins.type_u16 => @as(Dst, @intCast(obj.toInt(u32))),
        skript.builtins.type_u8 => @as(Dst, @intCast(obj.toInt(u32))),
        else => unreachable,
    };
}

/// Convert an integer Value to f64, widening through i64.
fn intToF64(v: Value) f64 {
    return @floatFromInt(convertIntToInt(i64, v.typ, v.obj));
}

/// Generic conversion from a Skript `Value` to Zig type `T`. Fast path when
/// the value's type tag matches `T` (direct access with canary). Slow path
/// handles cross-type coercion (float↔float, int→float, float→int, int↔int).
/// `T` must be i8/i16/i32/i64/u8/u16/u32/u64/f16/f32/f64/bool — other types
/// produce a compile error.
pub fn convertFromValue(comptime T: type, v: Value) T {
    const tag = comptime switch (T) {
        i8 => skript.builtins.type_i8,
        i16 => skript.builtins.type_i16,
        i32 => skript.builtins.type_i32,
        i64 => skript.builtins.type_i64,
        u8 => skript.builtins.type_u8,
        u16 => skript.builtins.type_u16,
        u32 => skript.builtins.type_u32,
        u64 => skript.builtins.type_u64,
        f16 => skript.builtins.type_f16,
        f32 => skript.builtins.type_f32,
        f64 => skript.builtins.type_f64,
        bool => skript.builtins.type_bool,
        else => @compileError("Unimplemented"),
    };
    if (v.typ == tag) {
        // Fast path: same type, direct access
        // The canary in toInt ensures unused bits are zero (type mismatch detection).
        return switch (T) {
            u8, i8, u16, i16, u32, i32, u64, i64 => v.obj.toInt(T),
            f16 => v.obj.tof16(),
            f32 => v.obj.tof32(),
            f64 => v.obj.tof64(),
            bool => v.obj.toBool(),
            else => unreachable,
        };
    }
    // Cross-type coercion
    return switch (T) {
        f16 => switch (v.typ) {
            skript.builtins.type_f16 => v.obj.tof16(),
            skript.builtins.type_f32 => @floatCast(v.obj.tof32()),
            skript.builtins.type_f64 => @floatCast(v.obj.tof64()),
            else => @floatCast(intToF64(v)),
        },
        f32 => switch (v.typ) {
            skript.builtins.type_f16 => @floatCast(v.obj.tof16()),
            skript.builtins.type_f32 => v.obj.tof32(),
            skript.builtins.type_f64 => @floatCast(v.obj.tof64()),
            else => @floatCast(intToF64(v)),
        },
        f64 => switch (v.typ) {
            skript.builtins.type_f16 => @floatCast(v.obj.tof16()),
            skript.builtins.type_f32 => @floatCast(v.obj.tof32()),
            skript.builtins.type_f64 => v.obj.tof64(),
            else => intToF64(v),
        },
        i8, i16, i32, i64 => blk: {
            const src = convertIntToInt(i64, v.typ, v.obj);
            break :blk switch (v.typ) {
                skript.builtins.type_f16,
                skript.builtins.type_f32,
                skript.builtins.type_f64,
                => std.math.lossyCast(T, switch (v.typ) {
                    // out-of-range/NaN saturate via lossyCast (zbc intfromfloat-without-clamp)
                    skript.builtins.type_f16 => @as(f64, @floatCast(v.obj.tof16())),
                    skript.builtins.type_f32 => @as(f64, @floatCast(v.obj.tof32())),
                    skript.builtins.type_f64 => v.obj.tof64(),
                    else => unreachable,
                }),
                else => @as(T, @intCast(src)),
            };
        },
        u8, u16, u32, u64 => blk: {
            const src = convertIntToInt(u64, v.typ, v.obj);
            break :blk switch (v.typ) {
                skript.builtins.type_f16,
                skript.builtins.type_f32,
                skript.builtins.type_f64,
                => std.math.lossyCast(T, switch (v.typ) {
                    // out-of-range/NaN saturate via lossyCast (zbc intfromfloat-without-clamp)
                    skript.builtins.type_f16 => @as(f64, @floatCast(v.obj.tof16())),
                    skript.builtins.type_f32 => @as(f64, @floatCast(v.obj.tof32())),
                    skript.builtins.type_f64 => v.obj.tof64(),
                    else => unreachable,
                }),
                else => @as(T, @intCast(src)),
            };
        },
        bool => v.obj.toBool(),
        else => @compileError("Unimplemented"),
    };
}

/// Dispatch by Zig type. Supports f16/f32/f64/bool/i8..i64/u8..u64 and
/// `std.math.Complex(f32)` (→ c32).
pub fn convertToValue(v: anytype) Value {
    const TypeOf = @TypeOf(v);
    return switch (TypeOf) {
        f16 => .f16(v),
        f32 => .f32(v),
        f64 => .f64(v),
        bool => .bool(v),
        i8 => .i8(v),
        i16 => .i16(v),
        i32 => .i32(v),
        i64 => .i64(v),
        u8 => .u8(v),
        u16 => .u16(v),
        u32 => .u32(v),
        u64 => .u64(v),
        std.math.Complex(f32) => .c32(v),
        else => @compileError("Unimplemented"),
    };
}

/// Assert `val` has the expected type tag. Returns `error.Assertion` otherwise.
pub fn typeAssert(val: Value, expected: Object) Error!void {
    if (val.typ != expected) return error.TypeMismatch;
}

/// Assert `args.len` equals `n`. Returns `error.Arity` otherwise.
pub fn arityAssert(args: []const Value, n: usize) Error!void {
    if (args.len != n) return error.ArityMismatch;
}

/// Extract the real and imaginary parts from an immediate complex value (c16 or c32).
pub fn complexParts(comptime FloatType: type, val: Value) struct { FloatType, FloatType } {
    const Storage = switch (FloatType) {
        f16 => [4]f16,
        f32 => [2]f32,
        else => @compileError("complexParts only supports f16 and f32 immediate types"),
    };
    const arr = val.obj.as(Storage);
    return .{ arr[0], arr[1] };
}

/// Extract the real and imaginary parts from a stored complex value (c64).
pub fn complexPartsStored(_: *Runtime, val: Value) struct { f64, f64 } {
    const arr = val.obj.toRef().deref([2]f64).*;
    return .{ arr[0], arr[1] };
}

/// Comptime adapter: converts a pure Zig function into the `Func` signature
/// `(ctx, ns, func, args)`. Arguments are coerced via `convertFromValue` and
/// the return value is wrapped via `convertToValue`. Each parameter must have
/// a concrete type. Arity must match.
pub fn makeWrapper(func: anytype) fn (*EvalContext, Value, Value, []const Value) Error!Value {
    const func_info = @typeInfo(@TypeOf(func)).@"fn";
    const arg_types = comptime blk: {
        // SAFETY: every element set by the following inline for
        var types: [func_info.params.len]type = undefined;
        for (func_info.params, 0..) |p, i| {
            types[i] = p.type orelse @compileError("makeWrapper requires concrete parameter types");
        }
        break :blk types;
    };
    const args_tuple = @Tuple(&arg_types);

    return struct {
        fn f(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
            if (args.len != func_info.params.len) return error.ArityMismatch;

            // SAFETY: every field set by the following inline for
            var call_args: args_tuple = undefined;
            inline for (arg_types, 0..) |arg_type, i| {
                call_args[i] = convertFromValue(arg_type, args[i]);
            }
            return convertToValue(@call(.auto, func, call_args));
        }
    }.f;
}

fn coerceIntToFloat(comptime T: type, val: Value) T {
    return switch (val.typ) {
        skript.builtins.type_i64 => @floatFromInt(val.obj.toInt(i64)),
        skript.builtins.type_i32 => @floatFromInt(val.obj.toInt(i32)),
        skript.builtins.type_i16 => @floatFromInt(val.obj.toInt(i32)),
        skript.builtins.type_i8 => @floatFromInt(val.obj.toInt(i32)),
        skript.builtins.type_u64 => @floatFromInt(val.obj.toInt(u64)),
        skript.builtins.type_u32 => @floatFromInt(val.obj.toInt(u32)),
        skript.builtins.type_u16 => @floatFromInt(val.obj.toInt(u32)),
        skript.builtins.type_u8 => @floatFromInt(val.obj.toInt(u32)),
        else => unreachable,
    };
}

/// Signed integer source into target T. A negative signed value coerced into
/// an unsigned target is `TypeMismatch`: wrapping a negative into an unsigned
/// type (the old i64+u64 two's-complement tie-break) silently miscompares and
/// mis-ariths, so it is never done — spec §1.3/§1.4.
fn coerceInt(comptime T: type, comptime S: type, src: S) Error!T {
    if (comptime @typeInfo(T).int.signedness == .unsigned and
        @typeInfo(S).int.signedness == .signed)
    {
        if (src < 0) return error.TypeMismatch;
    }
    return @intCast(src);
}

/// Convert any numeric value (float or integer) to a target integer type T.
/// Floats are truncated toward zero. Integers are widened or narrowed. A
/// negative signed source coerced into an unsigned target errors
/// TypeMismatch (see coerceInt).
fn coerceToInt(comptime T: type, val: Value) Error!T {
    switch (val.typ) {
        // Float sources: truncate toward zero
        // out-of-range/NaN saturate via lossyCast (zbc intfromfloat-without-clamp)
        skript.builtins.type_f16 => return std.math.lossyCast(T, val.obj.tof16()),
        skript.builtins.type_f32 => return std.math.lossyCast(T, val.obj.tof32()),
        skript.builtins.type_f64 => return std.math.lossyCast(T, val.obj.tof64()),
        // Integer sources: cast (widening or narrowing)
        skript.builtins.type_i64 => return coerceInt(T, i64, val.obj.toInt(i64)),
        skript.builtins.type_i32 => return coerceInt(T, i32, val.obj.toInt(i32)),
        skript.builtins.type_i16 => return coerceInt(T, i32, val.obj.toInt(i32)),
        skript.builtins.type_i8 => return coerceInt(T, i32, val.obj.toInt(i32)),
        skript.builtins.type_u64 => return coerceInt(T, u64, val.obj.toInt(u64)),
        skript.builtins.type_u32 => return coerceInt(T, u32, val.obj.toInt(u32)),
        skript.builtins.type_u16 => return coerceInt(T, u32, val.obj.toInt(u32)),
        skript.builtins.type_u8 => return coerceInt(T, u32, val.obj.toInt(u32)),
        else => unreachable,
    }
}

pub fn coerceBuiltin(comptime to: Object, rt: *Runtime, from: Value) Error!Value {
    // Complex sources never coerce into int/float targets: the imaginary
    // part must never be dropped implicitly (spec §1.4). This also turns the
    // former latent panic in coerceToInt (else => unreachable) into a clean
    // error, e.g. (i64 1+2i).
    switch (from.typ) {
        skript.builtins.type_c16, skript.builtins.type_c32, skript.builtins.type_c64 => {
            switch (to) {
                skript.builtins.type_c16, skript.builtins.type_c32, skript.builtins.type_c64 => {},
                else => return error.TypeMismatch,
            }
        },
        else => {},
    }
    switch (to) {
        skript.builtins.type_f16 => switch (from.typ) {
            skript.builtins.type_f16 => return from,
            skript.builtins.type_f32 => return .f16(@floatCast(from.obj.tof32())),
            skript.builtins.type_f64 => return .f16(@floatCast(from.obj.tof64())),
            else => {},
        },
        skript.builtins.type_f32 => switch (from.typ) {
            skript.builtins.type_f16 => return .f32(@floatCast(from.obj.tof16())),
            skript.builtins.type_f32 => return from,
            skript.builtins.type_f64 => return .f32(@floatCast(from.obj.tof64())),
            else => {},
        },
        skript.builtins.type_f64 => switch (from.typ) {
            skript.builtins.type_f16 => return .f64(@floatCast(from.obj.tof16())),
            skript.builtins.type_f32 => return .f64(@floatCast(from.obj.tof32())),
            skript.builtins.type_f64 => return from,
            else => {},
        },
        // Complex targets (NEW, §1.4): real → complex with imaginary 0;
        // complex → complex per-component @floatCast (widen or narrow);
        // same type identity. Non-numeric sources are Unimplemented, matching
        // the float/int constructor arms.
        skript.builtins.type_c16 => return coerceToComplex(f16, skript.builtins.type_c16, rt, from),
        skript.builtins.type_c32 => return coerceToComplex(f32, skript.builtins.type_c32, rt, from),
        skript.builtins.type_c64 => return coerceToComplex(f64, skript.builtins.type_c64, rt, from),
        // Integer targets: coerce from any numeric type
        skript.builtins.type_i8 => return .i8(try coerceToInt(i8, from)),
        skript.builtins.type_i16 => return .i16(try coerceToInt(i16, from)),
        skript.builtins.type_i32 => return .i32(try coerceToInt(i32, from)),
        skript.builtins.type_i64 => return .i64(try coerceToInt(i64, from)),
        skript.builtins.type_u8 => return .u8(try coerceToInt(u8, from)),
        skript.builtins.type_u16 => return .u16(try coerceToInt(u16, from)),
        skript.builtins.type_u32 => return .u32(try coerceToInt(u32, from)),
        skript.builtins.type_u64 => return .u64(try coerceToInt(u64, from)),
        else => return error.Unimplemented,
    }
    // Integer-to-float coercion: hit when from.typ is an integer type and to is a float target.
    switch (from.typ) {
        skript.builtins.type_i64,
        skript.builtins.type_i32,
        skript.builtins.type_i16,
        skript.builtins.type_i8,
        skript.builtins.type_u64,
        skript.builtins.type_u32,
        skript.builtins.type_u16,
        skript.builtins.type_u8,
        => return switch (to) {
            skript.builtins.type_f16 => .f16(coerceIntToFloat(f16, from)),
            skript.builtins.type_f32 => .f32(coerceIntToFloat(f32, from)),
            skript.builtins.type_f64 => .f64(coerceIntToFloat(f64, from)),
            else => unreachable,
        },
        else => return error.Unimplemented,
    }
}

/// The float value of a float-tagged value, widened exactly to f64.
fn realFloatOf(val: Value) f64 {
    return switch (val.typ) {
        skript.builtins.type_f16 => @floatCast(val.obj.tof16()),
        skript.builtins.type_f32 => @floatCast(val.obj.tof32()),
        skript.builtins.type_f64 => val.obj.tof64(),
        else => unreachable,
    };
}

/// Per-component parts of a complex value, cast to component float F.
fn complexPartsOf(comptime F: type, rt: *Runtime, val: Value) struct { F, F } {
    return switch (val.typ) {
        skript.builtins.type_c16 => blk: {
            const p = complexParts(f16, val);
            break :blk .{ @floatCast(p[0]), @floatCast(p[1]) };
        },
        skript.builtins.type_c32 => blk: {
            const p = complexParts(f32, val);
            break :blk .{ @floatCast(p[0]), @floatCast(p[1]) };
        },
        skript.builtins.type_c64 => blk: {
            const p = complexPartsStored(rt, val);
            break :blk .{ @floatCast(p[0]), @floatCast(p[1]) };
        },
        else => unreachable,
    };
}

/// Coerce any numeric `from` to the complex type with component float `F`
/// (c16/c32/c64). Real sources get imaginary 0; complex sources cast
/// per-component (widen or narrow). Non-numeric → error.Unimplemented,
/// matching the float/int constructor arms.
fn coerceToComplex(comptime F: type, comptime dst: Object, rt: *Runtime, from: Value) Error!Value {
    const parts: struct { F, F } = switch (from.typ) {
        skript.builtins.type_c16,
        skript.builtins.type_c32,
        skript.builtins.type_c64,
        => complexPartsOf(F, rt, from),
        skript.builtins.type_f16,
        skript.builtins.type_f32,
        skript.builtins.type_f64,
        => .{ @floatCast(realFloatOf(from)), 0 },
        skript.builtins.type_i64,
        skript.builtins.type_i32,
        skript.builtins.type_i16,
        skript.builtins.type_i8,
        skript.builtins.type_u64,
        skript.builtins.type_u32,
        skript.builtins.type_u16,
        skript.builtins.type_u8,
        => .{ coerceIntToFloat(F, from), 0 },
        else => return error.Unimplemented,
    };
    const re = parts[0];
    const im = parts[1];
    return switch (dst) {
        skript.builtins.type_c16 => .c16(.{ re, im }),
        skript.builtins.type_c32 => .c32(.{ re, im }),
        skript.builtins.type_c64 => blk: {
            const ref = try rt.store.create([2]f64);
            const ptr = ref.deref([2]f64);
            ptr[0] = re;
            ptr[1] = im;
            break :blk .c64(ref.toObject());
        },
        else => unreachable,
    };
}

// ---- numeric promotion lattice (types-numeric spec §1.3) ----

const NumericKind = enum(u2) { int, uint, float, complex };

/// Kind and bit width of a usable numeric tag; null for non-numeric tags and
/// the dead f8/c8 tags (no constructor can produce a value of them, so they
/// are not join members).
fn numericInfo(tag: Object) ?struct { kind: NumericKind, width: u16 } {
    return switch (tag) {
        skript.builtins.type_i8 => .{ .kind = .int, .width = 8 },
        skript.builtins.type_i16 => .{ .kind = .int, .width = 16 },
        skript.builtins.type_i32 => .{ .kind = .int, .width = 32 },
        skript.builtins.type_i64 => .{ .kind = .int, .width = 64 },
        skript.builtins.type_u8 => .{ .kind = .uint, .width = 8 },
        skript.builtins.type_u16 => .{ .kind = .uint, .width = 16 },
        skript.builtins.type_u32 => .{ .kind = .uint, .width = 32 },
        skript.builtins.type_u64 => .{ .kind = .uint, .width = 64 },
        skript.builtins.type_f16 => .{ .kind = .float, .width = 16 },
        skript.builtins.type_f32 => .{ .kind = .float, .width = 32 },
        skript.builtins.type_f64 => .{ .kind = .float, .width = 64 },
        skript.builtins.type_c16 => .{ .kind = .complex, .width = 16 },
        skript.builtins.type_c32 => .{ .kind = .complex, .width = 32 },
        skript.builtins.type_c64 => .{ .kind = .complex, .width = 64 },
        else => null,
    };
}

/// The numeric tag for a (kind, width) pair.
fn numTag(kind: NumericKind, width: u16) Object {
    return switch (kind) {
        .int => switch (width) {
            8 => skript.builtins.type_i8,
            16 => skript.builtins.type_i16,
            32 => skript.builtins.type_i32,
            64 => skript.builtins.type_i64,
            else => unreachable,
        },
        .uint => switch (width) {
            8 => skript.builtins.type_u8,
            16 => skript.builtins.type_u16,
            32 => skript.builtins.type_u32,
            64 => skript.builtins.type_u64,
            else => unreachable,
        },
        .float => switch (width) {
            16 => skript.builtins.type_f16,
            32 => skript.builtins.type_f32,
            64 => skript.builtins.type_f64,
            else => unreachable,
        },
        .complex => switch (width) {
            16 => skript.builtins.type_c16,
            32 => skript.builtins.type_c32,
            64 => skript.builtins.type_c64,
            else => unreachable,
        },
    };
}

/// Integer × integer join: same signedness → the wider type; mixed
/// signedness → the wider type, or the next-wider signed type at equal width
/// (i8+u8 → i16, i16+u16 → i32, i32+u32 → i64); i64+u64 → u64 (no wider
/// signed exists — the C tie-break). Coercing a negative signed value into
/// the unsigned join target errors TypeMismatch (never wraps; see
/// coerceInt) — only non-negative signed operands join to uN.
fn joinInts(a: Object, b: Object) Object {
    const ia = numericInfo(a) orelse unreachable;
    const ib = numericInfo(b) orelse unreachable;
    const a_signed = ia.kind == .int;
    const b_signed = ib.kind == .int;
    if (a_signed == b_signed) return if (ib.width > ia.width) b else a;
    if (ia.width != ib.width) return if (ia.width > ib.width) a else b;
    if (ia.width < 64) return numTag(.int, ia.width * 2);
    return skript.builtins.type_u64;
}

/// Lattice join of two numeric types (§1.3): the narrowest type that can
/// represent every value of both operands. Commutative, associative,
/// idempotent. Null when either operand is non-numeric.
fn numericJoin2(a: Object, b: Object) ?Object {
    const ia = numericInfo(a) orelse return null;
    const ib = numericInfo(b) orelse return null;
    return switch (ia.kind) {
        .int, .uint => switch (ib.kind) {
            .int, .uint => joinInts(a, b),
            // Integer × float → f64: the reader produces only i64/f64
            // literals and the existing unary-instance precedent routes ints
            // to f64; avoids f16/f32 mantissa traps swallowing i64 operands.
            .float => skript.builtins.type_f64,
            // Real × complex → the complex side (imag 0), per §1.3.
            .complex => b,
        },
        .float => switch (ib.kind) {
            .int, .uint => skript.builtins.type_f64,
            .float => if (ib.width > ia.width) b else a, // wider wins; equal → same type
            .complex => b,
        },
        .complex => switch (ib.kind) {
            .int, .uint, .float => a,
            .complex => if (ib.width > ia.width) b else a, // wider wins
        },
    };
}

/// Fold the §1.3 lattice join over all argument types; null when any
/// argument is non-numeric or the list is empty. The dispatch coercion
/// fallback (data.zig Method.get) uses this to find the join instance.
pub fn numericJoin(args: []const Value) ?Object {
    if (args.len == 0) return null;
    var join = args[0].typ;
    if (numericInfo(join) == null) return null;
    for (args[1..]) |arg| {
        join = numericJoin2(join, arg.typ) orelse return null;
    }
    return join;
}

/// Return the runtime type descriptor for a value. Equivalent to `(type x)`.
pub fn typeof(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try arityAssert(args, 1);
    const arg = args[0];
    const tag: u64 = @intFromEnum(arg.typ);
    const typ = if (tag <= skript.builtins.type_last_idx)
        ctx.runtime.predefined_types.items[@as(usize, @intCast(tag))].*
    else
        arg.typ.toRef().deref(skript.Type).*;
    return .init(typ.meta, arg.typ);
}

/// Return true if `args[0]` is a predefined builtin type (index ≤ type_last_idx).
pub fn isCoreType(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try arityAssert(args, 1);
    const idx = @intFromEnum(args[0].obj);
    return .bool(args[0].isType() and idx <= skript.builtins.type_last_idx);
}

/// Return bounded bytecode for a closure and its nested closure bodies.
/// PCs count instruction words, including guard and intrinsic extensions.
pub fn disasm(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    const rt = ctx.runtime;
    try typeAssert(args[0], skript.builtins.type_closure);
    const closure = args[0].obj.toRef().deref(Closure);
    if (closure.ir.len == 0) return .nil;
    const limit = @min(try sourceLimit(args, 65536), 1024 * 1024);
    const buffer = try rt.gpa.alloc(u8, limit);
    defer rt.gpa.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);

    // One visit per function, without recursion or constructing closures.
    const root_sites: []const @import("../reg_lower.zig").ClosureSite =
        if (closure.function_id == .invalid)
            &.{}
        else if (@intFromEnum(closure.function_id) < closure.fns.len)
            closure.fns[@intFromEnum(closure.function_id)].closure_sites
        else
            return error.InvalidCode;
    const count = if (root_sites.len == 0) 0 else closure.fns.len;
    try ctx.chargeWork(count, 1, .native);
    const seen = try rt.gpa.alloc(bool, count);
    defer rt.gpa.free(seen);
    @memset(seen, false);
    const pending = try rt.gpa.alloc(usize, count);
    defer rt.gpa.free(pending);
    var pending_start: usize = 0;
    var pending_end: usize = 0;
    var function = closure.function_id;
    if (count != 0 and function != .invalid) {
        const index = @intFromEnum(function);
        if (index >= count) return error.InvalidCode;
        seen[index] = true;
    }
    var ir = closure.ir;
    var sites = root_sites;
    var nregs = closure.nregs;
    while (true) {
        writer.print("function #{} regs={} words={}\n", .{
            @intFromEnum(function), nregs, ir.len,
        }) catch return error.Unsupported;
        var index: usize = 0;
        while (index < ir.len) {
            try ctx.chargeWork(1, 1, .native);
            const inst = ir[index];
            const size = skript.regvm.instructionSize(inst.opcode);
            if (size > ir.len - index) return error.InvalidCode;
            if (inst.opcode == .call_builtin_ext) {
                _ = try skript.regvm.decodeBuiltin(ir, index);
            }
            writer.print("{d:0>6}: ", .{index}) catch return error.Unsupported;
            const next = skript.regvm.formatRegInst(&writer, ir[index..].ptr, rt) catch return error.Unsupported;
            if (next != size) return error.InvalidCode;
            const offset: ?i64 = switch (inst.opcode) {
                .jmp => skript.regvm.Formats.imm24(inst.payload),
                .br, .brn, .@"try" => skript.regvm.Formats.rdOffset(inst.payload)[1],
                .guard_callee, .guard_self => skript.regvm.Formats.extension(ir[index + 1]),
                else => null,
            };
            if (offset) |relative| {
                const target = @as(i64, @intCast(index)) + size + relative;
                writer.print(" -> {}", .{target}) catch return error.Unsupported;
            }
            if (inst.opcode == .make_closure) {
                const site = skript.regvm.Formats.rdAndSidx(inst.payload)[1];
                if (site >= sites.len) return error.InvalidCode;
                writer.print(" -> fn#{}", .{@intFromEnum(sites[site].function)}) catch return error.Unsupported;
            }
            if (inst.opcode == .lookup or inst.opcode == .lookup_val) {
                const symbol = skript.regvm.Formats.rdAndSidx(inst.payload)[1];
                if (symbol >= rt.symbol_pool.items.len) return error.InvalidCode;
                writer.print(" ; {s}", .{rt.symbol_pool.items[symbol].symbol.*}) catch return error.Unsupported;
            }
            writer.writeByte('\n') catch return error.Unsupported;
            index += size;
        }
        for (sites) |site| {
            try ctx.chargeWork(1, 1, .native);
            const site_index = @intFromEnum(site.function);
            if (site_index >= count) return error.InvalidCode;
            if (seen[site_index]) continue;
            seen[site_index] = true;
            pending[pending_end] = site_index;
            pending_end += 1;
        }
        if (pending_start == pending_end) break;
        const entry = closure.fns[pending[pending_start]];
        pending_start += 1;
        function = entry.function;
        ir = entry.ir;
        sites = entry.closure_sites;
        nregs = entry.nregs;
        writer.writeByte('\n') catch return error.Unsupported;
    }
    const written = writer.buffered();
    const alloc = try rt.store.allocSlice(u8, written.len + 1);
    @memcpy(alloc.slice[0..written.len], written);
    alloc.slice[written.len] = 0;
    return .string(Object.fromPtr(alloc.slice.ptr));
}

fn sourceLimit(args: []const Value, default_limit: usize) Error!usize {
    if (args.len == 1) return default_limit;
    try typeAssert(args[1], skript.builtins.type_i64);
    const raw_limit = args[1].obj.toInt(i64);
    if (raw_limit < 0) return error.Unsupported;
    return std.math.cast(usize, raw_limit) orelse error.Unsupported;
}

/// Return the exact retained source text for a closure's defining form.
pub fn sourceText(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    if (args.len < 1 or args.len > 2) return error.ArityMismatch;
    try typeAssert(args[0], skript.builtins.type_closure);
    const closure = args[0].obj.toRef().deref(Closure);
    const max_bytes = try sourceLimit(args, 65536);
    return ctx.runtime.inspectSourceText(closure, max_bytes);
}

/// Return a bounded detached source datum for a closure's defining form.
pub fn sourceDatum(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    if (args.len < 1 or args.len > 2) return error.ArityMismatch;
    try typeAssert(args[0], skript.builtins.type_closure);
    const closure = args[0].obj.toRef().deref(Closure);
    const max_nodes = try sourceLimit(args, 16384);
    return ctx.runtime.inspectSourceDatum(closure, max_nodes);
}

/// Return a bounded immutable semantic-code view for a closure's function.
pub fn boundCode(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    if (args.len < 1 or args.len > 2) return error.ArityMismatch;
    try typeAssert(args[0], skript.builtins.type_closure);
    const closure = args[0].obj.toRef().deref(Closure);
    const max_nodes = try sourceLimit(args, 16384);
    return ctx.runtime.inspectBoundCode(closure, max_nodes);
}

/// Generate a type-check function that returns true if a value's type tag
/// equals `o`. Used to create `@is-instance-of?`-style predicates.
pub fn makeIsInstance(comptime o: skript.Object) Func {
    return struct {
        pub fn isinstance(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
            try arityAssert(args, 1);
            return .bool(args[0].typ == o);
        }
    }.isinstance;
}

// ---- per-type predicates (SEMANTICS §3.2 disjoint set) ----
// Exact tag tests. The `@Type`-style constants for these tags live in
// Runtime.zig's constants table; the orchestrator's C3 tranche may not touch
// Runtime.zig, so these six are registered as intrinsics instead of prelude
// defns over `@is-instance-of?` with new constants (same semantics: exact
// typ == tag).
pub const is_cons: Func = makeIsInstance(skript.builtins.type_cons);
pub const is_closure: Func = makeIsInstance(skript.builtins.type_closure);
pub const is_intrinsic: Func = makeIsInstance(skript.builtins.type_intrinsic);
pub const is_ffifunc: Func = makeIsInstance(skript.builtins.type_ffifunc);
pub const is_method: Func = makeIsInstance(skript.builtins.type_method);
pub const is_namespace: Func = makeIsInstance(skript.builtins.type_namespace);

// ---- aggregate numeric predicates (SEMANTICS §3.2) ----
// Flat-tag mask tests: the aggregates test the value's ACTUAL tag, so
// (complex? 1) is #f and (real? 1+2i) is #f (a c64-tagged value is not a
// real — divergence from R7RS, documented). "Exactly one per-type predicate
// is true" is preserved. The masks include the dead f8/c8 tags — correct
// robustness: no f8/c8 value can be constructed.

fn isIntTag(tag: u64) bool {
    return (tag & skript.builtins.type_int_mask) == skript.builtins.type_int or
        (tag & skript.builtins.type_uint_mask) == skript.builtins.type_uint;
}
fn isFloatTag(tag: u64) bool {
    return (tag & skript.builtins.type_float_mask) == skript.builtins.type_float;
}
fn isComplexTag(tag: u64) bool {
    return (tag & skript.builtins.type_complex_mask) == skript.builtins.type_complex;
}
fn isRealTag(tag: u64) bool {
    return isIntTag(tag) or isFloatTag(tag);
}
fn isNumericTag(tag: u64) bool {
    return isRealTag(tag) or isComplexTag(tag);
}

/// Generate a single-argument boolean intrinsic from a tag predicate.
fn isPred(comptime pred: fn (u64) bool) Func {
    return struct {
        pub fn f(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
            try arityAssert(args, 1);
            return .bool(pred(@intFromEnum(args[0].typ)));
        }
    }.f;
}

pub const is_number: Func = isPred(isNumericTag);
pub const is_real: Func = isPred(isRealTag);
pub const is_int: Func = isPred(isIntTag);
pub const is_float: Func = isPred(isFloatTag);
pub const is_complex: Func = isPred(isComplexTag);

/// Check if `args[1]` is an instance of type `args[0]`. `args[0]` must be a
/// type value. Equivalent to `(@is-instance-of? Type value)`.
pub fn isInstance(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try arityAssert(args, 2);
    if (!args[0].isType()) return error.ArityMismatch;
    return .bool(std.meta.eql(args[1].typ, args[0].obj));
}

/// Create an empty method dispatcher. Returns a `.method` value.
pub fn method(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try arityAssert(args, 0);
    const rt = ctx.runtime;
    const ref = try rt.store.create(skript.data.Method);
    const ptr = ref.deref(skript.data.Method);
    ptr.* = .{
        .id = try rt.store.allocMethodId(),
        .resolved = .init(rt.static),
    };
    return .method(ref.toObject());
}

/// True when every entry of `spec` is a builtin type. A builtin type value
/// wraps its type tag directly (`Value.typeValue(tag)` has obj = the tag);
/// a user Type object's obj is a heap handle. Used to enforce that core
/// (builtin arithmetic/comparison) dispatch is non-overridable.
fn specAllBuiltin(spec: []const Value) bool {
    for (spec) |s| {
        if (s.typ != skript.builtins.type_type) return false;
        if (@intFromEnum(s.obj) > skript.builtins.type_last_idx) return false;
    }
    return true;
}

/// Register a method instance. Arguments: `(method, type_spec..., func)`.
/// `type_spec` are type values (literals like @f64). The last argument is the
/// function to dispatch to when the method is called with matching arg types.
/// A locked method (see `lockMethod`) refuses a registration whose spec is
/// entirely builtin types — core ops are non-overridable.
pub fn instance(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    if (args.len < 3) return error.ArityMismatch;
    try typeAssert(args[0], skript.builtins.type_method);
    const func = args[args.len - 1];
    const spec = args[1 .. args.len - 1];
    try ctx.chargeWork(
        std.math.cast(u64, spec.len) orelse return error.Unsupported,
        1,
        .native,
    );
    const method_ptr = args[0].obj.toRef().deref(skript.data.Method);
    if (method_ptr.locked and specAllBuiltin(spec)) return error.Unsupported;
    const bound = @as(u64, method_ptr.resolved.capacity()) + 1;
    try ctx.chargeWork(bound, bound, .native);
    try method_ptr.put(spec, func);
    return .nil;
}

/// Lock a method against builtin-signature overrides. `(lock-method METHOD)`.
/// The prelude locks the arithmetic/comparison methods (+ - * / < > <= >=
/// = !=) so their builtin dispatch is fixed; user-type extensions of those
/// methods (a non-builtin spec) remain allowed.
pub fn lockMethod(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    try typeAssert(args[0], skript.builtins.type_method);
    const method_ptr = args[0].obj.toRef().deref(skript.data.Method);
    if (!method_ptr.locked) {
        if (method_ptr.revision == std.math.maxInt(u64)) return error.Unsupported;
        method_ptr.locked = true;
        method_ptr.revision += 1;
    }
    return .nil;
}

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
    }
}

test "disasm! prints every function of a program, once each" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    // `outer` and the `letrec` closure it builds. The traversal starts at the
    // dumped closure, so the module entry is not printed, and each reachable
    // function is printed exactly once even though the inner body calls itself.
    _ = try rt.evalString(
        \\(defn (outer n)
        \\  (letrec ((inner (fn (m) (if (= m 0) n (inner (- m 1))))))
        \\    (inner 3)))
        \\(outer 1)
    );
    const dumped = try rt.evalString("(disasm! outer)");
    const text = std.mem.span(dumped.obj.toPtr([*:0]const u8));

    var headers: std.ArrayList([]const u8) = .empty;
    defer headers.deinit(std.testing.allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "function #")) continue;
        const marker = std.mem.indexOf(u8, line, " regs=") orelse continue;
        try headers.append(std.testing.allocator, line[0..marker]);
    }
    try std.testing.expectEqual(@as(usize, 2), headers.items.len);
    try std.testing.expectEqualStrings("function #1", headers.items[0]);
    try std.testing.expectEqualStrings("function #2", headers.items[1]);
    // The inner body is in the dump, not only the instruction that builds it,
    // and its recursion resolves the letrec name rather than a symbol index.
    try std.testing.expect(std.mem.indexOf(u8, text, "; inner") != null);
    // Word-addressed PCs, and a resolved absolute target for every branch.
    try std.testing.expect(std.mem.indexOf(u8, text, "000000: start") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, " -> ") != null);
}

test "TIER-1: cross-type numeric coercion, comparisons, type predicates" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const expectEqual = std.testing.expectEqual;
    const expectError = std.testing.expectError;
    const b = skript.builtins;

    // §1.7 — cross-type coercion at dispatch.
    try expectEqual(Value.f64(3.0), try rt.evalString("(+ 1 2.0)"));
    try expectEqual(Value.i64(3), try rt.evalString("(+ 1 2)")); // same-type unchanged
    try expectEqual(Value.i16(300), try rt.evalString("(+ (i8 100) (u8 200))")); // i8+u8 → i16
    try expectEqual(Value.i64(0), try rt.evalString("(+ (i32 -1) (u32 1))")); // i32+u32 → i64
    try expectEqual(Value.f32(4.0), try rt.evalString("(+ (f16 1.5) (f32 2.5))")); // float widen → f32
    try expectEqual(Value.f64(6.0), try rt.evalString("(* 2 3.0)"));
    {
        // (+ 1 2+3i) → c64 3.0+3.0i (real+complex, imag 0)
        const v = try rt.evalString("(+ 1 2+3i)");
        try expectEqual(b.type_c64, v.typ);
        const parts = v.obj.toRef().deref([2]f64).*;
        try expectEqual(@as(f64, 3.0), parts[0]);
        try expectEqual(@as(f64, 3.0), parts[1]);
    }
    // Arity unchanged: no 3-ary instance; non-numeric operand: no join.
    try expectError(error.ArityMismatch, rt.evalString("(+ 1 2.0 3)"));
    try expectError(error.ArityMismatch, rt.evalString("(+ 1 \"a\")"));
    // i64+u64 → u64, modular wrap.
    try expectEqual(Value.u64(18446744073709551611), try rt.evalString("(- 0 (u64 5))"));
    try expectEqual(Value.u64(4), try rt.evalString("(+ -1 (u64 5))")); // negative i64 wraps

    // §2.3 — cross-type = and < (same lattice).
    try expectEqual(Value.true, try rt.evalString("(= 1 1.0)"));
    try expectEqual(Value.true, try rt.evalString("(= 1 1+0i)"));
    try expectEqual(Value.true, try rt.evalString("(< 1 2.0)"));
    try expectEqual(Value.false, try rt.evalString("(< 2.0 1)"));
    try expectError(error.ArityMismatch, rt.evalString("(< 1 2+0i)")); // complex unordered
    try expectEqual(Value.true, try rt.evalString("(= (i8 1) (u8 1))"));
    try expectEqual(Value.false, try rt.evalString("(!= 1 1.0)"));
    try expectEqual(Value.true, try rt.evalString("(< (i32 -1) (u32 1))")); // value-preserving join
    try expectEqual(Value.true, try rt.evalString("(= 0 -0.0)")); // IEEE, delegated
    try expectEqual(Value.true, try rt.evalString("(case 1.0 ((1) #t) (else #f))")); // case via =

    // §3.4 — per-type predicates (exact tag tests, total).
    try expectEqual(Value.true, try rt.evalString("(symbol? 'foo)"));
    try expectEqual(Value.false, try rt.evalString("(symbol? \"foo\")"));
    try expectEqual(Value.true, try rt.evalString("(string? \"hi\")"));
    try expectEqual(Value.true, try rt.evalString("(bool? #t)"));
    try expectEqual(Value.false, try rt.evalString("(bool? 1)"));
    try expectEqual(Value.true, try rt.evalString("(cons? (list 1))"));
    try expectEqual(Value.false, try rt.evalString("(cons? 5)"));
    try expectEqual(Value.true, try rt.evalString("(closure? (fn (x) x))"));
    try expectEqual(Value.false, try rt.evalString("(closure? +)")); // + is a method
    try expectEqual(Value.true, try rt.evalString("(intrinsic? @i64.add)"));
    try expectEqual(Value.true, try rt.evalString("(method? +)"));
    try expectEqual(Value.false, try rt.evalString("(method? @i64.add)"));
    try expectEqual(Value.false, try rt.evalString("(opaque? 1)"));

    // §3.4 — aggregate numeric predicates (flat-tag mask tests).
    try expectEqual(Value.true, try rt.evalString("(number? 42)"));
    try expectEqual(Value.true, try rt.evalString("(number? 1+2i)"));
    try expectEqual(Value.false, try rt.evalString("(number? \"42\")"));
    try expectEqual(Value.false, try rt.evalString("(number? @i64)")); // a type value is not a number
    try expectEqual(Value.true, try rt.evalString("(int? 42)"));
    try expectEqual(Value.false, try rt.evalString("(int? 42.0)"));
    try expectEqual(Value.true, try rt.evalString("(float? 42.0)"));
    try expectEqual(Value.false, try rt.evalString("(float? 42)"));
    try expectEqual(Value.true, try rt.evalString("(complex? 1+2i)"));
    try expectEqual(Value.false, try rt.evalString("(complex? 1)")); // flat-tag: a c64 is not a real
    try expectEqual(Value.true, try rt.evalString("(real? 42)"));
    try expectEqual(Value.false, try rt.evalString("(real? 1+2i)"));
}

test "TIER-1: coerceBuiltin complex arms and guards" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const expectEqual = std.testing.expectEqual;
    const expectError = std.testing.expectError;
    const b = skript.builtins;

    // Real → complex: component-coerce, imaginary 0.
    const a = try coerceBuiltin(b.type_c64, rt, .i64(2));
    try expectEqual(b.type_c64, a.typ);
    const a_parts = a.obj.toRef().deref([2]f64).*;
    try expectEqual(@as(f64, 2.0), a_parts[0]);
    try expectEqual(@as(f64, 0.0), a_parts[1]);
    // Same type: identity.
    const id = try coerceBuiltin(b.type_c32, rt, .c32(.{ 1, 2 }));
    try expectEqual(b.type_c32, id.typ);
    // Complex → complex: per-component @floatCast (narrow allowed).
    const narrow = try coerceBuiltin(b.type_c16, rt, .c32(.{ 1.5, 2.5 }));
    try expectEqual(b.type_c16, narrow.typ);
    const n_parts = complexParts(f16, narrow);
    try expectEqual(@as(f16, 1.5), n_parts[0]);
    try expectEqual(@as(f16, 2.5), n_parts[1]);
    // Complex source → int/float target: TypeMismatch (was a latent panic).
    try expectError(error.TypeMismatch, coerceBuiltin(b.type_i64, rt, .c32(.{ 1, 2 })));
    try expectError(error.TypeMismatch, coerceBuiltin(b.type_f64, rt, .c32(.{ 1, 2 })));
    // i64 → u64: negative signed refuse coercion (no two's-complement wrap).
    try expectError(error.TypeMismatch, coerceBuiltin(b.type_u64, rt, .i64(-1)));
    // Non-numeric → complex: Unimplemented (matches the float arms).
    try expectError(error.Unimplemented, coerceBuiltin(b.type_c32, rt, .bool(true)));
}
