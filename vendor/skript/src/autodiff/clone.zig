const std = @import("std");
const skript = @import("../root.zig");
const Code = @import("../code.zig");
const Error = skript.Error;

/// Copy a semantic program into an empty builder. Non-value identities retain
/// their indices; value definitions get fresh IDs in builder allocation order.
pub fn append(
    scratch: std.mem.Allocator,
    builder: *Code.Builder,
    source: *const Code.Code,
) Error!void {
    std.debug.assert(builder.functions.items.len == 0);
    std.debug.assert(builder.operands.items.len == 0);
    const values = try scratch.alloc(Code.ValueId, source.values.len);
    defer scratch.free(values);
    @memset(values, .invalid);
    for (source.functions) |function| {
        const id = try builder.addFunction(function.name, function.source);
        std.debug.assert(id == function.id);
        const output = &builder.functions.items[@backingInt(id)];
        output.has_rest = function.has_rest;
        output.result_count = function.result_count;
        output.module_entry = function.module_entry;
        output.ad_level = function.ad_level;
        output.allows_ad = function.allows_ad;
        output.origin = .{ .code = source, .function = function.id };
        output.source_value = function.source_value;
        output.arglist = function.arglist;
        output.body = function.body;
    }
    for (source.bindings) |binding| {
        const id = try builder.addBinding(binding.function, binding.name, binding.kind, binding.source);
        std.debug.assert(id == binding.id);
    }
    for (source.blocks) |block| {
        const id = try builder.addBlock(block.function);
        std.debug.assert(id == block.id);
    }
    try copyInputs(builder, source, values);
    for (source.globals) |global| {
        const id = if (global.binding == .invalid)
            try builder.addGlobal(global.name, global.source)
        else
            try builder.addLocalCell(global.binding, global.source);
        std.debug.assert(id == global.id);
    }
    for (source.handlers, 0..) |handler, index| {
        const exception = try mapped(values, handler.exception);
        const id = try builder.addHandler(handler.function, handler.protected, handler.landing, exception);
        std.debug.assert(@backingInt(id) == index);
    }
    for (source.nodes) |node| {
        const result = try builder.addNode(node.function, node.block, node.operation, node.source);
        const id = builder.lastNodeId() orelse return error.InvalidCode;
        std.debug.assert(id == node.id);
        builder.nodes.items[@backingInt(id)].source_index = node.source_index;
        for (0..node.resultCount()) |index| {
            values[@backingInt(node.result) + index] = @fromBackingInt(@intCast(@backingInt(result) + index));
        }
    }
    for (source.bindings) |binding| {
        builder.bindings.items[@backingInt(binding.id)].value = try mapped(values, binding.value);
    }
    const operands = try scratch.alloc(Code.ValueId, source.operands.len);
    defer scratch.free(operands);
    for (source.operands, operands) |value, *output| output.* = try mapped(values, value);
    const range = try builder.addOperands(operands);
    std.debug.assert(range.start == 0);
    for (source.nodes) |node| {
        builder.nodes.items[@backingInt(node.id)].operation = try remapOperation(values, node.operation);
    }
    for (source.blocks) |block| try builder.setTerminator(block.id, try remapTerminator(values, block.terminator));
}

fn copyInputs(builder: *Code.Builder, source: *const Code.Code, values: []Code.ValueId) Error!void {
    for (source.functions) |function| {
        for (source.parameters[function.parameter_start..][0..function.parameter_count]) |binding| {
            const original = source.bindings[@backingInt(binding)].value;
            values[@backingInt(original)] = try builder.addValue(function.id);
            try builder.addParameter(function.id, binding);
        }
        const start: usize = function.capture_start;
        for (source.captures[start..][0..function.capture_count], 0..) |binding, index| {
            const original = source.capture_values[start + index];
            values[@backingInt(original)] = try builder.addCapture(function.id, binding);
        }
    }
    for (source.blocks) |block| {
        for (source.block_parameters[block.param_start..][0..block.param_count]) |value| {
            values[@backingInt(value)] = try builder.addBlockParam(block.id, block.function);
        }
    }
}

fn mapped(values: []const Code.ValueId, value: Code.ValueId) Error!Code.ValueId {
    if (value == .invalid) return .invalid;
    const index = @backingInt(value);
    if (index >= values.len or values[index] == .invalid) return error.InvalidCode;
    return values[index];
}

fn remapOperation(values: []const Code.ValueId, operation: Code.Operation) Error!Code.Operation {
    var result = operation;
    switch (result) {
        .global_write => |*write| write.value = try mapped(values, write.value),
        .arithmetic => |*arithmetic| {
            arithmetic.left = try mapped(values, arithmetic.left);
            arithmetic.right = try mapped(values, arithmetic.right);
            arithmetic.callee = try mapped(values, arithmetic.callee);
        },
        .dynamic_call => |*call| call.callee = try mapped(values, call.callee),
        .literal,
        .quote,
        .local_read,
        .global_read,
        .primitive_call,
        .direct_call,
        .make_closure,
        .try_begin,
        .try_end,
        .ns_push,
        .ns_pop,
        => {},
    }
    return result;
}

fn remapTerminator(values: []const Code.ValueId, terminator: Code.Terminator) Error!Code.Terminator {
    var result = terminator;
    switch (result) {
        .return_values, .jump => {},
        .branch => |*branch| branch.condition = try mapped(values, branch.condition),
        .raise => |*value| value.* = try mapped(values, value.*),
        .tail_call => |*call| call.callee = try mapped(values, call.callee),
        .none => return error.InvalidCode,
    }
    return result;
}

test "clone preserves variadic function metadata and parameter bindings" {
    const runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    var source_builder = Code.Builder.init(runtime.static, runtime.context());
    const identity = try runtime.allocCodeIdentity();
    source_builder.id = identity.id;
    source_builder.revision = identity.revision;
    const function = try source_builder.addFunction(
        try runtime.store.getsym("variadic-clone"),
        .{},
    );
    const info = &source_builder.functions.items[@backingInt(function)];
    info.has_rest = true;
    info.result_count = 2;
    info.ad_level = 7;
    info.allows_ad = false;
    info.source_value = skript.Value.i64(29);
    info.arglist = skript.Value.i64(31);
    info.body = skript.Value.i64(37);
    const block = try source_builder.addBlock(function);
    const fixed_binding = try source_builder.addBinding(
        function,
        try runtime.store.getsym("fixed"),
        .parameter,
        .{},
    );
    const fixed_value = try source_builder.addValue(function);
    source_builder.bindings.items[@backingInt(fixed_binding)].value = fixed_value;
    try source_builder.addParameter(function, fixed_binding);
    const rest_binding = try source_builder.addBinding(
        function,
        try runtime.store.getsym("rest"),
        .parameter,
        .{},
    );
    const rest_value = try source_builder.addValue(function);
    source_builder.bindings.items[@backingInt(rest_binding)].value = rest_value;
    try source_builder.addParameter(function, rest_binding);
    try source_builder.setTerminator(
        block,
        .{ .return_values = try source_builder.addOperands(&.{ fixed_value, rest_value }) },
    );
    const source = try source_builder.finish(runtime.context().scratch);

    var cloned_builder = Code.Builder.init(runtime.static, runtime.context());
    try append(runtime.context().scratch, &cloned_builder, source);
    const cloned = try cloned_builder.finish(runtime.context().scratch);
    const cloned_info = cloned.function(function) orelse return error.TestUnexpectedResult;
    try std.testing.expect(cloned_info.has_rest);
    try std.testing.expectEqual(@as(u32, 2), cloned_info.parameter_count);
    try std.testing.expectEqual(@as(u8, 2), cloned_info.result_count);
    try std.testing.expectEqual(@as(u16, 7), cloned_info.ad_level);
    try std.testing.expect(!cloned_info.allows_ad);
    try std.testing.expectEqual(skript.Value.i64(29), cloned_info.source_value);
    try std.testing.expectEqual(skript.Value.i64(31), cloned_info.arglist);
    try std.testing.expectEqual(skript.Value.i64(37), cloned_info.body);
    const parameters = cloned.parameters[cloned_info.parameter_start..][0..cloned_info.parameter_count];
    try std.testing.expectEqualStrings(
        "fixed",
        cloned.bindings[@backingInt(parameters[0])].name.*,
    );
    try std.testing.expectEqualStrings(
        "rest",
        cloned.bindings[@backingInt(parameters[1])].name.*,
    );
}
