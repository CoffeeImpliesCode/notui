const std = @import("std");

const skript = @import("root.zig");
const Store = skript.Store;
const Object = Store.Object;

pub const Width = enum(u2) {
    @"8" = 0,
    @"16" = 1,
    @"32" = 2,
    @"64" = 3,
};

/// Encode a builtin type index as an Object. The Object value for type N is N.
fn typeTag(idx: u64) Object {
    return @fromBackingInt(@intCast(idx));
}

pub const type_start: u64 = 0;
pub const type_nil: Object = typeTag(type_start + 0);
pub const type_error: Object = typeTag(type_start + 1);
pub const type_type: Object = typeTag(type_start + 2);
pub const type_namespace: Object = typeTag(type_start + 3);
pub const type_bool: Object = typeTag(type_start + 4);
pub const type_symbol: Object = typeTag(type_start + 5);
pub const type_string: Object = typeTag(type_start + 6);
pub const type_opaque: Object = typeTag(type_start + 7);

pub const type_callable: u64 = type_start + 8;
pub const type_callable_mask: u64 = 0xFFFFFFFFFFFFFFF8;
pub const type_closure: Object = typeTag(type_callable + 0);
pub const type_method: Object = typeTag(type_callable + 1);
pub const type_intrinsic: Object = typeTag(type_callable + 2);
pub const type_callable_placeholder0: Object = typeTag(type_callable + 3);
pub const type_ffifunc: Object = typeTag(type_callable + 4);
pub const type_pid: Object = typeTag(type_callable + 5);
pub const type_callable_placeholder1: Object = typeTag(type_callable + 6);
pub const type_callable_placeholder2: Object = typeTag(type_callable + 7);
pub const type_callable_max: u64 = type_callable + 7;

pub const type_float: u64 = type_start + 16;
pub const type_float_mask: u64 = 0xFFFFFFFFFFFFFFFC;
pub const type_f8: Object = typeTag(type_float + 0);
pub const type_f16: Object = typeTag(type_float + 1);
pub const type_f32: Object = typeTag(type_float + 2);
pub const type_f64: Object = typeTag(type_float + 3);
pub const type_float_max: u64 = type_float + 3;

pub const type_uint: u64 = type_start + 20;
pub const type_uint_mask: u64 = 0xFFFFFFFFFFFFFFFC;
pub const type_u8: Object = typeTag(type_uint + 0);
pub const type_u16: Object = typeTag(type_uint + 1);
pub const type_u32: Object = typeTag(type_uint + 2);
pub const type_u64: Object = typeTag(type_uint + 3);
pub const type_uint_max: u64 = type_uint + 3;

pub const type_int: u64 = type_start + 24;
pub const type_int_mask: u64 = 0xFFFFFFFFFFFFFFFC;
pub const type_i8: Object = typeTag(type_int + 0);
pub const type_i16: Object = typeTag(type_int + 1);
pub const type_i32: Object = typeTag(type_int + 2);
pub const type_i64: Object = typeTag(type_int + 3);
pub const type_int_max: u64 = type_int + 3;

pub const type_complex: u64 = type_start + 28;
pub const type_complex_mask: u64 = 0xFFFFFFFFFFFFFFFC;
pub const type_c8: Object = typeTag(type_complex + 0);
pub const type_c16: Object = typeTag(type_complex + 1);
pub const type_c32: Object = typeTag(type_complex + 2);
pub const type_c64: Object = typeTag(type_complex + 3);
pub const type_complex_max: u64 = type_complex + 3;

pub const type_c: u64 = type_start + 32;
pub const type_c_mask: u64 = 0xFFFFFFFFFFFFFFF8;
pub const type_cvoid: Object = typeTag(type_c + 0);
pub const type_cbool: Object = typeTag(type_c + 1);
pub const type_cint: Object = typeTag(type_c + 2);
pub const type_cuint: Object = typeTag(type_c + 3);
pub const type_cfloat: Object = typeTag(type_c + 4);
pub const type_cdouble: Object = typeTag(type_c + 5);
pub const type_cstring: Object = typeTag(type_c + 6);
pub const type_c_max: u64 = type_c + 6;

pub const type_structures: u64 = type_start + 39;
pub const type_cons: Object = typeTag(type_structures + 0);
pub const type_ast: Object = typeTag(type_structures + 1);
pub const type_map: Object = typeTag(type_structures + 2);
pub const type_keyword: Object = typeTag(type_start + 42);
pub const type_tensor: Object = typeTag(type_start + 43);
/// Runtime-owned symbolic expression handle. The payload is an opaque
/// process-local ID, never a pointer into Expr storage.
pub const type_expr: Object = typeTag(type_start + 44);
pub const type_bytevector: Object = typeTag(type_start + 45);

pub const type_last_idx: u64 = 45;

pub const BuiltinTypeSpec = struct {
    object: Object,
    name: []const u8,
    size: u8 = 6,
};

pub const builtin_types: []const BuiltinTypeSpec = &.{
    .{ .object = type_nil, .name = "core.nil" },
    .{ .object = type_error, .name = "core.error" },
    .{ .object = type_type, .name = "core.type" },
    .{ .object = type_namespace, .name = "core.namespace" },
    .{ .object = type_bool, .name = "core.bool" },
    .{ .object = type_symbol, .name = "core.symbol" },
    .{ .object = type_string, .name = "core.string" },
    .{ .object = type_opaque, .name = "core.opaque" },
    .{ .object = type_closure, .name = "core.closure" },
    .{ .object = type_method, .name = "core.method" },
    .{ .object = type_intrinsic, .name = "core.intrinsic" },
    .{ .object = type_callable_placeholder0, .name = "core.callable.placeholder0" },
    .{ .object = type_ffifunc, .name = "core.ffifunc" },
    .{ .object = type_pid, .name = "core.pid" },
    .{ .object = type_callable_placeholder1, .name = "core.callable.placeholder1" },
    .{ .object = type_callable_placeholder2, .name = "core.callable.placeholder2" },
    .{ .object = type_f8, .name = "core.f8" },
    .{ .object = type_f16, .name = "core.f16" },
    .{ .object = type_f32, .name = "core.f32" },
    .{ .object = type_f64, .name = "core.f64" },
    .{ .object = type_u8, .name = "core.u8" },
    .{ .object = type_u16, .name = "core.u16" },
    .{ .object = type_u32, .name = "core.u32" },
    .{ .object = type_u64, .name = "core.u64" },
    .{ .object = type_i8, .name = "core.i8" },
    .{ .object = type_i16, .name = "core.i16" },
    .{ .object = type_i32, .name = "core.i32" },
    .{ .object = type_i64, .name = "core.i64" },
    .{ .object = type_c8, .name = "core.c8" },
    .{ .object = type_c16, .name = "core.c16" },
    .{ .object = type_c32, .name = "core.c32" },
    .{ .object = type_c64, .name = "core.c64" },
    .{ .object = type_cvoid, .name = "core.c.void" },
    .{ .object = type_cbool, .name = "core.c.bool" },
    .{ .object = type_cint, .name = "core.c.int" },
    .{ .object = type_cuint, .name = "core.c.uint" },
    .{ .object = type_cfloat, .name = "core.c.float" },
    .{ .object = type_cdouble, .name = "core.c.double" },
    .{ .object = type_cstring, .name = "core.c.string" },
    .{ .object = type_cons, .name = "core.cons" },
    .{ .object = type_ast, .name = "core.ast" },
    .{ .object = type_map, .name = "core.map" },
    .{ .object = type_keyword, .name = "core.keyword" },
    .{ .object = type_tensor, .name = "core.tensor" },
    .{ .object = type_expr, .name = "core.expr" },
    .{ .object = type_bytevector, .name = "core.bytevector" },
};

/// Non-enum primitive declarations. Type application and builtin formatting
/// are registered beside the enum rows so they use the same descriptor path.
pub const primitive_registrations = [_]skript.Primitive.Registration{
    .{
        .stable_name = "builtin.type.f16.apply",
        .invoke = skript.Primitive.Invocation.nativePtr(&skript.intrinsics.float.f16_construct),
        .effects = .none,
        .callbacks = .none,
        .resources = .{ .fixed = .{} },
        .suspension = .never,
    },
    .{
        .stable_name = "builtin.type.f32.apply",
        .invoke = skript.Primitive.Invocation.nativePtr(&skript.intrinsics.float.f32_construct),
        .effects = .none,
        .callbacks = .none,
        .resources = .{ .fixed = .{} },
        .suspension = .never,
    },
    .{
        .stable_name = "builtin.type.f64.apply",
        .invoke = skript.Primitive.Invocation.nativePtr(&skript.intrinsics.float.f64_construct),
        .effects = .none,
        .callbacks = .none,
        .resources = .{ .fixed = .{} },
        .suspension = .never,
    },
    .{
        .stable_name = "builtin.type.u8.apply",
        .invoke = skript.Primitive.Invocation.nativePtr(&skript.intrinsics.int.u8_construct),
        .effects = .none,
        .callbacks = .none,
        .resources = .{ .fixed = .{} },
        .suspension = .never,
    },
    .{
        .stable_name = "builtin.type.u16.apply",
        .invoke = skript.Primitive.Invocation.nativePtr(&skript.intrinsics.int.u16_construct),
        .effects = .none,
        .callbacks = .none,
        .resources = .{ .fixed = .{} },
        .suspension = .never,
    },
    .{
        .stable_name = "builtin.type.u32.apply",
        .invoke = skript.Primitive.Invocation.nativePtr(&skript.intrinsics.int.u32_construct),
        .effects = .none,
        .callbacks = .none,
        .resources = .{ .fixed = .{} },
        .suspension = .never,
    },
    .{
        .stable_name = "builtin.type.u64.apply",
        .invoke = skript.Primitive.Invocation.nativePtr(&skript.intrinsics.int.u64_construct),
        .effects = .none,
        .callbacks = .none,
        .resources = .{ .fixed = .{} },
        .suspension = .never,
    },
    .{
        .stable_name = "builtin.type.i8.apply",
        .invoke = skript.Primitive.Invocation.nativePtr(&skript.intrinsics.int.i8_construct),
        .effects = .none,
        .callbacks = .none,
        .resources = .{ .fixed = .{} },
        .suspension = .never,
    },
    .{
        .stable_name = "builtin.type.i16.apply",
        .invoke = skript.Primitive.Invocation.nativePtr(&skript.intrinsics.int.i16_construct),
        .effects = .none,
        .callbacks = .none,
        .resources = .{ .fixed = .{} },
        .suspension = .never,
    },
    .{
        .stable_name = "builtin.type.i32.apply",
        .invoke = skript.Primitive.Invocation.nativePtr(&skript.intrinsics.int.i32_construct),
        .effects = .none,
        .callbacks = .none,
        .resources = .{ .fixed = .{} },
        .suspension = .never,
    },
    .{
        .stable_name = "builtin.type.i64.apply",
        .invoke = skript.Primitive.Invocation.nativePtr(&skript.intrinsics.int.i64_construct),
        .effects = .none,
        .callbacks = .none,
        .resources = .{ .fixed = .{} },
        .suspension = .never,
    },
    .{
        .stable_name = "builtin.type.ByteVector.apply",
        .invoke = skript.Primitive.Invocation.nativePtr(&skript.intrinsics.bytes.construct),
        .effects = .none,
        .callbacks = .none,
        .resources = .native,
        .suspension = .never,
    },
    .{
        .stable_name = "builtin.type.show",
        .invoke = skript.Primitive.Invocation.nativePtr(&skript.intrinsics.print.debugFormatBuiltin),
        .effects = .{ .state_read = true, .unknown = true },
        .callbacks = .type_hook,
        .resources = .unknown,
        .suspension = .unknown,
    },
    .{
        .stable_name = "builtin.type.display",
        .invoke = skript.Primitive.Invocation.nativePtr(&skript.intrinsics.print.displayBuiltin),
        .effects = .{ .state_read = true, .io = true, .host = true, .unknown = true },
        .callbacks = .type_hook,
        .resources = .unknown,
        .suspension = .unknown,
    },
};

/// Create Type descriptors in the GC heap for all builtin types.
/// Returns an array of Type pointers indexed by type index.
pub fn initBuiltinTypes(store: *Store) ![type_last_idx + 1]*skript.data.Type {
    const Type = skript.data.Type;

    var types: [type_last_idx + 1]*Type = undefined;

    inline for (builtin_types, 0..) |spec, idx| {
        const ref = try store.create(Type);
        types[idx] = ref.deref(Type);

        const apply: skript.Value = switch (idx) {
            17 => .intrinsic(&skript.intrinsics.float.f16_construct),
            18 => .intrinsic(&skript.intrinsics.float.f32_construct),
            19 => .intrinsic(&skript.intrinsics.float.f64_construct),
            20 => .intrinsic(&skript.intrinsics.int.u8_construct),
            21 => .intrinsic(&skript.intrinsics.int.u16_construct),
            22 => .intrinsic(&skript.intrinsics.int.u32_construct),
            23 => .intrinsic(&skript.intrinsics.int.u64_construct),
            24 => .intrinsic(&skript.intrinsics.int.i8_construct),
            25 => .intrinsic(&skript.intrinsics.int.i16_construct),
            26 => .intrinsic(&skript.intrinsics.int.i32_construct),
            27 => .intrinsic(&skript.intrinsics.int.i64_construct),
            45 => .intrinsic(&skript.intrinsics.bytes.construct),
            else => .nil,
        };

        store.store(Type, ref.deref(Type), .{
            .meta = type_type,
            .name = Object.fromPtr(try store.getsym(spec.name)),
            .show = .intrinsic(&skript.intrinsics.print.debugFormatBuiltin),
            .display = .intrinsic(&skript.intrinsics.print.displayBuiltin),
            .apply = apply,
        });
    }

    return types;
}

test "Null is null" {
    try std.testing.expectEqual(type_nil, Object.null);
}

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
    }
}
