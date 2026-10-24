const std = @import("std");
const skript = @import("root.zig");
const Code = @import("code.zig");
const SourceUnit = @import("SourceUnit.zig");
const Value = skript.Value;
const Error = skript.Error;

const CodeIdentityView = struct {
    id: u32,
    revision: u64,
};

const OriginView = struct {
    code: CodeIdentityView,
    function: u32,
    origin: Value,
};

/// Export data, never owners, host pointers, or closure environments. The final
/// snapshot validates the complete datum before copying into the live Store.
pub fn snapshot(
    rt: *skript.Runtime,
    code: *const Code.Code,
    function: Code.FunctionId,
    limit: SourceUnit.ExportLimit,
) Error!Value {
    const scope = rt.context().activate();
    defer scope.deinit();
    if (code.owner != @as(?*const anyopaque, rt)) return error.InvalidCode;
    if (code.function(function) == null) return error.InvalidCode;
    if (code.functions.len > limit.max_nodes or code.globals.len > limit.max_nodes) return error.Unsupported;
    var arena = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena.deinit();
    const scratch = arena.allocator();
    try code.validate(scratch, rt.context());
    const temporary = skript.Store.initDefault(scratch, rt.io) catch return error.OutOfMemory;
    defer temporary.deinit();
    var encoder: Encoder = .{
        .runtime = rt,
        .code = code,
        .store = temporary,
        .scratch = scratch,
        .remaining = limit.max_nodes,
        .max_depth = limit.max_depth,
    };
    const datum = try encoder.list(&.{
        try encoder.label("code-v1"),
        try encoder.encode(function, 1),
        try encoder.program(function),
    });
    return SourceUnit.snapshot(scratch, rt.store, datum, limit);
}

const Encoder = struct {
    runtime: *skript.Runtime,
    code: *const Code.Code,
    store: *skript.Store,
    scratch: std.mem.Allocator,
    remaining: usize,
    max_depth: usize,

    fn charge(self: *Encoder) Error!void {
        try self.runtime.context().charge(.{ .work = 1, .nodes = 1 }, .code);
        if (self.remaining == 0) return error.Unsupported;
        self.remaining -= 1;
    }

    fn label(self: *Encoder, name: []const u8) Error!Value {
        try self.charge();
        return .keyword(try self.runtime.store.getsym(name));
    }

    fn list(self: *Encoder, values: []const Value) Error!Value {
        if (values.len > self.remaining) return error.Unsupported;
        var result: Value = .nil;
        var index = values.len;
        while (index > 0) {
            index -= 1;
            try self.charge();
            const ref = try self.store.create([2]Value);
            self.store.store([2]Value, ref.deref([2]Value), .{ values[index], result });
            result = .cons(ref.toObject());
        }
        return result;
    }

    fn opaqueValue(self: *Encoder, name: []const u8) Error!Value {
        return self.list(&.{ try self.label("opaque"), try self.label(name) });
    }

    fn value(self: *Encoder, item: Value) Error!Value {
        const b = skript.builtins;
        const tag = @backingInt(item.typ);
        if (item.isNil() or item.typ == b.type_bool or item.typ == b.type_symbol or
            item.typ == b.type_keyword or item.typ == b.type_string or item.typ == b.type_cons or
            (tag >= b.type_float and tag <= b.type_complex_max))
        {
            // SourceUnit.snapshot bounds, validates, and detaches these values.
            return item;
        }
        if (item.typ == b.type_intrinsic) {
            if (self.runtime.intrinsics.idForNative(item.obj.toPtr(skript.FuncPtr))) |id| {
                return self.list(&.{ try self.label("primitive"), .u64(id.index()) });
            }
            return self.opaqueValue("native");
        }
        if (item.typ == b.type_method) {
            const method = item.obj.toRef().deref(skript.data.Method);
            return self.list(&.{ try self.label("method"), .u64(method.id), .u64(method.revision) });
        }
        if (item.typ == b.type_closure) {
            const closure = item.obj.toRef().deref(skript.data.Closure);
            if (closure.code) |owner| {
                return self.list(&.{
                    try self.label("function"),
                    .u64(owner.id),
                    .u64(owner.revision),
                    .u64(@backingInt(closure.function_id)),
                });
            }
            return self.opaqueValue("closure");
        }
        return self.opaqueValue("value");
    }

    fn program(self: *Encoder, root: Code.FunctionId) Error!Value {
        const reachable = try self.scratch.alloc(bool, self.code.functions.len);
        @memset(reachable, false);
        reachable[@backingInt(root)] = true;
        const used_globals = try self.scratch.alloc(bool, self.code.globals.len);
        @memset(used_globals, false);
        var pending: std.ArrayList(Code.FunctionId) = .empty;
        try pending.append(self.scratch, root);
        var cursor: usize = 0;
        while (cursor < pending.items.len) : (cursor += 1) {
            try self.charge();
            const function = self.code.function(pending.items[cursor]) orelse return error.InvalidCode;
            for (self.code.function_blocks[function.block_start..][0..function.block_count]) |block_id| {
                const block = self.code.blocks[@backingInt(block_id)];
                for (self.code.block_nodes[block.node_start..][0..block.node_count]) |node_id| {
                    try self.charge();
                    const node = self.code.nodes[@backingInt(node_id)];
                    const target = switch (node.operation) {
                        .make_closure => |closure| closure.function,
                        .direct_call => |call| call.function,
                        .global_read => |cell| {
                            used_globals[@backingInt(cell)] = true;
                            continue;
                        },
                        .global_write => |write| {
                            used_globals[@backingInt(write.cell)] = true;
                            continue;
                        },
                        else => continue,
                    };
                    if (!reachable[@backingInt(target)]) {
                        reachable[@backingInt(target)] = true;
                        try pending.append(self.scratch, target);
                    }
                }
            }
        }
        var globals: std.ArrayList(Code.GlobalCell) = .empty;
        for (self.code.globals, used_globals) |global, used| {
            if (used) try globals.append(self.scratch, global);
        }
        const functions = try self.scratch.alloc(Value, pending.items.len);
        for (pending.items, functions) |function, *out| out.* = try self.functionView(function);
        return self.encode(.{
            .id = self.code.id,
            .revision = self.code.revision,
            .functions = functions,
            .globals = globals.items,
        }, 1);
    }

    fn originView(self: *Encoder, first: ?Code.Origin, depth: usize) Error!Value {
        var chain: std.ArrayList(Code.Origin) = .empty;
        defer chain.deinit(self.scratch);
        var current = first;
        while (current) |origin| {
            const origin_depth = std.math.add(usize, depth, chain.items.len) catch
                return error.Unsupported;
            if (origin_depth > self.max_depth) return error.Unsupported;
            if (origin.code.owner != @as(?*const anyopaque, self.runtime)) return error.InvalidCode;
            const function = origin.code.function(origin.function) orelse return error.InvalidCode;
            try chain.append(self.scratch, origin);
            current = function.origin;
        }

        var view: Value = .nil;
        var index = chain.items.len;
        while (index > 0) {
            index -= 1;
            const origin = chain.items[index];
            const origin_depth = std.math.add(usize, depth, index) catch
                return error.Unsupported;
            view = try self.encode(OriginView{
                .code = .{ .id = origin.code.id, .revision = origin.code.revision },
                .function = @backingInt(origin.function),
                .origin = view,
            }, origin_depth);
        }
        return view;
    }

    fn functionView(self: *Encoder, id: Code.FunctionId) Error!Value {
        const function = self.code.function(id) orelse return error.InvalidCode;
        const block_ids = self.code.function_blocks[function.block_start..][0..function.block_count];
        if (block_ids.len > self.remaining) return error.Unsupported;
        const blocks = try self.scratch.alloc(Value, block_ids.len);
        for (block_ids, blocks) |block_id, *out| {
            const block = self.code.blocks[@backingInt(block_id)];
            const node_ids = self.code.block_nodes[block.node_start..][0..block.node_count];
            if (node_ids.len > self.remaining) return error.Unsupported;
            const nodes = try self.scratch.alloc(Code.Node, node_ids.len);
            for (node_ids, nodes) |node_id, *node| node.* = self.code.nodes[@backingInt(node_id)];
            out.* = try self.encode(.{
                .id = block.id,
                .parameters = self.code.block_parameters[block.param_start..][0..block.param_count],
                .nodes = nodes,
                .terminator = block.terminator,
                .handler = if (block.handler == .invalid) null else self.code.handlers[@backingInt(block.handler)],
            }, 2);
        }
        const binding_ids = self.code.function_bindings[function.binding_start..][0..function.binding_count];
        if (binding_ids.len > self.remaining) return error.Unsupported;
        const bindings = try self.scratch.alloc(Code.Binding, binding_ids.len);
        for (binding_ids, bindings) |binding_id, *binding| binding.* = self.code.bindings[@backingInt(binding_id)];
        return self.encode(.{
            .id = function.id,
            .name = function.name,
            .source = function.source,
            .parameters = self.code.parameters[function.parameter_start..][0..function.parameter_count],
            .captures = self.code.captures[function.capture_start..][0..function.capture_count],
            .bindings = bindings,
            .blocks = blocks,
            .result_count = function.result_count,
            .module_entry = function.module_entry,
            .ad_level = function.ad_level,
            .allows_ad = function.allows_ad,
            .origin = try self.originView(function.origin, 2),
        }, 1);
    }

    fn encode(self: *Encoder, item: anytype, depth: usize) Error!Value {
        if (depth > self.max_depth) return error.Unsupported;
        try self.charge();
        const T = @TypeOf(item);
        if (T == Value) return self.value(item);
        if (T == Code.Symbol) return .symbol(item);
        if (T == SourceUnit.Ref) {
            const unit = item.unit orelse return .nil;
            return self.list(&.{ .u64(@backingInt(unit.id)), .u64(@backingInt(item.node)) });
        }
        if (T == Code.OperandRange) {
            return self.encode(self.code.operands[item.start..][0..item.len], depth + 1);
        }
        switch (@typeInfo(T)) {
            .int => return .u64(@intCast(item)),
            .bool => return .bool(item),
            .void => return .nil,
            .optional => return if (item) |present| self.encode(present, depth + 1) else .nil,
            .@"enum" => |info| {
                if (info.mode == .nonexhaustive) return .u64(@backingInt(item));
                return self.label(@tagName(item));
            },
            .@"union" => |info| {
                inline for (info.field_names) |name| {
                    if (std.mem.eql(u8, @tagName(item), name)) {
                        return self.list(&.{
                            try self.label(name),
                            try self.encode(@field(item, name), depth + 1),
                        });
                    }
                }
                unreachable;
            },
            .@"struct" => |info| {
                var fields: std.ArrayList(Value) = .empty;
                inline for (info.field_names) |name| {
                    try fields.append(self.scratch, try self.label(name));
                    try fields.append(self.scratch, try self.encode(@field(item, name), depth + 1));
                }
                return self.list(fields.items);
            },
            .pointer => |info| {
                if (info.size != .slice) @compileError("code export cannot contain an owner pointer");
                if (item.len > self.remaining) return error.Unsupported;
                const values = try self.scratch.alloc(Value, item.len);
                for (item, values) |element, *out| out.* = try self.encode(element, depth + 1);
                return self.list(values);
            },
            else => @compileError("unsupported semantic export field"),
        }
    }
};

test "bound snapshots reject invalid code ranges" {
    const rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const value = try rt.evalString("(fn (x) x)");
    const closure = value.obj.toRef().deref(skript.data.Closure);
    const closure_code = closure.code orelse return error.TestUnexpectedResult;
    var malformed = closure_code.*;

    malformed.function_blocks = &.{.invalid};
    try std.testing.expectError(error.InvalidCode, snapshot(rt, &malformed, closure.function_id, .{}));
    var malformed_origin = closure_code.*;
    const functions = try std.testing.allocator.dupe(Code.Function, malformed_origin.functions);
    defer std.testing.allocator.free(functions);
    functions[@backingInt(closure.function_id)].origin = .{
        .code = &malformed_origin,
        .function = closure.function_id,
    };
    malformed_origin.functions = functions;
    try std.testing.expectError(
        error.InvalidCode,
        snapshot(rt, &malformed_origin, closure.function_id, .{}),
    );
}

test "bound snapshots expose redacted generated origins" {
    const Inspect = struct {
        const InspectError = error{MalformedView};

        fn pair(value: Value) InspectError![2]Value {
            if (value.typ != skript.builtins.type_cons) return error.MalformedView;
            return value.obj.toRef().deref([2]Value).*;
        }

        fn at(value: Value, index: usize) InspectError!Value {
            var cursor = value;
            var remaining = index;
            while (remaining > 0) : (remaining -= 1) {
                cursor = (try pair(cursor))[1];
            }
            return (try pair(cursor))[0];
        }
    };

    const rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const source = try rt.evalString("(fn (x) (* x x))");
    const source_closure = source.obj.toRef().deref(skript.data.Closure);
    const source_code = source_closure.code orelse return error.TestUnexpectedResult;
    const derivative = try skript.autodiff_forward.generate(rt.context(), source, 0, .derivative);
    const derivative_closure = derivative.obj.toRef().deref(skript.data.Closure);
    const derivative_code = derivative_closure.code orelse return error.TestUnexpectedResult;
    const derivative_function = derivative_code.function(derivative_closure.function_id) orelse
        return error.TestUnexpectedResult;
    const derivative_origin = derivative_function.origin orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(source_code, derivative_origin.code);
    try std.testing.expectEqual(source_closure.function_id, derivative_origin.function);

    const view = try snapshot(rt, derivative_code, derivative_closure.function_id, .{});
    const program = try Inspect.at(view, 2);
    const functions = try Inspect.at(program, 5);
    const function_view = try Inspect.at(functions, 0);
    const origin = try Inspect.at(function_view, 23);
    const origin_code = try Inspect.at(origin, 1);
    try std.testing.expectEqual(
        Value.u64(source_code.id),
        try Inspect.at(origin_code, 1),
    );
    try std.testing.expectEqual(
        Value.u64(source_code.revision),
        try Inspect.at(origin_code, 3),
    );
    try std.testing.expectEqual(
        Value.u64(@backingInt(source_closure.function_id)),
        try Inspect.at(origin, 3),
    );
    try std.testing.expectEqual(Value.nil, try Inspect.at(origin, 5));

    const second = try skript.autodiff_forward.generate(rt.context(), derivative, 0, .derivative);
    const second_closure = second.obj.toRef().deref(skript.data.Closure);
    const second_code = second_closure.code orelse return error.TestUnexpectedResult;
    const second_function = second_code.function(second_closure.function_id) orelse
        return error.TestUnexpectedResult;
    const second_origin = second_function.origin orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(derivative_code, second_origin.code);
    try std.testing.expectEqual(derivative_closure.function_id, second_origin.function);
}
