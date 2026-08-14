//! Deterministic runtime-value trees for automatic differentiation.
//!
//! A TreeSpec is a flat, allocator-owned structural snapshot. Leaves are
//! occurrences, not object identities: repeated acyclic values produce repeated
//! leaves, while only identities on the active ancestor path are cycles.

const std = @import("std");
const skript = @import("../root.zig");

const Allocator = std.mem.Allocator;
const Error = skript.Error;
const EvalContext = skript.EvalContext;
const Object = skript.Object;
const Sym = skript.Sym;
const Value = skript.Value;
const TensorHolder = skript.intrinsics.tensor.TensorHolder;
const TensorInner = skript.intrinsics.tensor.InnerType;
const map_intrin = skript.intrinsics.map;

const MapHolder = skript.data.MapHolder;

pub const AliasPolicy = enum { occurrence_tree, declared_graph };
pub const CyclePolicy = enum { reject };

/// Limits are part of the operation contract, not hidden implementation caps.
pub const Limits = struct {
    max_depth: usize = 512,
    max_nodes: usize = 1_048_576,
    max_children: usize = 4_194_304,
    max_leaves: usize = 16_777_216,
    max_rank: usize = 1_024,
    max_metadata_depth: usize = 128,
    max_metadata_nodes: usize = 16_384,
    max_metadata_bytes: usize = 1_048_576,

    /// General-purpose limits leave room for future whole-tensor reverse work.
    pub const generic: Limits = .{};

    /// Compatibility limits for the current scalar-sweep gradient engine.
    pub const gradient: Limits = .{
        .max_depth = 128,
        .max_nodes = 16_384,
        .max_children = 16_384,
        .max_leaves = 8_192,
        .max_rank = 16_384,
        .max_metadata_depth = 128,
        .max_metadata_nodes = 16_384,
        .max_metadata_bytes = 1_048_576,
    };
};

pub const NodeId = enum(u32) {
    invalid = std.math.maxInt(u32),
    _,

    pub fn fromIndex(position: usize) Error!NodeId {
        if (position >= std.math.maxInt(u32)) return error.Unsupported;
        return @enumFromInt(@as(u32, @intCast(position)));
    }

    pub fn index(self: NodeId) usize {
        return @intCast(@intFromEnum(self));
    }
};

pub const Range = struct {
    start: u32 = 0,
    len: u32 = 0,

    pub fn init(start: usize, len: usize) Error!Range {
        const start_u32 = std.math.cast(u32, start) orelse return error.Unsupported;
        const len_u32 = std.math.cast(u32, len) orelse return error.Unsupported;
        _ = std.math.add(u32, start_u32, len_u32) catch return error.Unsupported;
        return .{ .start = start_u32, .len = len_u32 };
    }

    pub fn begin(self: Range) usize {
        return self.start;
    }

    pub fn end(self: Range) usize {
        return @as(usize, self.start) + @as(usize, self.len);
    }
};

pub const NumericKind = enum {
    f16,
    f32,
    f64,
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
};

pub fn numericKind(runtime_type: Object) ?NumericKind {
    return switch (runtime_type) {
        skript.builtins.type_f16 => .f16,
        skript.builtins.type_f32 => .f32,
        skript.builtins.type_f64 => .f64,
        skript.builtins.type_i8 => .i8,
        skript.builtins.type_i16 => .i16,
        skript.builtins.type_i32 => .i32,
        skript.builtins.type_i64 => .i64,
        skript.builtins.type_u8 => .u8,
        skript.builtins.type_u16 => .u16,
        skript.builtins.type_u32 => .u32,
        skript.builtins.type_u64 => .u64,
        else => null,
    };
}

pub fn isNumeric(value: Value) bool {
    return numericKind(value.typ) != null;
}

pub fn zero(runtime_type: Object) Error!Value {
    return switch (numericKind(runtime_type) orelse return error.TypeMismatch) {
        .f16 => .f16(0.0),
        .f32 => .f32(0.0),
        .f64 => .f64(0.0),
        .i8 => .i8(0),
        .i16 => .i16(0),
        .i32 => .i32(0),
        .i64 => .i64(0),
        .u8 => .u8(0),
        .u16 => .u16(0),
        .u32 => .u32(0),
        .u64 => .u64(0),
    };
}

pub fn one(runtime_type: Object) Error!Value {
    return switch (numericKind(runtime_type) orelse return error.TypeMismatch) {
        .f16 => .f16(1.0),
        .f32 => .f32(1.0),
        .f64 => .f64(1.0),
        .i8 => .i8(1),
        .i16 => .i16(1),
        .i32 => .i32(1),
        .i64 => .i64(1),
        .u8 => .u8(1),
        .u16 => .u16(1),
        .u32 => .u32(1),
        .u64 => .u64(1),
    };
}

pub fn asF64(value: Value) Error!f64 {
    return switch (numericKind(value.typ) orelse return error.TypeMismatch) {
        .f16 => @floatCast(value.obj.tof16()),
        .f32 => @floatCast(value.obj.tof32()),
        .f64 => value.obj.tof64(),
        .i8 => @floatFromInt(value.obj.toInt(i8)),
        .i16 => @floatFromInt(value.obj.toInt(i16)),
        .i32 => @floatFromInt(value.obj.toInt(i32)),
        .i64 => @floatFromInt(value.obj.toInt(i64)),
        .u8 => @floatFromInt(value.obj.toInt(u8)),
        .u16 => @floatFromInt(value.obj.toInt(u16)),
        .u32 => @floatFromInt(value.obj.toInt(u32)),
        .u64 => @floatFromInt(value.obj.toInt(u64)),
    };
}

fn coerceSigned(comptime T: type, value: Value) Error!T {
    return switch (numericKind(value.typ) orelse return error.TypeMismatch) {
        .i8 => std.math.cast(T, value.obj.toInt(i8)) orelse error.Unsupported,
        .i16 => std.math.cast(T, value.obj.toInt(i16)) orelse error.Unsupported,
        .i32 => std.math.cast(T, value.obj.toInt(i32)) orelse error.Unsupported,
        .i64 => std.math.cast(T, value.obj.toInt(i64)) orelse error.Unsupported,
        .u8 => std.math.cast(T, value.obj.toInt(u8)) orelse error.Unsupported,
        .u16 => std.math.cast(T, value.obj.toInt(u16)) orelse error.Unsupported,
        .u32 => std.math.cast(T, value.obj.toInt(u32)) orelse error.Unsupported,
        .u64 => std.math.cast(T, value.obj.toInt(u64)) orelse error.Unsupported,
        .f16, .f32, .f64 => blk: {
            const number = try asF64(value);
            if (!std.math.isFinite(number)) return error.Unsupported;
            if (std.math.trunc(number) != number) return error.Unsupported;
            const lower: f64 = @floatFromInt(std.math.minInt(T));
            const upper_exclusive: f64 = if (@bitSizeOf(T) == 64)
                9223372036854775808.0
            else
                @floatFromInt(@as(i128, std.math.maxInt(T)) + 1);
            if (number < lower or number >= upper_exclusive) return error.Unsupported;
            break :blk std.math.lossyCast(T, number);
        },
    };
}

fn coerceUnsigned(comptime T: type, value: Value) Error!T {
    return switch (numericKind(value.typ) orelse return error.TypeMismatch) {
        .i8 => std.math.cast(T, value.obj.toInt(i8)) orelse error.Unsupported,
        .i16 => std.math.cast(T, value.obj.toInt(i16)) orelse error.Unsupported,
        .i32 => std.math.cast(T, value.obj.toInt(i32)) orelse error.Unsupported,
        .i64 => std.math.cast(T, value.obj.toInt(i64)) orelse error.Unsupported,
        .u8 => std.math.cast(T, value.obj.toInt(u8)) orelse error.Unsupported,
        .u16 => std.math.cast(T, value.obj.toInt(u16)) orelse error.Unsupported,
        .u32 => std.math.cast(T, value.obj.toInt(u32)) orelse error.Unsupported,
        .u64 => std.math.cast(T, value.obj.toInt(u64)) orelse error.Unsupported,
        .f16, .f32, .f64 => blk: {
            const number = try asF64(value);
            if (!std.math.isFinite(number)) return error.Unsupported;
            if (std.math.trunc(number) != number) return error.Unsupported;
            const upper_exclusive: f64 = if (@bitSizeOf(T) == 64)
                18446744073709551616.0
            else
                @floatFromInt(@as(u128, std.math.maxInt(T)) + 1);
            if (number < 0.0 or number >= upper_exclusive) return error.Unsupported;
            break :blk std.math.lossyCast(T, number);
        },
    };
}

/// Convert a numeric value without silently changing an integer tangent.
pub fn coerceNumeric(runtime_type: Object, value: Value) Error!Value {
    return switch (numericKind(runtime_type) orelse return error.TypeMismatch) {
        .f16 => .f16(@floatCast(try asF64(value))),
        .f32 => .f32(@floatCast(try asF64(value))),
        .f64 => .f64(try asF64(value)),
        .i8 => .i8(try coerceSigned(i8, value)),
        .i16 => .i16(try coerceSigned(i16, value)),
        .i32 => .i32(try coerceSigned(i32, value)),
        .i64 => .i64(try coerceSigned(i64, value)),
        .u8 => .u8(try coerceUnsigned(u8, value)),
        .u16 => .u16(try coerceUnsigned(u16, value)),
        .u32 => .u32(try coerceUnsigned(u32, value)),
        .u64 => .u64(try coerceUnsigned(u64, value)),
    };
}

/// Encode a tangent word using the existing tensor dtype contract.
pub fn tensorWord(inner: TensorInner, value: Value) Error!u64 {
    return switch (inner) {
        .i64 => @bitCast((try coerceNumeric(skript.builtins.type_i64, value)).obj.toInt(i64)),
        .f64 => @bitCast((try coerceNumeric(skript.builtins.type_f64, value)).obj.tof64()),
        .empty => error.TypeMismatch,
        else => error.TypeMismatch,
    };
}

pub const TensorNode = struct {
    inner: TensorInner,
    dimensions: Range,
};

pub const CustomNode = struct {
    registry_version: u64,
    implementation_revision: u64,
    namespace: Value,
    metadata: Value,
    unflatten_hook: Value,
};

pub const NodeKind = union(enum) {
    scalar: NumericKind,
    list,
    map,
    tensor: TensorNode,
    custom: CustomNode,
};

pub const Node = struct {
    kind: NodeKind,
    runtime_type: Object,
    original: Value,
    children: Range = .{},
    keys: Range = .{},
    leaves: Range = .{},
};

/// One deterministic leaf occurrence. Shared backing never merges entries.
pub const Leaf = struct {
    occurrence: u32,
    node: NodeId,
    element: u32,
    runtime_type: Object,
    primal: Value,
};

pub const CustomSpec = struct {
    runtime_type: Object,
    implementation_revision: u64,
    namespace: Value,
    flatten_hook: Value,
    unflatten_hook: Value,
};

pub const Registration = struct {
    runtime_type: Object,
    implementation_revision: u64 = 1,
    namespace: Value = .nil,
    flatten_hook: Value,
    unflatten_hook: Value,
};

pub const RegistryVersion = struct {
    version: u64,
    specs: []const CustomSpec,

    pub fn find(self: *const RegistryVersion, runtime_type: Object) ?*const CustomSpec {
        for (self.specs) |*spec| {
            if (spec.runtime_type == runtime_type) return spec;
        }
        return null;
    }
};

pub const RegistryError = error{
    InvalidRuntimeType,
    InvalidRevision,
    InvalidHook,
    DuplicateRuntimeType,
    VersionOverflow,
};

const SnapshotNode = struct {
    snapshot: *RegistryVersion,
    next: ?*SnapshotNode,
};

/// Runtime-owned immutable registry snapshots. Old TreeSpecs retain valid hooks.
pub const RegistryOwner = struct {
    allocator: Allocator,
    current_version: *RegistryVersion,
    snapshots: ?*SnapshotNode,
    next_version: u64,

    pub fn init(allocator: Allocator) Allocator.Error!RegistryOwner {
        var owner: RegistryOwner = .{
            .allocator = allocator,
            // SAFETY: buildSnapshot initializes this field before init returns.
            .current_version = undefined,
            .snapshots = null,
            .next_version = 2,
        };
        errdefer owner.deinit();
        owner.current_version = try owner.buildSnapshot(&.{}, 1);
        return owner;
    }

    pub fn deinit(self: *RegistryOwner) void {
        var cursor = self.snapshots;
        while (cursor) |node| {
            const next = node.next;
            self.allocator.free(node.snapshot.specs);
            self.allocator.destroy(node.snapshot);
            self.allocator.destroy(node);
            cursor = next;
        }
        self.current_version = undefined;
        self.snapshots = null;
    }

    pub fn current(self: *const RegistryOwner) *const RegistryVersion {
        return self.current_version;
    }

    pub fn publish(
        self: *RegistryOwner,
        registrations: []const Registration,
    ) (RegistryError || Allocator.Error)!*const RegistryVersion {
        if (registrations.len == 0) return self.current_version;
        if (self.next_version == std.math.maxInt(u64)) return error.VersionOverflow;
        for (registrations, 0..) |registration, index| {
            try validateRegistration(registration);
            for (registrations[0..index]) |prior| {
                if (prior.runtime_type == registration.runtime_type) {
                    return error.DuplicateRuntimeType;
                }
            }
        }

        const old = self.current_version.specs;
        var added: usize = 0;
        for (registrations) |registration| {
            var replaces = false;
            for (old) |spec| {
                if (spec.runtime_type == registration.runtime_type) {
                    replaces = true;
                    break;
                }
            }
            if (!replaces) added = std.math.add(usize, added, 1) catch {
                return error.VersionOverflow;
            };
        }
        const total = std.math.add(usize, old.len, added) catch return error.VersionOverflow;
        const candidates = try self.allocator.alloc(CustomSpec, total);
        defer self.allocator.free(candidates);
        @memcpy(candidates[0..old.len], old);
        var used = old.len;
        for (registrations) |registration| {
            const candidate: CustomSpec = .{
                .runtime_type = registration.runtime_type,
                .implementation_revision = registration.implementation_revision,
                .namespace = registration.namespace,
                .flatten_hook = registration.flatten_hook,
                .unflatten_hook = registration.unflatten_hook,
            };
            var replaced = false;
            for (candidates[0..used]) |*existing| {
                if (existing.runtime_type != candidate.runtime_type) continue;
                existing.* = candidate;
                replaced = true;
                break;
            }
            if (!replaced) {
                candidates[used] = candidate;
                used += 1;
            }
        }
        std.debug.assert(used == total);
        const snapshot = try self.buildSnapshot(candidates, self.next_version);
        self.next_version += 1;
        self.current_version = snapshot;
        return snapshot;
    }

    fn buildSnapshot(
        self: *RegistryOwner,
        specs: []const CustomSpec,
        version: u64,
    ) Allocator.Error!*RegistryVersion {
        const owned_specs = try self.allocator.dupe(CustomSpec, specs);
        errdefer self.allocator.free(owned_specs);
        const snapshot = try self.allocator.create(RegistryVersion);
        errdefer self.allocator.destroy(snapshot);
        snapshot.* = .{ .version = version, .specs = owned_specs };
        const node = try self.allocator.create(SnapshotNode);
        node.* = .{ .snapshot = snapshot, .next = self.snapshots };
        self.snapshots = node;
        return snapshot;
    }
};

fn isCallable(value: Value) bool {
    return switch (value.typ) {
        skript.builtins.type_closure,
        skript.builtins.type_intrinsic,
        skript.builtins.type_method,
        => true,
        else => false,
    };
}

fn validateRegistration(registration: Registration) RegistryError!void {
    const type_index = @intFromEnum(registration.runtime_type);
    if (registration.runtime_type == .null or type_index <= skript.builtins.type_last_idx) {
        return error.InvalidRuntimeType;
    }
    if (registration.implementation_revision == 0) return error.InvalidRevision;
    if (!isCallable(registration.flatten_hook)) return error.InvalidHook;
    if (!isCallable(registration.unflatten_hook)) return error.InvalidHook;
}

/// Native ABI entry point. Arguments are Type, positive revision, flatten hook,
/// and unflatten hook. The hook contract is documented on `flatten`.
pub fn registerTree(
    ctx: *EvalContext,
    namespace: Value,
    _: Value,
    args: []const Value,
) Error!Value {
    if (args.len != 4) return error.ArityMismatch;
    if (ctx.execution == .pure_limited) return error.Denied;
    if (ctx.effects.state_write != .allow) return error.Denied;
    if (args[0].typ != skript.builtins.type_type) return error.TypeMismatch;
    if (args[1].typ != skript.builtins.type_i64) return error.TypeMismatch;
    const revision = args[1].obj.toInt(i64);
    if (revision <= 0) return error.TypeMismatch;
    const snapshot = ctx.runtime.tree_registry.publish(&.{.{
        .runtime_type = args[0].obj,
        .implementation_revision = @intCast(revision),
        .namespace = namespace,
        .flatten_hook = args[2],
        .unflatten_hook = args[3],
    }}) catch |publish_error| switch (publish_error) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TypeMismatch,
    };
    const version = std.math.cast(i64, snapshot.version) orelse return error.Unsupported;
    return .i64(version);
}

const Identity = struct {
    runtime_type: Object,
    object: Object,
};

fn sameIdentity(left: Identity, right: Identity) bool {
    return left.runtime_type == right.runtime_type and left.object == right.object;
}

fn chargeWork(ctx: *EvalContext, count: usize) Error!void {
    const count_u64 = std.math.cast(u64, count) orelse return error.Unsupported;
    try ctx.chargeWork(count_u64, 1, .transform);
}

fn restrictedHookContext(ctx: *EvalContext) Error!EvalContext {
    var restricted = try ctx.enter(.transform);
    restricted.execution = .pure_limited;
    // Hook code may read its declared argument state, such as a record field.
    // Keep every other effect denied and never allow hook suspension.
    restricted.effects = .{};
    restricted.effects.state_read = ctx.effects.state_read;
    restricted.allow_suspend = false;
    restricted.reservation = null;
    return restricted;
}

fn callHook(
    ctx: *EvalContext,
    namespace: Value,
    hook: Value,
    args: []const Value,
) Error!Value {
    var restricted = try restrictedHookContext(ctx);
    const scope = restricted.activate();
    defer scope.deinit();
    return (try restricted.apply(namespace, hook, args)).unwrapError();
}

const MetadataState = struct {
    nodes: usize = 0,
    bytes: usize = 0,
};

const Builder = struct {
    ctx: *EvalContext,
    allocator: Allocator,
    registry: *const RegistryVersion,
    limits: Limits,
    nodes: std.ArrayList(Node) = .empty,
    child_nodes: std.ArrayList(NodeId) = .empty,
    map_keys: std.ArrayList(Value) = .empty,
    dimensions: std.ArrayList(u32) = .empty,
    leaves: std.ArrayList(Leaf) = .empty,
    ancestors: std.ArrayList(Identity) = .empty,

    fn deinit(self: *Builder) void {
        self.nodes.deinit(self.allocator);
        self.child_nodes.deinit(self.allocator);
        self.map_keys.deinit(self.allocator);
        self.dimensions.deinit(self.allocator);
        self.leaves.deinit(self.allocator);
        self.ancestors.deinit(self.allocator);
        self.* = undefined;
    }

    fn build(self: *Builder, value: Value, depth: usize) Error!NodeId {
        try chargeWork(self.ctx, 1);
        if (depth >= self.limits.max_depth) return error.Unsupported;
        var child_context = try self.ctx.enter(.transform);
        const scope = child_context.activate();
        defer scope.deinit();
        const parent_context = self.ctx;
        self.ctx = &child_context;
        defer self.ctx = parent_context;

        if (numericKind(value.typ)) |kind| return self.buildScalar(value, kind);
        if (value.typ == skript.builtins.type_tensor) return self.buildTensor(value);
        if (value.typ == skript.builtins.type_nil) return self.buildList(value, depth);
        if (value.typ == skript.builtins.type_cons) {
            try self.pushAncestor(value);
            defer self.popAncestor();
            return self.buildList(value, depth);
        }
        if (value.typ == skript.builtins.type_map) {
            try self.pushAncestor(value);
            defer self.popAncestor();
            return self.buildMap(value, depth);
        }
        if (self.registry.find(value.typ)) |custom| {
            try self.pushAncestor(value);
            defer self.popAncestor();
            return self.buildCustom(value, depth, custom);
        }
        return error.TypeMismatch;
    }

    fn appendNode(self: *Builder, node: Node) Error!NodeId {
        if (self.nodes.items.len >= self.limits.max_nodes) return error.Unsupported;
        const id = try NodeId.fromIndex(self.nodes.items.len);
        try self.nodes.append(self.allocator, node);
        return id;
    }

    fn appendLeaf(
        self: *Builder,
        node: NodeId,
        element: usize,
        runtime_type: Object,
        primal: Value,
    ) Error!void {
        if (self.leaves.items.len >= self.limits.max_leaves) return error.LimitExceeded;
        const occurrence = std.math.cast(u32, self.leaves.items.len) orelse {
            return error.Unsupported;
        };
        const element_u32 = std.math.cast(u32, element) orelse return error.Unsupported;
        try self.leaves.append(self.allocator, .{
            .occurrence = occurrence,
            .node = node,
            .element = element_u32,
            .runtime_type = runtime_type,
            .primal = primal,
        });
    }

    fn reserveChildren(self: *Builder, count: usize) Error!Range {
        const total = std.math.add(usize, self.child_nodes.items.len, count) catch {
            return error.Unsupported;
        };
        if (total > self.limits.max_children) return error.Unsupported;
        const range = try Range.init(self.child_nodes.items.len, count);
        try self.child_nodes.ensureUnusedCapacity(self.allocator, count);
        for (0..count) |_| self.child_nodes.appendAssumeCapacity(.invalid);
        return range;
    }

    fn pushAncestor(self: *Builder, value: Value) Error!void {
        const candidate: Identity = .{ .runtime_type = value.typ, .object = value.obj };
        for (self.ancestors.items) |ancestor| {
            if (sameIdentity(candidate, ancestor)) return error.Unsupported;
        }
        try self.ancestors.append(self.allocator, candidate);
    }

    fn popAncestor(self: *Builder) void {
        _ = self.ancestors.pop() orelse unreachable;
    }

    fn isAncestor(self: *const Builder, value: Value) bool {
        const candidate: Identity = .{ .runtime_type = value.typ, .object = value.obj };
        for (self.ancestors.items) |ancestor| {
            if (sameIdentity(candidate, ancestor)) return true;
        }
        return false;
    }

    fn buildScalar(self: *Builder, value: Value, kind: NumericKind) Error!NodeId {
        const leaf_start = self.leaves.items.len;
        const id = try self.appendNode(.{
            .kind = .{ .scalar = kind },
            .runtime_type = value.typ,
            .original = value,
        });
        try self.appendLeaf(id, 0, value.typ, value);
        self.nodes.items[id.index()].leaves = try Range.init(leaf_start, 1);
        return id;
    }

    fn buildTensor(self: *Builder, value: Value) Error!NodeId {
        const holder = value.obj.toRef().deref(TensorHolder).*;
        const rank = std.math.cast(usize, holder.rank) orelse return error.Unsupported;
        if (rank == 0 or holder.shape.len != rank) return error.TypeMismatch;
        if (rank > self.limits.max_rank) return error.Unsupported;
        if (holder.inner != .i64 and holder.inner != .f64 and holder.inner != .empty) {
            return error.TypeMismatch;
        }
        var expected: usize = 1;
        for (holder.shape) |dimension| {
            try chargeWork(self.ctx, 1);
            expected = std.math.mul(usize, expected, dimension) catch return error.Unsupported;
        }
        if (expected != holder.data.len) return error.TypeMismatch;
        if (holder.inner == .empty and holder.data.len != 0) return error.TypeMismatch;
        if (holder.data.len > self.limits.max_leaves -| self.leaves.items.len) {
            return error.LimitExceeded;
        }

        const dimension_range = try Range.init(self.dimensions.items.len, holder.shape.len);
        try self.dimensions.appendSlice(self.allocator, holder.shape);
        const leaf_start = self.leaves.items.len;
        const id = try self.appendNode(.{
            .kind = .{ .tensor = .{
                .inner = holder.inner,
                .dimensions = dimension_range,
            } },
            .runtime_type = value.typ,
            .original = value,
        });
        for (holder.data, 0..) |word, index| {
            try chargeWork(self.ctx, 1);
            const leaf_value = skript.intrinsics.tensor.wordToValue(holder.inner, word);
            try self.appendLeaf(id, index, leaf_value.typ, leaf_value);
        }
        self.nodes.items[id.index()].leaves = try Range.init(leaf_start, holder.data.len);
        return id;
    }

    fn buildList(self: *Builder, value: Value, depth: usize) Error!NodeId {
        var child_values: std.ArrayList(Value) = .empty;
        defer child_values.deinit(self.allocator);
        var seen: std.AutoHashMapUnmanaged(Object, void) = .empty;
        defer seen.deinit(self.allocator);

        var current = value;
        while (current.typ == skript.builtins.type_cons) {
            try chargeWork(self.ctx, 1);
            if (child_values.items.len >= self.limits.max_children) return error.Unsupported;
            const result = try seen.getOrPut(self.allocator, current.obj);
            if (result.found_existing) return error.Unsupported;
            if (current.obj != value.obj and self.isAncestor(current)) return error.Unsupported;
            const cell = current.obj.toRef().deref([2]Value).*;
            try child_values.append(self.allocator, cell[0]);
            current = cell[1];
        }
        if (current.typ != skript.builtins.type_nil) return error.TypeMismatch;

        const leaf_start = self.leaves.items.len;
        const children = try self.reserveChildren(child_values.items.len);
        const id = try self.appendNode(.{
            .kind = .list,
            .runtime_type = skript.builtins.type_cons,
            .original = value,
            .children = children,
        });
        for (child_values.items, 0..) |child_value, index| {
            const child = try self.build(child_value, depth + 1);
            self.child_nodes.items[children.begin() + index] = child;
        }
        self.nodes.items[id.index()].leaves = try Range.init(
            leaf_start,
            self.leaves.items.len - leaf_start,
        );
        return id;
    }

    fn buildMap(self: *Builder, value: Value, depth: usize) Error!NodeId {
        const holder = value.obj.toRef().deref(MapHolder).*;
        const count = holder.map.count();
        if (count > self.limits.max_children) return error.Unsupported;
        try chargeWork(self.ctx, count);

        var keys: std.ArrayList(Value) = .empty;
        defer keys.deinit(self.allocator);
        try keys.ensureTotalCapacity(self.allocator, count);
        var iterator = holder.map.iterator();
        while (iterator.next()) |entry| {
            keys.appendAssumeCapacity(map_intrin.keyValue(entry.key_ptr.*));
        }
        std.mem.sort(Value, keys.items, {}, mapKeyLessThan);

        const key_range = try Range.init(self.map_keys.items.len, keys.items.len);
        try self.map_keys.appendSlice(self.allocator, keys.items);
        const children = try self.reserveChildren(keys.items.len);
        const leaf_start = self.leaves.items.len;
        const id = try self.appendNode(.{
            .kind = .map,
            .runtime_type = value.typ,
            .original = value,
            .children = children,
            .keys = key_range,
        });
        for (keys.items, 0..) |key, index| {
            const child_value = holder.map.get(try map_intrin.keyOf(self.ctx, key)) orelse return error.InvalidCode;
            const child = try self.build(child_value, depth + 1);
            self.child_nodes.items[children.begin() + index] = child;
        }
        self.nodes.items[id.index()].leaves = try Range.init(
            leaf_start,
            self.leaves.items.len - leaf_start,
        );
        std.debug.assert(key_range.len == children.len);
        return id;
    }

    fn buildCustom(
        self: *Builder,
        value: Value,
        depth: usize,
        custom: *const CustomSpec,
    ) Error!NodeId {
        const hook_result = try callHook(
            self.ctx,
            custom.namespace,
            custom.flatten_hook,
            &.{value},
        );
        const result = try parseFlattenResult(hook_result);
        var metadata_state: MetadataState = .{};
        var metadata_ancestors: std.ArrayList(Identity) = .empty;
        defer metadata_ancestors.deinit(self.allocator);
        try self.validateMetadata(
            result.metadata,
            0,
            &metadata_state,
            &metadata_ancestors,
        );

        var child_values: std.ArrayList(Value) = .empty;
        defer child_values.deinit(self.allocator);
        try collectProperList(
            self.allocator,
            self.ctx,
            result.children,
            self.limits.max_children,
            &child_values,
        );

        const children = try self.reserveChildren(child_values.items.len);
        const leaf_start = self.leaves.items.len;
        const id = try self.appendNode(.{
            .kind = .{ .custom = .{
                .registry_version = self.registry.version,
                .implementation_revision = custom.implementation_revision,
                .namespace = custom.namespace,
                .metadata = result.metadata,
                .unflatten_hook = custom.unflatten_hook,
            } },
            .runtime_type = value.typ,
            .original = value,
            .children = children,
        });
        for (child_values.items, 0..) |child_value, index| {
            const child = try self.build(child_value, depth + 1);
            self.child_nodes.items[children.begin() + index] = child;
        }
        self.nodes.items[id.index()].leaves = try Range.init(
            leaf_start,
            self.leaves.items.len - leaf_start,
        );
        return id;
    }

    fn validateMetadata(
        self: *Builder,
        value: Value,
        depth: usize,
        state: *MetadataState,
        ancestors: *std.ArrayList(Identity),
    ) Error!void {
        try chargeWork(self.ctx, 1);
        if (depth >= self.limits.max_metadata_depth) return error.Unsupported;
        var child_context = try self.ctx.enter(.transform);
        const scope = child_context.activate();
        defer scope.deinit();
        const parent_context = self.ctx;
        self.ctx = &child_context;
        defer self.ctx = parent_context;

        state.nodes = std.math.add(usize, state.nodes, 1) catch return error.Unsupported;
        if (state.nodes > self.limits.max_metadata_nodes) return error.Unsupported;

        if (isStaticAtom(value)) {
            const bytes = try staticAtomBytes(self.ctx, value, self.limits.max_metadata_bytes -| state.bytes);
            state.bytes = std.math.add(usize, state.bytes, bytes) catch return error.Unsupported;
            if (state.bytes > self.limits.max_metadata_bytes) return error.Unsupported;
            return;
        }
        if (value.typ != skript.builtins.type_cons) return error.TypeMismatch;

        const identity: Identity = .{ .runtime_type = value.typ, .object = value.obj };
        for (ancestors.items) |ancestor| {
            if (sameIdentity(identity, ancestor)) return error.Unsupported;
        }
        try ancestors.append(self.allocator, identity);
        defer _ = ancestors.pop();

        var seen: std.AutoHashMapUnmanaged(Object, void) = .empty;
        defer seen.deinit(self.allocator);
        var current = value;
        while (current.typ == skript.builtins.type_cons) {
            const result = try seen.getOrPut(self.allocator, current.obj);
            if (result.found_existing) return error.Unsupported;
            if (current.obj != value.obj) {
                const current_identity: Identity = .{
                    .runtime_type = current.typ,
                    .object = current.obj,
                };
                for (ancestors.items) |ancestor| {
                    if (sameIdentity(current_identity, ancestor)) return error.Unsupported;
                }
            }
            const cell = current.obj.toRef().deref([2]Value).*;
            try self.validateMetadata(cell[0], depth + 1, state, ancestors);
            current = cell[1];
        }
        if (current.typ != skript.builtins.type_nil) return error.TypeMismatch;
    }
};

fn mapKeyLessThan(_: void, left: Value, right: Value) bool {
    if (left.typ != right.typ) return @intFromEnum(left.typ) < @intFromEnum(right.typ);
    const b = skript.builtins;
    if (left.typ == b.type_symbol or left.typ == b.type_keyword) {
        return std.mem.order(u8, left.obj.toPtr(Sym).*, right.obj.toPtr(Sym).*) == .lt;
    }
    if (left.typ == b.type_string) {
        return std.mem.order(
            u8,
            std.mem.span(left.obj.toPtr([*:0]const u8)),
            std.mem.span(right.obj.toPtr([*:0]const u8)),
        ) == .lt;
    }
    if (left.typ == b.type_bytevector) {
        return std.mem.order(
            u8,
            left.byteVectorBytes() catch unreachable,
            right.byteVectorBytes() catch unreachable,
        ) == .lt;
    }
    return @intFromEnum(left.obj) < @intFromEnum(right.obj);
}

fn sameMapKey(left: Value, right: Value) bool {
    if (left.typ != right.typ) return false;
    const b = skript.builtins;
    if (left.typ == b.type_symbol or left.typ == b.type_keyword) {
        return std.mem.eql(u8, left.obj.toPtr(Sym).*, right.obj.toPtr(Sym).*);
    }
    if (left.typ == b.type_string) {
        return std.mem.eql(
            u8,
            std.mem.span(left.obj.toPtr([*:0]const u8)),
            std.mem.span(right.obj.toPtr([*:0]const u8)),
        );
    }
    if (left.typ == b.type_bytevector) {
        return std.mem.eql(
            u8,
            left.byteVectorBytes() catch unreachable,
            right.byteVectorBytes() catch unreachable,
        );
    }
    return left.obj == right.obj;
}

fn parseFlattenResult(value: Value) Error!struct { children: Value, metadata: Value } {
    if (value.typ != skript.builtins.type_cons) return error.TypeMismatch;
    const first = value.obj.toRef().deref([2]Value).*;
    if (first[1].typ != skript.builtins.type_cons) return error.TypeMismatch;
    const second = first[1].obj.toRef().deref([2]Value).*;
    if (second[1].typ != skript.builtins.type_nil) return error.TypeMismatch;
    return .{ .children = first[0], .metadata = second[0] };
}

fn collectProperList(
    allocator: Allocator,
    ctx: *EvalContext,
    value: Value,
    limit: usize,
    output: *std.ArrayList(Value),
) Error!void {
    var seen: std.AutoHashMapUnmanaged(Object, void) = .empty;
    defer seen.deinit(allocator);
    var current = value;
    while (current.typ == skript.builtins.type_cons) {
        try chargeWork(ctx, 1);
        if (output.items.len >= limit) return error.Unsupported;
        const result = try seen.getOrPut(allocator, current.obj);
        if (result.found_existing) return error.Unsupported;
        const cell = current.obj.toRef().deref([2]Value).*;
        try output.append(allocator, cell[0]);
        current = cell[1];
    }
    if (current.typ != skript.builtins.type_nil) return error.TypeMismatch;
}

fn isStaticAtom(value: Value) bool {
    if (numericKind(value.typ) != null) return true;
    return switch (value.typ) {
        skript.builtins.type_nil,
        skript.builtins.type_bool,
        skript.builtins.type_symbol,
        skript.builtins.type_keyword,
        skript.builtins.type_string,
        skript.builtins.type_type,
        => true,
        else => false,
    };
}

fn staticAtomBytes(ctx: *EvalContext, value: Value, remaining: usize) Error!usize {
    return switch (value.typ) {
        skript.builtins.type_symbol,
        skript.builtins.type_keyword,
        => blk: {
            const size = value.obj.toPtr(Sym).*.len;
            if (size > remaining) return error.Unsupported;
            break :blk size;
        },
        skript.builtins.type_string => blk: {
            const bytes = try ctx.stringBytes(
                value.obj.toPtr([*:0]const u8),
                remaining,
                .transform,
            );
            break :blk bytes.len;
        },
        else => 0,
    };
}

/// Immutable, flat tree structure plus its original leaf occurrences.
pub const TreeSpec = struct {
    allocator: Allocator,
    registry: *const RegistryVersion,
    limits: Limits,
    root: NodeId,
    nodes: []Node,
    child_nodes: []NodeId,
    map_keys: []Value,
    dimensions: []u32,
    leaves: []Leaf,
    alias_policy: AliasPolicy = .occurrence_tree,
    cycle_policy: CyclePolicy = .reject,

    pub fn deinit(self: *TreeSpec) void {
        self.allocator.free(self.nodes);
        self.allocator.free(self.child_nodes);
        self.allocator.free(self.map_keys);
        self.allocator.free(self.dimensions);
        self.allocator.free(self.leaves);
        self.* = undefined;
    }

    pub fn node(self: *const TreeSpec, id: NodeId) *const Node {
        std.debug.assert(id.index() < self.nodes.len);
        return &self.nodes[id.index()];
    }

    pub fn children(self: *const TreeSpec, tree_node: *const Node) []const NodeId {
        return self.child_nodes[tree_node.children.begin()..tree_node.children.end()];
    }

    pub fn keys(self: *const TreeSpec, tree_node: *const Node) []const Value {
        std.debug.assert(tree_node.kind == .map);
        return self.map_keys[tree_node.keys.begin()..tree_node.keys.end()];
    }

    pub fn tensorShape(self: *const TreeSpec, tensor: TensorNode) []const u32 {
        return self.dimensions[tensor.dimensions.begin()..tensor.dimensions.end()];
    }

    pub fn containsCustom(self: *const TreeSpec) bool {
        for (self.nodes) |tree_node| {
            if (tree_node.kind == .custom) return true;
        }
        return false;
    }

    /// Rebuild a value from exactly one supplied value per leaf occurrence.
    pub fn unflatten(
        self: *const TreeSpec,
        scratch: Allocator,
        ctx: *EvalContext,
        leaf_values: []const Value,
    ) Error!Value {
        const scope = ctx.activate();
        defer scope.deinit();
        if (leaf_values.len != self.leaves.len) return error.ArityMismatch;
        var rebuilder: Rebuilder = .{
            .spec = self,
            .ctx = ctx,
            .scratch = scratch,
            .leaf_values = leaf_values,
        };
        return rebuilder.build(self.root, 0) catch |err| {
            if (err == error.OutOfMemory) try ctx.check();
            return err;
        };
    }

    /// Check structure, dtype, static metadata, and deterministic leaf order.
    pub fn check(
        self: *const TreeSpec,
        scratch: Allocator,
        ctx: *EvalContext,
        candidate: Value,
    ) Error!void {
        const scope = ctx.activate();
        defer scope.deinit();
        var candidate_spec = try flatten(scratch, ctx, self.registry, candidate, self.limits);
        defer candidate_spec.deinit();
        if (!try sameStructure(ctx, self, &candidate_spec)) return error.TypeMismatch;
    }
};

/// Flatten hooks receive `(value)` and return exactly
/// `(list dynamic-children static-metadata)`. Unflatten hooks receive
/// `(static-metadata dynamic-children-list)`. Both deny mutation, host
/// effects, unknown effects, and suspension; bounded reads of declared
/// argument state are allowed.
pub fn flatten(
    allocator: Allocator,
    ctx: *EvalContext,
    registry: *const RegistryVersion,
    value: Value,
    limits: Limits,
) Error!TreeSpec {
    const scope = ctx.activate();
    defer scope.deinit();
    var builder: Builder = .{
        .ctx = ctx,
        .allocator = allocator,
        .registry = registry,
        .limits = limits,
    };
    defer builder.deinit();
    const root = try builder.build(value, 0);

    const nodes = try builder.nodes.toOwnedSlice(allocator);
    errdefer allocator.free(nodes);
    const child_nodes = try builder.child_nodes.toOwnedSlice(allocator);
    errdefer allocator.free(child_nodes);
    const map_keys = try builder.map_keys.toOwnedSlice(allocator);
    errdefer allocator.free(map_keys);
    const dimensions = try builder.dimensions.toOwnedSlice(allocator);
    errdefer allocator.free(dimensions);
    const leaves = try builder.leaves.toOwnedSlice(allocator);
    errdefer allocator.free(leaves);
    return .{
        .allocator = allocator,
        .registry = registry,
        .limits = limits,
        .root = root,
        .nodes = nodes,
        .child_nodes = child_nodes,
        .map_keys = map_keys,
        .dimensions = dimensions,
        .leaves = leaves,
    };
}

const Rebuilder = struct {
    spec: *const TreeSpec,
    ctx: *EvalContext,
    scratch: Allocator,
    leaf_values: []const Value,

    fn build(self: *Rebuilder, id: NodeId, depth: usize) Error!Value {
        try chargeWork(self.ctx, 1);
        if (depth >= self.spec.limits.max_depth) return error.Unsupported;
        var child_context = try self.ctx.enter(.transform);
        const scope = child_context.activate();
        defer scope.deinit();
        const parent_context = self.ctx;
        self.ctx = &child_context;
        defer self.ctx = parent_context;

        const tree_node = self.spec.node(id);
        return switch (tree_node.kind) {
            .scalar => self.buildScalar(tree_node),
            .tensor => |tensor| self.buildTensor(tree_node, tensor),
            .list => self.buildList(tree_node, depth),
            .map => self.buildMap(tree_node, depth),
            .custom => |custom| self.buildCustom(tree_node, depth, custom),
        };
    }

    fn buildScalar(self: *Rebuilder, tree_node: *const Node) Error!Value {
        if (tree_node.leaves.len != 1) return error.TypeMismatch;
        const index = tree_node.leaves.begin();
        return coerceNumeric(tree_node.runtime_type, self.leaf_values[index]);
    }

    fn buildTensor(self: *Rebuilder, tree_node: *const Node, tensor: TensorNode) Error!Value {
        const shape_source = self.spec.tensorShape(tensor);
        if (tree_node.leaves.len == 0 and tensor.inner != .empty) {
            var product: usize = 1;
            for (shape_source) |dimension| {
                product = std.math.mul(usize, product, dimension) catch return error.Unsupported;
            }
            if (product != 0) return error.TypeMismatch;
        }
        const shape = try self.ctx.runtime.store.allocSlice(u32, shape_source.len);
        errdefer self.ctx.runtime.store.discardUnpublished(shape.ref) catch unreachable;
        @memcpy(shape.slice, shape_source);
        const data = try self.ctx.runtime.store.allocSlice(u64, tree_node.leaves.len);
        errdefer self.ctx.runtime.store.discardUnpublished(data.ref) catch unreachable;
        for (data.slice, 0..) |*word, index| {
            const leaf_index = tree_node.leaves.begin() + index;
            word.* = try tensorWord(tensor.inner, self.leaf_values[leaf_index]);
        }
        const reference = try self.ctx.runtime.store.createTraced(
            TensorHolder,
            skript.intrinsics.tensor.traceTensorHolder,
        );
        reference.deref(TensorHolder).* = .{
            .inner = tensor.inner,
            .rank = @intCast(shape.slice.len),
            .shape = shape.slice,
            .data = data.slice,
            .shape_ref = shape.ref,
            .data_ref = data.ref,
        };
        return .tensor(reference.toObject());
    }

    fn buildList(self: *Rebuilder, tree_node: *const Node, depth: usize) Error!Value {
        var result: Value = .nil;
        var tail: ?*[2]Value = null;
        for (self.spec.children(tree_node)) |child| {
            const reference = try self.ctx.runtime.store.create([2]Value);
            const cell = reference.deref([2]Value);
            cell.* = .{ try self.build(child, depth + 1), .nil };
            const cell_value = Value.cons(reference.toObject());
            if (tail) |previous| {
                previous[1] = cell_value;
            } else {
                result = cell_value;
            }
            tail = cell;
        }
        return result;
    }

    fn buildMap(self: *Rebuilder, tree_node: *const Node, depth: usize) Error!Value {
        const children = self.spec.children(tree_node);
        const keys = self.spec.keys(tree_node);
        if (children.len != keys.len) return error.TypeMismatch;
        const pair_count = std.math.mul(usize, children.len, 2) catch {
            return error.Unsupported;
        };
        const pairs = try self.scratch.alloc(Value, pair_count);
        defer self.scratch.free(pairs);
        for (children, keys, 0..) |child, key, index| {
            pairs[index * 2] = key;
            pairs[index * 2 + 1] = try self.build(child, depth + 1);
        }
        return map_intrin.create(self.ctx, .nil, .nil, pairs);
    }

    fn buildCustom(
        self: *Rebuilder,
        tree_node: *const Node,
        depth: usize,
        custom: CustomNode,
    ) Error!Value {
        const children = self.spec.children(tree_node);
        const child_values = try self.scratch.alloc(Value, children.len);
        defer self.scratch.free(child_values);
        for (children, child_values) |child, *value| {
            value.* = try self.build(child, depth + 1);
        }
        const child_list = try makeList(self.ctx, child_values);
        const result = try callHook(
            self.ctx,
            custom.namespace,
            custom.unflatten_hook,
            &.{ custom.metadata, child_list },
        );
        if (result.typ != tree_node.runtime_type) return error.TypeMismatch;
        return result;
    }
};

fn makeList(ctx: *EvalContext, values: []const Value) Error!Value {
    var result: Value = .nil;
    var index = values.len;
    while (index > 0) {
        try chargeWork(ctx, 1);
        index -= 1;
        const reference = try ctx.runtime.store.create([2]Value);
        reference.deref([2]Value).* = .{ values[index], result };
        result = .cons(reference.toObject());
    }
    return result;
}

pub fn sameStructure(ctx: *EvalContext, left: *const TreeSpec, right: *const TreeSpec) Error!bool {
    if (left.nodes.len != right.nodes.len) return false;
    if (left.child_nodes.len != right.child_nodes.len) return false;
    if (left.map_keys.len != right.map_keys.len) return false;
    if (left.dimensions.len != right.dimensions.len) return false;
    if (left.leaves.len != right.leaves.len) return false;
    if (!std.mem.eql(NodeId, left.child_nodes, right.child_nodes)) return false;
    if (!std.mem.eql(u32, left.dimensions, right.dimensions)) return false;
    for (left.map_keys, right.map_keys) |left_key, right_key| {
        if (!sameMapKey(left_key, right_key)) return false;
    }
    for (left.leaves, right.leaves) |left_leaf, right_leaf| {
        if (left_leaf.occurrence != right_leaf.occurrence) return false;
        if (left_leaf.node != right_leaf.node) return false;
        if (left_leaf.element != right_leaf.element) return false;
        if (left_leaf.runtime_type != right_leaf.runtime_type) return false;
    }
    for (left.nodes, right.nodes) |left_node, right_node| {
        if (left_node.runtime_type != right_node.runtime_type) return false;
        if (!std.meta.eql(left_node.children, right_node.children)) return false;
        if (!std.meta.eql(left_node.keys, right_node.keys)) return false;
        if (!std.meta.eql(left_node.leaves, right_node.leaves)) return false;
        if (std.meta.activeTag(left_node.kind) != std.meta.activeTag(right_node.kind)) {
            return false;
        }
        switch (left_node.kind) {
            .scalar => |left_kind| {
                if (left_kind != right_node.kind.scalar) return false;
            },
            .list, .map => {},
            .tensor => |left_tensor| {
                const right_tensor = right_node.kind.tensor;
                if (left_tensor.inner != right_tensor.inner) return false;
                if (!std.meta.eql(left_tensor.dimensions, right_tensor.dimensions)) return false;
            },
            .custom => |left_custom| {
                const right_custom = right_node.kind.custom;
                if (left_custom.registry_version != right_custom.registry_version) return false;
                if (left_custom.implementation_revision != right_custom.implementation_revision) {
                    return false;
                }
                var remaining = left.limits.max_metadata_nodes;
                if (!try staticEqual(ctx, left_custom.metadata, right_custom.metadata, &remaining)) {
                    return false;
                }
            },
        }
    }
    return true;
}

fn staticEqual(
    ctx: *EvalContext,
    left: Value,
    right: Value,
    remaining: *usize,
) Error!bool {
    var child_context = try ctx.enter(.transform);
    const scope = child_context.activate();
    defer scope.deinit();
    if (remaining.* == 0) return error.Unsupported;
    remaining.* -= 1;
    if (left.typ != right.typ) return false;
    if (left.typ == skript.builtins.type_string) {
        const left_bytes = std.mem.span(left.obj.toPtr([*:0]const u8));
        const right_bytes = std.mem.span(right.obj.toPtr([*:0]const u8));
        return std.mem.eql(u8, left_bytes, right_bytes);
    }
    if (left.typ == skript.builtins.type_symbol or
        left.typ == skript.builtins.type_keyword)
    {
        return std.mem.eql(u8, left.obj.toPtr(Sym).*, right.obj.toPtr(Sym).*);
    }
    if (left.typ != skript.builtins.type_cons) return left.obj == right.obj;

    var left_current = left;
    var right_current = right;
    while (left_current.typ == skript.builtins.type_cons and
        right_current.typ == skript.builtins.type_cons)
    {
        const left_cell = left_current.obj.toRef().deref([2]Value).*;
        const right_cell = right_current.obj.toRef().deref([2]Value).*;
        if (!try staticEqual(&child_context, left_cell[0], right_cell[0], remaining)) {
            return false;
        }
        left_current = left_cell[1];
        right_current = right_cell[1];
    }
    return left_current.typ == skript.builtins.type_nil and
        right_current.typ == skript.builtins.type_nil;
}
test "TreeSpec keeps repeated list occurrences independent" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const input = try rt.evalString("(list 2 2)");
    var spec = try flatten(std.testing.allocator, rt.context(), rt.tree_registry.current(), input, Limits.gradient);
    defer spec.deinit();
    try std.testing.expectEqual(@as(usize, 2), spec.leaves.len);
    const rebuilt = try spec.unflatten(std.testing.allocator, rt.context(), &.{ Value.f64(3.0), Value.f64(4.0) });
    try std.testing.expectEqual(skript.builtins.type_cons, rebuilt.typ);
    const first = rebuilt.obj.toRef().deref([2]Value).*;
    try std.testing.expectEqual(@as(i64, 3), first[0].obj.toInt(i64));
    const second = first[1].obj.toRef().deref([2]Value).*;
    try std.testing.expectEqual(@as(i64, 4), second[0].obj.toInt(i64));
}

test "TreeSpec rejects active cons cycles" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const reference = try rt.store.create([2]Value);
    reference.deref([2]Value).* = .{ Value.i64(1), .cons(reference.toObject()) };
    try std.testing.expectError(
        error.Unsupported,
        flatten(
            std.testing.allocator,
            rt.context(),
            rt.tree_registry.current(),
            .cons(reference.toObject()),
            Limits.gradient,
        ),
    );
}
test "TreeSpec preserves tensor shape and empty storage" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const ctx = rt.context();
    const input = try rt.evalString("(stack (stack 1 2) (stack 3 4))");
    var spec = try flatten(std.testing.allocator, ctx, rt.tree_registry.current(), input, Limits.gradient);
    defer spec.deinit();
    switch (spec.node(spec.root).kind) {
        .tensor => |tensor| {
            try std.testing.expectEqualSlices(u32, &.{ 2, 2 }, spec.tensorShape(tensor));
            try std.testing.expectEqual(@as(usize, 4), spec.leaves.len);
        },
        else => return error.TestUnexpectedResult,
    }
    const empty = try rt.evalString("(stack)");
    var empty_spec = try flatten(std.testing.allocator, ctx, rt.tree_registry.current(), empty, Limits.gradient);
    defer empty_spec.deinit();
    switch (empty_spec.node(empty_spec.root).kind) {
        .tensor => |tensor| {
            try std.testing.expectEqualSlices(u32, &.{0}, empty_spec.tensorShape(tensor));
            try std.testing.expectEqual(@as(usize, 0), empty_spec.leaves.len);
        },
        else => return error.TestUnexpectedResult,
    }
}

const TestPointRecord = struct {
    x: Value,
    y: Value,
    label: Value,
};

fn testPointType(ctx: *EvalContext, namespace: Value) Error!Object {
    const binding = try ctx.runtime.store.getsym("Point");
    const type_value = try ctx.runtime.nsGet(namespace, binding);
    if (type_value.typ != skript.builtins.type_type) return error.TypeMismatch;
    return type_value.obj;
}

fn testPointPayload(
    ctx: *EvalContext,
    namespace: Value,
    value: Value,
) Error!*const TestPointRecord {
    if (value.typ != try testPointType(ctx, namespace)) return error.TypeMismatch;
    return value.obj.toRef().deref(TestPointRecord);
}

fn testPointConstruct(
    ctx: *EvalContext,
    namespace: Value,
    _: Value,
    args: []const Value,
) Error!Value {
    if (args.len != 3) return error.ArityMismatch;
    if (args[0].typ != skript.builtins.type_f64) return error.TypeMismatch;
    if (args[1].typ != skript.builtins.type_f64) return error.TypeMismatch;
    if (args[2].typ != skript.builtins.type_symbol) return error.TypeMismatch;
    const reference = try ctx.runtime.store.create(TestPointRecord);
    ctx.runtime.store.store(TestPointRecord, reference.deref(TestPointRecord), .{
        .x = args[0],
        .y = args[1],
        .label = args[2],
    });
    return .init(try testPointType(ctx, namespace), reference.toObject());
}

fn testPointX(
    ctx: *EvalContext,
    namespace: Value,
    _: Value,
    args: []const Value,
) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    return (try testPointPayload(ctx, namespace, args[0])).x;
}

fn testPointY(
    ctx: *EvalContext,
    namespace: Value,
    _: Value,
    args: []const Value,
) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    return (try testPointPayload(ctx, namespace, args[0])).y;
}

fn testPointLabel(
    ctx: *EvalContext,
    namespace: Value,
    _: Value,
    args: []const Value,
) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    return (try testPointPayload(ctx, namespace, args[0])).label;
}

fn testPointFlattenNative(
    ctx: *EvalContext,
    namespace: Value,
    _: Value,
    args: []const Value,
) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    const point = try testPointPayload(ctx, namespace, args[0]);
    const children = try makeList(ctx, &.{ point.x, point.y });
    const metadata = try makeList(ctx, &.{point.label});
    return makeList(ctx, &.{ children, metadata });
}

fn testPointUnflattenNative(
    ctx: *EvalContext,
    namespace: Value,
    _: Value,
    args: []const Value,
) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (args[0].typ != skript.builtins.type_cons) return error.TypeMismatch;
    if (args[1].typ != skript.builtins.type_cons) return error.TypeMismatch;
    const metadata = args[0].obj.toRef().deref([2]Value).*;
    if (metadata[1].typ != skript.builtins.type_nil) return error.TypeMismatch;
    const first = args[1].obj.toRef().deref([2]Value).*;
    if (first[1].typ != skript.builtins.type_cons) return error.TypeMismatch;
    const second = first[1].obj.toRef().deref([2]Value).*;
    if (second[1].typ != skript.builtins.type_nil) return error.TypeMismatch;
    return testPointConstruct(
        ctx,
        namespace,
        .nil,
        &.{ first[0], second[0], metadata[0] },
    );
}

fn installTestPoint(rt: *skript.Runtime) !Object {
    _ = try rt.intrinsics.publish(&.{
        .{
            .stable_name = "test.autodiff.point-construct",
            .invoke = .nativePtr(&testPointConstruct),
            .effects = .none,
            .callbacks = .none,
            .resources = .native,
            .suspension = .never,
        },
        .{
            .stable_name = "test.autodiff.point-x",
            .invoke = .nativePtr(&testPointX),
            .effects = .{ .state_read = true },
            .reads_argument_state = true,
            .callbacks = .none,
            .resources = .native,
            .suspension = .never,
        },
        .{
            .stable_name = "test.autodiff.point-y",
            .invoke = .nativePtr(&testPointY),
            .effects = .{ .state_read = true },
            .reads_argument_state = true,
            .callbacks = .none,
            .resources = .native,
            .suspension = .never,
        },
        .{
            .stable_name = "test.autodiff.point-label",
            .invoke = .nativePtr(&testPointLabel),
            .effects = .{ .state_read = true },
            .reads_argument_state = true,
            .callbacks = .none,
            .resources = .native,
            .suspension = .never,
        },
    });

    const type_name = try rt.store.getsym("Point");
    const type_reference = try rt.store.create(skript.Type);
    rt.store.store(skript.Type, type_reference.deref(skript.Type), .{
        .meta = skript.builtins.type_type,
        .name = Object.fromPtr(type_name),
        .apply = .intrinsic(&testPointConstruct),
    });
    const runtime_type = type_reference.toObject();
    try rt.nsBind(rt.root_ns, type_name, .typeValue(runtime_type));
    try rt.nsBind(
        rt.root_ns,
        try rt.store.getsym("point-x"),
        .intrinsic(&testPointX),
    );
    try rt.nsBind(
        rt.root_ns,
        try rt.store.getsym("point-y"),
        .intrinsic(&testPointY),
    );
    try rt.nsBind(
        rt.root_ns,
        try rt.store.getsym("point-label"),
        .intrinsic(&testPointLabel),
    );
    return runtime_type;
}

fn installSkriptTestPointTree(rt: *skript.Runtime) !Object {
    const point_type = try installTestPoint(rt);
    const flatten_hook = try rt.evalString(
        \\(fn (point)
        \\  (list
        \\    (list (point-x point) (point-y point))
        \\    (list (point-label point))))
    );
    const unflatten_hook = try rt.evalString(
        \\(fn (metadata children)
        \\  (Point
        \\    (fst children)
        \\    (fst (rst children))
        \\    (fst metadata)))
    );
    _ = try registerTree(
        rt.context(),
        rt.root_ns,
        .nil,
        &.{ .typeValue(point_type), .i64(7), flatten_hook, unflatten_hook },
    );
    return point_type;
}

fn installNativeTestPointTree(rt: *skript.Runtime) !Object {
    const point_type = try installTestPoint(rt);
    _ = try rt.intrinsics.publish(&.{
        .{
            .stable_name = "test.autodiff.point-flatten",
            .invoke = .nativePtr(&testPointFlattenNative),
            .effects = .{ .state_read = true },
            .reads_argument_state = true,
            .callbacks = .none,
            .resources = .native,
            .suspension = .never,
        },
        .{
            .stable_name = "test.autodiff.point-unflatten",
            .invoke = .nativePtr(&testPointUnflattenNative),
            .effects = .{ .state_read = true },
            .reads_argument_state = true,
            .callbacks = .none,
            .resources = .native,
            .suspension = .never,
        },
    });
    _ = try registerTree(
        rt.context(),
        rt.root_ns,
        .nil,
        &.{
            .typeValue(point_type),
            .i64(7),
            .intrinsic(&testPointFlattenNative),
            .intrinsic(&testPointUnflattenNative),
        },
    );
    return point_type;
}

fn makeTestPoint(
    rt: *skript.Runtime,
    point_type: Object,
    label: Value,
) Error!Value {
    return rt.apply(
        rt.root_ns,
        .typeValue(point_type),
        &.{ .f64(3.0), .f64(4.0), label },
    );
}

fn makeRawTestPoint(
    rt: *skript.Runtime,
    point_type: Object,
    metadata: Value,
) Error!Value {
    const reference = try rt.store.create(TestPointRecord);
    rt.store.store(TestPointRecord, reference.deref(TestPointRecord), .{
        .x = .f64(3.0),
        .y = .f64(4.0),
        .label = metadata,
    });
    return .init(point_type, reference.toObject());
}

fn makeNestedTestList(
    rt: *skript.Runtime,
    depth: usize,
    leaf: Value,
) Error!Value {
    var result = leaf;
    for (0..depth) |_| {
        const reference = try rt.store.create([2]Value);
        reference.deref([2]Value).* = .{ result, .nil };
        result = .cons(reference.toObject());
    }
    return result;
}

const TreeLimitedContext = struct {
    budget: EvalContext.Budget,
    lease: EvalContext.Budget.Lease,
    account: EvalContext.Budget.AccountAllocator,
    output_bytes: [64]u8,
    writer: std.Io.Writer,
    context: EvalContext,

    fn init(
        self: *TreeLimitedContext,
        rt: *skript.Runtime,
        lineage_id: u64,
        limits: EvalContext.Budget.Limits,
        options: EvalContext.LimitedOptions,
    ) Error!void {
        self.budget = EvalContext.Budget.init(rt.io, lineage_id, limits);
        self.lease = try EvalContext.Budget.Lease.root(&self.budget, limits.work);
        self.account = EvalContext.Budget.AccountAllocator.init(
            std.testing.allocator,
            &self.lease,
            .transform,
        );
        self.writer = .fixed(&self.output_bytes);
        self.context = try EvalContext.limited(
            rt,
            rt.intrinsics.registryVersion(),
            &self.account,
            .{ .writer = &self.writer, .bounded_memory = true },
            options,
        );
    }
};

test "TreeSpec check reuses metadata validation node accounting" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const point_type = try installSkriptTestPointTree(rt);
    const label = Value.symbol(try rt.store.getsym("metadata-count"));
    const point = try makeTestPoint(rt, point_type, label);
    var limits = Limits.gradient;
    limits.max_metadata_nodes = 2;
    var spec = try flatten(std.testing.allocator, rt.context(), rt.tree_registry.current(), point, limits);
    defer spec.deinit();

    try spec.check(std.testing.allocator, rt.context(), point);
}

test "Skript tree hooks preserve denied state reads" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const point_type = try installSkriptTestPointTree(rt);
    const label = Value.symbol(try rt.store.getsym("denied-read"));
    const point = try makeTestPoint(rt, point_type, label);
    // SAFETY: TreeLimitedContext.init assigns every field before any field is read.
    var limited: TreeLimitedContext = undefined;
    try limited.init(rt, 8101, .{ .work = 100_000 }, .{});

    try std.testing.expectError(
        error.Denied,
        flatten(std.testing.allocator, &limited.context, rt.tree_registry.current(), point, Limits.gradient),
    );
}

test "Skript tree hooks preserve modelled state reads" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const point_type = try installSkriptTestPointTree(rt);
    const label = Value.symbol(try rt.store.getsym("modelled-read"));
    const point = try makeTestPoint(rt, point_type, label);
    const model: EvalContext.Version = .{ .id = 81, .revision = 1 };
    // SAFETY: TreeLimitedContext.init assigns every field before any field is read.
    var limited: TreeLimitedContext = undefined;
    try limited.init(rt, 8102, .{ .work = 100_000 }, .{
        .model = model,
        .effects = .{ .state_read = .{ .model = model } },
    });

    try std.testing.expectError(
        error.Unsupported,
        flatten(std.testing.allocator, &limited.context, rt.tree_registry.current(), point, Limits.gradient),
    );
}

test "native tree hooks preserve denied state reads" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const point_type = try installNativeTestPointTree(rt);
    const label = Value.symbol(try rt.store.getsym("native-denied-read"));
    const point = try makeTestPoint(rt, point_type, label);
    var spec = try flatten(std.testing.allocator, rt.context(), rt.tree_registry.current(), point, Limits.gradient);
    defer spec.deinit();

    // SAFETY: TreeLimitedContext.init assigns every field before any field is read.
    var flatten_context: TreeLimitedContext = undefined;
    try flatten_context.init(rt, 8103, .{ .work = 100_000 }, .{});
    try std.testing.expectError(
        error.Denied,
        flatten(std.testing.allocator, &flatten_context.context, rt.tree_registry.current(), point, Limits.gradient),
    );

    // SAFETY: TreeLimitedContext.init assigns every field before any field is read.
    var unflatten_context: TreeLimitedContext = undefined;
    try unflatten_context.init(rt, 8104, .{ .work = 100_000 }, .{});
    try std.testing.expectError(
        error.Denied,
        spec.unflatten(std.testing.allocator, &unflatten_context.context, &.{ .f64(6.0), .f64(8.0) }),
    );
}

test "native tree hooks preserve modelled state reads" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const point_type = try installNativeTestPointTree(rt);
    const label = Value.symbol(try rt.store.getsym("native-modelled-read"));
    const point = try makeTestPoint(rt, point_type, label);
    var spec = try flatten(std.testing.allocator, rt.context(), rt.tree_registry.current(), point, Limits.gradient);
    defer spec.deinit();
    const model: EvalContext.Version = .{ .id = 82, .revision = 1 };

    // SAFETY: TreeLimitedContext.init assigns every field before any field is read.
    var flatten_context: TreeLimitedContext = undefined;
    try flatten_context.init(rt, 8111, .{ .work = 100_000 }, .{
        .model = model,
        .effects = .{ .state_read = .{ .model = model } },
    });
    try std.testing.expectError(
        error.Unsupported,
        flatten(std.testing.allocator, &flatten_context.context, rt.tree_registry.current(), point, Limits.gradient),
    );

    // SAFETY: TreeLimitedContext.init assigns every field before any field is read.
    var unflatten_context: TreeLimitedContext = undefined;
    try unflatten_context.init(rt, 8112, .{ .work = 100_000 }, .{
        .model = model,
        .effects = .{ .state_read = .{ .model = model } },
    });
    try std.testing.expectError(
        error.Unsupported,
        spec.unflatten(std.testing.allocator, &unflatten_context.context, &.{ .f64(6.0), .f64(8.0) }),
    );
}

test "flatten applies the caller depth quota" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const input = try makeNestedTestList(rt, 20, .i64(1));
    // SAFETY: TreeLimitedContext.init assigns every field before any field is read.
    var limited: TreeLimitedContext = undefined;
    try limited.init(rt, 8105, .{ .work = 100_000, .depth = 8 }, .{});

    try std.testing.expectError(
        error.Exhausted,
        flatten(std.testing.allocator, &limited.context, rt.tree_registry.current(), input, Limits.gradient),
    );
    const report = limited.budget.report() orelse return error.TestExpectedExhaustion;
    try std.testing.expectEqual(EvalContext.Budget.Resource.depth, report.resource);
    try std.testing.expectEqual(EvalContext.Budget.Backend.transform, report.backend);
}

test "TreeSpec check applies the caller depth quota" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const input = try makeNestedTestList(rt, 20, .i64(1));
    var spec = try flatten(std.testing.allocator, rt.context(), rt.tree_registry.current(), input, Limits.gradient);
    defer spec.deinit();
    // SAFETY: TreeLimitedContext.init assigns every field before any field is read.
    var limited: TreeLimitedContext = undefined;
    try limited.init(rt, 8106, .{ .work = 100_000, .depth = 8 }, .{});

    try std.testing.expectError(
        error.Exhausted,
        spec.check(std.testing.allocator, &limited.context, input),
    );
    const report = limited.budget.report() orelse return error.TestExpectedExhaustion;
    try std.testing.expectEqual(EvalContext.Budget.Resource.depth, report.resource);
    try std.testing.expectEqual(EvalContext.Budget.Backend.transform, report.backend);
}

test "TreeSpec unflatten applies the caller depth quota" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const input = try makeNestedTestList(rt, 20, .i64(1));
    var spec = try flatten(std.testing.allocator, rt.context(), rt.tree_registry.current(), input, Limits.gradient);
    defer spec.deinit();
    // SAFETY: TreeLimitedContext.init assigns every field before any field is read.
    var limited: TreeLimitedContext = undefined;
    try limited.init(rt, 8107, .{ .work = 100_000, .depth = 8 }, .{});

    try std.testing.expectError(
        error.Exhausted,
        spec.unflatten(std.testing.allocator, &limited.context, &.{.i64(2)}),
    );
    const report = limited.budget.report() orelse return error.TestExpectedExhaustion;
    try std.testing.expectEqual(EvalContext.Budget.Resource.depth, report.resource);
    try std.testing.expectEqual(EvalContext.Budget.Backend.transform, report.backend);
}

test "custom metadata applies the caller depth quota" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const point_type = try installNativeTestPointTree(rt);
    const label = Value.symbol(try rt.store.getsym("deep-metadata"));
    const metadata = try makeNestedTestList(rt, 20, label);
    const point = try makeRawTestPoint(rt, point_type, metadata);
    // SAFETY: TreeLimitedContext.init assigns every field before any field is read.
    var limited: TreeLimitedContext = undefined;
    try limited.init(rt, 8108, .{ .work = 100_000, .depth = 8 }, .{
        .effects = .{ .state_read = .allow },
    });

    try std.testing.expectError(
        error.Exhausted,
        flatten(std.testing.allocator, &limited.context, rt.tree_registry.current(), point, Limits.gradient),
    );
    const report = limited.budget.report() orelse return error.TestExpectedExhaustion;
    try std.testing.expectEqual(EvalContext.Budget.Resource.depth, report.resource);
    try std.testing.expectEqual(EvalContext.Budget.Backend.transform, report.backend);
}

test "TreeSpec unflatten accounts exported Store allocations" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const input = try rt.evalString("(stack 1)");
    var spec = try flatten(std.testing.allocator, rt.context(), rt.tree_registry.current(), input, Limits.gradient);
    defer spec.deinit();

    // SAFETY: TreeLimitedContext.init assigns every field before any field is read.
    var bytes_limited: TreeLimitedContext = undefined;
    try bytes_limited.init(rt, 8109, .{
        .work = 100_000,
        .bytes = 0,
        .objects = 100,
    }, .{});
    try std.testing.expectError(
        error.Exhausted,
        spec.unflatten(std.testing.allocator, &bytes_limited.context, &.{.i64(2)}),
    );
    const bytes_report = bytes_limited.budget.report() orelse {
        return error.TestExpectedExhaustion;
    };
    try std.testing.expectEqual(EvalContext.Budget.Resource.bytes, bytes_report.resource);
    try std.testing.expectEqual(EvalContext.Budget.Backend.native, bytes_report.backend);

    // SAFETY: TreeLimitedContext.init assigns every field before any field is read.
    var objects_limited: TreeLimitedContext = undefined;
    try objects_limited.init(rt, 8110, .{
        .work = 100_000,
        .bytes = 1024 * 1024,
        .objects = 0,
    }, .{});
    try std.testing.expectError(
        error.Exhausted,
        spec.unflatten(std.testing.allocator, &objects_limited.context, &.{.i64(2)}),
    );
    const objects_report = objects_limited.budget.report() orelse {
        return error.TestExpectedExhaustion;
    };
    try std.testing.expectEqual(
        EvalContext.Budget.Resource.objects,
        objects_report.resource,
    );
    try std.testing.expectEqual(
        EvalContext.Budget.Backend.native,
        objects_report.backend,
    );
}

test "registered Point tree preserves static metadata and held snapshots" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const point_type = try installTestPoint(rt);
    const flatten_hook = try rt.evalString(
        \\(fn (point)
        \\  (list
        \\    (list (point-x point) (point-y point))
        \\    (list (point-label point))))
    );
    const unflatten_hook = try rt.evalString(
        \\(fn (metadata children)
        \\  (Point
        \\    (fst children)
        \\    (fst (rst children))
        \\    (fst metadata)))
    );
    const label = Value.symbol(try rt.store.getsym("sample-a"));
    const point = try rt.apply(
        rt.root_ns,
        .typeValue(point_type),
        &.{ .f64(3.0), .f64(4.0), label },
    );
    const point_type_value = try rt.evalString(
        "(type (Point 3.0 4.0 'sample-a))",
    );
    try std.testing.expect(point_type_value.isType());
    try std.testing.expectEqual(point_type, point_type_value.obj);

    const version = try registerTree(
        rt.context(),
        rt.root_ns,
        .nil,
        &.{ point_type_value, .i64(7), flatten_hook, unflatten_hook },
    );
    try std.testing.expectEqual(skript.builtins.type_i64, version.typ);
    const held = rt.tree_registry.current();
    var spec = try flatten(std.testing.allocator, rt.context(), held, point, Limits.gradient);
    defer spec.deinit();
    try std.testing.expectEqual(@as(usize, 2), spec.leaves.len);
    const custom = switch (spec.node(spec.root).kind) {
        .custom => |custom| custom,
        else => return error.TestUnexpectedResult,
    };
    const metadata_cell = custom.metadata.obj.toRef().deref([2]Value).*;
    try std.testing.expectEqual(label, metadata_cell[0]);
    try std.testing.expectEqual(Value.nil, metadata_cell[1]);

    const replacement_unflatten = try rt.evalString(
        "(fn (_metadata _children) nil)",
    );
    const latest = try rt.tree_registry.publish(&.{.{
        .runtime_type = point_type,
        .implementation_revision = 8,
        .namespace = rt.root_ns,
        .flatten_hook = flatten_hook,
        .unflatten_hook = replacement_unflatten,
    }});
    try std.testing.expect(latest != held);
    try std.testing.expectEqual(
        @as(u64, 7),
        held.find(point_type).?.implementation_revision,
    );
    try std.testing.expectEqual(
        unflatten_hook,
        held.find(point_type).?.unflatten_hook,
    );
    try std.testing.expectEqual(
        replacement_unflatten,
        latest.find(point_type).?.unflatten_hook,
    );

    try std.testing.expectError(
        error.InvalidHook,
        rt.tree_registry.publish(&.{.{
            .runtime_type = point_type,
            .implementation_revision = 9,
            .namespace = rt.root_ns,
            .flatten_hook = .nil,
            .unflatten_hook = unflatten_hook,
        }}),
    );
    try std.testing.expect(rt.tree_registry.current() == latest);

    const rebuilt = try spec.unflatten(std.testing.allocator, rt.context(), &.{ .f64(6.0), .f64(8.0) });
    const payload = try testPointPayload(rt.context(), rt.root_ns, rebuilt);
    try std.testing.expectEqual(@as(f64, 6.0), payload.x.obj.tof64());
    try std.testing.expectEqual(@as(f64, 8.0), payload.y.obj.tof64());
    try std.testing.expectEqual(label, payload.label);
    try spec.check(std.testing.allocator, rt.context(), rebuilt);

    const impure_hook = try rt.evalString(
        "(fn (_point) (write \"forbidden\"))",
    );
    try std.testing.expectError(
        error.Denied,
        callHook(rt.context(), rt.root_ns, impure_hook, &.{point}),
    );
}

test "TreeSpec sorts map keys and rejects improper lists" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const input = try rt.evalString("(hash-map :z 1 'a 2 :a 3)");
    var spec = try flatten(std.testing.allocator, rt.context(), rt.tree_registry.current(), input, Limits.gradient);
    defer spec.deinit();
    const root_node = spec.node(spec.root);
    if (root_node.kind != .map) return error.TestUnexpectedResult;
    const keys = spec.keys(root_node);
    try std.testing.expectEqual(@as(usize, 3), keys.len);
    try std.testing.expectEqualStrings("a", keys[0].obj.toPtr(Sym).*);
    try std.testing.expectEqualStrings("a", keys[1].obj.toPtr(Sym).*);
    try std.testing.expectEqualStrings("z", keys[2].obj.toPtr(Sym).*);
    try std.testing.expectEqual(skript.builtins.type_symbol, keys[0].typ);
    try std.testing.expectEqual(skript.builtins.type_keyword, keys[1].typ);
    try std.testing.expectEqual(@as(i64, 2), spec.leaves[0].primal.obj.toInt(i64));
    try std.testing.expectEqual(@as(i64, 3), spec.leaves[1].primal.obj.toInt(i64));
    try std.testing.expectEqual(@as(i64, 1), spec.leaves[2].primal.obj.toInt(i64));

    const scalar_keys = try rt.evalString("(hash-map 2 20 \"name\" 30 #f 40 :z 50)");
    const same_keys = try rt.evalString("(hash-map :z 1 #f 2 \"name\" 3 2 4)");
    var scalar_spec = try flatten(
        std.testing.allocator,
        rt.context(),
        rt.tree_registry.current(),
        scalar_keys,
        Limits.gradient,
    );
    defer scalar_spec.deinit();
    var same_spec = try flatten(
        std.testing.allocator,
        rt.context(),
        rt.tree_registry.current(),
        same_keys,
        Limits.gradient,
    );
    defer same_spec.deinit();
    try std.testing.expect(try sameStructure(rt.context(), &scalar_spec, &same_spec));
    const scalar_root = scalar_spec.node(scalar_spec.root);
    const scalar_order = scalar_spec.keys(scalar_root);
    try std.testing.expectEqual(@as(usize, 4), scalar_order.len);
    try std.testing.expectEqual(skript.builtins.type_bool, scalar_order[0].typ);
    try std.testing.expectEqual(skript.builtins.type_string, scalar_order[1].typ);
    try std.testing.expectEqual(skript.builtins.type_i64, scalar_order[2].typ);
    try std.testing.expectEqual(skript.builtins.type_keyword, scalar_order[3].typ);
    try std.testing.expectEqual(@as(i64, 40), scalar_spec.leaves[0].primal.obj.toInt(i64));
    try std.testing.expectEqual(@as(i64, 30), scalar_spec.leaves[1].primal.obj.toInt(i64));
    try std.testing.expectEqual(@as(i64, 20), scalar_spec.leaves[2].primal.obj.toInt(i64));
    try std.testing.expectEqual(@as(i64, 50), scalar_spec.leaves[3].primal.obj.toInt(i64));
    const byte_keys = try rt.evalString(
        "(hash-map (ByteVector (u8 0) (u8 255)) 20 (ByteVector (u8 0) (u8 1)) 30)",
    );
    const same_bytes = try rt.evalString(
        "(hash-map (ByteVector (u8 0) (u8 1)) 3 (ByteVector (u8 0) (u8 255)) 2)",
    );
    var byte_spec = try flatten(
        std.testing.allocator,
        rt.context(),
        rt.tree_registry.current(),
        byte_keys,
        Limits.gradient,
    );
    defer byte_spec.deinit();
    var same_byte_spec = try flatten(
        std.testing.allocator,
        rt.context(),
        rt.tree_registry.current(),
        same_bytes,
        Limits.gradient,
    );
    defer same_byte_spec.deinit();
    try std.testing.expect(try sameStructure(rt.context(), &byte_spec, &same_byte_spec));
    const byte_order = byte_spec.keys(byte_spec.node(byte_spec.root));
    try std.testing.expectEqualSlices(u8, &.{ 0, 1 }, try byte_order[0].byteVectorBytes());
    try std.testing.expectEqualSlices(u8, &.{ 0, 255 }, try byte_order[1].byteVectorBytes());

    const improper = try rt.evalString("(cons 1 2)");
    try std.testing.expectError(
        error.TypeMismatch,
        flatten(std.testing.allocator, rt.context(), rt.tree_registry.current(), improper, Limits.gradient),
    );
}

test "TreeSpec keeps shared tensor backing as separate occurrences" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const ctx = rt.context();
    const shared = try rt.evalString("(stack 1 2)");
    const input = try makeList(ctx, &.{ shared, shared });
    var spec = try flatten(std.testing.allocator, ctx, rt.tree_registry.current(), input, Limits.gradient);
    defer spec.deinit();
    try std.testing.expectEqual(@as(usize, 4), spec.leaves.len);

    const rebuilt = try spec.unflatten(std.testing.allocator, ctx, &.{ .i64(10), .i64(20), .i64(30), .i64(40) });
    const first_cell = rebuilt.obj.toRef().deref([2]Value).*;
    const second_cell = first_cell[1].obj.toRef().deref([2]Value).*;
    const first_tensor = first_cell[0];
    const second_tensor = second_cell[0];
    try std.testing.expect(first_tensor.obj != second_tensor.obj);
    const first_holder = first_tensor.obj.toRef().deref(TensorHolder);
    const second_holder = second_tensor.obj.toRef().deref(TensorHolder);
    try std.testing.expect(first_holder.data.ptr != second_holder.data.ptr);
    try std.testing.expectEqual(
        Value.i64(10),
        skript.intrinsics.tensor.wordToValue(first_holder.inner, first_holder.data[0]),
    );
    try std.testing.expectEqual(
        Value.i64(30),
        skript.intrinsics.tensor.wordToValue(second_holder.inner, second_holder.data[0]),
    );
}

test "TreeSpec accepts only exact representable i64 replacements" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var spec = try flatten(std.testing.allocator, rt.context(), rt.tree_registry.current(), .i64(1), Limits.gradient);
    defer spec.deinit();

    const exact = try spec.unflatten(std.testing.allocator, rt.context(), &.{.f64(9_007_199_254_740_992.0)});
    try std.testing.expectEqual(
        @as(i64, 9_007_199_254_740_992),
        exact.obj.toInt(i64),
    );
    try std.testing.expectError(
        error.Unsupported,
        spec.unflatten(std.testing.allocator, rt.context(), &.{.f64(1.5)}),
    );
    try std.testing.expectError(
        error.Unsupported,
        spec.unflatten(std.testing.allocator, rt.context(), &.{.f64(std.math.nan(f64))}),
    );
    try std.testing.expectError(
        error.Unsupported,
        spec.unflatten(std.testing.allocator, rt.context(), &.{.f64(9_223_372_036_854_775_808.0)}),
    );
}
