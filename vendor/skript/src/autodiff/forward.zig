//! Bound-Code forward automatic differentiation.
const std = @import("std");
const Allocator = std.mem.Allocator;
const skript = @import("../root.zig");
const Code = @import("../code.zig");
const SourceUnit = @import("../SourceUnit.zig");
const Primitive = @import("../primitive.zig");
const Effects = @import("../ad_effects.zig");
const rules = @import("rules.zig");
const clone = @import("clone.zig");
const callable_mod = @import("callable.zig");
const tensor = @import("tensor.zig");
const Error = skript.Error;
const EvalContext = skript.EvalContext;
const Runtime = skript.Runtime;
const Value = skript.Value;
const Closure = skript.data.Closure;
const ClosureGuard = skript.data.ClosureGuard;
const Sym = skript.Sym;
const b = skript.builtins;
pub const Mode = enum { derivative, jvp, full_jvp };
const max_generation_depth: u16 = 32;

const Pair = struct {
    primal: Code.ValueId = .invalid,
    tangent: Code.ValueId = .invalid,
    active: bool = false,
};

const FunctionPair = struct {
    jvp: Code.FunctionId = .invalid,
    plain: Code.FunctionId = .invalid,
};
const GenerationKey = struct {
    closure: *const Closure,
    mode: Mode,
    parameter: u16,
};

const GenerationEntry = struct {
    value: Value,
    allows_ad: ?bool = null,
};

const GenerationSession = struct {
    allocator: Allocator,
    entries: std.AutoHashMapUnmanaged(GenerationKey, GenerationEntry) = .empty,

    fn init(allocator: Allocator) GenerationSession {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *GenerationSession) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    fn get(self: *const GenerationSession, key: GenerationKey) ?Value {
        const entry = self.entries.get(key) orelse return null;
        return entry.value;
    }

    fn allowsAd(self: *const GenerationSession, key: GenerationKey) ?bool {
        const entry = self.entries.get(key) orelse return null;
        return entry.allows_ad;
    }

    fn finish(self: *GenerationSession, key: GenerationKey, allows_ad: bool) Error!void {
        const entry = self.entries.getPtr(key) orelse return error.InvalidCode;
        entry.allows_ad = allows_ad;
    }

    fn reserve(self: *GenerationSession, runtime: *Runtime, key: GenerationKey) Error!Value {
        if (self.entries.get(key)) |existing| return existing.value;
        const reference = try runtime.store.create(Closure);
        const value = Value.closure(reference.toObject());
        try self.entries.put(self.allocator, key, .{ .value = value });
        return value;
    }
};

const CallableInfo = struct {
    function: Code.FunctionId,
};
const DependencyGuard = struct {
    runtime: *Runtime,
    registry: *const Primitive.RegistryVersion,
    rules_version: *const rules.RegistryVersion,
    code: *const Code.Code,
    source_code: *const Code.Code,
    source: *const Closure,
    expected_captures: []const Value,
    reads: []const Effects.Read,
    inherited: ?*const ClosureGuard,
    inherited_argument_count: usize,
    argument_count: usize,
};

fn traceRead(read: Effects.Read, visitor: *skript.Store.MarkVisitor) anyerror!void {
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

fn traceGuard(context: *const anyopaque, visitor: *skript.Store.MarkVisitor) anyerror!void {
    const guard: *const DependencyGuard = @ptrCast(@alignCast(context));
    try visitor.visitValue(guard.source.parent_ns);
    for (guard.expected_captures) |value| try visitor.visitValue(value);
    try callable_mod.traceClosureRef(guard.source, visitor);
    try callable_mod.traceCodeGraph(guard.code, visitor);
    try callable_mod.traceCodeGraph(guard.source_code, visitor);
    for (guard.reads) |read| try traceRead(read, visitor);
    if (guard.inherited) |inherited| {
        const trace = inherited.trace orelse return error.UntracedAllocation;
        try visitor.visitGuard(trace, inherited.context);
    }
}

fn validateGuardLifecycle(guard: *const ClosureGuard) Error!void {
    const has_acquire = guard.acquire != null;
    const has_release = guard.release != null;
    if (has_acquire != has_release) return error.InvalidCode;
}

fn checkInheritedGuardArguments(
    runtime: *Runtime,
    guard: *const ClosureGuard,
    arguments: []const Value,
) Error!void {
    try validateGuardLifecycle(guard);
    const check = guard.check_arguments orelse return;
    var acquired = false;
    if (guard.acquire) |acquire| {
        try acquire(runtime, guard.context);
        acquired = true;
    }
    defer {
        if (acquired) {
            if (guard.release) |release| release(runtime, guard.context);
        }
    }
    try check(runtime, guard.context, arguments);
}

fn acquireGuard(runtime: *Runtime, state: *const anyopaque) Error!void {
    const guard: *const DependencyGuard = @ptrCast(@alignCast(state));
    if (guard.inherited) |parent| {
        try validateGuardLifecycle(parent);
        if (parent.acquire) |acquire| try acquire(runtime, parent.context);
    }
}

fn releaseGuard(runtime: *Runtime, state: *const anyopaque) void {
    const guard: *const DependencyGuard = @ptrCast(@alignCast(state));
    if (guard.inherited) |parent| {
        if (parent.acquire == null or parent.release == null) return;
        if (parent.release) |release| release(runtime, parent.context);
    }
}

fn checkGuard(runtime: *Runtime, state: *const anyopaque) Error!void {
    const guard: *const DependencyGuard = @ptrCast(@alignCast(state));
    if (runtime != guard.runtime) return error.Denied;
    const context = runtime.context();
    try context.check();
    if (context.registry != guard.registry) return error.Denied;
    if (runtime.intrinsics.registryVersion() != guard.registry) return error.Denied;
    if (!guard.rules_version.validFor(guard.registry)) return error.Denied;
    const owner = if (runtime.ad_rules) |*registry_owner| registry_owner else return error.Unsupported;
    if (!owner.ownsCurrent(guard.rules_version)) return error.Unsupported;
    var inherited_acquired = false;
    if (guard.inherited) |parent| {
        try validateGuardLifecycle(parent);
        if (parent.acquire) |acquire| {
            try acquire(runtime, parent.context);
            inherited_acquired = true;
        }
    }
    defer if (inherited_acquired) {
        if (guard.inherited) |parent| {
            if (parent.release) |release| release(runtime, parent.context);
        }
    };
    if (guard.inherited) |parent| try parent.check(runtime, parent.context);
    if (guard.source.code != guard.source_code) return error.Denied;
    if (guard.source.function_id == .invalid) return error.Denied;
    if (guard.source.captures.len != guard.expected_captures.len) return error.Denied;
    try context.chargeWork(@intCast(guard.reads.len + guard.expected_captures.len), 1, .code);
    for (guard.source.captures, guard.expected_captures) |actual, expected| {
        if (actual.typ != expected.typ or actual.obj != expected.obj) return error.Denied;
    }
    for (guard.reads) |read| {
        if (!read.valid(runtime)) return error.Unsupported;
    }
}

fn checkGuardArguments(runtime: *Runtime, state: *const anyopaque, args: []const Value) Error!void {
    const guard: *const DependencyGuard = @ptrCast(@alignCast(state));
    if (args.len != guard.argument_count) return error.ArityMismatch;
    if (guard.inherited) |parent| {
        if (args.len < guard.inherited_argument_count) return error.ArityMismatch;
        try checkInheritedGuardArguments(runtime, parent, args[0..guard.inherited_argument_count]);
    }
}

fn sourceFunction(code: *const Code.Code, id: Code.FunctionId) Error!*const Code.Function {
    const function = code.function(id) orelse return error.InvalidCode;
    if (function.has_rest or !function.allows_ad) return error.Unsupported;
    return function;
}

const Transform = struct {
    ctx: *EvalContext,
    runtime: *Runtime,
    source: *const Code.Code,
    source_closure: *const Closure,
    rule_version: *const rules.RegistryVersion,
    builder: Code.Builder,
    scratch: Allocator,
    differentiated: []bool,
    functions: []FunctionPair,
    blocks: []Code.BlockId,
    globals: []Code.GlobalCellId,
    tangent_globals: []Code.GlobalCellId,
    handlers: []Code.HandlerId,
    bindings: []Code.BindingId,
    tangent_bindings: []Code.BindingId,
    values: []Pair,
    join_inputs: []bool,
    binding_values: []Pair,
    captures: []Pair,
    callable_infos: std.AutoHashMapUnmanaged(u32, CallableInfo) = .empty,
    scalar_primitive: Primitive.PrimitiveId,
    source_function: Code.FunctionId,
    generation_depth: u16,

    session: *GenerationSession,
    extra_reads: std.ArrayList(Effects.Read) = .empty,
    higher_order: bool = true,
    fn noteGeneratedHigherOrder(self: *Transform, callable: Value) void {
        if (callable.typ != b.type_closure or callable.obj == .null) return;
        const closure = callable.obj.toRef().deref(Closure);
        const key: GenerationKey = .{
            .closure = closure,
            .mode = .full_jvp,
            .parameter = 0,
        };
        if (self.session.allowsAd(key)) |allows_ad| {
            self.higher_order = self.higher_order and allows_ad;
        }
    }
    fn isClosureJoin(self: *Transform, value: Code.ValueId, depth: usize) Error!bool {
        if (depth >= 64) return error.Unsupported;
        try self.ctx.chargeWork(1, 1, .transform);
        if (try self.staticCallable(value)) |known| {
            return known.typ == b.type_closure and (depth != 0 or self.join_inputs[@intFromEnum(value)]);
        }
        if (try knownFunctionInCode(self.ctx, self.source, self.source_closure, value) != null) return true;
        const inputs = (try callable_mod.incoming(self.ctx, self.source, value)) orelse return false;
        defer self.ctx.scratch.free(inputs);
        for (inputs) |input| {
            if (!try self.isClosureJoin(input, depth + 1)) return false;
        }
        return true;
    }

    fn joinedCallableTangent(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        node: Code.Node,
    ) Error!?Code.ValueId {
        if (!self.join_inputs[@intFromEnum(node.result)]) return null;
        const known = (try self.staticCallable(node.result)) orelse return null;
        if (known.typ != b.type_closure) return null;
        if (self.generation_depth >= max_generation_depth) return error.Unsupported;
        const generated = try generateAtDepth(
            self.ctx,
            known,
            0,
            .full_jvp,
            self.generation_depth + 1,
            self.session,
        );
        self.noteGeneratedHigherOrder(known);
        const generated_value = try self.addLiteral(function, block, generated, node.source);
        return generated_value;
    }

    fn init(
        scratch: Allocator,
        ctx: *EvalContext,
        source: *const Code.Code,
        source_closure: *const Closure,
        rule_version: *const rules.RegistryVersion,
        builder: Code.Builder,
        source_function: Code.FunctionId,
        scalar_primitive: Primitive.PrimitiveId,
        generation_depth: u16,
        session: *GenerationSession,
    ) Error!Transform {
        const functions = try scratch.alloc(FunctionPair, source.functions.len);
        @memset(functions, .{});
        const blocks = try scratch.alloc(Code.BlockId, source.blocks.len);
        @memset(blocks, .invalid);
        const globals = try scratch.alloc(Code.GlobalCellId, source.globals.len);
        @memset(globals, .invalid);
        const tangent_globals = try scratch.alloc(Code.GlobalCellId, source.globals.len);
        @memset(tangent_globals, .invalid);
        const handlers = try scratch.alloc(Code.HandlerId, source.handlers.len);
        @memset(handlers, .invalid);
        const bindings = try scratch.alloc(Code.BindingId, source.bindings.len);
        @memset(bindings, .invalid);
        const tangent_bindings = try scratch.alloc(Code.BindingId, source.bindings.len);
        @memset(tangent_bindings, .invalid);
        const values = try scratch.alloc(Pair, source.values.len);
        @memset(values, .{});
        const binding_values = try scratch.alloc(Pair, source.bindings.len);
        @memset(binding_values, .{});
        const captures = try scratch.alloc(Pair, source.captures.len);
        @memset(captures, .{});
        return .{
            .differentiated = try reachableFunctions(scratch, ctx, source, source_closure, source_function),
            .ctx = ctx,
            .runtime = ctx.runtime,
            .source = source,
            .source_closure = source_closure,
            .rule_version = rule_version,
            .builder = builder,
            .scratch = scratch,
            .functions = functions,
            .blocks = blocks,
            .globals = globals,
            .tangent_globals = tangent_globals,
            .handlers = handlers,
            .bindings = bindings,
            .tangent_bindings = tangent_bindings,
            .values = values,
            .join_inputs = try callable_mod.joinAncestors(scratch, ctx, source),
            .binding_values = binding_values,
            .captures = captures,
            .scalar_primitive = scalar_primitive,
            .source_function = source_function,
            .generation_depth = generation_depth,
            .session = session,
        };
    }

    fn deinit(self: *Transform) void {
        self.callable_infos.deinit(self.scratch);
        self.extra_reads.deinit(self.scratch);
        self.* = undefined;
    }

    fn addNode(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        operation: Code.Operation,
        source: Code.Node,
    ) Error!Code.ValueId {
        const result = try self.builder.addNode(function, block, operation, source.source);
        if (source.source_index != Code.invalid_index) {
            const node = self.builder.lastNodeId() orelse return error.InvalidCode;
            try self.builder.setNodeSourceIndex(node, source.source_index);
        }
        return result;
    }

    fn addGeneratedNode(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        operation: Code.Operation,
        source: SourceUnit.Ref,
    ) Error!Code.ValueId {
        return self.builder.addNode(function, block, operation, source);
    }

    fn addLiteral(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        value: Value,
        source: SourceUnit.Ref,
    ) Error!Code.ValueId {
        return self.builder.addNode(function, block, .{ .literal = value }, source);
    }

    fn addNil(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        source: SourceUnit.Ref,
    ) Error!Code.ValueId {
        return self.addLiteral(function, block, .nil, source);
    }

    fn sourceOperands(self: *const Transform, range: Code.OperandRange) Error![]const Code.ValueId {
        const begin: usize = range.start;
        const end = std.math.add(usize, begin, range.len) catch return error.InvalidCode;
        if (end > self.source.operands.len) return error.InvalidCode;
        return self.source.operands[begin..end];
    }

    fn mapped(self: *const Transform, value: Code.ValueId) Error!Pair {
        const index = @intFromEnum(value);
        if (index >= self.values.len or self.values[index].primal == .invalid) return error.InvalidCode;
        return self.values[index];
    }

    fn setMapped(self: *Transform, source_value: Code.ValueId, pair: Pair) Error!void {
        const index = @intFromEnum(source_value);
        if (index >= self.values.len or pair.primal == .invalid or pair.tangent == .invalid) {
            return error.InvalidCode;
        }
        self.values[index] = pair;
    }

    fn sourceBinding(self: *const Transform, binding: Code.BindingId) Error!Code.Binding {
        const index = @intFromEnum(binding);
        if (index >= self.source.bindings.len) return error.InvalidCode;
        return self.source.bindings[index];
    }

    fn functionCaptureRange(
        self: *const Transform,
        function: Code.FunctionId,
    ) Error!struct { start: usize, end: usize } {
        const info = try sourceFunction(self.source, function);
        const start: usize = info.capture_start;
        const end = std.math.add(usize, start, info.capture_count) catch return error.InvalidCode;
        if (end > self.source.captures.len) return error.InvalidCode;
        return .{ .start = start, .end = end };
    }

    fn lookupBindingPair(self: *const Transform, function: Code.FunctionId, binding: Code.BindingId) Error!Pair {
        const definition = try self.sourceBinding(binding);
        if (definition.function == function) {
            const index = @intFromEnum(binding);
            if (index >= self.binding_values.len) return error.InvalidCode;
            if (self.binding_values[index].primal != .invalid) return self.binding_values[index];
            if (definition.value != .invalid) return self.mapped(definition.value);
            return error.InvalidCode;
        }
        const range = try self.functionCaptureRange(function);
        for (range.start..range.end) |capture_index| {
            if (self.source.captures[capture_index] == binding) return self.captures[capture_index];
        }
        return error.InvalidCode;
    }

    fn setBindingPair(self: *Transform, binding: Code.BindingId, pair: Pair) Error!void {
        const index = @intFromEnum(binding);
        if (index >= self.binding_values.len) return error.InvalidCode;
        self.binding_values[index] = pair;
        const generated = self.bindings[index];
        const tangent = self.tangent_bindings[index];
        if (generated == .invalid or tangent == .invalid) return error.InvalidCode;
        self.builder.bindings.items[@intFromEnum(generated)].value = pair.primal;
        self.builder.bindings.items[@intFromEnum(tangent)].value = pair.tangent;
    }

    fn mappedBinding(self: *const Transform, binding: Code.BindingId) Error!Code.BindingId {
        const index = @intFromEnum(binding);
        if (index >= self.bindings.len or self.bindings[index] == .invalid) return error.InvalidCode;
        return self.bindings[index];
    }

    fn mappedTangentBinding(self: *const Transform, binding: Code.BindingId) Error!Code.BindingId {
        const index = @intFromEnum(binding);
        if (index >= self.tangent_bindings.len or self.tangent_bindings[index] == .invalid) return error.InvalidCode;
        return self.tangent_bindings[index];
    }

    fn lookupCallable(self: *const Transform, value: Code.ValueId) ?CallableInfo {
        return self.callable_infos.get(@intFromEnum(value));
    }

    fn recordCallable(self: *Transform, value: Code.ValueId, function: Code.FunctionId) Error!void {
        try self.callable_infos.put(self.scratch, @intFromEnum(value), .{ .function = function });
    }

    fn materialize(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        pair: Pair,
        source: SourceUnit.Ref,
    ) Error!Code.ValueId {
        return self.scalarCall(function, block, .realize_tangent, &.{ pair.primal, pair.tangent }, source);
    }

    fn scalarCall(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        operation: rules.ScalarOp,
        args: []const Code.ValueId,
        source: SourceUnit.Ref,
    ) Error!Code.ValueId {
        const tag = try self.addLiteral(function, block, .i64(@intFromEnum(operation)), source);
        var operands = std.ArrayList(Code.ValueId).empty;
        defer operands.deinit(self.scratch);
        try operands.append(self.scratch, tag);
        try operands.appendSlice(self.scratch, args);
        const range = try self.builder.addOperands(operands.items);
        return self.addGeneratedNode(function, block, .{ .primitive_call = .{
            .primitive = self.scalar_primitive,
            .args = range,
            .result_count = 1,
        } }, source);
    }

    fn scalarOne(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        primal: Code.ValueId,
        source: SourceUnit.Ref,
    ) Error!Code.ValueId {
        return self.scalarCall(function, block, .one_like, &.{primal}, source);
    }

    fn scalarZero(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        primal: Code.ValueId,
        source: SourceUnit.Ref,
    ) Error!Code.ValueId {
        return self.scalarCall(function, block, .zero_like, &.{primal}, source);
    }

    fn scalarBinary(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        operation: rules.ScalarOp,
        left: Code.ValueId,
        right: Code.ValueId,
        source: SourceUnit.Ref,
    ) Error!Code.ValueId {
        return self.scalarCall(function, block, operation, &.{ left, right }, source);
    }

    fn scalarUnary(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        operation: rules.ScalarOp,
        value: Code.ValueId,
        source: SourceUnit.Ref,
    ) Error!Code.ValueId {
        return self.scalarCall(function, block, operation, &.{value}, source);
    }

    fn emitPairNil(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        primal: Code.ValueId,
        source: SourceUnit.Ref,
    ) Error!Pair {
        return .{ .primal = primal, .tangent = try self.addNil(function, block, source), .active = false };
    }

    fn addMappedArgs(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        source_args: []const Code.ValueId,
        include_tangents: bool,
        source: SourceUnit.Ref,
    ) Error!Code.OperandRange {
        var values = std.ArrayList(Code.ValueId).empty;
        defer values.deinit(self.scratch);
        for (source_args) |source_arg| {
            const pair = try self.mapped(source_arg);
            try values.append(self.scratch, pair.primal);
            if (include_tangents) try values.append(self.scratch, try self.materialize(function, block, pair, source));
        }
        return self.builder.addOperands(values.items);
    }

    fn addEdgeArgs(
        self: *Transform,
        edge: Code.Edge,
    ) Error!Code.OperandRange {
        const source_args = try self.sourceOperands(edge.args);
        var values = std.ArrayList(Code.ValueId).empty;
        defer values.deinit(self.scratch);
        for (source_args) |source_arg| {
            const pair = try self.mapped(source_arg);
            try values.append(self.scratch, pair.primal);
            try values.append(self.scratch, pair.tangent);
        }
        return self.builder.addOperands(values.items);
    }

    fn emitUnaryRule(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        builtin: rules.BuiltinJvp,
        primal: Code.ValueId,
        tangent: Code.ValueId,
        source: SourceUnit.Ref,
    ) Error!Code.ValueId {
        return switch (builtin) {
            .neg => self.scalarUnary(function, block, .neg, tangent, source),
            .sqrt => blk: {
                const one = try self.scalarOne(function, block, primal, source);
                const two = try self.scalarBinary(function, block, .add, one, one, source);
                const root = try self.scalarUnary(function, block, .sqrt, primal, source);
                const denom = try self.scalarBinary(function, block, .mul, two, root, source);
                break :blk self.scalarBinary(function, block, .div, tangent, denom, source);
            },
            .sin => blk: {
                const cosine = try self.scalarUnary(function, block, .cos, primal, source);
                break :blk self.scalarBinary(function, block, .mul, cosine, tangent, source);
            },
            .cos => blk: {
                const sine = try self.scalarUnary(function, block, .sin, primal, source);
                const product = try self.scalarBinary(function, block, .mul, sine, tangent, source);
                break :blk self.scalarUnary(function, block, .neg, product, source);
            },
            .tan => blk: {
                const tan_value = try self.scalarUnary(function, block, .tan, primal, source);
                const square = try self.scalarBinary(function, block, .mul, tan_value, tan_value, source);
                const one = try self.scalarOne(function, block, primal, source);
                const factor = try self.scalarBinary(function, block, .add, one, square, source);
                break :blk self.scalarBinary(function, block, .mul, factor, tangent, source);
            },
            .asin => blk: {
                const square = try self.scalarBinary(function, block, .mul, primal, primal, source);
                const one = try self.scalarOne(function, block, primal, source);
                const under = try self.scalarBinary(function, block, .sub, one, square, source);
                const root = try self.scalarUnary(function, block, .sqrt, under, source);
                break :blk self.scalarBinary(function, block, .div, tangent, root, source);
            },
            .acos => blk: {
                const quotient = try self.emitUnaryRule(function, block, .asin, primal, tangent, source);
                break :blk self.scalarUnary(function, block, .neg, quotient, source);
            },
            .atan => blk: {
                const square = try self.scalarBinary(function, block, .mul, primal, primal, source);
                const one = try self.scalarOne(function, block, primal, source);
                const denom = try self.scalarBinary(function, block, .add, one, square, source);
                break :blk self.scalarBinary(function, block, .div, tangent, denom, source);
            },
            .sinh => blk: {
                const cosh = try self.scalarUnary(function, block, .cosh, primal, source);
                break :blk self.scalarBinary(function, block, .mul, cosh, tangent, source);
            },
            .cosh => blk: {
                const sinh = try self.scalarUnary(function, block, .sinh, primal, source);
                break :blk self.scalarBinary(function, block, .mul, sinh, tangent, source);
            },
            .tanh => blk: {
                const value = try self.scalarUnary(function, block, .tanh, primal, source);
                const square = try self.scalarBinary(function, block, .mul, value, value, source);
                const one = try self.scalarOne(function, block, primal, source);
                const factor = try self.scalarBinary(function, block, .sub, one, square, source);
                break :blk self.scalarBinary(function, block, .mul, factor, tangent, source);
            },
            .asinh => blk: {
                const square = try self.scalarBinary(function, block, .mul, primal, primal, source);
                const one = try self.scalarOne(function, block, primal, source);
                const under = try self.scalarBinary(function, block, .add, one, square, source);
                const root = try self.scalarUnary(function, block, .sqrt, under, source);
                break :blk self.scalarBinary(function, block, .div, tangent, root, source);
            },
            .acosh => blk: {
                const square = try self.scalarBinary(function, block, .mul, primal, primal, source);
                const one = try self.scalarOne(function, block, primal, source);
                const under = try self.scalarBinary(function, block, .sub, square, one, source);
                const root = try self.scalarUnary(function, block, .sqrt, under, source);
                break :blk self.scalarBinary(function, block, .div, tangent, root, source);
            },
            .atanh => blk: {
                const square = try self.scalarBinary(function, block, .mul, primal, primal, source);
                const one = try self.scalarOne(function, block, primal, source);
                const denom = try self.scalarBinary(function, block, .sub, one, square, source);
                break :blk self.scalarBinary(function, block, .div, tangent, denom, source);
            },
            .exp => blk: {
                const exponential = try self.scalarUnary(function, block, .exp, primal, source);
                break :blk self.scalarBinary(function, block, .mul, exponential, tangent, source);
            },
            .log => self.scalarBinary(function, block, .div, tangent, primal, source),
            .log2 => blk: {
                const first = try self.scalarOne(function, block, primal, source);
                const second = try self.scalarOne(function, block, primal, source);
                const two = try self.scalarBinary(function, block, .add, first, second, source);
                const logarithm = try self.scalarUnary(function, block, .log, two, source);
                const denominator = try self.scalarBinary(function, block, .mul, logarithm, primal, source);
                break :blk self.scalarBinary(function, block, .div, tangent, denominator, source);
            },
            .log10 => blk: {
                var ten = try self.scalarOne(function, block, primal, source);
                var i: usize = 1;
                while (i < 10) : (i += 1) {
                    const one = try self.scalarOne(function, block, primal, source);
                    ten = try self.scalarBinary(function, block, .add, ten, one, source);
                }
                const logarithm = try self.scalarUnary(function, block, .log, ten, source);
                const denominator = try self.scalarBinary(function, block, .mul, logarithm, primal, source);
                break :blk self.scalarBinary(function, block, .div, tangent, denominator, source);
            },
            else => return error.Unsupported,
        };
    }

    fn emitBinaryRule(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        builtin: rules.BuiltinJvp,
        left: Pair,
        right: Pair,
        source: SourceUnit.Ref,
    ) Error!Code.ValueId {
        const left_t = try self.materialize(function, block, left, source);
        const right_t = try self.materialize(function, block, right, source);
        return switch (builtin) {
            .add => self.scalarBinary(function, block, .add, left_t, right_t, source),
            .sub => self.scalarBinary(function, block, .sub, left_t, right_t, source),
            .mul => blk: {
                const first = try self.scalarBinary(function, block, .mul, left_t, right.primal, source);
                const second = try self.scalarBinary(function, block, .mul, left.primal, right_t, source);
                break :blk self.scalarBinary(function, block, .add, first, second, source);
            },
            .div => blk: {
                const first = try self.scalarBinary(function, block, .mul, left_t, right.primal, source);
                const second = try self.scalarBinary(function, block, .mul, left.primal, right_t, source);
                const numerator = try self.scalarBinary(function, block, .sub, first, second, source);
                const denominator = try self.scalarBinary(function, block, .mul, right.primal, right.primal, source);
                break :blk self.scalarBinary(function, block, .div, numerator, denominator, source);
            },
            .pow => blk: {
                const left_active = left.active;
                const right_active = right.active;
                if (!left_active and !right_active) return self.scalarZero(function, block, left.primal, source);
                const one = try self.scalarOne(function, block, right.primal, source);
                const uv = try self.scalarBinary(function, block, .pow, left.primal, right.primal, source);
                if (left_active and !right_active) {
                    const exponent = try self.scalarBinary(function, block, .sub, right.primal, one, source);
                    const power = try self.scalarBinary(function, block, .pow, left.primal, exponent, source);
                    const factor = try self.scalarBinary(function, block, .mul, right.primal, power, source);
                    break :blk self.scalarBinary(function, block, .mul, factor, left_t, source);
                }
                if (!left_active and right_active) {
                    const log_left = try self.scalarUnary(function, block, .log, left.primal, source);
                    const factor = try self.scalarBinary(function, block, .mul, uv, log_left, source);
                    break :blk self.scalarBinary(function, block, .mul, factor, right_t, source);
                }
                const log_left = try self.scalarUnary(function, block, .log, left.primal, source);
                const term_one = try self.scalarBinary(function, block, .mul, right_t, log_left, source);
                const quotient = try self.scalarBinary(function, block, .div, left_t, left.primal, source);
                const term_two = try self.scalarBinary(function, block, .mul, right.primal, quotient, source);
                const sum = try self.scalarBinary(function, block, .add, term_one, term_two, source);
                break :blk self.scalarBinary(function, block, .mul, uv, sum, source);
            },
            else => return error.Unsupported,
        };
    }

    fn tensorOperationTag(self: *const Transform, value: Code.ValueId) ?tensor.Operation {
        for (self.source.nodes) |node| {
            if (node.result != value or node.operation != .literal) continue;
            const literal = node.operation.literal;
            if (literal.typ != b.type_i64) return null;
            const raw = literal.obj.toInt(i64);
            if (raw < @intFromEnum(tensor.Operation.stack) or
                raw > @intFromEnum(tensor.Operation.scan))
            {
                return null;
            }
            return @enumFromInt(raw);
        }
        return null;
    }

    fn tensorLiteralI64(self: *const Transform, value: Code.ValueId) ?i64 {
        for (self.source.nodes) |node| {
            if (node.result != value or node.operation != .literal) continue;
            const literal = node.operation.literal;
            if (literal.typ != b.type_i64) return null;
            return literal.obj.toInt(i64);
        }
        return null;
    }

    fn emitTensorListDrop(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        value: Code.ValueId,
        count: usize,
        source: SourceUnit.Ref,
    ) Error!Code.ValueId {
        var result = value;
        var index: usize = 0;
        while (index < count) : (index += 1) {
            result = try self.emitNative(function, block, &skript.intrinsics.list.rst, &.{result}, source);
        }
        return result;
    }

    fn emitTensorListPrefix(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        value: Code.ValueId,
        count: usize,
        source: SourceUnit.Ref,
    ) Error!Code.ValueId {
        var elements: std.ArrayList(Code.ValueId) = .empty;
        defer elements.deinit(self.scratch);
        try elements.ensureTotalCapacity(self.scratch, count);
        var cursor = value;
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const element = try self.emitNative(
                function,
                block,
                &skript.intrinsics.list.fst,
                &.{cursor},
                source,
            );
            elements.appendAssumeCapacity(element);
            cursor = try self.emitNative(
                function,
                block,
                &skript.intrinsics.list.rst,
                &.{cursor},
                source,
            );
        }
        var result = try self.addNil(function, block, source);
        var reverse = elements.items.len;
        while (reverse > 0) {
            reverse -= 1;
            result = try self.emitNative(
                function,
                block,
                &skript.intrinsics.list.cons,
                &.{ elements.items[reverse], result },
                source,
            );
        }
        return result;
    }

    fn emitTensorNestedDispatchJvp(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        arguments: []const Code.ValueId,
        source: SourceUnit.Ref,
    ) Error!?Pair {
        if (arguments.len < 4) return error.ArityMismatch;
        const operation = self.tensorOperationTag(arguments[0]) orelse return error.Unsupported;
        const callback_arity: usize = switch (operation) {
            .map => 1,
            .map2, .outer, .fold, .scan => 2,
            else => return error.Unsupported,
        };
        const raw_order = self.tensorLiteralI64(arguments[2]) orelse return error.Unsupported;
        const order = std.math.cast(u8, raw_order) orelse return error.Unsupported;
        if (order >= tensor.max_nested_order) return error.Unsupported;
        const raw_lane_count = self.tensorLiteralI64(arguments[3]) orelse return error.Unsupported;
        const lane_count = std.math.cast(usize, raw_lane_count) orelse return error.Unsupported;
        if (lane_count == 0 or lane_count > tensor.max_nested_lanes) return error.Unsupported;
        if (lane_count != (@as(usize, 1) << @intCast(order))) {
            return error.Unsupported;
        }
        const payload_len = arguments.len - 4;
        if (payload_len == 0 or payload_len % lane_count != 0) return error.ArityMismatch;
        const payload_count = payload_len / lane_count;
        switch (operation) {
            .map, .fold, .scan => if (payload_count != 1 and payload_count != 2) return error.ArityMismatch,
            .map2, .outer => if (payload_count != 2) return error.ArityMismatch,
            else => unreachable,
        }

        var pairs = try self.scratch.alloc(Pair, arguments.len);
        defer self.scratch.free(pairs);
        if (pairs.len < 4) return error.ArityMismatch;
        for (arguments, 0..) |argument, index| pairs[index] = try self.mapped(argument);
        const callback = try self.emitCallbackKernel(
            function,
            block,
            arguments[1],
            callback_arity,
            source,
        );
        const next_order = order + 1;
        const next_lane_count = std.math.mul(usize, lane_count, 2) catch return error.Unsupported;
        if (next_lane_count > tensor.max_nested_lanes) return error.Unsupported;
        var tangent_args: std.ArrayList(Code.ValueId) = .empty;
        defer tangent_args.deinit(self.scratch);
        const tangent_capacity = std.math.add(
            usize,
            4,
            std.math.mul(usize, payload_len, 2) catch return error.Unsupported,
        ) catch return error.Unsupported;
        try tangent_args.ensureTotalCapacity(self.scratch, tangent_capacity);
        tangent_args.appendAssumeCapacity(pairs[0].primal);
        tangent_args.appendAssumeCapacity(callback);
        tangent_args.appendAssumeCapacity(
            try self.addLiteral(function, block, .i64(next_order), source),
        );
        tangent_args.appendAssumeCapacity(
            try self.addLiteral(function, block, .i64(@intCast(next_lane_count)), source),
        );
        for (pairs[4..]) |pair| tangent_args.appendAssumeCapacity(pair.primal);
        for (pairs[4..]) |pair| tangent_args.appendAssumeCapacity(pair.tangent);
        const nested = try self.emitNative(function, block, &tensor.dispatchNested, tangent_args.items, source);
        const primal = try self.emitTensorListPrefix(function, block, nested, lane_count, source);
        const tangent = try self.emitTensorListDrop(function, block, nested, lane_count, source);
        return .{ .primal = primal, .tangent = tangent, .active = true };
    }

    fn emitTensorDispatchJvp(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        arguments: []const Code.ValueId,
        source: SourceUnit.Ref,
    ) Error!?Pair {
        if (arguments.len < 2) return error.ArityMismatch;
        if ((arguments.len - 2) % 2 != 0) return error.InvalidCode;
        const operation = self.tensorOperationTag(arguments[0]) orelse return error.Unsupported;
        const callback_arity: usize = switch (operation) {
            .map => 1,
            .map2, .outer, .fold, .scan => 2,
            else => 0,
        };
        var primal_args: std.ArrayList(Code.ValueId) = .empty;
        defer primal_args.deinit(self.scratch);
        var tangent_args: std.ArrayList(Code.ValueId) = .empty;
        defer tangent_args.deinit(self.scratch);
        try primal_args.ensureTotalCapacity(self.scratch, arguments.len);
        try tangent_args.ensureTotalCapacity(self.scratch, arguments.len);
        var pairs = try self.scratch.alloc(Pair, arguments.len);
        defer self.scratch.free(pairs);
        if (pairs.len < 2) return error.ArityMismatch;
        for (arguments, 0..) |argument, index| {
            pairs[index] = try self.mapped(argument);
            primal_args.appendAssumeCapacity(pairs[index].primal);
            const payload_count = (arguments.len - 2) / 2;
            const static_control = switch (operation) {
                .tensor_get, .reshape => index >= 2 and (index - 2) % payload_count != 0,
                else => false,
            };
            if (index < 2 or static_control) {
                tangent_args.appendAssumeCapacity(pairs[index].primal);
            } else {
                tangent_args.appendAssumeCapacity(pairs[index].tangent);
            }
        }
        if (callback_arity == 0) {
            const primal = try self.emitNative(function, block, &tensor.dispatch, primal_args.items, source);
            const tangent = try self.emitNative(function, block, &tensor.dispatch, tangent_args.items, source);
            return .{ .primal = primal, .tangent = tangent, .active = true };
        }
        const callback = try self.emitCallbackKernel(
            function,
            block,
            arguments[1],
            callback_arity,
            source,
        );
        const nested_order: u8 = 2;
        const nested_lane_count: usize = 4;
        var nested_args: std.ArrayList(Code.ValueId) = .empty;
        defer nested_args.deinit(self.scratch);
        const payload_len = arguments.len - 2;
        const nested_capacity = std.math.add(
            usize,
            4,
            std.math.mul(usize, payload_len, 2) catch return error.Unsupported,
        ) catch return error.Unsupported;
        try nested_args.ensureTotalCapacity(self.scratch, nested_capacity);
        nested_args.appendAssumeCapacity(pairs[0].primal);
        nested_args.appendAssumeCapacity(callback);
        nested_args.appendAssumeCapacity(
            try self.addLiteral(function, block, .i64(nested_order), source),
        );
        nested_args.appendAssumeCapacity(
            try self.addLiteral(function, block, .i64(nested_lane_count), source),
        );
        for (pairs[2..]) |pair| nested_args.appendAssumeCapacity(pair.primal);
        for (pairs[2..]) |pair| nested_args.appendAssumeCapacity(pair.tangent);
        const nested = try self.emitNative(function, block, &tensor.dispatchNested, nested_args.items, source);
        const primal = try self.emitTensorListPrefix(function, block, nested, nested_lane_count / 2, source);
        const tangent = try self.emitTensorListDrop(function, block, nested, nested_lane_count / 2, source);
        return .{ .primal = primal, .tangent = tangent, .active = true };
    }

    fn emitTensorJvp(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        primitive: Primitive.PrimitiveId,
        arguments: []const Code.ValueId,
        source: SourceUnit.Ref,
    ) Error!?Pair {
        if (self.ctx.registry.idForNative(&tensor.dispatchNested)) |nested_primitive| {
            if (primitive == nested_primitive) {
                return self.emitTensorNestedDispatchJvp(function, block, arguments, source);
            }
        }
        if (self.ctx.registry.idForNative(&tensor.dispatch)) |dispatch_primitive| {
            if (primitive == dispatch_primitive) {
                return self.emitTensorDispatchJvp(function, block, arguments, source);
            }
        }
        const rule = self.rule_version.find(primitive) orelse return null;
        const jvp = rule.jvp orelse return null;
        const operation: tensor.Operation = switch (jvp) {
            .builtin => |builtin| switch (builtin) {
                .map => .map,
                .map2 => .map2,
                .outer => .outer,
                .fold => .fold,
                .scan => .scan,
                .stack, .tensor_get, .reshape, .transpose, .dot => return null,
                else => return null,
            },
            else => return null,
        };
        const callback_arity: usize = switch (operation) {
            .map => 1,
            .map2, .outer, .fold, .scan => 2,
            else => 0,
        };
        if (arguments.len == 0 and operation != .stack) return error.ArityMismatch;
        var kernel = try self.addNil(function, block, source);
        var payload = arguments;
        if (callback_arity != 0) {
            if (arguments.len < 2) return error.ArityMismatch;
            payload = arguments[0 .. arguments.len - 1];
            kernel = try self.emitCallbackKernel(function, block, arguments[arguments.len - 1], callback_arity, source);
        }
        var args: std.ArrayList(Code.ValueId) = .empty;
        defer args.deinit(self.scratch);
        try args.append(self.scratch, try self.addLiteral(function, block, .i64(@intFromEnum(operation)), source));
        try args.append(self.scratch, kernel);
        for (payload) |argument| try args.append(self.scratch, (try self.mapped(argument)).primal);
        for (payload) |argument| try args.append(self.scratch, (try self.mapped(argument)).tangent);
        const result_list = try self.emitNative(function, block, &tensor.dispatch, args.items, source);
        const primal = try self.emitNative(function, block, &skript.intrinsics.list.fst, &.{result_list}, source);
        const rest = try self.emitNative(function, block, &skript.intrinsics.list.rst, &.{result_list}, source);
        const tangent = try self.emitNative(function, block, &skript.intrinsics.list.fst, &.{rest}, source);
        return .{ .primal = primal, .tangent = tangent, .active = true };
    }

    fn emitCallbackKernel(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        callback: Code.ValueId,
        arity: usize,
        source: SourceUnit.Ref,
    ) Error!Code.ValueId {
        const pair = try self.mapped(callback);
        if (self.lookupCallable(pair.tangent) != null) return pair.tangent;
        if (try self.isClosureJoin(callback, 0)) return pair.tangent;
        const callable = (try self.staticCallable(callback)) orelse return error.Unsupported;
        if (self.generation_depth >= max_generation_depth) return error.Unsupported;
        const bound = if (callable.typ == b.type_closure)
            callable
        else
            try skript.intrinsics.ad.bindCallable(self.ctx, callable, arity);
        const generated = try generateAtDepth(
            self.ctx,
            bound,
            0,
            .full_jvp,
            self.generation_depth + 1,
            self.session,
        );
        self.noteGeneratedHigherOrder(bound);
        return self.addLiteral(function, block, generated, source);
    }

    fn emitNative(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        native: skript.FuncPtr,
        args: []const Code.ValueId,
        source: SourceUnit.Ref,
    ) Error!Code.ValueId {
        const primitive = self.ctx.registry.idForNative(native) orelse return error.Unsupported;
        return self.emitSamePrimitive(function, block, primitive, args, source);
    }

    fn emitCustomJvp(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        primitive: Primitive.PrimitiveId,
        arguments: []const Code.ValueId,
        source: SourceUnit.Ref,
    ) Error!?Pair {
        const rule = self.rule_version.find(primitive) orelse return null;
        const Selected = union(enum) {
            jvp: rules.JvpRule,
            linearize: rules.CodeRule,
        };
        const selected: Selected = if (rule.jvp) |jvp| switch (jvp) {
            .builtin => return null,
            else => .{ .jvp = jvp },
        } else if (rule.linearize) |linearize| .{ .linearize = linearize } else return null;
        if (rule.metadata.arity) |arity| if (arity != arguments.len) return error.ArityMismatch;
        self.higher_order = self.higher_order and rule.metadata.higher_order;

        const callable = switch (selected) {
            .jvp => |body| switch (body) {
                .code => |code| try rules.materializeCodeCallable(self.ctx, code),
                .hook => |hook| hook.callable,
                .builtin => unreachable,
            },
            .linearize => |body| try rules.materializeCodeCallable(self.ctx, body),
        };
        const namespace = switch (selected) {
            .jvp => |body| switch (body) {
                .hook => |hook| hook.namespace,
                .code => callable.obj.toRef().deref(Closure).parent_ns,
                .builtin => unreachable,
            },
            .linearize => callable.obj.toRef().deref(Closure).parent_ns,
        };
        const dependencies = try Effects.collectReads(self.runtime, namespace, callable, self.scratch);
        defer self.scratch.free(dependencies);
        try self.extra_reads.appendSlice(self.scratch, dependencies);
        const primals = try self.scratch.alloc(Code.ValueId, arguments.len);
        defer self.scratch.free(primals);
        const tangents = try self.scratch.alloc(Code.ValueId, arguments.len);
        defer self.scratch.free(tangents);
        for (arguments, primals, tangents) |argument, *primal, *tangent| {
            const pair = try self.mapped(argument);
            primal.* = pair.primal;
            tangent.* = try self.materialize(function, block, pair, source);
        }
        const callee = try self.addLiteral(function, block, callable, source);
        switch (selected) {
            .jvp => |body| {
                if (body == .hook) {
                    return try self.emitHookJvp(function, block, callee, primals, tangents, source);
                }
                var args: std.ArrayList(Code.ValueId) = .empty;
                defer args.deinit(self.scratch);
                try args.appendSlice(self.scratch, primals);
                try args.appendSlice(self.scratch, tangents);
                const result = try self.addGeneratedNode(function, block, .{ .dynamic_call = .{
                    .callee = callee,
                    .args = try self.builder.addOperands(args.items),
                    .result_count = 2,
                } }, source);
                return .{ .primal = result, .tangent = @enumFromInt(@intFromEnum(result) + 1), .active = true };
            },
            .linearize => {
                const result = try self.addGeneratedNode(function, block, .{ .dynamic_call = .{
                    .callee = callee,
                    .args = try self.builder.addOperands(primals),
                    .result_count = 1,
                } }, source);
                const checked = try self.emitNative(function, block, &rules.checkHookResult, &.{result}, source);
                const primal = try self.emitNative(function, block, &skript.intrinsics.list.fst, &.{checked}, source);
                const residuals = try self.emitNative(
                    function,
                    block,
                    &skript.intrinsics.list.rst,
                    &.{checked},
                    source,
                );
                const linear = try self.emitNative(function, block, &skript.intrinsics.list.fst, &.{residuals}, source);
                const tangent = try self.addGeneratedNode(function, block, .{ .dynamic_call = .{
                    .callee = linear,
                    .args = try self.builder.addOperands(tangents),
                    .result_count = 1,
                } }, source);
                return .{ .primal = primal, .tangent = tangent, .active = true };
            },
        }
    }

    fn emitHookJvp(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        callee: Code.ValueId,
        primals: []const Code.ValueId,
        tangents: []const Code.ValueId,
        source: SourceUnit.Ref,
    ) Error!Pair {
        const primal_list = try self.emitNative(function, block, &skript.intrinsics.list.list, primals, source);
        const tangent_list = try self.emitNative(function, block, &skript.intrinsics.list.list, tangents, source);
        const result = try self.addGeneratedNode(function, block, .{ .dynamic_call = .{
            .callee = callee,
            .args = try self.builder.addOperands(&.{ primal_list, tangent_list }),
        } }, source);
        const checked = try self.emitNative(function, block, &rules.checkHookResult, &.{result}, source);
        const primal = try self.emitNative(function, block, &skript.intrinsics.list.fst, &.{checked}, source);
        const rest = try self.emitNative(function, block, &skript.intrinsics.list.rst, &.{checked}, source);
        const tangent = try self.emitNative(function, block, &skript.intrinsics.list.fst, &.{rest}, source);
        return .{ .primal = primal, .tangent = tangent, .active = true };
    }

    fn primitiveDescriptor(self: *const Transform, primitive: Primitive.PrimitiveId) Error!rules.Descriptor {
        const spec = self.ctx.registry.spec(primitive) orelse return error.Unsupported;
        if (spec.id != primitive) return error.Unsupported;
        if (self.rule_version.find(primitive)) |rule| {
            if (rule.primitive_revision != spec.implementation_revision) return error.Unsupported;
            if (rule.jvp) |jvp| switch (jvp) {
                .builtin => |builtin| {
                    return .{ .rule = builtin, .metadata = rule.metadata };
                },
                else => {},
            };
        }
        return error.Unsupported;
    }

    fn scalarTag(self: *const Transform, args: []const Code.ValueId) ?rules.ScalarOp {
        if (args.len == 0) return null;
        const id = @intFromEnum(args[0]);
        if (id >= self.source.values.len) return null;
        for (self.source.nodes) |node| {
            if (node.result != args[0]) continue;
            if (node.operation != .literal) return null;
            const literal = node.operation.literal;
            if (literal.typ != b.type_i64) return null;
            const raw = literal.obj.toInt(i64);
            if (raw < 0 or raw > @intFromEnum(rules.ScalarOp.realize_tangent)) return null;
            return @enumFromInt(raw);
        }
        return null;
    }

    fn emitTensorStructuralTangent(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        operation: tensor.Operation,
        arguments: []const Code.ValueId,
        source: SourceUnit.Ref,
    ) Error!Code.ValueId {
        var pairs = try self.scratch.alloc(Pair, arguments.len);
        defer self.scratch.free(pairs);
        var dispatch_args: std.ArrayList(Code.ValueId) = .empty;
        defer dispatch_args.deinit(self.scratch);
        try dispatch_args.append(
            self.scratch,
            try self.addLiteral(function, block, .i64(@intFromEnum(operation)), source),
        );
        try dispatch_args.append(self.scratch, try self.addNil(function, block, source));
        for (arguments, 0..) |argument, index| {
            pairs[index] = try self.mapped(argument);
            try dispatch_args.append(self.scratch, pairs[index].primal);
        }
        for (pairs) |pair| try dispatch_args.append(self.scratch, pair.tangent);
        const result_list = try self.emitNative(function, block, &tensor.dispatch, dispatch_args.items, source);
        const rest = try self.emitNative(function, block, &skript.intrinsics.list.rst, &.{result_list}, source);
        return self.emitNative(function, block, &skript.intrinsics.list.fst, &.{rest}, source);
    }

    fn emitPrimitiveTangent(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        primitive: Primitive.PrimitiveId,
        source_args: []const Code.ValueId,
        source: SourceUnit.Ref,
    ) Error!Code.ValueId {
        const cotangent_zero = self.ctx.registry.idForNative(&skript.autodiff_linearize.cotangentZero) orelse .invalid;
        if (primitive == cotangent_zero) {
            if (source_args.len != 1) return error.ArityMismatch;
            const record = try self.mapped(source_args[0]);
            if (record.active) return error.Unsupported;
            return self.emitNative(
                function,
                block,
                &skript.autodiff_linearize.cotangentZero,
                &.{record.primal},
                source,
            );
        }
        const cotangent_add = self.ctx.registry.idForNative(&skript.autodiff_linearize.cotangentAdd) orelse .invalid;
        if (primitive == cotangent_add) {
            if (source_args.len != 3) return error.ArityMismatch;
            const record = try self.mapped(source_args[0]);
            if (record.active) return error.Unsupported;
            const left = try self.mapped(source_args[1]);
            const right = try self.mapped(source_args[2]);
            return self.emitNative(function, block, &skript.autodiff_linearize.cotangentAdd, &.{
                record.primal,
                left.tangent,
                right.tangent,
            }, source);
        }
        const descriptor = try self.primitiveDescriptor(primitive);
        if (descriptor.rule == .dispatch) {
            if (source_args.len == 0) return error.ArityMismatch;
            const operation = self.scalarTag(source_args) orelse return error.Unsupported;
            const args = source_args[1..];
            const scalar_jvp = rules.scalarJvp(operation) orelse return error.Unsupported;
            if (operation == .zero_like or operation == .one_like or operation == .abs_slope) {
                if (args.len != 1) return error.ArityMismatch;
                return self.scalarZero(function, block, (try self.mapped(args[0])).primal, source);
            }
            if (operation == .coerce_tangent or operation == .realize_tangent) {
                if (args.len != 2) return error.ArityMismatch;
                return self.scalarCall(function, block, .realize_tangent, &.{
                    (try self.mapped(args[0])).primal,
                    (try self.mapped(args[1])).tangent,
                }, source);
            }
            if (args.len == 1) {
                const pair = try self.mapped(args[0]);
                if (!pair.active) return self.scalarZero(function, block, pair.primal, source);
                const materialized = try self.materialize(function, block, pair, source);
                return self.emitUnaryRule(
                    function,
                    block,
                    scalar_jvp,
                    pair.primal,
                    materialized,
                    source,
                );
            }
            if (args.len == 2) {
                const left = try self.mapped(args[0]);
                const right = try self.mapped(args[1]);
                if (!left.active and !right.active) return self.scalarZero(function, block, left.primal, source);
                return self.emitBinaryRule(function, block, scalar_jvp, left, right, source);
            }
            return error.Unsupported;
        }

        const args = source_args;
        switch (descriptor.rule) {
            .constant, .predicate => {
                if (args.len == 0) return error.ArityMismatch;
                return self.scalarZero(function, block, (try self.mapped(args[0])).primal, source);
            },
            .construct => {
                if (args.len != 1) return error.ArityMismatch;
                const pair = try self.mapped(args[0]);
                if (!pair.active) return self.scalarZero(function, block, pair.primal, source);
                const materialized = try self.materialize(function, block, pair, source);
                return self.scalarCall(
                    function,
                    block,
                    .coerce_tangent,
                    &.{ pair.primal, materialized },
                    source,
                );
            },
            .runtime_owned_output => {
                if (args.len != 1) return error.ArityMismatch;
                const pair = try self.mapped(args[0]);
                if (!pair.active) return self.scalarZero(function, block, pair.primal, source);
                return self.emitSamePrimitive(function, block, primitive, &.{
                    try self.materialize(function, block, pair, source),
                }, source);
            },
            .add, .sub, .mul, .div, .pow => {
                if (args.len != 2) return error.ArityMismatch;
                const left = try self.mapped(args[0]);
                const right = try self.mapped(args[1]);
                if (!left.active and !right.active) return self.scalarZero(function, block, left.primal, source);
                return self.emitBinaryRule(function, block, descriptor.rule, left, right, source);
            },
            .neg,
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
            => {
                if (args.len != 1) return error.ArityMismatch;
                const pair = try self.mapped(args[0]);
                if (!pair.active) return self.scalarZero(function, block, pair.primal, source);
                const materialized = try self.materialize(function, block, pair, source);
                return self.emitUnaryRule(
                    function,
                    block,
                    descriptor.rule,
                    pair.primal,
                    materialized,
                    source,
                );
            },
            .abs => {
                if (args.len != 1) return error.ArityMismatch;
                const pair = try self.mapped(args[0]);
                if (!pair.active) return self.scalarZero(function, block, pair.primal, source);
                const slope = try self.scalarCall(function, block, .abs_slope, &.{pair.primal}, source);
                const materialized = try self.materialize(function, block, pair, source);
                return self.scalarBinary(function, block, .mul, slope, materialized, source);
            },
            .cons => {
                if (args.len != 2) return error.ArityMismatch;
                const left = try self.mapped(args[0]);
                const right = try self.mapped(args[1]);
                if (!left.active and !right.active) return self.scalarZero(function, block, left.primal, source);
                const left_tangent = try self.materialize(function, block, left, source);
                const right_tangent = try self.materialize(function, block, right, source);
                return self.emitSamePrimitive(
                    function,
                    block,
                    primitive,
                    &.{ left_tangent, right_tangent },
                    source,
                );
            },
            .fst, .rst => {
                if (args.len != 1) return error.ArityMismatch;
                const pair = try self.mapped(args[0]);
                if (!pair.active) return self.scalarZero(function, block, pair.primal, source);
                const materialized = try self.materialize(function, block, pair, source);
                return self.emitSamePrimitive(function, block, primitive, &.{materialized}, source);
            },
            .tensor_linear_apply, .tensor_linear_transpose => {
                if (args.len < 2) return error.ArityMismatch;
                const record = try self.mapped(args[0]);
                if (record.active) return error.Unsupported;
                var values: std.ArrayList(Code.ValueId) = .empty;
                defer values.deinit(self.scratch);
                try values.append(self.scratch, record.primal);
                for (args[1..]) |argument| {
                    const pair = try self.mapped(argument);
                    const materialized = try self.materialize(function, block, pair, source);
                    try values.append(self.scratch, materialized);
                }
                return self.emitSamePrimitive(function, block, primitive, values.items, source);
            },
            .list, .stack, .map_create => {
                if (args.len == 0) return error.ArityMismatch;
                var values = std.ArrayList(Code.ValueId).empty;
                defer values.deinit(self.scratch);
                var active = false;
                for (args, 0..) |arg, index| {
                    const pair = try self.mapped(arg);
                    if (descriptor.rule == .map_create and index % 2 == 0) {
                        try values.append(self.scratch, pair.primal);
                    } else {
                        active = active or pair.active;
                        try values.append(self.scratch, try self.materialize(function, block, pair, source));
                    }
                }
                if (!active) return self.scalarZero(function, block, (try self.mapped(args[0])).primal, source);
                return self.emitSamePrimitive(function, block, primitive, values.items, source);
            },
            .map_get => {
                if (args.len == 0) return error.ArityMismatch;
                const pair = try self.mapped(args[0]);
                if (!pair.active) return self.scalarZero(function, block, pair.primal, source);
                var values = std.ArrayList(Code.ValueId).empty;
                defer values.deinit(self.scratch);
                try values.append(self.scratch, try self.materialize(function, block, pair, source));
                for (args[1..]) |arg| try values.append(self.scratch, (try self.mapped(arg)).primal);
                return self.emitSamePrimitive(function, block, primitive, values.items, source);
            },
            .tensor_get => {
                if (args.len < 2) return error.ArityMismatch;
                return self.emitTensorStructuralTangent(
                    function,
                    block,
                    .tensor_get,
                    args,
                    source,
                );
            },
            .reshape => {
                if (args.len != 2) return error.ArityMismatch;
                return self.emitTensorStructuralTangent(
                    function,
                    block,
                    .reshape,
                    args,
                    source,
                );
            },
            .transpose => {
                if (args.len != 1) return error.ArityMismatch;
                const pair = try self.mapped(args[0]);
                if (!pair.active) return self.scalarZero(function, block, pair.primal, source);
                const materialized = try self.materialize(function, block, pair, source);
                return self.emitSamePrimitive(function, block, primitive, &.{materialized}, source);
            },
            .dot => {
                if (args.len != 2) return error.ArityMismatch;
                const left = try self.mapped(args[0]);
                const right = try self.mapped(args[1]);
                if (!left.active and !right.active) return self.scalarZero(function, block, left.primal, source);
                var tangent: ?Code.ValueId = null;
                if (left.active) {
                    const left_tangent = try self.materialize(function, block, left, source);
                    tangent = try self.emitSamePrimitive(
                        function,
                        block,
                        primitive,
                        &.{ left_tangent, right.primal },
                        source,
                    );
                }
                if (right.active) {
                    const right_tangent = try self.materialize(function, block, right, source);
                    const term = try self.emitSamePrimitive(
                        function,
                        block,
                        primitive,
                        &.{ left.primal, right_tangent },
                        source,
                    );
                    tangent = if (tangent) |current|
                        try self.scalarBinary(function, block, .add, current, term, source)
                    else
                        term;
                }
                return tangent orelse error.Unsupported;
            },
            else => return error.Unsupported,
        }
    }
    fn emitSamePrimitive(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        primitive: Primitive.PrimitiveId,
        args: []const Code.ValueId,
        source: SourceUnit.Ref,
    ) Error!Code.ValueId {
        return self.addGeneratedNode(function, block, .{ .primitive_call = .{
            .primitive = primitive,
            .args = try self.builder.addOperands(args),
            .result_count = 1,
        } }, source);
    }

    fn staticCallable(self: *const Transform, original: Code.ValueId) Error!?Value {
        var value_id = original;
        for (0..self.source.values.len) |_| {
            try self.ctx.chargeWork(1, 1, .code);
            if (capturedValueInCode(self.source, self.source_closure, value_id)) |captured| return captured;
            var next: ?Code.ValueId = null;
            for (self.source.nodes) |node| {
                if (node.result != value_id) continue;
                switch (node.operation) {
                    .literal, .quote => |value| return value,
                    .local_read => |binding| {
                        next = self.source.bindings[@intFromEnum(binding)].value;
                    },
                    .global_read => |global| {
                        const cell = self.source.globals[@intFromEnum(global)];
                        if (cell.binding == .invalid) {
                            return try self.runtime.nsGet(self.source_closure.parent_ns, cell.name);
                        }
                        next = self.source.bindings[@intFromEnum(cell.binding)].value;
                    },
                    else => return null,
                }
                break;
            }
            value_id = next orelse return null;
            if (value_id == .invalid) return null;
        }
        return error.InvalidCode;
    }

    fn staticPrimitive(self: *const Transform, callable: Value) Error!?Primitive.PrimitiveId {
        if (callable.typ == b.type_intrinsic) return self.ctx.registry.idForNative(callable.obj.toPtr(skript.FuncPtr));
        if (callable.typ != b.type_method) return null;
        const method = callable.obj.toRef().deref(skript.data.Method);
        var iterator = method.resolved.valueIterator();
        var selected: ?Primitive.PrimitiveId = null;
        var family: ?rules.BuiltinJvp = null;
        while (iterator.next()) |target| {
            try self.ctx.chargeWork(1, 1, .code);
            if (target.typ != b.type_intrinsic) return null;
            const primitive = self.ctx.registry.idForNative(target.obj.toPtr(skript.FuncPtr)) orelse return null;
            const descriptor = try self.primitiveDescriptor(primitive);
            if (family) |expected| {
                if (descriptor.rule != expected) return null;
            } else {
                family = descriptor.rule;
                selected = primitive;
            }
        }
        return selected;
    }

    fn isCurrentSourceClosure(self: *const Transform, value: Value) bool {
        if (value.typ != b.type_closure or value.obj == .null) return false;
        return value.obj.toRef().deref(Closure) == self.source_closure;
    }
    fn isCurrentSourceFunction(self: *const Transform, value: Value, function: Code.FunctionId) bool {
        if (!self.isCurrentSourceClosure(value)) return false;
        return value.obj.toRef().deref(Closure).function_id == function;
    }

    fn addSourceGeneratedClosure(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        helper: *const Closure,
        source: SourceUnit.Ref,
    ) Error!Code.ValueId {
        const helper_code = helper.code orelse return error.Unsupported;
        if (helper_code != self.source) return error.InvalidCode;
        const helper_info = try sourceFunction(helper_code, helper.function_id);
        const helper_index = @intFromEnum(helper.function_id);
        if (helper_index >= self.functions.len) return error.InvalidCode;
        const target = self.functions[helper_index].jvp;
        if (target == .invalid) return error.Unsupported;
        const target_info = self.builder.functions.items[@intFromEnum(target)];

        var captures = std.ArrayList(Code.ValueId).empty;
        defer captures.deinit(self.scratch);
        if (helper == self.source_closure) {
            const capture_range = try self.functionCaptureRange(helper.function_id);
            for (capture_range.start..capture_range.end) |capture_index| {
                const pair = self.captures[capture_index];
                try captures.append(self.scratch, pair.primal);
                try captures.append(self.scratch, pair.tangent);
            }
        } else {
            if (helper.captures.len != helper_info.capture_count) return error.InvalidCode;
            for (helper.captures) |capture| {
                try captures.append(self.scratch, try self.addLiteral(function, block, capture, source));
                try captures.append(self.scratch, try self.addNil(function, block, source));
            }
        }
        if (captures.items.len != target_info.capture_count) return error.InvalidCode;
        return self.addGeneratedNode(function, block, .{ .make_closure = .{
            .function = target,
            .captures = try self.builder.addOperands(captures.items),
        } }, source);
    }

    fn emitResolvedHelperPair(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        node: Code.Node,
        callable: Value,
        arguments: []const Code.ValueId,
    ) Error!Pair {
        if (callable.typ != b.type_closure or callable.obj == .null) return error.Unsupported;
        const helper = callable.obj.toRef().deref(Closure);
        const helper_code = helper.code orelse return error.Unsupported;
        const target = try sourceFunction(helper_code, helper.function_id);
        if (target.parameter_count != arguments.len or target.result_count != 1) {
            return error.ArityMismatch;
        }
        const callee = if (helper_code == self.source)
            try self.addSourceGeneratedClosure(function, block, helper, node.source)
        else blk: {
            if (self.generation_depth >= max_generation_depth) return error.Unsupported;
            const generated = try generateAtDepth(
                self.ctx,
                callable,
                0,
                .full_jvp,
                self.generation_depth + 1,
                self.session,
            );
            self.noteGeneratedHigherOrder(callable);
            break :blk try self.addLiteral(function, block, generated, node.source);
        };
        const result = try self.addNode(function, block, .{ .dynamic_call = .{
            .callee = callee,
            .args = try self.addJvpArguments(arguments),
            .result_count = 2,
        } }, node);
        return .{
            .primal = result,
            .tangent = @enumFromInt(@intFromEnum(result) + 1),
            .active = true,
        };
    }

    fn emitStaticHelperCall(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        node: Code.Node,
        call: Code.Call,
        tail_results: ?[]Pair,
    ) Error!bool {
        const callable = (try self.staticCallable(call.callee)) orelse return false;
        if (callable.typ != b.type_closure or callable.obj == .null) return false;
        const arguments = try self.sourceOperands(call.args);
        const helper = callable.obj.toRef().deref(Closure);
        const helper_code = helper.code orelse return error.Unsupported;
        const target = try sourceFunction(helper_code, helper.function_id);
        if (target.parameter_count != arguments.len) return error.ArityMismatch;
        if (call.result_count > target.result_count) return error.InvalidCode;
        const callee = if (helper_code == self.source)
            try self.addSourceGeneratedClosure(function, block, helper, node.source)
        else blk: {
            if (self.generation_depth >= max_generation_depth) return error.Unsupported;
            const generated = try generateAtDepth(
                self.ctx,
                callable,
                0,
                .full_jvp,
                self.generation_depth + 1,
                self.session,
            );
            self.noteGeneratedHigherOrder(callable);
            break :blk try self.addLiteral(function, block, generated, node.source);
        };
        const result_count = std.math.mul(u8, target.result_count, 2) catch return error.Unsupported;
        const result = try self.addNode(function, block, .{ .dynamic_call = .{
            .callee = callee,
            .args = try self.addJvpArguments(arguments),
            .result_count = result_count,
        } }, node);
        var index: u8 = 0;
        while (index < call.result_count) : (index += 1) {
            const primal: Code.ValueId = @enumFromInt(@intFromEnum(result) + @as(u32, index) * 2);
            try self.recordCallResult(node, index, .{
                .primal = primal,
                .tangent = @enumFromInt(@intFromEnum(primal) + 1),
                .active = true,
            }, tail_results);
        }
        return true;
    }

    fn addJvpArguments(self: *Transform, arguments: []const Code.ValueId) Error!Code.OperandRange {
        var values: std.ArrayList(Code.ValueId) = .empty;
        defer values.deinit(self.scratch);
        try values.ensureTotalCapacity(self.scratch, arguments.len * 2);
        for (arguments) |argument| values.appendAssumeCapacity((try self.mapped(argument)).primal);
        for (arguments) |argument| values.appendAssumeCapacity((try self.mapped(argument)).tangent);
        return self.builder.addOperands(values.items);
    }

    fn recordCallResult(self: *Transform, node: Code.Node, index: u8, pair: Pair, tail_results: ?[]Pair) Error!void {
        if (tail_results) |results| {
            if (index >= results.len) return error.InvalidCode;
            results[index] = pair;
        } else {
            try self.setMapped(@enumFromInt(@intFromEnum(node.result) + index), pair);
        }
    }

    fn recordPairedResults(
        self: *Transform,
        node: Code.Node,
        count: u8,
        result: Code.ValueId,
        tail_results: ?[]Pair,
    ) Error!void {
        var index: u8 = 0;
        while (index < count) : (index += 1) {
            const primal: Code.ValueId = @enumFromInt(@intFromEnum(result) + @as(u32, index) * 2);
            try self.recordCallResult(node, index, .{
                .primal = primal,
                .tangent = @enumFromInt(@intFromEnum(primal) + 1),
                .active = true,
            }, tail_results);
        }
    }

    fn immutableCellCallable(self: *Transform, global: Code.GlobalCellId) Error!?Code.FunctionId {
        const cell = self.source.globals[@intFromEnum(global)];
        if (cell.binding == .invalid) return null;
        const binding = self.source.bindings[@intFromEnum(cell.binding)];
        var writes: usize = 0;
        for (self.source.nodes) |node| {
            try self.ctx.chargeWork(1, 1, .transform);
            if (node.operation != .global_write or node.operation.global_write.cell != global) continue;
            if (node.operation.global_write.value != binding.value) return null;
            writes += 1;
            if (writes > 1) return null;
        }
        if (writes != 1) return null;
        const pair = try self.mapped(binding.value);
        return if (self.lookupCallable(pair.tangent)) |info| info.function else null;
    }

    fn isControlOnly(self: *const Transform, value: Code.ValueId) Error!bool {
        if (value == .invalid) return false;
        var condition_use = false;
        for (self.source.nodes) |node| {
            try self.ctx.chargeWork(1, 1, .transform);
            const operands: Code.OperandRange = switch (node.operation) {
                .primitive_call => |call| call.args,
                .direct_call => |call| call.args,
                .dynamic_call => |call| blk: {
                    if (call.callee == value) return false;
                    break :blk call.args;
                },
                .make_closure => |closure| closure.captures,
                .arithmetic => |arith| {
                    if (arith.left == value or arith.right == value or arith.callee == value) return false;
                    continue;
                },
                .global_write => |write| {
                    if (write.value == value) return false;
                    continue;
                },
                .local_read => |binding| {
                    if (self.source.bindings[@intFromEnum(binding)].value == value) return false;
                    continue;
                },
                .global_read => |global| {
                    const binding = self.source.globals[@intFromEnum(global)].binding;
                    if (binding != .invalid and
                        self.source.bindings[@intFromEnum(binding)].value == value) return false;
                    continue;
                },
                else => continue,
            };
            try self.ctx.chargeWork(operands.len, 1, .transform);
            if (std.mem.indexOfScalar(Code.ValueId, try self.sourceOperands(operands), value) != null) return false;
        }
        for (self.source.blocks) |source_block| {
            try self.ctx.chargeWork(1, 1, .transform);
            var ranges: [2]Code.OperandRange = @splat(.{});
            switch (source_block.terminator) {
                .branch => |branch| {
                    condition_use = condition_use or branch.condition == value;
                    ranges = .{ branch.then_edge.args, branch.else_edge.args };
                },
                .jump => |edge| ranges[0] = edge.args,
                .return_values => |values| ranges[0] = values,
                .tail_call => |call| {
                    if (call.callee == value) return false;
                    ranges[0] = call.args;
                },
                .raise => |raised| if (raised == value) {
                    return false;
                },
                .none => {},
            }
            for (ranges) |range| {
                try self.ctx.chargeWork(range.len, 1, .transform);
                if (std.mem.indexOfScalar(Code.ValueId, try self.sourceOperands(range), value) != null) return false;
            }
        }
        return condition_use;
    }

    fn transformDynamicCall(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        node: Code.Node,
        call: Code.Call,
        tail_results: ?[]Pair,
    ) Error!void {
        if (call.result_count == 0) return error.InvalidCode;
        const arguments = try self.sourceOperands(call.args);
        const callee = try self.mapped(call.callee);
        var active = callee.active;
        for (arguments) |argument| active = active or (try self.mapped(argument)).active;
        // Predicates still execute and remain effect-checked. Their results
        // need no tangent when they are consumed only by control flow.
        const control_only = call.result_count == 1 and tail_results == null and try self.isControlOnly(node.result);
        if (!active or control_only) {
            const result = try self.addNode(function, block, .{ .dynamic_call = .{
                .callee = callee.primal,
                .args = try self.addMappedArgs(function, block, arguments, false, node.source),
                .result_count = call.result_count,
            } }, node);
            var index: u8 = 0;
            while (index < call.result_count) : (index += 1) {
                const primal: Code.ValueId = @enumFromInt(@intFromEnum(result) + index);
                const tangent = try self.emitPairNil(function, block, primal, node.source);
                try self.recordCallResult(node, index, tangent, tail_results);
            }
            return;
        }
        const resolved = try self.staticCallable(call.callee);
        if (call.self_target != .invalid) {
            const target_index = @intFromEnum(call.self_target);
            if (target_index >= self.functions.len) return error.InvalidCode;
            if (resolved) |target_value| {
                if (self.isCurrentSourceFunction(target_value, call.self_target)) {
                    const target = self.functions[target_index].jvp;
                    if (target == .invalid) return error.Unsupported;
                    const result = try self.addNode(function, block, .{ .direct_call = .{
                        .function = target,
                        .args = try self.addJvpArguments(arguments),
                        .result_count = self.builder.functions.items[@intFromEnum(target)].result_count,
                    } }, node);
                    return self.recordPairedResults(node, call.result_count, result, tail_results);
                }
            }
        }
        if (self.lookupCallable(callee.tangent)) |info| {
            const target = try sourceFunction(self.source, info.function);
            if (target.parameter_count != arguments.len) return error.ArityMismatch;
            if (call.result_count > target.result_count) return error.InvalidCode;
            const result = try self.addNode(function, block, .{ .dynamic_call = .{
                .callee = callee.tangent,
                .args = try self.addJvpArguments(arguments),
                .result_count = std.math.mul(u8, target.result_count, 2) catch return error.Unsupported,
            } }, node);
            return self.recordPairedResults(node, call.result_count, result, tail_results);
        }
        if (try self.emitStaticHelperCall(function, block, node, call, tail_results)) return;
        if (try self.isClosureJoin(call.callee, 0)) {
            const result = try self.addNode(function, block, .{ .dynamic_call = .{
                .callee = callee.tangent,
                .args = try self.addJvpArguments(arguments),
                .result_count = std.math.mul(u8, call.result_count, 2) catch return error.Unsupported,
            } }, node);
            return self.recordPairedResults(node, call.result_count, result, tail_results);
        }
        if (call.result_count == 1) {
            if (resolved) |target| {
                if (try self.staticPrimitive(target)) |primitive| {
                    if (try self.emitCustomJvp(function, block, primitive, arguments, node.source)) |pair| {
                        return self.recordCallResult(node, 0, pair, tail_results);
                    }
                    if (try self.emitTensorJvp(function, block, primitive, arguments, node.source)) |pair| {
                        return self.recordCallResult(node, 0, pair, tail_results);
                    }
                    const primal = try self.addNode(function, block, .{ .dynamic_call = .{
                        .callee = callee.primal,
                        .args = try self.addMappedArgs(function, block, arguments, false, node.source),
                    } }, node);
                    const tangent = try self.emitPrimitiveTangent(function, block, primitive, arguments, node.source);
                    const pair: Pair = .{
                        .primal = primal,
                        .tangent = tangent,
                        .active = true,
                    };
                    return self.recordCallResult(node, 0, pair, tail_results);
                }
            }
        }
        return error.Unsupported;
    }

    fn transformNode(
        self: *Transform,
        source_function: Code.FunctionId,
        function: Code.FunctionId,
        block: Code.BlockId,
        node: Code.Node,
    ) Error!void {
        switch (node.operation) {
            .literal => |value| {
                const primal = try self.addNode(function, block, .{ .literal = value }, node);
                const joined = try self.joinedCallableTangent(function, block, node);
                const tangent = joined orelse try self.addNil(function, block, node.source);
                try self.setMapped(node.result, .{ .primal = primal, .tangent = tangent, .active = false });
            },
            .quote => |value| {
                const primal = try self.addNode(function, block, .{ .quote = value }, node);
                const joined = try self.joinedCallableTangent(function, block, node);
                const tangent = joined orelse try self.addNil(function, block, node.source);
                try self.setMapped(node.result, .{ .primal = primal, .tangent = tangent, .active = false });
            },
            .local_read => |binding| {
                const pair = try self.lookupBindingPair(source_function, binding);
                const mapped_binding = try self.mappedBinding(binding);
                const primal = try self.addNode(
                    function,
                    block,
                    .{ .local_read = mapped_binding },
                    node,
                );
                const joined = try self.joinedCallableTangent(function, block, node);
                const tangent = joined orelse try self.addNode(
                    function,
                    block,
                    .{ .local_read = try self.mappedTangentBinding(binding) },
                    node,
                );
                if (self.lookupCallable(pair.tangent)) |info| try self.recordCallable(tangent, info.function);
                try self.setMapped(node.result, .{ .primal = primal, .tangent = tangent, .active = pair.active });
            },
            .global_read => |global| {
                const index = @intFromEnum(global);
                if (index >= self.globals.len) return error.InvalidCode;
                const primal = try self.addNode(function, block, .{ .global_read = self.globals[index] }, node);
                if (self.tangent_globals[index] == .invalid) {
                    const joined = try self.joinedCallableTangent(function, block, node);
                    const tangent = joined orelse try self.addNil(function, block, node.source);
                    try self.setMapped(node.result, .{ .primal = primal, .tangent = tangent, .active = false });
                } else {
                    const tangent = try self.addNode(
                        function,
                        block,
                        .{ .global_read = self.tangent_globals[index] },
                        node,
                    );
                    if (try self.immutableCellCallable(global)) |target| try self.recordCallable(tangent, target);
                    try self.setMapped(node.result, .{ .primal = primal, .tangent = tangent, .active = true });
                }
            },
            .global_write => |write| {
                if (write.assign_existing) return error.Unsupported;
                const index = @intFromEnum(write.cell);
                if (index >= self.globals.len) return error.InvalidCode;
                const cell = self.source.globals[index];
                if (cell.binding == .invalid or self.tangent_globals[index] == .invalid) return error.Unsupported;
                if (self.source.bindings[@intFromEnum(cell.binding)].function != source_function) {
                    return error.Unsupported;
                }
                const pair = try self.mapped(write.value);
                _ = try self.addNode(function, block, .{ .global_write = .{
                    .cell = self.globals[index],
                    .value = pair.primal,
                } }, node);
                _ = try self.addNode(function, block, .{ .global_write = .{
                    .cell = self.tangent_globals[index],
                    .value = pair.tangent,
                } }, node);
            },
            .primitive_call => |call| {
                if (call.result_count != 1) return error.Unsupported;
                const source_args = try self.sourceOperands(call.args);
                var active = false;
                for (source_args) |source_arg| active = active or (try self.mapped(source_arg)).active;
                if (active) {
                    if (try self.emitCustomJvp(function, block, call.primitive, source_args, node.source)) |pair| {
                        return self.setMapped(node.result, pair);
                    }
                    if (try self.emitTensorJvp(function, block, call.primitive, source_args, node.source)) |pair| {
                        return self.setMapped(node.result, pair);
                    }
                }
                var primal_args = std.ArrayList(Code.ValueId).empty;
                defer primal_args.deinit(self.scratch);
                for (source_args) |source_arg| {
                    const pair = try self.mapped(source_arg);
                    try primal_args.append(self.scratch, pair.primal);
                }
                const primal = try self.addNode(function, block, .{ .primitive_call = .{
                    .primitive = call.primitive,
                    .args = try self.builder.addOperands(primal_args.items),
                    .result_count = 1,
                } }, node);
                const tangent = if (active)
                    try self.emitPrimitiveTangent(function, block, call.primitive, source_args, node.source)
                else
                    try self.addNil(function, block, node.source);
                try self.setMapped(node.result, .{ .primal = primal, .tangent = tangent, .active = active });
            },
            .arithmetic => |arith| {
                if (arith.callee != .invalid and arith.expected_callee.isNil()) return error.InvalidCode;
                const left = try self.mapped(arith.left);
                const right = try self.mapped(arith.right);
                const active = left.active or right.active;
                const callee = if (arith.callee == .invalid) Pair{} else try self.mapped(arith.callee);
                if (active and arith.callee != .invalid) {
                    const resolved = try self.staticCallable(arith.callee);
                    const matches_expected = if (resolved) |target|
                        target.typ == arith.expected_callee.typ and target.obj == arith.expected_callee.obj
                    else
                        false;
                    if (!matches_expected) {
                        if (resolved) |target| {
                            if (try self.staticPrimitive(target)) |primitive| {
                                if (try self.emitCustomJvp(
                                    function,
                                    block,
                                    primitive,
                                    &.{ arith.left, arith.right },
                                    node.source,
                                )) |pair| {
                                    return self.setMapped(node.result, pair);
                                }
                                if (try self.emitTensorJvp(
                                    function,
                                    block,
                                    primitive,
                                    &.{ arith.left, arith.right },
                                    node.source,
                                )) |pair| {
                                    return self.setMapped(node.result, pair);
                                }
                                const primal = try self.addNode(function, block, .{ .dynamic_call = .{
                                    .callee = callee.primal,
                                    .args = try self.addMappedArgs(
                                        function,
                                        block,
                                        &.{ arith.left, arith.right },
                                        false,
                                        node.source,
                                    ),
                                } }, node);
                                const tangent = try self.emitPrimitiveTangent(
                                    function,
                                    block,
                                    primitive,
                                    &.{ arith.left, arith.right },
                                    node.source,
                                );
                                return self.setMapped(node.result, .{
                                    .primal = primal,
                                    .tangent = tangent,
                                    .active = true,
                                });
                            }
                            if (target.typ == b.type_closure and target.obj != .null) {
                                const pair = try self.emitResolvedHelperPair(
                                    function,
                                    block,
                                    node,
                                    target,
                                    &.{ arith.left, arith.right },
                                );
                                return self.setMapped(node.result, pair);
                            }
                        }
                        if (self.lookupCallable(callee.tangent)) |info| {
                            const target = try sourceFunction(self.source, info.function);
                            if (target.parameter_count != 2) return error.ArityMismatch;
                            const result = try self.addNode(function, block, .{ .dynamic_call = .{
                                .callee = callee.tangent,
                                .args = try self.addJvpArguments(&.{ arith.left, arith.right }),
                                .result_count = std.math.mul(u8, target.result_count, 2) catch return error.Unsupported,
                            } }, node);
                            return self.setMapped(node.result, .{
                                .primal = result,
                                .tangent = @enumFromInt(@intFromEnum(result) + 1),
                                .active = true,
                            });
                        }
                        return error.Unsupported;
                    }
                }
                const primal = try self.addNode(function, block, .{ .arithmetic = .{
                    .op = arith.op,
                    .left = left.primal,
                    .right = right.primal,
                    .callee = callee.primal,
                    .expected_callee = arith.expected_callee,
                    .left_types = arith.left_types,
                    .right_types = arith.right_types,
                } }, node);
                const tangent = if (!active)
                    try self.addNil(function, block, node.source)
                else switch (arith.op) {
                    .add => try self.emitBinaryRule(function, block, .add, left, right, node.source),
                    .sub => try self.emitBinaryRule(function, block, .sub, left, right, node.source),
                    .mul => try self.emitBinaryRule(function, block, .mul, left, right, node.source),
                    .div => try self.emitBinaryRule(function, block, .div, left, right, node.source),
                    .equal, .less, .greater => try self.addNil(function, block, node.source),
                };
                try self.setMapped(node.result, .{ .primal = primal, .tangent = tangent, .active = active });
            },
            .dynamic_call => |call| {
                try self.transformDynamicCall(function, block, node, call, null);
            },
            .direct_call => |call| {
                if (call.result_count == 0) return error.InvalidCode;
                const target = try sourceFunction(self.source, call.function);
                const source_args = try self.sourceOperands(call.args);
                var args = std.ArrayList(Code.ValueId).empty;
                defer args.deinit(self.scratch);
                for (source_args) |source_arg| {
                    try args.append(self.scratch, (try self.mapped(source_arg)).primal);
                }
                for (source_args) |source_arg| {
                    try args.append(self.scratch, (try self.mapped(source_arg)).tangent);
                }
                const transformed_count = std.math.mul(u16, target.result_count, 2) catch return error.Unsupported;
                const result = try self.addNode(function, block, .{ .direct_call = .{
                    .function = self.functions[@intFromEnum(call.function)].jvp,
                    .args = try self.builder.addOperands(args.items),
                    .result_count = @intCast(transformed_count),
                } }, node);
                var result_index: u8 = 0;
                while (result_index < call.result_count) : (result_index += 1) {
                    const source_value: Code.ValueId =
                        @enumFromInt(@intFromEnum(node.result) + result_index);
                    const pair: Pair = .{
                        .primal = @as(Code.ValueId, @enumFromInt(@intFromEnum(result) + result_index * 2)),
                        .tangent = @as(Code.ValueId, @enumFromInt(@intFromEnum(result) + result_index * 2 + 1)),
                        .active = true,
                    };
                    try self.setMapped(source_value, pair);
                }
            },
            .make_closure => |closure| {
                const target_index = @intFromEnum(closure.function);
                if (target_index >= self.functions.len) return error.InvalidCode;
                const target = self.functions[target_index];
                const source_captures = try self.sourceOperands(closure.captures);
                var captures = std.ArrayList(Code.ValueId).empty;
                defer captures.deinit(self.scratch);
                for (source_captures) |source_capture| {
                    const pair = try self.mapped(source_capture);
                    try captures.append(self.scratch, pair.primal);
                    try captures.append(self.scratch, pair.tangent);
                }
                const range = try self.builder.addOperands(captures.items);
                const primal = try self.addNode(function, block, .{ .make_closure = .{
                    .function = target.plain,
                    .captures = try self.addMappedArgs(function, block, source_captures, false, node.source),
                } }, node);
                const tangent = try self.addNode(function, block, .{ .make_closure = .{
                    .function = target.jvp,
                    .captures = range,
                } }, node);
                try self.recordCallable(tangent, closure.function);
                try self.setMapped(node.result, .{ .primal = primal, .tangent = tangent, .active = true });
            },
            .try_begin => |handler| {
                const index = @intFromEnum(handler);
                if (index >= self.handlers.len) return error.InvalidCode;
                _ = try self.addNode(function, block, .{ .try_begin = self.handlers[index] }, node);
            },
            .try_end => {
                _ = try self.addNode(function, block, .try_end, node);
            },
            .ns_push => |count| {
                const primal = try self.addNode(function, block, .{
                    .ns_push = std.math.mul(u16, count, 2) catch return error.Unsupported,
                }, node);
                try self.setMapped(node.result, try self.emitPairNil(function, block, primal, node.source));
            },
            .ns_pop => {
                _ = try self.addNode(function, block, .ns_pop, node);
            },
        }
    }

    fn transformFunction(self: *Transform, source_function: Code.FunctionId) Error!void {
        const source_info = try sourceFunction(self.source, source_function);
        const generated = self.functions[@intFromEnum(source_function)].jvp;
        const block_start: usize = source_info.block_start;
        const block_end = std.math.add(usize, block_start, source_info.block_count) catch return error.InvalidCode;
        if (block_end > self.source.function_blocks.len) return error.InvalidCode;

        const param_start: usize = source_info.parameter_start;
        const param_end = std.math.add(usize, param_start, source_info.parameter_count) catch return error.InvalidCode;
        if (param_end > self.source.parameters.len) return error.InvalidCode;
        for (self.source.parameters[param_start..param_end]) |binding| {
            const pair = try self.lookupBindingPair(source_function, binding);
            try self.setBindingPair(binding, pair);
        }

        for (self.source.function_blocks[block_start..block_end]) |source_block_id| {
            const source_block = self.source.blocks[@intFromEnum(source_block_id)];
            const block = self.blocks[@intFromEnum(source_block_id)];
            const node_start: usize = source_block.node_start;
            const node_end = std.math.add(usize, node_start, source_block.node_count) catch return error.InvalidCode;
            if (node_end > self.source.block_nodes.len) return error.InvalidCode;
            for (self.source.block_nodes[node_start..node_end]) |node_id| {
                const node_index = @intFromEnum(node_id);
                if (node_index >= self.source.nodes.len) return error.InvalidCode;
                try self.transformNode(source_function, generated, block, self.source.nodes[node_index]);
            }
            try self.transformTerminator(generated, block, source_block.terminator);
        }
    }

    fn transformTailCallAsReturn(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        call: Code.TailCall,
    ) Error!void {
        const results = try self.scratch.alloc(Pair, call.result_count);
        defer self.scratch.free(results);
        @memset(results, .{});
        const source_info = try sourceFunction(self.source, self.source_function);
        const dynamic: Code.Call = .{
            .callee = call.callee,
            .args = call.args,
            .result_count = call.result_count,
            .self_target = call.self_target,
        };
        const node: Code.Node = .{
            .id = .invalid,
            .function = self.source_function,
            .block = block,
            .operation = .{ .dynamic_call = dynamic },
            .source = source_info.source,
        };
        try self.transformDynamicCall(function, block, node, dynamic, results);
        var return_values: std.ArrayList(Code.ValueId) = .empty;
        defer return_values.deinit(self.scratch);
        try return_values.ensureTotalCapacity(self.scratch, results.len * 2);
        for (results) |pair| {
            if (pair.primal == .invalid or pair.tangent == .invalid) return error.InvalidCode;
            return_values.appendAssumeCapacity(pair.primal);
            return_values.appendAssumeCapacity(pair.tangent);
        }
        if (return_values.items.len != self.builder.functions.items[@intFromEnum(function)].result_count) {
            return error.InvalidCode;
        }
        try self.builder.setTerminator(block, .{
            .return_values = try self.builder.addOperands(return_values.items),
        });
    }

    fn transformTailCall(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        call: Code.TailCall,
    ) Error!void {
        if (call.result_count == 0) return error.InvalidCode;
        const arguments = try self.sourceOperands(call.args);
        const callee = try self.mapped(call.callee);
        const resolved = try self.staticCallable(call.callee);
        var generated_callee: Code.ValueId = .invalid;
        var generated_self_target: Code.FunctionId = .invalid;
        // SAFETY: target_info is assigned in every branch before have_target is set.
        var target_info: *const Code.Function = undefined;
        var have_target = false;

        if (call.self_target != .invalid) {
            const target_index = @intFromEnum(call.self_target);
            if (target_index >= self.functions.len) return error.InvalidCode;
            if (resolved) |target_value| {
                if (self.isCurrentSourceFunction(target_value, call.self_target)) {
                    const helper = target_value.obj.toRef().deref(Closure);
                    target_info = try sourceFunction(self.source, call.self_target);
                    if (target_info.parameter_count != arguments.len or target_info.result_count != call.result_count) {
                        return error.ArityMismatch;
                    }
                    generated_callee = try self.addSourceGeneratedClosure(
                        function,
                        block,
                        helper,
                        target_info.source,
                    );
                    if (self.functions[target_index].jvp == function) generated_self_target = function;
                    have_target = true;
                }
            }
        }
        if (!have_target) {
            if (self.lookupCallable(callee.tangent)) |info| {
                target_info = try sourceFunction(self.source, info.function);
                if (target_info.parameter_count != arguments.len or target_info.result_count != call.result_count) {
                    return error.ArityMismatch;
                }
                generated_callee = callee.tangent;
                have_target = true;
            }
        }
        if (!have_target) {
            if (resolved) |target_value| {
                if (target_value.typ == b.type_closure and target_value.obj != .null) {
                    const helper = target_value.obj.toRef().deref(Closure);
                    const helper_code = helper.code orelse return error.Unsupported;
                    target_info = try sourceFunction(helper_code, helper.function_id);
                    if (target_info.parameter_count != arguments.len or target_info.result_count != call.result_count) {
                        return error.ArityMismatch;
                    }
                    if (helper_code == self.source) {
                        generated_callee = try self.addSourceGeneratedClosure(
                            function,
                            block,
                            helper,
                            target_info.source,
                        );
                    } else {
                        if (self.generation_depth >= max_generation_depth) return error.Unsupported;
                        const generated = try generateAtDepth(
                            self.ctx,
                            target_value,
                            0,
                            .full_jvp,
                            self.generation_depth + 1,
                            self.session,
                        );
                        self.noteGeneratedHigherOrder(target_value);
                        generated_callee = try self.addLiteral(function, block, generated, target_info.source);
                    }
                    have_target = true;
                }
            }
        }
        if (!have_target and try self.isClosureJoin(call.callee, 0)) {
            generated_callee = callee.tangent;
            have_target = true;
        }
        if (!have_target) return self.transformTailCallAsReturn(function, block, call);
        const result_count = std.math.mul(u8, call.result_count, 2) catch return error.Unsupported;
        if (result_count != self.builder.functions.items[@intFromEnum(function)].result_count) {
            return error.InvalidCode;
        }
        try self.builder.setTerminator(block, .{ .tail_call = .{
            .callee = generated_callee,
            .args = try self.addJvpArguments(arguments),
            .result_count = result_count,
            .self_target = generated_self_target,
        } });
    }

    fn transformTerminator(
        self: *Transform,
        function: Code.FunctionId,
        block: Code.BlockId,
        term: Code.Terminator,
    ) Error!void {
        switch (term) {
            .none => return error.InvalidCode,
            .jump => |edge| try self.builder.setTerminator(block, .{ .jump = .{
                .target = self.blocks[@intFromEnum(edge.target)],
                .args = try self.addEdgeArgs(edge),
            } }),
            .branch => |branch| {
                const condition = try self.mapped(branch.condition);
                try self.builder.setTerminator(block, .{ .branch = .{
                    .condition = condition.primal,
                    .then_edge = .{
                        .target = self.blocks[@intFromEnum(branch.then_edge.target)],
                        .args = try self.addEdgeArgs(branch.then_edge),
                    },
                    .else_edge = .{
                        .target = self.blocks[@intFromEnum(branch.else_edge.target)],
                        .args = try self.addEdgeArgs(branch.else_edge),
                    },
                } });
            },
            .return_values => |values| {
                const source_values = try self.sourceOperands(values);
                if (source_values.len == 0) return error.InvalidCode;
                var result_values = std.ArrayList(Code.ValueId).empty;
                defer result_values.deinit(self.scratch);
                for (source_values) |source_value| {
                    const pair = try self.mapped(source_value);
                    try result_values.append(self.scratch, pair.primal);
                    try result_values.append(self.scratch, try self.materialize(function, block, pair, .{}));
                }
                try self.builder.setTerminator(block, .{
                    .return_values = try self.builder.addOperands(result_values.items),
                });
            },
            .raise => |value| {
                try self.builder.setTerminator(block, .{ .raise = (try self.mapped(value)).primal });
            },
            .tail_call => |call| {
                try self.transformTailCall(function, block, call);
            },
        }
    }
};

fn makeTangentSymbol(runtime: *Runtime, function: usize, binding: usize) Error!Sym {
    var buffer: [96]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "$__skript_ad_tangent_{d}_{d}", .{ function, binding }) catch
        return error.Unsupported;
    return runtime.store.getsym(text);
}

fn makeSeedSymbol(runtime: *Runtime, function: usize, parameter: usize) Error!Sym {
    var buffer: [96]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "$__skript_ad_seed_{d}_{d}", .{ function, parameter }) catch
        return error.Unsupported;
    return runtime.store.getsym(text);
}

fn cloneFunctions(transform: *Transform) Error!void {
    const source_blocks = transform.source.function_blocks;
    try clone.append(transform.scratch, &transform.builder, transform.source);
    for (transform.source.functions, 0..) |source_function, source_index| {
        transform.functions[source_index].plain = source_function.id;
        if (!transform.differentiated[source_index]) continue;
        const jvp = try transform.builder.addFunction(source_function.name, source_function.source);
        transform.functions[source_index].jvp = jvp;
        const output = &transform.builder.functions.items[@intFromEnum(jvp)];
        output.has_rest = false;
        output.result_count = std.math.mul(u8, source_function.result_count, 2) catch return error.Unsupported;
        output.ad_level = std.math.add(u16, source_function.ad_level, 1) catch return error.Unsupported;
        output.origin = .{ .code = transform.source, .function = source_function.id };
        output.source_value = source_function.source_value;
        output.arglist = source_function.arglist;
        output.body = source_function.body;
        for (source_blocks[source_function.block_start..][0..source_function.block_count]) |source_block| {
            transform.blocks[@intFromEnum(source_block)] = try transform.builder.addBlock(jvp);
        }
    }
}

fn cloneGlobals(transform: *Transform) Error!void {
    for (transform.source.globals, 0..) |global, index| {
        transform.globals[index] = if (global.binding == .invalid)
            try transform.builder.addGlobal(global.name, global.source)
        else
            try transform.builder.addLocalCell(try transform.mappedBinding(global.binding), global.source);
        if (global.binding != .invalid) {
            const binding = transform.source.bindings[@intFromEnum(global.binding)];
            if (transform.differentiated[@intFromEnum(binding.function)]) {
                transform.tangent_globals[index] = try transform.builder.addLocalCell(
                    try transform.mappedTangentBinding(global.binding),
                    global.source,
                );
            }
        }
    }
}

fn cloneBindings(transform: *Transform) Error!void {
    const source_bindings = transform.source.function_bindings;
    for (transform.source.bindings) |binding| transform.bindings[@intFromEnum(binding.id)] = binding.id;
    for (transform.source.functions, 0..) |source_function, function_index| {
        if (!transform.differentiated[function_index]) continue;
        const generated = transform.functions[function_index].jvp;
        for (source_bindings[source_function.binding_start..][0..source_function.binding_count]) |binding_id| {
            const binding = transform.source.bindings[@intFromEnum(binding_id)];
            transform.bindings[@intFromEnum(binding_id)] = try transform.builder.addBinding(
                generated,
                binding.name,
                binding.kind,
                binding.source,
            );
            const tangent_name = try makeTangentSymbol(transform.runtime, function_index, @intFromEnum(binding_id));
            transform.tangent_bindings[@intFromEnum(binding_id)] = try transform.builder.addBinding(
                generated,
                tangent_name,
                .let,
                binding.source,
            );
        }
        const parameter_values = transform.source.parameters[source_function.parameter_start..];
        const parameters = parameter_values[0..source_function.parameter_count];
        for (parameters) |binding_id| {
            const mapped = transform.bindings[@intFromEnum(binding_id)];
            const value = try transform.builder.addValue(generated);
            transform.builder.bindings.items[@intFromEnum(mapped)].value = value;
            try transform.builder.addParameter(generated, mapped);
        }
        for (parameters) |binding_id| {
            const index = @intFromEnum(binding_id);
            const tangent = transform.tangent_bindings[index];
            const seed = try transform.builder.addValue(generated);
            try transform.builder.addParameter(generated, tangent);
            const primal = transform.builder.bindings.items[@intFromEnum(transform.bindings[index])].value;
            const pair: Pair = .{ .primal = primal, .tangent = seed, .active = true };
            try transform.setBindingPair(binding_id, pair);
            try transform.setMapped(transform.source.bindings[index].value, pair);
        }
    }
    for (transform.source.functions, 0..) |function, function_index| {
        if (!transform.differentiated[function_index]) continue;
        for (transform.source.captures[function.capture_start..][0..function.capture_count]) |binding| {
            try makeEnvironmentTangent(transform, binding);
        }
    }
}

fn makeEnvironmentTangent(transform: *Transform, binding_id: Code.BindingId) Error!void {
    const index = @intFromEnum(binding_id);
    if (transform.tangent_bindings[index] != .invalid) return;
    const binding = transform.source.bindings[index];
    const owner = try sourceFunction(transform.source, binding.function);
    const block = transform.source.function_blocks[owner.block_start];
    const name = try makeTangentSymbol(transform.runtime, @intFromEnum(owner.id), index);
    const tangent = try transform.builder.addBinding(owner.id, name, .let, binding.source);
    transform.builder.bindings.items[@intFromEnum(tangent)].value = try transform.addNil(
        owner.id,
        block,
        binding.source,
    );
    transform.tangent_bindings[index] = tangent;
}

fn cloneCaptures(transform: *Transform) Error!void {
    for (transform.source.functions, 0..) |source_function, function_index| {
        if (!transform.differentiated[function_index]) continue;
        const generated = transform.functions[function_index].jvp;
        const start: usize = source_function.capture_start;
        const end = std.math.add(usize, start, source_function.capture_count) catch return error.InvalidCode;
        if (end > transform.source.captures.len) return error.InvalidCode;
        for (start..end) |capture_index| {
            const source_binding = transform.source.captures[capture_index];
            const mapped_binding = try transform.mappedBinding(source_binding);
            const primal = try transform.builder.addCapture(generated, mapped_binding);
            const tangent_binding = try transform.mappedTangentBinding(source_binding);
            const tangent = try transform.builder.addCapture(generated, tangent_binding);
            transform.captures[capture_index] = .{
                .primal = primal,
                .tangent = tangent,
                .active = source_function.id != transform.source_function,
            };
            if (capture_index >= transform.source.capture_values.len) return error.InvalidCode;
            const source_value = transform.source.capture_values[capture_index];
            try transform.setMapped(source_value, transform.captures[capture_index]);
        }
    }
}

fn cloneBlockParameters(transform: *Transform) Error!void {
    for (transform.source.blocks, 0..) |source_block, source_index| {
        if (!transform.differentiated[@intFromEnum(source_block.function)]) continue;
        const generated = transform.blocks[source_index];
        const generated_function = transform.functions[@intFromEnum(source_block.function)].jvp;
        const start: usize = source_block.param_start;
        const end = std.math.add(usize, start, source_block.param_count) catch return error.InvalidCode;
        if (end > transform.source.block_parameters.len) return error.InvalidCode;
        for (transform.source.block_parameters[start..end]) |source_value| {
            const primal = try transform.builder.addBlockParam(generated, generated_function);
            const tangent = try transform.builder.addBlockParam(generated, generated_function);
            transform.values[@intFromEnum(source_value)] = .{ .primal = primal, .tangent = tangent, .active = true };
        }
    }
}

fn cloneHandlers(transform: *Transform) Error!void {
    for (transform.source.handlers, 0..) |handler, index| {
        if (!transform.differentiated[@intFromEnum(handler.function)]) continue;
        const function = transform.functions[@intFromEnum(handler.function)].jvp;
        const exception = try transform.mapped(handler.exception);
        transform.handlers[index] = try transform.builder.addHandler(
            function,
            transform.blocks[@intFromEnum(handler.protected)],
            transform.blocks[@intFromEnum(handler.landing)],
            exception.primal,
        );
    }
}

fn transformAll(transform: *Transform) Error!void {
    for (transform.source.functions, 0..) |_, index| {
        if (!transform.differentiated[index]) continue;
        try transform.transformFunction(@enumFromInt(@as(u32, @intCast(index))));
    }
}
fn addWrapper(
    transform: *Transform,
    source_function_id: Code.FunctionId,
    mode: Mode,
    selected_parameter: u16,
) Error!Code.FunctionId {
    const source_function = try sourceFunction(transform.source, source_function_id);
    const wrapper = try transform.builder.addFunction(source_function.name, source_function.source);
    transform.builder.functions.items[@intFromEnum(wrapper)].result_count = if (mode == .jvp) 2 else 1;
    transform.builder.functions.items[@intFromEnum(wrapper)].ad_level =
        std.math.add(u16, source_function.ad_level, 1) catch return error.Unsupported;
    transform.builder.functions.items[@intFromEnum(wrapper)].origin = .{
        .code = transform.source,
        .function = source_function.id,
    };
    transform.builder.functions.items[@intFromEnum(wrapper)].source_value = source_function.source_value;
    transform.builder.functions.items[@intFromEnum(wrapper)].arglist = source_function.arglist;
    transform.builder.functions.items[@intFromEnum(wrapper)].has_rest = false;
    transform.builder.functions.items[@intFromEnum(wrapper)].body = source_function.body;
    const block = try transform.builder.addBlock(wrapper);
    const capture_start: usize = source_function.capture_start;
    const capture_end = std.math.add(
        usize,
        capture_start,
        source_function.capture_count,
    ) catch return error.InvalidCode;
    if (capture_end > transform.source.captures.len) return error.InvalidCode;
    var closure_captures = std.ArrayList(Code.ValueId).empty;
    defer closure_captures.deinit(transform.scratch);
    for (capture_start..capture_end) |capture_index| {
        const source_binding = transform.source.captures[capture_index];
        const primal = try transform.builder.addCapture(wrapper, try transform.mappedBinding(source_binding));
        const tangent = try transform.builder.addCapture(wrapper, try transform.mappedTangentBinding(source_binding));
        try closure_captures.append(transform.scratch, primal);
        try closure_captures.append(transform.scratch, tangent);
    }

    const parameter_start: usize = source_function.parameter_start;
    const parameter_end = std.math.add(
        usize,
        parameter_start,
        source_function.parameter_count,
    ) catch return error.InvalidCode;
    if (parameter_end > transform.source.parameters.len) return error.InvalidCode;
    var parameters = std.ArrayList(Code.ValueId).empty;
    defer parameters.deinit(transform.scratch);
    for (transform.source.parameters[parameter_start..parameter_end]) |source_binding| {
        const binding = transform.source.bindings[@intFromEnum(source_binding)];
        const generated = try transform.builder.addBinding(wrapper, binding.name, .parameter, binding.source);
        const value = try transform.builder.addValue(wrapper);
        transform.builder.bindings.items[@intFromEnum(generated)].value = value;
        try transform.builder.addParameter(wrapper, generated);
        try parameters.append(transform.scratch, value);
    }
    var public_seed: Code.ValueId = .invalid;
    if (mode == .jvp) {
        const seed_name = try makeSeedSymbol(transform.runtime, @intFromEnum(source_function_id), selected_parameter);
        const seed_binding = try transform.builder.addBinding(wrapper, seed_name, .parameter, source_function.source);
        public_seed = try transform.builder.addValue(wrapper);
        transform.builder.bindings.items[@intFromEnum(seed_binding)].value = public_seed;
        try transform.builder.addParameter(wrapper, seed_binding);
    }

    const closure = try transform.addGeneratedNode(wrapper, block, .{ .make_closure = .{
        .function = transform.functions[@intFromEnum(source_function_id)].jvp,
        .captures = try transform.builder.addOperands(closure_captures.items),
    } }, source_function.source);
    var call_args = std.ArrayList(Code.ValueId).empty;
    defer call_args.deinit(transform.scratch);
    try call_args.appendSlice(transform.scratch, parameters.items);
    for (parameters.items, 0..) |parameter_value, index| {
        if (index == selected_parameter) {
            try call_args.append(transform.scratch, if (mode == .jvp)
                public_seed
            else
                try transform.scalarOne(wrapper, block, parameter_value, source_function.source));
        } else {
            try call_args.append(transform.scratch, try transform.addNil(wrapper, block, source_function.source));
        }
    }
    const result = try transform.addGeneratedNode(wrapper, block, .{ .dynamic_call = .{
        .callee = closure,
        .args = try transform.builder.addOperands(call_args.items),
        .result_count = 2,
    } }, source_function.source);
    const tangent = try transform.scalarCall(wrapper, block, .realize_tangent, &.{
        result, @enumFromInt(@intFromEnum(result) + 1),
    }, source_function.source);
    if (mode == .derivative) {
        try transform.builder.setTerminator(block, .{
            .return_values = try transform.builder.addOperands(&.{tangent}),
        });
    } else {
        try transform.builder.setTerminator(block, .{
            .return_values = try transform.builder.addOperands(&.{ result, tangent }),
        });
    }
    return wrapper;
}

fn makeGuard(
    ctx: *EvalContext,
    source: *const Closure,
    code: *const Code.Code,
    rule_version: *const rules.RegistryVersion,
    reads: []const Effects.Read,
    argument_count: usize,
) Error!*const ClosureGuard {
    const source_code = source.code orelse return error.Unsupported;
    const inherited_lifecycle = if (source.guard) |parent| blk: {
        try validateGuardLifecycle(parent);
        break :blk parent.acquire != null;
    } else false;
    const inherited_argument_count = blk: {
        const source_function = source_code.function(source.function_id) orelse return error.InvalidCode;
        break :blk source_function.parameter_count;
    };
    const expected = try ctx.runtime.static.dupe(Value, source.captures);
    const retained_reads = try ctx.runtime.static.dupe(Effects.Read, reads);
    const context = try ctx.runtime.static.create(DependencyGuard);
    context.* = .{
        .runtime = ctx.runtime,
        .registry = ctx.registry,
        .rules_version = rule_version,
        .code = code,
        .source_code = source_code,
        .source = source,
        .expected_captures = expected,
        .reads = retained_reads,
        .inherited = source.guard,
        .inherited_argument_count = inherited_argument_count,
        .argument_count = argument_count,
    };
    const guard = try ctx.runtime.static.create(ClosureGuard);
    guard.* = .{
        .context = context,
        .check = &checkGuard,
        .trace = &traceGuard,
        .check_arguments = &checkGuardArguments,
        .acquire = if (inherited_lifecycle) &acquireGuard else null,
        .release = if (inherited_lifecycle) &releaseGuard else null,
    };
    return guard;
}

fn materializeClosure(
    runtime: *Runtime,
    source: *const Closure,
    code: *const Code.Code,
    program: Runtime.RegProgram,
    function: Code.FunctionId,
    guard: *const skript.data.ClosureGuard,
    placeholder: Value,
) Error!Value {
    const index = @intFromEnum(function);
    if (index >= program.fns.len) return error.InvalidCode;
    const lowered = program.fns[index];
    if (placeholder.typ != b.type_closure or placeholder.obj == .null) return error.InvalidCode;
    const ref = placeholder.obj.toRef();
    const arg_alloc = try runtime.store.allocSlice(Sym, lowered.arglist.len);
    @memcpy(arg_alloc.slice, lowered.arglist);
    const captures = try runtime.store.allocSlice(Value, lowered.capture_syms.len);
    @memset(captures.slice, .nil);
    const original_count = source.captures.len;
    if (lowered.capture_syms.len != original_count * 2) return error.InvalidCode;
    for (source.captures, 0..) |capture, index_capture| {
        captures.slice[index_capture * 2] = capture;
        captures.slice[index_capture * 2 + 1] = .nil;
    }
    runtime.store.store(Closure, ref.deref(Closure), .{
        .parent_ns = source.parent_ns,
        .arglist = arg_alloc.slice,
        .source = source.source,
        .source_ref = source.source_ref,
        .ir = lowered.ir,
        .constants = lowered.constants,
        .nregs = lowered.nregs,
        .result_count = lowered.result_count,
        .zero_mask = lowered.zero_mask,
        .capture_syms = lowered.capture_syms,
        .captures = captures.slice,
        .guard = guard,
        .code = code,
        .function_id = function,
        .environment_id = source.environment_id,
        .fns = program.fns,
    });
    return Value.closure(ref.toObject());
}

fn generateAtDepth(
    ctx: *EvalContext,
    source: Value,
    parameter: u16,
    mode: Mode,
    generation_depth: u16,
    session: *GenerationSession,
) Error!Value {
    const scope = ctx.activate();
    defer scope.deinit();
    try ctx.check();
    if (source.typ != b.type_closure or source.obj == .null) return error.TypeMismatch;
    const source_closure = source.obj.toRef().deref(Closure);
    const source_guard = source_closure.guard;
    var source_guard_lease: ?*const ClosureGuard = null;
    if (source_guard) |guard| {
        try validateGuardLifecycle(guard);
        if (guard.acquire) |acquire| {
            try acquire(ctx.runtime, guard.context);
            source_guard_lease = guard;
        }
    }
    defer if (source_guard_lease) |guard| {
        if (guard.release) |release| release(ctx.runtime, guard.context);
    };
    if (source_guard) |guard| try guard.check(ctx.runtime, guard.context);
    const source_code = source_closure.code orelse return error.Unsupported;
    _ = try sourceFunction(source_code, source_closure.function_id);
    if (ctx.registry != ctx.runtime.intrinsics.registryVersion()) return error.Denied;
    const generation_key: GenerationKey = .{
        .closure = source_closure,
        .mode = mode,
        .parameter = parameter,
    };
    if (session.get(generation_key)) |existing| return existing;
    const reservation = try session.reserve(ctx.runtime, generation_key);
    var generation_complete = false;
    defer if (!generation_complete) {
        const removed = session.entries.remove(generation_key);
        std.debug.assert(removed);
    };

    const reads = try Effects.collectReads(ctx.runtime, source_closure.parent_ns, source, ctx.scratch);
    defer ctx.scratch.free(reads);
    const rule_version = try rules.builtinSnapshot(ctx);
    const scalar_primitive = ctx.registry.idForNative(&rules.scalarDispatch) orelse return error.Unsupported;
    if (rule_version.find(scalar_primitive) == null) return error.Unsupported;

    var arena = std.heap.ArenaAllocator.init(ctx.scratch);
    defer arena.deinit();
    const scratch = arena.allocator();
    const identity = try ctx.runtime.allocCodeIdentity();
    var builder = Code.Builder.init(ctx.runtime.static, ctx);
    builder.id = identity.id;
    builder.revision = identity.revision;
    var transform = try Transform.init(
        scratch,
        ctx,
        source_code,
        source_closure,
        rule_version,
        builder,
        source_closure.function_id,
        scalar_primitive,
        generation_depth,
        session,
    );
    defer transform.deinit();
    try transform.extra_reads.appendSlice(scratch, reads);
    try cloneFunctions(&transform);
    try cloneBindings(&transform);
    try cloneGlobals(&transform);
    try cloneCaptures(&transform);
    try cloneBlockParameters(&transform);
    try cloneHandlers(&transform);
    try transformAll(&transform);
    for (transform.source.bindings) |binding| {
        if (!transform.differentiated[@intFromEnum(binding.function)] or binding.value == .invalid) continue;
        try transform.setBindingPair(binding.id, try transform.mapped(binding.value));
    }
    const source_function = try sourceFunction(source_code, source_closure.function_id);

    const public_function = if (mode == .full_jvp)
        transform.functions[@intFromEnum(source_closure.function_id)].jvp
    else
        try addWrapper(&transform, source_closure.function_id, mode, parameter);
    for (transform.functions) |pair| {
        if (pair.jvp == .invalid) continue;
        const nested_generated = &transform.builder.functions.items[@intFromEnum(pair.jvp)];
        nested_generated.allows_ad = transform.higher_order;
        nested_generated.ad_level = std.math.add(u16, source_function.ad_level, 1) catch return error.Unsupported;
    }
    transform.builder.functions.items[@intFromEnum(public_function)].ad_level =
        std.math.add(u16, source_function.ad_level, 1) catch return error.Unsupported;
    transform.builder.functions.items[@intFromEnum(public_function)].allows_ad = transform.higher_order;
    const code = try transform.builder.finish(ctx.scratch);
    code.owner = ctx.runtime;
    const program = try ctx.runtime.lowerCode(ctx.scratch, code);
    const public_argument_count = switch (mode) {
        .derivative => @as(usize, source_function.parameter_count),
        .jvp => @as(usize, source_function.parameter_count) + 1,
        .full_jvp => @as(usize, source_function.parameter_count) * 2,
    };
    const guard = try makeGuard(
        ctx,
        source_closure,
        code,
        rule_version,
        transform.extra_reads.items,
        public_argument_count,
    );
    const result = try materializeClosure(
        ctx.runtime,
        source_closure,
        code,
        program,
        public_function,
        guard,
        reservation,
    );
    try session.finish(generation_key, transform.higher_order);
    generation_complete = true;
    return result;
}

pub fn generate(
    ctx: *EvalContext,
    source: Value,
    parameter: u16,
    mode: Mode,
) Error!Value {
    var session = GenerationSession.init(ctx.scratch);
    defer session.deinit();
    return generateAtDepth(ctx, source, parameter, mode, 0, &session);
}
const ForwardGuardProbe = struct {
    open: bool = true,
    users: u32 = 0,
    reclaimed: bool = false,
    require_held_check: bool = false,
    arm_close_on_arguments: bool = false,
    close_on_next_acquire: bool = false,

    fn mutable(state: *const anyopaque) *ForwardGuardProbe {
        return @constCast(@as(*const ForwardGuardProbe, @ptrCast(@alignCast(state))));
    }

    fn check(runtime: *Runtime, state: *const anyopaque) Error!void {
        _ = runtime;
        const probe = mutable(state);
        if (!probe.open) return error.Expired;
        if (probe.require_held_check and probe.users == 0) return error.Denied;
    }

    fn checkArguments(
        runtime: *Runtime,
        state: *const anyopaque,
        arguments: []const Value,
    ) Error!void {
        try check(runtime, state);
        if (arguments.len != 1) return error.ArityMismatch;
        const probe = mutable(state);
        if (probe.arm_close_on_arguments) {
            probe.arm_close_on_arguments = false;
            probe.close_on_next_acquire = true;
        }
    }

    fn acquire(runtime: *Runtime, state: *const anyopaque) Error!void {
        _ = runtime;
        const probe = mutable(state);
        if (!probe.open) return error.Expired;
        probe.users += 1;
        if (probe.close_on_next_acquire) {
            probe.close_on_next_acquire = false;
            probe.open = false;
        }
    }

    fn release(runtime: *Runtime, state: *const anyopaque) void {
        _ = runtime;
        const probe = mutable(state);
        std.debug.assert(probe.users > 0);
        probe.users -= 1;
        if (!probe.open and probe.users == 0) probe.reclaimed = true;
    }

    fn close(self: *ForwardGuardProbe) void {
        self.open = false;
        if (self.users == 0) self.reclaimed = true;
    }

    fn guard(self: *ForwardGuardProbe) skript.data.ClosureGuard {
        return .{
            .context = self,
            .check = &check,
            .trace = null,
            .check_arguments = &checkArguments,
            .acquire = &acquire,
            .release = &release,
        };
    }
};

fn attachForwardGuard(value: Value, guard: *const skript.data.ClosureGuard) void {
    std.debug.assert(value.typ == b.type_closure);
    value.obj.toRef().deref(Closure).guard = guard;
}

test "forward derivative pins guarded parent during generation and checks" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    var probe: ForwardGuardProbe = .{ .require_held_check = true };
    var parent_guard = probe.guard();
    const source = try runtime.evalString("(fn (x) (* x x))");
    attachForwardGuard(source, &parent_guard);

    const derivative = try generate(runtime.context(), source, 0, .derivative);
    try std.testing.expectEqual(
        Value.f64(6.0),
        try runtime.apply(runtime.root_ns, derivative, &.{Value.f64(3.0)}),
    );

    probe.close();
    try std.testing.expectError(
        error.Expired,
        runtime.apply(runtime.root_ns, derivative, &.{Value.f64(3.0)}),
    );
}

test "collection fails closed on an explicitly untraced synthetic guard" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    var probe: ForwardGuardProbe = .{};
    var parent_guard = probe.guard();
    const source = try runtime.evalString("(fn (x) (* x x))");
    attachForwardGuard(source, &parent_guard);
    const derivative = try generate(runtime.context(), source, 0, .derivative);
    var root: Runtime.ValueRoot = .{};
    try runtime.registerValueRoot(&root, derivative);
    defer runtime.unregisterValueRoot(&root) catch unreachable;

    try std.testing.expectError(error.UntracedAllocation, runtime.collect());
}

test "forward full JVP keeps a closing parent leased in flight" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    var probe: ForwardGuardProbe = .{ .arm_close_on_arguments = true };
    var parent_guard = probe.guard();
    const source = try runtime.evalString("(fn (x) (* x x))");
    attachForwardGuard(source, &parent_guard);
    const jvp = try generate(runtime.context(), source, 0, .full_jvp);

    var outputs: [2]Value = undefined;
    try runtime.applyResultsWithContext(
        runtime.context(),
        jvp,
        &.{ Value.f64(3.0), Value.f64(1.0) },
        &outputs,
    );
    try std.testing.expectEqualSlices(Value, &.{ Value.f64(9.0), Value.f64(6.0) }, &outputs);
    try std.testing.expect(!probe.open);
    try std.testing.expect(probe.reclaimed);
    try std.testing.expectEqual(@as(u32, 0), probe.users);
}

test "forward generation rejects malformed parent guard lifecycle" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    var probe: ForwardGuardProbe = .{};
    var parent_guard = probe.guard();
    parent_guard.release = null;
    const source = try runtime.evalString("(fn (x) (* x x))");
    attachForwardGuard(source, &parent_guard);

    try std.testing.expectError(
        error.InvalidCode,
        generate(runtime.context(), source, 0, .derivative),
    );
}

test "forward derivative supports parent guards without lifecycle callbacks" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    var probe: ForwardGuardProbe = .{};
    var parent_guard = probe.guard();
    parent_guard.acquire = null;
    parent_guard.release = null;
    const source = try runtime.evalString("(fn (x) (* x x))");
    attachForwardGuard(source, &parent_guard);

    const derivative = try generate(runtime.context(), source, 0, .derivative);
    try std.testing.expectEqual(
        Value.f64(6.0),
        try runtime.apply(runtime.root_ns, derivative, &.{Value.f64(3.0)}),
    );
}

test "forward derivative generates and applies a bound square" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const source = try rt.evalString("(fn (x) (* x x))");
    const derivative = try generate(rt.context(), source, 0, .derivative);
    const result = try rt.apply(rt.root_ns, derivative, &.{Value.f64(3.0)});
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.obj.tof64(), 1e-6);
}

test "forward derivative composes for a second derivative" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const source = try rt.evalString("(fn (x) (* x x))");
    const first = try generate(rt.context(), source, 0, .derivative);
    const second = try generate(rt.context(), first, 0, .derivative);
    const result = try rt.apply(rt.root_ns, second, &.{Value.f64(3.0)});
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.obj.tof64(), 1e-6);
}

test "forward derivative preserves multiple lexical captures" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const source = try rt.evalString("((fn (a b) (fn (x) (+ (* a x) b))) 2.0 5.0)");
    const derivative = try generate(rt.context(), source, 0, .derivative);
    const result = try rt.apply(rt.root_ns, derivative, &.{Value.f64(3.0)});
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.obj.tof64(), 1e-6);
}

test "forward arithmetic differentiates the current dynamic callee" {
    for ([_][]const u8{ "+", "(fn (a b) (+ a b))" }) |replacement| {
        const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
        defer runtime.deinit();
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "(def bound-op-fn (fn (x) (* x x))) (def * {s}) ((deriv bound-op-fn) 3.0)",
            .{replacement},
        );
        defer std.testing.allocator.free(source);
        const result = try runtime.evalString(source);
        try std.testing.expectEqual(b.type_f64, result.typ);
        try std.testing.expectEqual(@as(f64, 2.0), result.obj.tof64());
    }
}

test "forward propagates opaque helper higher-order boundaries" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const registration = try runtime.evalString(
        \\:{:primitive @f64.neg
        \\  :implementation-revision 1
        \\  :rule-revision 7
        \\  :capabilities (list :jvp)
        \\  :metadata :{:arity 1
        \\              :linearity :linear
        \\              :allocation :none
        \\              :higher-order #f}
        \\  :jvp :{:kind :hook
        \\          :callable (fn (primals tangents)
        \\                      (list (- (fst primals)) (- (fst tangents))))
        \\          :revision 3}}
    );
    _ = try rules.registerRule(runtime.context(), runtime.root_ns, .nil, &.{registration});
    _ = try runtime.evalString(
        "(defn (ad-opaque-helper x) (@f64.neg x)) " ++
            "(defn (ad-safe-helper x) (* x x))",
    );
    const source = try runtime.evalString(
        "(fn (choose x) ((if choose ad-opaque-helper ad-safe-helper) x))",
    );
    const first = try generate(runtime.context(), source, 1, .derivative);
    const first_result = try runtime.apply(
        runtime.root_ns,
        first,
        &.{ Value.bool(true), Value.f64(3.0) },
    );
    try std.testing.expectEqual(Value.f64(-1.0), try first_result.unwrapError());
    try std.testing.expectError(error.Unsupported, generate(runtime.context(), first, 1, .derivative));
}

test "forward helper generation memoizes mutual recursion" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const result = try runtime.evalString(
        "(defn (ad-even n x) (if (= n 0) (* x x) (ad-odd (- n 1) x))) " ++
            "(defn (ad-odd n x) (if (= n 0) (* x x) (ad-even (- n 1) x))) " ++
            "((deriv ad-even 1) 4 3.0)",
    );
    try std.testing.expectEqual(Value.f64(6.0), result);
}

test "forward helper generation memoizes mutual recursion across source units" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    _ = try runtime.evalString(
        "(defn (ad-split-even n x) " ++
            "(if (= n 0) (* x x) (ad-split-odd (- n 1) x)))",
    );
    _ = try runtime.evalString(
        "(defn (ad-split-odd n x) " ++
            "(if (= n 0) (* x x) (ad-split-even (- n 1) x)))",
    );
    const result = try runtime.evalString("((deriv ad-split-even 1) 4 3.0)");
    try std.testing.expectEqual(Value.f64(6.0), result);
}

test "forward tail recursion stays within a finite VM depth budget" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const derivative = try runtime.evalString(
        "(defn (ad-tail-depth n x) " ++
            "(if (= n 0) x (ad-tail-depth (- n 1) x))) " ++
            "(deriv ad-tail-depth 1)",
    );

    const work_limit = 50_000_000;
    var budget = EvalContext.Budget.init(
        runtime.io,
        9_101,
        .{ .work = work_limit, .depth = 4 },
    );
    var lease = try EvalContext.Budget.Lease.root(&budget, work_limit);
    var account = EvalContext.Budget.AccountAllocator.init(
        std.testing.allocator,
        &lease,
        .regvm,
    );
    var output_bytes: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_bytes);
    var context = try EvalContext.limited(
        runtime,
        runtime.intrinsics.registryVersion(),
        &account,
        .{ .writer = &writer, .bounded_memory = true },
        .{ .effects = .{ .state_read = .allow } },
    );
    var outputs: [1]Value = undefined;
    try runtime.applyResultsWithContext(
        &context,
        derivative,
        &.{ Value.i64(4_096), Value.f64(3.0) },
        &outputs,
    );
    try std.testing.expectEqual(Value.f64(1.0), try outputs[0].unwrapError());
    try std.testing.expect(budget.snapshot().depth_peak <= 4);
}

test "forward branch-selected tail recursion preserves constant VM depth" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const derivative = try runtime.evalString(
        "(defn (ad-tail-select-left n x) " ++
            "(if (= n 0) x " ++
            "((if (> n 0) ad-tail-select-right ad-tail-select-left) (- n 1) x))) " ++
            "(defn (ad-tail-select-right n x) " ++
            "(if (= n 0) x " ++
            "((if (> n 0) ad-tail-select-left ad-tail-select-right) (- n 1) x))) " ++
            "(deriv ad-tail-select-left 1)",
    );

    // `>` is a method, so its fixed path is the host VM entry (1), the wrapper
    // and JVP frames (2), the method VM re-entry (1), and the native entry (1).
    // Recursive JVP tail calls replace their frame across all 4,096 iterations.
    const depth_limit = 5;
    const work_limit = 50_000_000;
    var budget = EvalContext.Budget.init(
        runtime.io,
        9_102,
        .{ .work = work_limit, .depth = depth_limit },
    );
    var lease = try EvalContext.Budget.Lease.root(&budget, work_limit);
    var account = EvalContext.Budget.AccountAllocator.init(
        std.testing.allocator,
        &lease,
        .regvm,
    );
    var output_bytes: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_bytes);
    var context = try EvalContext.limited(
        runtime,
        runtime.intrinsics.registryVersion(),
        &account,
        .{ .writer = &writer, .bounded_memory = true },
        .{ .effects = .{ .state_read = .allow } },
    );
    var outputs: [1]Value = undefined;
    try runtime.applyResultsWithContext(
        &context,
        derivative,
        &.{ Value.i64(4_096), Value.f64(3.0) },
        &outputs,
    );
    try std.testing.expectEqual(Value.f64(1.0), try outputs[0].unwrapError());
    try std.testing.expect(budget.snapshot().depth_peak <= depth_limit);
}

test "forward self specialization follows the resolved closure" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const result = try runtime.evalString(
        "(defn (ad-rebound n x) " ++
            "(if (= n 0) (* x x) (ad-rebound (- n 1) x))) " ++
            "(def ad-old ad-rebound) " ++
            "(def ad-rebound (fn (n x) (* 3.0 x))) " ++
            "((deriv ad-old 1) 1 2.0)",
    );
    try std.testing.expectEqual(Value.f64(3.0), result);
}

test "forward tensor structural rules preserve inactivity and higher derivatives" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const second = try runtime.evalString(
        "((deriv (deriv (fn (x) (tensor-get (stack (* x x)) 0)))) 3.0)",
    );
    try std.testing.expectEqual(Value.f64(2.0), second);
    const selected = try runtime.evalString(
        "((deriv (fn (x i) (tensor-get (stack (* x x)) i)) 0) 3.0 0)",
    );
    try std.testing.expectEqual(Value.f64(6.0), selected);
}

test "forward tensor callback kernels preserve bounded higher-order jets" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();

    try std.testing.expectEqual(Value.f64(2.0), try runtime.evalString(
        "((deriv (deriv (fn (x) " ++
            "(tensor-get (map (stack x) (fn (y) (* y y))) 0)))) 3.0)",
    ));
    try std.testing.expectEqual(Value.f64(2.0), try runtime.evalString(
        "((deriv (deriv (fn (x) " ++
            "(tensor-get (map2 (stack x) (stack x) (fn (a b) (* a b))) 0)))) 3.0)",
    ));
    try std.testing.expectEqual(Value.f64(2.0), try runtime.evalString(
        "((deriv (deriv (fn (x) " ++
            "(tensor-get (outer (stack x) (stack x) (fn (a b) (* a b))) 0 0)))) 3.0)",
    ));
    try std.testing.expectEqual(Value.f64(10.0), try runtime.evalString(
        "((deriv (deriv (fn (x) " ++
            "(fold (map (stack x (* 2.0 x)) (fn (y) (* y y))) " ++
            "(fn (a y) (+ a y)))))) 3.0)",
    ));
    try std.testing.expectEqual(Value.f64(2.0), try runtime.evalString(
        "((deriv (deriv (fn (x) " ++
            "(tensor-get (scan (stack x x) (fn (a y) (* a y))) 1)))) 3.0)",
    ));
    try std.testing.expectEqual(Value.f64(6.0), try runtime.evalString(
        "((deriv (deriv (deriv (fn (x) " ++
            "(tensor-get (map (stack x) (fn (y) (* y (* y y)))) 0))))) 3.0)",
    ));
}

test "forward HVP composes through tensor callback kernels" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();

    try std.testing.expectEqual(Value.f64(8.0), try runtime.evalString(
        "(hvp (fn (x) " ++
            "(fold (map (stack x) (fn (y) (* y y))) (fn (a y) (+ a y)))) " ++
            "3.0 4.0)",
    ));
}

test "forward tensor index and shape tangents must be statically zero" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();

    try std.testing.expectError(error.Unsupported, runtime.evalString(
        "((deriv (fn (x i) (tensor-get (stack x) i)) 1) 3.0 0)",
    ));
    try std.testing.expectError(error.Unsupported, runtime.evalString(
        "((deriv (fn (x n) " ++
            "(tensor-get (reshape (stack x x) (stack n)) 0)) 1) 3.0 2)",
    ));
    try std.testing.expectEqual(Value.f64(1.0), try runtime.evalString(
        "(fst (rst (jvp (fn (x i) (tensor-get (stack x) i)) " ++
            "(list 3.0 0) (list 1.0 0))))",
    ));
    try std.testing.expectEqual(Value.f64(1.0), try runtime.evalString(
        "(fst (rst (jvp (fn (x n) " ++
            "(tensor-get (reshape (stack x x) (stack n)) 0)) " ++
            "(list 3.0 2) (list 1.0 0))))",
    ));
}

fn capturedValueInCode(source: *const Code.Code, closure: *const Closure, value: Code.ValueId) ?Value {
    const function = source.function(closure.function_id) orelse return null;
    const start: usize = function.capture_start;
    const count: usize = function.capture_count;
    if (count != closure.captures.len or start > source.captures.len or
        count > source.captures.len - start or start > source.capture_values.len or
        count > source.capture_values.len - start) return null;
    for (
        source.captures[start..][0..count],
        source.capture_values[start..][0..count],
        closure.captures,
    ) |binding, capture, actual| {
        const index = @intFromEnum(binding);
        if (index >= source.bindings.len) return null;
        if (capture == value or source.bindings[index].value == value) return actual;
    }
    return null;
}

fn knownFunctionInCode(
    context: *EvalContext,
    source: *const Code.Code,
    source_closure: *const Closure,
    original: Code.ValueId,
) Error!?Code.FunctionId {
    var value = original;
    var steps: usize = 0;
    while (steps < source.values.len) : (steps += 1) {
        if (value == .invalid) return null;
        if (capturedValueInCode(source, source_closure, value)) |captured| {
            if (captured.typ != b.type_closure or captured.obj == .null) return null;
            const closure = captured.obj.toRef().deref(Closure);
            return if (closure.code == source) closure.function_id else null;
        }
        var next: ?Code.ValueId = null;
        var found = false;
        for (source.nodes) |node| {
            if (node.result != value) continue;
            found = true;
            switch (node.operation) {
                .make_closure => |closure| return closure.function,
                .literal, .quote => |literal| {
                    if (literal.typ != b.type_closure or literal.obj == .null) return null;
                    const closure = literal.obj.toRef().deref(Closure);
                    if (closure.code != source) return null;
                    return closure.function_id;
                },
                .local_read => |binding| {
                    const index = @intFromEnum(binding);
                    if (index >= source.bindings.len) return null;
                    next = source.bindings[index].value;
                },
                .global_read => |global| {
                    const index = @intFromEnum(global);
                    if (index >= source.globals.len) return null;
                    const cell = source.globals[index];
                    if (cell.binding != .invalid) {
                        const binding_index = @intFromEnum(cell.binding);
                        if (binding_index >= source.bindings.len) return null;
                        next = source.bindings[binding_index].value;
                    } else {
                        const current = context.runtime.nsGet(source_closure.parent_ns, cell.name) catch return null;
                        if (current.typ != b.type_closure or current.obj == .null) return null;
                        const closure = current.obj.toRef().deref(Closure);
                        if (closure.code != source) return null;
                        return closure.function_id;
                    }
                },
                else => return null,
            }
            break;
        }
        if (!found) return null;
        value = next orelse return null;
    }
    return null;
}

fn reachableFunctions(
    allocator: Allocator,
    context: *EvalContext,
    source: *const Code.Code,
    source_closure: *const Closure,
    entry: Code.FunctionId,
) Error![]bool {
    const selected = try allocator.alloc(bool, source.functions.len);
    @memset(selected, false);
    const queue = try allocator.alloc(Code.FunctionId, source.functions.len);
    defer allocator.free(queue);
    if (@intFromEnum(entry) >= selected.len) return error.InvalidCode;
    selected[@intFromEnum(entry)] = true;
    queue[0] = entry;
    var length: usize = 1;
    var cursor: usize = 0;
    while (cursor < length) : (cursor += 1) {
        const function = try sourceFunction(source, queue[cursor]);
        for (source.function_blocks[function.block_start..][0..function.block_count]) |block_id| {
            const block = source.blocks[@intFromEnum(block_id)];
            for (source.block_nodes[block.node_start..][0..block.node_count]) |node_id| {
                try context.chargeWork(1, 1, .code);
                const node = source.nodes[@intFromEnum(node_id)];
                const direct_target: Code.FunctionId = switch (node.operation) {
                    .make_closure => |closure| closure.function,
                    .direct_call => |call| call.function,
                    .dynamic_call => |call| call.self_target,
                    else => .invalid,
                };
                try enqueueFunction(selected, queue, &length, direct_target);
                const static_value: Code.ValueId = switch (node.operation) {
                    .dynamic_call => |call| call.callee,
                    .arithmetic => |arith| arith.callee,
                    else => .invalid,
                };
                try enqueueFunction(
                    selected,
                    queue,
                    &length,
                    (try knownFunctionInCode(context, source, source_closure, static_value)) orelse .invalid,
                );
            }
            if (block.terminator == .tail_call) {
                try enqueueFunction(selected, queue, &length, block.terminator.tail_call.self_target);
                const known = try knownFunctionInCode(
                    context,
                    source,
                    source_closure,
                    block.terminator.tail_call.callee,
                );
                try enqueueFunction(selected, queue, &length, known orelse .invalid);
            }
        }
    }
    return selected;
}

fn enqueueFunction(selected: []bool, queue: []Code.FunctionId, length: *usize, function: Code.FunctionId) Error!void {
    if (function == .invalid) return;
    const index = @intFromEnum(function);
    if (index >= selected.len) return error.InvalidCode;
    if (selected[index]) return;
    std.debug.assert(length.* < queue.len);
    selected[index] = true;
    queue[length.*] = function;
    length.* += 1;
}

test "recursive tensor callbacks resolve generation placeholders before execution" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const result = try runtime.evalString(
        "(defn (ad-recursive-map x) " ++
            "(if (< x 1.0) x " ++
            "(tensor-get (map (stack (- x 1.0)) ad-recursive-map) 0))) " ++
            "((deriv ad-recursive-map) 4.0)",
    );
    try std.testing.expectEqual(Value.f64(1.0), result);
}
