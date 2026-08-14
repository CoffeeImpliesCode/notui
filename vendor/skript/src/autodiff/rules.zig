//! Immutable forward-mode rules keyed by primitive identity.
//!
//! This module owns AD metadata. Primitive names are display data only: rule
//! selection uses PrimitiveId or the trusted native implementation pointer.

const std = @import("std");
const skript = @import("../root.zig");
const Code = @import("../code.zig");
const Primitive = @import("../primitive.zig");
const tree = @import("tree.zig");
const space = @import("space.zig");
const ad_effects = @import("../ad_effects.zig");

const Allocator = std.mem.Allocator;
const Error = skript.Error;
const EvalContext = skript.EvalContext;
const FuncPtr = skript.FuncPtr;
const Object = skript.Object;
const Value = skript.Value;
const b = skript.builtins;
const float_intrin = skript.intrinsics.float;
const int_intrin = skript.intrinsics.int;
const complex_intrin = skript.intrinsics.complex;
const list_intrin = skript.intrinsics.list;
const map_intrin = skript.intrinsics.map;
const tensor_intrin = skript.intrinsics.tensor;
const intrin = skript.intrinsics;

pub const schema_revision: u64 = 1;

pub const Linearity = enum { constant, linear, nonlinear, control };
pub const Allocation = enum { none, private };

pub const Metadata = struct {
    arity: ?u8,
    linearity: Linearity,
    allocation: Allocation = .none,
    higher_order: bool = true,
};

/// Capability declarations are retained separately while a rule is parsed,
/// then checked against the actual rule bodies before publication.
pub const Capabilities = struct {
    jvp: bool = false,
    linearize: bool = false,
    transpose_linear: bool = false,

    fn fromRules(
        jvp: ?JvpRule,
        linearize: ?CodeRule,
        transpose_linear: ?CodeRule,
    ) Capabilities {
        return .{
            .jvp = jvp != null,
            .linearize = linearize != null,
            .transpose_linear = transpose_linear != null,
        };
    }
};

/// Declarative rules understood by the bound-Code transformer. `dispatch`
/// denotes the private scalar operation primitive below; its first operand is
/// a ScalarOp identity and determines the actual rule.
pub const BuiltinJvp = enum {
    dispatch,
    constant,
    construct,
    runtime_owned_output,
    add,
    cotangent_add,
    sub,
    mul,
    div,
    neg,
    abs,
    sqrt,
    sin,
    cos,
    tan,
    asin,
    acos,
    atan,
    sinh,
    cosh,
    tanh,
    asinh,
    acosh,
    atanh,
    exp,
    log,
    log2,
    log10,
    pow,
    predicate,
    cons,
    fst,
    rst,
    list,
    map_create,
    map_get,
    stack,
    tensor_get,
    reshape,
    transpose,
    dot,
    map,
    map2,
    outer,
    fold,
    scan,
    tensor_linear_apply,
    tensor_linear_transpose,
};

/// An inspectable rule body. Code rules may carry a closure materialization
/// for public registration; host callers can leave it nil and the registry
/// will materialize a capture-free Code function on first invocation.
pub const CodeRule = struct {
    code: *const Code.Code,
    function: Code.FunctionId,
    arity: u8,
    callable: Value = .nil,
};

pub const HookRule = struct {
    namespace: Value,
    callable: Value,
    revision: u64,
};

pub const JvpRule = union(enum) {
    builtin: BuiltinJvp,
    code: CodeRule,
    hook: HookRule,
};

/// Every operation emitted by forward mode has an explicit second-order
/// contract. This table is keyed by the compact operation tag.
pub fn scalarJvp(operation: ScalarOp) ?BuiltinJvp {
    return switch (operation) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .neg => .neg,
        .sqrt => .sqrt,
        .sin => .sin,
        .cos => .cos,
        .tan => .tan,
        .asin => .asin,
        .acos => .acos,
        .atan => .atan,
        .sinh => .sinh,
        .cosh => .cosh,
        .tanh => .tanh,
        .asinh => .asinh,
        .acosh => .acosh,
        .atanh => .atanh,
        .exp => .exp,
        .log => .log,
        .log2 => .log2,
        .log10 => .log10,
        .pow => .pow,
        .abs_slope => .constant,
        .zero_like, .one_like => .constant,
        .coerce_tangent, .realize_tangent => .construct,
    };
}

pub fn scalarOperationArity(operation: ScalarOp) u8 {
    return switch (operation) {
        .add, .sub, .mul, .div, .pow, .coerce_tangent, .realize_tangent => 2,
        else => 1,
    };
}

pub fn scalarOperationLinear(operation: ScalarOp) bool {
    return switch (operation) {
        .add, .sub, .neg, .coerce_tangent, .realize_tangent => true,
        else => false,
    };
}

pub const PrimitiveRule = struct {
    primitive: Primitive.PrimitiveId,
    primitive_revision: u64,
    rule_revision: u64 = 1,
    jvp: ?JvpRule = null,
    linearize: ?CodeRule = null,
    transpose_linear: ?CodeRule = null,
    metadata: Metadata,
};

pub const RegistryVersion = struct {
    version: u64,
    schema: u64 = schema_revision,
    primitive_registry: *const Primitive.RegistryVersion,
    primitive_registry_version: u64,
    rules: []const PrimitiveRule,

    pub fn find(self: *const RegistryVersion, id: Primitive.PrimitiveId) ?*const PrimitiveRule {
        for (self.rules) |*candidate| {
            if (candidate.primitive == id) return candidate;
        }
        return null;
    }

    pub fn validFor(self: *const RegistryVersion, primitive_registry: *const Primitive.RegistryVersion) bool {
        return self.schema == schema_revision and
            self.primitive_registry == primitive_registry and
            self.primitive_registry_version == primitive_registry.version;
    }
};

pub const Registration = struct {
    primitive: Primitive.PrimitiveId,
    primitive_revision: u64,
    rule_revision: u64 = 1,
    jvp: ?JvpRule = null,
    linearize: ?CodeRule = null,
    transpose_linear: ?CodeRule = null,
    metadata: Metadata,
    capabilities: ?Capabilities = null,
};

pub const RegistryError = error{
    InvalidPrimitive,
    InvalidRevision,
    MissingCapability,
    DuplicatePrimitive,
    VersionOverflow,
    InvalidDescriptor,
    InvalidMetadata,
    InvalidArity,
    InvalidCapability,
    InvalidCode,
    InvalidHook,
    UnsafeEffects,
};

const SnapshotNode = struct {
    snapshot: *RegistryVersion,
    next: ?*SnapshotNode,
};

/// Cold immutable snapshots. Publication never mutates a snapshot that can be
/// retained by generated Code or a closure guard.
pub const RegistryOwner = struct {
    allocator: Allocator,
    current_version: *RegistryVersion,
    snapshots: ?*SnapshotNode,
    next_version: u64,

    pub fn init(
        allocator: Allocator,
        ctx: *EvalContext,
    ) (Error || RegistryError)!RegistryOwner {
        var owner: RegistryOwner = .{
            .allocator = allocator,
            // SAFETY: buildBuiltins initializes this field before init returns.
            .current_version = undefined,
            .snapshots = null,
            .next_version = 2,
        };
        errdefer owner.deinit();
        owner.current_version = try owner.buildBuiltins(ctx, 1);
        return owner;
    }

    pub fn deinit(self: *RegistryOwner) void {
        var cursor = self.snapshots;
        while (cursor) |node| {
            const next = node.next;
            self.allocator.free(node.snapshot.rules);
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
        ctx: *EvalContext,
        registrations: []const Registration,
    ) (Error || RegistryError)!*const RegistryVersion {
        if (registrations.len == 0) return self.current_version;
        if (self.next_version == std.math.maxInt(u64)) return error.VersionOverflow;
        if (ctx.registry != self.current_version.primitive_registry) return error.InvalidPrimitive;

        for (registrations, 0..) |registration, index| {
            try validateRegistration(ctx, registration);
            for (registrations[0..index]) |prior| {
                if (prior.primitive == registration.primitive) return error.DuplicatePrimitive;
            }
        }

        var added: usize = 0;
        for (registrations) |registration| {
            if (self.current_version.find(registration.primitive) == null) {
                added = std.math.add(usize, added, 1) catch return error.VersionOverflow;
            }
        }
        const total = std.math.add(usize, self.current_version.rules.len, added) catch
            return error.VersionOverflow;
        const candidates = try self.allocator.alloc(PrimitiveRule, total);
        defer self.allocator.free(candidates);
        @memcpy(candidates[0..self.current_version.rules.len], self.current_version.rules);
        var used = self.current_version.rules.len;
        for (registrations) |registration| {
            const candidate = fromRegistration(registration);
            var replaced = false;
            for (candidates[0..used]) |*existing| {
                if (existing.primitive != candidate.primitive) continue;
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
        const snapshot = try self.retainSnapshot(
            ctx.registry,
            candidates,
            self.next_version,
        );
        self.next_version += 1;
        self.current_version = snapshot;
        return snapshot;
    }

    fn buildBuiltins(
        self: *RegistryOwner,
        ctx: *EvalContext,
        version: u64,
    ) (Error || RegistryError)!*RegistryVersion {
        if (ctx.registry.version == 0) return error.InvalidPrimitive;
        var candidates: std.ArrayList(PrimitiveRule) = .empty;
        defer candidates.deinit(self.allocator);
        for (ctx.registry.specs) |spec| {
            try ctx.chargeWork(1, 1, .transform);
            const descriptor_info = descriptorForInvocation(spec.invoke) orelse continue;
            try candidates.append(self.allocator, .{
                .primitive = spec.id,
                .primitive_revision = spec.implementation_revision,
                .jvp = .{ .builtin = descriptor_info.rule },
                .metadata = descriptor_info.metadata,
            });
        }
        return self.retainSnapshot(ctx.registry, candidates.items, version);
    }

    fn retainSnapshot(
        self: *RegistryOwner,
        primitive_registry: *const Primitive.RegistryVersion,
        source: []const PrimitiveRule,
        version: u64,
    ) Error!*RegistryVersion {
        const owned = try self.allocator.dupe(PrimitiveRule, source);
        errdefer self.allocator.free(owned);
        const snapshot = try self.allocator.create(RegistryVersion);
        errdefer self.allocator.destroy(snapshot);
        snapshot.* = .{
            .version = version,
            .primitive_registry = primitive_registry,
            .primitive_registry_version = primitive_registry.version,
            .rules = owned,
        };
        const node = try self.allocator.create(SnapshotNode);
        node.* = .{ .snapshot = snapshot, .next = self.snapshots };
        self.snapshots = node;
        return snapshot;
    }
    /// Start a fresh builtin baseline when the immutable primitive registry
    /// advances. Existing snapshots stay retained for closure guards.
    pub fn syncPrimitiveRegistry(self: *RegistryOwner, ctx: *EvalContext) (Error || RegistryError)!void {
        if (self.current_version.primitive_registry == ctx.registry) return;
        if (self.next_version == std.math.maxInt(u64)) return error.VersionOverflow;
        const snapshot = try self.buildBuiltins(ctx, self.next_version);
        self.next_version += 1;
        self.current_version = snapshot;
    }

    pub fn ownsCurrent(self: *const RegistryOwner, snapshot: *const RegistryVersion) bool {
        return self.current_version == snapshot;
    }
};

/// Return the Runtime-owned rule snapshot. The owner is initialized exactly
/// once, so every caller observes the same immutable current snapshot.
pub fn registry(ctx: *EvalContext) Error!*RegistryOwner {
    if (ctx.runtime.ad_rules == null) {
        ctx.runtime.ad_rules = RegistryOwner.init(ctx.runtime.static, ctx) catch |err| switch (err) {
            error.InvalidPrimitive,
            error.InvalidRevision,
            error.MissingCapability,
            error.DuplicatePrimitive,
            error.InvalidDescriptor,
            error.InvalidMetadata,
            error.InvalidArity,
            error.InvalidCapability,
            error.InvalidCode,
            error.InvalidHook,
            error.UnsafeEffects,
            error.VersionOverflow,
            => return error.Unsupported,
            else => |cause| return cause,
        };
    }
    const owner = if (ctx.runtime.ad_rules) |*value| value else unreachable;
    owner.syncPrimitiveRegistry(ctx) catch |err| switch (err) {
        error.InvalidPrimitive,
        error.InvalidRevision,
        error.MissingCapability,
        error.DuplicatePrimitive,
        error.InvalidDescriptor,
        error.InvalidMetadata,
        error.InvalidArity,
        error.InvalidCapability,
        error.InvalidCode,
        error.InvalidHook,
        error.UnsafeEffects,
        error.VersionOverflow,
        => return error.Unsupported,
        else => |cause| return cause,
    };
    return owner;
}

pub fn builtinSnapshot(ctx: *EvalContext) Error!*const RegistryVersion {
    return (try registry(ctx)).current();
}

fn fromRegistration(registration: Registration) PrimitiveRule {
    return .{
        .primitive = registration.primitive,
        .primitive_revision = registration.primitive_revision,
        .rule_revision = registration.rule_revision,
        .jvp = registration.jvp,
        .linearize = registration.linearize,
        .transpose_linear = registration.transpose_linear,
        .metadata = registration.metadata,
    };
}

fn validateRegistration(
    ctx: *EvalContext,
    registration: Registration,
) (Error || RegistryError)!void {
    if (!registration.primitive.isValid()) return error.InvalidPrimitive;
    const primitive = ctx.registry.spec(registration.primitive) orelse
        return error.InvalidPrimitive;
    if (registration.primitive_revision == 0 or
        primitive.implementation_revision != registration.primitive_revision or
        registration.rule_revision == 0)
    {
        return error.InvalidRevision;
    }

    const capabilities = registration.capabilities orelse
        Capabilities.fromRules(registration.jvp, registration.linearize, registration.transpose_linear);
    if (capabilities.jvp != (registration.jvp != null) or
        capabilities.linearize != (registration.linearize != null) or
        capabilities.transpose_linear != (registration.transpose_linear != null))
    {
        return error.InvalidCapability;
    }
    if (!capabilities.jvp and !capabilities.linearize and !capabilities.transpose_linear) {
        return error.MissingCapability;
    }

    try validatePrimitiveEffects(primitive);
    try validateMetadata(ctx, primitive, registration.metadata);
    if (registration.jvp) |rule| try validateJvpRule(ctx, primitive, rule, registration.metadata);
    if (registration.linearize) |rule| try validateLinearizeRule(ctx, rule, registration.metadata);
    if (registration.transpose_linear) |rule| try validateCodeRule(ctx, rule);
}

fn validateLinearizeRule(
    ctx: *EvalContext,
    body: CodeRule,
    metadata: Metadata,
) (Error || RegistryError)!void {
    try validateCodeRule(ctx, body);
    const function = body.code.function(body.function) orelse return error.InvalidCode;
    if (function.result_count != 1) return error.InvalidCode;
    const arity = metadata.arity orelse return error.InvalidArity;
    if (body.arity != arity) return error.InvalidArity;
    const callable = if (!Value.isNil(body.callable))
        body.callable
    else
        try materializeCodeCallable(ctx, body);
    const closure = callable.obj.toRef().deref(skript.data.Closure);
    const scope = ctx.activate();
    defer scope.deinit();
    ad_effects.preflight(ctx.runtime, closure.parent_ns, callable) catch |err| switch (err) {
        error.OutOfMemory, error.Exhausted => return err,
        else => return error.UnsafeEffects,
    };
}

fn validatePrimitiveEffects(spec: *const Primitive.Spec) RegistryError!void {
    const effects = spec.effects;
    if (effects.state_write or effects.io or effects.clock or effects.random or
        effects.process or effects.module or effects.ffi or effects.dynamic_loader or
        effects.host or effects.unknown)
    {
        return error.UnsafeEffects;
    }
    if (effects.state_read and !spec.reads_argument_state) return error.UnsafeEffects;
    switch (spec.callbacks) {
        .none => {},
        else => return error.UnsafeEffects,
    }
    switch (spec.resources) {
        .fixed, .bounded, .native => {},
        .unknown, .denied => return error.UnsafeEffects,
    }
    switch (spec.suspension) {
        .never => {},
        else => return error.UnsafeEffects,
    }
}

fn validateMetadata(
    ctx: *EvalContext,
    spec: *const Primitive.Spec,
    metadata: Metadata,
) (Error || RegistryError)!void {
    if (descriptorForInvocation(spec.invoke)) |expected| {
        if (metadata.arity != expected.metadata.arity) {
            return error.InvalidArity;
        }
    } else switch (spec.invoke) {
        .native => {},
        .closure => |callable| {
            if (callable.typ != b.type_closure or callable.obj == .null) return error.InvalidHook;
            const closure = callable.obj.toRef().deref(skript.data.Closure);
            const code = closure.code orelse return error.InvalidHook;
            const function = code.function(closure.function_id) orelse return error.InvalidHook;
            if (function.has_rest) return error.InvalidArity;
            if (closure.arglist.len != @as(usize, function.parameter_count)) return error.InvalidHook;
            const expected_arity = std.math.cast(u8, function.parameter_count) orelse
                return error.InvalidArity;
            if (metadata.arity) |arity| {
                if (arity != expected_arity) return error.InvalidArity;
            } else {
                return error.InvalidArity;
            }
        },
    }
    if (metadata.arity != null) {
        try ctx.chargeWork(1, 1, .transform);
    }
}

fn validateJvpRule(
    ctx: *EvalContext,
    spec: *const Primitive.Spec,
    rule: JvpRule,
    metadata: Metadata,
) (Error || RegistryError)!void {
    switch (rule) {
        .builtin => |builtin| {
            if (descriptorForInvocation(spec.invoke)) |expected| {
                if (expected.rule != builtin) return error.InvalidDescriptor;
            } else {
                return error.InvalidDescriptor;
            }
        },
        .code => |body| {
            try validateCodeRule(ctx, body);
            const function = body.code.function(body.function) orelse return error.InvalidCode;
            if (function.result_count != 2) return error.InvalidCode;
            if (metadata.arity) |arity| {
                const expected = std.math.mul(u16, arity, 2) catch return error.InvalidArity;
                if (expected > std.math.maxInt(u8) or @as(u16, body.arity) != expected) {
                    return error.InvalidArity;
                }
            }
        },
        .hook => |hook| {
            if (hook.revision == 0 or !isCallable(hook.callable)) return error.InvalidHook;
            try validateHook(ctx, hook);
        },
    }
}

fn validateCodeRule(ctx: *EvalContext, body: CodeRule) (Error || RegistryError)!void {
    if (body.arity == 0 or body.function == .invalid or body.code.id == 0 or
        body.code.revision == 0 or body.code.owner != @as(?*const anyopaque, ctx.runtime))
    {
        return error.InvalidCode;
    }
    const function = body.code.function(body.function) orelse return error.InvalidCode;
    if (function.has_rest) return error.InvalidArity;
    if (function.parameter_count != body.arity or function.result_count == 0) {
        return error.InvalidArity;
    }
    if (Value.isNil(body.callable) and function.capture_count != 0) return error.InvalidCode;
    if (!Value.isNil(body.callable)) {
        if (body.callable.typ != b.type_closure or body.callable.obj == .null) {
            return error.InvalidHook;
        }
        const closure = body.callable.obj.toRef().deref(skript.data.Closure);
        if (closure.code != body.code or closure.function_id != body.function or
            closure.arglist.len != body.arity or closure.result_count != function.result_count)
        {
            return error.InvalidCode;
        }
    }
    body.code.validate(ctx.scratch, ctx) catch |err| switch (err) {
        error.OutOfMemory, error.Exhausted => return err,
        else => return error.InvalidCode,
    };
}

fn validateHook(ctx: *EvalContext, hook: HookRule) (Error || RegistryError)!void {
    if (!isCallable(hook.callable)) return error.InvalidHook;
    switch (hook.callable.typ) {
        b.type_closure => {
            const closure = hook.callable.obj.toRef().deref(skript.data.Closure);
            const code = closure.code orelse return error.InvalidHook;
            const function = code.function(closure.function_id) orelse return error.InvalidHook;
            if (function.has_rest) return error.InvalidArity;
            if (closure.arglist.len != 2 or function.parameter_count != 2 or
                closure.result_count != 1)
            {
                return error.InvalidArity;
            }
        },
        b.type_intrinsic => {
            const native = hook.callable.obj.toPtr(FuncPtr);
            const id = ctx.registry.idForNative(native) orelse return error.InvalidHook;
            const spec = ctx.registry.spec(id) orelse return error.InvalidHook;
            // Hook invocation always supplies the primal and tangent lists.
            if (descriptorForNative(native)) |native_descriptor| {
                if (native_descriptor.metadata.arity) |arity| {
                    if (arity != 2) return error.InvalidArity;
                }
            }
            try validatePrimitiveEffects(spec);
        },
        else => return error.InvalidHook,
    }
    const scope = ctx.activate();
    defer scope.deinit();
    ad_effects.preflight(ctx.runtime, hook.namespace, hook.callable) catch |err| switch (err) {
        error.OutOfMemory, error.Exhausted => return err,
        else => return error.UnsafeEffects,
    };
}

fn isCallable(value: Value) bool {
    return switch (value.typ) {
        b.type_closure, b.type_intrinsic, b.type_method => value.obj != .null,
        else => false,
    };
}

pub const Descriptor = struct {
    rule: BuiltinJvp,
    metadata: Metadata,
};

fn descriptor(rule: BuiltinJvp, arity: ?u8, linearity: Linearity) Descriptor {
    return .{ .rule = rule, .metadata = .{ .arity = arity, .linearity = linearity } };
}

pub fn descriptorForInvocation(invocation: Primitive.Invocation) ?Descriptor {
    return switch (invocation) {
        .native => |native| descriptorForNative(native),
        .closure => null,
    };
}

/// Classify trusted implementations by pointer identity. Stable names never
/// participate in rule lookup, so aliases cannot acquire or evade a rule.
pub fn descriptorForNative(native: FuncPtr) ?Descriptor {
    if (native == &scalarDispatch) return descriptor(.dispatch, null, .nonlinear);
    if (native == &checkHookResult) return descriptor(.construct, 1, .linear);
    if (native == &skript.autodiff_linearize.materializeOutput) {
        return descriptor(.runtime_owned_output, 1, .linear);
    }
    if (native == &skript.autodiff_linearize.tensorLinearApply) {
        return descriptor(.tensor_linear_apply, null, .linear);
    }
    if (native == &skript.autodiff_linearize.tensorLinearTranspose) {
        return descriptor(.tensor_linear_transpose, 2, .linear);
    }
    if (native == &skript.autodiff_linearize.cotangentZero) return descriptor(.constant, 1, .constant);
    if (native == &skript.autodiff_linearize.cotangentAdd) return descriptor(.cotangent_add, 3, .linear);

    inline for (.{ "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64" }) |prefix| {
        if (native == &@field(int_intrin, prefix ++ "_construct")) return descriptor(.construct, 1, .linear);
        if (native == &@field(int_intrin, prefix ++ "_add")) return descriptor(.add, 2, .linear);
        if (native == &@field(int_intrin, prefix ++ "_sub")) return descriptor(.sub, 2, .linear);
        if (native == &@field(int_intrin, prefix ++ "_mul")) return descriptor(.mul, 2, .nonlinear);
        if (native == &@field(int_intrin, prefix ++ "_div")) return descriptor(.div, 2, .nonlinear);
        if (native == &@field(int_intrin, prefix ++ "_neg")) return descriptor(.neg, 1, .linear);
        if (native == &@field(int_intrin, prefix ++ "_abs")) return descriptor(.abs, 1, .nonlinear);
        if (native == &@field(int_intrin, prefix ++ "_pow")) return descriptor(.pow, 2, .nonlinear);
        if (native == &@field(int_intrin, prefix ++ "_eq") or
            native == &@field(int_intrin, prefix ++ "_ne") or
            native == &@field(int_intrin, prefix ++ "_gt") or
            native == &@field(int_intrin, prefix ++ "_lt") or
            native == &@field(int_intrin, prefix ++ "_gte") or
            native == &@field(int_intrin, prefix ++ "_lte"))
        {
            return descriptor(.predicate, 2, .control);
        }
    }

    inline for (.{ "f16", "f32", "f64" }) |prefix| {
        if (native == &@field(float_intrin, prefix ++ "_construct")) return descriptor(.construct, 1, .linear);
        if (native == &@field(float_intrin, prefix ++ "_add")) return descriptor(.add, 2, .linear);
        if (native == &@field(float_intrin, prefix ++ "_sub")) return descriptor(.sub, 2, .linear);
        if (native == &@field(float_intrin, prefix ++ "_mul")) return descriptor(.mul, 2, .nonlinear);
        if (native == &@field(float_intrin, prefix ++ "_div")) return descriptor(.div, 2, .nonlinear);
        if (native == &@field(float_intrin, prefix ++ "_neg")) return descriptor(.neg, 1, .linear);
        if (native == &@field(float_intrin, prefix ++ "_abs")) return descriptor(.abs, 1, .nonlinear);
        if (native == &@field(float_intrin, prefix ++ "_sqrt")) return descriptor(.sqrt, 1, .nonlinear);
        if (native == &@field(float_intrin, prefix ++ "_sin")) return descriptor(.sin, 1, .nonlinear);
        if (native == &@field(float_intrin, prefix ++ "_cos")) return descriptor(.cos, 1, .nonlinear);
        if (native == &@field(float_intrin, prefix ++ "_tan")) return descriptor(.tan, 1, .nonlinear);
        if (native == &@field(float_intrin, prefix ++ "_asin")) return descriptor(.asin, 1, .nonlinear);
        if (native == &@field(float_intrin, prefix ++ "_acos")) return descriptor(.acos, 1, .nonlinear);
        if (native == &@field(float_intrin, prefix ++ "_atan")) return descriptor(.atan, 1, .nonlinear);
        if (native == &@field(float_intrin, prefix ++ "_sinh")) return descriptor(.sinh, 1, .nonlinear);
        if (native == &@field(float_intrin, prefix ++ "_cosh")) return descriptor(.cosh, 1, .nonlinear);
        if (native == &@field(float_intrin, prefix ++ "_tanh")) return descriptor(.tanh, 1, .nonlinear);
        if (native == &@field(float_intrin, prefix ++ "_asinh")) return descriptor(.asinh, 1, .nonlinear);
        if (native == &@field(float_intrin, prefix ++ "_acosh")) return descriptor(.acosh, 1, .nonlinear);
        if (native == &@field(float_intrin, prefix ++ "_atanh")) return descriptor(.atanh, 1, .nonlinear);
        if (native == &@field(float_intrin, prefix ++ "_exp")) return descriptor(.exp, 1, .nonlinear);
        if (native == &@field(float_intrin, prefix ++ "_log")) return descriptor(.log, 1, .nonlinear);
        if (native == &@field(float_intrin, prefix ++ "_log2")) return descriptor(.log2, 1, .nonlinear);
        if (native == &@field(float_intrin, prefix ++ "_log10")) return descriptor(.log10, 1, .nonlinear);
        if (native == &@field(float_intrin, prefix ++ "_pow")) return descriptor(.pow, 2, .nonlinear);
        if (native == &@field(float_intrin, prefix ++ "_eq") or
            native == &@field(float_intrin, prefix ++ "_ne") or
            native == &@field(float_intrin, prefix ++ "_gt") or
            native == &@field(float_intrin, prefix ++ "_lt") or
            native == &@field(float_intrin, prefix ++ "_gte") or
            native == &@field(float_intrin, prefix ++ "_lte"))
        {
            return descriptor(.predicate, 2, .control);
        }
    }

    inline for (.{ "c16", "c32", "c64" }) |prefix| {
        if (native == &@field(complex_intrin, prefix ++ "_add")) return descriptor(.add, 2, .linear);
        if (native == &@field(complex_intrin, prefix ++ "_sub")) return descriptor(.sub, 2, .linear);
        if (native == &@field(complex_intrin, prefix ++ "_mul")) return descriptor(.mul, 2, .nonlinear);
        if (native == &@field(complex_intrin, prefix ++ "_div")) return descriptor(.div, 2, .nonlinear);
        if (native == &@field(complex_intrin, prefix ++ "_neg")) return descriptor(.neg, 1, .linear);
        if (native == &@field(complex_intrin, prefix ++ "_sqrt")) return descriptor(.sqrt, 1, .nonlinear);
        if (native == &@field(complex_intrin, prefix ++ "_sin")) return descriptor(.sin, 1, .nonlinear);
        if (native == &@field(complex_intrin, prefix ++ "_cos")) return descriptor(.cos, 1, .nonlinear);
        if (native == &@field(complex_intrin, prefix ++ "_tan")) return descriptor(.tan, 1, .nonlinear);
        if (native == &@field(complex_intrin, prefix ++ "_asin")) return descriptor(.asin, 1, .nonlinear);
        if (native == &@field(complex_intrin, prefix ++ "_acos")) return descriptor(.acos, 1, .nonlinear);
        if (native == &@field(complex_intrin, prefix ++ "_atan")) return descriptor(.atan, 1, .nonlinear);
        if (native == &@field(complex_intrin, prefix ++ "_sinh")) return descriptor(.sinh, 1, .nonlinear);
        if (native == &@field(complex_intrin, prefix ++ "_cosh")) return descriptor(.cosh, 1, .nonlinear);
        if (native == &@field(complex_intrin, prefix ++ "_tanh")) return descriptor(.tanh, 1, .nonlinear);
        if (native == &@field(complex_intrin, prefix ++ "_asinh")) return descriptor(.asinh, 1, .nonlinear);
        if (native == &@field(complex_intrin, prefix ++ "_acosh")) return descriptor(.acosh, 1, .nonlinear);
        if (native == &@field(complex_intrin, prefix ++ "_atanh")) return descriptor(.atanh, 1, .nonlinear);
        if (native == &@field(complex_intrin, prefix ++ "_exp")) return descriptor(.exp, 1, .nonlinear);
        if (native == &@field(complex_intrin, prefix ++ "_log")) return descriptor(.log, 1, .nonlinear);
        if (comptime std.mem.eql(u8, prefix, "c16")) {
            if (native == &complex_intrin.c16Pow) return descriptor(.pow, 2, .nonlinear);
        } else {
            if (native == &@field(complex_intrin, prefix ++ "_pow")) return descriptor(.pow, 2, .nonlinear);
        }
    }
    if (native == &complex_intrin.c16Abs or native == &complex_intrin.c32Abs or
        native == &complex_intrin.c64Abs)
    {
        return descriptor(.abs, 1, .nonlinear);
    }

    if (native == &list_intrin.cons) return .{
        .rule = .cons,
        .metadata = .{ .arity = 2, .linearity = .linear, .allocation = .private },
    };
    if (native == &list_intrin.fst) return descriptor(.fst, 1, .linear);
    if (native == &list_intrin.rst) return descriptor(.rst, 1, .linear);
    if (native == &list_intrin.list) return .{
        .rule = .list,
        .metadata = .{ .arity = null, .linearity = .linear, .allocation = .private },
    };
    if (native == &map_intrin.create) return .{
        .rule = .map_create,
        .metadata = .{ .arity = null, .linearity = .linear, .allocation = .private },
    };
    if (native == &map_intrin.get) return descriptor(.map_get, 2, .linear);
    if (native == &tensor_intrin.create) return .{
        .rule = .stack,
        .metadata = .{ .arity = null, .linearity = .linear, .allocation = .private },
    };
    if (native == &tensor_intrin.tensorGet) return descriptor(.tensor_get, null, .linear);
    if (native == &tensor_intrin.reshape) return .{
        .rule = .reshape,
        .metadata = .{ .arity = 2, .linearity = .linear, .allocation = .private },
    };
    if (native == &tensor_intrin.trans) return .{
        .rule = .transpose,
        .metadata = .{ .arity = 1, .linearity = .linear, .allocation = .private },
    };
    if (native == &tensor_intrin.dot) return descriptor(.dot, 2, .nonlinear);
    if (native == &intrin.collections.map or native == &tensor_intrin.map) return descriptor(.map, null, .nonlinear);
    if (native == &tensor_intrin.map2) return descriptor(.map2, 3, .nonlinear);
    if (native == &tensor_intrin.outer) return descriptor(.outer, 3, .nonlinear);
    if (native == &intrin.collections.fold or native == &tensor_intrin.fold) return descriptor(.fold, null, .nonlinear);
    if (native == &intrin.collections.scan or native == &tensor_intrin.scan) return descriptor(.scan, null, .nonlinear);
    return null;
}
const outer_descriptor_fields = [_][]const u8{
    "primitive",
    "implementation-revision",
    "rule-revision",
    "capabilities",
    "metadata",
    "jvp",
    "linearize",
    "transpose-linear",
};
const metadata_fields = [_][]const u8{
    "arity",
    "linearity",
    "allocation",
    "higher-order",
};
const builtin_rule_fields = [_][]const u8{
    "kind",
    "rule",
};
const code_rule_fields = [_][]const u8{
    "kind",
    "callable",
    "arity",
    "revision",
};
const hook_rule_fields = [_][]const u8{
    "kind",
    "callable",
    "revision",
};
fn keywordText(value: Value) ?[]const u8 {
    if (value.typ != b.type_keyword or value.obj == .null) return null;
    return value.obj.toPtr(skript.Sym).*;
}

fn mapFieldPresent(ctx: *EvalContext, map: Value, name: []const u8) Error!bool {
    const key = Value.keyword(try ctx.runtime.store.getsym(name));
    const result = try map_intrin.has(ctx, .nil, .nil, &.{ map, key });
    return result.typ == b.type_bool and result.obj.toBool();
}

fn mapField(ctx: *EvalContext, map: Value, name: []const u8) Error!Value {
    const key = Value.keyword(try ctx.runtime.store.getsym(name));
    return map_intrin.get(ctx, .nil, .nil, &.{ map, key });
}

fn requireMapField(ctx: *EvalContext, map: Value, name: []const u8) (Error || RegistryError)!Value {
    if (!try mapFieldPresent(ctx, map, name)) return error.InvalidDescriptor;
    return mapField(ctx, map, name);
}

fn validateMapKeys(
    ctx: *EvalContext,
    map: Value,
    allowed: []const []const u8,
) (Error || RegistryError)!void {
    if (map.typ != b.type_map or map.obj == .null) return error.InvalidDescriptor;
    const keys = try map_intrin.keys(ctx, .nil, .nil, &.{map});
    var cursor = keys;
    var count: usize = 0;
    while (cursor.typ == b.type_cons) {
        if (count >= 64) return error.InvalidDescriptor;
        try ctx.chargeWork(1, 1, .transform);
        const cell = cursor.obj.toRef().deref([2]Value);
        const text = keywordText(cell[0]) orelse return error.InvalidDescriptor;
        var known = false;
        for (allowed) |field| {
            if (std.mem.eql(u8, text, field)) {
                known = true;
                break;
            }
        }
        if (!known) return error.InvalidDescriptor;
        cursor = cell[1];
        count += 1;
    }
    if (!Value.isNil(cursor)) return error.InvalidDescriptor;
}

fn parseRevision(value: Value) (Error || RegistryError)!u64 {
    return switch (value.typ) {
        b.type_i64 => blk: {
            const revision = value.obj.toInt(i64);
            if (revision <= 0) break :blk error.InvalidRevision;
            break :blk @intCast(revision);
        },
        b.type_u64 => blk: {
            const revision = value.obj.toInt(u64);
            if (revision == 0) break :blk error.InvalidRevision;
            break :blk revision;
        },
        else => error.InvalidRevision,
    };
}

fn parseArity(value: Value) (Error || RegistryError)!u8 {
    return switch (value.typ) {
        b.type_i64 => blk: {
            const arity = value.obj.toInt(i64);
            if (arity < 0 or arity > std.math.maxInt(u8)) break :blk error.InvalidArity;
            break :blk @intCast(arity);
        },
        b.type_u64 => blk: {
            const arity = value.obj.toInt(u64);
            if (arity > std.math.maxInt(u8)) break :blk error.InvalidArity;
            break :blk @intCast(arity);
        },
        else => error.InvalidArity,
    };
}

fn parseLinearity(value: Value) RegistryError!Linearity {
    const text = keywordText(value) orelse return error.InvalidMetadata;
    return std.meta.stringToEnum(Linearity, text) orelse error.InvalidMetadata;
}

fn parseAllocation(value: Value) RegistryError!Allocation {
    const text = keywordText(value) orelse return error.InvalidMetadata;
    return std.meta.stringToEnum(Allocation, text) orelse error.InvalidMetadata;
}

fn parseMetadata(ctx: *EvalContext, value: Value) (Error || RegistryError)!Metadata {
    if (value.typ != b.type_map or value.obj == .null) return error.InvalidMetadata;
    try validateMapKeys(ctx, value, &metadata_fields);
    const arity_value = try requireMapField(ctx, value, "arity");
    const arity = if (Value.isNil(arity_value)) null else try parseArity(arity_value);
    const linearity = try parseLinearity(try requireMapField(ctx, value, "linearity"));
    const allocation = try parseAllocation(try requireMapField(ctx, value, "allocation"));
    const higher_order = try requireMapField(ctx, value, "higher-order");
    if (higher_order.typ != b.type_bool) return error.InvalidMetadata;
    return .{
        .arity = arity,
        .linearity = linearity,
        .allocation = allocation,
        .higher_order = higher_order.obj.toBool(),
    };
}

fn parseCapabilities(ctx: *EvalContext, value: Value) (Error || RegistryError)!Capabilities {
    var capabilities: Capabilities = .{};
    var cursor = value;
    var count: usize = 0;
    while (cursor.typ == b.type_cons) {
        if (count >= 3) return error.InvalidCapability;
        try ctx.chargeWork(1, 1, .transform);
        const cell = cursor.obj.toRef().deref([2]Value);
        const text = keywordText(cell[0]) orelse return error.InvalidCapability;
        if (std.mem.eql(u8, text, "jvp")) {
            if (capabilities.jvp) return error.InvalidCapability;
            capabilities.jvp = true;
        } else if (std.mem.eql(u8, text, "linearize")) {
            if (capabilities.linearize) return error.InvalidCapability;
            capabilities.linearize = true;
        } else if (std.mem.eql(u8, text, "transpose-linear")) {
            if (capabilities.transpose_linear) return error.InvalidCapability;
            capabilities.transpose_linear = true;
        } else {
            return error.InvalidCapability;
        }
        cursor = cell[1];
        count += 1;
    }
    if (!Value.isNil(cursor) or count == 0) return error.InvalidCapability;
    return capabilities;
}
fn primitiveIdForValue(ctx: *EvalContext, value: Value) (Error || RegistryError)!Primitive.PrimitiveId {
    if (value.typ == b.type_intrinsic and value.obj != .null) {
        return ctx.registry.idForNative(value.obj.toPtr(FuncPtr)) orelse error.InvalidPrimitive;
    }
    if (value.typ == b.type_closure and value.obj != .null) {
        var found: ?Primitive.PrimitiveId = null;
        for (ctx.registry.specs) |spec| {
            try ctx.chargeWork(1, 1, .transform);
            const callable = switch (spec.invoke) {
                .native => continue,
                .closure => |closure| closure,
            };
            if (callable.typ != value.typ or callable.obj != value.obj) continue;
            if (found) |prior| {
                if (prior != spec.id) return error.InvalidPrimitive;
            } else {
                found = spec.id;
            }
        }
        return found orelse error.InvalidPrimitive;
    }
    return switch (value.typ) {
        b.type_i64 => blk: {
            const raw = value.obj.toInt(i64);
            if (raw < 0 or raw >= std.math.maxInt(u32)) break :blk error.InvalidPrimitive;
            const id = Primitive.PrimitiveId.fromIndex(@intCast(raw));
            if (ctx.registry.spec(id) == null) break :blk error.InvalidPrimitive;
            break :blk id;
        },
        b.type_u64 => blk: {
            const raw = value.obj.toInt(u64);
            if (raw >= std.math.maxInt(u32)) break :blk error.InvalidPrimitive;
            const id = Primitive.PrimitiveId.fromIndex(@intCast(raw));
            if (ctx.registry.spec(id) == null) break :blk error.InvalidPrimitive;
            break :blk id;
        },
        else => error.InvalidPrimitive,
    };
}

fn parseBuiltinRule(ctx: *EvalContext, value: Value) (Error || RegistryError)!JvpRule {
    if (value.typ != b.type_map or value.obj == .null) return error.InvalidDescriptor;
    try validateMapKeys(ctx, value, &builtin_rule_fields);
    const kind = keywordText(try requireMapField(ctx, value, "kind")) orelse
        return error.InvalidDescriptor;
    if (!std.mem.eql(u8, kind, "builtin")) return error.InvalidDescriptor;
    const rule_value = try requireMapField(ctx, value, "rule");
    const text = keywordText(rule_value) orelse return error.InvalidDescriptor;
    const builtin = std.meta.stringToEnum(BuiltinJvp, text) orelse return error.InvalidDescriptor;
    return .{ .builtin = builtin };
}

fn parseCodeRule(ctx: *EvalContext, value: Value) (Error || RegistryError)!CodeRule {
    if (value.typ != b.type_map or value.obj == .null) return error.InvalidDescriptor;
    try validateMapKeys(ctx, value, &code_rule_fields);
    const kind = keywordText(try requireMapField(ctx, value, "kind")) orelse
        return error.InvalidDescriptor;
    if (!std.mem.eql(u8, kind, "code")) return error.InvalidDescriptor;
    const callable_value = try requireMapField(ctx, value, "callable");
    if (callable_value.typ != b.type_closure or callable_value.obj == .null) {
        return error.InvalidCode;
    }
    const closure = callable_value.obj.toRef().deref(skript.data.Closure);
    const code = closure.code orelse return error.InvalidCode;
    const arity = try parseArity(try requireMapField(ctx, value, "arity"));
    const revision = try parseRevision(try requireMapField(ctx, value, "revision"));
    if (revision == 0) return error.InvalidRevision;
    return .{
        .code = code,
        .function = closure.function_id,
        .arity = arity,
        .callable = callable_value,
    };
}

fn parseHookRule(
    ctx: *EvalContext,
    namespace: Value,
    value: Value,
) (Error || RegistryError)!JvpRule {
    if (value.typ != b.type_map or value.obj == .null) return error.InvalidDescriptor;
    try validateMapKeys(ctx, value, &hook_rule_fields);
    const kind = keywordText(try requireMapField(ctx, value, "kind")) orelse
        return error.InvalidDescriptor;
    if (!std.mem.eql(u8, kind, "hook")) return error.InvalidDescriptor;
    const callable = try requireMapField(ctx, value, "callable");
    const revision = try parseRevision(try requireMapField(ctx, value, "revision"));
    if (!isCallable(callable)) return error.InvalidHook;
    return .{ .hook = .{ .namespace = namespace, .callable = callable, .revision = revision } };
}

fn parseJvpRule(
    ctx: *EvalContext,
    namespace: Value,
    value: Value,
) (Error || RegistryError)!?JvpRule {
    if (Value.isNil(value)) return null;
    if (value.typ != b.type_map or value.obj == .null) return error.InvalidDescriptor;
    const kind_value = try requireMapField(ctx, value, "kind");
    const kind = keywordText(kind_value) orelse return error.InvalidDescriptor;
    if (std.mem.eql(u8, kind, "builtin")) {
        const rule = try parseBuiltinRule(ctx, value);
        return rule;
    }
    if (std.mem.eql(u8, kind, "code")) {
        const rule = try parseCodeRule(ctx, value);
        return .{ .code = rule };
    }
    if (std.mem.eql(u8, kind, "hook")) {
        const rule = try parseHookRule(ctx, namespace, value);
        return rule;
    }
    return error.InvalidDescriptor;
}

fn parseCodeCapability(
    ctx: *EvalContext,
    value: Value,
) (Error || RegistryError)!?CodeRule {
    if (Value.isNil(value)) return null;
    const rule = try parseCodeRule(ctx, value);
    return rule;
}

fn optionalMapField(ctx: *EvalContext, map: Value, name: []const u8) Error!Value {
    if (!try mapFieldPresent(ctx, map, name)) return .nil;
    return mapField(ctx, map, name);
}

fn parseRegistrationMap(
    ctx: *EvalContext,
    namespace: Value,
    descriptor_value: Value,
) (Error || RegistryError)!Registration {
    if (descriptor_value.typ != b.type_map or descriptor_value.obj == .null) {
        return error.InvalidDescriptor;
    }
    try validateMapKeys(ctx, descriptor_value, &outer_descriptor_fields);
    const primitive = try primitiveIdForValue(
        ctx,
        try requireMapField(ctx, descriptor_value, "primitive"),
    );
    const primitive_revision = try parseRevision(
        try requireMapField(ctx, descriptor_value, "implementation-revision"),
    );
    const rule_revision = try parseRevision(
        try requireMapField(ctx, descriptor_value, "rule-revision"),
    );
    const capabilities = try parseCapabilities(
        ctx,
        try requireMapField(ctx, descriptor_value, "capabilities"),
    );
    const metadata = try parseMetadata(
        ctx,
        try requireMapField(ctx, descriptor_value, "metadata"),
    );
    const jvp = try parseJvpRule(
        ctx,
        namespace,
        try optionalMapField(ctx, descriptor_value, "jvp"),
    );
    const linearize = try parseCodeCapability(
        ctx,
        try optionalMapField(ctx, descriptor_value, "linearize"),
    );
    const transpose_linear = try parseCodeCapability(
        ctx,
        try optionalMapField(ctx, descriptor_value, "transpose-linear"),
    );
    return .{
        .primitive = primitive,
        .primitive_revision = primitive_revision,
        .rule_revision = rule_revision,
        .jvp = jvp,
        .linearize = linearize,
        .transpose_linear = transpose_linear,
        .metadata = metadata,
        .capabilities = capabilities,
    };
}

fn parsePublicRegistration(
    ctx: *EvalContext,
    namespace: Value,
    descriptor_value: Value,
) Error!Registration {
    return parseRegistrationMap(ctx, namespace, descriptor_value) catch |err| switch (err) {
        error.InvalidPrimitive,
        error.InvalidRevision,
        error.MissingCapability,
        error.DuplicatePrimitive,
        error.InvalidDescriptor,
        error.InvalidMetadata,
        error.InvalidArity,
        error.InvalidCapability,
        error.InvalidCode,
        error.InvalidHook,
        error.UnsafeEffects,
        error.VersionOverflow,
        => error.TypeMismatch,
        else => |cause| cause,
    };
}

fn publicRegistry(ctx: *EvalContext) Error!*RegistryOwner {
    return registry(ctx);
}

/// Register one or more immutable AD rule descriptors. Each argument is a
/// descriptor map. For host callers, `object` may itself be the sole map.
pub fn registerRule(
    ctx: *EvalContext,
    namespace: Value,
    object: Value,
    args: []const Value,
) Error!Value {
    if (ctx.mode != .concrete) return error.Unsupported;
    if (ctx.execution == .pure_limited) return error.Denied;
    if (args.len == 0 and object.typ != b.type_map) return error.ArityMismatch;
    if (ctx.effects.state_write != .allow) return error.Denied;
    var registrations: std.ArrayList(Registration) = .empty;
    defer registrations.deinit(ctx.scratch);
    if (args.len == 0) {
        try registrations.append(ctx.scratch, try parsePublicRegistration(ctx, namespace, object));
    } else {
        for (args) |descriptor_value| {
            try registrations.append(ctx.scratch, try parsePublicRegistration(ctx, namespace, descriptor_value));
        }
    }
    const owner = try publicRegistry(ctx);
    const snapshot = owner.publish(ctx, registrations.items) catch |err| switch (err) {
        error.InvalidPrimitive,
        error.InvalidRevision,
        error.MissingCapability,
        error.DuplicatePrimitive,
        error.InvalidDescriptor,
        error.InvalidMetadata,
        error.InvalidArity,
        error.InvalidCapability,
        error.InvalidCode,
        error.InvalidHook,
        error.UnsafeEffects,
        => return error.TypeMismatch,
        error.VersionOverflow => return error.Unsupported,
        else => |cause| return cause,
    };
    const version = std.math.cast(i64, snapshot.version) orelse return error.Unsupported;
    return .i64(version);
}

fn validateHookForInvocation(ctx: *EvalContext, hook: HookRule) Error!void {
    const scope = ctx.activate();
    defer scope.deinit();
    return ad_effects.preflight(ctx.runtime, hook.namespace, hook.callable);
}

fn parseHookResult(value: Value) Error![2]Value {
    if (value.typ != b.type_cons or value.obj == .null) return error.TypeMismatch;
    const first = value.obj.toRef().deref([2]Value);
    if (first[1].typ != b.type_cons or first[1].obj == .null) return error.TypeMismatch;
    const second = first[1].obj.toRef().deref([2]Value);
    if (!Value.isNil(second[1])) return error.TypeMismatch;
    return .{ first[0], second[0] };
}

pub fn materializeCodeCallable(ctx: *EvalContext, body: CodeRule) Error!Value {
    const function = body.code.function(body.function) orelse return error.InvalidCode;
    if (function.has_rest) return error.Unsupported;
    if (!Value.isNil(body.callable)) return body.callable;
    if (function.capture_count != 0) return error.Unsupported;
    const program = try ctx.runtime.lowerCode(ctx.scratch, body.code);
    const index = @intFromEnum(body.function);
    if (index >= program.fns.len) return error.InvalidCode;
    const lowered = program.fns[index];
    const ref = try ctx.runtime.store.create(skript.data.Closure);
    ctx.runtime.store.store(skript.data.Closure, ref.deref(skript.data.Closure), .{
        .parent_ns = ctx.runtime.root_ns,
        .arglist = lowered.arglist,
        .ir = lowered.ir,
        .constants = lowered.constants,
        .nregs = lowered.nregs,
        .result_count = lowered.result_count,
        .zero_mask = lowered.zero_mask,
        .capture_syms = lowered.capture_syms,
        .captures = &.{},
        .code = body.code,
        .function_id = body.function,
        .fns = program.fns,
    });
    return .closure(ref.toObject());
}

fn invokeCodeJvp(
    ctx: *EvalContext,
    body: CodeRule,
    primals: []const Value,
    tangents: []const Value,
    outputs: []Value,
) Error!void {
    if (outputs.len != 2) return error.ArityMismatch;
    const total = std.math.add(usize, primals.len, tangents.len) catch return error.Unsupported;
    if (total != body.arity) return error.ArityMismatch;
    const call_args = try ctx.scratch.alloc(Value, total);
    defer ctx.scratch.free(call_args);
    @memcpy(call_args[0..primals.len], primals);
    @memcpy(call_args[primals.len..], tangents);
    const callable = try materializeCodeCallable(ctx, body);
    const namespace = if (callable.typ == b.type_closure and callable.obj != .null)
        callable.obj.toRef().deref(skript.data.Closure).parent_ns
    else
        ctx.runtime.root_ns;
    try validateHookForInvocation(ctx, .{
        .namespace = namespace,
        .callable = callable,
        .revision = body.code.revision,
    });
    try ctx.runtime.applyResultsWithContext(ctx, callable, call_args, outputs);
}

/// Invoke a custom JVP body after its capability and effect checks. Builtin
/// rules are intentionally left to the forward transformer.
pub fn invokeJvp(
    ctx: *EvalContext,
    rule: *const PrimitiveRule,
    primals: []const Value,
    tangents: []const Value,
    outputs: []Value,
) Error!void {
    const jvp = rule.jvp orelse return error.Unsupported;
    switch (jvp) {
        .builtin => return error.Unsupported,
        .code => |body| return invokeCodeJvp(ctx, body, primals, tangents, outputs),
        .hook => |hook| {
            if (outputs.len != 2) return error.ArityMismatch;
            try validateHookForInvocation(ctx, hook);
            const primal_list = try list_intrin.list(ctx, .nil, .nil, primals);
            const tangent_list = try list_intrin.list(ctx, .nil, .nil, tangents);
            const result = try ctx.apply(hook.namespace, hook.callable, &.{ primal_list, tangent_list });
            const pair = try parseHookResult(result);
            outputs[0] = pair[0];
            outputs[1] = pair[1];
        },
    }
}

pub fn checkHookResult(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    const pair = try parseHookResult(args[0]);
    for (pair) |value| if (value.typ == b.type_error) return value.errorCode();
    return args[0];
}

/// The only additional primitive required by bound forward mode. Its operation
/// tag is a compact identity, not a source-level name. Main registers this
/// function in the core primitive registry so limited contexts can authorize
/// generated scalar work by PrimitiveId.
pub const ScalarOp = enum(i64) {
    add,
    sub,
    mul,
    div,
    neg,
    sqrt,
    sin,
    cos,
    tan,
    asin,
    acos,
    atan,
    sinh,
    cosh,
    tanh,
    asinh,
    acosh,
    atanh,
    exp,
    log,
    log2,
    log10,
    pow,
    abs_slope,
    zero_like,
    one_like,
    coerce_tangent,
    realize_tangent,
};

pub fn scalarDispatch(
    ctx: *EvalContext,
    _: Value,
    _: Value,
    args: []const Value,
) Error!Value {
    if (args.len == 0 or args[0].typ != b.type_i64) return error.ArityMismatch;
    try ctx.chargeWork(1, 1, .native);
    const raw = args[0].obj.toInt(i64);
    if (raw < @intFromEnum(ScalarOp.add) or raw > @intFromEnum(ScalarOp.realize_tangent)) {
        return error.TypeMismatch;
    }
    const operation: ScalarOp = @enumFromInt(raw);
    const values = args[1..];
    return switch (operation) {
        .add => scalarBinary(ctx, .add, values),
        .sub => scalarBinary(ctx, .sub, values),
        .mul => scalarBinary(ctx, .mul, values),
        .div => scalarBinary(ctx, .div, values),
        .pow => scalarBinary(ctx, .pow, values),
        .neg => scalarUnary(ctx, .neg, values),
        .sqrt => scalarUnary(ctx, .sqrt, values),
        .sin => scalarUnary(ctx, .sin, values),
        .cos => scalarUnary(ctx, .cos, values),
        .tan => scalarUnary(ctx, .tan, values),
        .asin => scalarUnary(ctx, .asin, values),
        .acos => scalarUnary(ctx, .acos, values),
        .atan => scalarUnary(ctx, .atan, values),
        .sinh => scalarUnary(ctx, .sinh, values),
        .cosh => scalarUnary(ctx, .cosh, values),
        .tanh => scalarUnary(ctx, .tanh, values),
        .asinh => scalarUnary(ctx, .asinh, values),
        .acosh => scalarUnary(ctx, .acosh, values),
        .atanh => scalarUnary(ctx, .atanh, values),
        .exp => scalarUnary(ctx, .exp, values),
        .log => scalarUnary(ctx, .log, values),
        .log2 => scalarUnary(ctx, .log2, values),
        .log10 => scalarUnary(ctx, .log10, values),
        .abs_slope => absSlope(ctx, values),
        .zero_like => scalarLike(ctx, values, false),
        .one_like => scalarLike(ctx, values, true),
        .coerce_tangent => coerceTangent(ctx, values, false),
        .realize_tangent => coerceTangent(ctx, values, true),
    };
}

const BinaryOp = enum { add, sub, mul, div, pow };
const UnaryOp = enum {
    neg,
    sqrt,
    sin,
    cos,
    tan,
    asin,
    acos,
    atan,
    sinh,
    cosh,
    tanh,
    asinh,
    acosh,
    atanh,
    exp,
    log,
    log2,
    log10,
};

fn scalarBinary(ctx: *EvalContext, operation: BinaryOp, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (operation == .add and args[0].typ == b.type_tensor and args[1].typ == b.type_tensor) {
        return skript.autodiff_tensor.addTangents(ctx, args[0], args[1]);
    }
    const result_type = intrin.numericJoin(args) orelse return error.TypeMismatch;
    if (result_type == b.type_i64) return exactI64(ctx, operation, args);
    const target = binaryTarget(result_type, operation) orelse return error.Unsupported;
    return target(ctx, .nil, .nil, args);
}

fn exactI64(ctx: *EvalContext, operation: BinaryOp, args: []const Value) Error!Value {
    const left = (try tree.coerceNumeric(b.type_i64, args[0])).obj.toInt(i64);
    const right = (try tree.coerceNumeric(b.type_i64, args[1])).obj.toInt(i64);
    return .i64(switch (operation) {
        .add => std.math.add(i64, left, right) catch return error.Unsupported,
        .sub => std.math.sub(i64, left, right) catch return error.Unsupported,
        .mul => std.math.mul(i64, left, right) catch return error.Unsupported,
        .div => blk: {
            if (right == 0 or (left == std.math.minInt(i64) and right == -1)) {
                return error.Unsupported;
            }
            if (@rem(left, right) != 0) return error.Unsupported;
            break :blk @divTrunc(left, right);
        },
        .pow => try exactPowI64(ctx, left, right),
    });
}

fn exactPowI64(ctx: *EvalContext, base_input: i64, exponent_input: i64) Error!i64 {
    if (exponent_input < 0) return error.Unsupported;
    var result: i64 = 1;
    var base = base_input;
    var exponent: u64 = @intCast(exponent_input);
    var steps: usize = 0;
    while (exponent != 0) : (steps += 1) {
        if (steps >= 64) return error.Unsupported;
        try ctx.chargeWork(1, 1, .native);
        if ((exponent & 1) != 0) {
            result = std.math.mul(i64, result, base) catch return error.Unsupported;
        }
        exponent >>= 1;
        if (exponent != 0) base = std.math.mul(i64, base, base) catch return error.Unsupported;
    }
    return result;
}

fn binaryTarget(runtime_type: Object, operation: BinaryOp) ?FuncPtr {
    return switch (runtime_type) {
        b.type_i8 => intBinaryTarget("i8", operation),
        b.type_i16 => intBinaryTarget("i16", operation),
        b.type_i32 => intBinaryTarget("i32", operation),
        b.type_u8 => intBinaryTarget("u8", operation),
        b.type_u16 => intBinaryTarget("u16", operation),
        b.type_u32 => intBinaryTarget("u32", operation),
        b.type_u64 => intBinaryTarget("u64", operation),
        b.type_f16 => floatBinaryTarget("f16", operation),
        b.type_f32 => floatBinaryTarget("f32", operation),
        b.type_f64 => floatBinaryTarget("f64", operation),
        b.type_c16 => complexBinaryTarget("c16", operation),
        b.type_c32 => complexBinaryTarget("c32", operation),
        b.type_c64 => complexBinaryTarget("c64", operation),
        else => null,
    };
}

fn intBinaryTarget(comptime prefix: []const u8, operation: BinaryOp) ?FuncPtr {
    return switch (operation) {
        .add => &@field(int_intrin, prefix ++ "_add"),
        .sub => &@field(int_intrin, prefix ++ "_sub"),
        .mul => &@field(int_intrin, prefix ++ "_mul"),
        .div => &@field(int_intrin, prefix ++ "_div"),
        .pow => &@field(int_intrin, prefix ++ "_pow"),
    };
}

fn floatBinaryTarget(comptime prefix: []const u8, operation: BinaryOp) ?FuncPtr {
    return switch (operation) {
        .add => &@field(float_intrin, prefix ++ "_add"),
        .sub => &@field(float_intrin, prefix ++ "_sub"),
        .mul => &@field(float_intrin, prefix ++ "_mul"),
        .div => &@field(float_intrin, prefix ++ "_div"),
        .pow => &@field(float_intrin, prefix ++ "_pow"),
    };
}

fn complexBinaryTarget(comptime prefix: []const u8, operation: BinaryOp) ?FuncPtr {
    return switch (operation) {
        .add => &@field(complex_intrin, prefix ++ "_add"),
        .sub => &@field(complex_intrin, prefix ++ "_sub"),
        .mul => &@field(complex_intrin, prefix ++ "_mul"),
        .div => &@field(complex_intrin, prefix ++ "_div"),
        .pow => if (comptime std.mem.eql(u8, prefix, "c16"))
            &complex_intrin.c16Pow
        else
            &@field(complex_intrin, prefix ++ "_pow"),
    };
}

fn scalarUnary(ctx: *EvalContext, operation: UnaryOp, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (operation == .neg and args[0].typ == b.type_i64) {
        const value = args[0].obj.toInt(i64);
        if (value == std.math.minInt(i64)) return error.Unsupported;
        return .i64(-value);
    }
    const target = unaryTarget(args[0].typ, operation) orelse return error.Unsupported;
    return target(ctx, .nil, .nil, args);
}

fn unaryTarget(runtime_type: Object, operation: UnaryOp) ?FuncPtr {
    return switch (runtime_type) {
        b.type_i8 => integerUnaryTarget("i8", operation),
        b.type_i16 => integerUnaryTarget("i16", operation),
        b.type_i32 => integerUnaryTarget("i32", operation),
        b.type_i64 => integerUnaryTarget("i64", operation),
        b.type_u8 => integerUnaryTarget("u8", operation),
        b.type_u16 => integerUnaryTarget("u16", operation),
        b.type_u32 => integerUnaryTarget("u32", operation),
        b.type_u64 => integerUnaryTarget("u64", operation),
        b.type_f16 => floatUnaryTarget("f16", operation),
        b.type_f32 => floatUnaryTarget("f32", operation),
        b.type_f64 => floatUnaryTarget("f64", operation),
        b.type_c16 => complexUnaryTarget("c16", operation),
        b.type_c32 => complexUnaryTarget("c32", operation),
        b.type_c64 => complexUnaryTarget("c64", operation),
        else => null,
    };
}

fn integerUnaryTarget(comptime prefix: []const u8, operation: UnaryOp) ?FuncPtr {
    return switch (operation) {
        .neg => &@field(int_intrin, prefix ++ "_neg"),
        .sqrt,
        .sin,
        .cos,
        .tan,
        .asin,
        .acos,
        .atan,
        .sinh,
        .cosh,
        .tanh,
        .asinh,
        .acosh,
        .atanh,
        .exp,
        .log,
        .log2,
        .log10,
        => floatUnaryTarget("f64", operation),
    };
}

fn floatUnaryTarget(comptime prefix: []const u8, operation: UnaryOp) ?FuncPtr {
    return switch (operation) {
        .neg => &@field(float_intrin, prefix ++ "_neg"),
        .sqrt => &@field(float_intrin, prefix ++ "_sqrt"),
        .sin => &@field(float_intrin, prefix ++ "_sin"),
        .cos => &@field(float_intrin, prefix ++ "_cos"),
        .tan => &@field(float_intrin, prefix ++ "_tan"),
        .asin => &@field(float_intrin, prefix ++ "_asin"),
        .acos => &@field(float_intrin, prefix ++ "_acos"),
        .atan => &@field(float_intrin, prefix ++ "_atan"),
        .sinh => &@field(float_intrin, prefix ++ "_sinh"),
        .cosh => &@field(float_intrin, prefix ++ "_cosh"),
        .tanh => &@field(float_intrin, prefix ++ "_tanh"),
        .asinh => &@field(float_intrin, prefix ++ "_asinh"),
        .acosh => &@field(float_intrin, prefix ++ "_acosh"),
        .atanh => &@field(float_intrin, prefix ++ "_atanh"),
        .exp => &@field(float_intrin, prefix ++ "_exp"),
        .log => &@field(float_intrin, prefix ++ "_log"),
        .log2 => &@field(float_intrin, prefix ++ "_log2"),
        .log10 => &@field(float_intrin, prefix ++ "_log10"),
    };
}

fn complexUnaryTarget(comptime prefix: []const u8, operation: UnaryOp) ?FuncPtr {
    return switch (operation) {
        .neg => &@field(complex_intrin, prefix ++ "_neg"),
        .sqrt => &@field(complex_intrin, prefix ++ "_sqrt"),
        .sin => &@field(complex_intrin, prefix ++ "_sin"),
        .cos => &@field(complex_intrin, prefix ++ "_cos"),
        .tan => &@field(complex_intrin, prefix ++ "_tan"),
        .asin => &@field(complex_intrin, prefix ++ "_asin"),
        .acos => &@field(complex_intrin, prefix ++ "_acos"),
        .atan => &@field(complex_intrin, prefix ++ "_atan"),
        .sinh => &@field(complex_intrin, prefix ++ "_sinh"),
        .cosh => &@field(complex_intrin, prefix ++ "_cosh"),
        .tanh => &@field(complex_intrin, prefix ++ "_tanh"),
        .asinh => &@field(complex_intrin, prefix ++ "_asinh"),
        .acosh => &@field(complex_intrin, prefix ++ "_acosh"),
        .atanh => &@field(complex_intrin, prefix ++ "_atanh"),
        .exp => &@field(complex_intrin, prefix ++ "_exp"),
        .log => &@field(complex_intrin, prefix ++ "_log"),
        .log2, .log10 => null,
    };
}

fn scalarLike(ctx: *EvalContext, args: []const Value, one: bool) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (tree.numericKind(args[0].typ) != null) {
        return if (one) tree.one(args[0].typ) else tree.zero(args[0].typ);
    }
    return switch (args[0].typ) {
        b.type_c16 => .c16(if (one) .{ 1.0, 0.0 } else .{ 0.0, 0.0 }),
        b.type_c32 => .c32(if (one) .{ 1.0, 0.0 } else .{ 0.0, 0.0 }),
        b.type_c64 => blk: {
            const reference = try ctx.runtime.store.create([2]f64);
            reference.deref([2]f64).* = if (one) .{ 1.0, 0.0 } else .{ 0.0, 0.0 };
            break :blk .c64(reference.toObject());
        },
        else => blk: {
            if (one) return error.TypeMismatch;
            var spec = try tree.flatten(
                ctx.scratch,
                ctx,
                ctx.runtime.tree_registry.current(),
                args[0],
                tree.Limits.gradient,
            );
            defer spec.deinit();
            const vector_space = space.treeSpace(&spec);
            break :blk try vector_space.tangentZero(ctx);
        },
    };
}

fn coerceTangent(ctx: *EvalContext, args: []const Value, allow_nil: bool) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (args[1].isNil()) {
        if (!allow_nil) return error.TypeMismatch;
        return scalarLike(ctx, args[0..1], false);
    }
    if (tree.numericKind(args[0].typ) != null) return tree.coerceNumeric(args[0].typ, args[1]);
    if ((args[0].typ == b.type_c16 or args[0].typ == b.type_c32 or args[0].typ == b.type_c64) and
        args[1].typ == args[0].typ)
    {
        return args[1];
    }
    if (args[0].typ == b.type_c16 or args[0].typ == b.type_c32 or args[0].typ == b.type_c64) {
        return error.TypeMismatch;
    }
    return args[1];
}

fn absSlope(ctx: *EvalContext, args: []const Value) Error!Value {
    if (args.len != 1) return error.TypeMismatch;
    const numeric_kind = tree.numericKind(args[0].typ) orelse return error.TypeMismatch;
    const one = try scalarLike(ctx, args, true);
    const nonnegative = switch (numeric_kind) {
        .f16 => args[0].obj.tof16() >= 0.0,
        .f32 => args[0].obj.tof32() >= 0.0,
        .f64 => args[0].obj.tof64() >= 0.0,
        .i8 => args[0].obj.toInt(i8) >= 0,
        .i16 => args[0].obj.toInt(i16) >= 0,
        .i32 => args[0].obj.toInt(i32) >= 0,
        .i64 => args[0].obj.toInt(i64) >= 0,
        .u8, .u16, .u32, .u64 => true,
    };
    if (nonnegative) return one;
    return scalarUnary(ctx, .neg, &.{one});
}

fn testPrimitive(
    _: *EvalContext,
    _: Value,
    _: Value,
    _: []const Value,
) Error!Value {
    return .nil;
}

test "rule publication retains immutable identity-keyed snapshots" {
    var runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    var owner = try RegistryOwner.init(std.testing.allocator, runtime.context());
    defer owner.deinit();
    const before = owner.current();
    const primitive = runtime.intrinsics.registryVersion().idForNative(&testPrimitive);
    try std.testing.expect(primitive == null);
    try std.testing.expect(before.validFor(runtime.intrinsics.registryVersion()));
    try std.testing.expect(descriptorForNative(&float_intrin.f64_mul).?.rule == .mul);
    try std.testing.expect(descriptorForNative(&float_intrin.f64_sin).?.rule == .sin);
    try std.testing.expect(descriptorForNative(&skript.autodiff_linearize.cotangentZero).?.rule == .constant);
    try std.testing.expect(descriptorForNative(&skript.autodiff_linearize.cotangentZero).?.metadata.arity.? == 1);
    try std.testing.expect(descriptorForNative(&skript.autodiff_linearize.cotangentAdd).?.rule == .cotangent_add);
    try std.testing.expect(descriptorForNative(&skript.autodiff_linearize.cotangentAdd).?.metadata.arity.? == 3);
    try std.testing.expect(descriptorForNative(&skript.autodiff_linearize.scalarAdjoint) == null);
}

test "scalar dispatch refuses fractional and overflowing i64 tangents" {
    var runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    try std.testing.expectError(error.Unsupported, scalarDispatch(
        ctx,
        .nil,
        .nil,
        &.{ .i64(@intFromEnum(ScalarOp.div)), .i64(1), .i64(2) },
    ));
    try std.testing.expectError(error.Unsupported, scalarDispatch(
        ctx,
        .nil,
        .nil,
        &.{ .i64(@intFromEnum(ScalarOp.add)), .i64(std.math.maxInt(i64)), .i64(1) },
    ));
}

fn addTestCodeParameter(
    builder: *Code.Builder,
    runtime: *skript.Runtime,
    function: Code.FunctionId,
    block: Code.BlockId,
    name: []const u8,
) !Code.ValueId {
    const binding = try builder.addBinding(
        function,
        try runtime.store.getsym(name),
        .parameter,
        .{},
    );
    builder.bindings.items[@intFromEnum(binding)].value = try builder.addValue(function);
    try builder.addParameter(function, binding);
    return builder.addNode(function, block, .{ .local_read = binding }, .{});
}

fn makeTestCodeJvp(runtime: *skript.Runtime) !Value {
    var builder = Code.Builder.init(runtime.static, runtime.context());
    const identity = try runtime.allocCodeIdentity();
    builder.id = identity.id;
    builder.revision = identity.revision;
    const function = try builder.addFunction(null, .{});
    builder.functions.items[@intFromEnum(function)].result_count = 2;
    const block = try builder.addBlock(function);
    const primal = try addTestCodeParameter(&builder, runtime, function, block, "primal");
    const tangent = try addTestCodeParameter(&builder, runtime, function, block, "tangent");
    const negate = runtime.context().registry.idForNative(&float_intrin.f64_neg) orelse return error.Unsupported;
    const primal_result = try builder.addNode(function, block, .{ .primitive_call = .{
        .primitive = negate,
        .args = try builder.addOperands(&.{primal}),
    } }, .{});
    const tangent_result = try builder.addNode(function, block, .{ .primitive_call = .{
        .primitive = negate,
        .args = try builder.addOperands(&.{tangent}),
    } }, .{});
    try builder.setTerminator(
        block,
        .{ .return_values = try builder.addOperands(&.{ primal_result, tangent_result }) },
    );
    const code = try builder.finish(runtime.context().scratch);
    code.owner = runtime;
    const program = try runtime.lowerCode(runtime.context().scratch, code);
    const lowered = program.fns[@intFromEnum(function)];
    const reference = try runtime.store.create(skript.data.Closure);
    runtime.store.store(skript.data.Closure, reference.deref(skript.data.Closure), .{
        .parent_ns = runtime.root_ns,
        .arglist = lowered.arglist,
        .ir = lowered.ir,
        .constants = lowered.constants,
        .nregs = lowered.nregs,
        .result_count = lowered.result_count,
        .zero_mask = lowered.zero_mask,
        .code = code,
        .function_id = function,
        .fns = program.fns,
    });
    return .closure(reference.toObject());
}

test "custom hook JVP receives proper primal and tangent lists" {
    var runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const registration = try runtime.evalString(
        \\:{:primitive @f64.neg
        \\  :implementation-revision 1
        \\  :rule-revision 7
        \\  :capabilities (list :jvp)
        \\  :metadata :{:arity 1
        \\              :linearity :linear
        \\              :allocation :none
        \\              :higher-order #t}
        \\  :jvp :{:kind :hook
        \\          :callable (fn (primals tangents)
        \\                      (list (- (fst primals)) (- (fst tangents))))
        \\          :revision 3}}
    );
    const published = try registerRule(ctx, runtime.root_ns, .nil, &.{registration});
    try std.testing.expect(published.obj.toInt(i64) > 1);

    const outputs = try parseHookResult(try skript.intrinsics.ad.jvp(
        ctx,
        runtime.root_ns,
        .nil,
        &.{ .intrinsic(&float_intrin.f64_neg), .f64(7.0), .f64(3.0) },
    ));
    try std.testing.expectEqual(Value.f64(-7.0), outputs[0]);
    try std.testing.expectEqual(Value.f64(-3.0), outputs[1]);
}
test "native hook with known descriptor arity is rejected" {
    var runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const registration = try runtime.evalString(
        \\:{:primitive @f64.neg
        \\  :implementation-revision 1
        \\  :rule-revision 8
        \\  :capabilities (list :jvp)
        \\  :metadata :{:arity 1
        \\              :linearity :linear
        \\              :allocation :none
        \\              :higher-order #t}
        \\  :jvp :{:kind :hook
        \\          :callable @f64.neg
        \\          :revision 5}}
    );
    const owner = try registry(ctx);
    const before = owner.current();
    try std.testing.expectError(
        error.TypeMismatch,
        registerRule(ctx, runtime.root_ns, .nil, &.{registration}),
    );
    try std.testing.expect(before == owner.current());
}

test "custom direct Code JVP returns two unboxed results" {
    var runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const callable = try makeTestCodeJvp(runtime);
    try runtime.nsBind(
        runtime.root_ns,
        try runtime.store.getsym("direct-custom-jvp"),
        callable,
    );
    const registration = try runtime.evalString(
        \\:{:primitive @f64.neg
        \\  :implementation-revision 1
        \\  :rule-revision 5
        \\  :capabilities (list :jvp)
        \\  :metadata :{:arity 1
        \\              :linearity :linear
        \\              :allocation :none
        \\              :higher-order #t}
        \\  :jvp :{:kind :code
        \\          :callable direct-custom-jvp
        \\          :arity 2
        \\          :revision 4}}
    );
    const ctx = runtime.context();
    _ = try registerRule(ctx, runtime.root_ns, .nil, &.{registration});
    const outputs = try parseHookResult(try skript.intrinsics.ad.jvp(
        ctx,
        runtime.root_ns,
        .nil,
        &.{ .intrinsic(&float_intrin.f64_neg), .f64(11.0), .f64(13.0) },
    ));
    try std.testing.expectEqual(Value.f64(-11.0), outputs[0]);
    try std.testing.expectEqual(Value.f64(-13.0), outputs[1]);
}

test "invalid registration batches never publish" {
    var runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const valid = try runtime.evalString(
        \\:{:primitive @f64.neg
        \\  :implementation-revision 1
        \\  :rule-revision 2
        \\  :capabilities (list :jvp)
        \\  :metadata :{:arity 1
        \\              :linearity :linear
        \\              :allocation :none
        \\              :higher-order #t}
        \\  :jvp :{:kind :hook
        \\          :callable (fn (primals tangents)
        \\                      (list (fst primals) (fst tangents)))
        \\          :revision 1}}
    );
    const owner = try registry(ctx);
    const before = owner.current();
    try std.testing.expectError(
        error.TypeMismatch,
        registerRule(ctx, runtime.root_ns, .nil, &.{ valid, valid }),
    );
    try std.testing.expect(before == owner.current());

    const stale = try runtime.evalString(
        \\:{:primitive @f64.neg
        \\  :implementation-revision 2
        \\  :rule-revision 2
        \\  :capabilities (list :jvp)
        \\  :metadata :{:arity 1
        \\              :linearity :linear
        \\              :allocation :none
        \\              :higher-order #t}
        \\  :jvp :{:kind :hook
        \\          :callable (fn (primals tangents)
        \\                      (list (fst primals) (fst tangents)))
        \\          :revision 1}}
    );
    try std.testing.expectError(
        error.TypeMismatch,
        registerRule(ctx, runtime.root_ns, .nil, &.{stale}),
    );
    try std.testing.expect(before == owner.current());

    const malformed = try runtime.evalString(
        \\:{:primitive @f64.neg
        \\  :implementation-revision 1
        \\  :rule-revision 2
        \\  :capabilities (list :jvp)
        \\  :metadata :{:arity -1
        \\              :linearity :linear
        \\              :allocation :none
        \\              :higher-order #t}
        \\  :jvp nil}
    );
    try std.testing.expectError(
        error.TypeMismatch,
        registerRule(ctx, runtime.root_ns, .nil, &.{malformed}),
    );
    try std.testing.expect(before == owner.current());
}

test "held snapshots stay stable while replacements advance registry revision" {
    var runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const first = try runtime.evalString(
        \\:{:primitive @f64.neg
        \\  :implementation-revision 1
        \\  :rule-revision 7
        \\  :capabilities (list :jvp)
        \\  :metadata :{:arity 1
        \\              :linearity :linear
        \\              :allocation :none
        \\              :higher-order #t}
        \\  :jvp :{:kind :hook
        \\          :callable (fn (primals tangents)
        \\                      (list (fst primals) (fst tangents)))
        \\          :revision 1}}
    );
    _ = try registerRule(ctx, runtime.root_ns, .nil, &.{first});
    const owner = try registry(ctx);
    const held = owner.current();
    const primitive = ctx.registry.idForNative(&float_intrin.f64_neg) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 7), held.find(primitive).?.rule_revision);

    const replacement = try runtime.evalString(
        \\:{:primitive @f64.neg
        \\  :implementation-revision 1
        \\  :rule-revision 8
        \\  :capabilities (list :jvp)
        \\  :metadata :{:arity 1
        \\              :linearity :linear
        \\              :allocation :none
        \\              :higher-order #t}
        \\  :jvp :{:kind :hook
        \\          :callable (fn (primals tangents)
        \\                      (list (fst tangents) (fst primals)))
        \\          :revision 2}}
    );
    _ = try registerRule(ctx, runtime.root_ns, .nil, &.{replacement});
    const latest = owner.current();
    try std.testing.expect(latest != held);
    try std.testing.expect(latest.version > held.version);
    try std.testing.expectEqual(@as(u64, 7), held.find(primitive).?.rule_revision);
    try std.testing.expectEqual(@as(u64, 8), latest.find(primitive).?.rule_revision);
}

test "JVP hook effect changes are denied before output" {
    var runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    var output_storage: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_storage);
    runtime.stdout = &output;
    _ = try runtime.evalString("(def custom-jvp-target (fn (value) value))");
    const registration = try runtime.evalString(
        \\:{:primitive @f64.neg
        \\  :implementation-revision 1
        \\  :rule-revision 3
        \\  :capabilities (list :jvp)
        \\  :metadata :{:arity 1
        \\              :linearity :linear
        \\              :allocation :none
        \\              :higher-order #t}
        \\  :jvp :{:kind :hook
        \\          :callable (fn (primals tangents)
        \\                      (custom-jvp-target "blocked")
        \\                      (list (fst primals) (fst tangents)))
        \\          :revision 1}}
    );
    const ctx = runtime.context();
    _ = try registerRule(ctx, runtime.root_ns, .nil, &.{registration});
    _ = try runtime.evalString("(def custom-jvp-target write)");
    const primitive = ctx.registry.idForNative(&float_intrin.f64_neg) orelse
        return error.TestUnexpectedResult;
    const rule = (try builtinSnapshot(ctx)).find(primitive) orelse
        return error.TestUnexpectedResult;
    var outputs: [2]Value = undefined;
    try std.testing.expectError(
        error.Unsupported,
        invokeJvp(ctx, rule, &.{.f64(1.0)}, &.{.f64(2.0)}, &outputs),
    );
    try std.testing.expectEqual(@as(usize, 0), output.buffered().len);
}

var linearize_only_primal_calls: usize = 0;

fn linearizeOnlySquare(
    _: *EvalContext,
    _: Value,
    _: Value,
    args: []const Value,
) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (args[0].typ != b.type_f64) return error.TypeMismatch;
    linearize_only_primal_calls += 1;
    const value = args[0].obj.tof64();
    return .f64(value * value);
}

fn setupLinearizeOnlyPrimitive(runtime: *skript.Runtime) !*EvalContext {
    const primitive_registry = try runtime.intrinsics.publish(&.{.{
        .stable_name = "test.autodiff.linearize-only-square",
        .invoke = Primitive.Invocation.nativePtr(&linearizeOnlySquare),
        .effects = .none,
        .reads_argument_state = false,
        .callbacks = .none,
        .resources = .{ .fixed = .{} },
        .suspension = .never,
    }});
    const ctx = runtime.context();
    ctx.registry = primitive_registry;
    try runtime.nsBind(
        runtime.root_ns,
        try runtime.store.getsym("linearize-only-square"),
        .intrinsic(&linearizeOnlySquare),
    );
    try runtime.nsBind(
        runtime.root_ns,
        try runtime.store.getsym("linearize-only-factor"),
        .f64(2.0),
    );
    return ctx;
}

fn linearizeOnlyDescriptor(
    runtime: *skript.Runtime,
    rule_revision: i64,
    metadata_arity: i64,
    nonlinear: bool,
) !Value {
    _ = try runtime.evalString(if (nonlinear)
        \\(def linearize-only-rule
        \\  (fn (x)
        \\    (list (linearize-only-square x)
        \\          (fn (dx) (* dx dx)))))
    else
        \\(def linearize-only-rule
        \\  (fn (x)
        \\    (list (linearize-only-square x)
        \\          (fn (dx) (* (* linearize-only-factor x) dx)))))
    );
    try runtime.nsBind(
        runtime.root_ns,
        try runtime.store.getsym("linearize-only-rule-revision"),
        .i64(rule_revision),
    );
    try runtime.nsBind(
        runtime.root_ns,
        try runtime.store.getsym("linearize-only-metadata-arity"),
        .i64(metadata_arity),
    );
    return runtime.evalString(
        \\:{:primitive linearize-only-square
        \\  :implementation-revision 1
        \\  :rule-revision linearize-only-rule-revision
        \\  :capabilities (list :linearize)
        \\  :metadata :{:arity linearize-only-metadata-arity
        \\              :linearity :nonlinear
        \\              :allocation :none
        \\              :higher-order #t}
        \\  :linearize :{:kind :code
        \\               :callable linearize-only-rule
        \\               :arity 1
        \\               :revision linearize-only-rule-revision}}
    );
}

fn applyLinearizeOnlyJvp(
    ctx: *EvalContext,
    callable: Value,
    primal: Value,
    tangent: Value,
) Error![2]Value {
    var outputs: [2]Value = undefined;
    var workspace = skript.Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    try workspace.apply(ctx, callable, &.{ primal, tangent }, &outputs);
    for (outputs) |value| if (value.typ == b.type_error) return value.errorCode();
    return outputs;
}

test "public linearize-only rule executes JVP linearize and VJP once" {
    var runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = try setupLinearizeOnlyPrimitive(runtime);
    const malformed = try linearizeOnlyDescriptor(runtime, 1, 2, false);
    try std.testing.expectError(
        error.TypeMismatch,
        registerRule(ctx, runtime.root_ns, .nil, &.{malformed}),
    );
    const registration = try linearizeOnlyDescriptor(runtime, 1, 1, false);
    _ = try registerRule(ctx, runtime.root_ns, .nil, &.{registration});
    const target = Value.intrinsic(&linearizeOnlySquare);

    linearize_only_primal_calls = 0;
    const jvp_result = try parseHookResult(try skript.intrinsics.ad.jvp(
        ctx,
        runtime.root_ns,
        .nil,
        &.{ target, .f64(3.0), .f64(4.0) },
    ));
    try std.testing.expectEqual(Value.f64(9.0), jvp_result[0]);
    try std.testing.expectEqual(Value.f64(24.0), jvp_result[1]);
    try std.testing.expectEqual(@as(usize, 1), linearize_only_primal_calls);

    linearize_only_primal_calls = 0;
    const linearized = try parseHookResult(try skript.intrinsics.ad_reverse.linearize(
        ctx,
        runtime.root_ns,
        .nil,
        &.{ target, .f64(3.0) },
    ));
    try std.testing.expectEqual(Value.f64(9.0), linearized[0]);
    try std.testing.expectEqual(
        Value.f64(12.0),
        try ctx.apply(runtime.root_ns, linearized[1], &.{.f64(2.0)}),
    );
    try std.testing.expectEqual(@as(usize, 1), linearize_only_primal_calls);
    _ = try skript.intrinsics.ad_reverse.closeLinear(
        ctx,
        runtime.root_ns,
        .nil,
        &.{linearized[1]},
    );

    linearize_only_primal_calls = 0;
    const reverse = try parseHookResult(try skript.intrinsics.ad_reverse.vjp(
        ctx,
        runtime.root_ns,
        .nil,
        &.{ target, .f64(3.0) },
    ));
    try std.testing.expectEqual(Value.f64(9.0), reverse[0]);
    try std.testing.expectEqual(
        Value.f64(12.0),
        try ctx.apply(runtime.root_ns, reverse[1], &.{.f64(2.0)}),
    );
    try std.testing.expectEqual(@as(usize, 1), linearize_only_primal_calls);
    _ = try skript.intrinsics.ad_reverse.closeLinear(
        ctx,
        runtime.root_ns,
        .nil,
        &.{reverse[1]},
    );
}

test "public linearize-only closures reject stale rule and dependency" {
    var runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = try setupLinearizeOnlyPrimitive(runtime);
    const registration = try linearizeOnlyDescriptor(runtime, 1, 1, false);
    _ = try registerRule(ctx, runtime.root_ns, .nil, &.{registration});
    const source = try runtime.evalString("(fn (x) (linearize-only-square x))");

    const dependency_bound = try skript.intrinsics.ad.jvpClosure(ctx, source, 0);
    const initial = try applyLinearizeOnlyJvp(
        ctx,
        dependency_bound,
        .f64(3.0),
        .f64(1.0),
    );
    try std.testing.expectEqual(Value.f64(9.0), initial[0]);
    try std.testing.expectEqual(Value.f64(6.0), initial[1]);
    try runtime.nsBind(
        runtime.root_ns,
        try runtime.store.getsym("linearize-only-factor"),
        .f64(3.0),
    );
    try std.testing.expectError(
        error.Unsupported,
        applyLinearizeOnlyJvp(ctx, dependency_bound, .f64(3.0), .f64(1.0)),
    );

    try runtime.nsBind(
        runtime.root_ns,
        try runtime.store.getsym("linearize-only-factor"),
        .f64(2.0),
    );
    const rule_bound = try skript.intrinsics.ad.jvpClosure(ctx, source, 0);
    const replacement = try linearizeOnlyDescriptor(runtime, 2, 1, false);
    _ = try registerRule(ctx, runtime.root_ns, .nil, &.{replacement});
    try std.testing.expectError(
        error.Unsupported,
        applyLinearizeOnlyJvp(ctx, rule_bound, .f64(3.0), .f64(1.0)),
    );
}

test "public linearize-only nonlinear returned tangent is rejected" {
    var runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = try setupLinearizeOnlyPrimitive(runtime);
    const registration = try linearizeOnlyDescriptor(runtime, 1, 1, true);
    _ = try registerRule(ctx, runtime.root_ns, .nil, &.{registration});

    linearize_only_primal_calls = 0;
    try std.testing.expectError(
        error.Unsupported,
        skript.intrinsics.ad_reverse.linearize(
            ctx,
            runtime.root_ns,
            .nil,
            &.{ Value.intrinsic(&linearizeOnlySquare), .f64(3.0) },
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), linearize_only_primal_calls);
}
