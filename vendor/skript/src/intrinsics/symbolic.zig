//! Public symbolic values. Expr values are stable Runtime handles. Neither a
//! handle nor State retains a stack EvalContext pointer.

const std = @import("std");
const skript = @import("../root.zig");
const Expr = @import("../expr.zig");
const symbolic_eval = @import("../autodiff/symbolic.zig");
const rules = @import("../autodiff/rules.zig");

const Value = skript.Value;
pub const Error = skript.Error || Expr.Error;
const Runtime = skript.Runtime;
const EvalContext = skript.EvalContext;
const Sym = skript.Sym;
const FuncPtr = skript.FuncPtr;
const Primitive = skript.Primitive;
const b = skript.builtins;
const Method = skript.data.Method;
const Allocator = std.mem.Allocator;

const default_limits: Expr.Limits = .{
    .max_nodes = 16_384,
    .max_edges = 65_536,
    .max_names = 16_384,
    .max_labels = 16_384,
    .max_name_bytes = 1 * 1024 * 1024,
    .max_shape_dimensions = 16_384,
    .max_depth = 256,
};
const default_view_nodes: usize = 4_096;
const max_view_nodes: usize = 16_384;
const max_symbolic_arguments: usize = 256;

var next_state_identity: std.atomic.Value(u32) = .init(1);

fn allocateStateIdentity() Error!u32 {
    var old = next_state_identity.load(.acquire);
    while (old != 0 and old != std.math.maxInt(u32)) {
        if (next_state_identity.cmpxchgWeak(old, old + 1, .acq_rel, .acquire) == null) return old;
        old = next_state_identity.load(.acquire);
    }
    return error.Exhausted;
}

fn resolveRuntimeContext(owner: *const anyopaque) *EvalContext {
    const runtime: *Runtime = @ptrCast(@alignCast(@constCast(owner)));
    return runtime.context();
}

const RegionRecord = struct {
    region: Expr.Region,
    identity: Expr.RegionId,
    removed: bool = false,
    closed: bool = false,
};
const HandleRecord = struct { handle: Expr.Handle, region_index: usize };

/// Append-only Runtime-owned expression state. ExprIds are never reused while
/// this State exists, so a stale public value cannot alias a newer expression.
pub const State = struct {
    allocator: Allocator,
    runtime: *Runtime,
    owner_id: u32,
    next_region_identity: usize = 1,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    regions: std.ArrayList(*RegionRecord) = .empty,
    handles: std.ArrayList(*HandleRecord) = .empty,

    pub fn init(runtime: *Runtime) Error!State {
        return .{
            .allocator = runtime.gpa,
            .runtime = runtime,
            .owner_id = try allocateStateIdentity(),
            .io = runtime.io,
        };
    }

    pub fn deinit(self: *State) void {
        for (self.handles.items) |record| {
            record.handle.deinit();
            self.allocator.destroy(record);
        }
        for (self.regions.items) |record| {
            record.region.deinit();
            self.allocator.destroy(record);
        }
        self.handles.deinit(self.allocator);
        self.regions.deinit(self.allocator);
        self.* = undefined;
    }

    fn lock(self: *State) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *State) void {
        self.mutex.unlock(self.io);
    }

    fn regionIdentity(self: *State) Error!Expr.RegionId {
        const local = self.next_region_identity;
        if (local >= std.math.maxInt(u32)) return error.Exhausted;
        self.next_region_identity = std.math.add(usize, local, 1) catch return error.Exhausted;
        const identity = (@as(u64, self.owner_id) << 32) | @as(u64, @intCast(local));
        return Expr.RegionId.fromInt(identity);
    }

    fn addRegion(self: *State, ctx: *EvalContext) Error!usize {
        try ctx.check();
        const identity = try self.regionIdentity();
        const owner: *const anyopaque = @ptrCast(self.runtime);
        const record = try self.allocator.create(RegionRecord);
        errdefer self.allocator.destroy(record);
        record.* = .{
            .region = try Expr.Region.initOwned(
                self.allocator,
                owner,
                &resolveRuntimeContext,
                ctx,
                .{ .identity = identity, .limits = default_limits },
            ),
            .identity = identity,
        };
        errdefer record.region.deinit();
        try self.regions.append(self.allocator, record);
        return self.regions.items.len - 1;
    }

    fn closeRegion(self: *State, index: usize, removed: bool) void {
        std.debug.assert(index < self.regions.items.len);
        const region_record = self.regions.items[index];
        if (removed) region_record.removed = true;
        if (region_record.closed) return;
        region_record.closed = true;
        region_record.region.close();
        for (self.handles.items) |handle_record| {
            if (handle_record.region_index == index) handle_record.handle.deinit();
        }
        region_record.region.deinit();
    }

    fn rollbackRegion(self: *State, index: usize) void {
        self.closeRegion(index, true);
    }

    fn handleIndex(self: *const State, id: Value.ExprId) Error!usize {
        if (!id.isValid()) return error.InvalidHandle;
        if (id.owner() != self.owner_id) return error.Denied;
        const local = id.local();
        if (local == 0) return error.InvalidHandle;
        const index: usize = local - 1;
        if (index >= self.handles.items.len) return error.InvalidHandle;
        const handle_record = self.handles.items[index];
        if (handle_record.region_index >= self.regions.items.len) return error.InvalidHandle;
        const region_record = self.regions.items[handle_record.region_index];
        if (region_record.removed) return error.InvalidHandle;
        if (region_record.region.isClosed()) return error.Expired;
        if (!handle_record.handle.active) return error.Expired;
        return index;
    }

    fn handleFor(self: *const State, id: Value.ExprId) Error!*const Expr.Handle {
        const record = self.handles.items[try self.handleIndex(id)];
        return &record.handle;
    }

    fn cloneHandle(self: *State, ctx: *EvalContext, id: Value.ExprId) Error!Expr.Handle {
        self.lock();
        defer self.unlock();
        const record = self.handles.items[try self.handleIndex(id)];
        const region = self.regions.items[record.region_index];
        return region.region.handle(ctx, record.handle.nodeId());
    }

    fn regionAt(self: *const State, index: usize) Error!*Expr.Region {
        if (index >= self.regions.items.len) return error.InvalidHandle;
        const record = self.regions.items[index];
        if (record.removed) return error.InvalidHandle;
        return &record.region;
    }

    fn storeHandle(self: *State, handle: *Expr.Handle, region_index: usize) Error!Value {
        if (!handle.active) return error.Expired;
        if (region_index >= self.regions.items.len) return error.InvalidHandle;
        const region_record = self.regions.items[region_index];
        if (region_record.removed) return error.InvalidHandle;
        if (region_record.region.isClosed()) return error.Expired;
        const local = std.math.add(usize, self.handles.items.len, 1) catch return error.Exhausted;
        if (local >= std.math.maxInt(u32)) return error.Exhausted;
        const record = try self.allocator.create(HandleRecord);
        errdefer self.allocator.destroy(record);
        record.* = .{ .handle = handle.*, .region_index = region_index };
        try self.handles.append(self.allocator, record);
        handle.active = false;
        return Value.expr(Value.ExprId.init(self.owner_id, @intCast(local)));
    }
};

fn stateFor(ctx: *EvalContext) Error!*State {
    if (ctx.runtime.symbolic_state) |*state| {
        if (state.runtime != ctx.runtime) return error.Denied;
        return state;
    }
    return error.Unsupported;
}

fn arity(args: []const Value, expected: usize) Error!void {
    if (args.len != expected) return error.ArityMismatch;
}

fn symbolName(value: Value) Error![]const u8 {
    if (value.typ != b.type_symbol or value.obj == .null) return error.TypeMismatch;
    return value.obj.toPtr(Sym).*;
}

/// Direct Expr arguments trigger symbolic routing. Nested data are left to the
/// symbolic evaluator's explicit structured-value lifting rules.
pub fn hasExpr(arguments: []const Value) bool {
    for (arguments) |argument| if (argument.isExpr()) return true;
    return false;
}

fn isConcreteExprObserver(native: FuncPtr) bool {
    return native == &skript.intrinsics.print.write or
        native == &skript.intrinsics.print.displayBuiltin or
        native == &skript.intrinsics.string.format or
        native == &skript.intrinsics.string.printf;
}

/// Runtime's pre-RegVM filter. Public symbolic data operations must not be
/// redirected back through this function.
pub fn accepts(ctx: *EvalContext, callable: Value) bool {
    if (callable.typ == b.type_closure or callable.typ == b.type_method) return callable.obj != .null;
    if (callable.typ != b.type_intrinsic or callable.obj == .null) return false;
    const native = callable.obj.toPtr(FuncPtr);
    if (native == &symbolicVar or native == &symbolic or native == &exprToDatum or
        native == &compileExpr or native == &exprView or native == &closeExpr or native == &simplifyExpr)
    {
        return false;
    }
    if (isConcreteExprObserver(native)) return false;
    const id = ctx.registry.idForNative(native) orelse return false;
    const spec = ctx.registry.spec(id) orelse return false;
    const descriptor = rules.descriptorForInvocation(spec.invoke) orelse return true;
    return switch (descriptor.rule) {
        .list, .cons, .map_create => false,
        else => true,
    };
}

fn deinitArguments(arguments: []symbolic_eval.Argument) void {
    for (arguments) |*argument| switch (argument.*) {
        .constant => {},
        .expression => |*expression| expression.handle.deinit(),
    };
}

fn makeArguments(
    state: *State,
    ctx: *EvalContext,
    values: []const Value,
) Error![]symbolic_eval.Argument {
    if (values.len > max_symbolic_arguments) return error.Exhausted;
    const result = try ctx.scratch.alloc(symbolic_eval.Argument, values.len);
    var initialized: usize = 0;
    errdefer {
        deinitArguments(result[0..initialized]);
        ctx.scratch.free(result);
    }
    for (values, 0..) |value, index| {
        result[index] = if (value.isExpr()) blk: {
            const id = try value.exprId();
            break :blk .{ .expression = .{
                .handle = try state.cloneHandle(ctx, id),
                .guard_value = value,
            } };
        } else .{ .constant = value };
        initialized += 1;
    }
    return result;
}
fn primitiveForValue(ctx: *EvalContext, value: Value) Error!Primitive.PrimitiveId {
    if (value.typ != b.type_intrinsic or value.obj == .null) return error.TypeMismatch;
    return ctx.registry.idForNative(value.obj.toPtr(FuncPtr)) orelse error.Unsupported;
}

fn checkRuleSnapshot(ctx: *EvalContext, snapshot: *const rules.RegistryVersion) Error!void {
    if (ctx.registry != ctx.runtime.intrinsics.registryVersion()) return error.Denied;
    if (!snapshot.validFor(ctx.registry)) return error.Denied;
    const owner = if (ctx.runtime.ad_rules) |*rule_owner| rule_owner else return error.Unsupported;
    if (!owner.ownsCurrent(snapshot)) return error.Unsupported;
}

fn internScalar(ctx: *EvalContext, region: *Expr.Region, scalar: Expr.Scalar, domain: Expr.Domain) Error!Expr.NodeId {
    return region.intern(ctx, .{ .scalar = .{ .value = scalar, .domain = domain } });
}

fn scalarOperation(rule: rules.BuiltinJvp) ?rules.ScalarOp {
    return switch (rule) {
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
        else => null,
    };
}

fn scalarIdentity(ctx: *EvalContext, snapshot: *const rules.RegistryVersion) Error!Expr.PrimitiveIdentity {
    const primitive = ctx.registry.idForNative(&rules.scalarDispatch) orelse return error.Unsupported;
    const spec = ctx.registry.spec(primitive) orelse return error.Unsupported;
    const rule = snapshot.find(primitive) orelse return error.Unsupported;
    return .{
        .primitive = primitive,
        .registry_revision = ctx.registry.version,
        .implementation_revision = spec.implementation_revision,
        .rule_revision = rule.rule_revision,
    };
}

fn primitiveCallWithSnapshot(
    ctx: *EvalContext,
    region: *Expr.Region,
    primitive: Primitive.PrimitiveId,
    arguments: []const Expr.NodeId,
    snapshot: *const rules.RegistryVersion,
) Error!Expr.NodeId {
    if (ctx.registry != ctx.runtime.intrinsics.registryVersion()) return error.Denied;
    const spec = ctx.registry.spec(primitive) orelse return error.Denied;
    try checkRuleSnapshot(ctx, snapshot);
    const rule = snapshot.find(primitive) orelse return error.Unsupported;
    if (rule.primitive_revision != spec.implementation_revision) return error.Denied;
    if (rules.descriptorForInvocation(spec.invoke)) |descriptor| {
        if (scalarOperation(descriptor.rule)) |operation| {
            if (arguments.len == rules.scalarOperationArity(operation)) {
                const tag = try internScalar(
                    ctx,
                    region,
                    .{ .signed = @backingInt(operation) },
                    .signed_integer,
                );
                const operands = try ctx.scratch.alloc(Expr.NodeId, arguments.len + 1);
                defer ctx.scratch.free(operands);
                operands[0] = tag;
                @memcpy(operands[1..], arguments);
                return region.intern(ctx, .{ .primitive_call = .{
                    .identity = try scalarIdentity(ctx, snapshot),
                    .arguments = operands,
                    .domain = .real,
                } });
            }
        }
    }
    return region.intern(ctx, .{ .primitive_call = .{ .identity = .{
        .primitive = primitive,
        .registry_revision = ctx.registry.version,
        .implementation_revision = spec.implementation_revision,
        .rule_revision = rule.rule_revision,
    }, .arguments = arguments, .domain = .unknown } });
}

fn primitiveCall(
    ctx: *EvalContext,
    region: *Expr.Region,
    primitive: Primitive.PrimitiveId,
    arguments: []const Expr.NodeId,
) Error!Expr.NodeId {
    const snapshot = try rules.builtinSnapshot(ctx);
    return primitiveCallWithSnapshot(ctx, region, primitive, arguments, snapshot);
}

fn opaqueIdentity(primitive: Primitive.PrimitiveId, revision: u64) Expr.OpaqueIdentity {
    var hasher = std.hash.Fnv1a_64.init();
    var values = [_]u64{ @backingInt(primitive), revision };
    hasher.update(std.mem.sliceAsBytes(values[0..]));
    return .{ .id = hasher.final() | 1, .revision = revision | 1 };
}

fn argumentNode(
    ctx: *EvalContext,
    region: *Expr.Region,
    argument: symbolic_eval.Argument,
) Error!Expr.NodeId {
    return switch (argument) {
        .expression => |expression| try symbolic_eval.copyToRegion(ctx, region, &expression.handle),
        .constant => |value| try symbolic_eval.liftValue(ctx, region, value),
    };
}

fn argumentDomain(
    ctx: *EvalContext,
    argument: symbolic_eval.Argument,
) Error!Expr.Domain {
    return switch (argument) {
        .constant => |value| switch (value.typ) {
            b.type_f16, b.type_f32, b.type_f64 => .real,
            b.type_i8, b.type_i16, b.type_i32, b.type_i64 => .signed_integer,
            b.type_u8, b.type_u16, b.type_u32, b.type_u64 => .unsigned_integer,
            b.type_bool => .boolean,
            else => .structured,
        },
        .expression => |expression| blk: {
            var snapshot = try expression.handle.snapshot(ctx.scratch, ctx, .{});
            defer snapshot.deinit();
            const node = try snapshot.node(snapshot.root());
            break :blk nodeDomain(node);
        },
    };
}

fn argumentType(
    ctx: *EvalContext,
    argument: symbolic_eval.Argument,
) Error!skript.Object {
    return switch (try argumentDomain(ctx, argument)) {
        .real => b.type_f64,
        .signed_integer => b.type_i64,
        .unsigned_integer => b.type_u64,
        .boolean => b.type_bool,
        .unknown, .structured => error.Unsupported,
    };
}
fn requireScalarArguments(
    ctx: *EvalContext,
    arguments: []const symbolic_eval.Argument,
) Error!void {
    for (arguments) |argument| switch (try argumentDomain(ctx, argument)) {
        .real, .signed_integer, .unsigned_integer => {},
        .unknown, .boolean, .structured => return error.Unsupported,
    };
}

fn methodSelection(
    ctx: *EvalContext,
    method: *Method,
    arguments: []const symbolic_eval.Argument,
) Error!Value {
    var hash = std.hash.Fnv1a_64.init();
    for (arguments) |argument| {
        const runtime_type = try argumentType(ctx, argument);
        hash.update(&std.mem.toBytes(runtime_type));
    }
    return method.resolved.get(hash.final()) orelse error.ArityMismatch;
}

fn primitiveExpression(
    ctx: *EvalContext,
    region: *Expr.Region,
    callable: Value,
    arguments: []const symbolic_eval.Argument,
    original_values: []const Value,
) Error!Expr.NodeId {
    var selected = callable;
    if (callable.typ == b.type_method) {
        if (callable.obj == .null) return error.TypeMismatch;
        selected = try methodSelection(
            ctx,
            callable.obj.toRef().deref(Method),
            arguments,
        );
    }
    if (selected.typ != b.type_intrinsic) return error.Unsupported;
    const primitive = try primitiveForValue(ctx, selected);
    if (ctx.registry != ctx.runtime.intrinsics.registryVersion()) return error.Denied;
    const spec = ctx.registry.spec(primitive) orelse return error.Denied;
    switch (try ctx.authorize(spec)) {
        .invoke => {},
        .model => return error.Unsupported,
    }
    const snapshot = try rules.builtinSnapshot(ctx);
    try checkRuleSnapshot(ctx, snapshot);
    const nodes = try ctx.scratch.alloc(Expr.NodeId, arguments.len);
    defer ctx.scratch.free(nodes);
    for (arguments, 0..) |argument, index| {
        nodes[index] = try argumentNode(ctx, region, argument);
    }
    const descriptor = rules.descriptorForInvocation(spec.invoke);
    if (descriptor) |info| {
        if (info.rule == .list) {
            return region.intern(ctx, .{ .list = .{ .elements = nodes } });
        }
        if (info.rule == .map_create) {
            if (arguments.len != original_values.len or arguments.len % 2 != 0) {
                return error.ArityMismatch;
            }
            const labels = try ctx.scratch.alloc([]const u8, arguments.len / 2);
            defer ctx.scratch.free(labels);
            var initialized_labels: usize = 0;
            defer for (labels[0..initialized_labels]) |label| ctx.scratch.free(@constCast(label));
            for (labels, 0..) |*label, index| {
                const key = original_values[index * 2];
                const bytes = if (key.typ == b.type_symbol or key.typ == b.type_keyword)
                    key.obj.toPtr(Sym).*
                else
                    return error.TypeMismatch;
                const prefix: u8 = if (key.typ == b.type_symbol) '\'' else ':';
                label.* = try std.fmt.allocPrint(ctx.scratch, "{c}{s}", .{ prefix, bytes });
                initialized_labels += 1;
            }
            const values = try ctx.scratch.alloc(Expr.NodeId, arguments.len / 2);
            defer ctx.scratch.free(values);
            for (values, 0..) |*value, index| value.* = nodes[index * 2 + 1];
            return region.intern(ctx, .{ .map = .{ .labels = labels, .values = values } });
        }
        if (info.rule == .stack) {
            const shape = try ctx.scratch.alloc(u32, 1);
            defer ctx.scratch.free(shape);
            shape[0] = std.math.cast(u32, nodes.len) orelse return error.Exhausted;
            return region.intern(ctx, .{ .tensor = .{
                .dtype = .unknown,
                .shape = shape,
                .elements = nodes,
            } });
        }
        if (info.rule == .constant or info.rule == .construct) return error.Unsupported;
        if (scalarOperation(info.rule) != null) {
            try requireScalarArguments(ctx, arguments);
            return primitiveCall(ctx, region, primitive, nodes);
        }
    }
    const effects = if (spec.effects.eql(Primitive.EffectSet.none))
        Expr.EffectKnowledge.known_none
    else
        Expr.EffectKnowledge.known;
    return region.intern(ctx, .{ .opaque_call = .{
        .identity = opaqueIdentity(primitive, spec.implementation_revision),
        .display_label = if (spec.stable_name.len == 0) "primitive" else spec.stable_name,
        .arguments = nodes,
        .domain = .unknown,
        .effects = effects,
        .linearity = if (descriptor) |info| switch (info.metadata.linearity) {
            .linear => .linear,
            .nonlinear => .nonlinear,
            .constant, .control => .unknown,
        } else .unknown,
    } });
}

fn evaluateCallable(
    state: *State,
    ctx: *EvalContext,
    region: *Expr.Region,
    callable: Value,
    arguments: []const Value,
) Error!Expr.Handle {
    const symbolic_arguments = try makeArguments(state, ctx, arguments);
    defer {
        deinitArguments(symbolic_arguments);
        ctx.scratch.free(symbolic_arguments);
    }
    return switch (callable.typ) {
        b.type_closure => symbolic_eval.evaluate(ctx, region, callable, symbolic_arguments),
        b.type_intrinsic, b.type_method => region.handle(
            ctx,
            try primitiveExpression(ctx, region, callable, symbolic_arguments, arguments),
        ),
        else => error.TypeMismatch,
    };
}

pub fn symbolicVar(ctx: *EvalContext, ns: Value, object: Value, args: []const Value) Error!Value {
    const scope = ctx.activate();
    defer scope.deinit();

    _ = ns;
    _ = object;
    try arity(args, 1);
    const name = try symbolName(args[0]);
    const state = try stateFor(ctx);
    state.lock();
    defer state.unlock();
    const index = try state.addRegion(ctx);
    errdefer state.rollbackRegion(index);
    const region_record = state.regions.items[index];
    var region = &region_record.region;
    const node = try region.freshVariable(ctx, name, .real, .none);
    var handle = try region.handle(ctx, node);
    errdefer handle.deinit();
    const result = try state.storeHandle(&handle, index);
    return result;
}

pub fn symbolic(ctx: *EvalContext, ns: Value, object: Value, args: []const Value) Error!Value {
    const scope = ctx.activate();
    defer scope.deinit();

    if (args.len == 0) return error.ArityMismatch;
    try ctx.check();
    if (args[0].obj == .null or
        (args[0].typ != b.type_closure and args[0].typ != b.type_method and args[0].typ != b.type_intrinsic))
    {
        return error.TypeMismatch;
    }
    if (args[0].typ == b.type_intrinsic and
        args[0].obj.toPtr(FuncPtr) == &skript.intrinsics.list.apply)
    {
        const id = try primitiveForValue(ctx, args[0]);
        const spec = ctx.registry.spec(id) orelse return error.Denied;
        switch (try ctx.authorize(spec)) {
            .invoke => {},
            .model => return error.Unsupported,
        }
        var inline_storage: [max_symbolic_arguments]Value = undefined;
        var expanded = try skript.intrinsics.list.expandApplyArguments(ctx, args[1..], &inline_storage);
        defer expanded.deinit();
        if (expanded.values.len > max_symbolic_arguments) return error.Exhausted;
        var forwarded: [max_symbolic_arguments + 1]Value = undefined;
        forwarded[0] = expanded.target;
        @memcpy(forwarded[1 .. expanded.values.len + 1], expanded.values);
        var nested = try ctx.enter(.native);
        return symbolic(&nested, ns, object, forwarded[0 .. expanded.values.len + 1]);
    }
    const state = try stateFor(ctx);
    const index = blk: {
        state.lock();
        defer state.unlock();
        break :blk try state.addRegion(ctx);
    };
    errdefer {
        state.lock();
        defer state.unlock();
        state.rollbackRegion(index);
    }
    const region = blk: {
        state.lock();
        defer state.unlock();
        break :blk try state.regionAt(index);
    };
    const values = args[1..];
    if (values.len > max_symbolic_arguments) return error.Exhausted;
    const symbolic_arguments = try ctx.scratch.alloc(symbolic_eval.Argument, values.len);
    var initialized_arguments: usize = 0;
    var owned_arguments: [max_symbolic_arguments]bool = undefined;
    @memset(owned_arguments[0..values.len], false);
    defer {
        for (
            symbolic_arguments[0..initialized_arguments],
            owned_arguments[0..initialized_arguments],
        ) |*argument, owned| {
            if (owned) switch (argument.*) {
                .constant => {},
                .expression => |*expression| expression.handle.deinit(),
            };
        }
        ctx.scratch.free(symbolic_arguments);
    }
    var names = std.ArrayList([]const u8).empty;
    var vars = std.ArrayList(Expr.Handle).empty;
    defer {
        for (vars.items) |*handle| handle.deinit();
        vars.deinit(ctx.scratch);
        names.deinit(ctx.scratch);
    }
    for (values, 0..) |value, argument_index| {
        if (value.isExpr()) {
            symbolic_arguments[argument_index] = .{ .expression = .{
                .handle = try state.cloneHandle(ctx, try value.exprId()),
                .guard_value = value,
            } };
            owned_arguments[argument_index] = true;
        } else if (value.typ == b.type_symbol) {
            const name = try symbolName(value);
            var found: ?usize = null;
            for (names.items, 0..) |known, name_index| {
                if (std.mem.eql(u8, known, name)) {
                    found = name_index;
                    break;
                }
            }
            const name_index = found orelse blk: {
                const node = try region.freshVariable(ctx, name, .real, .none);
                var handle = try region.handle(ctx, node);
                errdefer handle.deinit();
                try names.append(ctx.scratch, name);
                try vars.append(ctx.scratch, handle);
                handle.active = false;
                break :blk names.items.len - 1;
            };
            symbolic_arguments[argument_index] = .{ .expression = .{
                .handle = vars.items[name_index],
                .guard_value = value,
            } };
        } else {
            symbolic_arguments[argument_index] = .{ .constant = value };
        }
        initialized_arguments += 1;
    }
    var result = switch (args[0].typ) {
        b.type_closure => try symbolic_eval.evaluate(ctx, region, args[0], symbolic_arguments),
        b.type_intrinsic, b.type_method => try region.handle(
            ctx,
            try primitiveExpression(ctx, region, args[0], symbolic_arguments, values),
        ),
        else => return error.Unsupported,
    };
    errdefer result.deinit();
    if (ctx.registry != ctx.runtime.intrinsics.registryVersion()) return error.Denied;
    state.lock();
    defer state.unlock();
    return state.storeHandle(&result, index);
}

pub fn exprToDatum(ctx: *EvalContext, ns: Value, object: Value, args: []const Value) Error!Value {
    const scope = ctx.activate();
    defer scope.deinit();

    _ = ns;
    _ = object;
    try arity(args, 1);
    const state = try stateFor(ctx);
    state.lock();
    defer state.unlock();
    return symbolic_eval.toDatum(ctx, try state.handleFor(try args[0].exprId()));
}

fn integerValue(value: Value) Error!usize {
    return switch (value.typ) {
        b.type_i8 => blk: {
            const raw = value.obj.toInt(i8);
            if (raw < 0) return error.TypeMismatch;
            break :blk @intCast(raw);
        },
        b.type_i16 => blk: {
            const raw = value.obj.toInt(i16);
            if (raw < 0) return error.TypeMismatch;
            break :blk @intCast(raw);
        },
        b.type_i32 => blk: {
            const raw = value.obj.toInt(i32);
            if (raw < 0) return error.TypeMismatch;
            break :blk @intCast(raw);
        },
        b.type_i64 => blk: {
            const raw = value.obj.toInt(i64);
            if (raw < 0) return error.TypeMismatch;
            break :blk @intCast(raw);
        },
        b.type_u8 => @intCast(value.obj.toInt(u8)),
        b.type_u16 => @intCast(value.obj.toInt(u16)),
        b.type_u32 => @intCast(value.obj.toInt(u32)),
        b.type_u64 => std.math.cast(usize, value.obj.toInt(u64)) orelse return error.Exhausted,
        else => error.TypeMismatch,
    };
}

fn keyword(ctx: *EvalContext, name: []const u8) Error!Value {
    return Value.keyword(try ctx.runtime.store.getsym(name));
}
fn symbol(ctx: *EvalContext, name: []const u8) Error!Value {
    return Value.symbol(try ctx.runtime.store.getsym(name));
}
fn listValue(ctx: *EvalContext, values: []const Value) Error!Value {
    return skript.intrinsics.list.list(ctx, .nil, .nil, values);
}
fn mapValue(ctx: *EvalContext, values: []const Value) Error!Value {
    return skript.intrinsics.map.create(ctx, .nil, .nil, values);
}

fn domainName(domain: Expr.Domain) []const u8 {
    return switch (domain) {
        .unknown => "unknown",
        .real => "real",
        .signed_integer => "signed-integer",
        .unsigned_integer => "unsigned-integer",
        .boolean => "boolean",
        .structured => "structured",
    };
}

fn nodeDomain(node: Expr.Node) Expr.Domain {
    return switch (node.kind) {
        .scalar => |v| v.domain,
        .free_variable => |v| v.domain,
        .primitive_call => |v| v.domain,
        .conditional => |v| v.domain,
        .opaque_call => |v| v.domain,
        .list => |v| v.domain,
        .map => |v| v.domain,
        .tensor => |v| v.domain,
        .record => |v| v.domain,
        .static_atom => .structured,
    };
}

fn nodeView(ctx: *EvalContext, snapshot: *const Expr.Snapshot, node: Expr.Node) Error!Value {
    var pairs = std.ArrayList(Value).empty;
    defer pairs.deinit(ctx.scratch);
    try pairs.appendSlice(ctx.scratch, &.{
        try keyword(ctx, "id"),
        Value.u64(@backingInt(node.id)),
        try keyword(ctx, "kind"),
        try symbol(ctx, @tagName(std.meta.activeTag(node.kind))),
        try keyword(ctx, "domain"),
        try symbol(ctx, domainName(nodeDomain(node))),
    });
    const operands = try snapshot.operands(node);
    const operand_values = try ctx.scratch.alloc(Value, operands.len);
    defer ctx.scratch.free(operand_values);
    for (operands, 0..) |operand, index| operand_values[index] = Value.u64(@backingInt(operand));
    try pairs.appendSlice(ctx.scratch, &.{ try keyword(ctx, "operands"), try listValue(ctx, operand_values) });
    switch (node.kind) {
        .scalar => |value| try pairs.appendSlice(ctx.scratch, &.{ try keyword(ctx, "scalar"), switch (value.value) {
            .f64_bits => |bits| Value.u64(bits),
            .f32_bits => |bits| Value.u64(bits),
            .signed => |raw| Value.i64(raw),
            .unsigned => |raw| Value.u64(raw),
            .boolean => |raw| Value.bool(raw),
        } }),
        .static_atom => |value| try pairs.appendSlice(ctx.scratch, &.{
            try keyword(ctx, "name"),
            try symbol(ctx, try snapshot.name(value.name)),
        }),
        .free_variable => |value| try pairs.appendSlice(ctx.scratch, &.{
            try keyword(ctx, "region"),
            Value.u64(@backingInt(value.identity.region)),
            try keyword(ctx, "local"),
            Value.u64(value.identity.local),
            try keyword(ctx, "name"),
            try symbol(ctx, try snapshot.name(value.name)),
        }),
        .primitive_call => |value| try pairs.appendSlice(ctx.scratch, &.{
            try keyword(ctx, "primitive"),
            Value.u64(@backingInt(value.identity.primitive)),
            try keyword(ctx, "registry-revision"),
            Value.u64(value.identity.registry_revision),
            try keyword(ctx, "rule-revision"),
            Value.u64(value.identity.rule_revision),
        }),
        .conditional => |value| try pairs.appendSlice(ctx.scratch, &.{
            try keyword(ctx, "predicate"),
            Value.u64(@backingInt(value.predicate)),
            try keyword(ctx, "then"),
            Value.u64(@backingInt(value.then_branch)),
            try keyword(ctx, "else"),
            Value.u64(@backingInt(value.else_branch)),
        }),
        .opaque_call => |value| try pairs.appendSlice(ctx.scratch, &.{
            try keyword(ctx, "opaque-id"),
            Value.u64(value.identity.id),
            try keyword(ctx, "label"),
            try symbol(ctx, try snapshot.name(value.display_label)),
            try keyword(ctx, "effects"),
            try symbol(ctx, @tagName(value.effects)),
        }),
        .tensor => |value| {
            const shape = try snapshot.shape(value.shape);
            const shape_values = try ctx.scratch.alloc(Value, shape.len);
            defer ctx.scratch.free(shape_values);
            for (shape, 0..) |dimension, index| shape_values[index] = Value.u64(dimension);
            try pairs.appendSlice(ctx.scratch, &.{
                try keyword(ctx, "shape"),
                try listValue(ctx, shape_values),
                try keyword(ctx, "dtype"),
                try symbol(ctx, @tagName(value.dtype)),
            });
        },
        .list, .map, .record => {},
    }
    return mapValue(ctx, pairs.items);
}

pub fn exprView(ctx: *EvalContext, ns: Value, object: Value, args: []const Value) Error!Value {
    const scope = ctx.activate();
    defer scope.deinit();

    _ = ns;
    _ = object;
    if (args.len < 1 or args.len > 2) return error.ArityMismatch;
    const id = try args[0].exprId();
    const limit = if (args.len == 2) try integerValue(args[1]) else default_view_nodes;
    if (limit == 0 or limit > max_view_nodes) return error.Exhausted;
    const state = try stateFor(ctx);
    state.lock();
    defer state.unlock();
    const handle = try state.handleFor(id);
    var snapshot = try handle.snapshot(ctx.scratch, ctx, .{
        .max_nodes = limit,
        .max_edges = @min(default_limits.max_edges, limit * 8),
        .max_names = @min(default_limits.max_names, limit * 2),
        .max_labels = @min(default_limits.max_labels, limit * 2),
        .max_name_bytes = default_limits.max_name_bytes,
        .max_shape_dimensions = default_limits.max_shape_dimensions,
        .max_depth = default_limits.max_depth,
    });
    defer snapshot.deinit();
    const nodes = try ctx.scratch.alloc(Value, snapshot.nodeCount());
    defer ctx.scratch.free(nodes);
    for (nodes, 0..) |*entry, index| {
        try ctx.check();
        try ctx.charge(.{ .work = 1, .nodes = 1 }, .transform);
        entry.* = try nodeView(ctx, &snapshot, try snapshot.node(try Expr.NodeId.fromIndex(index)));
    }
    return mapValue(ctx, &.{
        try keyword(ctx, "owner"),
        Value.u64(id.owner()),
        try keyword(ctx, "handle"),
        Value.u64(id.local()),
        try keyword(ctx, "root"),
        Value.u64(@backingInt(snapshot.root())),
        try keyword(ctx, "nodes"),
        try listValue(ctx, nodes),
    });
}
pub fn apply(ctx: *EvalContext, namespace: Value, callable: Value, arguments: []const Value) Error!Value {
    const scope = ctx.activate();
    defer scope.deinit();

    if (callable.typ == b.type_intrinsic and callable.obj != .null and
        callable.obj.toPtr(FuncPtr) == &skript.intrinsics.list.apply)
    {
        if (!accepts(ctx, callable)) return error.Unsupported;
        const id = ctx.registry.idForNative(&skript.intrinsics.list.apply) orelse return error.Denied;
        const spec = ctx.registry.spec(id) orelse return error.Denied;
        switch (try ctx.authorize(spec)) {
            .invoke => {},
            .model => return error.Unsupported,
        }
        var inline_storage: [32]Value = undefined;
        var expanded = try skript.intrinsics.list.expandApplyArguments(ctx, arguments, &inline_storage);
        defer expanded.deinit();
        return ctx.apply(namespace, expanded.target, expanded.values);
    }
    if (!hasExpr(arguments) or !accepts(ctx, callable)) return error.Unsupported;
    const state = try stateFor(ctx);
    const index = blk: {
        state.lock();
        defer state.unlock();
        break :blk try state.addRegion(ctx);
    };
    errdefer {
        state.lock();
        defer state.unlock();
        state.rollbackRegion(index);
    }
    const region = blk: {
        state.lock();
        defer state.unlock();
        break :blk try state.regionAt(index);
    };
    var result = try evaluateCallable(state, ctx, region, callable, arguments);
    errdefer result.deinit();
    if (ctx.registry != ctx.runtime.intrinsics.registryVersion()) return error.Denied;
    state.lock();
    defer state.unlock();
    return state.storeHandle(&result, index);
}

pub fn closeExpr(ctx: *EvalContext, ns: Value, object: Value, args: []const Value) Error!Value {
    const scope = ctx.activate();
    defer scope.deinit();

    _ = ns;
    _ = object;
    try arity(args, 1);
    const state = try stateFor(ctx);
    state.lock();
    defer state.unlock();
    const record = state.handles.items[try state.handleIndex(try args[0].exprId())];
    state.closeRegion(record.region_index, false);
    return .nil;
}

pub fn simplifyExpr(ctx: *EvalContext, ns: Value, object: Value, args: []const Value) Error!Value {
    const scope = ctx.activate();
    defer scope.deinit();

    _ = ns;
    _ = object;
    if (args.len < 1 or args.len > 2) return error.ArityMismatch;
    const id = try args[0].exprId();
    const passes = if (args.len == 2) try integerValue(args[1]) else 8;
    if (passes == 0 or passes > 64) return error.Exhausted;
    const state = try stateFor(ctx);
    state.lock();
    defer state.unlock();
    const index = try state.addRegion(ctx);
    errdefer state.rollbackRegion(index);
    const region_record = state.regions.items[index];
    var region = &region_record.region;
    const source = try state.handleFor(id);
    var copied = try region.handle(ctx, try symbolic_eval.copyToRegion(ctx, region, source));
    defer copied.deinit();
    if (ctx.registry != ctx.runtime.intrinsics.registryVersion()) return error.Denied;
    const snapshot = try rules.builtinSnapshot(ctx);
    try checkRuleSnapshot(ctx, snapshot);
    const scalar = try scalarIdentity(ctx, snapshot);
    const dispatch: Expr.DispatchRewriteOperators = .{
        .primitive = scalar,
        .add = @intCast(@backingInt(rules.ScalarOp.add)),
        .multiply = @intCast(@backingInt(rules.ScalarOp.mul)),
        .divide = @intCast(@backingInt(rules.ScalarOp.div)),
        .zero_like = @intCast(@backingInt(rules.ScalarOp.zero_like)),
        .one_like = @intCast(@backingInt(rules.ScalarOp.one_like)),
        .coerce_tangent = @intCast(@backingInt(rules.ScalarOp.coerce_tangent)),
        .realize_tangent = @intCast(@backingInt(rules.ScalarOp.realize_tangent)),
    };
    var result = try region.rewrite(ctx, &copied, .{
        .policy = .formal_real,
        .operators = .{ .dispatch = dispatch },
        .limits = .{
            .max_nodes = default_limits.max_nodes,
            .max_edges = default_limits.max_edges,
            .max_rule_steps = 1_024,
            .max_passes = passes,
        },
    });
    errdefer result.deinit();
    try checkRuleSnapshot(ctx, snapshot);
    return state.storeHandle(&result, index);
}

pub fn compileExpr(ctx: *EvalContext, ns: Value, object: Value, args: []const Value) Error!Value {
    const scope = ctx.activate();
    defer scope.deinit();
    _ = ns;
    _ = object;
    if (args.len < 1 or args.len > 2) return error.ArityMismatch;
    const state = try stateFor(ctx);
    var variables = std.ArrayList(Expr.Handle).empty;
    defer variables.deinit(ctx.scratch);
    var bindings = std.ArrayList(Value).empty;
    defer bindings.deinit(ctx.scratch);
    const compiled = blk: {
        state.lock();
        defer state.unlock();
        const expression = try state.handleFor(try args[0].exprId());
        if (args.len == 2) {
            if (args[1].isExpr()) {
                try variables.append(ctx.scratch, (try state.handleFor(try args[1].exprId())).*);
            } else {
                const items = try collectList(ctx, args[1]);
                defer ctx.scratch.free(items);
                const pairs = items.len > 0 and items[0].typ == b.type_cons;
                for (items) |item| {
                    if (pairs) {
                        const pair = try collectList(ctx, item);
                        defer ctx.scratch.free(pair);
                        if (pair.len != 2) return error.InvalidShape;
                        if (!pair[0].isExpr() or pair[1].isExpr()) return error.TypeMismatch;
                        try variables.append(ctx.scratch, (try state.handleFor(try pair[0].exprId())).*);
                        try bindings.append(ctx.scratch, pair[1]);
                    } else {
                        if (!item.isExpr()) return error.TypeMismatch;
                        try variables.append(ctx.scratch, (try state.handleFor(try item.exprId())).*);
                    }
                }
            }
        }
        break :blk try symbolic_eval.compile(ctx, expression, variables.items);
    };
    if (bindings.items.len == 0) return compiled;
    return ctx.runtime.applyWithContext(ctx, ctx.runtime.root_ns, compiled, bindings.items);
}

fn collectList(ctx: *EvalContext, value: Value) Error![]Value {
    var count: usize = 0;
    var current = value;
    while (current.typ == b.type_cons) {
        try ctx.check();
        count = std.math.add(usize, count, 1) catch return error.Exhausted;
        if (count > max_symbolic_arguments) return error.Exhausted;
        current = current.obj.toRef().deref([2]Value)[1];
    }
    if (current.typ != b.type_nil) return error.TypeMismatch;
    const result = try ctx.scratch.alloc(Value, count);
    current = value;
    var index: usize = 0;
    while (current.typ == b.type_cons) : (index += 1) {
        result[index] = current.obj.toRef().deref([2]Value)[0];
        current = current.obj.toRef().deref([2]Value)[1];
    }
    return result;
}

fn installReentrantPointTree(runtime: *Runtime, expression: Value) !Value {
    const name = try runtime.store.getsym("Point");
    const type_reference = try runtime.store.create(skript.Type);
    runtime.store.store(skript.Type, type_reference.deref(skript.Type), .{
        .meta = b.type_type,
        .name = skript.Object.fromPtr(name),
    });
    const runtime_type = type_reference.toObject();
    const maker = try runtime.evalString(
        "(fn (saved) (fn (point) (begin (expr-view saved) (list (list 3.0 4.0) '(point-label)))))",
    );
    var hook_result: [1]Value = undefined;
    try runtime.applyResultsWithContext(
        runtime.context(),
        maker,
        &.{expression},
        &hook_result,
    );
    const flatten_hook = hook_result[0];
    const unflatten_hook = try runtime.evalString("(fn (metadata children) nil)");
    _ = try runtime.tree_registry.publish(&.{.{
        .runtime_type = runtime_type,
        .implementation_revision = 7,
        .namespace = runtime.root_ns,
        .flatten_hook = flatten_hook,
        .unflatten_hook = unflatten_hook,
    }});
    return Value.init(runtime_type, .null);
}

fn installCompiledPointTree(runtime: *Runtime) !Value {
    const name = try runtime.store.getsym("CompiledPoint");
    const type_reference = try runtime.store.create(skript.Type);
    runtime.store.store(skript.Type, type_reference.deref(skript.Type), .{
        .meta = b.type_type,
        .name = skript.Object.fromPtr(name),
    });
    const runtime_type = type_reference.toObject();
    const point = Value.init(runtime_type, .null);
    const flatten_hook = try runtime.evalString(
        "(fn (point) (list (list 3.0 4.0) (list 'compiled-point-label)))",
    );
    const unflatten_maker = try runtime.evalString(
        "(fn (point) (fn (metadata children) point))",
    );
    var hook_result: [1]Value = undefined;
    try runtime.applyResultsWithContext(
        runtime.context(),
        unflatten_maker,
        &.{point},
        &hook_result,
    );
    _ = try runtime.tree_registry.publish(&.{.{
        .runtime_type = runtime_type,
        .implementation_revision = 11,
        .namespace = runtime.root_ns,
        .flatten_hook = flatten_hook,
        .unflatten_hook = hook_result[0],
    }});
    return point;
}

var descriptorless_native_invocations: usize = 0;

fn descriptorlessTestNative(
    _: *EvalContext,
    _: Value,
    _: Value,
    _: []const Value,
) Error!Value {
    descriptorless_native_invocations += 1;
    return .f64(99.0);
}

fn symbolicTestMapField(ctx: *EvalContext, map: Value, name: []const u8) Error!Value {
    return skript.intrinsics.map.get(
        ctx,
        .nil,
        .nil,
        &.{ map, Value.keyword(try ctx.runtime.store.getsym(name)) },
    );
}

fn symbolicTestListAt(value: Value, index: usize) Error!Value {
    var current = value;
    var offset: usize = 0;
    while (offset < index) : (offset += 1) {
        if (current.typ != b.type_cons) return error.InvalidShape;
        current = current.obj.toRef().deref([2]Value)[1];
    }
    if (current.typ != b.type_cons) return error.InvalidShape;
    return current.obj.toRef().deref([2]Value)[0];
}

fn symbolicTestListLength(value: Value) Error!usize {
    var current = value;
    var length: usize = 0;
    while (current.typ == b.type_cons) {
        length = std.math.add(usize, length, 1) catch return error.Exhausted;
        current = current.obj.toRef().deref([2]Value)[1];
    }
    if (current.typ != b.type_nil) return error.TypeMismatch;
    return length;
}

fn symbolicTestIndex(value: Value) Error!usize {
    if (value.typ != b.type_u64) return error.TypeMismatch;
    return std.math.cast(usize, value.obj.toInt(u64)) orelse return error.Exhausted;
}

fn expectReentrantPointExpression(ctx: *EvalContext, expression: Value) !void {
    const view = try exprView(ctx, .nil, .nil, &.{expression});
    const nodes = try symbolicTestMapField(ctx, view, "nodes");
    const root = try symbolicTestMapField(ctx, view, "root");
    const root_node = try symbolicTestListAt(nodes, try symbolicTestIndex(root));
    const root_kind = try symbolicTestMapField(ctx, root_node, "kind");
    try std.testing.expectEqual(b.type_symbol, root_kind.typ);
    try std.testing.expectEqualStrings("record", root_kind.obj.toPtr(Sym).*);
    const root_operands = try symbolicTestMapField(ctx, root_node, "operands");
    try std.testing.expectEqual(@as(usize, 5), try symbolicTestListLength(root_operands));
    const children_id = try symbolicTestListAt(root_operands, 4);
    const children_node = try symbolicTestListAt(nodes, try symbolicTestIndex(children_id));
    const children_operands = try symbolicTestMapField(ctx, children_node, "operands");
    try std.testing.expectEqual(@as(usize, 2), try symbolicTestListLength(children_operands));
    for ([_]f64{ 3.0, 4.0 }, 0..) |expected, index| {
        const child_id = try symbolicTestListAt(children_operands, index);
        const child = try symbolicTestListAt(nodes, try symbolicTestIndex(child_id));
        const scalar = try symbolicTestMapField(ctx, child, "scalar");
        try std.testing.expectEqual(b.type_u64, scalar.typ);
        const expected_bits: u64 = @bitCast(expected);
        try std.testing.expectEqual(expected_bits, scalar.obj.toInt(u64));
    }
}

test "public compile-expr rebuilds list map tensor with distinct variables" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    try std.testing.expectEqual(
        Value.true,
        try runtime.evalString(
            "(def structured-left (symbolic-var 'x)) " ++
                "(def structured-right (symbolic-var 'x)) " ++
                "(def structured-map " ++
                "  (symbolic hash-map :left structured-left :right structured-right)) " ++
                "(def structured-tensor " ++
                "  (symbolic stack structured-right structured-left)) " ++
                "(def structured-value " ++
                "  (symbolic list structured-left structured-map structured-tensor)) " ++
                "(def structured-compiled " ++
                "  (compile-expr structured-value " ++
                "    (list structured-left structured-right))) " ++
                "(let ((actual (structured-compiled 7.0 2.0))) " ++
                "  (let ((mapped (fst (rst actual))) " ++
                "        (tensor (fst (rst (rst actual))))) " ++
                "    (equal? " ++
                "      (list (fst actual) " ++
                "            (map-get mapped :left) (map-get mapped :right) " ++
                "            (tensor-shape tensor) " ++
                "            (tensor-get tensor 0) (tensor-get tensor 1)) " ++
                "      (list 7.0 7.0 2.0 '(2) 2.0 7.0))))",
        ),
    );
}

test "public compile-expr invokes registered record rebuild hooks" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const context = runtime.context();
    const point = try installCompiledPointTree(runtime);
    const identity = try runtime.evalString("(fn (point) point)");
    const expression = try symbolic(context, .nil, .nil, &.{ identity, point });
    const compiled = try compileExpr(context, .nil, .nil, &.{expression});
    const actual = try runtime.applyWithContext(
        context,
        runtime.root_ns,
        compiled,
        &.{},
    );
    try std.testing.expectEqual(point.typ, actual.typ);
    try std.testing.expectEqual(point.obj, actual.obj);
}

test "public compile-expr keeps conditional branches lazy" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const context = runtime.context();
    const state = try stateFor(context);
    const handles = blk: {
        state.lock();
        defer state.unlock();
        const region_index = try state.addRegion(context);
        errdefer state.rollbackRegion(region_index);
        const region = try state.regionAt(region_index);
        const predicate_id = try region.freshVariable(
            context,
            "predicate",
            .boolean,
            .none,
        );
        const good = try internScalar(context, region, .{ .signed = 42 }, .signed_integer);
        const bad_argument = try internScalar(
            context,
            region,
            .{ .signed = 1 },
            .signed_integer,
        );
        const rst = context.registry.idForNative(
            &skript.intrinsics.list.rst,
        ) orelse return error.Unsupported;
        const bad = try primitiveCall(context, region, rst, &.{bad_argument});
        const root = try region.intern(context, .{ .conditional = .{
            .predicate = predicate_id,
            .then_branch = good,
            .else_branch = bad,
            .domain = .signed_integer,
        } });
        var predicate = try region.handle(context, predicate_id);
        errdefer predicate.deinit();
        var expression = try region.handle(context, root);
        errdefer expression.deinit();
        const predicate_value = try state.storeHandle(&predicate, region_index);
        const expression_value = try state.storeHandle(&expression, region_index);
        break :blk .{
            .predicate = predicate_value,
            .expression = expression_value,
        };
    };
    const compiled = try compileExpr(
        context,
        .nil,
        .nil,
        &.{ handles.expression, handles.predicate },
    );
    try std.testing.expectEqual(
        Value.i64(42),
        try runtime.applyWithContext(
            context,
            runtime.root_ns,
            compiled,
            &.{Value.true},
        ),
    );
    try std.testing.expectError(
        error.TypeMismatch,
        (try runtime.applyWithContext(
            context,
            runtime.root_ns,
            compiled,
            &.{Value.false},
        )).unwrapError(),
    );
}

test "registered descriptorless natives stay opaque for Expr arguments" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    _ = try runtime.intrinsics.publish(&.{.{
        .stable_name = "test.symbolic.descriptorless",
        .invoke = Primitive.Invocation.nativePtr(&descriptorlessTestNative),
        .effects = .none,
        .callbacks = .none,
        .resources = .{ .fixed = .{} },
        .suspension = .never,
    }});
    const context = runtime.context();
    const variable = try symbolicVar(
        context,
        .nil,
        .nil,
        &.{Value.symbol(try runtime.store.getsym("descriptorless-x"))},
    );
    descriptorless_native_invocations = 0;
    const expression = try runtime.applyWithContext(
        context,
        runtime.root_ns,
        Value.intrinsic(&descriptorlessTestNative),
        &.{variable},
    );
    try std.testing.expectEqual(@as(usize, 0), descriptorless_native_invocations);
    const datum = try exprToDatum(context, .nil, .nil, &.{expression});
    try std.testing.expectEqual(
        Value.symbol(try runtime.store.getsym("test.symbolic.descriptorless")),
        try symbolicTestListAt(datum, 0),
    );
    try std.testing.expectError(
        error.Unsupported,
        compileExpr(context, .nil, .nil, &.{ expression, variable }),
    );
    try std.testing.expectEqual(@as(usize, 0), descriptorless_native_invocations);
}

test "direct symbolic host entries charge the supplied allocation lineage" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    _ = try rules.builtinSnapshot(runtime.context());
    const variable_name = Value.symbol(try runtime.store.getsym("bounded-symbolic-x"));
    const work_limit = 10_000_000;
    var budget = EvalContext.Budget.init(runtime.io, 7_301, .{
        .work = work_limit,
        .bytes = 64 * 1024 * 1024,
        .objects = 1_000_000,
        .nodes = 1_000_000,
    });
    var lease = try EvalContext.Budget.Lease.root(&budget, work_limit);
    var account = EvalContext.Budget.AccountAllocator.init(
        std.testing.allocator,
        &lease,
        .native,
    );
    var output_bytes: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_bytes);
    var bounded = try EvalContext.limited(
        runtime,
        runtime.intrinsics.registryVersion(),
        &account,
        .{ .writer = &writer, .bounded_memory = true },
        .{},
    );
    const state_before = budget.snapshot().consumed.objects;
    _ = try symbolicVar(&bounded, .nil, .nil, &.{variable_name});
    const state_after = budget.snapshot().consumed.objects;
    try std.testing.expect(state_after - state_before >= 5);

    const context = runtime.context();
    var region = try Expr.Region.init(
        std.testing.allocator,
        context,
        .{ .identity = @fromBackingInt(@intCast(7_302)) },
    );
    defer region.deinit();
    const scalar = try internScalar(context, &region, .{ .signed = 1 }, .signed_integer);
    const element_count = 256;
    const elements: [element_count]Expr.NodeId = @splat(scalar);
    const root = try region.intern(context, .{ .list = .{ .elements = &elements } });
    var handle = try region.handle(context, root);
    defer handle.deinit();
    const datum_before = budget.snapshot().consumed.objects;
    _ = try symbolic_eval.toDatum(&bounded, &handle);
    const datum_after = budget.snapshot().consumed.objects;
    try std.testing.expect(datum_after - datum_before >= element_count);
}

test "public symbolic releases State mutex around reentrant tree hooks" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const saved = try runtime.evalString("(symbolic-var 'saved)");
    const point = try installReentrantPointTree(runtime, saved);
    const direct_callable = try runtime.evalString("(fn (point) point)");

    var budget = EvalContext.Budget.init(runtime.io, 1, .{ .work = 100_000 });
    var lease = try EvalContext.Budget.Lease.root(&budget, 100_000);
    var account = EvalContext.Budget.AccountAllocator.init(std.testing.allocator, &lease, .native);
    var output_bytes: [1024]u8 = undefined;
    var output_writer = std.Io.Writer.fixed(&output_bytes);
    var bounded = try EvalContext.limited(
        runtime,
        runtime.intrinsics.registryVersion(),
        &account,
        .{ .writer = &output_writer, .bounded_memory = true },
        .{ .effects = .{ .state_read = .allow } },
    );
    const direct = try symbolic(&bounded, .nil, .nil, &.{ direct_callable, point });
    try expectReentrantPointExpression(&bounded, direct);

    const apply_callable = try runtime.evalString("(fn (point saved) point)");
    const implicit = try apply(&bounded, runtime.root_ns, apply_callable, &.{ point, saved });
    try expectReentrantPointExpression(&bounded, implicit);
}

test "explicit symbolic apply expands Expr values inside its final list" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const target = try runtime.evalString("@f64.add");
    const variable = try symbolicVar(ctx, .nil, .nil, &.{Value.symbol(try runtime.store.getsym("apply-x"))});
    const spread = try skript.intrinsics.list.list(ctx, .nil, .nil, &.{ variable, Value.f64(2.0) });
    const actual = try apply(
        ctx,
        runtime.root_ns,
        Value.intrinsic(&skript.intrinsics.list.apply),
        &.{ target, spread },
    );
    const expected = try apply(ctx, runtime.root_ns, target, &.{ variable, Value.f64(2.0) });
    const actual_datum = try exprToDatum(ctx, .nil, .nil, &.{actual});
    const expected_datum = try exprToDatum(ctx, .nil, .nil, &.{expected});
    try std.testing.expectEqual(
        Value.true,
        try runtime.apply(runtime.root_ns, try runtime.evalString("equal?"), &.{ actual_datum, expected_datum }),
    );
}

test "explicit symbolic operator expands apply before lifting symbols and nested Expr" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    try std.testing.expectEqual(Value.true, try runtime.evalString(
        "(equal? (expr->datum (symbolic apply @f64.add (list 'x 2.0))) '(+ x 2.0))",
    ));
    try std.testing.expectEqual(Value.true, try runtime.evalString(
        "(equal? (expr->datum (symbolic apply @f64.add (list (symbolic-var 'x) 2.0))) '(+ x 2.0))",
    ));
}

test "public symbolic compiles tail primitive calls" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    try std.testing.expectEqual(
        Value.true,
        try runtime.evalString(
            "(equal? (expr->datum (symbolic (fn (x) (@f64.sin x)) 'x)) '(sin x))",
        ),
    );
}

test "public symbolic APIs evaluate through runtime syntax" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    try std.testing.expectEqual(
        Value.true,
        try runtime.evalString(
            "(def public-symbolic-x (symbolic-var 'x)) " ++
                "(def public-symbolic-y (symbolic-var 'y)) " ++
                "(def public-symbolic-sum (symbolic + public-symbolic-x public-symbolic-y)) " ++
                "(def public-symbolic-compiled " ++
                "  (compile-expr public-symbolic-sum (list public-symbolic-x public-symbolic-y))) " ++
                "(equal? " ++
                "  (list (public-symbolic-compiled 2.0 5.0) (expr->datum public-symbolic-sum)) " ++
                "  (list 7.0 '(+ x y)))",
        ),
    );
}

test "public symbolic lifts quoted primitive and typed method calls" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    try std.testing.expectEqual(
        Value.true,
        try runtime.evalString(
            "(equal? (expr->datum (symbolic @f64.mul 'x 'x)) '(* x x))",
        ),
    );
    try std.testing.expectEqual(
        Value.true,
        try runtime.evalString(
            "(def public-symbolic-add (method)) " ++
                "(instance public-symbolic-add f64 f64 @f64.add) " ++
                "(equal? " ++
                "  (expr->datum (symbolic public-symbolic-add 'x 1.0)) " ++
                "  '(+ x 1.0))",
        ),
    );
    _ = try runtime.evalString(
        "(def public-symbolic-square (fn (x) (* x x))) " ++
            "(def public-symbolic-vector (stack (symbolic-var 'vector-x)))",
    );
    try std.testing.expectError(
        error.Unsupported,
        runtime.evalString(
            "(symbolic public-symbolic-square public-symbolic-vector)",
        ),
    );
    try std.testing.expectError(
        error.Unsupported,
        runtime.evalString(
            "(symbolic public-symbolic-add public-symbolic-vector public-symbolic-vector)",
        ),
    );
    try std.testing.expectError(
        error.Unsupported,
        runtime.evalString(
            "(symbolic @f64.mul public-symbolic-vector public-symbolic-vector)",
        ),
    );
}

test "terminal budget exhaustion releases the symbolic region owner" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const state = try stateFor(ctx);
    const name = Value.symbol(try runtime.store.getsym("budget-exhausted-symbol"));
    var budget = EvalContext.Budget.init(runtime.io, 9_104, .{
        .work = 1_000,
        .bytes = 1024 * 1024,
        .objects = 128,
        .nodes = 0,
    });
    var lease = try EvalContext.Budget.Lease.root(&budget, 1_000);
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
    const regions_before = state.regions.items.len;
    const handles_before = state.handles.items.len;
    try std.testing.expectError(
        error.Exhausted,
        symbolicVar(&bounded, .nil, .nil, &.{name}),
    );
    try std.testing.expect(budget.isExhausted());
    const failure = budget.report() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(EvalContext.Budget.Resource.nodes, failure.resource);
    try std.testing.expectEqual(regions_before + 1, state.regions.items.len);
    const failed = state.regions.items[regions_before];
    try std.testing.expect(failed.removed);
    try std.testing.expect(failed.closed);
    try std.testing.expect(failed.region.control == null);
    try std.testing.expectEqual(handles_before, state.handles.items.len);
    try std.testing.expectError(error.InvalidHandle, state.regionAt(regions_before));
}

test "rolled-back symbolic handles never alias a later region" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const state = try stateFor(ctx);

    // Publish a handle before rolling back its owning region.
    const stale = blk: {
        state.lock();
        defer state.unlock();
        const index = try state.addRegion(ctx);
        errdefer state.rollbackRegion(index);
        const region = try state.regionAt(index);
        const identity = region.identity();
        const node = try region.freshVariable(ctx, "stale", .real, .none);
        var handle = try region.handle(ctx, node);
        errdefer handle.deinit();
        const value = try state.storeHandle(&handle, index);
        var alias = try region.handle(ctx, node);
        errdefer alias.deinit();
        const alias_value = try state.storeHandle(&alias, index);
        state.rollbackRegion(index);
        const tombstone = state.regions.items[index];
        try std.testing.expect(tombstone.removed);
        try std.testing.expect(tombstone.closed);
        try std.testing.expect(tombstone.identity == identity);
        try std.testing.expect(tombstone.region.control == null);
        for (state.handles.items) |stored| {
            if (stored.region_index == index) try std.testing.expect(!stored.handle.active);
        }
        state.rollbackRegion(index);
        try std.testing.expect(tombstone.region.control == null);
        break :blk .{
            .value = value,
            .alias_value = alias_value,
            .index = index,
            .identity = identity,
        };
    };

    const live_name = try runtime.store.getsym("live");
    const live = try symbolicVar(ctx, .nil, .nil, &.{Value.symbol(live_name)});
    try std.testing.expect(
        stale.identity != state.regions.items[stale.index + 1].identity,
    );
    try std.testing.expectError(error.InvalidHandle, state.regionAt(stale.index));
    try std.testing.expectError(error.InvalidHandle, exprToDatum(ctx, .nil, .nil, &.{stale.value}));
    try std.testing.expectError(
        error.InvalidHandle,
        exprToDatum(ctx, .nil, .nil, &.{stale.alias_value}),
    );
    try std.testing.expectError(error.InvalidHandle, closeExpr(ctx, .nil, .nil, &.{stale.value}));
    try std.testing.expectEqual(Value.symbol(live_name), try exprToDatum(ctx, .nil, .nil, &.{live}));
}

test "public symbolic handles enforce owner and close checks" {
    var first = try Runtime.init(std.testing.allocator, std.testing.io);
    defer first.deinit();
    var second = try Runtime.init(std.testing.allocator, std.testing.io);
    defer second.deinit();
    const sx = try symbolicVar(first.context(), .nil, .nil, &.{Value.symbol(try first.store.getsym("x"))});
    try std.testing.expectError(error.Denied, exprToDatum(second.context(), .nil, .nil, &.{sx}));
    try std.testing.expectEqual(Value.nil, try closeExpr(first.context(), .nil, .nil, &.{sx}));
    try std.testing.expectError(error.Expired, exprToDatum(first.context(), .nil, .nil, &.{sx}));
    try std.testing.expectError(error.Expired, exprView(first.context(), .nil, .nil, &.{sx}));
    try std.testing.expectError(error.Expired, compileExpr(first.context(), .nil, .nil, &.{sx}));
    try std.testing.expectError(error.Expired, simplifyExpr(first.context(), .nil, .nil, &.{sx}));
    try std.testing.expectError(error.Expired, closeExpr(first.context(), .nil, .nil, &.{sx}));
}

test "closing a symbolic owner preserves an active Reader until lease release" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const value = try symbolicVar(
        ctx,
        .nil,
        .nil,
        &.{Value.symbol(try runtime.store.getsym("leased-reader"))},
    );
    const state = try stateFor(ctx);
    const expr_id = try value.exprId();
    var region_record: *RegionRecord = undefined;
    var node_id: Expr.NodeId = undefined;
    var reader = blk: {
        state.lock();
        defer state.unlock();
        const handle_index: usize = @intCast(expr_id.local() - 1);
        const handle_record = state.handles.items[handle_index];
        region_record = state.regions.items[handle_record.region_index];
        node_id = handle_record.handle.nodeId();
        break :blk try region_record.region.acquire(ctx);
    };
    defer reader.deinit();
    const retained_before = runtime.store.retainedBytes();

    try std.testing.expectEqual(Value.nil, try closeExpr(ctx, .nil, .nil, &.{value}));
    try std.testing.expect(region_record.closed);
    try std.testing.expect(region_record.region.control == null);
    try std.testing.expectEqual(retained_before, runtime.store.retainedBytes());
    const node = try reader.node(node_id);
    try std.testing.expectEqual(
        Expr.NodeTag.free_variable,
        std.meta.activeTag(node.kind),
    );
    try std.testing.expectError(error.Expired, exprToDatum(ctx, .nil, .nil, &.{value}));

    reader.deinit();
    try std.testing.expect(!reader.active);
    try std.testing.expect(runtime.store.retainedBytes() < retained_before);
}

test "closing a symbolic handle expires only its region aliases" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const state = try stateFor(ctx);

    const siblings = blk: {
        state.lock();
        defer state.unlock();
        const index = try state.addRegion(ctx);
        errdefer state.rollbackRegion(index);
        const region = try state.regionAt(index);
        const identity = region.identity();
        const node = try region.freshVariable(ctx, "shared", .real, .none);
        var first = try region.handle(ctx, node);
        errdefer first.deinit();
        var second = try region.handle(ctx, node);
        errdefer second.deinit();
        const first_value = try state.storeHandle(&first, index);
        const second_value = try state.storeHandle(&second, index);
        break :blk .{
            .first = first_value,
            .second = second_value,
            .index = index,
            .identity = identity,
        };
    };

    try std.testing.expectEqual(Value.nil, try closeExpr(ctx, .nil, .nil, &.{siblings.first}));
    {
        state.lock();
        defer state.unlock();
        const closed = state.regions.items[siblings.index];
        try std.testing.expect(closed.closed);
        try std.testing.expect(closed.region.control == null);
        for (state.handles.items) |stored| {
            if (stored.region_index == siblings.index) {
                try std.testing.expect(!stored.handle.active);
            }
        }
    }
    try std.testing.expectError(
        error.Expired,
        exprToDatum(ctx, .nil, .nil, &.{siblings.second}),
    );
    const live_name = try runtime.store.getsym("live-after-close");
    const live = try symbolicVar(ctx, .nil, .nil, &.{Value.symbol(live_name)});
    try std.testing.expect(
        siblings.identity != state.regions.items[siblings.index + 1].identity,
    );
    try std.testing.expectEqual(
        Value.symbol(live_name),
        try exprToDatum(ctx, .nil, .nil, &.{live}),
    );
}

test "public symbolic view is bounded before expansion" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();

    const ctx = runtime.context();
    const sx = try symbolicVar(ctx, .nil, .nil, &.{Value.symbol(try runtime.store.getsym("x"))});
    const plus = try runtime.nsGet(runtime.root_ns, try runtime.store.getsym("+"));
    const expression = try symbolic(ctx, .nil, .nil, &.{ plus, sx, Value.f64(1.0) });
    try std.testing.expectError(error.LimitExceeded, exprView(ctx, .nil, .nil, &.{ expression, Value.i64(1) }));
}

test "ordinary and differentiated closures compose with symbolic arguments" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const ctx = runtime.context();
    const source = try runtime.evalString("(fn (x) (* x x))");
    const derivative = try skript.intrinsics.ad.deriv(ctx, runtime.root_ns, .nil, &.{source});
    const variable = try symbolicVar(ctx, .nil, .nil, &.{Value.symbol(try runtime.store.getsym("x"))});
    for ([_]Value{ source, derivative }, [_]f64{ 9.0, 6.0 }) |callable, expected| {
        const expression = try apply(ctx, runtime.root_ns, callable, &.{variable});
        const compiled = try compileExpr(ctx, .nil, .nil, &.{ expression, variable });
        const actual = try runtime.applyWithContext(ctx, runtime.root_ns, compiled, &.{Value.f64(3.0)});
        try std.testing.expectEqual(Value.f64(expected), try actual.unwrapError());
    }
}

test "association bindings distinguish names and failed construction tombstones regions" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    try std.testing.expectEqual(
        Value.f64(5.0),
        try runtime.evalString(
            "(def association-left (symbolic-var 'x)) " ++
                "(def association-right (symbolic-var 'x)) " ++
                "(def association-difference " ++
                "  (symbolic - association-left association-right)) " ++
                "(compile-expr association-difference " ++
                "  (list (list association-left 7.0) (list association-right 2.0)))",
        ),
    );
    try std.testing.expectError(
        error.TypeMismatch,
        runtime.evalString("(compile-expr association-difference 2.0)"),
    );

    const state = if (runtime.symbolic_state) |*state| state else return error.Unsupported;
    const before = state.regions.items.len;
    try std.testing.expectError(
        error.ArityMismatch,
        runtime.evalString("(symbolic + 'rollback-x)"),
    );
    try std.testing.expectEqual(before + 1, state.regions.items.len);
    const failed_region = state.regions.items[before];
    try std.testing.expect(failed_region.region.isClosed());
    try std.testing.expect(failed_region.removed);
    try std.testing.expect(failed_region.closed);
    try std.testing.expect(failed_region.region.control == null);

    const live_name = try runtime.store.getsym("live-after-failure");
    const live = try symbolicVar(
        runtime.context(),
        .nil,
        .nil,
        &.{Value.symbol(live_name)},
    );
    try std.testing.expect(
        failed_region.identity != state.regions.items[before + 1].identity,
    );
    try std.testing.expectEqual(
        Value.symbol(live_name),
        try exprToDatum(runtime.context(), .nil, .nil, &.{live}),
    );
}

test "public symbolic exports reject negative narrow limits" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    _ = try runtime.evalString("(def negative-limit-expression (symbolic-var 'x))");
    for ([_][]const u8{
        "(expr-view negative-limit-expression (i8 -1))",
        "(expr-view negative-limit-expression (i16 -1))",
        "(expr-view negative-limit-expression (i32 -1))",
        "(simplify-expr negative-limit-expression (i8 -1))",
        "(simplify-expr negative-limit-expression (i16 -1))",
        "(simplify-expr negative-limit-expression (i32 -1))",
    }) |source| {
        try std.testing.expectError(error.TypeMismatch, runtime.evalString(source));
    }
}

test "tensor symbolic datum preserves shape dtype and symbolic elements" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    _ = try runtime.evalString(
        "(def tensor-symbolic-x (symbolic-var 'x)) " ++
            "(def tensor-symbolic-datum " ++
            "  (expr->datum (stack (+ tensor-symbolic-x 1.0))))",
    );
    try std.testing.expectEqual(
        Value.true,
        try runtime.evalString(
            "(equal? (map-get tensor-symbolic-datum :shape) '(1))",
        ),
    );
    try std.testing.expectEqual(
        Value.true,
        try runtime.evalString(
            "(equal? (map-get tensor-symbolic-datum :dtype) 'unknown)",
        ),
    );
    try std.testing.expectEqual(
        Value.true,
        try runtime.evalString(
            "(equal? (map-get tensor-symbolic-datum :elements) '((+ x 1.0)))",
        ),
    );
}

test "public formal simplification rewrites a strict square derivative" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    _ = try runtime.evalString(
        "(def square-symbolic-expression " ++
            "  (symbolic (deriv (fn (x) (* x x))) 'x))",
    );
    try std.testing.expectEqual(
        Value.false,
        try runtime.evalString(
            "(equal? (expr->datum square-symbolic-expression) '(* 2.0 x))",
        ),
    );
    try std.testing.expectEqual(
        Value.true,
        try runtime.evalString(
            "(equal? " ++
                "  (expr->datum (simplify-expr square-symbolic-expression)) " ++
                "  '(* 2.0 x))",
        ),
    );
}

test "stale derivative and helper closures reject symbolic evaluation" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    _ = try runtime.evalString(
        "(def stale-symbolic-predicate (method)) " ++
            "(instance stale-symbolic-predicate f64 (fn (x) #t)) " ++
            "(def stale-symbolic-derivative " ++
            "  (deriv ((fn (predicate) " ++
            "    (fn (x) (if (predicate x) (* x x) x))) " ++
            "    stale-symbolic-predicate))) " ++
            "(def stale-symbolic-helper " ++
            "  (fn (x) (stale-symbolic-derivative x))) " ++
            "(expr->datum (symbolic stale-symbolic-derivative 'x))",
    );
    _ = try runtime.evalString(
        "(instance stale-symbolic-predicate f64 (fn (x) #f))",
    );
    try std.testing.expectError(
        error.Unsupported,
        runtime.evalString("(symbolic stale-symbolic-derivative 'x)"),
    );
    try std.testing.expectError(
        error.Unsupported,
        runtime.evalString("(symbolic stale-symbolic-helper 'x)"),
    );
}
