const std = @import("std");
const skript = @import("root.zig");
const Code = @import("code.zig");
const AdCallable = @import("autodiff/callable.zig");
const EvalContext = skript.EvalContext;
const Primitive = @import("primitive.zig");

const Runtime = skript.Runtime;
const Value = skript.Value;
const Object = skript.Object;
const Error = skript.Error;
const FuncPtr = skript.FuncPtr;
const Closure = skript.data.Closure;

/// Bound-code effect preflight is deliberately finite. A malformed or larger
/// graph fails closed instead of turning a validation call into an unbounded
/// traversal.
const max_functions: usize = 4096;
const max_steps: usize = 131_072;
const max_resolution_depth: usize = 256;

const FunctionTarget = struct {
    code: *const Code.Code,
    function_id: Code.FunctionId,
    namespace: Value,
    captures: []const Capture,
};

const Resolved = union(enum) {
    unknown,
    value: Value,
    function: FunctionTarget,
};

const Capture = struct {
    binding: Code.BindingId,
    target: Resolved,
};

const WorkItem = FunctionTarget;

fn contextEqualStep(context: ?*const EvalContext, depth: usize) Error!void {
    if (context) |active| {
        try active.check();
        if (active.budget()) |budget| try budget.checkDepth(@intCast(depth), .transform);
        try active.chargeWork(1, 1, .transform);
    }
}
fn contextError(context: ?*const EvalContext, err: Error) Error {
    if (context) |active| {
        if (active.check()) |_| {} else |check_error| return check_error;
    }
    return err;
}

fn capturesEqual(
    context: ?*const EvalContext,
    lhs: []const Capture,
    rhs: []const Capture,
    depth: usize,
) Error!bool {
    if (lhs.len != rhs.len or depth >= max_resolution_depth) return false;
    for (lhs, rhs) |left, right| {
        try contextEqualStep(context, depth);
        if (left.binding != right.binding) return false;
        if (!try resolvedEqual(context, left.target, right.target, depth + 1)) return false;
    }
    return true;
}

fn resolvedEqual(context: ?*const EvalContext, lhs: Resolved, rhs: Resolved, depth: usize) Error!bool {
    if (depth >= max_resolution_depth) return false;
    try contextEqualStep(context, depth);
    return switch (lhs) {
        .unknown => switch (rhs) {
            .unknown => true,
            else => false,
        },
        .value => |left| switch (rhs) {
            .value => |right| left.typ == right.typ and left.obj == right.obj,
            else => false,
        },
        .function => |left| switch (rhs) {
            .function => |right| left.code.id == right.code.id and
                left.code.revision == right.code.revision and
                left.function_id == right.function_id and
                left.namespace.typ == right.namespace.typ and
                left.namespace.obj == right.namespace.obj and
                try capturesEqual(context, left.captures, right.captures, depth + 1),
            else => false,
        },
    };
}

const Seen = struct {
    code_id: u32,
    code_revision: u64,
    function_id: Code.FunctionId,
    namespace: Value,
    captures: []const Capture,
};

pub const Read = union(enum) {
    cell: struct { namespace: Value, binding: skript.Sym, snapshot: Runtime.Dependency },
    method: struct { value: Value, id: u64, revision: u64 },
    primitive: *const Primitive.Spec,

    pub fn valid(self: Read, rt: *Runtime) bool {
        return switch (self) {
            .cell => |cell| rt.validateDependency(cell.namespace, cell.binding, cell.snapshot),
            .method => |saved| blk: {
                const current = saved.value.obj.toRef().deref(skript.data.Method);
                break :blk current.id == saved.id and current.revision == saved.revision;
            },
            .primitive => |saved| blk: {
                const current = rt.intrinsics.spec(saved.id) orelse break :blk false;
                break :blk saved.sameSemantics(current.*);
            },
        };
    }
};

const Scanner = struct {
    rt: *Runtime,
    scratch: std.mem.Allocator,
    // SAFETY: every queue entry is written by enqueue before run reads its bounded prefix.
    queue: [max_functions]WorkItem,
    queue_len: usize = 0,
    queue_pos: usize = 0,
    // SAFETY: every seen entry is written by enqueue before duplicate checks read its prefix.
    seen: [max_functions]Seen,
    seen_len: usize = 0,
    steps: usize = 0,
    reads: std.ArrayList(Read) = .empty,
    context: ?*const EvalContext = null,

    fn readGlobal(self: *Scanner, namespace: Value, binding: skript.Sym) Error!Runtime.Dependency {
        for (self.reads.items) |previous| {
            try self.step();
            if (previous != .cell) continue;
            const cell = previous.cell;
            if (cell.namespace.typ == namespace.typ and cell.namespace.obj == namespace.obj and
                cell.binding == binding) return cell.snapshot;
        }
        const snapshot = try self.rt.readDependency(namespace, binding);
        try self.reads.append(self.scratch, .{
            .cell = .{
                .namespace = namespace,
                .binding = binding,
                .snapshot = snapshot,
            },
        });
        return snapshot;
    }

    fn noteMethod(self: *Scanner, value: Value) Error!void {
        for (self.reads.items) |previous| {
            try self.step();
            if (previous == .method and previous.method.value.obj == value.obj) return;
        }
        const method = value.obj.toRef().deref(skript.data.Method);
        try self.reads.append(self.scratch, .{ .method = .{
            .value = value,
            .id = method.id,
            .revision = method.revision,
        } });
    }

    fn notePrimitive(self: *Scanner, spec: *const Primitive.Spec) Error!void {
        for (self.reads.items) |previous| {
            try self.step();
            if (previous == .primitive and previous.primitive.id == spec.id) return;
        }
        try self.reads.append(self.scratch, .{ .primitive = spec });
    }

    fn enqueue(self: *Scanner, target: FunctionTarget) Error!void {
        if (target.code.function(target.function_id) == null) return error.Unsupported;
        for (self.seen[0..self.seen_len]) |seen| {
            try self.chargeWork();
            if (seen.code_id == target.code.id and
                seen.code_revision == target.code.revision and
                seen.function_id == target.function_id and
                seen.namespace.typ == target.namespace.typ and
                seen.namespace.obj == target.namespace.obj and
                (try capturesEqual(self.context, seen.captures, target.captures, 0)))
            {
                return;
            }
        }
        if (self.seen_len >= max_functions or self.queue_len >= max_functions) {
            return error.Unsupported;
        }
        self.seen[self.seen_len] = .{
            .code_id = target.code.id,
            .code_revision = target.code.revision,
            .function_id = target.function_id,
            .namespace = target.namespace,
            .captures = target.captures,
        };
        self.seen_len += 1;
        self.queue[self.queue_len] = target;
        self.queue_len += 1;
    }

    fn run(self: *Scanner) Error!void {
        while (self.queue_pos < self.queue_len) {
            try self.chargeWork();
            const item = self.queue[self.queue_pos];
            self.queue_pos += 1;
            try self.scanFunction(item);
        }
    }

    fn scanFunction(self: *Scanner, item: WorkItem) Error!void {
        const function = item.code.function(item.function_id) orelse return error.Unsupported;
        const first: usize = function.block_start;
        const block_count: usize = function.block_count;
        const last = std.math.add(usize, first, block_count) catch return error.Unsupported;
        if (last > item.code.function_blocks.len) return error.Unsupported;

        for (item.code.function_blocks[first..last]) |block_id| {
            const block_index = @intFromEnum(block_id);
            if (block_index >= item.code.blocks.len) return error.Unsupported;
            const block = item.code.blocks[block_index];
            if (block.function != item.function_id) return error.Unsupported;
            const node_first: usize = block.node_start;
            const node_count: usize = block.node_count;
            const node_last = std.math.add(usize, node_first, node_count) catch
                return error.Unsupported;
            if (node_last > item.code.block_nodes.len) return error.Unsupported;
            for (item.code.block_nodes[node_first..node_last]) |node_id| {
                try self.step();
                const node_index = @intFromEnum(node_id);
                if (node_index >= item.code.nodes.len) return error.Unsupported;
                const node = item.code.nodes[node_index];
                if (node.function != item.function_id) return error.Unsupported;
                try self.scanOperation(item, node.operation);
            }
            try self.step();
            try self.scanTerminator(item, block.terminator);
        }
    }

    fn step(self: *Scanner) Error!void {
        self.steps = std.math.add(usize, self.steps, 1) catch return error.Unsupported;
        if (self.steps > max_steps) return error.Unsupported;
        if (self.context) |context| {
            try context.charge(.{ .work = 1, .nodes = 1 }, .transform);
        }
    }

    fn chargeWork(self: *Scanner) Error!void {
        if (self.context) |context| {
            try context.check();
            try context.chargeWork(1, 1, .transform);
        }
    }

    fn scanOperation(self: *Scanner, item: WorkItem, operation: Code.Operation) Error!void {
        switch (operation) {
            .literal, .quote, .local_read, .try_begin, .try_end, .ns_push, .ns_pop => {},
            .global_read => |cell| {
                const global = item.code.globals[@intFromEnum(cell)];
                if (global.binding == .invalid) {
                    _ = self.readGlobal(item.namespace, global.name) catch |err| switch (err) {
                        error.Unbound => return,
                        else => return err,
                    };
                }
            },
            .global_write => |write| {
                if (write.assign_existing) return error.Unsupported;
                const cell = item.code.globals[@intFromEnum(write.cell)];
                if (cell.binding == .invalid) return error.Unsupported;
                const binding = item.code.bindings[@intFromEnum(cell.binding)];
                if (binding.function != item.function_id) return error.Unsupported;
            },
            .arithmetic => |arith| {
                if (arith.callee != .invalid) {
                    try self.inspectCallTarget(item, arith.callee, .{});
                }
                if (!arith.expected_callee.isNil()) {
                    try self.inspectValue(arith.expected_callee, item.namespace);
                }
            },
            .primitive_call => |call| {
                try self.inspectPrimitive(item, call.primitive, call.args);
            },
            .direct_call => |call| {
                const function = item.code.function(call.function) orelse return error.Unsupported;
                const captures: []const Capture = if (call.function == item.function_id)
                    item.captures
                else if (function.capture_count == 0)
                    &.{}
                else
                    return error.Unsupported;
                try self.enqueue(.{
                    .code = item.code,
                    .function_id = call.function,
                    .namespace = item.namespace,
                    .captures = captures,
                });
            },
            .dynamic_call => |call| {
                try self.inspectCallTarget(item, call.callee, call.args);
            },
            .make_closure => |closure| {
                const target = try self.makeClosureTarget(item, closure.function, closure.captures);
                try self.enqueue(target);
            },
        }
    }

    fn scanTerminator(self: *Scanner, item: WorkItem, terminator: Code.Terminator) Error!void {
        switch (terminator) {
            .none, .jump, .branch, .return_values, .raise => {},
            .tail_call => |call| try self.inspectCallTarget(item, call.callee, call.args),
        }
    }

    fn inspectCallTarget(
        self: *Scanner,
        item: WorkItem,
        value: Code.ValueId,
        args: Code.OperandRange,
    ) Error!void {
        try self.inspectCallAtDepth(item, value, args, 0);
    }

    fn inspectCallAtDepth(
        self: *Scanner,
        item: WorkItem,
        value: Code.ValueId,
        args: Code.OperandRange,
        depth: usize,
    ) Error!void {
        if (depth >= max_resolution_depth) return error.Unsupported;
        const target = try self.resolveValue(item, value, depth);
        switch (target) {
            .unknown => {
                const ctx = self.context orelse self.rt.context();
                const sources = (try AdCallable.incoming(ctx, item.code, value)) orelse
                    return error.Unsupported;
                defer ctx.scratch.free(sources);
                for (sources) |source| try self.inspectCallAtDepth(item, source, args, depth + 1);
            },
            .value => |callable| {
                if (callable.typ == skript.builtins.type_intrinsic) {
                    const native = callable.obj.toPtr(FuncPtr);
                    const primitive_id = self.rt.intrinsics.idForNative(native) orelse return error.Unsupported;
                    try self.inspectPrimitive(item, primitive_id, args);
                } else if (callable.typ == skript.builtins.type_method) {
                    try self.inspectMethodCall(callable, item, args);
                } else {
                    try self.inspectValue(callable, item.namespace);
                }
            },
            .function => |function| try self.enqueue(function),
        }
    }

    fn inspectPrimitive(
        self: *Scanner,
        item: ?WorkItem,
        primitive_id: Primitive.PrimitiveId,
        args: Code.OperandRange,
    ) Error!void {
        const spec = self.rt.intrinsics.spec(primitive_id) orelse return error.Unsupported;
        if (spec.id != primitive_id) return error.Unsupported;
        try self.notePrimitive(spec);
        try requirePurePrimitive(spec);
        try self.inspectInvocation(spec.invoke);
        if (item) |actual| {
            try self.inspectCallback(actual, spec.callbacks, args);
        } else switch (spec.callbacks) {
            .none => {},
            else => return error.Unsupported,
        }
    }

    fn inspectInvocation(self: *Scanner, invocation: Primitive.Invocation) Error!void {
        switch (invocation) {
            .native => {},
            .closure => |closure| try self.inspectClosure(closure),
        }
    }

    fn inspectCallback(
        self: *Scanner,
        item: WorkItem,
        callback: Primitive.Callback,
        args: Code.OperandRange,
    ) Error!void {
        const values = try operands(item.code, args);
        switch (callback) {
            .none => {},
            .last => {
                if (values.len == 0) return error.Unsupported;
                try self.inspectResolvedValue(item, values[values.len - 1]);
            },
            .argument => |index| {
                if (@as(usize, index) >= values.len) return error.Unsupported;
                try self.inspectResolvedValue(item, values[index]);
            },
            .collection_fold => {
                const last_index: usize = switch (values.len) {
                    2 => 1,
                    3 => 2,
                    else => return error.Unsupported,
                };
                try self.inspectResolvedValue(item, values[last_index]);
            },
            .type_hook => {
                if (values.len == 0) return error.Unsupported;
                for (values) |value_id| {
                    try self.step();
                    const resolved = try self.resolveValue(item, value_id, 0);
                    switch (resolved) {
                        .value => |value| {
                            if (value.isType()) try self.inspectType(value, item.namespace);
                        },
                        .function => |function| try self.enqueue(function),
                        .unknown => return error.Unsupported,
                    }
                }
            },
            .unknown => return error.Unsupported,
        }
    }

    fn inspectResolvedValue(self: *Scanner, item: WorkItem, value_id: Code.ValueId) Error!void {
        const resolved = try self.resolveValue(item, value_id, 0);
        switch (resolved) {
            .unknown => return error.Unsupported,
            .value => |value| try self.inspectValue(value, item.namespace),
            .function => |function| try self.enqueue(function),
        }
    }

    fn inspectValue(self: *Scanner, value: Value, namespace: Value) Error!void {
        switch (value.typ) {
            skript.builtins.type_intrinsic => {
                const native = value.obj.toPtr(FuncPtr);
                const primitive_id = self.rt.intrinsics.idForNative(native) orelse return error.Unsupported;
                try self.inspectPrimitive(null, primitive_id, .{});
            },
            skript.builtins.type_closure => {
                var registered = false;
                for (self.rt.intrinsics.registry.current().specs) |spec| {
                    try self.chargeWork();
                    const implementation = switch (spec.invoke) {
                        .native => continue,
                        .closure => |closure| closure,
                    };
                    if (implementation.typ != value.typ or implementation.obj != value.obj) continue;
                    registered = true;
                    try self.inspectPrimitive(null, spec.id, .{});
                }
                if (!registered) try self.inspectClosure(value);
            },
            skript.builtins.type_method => {
                try self.inspectMethod(value, namespace);
            },
            skript.builtins.type_type => try self.inspectType(value, namespace),
            skript.builtins.type_keyword,
            skript.builtins.type_ffifunc,
            skript.builtins.type_opaque,
            => return error.Unsupported,
            else => {},
        }
    }

    fn inspectClosure(self: *Scanner, value: Value) Error!void {
        const closure = value.obj.toRef().deref(Closure);
        const code = closure.code orelse return error.Unsupported;
        const captures = try self.captureValues(code, closure.function_id, closure.captures);
        try self.enqueue(.{
            .code = code,
            .function_id = closure.function_id,
            .namespace = closure.parent_ns,
            .captures = captures,
        });
    }

    fn inspectMethod(self: *Scanner, value: Value, namespace: Value) Error!void {
        try self.noteMethod(value);
        const method = value.obj.toRef().deref(skript.data.Method);
        if (method.resolved.count() == 0) return error.Unsupported;
        var iterator = method.resolved.valueIterator();
        while (iterator.next()) |target| {
            try self.step();
            switch (target.*.typ) {
                skript.builtins.type_intrinsic,
                skript.builtins.type_closure,
                => try self.inspectValue(target.*, namespace),
                else => return error.Unsupported,
            }
        }
    }

    fn inspectMethodCall(
        self: *Scanner,
        value: Value,
        item: WorkItem,
        args: Code.OperandRange,
    ) Error!void {
        try self.noteMethod(value);
        const method = value.obj.toRef().deref(skript.data.Method);
        if (method.resolved.count() == 0) return error.Unsupported;
        var iterator = method.resolved.valueIterator();
        while (iterator.next()) |target| {
            try self.step();
            switch (target.*.typ) {
                skript.builtins.type_intrinsic => {
                    const native = target.*.obj.toPtr(FuncPtr);
                    const id = self.rt.intrinsics.idForNative(native) orelse return error.Unsupported;
                    try self.inspectPrimitive(item, id, args);
                },
                skript.builtins.type_closure => try self.inspectValue(target.*, item.namespace),
                else => return error.Unsupported,
            }
        }
    }

    fn inspectType(self: *Scanner, value: Value, namespace: Value) Error!void {
        const type_ptr = self.typePtr(value);
        switch (type_ptr.apply.typ) {
            skript.builtins.type_intrinsic,
            skript.builtins.type_closure,
            skript.builtins.type_method,
            => try self.inspectValue(type_ptr.apply, namespace),
            else => return error.Unsupported,
        }
    }

    fn typePtr(self: *Scanner, value: Value) *const skript.Type {
        const tag = @intFromEnum(value.obj);
        if (tag <= skript.builtins.type_last_idx) {
            return self.rt.predefined_types.items[@as(usize, @intCast(tag))];
        }
        return value.obj.toRef().deref(skript.Type);
    }

    fn operands(code: *const Code.Code, range: Code.OperandRange) Error![]const Code.ValueId {
        const first: usize = range.start;
        const last = std.math.add(usize, first, @as(usize, range.len)) catch
            return error.Unsupported;
        if (last > code.operands.len) return error.Unsupported;
        return code.operands[first..last];
    }

    fn resolveLocalCell(
        self: *Scanner,
        item: WorkItem,
        cell: Code.GlobalCellId,
        binding_id: Code.BindingId,
        depth: usize,
    ) Error!Resolved {
        const binding_index = @intFromEnum(binding_id);
        if (binding_index >= item.code.bindings.len) return .unknown;
        const binding = item.code.bindings[binding_index];
        var initializer: Code.ValueId = .invalid;
        for (item.code.nodes) |node| {
            try self.step();
            switch (node.operation) {
                .global_write => |write| {
                    if (write.cell != cell) continue;
                    if (write.assign_existing) return .unknown;
                    if (initializer != .invalid) return .unknown;
                    initializer = write.value;
                },
                else => {},
            }
        }
        if (initializer == .invalid) return .unknown;
        var owner = item;
        owner.function_id = binding.function;
        if (owner.function_id != item.function_id) owner.captures = &.{};
        return self.resolveValue(owner, initializer, depth + 1);
    }

    fn resolveValue(
        self: *Scanner,
        item: WorkItem,
        value_id: Code.ValueId,
        depth: usize,
    ) Error!Resolved {
        if (depth >= max_resolution_depth) return error.Unsupported;
        try self.chargeWork();
        if (self.context) |context| {
            if (context.budget()) |budget| try budget.checkDepth(@intCast(depth), .transform);
        }
        if (value_id == .invalid) return .unknown;
        const function = item.code.function(item.function_id) orelse return error.Unsupported;
        const binding = try self.captureBinding(item, value_id);
        if (binding) |captured| return captured;

        const first: usize = function.block_start;
        const last = std.math.add(usize, first, @as(usize, function.block_count)) catch
            return error.Unsupported;
        if (last > item.code.function_blocks.len) return error.Unsupported;
        for (item.code.function_blocks[first..last]) |block_id| {
            const block_index = @intFromEnum(block_id);
            if (block_index >= item.code.blocks.len) return error.Unsupported;
            const block = item.code.blocks[block_index];
            const node_first: usize = block.node_start;
            const node_last = std.math.add(usize, node_first, @as(usize, block.node_count)) catch
                return error.Unsupported;
            if (node_last > item.code.block_nodes.len) return error.Unsupported;
            for (item.code.block_nodes[node_first..node_last]) |node_id| {
                try self.step();
                const node_index = @intFromEnum(node_id);
                if (node_index >= item.code.nodes.len) return error.Unsupported;
                const node = item.code.nodes[node_index];
                if (node.result != value_id) continue;
                return switch (node.operation) {
                    .literal => |literal| .{ .value = literal },
                    .global_read => |cell| blk: {
                        const global_index = @intFromEnum(cell);
                        if (global_index >= item.code.globals.len) break :blk .unknown;
                        const global = item.code.globals[global_index];
                        if (global.binding != .invalid) {
                            break :blk try self.resolveLocalCell(item, cell, global.binding, depth);
                        }
                        const dependency = self.readGlobal(item.namespace, global.name) catch |err| switch (err) {
                            error.Unbound => break :blk .unknown,
                            else => return err,
                        };
                        break :blk .{ .value = dependency.value };
                    },
                    .local_read => |binding_id| blk: {
                        const binding_index = @intFromEnum(binding_id);
                        if (binding_index >= item.code.bindings.len) break :blk .unknown;
                        const local = item.code.bindings[binding_index];
                        if (local.function != item.function_id) {
                            for (item.captures) |capture| {
                                try self.chargeWork();
                                if (capture.binding == binding_id) break :blk capture.target;
                            }
                            break :blk .unknown;
                        }
                        if (local.value == .invalid or local.value == value_id) break :blk .unknown;
                        break :blk try self.resolveValue(item, local.value, depth + 1);
                    },
                    .make_closure => |closure| .{ .function = try self.makeClosureTarget(
                        item,
                        closure.function,
                        closure.captures,
                    ) },
                    else => .unknown,
                };
            }
        }
        return .unknown;
    }

    fn captureBinding(self: *Scanner, item: WorkItem, value_id: Code.ValueId) Error!?Resolved {
        const function = item.code.function(item.function_id) orelse return null;
        const first: usize = function.capture_start;
        const last = std.math.add(usize, first, @as(usize, function.capture_count)) catch return null;
        if (last > item.code.captures.len or item.captures.len != last - first) return null;
        for (item.captures, 0..) |capture, index| {
            try self.chargeWork();
            if (index >= item.code.capture_values.len) return null;
            if (item.code.capture_values[first + index] == value_id) return capture.target;
        }
        return null;
    }

    fn makeClosureTarget(
        self: *Scanner,
        item: WorkItem,
        function_id: Code.FunctionId,
        capture_range: Code.OperandRange,
    ) Error!FunctionTarget {
        const code = item.code;
        const function = code.function(function_id) orelse return error.Unsupported;
        const values = try operands(code, capture_range);
        if (values.len != @as(usize, function.capture_count)) return error.Unsupported;
        const first: usize = function.capture_start;
        const last = std.math.add(usize, first, @as(usize, function.capture_count)) catch
            return error.Unsupported;
        if (last > code.captures.len) return error.Unsupported;
        const captures = try self.scratch.alloc(Capture, values.len);
        for (captures, values, 0..) |*capture, source, index| {
            try self.step();
            capture.* = .{
                .binding = code.captures[first + index],
                .target = self.resolveValue(item, source, 0) catch |err| switch (err) {
                    error.Unsupported => .unknown,
                    else => return err,
                },
            };
        }
        return .{
            .code = code,
            .function_id = function_id,
            .namespace = item.namespace,
            .captures = captures,
        };
    }

    fn captureValues(
        self: *Scanner,
        code: *const Code.Code,
        function_id: Code.FunctionId,
        values: []const Value,
    ) Error![]const Capture {
        const function = code.function(function_id) orelse return error.Unsupported;
        if (values.len != @as(usize, function.capture_count)) return error.Unsupported;
        const first: usize = function.capture_start;
        const last = std.math.add(usize, first, @as(usize, function.capture_count)) catch
            return error.Unsupported;
        if (last > code.captures.len) return error.Unsupported;
        const captures = try self.scratch.alloc(Capture, values.len);
        for (captures, values, 0..) |*capture, value, index| {
            try self.step();
            capture.* = .{
                .binding = code.captures[first + index],
                .target = .{ .value = value },
            };
        }
        return captures;
    }
};

/// Validate a callable's immutable bound code and every statically-known
/// transitive target before AD can execute its primal or generated sweeps.
pub fn preflight(rt: *Runtime, namespace: Value, callable: Value) Error!void {
    _ = try collectReads(rt, namespace, callable, null);
}
pub fn collectReads(rt: *Runtime, namespace: Value, callable: Value, allocator: ?std.mem.Allocator) Error![]Read {
    const context = EvalContext.currentForStore(rt.store);
    if (context) |active| try active.check();
    var scratch = std.heap.ArenaAllocator.init(rt.gpa);
    defer scratch.deinit();
    var scanner: Scanner = .{
        .rt = rt,
        .scratch = scratch.allocator(),
        // SAFETY: lengths bound all reads, and enqueue writes each entry before run uses it.
        .queue = undefined,
        // SAFETY: every seen entry is written by enqueue before run reads its bounded prefix.
        .seen = undefined,
        .context = context,
    };
    scanner.inspectValue(callable, namespace) catch |err| {
        return contextError(context, err);
    };
    scanner.run() catch |err| {
        return contextError(context, err);
    };
    if (allocator) |output| {
        return output.dupe(Read, scanner.reads.items) catch |err| {
            return contextError(context, err);
        };
    }
    return &.{};
}

pub fn requirePurePrimitive(spec: *const Primitive.Spec) Error!void {
    const effects = spec.effects;
    if (effects.state_write or effects.io or effects.clock or effects.random or
        effects.process or effects.module or effects.ffi or effects.dynamic_loader or
        effects.host or effects.unknown) return error.Unsupported;
    if (effects.state_read and !spec.reads_argument_state) return error.Unsupported;
    if (spec.resources == .denied) return error.Unsupported;
    switch (spec.suspension) {
        .never => {},
        .callback => switch (spec.callbacks) {
            .last, .argument, .collection_fold, .type_hook => {},
            .none, .unknown => return error.Unsupported,
        },
        .would_block, .unknown => return error.Unsupported,
    }
}

pub fn preflightCall(rt: *Runtime, namespace: Value, callable: Value, arguments: []const Value) Error!void {
    if (callable.typ != skript.builtins.type_intrinsic) return preflight(rt, namespace, callable);
    const primitive = rt.context().registry.idForNative(callable.obj.toPtr(FuncPtr)) orelse return error.Unsupported;
    const spec = rt.context().registry.spec(primitive) orelse return error.Unsupported;
    try requirePurePrimitive(spec);
    const callback_index: ?usize = switch (spec.callbacks) {
        .none => null,
        .last => if (arguments.len == 0) return error.ArityMismatch else arguments.len - 1,
        .argument => |index| index,
        .collection_fold => switch (arguments.len) {
            2, 3 => arguments.len - 1,
            else => return error.ArityMismatch,
        },
        .type_hook => blk: {
            for (arguments) |argument| {
                if (argument.isType()) try preflight(rt, namespace, argument);
            }
            break :blk null;
        },
        .unknown => return error.Unsupported,
    };
    if (callback_index) |index| {
        if (index >= arguments.len) return error.ArityMismatch;
        if (!arguments[index].isNil()) try preflight(rt, namespace, arguments[index]);
    }
}

test "local namespace aliases cannot inherit a global effect classification" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const unsafe = try rt.evalString(
        "(def effect-alias +) (fn (x) (let ((effect-alias +)) (def effect-alias write) (effect-alias x)) x)",
    );
    try std.testing.expectError(error.Unsupported, preflight(rt, rt.root_ns, unsafe));
    const safe = try rt.evalString(
        "(def effect-alias write) (fn (x) (let ((effect-alias +)) (effect-alias x x)))",
    );
    try preflight(rt, rt.root_ns, safe);
}

test "nested unexecuted closures inherit lexical effect targets" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const unsafe = try rt.evalString(
        "(def effect-alias +) (fn (x) (let ((effect-alias write)) ((fn () (effect-alias x)))) x)",
    );
    try std.testing.expectError(error.Unsupported, preflight(rt, rt.root_ns, unsafe));
    const safe = try rt.evalString(
        "(def effect-alias write) (fn (x) (let ((effect-alias +)) ((fn () (effect-alias x x)))))",
    );
    try preflight(rt, rt.root_ns, safe);
}

test "registered closure policy cannot be bypassed by its implementation" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const closure = try rt.evalString("(fn (x) (* x x))");
    _ = try rt.intrinsics.registry.publish(&.{.{
        .stable_name = "blocked",
        .invoke = .{ .closure = closure },
        .effects = .none,
        .callbacks = .none,
        .suspension = .never,
        .resources = .denied,
    }});
    try std.testing.expectError(error.Unsupported, rt.evalString("(deriv @blocked)"));
}

test "extension names cannot select builtin derivative formulas" {
    const Native = struct {
        fn zero(_: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
            if (args.len != 1) return error.ArityMismatch;
            return Value.f64(0);
        }
    };
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    _ = try rt.intrinsics.registry.publish(&.{.{
        .stable_name = "custom.sin",
        .invoke = Primitive.Invocation.nativePtr(&Native.zero),
        .effects = .none,
        .callbacks = .none,
        .suspension = .never,
        .resources = .{ .fixed = .{} },
    }});
    try std.testing.expectError(error.Unsupported, rt.evalString("(deriv @custom.sin)"));
}

test "AD rejects foreign namespace getters before their effects" {
    const Foreign = struct {
        const Self = @This();
        base: skript.HashMapNamespace,
        calls: u32 = 0,

        fn get(_: *Runtime, table: *skript.Namespace, _: Object, _: skript.Sym) callconv(.c) Value {
            const self: *Self = @ptrCast(@alignCast(table.data));
            self.calls += 1;
            return .true;
        }
    };
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var foreign: Foreign = .{ .base = try skript.HashMapNamespace.init(rt.static, .nil) };
    const namespace = try rt.store.create(skript.Namespace);
    namespace.deref(skript.Namespace).* = skript.HashMapNamespace.vtable;
    namespace.deref(skript.Namespace).data = &foreign;
    namespace.deref(skript.Namespace).get = &Foreign.get;
    try rt.nsBind(rt.root_ns, try rt.store.getsym("foreign"), Value.namespace(namespace.toObject()));
    try std.testing.expectError(error.Unsupported, rt.evalString(
        "((value-and-gradient (fn (x) (if (:flag foreign) x x))) 3.0)",
    ));
    try std.testing.expectEqual(@as(u32, 0), foreign.calls);
    try std.testing.expectError(error.Unsupported, rt.evalString(
        "((value-and-gradient (fn (x) (if foreign/flag x x))) 3.0)",
    ));
    try std.testing.expectEqual(@as(u32, 0), foreign.calls);
}
