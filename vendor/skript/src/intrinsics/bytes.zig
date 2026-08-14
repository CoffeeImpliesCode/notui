const std = @import("std");

const skript = @import("../root.zig");
const Value = skript.Value;
const Object = skript.Object;
const Error = skript.Error;
const EvalContext = skript.EvalContext;

const intrin = @import("root.zig");

fn chargeBytes(ctx: *EvalContext, count: usize) Error!void {
    try ctx.chargeWork(@intCast(count), 1, .native);
}

fn allocateByteVector(ctx: *EvalContext, bytes: []const u8) Error!Value {
    const data = try ctx.runtime.store.allocSlice(u8, bytes.len);
    errdefer ctx.runtime.store.discardUnpublished(data.ref) catch unreachable;
    if (bytes.len != 0) @memcpy(data.slice, bytes);
    return fromStoreSlice(ctx, data.slice);
}

/// Wrap a byte slice whose storage already belongs to the Runtime Store.
pub fn fromStoreSlice(ctx: *EvalContext, bytes: []const u8) Error!Value {
    const holder = try ctx.runtime.store.create(Value.ByteVector);
    ctx.runtime.store.store(Value.ByteVector, holder.deref(Value.ByteVector), .{ .bytes = bytes });
    return Value.byteVector(holder.toObject());
}

/// Construct a ByteVector from an immutable byte slice.
pub fn fromBytes(ctx: *EvalContext, bytes: []const u8) Error!Value {
    try chargeBytes(ctx, bytes.len);
    return allocateByteVector(ctx, bytes);
}

/// `(ByteVector u8 ...)` — copy numeric u8 arguments into an immutable vector.
pub fn construct(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try chargeBytes(ctx, args.len);
    for (args) |arg| try intrin.typeAssert(arg, skript.builtins.type_u8);

    const store = ctx.runtime.store;
    const data = try store.allocSlice(u8, args.len);
    errdefer store.discardUnpublished(data.ref) catch unreachable;
    for (args, data.slice) |arg, *byte| byte.* = arg.obj.toInt(u8);
    return fromStoreSlice(ctx, data.slice);
}

/// `(bytevector? value)` — true when value is a ByteVector.
pub fn isByteVector(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    return Value.bool(args[0].isByteVector());
}

/// `(bytevector-length bytes)` — return its length as an i64.
pub fn length(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_bytevector);
    const bytes = try args[0].byteVectorBytes();
    try chargeBytes(ctx, 1);
    return .i64(std.math.cast(i64, bytes.len) orelse return error.Unsupported);
}

fn isIntegerType(typ: Object) bool {
    return switch (typ) {
        skript.builtins.type_i8,
        skript.builtins.type_i16,
        skript.builtins.type_i32,
        skript.builtins.type_i64,
        skript.builtins.type_u8,
        skript.builtins.type_u16,
        skript.builtins.type_u32,
        skript.builtins.type_u64,
        => true,
        else => false,
    };
}

fn indexValue(value: Value) Error!usize {
    if (!isIntegerType(value.typ)) return error.TypeMismatch;
    const raw: u64 = switch (value.typ) {
        skript.builtins.type_i8 => blk: {
            const number = value.obj.toInt(i8);
            if (number < 0) return error.Unsupported;
            break :blk @intCast(number);
        },
        skript.builtins.type_i16 => blk: {
            const number = value.obj.toInt(i16);
            if (number < 0) return error.Unsupported;
            break :blk @intCast(number);
        },
        skript.builtins.type_i32 => blk: {
            const number = value.obj.toInt(i32);
            if (number < 0) return error.Unsupported;
            break :blk @intCast(number);
        },
        skript.builtins.type_i64 => blk: {
            const number = value.obj.toInt(i64);
            if (number < 0) return error.Unsupported;
            break :blk @intCast(number);
        },
        skript.builtins.type_u8 => value.obj.toInt(u8),
        skript.builtins.type_u16 => value.obj.toInt(u16),
        skript.builtins.type_u32 => value.obj.toInt(u32),
        skript.builtins.type_u64 => value.obj.toInt(u64),
        else => unreachable,
    };
    return std.math.cast(usize, raw) orelse error.Unsupported;
}

/// `(bytevector-ref bytes index)` — return the indexed byte as a u8.
pub fn ref(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    try intrin.typeAssert(args[0], skript.builtins.type_bytevector);
    const bytes = try args[0].byteVectorBytes();
    const index = try indexValue(args[1]);
    try chargeBytes(ctx, 1);
    if (index >= bytes.len) return error.Unsupported;
    return .u8(bytes[index]);
}

test "ByteVector constructor and accessors preserve every byte" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const vector = try rt.evalString("(ByteVector (u8 0) (u8 65) (u8 128) (u8 255))");
    try std.testing.expect(vector.isByteVector());
    try std.testing.expectEqualSlices(u8, &.{ 0, 65, 128, 255 }, try vector.byteVectorBytes());
    try std.testing.expectEqual(Value.i64(4), try rt.evalString(
        "(bytevector-length (ByteVector (u8 0) (u8 65) (u8 128) (u8 255)))",
    ));
    try std.testing.expectEqual(Value.u8(255), try rt.evalString(
        "(bytevector-ref (ByteVector (u8 0) (u8 65) (u8 128) (u8 255)) 3)",
    ));
    try std.testing.expectEqual(Value.i64(0), try rt.evalString("(bytevector-length (ByteVector))"));
}

test "ByteVector constructor and ref reject invalid types and indexes" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try std.testing.expectError(error.TypeMismatch, rt.evalString("(ByteVector 1)"));
    try std.testing.expectError(error.TypeMismatch, rt.evalString("(bytevector-ref (ByteVector (u8 1)) 1.5)"));
    try std.testing.expectError(error.Unsupported, rt.evalString("(bytevector-ref (ByteVector (u8 1)) -1)"));
    try std.testing.expectError(error.Unsupported, rt.evalString("(bytevector-ref (ByteVector (u8 1)) (i8 -1))"));
    try std.testing.expectError(error.Unsupported, rt.evalString("(bytevector-ref (ByteVector (u8 1)) 1)"));
}

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
    }
}
