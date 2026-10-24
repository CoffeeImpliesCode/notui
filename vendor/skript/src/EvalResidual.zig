const std = @import("std");
const skript = @import("root.zig");
const Code = @import("code.zig");
const Primitive = @import("primitive.zig");
const Runtime = @import("Runtime.zig");
const EvalContext = @import("EvalContext.zig");

const Allocator = std.mem.Allocator;
const Closure = skript.data.Closure;
const Value = skript.Value;
const b = skript.builtins;

const callables = @import("autodiff/callable.zig");
const Self = @This();
pub const Residual = Self;

pub const Fold = struct {
    node: Code.BoundNodeId,
    value: Value,
};

pub const Dependency = struct {
    namespace: Value,
    binding: Code.Symbol,
    expected: Runtime.Dependency,
};

pub const Options = struct {
    arguments: []const Value,
    folds: []const Fold = &.{},
    dependencies: []const Dependency = &.{},
    model: ?skript.EvalContext.Version = null,
};

/// Fresh semantic code for this residual. Its arrays either share immutable
/// Runtime-owned source arrays or point into Runtime's retained code arena.
code: *const Code.Code,

runtime: *Runtime,
source_closure: *const Closure,
source_code: *const Code.Code,
source_code_id: u32,
source_code_revision: u64,
residual_code_id: u32,
residual_code_revision: u64,
source_function: Code.FunctionId,
parent_namespace: Value,
expected_arguments: []const Value,
expected_captures: []const Value,
dependencies: []const Dependency,
lowered_functions: []const Runtime.FnTableEntry,
registry: *const Primitive.RegistryVersion,
registry_version: u64,
model: ?EvalContext.Version,
validation: skript.data.ClosureGuard,
callable_value: Value = .nil,

const SourceInfo = struct {
    closure: *const Closure,
    code: *const Code.Code,
    function: *const Code.Function,
};

fn sourceInfo(runtime: *Runtime, source: Value) skript.Error!SourceInfo {
    if (source.typ != b.type_closure or source.obj == .null) return error.TypeMismatch;
    const closure = source.obj.toRef().deref(Closure);
    const code = closure.code orelse return error.Unsupported;
    if (code.owner != @as(?*const anyopaque, runtime)) return error.Denied;
    if (code.id == 0 or code.revision == 0) return error.InvalidCode;
    if (closure.function_id == .invalid) return error.InvalidCode;
    const function_index = @backingInt(closure.function_id);
    if (function_index >= code.functions.len) return error.InvalidCode;
    const function = code.function(closure.function_id) orelse return error.InvalidCode;
    if (closure.arglist.len != function.parameter_count) return error.InvalidCode;
    if (closure.captures.len != function.capture_count) return error.InvalidCode;
    if (closure.result_count != function.result_count) return error.InvalidCode;
    if (closure.result_count != 1) return error.Unsupported;
    return .{ .closure = closure, .code = code, .function = function };
}

pub fn specialize(
    ctx: *EvalContext,
    source: Value,
    options: Options,
) skript.Error!*Residual {
    const scope = ctx.activate();
    defer scope.deinit();
    const info = try sourceInfo(ctx.runtime, source);
    if (options.arguments.len != info.closure.arglist.len) return error.ArityMismatch;
    try info.code.validate(ctx.scratch, ctx);

    var pass = try Specializer.init(ctx, info, options.arguments);
    defer pass.deinit();
    try pass.run();

    var folds: std.ArrayList(Fold) = .empty;
    defer folds.deinit(ctx.scratch);
    try appendFolds(ctx, ctx.scratch, &folds, options.folds);
    try appendFolds(ctx, ctx.scratch, &folds, pass.folds.items);

    var dependencies: std.ArrayList(Dependency) = .empty;
    defer dependencies.deinit(ctx.scratch);
    try appendDependencies(ctx, ctx.scratch, &dependencies, options.dependencies);
    try appendDependencies(ctx, ctx.scratch, &dependencies, pass.dependencies.items);

    return create(ctx, source, .{
        .arguments = options.arguments,
        .folds = folds.items,
        .dependencies = dependencies.items,
        .model = options.model,
    });
}

fn appendFolds(
    ctx: *EvalContext,
    allocator: Allocator,
    destination: *std.ArrayList(Fold),
    source: []const Fold,
) skript.Error!void {
    for (source) |candidate| {
        try ctx.chargeWork(1, 1, .code);
        var present = false;
        for (destination.items) |existing| {
            try ctx.chargeWork(1, 1, .code);
            if (existing.node == candidate.node) {
                present = true;
                if (!sameValue(existing.value, candidate.value)) return error.InvalidCode;
                break;
            }
        }
        if (!present) try destination.append(allocator, candidate);
    }
}

fn appendDependencies(
    ctx: *EvalContext,
    allocator: Allocator,
    destination: *std.ArrayList(Dependency),
    source: []const Dependency,
) skript.Error!void {
    for (source) |candidate| {
        try ctx.chargeWork(1, 1, .code);
        var present = false;
        for (destination.items) |existing| {
            try ctx.chargeWork(1, 1, .code);
            if (sameValue(existing.namespace, candidate.namespace) and
                existing.binding == candidate.binding)
            {
                present = true;
                if (!sameDependency(existing.expected, candidate.expected)) return error.InvalidCode;
                break;
            }
        }
        if (!present) try destination.append(allocator, candidate);
    }
}

const Specializer = struct {
    ctx: *EvalContext,
    runtime: *Runtime,
    source: *const Code.Code,
    closure: *const Closure,
    function: *const Code.Function,
    arguments: []const Value,
    known: []?Value,
    folds: std.ArrayList(Fold) = .empty,
    dependencies: std.ArrayList(Dependency) = .empty,
    blocked: bool = false,

    fn init(
        ctx: *EvalContext,
        info: SourceInfo,
        arguments: []const Value,
    ) skript.Error!Specializer {
        const known = try ctx.scratch.alloc(?Value, info.code.values.len);
        @memset(known, null);
        return .{
            .ctx = ctx,
            .runtime = ctx.runtime,
            .source = info.code,
            .closure = info.closure,
            .function = info.function,
            .arguments = arguments,
            .known = known,
        };
    }

    fn deinit(self: *Specializer) void {
        self.folds.deinit(self.ctx.scratch);
        self.dependencies.deinit(self.ctx.scratch);
        self.ctx.scratch.free(self.known);
        self.* = undefined;
    }

    fn run(self: *Specializer) skript.Error!void {
        try self.seedParameters();
        try self.seedCaptures();

        const function_index = @backingInt(self.function.id);
        if (function_index >= self.source.functions.len) return error.InvalidCode;
        const block_start: usize = self.function.block_start;
        const block_end = std.math.add(
            usize,
            block_start,
            @as(usize, self.function.block_count),
        ) catch
            return error.InvalidCode;
        if (block_end > self.source.function_blocks.len) return error.InvalidCode;
        const entry_id = self.source.function_blocks[block_start];
        const entry_index = @backingInt(entry_id);
        if (entry_index >= self.source.blocks.len) return error.InvalidCode;
        const entry = self.source.blocks[entry_index];
        const node_start: usize = entry.node_start;
        const node_end = std.math.add(usize, node_start, entry.node_count) catch
            return error.InvalidCode;
        if (node_end > self.source.block_nodes.len) return error.InvalidCode;
        for (self.source.block_nodes[node_start..node_end]) |node_id| {
            try self.ctx.chargeWork(1, 1, .code);
            const node_index = @backingInt(node_id);
            if (node_index >= self.source.nodes.len) return error.InvalidCode;
            try self.visit(self.source.nodes[node_index]);
        }
        if (self.folds.items.len == 0) return;
        if (!try self.collectGlobalDependencies()) {
            self.folds.clearRetainingCapacity();
            self.dependencies.clearRetainingCapacity();
        }
    }

    fn seedParameters(self: *Specializer) skript.Error!void {
        const start: usize = self.function.parameter_start;
        const end = std.math.add(usize, start, @as(usize, self.function.parameter_count)) catch
            return error.InvalidCode;
        if (end > self.source.parameters.len) return error.InvalidCode;
        if (self.closure.arglist.len != end - start) return error.InvalidCode;
        if (self.arguments.len != end - start) return error.ArityMismatch;
        for (self.source.parameters[start..end], self.arguments) |binding_id, value| {
            if (!isImmediateScalar(value)) continue;
            const binding_index = @backingInt(binding_id);
            if (binding_index >= self.source.bindings.len) return error.InvalidCode;
            try self.setKnown(self.source.bindings[binding_index].value, value);
        }
    }

    fn seedCaptures(self: *Specializer) skript.Error!void {
        const start: usize = self.function.capture_start;
        const end = std.math.add(usize, start, @as(usize, self.function.capture_count)) catch
            return error.InvalidCode;
        if (end > self.source.capture_values.len or end > self.source.captures.len) {
            return error.InvalidCode;
        }
        if (self.closure.captures.len != end - start) return error.InvalidCode;
        for (self.source.capture_values[start..end], self.closure.captures) |value_id, value| {
            if (!isImmediateScalar(value)) continue;
            try self.setKnown(value_id, value);
        }
    }

    fn visit(self: *Specializer, node: Code.Node) skript.Error!void {
        switch (node.operation) {
            .literal, .quote => |value| {
                if (isImmediateScalar(value)) try self.setKnown(node.result, value);
            },
            .local_read => |binding_id| {
                const binding_index = @backingInt(binding_id);
                if (binding_index >= self.source.bindings.len) return error.InvalidCode;
                const value_id = self.source.bindings[binding_index].value;
                if (self.getKnown(value_id)) |value| try self.setKnown(node.result, value);
            },
            .global_read => |global_id| {
                const global_index = @backingInt(global_id);
                if (global_index >= self.source.globals.len) return error.InvalidCode;
                const global = self.source.globals[global_index];
                const dependency = try self.readDependency(global.name) orelse return;
                if (isSafeDependencyValue(dependency.value, dependency)) {
                    try self.setKnown(node.result, dependency.value);
                } else {
                    self.blocked = true;
                }
            },
            .arithmetic => |arithmetic| {
                if (self.blocked) return;
                const left = self.getKnown(arithmetic.left) orelse {
                    self.blocked = true;
                    return;
                };
                const right = self.getKnown(arithmetic.right) orelse {
                    self.blocked = true;
                    return;
                };
                const value = try self.foldArithmetic(arithmetic, left, right) orelse {
                    self.blocked = true;
                    return;
                };
                try self.appendFold(node.id, value);
                try self.setKnown(node.result, value);
            },
            .primitive_call => |call| {
                if (self.blocked) return;
                if (call.result_count != 1) return self.block();
                const argument_values = self.operandValues(call.args) catch |err| switch (err) {
                    error.Unsupported => {
                        self.blocked = true;
                        return;
                    },
                    else => return err,
                };
                defer self.ctx.scratch.free(argument_values);
                const value = try self.foldPrimitive(call, argument_values) orelse {
                    self.blocked = true;
                    return;
                };
                try self.appendFold(node.id, value);
                try self.setKnown(node.result, value);
            },
            else => self.block(),
        }
    }
    fn block(self: *Specializer) void {
        self.blocked = true;
    }

    fn operandValues(self: *Specializer, range: Code.OperandRange) skript.Error![]const Value {
        const start: usize = range.start;
        const end = std.math.add(usize, start, @as(usize, range.len)) catch return error.InvalidCode;
        if (end > self.source.operands.len) return error.InvalidCode;
        const values = try self.ctx.scratch.alloc(Value, @as(usize, range.len));
        errdefer self.ctx.scratch.free(values);
        for (self.source.operands[start..end], values) |value_id, *out| {
            out.* = self.getKnown(value_id) orelse return error.Unsupported;
        }
        return values;
    }

    fn getKnown(self: *const Specializer, value_id: Code.ValueId) ?Value {
        const index = @backingInt(value_id);
        if (value_id == .invalid or index >= self.known.len) return null;
        return self.known[index];
    }

    fn setKnown(self: *Specializer, value_id: Code.ValueId, value: Value) skript.Error!void {
        const index = @backingInt(value_id);
        if (value_id == .invalid or index >= self.known.len) return error.InvalidCode;
        self.known[index] = value;
    }

    fn readDependency(self: *Specializer, binding: Code.Symbol) skript.Error!?Runtime.Dependency {
        const dependency = self.runtime.readDependency(self.closure.parent_ns, binding) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Exhausted => return error.Exhausted,
            else => return null,
        };
        if (isSafeDependencyValue(dependency.value, dependency)) {
            try self.appendDependency(.{
                .namespace = self.closure.parent_ns,
                .binding = binding,
                .expected = dependency,
            });
        }
        return dependency;
    }

    fn appendDependency(self: *Specializer, candidate: Dependency) skript.Error!void {
        try self.ctx.chargeWork(1, 1, .code);
        for (self.dependencies.items) |existing| {
            try self.ctx.chargeWork(1, 1, .code);
            if (sameValue(existing.namespace, candidate.namespace) and
                existing.binding == candidate.binding)
            {
                if (!sameDependency(existing.expected, candidate.expected)) return error.Denied;
                return;
            }
        }
        try self.dependencies.append(self.ctx.scratch, candidate);
    }

    fn appendFold(self: *Specializer, node: Code.BoundNodeId, value: Value) skript.Error!void {
        try appendFolds(self.ctx, self.ctx.scratch, &self.folds, &.{.{ .node = node, .value = value }});
    }

    fn collectGlobalDependencies(self: *Specializer) skript.Error!bool {
        for (self.source.nodes) |node| {
            if (node.function != self.function.id) continue;
            try self.ctx.chargeWork(1, 1, .code);
            switch (node.operation) {
                .ns_push, .ns_pop => return false,
                .global_read => |global_id| {
                    const index = @backingInt(global_id);
                    if (index >= self.source.globals.len) return error.InvalidCode;
                    const global = self.source.globals[index];
                    const dependency = self.runtime.readDependency(
                        self.closure.parent_ns,
                        global.name,
                    ) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.Exhausted => return error.Exhausted,
                        else => return false,
                    };
                    if (!isSafeDependencyValue(dependency.value, dependency)) return false;
                    try self.appendDependency(.{
                        .namespace = self.closure.parent_ns,
                        .binding = global.name,
                        .expected = dependency,
                    });
                },
                else => {},
            }
        }
        return true;
    }

    fn foldArithmetic(
        self: *Specializer,
        arithmetic: Code.Arithmetic,
        left: Value,
        right: Value,
    ) skript.Error!?Value {
        if (arithmetic.tail) return null;
        if (arithmetic.callee == .invalid) return null;
        const callee = self.getKnown(arithmetic.callee) orelse return null;
        if (!sameValue(callee, arithmetic.expected_callee)) return null;
        if (!try hasDependencyValue(
            self.ctx,
            self.dependencies.items,
            self.closure.parent_ns,
            arithmetic.expected_callee,
        )) return null;
        if (arithmetic.expected_callee.typ != b.type_method or
            arithmetic.expected_callee.obj == .null)
        {
            return null;
        }
        const method = arithmetic.expected_callee.obj.toRef().deref(skript.data.Method);
        if (!method.locked or method.id == 0) return null;
        const target = method.get(self.runtime, &.{ left, right }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Exhausted => return error.Exhausted,
            else => return null,
        };
        const expected_function = canonicalArithmeticFunction(arithmetic.op, left.typ) orelse return null;
        if (right.typ != left.typ or target.typ != b.type_intrinsic) return null;
        if (target.obj != Value.intrinsic(expected_function).obj) return null;
        const primitive_id = self.ctx.registry.idForNative(target.obj.toPtr(skript.FuncPtr)) orelse return null;
        const spec = self.ctx.registry.spec(primitive_id) orelse return null;
        if (spec.id != primitive_id or !isPurePrimitive(spec)) return null;
        return foldNumeric(arithmetic.op, left, right);
    }

    fn foldPrimitive(
        self: *Specializer,
        call: Code.PrimitiveCall,
        arguments: []const Value,
    ) skript.Error!?Value {
        if (arguments.len != 2) return null;
        const spec = self.ctx.registry.spec(call.primitive) orelse return null;
        if (spec.id != call.primitive or !isPurePrimitive(spec)) return null;
        const target = switch (spec.invoke) {
            .native => |function| function,
            .closure => return null,
        };
        const primitive_id = self.ctx.registry.idForNative(target) orelse return null;
        if (primitive_id != call.primitive) return null;
        const operation = canonicalPrimitiveOperation(target, arguments[0].typ) orelse return null;
        if (arguments[0].typ != arguments[1].typ) return null;
        return foldNumeric(operation, arguments[0], arguments[1]);
    }
};

fn hasDependencyValue(
    ctx: *const EvalContext,
    dependencies: []const Dependency,
    namespace: Value,
    value: Value,
) skript.Error!bool {
    for (dependencies) |dependency| {
        try ctx.chargeWork(1, 1, .code);
        if (sameValue(dependency.namespace, namespace) and
            sameValue(dependency.expected.value, value))
        {
            return true;
        }
    }
    return false;
}

fn isPurePrimitive(spec: *const Primitive.Spec) bool {
    if (!spec.effects.eql(.none)) return false;
    if (spec.callbacks != .none) return false;
    if (spec.suspension != .never) return false;
    return switch (spec.resources) {
        .fixed, .native => true,
        .bounded => true,
        .unknown, .denied => false,
    };
}

fn canonicalArithmeticFunction(op: Code.ArithOp, typ: skript.Object) ?skript.FuncPtr {
    if (typ == b.type_i64) {
        return switch (op) {
            .add => &skript.intrinsics.int.i64_add,
            .sub => &skript.intrinsics.int.i64_sub,
            .mul => &skript.intrinsics.int.i64_mul,
            .div => &skript.intrinsics.int.i64_div,
            .equal => &skript.intrinsics.int.i64_eq,
            .less => &skript.intrinsics.int.i64_lt,
            .greater => &skript.intrinsics.int.i64_gt,
        };
    }
    if (typ == b.type_f64) {
        return switch (op) {
            .add => &skript.intrinsics.float.f64_add,
            .sub => &skript.intrinsics.float.f64_sub,
            .mul => &skript.intrinsics.float.f64_mul,
            .div => &skript.intrinsics.float.f64_div,
            .equal => &skript.intrinsics.float.f64_eq,
            .less => &skript.intrinsics.float.f64_lt,
            .greater => &skript.intrinsics.float.f64_gt,
        };
    }
    return null;
}

fn canonicalPrimitiveOperation(function: skript.FuncPtr, typ: skript.Object) ?Code.ArithOp {
    if (typ == b.type_i64) {
        if (function == &skript.intrinsics.int.i64_add) return .add;
        if (function == &skript.intrinsics.int.i64_sub) return .sub;
        if (function == &skript.intrinsics.int.i64_mul) return .mul;
        if (function == &skript.intrinsics.int.i64_div) return .div;
        if (function == &skript.intrinsics.int.i64_eq) return .equal;
        if (function == &skript.intrinsics.int.i64_lt) return .less;
        if (function == &skript.intrinsics.int.i64_gt) return .greater;
    }
    if (typ == b.type_f64) {
        if (function == &skript.intrinsics.float.f64_add) return .add;
        if (function == &skript.intrinsics.float.f64_sub) return .sub;
        if (function == &skript.intrinsics.float.f64_mul) return .mul;
        if (function == &skript.intrinsics.float.f64_div) return .div;
        if (function == &skript.intrinsics.float.f64_eq) return .equal;
        if (function == &skript.intrinsics.float.f64_lt) return .less;
        if (function == &skript.intrinsics.float.f64_gt) return .greater;
    }
    return null;
}

fn foldNumeric(op: Code.ArithOp, left: Value, right: Value) ?Value {
    if (left.typ != right.typ) return null;
    if (left.typ == b.type_i64) {
        const a = left.obj.toInt(i64);
        const b_value = right.obj.toInt(i64);
        return switch (op) {
            .add => Value.i64(a +% b_value),
            .sub => Value.i64(a -% b_value),
            .mul => Value.i64(a *% b_value),
            .div => if (b_value == 0 or
                (a == std.math.minInt(i64) and b_value == -1))
                null
            else
                Value.i64(@divTrunc(a, b_value)),
            .equal => Value.bool(a == b_value),
            .less => Value.bool(a < b_value),
            .greater => Value.bool(a > b_value),
        };
    }
    if (left.typ == b.type_f64) {
        const a = left.obj.tof64();
        const b_value = right.obj.tof64();
        return switch (op) {
            .add => Value.f64(a + b_value),
            .sub => Value.f64(a - b_value),
            .mul => Value.f64(a * b_value),
            .div => Value.f64(a / b_value),
            .equal => Value.bool(a == b_value),
            .less => Value.bool(a < b_value),
            .greater => Value.bool(a > b_value),
        };
    }
    return null;
}

pub fn create(
    ctx: *EvalContext,
    source: Value,
    options: Options,
) skript.Error!*Residual {
    const runtime = ctx.runtime;
    const scope = ctx.activate();
    defer scope.deinit();

    try ctx.check();
    const registry = runtime.intrinsics.registryVersion();
    if (ctx.registry != registry) return error.Denied;
    if (registry.version == 0) return error.Denied;
    try validateModel(ctx, options.model);

    const info = try sourceInfo(runtime, source);
    const source_closure = info.closure;
    const source_code = info.code;
    const source_function = info.function;
    const source_function_index = @backingInt(source_closure.function_id);
    try source_code.validate(ctx.scratch, ctx);
    if (options.arguments.len != source_closure.arglist.len) return error.ArityMismatch;
    const expected_arguments = try copyGuardValues(runtime.static, options.arguments);
    const expected_captures = try copyGuardValues(runtime.static, source_closure.captures);

    if (options.folds.len > source_code.nodes.len) return error.InvalidCode;
    for (options.folds, 0..) |fold, fold_index| {
        try ctx.chargeWork(1, 1, .code);
        try validateFold(
            ctx,
            runtime,
            source_closure.parent_ns,
            source_code,
            options.dependencies,
            fold,
        );
        for (options.folds[0..fold_index]) |previous| {
            try ctx.chargeWork(1, 1, .code);
            if (previous.node == fold.node) return error.InvalidCode;
        }
    }
    if (options.folds.len > 0) {
        try validateFoldDependencies(
            ctx,
            source_closure.parent_ns,
            source_code,
            source_function.id,
            options.dependencies,
        );
    }
    const dependencies = try copyDependencies(
        ctx,
        runtime.static,
        runtime,
        options.dependencies,
    );

    const residual_code = try buildCode(runtime, ctx, source_code, options.folds);
    const lowered = try runtime.lowerCode(ctx.scratch, residual_code);
    if (source_function_index >= lowered.fns.len) return error.InvalidCode;
    const lowered_function = lowered.fns[source_function_index];
    const lowered_code = lowered_function.code orelse return error.InvalidCode;
    if (lowered_code != residual_code) return error.InvalidCode;
    if (lowered_function.function != source_closure.function_id) return error.InvalidCode;
    if (lowered_function.result_count != source_function.result_count) return error.InvalidCode;

    const residual = try runtime.static.create(Residual);
    residual.* = .{
        .code = residual_code,
        .runtime = runtime,
        .source_closure = source_closure,
        .source_code = source_code,
        .source_code_id = source_code.id,
        .source_code_revision = source_code.revision,
        .residual_code_id = residual_code.id,
        .residual_code_revision = residual_code.revision,
        .source_function = source_closure.function_id,
        .parent_namespace = source_closure.parent_ns,
        .expected_arguments = expected_arguments,
        .expected_captures = expected_captures,
        .dependencies = dependencies,
        .lowered_functions = lowered.fns,
        .registry = registry,
        .registry_version = registry.version,
        .model = options.model,
        .validation = .{
            .context = residual,
            .check = &checkMetadata,
            .check_arguments = &checkArguments,
            .trace = &traceResidual,
        },
    };
    residual.callable_value = try makeClosure(residual);
    return residual;
}

pub fn callable(self: *const Residual, ctx: *EvalContext) skript.Error!Value {
    try ctx.check();
    if (ctx.runtime != self.runtime) return error.Denied;
    return self.callable_value;
}

pub fn invoke(self: *const Residual, ctx: *EvalContext, args: []const Value) skript.Error!Value {
    return self.runtime.applyWithContext(ctx, self.parent_namespace, try self.callable(ctx), args);
}

fn traceResidual(context: *const anyopaque, visitor: *skript.Store.MarkVisitor) anyerror!void {
    const self: *const Residual = @ptrCast(@alignCast(context));
    try visitor.visitValue(self.parent_namespace);
    for (self.expected_arguments) |value| try visitor.visitValue(value);
    for (self.expected_captures) |value| try visitor.visitValue(value);
    for (self.dependencies) |dependency| {
        try visitor.visitValue(dependency.namespace);
        try visitor.visitValue(dependency.expected.value);
    }
    try callables.traceClosureRef(self.source_closure, visitor);
    try callables.traceCodeGraph(self.source_code, visitor);
    try callables.traceCodeGraph(self.code, visitor);
    for (self.lowered_functions) |function| {
        try visitor.visitValue(function.source);
        try visitor.visitValue(function.body);
        for (function.constants) |value| try visitor.visitValue(value);
    }
    if (self.source_closure.guard) |inherited| {
        const trace = inherited.trace orelse return error.UntracedAllocation;
        try visitor.visitGuard(trace, inherited.context);
    }
}

fn checkMetadata(runtime: *Runtime, opaque_context: *const anyopaque) skript.Error!void {
    const self: *const Residual = @ptrCast(@alignCast(opaque_context));
    if (runtime != self.runtime) return error.Denied;
    const ctx = runtime.context();
    try ctx.check();
    if (ctx.reentry != null) return error.Denied;
    if (ctx.model != null or self.model != null) return error.Denied;
    if (ctx.registry != self.registry or ctx.registry.version != self.registry_version) return error.Denied;
    if (runtime.intrinsics.registryVersion() != self.registry) return error.Denied;
    if (!sourceIdentityValid(self)) return error.Denied;
    if (!sameValue(self.source_closure.parent_ns, self.parent_namespace)) return error.Denied;
    if (self.source_closure.captures.len != self.expected_captures.len) return error.Denied;
    try ctx.chargeWork(self.expected_captures.len, 1, .code);
    for (self.source_closure.captures, self.expected_captures) |actual, expected| {
        if (!sameValue(actual, expected)) return error.Denied;
    }
    for (self.dependencies) |dependency| {
        try ctx.charge(.{ .work = 1 }, .code);
        const current = runtime.readDependency(dependency.namespace, dependency.binding) catch |err| switch (err) {
            error.OutOfMemory, error.Exhausted => return err,
            else => return error.Denied,
        };
        if (!sameDependency(current, dependency.expected)) return error.Denied;
    }
    if (self.source_closure.guard) |parent| {
        var child = try ctx.enter(.code);
        const scope = child.activate();
        defer scope.deinit();
        try parent.check(runtime, parent.context);
    }
}

fn checkArguments(runtime: *Runtime, opaque_context: *const anyopaque, args: []const Value) skript.Error!void {
    const self: *const Residual = @ptrCast(@alignCast(opaque_context));
    if (runtime != self.runtime or args.len != self.expected_arguments.len) return error.Denied;
    const ctx = runtime.context();
    try ctx.chargeWork(args.len, 1, .code);
    for (args, self.expected_arguments) |actual, expected| {
        if (!sameValue(actual, expected)) return error.Denied;
    }
    if (self.source_closure.guard) |parent| {
        if (parent.check_arguments) |check| {
            var child = try ctx.enter(.code);
            const scope = child.activate();
            defer scope.deinit();
            try check(runtime, parent.context, args);
        }
    }
}

fn validateModel(ctx: *const EvalContext, model: ?EvalContext.Version) skript.Error!void {
    if (ctx.model) |selected| {
        const expected = model orelse return error.Denied;
        if (!selected.eql(expected)) return error.Denied;
    }
    if (model) |expected| {
        if (expected.id == 0 or expected.revision == 0) return error.Denied;
    }
    inline for (@typeInfo(EvalContext.EffectDecisionTable).@"struct".field_names) |name| {
        switch (@field(ctx.effects, name)) {
            .model => |selected| {
                const expected = model orelse return error.Denied;
                if (!selected.eql(expected)) return error.Denied;
            },
            .allow, .deny => {},
        }
    }
}

fn sameValue(left: Value, right: Value) bool {
    return left.typ == right.typ and left.obj == right.obj;
}

fn isImmediateScalar(value: Value) bool {
    if (value.typ == b.type_nil or value.typ == b.type_bool or
        value.typ == b.type_symbol or value.typ == b.type_keyword)
    {
        return true;
    }
    const tag = @backingInt(value.typ);
    if (tag >= b.type_float and tag <= b.type_float_max) return true;
    if (tag >= b.type_uint and tag <= b.type_uint_max) return true;
    if (tag >= b.type_int and tag <= b.type_int_max) return true;
    if (tag >= b.type_complex and tag <= @backingInt(b.type_c32)) return true;
    return false;
}

fn isNumericScalar(value: Value) bool {
    const tag = @backingInt(value.typ);
    if (tag >= b.type_float and tag <= b.type_float_max) return true;
    if (tag >= b.type_uint and tag <= b.type_uint_max) return true;
    if (tag >= b.type_int and tag <= b.type_int_max) return true;
    if (tag >= b.type_complex and tag <= @backingInt(b.type_c32)) return true;
    return false;
}

fn copyGuardValues(allocator: Allocator, values: []const Value) skript.Error![]const Value {
    for (values) |value| {
        if (!isImmediateScalar(value)) return error.Denied;
    }
    return allocator.dupe(Value, values);
}

fn copyDependencies(
    ctx: *const EvalContext,
    allocator: Allocator,
    runtime: *Runtime,
    dependencies: []const Dependency,
) skript.Error![]const Dependency {
    for (dependencies, 0..) |dependency, index| {
        try ctx.chargeWork(1, 1, .code);
        if (dependency.namespace.typ != b.type_namespace or dependency.namespace.obj == .null) {
            return error.Denied;
        }
        if (!isSafeDependencyValue(dependency.expected.value, dependency.expected)) return error.Denied;
        if (dependency.expected.cell_id == 0 or dependency.expected.revision == 0) return error.Denied;
        for (dependencies[0..index]) |previous| {
            try ctx.chargeWork(1, 1, .code);
            if (sameValue(previous.namespace, dependency.namespace) and
                previous.binding == dependency.binding)
            {
                return error.InvalidCode;
            }
        }
        const current = runtime.readDependency(dependency.namespace, dependency.binding) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Exhausted => return error.Exhausted,
            else => return error.Denied,
        };
        if (!sameDependency(current, dependency.expected)) return error.Denied;
    }
    return allocator.dupe(Dependency, dependencies);
}

fn isSafeDependencyValue(value: Value, expected: Runtime.Dependency) bool {
    if (isImmediateScalar(value)) {
        return expected.method_id == 0 and expected.method_revision == 0;
    }
    if (value.typ != b.type_method or value.obj == .null) return false;
    if (expected.method_id == 0 or expected.method_revision == 0) return false;
    const method = value.obj.toRef().deref(skript.data.Method);
    return method.id == expected.method_id and method.revision == expected.method_revision;
}

fn sameDependency(actual: Runtime.Dependency, expected: Runtime.Dependency) bool {
    return actual.cell_id == expected.cell_id and
        actual.revision == expected.revision and
        actual.method_id == expected.method_id and
        actual.method_revision == expected.method_revision and
        sameValue(actual.value, expected.value);
}

fn findDependencyBinding(
    ctx: *const EvalContext,
    dependencies: []const Dependency,
    namespace: Value,
    binding: Code.Symbol,
) skript.Error!bool {
    for (dependencies) |dependency| {
        try ctx.chargeWork(1, 1, .code);
        if (sameValue(dependency.namespace, namespace) and
            dependency.binding == binding) return true;
    }
    return false;
}

fn findDependencyValue(
    ctx: *const EvalContext,
    dependencies: []const Dependency,
    namespace: Value,
    value: Value,
) skript.Error!bool {
    for (dependencies) |dependency| {
        try ctx.chargeWork(1, 1, .code);
        if (sameValue(dependency.namespace, namespace) and
            sameValue(dependency.expected.value, value))
        {
            return true;
        }
    }
    return false;
}

fn validateFold(
    ctx: *const EvalContext,
    runtime: *Runtime,
    namespace: Value,
    code: *const Code.Code,
    dependencies: []const Dependency,
    fold: Fold,
) skript.Error!void {
    const index = @backingInt(fold.node);
    if (index >= code.nodes.len) return error.InvalidCode;
    const node = code.nodes[index];
    if (node.id != fold.node) return error.InvalidCode;
    if (node.resultCount() != 1 or node.result == .invalid) return error.InvalidCode;
    switch (node.operation) {
        .arithmetic => |arithmetic| {
            if (arithmetic.tail) return error.InvalidCode;
            if (arithmetic.callee != .invalid) {
                if (arithmetic.expected_callee.isNil()) return error.InvalidCode;
                if (arithmetic.expected_callee.typ != b.type_method) return error.Denied;
                if (!try findDependencyValue(
                    ctx,
                    dependencies,
                    namespace,
                    arithmetic.expected_callee,
                )) return error.Denied;
            }
            if (arithmetic.op == .equal or arithmetic.op == .less or arithmetic.op == .greater) {
                if (fold.value.typ != b.type_bool) return error.Denied;
            } else if (!isNumericScalar(fold.value)) {
                return error.Denied;
            }
            if (!isImmediateScalar(fold.value)) return error.Denied;
        },
        .primitive_call => |call| {
            if (call.result_count != 1) return error.InvalidCode;
            const spec = runtime.intrinsics.registryVersion().spec(call.primitive) orelse {
                return error.Denied;
            };
            if (spec.id != call.primitive or !isPurePrimitive(spec)) return error.Denied;
            const function = switch (spec.invoke) {
                .native => |native| native,
                .closure => return error.Denied,
            };
            const operation = canonicalPrimitiveOperation(function, b.type_i64) orelse
                canonicalPrimitiveOperation(function, b.type_f64) orelse return error.Denied;
            const primitive_id = runtime.intrinsics.registryVersion().idForNative(function) orelse {
                return error.Denied;
            };
            if (primitive_id != call.primitive) return error.Denied;
            if (operation == .equal or operation == .less or operation == .greater) {
                if (fold.value.typ != b.type_bool) return error.Denied;
            } else if (!isNumericScalar(fold.value)) {
                return error.Denied;
            }
            if (!isImmediateScalar(fold.value)) return error.Denied;
        },
        else => return error.InvalidCode,
    }
}

fn validateFoldDependencies(
    ctx: *const EvalContext,
    namespace: Value,
    code: *const Code.Code,
    function: Code.FunctionId,
    dependencies: []const Dependency,
) skript.Error!void {
    for (code.nodes) |node| {
        if (node.function != function) continue;
        switch (node.operation) {
            .global_read => |global_id| {
                const index = @backingInt(global_id);
                if (index >= code.globals.len) return error.InvalidCode;
                if (!try findDependencyBinding(
                    ctx,
                    dependencies,
                    namespace,
                    code.globals[index].name,
                )) {
                    return error.Denied;
                }
            },
            .arithmetic => |arithmetic| {
                if (arithmetic.callee != .invalid and
                    !try findDependencyValue(
                        ctx,
                        dependencies,
                        namespace,
                        arithmetic.expected_callee,
                    ))
                {
                    return error.Denied;
                }
            },
            else => {},
        }
    }
}

fn buildCode(
    runtime: *Runtime,
    ctx: *EvalContext,
    source: *const Code.Code,
    folds: []const Fold,
) skript.Error!*const Code.Code {
    var nodes: []const Code.Node = source.nodes;
    if (folds.len > 0) {
        const copied_nodes = try runtime.static.dupe(Code.Node, source.nodes);
        for (folds) |fold| {
            const index = @backingInt(fold.node);
            if (index >= copied_nodes.len) return error.InvalidCode;
            copied_nodes[index].operation = .{ .literal = fold.value };
        }
        nodes = copied_nodes;
    }
    const identity = try runtime.allocCodeIdentity();
    const code = try runtime.static.create(Code.Code);
    code.* = .{
        .id = identity.id,
        .revision = identity.revision,
        .functions = source.functions,
        .blocks = source.blocks,
        .function_blocks = source.function_blocks,
        .nodes = nodes,
        .block_nodes = source.block_nodes,
        .values = source.values,
        .block_parameters = source.block_parameters,
        .operands = source.operands,
        .bindings = source.bindings,
        .function_bindings = source.function_bindings,
        .captures = source.captures,
        .capture_values = source.capture_values,
        .parameters = source.parameters,
        .globals = source.globals,
        .handlers = source.handlers,
        .owner = runtime,
    };
    try code.validate(ctx.scratch, ctx);
    return code;
}

fn sourceIdentityValid(self: *const Residual) bool {
    const source_code = self.source_closure.code orelse return false;
    if (source_code != self.source_code) return false;
    if (source_code == self.code) return false;
    if (source_code.owner != @as(?*const anyopaque, self.runtime)) return false;
    if (self.code.owner != @as(?*const anyopaque, self.runtime)) return false;
    if (source_code.id != self.source_code_id or source_code.revision != self.source_code_revision) return false;
    if (self.code.id != self.residual_code_id or self.code.revision != self.residual_code_revision) return false;
    if (self.source_closure.function_id != self.source_function) return false;
    const index = @backingInt(self.source_function);
    if (index >= source_code.functions.len or index >= self.lowered_functions.len) return false;
    const function = source_code.function(self.source_function) orelse return false;
    if (self.source_closure.arglist.len != function.parameter_count) return false;
    if (self.source_closure.captures.len != function.capture_count) return false;
    if (self.source_closure.result_count != function.result_count) return false;
    const lowered = self.lowered_functions[index];
    const lowered_code = lowered.code orelse return false;
    if (lowered.function != self.source_function or lowered_code != self.code) return false;
    return lowered.result_count == function.result_count and lowered.result_count == 1;
}

fn makeClosure(self: *const Residual) skript.Error!Value {
    const source_closure = self.source_closure;
    const index = @backingInt(source_closure.function_id);
    if (index >= self.lowered_functions.len) return error.InvalidCode;
    const function = self.lowered_functions[index];
    const function_code = function.code orelse return error.InvalidCode;
    if (function_code != self.code or function.function != source_closure.function_id) return error.InvalidCode;
    if (function.result_count != 1) return error.Unsupported;
    if (function.capture_syms.len != source_closure.captures.len) return error.InvalidCode;
    if (function.arglist.len != source_closure.arglist.len) return error.InvalidCode;

    const ref = try self.runtime.store.create(Closure);
    const captures = self.expected_captures;
    self.runtime.store.store(Closure, ref.deref(Closure), .{
        .parent_ns = source_closure.parent_ns,
        .arglist = function.arglist,
        .source = function.source,
        .source_ref = function.source_ref,
        .ir = function.ir,
        .constants = function.constants,
        .nregs = function.nregs,
        .result_count = function.result_count,
        .zero_mask = function.zero_mask,
        .capture_syms = function.capture_syms,
        .captures = captures,
        .guard = &self.validation,
        .code = function_code,
        .function_id = function.function,
        .environment_id = 0,
        .fns = self.lowered_functions,
    });
    return Value.closure(ref.toObject());
}

const ResidualTestContext = struct {
    const Budget = EvalContext.Budget;

    budget: Budget,
    lease: Budget.Lease,
    account: Budget.AccountAllocator,
    output: [256]u8,
    writer: std.Io.Writer,
    context: EvalContext,

    fn init(self: *ResidualTestContext, runtime: *Runtime, options: EvalContext.LimitedOptions) !void {
        const limits: Budget.Limits = .{
            .work = 4_000_000,
            .bytes = 16 * 1024 * 1024,
            .objects = 100_000,
            .nodes = 100_000,
            .output = 256,
            .paths = 100_000,
        };
        try self.initWithLimits(runtime, limits, options);
    }

    fn initWithLimits(
        self: *ResidualTestContext,
        runtime: *Runtime,
        limits: Budget.Limits,
        options: EvalContext.LimitedOptions,
    ) !void {
        self.budget = Budget.init(runtime.io, 91, limits);
        self.lease = try Budget.Lease.root(&self.budget, limits.work);
        self.account = Budget.AccountAllocator.init(std.testing.allocator, &self.lease, .code);
        self.writer = .fixed(&self.output);
        self.context = try EvalContext.limited(
            runtime,
            runtime.intrinsics.registryVersion(),
            &self.account,
            .{ .writer = &self.writer, .bounded_memory = true },
            options,
        );
    }
};

fn arithmeticNode(source: Value, operation: Code.ArithOp) !Code.BoundNodeId {
    if (source.typ != b.type_closure) return error.TestUnexpectedResult;
    const closure = source.obj.toRef().deref(Closure);
    const code = closure.code orelse return error.TestUnexpectedResult;
    for (code.nodes) |node| {
        switch (node.operation) {
            .arithmetic => |arithmetic| if (arithmetic.op == operation) return node.id,
            else => {},
        }
    }
    return error.TestUnexpectedResult;
}

fn testDependency(runtime: *Runtime, namespace: Value, name: []const u8) !Dependency {
    const binding = try runtime.store.getsym(name);
    return .{
        .namespace = namespace,
        .binding = binding,
        .expected = try runtime.readDependency(namespace, binding),
    };
}

fn foldedArithmeticCount(
    source: *const Code.Code,
    residual: *const Code.Code,
    function: Code.FunctionId,
) !usize {
    if (source.nodes.len != residual.nodes.len) return error.TestUnexpectedResult;
    var count: usize = 0;
    for (source.nodes, residual.nodes) |source_node, residual_node| {
        if (source_node.function != function) continue;
        switch (source_node.operation) {
            .arithmetic => switch (residual_node.operation) {
                .literal => count += 1,
                else => {},
            },
            else => {},
        }
    }
    return count;
}

test "specialization merge meters large fold comparisons on the supplied lineage" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();

    const destination_count = 64;
    const source_count = 64;
    const total_count = destination_count + source_count;
    var storage: [total_count]Fold = undefined;
    var destination = std.ArrayList(Fold).initBuffer(&storage);
    for (0..destination_count) |index| {
        destination.appendAssumeCapacity(.{
            .node = @fromBackingInt(@intCast(@as(u32, @intCast(index)))),
            .value = Value.i64(@intCast(index)),
        });
    }
    var source: [source_count]Fold = undefined;
    for (0..source_count) |index| {
        source[index] = .{
            .node = @fromBackingInt(@intCast(@as(u32, @intCast(destination_count + index)))),
            .value = Value.i64(@intCast(destination_count + index)),
        };
    }

    const work_limit: u64 = 8;
    var environment: ResidualTestContext = undefined;
    try environment.initWithLimits(runtime, .{ .work = work_limit }, .{});
    try std.testing.expectError(
        error.Exhausted,
        appendFolds(
            &environment.context,
            std.testing.allocator,
            &destination,
            source[0..],
        ),
    );
    try std.testing.expectEqual(destination_count, destination.items.len);
    const report = environment.budget.report() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(EvalContext.Budget.Resource.work, report.resource);
    try std.testing.expectEqual(EvalContext.Budget.Backend.code, report.backend);
    try std.testing.expectEqual(@as(u64, 91), report.lineage_id);
    try std.testing.expectEqual(work_limit, report.consumed.work);
}

test "specialization merge meters large dependency comparisons on the supplied lineage" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();

    const destination_count = 64;
    const source_count = 64;
    const total_count = destination_count + source_count;
    var bindings: [total_count][]const u8 = @splat("merge-dependency");
    var storage: [total_count]Dependency = undefined;
    var destination = std.ArrayList(Dependency).initBuffer(&storage);
    for (0..destination_count) |index| {
        destination.appendAssumeCapacity(.{
            .namespace = runtime.root_ns,
            .binding = &bindings[index],
            .expected = .{
                .cell_id = @as(u64, @intCast(index)) + 1,
                .revision = 1,
                .value = Value.i64(@intCast(index)),
            },
        });
    }
    var source: [source_count]Dependency = undefined;
    for (0..source_count) |index| {
        source[index] = .{
            .namespace = runtime.root_ns,
            .binding = &bindings[destination_count + index],
            .expected = .{
                .cell_id = @as(u64, @intCast(destination_count + index)) + 1,
                .revision = 1,
                .value = Value.i64(@intCast(destination_count + index)),
            },
        };
    }

    const work_limit: u64 = 8;
    var environment: ResidualTestContext = undefined;
    try environment.initWithLimits(runtime, .{ .work = work_limit }, .{});
    try std.testing.expectError(
        error.Exhausted,
        appendDependencies(
            &environment.context,
            std.testing.allocator,
            &destination,
            source[0..],
        ),
    );
    try std.testing.expectEqual(destination_count, destination.items.len);
    const report = environment.budget.report() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(EvalContext.Budget.Resource.work, report.resource);
    try std.testing.expectEqual(EvalContext.Budget.Backend.code, report.backend);
    try std.testing.expectEqual(@as(u64, 91), report.lineage_id);
    try std.testing.expectEqual(work_limit, report.consumed.work);
}

test "specialization merge preserves duplicate rules and first occurrence order" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();

    var environment: ResidualTestContext = undefined;
    try environment.init(runtime, .{});

    const first_fold: Fold = .{ .node = @fromBackingInt(@intCast(2)), .value = Value.i64(20) };
    const second_fold: Fold = .{ .node = @fromBackingInt(@intCast(1)), .value = Value.i64(10) };
    var fold_storage: [4]Fold = undefined;
    var folds = std.ArrayList(Fold).initBuffer(&fold_storage);
    try appendFolds(
        &environment.context,
        std.testing.allocator,
        &folds,
        &.{ first_fold, second_fold, first_fold },
    );
    try std.testing.expectEqual(@as(usize, 2), folds.items.len);
    try std.testing.expectEqual(first_fold.node, folds.items[0].node);
    try std.testing.expectEqual(first_fold.value, folds.items[0].value);
    try std.testing.expectEqual(second_fold.node, folds.items[1].node);
    try std.testing.expectError(
        error.InvalidCode,
        appendFolds(
            &environment.context,
            std.testing.allocator,
            &folds,
            &.{.{ .node = first_fold.node, .value = Value.i64(99) }},
        ),
    );

    const first_dependency = try testDependency(runtime, runtime.root_ns, "+");
    const second_dependency = try testDependency(runtime, runtime.root_ns, "*");
    var dependency_storage: [4]Dependency = undefined;
    var dependencies = std.ArrayList(Dependency).initBuffer(&dependency_storage);
    try appendDependencies(
        &environment.context,
        std.testing.allocator,
        &dependencies,
        &.{ first_dependency, second_dependency, first_dependency },
    );
    try std.testing.expectEqual(@as(usize, 2), dependencies.items.len);
    try std.testing.expectEqual(first_dependency.binding, dependencies.items[0].binding);
    try std.testing.expectEqual(second_dependency.binding, dependencies.items[1].binding);
    var conflicting_dependency = first_dependency;
    conflicting_dependency.expected.revision += 1;
    try std.testing.expectError(
        error.InvalidCode,
        appendDependencies(
            &environment.context,
            std.testing.allocator,
            &dependencies,
            &.{conflicting_dependency},
        ),
    );
}

test "specialization folds known scalar arithmetic into guarded Code" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const source = try runtime.evalString("(fn (x) (+ (* x 2) 1))");
    const source_closure = source.obj.toRef().deref(Closure);
    const source_code = source_closure.code orelse return error.TestUnexpectedResult;

    var environment: ResidualTestContext = undefined;
    try environment.init(runtime, .{});
    const residual = try specialize(&environment.context, source, .{
        .arguments = &.{Value.i64(3)},
    });

    try std.testing.expectEqual(
        @as(usize, 2),
        try foldedArithmeticCount(source_code, residual.code, source_closure.function_id),
    );
    try std.testing.expectEqual(
        Value.i64(7),
        try residual.invoke(&environment.context, &.{Value.i64(3)}),
    );
}

test "specialization rejects a changed fold dependency before effects" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    _ = try runtime.evalString("(def residual-specialized-global 2)");
    const source = try runtime.evalString(
        "(fn () (begin (+ residual-specialized-global 1) (@write \"executed\") 7))",
    );
    const source_closure = source.obj.toRef().deref(Closure);
    const source_code = source_closure.code orelse return error.TestUnexpectedResult;

    var environment: ResidualTestContext = undefined;
    try environment.init(runtime, .{ .effects = .{ .state_read = .allow, .io = .allow } });
    const residual = try specialize(&environment.context, source, .{ .arguments = &.{} });
    try std.testing.expectEqual(
        @as(usize, 1),
        try foldedArithmeticCount(source_code, residual.code, source_closure.function_id),
    );

    _ = try runtime.evalString("(def residual-specialized-global 9)");
    try std.testing.expectError(error.Denied, residual.invoke(&environment.context, &.{}));
    try std.testing.expectEqual(@as(usize, 0), environment.writer.buffered().len);
}

test "residual invokes specialized bound code through RegVM" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const source = try runtime.evalString("(fn (x) (+ (* x 2) 1))");
    const multiply = try testDependency(runtime, runtime.root_ns, "*");
    const add = try testDependency(runtime, runtime.root_ns, "+");

    var environment: ResidualTestContext = undefined;
    try environment.init(runtime, .{});
    const residual = try create(&environment.context, source, .{
        .arguments = &.{Value.i64(3)},
        .folds = &.{.{ .node = try arithmeticNode(source, .mul), .value = Value.i64(6) }},
        .dependencies = &.{ multiply, add },
    });

    try std.testing.expectEqual(Value.i64(7), try residual.invoke(&environment.context, &.{Value.i64(3)}));
}

test "residual rejects changed arguments before output" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const source = try runtime.evalString("(fn (x) (begin (@write \"executed\") (+ x 1)))");
    const add = try testDependency(runtime, runtime.root_ns, "+");

    var environment: ResidualTestContext = undefined;
    try environment.init(runtime, .{ .effects = .{ .io = .allow } });
    const residual = try create(&environment.context, source, .{
        .arguments = &.{Value.i64(3)},
        .folds = &.{.{ .node = try arithmeticNode(source, .add), .value = Value.i64(4) }},
        .dependencies = &.{add},
    });

    try std.testing.expectError(error.Denied, residual.invoke(&environment.context, &.{Value.i64(4)}));
    try std.testing.expectEqual(@as(usize, 0), environment.writer.buffered().len);
}

test "residual rejects changed global dependency before output" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    _ = try runtime.evalString("(def residual-global 2)");
    const source = try runtime.evalString("(fn () (begin (@write \"executed\") (+ residual-global 1)))");
    const global = try testDependency(runtime, runtime.root_ns, "residual-global");
    const add = try testDependency(runtime, runtime.root_ns, "+");

    var environment: ResidualTestContext = undefined;
    try environment.init(runtime, .{ .effects = .{ .state_read = .allow, .io = .allow } });
    const residual = try create(&environment.context, source, .{
        .arguments = &.{},
        .folds = &.{.{ .node = try arithmeticNode(source, .add), .value = Value.i64(3) }},
        .dependencies = &.{ global, add },
    });

    _ = try runtime.evalString("(def residual-global 9)");
    try std.testing.expectError(error.Denied, residual.invoke(&environment.context, &.{}));
    try std.testing.expectEqual(@as(usize, 0), environment.writer.buffered().len);
}

test "residual rejects changed method dependency before output" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    _ = try runtime.evalString("(def residual-method (method)) (instance residual-method i64 (fn (x) #t))");
    const source = try runtime.evalString(
        "(fn (x) (begin (@write \"executed\") (if (residual-method x) (+ x 1) (+ x 2))))",
    );
    const method = try testDependency(runtime, runtime.root_ns, "residual-method");
    const add = try testDependency(runtime, runtime.root_ns, "+");

    var environment: ResidualTestContext = undefined;
    try environment.init(runtime, .{ .effects = .{ .state_read = .allow, .io = .allow } });
    const residual = try create(&environment.context, source, .{
        .arguments = &.{Value.i64(3)},
        .folds = &.{.{ .node = try arithmeticNode(source, .add), .value = Value.i64(4) }},
        .dependencies = &.{ method, add },
    });

    _ = try runtime.evalString("(instance residual-method i64 (fn (x) #f))");
    try std.testing.expectError(error.Denied, residual.invoke(&environment.context, &.{Value.i64(3)}));
    try std.testing.expectEqual(@as(usize, 0), environment.writer.buffered().len);
}

test "residual rejects mutable fold values" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const source = try runtime.evalString("(fn (x) (+ x 1))");
    const add = try testDependency(runtime, runtime.root_ns, "+");
    const mutable = try runtime.evalString("(hash-map :value 4)");

    var environment: ResidualTestContext = undefined;
    try environment.init(runtime, .{});
    try std.testing.expectError(error.Denied, create(&environment.context, source, .{
        .arguments = &.{Value.i64(3)},
        .folds = &.{.{ .node = try arithmeticNode(source, .add), .value = mutable }},
        .dependencies = &.{add},
    }));
}

test "modeled residual never invokes concrete RegVM" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const source = try runtime.evalString("(fn () (begin (@write \"executed\") 7))");
    const model: EvalContext.Version = .{ .id = 73, .revision = 5 };

    var environment: ResidualTestContext = undefined;
    try environment.init(runtime, .{
        .mode = .residual,
        .effects = .{ .io = .{ .model = model } },
        .model = model,
    });
    const residual = try create(&environment.context, source, .{ .arguments = &.{}, .model = model });
    environment.context.mode = .concrete;
    environment.context.effects.io = .allow;

    try std.testing.expectError(error.Denied, residual.invoke(&environment.context, &.{}));
    try std.testing.expectEqual(@as(usize, 0), environment.writer.buffered().len);
}

test "residual rejects an explicit intrinsic dependency" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const source = try runtime.evalString("(fn () 7)");
    const dependency = try testDependency(runtime, runtime.root_ns, "apply");
    var environment: ResidualTestContext = undefined;
    try environment.init(runtime, .{});
    try std.testing.expectError(error.Denied, create(&environment.context, source, .{
        .arguments = &.{},
        .dependencies = &.{dependency},
    }));
}

test "residual preserves applied target and guarded expanded arguments" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const source = try runtime.evalString("(fn (x) (apply @i64.add x '(2)))");
    var environment: ResidualTestContext = undefined;
    try environment.init(runtime, .{});
    const residual = try specialize(&environment.context, source, .{ .arguments = &.{Value.i64(3)} });
    try std.testing.expectEqual(Value.i64(5), try residual.invoke(&environment.context, &.{Value.i64(3)}));
    try std.testing.expectError(error.Denied, residual.invoke(&environment.context, &.{Value.i64(4)}));
}

test "residual callable guards script tail calls and native callbacks" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const source = try runtime.evalString("(fn (x) (+ x 1))");
    var environment: ResidualTestContext = undefined;
    try environment.init(runtime, .{});
    const residual = try create(&environment.context, source, .{ .arguments = &.{Value.i64(3)} });
    try runtime.nsBind(
        runtime.root_ns,
        try runtime.store.getsym("held-residual"),
        try residual.callable(&environment.context),
    );
    try std.testing.expectEqual(Value.i64(4), try runtime.evalString("(held-residual 3)"));
    try std.testing.expectError(error.Denied, runtime.evalString("(held-residual 4)"));
    try std.testing.expectError(
        error.Denied,
        runtime.evalString("(fold (list 3 4) 0 (fn (sum x) (+ sum (held-residual x))))"),
    );
}

test "residual callable retains a scalar closure capture across collection" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const source = try runtime.evalString(
        "((fn (saved) (fn (x) (+ x saved))) 40)",
    );
    var environment: ResidualTestContext = undefined;
    try environment.init(runtime, .{});
    const residual = try create(&environment.context, source, .{ .arguments = &.{Value.i64(2)} });
    var root: Runtime.ValueRoot = .{};
    try runtime.registerValueRoot(&root, try residual.callable(&environment.context));
    defer runtime.unregisterValueRoot(&root) catch unreachable;

    try runtime.collect();
    try std.testing.expectEqual(Value.i64(42), try residual.invoke(&environment.context, &.{Value.i64(2)}));
}
