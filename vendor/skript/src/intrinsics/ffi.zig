const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.ffi);

const skript = @import("../root.zig");
const Value = skript.Value;
const Object = skript.Object;
const Error = skript.Error;
const EvalContext = skript.EvalContext;
const Runtime = skript.Runtime;
const ffi = @import("ffi");

const dynlib = @import("dynlib.zig");

pub const Function = struct {
    magic: u64,
    ret: Value,
    ptr: *const fn () callconv(.c) void,
    ffi_params: []*ffi.Type,
    ffi_ret: *ffi.Type,
    /// Runtime.static owns the CIF storage through plan teardown.
    ffi_func: *ffi.Function,
    ffi_plan: ?*ffi.CallPlan,
    library_symbol: ?*dynlib.FunctionSymbol = null,
    /// Runtime teardown uses this link to release the plan while the CIF remains alive.
    next_plan: ?*Function = null,
};

const foreign_arg_capacity: usize = 64;
const function_magic: u64 = 0x534b_5249_5054_4646;

const foreign_scratch_capacity: usize = 1024;
const foreign_result_capacity: usize = @max(@sizeOf([2]f64), @sizeOf(*anyopaque));
const foreign_result_alignment: usize = @max(@alignOf([2]f64), @alignOf(*anyopaque));
const foreign_result_alignment_enum: std.mem.Alignment =
    std.mem.Alignment.fromByteUnits(foreign_result_alignment);

fn hasStoreRef(obj: Object) bool {
    if (obj == .null) return false;
    const ref = obj.toRef();
    return !ref.isNull() and ref.tag != 0 and ref.address() != 0;
}

fn mapTypeValue(value: Value) Error!*ffi.Type {
    if (!value.isType()) return error.TypeMismatch;
    return mapObjectType(value.obj);
}

fn mapObjectType(obj: Object) Error!*ffi.Type {
    return switch (obj) {
        skript.builtins.type_cvoid => ffi.types.void,
        skript.builtins.type_cbool => ffi.types.uint8,
        skript.builtins.type_cint => ffi.types.sint,
        skript.builtins.type_cuint => ffi.types.uint,
        skript.builtins.type_cstring => ffi.types.pointer,
        skript.builtins.type_cfloat => ffi.types.float,
        skript.builtins.type_cdouble => ffi.types.double,
        skript.builtins.type_opaque => ffi.types.pointer,
        skript.builtins.type_c32 => if (ffi.have_complex_type) ffi.types.complex_float else return error.Unsupported,
        skript.builtins.type_c64 => if (ffi.have_complex_type) ffi.types.complex_double else return error.Unsupported,
        else => return error.Unsupported,
    };
}

fn validateAbiLayout(target: *ffi.Type, expected_size: usize, expected_alignment: usize) Error!void {
    if (@as(usize, target.size) != expected_size) return error.Unsupported;
    if (@as(usize, target.alignment) != expected_alignment) return error.Unsupported;
    if (target.size > foreign_result_capacity) return error.Unsupported;
    if (@as(usize, target.alignment) > foreign_result_alignment) return error.Unsupported;
}

fn validateAbiType(target: *ffi.Type, allow_void: bool) Error!void {
    if (@intFromPtr(target) == 0) return error.Unsupported;
    if (target == ffi.types.void) {
        if (allow_void) return;
        return error.Unsupported;
    }
    if (target == ffi.types.uint8) {
        return validateAbiLayout(target, @sizeOf(u8), @alignOf(u8));
    }
    if (target == ffi.types.sint) {
        return validateAbiLayout(target, @sizeOf(c_int), @alignOf(c_int));
    }
    if (target == ffi.types.uint) {
        return validateAbiLayout(target, @sizeOf(c_uint), @alignOf(c_uint));
    }
    if (target == ffi.types.pointer) {
        return validateAbiLayout(target, @sizeOf(*anyopaque), @alignOf(*anyopaque));
    }
    if (target == ffi.types.float) {
        return validateAbiLayout(target, @sizeOf(f32), @alignOf(f32));
    }
    if (target == ffi.types.double) {
        return validateAbiLayout(target, @sizeOf(f64), @alignOf(f64));
    }
    if (ffi.have_complex_type) {
        if (target == ffi.types.complex_float) {
            return validateAbiLayout(target, @sizeOf([2]f32), @alignOf([2]f32));
        }
        if (target == ffi.types.complex_double) {
            return validateAbiLayout(target, @sizeOf([2]f64), @alignOf([2]f64));
        }
    }
    return error.Unsupported;
}

fn validateFunction(func: *const Function) Error!void {
    if (func.magic != function_magic) return error.TypeMismatch;
    if (@intFromPtr(func.ptr) == 0) return error.TypeMismatch;
    if (@intFromPtr(func.ffi_ret) == 0) return error.Unsupported;
    if (func.ffi_plan == null) return error.Unsupported;
    if (@intFromPtr(func.ffi_func) == 0) return error.Unsupported;
    if (func.ffi_params.len > foreign_arg_capacity) return error.Unsupported;
    if (func.ffi_params.len > 0 and @intFromPtr(func.ffi_params.ptr) == 0) return error.Unsupported;
    if (!func.ret.isType()) return error.TypeMismatch;

    const expected_return = try mapTypeValue(func.ret);
    if (expected_return != func.ffi_ret) return error.Unsupported;
    try validateAbiType(func.ffi_ret, true);
    for (func.ffi_params) |param| {
        if (@intFromPtr(param) == 0) return error.Unsupported;
        try validateAbiType(param, false);
    }

    const expected_count: c_uint = @intCast(func.ffi_params.len);
    if (func.ffi_func.param_count != expected_count) return error.Unsupported;
    if (func.ffi_func.return_type != func.ffi_ret) return error.Unsupported;
    if (func.ffi_params.len == 0) {
        if (func.ffi_func.param_types != null) return error.Unsupported;
    } else {
        const param_types = func.ffi_func.param_types orelse return error.Unsupported;
        if (param_types != func.ffi_params.ptr) return error.Unsupported;
    }
}
fn ffiReleasePlan(plan: *ffi.CallPlan) void {
    ffi.ffi_call_plan_free(plan);
}

pub fn makeFunc(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    return makeFuncWithPlanRelease(ctx, args, &ffiReleasePlan);
}

fn makeFuncWithPlanRelease(
    ctx: *EvalContext,
    args: []const Value,
    release_plan: *const fn (*ffi.CallPlan) void,
) Error!Value {
    try requireTrustedConcrete(ctx);
    const rt = ctx.runtime;
    if (args.len < 2) return error.ArityMismatch;
    const parameter_count = args.len - 2;
    if (parameter_count > foreign_arg_capacity) return error.Unsupported;
    if (!args[0].isOpaque() or args[0].obj == .null) return error.TypeMismatch;

    const library_symbol = dynlib.functionSymbol(rt, args[0].obj);
    const function_ptr = if (library_symbol) |symbol|
        try dynlib.validateFunctionSymbol(symbol)
    else blk: {
        if (hasStoreRef(args[0].obj)) return error.TypeMismatch;
        break :blk args[0].obj.toPtr(*const fn () callconv(.c) void);
    };
    if (@intFromPtr(function_ptr) % @alignOf(@TypeOf(function_ptr)) != 0) return error.TypeMismatch;
    if (@intFromPtr(function_ptr) == 0) return error.TypeMismatch;

    const params = args[1 .. args.len - 1];
    const ret = args[args.len - 1];
    const ret_typ = try mapTypeValue(ret);
    try validateAbiType(ret_typ, true);

    // SAFETY: every parameter slot below is initialized before it is copied.
    var mapped_params: [foreign_arg_capacity]*ffi.Type = undefined;
    for (params, 0..) |param, index| {
        const mapped = try mapTypeValue(param);
        try validateAbiType(mapped, false);
        mapped_params[index] = mapped;
    }

    const ffi_params = try rt.static.alloc(*ffi.Type, parameter_count);
    errdefer rt.static.free(ffi_params);
    @memcpy(ffi_params, mapped_params[0..parameter_count]);

    const ffi_func = try rt.static.create(ffi.Function);
    errdefer rt.static.destroy(ffi_func);
    ffi_func.* = undefined;
    ffi_func.prepare(
        .default(),
        @intCast(parameter_count),
        if (parameter_count == 0) null else ffi_params.ptr,
        ret_typ,
    ) catch |err| {
        log.err("ffi: prepare failed: {any}", .{err});
        return error.Unsupported;
    };
    const ffi_plan = ffi.ffi_call_plan_alloc(ffi_func) orelse {
        log.err("ffi: plan alloc failed", .{});
        return error.Unsupported;
    };
    errdefer release_plan(ffi_plan);

    const ref = try rt.store.create(Function);
    const ptr = ref.deref(Function);
    const obj = ref.toObject();
    ptr.* = .{
        .magic = function_magic,
        .ret = ret,
        .ptr = function_ptr,
        .ffi_params = ffi_params,
        .ffi_ret = ret_typ,
        .ffi_func = ffi_func,
        .ffi_plan = ffi_plan,
        .library_symbol = library_symbol,
    };

    rt.ffi_plan_mutex.lockUncancelable(rt.io);
    defer rt.ffi_plan_mutex.unlock(rt.io);
    if (rt.ffi_plan_head) |head| {
        const next: *Function = @ptrCast(@alignCast(head));
        ptr.next_plan = next;
    }
    const opaque_function: *anyopaque = @ptrCast(ptr);
    rt.ffi_plan_head = opaque_function;
    log.info("ffi:makeFunc `{*}`", .{ptr.ptr});
    return .ffi(obj);
}

/// Release plans before Runtime destroys the Store-owned function nodes and CIFs they reference.
pub fn deinitRuntimePlans(rt: *Runtime) void {
    rt.ffi_plan_mutex.lockUncancelable(rt.io);
    defer rt.ffi_plan_mutex.unlock(rt.io);

    var function: ?*Function = null;
    if (rt.ffi_plan_head) |head| {
        const first: *Function = @ptrCast(@alignCast(head));
        function = first;
    }
    rt.ffi_plan_head = null;
    while (function) |func| {
        const next = func.next_plan;
        if (func.ffi_plan) |plan| {
            ffi.ffi_call_plan_free(plan);
            func.ffi_plan = null;
        }
        func.next_plan = null;
        function = next;
    }
}

pub fn invoke(ctx: *EvalContext, ffifunc: Value, args: []const Value) Error!Value {
    try requireTrustedConcrete(ctx);
    if (!ffifunc.isFfi() or !hasStoreRef(ffifunc.obj)) return error.TypeMismatch;

    const rt = ctx.runtime;
    const func = ffifunc.obj.toRef().deref(Function);
    try validateFunction(func);
    if (args.len != func.ffi_params.len) return error.ArityMismatch;
    const required = try checkScratchCapacity(ctx, args, func.ffi_params);

    // SAFETY: every argument slot is filled before the native call.
    var argv: [foreign_arg_capacity]*anyopaque = undefined;
    var empty_scratch: [0]u8 align(foreign_result_alignment) = .{};
    const scratch_storage: []align(foreign_result_alignment) u8 = if (required == 0)
        empty_scratch[0..]
    else
        try ctx.scratch.allocWithOptions(u8, required, foreign_result_alignment_enum, null);
    defer if (required != 0) ctx.scratch.free(scratch_storage);
    var scratch_alloc = std.heap.FixedBufferAllocator.init(scratch_storage);
    const scratch = scratch_alloc.allocator();

    for (args, 0..) |arg, index| {
        argv[index] = try coerce(scratch, rt, arg, func.ffi_params[index]);
    }

    var result: [foreign_result_capacity]u8 align(foreign_result_alignment) = undefined;
    const result_ptr: ?*anyopaque = if (func.ffi_ret == ffi.types.void)
        null
    else
        @ptrCast(&result);
    const argv_ptr: ?[*]*anyopaque = if (args.len == 0) null else argv[0..args.len].ptr;
    const plan = func.ffi_plan orelse return error.Unsupported;
    const call_ptr = if (func.library_symbol) |symbol|
        try dynlib.acquireFunction(symbol)
    else
        func.ptr;
    defer if (func.library_symbol) |symbol| dynlib.releaseFunction(symbol);
    ffi.ffi_call_plan_invoke(plan, @ptrCast(call_ptr), result_ptr, argv_ptr);
    return uncoerceResult(rt, &result, func.ret, func.ffi_ret);
}

fn requireTrustedConcrete(ctx: *EvalContext) Error!void {
    if (!ctx.isUnrestricted()) return error.Denied;
    try ctx.check();
}

fn appendScratch(offset: *usize, size: usize, alignment: usize) Error!void {
    if (alignment == 0) return error.Unsupported;
    if ((alignment & (alignment - 1)) != 0) return error.Unsupported;
    const remainder = offset.* & (alignment - 1);
    const padding = if (remainder == 0) 0 else alignment - remainder;
    offset.* = std.math.add(usize, offset.*, padding) catch return error.Unsupported;
    offset.* = std.math.add(usize, offset.*, size) catch return error.Unsupported;
}

fn checkedFloatToInt(comptime T: type, source: anytype) Error!T {
    const value: f64 = @floatCast(source);
    if (!std.math.isFinite(value)) return error.TypeMismatch;
    const truncated = @trunc(value);
    const min_value: f64 = @floatFromInt(std.math.minInt(T));
    const max_exclusive: f64 = @as(f64, @floatFromInt(std.math.maxInt(T))) + 1.0;
    if (truncated < min_value or truncated >= max_exclusive) return error.TypeMismatch;
    return @intFromFloat(truncated);
}

fn integerValue(comptime T: type, value: Value) Error!T {
    return switch (value.typ) {
        skript.builtins.type_nil => 0,
        skript.builtins.type_bool => @intCast(@intFromBool(value.obj.toBool())),
        skript.builtins.type_f16 => try checkedFloatToInt(T, value.obj.tof16()),
        skript.builtins.type_f32 => try checkedFloatToInt(T, value.obj.tof32()),
        skript.builtins.type_f64 => try checkedFloatToInt(T, value.obj.tof64()),
        skript.builtins.type_i8 => std.math.cast(T, value.obj.toInt(i8)) orelse error.TypeMismatch,
        skript.builtins.type_i16 => std.math.cast(T, value.obj.toInt(i16)) orelse error.TypeMismatch,
        skript.builtins.type_i32 => std.math.cast(T, value.obj.toInt(i32)) orelse error.TypeMismatch,
        skript.builtins.type_i64 => std.math.cast(T, value.obj.toInt(i64)) orelse error.TypeMismatch,
        skript.builtins.type_u8 => std.math.cast(T, value.obj.toInt(u8)) orelse error.TypeMismatch,
        skript.builtins.type_u16 => std.math.cast(T, value.obj.toInt(u16)) orelse error.TypeMismatch,
        skript.builtins.type_u32 => std.math.cast(T, value.obj.toInt(u32)) orelse error.TypeMismatch,
        skript.builtins.type_u64 => std.math.cast(T, value.obj.toInt(u64)) orelse error.TypeMismatch,
        else => error.TypeMismatch,
    };
}

fn floatValue(comptime T: type, value: Value) Error!T {
    const source: f64 = switch (value.typ) {
        skript.builtins.type_bool => @floatFromInt(@intFromBool(value.obj.toBool())),
        skript.builtins.type_f16 => @floatCast(value.obj.tof16()),
        skript.builtins.type_f32 => @floatCast(value.obj.tof32()),
        skript.builtins.type_f64 => value.obj.tof64(),
        skript.builtins.type_i8 => @floatFromInt(value.obj.toInt(i8)),
        skript.builtins.type_i16 => @floatFromInt(value.obj.toInt(i16)),
        skript.builtins.type_i32 => @floatFromInt(value.obj.toInt(i32)),
        skript.builtins.type_i64 => @floatFromInt(value.obj.toInt(i64)),
        skript.builtins.type_u8 => @floatFromInt(value.obj.toInt(u8)),
        skript.builtins.type_u16 => @floatFromInt(value.obj.toInt(u16)),
        skript.builtins.type_u32 => @floatFromInt(value.obj.toInt(u32)),
        skript.builtins.type_u64 => @floatFromInt(value.obj.toInt(u64)),
        else => return error.TypeMismatch,
    };
    return @floatCast(source);
}

fn boundedCStringNoContext(value: Value) Error![:0]const u8 {
    if (value.obj == .null or hasStoreRef(value.obj)) return error.TypeMismatch;
    const start = value.obj.toPtr([*:0]const u8);
    var length: usize = 0;
    while (length < foreign_scratch_capacity) : (length += 1) {
        if (start[length] == 0) return start[0..length :0];
    }
    return error.Unsupported;
}

fn boundedCString(ctx: *EvalContext, value: Value) Error![:0]const u8 {
    if (value.obj == .null or hasStoreRef(value.obj)) return error.TypeMismatch;
    const start = value.obj.toPtr([*:0]const u8);
    return ctx.stringBytes(start, foreign_scratch_capacity, .native);
}

fn validateValue(ctx: *EvalContext, value: Value, target: *ffi.Type) Error!void {
    if (target == ffi.types.void) return error.Unsupported;
    if (target == ffi.types.pointer) {
        switch (value.typ) {
            skript.builtins.type_string => {
                _ = try boundedCString(ctx, value);
            },
            skript.builtins.type_opaque => {
                if (value.obj == .null or hasStoreRef(value.obj)) return error.TypeMismatch;
            },
            else => return error.TypeMismatch,
        }
        return;
    }
    if (target == ffi.types.uint8) {
        _ = try integerValue(u8, value);
        return;
    }
    if (target == ffi.types.sint) {
        _ = try integerValue(c_int, value);
        return;
    }
    if (target == ffi.types.uint) {
        _ = try integerValue(c_uint, value);
        return;
    }
    if (target == ffi.types.float) {
        _ = try floatValue(f32, value);
        return;
    }
    if (target == ffi.types.double) {
        _ = try floatValue(f64, value);
        return;
    }
    if (ffi.have_complex_type and target == ffi.types.complex_float) {
        if (value.typ != skript.builtins.type_c32) return error.TypeMismatch;
        return;
    }
    if (ffi.have_complex_type and target == ffi.types.complex_double) {
        if (value.typ != skript.builtins.type_c64 or !hasStoreRef(value.obj)) {
            return error.TypeMismatch;
        }
        return;
    }
    return error.Unsupported;
}

fn checkScratchCapacity(
    ctx: *EvalContext,
    args: []const Value,
    params: []*ffi.Type,
) Error!usize {
    if (args.len != params.len) return error.ArityMismatch;
    if (params.len > foreign_arg_capacity) return error.Unsupported;
    var required: usize = 0;
    for (args, 0..) |arg, index| {
        required = try scratchNeed(ctx, required, arg, params[index]);
    }
    if (required > foreign_scratch_capacity) return error.Unsupported;
    return required;
}

fn scratchNeed(
    ctx: *EvalContext,
    offset: usize,
    value: Value,
    target: *ffi.Type,
) Error!usize {
    try validateValue(ctx, value, target);
    var required = offset;
    if (target == ffi.types.pointer) {
        try appendScratch(&required, @sizeOf(*anyopaque), @alignOf(*anyopaque));
        if (value.typ == skript.builtins.type_string) {
            const string = try boundedCString(ctx, value);
            const string_bytes = std.math.add(usize, string.len, 1) catch return error.Unsupported;
            try appendScratch(&required, string_bytes, @alignOf(u8));
        }
        return required;
    }
    if (target == ffi.types.uint8) {
        try appendScratch(&required, @sizeOf(u8), @alignOf(u8));
        return required;
    }
    if (target == ffi.types.sint) {
        try appendScratch(&required, @sizeOf(c_int), @alignOf(c_int));
        return required;
    }
    if (target == ffi.types.uint) {
        try appendScratch(&required, @sizeOf(c_uint), @alignOf(c_uint));
        return required;
    }
    if (target == ffi.types.float) {
        try appendScratch(&required, @sizeOf(f32), @alignOf(f32));
        return required;
    }
    if (target == ffi.types.double) {
        try appendScratch(&required, @sizeOf(f64), @alignOf(f64));
        return required;
    }
    if (ffi.have_complex_type and target == ffi.types.complex_float) {
        try appendScratch(&required, @sizeOf([2]f32), @alignOf([2]f32));
        return required;
    }
    if (ffi.have_complex_type and target == ffi.types.complex_double) {
        try appendScratch(&required, @sizeOf([2]f64), @alignOf([2]f64));
        return required;
    }
    return error.Unsupported;
}

pub fn coerce(alloc: Allocator, _: *Runtime, val: Value, target: *ffi.Type) Error!*anyopaque {
    try validateAbiType(target, false);
    if (target == ffi.types.pointer) {
        switch (val.typ) {
            skript.builtins.type_string => {
                const str_slice = try boundedCStringNoContext(val);
                const str = try alloc.dupeSentinel(u8, str_slice, 0);
                errdefer alloc.free(str);
                const ptr = try alloc.create(*anyopaque);
                ptr.* = @ptrCast(str.ptr);
                return @ptrCast(ptr);
            },
            skript.builtins.type_opaque => {
                if (val.obj == .null or hasStoreRef(val.obj)) return error.TypeMismatch;
                const raw = val.obj.toPtr(*anyopaque);
                const ptr = try alloc.create(*anyopaque);
                ptr.* = raw;
                return @ptrCast(ptr);
            },
            else => return error.TypeMismatch,
        }
    }
    if (target == ffi.types.uint8) {
        const value = try integerValue(u8, val);
        const ptr = try alloc.create(u8);
        ptr.* = value;
        return @ptrCast(ptr);
    }
    if (target == ffi.types.sint) {
        const value = try integerValue(c_int, val);
        const ptr = try alloc.create(c_int);
        ptr.* = value;
        return @ptrCast(ptr);
    }
    if (target == ffi.types.uint) {
        const value = try integerValue(c_uint, val);
        const ptr = try alloc.create(c_uint);
        ptr.* = value;
        return @ptrCast(ptr);
    }
    if (target == ffi.types.float) {
        const value = try floatValue(f32, val);
        const ptr = try alloc.create(f32);
        ptr.* = value;
        return @ptrCast(ptr);
    }
    if (target == ffi.types.double) {
        const value = try floatValue(f64, val);
        const ptr = try alloc.create(f64);
        ptr.* = value;
        return @ptrCast(ptr);
    }
    if (ffi.have_complex_type and target == ffi.types.complex_float) {
        if (val.typ != skript.builtins.type_c32) return error.TypeMismatch;
        const value = val.obj.as([2]f32);
        const ptr = try alloc.create([2]f32);
        ptr.* = value;
        return @ptrCast(ptr);
    }
    if (ffi.have_complex_type and target == ffi.types.complex_double) {
        if (val.typ != skript.builtins.type_c64 or !hasStoreRef(val.obj)) {
            return error.TypeMismatch;
        }
        const value = val.obj.toRef().deref([2]f64).*;
        const ptr = try alloc.create([2]f64);
        ptr.* = value;
        return @ptrCast(ptr);
    }
    return error.Unsupported;
}

fn loadResult(comptime T: type, result: *const [foreign_result_capacity]u8) T {
    const ptr: *const T = @ptrCast(@alignCast(result));
    return ptr.*;
}

fn uncoerceResult(
    rt: *Runtime,
    result: *const [foreign_result_capacity]u8,
    ret_typ: Value,
    ffi_ret: *ffi.Type,
) Error!Value {
    const expected_return = try mapTypeValue(ret_typ);
    if (expected_return != ffi_ret) return error.Unsupported;
    try validateAbiType(ffi_ret, true);
    return switch (ret_typ.obj) {
        skript.builtins.type_bool => .bool(loadResult(u8, result) > 0),
        skript.builtins.type_cbool => .bool(loadResult(u8, result) > 0),
        skript.builtins.type_cint => .i32(@intCast(loadResult(c_int, result))),
        skript.builtins.type_cuint => .u32(@intCast(loadResult(c_uint, result))),
        skript.builtins.type_cvoid => .nil,
        skript.builtins.type_cfloat => .f32(loadResult(f32, result)),
        skript.builtins.type_cdouble => .f64(loadResult(f64, result)),
        skript.builtins.type_c32 => .c32(loadResult([2]f32, result)),
        skript.builtins.type_c64 => {
            const ref = try rt.store.create([2]f64);
            ref.deref([2]f64).* = loadResult([2]f64, result);
            return .c64(ref.toObject());
        },
        // A C string return is borrowed from the callee, so copy it into the store.
        // A NULL return becomes nil; a non-NULL empty string remains a string.
        skript.builtins.type_cstring => {
            const raw = loadResult(?*const anyopaque, result) orelse return .nil;
            const cstr: [*:0]const u8 = @ptrCast(raw);
            const str = try rt.context().stringBytes(cstr, foreign_scratch_capacity, .native);
            const alloc = try rt.store.allocSlice(u8, str.len + 1);
            @memcpy(alloc.slice[0..str.len], str[0..str.len]);
            alloc.slice[str.len] = 0;
            return .string(Object.fromPtr(alloc.slice.ptr));
        },
        skript.builtins.type_opaque => .opaq(Object.fromPtr(loadResult(*const anyopaque, result))),
        else => {
            log.err("ffi:uncoerce: unhandled return type: {any}", .{ret_typ.obj});
            return error.Unsupported;
        },
    };
}

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
    }
}
var ffi_test_calls: usize = 0;
var ffi_test_plan_frees: usize = 0;

fn ffiTestReleasePlan(plan: *ffi.CallPlan) void {
    ffi_test_plan_frees += 1;
    ffi.ffi_call_plan_free(plan);
}

fn ffiTestDouble(value: f64) callconv(.c) f64 {
    ffi_test_calls += 1;
    return value * 2.0;
}

fn ffiTestNullCString() callconv(.c) ?*const anyopaque {
    ffi_test_calls += 1;
    return null;
}

fn ffiTestEmptyCString() callconv(.c) [*:0]const u8 {
    ffi_test_calls += 1;
    return "";
}

fn ffiTestCString(_: [*]const u8) callconv(.c) void {
    ffi_test_calls += 1;
}

fn ffiTestInt(_: c_int) callconv(.c) void {
    ffi_test_calls += 1;
}

fn ffiTestString(rt: *Runtime, length: usize) !Value {
    const stored = try rt.store.allocSlice(u8, length + 1);
    @memset(stored.slice[0..length], 'x');
    stored.slice[length] = 0;
    return .string(Object.fromPtr(stored.slice.ptr));
}

test "ffi rejects wrong arity before target call" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    ffi_test_calls = 0;

    const b = skript.builtins;
    const func = try makeFunc(
        rt.context(),
        .nil,
        .nil,
        &.{
            Value.opaq(Object.fromPtr(&ffiTestDouble)),
            .typeValue(b.type_cdouble),
            .typeValue(b.type_cdouble),
        },
    );

    try std.testing.expectError(error.ArityMismatch, invoke(rt.context(), func, &.{}));
    try std.testing.expectEqual(@as(usize, 0), ffi_test_calls);
}

test "ffi rejects oversized scratch before target call" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    ffi_test_calls = 0;

    const b = skript.builtins;
    const func = try makeFunc(
        rt.context(),
        .nil,
        .nil,
        &.{
            Value.opaq(Object.fromPtr(&ffiTestCString)),
            .typeValue(b.type_cstring),
            .typeValue(b.type_cvoid),
        },
    );
    const oversized = try ffiTestString(rt, foreign_scratch_capacity);

    try std.testing.expectError(error.Unsupported, invoke(rt.context(), func, &.{oversized}));
    try std.testing.expectEqual(@as(usize, 0), ffi_test_calls);
}

test "ffi calls a double target with a double result" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    ffi_test_calls = 0;

    const b = skript.builtins;
    const func = try makeFunc(
        rt.context(),
        .nil,
        .nil,
        &.{
            Value.opaq(Object.fromPtr(&ffiTestDouble)),
            .typeValue(b.type_cdouble),
            .typeValue(b.type_cdouble),
        },
    );
    const result = try invoke(rt.context(), func, &.{.f64(1.25)});

    try std.testing.expectEqual(b.type_f64, result.typ);
    try std.testing.expectEqual(@as(f64, 2.5), result.obj.tof64());
    try std.testing.expectEqual(@as(usize, 1), ffi_test_calls);
}

test "ffi distinguishes a null C string return from an empty string" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    ffi_test_calls = 0;

    const b = skript.builtins;
    const null_func = try makeFunc(
        rt.context(),
        .nil,
        .nil,
        &.{
            Value.opaq(Object.fromPtr(&ffiTestNullCString)),
            .typeValue(b.type_cstring),
        },
    );
    const null_result = try invoke(rt.context(), null_func, &.{});
    try std.testing.expectEqual(b.type_nil, null_result.typ);

    const empty_func = try makeFunc(
        rt.context(),
        .nil,
        .nil,
        &.{
            Value.opaq(Object.fromPtr(&ffiTestEmptyCString)),
            .typeValue(b.type_cstring),
        },
    );
    const empty_result = try invoke(rt.context(), empty_func, &.{});
    try std.testing.expectEqual(b.type_string, empty_result.typ);
    const empty = try rt.context().stringBytes(
        empty_result.obj.toPtr([*:0]const u8),
        foreign_scratch_capacity,
        .native,
    );
    try std.testing.expectEqualStrings("", empty);
    try std.testing.expectEqual(@as(usize, 2), ffi_test_calls);
}

test "ffi rejects an invalid return ABI before construction" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try std.testing.expectError(
        error.TypeMismatch,
        makeFunc(
            rt.context(),
            .nil,
            .nil,
            &.{
                Value.opaq(Object.fromPtr(&ffiTestDouble)),
                Value.i64(1),
            },
        ),
    );
}

test "ffi rejects an out of range integer before target call" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    ffi_test_calls = 0;

    const b = skript.builtins;
    const func = try makeFunc(
        rt.context(),
        .nil,
        .nil,
        &.{
            Value.opaq(Object.fromPtr(&ffiTestInt)),
            .typeValue(b.type_cint),
            .typeValue(b.type_cvoid),
        },
    );

    try std.testing.expectError(
        error.TypeMismatch,
        invoke(rt.context(), func, &.{.i64(std.math.maxInt(i64))}),
    );
    try std.testing.expectEqual(@as(usize, 0), ffi_test_calls);
}

test "ffi rejects null function pointers and restricted contexts" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    ffi_test_calls = 0;

    const b = skript.builtins;
    try std.testing.expectError(
        error.TypeMismatch,
        makeFunc(
            rt.context(),
            .nil,
            .nil,
            &.{
                Value.opaq(.null),
                .typeValue(b.type_cdouble),
            },
        ),
    );
    const fake_ref = try rt.store.create(u8);
    try std.testing.expectError(
        error.TypeMismatch,
        makeFunc(
            rt.context(),
            .nil,
            .nil,
            &.{
                Value.opaq(fake_ref.toObject()),
                .typeValue(b.type_cdouble),
            },
        ),
    );

    const func = try makeFunc(
        rt.context(),
        .nil,
        .nil,
        &.{
            Value.opaq(Object.fromPtr(&ffiTestDouble)),
            .typeValue(b.type_cdouble),
            .typeValue(b.type_cdouble),
        },
    );
    var restricted = rt.context().*;
    restricted.mode = .dry;
    try std.testing.expectError(error.Denied, invoke(&restricted, func, &.{.f64(1.0)}));
    try std.testing.expectEqual(@as(usize, 0), ffi_test_calls);
    try std.testing.expectError(
        error.Denied,
        makeFunc(
            &restricted,
            .nil,
            .nil,
            &.{
                Value.opaq(Object.fromPtr(&ffiTestDouble)),
                .typeValue(b.type_cdouble),
            },
        ),
    );
}
test "ffi coercion rejects a pointer type mismatch without leaking" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try std.testing.expectError(
        error.TypeMismatch,
        coerce(std.testing.allocator, rt, .i32(7), ffi.types.pointer),
    );
}

test "ffi integer conversion failure allocates no argument slot" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try std.testing.expectError(
        error.TypeMismatch,
        coerce(
            std.testing.allocator,
            rt,
            .i64(std.math.maxInt(i64)),
            ffi.types.sint,
        ),
    );
}

test "ffi frees a copied C string if argument-slot allocation exhausts" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var storage: [8]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const input = "hello";

    try std.testing.expectError(
        error.OutOfMemory,
        coerce(
            fixed.allocator(),
            rt,
            Value.string(Object.fromPtr(input.ptr)),
            ffi.types.pointer,
        ),
    );
    _ = try fixed.allocator().alloc(u8, storage.len);
}

test "ffi scratch exhaustion rejects arguments before calling target" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    ffi_test_calls = 0;
    const b = skript.builtins;
    const function = try makeFunc(rt.context(), .nil, .nil, &.{
        Value.opaq(Object.fromPtr(&ffiTestCString)),
        .typeValue(b.type_cstring),
        .typeValue(b.type_cvoid),
    });
    const input = try ffiTestString(rt, 8);
    var ctx = rt.context().*;
    var storage: [8]u8 align(8) = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    ctx.scratch = fixed.allocator();

    try std.testing.expectError(error.OutOfMemory, invoke(&ctx, function, &.{input}));
    try std.testing.expectEqual(@as(usize, 0), ffi_test_calls);
}

test "ffi rejects a dynamic-library function after close" {
    if (builtin.os.tag != .linux or builtin.link_mode == .static) return error.SkipZigTest;

    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const ctx = rt.context();

    const library = try dynlib.open(ctx, .nil, .nil, &.{
        Value.string(Object.fromPtr("libc.so.6".ptr)),
    });
    const function_pointer = try dynlib.lookup(ctx, .nil, .nil, &.{
        library,
        Value.string(Object.fromPtr("abs".ptr)),
    });
    const b = skript.builtins;
    const function = try makeFunc(ctx, .nil, .nil, &.{
        function_pointer,
        .typeValue(b.type_cint),
        .typeValue(b.type_cint),
    });

    try std.testing.expectEqual(Value.i32(7), try invoke(ctx, function, &.{.i32(-7)}));
    _ = try dynlib.close(ctx, .nil, .nil, &.{library});
    _ = try dynlib.close(ctx, .nil, .nil, &.{library});
    dynlib.deinitRuntimeLibraries(rt);
    dynlib.deinitRuntimeLibraries(rt);
    try std.testing.expectError(error.Unsupported, invoke(ctx, function, &.{.i32(-7)}));
}
fn exhaustStoreFor(comptime T: type, rt: *Runtime) void {
    while (rt.store.create([65536]u8)) |_| {} else |err| {
        std.debug.assert(err == error.OutOfMemory);
    }
    while (rt.store.create(T)) |_| {} else |err| {
        std.debug.assert(err == error.OutOfMemory);
    }
}

test "ffi releases a prepared plan when Store publication is exhausted" {
    var rt = try Runtime.initWithConfig(std.testing.allocator, std.testing.io, .{
        .heap_size = 8 * 1024 * 1024,
        .max_heap_size = 8 * 1024 * 1024,
    });
    defer rt.deinit();
    exhaustStoreFor(Function, rt);
    const live_objects = rt.store.stats().live_objects;

    ffi_test_plan_frees = 0;
    const b = skript.builtins;
    const args: [3]Value = .{
        Value.opaq(Object.fromPtr(&ffiTestDouble)),
        .typeValue(b.type_cdouble),
        .typeValue(b.type_cdouble),
    };
    try std.testing.expectError(
        error.OutOfMemory,
        makeFuncWithPlanRelease(rt.context(), &args, &ffiTestReleasePlan),
    );
    try std.testing.expectEqual(@as(usize, 1), ffi_test_plan_frees);
    try std.testing.expectEqual(live_objects, rt.store.stats().live_objects);
    try std.testing.expectEqual(@as(?*anyopaque, null), rt.ffi_plan_head);
}

test "collection retains Runtime-owned FFI call plans" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const b = skript.builtins;
    const function = try makeFunc(rt.context(), .nil, .nil, &.{
        Value.opaq(Object.fromPtr(&ffiTestDouble)),
        .typeValue(b.type_cdouble),
        .typeValue(b.type_cdouble),
    });

    try rt.collect();
    _ = try rt.store.derefChecked(Function, function.obj.toRef());
    try std.testing.expectEqual(Value.f64(6), try invoke(rt.context(), function, &.{.f64(3)}));
}

test "ffi Runtime plan teardown is idempotent and rejects expired calls" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const b = skript.builtins;
    const function = try makeFunc(rt.context(), .nil, .nil, &.{
        Value.opaq(Object.fromPtr(&ffiTestDouble)),
        .typeValue(b.type_cdouble),
        .typeValue(b.type_cdouble),
    });

    deinitRuntimePlans(rt);
    deinitRuntimePlans(rt);
    try std.testing.expectEqual(@as(?*anyopaque, null), rt.ffi_plan_head);
    try std.testing.expectError(error.Unsupported, invoke(rt.context(), function, &.{.f64(1.0)}));
}
