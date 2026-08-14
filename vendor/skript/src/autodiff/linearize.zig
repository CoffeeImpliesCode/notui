//! Primal-once linearization of immutable bound Code.

const std = @import("std");
const skript = @import("../root.zig");
const Code = @import("../code.zig");
const Primitive = @import("../primitive.zig");
const effects = @import("../ad_effects.zig");
const tensor_ad = @import("tensor.zig");
const rules = @import("rules.zig");
const forward = @import("forward.zig");
const callables = @import("callable.zig");
const tree = @import("tree.zig");
const space = @import("space.zig");

const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;
const Error = skript.Error;
const EvalContext = skript.EvalContext;
const Runtime = skript.Runtime;
const Value = skript.Value;
const Closure = skript.data.Closure;
const ClosureGuard = skript.data.ClosureGuard;
const Sym = skript.Sym;
const b = skript.builtins;
const tensor_intrin = skript.intrinsics.tensor;

const region_open: u8 = 0;
const region_closed: u8 = 1;
const max_steps: usize = 1_000_000;
const max_call_depth: usize = 64;
const max_value_depth: usize = 64;

/// Borrowed residual metadata backed by one live Region lease.
pub const TensorLinearInfo = struct {
    id: u64,
    operation: rules.BuiltinJvp,
    input_count: usize,
    inputs: []const Value,
    input_prototypes: []const Value,
    output: Value,
    nested_order: u8 = 0,
    region: ?*Region,

    pub fn deinit(self: *TensorLinearInfo) void {
        const region = self.region orelse return;
        // Invalidate borrowed fields, but keep a null lease so a repeated
        // deinit cannot release the same Region twice.
        self.* = undefined;
        self.region = null;
        region.release();
    }
};

const SpaceRecord = struct {
    id: u64,
    region: *Region,
    algebra: space.SpaceSpec,
    next: ?*SpaceRecord,
};

const HookSnapshot = struct {
    value: Value,
    captures: []const Value,
};

const ValueSnapshot = struct {
    value: Value,
    structure: tree.TreeSpec,
};

const TensorLinearRecord = struct {
    id: u64,
    region: *Region,
    operation: rules.BuiltinJvp,
    kernel: Value,
    inputs: []const Value,
    input_prototypes: []const Value,
    output: Value,
    coefficients: []const u64,
    control: []const u32,
    prefixes: []const Value,
    nested_order: u8 = 0,
    pullback: std.atomic.Value(?*const Value) = .init(null),
    next: ?*TensorLinearRecord,
};
const Storage = struct {
    arena: Arena,

    fn init(allocator: Allocator) Storage {
        return .{ .arena = .init(allocator) };
    }

    fn deinit(self: *Storage) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Runtime owner for reclaimable residual allocations. Region and guard
/// tombstones themselves live in Runtime.static and therefore remain safe to
/// inspect until Runtime.deinit.
pub const State = struct {
    allocator: Allocator,
    head: std.atomic.Value(?*Region) = .init(null),
    next_record: std.atomic.Value(usize) = .init(1),
    pub fn init(allocator: Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        var region = self.head.swap(null, .acq_rel);
        while (region) |current| {
            const next = current.next;
            current.close();
            std.debug.assert(current.users.load(.acquire) == 0);
            region = next;
        }
        self.* = undefined;
    }

    fn createStorage(self: *State, ctx: *EvalContext) Error!*Storage {
        try ctx.chargeAllocation(@sizeOf(Storage), 1, .transform);
        const storage = self.allocator.create(Storage) catch return error.OutOfMemory;
        storage.* = Storage.init(self.allocator);
        return storage;
    }

    fn destroyStorage(self: *State, storage: *Storage) void {
        storage.deinit();
        self.allocator.destroy(storage);
    }

    fn track(self: *State, region: *Region) void {
        var head = self.head.load(.acquire);
        while (true) {
            region.next = head;
            if (self.head.cmpxchgWeak(head, region, .acq_rel, .acquire)) |observed| {
                head = observed;
                continue;
            }
            return;
        }
    }
    fn allocateRecordId(self: *State) Error!u64 {
        const limit: usize = @min(std.math.maxInt(usize), std.math.maxInt(i64));
        var id = self.next_record.load(.acquire);
        while (id < limit) {
            if (self.next_record.cmpxchgStrong(id, id + 1, .acq_rel, .acquire)) |next| {
                std.debug.assert(next > id);
                id = next;
            } else return id;
        }
        return error.Exhausted;
    }
};

/// Stable owner and expiry token for one residual linear callable.
pub const Region = struct {
    runtime: *Runtime,
    owner: *State,
    storage: std.atomic.Value(?*Storage),
    state: std.atomic.Value(u8) = .init(region_open),
    users: std.atomic.Value(u32) = .init(0),
    next: ?*Region = null,
    records: ?*TensorLinearRecord = null,
    spaces: std.atomic.Value(?*SpaceRecord) = .init(null),
    tree_version: *const tree.RegistryVersion,
    space_version: *const space.RegistryVersion,
    argument_spaces: []const space.SpaceSpec = &.{},
    space_reads: std.ArrayList(effects.Read) = .empty,
    space_hooks: std.ArrayList(HookSnapshot) = .empty,
    space_values: std.ArrayList(ValueSnapshot) = .empty,
    registry: *const Primitive.RegistryVersion,
    rules_version: *const rules.RegistryVersion,
    inherited: ?*const ClosureGuard,
    expected_arguments: []const Value,

    pub fn close(self: *Region) void {
        if (self.state.cmpxchgStrong(region_open, region_closed, .acq_rel, .acquire) == null) {
            self.reclaim();
        }
    }

    pub fn deinit(self: *Region) void {
        self.close();
    }

    pub fn isClosed(self: *const Region) bool {
        return self.state.load(.acquire) != region_open;
    }

    pub fn acquire(self: *Region) Error!void {
        if (self.state.load(.acquire) != region_open) return error.Expired;
        var users = self.users.load(.acquire);
        while (users != std.math.maxInt(u32)) {
            if (self.users.cmpxchgWeak(users, users + 1, .acq_rel, .acquire)) |observed| {
                users = observed;
                continue;
            }
            if (self.state.load(.acquire) == region_open and
                self.storage.load(.acquire) != null)
            {
                return;
            }
            self.release();
            return error.Expired;
        }
        return error.Exhausted;
    }

    pub fn release(self: *Region) void {
        const old = self.users.fetchSub(1, .acq_rel);
        std.debug.assert(old != 0);
        if (old == 1) self.reclaim();
    }

    fn reclaim(self: *Region) void {
        if (self.state.load(.acquire) != region_closed) return;
        if (self.users.load(.acquire) != 0) return;
        const storage = self.storage.swap(null, .acq_rel) orelse return;
        self.owner.destroyStorage(storage);
    }

    pub fn check(self: *const Region, ctx: *EvalContext) Error!void {
        return checkRegion(ctx.runtime, self);
    }

    pub fn tangentPrototype(
        self: *Region,
        ctx: *EvalContext,
        algebra: *const space.SpaceSpec,
        primal: Value,
    ) Error!Value {
        if (ctx.runtime != self.runtime) return error.Denied;
        try self.acquire();
        defer self.release();
        const prototype = if (algebra.usesRegisteredAlgebra()) try algebra.tangentZero(ctx) else primal;
        return prototypeValue(ctx, self, prototype, 0);
    }

    pub fn resolveSpace(self: *Region, ctx: *EvalContext, primal: Value) Error!space.SpaceSpec {
        if (ctx.runtime != self.runtime) return error.Denied;
        try self.acquire();
        defer self.release();
        if (ctx.runtime.space_registry.current().find(primal.typ)) |registered| {
            try rememberAlgebra(ctx, self, registered);
            return registered.*;
        }
        if (tree.isNumeric(primal)) return space.scalar(primal.typ);
        const storage = self.storage.load(.acquire) orelse return error.Expired;
        const allocator = storage.arena.allocator();
        const structure = try allocator.create(tree.TreeSpec);
        structure.* = try tree.flatten(allocator, ctx, self.tree_version, primal, tree.Limits.generic);
        const algebra = try space.resolve(ctx, structure);
        try rememberAlgebra(ctx, self, &algebra);
        return algebra;
    }

    pub fn addSpace(self: *Region, ctx: *EvalContext, algebra: space.SpaceSpec) Error!u64 {
        if (ctx.runtime != self.runtime) return error.Denied;
        try self.acquire();
        defer self.release();
        const storage = self.storage.load(.acquire) orelse return error.Expired;
        const allocator = storage.arena.allocator();
        try algebra.validate();
        try ctx.charge(.{ .objects = 1 }, .transform);
        const record = try allocator.create(SpaceRecord);
        record.* = .{
            .id = try self.owner.allocateRecordId(),
            .region = self,
            .algebra = algebra,
            .next = null,
        };
        record.algebra.allocator = null;
        if (algebra.metric == .diagonal) {
            const diagonal = try allocator.dupe(f64, algebra.metric.diagonal);
            record.algebra.metric = .{ .diagonal = diagonal };
        }
        var previous = self.spaces.load(.acquire);
        while (true) {
            try ctx.chargeWork(1, 1, .transform);
            record.next = previous;
            if (self.spaces.cmpxchgWeak(previous, record, .acq_rel, .acquire)) |observed| {
                previous = observed;
                continue;
            }
            return record.id;
        }
    }

    fn addTensorRecord(
        self: *Region,
        ctx: *EvalContext,
        operation: rules.BuiltinJvp,
        kernel: Value,
        inputs: []const Value,
        input_prototypes: []const Value,
        output: Value,
        coefficients: []const u64,
        control: []const u32,
        prefixes: []const Value,
        nested_order: u8,
    ) Error!u64 {
        if (ctx.runtime != self.runtime) return error.Denied;
        if (self.state.load(.acquire) != region_open) return error.Expired;
        const storage = self.storage.load(.acquire) orelse return error.Expired;
        const allocator = storage.arena.allocator();
        const id = try self.owner.allocateRecordId();
        const record = allocator.create(TensorLinearRecord) catch return error.OutOfMemory;
        record.* = .{
            .id = id,
            .region = self,
            .operation = operation,
            .kernel = kernel,
            .inputs = allocator.dupe(Value, inputs) catch return error.OutOfMemory,
            .input_prototypes = allocator.dupe(Value, input_prototypes) catch return error.OutOfMemory,
            .output = output,
            .coefficients = allocator.dupe(u64, coefficients) catch return error.OutOfMemory,
            .control = allocator.dupe(u32, control) catch return error.OutOfMemory,
            .prefixes = allocator.dupe(Value, prefixes) catch return error.OutOfMemory,
            .nested_order = nested_order,
            .next = self.records,
        };
        self.records = record;
        try ctx.chargeWork(1, 1, .transform);
        return id;
    }

    fn findTensorRecordInRegion(
        ctx: *EvalContext,
        current: *Region,
        id: u64,
    ) Error!?*TensorLinearRecord {
        if (current.runtime != ctx.runtime) return error.Denied;
        try ctx.chargeWork(1, 1, .native);
        if (current.isClosed()) return null;
        try current.acquire();
        var transferred = false;
        defer if (!transferred) current.release();
        var record = current.records;
        while (record) |candidate| {
            try ctx.chargeWork(1, 1, .native);
            if (candidate.id == id) {
                try checkRegion(ctx.runtime, current);
                transferred = true;
                return candidate;
            }
            record = candidate.next;
        }
        return null;
    }

    fn findTensorRecord(
        ctx: *EvalContext,
        id: u64,
        candidate: ?*Region,
    ) Error!*TensorLinearRecord {
        if (id == 0) return error.InvalidCode;
        if (candidate) |current| {
            if (try findTensorRecordInRegion(ctx, current, id)) |record| return record;
        }
        var region = ctx.runtime.linearization_state.head.load(.acquire);
        while (region) |current| {
            try ctx.chargeWork(1, 1, .native);
            if (try findTensorRecordInRegion(ctx, current, id)) |record| return record;
            region = current.next;
        }
        return error.Expired;
    }

    fn tensorLinearInfoWithCandidate(
        ctx: *EvalContext,
        id: u64,
        candidate: ?*Region,
    ) Error!TensorLinearInfo {
        try ctx.check();
        const record = try findTensorRecord(ctx, id, candidate);
        const result: TensorLinearInfo = .{
            .id = record.id,
            .operation = record.operation,
            .input_count = record.inputs.len,
            .inputs = record.inputs,
            .input_prototypes = record.input_prototypes,
            .output = record.output,
            .nested_order = record.nested_order,
            .region = record.region,
        };
        return result;
    }

    pub fn tensorLinearInfo(ctx: *EvalContext, id: u64) Error!TensorLinearInfo {
        return tensorLinearInfoWithCandidate(ctx, id, null);
    }

    pub fn tensorLinearInfoIn(ctx: *EvalContext, id: u64, candidate: *Region) Error!TensorLinearInfo {
        return tensorLinearInfoWithCandidate(ctx, id, candidate);
    }
};

fn traceType(visitor: *skript.Store.MarkVisitor, object: skript.Object) anyerror!void {
    if (object != .null and @intFromEnum(object) > skript.builtins.type_last_idx) {
        try visitor.visitValue(Value.typeValue(object));
    }
}

fn traceTreeSpec(visitor: *skript.Store.MarkVisitor, spec: *const tree.TreeSpec) anyerror!void {
    for (spec.nodes) |node| {
        try traceType(visitor, node.runtime_type);
        try visitor.visitValue(node.original);
        if (node.kind == .custom) {
            try visitor.visitValue(node.kind.custom.namespace);
            try visitor.visitValue(node.kind.custom.metadata);
            try visitor.visitValue(node.kind.custom.unflatten_hook);
        }
    }
    for (spec.map_keys) |value| try visitor.visitValue(value);
    for (spec.leaves) |leaf| {
        try traceType(visitor, leaf.runtime_type);
        try visitor.visitValue(leaf.primal);
    }
}

fn traceLinearOps(visitor: *skript.Store.MarkVisitor, ops: space.LinearOps) anyerror!void {
    try traceType(visitor, ops.representation_type);
    try visitor.visitValue(ops.namespace);
    if (ops.native.context != null) return error.UntracedAllocation;
    if (ops.zero_hook) |value| try visitor.visitValue(value);
    if (ops.add_hook) |value| try visitor.visitValue(value);
    if (ops.scale_hook) |value| try visitor.visitValue(value);
    if (ops.check_hook) |value| try visitor.visitValue(value);
    if (ops.basis_hook) |value| try visitor.visitValue(value);
    if (ops.construct_hook) |value| try visitor.visitValue(value);
}

pub fn traceSpaceSpec(visitor: *skript.Store.MarkVisitor, spec: *const space.SpaceSpec) anyerror!void {
    try traceType(visitor, spec.primal_type);
    if (spec.tree_spec) |tree_spec| try traceTreeSpec(visitor, tree_spec);
    try traceLinearOps(visitor, spec.tangent);
    try traceLinearOps(visitor, spec.cotangent);
    try visitor.visitValue(spec.pairing.namespace);
    if (spec.pairing.hook) |value| try visitor.visitValue(value);
    if (spec.pairing.native) |native| {
        if (native.context != null) return error.UntracedAllocation;
    }
    switch (spec.metric) {
        .native => |native| {
            if (native.context != null) return error.UntracedAllocation;
        },
        .hook => |hook| {
            try visitor.visitValue(hook.namespace);
            try visitor.visitValue(hook.function);
        },
        else => {},
    }
}

fn traceRead(visitor: *skript.Store.MarkVisitor, read: effects.Read) anyerror!void {
    switch (read) {
        .cell => |cell| {
            try visitor.visitValue(cell.namespace);
            try visitor.visitValue(cell.snapshot.value);
        },
        .method => |method| try visitor.visitValue(method.value),
        .primitive => |primitive| switch (primitive.invoke) {
            .closure => |value| try visitor.visitValue(value),
            .native => {},
        },
    }
}

pub fn traceRegion(region: *const Region, visitor: *skript.Store.MarkVisitor) anyerror!void {
    const mutable_region = @constCast(region);
    mutable_region.acquire() catch |err| switch (err) {
        error.Expired => return,
        else => return err,
    };
    defer mutable_region.release();
    // The lease keeps arena storage alive if a host closes the Region during tracing.
    const storage = mutable_region.storage.load(.acquire) orelse return error.UntracedAllocation;
    if (region.inherited) |inherited| {
        const trace = inherited.trace orelse return error.UntracedAllocation;
        try visitor.visitGuard(trace, inherited.context);
    }
    for (region.expected_arguments) |value| try visitor.visitValue(value);
    for (region.argument_spaces) |*spec| try traceSpaceSpec(visitor, spec);
    for (region.space_reads.items) |read| try traceRead(visitor, read);
    for (region.space_hooks.items) |hook| {
        try visitor.visitValue(hook.value);
        for (hook.captures) |value| try visitor.visitValue(value);
    }
    for (region.space_values.items) |snapshot| {
        try visitor.visitValue(snapshot.value);
        try traceTreeSpec(visitor, &snapshot.structure);
    }
    var space_record = region.spaces.load(.acquire);
    var count: usize = 0;
    while (space_record) |record| : (space_record = record.next) {
        if (count == max_steps) return error.UntracedAllocation;
        count += 1;
        try traceSpaceSpec(visitor, &record.algebra);
    }
    var tensor_record = region.records;
    count = 0;
    while (tensor_record) |record| : (tensor_record = record.next) {
        if (count == max_steps) return error.UntracedAllocation;
        count += 1;
        try visitor.visitValue(record.kernel);
        for (record.inputs) |value| try visitor.visitValue(value);
        for (record.input_prototypes) |value| try visitor.visitValue(value);
        try visitor.visitValue(record.output);
        for (record.prefixes) |value| try visitor.visitValue(value);
        if (record.pullback.load(.acquire)) |pullback| try visitor.visitValue(pullback.*);
    }
    _ = storage;
}

pub fn tensorLinearInfo(ctx: *EvalContext, id: u64) Error!TensorLinearInfo {
    return Region.tensorLinearInfo(ctx, id);
}

pub const Result = struct {
    primal: Value,
    linear: Value,
    region: *Region,
};

fn checkRegion(runtime: *Runtime, state_data: *const anyopaque) Error!void {
    const region: *const Region = @ptrCast(@alignCast(state_data));
    if (runtime != region.runtime) return error.Denied;
    if (region.state.load(.acquire) != region_open) return error.Expired;
    try @constCast(region).acquire();
    defer @constCast(region).release();
    if (region.storage.load(.acquire) == null) return error.Expired;
    const ctx = runtime.context();
    try ctx.check();
    if (ctx.registry != region.registry or runtime.intrinsics.registryVersion() != region.registry) {
        return error.Denied;
    }
    if (runtime.tree_registry.current() != region.tree_version) return error.Unsupported;
    if (runtime.space_registry.current() != region.space_version) return error.Unsupported;
    if (!region.rules_version.validFor(region.registry)) return error.Denied;
    const owner = if (runtime.ad_rules) |*rule_owner| rule_owner else return error.Unsupported;
    try checkAlgebraDependencies(ctx, region);
    if (!owner.ownsCurrent(region.rules_version)) return error.Unsupported;
    if (region.inherited) |guard| try guard.check(runtime, guard.context);
}

fn checkRegionArguments(runtime: *Runtime, state_data: *const anyopaque, arguments: []const Value) Error!void {
    const region: *Region = @constCast(@as(*const Region, @ptrCast(@alignCast(state_data))));
    try checkRegion(runtime, state_data);
    try region.acquire();
    defer region.release();
    if (arguments.len != region.expected_arguments.len) return error.ArityMismatch;
    try runtime.context().chargeWork(@intCast(arguments.len), 1, .code);
    for (region.argument_spaces, arguments) |*algebra, actual| {
        try algebra.tangentCheck(runtime.context(), actual);
    }
}

fn acquireRegion(runtime: *Runtime, state_data: *const anyopaque) Error!void {
    const region: *Region = @constCast(@as(*const Region, @ptrCast(@alignCast(state_data))));
    if (runtime != region.runtime) return error.Denied;
    try region.acquire();
}

fn releaseRegion(runtime: *Runtime, state_data: *const anyopaque) void {
    const region: *Region = @constCast(@as(*const Region, @ptrCast(@alignCast(state_data))));
    std.debug.assert(runtime == region.runtime);
    region.release();
}

fn samePrototype(expected: Value, actual: Value, depth: usize) bool {
    if (depth >= max_value_depth or expected.typ != actual.typ) return false;
    if (expected.typ == b.type_tensor) {
        if (expected.obj == .null or actual.obj == .null) return false;
        const left = expected.obj.toRef().deref(tensor_intrin.TensorHolder);
        const right = actual.obj.toRef().deref(tensor_intrin.TensorHolder);
        return left.inner == right.inner and left.rank == right.rank and
            std.mem.eql(u32, left.shape, right.shape);
    }
    if (expected.typ == b.type_cons) {
        if (expected.obj == .null or actual.obj == .null) return false;
        const left = expected.obj.toRef().deref([2]Value);
        const right = actual.obj.toRef().deref([2]Value);
        return samePrototype(left[0], right[0], depth + 1) and
            samePrototype(left[1], right[1], depth + 1);
    }
    return true;
}

fn addTestParameter(
    builder: *Code.Builder,
    runtime: *Runtime,
    function: Code.FunctionId,
    name: []const u8,
) !Code.ValueId {
    const binding = try builder.addBinding(function, try runtime.store.getsym(name), .parameter, .{});
    const value = try builder.addValue(function);
    builder.bindings.items[@intFromEnum(binding)].value = value;
    try builder.addParameter(function, binding);
    return value;
}

fn materializeTestClosure(runtime: *Runtime, builder: *Code.Builder, function: Code.FunctionId) !Value {
    const code = try builder.finish(runtime.context().scratch);
    code.owner = runtime;
    const program = try runtime.lowerCode(runtime.context().scratch, code);
    const lowered = program.fns[@intFromEnum(function)];
    const reference = try runtime.store.create(Closure);
    runtime.store.store(Closure, reference.deref(Closure), .{
        .parent_ns = runtime.root_ns,
        .arglist = lowered.arglist,
        .source = lowered.source,
        .source_ref = lowered.source_ref,
        .ir = lowered.ir,
        .constants = lowered.constants,
        .nregs = lowered.nregs,
        .result_count = lowered.result_count,
        .zero_mask = lowered.zero_mask,
        .capture_syms = lowered.capture_syms,
        .captures = &.{},
        .code = code,
        .function_id = function,
        .fns = program.fns,
    });
    return .closure(reference.toObject());
}

var counted_primal_calls: usize = 0;

fn countedMultiply(_: *EvalContext, _: Value, _: Value, arguments: []const Value) Error!Value {
    if (arguments.len != 2) return error.ArityMismatch;
    if (arguments[0].typ != b.type_f64 or arguments[1].typ != b.type_f64) return error.TypeMismatch;
    counted_primal_calls += 1;
    return .f64(arguments[0].obj.tof64() * arguments[1].obj.tof64());
}

fn nonlinearLinearizePrimitive(_: *EvalContext, _: Value, _: Value, arguments: []const Value) Error!Value {
    if (arguments.len != 1) return error.ArityMismatch;
    if (arguments[0].typ != b.type_f64) return error.TypeMismatch;
    return arguments[0];
}

fn makeCountedSquare(runtime: *Runtime) !Value {
    var builder = Code.Builder.init(runtime.static, runtime.context());
    const identity = try runtime.allocCodeIdentity();
    builder.id = identity.id;
    builder.revision = identity.revision;
    const function = try builder.addFunction(null, .{});
    const block = try builder.addBlock(function);
    const argument = try addTestParameter(&builder, runtime, function, "x");
    const callee_value = Value.intrinsic(&countedMultiply);
    const callee = try builder.addNode(function, block, .{ .literal = callee_value }, .{});
    const result = try builder.addNode(function, block, .{ .arithmetic = .{
        .op = .mul,
        .left = argument,
        .right = argument,
        .callee = callee,
        .expected_callee = callee_value,
    } }, .{});
    try builder.setTerminator(block, .{ .return_values = try builder.addOperands(&.{result}) });
    return materializeTestClosure(runtime, &builder, function);
}

fn applyLinearOutputs(
    ctx: *EvalContext,
    callable: Value,
    argument: Value,
    outputs: []Value,
) !void {
    var workspace = Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    try workspace.apply(ctx, callable, &.{argument}, outputs);
}

fn applyLinear(ctx: *EvalContext, callable: Value, argument: Value) !Value {
    var output: [1]Value = undefined;
    try applyLinearOutputs(ctx, callable, argument, &output);
    return output[0].unwrapError();
}
fn failTangentZero(_: *EvalContext, _: skript.Object, _: ?*const anyopaque) Error!Value {
    return error.Unsupported;
}
var linear_guard_acquires: usize = 0;
var linear_guard_releases: usize = 0;

fn testLinearGuardCheck(_: *Runtime, _: *const anyopaque) Error!void {}

fn testLinearGuardArgumentsFail(
    _: *Runtime,
    _: *const anyopaque,
    _: []const Value,
) Error!void {
    return error.Unsupported;
}

fn testLinearGuardAcquire(_: *Runtime, _: *const anyopaque) Error!void {
    linear_guard_acquires += 1;
}

fn testLinearGuardRelease(_: *Runtime, _: *const anyopaque) void {
    linear_guard_releases += 1;
}

test "linear Region leases survive callback failure and budget exhaustion" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const source = try runtime.evalString("(fn (a b) (outer a b (fn (x y) (* x y))))");
    const left = try runtime.evalString("[1.0 2.0]");
    const right = try runtime.evalString("[3.0 4.0]");
    const result = try linearize(ctx, source, &.{ left, right });
    defer result.region.deinit();
    const record = result.region.records orelse return error.TestUnexpectedResult;
    const record_id = record.id;

    var info = try Region.tensorLinearInfoIn(ctx, record_id, result.region);
    defer info.deinit();
    try std.testing.expectEqual(@as(u32, 1), result.region.users.load(.acquire));
    const frozen = try tensorInput(info.inputs[0]);
    try std.testing.expectEqualSlices(
        u64,
        &.{ @bitCast(@as(f64, 1.0)), @bitCast(@as(f64, 2.0)) },
        frozen.data,
    );

    var failing_algebra = space.scalar(b.type_f64);
    failing_algebra.version = 1;
    failing_algebra.tangent.native.zero = &failTangentZero;
    try std.testing.expectError(
        error.Unsupported,
        result.region.tangentPrototype(ctx, &failing_algebra, Value.f64(1.0)),
    );
    try std.testing.expectEqual(@as(u32, 1), result.region.users.load(.acquire));

    var budget = EvalContext.Budget.init(runtime.io, 9_103, .{ .work = 100, .objects = 4 });
    var lease = try EvalContext.Budget.Lease.root(&budget, 0);
    var account = EvalContext.Budget.AccountAllocator.init(std.testing.allocator, &lease, .native);
    var output_bytes: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_bytes);
    var bounded = try EvalContext.limited(
        runtime,
        runtime.intrinsics.registryVersion(),
        &account,
        .{ .writer = &writer, .bounded_memory = true },
        .{},
    );
    try std.testing.expectError(
        error.Exhausted,
        result.region.addSpace(&bounded, space.scalar(b.type_f64)),
    );
    try std.testing.expectEqual(@as(u32, 1), result.region.users.load(.acquire));

    const retained_storage = result.region.storage.load(.acquire);
    try std.testing.expect(retained_storage != null);
    result.region.close();
    result.region.close();
    try std.testing.expectEqual(@as(u32, 1), result.region.users.load(.acquire));
    try std.testing.expectEqual(retained_storage, result.region.storage.load(.acquire));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 1.0))), frozen.data[0]);
    try std.testing.expectError(
        error.Expired,
        Region.tensorLinearInfoIn(ctx, record_id, result.region),
    );

    info.deinit();
    info.deinit();
    try std.testing.expectEqual(@as(u32, 0), result.region.users.load(.acquire));
    try std.testing.expectEqual(@as(?*Storage, null), result.region.storage.load(.acquire));
    try std.testing.expectError(
        error.Expired,
        Region.tensorLinearInfoIn(ctx, record_id, result.region),
    );
}

test "linearize rejects variadic functions before treating rest as fixed" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const source = try runtime.evalString("(fn (first . rest) first)");
    try std.testing.expectError(
        error.Unsupported,
        linearize(runtime.context(), source, &.{ Value.f64(1.0), Value.f64(2.0) }),
    );
}

test "failed linearization releases an acquired source callback" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const source = try runtime.evalString("(fn (x) x)");
    const closure = source.obj.toRef().deref(Closure);
    const guard = try runtime.static.create(ClosureGuard);
    guard.* = .{
        .context = &linear_guard_acquires,
        .check = &testLinearGuardCheck,
        .trace = null,
        .check_arguments = &testLinearGuardArgumentsFail,
        .acquire = &testLinearGuardAcquire,
        .release = &testLinearGuardRelease,
    };
    closure.guard = guard;
    linear_guard_acquires = 0;
    linear_guard_releases = 0;
    try std.testing.expectError(
        error.Unsupported,
        linearize(runtime.context(), source, &.{Value.f64(1.0)}),
    );
    try std.testing.expectEqual(@as(usize, 1), linear_guard_acquires);
    try std.testing.expectEqual(@as(usize, 1), linear_guard_releases);
}

test "collection skips reclaimed linear Region storage" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const source = try runtime.evalString("(fn (x) (* x x))");
    const result = try linearize(runtime.context(), source, &.{Value.f64(3.0)});
    defer result.region.deinit();
    var root: Runtime.ValueRoot = .{};
    try runtime.registerValueRoot(&root, result.linear);
    defer runtime.unregisterValueRoot(&root) catch unreachable;

    result.region.close();
    try runtime.collect();
    try std.testing.expectError(
        error.Expired,
        applyLinear(runtime.context(), result.linear, Value.f64(1.0)),
    );
}

test "linearization evaluates the primal exactly once" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const registry = try runtime.intrinsics.publish(&.{.{
        .stable_name = "linearize-test-counted-multiply",
        .invoke = Primitive.Invocation.nativePtr(&countedMultiply),
        .effects = .none,
        .reads_argument_state = false,
        .callbacks = .none,
        .resources = .{ .fixed = .{} },
        .suspension = .never,
    }});
    const ctx = runtime.context();
    ctx.registry = registry;
    const source = try makeCountedSquare(runtime);
    counted_primal_calls = 0;
    const result = try linearize(ctx, source, &.{Value.f64(3.0)});
    defer result.region.deinit();
    try std.testing.expectEqual(@as(usize, 1), counted_primal_calls);
    try std.testing.expectApproxEqAbs(@as(f64, 9.0), result.primal.obj.tof64(), 1e-12);
    try std.testing.expectApproxEqAbs(
        @as(f64, 6.0),
        (try applyLinear(ctx, result.linear, .f64(1.0))).obj.tof64(),
        1e-12,
    );
    try std.testing.expectEqual(@as(usize, 1), counted_primal_calls);
}

test "linearization rejects nonlinear custom JVP before publication" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const registry = try runtime.intrinsics.publish(&.{.{
        .stable_name = "linearize-test-nonlinear-jvp",
        .invoke = Primitive.Invocation.nativePtr(&nonlinearLinearizePrimitive),
        .effects = .none,
        .reads_argument_state = false,
        .callbacks = .none,
        .resources = .native,
        .suspension = .never,
    }});
    const ctx = runtime.context();
    ctx.registry = registry;
    try runtime.nsBind(
        runtime.root_ns,
        try runtime.store.getsym("linearize-test-nonlinear-jvp"),
        .intrinsic(&nonlinearLinearizePrimitive),
    );
    _ = try runtime.evalString(
        \\(register-ad-rule
        \\  :{:primitive linearize-test-nonlinear-jvp :implementation-revision 1 :rule-revision 1
        \\    :capabilities (list :jvp)
        \\    :metadata :{:arity 1 :linearity :linear :allocation :none :higher-order #t}
        \\    :jvp :{:kind :hook :revision 1
        \\      :callable (fn (primals tangents)
        \\        (list (fst primals) (* (fst tangents) (fst tangents))))}})
    );
    const source = try runtime.evalString("(fn (x) (linearize-test-nonlinear-jvp x))");
    try std.testing.expectError(error.Unsupported, linearize(ctx, source, &.{Value.f64(3.0)}));
}

test "linear and reverse transforms reject assignment closures before evaluation" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const source = try runtime.evalString(
        "(let ((calls 0)) (fn (x) (begin (set! calls (+ calls 1)) (+ x calls))))",
    );
    try std.testing.expectError(
        error.Unsupported,
        linearize(ctx, source, &.{Value.i64(10)}),
    );
    try std.testing.expectError(
        error.Unsupported,
        skript.autodiff_transpose.generate(
            ctx,
            source,
            &.{Value.i64(10)},
            &.{Value.i64(11)},
            null,
        ),
    );
    try std.testing.expectEqual(Value.i64(11), try applyLinear(ctx, source, .i64(10)));
}

test "pure reverse AD ignores sibling mutation in shared Code" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    try std.testing.expectEqual(Value.bool(true), try runtime.evalString(
        "(and (= (do ((a 0 (+ a 1)) (b 100 a)) ((= a 3) b)) 2) " ++
            "(= (hvp (fn (x) (* x x)) 3.0 4.0) 8.0))",
    ));
    try std.testing.expectEqual(Value.bool(true), try runtime.evalString(
        "(let ((calls 0)) (and " ++
            "(= ((fn () (begin (set! calls (+ calls 1)) calls))) 1) " ++
            "(= (hvp (fn (x) (* x x)) 3.0 4.0) 8.0)))",
    ));
}

test "linearization freezes the selected nonlinear branch" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const source = try runtime.evalString(
        "(fn (x) (if (< x 0.0) (* x x) (* x (* x x))))",
    );
    const negative = try linearize(ctx, source, &.{Value.f64(-2.0)});
    defer negative.region.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), negative.primal.obj.tof64(), 1e-12);
    try std.testing.expectApproxEqAbs(
        @as(f64, -4.0),
        (try applyLinear(ctx, negative.linear, .f64(1.0))).obj.tof64(),
        1e-12,
    );

    const positive = try linearize(ctx, source, &.{Value.f64(2.0)});
    defer positive.region.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), positive.primal.obj.tof64(), 1e-12);
    try std.testing.expectApproxEqAbs(
        @as(f64, 12.0),
        (try applyLinear(ctx, positive.linear, .f64(1.0))).obj.tof64(),
        1e-12,
    );
}

test "linear closure is reusable and expires when its Region closes" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const source = try runtime.evalString("(fn (x) (* x x))");
    const result = try linearize(ctx, source, &.{Value.i64(7)});
    defer result.region.deinit();
    try std.testing.expectEqual(Value.i64(14), try applyLinear(ctx, result.linear, .i64(1)));
    try std.testing.expectEqual(Value.i64(42), try applyLinear(ctx, result.linear, .i64(3)));
    result.region.close();
    try std.testing.expectError(error.Expired, applyLinear(ctx, result.linear, .i64(1)));
}

test "linearized structured constants return durable tangents and output errors retain origins" {
    const ErrorOrigin = struct {
        const Self = @This();
        line: Value,
        frame_line: Value,
        file: []const u8,
        function: []const u8,

        fn field(alist: Value, key: []const u8) !Value {
            var cursor = alist;
            while (!cursor.isNil()) {
                if (cursor.typ != b.type_cons) return error.TestUnexpectedResult;
                const cell = cursor.obj.toRef().deref([2]Value).*;
                if (cell[0].typ != b.type_cons) return error.TestUnexpectedResult;
                const entry = cell[0].obj.toRef().deref([2]Value).*;
                if (entry[0].typ != b.type_symbol) return error.TestUnexpectedResult;
                if (std.mem.eql(u8, entry[0].obj.toPtr(Sym).*, key)) return entry[1];
                cursor = cell[1];
            }
            return error.TestUnexpectedResult;
        }

        fn observe(ctx: *EvalContext, value: Value) !Self {
            const location = try skript.intrinsics.misc.errorLocation(ctx, .nil, .nil, &.{value});
            const trace = try skript.intrinsics.misc.errorTrace(ctx, .nil, .nil, &.{value});
            try std.testing.expectEqual(b.type_cons, location.typ);
            try std.testing.expectEqual(b.type_cons, trace.typ);
            const frame = trace.obj.toRef().deref([2]Value)[0];
            const line = try field(location, "line");
            const frame_line = try field(frame, "line");
            const file = try field(frame, "file");
            const function = try field(frame, "function");
            try std.testing.expectEqual(b.type_i64, line.typ);
            try std.testing.expectEqual(b.type_i64, frame_line.typ);
            try std.testing.expectEqual(b.type_string, file.typ);
            try std.testing.expectEqual(b.type_string, function.typ);
            return .{
                .line = line,
                .frame_line = frame_line,
                .file = std.mem.span(file.obj.toPtr([*:0]const u8)),
                .function = std.mem.span(function.obj.toPtr([*:0]const u8)),
            };
        }

        fn expectSame(expected: Self, actual: Self) !void {
            try std.testing.expectEqual(expected.line, actual.line);
            try std.testing.expectEqual(expected.frame_line, actual.frame_line);
            try std.testing.expectEqualStrings(expected.file, actual.file);
            try std.testing.expectEqualStrings(expected.function, actual.function);
        }
    };
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const source = try runtime.evalString("(fn (x) '(1.0 2.0))");
    const result = try linearize(ctx, source, &.{Value.f64(3.0)});
    defer result.region.deinit();

    const first = try applyLinear(ctx, result.linear, .f64(1.0));
    try std.testing.expectEqual(b.type_cons, first.typ);
    first.obj.toRef().deref([2]Value)[0] = .f64(9.0);

    const retained = try applyLinear(ctx, result.linear, .f64(2.0));
    const retained_first = retained.obj.toRef().deref([2]Value).*;
    try std.testing.expectEqual(Value.f64(0.0), retained_first[0]);
    try std.testing.expectEqual(b.type_cons, retained_first[1].typ);
    const retained_second = retained_first[1].obj.toRef().deref([2]Value).*;
    try std.testing.expectEqual(Value.f64(0.0), retained_second[0]);
    try std.testing.expectEqual(Value.nil, retained_second[1]);

    result.region.close();
    const escaped_first = retained.obj.toRef().deref([2]Value).*;
    try std.testing.expectEqual(Value.f64(0.0), escaped_first[0]);
    const escaped_second = escaped_first[1].obj.toRef().deref([2]Value).*;
    try std.testing.expectEqual(Value.f64(0.0), escaped_second[0]);
    try std.testing.expectEqual(Value.nil, escaped_second[1]);

    const definition = try skript.Reader.readUnit(
        runtime.store,
        "\n(defn (linearize-clone-leaf) (fst 42))",
        .{ .mode = .one, .file = "linearize-error.pt" },
    );
    _ = try runtime.evalDatumWithContext(ctx, definition.datum, null);
    const caught = try skript.Reader.readUnit(
        runtime.store,
        "\n(try (linearize-clone-leaf) (catch e e))",
        .{ .mode = .one, .file = "linearize-error.pt" },
    );
    const original_error = try runtime.evalDatumWithContext(ctx, caught.datum, null);
    try std.testing.expectEqual(b.type_error, original_error.typ);
    const original_origin = try ErrorOrigin.observe(ctx, original_error);
    try std.testing.expectEqual(Value.i64(2), original_origin.line);
    try std.testing.expect(original_origin.frame_line.obj.toInt(i64) > 0);
    try std.testing.expectEqualStrings("linearize-error.pt", original_origin.file);
    try std.testing.expectEqualStrings("linearize-clone-leaf", original_origin.function);

    const owned_error = try materializeOutput(ctx, .nil, .nil, &.{original_error});
    try ErrorOrigin.expectSame(original_origin, try ErrorOrigin.observe(ctx, owned_error));
}

test "linearized cons with nil tail preserves list shape" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const source = try runtime.evalString("(fn (x) (cons x nil))");
    const result = try linearize(ctx, source, &.{Value.f64(3.0)});
    defer result.region.deinit();

    const tangent = try applyLinear(ctx, result.linear, .f64(1.0));
    try std.testing.expectEqual(b.type_cons, tangent.typ);
    const pair = tangent.obj.toRef().deref([2]Value).*;
    try std.testing.expectEqual(Value.f64(1.0), pair[0]);
    try std.testing.expectEqual(Value.nil, pair[1]);
}

test "linearization snapshots captured tensor coefficients" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const captured_value = try runtime.evalString("[1.0 2.0]");
    const maker = try runtime.evalString("(fn (weights) (fn (x) (dot weights x)))");
    const source = try runtime.applyWithContext(ctx, runtime.root_ns, maker, &.{captured_value});
    const primal_argument = try runtime.evalString("[3.0 4.0]");
    const result = try linearize(ctx, source, &.{primal_argument});
    defer result.region.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 11.0), result.primal.obj.tof64(), 1e-12);

    const captured = captured_value.obj.toRef().deref(tensor_intrin.TensorHolder);
    captured.data[0] = @bitCast(@as(f64, 100.0));

    const seed = try runtime.evalString("[1.0 1.0]");
    const tangent = try applyLinear(ctx, result.linear, seed);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), tangent.obj.tof64(), 1e-12);
}

test "closing linear regions releases frozen tensor storage" {
    const runtime = try Runtime.initWithConfig(std.testing.allocator, std.testing.io, .{
        .max_heap_size = 16 * 1024 * 1024,
    });
    defer runtime.deinit();
    const count = 65_536;
    const data = try allocTensorBacking(u64, runtime.context(), count);
    @memset(data, @bitCast(@as(f64, 1.0)));
    const input = try makeTensorValue(runtime.context(), .f64, &.{count}, data);
    const source = try runtime.evalString("(fn (x) (dot x x))");
    const result = try linearize(runtime.context(), source, &.{input});
    defer result.region.deinit();
    try std.testing.expectEqual(Value.f64(count), result.primal);
    const retained = runtime.store.retainedBytes();
    result.region.close();
    const released = retained - runtime.store.retainedBytes();
    try std.testing.expect(released >= count * @sizeOf(u64));
}

test "expired linear code rejects further transforms" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const source = try runtime.evalString("(fn (x) (* x x))");
    const result = try linearize(ctx, source, &.{Value.f64(3.0)});
    result.region.close();
    try std.testing.expectError(error.Expired, linearize(ctx, result.linear, &.{Value.f64(1.0)}));
    try std.testing.expectError(error.Expired, skript.autodiff_transpose.generate(
        ctx,
        result.linear,
        &.{Value.f64(0.0)},
        &.{Value.f64(0.0)},
        null,
    ));
}

fn slotConcrete(slot: Slot) ?Value {
    return switch (slot) {
        .concrete => |value| value,
        else => null,
    };
}

const Slot = union(enum) {
    unset,
    concrete: Value,
    residual: Code.ValueId,
    tensor_pair: struct { primal: Value, tangent: Code.ValueId },
    tensor_tail: Code.ValueId,
    list_elements: []const Slot,
};
fn numericZero(value: Value) ?Value {
    return switch (value.typ) {
        b.type_i8 => .i8(0),
        b.type_i16 => .i16(0),
        b.type_i32 => .i32(0),
        b.type_i64 => .i64(0),
        b.type_u8 => .u8(0),
        b.type_u16 => .u16(0),
        b.type_u32 => .u32(0),
        b.type_u64 => .u64(0),
        b.type_f16 => .f16(0),
        b.type_f32 => .f32(0),
        b.type_f64 => .f64(0),
        else => null,
    };
}

fn zeroLikeValue(runtime: *Runtime, value: Value, depth: usize) Error!Value {
    if (depth >= max_value_depth) return error.Unsupported;
    if (numericZero(value)) |zero| return zero;
    if (value.typ == b.type_bool or value.typ == b.type_nil) {
        return if (value.typ == b.type_bool) .false else .nil;
    }
    if (value.typ == b.type_cons and value.obj != .null) {
        const pair = value.obj.toRef().deref([2]Value);
        const head = try zeroLikeValue(runtime, pair[0], depth + 1);
        const tail = try zeroLikeValue(runtime, pair[1], depth + 1);
        const ref = try runtime.store.create([2]Value);
        ref.deref([2]Value).* = .{ head, tail };
        return .cons(ref.toObject());
    }
    if (value.typ == b.type_tensor and value.obj != .null) {
        const source = value.obj.toRef().deref(tensor_intrin.TensorHolder);
        const shape = try runtime.store.allocSlice(u32, source.shape.len);
        errdefer runtime.store.discardUnpublished(shape.ref) catch unreachable;
        @memcpy(shape.slice, source.shape);
        const data = try runtime.store.allocSlice(u64, source.data.len);
        errdefer runtime.store.discardUnpublished(data.ref) catch unreachable;
        @memset(data.slice, switch (source.inner) {
            .i64 => @bitCast(@as(i64, 0)),
            .f64 => @bitCast(@as(f64, 0.0)),
            else => return error.Unsupported,
        });
        const ref = try runtime.store.createTraced(
            tensor_intrin.TensorHolder,
            tensor_intrin.traceTensorHolder,
        );
        ref.deref(tensor_intrin.TensorHolder).* = .{
            .inner = source.inner,
            .rank = source.rank,
            .shape = shape.slice,
            .data = data.slice,
            .shape_ref = shape.ref,
            .data_ref = data.ref,
        };
        return .init(b.type_tensor, ref.toObject());
    }
    return error.Unsupported;
}

fn cloneEscapedMap(ctx: *EvalContext, value: Value, depth: usize) Error!Value {
    if (value.typ != b.type_map or value.obj == .null) return error.TypeMismatch;
    var pairs: std.ArrayList(Value) = .empty;
    defer pairs.deinit(ctx.scratch);
    var cursor = try skript.intrinsics.map.keys(ctx, .nil, .nil, &.{value});
    while (!cursor.isNil()) {
        if (cursor.typ != b.type_cons or cursor.obj == .null) return error.TypeMismatch;
        const cell = cursor.obj.toRef().deref([2]Value).*;
        if (cell[0].typ != b.type_symbol and cell[0].typ != b.type_keyword) return error.TypeMismatch;
        try pairs.append(ctx.scratch, cell[0]);
        const item = try skript.intrinsics.map.get(ctx, .nil, .nil, &.{ value, cell[0] });
        try pairs.append(ctx.scratch, try cloneEscapedValue(ctx, item, depth + 1));
        cursor = cell[1];
    }
    return skript.intrinsics.map.create(ctx, .nil, .nil, pairs.items);
}
fn cloneEscapedCustom(ctx: *EvalContext, value: Value, depth: usize) Error!Value {
    if (depth >= max_value_depth) return error.Unsupported;
    var arena = Arena.init(ctx.scratch);
    defer arena.deinit();
    const allocator = arena.allocator();
    var spec = try tree.flatten(allocator, ctx, ctx.runtime.tree_registry.current(), value, tree.Limits.generic);
    defer spec.deinit();
    if (!spec.containsCustom()) return error.Unsupported;
    const leaves = try allocator.alloc(Value, spec.leaves.len);
    for (spec.leaves, leaves) |leaf, *copy| {
        copy.* = try cloneEscapedValue(ctx, leaf.primal, depth + 1);
    }
    for (spec.nodes) |*node| {
        switch (node.kind) {
            .custom => |*custom| {
                custom.metadata = try cloneEscapedValue(ctx, custom.metadata, depth + 1);
            },
            else => {},
        }
    }
    return spec.unflatten(ctx.scratch, ctx, leaves);
}

fn cloneEscapedValue(ctx: *EvalContext, value: Value, depth: usize) Error!Value {
    if (depth >= max_value_depth) return error.Unsupported;
    try ctx.chargeWork(1, 1, .native);
    if (value.typ == b.type_cons) {
        if (value.obj == .null) return error.TypeMismatch;
        const pair = value.obj.toRef().deref([2]Value).*;
        const head = try cloneEscapedValue(ctx, pair[0], depth + 1);
        const tail = try cloneEscapedValue(ctx, pair[1], depth + 1);
        const ref = try ctx.runtime.store.create([2]Value);
        ref.deref([2]Value).* = .{ head, tail };
        return .cons(ref.toObject());
    }
    if (value.typ == b.type_map) return cloneEscapedMap(ctx, value, depth);
    if (value.typ == b.type_tensor) {
        if (value.obj == .null) return error.TypeMismatch;
        const source = value.obj.toRef().deref(tensor_intrin.TensorHolder).*;
        if (source.rank == 0 or source.rank != source.shape.len) return error.TypeMismatch;
        var count: usize = 1;
        for (source.shape) |dimension| count = std.math.mul(usize, count, dimension) catch return error.Unsupported;
        if (count != source.data.len) return error.TypeMismatch;
        const size = std.math.add(usize, source.shape.len, source.data.len) catch return error.Unsupported;
        try ctx.chargeWork(@intCast(size), 1, .native);
        const shape = try ctx.runtime.store.allocSlice(u32, source.shape.len);
        errdefer ctx.runtime.store.discardUnpublished(shape.ref) catch unreachable;
        @memcpy(shape.slice, source.shape);
        const data = try ctx.runtime.store.allocSlice(u64, source.data.len);
        errdefer ctx.runtime.store.discardUnpublished(data.ref) catch unreachable;
        @memcpy(data.slice, source.data);
        const ref = try ctx.runtime.store.createTraced(
            tensor_intrin.TensorHolder,
            tensor_intrin.traceTensorHolder,
        );
        ref.deref(tensor_intrin.TensorHolder).* = .{
            .inner = source.inner,
            .rank = source.rank,
            .shape = shape.slice,
            .data = data.slice,
            .shape_ref = shape.ref,
            .data_ref = data.ref,
        };
        return .init(b.type_tensor, ref.toObject());
    }
    if (value.typ == b.type_c64) {
        if (value.obj == .null) return error.TypeMismatch;
        const ref = try ctx.runtime.store.create([2]f64);
        ref.deref([2]f64).* = value.obj.toRef().deref([2]f64).*;
        return .c64(ref.toObject());
    }
    if (value.typ == b.type_error) {
        if (!Value.errorPayloadIsRef(value.obj)) return value;
        const source = value.obj.toRef().deref(skript.data.ErrorObj).*;
        const ref = try ctx.runtime.store.create(skript.data.ErrorObj);
        const dst = ref.deref(skript.data.ErrorObj);
        dst.* = .{ .err = source.err, .site = .{
            .idx = source.site.idx,
            .line = source.site.line,
            .col = source.site.col,
        } };
        dst.site.source = try cloneEscapedValue(ctx, source.site.source, depth + 1);
        dst.site.file = try cloneEscapedValue(ctx, source.site.file, depth + 1);
        dst.raised = try cloneEscapedValue(ctx, source.raised, depth + 1);
        const frames = try ctx.runtime.store.allocSlice(skript.data.ErrorFrame, source.frames.len);
        dst.frames = frames.slice;
        for (source.frames, frames.slice) |from, *to| {
            to.* = .{ .site = .{
                .idx = from.site.idx,
                .line = from.site.line,
                .col = from.site.col,
            }, .name = from.name };
            to.site.source = try cloneEscapedValue(ctx, from.site.source, depth + 1);
            to.site.file = try cloneEscapedValue(ctx, from.site.file, depth + 1);
        }
        return .init(b.type_error, ref.toObject());
    }
    if (ctx.runtime.tree_registry.current().find(value.typ) != null) {
        return cloneEscapedCustom(ctx, value, depth);
    }
    return switch (value.typ) {
        b.type_namespace,
        b.type_opaque,
        b.type_pid,
        b.type_ffifunc,
        b.type_closure,
        b.type_method,
        b.type_ast,
        => error.Unsupported,
        b.type_symbol,
        b.type_keyword,
        b.type_string,
        b.type_intrinsic,
        b.type_expr,
        => if (value.obj == .null) error.TypeMismatch else value,
        b.type_type => if (@intFromEnum(value.obj) <= b.type_last_idx) value else error.Unsupported,
        else => if (@intFromEnum(value.typ) <= b.type_last_idx) value else error.Unsupported,
    };
}

pub fn materializeOutput(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    return cloneEscapedValue(ctx, args[0], 0);
}

fn sourceFunction(code: *const Code.Code, id: Code.FunctionId) Error!*const Code.Function {
    return code.function(id) orelse error.InvalidCode;
}

const Specializer = struct {
    ctx: *EvalContext,
    runtime: *Runtime,
    code: *const Code.Code,
    region: *Region,
    builder: *Code.Builder,
    function: Code.FunctionId,
    current_block: Code.BlockId,
    steps: usize = 0,
    depth: usize = 0,

    fn step(self: *Specializer) Error!void {
        if (self.steps >= max_steps) return error.Exhausted;
        try self.ctx.chargeWork(1, 1, .transform);
        self.steps += 1;
    }

    fn valueSlot(self: *Specializer, slots: []const Slot, value: Code.ValueId) Error!Slot {
        _ = self;
        const index = @intFromEnum(value);
        if (index >= slots.len) return error.InvalidCode;
        if (slots[index] == .unset) return error.InvalidCode;
        return slots[index];
    }

    fn setValue(self: *Specializer, slots: []Slot, value: Code.ValueId, slot: Slot) Error!void {
        _ = self;
        const index = @intFromEnum(value);
        if (index >= slots.len) return error.InvalidCode;
        slots[index] = slot;
    }

    fn ensureResidual(self: *Specializer, slot: Slot) Error!Code.ValueId {
        return switch (slot) {
            .residual => |value| value,
            .concrete => |value| self.builder.addNode(
                self.function,
                self.current_block,
                .{ .literal = try prototypeValue(self.ctx, self.region, value, 0) },
                .{},
            ),
            .list_elements => |elements| blk: {
                const list_primitive = self.ctx.registry.idForNative(
                    &skript.intrinsics.list.list,
                ) orelse return error.Unsupported;
                const operands = try self.ctx.scratch.alloc(Code.ValueId, elements.len);
                defer self.ctx.scratch.free(operands);
                for (elements, 0..) |element, index| {
                    operands[index] = try self.ensureResidual(element);
                }
                const range = try self.builder.addOperands(operands);
                break :blk try self.builder.addNode(
                    self.function,
                    self.current_block,
                    .{ .primitive_call = .{
                        .primitive = list_primitive,
                        .args = range,
                        .result_count = 1,
                    } },
                    .{},
                );
            },
            else => error.Unsupported,
        };
    }
    fn materializeConcreteClosure(
        self: *Specializer,
        closure_code: *const Code.Code,
        function: Code.FunctionId,
        parent: *const Closure,
        captures: []const Value,
    ) Error!Value {
        const index = @intFromEnum(function);
        if (parent.code != closure_code or index >= parent.fns.len) return error.InvalidCode;
        const lowered = parent.fns[index];
        if (lowered.code != closure_code or lowered.function != function) return error.InvalidCode;
        if (lowered.capture_syms.len != captures.len) return error.InvalidCode;
        const arguments = try self.runtime.store.allocSlice(Sym, lowered.arglist.len);
        @memcpy(arguments.slice, lowered.arglist);
        const copied = try self.runtime.store.allocSlice(Value, captures.len);
        @memcpy(copied.slice, captures);
        const ref = try self.runtime.store.create(Closure);
        self.runtime.store.store(Closure, ref.deref(Closure), .{
            .parent_ns = parent.parent_ns,
            .arglist = arguments.slice,
            .source = lowered.source,
            .source_ref = lowered.source_ref,
            .ir = lowered.ir,
            .constants = lowered.constants,
            .nregs = lowered.nregs,
            .result_count = lowered.result_count,
            .zero_mask = lowered.zero_mask,
            .capture_syms = lowered.capture_syms,
            .captures = copied.slice,
            .guard = if (parent.guard) |guard| try self.runtime.inheritClosureGuard(guard) else null,
            .code = closure_code,
            .function_id = function,
            .fns = parent.fns,
        });
        return .closure(ref.toObject());
    }

    fn invokeConcrete(self: *Specializer, callable: Value, args: []const Value) Error!Value {
        if (callable.typ != b.type_closure and callable.typ != b.type_intrinsic and
            callable.typ != b.type_method)
        {
            return error.Unsupported;
        }
        const namespace = if (callable.typ == b.type_closure)
            callable.obj.toRef().deref(Closure).parent_ns
        else
            self.runtime.root_ns;
        try effects.preflightCall(self.runtime, namespace, callable, args);
        const output = try self.runtime.applyWithContext(self.ctx, namespace, callable, args);
        if (output.typ == b.type_error) return output.errorCode();
        return output;
    }

    fn tensorOperation(raw: Value) Error!rules.BuiltinJvp {
        if (raw.typ != b.type_i64) return error.TypeMismatch;
        const value = raw.obj.toInt(i64);
        if (value < 0 or value > @as(i64, @intFromEnum(tensor_ad.Operation.scan))) {
            return error.TypeMismatch;
        }
        return switch (@as(tensor_ad.Operation, @enumFromInt(value))) {
            .stack => .stack,
            .tensor_get => .tensor_get,
            .reshape => .reshape,
            .transpose => .transpose,
            .dot => .dot,
            .map => .map,
            .map2 => .map2,
            .outer => .outer,
            .fold => .fold,
            .scan => .scan,
        };
    }

    fn tensorPair(value: Value) Error![2]Value {
        if (value.typ != b.type_cons or value.obj == .null) return error.TypeMismatch;
        const first = value.obj.toRef().deref([2]Value).*;
        if (first[1].typ != b.type_cons or first[1].obj == .null) return error.TypeMismatch;
        const second = first[1].obj.toRef().deref([2]Value).*;
        if (!Value.isNil(second[1])) return error.TypeMismatch;
        return .{ first[0], second[0] };
    }

    fn tensorProjection(
        self: *Specializer,
        primitive: Primitive.PrimitiveId,
        slots: []const Slot,
    ) Error!?Slot {
        const fst = self.ctx.registry.idForNative(&skript.intrinsics.list.fst) orelse return null;
        const rst = self.ctx.registry.idForNative(&skript.intrinsics.list.rst) orelse return null;
        if (primitive != fst and primitive != rst) return null;
        if (slots.len != 1) return error.ArityMismatch;
        return switch (slots[0]) {
            .tensor_pair => |pair| if (primitive == fst)
                .{ .concrete = pair.primal }
            else
                .{ .tensor_tail = pair.tangent },
            .tensor_tail => |tangent| if (primitive == fst)
                .{ .residual = tangent }
            else
                return error.Unsupported,
            else => null,
        };
    }

    fn emitNestedTensorPrimitive(self: *Specializer, slots: []const Slot) Error![]Slot {
        if (slots.len < 4) return error.ArityMismatch;
        const operation = try tensorOperation(slotConcrete(slots[0]) orelse return error.Unsupported);
        const kernel = slotConcrete(slots[1]) orelse return error.Unsupported;
        const raw_order = slotConcrete(slots[2]) orelse return error.Unsupported;
        const raw_lanes = slotConcrete(slots[3]) orelse return error.Unsupported;
        if (raw_order.typ != b.type_i64 or raw_lanes.typ != b.type_i64) return error.TypeMismatch;
        const order = std.math.cast(u8, raw_order.obj.toInt(i64)) orelse return error.Unsupported;
        if (order < 2 or order > tensor_ad.max_nested_order) return error.Unsupported;
        const lane_count = @as(usize, 1) << @intCast(order);
        if (raw_lanes.obj.toInt(i64) != lane_count) return error.ArityMismatch;
        if ((slots.len - 4) % lane_count != 0) return error.ArityMismatch;
        const payload_count = (slots.len - 4) / lane_count;
        const has_axis = switch (operation) {
            .map, .fold, .scan => blk: {
                if (payload_count != 1 and payload_count != 2) return error.ArityMismatch;
                break :blk payload_count == 2;
            },
            .map2, .outer => blk: {
                if (payload_count != 2) return error.ArityMismatch;
                break :blk false;
            },
            else => return error.Unsupported,
        };
        const arguments = try self.ctx.scratch.alloc(Value, slots.len);
        defer self.ctx.scratch.free(arguments);
        const input_count = (slots.len - 4) / 2;
        for (slots[0 .. 4 + input_count], arguments[0 .. 4 + input_count]) |slot, *value| {
            value.* = slotConcrete(slot) orelse return error.Unsupported;
        }
        for (slots[4 + input_count ..], arguments[4 + input_count ..], 0..) |slot, *value, index| {
            value.* = switch (slot) {
                .concrete => |concrete| concrete,
                .residual => try zeroLikeValue(self.runtime, arguments[4 + index % payload_count], 0),
                else => return error.Unsupported,
            };
            if (has_axis and index % payload_count == 1 and !value.isNil()) return error.Unsupported;
        }
        return self.emitNestedTensorRecord(operation, kernel, order, arguments, slots[4 + input_count ..]);
    }

    fn emitNestedTensorRecord(
        self: *Specializer,
        operation: rules.BuiltinJvp,
        kernel: Value,
        order: u8,
        arguments: []const Value,
        tangents: []const Slot,
    ) Error![]Slot {
        // The outermost JVP has already split the payload into concrete
        // coefficients and linear inputs. Do not differentiate these lanes again.
        const lane_count = @as(usize, 1) << @intCast(order);
        const primal_lane_count = lane_count / 2;
        const prefix_count = if (operation == .fold or operation == .scan)
            std.math.mul(
                usize,
                (try tensorInput(arguments[4])).data.len,
                primal_lane_count,
            ) catch return error.Unsupported
        else
            0;
        const prefixes = try self.ctx.scratch.alloc(Value, prefix_count);
        defer self.ctx.scratch.free(prefixes);
        var results: [tensor_ad.max_nested_lanes]Value = undefined;
        try tensor_ad.executeNested(
            self.ctx,
            @enumFromInt(arguments[0].obj.toInt(i64)),
            order,
            lane_count,
            arguments[4..],
            kernel,
            &results,
            if (operation == .fold or operation == .scan) prefixes else null,
        );
        const lanes = results[0..lane_count];
        const primals = arguments[4..][0..tangents.len];
        const prototypes = arguments[4 + tangents.len ..];
        const input_snapshots = try self.ctx.scratch.alloc(Value, primals.len);
        defer self.ctx.scratch.free(input_snapshots);
        for (primals, input_snapshots) |value, *snapshot| {
            snapshot.* = try prototypeValue(self.ctx, self.region, value, 0);
        }
        const output = try prototypeValue(
            self.ctx,
            self.region,
            try listFromValues(self.runtime, lanes[primal_lane_count..]),
            0,
        );
        const id = try self.region.addTensorRecord(
            self.ctx,
            operation,
            kernel,
            input_snapshots,
            prototypes,
            output,
            &.{},
            &.{},
            prefixes,
            order - 1,
        );
        const operands = try self.ctx.scratch.alloc(Code.ValueId, tangents.len + 1);
        defer self.ctx.scratch.free(operands);
        operands[0] = try self.builder.addNode(
            self.function,
            self.current_block,
            .{ .literal = .i64(@intCast(id)) },
            .{},
        );
        for (tangents, operands[1..]) |slot, *operand| operand.* = try self.ensureResidual(slot);
        const apply_primitive = self.ctx.registry.idForNative(&tensorLinearApply) orelse return error.Unsupported;
        var remaining = try self.builder.addNode(self.function, self.current_block, .{ .primitive_call = .{
            .primitive = apply_primitive,
            .args = try self.builder.addOperands(operands),
            .result_count = 1,
        } }, .{});
        const fst = self.ctx.registry.idForNative(&skript.intrinsics.list.fst) orelse return error.Unsupported;
        const rst = self.ctx.registry.idForNative(&skript.intrinsics.list.rst) orelse return error.Unsupported;
        const lane_slots = try self.ctx.scratch.alloc(Slot, lane_count);
        for (lane_slots[0..primal_lane_count], lanes[0..primal_lane_count]) |*slot, value| {
            slot.* = .{ .concrete = value };
        }
        for (lane_slots[primal_lane_count..], 0..) |*slot, lane| {
            slot.* = .{ .residual = try self.builder.addNode(self.function, self.current_block, .{ .primitive_call = .{
                .primitive = fst,
                .args = try self.builder.addOperands(&.{remaining}),
                .result_count = 1,
            } }, .{}) };
            if (lane + 1 < primal_lane_count) {
                remaining = try self.builder.addNode(self.function, self.current_block, .{ .primitive_call = .{
                    .primitive = rst,
                    .args = try self.builder.addOperands(&.{remaining}),
                    .result_count = 1,
                } }, .{});
            }
        }
        return self.ctx.scratch.dupe(Slot, &.{.{ .list_elements = lane_slots }});
    }
    fn emitResidualTensorView(self: *Specializer, operation: rules.BuiltinJvp, slots: []const Slot) Error!?[]Slot {
        const native: skript.FuncPtr = switch (operation) {
            .stack => &tensor_intrin.create,
            .tensor_get => &tensor_intrin.tensorGet,
            .reshape => &tensor_intrin.reshape,
            .transpose => &tensor_intrin.trans,
            else => return null,
        };
        const count = (slots.len - 2) / 2;
        var unknown_primal = false;
        for (slots[2..][0..count]) |slot| {
            if (slot != .concrete) unknown_primal = true;
        }
        if (!unknown_primal) return null;
        const primitive = self.ctx.registry.idForNative(native) orelse return error.Unsupported;
        const scalar = self.ctx.registry.idForNative(&rules.scalarDispatch) orelse return error.Unsupported;
        const inputs = try self.ctx.scratch.alloc(Slot, count);
        defer self.ctx.scratch.free(inputs);
        const pair = try self.ctx.scratch.alloc(Slot, 2);
        for (pair, 0..) |*output, component| {
            var all_zero = component == 1;
            for (inputs, 0..) |*input, index| {
                const control = operation != .stack and index != 0;
                const primal = slots[2 + index];
                const tangent = slots[2 + count + index];
                if (control) {
                    if (primal != .concrete or tangent != .concrete or !tangent.concrete.isNil()) {
                        return error.Unsupported;
                    }
                    input.* = primal;
                } else {
                    input.* = if (component == 0) primal else tangent;
                    if (input.* != .concrete or !input.concrete.isNil()) all_zero = false;
                }
            }
            if (all_zero) {
                output.* = .{ .concrete = .nil };
                continue;
            }
            if (component == 1) {
                for (inputs, 0..) |*input, index| {
                    if (input.* == .concrete and input.concrete.isNil()) {
                        const realized = try self.emitPrimitive(scalar, &.{
                            .{ .concrete = .i64(@intFromEnum(rules.ScalarOp.realize_tangent)) },
                            slots[2 + index],
                            input.*,
                        }, 1);
                        input.* = realized[0];
                    }
                }
            }
            const result = try self.emitPrimitive(primitive, inputs, 1);
            output.* = result[0];
        }
        const output = try self.ctx.scratch.dupe(Slot, &.{.{ .list_elements = pair }});
        return output;
    }

    fn emitTensorPrimitive(self: *Specializer, slots: []const Slot) Error![]Slot {
        if (slots.len < 2 or (slots.len - 2) % 2 != 0) return error.ArityMismatch;
        const operation = try tensorOperation(switch (slots[0]) {
            .concrete => |value| value,
            else => return error.Unsupported,
        });
        if (try self.emitResidualTensorView(operation, slots)) |result| return result;
        const count = (slots.len - 2) / 2;
        var arguments = try self.ctx.scratch.alloc(Value, slots.len);
        defer self.ctx.scratch.free(arguments);
        arguments[0] = switch (slots[0]) {
            .concrete => |value| value,
            else => return error.Unsupported,
        };
        arguments[1] = switch (slots[1]) {
            .concrete => |value| value,
            else => return error.Unsupported,
        };
        var primals = try self.ctx.scratch.alloc(Value, count);
        defer self.ctx.scratch.free(primals);
        var prototypes = try self.ctx.scratch.alloc(Value, count);
        defer self.ctx.scratch.free(prototypes);
        for (0..count) |index| {
            primals[index] = switch (slots[2 + index]) {
                .concrete => |value| value,
                else => return error.Unsupported,
            };
            prototypes[index] = switch (slots[2 + count + index]) {
                .concrete => |value| value,
                .residual => try zeroLikeValue(self.runtime, primals[index], 0),
                else => return error.Unsupported,
            };
            arguments[2 + index] = primals[index];
            arguments[2 + count + index] = switch (slots[2 + count + index]) {
                .concrete => |value| value,
                .residual => prototypes[index],
                else => return error.Unsupported,
            };
        }
        const recorded = switch (operation) {
            .map, .map2, .outer, .fold, .scan => try recordTensorKernel(
                self.ctx,
                operation,
                arguments[1],
                primals,
                prototypes,
            ),
            else => blk: {
                const primitive = self.ctx.registry.idForNative(&tensor_ad.dispatch) orelse return error.Unsupported;
                const pair = try tensorPair(try self.invokeConcrete(
                    try primitiveValue(self.ctx, primitive),
                    arguments,
                ));
                break :blk TensorResiduals{ .primal = pair[0], .coefficients = &.{} };
            },
        };
        defer self.ctx.scratch.free(recorded.coefficients);
        const output = try prototypeValue(self.ctx, self.region, recorded.primal, 0);
        const input_snapshots = try self.ctx.scratch.alloc(Value, count);
        defer self.ctx.scratch.free(input_snapshots);
        for (primals, 0..) |primal, index| {
            input_snapshots[index] = try prototypeValue(self.ctx, self.region, primal, 0);
        }
        const id = try self.region.addTensorRecord(
            self.ctx,
            operation,
            arguments[1],
            input_snapshots,
            prototypes,
            output,
            recorded.coefficients,
            &.{},
            &.{},
            0,
        );
        var operands = try self.ctx.scratch.alloc(Code.ValueId, count + 1);
        defer self.ctx.scratch.free(operands);
        operands[0] = try self.builder.addNode(
            self.function,
            self.current_block,
            .{ .literal = .i64(@intCast(id)) },
            .{},
        );
        for (0..count) |index| operands[index + 1] = try self.ensureResidual(switch (slots[2 + count + index]) {
            .concrete => |value| .{ .concrete = value },
            .residual => |value| .{ .residual = value },
            else => return error.Unsupported,
        });
        const apply_primitive = self.ctx.registry.idForNative(&tensorLinearApply) orelse return error.Unsupported;
        const tangent = try self.builder.addNode(self.function, self.current_block, .{ .primitive_call = .{
            .primitive = apply_primitive,
            .args = try self.builder.addOperands(operands),
            .result_count = 1,
        } }, .{});
        return self.ctx.scratch.dupe(Slot, &.{.{ .tensor_pair = .{ .primal = recorded.primal, .tangent = tangent } }});
    }

    fn listProjection(
        self: *Specializer,
        primitive: Primitive.PrimitiveId,
        slots: []const Slot,
        result_count: u8,
    ) Error!?[]Slot {
        const list_id = self.ctx.registry.idForNative(&skript.intrinsics.list.list);
        const cons_id = self.ctx.registry.idForNative(&skript.intrinsics.list.cons);
        const fst_id = self.ctx.registry.idForNative(&skript.intrinsics.list.fst);
        const rst_id = self.ctx.registry.idForNative(&skript.intrinsics.list.rst);
        const check_id = self.ctx.registry.idForNative(&rules.checkHookResult);
        if (self.ctx.registry.idForNative(&rules.scalarDispatch)) |id| {
            if (primitive == id and slots.len == 3 and slots[2] == .list_elements) {
                const operation = slotConcrete(slots[0]) orelse return error.Unsupported;
                if (operation.typ != b.type_i64) return error.TypeMismatch;
                const tag = operation.obj.toInt(i64);
                const coercion = tag == @intFromEnum(rules.ScalarOp.coerce_tangent) or
                    tag == @intFromEnum(rules.ScalarOp.realize_tangent);
                const aggregate = switch (slots[1]) {
                    .concrete => |prototype| tree.numericKind(prototype.typ) == null and
                        prototype.typ != b.type_c16 and prototype.typ != b.type_c32 and
                        prototype.typ != b.type_c64,
                    .list_elements, .tensor_pair, .tensor_tail => true,
                    else => false,
                };
                if (coercion and aggregate and slots[2].list_elements.len != 0) {
                    const output = try self.ctx.scratch.dupe(Slot, &.{slots[2]});
                    return output;
                }
            }
        }
        if (list_id) |id| if (primitive == id) {
            if (result_count != 1) return error.Unsupported;
            var all_leaf_concrete = true;
            for (slots) |slot| {
                if (slot != .concrete) {
                    all_leaf_concrete = false;
                    break;
                }
            }
            if (all_leaf_concrete) return null;
            const elements = try self.ctx.scratch.dupe(Slot, slots);
            const output = try self.ctx.scratch.dupe(Slot, &.{.{ .list_elements = elements }});
            return output;
        };
        if (cons_id) |id| if (primitive == id) {
            if (slots.len != 2 or result_count != 1) return error.ArityMismatch;
            var all_leaf_concrete = true;
            for (slots) |slot| {
                if (slot != .concrete) {
                    all_leaf_concrete = false;
                    break;
                }
            }
            if (all_leaf_concrete) return null;
            const elements = switch (slots[1]) {
                .concrete => |tail| blk: {
                    if (!tail.isNil()) return error.Unsupported;
                    break :blk try self.ctx.scratch.dupe(Slot, slots[0..1]);
                },
                .list_elements => |tail| blk: {
                    const flattened = try self.ctx.scratch.alloc(Slot, 1 + tail.len);
                    flattened[0] = slots[0];
                    @memcpy(flattened[1..], tail);
                    break :blk flattened;
                },
                else => return error.Unsupported,
            };
            const output = try self.ctx.scratch.dupe(Slot, &.{.{ .list_elements = elements }});
            return output;
        };
        if (fst_id) |id| if (primitive == id) {
            if (slots.len != 1 or result_count != 1) return error.ArityMismatch;
            if (slots[0] == .list_elements) {
                const elements = slots[0].list_elements;
                if (elements.len == 0) return error.Unsupported;
                const output = try self.ctx.scratch.dupe(Slot, &.{elements[0]});
                return output;
            }
            return null;
        };
        if (rst_id) |id| if (primitive == id) {
            if (slots.len != 1 or result_count != 1) return error.ArityMismatch;
            if (slots[0] == .list_elements) {
                const elements = slots[0].list_elements;
                if (elements.len == 0) return error.Unsupported;
                const rest = try self.ctx.scratch.dupe(Slot, elements[1..]);
                const output = try self.ctx.scratch.dupe(Slot, &.{.{ .list_elements = rest }});
                return output;
            }
            return null;
        };
        if (check_id) |id| if (primitive == id) {
            if (slots.len != 1 or result_count != 1) return error.ArityMismatch;
            if (slots[0] == .list_elements) {
                if (slots[0].list_elements.len != 2) return error.Unsupported;
                const output = try self.ctx.scratch.dupe(Slot, &.{slots[0]});
                return output;
            }
            return null;
        };
        return null;
    }

    fn concretePrimitive(
        self: *Specializer,
        primitive: Primitive.PrimitiveId,
        slots: []const Slot,
        result_count: u8,
    ) Error!?[]Slot {
        for (slots) |slot| if (slot != .concrete) return null;
        if (result_count != 1) return error.Unsupported;
        const arguments = try self.ctx.scratch.alloc(Value, slots.len);
        defer self.ctx.scratch.free(arguments);
        for (slots, arguments) |slot, *value| value.* = slot.concrete;
        const result = try self.invokeConcrete(try primitiveValue(self.ctx, primitive), arguments);
        const output = try self.ctx.scratch.dupe(Slot, &.{.{ .concrete = result }});
        return output;
    }

    fn emitPrimitive(
        self: *Specializer,
        primitive: Primitive.PrimitiveId,
        slots: []const Slot,
        result_count: u8,
    ) Error![]Slot {
        try self.step();
        if (try self.concretePrimitive(primitive, slots, result_count)) |result| return result;
        if (self.ctx.registry.idForNative(&tensor_ad.dispatchNested)) |tensor_primitive| {
            if (primitive == tensor_primitive) {
                if (result_count != 1) return error.Unsupported;
                return self.emitNestedTensorPrimitive(slots);
            }
        }
        if (self.ctx.registry.idForNative(&tensor_ad.dispatch)) |tensor_primitive| {
            if (primitive == tensor_primitive) {
                if (result_count != 1) return error.Unsupported;
                return self.emitTensorPrimitive(slots);
            }
        }
        if (try self.tensorProjection(primitive, slots)) |projection| {
            return self.ctx.scratch.dupe(Slot, &.{projection});
        }
        if (try self.listProjection(primitive, slots, result_count)) |projected| {
            return projected;
        }
        try pureSpec(self.ctx, primitive);
        var operands = try self.ctx.scratch.alloc(Code.ValueId, slots.len);
        defer self.ctx.scratch.free(operands);
        for (slots, 0..) |slot, index| operands[index] = try self.ensureResidual(slot);
        const range = try self.builder.addOperands(operands);
        const first = try self.builder.addNode(self.function, self.current_block, .{ .primitive_call = .{
            .primitive = primitive,
            .args = range,
            .result_count = result_count,
        } }, .{});
        const output = try self.ctx.scratch.alloc(Slot, result_count);
        for (output, 0..) |*slot, index| {
            slot.* = .{ .residual = @enumFromInt(@intFromEnum(first) + @as(u32, @intCast(index))) };
        }
        return output;
    }

    fn emitArithmetic(
        self: *Specializer,
        arithmetic: Code.Arithmetic,
        slots: []const Slot,
    ) Error!Slot {
        try self.step();
        const left = switch (slots[0]) {
            .concrete => |value| value,
            else => null,
        };
        const right = switch (slots[1]) {
            .concrete => |value| value,
            else => null,
        };
        if (left) |lhs| if (right) |rhs| {
            if (arithmetic.callee != .invalid) {
                return .{ .concrete = try self.invokeConcrete(arithmetic.expected_callee, &.{ lhs, rhs }) };
            }
            return .{ .concrete = try evaluateArithmetic(arithmetic.op, lhs, rhs) };
        };
        const left_value = try self.ensureResidual(slots[0]);
        const right_value = try self.ensureResidual(slots[1]);
        const callee = if (arithmetic.callee == .invalid) .invalid else try self.builder.addNode(
            self.function,
            self.current_block,
            .{ .literal = arithmetic.expected_callee },
            .{},
        );
        const result = try self.builder.addNode(self.function, self.current_block, .{ .arithmetic = .{
            .op = arithmetic.op,
            .left = left_value,
            .right = right_value,
            .callee = callee,
            .expected_callee = arithmetic.expected_callee,
        } }, .{});
        return .{ .residual = result };
    }

    fn executeNode(
        self: *Specializer,
        code: *const Code.Code,
        closure: *const Closure,
        function: Code.FunctionId,
        slots: []Slot,
        globals: []Slot,
        node: *const Code.Node,
    ) Error!void {
        try self.step();
        const result = node.result;
        const output: ?[]const Slot = switch (node.operation) {
            .literal => |value| &[_]Slot{.{ .concrete = value }},
            .quote => |value| &[_]Slot{.{ .concrete = value }},
            .local_read => |binding| blk: {
                const value = try bindingValue(code, function, binding);
                break :blk &[_]Slot{try self.valueSlot(slots, value)};
            },
            .global_read => |global| blk: {
                const index = @intFromEnum(global);
                if (index >= globals.len or index >= code.globals.len) return error.InvalidCode;
                if (globals[index] != .unset) break :blk &[_]Slot{globals[index]};
                const dependency = try self.runtime.readDependency(closure.parent_ns, code.globals[index].name);
                break :blk &[_]Slot{.{ .concrete = dependency.value }};
            },
            .global_write => |write| blk: {
                const index = @intFromEnum(write.cell);
                if (index >= globals.len) return error.InvalidCode;
                globals[index] = try self.valueSlot(slots, write.value);
                break :blk null;
            },
            .primitive_call => |call| blk: {
                const operands = try rangeValues(code, call.args);
                const inputs = try self.ctx.scratch.alloc(Slot, operands.len);
                defer self.ctx.scratch.free(inputs);
                for (operands, 0..) |operand, index| inputs[index] = try self.valueSlot(slots, operand);
                break :blk try self.emitPrimitive(call.primitive, inputs, call.result_count);
            },
            .arithmetic => |arithmetic| blk: {
                const left = try self.valueSlot(slots, arithmetic.left);
                const right = try self.valueSlot(slots, arithmetic.right);
                break :blk &[_]Slot{try self.emitArithmetic(arithmetic, &.{ left, right })};
            },
            .dynamic_call => |call| blk: {
                const callee = try self.valueSlot(slots, call.callee);
                const operands = try rangeValues(code, call.args);
                const inputs = try self.ctx.scratch.alloc(Slot, operands.len);
                defer self.ctx.scratch.free(inputs);
                for (operands, 0..) |operand, index| inputs[index] = try self.valueSlot(slots, operand);
                break :blk try self.dynamicCall(callee, inputs, call.result_count);
            },
            .direct_call => |call| blk: {
                const operands = try rangeValues(code, call.args);
                const inputs = try self.ctx.scratch.alloc(Slot, operands.len);
                defer self.ctx.scratch.free(inputs);
                for (operands, 0..) |operand, index| inputs[index] = try self.valueSlot(slots, operand);
                const captures = try self.captureSlots(code, function, slots, call.function);
                break :blk try self.evalFunction(code, closure, call.function, inputs, captures);
            },
            .make_closure => |make| blk: {
                const operands = try rangeValues(code, make.captures);
                const captures = try self.ctx.scratch.alloc(Value, operands.len);
                defer self.ctx.scratch.free(captures);
                for (operands, 0..) |operand, index| {
                    captures[index] = switch (try self.valueSlot(slots, operand)) {
                        .concrete => |value| value,
                        else => return error.Unsupported,
                    };
                }
                break :blk &[_]Slot{.{ .concrete = try self.materializeConcreteClosure(
                    code,
                    make.function,
                    closure,
                    captures,
                ) }};
            },
            .try_begin, .try_end, .ns_pop => null,
            .ns_push => return error.Unsupported,
        };
        if (output) |values| {
            if (result == .invalid or values.len == 0) return error.InvalidCode;
            for (values, 0..) |value, index| {
                const offset: u32 = @intCast(index);
                const target: Code.ValueId = @enumFromInt(
                    @intFromEnum(result) + offset,
                );
                try self.setValue(slots, target, value);
            }
        } else if (result != .invalid) {
            return error.InvalidCode;
        }
    }

    fn dynamicCall(self: *Specializer, callee: Slot, arguments: []const Slot, result_count: u8) Error![]Slot {
        const callable = switch (callee) {
            .concrete => |value| value,
            else => return error.Unsupported,
        };
        if (callable.typ == b.type_closure and callable.obj != .null) {
            if (self.depth >= max_call_depth) return error.Exhausted;
            const closure = callable.obj.toRef().deref(Closure);
            const code = closure.code orelse return error.Unsupported;
            if (code.owner != @as(?*const anyopaque, self.runtime)) return error.Denied;
            if (closure.guard) |guard| try guard.check(self.runtime, guard.context);
            try effects.preflight(self.runtime, closure.parent_ns, callable);
            const inputs = try self.ctx.scratch.alloc(Slot, arguments.len);
            defer self.ctx.scratch.free(inputs);
            @memcpy(inputs, arguments);
            const captures = try self.ctx.scratch.alloc(Slot, closure.captures.len);
            defer self.ctx.scratch.free(captures);
            for (closure.captures, 0..) |value, index| captures[index] = .{ .concrete = value };
            const output = try self.evalFunction(code, closure, closure.function_id, inputs, captures);
            if (output.len != result_count) return error.InvalidCode;
            return output;
        }
        var has_residual = false;
        for (arguments) |argument| {
            if (argument != .concrete) {
                has_residual = true;
                break;
            }
        }
        if (has_residual) {
            if (callable.typ != b.type_intrinsic or callable.obj == .null) return error.Unsupported;
            const primitive = self.ctx.registry.idForNative(
                callable.obj.toPtr(skript.FuncPtr),
            ) orelse return error.Unsupported;
            if (try self.listProjection(primitive, arguments, result_count)) |projected| {
                return projected;
            }
            return error.Unsupported;
        }
        const values = try self.ctx.scratch.alloc(Value, arguments.len);
        defer self.ctx.scratch.free(values);
        for (arguments, 0..) |argument, index| values[index] = switch (argument) {
            .concrete => |value| value,
            else => return error.InvalidCode,
        };
        const result = try self.invokeConcrete(callable, values);
        if (result_count != 1) return error.Unsupported;
        return self.ctx.scratch.dupe(Slot, &.{.{ .concrete = result }});
    }

    fn captureSlots(
        self: *Specializer,
        code: *const Code.Code,
        function: Code.FunctionId,
        slots: []Slot,
        target: Code.FunctionId,
    ) Error![]Slot {
        const info = try sourceFunction(code, target);
        const start: usize = info.capture_start;
        const end = std.math.add(usize, start, info.capture_count) catch return error.InvalidCode;
        if (end > code.captures.len) return error.InvalidCode;
        const captures = try self.ctx.scratch.alloc(Slot, info.capture_count);
        for (code.captures[start..end], 0..) |binding, index| {
            captures[index] = try self.valueSlot(slots, try bindingValue(code, function, binding));
        }
        return captures;
    }

    fn edge(
        self: *Specializer,
        code: *const Code.Code,
        closure: *const Closure,
        function: Code.FunctionId,
        slots: []Slot,
        globals: []Slot,
        edge_value: Code.Edge,
    ) Error![]Slot {
        const target = sourceBlock(code, edge_value.target) orelse return error.InvalidCode;
        const arguments = try rangeValues(code, edge_value.args);
        if (arguments.len != target.param_count) return error.InvalidCode;
        const start: usize = target.param_start;
        const end = std.math.add(usize, start, target.param_count) catch return error.InvalidCode;
        if (end > code.block_parameters.len) return error.InvalidCode;
        for (arguments, code.block_parameters[start..end]) |argument, parameter| {
            try self.setValue(slots, parameter, try self.valueSlot(slots, argument));
        }
        return self.block(code, closure, function, slots, globals, edge_value.target);
    }

    fn block(
        self: *Specializer,
        code: *const Code.Code,
        closure: *const Closure,
        function: Code.FunctionId,
        slots: []Slot,
        globals: []Slot,
        block_id: Code.BlockId,
    ) Error![]Slot {
        if (self.depth >= max_call_depth) return error.Exhausted;
        self.depth += 1;
        defer self.depth -= 1;
        const current = sourceBlock(code, block_id) orelse return error.InvalidCode;
        const start: usize = current.node_start;
        const end = std.math.add(usize, start, current.node_count) catch return error.InvalidCode;
        if (end > code.block_nodes.len) return error.InvalidCode;
        for (code.block_nodes[start..end]) |node_id| {
            const index = @intFromEnum(node_id);
            if (index >= code.nodes.len) return error.InvalidCode;
            try self.executeNode(code, closure, function, slots, globals, &code.nodes[index]);
        }
        return switch (current.terminator) {
            .return_values => |range| blk: {
                const values = try rangeValues(code, range);
                const output = try self.ctx.scratch.alloc(Slot, values.len);
                for (values, 0..) |value, index| output[index] = try self.valueSlot(slots, value);
                break :blk output;
            },
            .jump => |jump| try self.edge(code, closure, function, slots, globals, jump),
            .branch => |branch| blk: {
                const condition = try self.valueSlot(slots, branch.condition);
                const value = switch (condition) {
                    .concrete => |concrete| concrete,
                    else => return error.Unsupported,
                };
                break :blk if (Value.isTruthy(value))
                    try self.edge(code, closure, function, slots, globals, branch.then_edge)
                else
                    try self.edge(code, closure, function, slots, globals, branch.else_edge);
            },
            .tail_call => |call| blk: {
                const callee = try self.valueSlot(slots, call.callee);
                const values = try rangeValues(code, call.args);
                const arguments = try self.ctx.scratch.alloc(Slot, values.len);
                defer self.ctx.scratch.free(arguments);
                for (values, 0..) |value, index| arguments[index] = try self.valueSlot(slots, value);
                break :blk try self.dynamicCall(callee, arguments, call.result_count);
            },
            .raise, .none => error.Unsupported,
        };
    }

    fn evalFunction(
        self: *Specializer,
        code: *const Code.Code,
        closure: *const Closure,
        function: Code.FunctionId,
        arguments: []const Slot,
        captures: []const Slot,
    ) Error![]Slot {
        const info = try sourceFunction(code, function);
        if (info.has_rest) return error.Unsupported;
        if (arguments.len != info.parameter_count or captures.len != info.capture_count) return error.ArityMismatch;
        const slots = try self.ctx.scratch.alloc(Slot, code.values.len);
        defer self.ctx.scratch.free(slots);
        @memset(slots, .unset);
        const globals = try self.ctx.scratch.alloc(Slot, code.globals.len);
        defer self.ctx.scratch.free(globals);
        @memset(globals, .unset);
        const parameter_start: usize = info.parameter_start;
        const parameter_end = std.math.add(
            usize,
            parameter_start,
            info.parameter_count,
        ) catch return error.InvalidCode;
        if (parameter_end > code.parameters.len) return error.InvalidCode;
        for (code.parameters[parameter_start..parameter_end], arguments) |binding, argument| {
            try self.setValue(slots, try bindingValue(code, function, binding), argument);
        }
        const capture_start: usize = info.capture_start;
        const capture_end = std.math.add(
            usize,
            capture_start,
            info.capture_count,
        ) catch return error.InvalidCode;
        if (capture_end > code.capture_values.len) return error.InvalidCode;
        for (code.capture_values[capture_start..capture_end], captures) |value, capture| {
            try self.setValue(slots, value, capture);
        }
        const entry = sourceFunctionEntry(code, function) orelse return error.InvalidCode;
        return self.block(code, closure, function, slots, globals, entry);
    }
};
fn recordId(value: Value) Error!u64 {
    return switch (value.typ) {
        b.type_i64 => std.math.cast(u64, value.obj.toInt(i64)) orelse error.InvalidCode,
        b.type_u64 => value.obj.toInt(u64),
        else => error.TypeMismatch,
    };
}

fn listFromValues(runtime: *Runtime, values: []const Value) Error!Value {
    var result = Value.nil;
    var index = values.len;
    while (index > 0) {
        index -= 1;
        const cell = try runtime.store.create([2]Value);
        cell.deref([2]Value).* = .{ values[index], result };
        result = .cons(cell.toObject());
    }
    return result;
}

fn addScalarValues(left: Value, right: Value) Error!Value {
    if (left.typ == b.type_i64 and right.typ == b.type_i64) {
        const pair = @addWithOverflow(left.obj.toInt(i64), right.obj.toInt(i64));
        if (pair[1] != 0) return error.Unsupported;
        return .i64(pair[0]);
    }
    if (left.typ == b.type_f64 and right.typ == b.type_f64) {
        return .f64(left.obj.tof64() + right.obj.tof64());
    }
    return error.TypeMismatch;
}

fn addTensorValues(ctx: *EvalContext, left: Value, right: Value) Error!Value {
    if (left.typ != b.type_tensor or right.typ != b.type_tensor) return addScalarValues(left, right);
    return tensor_ad.addTangents(ctx, left, right);
}

fn scalarWord(inner: tensor_intrin.InnerType, value: Value) Error!u64 {
    return skript.autodiff_tree.tensorWord(inner, value);
}
fn wordAdd(inner: tensor_intrin.InnerType, left: u64, right: u64) Error!u64 {
    return switch (inner) {
        .i64 => blk: {
            const pair = @addWithOverflow(@as(i64, @bitCast(left)), @as(i64, @bitCast(right)));
            if (pair[1] != 0) return error.Unsupported;
            break :blk @bitCast(pair[0]);
        },
        .f64 => @bitCast(@as(f64, @bitCast(left)) + @as(f64, @bitCast(right))),
        else => error.Unsupported,
    };
}

fn wordMul(inner: tensor_intrin.InnerType, left: u64, right: u64) Error!u64 {
    return switch (inner) {
        .i64 => blk: {
            const pair = @mulWithOverflow(@as(i64, @bitCast(left)), @as(i64, @bitCast(right)));
            if (pair[1] != 0) return error.Unsupported;
            break :blk @bitCast(pair[0]);
        },
        .f64 => @bitCast(@as(f64, @bitCast(left)) * @as(f64, @bitCast(right))),
        else => error.Unsupported,
    };
}

const TensorResiduals = struct {
    primal: Value,
    coefficients: []u64,
};

const CoefficientKernel = struct {
    source: Value,
    compiled: [4]?Value = @splat(null),

    fn apply(
        self: *CoefficientKernel,
        ctx: *EvalContext,
        workspace: *Runtime.CallWorkspace,
        args: []const Value,
        outputs: []Value,
    ) Error!void {
        if (args.len == 0 or args.len > 2 or outputs.len != args.len + 1) return error.ArityMismatch;
        var signature: usize = 0;
        for (args, 0..) |arg, index| {
            if (arg.typ == b.type_f64) {
                signature |= @as(usize, 1) << @intCast(index);
            } else if (arg.typ != b.type_i64) return error.TypeMismatch;
        }
        const compiled = self.compiled[signature] orelse blk: {
            const generated = try skript.autodiff_transpose.generateCoefficients(
                ctx,
                self.source,
                args,
            );
            self.compiled[signature] = generated;
            break :blk generated;
        };
        try workspace.apply(ctx, compiled, args, outputs);
        for (outputs) |*output| output.* = try output.unwrapError();
    }
};

const TensorAxis = struct {
    axis: usize,
    length: usize,
    stride: usize,
    cells: usize,

    fn init(input: tensor_intrin.TensorHolder, arguments: []const Value) Error!TensorAxis {
        if (arguments.len == 0 or arguments.len > 2) return error.ArityMismatch;
        if (arguments.len == 2 and arguments[1].isNil()) return init(input, arguments[0..1]);
        const rank = input.shape.len;
        const axis: usize = if (arguments.len == 1) 0 else blk: {
            if (arguments[1].typ != b.type_i64) return error.TypeMismatch;
            const raw = arguments[1].obj.toInt(i64);
            const resolved = if (raw < 0)
                std.math.add(i64, @intCast(rank), raw) catch return error.Unsupported
            else
                raw;
            if (resolved < 0 or resolved >= rank) return error.Unsupported;
            break :blk @intCast(resolved);
        };
        var stride: usize = 1;
        var cells: usize = 1;
        for (input.shape, 0..) |dimension, index| {
            if (index > axis) stride = std.math.mul(usize, stride, dimension) catch return error.Unsupported;
            if (index != axis) cells = std.math.mul(usize, cells, dimension) catch return error.Unsupported;
        }
        return .{ .axis = axis, .length = input.shape[axis], .stride = stride, .cells = cells };
    }

    fn base(self: TensorAxis, cell: usize) usize {
        std.debug.assert(cell < self.cells);
        std.debug.assert(self.stride != 0);
        return (cell / self.stride) * self.stride * self.length + cell % self.stride;
    }
};

fn tensorInput(value: Value) Error!tensor_intrin.TensorHolder {
    if (value.typ != b.type_tensor or value.obj == .null) return error.TypeMismatch;
    const holder = value.obj.toRef().deref(tensor_intrin.TensorHolder).*;
    if (holder.rank == 0 or holder.rank != holder.shape.len) return error.TypeMismatch;
    var count: usize = 1;
    for (holder.shape) |dimension| count = std.math.mul(usize, count, dimension) catch return error.Unsupported;
    if (count != holder.data.len) return error.TypeMismatch;
    if (holder.inner != .i64 and holder.inner != .f64 and
        !(holder.inner == .empty and count == 0))
    {
        return error.Unsupported;
    }
    return holder;
}

fn scalarInner(value: Value) Error!tensor_intrin.InnerType {
    return switch (value.typ) {
        b.type_i64 => .i64,
        b.type_f64 => .f64,
        else => error.TypeMismatch,
    };
}

fn recordTensorKernel(
    ctx: *EvalContext,
    operation: rules.BuiltinJvp,
    source: Value,
    primals: []const Value,
    tangents: []const Value,
) Error!TensorResiduals {
    if (source.typ != b.type_closure) return error.TypeMismatch;
    try effects.preflight(ctx.runtime, source.obj.toRef().deref(Closure).parent_ns, source);
    if (primals.len != tangents.len) return error.ArityMismatch;
    if (operation == .map) {
        if (primals.len != 1 and primals.len != 2) return error.ArityMismatch;
        if (primals.len == 2 and !tangents[1].isNil()) return error.Unsupported;
    } else if (operation == .fold or operation == .scan) {
        if (primals.len == 2) {
            if (!tangents[1].isNil()) return error.Unsupported;
        } else if (primals.len != 1) return error.ArityMismatch;
    } else if (primals.len != 2) return error.ArityMismatch;
    return switch (operation) {
        .map => recordTensorMap(ctx, source, primals),
        .map2, .outer => recordTensorBinary(ctx, operation, source, primals),
        .fold, .scan => recordTensorFold(ctx, operation, source, primals),
        else => error.Unsupported,
    };
}

fn recordTensorMap(ctx: *EvalContext, source: Value, primals: []const Value) Error!TensorResiduals {
    const input = try tensorInput(primals[0]);
    const axis = try TensorAxis.init(input, primals);
    const data = try allocTensorBacking(u64, ctx, input.data.len);
    const coefficients = try ctx.scratch.alloc(u64, input.data.len);
    errdefer ctx.scratch.free(coefficients);
    var kernel: CoefficientKernel = .{ .source = source };
    var workspace = Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    var inner: ?tensor_intrin.InnerType = null;
    for (0..axis.cells) |cell| {
        if (axis.length == 0) continue;
        const base = axis.base(cell);
        for (0..axis.length) |offset| {
            const index = base + offset * axis.stride;
            var outputs: [2]Value = undefined;
            try kernel.apply(ctx, &workspace, &.{tensor_intrin.wordToValue(input.inner, input.data[index])}, &outputs);
            const actual_inner = try scalarInner(outputs[0]);
            if (inner) |expected| {
                if (actual_inner != expected) return error.TypeMismatch;
            }
            inner = actual_inner;
            data[index] = try scalarWord(actual_inner, outputs[0]);
            coefficients[index] = try scalarWord(actual_inner, outputs[1]);
        }
    }
    return .{
        .primal = try makeTensorValue(ctx, inner orelse input.inner, input.shape, data),
        .coefficients = coefficients,
    };
}

fn recordTensorBinary(
    ctx: *EvalContext,
    operation: rules.BuiltinJvp,
    source: Value,
    primals: []const Value,
) Error!TensorResiduals {
    const left = try tensorInput(primals[0]);
    const right = try tensorInput(primals[1]);
    const map2_layout = if (operation == .map2)
        try tensor_intrin.Map2Layout.init(left.shape, right.shape)
    else
        undefined;
    const count = if (operation == .outer)
        std.math.mul(usize, left.data.len, right.data.len) catch return error.Unsupported
    else if (operation == .map2)
        map2_layout.output_len
    else
        left.data.len;
    if (operation == .map2) {
        const rank_work = std.math.add(usize, left.shape.len, right.shape.len) catch return error.Unsupported;
        try ctx.chargeWork(
            std.math.cast(u64, rank_work) orelse return error.Unsupported,
            1,
            .native,
        );
        try ctx.chargeWork(
            std.math.cast(u64, count) orelse return error.Unsupported,
            1,
            .native,
        );
    }
    const data = try allocTensorBacking(u64, ctx, count);
    const coefficients = try ctx.scratch.alloc(u64, std.math.mul(usize, count, 2) catch return error.Unsupported);
    errdefer ctx.scratch.free(coefficients);
    var kernel: CoefficientKernel = .{ .source = source };
    var workspace = Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    var inner: ?tensor_intrin.InnerType = null;
    for (0..count) |index| {
        const indexes: [2]usize = if (operation == .outer)
            .{ index / right.data.len, index % right.data.len }
        else if (operation == .map2)
            map2_layout.inputIndices(index)
        else
            .{ index, index };
        const li = indexes[0];
        const ri = indexes[1];
        var outputs: [3]Value = undefined;
        try kernel.apply(ctx, &workspace, &.{
            tensor_intrin.wordToValue(left.inner, left.data[li]),
            tensor_intrin.wordToValue(right.inner, right.data[ri]),
        }, &outputs);
        const actual_inner = try scalarInner(outputs[0]);
        if (inner) |expected| {
            if (actual_inner != expected) return error.TypeMismatch;
        }
        inner = actual_inner;
        data[index] = try scalarWord(actual_inner, outputs[0]);
        coefficients[index * 2] = try scalarWord(actual_inner, outputs[1]);
        coefficients[index * 2 + 1] = try scalarWord(actual_inner, outputs[2]);
    }
    const shape: []const u32 = if (operation == .outer) blk: {
        const outer_shape = try ctx.scratch.alloc(u32, left.shape.len + right.shape.len);
        @memcpy(outer_shape[0..left.shape.len], left.shape);
        @memcpy(outer_shape[left.shape.len..], right.shape);
        break :blk outer_shape;
    } else if (operation == .map2)
        map2_layout.shapeSlice()
    else
        left.shape;
    defer if (operation == .outer) ctx.scratch.free(shape);
    return .{
        .primal = try makeTensorValue(ctx, inner orelse .empty, shape, data),
        .coefficients = coefficients,
    };
}

fn recordTensorFold(
    ctx: *EvalContext,
    operation: rules.BuiltinJvp,
    source: Value,
    primals: []const Value,
) Error!TensorResiduals {
    const input = try tensorInput(primals[0]);
    const axis = try TensorAxis.init(input, primals);
    if (axis.length == 0 and operation != .scan) return error.Unsupported;
    const scan = operation == .scan;
    const data = try allocTensorBacking(u64, ctx, if (scan) input.data.len else axis.cells);
    const coefficients = try ctx.scratch.alloc(
        u64,
        std.math.mul(usize, input.data.len, 2) catch return error.Unsupported,
    );
    errdefer ctx.scratch.free(coefficients);
    @memset(coefficients, 0);
    if (scan and input.data.len == 0) return .{
        .primal = try makeTensorValue(ctx, .empty, input.shape, data),
        .coefficients = coefficients,
    };
    try ctx.chargeWork(@intCast(input.data.len), 4, .native);
    var kernel: CoefficientKernel = .{ .source = source };
    var workspace = Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    var inner = input.inner;
    for (0..axis.cells) |cell| {
        const base = axis.base(cell);
        var accumulator = tensor_intrin.wordToValue(input.inner, input.data[base]);
        if (scan) data[base] = input.data[base];
        for (1..axis.length) |offset| {
            const index = base + offset * axis.stride;
            var outputs: [3]Value = undefined;
            try kernel.apply(
                ctx,
                &workspace,
                &.{ accumulator, tensor_intrin.wordToValue(input.inner, input.data[index]) },
                &outputs,
            );
            const result_inner = try scalarInner(outputs[0]);
            if (result_inner != inner) {
                if (scan or inner != .i64 or result_inner != .f64) return error.TypeMismatch;
                try ctx.chargeWork(@intCast(coefficients.len + cell), 1, .native);
                for (coefficients) |*word| word.* = @bitCast(@as(f64, @floatFromInt(@as(i64, @bitCast(word.*)))));
                for (data[0..cell]) |*word| word.* = @bitCast(@as(f64, @floatFromInt(@as(i64, @bitCast(word.*)))));
                inner = result_inner;
            }
            accumulator = outputs[0];
            coefficients[index * 2] = try scalarWord(inner, outputs[1]);
            coefficients[index * 2 + 1] = try scalarWord(inner, outputs[2]);
            if (scan) data[index] = try scalarWord(inner, accumulator);
        }
        if (!scan) data[cell] = try scalarWord(inner, accumulator);
    }
    if (!scan and input.rank == 1) {
        return .{
            .primal = tensor_intrin.wordToValue(inner, data[0]),
            .coefficients = coefficients,
        };
    }
    const shape = if (scan) input.shape else try ctx.scratch.alloc(u32, input.shape.len - 1);
    defer if (!scan) ctx.scratch.free(shape);
    if (!scan) {
        var index: usize = 0;
        for (input.shape, 0..) |dimension, coordinate| {
            if (coordinate == axis.axis) continue;
            shape[index] = dimension;
            index += 1;
        }
    }
    return .{ .primal = try makeTensorValue(ctx, inner, shape, data), .coefficients = coefficients };
}

fn allocTensorBacking(comptime T: type, ctx: *EvalContext, count: usize) Error![]T {
    return (try ctx.runtime.store.allocSlice(T, count)).slice;
}

fn dupeTensorBacking(comptime T: type, ctx: *EvalContext, source: []const T) Error![]T {
    const allocation = try ctx.runtime.store.allocSlice(T, source.len);
    @memcpy(allocation.slice, source);
    return allocation.slice;
}

fn makeTensorValue(ctx: *EvalContext, inner: tensor_intrin.InnerType, shape: []const u32, data: []u64) Error!Value {
    const shape_copy = try dupeTensorBacking(u32, ctx, shape);
    const ref = try ctx.runtime.store.createTraced(
        tensor_intrin.TensorHolder,
        tensor_intrin.traceTensorHolder,
    );
    ref.deref(tensor_intrin.TensorHolder).* = .{
        .inner = inner,
        .rank = @intCast(shape.len),
        .shape = shape_copy,
        .data = data,
    };
    return .tensor(ref.toObject());
}

fn tangentWordAt(value: Value, inner: tensor_intrin.InnerType, index: usize) Error!u64 {
    if (Value.isNil(value)) return 0;
    if (value.typ != b.type_tensor or value.obj == .null) return error.TypeMismatch;
    const holder = value.obj.toRef().deref(tensor_intrin.TensorHolder).*;
    if (index >= holder.data.len) return error.TypeMismatch;
    if (holder.inner == inner) return holder.data[index];
    return scalarWord(inner, tensor_intrin.wordToValue(holder.inner, holder.data[index]));
}

fn applyTensorMap(ctx: *EvalContext, record: *const TensorLinearRecord, tangents: []const Value) Error!Value {
    const output = record.output.obj.toRef().deref(tensor_intrin.TensorHolder).*;
    const data = try allocTensorBacking(u64, ctx, output.data.len);
    try ctx.chargeWork(@intCast(data.len), 6, .native);
    switch (record.operation) {
        .map => {
            if (tangents.len != 1 and tangents.len != 2) return error.ArityMismatch;
            for (data, 0..) |*item, index| {
                const tangent = try tangentWordAt(tangents[0], output.inner, index);
                item.* = try wordMul(output.inner, record.coefficients[index], tangent);
            }
        },
        .map2, .outer => {
            if (tangents.len != 2) return error.ArityMismatch;
            const map2_layout = if (record.operation == .map2) blk: {
                const left_input = try tensorInput(record.inputs[0]);
                const right_input = try tensorInput(record.inputs[1]);
                break :blk try tensor_intrin.Map2Layout.init(left_input.shape, right_input.shape);
            } else undefined;
            const right_len = if (record.operation == .outer)
                record.inputs[1].obj.toRef().deref(tensor_intrin.TensorHolder).data.len
            else
                0;
            for (data, 0..) |*item, index| {
                const indexes: [2]usize = if (record.operation == .outer)
                    .{ index / right_len, index % right_len }
                else if (record.operation == .map2)
                    map2_layout.inputIndices(index)
                else
                    .{ index, index };
                const left_index = indexes[0];
                const right_index = indexes[1];
                const left = try tangentWordAt(tangents[0], output.inner, left_index);
                const right = try tangentWordAt(tangents[1], output.inner, right_index);
                item.* = try wordAdd(
                    output.inner,
                    try wordMul(output.inner, record.coefficients[index * 2], left),
                    try wordMul(output.inner, record.coefficients[index * 2 + 1], right),
                );
            }
        },
        else => return error.Unsupported,
    }
    return makeTensorValue(ctx, output.inner, output.shape, data);
}

fn applyTensorFold(ctx: *EvalContext, record: *const TensorLinearRecord, tangent: Value) Error!Value {
    const input = try tensorInput(record.inputs[0]);
    const axis = try TensorAxis.init(input, record.inputs);
    const scan = record.operation == .scan;
    const inner = if (record.output.typ == b.type_tensor)
        record.output.obj.toRef().deref(tensor_intrin.TensorHolder).inner
    else
        try scalarInner(record.output);
    const data = try allocTensorBacking(u64, ctx, if (scan) input.data.len else axis.cells);
    try ctx.chargeWork(@intCast(input.data.len), 6, .native);
    for (0..axis.cells) |cell| {
        if (axis.length == 0) continue;
        const base = axis.base(cell);
        var accumulator = try tangentWordAt(tangent, inner, base);
        if (scan) data[base] = accumulator;
        for (1..axis.length) |offset| {
            const index = base + offset * axis.stride;
            const element = try tangentWordAt(tangent, inner, index);
            accumulator = try wordAdd(
                inner,
                try wordMul(inner, record.coefficients[index * 2], accumulator),
                try wordMul(inner, record.coefficients[index * 2 + 1], element),
            );
            if (scan) data[index] = accumulator;
        }
        if (!scan) data[cell] = accumulator;
    }
    if (!scan and input.rank == 1) return tensor_intrin.wordToValue(inner, data[0]);
    const output = record.output.obj.toRef().deref(tensor_intrin.TensorHolder);
    return makeTensorValue(ctx, inner, output.shape, data);
}

fn transposeTensorMap(ctx: *EvalContext, record: *const TensorLinearRecord, cotangent: Value) Error!Value {
    const output = try tensorInput(record.output);
    const cot = try tensorInput(cotangent);
    if (!std.mem.eql(u32, cot.shape, output.shape)) return error.TypeMismatch;
    try ctx.chargeWork(@intCast(cot.data.len), 6, .native);
    const left = try tensorInput(record.inputs[0]);
    const left_data = try allocTensorBacking(u64, ctx, left.data.len);
    if (record.operation == .map) {
        for (left_data, 0..) |*item, index| {
            const word = try wordMul(output.inner, record.coefficients[index], cot.data[index]);
            item.* = try scalarWord(left.inner, tensor_intrin.wordToValue(output.inner, word));
        }
        const results = [_]Value{ try makeTensorValue(ctx, left.inner, left.shape, left_data), .nil };
        return listFromValues(ctx.runtime, results[0..record.inputs.len]);
    }
    const right = try tensorInput(record.inputs[1]);
    const map2_layout = if (record.operation == .map2)
        try tensor_intrin.Map2Layout.init(left.shape, right.shape)
    else
        undefined;
    if (record.operation == .map2) {
        if (!std.mem.eql(u32, output.shape, map2_layout.shapeSlice())) return error.TypeMismatch;
    }
    const expected_count = if (record.operation == .outer)
        std.math.mul(usize, left.data.len, right.data.len) catch return error.Unsupported
    else if (record.operation == .map2)
        map2_layout.output_len
    else
        left.data.len;
    if (cot.data.len != expected_count) return error.TypeMismatch;
    const right_data = try allocTensorBacking(u64, ctx, right.data.len);
    @memset(left_data, 0);
    @memset(right_data, 0);
    for (cot.data, 0..) |value, index| {
        const indexes: [2]usize = if (record.operation == .outer)
            .{ index / right.data.len, index % right.data.len }
        else if (record.operation == .map2)
            map2_layout.inputIndices(index)
        else
            .{ index, index };
        const li = indexes[0];
        const ri = indexes[1];
        left_data[li] = try wordAdd(
            output.inner,
            left_data[li],
            try wordMul(output.inner, record.coefficients[index * 2], value),
        );
        right_data[ri] = try wordAdd(
            output.inner,
            right_data[ri],
            try wordMul(output.inner, record.coefficients[index * 2 + 1], value),
        );
    }
    if (output.inner != .empty) {
        for (left_data) |*word| {
            word.* = try scalarWord(left.inner, tensor_intrin.wordToValue(output.inner, word.*));
        }
        for (right_data) |*word| {
            word.* = try scalarWord(right.inner, tensor_intrin.wordToValue(output.inner, word.*));
        }
    }
    return listFromValues(ctx.runtime, &.{
        try makeTensorValue(ctx, left.inner, left.shape, left_data),
        try makeTensorValue(ctx, right.inner, right.shape, right_data),
    });
}

fn applyNestedTensor(
    ctx: *EvalContext,
    record: *const TensorLinearRecord,
    tangents: []const Value,
) Error!Value {
    if (record.nested_order == 0 or tangents.len != record.inputs.len) {
        return error.InvalidCode;
    }
    const next_order = std.math.add(u8, record.nested_order, 1) catch return error.Unsupported;
    if (next_order > tensor_ad.max_nested_order) return error.Unsupported;
    const lane_count = @as(usize, 1) << @intCast(record.nested_order);
    const next_lane_count = std.math.mul(usize, lane_count, 2) catch return error.Unsupported;
    const operation: tensor_ad.Operation = switch (record.operation) {
        .map => .map,
        .map2 => .map2,
        .outer => .outer,
        .fold => .fold,
        .scan => .scan,
        else => return error.Unsupported,
    };
    var arguments: [tensor_ad.max_nested_lanes * 2]Value = undefined;
    if (record.inputs.len > arguments.len / 2) return error.ArityMismatch;
    @memcpy(arguments[0..record.inputs.len], record.inputs);
    @memcpy(arguments[record.inputs.len..][0..tangents.len], tangents);
    var outputs: [tensor_ad.max_nested_lanes]Value = undefined;
    try tensor_ad.executeNested(
        ctx,
        operation,
        next_order,
        next_lane_count,
        arguments[0 .. record.inputs.len * 2],
        record.kernel,
        &outputs,
        null,
    );
    return listFromValues(ctx.runtime, outputs[lane_count..next_lane_count]);
}

pub fn tensorLinearApply(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try ctx.check();
    if (args.len < 1) return error.ArityMismatch;
    const record = try Region.findTensorRecord(ctx, try recordId(args[0]), null);
    defer record.region.release();
    if (args.len != record.inputs.len + 1) return error.ArityMismatch;
    for (args[1..], record.input_prototypes) |actual, expected| {
        if (!samePrototype(expected, actual, 0)) return error.TypeMismatch;
    }
    if (record.nested_order != 0) return applyNestedTensor(ctx, record, args[1..]);
    switch (record.operation) {
        .stack => {
            const tangents = try ctx.scratch.alloc(Value, record.inputs.len);
            defer ctx.scratch.free(tangents);
            for (args[1..], record.inputs, tangents) |value, primal, *tangent| {
                tangent.* = if (value.isNil()) try zeroLikeValue(ctx.runtime, primal, 0) else value;
            }
            return tensor_intrin.create(ctx, .nil, .nil, tangents);
        },
        .tensor_get => {
            var operands = try ctx.scratch.alloc(Value, record.inputs.len);
            defer ctx.scratch.free(operands);
            operands[0] = args[1];
            @memcpy(operands[1..], record.inputs[1..]);
            return tensor_intrin.tensorGet(ctx, .nil, .nil, operands);
        },
        .reshape => return tensor_intrin.reshape(ctx, .nil, .nil, &.{ args[1], record.inputs[1] }),
        .transpose => {
            var operands = try ctx.scratch.alloc(Value, record.inputs.len);
            defer ctx.scratch.free(operands);
            operands[0] = args[1];
            @memcpy(operands[1..], record.inputs[1..]);
            return tensor_intrin.trans(ctx, .nil, .nil, operands);
        },
        .dot => {
            if (record.inputs.len != 2) return error.ArityMismatch;
            if (args[1].isNil() and args[2].isNil()) return zeroLikeValue(ctx.runtime, record.output, 0);
            if (args[1].isNil()) return tensor_intrin.dot(ctx, .nil, .nil, &.{ record.inputs[0], args[2] });
            if (args[2].isNil()) return tensor_intrin.dot(ctx, .nil, .nil, &.{ args[1], record.inputs[1] });
            const left = try tensor_intrin.dot(ctx, .nil, .nil, &.{ args[1], record.inputs[1] });
            const right = try tensor_intrin.dot(ctx, .nil, .nil, &.{ record.inputs[0], args[2] });
            return addTensorValues(ctx, left, right);
        },
        .map, .map2, .outer => return applyTensorMap(ctx, record, args[1..]),
        .fold, .scan => return applyTensorFold(ctx, record, args[1]),
        else => return error.Unsupported,
    }
}

fn scaleTensor(ctx: *EvalContext, value: Value, scalar: Value) Error!Value {
    const source = value.obj.toRef().deref(tensor_intrin.TensorHolder).*;
    const factor = try scalarWord(source.inner, scalar);
    const data = try allocTensorBacking(u64, ctx, source.data.len);
    for (source.data, data) |word, *out| out.* = try wordMul(source.inner, word, factor);
    return makeTensorValue(ctx, source.inner, source.shape, data);
}

fn transposeTensorFold(ctx: *EvalContext, record: *const TensorLinearRecord, cotangent: Value) Error!Value {
    const input = try tensorInput(record.inputs[0]);
    const axis = try TensorAxis.init(input, record.inputs);
    const scan = record.operation == .scan;
    const inner = if (record.output.typ == b.type_tensor)
        record.output.obj.toRef().deref(tensor_intrin.TensorHolder).inner
    else
        try scalarInner(record.output);
    const data = try allocTensorBacking(u64, ctx, input.data.len);
    try ctx.chargeWork(@intCast(input.data.len), 7, .native);
    for (0..axis.cells) |cell| {
        if (axis.length == 0) continue;
        const base = axis.base(cell);
        const last = base + (axis.length - 1) * axis.stride;
        var accumulator = if (scan) try tangentWordAt(cotangent, inner, last) else if (input.rank == 1)
            try scalarWord(inner, cotangent)
        else
            try tangentWordAt(cotangent, inner, cell);
        var offset = axis.length - 1;
        while (offset > 0) : (offset -= 1) {
            const index = base + offset * axis.stride;
            const word = try wordMul(inner, record.coefficients[index * 2 + 1], accumulator);
            data[index] = try scalarWord(input.inner, tensor_intrin.wordToValue(inner, word));
            accumulator = try wordMul(inner, record.coefficients[index * 2], accumulator);
            if (scan) {
                accumulator = try wordAdd(
                    inner,
                    accumulator,
                    try tangentWordAt(cotangent, inner, index - axis.stride),
                );
            }
        }
        data[base] = try scalarWord(input.inner, tensor_intrin.wordToValue(inner, accumulator));
    }
    const results = [_]Value{ try makeTensorValue(ctx, input.inner, input.shape, data), .nil };
    return listFromValues(ctx.runtime, results[0..record.inputs.len]);
}

fn staticCotangentList(ctx: *EvalContext, record: *const TensorLinearRecord, first: Value) Error!Value {
    const values = try ctx.scratch.alloc(Value, record.inputs.len);
    defer ctx.scratch.free(values);
    @memset(values, .nil);
    if (values.len != 0) values[0] = first;
    return listFromValues(ctx.runtime, values);
}

fn transposeTensorStack(ctx: *EvalContext, record: *const TensorLinearRecord, cotangent: Value) Error!Value {
    const output = try tensorInput(cotangent);
    const values = try ctx.scratch.alloc(Value, record.inputs.len);
    defer ctx.scratch.free(values);
    var offset: usize = 0;
    for (record.inputs, record.input_prototypes, values) |input, prototype, *result| {
        if (input.typ == b.type_tensor) {
            const tensor = try tensorInput(input);
            const end = offset + tensor.data.len;
            if (end > output.data.len) return error.InvalidCode;
            result.* = if (prototype.isNil()) .nil else try makeTensorValue(
                ctx,
                tensor.inner,
                tensor.shape,
                try dupeTensorBacking(u64, ctx, output.data[offset..end]),
            );
            offset = end;
        } else {
            if (offset >= output.data.len) return error.InvalidCode;
            result.* = if (prototype.isNil()) .nil else tensor_intrin.wordToValue(output.inner, output.data[offset]);
            offset += 1;
        }
    }
    if (offset != output.data.len) return error.InvalidCode;
    return listFromValues(ctx.runtime, values);
}

fn transposeTensorGet(ctx: *EvalContext, record: *const TensorLinearRecord, cotangent: Value) Error!Value {
    const input = try tensorInput(record.inputs[0]);
    if (record.inputs.len != input.rank + 1) return error.ArityMismatch;
    var index: usize = 0;
    for (input.shape, record.inputs[1..]) |dimension, argument| {
        if (argument.typ != b.type_i64) return error.TypeMismatch;
        const coordinate = argument.obj.toInt(i64);
        if (coordinate < 0 or coordinate >= dimension) return error.Unsupported;
        index = index * dimension + @as(usize, @intCast(coordinate));
    }
    const data = try allocTensorBacking(u64, ctx, input.data.len);
    try ctx.chargeWork(@intCast(data.len), 1, .native);
    @memset(data, 0);
    if (index >= data.len) return error.Unsupported;
    data[index] = try scalarWord(input.inner, cotangent);
    return staticCotangentList(ctx, record, try makeTensorValue(ctx, input.inner, input.shape, data));
}

fn transposeTensorView(ctx: *EvalContext, record: *const TensorLinearRecord, cotangent: Value) Error!Value {
    const input = try tensorInput(record.inputs[0]);
    const output = try tensorInput(cotangent);
    const result = if (record.operation == .reshape) blk: {
        if (input.data.len != output.data.len) return error.TypeMismatch;
        const data = try dupeTensorBacking(u64, ctx, output.data);
        break :blk try makeTensorValue(ctx, output.inner, input.shape, data);
    } else if (record.inputs.len == 1)
        try tensor_intrin.trans(ctx, .nil, .nil, &.{cotangent})
    else blk: {
        const permutation = try tensorInput(record.inputs[1]);
        if (permutation.inner != .i64 or permutation.data.len != input.rank) return error.TypeMismatch;
        const inverse = try allocTensorBacking(u64, ctx, input.rank);
        for (permutation.data, 0..) |word, axis| {
            const old_axis: i64 = @bitCast(word);
            if (old_axis < 0 or old_axis >= input.rank) return error.Unsupported;
            inverse[@intCast(old_axis)] = @bitCast(@as(i64, @intCast(axis)));
        }
        const perm = try makeTensorValue(ctx, .i64, &.{input.rank}, inverse);
        break :blk try tensor_intrin.trans(ctx, .nil, .nil, &.{ cotangent, perm });
    };
    return staticCotangentList(ctx, record, result);
}

fn outerProduct(ctx: *EvalContext, left: Value, right: Value) Error!Value {
    const lhs = try tensorInput(left);
    const rhs = try tensorInput(right);
    if (lhs.rank != 1 or rhs.rank != 1 or lhs.inner != rhs.inner) return error.TypeMismatch;
    const count = std.math.mul(usize, lhs.data.len, rhs.data.len) catch return error.Unsupported;
    try ctx.chargeWork(@intCast(count), 2, .native);
    const data = try allocTensorBacking(u64, ctx, count);
    for (lhs.data, 0..) |a, row| {
        for (rhs.data, 0..) |bword, column| data[row * rhs.data.len + column] = try wordMul(lhs.inner, a, bword);
    }
    return makeTensorValue(ctx, lhs.inner, &.{ lhs.shape[0], rhs.shape[0] }, data);
}

fn transposeTensorDot(ctx: *EvalContext, record: *const TensorLinearRecord, cotangent: Value) Error!Value {
    if (record.inputs.len != 2) return error.ArityMismatch;
    const left = try tensorInput(record.inputs[0]);
    const right = try tensorInput(record.inputs[1]);
    if (left.rank > 2 or right.rank > 2) return error.Unsupported;
    var results = [_]Value{ .nil, .nil };
    if (!record.input_prototypes[0].isNil()) {
        results[0] = if (left.rank == 1 and right.rank == 1)
            try scaleTensor(ctx, record.inputs[1], cotangent)
        else if (left.rank == 2 and right.rank == 1)
            try outerProduct(ctx, cotangent, record.inputs[1])
        else if (left.rank == 1)
            try tensor_intrin.dot(ctx, .nil, .nil, &.{ record.inputs[1], cotangent })
        else
            try tensor_intrin.dot(
                ctx,
                .nil,
                .nil,
                &.{
                    cotangent,
                    try tensor_intrin.trans(ctx, .nil, .nil, &.{record.inputs[1]}),
                },
            );
    }
    if (!record.input_prototypes[1].isNil()) {
        results[1] = if (left.rank == 1 and right.rank == 1)
            try scaleTensor(ctx, record.inputs[0], cotangent)
        else if (left.rank == 1)
            try outerProduct(ctx, record.inputs[0], cotangent)
        else
            try tensor_intrin.dot(
                ctx,
                .nil,
                .nil,
                &.{
                    try tensor_intrin.trans(ctx, .nil, .nil, &.{record.inputs[0]}),
                    cotangent,
                },
            );
    }
    return listFromValues(ctx.runtime, &results);
}

fn nestedBitReverse(order: u8, index: usize) usize {
    var remaining = order;
    var source = index;
    var result: usize = 0;
    while (remaining > 0) : (remaining -= 1) {
        result = (result << 1) | (source & 1);
        source >>= 1;
    }
    return result;
}

fn nestedListLanes(
    ctx: *EvalContext,
    value: Value,
    count: usize,
) Error![]Value {
    const lanes = try ctx.scratch.alloc(Value, count);
    var cursor = value;
    for (lanes, 0..) |*lane, index| {
        if (cursor.typ != b.type_cons or cursor.obj == .null) return error.TypeMismatch;
        const cell = cursor.obj.toRef().deref([2]Value).*;
        lane.* = cell[0];
        cursor = cell[1];
        if (index + 1 == count and !Value.isNil(cursor)) return error.TypeMismatch;
    }
    return lanes;
}

fn nestedScalarAt(value: Value, index: usize) Error!Value {
    if (value.typ == b.type_i64 or value.typ == b.type_f64) return value;
    if (value.typ != b.type_tensor or value.obj == .null) {
        if (Value.isNil(value)) return .nil;
        return error.TypeMismatch;
    }
    const holder = try tensorInput(value);
    if (index >= holder.data.len) return error.TypeMismatch;
    return tensor_intrin.wordToValue(holder.inner, holder.data[index]);
}

fn nestedScalarPrototype(value: Value) Error!Value {
    return switch (value.typ) {
        b.type_i64 => .i64(0),
        b.type_f64 => .f64(0.0),
        b.type_tensor => if (value.obj == .null) error.TypeMismatch else blk: {
            const holder = value.obj.toRef().deref(tensor_intrin.TensorHolder);
            break :blk switch (holder.inner) {
                .i64 => .i64(0),
                .f64 => .f64(0.0),
                else => .i64(0),
            };
        },
        b.type_nil => .nil,
        else => error.TypeMismatch,
    };
}

fn nestedKernelPullback(
    ctx: *EvalContext,
    record: *const TensorLinearRecord,
    arity: usize,
    payload_count: usize,
) Error!Value {
    if (record.pullback.load(.acquire)) |cached| return cached.*;
    const lanes = @as(usize, 1) << @intCast(record.nested_order);
    const total_lanes = lanes * 2;
    var inputs: [tensor_ad.max_nested_lanes * 2]Value = undefined;
    for (0..total_lanes) |lane| {
        const values = if (lane < lanes) record.inputs else record.input_prototypes;
        for (0..arity) |operand| {
            const index = (lane % lanes) * payload_count + @min(operand, payload_count - 1);
            // Fold callbacks have an accumulator and an element from the same
            // tensor lane; binary elementwise callbacks have two tensor lanes.
            const source_index = if (record.operation == .fold or record.operation == .scan)
                (lane % lanes) * payload_count
            else
                index;
            inputs[lane * arity + operand] = try nestedScalarPrototype(values[source_index]);
        }
    }
    const outputs = try nestedListLanes(ctx, record.output, lanes);
    defer ctx.scratch.free(outputs);
    var output_prototypes: [tensor_ad.max_nested_lanes]Value = undefined;
    const numeric = try nestedScalarPrototype(outputs[0]);
    @memset(output_prototypes[0..total_lanes], numeric);
    const generated = try skript.autodiff_transpose.generatePartial(
        ctx,
        record.kernel,
        inputs[0 .. total_lanes * arity],
        output_prototypes[0..total_lanes],
        lanes * arity,
    );
    const storage = record.region.storage.load(.acquire) orelse return error.Expired;
    const slot = try skript.Store.createOwned(Value, storage.arena.allocator());
    const cached: *Value = slot.deref(Value);
    cached.* = generated;
    const published = @constCast(&record.pullback).cmpxchgStrong(null, cached, .acq_rel, .acquire);
    const selected = (published orelse null) orelse cached;
    return selected.*;
}

fn transposeNestedElementwise(
    ctx: *EvalContext,
    record: *const TensorLinearRecord,
    cotangent: Value,
) Error!Value {
    const order = record.nested_order;
    if (order == 0 or order >= tensor_ad.max_nested_order) return error.Unsupported;
    const lane_count = @as(usize, 1) << @intCast(order);
    const next_order = order + 1;
    const next_lane_count = lane_count * 2;
    if (record.inputs.len == 0 or record.inputs.len % lane_count != 0) return error.ArityMismatch;
    const payload_count = record.inputs.len / lane_count;
    const callback_arity: usize = switch (record.operation) {
        .map => 1,
        .map2, .outer => 2,
        else => return error.Unsupported,
    };
    if (payload_count != callback_arity and !(record.operation == .map and payload_count == 2)) {
        return error.ArityMismatch;
    }

    const cot_lanes = try nestedListLanes(ctx, cotangent, lane_count);
    defer ctx.scratch.free(cot_lanes);
    var input_offsets: [tensor_ad.max_nested_lanes * 2]usize = .{0} ** (tensor_ad.max_nested_lanes * 2);
    var input_lengths: [tensor_ad.max_nested_lanes * 2]usize = .{0} ** (tensor_ad.max_nested_lanes * 2);
    var input_inners: [tensor_ad.max_nested_lanes * 2]tensor_intrin.InnerType =
        .{.empty} ** (tensor_ad.max_nested_lanes * 2);
    var total: usize = 0;
    for (record.inputs, 0..) |input, input_index| {
        if (record.input_prototypes[input_index].isNil()) continue;
        if (input.typ == b.type_tensor) {
            const holder = try tensorInput(input);
            input_offsets[input_index] = total;
            input_lengths[input_index] = holder.data.len;
            input_inners[input_index] = holder.inner;
            total = std.math.add(usize, total, holder.data.len) catch return error.Unsupported;
        } else if (input.typ == b.type_i64) {
            input_inners[input_index] = .i64;
        } else if (input.typ == b.type_f64) {
            input_inners[input_index] = .f64;
        } else {
            return error.TypeMismatch;
        }
    }
    const accum_data = try allocTensorBacking(u64, ctx, total);
    @memset(accum_data, 0);
    var scalar_accum: [tensor_ad.max_nested_lanes * 2]u64 =
        .{0} ** (tensor_ad.max_nested_lanes * 2);
    const output_lanes = try nestedListLanes(ctx, record.output, lane_count);
    defer ctx.scratch.free(output_lanes);
    const output_prototype = try nestedScalarPrototype(output_lanes[0]);
    const pullback = try nestedKernelPullback(ctx, record, callback_arity, payload_count);
    const parameter_count = callback_arity * lane_count;
    const call_args = try ctx.scratch.alloc(Value, parameter_count);
    const pullback_args = try ctx.scratch.alloc(Value, parameter_count + next_lane_count);
    defer ctx.scratch.free(pullback_args);
    defer ctx.scratch.free(call_args);
    var call_outputs: [tensor_ad.max_nested_lanes * 2]Value = undefined;
    var raw_cotangents: [tensor_ad.max_nested_lanes]Value = undefined;
    var workspace = Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    const first_input = try tensorInput(record.inputs[0]);
    const second_input = if (record.operation == .outer or record.operation == .map2)
        try tensorInput(record.inputs[1])
    else
        first_input;
    const map2_layout = if (record.operation == .map2)
        try tensor_intrin.Map2Layout.init(first_input.shape, second_input.shape)
    else
        undefined;
    const element_count = if (record.operation == .outer)
        std.math.mul(usize, first_input.data.len, second_input.data.len) catch return error.Unsupported
    else if (record.operation == .map2)
        map2_layout.output_len
    else
        first_input.data.len;
    try ctx.chargeWork(@intCast(element_count), @intCast(parameter_count + lane_count), .native);
    for (0..element_count) |element| {
        const indexes: [2]usize = if (record.operation == .outer)
            .{ element / second_input.data.len, element % second_input.data.len }
        else if (record.operation == .map2)
            map2_layout.inputIndices(element)
        else
            .{ element, element };
        const left_index = indexes[0];
        const right_index = indexes[1];
        for (0..lane_count) |source_lane| {
            for (0..callback_arity) |operand| {
                const input_index = source_lane * payload_count + operand;
                const source_value = record.inputs[input_index];
                const source_index = if (operand == 1 and
                    (record.operation == .outer or record.operation == .map2))
                    right_index
                else
                    left_index;
                call_args[source_lane * callback_arity + operand] =
                    try nestedScalarAt(source_value, source_index);
            }
        }
        @memset(raw_cotangents[0..next_lane_count], output_prototype);
        for (0..lane_count) |lane| {
            const canonical = lane_count + lane;
            const raw = nestedBitReverse(next_order, canonical);
            const output_value = cot_lanes[lane];
            raw_cotangents[raw] = if (Value.isNil(output_value))
                output_prototype
            else
                try nestedScalarAt(output_value, element);
        }
        @memcpy(pullback_args[0..parameter_count], call_args);
        @memcpy(pullback_args[parameter_count..], raw_cotangents[0..next_lane_count]);
        try workspace.apply(
            ctx,
            pullback,
            pullback_args,
            call_outputs[0..parameter_count],
        );
        for (call_outputs[0..parameter_count]) |*output| output.* = try output.*.unwrapError();
        for (0..lane_count) |source_lane| {
            for (0..callback_arity) |operand| {
                const input_index = source_lane * payload_count + operand;
                if (record.input_prototypes[input_index].isNil()) continue;
                const parameter = source_lane * callback_arity + operand;
                const adjoint = call_outputs[parameter];
                if (Value.isNil(adjoint)) continue;
                const inner = input_inners[input_index];
                const word = try scalarWord(inner, adjoint);
                if (record.inputs[input_index].typ == b.type_tensor) {
                    const source_index = if (operand == 1 and
                        (record.operation == .outer or record.operation == .map2))
                        right_index
                    else
                        left_index;
                    const target = input_offsets[input_index] + source_index;
                    accum_data[target] = try wordAdd(inner, accum_data[target], word);
                } else {
                    scalar_accum[input_index] = try wordAdd(inner, scalar_accum[input_index], word);
                }
            }
        }
    }
    const values = try ctx.scratch.alloc(Value, record.inputs.len);
    defer ctx.scratch.free(values);
    @memset(values, .nil);
    for (record.inputs, 0..) |input, input_index| {
        if (record.input_prototypes[input_index].isNil()) continue;
        if (input.typ == b.type_tensor) {
            const holder = try tensorInput(input);
            const offset = input_offsets[input_index];
            values[input_index] = try makeTensorValue(
                ctx,
                holder.inner,
                holder.shape,
                accum_data[offset .. offset + input_lengths[input_index]],
            );
        } else if (input.typ == b.type_i64 or input.typ == b.type_f64) {
            values[input_index] = tensor_intrin.wordToValue(
                input_inners[input_index],
                scalar_accum[input_index],
            );
        }
    }
    return listFromValues(ctx.runtime, values);
}

fn nestedAddScalar(inner: tensor_intrin.InnerType, left: Value, right: Value) Error!Value {
    const left_word = if (Value.isNil(left)) 0 else try scalarWord(inner, left);
    const right_word = if (Value.isNil(right)) 0 else try scalarWord(inner, right);
    return tensor_intrin.wordToValue(inner, try wordAdd(inner, left_word, right_word));
}

const NestedFoldPullback = struct {
    ctx: *EvalContext,
    record: *const TensorLinearRecord,
    input: tensor_intrin.TensorHolder,
    axis: TensorAxis,
    lanes: usize,
    payload_count: usize,
    cotangents: []const Value,
    inner: tensor_intrin.InnerType,
    data: []u64,
    kernel: Value,
    workspace: Runtime.CallWorkspace,

    fn reverseCell(self: *NestedFoldPullback, cell: usize) Error!void {
        if (self.axis.length == 0) return;
        const scan = self.record.operation == .scan;
        const base = self.axis.base(cell);
        var accumulator: [tensor_ad.max_nested_lanes]Value = undefined;
        for (accumulator[0..self.lanes], self.cotangents) |*value, cot| {
            value.* = if (scan) tensor_intrin.wordToValue(self.inner, 0) else try nestedScalarAt(cot, cell);
        }
        var offset = self.axis.length;
        while (offset > 1) {
            offset -= 1;
            const index = base + offset * self.axis.stride;
            try self.ctx.chargeWork(@intCast(self.lanes), 4, .native);
            if (scan) {
                for (accumulator[0..self.lanes], self.cotangents) |*value, cot| {
                    value.* = try nestedAddScalar(self.inner, value.*, try nestedScalarAt(cot, index));
                }
            }
            var gradients: [tensor_ad.max_nested_lanes]Value = undefined;
            try self.reverseStep(index, accumulator[0..self.lanes], gradients[0 .. self.lanes * 2]);
            for (accumulator[0..self.lanes], 0..) |*value, lane| {
                value.* = gradients[lane * 2];
                self.data[lane * self.input.data.len + index] =
                    if (gradients[lane * 2 + 1].isNil())
                        0
                    else
                        try scalarWord(self.input.inner, gradients[lane * 2 + 1]);
            }
        }
        for (accumulator[0..self.lanes], self.cotangents, 0..) |value, cot, lane| {
            const result = if (scan)
                try nestedAddScalar(self.inner, value, try nestedScalarAt(cot, base))
            else
                value;
            self.data[lane * self.input.data.len + base] =
                if (result.isNil()) 0 else try scalarWord(self.input.inner, result);
        }
    }

    fn reverseStep(self: *NestedFoldPullback, index: usize, seeds: []const Value, outputs: []Value) Error!void {
        const parameters = self.lanes * 2;
        var arguments: [tensor_ad.max_nested_lanes * 2]Value = undefined;
        for (0..self.lanes) |lane| {
            arguments[lane * 2] = self.record.prefixes[index * self.lanes + lane];
            arguments[lane * 2 + 1] = try nestedScalarAt(self.record.inputs[lane * self.payload_count], index);
        }
        @memset(arguments[parameters .. parameters * 2], tensor_intrin.wordToValue(self.inner, 0));
        for (seeds, 0..) |seed, lane| {
            const raw = nestedBitReverse(self.record.nested_order + 1, self.lanes + lane);
            arguments[parameters + raw] = if (seed.isNil()) tensor_intrin.wordToValue(self.inner, 0) else seed;
        }
        try self.workspace.apply(self.ctx, self.kernel, arguments[0 .. parameters * 2], outputs);
        for (outputs) |*output| output.* = try output.unwrapError();
    }
};

fn transposeNestedFoldLike(
    ctx: *EvalContext,
    record: *const TensorLinearRecord,
    cotangent: Value,
) Error!Value {
    if (record.nested_order == 0 or record.nested_order >= tensor_ad.max_nested_order) return error.Unsupported;
    const lanes = @as(usize, 1) << @intCast(record.nested_order);
    if (record.inputs.len == 0 or record.inputs.len % lanes != 0) return error.ArityMismatch;
    const payload_count = record.inputs.len / lanes;
    if (payload_count != 1 and payload_count != 2) return error.ArityMismatch;
    const input = try tensorInput(record.inputs[0]);
    const axis = try TensorAxis.init(input, record.inputs[0..payload_count]);
    const count = std.math.mul(usize, input.data.len, lanes) catch return error.Unsupported;
    if (record.prefixes.len != count) return error.InvalidCode;
    const cots = try nestedListLanes(ctx, cotangent, lanes);
    defer ctx.scratch.free(cots);
    const data = try allocTensorBacking(u64, ctx, count);
    @memset(data, 0);
    var pullback: NestedFoldPullback = .{
        .ctx = ctx,
        .record = record,
        .input = input,
        .axis = axis,
        .lanes = lanes,
        .payload_count = payload_count,
        .cotangents = cots,
        .inner = try scalarInner(try nestedScalarPrototype(cots[0])),
        .data = data,
        .kernel = try nestedKernelPullback(ctx, record, 2, payload_count),
        .workspace = Runtime.CallWorkspace.init(ctx.scratch),
    };
    defer pullback.workspace.deinit();
    for (0..axis.cells) |cell| try pullback.reverseCell(cell);
    var results: [tensor_ad.max_nested_lanes]Value = undefined;
    @memset(results[0..record.inputs.len], .nil);
    for (0..lanes) |lane| {
        const index = lane * payload_count;
        if (record.input_prototypes[index].isNil()) continue;
        results[index] = try makeTensorValue(
            ctx,
            input.inner,
            input.shape,
            data[lane * input.data.len ..][0..input.data.len],
        );
    }
    return listFromValues(ctx.runtime, results[0..record.inputs.len]);
}

pub fn prepareTensorTranspose(ctx: *EvalContext, id: u64) Error!void {
    const record = try Region.findTensorRecord(ctx, id, null);
    defer record.region.release();
    if (record.nested_order == 0) return;
    const lanes = @as(usize, 1) << @intCast(record.nested_order);
    const arity: usize = switch (record.operation) {
        .map => 1,
        .map2, .outer, .fold, .scan => 2,
        else => return error.Unsupported,
    };
    const kernel = try nestedKernelPullback(ctx, record, arity, record.inputs.len / lanes);
    std.debug.assert(kernel.typ == b.type_closure);
}

pub fn tensorLinearTranspose(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try ctx.check();
    if (args.len != 2) return error.ArityMismatch;
    const record = try Region.findTensorRecord(ctx, try recordId(args[0]), null);
    defer record.region.release();
    if (!samePrototype(record.output, args[1], 0)) return error.TypeMismatch;
    if (record.nested_order != 0 and (record.operation == .fold or record.operation == .scan)) {
        return transposeNestedFoldLike(ctx, record, args[1]);
    }
    if (record.nested_order != 0) return transposeNestedElementwise(ctx, record, args[1]);
    return switch (record.operation) {
        .stack => transposeTensorStack(ctx, record, args[1]),
        .tensor_get => transposeTensorGet(ctx, record, args[1]),
        .reshape, .transpose => transposeTensorView(ctx, record, args[1]),
        .map, .map2, .outer => transposeTensorMap(ctx, record, args[1]),
        .fold, .scan => transposeTensorFold(ctx, record, args[1]),
        .dot => transposeTensorDot(ctx, record, args[1]),
        else => error.Unsupported,
    };
}

fn sourceBlock(code: *const Code.Code, id: Code.BlockId) ?*const Code.Block {
    const index = @intFromEnum(id);
    if (index >= code.blocks.len) return null;
    return &code.blocks[index];
}

fn sourceFunctionEntry(code: *const Code.Code, id: Code.FunctionId) ?Code.BlockId {
    const function = code.function(id) orelse return null;
    const start: usize = function.block_start;
    if (start >= code.function_blocks.len) return null;
    return code.function_blocks[start];
}
fn bindingValue(code: *const Code.Code, function: Code.FunctionId, binding: Code.BindingId) Error!Code.ValueId {
    const index = @intFromEnum(binding);
    if (index >= code.bindings.len) return error.InvalidCode;
    const definition = code.bindings[index];
    if (definition.function == function) return definition.value;
    const info = try sourceFunction(code, function);
    const start: usize = info.capture_start;
    const end = std.math.add(usize, start, info.capture_count) catch return error.InvalidCode;
    if (end > code.captures.len or end > code.capture_values.len) return error.InvalidCode;
    for (code.captures[start..end], code.capture_values[start..end]) |captured, value| {
        if (captured == binding) return value;
    }
    return error.InvalidCode;
}

fn rangeValues(code: *const Code.Code, range: Code.OperandRange) Error![]const Code.ValueId {
    const start: usize = range.start;
    const end = std.math.add(usize, start, range.len) catch return error.InvalidCode;
    if (end > code.operands.len) return error.InvalidCode;
    return code.operands[start..end];
}

fn primitiveValue(ctx: *EvalContext, primitive: Primitive.PrimitiveId) Error!Value {
    const spec = ctx.registry.spec(primitive) orelse return error.Unsupported;
    return switch (spec.invoke) {
        .native => |native| Value.intrinsic(native),
        .closure => |closure| closure,
    };
}

fn pureSpec(ctx: *EvalContext, primitive: Primitive.PrimitiveId) Error!void {
    const spec = ctx.registry.spec(primitive) orelse return error.Unsupported;
    try effects.requirePurePrimitive(spec);
    if (spec.callbacks != .none) return error.Unsupported;
}

fn evaluateArithmetic(op: Code.ArithOp, left: Value, right: Value) Error!Value {
    if (left.typ == b.type_f64 and right.typ == b.type_f64) {
        const lhs = left.obj.tof64();
        const rhs = right.obj.tof64();
        return switch (op) {
            .add => .f64(lhs + rhs),
            .sub => .f64(lhs - rhs),
            .mul => .f64(lhs * rhs),
            .div => .f64(lhs / rhs),
            .equal => .bool(lhs == rhs),
            .less => .bool(lhs < rhs),
            .greater => .bool(lhs > rhs),
        };
    }
    if (left.typ == b.type_i64 and right.typ == b.type_i64) {
        const lhs = left.obj.toInt(i64);
        const rhs = right.obj.toInt(i64);
        return switch (op) {
            .add => blk: {
                const pair = @addWithOverflow(lhs, rhs);
                if (pair[1] != 0) break :blk error.Unsupported;
                break :blk .i64(pair[0]);
            },
            .sub => blk: {
                const pair = @subWithOverflow(lhs, rhs);
                if (pair[1] != 0) break :blk error.Unsupported;
                break :blk .i64(pair[0]);
            },
            .mul => blk: {
                const pair = @mulWithOverflow(lhs, rhs);
                if (pair[1] != 0) break :blk error.Unsupported;
                break :blk .i64(pair[0]);
            },
            .div => if (rhs == 0 or (lhs == std.math.minInt(i64) and rhs == -1))
                error.Unsupported
            else
                .i64(@divTrunc(lhs, rhs)),
            .equal => .bool(lhs == rhs),
            .less => .bool(lhs < rhs),
            .greater => .bool(lhs > rhs),
        };
    }
    return error.TypeMismatch;
}

fn prototypeValue(parent: *EvalContext, region: *Region, value: Value, depth: usize) Error!Value {
    if (depth >= max_value_depth) return error.Unsupported;
    var ctx = try parent.enter(.transform);
    const scope = ctx.activate();
    defer scope.deinit();
    try ctx.chargeWork(1, 1, .transform);
    const storage = region.storage.load(.acquire) orelse return error.Expired;
    const allocator = storage.arena.allocator();
    if (value.typ == b.type_cons and value.obj != .null) {
        const pair = value.obj.toRef().deref([2]Value);
        const head = try prototypeValue(&ctx, region, pair[0], depth + 1);
        const tail = try prototypeValue(&ctx, region, pair[1], depth + 1);
        try ctx.charge(.{ .objects = 1 }, .transform);
        const ref = try skript.Store.createOwned([2]Value, allocator);
        ref.deref([2]Value).* = .{ head, tail };
        return .cons(ref.toObject());
    }
    if (value.typ == b.type_tensor and value.obj != .null) {
        const source = try tensorInput(value);
        try ctx.chargeWork(@intCast(source.data.len + source.shape.len), 1, .transform);
        try ctx.charge(.{ .objects = 1 }, .transform);
        const shape = try ctx.runtime.store.allocSlice(u32, source.shape.len);
        errdefer ctx.runtime.store.discardUnpublished(shape.ref) catch unreachable;
        @memcpy(shape.slice, source.shape);
        const data = try ctx.runtime.store.allocSlice(u64, source.data.len);
        errdefer ctx.runtime.store.discardUnpublished(data.ref) catch unreachable;
        @memcpy(data.slice, source.data);
        const ref = try ctx.runtime.store.createTraced(
            tensor_intrin.TensorHolder,
            tensor_intrin.traceTensorHolder,
        );
        ref.deref(tensor_intrin.TensorHolder).* = .{
            .inner = source.inner,
            .rank = source.rank,
            .shape = shape.slice,
            .data = data.slice,
            .shape_ref = shape.ref,
            .data_ref = data.ref,
        };
        return .init(b.type_tensor, ref.toObject());
    }
    if (value.typ == b.type_map) return materializeOutput(&ctx, .nil, .nil, &.{value});
    if (ctx.runtime.tree_registry.current().find(value.typ) != null) {
        return materializeOutput(&ctx, .nil, .nil, &.{value});
    }
    if (value.typ == b.type_closure or value.typ == b.type_method) {
        return error.Unsupported;
    }
    return value;
}

fn traceRegionGuard(context: *const anyopaque, visitor: *skript.Store.MarkVisitor) anyerror!void {
    const region: *const Region = @ptrCast(@alignCast(context));
    try traceRegion(region, visitor);
}

fn makeGuard(runtime: *Runtime, region: *Region) Error!*ClosureGuard {
    const guard = try runtime.static.create(ClosureGuard);
    guard.* = .{
        .context = region,
        .check = &checkRegion,
        .trace = &traceRegionGuard,
        .check_arguments = &checkRegionArguments,
        .acquire = &acquireRegion,
        .release = &releaseRegion,
    };
    return guard;
}

fn materializeLinear(
    ctx: *EvalContext,
    source: *const Closure,
    code: *const Code.Code,
    program: Runtime.RegProgram,
    function: Code.FunctionId,
    guard: *const ClosureGuard,
) Error!Value {
    const index = @intFromEnum(function);
    if (index >= program.fns.len) return error.InvalidCode;
    const lowered = program.fns[index];
    const arguments = try ctx.runtime.store.allocSlice(Sym, lowered.arglist.len);
    @memcpy(arguments.slice, lowered.arglist);
    const reference = try ctx.runtime.store.create(Closure);
    ctx.runtime.store.store(Closure, reference.deref(Closure), .{
        .parent_ns = source.parent_ns,
        .arglist = arguments.slice,
        .source = source.source,
        .source_ref = source.source_ref,
        .ir = lowered.ir,
        .constants = lowered.constants,
        .nregs = lowered.nregs,
        .result_count = lowered.result_count,
        .zero_mask = lowered.zero_mask,
        .capture_syms = lowered.capture_syms,
        .captures = &.{},
        .guard = guard,
        .code = code,
        .function_id = function,
        .environment_id = source.environment_id,
        .fns = program.fns,
    });
    return .closure(reference.toObject());
}

fn addTangentParameter(
    builder: *Code.Builder,
    runtime: *Runtime,
    function: Code.FunctionId,
    index: usize,
) Error!Code.ValueId {
    var name_buffer: [48]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buffer, "__linear_tangent_{d}", .{index}) catch return error.Unsupported;
    const binding = try builder.addBinding(function, try runtime.store.getsym(name), .parameter, .{});
    const value = try builder.addValue(function);
    builder.bindings.items[@intFromEnum(binding)].value = value;
    try builder.addParameter(function, binding);
    return value;
}

pub fn linearize(parent_ctx: *EvalContext, source: Value, primals: []const Value) Error!Result {
    var scratch_arena = Arena.init(parent_ctx.scratch);
    defer scratch_arena.deinit();
    var context = parent_ctx.*;
    context.scratch = scratch_arena.allocator();
    const ctx = &context;
    const scope = ctx.activate();
    defer scope.deinit();
    try ctx.check();
    if (source.typ != b.type_closure or source.obj == .null) return error.TypeMismatch;
    const source_closure = source.obj.toRef().deref(Closure);
    const source_guard = source_closure.guard;
    if (source_guard) |guard| {
        try guard.check(ctx.runtime, guard.context);
        if (guard.acquire) |acquire| try acquire(ctx.runtime, guard.context);
    }
    defer if (source_guard) |guard| {
        if (guard.release) |release| release(ctx.runtime, guard.context);
    };
    const source_code = source_closure.code orelse return error.Unsupported;
    if (source_code.owner != @as(?*const anyopaque, ctx.runtime)) return error.Denied;
    const source_function = try sourceFunction(source_code, source_closure.function_id);
    if (source_function.has_rest) return error.Unsupported;
    if (source_function.result_count != 1 or source_closure.result_count != 1) return error.Unsupported;
    if (!source_function.allows_ad) return error.Unsupported;
    if (primals.len != source_function.parameter_count) return error.ArityMismatch;
    if (source_closure.guard) |guard| {
        try guard.check(ctx.runtime, guard.context);
        if (guard.check_arguments) |check| try check(ctx.runtime, guard.context, primals);
    }
    if (ctx.registry != ctx.runtime.intrinsics.registryVersion()) return error.Denied;
    const rule_version = try rules.builtinSnapshot(ctx);
    const scalar_primitive = ctx.registry.idForNative(&rules.scalarDispatch) orelse return error.Unsupported;
    if (rule_version.find(scalar_primitive) == null) return error.Unsupported;
    const specialized = try callables.bind(ctx, source, primals);
    try effects.preflight(ctx.runtime, source_closure.parent_ns, specialized);

    const generated = try forward.generate(ctx, specialized, 0, .full_jvp);
    if (generated.typ != b.type_closure or generated.obj == .null) return error.InvalidCode;
    const generated_closure = generated.obj.toRef().deref(Closure);
    const generated_code = generated_closure.code orelse return error.InvalidCode;
    const generated_function = try sourceFunction(generated_code, generated_closure.function_id);
    if (generated_function.parameter_count != primals.len * 2 or generated_function.result_count != 2) {
        return error.InvalidCode;
    }

    const region = try ctx.runtime.static.create(Region);
    const storage = try ctx.runtime.linearization_state.createStorage(ctx);
    region.* = .{
        .runtime = ctx.runtime,
        .owner = &ctx.runtime.linearization_state,
        .storage = .init(storage),
        .tree_version = ctx.runtime.tree_registry.current(),
        .space_version = ctx.runtime.space_registry.current(),
        .registry = ctx.registry,
        .inherited = generated_closure.guard,
        .rules_version = rule_version,
        .expected_arguments = &.{},
    };
    errdefer region.close();
    const expected = try storage.arena.allocator().alloc(Value, primals.len);
    const argument_spaces = try storage.arena.allocator().alloc(space.SpaceSpec, primals.len);
    for (primals, argument_spaces, expected) |primal, *algebra, *prototype| {
        const vector_primal = if (callables.isStatic(ctx, primal)) Value.nil else primal;
        algebra.* = try region.resolveSpace(ctx, vector_primal);
        prototype.* = try region.tangentPrototype(ctx, algebra, vector_primal);
    }
    region.argument_spaces = argument_spaces;
    region.expected_arguments = expected;

    var builder = Code.Builder.init(ctx.runtime.static, ctx);
    const identity = try ctx.runtime.allocCodeIdentity();
    builder.id = identity.id;
    builder.revision = identity.revision;
    const module = try builder.addFunction(null, .{});
    builder.functions.items[@intFromEnum(module)].module_entry = true;
    builder.functions.items[@intFromEnum(module)].result_count = 1;
    const callable = try builder.addFunction(source_function.name, source_function.source);
    const callable_info = &builder.functions.items[@intFromEnum(callable)];
    callable_info.result_count = 1;
    callable_info.ad_level = std.math.add(u16, source_function.ad_level, 1) catch return error.Unsupported;
    callable_info.allows_ad = source_function.allows_ad;
    callable_info.origin = .{ .code = source_code, .function = source_closure.function_id };
    callable_info.source_value = source_function.source_value;
    callable_info.arglist = source_function.arglist;
    callable_info.body = source_function.body;
    const module_block = try builder.addBlock(module);
    const callable_block = try builder.addBlock(callable);
    const tangent_args = try ctx.scratch.alloc(Code.ValueId, primals.len);
    defer ctx.scratch.free(tangent_args);
    for (tangent_args, 0..) |*argument, index| {
        argument.* = try addTangentParameter(&builder, ctx.runtime, callable, index);
    }
    const closure_node = try builder.addNode(module, module_block, .{ .make_closure = .{
        .function = callable,
        .captures = .{},
    } }, .{});
    try builder.setTerminator(module_block, .{ .return_values = try builder.addOperands(&.{closure_node}) });

    const arguments = try ctx.scratch.alloc(Slot, generated_function.parameter_count);
    defer ctx.scratch.free(arguments);
    for (0..primals.len) |index| arguments[index] = .{ .concrete = primals[index] };
    for (0..primals.len) |index| arguments[primals.len + index] = .{ .residual = tangent_args[index] };
    const captures = try ctx.scratch.alloc(Slot, generated_closure.captures.len);
    defer ctx.scratch.free(captures);
    for (generated_closure.captures, 0..) |capture, index| captures[index] = .{ .concrete = capture };
    var specializer: Specializer = .{
        .ctx = ctx,
        .runtime = ctx.runtime,
        .code = generated_code,
        .region = region,
        .builder = &builder,
        .function = callable,
        .current_block = callable_block,
    };
    const output = try specializer.evalFunction(
        generated_code,
        generated_closure,
        generated_closure.function_id,
        arguments,
        captures,
    );
    if (output.len != 2) return error.InvalidCode;
    const tangent = try specializer.ensureResidual(output[1]);
    const primal = switch (output[0]) {
        .concrete => |value| value,
        else => return error.InvalidCode,
    };
    const output_primitive = ctx.registry.idForNative(&materializeOutput) orelse return error.Unsupported;
    const owned_tangent = try builder.addNode(callable, callable_block, .{ .primitive_call = .{
        .primitive = output_primitive,
        .args = try builder.addOperands(&.{tangent}),
        .result_count = 1,
    } }, .{});
    try builder.setTerminator(callable_block, .{ .return_values = try builder.addOperands(&.{owned_tangent}) });
    const code = try builder.finish(ctx.scratch);
    code.owner = ctx.runtime;
    const program = try ctx.runtime.lowerCode(ctx.scratch, code);
    const guard = try makeGuard(ctx.runtime, region);
    const linear = try materializeLinear(ctx, source_closure, code, program, callable, guard);
    const output_algebra = try region.resolveSpace(ctx, primal);
    const output_tangent = try region.tangentPrototype(ctx, &output_algebra, primal);
    try skript.autodiff_transpose.validateLinear(ctx, linear, region.expected_arguments, &.{output_tangent}, region);
    ctx.runtime.linearization_state.track(region);
    return .{ .primal = primal, .linear = linear, .region = region };
}

test "linearization preserves builtin tensor reduction axes" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const source = try runtime.evalString("(fn (x) (fold x 0 +))");
    const input = try runtime.evalString("[[1.0 2.0] [3.0 4.0]]");
    const result = try linearize(ctx, source, &.{input});
    defer result.region.close();
    const primal = try tensorInput(result.primal);
    try std.testing.expectEqualSlices(u32, &.{2}, primal.shape);
    try std.testing.expectEqualSlices(u64, &.{
        @bitCast(@as(f64, 4.0)), @bitCast(@as(f64, 6.0)),
    }, primal.data);
    const reversed = try skript.autodiff_transpose.generate(
        ctx,
        result.linear,
        &.{input},
        &.{result.primal},
        null,
    );
    const cotangent = try runtime.evalString("[10.0 20.0]");
    const pulled = try tensorInput(try applyLinear(ctx, reversed, cotangent));
    try std.testing.expectEqualSlices(u32, &.{ 2, 2 }, pulled.shape);
    try std.testing.expectEqualSlices(u64, &.{
        @bitCast(@as(f64, 10.0)), @bitCast(@as(f64, 20.0)),
        @bitCast(@as(f64, 10.0)), @bitCast(@as(f64, 20.0)),
    }, pulled.data);
}

test "broadcast map2 JVP and reverse cotangents reduce repeated indices" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const source = try runtime.evalString(
        "(fn (a b) (map2 a b (fn (x y) (* x y))))",
    );
    const left = try runtime.evalString("[[1.0 2.0 3.0] [4.0 5.0 6.0]]");
    const right = try runtime.evalString("[10.0 20.0 30.0]");
    const result = try linearize(ctx, source, &.{ left, right });
    defer result.region.close();
    const primal = try tensorInput(result.primal);
    try std.testing.expectEqualSlices(u32, &.{ 2, 3 }, primal.shape);
    try std.testing.expectEqualSlices(u64, &.{
        @bitCast(@as(f64, 10.0)), @bitCast(@as(f64, 40.0)),  @bitCast(@as(f64, 90.0)),
        @bitCast(@as(f64, 40.0)), @bitCast(@as(f64, 100.0)), @bitCast(@as(f64, 180.0)),
    }, primal.data);

    const left_tangent = try runtime.evalString("[[1.0 2.0 3.0] [4.0 5.0 6.0]]");
    const right_tangent = try runtime.evalString("[2.0 3.0 4.0]");
    var workspace = Runtime.CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    var tangent_outputs: [1]Value = undefined;
    try workspace.apply(
        ctx,
        result.linear,
        &.{ left_tangent, right_tangent },
        &tangent_outputs,
    );
    const tangent = try tensorInput(try tangent_outputs[0].unwrapError());
    try std.testing.expectEqualSlices(u64, &.{
        @bitCast(@as(f64, 12.0)), @bitCast(@as(f64, 46.0)),  @bitCast(@as(f64, 102.0)),
        @bitCast(@as(f64, 48.0)), @bitCast(@as(f64, 115.0)), @bitCast(@as(f64, 204.0)),
    }, tangent.data);

    const reversed = try skript.autodiff_transpose.generate(
        ctx,
        result.linear,
        &.{ left, right },
        &.{result.primal},
        null,
    );
    const cotangent = try runtime.evalString("[[1.0 2.0 3.0] [4.0 5.0 6.0]]");
    const reverse_result_count = reversed.obj.toRef().deref(Closure).result_count;
    try std.testing.expectEqual(@as(u8, 2), reverse_result_count);
    var pulled_outputs: [2]Value = undefined;
    try applyLinearOutputs(ctx, reversed, cotangent, pulled_outputs[0..reverse_result_count]);
    const left_value = try pulled_outputs[0].unwrapError();
    const right_value = try pulled_outputs[1].unwrapError();
    const left_cotangent = try tensorInput(left_value);
    const right_cotangent = try tensorInput(right_value);
    try std.testing.expectEqualSlices(u32, &.{ 2, 3 }, left_cotangent.shape);
    try std.testing.expectEqualSlices(u32, &.{3}, right_cotangent.shape);
    try std.testing.expectEqualSlices(u64, &.{
        @bitCast(@as(f64, 10.0)), @bitCast(@as(f64, 40.0)),  @bitCast(@as(f64, 90.0)),
        @bitCast(@as(f64, 40.0)), @bitCast(@as(f64, 100.0)), @bitCast(@as(f64, 180.0)),
    }, left_cotangent.data);
    try std.testing.expectEqualSlices(u64, &.{
        @bitCast(@as(f64, 17.0)), @bitCast(@as(f64, 29.0)), @bitCast(@as(f64, 45.0)),
    }, right_cotangent.data);
    const empty_left = try runtime.evalString("(reshape (iota 0) [2 0 3])");
    const empty_right = try runtime.evalString("(reshape [10.0 20.0 30.0] [1 1 3])");
    const empty_result = try linearize(ctx, source, &.{ empty_left, empty_right });
    defer empty_result.region.close();
    const empty_primal = try tensorInput(empty_result.primal);
    try std.testing.expectEqualSlices(u32, &.{ 2, 0, 3 }, empty_primal.shape);
    try std.testing.expectEqual(tensor_intrin.InnerType.empty, empty_primal.inner);
    const empty_reversed = try skript.autodiff_transpose.generate(
        ctx,
        empty_result.linear,
        &.{ empty_left, empty_right },
        &.{empty_result.primal},
        null,
    );
    const empty_reverse_result_count = empty_reversed.obj.toRef().deref(Closure).result_count;
    try std.testing.expectEqual(reverse_result_count, empty_reverse_result_count);
    var empty_pulled_outputs: [2]Value = undefined;
    try applyLinearOutputs(
        ctx,
        empty_reversed,
        empty_result.primal,
        empty_pulled_outputs[0..empty_reverse_result_count],
    );
    const empty_left_value = try empty_pulled_outputs[0].unwrapError();
    const empty_right_value = try empty_pulled_outputs[1].unwrapError();
    const empty_left_cotangent = try tensorInput(empty_left_value);
    const empty_right_cotangent = try tensorInput(empty_right_value);
    try std.testing.expectEqualSlices(u32, &.{ 2, 0, 3 }, empty_left_cotangent.shape);
    try std.testing.expectEqualSlices(u32, &.{ 1, 1, 3 }, empty_right_cotangent.shape);
    try std.testing.expectEqualSlices(u64, &.{ 0, 0, 0 }, empty_right_cotangent.data);
}

test "outer transpose rejects inconsistent input and output sizes" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const source = try runtime.evalString("(fn (a b) (outer a b (fn (x y) (* x y))))");
    const left = try runtime.evalString("[1.0 2.0]");
    const right = try runtime.evalString("[3.0 4.0]");
    const result = try linearize(ctx, source, &.{ left, right });
    defer result.region.close();
    const record = result.region.records orelse return error.TestUnexpectedResult;
    var inconsistent = record.*;
    const empty = try runtime.evalString("[]");
    inconsistent.inputs = &.{ left, empty };
    try std.testing.expectError(error.TypeMismatch, transposeTensorMap(ctx, &inconsistent, result.primal));
}

fn findSpaceRecord(ctx: *EvalContext, id: u64) Error!*const SpaceRecord {
    if (id == 0) return error.InvalidCode;
    var region = ctx.runtime.linearization_state.head.load(.acquire);
    while (region) |current| {
        try ctx.chargeWork(1, 1, .native);
        if (!current.isClosed()) {
            try current.acquire();
            var transferred = false;
            defer if (!transferred) current.release();
            var record = current.spaces.load(.acquire);
            while (record) |candidate| {
                try ctx.chargeWork(1, 1, .native);
                if (candidate.id == id) {
                    try checkRegion(ctx.runtime, current);
                    transferred = true;
                    return candidate;
                }
                record = candidate.next;
            }
        }
        region = current.next;
    }
    return error.Expired;
}

pub fn cotangentZero(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    const record = try findSpaceRecord(ctx, try recordId(args[0]));
    defer record.region.release();
    return record.algebra.cotangentZero(ctx);
}

pub fn cotangentAdd(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    if (args.len != 3) return error.ArityMismatch;
    const record = try findSpaceRecord(ctx, try recordId(args[0]));
    defer record.region.release();
    const left = if (args[1].isNil()) try record.algebra.cotangentZero(ctx) else args[1];
    const right = if (args[2].isNil()) try record.algebra.cotangentZero(ctx) else args[2];
    return record.algebra.cotangentAdd(ctx, left, right);
}

pub fn sameLinearSpace(left: *const space.SpaceSpec, right: *const space.SpaceSpec) bool {
    return left.primal_type == right.primal_type and
        left.dimension == right.dimension and left.tree_spec == right.tree_spec and
        std.meta.eql(left.tangent, right.tangent) and
        std.meta.eql(left.cotangent, right.cotangent) and
        std.meta.eql(left.pairing, right.pairing);
}

pub fn scalarAdjoint(ctx: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    if (args.len != 4) return error.ArityMismatch;
    const input = try findSpaceRecord(ctx, try recordId(args[0]));
    defer input.region.release();
    const output = try findSpaceRecord(ctx, try recordId(args[1]));
    defer output.region.release();
    if (sameLinearSpace(&input.algebra, &output.algebra)) {
        return input.algebra.cotangentScale(ctx, args[3], args[2]);
    }
    const dimension = input.algebra.dimension orelse return error.Unsupported;
    try ctx.charge(.{
        .work = @intCast(dimension),
        .objects = 1,
        .bytes = std.math.mul(
            u64,
            @intCast(dimension),
            @sizeOf(Value),
        ) catch return error.Exhausted,
    }, .native);
    const coordinates = try ctx.scratch.alloc(Value, dimension);
    defer ctx.scratch.free(coordinates);
    const output_zero = try output.algebra.tangentZero(ctx);
    for (coordinates, 0..) |*coordinate, index| {
        const basis = try input.algebra.tangentBasis(ctx, index);
        const factor = if (tree.isNumeric(basis)) try tree.coerceNumeric(basis.typ, args[2]) else args[2];
        var image = try input.algebra.tangentScale(ctx, basis, factor);
        if (tree.isNumeric(image) and tree.isNumeric(output_zero)) {
            image = try tree.coerceNumeric(output_zero.typ, image);
        }
        coordinate.* = try output.algebra.pair(ctx, image, args[3]);
    }
    return input.algebra.cotangentFromCoordinates(ctx, coordinates);
}

fn rememberAlgebra(ctx: *EvalContext, region: *Region, algebra: *const space.SpaceSpec) Error!void {
    if (!algebra.usesRegisteredAlgebra()) return;
    if (algebra.tree_spec) |structure| {
        const registry = algebra.space_registry orelse return error.Unsupported;
        for (structure.nodes) |node| {
            try ctx.chargeWork(1, 1, .transform);
            if (node.kind != .custom) continue;
            const child = registry.find(node.runtime_type) orelse return error.Unsupported;
            try rememberAlgebra(ctx, region, child);
        }
        return;
    }
    for ([_]space.LinearOps{ algebra.tangent, algebra.cotangent }) |ops| {
        for ([_]?Value{
            ops.zero_hook,
            ops.add_hook,
            ops.scale_hook,
            ops.check_hook,
            ops.basis_hook,
            ops.construct_hook,
        }) |hook| {
            if (hook) |value| try rememberHook(ctx, region, ops.namespace, value, 0);
        }
    }
    if (algebra.pairing.hook) |hook| try rememberHook(ctx, region, algebra.pairing.namespace, hook, 0);
}

fn rememberHook(parent: *EvalContext, region: *Region, namespace: Value, value: Value, depth: usize) Error!void {
    if (depth >= max_value_depth) return error.Unsupported;
    if (value.typ != b.type_closure and value.typ != b.type_method) return;
    var ctx = try parent.enter(.transform);
    const scope = ctx.activate();
    defer scope.deinit();
    for (region.space_hooks.items) |seen| {
        try ctx.chargeWork(1, 1, .transform);
        if (seen.value.typ == value.typ and seen.value.obj == value.obj) return;
    }
    const storage = region.storage.load(.acquire) orelse return error.Expired;
    const allocator = storage.arena.allocator();
    const closure = if (value.typ == b.type_closure) value.obj.toRef().deref(Closure) else null;
    const guard = if (closure) |function| function.guard else null;
    if (guard) |held| {
        try held.check(ctx.runtime, held.context);
        if (held.acquire) |acquire| try acquire(ctx.runtime, held.context);
    }
    defer if (guard) |held| {
        if (held.release) |release| release(ctx.runtime, held.context);
    };
    const captures = if (closure) |function| try allocator.dupe(Value, function.captures) else &.{};
    try region.space_hooks.append(allocator, .{ .value = value, .captures = captures });
    for (captures) |capture| try rememberValue(&ctx, region, namespace, capture, depth + 1);
    if (value.typ == b.type_method) {
        var targets = value.obj.toRef().deref(skript.data.Method).resolved.valueIterator();
        while (targets.next()) |target| try rememberHook(&ctx, region, namespace, target.*, depth + 1);
    }
    const reads = try effects.collectReads(ctx.runtime, namespace, value, ctx.scratch);
    defer ctx.scratch.free(reads);
    try region.space_reads.appendSlice(allocator, reads);
    for (reads) |read| {
        if (read == .cell) try rememberValue(&ctx, region, read.cell.namespace, read.cell.snapshot.value, depth + 1);
    }
}

fn rememberValue(ctx: *EvalContext, region: *Region, namespace: Value, value: Value, depth: usize) Error!void {
    if (depth >= max_value_depth) return error.Unsupported;
    if (value.typ == b.type_closure or value.typ == b.type_method) {
        return rememberHook(ctx, region, namespace, value, depth + 1);
    }
    const mutable = value.typ == b.type_cons or value.typ == b.type_map or value.typ == b.type_tensor or
        @intFromEnum(value.typ) > b.type_last_idx;
    if (!mutable) return;
    for (region.space_values.items) |seen| {
        try ctx.chargeWork(1, 1, .transform);
        if (seen.value.typ == value.typ and seen.value.obj == value.obj) return;
    }
    const storage = region.storage.load(.acquire) orelse return error.Expired;
    const allocator = storage.arena.allocator();
    const structure = try tree.flatten(allocator, ctx, region.tree_version, value, tree.Limits.generic);
    for (structure.nodes) |*node| {
        if (node.kind == .custom) {
            node.kind.custom.metadata = try prototypeValue(ctx, region, node.kind.custom.metadata, 0);
        }
    }
    try region.space_values.append(allocator, .{ .value = value, .structure = structure });
}

fn checkAlgebraDependencies(ctx: *EvalContext, region: *const Region) Error!void {
    try ctx.chargeWork(@intCast(region.space_reads.items.len + region.space_hooks.items.len), 1, .code);
    for (region.space_reads.items) |read| if (!read.valid(ctx.runtime)) return error.Unsupported;
    for (region.space_hooks.items) |snapshot| {
        if (snapshot.value.typ != b.type_closure) continue;
        const closure = snapshot.value.obj.toRef().deref(Closure);
        if (closure.captures.len != snapshot.captures.len) return error.Unsupported;
        for (closure.captures, snapshot.captures) |actual, expected| {
            try ctx.chargeWork(1, 1, .code);
            if (actual.typ != expected.typ or actual.obj != expected.obj) return error.Unsupported;
        }
        if (closure.guard) |guard| try guard.check(ctx.runtime, guard.context);
    }
    for (region.space_values.items) |*snapshot| {
        var current = try tree.flatten(ctx.scratch, ctx, region.tree_version, snapshot.value, tree.Limits.generic);
        defer current.deinit();
        if (!try tree.sameStructure(ctx, &snapshot.structure, &current)) return error.Unsupported;
        for (snapshot.structure.leaves, current.leaves) |expected, actual| {
            try ctx.chargeWork(1, 1, .code);
            if (actual.primal.typ != expected.primal.typ or
                actual.primal.obj != expected.primal.obj)
            {
                return error.Unsupported;
            }
        }
    }
}

test "tensor HVP reverses nonlinear fold and scan recurrence" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    try std.testing.expectEqual(Value.f64(72.0), try runtime.evalString(
        "(hvp (fn (x) (fold (stack x x x) (fn (a y) (* a y)))) 3.0 4.0)",
    ));
    try std.testing.expectEqual(Value.f64(80.0), try runtime.evalString(
        "(hvp (fn (x) (fold (scan (stack x x x) (fn (a y) (* a y))) " ++
            "(fn (a y) (+ a y)))) 3.0 4.0)",
    ));
    try std.testing.expectEqual(Value.i64(72), try runtime.evalString(
        "(hvp (fn (x) (fold (stack x x x) (fn (a y) (* a y)))) 3 4)",
    ));
}

test "tensor HVP keeps binary operands active and honors reduction axes" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    try std.testing.expectEqual(Value.f64(40.0), try runtime.evalString(
        "(hvp (fn (x) (fold (map2 (stack x (* 2.0 x)) (stack x (* 2.0 x)) " ++
            "(fn (a y) (* a y))) (fn (a y) (+ a y)))) 3.0 4.0)",
    ));
    const outer = try runtime.evalString(
        "(fn (x) (tensor-get (outer (stack x) (stack x (* 3.0 x)) " ++
            "(fn (a y) (* a y))) 0 1))",
    );
    try std.testing.expectEqual(Value.f64(24.0), try skript.intrinsics.ad_reverse.hvp(
        runtime.context(),
        .nil,
        .nil,
        &.{ outer, Value.f64(3.0), Value.f64(4.0) },
    ));
    const axis_fold = try runtime.evalString(
        "(fn (x) (tensor-get (fold (stack (stack x x) (stack x x)) " ++
            "0 (fn (a y) (* a y))) 0))",
    );
    try std.testing.expectEqual(Value.f64(8.0), try skript.intrinsics.ad_reverse.hvp(
        runtime.context(),
        .nil,
        .nil,
        &.{ axis_fold, Value.f64(3.0), Value.f64(4.0) },
    ));
}

test "broadcast map2 HVP transposes nested repeated indices" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const result = try runtime.evalString(
        "(hvp (fn (x) (fold (fold (map2 " ++
            "(reshape (stack x (* 2.0 x)) (stack 2 1)) " ++
            "(reshape (stack x (* 3.0 x) (* 4.0 x)) (stack 1 3)) " ++
            "(fn (a b) (* a b))) 0 +) +)) 2.0 5.0)",
    );
    try std.testing.expectEqual(Value.f64(240.0), result);
}

test "closed residual histories cannot bypass a lookup work limit" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const source = try runtime.evalString("(fn (x) (* x x))");
    for (0..8) |_| {
        const result = try linearize(runtime.context(), source, &.{Value.f64(3.0)});
        result.region.close();
    }
    try std.testing.expectError(error.Expired, tensorLinearInfo(runtime.context(), std.math.maxInt(u64)));
    var budget = EvalContext.Budget.init(runtime.io, 9_102, .{ .work = 4 });
    var lease = try EvalContext.Budget.Lease.root(&budget, 4);
    var account = EvalContext.Budget.AccountAllocator.init(std.testing.allocator, &lease, .regvm);
    var output_bytes: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_bytes);
    var context = try EvalContext.limited(
        runtime,
        runtime.intrinsics.registryVersion(),
        &account,
        .{ .writer = &writer, .bounded_memory = true },
        .{ .effects = .{ .state_read = .allow } },
    );
    try std.testing.expectError(error.Exhausted, tensorLinearInfo(&context, std.math.maxInt(u64)));
    try std.testing.expectError(error.Exhausted, context.check());
}

test "linearize inlines helper closures through dynamic calls" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const source = try runtime.evalString("(fn (x) ((fn (y) (* y y)) x))");
    const result = try linearize(ctx, source, &.{Value.f64(3.0)});
    defer result.region.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 9.0), result.primal.obj.tof64(), 1e-12);
    try std.testing.expectApproxEqAbs(
        @as(f64, 6.0),
        (try applyLinear(ctx, result.linear, .f64(1.0))).obj.tof64(),
        1e-12,
    );
}

test "linearize rejects closures owned by a foreign runtime" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const foreign = try Runtime.init(std.testing.allocator, std.testing.io);
    defer foreign.deinit();
    const source = try foreign.evalString("(fn (x) (* x x))");
    try std.testing.expectError(error.Denied, linearize(runtime.context(), source, &.{Value.f64(3.0)}));
}

test "linearize rejects dynamic callees with no concrete target" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const source = try runtime.evalString("(fn (f x) (f x))");
    const active = try runtime.evalString("[1.0 2.0]");
    try std.testing.expectError(error.Unsupported, linearize(ctx, source, &.{ active, Value.f64(3.0) }));
}
