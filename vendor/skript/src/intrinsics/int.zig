const std = @import("std");

const skript = @import("../root.zig");
const Value = skript.Value;
const Error = skript.Error;
const EvalContext = skript.EvalContext;
const Func = skript.Func;
const Runtime = skript.Runtime;

const intrin = @import("root.zig");
const makeWrapper = intrin.makeWrapper;

fn add(comptime T: type) fn (T, T) T {
    return struct {
        fn add(a: T, b: T) T {
            return a +% b;
        }
    }.add;
}

fn sub(comptime T: type) fn (T, T) T {
    return struct {
        fn sub(a: T, b: T) T {
            return a -% b;
        }
    }.sub;
}

fn mul(comptime T: type) fn (T, T) T {
    return struct {
        fn mul(a: T, b: T) T {
            return a *% b;
        }
    }.mul;
}

fn div(comptime T: type) fn (T, T) T {
    return struct {
        fn div(a: T, b: T) T {
            return @divTrunc(a, b);
        }
    }.div;
}

fn compare(comptime T: type, comptime cmp: std.math.CompareOperator) fn (T, T) bool {
    return struct {
        fn compare(a: T, b: T) bool {
            return std.math.compare(a, cmp, b);
        }
    }.compare;
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

fn neg(comptime T: type) fn (T) T {
    return struct {
        fn neg(a: T) T {
            // Wrap: -@minInt(T) (signed) and 0 -% a (unsigned) are modular —
            // never trap in safe builds (§02 overflow policy, matches +/*).
            return if (@typeInfo(T).int.signedness == .signed) -%a else 0 -% a;
        }
    }.neg;
}

fn abs(comptime T: type) fn (T) T {
    return struct {
        fn abs(a: T) T {
            // Wrap: -@minInt(T) is modular, never traps (§02 overflow policy).
            return if (a < 0) -%a else a;
        }
    }.abs;
}

fn sign(comptime T: type) fn (T) T {
    return struct {
        fn sign(a: T) T {
            if (a > 0) return 1 else if (a < 0) return -1 else return 0;
        }
    }.sign;
}

fn intRem(comptime T: type) fn (T, T) T {
    return struct {
        fn intRem(a: T, b: T) T {
            return @rem(a, b);
        }
    }.intRem;
}

fn intMod(comptime T: type) fn (T, T) T {
    return struct {
        fn intMod(a: T, b: T) T {
            return @mod(a, b);
        }
    }.intMod;
}

fn intPow(comptime T: type) fn (T, T) T {
    return struct {
        fn intPow(a: T, b: T) T {
            // Overflow wraps modularly (two's complement), matching + and * —
            // see spec §02 overflow policy. Never a `catch 0` sentinel.
            if (comptime @typeInfo(T).int.signedness == .signed) {
                // A negative exponent is fractional for |a| > 1 (no integer
                // value) and undefined for a == 0; keep the prior 0 result.
                if (b < 0) return 0;
            }
            var result: T = 1;
            var base = a;
            var exp = b;
            while (true) {
                if ((exp & 1) == 1) result = result *% base;
                exp >>= 1;
                if (exp == 0) break;
                base = base *% base;
            }
            return result;
        }
    }.intPow;
}

fn shl(comptime T: type) fn (T, T) T {
    return struct {
        fn shl(a: T, b: T) T {
            return a << @intCast(b);
        }
    }.shl;
}

fn shr(comptime T: type) fn (T, T) T {
    return struct {
        fn shr(a: T, b: T) T {
            return a >> @intCast(b);
        }
    }.shr;
}

fn intClamp(comptime T: type) fn (T, T, T) T {
    return struct {
        fn intClamp(x: T, lo: T, hi: T) T {
            const l = @min(lo, hi);
            const h = @max(lo, hi);
            return @max(@min(x, h), l);
        }
    }.intClamp;
}

fn fromF64(comptime T: type) fn (f64) T {
    return struct {
        fn fromF64(x: f64) T {
            // out-of-range/NaN saturate via lossyCast (zbc intfromfloat-without-clamp)
            return std.math.lossyCast(T, x);
        }
    }.fromF64;
}

fn fromF32(comptime T: type) fn (f32) T {
    return struct {
        fn fromF32(x: f32) T {
            // out-of-range/NaN saturate via lossyCast (zbc intfromfloat-without-clamp)
            return std.math.lossyCast(T, x);
        }
    }.fromF32;
}

fn fromF16(comptime T: type) fn (f16) T {
    return struct {
        fn fromF16(x: f16) T {
            // out-of-range/NaN saturate via lossyCast (zbc intfromfloat-without-clamp)
            return std.math.lossyCast(T, x);
        }
    }.fromF16;
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

pub const i64_add = makeWrapper(add(i64));
pub const i64_sub = makeWrapper(sub(i64));
pub const i64_mul = makeWrapper(mul(i64));
pub const i64_div = makeWrapper(div(i64));
pub const i64_eq = makeWrapper(compare(i64, .eq));
pub const i64_ne = makeWrapper(compare(i64, .neq));
pub const i64_gt = makeWrapper(compare(i64, .gt));
pub const i64_lt = makeWrapper(compare(i64, .lt));
pub const i64_gte = makeWrapper(compare(i64, .gte));
pub const i64_lte = makeWrapper(compare(i64, .lte));
pub const i64_min = makeWrapper(min(i64));
pub const i64_max = makeWrapper(max(i64));
pub const i64_neg = makeWrapper(neg(i64));
pub const i64_abs = makeWrapper(abs(i64));
pub const i64_sign = makeWrapper(sign(i64));
pub const i64_rem = makeWrapper(intRem(i64));
pub const i64_mod = makeWrapper(intMod(i64));
pub const i64_pow = makeWrapper(intPow(i64));
pub const i64_shl = makeWrapper(shl(i64));
pub const i64_shr = makeWrapper(shr(i64));
pub const i64_clamp = makeWrapper(intClamp(i64));
pub const i64_from_f64 = makeWrapper(fromF64(i64));
pub const i64_is_odd = makeWrapper(isOdd(i64));
pub const i64_is_even = makeWrapper(isEven(i64));

pub const i8_add = makeWrapper(add(i8));
pub const i8_sub = makeWrapper(sub(i8));
pub const i8_mul = makeWrapper(mul(i8));
pub const i8_div = makeWrapper(div(i8));
pub const i8_eq = makeWrapper(compare(i8, .eq));
pub const i8_ne = makeWrapper(compare(i8, .neq));
pub const i8_gt = makeWrapper(compare(i8, .gt));
pub const i8_lt = makeWrapper(compare(i8, .lt));
pub const i8_gte = makeWrapper(compare(i8, .gte));
pub const i8_lte = makeWrapper(compare(i8, .lte));
pub const i8_min = makeWrapper(min(i8));
pub const i8_max = makeWrapper(max(i8));
pub const i8_neg = makeWrapper(neg(i8));
pub const i8_abs = makeWrapper(abs(i8));
pub const i8_sign = makeWrapper(sign(i8));
pub const i8_rem = makeWrapper(intRem(i8));
pub const i8_mod = makeWrapper(intMod(i8));
pub const i8_pow = makeWrapper(intPow(i8));
pub const i8_shl = makeWrapper(shl(i8));
pub const i8_shr = makeWrapper(shr(i8));
pub const i8_clamp = makeWrapper(intClamp(i8));
pub const i8_from_f64 = makeWrapper(fromF64(i8));
pub const i8_is_odd = makeWrapper(isOdd(i8));
pub const i8_is_even = makeWrapper(isEven(i8));

pub const i16_add = makeWrapper(add(i16));
pub const i16_sub = makeWrapper(sub(i16));
pub const i16_mul = makeWrapper(mul(i16));
pub const i16_div = makeWrapper(div(i16));
pub const i16_eq = makeWrapper(compare(i16, .eq));
pub const i16_ne = makeWrapper(compare(i16, .neq));
pub const i16_gt = makeWrapper(compare(i16, .gt));
pub const i16_lt = makeWrapper(compare(i16, .lt));
pub const i16_gte = makeWrapper(compare(i16, .gte));
pub const i16_lte = makeWrapper(compare(i16, .lte));
pub const i16_min = makeWrapper(min(i16));
pub const i16_max = makeWrapper(max(i16));
pub const i16_neg = makeWrapper(neg(i16));
pub const i16_abs = makeWrapper(abs(i16));
pub const i16_sign = makeWrapper(sign(i16));
pub const i16_rem = makeWrapper(intRem(i16));
pub const i16_mod = makeWrapper(intMod(i16));
pub const i16_pow = makeWrapper(intPow(i16));
pub const i16_shl = makeWrapper(shl(i16));
pub const i16_shr = makeWrapper(shr(i16));
pub const i16_clamp = makeWrapper(intClamp(i16));
pub const i16_from_f64 = makeWrapper(fromF64(i16));
pub const i16_is_odd = makeWrapper(isOdd(i16));
pub const i16_is_even = makeWrapper(isEven(i16));

pub const i32_add = makeWrapper(add(i32));
pub const i32_sub = makeWrapper(sub(i32));
pub const i32_mul = makeWrapper(mul(i32));
pub const i32_div = makeWrapper(div(i32));
pub const i32_eq = makeWrapper(compare(i32, .eq));
pub const i32_ne = makeWrapper(compare(i32, .neq));
pub const i32_gt = makeWrapper(compare(i32, .gt));
pub const i32_lt = makeWrapper(compare(i32, .lt));
pub const i32_gte = makeWrapper(compare(i32, .gte));
pub const i32_lte = makeWrapper(compare(i32, .lte));
pub const i32_min = makeWrapper(min(i32));
pub const i32_max = makeWrapper(max(i32));
pub const i32_neg = makeWrapper(neg(i32));
pub const i32_abs = makeWrapper(abs(i32));
pub const i32_sign = makeWrapper(sign(i32));
pub const i32_rem = makeWrapper(intRem(i32));
pub const i32_mod = makeWrapper(intMod(i32));
pub const i32_pow = makeWrapper(intPow(i32));
pub const i32_shl = makeWrapper(shl(i32));
pub const i32_shr = makeWrapper(shr(i32));
pub const i32_clamp = makeWrapper(intClamp(i32));
pub const i32_from_f64 = makeWrapper(fromF64(i32));
pub const i32_is_odd = makeWrapper(isOdd(i32));
pub const i32_is_even = makeWrapper(isEven(i32));

pub const u8_add = makeWrapper(add(u8));
pub const u8_sub = makeWrapper(sub(u8));
pub const u8_mul = makeWrapper(mul(u8));
pub const u8_div = makeWrapper(div(u8));
pub const u8_eq = makeWrapper(compare(u8, .eq));
pub const u8_ne = makeWrapper(compare(u8, .neq));
pub const u8_gt = makeWrapper(compare(u8, .gt));
pub const u8_lt = makeWrapper(compare(u8, .lt));
pub const u8_gte = makeWrapper(compare(u8, .gte));
pub const u8_lte = makeWrapper(compare(u8, .lte));
pub const u8_min = makeWrapper(min(u8));
pub const u8_max = makeWrapper(max(u8));
pub const u8_neg = makeWrapper(neg(u8));
pub const u8_abs = makeWrapper(abs(u8));
pub const u8_sign = makeWrapper(sign(u8));
pub const u8_rem = makeWrapper(intRem(u8));
pub const u8_mod = makeWrapper(intMod(u8));
pub const u8_pow = makeWrapper(intPow(u8));
pub const u8_shl = makeWrapper(shl(u8));
pub const u8_shr = makeWrapper(shr(u8));
pub const u8_clamp = makeWrapper(intClamp(u8));
pub const u8_from_f64 = makeWrapper(fromF64(u8));
pub const u8_is_odd = makeWrapper(isOdd(u8));
pub const u8_is_even = makeWrapper(isEven(u8));

pub const u16_add = makeWrapper(add(u16));
pub const u16_sub = makeWrapper(sub(u16));
pub const u16_mul = makeWrapper(mul(u16));
pub const u16_div = makeWrapper(div(u16));
pub const u16_eq = makeWrapper(compare(u16, .eq));
pub const u16_ne = makeWrapper(compare(u16, .neq));
pub const u16_gt = makeWrapper(compare(u16, .gt));
pub const u16_lt = makeWrapper(compare(u16, .lt));
pub const u16_gte = makeWrapper(compare(u16, .gte));
pub const u16_lte = makeWrapper(compare(u16, .lte));
pub const u16_min = makeWrapper(min(u16));
pub const u16_max = makeWrapper(max(u16));
pub const u16_neg = makeWrapper(neg(u16));
pub const u16_abs = makeWrapper(abs(u16));
pub const u16_sign = makeWrapper(sign(u16));
pub const u16_rem = makeWrapper(intRem(u16));
pub const u16_mod = makeWrapper(intMod(u16));
pub const u16_pow = makeWrapper(intPow(u16));
pub const u16_shl = makeWrapper(shl(u16));
pub const u16_shr = makeWrapper(shr(u16));
pub const u16_clamp = makeWrapper(intClamp(u16));
pub const u16_from_f64 = makeWrapper(fromF64(u16));
pub const u16_is_odd = makeWrapper(isOdd(u16));
pub const u16_is_even = makeWrapper(isEven(u16));

pub const u32_add = makeWrapper(add(u32));
pub const u32_sub = makeWrapper(sub(u32));
pub const u32_mul = makeWrapper(mul(u32));
pub const u32_div = makeWrapper(div(u32));
pub const u32_eq = makeWrapper(compare(u32, .eq));
pub const u32_ne = makeWrapper(compare(u32, .neq));
pub const u32_gt = makeWrapper(compare(u32, .gt));
pub const u32_lt = makeWrapper(compare(u32, .lt));
pub const u32_gte = makeWrapper(compare(u32, .gte));
pub const u32_lte = makeWrapper(compare(u32, .lte));
pub const u32_min = makeWrapper(min(u32));
pub const u32_max = makeWrapper(max(u32));
pub const u32_neg = makeWrapper(neg(u32));
pub const u32_abs = makeWrapper(abs(u32));
pub const u32_sign = makeWrapper(sign(u32));
pub const u32_rem = makeWrapper(intRem(u32));
pub const u32_mod = makeWrapper(intMod(u32));
pub const u32_pow = makeWrapper(intPow(u32));
pub const u32_shl = makeWrapper(shl(u32));
pub const u32_shr = makeWrapper(shr(u32));
pub const u32_clamp = makeWrapper(intClamp(u32));
pub const u32_from_f64 = makeWrapper(fromF64(u32));
pub const u32_is_odd = makeWrapper(isOdd(u32));
pub const u32_is_even = makeWrapper(isEven(u32));

pub const u64_add = makeWrapper(add(u64));
pub const u64_sub = makeWrapper(sub(u64));
pub const u64_mul = makeWrapper(mul(u64));
pub const u64_div = makeWrapper(div(u64));
pub const u64_eq = makeWrapper(compare(u64, .eq));
pub const u64_ne = makeWrapper(compare(u64, .neq));
pub const u64_gt = makeWrapper(compare(u64, .gt));
pub const u64_lt = makeWrapper(compare(u64, .lt));
pub const u64_gte = makeWrapper(compare(u64, .gte));
pub const u64_lte = makeWrapper(compare(u64, .lte));
pub const u64_min = makeWrapper(min(u64));
pub const u64_max = makeWrapper(max(u64));
pub const u64_neg = makeWrapper(neg(u64));
pub const u64_abs = makeWrapper(abs(u64));
pub const u64_sign = makeWrapper(sign(u64));
pub const u64_rem = makeWrapper(intRem(u64));
pub const u64_mod = makeWrapper(intMod(u64));
pub const u64_pow = makeWrapper(intPow(u64));
pub const u64_shl = makeWrapper(shl(u64));
pub const u64_shr = makeWrapper(shr(u64));
pub const u64_clamp = makeWrapper(intClamp(u64));
pub const u64_from_f64 = makeWrapper(fromF64(u64));
pub const u64_is_odd = makeWrapper(isOdd(u64));
pub const u64_is_even = makeWrapper(isEven(u64));
pub const u64_from_f32 = makeWrapper(fromF32(u64));
pub const u64_from_f16 = makeWrapper(fromF16(u64));

pub const i8_from_f32 = makeWrapper(fromF32(i8));
pub const i8_from_f16 = makeWrapper(fromF16(i8));
pub const i16_from_f32 = makeWrapper(fromF32(i16));
pub const i16_from_f16 = makeWrapper(fromF16(i16));
pub const i32_from_f32 = makeWrapper(fromF32(i32));
pub const i32_from_f16 = makeWrapper(fromF16(i32));
pub const i64_from_f32 = makeWrapper(fromF32(i64));
pub const i64_from_f16 = makeWrapper(fromF16(i64));
pub const u8_from_f32 = makeWrapper(fromF32(u8));
pub const u8_from_f16 = makeWrapper(fromF16(u8));
pub const u16_from_f32 = makeWrapper(fromF32(u16));
pub const u16_from_f16 = makeWrapper(fromF16(u16));
pub const u32_from_f32 = makeWrapper(fromF32(u32));
pub const u32_from_f16 = makeWrapper(fromF16(u32));

test "i64 ops" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();

    try std.testing.expectEqual(
        @as(i64, 5),
        (try i64_add(runtime.context(), .nil, .nil, &.{ .i64(2), .i64(3) })).obj.toInt(i64),
    );
    try std.testing.expectEqual(
        @as(i64, 2),
        (try i64_sub(runtime.context(), .nil, .nil, &.{ .i64(5), .i64(3) })).obj.toInt(i64),
    );
    try std.testing.expectEqual(
        @as(i64, 6),
        (try i64_mul(runtime.context(), .nil, .nil, &.{ .i64(2), .i64(3) })).obj.toInt(i64),
    );
    try std.testing.expectEqual(
        @as(i64, 2),
        (try i64_div(runtime.context(), .nil, .nil, &.{ .i64(7), .i64(3) })).obj.toInt(i64),
    );
    try std.testing.expect(
        (try i64_eq(runtime.context(), .nil, .nil, &.{ .i64(3), .i64(3) })).obj.toBool(),
    );
    try std.testing.expect(
        (try i64_ne(runtime.context(), .nil, .nil, &.{ .i64(3), .i64(4) })).obj.toBool(),
    );
    try std.testing.expect((try i64_gt(runtime.context(), .nil, .nil, &.{ .i64(4), .i64(3) })).obj.toBool());
    try std.testing.expect((try i64_lt(runtime.context(), .nil, .nil, &.{ .i64(3), .i64(4) })).obj.toBool());
    try std.testing.expect((try i64_gte(runtime.context(), .nil, .nil, &.{ .i64(3), .i64(3) })).obj.toBool());
    try std.testing.expect((try i64_lte(runtime.context(), .nil, .nil, &.{ .i64(3), .i64(3) })).obj.toBool());
    try std.testing.expectEqual(
        @as(i64, 2),
        (try i64_min(runtime.context(), .nil, .nil, &.{ .i64(2), .i64(5) })).obj.toInt(i64),
    );
    try std.testing.expectEqual(
        @as(i64, 5),
        (try i64_max(runtime.context(), .nil, .nil, &.{ .i64(2), .i64(5) })).obj.toInt(i64),
    );
    try std.testing.expectEqual(
        @as(i64, -3),
        (try i64_neg(runtime.context(), .nil, .nil, &.{.i64(3)})).obj.toInt(i64),
    );
    try std.testing.expectEqual(
        @as(i64, 3),
        (try i64_abs(runtime.context(), .nil, .nil, &.{.i64(-3)})).obj.toInt(i64),
    );
    try std.testing.expectEqual(
        @as(i64, 0),
        (try i64_sign(runtime.context(), .nil, .nil, &.{.i64(0)})).obj.toInt(i64),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        (try i64_sign(runtime.context(), .nil, .nil, &.{.i64(5)})).obj.toInt(i64),
    );
    try std.testing.expectEqual(
        @as(i64, -1),
        (try i64_sign(runtime.context(), .nil, .nil, &.{.i64(-3)})).obj.toInt(i64),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        (try i64_rem(runtime.context(), .nil, .nil, &.{ .i64(7), .i64(3) })).obj.toInt(i64),
    );
    try std.testing.expectEqual(
        @as(i64, -1),
        (try i64_rem(runtime.context(), .nil, .nil, &.{ .i64(-7), .i64(3) })).obj.toInt(i64),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        (try i64_mod(runtime.context(), .nil, .nil, &.{ .i64(7), .i64(3) })).obj.toInt(i64),
    );
    try std.testing.expectEqual(
        @as(i64, 2),
        (try i64_mod(runtime.context(), .nil, .nil, &.{ .i64(-7), .i64(3) })).obj.toInt(i64),
    );
    try std.testing.expectEqual(
        @as(i64, 1024),
        (try i64_pow(runtime.context(), .nil, .nil, &.{ .i64(2), .i64(10) })).obj.toInt(i64),
    );
    try std.testing.expectEqual(
        @as(i64, 8),
        (try i64_shl(runtime.context(), .nil, .nil, &.{ .i64(1), .i64(3) })).obj.toInt(i64),
    );
    try std.testing.expectEqual(
        @as(i64, 2),
        (try i64_shr(runtime.context(), .nil, .nil, &.{ .i64(16), .i64(3) })).obj.toInt(i64),
    );
    try std.testing.expectEqual(
        @as(i64, 3),
        (try i64_clamp(runtime.context(), .nil, .nil, &.{ .i64(5), .i64(0), .i64(3) })).obj.toInt(i64),
    );
    try std.testing.expectEqual(
        @as(i64, 0),
        (try i64_clamp(runtime.context(), .nil, .nil, &.{ .i64(-1), .i64(0), .i64(3) })).obj.toInt(i64),
    );
    try std.testing.expect((try i64_is_odd(runtime.context(), .nil, .nil, &.{.i64(5)})).obj.toBool());
    try std.testing.expect(!(try i64_is_odd(runtime.context(), .nil, .nil, &.{.i64(4)})).obj.toBool());
    try std.testing.expect((try i64_is_even(runtime.context(), .nil, .nil, &.{.i64(4)})).obj.toBool());
    try std.testing.expect(!(try i64_is_even(runtime.context(), .nil, .nil, &.{.i64(5)})).obj.toBool());
    try std.testing.expectEqual(
        @as(i64, 3),
        (try i64_from_f64(runtime.context(), .nil, .nil, &.{.f64(3.14)})).obj.toInt(i64),
    );
}

test "other integer ops" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();

    try std.testing.expectEqual(
        @as(i8, 1),
        (try i8_rem(runtime.context(), .nil, .nil, &.{ .i8(7), .i8(3) })).obj.toInt(i8),
    );
    try std.testing.expectEqual(
        @as(i8, 2),
        (try i8_mod(runtime.context(), .nil, .nil, &.{ .i8(-7), .i8(3) })).obj.toInt(i8),
    );

    try std.testing.expectEqual(
        @as(u64, 1),
        (try u64_rem(runtime.context(), .nil, .nil, &.{ .u64(7), .u64(3) })).obj.toInt(u64),
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        (try u64_mod(runtime.context(), .nil, .nil, &.{ .u64(7), .u64(3) })).obj.toInt(u64),
    );

    const res = try i16_add(runtime.context(), .nil, .nil, &.{ .i16(2), .i16(3) });
    try std.testing.expectEqual(@as(i16, 5), res.obj.toInt(i16));
    const res2 = try i16_sub(runtime.context(), .nil, .nil, &.{ .i16(2), .i16(3) });
    try std.testing.expectEqual(@as(i16, -1), res2.obj.toInt(i16));
    const res3 = try i16_mul(runtime.context(), .nil, .nil, &.{ .i16(2), .i16(3) });
    try std.testing.expectEqual(@as(i16, 6), res3.obj.toInt(i16));
    const res4 = try i16_div(runtime.context(), .nil, .nil, &.{ .i16(7), .i16(3) });
    try std.testing.expectEqual(@as(i16, 2), res4.obj.toInt(i16));
    try std.testing.expect((try i16_eq(runtime.context(), .nil, .nil, &.{ .i16(3), .i16(3) })).obj.toBool());
    try std.testing.expect((try i16_ne(runtime.context(), .nil, .nil, &.{ .i16(3), .i16(4) })).obj.toBool());
    try std.testing.expect((try i16_gt(runtime.context(), .nil, .nil, &.{ .i16(4), .i16(3) })).obj.toBool());
    const res5 = try i16_min(runtime.context(), .nil, .nil, &.{ .i16(2), .i16(5) });
    try std.testing.expectEqual(@as(i16, 2), res5.obj.toInt(i16));
    try std.testing.expectEqual(
        @as(i16, -3),
        (try i16_neg(runtime.context(), .nil, .nil, &.{.i16(3)})).obj.toInt(i16),
    );
    try std.testing.expectEqual(
        @as(i16, 3),
        (try i16_abs(runtime.context(), .nil, .nil, &.{.i16(-3)})).obj.toInt(i16),
    );
    try std.testing.expectEqual(
        @as(i16, 1),
        (try i16_sign(runtime.context(), .nil, .nil, &.{.i16(5)})).obj.toInt(i16),
    );
    const res6 = try i16_rem(runtime.context(), .nil, .nil, &.{ .i16(7), .i16(3) });
    try std.testing.expectEqual(@as(i16, 1), res6.obj.toInt(i16));
    const res7 = try i16_mod(runtime.context(), .nil, .nil, &.{ .i16(-7), .i16(3) });
    try std.testing.expectEqual(@as(i16, 2), res7.obj.toInt(i16));
    const res8 = try i16_pow(runtime.context(), .nil, .nil, &.{ .i16(2), .i16(10) });
    try std.testing.expectEqual(@as(i16, 1024), res8.obj.toInt(i16));
    const res9 = try i16_clamp(runtime.context(), .nil, .nil, &.{ .i16(5), .i16(0), .i16(3) });
    try std.testing.expectEqual(@as(i16, 3), res9.obj.toInt(i16));
    try std.testing.expect((try i16_is_odd(runtime.context(), .nil, .nil, &.{.i16(5)})).obj.toBool());
    try std.testing.expect((try i16_is_even(runtime.context(), .nil, .nil, &.{.i16(4)})).obj.toBool());
    const res10 = try i16_shl(runtime.context(), .nil, .nil, &.{ .i16(1), .i16(3) });
    try std.testing.expectEqual(@as(i16, 8), res10.obj.toInt(i16));
    const res11 = try i16_shr(runtime.context(), .nil, .nil, &.{ .i16(16), .i16(3) });
    try std.testing.expectEqual(@as(i16, 2), res11.obj.toInt(i16));
    try std.testing.expectEqual(
        @as(i16, 3),
        (try i16_from_f64(runtime.context(), .nil, .nil, &.{.f64(3.14)})).obj.toInt(i16),
    );

    try std.testing.expectEqual(
        @as(i32, 5),
        (try i32_add(runtime.context(), .nil, .nil, &.{ .i32(2), .i32(3) })).obj.toInt(i32),
    );
    try std.testing.expectEqual(
        @as(i32, -1),
        (try i32_sub(runtime.context(), .nil, .nil, &.{ .i32(2), .i32(3) })).obj.toInt(i32),
    );
    try std.testing.expectEqual(
        @as(i32, 6),
        (try i32_mul(runtime.context(), .nil, .nil, &.{ .i32(2), .i32(3) })).obj.toInt(i32),
    );
    try std.testing.expectEqual(
        @as(i32, 2),
        (try i32_div(runtime.context(), .nil, .nil, &.{ .i32(7), .i32(3) })).obj.toInt(i32),
    );
    try std.testing.expectEqual(
        @as(i32, 1),
        (try i32_rem(runtime.context(), .nil, .nil, &.{ .i32(7), .i32(3) })).obj.toInt(i32),
    );
    try std.testing.expectEqual(
        @as(i32, 3),
        (try i32_clamp(runtime.context(), .nil, .nil, &.{ .i32(5), .i32(0), .i32(3) })).obj.toInt(i32),
    );
    try std.testing.expectEqual(
        @as(i32, 3),
        (try i32_from_f64(runtime.context(), .nil, .nil, &.{.f64(3.14)})).obj.toInt(i32),
    );

    try std.testing.expectEqual(
        @as(u16, 5),
        (try u16_add(runtime.context(), .nil, .nil, &.{ .u16(2), .u16(3) })).obj.toInt(u16),
    );
    try std.testing.expectEqual(
        @as(u16, 6),
        (try u16_mul(runtime.context(), .nil, .nil, &.{ .u16(2), .u16(3) })).obj.toInt(u16),
    );
    try std.testing.expectEqual(
        @as(u16, 1),
        (try u16_rem(runtime.context(), .nil, .nil, &.{ .u16(7), .u16(3) })).obj.toInt(u16),
    );
    try std.testing.expectEqual(
        @as(u16, 3),
        (try u16_clamp(runtime.context(), .nil, .nil, &.{ .u16(5), .u16(0), .u16(3) })).obj.toInt(u16),
    );
    try std.testing.expect((try u16_is_odd(runtime.context(), .nil, .nil, &.{.u16(5)})).obj.toBool());
    try std.testing.expect((try u16_is_even(runtime.context(), .nil, .nil, &.{.u16(4)})).obj.toBool());

    try std.testing.expectEqual(
        @as(u32, 5),
        (try u32_add(runtime.context(), .nil, .nil, &.{ .u32(2), .u32(3) })).obj.toInt(u32),
    );
    try std.testing.expectEqual(
        @as(u32, 6),
        (try u32_mul(runtime.context(), .nil, .nil, &.{ .u32(2), .u32(3) })).obj.toInt(u32),
    );
    try std.testing.expectEqual(
        @as(u32, 3),
        (try u32_from_f64(runtime.context(), .nil, .nil, &.{.f64(3.14)})).obj.toInt(u32),
    );

    try std.testing.expectEqual(
        @as(u8, 5),
        (try u8_add(runtime.context(), .nil, .nil, &.{ .u8(2), .u8(3) })).obj.toInt(u8),
    );
    try std.testing.expectEqual(
        @as(u8, 6),
        (try u8_mul(runtime.context(), .nil, .nil, &.{ .u8(2), .u8(3) })).obj.toInt(u8),
    );
    try std.testing.expectEqual(
        @as(u8, 3),
        (try u8_clamp(runtime.context(), .nil, .nil, &.{ .u8(5), .u8(0), .u8(3) })).obj.toInt(u8),
    );
}

// Integer type constructors: delegate to coerceBuiltin for any→int conversion
fn construct(comptime T: type, comptime type_obj: skript.Object) Func {
    return (struct {
        pub fn c(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
            if (args.len == 0) return switch (T) {
                i8 => Value.i8(0),
                i16 => Value.i16(0),
                i32 => Value.i32(0),
                i64 => Value.i64(0),
                u8 => Value.u8(0),
                u16 => Value.u16(0),
                u32 => Value.u32(0),
                u64 => Value.u64(0),
                else => return error.Unimplemented,
            };
            if (args.len != 1) return error.ArityMismatch;
            return intrin.coerceBuiltin(type_obj, rt.runtime, args[0]);
        }
    }).c;
}

pub const i64_construct = construct(i64, skript.builtins.type_i64);
pub const i32_construct = construct(i32, skript.builtins.type_i32);
pub const i16_construct = construct(i16, skript.builtins.type_i16);
pub const i8_construct = construct(i8, skript.builtins.type_i8);
pub const u64_construct = construct(u64, skript.builtins.type_u64);
pub const u32_construct = construct(u32, skript.builtins.type_u32);
pub const u16_construct = construct(u16, skript.builtins.type_u16);
pub const u8_construct = construct(u8, skript.builtins.type_u8);
