const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;
const SourceUnit = @import("SourceUnit.zig");
const EvalContext = @import("EvalContext.zig");
const PrimitiveId = @import("primitive.zig").PrimitiveId;

pub const Symbol = *[]const u8;
pub const invalid_index: u32 = std.math.maxInt(u32);

pub const BindingId = enum(u32) { invalid = invalid_index, _ };
pub const ValueId = enum(u32) { invalid = invalid_index, _ };
pub const FunctionId = enum(u32) { invalid = invalid_index, _ };
pub const BlockId = enum(u32) { invalid = invalid_index, _ };
pub const BoundNodeId = enum(u32) { invalid = invalid_index, _ };
pub const GlobalCellId = enum(u32) { invalid = invalid_index, _ };
pub const HandlerId = enum(u32) { invalid = invalid_index, _ };

pub const Error = error{ OutOfMemory, InvalidCode, Unsupported, Exhausted };
const max_origin_depth: usize = 256;

fn contextCheck(context: ?*const EvalContext) Error!void {
    if (context) |active| {
        try active.check();
    }
}

fn contextChargeWork(context: ?*const EvalContext, count: usize) Error!void {
    if (context) |active| {
        try contextCheck(context);
        try active.chargeWork(@intCast(count), 1, .code);
    }
}

fn contextChargeNodes(context: ?*const EvalContext, count: usize) Error!void {
    if (context) |active| {
        try contextCheck(context);
        const amount: u64 = @intCast(count);
        try active.charge(.{ .work = amount, .nodes = amount }, .code);
    }
}

fn contextCheckDepth(context: ?*const EvalContext, depth: u32) Error!void {
    if (context) |active| {
        if (active.budget()) |budget| {
            budget.checkDepth(depth, .code) catch |err| switch (err) {
                error.Exhausted => return error.Exhausted,
            };
        }
    }
}
fn contextError(context: ?*const EvalContext, err: Error) Error {
    if (context) |active| {
        try active.check();
    }
    return err;
}

pub const OperandRange = struct {
    start: u32 = 0,
    len: u32 = 0,

    pub fn empty() OperandRange {
        return .{};
    }
};

pub const BindingKind = enum { parameter, capture, let, handler, definition };

pub const Binding = struct {
    id: BindingId,
    function: FunctionId,
    name: Symbol,
    kind: BindingKind,
    mutable: bool = false,
    value: ValueId = .invalid,
    source: SourceUnit.Ref = .{},
};

pub const GlobalCell = struct {
    id: GlobalCellId,
    name: Symbol,
    /// Lexical namespace cells retain their binding identity across closures.
    binding: BindingId = .invalid,
    source: SourceUnit.Ref = .{},
};

pub const ArithOp = enum { add, sub, mul, div, equal, less, greater };

pub const Call = struct {
    callee: ValueId = .invalid,
    args: OperandRange = .{},
    result_count: u8 = 1,
    self_target: FunctionId = .invalid,
    tail: bool = false,
};

pub const PrimitiveCall = struct {
    primitive: PrimitiveId,
    args: OperandRange = .{},
    result_count: u8 = 1,
    tail: bool = false,
};

pub const DirectCall = struct {
    function: FunctionId,
    args: OperandRange = .{},
    result_count: u8 = 1,
};

pub const Arithmetic = struct {
    op: ArithOp,
    left: ValueId,
    right: ValueId,
    callee: ValueId = .invalid,
    expected_callee: Value = .nil,
    left_types: u64 = std.math.maxInt(u64),
    right_types: u64 = std.math.maxInt(u64),
    tail: bool = false,
};

pub const MakeClosure = struct {
    function: FunctionId,
    captures: OperandRange = .{},
};

pub const Operation = union(enum) {
    literal: Value,
    quote: Value,
    local_read: BindingId,
    global_read: GlobalCellId,
    global_write: struct {
        cell: GlobalCellId,
        value: ValueId,
        assign_existing: bool = false,
    },
    primitive_call: PrimitiveCall,
    arithmetic: Arithmetic,
    dynamic_call: Call,
    direct_call: DirectCall,
    make_closure: MakeClosure,
    try_begin: HandlerId,
    try_end,
    ns_push: u16,
    ns_pop,
};

pub const Edge = struct {
    target: BlockId,
    args: OperandRange = .{},
};

pub const Branch = struct {
    condition: ValueId,
    then_edge: Edge,
    else_edge: Edge,
};

pub const TailCall = struct {
    callee: ValueId,
    args: OperandRange = .{},
    result_count: u8 = 1,
    self_target: FunctionId = .invalid,
};

pub const Terminator = union(enum) {
    none,
    jump: Edge,
    branch: Branch,
    return_values: OperandRange,
    raise: ValueId,
    tail_call: TailCall,
};

fn operationResultCount(operation: Operation) u8 {
    return switch (operation) {
        .literal, .quote, .local_read, .global_read, .arithmetic, .make_closure, .ns_push => 1,
        .primitive_call => |call| call.result_count,
        .dynamic_call => |call| call.result_count,
        .direct_call => |call| call.result_count,
        .global_write, .try_begin, .try_end, .ns_pop => 0,
    };
}

pub const Node = struct {
    id: BoundNodeId,
    function: FunctionId,
    block: BlockId,
    result: ValueId = .invalid,
    operation: Operation,
    source: SourceUnit.Ref = .{},
    source_index: u32 = invalid_index,

    pub fn resultCount(self: Node) u8 {
        return operationResultCount(self.operation);
    }
};

pub const Block = struct {
    id: BlockId,
    function: FunctionId,
    param_start: u32 = 0,
    param_count: u32 = 0,
    node_start: u32 = 0,
    node_count: u32 = 0,
    terminator: Terminator = .none,
    handler: HandlerId = .invalid,
};

pub const Handler = struct {
    id: HandlerId,
    function: FunctionId,
    protected: BlockId,
    landing: BlockId,
    exception: ValueId,
};
pub const Origin = struct {
    code: *const Code,
    function: FunctionId,
};

const OriginSet = std.AutoHashMapUnmanaged(Origin, void);

pub const Function = struct {
    id: FunctionId,
    name: ?Symbol = null,
    block_start: u32 = 0,
    block_count: u32 = 0,
    binding_start: u32 = 0,
    binding_count: u32 = 0,
    parameter_start: u32 = 0,
    parameter_count: u32 = 0,
    /// The final formal parameter receives all arguments after the fixed prefix.
    has_rest: bool = false,
    capture_start: u32 = 0,
    capture_count: u32 = 0,
    result_count: u8 = 1,
    /// Module entries terminate evaluation; callable functions return to a caller.
    module_entry: bool = false,
    ad_level: u16 = 0,
    allows_ad: bool = true,
    origin: ?Origin = null,
    source: SourceUnit.Ref = .{},
    source_value: Value = .nil,
    arglist: Value = .nil,
    body: Value = .nil,
};

const ValueDefinition = struct {
    function: FunctionId = .invalid,
    block: BlockId = .invalid,
    position: usize = std.math.maxInt(usize),
};

/// Immutable bound semantic code. The arrays are flat and owned by the same
/// runtime arena as this object. Values in quoted operations remain opaque.
pub const Code = struct {
    id: u32,
    revision: u64,
    functions: []const Function,
    blocks: []const Block,
    function_blocks: []const BlockId,
    nodes: []const Node,
    block_nodes: []const BoundNodeId,
    values: []const FunctionId,
    block_parameters: []const ValueId,
    operands: []const ValueId,
    bindings: []const Binding,
    function_bindings: []const BindingId = &.{},
    captures: []const BindingId,
    capture_values: []const ValueId,
    parameters: []const BindingId,
    globals: []const GlobalCell,
    handlers: []const Handler,
    owner: ?*const anyopaque = null,

    pub fn function(self: *const Code, id: FunctionId) ?*const Function {
        const index = @intFromEnum(id);
        if (index >= self.functions.len) return null;
        return &self.functions[index];
    }

    fn validateOrigin(
        self: *const Code,
        scratch: Allocator,
        function_info: Function,
        seen: *OriginSet,
        context: ?*const EvalContext,
    ) Error!void {
        seen.clearRetainingCapacity();
        try seen.put(scratch, .{ .code = self, .function = function_info.id }, {});
        var expected_owner = self.owner;
        if (expected_owner == null) {
            if (context) |active| expected_owner = @as(?*const anyopaque, active.runtime);
        }
        var current = function_info.origin;
        var depth: usize = 0;
        while (current) |origin| {
            try contextChargeWork(context, 1);
            if (depth >= max_origin_depth) return error.InvalidCode;
            if (origin.code == self) return error.InvalidCode;
            const owner = origin.code.owner orelse return error.InvalidCode;
            if (expected_owner) |expected| {
                if (owner != expected) return error.InvalidCode;
            } else {
                return error.InvalidCode;
            }
            if (seen.contains(origin)) return error.InvalidCode;
            try seen.put(scratch, origin, {});
            const parent = origin.code.function(origin.function) orelse return error.InvalidCode;
            current = parent.origin;
            depth += 1;
        }
    }

    pub fn functionNodeCount(self: *const Code, id: FunctionId) ?usize {
        const function_info = self.function(id) orelse return null;
        const block_end = checkedEnd(function_info.block_start, function_info.block_count) catch return null;
        if (block_end > self.function_blocks.len) return null;
        const block_start: usize = function_info.block_start;
        var count: usize = 0;
        for (self.function_blocks[block_start..block_end]) |block_id| {
            const block = self.getBlock(block_id) orelse return null;
            count = std.math.add(usize, count, @as(usize, block.node_count)) catch return null;
            switch (block.terminator) {
                .none => {},
                else => count = std.math.add(usize, count, 1) catch return null,
            }
        }
        return count;
    }

    pub fn validate(self: *const Code, scratch: Allocator, context: ?*const EvalContext) Error!void {
        self.validateUnchecked(scratch, context) catch |err| {
            return contextError(context, err);
        };
    }

    fn validateUnchecked(self: *const Code, scratch: Allocator, context: ?*const EvalContext) Error!void {
        try contextCheck(context);
        try contextCheckDepth(context, 0);
        if (self.functions.len == 0) return error.InvalidCode;
        if (self.functions.len > @as(usize, invalid_index) or
            self.blocks.len > @as(usize, invalid_index) or
            self.function_blocks.len > @as(usize, invalid_index) or
            self.nodes.len > @as(usize, invalid_index) or
            self.block_nodes.len > @as(usize, invalid_index) or
            self.values.len > @as(usize, invalid_index) or
            self.block_parameters.len > @as(usize, invalid_index) or
            self.operands.len > @as(usize, invalid_index) or
            self.bindings.len > @as(usize, invalid_index) or
            self.function_bindings.len > @as(usize, invalid_index) or
            self.captures.len > @as(usize, invalid_index) or
            self.capture_values.len > @as(usize, invalid_index) or
            self.parameters.len > @as(usize, invalid_index) or
            self.globals.len > @as(usize, invalid_index) or
            self.handlers.len > @as(usize, invalid_index))
        {
            return error.InvalidCode;
        }
        if (self.function_blocks.len != self.blocks.len or
            self.function_bindings.len != self.bindings.len or
            self.block_nodes.len != self.nodes.len or
            self.capture_values.len != self.captures.len)
        {
            return error.InvalidCode;
        }
        try contextChargeWork(context, self.functions.len);
        try contextChargeWork(context, self.blocks.len);
        try contextChargeWork(context, self.function_blocks.len);
        try contextChargeNodes(context, self.nodes.len);
        try contextChargeWork(context, self.block_nodes.len);
        try contextChargeWork(context, self.values.len);
        try contextChargeWork(context, self.block_parameters.len);
        try contextChargeWork(context, self.operands.len);
        try contextChargeWork(context, self.bindings.len);
        try contextChargeWork(context, self.function_bindings.len);
        try contextChargeWork(context, self.captures.len);
        try contextChargeWork(context, self.capture_values.len);
        try contextChargeWork(context, self.parameters.len);
        try contextChargeWork(context, self.globals.len);
        try contextChargeWork(context, self.handlers.len);

        const block_owner = try scratch.alloc(FunctionId, self.blocks.len);
        defer scratch.free(block_owner);
        @memset(block_owner, .invalid);
        const node_owner = try scratch.alloc(BlockId, self.nodes.len);
        defer scratch.free(node_owner);
        @memset(node_owner, .invalid);
        const node_positions = try scratch.alloc(usize, self.nodes.len);
        defer scratch.free(node_positions);
        const binding_owner = try scratch.alloc(FunctionId, self.bindings.len);
        defer scratch.free(binding_owner);
        @memset(binding_owner, .invalid);
        const parameter_membership = try scratch.alloc(bool, self.parameters.len);
        defer scratch.free(parameter_membership);
        @memset(parameter_membership, false);
        const capture_membership = try scratch.alloc(bool, self.captures.len);
        defer scratch.free(capture_membership);
        @memset(capture_membership, false);
        const capture_value_membership = try scratch.alloc(bool, self.capture_values.len);
        defer scratch.free(capture_value_membership);
        @memset(capture_value_membership, false);
        const block_parameter_membership = try scratch.alloc(bool, self.block_parameters.len);
        defer scratch.free(block_parameter_membership);
        @memset(block_parameter_membership, false);
        const definitions = try scratch.alloc(ValueDefinition, self.values.len);
        defer scratch.free(definitions);
        for (definitions) |*definition| definition.* = .{};
        const entry_blocks = try scratch.alloc(BlockId, self.functions.len);
        defer scratch.free(entry_blocks);
        @memset(entry_blocks, .invalid);
        var origins: OriginSet = .empty;
        defer origins.deinit(scratch);

        for (self.functions, 0..) |function_info, function_index| {
            if (@intFromEnum(function_info.id) != function_index) return error.InvalidCode;
            if (function_info.result_count == 0) return error.InvalidCode;
            if (function_info.module_entry and (function_index != 0 or
                function_info.result_count != 1 or function_info.parameter_count != 0 or
                function_info.capture_count != 0)) return error.InvalidCode;
            if (function_info.block_count == 0) return error.InvalidCode;
            try self.validateOrigin(scratch, function_info, &origins, context);

            const block_start: usize = function_info.block_start;
            const block_end = try checkedEnd(function_info.block_start, function_info.block_count);
            if (block_end > self.function_blocks.len) return error.InvalidCode;
            entry_blocks[function_index] = self.function_blocks[block_start];
            for (self.function_blocks[block_start..block_end]) |block_id| {
                const block_index = @intFromEnum(block_id);
                if (block_index >= self.blocks.len) return error.InvalidCode;
                if (block_owner[block_index] != .invalid) return error.InvalidCode;
                block_owner[block_index] = function_info.id;
            }

            const binding_start: usize = function_info.binding_start;
            const binding_end = try checkedEnd(function_info.binding_start, function_info.binding_count);
            if (binding_end > self.function_bindings.len) return error.InvalidCode;
            for (self.function_bindings[binding_start..binding_end]) |binding_id| {
                const binding_index = @intFromEnum(binding_id);
                if (binding_index >= self.bindings.len) return error.InvalidCode;
                if (binding_owner[binding_index] != .invalid) return error.InvalidCode;
                binding_owner[binding_index] = function_info.id;
            }

            const parameter_start: usize = function_info.parameter_start;
            const parameter_end = try checkedEnd(function_info.parameter_start, function_info.parameter_count);
            if (parameter_end > self.parameters.len) return error.InvalidCode;
            for (parameter_start..parameter_end) |index| {
                if (parameter_membership[index]) return error.InvalidCode;
                parameter_membership[index] = true;
            }
            const capture_start: usize = function_info.capture_start;
            const capture_end = try checkedEnd(function_info.capture_start, function_info.capture_count);
            if (capture_end > self.captures.len) return error.InvalidCode;
            if (capture_end > self.capture_values.len) return error.InvalidCode;
            for (capture_start..capture_end) |index| {
                if (capture_membership[index] or capture_value_membership[index]) return error.InvalidCode;
                capture_membership[index] = true;
                capture_value_membership[index] = true;
            }
        }
        for (parameter_membership) |member| {
            if (!member) return error.InvalidCode;
        }
        for (capture_membership) |member| {
            if (!member) return error.InvalidCode;
        }
        for (capture_value_membership) |member| {
            if (!member) return error.InvalidCode;
        }

        for (block_owner) |owner| {
            if (owner == .invalid) return error.InvalidCode;
        }
        for (binding_owner) |owner| {
            if (owner == .invalid) return error.InvalidCode;
        }

        for (self.blocks, 0..) |block, block_index| {
            if (@intFromEnum(block.id) != block_index) return error.InvalidCode;
            if (@intFromEnum(block.function) >= self.functions.len) return error.InvalidCode;
            if (block.handler != .invalid) {
                const handler_index = @intFromEnum(block.handler);
                if (handler_index >= self.handlers.len) return error.InvalidCode;
                if (self.handlers[handler_index].protected != block.id) return error.InvalidCode;
            }
            const parameter_start: usize = block.param_start;
            const parameter_end = try checkedEnd(block.param_start, block.param_count);
            if (parameter_end > self.block_parameters.len) return error.InvalidCode;
            const node_start: usize = block.node_start;
            const node_end = try checkedEnd(block.node_start, block.node_count);
            if (node_end > self.block_nodes.len) return error.InvalidCode;
            for (self.block_nodes[node_start..node_end], 0..) |node_id, position| {
                const node_index = @intFromEnum(node_id);
                if (node_index >= self.nodes.len) return error.InvalidCode;
                if (node_owner[node_index] != .invalid) return error.InvalidCode;
                node_owner[node_index] = block.id;
                node_positions[node_index] = position + 1;
            }
            for (self.block_parameters[parameter_start..parameter_end], 0..) |value, offset| {
                if (block_parameter_membership[parameter_start + offset]) return error.InvalidCode;
                block_parameter_membership[parameter_start + offset] = true;
                try self.defineValue(
                    definitions,
                    value,
                    block.function,
                    block.id,
                    0,
                );
            }
            try self.validateTerminatorShape(block.terminator, block.function);
        }
        for (block_parameter_membership) |member| {
            if (!member) return error.InvalidCode;
        }
        for (node_owner) |owner| {
            if (owner == .invalid) return error.InvalidCode;
        }
        for (self.bindings, 0..) |binding, binding_index| {
            if (@intFromEnum(binding.id) != binding_index) return error.InvalidCode;
            const function_index = @intFromEnum(binding.function);
            if (function_index >= self.functions.len) return error.InvalidCode;
            if (binding_owner[binding_index] != binding.function) return error.InvalidCode;
            if (binding.value == .invalid or @intFromEnum(binding.value) >= self.values.len or
                self.values[@intFromEnum(binding.value)] != binding.function)
            {
                return error.InvalidCode;
            }
        }

        for (self.functions) |function_info| {
            const parameter_end = try checkedEnd(function_info.parameter_start, function_info.parameter_count);
            const parameter_start: usize = function_info.parameter_start;
            for (self.parameters[parameter_start..parameter_end], 0..) |binding_id, index| {
                const binding_index = @intFromEnum(binding_id);
                if (binding_index >= self.bindings.len) return error.InvalidCode;
                const binding = self.bindings[binding_index];
                if (binding.function != function_info.id or binding.kind != .parameter) {
                    return error.InvalidCode;
                }
                try self.defineValue(
                    definitions,
                    binding.value,
                    function_info.id,
                    entry_blocks[@intFromEnum(function_info.id)],
                    0,
                );
                for (self.parameters[parameter_start .. parameter_start + index]) |previous| {
                    try contextChargeWork(context, 1);
                    if (previous == binding_id) return error.InvalidCode;
                }
            }

            const capture_end = try checkedEnd(function_info.capture_start, function_info.capture_count);
            const capture_start: usize = function_info.capture_start;
            for (self.captures[capture_start..capture_end], 0..) |binding_id, index| {
                const binding_index = @intFromEnum(binding_id);
                if (binding_index >= self.bindings.len) return error.InvalidCode;
                const binding = self.bindings[binding_index];
                if (binding.function == function_info.id) return error.InvalidCode;
                const capture_value = self.capture_values[capture_start + index];
                if (@intFromEnum(capture_value) >= self.values.len) return error.InvalidCode;
                try self.defineValue(
                    definitions,
                    capture_value,
                    function_info.id,
                    entry_blocks[@intFromEnum(function_info.id)],
                    0,
                );
                for (self.captures[capture_start .. capture_start + index]) |previous| {
                    try contextChargeWork(context, 1);
                    if (previous == binding_id) return error.InvalidCode;
                }
            }
        }

        for (self.globals, 0..) |global, index| {
            if (@intFromEnum(global.id) != index) return error.InvalidCode;
            if (global.binding != .invalid) {
                const binding_index = @intFromEnum(global.binding);
                if (binding_index >= self.bindings.len) return error.InvalidCode;
                const binding = self.bindings[binding_index];
                if (binding.name != global.name) return error.InvalidCode;
                if (binding.kind != .let and binding.kind != .definition) return error.InvalidCode;
            }
        }
        for (self.handlers, 0..) |handler, index| {
            if (@intFromEnum(handler.id) != index) return error.InvalidCode;
            if (@intFromEnum(handler.function) >= self.functions.len) return error.InvalidCode;
            const protected = self.getBlock(handler.protected) orelse return error.InvalidCode;
            const landing = self.getBlock(handler.landing) orelse return error.InvalidCode;
            if (protected.function != handler.function or landing.function != handler.function) {
                return error.InvalidCode;
            }
            const landing_param_start: usize = landing.param_start;
            const landing_end = try checkedEnd(landing.param_start, landing.param_count);
            if (landing_end > self.block_parameters.len) return error.InvalidCode;
            if (landing.param_count != 1) return error.InvalidCode;
            if (self.block_parameters[landing_param_start] != handler.exception) return error.InvalidCode;
            if (@intFromEnum(handler.exception) >= self.values.len) return error.InvalidCode;
        }
        for (self.bindings) |binding| {
            if (binding.kind != .handler) continue;
            const value_index = @intFromEnum(binding.value);
            if (value_index >= definitions.len) return error.InvalidCode;
            const definition = definitions[value_index];
            var matches_handler = false;
            for (self.handlers) |handler| {
                if (handler.function == binding.function and handler.exception == binding.value and
                    handler.landing == definition.block)
                {
                    matches_handler = true;
                    break;
                }
            }
            if (!matches_handler) return error.InvalidCode;
        }

        for (self.nodes, 0..) |node, node_index| {
            if (@intFromEnum(node.id) != node_index) return error.InvalidCode;
            const block = self.getBlock(node.block) orelse return error.InvalidCode;
            if (node_owner[node_index] != node.block) return error.InvalidCode;
            if (node.function != block.function) return error.InvalidCode;
            const result_count = node.resultCount();
            if (result_count == 0) {
                if (node.result != .invalid) return error.InvalidCode;
            } else {
                if (node.result == .invalid) return error.InvalidCode;
                const result_end = std.math.add(
                    usize,
                    @intFromEnum(node.result),
                    @as(usize, result_count),
                ) catch return error.InvalidCode;
                if (result_end > self.values.len) return error.InvalidCode;
                var result = node.result;
                var result_index: usize = 0;
                while (result_index < @as(usize, result_count)) : (result_index += 1) {
                    const value_index = @intFromEnum(result);
                    if (value_index >= self.values.len) return error.InvalidCode;
                    if (self.values[value_index] != node.function) return error.InvalidCode;
                    try self.defineValue(
                        definitions,
                        result,
                        node.function,
                        node.block,
                        node_positions[node_index],
                    );
                    result = @enumFromInt(value_index + 1);
                }
            }
            try self.validateOperationShape(node.operation, node.function, node.block, context);
        }

        for (definitions) |definition| {
            if (definition.function == .invalid) return error.InvalidCode;
        }

        const predecessor_counts = try scratch.alloc(usize, self.blocks.len);
        defer scratch.free(predecessor_counts);
        @memset(predecessor_counts, 0);
        for (self.blocks) |block| {
            switch (block.terminator) {
                .jump => |edge| try self.countPredecessor(predecessor_counts, edge.target, context),
                .branch => |branch| {
                    try self.countPredecessor(predecessor_counts, branch.then_edge.target, context);
                    try self.countPredecessor(predecessor_counts, branch.else_edge.target, context);
                },
                .none => return error.InvalidCode,
                .return_values, .raise, .tail_call => {},
            }
        }
        for (self.handlers) |handler| {
            try self.countPredecessor(predecessor_counts, handler.landing, context);
        }
        const predecessor_offset_len = std.math.add(usize, self.blocks.len, 1) catch return error.InvalidCode;
        const predecessor_offsets = try scratch.alloc(usize, predecessor_offset_len);
        defer scratch.free(predecessor_offsets);
        predecessor_offsets[0] = 0;
        for (predecessor_counts, 0..) |count, index| {
            predecessor_offsets[index + 1] = std.math.add(usize, predecessor_offsets[index], count) catch
                return error.InvalidCode;
        }
        const predecessors = try scratch.alloc(BlockId, predecessor_offsets[self.blocks.len]);
        defer scratch.free(predecessors);
        const predecessor_cursor = try scratch.alloc(usize, self.blocks.len);
        defer scratch.free(predecessor_cursor);
        @memcpy(predecessor_cursor, predecessor_offsets[0..self.blocks.len]);
        for (self.blocks) |block| {
            switch (block.terminator) {
                .jump => |edge| {
                    predecessors[predecessor_cursor[@intFromEnum(edge.target)]] = block.id;
                    predecessor_cursor[@intFromEnum(edge.target)] += 1;
                },
                .branch => |branch| {
                    predecessors[predecessor_cursor[@intFromEnum(branch.then_edge.target)]] = block.id;
                    predecessor_cursor[@intFromEnum(branch.then_edge.target)] += 1;
                    predecessors[predecessor_cursor[@intFromEnum(branch.else_edge.target)]] = block.id;
                    predecessor_cursor[@intFromEnum(branch.else_edge.target)] += 1;
                },
                else => {},
            }
        }
        for (self.handlers) |handler| {
            const landing_index = @intFromEnum(handler.landing);
            predecessors[predecessor_cursor[landing_index]] = handler.protected;
            predecessor_cursor[landing_index] += 1;
        }
        const idom = try scratch.alloc(BlockId, self.blocks.len);
        defer scratch.free(idom);
        @memset(idom, .invalid);
        for (self.functions) |function_info| {
            const block_start: usize = function_info.block_start;
            const block_end = try checkedEnd(function_info.block_start, function_info.block_count);
            const blocks = self.function_blocks[block_start..block_end];
            const entry = blocks[0];
            idom[@intFromEnum(entry)] = entry;
            for (blocks[1..]) |block_id| {
                if (predecessor_offsets[@intFromEnum(block_id)] ==
                    predecessor_offsets[@intFromEnum(block_id) + 1])
                {
                    idom[@intFromEnum(block_id)] = block_id;
                }
            }
            var pass: usize = 0;
            var changed = true;
            while (changed and pass <= blocks.len) : (pass += 1) {
                try contextChargeWork(context, blocks.len);
                changed = false;
                for (blocks[1..]) |block_id| {
                    const pred_first = predecessor_offsets[@intFromEnum(block_id)];
                    const pred_last = predecessor_offsets[@intFromEnum(block_id) + 1];
                    var candidate: BlockId = .invalid;
                    for (predecessors[pred_first..pred_last]) |predecessor| {
                        try contextChargeWork(context, 1);
                        if (idom[@intFromEnum(predecessor)] != .invalid) {
                            candidate = predecessor;
                            break;
                        }
                    }
                    if (candidate == .invalid) continue;
                    for (predecessors[pred_first..pred_last]) |predecessor| {
                        try contextChargeWork(context, 1);
                        if (idom[@intFromEnum(predecessor)] == .invalid) continue;
                        candidate = try intersectDominators(
                            idom,
                            candidate,
                            predecessor,
                            blocks.len,
                            context,
                        );
                        if (candidate == .invalid) break;
                    }
                    if (idom[@intFromEnum(block_id)] != candidate) {
                        idom[@intFromEnum(block_id)] = candidate;
                        changed = true;
                    }
                }
            }
            for (blocks) |block_id| {
                if (idom[@intFromEnum(block_id)] == .invalid) return error.InvalidCode;
            }
        }

        for (self.functions) |function_info| {
            const block_start: usize = function_info.block_start;
            const block_end = try checkedEnd(function_info.block_start, function_info.block_count);
            for (self.function_blocks[block_start..block_end]) |block_id| {
                const block = &self.blocks[@intFromEnum(block_id)];
                const node_start: usize = block.node_start;
                const node_end = try checkedEnd(block.node_start, block.node_count);
                for (self.block_nodes[node_start..node_end], 0..) |node_id, position| {
                    const node = self.nodes[@intFromEnum(node_id)];
                    try self.validateOperationUses(
                        node.operation,
                        node.function,
                        node.block,
                        position + 1,
                        definitions,
                        idom,
                        context,
                    );
                }
                try self.validateTerminatorUses(
                    block.terminator,
                    function_info,
                    block.id,
                    @as(usize, block.node_count) + 1,
                    definitions,
                    idom,
                    context,
                );
            }
        }
        try ScopeChecker.validate(self, scratch, context);
    }

    const ScopeChecker = struct {
        const State = struct {
            handler: HandlerId = .invalid,
            namespace_depth: u32 = 0,
        };

        code: *const Code,
        incoming: []?State,
        parents: []?HandlerId,
        queue: []BlockId,
        queue_len: usize = 0,
        context: ?*const EvalContext = null,

        fn validate(code: *const Code, scratch: Allocator, context: ?*const EvalContext) Error!void {
            try contextCheck(context);
            const incoming = try scratch.alloc(?State, code.blocks.len);
            defer scratch.free(incoming);
            @memset(incoming, null);
            const parents = try scratch.alloc(?HandlerId, code.handlers.len);
            defer scratch.free(parents);
            @memset(parents, null);
            const queue = try scratch.alloc(BlockId, code.blocks.len);
            defer scratch.free(queue);
            var checker: ScopeChecker = .{
                .code = code,
                .incoming = incoming,
                .parents = parents,
                .queue = queue,
                .context = context,
            };
            for (code.functions) |function_info| {
                try checker.enqueue(code.function_blocks[function_info.block_start], .{});
            }
            var cursor: usize = 0;
            while (cursor < checker.queue_len) : (cursor += 1) {
                try checker.visit(checker.queue[cursor]);
            }
            for (incoming) |state| {
                try contextChargeWork(context, 1);
                if (state == null) return error.InvalidCode;
            }
        }
        fn enqueue(self: *ScopeChecker, block: BlockId, state: State) Error!void {
            try contextChargeWork(self.context, 1);
            const index = @intFromEnum(block);
            if (index >= self.incoming.len) return error.InvalidCode;
            if (self.incoming[index]) |existing| {
                if (existing.handler != state.handler or existing.namespace_depth != state.namespace_depth) {
                    return error.InvalidCode;
                }
                return;
            }
            if (self.queue_len >= self.queue.len) return error.InvalidCode;
            self.incoming[index] = state;
            self.queue[self.queue_len] = block;
            self.queue_len += 1;
        }

        fn visit(self: *ScopeChecker, block_id: BlockId) Error!void {
            try contextChargeWork(self.context, 1);
            const block = self.code.blocks[@intFromEnum(block_id)];
            var state = self.incoming[@intFromEnum(block_id)] orelse unreachable;
            for (self.code.block_nodes[block.node_start..][0..block.node_count]) |node_id| {
                try contextChargeWork(self.context, 1);
                switch (self.code.nodes[@intFromEnum(node_id)].operation) {
                    .try_begin => |handler_id| {
                        const index = @intFromEnum(handler_id);
                        if (self.parents[index]) |parent| {
                            if (parent != state.handler) return error.InvalidCode;
                        } else self.parents[index] = state.handler;
                        try self.enqueue(self.code.handlers[index].landing, state);
                        state.handler = handler_id;
                    },
                    .try_end => {
                        if (state.handler == .invalid) return error.InvalidCode;
                        state.handler = self.parents[@intFromEnum(state.handler)] orelse return error.InvalidCode;
                    },
                    .ns_push => {
                        state.namespace_depth = std.math.add(u32, state.namespace_depth, 1) catch
                            return error.InvalidCode;
                    },
                    .ns_pop => {
                        if (state.namespace_depth == 0) return error.InvalidCode;
                        state.namespace_depth -= 1;
                    },
                    else => {},
                }
            }
            switch (block.terminator) {
                .jump => |edge| try self.enqueue(edge.target, state),
                .branch => |branch| {
                    try self.enqueue(branch.then_edge.target, state);
                    try self.enqueue(branch.else_edge.target, state);
                },
                .return_values, .tail_call => if (state.handler != .invalid) return error.InvalidCode,
                .raise => {},
                .none => return error.InvalidCode,
            }
        }
    };

    fn defineValue(
        self: *const Code,
        definitions: []ValueDefinition,
        value: ValueId,
        function_id: FunctionId,
        block: BlockId,
        position: usize,
    ) Error!void {
        _ = self;
        const index = @intFromEnum(value);
        if (index >= definitions.len or value == .invalid) return error.InvalidCode;
        if (definitions[index].function != .invalid) return error.InvalidCode;
        definitions[index] = .{ .function = function_id, .block = block, .position = position };
    }

    fn validateOperationShape(
        self: *const Code,
        operation: Operation,
        function_id: FunctionId,
        block: BlockId,
        context: ?*const EvalContext,
    ) Error!void {
        switch (operation) {
            .literal, .quote, .try_end, .ns_push, .ns_pop => {},
            .try_begin => |handler_id| {
                const index = @intFromEnum(handler_id);
                if (index >= self.handlers.len) return error.InvalidCode;
                const handler = self.handlers[index];
                if (handler.function != function_id or handler.protected != block) return error.InvalidCode;
            },
            .local_read => |binding_id| {
                const index = @intFromEnum(binding_id);
                if (index >= self.bindings.len) return error.InvalidCode;
                const binding = self.bindings[index];
                if (binding.function != function_id and
                    !(try self.functionCapturesBinding(function_id, binding_id, context)))
                {
                    return error.InvalidCode;
                }
            },
            .global_read => |global_id| {
                if (@intFromEnum(global_id) >= self.globals.len) return error.InvalidCode;
            },
            .global_write => |write| {
                if (@intFromEnum(write.cell) >= self.globals.len) return error.InvalidCode;
                if (write.value == .invalid or @intFromEnum(write.value) >= self.values.len) {
                    return error.InvalidCode;
                }
            },
            .primitive_call => |call| {
                if (call.result_count == 0) return error.InvalidCode;
                try self.validateRangeShape(call.args);
            },
            .arithmetic => |arith| {
                if (@intFromEnum(arith.left) >= self.values.len or @intFromEnum(arith.right) >= self.values.len) {
                    return error.InvalidCode;
                }
                if (arith.callee == .invalid) {
                    if (!arith.expected_callee.isNil()) return error.InvalidCode;
                } else if (@intFromEnum(arith.callee) >= self.values.len or arith.expected_callee.isNil()) {
                    return error.InvalidCode;
                }
            },
            .dynamic_call => |call| {
                if (call.result_count == 0) return error.InvalidCode;
                if (call.callee == .invalid or @intFromEnum(call.callee) >= self.values.len) {
                    return error.InvalidCode;
                }
                try self.validateRangeShape(call.args);
                try self.validateSelfTarget(function_id, call.self_target, call.args);
            },
            .direct_call => |call| {
                if (call.result_count == 0) return error.InvalidCode;
                const target = self.function(call.function) orelse return error.InvalidCode;
                if (call.result_count != target.result_count) return error.InvalidCode;
                if (!validCallArity(target, call.args.len)) return error.InvalidCode;
                if (call.function != function_id and target.capture_count != 0) return error.InvalidCode;
                try self.validateRangeShape(call.args);
            },
            .make_closure => |closure| {
                const target = self.function(closure.function) orelse return error.InvalidCode;
                if (closure.captures.len != target.capture_count) return error.InvalidCode;
                try self.validateRangeShape(closure.captures);
            },
        }
    }

    fn validCallArity(function_info: *const Function, count: u32) bool {
        if (!function_info.has_rest) return count == function_info.parameter_count;
        return function_info.parameter_count != 0 and count >= function_info.parameter_count - 1;
    }

    fn validateSelfTarget(
        self: *const Code,
        function_id: FunctionId,
        target: FunctionId,
        args: OperandRange,
    ) Error!void {
        if (target == .invalid) return;
        if (target != function_id) return error.InvalidCode;
        const function_info = self.function(function_id) orelse return error.InvalidCode;
        if (!validCallArity(function_info, args.len)) return error.InvalidCode;
    }

    fn validateTerminatorShape(
        self: *const Code,
        term: Terminator,
        function_id: FunctionId,
    ) Error!void {
        switch (term) {
            .none => return error.InvalidCode,
            .jump => |edge| try self.validateEdgeShape(edge, function_id),
            .branch => |branch| {
                if (branch.condition == .invalid or @intFromEnum(branch.condition) >= self.values.len) {
                    return error.InvalidCode;
                }
                try self.validateEdgeShape(branch.then_edge, function_id);
                try self.validateEdgeShape(branch.else_edge, function_id);
            },
            .return_values => |values| {
                const function_info = self.function(function_id) orelse return error.InvalidCode;
                if (values.len != @as(u32, function_info.result_count)) return error.InvalidCode;
                try self.validateRangeShape(values);
            },
            .raise => |value| {
                if (value == .invalid or @intFromEnum(value) >= self.values.len) return error.InvalidCode;
            },
            .tail_call => |call| {
                const function_info = self.function(function_id) orelse return error.InvalidCode;
                if (call.result_count == 0 or call.result_count != function_info.result_count) {
                    return error.InvalidCode;
                }
                if (call.callee == .invalid or @intFromEnum(call.callee) >= self.values.len) {
                    return error.InvalidCode;
                }
                try self.validateRangeShape(call.args);
                try self.validateSelfTarget(function_id, call.self_target, call.args);
            },
        }
    }

    fn validateEdgeShape(self: *const Code, edge: Edge, function_id: FunctionId) Error!void {
        const target = self.getBlock(edge.target) orelse return error.InvalidCode;
        if (target.function != function_id) return error.InvalidCode;
        if (edge.args.len != target.param_count) return error.InvalidCode;
        try self.validateRangeShape(edge.args);
    }

    fn validateRangeShape(self: *const Code, range: OperandRange) Error!void {
        const end = try checkedEnd(range.start, range.len);
        if (end > self.operands.len) return error.InvalidCode;
    }

    fn validateOperationUses(
        self: *const Code,
        operation: Operation,
        function_id: FunctionId,
        block: BlockId,
        position: usize,
        definitions: []const ValueDefinition,
        idom: []const BlockId,
        context: ?*const EvalContext,
    ) Error!void {
        switch (operation) {
            .literal, .quote, .global_read, .try_begin, .try_end, .ns_push, .ns_pop => {},
            .local_read => |binding_id| {
                const value = (try self.bindingValue(function_id, binding_id, context)) orelse
                    return error.InvalidCode;
                try self.validateUse(value, function_id, block, position, definitions, idom, context);
            },
            .global_write => |write| try self.validateUse(
                write.value,
                function_id,
                block,
                position,
                definitions,
                idom,
                context,
            ),
            .primitive_call => |call| try self.validateRangeUses(
                call.args,
                function_id,
                block,
                position,
                definitions,
                idom,
                context,
            ),
            .arithmetic => |arith| {
                try self.validateUse(arith.left, function_id, block, position, definitions, idom, context);
                try self.validateUse(arith.right, function_id, block, position, definitions, idom, context);
                if (arith.callee != .invalid) {
                    try self.validateUse(
                        arith.callee,
                        function_id,
                        block,
                        position,
                        definitions,
                        idom,
                        context,
                    );
                }
            },
            .dynamic_call => |call| {
                try self.validateUse(call.callee, function_id, block, position, definitions, idom, context);
                try self.validateRangeUses(
                    call.args,
                    function_id,
                    block,
                    position,
                    definitions,
                    idom,
                    context,
                );
            },
            .direct_call => |call| try self.validateRangeUses(
                call.args,
                function_id,
                block,
                position,
                definitions,
                idom,
                context,
            ),
            .make_closure => |closure| try self.validateRangeUses(
                closure.captures,
                function_id,
                block,
                position,
                definitions,
                idom,
                context,
            ),
        }
    }

    fn validateTerminatorUses(
        self: *const Code,
        term: Terminator,
        function_info: Function,
        block: BlockId,
        position: usize,
        definitions: []const ValueDefinition,
        idom: []const BlockId,
        context: ?*const EvalContext,
    ) Error!void {
        switch (term) {
            .none => return error.InvalidCode,
            .jump => |edge| try self.validateRangeUses(
                edge.args,
                function_info.id,
                block,
                position,
                definitions,
                idom,
                context,
            ),
            .branch => |branch| {
                try self.validateUse(
                    branch.condition,
                    function_info.id,
                    block,
                    position,
                    definitions,
                    idom,
                    context,
                );
                try self.validateRangeUses(
                    branch.then_edge.args,
                    function_info.id,
                    block,
                    position,
                    definitions,
                    idom,
                    context,
                );
                try self.validateRangeUses(
                    branch.else_edge.args,
                    function_info.id,
                    block,
                    position,
                    definitions,
                    idom,
                    context,
                );
            },
            .return_values => |values| try self.validateRangeUses(
                values,
                function_info.id,
                block,
                position,
                definitions,
                idom,
                context,
            ),
            .raise => |value| try self.validateUse(
                value,
                function_info.id,
                block,
                position,
                definitions,
                idom,
                context,
            ),
            .tail_call => |call| {
                try self.validateUse(
                    call.callee,
                    function_info.id,
                    block,
                    position,
                    definitions,
                    idom,
                    context,
                );
                try self.validateRangeUses(
                    call.args,
                    function_info.id,
                    block,
                    position,
                    definitions,
                    idom,
                    context,
                );
            },
        }
    }

    fn bindingValue(
        self: *const Code,
        function_id: FunctionId,
        binding_id: BindingId,
        context: ?*const EvalContext,
    ) Error!?ValueId {
        const binding_index = @intFromEnum(binding_id);
        if (binding_index >= self.bindings.len) return null;
        const binding = self.bindings[binding_index];
        if (binding.function == function_id) return binding.value;
        const function_info = self.function(function_id) orelse return null;
        const capture_start: usize = function_info.capture_start;
        const capture_end = checkedEnd(function_info.capture_start, function_info.capture_count) catch return null;
        for (self.captures[capture_start..capture_end], 0..) |captured, index| {
            try contextChargeWork(context, 1);
            if (captured == binding_id) return self.capture_values[capture_start + index];
        }
        return null;
    }

    fn validateRangeUses(
        self: *const Code,
        range: OperandRange,
        function_id: FunctionId,
        block: BlockId,
        position: usize,
        definitions: []const ValueDefinition,
        idom: []const BlockId,
        context: ?*const EvalContext,
    ) Error!void {
        const start: usize = range.start;
        const end = try checkedEnd(range.start, range.len);
        if (end > self.operands.len) return error.InvalidCode;
        for (self.operands[start..end]) |value| {
            try self.validateUse(value, function_id, block, position, definitions, idom, context);
        }
    }

    fn validateUse(
        self: *const Code,
        value: ValueId,
        function_id: FunctionId,
        block: BlockId,
        position: usize,
        definitions: []const ValueDefinition,
        idom: []const BlockId,
        context: ?*const EvalContext,
    ) Error!void {
        _ = self;
        try contextChargeWork(context, 1);
        const index = @intFromEnum(value);
        if (value == .invalid or index >= definitions.len) return error.InvalidCode;
        const definition = definitions[index];
        if (definition.function != function_id) return error.InvalidCode;
        if (definition.block == block) {
            if (definition.position >= position) return error.InvalidCode;
        } else if (!(try dominates(idom, definition.block, block, context))) {
            return error.InvalidCode;
        }
    }

    fn functionCapturesBinding(
        self: *const Code,
        function_id: FunctionId,
        binding: BindingId,
        context: ?*const EvalContext,
    ) Error!bool {
        const function_info = self.function(function_id) orelse return false;
        const capture_start: usize = function_info.capture_start;
        const capture_end = checkedEnd(function_info.capture_start, function_info.capture_count) catch return false;
        for (self.captures[capture_start..capture_end]) |captured| {
            try contextChargeWork(context, 1);
            if (captured == binding) return true;
        }
        return false;
    }

    fn countPredecessor(
        self: *const Code,
        counts: []usize,
        target: BlockId,
        context: ?*const EvalContext,
    ) Error!void {
        _ = self;
        try contextChargeWork(context, 1);
        const index = @intFromEnum(target);
        if (index >= counts.len) return error.InvalidCode;
        counts[index] = std.math.add(usize, counts[index], 1) catch return error.InvalidCode;
    }

    fn getBlock(self: *const Code, id: BlockId) ?*const Block {
        const index = @intFromEnum(id);
        if (index >= self.blocks.len) return null;
        return &self.blocks[index];
    }
};

fn checkedEnd(start: u32, len: u32) Error!usize {
    if (start == invalid_index) return error.InvalidCode;
    const end = std.math.add(u64, @as(u64, start), @as(u64, len)) catch return error.InvalidCode;
    if (end > @as(u64, invalid_index)) return error.InvalidCode;
    return @intCast(end);
}

fn incrementU32(value: *u32) Error!void {
    if (value.* >= invalid_index - 1) return error.InvalidCode;
    value.* += 1;
}
fn intersectDominators(
    idom: []const BlockId,
    left: BlockId,
    right: BlockId,
    limit: usize,
    context: ?*const EvalContext,
) Error!BlockId {
    var a = left;
    var b = right;
    var a_len = try dominatorDepth(idom, a, limit, context);
    var b_len = try dominatorDepth(idom, b, limit, context);
    while (a != b and a_len > 0 and b_len > 0) {
        try contextChargeWork(context, 1);
        if (a_len > b_len) {
            a = idom[@intFromEnum(a)];
            a_len -= 1;
        } else if (b_len > a_len) {
            b = idom[@intFromEnum(b)];
            b_len -= 1;
        } else {
            a = idom[@intFromEnum(a)];
            b = idom[@intFromEnum(b)];
            a_len -= 1;
            b_len -= 1;
        }
    }
    return if (a == b) a else .invalid;
}

fn dominatorDepth(
    idom: []const BlockId,
    block: BlockId,
    limit: usize,
    context: ?*const EvalContext,
) Error!usize {
    var current = block;
    var depth: usize = 0;
    while (depth <= limit) : (depth += 1) {
        try contextChargeWork(context, 1);
        const parent = idom[@intFromEnum(current)];
        if (parent == .invalid or parent == current) return depth + 1;
        current = parent;
    }
    return 0;
}

fn dominates(
    idom: []const BlockId,
    definition: BlockId,
    use: BlockId,
    context: ?*const EvalContext,
) Error!bool {
    var current = use;
    var steps: usize = 0;
    while (steps <= idom.len) : (steps += 1) {
        try contextChargeWork(context, 1);
        if (current == definition) return true;
        const parent = idom[@intFromEnum(current)];
        if (parent == .invalid or parent == current) return false;
        current = parent;
    }
    return false;
}

pub const Builder = struct {
    allocator: Allocator,
    context: ?*const EvalContext = null,
    id: u32 = 1,
    revision: u64 = 1,
    functions: std.ArrayList(Function) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    function_blocks: std.ArrayList(BlockId) = .empty,
    nodes: std.ArrayList(Node) = .empty,
    block_nodes: std.ArrayList(BoundNodeId) = .empty,
    values: std.ArrayList(FunctionId) = .empty,
    block_parameters: std.ArrayList(ValueId) = .empty,
    operands: std.ArrayList(ValueId) = .empty,
    bindings: std.ArrayList(Binding) = .empty,
    function_bindings: std.ArrayList(BindingId) = .empty,
    captures: std.ArrayList(BindingId) = .empty,
    capture_values: std.ArrayList(ValueId) = .empty,
    parameters: std.ArrayList(BindingId) = .empty,
    globals: std.ArrayList(GlobalCell) = .empty,
    handlers: std.ArrayList(Handler) = .empty,

    pub fn init(allocator: Allocator, context: ?*const EvalContext) Builder {
        return .{ .allocator = allocator, .context = context };
    }

    fn chargeWork(self: *const Builder, count: usize) Error!void {
        try contextChargeWork(self.context, count);
    }

    fn chargeNode(self: *const Builder) Error!void {
        try contextChargeNodes(self.context, 1);
    }

    fn functionIndex(self: *const Builder, function: FunctionId) Error!usize {
        const index = @intFromEnum(function);
        if (index >= self.functions.items.len) return error.InvalidCode;
        return index;
    }

    fn blockIndex(self: *const Builder, block: BlockId) Error!usize {
        const index = @intFromEnum(block);
        if (index >= self.blocks.items.len) return error.InvalidCode;
        return index;
    }

    fn bindingIndex(self: *const Builder, binding: BindingId) Error!usize {
        const index = @intFromEnum(binding);
        if (index >= self.bindings.items.len) return error.InvalidCode;
        return index;
    }

    fn ensureIndexCapacity(length: usize) Error!void {
        if (length >= @as(usize, invalid_index)) return error.InvalidCode;
    }

    fn insertAt(self: *Builder, comptime T: type, list: *std.ArrayList(T), index: usize, value: T) Error!void {
        if (index > list.items.len) return error.InvalidCode;
        try ensureIndexCapacity(list.items.len);
        try list.ensureUnusedCapacity(self.allocator, 1);
        list.items.len += 1;
        var cursor = list.items.len - 1;
        while (cursor > index) : (cursor -= 1) {
            try self.chargeWork(1);
            list.items[cursor] = list.items[cursor - 1];
        }
        list.items[index] = value;
    }

    fn shiftFunctionBlockStarts(self: *Builder, insertion: usize, current: FunctionId) Error!void {
        for (self.functions.items) |*function_info| {
            try self.chargeWork(1);
            if (function_info.id == current) continue;
            if (@as(usize, function_info.block_start) < insertion) continue;
            if (function_info.block_start == invalid_index) return error.InvalidCode;
            try incrementU32(&function_info.block_start);
        }
    }

    fn shiftFunctionBindingStarts(self: *Builder, insertion: usize, current: FunctionId) Error!void {
        for (self.functions.items) |*function_info| {
            try self.chargeWork(1);
            if (function_info.id == current) continue;
            if (@as(usize, function_info.binding_start) < insertion) continue;
            if (function_info.binding_start == invalid_index) return error.InvalidCode;
            try incrementU32(&function_info.binding_start);
        }
    }

    fn shiftFunctionParameterStarts(self: *Builder, insertion: usize, current: FunctionId) Error!void {
        for (self.functions.items) |*function_info| {
            try self.chargeWork(1);
            if (function_info.id == current) continue;
            if (@as(usize, function_info.parameter_start) < insertion) continue;
            if (function_info.parameter_start == invalid_index) return error.InvalidCode;
            try incrementU32(&function_info.parameter_start);
        }
    }

    fn shiftFunctionCaptureStarts(self: *Builder, insertion: usize, current: FunctionId) Error!void {
        for (self.functions.items) |*function_info| {
            try self.chargeWork(1);
            if (function_info.id == current) continue;
            if (@as(usize, function_info.capture_start) < insertion) continue;
            if (function_info.capture_start == invalid_index) return error.InvalidCode;
            try incrementU32(&function_info.capture_start);
        }
    }

    fn shiftBlockNodeStarts(self: *Builder, insertion: usize, current: BlockId) Error!void {
        for (self.blocks.items) |*block| {
            try self.chargeWork(1);
            if (block.id == current) continue;
            if (@as(usize, block.node_start) < insertion) continue;
            if (block.node_start == invalid_index) return error.InvalidCode;
            try incrementU32(&block.node_start);
        }
    }

    fn shiftBlockParameterStarts(self: *Builder, insertion: usize, current: BlockId) Error!void {
        for (self.blocks.items) |*block| {
            try self.chargeWork(1);
            if (block.id == current) continue;
            if (@as(usize, block.param_start) < insertion) continue;
            if (block.param_start == invalid_index) return error.InvalidCode;
            try incrementU32(&block.param_start);
        }
    }

    pub fn addFunction(self: *Builder, name: ?Symbol, source: SourceUnit.Ref) Error!FunctionId {
        try self.chargeWork(1);
        try ensureIndexCapacity(self.functions.items.len);
        try ensureIndexCapacity(self.function_blocks.items.len);
        try ensureIndexCapacity(self.function_bindings.items.len);
        try ensureIndexCapacity(self.parameters.items.len);
        try ensureIndexCapacity(self.captures.items.len);
        const id: FunctionId = @enumFromInt(@as(u32, @intCast(self.functions.items.len)));
        try self.functions.append(self.allocator, .{
            .id = id,
            .name = name,
            .block_start = @intCast(self.function_blocks.items.len),
            .binding_start = @intCast(self.function_bindings.items.len),
            .parameter_start = @intCast(self.parameters.items.len),
            .capture_start = @intCast(self.captures.items.len),
            .source = source,
        });
        return id;
    }

    pub fn addBlock(self: *Builder, function: FunctionId) Error!BlockId {
        try self.chargeWork(1);
        const function_index = try self.functionIndex(function);
        try ensureIndexCapacity(self.blocks.items.len);
        try ensureIndexCapacity(self.block_nodes.items.len);
        const node_start: u32 = @intCast(self.block_nodes.items.len);
        const id: BlockId = @enumFromInt(@as(u32, @intCast(self.blocks.items.len)));
        try self.blocks.append(self.allocator, .{
            .id = id,
            .function = function,
            .node_start = node_start,
        });
        const function_info = &self.functions.items[function_index];
        const insertion = try checkedEnd(function_info.block_start, function_info.block_count);
        try self.shiftFunctionBlockStarts(insertion, function);
        try self.insertAt(BlockId, &self.function_blocks, insertion, id);
        try incrementU32(&function_info.block_count);
        return id;
    }

    pub fn addValue(self: *Builder, function: FunctionId) Error!ValueId {
        try self.chargeWork(1);
        _ = try self.functionIndex(function);
        try ensureIndexCapacity(self.values.items.len);
        const id: ValueId = @enumFromInt(@as(u32, @intCast(self.values.items.len)));
        try self.values.append(self.allocator, function);
        return id;
    }

    pub fn addBinding(
        self: *Builder,
        function: FunctionId,
        name: Symbol,
        kind: BindingKind,
        source: SourceUnit.Ref,
    ) Error!BindingId {
        try self.chargeWork(1);
        const function_index = try self.functionIndex(function);
        try ensureIndexCapacity(self.bindings.items.len);
        const id: BindingId = @enumFromInt(@as(u32, @intCast(self.bindings.items.len)));
        try self.bindings.append(self.allocator, .{
            .id = id,
            .function = function,
            .name = name,
            .kind = kind,
            .source = source,
        });
        const function_info = &self.functions.items[function_index];
        const insertion = try checkedEnd(function_info.binding_start, function_info.binding_count);
        try self.shiftFunctionBindingStarts(insertion, function);
        try self.insertAt(BindingId, &self.function_bindings, insertion, id);
        try incrementU32(&function_info.binding_count);
        return id;
    }

    pub fn addParameter(self: *Builder, function: FunctionId, binding: BindingId) Error!void {
        try self.chargeWork(1);
        const function_index = try self.functionIndex(function);
        const binding_index = try self.bindingIndex(binding);
        if (self.bindings.items[binding_index].function != function) return error.InvalidCode;
        const function_info = &self.functions.items[function_index];
        const insertion = try checkedEnd(function_info.parameter_start, function_info.parameter_count);
        const parameter_start: usize = function_info.parameter_start;
        for (self.parameters.items[parameter_start..insertion]) |existing| {
            try self.chargeWork(1);
            if (existing == binding) return error.InvalidCode;
        }
        try self.shiftFunctionParameterStarts(insertion, function);
        try self.insertAt(BindingId, &self.parameters, insertion, binding);
        try incrementU32(&function_info.parameter_count);
        self.bindings.items[binding_index].kind = .parameter;
    }

    pub fn addCapture(self: *Builder, function: FunctionId, binding: BindingId) Error!ValueId {
        try self.chargeWork(1);
        const function_index = try self.functionIndex(function);
        const binding_index = try self.bindingIndex(binding);
        if (self.bindings.items[binding_index].function == function) return error.InvalidCode;
        const value = try self.addValue(function);
        const function_info = &self.functions.items[function_index];
        const insertion = try checkedEnd(function_info.capture_start, function_info.capture_count);
        const capture_start: usize = function_info.capture_start;
        for (self.captures.items[capture_start..insertion]) |existing| {
            try self.chargeWork(1);
            if (existing == binding) return error.InvalidCode;
        }
        try self.shiftFunctionCaptureStarts(insertion, function);
        try self.insertAt(BindingId, &self.captures, insertion, binding);
        try self.insertAt(ValueId, &self.capture_values, insertion, value);
        try incrementU32(&function_info.capture_count);
        return value;
    }

    pub fn addGlobal(self: *Builder, name: Symbol, source: SourceUnit.Ref) Error!GlobalCellId {
        try self.chargeWork(1);
        for (self.globals.items) |cell| {
            try self.chargeWork(1);
            if (cell.binding == .invalid and cell.name == name) return cell.id;
        }
        try ensureIndexCapacity(self.globals.items.len);
        const id: GlobalCellId = @enumFromInt(@as(u32, @intCast(self.globals.items.len)));
        try self.globals.append(self.allocator, .{ .id = id, .name = name, .source = source });
        return id;
    }

    pub fn addLocalCell(self: *Builder, binding: BindingId, source: SourceUnit.Ref) Error!GlobalCellId {
        try self.chargeWork(1);
        const binding_index = try self.bindingIndex(binding);
        const definition = self.bindings.items[binding_index];
        if (definition.kind != .let and definition.kind != .definition) return error.InvalidCode;
        for (self.globals.items) |cell| {
            try self.chargeWork(1);
            if (cell.binding == binding) return cell.id;
        }
        try ensureIndexCapacity(self.globals.items.len);
        const id: GlobalCellId = @enumFromInt(@as(u32, @intCast(self.globals.items.len)));
        try self.globals.append(self.allocator, .{
            .id = id,
            .name = definition.name,
            .binding = binding,
            .source = source,
        });
        return id;
    }

    pub fn addHandler(
        self: *Builder,
        function: FunctionId,
        protected: BlockId,
        landing: BlockId,
        exception: ValueId,
    ) Error!HandlerId {
        try self.chargeWork(1);
        _ = try self.functionIndex(function);
        const protected_index = try self.blockIndex(protected);
        const landing_index = try self.blockIndex(landing);
        if (self.blocks.items[protected_index].function != function or
            self.blocks.items[landing_index].function != function)
        {
            return error.InvalidCode;
        }
        if (self.blocks.items[protected_index].handler != .invalid) return error.InvalidCode;
        if (@intFromEnum(exception) >= self.values.items.len or
            self.values.items[@intFromEnum(exception)] != function)
        {
            return error.InvalidCode;
        }
        try ensureIndexCapacity(self.handlers.items.len);
        const id: HandlerId = @enumFromInt(@as(u32, @intCast(self.handlers.items.len)));
        try self.handlers.append(self.allocator, .{
            .id = id,
            .function = function,
            .protected = protected,
            .landing = landing,
            .exception = exception,
        });
        self.blocks.items[protected_index].handler = id;
        return id;
    }

    pub fn addOperands(self: *Builder, values: []const ValueId) Error!OperandRange {
        try self.chargeWork(values.len);
        try ensureIndexCapacity(self.operands.items.len);
        try ensureIndexCapacity(values.len);
        const end = std.math.add(usize, self.operands.items.len, values.len) catch return error.InvalidCode;
        try ensureIndexCapacity(end);
        const start: u32 = @intCast(self.operands.items.len);
        try self.operands.appendSlice(self.allocator, values);
        return .{ .start = start, .len = @intCast(values.len) };
    }

    pub fn addBlockParam(self: *Builder, block: BlockId, function: FunctionId) Error!ValueId {
        try self.chargeWork(1);
        const block_index = try self.blockIndex(block);
        _ = try self.functionIndex(function);
        if (self.blocks.items[block_index].function != function) return error.InvalidCode;
        const value = try self.addValue(function);
        const target = &self.blocks.items[block_index];
        const insertion = if (target.param_count == 0)
            self.block_parameters.items.len
        else
            try checkedEnd(target.param_start, target.param_count);
        try ensureIndexCapacity(insertion);
        try self.shiftBlockParameterStarts(insertion, block);
        try self.insertAt(ValueId, &self.block_parameters, insertion, value);
        if (target.param_count == 0) target.param_start = @intCast(insertion);
        try incrementU32(&target.param_count);
        return value;
    }

    pub fn addNode(
        self: *Builder,
        function: FunctionId,
        block: BlockId,
        operation: Operation,
        source: SourceUnit.Ref,
    ) Error!ValueId {
        try self.chargeNode();
        const block_index = try self.blockIndex(block);
        _ = try self.functionIndex(function);
        if (self.blocks.items[block_index].function != function) return error.InvalidCode;
        const result_count = operationResultCount(operation);
        if (result_count > 0) {
            const end = std.math.add(usize, self.values.items.len, @as(usize, result_count)) catch
                return error.InvalidCode;
            try ensureIndexCapacity(end);
        }
        const result = if (result_count == 0) ValueId.invalid else try self.addValue(function);
        if (result_count > 1) {
            var remaining: u8 = result_count - 1;
            while (remaining > 0) : (remaining -= 1) {
                try self.chargeWork(1);
                _ = try self.addValue(function);
            }
        }
        try ensureIndexCapacity(self.nodes.items.len);
        const id: BoundNodeId = @enumFromInt(@as(u32, @intCast(self.nodes.items.len)));
        try self.nodes.append(self.allocator, .{
            .id = id,
            .function = function,
            .block = block,
            .result = result,
            .operation = operation,
            .source = source,
        });
        const target = &self.blocks.items[block_index];
        const insertion = if (target.node_count == 0)
            self.block_nodes.items.len
        else
            try checkedEnd(target.node_start, target.node_count);
        try ensureIndexCapacity(insertion);
        try self.shiftBlockNodeStarts(insertion, block);
        try self.insertAt(BoundNodeId, &self.block_nodes, insertion, id);
        if (target.node_count == 0) target.node_start = @intCast(insertion);
        try incrementU32(&target.node_count);
        return result;
    }

    pub fn lastNodeId(self: *const Builder) ?BoundNodeId {
        if (self.nodes.items.len == 0) return null;
        return @enumFromInt(@as(u32, @intCast(self.nodes.items.len - 1)));
    }

    pub fn setNodeSourceIndex(self: *Builder, node: BoundNodeId, source_index: u32) Error!void {
        try self.chargeWork(1);
        const index = @intFromEnum(node);
        if (index >= self.nodes.items.len) return error.InvalidCode;
        self.nodes.items[index].source_index = source_index;
    }

    pub fn setTerminator(self: *Builder, block: BlockId, term: Terminator) Error!void {
        try self.chargeWork(1);
        const index = try self.blockIndex(block);
        switch (self.blocks.items[index].terminator) {
            .none => {},
            else => return error.InvalidCode,
        }
        self.blocks.items[index].terminator = term;
    }

    pub fn finish(self: *Builder, scratch: Allocator) Error!*Code {
        const code = self.allocator.create(Code) catch |err| {
            return contextError(self.context, err);
        };
        code.* = .{
            .id = self.id,
            .revision = self.revision,
            .functions = &.{},
            .blocks = &.{},
            .function_blocks = &.{},
            .nodes = &.{},
            .block_nodes = &.{},
            .values = &.{},
            .block_parameters = &.{},
            .operands = &.{},
            .bindings = &.{},
            .function_bindings = &.{},
            .captures = &.{},
            .capture_values = &.{},
            .parameters = &.{},
            .globals = &.{},
            .handlers = &.{},
            .owner = if (self.context) |context|
                @as(?*const anyopaque, context.runtime)
            else
                null,
        };
        errdefer {
            self.allocator.free(code.functions);
            self.allocator.free(code.blocks);
            self.allocator.free(code.function_blocks);
            self.allocator.free(code.nodes);
            self.allocator.free(code.block_nodes);
            self.allocator.free(code.values);
            self.allocator.free(code.block_parameters);
            self.allocator.free(code.operands);
            self.allocator.free(code.bindings);
            self.allocator.free(code.function_bindings);
            self.allocator.free(code.captures);
            self.allocator.free(code.capture_values);
            self.allocator.free(code.parameters);
            self.allocator.free(code.globals);
            self.allocator.free(code.handlers);
            self.allocator.destroy(code);
        }
        code.functions = self.functions.toOwnedSlice(self.allocator) catch |err| {
            return contextError(self.context, err);
        };
        code.blocks = self.blocks.toOwnedSlice(self.allocator) catch |err| {
            return contextError(self.context, err);
        };
        code.function_blocks = self.function_blocks.toOwnedSlice(self.allocator) catch |err| {
            return contextError(self.context, err);
        };
        code.nodes = self.nodes.toOwnedSlice(self.allocator) catch |err| {
            return contextError(self.context, err);
        };
        code.block_nodes = self.block_nodes.toOwnedSlice(self.allocator) catch |err| {
            return contextError(self.context, err);
        };
        code.values = self.values.toOwnedSlice(self.allocator) catch |err| {
            return contextError(self.context, err);
        };
        code.block_parameters = self.block_parameters.toOwnedSlice(self.allocator) catch |err| {
            return contextError(self.context, err);
        };
        code.operands = self.operands.toOwnedSlice(self.allocator) catch |err| {
            return contextError(self.context, err);
        };
        code.bindings = self.bindings.toOwnedSlice(self.allocator) catch |err| {
            return contextError(self.context, err);
        };
        code.function_bindings = self.function_bindings.toOwnedSlice(self.allocator) catch |err| {
            return contextError(self.context, err);
        };
        code.captures = self.captures.toOwnedSlice(self.allocator) catch |err| {
            return contextError(self.context, err);
        };
        code.capture_values = self.capture_values.toOwnedSlice(self.allocator) catch |err| {
            return contextError(self.context, err);
        };
        code.parameters = self.parameters.toOwnedSlice(self.allocator) catch |err| {
            return contextError(self.context, err);
        };
        code.globals = self.globals.toOwnedSlice(self.allocator) catch |err| {
            return contextError(self.context, err);
        };
        code.handlers = self.handlers.toOwnedSlice(self.allocator) catch |err| {
            return contextError(self.context, err);
        };
        code.validate(scratch, self.context) catch |err| {
            return contextError(self.context, err);
        };
        return code;
    }
};

test "builder preserves nested membership and genuine multi-result calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var builder = Builder.init(arena.allocator(), null);
    const outer = try builder.addFunction(null, .{});
    const outer_entry = try builder.addBlock(outer);

    const child = try builder.addFunction(null, .{});
    builder.functions.items[@intFromEnum(child)].result_count = 2;
    const child_entry = try builder.addBlock(child);
    const child_first = try builder.addNode(child, child_entry, .{ .literal = .nil }, .{});
    const child_second = try builder.addNode(child, child_entry, .{ .literal = .true }, .{});
    const child_returns = try builder.addOperands(&.{ child_first, child_second });
    try builder.setTerminator(child_entry, .{ .return_values = child_returns });

    builder.functions.items[@intFromEnum(outer)].result_count = 2;
    const outer_exit = try builder.addBlock(outer);
    const exit_first = try builder.addBlockParam(outer_exit, outer);
    const exit_second = try builder.addBlockParam(outer_exit, outer);
    const call_first = try builder.addNode(outer, outer_entry, .{
        .direct_call = .{
            .function = child,
            .result_count = 2,
        },
    }, .{});
    const call_second: ValueId = @enumFromInt(@intFromEnum(call_first) + 1);
    const call_results = try builder.addOperands(&.{ call_first, call_second });
    try builder.setTerminator(outer_entry, .{
        .jump = .{ .target = outer_exit, .args = call_results },
    });
    const outer_returns = try builder.addOperands(&.{ exit_first, exit_second });
    try builder.setTerminator(outer_exit, .{ .return_values = outer_returns });

    const code = try builder.finish(std.testing.allocator);
    const outer_info = code.function(outer) orelse return error.TestUnexpectedResult;
    const outer_block_start: usize = outer_info.block_start;
    const outer_block_end = outer_block_start + @as(usize, outer_info.block_count);
    const outer_blocks = code.function_blocks[outer_block_start..outer_block_end];
    try std.testing.expectEqualSlices(BlockId, &.{ outer_entry, outer_exit }, outer_blocks);
    const child_info = code.function(child) orelse return error.TestUnexpectedResult;
    const child_block_start: usize = child_info.block_start;
    const child_block_end = child_block_start + @as(usize, child_info.block_count);
    const child_blocks = code.function_blocks[child_block_start..child_block_end];
    try std.testing.expectEqualSlices(BlockId, &.{child_entry}, child_blocks);
    const outer_node_start: usize = code.blocks[@intFromEnum(outer_entry)].node_start;
    try std.testing.expectEqual(@as(u8, 2), code.nodes[
        @intFromEnum(
            code.block_nodes[outer_node_start],
        )
    ].resultCount());
    try std.testing.expectEqual(outer, code.values[@intFromEnum(call_second)]);
}

test "validation rejects a branch-join use without a dominating definition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var builder = Builder.init(arena.allocator(), null);
    const function = try builder.addFunction(null, .{});
    const entry = try builder.addBlock(function);
    const then_block = try builder.addBlock(function);
    const else_block = try builder.addBlock(function);
    const join = try builder.addBlock(function);
    const condition = try builder.addNode(function, entry, .{ .literal = .true }, .{});
    try builder.setTerminator(entry, .{ .branch = .{
        .condition = condition,
        .then_edge = .{ .target = then_block },
        .else_edge = .{ .target = else_block },
    } });
    const branch_value = try builder.addNode(
        function,
        then_block,
        .{ .literal = .nil },
        .{},
    );
    try builder.setTerminator(then_block, .{ .jump = .{ .target = join } });
    try builder.setTerminator(else_block, .{ .jump = .{ .target = join } });
    const returns = try builder.addOperands(&.{branch_value});
    try builder.setTerminator(join, .{ .return_values = returns });

    try std.testing.expectError(error.InvalidCode, builder.finish(std.testing.allocator));
}

test "validation rejects branch argument arity mismatches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var builder = Builder.init(arena.allocator(), null);
    const function = try builder.addFunction(null, .{});
    const entry = try builder.addBlock(function);
    const target = try builder.addBlock(function);
    const target_value = try builder.addBlockParam(target, function);
    try builder.setTerminator(entry, .{ .jump = .{ .target = target } });
    const returns = try builder.addOperands(&.{target_value});
    try builder.setTerminator(target, .{ .return_values = returns });

    try std.testing.expectError(error.InvalidCode, builder.finish(std.testing.allocator));
}

test "validation rejects malformed handler exception parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var builder = Builder.init(arena.allocator(), null);
    const function = try builder.addFunction(null, .{});
    const protected = try builder.addBlock(function);
    const landing = try builder.addBlock(function);
    const exception = try builder.addBlockParam(landing, function);
    _ = try builder.addBlockParam(landing, function);
    const handler = try builder.addHandler(function, protected, landing, exception);
    _ = try builder.addNode(function, protected, .{ .try_begin = handler }, .{});
    const raised = try builder.addNode(function, protected, .{ .literal = .nil }, .{});
    try builder.setTerminator(protected, .{ .raise = raised });
    const returns = try builder.addOperands(&.{exception});
    try builder.setTerminator(landing, .{ .return_values = returns });

    try std.testing.expectError(error.InvalidCode, builder.finish(std.testing.allocator));
}

test "validation rejects tail-call result arity mismatches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var builder = Builder.init(arena.allocator(), null);
    const function = try builder.addFunction(null, .{});
    builder.functions.items[@intFromEnum(function)].result_count = 2;
    const entry = try builder.addBlock(function);
    const callee = try builder.addNode(function, entry, .{ .literal = .nil }, .{});
    try builder.setTerminator(entry, .{ .tail_call = .{
        .callee = callee,
        .result_count = 1,
    } });

    try std.testing.expectError(error.InvalidCode, builder.finish(std.testing.allocator));
}

test "validation rejects a binding read before its value definition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var builder = Builder.init(arena.allocator(), null);
    const function = try builder.addFunction(null, .{});
    const entry = try builder.addBlock(function);
    const prefix = try builder.addNode(function, entry, .{ .literal = Value.i64(2) }, .{});
    var name: []const u8 = "later";
    const binding = try builder.addBinding(function, &name, .let, .{});
    const read_before_definition = try builder.addNode(function, entry, .{ .local_read = binding }, .{});
    const later = try builder.addNode(function, entry, .{ .arithmetic = .{
        .op = .add,
        .left = prefix,
        .right = prefix,
    } }, .{});
    builder.bindings.items[@intFromEnum(binding)].value = later;
    const result = try builder.addOperands(&.{read_before_definition});
    try builder.setTerminator(entry, .{ .return_values = result });
    try std.testing.expectError(error.InvalidCode, builder.finish(std.testing.allocator));
}

test "scope pops cannot consume a caller scope" {
    for ([_]Operation{ .try_end, .ns_pop }) |operation| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var builder = Builder.init(arena.allocator(), null);
        const function = try builder.addFunction(null, .{});
        const entry = try builder.addBlock(function);
        _ = try builder.addNode(function, entry, operation, .{});
        const value = try builder.addNode(function, entry, .{ .literal = .nil }, .{});
        try builder.setTerminator(entry, .{ .return_values = try builder.addOperands(&.{value}) });
        try std.testing.expectError(error.InvalidCode, builder.finish(std.testing.allocator));
    }
}

test "control-flow joins require matching namespace depths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var builder = Builder.init(arena.allocator(), null);
    const function = try builder.addFunction(null, .{});
    const entry = try builder.addBlock(function);
    const left = try builder.addBlock(function);
    const right = try builder.addBlock(function);
    const join = try builder.addBlock(function);
    const condition = try builder.addNode(function, entry, .{ .literal = .true }, .{});
    try builder.setTerminator(entry, .{ .branch = .{
        .condition = condition,
        .then_edge = .{ .target = left },
        .else_edge = .{ .target = right },
    } });
    _ = try builder.addNode(function, left, .{ .ns_push = 0 }, .{});
    try builder.setTerminator(left, .{ .jump = .{ .target = join } });
    try builder.setTerminator(right, .{ .jump = .{ .target = join } });
    const value = try builder.addNode(function, join, .{ .literal = .nil }, .{});
    try builder.setTerminator(join, .{ .return_values = try builder.addOperands(&.{value}) });
    try std.testing.expectError(error.InvalidCode, builder.finish(std.testing.allocator));
}
