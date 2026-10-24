const std = @import("std");

const skript = @import("root.zig");
const Object = skript.Object;
const Error = skript.Error;
const FuncPtr = skript.FuncPtr;
const Sym = skript.Sym;

/// Store-owned immutable bytes. `bytes` carries both the length and data.
const ByteVectorData = struct {
    bytes: []const u8,
};
pub const ByteVector = ByteVectorData;

/// Tagged union of all Skript runtime values. A `Value` pairs a type tag
/// (an `Object`) with a payload (also `Object`). The payload may be an
/// immediate (encoded in the Object bits) or a store reference for heap data.
pub const Value = extern struct {
    pub const ByteVector = ByteVectorData;
    typ: Object = .null,
    obj: Object = .null,
    /// Opaque identity for a Runtime-owned expression handle. The high half
    /// identifies the owning symbolic State; the low half indexes its handle
    /// table. Neither half is an address.
    pub const ExprId = enum(u64) {
        invalid = 0,
        _,

        pub fn init(owner_id: u32, local_id: u32) ExprId {
            std.debug.assert(owner_id != 0);
            std.debug.assert(local_id != 0);
            return @fromBackingInt(@intCast((@as(u64, owner_id) << 32) | @as(u64, local_id)));
        }

        pub fn owner(self: ExprId) u32 {
            return @truncate(@backingInt(self) >> 32);
        }

        pub fn local(self: ExprId) u32 {
            return @truncate(@backingInt(self));
        }

        pub fn isValid(self: ExprId) bool {
            return self != .invalid and self.owner() != 0 and self.local() != 0;
        }
    };

    pub fn init(typ: Object, obj: Object) Value {
        return .{ .typ = typ, .obj = obj };
    }

    /// Convert a Zig error into an error Value.
    pub fn err(e: Error) Value {
        return .init(skript.builtins.type_error, Object.fromError(e));
    }

    /// Plain errors carry an ErrorObject enum directly in Object. Rich errors
    /// carry a Store Ref to data.ErrorObj; its address exceeds the enum range.
    pub const error_payload_max: u64 = 0xFF;

    /// Preserve the source occurrence of an error without changing its Zig
    /// error code. On allocation failure, return the plain error value.
    pub fn errWith(self: *skript.Store, e: Error, src: Value, idx: u32) Value {
        return errWithDetails(self, e, .{ .source = src, .idx = idx }, .nil, &.{});
    }

    /// `frames` must be Store-backed (or empty): GC traces this slice and
    /// every source and filename Value it contains through the rich error object.
    pub fn errWithDetails(
        self: *skript.Store,
        e: Error,
        site: skript.data.ErrorSite,
        raised: Value,
        frames: []const skript.data.ErrorFrame,
    ) Value {
        const ref = self.create(skript.data.ErrorObj) catch return .err(e);
        self.store(skript.data.ErrorObj, ref.deref(skript.data.ErrorObj), .{
            .err = e,
            .site = site,
            .raised = raised,
            .frames = frames,
        });
        return .init(skript.builtins.type_error, ref.toObject());
    }

    /// True when an error Value's payload is a rich ErrorObj Ref rather than
    /// the bare ErrorObject enum.
    pub fn errorPayloadIsRef(obj: Object) bool {
        return @backingInt(obj) > error_payload_max;
    }

    /// The Zig error code of an error Value (either payload form).
    pub fn errorCode(self: Value) Error {
        std.debug.assert(self.typ == skript.builtins.type_error);
        if (errorPayloadIsRef(self.obj)) {
            return self.obj.toRef().deref(skript.data.ErrorObj).err;
        }
        return self.obj.toError();
    }

    /// The source occurrence of a rich error, including the location snapshot.
    pub fn errorSite(self: Value) skript.data.ErrorSite {
        std.debug.assert(self.typ == skript.builtins.type_error);
        if (!errorPayloadIsRef(self.obj)) return .{};
        return self.obj.toRef().deref(skript.data.ErrorObj).site;
    }

    /// The rich location of an error Value: (source tree, DFS index), or
    /// (.nil, 0) for the plain form.
    pub fn errorLocation(self: Value) struct { Value, u32 } {
        const site = self.errorSite();
        return .{ site.source, site.idx };
    }

    /// Captured user `(raise X)` payload, or nil for ordinary system errors.
    pub fn errorRaised(self: Value) Value {
        std.debug.assert(self.typ == skript.builtins.type_error);
        if (!errorPayloadIsRef(self.obj)) return .nil;
        return self.obj.toRef().deref(skript.data.ErrorObj).raised;
    }

    /// Stable call frames of a rich error, innermost first.
    pub fn errorFrames(self: Value) []const skript.data.ErrorFrame {
        std.debug.assert(self.typ == skript.builtins.type_error);
        if (!errorPayloadIsRef(self.obj)) return &.{};
        return self.obj.toRef().deref(skript.data.ErrorObj).frames;
    }

    /// Build a type Value wrapping the type object.
    pub fn typeValue(val: Object) Value {
        return .init(skript.builtins.type_type, val);
    }

    pub fn intrinsic(intr: FuncPtr) Value {
        return .init(skript.builtins.type_intrinsic, .fromPtr(intr));
    }

    pub fn symbol(s: Sym) Value {
        return .init(skript.builtins.type_symbol, @fromBackingInt(@intCast(@intFromPtr(s))));
    }

    pub fn keyword(s: Sym) Value {
        return .init(skript.builtins.type_keyword, @fromBackingInt(@intCast(@intFromPtr(s))));
    }

    pub fn cons(obj: Object) Value {
        return .init(skript.builtins.type_cons, obj);
    }

    pub fn closure(obj: Object) Value {
        return .init(skript.builtins.type_closure, obj);
    }

    pub fn method(obj: Object) Value {
        return .init(skript.builtins.type_method, obj);
    }

    pub fn string(obj: Object) Value {
        return .init(skript.builtins.type_string, obj);
    }

    pub fn byteVector(obj: Object) Value {
        return .init(skript.builtins.type_bytevector, obj);
    }

    pub fn opaq(obj: Object) Value {
        return .init(skript.builtins.type_opaque, obj);
    }

    pub fn pid(obj: Object) Value {
        return .init(skript.builtins.type_pid, obj);
    }

    pub fn ffi(obj: Object) Value {
        return .init(skript.builtins.type_ffifunc, obj);
    }

    pub fn namespace(obj: Object) Value {
        return .init(skript.builtins.type_namespace, obj);
    }

    pub fn tensor(obj: Object) Value {
        return .init(skript.builtins.type_tensor, obj);
    }
    pub fn expr(id: ExprId) Value {
        std.debug.assert(id.isValid());
        return .init(skript.builtins.type_expr, .from(id));
    }

    pub const nil: Value = .{ .typ = skript.builtins.type_nil };
    pub const @"true": Value = .{ .typ = skript.builtins.type_bool, .obj = @fromBackingInt(@intCast(1)) };
    pub const @"false": Value = .{ .typ = skript.builtins.type_bool, .obj = @fromBackingInt(@intCast(0)) };

    pub fn @"bool"(val: bool) Value {
        return if (val) .true else .false;
    }

    /// Truthiness for conditionals (SEM:§3.2): a value is falsy iff it is
    /// nil OR the #f boolean. Every other value — 0, 0.0, "", symbols,
    /// closures, … — is truthy. The #f case is tested by PAYLOAD (a typed
    /// bool check), never by bit pattern: 0 and +0.0 (zero bit patterns) are
    /// truthy, unlike the old Object.toBool discriminant rule where 0/0.0/#f
    /// were all falsy and -0.0 was truthy (inconsistent).
    ///
    /// NOTE: the semantics-control design doc's headline rule is "only nil is
    /// false"; its cond/when/unless test battery and the tranche acceptance
    /// criteria keep `#f` falsy, so the operative rule is nil-or-#f.
    pub inline fn isTruthy(v: Value) bool {
        return v.typ != skript.builtins.type_nil and
            !(v.typ == skript.builtins.type_bool and !v.obj.toBool());
    }

    pub fn @"f16"(val: f16) Value {
        return .init(skript.builtins.type_f16, .fromf16(val));
    }

    pub fn @"f32"(val: f32) Value {
        return .init(skript.builtins.type_f32, .fromf32(val));
    }

    pub fn @"f64"(val: f64) Value {
        return .init(skript.builtins.type_f64, .fromf64(val));
    }

    pub fn @"u8"(val: u8) Value {
        return .init(skript.builtins.type_u8, .from(val));
    }

    pub fn @"u16"(val: u16) Value {
        return .init(skript.builtins.type_u16, .from(val));
    }

    pub fn @"u32"(val: u32) Value {
        return .init(skript.builtins.type_u32, .from(val));
    }

    pub fn @"i8"(val: i8) Value {
        return .init(skript.builtins.type_i8, .from(val));
    }

    pub fn @"i16"(val: i16) Value {
        return .init(skript.builtins.type_i16, .from(val));
    }

    pub fn @"i32"(val: i32) Value {
        return .init(skript.builtins.type_i32, .from(val));
    }

    pub fn @"u64"(val: u64) Value {
        return .init(skript.builtins.type_u64, .from(val));
    }

    pub fn @"i64"(val: i64) Value {
        return .init(skript.builtins.type_i64, .from(val));
    }

    /// Construct a c16 from a pair of f16 values. Internally stored as [4]f16.
    pub fn c16(val: [2]f16) Value {
        const data: [4]f16 = .{ val[0], val[1], 0, 0 };
        return .init(skript.builtins.type_c16, .from(data));
    }

    pub fn c32(val: [2]f32) Value {
        return .init(skript.builtins.type_c32, .from(val));
    }

    pub fn c64(val: Object) Value {
        return .init(skript.builtins.type_c64, val);
    }

    pub fn isNil(val: Value) bool {
        return std.meta.eql(val, .nil);
    }

    pub fn isBool(val: Value) bool {
        return std.meta.eql(val.typ, skript.builtins.type_bool);
    }

    pub fn isCons(val: Value) bool {
        return std.meta.eql(val.typ, skript.builtins.type_cons);
    }

    pub fn isDouble(val: Value) bool {
        return std.meta.eql(val.typ, skript.builtins.type_f64);
    }

    pub fn isString(val: Value) bool {
        return std.meta.eql(val.typ, skript.builtins.type_string);
    }

    pub fn isOpaque(val: Value) bool {
        return std.meta.eql(val.typ, skript.builtins.type_opaque);
    }

    pub fn isPid(val: Value) bool {
        return std.meta.eql(val.typ, skript.builtins.type_pid);
    }

    pub fn isType(val: Value) bool {
        return std.meta.eql(val.typ, skript.builtins.type_type);
    }

    pub fn isFfi(val: Value) bool {
        return std.meta.eql(val.typ, skript.builtins.type_ffifunc);
    }

    pub fn isTensor(val: Value) bool {
        return std.meta.eql(val.typ, skript.builtins.type_tensor);
    }
    pub fn isExpr(val: Value) bool {
        return std.meta.eql(val.typ, skript.builtins.type_expr);
    }

    pub fn isByteVector(self: Value) bool {
        return self.typ == skript.builtins.type_bytevector;
    }

    /// Return the immutable byte slice held by this ByteVector.
    pub fn byteVectorBytes(self: Value) Error![]const u8 {
        if (!self.isByteVector()) return error.TypeMismatch;
        return self.obj.toRef().deref(ByteVectorData).bytes;
    }

    pub fn exprId(self: Value) Error!ExprId {
        if (!self.isExpr()) return error.TypeMismatch;
        const id: ExprId = @fromBackingInt(@intCast(self.obj.toInt(u64)));
        if (!id.isValid()) return error.TypeMismatch;
        return id;
    }

    /// Convert an error Value back to a Zig error. Returns non-error values unchanged.
    pub fn unwrapError(self: Value) Error!Value {
        if (self.typ == skript.builtins.type_error) return self.errorCode();
        return self;
    }

    /// Returns the value if non-nil, or Zig null for the nil value.
    pub fn unwrapNil(self: Value) ?Value {
        return if (std.meta.eql(self, Value.nil)) null else self;
    }
};

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
        std.testing.refAllDecls(Value);
    }
}

test "null round-trip" {
    try std.testing.expect(std.meta.eql(Value.nil, Value.nil));
    try std.testing.expect(Value.isNil(Value.nil));
    try std.testing.expectEqual(@as(?Value, null), Value.nil.unwrapNil());
}

test "bool round-trip" {
    const val = Value.bool(true);
    try std.testing.expect(Value.isBool(val));
    try std.testing.expect(val.obj.toBool());
    try std.testing.expectEqual(Value.true, val);

    const f_val = Value.bool(false);
    try std.testing.expect(!f_val.obj.toBool());
    try std.testing.expectEqual(Value.false, f_val);
}

test "f16 round-trip" {
    const val: f16 = 3.14;
    const got = Value.f16(val);
    try std.testing.expectEqual(val, got.obj.tof16());
}

test "f32 round-trip" {
    const val: f32 = 3.14;
    const got = Value.f32(val);
    try std.testing.expectEqual(val, got.obj.tof32());
}

test "f64 round-trip" {
    const val: f64 = 3.141592653589793;
    const got = Value.f64(val);
    try std.testing.expectEqual(val, got.obj.tof64());
}

test "u32 round-trip" {
    const val: u32 = 42;
    const got = Value.u32(val);
    try std.testing.expectEqual(val, got.obj.toInt(u32));
}

test "i32 round-trip" {
    const val: i32 = -42;
    const got = Value.i32(val);
    try std.testing.expectEqual(val, got.obj.toInt(i32));
}

test "u64 round-trip" {
    const val: u64 = 0xDEADBEEF;
    const got = Value.u64(val);
    try std.testing.expectEqual(val, got.obj.toInt(u64));
}

test "i64 round-trip" {
    const val: i64 = -0xDEADBEEF;
    const got = Value.i64(val);
    try std.testing.expectEqual(val, got.obj.toInt(i64));
}

test "c16 round-trip" {
    const val: [2]f16 = .{ 1.5, 2.5 };
    const got = Value.c16(val);
    const back = got.obj.as([4]f16);
    try std.testing.expectEqual(val[0], back[0]);
    try std.testing.expectEqual(val[1], back[1]);
    try std.testing.expectEqual(@as(f16, 0), back[2]); // zero-padded
    try std.testing.expectEqual(@as(f16, 0), back[3]);
}

test "c32 round-trip" {
    const val: [2]f32 = .{ 1.5, 2.5 };
    const got = Value.c32(val);
    const back = got.obj.as([2]f32);
    try std.testing.expectEqual(val[0], back[0]);
    try std.testing.expectEqual(val[1], back[1]);
}

test "constructor round-trip: init" {
    const val = Value.init(skript.builtins.type_f64, Object.fromf64(3.14));
    try std.testing.expect(std.meta.eql(skript.builtins.type_f64, val.typ));
    try std.testing.expectEqual(@as(f64, 3.14), val.obj.tof64());
}

test "constructor round-trip: err" {
    const val = Value.err(error.Unsupported);
    try std.testing.expectEqual(error.Unsupported, val.unwrapError());
}

test "constructor round-trip: typeValue" {
    const val = Value.typeValue(skript.builtins.type_bool);
    try std.testing.expect(Value.isType(val));
    try std.testing.expect(std.meta.eql(skript.builtins.type_bool, val.obj));
}

test "constructor round-trip: intrinsic" {
    const fn_ptr: FuncPtr = @ptrCast(&Value.isNil);
    const val = Value.intrinsic(fn_ptr);
    try std.testing.expect(std.meta.eql(val.typ, skript.builtins.type_intrinsic));
    try std.testing.expectEqual(fn_ptr, val.obj.toPtr(FuncPtr));
}

test "constructor round-trip: symbol" {
    var name: []const u8 = "hello";
    const sym: Sym = &name;
    const val = Value.symbol(sym);
    try std.testing.expect(std.meta.eql(val.typ, skript.builtins.type_symbol));
    try std.testing.expectEqual(sym, val.obj.toPtr(Sym));
}

test "constructor round-trip: cons, closure, method, string, opaq, ffi, namespace" {
    const obj: Object = @fromBackingInt(@intCast(@as(u64, 42)));
    try std.testing.expect(std.meta.eql(Value.cons(obj).obj, obj));
    try std.testing.expectEqual(skript.builtins.type_cons, Value.cons(obj).typ);
    try std.testing.expect(std.meta.eql(Value.closure(obj).obj, obj));
    try std.testing.expectEqual(skript.builtins.type_closure, Value.closure(obj).typ);
    try std.testing.expect(std.meta.eql(Value.method(obj).obj, obj));
    try std.testing.expectEqual(skript.builtins.type_method, Value.method(obj).typ);
    try std.testing.expect(std.meta.eql(Value.string(obj).obj, obj));
    try std.testing.expectEqual(skript.builtins.type_string, Value.string(obj).typ);
    try std.testing.expect(std.meta.eql(Value.opaq(obj).obj, obj));
    try std.testing.expectEqual(skript.builtins.type_opaque, Value.opaq(obj).typ);
    try std.testing.expect(std.meta.eql(Value.ffi(obj).obj, obj));
    try std.testing.expectEqual(skript.builtins.type_ffifunc, Value.ffi(obj).typ);
    try std.testing.expect(std.meta.eql(Value.namespace(obj).obj, obj));
    try std.testing.expectEqual(skript.builtins.type_namespace, Value.namespace(obj).typ);
}

test "type predicates" {
    try std.testing.expect(Value.isNil(Value.nil));
    try std.testing.expect(Value.isBool(Value.true));
    try std.testing.expect(Value.isBool(Value.false));
    try std.testing.expect(!Value.isBool(Value.nil));
    try std.testing.expect(Value.isDouble(Value.f64(1.0)));
    try std.testing.expect(!Value.isDouble(Value.f32(1.0)));
    try std.testing.expect(Value.isString(Value.string(.null)));
    try std.testing.expect(Value.isOpaque(Value.opaq(.null)));
    try std.testing.expect(Value.isType(Value.typeValue(.null)));
    try std.testing.expect(Value.isFfi(Value.ffi(.null)));
    try std.testing.expect(Value.isCons(Value.cons(.null)));
}

test "unwrapNil: non-null value returns self" {
    const val = Value.f64(42.0);
    try std.testing.expectEqual(@as(?Value, val), val.unwrapNil());
}

test "unwrapError: non-error returns self" {
    const val = Value.f64(42.0);
    try std.testing.expectEqual(val, try val.unwrapError());
}

test "edge cases: f16 extremes" {
    try std.testing.expectEqual(@as(f16, 0.0), Value.f16(0.0).obj.tof16());
    try std.testing.expectEqual(@as(f16, -0.0), Value.f16(-0.0).obj.tof16());
    try std.testing.expectEqual(@as(f16, std.math.inf(f16)), Value.f16(std.math.inf(f16)).obj.tof16());
    try std.testing.expectEqual(@as(f16, -std.math.inf(f16)), Value.f16(-std.math.inf(f16)).obj.tof16());
}

test "edge cases: u32/i32 boundaries" {
    try std.testing.expectEqual(@as(u32, 0), Value.u32(0).obj.toInt(u32));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), Value.u32(std.math.maxInt(u32)).obj.toInt(u32));
    try std.testing.expectEqual(@as(i32, std.math.minInt(i32)), Value.i32(std.math.minInt(i32)).obj.toInt(i32));
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), Value.i32(std.math.maxInt(i32)).obj.toInt(i32));
}
