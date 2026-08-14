const std = @import("std");
const skript = @import("../root.zig");
const Context = skript.EvalContext;
const Budget = Context.Budget;
const Evaluator = skript.Evaluator;
const Value = skript.Value;
const Error = skript.Error;
const b = skript.builtins;

const default_limits: Budget.Limits = .{
    .work = 50_000_000,
    .bytes = 128 * 1024 * 1024,
    .objects = 1_000_000,
    .nodes = 1_000_000,
    .output = 1024 * 1024,
    .processes = 0,
    .paths = 1024,
    .depth = 1024,
};

pub fn evaluate(ctx: *Context, namespace: Value, _: Value, args: []const Value) Error!Value {
    if (args.len < 3 or args.len > 4) return error.ArityMismatch;
    const mode = try parseMode(args[2]);
    // SAFETY: `ledger` is initialized before use on the root-budget branch.
    var ledger: Budget = undefined;
    // SAFETY: `lease` is assigned in either branch before it is borrowed.
    var lease: Budget.Lease = undefined;
    if (ctx.lease) |parent| {
        lease = try parent.child(std.math.maxInt(u64));
    } else {
        if (ctx.execution != .trusted or ctx.mode != .concrete) return error.Denied;
        ledger = Budget.init(ctx.runtime.io, try ctx.runtime.allocEvaluationIdentity(), default_limits);
        lease = try Budget.Lease.root(&ledger, default_limits.work);
    }
    var account = Budget.AccountAllocator.init(ctx.scratch_base, &lease, .code);
    var context = if (ctx.lease != null)
        try ctx.child(&account, ctx.effects)
    else
        try Context.limited(ctx.runtime, ctx.registry, &account, ctx.output, .{});
    context.depth = (try ctx.enter(.code)).depth;
    context.mode = mode;
    context.allow_suspend = false;
    context.native_reentry = ctx.native_reentry or ctx.in_native;
    const scope = context.activate();
    defer scope.deinit();
    const model = if (args.len == 4 and !args[3].isNil()) try parseModel(&context, args[3]) else null;
    if (ctx.model) |selected| {
        const requested = model orelse return error.Denied;
        if (!selected.eql(requested.version)) return error.Denied;
    }
    context.model = if (model) |selected| selected.version else null;
    context.effects = childEffects(ctx.effects, context.model);
    var inline_storage: [16]Value = undefined;
    var expanded = try skript.intrinsics.list.expandApplyArguments(
        &context,
        &.{ .nil, args[1] },
        &inline_storage,
    );
    defer expanded.deinit();
    const arguments = expanded.values;
    const evaluation = try Evaluator.evaluateWithModel(&context, namespace, args[0], arguments, model);
    defer evaluation.deinit();
    const residual = if (mode == .residual)
        try skript.EvalResidual.specialize(&context, args[0], .{ .arguments = arguments, .model = context.model })
    else
        null;
    var snapshot: Snapshot = .{ .context = &context, .evaluation = evaluation };
    return snapshot.outcome(residual);
}

fn parseMode(value: Value) Error!Context.Mode {
    if (value.typ != b.type_keyword) return error.TypeMismatch;
    const name = value.obj.toPtr(skript.Sym).*;
    inline for (.{ Context.Mode.dry, Context.Mode.abstract, Context.Mode.residual }) |mode| {
        if (std.mem.eql(u8, name, @tagName(mode))) return mode;
    }
    return error.Unsupported;
}

fn childEffects(parent: Context.EffectDecisionTable, model: ?Context.Version) Context.EffectDecisionTable {
    var result: Context.EffectDecisionTable = .{};
    inline for (std.meta.fields(Context.EffectDecisionTable)) |entry| {
        const before = @field(parent, entry.name);
        const private_state = std.mem.eql(u8, entry.name, "state_read") or std.mem.eql(u8, entry.name, "state_write");
        if (private_state and before == .allow) {
            @field(result, entry.name) = .allow;
        } else if (model) |version| {
            switch (before) {
                .allow => @field(result, entry.name) = .{ .model = version },
                .model => |selected| {
                    if (selected.eql(version)) @field(result, entry.name) = .{ .model = version };
                },
                .deny => {},
            }
        }
    }
    std.debug.assert(parent.permitsChild(result));
    return result;
}

fn keyword(ctx: *Context, name: []const u8) Error!Value {
    try ctx.chargeWork(name.len, 1, .code);
    const symbol = try ctx.runtime.store.getsym(name);
    return Value.keyword(symbol);
}

fn field(ctx: *Context, value: Value, name: []const u8) Error!Value {
    return skript.intrinsics.map.get(ctx, .nil, .nil, &.{ value, try keyword(ctx, name) });
}

fn versionNumber(value: Value) Error!u64 {
    if (value.typ == b.type_u64) {
        const number = value.obj.toInt(u64);
        if (number == 0) return error.TypeMismatch;
        return number;
    }
    if (value.typ != b.type_i64) return error.TypeMismatch;
    const number = value.obj.toInt(i64);
    if (number <= 0) return error.TypeMismatch;
    return @intCast(number);
}

fn parseModel(ctx: *Context, value: Value) Error!Evaluator.Model {
    return .{
        .version = .{
            .id = try versionNumber(try field(ctx, value, "id")),
            .revision = try versionNumber(try field(ctx, value, "revision")),
        },
        .lift_literal = try field(ctx, value, "lift-literal"),
        .invoke_primitive = try field(ctx, value, "invoke-primitive"),
        .decide_branch = try field(ctx, value, "decide-branch"),
        .join = try field(ctx, value, "join"),
    };
}

const Snapshot = struct {
    context: *Context,
    evaluation: Evaluator.Evaluation,

    fn map(self: *Snapshot, values: []const Value) Error!Value {
        try self.context.charge(.{ .nodes = 1 }, .code);
        return skript.intrinsics.map.create(self.context, .nil, .nil, values);
    }

    fn list(self: *Snapshot, values: []const Value) Error!Value {
        try self.context.charge(.{ .nodes = @intCast(values.len) }, .code);
        return skript.intrinsics.list.list(self.context, .nil, .nil, values);
    }

    fn key(self: *Snapshot, name: []const u8) Error!Value {
        return keyword(self.context, name);
    }

    fn version(self: *Snapshot, value: ?Context.Version) Error!Value {
        const selected = value orelse return .nil;
        return self.map(&.{
            try self.key("id"),       Value.init(b.type_u64, @enumFromInt(selected.id)),
            try self.key("revision"), Value.init(b.type_u64, @enumFromInt(selected.revision)),
        });
    }

    fn valueType(self: *Snapshot, typ: skript.Object) Error!Value {
        return self.evaluation.exportData(Value.typeValue(typ));
    }

    fn opaqueSummary(self: *Snapshot, typ: skript.Object) Error!Value {
        return self.map(&.{
            try self.key("kind"), try self.key("opaque"),
            try self.key("type"), try self.valueType(typ),
        });
    }

    fn slot(self: *Snapshot, value: Evaluator.Slot) Error!Value {
        switch (value) {
            .empty => return error.InvalidCode,
            .known => |known| {
                const exported = self.evaluation.exportData(known) catch |err| switch (err) {
                    error.Unsupported, error.Denied => return self.opaqueSummary(known.typ),
                    else => return err,
                };
                return self.map(&.{ try self.key("kind"), try self.key("known"), try self.key("value"), exported });
            },
            .unknown => |unknown| {
                var facts = unknown;
                if (facts.typ) |typ| facts.typ = (try self.valueType(typ)).obj;
                return skript.EvalModel.encodeUnknown(self.context, facts);
            },
        }
    }

    fn effectNames(self: *Snapshot, effects: skript.Primitive.EffectSet) Error!Value {
        var names: [std.meta.fields(Context.Effect).len]Value = undefined;
        var count: usize = 0;
        inline for (std.meta.fields(Context.Effect)) |entry| {
            if (@field(effects, entry.name)) {
                names[count] = try self.key(entry.name);
                count += 1;
            }
        }
        return self.list(names[0..count]);
    }

    fn effect(self: *Snapshot, value: Evaluator.Effect) Error!Value {
        var primitive: Value = .nil;
        var revision: Value = .nil;
        var name: Value = .nil;
        var callable: Value = .nil;
        switch (value.invocation) {
            .primitive => |invocation| {
                const spec = self.context.registry.spec(invocation.id) orelse return error.Denied;
                primitive = .i64(@intFromEnum(invocation.id));
                revision = .u64(invocation.revision);
                name = try skript.intrinsics.string.storeString(self.context, spec.stable_name);
            },
            .call => |invocation| callable = try self.slot(invocation.*),
        }
        const arguments = try self.context.scratch.alloc(Value, value.arguments.len);
        defer self.context.scratch.free(arguments);
        for (value.arguments, arguments) |argument, *out| out.* = try self.slot(argument);
        return self.map(&.{
            try self.key("kind"),      try self.key(@tagName(value.invocation)),
            try self.key("primitive"), primitive,
            try self.key("revision"),  revision,
            try self.key("name"),      name,
            try self.key("callable"),  callable,
            try self.key("effects"),   try self.effectNames(value.effects),
            try self.key("arguments"), try self.list(arguments),
            try self.key("path"),      if (value.path) |path| Value.i64(path) else Value.nil,
            try self.key("model"),     try self.version(value.model),
            try self.key("result"),    try self.slot(value.result),
        });
    }

    fn paths(self: *Snapshot) Error!Value {
        const source = self.evaluation.paths();
        const values = try self.context.scratch.alloc(Value, source.len);
        defer self.context.scratch.free(values);
        for (source, values) |path, *out| {
            out.* = try self.map(&.{
                try self.key("parent"),    if (path.parent) |parent| Value.i64(parent) else Value.nil,
                try self.key("condition"), try self.slot(path.condition),
                try self.key("selected"),  Value.bool(path.selected),
            });
        }
        return self.list(values);
    }

    const ResultSummary = struct { status: []const u8, key: []const u8, value: Value };

    fn resultSummary(self: *Snapshot) Error!ResultSummary {
        return switch (self.evaluation.result) {
            .empty => error.InvalidCode,
            .unknown => .{ .status = "unknown", .key = "summary", .value = try self.slot(self.evaluation.result) },
            .known => |value| known: {
                const exported = self.evaluation.exportData(value) catch |err| switch (err) {
                    error.Unsupported, error.Denied => return .{
                        .status = "unknown",
                        .key = "summary",
                        .value = try self.opaqueSummary(value.typ),
                    },
                    else => return err,
                };
                const failed = value.typ == b.type_error;
                break :known .{
                    .status = if (failed) "failed" else "value",
                    .key = if (failed) "error" else "value",
                    .value = exported,
                };
            },
        };
    }

    fn dependencySummary(self: *Snapshot, value: skript.EvalResidual.Dependency) Error!Value {
        return self.map(&.{
            try self.key("namespace"),       try self.slot(.{ .known = value.namespace }),
            try self.key("binding"),         Value.symbol(value.binding),
            try self.key("cell-id"),         Value.u64(value.expected.cell_id),
            try self.key("revision"),        Value.u64(value.expected.revision),
            try self.key("value"),           try self.slot(.{ .known = value.expected.value }),
            try self.key("method-id"),       Value.u64(value.expected.method_id),
            try self.key("method-revision"), Value.u64(value.expected.method_revision),
        });
    }

    fn assumptions(self: *Snapshot, residual: *const skript.EvalResidual) Error!Value {
        const captures = try self.list(residual.expected_captures);
        const dependencies = try self.context.scratch.alloc(Value, residual.dependencies.len);
        defer self.context.scratch.free(dependencies);
        for (residual.dependencies, dependencies) |entry, *out| {
            out.* = try self.dependencySummary(entry);
        }
        return self.map(&.{
            try self.key("source-code-id"),   Value.u64(residual.source_code_id),
            try self.key("source-revision"),  Value.u64(residual.source_code_revision),
            try self.key("function-id"),      Value.u64(@intFromEnum(residual.source_function)),
            try self.key("registry-version"), Value.u64(residual.registry_version),
            try self.key("arguments"),        try self.list(residual.expected_arguments),
            try self.key("captures"),         captures,
            try self.key("dependencies"),     try self.list(dependencies),
            try self.key("model"),            try self.version(residual.model),
        });
    }

    fn outcome(self: *Snapshot, residual: ?*const skript.EvalResidual) Error!Value {
        const source = self.evaluation.effects();
        const effects = try self.context.scratch.alloc(Value, source.len);
        defer self.context.scratch.free(effects);
        for (source, effects) |effect_value, *out| out.* = try self.effect(effect_value);
        var report = try self.resultSummary();
        if (self.evaluation.hasDeferred()) report.status = "unknown";
        if (residual != null) report.status = "residual";
        var fields: [16]Value = undefined;
        fields[0..10].* = .{
            try self.key("status"),   try self.key(report.status),
            try self.key(report.key), report.value,
            try self.key("effects"),  try self.list(effects),
            try self.key("paths"),    try self.paths(),
            try self.key("model"),    try self.version(self.context.model),
        };
        var count: usize = 10;
        if (residual) |code| {
            const callable = try code.callable(self.context);
            fields[10..16].* = .{
                try self.key("residual"),    callable,
                try self.key("code"),
                try self.context.runtime.inspectBoundCode(
                    callable.obj.toRef().deref(skript.data.Closure),
                    @intCast(default_limits.nodes),
                ),
                try self.key("assumptions"), try self.assumptions(code),
            };
            count = fields.len;
        }
        return self.map(fields[0..count]);
    }
};

test "public evaluator returns isolated results without mutating arguments" {
    const runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const result = try runtime.evalString(
        "(let ((input (hash-map :k 1))) " ++
            "(let ((outcome (@evaluate (fn (m) (map-set! m :k 7) (map-get m :k)) (list input) :dry))) " ++
            "(list (map-get outcome :status) (map-get outcome :value) (map-get input :k))))",
    );
    var current = result;
    var values: [3]skript.Value = undefined;
    for (&values) |*value| {
        try std.testing.expectEqual(skript.builtins.type_cons, current.typ);
        const pair = current.obj.toRef().deref([2]skript.Value).*;
        value.* = pair[0];
        current = pair[1];
    }
    try std.testing.expect(current.isNil());
    try std.testing.expectEqual(skript.builtins.type_keyword, values[0].typ);
    try std.testing.expectEqualStrings("value", values[0].obj.toPtr(skript.Sym).*);
    try std.testing.expectEqual(skript.Value.i64(7), values[1]);
    try std.testing.expectEqual(skript.Value.i64(1), values[2]);
}

test "public evaluator reports applied target values in dry and residual modes" {
    const runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    try std.testing.expectEqual(Value.i64(7), try runtime.evalString(
        "(map-get (evaluate (fn () (apply @i64.add 3 '(4))) nil :dry) :value)",
    ));
    try std.testing.expectEqual(Value.i64(7), try runtime.evalString(
        "(def applied-residual-report (evaluate (fn (x) (apply @i64.add x '(2))) '(5) :residual)) " ++
            "(def applied-residual (map-get applied-residual-report :residual)) " ++
            "(applied-residual 5)",
    ));
    try std.testing.expectError(error.Denied, runtime.evalString("(applied-residual 6)"));
}

test "public evaluator rejects cyclic argument lists" {
    const runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const closure = try runtime.evalString("(fn (x) x)");
    const ref = try runtime.store.create([2]Value);
    const cyclic = Value.cons(ref.toObject());
    ref.deref([2]Value).* = .{ Value.i64(1), cyclic };
    try std.testing.expectError(
        error.TypeMismatch,
        evaluate(runtime.context(), runtime.root_ns, .nil, &.{
            closure,
            cyclic,
            Value.keyword(try runtime.store.getsym("dry")),
        }),
    );
}

test "public evaluator runs Skript effect models" {
    const runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const result = try runtime.evalString(
        "(def eval-test-model (hash-map :id 74 :revision 2 " ++
            ":lift-literal (fn (value) :default) " ++
            ":invoke-primitive (fn (primitive arguments) " ++
            "(if (= (map-get primitive :name) \"receive\") (list :known 17) :default)) " ++
            ":decide-branch (fn (condition) :default) " ++
            ":join (fn (left right) :default))) " ++
            "(def eval-test-outcome (evaluate (fn () (@receive)) nil :dry eval-test-model)) " ++
            "(map-get eval-test-outcome :value)",
    );
    try std.testing.expectEqual(Value.i64(17), result);
    const identity = try runtime.evalString(
        "(map-get (map-get (fst (map-get eval-test-outcome :effects)) :model) :id)",
    );
    try std.testing.expectEqual(Value.u64(74), identity);
}

test "public evaluator models bounded integer inputs and prunes impossible effects" {
    const runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const result = try runtime.evalString(
        "(def range-model (hash-map :id 83 :revision 1 " ++
            ":lift-literal (fn (value) " ++
            "(if (int? value) (if (= value 17) " ++
            "(list :unknown (hash-map :type @i64 :i64-range (list 1 3))) :default) :default)) " ++
            ":invoke-primitive (fn (primitive arguments) :default) " ++
            ":decide-branch (fn (condition) :default) " ++
            ":join (fn (left right) :default))) " ++
            "(def range-result (evaluate " ++
            "(fn (x) (if (< x 0) (write \"impossible\") 42)) " ++
            "(list 17) :abstract range-model)) " ++
            "(map-get range-result :value)",
    );
    try std.testing.expectEqual(Value.i64(42), result);
    try std.testing.expect((try runtime.evalString("(map-get range-result :effects)")).isNil());
}

test "public residual evaluation returns guarded executable Code" {
    const runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    try std.testing.expectEqual(Value.i64(7), try runtime.evalString(
        "(def residual-report (evaluate (fn (x) (+ (* x 2) 1)) (list 3) :residual)) " ++
            "(def residual-function (map-get residual-report :residual)) " ++
            "(residual-function 3)",
    ));
    try std.testing.expectError(error.Denied, runtime.evalString("(residual-function 4)"));
}
