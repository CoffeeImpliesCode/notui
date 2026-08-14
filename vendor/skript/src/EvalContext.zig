const std = @import("std");
const Runtime = @import("Runtime.zig");
const Primitive = @import("primitive.zig");
pub const Budget = @import("Budget.zig");
const EvalContext = @This();
const skript = @import("root.zig");
const Value = skript.Value;

pub threadlocal var active: ?*EvalContext = null;

pub fn currentForStore(store: *skript.Store) ?*EvalContext {
    const context = active orelse return null;
    return if (context.runtime.store == store) context else null;
}

pub const Scope = struct {
    previous: ?*EvalContext,

    pub fn deinit(self: Scope) void {
        active = self.previous;
    }
};

pub fn activate(self: *EvalContext) Scope {
    const scope: Scope = .{ .previous = active };
    active = self;
    return scope;
}

pub fn apply(
    self: *EvalContext,
    namespace: Value,
    callable: Value,
    args: []const Value,
) skript.Error!Value {
    return self.runtime.applyWithContext(self, namespace, callable, args);
}

pub const Reentry = struct {
    state: *anyopaque,
    apply: *const fn (*anyopaque, *EvalContext, Value, Value, []const Value) skript.Error!Value,
    source: *const fn (*anyopaque, *EvalContext, []const u8) skript.Error!Value,
    lookup: *const fn (*anyopaque, *EvalContext, Value, skript.Sym) skript.Error!Value,
};

test "native source reentry cannot suspend its owning fiber" {
    const reenter = struct {
        fn invoke(ctx: *EvalContext, _: Value, _: Value, _: []const Value) skript.Error!Value {
            return ctx.runtime.evalString("(sleep 1)");
        }
    }.invoke;
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    try std.testing.expectError(error.Denied, rt.apply(rt.root_ns, Value.intrinsic(&reenter), &.{}));
}

test "native callbacks refuse suspension without replaying effects" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const result = try rt.evalString(
        \\(let ((hits (hash-map :n 0)))
        \\  (let ((result
        \\    (map (list 1 2) (fn (x)
        \\      (map-set! hits :n (+ (map-get hits :n) 1))
        \\      (sleep 1)))))
        \\    (list (error-name (fst result))
        \\          (error-name (fst (rst result)))
        \\          (map-get hits :n))))
    );
    var current = result;
    for (0..2) |_| {
        const cell = current.obj.toRef().deref([2]skript.Value);
        try std.testing.expectEqual(skript.builtins.type_string, cell[0].typ);
        try std.testing.expectEqualStrings("Denied", std.mem.span(cell[0].obj.toPtr([*:0]const u8)));
        current = cell[1];
    }
    const second = current.obj.toRef().deref([2]skript.Value);
    try std.testing.expectEqual(Value.i64(2), second[0]);
}

test "embedded and scheduled eval resolve direct, tail, and aliased calls lexically" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const cases = [_]struct { source: []const u8, expected: i64 }{
        .{ .source = "(let ((scope 11)) (+ 2 (eval 'scope)))", .expected = 13 },
        .{ .source = "(let ((scope 11)) (eval 'scope))", .expected = 11 },
        .{ .source = "(let ((scope 11)) ((fn (evaluate) (evaluate 'scope)) eval))", .expected = 11 },
    };
    for (cases) |case| {
        try std.testing.expectEqual(Value.i64(case.expected), try rt.evalString(case.source));
        const process = try rt.spawnEval(case.source);
        try std.testing.expectEqual(Value.i64(case.expected), try rt.awaitProcess(process));
    }
}

test "embedded eval uses the root namespace only when no namespace is supplied" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    _ = try rt.evalString("(def embedded-eval-root 17)");
    const datum = try rt.evalString("'(+ embedded-eval-root 4)");
    const evaluate = rt.intrinsics.get("eval").?;
    try std.testing.expectEqual(Value.i64(21), try rt.apply(.nil, evaluate, &.{datum}));
    try std.testing.expectError(error.TypeMismatch, rt.apply(.nil, evaluate, &.{ datum, Value.nil }));
    try std.testing.expectError(error.TypeMismatch, rt.apply(.nil, evaluate, &.{ datum, Value.i64(1) }));
    try std.testing.expectError(error.ArityMismatch, rt.apply(.nil, evaluate, &.{}));
    try std.testing.expectError(error.ArityMismatch, rt.apply(.nil, evaluate, &.{ datum, .nil, .nil }));
}

test "embedded eval explicit export namespace overrides lexical bindings and denies writes" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    _ = try rt.evalString("(def embedded-eval-exported 17)");
    const exported = try rt.store.getsym("embedded-eval-exported");
    const view = try rt.static.create(skript.data.ExportNamespace);
    view.* = skript.data.ExportNamespace.init(rt.static, rt.root_ns);
    try view.names.put(exported, .{ .namespace = rt.root_ns, .name = exported });
    const reference = try rt.store.create(skript.Namespace);
    rt.store.store(skript.Namespace, reference.deref(skript.Namespace), skript.data.ExportNamespace.vtable);
    reference.deref(skript.Namespace).data = @ptrCast(view);
    try rt.nsBind(rt.root_ns, try rt.store.getsym("embedded-eval-view"), .namespace(reference.toObject()));

    try std.testing.expectEqual(Value.i64(17), try rt.evalString(
        "(let ((embedded-eval-exported 99)) (eval 'embedded-eval-exported embedded-eval-view))",
    ));
    try std.testing.expectError(error.Denied, rt.evalString(
        "(eval '(set! embedded-eval-exported 42) embedded-eval-view)",
    ));
    try std.testing.expectEqual(Value.i64(17), try rt.evalString("embedded-eval-exported"));
}

test "native callback eval completes before the scheduled caller resumes its own eval" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const source =
        \\(let ((base 5) (hits (hash-map :n 0)))
        \\  (let ((values
        \\    (eval '(map (list 1 2) (fn (x)
        \\      (map-set! hits :n (+ (map-get hits :n) 1))
        \\      (eval (list '+ 'base x)))))))
        \\    (list (fst values) (fst (rst values))
        \\          (eval '(+ base 30)) (map-get hits :n))))
    ;
    const expect_result = struct {
        fn check(value: Value) !void {
            var current = value;
            for ([_]i64{ 6, 7, 35, 2 }) |expected| {
                try std.testing.expectEqual(skript.builtins.type_cons, current.typ);
                const cell = current.obj.toRef().deref([2]Value);
                try std.testing.expectEqual(Value.i64(expected), cell[0]);
                current = cell[1];
            }
            try std.testing.expectEqual(Value.nil, current);
        }
    }.check;
    try expect_result(try rt.evalString(source));
    const process = try rt.spawnEval(source);
    try expect_result(try rt.awaitProcess(process));
}

test "native callback eval refuses suspension without replay or later effects" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const process = try rt.spawnEval(
        \\(let ((hits (hash-map :before 0 :after 0)))
        \\  (let ((errors
        \\    (map (list 1 2) (fn (x)
        \\      (map-set! hits :before (+ (map-get hits :before) 1))
        \\      (let ((result (eval '(sleep 1))))
        \\        (if (error? result)
        \\            result
        \\            (begin
        \\              (map-set! hits :after (+ (map-get hits :after) 1))
        \\              x)))))))
        \\    (list (error-name (fst errors))
        \\          (error-name (fst (rst errors)))
        \\          (eval '(+ 40 2))
        \\          (map-get hits :before)
        \\          (map-get hits :after))))
    );
    var current = try rt.awaitProcess(process);
    for (0..2) |_| {
        try std.testing.expectEqual(skript.builtins.type_cons, current.typ);
        const cell = current.obj.toRef().deref([2]Value);
        try std.testing.expectEqual(skript.builtins.type_string, cell[0].typ);
        try std.testing.expectEqualStrings("Denied", std.mem.span(cell[0].obj.toPtr([*:0]const u8)));
        current = cell[1];
    }
    for ([_]i64{ 42, 2, 0 }) |expected| {
        try std.testing.expectEqual(skript.builtins.type_cons, current.typ);
        const cell = current.obj.toRef().deref([2]Value);
        try std.testing.expectEqual(Value.i64(expected), cell[0]);
        current = cell[1];
    }
    try std.testing.expectEqual(Value.nil, current);
}

test "metered embedding cannot use eval even with all effects available" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    _ = try rt.evalString("(def embedded-eval-restricted-hits (hash-map :n 0))");
    const limits: Budget.Limits = .{ .work = 100_000 };
    var ledger = Budget.init(rt.io, 1, limits);
    var lease = try Budget.Lease.root(&ledger, limits.work);
    var account = Budget.AccountAllocator.init(std.testing.allocator, &lease, .native);
    var output_bytes: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output_bytes);
    var restricted = try EvalContext.limited(rt, rt.intrinsics.registryVersion(), &account, .{
        .writer = &writer,
        .bounded_memory = true,
    }, .{
        .effects = EvalContext.EffectDecisionTable.trusted(),
        .allow_suspend = true,
    });
    try std.testing.expectError(error.Denied, rt.evalStringWithContext(
        &restricted,
        "(eval '(map-set! embedded-eval-restricted-hits :n 1))",
    ));
    const datum = try rt.evalString("'(map-set! embedded-eval-restricted-hits :n 2)");
    try std.testing.expectError(error.Denied, rt.evalDatumWithContext(&restricted, datum, null));
    try std.testing.expectEqual(Value.i64(0), try rt.evalString(
        "(map-get embedded-eval-restricted-hits :n)",
    ));
}

pub const Error = Budget.Error || error{ Denied, Unsupported, WriteFailed };
pub const Mode = enum { concrete, dry, abstract, residual };
pub const Execution = enum { trusted, metered, pure_limited };
pub const Version = struct {
    id: u64,
    revision: u64,

    pub fn eql(a: Version, b: Version) bool {
        return a.id == b.id and a.revision == b.revision;
    }
};
pub const Decision = union(enum) { allow, deny, model: Version };
pub const Effect = enum {
    state_read,
    state_write,
    io,
    clock,
    random,
    process,
    module,
    ffi,
    dynamic_loader,
    host,
    unknown,
};
pub const EffectDecisionTable = struct {
    state_read: Decision = .deny,
    state_write: Decision = .deny,
    io: Decision = .deny,
    clock: Decision = .deny,
    random: Decision = .deny,
    process: Decision = .deny,
    module: Decision = .deny,
    ffi: Decision = .deny,
    dynamic_loader: Decision = .deny,
    host: Decision = .deny,
    unknown: Decision = .deny,

    pub fn trusted() EffectDecisionTable {
        var table: EffectDecisionTable = .{};
        inline for (@typeInfo(EffectDecisionTable).@"struct".fields) |field| {
            @field(table, field.name) = .allow;
        }
        return table;
    }

    pub fn permitsChild(parent: EffectDecisionTable, candidate: EffectDecisionTable) bool {
        inline for (@typeInfo(EffectDecisionTable).@"struct".fields) |field| {
            const before = @field(parent, field.name);
            const after = @field(candidate, field.name);
            switch (before) {
                .allow => {},
                .deny => if (after != .deny) return false,
                .model => |identity| switch (after) {
                    .deny => {},
                    .model => |next| if (!identity.eql(next)) return false,
                    .allow => return false,
                },
            }
        }
        return true;
    }
};

pub const Output = struct {
    writer: *std.Io.Writer,
    /// Limited execution can write only to a host-provided bounded memory sink.
    bounded_memory: bool = false,
};

/// Caller-owned native reservation. A nested call must not inherit this credit.
pub const Reservation = struct {
    bytes: u64 = 0,
    objects: u64 = 0,
    allow_suspend: bool = false,
};
pub const Authorization = union(enum) {
    invoke: Reservation,
    model: Version,
};
pub const LimitedOptions = struct {
    mode: Mode = .concrete,
    pure: bool = false,
    effects: EffectDecisionTable = .{},
    model: ?Version = null,
    allow_suspend: bool = false,
};

/// Host-owned context. Skript receives an opaque capability handle, not this pointer.
/// Its runtime, registry, output, and lease owners must outlive all derived contexts.
runtime: *Runtime,
registry: *const Primitive.RegistryVersion,
scratch: std.mem.Allocator,
scratch_base: std.mem.Allocator,
output: Output,
identity: u64 = 0,
mode: Mode = .concrete,
execution: Execution = .trusted,
effects: EffectDecisionTable,
model: ?Version = null,
lease: ?*Budget.Lease = null,
allow_suspend: bool = true,
in_native: bool = false,
native_reentry: bool = false,
depth: u32 = 0,
vm_depth: ?*const u32 = null,
reservation: ?*Reservation = null,
reentry: ?Reentry = null,

pub fn trusted(
    scratch: std.mem.Allocator,
    runtime: *Runtime,
    registry: *const Primitive.RegistryVersion,
    output: Output,
) EvalContext {
    return .{
        .runtime = runtime,
        .registry = registry,
        .scratch = scratch,
        .scratch_base = scratch,
        .output = output,
        .effects = EffectDecisionTable.trusted(),
    };
}

pub fn limited(
    runtime: *Runtime,
    registry: *const Primitive.RegistryVersion,
    account: *Budget.AccountAllocator,
    output: Output,
    options: LimitedOptions,
) Error!EvalContext {
    const lease = account.lease;
    if (lease.budget.isExhausted()) return error.Exhausted;
    return .{
        .identity = try runtime.allocEvaluationIdentity(),
        .runtime = runtime,
        .registry = registry,
        .scratch = account.allocator(),
        .scratch_base = account.base,
        .output = output,
        .mode = options.mode,
        .execution = if (options.pure) .pure_limited else .metered,
        .effects = options.effects,
        .model = options.model,
        .lease = lease,
        .allow_suspend = options.allow_suspend,
    };
}

pub fn budget(self: *const EvalContext) ?*Budget {
    return if (self.lease) |lease| lease.budget else null;
}

pub fn check(self: *const EvalContext) Budget.Error!void {
    if (self.budget()) |ledger| {
        if (ledger.isExhausted()) return error.Exhausted;
    }
}

pub fn charge(self: *const EvalContext, amount: Budget.Charge, backend: Budget.Backend) Budget.Error!void {
    if (self.lease) |lease| try lease.charge(amount, backend);
}

pub fn chargeWork(self: *const EvalContext, count: u64, cost: u64, backend: Budget.Backend) Budget.Error!void {
    if (self.lease) |lease| try lease.chargeWork(count, cost, backend);
}

pub fn enter(self: *const EvalContext, backend: Budget.Backend) Error!EvalContext {
    try self.check();
    var result = self.*;
    result.reservation = null;
    result.vm_depth = null;
    result.in_native = false;
    result.native_reentry = self.native_reentry or (self.in_native and backend != .native);
    if (self.reservation) |credit| result.native_reentry = result.native_reentry or !credit.allow_suspend;
    if (backend == .scheduler) result.native_reentry = false;
    const depth: u64 = @as(u64, self.depth) + (if (self.vm_depth) |value| @as(u64, value.*) else 0) + 1;
    if (depth > std.math.maxInt(u32)) {
        if (self.budget()) |ledger| return ledger.overflow(.depth, backend);
        return error.Unsupported;
    }
    result.depth = @intCast(depth);
    if (self.budget()) |ledger| try ledger.checkDepth(result.depth, backend);
    return result;
}

/// The caller creates an address-stable direct child lease before this call.
pub fn child(
    self: *const EvalContext,
    account: *Budget.AccountAllocator,
    effects: EffectDecisionTable,
) Error!EvalContext {
    try self.check();
    const lease = account.lease;
    const parent = self.lease orelse return error.Denied;
    if (lease.parent != parent) return error.Denied;
    if (lease.budget != parent.budget) return error.Denied;
    if (!self.effects.permitsChild(effects)) return error.Denied;
    var result = try self.enter(.scheduler);
    result.lease = lease;
    result.scratch = account.allocator();
    result.scratch_base = account.base;
    result.effects = effects;
    return result;
}

pub fn isUnrestricted(self: *const EvalContext) bool {
    if (self.execution != .trusted or self.mode != .concrete or self.lease != null or !self.allow_suspend) return false;
    inline for (@typeInfo(EffectDecisionTable).@"struct".fields) |field| {
        if (@field(self.effects, field.name) != .allow) return false;
    }
    return true;
}

pub fn authorize(self: *const EvalContext, spec: *const Primitive.Spec) Error!Authorization {
    try self.check();
    var selected_model: ?Version = null;
    inline for (@typeInfo(Effect).@"enum".fields) |field| {
        if (@field(spec.effects, field.name)) {
            switch (@field(self.effects, field.name)) {
                .deny => return error.Denied,
                .model => |identity| {
                    if (identity.id == 0 or identity.revision == 0) return error.Denied;
                    if (selected_model) |previous| {
                        if (!identity.eql(previous)) return error.Denied;
                    }
                    selected_model = identity;
                },
                .allow => {
                    const argument_read = comptime std.mem.eql(u8, field.name, "state_read");
                    if (self.mode != .concrete and !(argument_read and spec.reads_argument_state)) return error.Denied;
                    if (self.execution == .pure_limited and
                        !(argument_read and spec.reads_argument_state)) return error.Denied;
                },
            }
        }
    }
    if (selected_model) |identity| {
        try self.charge(.{ .work = 1 }, .code);
        return .{ .model = identity };
    }
    const allow_suspend = self.allow_suspend and !self.native_reentry and spec.suspension == .would_block;
    if (self.execution == .trusted) return .{ .invoke = .{ .allow_suspend = allow_suspend } };
    if (spec.effects.ffi or spec.effects.dynamic_loader or
        spec.effects.host or spec.effects.unknown) return error.Denied;
    if (spec.suspension == .unknown) return error.Denied;
    if (spec.suspension == .would_block and !allow_suspend) return error.Denied;
    const amount: Budget.Charge = switch (spec.resources) {
        .fixed => |cost| .{ .work = cost.work, .bytes = cost.bytes, .objects = cost.objects },
        .bounded => |cost| .{ .work = cost.work, .bytes = cost.bytes, .objects = cost.objects },
        .native => .{ .work = 1 },
        .unknown, .denied => return error.Denied,
    };
    try self.charge(amount, .native);
    return .{ .invoke = .{ .bytes = amount.bytes, .objects = amount.objects, .allow_suspend = allow_suspend } };
}

pub fn forPrimitive(self: *const EvalContext, reservation: *Reservation) Error!EvalContext {
    var result = try self.enter(.native);
    result.reservation = reservation;
    return result;
}

pub fn chargeAllocation(self: *const EvalContext, bytes: u64, objects: u64, backend: Budget.Backend) Budget.Error!void {
    const credit_bytes = if (self.reservation) |credit| @min(bytes, credit.bytes) else 0;
    const credit_objects = if (self.reservation) |credit| @min(objects, credit.objects) else 0;
    try self.charge(.{
        .work = @intFromBool(bytes != 0 or objects != 0) + bytes / 64,
        .bytes = bytes - credit_bytes,
        .objects = objects - credit_objects,
    }, backend);
    if (self.reservation) |credit| {
        credit.bytes -= credit_bytes;
        credit.objects -= credit_objects;
    }
}

pub fn stringBytes(
    self: *const EvalContext,
    pointer: [*:0]const u8,
    max_len: usize,
    backend: Budget.Backend,
) Error![:0]const u8 {
    try self.check();
    if (self.lease == null and max_len == std.math.maxInt(usize)) return std.mem.span(pointer);
    var length: usize = 0;
    while (true) {
        try self.chargeWork(1, 1, backend);
        if (pointer[length] == 0) return pointer[0..length :0];
        if (length == max_len) return error.Unsupported;
        length += 1;
    }
}

pub fn writeAll(self: *const EvalContext, bytes: []const u8) Error!void {
    try self.check();
    if (self.mode != .concrete or self.effects.io != .allow) return error.Denied;
    if (self.execution == .pure_limited) return error.Denied;
    if (self.execution != .trusted and !self.output.bounded_memory) return error.Denied;
    try self.charge(.{ .work = bytes.len, .output = bytes.len }, .formatter);
    try self.output.writer.writeAll(bytes);
}

test "context child capabilities cannot replace a model with live effects" {
    const parent: EffectDecisionTable = .{ .io = .{ .model = .{ .id = 4, .revision = 2 } } };
    try std.testing.expect(!parent.permitsChild(.{ .io = .allow }));
    try std.testing.expect(!parent.permitsChild(.{ .io = .{ .model = .{ .id = 4, .revision = 3 } } }));
    try std.testing.expect(parent.permitsChild(.{}));
    try std.testing.expect(parent.permitsChild(parent));
}

test "context child capabilities cannot add an effect" {
    const pure: EffectDecisionTable = .{};
    try std.testing.expect(!pure.permitsChild(.{ .ffi = .allow }));
    try std.testing.expect(!pure.permitsChild(.{ .io = .{ .model = .{ .id = 1, .revision = 1 } } }));
    try std.testing.expect(EffectDecisionTable.trusted().permitsChild(pure));
}
