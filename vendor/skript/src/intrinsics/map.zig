const std = @import("std");

const skript = @import("../root.zig");
const Object = skript.Object;
const Value = skript.Value;
const Error = skript.Error;
const Runtime = skript.Runtime;
const EvalContext = skript.EvalContext;

const intrin = @import("root.zig");
const tracy = @import("tracy");

const MapKey = skript.data.MapKey;
/// MapKeys use exact tag/value identity; strings and bytevectors compare and
/// hash by content, so symbols and keywords remain distinct.
const Map = skript.data.RuntimeMap;
const MapHolder = skript.data.MapHolder;

pub const EqualityView = struct {
    map: *const Map,

    pub const Entry = struct {
        key: MapKey,
        value: Value,
    };

    pub const Iterator = struct {
        inner: Map.Iterator,

        pub fn next(self: *Iterator) ?Entry {
            const entry = self.inner.next() orelse return null;
            return .{ .key = entry.key_ptr.*, .value = entry.value_ptr.* };
        }
    };

    pub fn count(self: EqualityView) usize {
        return self.map.count();
    }

    pub fn iterator(self: EqualityView) Iterator {
        return .{ .inner = self.map.iterator() };
    }

    pub fn get(self: EqualityView, ctx: *EvalContext, key: MapKey) Error!?Value {
        try chargeProbe(ctx, self.map, key);
        return self.map.get(key);
    }
};

pub fn equalityView(value: Value) EqualityView {
    const holder = value.obj.toRef().deref(MapHolder);
    return .{ .map = holder.map };
}

fn chargeWork(ctx: *EvalContext, count: usize) Error!void {
    const count_u64 = std.math.cast(u64, count) orelse return error.Unsupported;
    try ctx.chargeWork(count_u64, 1, .native);
}

/// Charge a hash probe and its worst-case bounded content equality work.
fn chargeProbe(ctx: *EvalContext, map: *const Map, key: MapKey) Error!void {
    const capacity = map.capacity();
    const bound: u64 = if (capacity == 0) 1 else capacity;
    var cost: u64 = 1;
    if (key.typ == @as(u8, @intCast(@intFromEnum(skript.builtins.type_string)))) {
        const bytes = try ctx.stringBytes(
            key.obj.toPtr([*:0]const u8),
            skript.data.map_key_bytes_max,
            .native,
        );
        const byte_count = std.math.cast(u64, bytes.len) orelse return error.Unsupported;
        cost = std.math.add(u64, byte_count, 1) catch return error.Unsupported;
    } else if (key.typ == @as(u8, @intCast(@intFromEnum(skript.builtins.type_bytevector)))) {
        const bytes = key.obj.toRef().deref(Value.ByteVector).bytes;
        const byte_count = std.math.cast(u64, bytes.len) orelse return error.Unsupported;
        cost = std.math.add(u64, byte_count, 1) catch return error.Unsupported;
    }
    try ctx.chargeWork(bound, cost, .native);
}

/// Return a validated, non-owning lookup key with the `equal?` type contract.
/// String and bytevector keys are limited to 1 MiB and cache their content hash.
pub fn keyOf(ctx: *EvalContext, value: Value) Error!MapKey {
    const typ: u8 = @intCast(@intFromEnum(value.typ));
    if (value.typ == skript.builtins.type_symbol or value.typ == skript.builtins.type_keyword) {
        return .{ .typ = typ, .obj = value.obj };
    }

    if (value.typ == skript.builtins.type_string) {
        const bytes = try ctx.stringBytes(
            value.obj.toPtr([*:0]const u8),
            skript.data.map_key_bytes_max,
            .native,
        );
        try chargeWork(ctx, bytes.len);
        return .{
            .typ = typ,
            .obj = value.obj,
            .cached_hash = std.hash.Wyhash.hash(typ, bytes),
        };
    }

    if (value.typ == skript.builtins.type_bytevector) {
        const bytes = try value.byteVectorBytes();
        if (bytes.len > skript.data.map_key_bytes_max) return error.Unsupported;
        try chargeWork(ctx, bytes.len);
        return .{
            .typ = typ,
            .obj = value.obj,
            .cached_hash = std.hash.Wyhash.hash(typ, bytes),
        };
    }

    switch (value.typ) {
        skript.builtins.type_nil,
        skript.builtins.type_bool,
        skript.builtins.type_i8,
        skript.builtins.type_i16,
        skript.builtins.type_i32,
        skript.builtins.type_i64,
        skript.builtins.type_u8,
        skript.builtins.type_u16,
        skript.builtins.type_u32,
        skript.builtins.type_u64,
        => return .{ .typ = typ, .obj = value.obj },
        skript.builtins.type_f16 => {
            const number = value.obj.tof16();
            if (std.math.isNan(number)) return error.Unsupported;
            return .{ .typ = typ, .obj = if (number == 0.0) Value.f16(0.0).obj else value.obj };
        },
        skript.builtins.type_f32 => {
            const number = value.obj.tof32();
            if (std.math.isNan(number)) return error.Unsupported;
            return .{ .typ = typ, .obj = if (number == 0.0) Value.f32(0.0).obj else value.obj };
        },
        skript.builtins.type_f64 => {
            const number = value.obj.tof64();
            if (std.math.isNan(number)) return error.Unsupported;
            return .{ .typ = typ, .obj = if (number == 0.0) Value.f64(0.0).obj else value.obj };
        },
        else => return error.TypeMismatch,
    }
}

/// Copy validated string and bytevector keys into the destination Store.
pub fn ownKey(ctx: *EvalContext, key: MapKey) Error!MapKey {
    if (key.typ == @as(u8, @intCast(@intFromEnum(skript.builtins.type_string)))) {
        const bytes = try ctx.stringBytes(
            key.obj.toPtr([*:0]const u8),
            skript.data.map_key_bytes_max,
            .native,
        );
        try chargeWork(ctx, bytes.len);
        const allocation = try ctx.runtime.store.allocSlice(u8, bytes.len + 1);
        @memcpy(allocation.slice[0..bytes.len], bytes);
        allocation.slice[bytes.len] = 0;
        return .{
            .typ = key.typ,
            .obj = Object.fromPtr(allocation.slice.ptr),
            .cached_hash = key.cached_hash,
            .owned_ref = allocation.ref,
        };
    }
    if (key.typ == @as(u8, @intCast(@intFromEnum(skript.builtins.type_bytevector)))) {
        const bytes = key.obj.toRef().deref(Value.ByteVector).bytes;
        if (bytes.len > skript.data.map_key_bytes_max) return error.Unsupported;
        try chargeWork(ctx, bytes.len);
        const allocation = try ctx.runtime.store.allocSlice(u8, bytes.len);
        errdefer ctx.runtime.store.discardUnpublished(allocation.ref) catch unreachable;
        @memcpy(allocation.slice, bytes);
        const reference = try ctx.runtime.store.create(Value.ByteVector);
        ctx.runtime.store.store(Value.ByteVector, reference.deref(Value.ByteVector), .{
            .bytes = allocation.slice,
        });
        return .{
            .typ = key.typ,
            .obj = reference.toObject(),
            .cached_hash = key.cached_hash,
            .owned_ref = reference,
            .owned_data_ref = allocation.ref,
        };
    }
    return key;
}

fn discardOwnedKey(store: *skript.Store, key: MapKey) void {
    if (!key.owned_ref.isNull()) store.discardUnpublished(key.owned_ref) catch unreachable;
    if (!key.owned_data_ref.isNull()) store.discardUnpublished(key.owned_data_ref) catch unreachable;
}

/// Reconstruct the exact Value represented by a stored MapKey.
pub fn keyValue(key: MapKey) Value {
    return Value.init(@enumFromInt(key.typ), key.obj);
}

/// Create a new map from alternating key-value pairs.
/// `(hash-map k1 v1 k2 v2 ...)` — keys are nil, bool, fixed-width numbers,
/// strings, bytevectors, symbols, or keywords. Duplicate keys overwrite (last wins).
pub fn create(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    if (args.len % 2 != 0) return error.ArityMismatch;
    try chargeWork(ctx, args.len / 2);

    const alloc = ctx.runtime.store.accountedAllocator();
    const map_ptr = try alloc.create(Map);
    map_ptr.* = Map.init(alloc);
    errdefer {
        var entries = map_ptr.iterator();
        while (entries.next()) |entry| discardOwnedKey(ctx.runtime.store, entry.key_ptr.*);
        map_ptr.deinit();
        alloc.destroy(map_ptr);
    }

    const ref = try ctx.runtime.store.createManaged(
        MapHolder,
        skript.data.traceMapHolder,
        skript.data.finalizeMapHolder,
    );
    errdefer ctx.runtime.store.discardUnpublished(ref) catch unreachable;
    const ptr = ref.deref(MapHolder);
    ptr.* = .{ .map = map_ptr, .allocator = alloc };
    const obj = ref.toObject();
    var index: usize = 0;
    while (index < args.len) : (index += 2) {
        const key = try keyOf(ctx, args[index]);
        try chargeProbe(ctx, map_ptr, key);
        if (map_ptr.getPtr(key)) |value_ptr| {
            try ctx.check();
            value_ptr.* = args[index + 1];
            continue;
        }
        try ctx.check();
        map_ptr.ensureUnusedCapacity(1) catch |err| {
            try ctx.check();
            return err;
        };
        try chargeProbe(ctx, map_ptr, key);
        const owned_key = try ownKey(ctx, key);
        errdefer discardOwnedKey(ctx.runtime.store, owned_key);
        try ctx.check();
        map_ptr.putAssumeCapacity(owned_key, args[index + 1]);
    }

    return .init(skript.builtins.type_map, obj);
}

/// Look up a key in a map. Returns the value or nil.
pub fn get(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    const zone = tracy.Zone.begin(.{ .name = "map-get", .src = @src() });
    defer zone.end();
    try intrin.arityAssert(args, 2);
    try intrin.typeAssert(args[0], skript.builtins.type_map);
    const key = try keyOf(ctx, args[1]);

    const holder = args[0].obj.toRef().deref(MapHolder);
    try chargeProbe(ctx, holder.map, key);
    return holder.map.get(key) orelse Value.nil;
}

/// Insert or update a key. Returns the previous value or nil.
pub fn set(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    const zone = tracy.Zone.begin(.{ .name = "map-set", .src = @src() });
    defer zone.end();
    try intrin.arityAssert(args, 3);
    try intrin.typeAssert(args[0], skript.builtins.type_map);
    const key = try keyOf(ctx, args[1]);

    const holder = args[0].obj.toRef().deref(MapHolder);
    try chargeProbe(ctx, holder.map, key);
    if (holder.map.getPtr(key)) |value_ptr| {
        const previous = value_ptr.*;
        try ctx.check();
        value_ptr.* = args[2];
        return previous;
    }
    try ctx.check();
    holder.map.ensureUnusedCapacity(1) catch |err| {
        try ctx.check();
        return err;
    };
    try chargeProbe(ctx, holder.map, key);
    const owned_key = try ownKey(ctx, key);
    errdefer discardOwnedKey(ctx.runtime.store, owned_key);
    try ctx.check();
    holder.map.putAssumeCapacity(owned_key, args[2]);
    return .nil;
}

/// Return true when the map contains the key.
pub fn has(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    try intrin.typeAssert(args[0], skript.builtins.type_map);
    const key = try keyOf(ctx, args[1]);

    const holder = args[0].obj.toRef().deref(MapHolder);
    try chargeProbe(ctx, holder.map, key);
    return if (holder.map.contains(key)) .true else .false;
}

/// `(map-keys m)` reconstructs all stored key Values as a list in unspecified order.
pub fn keys(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_map);

    const holder = args[0].obj.toRef().deref(MapHolder);
    try chargeWork(ctx, holder.map.count());
    var head: Value = .nil;
    var tail: ?*[2]Value = null;
    var iterator = holder.map.iterator();
    while (iterator.next()) |entry| {
        const ref = try ctx.runtime.store.create([2]Value);
        const cell = ref.deref([2]Value);
        cell[0] = keyValue(entry.key_ptr.*);
        if (tail) |previous| {
            previous[1] = Value.cons(ref.toObject());
        } else {
            head = Value.cons(ref.toObject());
        }
        tail = cell;
    }
    if (tail) |last| last[1] = .nil;
    return head;
}

/// `(map-vals m)` returns the values in the same iteration order as map-keys.
pub fn vals(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_map);

    const holder = args[0].obj.toRef().deref(MapHolder);
    try chargeWork(ctx, holder.map.count());
    var head: Value = .nil;
    var tail: ?*[2]Value = null;
    var iterator = holder.map.iterator();
    while (iterator.next()) |entry| {
        const ref = try ctx.runtime.store.create([2]Value);
        const cell = ref.deref([2]Value);
        cell[0] = entry.value_ptr.*;
        if (tail) |previous| {
            previous[1] = Value.cons(ref.toObject());
        } else {
            head = Value.cons(ref.toObject());
        }
        tail = cell;
    }
    if (tail) |last| last[1] = .nil;
    return head;
}

/// Return the number of entries in a map.
pub fn size(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 1);
    try intrin.typeAssert(args[0], skript.builtins.type_map);

    const holder = args[0].obj.toRef().deref(MapHolder);
    return .i64(std.math.cast(i64, holder.map.count()) orelse return error.Unsupported);
}

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
    }
}

fn initTestingRuntime() !*Runtime {
    return Runtime.init(std.testing.allocator, std.testing.io);
}

test "map: symbol keys" {
    const runtime = try initTestingRuntime();
    defer runtime.deinit();

    const x = try runtime.store.getsym("x");
    // (hash-map 'x 1)
    const m = try create(runtime.context(), .nil, .nil, &.{ .symbol(x), .i64(1) });
    // (map-get m 'x) => 1
    const got = try get(runtime.context(), .nil, .nil, &.{ m, .symbol(x) });
    try std.testing.expectEqual(@as(i64, 1), got.obj.toInt(i64));
}

test "map: keyword keys" {
    const runtime = try initTestingRuntime();
    defer runtime.deinit();

    const x = try runtime.store.getsym("x");
    // (hash-map :x 1)
    const m = try create(runtime.context(), .nil, .nil, &.{ .keyword(x), .i64(1) });
    // (map-get m :x) => 1
    const got = try get(runtime.context(), .nil, .nil, &.{ m, .keyword(x) });
    try std.testing.expectEqual(@as(i64, 1), got.obj.toInt(i64));
    // (map-get m 'x) on the same map => nil: 'x and :x are distinct keys
    const miss = try get(runtime.context(), .nil, .nil, &.{ m, .symbol(x) });
    try std.testing.expectEqual(Value.nil, miss);
}

test "map: symbol and keyword keys coexist" {
    const runtime = try initTestingRuntime();
    defer runtime.deinit();

    const x = try runtime.store.getsym("x");
    // (hash-map 'x 1 :x 2) — both keys in one map
    const m = try create(
        runtime.context(),
        .nil,
        .nil,
        &.{ .symbol(x), .i64(1), .keyword(x), .i64(2) },
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        (try get(runtime.context(), .nil, .nil, &.{ m, .symbol(x) })).obj.toInt(i64),
    );
    try std.testing.expectEqual(
        @as(i64, 2),
        (try get(runtime.context(), .nil, .nil, &.{ m, .keyword(x) })).obj.toInt(i64),
    );
}

test "map: map-set! finds the key by type and sym" {
    const runtime = try initTestingRuntime();
    defer runtime.deinit();

    const x = try runtime.store.getsym("x");
    const m = try create(
        runtime.context(),
        .nil,
        .nil,
        &.{ .symbol(x), .i64(1), .keyword(x), .i64(2) },
    );
    // (map-set! m 'x 10) — updates only the symbol entry
    const prev = try set(runtime.context(), .nil, .nil, &.{ m, .symbol(x), .i64(10) });
    try std.testing.expectEqual(@as(i64, 1), prev.obj.toInt(i64));
    try std.testing.expectEqual(
        @as(i64, 10),
        (try get(runtime.context(), .nil, .nil, &.{ m, .symbol(x) })).obj.toInt(i64),
    );
    try std.testing.expectEqual(
        @as(i64, 2),
        (try get(runtime.context(), .nil, .nil, &.{ m, .keyword(x) })).obj.toInt(i64),
    );
    // (map-set! m :x 20) — updates only the keyword entry
    const prev_kwd = try set(runtime.context(), .nil, .nil, &.{ m, .keyword(x), .i64(20) });
    try std.testing.expectEqual(@as(i64, 2), prev_kwd.obj.toInt(i64));
    try std.testing.expectEqual(
        @as(i64, 10),
        (try get(runtime.context(), .nil, .nil, &.{ m, .symbol(x) })).obj.toInt(i64),
    );
    try std.testing.expectEqual(
        @as(i64, 20),
        (try get(runtime.context(), .nil, .nil, &.{ m, .keyword(x) })).obj.toInt(i64),
    );
}

test "map: error contracts" {
    const runtime = try initTestingRuntime();
    defer runtime.deinit();

    const x = try runtime.store.getsym("x");
    // Odd arg count => ArityMismatch
    try std.testing.expectError(
        error.ArityMismatch,
        create(runtime.context(), .nil, .nil, &.{ .symbol(x), .i64(1), .symbol(x) }),
    );
    // Mutable, recursive, and other unsupported composite values are not map keys.
    const unsupported: Value = .cons(.null);
    try std.testing.expectError(error.TypeMismatch, create(runtime.context(), .nil, .nil, &.{ unsupported, .i64(2) }));

    const m = try create(runtime.context(), .nil, .nil, &.{ .symbol(x), .i64(1) });
    try std.testing.expectError(error.TypeMismatch, get(runtime.context(), .nil, .nil, &.{ m, unsupported }));
    try std.testing.expectError(error.TypeMismatch, set(runtime.context(), .nil, .nil, &.{ m, unsupported, .i64(2) }));
    try std.testing.expectError(error.TypeMismatch, has(runtime.context(), .nil, .nil, &.{ m, unsupported }));
}

fn testingByteVector(runtime: *Runtime, bytes: []const u8) !Value {
    const allocation = try runtime.store.allocSlice(u8, bytes.len);
    @memcpy(allocation.slice, bytes);
    const reference = try runtime.store.create(Value.ByteVector);
    runtime.store.store(Value.ByteVector, reference.deref(Value.ByteVector), .{
        .bytes = allocation.slice,
    });
    return Value.byteVector(reference.toObject());
}

test "map: mutable and cyclic values are rejected before insertion" {
    const runtime = try initTestingRuntime();
    defer runtime.deinit();

    const cyclic_ref = try runtime.store.create([2]Value);
    const cyclic = Value.cons(cyclic_ref.toObject());
    cyclic_ref.deref([2]Value).* = .{ cyclic, .nil };
    const unsupported = [_]Value{
        cyclic,
        Value.init(skript.builtins.type_map, .null),
        Value.tensor(.null),
        Value.opaq(.null),
    };
    const map = try create(runtime.context(), .nil, .nil, &.{ Value.i64(1), .i64(1) });
    for (unsupported) |key| {
        try std.testing.expectError(error.TypeMismatch, create(runtime.context(), .nil, .nil, &.{ key, .i64(2) }));
        try std.testing.expectError(error.TypeMismatch, set(runtime.context(), .nil, .nil, &.{ map, key, .i64(2) }));
    }
    try std.testing.expectEqual(@as(i64, 1), (try size(runtime.context(), .nil, .nil, &.{map})).obj.toInt(i64));
}

test "map: bytevector keys use bounded content equality and owned copies" {
    const runtime = try initTestingRuntime();
    defer runtime.deinit();

    const original_bytes = [_]u8{ 0, 255, 7 };
    const backing = try runtime.store.allocSlice(u8, original_bytes.len);
    @memcpy(backing.slice, &original_bytes);
    const backing_ref = try runtime.store.create(Value.ByteVector);
    runtime.store.store(Value.ByteVector, backing_ref.deref(Value.ByteVector), .{
        .bytes = backing.slice,
    });
    const first = Value.byteVector(backing_ref.toObject());
    const same_content = try testingByteVector(runtime, &original_bytes);
    const different = try testingByteVector(runtime, &.{ 0, 255, 8 });
    const empty_first = try testingByteVector(runtime, &.{});
    const empty_second = try testingByteVector(runtime, &.{});
    const map = try create(runtime.context(), .nil, .nil, &.{
        first,        .i64(1),
        same_content, .i64(2),
        different,    .i64(3),
        empty_first,  .i64(4),
        empty_second, .i64(5),
    });

    try std.testing.expectEqual(@as(i64, 3), (try size(runtime.context(), .nil, .nil, &.{map})).obj.toInt(i64));
    try std.testing.expectEqual(Value.i64(2), try get(runtime.context(), .nil, .nil, &.{ map, same_content }));
    try std.testing.expectEqual(Value.i64(3), try get(runtime.context(), .nil, .nil, &.{ map, different }));
    try std.testing.expectEqual(Value.i64(5), try get(runtime.context(), .nil, .nil, &.{ map, empty_first }));

    backing.slice[0] = 42;
    const stable = try testingByteVector(runtime, &original_bytes);
    const changed = try testingByteVector(runtime, backing.slice);
    try std.testing.expectEqual(Value.i64(2), try get(runtime.context(), .nil, .nil, &.{ map, stable }));
    try std.testing.expectEqual(Value.nil, try get(runtime.context(), .nil, .nil, &.{ map, changed }));
    try std.testing.expectEqual(Value.i64(2), try set(runtime.context(), .nil, .nil, &.{ map, stable, .i64(9) }));

    var listed = try keys(runtime.context(), .nil, .nil, &.{map});
    var listed_count: usize = 0;
    while (listed.typ == skript.builtins.type_cons) {
        const cell = listed.obj.toRef().deref([2]Value);
        try std.testing.expectEqual(Value.true, try has(runtime.context(), .nil, .nil, &.{ map, cell[0] }));
        listed = cell[1];
        listed_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), listed_count);

    const reordered = try create(runtime.context(), .nil, .nil, &.{
        stable,       .i64(9),
        empty_second, .i64(5),
        different,    .i64(3),
    });
    try std.testing.expectEqual(Value.true, try intrin.equal.equal(
        runtime.context(),
        .nil,
        .nil,
        &.{ map, reordered },
    ));
}

test "map: bytevector key scans honor the finite work budget" {
    const runtime = try initTestingRuntime();
    defer runtime.deinit();

    const bytes = [_]u8{0xFF} ** 64;
    const key = try testingByteVector(runtime, &bytes);
    const map = try create(runtime.context(), .nil, .nil, &.{ key, .i64(1) });

    var budget = EvalContext.Budget.init(runtime.io, 8_341, .{ .work = 10_000 });
    var lease = try EvalContext.Budget.Lease.root(&budget, 20);
    var account = EvalContext.Budget.AccountAllocator.init(std.testing.allocator, &lease, .native);
    var output_bytes: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_bytes);
    var context = try EvalContext.limited(
        runtime,
        runtime.intrinsics.registryVersion(),
        &account,
        .{ .writer = &writer, .bounded_memory = true },
        .{},
    );
    try std.testing.expectError(error.Exhausted, get(&context, .nil, .nil, &.{ map, key }));
}

test "map: string key scans honor the finite work budget" {
    const runtime = try initTestingRuntime();
    defer runtime.deinit();

    const bytes = [_]u8{'x'} ** 64;
    const key = try intrin.string.storeString(runtime.context(), &bytes);
    const map = try create(runtime.context(), .nil, .nil, &.{ key, .i64(1) });

    var budget = EvalContext.Budget.init(runtime.io, 8_341, .{ .work = 10_000 });
    var lease = try EvalContext.Budget.Lease.root(&budget, 20);
    var account = EvalContext.Budget.AccountAllocator.init(std.testing.allocator, &lease, .native);
    var output_bytes: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_bytes);
    var context = try EvalContext.limited(
        runtime,
        runtime.intrinsics.registryVersion(),
        &account,
        .{ .writer = &writer, .bounded_memory = true },
        .{},
    );
    try std.testing.expectError(error.Exhausted, get(&context, .nil, .nil, &.{ map, key }));
}

test "map: scalar keys preserve type and equality identity" {
    // The runtime prelude and this map fixture exceed the default test Store.
    const runtime = try Runtime.initWithConfig(
        std.testing.allocator,
        std.testing.io,
        .{ .max_heap_size = 8 * 1024 * 1024 },
    );
    defer runtime.deinit();

    const scalar_keys = [_]Value{
        .nil,
        .false,
        .true,
        Value.i8(1),
        Value.i16(1),
        Value.i32(1),
        Value.i64(1),
        Value.u8(1),
        Value.u16(1),
        Value.u32(1),
        Value.u64(1),
        Value.f16(1.0),
        Value.f32(1.0),
        Value.f64(1.0),
    };
    var args: [scalar_keys.len * 2]Value = undefined;
    for (scalar_keys, 0..) |key, index| {
        args[index * 2] = key;
        args[index * 2 + 1] = Value.i64(@intCast(index));
    }

    const map = try create(runtime.context(), .nil, .nil, &args);
    const count = try size(runtime.context(), .nil, .nil, &.{map});
    try std.testing.expectEqual(@as(i64, scalar_keys.len), count.obj.toInt(i64));
    for (scalar_keys, 0..) |key, index| {
        const got = try get(runtime.context(), .nil, .nil, &.{ map, key });
        try std.testing.expectEqual(Value.i64(@intCast(index)), got);
        try std.testing.expectEqual(Value.true, try has(runtime.context(), .nil, .nil, &.{ map, key }));
    }
    var reconstructed_keys = try keys(runtime.context(), .nil, .nil, &.{map});
    var reconstructed_count: usize = 0;
    while (reconstructed_keys.typ == skript.builtins.type_cons) {
        const cell = reconstructed_keys.obj.toRef().deref([2]Value);
        const reconstructed_key = try keyOf(runtime.context(), cell[0]);
        try std.testing.expect(map.obj.toRef().deref(MapHolder).map.contains(reconstructed_key));
        reconstructed_keys = cell[1];
        reconstructed_count += 1;
    }
    try std.testing.expectEqual(scalar_keys.len, reconstructed_count);
    try std.testing.expectEqual(skript.builtins.type_nil, reconstructed_keys.typ);

    var reverse_args: [scalar_keys.len * 2]Value = undefined;
    for (scalar_keys, 0..) |key, index| {
        const reverse_index = scalar_keys.len - index - 1;
        reverse_args[reverse_index * 2] = key;
        reverse_args[reverse_index * 2 + 1] = Value.i64(@intCast(index));
    }
    const reversed = try create(runtime.context(), .nil, .nil, &reverse_args);
    try std.testing.expectEqual(Value.true, try intrin.equal.equal(runtime.context(), .nil, .nil, &.{ map, reversed }));

    var unequal_args = reverse_args;
    unequal_args[1] = Value.i64(99);
    const unequal = try create(runtime.context(), .nil, .nil, &unequal_args);
    try std.testing.expectEqual(Value.false, try intrin.equal.equal(runtime.context(), .nil, .nil, &.{ map, unequal }));

    const previous = try set(runtime.context(), .nil, .nil, &.{ map, Value.i64(1), Value.i64(99) });
    try std.testing.expectEqual(Value.i64(6), previous);
    try std.testing.expectEqual(Value.i64(99), try get(runtime.context(), .nil, .nil, &.{ map, Value.i64(1) }));
    try std.testing.expectEqual(Value.i64(3), try get(runtime.context(), .nil, .nil, &.{ map, Value.i8(1) }));
}

test "map: float zeros share keys and NaN keys are rejected" {
    const runtime = try initTestingRuntime();
    defer runtime.deinit();

    const map = try create(runtime.context(), .nil, .nil, &.{
        Value.f16(0.0),  Value.i64(1),
        Value.f16(-0.0), Value.i64(2),
        Value.f32(0.0),  Value.i64(3),
        Value.f32(-0.0), Value.i64(4),
        Value.f64(0.0),  Value.i64(5),
        Value.f64(-0.0), Value.i64(6),
    });
    const count = try size(runtime.context(), .nil, .nil, &.{map});
    try std.testing.expectEqual(@as(i64, 3), count.obj.toInt(i64));
    try std.testing.expectEqual(Value.i64(2), try get(runtime.context(), .nil, .nil, &.{ map, Value.f16(0.0) }));
    try std.testing.expectEqual(Value.i64(4), try get(runtime.context(), .nil, .nil, &.{ map, Value.f32(-0.0) }));
    try std.testing.expectEqual(Value.i64(6), try get(runtime.context(), .nil, .nil, &.{ map, Value.f64(0.0) }));

    const nan_keys = [_]Value{
        Value.f16(std.math.nan(f16)),
        Value.f32(std.math.nan(f32)),
        Value.f64(std.math.nan(f64)),
    };
    for (nan_keys) |key| {
        try std.testing.expectError(error.Unsupported, create(runtime.context(), .nil, .nil, &.{ key, .i64(1) }));
        try std.testing.expectError(error.Unsupported, get(runtime.context(), .nil, .nil, &.{ map, key }));
        try std.testing.expectError(error.Unsupported, has(runtime.context(), .nil, .nil, &.{ map, key }));
        try std.testing.expectError(error.Unsupported, set(runtime.context(), .nil, .nil, &.{ map, key, .i64(7) }));
    }
}

test "map: strings use content equality and own inserted key bytes" {
    const runtime = try initTestingRuntime();
    defer runtime.deinit();

    const first = try intrin.string.storeString(runtime.context(), "stable");
    const second = try intrin.string.storeString(runtime.context(), "stable");
    const map = try create(runtime.context(), .nil, .nil, &.{
        first,  .i64(1),
        second, .i64(2),
    });
    try std.testing.expectEqual(@as(i64, 1), (try size(runtime.context(), .nil, .nil, &.{map})).obj.toInt(i64));
    try std.testing.expectEqual(Value.i64(2), try get(runtime.context(), .nil, .nil, &.{ map, first }));

    first.obj.toPtr([*:0]u8)[0] = 'X';
    const stable = try intrin.string.storeString(runtime.context(), "stable");
    const changed = try intrin.string.storeString(runtime.context(), "Xtable");
    try std.testing.expectEqual(Value.i64(2), try get(runtime.context(), .nil, .nil, &.{ map, stable }));
    try std.testing.expectEqual(Value.nil, try get(runtime.context(), .nil, .nil, &.{ map, changed }));

    const keys_list = try keys(runtime.context(), .nil, .nil, &.{map});
    const key_cell = keys_list.obj.toRef().deref([2]Value);
    try std.testing.expectEqual(skript.builtins.type_string, key_cell[0].typ);
    try std.testing.expectEqualStrings("stable", std.mem.span(key_cell[0].obj.toPtr([*:0]const u8)));
}

test "map: scalar key collisions and large maps preserve lookups and equality" {
    // The runtime prelude and this 512-entry map fixture exceed the default test Store.
    const runtime = try Runtime.initWithConfig(
        std.testing.allocator,
        std.testing.io,
        .{ .max_heap_size = 8 * 1024 * 1024 },
    );
    defer runtime.deinit();

    const allocator = std.testing.allocator;
    const count: usize = 512;
    const forward = try allocator.alloc(Value, count * 2);
    defer allocator.free(forward);
    const reverse = try allocator.alloc(Value, count * 2);
    defer allocator.free(reverse);

    for (0..count) |index| {
        forward[index * 2] = Value.i64(@intCast(index));
        forward[index * 2 + 1] = Value.i64(@intCast(index * 2));
        const reverse_index = count - index - 1;
        reverse[index * 2] = Value.i64(@intCast(reverse_index));
        reverse[index * 2 + 1] = Value.i64(@intCast(reverse_index * 2));
    }
    const first = try create(runtime.context(), .nil, .nil, forward);
    const second = try create(runtime.context(), .nil, .nil, reverse);
    const table = first.obj.toRef().deref(MapHolder).map;
    const buckets = try allocator.alloc(bool, table.capacity());
    defer allocator.free(buckets);
    @memset(buckets, false);
    var collided = false;
    var iterator = table.iterator();
    while (iterator.next()) |entry| {
        const hash = MapKey.Context.hash(.{}, entry.key_ptr.*);
        const bucket = @as(usize, @intCast(hash % @as(u64, @intCast(buckets.len))));
        if (buckets[bucket]) {
            collided = true;
        } else {
            buckets[bucket] = true;
        }
    }
    try std.testing.expect(collided);

    for (0..count) |index| {
        const key = Value.i64(@intCast(index));
        const value = Value.i64(@intCast(index * 2));
        try std.testing.expectEqual(value, try get(runtime.context(), .nil, .nil, &.{ first, key }));
        try std.testing.expectEqual(value, try get(runtime.context(), .nil, .nil, &.{ second, key }));
    }
    try std.testing.expectEqual(Value.true, try intrin.equal.equal(runtime.context(), .nil, .nil, &.{ first, second }));
}
test "map: map-key constructor rejects overlong string and bytevector keys" {
    // Keep oversized inputs outside the Store so map-key validation reaches its size limit.
    const too_long_string = try std.testing.allocator.alloc(u8, skript.data.map_key_bytes_max + 2);
    defer std.testing.allocator.free(too_long_string);
    @memset(too_long_string, 'x');
    too_long_string[too_long_string.len - 1] = 0;
    const too_long_pointer: [*:0]const u8 = @ptrCast(too_long_string.ptr);
    const string_key = Value.string(.fromPtr(too_long_pointer));

    const too_long_bytes = try std.testing.allocator.alloc(u8, skript.data.map_key_bytes_max + 1);
    defer std.testing.allocator.free(too_long_bytes);
    @memset(too_long_bytes, 0xFF);

    const runtime = try initTestingRuntime();
    defer runtime.deinit();
    const bytevector_ref = try runtime.store.create(Value.ByteVector);
    runtime.store.store(Value.ByteVector, bytevector_ref.deref(Value.ByteVector), .{
        .bytes = too_long_bytes,
    });
    const bytevector_key = Value.byteVector(bytevector_ref.toObject());
    const map = try create(runtime.context(), .nil, .nil, &.{ .i64(1), .i64(1) });

    try std.testing.expectError(
        error.Unsupported,
        create(runtime.context(), .nil, .nil, &.{ string_key, .i64(1) }),
    );
    try std.testing.expectError(
        error.Unsupported,
        get(runtime.context(), .nil, .nil, &.{ map, string_key }),
    );
    try std.testing.expectError(
        error.Unsupported,
        set(runtime.context(), .nil, .nil, &.{ map, bytevector_key, .i64(2) }),
    );
    try std.testing.expectError(
        error.Unsupported,
        has(runtime.context(), .nil, .nil, &.{ map, bytevector_key }),
    );
}

test "hash-map releases cloned keys and unpublished storage when a later key is invalid" {
    const runtime = try initTestingRuntime();
    defer runtime.deinit();

    const string_key = try runtime.evalString("\"owned\"");
    const bytes_key = try runtime.evalString("(ByteVector (u8 7) (u8 8))");
    const invalid_key = try runtime.evalString("(list 1)");
    const raw_before = runtime.store.stats().raw_allocations;
    const live_before = runtime.store.stats().live_objects;
    try std.testing.expectError(error.TypeMismatch, create(
        runtime.context(),
        .nil,
        .nil,
        &.{ string_key, Value.i64(2), bytes_key, Value.i64(4), invalid_key, Value.i64(3) },
    ));
    try std.testing.expectEqual(raw_before, runtime.store.stats().raw_allocations);
    try std.testing.expectEqual(live_before, runtime.store.stats().live_objects);
}

// --- TIER-1 map algorithms (03-collections-algorithms.md §2), full-language ---

fn format(rt: *Runtime, v: Value) ![]const u8 {
    const s = try intrin.print.debugFormatBuiltin(rt.context(), .nil, .nil, &.{v});
    return std.mem.sliceTo(s.obj.toPtr([*]u8), 0);
}

test "map: transform dispatches lists/tensors, hash-map builds dicts" {
    var runtime = try initTestingRuntime();
    defer runtime.deinit();
    try std.testing.expectEqualStrings("(2 4 6)", try format(runtime, try runtime.evalString(
        "(map (list 1 2 3) (fn (x) (* x 2)))",
    )));
    // The transform `map` also forwards to the tensor kernel.
    try std.testing.expectEqualStrings("[2 4 6]", try format(runtime, try runtime.evalString(
        "(map (stack 1 2 3) (fn (x) (* x 2)))",
    )));
    // Dict construction moved to hash-map.
    try std.testing.expectEqualStrings(":v", try format(runtime, try runtime.evalString(
        "(map-get (hash-map :k :v) :k)",
    )));
    // (hash-map) with no args builds an empty dict.
    try std.testing.expectEqual(Value.nil, try runtime.evalString("(map-keys (hash-map))"));
    // hash-map is a pure constructor: it never routes to the transform map.
    try std.testing.expectError(error.TypeMismatch, runtime.evalString("(hash-map (list 1 2) (fn (x) x))"));
    // Non-callable fn on the transform path: ctx.apply's error (stack contract).
    try std.testing.expectError(error.Unimplemented, runtime.evalString("(map (list 1 2) 3)"));
}

test "map: map-has? key membership" {
    var runtime = try initTestingRuntime();
    defer runtime.deinit();
    try std.testing.expectEqual(Value.true, try runtime.evalString("(map-has? (hash-map 'a 1) 'a)"));
    // Symbol/keyword keys are distinct.
    try std.testing.expectEqual(Value.false, try runtime.evalString("(map-has? (hash-map 'a 1) :a)"));
    try std.testing.expectEqual(Value.false, try runtime.evalString("(map-has? (hash-map 'a 1) 'b)"));
    try std.testing.expectEqual(Value.false, try runtime.evalString("(map-has? (hash-map) 'a)"));
    try std.testing.expectEqual(Value.true, try runtime.evalString("(map-has? (hash-map :k 1) :k)"));
    // Aggregate values remain unsupported keys; fixed-width scalars are accepted.
    try std.testing.expectEqual(Value.true, try runtime.evalString("(map-has? (hash-map 1 :one) 1)"));
    try std.testing.expectEqual(Value.false, try runtime.evalString("(map-has? (hash-map 1 :one) 2)"));
    try std.testing.expectError(error.TypeMismatch, runtime.evalString("(map-has? (hash-map 'a 1) (list 1))"));
    try std.testing.expectError(error.TypeMismatch, runtime.evalString("(map-has? 1 'a)"));
}

test "map: map-keys lists the keys" {
    var runtime = try initTestingRuntime();
    defer runtime.deinit();
    try std.testing.expectEqual(Value.i64(2), try runtime.evalString("(length (map-keys (hash-map 'a 1 :b 2)))"));
    try std.testing.expectEqual(Value.nil, try runtime.evalString("(map-keys (hash-map))"));
    try std.testing.expectEqual(Value.true, try runtime.evalString("(contains? (map-keys (hash-map 'a 1 :b 2)) 'a)"));
    try std.testing.expectEqual(Value.false, try runtime.evalString("(contains? (map-keys (hash-map 'a 1)) 'b)"));
    // :a survives as a keyword key, distinct from 'a.
    try std.testing.expectEqual(Value.true, try runtime.evalString("(contains? (map-keys (hash-map :a 1 'b 2)) :a)"));
}

test "map: map-vals lists the values" {
    var runtime = try initTestingRuntime();
    defer runtime.deinit();
    try std.testing.expectEqual(Value.i64(2), try runtime.evalString("(length (map-vals (hash-map 'a 1 :b 2)))"));
    try std.testing.expectEqual(Value.nil, try runtime.evalString("(map-vals (hash-map))"));
    try std.testing.expectEqual(Value.true, try runtime.evalString("(contains? (map-vals (hash-map 'a 1 :b 2)) 2)"));
    try std.testing.expectEqual(Value.false, try runtime.evalString("(contains? (map-vals (hash-map 'a 1)) 9)"));
}

test "map: colliding string hashes still compare key content" {
    const runtime = try initTestingRuntime();
    defer runtime.deinit();

    const first = try intrin.string.storeString(runtime.context(), "first");
    const second = try intrin.string.storeString(runtime.context(), "second");
    const first_key = try keyOf(runtime.context(), first);
    var second_key = try keyOf(runtime.context(), second);
    second_key.cached_hash = first_key.cached_hash;
    try std.testing.expectEqual(
        MapKey.Context.hash(.{}, first_key),
        MapKey.Context.hash(.{}, second_key),
    );
    try std.testing.expect(!MapKey.Context.eql(.{}, first_key, second_key));

    var collision_map = Map.init(runtime.store.allocator());
    defer collision_map.deinit();
    try collision_map.put(first_key, Value.i64(11));
    try collision_map.put(second_key, Value.i64(22));
    try std.testing.expectEqual(@as(usize, 2), collision_map.count());
    try std.testing.expectEqual(Value.i64(11), collision_map.get(first_key).?);
    try std.testing.expectEqual(Value.i64(22), collision_map.get(second_key).?);
}

test "map: map-size counts entries" {
    var runtime = try initTestingRuntime();
    defer runtime.deinit();
    try std.testing.expectEqual(Value.i64(2), try runtime.evalString("(map-size (hash-map 'a 1 :b 2))"));
    try std.testing.expectEqual(Value.i64(0), try runtime.evalString("(map-size (hash-map))"));
    // Duplicate-key constructions collapse (create overwrites).
    try std.testing.expectEqual(Value.i64(1), try runtime.evalString("(map-size (hash-map 'a 1 'a 2))"));
}
test "map backing and owned keys survive Store collection" {
    var runtime = try initTestingRuntime();
    defer runtime.deinit();

    const context = runtime.context();
    const string_key = try intrin.string.storeString(context, "owned-key");
    const retained_value = try intrin.string.storeString(context, "map-value");
    const key_bytes = try runtime.store.allocSlice(u8, 2);
    key_bytes.slice[0] = 0xA5;
    key_bytes.slice[1] = 0x5A;
    const key_bytes_ref = try runtime.store.create(Value.ByteVector);
    runtime.store.store(Value.ByteVector, key_bytes_ref.deref(Value.ByteVector), .{
        .bytes = key_bytes.slice,
    });
    const map = try create(context, .nil, .nil, &.{
        string_key,
        retained_value,
        Value.byteVector(key_bytes_ref.toObject()),
        .i64(42),
    });
    var root = skript.Store.Root.init(map.obj.toRef());
    try runtime.store.registerRoot(&root);
    defer runtime.store.unregisterRoot(&root) catch unreachable;

    try std.testing.expectEqual(@as(usize, 0), runtime.store.stats().raw_allocations);
    try runtime.store.collect(runtime.store.assumeStopped());

    const fresh_string_key = try intrin.string.storeString(context, "owned-key");
    const string_result = try get(context, .nil, .nil, &.{ map, fresh_string_key });
    try std.testing.expectEqualStrings(
        "map-value",
        try context.stringBytes(
            string_result.obj.toPtr([*:0]const u8),
            std.math.maxInt(usize),
            .native,
        ),
    );

    const query_bytes = try runtime.store.allocSlice(u8, 2);
    query_bytes.slice[0] = 0xA5;
    query_bytes.slice[1] = 0x5A;
    const query_bytes_ref = try runtime.store.create(Value.ByteVector);
    runtime.store.store(Value.ByteVector, query_bytes_ref.deref(Value.ByteVector), .{
        .bytes = query_bytes.slice,
    });
    try std.testing.expectEqual(
        Value.i64(42),
        try get(context, .nil, .nil, &.{ map, Value.byteVector(query_bytes_ref.toObject()) }),
    );
}

test "unreachable maps reclaim cloned key Store allocations" {
    var runtime = try initTestingRuntime();
    defer runtime.deinit();

    const live_before = runtime.store.stats().live_objects;
    const key = try intrin.string.storeString(runtime.context(), "unreachable-key");
    _ = try create(runtime.context(), .nil, .nil, &.{ key, .i64(1) });
    try std.testing.expectEqual(@as(usize, 0), runtime.store.stats().raw_allocations);
    try runtime.store.collect(runtime.store.assumeStopped());
    try std.testing.expectEqual(live_before, runtime.store.stats().live_objects);

    const folios_after_collection = runtime.store.stats().folio_count;
    const replacement = try create(runtime.context(), .nil, .nil, &.{ .i64(2), .i64(3) });
    try std.testing.expectEqual(Value.i64(3), try get(
        runtime.context(),
        .nil,
        .nil,
        &.{ replacement, .i64(2) },
    ));
    try std.testing.expectEqual(folios_after_collection, runtime.store.stats().folio_count);
}
