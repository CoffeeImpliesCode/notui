//! Symbolic interpretation of immutable bound Code.

const std = @import("std");
const skript = @import("../root.zig");
const Code = @import("../code.zig");
const Expr = @import("../expr.zig");
const Primitive = @import("../primitive.zig");
const tree = @import("tree.zig");
const rules = @import("rules.zig");

const EvalContext = skript.EvalContext;
const Runtime = skript.Runtime;
const Value = skript.Value;
const Closure = skript.data.Closure;
const Sym = skript.Sym;
const b = skript.builtins;

const callables = @import("callable.zig");
fn addTestParameter(
    builder: *Code.Builder,
    runtime: *Runtime,
    function: Code.FunctionId,
    name: []const u8,
) !Code.ValueId {
    const binding = try builder.addBinding(
        function,
        try runtime.store.getsym(name),
        .parameter,
        .{},
    );
    const value = try builder.addValue(function);
    builder.bindings.items[@backingInt(binding)].value = value;
    try builder.addParameter(function, binding);
    return value;
}

fn materializeTestClosure(
    runtime: *Runtime,
    builder: *Code.Builder,
    function: Code.FunctionId,
) !Value {
    const code = try builder.finish(runtime.context().scratch);
    code.owner = runtime;
    const program = try runtime.lowerCode(runtime.context().scratch, code);
    const index = @backingInt(function);
    if (index >= program.fns.len) return error.InvalidCode;
    const lowered = program.fns[index];
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

fn makeIdentityClosure(runtime: *Runtime) !Value {
    var builder = Code.Builder.init(runtime.static, runtime.context());
    const identity = try runtime.allocCodeIdentity();
    builder.id = identity.id;
    builder.revision = identity.revision;
    const function = try builder.addFunction(null, .{});
    const block = try builder.addBlock(function);
    const argument = try addTestParameter(&builder, runtime, function, "value");
    try builder.setTerminator(
        block,
        .{ .return_values = try builder.addOperands(&.{argument}) },
    );
    return materializeTestClosure(runtime, &builder, function);
}

fn makeListClosure(runtime: *Runtime) !Value {
    var builder = Code.Builder.init(runtime.static, runtime.context());
    const identity = try runtime.allocCodeIdentity();
    builder.id = identity.id;
    builder.revision = identity.revision;
    const function = try builder.addFunction(null, .{});
    const block = try builder.addBlock(function);
    const left = try addTestParameter(&builder, runtime, function, "left");
    const right = try addTestParameter(&builder, runtime, function, "right");
    const primitive = runtime.context().registry.idForNative(
        &skript.intrinsics.list.list,
    ) orelse return error.Unsupported;
    const result = try builder.addNode(function, block, .{ .primitive_call = .{
        .primitive = primitive,
        .args = try builder.addOperands(&.{ left, right }),
    } }, .{});
    try builder.setTerminator(
        block,
        .{ .return_values = try builder.addOperands(&.{result}) },
    );
    return materializeTestClosure(runtime, &builder, function);
}

var opaque_invocations: usize = 0;

fn opaqueTestTarget(
    _: *EvalContext,
    _: Value,
    _: Value,
    _: []const Value,
) skript.Error!Value {
    opaque_invocations += 1;
    return .f64(99.0);
}

fn makeOpaqueClosure(runtime: *Runtime) !Value {
    var builder = Code.Builder.init(runtime.static, runtime.context());
    const identity = try runtime.allocCodeIdentity();
    builder.id = identity.id;
    builder.revision = identity.revision;
    const function = try builder.addFunction(null, .{});
    const block = try builder.addBlock(function);
    const argument = try addTestParameter(&builder, runtime, function, "x");
    const callee = try builder.addNode(
        function,
        block,
        .{ .literal = .intrinsic(&opaqueTestTarget) },
        .{},
    );
    const result = try builder.addNode(function, block, .{ .dynamic_call = .{
        .callee = callee,
        .args = try builder.addOperands(&.{argument}),
    } }, .{});
    try builder.setTerminator(
        block,
        .{ .return_values = try builder.addOperands(&.{result}) },
    );
    return materializeTestClosure(runtime, &builder, function);
}
fn makeTailOpaqueClosure(runtime: *Runtime) !Value {
    var builder = Code.Builder.init(runtime.static, runtime.context());
    const identity = try runtime.allocCodeIdentity();
    builder.id = identity.id;
    builder.revision = identity.revision;
    const function = try builder.addFunction(null, .{});
    const block = try builder.addBlock(function);
    const argument = try addTestParameter(&builder, runtime, function, "x");
    const callee = try builder.addNode(
        function,
        block,
        .{ .literal = .intrinsic(&opaqueTestTarget) },
        .{},
    );
    try builder.setTerminator(block, .{ .tail_call = .{
        .callee = callee,
        .args = try builder.addOperands(&.{argument}),
    } });
    return materializeTestClosure(runtime, &builder, function);
}

fn makeBranchClosure(runtime: *Runtime) !Value {
    var builder = Code.Builder.init(runtime.static, runtime.context());
    const identity = try runtime.allocCodeIdentity();
    builder.id = identity.id;
    builder.revision = identity.revision;
    const function = try builder.addFunction(null, .{});
    const entry = try builder.addBlock(function);
    const then_block = try builder.addBlock(function);
    const else_block = try builder.addBlock(function);
    const condition = try addTestParameter(&builder, runtime, function, "condition");
    try builder.setTerminator(entry, .{ .branch = .{
        .condition = condition,
        .then_edge = .{ .target = then_block },
        .else_edge = .{ .target = else_block },
    } });
    const left = try builder.addNode(
        function,
        then_block,
        .{ .literal = .f64(1.0) },
        .{},
    );
    try builder.setTerminator(
        then_block,
        .{ .return_values = try builder.addOperands(&.{left}) },
    );
    const right = try builder.addNode(
        function,
        else_block,
        .{ .literal = .f64(2.0) },
        .{},
    );
    try builder.setTerminator(
        else_block,
        .{ .return_values = try builder.addOperands(&.{right}) },
    );
    return materializeTestClosure(runtime, &builder, function);
}

fn checkRuleSnapshot(
    context: *EvalContext,
    snapshot: *const rules.RegistryVersion,
) Error!void {
    if (context.registry != context.runtime.intrinsics.registryVersion()) return error.Denied;
    if (!snapshot.validFor(context.registry)) return error.Denied;
    const owner = if (context.runtime.ad_rules) |*rule_owner| rule_owner else return error.Unsupported;
    if (!owner.ownsCurrent(snapshot)) return error.Unsupported;
}

fn currentPrimitiveIdentity(
    context: *EvalContext,
    primitive: Primitive.PrimitiveId,
) !Expr.PrimitiveIdentity {
    const spec = context.registry.spec(primitive) orelse return error.Unsupported;
    const registry = try rules.builtinSnapshot(context);
    try checkRuleSnapshot(context, registry);
    const rule = registry.find(primitive) orelse return error.Unsupported;
    return .{
        .primitive = primitive,
        .registry_revision = context.registry.version,
        .implementation_revision = spec.implementation_revision,
        .rule_revision = rule.rule_revision,
    };
}

pub const Error = skript.Error || Expr.Error || Code.Error;

pub const ExpressionArgument = struct {
    handle: Expr.Handle,
    guard_value: ?Value = null,
};

pub const Argument = union(enum) {
    constant: Value,
    expression: ExpressionArgument,
};

const max_steps: usize = 1_000_000;
const max_branch_depth: usize = 64;
const max_string_bytes: usize = 16 * 1024 * 1024;
const max_compile_depth: usize = 1024;
const max_host_depth: usize = 1024;

const ExpressionSlot = struct {
    node: Expr.NodeId,
    guard_value: ?Value = null,
};

const Slot = union(enum) {
    empty,
    concrete: Value,
    expression: ExpressionSlot,
    closure: *BoundClosure,
    results: []const Slot,
};

const GuardLease = struct {
    runtime: *Runtime,
    guard: *const skript.data.ClosureGuard,
    active: bool = true,

    fn release(self: *GuardLease) void {
        if (!self.active) return;
        self.active = false;
        if (self.guard.release) |release_guard| release_guard(self.runtime, self.guard.context);
    }
};

const ActiveClosure = struct {
    code: *const Code.Code,
    function: Code.FunctionId,
    captures: []const Slot,
    namespace: Value,
    guard: ?*const skript.data.ClosureGuard,
};

const BoundClosure = struct {
    code: *const Code.Code,
    function: Code.FunctionId,
    closure: ?*const Closure,
    captures: []const Slot,
    namespace: Value,
    guard: ?*const skript.data.ClosureGuard,
    guard_acquired: bool = false,
    guard_arguments_checked: bool = false,
};

const Frame = struct {
    callable: *const ActiveClosure,
    function: Code.FunctionId,
    namespace: Value,
    slots: []Slot,
};

const RunResult = union(enum) {
    value: Slot,
    tail_call: struct {
        callable: *BoundClosure,
        arguments: []const Slot,
    },
};
const Session = struct {
    ctx: *EvalContext,
    region: *Expr.Region,
    allocator: std.mem.Allocator,
    rule_version: *const rules.RegistryVersion,
    tree_version: *const tree.RegistryVersion,
    leases: std.ArrayList(GuardLease) = .empty,
    steps: usize = 0,
    branch_depth: usize = 0,
    host_depth: usize = 0,
    call_depth: usize = 0,

    fn enterHost(self: *Session) Error!void {
        const inherited = std.math.add(
            usize,
            self.ctx.depth,
            if (self.ctx.vm_depth) |value| @as(usize, value.*) else 0,
        ) catch return error.Exhausted;
        if (inherited >= max_host_depth or self.host_depth >= max_host_depth - inherited) {
            return error.Exhausted;
        }
        self.host_depth += 1;
    }

    fn leaveHost(self: *Session) void {
        std.debug.assert(self.host_depth > 0);
        self.host_depth -= 1;
    }
    /// Effective nesting depth across symbolic calls, held host leases, and
    /// inherited runtime depths. Checked BEFORE any per-level allocation so
    /// deep chains fail with Exhausted instead of exhausting memory first.
    fn checkCallDepth(self: *const Session) Error!void {
        const inherited = std.math.add(
            usize,
            self.ctx.depth,
            if (self.ctx.vm_depth) |value| @as(usize, value.*) else 0,
        ) catch return error.Exhausted;
        const held = std.math.add(usize, self.call_depth, self.host_depth) catch return error.Exhausted;
        const total = std.math.add(usize, held, inherited) catch return error.Exhausted;
        if (total >= max_host_depth) return error.Exhausted;
    }

    fn init(allocator: std.mem.Allocator, ctx: *EvalContext, region: *Expr.Region) Error!Session {
        try ctx.check();
        if (ctx.registry != ctx.runtime.intrinsics.registryVersion()) return error.Denied;
        const rule_version = try rules.builtinSnapshot(ctx);
        try checkRuleSnapshot(ctx, rule_version);
        const tree_version = ctx.runtime.tree_registry.current();
        const scalar_primitive = ctx.registry.idForNative(&rules.scalarDispatch) orelse return error.Unsupported;
        if (rule_version.find(scalar_primitive) == null) return error.Unsupported;
        return .{
            .ctx = ctx,
            .region = region,
            .allocator = allocator,
            .rule_version = rule_version,
            .tree_version = tree_version,
        };
    }

    fn checkCurrent(self: *const Session) Error!void {
        try checkRuleSnapshot(self.ctx, self.rule_version);
        if (self.ctx.runtime.tree_registry.current() != self.tree_version) return error.Denied;
    }

    fn deinit(self: *Session) void {
        var index = self.leases.items.len;
        while (index > 0) {
            index -= 1;
            self.leases.items[index].release();
        }
        self.leases.deinit(self.allocator);
        self.* = undefined;
    }

    fn step(self: *Session, work: u64, nodes: u64) Error!void {
        if (self.steps >= max_steps) return error.Exhausted;
        self.steps += 1;
        if (self.ctx.registry != self.ctx.runtime.intrinsics.registryVersion()) return error.Denied;
        if (!self.rule_version.validFor(self.ctx.registry)) return error.Denied;
        if (self.ctx.runtime.tree_registry.current() != self.tree_version) return error.Denied;
        try self.ctx.check();
        try self.ctx.charge(.{ .work = work, .nodes = nodes }, .transform);
    }

    fn internScalar(self: *Session, scalar: Expr.Scalar, domain: Expr.Domain) Error!Expr.NodeId {
        try self.step(1, 1);
        return self.region.intern(self.ctx, .{ .scalar = .{
            .value = scalar,
            .domain = domain,
        } });
    }

    fn internStatic(self: *Session, kind: Expr.StaticAtomKind, bytes: []const u8) Error!Expr.NodeId {
        try self.step(1, 1);
        return self.region.intern(self.ctx, .{ .static_atom = .{
            .kind = kind,
            .bytes = bytes,
        } });
    }

    fn slotFromValue(self: *Session, value: Value) Error!Slot {
        if (value.typ == b.type_closure and value.obj != .null) {
            const bound = try self.bindClosure(value);
            return .{ .closure = bound };
        }
        return .{ .concrete = value };
    }

    fn validateGuard(self: *Session, guard: *const skript.data.ClosureGuard) Error!void {
        _ = self;
        if ((guard.acquire == null) != (guard.release == null)) return error.InvalidCode;
    }

    fn slotGuardValue(self: *Session, slot: Slot) Error!Value {
        return switch (slot) {
            .concrete => |value| value,
            .expression => |expression| expression.guard_value orelse blk: {
                var reader = try self.region.acquire(self.ctx);
                defer reader.deinit();
                const node = try reader.node(expression.node);
                const free = switch (node.kind) {
                    .free_variable => |variable| variable,
                    else => return error.Unsupported,
                };
                break :blk Value.symbol(try self.ctx.runtime.store.getsym(try reader.name(free.name)));
            },
            .closure, .empty, .results => error.Unsupported,
        };
    }

    fn checkGuardArguments(
        self: *Session,
        guard: *const skript.data.ClosureGuard,
        arguments: []const Slot,
    ) Error!void {
        const check_arguments = guard.check_arguments orelse return;
        const concrete = try self.allocator.alloc(Value, arguments.len);
        defer self.allocator.free(concrete);
        for (arguments, 0..) |argument, index| {
            concrete[index] = try self.slotGuardValue(argument);
        }
        try check_arguments(self.ctx.runtime, guard.context, concrete);
    }

    fn acquireGuard(
        self: *Session,
        guard: *const skript.data.ClosureGuard,
        arguments: ?[]const Slot,
    ) Error!void {
        try self.validateGuard(guard);
        try guard.check(self.ctx.runtime, guard.context);
        try self.checkCurrent();
        if (arguments) |values| {
            try self.checkGuardArguments(guard, values);
            try self.checkCurrent();
        }
        if (guard.acquire) |acquire| {
            try acquire(self.ctx.runtime, guard.context);
            self.checkCurrent() catch |err| {
                if (guard.release) |release| release(self.ctx.runtime, guard.context);
                return err;
            };
            self.leases.append(self.allocator, .{
                .runtime = self.ctx.runtime,
                .guard = guard,
            }) catch |err| {
                if (guard.release) |release| release(self.ctx.runtime, guard.context);
                return err;
            };
        }
    }

    fn enterClosure(
        self: *Session,
        callable: *BoundClosure,
        arguments: []const Slot,
    ) Error!void {
        if (callable.guard_acquired) {
            if (!callable.guard_arguments_checked) {
                if (callable.guard) |guard| {
                    try self.checkGuardArguments(guard, arguments);
                    try self.checkCurrent();
                }
                callable.guard_arguments_checked = true;
            }
            return;
        }
        if (callable.guard) |guard| {
            const arguments_to_check: ?[]const Slot =
                if (callable.guard_arguments_checked) null else arguments;
            try self.acquireGuard(guard, arguments_to_check);
            callable.guard_arguments_checked = true;
        }
        callable.guard_acquired = true;
    }
    fn bindClosure(self: *Session, value: Value) Error!*BoundClosure {
        try self.checkCallDepth();
        try self.enterHost();
        defer self.leaveHost();
        if (value.typ != b.type_closure or value.obj == .null) return error.TypeMismatch;
        const closure = value.obj.toRef().deref(Closure);
        const guard = closure.guard;
        if (guard) |current| {
            // Check and acquire before reading code, captures, or parent
            // namespace. The lease remains active for this Session.
            try self.acquireGuard(current, null);
        }
        const code = closure.code orelse return error.Unsupported;
        if (code.owner != @as(?*const anyopaque, self.ctx.runtime)) return error.Denied;
        if (closure.function_id == .invalid) return error.InvalidCode;
        const captures = try self.allocator.alloc(Slot, closure.captures.len);
        try self.step(@intCast(closure.captures.len), 0);
        for (closure.captures, 0..) |capture, index| {
            captures[index] = try self.slotFromValue(capture);
        }
        const bound = try self.allocator.create(BoundClosure);
        bound.* = .{
            .code = code,
            .function = closure.function_id,
            .closure = closure,
            .captures = captures,
            .namespace = closure.parent_ns,
            .guard = guard,
            .guard_acquired = guard != null,
            .guard_arguments_checked = if (guard) |current| current.check_arguments == null else true,
        };
        return bound;
    }

    fn valueExpr(self: *Session, value: Value) Error!?Expr.NodeId {
        if (self.tree_version.find(value.typ) != null) {
            const node = try self.treeValueExpr(value);
            return node;
        }
        switch (value.typ) {
            b.type_nil => return try self.internStatic(.nil, &.{}),
            b.type_bool => return try self.internScalar(.{ .boolean = value.obj.toBool() }, .boolean),
            b.type_f16 => return try self.internScalar(
                .{ .f32_bits = @bitCast(@as(f32, @floatCast(value.obj.tof16()))) },
                .real,
            ),
            b.type_f32 => return try self.internScalar(.{ .f32_bits = @bitCast(value.obj.tof32()) }, .real),
            b.type_f64 => return try self.internScalar(.{ .f64_bits = @bitCast(value.obj.tof64()) }, .real),
            b.type_i8 => return try self.internScalar(.{ .signed = value.obj.toInt(i8) }, .signed_integer),
            b.type_i16 => return try self.internScalar(.{ .signed = value.obj.toInt(i16) }, .signed_integer),
            b.type_i32 => return try self.internScalar(.{ .signed = value.obj.toInt(i32) }, .signed_integer),
            b.type_i64 => return try self.internScalar(.{ .signed = value.obj.toInt(i64) }, .signed_integer),
            b.type_u8 => return try self.internScalar(.{ .unsigned = value.obj.toInt(u8) }, .unsigned_integer),
            b.type_u16 => return try self.internScalar(.{ .unsigned = value.obj.toInt(u16) }, .unsigned_integer),
            b.type_u32 => return try self.internScalar(.{ .unsigned = value.obj.toInt(u32) }, .unsigned_integer),
            b.type_u64 => return try self.internScalar(.{ .unsigned = value.obj.toInt(u64) }, .unsigned_integer),
            b.type_symbol => return try self.internStatic(.symbol, value.obj.toPtr(Sym).*),
            b.type_keyword => return try self.internStatic(.keyword, value.obj.toPtr(Sym).*),
            b.type_string => {
                const bytes = try self.ctx.stringBytes(
                    value.obj.toPtr([*:0]const u8),
                    max_string_bytes,
                    .transform,
                );
                return try self.internStatic(.string, bytes);
            },
            b.type_cons => return try self.listValueExpr(value),
            b.type_map => return try self.mapValueExpr(value),
            b.type_tensor => return try self.tensorValueExpr(value),
            else => return null,
        }
    }

    fn collectList(self: *Session, value: Value) Error![]Value {
        var count: usize = 0;
        var current = value;
        while (current.typ == b.type_cons) {
            try self.step(1, 0);
            count = std.math.add(usize, count, 1) catch return error.LimitExceeded;
            current = current.obj.toRef().deref([2]Value)[1];
        }
        if (current.typ != b.type_nil) return error.TypeMismatch;
        const result = try self.allocator.alloc(Value, count);
        try self.step(@intCast(result.len), 0);
        current = value;
        var index: usize = 0;
        while (current.typ == b.type_cons) : (index += 1) {
            result[index] = current.obj.toRef().deref([2]Value)[0];
            current = current.obj.toRef().deref([2]Value)[1];
        }
        return result;
    }

    fn listValueExpr(self: *Session, value: Value) Error!Expr.NodeId {
        const values = try self.collectList(value);
        const elements = try self.allocator.alloc(Expr.NodeId, values.len);
        try self.step(@intCast(values.len), 0);
        for (values, 0..) |item, index| {
            const node = (try self.valueExpr(item)) orelse return error.Unsupported;
            elements[index] = node;
        }
        return self.region.intern(self.ctx, .{ .list = .{ .elements = elements } });
    }

    fn mapValueExpr(self: *Session, value: Value) Error!Expr.NodeId {
        const keys = try skript.intrinsics.map.keys(self.ctx, .nil, .nil, &.{value});
        const vals = try skript.intrinsics.map.vals(self.ctx, .nil, .nil, &.{value});
        const key_values = try self.collectList(keys);
        const value_values = try self.collectList(vals);
        if (key_values.len != value_values.len) return error.InvalidShape;
        const labels = try self.allocator.alloc([]const u8, key_values.len);
        const elements = try self.allocator.alloc(Expr.NodeId, value_values.len);
        try self.step(@intCast(key_values.len), 0);
        for (key_values, value_values, 0..) |key, item, index| {
            const bytes = switch (key.typ) {
                b.type_symbol, b.type_keyword => key.obj.toPtr(Sym).*,
                else => return error.TypeMismatch,
            };
            const prefix: u8 = if (key.typ == b.type_symbol) '\'' else ':';
            labels[index] = try std.fmt.allocPrint(self.allocator, "{c}{s}", .{ prefix, bytes });
            elements[index] = (try self.valueExpr(item)) orelse return error.Unsupported;
        }
        return self.region.intern(self.ctx, .{ .map = .{
            .labels = labels,
            .values = elements,
        } });
    }

    fn tensorValueExpr(self: *Session, value: Value) Error!Expr.NodeId {
        const tensor = value.obj.toRef().deref(skript.intrinsics.tensor.TensorHolder);
        const elements = try self.allocator.alloc(Expr.NodeId, tensor.data.len);
        const dtype: Expr.DType = switch (tensor.inner) {
            .i64 => .i64,
            .f64 => .f64,
            .string => .unknown,
            .symbol => .unknown,
            .keyword => .unknown,
            .empty => .unknown,
        };
        try self.step(@intCast(tensor.data.len), 0);
        for (tensor.data, 0..) |word, index| {
            const element: Value = switch (tensor.inner) {
                .i64 => .i64(@bitCast(word)),
                .f64 => .f64(@bitCast(word)),
                .string => .string(@fromBackingInt(@intCast(word))),
                .symbol => .symbol(@ptrFromInt(std.math.cast(usize, word) orelse return error.TypeMismatch)),
                .keyword => .keyword(@ptrFromInt(std.math.cast(usize, word) orelse return error.TypeMismatch)),
                .empty => return error.InvalidShape,
            };
            elements[index] = (try self.valueExpr(element)) orelse return error.Unsupported;
        }
        return self.region.intern(self.ctx, .{ .tensor = .{
            .dtype = dtype,
            .shape = tensor.shape,
            .elements = elements,
        } });
    }

    fn copyHandle(self: *Session, handle: *const Expr.Handle) Error!Expr.NodeId {
        var snapshot = try handle.snapshot(self.allocator, self.ctx, .{});
        defer snapshot.deinit();
        const mapping = try self.allocator.alloc(Expr.NodeId, snapshot.nodeCount());
        for (mapping, 0..) |*target, index| {
            try self.step(1, 1);
            const source_id = try Expr.NodeId.fromIndex(index);
            const node = try snapshot.node(source_id);
            target.* = switch (node.kind) {
                .scalar => |scalar| try self.region.intern(self.ctx, .{ .scalar = .{
                    .value = scalar.value,
                    .domain = scalar.domain,
                    .origin = node.origin,
                } }),
                .static_atom => |atom| try self.region.intern(self.ctx, .{ .static_atom = .{
                    .kind = atom.kind,
                    .bytes = try snapshot.name(atom.name),
                    .origin = node.origin,
                } }),
                .free_variable => |variable| try self.region.intern(self.ctx, .{ .free_variable = .{
                    .identity = variable.identity,
                    .name = try snapshot.name(variable.name),
                    .domain = variable.domain,
                    .assumptions = variable.assumptions,
                    .origin = node.origin,
                } }),
                .primitive_call => |call| blk: {
                    const old = try snapshot.operands(node);
                    const args = try self.allocator.alloc(Expr.NodeId, old.len);
                    for (old, 0..) |child, child_index| args[child_index] = mapping[child.index()];
                    break :blk try self.region.intern(self.ctx, .{ .primitive_call = .{
                        .identity = call.identity,
                        .arguments = args,
                        .domain = call.domain,
                        .origin = node.origin,
                    } });
                },
                .conditional => |conditional| try self.region.intern(self.ctx, .{ .conditional = .{
                    .predicate = mapping[conditional.predicate.index()],
                    .then_branch = mapping[conditional.then_branch.index()],
                    .else_branch = mapping[conditional.else_branch.index()],
                    .domain = conditional.domain,
                    .origin = node.origin,
                } }),
                .opaque_call => |call| blk: {
                    const old = try snapshot.operands(node);
                    const args = try self.allocator.alloc(Expr.NodeId, old.len);
                    for (old, 0..) |child, child_index| args[child_index] = mapping[child.index()];
                    break :blk try self.region.intern(self.ctx, .{ .opaque_call = .{
                        .identity = call.identity,
                        .display_label = try snapshot.name(call.display_label),
                        .arguments = args,
                        .domain = call.domain,
                        .effects = call.effects,
                        .linearity = call.linearity,
                        .origin = node.origin,
                    } });
                },
                .list => |list| blk: {
                    const old = try snapshot.operands(node);
                    const args = try self.allocator.alloc(Expr.NodeId, old.len);
                    for (old, 0..) |child, child_index| args[child_index] = mapping[child.index()];
                    break :blk try self.region.intern(self.ctx, .{ .list = .{
                        .elements = args,
                        .domain = list.domain,
                        .origin = node.origin,
                    } });
                },
                .map => |map| blk: {
                    const old = try snapshot.operands(node);
                    const args = try self.allocator.alloc(Expr.NodeId, old.len);
                    const labels = try self.allocator.alloc([]const u8, map.labels.len);
                    for (old, 0..) |child, child_index| args[child_index] = mapping[child.index()];
                    for (labels, 0..) |*label, label_index| label.* = try snapshot.label(map.labels, label_index);
                    break :blk try self.region.intern(self.ctx, .{ .map = .{
                        .labels = labels,
                        .values = args,
                        .domain = map.domain,
                        .origin = node.origin,
                    } });
                },
                .tensor => |tensor| blk: {
                    const old = try snapshot.operands(node);
                    const args = try self.allocator.alloc(Expr.NodeId, old.len);
                    for (old, 0..) |child, child_index| args[child_index] = mapping[child.index()];
                    break :blk try self.region.intern(self.ctx, .{ .tensor = .{
                        .dtype = tensor.dtype,
                        .shape = try snapshot.shape(tensor.shape),
                        .elements = args,
                        .domain = tensor.domain,
                        .origin = node.origin,
                    } });
                },
                .record => |record| blk: {
                    const old = try snapshot.operands(node);
                    const args = try self.allocator.alloc(Expr.NodeId, old.len);
                    const labels = try self.allocator.alloc([]const u8, record.fields.len);
                    for (old, 0..) |child, child_index| args[child_index] = mapping[child.index()];
                    for (labels, 0..) |*label, label_index| label.* = try snapshot.label(record.fields, label_index);
                    break :blk try self.region.intern(self.ctx, .{ .record = .{
                        .type_label = try snapshot.name(record.type_label),
                        .field_labels = labels,
                        .fields = args,
                        .domain = record.domain,
                        .origin = node.origin,
                    } });
                },
            };
        }
        return mapping[snapshot.root().index()];
    }
    fn treeValueExpr(self: *Session, value: Value) Error!Expr.NodeId {
        const snapshot = self.tree_version;
        var spec = try tree.flatten(self.allocator, self.ctx, snapshot, value, tree.Limits.gradient);
        defer spec.deinit();
        if (spec.registry != self.tree_version) return error.Denied;
        try self.checkCurrent();
        return self.treeNodeExpr(&spec, spec.root, 0);
    }

    fn treeNodeExpr(
        self: *Session,
        spec: *const tree.TreeSpec,
        id: tree.NodeId,
        depth: usize,
    ) Error!Expr.NodeId {
        if (depth >= spec.limits.max_depth) return error.Exhausted;
        try self.step(1, 1);
        const node = spec.node(id);
        return switch (node.kind) {
            .scalar => {
                if (node.leaves.len != 1) return error.InvalidShape;
                return (try self.valueExpr(spec.leaves[node.leaves.begin()].primal)) orelse error.Unsupported;
            },
            .list => blk: {
                const children = spec.children(node);
                const elements = try self.allocator.alloc(Expr.NodeId, children.len);
                for (children, 0..) |child, index| {
                    elements[index] = try self.treeNodeExpr(spec, child, depth + 1);
                }
                break :blk try self.region.intern(self.ctx, .{ .list = .{
                    .elements = elements,
                    .domain = .structured,
                } });
            },
            .map => blk: {
                const children = spec.children(node);
                const keys = spec.keys(node);
                if (children.len != keys.len) return error.InvalidShape;
                const labels = try self.allocator.alloc([]const u8, keys.len);
                const values = try self.allocator.alloc(Expr.NodeId, children.len);
                for (keys, children, 0..) |key, child, index| {
                    const bytes = switch (key.typ) {
                        b.type_symbol, b.type_keyword => key.obj.toPtr(Sym).*,
                        else => return error.TypeMismatch,
                    };
                    const prefix: u8 = if (key.typ == b.type_symbol) '\'' else ':';
                    labels[index] = try std.fmt.allocPrint(self.allocator, "{c}{s}", .{ prefix, bytes });
                    values[index] = try self.treeNodeExpr(spec, child, depth + 1);
                }
                break :blk try self.region.intern(self.ctx, .{ .map = .{
                    .labels = labels,
                    .values = values,
                    .domain = .structured,
                } });
            },
            .tensor => |tensor| blk: {
                const elements = try self.allocator.alloc(Expr.NodeId, node.leaves.len);
                const leaves = spec.leaves[node.leaves.begin()..node.leaves.end()];
                for (leaves, 0..) |leaf, index| {
                    elements[index] = (try self.valueExpr(leaf.primal)) orelse return error.Unsupported;
                }
                const shape = try self.allocator.alloc(u32, spec.tensorShape(tensor).len);
                @memcpy(shape, spec.tensorShape(tensor));
                const dtype: Expr.DType = switch (tensor.inner) {
                    .i64 => .i64,
                    .f64 => .f64,
                    else => .unknown,
                };
                break :blk try self.region.intern(self.ctx, .{ .tensor = .{
                    .dtype = dtype,
                    .shape = shape,
                    .elements = elements,
                    .domain = .structured,
                } });
            },
            .custom => |custom| try self.treeCustomExpr(spec, node, custom, depth),
        };
    }

    fn treeCustomExpr(
        self: *Session,
        spec: *const tree.TreeSpec,
        node: *const tree.Node,
        custom: tree.CustomNode,
        depth: usize,
    ) Error!Expr.NodeId {
        const type_ptr = self.ctx.runtime.typePtrFromObj(node.runtime_type);
        const type_label = type_ptr.name.toPtr(Sym).*;
        var type_index: ?usize = null;
        for (spec.registry.specs, 0..) |registered, index| {
            if (registered.runtime_type == node.runtime_type) {
                type_index = index;
                break;
            }
        }
        const index = type_index orelse return error.Denied;
        const children = spec.children(node);
        const child_nodes = try self.allocator.alloc(Expr.NodeId, children.len);
        for (children, 0..) |child, child_index| {
            child_nodes[child_index] = try self.treeNodeExpr(spec, child, depth + 1);
        }
        const children_node = try self.region.intern(self.ctx, .{ .list = .{
            .elements = child_nodes,
            .domain = .structured,
        } });
        const metadata_node = (try self.valueExpr(custom.metadata)) orelse return error.Unsupported;
        const fields = try self.allocator.alloc(Expr.NodeId, 5);
        fields[0] = (try self.valueExpr(Value.u64(spec.registry.version))) orelse return error.Unsupported;
        fields[1] = (try self.valueExpr(Value.u64(@intCast(index)))) orelse return error.Unsupported;
        fields[2] = (try self.valueExpr(Value.u64(custom.implementation_revision))) orelse return error.Unsupported;
        fields[3] = metadata_node;
        fields[4] = children_node;
        const labels = try self.allocator.alloc([]const u8, 5);
        labels[0] = "tree-registry-version";
        labels[1] = "tree-type-index";
        labels[2] = "implementation-revision";
        labels[3] = "static-metadata";
        labels[4] = "children";
        return self.region.intern(self.ctx, .{ .record = .{
            .type_label = type_label,
            .field_labels = labels,
            .fields = fields,
            .domain = .structured,
        } });
    }
};
fn nodeDomain(node: Expr.Node) Expr.Domain {
    return switch (node.kind) {
        .scalar => |value| value.domain,
        .static_atom => .structured,
        .free_variable => |value| value.domain,
        .primitive_call => |value| value.domain,
        .conditional => |value| value.domain,
        .opaque_call => |value| value.domain,
        .list => |value| value.domain,
        .map => |value| value.domain,
        .tensor => |value| value.domain,
        .record => |value| value.domain,
    };
}

fn valueDomain(value: Value) Expr.Domain {
    return switch (value.typ) {
        b.type_f16, b.type_f32, b.type_f64 => .real,
        b.type_i8, b.type_i16, b.type_i32, b.type_i64 => .signed_integer,
        b.type_u8, b.type_u16, b.type_u32, b.type_u64 => .unsigned_integer,
        b.type_bool => .boolean,
        else => .structured,
    };
}

fn slotDomain(session: *Session, slot: Slot) Error!Expr.Domain {
    return switch (slot) {
        .expression => |expression| nodeDomain(try session.region.checkedNode(expression.node)),
        .concrete => |value| valueDomain(value),
        .empty, .closure, .results => .structured,
    };
}

fn requireScalarSlots(session: *Session, arguments: []const Slot) Error!void {
    for (arguments) |argument| switch (try slotDomain(session, argument)) {
        .real, .signed_integer, .unsigned_integer => {},
        .unknown, .boolean, .structured => return error.Unsupported,
    };
}

fn slotExpr(session: *Session, slot: Slot) Error!Expr.NodeId {
    return switch (slot) {
        .expression => |node| node.node,
        .concrete => |value| (try session.valueExpr(value)) orelse error.Unsupported,
        .empty, .closure, .results => error.Unsupported,
    };
}

fn slotEqual(left: Slot, right: Slot) bool {
    return switch (left) {
        .expression => |node| switch (right) {
            .expression => |other| node.node == other.node,
            else => false,
        },
        .concrete => |value| switch (right) {
            .concrete => |other| value.typ == other.typ and value.obj == other.obj,
            else => false,
        },
        .closure => |closure| switch (right) {
            .closure => |other| closure == other,
            else => false,
        },
        .empty => right == .empty,
        .results => false,
    };
}

fn scalarIdentity(session: *Session) Error!Expr.PrimitiveIdentity {
    const scalar_primitive = session.ctx.registry.idForNative(&rules.scalarDispatch) orelse return error.Unsupported;
    const spec = session.ctx.registry.spec(scalar_primitive) orelse return error.Unsupported;
    const rule = session.rule_version.find(scalar_primitive) orelse return error.Unsupported;
    return .{
        .primitive = scalar_primitive,
        .registry_revision = session.ctx.registry.version,
        .implementation_revision = spec.implementation_revision,
        .rule_revision = rule.rule_revision,
    };
}

fn scalarOpForRule(rule: rules.BuiltinJvp) ?rules.ScalarOp {
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

fn scalarExpr(
    session: *Session,
    operation: rules.ScalarOp,
    arguments: []const Slot,
) Error!Slot {
    const arity = rules.scalarOperationArity(operation);
    if (arguments.len != arity) return error.ArityMismatch;
    try requireScalarSlots(session, arguments);
    const operands = try session.allocator.alloc(Expr.NodeId, arguments.len + 1);
    operands[0] = try session.internScalar(.{ .signed = @backingInt(operation) }, .signed_integer);
    for (arguments, 0..) |argument, index| operands[index + 1] = try slotExpr(session, argument);
    const node = try session.region.intern(session.ctx, .{ .primitive_call = .{
        .identity = try scalarIdentity(session),
        .arguments = operands,
        .domain = .real,
    } });
    return .{ .expression = .{ .node = node } };
}

fn hashOpaque(
    tag: u64,
    first: u64,
    second: u64,
    third: u64,
    revision: u64,
) Expr.OpaqueIdentity {
    var hasher = std.hash.Fnv1a_64.init();
    var values = [_]u64{ tag, first, second, third, revision };
    hasher.update(std.mem.sliceAsBytes(values[0..]));
    return .{ .id = hasher.final() | 1, .revision = revision | 1 };
}

fn opaqueSlot(
    session: *Session,
    frame: *const Frame,
    site: u64,
    callee: ?Slot,
    arguments: []const Slot,
    domain: Expr.Domain,
    display_label: []const u8,
    primitive: ?Primitive.PrimitiveId,
) Error!Slot {
    const nodes = try session.allocator.alloc(Expr.NodeId, arguments.len);
    for (arguments, 0..) |argument, index| nodes[index] = try slotExpr(session, argument);
    var first: u64 = frame.callable.code.id;
    var second: u64 = frame.callable.code.revision;
    var third: u64 = site;
    var identity_revision: u64 = frame.callable.code.revision;
    if (primitive) |primitive_id| {
        if (session.ctx.registry.spec(primitive_id)) |spec| {
            first = @backingInt(primitive_id);
            second = session.ctx.registry.version;
            third ^= spec.implementation_revision;
            identity_revision = spec.implementation_revision;
            if (session.rule_version.find(primitive_id)) |rule| {
                third ^= rule.rule_revision;
            }
        }
    }
    if (callee) |target| switch (target) {
        .expression => |expression| third ^= @backingInt(expression.node),
        .concrete => |value| {
            third ^= @backingInt(value.typ);
            if (value.typ == b.type_method and value.obj != .null) {
                const method = value.obj.toRef().deref(skript.data.Method);
                first = method.id;
                second = method.revision;
                identity_revision = method.revision;
            } else if (value.typ == b.type_intrinsic) {
                // Native function pointers are lookup-only. Never persist
                // their address in an expression identity.
                if (primitiveIdForValue(session.ctx, value)) |primitive_id| {
                    if (session.ctx.registry.spec(primitive_id)) |spec| {
                        first = @backingInt(primitive_id);
                        second = session.ctx.registry.version;
                        third ^= spec.implementation_revision;
                        identity_revision = spec.implementation_revision;
                        if (session.rule_version.find(primitive_id)) |rule| {
                            third ^= rule.rule_revision;
                        }
                    }
                }
            }
        },
        .closure => |bound| {
            first = bound.code.id;
            second = bound.code.revision;
            third ^= @backingInt(bound.function);
            identity_revision = bound.code.revision;
        },
        .results => |results| third ^= @intCast(results.len),
        .empty => {},
    };
    const node = try session.region.intern(session.ctx, .{ .opaque_call = .{
        .identity = hashOpaque(0x53594D, first, second, third, identity_revision),
        .display_label = display_label,
        .arguments = nodes,
        .domain = domain,
        .effects = .unknown,
        .linearity = .unknown,
    } });
    return .{ .expression = .{ .node = node } };
}

fn listExpr(session: *Session, arguments: []const Slot) Error!Slot {
    const elements = try session.allocator.alloc(Expr.NodeId, arguments.len);
    try session.step(@intCast(arguments.len), 0);
    for (arguments, 0..) |argument, index| elements[index] = try slotExpr(session, argument);
    const node = try session.region.intern(
        session.ctx,
        .{ .list = .{ .elements = elements } },
    );
    return .{ .expression = .{ .node = node } };
}

fn mapExpr(session: *Session, arguments: []const Slot) Error!Slot {
    if (arguments.len % 2 != 0) return error.ArityMismatch;
    const labels = try session.allocator.alloc([]const u8, arguments.len / 2);
    const values = try session.allocator.alloc(Expr.NodeId, arguments.len / 2);
    try session.step(@intCast(arguments.len), 0);
    var pair: usize = 0;
    while (pair < arguments.len) : (pair += 2) {
        const key_node = try slotExpr(session, arguments[pair]);
        const key_value = try session.region.checkedNode(key_node);
        const atom = switch (key_value.kind) {
            .static_atom => |value| value,
            else => return error.TypeMismatch,
        };
        const bytes = switch (atom.kind) {
            .symbol, .keyword => blk: {
                var reader = try session.region.acquire(session.ctx);
                defer reader.deinit();
                break :blk try reader.name(atom.name);
            },
            else => return error.TypeMismatch,
        };
        const prefix: u8 = switch (atom.kind) {
            .symbol => '\'',
            .keyword => ':',
            else => unreachable,
        };
        labels[pair / 2] = try std.fmt.allocPrint(session.allocator, "{c}{s}", .{ prefix, bytes });
        values[pair / 2] = try slotExpr(session, arguments[pair + 1]);
    }
    return .{ .expression = .{ .node = try session.region.intern(session.ctx, .{
        .map = .{
            .labels = labels,
            .values = values,
        },
    }) } };
}

fn tensorExpr(session: *Session, arguments: []const Slot) Error!Slot {
    const elements = try session.allocator.alloc(Expr.NodeId, arguments.len);
    try session.step(@intCast(arguments.len), 0);
    for (arguments, 0..) |argument, index| elements[index] = try slotExpr(session, argument);
    return .{ .expression = .{ .node = try session.region.intern(session.ctx, .{ .tensor = .{
        .dtype = .unknown,
        .shape = &.{@intCast(arguments.len)},
        .elements = elements,
    } }) } };
}

fn isNative(spec: *const Primitive.Spec, pointer: skript.FuncPtr) bool {
    return switch (spec.invoke) {
        .native => |native| native == pointer,
        .closure => false,
    };
}

fn primitiveSlot(
    session: *Session,
    frame: *const Frame,
    node_id: Code.BoundNodeId,
    primitive: Primitive.PrimitiveId,
    arguments: []const Slot,
) Error!Slot {
    if (session.ctx.registry.idForNative(&rules.scalarDispatch)) |scalar_primitive| {
        if (primitive == scalar_primitive) {
            if (arguments.len < 1) return error.ArityMismatch;
            const tag = switch (arguments[0]) {
                .concrete => |value| if (value.typ == b.type_i64) value.obj.toInt(i64) else return error.TypeMismatch,
                else => return opaqueSlot(
                    session,
                    frame,
                    @backingInt(node_id),
                    null,
                    arguments,
                    .unknown,
                    "autodiff.scalar",
                    primitive,
                ),
            };
            if (tag < @backingInt(rules.ScalarOp.add) or tag > @backingInt(rules.ScalarOp.realize_tangent)) {
                return error.TypeMismatch;
            }
            return scalarExpr(session, @fromBackingInt(@intCast(tag)), arguments[1..]);
        }
    }
    const spec = session.ctx.registry.spec(primitive) orelse
        return opaqueSlot(session, frame, @backingInt(node_id), null, arguments, .unknown, "primitive", primitive);
    const descriptor = rules.descriptorForInvocation(spec.invoke) orelse
        return opaqueSlot(
            session,
            frame,
            @backingInt(node_id),
            null,
            arguments,
            .unknown,
            spec.stable_name,
            primitive,
        );
    if (scalarOpForRule(descriptor.rule)) |operation| {
        return scalarExpr(session, operation, arguments);
    }
    if (isNative(spec, &skript.intrinsics.list.list)) return listExpr(session, arguments);
    if (isNative(spec, &skript.intrinsics.map.create)) return mapExpr(session, arguments);
    if (isNative(spec, &skript.intrinsics.tensor.create)) return tensorExpr(session, arguments);
    return opaqueSlot(session, frame, @backingInt(node_id), null, arguments, .unknown, spec.stable_name, primitive);
}

fn primitiveIdForValue(
    ctx: *EvalContext,
    value: Value,
) ?Primitive.PrimitiveId {
    if (value.typ != b.type_intrinsic or value.obj == .null) return null;
    const pointer = value.obj.toPtr(skript.FuncPtr);
    var found: ?Primitive.PrimitiveId = null;
    for (ctx.registry.specs) |spec| {
        const native = switch (spec.invoke) {
            .native => |candidate| candidate,
            .closure => continue,
        };
        if (native != pointer) continue;
        if (found != null) return null;
        found = spec.id;
    }
    return found;
}

fn invokeActual(
    session: *Session,
    frame: *const Frame,
    node_id: Code.BoundNodeId,
    callee: Slot,
    arguments: []const Slot,
) Error!Slot {
    switch (callee) {
        .closure => |bound| {
            const result = try runClosure(session, bound, arguments);
            try session.checkCurrent();
            return result;
        },
        .concrete => |value| {
            if (primitiveIdForValue(session.ctx, value)) |primitive| {
                return primitiveSlot(session, frame, node_id, primitive, arguments);
            }
            if (value.typ == b.type_method and value.obj != .null) {
                var concrete = try session.allocator.alloc(Value, arguments.len);
                defer session.allocator.free(concrete);
                for (arguments, 0..) |argument, index| {
                    concrete[index] = switch (argument) {
                        .concrete => |known| known,
                        else => return opaqueSlot(
                            session,
                            frame,
                            @backingInt(node_id),
                            callee,
                            arguments,
                            .unknown,
                            "method",
                            null,
                        ),
                    };
                }
                try session.checkCallDepth();
                const dispatched = try value.obj.toRef().deref(skript.data.Method).get(
                    session.ctx.runtime,
                    concrete,
                );
                try session.checkCurrent();
                return invokeActual(session, frame, node_id, .{ .concrete = dispatched }, arguments);
            }
        },
        else => {},
    }
    return opaqueSlot(
        session,
        frame,
        @backingInt(node_id),
        callee,
        arguments,
        .unknown,
        "opaque",
        null,
    );
}

fn sameConcreteValue(left: Value, right: Value) bool {
    return left.typ == right.typ and left.obj == right.obj;
}
fn blockAt(code: *const Code.Code, id: Code.BlockId) Error!*const Code.Block {
    const index = @backingInt(id);
    if (index >= code.blocks.len) return error.InvalidCode;
    return &code.blocks[index];
}

fn nodeAt(code: *const Code.Code, id: Code.BoundNodeId) Error!*const Code.Node {
    const index = @backingInt(id);
    if (index >= code.nodes.len) return error.InvalidCode;
    return &code.nodes[index];
}

fn functionAt(code: *const Code.Code, id: Code.FunctionId) Error!*const Code.Function {
    const function = code.function(id) orelse return error.InvalidCode;
    if (function.has_rest) return error.Unsupported;
    return function;
}

fn functionEntry(code: *const Code.Code, id: Code.FunctionId) Error!Code.BlockId {
    const function = try functionAt(code, id);
    const start: usize = function.block_start;
    if (start >= code.function_blocks.len) return error.InvalidCode;
    return code.function_blocks[start];
}

fn bindingValue(
    code: *const Code.Code,
    function: Code.FunctionId,
    binding: Code.BindingId,
) Error!Code.ValueId {
    const index = @backingInt(binding);
    if (index >= code.bindings.len) return error.InvalidCode;
    const definition = code.bindings[index];
    if (definition.function == function) return definition.value;
    const info = try functionAt(code, function);
    const start: usize = info.capture_start;
    const end = start + @as(usize, info.capture_count);
    if (end > code.captures.len or end > code.capture_values.len) return error.InvalidCode;
    for (code.captures[start..end], code.capture_values[start..end]) |captured, value| {
        if (captured == binding) return value;
    }
    return error.InvalidCode;
}

fn valueSlot(frame: *const Frame, value: Code.ValueId) Error!Slot {
    const index = @backingInt(value);
    if (index >= frame.slots.len) return error.InvalidCode;
    return frame.slots[index];
}

fn putValue(frame: *Frame, value: Code.ValueId, slot: Slot) Error!void {
    const index = @backingInt(value);
    if (index >= frame.slots.len) return error.InvalidCode;
    frame.slots[index] = slot;
}

fn copySlots(session: *Session, source: []const Slot) Error![]Slot {
    try session.step(@intCast(source.len), 0);
    const copy = try session.allocator.alloc(Slot, source.len);
    @memcpy(copy, source);
    return copy;
}

fn childClosure(
    session: *Session,
    frame: *const Frame,
    function: Code.FunctionId,
    captures: []const Slot,
) Error!*BoundClosure {
    const info = try functionAt(frame.callable.code, function);
    if (captures.len != info.capture_count) return error.InvalidCode;
    const copied = try copySlots(session, captures);
    const child = try session.allocator.create(BoundClosure);
    child.* = .{
        .code = frame.callable.code,
        .function = function,
        .closure = null,
        .captures = copied,
        .namespace = frame.namespace,
        .guard = frame.callable.guard,
        .guard_arguments_checked = true,
    };
    return child;
}

fn captureFromFunction(
    session: *Session,
    frame: *const Frame,
    function: Code.FunctionId,
) Error![]Slot {
    const info = try functionAt(frame.callable.code, function);
    const start: usize = info.capture_start;
    const end = start + @as(usize, info.capture_count);
    if (end > frame.callable.code.captures.len) return error.InvalidCode;
    const result = try session.allocator.alloc(Slot, info.capture_count);
    try session.step(@intCast(info.capture_count), 0);
    for (frame.callable.code.captures[start..end], 0..) |binding, index| {
        const value = try bindingValue(frame.callable.code, frame.function, binding);
        result[index] = try valueSlot(frame, value);
    }
    return result;
}

fn resolveRunResult(session: *Session, result: RunResult) Error!Slot {
    try session.checkCallDepth();
    return switch (result) {
        .value => |value| value,
        .tail_call => |tail| runClosure(session, tail.callable, tail.arguments),
    };
}

fn runClosure(
    session: *Session,
    callable: *BoundClosure,
    arguments: []const Slot,
) Error!Slot {
    try session.checkCallDepth();
    const base_depth = session.call_depth;
    session.call_depth = std.math.add(usize, base_depth, 1) catch return error.Exhausted;
    defer session.call_depth = base_depth;
    var current_callable = callable;
    var current_arguments = arguments;
    while (true) {
        try session.enterHost();
        // SAFETY: result is assigned by runBlock before this scope ends.
        var result: RunResult = undefined;
        {
            defer session.leaveHost();
            try session.enterClosure(current_callable, current_arguments);
            const active: ActiveClosure = .{
                .code = current_callable.code,
                .function = current_callable.function,
                .captures = current_callable.captures,
                .namespace = current_callable.namespace,
                .guard = current_callable.guard,
            };
            const info = try functionAt(active.code, active.function);
            if (current_arguments.len != info.parameter_count) return error.ArityMismatch;
            const slots = try session.allocator.alloc(Slot, active.code.values.len);
            @memset(slots, .empty);
            try session.step(@intCast(active.code.values.len), 0);
            const frame = try session.allocator.create(Frame);
            frame.* = .{
                .callable = &active,
                .function = active.function,
                .namespace = active.namespace,
                .slots = slots,
            };
            const parameter_start: usize = info.parameter_start;
            const parameter_end = parameter_start + @as(usize, info.parameter_count);
            if (parameter_end > active.code.parameters.len) return error.InvalidCode;
            try session.step(@intCast(info.parameter_count), 0);
            for (
                active.code.parameters[parameter_start..parameter_end],
                current_arguments,
            ) |binding, argument| {
                try putValue(frame, try bindingValue(active.code, active.function, binding), argument);
            }
            const capture_start: usize = info.capture_start;
            const capture_end = capture_start + @as(usize, info.capture_count);
            if (capture_end > active.code.capture_values.len or
                current_callable.captures.len != info.capture_count)
            {
                return error.InvalidCode;
            }
            try session.step(@intCast(info.capture_count), 0);
            for (
                active.code.capture_values[capture_start..capture_end],
                current_callable.captures,
            ) |value, capture| {
                try putValue(frame, value, capture);
            }
            result = try runBlock(session, frame, try functionEntry(active.code, active.function));
        }
        switch (result) {
            .value => |value| return value,
            .tail_call => |tail| {
                session.call_depth = std.math.add(usize, session.call_depth, 1) catch return error.Exhausted;
                try session.checkCallDepth();
                current_callable = tail.callable;
                current_arguments = tail.arguments;
            },
        }
    }
}

fn transferEdge(session: *Session, frame: *Frame, edge: Code.Edge) Error!void {
    const target = try blockAt(frame.callable.code, edge.target);
    if (edge.args.len != target.param_count) return error.InvalidCode;
    const arg_start: usize = edge.args.start;
    const arg_end = arg_start + @as(usize, edge.args.len);
    if (arg_end > frame.callable.code.operands.len) return error.InvalidCode;
    const param_start: usize = target.param_start;
    const param_end = param_start + @as(usize, target.param_count);
    if (param_end > frame.callable.code.block_parameters.len) return error.InvalidCode;
    const values = try session.allocator.alloc(Slot, edge.args.len);
    try session.step(@intCast(edge.args.len), 0);
    for (frame.callable.code.operands[arg_start..arg_end], 0..) |source, index| {
        values[index] = try valueSlot(frame, source);
    }
    for (values, frame.callable.code.block_parameters[param_start..param_end]) |
        value,
        target_value,
    | {
        try putValue(frame, target_value, value);
    }
}

fn runEdge(session: *Session, frame: *Frame, edge: Code.Edge) Error!RunResult {
    try transferEdge(session, frame, edge);
    return runBlock(session, frame, edge.target);
}

fn conditionalSlot(
    session: *Session,
    predicate: Slot,
    then_value: Slot,
    else_value: Slot,
) Error!Slot {
    if (then_value == .results or else_value == .results) {
        if (then_value != .results or else_value != .results) return error.InvalidCode;
        if (then_value.results.len != else_value.results.len) return error.InvalidCode;
        const results = try session.allocator.alloc(Slot, then_value.results.len);
        for (then_value.results, else_value.results, results) |yes, no, *result| {
            result.* = try conditionalSlot(session, predicate, yes, no);
        }
        return .{ .results = results };
    }
    if (slotEqual(then_value, else_value)) return then_value;
    const predicate_node = try slotExpr(session, predicate);
    const then_node = try slotExpr(session, then_value);
    const else_node = try slotExpr(session, else_value);
    const then_domain = try slotDomain(session, then_value);
    const else_domain = try slotDomain(session, else_value);
    const domain: Expr.Domain = if (then_domain == else_domain) then_domain else .unknown;
    const node = try session.region.intern(session.ctx, .{ .conditional = .{
        .predicate = predicate_node,
        .then_branch = then_node,
        .else_branch = else_node,
        .domain = domain,
    } });
    return .{ .expression = .{ .node = node } };
}

fn runBlock(session: *Session, frame: *Frame, block_id: Code.BlockId) Error!RunResult {
    try session.enterHost();
    defer session.leaveHost();
    var current_block = block_id;
    while (true) {
        try session.step(1, 0);
        const block = try blockAt(frame.callable.code, current_block);
        const node_start: usize = block.node_start;
        const node_end = node_start + @as(usize, block.node_count);
        if (node_end > frame.callable.code.block_nodes.len) return error.InvalidCode;
        for (frame.callable.code.block_nodes[node_start..node_end]) |node_id| {
            try executeNode(session, frame, try nodeAt(frame.callable.code, node_id));
        }
        switch (block.terminator) {
            .return_values => |range| {
                const start: usize = range.start;
                const end = start + @as(usize, range.len);
                if (end > frame.callable.code.operands.len) return error.InvalidCode;
                const results = try collectSlots(session, frame, frame.callable.code.operands[start..end]);
                return .{ .value = if (results.len == 1) results[0] else .{ .results = results } };
            },
            .jump => |edge| {
                try transferEdge(session, frame, edge);
                current_block = edge.target;
            },
            .branch => |branch| {
                const predicate = try valueSlot(frame, branch.condition);
                switch (predicate) {
                    .concrete => |value| {
                        const edge = if (Value.isTruthy(value)) branch.then_edge else branch.else_edge;
                        try transferEdge(session, frame, edge);
                        current_block = edge.target;
                    },
                    .expression => {
                        if (session.branch_depth >= max_branch_depth) return error.Exhausted;
                        session.branch_depth += 1;
                        defer session.branch_depth -= 1;
                        const then_slots = try copySlots(session, frame.slots);
                        const else_slots = try copySlots(session, frame.slots);
                        var then_frame = frame.*;
                        then_frame.slots = then_slots;
                        var else_frame = frame.*;
                        else_frame.slots = else_slots;
                        const then_value = try resolveRunResult(
                            session,
                            try runEdge(session, &then_frame, branch.then_edge),
                        );
                        const else_value = try resolveRunResult(
                            session,
                            try runEdge(session, &else_frame, branch.else_edge),
                        );
                        return .{ .value = try conditionalSlot(
                            session,
                            predicate,
                            then_value,
                            else_value,
                        ) };
                    },
                    .closure => {
                        try transferEdge(session, frame, branch.then_edge);
                        current_block = branch.then_edge.target;
                    },
                    .empty, .results => return error.InvalidCode,
                }
            },
            .raise => return error.Unsupported,
            .tail_call => |call| {
                const callee = try valueSlot(frame, call.callee);
                const start: usize = call.args.start;
                const end = start + @as(usize, call.args.len);
                if (end > frame.callable.code.operands.len) return error.InvalidCode;
                const arguments = try session.allocator.alloc(Slot, call.args.len);
                for (frame.callable.code.operands[start..end], 0..) |value, index| {
                    arguments[index] = try valueSlot(frame, value);
                }
                switch (callee) {
                    .closure => |bound| return .{ .tail_call = .{
                        .callable = bound,
                        .arguments = arguments,
                    } },
                    else => {
                        const site: Code.BoundNodeId = @fromBackingInt(@intCast(@backingInt(current_block)));
                        return .{ .value = try invokeActual(session, frame, site, callee, arguments) };
                    },
                }
            },
            .none => return error.InvalidCode,
        }
    }
}

fn executeNode(session: *Session, frame: *Frame, node: *const Code.Node) Error!void {
    try session.step(1, 0);
    const result = node.result;
    const operation = node.operation;
    const slot: ?Slot = switch (operation) {
        .literal => |value| try session.slotFromValue(value),
        .quote => |value| try session.slotFromValue(value),
        .local_read => |binding| try valueSlot(frame, try bindingValue(frame.callable.code, frame.function, binding)),
        .global_read => |global| blk: {
            const index = @backingInt(global);
            if (index >= frame.callable.code.globals.len) return error.InvalidCode;
            const dependency = try session.ctx.runtime.readDependency(
                frame.namespace,
                frame.callable.code.globals[index].name,
            );
            break :blk try session.slotFromValue(dependency.value);
        },
        .global_write => return error.Denied,
        .primitive_call => |call| blk: {
            const start: usize = call.args.start;
            const end = start + @as(usize, call.args.len);
            if (end > frame.callable.code.operands.len) return error.InvalidCode;
            break :blk try primitiveSlot(
                session,
                frame,
                node.id,
                call.primitive,
                try collectSlots(session, frame, frame.callable.code.operands[start..end]),
            );
        },
        .arithmetic => |arith| blk: {
            const left = try valueSlot(frame, arith.left);
            const right = try valueSlot(frame, arith.right);
            if (arith.callee != .invalid) {
                const actual = try valueSlot(frame, arith.callee);
                const matches = switch (actual) {
                    .concrete => |value| sameConcreteValue(value, arith.expected_callee),
                    else => false,
                };
                if (!matches) {
                    break :blk try invokeActual(
                        session,
                        frame,
                        node.id,
                        actual,
                        &.{ left, right },
                    );
                }
            }
            break :blk switch (arith.op) {
                .add => try scalarExpr(session, .add, &.{ left, right }),
                .sub => try scalarExpr(session, .sub, &.{ left, right }),
                .mul => try scalarExpr(session, .mul, &.{ left, right }),
                .div => try scalarExpr(session, .div, &.{ left, right }),
                .equal => try opaqueSlot(
                    session,
                    frame,
                    @backingInt(node.id),
                    .{ .concrete = arith.expected_callee },
                    &.{ left, right },
                    .boolean,
                    "equal",
                    null,
                ),
                .less => try opaqueSlot(
                    session,
                    frame,
                    @backingInt(node.id),
                    .{ .concrete = arith.expected_callee },
                    &.{ left, right },
                    .boolean,
                    "less",
                    null,
                ),
                .greater => try opaqueSlot(
                    session,
                    frame,
                    @backingInt(node.id),
                    .{ .concrete = arith.expected_callee },
                    &.{ left, right },
                    .boolean,
                    "greater",
                    null,
                ),
            };
        },
        .dynamic_call => |call| blk: {
            const callee = try valueSlot(frame, call.callee);
            const start: usize = call.args.start;
            const end = start + @as(usize, call.args.len);
            if (end > frame.callable.code.operands.len) return error.InvalidCode;
            const arguments = try collectSlots(session, frame, frame.callable.code.operands[start..end]);
            break :blk try invokeActual(
                session,
                frame,
                node.id,
                callee,
                arguments,
            );
        },
        .direct_call => |call| blk: {
            const captures = try captureFromFunction(session, frame, call.function);
            const child = try childClosure(session, frame, call.function, captures);
            const start: usize = call.args.start;
            const end = start + @as(usize, call.args.len);
            if (end > frame.callable.code.operands.len) return error.InvalidCode;
            const arguments = try collectSlots(
                session,
                frame,
                frame.callable.code.operands[start..end],
            );
            break :blk try runClosure(session, child, arguments);
        },
        .make_closure => |closure| blk: {
            const start: usize = closure.captures.start;
            const end = start + @as(usize, closure.captures.len);
            if (end > frame.callable.code.operands.len) return error.InvalidCode;
            const child = try childClosure(
                session,
                frame,
                closure.function,
                try collectSlots(session, frame, frame.callable.code.operands[start..end]),
            );
            break :blk .{ .closure = child };
        },
        .try_begin, .try_end => null,
        .ns_push, .ns_pop => return error.Unsupported,
    };
    if (slot) |value| {
        if (result == .invalid) return error.InvalidCode;
        if (value == .results) {
            if (value.results.len != node.resultCount()) return error.InvalidCode;
            for (value.results, 0..) |item, index| {
                try putValue(frame, @fromBackingInt(@intCast(@backingInt(result) + index)), item);
            }
        } else {
            if (node.resultCount() != 1) return error.InvalidCode;
            try putValue(frame, result, value);
        }
    }
}

fn collectSlots(session: *Session, frame: *const Frame, values: []const Code.ValueId) Error![]Slot {
    const result = try session.allocator.alloc(Slot, values.len);
    try session.step(@intCast(values.len), 0);
    for (values, 0..) |value, index| result[index] = try valueSlot(frame, value);
    return result;
}

pub fn evaluate(
    ctx: *EvalContext,
    region: *Expr.Region,
    callable: Value,
    arguments: []const Argument,
) Error!Expr.Handle {
    const scope = ctx.activate();
    defer scope.deinit();

    var arena = std.heap.ArenaAllocator.init(ctx.scratch);
    defer arena.deinit();
    var session = try Session.init(arena.allocator(), ctx, region);
    defer session.deinit();

    const bound = try session.bindClosure(callable);
    const values = try session.allocator.alloc(Slot, arguments.len);
    try session.step(@intCast(arguments.len), 0);
    for (arguments, 0..) |argument, index| {
        values[index] = switch (argument) {
            .constant => |value| try session.slotFromValue(value),
            .expression => |expression| .{ .expression = .{
                .node = try session.copyHandle(&expression.handle),
                .guard_value = expression.guard_value,
            } },
        };
    }
    const result = try runClosure(&session, bound, values);
    try session.checkCurrent();
    const node = try slotExpr(&session, result);
    try session.checkCurrent();
    return region.handle(ctx, node);
}

/// Copy an existing expression into `region` without reparsing its datum.
/// Free-variable identities and node metadata are preserved.
pub fn copyToRegion(
    ctx: *EvalContext,
    region: *Expr.Region,
    handle: *const Expr.Handle,
) Error!Expr.NodeId {
    const scope = ctx.activate();
    defer scope.deinit();

    var arena = std.heap.ArenaAllocator.init(ctx.scratch);
    defer arena.deinit();
    var session = try Session.init(arena.allocator(), ctx, region);
    defer session.deinit();
    const result = try session.copyHandle(handle);
    try session.checkCurrent();
    return result;
}

/// Lift an ordinary runtime value into an expression node. Values that are
/// not representable by the symbolic domain return `Unsupported`.
pub fn liftValue(
    ctx: *EvalContext,
    region: *Expr.Region,
    value: Value,
) Error!Expr.NodeId {
    const scope = ctx.activate();
    defer scope.deinit();

    var arena = std.heap.ArenaAllocator.init(ctx.scratch);
    defer arena.deinit();
    var session = try Session.init(arena.allocator(), ctx, region);
    defer session.deinit();
    const result = (try session.valueExpr(value)) orelse error.Unsupported;
    try session.checkCurrent();
    return result;
}

const DatumWriter = struct {
    ctx: *EvalContext,
    snapshot: *const Expr.Snapshot,
    names: std.AutoHashMapUnmanaged(Expr.FreeVarId, []const u8) = .empty,
    used_names: std.StringHashMapUnmanaged(void) = .empty,
    next_suffix: std.StringHashMapUnmanaged(u32) = .empty,

    fn deinit(self: *DatumWriter) void {
        self.names.deinit(self.ctx.scratch);
        self.used_names.deinit(self.ctx.scratch);
        self.next_suffix.deinit(self.ctx.scratch);
        self.* = undefined;
    }

    fn chargeNameWork(self: *DatumWriter) Error!void {
        try self.ctx.charge(.{ .work = 1 }, .transform);
    }

    fn scalar(_: *DatumWriter, value: Expr.Scalar) Error!Value {
        return switch (value) {
            .f64_bits => |bits| .f64(@bitCast(bits)),
            .f32_bits => |bits| .f32(@bitCast(bits)),
            .signed => |number| .i64(number),
            .unsigned => |number| .u64(number),
            .boolean => |boolean| .bool(boolean),
        };
    }

    fn staticAtom(self: *DatumWriter, atom: Expr.StaticAtomNode) Error!Value {
        const bytes = try self.snapshot.name(atom.name);
        return switch (atom.kind) {
            .nil => .nil,
            .symbol => Value.symbol(try self.ctx.runtime.store.getsym(bytes)),
            .keyword => Value.keyword(try self.ctx.runtime.store.getsym(bytes)),
            .string => blk: {
                const stored = try self.ctx.runtime.store.allocSlice(u8, bytes.len + 1);
                @memcpy(stored.slice[0..bytes.len], bytes);
                stored.slice[bytes.len] = 0;
                break :blk Value.string(.fromPtr(stored.slice.ptr));
            },
        };
    }

    fn freeName(self: *DatumWriter, identity: Expr.FreeVarId, source: []const u8) Error![]const u8 {
        try self.chargeNameWork();
        if (self.names.get(identity)) |name| return name;

        const source_copy = try self.ctx.scratch.dupe(u8, source);
        try self.chargeNameWork();
        var suffix = self.next_suffix.get(source) orelse 1;
        var candidate: []const u8 = source_copy;
        while (true) {
            try self.chargeNameWork();
            if (!self.used_names.contains(candidate)) break;
            suffix = std.math.add(u32, suffix, 1) catch return error.Exhausted;
            candidate = try std.fmt.allocPrint(
                self.ctx.scratch,
                "{s}#{d}",
                .{ source, suffix - 1 },
            );
        }
        try self.chargeNameWork();
        try self.names.put(self.ctx.scratch, identity, candidate);
        try self.chargeNameWork();
        try self.used_names.put(self.ctx.scratch, candidate, {});
        try self.chargeNameWork();
        try self.next_suffix.put(self.ctx.scratch, source, suffix);
        return candidate;
    }

    fn list(self: *DatumWriter, values: []const Value) Error!Value {
        return skript.intrinsics.list.list(self.ctx, .nil, .nil, values);
    }

    fn call(self: *DatumWriter, name: []const u8, values: []const Value) Error!Value {
        const all = try self.ctx.scratch.alloc(Value, values.len + 1);
        all[0] = Value.symbol(try self.ctx.runtime.store.getsym(name));
        @memcpy(all[1..], values);
        return self.list(all);
    }

    fn scalarOperationName(operation: rules.ScalarOp) []const u8 {
        return switch (operation) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .neg => "neg",
            .sqrt => "sqrt",
            .sin => "sin",
            .cos => "cos",
            .tan => "tan",
            .asin => "asin",
            .acos => "acos",
            .atan => "atan",
            .sinh => "sinh",
            .cosh => "cosh",
            .tanh => "tanh",
            .asinh => "asinh",
            .acosh => "acosh",
            .atanh => "atanh",
            .exp => "exp",
            .log => "log",
            .log2 => "log2",
            .log10 => "log10",
            .pow => "pow",
            .abs_slope => "abs-slope",
            .zero_like => "zero-like",
            .one_like => "one-like",
            .coerce_tangent => "coerce-tangent",
            .realize_tangent => "realize-tangent",
        };
    }

    fn render(self: *DatumWriter, id: Expr.NodeId, depth: usize) Error!Value {
        try self.ctx.check();
        try self.ctx.charge(.{ .work = 1, .nodes = 1 }, .transform);
        if (depth > 4096 or depth > self.snapshot.nodeCount()) return error.LimitExceeded;
        const node = try self.snapshot.node(id);
        switch (node.kind) {
            .scalar => |number| return self.scalar(number.value),
            .static_atom => |atom| return self.staticAtom(atom),
            .free_variable => |variable| {
                const source = try self.snapshot.name(variable.name);
                return Value.symbol(try self.ctx.runtime.store.getsym(try self.freeName(variable.identity, source)));
            },
            .primitive_call => |invocation| {
                const old = try self.snapshot.operands(node);
                var start: usize = 0;
                var name: []const u8 = "primitive";
                const is_scalar = if (self.ctx.registry.idForNative(&rules.scalarDispatch)) |scalar_id|
                    invocation.identity.primitive == scalar_id
                else
                    false;
                if (is_scalar) {
                    if (old.len > 0) {
                        const tag_node = try self.snapshot.node(old[0]);
                        if (std.meta.activeTag(tag_node.kind) == .scalar) {
                            switch (tag_node.kind.scalar.value) {
                                .signed => |raw| {
                                    if (raw >= @backingInt(rules.ScalarOp.add) and
                                        raw <= @backingInt(rules.ScalarOp.realize_tangent))
                                    {
                                        const operation: rules.ScalarOp = @fromBackingInt(@intCast(raw));
                                        name = scalarOperationName(operation);
                                        start = 1;
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                } else if (self.ctx.registry.spec(invocation.identity.primitive)) |spec| {
                    name = spec.stable_name;
                }
                const values = try self.ctx.scratch.alloc(Value, old.len - start);
                for (old[start..], 0..) |child, index| values[index] = try self.render(child, depth + 1);
                return self.call(name, values);
            },
            .conditional => |conditional| {
                return self.call("if", &.{
                    try self.render(conditional.predicate, depth + 1),
                    try self.render(conditional.then_branch, depth + 1),
                    try self.render(conditional.else_branch, depth + 1),
                });
            },
            .opaque_call => |invocation| {
                const name = try self.snapshot.name(invocation.display_label);
                const old = try self.snapshot.operands(node);
                const values = try self.ctx.scratch.alloc(Value, old.len);
                for (old, 0..) |child, index| values[index] = try self.render(child, depth + 1);
                return self.call(name, values);
            },
            .list => {
                const old = try self.snapshot.operands(node);
                const values = try self.ctx.scratch.alloc(Value, old.len);
                for (old, 0..) |child, index| values[index] = try self.render(child, depth + 1);
                return self.list(values);
            },
            .map => |map| {
                const old = try self.snapshot.operands(node);
                if (old.len != map.labels.len) return error.InvalidShape;
                const values = try self.ctx.scratch.alloc(Value, old.len * 2);
                for (old, 0..) |child, index| {
                    const label = try self.snapshot.label(map.labels, index);
                    if (label.len < 2) return error.InvalidShape;
                    const key_name = try self.ctx.runtime.store.getsym(label[1..]);
                    values[index * 2] = if (label[0] == '\'')
                        Value.symbol(key_name)
                    else if (label[0] == ':')
                        Value.keyword(key_name)
                    else
                        return error.TypeMismatch;
                    values[index * 2 + 1] = try self.render(child, depth + 1);
                }
                return skript.intrinsics.map.create(self.ctx, .nil, .nil, values);
            },
            .tensor => |tensor| {
                const old = try self.snapshot.operands(node);
                const rendered = try self.ctx.scratch.alloc(Value, old.len);
                for (old, 0..) |child, index| rendered[index] = try self.render(child, depth + 1);
                const shape = try self.snapshot.shape(tensor.shape);
                const dimensions = try self.ctx.scratch.alloc(Value, shape.len);
                for (shape, 0..) |dimension, index| dimensions[index] = .i64(@intCast(dimension));
                const shape_list = try skript.intrinsics.list.list(self.ctx, .nil, .nil, dimensions);
                const element_list = try skript.intrinsics.list.list(self.ctx, .nil, .nil, rendered);
                const fields = try self.ctx.scratch.alloc(Value, 6);
                fields[0] = .keyword(try self.ctx.runtime.store.getsym("shape"));
                fields[1] = shape_list;
                fields[2] = .keyword(try self.ctx.runtime.store.getsym("dtype"));
                fields[3] = .symbol(try self.ctx.runtime.store.getsym(@tagName(tensor.dtype)));
                fields[4] = .keyword(try self.ctx.runtime.store.getsym("elements"));
                fields[5] = element_list;
                return skript.intrinsics.map.create(self.ctx, .nil, .nil, fields);
            },
            .record => |record| {
                const old = try self.snapshot.operands(node);
                const values = try self.ctx.scratch.alloc(Value, old.len * 2 + 2);
                values[0] = Value.symbol(try self.ctx.runtime.store.getsym("record"));
                values[1] = Value.symbol(try self.ctx.runtime.store.getsym(try self.snapshot.name(record.type_label)));
                for (old, 0..) |child, index| {
                    const label = try self.snapshot.label(record.fields, index);
                    const symbol = try self.ctx.runtime.store.getsym(label);
                    values[index * 2 + 2] = Value.keyword(symbol);
                    values[index * 2 + 3] = try self.render(child, depth + 1);
                }
                return self.list(values);
            },
        }
    }
};

pub fn toDatum(parent_ctx: *EvalContext, handle: *const Expr.Handle) Error!Value {
    var arena = std.heap.ArenaAllocator.init(parent_ctx.scratch);
    defer arena.deinit();
    var context = parent_ctx.*;
    context.scratch = arena.allocator();
    const ctx = &context;
    const scope = ctx.activate();
    defer scope.deinit();
    try ctx.check();
    var snapshot = try handle.snapshot(ctx.scratch, ctx, .{});
    defer snapshot.deinit();
    var writer: DatumWriter = .{ .ctx = ctx, .snapshot = &snapshot };
    defer writer.deinit();
    return writer.render(snapshot.root(), 0);
}
const CompileGuard = struct {
    runtime: *Runtime,
    registry: *const Primitive.RegistryVersion,
    rules_version: *const rules.RegistryVersion,
    tree_version: *const tree.RegistryVersion,
    code: *const Code.Code,
    argument_count: usize,
};

fn traceCompileGuard(context: *const anyopaque, visitor: *skript.Store.MarkVisitor) anyerror!void {
    const guard: *const CompileGuard = @ptrCast(@alignCast(context));
    try callables.traceCodeGraph(guard.code, visitor);
}

fn checkCompileGuard(runtime: *Runtime, state: *const anyopaque) Error!void {
    const guard: *const CompileGuard = @ptrCast(@alignCast(state));
    if (runtime != guard.runtime) return error.Denied;
    const ctx = runtime.context();
    try ctx.check();
    if (ctx.registry != guard.registry) return error.Denied;
    if (runtime.intrinsics.registryVersion() != guard.registry) return error.Denied;
    if (!guard.rules_version.validFor(guard.registry)) return error.Denied;
    const owner = if (runtime.ad_rules) |*rule_owner| rule_owner else return error.Unsupported;
    if (!owner.ownsCurrent(guard.rules_version)) return error.Unsupported;
    if (runtime.tree_registry.current() != guard.tree_version) return error.Denied;
    if (guard.code.owner != @as(?*const anyopaque, runtime)) return error.Denied;
}

fn checkCompileGuardArguments(_: *Runtime, state: *const anyopaque, args: []const Value) Error!void {
    const guard: *const CompileGuard = @ptrCast(@alignCast(state));
    if (args.len != guard.argument_count) return error.ArityMismatch;
}

fn scalarDatum(value: Expr.Scalar) Value {
    return switch (value) {
        .f64_bits => |bits| .f64(@bitCast(bits)),
        .f32_bits => |bits| .f32(@bitCast(bits)),
        .signed => |number| .i64(number),
        .unsigned => |number| .u64(number),
        .boolean => |boolean| .bool(boolean),
    };
}

fn staticDatum(ctx: *EvalContext, snapshot: *const Expr.Snapshot, atom: Expr.StaticAtomNode) Error!Value {
    const bytes = try snapshot.name(atom.name);
    return switch (atom.kind) {
        .nil => .nil,
        .symbol => Value.symbol(try ctx.runtime.store.getsym(bytes)),
        .keyword => Value.keyword(try ctx.runtime.store.getsym(bytes)),
        .string => blk: {
            const stored = try ctx.runtime.store.allocSlice(u8, bytes.len + 1);
            @memcpy(stored.slice[0..bytes.len], bytes);
            stored.slice[bytes.len] = 0;
            break :blk Value.string(.fromPtr(stored.slice.ptr));
        },
    };
}

const CompileVariable = struct {
    identity: Expr.FreeVarId,
    value: Code.ValueId,
};

const Compiler = struct {
    ctx: *EvalContext,
    snapshot: *const Expr.Snapshot,
    rule_version: *const rules.RegistryVersion,
    tree_version: *const tree.RegistryVersion,
    builder: Code.Builder,
    function: Code.FunctionId,
    block: Code.BlockId,
    values: []Code.ValueId,
    variables: []const CompileVariable,

    fn checkCurrent(self: *const Compiler, depth: usize) Error!void {
        const inherited = std.math.add(
            usize,
            self.ctx.depth,
            if (self.ctx.vm_depth) |value| @as(usize, value.*) else 0,
        ) catch return error.Exhausted;
        if (depth >= max_compile_depth or inherited >= max_compile_depth -| depth) {
            return error.Exhausted;
        }
        try self.ctx.check();
        if (self.ctx.registry != self.ctx.runtime.intrinsics.registryVersion()) return error.Denied;
        if (!self.rule_version.validFor(self.ctx.registry)) return error.Denied;
        if (self.ctx.runtime.tree_registry.current() != self.tree_version) return error.Denied;
    }

    fn literal(self: *Compiler, value: Value) Error!Code.ValueId {
        return self.builder.addNode(
            self.function,
            self.block,
            .{ .literal = value },
            .{},
        );
    }

    fn primitive(self: *Compiler, primitive_id: Primitive.PrimitiveId, args: []const Code.ValueId) Error!Code.ValueId {
        return self.builder.addNode(
            self.function,
            self.block,
            .{ .primitive_call = .{
                .primitive = primitive_id,
                .args = try self.builder.addOperands(args),
            } },
            .{},
        );
    }

    fn emitChildren(
        self: *Compiler,
        children: []const Expr.NodeId,
        depth: usize,
    ) Error![]Code.ValueId {
        const result = try self.ctx.scratch.alloc(Code.ValueId, children.len);
        for (children, 0..) |child, index| {
            result[index] = try self.emit(child, depth + 1);
        }
        return result;
    }

    fn emitList(self: *Compiler, node: Expr.Node, depth: usize) Error!Code.ValueId {
        const old = try self.snapshot.operands(node);
        const children = try self.emitChildren(old, depth);
        const primitive_id = self.ctx.registry.idForNative(
            &skript.intrinsics.list.list,
        ) orelse return error.Unsupported;
        return self.primitive(primitive_id, children);
    }

    fn emitMapKey(self: *Compiler, label: []const u8) Error!Code.ValueId {
        if (label.len == 0) return error.InvalidShape;
        const key = switch (label[0]) {
            '\'' => Value.symbol(try self.ctx.runtime.store.getsym(label[1..])),
            ':' => Value.keyword(try self.ctx.runtime.store.getsym(label[1..])),
            else => Value.symbol(try self.ctx.runtime.store.getsym(label)),
        };
        return self.literal(key);
    }

    fn emitMap(self: *Compiler, node: Expr.Node, depth: usize) Error!Code.ValueId {
        const map = node.kind.map;
        const old = try self.snapshot.operands(node);
        if (old.len != map.labels.len) return error.InvalidShape;
        const values = try self.ctx.scratch.alloc(Code.ValueId, old.len * 2);
        for (old, 0..) |child, index| {
            values[index * 2] = try self.emitMapKey(
                try self.snapshot.label(map.labels, index),
            );
            values[index * 2 + 1] = try self.emit(child, depth + 1);
        }
        const primitive_id = self.ctx.registry.idForNative(
            &skript.intrinsics.map.create,
        ) orelse return error.Unsupported;
        return self.primitive(primitive_id, values);
    }

    fn emitTensor(self: *Compiler, node: Expr.Node, depth: usize) Error!Code.ValueId {
        const tensor = node.kind.tensor;
        const old = try self.snapshot.operands(node);
        const elements = try self.emitChildren(old, depth);
        const stack_id = self.ctx.registry.idForNative(
            &skript.intrinsics.tensor.create,
        ) orelse return error.Unsupported;
        const tensor_value = try self.primitive(stack_id, elements);
        const shape = try self.snapshot.shape(tensor.shape);
        const dimensions = try self.ctx.scratch.alloc(Code.ValueId, shape.len);
        for (shape, 0..) |dimension, index| {
            dimensions[index] = try self.literal(.i64(@intCast(dimension)));
        }
        const list_id = self.ctx.registry.idForNative(
            &skript.intrinsics.list.list,
        ) orelse return error.Unsupported;
        const shape_value = try self.primitive(list_id, dimensions);
        const reshape_id = self.ctx.registry.idForNative(
            &skript.intrinsics.tensor.reshape,
        ) orelse return error.Unsupported;
        return self.primitive(reshape_id, &.{ tensor_value, shape_value });
    }

    fn unsignedScalar(self: *const Compiler, id: Expr.NodeId) Error!u64 {
        const node = try self.snapshot.node(id);
        return switch (node.kind) {
            .scalar => |scalar| switch (scalar.value) {
                .unsigned => |value| value,
                else => error.InvalidShape,
            },
            else => error.InvalidShape,
        };
    }

    fn emitRecord(self: *Compiler, node: Expr.Node, depth: usize) Error!Code.ValueId {
        const record = node.kind.record;
        const old = try self.snapshot.operands(node);
        if (old.len != 5 or record.fields.len != 5) return error.InvalidShape;
        const expected_labels = [_][]const u8{
            "tree-registry-version",
            "tree-type-index",
            "implementation-revision",
            "static-metadata",
            "children",
        };
        for (expected_labels, 0..) |expected, index| {
            if (!std.mem.eql(u8, try self.snapshot.label(record.fields, index), expected)) {
                return error.InvalidShape;
            }
        }
        if (try self.unsignedScalar(old[0]) != self.tree_version.version) {
            return error.Denied;
        }
        const type_index = std.math.cast(usize, try self.unsignedScalar(old[1])) orelse
            return error.InvalidShape;
        if (type_index >= self.tree_version.specs.len) return error.Denied;
        const custom = self.tree_version.specs[type_index];
        if (try self.unsignedScalar(old[2]) != custom.implementation_revision) {
            return error.Denied;
        }
        const type_name = try self.snapshot.name(record.type_label);
        const type_ptr = self.ctx.runtime.typePtrFromObj(custom.runtime_type);
        if (!std.mem.eql(u8, type_ptr.name.toPtr(Sym).*, type_name)) {
            return error.InvalidShape;
        }
        const metadata = try self.emit(old[3], depth + 1);
        const children_node = try self.snapshot.node(old[4]);
        if (children_node.kind != .list) return error.InvalidShape;
        const children = try self.emit(old[4], depth + 1);
        const hook = try self.literal(custom.unflatten_hook);
        const arguments = try self.builder.addOperands(&.{ metadata, children });
        return self.builder.addNode(
            self.function,
            self.block,
            .{ .dynamic_call = .{ .callee = hook, .args = arguments } },
            .{},
        );
    }

    fn emitConditional(
        self: *Compiler,
        index: usize,
        conditional: Expr.ConditionalNode,
        depth: usize,
    ) Error!Code.ValueId {
        const entry = self.block;
        const predicate = try self.emit(conditional.predicate, depth + 1);
        const then_block = try self.builder.addBlock(self.function);
        const else_block = try self.builder.addBlock(self.function);
        const merge_block = try self.builder.addBlock(self.function);
        try self.builder.setTerminator(entry, .{ .branch = .{
            .condition = predicate,
            .then_edge = .{ .target = then_block },
            .else_edge = .{ .target = else_block },
        } });

        const saved_values = try self.ctx.scratch.alloc(Code.ValueId, self.values.len);
        @memcpy(saved_values, self.values);

        self.block = then_block;
        const then_value = try self.emit(conditional.then_branch, depth + 1);
        const then_end = self.block;
        @memcpy(self.values, saved_values);

        self.block = else_block;
        const else_value = try self.emit(conditional.else_branch, depth + 1);
        const else_end = self.block;
        @memcpy(self.values, saved_values);

        const merged = try self.builder.addBlockParam(merge_block, self.function);
        const then_args = try self.builder.addOperands(&.{then_value});
        try self.builder.setTerminator(then_end, .{ .jump = .{
            .target = merge_block,
            .args = then_args,
        } });
        const else_args = try self.builder.addOperands(&.{else_value});
        try self.builder.setTerminator(else_end, .{ .jump = .{
            .target = merge_block,
            .args = else_args,
        } });
        self.block = merge_block;
        self.values[index] = merged;
        return merged;
    }

    fn emit(self: *Compiler, id: Expr.NodeId, depth: usize) Error!Code.ValueId {
        try self.checkCurrent(depth);
        const index = id.index();
        if (index >= self.values.len) return error.InvalidNode;
        if (self.values[index] != .invalid) return self.values[index];
        try self.ctx.charge(.{ .work = 1, .nodes = 1 }, .code);
        const node = try self.snapshot.node(id);
        const value = switch (node.kind) {
            .scalar => |scalar| try self.literal(scalarDatum(scalar.value)),
            .static_atom => |atom| try self.literal(try staticDatum(self.ctx, self.snapshot, atom)),
            .free_variable => |variable| blk: {
                for (self.variables) |known| {
                    if (known.identity.eql(variable.identity)) break :blk known.value;
                }
                return error.Unsupported;
            },
            .primitive_call => |call| blk: {
                const spec = self.ctx.registry.spec(call.identity.primitive) orelse return error.Denied;
                const rule = self.rule_version.find(call.identity.primitive) orelse return error.Denied;
                if (call.identity.registry_revision != self.ctx.registry.version or
                    call.identity.implementation_revision != spec.implementation_revision or
                    call.identity.rule_revision != rule.rule_revision)
                {
                    return error.Denied;
                }
                const old = try self.snapshot.operands(node);
                const args = try self.emitChildren(old, depth);
                break :blk try self.primitive(call.identity.primitive, args);
            },
            .conditional => |conditional| return self.emitConditional(index, conditional, depth),
            .list => try self.emitList(node, depth),
            .map => try self.emitMap(node, depth),
            .tensor => try self.emitTensor(node, depth),
            .record => try self.emitRecord(node, depth),
            .opaque_call => return error.Unsupported,
        };
        self.values[index] = value;
        return value;
    }
};

fn materializeCompiled(
    runtime: *Runtime,
    code: *const Code.Code,
    program: Runtime.RegProgram,
    function: Code.FunctionId,
    guard: *const skript.data.ClosureGuard,
) Error!Value {
    const index = @backingInt(function);
    if (index >= program.fns.len) return error.InvalidCode;
    const lowered = program.fns[index];
    const reference = try runtime.store.create(Closure);
    runtime.store.store(Closure, reference.deref(Closure), .{
        .parent_ns = runtime.root_ns,
        .arglist = lowered.arglist,
        .source = .nil,
        .source_ref = .{},
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
        .fns = program.fns,
    });
    return .closure(reference.toObject());
}

pub fn compile(
    parent_ctx: *EvalContext,
    handle: *const Expr.Handle,
    variables: []const Expr.Handle,
) Error!Value {
    var arena = std.heap.ArenaAllocator.init(parent_ctx.scratch);
    defer arena.deinit();
    var context = parent_ctx.*;
    context.scratch = arena.allocator();
    const ctx = &context;
    const scope = ctx.activate();
    defer scope.deinit();
    try ctx.check();
    if (ctx.registry != ctx.runtime.intrinsics.registryVersion()) return error.Denied;
    const rules_version = try rules.builtinSnapshot(ctx);
    try checkRuleSnapshot(ctx, rules_version);
    const tree_version = ctx.runtime.tree_registry.current();

    var snapshot = try handle.snapshot(ctx.scratch, ctx, .{});
    defer snapshot.deinit();

    const variable_info = try ctx.scratch.alloc(CompileVariable, variables.len);
    var builder = Code.Builder.init(ctx.runtime.static, ctx);
    const identity = try ctx.runtime.allocCodeIdentity();
    builder.id = identity.id;
    builder.revision = identity.revision;
    const function = try builder.addFunction(null, .{});
    const block = try builder.addBlock(function);
    for (variables, 0..) |variable_handle, index| {
        var reader = try variable_handle.acquire(ctx);
        defer reader.deinit();
        const variable_node = try reader.node(variable_handle.nodeId());
        const variable = switch (variable_node.kind) {
            .free_variable => |value| value,
            else => return error.Unsupported,
        };
        for (variable_info[0..index]) |prior| {
            if (prior.identity.eql(variable.identity)) return error.InvalidIdentity;
        }
        const name = try reader.name(variable.name);
        const binding = try builder.addBinding(function, try ctx.runtime.store.getsym(name), .parameter, .{});
        const value = try builder.addValue(function);
        builder.bindings.items[@backingInt(binding)].value = value;
        try builder.addParameter(function, binding);
        variable_info[index] = .{ .identity = variable.identity, .value = value };
    }
    var compiler: Compiler = .{
        .ctx = ctx,
        .snapshot = &snapshot,
        .rule_version = rules_version,
        .tree_version = tree_version,
        .builder = builder,
        .function = function,
        .block = block,
        .values = try ctx.scratch.alloc(Code.ValueId, snapshot.nodeCount()),
        .variables = variable_info,
    };
    @memset(compiler.values, .invalid);
    const result = try compiler.emit(snapshot.root(), 0);
    try compiler.builder.setTerminator(
        compiler.block,
        .{ .return_values = try compiler.builder.addOperands(&.{result}) },
    );
    const code = try compiler.builder.finish(ctx.scratch);
    code.owner = ctx.runtime;
    const program = try ctx.runtime.lowerCode(ctx.scratch, code);
    try checkRuleSnapshot(ctx, rules_version);
    if (ctx.runtime.tree_registry.current() != tree_version) return error.Denied;

    const guard_context = try ctx.runtime.static.create(CompileGuard);
    guard_context.* = .{
        .runtime = ctx.runtime,
        .registry = ctx.registry,
        .rules_version = rules_version,
        .tree_version = tree_version,
        .code = code,
        .argument_count = variables.len,
    };
    const guard = try ctx.runtime.static.create(skript.data.ClosureGuard);
    guard.* = .{
        .context = guard_context,
        .check = &checkCompileGuard,
        .trace = &traceCompileGuard,
        .check_arguments = &checkCompileGuardArguments,
    };
    return materializeCompiled(ctx.runtime, code, program, function, guard);
}
test "symbolic evaluation keeps same-spelled variables distinct" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const context = runtime.context();
    var region = try Expr.Region.init(
        std.testing.allocator,
        context,
        .{ .identity = @fromBackingInt(@intCast(701)) },
    );
    defer region.deinit();
    const first_id = try region.freshVariable(context, "x", .real, .none);
    const second_id = try region.freshVariable(context, "x", .real, .none);
    var first = try region.handle(context, first_id);
    defer first.deinit();
    var second = try region.handle(context, second_id);
    defer second.deinit();
    const callable = try makeListClosure(runtime);

    var result = try evaluate(context, &region, callable, &.{
        .{ .expression = .{ .handle = first } },
        .{ .expression = .{ .handle = second } },
    });
    defer result.deinit();
    var reader = try result.acquire(context);
    defer reader.deinit();
    const root = try reader.node(result.nodeId());
    try std.testing.expectEqual(Expr.NodeTag.list, std.meta.activeTag(root.kind));
    const elements = try reader.operands(root);
    try std.testing.expectEqual(@as(usize, 2), elements.len);
    const first_variable = (try reader.node(elements[0])).kind.free_variable;
    const second_variable = (try reader.node(elements[1])).kind.free_variable;
    try std.testing.expect(!first_variable.identity.eql(second_variable.identity));
    try std.testing.expectEqualStrings("x", try reader.name(first_variable.name));
    try std.testing.expectEqualStrings("x", try reader.name(second_variable.name));
}

test "symbolic structured results retain quoted map labels" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const context = runtime.context();
    const label = Value.symbol(try runtime.store.getsym("label"));
    const input = try skript.intrinsics.map.create(
        context,
        .nil,
        .nil,
        &.{ label, Value.f64(3.0) },
    );
    var region = try Expr.Region.init(
        std.testing.allocator,
        context,
        .{ .identity = @fromBackingInt(@intCast(702)) },
    );
    defer region.deinit();
    const callable = try makeIdentityClosure(runtime);

    var result = try evaluate(
        context,
        &region,
        callable,
        &.{.{ .constant = input }},
    );
    defer result.deinit();
    var reader = try result.acquire(context);
    defer reader.deinit();
    const root = try reader.node(result.nodeId());
    try std.testing.expectEqual(Expr.NodeTag.map, std.meta.activeTag(root.kind));
    try std.testing.expectEqualStrings("'label", try reader.label(root.kind.map.labels, 0));

    const datum = try toDatum(context, &result);
    const recovered = try skript.intrinsics.map.get(
        context,
        .nil,
        .nil,
        &.{ datum, label },
    );
    try std.testing.expectEqual(Value.f64(3.0), recovered);
}

test "symbolic evaluation preserves unresolved calls as opaque without invoking them" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const context = runtime.context();
    var region = try Expr.Region.init(
        std.testing.allocator,
        context,
        .{ .identity = @fromBackingInt(@intCast(703)) },
    );
    defer region.deinit();
    const variable_id = try region.freshVariable(context, "x", .real, .none);
    var variable = try region.handle(context, variable_id);
    defer variable.deinit();
    const callable = try makeOpaqueClosure(runtime);
    opaque_invocations = 0;

    var result = try evaluate(
        context,
        &region,
        callable,
        &.{.{ .expression = .{ .handle = variable } }},
    );
    defer result.deinit();
    var reader = try result.acquire(context);
    defer reader.deinit();
    const root = try reader.node(result.nodeId());
    try std.testing.expectEqual(Expr.NodeTag.opaque_call, std.meta.activeTag(root.kind));
    try std.testing.expectEqual(Expr.EffectKnowledge.unknown, root.effectKnowledge());
    try std.testing.expectEqual(@as(usize, 0), opaque_invocations);
}

test "symbolic branches produce bounded inert alternatives" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const context = runtime.context();
    var region = try Expr.Region.init(std.testing.allocator, context, .{
        .identity = @fromBackingInt(@intCast(704)),
        .limits = .{ .max_nodes = 8, .max_edges = 16 },
    });
    defer region.deinit();
    const predicate_id = try region.freshVariable(
        context,
        "condition",
        .boolean,
        .none,
    );
    var predicate = try region.handle(context, predicate_id);
    defer predicate.deinit();
    const callable = try makeBranchClosure(runtime);

    var result = try evaluate(
        context,
        &region,
        callable,
        &.{.{ .expression = .{ .handle = predicate } }},
    );
    defer result.deinit();
    var reader = try result.acquire(context);
    defer reader.deinit();
    const root = try reader.node(result.nodeId());
    try std.testing.expectEqual(
        Expr.NodeTag.conditional,
        std.meta.activeTag(root.kind),
    );
    try std.testing.expectEqual(
        predicate_id,
        root.kind.conditional.predicate,
    );
    try std.testing.expectEqual(@as(usize, 3), (try reader.operands(root)).len);
}

test "symbolic tail calls dispatch primitives and retain opaque calls" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const context = runtime.context();
    var region = try Expr.Region.init(
        std.testing.allocator,
        context,
        .{ .identity = @fromBackingInt(@intCast(711)) },
    );
    defer region.deinit();
    const variable_id = try region.freshVariable(context, "x", .real, .none);
    var variable = try region.handle(context, variable_id);
    defer variable.deinit();

    const sine = try runtime.evalString("(fn (x) (@f64.sin x))");
    var sine_result = try evaluate(
        context,
        &region,
        sine,
        &.{.{ .expression = .{ .handle = variable } }},
    );
    defer sine_result.deinit();
    var sine_reader = try sine_result.acquire(context);
    defer sine_reader.deinit();
    const sine_root = try sine_reader.node(sine_result.nodeId());
    try std.testing.expectEqual(
        Expr.NodeTag.primitive_call,
        std.meta.activeTag(sine_root.kind),
    );
    const sine_operands = try sine_reader.operands(sine_root);
    try std.testing.expectEqual(@as(usize, 2), sine_operands.len);
    const sine_operation_node = try sine_reader.node(sine_operands[0]);
    try std.testing.expectEqual(
        Expr.NodeTag.scalar,
        std.meta.activeTag(sine_operation_node.kind),
    );
    const sine_operation = sine_operation_node.kind.scalar.value;
    switch (sine_operation) {
        .signed => |tag| try std.testing.expectEqual(
            @as(i64, @intCast(@backingInt(rules.ScalarOp.sin))),
            tag,
        ),
        else => return error.TestUnexpectedResult,
    }

    const opaque_source = try makeTailOpaqueClosure(runtime);
    opaque_invocations = 0;
    var opaque_result = try evaluate(
        context,
        &region,
        opaque_source,
        &.{.{ .expression = .{ .handle = variable } }},
    );
    defer opaque_result.deinit();
    var opaque_reader = try opaque_result.acquire(context);
    defer opaque_reader.deinit();
    const opaque_root = try opaque_reader.node(opaque_result.nodeId());
    try std.testing.expectEqual(
        Expr.NodeTag.opaque_call,
        std.meta.activeTag(opaque_root.kind),
    );
    try std.testing.expectEqual(@as(usize, 0), opaque_invocations);
}
test "symbolic evaluator rejects deeply nested closure calls" {
    const runtime = try Runtime.initWithConfig(std.testing.allocator, std.testing.io, .{
        // Setup retains 1024 live wrapper closures (~450B each over the
        // ~868KB prelude base), exceeding the default 1 MiB test-mode cap
        // before evaluate() runs. Bump this test's heap only.
        .max_heap_size = 4 * 1024 * 1024,
    });
    defer runtime.deinit();
    const context = runtime.context();
    var region = try Expr.Region.init(
        std.testing.allocator,
        context,
        .{ .identity = @fromBackingInt(@intCast(712)) },
    );
    defer region.deinit();
    const variable_id = try region.freshVariable(context, "x", .real, .none);
    var variable = try region.handle(context, variable_id);
    defer variable.deinit();

    const wrapper = try runtime.evalString("(fn (next) (fn (x) (next x)))");
    var chained = try makeIdentityClosure(runtime);
    for (0..1024) |_| {
        chained = try runtime.applyWithContext(
            context,
            runtime.root_ns,
            wrapper,
            &.{chained},
        );
    }
    try std.testing.expectError(
        error.Exhausted,
        evaluate(
            context,
            &region,
            chained,
            &.{.{ .expression = .{ .handle = variable } }},
        ),
    );
}

test "compiler bounds deeply nested primitive source" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const context = runtime.context();
    var region = try Expr.Region.init(
        std.testing.allocator,
        context,
        .{ .identity = @fromBackingInt(@intCast(713)) },
    );
    defer region.deinit();
    const primitive = context.registry.idForNative(
        &skript.intrinsics.float.f64_neg,
    ) orelse return error.Unsupported;
    const identity = try currentPrimitiveIdentity(context, primitive);
    var root = try region.intern(context, .{ .scalar = .{
        .value = Expr.Scalar.fromF64(1.0),
        .domain = .real,
    } });
    for (0..1024) |_| {
        root = try region.intern(context, .{ .primitive_call = .{
            .identity = identity,
            .arguments = &.{root},
            .domain = .real,
        } });
    }
    var expression = try region.handle(context, root);
    defer expression.deinit();
    try std.testing.expectError(
        error.Exhausted,
        compile(context, &expression, &.{}),
    );
}

test "compiled pure expressions preserve numeric results" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const context = runtime.context();
    var region = try Expr.Region.init(
        std.testing.allocator,
        context,
        .{ .identity = @fromBackingInt(@intCast(705)) },
    );
    defer region.deinit();
    const variable_id = try region.freshVariable(context, "x", .real, .none);
    const multiply_id = context.registry.idForNative(
        &skript.intrinsics.float.f64_mul,
    ) orelse return error.Unsupported;
    const product_id = try region.intern(context, .{ .primitive_call = .{
        .identity = try currentPrimitiveIdentity(context, multiply_id),
        .arguments = &.{ variable_id, variable_id },
        .domain = .real,
    } });
    var variable = try region.handle(context, variable_id);
    defer variable.deinit();
    var product = try region.handle(context, product_id);
    defer product.deinit();

    const callable = try compile(context, &product, &.{variable});
    const result = try context.apply(
        runtime.root_ns,
        callable,
        &.{Value.f64(3.0)},
    );
    try std.testing.expectEqual(Value.f64(9.0), result);
}

test "symbolic entry points reject expired handles" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const context = runtime.context();
    var source_region = try Expr.Region.init(
        std.testing.allocator,
        context,
        .{ .identity = @fromBackingInt(@intCast(706)) },
    );
    const variable_id = try source_region.freshVariable(
        context,
        "x",
        .real,
        .none,
    );
    var variable = try source_region.handle(context, variable_id);
    defer variable.deinit();
    source_region.close();
    defer source_region.deinit();
    var output_region = try Expr.Region.init(
        std.testing.allocator,
        context,
        .{ .identity = @fromBackingInt(@intCast(707)) },
    );
    defer output_region.deinit();
    const callable = try makeIdentityClosure(runtime);

    try std.testing.expectError(error.Expired, toDatum(context, &variable));
    try std.testing.expectError(
        error.Expired,
        compile(context, &variable, &.{variable}),
    );
    try std.testing.expectError(
        error.Expired,
        evaluate(
            context,
            &output_region,
            callable,
            &.{.{ .expression = .{ .handle = variable } }},
        ),
    );
}

const TestSymbolicGuardState = struct {
    valid: bool = true,
    checks: usize = 0,
    acquisitions: usize = 0,
    releases: usize = 0,
};

fn checkTestSymbolicGuard(
    _: *Runtime,
    opaque_state: *const anyopaque,
) Error!void {
    const state: *TestSymbolicGuardState =
        @constCast(@as(*const TestSymbolicGuardState, @ptrCast(@alignCast(opaque_state))));
    state.checks += 1;
    if (!state.valid) return error.Denied;
}

fn checkTestSymbolicGuardArguments(
    _: *Runtime,
    _: *const anyopaque,
    arguments: []const Value,
) Error!void {
    if (arguments.len != 1) return error.ArityMismatch;
    if (arguments[0].typ != b.type_symbol) return error.Unsupported;
}

fn acquireTestSymbolicGuard(
    _: *Runtime,
    opaque_state: *const anyopaque,
) Error!void {
    const state: *TestSymbolicGuardState =
        @constCast(@as(*const TestSymbolicGuardState, @ptrCast(@alignCast(opaque_state))));
    if (!state.valid) return error.Denied;
    state.acquisitions += 1;
}

fn releaseTestSymbolicGuard(
    _: *Runtime,
    opaque_state: *const anyopaque,
) void {
    const state: *TestSymbolicGuardState =
        @constCast(@as(*const TestSymbolicGuardState, @ptrCast(@alignCast(opaque_state))));
    state.releases += 1;
}

fn makeCallingClosure(runtime: *Runtime, target: Value) !Value {
    var builder = Code.Builder.init(runtime.static, runtime.context());
    const identity = try runtime.allocCodeIdentity();
    builder.id = identity.id;
    builder.revision = identity.revision;
    const function = try builder.addFunction(null, .{});
    const block = try builder.addBlock(function);
    const argument = try addTestParameter(&builder, runtime, function, "value");
    const callee = try builder.addNode(
        function,
        block,
        .{ .literal = target },
        .{},
    );
    const result = try builder.addNode(function, block, .{ .dynamic_call = .{
        .callee = callee,
        .args = try builder.addOperands(&.{argument}),
    } }, .{});
    try builder.setTerminator(
        block,
        .{ .return_values = try builder.addOperands(&.{result}) },
    );
    return materializeTestClosure(runtime, &builder, function);
}

fn makeSymbolicTestNamespace(runtime: *Runtime, parent: Value) !Value {
    const reference = try runtime.store.create(skript.Namespace);
    runtime.store.store(
        skript.Namespace,
        reference.deref(skript.Namespace),
        skript.HashMapNamespace.vtable,
    );
    const values = try runtime.static.create(skript.HashMapNamespace);
    values.* = try skript.HashMapNamespace.init(runtime.static, parent);
    reference.deref(skript.Namespace).data = @ptrCast(values);
    const namespace = Value.namespace(reference.toObject());
    runtime.ownNamespace(namespace);
    return namespace;
}

fn installSymbolicPointTree(runtime: *Runtime) !struct {
    runtime_type: skript.Object,
    point: Value,
} {
    const name = try runtime.store.getsym("Point");
    const type_reference = try runtime.store.create(skript.Type);
    runtime.store.store(skript.Type, type_reference.deref(skript.Type), .{
        .meta = b.type_type,
        .name = skript.Object.fromPtr(name),
    });
    const runtime_type = type_reference.toObject();
    const flatten_hook = try runtime.evalString(
        "(fn (point) (list (list 3.0 4.0) (list 'point-label)))",
    );
    const unflatten_hook = try runtime.evalString("(fn (metadata children) nil)");
    _ = try runtime.tree_registry.publish(&.{.{
        .runtime_type = runtime_type,
        .implementation_revision = 7,
        .namespace = runtime.root_ns,
        .flatten_hook = flatten_hook,
        .unflatten_hook = unflatten_hook,
    }});
    return .{
        .runtime_type = runtime_type,
        .point = Value.init(runtime_type, .null),
    };
}

test "nested symbolic closures check guards and balance lifetime leases" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const context = runtime.context();
    var guard_state: TestSymbolicGuardState = .{};
    const guard: skript.data.ClosureGuard = .{
        .context = &guard_state,
        .check = &checkTestSymbolicGuard,
        .trace = null,
        .check_arguments = &checkTestSymbolicGuardArguments,
        .acquire = &acquireTestSymbolicGuard,
        .release = &releaseTestSymbolicGuard,
    };
    const outer = try runtime.evalString(
        "(fn (x) ((fn (left right) (+ left right)) x x))",
    );
    outer.obj.toRef().deref(Closure).guard = &guard;
    var region = try Expr.Region.init(
        std.testing.allocator,
        context,
        .{ .identity = @fromBackingInt(@intCast(708)) },
    );
    defer region.deinit();
    const variable_id = try region.freshVariable(context, "x", .real, .none);
    var variable = try region.handle(context, variable_id);
    defer variable.deinit();

    var result = try evaluate(context, &region, outer, &.{
        .{ .expression = .{ .handle = variable } },
    });
    defer result.deinit();
    const compiled = try compile(context, &result, &.{variable});
    try std.testing.expectEqual(
        Value.f64(6.0),
        try runtime.applyWithContext(
            context,
            runtime.root_ns,
            compiled,
            &.{Value.f64(3.0)},
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), guard_state.checks);
    try std.testing.expectEqual(@as(usize, 2), guard_state.acquisitions);
    try std.testing.expectEqual(@as(usize, 2), guard_state.releases);

    guard_state.valid = false;
    try std.testing.expectError(
        error.Denied,
        evaluate(context, &region, outer, &.{
            .{ .expression = .{ .handle = variable } },
        }),
    );
    try std.testing.expectEqual(@as(usize, 3), guard_state.checks);
    try std.testing.expectEqual(@as(usize, 2), guard_state.acquisitions);
    try std.testing.expectEqual(@as(usize, 2), guard_state.releases);
}

test "symbolic closure composition uses the callee parent namespace" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const context = runtime.context();
    const callee_namespace = try makeSymbolicTestNamespace(runtime, runtime.root_ns);
    const caller_namespace = try makeSymbolicTestNamespace(runtime, runtime.root_ns);
    const binding = try runtime.store.getsym("symbolic-k");
    try runtime.nsBind(callee_namespace, binding, Value.f64(2.0));
    try runtime.nsBind(caller_namespace, binding, Value.f64(7.0));
    const helper = try runtime.evalString("(fn (x) (+ x symbolic-k))");
    helper.obj.toRef().deref(Closure).parent_ns = callee_namespace;
    const caller = try makeCallingClosure(runtime, helper);
    caller.obj.toRef().deref(Closure).parent_ns = caller_namespace;
    var region = try Expr.Region.init(
        std.testing.allocator,
        context,
        .{ .identity = @fromBackingInt(@intCast(709)) },
    );
    defer region.deinit();
    const variable_id = try region.freshVariable(context, "x", .real, .none);
    var variable = try region.handle(context, variable_id);
    defer variable.deinit();

    var expression = try evaluate(context, &region, caller, &.{
        .{ .expression = .{ .handle = variable } },
    });
    defer expression.deinit();
    const compiled = try compile(context, &expression, &.{variable});
    const result = try context.apply(
        runtime.root_ns,
        compiled,
        &.{Value.f64(5.0)},
    );
    try std.testing.expectEqual(Value.f64(7.0), result);
}

test "registered Point lifting preserves identity metadata and children" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const context = runtime.context();
    const registered = try installSymbolicPointTree(runtime);
    var region = try Expr.Region.init(
        std.testing.allocator,
        context,
        .{ .identity = @fromBackingInt(@intCast(710)) },
    );
    defer region.deinit();
    const callable = try makeIdentityClosure(runtime);

    var expression = try evaluate(
        context,
        &region,
        callable,
        &.{.{ .constant = registered.point }},
    );
    defer expression.deinit();
    var reader = try expression.acquire(context);
    defer reader.deinit();
    const root = try reader.node(expression.nodeId());
    try std.testing.expectEqual(Expr.NodeTag.record, std.meta.activeTag(root.kind));
    const record = root.kind.record;
    try std.testing.expectEqualStrings("Point", try reader.name(record.type_label));
    const fields = try reader.operands(root);
    try std.testing.expectEqual(@as(usize, 5), fields.len);
    try std.testing.expectEqualStrings(
        "tree-registry-version",
        try reader.label(record.fields, 0),
    );
    try std.testing.expectEqualStrings("tree-type-index", try reader.label(record.fields, 1));
    try std.testing.expectEqualStrings(
        "implementation-revision",
        try reader.label(record.fields, 2),
    );
    try std.testing.expectEqualStrings("static-metadata", try reader.label(record.fields, 3));
    try std.testing.expectEqualStrings("children", try reader.label(record.fields, 4));

    const metadata = try reader.node(fields[3]);
    const metadata_items = try reader.operands(metadata);
    try std.testing.expectEqual(@as(usize, 1), metadata_items.len);
    const label = (try reader.node(metadata_items[0])).kind.static_atom;
    try std.testing.expectEqual(Expr.StaticAtomKind.symbol, label.kind);
    try std.testing.expectEqualStrings("point-label", try reader.name(label.name));
    const children = try reader.node(fields[4]);
    try std.testing.expectEqual(@as(usize, 2), (try reader.operands(children)).len);
}
