const std = @import("std");
const root = @import("root.zig");

pub const Value = root.Value;
pub const FuncPtr = root.FuncPtr;

/// Process-local identity of one bound primitive operation.
pub const PrimitiveId = enum(u32) {
    invalid = std.math.maxInt(u32),
    _,

    pub fn fromIndex(value: u32) PrimitiveId {
        std.debug.assert(value != std.math.maxInt(u32));
        return @enumFromInt(value);
    }

    pub fn index(self: PrimitiveId) u32 {
        return @intFromEnum(self);
    }

    pub fn isValid(self: PrimitiveId) bool {
        return self != .invalid;
    }
};

/// Semantic effects exposed by a primitive. A zero set is audited purity;
/// unknown is set explicitly for dynamic or incomplete behavior.
pub const EffectSet = packed struct(u16) {
    state_read: bool = false,
    state_write: bool = false,
    io: bool = false,
    clock: bool = false,
    random: bool = false,
    process: bool = false,
    module: bool = false,
    ffi: bool = false,
    dynamic_loader: bool = false,
    host: bool = false,
    unknown: bool = false,
    _reserved: u5 = 0,

    pub const none: EffectSet = .{};
    pub const unknown_effect: EffectSet = .{ .unknown = true };

    pub fn eql(lhs: EffectSet, rhs: EffectSet) bool {
        return @as(u16, @bitCast(lhs)) == @as(u16, @bitCast(rhs));
    }
};

pub const FixedResource = struct {
    work: u32 = 1,
    objects: u32 = 0,
    bytes: u64 = 0,
};

pub const BoundedResource = struct {
    work: u64,
    objects: u64 = 0,
    bytes: u64 = 0,
};

pub const ResourceCost = union(enum) {
    fixed: FixedResource,
    bounded: BoundedResource,
    native,
    unknown,
    denied,
};

pub const SuspensionContract = union(enum) {
    never,
    would_block,
    callback,
    unknown,

    pub const no_suspend: SuspensionContract = .never;
};

pub const Callback = union(enum) {
    none,
    last,
    argument: u8,
    collection_fold,
    type_hook,
    unknown,
};

pub const Invocation = union(enum) {
    native: FuncPtr,
    closure: Value,

    pub fn nativePtr(ptr: FuncPtr) Invocation {
        return .{ .native = ptr };
    }

    pub fn closureValue(value: Value) Invocation {
        return .{ .closure = value };
    }
};

pub const Spec = struct {
    id: PrimitiveId,
    stable_name: []const u8,
    implementation_revision: u64,
    invoke: Invocation,
    effects: EffectSet,
    reads_argument_state: bool,
    callbacks: Callback,
    resources: ResourceCost,
    suspension: SuspensionContract,

    pub fn sameSemantics(lhs: Spec, rhs: Spec) bool {
        if (lhs.implementation_revision != rhs.implementation_revision) return false;
        if (!lhs.effects.eql(rhs.effects)) return false;
        if (lhs.reads_argument_state != rhs.reads_argument_state) return false;
        if (!std.meta.eql(lhs.callbacks, rhs.callbacks)) return false;
        if (!std.meta.eql(lhs.resources, rhs.resources)) return false;
        if (!std.meta.eql(lhs.suspension, rhs.suspension)) return false;
        return invocationEqual(lhs.invoke, rhs.invoke);
    }
};

pub const Registration = struct {
    id: ?PrimitiveId = null,
    stable_name: []const u8,
    implementation_revision: u64 = 1,
    invoke: ?Invocation = null,
    effects: EffectSet = EffectSet.unknown_effect,
    reads_argument_state: bool = false,
    callbacks: Callback = .unknown,
    resources: ResourceCost = .unknown,
    suspension: SuspensionContract = .unknown,
};

pub const RegistryVersion = struct {
    version: u64,
    specs: []const Spec,
    /// Exact tagged closure identity to its first published specification.
    /// Build once per immutable snapshot; metered recursive calls use O(1) lookup.
    closure_specs: std.AutoHashMapUnmanaged(u64, usize) = .empty,

    pub fn closureSpec(self: *const RegistryVersion, reference: root.Store.Ref) ?*const Spec {
        const index = self.closure_specs.get(reference.bits()) orelse return null;
        return &self.specs[index];
    }

    pub fn spec(self: *const RegistryVersion, id: PrimitiveId) ?*const Spec {
        for (self.specs) |*candidate| {
            if (candidate.id == id) return candidate;
        }
        return null;
    }

    pub fn find(self: *const RegistryVersion, name: []const u8) ?*const Spec {
        for (self.specs) |*candidate| {
            if (std.mem.eql(u8, candidate.stable_name, name)) return candidate;
        }
        return null;
    }

    pub fn idForNative(self: *const RegistryVersion, native: FuncPtr) ?PrimitiveId {
        var found: ?PrimitiveId = null;
        for (self.specs) |candidate| {
            const candidate_native = switch (candidate.invoke) {
                .native => |ptr| ptr,
                .closure => continue,
            };
            if (candidate_native != native) continue;
            if (found) |prior| {
                if (prior != candidate.id) return null;
            } else {
                found = candidate.id;
            }
        }
        return found;
    }
};

pub const RegistryError = error{
    EmptyName,
    MissingImplementation,
    DuplicateName,
    DuplicatePrimitiveId,
    InvalidPrimitiveId,
    InvalidEffects,
    InvalidRevision,
    VersionOverflow,
    IdOverflow,
};

const SnapshotNode = struct {
    snapshot: *RegistryVersion,
    next: ?*SnapshotNode,
};

/// Runtime-owned publisher for immutable registry snapshots. Each publication
/// allocates a fresh snapshot; prior snapshots and their names remain valid.
pub const RegistryOwner = struct {
    allocator: std.mem.Allocator,
    current_version: *RegistryVersion,
    snapshots: ?*SnapshotNode,
    next_version: u64,
    next_id: u64,

    pub fn init(allocator: std.mem.Allocator, base: []const Spec) !RegistryOwner {
        var owner: RegistryOwner = .{
            .allocator = allocator,
            // SAFETY: buildSnapshot assigns this before the owner is returned.
            .current_version = undefined,
            .snapshots = null,
            .next_version = 2,
            .next_id = 0,
        };
        errdefer owner.deinit();
        const snapshot = try owner.buildSnapshot(base, 1);
        owner.current_version = snapshot;
        owner.next_id = nextIdAfter(base);
        return owner;
    }

    pub fn deinit(self: *RegistryOwner) void {
        var node = self.snapshots;
        while (node) |node_current| {
            const next = node_current.next;
            node_current.snapshot.closure_specs.deinit(self.allocator);
            for (node_current.snapshot.specs) |spec| self.allocator.free(spec.stable_name);
            self.allocator.free(node_current.snapshot.specs);
            self.allocator.destroy(node_current.snapshot);
            self.allocator.destroy(node_current);
            node = next;
        }
        self.current_version = undefined;
        self.snapshots = null;
    }

    pub fn current(self: *const RegistryOwner) *const RegistryVersion {
        return self.current_version;
    }

    pub fn publish(
        self: *RegistryOwner,
        additions: []const Registration,
    ) (RegistryError || std.mem.Allocator.Error)!*const RegistryVersion {
        const old = self.current_version;
        const total = std.math.add(usize, old.specs.len, additions.len) catch {
            return error.IdOverflow;
        };
        var candidates = try self.allocator.alloc(Spec, total);
        defer self.allocator.free(candidates);
        @memcpy(candidates[0..old.specs.len], old.specs);

        var next_id = self.next_id;
        for (additions, 0..) |registration, i| {
            const invoke = registration.invoke orelse return error.MissingImplementation;
            if (registration.stable_name.len == 0) return error.EmptyName;
            var candidate: Spec = .{
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
            var id = registration.id;
            if (id == null) {
                for (candidates[0 .. old.specs.len + i]) |existing| {
                    if (existing.sameSemantics(candidate)) {
                        id = existing.id;
                        break;
                    }
                }
            }
            if (id == null) {
                if (next_id >= std.math.maxInt(u32)) return error.IdOverflow;
                id = PrimitiveId.fromIndex(@intCast(next_id));
                next_id += 1;
            }
            const resolved_id = id orelse unreachable;
            if (!resolved_id.isValid()) return error.InvalidPrimitiveId;
            const id_after = @as(u64, resolved_id.index()) + 1;
            if (id_after > next_id) next_id = id_after;
            candidate.id = resolved_id;
            candidates[old.specs.len + i] = candidate;
        }
        try validateSpecs(candidates);
        if (self.next_version == std.math.maxInt(u64)) return error.VersionOverflow;
        const snapshot = try self.buildSnapshot(candidates, self.next_version);
        self.next_id = next_id;
        self.next_version += 1;
        self.current_version = snapshot;
        return snapshot;
    }

    fn buildSnapshot(self: *RegistryOwner, source: []const Spec, version: u64) !*RegistryVersion {
        if (version == 0) return error.VersionOverflow;
        try validateSpecs(source);
        const specs = try self.allocator.alloc(Spec, source.len);
        errdefer self.allocator.free(specs);
        var copied: usize = 0;
        errdefer {
            for (specs[0..copied]) |spec| self.allocator.free(spec.stable_name);
        }
        for (source, 0..) |spec, i| {
            specs[i] = spec;
            specs[i].stable_name = try self.allocator.dupe(u8, spec.stable_name);
            copied += 1;
        }
        var closure_specs: std.AutoHashMapUnmanaged(u64, usize) = .empty;
        errdefer closure_specs.deinit(self.allocator);
        for (specs, 0..) |spec, index| {
            const value = switch (spec.invoke) {
                .closure => |closure| closure,
                .native => continue,
            };
            if (value.typ != root.builtins.type_closure or value.obj == .null) continue;
            const entry = try closure_specs.getOrPut(self.allocator, value.obj.toRef().bits());
            if (!entry.found_existing) entry.value_ptr.* = index;
        }
        const snapshot = try self.allocator.create(RegistryVersion);
        errdefer self.allocator.destroy(snapshot);
        snapshot.* = .{ .version = version, .specs = specs, .closure_specs = closure_specs };
        const node = try self.allocator.create(SnapshotNode);
        node.* = .{ .snapshot = snapshot, .next = self.snapshots };
        self.snapshots = node;
        return snapshot;
    }
};

fn invocationEqual(lhs: Invocation, rhs: Invocation) bool {
    return switch (lhs) {
        .native => |native| switch (rhs) {
            .native => |other| native == other,
            .closure => false,
        },
        .closure => |closure| switch (rhs) {
            .native => false,
            .closure => |other| std.meta.eql(closure, other),
        },
    };
}

fn validateSpecs(specs: []const Spec) RegistryError!void {
    for (specs, 0..) |candidate, i| {
        if (candidate.stable_name.len == 0) return error.EmptyName;
        if (!candidate.id.isValid()) return error.InvalidPrimitiveId;
        if (candidate.effects._reserved != 0) return error.InvalidEffects;
        if (candidate.implementation_revision == 0) return error.InvalidRevision;
        for (specs[0..i]) |prior| {
            if (std.mem.eql(u8, prior.stable_name, candidate.stable_name)) {
                return error.DuplicateName;
            }
            if (prior.id == candidate.id and !candidate.sameSemantics(prior)) {
                return error.DuplicatePrimitiveId;
            }
        }
    }
}

fn nextIdAfter(specs: []const Spec) u64 {
    var next: u64 = 0;
    for (specs) |spec| {
        const candidate = @as(u64, spec.id.index()) + 1;
        if (candidate > next) next = candidate;
    }
    return next;
}

fn registryTestNative(
    _: *root.EvalContext,
    _: Value,
    _: Value,
    _: []const Value,
) root.Error!Value {
    return .nil;
}

fn registryTestNative2(
    _: *root.EvalContext,
    _: Value,
    _: Value,
    _: []const Value,
) root.Error!Value {
    return .nil;
}

test "registry publication retains old versions and allocates unique identities" {
    const base = [_]Spec{.{
        .id = PrimitiveId.fromIndex(0),
        .stable_name = "base",
        .implementation_revision = 1,
        .invoke = Invocation.nativePtr(&registryTestNative),
        .effects = .none,
        .reads_argument_state = false,
        .resources = .{ .fixed = .{} },
        .suspension = .never,
        .callbacks = .none,
    }};
    var owner = try RegistryOwner.init(std.testing.allocator, &base);
    defer owner.deinit();

    const old = owner.current();
    const first = try owner.publish(&.{.{
        .stable_name = "extension.one",
        .invoke = Invocation.nativePtr(&registryTestNative2),
        .effects = .none,
        .resources = .{ .fixed = .{} },
        .suspension = .never,
        .callbacks = .none,
    }});
    const second = try owner.publish(&.{.{
        .stable_name = "extension.two",
        .invoke = Invocation.nativePtr(&registryTestNative),
    }});
    const alias = try owner.publish(&.{.{
        .id = PrimitiveId.fromIndex(0),
        .stable_name = "base.alias",
        .invoke = Invocation.nativePtr(&registryTestNative),
        .effects = .none,
        .resources = .{ .fixed = .{} },
        .suspension = .never,
        .callbacks = .none,
    }});
    const closure = try owner.publish(&.{.{
        .stable_name = "closure.one",
        .invoke = Invocation.closureValue(Value.nil),
        .effects = .none,
        .resources = .{ .fixed = .{} },
        .suspension = .never,
        .callbacks = .none,
    }});
    const closure_alias = try owner.publish(&.{.{
        .stable_name = "closure.alias",
        .invoke = Invocation.closureValue(Value.nil),
        .effects = .none,
        .resources = .{ .fixed = .{} },
        .suspension = .never,
        .callbacks = .none,
    }});

    try std.testing.expectEqual(@as(u64, 1), old.version);
    try std.testing.expectEqual(@as(usize, 1), old.specs.len);
    try std.testing.expect(old.find("extension.one") == null);
    try std.testing.expect(first.version != old.version);
    try std.testing.expect(second.version != first.version);
    try std.testing.expect(alias.find("base.alias").?.id == PrimitiveId.fromIndex(0));
    try std.testing.expect(first.find("extension.one").?.id != second.find("extension.two").?.id);
    try std.testing.expect(closure.find("closure.one").?.id == closure_alias.find("closure.alias").?.id);
    try std.testing.expect(second.find("extension.two").?.effects.unknown);
}

test "registry rejects invalid declarations without publication" {
    const duplicate_ids = [_]Spec{
        .{
            .id = PrimitiveId.fromIndex(0),
            .stable_name = "one",
            .implementation_revision = 1,
            .invoke = Invocation.nativePtr(&registryTestNative),
            .effects = .none,
            .reads_argument_state = false,
            .resources = .{ .fixed = .{} },
            .suspension = .never,
            .callbacks = .none,
        },
        .{
            .id = PrimitiveId.fromIndex(0),
            .stable_name = "two",
            .implementation_revision = 1,
            .invoke = Invocation.nativePtr(&registryTestNative2),
            .effects = .none,
            .reads_argument_state = false,
            .resources = .{ .fixed = .{} },
            .suspension = .never,
            .callbacks = .none,
        },
    };
    try std.testing.expectError(error.DuplicatePrimitiveId, RegistryOwner.init(std.testing.allocator, &duplicate_ids));

    var invalid_effects = duplicate_ids[0];
    invalid_effects.effects._reserved = 1;
    try std.testing.expectError(
        error.InvalidEffects,
        RegistryOwner.init(std.testing.allocator, &.{invalid_effects}),
    );

    var invalid_revision = duplicate_ids[0];
    invalid_revision.implementation_revision = 0;
    try std.testing.expectError(
        error.InvalidRevision,
        RegistryOwner.init(std.testing.allocator, &.{invalid_revision}),
    );

    const base = [_]Spec{.{
        .id = PrimitiveId.fromIndex(0),
        .stable_name = "base",
        .implementation_revision = 1,
        .invoke = Invocation.nativePtr(&registryTestNative),
        .effects = .none,
        .reads_argument_state = false,
        .resources = .{ .fixed = .{} },
        .suspension = .never,
        .callbacks = .none,
    }};
    var owner = try RegistryOwner.init(std.testing.allocator, &base);
    defer owner.deinit();
    const before = owner.current();
    try std.testing.expectError(error.EmptyName, owner.publish(&.{.{
        .stable_name = "",
        .invoke = Invocation.nativePtr(&registryTestNative2),
    }}));
    try std.testing.expectError(error.MissingImplementation, owner.publish(&.{.{ .stable_name = "missing" }}));
    try std.testing.expectError(error.DuplicateName, owner.publish(&.{.{
        .stable_name = "base",
        .invoke = Invocation.nativePtr(&registryTestNative2),
    }}));
    try std.testing.expect(before == owner.current());
}
