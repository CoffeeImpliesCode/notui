const std = @import("std");

const skript = @import("../root.zig");
const Value = skript.Value;
const Error = skript.Error;
const EvalContext = skript.EvalContext;
const Func = skript.Func;
const Runtime = skript.Runtime;

const intrin = @import("root.zig");
const makeWrapper = intrin.makeWrapper;
const coerceBuiltin = intrin.coerceBuiltin;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const expectError = std.testing.expectError;

fn add(comptime T: type) fn (T, T) T {
    return struct {
        fn add(a: T, b: T) T {
            return a + b;
        }
    }.add;
}

fn sub(comptime T: type) fn (T, T) T {
    return struct {
        fn sub(a: T, b: T) T {
            return a - b;
        }
    }.sub;
}

fn mul(comptime T: type) fn (T, T) T {
    return struct {
        fn mul(a: T, b: T) T {
            return a * b;
        }
    }.mul;
}

fn div(comptime T: type) fn (T, T) T {
    return struct {
        fn div(a: T, b: T) T {
            return a / b;
        }
    }.div;
}

fn sin(comptime T: type) fn (T) T {
    return struct {
        fn sin(x: T) T {
            return std.math.sin(x);
        }
    }.sin;
}

fn cos(comptime T: type) fn (T) T {
    return struct {
        fn cos(x: T) T {
            return std.math.cos(x);
        }
    }.cos;
}

fn tan(comptime T: type) fn (T) T {
    return struct {
        fn tan(x: T) T {
            return std.math.tan(x);
        }
    }.tan;
}

fn sinh(comptime T: type) fn (T) T {
    return struct {
        fn sinh(x: T) T {
            return switch (T) {
                f16 => @floatCast(std.math.sinh(@as(f32, @floatCast(x)))),
                f32, f64 => std.math.sinh(x),
                else => @compileError("sinh not implemented for " ++ @typeName(T)),
            };
        }
    }.sinh;
}

fn cosh(comptime T: type) fn (T) T {
    return struct {
        fn cosh(x: T) T {
            return switch (T) {
                f16 => @floatCast(std.math.cosh(@as(f32, @floatCast(x)))),
                f32, f64 => std.math.cosh(x),
                else => @compileError("cosh not implemented for " ++ @typeName(T)),
            };
        }
    }.cosh;
}

fn tanh(comptime T: type) fn (T) T {
    return struct {
        fn tanh(x: T) T {
            return switch (T) {
                f16 => @floatCast(std.math.tanh(@as(f32, @floatCast(x)))),
                f32, f64 => std.math.tanh(x),
                else => @compileError("tanh not implemented for " ++ @typeName(T)),
            };
        }
    }.tanh;
}

fn exp(comptime T: type) fn (T) T {
    return struct {
        fn exp(x: T) T {
            return std.math.exp(x);
        }
    }.exp;
}

fn log(comptime T: type) fn (T) T {
    return struct {
        fn log(x: T) T {
            return @log(x);
        }
    }.log;
}

fn log2(comptime T: type) fn (T) T {
    return struct {
        fn log2(x: T) T {
            return std.math.log2(x);
        }
    }.log2;
}

fn log10(comptime T: type) fn (T) T {
    return struct {
        fn log10(x: T) T {
            return std.math.log10(x);
        }
    }.log10;
}

fn pow(comptime T: type) fn (T, T) T {
    return struct {
        fn pow(a: T, b: T) T {
            return switch (T) {
                f16 => @floatCast(std.math.pow(f32, @as(f32, @floatCast(a)), @as(f32, @floatCast(b)))),
                f32, f64 => std.math.pow(T, a, b),
                else => @compileError("pow not implemented for " ++ @typeName(T)),
            };
        }
    }.pow;
}

fn hypot(comptime T: type) fn (T, T) T {
    return struct {
        fn hypot(a: T, b: T) T {
            return std.math.hypot(a, b);
        }
    }.hypot;
}

fn floor(comptime T: type) fn (T) T {
    return struct {
        fn floor(x: T) T {
            return std.math.floor(x);
        }
    }.floor;
}

fn ceil(comptime T: type) fn (T) T {
    return struct {
        fn ceil(x: T) T {
            return std.math.ceil(x);
        }
    }.ceil;
}

fn round(comptime T: type) fn (T) T {
    return struct {
        fn round(x: T) T {
            return std.math.round(x);
        }
    }.round;
}

fn trunc(comptime T: type) fn (T) T {
    return struct {
        fn trunc(x: T) T {
            return std.math.trunc(x);
        }
    }.trunc;
}

fn abs(comptime T: type) fn (T) T {
    return struct {
        fn abs(x: T) T {
            return @abs(x);
        }
    }.abs;
}

fn neg(comptime T: type) fn (T) T {
    return struct {
        fn neg(x: T) T {
            return -x;
        }
    }.neg;
}

fn min(comptime T: type) fn (T, T) T {
    return struct {
        fn min(a: T, b: T) T {
            return @min(a, b);
        }
    }.min;
}

fn max(comptime T: type) fn (T, T) T {
    return struct {
        fn max(a: T, b: T) T {
            return @max(a, b);
        }
    }.max;
}

fn avg(comptime T: type) Func {
    return struct {
        fn avg(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
            if (args.len != 1) return error.ArityMismatch;
            const list_val = args[0];
            var sum: T = 0;
            var count: usize = 0;
            var cur = list_val;
            while (cur.typ == skript.builtins.type_cons) {
                try rt.chargeWork(1, 1, .native);
                const pair = cur.obj.toRef().deref([2]Value);
                const elem = pair[0];
                const coerced = try coerceBuiltin(comptime switch (T) {
                    f16 => skript.builtins.type_f16,
                    f32 => skript.builtins.type_f32,
                    f64 => skript.builtins.type_f64,
                    else => @compileError("unsupported type"),
                }, rt.runtime, elem);
                sum += switch (T) {
                    f16 => coerced.obj.tof16(),
                    f32 => coerced.obj.tof32(),
                    f64 => coerced.obj.tof64(),
                    else => unreachable,
                };
                count += 1;
                cur = pair[1];
            }
            if (count == 0) return error.Unsupported;
            const result = sum / @as(T, @floatFromInt(count));
            return switch (T) {
                f16 => Value.f16(result),
                f32 => Value.f32(result),
                f64 => Value.f64(result),
                else => unreachable,
            };
        }
    }.avg;
}

fn sign(comptime T: type) fn (T) T {
    return struct {
        fn sign(x: T) T {
            if (x > 0) return 1 else if (x < 0) return -1 else return 0;
        }
    }.sign;
}

fn fract(comptime T: type) fn (T) T {
    return struct {
        fn fract(x: T) T {
            return x - std.math.trunc(x);
        }
    }.fract;
}

fn mod(comptime T: type) fn (T, T) T {
    return struct {
        fn mod(a: T, b: T) T {
            return @mod(a, b);
        }
    }.mod;
}

fn rem(comptime T: type) fn (T, T) T {
    return struct {
        fn rem(a: T, b: T) T {
            return a - std.math.trunc(a / b) * b;
        }
    }.rem;
}

fn clamp(comptime T: type) fn (T, T, T) T {
    return struct {
        fn clamp(x: T, lo: T, hi: T) T {
            const l = @min(lo, hi);
            const h = @max(lo, hi);
            return @max(@min(x, h), l);
        }
    }.clamp;
}

fn blend(comptime T: type) fn (T, T, T) T {
    return struct {
        fn blend(a: T, b: T, t: T) T {
            return a + (b - a) * t;
        }
    }.blend;
}

fn unblend(comptime T: type) fn (T, T, T) T {
    return struct {
        fn unblend(a: T, b: T, v: T) T {
            return (v - a) / (b - a);
        }
    }.unblend;
}

fn remap(comptime T: type) fn (T, T, T, T, T) T {
    return struct {
        fn remap(x: T, in_lo: T, in_hi: T, out_lo: T, out_hi: T) T {
            return out_lo + (x - in_lo) * (out_hi - out_lo) / (in_hi - in_lo);
        }
    }.remap;
}

fn isNan(comptime T: type) fn (T) bool {
    return struct {
        fn isNan(x: T) bool {
            return std.math.isNan(x);
        }
    }.isNan;
}

fn isInf(comptime T: type) fn (T) bool {
    return struct {
        fn isInf(x: T) bool {
            return std.math.isInf(x);
        }
    }.isInf;
}

fn isFinite(comptime T: type) fn (T) bool {
    return struct {
        fn isFinite(x: T) bool {
            return std.math.isFinite(x);
        }
    }.isFinite;
}

fn isZero(comptime T: type) fn (T) bool {
    return struct {
        fn isZero(x: T) bool {
            return x == 0;
        }
    }.isZero;
}

fn isOdd(comptime T: type) fn (T) bool {
    return struct {
        fn isOdd(x: T) bool {
            return @rem(x, 2) != 0;
        }
    }.isOdd;
}

fn isEven(comptime T: type) fn (T) bool {
    return struct {
        fn isEven(x: T) bool {
            return @rem(x, 2) == 0;
        }
    }.isEven;
}

fn degToRad(comptime T: type) fn (T) T {
    return struct {
        fn degToRad(x: T) T {
            return std.math.degreesToRadians(x);
        }
    }.degToRad;
}

fn radToDeg(comptime T: type) fn (T) T {
    return struct {
        fn radToDeg(x: T) T {
            return std.math.radiansToDegrees(x);
        }
    }.radToDeg;
}

fn nextafter(comptime T: type) fn (T, T) T {
    return struct {
        fn nextafter(x: T, y: T) T {
            return std.math.nextAfter(T, x, y);
        }
    }.nextafter;
}

fn prevbefore(comptime T: type) fn (T) T {
    return struct {
        fn prevbefore(x: T) T {
            return std.math.nextAfter(T, x, -std.math.inf(T));
        }
    }.prevbefore;
}

fn expm1(comptime T: type) fn (T) T {
    return struct {
        fn expm1(x: T) T {
            return switch (T) {
                f16 => @floatCast(std.math.expm1(@as(f32, @floatCast(x)))),
                f32, f64 => std.math.expm1(x),
                else => @compileError("expm1 not implemented for " ++ @typeName(T)),
            };
        }
    }.expm1;
}

fn log1p(comptime T: type) fn (T) T {
    return struct {
        fn log1p(x: T) T {
            return switch (T) {
                f16 => @floatCast(std.math.log1p(@as(f32, @floatCast(x)))),
                f32, f64 => std.math.log1p(x),
                else => @compileError("log1p not implemented for " ++ @typeName(T)),
            };
        }
    }.log1p;
}

fn asinh(comptime T: type) fn (T) T {
    return struct {
        fn asinh(x: T) T {
            return switch (T) {
                f16 => @floatCast(std.math.asinh(@as(f32, @floatCast(x)))),
                f32, f64 => std.math.asinh(x),
                else => @compileError("asinh not implemented for " ++ @typeName(T)),
            };
        }
    }.asinh;
}

fn acosh(comptime T: type) fn (T) T {
    return struct {
        fn acosh(x: T) T {
            return switch (T) {
                f16 => @floatCast(std.math.acosh(@as(f32, @floatCast(x)))),
                f32, f64 => std.math.acosh(x),
                else => @compileError("acosh not implemented for " ++ @typeName(T)),
            };
        }
    }.acosh;
}

fn atanh(comptime T: type) fn (T) T {
    return struct {
        fn atanh(x: T) T {
            return switch (T) {
                f16 => @floatCast(std.math.atanh(@as(f32, @floatCast(x)))),
                f32, f64 => std.math.atanh(x),
                else => @compileError("atanh not implemented for " ++ @typeName(T)),
            };
        }
    }.atanh;
}

fn asin(comptime T: type) fn (T) T {
    return struct {
        fn asin(x: T) T {
            return std.math.asin(x);
        }
    }.asin;
}

fn acos(comptime T: type) fn (T) T {
    return struct {
        fn acos(x: T) T {
            return std.math.acos(x);
        }
    }.acos;
}

fn atan(comptime T: type) fn (T) T {
    return struct {
        fn atan(x: T) T {
            return std.math.atan(x);
        }
    }.atan;
}

fn atan2(comptime T: type) fn (T, T) T {
    return struct {
        fn atan2(y: T, x: T) T {
            return switch (T) {
                f16 => @floatCast(std.math.atan2(@as(f32, @floatCast(y)), @as(f32, @floatCast(x)))),
                f32, f64 => std.math.atan2(y, x),
                else => @compileError("atan2 not implemented for " ++ @typeName(T)),
            };
        }
    }.atan2;
}

fn approx(comptime T: type) fn (T, T, T) bool {
    return struct {
        fn approx(a: T, b: T, eps: T) bool {
            return std.math.approxEqAbs(T, a, b, eps);
        }
    }.approx;
}

fn sqrt(comptime T: type) fn (T) T {
    return struct {
        fn sqrt(a: T) T {
            return std.math.sqrt(a);
        }
    }.sqrt;
}

fn compare(comptime T: type, comptime cmp: std.math.CompareOperator) fn (T, T) bool {
    return struct {
        fn compare(a: T, b: T) bool {
            return std.math.compare(a, cmp, b);
        }
    }.compare;
}

pub fn construct(comptime T: type) Func {
    return (struct {
        pub fn construct(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
            if (args.len == 0) {
                switch (T) {
                    f16 => return .f16(0),
                    f32 => return .f32(0),
                    f64 => return .f64(0),
                    else => return error.Unimplemented,
                }
            }
            if (args.len != 1) return error.ArityMismatch;
            const arg = args[0];
            switch (T) {
                f16 => return coerceBuiltin(skript.builtins.type_f16, rt.runtime, arg),
                f32 => return coerceBuiltin(skript.builtins.type_f32, rt.runtime, arg),
                f64 => return coerceBuiltin(skript.builtins.type_f64, rt.runtime, arg),
                else => return error.Unimplemented,
            }
        }
    }).construct;
}

pub const f16_construct = construct(f16);
pub const f16_add = makeWrapper(add(f16));
pub const f16_sub = makeWrapper(sub(f16));
pub const f16_mul = makeWrapper(mul(f16));
pub const f16_div = makeWrapper(div(f16));
pub const f16_sqrt = makeWrapper(sqrt(f16));
pub const f16_sin = makeWrapper(sin(f16));
pub const f16_cos = makeWrapper(cos(f16));
pub const f16_tan = makeWrapper(tan(f16));
pub const f16_sinh = makeWrapper(sinh(f16));
pub const f16_cosh = makeWrapper(cosh(f16));
pub const f16_tanh = makeWrapper(tanh(f16));
pub const f16_exp = makeWrapper(exp(f16));
pub const f16_log = makeWrapper(log(f16));
pub const f16_log2 = makeWrapper(log2(f16));
pub const f16_log10 = makeWrapper(log10(f16));
pub const f16_pow = makeWrapper(pow(f16));
pub const f16_hypot = makeWrapper(hypot(f16));
pub const f16_floor = makeWrapper(floor(f16));
pub const f16_ceil = makeWrapper(ceil(f16));
pub const f16_round = makeWrapper(round(f16));
pub const f16_trunc = makeWrapper(trunc(f16));
pub const f16_abs = makeWrapper(abs(f16));
pub const f16_neg = makeWrapper(neg(f16));
pub const f16_min = makeWrapper(min(f16));
pub const f16_max = makeWrapper(max(f16));
pub const f16_sign = makeWrapper(sign(f16));
pub const f16_asinh = makeWrapper(asinh(f16));
pub const f16_acosh = makeWrapper(acosh(f16));
pub const f16_atanh = makeWrapper(atanh(f16));
pub const f16_asin = makeWrapper(asin(f16));
pub const f16_acos = makeWrapper(acos(f16));
pub const f16_atan = makeWrapper(atan(f16));
pub const f16_atan2 = makeWrapper(atan2(f16));
pub const f16_approx = makeWrapper(approx(f16));
pub const f16_eq = makeWrapper(compare(f16, .eq));
pub const f16_ne = makeWrapper(compare(f16, .neq));
pub const f16_gt = makeWrapper(compare(f16, .gt));
pub const f16_lt = makeWrapper(compare(f16, .lt));
pub const f16_gte = makeWrapper(compare(f16, .gte));
pub const f16_lte = makeWrapper(compare(f16, .lte));

pub const f32_construct = construct(f32);
pub const f32_add = makeWrapper(add(f32));
pub const f32_sub = makeWrapper(sub(f32));
pub const f32_mul = makeWrapper(mul(f32));
pub const f32_div = makeWrapper(div(f32));
pub const f32_sqrt = makeWrapper(sqrt(f32));
pub const f32_sin = makeWrapper(sin(f32));
pub const f32_cos = makeWrapper(cos(f32));
pub const f32_tan = makeWrapper(tan(f32));
pub const f32_sinh = makeWrapper(sinh(f32));
pub const f32_cosh = makeWrapper(cosh(f32));
pub const f32_tanh = makeWrapper(tanh(f32));
pub const f32_exp = makeWrapper(exp(f32));
pub const f32_log = makeWrapper(log(f32));
pub const f32_log2 = makeWrapper(log2(f32));
pub const f32_log10 = makeWrapper(log10(f32));
pub const f32_pow = makeWrapper(pow(f32));
pub const f32_hypot = makeWrapper(hypot(f32));
pub const f32_floor = makeWrapper(floor(f32));
pub const f32_ceil = makeWrapper(ceil(f32));
pub const f32_round = makeWrapper(round(f32));
pub const f32_trunc = makeWrapper(trunc(f32));
pub const f32_abs = makeWrapper(abs(f32));
pub const f32_neg = makeWrapper(neg(f32));
pub const f32_min = makeWrapper(min(f32));
pub const f32_max = makeWrapper(max(f32));
pub const f32_sign = makeWrapper(sign(f32));
pub const f32_asinh = makeWrapper(asinh(f32));
pub const f32_acosh = makeWrapper(acosh(f32));
pub const f32_atanh = makeWrapper(atanh(f32));
pub const f32_asin = makeWrapper(asin(f32));
pub const f32_acos = makeWrapper(acos(f32));
pub const f32_atan = makeWrapper(atan(f32));
pub const f32_atan2 = makeWrapper(atan2(f32));
pub const f32_approx = makeWrapper(approx(f32));
pub const f32_eq = makeWrapper(compare(f32, .eq));
pub const f32_ne = makeWrapper(compare(f32, .neq));
pub const f32_gt = makeWrapper(compare(f32, .gt));
pub const f32_lt = makeWrapper(compare(f32, .lt));
pub const f32_gte = makeWrapper(compare(f32, .gte));
pub const f32_lte = makeWrapper(compare(f32, .lte));

pub const f64_construct = construct(f64);
pub const f64_add = makeWrapper(add(f64));
pub const f64_sub = makeWrapper(sub(f64));
pub const f64_mul = makeWrapper(mul(f64));
pub const f64_div = makeWrapper(div(f64));
pub const f64_sqrt = makeWrapper(sqrt(f64));
pub const f64_sin = makeWrapper(sin(f64));
pub const f64_cos = makeWrapper(cos(f64));
pub const f64_tan = makeWrapper(tan(f64));
pub const f64_sinh = makeWrapper(sinh(f64));
pub const f64_cosh = makeWrapper(cosh(f64));
pub const f64_tanh = makeWrapper(tanh(f64));
pub const f64_exp = makeWrapper(exp(f64));
pub const f64_log = makeWrapper(log(f64));
pub const f64_log2 = makeWrapper(log2(f64));
pub const f64_log10 = makeWrapper(log10(f64));
pub const f64_pow = makeWrapper(pow(f64));
pub const f64_hypot = makeWrapper(hypot(f64));
pub const f64_floor = makeWrapper(floor(f64));
pub const f64_ceil = makeWrapper(ceil(f64));
pub const f64_round = makeWrapper(round(f64));
pub const f64_trunc = makeWrapper(trunc(f64));
pub const f64_abs = makeWrapper(abs(f64));
pub const f64_neg = makeWrapper(neg(f64));
pub const f64_min = makeWrapper(min(f64));
pub const f64_max = makeWrapper(max(f64));
pub const f64_sign = makeWrapper(sign(f64));
pub const f64_asinh = makeWrapper(asinh(f64));
pub const f64_acosh = makeWrapper(acosh(f64));
pub const f64_atanh = makeWrapper(atanh(f64));
pub const f64_asin = makeWrapper(asin(f64));
pub const f64_acos = makeWrapper(acos(f64));
pub const f64_atan = makeWrapper(atan(f64));
pub const f64_atan2 = makeWrapper(atan2(f64));
pub const f64_approx = makeWrapper(approx(f64));
pub const f64_eq = makeWrapper(compare(f64, .eq));
pub const f64_ne = makeWrapper(compare(f64, .neq));
pub const f64_gt = makeWrapper(compare(f64, .gt));
pub const f64_lt = makeWrapper(compare(f64, .lt));
pub const f64_gte = makeWrapper(compare(f64, .gte));
pub const f64_lte = makeWrapper(compare(f64, .lte));

pub const f16_avg = avg(f16);
pub const f32_avg = avg(f32);
pub const f64_avg = avg(f64);

pub const f16_fract = makeWrapper(fract(f16));
pub const f32_fract = makeWrapper(fract(f32));
pub const f64_fract = makeWrapper(fract(f64));
pub const f16_mod = makeWrapper(mod(f16));
pub const f32_mod = makeWrapper(mod(f32));
pub const f64_mod = makeWrapper(mod(f64));
pub const f16_rem = makeWrapper(rem(f16));
pub const f32_rem = makeWrapper(rem(f32));
pub const f64_rem = makeWrapper(rem(f64));
pub const f16_clamp = makeWrapper(clamp(f16));
pub const f32_clamp = makeWrapper(clamp(f32));
pub const f64_clamp = makeWrapper(clamp(f64));
pub const f16_blend = makeWrapper(blend(f16));
pub const f32_blend = makeWrapper(blend(f32));
pub const f64_blend = makeWrapper(blend(f64));
pub const f16_unblend = makeWrapper(unblend(f16));
pub const f32_unblend = makeWrapper(unblend(f32));
pub const f64_unblend = makeWrapper(unblend(f64));
pub const f16_remap = makeWrapper(remap(f16));
pub const f32_remap = makeWrapper(remap(f32));
pub const f64_remap = makeWrapper(remap(f64));
pub const f16_is_nan = makeWrapper(isNan(f16));
pub const f32_is_nan = makeWrapper(isNan(f32));
pub const f64_is_nan = makeWrapper(isNan(f64));
pub const f16_is_inf = makeWrapper(isInf(f16));
pub const f32_is_inf = makeWrapper(isInf(f32));
pub const f64_is_inf = makeWrapper(isInf(f64));
pub const f16_is_finite = makeWrapper(isFinite(f16));
pub const f32_is_finite = makeWrapper(isFinite(f32));
pub const f64_is_finite = makeWrapper(isFinite(f64));
pub const f16_is_zero = makeWrapper(isZero(f16));
pub const f32_is_zero = makeWrapper(isZero(f32));
pub const f64_is_zero = makeWrapper(isZero(f64));
pub const f16_is_odd = makeWrapper(isOdd(f16));
pub const f32_is_odd = makeWrapper(isOdd(f32));
pub const f64_is_odd = makeWrapper(isOdd(f64));
pub const f16_is_even = makeWrapper(isEven(f16));
pub const f32_is_even = makeWrapper(isEven(f32));
pub const f64_is_even = makeWrapper(isEven(f64));
pub const f16_deg_to_rad = makeWrapper(degToRad(f16));
pub const f32_deg_to_rad = makeWrapper(degToRad(f32));
pub const f64_deg_to_rad = makeWrapper(degToRad(f64));
pub const f16_rad_to_deg = makeWrapper(radToDeg(f16));
pub const f32_rad_to_deg = makeWrapper(radToDeg(f32));
pub const f64_rad_to_deg = makeWrapper(radToDeg(f64));
pub const f16_nextafter = makeWrapper(nextafter(f16));
pub const f32_nextafter = makeWrapper(nextafter(f32));
pub const f64_nextafter = makeWrapper(nextafter(f64));
pub const f16_prevbefore = makeWrapper(prevbefore(f16));
pub const f32_prevbefore = makeWrapper(prevbefore(f32));
pub const f64_prevbefore = makeWrapper(prevbefore(f64));
pub const f16_expm1 = makeWrapper(expm1(f16));
pub const f32_expm1 = makeWrapper(expm1(f32));
pub const f64_expm1 = makeWrapper(expm1(f64));
pub const f16_log1p = makeWrapper(log1p(f16));
pub const f32_log1p = makeWrapper(log1p(f32));
pub const f64_log1p = makeWrapper(log1p(f64));

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
    }
}

// ---- test helpers ---- //

fn initTestingRuntime() !*Runtime {
    return Runtime.init(std.testing.allocator, std.testing.io);
}

test "all float operations" {
    const runtime = try initTestingRuntime();
    defer runtime.deinit();

    // ---- arithmetic ----
    {

        // f64 add
        try expectEqual(
            @as(f64, 5.0),
            (try f64_add(runtime.context(), .nil, .nil, &.{ .f64(2.0), .f64(3.0) })).obj.tof64(),
        );

        // f64 sub
        try expectEqual(
            @as(f64, 2.0),
            (try f64_sub(runtime.context(), .nil, .nil, &.{ .f64(5.0), .f64(3.0) })).obj.tof64(),
        );

        // f64 mul
        try expectEqual(
            @as(f64, 6.0),
            (try f64_mul(runtime.context(), .nil, .nil, &.{ .f64(2.0), .f64(3.0) })).obj.tof64(),
        );

        // f64 div
        try expectEqual(
            @as(f64, 3.5),
            (try f64_div(runtime.context(), .nil, .nil, &.{ .f64(7.0), .f64(2.0) })).obj.tof64(),
        );

        // f64 arithmetic returns correct type
        try expectEqual(
            skript.builtins.type_f64,
            (try f64_add(runtime.context(), .nil, .nil, &.{ .f64(1), .f64(2) })).typ,
        );
        try expectEqual(
            skript.builtins.type_f64,
            (try f64_sub(runtime.context(), .nil, .nil, &.{ .f64(1), .f64(2) })).typ,
        );
        try expectEqual(
            skript.builtins.type_f64,
            (try f64_mul(runtime.context(), .nil, .nil, &.{ .f64(1), .f64(2) })).typ,
        );
        try expectEqual(
            skript.builtins.type_f64,
            (try f64_div(runtime.context(), .nil, .nil, &.{ .f64(1), .f64(2) })).typ,
        );

        // f32 arithmetic
        try expectEqual(
            @as(f32, 5.0),
            (try f32_add(runtime.context(), .nil, .nil, &.{ .f32(2.0), .f32(3.0) })).obj.tof32(),
        );
        try expectEqual(
            @as(f32, 2.0),
            (try f32_sub(runtime.context(), .nil, .nil, &.{ .f32(5.0), .f32(3.0) })).obj.tof32(),
        );
        try expectEqual(
            @as(f32, 6.0),
            (try f32_mul(runtime.context(), .nil, .nil, &.{ .f32(2.0), .f32(3.0) })).obj.tof32(),
        );
        try expectEqual(
            @as(f32, 2.5),
            (try f32_div(runtime.context(), .nil, .nil, &.{ .f32(5.0), .f32(2.0) })).obj.tof32(),
        );

        // f16 arithmetic
        try expectEqual(
            @as(f16, 5.0),
            (try f16_add(runtime.context(), .nil, .nil, &.{ .f16(2.0), .f16(3.0) })).obj.tof16(),
        );
        try expectEqual(
            @as(f16, -1.0),
            (try f16_sub(runtime.context(), .nil, .nil, &.{ .f16(2.0), .f16(3.0) })).obj.tof16(),
        );
        try expectEqual(
            @as(f16, 6.0),
            (try f16_mul(runtime.context(), .nil, .nil, &.{ .f16(2.0), .f16(3.0) })).obj.tof16(),
        );
        try expectEqual(
            @as(f16, 2.5),
            (try f16_div(runtime.context(), .nil, .nil, &.{ .f16(5.0), .f16(2.0) })).obj.tof16(),
        );

        // f64 comparisons
        try expect((try f64_eq(runtime.context(), .nil, .nil, &.{ .f64(3.0), .f64(3.0) })).obj.toBool());
        try expect((try f64_ne(runtime.context(), .nil, .nil, &.{ .f64(3.0), .f64(4.0) })).obj.toBool());
        try expect((try f64_gt(runtime.context(), .nil, .nil, &.{ .f64(4.0), .f64(3.0) })).obj.toBool());
        try expect((try f64_lt(runtime.context(), .nil, .nil, &.{ .f64(3.0), .f64(4.0) })).obj.toBool());
        try expect((try f64_gte(runtime.context(), .nil, .nil, &.{ .f64(3.0), .f64(3.0) })).obj.toBool());
        try expect((try f64_gte(runtime.context(), .nil, .nil, &.{ .f64(4.0), .f64(3.0) })).obj.toBool());
        try expect((try f64_lte(runtime.context(), .nil, .nil, &.{ .f64(3.0), .f64(3.0) })).obj.toBool());
        try expect((try f64_lte(runtime.context(), .nil, .nil, &.{ .f64(3.0), .f64(4.0) })).obj.toBool());

        // f32 comparisons
        try expectEqual(
            skript.builtins.type_bool,
            (try f32_eq(runtime.context(), .nil, .nil, &.{ .f32(1), .f32(1) })).typ,
        );
        try expect((try f32_eq(runtime.context(), .nil, .nil, &.{ .f32(1.0), .f32(1.0) })).obj.toBool());
        try expect(!(try f32_eq(runtime.context(), .nil, .nil, &.{ .f32(1.0), .f32(2.0) })).obj.toBool());
        try expect((try f32_ne(runtime.context(), .nil, .nil, &.{ .f32(1.0), .f32(2.0) })).obj.toBool());
        try expect(!(try f32_ne(runtime.context(), .nil, .nil, &.{ .f32(1.0), .f32(1.0) })).obj.toBool());
        try expect((try f32_gt(runtime.context(), .nil, .nil, &.{ .f32(2.0), .f32(1.0) })).obj.toBool());
        try expect(!(try f32_gt(runtime.context(), .nil, .nil, &.{ .f32(1.0), .f32(1.0) })).obj.toBool());
        try expect(!(try f32_gt(runtime.context(), .nil, .nil, &.{ .f32(1.0), .f32(2.0) })).obj.toBool());
        try expect((try f32_lt(runtime.context(), .nil, .nil, &.{ .f32(1.0), .f32(2.0) })).obj.toBool());
        try expect(!(try f32_lt(runtime.context(), .nil, .nil, &.{ .f32(1.0), .f32(1.0) })).obj.toBool());
    }

    // ---- transcendental ----
    {

        // f64 sin and cos
        try expectApproxEqAbs(
            @as(f64, 0.0),
            (try f64_sin(runtime.context(), .nil, .nil, &.{.f64(0.0)})).obj.tof64(),
            @as(f64, 1e-15),
        );
        try expectApproxEqAbs(
            @as(f64, 1.0),
            (try f64_sin(runtime.context(), .nil, .nil, &.{.f64(std.math.pi / 2.0)})).obj.tof64(),
            @as(f64, 1e-15),
        );
        try expectApproxEqAbs(
            @as(f64, 0.0),
            (try f64_sin(runtime.context(), .nil, .nil, &.{.f64(std.math.pi)})).obj.tof64(),
            @as(f64, 1e-15),
        );
        try expectApproxEqAbs(
            @as(f64, 1.0),
            (try f64_cos(runtime.context(), .nil, .nil, &.{.f64(0.0)})).obj.tof64(),
            @as(f64, 1e-15),
        );
        try expectApproxEqAbs(
            @as(f64, 0.0),
            (try f64_cos(runtime.context(), .nil, .nil, &.{.f64(std.math.pi / 2.0)})).obj.tof64(),
            @as(f64, 1e-15),
        );
        try expectApproxEqAbs(
            @as(f64, -1.0),
            (try f64_cos(runtime.context(), .nil, .nil, &.{.f64(std.math.pi)})).obj.tof64(),
            @as(f64, 1e-15),
        );

        // f64 tan
        try expectApproxEqAbs(
            @as(f64, 0.0),
            (try f64_tan(runtime.context(), .nil, .nil, &.{.f64(0.0)})).obj.tof64(),
            @as(f64, 1e-15),
        );
        try expectApproxEqAbs(
            @as(f64, 1.0),
            (try f64_tan(runtime.context(), .nil, .nil, &.{.f64(std.math.pi / 4.0)})).obj.tof64(),
            @as(f64, 1e-14),
        );

        // f64 inverse trig (tight tolerance)
        try expectApproxEqAbs(
            @as(f64, 0.0),
            (try f64_asin(runtime.context(), .nil, .nil, &.{.f64(0.0)})).obj.tof64(),
            @as(f64, 1e-15),
        );
        try expectApproxEqAbs(
            @as(f64, std.math.pi / 2.0),
            (try f64_asin(runtime.context(), .nil, .nil, &.{.f64(1.0)})).obj.tof64(),
            @as(f64, 1e-15),
        );
        try expectApproxEqAbs(
            @as(f64, 0.0),
            (try f64_acos(runtime.context(), .nil, .nil, &.{.f64(1.0)})).obj.tof64(),
            @as(f64, 1e-15),
        );
        try expectApproxEqAbs(
            @as(f64, std.math.pi / 2.0),
            (try f64_acos(runtime.context(), .nil, .nil, &.{.f64(0.0)})).obj.tof64(),
            @as(f64, 1e-15),
        );
        try expectApproxEqAbs(
            @as(f64, 0.0),
            (try f64_atan(runtime.context(), .nil, .nil, &.{.f64(0.0)})).obj.tof64(),
            @as(f64, 1e-15),
        );
        try expectApproxEqAbs(
            @as(f64, std.math.pi / 4.0),
            (try f64_atan(runtime.context(), .nil, .nil, &.{.f64(1.0)})).obj.tof64(),
            @as(f64, 1e-15),
        );

        // f64 atan2
        try expectApproxEqAbs(
            @as(f64, 0.0),
            (try f64_atan2(runtime.context(), .nil, .nil, &.{ .f64(0.0), .f64(1.0) })).obj.tof64(),
            @as(f64, 1e-15),
        );
        try expectApproxEqAbs(
            @as(f64, std.math.pi / 4.0),
            (try f64_atan2(runtime.context(), .nil, .nil, &.{ .f64(1.0), .f64(1.0) })).obj.tof64(),
            @as(f64, 1e-15),
        );
        try expectApproxEqAbs(
            @as(f64, std.math.pi),
            (try f64_atan2(runtime.context(), .nil, .nil, &.{ .f64(0.0), .f64(-1.0) })).obj.tof64(),
            @as(f64, 1e-15),
        );

        // f64 asin (individual assertions)
        try expectEqual(@as(f64, 0.0), (try f64_asin(runtime.context(), .nil, .nil, &.{.f64(0.0)})).obj.tof64());
        try expectApproxEqAbs(
            @as(f64, std.math.pi) / 2,
            (try f64_asin(runtime.context(), .nil, .nil, &.{.f64(1.0)})).obj.tof64(),
            @as(f64, 1e-12),
        );

        // f64 acos (individual assertions)
        try expectEqual(@as(f64, 0.0), (try f64_acos(runtime.context(), .nil, .nil, &.{.f64(1.0)})).obj.tof64());
        try expectApproxEqAbs(
            @as(f64, std.math.pi) / 2,
            (try f64_acos(runtime.context(), .nil, .nil, &.{.f64(0.0)})).obj.tof64(),
            @as(f64, 1e-12),
        );

        // f64 atan (individual assertions)
        try expectEqual(@as(f64, 0.0), (try f64_atan(runtime.context(), .nil, .nil, &.{.f64(0.0)})).obj.tof64());
        try expectApproxEqAbs(
            @as(f64, std.math.pi) / 4,
            (try f64_atan(runtime.context(), .nil, .nil, &.{.f64(1.0)})).obj.tof64(),
            @as(f64, 1e-12),
        );

        // f64 sinh
        try expectEqual(@as(f64, 0.0), (try f64_sinh(runtime.context(), .nil, .nil, &.{.f64(0.0)})).obj.tof64());
        try expectApproxEqAbs(
            (std.math.e - 1.0 / std.math.e) / 2.0,
            (try f64_sinh(runtime.context(), .nil, .nil, &.{.f64(1.0)})).obj.tof64(),
            @as(f64, 1e-12),
        );

        // f64 cosh
        try expectEqual(@as(f64, 1.0), (try f64_cosh(runtime.context(), .nil, .nil, &.{.f64(0.0)})).obj.tof64());
        try expectApproxEqAbs(
            (std.math.e + 1.0 / std.math.e) / 2.0,
            (try f64_cosh(runtime.context(), .nil, .nil, &.{.f64(1.0)})).obj.tof64(),
            @as(f64, 1e-12),
        );

        // f64 identity: cosh^2 - sinh^2 = 1
        {
            const x: f64 = 0.875;
            const s = (try f64_sinh(runtime.context(), .nil, .nil, &.{.f64(x)})).obj.tof64();
            const c = (try f64_cosh(runtime.context(), .nil, .nil, &.{.f64(x)})).obj.tof64();
            try expectApproxEqAbs(@as(f64, 1.0), c * c - s * s, @as(f64, 1e-12));
        }

        // f64 tanh
        try expectEqual(@as(f64, 0.0), (try f64_tanh(runtime.context(), .nil, .nil, &.{.f64(0.0)})).obj.tof64());
        {
            const s = (try f64_sinh(runtime.context(), .nil, .nil, &.{.f64(1.0)})).obj.tof64();
            const c = (try f64_cosh(runtime.context(), .nil, .nil, &.{.f64(1.0)})).obj.tof64();
            try expectApproxEqAbs(
                s / c,
                (try f64_tanh(runtime.context(), .nil, .nil, &.{.f64(1.0)})).obj.tof64(),
                @as(f64, 1e-12),
            );
        }

        // f64 asinh
        try expectEqual(@as(f64, 0.0), (try f64_asinh(runtime.context(), .nil, .nil, &.{.f64(0.0)})).obj.tof64());
        {
            const sinh05 = (try f64_sinh(runtime.context(), .nil, .nil, &.{.f64(0.5)})).obj.tof64();
            try expectApproxEqAbs(
                @as(f64, 0.5),
                (try f64_asinh(runtime.context(), .nil, .nil, &.{.f64(sinh05)})).obj.tof64(),
                @as(f64, 1e-10),
            );
        }

        // f64 acosh
        try expectEqual(@as(f64, 0.0), (try f64_acosh(runtime.context(), .nil, .nil, &.{.f64(1.0)})).obj.tof64());
        {
            const cosh05 = (try f64_cosh(runtime.context(), .nil, .nil, &.{.f64(0.5)})).obj.tof64();
            try expectApproxEqAbs(
                @as(f64, 0.5),
                (try f64_acosh(runtime.context(), .nil, .nil, &.{.f64(cosh05)})).obj.tof64(),
                @as(f64, 1e-10),
            );
        }

        // f64 atanh
        try expectEqual(@as(f64, 0.0), (try f64_atanh(runtime.context(), .nil, .nil, &.{.f64(0.0)})).obj.tof64());
        {
            const tanh025 = (try f64_tanh(runtime.context(), .nil, .nil, &.{.f64(0.25)})).obj.tof64();
            try expectApproxEqAbs(
                @as(f64, 0.25),
                (try f64_atanh(runtime.context(), .nil, .nil, &.{.f64(tanh025)})).obj.tof64(),
                @as(f64, 1e-10),
            );
        }

        // f32 sin and cos
        try expectEqual(skript.builtins.type_f32, (try f32_sin(runtime.context(), .nil, .nil, &.{.f32(0.0)})).typ);
        try expectApproxEqAbs(
            @as(f32, 0.0),
            (try f32_sin(runtime.context(), .nil, .nil, &.{.f32(0.0)})).obj.tof32(),
            @as(f32, 1e-7),
        );
        try expectApproxEqAbs(
            @as(f32, 1.0),
            (try f32_sin(runtime.context(), .nil, .nil, &.{.f32(std.math.pi / 2.0)})).obj.tof32(),
            @as(f32, 1e-7),
        );
        try expectApproxEqAbs(
            @as(f32, 1.0),
            (try f32_cos(runtime.context(), .nil, .nil, &.{.f32(0.0)})).obj.tof32(),
            @as(f32, 1e-7),
        );
        try expectApproxEqAbs(
            @as(f32, 0.0),
            (try f32_cos(runtime.context(), .nil, .nil, &.{.f32(std.math.pi / 2.0)})).obj.tof32(),
            @as(f32, 1e-7),
        );

        // f32 asin acos atan
        try expectEqual(@as(f32, 0.0), (try f32_asin(runtime.context(), .nil, .nil, &.{.f32(0.0)})).obj.tof32());
        try expectApproxEqAbs(
            @as(f32, std.math.pi) / 2,
            (try f32_asin(runtime.context(), .nil, .nil, &.{.f32(1.0)})).obj.tof32(),
            @as(f32, 1e-6),
        );
        try expectEqual(@as(f32, 0.0), (try f32_acos(runtime.context(), .nil, .nil, &.{.f32(1.0)})).obj.tof32());
        try expectEqual(@as(f32, 0.0), (try f32_atan(runtime.context(), .nil, .nil, &.{.f32(0.0)})).obj.tof32());

        // f32 sinh cosh tanh
        try expectEqual(@as(f32, 0.0), (try f32_sinh(runtime.context(), .nil, .nil, &.{.f32(0.0)})).obj.tof32());
        try expectEqual(@as(f32, 1.0), (try f32_cosh(runtime.context(), .nil, .nil, &.{.f32(0.0)})).obj.tof32());
        try expectEqual(@as(f32, 0.0), (try f32_tanh(runtime.context(), .nil, .nil, &.{.f32(0.0)})).obj.tof32());

        // f32 asinh acosh atanh
        try expectEqual(@as(f32, 0.0), (try f32_asinh(runtime.context(), .nil, .nil, &.{.f32(0.0)})).obj.tof32());
        try expectEqual(@as(f32, 0.0), (try f32_acosh(runtime.context(), .nil, .nil, &.{.f32(1.0)})).obj.tof32());
        try expectEqual(@as(f32, 0.0), (try f32_atanh(runtime.context(), .nil, .nil, &.{.f32(0.0)})).obj.tof32());

        // f16 sin cos tan
        try expectEqual(@as(f16, 0.0), (try f16_sin(runtime.context(), .nil, .nil, &.{.f16(0.0)})).obj.tof16());
        try expectEqual(@as(f16, 1.0), (try f16_cos(runtime.context(), .nil, .nil, &.{.f16(0.0)})).obj.tof16());
        try expectEqual(@as(f16, 0.0), (try f16_tan(runtime.context(), .nil, .nil, &.{.f16(0.0)})).obj.tof16());

        // f16 asin acos atan
        try expectEqual(@as(f16, 0.0), (try f16_asin(runtime.context(), .nil, .nil, &.{.f16(0.0)})).obj.tof16());
        try expectEqual(@as(f16, 0.0), (try f16_acos(runtime.context(), .nil, .nil, &.{.f16(1.0)})).obj.tof16());
        try expectEqual(@as(f16, 0.0), (try f16_atan(runtime.context(), .nil, .nil, &.{.f16(0.0)})).obj.tof16());

        // f16 sinh cosh tanh asinh acosh atanh
        try expectEqual(@as(f16, 0.0), (try f16_sinh(runtime.context(), .nil, .nil, &.{.f16(0.0)})).obj.tof16());
        try expectEqual(@as(f16, 1.0), (try f16_cosh(runtime.context(), .nil, .nil, &.{.f16(0.0)})).obj.tof16());
        try expectEqual(@as(f16, 0.0), (try f16_tanh(runtime.context(), .nil, .nil, &.{.f16(0.0)})).obj.tof16());
        try expectEqual(@as(f16, 0.0), (try f16_asinh(runtime.context(), .nil, .nil, &.{.f16(0.0)})).obj.tof16());
        try expectEqual(@as(f16, 0.0), (try f16_acosh(runtime.context(), .nil, .nil, &.{.f16(1.0)})).obj.tof16());
        try expectEqual(@as(f16, 0.0), (try f16_atanh(runtime.context(), .nil, .nil, &.{.f16(0.0)})).obj.tof16());
    }

    // ---- sqrt and approx ----
    {

        // f64 sqrt
        try expectEqual(@as(f64, 0.0), (try f64_sqrt(runtime.context(), .nil, .nil, &.{.f64(0.0)})).obj.tof64());
        try expectEqual(@as(f64, 1.0), (try f64_sqrt(runtime.context(), .nil, .nil, &.{.f64(1.0)})).obj.tof64());
        try expectEqual(@as(f64, 2.0), (try f64_sqrt(runtime.context(), .nil, .nil, &.{.f64(4.0)})).obj.tof64());
        try expectEqual(@as(f64, 3.0), (try f64_sqrt(runtime.context(), .nil, .nil, &.{.f64(9.0)})).obj.tof64());

        // f32 sqrt
        try expectEqual(@as(f32, 2.0), (try f32_sqrt(runtime.context(), .nil, .nil, &.{.f32(4.0)})).obj.tof32());
        try expectEqual(@as(f32, 3.0), (try f32_sqrt(runtime.context(), .nil, .nil, &.{.f32(9.0)})).obj.tof32());

        // f16 sqrt
        try expectEqual(@as(f16, 2.0), (try f16_sqrt(runtime.context(), .nil, .nil, &.{.f16(4.0)})).obj.tof16());
        try expectEqual(@as(f16, 3.0), (try f16_sqrt(runtime.context(), .nil, .nil, &.{.f16(9.0)})).obj.tof16());

        // f16 comparisons
        try expect((try f16_eq(runtime.context(), .nil, .nil, &.{ .f16(1.0), .f16(1.0) })).obj.toBool());
        try expect(!(try f16_eq(runtime.context(), .nil, .nil, &.{ .f16(1.0), .f16(2.0) })).obj.toBool());
        try expect((try f16_gt(runtime.context(), .nil, .nil, &.{ .f16(2.0), .f16(1.0) })).obj.toBool());
        try expect((try f16_lt(runtime.context(), .nil, .nil, &.{ .f16(1.0), .f16(2.0) })).obj.toBool());

        // f64 approx
        try expect(
            (try f64_approx(
                runtime.context(),
                .nil,
                .nil,
                &.{ .f64(3.14159), .f64(3.14160), .f64(1e-4) },
            )).obj.toBool(),
        );
        try expect(
            !(try f64_approx(
                runtime.context(),
                .nil,
                .nil,
                &.{ .f64(3.14), .f64(3.2), .f64(1e-4) },
            )).obj.toBool(),
        );

        // f32 approx
        try expect(
            (try f32_approx(
                runtime.context(),
                .nil,
                .nil,
                &.{ .f32(1.0), .f32(1.0001), .f32(1e-3) },
            )).obj.toBool(),
        );
        try expect(
            !(try f32_approx(
                runtime.context(),
                .nil,
                .nil,
                &.{ .f32(1.0), .f32(2.0), .f32(1e-3) },
            )).obj.toBool(),
        );
    }

    // ---- construct and avg ----
    {

        // f64 construct from same type
        try expectEqual(@as(f64, 42.5), (try f64_construct(runtime.context(), .nil, .nil, &.{.f64(42.5)})).obj.tof64());

        // f64 construct from f32 coerces up (f32→f64 widening is exact)
        try expectEqual(
            @as(f64, @as(f32, 3.14)),
            (try f64_construct(runtime.context(), .nil, .nil, &.{.f32(3.14)})).obj.tof64(),
        );

        // f32 construct from f64 coerces down (narrowing to nearest f32)
        try expectEqual(@as(f32, 3.14), (try f32_construct(runtime.context(), .nil, .nil, &.{.f64(3.14)})).obj.tof32());

        // construct with zero args returns zero
        try expectEqual(@as(f64, 0.0), (try f64_construct(runtime.context(), .nil, .nil, &.{})).obj.tof64());
        try expectEqual(@as(f32, 0.0), (try f32_construct(runtime.context(), .nil, .nil, &.{})).obj.tof32());
        try expectEqual(@as(f16, 0.0), (try f16_construct(runtime.context(), .nil, .nil, &.{})).obj.tof16());

        // comparisons return bool type
        try expectEqual(
            skript.builtins.type_bool,
            (try f64_eq(runtime.context(), .nil, .nil, &.{ .f64(1), .f64(1) })).typ,
        );
        try expectEqual(
            skript.builtins.type_bool,
            (try f64_ne(runtime.context(), .nil, .nil, &.{ .f64(1), .f64(2) })).typ,
        );
        try expectEqual(
            skript.builtins.type_bool,
            (try f64_gt(runtime.context(), .nil, .nil, &.{ .f64(2), .f64(1) })).typ,
        );
        try expectEqual(
            skript.builtins.type_bool,
            (try f64_lt(runtime.context(), .nil, .nil, &.{ .f64(1), .f64(2) })).typ,
        );
        try expectEqual(
            skript.builtins.type_bool,
            (try f64_gte(runtime.context(), .nil, .nil, &.{ .f64(1), .f64(1) })).typ,
        );
        try expectEqual(
            skript.builtins.type_bool,
            (try f64_lte(runtime.context(), .nil, .nil, &.{ .f64(1), .f64(1) })).typ,
        );

        // approx returns bool type
        try expectEqual(
            skript.builtins.type_bool,
            (try f64_approx(runtime.context(), .nil, .nil, &.{ .f64(1), .f64(1), .f64(1e-6) })).typ,
        );

        // f64 avg (list built manually)
        {
            var list = Value.nil;
            inline for (.{ 4.0, 3.0, 2.0, 1.0 }) |n| {
                const cell_ref = try runtime.store.create([2]Value);
                const cell_ptr = cell_ref.deref([2]Value);
                cell_ptr.* = .{ .f64(n), list };
                list = Value.cons(cell_ref.toObject());
            }
            try expectEqual(@as(f64, 2.5), (try f64_avg(runtime.context(), .nil, .nil, &.{list})).obj.tof64());
        }

        // f64 avg via evalString
        try expectEqual(
            @as(f64, 2.5),
            (try runtime.evalString("(@f64.avg (cons 1.0 (cons 2.0 (cons 3.0 (cons 4.0 nil)))))")).obj.tof64(),
        );

        // f64 avg via list
        try expectEqual(@as(f64, 2.5), (try runtime.evalString("(@f64.avg (list 1.0 2.0 3.0 4.0))")).obj.tof64());

        // f64 avg via evalString (3 elem, non-integer)
        try expectEqual(
            @as(f64, 2.5),
            (try runtime.evalString("(@f64.avg (cons 1.5 (cons 2.5 (cons 3.5 nil))))")).obj.tof64(),
        );
    }

    // ---- avg edge cases and arity errors ----
    {

        // f64 avg empty list
        try expectError(error.Unsupported, f64_avg(runtime.context(), .nil, .nil, &.{.nil}));

        // f64 avg arity
        try expectError(error.ArityMismatch, f64_avg(runtime.context(), .nil, .nil, &.{}));
        try expectError(error.ArityMismatch, f64_avg(runtime.context(), .nil, .nil, &.{ .nil, .nil }));

        // arithmetic arity errors
        try expectError(error.ArityMismatch, f64_add(runtime.context(), .nil, .nil, &.{}));
        try expectError(error.ArityMismatch, f64_sub(runtime.context(), .nil, .nil, &.{}));
        try expectError(error.ArityMismatch, f64_mul(runtime.context(), .nil, .nil, &.{}));
        try expectError(error.ArityMismatch, f64_div(runtime.context(), .nil, .nil, &.{}));
        try expectError(error.ArityMismatch, f64_add(runtime.context(), .nil, .nil, &.{.f64(1.0)}));
        try expectError(
            error.ArityMismatch,
            f64_add(runtime.context(), .nil, .nil, &.{ .f64(1.0), .f64(2.0), .f64(3.0) }),
        );

        // unary arity errors
        try expectError(error.ArityMismatch, f64_sin(runtime.context(), .nil, .nil, &.{}));
        try expectError(error.ArityMismatch, f64_sin(runtime.context(), .nil, .nil, &.{ .f64(1.0), .f64(2.0) }));
        try expectError(error.ArityMismatch, f64_cos(runtime.context(), .nil, .nil, &.{}));
        try expectError(error.ArityMismatch, f64_sqrt(runtime.context(), .nil, .nil, &.{}));
        try expectError(error.ArityMismatch, f64_asin(runtime.context(), .nil, .nil, &.{}));
        try expectError(error.ArityMismatch, f64_atan(runtime.context(), .nil, .nil, &.{}));

        // approx arity errors
        try expectError(error.ArityMismatch, f64_approx(runtime.context(), .nil, .nil, &.{}));
        try expectError(error.ArityMismatch, f64_approx(runtime.context(), .nil, .nil, &.{ .f64(1.0), .f64(2.0) }));
        try expectError(
            error.ArityMismatch,
            f64_approx(runtime.context(), .nil, .nil, &.{ .f64(1.0), .f64(2.0), .f64(3.0), .f64(4.0) }),
        );

        // atan2 arity errors
        try expectError(error.ArityMismatch, f64_atan2(runtime.context(), .nil, .nil, &.{}));
        try expectError(error.ArityMismatch, f64_atan2(runtime.context(), .nil, .nil, &.{.f64(1.0)}));
        try expectError(
            error.ArityMismatch,
            f64_atan2(runtime.context(), .nil, .nil, &.{ .f64(1.0), .f64(2.0), .f64(3.0) }),
        );

        // construct arity errors
        try expectError(error.ArityMismatch, f64_construct(runtime.context(), .nil, .nil, &.{ .f64(1.0), .f64(2.0) }));
    }

    // ---- edge cases ----
    {

        // f64 div by zero produces infinity
        try expectEqual(
            std.math.inf(f64),
            (try f64_div(runtime.context(), .nil, .nil, &.{ .f64(1.0), .f64(0.0) })).obj.tof64(),
        );

        // f64 sqrt of zero
        try expectEqual(@as(f64, 0.0), (try f64_sqrt(runtime.context(), .nil, .nil, &.{.f64(0.0)})).obj.tof64());

        // f64 sqrt of negative produces nan
        try expect(std.math.isNan((try f64_sqrt(runtime.context(), .nil, .nil, &.{.f64(-1.0)})).obj.tof64()));

        // f64 negatives in arithmetic
        try expectEqual(
            @as(f64, -5.0),
            (try f64_add(runtime.context(), .nil, .nil, &.{ .f64(-2.0), .f64(-3.0) })).obj.tof64(),
        );
        try expectEqual(
            @as(f64, 5.0),
            (try f64_sub(runtime.context(), .nil, .nil, &.{ .f64(2.0), .f64(-3.0) })).obj.tof64(),
        );
        try expectEqual(
            @as(f64, -6.0),
            (try f64_mul(runtime.context(), .nil, .nil, &.{ .f64(-2.0), .f64(3.0) })).obj.tof64(),
        );
        try expectEqual(
            @as(f64, -1.5),
            (try f64_div(runtime.context(), .nil, .nil, &.{ .f64(-3.0), .f64(2.0) })).obj.tof64(),
        );

        // f64 sin negative
        try expectApproxEqAbs(
            @as(f64, -1.0),
            (try f64_sin(runtime.context(), .nil, .nil, &.{.f64(-std.math.pi / 2.0)})).obj.tof64(),
            @as(f64, 1e-15),
        );
    }

    // ---- exponential power rounding ----
    {

        // f64 exp
        try expectEqual(@as(f64, 1.0), (try f64_exp(runtime.context(), .nil, .nil, &.{.f64(0.0)})).obj.tof64());
        try expectApproxEqAbs(
            std.math.e,
            (try f64_exp(runtime.context(), .nil, .nil, &.{.f64(1.0)})).obj.tof64(),
            @as(f64, 1e-12),
        );

        // f64 log
        try expectEqual(@as(f64, 0.0), (try f64_log(runtime.context(), .nil, .nil, &.{.f64(1.0)})).obj.tof64());
        try expectApproxEqAbs(
            @as(f64, 1.0),
            (try f64_log(runtime.context(), .nil, .nil, &.{.f64(std.math.e)})).obj.tof64(),
            @as(f64, 1e-12),
        );

        // f64 log2
        try expectEqual(@as(f64, 0.0), (try f64_log2(runtime.context(), .nil, .nil, &.{.f64(1.0)})).obj.tof64());
        try expectEqual(@as(f64, 1.0), (try f64_log2(runtime.context(), .nil, .nil, &.{.f64(2.0)})).obj.tof64());
        try expectEqual(@as(f64, 3.0), (try f64_log2(runtime.context(), .nil, .nil, &.{.f64(8.0)})).obj.tof64());

        // f64 log10
        try expectEqual(@as(f64, 0.0), (try f64_log10(runtime.context(), .nil, .nil, &.{.f64(1.0)})).obj.tof64());
        try expectEqual(@as(f64, 1.0), (try f64_log10(runtime.context(), .nil, .nil, &.{.f64(10.0)})).obj.tof64());
        try expectEqual(@as(f64, 2.0), (try f64_log10(runtime.context(), .nil, .nil, &.{.f64(100.0)})).obj.tof64());

        // f64 pow
        try expectEqual(
            @as(f64, 1.0),
            (try f64_pow(runtime.context(), .nil, .nil, &.{ .f64(2.0), .f64(0.0) })).obj.tof64(),
        );
        try expectEqual(
            @as(f64, 8.0),
            (try f64_pow(runtime.context(), .nil, .nil, &.{ .f64(2.0), .f64(3.0) })).obj.tof64(),
        );
        try expectApproxEqAbs(
            @as(f64, 2.0),
            (try f64_pow(runtime.context(), .nil, .nil, &.{ .f64(4.0), .f64(0.5) })).obj.tof64(),
            @as(f64, 1e-12),
        );

        // f64 hypot
        try expectEqual(
            @as(f64, 5.0),
            (try f64_hypot(runtime.context(), .nil, .nil, &.{ .f64(3.0), .f64(4.0) })).obj.tof64(),
        );
        try expectEqual(
            @as(f64, 0.0),
            (try f64_hypot(runtime.context(), .nil, .nil, &.{ .f64(0.0), .f64(0.0) })).obj.tof64(),
        );

        // f64 floor ceil round trunc
        try expectEqual(@as(f64, 3.0), (try f64_floor(runtime.context(), .nil, .nil, &.{.f64(3.7)})).obj.tof64());
        try expectEqual(@as(f64, 4.0), (try f64_ceil(runtime.context(), .nil, .nil, &.{.f64(3.7)})).obj.tof64());
        try expectEqual(@as(f64, 4.0), (try f64_round(runtime.context(), .nil, .nil, &.{.f64(3.7)})).obj.tof64());
        try expectEqual(@as(f64, 3.0), (try f64_trunc(runtime.context(), .nil, .nil, &.{.f64(3.7)})).obj.tof64());
        try expectEqual(@as(f64, -4.0), (try f64_floor(runtime.context(), .nil, .nil, &.{.f64(-3.7)})).obj.tof64());
        try expectEqual(@as(f64, -3.0), (try f64_ceil(runtime.context(), .nil, .nil, &.{.f64(-3.7)})).obj.tof64());
        try expectEqual(@as(f64, -4.0), (try f64_round(runtime.context(), .nil, .nil, &.{.f64(-3.7)})).obj.tof64());
        try expectEqual(@as(f64, -3.0), (try f64_trunc(runtime.context(), .nil, .nil, &.{.f64(-3.7)})).obj.tof64());

        // f64 abs min max sign
        try expectEqual(@as(f64, 3.5), (try f64_abs(runtime.context(), .nil, .nil, &.{.f64(-3.5)})).obj.tof64());
        try expectEqual(
            @as(f64, 2.0),
            (try f64_min(runtime.context(), .nil, .nil, &.{ .f64(2.0), .f64(5.0) })).obj.tof64(),
        );
        try expectEqual(
            @as(f64, 5.0),
            (try f64_max(runtime.context(), .nil, .nil, &.{ .f64(2.0), .f64(5.0) })).obj.tof64(),
        );
        try expectEqual(@as(f64, 1.0), (try f64_sign(runtime.context(), .nil, .nil, &.{.f64(3.0)})).obj.tof64());
        try expectEqual(@as(f64, -1.0), (try f64_sign(runtime.context(), .nil, .nil, &.{.f64(-3.0)})).obj.tof64());
        try expectEqual(@as(f64, 0.0), (try f64_sign(runtime.context(), .nil, .nil, &.{.f64(0.0)})).obj.tof64());

        // f32 exp log log2 log10
        try expectEqual(@as(f32, 1.0), (try f32_exp(runtime.context(), .nil, .nil, &.{.f32(0.0)})).obj.tof32());
        try expectEqual(@as(f32, 0.0), (try f32_log(runtime.context(), .nil, .nil, &.{.f32(1.0)})).obj.tof32());
        try expectEqual(@as(f32, 1.0), (try f32_log2(runtime.context(), .nil, .nil, &.{.f32(2.0)})).obj.tof32());
        try expectEqual(@as(f32, 1.0), (try f32_log10(runtime.context(), .nil, .nil, &.{.f32(10.0)})).obj.tof32());

        // f32 pow hypot
        try expectEqual(
            @as(f32, 27.0),
            (try f32_pow(runtime.context(), .nil, .nil, &.{ .f32(3.0), .f32(3.0) })).obj.tof32(),
        );
        try expectEqual(
            @as(f32, 5.0),
            (try f32_hypot(runtime.context(), .nil, .nil, &.{ .f32(3.0), .f32(4.0) })).obj.tof32(),
        );

        // f32 floor ceil round trunc abs min max sign
        try expectEqual(@as(f32, 2.0), (try f32_floor(runtime.context(), .nil, .nil, &.{.f32(2.7)})).obj.tof32());
        try expectEqual(@as(f32, 3.0), (try f32_ceil(runtime.context(), .nil, .nil, &.{.f32(2.7)})).obj.tof32());
        try expectEqual(@as(f32, 3.0), (try f32_round(runtime.context(), .nil, .nil, &.{.f32(2.7)})).obj.tof32());
        try expectEqual(@as(f32, 2.0), (try f32_trunc(runtime.context(), .nil, .nil, &.{.f32(2.7)})).obj.tof32());
        try expectEqual(@as(f32, 2.7), (try f32_abs(runtime.context(), .nil, .nil, &.{.f32(-2.7)})).obj.tof32());
        try expectEqual(
            @as(f32, 1.0),
            (try f32_min(runtime.context(), .nil, .nil, &.{ .f32(1.0), .f32(3.0) })).obj.tof32(),
        );
        try expectEqual(
            @as(f32, 3.0),
            (try f32_max(runtime.context(), .nil, .nil, &.{ .f32(1.0), .f32(3.0) })).obj.tof32(),
        );
        try expectEqual(@as(f32, 1.0), (try f32_sign(runtime.context(), .nil, .nil, &.{.f32(2.0)})).obj.tof32());
        try expectEqual(@as(f32, -1.0), (try f32_sign(runtime.context(), .nil, .nil, &.{.f32(-2.0)})).obj.tof32());
        try expectEqual(@as(f32, 0.0), (try f32_sign(runtime.context(), .nil, .nil, &.{.f32(0.0)})).obj.tof32());

        // f16 exp log pow hypot floor ceil round trunc abs min max sign
        try expectEqual(@as(f16, 1.0), (try f16_exp(runtime.context(), .nil, .nil, &.{.f16(0.0)})).obj.tof16());
        try expectEqual(@as(f16, 0.0), (try f16_log(runtime.context(), .nil, .nil, &.{.f16(1.0)})).obj.tof16());
        try expectEqual(
            @as(f16, 8.0),
            (try f16_pow(runtime.context(), .nil, .nil, &.{ .f16(2.0), .f16(3.0) })).obj.tof16(),
        );
        try expectEqual(
            @as(f16, 5.0),
            (try f16_hypot(runtime.context(), .nil, .nil, &.{ .f16(3.0), .f16(4.0) })).obj.tof16(),
        );
        try expectEqual(@as(f16, 3.0), (try f16_floor(runtime.context(), .nil, .nil, &.{.f16(3.5)})).obj.tof16());
        try expectEqual(@as(f16, 4.0), (try f16_ceil(runtime.context(), .nil, .nil, &.{.f16(3.5)})).obj.tof16());
        try expectEqual(@as(f16, 4.0), (try f16_round(runtime.context(), .nil, .nil, &.{.f16(3.5)})).obj.tof16());
        try expectEqual(@as(f16, 3.0), (try f16_trunc(runtime.context(), .nil, .nil, &.{.f16(3.5)})).obj.tof16());
        try expectEqual(@as(f16, 3.5), (try f16_abs(runtime.context(), .nil, .nil, &.{.f16(-3.5)})).obj.tof16());
        try expectEqual(
            @as(f16, 1.0),
            (try f16_min(runtime.context(), .nil, .nil, &.{ .f16(1.0), .f16(4.0) })).obj.tof16(),
        );
        try expectEqual(
            @as(f16, 4.0),
            (try f16_max(runtime.context(), .nil, .nil, &.{ .f16(1.0), .f16(4.0) })).obj.tof16(),
        );
        try expectEqual(@as(f16, 1.0), (try f16_sign(runtime.context(), .nil, .nil, &.{.f16(2.0)})).obj.tof16());
        try expectEqual(@as(f16, -1.0), (try f16_sign(runtime.context(), .nil, .nil, &.{.f16(-2.0)})).obj.tof16());
        try expectEqual(@as(f16, 0.0), (try f16_sign(runtime.context(), .nil, .nil, &.{.f16(0.0)})).obj.tof16());
    }

    // ---- f64 misc functions ----
    {

        // f64 fract
        try expectApproxEqAbs(
            @as(f64, 0.14),
            (try f64_fract(runtime.context(), .nil, .nil, &.{.f64(3.14)})).obj.tof64(),
            @as(f64, 1e-12),
        );
        try expectEqual(@as(f64, -0.5), (try f64_fract(runtime.context(), .nil, .nil, &.{.f64(-1.5)})).obj.tof64());

        // f64 mod floored
        try expectEqual(
            @as(f64, 1.0),
            (try f64_mod(runtime.context(), .nil, .nil, &.{ .f64(7.0), .f64(3.0) })).obj.tof64(),
        );
        try expectEqual(
            @as(f64, 2.0),
            (try f64_mod(runtime.context(), .nil, .nil, &.{ .f64(-7.0), .f64(3.0) })).obj.tof64(),
        );

        // f64 rem truncated
        try expectEqual(
            @as(f64, 1.0),
            (try f64_rem(runtime.context(), .nil, .nil, &.{ .f64(7.0), .f64(3.0) })).obj.tof64(),
        );
        try expectEqual(
            @as(f64, -1.0),
            (try f64_rem(runtime.context(), .nil, .nil, &.{ .f64(-7.0), .f64(3.0) })).obj.tof64(),
        );

        // f64 clamp blend unblend remap
        try expectEqual(
            @as(f64, 3.0),
            (try f64_clamp(runtime.context(), .nil, .nil, &.{ .f64(5.0), .f64(0.0), .f64(3.0) })).obj.tof64(),
        );
        try expectEqual(
            @as(f64, 0.0),
            (try f64_clamp(runtime.context(), .nil, .nil, &.{ .f64(-1.0), .f64(0.0), .f64(3.0) })).obj.tof64(),
        );
        try expectEqual(
            @as(f64, 5.0),
            (try f64_blend(runtime.context(), .nil, .nil, &.{ .f64(0.0), .f64(10.0), .f64(0.5) })).obj.tof64(),
        );
        try expectEqual(
            @as(f64, 0.5),
            (try f64_unblend(runtime.context(), .nil, .nil, &.{ .f64(0.0), .f64(10.0), .f64(5.0) })).obj.tof64(),
        );
        const remapped_f64 = try f64_remap(
            runtime.context(),
            .nil,
            .nil,
            &.{ .f64(5.0), .f64(0.0), .f64(10.0), .f64(100.0), .f64(200.0) },
        );
        try expectEqual(@as(f64, 150.0), remapped_f64.obj.tof64());

        // f64 predicates
        try expect((try f64_is_nan(runtime.context(), .nil, .nil, &.{.f64(std.math.nan(f64))})).obj.toBool());
        try expect(!(try f64_is_nan(runtime.context(), .nil, .nil, &.{.f64(1.0)})).obj.toBool());
        try expect((try f64_is_inf(runtime.context(), .nil, .nil, &.{.f64(std.math.inf(f64))})).obj.toBool());
        try expect(!(try f64_is_inf(runtime.context(), .nil, .nil, &.{.f64(1.0)})).obj.toBool());
        try expect((try f64_is_finite(runtime.context(), .nil, .nil, &.{.f64(1.0)})).obj.toBool());
        try expect(!(try f64_is_finite(runtime.context(), .nil, .nil, &.{.f64(std.math.inf(f64))})).obj.toBool());
        try expect((try f64_is_zero(runtime.context(), .nil, .nil, &.{.f64(0.0)})).obj.toBool());
        try expect(!(try f64_is_zero(runtime.context(), .nil, .nil, &.{.f64(1.0)})).obj.toBool());

        // f64 is-odd is-even
        try expect((try f64_is_odd(runtime.context(), .nil, .nil, &.{.f64(3.0)})).obj.toBool());
        try expect(!(try f64_is_odd(runtime.context(), .nil, .nil, &.{.f64(4.0)})).obj.toBool());
        try expect((try f64_is_even(runtime.context(), .nil, .nil, &.{.f64(4.0)})).obj.toBool());
        try expect(!(try f64_is_even(runtime.context(), .nil, .nil, &.{.f64(3.0)})).obj.toBool());

        // f64 deg->rad rad->deg
        try expectApproxEqAbs(
            @as(f64, std.math.pi),
            (try f64_deg_to_rad(runtime.context(), .nil, .nil, &.{.f64(180.0)})).obj.tof64(),
            @as(f64, 1e-12),
        );
        try expectApproxEqAbs(
            @as(f64, 180.0),
            (try f64_rad_to_deg(runtime.context(), .nil, .nil, &.{.f64(std.math.pi)})).obj.tof64(),
            @as(f64, 1e-10),
        );

        // f64 nextafter prevbefore
        try expect((try f64_nextafter(runtime.context(), .nil, .nil, &.{ .f64(0.0), .f64(1.0) })).obj.tof64() > 0);
        try expect((try f64_prevbefore(runtime.context(), .nil, .nil, &.{.f64(1.0)})).obj.tof64() < 1.0);

        // f64 expm1 log1p
        try expectEqual(@as(f64, 0.0), (try f64_expm1(runtime.context(), .nil, .nil, &.{.f64(0.0)})).obj.tof64());
        try expectApproxEqAbs(
            @as(f64, std.math.e - 1),
            (try f64_expm1(runtime.context(), .nil, .nil, &.{.f64(1.0)})).obj.tof64(),
            @as(f64, 1e-12),
        );
        try expectEqual(@as(f64, 0.0), (try f64_log1p(runtime.context(), .nil, .nil, &.{.f64(0.0)})).obj.tof64());
        try expectApproxEqAbs(
            @as(f64, 1.0),
            (try f64_log1p(runtime.context(), .nil, .nil, &.{.f64(std.math.e - 1)})).obj.tof64(),
            @as(f64, 1e-12),
        );
    }

    // ---- f32 and f16 misc functions ----
    {

        // f32 fract mod rem clamp
        try expectApproxEqAbs(
            @as(f32, 0.14),
            (try f32_fract(runtime.context(), .nil, .nil, &.{.f32(3.14)})).obj.tof32(),
            @as(f32, 1e-6),
        );
        try expectEqual(
            @as(f32, 2.0),
            (try f32_mod(runtime.context(), .nil, .nil, &.{ .f32(-7.0), .f32(3.0) })).obj.tof32(),
        );
        try expectEqual(
            @as(f32, -1.0),
            (try f32_rem(runtime.context(), .nil, .nil, &.{ .f32(-7.0), .f32(3.0) })).obj.tof32(),
        );
        try expectEqual(
            @as(f32, 3.0),
            (try f32_clamp(runtime.context(), .nil, .nil, &.{ .f32(5.0), .f32(0.0), .f32(3.0) })).obj.tof32(),
        );

        // f32 blend unblend remap deg-rad rad-deg
        try expectEqual(
            @as(f32, 5.0),
            (try f32_blend(runtime.context(), .nil, .nil, &.{ .f32(0.0), .f32(10.0), .f32(0.5) })).obj.tof32(),
        );
        try expectEqual(
            @as(f32, 0.5),
            (try f32_unblend(runtime.context(), .nil, .nil, &.{ .f32(0.0), .f32(10.0), .f32(5.0) })).obj.tof32(),
        );
        const remapped_f32 = try f32_remap(
            runtime.context(),
            .nil,
            .nil,
            &.{ .f32(5.0), .f32(0.0), .f32(10.0), .f32(100.0), .f32(200.0) },
        );
        try expectEqual(@as(f32, 150.0), remapped_f32.obj.tof32());
        try expectApproxEqAbs(
            @as(f32, std.math.pi),
            (try f32_deg_to_rad(runtime.context(), .nil, .nil, &.{.f32(180.0)})).obj.tof32(),
            @as(f32, 1e-6),
        );
        try expectApproxEqAbs(
            @as(f32, 180.0),
            (try f32_rad_to_deg(runtime.context(), .nil, .nil, &.{.f32(std.math.pi)})).obj.tof32(),
            @as(f32, 1e-6),
        );

        // f32 predicates
        try expect((try f32_is_nan(runtime.context(), .nil, .nil, &.{.f32(std.math.nan(f32))})).obj.toBool());
        try expect(!(try f32_is_nan(runtime.context(), .nil, .nil, &.{.f32(1.0)})).obj.toBool());
        try expect((try f32_is_inf(runtime.context(), .nil, .nil, &.{.f32(std.math.inf(f32))})).obj.toBool());
        try expect(!(try f32_is_inf(runtime.context(), .nil, .nil, &.{.f32(1.0)})).obj.toBool());
        try expect((try f32_is_finite(runtime.context(), .nil, .nil, &.{.f32(1.0)})).obj.toBool());
        try expect(!(try f32_is_finite(runtime.context(), .nil, .nil, &.{.f32(std.math.inf(f32))})).obj.toBool());
        try expect((try f32_is_zero(runtime.context(), .nil, .nil, &.{.f32(0.0)})).obj.toBool());
        try expect(!(try f32_is_zero(runtime.context(), .nil, .nil, &.{.f32(1.0)})).obj.toBool());
        try expect((try f32_is_odd(runtime.context(), .nil, .nil, &.{.f32(3.0)})).obj.toBool());
        try expect((try f32_is_even(runtime.context(), .nil, .nil, &.{.f32(4.0)})).obj.toBool());

        // f32 nextafter prevbefore expm1 log1p
        try expect((try f32_nextafter(runtime.context(), .nil, .nil, &.{ .f32(0.0), .f32(1.0) })).obj.tof32() > 0);
        try expect((try f32_prevbefore(runtime.context(), .nil, .nil, &.{.f32(1.0)})).obj.tof32() < 1.0);
        try expectEqual(@as(f32, 0.0), (try f32_expm1(runtime.context(), .nil, .nil, &.{.f32(0.0)})).obj.tof32());
        try expectEqual(@as(f32, 0.0), (try f32_log1p(runtime.context(), .nil, .nil, &.{.f32(0.0)})).obj.tof32());

        // f16 fract mod rem clamp blend unblend remap
        try expectApproxEqAbs(
            @as(f16, 0.14),
            (try f16_fract(runtime.context(), .nil, .nil, &.{.f16(3.14)})).obj.tof16(),
            @as(f16, 1e-2),
        );
        try expectEqual(
            @as(f16, 2.0),
            (try f16_mod(runtime.context(), .nil, .nil, &.{ .f16(-7.0), .f16(3.0) })).obj.tof16(),
        );
        try expectEqual(
            @as(f16, -1.0),
            (try f16_rem(runtime.context(), .nil, .nil, &.{ .f16(-7.0), .f16(3.0) })).obj.tof16(),
        );
        try expectEqual(
            @as(f16, 3.0),
            (try f16_clamp(runtime.context(), .nil, .nil, &.{ .f16(5.0), .f16(0.0), .f16(3.0) })).obj.tof16(),
        );
        try expectEqual(
            @as(f16, 5.0),
            (try f16_blend(runtime.context(), .nil, .nil, &.{ .f16(0.0), .f16(10.0), .f16(0.5) })).obj.tof16(),
        );
        try expectEqual(
            @as(f16, 0.5),
            (try f16_unblend(runtime.context(), .nil, .nil, &.{ .f16(0.0), .f16(10.0), .f16(5.0) })).obj.tof16(),
        );
        const remapped_f16 = try f16_remap(
            runtime.context(),
            .nil,
            .nil,
            &.{ .f16(5.0), .f16(0.0), .f16(10.0), .f16(100.0), .f16(200.0) },
        );
        try expectEqual(@as(f16, 150.0), remapped_f16.obj.tof16());

        // f16 predicates deg-rad rad-deg nextafter prevbefore expm1 log1p
        const f16_nan: f16 = @floatCast(std.math.sqrt(@as(f32, -1.0)));
        try expect((try f16_is_nan(runtime.context(), .nil, .nil, &.{.f16(f16_nan)})).obj.toBool());
        try expect(!(try f16_is_nan(runtime.context(), .nil, .nil, &.{.f16(1.0)})).obj.toBool());
        try expect((try f16_is_inf(runtime.context(), .nil, .nil, &.{.f16(std.math.inf(f16))})).obj.toBool());
        try expect((try f16_is_finite(runtime.context(), .nil, .nil, &.{.f16(1.0)})).obj.toBool());
        try expect((try f16_is_zero(runtime.context(), .nil, .nil, &.{.f16(0.0)})).obj.toBool());
        try expect((try f16_is_odd(runtime.context(), .nil, .nil, &.{.f16(3.0)})).obj.toBool());
        try expect((try f16_is_even(runtime.context(), .nil, .nil, &.{.f16(4.0)})).obj.toBool());
        try expectApproxEqAbs(
            @as(f16, std.math.pi),
            (try f16_deg_to_rad(runtime.context(), .nil, .nil, &.{.f16(180.0)})).obj.tof16(),
            @as(f16, 1e-2),
        );
        try expectApproxEqAbs(
            @as(f16, 180.0),
            (try f16_rad_to_deg(runtime.context(), .nil, .nil, &.{.f16(std.math.pi)})).obj.tof16(),
            @as(f16, 5e-1),
        );
        try expect((try f16_nextafter(runtime.context(), .nil, .nil, &.{ .f16(0.0), .f16(1.0) })).obj.tof16() > 0);
        try expect((try f16_prevbefore(runtime.context(), .nil, .nil, &.{.f16(1.0)})).obj.tof16() < 1.0);
        try expectEqual(@as(f16, 0.0), (try f16_expm1(runtime.context(), .nil, .nil, &.{.f16(0.0)})).obj.tof16());
        try expectEqual(@as(f16, 0.0), (try f16_log1p(runtime.context(), .nil, .nil, &.{.f16(0.0)})).obj.tof16());
    }
}
