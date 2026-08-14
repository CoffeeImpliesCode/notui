const std = @import("std");

const skript = @import("../root.zig");
const Value = skript.Value;
const Object = skript.Object;
const Error = skript.Error;
const EvalContext = skript.EvalContext;
const Func = skript.Func;
const Runtime = skript.Runtime;

const intrin = @import("root.zig");
const convertToValue = intrin.convertToValue;

const cmath = std.math.complex;
const Complex = cmath.Complex;

// ---- ops ----

const Add = struct {
    fn eval(comptime T: type, ra: T, ia: T, rb: T, ib: T) struct { T, T } {
        return .{ ra + rb, ia + ib };
    }
};

const Sub = struct {
    fn eval(comptime T: type, ra: T, ia: T, rb: T, ib: T) struct { T, T } {
        return .{ ra - rb, ia - ib };
    }
};

const Mul = struct {
    fn eval(comptime T: type, ra: T, ia: T, rb: T, ib: T) struct { T, T } {
        return .{ ra * rb - ia * ib, ra * ib + ia * rb };
    }
};

const Div = struct {
    fn eval(comptime T: type, ra: T, ia: T, rb: T, ib: T) struct { T, T } {
        const denom = rb * rb + ib * ib;
        return .{ (ra * rb + ia * ib) / denom, (ia * rb - ra * ib) / denom };
    }
};

const Pow = struct {
    fn eval(comptime T: type, ra: T, ia: T, rb: T, ib: T) struct { T, T } {
        return complexPow(T, ra, ia, rb, ib);
    }
};

const Mod = struct {
    fn eval(comptime T: type, ra: T, ia: T, rb: T, ib: T) struct { T, T } {
        return complexMod(T, ra, ia, rb, ib);
    }
};

const Rem = struct {
    fn eval(comptime T: type, ra: T, ia: T, rb: T, ib: T) struct { T, T } {
        return complexRem(T, ra, ia, rb, ib);
    }
};

// ---- cartesian constructors ----

pub fn c16Cart(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    if (args[0].typ != skript.builtins.type_f16 or args[1].typ != skript.builtins.type_f16)
        return error.TypeMismatch;
    const real = args[0].obj.tof16();
    const imag = args[1].obj.tof16();
    return .c16(.{ real, imag });
}

pub fn c32Cart(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    if (args[0].typ != skript.builtins.type_f32 or args[1].typ != skript.builtins.type_f32)
        return error.TypeMismatch;
    const real = args[0].obj.tof32();
    const imag = args[1].obj.tof32();
    return .c32(.{ real, imag });
}

pub fn c64Cart(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    if (args[0].typ != skript.builtins.type_f64 or args[1].typ != skript.builtins.type_f64)
        return error.TypeMismatch;
    const real = args[0].obj.tof64();
    const imag = args[1].obj.tof64();
    const ref_temp = try rt.runtime.store.create([2]f64);
    const ptr = ref_temp.deref([2]f64);
    ptr[0] = real;
    ptr[1] = imag;
    return .c64(ref_temp.toObject());
}

const StorageMode = enum(u1) { immediate, stored };

// ---- binary arithmetic helpers ----

fn makeBinOp(
    comptime FloatType: type,
    comptime Storage: type,
    comptime Op: type,
    comptime mode: StorageMode,
    comptime complex_type: Object,
) Func {
    return struct {
        fn f(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
            if (args.len != 2) return error.ArityMismatch;
            const expected = if (mode == .stored) skript.builtins.type_c64 else complex_type;
            // C3 coercion (types-numeric §1.4): mixed numeric calls dispatch
            // through Method.get's join fallback, which resolves the
            // same-type instance but applies it to the ORIGINAL args — so
            // the complex ops coerce their operands here (single coercion
            // point: coerceBuiltin; identity on already-correct types).
            const val_a = try intrin.coerceBuiltin(expected, rt.runtime, args[0]);
            const val_b = try intrin.coerceBuiltin(expected, rt.runtime, args[1]);
            const a_re = if (mode == .stored) val_a.obj.toRef().deref([2]f64).*[0] else val_a.obj.as(Storage)[0];
            const a_im = if (mode == .stored) val_a.obj.toRef().deref([2]f64).*[1] else val_a.obj.as(Storage)[1];
            const b_re = if (mode == .stored) val_b.obj.toRef().deref([2]f64).*[0] else val_b.obj.as(Storage)[0];
            const b_im = if (mode == .stored) val_b.obj.toRef().deref([2]f64).*[1] else val_b.obj.as(Storage)[1];
            const res = Op.eval(FloatType, a_re, a_im, b_re, b_im);
            if (mode == .stored) {
                const ref_temp = try rt.runtime.store.create([2]f64);
                const ptr = ref_temp.deref([2]f64);
                ptr[0] = res[0];
                ptr[1] = res[1];
                return .c64(ref_temp.toObject());
            } else {
                return switch (complex_type) {
                    skript.builtins.type_c16 => .c16(.{ res[0], res[1] }),
                    skript.builtins.type_c32 => .c32(.{ res[0], res[1] }),
                    else => @compileError("unreachable"),
                };
            }
        }
    }.f;
}

pub const c16_add = makeBinOp(f16, [4]f16, Add, .immediate, skript.builtins.type_c16);
pub const c16_sub = makeBinOp(f16, [4]f16, Sub, .immediate, skript.builtins.type_c16);
pub const c16_mul = makeBinOp(f16, [4]f16, Mul, .immediate, skript.builtins.type_c16);
pub const c16_div = makeBinOp(f16, [4]f16, Div, .immediate, skript.builtins.type_c16);

pub const c32_add = makeBinOp(f32, [2]f32, Add, .immediate, skript.builtins.type_c32);
pub const c32_sub = makeBinOp(f32, [2]f32, Sub, .immediate, skript.builtins.type_c32);
pub const c32_mul = makeBinOp(f32, [2]f32, Mul, .immediate, skript.builtins.type_c32);
pub const c32_div = makeBinOp(f32, [2]f32, Div, .immediate, skript.builtins.type_c32);

pub const c64_add = makeBinOp(f64, [2]f64, Add, .stored, skript.builtins.type_c64);
pub const c64_sub = makeBinOp(f64, [2]f64, Sub, .stored, skript.builtins.type_c64);
pub const c64_mul = makeBinOp(f64, [2]f64, Mul, .stored, skript.builtins.type_c64);
pub const c64_div = makeBinOp(f64, [2]f64, Div, .stored, skript.builtins.type_c64);

// ---- unary operation helpers ----

fn makeUnaryOp(
    comptime FloatType: type,
    comptime Storage: type,
    comptime mode: StorageMode,
    comptime complex_type: Object,
    comptime op: fn (FloatType, FloatType) struct { FloatType, FloatType },
) Func {
    return struct {
        fn f(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
            if (args.len != 1) return error.ArityMismatch;
            const expected = if (mode == .stored) skript.builtins.type_c64 else complex_type;
            if (args[0].typ != expected) return error.TypeMismatch;
            const re_in = if (mode == .stored) args[0].obj.toRef().deref([2]f64).*[0] else args[0].obj.as(Storage)[0];
            const im_in = if (mode == .stored) args[0].obj.toRef().deref([2]f64).*[1] else args[0].obj.as(Storage)[1];
            const res = op(re_in, im_in);
            if (mode == .stored) {
                const ref_temp = try rt.runtime.store.create([2]f64);
                const ptr = ref_temp.deref([2]f64);
                ptr[0] = res[0];
                ptr[1] = res[1];
                return .c64(ref_temp.toObject());
            } else {
                return switch (complex_type) {
                    skript.builtins.type_c16 => .c16(.{ res[0], res[1] }),
                    skript.builtins.type_c32 => .c32(.{ res[0], res[1] }),
                    else => @compileError("unreachable"),
                };
            }
        }
    }.f;
}

// ---- trigonometric functions ----

// ---- core complex math via std.math.complex (musl-derived) ----

fn complexSin(comptime T: type, re: T, im: T) struct { T, T } {
    const r = cmath.sin(Complex(T).init(re, im));
    return .{ r.re, r.im };
}
fn complexCos(comptime T: type, re: T, im: T) struct { T, T } {
    const r = cmath.cos(Complex(T).init(re, im));
    return .{ r.re, r.im };
}
fn complexTan(comptime T: type, re: T, im: T) struct { T, T } {
    const r = cmath.tan(Complex(T).init(re, im));
    return .{ r.re, r.im };
}
fn complexAsin(comptime T: type, re: T, im: T) struct { T, T } {
    const r = cmath.asin(Complex(T).init(re, im));
    return .{ r.re, r.im };
}
fn complexAcos(comptime T: type, re: T, im: T) struct { T, T } {
    const r = cmath.acos(Complex(T).init(re, im));
    return .{ r.re, r.im };
}
fn complexAtan(comptime T: type, re: T, im: T) struct { T, T } {
    const r = cmath.atan(Complex(T).init(re, im));
    return .{ r.re, r.im };
}
fn complexSinh(comptime T: type, re: T, im: T) struct { T, T } {
    const r = cmath.sinh(Complex(T).init(re, im));
    return .{ r.re, r.im };
}
fn complexCosh(comptime T: type, re: T, im: T) struct { T, T } {
    const r = cmath.cosh(Complex(T).init(re, im));
    return .{ r.re, r.im };
}
fn complexTanh(comptime T: type, re: T, im: T) struct { T, T } {
    const r = cmath.tanh(Complex(T).init(re, im));
    return .{ r.re, r.im };
}
fn complexAsinh(comptime T: type, re: T, im: T) struct { T, T } {
    const r = cmath.asinh(Complex(T).init(re, im));
    return .{ r.re, r.im };
}
fn complexAcosh(comptime T: type, re: T, im: T) struct { T, T } {
    const r = cmath.acosh(Complex(T).init(re, im));
    return .{ r.re, r.im };
}
fn complexAtanh(comptime T: type, re: T, im: T) struct { T, T } {
    const r = cmath.atanh(Complex(T).init(re, im));
    return .{ r.re, r.im };
}
fn complexExp(comptime T: type, re: T, im: T) struct { T, T } {
    const r = cmath.exp(Complex(T).init(re, im));
    return .{ r.re, r.im };
}
fn complexLog(comptime T: type, re: T, im: T) struct { T, T } {
    const r = cmath.log(Complex(T).init(re, im));
    return .{ r.re, r.im };
}
fn complexSqrt(comptime T: type, re: T, im: T) struct { T, T } {
    const r = cmath.sqrt(Complex(T).init(re, im));
    return .{ r.re, r.im };
}
fn complexPow(comptime T: type, re1: T, im1: T, re2: T, im2: T) struct { T, T } {
    const r = cmath.pow(Complex(T).init(re1, im1), Complex(T).init(re2, im2));
    return .{ r.re, r.im };
}
fn complexConj(comptime T: type, re: T, im: T) struct { T, T } {
    const r = cmath.conj(Complex(T).init(re, im));
    return .{ r.re, r.im };
}
fn complexAbs(comptime T: type, re: T, im: T) T {
    return cmath.abs(Complex(T).init(re, im));
}
fn complexArg(comptime T: type, re: T, im: T) T {
    return cmath.arg(Complex(T).init(re, im));
}

fn complexFract(comptime T: type, re: T, im: T) struct { T, T } {
    return .{ re - std.math.trunc(re), im - std.math.trunc(im) };
}

fn complexMod(comptime T: type, a_re: T, a_im: T, b_re: T, b_im: T) struct { T, T } {
    // Component-wise floored modulus
    return .{ @mod(a_re, b_re), @mod(a_im, b_im) };
}

fn complexRem(comptime T: type, a_re: T, a_im: T, b_re: T, b_im: T) struct { T, T } {
    // Component-wise truncated remainder
    return .{ @rem(a_re, b_re), @rem(a_im, b_im) };
}

fn complexClamp(comptime T: type, x_re: T, x_im: T, lo_re: T, lo_im: T, hi_re: T, hi_im: T) struct { T, T } {
    const l_re = @min(lo_re, hi_re);
    const h_re = @max(lo_re, hi_re);
    const l_im = @min(lo_im, hi_im);
    const h_im = @max(lo_im, hi_im);
    return .{
        @max(@min(x_re, h_re), l_re),
        @max(@min(x_im, h_im), l_im),
    };
}

fn complexBlend(comptime T: type, a_re: T, a_im: T, b_re: T, b_im: T, t_re: T, t_im: T) struct { T, T } {
    return .{
        a_re + (b_re - a_re) * t_re,
        a_im + (b_im - a_im) * t_im,
    };
}

fn complexUnblend(comptime T: type, a_re: T, a_im: T, b_re: T, b_im: T, v_re: T, v_im: T) struct { T, T } {
    return .{
        (v_re - a_re) / (b_re - a_re),
        (v_im - a_im) / (b_im - a_im),
    };
}

fn complexRemap(
    comptime T: type,
    x_re: T,
    x_im: T,
    in_lo_re: T,
    in_lo_im: T,
    in_hi_re: T,
    in_hi_im: T,
    out_lo_re: T,
    out_lo_im: T,
    out_hi_re: T,
    out_hi_im: T,
) struct { T, T } {
    return .{
        out_lo_re + (x_re - in_lo_re) * (out_hi_re - out_lo_re) / (in_hi_re - in_lo_re),
        out_lo_im + (x_im - in_lo_im) * (out_hi_im - out_lo_im) / (in_hi_im - in_lo_im),
    };
}

fn complexPolar(comptime T: type, mag: T, ang: T) struct { T, T } {
    return .{ mag * std.math.cos(ang), mag * std.math.sin(ang) };
}

fn complexExpm1(comptime T: type, re: T, im: T) struct { T, T } {
    // expm1(z) = exp(z) - 1 = (exp(x)*cos(y) - 1) + i*exp(x)*sin(y)
    const ex = std.math.exp(re);
    return .{ ex * std.math.cos(im) - 1, ex * std.math.sin(im) };
}

fn complexLog1p(comptime T: type, re: T, im: T) struct { T, T } {
    // log1p(z) = log(1+z)
    const one_plus_re = 1 + re;
    const mag = std.math.sqrt(one_plus_re * one_plus_re + im * im);
    return .{ @log(mag), std.math.atan2(im, one_plus_re) };
}

fn complexNorm(comptime T: type, re: T, im: T) T {
    return re * re + im * im;
}

fn sinF32(re: f32, im: f32) struct { f32, f32 } {
    return complexSin(f32, re, im);
}
fn cosF32(re: f32, im: f32) struct { f32, f32 } {
    return complexCos(f32, re, im);
}
fn tanF32(re: f32, im: f32) struct { f32, f32 } {
    return complexTan(f32, re, im);
}
fn asinF32(re: f32, im: f32) struct { f32, f32 } {
    return complexAsin(f32, re, im);
}
fn acosF32(re: f32, im: f32) struct { f32, f32 } {
    return complexAcos(f32, re, im);
}
fn atanF32(re: f32, im: f32) struct { f32, f32 } {
    return complexAtan(f32, re, im);
}
fn sinhF32(re: f32, im: f32) struct { f32, f32 } {
    return complexSinh(f32, re, im);
}
fn coshF32(re: f32, im: f32) struct { f32, f32 } {
    return complexCosh(f32, re, im);
}
fn tanhF32(re: f32, im: f32) struct { f32, f32 } {
    return complexTanh(f32, re, im);
}
fn asinhF32(re: f32, im: f32) struct { f32, f32 } {
    return complexAsinh(f32, re, im);
}
fn acoshF32(re: f32, im: f32) struct { f32, f32 } {
    return complexAcosh(f32, re, im);
}
fn atanhF32(re: f32, im: f32) struct { f32, f32 } {
    return complexAtanh(f32, re, im);
}
fn expF32(re: f32, im: f32) struct { f32, f32 } {
    return complexExp(f32, re, im);
}
fn logF32(re: f32, im: f32) struct { f32, f32 } {
    return complexLog(f32, re, im);
}
fn sqrtF32(re: f32, im: f32) struct { f32, f32 } {
    return complexSqrt(f32, re, im);
}
fn conjF32(re: f32, im: f32) struct { f32, f32 } {
    return complexConj(f32, re, im);
}
fn negF32(re: f32, im: f32) struct { f32, f32 } {
    return .{ -re, -im };
}
fn fractF32(re: f32, im: f32) struct { f32, f32 } {
    return complexFract(f32, re, im);
}
fn expm1F32(re: f32, im: f32) struct { f32, f32 } {
    return complexExpm1(f32, re, im);
}
fn log1pF32(re: f32, im: f32) struct { f32, f32 } {
    return complexLog1p(f32, re, im);
}

fn sinF64(re: f64, im: f64) struct { f64, f64 } {
    return complexSin(f64, re, im);
}
fn cosF64(re: f64, im: f64) struct { f64, f64 } {
    return complexCos(f64, re, im);
}
fn tanF64(re: f64, im: f64) struct { f64, f64 } {
    return complexTan(f64, re, im);
}
fn asinF64(re: f64, im: f64) struct { f64, f64 } {
    return complexAsin(f64, re, im);
}
fn acosF64(re: f64, im: f64) struct { f64, f64 } {
    return complexAcos(f64, re, im);
}
fn atanF64(re: f64, im: f64) struct { f64, f64 } {
    return complexAtan(f64, re, im);
}
fn sinhF64(re: f64, im: f64) struct { f64, f64 } {
    return complexSinh(f64, re, im);
}
fn coshF64(re: f64, im: f64) struct { f64, f64 } {
    return complexCosh(f64, re, im);
}
fn tanhF64(re: f64, im: f64) struct { f64, f64 } {
    return complexTanh(f64, re, im);
}
fn asinhF64(re: f64, im: f64) struct { f64, f64 } {
    return complexAsinh(f64, re, im);
}
fn acoshF64(re: f64, im: f64) struct { f64, f64 } {
    return complexAcosh(f64, re, im);
}
fn atanhF64(re: f64, im: f64) struct { f64, f64 } {
    return complexAtanh(f64, re, im);
}
fn expF64(re: f64, im: f64) struct { f64, f64 } {
    return complexExp(f64, re, im);
}
fn logF64(re: f64, im: f64) struct { f64, f64 } {
    return complexLog(f64, re, im);
}
fn sqrtF64(re: f64, im: f64) struct { f64, f64 } {
    return complexSqrt(f64, re, im);
}
fn conjF64(re: f64, im: f64) struct { f64, f64 } {
    return complexConj(f64, re, im);
}
fn negF64(re: f64, im: f64) struct { f64, f64 } {
    return .{ -re, -im };
}
fn fractF64(re: f64, im: f64) struct { f64, f64 } {
    return complexFract(f64, re, im);
}
fn expm1F64(re: f64, im: f64) struct { f64, f64 } {
    return complexExpm1(f64, re, im);
}
fn log1pF64(re: f64, im: f64) struct { f64, f64 } {
    return complexLog1p(f64, re, im);
}

pub const c32_sin = makeUnaryOp(f32, [2]f32, .immediate, skript.builtins.type_c32, sinF32);
pub const c32_cos = makeUnaryOp(f32, [2]f32, .immediate, skript.builtins.type_c32, cosF32);
pub const c32_tan = makeUnaryOp(f32, [2]f32, .immediate, skript.builtins.type_c32, tanF32);
pub const c32_asin = makeUnaryOp(f32, [2]f32, .immediate, skript.builtins.type_c32, asinF32);
pub const c32_acos = makeUnaryOp(f32, [2]f32, .immediate, skript.builtins.type_c32, acosF32);
pub const c32_atan = makeUnaryOp(f32, [2]f32, .immediate, skript.builtins.type_c32, atanF32);
pub const c32_sinh = makeUnaryOp(f32, [2]f32, .immediate, skript.builtins.type_c32, sinhF32);
pub const c32_cosh = makeUnaryOp(f32, [2]f32, .immediate, skript.builtins.type_c32, coshF32);
pub const c32_tanh = makeUnaryOp(f32, [2]f32, .immediate, skript.builtins.type_c32, tanhF32);
pub const c32_asinh = makeUnaryOp(f32, [2]f32, .immediate, skript.builtins.type_c32, asinhF32);
pub const c32_acosh = makeUnaryOp(f32, [2]f32, .immediate, skript.builtins.type_c32, acoshF32);
pub const c32_atanh = makeUnaryOp(f32, [2]f32, .immediate, skript.builtins.type_c32, atanhF32);

pub const c32_exp = makeUnaryOp(f32, [2]f32, .immediate, skript.builtins.type_c32, expF32);
pub const c32_log = makeUnaryOp(f32, [2]f32, .immediate, skript.builtins.type_c32, logF32);
pub const c32_sqrt = makeUnaryOp(f32, [2]f32, .immediate, skript.builtins.type_c32, sqrtF32);
pub const c32_conj = makeUnaryOp(f32, [2]f32, .immediate, skript.builtins.type_c32, conjF32);
pub const c32_neg = makeUnaryOp(f32, [2]f32, .immediate, skript.builtins.type_c32, negF32);
pub const c32_pow = makeBinOp(f32, [2]f32, Pow, .immediate, skript.builtins.type_c32);

pub fn c32Abs(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_c32);
    const parts = intrin.complexParts(f32, args[0]);
    return convertToValue(complexAbs(f32, parts[0], parts[1]));
}

pub fn c32Arg(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_c32);
    const parts = intrin.complexParts(f32, args[0]);
    return convertToValue(complexArg(f32, parts[0], parts[1]));
}

pub fn c32Norm(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_c32);
    const parts = intrin.complexParts(f32, args[0]);
    return convertToValue(complexNorm(f32, parts[0], parts[1]));
}

pub const c64_sin = makeUnaryOp(f64, [2]f64, .stored, skript.builtins.type_c64, sinF64);
pub const c64_cos = makeUnaryOp(f64, [2]f64, .stored, skript.builtins.type_c64, cosF64);
pub const c64_tan = makeUnaryOp(f64, [2]f64, .stored, skript.builtins.type_c64, tanF64);
pub const c64_asin = makeUnaryOp(f64, [2]f64, .stored, skript.builtins.type_c64, asinF64);
pub const c64_acos = makeUnaryOp(f64, [2]f64, .stored, skript.builtins.type_c64, acosF64);
pub const c64_atan = makeUnaryOp(f64, [2]f64, .stored, skript.builtins.type_c64, atanF64);
pub const c64_sinh = makeUnaryOp(f64, [2]f64, .stored, skript.builtins.type_c64, sinhF64);
pub const c64_cosh = makeUnaryOp(f64, [2]f64, .stored, skript.builtins.type_c64, coshF64);
pub const c64_tanh = makeUnaryOp(f64, [2]f64, .stored, skript.builtins.type_c64, tanhF64);
pub const c64_asinh = makeUnaryOp(f64, [2]f64, .stored, skript.builtins.type_c64, asinhF64);
pub const c64_acosh = makeUnaryOp(f64, [2]f64, .stored, skript.builtins.type_c64, acoshF64);
pub const c64_atanh = makeUnaryOp(f64, [2]f64, .stored, skript.builtins.type_c64, atanhF64);

pub const c64_exp = makeUnaryOp(f64, [2]f64, .stored, skript.builtins.type_c64, expF64);
pub const c64_log = makeUnaryOp(f64, [2]f64, .stored, skript.builtins.type_c64, logF64);
pub const c64_sqrt = makeUnaryOp(f64, [2]f64, .stored, skript.builtins.type_c64, sqrtF64);
pub const c64_conj = makeUnaryOp(f64, [2]f64, .stored, skript.builtins.type_c64, conjF64);
pub const c64_neg = makeUnaryOp(f64, [2]f64, .stored, skript.builtins.type_c64, negF64);
pub const c64_pow = makeBinOp(f64, [2]f64, Pow, .stored, skript.builtins.type_c64);

pub fn c64Abs(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_c64);
    const parts = intrin.complexPartsStored(rt.runtime, args[0]);
    return convertToValue(complexAbs(f64, parts[0], parts[1]));
}

pub fn c64Arg(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_c64);
    const parts = intrin.complexPartsStored(rt.runtime, args[0]);
    return convertToValue(complexArg(f64, parts[0], parts[1]));
}

pub fn c64Norm(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_c64);
    const parts = intrin.complexPartsStored(rt.runtime, args[0]);
    return convertToValue(complexNorm(f64, parts[0], parts[1]));
}

// ---- new complex operations ----

// c16: unary (complex -> complex)
pub const c16_fract = makeUnaryOp(f16, [4]f16, .immediate, skript.builtins.type_c16, fractF16);
pub const c16_expm1 = makeUnaryOp(f16, [4]f16, .immediate, skript.builtins.type_c16, expm1F16);
pub const c16_log1p = makeUnaryOp(f16, [4]f16, .immediate, skript.builtins.type_c16, log1pF16);

// c16: binary (complex, complex -> complex)
pub const c16_mod = makeBinOp(f16, [4]f16, Mod, .immediate, skript.builtins.type_c16);
pub const c16_rem = makeBinOp(f16, [4]f16, Rem, .immediate, skript.builtins.type_c16);

// c16: multi-arg (hand-rolled)
pub fn c16Clamp(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 3);
    try intrin.typeAssert(args[0], skript.builtins.type_c16);
    try intrin.typeAssert(args[1], skript.builtins.type_c16);
    try intrin.typeAssert(args[2], skript.builtins.type_c16);
    const x = intrin.complexParts(f16, args[0]);
    const lo = intrin.complexParts(f16, args[1]);
    const hi = intrin.complexParts(f16, args[2]);
    const res = clampF16(x[0], x[1], lo[0], lo[1], hi[0], hi[1]);
    return .c16(.{ res[0], res[1] });
}

pub fn c16Blend(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 3);
    try intrin.typeAssert(args[0], skript.builtins.type_c16);
    try intrin.typeAssert(args[1], skript.builtins.type_c16);
    try intrin.typeAssert(args[2], skript.builtins.type_c16);
    const a = intrin.complexParts(f16, args[0]);
    const b = intrin.complexParts(f16, args[1]);
    const t = intrin.complexParts(f16, args[2]);
    const res = blendF16(a[0], a[1], b[0], b[1], t[0], t[1]);
    return .c16(.{ res[0], res[1] });
}

pub fn c16Unblend(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 3);
    try intrin.typeAssert(args[0], skript.builtins.type_c16);
    try intrin.typeAssert(args[1], skript.builtins.type_c16);
    try intrin.typeAssert(args[2], skript.builtins.type_c16);
    const a = intrin.complexParts(f16, args[0]);
    const b = intrin.complexParts(f16, args[1]);
    const v = intrin.complexParts(f16, args[2]);
    const res = unblendF16(a[0], a[1], b[0], b[1], v[0], v[1]);
    return .c16(.{ res[0], res[1] });
}

pub fn c16Remap(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 5);
    try intrin.typeAssert(args[0], skript.builtins.type_c16);
    try intrin.typeAssert(args[1], skript.builtins.type_c16);
    try intrin.typeAssert(args[2], skript.builtins.type_c16);
    try intrin.typeAssert(args[3], skript.builtins.type_c16);
    try intrin.typeAssert(args[4], skript.builtins.type_c16);
    const x = intrin.complexParts(f16, args[0]);
    const in_lo = intrin.complexParts(f16, args[1]);
    const in_hi = intrin.complexParts(f16, args[2]);
    const out_lo = intrin.complexParts(f16, args[3]);
    const out_hi = intrin.complexParts(f16, args[4]);
    const res = remapF16(
        x[0],
        x[1],
        in_lo[0],
        in_lo[1],
        in_hi[0],
        in_hi[1],
        out_lo[0],
        out_lo[1],
        out_hi[0],
        out_hi[1],
    );
    return .c16(.{ res[0], res[1] });
}

pub fn c16Polar(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    const mag_val = args[0];
    const ang_val = args[1];
    // Accept f16 values
    if (mag_val.typ != skript.builtins.type_f16 or ang_val.typ != skript.builtins.type_f16) return error.TypeMismatch;
    const mag = mag_val.obj.tof16();
    const ang = ang_val.obj.tof16();
    const res = polarF16(mag, ang);
    return .c16(.{ res[0], res[1] });
}

pub fn c16Mag(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_c16);
    const parts = intrin.complexParts(f16, args[0]);
    return convertToValue(absF16(parts[0], parts[1]));
}

// c32: unary (complex -> complex)
pub const c32_fract = makeUnaryOp(f32, [2]f32, .immediate, skript.builtins.type_c32, fractF32);
pub const c32_expm1 = makeUnaryOp(f32, [2]f32, .immediate, skript.builtins.type_c32, expm1F32);
pub const c32_log1p = makeUnaryOp(f32, [2]f32, .immediate, skript.builtins.type_c32, log1pF32);

// c32: binary (complex, complex -> complex)
pub const c32_mod = makeBinOp(f32, [2]f32, Mod, .immediate, skript.builtins.type_c32);
pub const c32_rem = makeBinOp(f32, [2]f32, Rem, .immediate, skript.builtins.type_c32);

// c32: multi-arg (hand-rolled)
pub fn c32Clamp(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 3);
    try intrin.typeAssert(args[0], skript.builtins.type_c32);
    try intrin.typeAssert(args[1], skript.builtins.type_c32);
    try intrin.typeAssert(args[2], skript.builtins.type_c32);
    const x = intrin.complexParts(f32, args[0]);
    const lo = intrin.complexParts(f32, args[1]);
    const hi = intrin.complexParts(f32, args[2]);
    const res = complexClamp(f32, x[0], x[1], lo[0], lo[1], hi[0], hi[1]);
    return .c32(.{ res[0], res[1] });
}

pub fn c32Blend(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 3);
    try intrin.typeAssert(args[0], skript.builtins.type_c32);
    try intrin.typeAssert(args[1], skript.builtins.type_c32);
    try intrin.typeAssert(args[2], skript.builtins.type_c32);
    const a = intrin.complexParts(f32, args[0]);
    const b = intrin.complexParts(f32, args[1]);
    const t = intrin.complexParts(f32, args[2]);
    const res = complexBlend(f32, a[0], a[1], b[0], b[1], t[0], t[1]);
    return .c32(.{ res[0], res[1] });
}

pub fn c32Unblend(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 3);
    try intrin.typeAssert(args[0], skript.builtins.type_c32);
    try intrin.typeAssert(args[1], skript.builtins.type_c32);
    try intrin.typeAssert(args[2], skript.builtins.type_c32);
    const a = intrin.complexParts(f32, args[0]);
    const b = intrin.complexParts(f32, args[1]);
    const v = intrin.complexParts(f32, args[2]);
    const res = complexUnblend(f32, a[0], a[1], b[0], b[1], v[0], v[1]);
    return .c32(.{ res[0], res[1] });
}

pub fn c32Remap(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 5);
    try intrin.typeAssert(args[0], skript.builtins.type_c32);
    try intrin.typeAssert(args[1], skript.builtins.type_c32);
    try intrin.typeAssert(args[2], skript.builtins.type_c32);
    try intrin.typeAssert(args[3], skript.builtins.type_c32);
    try intrin.typeAssert(args[4], skript.builtins.type_c32);
    const x = intrin.complexParts(f32, args[0]);
    const in_lo = intrin.complexParts(f32, args[1]);
    const in_hi = intrin.complexParts(f32, args[2]);
    const out_lo = intrin.complexParts(f32, args[3]);
    const out_hi = intrin.complexParts(f32, args[4]);
    const res = complexRemap(
        f32,
        x[0],
        x[1],
        in_lo[0],
        in_lo[1],
        in_hi[0],
        in_hi[1],
        out_lo[0],
        out_lo[1],
        out_hi[0],
        out_hi[1],
    );
    return .c32(.{ res[0], res[1] });
}

pub fn c32Polar(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    const mag_val = args[0];
    const ang_val = args[1];
    if (mag_val.typ != skript.builtins.type_f32 or ang_val.typ != skript.builtins.type_f32) return error.TypeMismatch;
    const mag = mag_val.obj.tof32();
    const ang = ang_val.obj.tof32();
    const res = complexPolar(f32, mag, ang);
    return .c32(.{ res[0], res[1] });
}

pub fn c32Mag(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_c32);
    const parts = intrin.complexParts(f32, args[0]);
    return convertToValue(complexAbs(f32, parts[0], parts[1]));
}

// c64: unary (complex -> complex)
pub const c64_fract = makeUnaryOp(f64, [2]f64, .stored, skript.builtins.type_c64, fractF64);
pub const c64_expm1 = makeUnaryOp(f64, [2]f64, .stored, skript.builtins.type_c64, expm1F64);
pub const c64_log1p = makeUnaryOp(f64, [2]f64, .stored, skript.builtins.type_c64, log1pF64);

// c64: binary (complex, complex -> complex)
pub const c64_mod = makeBinOp(f64, [2]f64, Mod, .stored, skript.builtins.type_c64);
pub const c64_rem = makeBinOp(f64, [2]f64, Rem, .stored, skript.builtins.type_c64);

// c64: multi-arg (hand-rolled)
pub fn c64Clamp(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 3);
    try intrin.typeAssert(args[0], skript.builtins.type_c64);
    try intrin.typeAssert(args[1], skript.builtins.type_c64);
    try intrin.typeAssert(args[2], skript.builtins.type_c64);
    const x = intrin.complexPartsStored(rt.runtime, args[0]);
    const lo = intrin.complexPartsStored(rt.runtime, args[1]);
    const hi = intrin.complexPartsStored(rt.runtime, args[2]);
    const res = complexClamp(f64, x[0], x[1], lo[0], lo[1], hi[0], hi[1]);
    const ref_temp = try rt.runtime.store.create([2]f64);
    const ptr = ref_temp.deref([2]f64);
    ptr[0] = res[0];
    ptr[1] = res[1];
    return .c64(ref_temp.toObject());
}

pub fn c64Blend(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 3);
    try intrin.typeAssert(args[0], skript.builtins.type_c64);
    try intrin.typeAssert(args[1], skript.builtins.type_c64);
    try intrin.typeAssert(args[2], skript.builtins.type_c64);
    const a = intrin.complexPartsStored(rt.runtime, args[0]);
    const b = intrin.complexPartsStored(rt.runtime, args[1]);
    const t = intrin.complexPartsStored(rt.runtime, args[2]);
    const res = complexBlend(f64, a[0], a[1], b[0], b[1], t[0], t[1]);
    const ref_temp = try rt.runtime.store.create([2]f64);
    const ptr = ref_temp.deref([2]f64);
    ptr[0] = res[0];
    ptr[1] = res[1];
    return .c64(ref_temp.toObject());
}

pub fn c64Unblend(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 3);
    try intrin.typeAssert(args[0], skript.builtins.type_c64);
    try intrin.typeAssert(args[1], skript.builtins.type_c64);
    try intrin.typeAssert(args[2], skript.builtins.type_c64);
    const a = intrin.complexPartsStored(rt.runtime, args[0]);
    const b = intrin.complexPartsStored(rt.runtime, args[1]);
    const v = intrin.complexPartsStored(rt.runtime, args[2]);
    const res = complexUnblend(f64, a[0], a[1], b[0], b[1], v[0], v[1]);
    const ref_temp = try rt.runtime.store.create([2]f64);
    const ptr = ref_temp.deref([2]f64);
    ptr[0] = res[0];
    ptr[1] = res[1];
    return .c64(ref_temp.toObject());
}

pub fn c64Remap(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 5);
    try intrin.typeAssert(args[0], skript.builtins.type_c64);
    try intrin.typeAssert(args[1], skript.builtins.type_c64);
    try intrin.typeAssert(args[2], skript.builtins.type_c64);
    try intrin.typeAssert(args[3], skript.builtins.type_c64);
    try intrin.typeAssert(args[4], skript.builtins.type_c64);
    const x = intrin.complexPartsStored(rt.runtime, args[0]);
    const in_lo = intrin.complexPartsStored(rt.runtime, args[1]);
    const in_hi = intrin.complexPartsStored(rt.runtime, args[2]);
    const out_lo = intrin.complexPartsStored(rt.runtime, args[3]);
    const out_hi = intrin.complexPartsStored(rt.runtime, args[4]);
    const res = complexRemap(
        f64,
        x[0],
        x[1],
        in_lo[0],
        in_lo[1],
        in_hi[0],
        in_hi[1],
        out_lo[0],
        out_lo[1],
        out_hi[0],
        out_hi[1],
    );
    const ref_temp = try rt.runtime.store.create([2]f64);
    const ptr = ref_temp.deref([2]f64);
    ptr[0] = res[0];
    ptr[1] = res[1];
    return .c64(ref_temp.toObject());
}

pub fn c64Polar(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    const mag_val = args[0];
    const ang_val = args[1];
    if (mag_val.typ != skript.builtins.type_f64 or ang_val.typ != skript.builtins.type_f64) return error.TypeMismatch;
    const mag = mag_val.obj.tof64();
    const ang = ang_val.obj.tof64();
    const res = complexPolar(f64, mag, ang);
    const ref_temp = try rt.runtime.store.create([2]f64);
    const ptr = ref_temp.deref([2]f64);
    ptr[0] = res[0];
    ptr[1] = res[1];
    return .c64(ref_temp.toObject());
}

pub fn c64Mag(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_c64);
    const parts = intrin.complexPartsStored(rt.runtime, args[0]);
    return convertToValue(complexAbs(f64, parts[0], parts[1]));
}

// ---- f16 helpers (upcast to f32 for stdlib math support) ----

fn sinF16(re: f16, im: f16) struct { f16, f16 } {
    const r = complexSin(f32, @as(f32, re), @as(f32, im));
    return .{ @floatCast(r[0]), @floatCast(r[1]) };
}
fn cosF16(re: f16, im: f16) struct { f16, f16 } {
    const r = complexCos(f32, @as(f32, re), @as(f32, im));
    return .{ @floatCast(r[0]), @floatCast(r[1]) };
}
fn tanF16(re: f16, im: f16) struct { f16, f16 } {
    const r = complexTan(f32, @as(f32, re), @as(f32, im));
    return .{ @floatCast(r[0]), @floatCast(r[1]) };
}
fn asinF16(re: f16, im: f16) struct { f16, f16 } {
    const r = complexAsin(f32, @as(f32, re), @as(f32, im));
    return .{ @floatCast(r[0]), @floatCast(r[1]) };
}
fn acosF16(re: f16, im: f16) struct { f16, f16 } {
    const r = complexAcos(f32, @as(f32, re), @as(f32, im));
    return .{ @floatCast(r[0]), @floatCast(r[1]) };
}
fn atanF16(re: f16, im: f16) struct { f16, f16 } {
    const r = complexAtan(f32, @as(f32, re), @as(f32, im));
    return .{ @floatCast(r[0]), @floatCast(r[1]) };
}
fn sinhF16(re: f16, im: f16) struct { f16, f16 } {
    const r = complexSinh(f32, @as(f32, re), @as(f32, im));
    return .{ @floatCast(r[0]), @floatCast(r[1]) };
}
fn coshF16(re: f16, im: f16) struct { f16, f16 } {
    const r = complexCosh(f32, @as(f32, re), @as(f32, im));
    return .{ @floatCast(r[0]), @floatCast(r[1]) };
}
fn tanhF16(re: f16, im: f16) struct { f16, f16 } {
    const r = complexTanh(f32, @as(f32, re), @as(f32, im));
    return .{ @floatCast(r[0]), @floatCast(r[1]) };
}
fn asinhF16(re: f16, im: f16) struct { f16, f16 } {
    const r = complexAsinh(f32, @as(f32, re), @as(f32, im));
    return .{ @floatCast(r[0]), @floatCast(r[1]) };
}
fn acoshF16(re: f16, im: f16) struct { f16, f16 } {
    const r = complexAcosh(f32, @as(f32, re), @as(f32, im));
    return .{ @floatCast(r[0]), @floatCast(r[1]) };
}
fn atanhF16(re: f16, im: f16) struct { f16, f16 } {
    const r = complexAtanh(f32, @as(f32, re), @as(f32, im));
    return .{ @floatCast(r[0]), @floatCast(r[1]) };
}
fn expF16(re: f16, im: f16) struct { f16, f16 } {
    const r = complexExp(f32, @as(f32, re), @as(f32, im));
    return .{ @floatCast(r[0]), @floatCast(r[1]) };
}
fn logF16(re: f16, im: f16) struct { f16, f16 } {
    const r = complexLog(f32, @as(f32, re), @as(f32, im));
    return .{ @floatCast(r[0]), @floatCast(r[1]) };
}
fn sqrtF16(re: f16, im: f16) struct { f16, f16 } {
    const r = complexSqrt(f32, @as(f32, re), @as(f32, im));
    return .{ @floatCast(r[0]), @floatCast(r[1]) };
}
fn conjF16(re: f16, im: f16) struct { f16, f16 } {
    const r = complexConj(f32, @as(f32, re), @as(f32, im));
    return .{ @floatCast(r[0]), @floatCast(r[1]) };
}
fn negF16(re: f16, im: f16) struct { f16, f16 } {
    return .{ -re, -im };
}
fn absF16(re: f16, im: f16) f16 {
    return @floatCast(complexAbs(f32, @as(f32, re), @as(f32, im)));
}
fn argF16(re: f16, im: f16) f16 {
    return @floatCast(complexArg(f32, @as(f32, re), @as(f32, im)));
}
fn normF16(re: f16, im: f16) f16 {
    return @floatCast(complexNorm(f32, @as(f32, re), @as(f32, im)));
}

fn powF16(re_a: f16, im_a: f16, re_b: f16, im_b: f16) struct { f16, f16 } {
    const r = complexPow(f32, @as(f32, re_a), @as(f32, im_a), @as(f32, re_b), @as(f32, im_b));
    return .{ @floatCast(r[0]), @floatCast(r[1]) };
}

fn fractF16(re: f16, im: f16) struct { f16, f16 } {
    const r = complexFract(f32, @as(f32, re), @as(f32, im));
    return .{ @floatCast(r[0]), @floatCast(r[1]) };
}

fn clampF16(
    x_re: f16,
    x_im: f16,
    lo_re: f16,
    lo_im: f16,
    hi_re: f16,
    hi_im: f16,
) struct { f16, f16 } {
    const r = complexClamp(
        f32,
        @as(f32, x_re),
        @as(f32, x_im),
        @as(f32, lo_re),
        @as(f32, lo_im),
        @as(f32, hi_re),
        @as(f32, hi_im),
    );
    return .{ @floatCast(r[0]), @floatCast(r[1]) };
}

fn blendF16(
    a_re: f16,
    a_im: f16,
    b_re: f16,
    b_im: f16,
    t_re: f16,
    t_im: f16,
) struct { f16, f16 } {
    const r = complexBlend(
        f32,
        @as(f32, a_re),
        @as(f32, a_im),
        @as(f32, b_re),
        @as(f32, b_im),
        @as(f32, t_re),
        @as(f32, t_im),
    );
    return .{ @floatCast(r[0]), @floatCast(r[1]) };
}

fn unblendF16(
    a_re: f16,
    a_im: f16,
    b_re: f16,
    b_im: f16,
    v_re: f16,
    v_im: f16,
) struct { f16, f16 } {
    const r = complexUnblend(
        f32,
        @as(f32, a_re),
        @as(f32, a_im),
        @as(f32, b_re),
        @as(f32, b_im),
        @as(f32, v_re),
        @as(f32, v_im),
    );
    return .{ @floatCast(r[0]), @floatCast(r[1]) };
}

fn remapF16(
    x_re: f16,
    x_im: f16,
    in_lo_re: f16,
    in_lo_im: f16,
    in_hi_re: f16,
    in_hi_im: f16,
    out_lo_re: f16,
    out_lo_im: f16,
    out_hi_re: f16,
    out_hi_im: f16,
) struct { f16, f16 } {
    const r = complexRemap(
        f32,
        @as(f32, x_re),
        @as(f32, x_im),
        @as(f32, in_lo_re),
        @as(f32, in_lo_im),
        @as(f32, in_hi_re),
        @as(f32, in_hi_im),
        @as(f32, out_lo_re),
        @as(f32, out_lo_im),
        @as(f32, out_hi_re),
        @as(f32, out_hi_im),
    );
    return .{ @floatCast(r[0]), @floatCast(r[1]) };
}

fn polarF16(mag: f16, ang: f16) struct { f16, f16 } {
    const r = complexPolar(f32, @as(f32, mag), @as(f32, ang));
    return .{ @floatCast(r[0]), @floatCast(r[1]) };
}

fn expm1F16(re: f16, im: f16) struct { f16, f16 } {
    const r = complexExpm1(f32, @as(f32, re), @as(f32, im));
    return .{ @floatCast(r[0]), @floatCast(r[1]) };
}

fn log1pF16(re: f16, im: f16) struct { f16, f16 } {
    const r = complexLog1p(f32, @as(f32, re), @as(f32, im));
    return .{ @floatCast(r[0]), @floatCast(r[1]) };
}

pub const c16_sin = makeUnaryOp(f16, [4]f16, .immediate, skript.builtins.type_c16, sinF16);
pub const c16_cos = makeUnaryOp(f16, [4]f16, .immediate, skript.builtins.type_c16, cosF16);
pub const c16_tan = makeUnaryOp(f16, [4]f16, .immediate, skript.builtins.type_c16, tanF16);
pub const c16_asin = makeUnaryOp(f16, [4]f16, .immediate, skript.builtins.type_c16, asinF16);
pub const c16_acos = makeUnaryOp(f16, [4]f16, .immediate, skript.builtins.type_c16, acosF16);
pub const c16_atan = makeUnaryOp(f16, [4]f16, .immediate, skript.builtins.type_c16, atanF16);
pub const c16_sinh = makeUnaryOp(f16, [4]f16, .immediate, skript.builtins.type_c16, sinhF16);
pub const c16_cosh = makeUnaryOp(f16, [4]f16, .immediate, skript.builtins.type_c16, coshF16);
pub const c16_tanh = makeUnaryOp(f16, [4]f16, .immediate, skript.builtins.type_c16, tanhF16);
pub const c16_asinh = makeUnaryOp(f16, [4]f16, .immediate, skript.builtins.type_c16, asinhF16);
pub const c16_acosh = makeUnaryOp(f16, [4]f16, .immediate, skript.builtins.type_c16, acoshF16);
pub const c16_atanh = makeUnaryOp(f16, [4]f16, .immediate, skript.builtins.type_c16, atanhF16);
pub const c16_exp = makeUnaryOp(f16, [4]f16, .immediate, skript.builtins.type_c16, expF16);
pub const c16_log = makeUnaryOp(f16, [4]f16, .immediate, skript.builtins.type_c16, logF16);
pub const c16_sqrt = makeUnaryOp(f16, [4]f16, .immediate, skript.builtins.type_c16, sqrtF16);
pub const c16_conj = makeUnaryOp(f16, [4]f16, .immediate, skript.builtins.type_c16, conjF16);
pub const c16_neg = makeUnaryOp(f16, [4]f16, .immediate, skript.builtins.type_c16, negF16);

pub fn c16Pow(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    try intrin.typeAssert(args[0], skript.builtins.type_c16);
    try intrin.typeAssert(args[1], skript.builtins.type_c16);
    const a = intrin.complexParts(f16, args[0]);
    const b = intrin.complexParts(f16, args[1]);
    const res = powF16(a[0], a[1], b[0], b[1]);
    return .c16(.{ res[0], res[1] });
}

pub fn c16Abs(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_c16);
    const parts = intrin.complexParts(f16, args[0]);
    return convertToValue(absF16(parts[0], parts[1]));
}

pub fn c16Arg(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_c16);
    const parts = intrin.complexParts(f16, args[0]);
    return convertToValue(argF16(parts[0], parts[1]));
}

pub fn c16Norm(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_c16);
    const parts = intrin.complexParts(f16, args[0]);
    return convertToValue(normF16(parts[0], parts[1]));
}

// ---- re / im extractors ----

fn makeReIm(
    comptime Storage: type,
    comptime mode: StorageMode,
    comptime complex_type: Object,
    comptime idx: usize,
) Func {
    return struct {
        fn f(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
            if (args.len != 1) return error.ArityMismatch;
            const val = args[0];
            if (mode == .stored) {
                if (val.typ != skript.builtins.type_c64) return error.TypeMismatch;
                return convertToValue(val.obj.toRef().deref([2]f64).*[idx]);
            } else {
                if (val.typ != complex_type) return error.TypeMismatch;
                return convertToValue(val.obj.as(Storage)[idx]);
            }
        }
    }.f;
}

pub const c16_re = makeReIm([4]f16, .immediate, skript.builtins.type_c16, 0);
pub const c16_im = makeReIm([4]f16, .immediate, skript.builtins.type_c16, 1);
pub const c32_re = makeReIm([2]f32, .immediate, skript.builtins.type_c32, 0);
pub const c32_im = makeReIm([2]f32, .immediate, skript.builtins.type_c32, 1);
pub const c64_re = makeReIm([2]f64, .stored, skript.builtins.type_c64, 0);
pub const c64_im = makeReIm([2]f64, .stored, skript.builtins.type_c64, 1);

// ---- complex equality ----

fn makeCmp(
    comptime Storage: type,
    comptime mode: StorageMode,
    comptime complex_type: Object,
    comptime op: std.math.CompareOperator,
) Func {
    return struct {
        fn f(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
            try intrin.arityAssert(args, 2);
            // C3 coercion: see makeBinOp — Method.get's join fallback applies
            // the resolved instance to the original args, so coerce here.
            const a_val = try intrin.coerceBuiltin(complex_type, rt.runtime, args[0]);
            const b_val = try intrin.coerceBuiltin(complex_type, rt.runtime, args[1]);
            const a, const b = if (mode == .stored)
                .{ a_val.obj.toRef().deref([2]f64).*, b_val.obj.toRef().deref([2]f64).* }
            else
                .{ a_val.obj.as(Storage), b_val.obj.as(Storage) };
            const re = std.math.compare(a[0], op, b[0]);
            const im = std.math.compare(a[1], op, b[1]);
            return switch (op) {
                .eq => .bool(re and im),
                .neq => .bool(re or im),
                else => @compileError("Unsupported compare operator for complex: " ++ @tagName(op)),
            };
        }
    }.f;
}

pub const c16_eq = makeCmp([4]f16, .immediate, skript.builtins.type_c16, .eq);
pub const c32_eq = makeCmp([2]f32, .immediate, skript.builtins.type_c32, .eq);
pub const c64_eq = makeCmp([2]f64, .stored, skript.builtins.type_c64, .eq);
pub const c16_ne = makeCmp([4]f16, .immediate, skript.builtins.type_c16, .neq);
pub const c32_ne = makeCmp([2]f32, .immediate, skript.builtins.type_c32, .neq);
pub const c64_ne = makeCmp([2]f64, .stored, skript.builtins.type_c64, .neq);

// ---- complex predicates ----

fn makePred(comptime Storage: type, comptime complex_type: Object, comptime pred: anytype) Func {
    return struct {
        fn f(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
            try intrin.arityAssert(args, 1);
            try intrin.typeAssert(args[0], complex_type);
            const v = args[0].obj.as(Storage);
            return .bool(pred(v));
        }
    }.f;
}

fn makePredStored(comptime pred: anytype) Func {
    return struct {
        fn f(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
            try intrin.arityAssert(args, 1);
            try intrin.typeAssert(args[0], skript.builtins.type_c64);
            const v = args[0].obj.toRef().deref([2]f64).*;
            return .bool(pred(v));
        }
    }.f;
}

fn isZeroImmediate(storage: anytype) bool {
    return storage[0] == 0 and storage[1] == 0;
}
fn isNanImmediate(storage: anytype) bool {
    return std.math.isNan(storage[0]) or std.math.isNan(storage[1]);
}
fn isInfImmediate(storage: anytype) bool {
    return std.math.isInf(storage[0]) or std.math.isInf(storage[1]);
}
fn isFiniteImmediate(storage: anytype) bool {
    return std.math.isFinite(storage[0]) and std.math.isFinite(storage[1]);
}

pub const c16_is_zero = makePred([4]f16, skript.builtins.type_c16, isZeroImmediate);
pub const c16_is_nan = makePred([4]f16, skript.builtins.type_c16, isNanImmediate);
pub const c16_is_inf = makePred([4]f16, skript.builtins.type_c16, isInfImmediate);
pub const c16_is_finite = makePred([4]f16, skript.builtins.type_c16, isFiniteImmediate);
pub const c32_is_zero = makePred([2]f32, skript.builtins.type_c32, isZeroImmediate);
pub const c32_is_nan = makePred([2]f32, skript.builtins.type_c32, isNanImmediate);
pub const c32_is_inf = makePred([2]f32, skript.builtins.type_c32, isInfImmediate);
pub const c32_is_finite = makePred([2]f32, skript.builtins.type_c32, isFiniteImmediate);
pub const c64_is_zero = makePredStored(isZeroImmediate);
pub const c64_is_nan = makePredStored(isNanImmediate);
pub const c64_is_inf = makePredStored(isInfImmediate);
pub const c64_is_finite = makePredStored(isFiniteImmediate);

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
    }
}

fn initTestingRuntime() !*Runtime {
    return Runtime.init(std.testing.allocator, std.testing.io);
}

test "c16 all" {
    const runtime = try initTestingRuntime();
    defer runtime.deinit();

    // c16Cart round-trip
    {
        const val = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(1.5), .f16(2.5) });
        try std.testing.expectEqual(skript.builtins.type_c16, val.typ);
        const data = val.obj.as([4]f16);
        try std.testing.expectEqual(@as(f16, 1.5), data[0]);
        try std.testing.expectEqual(@as(f16, 2.5), data[1]);
    }

    // c16_re and c16_im
    {
        const val = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(3.0), .f16(4.0) });
        const real = try c16_re(runtime.context(), .nil, .nil, &.{val});
        const imag = try c16_im(runtime.context(), .nil, .nil, &.{val});
        try std.testing.expectEqual(skript.builtins.type_f16, real.typ);
        try std.testing.expectEqual(skript.builtins.type_f16, imag.typ);
        try std.testing.expectEqual(@as(f16, 3.0), real.obj.tof16());
        try std.testing.expectEqual(@as(f16, 4.0), imag.obj.tof16());
    }

    // c16 arity error
    {
        try std.testing.expectError(error.ArityMismatch, c16Cart(runtime.context(), .nil, .nil, &.{.f16(1.0)}));
        try std.testing.expectError(error.ArityMismatch, c16_re(runtime.context(), .nil, .nil, &.{}));
        try std.testing.expectError(error.ArityMismatch, c16_add(runtime.context(), .nil, .nil, &.{.c16(.{ 1, 2 })}));
    }

    // c16 sin cos tan
    {

        // sin(0+0i) = 0+0i
        const z0 = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(0), .f16(0) });
        const s0 = try c16_sin(runtime.context(), .nil, .nil, &.{z0});
        const d0 = s0.obj.as([4]f16);
        try std.testing.expectEqual(@as(f16, 0.0), d0[0]);
        try std.testing.expectEqual(@as(f16, 0.0), d0[1]);

        // cos(0+0i) = 1+0i
        const c0 = try c16_cos(runtime.context(), .nil, .nil, &.{z0});
        const dc0 = c0.obj.as([4]f16);
        try std.testing.expectEqual(@as(f16, 1.0), dc0[0]);
        try std.testing.expectEqual(@as(f16, 0.0), dc0[1]);

        // tan(0+0i) = 0+0i
        const t0 = try c16_tan(runtime.context(), .nil, .nil, &.{z0});
        const dt0 = t0.obj.as([4]f16);
        try std.testing.expectEqual(@as(f16, 0.0), dt0[0]);
        try std.testing.expectEqual(@as(f16, 0.0), dt0[1]);
    }

    // c16 sinh cosh tanh
    {
        const z0 = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(0), .f16(0) });
        const sh = try c16_sinh(runtime.context(), .nil, .nil, &.{z0});
        const dsh = sh.obj.as([4]f16);
        try std.testing.expectEqual(@as(f16, 0.0), dsh[0]);
        try std.testing.expectEqual(@as(f16, 0.0), dsh[1]);

        const ch = try c16_cosh(runtime.context(), .nil, .nil, &.{z0});
        const dch = ch.obj.as([4]f16);
        try std.testing.expectEqual(@as(f16, 1.0), dch[0]);
        try std.testing.expectEqual(@as(f16, 0.0), dch[1]);

        const th = try c16_tanh(runtime.context(), .nil, .nil, &.{z0});
        const dth = th.obj.as([4]f16);
        try std.testing.expectEqual(@as(f16, 0.0), dth[0]);
        try std.testing.expectEqual(@as(f16, 0.0), dth[1]);
    }

    // c16 asin acos atan
    {
        const z0 = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(0), .f16(0) });
        const a0 = try c16_asin(runtime.context(), .nil, .nil, &.{z0});
        const d0 = a0.obj.as([4]f16);
        try std.testing.expectApproxEqAbs(@as(f16, 0.0), d0[0], @as(f16, 1e-3));
        try std.testing.expectApproxEqAbs(@as(f16, 0.0), d0[1], @as(f16, 1e-3));

        const a1 = try c16_acos(runtime.context(), .nil, .nil, &.{z0});
        const d1 = a1.obj.as([4]f16);
        try std.testing.expectApproxEqAbs(@as(f16, 1.5708), d1[0], @as(f16, 1e-3));
        try std.testing.expectApproxEqAbs(@as(f16, 0.0), d1[1], @as(f16, 1e-3));

        const a2 = try c16_atan(runtime.context(), .nil, .nil, &.{z0});
        const d2 = a2.obj.as([4]f16);
        try std.testing.expectApproxEqAbs(@as(f16, 0.0), d2[0], @as(f16, 1e-3));
        try std.testing.expectApproxEqAbs(@as(f16, 0.0), d2[1], @as(f16, 1e-3));
    }

    // c16 asinh acosh atanh
    {
        const z0 = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(0), .f16(0) });
        const a0 = try c16_asinh(runtime.context(), .nil, .nil, &.{z0});
        const d0 = a0.obj.as([4]f16);
        try std.testing.expectApproxEqAbs(@as(f16, 0.0), d0[0], @as(f16, 1e-3));
        try std.testing.expectApproxEqAbs(@as(f16, 0.0), d0[1], @as(f16, 1e-3));

        const z1 = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(1), .f16(0) });
        const a1 = try c16_acosh(runtime.context(), .nil, .nil, &.{z1});
        const d1 = a1.obj.as([4]f16);
        try std.testing.expectApproxEqAbs(@as(f16, 0.0), d1[0], @as(f16, 1e-3));
        try std.testing.expectApproxEqAbs(@as(f16, 0.0), d1[1], @as(f16, 1e-3));

        const a2 = try c16_atanh(runtime.context(), .nil, .nil, &.{z0});
        const d2 = a2.obj.as([4]f16);
        try std.testing.expectApproxEqAbs(@as(f16, 0.0), d2[0], @as(f16, 1e-3));
        try std.testing.expectApproxEqAbs(@as(f16, 0.0), d2[1], @as(f16, 1e-3));
    }

    // c16 exp
    {
        const z0 = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(0), .f16(0) });
        const e0 = try c16_exp(runtime.context(), .nil, .nil, &.{z0});
        const d0 = e0.obj.as([4]f16);
        try std.testing.expectApproxEqAbs(@as(f16, 1.0), d0[0], @as(f16, 1e-3));
        try std.testing.expectApproxEqAbs(@as(f16, 0.0), d0[1], @as(f16, 1e-3));
    }

    // c16 log
    {
        const z0 = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(1), .f16(0) });
        const l0 = try c16_log(runtime.context(), .nil, .nil, &.{z0});
        const d0 = l0.obj.as([4]f16);
        try std.testing.expectApproxEqAbs(@as(f16, 0.0), d0[0], @as(f16, 1e-3));
        try std.testing.expectApproxEqAbs(@as(f16, 0.0), d0[1], @as(f16, 1e-3));
    }

    // c16 sqrt
    {

        // sqrt(4+0i) = 2+0i
        const z0 = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(4), .f16(0) });
        const s0 = try c16_sqrt(runtime.context(), .nil, .nil, &.{z0});
        const d0 = s0.obj.as([4]f16);
        try std.testing.expectApproxEqAbs(@as(f16, 2.0), d0[0], @as(f16, 1e-3));
        try std.testing.expectApproxEqAbs(@as(f16, 0.0), d0[1], @as(f16, 1e-3));

        // sqrt(-1+0i) = 0 + i
        const z1 = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(-1), .f16(0) });
        const s1 = try c16_sqrt(runtime.context(), .nil, .nil, &.{z1});
        const d1 = s1.obj.as([4]f16);
        try std.testing.expectApproxEqAbs(@as(f16, 0.0), d1[0], @as(f16, 1e-3));
        try std.testing.expectApproxEqAbs(@as(f16, 1.0), d1[1], @as(f16, 1e-3));
    }

    // c16 pow
    {
        const base = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(2), .f16(0) });
        const exp = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(3), .f16(0) });
        const p = try c16Pow(runtime.context(), .nil, .nil, &.{ base, exp });
        const d = p.obj.as([4]f16);
        try std.testing.expectApproxEqAbs(@as(f16, 8.0), d[0], @as(f16, 1e-2));
        try std.testing.expectApproxEqAbs(@as(f16, 0.0), d[1], @as(f16, 1e-2));
    }

    // c16 conj
    {
        const z = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(1.5), .f16(-2.5) });
        const c = try c16_conj(runtime.context(), .nil, .nil, &.{z});
        const d = c.obj.as([4]f16);
        try std.testing.expectEqual(@as(f16, 1.5), d[0]);
        try std.testing.expectEqual(@as(f16, 2.5), d[1]);
    }

    // c16 abs arg norm
    {
        const z = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(3), .f16(4) });
        const a = try c16Abs(runtime.context(), .nil, .nil, &.{z});
        try std.testing.expectApproxEqAbs(@as(f16, 5.0), a.obj.tof16(), @as(f16, 1e-2));

        const n = try c16Norm(runtime.context(), .nil, .nil, &.{z});
        try std.testing.expectApproxEqAbs(@as(f16, 25.0), n.obj.tof16(), @as(f16, 1e-2));

        const z1 = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(1), .f16(0) });
        const ar = try c16Arg(runtime.context(), .nil, .nil, &.{z1});
        try std.testing.expectApproxEqAbs(@as(f16, 0.0), ar.obj.tof16(), @as(f16, 1e-3));
    }

    // c16 arity errors
    {
        try std.testing.expectError(error.ArityMismatch, c16_sin(runtime.context(), .nil, .nil, &.{}));
        try std.testing.expectError(error.ArityMismatch, c16_cos(runtime.context(), .nil, .nil, &.{}));
        try std.testing.expectError(error.ArityMismatch, c16_exp(runtime.context(), .nil, .nil, &.{}));
        try std.testing.expectError(error.ArityMismatch, c16_log(runtime.context(), .nil, .nil, &.{}));
        try std.testing.expectError(error.ArityMismatch, c16_sqrt(runtime.context(), .nil, .nil, &.{}));
        try std.testing.expectError(error.ArityMismatch, c16_conj(runtime.context(), .nil, .nil, &.{}));
        try std.testing.expectError(error.ArityMismatch, c16Abs(runtime.context(), .nil, .nil, &.{}));
        try std.testing.expectError(error.ArityMismatch, c16Pow(runtime.context(), .nil, .nil, &.{Value.nil}));
    }

    // c16 identity: sin(z)/cos(z) = tan(z)
    {
        const re: f16 = 0.5;
        const im: f16 = 0.7;
        const z = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(re), .f16(im) });
        const s = try c16_sin(runtime.context(), .nil, .nil, &.{z});
        const c = try c16_cos(runtime.context(), .nil, .nil, &.{z});
        const t = try c16_tan(runtime.context(), .nil, .nil, &.{z});
        const sd = s.obj.as([4]f16);
        const cd = c.obj.as([4]f16);
        const td = t.obj.as([4]f16);
        const denom_mag2 = cd[0] * cd[0] + cd[1] * cd[1];
        const quot_re = (sd[0] * cd[0] + sd[1] * cd[1]) / denom_mag2;
        const quot_im = (sd[1] * cd[0] - sd[0] * cd[1]) / denom_mag2;
        try std.testing.expectApproxEqAbs(td[0], quot_re, @as(f16, 1e-2));
        try std.testing.expectApproxEqAbs(td[1], quot_im, @as(f16, 1e-2));
    }

    // c16 fract mag polar
    {
        const z = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(3.14), .f16(1.5) });
        const r = try c16_fract(runtime.context(), .nil, .nil, &.{z});
        const d = r.obj.as([4]f16);
        try std.testing.expectApproxEqAbs(@as(f16, 0.14), d[0], @as(f16, 1e-2));
        try std.testing.expectApproxEqAbs(@as(f16, 0.5), d[1], @as(f16, 1e-2));
        const m = try c16Mag(runtime.context(), .nil, .nil, &.{z});
        try std.testing.expectApproxEqAbs(@as(f16, 3.48), m.obj.tof16(), @as(f16, 1e-1));
        const ang: f16 = @floatCast(std.math.atan2(@as(f32, 4.0), @as(f32, 3.0)));
        const p = try c16Polar(runtime.context(), .nil, .nil, &.{ .f16(5.0), .f16(ang) });
        const pd = p.obj.as([4]f16);
        try std.testing.expectApproxEqAbs(@as(f16, 3.0), pd[0], @as(f16, 1e-2));
        try std.testing.expectApproxEqAbs(@as(f16, 4.0), pd[1], @as(f16, 1e-2));
    }

    // c16 expm1 log1p mod rem clamp blend unblend remap
    {
        const z = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(1.0), .f16(0.0) });
        const e = try c16_expm1(runtime.context(), .nil, .nil, &.{z});
        const ed = e.obj.as([4]f16);
        try std.testing.expectApproxEqAbs(@as(f16, std.math.e - 1), ed[0], @as(f16, 1e-2));
        try std.testing.expectEqual(@as(f16, 0.0), ed[1]);
        const lz = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(0.0), .f16(0.0) });
        const l = try c16_log1p(runtime.context(), .nil, .nil, &.{lz});
        const ld = l.obj.as([4]f16);
        try std.testing.expectEqual(@as(f16, 0.0), ld[0]);
        try std.testing.expectEqual(@as(f16, 0.0), ld[1]);
        const a = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(7.0), .f16(8.0) });
        const b = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(3.0), .f16(5.0) });
        const m = try c16_mod(runtime.context(), .nil, .nil, &.{ a, b });
        const md = m.obj.as([4]f16);
        try std.testing.expectEqual(@as(f16, 1.0), md[0]);
        try std.testing.expectEqual(@as(f16, 3.0), md[1]);
        const r = try c16_rem(runtime.context(), .nil, .nil, &.{ a, b });
        const rd = r.obj.as([4]f16);
        try std.testing.expectEqual(@as(f16, 1.0), rd[0]);
        try std.testing.expectEqual(@as(f16, 3.0), rd[1]);
        // clamp/blend/unblend/remap
        const lo = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(0.0), .f16(1.0) });
        const hi = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(3.0), .f16(5.0) });
        const cl = try c16Clamp(runtime.context(), .nil, .nil, &.{ z, lo, hi });
        const cld = cl.obj.as([4]f16);
        try std.testing.expectEqual(@as(f16, 1.0), cld[0]);
        try std.testing.expectEqual(@as(f16, 1.0), cld[1]);
        const zero = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(0.0), .f16(0.0) });
        const ten20 = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(10.0), .f16(20.0) });
        const half = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(0.5), .f16(0.5) });
        const bl = try c16Blend(runtime.context(), .nil, .nil, &.{ zero, ten20, half });
        const bld = bl.obj.as([4]f16);
        try std.testing.expectEqual(@as(f16, 5.0), bld[0]);
        try std.testing.expectEqual(@as(f16, 10.0), bld[1]);
        const ub = try c16Unblend(runtime.context(), .nil, .nil, &.{ zero, ten20, bl });
        const ubd = ub.obj.as([4]f16);
        try std.testing.expectApproxEqAbs(@as(f16, 0.5), ubd[0], @as(f16, 1e-2));
        try std.testing.expectApproxEqAbs(@as(f16, 0.5), ubd[1], @as(f16, 1e-2));
        const in_lo = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(0.0), .f16(0.0) });
        const in_hi = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(10.0), .f16(20.0) });
        const out_lo = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(100.0), .f16(200.0) });
        const out_hi = try c16Cart(runtime.context(), .nil, .nil, &.{ .f16(200.0), .f16(300.0) });
        const rp = try c16Remap(runtime.context(), .nil, .nil, &.{ z, in_lo, in_hi, out_lo, out_hi });
        const rpd = rp.obj.as([4]f16);
        try std.testing.expectApproxEqAbs(@as(f16, 110.0), rpd[0], @as(f16, 1.0));
        try std.testing.expectApproxEqAbs(@as(f16, 200.0), rpd[1], @as(f16, 1.0));
    }
}

test "c32 all" {
    const runtime = try initTestingRuntime();
    defer runtime.deinit();

    // c32Cart round-trip
    {
        const val = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(1.5), .f32(2.5) });
        try std.testing.expectEqual(skript.builtins.type_c32, val.typ);
        const data = val.obj.as([2]f32);
        try std.testing.expectEqual(@as(f32, 1.5), data[0]);
        try std.testing.expectEqual(@as(f32, 2.5), data[1]);
    }

    // c32_re and c32_im
    {
        const val = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(3.0), .f32(4.0) });
        const real = try c32_re(runtime.context(), .nil, .nil, &.{val});
        const imag = try c32_im(runtime.context(), .nil, .nil, &.{val});
        try std.testing.expectEqual(skript.builtins.type_f32, real.typ);
        try std.testing.expectEqual(skript.builtins.type_f32, imag.typ);
        try std.testing.expectEqual(@as(f32, 3.0), real.obj.tof32());
        try std.testing.expectEqual(@as(f32, 4.0), imag.obj.tof32());
    }

    // c32 add
    {
        const val_a = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(1.0), .f32(2.0) });
        const val_b = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(3.0), .f32(4.0) });
        const res = try c32_add(runtime.context(), .nil, .nil, &.{ val_a, val_b });
        const data = res.obj.as([2]f32);
        try std.testing.expectEqual(@as(f32, 4.0), data[0]);
        try std.testing.expectEqual(@as(f32, 6.0), data[1]);
    }

    // c32 sub
    {
        const val_a = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(5.0), .f32(7.0) });
        const val_b = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(3.0), .f32(4.0) });
        const res = try c32_sub(runtime.context(), .nil, .nil, &.{ val_a, val_b });
        const data = res.obj.as([2]f32);
        try std.testing.expectEqual(@as(f32, 2.0), data[0]);
        try std.testing.expectEqual(@as(f32, 3.0), data[1]);
    }

    // c32 mul
    {
        const val_a = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(1.0), .f32(2.0) });
        const val_b = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(3.0), .f32(4.0) });
        const res = try c32_mul(runtime.context(), .nil, .nil, &.{ val_a, val_b });
        const data = res.obj.as([2]f32);
        // (1+2i)*(3+4i) = (3-8) + (4+6)i = -5 + 10i
        try std.testing.expectEqual(@as(f32, -5.0), data[0]);
        try std.testing.expectEqual(@as(f32, 10.0), data[1]);
    }

    // c32 div
    {
        const val_a = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(1.0), .f32(2.0) });
        const val_b = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(3.0), .f32(4.0) });
        const res = try c32_div(runtime.context(), .nil, .nil, &.{ val_a, val_b });
        const data = res.obj.as([2]f32);
        // (1+2i)/(3+4i) = (1*3+2*4)/(25) + (2*3-1*4)/(25)i = 11/25 + 2/25i = 0.44 + 0.08i
        try std.testing.expectApproxEqAbs(@as(f32, 0.44), data[0], @as(f32, 1e-7));
        try std.testing.expectApproxEqAbs(@as(f32, 0.08), data[1], @as(f32, 1e-7));
    }

    // c32 type assertion error
    {
        try std.testing.expectError(
            error.TypeMismatch,
            c32Cart(runtime.context(), .nil, .nil, &.{ .f32(1.0), .f64(2.0) }),
        );
    }

    // c32 sin
    {

        // sin(0+0i) = 0+0i
        const z0 = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(0), .f32(0) });
        const s0 = try c32_sin(runtime.context(), .nil, .nil, &.{z0});
        const d0 = s0.obj.as([2]f32);
        try std.testing.expectEqual(@as(f32, 0.0), d0[0]);
        try std.testing.expectEqual(@as(f32, 0.0), d0[1]);

        // sin(pi/2 + 0i) = 1 + 0i
        const z1 = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(@as(f32, std.math.pi) / 2), .f32(0) });
        const s1 = try c32_sin(runtime.context(), .nil, .nil, &.{z1});
        const d1 = s1.obj.as([2]f32);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), d1[0], @as(f32, 1e-6));
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d1[1], @as(f32, 1e-6));

        // sin(0 + i) = 0 + i*sinh(1)
        const z2 = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(0), .f32(1) });
        const s2 = try c32_sin(runtime.context(), .nil, .nil, &.{z2});
        const d2 = s2.obj.as([2]f32);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d2[0], @as(f32, 1e-6));
        try std.testing.expectApproxEqAbs(@as(f32, std.math.sinh(@as(f32, 1.0))), d2[1], @as(f32, 1e-6));
    }

    // c32 cos
    {

        // cos(0+0i) = 1+0i
        const z0 = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(0), .f32(0) });
        const c0 = try c32_cos(runtime.context(), .nil, .nil, &.{z0});
        const d0 = c0.obj.as([2]f32);
        try std.testing.expectEqual(@as(f32, 1.0), d0[0]);
        try std.testing.expectEqual(@as(f32, 0.0), d0[1]);

        // cos(pi/2 + 0i) = 0 + 0i
        const z1 = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(@as(f32, std.math.pi) / 2), .f32(0) });
        const c1 = try c32_cos(runtime.context(), .nil, .nil, &.{z1});
        const d1 = c1.obj.as([2]f32);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d1[0], @as(f32, 1e-6));
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d1[1], @as(f32, 1e-6));
    }

    // c32 tan
    {

        // tan(0+0i) = 0+0i
        const z0 = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(0), .f32(0) });
        const t0 = try c32_tan(runtime.context(), .nil, .nil, &.{z0});
        const d0 = t0.obj.as([2]f32);
        try std.testing.expectEqual(@as(f32, 0.0), d0[0]);
        try std.testing.expectEqual(@as(f32, 0.0), d0[1]);
    }

    // c32 sinh
    {

        // sinh(0+0i) = 0+0i
        const z0 = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(0), .f32(0) });
        const h0 = try c32_sinh(runtime.context(), .nil, .nil, &.{z0});
        const d0 = h0.obj.as([2]f32);
        try std.testing.expectEqual(@as(f32, 0.0), d0[0]);
        try std.testing.expectEqual(@as(f32, 0.0), d0[1]);

        // sinh(0 + i*pi/2) = 0 + i
        const z1 = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(0), .f32(@as(f32, std.math.pi) / 2) });
        const h1 = try c32_sinh(runtime.context(), .nil, .nil, &.{z1});
        const d1 = h1.obj.as([2]f32);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d1[0], @as(f32, 1e-6));
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), d1[1], @as(f32, 1e-6));
    }

    // c32 cosh
    {

        // cosh(0+0i) = 1+0i
        const z0 = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(0), .f32(0) });
        const h0 = try c32_cosh(runtime.context(), .nil, .nil, &.{z0});
        const d0 = h0.obj.as([2]f32);
        try std.testing.expectEqual(@as(f32, 1.0), d0[0]);
        try std.testing.expectEqual(@as(f32, 0.0), d0[1]);
    }

    // c32 identity: sin^2 + cos^2 = 1
    {
        const re: f32 = 0.7;
        const im: f32 = 1.2;
        const z = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(re), .f32(im) });
        const s = try c32_sin(runtime.context(), .nil, .nil, &.{z});
        const c = try c32_cos(runtime.context(), .nil, .nil, &.{z});
        const sd = s.obj.as([2]f32);
        const cd = c.obj.as([2]f32);
        // sin^2 + cos^2 = 1
        const sum_sq_re = sd[0] * sd[0] - sd[1] * sd[1] + cd[0] * cd[0] - cd[1] * cd[1];
        const sum_sq_im = 2 * sd[0] * sd[1] + 2 * cd[0] * cd[1];
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), sum_sq_re, @as(f32, 1e-5));
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), sum_sq_im, @as(f32, 1e-5));
    }

    // c32 arity error
    {
        try std.testing.expectError(error.ArityMismatch, c32_sin(runtime.context(), .nil, .nil, &.{}));
        try std.testing.expectError(error.ArityMismatch, c32_sin(runtime.context(), .nil, .nil, &.{ .nil, .nil }));
        try std.testing.expectError(error.ArityMismatch, c32_cos(runtime.context(), .nil, .nil, &.{}));
        try std.testing.expectError(error.ArityMismatch, c32_tan(runtime.context(), .nil, .nil, &.{}));
    }

    // c32 asin acos atan
    {

        // asin(0+0i) = 0+0i
        const z0 = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(0), .f32(0) });
        const a0 = try c32_asin(runtime.context(), .nil, .nil, &.{z0});
        const d0 = a0.obj.as([2]f32);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d0[0], @as(f32, 1e-6));
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d0[1], @as(f32, 1e-6));

        // acos(1+0i) = 0+0i
        const z1 = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(1), .f32(0) });
        const a1 = try c32_acos(runtime.context(), .nil, .nil, &.{z1});
        const d1 = a1.obj.as([2]f32);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d1[0], @as(f32, 1e-6));
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d1[1], @as(f32, 1e-6));

        // atan(0+0i) = 0+0i
        const z2 = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(0), .f32(0) });
        const a2 = try c32_atan(runtime.context(), .nil, .nil, &.{z2});
        const d2 = a2.obj.as([2]f32);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d2[0], @as(f32, 1e-6));
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d2[1], @as(f32, 1e-6));
    }

    // c32 tanh
    {

        // tanh(0+0i) = 0+0i
        const z0 = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(0), .f32(0) });
        const h0 = try c32_tanh(runtime.context(), .nil, .nil, &.{z0});
        const d0 = h0.obj.as([2]f32);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d0[0], @as(f32, 1e-6));
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d0[1], @as(f32, 1e-6));
    }

    // c32 asinh acosh atanh
    {

        // asinh(0+0i) = 0+0i
        const z0 = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(0), .f32(0) });
        const a0 = try c32_asinh(runtime.context(), .nil, .nil, &.{z0});
        const d0 = a0.obj.as([2]f32);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d0[0], @as(f32, 1e-6));
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d0[1], @as(f32, 1e-6));

        // acosh(1+0i) = 0+0i
        const z1 = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(1), .f32(0) });
        const a1 = try c32_acosh(runtime.context(), .nil, .nil, &.{z1});
        const d1 = a1.obj.as([2]f32);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d1[0], @as(f32, 1e-6));
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d1[1], @as(f32, 1e-6));

        // atanh(0+0i) = 0+0i
        const z2 = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(0), .f32(0) });
        const a2 = try c32_atanh(runtime.context(), .nil, .nil, &.{z2});
        const d2 = a2.obj.as([2]f32);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d2[0], @as(f32, 1e-6));
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d2[1], @as(f32, 1e-6));
    }

    // c32 identity: sin(z)/cos(z) = tan(z)
    {
        const re: f32 = 0.7;
        const im: f32 = 1.2;
        const z = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(re), .f32(im) });
        const s = try c32_sin(runtime.context(), .nil, .nil, &.{z});
        const c = try c32_cos(runtime.context(), .nil, .nil, &.{z});
        const t = try c32_tan(runtime.context(), .nil, .nil, &.{z});
        const sd = s.obj.as([2]f32);
        const cd = c.obj.as([2]f32);
        const td = t.obj.as([2]f32);
        // sin/cos should equal tan (complex division)
        const denom_mag2 = cd[0] * cd[0] + cd[1] * cd[1];
        const quot_re = (sd[0] * cd[0] + sd[1] * cd[1]) / denom_mag2;
        const quot_im = (sd[1] * cd[0] - sd[0] * cd[1]) / denom_mag2;
        try std.testing.expectApproxEqAbs(td[0], quot_re, @as(f32, 1e-5));
        try std.testing.expectApproxEqAbs(td[1], quot_im, @as(f32, 1e-5));
    }

    // c32 exp
    {

        // exp(0+0i) = 1+0i
        const z0 = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(0), .f32(0) });
        const e0 = try c32_exp(runtime.context(), .nil, .nil, &.{z0});
        const d0 = e0.obj.as([2]f32);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), d0[0], @as(f32, 1e-6));
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d0[1], @as(f32, 1e-6));

        // exp(0 + i*pi) = -1 + 0i (Euler's identity)
        const z1 = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(0), .f32(@as(f32, std.math.pi)) });
        const e1 = try c32_exp(runtime.context(), .nil, .nil, &.{z1});
        const d1 = e1.obj.as([2]f32);
        try std.testing.expectApproxEqAbs(@as(f32, -1.0), d1[0], @as(f32, 1e-5));
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d1[1], @as(f32, 1e-5));

        // exp(1 + 0i) = e + 0i
        const z2 = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(1), .f32(0) });
        const e2 = try c32_exp(runtime.context(), .nil, .nil, &.{z2});
        const d2 = e2.obj.as([2]f32);
        try std.testing.expectApproxEqAbs(@as(f32, std.math.e), d2[0], @as(f32, 1e-5));
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d2[1], @as(f32, 1e-5));
    }

    // c32 log
    {

        // log(1+0i) = 0+0i
        const z0 = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(1), .f32(0) });
        const l0 = try c32_log(runtime.context(), .nil, .nil, &.{z0});
        const d0 = l0.obj.as([2]f32);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d0[0], @as(f32, 1e-6));
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d0[1], @as(f32, 1e-6));

        // log(e + 0i) = 1 + 0i
        const z1 = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(@as(f32, std.math.e)), .f32(0) });
        const l1 = try c32_log(runtime.context(), .nil, .nil, &.{z1});
        const d1 = l1.obj.as([2]f32);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), d1[0], @as(f32, 1e-5));
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d1[1], @as(f32, 1e-5));

        // log(-1 + 0i) = 0 + i*pi
        const z2 = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(-1), .f32(0) });
        const l2 = try c32_log(runtime.context(), .nil, .nil, &.{z2});
        const d2 = l2.obj.as([2]f32);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d2[0], @as(f32, 1e-5));
        try std.testing.expectApproxEqAbs(@as(f32, std.math.pi), d2[1], @as(f32, 1e-5));
    }

    // c32 sqrt
    {

        // sqrt(4+0i) = 2+0i
        const z0 = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(4), .f32(0) });
        const s0 = try c32_sqrt(runtime.context(), .nil, .nil, &.{z0});
        const d0 = s0.obj.as([2]f32);
        try std.testing.expectApproxEqAbs(@as(f32, 2.0), d0[0], @as(f32, 1e-6));
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d0[1], @as(f32, 1e-6));

        // sqrt(-1+0i) = 0 + i
        const z1 = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(-1), .f32(0) });
        const s1 = try c32_sqrt(runtime.context(), .nil, .nil, &.{z1});
        const d1 = s1.obj.as([2]f32);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d1[0], @as(f32, 1e-6));
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), d1[1], @as(f32, 1e-6));
    }

    // c32 pow
    {

        // (2+0i)^(3+0i) = 8+0i
        const z_base = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(2), .f32(0) });
        const z_exp = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(3), .f32(0) });
        const p = try c32_pow(runtime.context(), .nil, .nil, &.{ z_base, z_exp });
        const d = p.obj.as([2]f32);
        try std.testing.expectApproxEqAbs(@as(f32, 8.0), d[0], @as(f32, 1e-5));
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), d[1], @as(f32, 1e-5));
    }

    // c32 conj
    {
        const z = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(1.5), .f32(2.5) });
        const c = try c32_conj(runtime.context(), .nil, .nil, &.{z});
        const d = c.obj.as([2]f32);
        try std.testing.expectEqual(@as(f32, 1.5), d[0]);
        try std.testing.expectEqual(@as(f32, -2.5), d[1]);
    }

    // c32 abs arg norm
    {

        // |3+4i| = 5
        const z = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(3), .f32(4) });
        const a = try c32Abs(runtime.context(), .nil, .nil, &.{z});
        try std.testing.expectApproxEqAbs(@as(f32, 5.0), a.obj.tof32(), @as(f32, 1e-6));

        // arg(1+0i) = 0
        const z1 = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(1), .f32(0) });
        const ar = try c32Arg(runtime.context(), .nil, .nil, &.{z1});
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), ar.obj.tof32(), @as(f32, 1e-6));

        // |3+4i|^2 = 25
        const n = try c32Norm(runtime.context(), .nil, .nil, &.{z});
        try std.testing.expectApproxEqAbs(@as(f32, 25.0), n.obj.tof32(), @as(f32, 1e-6));

        // arg(0+i) = pi/2
        const z2 = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(0), .f32(1) });
        const ar2 = try c32Arg(runtime.context(), .nil, .nil, &.{z2});
        try std.testing.expectApproxEqAbs(@as(f32, std.math.pi) / 2, ar2.obj.tof32(), @as(f32, 1e-6));
    }

    // c32 exp_arity_error
    {
        try std.testing.expectError(error.ArityMismatch, c32_exp(runtime.context(), .nil, .nil, &.{}));
        try std.testing.expectError(error.ArityMismatch, c32_log(runtime.context(), .nil, .nil, &.{}));
        try std.testing.expectError(error.ArityMismatch, c32_sqrt(runtime.context(), .nil, .nil, &.{}));
        try std.testing.expectError(error.ArityMismatch, c32_conj(runtime.context(), .nil, .nil, &.{}));
        try std.testing.expectError(error.ArityMismatch, c32Abs(runtime.context(), .nil, .nil, &.{}));
        try std.testing.expectError(error.ArityMismatch, c32Arg(runtime.context(), .nil, .nil, &.{}));
        try std.testing.expectError(error.ArityMismatch, c32Norm(runtime.context(), .nil, .nil, &.{}));
        try std.testing.expectError(error.ArityMismatch, c32_pow(runtime.context(), .nil, .nil, &.{Value.nil}));
    }

    // c32 fract mag polar
    {
        const z = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(3.14), .f32(1.5) });
        const r = try c32_fract(runtime.context(), .nil, .nil, &.{z});
        const d = r.obj.as([2]f32);
        try std.testing.expectApproxEqAbs(@as(f32, 0.14), d[0], @as(f32, 1e-6));
        try std.testing.expectApproxEqAbs(@as(f32, 0.5), d[1], @as(f32, 1e-6));
        const m = try c32Mag(runtime.context(), .nil, .nil, &.{z});
        try std.testing.expectApproxEqAbs(@as(f32, 3.48), m.obj.tof32(), @as(f32, 1e-2));
        // polar(5, atan2(4,3)) ≈ 3+4i
        const p = try c32Polar(
            runtime.context(),
            .nil,
            .nil,
            &.{ .f32(5.0), .f32(std.math.atan2(@as(f32, 4.0), @as(f32, 3.0))) },
        );
        const pd = p.obj.as([2]f32);
        try std.testing.expectApproxEqAbs(@as(f32, 3.0), pd[0], @as(f32, 1e-5));
        try std.testing.expectApproxEqAbs(@as(f32, 4.0), pd[1], @as(f32, 1e-5));
    }

    // c32 expm1 log1p mod rem
    {
        const z = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(1.0), .f32(0.0) });
        const e = try c32_expm1(runtime.context(), .nil, .nil, &.{z});
        const ed = e.obj.as([2]f32);
        try std.testing.expectApproxEqAbs(@as(f32, std.math.e - 1), ed[0], @as(f32, 1e-6));
        try std.testing.expectEqual(@as(f32, 0.0), ed[1]);
        const lz = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(0.0), .f32(0.0) });
        const l = try c32_log1p(runtime.context(), .nil, .nil, &.{lz});
        const ld = l.obj.as([2]f32);
        try std.testing.expectEqual(@as(f32, 0.0), ld[0]);
        try std.testing.expectEqual(@as(f32, 0.0), ld[1]);
        const a = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(7.0), .f32(8.0) });
        const b = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(3.0), .f32(5.0) });
        const m = try c32_mod(runtime.context(), .nil, .nil, &.{ a, b });
        const md = m.obj.as([2]f32);
        try std.testing.expectEqual(@as(f32, 1.0), md[0]);
        try std.testing.expectEqual(@as(f32, 3.0), md[1]);
        const r = try c32_rem(runtime.context(), .nil, .nil, &.{ a, b });
        const rd = r.obj.as([2]f32);
        try std.testing.expectEqual(@as(f32, 1.0), rd[0]);
        try std.testing.expectEqual(@as(f32, 3.0), rd[1]);
    }

    // c32 clamp blend unblend remap
    {
        const x = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(5.0), .f32(8.0) });
        const lo = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(0.0), .f32(1.0) });
        const hi = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(3.0), .f32(5.0) });
        const cl = try c32Clamp(runtime.context(), .nil, .nil, &.{ x, lo, hi });
        const cld = cl.obj.as([2]f32);
        try std.testing.expectEqual(@as(f32, 3.0), cld[0]);
        try std.testing.expectEqual(@as(f32, 5.0), cld[1]);
        const a = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(0.0), .f32(0.0) });
        const b = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(10.0), .f32(20.0) });
        const t = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(0.5), .f32(0.5) });
        const bl = try c32Blend(runtime.context(), .nil, .nil, &.{ a, b, t });
        const bld = bl.obj.as([2]f32);
        try std.testing.expectEqual(@as(f32, 5.0), bld[0]);
        try std.testing.expectEqual(@as(f32, 10.0), bld[1]);
        const ub = try c32Unblend(runtime.context(), .nil, .nil, &.{ a, b, bl });
        const ubd = ub.obj.as([2]f32);
        try std.testing.expectApproxEqAbs(@as(f32, 0.5), ubd[0], @as(f32, 1e-6));
        try std.testing.expectApproxEqAbs(@as(f32, 0.5), ubd[1], @as(f32, 1e-6));
        const in_lo = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(0.0), .f32(0.0) });
        const in_hi = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(10.0), .f32(20.0) });
        const out_lo = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(100.0), .f32(200.0) });
        const out_hi = try c32Cart(runtime.context(), .nil, .nil, &.{ .f32(200.0), .f32(300.0) });
        const rp = try c32Remap(runtime.context(), .nil, .nil, &.{ x, in_lo, in_hi, out_lo, out_hi });
        const rpd = rp.obj.as([2]f32);
        try std.testing.expectEqual(@as(f32, 150.0), rpd[0]);
        try std.testing.expectEqual(@as(f32, 240.0), rpd[1]);
    }
}

test "c64 all" {
    const runtime = try initTestingRuntime();
    defer runtime.deinit();

    // c64Cart round-trip
    {
        const val = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(1.5), .f64(2.5) });
        try std.testing.expectEqual(skript.builtins.type_c64, val.typ);
        const data = val.obj.toRef().deref([2]f64).*;
        try std.testing.expectEqual(@as(f64, 1.5), data[0]);
        try std.testing.expectEqual(@as(f64, 2.5), data[1]);
    }

    // c64_re and c64_im
    {
        const val = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(3.0), .f64(4.0) });
        const real = try c64_re(runtime.context(), .nil, .nil, &.{val});
        const imag = try c64_im(runtime.context(), .nil, .nil, &.{val});
        try std.testing.expectEqual(skript.builtins.type_f64, real.typ);
        try std.testing.expectEqual(skript.builtins.type_f64, imag.typ);
        try std.testing.expectEqual(@as(f64, 3.0), real.obj.tof64());
        try std.testing.expectEqual(@as(f64, 4.0), imag.obj.tof64());
    }

    // c64 add
    {
        const val_a = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(1.0), .f64(2.0) });
        const val_b = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(3.0), .f64(4.0) });
        const res = try c64_add(runtime.context(), .nil, .nil, &.{ val_a, val_b });
        const data = res.obj.toRef().deref([2]f64).*;
        try std.testing.expectEqual(@as(f64, 4.0), data[0]);
        try std.testing.expectEqual(@as(f64, 6.0), data[1]);
    }

    // c64 mul identity
    {

        // (1+0i) * (a+bi) = (a+bi)
        const one = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(1.0), .f64(0.0) });
        const val = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(3.0), .f64(4.0) });
        const res = try c64_mul(runtime.context(), .nil, .nil, &.{ one, val });
        const data = res.obj.toRef().deref([2]f64).*;
        try std.testing.expectEqual(@as(f64, 3.0), data[0]);
        try std.testing.expectEqual(@as(f64, 4.0), data[1]);
    }

    // c64 sin
    {

        // sin(0+0i) = 0+0i
        const z0 = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(0), .f64(0) });
        const s0 = try c64_sin(runtime.context(), .nil, .nil, &.{z0});
        const d0 = s0.obj.toRef().deref([2]f64).*;
        try std.testing.expectEqual(@as(f64, 0.0), d0[0]);
        try std.testing.expectEqual(@as(f64, 0.0), d0[1]);

        // sin(pi/2 + 0i) = 1 + 0i
        const z1 = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(@as(f64, std.math.pi) / 2), .f64(0) });
        const s1 = try c64_sin(runtime.context(), .nil, .nil, &.{z1});
        const d1 = s1.obj.toRef().deref([2]f64).*;
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), d1[0], @as(f64, 1e-12));
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), d1[1], @as(f64, 1e-12));
    }

    // c64 identity: cosh^2 - sinh^2 = 1
    {
        const re: f64 = 0.5;
        const im: f64 = 0.8;
        const z = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(re), .f64(im) });
        const sh = try c64_sinh(runtime.context(), .nil, .nil, &.{z});
        const ch = try c64_cosh(runtime.context(), .nil, .nil, &.{z});
        const shd = sh.obj.toRef().deref([2]f64).*;
        const chd = ch.obj.toRef().deref([2]f64).*;
        // cosh^2 - sinh^2 = 1 for complex
        const diff_re = chd[0] * chd[0] - chd[1] * chd[1] - (shd[0] * shd[0] - shd[1] * shd[1]);
        const diff_im = 2 * chd[0] * chd[1] - 2 * shd[0] * shd[1];
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), diff_re, @as(f64, 1e-12));
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), diff_im, @as(f64, 1e-12));
    }

    // c64 cos tan
    {

        // cos(0+0i) = 1+0i
        const z0 = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(0), .f64(0) });
        const c0 = try c64_cos(runtime.context(), .nil, .nil, &.{z0});
        const d0 = c0.obj.toRef().deref([2]f64).*;
        try std.testing.expectEqual(@as(f64, 1.0), d0[0]);
        try std.testing.expectEqual(@as(f64, 0.0), d0[1]);

        // tan(0+0i) = 0+0i
        const z1 = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(0), .f64(0) });
        const t0 = try c64_tan(runtime.context(), .nil, .nil, &.{z1});
        const d1 = t0.obj.toRef().deref([2]f64).*;
        try std.testing.expectEqual(@as(f64, 0.0), d1[0]);
        try std.testing.expectEqual(@as(f64, 0.0), d1[1]);
    }

    // c64 asin acos atan
    {
        const z = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(0), .f64(0) });
        const a = try c64_asin(runtime.context(), .nil, .nil, &.{z});
        const d = a.obj.toRef().deref([2]f64).*;
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), d[0], @as(f64, 1e-12));
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), d[1], @as(f64, 1e-12));

        const b = try c64_acos(runtime.context(), .nil, .nil, &.{z});
        const e = b.obj.toRef().deref([2]f64).*;
        try std.testing.expectApproxEqAbs(@as(f64, std.math.pi) / 2, e[0], @as(f64, 1e-12));
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), e[1], @as(f64, 1e-12));

        const c = try c64_atan(runtime.context(), .nil, .nil, &.{z});
        const f = c.obj.toRef().deref([2]f64).*;
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), f[0], @as(f64, 1e-12));
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), f[1], @as(f64, 1e-12));
    }

    // c64 tanh
    {
        const z = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(0), .f64(0) });
        const h = try c64_tanh(runtime.context(), .nil, .nil, &.{z});
        const d = h.obj.toRef().deref([2]f64).*;
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), d[0], @as(f64, 1e-12));
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), d[1], @as(f64, 1e-12));
    }

    // c64 asinh acosh atanh
    {
        const z = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(0), .f64(0) });
        const a = try c64_asinh(runtime.context(), .nil, .nil, &.{z});
        const da = a.obj.toRef().deref([2]f64).*;
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), da[0], @as(f64, 1e-12));
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), da[1], @as(f64, 1e-12));

        // acosh(2+0i) = ln(2+sqrt(3)) + 0i ≈ 1.317
        const z2 = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(2), .f64(0) });
        const b = try c64_acosh(runtime.context(), .nil, .nil, &.{z2});
        const db = b.obj.toRef().deref([2]f64).*;
        const acosh2 = @log(2.0 + std.math.sqrt(3.0));
        try std.testing.expectApproxEqAbs(acosh2, db[0], @as(f64, 1e-12));
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), db[1], @as(f64, 1e-12));

        // atanh(0+0i) = 0+0i
        const c = try c64_atanh(runtime.context(), .nil, .nil, &.{z});
        const dc = c.obj.toRef().deref([2]f64).*;
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), dc[0], @as(f64, 1e-12));
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), dc[1], @as(f64, 1e-12));
    }

    // c64 exp
    {

        // exp(0+0i) = 1+0i
        const z0 = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(0), .f64(0) });
        const e0 = try c64_exp(runtime.context(), .nil, .nil, &.{z0});
        const d0 = e0.obj.toRef().deref([2]f64).*;
        try std.testing.expectEqual(@as(f64, 1.0), d0[0]);
        try std.testing.expectEqual(@as(f64, 0.0), d0[1]);

        // Euler: exp(0 + i*pi) = -1 + 0i
        const z1 = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(0), .f64(std.math.pi) });
        const e1 = try c64_exp(runtime.context(), .nil, .nil, &.{z1});
        const d1 = e1.obj.toRef().deref([2]f64).*;
        try std.testing.expectApproxEqAbs(@as(f64, -1.0), d1[0], @as(f64, 1e-12));
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), d1[1], @as(f64, 1e-12));
    }

    // c64 log sqrt conj
    {

        // log(e + 0i) = 1 + 0i
        const z0 = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(std.math.e), .f64(0) });
        const l = try c64_log(runtime.context(), .nil, .nil, &.{z0});
        const dl = l.obj.toRef().deref([2]f64).*;
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), dl[0], @as(f64, 1e-12));
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), dl[1], @as(f64, 1e-12));

        // sqrt(9+0i) = 3+0i
        const z1 = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(9), .f64(0) });
        const s = try c64_sqrt(runtime.context(), .nil, .nil, &.{z1});
        const ds = s.obj.toRef().deref([2]f64).*;
        try std.testing.expectApproxEqAbs(@as(f64, 3.0), ds[0], @as(f64, 1e-12));
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), ds[1], @as(f64, 1e-12));

        // conj(2-3i) = 2+3i
        const z2 = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(2), .f64(-3) });
        const c = try c64_conj(runtime.context(), .nil, .nil, &.{z2});
        const dc = c.obj.toRef().deref([2]f64).*;
        try std.testing.expectEqual(@as(f64, 2.0), dc[0]);
        try std.testing.expectEqual(@as(f64, 3.0), dc[1]);
    }

    // c64 pow
    {

        // (2+0i)^(0+0i) = 1+0i
        const base = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(2), .f64(0) });
        const exp = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(0), .f64(0) });
        const p = try c64_pow(runtime.context(), .nil, .nil, &.{ base, exp });
        const d = p.obj.toRef().deref([2]f64).*;
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), d[0], @as(f64, 1e-12));
        try std.testing.expectApproxEqAbs(@as(f64, 0.0), d[1], @as(f64, 1e-12));
    }

    // c64 abs arg norm
    {

        // |3+4i| = 5
        const z = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(3), .f64(4) });
        const a = try c64Abs(runtime.context(), .nil, .nil, &.{z});
        try std.testing.expectApproxEqAbs(@as(f64, 5.0), a.obj.tof64(), @as(f64, 1e-12));

        // arg(0+i) = pi/2
        const z1 = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(0), .f64(1) });
        const ar = try c64Arg(runtime.context(), .nil, .nil, &.{z1});
        try std.testing.expectApproxEqAbs(@as(f64, std.math.pi) / 2, ar.obj.tof64(), @as(f64, 1e-12));

        // |3+4i|^2 = 25
        const n = try c64Norm(runtime.context(), .nil, .nil, &.{z});
        try std.testing.expectApproxEqAbs(@as(f64, 25.0), n.obj.tof64(), @as(f64, 1e-12));
    }

    // c64 fract
    {
        const z = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(3.14), .f64(1.5) });
        const r = try c64_fract(runtime.context(), .nil, .nil, &.{z});
        const parts = intrin.complexPartsStored(runtime, r);
        try std.testing.expectApproxEqAbs(@as(f64, 0.14), parts[0], @as(f64, 1e-12));
        try std.testing.expectApproxEqAbs(@as(f64, 0.5), parts[1], @as(f64, 1e-12));
    }

    // c64 mag polar
    {
        // 3+4i → mag=5
        const z = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(3.0), .f64(4.0) });
        const m = try c64Mag(runtime.context(), .nil, .nil, &.{z});
        try std.testing.expectEqual(@as(f64, 5.0), m.obj.tof64());
        // polar(5, atan2(4,3)) → 3+4i
        const p = try c64Polar(
            runtime.context(),
            .nil,
            .nil,
            &.{ .f64(5.0), .f64(std.math.atan2(@as(f64, 4.0), @as(f64, 3.0))) },
        );
        const pp = intrin.complexPartsStored(runtime, p);
        try std.testing.expectApproxEqAbs(@as(f64, 3.0), pp[0], @as(f64, 1e-10));
        try std.testing.expectApproxEqAbs(@as(f64, 4.0), pp[1], @as(f64, 1e-10));
    }

    // c64 expm1 log1p
    {
        const z = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(1.0), .f64(0.0) });
        const e = try c64_expm1(runtime.context(), .nil, .nil, &.{z});
        const ep = intrin.complexPartsStored(runtime, e);
        try std.testing.expectApproxEqAbs(@as(f64, std.math.e - 1), ep[0], @as(f64, 1e-12));
        try std.testing.expectEqual(@as(f64, 0.0), ep[1]);
        const zero = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(0.0), .f64(0.0) });
        const l = try c64_log1p(runtime.context(), .nil, .nil, &.{zero});
        const lp = intrin.complexPartsStored(runtime, l);
        try std.testing.expectEqual(@as(f64, 0.0), lp[0]);
        try std.testing.expectEqual(@as(f64, 0.0), lp[1]);
    }

    // c64 mod rem
    {
        // mod: component-wise floored
        const a_pos = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(7.0), .f64(8.0) });
        const b = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(3.0), .f64(5.0) });
        const m = try c64_mod(runtime.context(), .nil, .nil, &.{ a_pos, b });
        const md = intrin.complexPartsStored(runtime, m);
        try std.testing.expectEqual(@as(f64, 1.0), md[0]);
        try std.testing.expectEqual(@as(f64, 3.0), md[1]);
        const r = try c64_rem(runtime.context(), .nil, .nil, &.{ a_pos, b });
        const rd = intrin.complexPartsStored(runtime, r);
        try std.testing.expectEqual(@as(f64, 1.0), rd[0]);
        try std.testing.expectEqual(@as(f64, 3.0), rd[1]);
        // negative: mod (floored) vs rem (truncated) differ
        const a_neg = try c64Cart(runtime.context(), .nil, .nil, &.{ .f64(-7.0), .f64(-8.0) });
        const m2 = try c64_mod(runtime.context(), .nil, .nil, &.{ a_neg, b });
        const md2 = intrin.complexPartsStored(runtime, m2);
        try std.testing.expectEqual(@as(f64, 2.0), md2[0]); // -7 = -3*3 + 2
        try std.testing.expectEqual(@as(f64, 2.0), md2[1]); // -8 = -2*5 + 2
        const r2 = try c64_rem(runtime.context(), .nil, .nil, &.{ a_neg, b });
        const rd2 = intrin.complexPartsStored(runtime, r2);
        try std.testing.expectEqual(@as(f64, -1.0), rd2[0]); // -7 = -2*3 - 1
        try std.testing.expectEqual(@as(f64, -3.0), rd2[1]); // -8 = -1*5 - 3
    }
}
