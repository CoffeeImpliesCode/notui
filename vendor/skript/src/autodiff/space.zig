//! Independent tangent and cotangent algebra for automatic differentiation.
//!
//! Trees describe representation. Spaces describe linear operations and the
//! tangent/cotangent pairing. The two registrations are deliberately separate.

const std = @import("std");
const skript = @import("../root.zig");
const tree = @import("tree.zig");
const Allocator = std.mem.Allocator;
const Error = skript.Error;
const EvalContext = skript.EvalContext;
const Object = skript.Object;
const Value = skript.Value;
const TensorHolder = skript.intrinsics.tensor.TensorHolder;
const TensorInner = skript.intrinsics.tensor.InnerType;
const map_intrin = skript.intrinsics.map;

const Dual = enum {
    tangent,
    cotangent,
};

const NodeInfo = struct {
    dimension: usize,
    has_metric: bool,
};

const ListValues = struct {
    allocator: Allocator,
    values: []Value,

    fn deinit(self: *ListValues) void {
        self.allocator.free(self.values);
        self.* = undefined;
    }
};

pub const Hook = Value;

pub const ZeroFn = *const fn (
    *EvalContext,
    Object,
    ?*const anyopaque,
) Error!Value;
pub const AddFn = *const fn (
    *EvalContext,
    Object,
    Value,
    Value,
    ?*const anyopaque,
) Error!Value;
pub const ScaleFn = *const fn (
    *EvalContext,
    Object,
    Value,
    Value,
    ?*const anyopaque,
) Error!Value;
pub const CheckFn = *const fn (
    *EvalContext,
    Object,
    Value,
    ?*const anyopaque,
) Error!void;
pub const BasisFn = *const fn (
    *EvalContext,
    Object,
    usize,
    ?*const anyopaque,
) Error!Value;
pub const ConstructFn = *const fn (
    *EvalContext,
    Object,
    Value,
    ?*const anyopaque,
) Error!Value;
pub const PairFn = *const fn (
    *EvalContext,
    Object,
    Value,
    Value,
    ?*const anyopaque,
) Error!Value;
pub const MetricFn = *const fn (
    *EvalContext,
    Object,
    Value,
    ?*const anyopaque,
) Error!Value;

pub const NativeLinearOps = struct {
    context: ?*const anyopaque = null,
    zero: ?ZeroFn = null,
    add: ?AddFn = null,
    scale: ?ScaleFn = null,
    check: ?CheckFn = null,
    basis: ?BasisFn = null,
    construct: ?ConstructFn = null,
};

pub const LinearOps = struct {
    /// A null representation uses an explicit check hook or numeric leaves.
    /// Tree spaces are identified by `SpaceSpec.tree_spec`.
    representation_type: Object = .null,
    namespace: Value = .nil,
    native: NativeLinearOps = .{},
    zero_hook: ?Hook = null,
    add_hook: ?Hook = null,
    scale_hook: ?Hook = null,
    check_hook: ?Hook = null,
    basis_hook: ?Hook = null,
    construct_hook: ?Hook = null,

    pub fn check(
        self: *const LinearOps,
        ctx: *EvalContext,
        primal_type: Object,
        value: Value,
    ) Error!void {
        const scope = ctx.activate();
        defer scope.deinit();
        if (self.check_hook) |hook| {
            const result = try callHook(ctx, self.namespace, hook, &.{value});
            if (result.typ != skript.builtins.type_nil) return error.TypeMismatch;
            return;
        }
        if (self.native.check) |check_fn| {
            var restricted = try restrictedHookContext(ctx);
            const restricted_scope = restricted.activate();
            defer restricted_scope.deinit();
            return check_fn(&restricted, primal_type, value, self.native.context);
        }
        if (self.representation_type != .null and value.typ != self.representation_type) {
            return error.TypeMismatch;
        }
        if (self.representation_type == .null and !tree.isNumeric(value)) {
            return error.TypeMismatch;
        }
    }

    pub fn zero(self: *const LinearOps, ctx: *EvalContext, primal_type: Object) Error!Value {
        const scope = ctx.activate();
        defer scope.deinit();
        const result = if (self.zero_hook) |hook|
            try callHook(ctx, self.namespace, hook, &.{})
        else if (self.native.zero) |zero_fn| blk: {
            var restricted = try restrictedHookContext(ctx);
            const restricted_scope = restricted.activate();
            defer restricted_scope.deinit();
            break :blk try zero_fn(&restricted, primal_type, self.native.context);
        } else return error.Unsupported;
        try self.check(ctx, primal_type, result);
        return result;
    }

    pub fn add(
        self: *const LinearOps,
        ctx: *EvalContext,
        primal_type: Object,
        left: Value,
        right: Value,
    ) Error!Value {
        const scope = ctx.activate();
        defer scope.deinit();
        try self.check(ctx, primal_type, left);
        try self.check(ctx, primal_type, right);
        const result = if (self.add_hook) |hook|
            try callHook(ctx, self.namespace, hook, &.{ left, right })
        else if (self.native.add) |add_fn| blk: {
            var restricted = try restrictedHookContext(ctx);
            const restricted_scope = restricted.activate();
            defer restricted_scope.deinit();
            break :blk try add_fn(&restricted, primal_type, left, right, self.native.context);
        } else return error.Unsupported;
        try self.check(ctx, primal_type, result);
        return result;
    }

    pub fn scale(
        self: *const LinearOps,
        ctx: *EvalContext,
        primal_type: Object,
        value: Value,
        factor: Value,
    ) Error!Value {
        const scope = ctx.activate();
        defer scope.deinit();
        try self.check(ctx, primal_type, value);
        const result = if (self.scale_hook) |hook|
            try callHook(ctx, self.namespace, hook, &.{ value, factor })
        else if (self.native.scale) |scale_fn| blk: {
            var restricted = try restrictedHookContext(ctx);
            const restricted_scope = restricted.activate();
            defer restricted_scope.deinit();
            break :blk try scale_fn(&restricted, primal_type, value, factor, self.native.context);
        } else return error.Unsupported;
        try self.check(ctx, primal_type, result);
        return result;
    }

    pub fn basis(
        self: *const LinearOps,
        ctx: *EvalContext,
        primal_type: Object,
        index: usize,
    ) Error!Value {
        const scope = ctx.activate();
        defer scope.deinit();
        const result = if (self.basis_hook) |hook| blk: {
            const index_value = Value.i64(std.math.cast(i64, index) orelse return error.Unsupported);
            break :blk try callHook(ctx, self.namespace, hook, &.{index_value});
        } else if (self.native.basis) |basis_fn| blk: {
            var restricted = try restrictedHookContext(ctx);
            const restricted_scope = restricted.activate();
            defer restricted_scope.deinit();
            break :blk try basis_fn(&restricted, primal_type, index, self.native.context);
        } else return error.Unsupported;
        try self.check(ctx, primal_type, result);
        return result;
    }

    pub fn construct(
        self: *const LinearOps,
        ctx: *EvalContext,
        primal_type: Object,
        value: Value,
    ) Error!Value {
        const scope = ctx.activate();
        defer scope.deinit();
        if (self.construct_hook) |hook| {
            const result = try callHook(ctx, self.namespace, hook, &.{value});
            return result;
        }
        if (self.native.construct) |construct_fn| {
            var restricted = try restrictedHookContext(ctx);
            const restricted_scope = restricted.activate();
            defer restricted_scope.deinit();
            return construct_fn(&restricted, primal_type, value, self.native.context);
        }
        return value;
    }
};
pub const NativePairing = struct {
    context: ?*const anyopaque = null,
    pair: PairFn,
};

pub const Pairing = struct {
    namespace: Value = .nil,
    native: ?NativePairing = null,
    hook: ?Hook = null,
    pub fn apply(
        self: *const Pairing,
        ctx: *EvalContext,
        primal_type: Object,
        tangent: Value,
        cotangent: Value,
    ) Error!Value {
        const scope = ctx.activate();
        defer scope.deinit();
        const result = if (self.hook) |hook|
            try callHook(ctx, self.namespace, hook, &.{ tangent, cotangent })
        else if (self.native) |native| blk: {
            var restricted = try restrictedHookContext(ctx);
            const restricted_scope = restricted.activate();
            defer restricted_scope.deinit();
            break :blk try native.pair(
                &restricted,
                primal_type,
                tangent,
                cotangent,
                native.context,
            );
        } else return error.Unsupported;
        if (!tree.isNumeric(result)) return error.TypeMismatch;
        return result;
    }
};
pub const NativeMetric = struct {
    context: ?*const anyopaque = null,
    identify: MetricFn,
};

pub const Metric = union(enum) {
    none,
    identity,
    diagonal: []const f64,
    native: NativeMetric,
    hook: struct {
        namespace: Value,
        function: Hook,
    },
};

pub const SpaceSpec = struct {
    allocator: ?Allocator = null,
    implementation_revision: u64 = 1,
    version: u64 = 0,
    primal_type: Object = .null,
    dimension: ?usize = null,
    tree_spec: ?*const tree.TreeSpec = null,
    /// Immutable space registrations used by composed custom tree nodes.
    space_registry: ?*const RegistryVersion = null,
    tangent: LinearOps,
    cotangent: LinearOps,
    pairing: Pairing,
    metric: Metric = .none,

    /// Report whether this space came from a published registration.
    ///
    /// A composed TreeSpec is registered only when it contains a custom tree
    /// node and retains the space-registry snapshot used to resolve it.
    pub fn usesRegisteredAlgebra(self: *const SpaceSpec) bool {
        if (self.tree_spec) |spec| {
            return spec.containsCustom() and self.space_registry != null;
        }
        return self.version != 0 or self.space_registry != null;
    }

    pub fn deinit(self: *SpaceSpec) void {
        if (self.allocator) |allocator| {
            switch (self.metric) {
                .diagonal => |weights| allocator.free(weights),
                else => {},
            }
        }
        self.* = undefined;
    }

    pub fn validate(self: *const SpaceSpec) Error!void {
        if (self.implementation_revision == 0) return error.Unsupported;
        if (self.tree_spec) |spec| {
            if (self.dimension) |dimension| {
                if (dimension != spec.leaves.len and
                    !(spec.containsCustom() and self.space_registry != null))
                {
                    return error.ArityMismatch;
                }
            }
            switch (self.metric) {
                .diagonal => |weights| {
                    if (weights.len != spec.leaves.len) return error.ArityMismatch;
                    for (weights) |weight| {
                        if (!std.math.isFinite(weight) or weight == 0.0) return error.Unsupported;
                    }
                },
                .hook => |hook| if (!isCallable(hook.function)) return error.Unsupported,
                else => {},
            }
            return;
        }
        if (self.dimension) |dimension| {
            if (dimension == 0) return error.Unsupported;
        }
        if (self.pairing.hook == null and self.pairing.native == null) return error.Unsupported;
        if (self.pairing.hook) |hook| if (!isCallable(hook)) return error.Unsupported;
        if (self.tangent.zero_hook == null and self.tangent.native.zero == null) {
            return error.Unsupported;
        }
        if (self.tangent.add_hook == null and self.tangent.native.add == null) {
            return error.Unsupported;
        }
        if (self.tangent.scale_hook == null and self.tangent.native.scale == null) {
            return error.Unsupported;
        }
        if (self.cotangent.zero_hook == null and self.cotangent.native.zero == null) {
            return error.Unsupported;
        }
        if (self.cotangent.add_hook == null and self.cotangent.native.add == null) {
            return error.Unsupported;
        }
        if (self.cotangent.scale_hook == null and self.cotangent.native.scale == null) {
            return error.Unsupported;
        }
        for ([_]LinearOps{ self.tangent, self.cotangent }) |ops| {
            if (ops.zero_hook) |hook| if (!isCallable(hook)) return error.Unsupported;
            if (ops.add_hook) |hook| if (!isCallable(hook)) return error.Unsupported;
            if (ops.scale_hook) |hook| if (!isCallable(hook)) return error.Unsupported;
            if (ops.check_hook) |hook| if (!isCallable(hook)) return error.Unsupported;
            if (ops.basis_hook) |hook| if (!isCallable(hook)) return error.Unsupported;
            if (ops.construct_hook) |hook| if (!isCallable(hook)) return error.Unsupported;
        }
        switch (self.metric) {
            .diagonal => |weights| {
                if (weights.len == 0) return error.Unsupported;
                if (self.dimension) |dimension| {
                    if (weights.len != dimension) return error.ArityMismatch;
                    if (dimension > 1 and self.tangent.basis_hook == null and self.tangent.native.basis == null) {
                        return error.Unsupported;
                    }
                }
                for (weights) |weight| {
                    if (!std.math.isFinite(weight) or weight == 0.0) return error.Unsupported;
                }
            },
            .hook => |hook| if (!isCallable(hook.function)) return error.Unsupported,
            else => {},
        }
    }

    pub fn tangentCheck(self: *const SpaceSpec, ctx: *EvalContext, value: Value) Error!void {
        const scope = ctx.activate();
        defer scope.deinit();
        if (self.tree_spec) |spec| {
            if (spec.containsCustom()) return composedCheckNode(self, spec, spec.root, ctx, value, .tangent);
            return checkTree(spec, ctx, value);
        }
        return self.tangent.check(ctx, self.primal_type, value);
    }

    pub fn cotangentCheck(self: *const SpaceSpec, ctx: *EvalContext, value: Value) Error!void {
        const scope = ctx.activate();
        defer scope.deinit();
        if (self.tree_spec) |spec| {
            if (spec.containsCustom()) {
                try composedCheckNode(self, spec, spec.root, ctx, value, .cotangent);
            } else {
                try checkTree(spec, ctx, value);
            }
        } else {
            try self.cotangent.check(ctx, self.primal_type, value);
        }
        try requireFiniteValue(ctx, value, 0);
    }

    pub fn tangentZero(self: *const SpaceSpec, ctx: *EvalContext) Error!Value {
        const scope = ctx.activate();
        defer scope.deinit();
        if (self.tree_spec) |spec| {
            if (spec.containsCustom()) return composedZeroNode(self, spec, spec.root, ctx, .tangent);
            return treeZero(spec, ctx);
        }
        return self.tangent.zero(ctx, self.primal_type);
    }

    pub fn cotangentZero(self: *const SpaceSpec, ctx: *EvalContext) Error!Value {
        const scope = ctx.activate();
        defer scope.deinit();
        if (self.tree_spec) |spec| {
            if (spec.containsCustom()) return composedZeroNode(self, spec, spec.root, ctx, .cotangent);
            return treeZero(spec, ctx);
        }
        return self.cotangent.zero(ctx, self.primal_type);
    }

    pub fn tangentAdd(
        self: *const SpaceSpec,
        ctx: *EvalContext,
        left: Value,
        right: Value,
    ) Error!Value {
        const scope = ctx.activate();
        defer scope.deinit();
        if (self.tree_spec) |spec| {
            if (spec.containsCustom()) {
                try composedCheckNode(self, spec, spec.root, ctx, left, .tangent);
                try composedCheckNode(self, spec, spec.root, ctx, right, .tangent);
                return composedAddNode(self, spec, spec.root, ctx, left, right, .tangent);
            }
            return treeAdd(spec, ctx, left, right);
        }
        return self.tangent.add(ctx, self.primal_type, left, right);
    }

    pub fn cotangentAdd(
        self: *const SpaceSpec,
        ctx: *EvalContext,
        left: Value,
        right: Value,
    ) Error!Value {
        const scope = ctx.activate();
        defer scope.deinit();
        if (self.tree_spec) |spec| {
            if (spec.containsCustom()) {
                try composedCheckNode(self, spec, spec.root, ctx, left, .cotangent);
                try composedCheckNode(self, spec, spec.root, ctx, right, .cotangent);
                return composedAddNode(self, spec, spec.root, ctx, left, right, .cotangent);
            }
            return treeAdd(spec, ctx, left, right);
        }
        return self.cotangent.add(ctx, self.primal_type, left, right);
    }

    pub fn tangentScale(
        self: *const SpaceSpec,
        ctx: *EvalContext,
        value: Value,
        factor: Value,
    ) Error!Value {
        const scope = ctx.activate();
        defer scope.deinit();
        if (self.tree_spec) |spec| {
            if (spec.containsCustom()) {
                try composedCheckNode(self, spec, spec.root, ctx, value, .tangent);
                return composedScaleNode(self, spec, spec.root, ctx, value, factor, .tangent);
            }
            return treeScale(spec, ctx, value, factor);
        }
        return self.tangent.scale(ctx, self.primal_type, value, factor);
    }

    pub fn cotangentScale(
        self: *const SpaceSpec,
        ctx: *EvalContext,
        value: Value,
        factor: Value,
    ) Error!Value {
        const scope = ctx.activate();
        defer scope.deinit();
        if (self.tree_spec) |spec| {
            if (spec.containsCustom()) {
                try composedCheckNode(self, spec, spec.root, ctx, value, .cotangent);
                return composedScaleNode(self, spec, spec.root, ctx, value, factor, .cotangent);
            }
            return treeScale(spec, ctx, value, factor);
        }
        return self.cotangent.scale(ctx, self.primal_type, value, factor);
    }

    pub fn tangentBasis(self: *const SpaceSpec, ctx: *EvalContext, index: usize) Error!Value {
        const scope = ctx.activate();
        defer scope.deinit();
        const dimension = self.dimension orelse return error.Unsupported;
        if (index >= dimension) return error.Unsupported;
        if (self.tree_spec) |spec| {
            if (spec.containsCustom()) return composedBasisNode(self, spec, spec.root, ctx, index, .tangent);
            return treeBasis(spec, ctx, index);
        }
        return self.tangent.basis(ctx, self.primal_type, index);
    }

    pub fn cotangentBasis(self: *const SpaceSpec, ctx: *EvalContext, index: usize) Error!Value {
        const scope = ctx.activate();
        defer scope.deinit();
        const dimension = self.dimension orelse return error.Unsupported;
        if (index >= dimension) return error.Unsupported;
        if (self.tree_spec) |spec| {
            if (spec.containsCustom()) return composedBasisNode(self, spec, spec.root, ctx, index, .cotangent);
            return treeBasis(spec, ctx, index);
        }
        return self.cotangent.basis(ctx, self.primal_type, index);
    }

    pub fn pair(
        self: *const SpaceSpec,
        ctx: *EvalContext,
        tangent: Value,
        cotangent: Value,
    ) Error!Value {
        const scope = ctx.activate();
        defer scope.deinit();
        if (self.tree_spec) |spec| {
            if (spec.containsCustom()) {
                try composedCheckNode(self, spec, spec.root, ctx, tangent, .tangent);
                try composedCheckNode(self, spec, spec.root, ctx, cotangent, .cotangent);
                return composedPairNode(self, spec, spec.root, ctx, tangent, cotangent);
            }
            return treePair(spec, ctx, tangent, cotangent);
        }
        try self.tangent.check(ctx, self.primal_type, tangent);
        try self.cotangent.check(ctx, self.primal_type, cotangent);
        return self.pairing.apply(ctx, self.primal_type, tangent, cotangent);
    }

    /// Build a cotangent from coordinates in the declared dual basis.
    pub fn cotangentFromCoordinates(
        self: *const SpaceSpec,
        ctx: *EvalContext,
        coordinates: []const Value,
    ) Error!Value {
        const scope = ctx.activate();
        defer scope.deinit();
        const dimension = self.dimension orelse return error.Unsupported;
        if (coordinates.len != dimension) return error.ArityMismatch;
        for (coordinates) |coordinate| {
            try chargeWork(ctx, 1);
            try requireFiniteScalar(coordinate);
        }
        if (self.tree_spec) |spec| {
            if (!spec.containsCustom()) {
                return spec.unflatten(scratchAllocator(ctx), ctx, coordinates);
            }
            var offset: usize = 0;
            const result = try composedCoordinatesNode(
                self,
                spec,
                spec.root,
                ctx,
                coordinates,
                &offset,
                .cotangent,
            );
            if (offset != coordinates.len) return error.InvalidCode;
            return result;
        }
        return coordinatesToCotangent(self, ctx, coordinates);
    }

    /// Convert a cotangent into a tangent only when a metric is declared.
    pub fn identify(self: *const SpaceSpec, ctx: *EvalContext, cotangent: Value) Error!Value {
        const scope = ctx.activate();
        defer scope.deinit();
        try self.cotangentCheck(ctx, cotangent);
        const result = if (self.tree_spec) |spec| blk: {
            switch (self.metric) {
                .none => return error.Unsupported,
                .identity => {
                    if (spec.containsCustom()) {
                        break :blk try composedIdentifyNode(self, spec, spec.root, ctx, cotangent);
                    }
                    break :blk cotangent;
                },
                .diagonal => |weights| {
                    if (spec.containsCustom()) return error.Unsupported;
                    break :blk try treeDiagonalIdentify(spec, ctx, cotangent, weights);
                },
                .native => |native| {
                    var restricted = try restrictedHookContext(ctx);
                    const restricted_scope = restricted.activate();
                    defer restricted_scope.deinit();
                    break :blk try native.identify(
                        &restricted,
                        self.primal_type,
                        cotangent,
                        native.context,
                    );
                },
                .hook => |hook| break :blk try callHook(ctx, hook.namespace, hook.function, &.{cotangent}),
            }
        } else switch (self.metric) {
            .none => return error.Unsupported,
            .identity => try self.tangent.construct(ctx, self.primal_type, cotangent),
            .diagonal => |weights| try scalarDiagonalIdentify(self, ctx, cotangent, weights),
            .native => |native| blk: {
                var restricted = try restrictedHookContext(ctx);
                const restricted_scope = restricted.activate();
                defer restricted_scope.deinit();
                break :blk try native.identify(
                    &restricted,
                    self.primal_type,
                    cotangent,
                    native.context,
                );
            },
            .hook => |hook| try callHook(ctx, hook.namespace, hook.function, &.{cotangent}),
        };
        try self.tangentCheck(ctx, result);
        return result;
    }

    pub fn gradientFromCotangent(
        self: *const SpaceSpec,
        ctx: *EvalContext,
        cotangent: Value,
    ) Error!Value {
        return self.identify(ctx, cotangent);
    }
};

pub const Registration = struct {
    primal_type: Object,
    implementation_revision: u64 = 1,
    dimension: ?usize = null,
    tangent: LinearOps,
    cotangent: LinearOps,
    pairing: Pairing,
    metric: Metric = .none,
};

pub const RegistryVersion = struct {
    version: u64,
    specs: []const SpaceSpec,

    pub fn find(self: *const RegistryVersion, primal_type: Object) ?*const SpaceSpec {
        for (self.specs) |*spec| {
            if (spec.primal_type == primal_type) return spec;
        }
        return null;
    }
};

const SnapshotNode = struct {
    snapshot: *RegistryVersion,
    next: ?*SnapshotNode,
};

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
            for (node.snapshot.specs) |spec| {
                var owned = spec;
                owned.deinit();
            }
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

    pub fn publish(self: *RegistryOwner, registrations: []const Registration) !*const RegistryVersion {
        if (registrations.len == 0) return self.current_version;
        if (self.next_version == std.math.maxInt(u64)) return error.Unsupported;
        for (registrations, 0..) |registration, index| {
            try validateRegistration(registration);
            for (registrations[0..index]) |prior| {
                if (prior.primal_type == registration.primal_type) {
                    return error.Unsupported;
                }
            }
        }

        const old = self.current_version.specs;
        var added: usize = 0;
        for (registrations) |registration| {
            var replaces = false;
            for (old) |spec| {
                if (spec.primal_type == registration.primal_type) {
                    replaces = true;
                    break;
                }
            }
            if (!replaces) {
                added = std.math.add(usize, added, 1) catch return error.Unsupported;
            }
        }
        const total = std.math.add(usize, old.len, added) catch return error.Unsupported;
        const specs = try self.allocator.alloc(SpaceSpec, total);
        var initialized: usize = 0;
        errdefer {
            for (specs[0..initialized]) |*spec| spec.deinit();
            self.allocator.free(specs);
        }
        for (old) |spec| {
            specs[initialized] = try cloneSpec(self.allocator, spec);
            initialized += 1;
        }
        var used = initialized;
        for (registrations) |registration| {
            const candidate = try cloneRegistration(self.allocator, registration, self.next_version);
            var replaced = false;
            for (specs[0..used]) |*existing| {
                if (existing.primal_type != candidate.primal_type) continue;
                existing.deinit();
                existing.* = candidate;
                replaced = true;
                break;
            }
            if (!replaced) {
                specs[used] = candidate;
                used += 1;
                initialized += 1;
            }
        }
        std.debug.assert(initialized == specs.len);
        std.debug.assert(used == specs.len);
        const snapshot = try self.allocator.create(RegistryVersion);
        errdefer self.allocator.destroy(snapshot);
        snapshot.* = .{ .version = self.next_version, .specs = specs };
        const node = try self.allocator.create(SnapshotNode);
        node.* = .{ .snapshot = snapshot, .next = self.snapshots };
        self.snapshots = node;
        self.next_version += 1;
        self.current_version = snapshot;
        return snapshot;
    }

    fn buildSnapshot(self: *RegistryOwner, specs: []const SpaceSpec, version: u64) !*RegistryVersion {
        const owned = try self.allocator.dupe(SpaceSpec, specs);
        errdefer self.allocator.free(owned);
        const snapshot = try self.allocator.create(RegistryVersion);
        errdefer self.allocator.destroy(snapshot);
        snapshot.* = .{ .version = version, .specs = owned };
        const node = try self.allocator.create(SnapshotNode);
        node.* = .{ .snapshot = snapshot, .next = self.snapshots };
        self.snapshots = node;
        return snapshot;
    }
};

fn validateRegistration(registration: Registration) Error!void {
    const type_index = @intFromEnum(registration.primal_type);
    if (registration.primal_type == .null or type_index <= skript.builtins.type_last_idx) {
        return error.Unsupported;
    }
    if (registration.implementation_revision == 0) return error.Unsupported;
    var candidate: SpaceSpec = .{
        .implementation_revision = registration.implementation_revision,
        .primal_type = registration.primal_type,
        .dimension = registration.dimension,
        .tangent = registration.tangent,
        .cotangent = registration.cotangent,
        .pairing = registration.pairing,
        .metric = registration.metric,
    };
    try candidate.validate();
}

fn cloneSpec(allocator: Allocator, source: SpaceSpec) Allocator.Error!SpaceSpec {
    var result = source;
    result.allocator = allocator;
    switch (source.metric) {
        .diagonal => |weights| result.metric = .{ .diagonal = try allocator.dupe(f64, weights) },
        else => {},
    }
    return result;
}

fn cloneRegistration(
    allocator: Allocator,
    registration: Registration,
    version: u64,
) Allocator.Error!SpaceSpec {
    var result: SpaceSpec = .{
        .allocator = allocator,
        .version = version,
        .implementation_revision = registration.implementation_revision,
        .primal_type = registration.primal_type,
        .dimension = registration.dimension,
        .tangent = registration.tangent,
        .cotangent = registration.cotangent,
        .pairing = registration.pairing,
        .metric = registration.metric,
    };
    switch (registration.metric) {
        .diagonal => |weights| result.metric = .{ .diagonal = try allocator.dupe(f64, weights) },
        else => {},
    }
    return result;
}

/// Register a host-defined space. Skript hooks are carried in `Registration`
/// and always run through the caller's restricted capability context.
pub fn register(owner: *RegistryOwner, registration: Registration) Error!u64 {
    const snapshot = try owner.publish(&.{registration});
    return snapshot.version;
}

/// Native entry point for scalar-space registration.
///
/// Arguments:
/// `(primal-type revision dimension-or-nil tangent-type-or-nil
///   cotangent-type-or-nil tangent-construct-or-nil cotangent-construct-or-nil
///   tangent-zero tangent-add tangent-scale tangent-check-or-nil
///   cotangent-zero cotangent-add cotangent-scale cotangent-check-or-nil pairing)`.
/// Register a host-defined scalar or record space.
///
/// The first sixteen arguments retain the original protocol. A seventeenth
/// optional map can add basis hooks and a metric without changing old callers.
pub fn registerSpace(
    ctx: *EvalContext,
    namespace: Value,
    _: Value,
    args: []const Value,
) Error!Value {
    const scope = ctx.activate();
    defer scope.deinit();
    if (args.len < 16 or args.len > 17) return error.ArityMismatch;
    if (ctx.execution == .pure_limited) return error.Denied;
    if (ctx.effects.state_write != .allow) return error.Denied;
    if (args[0].typ != skript.builtins.type_type) return error.TypeMismatch;
    if (args[1].typ != skript.builtins.type_i64 or args[1].obj.toInt(i64) <= 0) {
        return error.TypeMismatch;
    }
    var dimension = try optionalDimension(args[2]);
    const tangent_type = try optionalType(args[3]);
    const cotangent_type = try optionalType(args[4]);
    var tangent_construct = try optionalHook(args[5]);
    var cotangent_construct = try optionalHook(args[6]);
    const tangent_zero = try requiredHook(args[7]);
    const tangent_add = try requiredHook(args[8]);
    const tangent_scale = try requiredHook(args[9]);
    const tangent_check = try optionalHook(args[10]);
    const cotangent_zero = try requiredHook(args[11]);
    const cotangent_add = try requiredHook(args[12]);
    const cotangent_scale = try requiredHook(args[13]);
    const cotangent_check = try optionalHook(args[14]);
    const pairing = try requiredHook(args[15]);
    var tangent_basis: ?Hook = null;
    var cotangent_basis: ?Hook = null;
    var metric: Metric = .none;

    if (args.len == 17 and !Value.isNil(args[16])) {
        const options = args[16];
        try validateSpaceOptions(ctx, options);
        if (try mapFieldPresent(ctx, options, "dimension")) {
            const option_dimension = try optionalDimension(try mapField(ctx, options, "dimension"));
            if (dimension) |old| {
                if (option_dimension == null or option_dimension.? != old) return error.TypeMismatch;
            } else {
                dimension = option_dimension;
            }
        }
        if (try mapFieldPresent(ctx, options, "tangent-basis")) {
            tangent_basis = try optionalHook(try mapField(ctx, options, "tangent-basis"));
        }
        if (try mapFieldPresent(ctx, options, "cotangent-basis")) {
            cotangent_basis = try optionalHook(try mapField(ctx, options, "cotangent-basis"));
        }
        if (try mapFieldPresent(ctx, options, "tangent-construct")) {
            const option_hook = try optionalHook(try mapField(ctx, options, "tangent-construct"));
            if (tangent_construct != null and option_hook != null) return error.TypeMismatch;
            if (tangent_construct == null) tangent_construct = option_hook;
        }
        if (try mapFieldPresent(ctx, options, "cotangent-construct")) {
            const option_hook = try optionalHook(try mapField(ctx, options, "cotangent-construct"));
            if (cotangent_construct != null and option_hook != null) return error.TypeMismatch;
            if (cotangent_construct == null) cotangent_construct = option_hook;
        }
        if (try mapFieldPresent(ctx, options, "metric")) {
            metric = try parseMetricOption(ctx, try mapField(ctx, options, "metric"), namespace);
        }
    }
    defer switch (metric) {
        .diagonal => |weights| ctx.scratch.free(weights),
        else => {},
    };
    if (tangent_type == null and tangent_check == null) return error.TypeMismatch;
    if (cotangent_type == null and cotangent_check == null) return error.TypeMismatch;
    const registration: Registration = .{
        .primal_type = args[0].obj,
        .implementation_revision = @intCast(args[1].obj.toInt(i64)),
        .dimension = dimension,
        .tangent = .{
            .representation_type = tangent_type orelse .null,
            .namespace = namespace,
            .zero_hook = tangent_zero,
            .add_hook = tangent_add,
            .scale_hook = tangent_scale,
            .check_hook = tangent_check,
            .basis_hook = tangent_basis,
            .construct_hook = tangent_construct,
        },
        .cotangent = .{
            .representation_type = cotangent_type orelse .null,
            .namespace = namespace,
            .zero_hook = cotangent_zero,
            .add_hook = cotangent_add,
            .scale_hook = cotangent_scale,
            .check_hook = cotangent_check,
            .basis_hook = cotangent_basis,
            .construct_hook = cotangent_construct,
        },
        .pairing = .{ .namespace = namespace, .hook = pairing },
        .metric = metric,
    };
    const snapshot = ctx.runtime.space_registry.publish(&.{registration}) catch |publish_error| switch (publish_error) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TypeMismatch,
    };
    const version = std.math.cast(i64, snapshot.version) orelse return error.Unsupported;
    return .i64(version);
}

fn isCallable(value: Value) bool {
    return switch (value.typ) {
        skript.builtins.type_closure,
        skript.builtins.type_intrinsic,
        skript.builtins.type_method,
        => true,
        else => false,
    };
}

fn requiredHook(value: Value) Error!Hook {
    if (!isCallable(value)) return error.TypeMismatch;
    return value;
}

fn optionalHook(value: Value) Error!?Hook {
    if (Value.isNil(value)) return null;
    const hook = try requiredHook(value);
    return hook;
}

fn optionalType(value: Value) Error!?Object {
    if (value.isNil()) return null;
    if (value.typ != skript.builtins.type_type) return error.TypeMismatch;
    if (value.obj == .null) return error.TypeMismatch;
    return value.obj;
}

fn optionalDimension(value: Value) Error!?usize {
    if (value.isNil()) return null;
    if (value.typ != skript.builtins.type_i64) return error.TypeMismatch;
    const raw = value.obj.toInt(i64);
    if (raw <= 0) return error.TypeMismatch;
    return std.math.cast(usize, raw) orelse return error.TypeMismatch;
}

fn keywordText(value: Value) ?[]const u8 {
    if (value.typ != skript.builtins.type_keyword or value.obj == .null) return null;
    return value.obj.toPtr(skript.Sym).*;
}

fn mapFieldPresent(ctx: *EvalContext, map: Value, name: []const u8) Error!bool {
    if (map.typ != skript.builtins.type_map or map.obj == .null) return error.TypeMismatch;
    const key = Value.keyword(try ctx.runtime.store.getsym(name));
    const result = try map_intrin.has(ctx, .nil, .nil, &.{ map, key });
    if (result.typ != skript.builtins.type_bool) return error.TypeMismatch;
    return result.obj.toBool();
}

fn mapField(ctx: *EvalContext, map: Value, name: []const u8) Error!Value {
    const key = Value.keyword(try ctx.runtime.store.getsym(name));
    return map_intrin.get(ctx, .nil, .nil, &.{ map, key });
}

fn validateSpaceOptions(ctx: *EvalContext, options: Value) Error!void {
    if (options.typ != skript.builtins.type_map or options.obj == .null) {
        return error.TypeMismatch;
    }
    const allowed = [_][]const u8{
        "dimension",
        "tangent-basis",
        "cotangent-basis",
        "tangent-construct",
        "cotangent-construct",
        "metric",
    };
    const keys = try map_intrin.keys(ctx, .nil, .nil, &.{options});
    var cursor = keys;
    var count: usize = 0;
    while (cursor.typ == skript.builtins.type_cons) {
        if (count >= allowed.len) return error.TypeMismatch;
        const cell = cursor.obj.toRef().deref([2]Value);
        const text = keywordText(cell[0]) orelse return error.TypeMismatch;
        var known = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, text, name)) {
                known = true;
                break;
            }
        }
        if (!known) return error.TypeMismatch;
        cursor = cell[1];
        count += 1;
        try chargeWork(ctx, 1);
    }
    if (!Value.isNil(cursor)) return error.TypeMismatch;
}

fn parseDiagonal(ctx: *EvalContext, value: Value) Error![]const f64 {
    var weights: std.ArrayList(f64) = .empty;
    errdefer weights.deinit(ctx.scratch);
    var cursor = value;
    while (cursor.typ == skript.builtins.type_cons) {
        if (weights.items.len >= 16_384) return error.Unsupported;
        const cell = cursor.obj.toRef().deref([2]Value);
        try weights.append(ctx.scratch, try tree.asF64(cell[0]));
        cursor = cell[1];
        try chargeWork(ctx, 1);
    }
    if (!Value.isNil(cursor)) return error.TypeMismatch;
    if (weights.items.len == 0) return error.Unsupported;
    return weights.toOwnedSlice(ctx.scratch);
}

fn parseMetricOption(ctx: *EvalContext, value: Value, namespace: Value) Error!Metric {
    if (Value.isNil(value)) return .none;
    if (keywordText(value)) |text| {
        if (std.mem.eql(u8, text, "none")) return .none;
        if (std.mem.eql(u8, text, "identity")) return .identity;
        return error.TypeMismatch;
    }
    if (isCallable(value)) {
        return .{ .hook = .{ .namespace = namespace, .function = value } };
    }
    if (value.typ == skript.builtins.type_cons) {
        return .{ .diagonal = try parseDiagonal(ctx, value) };
    }
    if (value.typ != skript.builtins.type_map or value.obj == .null) {
        return error.TypeMismatch;
    }
    const kind = keywordText(try mapField(ctx, value, "kind")) orelse return error.TypeMismatch;
    if (std.mem.eql(u8, kind, "none")) return .none;
    if (std.mem.eql(u8, kind, "identity")) return .identity;
    if (std.mem.eql(u8, kind, "diagonal")) {
        return .{ .diagonal = try parseDiagonal(ctx, try mapField(ctx, value, "weights")) };
    }
    if (std.mem.eql(u8, kind, "hook")) {
        const function = try requiredHook(try mapField(ctx, value, "hook"));
        return .{ .hook = .{ .namespace = namespace, .function = function } };
    }
    return error.TypeMismatch;
}

fn restrictedHookContext(ctx: *EvalContext) Error!EvalContext {
    var restricted = try ctx.enter(.transform);
    restricted.execution = .pure_limited;
    // Hooks can inspect declared argument state only when the caller permits it.
    restricted.effects = .{};
    restricted.effects.state_read = ctx.effects.state_read;
    restricted.allow_suspend = false;
    restricted.reservation = null;
    return restricted;
}

fn callHook(
    ctx: *EvalContext,
    namespace: Value,
    hook: Hook,
    args: []const Value,
) Error!Value {
    var restricted = try restrictedHookContext(ctx);
    const scope = restricted.activate();
    defer scope.deinit();
    return (try restricted.apply(namespace, hook, args)).unwrapError();
}

fn numericZero(ctx: *EvalContext, runtime_type: Object, _: ?*const anyopaque) Error!Value {
    try chargeWork(ctx, 1);
    return tree.zero(runtime_type);
}

fn numericCheck(
    ctx: *EvalContext,
    runtime_type: Object,
    value: Value,
    _: ?*const anyopaque,
) Error!void {
    try chargeWork(ctx, 1);
    if (value.typ != runtime_type) return error.TypeMismatch;
}

fn numericAdd(
    ctx: *EvalContext,
    runtime_type: Object,
    left: Value,
    right: Value,
    _: ?*const anyopaque,
) Error!Value {
    try chargeWork(ctx, 1);
    const left_value = try tree.coerceNumeric(runtime_type, left);
    const right_value = try tree.coerceNumeric(runtime_type, right);
    return switch (tree.numericKind(runtime_type) orelse return error.TypeMismatch) {
        .f16 => .f16(left_value.obj.tof16() + right_value.obj.tof16()),
        .f32 => .f32(left_value.obj.tof32() + right_value.obj.tof32()),
        .f64 => .f64(left_value.obj.tof64() + right_value.obj.tof64()),
        .i8 => .i8(std.math.add(i8, left_value.obj.toInt(i8), right_value.obj.toInt(i8)) catch
            return error.Unsupported),
        .i16 => .i16(std.math.add(i16, left_value.obj.toInt(i16), right_value.obj.toInt(i16)) catch
            return error.Unsupported),
        .i32 => .i32(std.math.add(i32, left_value.obj.toInt(i32), right_value.obj.toInt(i32)) catch
            return error.Unsupported),
        .i64 => .i64(std.math.add(i64, left_value.obj.toInt(i64), right_value.obj.toInt(i64)) catch
            return error.Unsupported),
        .u8 => .u8(std.math.add(u8, left_value.obj.toInt(u8), right_value.obj.toInt(u8)) catch
            return error.Unsupported),
        .u16 => .u16(std.math.add(u16, left_value.obj.toInt(u16), right_value.obj.toInt(u16)) catch
            return error.Unsupported),
        .u32 => .u32(std.math.add(u32, left_value.obj.toInt(u32), right_value.obj.toInt(u32)) catch
            return error.Unsupported),
        .u64 => .u64(std.math.add(u64, left_value.obj.toInt(u64), right_value.obj.toInt(u64)) catch
            return error.Unsupported),
    };
}
fn numericScale(
    ctx: *EvalContext,
    runtime_type: Object,
    value: Value,
    factor: Value,
    _: ?*const anyopaque,
) Error!Value {
    try chargeWork(ctx, 1);
    const left = try tree.coerceNumeric(runtime_type, value);
    const right = try tree.coerceNumeric(runtime_type, factor);
    return switch (tree.numericKind(runtime_type) orelse return error.TypeMismatch) {
        .f16 => .f16(left.obj.tof16() * right.obj.tof16()),
        .f32 => .f32(left.obj.tof32() * right.obj.tof32()),
        .f64 => .f64(left.obj.tof64() * right.obj.tof64()),
        .i8 => .i8(std.math.mul(i8, left.obj.toInt(i8), right.obj.toInt(i8)) catch
            return error.Unsupported),
        .i16 => .i16(std.math.mul(i16, left.obj.toInt(i16), right.obj.toInt(i16)) catch
            return error.Unsupported),
        .i32 => .i32(std.math.mul(i32, left.obj.toInt(i32), right.obj.toInt(i32)) catch
            return error.Unsupported),
        .i64 => .i64(std.math.mul(i64, left.obj.toInt(i64), right.obj.toInt(i64)) catch
            return error.Unsupported),
        .u8 => .u8(std.math.mul(u8, left.obj.toInt(u8), right.obj.toInt(u8)) catch
            return error.Unsupported),
        .u16 => .u16(std.math.mul(u16, left.obj.toInt(u16), right.obj.toInt(u16)) catch
            return error.Unsupported),
        .u32 => .u32(std.math.mul(u32, left.obj.toInt(u32), right.obj.toInt(u32)) catch
            return error.Unsupported),
        .u64 => .u64(std.math.mul(u64, left.obj.toInt(u64), right.obj.toInt(u64)) catch
            return error.Unsupported),
    };
}

fn numericBasis(
    ctx: *EvalContext,
    runtime_type: Object,
    index: usize,
    _: ?*const anyopaque,
) Error!Value {
    try chargeWork(ctx, 1);
    if (index != 0) return error.Unsupported;
    return tree.one(runtime_type);
}

fn numericPair(
    ctx: *EvalContext,
    _: Object,
    tangent: Value,
    cotangent: Value,
    _: ?*const anyopaque,
) Error!Value {
    try chargeWork(ctx, 1);
    if (tangent.typ == skript.builtins.type_i64 and cotangent.typ == skript.builtins.type_i64) {
        const product = std.math.mul(
            i64,
            tangent.obj.toInt(i64),
            cotangent.obj.toInt(i64),
        ) catch return error.Unsupported;
        return .i64(product);
    }
    return .f64((try tree.asF64(tangent)) * (try tree.asF64(cotangent)));
}

fn requireFiniteScalar(value: Value) Error!void {
    switch (value.typ) {
        skript.builtins.type_f16 => if (!std.math.isFinite(value.obj.tof16())) return error.Unsupported,
        skript.builtins.type_f32 => if (!std.math.isFinite(value.obj.tof32())) return error.Unsupported,
        skript.builtins.type_f64 => if (!std.math.isFinite(value.obj.tof64())) return error.Unsupported,
        else => {},
    }
}

/// Cotangent seeds must be finite: an infinite or NaN seed carries no
/// derivative information and must fail loudly instead of poisoning the
/// pairing. Custom opaque values stay governed by their registered check.
/// The cons spine walks iteratively; only nested cars recurse, capped to
/// bound stack use. Every visited node charges work, so finite budgets
/// observe the validation cost.
fn requireFiniteValue(ctx: *EvalContext, value: Value, depth: usize) Error!void {
    var cursor = value;
    var spine: usize = 0;
    while (true) {
        if (depth + spine >= 512) return error.Unsupported;
        try chargeWork(ctx, 1);
        if (Value.isNil(cursor)) return;
        if (cursor.typ == skript.builtins.type_cons and cursor.obj != .null) {
            const cell = cursor.obj.toRef().deref([2]Value);
            try requireFiniteValue(ctx, cell[0], depth + spine + 1);
            cursor = cell[1];
            spine += 1;
            continue;
        }
        if (cursor.typ == skript.builtins.type_tensor and cursor.obj != .null) {
            const holder = cursor.obj.toRef().deref(TensorHolder).*;
            try chargeWork(ctx, holder.data.len);
            switch (holder.inner) {
                .f64 => for (holder.data) |word| {
                    if (!std.math.isFinite(@as(f64, @bitCast(word)))) return error.Unsupported;
                },
                else => {},
            }
            return;
        }
        if (cursor.typ == skript.builtins.type_map and cursor.obj != .null) {
            const keys = try map_intrin.keys(ctx, .nil, .nil, &.{cursor});
            var key_cursor = keys;
            while (key_cursor.typ == skript.builtins.type_cons and key_cursor.obj != .null) {
                try chargeWork(ctx, 1);
                const key_cell = key_cursor.obj.toRef().deref([2]Value);
                try requireFiniteValue(ctx, try mapValue(ctx, cursor, key_cell[0]), depth + spine + 1);
                key_cursor = key_cell[1];
            }
            if (!Value.isNil(key_cursor)) return error.TypeMismatch;
            return;
        }
        if (tree.isNumeric(cursor)) return requireFiniteScalar(cursor);
        return;
    }
}

pub fn scalar(runtime_type: Object) SpaceSpec {
    return .{
        .primal_type = runtime_type,
        .dimension = 1,
        .tangent = .{
            .representation_type = runtime_type,
            .native = .{
                .zero = &numericZero,
                .add = &numericAdd,
                .scale = &numericScale,
                .check = &numericCheck,
                .basis = &numericBasis,
            },
        },
        .cotangent = .{
            .representation_type = runtime_type,
            .native = .{
                .zero = &numericZero,
                .add = &numericAdd,
                .scale = &numericScale,
                .check = &numericCheck,
                .basis = &numericBasis,
            },
        },
        .pairing = .{ .native = .{ .pair = &numericPair } },
        .metric = .identity,
    };
}

pub fn treeSpace(spec: *const tree.TreeSpec) SpaceSpec {
    return .{
        .tree_spec = spec,
        .dimension = spec.leaves.len,
        .tangent = .{},
        .cotangent = .{},
        .pairing = .{},
        .metric = .none,
    };
}

/// Resolve a structural tree into declared tangent and cotangent operations.
/// Built-in nodes use numeric coordinate algebra; custom nodes require a
/// published space registration and retain that registration's dimensions.
pub fn resolve(ctx: *EvalContext, spec: *const tree.TreeSpec) Error!SpaceSpec {
    const scope = ctx.activate();
    defer scope.deinit();
    const registry = ctx.runtime.space_registry.current();
    const root = spec.node(spec.root);
    if (root.kind == .custom) {
        const registered = registry.find(root.runtime_type) orelse return error.Unsupported;
        try registered.validate();
        if (registered.dimension == null) return error.Unsupported;
        var result = registered.*;
        result.allocator = null;
        result.version = registry.version;
        result.space_registry = registry;
        return result;
    }
    const info = try resolveNodeInfo(ctx, registry, spec, spec.root);
    var result = treeSpace(spec);
    result.space_registry = registry;
    result.version = registry.version;
    result.dimension = info.dimension;
    result.metric = if (info.has_metric) .identity else .none;
    return result;
}

fn metricIsPresent(metric: Metric) bool {
    return switch (metric) {
        .none => false,
        else => true,
    };
}

fn resolveNodeInfo(
    ctx: *EvalContext,
    registry: *const RegistryVersion,
    spec: *const tree.TreeSpec,
    node_id: tree.NodeId,
) Error!NodeInfo {
    try chargeWork(ctx, 1);
    const tree_node = spec.node(node_id);
    return switch (tree_node.kind) {
        .scalar => .{ .dimension = 1, .has_metric = true },
        .tensor => .{ .dimension = @intCast(tree_node.leaves.len), .has_metric = true },
        .list, .map => blk: {
            var dimension: usize = 0;
            var has_metric = true;
            for (spec.children(tree_node)) |child| {
                const child_info = try resolveNodeInfo(ctx, registry, spec, child);
                dimension = std.math.add(usize, dimension, child_info.dimension) catch
                    return error.Unsupported;
                has_metric = has_metric and child_info.has_metric;
            }
            break :blk .{ .dimension = dimension, .has_metric = has_metric };
        },
        .custom => {
            const registered = registry.find(tree_node.runtime_type) orelse return error.Unsupported;
            try registered.validate();
            const dimension = registered.dimension orelse return error.Unsupported;
            return .{
                .dimension = dimension,
                .has_metric = metricIsPresent(registered.metric),
            };
        },
    };
}

fn customSpace(space: *const SpaceSpec, node: *const tree.Node) Error!*const SpaceSpec {
    const registry = space.space_registry orelse return error.Unsupported;
    const registered = registry.find(node.runtime_type) orelse return error.Unsupported;
    try registered.validate();
    return registered;
}

fn dualCheck(
    space: *const SpaceSpec,
    ctx: *EvalContext,
    node: *const tree.Node,
    value: Value,
    dual: Dual,
) Error!void {
    const registered = try customSpace(space, node);
    switch (dual) {
        .tangent => try registered.tangentCheck(ctx, value),
        .cotangent => try registered.cotangentCheck(ctx, value),
    }
}

fn dualZero(
    space: *const SpaceSpec,
    ctx: *EvalContext,
    node: *const tree.Node,
    dual: Dual,
) Error!Value {
    const registered = try customSpace(space, node);
    return switch (dual) {
        .tangent => registered.tangentZero(ctx),
        .cotangent => registered.cotangentZero(ctx),
    };
}

fn dualAdd(
    space: *const SpaceSpec,
    ctx: *EvalContext,
    node: *const tree.Node,
    left: Value,
    right: Value,
    dual: Dual,
) Error!Value {
    const registered = try customSpace(space, node);
    return switch (dual) {
        .tangent => registered.tangentAdd(ctx, left, right),
        .cotangent => registered.cotangentAdd(ctx, left, right),
    };
}

fn dualScale(
    space: *const SpaceSpec,
    ctx: *EvalContext,
    node: *const tree.Node,
    value: Value,
    factor: Value,
    dual: Dual,
) Error!Value {
    const registered = try customSpace(space, node);
    return switch (dual) {
        .tangent => registered.tangentScale(ctx, value, factor),
        .cotangent => registered.cotangentScale(ctx, value, factor),
    };
}

fn dualBasis(
    space: *const SpaceSpec,
    ctx: *EvalContext,
    node: *const tree.Node,
    index: usize,
    dual: Dual,
) Error!Value {
    const registered = try customSpace(space, node);
    return switch (dual) {
        .tangent => registered.tangentBasis(ctx, index),
        .cotangent => registered.cotangentBasis(ctx, index),
    };
}

fn readListValues(ctx: *EvalContext, value: Value, expected: usize) Error!ListValues {
    const allocator = scratchAllocator(ctx);
    const values = try allocator.alloc(Value, expected);
    errdefer allocator.free(values);
    var cursor = value;
    for (values) |*item| {
        if (cursor.typ != skript.builtins.type_cons or cursor.obj == .null) return error.TypeMismatch;
        const cell = cursor.obj.toRef().deref([2]Value);
        item.* = cell[0];
        cursor = cell[1];
        try chargeWork(ctx, 1);
    }
    if (!Value.isNil(cursor)) return error.TypeMismatch;
    return .{ .allocator = allocator, .values = values };
}

fn mapCount(ctx: *EvalContext, value: Value, limit: usize) Error!usize {
    if (value.typ != skript.builtins.type_map or value.obj == .null) return error.TypeMismatch;
    const keys = try map_intrin.keys(ctx, .nil, .nil, &.{value});
    var cursor = keys;
    var count: usize = 0;
    while (cursor.typ == skript.builtins.type_cons) {
        if (count >= limit) return error.Unsupported;
        const cell = cursor.obj.toRef().deref([2]Value);
        _ = cell[0];
        cursor = cell[1];
        count += 1;
        try chargeWork(ctx, 1);
    }
    if (!Value.isNil(cursor)) return error.TypeMismatch;
    return count;
}

fn mapValue(ctx: *EvalContext, map: Value, key: Value) Error!Value {
    if (map.typ != skript.builtins.type_map or map.obj == .null) return error.TypeMismatch;
    const present = try map_intrin.has(ctx, .nil, .nil, &.{ map, key });
    if (present.typ != skript.builtins.type_bool or !present.obj.toBool()) {
        return error.TypeMismatch;
    }
    return map_intrin.get(ctx, .nil, .nil, &.{ map, key });
}

fn makeListValues(ctx: *EvalContext, values: []const Value) Error!Value {
    var result: Value = .nil;
    var index = values.len;
    while (index > 0) {
        index -= 1;
        try chargeWork(ctx, 1);
        const reference = try ctx.runtime.store.create([2]Value);
        reference.deref([2]Value).* = .{ values[index], result };
        result = .cons(reference.toObject());
    }
    return result;
}

fn makeMapValues(
    ctx: *EvalContext,
    keys: []const Value,
    values: []const Value,
) Error!Value {
    if (keys.len != values.len) return error.ArityMismatch;
    const pair_count = std.math.mul(usize, keys.len, 2) catch return error.Unsupported;
    const pairs = try scratchAllocator(ctx).alloc(Value, pair_count);
    defer scratchAllocator(ctx).free(pairs);
    for (keys, values, 0..) |key, value, index| {
        pairs[index * 2] = key;
        pairs[index * 2 + 1] = value;
    }
    return map_intrin.create(ctx, .nil, .nil, pairs);
}

fn tensorValue(inner: TensorInner, word: u64) Error!Value {
    return switch (inner) {
        .i64 => .i64(@bitCast(word)),
        .f64 => .f64(@bitCast(word)),
        .empty => error.TypeMismatch,
        else => error.TypeMismatch,
    };
}

fn makeTensorValue(
    ctx: *EvalContext,
    inner: TensorInner,
    shape_source: []const u32,
    values: []const Value,
) Error!Value {
    try chargeWork(ctx, values.len);
    const shape = try ctx.runtime.store.allocSlice(u32, shape_source.len);
    errdefer ctx.runtime.store.discardUnpublished(shape.ref) catch unreachable;
    @memcpy(shape.slice, shape_source);
    const data = try ctx.runtime.store.allocSlice(u64, values.len);
    errdefer ctx.runtime.store.discardUnpublished(data.ref) catch unreachable;
    for (data.slice, values) |*word, value| {
        word.* = try tree.tensorWord(inner, value);
    }
    const reference = try ctx.runtime.store.createTraced(
        TensorHolder,
        skript.intrinsics.tensor.traceTensorHolder,
    );
    reference.deref(TensorHolder).* = .{
        .inner = inner,
        .rank = @intCast(shape.slice.len),
        .shape = shape.slice,
        .data = data.slice,
        .shape_ref = shape.ref,
        .data_ref = data.ref,
    };
    return .tensor(reference.toObject());
}

fn readTensorValues(
    ctx: *EvalContext,
    spec: *const tree.TreeSpec,
    node: *const tree.Node,
    value: Value,
) Error!ListValues {
    if (value.typ != skript.builtins.type_tensor or value.obj == .null) {
        return error.TypeMismatch;
    }
    const tensor = node.kind.tensor;
    const holder = value.obj.toRef().deref(TensorHolder).*;
    const shape = spec.tensorShape(tensor);
    const rank = std.math.cast(u32, shape.len) orelse return error.Unsupported;
    if (holder.inner != tensor.inner) return error.TypeMismatch;
    if (holder.rank != rank or !std.mem.eql(u32, holder.shape, shape)) {
        return error.TypeMismatch;
    }
    if (holder.data.len != @as(usize, @intCast(node.leaves.len))) return error.TypeMismatch;
    const allocator = scratchAllocator(ctx);
    const values = try allocator.alloc(Value, holder.data.len);
    errdefer allocator.free(values);
    for (values, holder.data) |*out, word| {
        out.* = try tensorValue(holder.inner, word);
        try chargeWork(ctx, 1);
    }
    return .{ .allocator = allocator, .values = values };
}

fn tensorRuntimeType(inner: TensorInner) Error!Object {
    return switch (inner) {
        .i64 => skript.builtins.type_i64,
        .f64 => skript.builtins.type_f64,
        else => error.TypeMismatch,
    };
}

fn composedCheckNode(
    space: *const SpaceSpec,
    spec: *const tree.TreeSpec,
    node_id: tree.NodeId,
    ctx: *EvalContext,
    value: Value,
    dual: Dual,
) Error!void {
    const tree_node = spec.node(node_id);
    switch (tree_node.kind) {
        .scalar => {
            _ = try tree.coerceNumeric(tree_node.runtime_type, value);
        },
        .tensor => {
            var values = try readTensorValues(ctx, spec, tree_node, value);
            values.deinit();
        },
        .list => {
            var values = try readListValues(ctx, value, spec.children(tree_node).len);
            defer values.deinit();
            for (spec.children(tree_node), values.values) |child, child_value| {
                try composedCheckNode(space, spec, child, ctx, child_value, dual);
            }
        },
        .map => {
            const children = spec.children(tree_node);
            const keys = spec.keys(tree_node);
            if (children.len != keys.len) return error.TypeMismatch;
            const map_limit = std.math.add(usize, children.len, 1) catch return error.Unsupported;
            if (try mapCount(ctx, value, map_limit) != children.len) {
                return error.TypeMismatch;
            }
            for (children, keys) |child, key| {
                const child_value = try mapValue(ctx, value, key);
                try composedCheckNode(space, spec, child, ctx, child_value, dual);
            }
        },
        .custom => try dualCheck(space, ctx, tree_node, value, dual),
    }
}

fn composedZeroNode(
    space: *const SpaceSpec,
    spec: *const tree.TreeSpec,
    node_id: tree.NodeId,
    ctx: *EvalContext,
    dual: Dual,
) Error!Value {
    const tree_node = spec.node(node_id);
    switch (tree_node.kind) {
        .scalar => return tree.zero(tree_node.runtime_type),
        .tensor => |tensor| {
            const values = try scratchAllocator(ctx).alloc(Value, @intCast(tree_node.leaves.len));
            defer scratchAllocator(ctx).free(values);
            if (tensor.inner != .empty) {
                const runtime_type = try tensorRuntimeType(tensor.inner);
                for (values) |*value| {
                    value.* = try tree.zero(runtime_type);
                    try chargeWork(ctx, 1);
                }
            }
            return makeTensorValue(ctx, tensor.inner, spec.tensorShape(tensor), values);
        },
        .list => {
            const children = spec.children(tree_node);
            const values = try scratchAllocator(ctx).alloc(Value, children.len);
            defer scratchAllocator(ctx).free(values);
            for (children, values) |child, *value| {
                value.* = try composedZeroNode(space, spec, child, ctx, dual);
            }
            return makeListValues(ctx, values);
        },
        .map => {
            const children = spec.children(tree_node);
            const keys = spec.keys(tree_node);
            if (children.len != keys.len) return error.TypeMismatch;
            const values = try scratchAllocator(ctx).alloc(Value, children.len);
            defer scratchAllocator(ctx).free(values);
            for (children, values) |child, *value| {
                value.* = try composedZeroNode(space, spec, child, ctx, dual);
            }
            return makeMapValues(ctx, keys, values);
        },
        .custom => return dualZero(space, ctx, tree_node, dual),
    }
}

fn composedAddNode(
    space: *const SpaceSpec,
    spec: *const tree.TreeSpec,
    node_id: tree.NodeId,
    ctx: *EvalContext,
    left: Value,
    right: Value,
    dual: Dual,
) Error!Value {
    const tree_node = spec.node(node_id);
    switch (tree_node.kind) {
        .scalar => return numericAdd(ctx, tree_node.runtime_type, left, right, null),
        .tensor => |tensor| {
            var left_values = try readTensorValues(ctx, spec, tree_node, left);
            defer left_values.deinit();
            var right_values = try readTensorValues(ctx, spec, tree_node, right);
            defer right_values.deinit();
            if (tensor.inner == .empty) {
                return makeTensorValue(ctx, tensor.inner, spec.tensorShape(tensor), &.{});
            }
            const result = try scratchAllocator(ctx).alloc(Value, left_values.values.len);
            defer scratchAllocator(ctx).free(result);
            const runtime_type = try tensorRuntimeType(tensor.inner);
            for (result, left_values.values, right_values.values) |*out, lhs, rhs| {
                out.* = try numericAdd(ctx, runtime_type, lhs, rhs, null);
            }
            return makeTensorValue(ctx, tensor.inner, spec.tensorShape(tensor), result);
        },
        .list => {
            const children = spec.children(tree_node);
            var left_values = try readListValues(ctx, left, children.len);
            defer left_values.deinit();
            var right_values = try readListValues(ctx, right, children.len);
            defer right_values.deinit();
            const result = try scratchAllocator(ctx).alloc(Value, children.len);
            defer scratchAllocator(ctx).free(result);
            for (children, left_values.values, right_values.values, result) |child, lhs, rhs, *out| {
                out.* = try composedAddNode(space, spec, child, ctx, lhs, rhs, dual);
            }
            return makeListValues(ctx, result);
        },
        .map => {
            const children = spec.children(tree_node);
            const keys = spec.keys(tree_node);
            if (children.len != keys.len) return error.TypeMismatch;
            const result = try scratchAllocator(ctx).alloc(Value, children.len);
            defer scratchAllocator(ctx).free(result);
            for (children, keys, result) |child, key, *out| {
                const lhs = try mapValue(ctx, left, key);
                const rhs = try mapValue(ctx, right, key);
                out.* = try composedAddNode(space, spec, child, ctx, lhs, rhs, dual);
            }
            return makeMapValues(ctx, keys, result);
        },
        .custom => return dualAdd(space, ctx, tree_node, left, right, dual),
    }
}

fn composedScaleNode(
    space: *const SpaceSpec,
    spec: *const tree.TreeSpec,
    node_id: tree.NodeId,
    ctx: *EvalContext,
    value: Value,
    factor: Value,
    dual: Dual,
) Error!Value {
    const tree_node = spec.node(node_id);
    switch (tree_node.kind) {
        .scalar => return numericScale(ctx, tree_node.runtime_type, value, factor, null),
        .tensor => |tensor| {
            var source = try readTensorValues(ctx, spec, tree_node, value);
            defer source.deinit();
            if (tensor.inner == .empty) {
                return makeTensorValue(ctx, tensor.inner, spec.tensorShape(tensor), &.{});
            }
            const result = try scratchAllocator(ctx).alloc(Value, source.values.len);
            defer scratchAllocator(ctx).free(result);
            const runtime_type = try tensorRuntimeType(tensor.inner);
            for (result, source.values) |*out, item| {
                out.* = try numericScale(ctx, runtime_type, item, factor, null);
            }
            return makeTensorValue(ctx, tensor.inner, spec.tensorShape(tensor), result);
        },
        .list => {
            const children = spec.children(tree_node);
            var source = try readListValues(ctx, value, children.len);
            defer source.deinit();
            const result = try scratchAllocator(ctx).alloc(Value, children.len);
            defer scratchAllocator(ctx).free(result);
            for (children, source.values, result) |child, item, *out| {
                out.* = try composedScaleNode(space, spec, child, ctx, item, factor, dual);
            }
            return makeListValues(ctx, result);
        },
        .map => {
            const children = spec.children(tree_node);
            const keys = spec.keys(tree_node);
            if (children.len != keys.len) return error.TypeMismatch;
            const result = try scratchAllocator(ctx).alloc(Value, children.len);
            defer scratchAllocator(ctx).free(result);
            for (children, keys, result) |child, key, *out| {
                const item = try mapValue(ctx, value, key);
                out.* = try composedScaleNode(space, spec, child, ctx, item, factor, dual);
            }
            return makeMapValues(ctx, keys, result);
        },
        .custom => return dualScale(space, ctx, tree_node, value, factor, dual),
    }
}

fn composedBasisNode(
    space: *const SpaceSpec,
    spec: *const tree.TreeSpec,
    node_id: tree.NodeId,
    ctx: *EvalContext,
    target: usize,
    dual: Dual,
) Error!Value {
    var offset: usize = 0;
    return basisNode(space, spec, node_id, ctx, target, &offset, dual);
}

fn basisNode(
    space: *const SpaceSpec,
    spec: *const tree.TreeSpec,
    node_id: tree.NodeId,
    ctx: *EvalContext,
    target: usize,
    offset: *usize,
    dual: Dual,
) Error!Value {
    try chargeWork(ctx, 1);
    const tree_node = spec.node(node_id);
    switch (tree_node.kind) {
        .scalar => {
            const selected = target == offset.*;
            offset.* = std.math.add(usize, offset.*, 1) catch return error.Unsupported;
            return if (selected) tree.one(tree_node.runtime_type) else tree.zero(tree_node.runtime_type);
        },
        .tensor => |tensor| {
            const count: usize = @intCast(tree_node.leaves.len);
            const end = std.math.add(usize, offset.*, count) catch return error.Unsupported;
            const selected = target >= offset.* and target < end;
            try chargeWork(ctx, count);
            const values = try scratchAllocator(ctx).alloc(Value, count);
            defer scratchAllocator(ctx).free(values);
            if (tensor.inner != .empty) {
                const runtime_type = try tensorRuntimeType(tensor.inner);
                for (values, 0..) |*value, index| {
                    try chargeWork(ctx, 1);
                    value.* = if (selected and target == offset.* + index)
                        try tree.one(runtime_type)
                    else
                        try tree.zero(runtime_type);
                }
            }
            offset.* = end;
            return makeTensorValue(ctx, tensor.inner, spec.tensorShape(tensor), values);
        },
        .list => {
            const children = spec.children(tree_node);
            try chargeWork(ctx, children.len);
            const values = try scratchAllocator(ctx).alloc(Value, children.len);
            defer scratchAllocator(ctx).free(values);
            for (children, values) |child, *value| {
                value.* = try basisNode(space, spec, child, ctx, target, offset, dual);
            }
            return makeListValues(ctx, values);
        },
        .map => {
            const children = spec.children(tree_node);
            const keys = spec.keys(tree_node);
            if (children.len != keys.len) return error.TypeMismatch;
            try chargeWork(ctx, children.len);
            const values = try scratchAllocator(ctx).alloc(Value, children.len);
            defer scratchAllocator(ctx).free(values);
            for (children, values) |child, *value| {
                value.* = try basisNode(space, spec, child, ctx, target, offset, dual);
            }
            return makeMapValues(ctx, keys, values);
        },
        .custom => {
            const registered = try customSpace(space, tree_node);
            const dimension = registered.dimension orelse return error.Unsupported;
            const end = std.math.add(usize, offset.*, dimension) catch return error.Unsupported;
            try chargeWork(ctx, 1);
            if (target < offset.* or target >= end) {
                offset.* = end;
                return switch (dual) {
                    .tangent => registered.tangentZero(ctx),
                    .cotangent => registered.cotangentZero(ctx),
                };
            }
            const local = target - offset.*;
            offset.* = end;
            return dualBasis(space, ctx, tree_node, local, dual);
        },
    }
}

fn composedCoordinatesNode(
    space: *const SpaceSpec,
    spec: *const tree.TreeSpec,
    node_id: tree.NodeId,
    ctx: *EvalContext,
    coordinates: []const Value,
    offset: *usize,
    dual: Dual,
) Error!Value {
    const tree_node = spec.node(node_id);
    switch (tree_node.kind) {
        .scalar => {
            if (offset.* >= coordinates.len) return error.ArityMismatch;
            const result = try tree.coerceNumeric(tree_node.runtime_type, coordinates[offset.*]);
            offset.* = std.math.add(usize, offset.*, 1) catch return error.Unsupported;
            return result;
        },
        .tensor => |tensor| {
            const count: usize = @intCast(tree_node.leaves.len);
            const end = std.math.add(usize, offset.*, count) catch return error.Unsupported;
            if (end > coordinates.len) return error.ArityMismatch;
            if (tensor.inner == .empty) {
                offset.* = end;
                return makeTensorValue(ctx, tensor.inner, spec.tensorShape(tensor), &.{});
            }
            const runtime_type = try tensorRuntimeType(tensor.inner);
            const values = try scratchAllocator(ctx).alloc(Value, count);
            defer scratchAllocator(ctx).free(values);
            for (values, coordinates[offset.*..end]) |*out, coordinate| {
                out.* = try tree.coerceNumeric(runtime_type, coordinate);
            }
            offset.* = end;
            return makeTensorValue(ctx, tensor.inner, spec.tensorShape(tensor), values);
        },
        .list => {
            const children = spec.children(tree_node);
            const values = try scratchAllocator(ctx).alloc(Value, children.len);
            defer scratchAllocator(ctx).free(values);
            for (children, values) |child, *value| {
                value.* = try composedCoordinatesNode(space, spec, child, ctx, coordinates, offset, dual);
            }
            return makeListValues(ctx, values);
        },
        .map => {
            const children = spec.children(tree_node);
            const keys = spec.keys(tree_node);
            if (children.len != keys.len) return error.TypeMismatch;
            const values = try scratchAllocator(ctx).alloc(Value, children.len);
            defer scratchAllocator(ctx).free(values);
            for (children, values) |child, *value| {
                value.* = try composedCoordinatesNode(space, spec, child, ctx, coordinates, offset, dual);
            }
            return makeMapValues(ctx, keys, values);
        },
        .custom => {
            if (dual != .cotangent) return error.Unsupported;
            const registered = try customSpace(space, tree_node);
            const dimension = registered.dimension orelse return error.Unsupported;
            const end = std.math.add(usize, offset.*, dimension) catch return error.Unsupported;
            if (end > coordinates.len) return error.ArityMismatch;
            const result = try registered.cotangentFromCoordinates(
                ctx,
                coordinates[offset.*..end],
            );
            offset.* = end;
            return result;
        },
    }
}

fn coordinatesToCotangent(
    space: *const SpaceSpec,
    ctx: *EvalContext,
    coordinates: []const Value,
) Error!Value {
    if (space.cotangent.construct_hook != null) {
        const list = try makeListValues(ctx, coordinates);
        return space.cotangent.construct(ctx, space.primal_type, list);
    }
    var result = try space.cotangentZero(ctx);
    for (coordinates, 0..) |coordinate, index| {
        const basis = try space.cotangentBasis(ctx, index);
        const scaled = try space.cotangentScale(ctx, basis, coordinate);
        result = try space.cotangentAdd(ctx, result, scaled);
    }
    return result;
}

fn identifyByMetricBasis(
    space: *const SpaceSpec,
    ctx: *EvalContext,
    cotangent: Value,
    weights: []const f64,
) Error!Value {
    const dimension = space.dimension orelse return error.Unsupported;
    if (weights.len != dimension) return error.ArityMismatch;
    var result = try space.tangentZero(ctx);
    for (weights, 0..) |weight, index| {
        const basis = try space.tangentBasis(ctx, index);
        const coordinate = try space.pair(ctx, basis, cotangent);
        const scaled_coordinate = try metricDivide(coordinate, weight);
        const scaled = try space.tangentScale(ctx, basis, scaled_coordinate);
        result = try space.tangentAdd(ctx, result, scaled);
    }
    return result;
}

fn composedPairNode(
    space: *const SpaceSpec,
    spec: *const tree.TreeSpec,
    node_id: tree.NodeId,
    ctx: *EvalContext,
    tangent: Value,
    cotangent: Value,
) Error!Value {
    const tree_node = spec.node(node_id);
    switch (tree_node.kind) {
        .scalar => return numericPair(ctx, .null, tangent, cotangent, null),
        .tensor => {
            var tangent_values = try readTensorValues(ctx, spec, tree_node, tangent);
            defer tangent_values.deinit();
            var cotangent_values = try readTensorValues(ctx, spec, tree_node, cotangent);
            defer cotangent_values.deinit();
            var result: ?Value = null;
            for (tangent_values.values, cotangent_values.values) |left, right| {
                const product = try numericPair(ctx, .null, left, right, null);
                result = if (result) |current| try addPairValues(ctx, current, product) else product;
            }
            return result orelse .f64(0.0);
        },
        .list => {
            const children = spec.children(tree_node);
            var tangent_values = try readListValues(ctx, tangent, children.len);
            defer tangent_values.deinit();
            var cotangent_values = try readListValues(ctx, cotangent, children.len);
            defer cotangent_values.deinit();
            var result: ?Value = null;
            for (children, tangent_values.values, cotangent_values.values) |child, left, right| {
                const product = try composedPairNode(space, spec, child, ctx, left, right);
                result = if (result) |current| try addPairValues(ctx, current, product) else product;
            }
            return result orelse .f64(0.0);
        },
        .map => {
            const children = spec.children(tree_node);
            const keys = spec.keys(tree_node);
            if (children.len != keys.len) return error.TypeMismatch;
            var result: ?Value = null;
            for (children, keys) |child, key| {
                const left = try mapValue(ctx, tangent, key);
                const right = try mapValue(ctx, cotangent, key);
                const product = try composedPairNode(space, spec, child, ctx, left, right);
                result = if (result) |current| try addPairValues(ctx, current, product) else product;
            }
            return result orelse .f64(0.0);
        },
        .custom => {
            const registered = try customSpace(space, tree_node);
            return registered.pair(ctx, tangent, cotangent);
        },
    }
}

fn composedIdentifyNode(
    space: *const SpaceSpec,
    spec: *const tree.TreeSpec,
    node_id: tree.NodeId,
    ctx: *EvalContext,
    cotangent: Value,
) Error!Value {
    const tree_node = spec.node(node_id);
    switch (tree_node.kind) {
        .scalar => return cotangent,
        .tensor => |tensor| {
            var values = try readTensorValues(ctx, spec, tree_node, cotangent);
            defer values.deinit();
            return makeTensorValue(ctx, tensor.inner, spec.tensorShape(tensor), values.values);
        },
        .list => {
            const children = spec.children(tree_node);
            var source = try readListValues(ctx, cotangent, children.len);
            defer source.deinit();
            const result = try scratchAllocator(ctx).alloc(Value, children.len);
            defer scratchAllocator(ctx).free(result);
            for (children, source.values, result) |child, item, *out| {
                out.* = try composedIdentifyNode(space, spec, child, ctx, item);
            }
            return makeListValues(ctx, result);
        },
        .map => {
            const children = spec.children(tree_node);
            const keys = spec.keys(tree_node);
            if (children.len != keys.len) return error.TypeMismatch;
            const result = try scratchAllocator(ctx).alloc(Value, children.len);
            defer scratchAllocator(ctx).free(result);
            for (children, keys, result) |child, key, *out| {
                out.* = try composedIdentifyNode(space, spec, child, ctx, try mapValue(ctx, cotangent, key));
            }
            return makeMapValues(ctx, keys, result);
        },
        .custom => {
            const registered = try customSpace(space, tree_node);
            return registered.identify(ctx, cotangent);
        },
    }
}

fn chargeWork(ctx: *EvalContext, count: usize) Error!void {
    const units = std.math.cast(u64, count) orelse return error.Unsupported;
    try ctx.chargeWork(units, 1, .transform);
}

fn scratchAllocator(ctx: *EvalContext) Allocator {
    return ctx.scratch;
}

fn flattenTree(
    spec: *const tree.TreeSpec,
    ctx: *EvalContext,
    value: Value,
) Error!tree.TreeSpec {
    try spec.check(scratchAllocator(ctx), ctx, value);
    return tree.flatten(scratchAllocator(ctx), ctx, spec.registry, value, spec.limits);
}

fn checkTree(spec: *const tree.TreeSpec, ctx: *EvalContext, value: Value) Error!void {
    try spec.check(scratchAllocator(ctx), ctx, value);
}

fn treeValues(spec: *const tree.TreeSpec, candidate: *tree.TreeSpec) Error![]Value {
    if (candidate.leaves.len != spec.leaves.len) return error.TypeMismatch;
    const values = try candidate.allocator.alloc(Value, candidate.leaves.len);
    for (values, candidate.leaves) |*value, leaf| value.* = leaf.primal;
    return values;
}

fn treeZero(spec: *const tree.TreeSpec, ctx: *EvalContext) Error!Value {
    const values = try scratchAllocator(ctx).alloc(Value, spec.leaves.len);
    defer scratchAllocator(ctx).free(values);
    for (values, spec.leaves) |*value, leaf| {
        try chargeWork(ctx, 1);
        value.* = try tree.zero(leaf.runtime_type);
    }
    return spec.unflatten(scratchAllocator(ctx), ctx, values);
}

fn treeAdd(
    spec: *const tree.TreeSpec,
    ctx: *EvalContext,
    left: Value,
    right: Value,
) Error!Value {
    var left_spec = try flattenTree(spec, ctx, left);
    defer left_spec.deinit();
    var right_spec = try flattenTree(spec, ctx, right);
    defer right_spec.deinit();
    const left_values = try treeValues(spec, &left_spec);
    defer left_spec.allocator.free(left_values);
    const right_values = try treeValues(spec, &right_spec);
    defer right_spec.allocator.free(right_values);
    const result = try scratchAllocator(ctx).alloc(Value, spec.leaves.len);
    defer scratchAllocator(ctx).free(result);
    for (result, left_values, right_values) |*out, left_value, right_value| {
        try chargeWork(ctx, 1);
        out.* = try numericAdd(ctx, left_value.typ, left_value, right_value, null);
    }
    return spec.unflatten(scratchAllocator(ctx), ctx, result);
}

fn treeScale(
    spec: *const tree.TreeSpec,
    ctx: *EvalContext,
    value: Value,
    scalar_value: Value,
) Error!Value {
    var value_spec = try flattenTree(spec, ctx, value);
    defer value_spec.deinit();
    const values = try treeValues(spec, &value_spec);
    defer value_spec.allocator.free(values);
    const result = try scratchAllocator(ctx).alloc(Value, spec.leaves.len);
    defer scratchAllocator(ctx).free(result);
    for (result, values) |*out, leaf| {
        try chargeWork(ctx, 1);
        out.* = try numericScale(ctx, leaf.typ, leaf, scalar_value, null);
    }
    return spec.unflatten(scratchAllocator(ctx), ctx, result);
}

fn treeBasis(spec: *const tree.TreeSpec, ctx: *EvalContext, index: usize) Error!Value {
    if (index >= spec.leaves.len) return error.Unsupported;
    const values = try scratchAllocator(ctx).alloc(Value, spec.leaves.len);
    defer scratchAllocator(ctx).free(values);
    for (values, spec.leaves) |*value, leaf| {
        try chargeWork(ctx, 1);
        value.* = try tree.zero(leaf.runtime_type);
    }
    try chargeWork(ctx, 1);
    values[index] = try tree.one(spec.leaves[index].runtime_type);
    return spec.unflatten(scratchAllocator(ctx), ctx, values);
}

fn treePair(
    spec: *const tree.TreeSpec,
    ctx: *EvalContext,
    tangent: Value,
    cotangent: Value,
) Error!Value {
    var tangent_spec = try flattenTree(spec, ctx, tangent);
    defer tangent_spec.deinit();
    var cotangent_spec = try flattenTree(spec, ctx, cotangent);
    defer cotangent_spec.deinit();
    const tangent_values = try treeValues(spec, &tangent_spec);
    defer tangent_spec.allocator.free(tangent_values);
    const cotangent_values = try treeValues(spec, &cotangent_spec);
    defer cotangent_spec.allocator.free(cotangent_values);
    var result: ?Value = null;
    for (tangent_values, cotangent_values) |left, right| {
        try chargeWork(ctx, 1);
        const product = try numericPair(ctx, .null, left, right, null);
        result = if (result) |current| try addPairValues(ctx, current, product) else product;
    }
    return result orelse .f64(0.0);
}

fn addPairValues(ctx: *EvalContext, left: Value, right: Value) Error!Value {
    if (left.typ == skript.builtins.type_i64 and right.typ == skript.builtins.type_i64) {
        return numericAdd(ctx, skript.builtins.type_i64, left, right, null);
    }
    return .f64((try tree.asF64(left)) + (try tree.asF64(right)));
}

fn metricDivide(value: Value, weight: f64) Error!Value {
    if (!std.math.isFinite(weight) or weight == 0.0) return error.Unsupported;
    if (weight == 1.0) return value;
    const kind = tree.numericKind(value.typ) orelse return error.TypeMismatch;
    switch (kind) {
        .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => {
            const source: i128 = switch (kind) {
                .i8 => value.obj.toInt(i8),
                .i16 => value.obj.toInt(i16),
                .i32 => value.obj.toInt(i32),
                .i64 => value.obj.toInt(i64),
                .u8 => value.obj.toInt(u8),
                .u16 => value.obj.toInt(u16),
                .u32 => value.obj.toInt(u32),
                .u64 => value.obj.toInt(u64),
                else => unreachable,
            };
            const quotient = try divideIntegerMetric(source, weight);
            const result: Value = if (quotient < 0)
                .i64(std.math.cast(i64, quotient) orelse return error.Unsupported)
            else
                .u64(std.math.cast(u64, quotient) orelse return error.Unsupported);
            return tree.coerceNumeric(value.typ, result);
        },
        .f16, .f32, .f64 => {
            const quotient = (try tree.asF64(value)) / weight;
            if (!std.math.isFinite(quotient)) return error.Unsupported;
            return tree.coerceNumeric(value.typ, .f64(quotient));
        },
    }
}

fn divideIntegerMetric(source: i128, weight: f64) Error!i128 {
    if (source == 0) return 0;
    const bits: u64 = @bitCast(weight);
    const biased_exponent: u11 = @truncate(bits >> 52);
    var significand = bits & ((@as(u64, 1) << 52) - 1);
    var exponent: i16 = -1074;
    if (biased_exponent != 0) {
        significand |= @as(u64, 1) << 52;
        exponent = @as(i16, biased_exponent) - 1023 - 52;
    }
    std.debug.assert(significand != 0);
    const trailing: u6 = @intCast(@ctz(significand));
    significand >>= trailing;
    exponent += trailing;
    const odd: i128 = significand;
    const magnitude = if (exponent >= 0) blk: {
        if (exponent > 64) return error.Unsupported;
        const divisor = odd << @as(u7, @intCast(exponent));
        if (@rem(source, divisor) != 0) return error.Unsupported;
        break :blk @divExact(source, divisor);
    } else blk: {
        if (@rem(source, odd) != 0) return error.Unsupported;
        if (exponent <= -64) return error.Unsupported;
        const factor = @as(i128, 1) << @as(u7, @intCast(-exponent));
        break :blk @divExact(source, odd) * factor;
    };
    return if (bits >> 63 != 0) -magnitude else magnitude;
}

fn treeDiagonalIdentify(
    spec: *const tree.TreeSpec,
    ctx: *EvalContext,
    cotangent: Value,
    weights: []const f64,
) Error!Value {
    if (weights.len != spec.leaves.len) return error.ArityMismatch;
    var cotangent_spec = try flattenTree(spec, ctx, cotangent);
    defer cotangent_spec.deinit();
    const values = try treeValues(spec, &cotangent_spec);
    defer cotangent_spec.allocator.free(values);
    const result = try scratchAllocator(ctx).alloc(Value, values.len);
    defer scratchAllocator(ctx).free(result);
    for (result, values, weights) |*out, value, weight| {
        try chargeWork(ctx, 1);
        out.* = try metricDivide(value, weight);
    }
    return spec.unflatten(scratchAllocator(ctx), ctx, result);
}

fn scalarDiagonalIdentify(
    spec: *const SpaceSpec,
    ctx: *EvalContext,
    cotangent: Value,
    weights: []const f64,
) Error!Value {
    const dimension = spec.dimension orelse return error.Unsupported;
    if (weights.len != dimension) return error.ArityMismatch;
    if (dimension != 1) return identifyByMetricBasis(spec, ctx, cotangent, weights);
    const quotient = try metricDivide(cotangent, weights[0]);
    const converted = if (spec.tangent.representation_type != .null)
        try tree.coerceNumeric(spec.tangent.representation_type, quotient)
    else
        quotient;
    return spec.tangent.construct(ctx, spec.primal_type, converted);
}

test "SpaceSpec separates pairing from metric identification" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const ctx = rt.context();

    var space = scalar(skript.builtins.type_f64);
    const sum = try space.tangentAdd(ctx, .f64(1.5), .f64(2.0));
    try std.testing.expectEqual(@as(f64, 3.5), sum.obj.tof64());

    space.metric = .none;
    try std.testing.expectError(error.Unsupported, space.identify(ctx, .f64(1.0)));

    space.metric = .{ .diagonal = &.{2.0} };
    const identified = try space.identify(ctx, .f64(6.0));

    try std.testing.expectEqual(@as(f64, 3.0), identified.obj.tof64());
}

test "SpaceSpec keeps i64 algebra exact and rejects overflow" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const ctx = rt.context();
    var space = scalar(skript.builtins.type_i64);

    try std.testing.expectEqual(
        Value.i64(9_007_199_254_740_993),
        try space.tangentAdd(ctx, .i64(9_007_199_254_740_992), .i64(1)),
    );
    try std.testing.expectError(
        error.Unsupported,
        space.tangentAdd(ctx, .i64(std.math.maxInt(i64)), .i64(1)),
    );
    try std.testing.expectError(
        error.Unsupported,
        space.tangentScale(ctx, .i64(std.math.maxInt(i64)), .i64(2)),
    );
    try std.testing.expectEqual(Value.i64(12), try space.pair(ctx, .i64(3), .i64(4)));
    try std.testing.expectError(
        error.Unsupported,
        space.pair(ctx, .i64(std.math.maxInt(i64)), .i64(2)),
    );

    space.metric = .{ .diagonal = &.{1.0} };
    try std.testing.expectEqual(
        Value.i64(9_007_199_254_740_993),
        try space.identify(ctx, .i64(9_007_199_254_740_993)),
    );
    space.metric = .{ .diagonal = &.{2.0} };
    try std.testing.expectError(error.Unsupported, space.identify(ctx, .i64(3)));
}

test "integer metrics reject fractional results without rounding large inputs" {
    const runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    var algebra = scalar(skript.builtins.type_i64);
    const input = Value.i64(9_007_199_254_740_993);
    algebra.metric = .{ .diagonal = &.{2.0} };
    try std.testing.expectError(error.Unsupported, algebra.identify(runtime.context(), input));
    algebra.metric = .{ .diagonal = &.{3.0} };
    try std.testing.expectEqual(Value.i64(3_002_399_751_580_331), try algebra.identify(runtime.context(), input));
    algebra.metric = .{ .diagonal = &.{0.5} };
    try std.testing.expectEqual(Value.i64(18_014_398_509_481_986), try algebra.identify(runtime.context(), input));
    try std.testing.expectError(error.Unsupported, algebra.identify(runtime.context(), .i64(std.math.maxInt(i64))));
}

test "SpaceSpec preserves exact i64 leaves through tree metrics" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const ctx = rt.context();
    const cotangent = try makeListValues(ctx, &.{Value.i64(9_007_199_254_740_993)});
    var spec = try tree.flatten(
        std.testing.allocator,
        ctx,
        rt.tree_registry.current(),
        cotangent,
        tree.Limits.gradient,
    );
    defer spec.deinit();
    var space = treeSpace(&spec);
    space.metric = .{ .diagonal = &.{1.0} };

    const tangent = try space.identify(ctx, cotangent);
    const cell = tangent.obj.toRef().deref([2]Value);
    try std.testing.expectEqual(Value.i64(9_007_199_254_740_993), cell[0]);
}

const test_f64_runtime_type: Object = skript.builtins.type_f64;
const test_f32_runtime_type: Object = skript.builtins.type_f32;

fn testNumericType(context: ?*const anyopaque) Error!Object {
    const raw_context = context orelse return error.Unsupported;
    const runtime_type: *const Object = @ptrCast(@alignCast(raw_context));
    return runtime_type.*;
}

fn testNumericZero(
    ctx: *EvalContext,
    _: Object,
    context: ?*const anyopaque,
) Error!Value {
    return numericZero(ctx, try testNumericType(context), null);
}

fn testNumericCheck(
    ctx: *EvalContext,
    _: Object,
    value: Value,
    context: ?*const anyopaque,
) Error!void {
    return numericCheck(ctx, try testNumericType(context), value, null);
}

fn testNumericAdd(
    ctx: *EvalContext,
    _: Object,
    left: Value,
    right: Value,
    context: ?*const anyopaque,
) Error!Value {
    return numericAdd(ctx, try testNumericType(context), left, right, null);
}

fn testNumericScale(
    ctx: *EvalContext,
    _: Object,
    value: Value,
    factor: Value,
    context: ?*const anyopaque,
) Error!Value {
    return numericScale(ctx, try testNumericType(context), value, factor, null);
}

fn testNumericBasis(
    ctx: *EvalContext,
    _: Object,
    index: usize,
    context: ?*const anyopaque,
) Error!Value {
    return numericBasis(ctx, try testNumericType(context), index, null);
}

fn testNumericOps(runtime_type: *const Object) LinearOps {
    return .{
        .representation_type = runtime_type.*,
        .native = .{
            .context = runtime_type,
            .zero = &testNumericZero,
            .add = &testNumericAdd,
            .scale = &testNumericScale,
            .check = &testNumericCheck,
            .basis = &testNumericBasis,
        },
    };
}
const TestContextProbe = struct {
    pure_limited: bool = false,
    state_read_model: bool = false,
    io_denied: bool = false,
    suspension_denied: bool = false,
    reservation_cleared: bool = false,
};

var test_context_probe: TestContextProbe = .{};

fn testProbeZero(
    ctx: *EvalContext,
    _: Object,
    _: ?*const anyopaque,
) Error!Value {
    test_context_probe.pure_limited = ctx.execution == .pure_limited;
    test_context_probe.state_read_model = switch (ctx.effects.state_read) {
        .model => true,
        else => false,
    };
    test_context_probe.io_denied = ctx.effects.io == .deny;
    test_context_probe.suspension_denied = !ctx.allow_suspend;
    test_context_probe.reservation_cleared = ctx.reservation == null;
    return .f64(0.0);
}

fn testRuntimeType(rt: *skript.Runtime, name: []const u8) Error!Object {
    const type_reference = try rt.store.create(skript.Type);
    const type_name = try rt.store.getsym(name);
    rt.store.store(skript.Type, type_reference.deref(skript.Type), .{
        .meta = skript.builtins.type_type,
        .name = Object.fromPtr(type_name),
    });
    return type_reference.toObject();
}
test "SpaceSpec restricts native callbacks to caller capabilities" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const ctx = rt.context();
    const saved_effects = ctx.effects;
    defer ctx.effects = saved_effects;
    ctx.effects.state_read = .{ .model = .{ .id = 1, .revision = 1 } };
    test_context_probe = .{};

    const space: SpaceSpec = .{
        .primal_type = skript.builtins.type_f64,
        .dimension = 1,
        .tangent = .{
            .representation_type = skript.builtins.type_f64,
            .native = .{ .zero = &testProbeZero },
        },
        .cotangent = testNumericOps(&test_f64_runtime_type),
        .pairing = .{ .native = .{ .pair = &numericPair } },
    };
    try std.testing.expectEqual(Value.f64(0.0), try space.tangentZero(ctx));
    try std.testing.expect(test_context_probe.pure_limited);
    try std.testing.expect(test_context_probe.state_read_model);
    try std.testing.expect(test_context_probe.io_denied);
    try std.testing.expect(test_context_probe.suspension_denied);
    try std.testing.expect(test_context_probe.reservation_cleared);
}

fn testIndexedNumericBasis(
    _: *EvalContext,
    _: Object,
    index: usize,
    context: ?*const anyopaque,
) Error!Value {
    const runtime_type = try testNumericType(context);
    if (index >= 2 or runtime_type != skript.builtins.type_f64) return error.Unsupported;
    return .f64(@floatFromInt(index + 1));
}

fn testIndexedNumericOps(runtime_type: *const Object) LinearOps {
    var result = testNumericOps(runtime_type);
    result.native.basis = &testIndexedNumericBasis;
    return result;
}

fn testSpaceRegistration(primal_type: Object, revision: u64) Registration {
    return .{
        .primal_type = primal_type,
        .implementation_revision = revision,
        .dimension = 1,
        .tangent = testNumericOps(&test_f64_runtime_type),
        .cotangent = testNumericOps(&test_f64_runtime_type),
        .pairing = .{ .native = .{ .pair = &numericPair } },
    };
}
test "Space registry supports multidimensional diagonal identification" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const primal_type = try testRuntimeType(rt, "RegisteredVector");
    var registration = testSpaceRegistration(primal_type, 1);
    registration.dimension = 2;
    registration.tangent = testIndexedNumericOps(&test_f64_runtime_type);
    registration.cotangent = testIndexedNumericOps(&test_f64_runtime_type);
    registration.metric = .{ .diagonal = &.{ 2.0, 3.0 } };
    _ = try register(&rt.space_registry, registration);

    const resolved = rt.space_registry.current().find(primal_type) orelse {
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(@as(usize, 2), resolved.dimension.?);
    try std.testing.expectEqual(Value.f64(2.0), try resolved.tangentBasis(rt.context(), 1));
    try std.testing.expectEqual(Value.f64(11.0), try resolved.identify(rt.context(), .f64(6.0)));
}
test "SpaceSpec composes registered custom nodes with builtin trees" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const ctx = rt.context();
    const primal_type = try testRuntimeType(rt, "NestedVector");
    var registration = testSpaceRegistration(primal_type, 1);
    registration.dimension = 2;
    registration.tangent = testIndexedNumericOps(&test_f64_runtime_type);
    registration.cotangent = testIndexedNumericOps(&test_f64_runtime_type);
    registration.metric = .identity;
    _ = try register(&rt.space_registry, registration);

    const root_id = try tree.NodeId.fromIndex(0);
    const custom_id = try tree.NodeId.fromIndex(1);
    const scalar_id = try tree.NodeId.fromIndex(2);
    const nodes = try std.testing.allocator.alloc(tree.Node, 3);
    const child_nodes = try std.testing.allocator.alloc(tree.NodeId, 2);
    const map_keys = try std.testing.allocator.alloc(Value, 0);
    const dimensions = try std.testing.allocator.alloc(u32, 0);
    const leaves = try std.testing.allocator.alloc(tree.Leaf, 1);
    var spec: tree.TreeSpec = .{
        .allocator = std.testing.allocator,
        .registry = rt.tree_registry.current(),
        .limits = tree.Limits.gradient,
        .root = root_id,
        .nodes = nodes,
        .child_nodes = child_nodes,
        .map_keys = map_keys,
        .dimensions = dimensions,
        .leaves = leaves,
    };
    defer spec.deinit();
    child_nodes[0] = custom_id;
    child_nodes[1] = scalar_id;
    nodes[0] = .{
        .kind = .list,
        .runtime_type = .null,
        .original = .nil,
        .children = try tree.Range.init(0, 2),
    };
    nodes[1] = .{
        .kind = .{ .custom = .{
            .registry_version = 1,
            .implementation_revision = 1,
            .namespace = .nil,
            .metadata = .nil,
            .unflatten_hook = .nil,
        } },
        .runtime_type = primal_type,
        .original = .nil,
    };
    nodes[2] = .{
        .kind = .{ .scalar = .f64 },
        .runtime_type = skript.builtins.type_f64,
        .original = .f64(0.0),
        .leaves = try tree.Range.init(0, 1),
    };
    leaves[0] = .{
        .occurrence = 0,
        .node = scalar_id,
        .element = 0,
        .runtime_type = skript.builtins.type_f64,
        .primal = .f64(0.0),
    };

    const bare_type = try testRuntimeType(rt, "UnregisteredNestedVector");
    nodes[1].runtime_type = bare_type;
    try std.testing.expectError(error.Unsupported, resolve(ctx, &spec));
    nodes[1].runtime_type = primal_type;

    const space = try resolve(ctx, &spec);
    try std.testing.expectEqual(@as(usize, 3), space.dimension.?);
    try std.testing.expect(space.usesRegisteredAlgebra());
    try space.validate();
    const zero = try space.tangentZero(ctx);
    var zero_values = try readListValues(ctx, zero, 2);
    defer zero_values.deinit();
    try std.testing.expectEqual(Value.f64(0.0), zero_values.values[0]);
    try std.testing.expectEqual(Value.f64(0.0), zero_values.values[1]);

    const basis = try space.tangentBasis(ctx, 2);
    var basis_values = try readListValues(ctx, basis, 2);
    defer basis_values.deinit();
    try std.testing.expectEqual(Value.f64(0.0), basis_values.values[0]);
    try std.testing.expectEqual(Value.f64(1.0), basis_values.values[1]);

    const cotangent = try space.cotangentFromCoordinates(
        ctx,
        &.{ .f64(1.0), .f64(2.0), .f64(3.0) },
    );
    var cotangent_values = try readListValues(ctx, cotangent, 2);
    defer cotangent_values.deinit();
    try std.testing.expectEqual(Value.f64(5.0), cotangent_values.values[0]);
    try std.testing.expectEqual(Value.f64(3.0), cotangent_values.values[1]);
}

test "SpaceSpec keeps tangent and cotangent operations distinct" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const ctx = rt.context();
    var space: SpaceSpec = .{
        .primal_type = skript.builtins.type_f64,
        .dimension = 1,
        .tangent = testNumericOps(&test_f64_runtime_type),
        .cotangent = testNumericOps(&test_f32_runtime_type),
        .pairing = .{ .native = .{ .pair = &numericPair } },
        .metric = .none,
    };
    try space.validate();

    const tangent_sum = try space.tangentAdd(ctx, .f64(5.0), .f64(2.0));
    try std.testing.expectEqual(skript.builtins.type_f64, tangent_sum.typ);
    try std.testing.expectEqual(@as(f64, 7.0), tangent_sum.obj.tof64());

    const cotangent_sum = try space.cotangentAdd(ctx, .f32(5.0), .f32(2.0));
    try std.testing.expectEqual(skript.builtins.type_f32, cotangent_sum.typ);
    try std.testing.expectEqual(@as(f32, 7.0), cotangent_sum.obj.tof32());

    const paired = try space.pair(ctx, .f64(2.5), .f32(4.0));
    try std.testing.expectEqual(@as(f64, 10.0), paired.obj.tof64());
}

test "SpaceSpec identifies a diagonal tree metric and rejects no metric" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const ctx = rt.context();
    const cotangent = try rt.evalString("(list 6.0 8.0)");
    var spec = try tree.flatten(
        std.testing.allocator,
        ctx,
        rt.tree_registry.current(),
        cotangent,
        tree.Limits.gradient,
    );
    defer spec.deinit();

    var space = treeSpace(&spec);
    try space.validate();
    try std.testing.expectError(error.Unsupported, space.identify(ctx, cotangent));

    space.metric = .{ .diagonal = &.{ 2.0, 4.0 } };
    try space.validate();
    const tangent = try space.identify(ctx, cotangent);
    const first = tangent.obj.toRef().deref([2]Value).*;
    const second = first[1].obj.toRef().deref([2]Value).*;
    try std.testing.expectEqual(@as(f64, 3.0), first[0].obj.tof64());
    try std.testing.expectEqual(@as(f64, 2.0), second[0].obj.tof64());
    const reconstructed = try space.cotangentFromCoordinates(ctx, &.{ .f64(6.0), .f64(8.0) });
    const reconstructed_first = reconstructed.obj.toRef().deref([2]Value).*;
    const reconstructed_second = reconstructed_first[1].obj.toRef().deref([2]Value).*;
    try std.testing.expectEqual(@as(f64, 6.0), reconstructed_first[0].obj.tof64());
    try std.testing.expectEqual(@as(f64, 8.0), reconstructed_second[0].obj.tof64());
}

test "Space registry preserves snapshots when replacement validation fails" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const primal_type = try testRuntimeType(rt, "RegisteredSpacePoint");
    const registration = testSpaceRegistration(primal_type, 1);
    _ = try register(&rt.space_registry, registration);
    const held = rt.space_registry.current();
    const replacement = try rt.space_registry.publish(&.{.{
        .primal_type = primal_type,
        .implementation_revision = 2,
        .dimension = 1,
        .tangent = registration.tangent,
        .cotangent = registration.cotangent,
        .pairing = registration.pairing,
    }});
    try std.testing.expect(replacement != held);
    try std.testing.expectEqual(
        @as(u64, 1),
        (held.find(primal_type) orelse return error.TestUnexpectedResult).implementation_revision,
    );
    const replacement_space = replacement.find(primal_type) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 2), replacement_space.implementation_revision);

    var malformed = registration;
    malformed.implementation_revision = 3;
    malformed.tangent = .{};
    malformed.cotangent = .{};
    malformed.pairing = .{};
    try std.testing.expectError(
        error.Unsupported,
        rt.space_registry.publish(&.{malformed}),
    );
    try std.testing.expect(rt.space_registry.current() == replacement);
    const current_space = rt.space_registry.current().find(primal_type) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 2), current_space.implementation_revision);
    const held_zero = try (held.find(primal_type) orelse return error.TestUnexpectedResult).tangentZero(rt.context());
    try std.testing.expectEqual(Value.f64(0.0), held_zero);
}

test "Space registry rejects duplicate primal types without publication" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const held_primal_type = try testRuntimeType(rt, "HeldSpacePoint");
    const duplicate_primal_type = try testRuntimeType(rt, "DuplicateSpacePoint");
    const held_registration = testSpaceRegistration(held_primal_type, 1);
    const registration = testSpaceRegistration(duplicate_primal_type, 1);
    const held = try rt.space_registry.publish(&.{held_registration});

    var replacement_a = registration;
    replacement_a.implementation_revision = 2;
    var replacement_b = registration;
    replacement_b.implementation_revision = 3;
    try std.testing.expectError(
        error.Unsupported,
        rt.space_registry.publish(&.{ replacement_a, replacement_b }),
    );

    try std.testing.expect(rt.space_registry.current() == held);
    const zero = try (held.find(held_primal_type) orelse return error.TestUnexpectedResult).tangentZero(rt.context());
    try std.testing.expectEqual(Value.f64(0.0), zero);
}

const TestDualMetric = enum {
    none,
    scaled,
};

fn registerTestDualSpace(
    rt: *skript.Runtime,
    primal_type: Object,
    revision: i64,
    metric: TestDualMetric,
) Error!Value {
    const tangent_zero = try rt.evalString("(fn () 0.0)");
    const tangent_add = try rt.evalString("(fn (left right) (+ left right))");
    const tangent_scale = try rt.evalString("(fn (value factor) (* value factor))");
    const cotangent_zero = try rt.evalString("(fn () (list 0.0))");
    const cotangent_type = try rt.evalString("(type (list 0.0))");
    const cotangent_add = try rt.evalString(
        "(fn (left right) (list (+ (fst left) (fst right))))",
    );
    const cotangent_scale = try rt.evalString(
        "(fn (value factor) (list (* (fst value) factor)))",
    );
    const pairing = try rt.evalString(
        "(fn (tangent cotangent) (* 2.0 (* tangent (fst cotangent))))",
    );
    const options = switch (metric) {
        .none => try rt.evalString(
            \\(hash-map
            \\  :tangent-basis (fn (_index) 1.0)
            \\  :cotangent-basis (fn (_index) (list 0.5)))
        ),
        .scaled => try rt.evalString(
            \\(hash-map
            \\  :tangent-basis (fn (_index) 1.0)
            \\  :cotangent-basis (fn (_index) (list 0.5))
            \\  :metric (fn (cotangent) (* 2.0 (fst cotangent))))
        ),
    };
    return registerSpace(
        rt.context(),
        rt.root_ns,
        .nil,
        &.{
            .typeValue(primal_type),
            .i64(revision),
            .i64(1),
            .typeValue(skript.builtins.type_f64),
            cotangent_type,
            .nil,
            .nil,
            tangent_zero,
            tangent_add,
            tangent_scale,
            .nil,
            cotangent_zero,
            cotangent_add,
            cotangent_scale,
            .nil,
            pairing,
            options,
        },
    );
}

test "public nominal space registration selects root dual algebra and metric" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const ctx = rt.context();
    const primal_type = try testRuntimeType(rt, "PublicDualPoint");

    const version = try registerTestDualSpace(rt, primal_type, 1, .none);
    try std.testing.expectEqual(skript.builtins.type_i64, version.typ);
    const published = rt.space_registry.current().find(primal_type) orelse {
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(published.usesRegisteredAlgebra());

    const nodes = try std.testing.allocator.alloc(tree.Node, 1);
    const child_nodes = try std.testing.allocator.alloc(tree.NodeId, 0);
    const map_keys = try std.testing.allocator.alloc(Value, 0);
    const dimensions = try std.testing.allocator.alloc(u32, 0);
    const leaves = try std.testing.allocator.alloc(tree.Leaf, 0);
    var spec: tree.TreeSpec = .{
        .allocator = std.testing.allocator,
        .registry = rt.tree_registry.current(),
        .limits = tree.Limits.gradient,
        .root = try tree.NodeId.fromIndex(0),
        .nodes = nodes,
        .child_nodes = child_nodes,
        .map_keys = map_keys,
        .dimensions = dimensions,
        .leaves = leaves,
    };
    defer spec.deinit();
    nodes[0] = .{
        .kind = .{ .custom = .{
            .registry_version = spec.registry.version,
            .implementation_revision = 1,
            .namespace = rt.root_ns,
            .metadata = .nil,
            .unflatten_hook = .nil,
        } },
        .runtime_type = primal_type,
        .original = .{ .typ = primal_type, .obj = .null },
    };

    const algebra = try resolve(ctx, &spec);
    try std.testing.expect(algebra.usesRegisteredAlgebra());
    try std.testing.expectEqual(Value.f64(0.0), try algebra.tangentZero(ctx));

    const cotangent = try algebra.cotangentFromCoordinates(ctx, &.{.f64(6.0)});
    var cotangent_values = try readListValues(ctx, cotangent, 1);
    defer cotangent_values.deinit();
    try std.testing.expectEqual(Value.f64(3.0), cotangent_values.values[0]);
    try std.testing.expectEqual(Value.f64(12.0), try algebra.pair(ctx, .f64(2.0), cotangent));
    try std.testing.expectError(error.Unsupported, algebra.identify(ctx, cotangent));

    _ = try registerTestDualSpace(rt, primal_type, 2, .scaled);
    const metric_algebra = try resolve(ctx, &spec);
    try std.testing.expectEqual(
        Value.f64(6.0),
        try metric_algebra.identify(ctx, cotangent),
    );

    var builtin_spec = try tree.flatten(
        std.testing.allocator,
        ctx,
        rt.tree_registry.current(),
        .f64(1.0),
        tree.Limits.gradient,
    );
    defer builtin_spec.deinit();
    const builtin_algebra = try resolve(ctx, &builtin_spec);
    try std.testing.expect(!builtin_algebra.usesRegisteredAlgebra());
}

test "custom tree tensor basis construction honors finite work" {
    const runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const primal_type = try testRuntimeType(runtime, "BoundedTensorBasis");
    var registration = testSpaceRegistration(primal_type, 1);
    registration.tangent = testIndexedNumericOps(&test_f64_runtime_type);
    registration.cotangent = testIndexedNumericOps(&test_f64_runtime_type);
    _ = try register(&runtime.space_registry, registration);
    var nodes = [_]tree.Node{
        .{ .kind = .list, .runtime_type = .null, .original = .nil, .children = try tree.Range.init(0, 2) },
        .{
            .kind = .{ .custom = .{
                .registry_version = 1,
                .implementation_revision = 1,
                .namespace = .nil,
                .metadata = .nil,
                .unflatten_hook = .nil,
            } },
            .runtime_type = primal_type,
            .original = .nil,
        },
        .{
            .kind = .{ .tensor = .{ .inner = .f64, .dimensions = try tree.Range.init(0, 1) } },
            .runtime_type = skript.builtins.type_tensor,
            .original = .nil,
            .leaves = try tree.Range.init(0, 64),
        },
    };
    var children = [_]tree.NodeId{ @enumFromInt(1), @enumFromInt(2) };
    var dimensions = [_]u32{64};
    var leaves: [64]tree.Leaf = undefined;
    for (&leaves, 0..) |*leaf, index| leaf.* = .{
        .occurrence = @intCast(index),
        .node = @enumFromInt(2),
        .element = @intCast(index),
        .runtime_type = skript.builtins.type_f64,
        .primal = .f64(0.0),
    };
    const spec: tree.TreeSpec = .{
        .allocator = std.testing.allocator,
        .registry = runtime.tree_registry.current(),
        .limits = tree.Limits.gradient,
        .root = @enumFromInt(0),
        .nodes = &nodes,
        .child_nodes = &children,
        .map_keys = &.{},
        .dimensions = &dimensions,
        .leaves = &leaves,
    };
    const algebra = try resolve(runtime.context(), &spec);
    var budget = EvalContext.Budget.init(runtime.io, 9104, .{ .work = 16 });
    var lease = try EvalContext.Budget.Lease.root(&budget, 16);
    var account = EvalContext.Budget.AccountAllocator.init(std.testing.allocator, &lease, .transform);
    var output_bytes: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_bytes);
    var context = try EvalContext.limited(
        runtime,
        runtime.intrinsics.registryVersion(),
        &account,
        .{ .writer = &writer, .bounded_memory = true },
        .{ .effects = .{ .state_read = .allow } },
    );
    try std.testing.expectError(error.Exhausted, algebra.tangentBasis(&context, 64));
    try std.testing.expectEqual(EvalContext.Budget.Resource.work, budget.report().?.resource);
}

test "cotangent checks reject non-finite seeds" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const ctx = rt.context();
    var space = scalar(skript.builtins.type_f64);
    try space.cotangentCheck(ctx, .f64(1.0));
    try std.testing.expectError(error.Unsupported, space.cotangentCheck(ctx, .f64(std.math.inf(f64))));
    try std.testing.expectError(error.Unsupported, space.cotangentCheck(ctx, .f64(-std.math.inf(f64))));
    try std.testing.expectError(error.Unsupported, space.cotangentCheck(ctx, .f64(std.math.nan(f64))));
    try std.testing.expectError(
        error.Unsupported,
        space.cotangentFromCoordinates(ctx, &.{.f64(std.math.inf(f64))}),
    );
    try std.testing.expectError(error.Unsupported, space.identify(ctx, .f64(std.math.nan(f64))));
    var integers = scalar(skript.builtins.type_i64);
    try integers.cotangentCheck(ctx, .i64(std.math.maxInt(i64)));
}

test "handle publishing requires validated linear algebra" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var space = scalar(skript.builtins.type_f64);
    try space.validate();
    space.pairing = .{};
    try std.testing.expectError(error.Unsupported, space.validate());
}
