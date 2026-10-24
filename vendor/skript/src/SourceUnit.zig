const std = @import("std");

const skript = @import("root.zig");
const Store = skript.Store;
const Value = skript.Value;
const EvalContext = skript.EvalContext;
pub const SourceUnit = @This();

pub const SourceId = enum(u32) { _ };
pub const Retention = enum { full, datum_only, none };
pub const NodeId = enum(u32) {
    none = std.math.maxInt(u32),
    _,
};

pub const Ref = struct {
    unit: ?*const SourceUnit = null,
    node: NodeId = .none,
};

pub const Span = struct {
    start: u32,
    end: u32,
    line: u32,
    col: u32,
};

pub const Node = struct {
    parent: NodeId = .none,
    span: ?Span = null,
    datum: Value = .nil,
};

pub const ExportLimit = struct {
    max_bytes: usize = 65536,
    max_nodes: usize = 16384,
    max_depth: usize = 4096,
};

id: SourceId,
retention: Retention,
bytes: ?[]const u8,
datum: Value,
nodes: []const Node,
file: ?[:0]const u8 = null,
store: ?*Store = null,

/// Return the exact retained source span named by `ref`.
pub fn text(ref: Ref, max_bytes: usize) skript.Error![]const u8 {
    const unit = ref.unit orelse return error.Unsupported;
    if (ref.node == .none) return error.Unsupported;

    const node_index: usize = @intCast(@backingInt(ref.node));
    if (node_index >= unit.nodes.len) return error.Unsupported;
    const span = unit.nodes[node_index].span orelse return error.Unsupported;
    const bytes = unit.bytes orelse return error.Unsupported;

    if (span.start > span.end) return error.Unsupported;
    const start: usize = @intCast(span.start);
    const end: usize = @intCast(span.end);
    if (end > bytes.len) return error.Unsupported;
    if (end - start > max_bytes) return error.Unsupported;
    if (unit.store) |store| {
        if (EvalContext.currentForStore(store)) |context| {
            try context.check();
            try context.chargeWork(@intCast(end - start), 1, .reader);
        }
    }
    return bytes[start..end];
}

const DatumKind = enum {
    immediate,
    string,
    cons,
    stored_complex,
};

fn datumKind(value: Value) ?DatumKind {
    const builtins = skript.builtins;
    if (value.typ == builtins.type_nil or
        value.typ == builtins.type_bool or
        value.typ == builtins.type_symbol or
        value.typ == builtins.type_keyword)
    {
        return .immediate;
    }
    if (value.typ == builtins.type_string) return .string;
    if (value.typ == builtins.type_cons) return .cons;
    if (value.typ == builtins.type_c64) return .stored_complex;
    const type_index = @backingInt(value.typ);
    if (type_index >= builtins.type_int and type_index <= builtins.type_int_max) {
        return .immediate;
    }
    if (type_index >= builtins.type_uint and type_index <= builtins.type_uint_max) {
        return .immediate;
    }
    if (type_index >= builtins.type_float and type_index <= builtins.type_float_max) {
        return .immediate;
    }
    if (type_index >= builtins.type_complex and type_index <= builtins.type_complex_max) {
        return .immediate;
    }
    return null;
}

fn boundedString(
    pointer: [*:0]const u8,
    max_len: usize,
    context: ?*EvalContext,
) skript.Error![:0]const u8 {
    if (context) |active| return active.stringBytes(pointer, max_len, .reader);
    if (max_len == std.math.maxInt(usize)) return std.mem.span(pointer);
    var length: usize = 0;
    while (true) {
        if (pointer[length] == 0) return pointer[0..length :0];
        if (length == max_len) return error.Unsupported;
        length += 1;
    }
}
fn contextError(context: ?*EvalContext, err: skript.Error) skript.Error {
    if (context) |active| {
        try active.check();
    }
    return err;
}

const Preflight = struct {
    scratch: std.mem.Allocator,
    limit: ExportLimit,
    context: ?*EvalContext = null,
    node_count: usize = 0,
    byte_count: usize = 0,
    active: std.AutoHashMapUnmanaged(usize, void) = .empty,
    fn deinit(self: *Preflight) void {
        self.active.deinit(self.scratch);
        // SAFETY: Preflight is not used after releasing its scratch map.
        self.* = undefined;
    }

    fn visit(self: *Preflight, value: Value, depth: usize) skript.Error!void {
        if (self.context) |context| {
            try context.check();
            const depth_u32 = std.math.cast(u32, depth) orelse return error.Unsupported;
            if (context.budget()) |budget| {
                try budget.checkDepth(depth_u32, .reader);
            }
            try context.charge(.{ .work = 1, .nodes = 1 }, .reader);
        }
        if (depth > self.limit.max_depth) return error.Unsupported;
        if (self.node_count >= self.limit.max_nodes) return error.Unsupported;
        self.node_count += 1;

        const kind = datumKind(value) orelse return error.Unsupported;
        switch (kind) {
            .immediate, .stored_complex => {},
            .string => {
                if (self.byte_count > self.limit.max_bytes) return error.Unsupported;
                const remaining = self.limit.max_bytes - self.byte_count;
                const ptr = value.obj.toPtr([*:0]const u8);
                const string = try boundedString(ptr, remaining, self.context);
                const sum = @addWithOverflow(self.byte_count, string.len);
                if (sum[1] != 0) return error.Unsupported;
                if (sum[0] > self.limit.max_bytes) return error.Unsupported;
                self.byte_count = sum[0];
            },
            .cons => {
                const address = value.obj.toRef().address();
                if (self.active.contains(address)) return error.Unsupported;
                try self.active.put(self.scratch, address, {});
                defer std.debug.assert(self.active.remove(address));

                const pair = value.obj.toRef().deref([2]Value);
                try self.visit(pair[0], depth + 1);
                try self.visit(pair[1], depth + 1);
            },
        }
    }
};

fn cloneDatum(
    store: *Store,
    value: Value,
    max_bytes: usize,
    context: ?*EvalContext,
    depth: usize,
) skript.Error!Value {
    if (context) |active| {
        try active.check();
        const depth_u32 = std.math.cast(u32, depth) orelse return error.Unsupported;
        if (active.budget()) |budget| try budget.checkDepth(depth_u32, .reader);
        try active.charge(.{ .work = 1, .nodes = 1 }, .reader);
    }
    switch (datumKind(value) orelse return error.Unsupported) {
        .immediate => return value,
        .string => {
            const ptr = value.obj.toPtr([*:0]const u8);
            const source = try boundedString(ptr, max_bytes, context);
            const copy = try store.sym_alloc.allocSentinel(u8, source.len, 0);
            @memcpy(copy[0..source.len], source);
            return .string(.fromPtr(copy.ptr));
        },
        .stored_complex => {
            const source = value.obj.toRef().deref([2]f64).*;
            const ref = try store.create([2]f64);
            store.store([2]f64, ref.deref([2]f64), source);
            return .c64(ref.toObject());
        },
        .cons => {
            const source = value.obj.toRef().deref([2]Value);
            const car = try cloneDatum(store, source[0], max_bytes, context, depth + 1);
            const cdr = try cloneDatum(store, source[1], max_bytes, context, depth + 1);
            const ref = try store.create([2]Value);
            store.store([2]Value, ref.deref([2]Value), .{ car, cdr });
            return .cons(ref.toObject());
        },
    }
}

/// Copy a bounded Reader-compatible datum after validating the complete graph.
pub fn snapshot(
    scratch: std.mem.Allocator,
    store: *Store,
    datum: Value,
    limit: ExportLimit,
) skript.Error!Value {
    const context = EvalContext.currentForStore(store);
    if (context) |active| try active.check();
    var preflight: Preflight = .{
        .scratch = scratch,
        .limit = limit,
        .context = context,
    };
    defer preflight.deinit();
    preflight.visit(datum, 1) catch |err| {
        return contextError(context, err);
    };
    return cloneDatum(store, datum, limit.max_bytes, context, 1) catch |err| {
        return contextError(context, err);
    };
}

const testing = std.testing;

test "snapshot rejects a cycle before persistent allocation" {
    const store = try Store.initDefault(testing.allocator, testing.io);
    defer store.deinit();

    const ref = try store.create([2]Value);
    const cycle = Value.cons(ref.toObject());
    store.store([2]Value, ref.deref([2]Value), .{ .i64(1), cycle });
    const heap_used = store.stats().heap_used;

    try testing.expectError(
        error.Unsupported,
        snapshot(testing.allocator, store, cycle, .{}),
    );
    try testing.expectEqual(heap_used, store.stats().heap_used);
}

test "snapshot rejects host capabilities before persistent allocation" {
    const store = try Store.initDefault(testing.allocator, testing.io);
    defer store.deinit();

    var payload: u8 = 0;
    const capability = Value.opaq(.fromPtr(&payload));
    const heap_used = store.stats().heap_used;

    try testing.expectError(
        error.Unsupported,
        snapshot(testing.allocator, store, capability, .{}),
    );
    try testing.expectEqual(heap_used, store.stats().heap_used);
}

test "snapshot is detached from mutable cons and string storage" {
    const store = try Store.initDefault(testing.allocator, testing.io);
    defer store.deinit();

    const source_string = try store.sym_alloc.allocSentinel(u8, 5, 0);
    @memcpy(source_string[0..5], "alpha");
    const source_ref = try store.create([2]Value);
    store.store([2]Value, source_ref.deref([2]Value), .{
        .string(.fromPtr(source_string.ptr)),
        .nil,
    });
    const source = Value.cons(source_ref.toObject());

    const copy = try snapshot(testing.allocator, store, source, .{});
    source_ref.deref([2]Value)[0] = .i64(7);
    source_string[0] = 'x';

    const copied_pair = copy.obj.toRef().deref([2]Value);
    try testing.expect(copy.obj != source.obj);
    try testing.expectEqualStrings(
        "alpha",
        std.mem.span(copied_pair[0].obj.toPtr([*:0]const u8)),
    );
}

test "snapshot enforces node byte and depth limits" {
    const store = try Store.initDefault(testing.allocator, testing.io);
    defer store.deinit();

    const string = try store.sym_alloc.allocSentinel(u8, 4, 0);
    @memcpy(string[0..4], "data");
    const value = Value.string(.fromPtr(string.ptr));

    try testing.expectError(
        error.Unsupported,
        snapshot(testing.allocator, store, value, .{ .max_bytes = 3 }),
    );
    try testing.expectError(
        error.Unsupported,
        snapshot(testing.allocator, store, value, .{ .max_nodes = 0 }),
    );
    try testing.expectError(
        error.Unsupported,
        snapshot(testing.allocator, store, value, .{ .max_depth = 0 }),
    );
}

test "force analysis of all declarations" {
    comptime {
        std.testing.refAllDecls(@This());
        std.testing.refAllDecls(SourceUnit);
    }
}
