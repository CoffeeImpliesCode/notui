const std = @import("std");
const root = @import("root.zig");
const intrinsics_mod = @import("intrinsics/root.zig");
const ad_gradient = @import("intrinsics/ad_gradient.zig");
const autodiff_tree = @import("autodiff/tree.zig");
const autodiff_space = @import("autodiff/space.zig");
const autodiff_rules = @import("autodiff/rules.zig");
const autodiff_tensor = @import("autodiff/tensor.zig");
const Reader = @import("Reader.zig");
const Primitive = @import("primitive.zig");
const Value = root.Value;
const FuncPtr = root.FuncPtr;
const EvalContext = root.EvalContext;
const Allocator = std.mem.Allocator;
/// Canonical builtin primitive declarations. This row order derives dispatch
/// indices, primitive identities, stable names, and descriptor metadata.
const primitive_declarations = .{
    .{ "rgba", &intrinsics_mod.misc.rgba, meta_collection },
    .{ "is-instance-of?", &intrinsics_mod.isInstance, meta_pure_fixed },
    .{ "disasm!", &intrinsics_mod.disasm, meta_source },
    .{ "type", &intrinsics_mod.typeof, meta_type },
    .{ "is-core-type?", &intrinsics_mod.isCoreType, meta_pure_fixed },
    .{ "cons?", &intrinsics_mod.is_cons, meta_pure_fixed },
    .{ "closure?", &intrinsics_mod.is_closure, meta_pure_fixed },
    .{ "intrinsic?", &intrinsics_mod.is_intrinsic, meta_pure_fixed },
    .{ "ffifunc?", &intrinsics_mod.is_ffifunc, meta_pure_fixed },
    .{ "method?", &intrinsics_mod.is_method, meta_pure_fixed },
    .{ "namespace?", &intrinsics_mod.is_namespace, meta_pure_fixed },
    .{ "number?", &intrinsics_mod.is_number, meta_pure_fixed },
    .{ "real?", &intrinsics_mod.is_real, meta_pure_fixed },
    .{ "int?", &intrinsics_mod.is_int, meta_pure_fixed },
    .{ "float?", &intrinsics_mod.is_float, meta_pure_fixed },
    .{ "complex?", &intrinsics_mod.is_complex, meta_pure_fixed },
    .{ "dynamic-library:open", &intrinsics_mod.dynlib.open, meta_dynamic_loader },
    .{ "dynamic-library:close", &intrinsics_mod.dynlib.close, meta_dynamic_loader },
    .{ "dynamic-library:lookup", &intrinsics_mod.dynlib.lookup, meta_dynamic_loader },
    .{ "ffi:make-func", &intrinsics_mod.ffi.makeFunc, meta_ffi },
    .{ "read", &Reader.readIntrinsic, meta_read },
    .{ "source-location", &Reader.sourceLocationIntrinsic, meta_source },
    .{ "source-span", &Reader.sourceSpanIntrinsic, meta_source },
    .{ "bool.and", &intrinsics_mod.bool.boolean_and, meta_pure_fixed },
    .{ "bool.or", &intrinsics_mod.bool.boolean_or, meta_pure_fixed },
    .{ "bool.not", &intrinsics_mod.bool.boolean_not, meta_pure_fixed },
    .{ "f16.add", &intrinsics_mod.float.f16_add, meta_numeric_native },
    .{ "f16.sub", &intrinsics_mod.float.f16_sub, meta_numeric_native },
    .{ "f16.mul", &intrinsics_mod.float.f16_mul, meta_numeric_native },
    .{ "f16.div", &intrinsics_mod.float.f16_div, meta_numeric_native },
    .{ "f16.sin", &intrinsics_mod.float.f16_sin, meta_numeric_native },
    .{ "f16.cos", &intrinsics_mod.float.f16_cos, meta_numeric_native },
    .{ "f16.tan", &intrinsics_mod.float.f16_tan, meta_numeric_native },
    .{ "f16.sinh", &intrinsics_mod.float.f16_sinh, meta_numeric_native },
    .{ "f16.cosh", &intrinsics_mod.float.f16_cosh, meta_numeric_native },
    .{ "f16.tanh", &intrinsics_mod.float.f16_tanh, meta_numeric_native },
    .{ "f16.asinh", &intrinsics_mod.float.f16_asinh, meta_numeric_native },
    .{ "f16.acosh", &intrinsics_mod.float.f16_acosh, meta_numeric_native },
    .{ "f16.atanh", &intrinsics_mod.float.f16_atanh, meta_numeric_native },
    .{ "f16.asin", &intrinsics_mod.float.f16_asin, meta_numeric_native },
    .{ "f16.acos", &intrinsics_mod.float.f16_acos, meta_numeric_native },
    .{ "f16.atan", &intrinsics_mod.float.f16_atan, meta_numeric_native },
    .{ "f16.atan2", &intrinsics_mod.float.f16_atan2, meta_numeric_native },
    .{ "f16.approx?", &intrinsics_mod.float.f16_approx, meta_numeric_native },
    .{ "f16.sqrt", &intrinsics_mod.float.f16_sqrt, meta_numeric_native },
    .{ "f16.exp", &intrinsics_mod.float.f16_exp, meta_numeric_native },
    .{ "f16.log", &intrinsics_mod.float.f16_log, meta_numeric_native },
    .{ "f16.log2", &intrinsics_mod.float.f16_log2, meta_numeric_native },
    .{ "f16.log10", &intrinsics_mod.float.f16_log10, meta_numeric_native },
    .{ "f16.pow", &intrinsics_mod.float.f16_pow, meta_numeric_native },
    .{ "f16.hypot", &intrinsics_mod.float.f16_hypot, meta_numeric_native },
    .{ "f16.floor", &intrinsics_mod.float.f16_floor, meta_numeric_native },
    .{ "f16.ceil", &intrinsics_mod.float.f16_ceil, meta_numeric_native },
    .{ "f16.round", &intrinsics_mod.float.f16_round, meta_numeric_native },
    .{ "f16.trunc", &intrinsics_mod.float.f16_trunc, meta_numeric_native },
    .{ "f16.abs", &intrinsics_mod.float.f16_abs, meta_numeric_native },
    .{ "f16.neg", &intrinsics_mod.float.f16_neg, meta_numeric_native },
    .{ "f16.min", &intrinsics_mod.float.f16_min, meta_numeric_native },
    .{ "f16.max", &intrinsics_mod.float.f16_max, meta_numeric_native },
    .{ "f16.sign", &intrinsics_mod.float.f16_sign, meta_numeric_native },
    .{ "f16.eq", &intrinsics_mod.float.f16_eq, meta_numeric_native },
    .{ "f16.ne", &intrinsics_mod.float.f16_ne, meta_numeric_native },
    .{ "f16.gt", &intrinsics_mod.float.f16_gt, meta_numeric_native },
    .{ "f16.lt", &intrinsics_mod.float.f16_lt, meta_numeric_native },
    .{ "f16.gte", &intrinsics_mod.float.f16_gte, meta_numeric_native },
    .{ "f16.lte", &intrinsics_mod.float.f16_lte, meta_numeric_native },
    .{ "f16.avg", &intrinsics_mod.float.f16_avg, meta_numeric_avg },
    .{ "f16.fract", &intrinsics_mod.float.f16_fract, meta_numeric_native },
    .{ "f16.mod", &intrinsics_mod.float.f16_mod, meta_numeric_native },
    .{ "f16.rem", &intrinsics_mod.float.f16_rem, meta_numeric_native },
    .{ "f16.clamp", &intrinsics_mod.float.f16_clamp, meta_numeric_native },
    .{ "f16.blend", &intrinsics_mod.float.f16_blend, meta_numeric_native },
    .{ "f16.unblend", &intrinsics_mod.float.f16_unblend, meta_numeric_native },
    .{ "f16.remap", &intrinsics_mod.float.f16_remap, meta_numeric_native },
    .{ "f16.is-nan?", &intrinsics_mod.float.f16_is_nan, meta_numeric_native },
    .{ "f16.is-inf?", &intrinsics_mod.float.f16_is_inf, meta_numeric_native },
    .{ "f16.is-finite?", &intrinsics_mod.float.f16_is_finite, meta_numeric_native },
    .{ "f16.is-zero?", &intrinsics_mod.float.f16_is_zero, meta_numeric_native },
    .{ "f16.is-odd?", &intrinsics_mod.float.f16_is_odd, meta_numeric_native },
    .{ "f16.is-even?", &intrinsics_mod.float.f16_is_even, meta_numeric_native },
    .{ "f16.deg->rad", &intrinsics_mod.float.f16_deg_to_rad, meta_numeric_native },
    .{ "f16.rad->deg", &intrinsics_mod.float.f16_rad_to_deg, meta_numeric_native },
    .{ "f16.nextafter", &intrinsics_mod.float.f16_nextafter, meta_numeric_native },
    .{ "f16.prevbefore", &intrinsics_mod.float.f16_prevbefore, meta_numeric_native },
    .{ "f16.expm1", &intrinsics_mod.float.f16_expm1, meta_numeric_native },
    .{ "f16.log1p", &intrinsics_mod.float.f16_log1p, meta_numeric_native },
    .{ "f32.add", &intrinsics_mod.float.f32_add, meta_numeric_native },
    .{ "f32.sub", &intrinsics_mod.float.f32_sub, meta_numeric_native },
    .{ "f32.mul", &intrinsics_mod.float.f32_mul, meta_numeric_native },
    .{ "f32.div", &intrinsics_mod.float.f32_div, meta_numeric_native },
    .{ "f32.sin", &intrinsics_mod.float.f32_sin, meta_numeric_native },
    .{ "f32.cos", &intrinsics_mod.float.f32_cos, meta_numeric_native },
    .{ "f32.tan", &intrinsics_mod.float.f32_tan, meta_numeric_native },
    .{ "f32.sinh", &intrinsics_mod.float.f32_sinh, meta_numeric_native },
    .{ "f32.cosh", &intrinsics_mod.float.f32_cosh, meta_numeric_native },
    .{ "f32.tanh", &intrinsics_mod.float.f32_tanh, meta_numeric_native },
    .{ "f32.asinh", &intrinsics_mod.float.f32_asinh, meta_numeric_native },
    .{ "f32.acosh", &intrinsics_mod.float.f32_acosh, meta_numeric_native },
    .{ "f32.atanh", &intrinsics_mod.float.f32_atanh, meta_numeric_native },
    .{ "f32.asin", &intrinsics_mod.float.f32_asin, meta_numeric_native },
    .{ "f32.acos", &intrinsics_mod.float.f32_acos, meta_numeric_native },
    .{ "f32.atan", &intrinsics_mod.float.f32_atan, meta_numeric_native },
    .{ "f32.atan2", &intrinsics_mod.float.f32_atan2, meta_numeric_native },
    .{ "f32.approx?", &intrinsics_mod.float.f32_approx, meta_numeric_native },
    .{ "f32.sqrt", &intrinsics_mod.float.f32_sqrt, meta_numeric_native },
    .{ "f32.exp", &intrinsics_mod.float.f32_exp, meta_numeric_native },
    .{ "f32.log", &intrinsics_mod.float.f32_log, meta_numeric_native },
    .{ "f32.log2", &intrinsics_mod.float.f32_log2, meta_numeric_native },
    .{ "f32.log10", &intrinsics_mod.float.f32_log10, meta_numeric_native },
    .{ "f32.pow", &intrinsics_mod.float.f32_pow, meta_numeric_native },
    .{ "f32.hypot", &intrinsics_mod.float.f32_hypot, meta_numeric_native },
    .{ "f32.floor", &intrinsics_mod.float.f32_floor, meta_numeric_native },
    .{ "f32.ceil", &intrinsics_mod.float.f32_ceil, meta_numeric_native },
    .{ "f32.round", &intrinsics_mod.float.f32_round, meta_numeric_native },
    .{ "f32.trunc", &intrinsics_mod.float.f32_trunc, meta_numeric_native },
    .{ "f32.abs", &intrinsics_mod.float.f32_abs, meta_numeric_native },
    .{ "f32.neg", &intrinsics_mod.float.f32_neg, meta_numeric_native },
    .{ "f32.min", &intrinsics_mod.float.f32_min, meta_numeric_native },
    .{ "f32.max", &intrinsics_mod.float.f32_max, meta_numeric_native },
    .{ "f32.sign", &intrinsics_mod.float.f32_sign, meta_numeric_native },
    .{ "f32.eq", &intrinsics_mod.float.f32_eq, meta_numeric_native },
    .{ "f32.ne", &intrinsics_mod.float.f32_ne, meta_numeric_native },
    .{ "f32.gt", &intrinsics_mod.float.f32_gt, meta_numeric_native },
    .{ "f32.lt", &intrinsics_mod.float.f32_lt, meta_numeric_native },
    .{ "f32.gte", &intrinsics_mod.float.f32_gte, meta_numeric_native },
    .{ "f32.lte", &intrinsics_mod.float.f32_lte, meta_numeric_native },
    .{ "f32.avg", &intrinsics_mod.float.f32_avg, meta_numeric_avg },
    .{ "f32.fract", &intrinsics_mod.float.f32_fract, meta_numeric_native },
    .{ "f32.mod", &intrinsics_mod.float.f32_mod, meta_numeric_native },
    .{ "f32.rem", &intrinsics_mod.float.f32_rem, meta_numeric_native },
    .{ "f32.clamp", &intrinsics_mod.float.f32_clamp, meta_numeric_native },
    .{ "f32.blend", &intrinsics_mod.float.f32_blend, meta_numeric_native },
    .{ "f32.unblend", &intrinsics_mod.float.f32_unblend, meta_numeric_native },
    .{ "f32.remap", &intrinsics_mod.float.f32_remap, meta_numeric_native },
    .{ "f32.is-nan?", &intrinsics_mod.float.f32_is_nan, meta_numeric_native },
    .{ "f32.is-inf?", &intrinsics_mod.float.f32_is_inf, meta_numeric_native },
    .{ "f32.is-finite?", &intrinsics_mod.float.f32_is_finite, meta_numeric_native },
    .{ "f32.is-zero?", &intrinsics_mod.float.f32_is_zero, meta_numeric_native },
    .{ "f32.is-odd?", &intrinsics_mod.float.f32_is_odd, meta_numeric_native },
    .{ "f32.is-even?", &intrinsics_mod.float.f32_is_even, meta_numeric_native },
    .{ "f32.deg->rad", &intrinsics_mod.float.f32_deg_to_rad, meta_numeric_native },
    .{ "f32.rad->deg", &intrinsics_mod.float.f32_rad_to_deg, meta_numeric_native },
    .{ "f32.nextafter", &intrinsics_mod.float.f32_nextafter, meta_numeric_native },
    .{ "f32.prevbefore", &intrinsics_mod.float.f32_prevbefore, meta_numeric_native },
    .{ "f32.expm1", &intrinsics_mod.float.f32_expm1, meta_numeric_native },
    .{ "f32.log1p", &intrinsics_mod.float.f32_log1p, meta_numeric_native },
    .{ "f64.add", &intrinsics_mod.float.f64_add, meta_numeric_native },
    .{ "f64.sub", &intrinsics_mod.float.f64_sub, meta_numeric_native },
    .{ "f64.mul", &intrinsics_mod.float.f64_mul, meta_numeric_native },
    .{ "f64.div", &intrinsics_mod.float.f64_div, meta_numeric_native },
    .{ "f64.sin", &intrinsics_mod.float.f64_sin, meta_numeric_native },
    .{ "f64.cos", &intrinsics_mod.float.f64_cos, meta_numeric_native },
    .{ "f64.tan", &intrinsics_mod.float.f64_tan, meta_numeric_native },
    .{ "f64.sinh", &intrinsics_mod.float.f64_sinh, meta_numeric_native },
    .{ "f64.cosh", &intrinsics_mod.float.f64_cosh, meta_numeric_native },
    .{ "f64.tanh", &intrinsics_mod.float.f64_tanh, meta_numeric_native },
    .{ "f64.asinh", &intrinsics_mod.float.f64_asinh, meta_numeric_native },
    .{ "f64.acosh", &intrinsics_mod.float.f64_acosh, meta_numeric_native },
    .{ "f64.atanh", &intrinsics_mod.float.f64_atanh, meta_numeric_native },
    .{ "f64.asin", &intrinsics_mod.float.f64_asin, meta_numeric_native },
    .{ "f64.acos", &intrinsics_mod.float.f64_acos, meta_numeric_native },
    .{ "f64.atan", &intrinsics_mod.float.f64_atan, meta_numeric_native },
    .{ "f64.atan2", &intrinsics_mod.float.f64_atan2, meta_numeric_native },
    .{ "f64.approx?", &intrinsics_mod.float.f64_approx, meta_numeric_native },
    .{ "f64.sqrt", &intrinsics_mod.float.f64_sqrt, meta_numeric_native },
    .{ "f64.exp", &intrinsics_mod.float.f64_exp, meta_numeric_native },
    .{ "f64.log", &intrinsics_mod.float.f64_log, meta_numeric_native },
    .{ "f64.log2", &intrinsics_mod.float.f64_log2, meta_numeric_native },
    .{ "f64.log10", &intrinsics_mod.float.f64_log10, meta_numeric_native },
    .{ "f64.pow", &intrinsics_mod.float.f64_pow, meta_numeric_native },
    .{ "f64.hypot", &intrinsics_mod.float.f64_hypot, meta_numeric_native },
    .{ "f64.floor", &intrinsics_mod.float.f64_floor, meta_numeric_native },
    .{ "f64.ceil", &intrinsics_mod.float.f64_ceil, meta_numeric_native },
    .{ "f64.round", &intrinsics_mod.float.f64_round, meta_numeric_native },
    .{ "f64.trunc", &intrinsics_mod.float.f64_trunc, meta_numeric_native },
    .{ "f64.abs", &intrinsics_mod.float.f64_abs, meta_numeric_native },
    .{ "f64.neg", &intrinsics_mod.float.f64_neg, meta_numeric_native },
    .{ "f64.min", &intrinsics_mod.float.f64_min, meta_numeric_native },
    .{ "f64.max", &intrinsics_mod.float.f64_max, meta_numeric_native },
    .{ "f64.sign", &intrinsics_mod.float.f64_sign, meta_numeric_native },
    .{ "f64.eq", &intrinsics_mod.float.f64_eq, meta_numeric_native },
    .{ "f64.ne", &intrinsics_mod.float.f64_ne, meta_numeric_native },
    .{ "f64.gt", &intrinsics_mod.float.f64_gt, meta_numeric_native },
    .{ "f64.lt", &intrinsics_mod.float.f64_lt, meta_numeric_native },
    .{ "f64.gte", &intrinsics_mod.float.f64_gte, meta_numeric_native },
    .{ "f64.lte", &intrinsics_mod.float.f64_lte, meta_numeric_native },
    .{ "f64.avg", &intrinsics_mod.float.f64_avg, meta_numeric_avg },
    .{ "f64.fract", &intrinsics_mod.float.f64_fract, meta_numeric_native },
    .{ "f64.mod", &intrinsics_mod.float.f64_mod, meta_numeric_native },
    .{ "f64.rem", &intrinsics_mod.float.f64_rem, meta_numeric_native },
    .{ "f64.clamp", &intrinsics_mod.float.f64_clamp, meta_numeric_native },
    .{ "f64.blend", &intrinsics_mod.float.f64_blend, meta_numeric_native },
    .{ "f64.unblend", &intrinsics_mod.float.f64_unblend, meta_numeric_native },
    .{ "f64.remap", &intrinsics_mod.float.f64_remap, meta_numeric_native },
    .{ "f64.is-nan?", &intrinsics_mod.float.f64_is_nan, meta_numeric_native },
    .{ "f64.is-inf?", &intrinsics_mod.float.f64_is_inf, meta_numeric_native },
    .{ "f64.is-finite?", &intrinsics_mod.float.f64_is_finite, meta_numeric_native },
    .{ "f64.is-zero?", &intrinsics_mod.float.f64_is_zero, meta_numeric_native },
    .{ "f64.is-odd?", &intrinsics_mod.float.f64_is_odd, meta_numeric_native },
    .{ "f64.is-even?", &intrinsics_mod.float.f64_is_even, meta_numeric_native },
    .{ "f64.deg->rad", &intrinsics_mod.float.f64_deg_to_rad, meta_numeric_native },
    .{ "f64.rad->deg", &intrinsics_mod.float.f64_rad_to_deg, meta_numeric_native },
    .{ "f64.nextafter", &intrinsics_mod.float.f64_nextafter, meta_numeric_native },
    .{ "f64.prevbefore", &intrinsics_mod.float.f64_prevbefore, meta_numeric_native },
    .{ "f64.expm1", &intrinsics_mod.float.f64_expm1, meta_numeric_native },
    .{ "f64.log1p", &intrinsics_mod.float.f64_log1p, meta_numeric_native },
    .{ "i64.add", &intrinsics_mod.int.i64_add, meta_pure_fixed },
    .{ "i64.sub", &intrinsics_mod.int.i64_sub, meta_pure_fixed },
    .{ "i64.mul", &intrinsics_mod.int.i64_mul, meta_pure_fixed },
    .{ "i64.div", &intrinsics_mod.int.i64_div, meta_pure_fixed },
    .{ "i64.eq", &intrinsics_mod.int.i64_eq, meta_pure_fixed },
    .{ "i64.ne", &intrinsics_mod.int.i64_ne, meta_pure_fixed },
    .{ "i64.gt", &intrinsics_mod.int.i64_gt, meta_pure_fixed },
    .{ "i64.lt", &intrinsics_mod.int.i64_lt, meta_pure_fixed },
    .{ "i64.gte", &intrinsics_mod.int.i64_gte, meta_pure_fixed },
    .{ "i64.lte", &intrinsics_mod.int.i64_lte, meta_pure_fixed },
    .{ "i64.min", &intrinsics_mod.int.i64_min, meta_pure_fixed },
    .{ "i64.max", &intrinsics_mod.int.i64_max, meta_pure_fixed },
    .{ "i64.neg", &intrinsics_mod.int.i64_neg, meta_pure_fixed },
    .{ "i64.abs", &intrinsics_mod.int.i64_abs, meta_pure_fixed },
    .{ "i64.sign", &intrinsics_mod.int.i64_sign, meta_pure_fixed },
    .{ "i64.rem", &intrinsics_mod.int.i64_rem, meta_pure_fixed },
    .{ "i64.mod", &intrinsics_mod.int.i64_mod, meta_pure_fixed },
    .{ "i64.pow", &intrinsics_mod.int.i64_pow, meta_int_pow },
    .{ "i64.shl", &intrinsics_mod.int.i64_shl, meta_pure_fixed },
    .{ "i64.shr", &intrinsics_mod.int.i64_shr, meta_pure_fixed },
    .{ "i64.clamp", &intrinsics_mod.int.i64_clamp, meta_pure_fixed },
    .{ "i64.from-f64", &intrinsics_mod.int.i64_from_f64, meta_pure_fixed },
    .{ "i64.from-f32", &intrinsics_mod.int.i64_from_f32, meta_pure_fixed },
    .{ "i64.from-f16", &intrinsics_mod.int.i64_from_f16, meta_pure_fixed },
    .{ "i64.is-odd?", &intrinsics_mod.int.i64_is_odd, meta_pure_fixed },
    .{ "i64.is-even?", &intrinsics_mod.int.i64_is_even, meta_pure_fixed },
    .{ "i8.add", &intrinsics_mod.int.i8_add, meta_pure_fixed },
    .{ "i8.sub", &intrinsics_mod.int.i8_sub, meta_pure_fixed },
    .{ "i8.mul", &intrinsics_mod.int.i8_mul, meta_pure_fixed },
    .{ "i8.div", &intrinsics_mod.int.i8_div, meta_pure_fixed },
    .{ "i8.eq", &intrinsics_mod.int.i8_eq, meta_pure_fixed },
    .{ "i8.ne", &intrinsics_mod.int.i8_ne, meta_pure_fixed },
    .{ "i8.gt", &intrinsics_mod.int.i8_gt, meta_pure_fixed },
    .{ "i8.lt", &intrinsics_mod.int.i8_lt, meta_pure_fixed },
    .{ "i8.gte", &intrinsics_mod.int.i8_gte, meta_pure_fixed },
    .{ "i8.lte", &intrinsics_mod.int.i8_lte, meta_pure_fixed },
    .{ "i8.min", &intrinsics_mod.int.i8_min, meta_pure_fixed },
    .{ "i8.max", &intrinsics_mod.int.i8_max, meta_pure_fixed },
    .{ "i8.neg", &intrinsics_mod.int.i8_neg, meta_pure_fixed },
    .{ "i8.abs", &intrinsics_mod.int.i8_abs, meta_pure_fixed },
    .{ "i8.sign", &intrinsics_mod.int.i8_sign, meta_pure_fixed },
    .{ "i8.rem", &intrinsics_mod.int.i8_rem, meta_pure_fixed },
    .{ "i8.mod", &intrinsics_mod.int.i8_mod, meta_pure_fixed },
    .{ "i8.pow", &intrinsics_mod.int.i8_pow, meta_int_pow },
    .{ "i8.shl", &intrinsics_mod.int.i8_shl, meta_pure_fixed },
    .{ "i8.shr", &intrinsics_mod.int.i8_shr, meta_pure_fixed },
    .{ "i8.clamp", &intrinsics_mod.int.i8_clamp, meta_pure_fixed },
    .{ "i8.from-f64", &intrinsics_mod.int.i8_from_f64, meta_pure_fixed },
    .{ "i8.from-f32", &intrinsics_mod.int.i8_from_f32, meta_pure_fixed },
    .{ "i8.from-f16", &intrinsics_mod.int.i8_from_f16, meta_pure_fixed },
    .{ "i8.is-odd?", &intrinsics_mod.int.i8_is_odd, meta_pure_fixed },
    .{ "i8.is-even?", &intrinsics_mod.int.i8_is_even, meta_pure_fixed },
    .{ "i16.add", &intrinsics_mod.int.i16_add, meta_pure_fixed },
    .{ "i16.sub", &intrinsics_mod.int.i16_sub, meta_pure_fixed },
    .{ "i16.mul", &intrinsics_mod.int.i16_mul, meta_pure_fixed },
    .{ "i16.div", &intrinsics_mod.int.i16_div, meta_pure_fixed },
    .{ "i16.eq", &intrinsics_mod.int.i16_eq, meta_pure_fixed },
    .{ "i16.ne", &intrinsics_mod.int.i16_ne, meta_pure_fixed },
    .{ "i16.gt", &intrinsics_mod.int.i16_gt, meta_pure_fixed },
    .{ "i16.lt", &intrinsics_mod.int.i16_lt, meta_pure_fixed },
    .{ "i16.gte", &intrinsics_mod.int.i16_gte, meta_pure_fixed },
    .{ "i16.lte", &intrinsics_mod.int.i16_lte, meta_pure_fixed },
    .{ "i16.min", &intrinsics_mod.int.i16_min, meta_pure_fixed },
    .{ "i16.max", &intrinsics_mod.int.i16_max, meta_pure_fixed },
    .{ "i16.neg", &intrinsics_mod.int.i16_neg, meta_pure_fixed },
    .{ "i16.abs", &intrinsics_mod.int.i16_abs, meta_pure_fixed },
    .{ "i16.sign", &intrinsics_mod.int.i16_sign, meta_pure_fixed },
    .{ "i16.rem", &intrinsics_mod.int.i16_rem, meta_pure_fixed },
    .{ "i16.mod", &intrinsics_mod.int.i16_mod, meta_pure_fixed },
    .{ "i16.pow", &intrinsics_mod.int.i16_pow, meta_int_pow },
    .{ "i16.shl", &intrinsics_mod.int.i16_shl, meta_pure_fixed },
    .{ "i16.shr", &intrinsics_mod.int.i16_shr, meta_pure_fixed },
    .{ "i16.clamp", &intrinsics_mod.int.i16_clamp, meta_pure_fixed },
    .{ "i16.from-f64", &intrinsics_mod.int.i16_from_f64, meta_pure_fixed },
    .{ "i16.from-f32", &intrinsics_mod.int.i16_from_f32, meta_pure_fixed },
    .{ "i16.from-f16", &intrinsics_mod.int.i16_from_f16, meta_pure_fixed },
    .{ "i16.is-odd?", &intrinsics_mod.int.i16_is_odd, meta_pure_fixed },
    .{ "i16.is-even?", &intrinsics_mod.int.i16_is_even, meta_pure_fixed },
    .{ "i32.add", &intrinsics_mod.int.i32_add, meta_pure_fixed },
    .{ "i32.sub", &intrinsics_mod.int.i32_sub, meta_pure_fixed },
    .{ "i32.mul", &intrinsics_mod.int.i32_mul, meta_pure_fixed },
    .{ "i32.div", &intrinsics_mod.int.i32_div, meta_pure_fixed },
    .{ "i32.eq", &intrinsics_mod.int.i32_eq, meta_pure_fixed },
    .{ "i32.ne", &intrinsics_mod.int.i32_ne, meta_pure_fixed },
    .{ "i32.gt", &intrinsics_mod.int.i32_gt, meta_pure_fixed },
    .{ "i32.lt", &intrinsics_mod.int.i32_lt, meta_pure_fixed },
    .{ "i32.gte", &intrinsics_mod.int.i32_gte, meta_pure_fixed },
    .{ "i32.lte", &intrinsics_mod.int.i32_lte, meta_pure_fixed },
    .{ "i32.min", &intrinsics_mod.int.i32_min, meta_pure_fixed },
    .{ "i32.max", &intrinsics_mod.int.i32_max, meta_pure_fixed },
    .{ "i32.neg", &intrinsics_mod.int.i32_neg, meta_pure_fixed },
    .{ "i32.abs", &intrinsics_mod.int.i32_abs, meta_pure_fixed },
    .{ "i32.sign", &intrinsics_mod.int.i32_sign, meta_pure_fixed },
    .{ "i32.rem", &intrinsics_mod.int.i32_rem, meta_pure_fixed },
    .{ "i32.mod", &intrinsics_mod.int.i32_mod, meta_pure_fixed },
    .{ "i32.pow", &intrinsics_mod.int.i32_pow, meta_int_pow },
    .{ "i32.shl", &intrinsics_mod.int.i32_shl, meta_pure_fixed },
    .{ "i32.shr", &intrinsics_mod.int.i32_shr, meta_pure_fixed },
    .{ "i32.clamp", &intrinsics_mod.int.i32_clamp, meta_pure_fixed },
    .{ "i32.from-f64", &intrinsics_mod.int.i32_from_f64, meta_pure_fixed },
    .{ "i32.from-f32", &intrinsics_mod.int.i32_from_f32, meta_pure_fixed },
    .{ "i32.from-f16", &intrinsics_mod.int.i32_from_f16, meta_pure_fixed },
    .{ "i32.is-odd?", &intrinsics_mod.int.i32_is_odd, meta_pure_fixed },
    .{ "i32.is-even?", &intrinsics_mod.int.i32_is_even, meta_pure_fixed },
    .{ "u8.add", &intrinsics_mod.int.u8_add, meta_pure_fixed },
    .{ "u8.sub", &intrinsics_mod.int.u8_sub, meta_pure_fixed },
    .{ "u8.mul", &intrinsics_mod.int.u8_mul, meta_pure_fixed },
    .{ "u8.div", &intrinsics_mod.int.u8_div, meta_pure_fixed },
    .{ "u8.eq", &intrinsics_mod.int.u8_eq, meta_pure_fixed },
    .{ "u8.ne", &intrinsics_mod.int.u8_ne, meta_pure_fixed },
    .{ "u8.gt", &intrinsics_mod.int.u8_gt, meta_pure_fixed },
    .{ "u8.lt", &intrinsics_mod.int.u8_lt, meta_pure_fixed },
    .{ "u8.gte", &intrinsics_mod.int.u8_gte, meta_pure_fixed },
    .{ "u8.lte", &intrinsics_mod.int.u8_lte, meta_pure_fixed },
    .{ "u8.min", &intrinsics_mod.int.u8_min, meta_pure_fixed },
    .{ "u8.max", &intrinsics_mod.int.u8_max, meta_pure_fixed },
    .{ "u8.neg", &intrinsics_mod.int.u8_neg, meta_pure_fixed },
    .{ "u8.abs", &intrinsics_mod.int.u8_abs, meta_pure_fixed },
    .{ "u8.sign", &intrinsics_mod.int.u8_sign, meta_pure_fixed },
    .{ "u8.rem", &intrinsics_mod.int.u8_rem, meta_pure_fixed },
    .{ "u8.mod", &intrinsics_mod.int.u8_mod, meta_pure_fixed },
    .{ "u8.pow", &intrinsics_mod.int.u8_pow, meta_int_pow },
    .{ "u8.shl", &intrinsics_mod.int.u8_shl, meta_pure_fixed },
    .{ "u8.shr", &intrinsics_mod.int.u8_shr, meta_pure_fixed },
    .{ "u8.clamp", &intrinsics_mod.int.u8_clamp, meta_pure_fixed },
    .{ "u8.from-f64", &intrinsics_mod.int.u8_from_f64, meta_pure_fixed },
    .{ "u8.from-f32", &intrinsics_mod.int.u8_from_f32, meta_pure_fixed },
    .{ "u8.from-f16", &intrinsics_mod.int.u8_from_f16, meta_pure_fixed },
    .{ "u8.is-odd?", &intrinsics_mod.int.u8_is_odd, meta_pure_fixed },
    .{ "u8.is-even?", &intrinsics_mod.int.u8_is_even, meta_pure_fixed },
    .{ "u16.add", &intrinsics_mod.int.u16_add, meta_pure_fixed },
    .{ "u16.sub", &intrinsics_mod.int.u16_sub, meta_pure_fixed },
    .{ "u16.mul", &intrinsics_mod.int.u16_mul, meta_pure_fixed },
    .{ "u16.div", &intrinsics_mod.int.u16_div, meta_pure_fixed },
    .{ "u16.eq", &intrinsics_mod.int.u16_eq, meta_pure_fixed },
    .{ "u16.ne", &intrinsics_mod.int.u16_ne, meta_pure_fixed },
    .{ "u16.gt", &intrinsics_mod.int.u16_gt, meta_pure_fixed },
    .{ "u16.lt", &intrinsics_mod.int.u16_lt, meta_pure_fixed },
    .{ "u16.gte", &intrinsics_mod.int.u16_gte, meta_pure_fixed },
    .{ "u16.lte", &intrinsics_mod.int.u16_lte, meta_pure_fixed },
    .{ "u16.min", &intrinsics_mod.int.u16_min, meta_pure_fixed },
    .{ "u16.max", &intrinsics_mod.int.u16_max, meta_pure_fixed },
    .{ "u16.neg", &intrinsics_mod.int.u16_neg, meta_pure_fixed },
    .{ "u16.abs", &intrinsics_mod.int.u16_abs, meta_pure_fixed },
    .{ "u16.sign", &intrinsics_mod.int.u16_sign, meta_pure_fixed },
    .{ "u16.rem", &intrinsics_mod.int.u16_rem, meta_pure_fixed },
    .{ "u16.mod", &intrinsics_mod.int.u16_mod, meta_pure_fixed },
    .{ "u16.pow", &intrinsics_mod.int.u16_pow, meta_int_pow },
    .{ "u16.shl", &intrinsics_mod.int.u16_shl, meta_pure_fixed },
    .{ "u16.shr", &intrinsics_mod.int.u16_shr, meta_pure_fixed },
    .{ "u16.clamp", &intrinsics_mod.int.u16_clamp, meta_pure_fixed },
    .{ "u16.from-f64", &intrinsics_mod.int.u16_from_f64, meta_pure_fixed },
    .{ "u16.from-f32", &intrinsics_mod.int.u16_from_f32, meta_pure_fixed },
    .{ "u16.from-f16", &intrinsics_mod.int.u16_from_f16, meta_pure_fixed },
    .{ "u16.is-odd?", &intrinsics_mod.int.u16_is_odd, meta_pure_fixed },
    .{ "u16.is-even?", &intrinsics_mod.int.u16_is_even, meta_pure_fixed },
    .{ "u32.add", &intrinsics_mod.int.u32_add, meta_pure_fixed },
    .{ "u32.sub", &intrinsics_mod.int.u32_sub, meta_pure_fixed },
    .{ "u32.mul", &intrinsics_mod.int.u32_mul, meta_pure_fixed },
    .{ "u32.div", &intrinsics_mod.int.u32_div, meta_pure_fixed },
    .{ "u32.eq", &intrinsics_mod.int.u32_eq, meta_pure_fixed },
    .{ "u32.ne", &intrinsics_mod.int.u32_ne, meta_pure_fixed },
    .{ "u32.gt", &intrinsics_mod.int.u32_gt, meta_pure_fixed },
    .{ "u32.lt", &intrinsics_mod.int.u32_lt, meta_pure_fixed },
    .{ "u32.gte", &intrinsics_mod.int.u32_gte, meta_pure_fixed },
    .{ "u32.lte", &intrinsics_mod.int.u32_lte, meta_pure_fixed },
    .{ "u32.min", &intrinsics_mod.int.u32_min, meta_pure_fixed },
    .{ "u32.max", &intrinsics_mod.int.u32_max, meta_pure_fixed },
    .{ "u32.neg", &intrinsics_mod.int.u32_neg, meta_pure_fixed },
    .{ "u32.abs", &intrinsics_mod.int.u32_abs, meta_pure_fixed },
    .{ "u32.sign", &intrinsics_mod.int.u32_sign, meta_pure_fixed },
    .{ "u32.rem", &intrinsics_mod.int.u32_rem, meta_pure_fixed },
    .{ "u32.mod", &intrinsics_mod.int.u32_mod, meta_pure_fixed },
    .{ "u32.pow", &intrinsics_mod.int.u32_pow, meta_int_pow },
    .{ "u32.shl", &intrinsics_mod.int.u32_shl, meta_pure_fixed },
    .{ "u32.shr", &intrinsics_mod.int.u32_shr, meta_pure_fixed },
    .{ "u32.clamp", &intrinsics_mod.int.u32_clamp, meta_pure_fixed },
    .{ "u32.from-f64", &intrinsics_mod.int.u32_from_f64, meta_pure_fixed },
    .{ "u32.from-f32", &intrinsics_mod.int.u32_from_f32, meta_pure_fixed },
    .{ "u32.from-f16", &intrinsics_mod.int.u32_from_f16, meta_pure_fixed },
    .{ "u32.is-odd?", &intrinsics_mod.int.u32_is_odd, meta_pure_fixed },
    .{ "u32.is-even?", &intrinsics_mod.int.u32_is_even, meta_pure_fixed },
    .{ "u64.add", &intrinsics_mod.int.u64_add, meta_pure_fixed },
    .{ "u64.sub", &intrinsics_mod.int.u64_sub, meta_pure_fixed },
    .{ "u64.mul", &intrinsics_mod.int.u64_mul, meta_pure_fixed },
    .{ "u64.div", &intrinsics_mod.int.u64_div, meta_pure_fixed },
    .{ "u64.eq", &intrinsics_mod.int.u64_eq, meta_pure_fixed },
    .{ "u64.ne", &intrinsics_mod.int.u64_ne, meta_pure_fixed },
    .{ "u64.gt", &intrinsics_mod.int.u64_gt, meta_pure_fixed },
    .{ "u64.lt", &intrinsics_mod.int.u64_lt, meta_pure_fixed },
    .{ "u64.gte", &intrinsics_mod.int.u64_gte, meta_pure_fixed },
    .{ "u64.lte", &intrinsics_mod.int.u64_lte, meta_pure_fixed },
    .{ "u64.min", &intrinsics_mod.int.u64_min, meta_pure_fixed },
    .{ "u64.max", &intrinsics_mod.int.u64_max, meta_pure_fixed },
    .{ "u64.neg", &intrinsics_mod.int.u64_neg, meta_pure_fixed },
    .{ "u64.abs", &intrinsics_mod.int.u64_abs, meta_pure_fixed },
    .{ "u64.sign", &intrinsics_mod.int.u64_sign, meta_pure_fixed },
    .{ "u64.rem", &intrinsics_mod.int.u64_rem, meta_pure_fixed },
    .{ "u64.mod", &intrinsics_mod.int.u64_mod, meta_pure_fixed },
    .{ "u64.pow", &intrinsics_mod.int.u64_pow, meta_int_pow },
    .{ "u64.shl", &intrinsics_mod.int.u64_shl, meta_pure_fixed },
    .{ "u64.shr", &intrinsics_mod.int.u64_shr, meta_pure_fixed },
    .{ "u64.clamp", &intrinsics_mod.int.u64_clamp, meta_pure_fixed },
    .{ "u64.from-f64", &intrinsics_mod.int.u64_from_f64, meta_pure_fixed },
    .{ "u64.from-f32", &intrinsics_mod.int.u64_from_f32, meta_pure_fixed },
    .{ "u64.from-f16", &intrinsics_mod.int.u64_from_f16, meta_pure_fixed },
    .{ "u64.is-odd?", &intrinsics_mod.int.u64_is_odd, meta_pure_fixed },
    .{ "u64.is-even?", &intrinsics_mod.int.u64_is_even, meta_pure_fixed },
    .{ "c16.cart", &intrinsics_mod.complex.c16Cart, meta_numeric_native },
    .{ "c16.re", &intrinsics_mod.complex.c16_re, meta_numeric_native },
    .{ "c16.im", &intrinsics_mod.complex.c16_im, meta_numeric_native },
    .{ "c32.cart", &intrinsics_mod.complex.c32Cart, meta_numeric_native },
    .{ "c32.re", &intrinsics_mod.complex.c32_re, meta_numeric_native },
    .{ "c32.im", &intrinsics_mod.complex.c32_im, meta_numeric_native },
    .{ "c64.cart", &intrinsics_mod.complex.c64Cart, meta_complex_alloc },
    .{ "c64.re", &intrinsics_mod.complex.c64_re, meta_complex_alloc },
    .{ "c64.im", &intrinsics_mod.complex.c64_im, meta_complex_alloc },
    .{ "c16.add", &intrinsics_mod.complex.c16_add, meta_numeric_native },
    .{ "c16.sub", &intrinsics_mod.complex.c16_sub, meta_numeric_native },
    .{ "c16.mul", &intrinsics_mod.complex.c16_mul, meta_numeric_native },
    .{ "c16.div", &intrinsics_mod.complex.c16_div, meta_numeric_native },
    .{ "c16.sin", &intrinsics_mod.complex.c16_sin, meta_numeric_native },
    .{ "c16.cos", &intrinsics_mod.complex.c16_cos, meta_numeric_native },
    .{ "c16.tan", &intrinsics_mod.complex.c16_tan, meta_numeric_native },
    .{ "c16.asin", &intrinsics_mod.complex.c16_asin, meta_numeric_native },
    .{ "c16.acos", &intrinsics_mod.complex.c16_acos, meta_numeric_native },
    .{ "c16.atan", &intrinsics_mod.complex.c16_atan, meta_numeric_native },
    .{ "c16.sinh", &intrinsics_mod.complex.c16_sinh, meta_numeric_native },
    .{ "c16.cosh", &intrinsics_mod.complex.c16_cosh, meta_numeric_native },
    .{ "c16.tanh", &intrinsics_mod.complex.c16_tanh, meta_numeric_native },
    .{ "c16.asinh", &intrinsics_mod.complex.c16_asinh, meta_numeric_native },
    .{ "c16.acosh", &intrinsics_mod.complex.c16_acosh, meta_numeric_native },
    .{ "c16.atanh", &intrinsics_mod.complex.c16_atanh, meta_numeric_native },
    .{ "c16.exp", &intrinsics_mod.complex.c16_exp, meta_numeric_native },
    .{ "c16.log", &intrinsics_mod.complex.c16_log, meta_numeric_native },
    .{ "c16.sqrt", &intrinsics_mod.complex.c16_sqrt, meta_numeric_native },
    .{ "c16.pow", &intrinsics_mod.complex.c16Pow, meta_numeric_native },
    .{ "c16.conj", &intrinsics_mod.complex.c16_conj, meta_numeric_native },
    .{ "c16.neg", &intrinsics_mod.complex.c16_neg, meta_numeric_native },
    .{ "c16.abs", &intrinsics_mod.complex.c16Abs, meta_numeric_native },
    .{ "c16.arg", &intrinsics_mod.complex.c16Arg, meta_numeric_native },
    .{ "c16.norm", &intrinsics_mod.complex.c16Norm, meta_numeric_native },
    .{ "c32.add", &intrinsics_mod.complex.c32_add, meta_numeric_native },
    .{ "c32.sub", &intrinsics_mod.complex.c32_sub, meta_numeric_native },
    .{ "c32.mul", &intrinsics_mod.complex.c32_mul, meta_numeric_native },
    .{ "c32.div", &intrinsics_mod.complex.c32_div, meta_numeric_native },
    .{ "c64.add", &intrinsics_mod.complex.c64_add, meta_complex_alloc },
    .{ "c64.sub", &intrinsics_mod.complex.c64_sub, meta_complex_alloc },
    .{ "c64.mul", &intrinsics_mod.complex.c64_mul, meta_complex_alloc },
    .{ "c64.div", &intrinsics_mod.complex.c64_div, meta_complex_alloc },
    .{ "c32.sin", &intrinsics_mod.complex.c32_sin, meta_numeric_native },
    .{ "c32.cos", &intrinsics_mod.complex.c32_cos, meta_numeric_native },
    .{ "c32.tan", &intrinsics_mod.complex.c32_tan, meta_numeric_native },
    .{ "c32.asin", &intrinsics_mod.complex.c32_asin, meta_numeric_native },
    .{ "c32.acos", &intrinsics_mod.complex.c32_acos, meta_numeric_native },
    .{ "c32.atan", &intrinsics_mod.complex.c32_atan, meta_numeric_native },
    .{ "c32.sinh", &intrinsics_mod.complex.c32_sinh, meta_numeric_native },
    .{ "c32.cosh", &intrinsics_mod.complex.c32_cosh, meta_numeric_native },
    .{ "c32.tanh", &intrinsics_mod.complex.c32_tanh, meta_numeric_native },
    .{ "c32.asinh", &intrinsics_mod.complex.c32_asinh, meta_numeric_native },
    .{ "c32.acosh", &intrinsics_mod.complex.c32_acosh, meta_numeric_native },
    .{ "c32.atanh", &intrinsics_mod.complex.c32_atanh, meta_numeric_native },
    .{ "c64.sin", &intrinsics_mod.complex.c64_sin, meta_complex_alloc },
    .{ "c64.cos", &intrinsics_mod.complex.c64_cos, meta_complex_alloc },
    .{ "c64.tan", &intrinsics_mod.complex.c64_tan, meta_complex_alloc },
    .{ "c64.asin", &intrinsics_mod.complex.c64_asin, meta_complex_alloc },
    .{ "c64.acos", &intrinsics_mod.complex.c64_acos, meta_complex_alloc },
    .{ "c64.atan", &intrinsics_mod.complex.c64_atan, meta_complex_alloc },
    .{ "c64.sinh", &intrinsics_mod.complex.c64_sinh, meta_complex_alloc },
    .{ "c64.cosh", &intrinsics_mod.complex.c64_cosh, meta_complex_alloc },
    .{ "c64.tanh", &intrinsics_mod.complex.c64_tanh, meta_complex_alloc },
    .{ "c64.asinh", &intrinsics_mod.complex.c64_asinh, meta_complex_alloc },
    .{ "c64.acosh", &intrinsics_mod.complex.c64_acosh, meta_complex_alloc },
    .{ "c64.atanh", &intrinsics_mod.complex.c64_atanh, meta_complex_alloc },
    .{ "c32.exp", &intrinsics_mod.complex.c32_exp, meta_numeric_native },
    .{ "c32.log", &intrinsics_mod.complex.c32_log, meta_numeric_native },
    .{ "c32.sqrt", &intrinsics_mod.complex.c32_sqrt, meta_numeric_native },
    .{ "c32.pow", &intrinsics_mod.complex.c32_pow, meta_numeric_native },
    .{ "c32.conj", &intrinsics_mod.complex.c32_conj, meta_numeric_native },
    .{ "c32.neg", &intrinsics_mod.complex.c32_neg, meta_numeric_native },
    .{ "c32.abs", &intrinsics_mod.complex.c32Abs, meta_numeric_native },
    .{ "c32.arg", &intrinsics_mod.complex.c32Arg, meta_numeric_native },
    .{ "c32.norm", &intrinsics_mod.complex.c32Norm, meta_numeric_native },
    .{ "c64.exp", &intrinsics_mod.complex.c64_exp, meta_complex_alloc },
    .{ "c64.log", &intrinsics_mod.complex.c64_log, meta_complex_alloc },
    .{ "c64.sqrt", &intrinsics_mod.complex.c64_sqrt, meta_complex_alloc },
    .{ "c64.pow", &intrinsics_mod.complex.c64_pow, meta_complex_alloc },
    .{ "c64.conj", &intrinsics_mod.complex.c64_conj, meta_complex_alloc },
    .{ "c64.neg", &intrinsics_mod.complex.c64_neg, meta_complex_alloc },
    .{ "c64.abs", &intrinsics_mod.complex.c64Abs, meta_complex_alloc },
    .{ "c64.arg", &intrinsics_mod.complex.c64Arg, meta_complex_alloc },
    .{ "c64.norm", &intrinsics_mod.complex.c64Norm, meta_complex_alloc },
    .{ "c16.fract", &intrinsics_mod.complex.c16_fract, meta_numeric_native },
    .{ "c16.mod", &intrinsics_mod.complex.c16_mod, meta_numeric_native },
    .{ "c16.rem", &intrinsics_mod.complex.c16_rem, meta_numeric_native },
    .{ "c16.clamp", &intrinsics_mod.complex.c16Clamp, meta_numeric_native },
    .{ "c16.blend", &intrinsics_mod.complex.c16Blend, meta_numeric_native },
    .{ "c16.unblend", &intrinsics_mod.complex.c16Unblend, meta_numeric_native },
    .{ "c16.remap", &intrinsics_mod.complex.c16Remap, meta_numeric_native },
    .{ "c16.mag", &intrinsics_mod.complex.c16Mag, meta_numeric_native },
    .{ "c16.polar", &intrinsics_mod.complex.c16Polar, meta_numeric_native },
    .{ "c16.expm1", &intrinsics_mod.complex.c16_expm1, meta_numeric_native },
    .{ "c16.log1p", &intrinsics_mod.complex.c16_log1p, meta_numeric_native },
    .{ "c32.fract", &intrinsics_mod.complex.c32_fract, meta_numeric_native },
    .{ "c32.mod", &intrinsics_mod.complex.c32_mod, meta_numeric_native },
    .{ "c32.rem", &intrinsics_mod.complex.c32_rem, meta_numeric_native },
    .{ "c32.clamp", &intrinsics_mod.complex.c32Clamp, meta_numeric_native },
    .{ "c32.blend", &intrinsics_mod.complex.c32Blend, meta_numeric_native },
    .{ "c32.unblend", &intrinsics_mod.complex.c32Unblend, meta_numeric_native },
    .{ "c32.remap", &intrinsics_mod.complex.c32Remap, meta_numeric_native },
    .{ "c32.mag", &intrinsics_mod.complex.c32Mag, meta_numeric_native },
    .{ "c32.polar", &intrinsics_mod.complex.c32Polar, meta_numeric_native },
    .{ "c32.expm1", &intrinsics_mod.complex.c32_expm1, meta_numeric_native },
    .{ "c32.log1p", &intrinsics_mod.complex.c32_log1p, meta_numeric_native },
    .{ "c64.fract", &intrinsics_mod.complex.c64_fract, meta_complex_alloc },
    .{ "c64.mod", &intrinsics_mod.complex.c64_mod, meta_complex_alloc },
    .{ "c64.rem", &intrinsics_mod.complex.c64_rem, meta_complex_alloc },
    .{ "c64.clamp", &intrinsics_mod.complex.c64Clamp, meta_complex_alloc },
    .{ "c64.blend", &intrinsics_mod.complex.c64Blend, meta_complex_alloc },
    .{ "c64.unblend", &intrinsics_mod.complex.c64Unblend, meta_complex_alloc },
    .{ "c64.remap", &intrinsics_mod.complex.c64Remap, meta_complex_alloc },
    .{ "c64.mag", &intrinsics_mod.complex.c64Mag, meta_complex_alloc },
    .{ "c64.polar", &intrinsics_mod.complex.c64Polar, meta_complex_alloc },
    .{ "c64.expm1", &intrinsics_mod.complex.c64_expm1, meta_complex_alloc },
    .{ "c64.log1p", &intrinsics_mod.complex.c64_log1p, meta_complex_alloc },
    .{ "c16.eq", &intrinsics_mod.complex.c16_eq, meta_numeric_native },
    .{ "c16.ne", &intrinsics_mod.complex.c16_ne, meta_numeric_native },
    .{ "c32.eq", &intrinsics_mod.complex.c32_eq, meta_numeric_native },
    .{ "c32.ne", &intrinsics_mod.complex.c32_ne, meta_numeric_native },
    .{ "c64.eq", &intrinsics_mod.complex.c64_eq, meta_complex_alloc },
    .{ "c64.ne", &intrinsics_mod.complex.c64_ne, meta_complex_alloc },
    .{ "c16.is-zero?", &intrinsics_mod.complex.c16_is_zero, meta_numeric_native },
    .{ "c16.is-nan?", &intrinsics_mod.complex.c16_is_nan, meta_numeric_native },
    .{ "c16.is-inf?", &intrinsics_mod.complex.c16_is_inf, meta_numeric_native },
    .{ "c16.is-finite?", &intrinsics_mod.complex.c16_is_finite, meta_numeric_native },
    .{ "c32.is-zero?", &intrinsics_mod.complex.c32_is_zero, meta_numeric_native },
    .{ "c32.is-nan?", &intrinsics_mod.complex.c32_is_nan, meta_numeric_native },
    .{ "c32.is-inf?", &intrinsics_mod.complex.c32_is_inf, meta_numeric_native },
    .{ "c32.is-finite?", &intrinsics_mod.complex.c32_is_finite, meta_numeric_native },
    .{ "c64.is-zero?", &intrinsics_mod.complex.c64_is_zero, meta_complex_alloc },
    .{ "c64.is-nan?", &intrinsics_mod.complex.c64_is_nan, meta_complex_alloc },
    .{ "c64.is-inf?", &intrinsics_mod.complex.c64_is_inf, meta_complex_alloc },
    .{ "c64.is-finite?", &intrinsics_mod.complex.c64_is_finite, meta_complex_alloc },
    .{ "write", &intrinsics_mod.print.write, meta_write },
    .{ "cons", &intrinsics_mod.list.cons, meta_collection },
    .{ "fst", &intrinsics_mod.list.fst, meta_collection },
    .{ "rst", &intrinsics_mod.list.rst, meta_collection },
    .{ "list", &intrinsics_mod.list.list, meta_collection },
    .{ "map", &intrinsics_mod.collections.map, meta_callback_last },
    .{ "hash-map", &intrinsics_mod.map.create, meta_collection },
    .{ "image", &intrinsics_mod.widget.image, meta_collection },
    .{ "video", &intrinsics_mod.widget.video, meta_collection },
    .{ "audio", &intrinsics_mod.widget.audio, meta_collection },
    .{ "map-get", &intrinsics_mod.map.get, meta_map_read },
    .{ "map-set!", &intrinsics_mod.map.set, meta_map_write },
    .{ "symbol", &intrinsics_mod.misc.makeSymbol, meta_symbol },
    .{ "symbol.eq", &intrinsics_mod.misc.symbolEq, meta_pure_fixed },
    .{ "symbol.ne", &intrinsics_mod.misc.symbolNe, meta_pure_fixed },
    .{ "keyword.eq", &intrinsics_mod.misc.keywordEq, meta_pure_fixed },
    .{ "keyword.ne", &intrinsics_mod.misc.keywordNe, meta_pure_fixed },
    .{ "method", &intrinsics_mod.method, meta_collection },
    .{ "instance", &intrinsics_mod.instance, meta_instance },
    .{ "lock-method", &intrinsics_mod.lockMethod, meta_instance },
    .{ "spawn", &intrinsics_mod.process.spawn, meta_spawn },
    .{ "send", &intrinsics_mod.process.send, meta_send },
    .{ "receive", &intrinsics_mod.process.receive, meta_receive },
    .{ "self", &intrinsics_mod.process.self, meta_process_read },
    .{ "alive?", &intrinsics_mod.process.@"alive?", meta_process_read },
    .{ "sleep", &intrinsics_mod.process.sleep, meta_sleep },
    .{ "process-info", &intrinsics_mod.process.processInfo, meta_process_info },
    .{ "exit-reason", &intrinsics_mod.process.exitReason, meta_process_read },
    .{ "timeout-sentinel", &intrinsics_mod.process.timeoutSentinel, meta_pure_fixed },
    .{ "pid.eq", &intrinsics_mod.process.pidEq, meta_pure_fixed },
    .{ "pid.ne", &intrinsics_mod.process.pidNe, meta_pure_fixed },
    .{ "load", &intrinsics_mod.modules.load, meta_load },
    .{ "evaluate", &intrinsics_mod.evaluator.evaluate, meta_evaluate },
    .{ "deriv", &intrinsics_mod.ad.deriv, meta_ad_deriv },
    .{ "jvp", &intrinsics_mod.ad.jvp, meta_ad_callback },
    .{ "gradient", &intrinsics_mod.ad.gradient, meta_ad_callback },
    .{ "value-and-gradient", &intrinsics_mod.ad.valueAndGradient, meta_ad_callback },
    .{ "linearize", &intrinsics_mod.ad_reverse.linearize, meta_ad_callback },
    .{ "transpose", &intrinsics_mod.ad_reverse.transpose, meta_ad_deriv },
    .{ "vjp", &intrinsics_mod.ad_reverse.vjp, meta_ad_callback },
    .{ "jacobian", &intrinsics_mod.ad_reverse.jacobian, meta_ad_callback },
    .{ "hvp", &intrinsics_mod.ad_reverse.hvp, meta_ad_callback },
    .{ "close-linear", &intrinsics_mod.ad_reverse.closeLinear, meta_ad_registration },
    .{ "symbolic-var", &intrinsics_mod.symbolic.symbolicVar, meta_ad_deriv },
    .{ "symbolic", &intrinsics_mod.symbolic.symbolic, meta_ad_callback },
    .{ "expr->datum", &intrinsics_mod.symbolic.exprToDatum, meta_ad_scalar },
    .{ "compile-expr", &intrinsics_mod.symbolic.compileExpr, meta_ad_deriv },
    .{ "expr-view", &intrinsics_mod.symbolic.exprView, meta_ad_scalar },
    .{ "close-expr", &intrinsics_mod.symbolic.closeExpr, meta_ad_registration },
    .{ "simplify-expr", &intrinsics_mod.symbolic.simplifyExpr, meta_ad_deriv },
    .{ "autodiff.register-tree", &autodiff_tree.registerTree, meta_ad_registration },
    .{ "autodiff.register-space", &autodiff_space.registerSpace, meta_ad_registration },
    .{ "autodiff.register-rule", &autodiff_rules.registerRule, meta_ad_registration },
    .{ "autodiff.scalar", &autodiff_rules.scalarDispatch, meta_ad_scalar },
    .{ "autodiff.hook-result", &autodiff_rules.checkHookResult, meta_ad_scalar },
    .{ "autodiff.tensor", &autodiff_tensor.dispatch, meta_ad_tensor },
    .{ "autodiff.tensor-nested", &autodiff_tensor.dispatchNested, meta_ad_tensor },
    .{ "autodiff.tensor-linear-apply", &root.autodiff_linearize.tensorLinearApply, meta_ad_scalar },
    .{ "autodiff.tensor-linear-transpose", &root.autodiff_linearize.tensorLinearTranspose, meta_ad_scalar },
    .{ "autodiff.runtime-owned-output", &root.autodiff_linearize.materializeOutput, meta_read },
    .{ "autodiff.cotangent-zero", &root.autodiff_linearize.cotangentZero, meta_ad_cotangent },
    .{ "autodiff.cotangent-add", &root.autodiff_linearize.cotangentAdd, meta_ad_cotangent },
    .{ "autodiff.scalar-adjoint", &root.autodiff_linearize.scalarAdjoint, meta_ad_cotangent },
    .{ "use-multi", &intrinsics_mod.modules.useMulti, meta_load },
    .{ "stack", &intrinsics_mod.tensor.create, meta_collection },
    .{ "tensor-shape", &intrinsics_mod.tensor.tensorShape, meta_collection },
    .{ "tensor-rank", &intrinsics_mod.tensor.tensorRank, meta_collection },
    .{ "tensor-len", &intrinsics_mod.tensor.tensorLen, meta_collection },
    .{ "tensor-get", &intrinsics_mod.tensor.tensorGet, meta_collection },
    .{ "tensor.eq", &intrinsics_mod.tensor.tensorEq, meta_collection },
    .{ "iota", &intrinsics_mod.tensor.iota, meta_collection },
    .{ "reshape", &intrinsics_mod.tensor.reshape, meta_collection },
    .{ "fold", &intrinsics_mod.collections.fold, meta_fold },
    .{ "scan", &intrinsics_mod.collections.scan, meta_callback_last },
    .{ "keep", &intrinsics_mod.collections.keep, meta_callback_last },
    .{ "uniq", &intrinsics_mod.tensor.uniq, meta_collection },
    .{ "where", &intrinsics_mod.tensor.where, meta_collection },
    .{ "diff", &intrinsics_mod.tensor.diff, meta_collection },
    .{ "flat", &intrinsics_mod.tensor.flat, meta_collection },
    .{ "trans", &intrinsics_mod.tensor.trans, meta_collection },
    .{ "chunk", &intrinsics_mod.tensor.chunk, meta_collection },
    .{ "part", &intrinsics_mod.tensor.part, meta_callback_last },
    .{ "take", &intrinsics_mod.collections.take, meta_collection },
    .{ "drop", &intrinsics_mod.collections.drop, meta_collection },
    .{ "cat", &intrinsics_mod.collections.concat, meta_collection },
    .{ "rev", &intrinsics_mod.collections.reverse, meta_collection },
    .{ "rot", &intrinsics_mod.tensor.rot, meta_collection },
    .{ "outer", &intrinsics_mod.tensor.outer, meta_callback_last },
    .{ "dot", &intrinsics_mod.tensor.dot, meta_collection },
    .{ "zip", &intrinsics_mod.tensor.zip, meta_collection },
    .{ "map2", &intrinsics_mod.tensor.map2, meta_callback_last },
    .{ "max", &intrinsics_mod.tensor.max, meta_collection },
    .{ "min", &intrinsics_mod.tensor.min, meta_collection },
    .{ "map-has?", &intrinsics_mod.map.has, meta_map_read },
    .{ "map-keys", &intrinsics_mod.map.keys, meta_map_read },
    .{ "map-vals", &intrinsics_mod.map.vals, meta_map_read },
    .{ "map-size", &intrinsics_mod.map.size, meta_map_read },
    .{ "concat", &intrinsics_mod.collections.concat, meta_collection },
    .{ "reverse", &intrinsics_mod.collections.reverse, meta_collection },
    .{ "length", &intrinsics_mod.list.length, meta_collection },
    .{ "range", &intrinsics_mod.list.range, meta_collection },
    .{ "contains?", &intrinsics_mod.list.contains, meta_collection },
    .{ "sort-up", &intrinsics_mod.list.sortUp, meta_collection },
    .{ "sort-dn", &intrinsics_mod.list.sortDn, meta_collection },
    .{ "string.append", &intrinsics_mod.string.append, meta_collection },
    .{ "string.length", &intrinsics_mod.string.length, meta_collection },
    .{ "string.eq", &intrinsics_mod.string.eq, meta_collection },
    .{ "string.ne", &intrinsics_mod.string.ne, meta_collection },
    .{ "string.lt", &intrinsics_mod.string.lt, meta_collection },
    .{ "string.gt", &intrinsics_mod.string.gt, meta_collection },
    .{ "string.lte", &intrinsics_mod.string.lte, meta_collection },
    .{ "string.gte", &intrinsics_mod.string.gte, meta_collection },
    .{ "string.upcase", &intrinsics_mod.string.upcase, meta_collection },
    .{ "string.downcase", &intrinsics_mod.string.downcase, meta_collection },
    .{ "string.find", &intrinsics_mod.string.find, meta_collection },
    .{ "string.replace", &intrinsics_mod.string.replace, meta_collection },
    .{ "string.split", &intrinsics_mod.string.split, meta_collection },
    .{ "string.join", &intrinsics_mod.string.join, meta_collection },
    .{ "string.trim", &intrinsics_mod.string.trim, meta_collection },
    .{ "string.trim-left", &intrinsics_mod.string.@"trim-left", meta_collection },
    .{ "string.trim-right", &intrinsics_mod.string.@"trim-right", meta_collection },
    .{ "string.includes?", &intrinsics_mod.string.@"includes?", meta_collection },
    .{ "string.starts-with?", &intrinsics_mod.string.@"starts-with?", meta_collection },
    .{ "string.ends-with?", &intrinsics_mod.string.@"ends-with?", meta_collection },
    .{ "string.reverse", &intrinsics_mod.string.reverse, meta_collection },
    .{ "string.substring", &intrinsics_mod.string.substring, meta_collection },
    .{ "string.byte-ref", &intrinsics_mod.string.@"byte-ref", meta_collection },
    .{ "string.number->string", &intrinsics_mod.string.@"number->string", meta_collection },
    .{ "string.string->number", &intrinsics_mod.string.@"string->number", meta_collection },
    .{ "string.from-symbol", &intrinsics_mod.string.@"from-symbol", meta_collection },
    .{ "string.to-list", &intrinsics_mod.string.@"to-list", meta_collection },
    .{ "string.from-list", &intrinsics_mod.string.@"from-list", meta_collection },
    .{ "format", &intrinsics_mod.string.format, meta_format },
    .{ "printf", &intrinsics_mod.string.printf, meta_io_display },
    .{ "equal?", &intrinsics_mod.equal.equal, meta_collection },
    .{ "display", &intrinsics_mod.print.displayBuiltin, meta_io_display },
    .{ "error?", &intrinsics_mod.misc.isError, meta_pure_fixed },
    .{ "error-name", &intrinsics_mod.misc.errorName, meta_pure_fixed },
    .{ "error-location", &intrinsics_mod.misc.errorLocation, meta_source },
    .{ "error-trace", &intrinsics_mod.misc.errorTrace, meta_source },
    .{ "source-text", &intrinsics_mod.sourceText, meta_source },
    .{ "source-datum", &intrinsics_mod.sourceDatum, meta_source },
    .{ "bound-code", &intrinsics_mod.boundCode, meta_source },
    .{ "ad.gradient-call", &ad_gradient.gradientCallback, meta_ad_callback },
    .{ "ad.value-gradient-call", &ad_gradient.valueGradientCallback, meta_ad_callback },
    .{ "bytevector?", &intrinsics_mod.bytes.isByteVector, meta_collection },
    .{ "bytevector-length", &intrinsics_mod.bytes.length, meta_collection },
    .{ "bytevector-ref", &intrinsics_mod.bytes.ref, meta_collection },
    .{ "read-line", &intrinsics_mod.input.readLine, meta_io },
    .{ "read-char", &intrinsics_mod.input.readChar, meta_io },
    .{ "read-byte", &intrinsics_mod.input.readByte, meta_io },
    .{ "read-all", &intrinsics_mod.input.readAll, meta_io },
    .{ "read-all-bytes", &intrinsics_mod.input.readAllBytes, meta_io },
    .{ "file-read", &intrinsics_mod.file.fileRead, meta_io },
    .{ "file-write", &intrinsics_mod.file.fileWrite, meta_io },
    .{ "file-exists?", &intrinsics_mod.file.fileExists, meta_io },
    .{ "file-read-bytes", &intrinsics_mod.file.fileReadBytes, meta_io },
    .{ "file-write-bytes", &intrinsics_mod.file.fileWriteBytes, meta_io },
    .{ "eval", &evalForm, meta_load },
    .{ "module-export", &intrinsics_mod.modules.moduleExport, meta_export },
    .{ "apply", &intrinsics_mod.list.apply, meta_apply },
};

fn evalForm(ctx: *EvalContext, namespace: Value, _: Value, args: []const Value) root.Error!Value {
    if (args.len != 1 and args.len != 2) return error.ArityMismatch;
    const target_ns: ?Value = if (args.len == 2)
        args[1]
    else if (namespace.typ == root.builtins.type_namespace)
        namespace
    else
        null;
    return ctx.runtime.evalDatumWithContext(ctx, args[0], target_ns);
}

const primitive_names = blk: {
    // SAFETY: Every entry is assigned in the following loop before use.
    var names: [primitive_declarations.len][:0]const u8 = undefined;
    for (primitive_declarations, 0..) |declaration, declaration_index| {
        names[declaration_index] = declaration[0];
    }
    break :blk names;
};

/// Intrinsic dispatch identifier generated from the canonical declarations.
pub const Intrinsic = @Enum(
    u16,
    .exhaustive,
    &primitive_names,
    &std.simd.iota(u16, primitive_declarations.len),
);

/// Function pointer table indexed by Intrinsic enum value.
pub const Intrinsics = struct {
    funcs: [primitive_declarations.len]FuncPtr,
    name_entries: [primitive_declarations.len]struct { []const u8, u16 },
    name_map: std.StaticStringMap(u16),
    ids: [primitive_declarations.len]Primitive.PrimitiveId,
    registry: Primitive.RegistryOwner,

    pub fn init(alloc: Allocator) !Intrinsics {
        return initEntries(alloc);
    }

    fn initEntries(alloc: Allocator) !Intrinsics {
        var self: Intrinsics = undefined;
        var base = std.ArrayList(Primitive.Spec).empty;
        defer base.deinit(alloc);

        inline for (primitive_declarations, 0..) |declaration, declaration_index| {
            const name: []const u8 = declaration[0];
            const function: FuncPtr = declaration[1];
            self.funcs[declaration_index] = function;
            self.name_entries[declaration_index] = .{ name, @intCast(declaration_index) };
            self.ids[declaration_index] = findOrAppendSpec(
                alloc,
                &base,
                name,
                function,
                declaration[2],
            ) catch return error.OutOfMemory;
        }
        for (root.builtins.primitive_registrations) |registration| {
            try appendRegistration(alloc, &base, registration);
        }
        self.name_map = try std.StaticStringMap(u16).init(&self.name_entries, alloc);
        self.registry = try Primitive.RegistryOwner.init(alloc, base.items);
        return self;
    }

    pub fn get(self: *const Intrinsics, name: []const u8) ?Value {
        if (self.name_map.get(name)) |index| {
            return Value.intrinsic(self.funcs[index]);
        }
        const registered = self.registry.current().find(name) orelse return null;
        return switch (registered.invoke) {
            .native => |native| Value.intrinsic(native),
            .closure => |closure| closure,
        };
    }

    pub fn nameOf(self: *const Intrinsics, ptr: FuncPtr) ?[]const u8 {
        for (self.funcs, 0..) |function, i| {
            if (function == ptr) return self.name_entries[i][0];
        }
        if (self.registry.current().idForNative(ptr)) |id| {
            if (self.registry.current().spec(id)) |registered_spec| return registered_spec.stable_name;
        }
        return null;
    }

    pub fn primitiveId(self: *const Intrinsics, intrinsic: Intrinsic) Primitive.PrimitiveId {
        return self.ids[@intFromEnum(intrinsic)];
    }

    pub fn indexForPrimitiveId(self: *const Intrinsics, id: Primitive.PrimitiveId) ?Intrinsic {
        for (self.ids, 0..) |candidate, index| {
            if (candidate == id) return @enumFromInt(index);
        }
        return null;
    }

    pub fn idForNative(self: *const Intrinsics, native: FuncPtr) ?Primitive.PrimitiveId {
        return self.registry.current().idForNative(native);
    }

    pub fn spec(self: *const Intrinsics, id: Primitive.PrimitiveId) ?*const Primitive.Spec {
        return self.registry.current().spec(id);
    }

    pub fn registryVersion(self: *const Intrinsics) *const Primitive.RegistryVersion {
        return self.registry.current();
    }

    pub fn publish(
        self: *Intrinsics,
        additions: []const Primitive.Registration,
    ) !*const Primitive.RegistryVersion {
        return self.registry.publish(additions);
    }
};

const Metadata = struct {
    effects: Primitive.EffectSet,
    reads_argument_state: bool,
    callbacks: Primitive.Callback,
    resources: Primitive.ResourceCost,
    suspension: Primitive.SuspensionContract,
};

const meta_pure_fixed: Metadata = .{
    .effects = .none,
    .reads_argument_state = false,
    .callbacks = .none,
    .resources = .{ .fixed = .{} },
    .suspension = .never,
};
const meta_int_pow: Metadata = .{
    .effects = .none,
    .reads_argument_state = false,
    .callbacks = .none,
    .resources = .{ .fixed = .{ .work = 64 } },
    .suspension = .never,
};
const meta_collection: Metadata = .{
    .effects = .none,
    .reads_argument_state = false,
    .callbacks = .none,
    .resources = .native,
    .suspension = .never,
};
const meta_io: Metadata = .{
    .effects = .{ .io = true },
    .reads_argument_state = false,
    .callbacks = .none,
    .resources = .native,
    .suspension = .never,
};
const meta_numeric_native: Metadata = .{
    .effects = .none,
    .reads_argument_state = false,
    .callbacks = .none,
    .resources = .native,
    .suspension = .never,
};
const meta_numeric_avg: Metadata = .{
    .effects = .none,
    .reads_argument_state = false,
    .callbacks = .none,
    .resources = .native,
    .suspension = .never,
};
const meta_complex_alloc: Metadata = .{
    .effects = .none,
    .reads_argument_state = false,
    .callbacks = .none,
    .resources = .{ .bounded = .{ .work = 64, .objects = 3 } },
    .suspension = .never,
};
const meta_map_read: Metadata = .{
    .effects = .{ .state_read = true },
    .reads_argument_state = true,
    .callbacks = .none,
    .resources = .native,
    .suspension = .never,
};
const meta_map_write: Metadata = .{
    .effects = .{ .state_read = true, .state_write = true },
    .reads_argument_state = true,
    .callbacks = .none,
    .resources = .native,
    .suspension = .never,
};
const meta_callback_last: Metadata = .{
    .effects = .{ .state_read = true },
    .reads_argument_state = true,
    .callbacks = .last,
    .resources = .native,
    .suspension = .callback,
};
const meta_fold: Metadata = .{
    .effects = .{ .state_read = true },
    .reads_argument_state = true,
    .callbacks = .collection_fold,
    .resources = .native,
    .suspension = .callback,
};
const meta_format: Metadata = .{
    .effects = .{ .state_read = true, .unknown = true },
    .reads_argument_state = false,
    .callbacks = .type_hook,
    .resources = .unknown,
    .suspension = .unknown,
};
const meta_io_display: Metadata = .{
    .effects = .{ .state_read = true, .io = true, .host = true, .unknown = true },
    .reads_argument_state = false,
    .callbacks = .type_hook,
    .resources = .unknown,
    .suspension = .unknown,
};
const meta_write: Metadata = meta_io_display;
const meta_receive: Metadata = .{
    .effects = .{ .state_read = true, .state_write = true, .process = true, .clock = true },
    .reads_argument_state = true,
    .callbacks = .{ .argument = 0 },
    .resources = .native,
    .suspension = .would_block,
};
const meta_sleep: Metadata = .{
    .effects = .{ .state_read = true, .state_write = true, .process = true, .clock = true },
    .reads_argument_state = false,
    .callbacks = .none,
    .resources = .native,
    .suspension = .would_block,
};
const meta_spawn: Metadata = .{
    .effects = .{ .state_write = true, .process = true },
    .reads_argument_state = false,
    .callbacks = .none,
    .resources = .native,
    .suspension = .never,
};
const meta_load: Metadata = .{
    .effects = .{
        .state_read = true,
        .state_write = true,
        .io = true,
        .process = true,
        .module = true,
        .host = true,
        .unknown = true,
    },
    .reads_argument_state = false,
    .callbacks = .unknown,
    .resources = .unknown,
    .suspension = .unknown,
};
const meta_export: Metadata = .{
    .effects = .{ .state_write = true, .module = true },
    .reads_argument_state = false,
    .callbacks = .none,
    .resources = .native,
    .suspension = .never,
};
const meta_apply: Metadata = .{
    .effects = .none,
    .reads_argument_state = true,
    .callbacks = .{ .argument = 0 },
    .resources = .native,
    .suspension = .callback,
};
const meta_send: Metadata = .{
    .effects = .{ .state_write = true, .process = true },
    .reads_argument_state = true,
    .callbacks = .none,
    .resources = .native,
    .suspension = .never,
};
const meta_process_read: Metadata = .{
    .effects = .{ .state_read = true, .process = true },
    .reads_argument_state = false,
    .callbacks = .none,
    .resources = .native,
    .suspension = .never,
};
const meta_process_info: Metadata = .{
    .effects = .{ .state_read = true, .state_write = true, .process = true },
    .reads_argument_state = false,
    .callbacks = .none,
    .resources = .native,
    .suspension = .never,
};
const meta_dynamic_loader: Metadata = .{
    .effects = .{ .dynamic_loader = true, .io = true, .host = true, .unknown = true },
    .reads_argument_state = false,
    .callbacks = .unknown,
    .resources = .unknown,
    .suspension = .unknown,
};
const meta_ffi: Metadata = .{
    .effects = .{ .ffi = true, .host = true, .unknown = true },
    .reads_argument_state = false,
    .callbacks = .unknown,
    .resources = .unknown,
    .suspension = .unknown,
};
const meta_type: Metadata = .{
    .effects = .{ .state_read = true },
    .reads_argument_state = false,
    .callbacks = .none,
    .resources = .native,
    .suspension = .never,
};
const meta_instance: Metadata = .{
    .effects = .{ .state_read = true, .state_write = true },
    .reads_argument_state = true,
    .callbacks = .none,
    .resources = .native,
    .suspension = .never,
};
const meta_source: Metadata = .{
    .effects = .{ .state_read = true },
    .reads_argument_state = true,
    .callbacks = .none,
    .resources = .native,
    .suspension = .never,
};
const meta_symbol: Metadata = .{
    .effects = .none,
    .reads_argument_state = false,
    .callbacks = .none,
    .resources = .native,
    .suspension = .never,
};
const meta_read: Metadata = .{
    .effects = .none,
    .reads_argument_state = false,
    .callbacks = .none,
    .resources = .native,
    .suspension = .never,
};
const meta_ad_deriv: Metadata = .{
    .effects = .{ .state_read = true },
    .reads_argument_state = false,
    .callbacks = .none,
    .resources = .native,
    .suspension = .never,
};
const meta_evaluate: Metadata = .{
    .effects = .{ .state_read = true },
    .reads_argument_state = false,
    .callbacks = .{ .argument = 0 },
    .resources = .native,
    .suspension = .never,
};
const meta_ad_callback: Metadata = .{
    .effects = .{ .state_read = true },
    .reads_argument_state = false,
    .callbacks = .{ .argument = 0 },
    .resources = .native,
    .suspension = .callback,
};
const meta_ad_scalar: Metadata = .{
    .effects = .{ .state_read = true },
    .reads_argument_state = true,
    .callbacks = .none,
    .resources = .{ .bounded = .{ .work = 64, .objects = 3 } },
    .suspension = .never,
};
const meta_ad_tensor: Metadata = .{
    .effects = .{ .state_read = true },
    .reads_argument_state = true,
    .callbacks = .{ .argument = 1 },
    .resources = .native,
    .suspension = .never,
};
const meta_ad_cotangent: Metadata = .{
    .effects = .{ .state_read = true },
    .reads_argument_state = true,
    .callbacks = .none,
    .resources = .native,
    .suspension = .never,
};
const meta_ad_registration: Metadata = .{
    .effects = .{ .state_write = true },
    .reads_argument_state = false,
    .callbacks = .none,
    .resources = .native,
    .suspension = .never,
};

fn sameInvocation(lhs: FuncPtr, rhs: FuncPtr) bool {
    return lhs == rhs;
}

fn sameMetadata(lhs: Metadata, rhs: Metadata) bool {
    return lhs.effects.eql(rhs.effects) and
        lhs.reads_argument_state == rhs.reads_argument_state and
        std.meta.eql(lhs.callbacks, rhs.callbacks) and
        std.meta.eql(lhs.resources, rhs.resources) and
        std.meta.eql(lhs.suspension, rhs.suspension);
}

fn findOrAppendSpec(
    alloc: Allocator,
    specs: *std.ArrayList(Primitive.Spec),
    name: []const u8,
    function: FuncPtr,
    metadata: Metadata,
) Allocator.Error!Primitive.PrimitiveId {
    for (specs.items) |candidate| {
        const native = switch (candidate.invoke) {
            .native => |ptr| ptr,
            .closure => continue,
        };
        if (!sameInvocation(native, function)) continue;
        const candidate_metadata: Metadata = .{
            .effects = candidate.effects,
            .reads_argument_state = candidate.reads_argument_state,
            .callbacks = candidate.callbacks,
            .resources = candidate.resources,
            .suspension = candidate.suspension,
        };
        if (!sameMetadata(candidate_metadata, metadata)) continue;
        try specs.append(alloc, .{
            .id = candidate.id,
            .stable_name = name,
            .implementation_revision = candidate.implementation_revision,
            .invoke = candidate.invoke,
            .effects = metadata.effects,
            .reads_argument_state = metadata.reads_argument_state,
            .callbacks = metadata.callbacks,
            .resources = metadata.resources,
            .suspension = metadata.suspension,
        });
        return candidate.id;
    }
    const id = Primitive.PrimitiveId.fromIndex(@intCast(specs.items.len));
    try specs.append(alloc, .{
        .id = id,
        .stable_name = name,
        .implementation_revision = 1,
        .invoke = Primitive.Invocation.nativePtr(function),
        .effects = metadata.effects,
        .reads_argument_state = metadata.reads_argument_state,
        .callbacks = metadata.callbacks,
        .resources = metadata.resources,
        .suspension = metadata.suspension,
    });
    return id;
}

fn appendRegistration(
    alloc: Allocator,
    specs: *std.ArrayList(Primitive.Spec),
    registration: Primitive.Registration,
) (Allocator.Error || Primitive.RegistryError)!void {
    const invoke = registration.invoke orelse return error.MissingImplementation;
    const candidate: Primitive.Spec = .{
        .id = .invalid,
        .stable_name = registration.stable_name,
        .implementation_revision = registration.implementation_revision,
        .invoke = invoke,
        .effects = registration.effects,
        .reads_argument_state = registration.reads_argument_state,
        .callbacks = registration.callbacks,
        .resources = registration.resources,
        .suspension = registration.suspension,
    };
    for (specs.items) |existing| {
        if (existing.sameSemantics(candidate)) {
            try specs.append(alloc, .{
                .id = existing.id,
                .stable_name = registration.stable_name,
                .implementation_revision = registration.implementation_revision,
                .invoke = invoke,
                .effects = registration.effects,
                .reads_argument_state = registration.reads_argument_state,
                .callbacks = registration.callbacks,
                .resources = registration.resources,
                .suspension = registration.suspension,
            });
            return;
        }
    }
    try specs.append(alloc, .{
        .id = Primitive.PrimitiveId.fromIndex(@intCast(specs.items.len)),
        .stable_name = registration.stable_name,
        .implementation_revision = registration.implementation_revision,
        .invoke = invoke,
        .effects = registration.effects,
        .reads_argument_state = registration.reads_argument_state,
        .callbacks = registration.callbacks,
        .resources = registration.resources,
        .suspension = registration.suspension,
    });
}

fn identityTestNative2(_: *EvalContext, _: Value, _: Value, _: []const Value) root.Error!Value {
    return .nil;
}

fn identityTestNative(_: *EvalContext, _: Value, _: Value, _: []const Value) root.Error!Value {
    return .nil;
}

test "canonical aliases share identity and independent names do not" {
    var specs = std.ArrayList(Primitive.Spec).empty;
    defer specs.deinit(std.testing.allocator);
    const cat = try findOrAppendSpec(
        std.testing.allocator,
        &specs,
        "cat",
        &identityTestNative,
        meta_collection,
    );
    const concat_id = try findOrAppendSpec(
        std.testing.allocator,
        &specs,
        "concat",
        &identityTestNative,
        meta_collection,
    );
    const other = try findOrAppendSpec(
        std.testing.allocator,
        &specs,
        "other",
        &identityTestNative2,
        meta_pure_fixed,
    );
    try std.testing.expectEqual(cat, concat_id);
    try std.testing.expect(cat != other);
}
