const std = @import("std");
const Allocator = std.mem.Allocator;
const Code = @import("code.zig");
const PrimitiveId = @import("primitive.zig").PrimitiveId;
const SourceUnit = @import("SourceUnit.zig");
const Value = @import("value.zig").Value;
const builtins = @import("builtin.zig");
const regvm = @import("regvm.zig");
const regalloc = @import("regalloc.zig");
const EvalContext = @import("EvalContext.zig");

pub const Error = error{ OutOfMemory, Unsupported, InvalidCode, RegisterOverflow, Exhausted };

pub const Options = struct {
    small_immediates: bool = true,
    constant_seeding: bool = true,
    arith_fast_path: bool = true,
    cold_arithmetic_fallbacks: bool = true,
    speculative_arith: bool = true,
    copy_propagation: bool = true,
    self_call: bool = true,
    self_call_zero_mask: bool = true,
};

pub const PrimitiveTarget = struct {
    index: ?u16,
    value: Value,
};

pub const ResolveContext = struct {
    userdata: *anyopaque,
    symbolIndex: *const fn (*anyopaque, Code.Symbol) anyerror!u16,
    primitive: *const fn (*anyopaque, PrimitiveId) ?PrimitiveTarget,
    context: ?*const EvalContext = null,
};

pub const ClosureSite = struct {
    function: Code.FunctionId,
    capture_start: u32,
    capture_count: u8,

    pub fn captures(self: ClosureSite, registers: []const u8) ?[]const u8 {
        const end = std.math.add(usize, self.capture_start, self.capture_count) catch return null;
        if (end > registers.len) return null;
        return registers[self.capture_start..end];
    }
};

pub const FnTableEntry = struct {
    code: ?*const Code.Code = null,
    function: Code.FunctionId = .invalid,
    arglist: []const Code.Symbol = &.{},
    capture_syms: []const Code.Symbol = &.{},
    closure_sites: []const ClosureSite = &.{},
    capture_regs: []const u8 = &.{},
    body: Value = .nil,
    source: Value = .nil,
    source_ref: SourceUnit.Ref = .{},
    ir: []regvm.Inst = &.{},
    constants: []const Value = &.{},
    nregs: u8 = 0,
    result_count: u8 = 1,
    zero_mask: u32 = 0xFFFF_FFFF,
    verified: bool = false,
};

pub const RegProgram = struct {
    code: ?*const Code.Code = null,
    ir: []regvm.Inst = &.{},
    constants: []const Value = &.{},
    nregs: u8 = 0,
    fns: []const FnTableEntry = &.{},
};

fn validateBytecode(
    allocator: Allocator,
    ir: []const regvm.Inst,
    nregs: u8,
    constant_count: usize,
    sites: []const ClosureSite,
    capture_registers: []const u8,
) Error!void {
    if (ir.len == 0) return error.InvalidCode;
    const starts = try allocator.alloc(bool, ir.len);
    defer allocator.free(starts);
    @memset(starts, false);
    const mask = regvm.registerRangeMask(0, nregs) orelse return error.InvalidCode;
    var index: usize = 0;
    while (index < ir.len) {
        const inst = ir[index];
        const size = regvm.instructionSize(inst.opcode);
        if (size > ir.len - index) return error.InvalidCode;
        starts[index] = true;
        const access = regvm.registerAccessAt(ir, index);
        if (!access.valid or
            ((access.reads | access.writes | access.exceptional_writes) & ~mask) != 0)
        {
            return error.InvalidCode;
        }
        switch (inst.opcode) {
            .load, .guard_callee => {
                if (regvm.Formats.rdAndSidx(inst.payload)[1] >= constant_count) {
                    return error.InvalidCode;
                }
            },
            .make_closure => {
                const site_index = regvm.Formats.rdAndSidx(inst.payload)[1];
                if (site_index >= sites.len) return error.InvalidCode;
                const captures = sites[site_index].captures(capture_registers) orelse return error.InvalidCode;
                for (captures) |register| if (register >= nregs) return error.InvalidCode;
            },
            else => {},
        }
        if (index + size == ir.len) switch (inst.opcode) {
            .stop, .ret, .ret_multi, .tail_call, .tail_call_multi, .tail_self_call, .raise, .jmp => {},
            else => return error.InvalidCode,
        };
        index += size;
    }
    index = 0;
    while (index < ir.len) {
        const inst = ir[index];
        const size = regvm.instructionSize(inst.opcode);
        const offset: ?i64 = switch (inst.opcode) {
            .jmp => regvm.Formats.imm24(inst.payload),
            .br, .brn, .@"try" => regvm.Formats.rdOffset(inst.payload)[1],
            .guard_callee, .guard_self => @as(u32, @bitCast(ir[index + 1])),
            else => null,
        };
        if (offset) |relative| {
            const target = @as(i64, @intCast(index + size)) + relative;
            if (target < 0 or target >= ir.len or !starts[@intCast(target)]) return error.InvalidCode;
        }
        index += size;
    }
}

test "bytecode validation rejects jumps into guard extensions" {
    const ir = [_]regvm.Inst{
        .make(.jmp, 1),
        .make(.guard_self, 0),
        .make(.nop, 0),
        .make(.stop, 0),
    };
    try std.testing.expectError(error.InvalidCode, validateBytecode(std.testing.allocator, &ir, 1, 0, &.{}, &.{}));
}

test "bytecode validation rejects truncated guards and out of frame operands" {
    try std.testing.expectError(error.InvalidCode, validateBytecode(
        std.testing.allocator,
        &.{.make(.guard_self, 0)},
        1,
        0,
        &.{},
        &.{},
    ));
    try std.testing.expectError(error.InvalidCode, validateBytecode(
        std.testing.allocator,
        &.{ .make(.mov_reg, 2), .make(.stop, 0) },
        2,
        0,
        &.{},
        &.{},
    ));
}

test "bytecode validation accepts all direct intrinsic arities and full indices" {
    for (0..5) |count| {
        const opcode: regvm.Opcode = switch (count) {
            0 => .call_builtin_0,
            1 => .call_builtin_1,
            2 => .call_builtin_2,
            3 => .call_builtin_3,
            else => .call_builtin_ext,
        };
        const ir = [_]regvm.Inst{
            .make(opcode, (551 << 8) | 1),
            if (count == 4) regvm.Formats.extensionWord(4) else .make(.stop, 1 << 16),
            .make(.stop, 1 << 16),
        };
        const words: usize = if (count == 4) 3 else 2;
        try validateBytecode(std.testing.allocator, ir[0..words], 6, 0, &.{}, &.{});
    }
    const largest = [_]regvm.Inst{
        .make(.call_builtin_ext, (65535 << 8) | 1),
        regvm.Formats.extensionWord(253),
        .make(.stop, 1 << 16),
    };
    try validateBytecode(std.testing.allocator, &largest, 255, 0, &.{}, &.{});
}

test "bytecode validation rejects malformed intrinsic extension and register windows" {
    const first = regvm.Inst.make(.call_builtin_ext, (300 << 8) | 1);
    try std.testing.expectError(error.InvalidCode, validateBytecode(
        std.testing.allocator,
        &.{first},
        6,
        0,
        &.{},
        &.{},
    ));
    for ([_]u32{ 3, 0x104, 254 }) |word| {
        const ir = [_]regvm.Inst{ first, regvm.Formats.extensionWord(word), .make(.stop, 1 << 16) };
        try std.testing.expectError(error.InvalidCode, validateBytecode(
            std.testing.allocator,
            &ir,
            255,
            0,
            &.{},
            &.{},
        ));
    }
    const over_frame = [_]regvm.Inst{
        first, regvm.Formats.extensionWord(4), .make(.stop, 1 << 16),
    };
    try std.testing.expectError(error.InvalidCode, validateBytecode(
        std.testing.allocator,
        &over_frame,
        5,
        0,
        &.{},
        &.{},
    ));
    const over_end = [_]regvm.Inst{
        .make(.call_builtin_ext, (300 << 8) | 251),
        regvm.Formats.extensionWord(4),
        .make(.stop, 251 << 16),
    };
    try std.testing.expectError(error.InvalidCode, validateBytecode(
        std.testing.allocator,
        &over_end,
        255,
        0,
        &.{},
        &.{},
    ));
    try std.testing.expectError(error.InvalidCode, validateBytecode(
        std.testing.allocator,
        &.{ .make(@enumFromInt(0x32), 0), .make(.stop, 0) },
        1,
        0,
        &.{},
        &.{},
    ));
}

test "bytecode validation rejects jumps into intrinsic extensions" {
    for ([_]regvm.Opcode{ .jmp, .br, .@"try" }) |opcode| {
        const branch_payload: u24 = if (opcode == .jmp) 1 else (1 << 16) | 1;
        const ir = [_]regvm.Inst{
            .make(opcode, branch_payload),
            .make(.call_builtin_ext, (551 << 8) | 1),
            regvm.Formats.extensionWord(4),
            .make(.stop, 1 << 16),
        };
        try std.testing.expectError(error.InvalidCode, validateBytecode(
            std.testing.allocator,
            &ir,
            6,
            0,
            &.{},
            &.{},
        ));
    }
}

const PatchKind = enum { jmp, br, try_begin };
const Patch = struct {
    pos: usize,
    target: Code.BlockId,
    kind: PatchKind,
    register: u8 = 0,
};

const Move = struct {
    source: u8,
    destination: u8,
    temporary: ?u8 = null,
};

const ArithmeticFallback = struct {
    guard: usize,
    continuation: usize,
    register: u8,
};

const LowerState = struct {
    lowerer: *Lowerer,
    function: Code.FunctionId,
    current_block: Code.BlockId = .invalid,
    blocks: []const Code.BlockId,
    buf: std.ArrayList(regvm.Inst) = .empty,
    constants: std.ArrayList(Value) = .empty,
    closure_sites: std.ArrayList(ClosureSite) = .empty,
    capture_regs: std.ArrayList(u8) = .empty,
    allocator: regalloc.RegAlloc = regalloc.RegAlloc.init(),
    value_regs: []?u8,
    uses: []u32,
    live_values: [256]u32 = @splat(0),
    binding_regs: []?u8,
    fixed_regs: std.StaticBitSet(256) = std.StaticBitSet(256).initEmpty(),
    labels: []?usize,
    patches: std.ArrayList(Patch) = .empty,
    arithmetic_fallbacks: std.ArrayList(ArithmeticFallback) = .empty,
    definition_positions: ?[]usize = null,
    use_positions: ?[]usize = null,
    current_position: usize = 0,
    loop_keeps: std.ArrayList(struct { block: Code.BlockId, value: Code.ValueId }) = .empty,

    fn init(lowerer: *Lowerer, function: Code.FunctionId) Error!LowerState {
        try lowerer.charge(lowerer.code.values.len);
        try lowerer.charge(lowerer.code.bindings.len);
        try lowerer.charge(lowerer.code.blocks.len);
        const function_info = lowerer.code.function(function) orelse return error.InvalidCode;
        const blocks_start: usize = function_info.block_start;
        const blocks_end = std.math.add(usize, blocks_start, function_info.block_count) catch
            return error.InvalidCode;
        if (blocks_end > lowerer.code.function_blocks.len) return error.InvalidCode;

        const value_regs = lowerer.scratch_allocator.alloc(?u8, lowerer.code.values.len) catch
            return error.OutOfMemory;
        errdefer lowerer.scratch_allocator.free(value_regs);
        @memset(value_regs, null);
        const uses = lowerer.scratch_allocator.alloc(u32, lowerer.code.values.len) catch
            return error.OutOfMemory;
        errdefer lowerer.scratch_allocator.free(uses);
        @memset(uses, 0);
        const binding_regs = lowerer.scratch_allocator.alloc(?u8, lowerer.code.bindings.len) catch
            return error.OutOfMemory;
        errdefer lowerer.scratch_allocator.free(binding_regs);
        @memset(binding_regs, null);
        const labels = lowerer.scratch_allocator.alloc(?usize, lowerer.code.blocks.len) catch
            return error.OutOfMemory;
        errdefer lowerer.scratch_allocator.free(labels);
        @memset(labels, null);
        return .{
            .lowerer = lowerer,
            .function = function,
            .blocks = try lowerer.orderBlocks(lowerer.code.function_blocks[blocks_start..blocks_end]),
            .value_regs = value_regs,
            .uses = uses,
            .binding_regs = binding_regs,
            .labels = labels,
        };
    }

    fn deinit(self: *LowerState) void {
        if (self.definition_positions) |positions| self.lowerer.scratch_allocator.free(positions);
        if (self.use_positions) |positions| self.lowerer.scratch_allocator.free(positions);
        self.loop_keeps.deinit(self.lowerer.scratch_allocator);
        self.lowerer.scratch_allocator.free(self.blocks);
        self.lowerer.scratch_allocator.free(self.value_regs);
        self.lowerer.scratch_allocator.free(self.uses);
        self.lowerer.scratch_allocator.free(self.binding_regs);
        self.lowerer.scratch_allocator.free(self.labels);
        self.buf.deinit(self.lowerer.scratch_allocator);
        self.constants.deinit(self.lowerer.scratch_allocator);
        self.patches.deinit(self.lowerer.scratch_allocator);
        self.arithmetic_fallbacks.deinit(self.lowerer.scratch_allocator);
        self.closure_sites.deinit(self.lowerer.scratch_allocator);
        self.capture_regs.deinit(self.lowerer.scratch_allocator);
        // SAFETY: LowerState is not used after all owned storage is released.
        self.* = undefined;
    }

    fn append(self: *LowerState, inst: regvm.Inst) Error!void {
        try self.lowerer.charge(1);
        self.buf.append(self.lowerer.scratch_allocator, inst) catch return error.OutOfMemory;
    }

    fn allocReg(self: *LowerState) Error!u8 {
        const index = self.allocator.free.findFirstSet() orelse return error.RegisterOverflow;
        // nregs is an 8-bit count. Register 255 cannot be represented in a
        // frame with that count, so leave it unavailable to emitted code.
        if (index >= std.math.maxInt(u8)) return error.RegisterOverflow;
        self.allocator.free.unset(index);
        self.allocator.next_hint = @intCast(index);
        if (index > self.allocator.max_used) self.allocator.max_used = @intCast(index);
        return @intCast(index);
    }

    fn allocBlock(self: *LowerState, count: usize) Error!u8 {
        if (count == 0 or count > std.math.maxInt(u8)) return error.RegisterOverflow;
        const width: u8 = @intCast(count);
        // Keep the exclusive upper bound below register 255 because nregs is
        // a count, not a maximum register index.
        var base: usize = 1;
        while (base + count <= std.math.maxInt(u8)) : (base += 1) {
            const candidate: u8 = @intCast(base);
            if (!self.allocator.blockFree(candidate, width)) continue;
            self.allocator.reserveBlock(candidate, width);
            return candidate;
        }
        return error.RegisterOverflow;
    }

    fn pushConstant(self: *LowerState, value: Value) Error!u24 {
        const index = self.constants.items.len;
        if (index > std.math.maxInt(u24)) return error.Unsupported;
        self.constants.append(self.lowerer.scratch_allocator, value) catch return error.OutOfMemory;
        return @intCast(index);
    }

    fn valueIndex(self: *const LowerState, value: Code.ValueId) Error!usize {
        if (value == .invalid) return error.InvalidCode;
        const index = @intFromEnum(value);
        if (index >= self.lowerer.code.values.len) return error.InvalidCode;
        if (self.lowerer.code.values[index] != self.function) return error.InvalidCode;
        return index;
    }

    fn regFor(self: *const LowerState, value: Code.ValueId) Error!u8 {
        const index = try self.valueIndex(value);
        return self.value_regs[index] orelse return error.InvalidCode;
    }

    fn assignValue(self: *LowerState, value: Code.ValueId, reg: u8) Error!void {
        const index = try self.valueIndex(value);
        if (self.value_regs[index] != null) return error.InvalidCode;
        self.value_regs[index] = reg;
        if (self.uses[index] != 0) self.live_values[reg] += 1;
    }

    fn assignResults(self: *LowerState, first: Code.ValueId, count: u8, base: u8) Error!void {
        if (count == 0 or first == .invalid) return error.InvalidCode;
        const first_index = try self.valueIndex(first);
        const end = std.math.add(usize, first_index, count) catch return error.InvalidCode;
        if (end > self.lowerer.code.values.len) return error.InvalidCode;
        if (self.lowerer.code.values[first_index] != self.function) return error.InvalidCode;
        if (@as(u16, base) + @as(u16, count) > std.math.maxInt(u8)) {
            return error.RegisterOverflow;
        }
        for (0..count) |offset| {
            const value: Code.ValueId = @enumFromInt(@as(u32, @intCast(first_index + offset)));
            try self.assignValue(value, @intCast(@as(usize, base) + offset));
        }
    }

    fn valueIsLiveAtOtherIndex(self: *const LowerState, index: usize, reg: u8) bool {
        const own: u32 = @intFromBool(self.uses[index] != 0 and self.value_regs[index] == reg);
        std.debug.assert(self.live_values[reg] >= own);
        return self.live_values[reg] > own;
    }

    fn release(self: *LowerState, value: Code.ValueId) void {
        const index = @intFromEnum(value);
        if (index >= self.uses.len) return;
        if (self.uses[index] != 0) {
            self.uses[index] -= 1;
            if (self.uses[index] != 0) return;
            if (self.value_regs[index]) |reg| {
                std.debug.assert(self.live_values[reg] > 0);
                self.live_values[reg] -= 1;
            }
        }
        const reg = self.value_regs[index] orelse return;
        if (self.fixed_regs.isSet(reg)) return;
        if (self.valueIsLiveAtOtherIndex(index, reg)) return;
        if (!self.allocator.free.isSet(reg)) self.allocator.freeReg(reg);
    }

    fn addUse(self: *LowerState, value: Code.ValueId) Error!void {
        try self.lowerer.charge(1);
        const index = try self.valueIndex(value);
        if (self.uses[index] == std.math.maxInt(u32)) return error.InvalidCode;
        self.uses[index] += 1;
        if (self.use_positions) |positions| positions[index] = @max(positions[index], self.current_position);
    }

    fn reusableCallWindow(
        self: *const LowerState,
        callee: Code.ValueId,
        args: []const Code.ValueId,
    ) Error!?u8 {
        const callee_index = try self.valueIndex(callee);
        if (self.uses[callee_index] != 1) return null;
        const base = self.value_regs[callee_index] orelse return error.InvalidCode;
        if (self.valueIsLiveAtOtherIndex(callee_index, base)) return null;
        const width = std.math.add(usize, args.len, 1) catch return null;
        const end = std.math.add(usize, base, width) catch return null;
        if (end > std.math.maxInt(u8)) return null;
        for (args, 0..) |argument, index| {
            const expected: u8 = @intCast(@as(usize, base) + index + 1);
            if (try self.regFor(argument) != expected) return null;
        }
        return base;
    }

    fn range(self: *const LowerState, operand_range: Code.OperandRange) Error![]const Code.ValueId {
        const start: usize = operand_range.start;
        const end = std.math.add(usize, start, operand_range.len) catch return error.InvalidCode;
        if (end > self.lowerer.code.operands.len) return error.InvalidCode;
        return self.lowerer.code.operands[start..end];
    }

    fn addRangeUses(self: *LowerState, operand_range: Code.OperandRange) Error!void {
        for (try self.range(operand_range)) |value| try self.addUse(value);
    }
};

const Lowerer = struct {
    output_allocator: Allocator,
    scratch_allocator: Allocator,
    code: *const Code.Code,
    resolve: ResolveContext,
    options: Options,
    fns: []FnTableEntry = &.{},

    fn charge(self: *const Lowerer, count: usize) Error!void {
        if (self.resolve.context) |context| try context.chargeWork(count, 1, .code);
    }

    fn init(
        output_allocator: Allocator,
        scratch_allocator: Allocator,
        code: *const Code.Code,
        resolve: ResolveContext,
        options: Options,
    ) Lowerer {
        return .{
            .output_allocator = output_allocator,
            .scratch_allocator = scratch_allocator,
            .code = code,
            .resolve = resolve,
            .options = options,
        };
    }

    fn deinitOutput(self: *Lowerer) void {
        for (self.fns) |entry| {
            self.output_allocator.free(entry.arglist);
            self.output_allocator.free(entry.capture_syms);
            self.output_allocator.free(entry.closure_sites);
            self.output_allocator.free(entry.capture_regs);
            self.output_allocator.free(entry.ir);
            self.output_allocator.free(entry.constants);
        }
        self.output_allocator.free(self.fns);
        self.fns = &.{};
    }

    fn orderBlocks(self: *Lowerer, blocks: []const Code.BlockId) Error![]const Code.BlockId {
        const Visit = struct { block: Code.BlockId, expanded: bool = false };
        const seen = try self.scratch_allocator.alloc(bool, self.code.blocks.len);
        defer self.scratch_allocator.free(seen);
        @memset(seen, false);
        var stack: std.ArrayList(Visit) = .empty;
        defer stack.deinit(self.scratch_allocator);
        var ordered: std.ArrayList(Code.BlockId) = .empty;
        errdefer ordered.deinit(self.scratch_allocator);
        for (blocks) |root_block| {
            if (seen[@intFromEnum(root_block)]) continue;
            const component_start = ordered.items.len;
            try stack.append(self.scratch_allocator, .{ .block = root_block });
            while (stack.pop()) |visit| {
                try self.charge(1);
                if (visit.expanded) {
                    try ordered.append(self.scratch_allocator, visit.block);
                    continue;
                }
                const index = @intFromEnum(visit.block);
                if (seen[index]) continue;
                seen[index] = true;
                try stack.append(self.scratch_allocator, .{ .block = visit.block, .expanded = true });
                const block = self.code.blocks[index];
                switch (block.terminator) {
                    .jump => |edge| try stack.append(self.scratch_allocator, .{ .block = edge.target }),
                    .branch => |branch| {
                        try stack.append(self.scratch_allocator, .{ .block = branch.then_edge.target });
                        try stack.append(self.scratch_allocator, .{ .block = branch.else_edge.target });
                    },
                    else => {},
                }
                if (block.handler != .invalid) {
                    const handler = self.code.handlers[@intFromEnum(block.handler)];
                    try stack.append(self.scratch_allocator, .{ .block = handler.landing });
                }
            }
            std.mem.reverse(Code.BlockId, ordered.items[component_start..]);
        }
        return ordered.toOwnedSlice(self.scratch_allocator);
    }

    fn lower(self: *Lowerer) Error!RegProgram {
        self.code.validate(self.scratch_allocator, self.resolve.context) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Exhausted => return error.Exhausted,
            else => return error.InvalidCode,
        };
        if (self.code.functions.len == 0) return error.InvalidCode;
        self.fns = self.output_allocator.alloc(FnTableEntry, self.code.functions.len) catch
            return error.OutOfMemory;
        @memset(self.fns, .{});
        errdefer self.deinitOutput();
        for (self.code.functions) |function| {
            const entry = try self.lowerFunction(function.id);
            self.fns[@intFromEnum(function.id)] = entry;
        }
        const top = self.fns[0];
        return .{
            .code = self.code,
            .ir = top.ir,
            .constants = top.constants,
            .nregs = top.nregs,
            .fns = self.fns,
        };
    }

    fn lowerFunction(self: *Lowerer, function_id: Code.FunctionId) Error!FnTableEntry {
        var state = try LowerState.init(self, function_id);
        defer state.deinit();
        if (self.options.constant_seeding) {
            state.constants.appendSlice(self.scratch_allocator, &[_]Value{ .nil, .true, .false }) catch
                return error.OutOfMemory;
        }
        try self.prepareLoopUses(&state);
        try self.computeUses(&state);
        try self.extendLoopUses(&state);
        try self.assignFixedRegisters(&state);
        try state.append(regvm.Inst.make(.start, 0));
        try self.emitMutableParameterFrame(&state);
        var keep_index: usize = 0;
        for (state.blocks) |block_id| {
            const block_index = @intFromEnum(block_id);
            if (block_index >= self.code.blocks.len) return error.InvalidCode;
            state.labels[block_index] = state.buf.items.len;
            try self.lowerBlock(&state, block_id);
            while (keep_index < state.loop_keeps.items.len and
                state.loop_keeps.items[keep_index].block == block_id) : (keep_index += 1)
            {
                state.release(state.loop_keeps.items[keep_index].value);
            }
        }
        try self.patch(&state);
        try self.emitArithmeticFallbacks(&state);

        var ir_view = state.buf.items;
        if (self.options.copy_propagation) {
            ir_view = try copyPropagate(
                self.scratch_allocator,
                ir_view,
                state.closure_sites.items,
                state.capture_regs.items,
                self.resolve.context,
            );
        }
        const ir = self.output_allocator.alloc(regvm.Inst, ir_view.len) catch return error.OutOfMemory;
        @memcpy(ir, ir_view);
        errdefer self.output_allocator.free(ir);
        const constants = self.output_allocator.alloc(Value, state.constants.items.len) catch
            return error.OutOfMemory;
        @memcpy(constants, state.constants.items);
        errdefer self.output_allocator.free(constants);

        const function = self.code.function(function_id) orelse return error.InvalidCode;
        const arglist = try self.argumentSymbols(function);
        errdefer self.output_allocator.free(arglist);
        const capture_syms = try self.captureSymbols(function);
        errdefer self.output_allocator.free(capture_syms);
        const closure_sites = try self.output_allocator.dupe(ClosureSite, state.closure_sites.items);
        errdefer self.output_allocator.free(closure_sites);
        const capture_regs = try self.output_allocator.dupe(u8, state.capture_regs.items);
        errdefer self.output_allocator.free(capture_regs);
        const nregs = try self.registerCount(state.allocator.max_used);
        try self.charge(ir.len);
        try self.charge(ir.len);
        try validateBytecode(self.scratch_allocator, ir, nregs, constants.len, closure_sites, capture_regs);
        const zero_mask = if (self.options.self_call_zero_mask)
            try computeZeroMask(
                self.scratch_allocator,
                ir,
                nregs,
                function.parameter_count,
                function.capture_count,
                closure_sites,
                capture_regs,
                self.resolve.context,
            )
        else
            std.math.maxInt(u32);
        return .{
            .code = self.code,
            .function = function_id,
            .arglist = arglist,
            .capture_syms = capture_syms,
            .closure_sites = closure_sites,
            .capture_regs = capture_regs,
            .body = function.body,
            .source = function.source_value,
            .source_ref = function.source,
            .ir = ir,
            .constants = constants,
            .nregs = nregs,
            .result_count = function.result_count,
            .zero_mask = zero_mask,
            .verified = true,
        };
    }

    fn registerCount(self: *Lowerer, max_used: u8) Error!u8 {
        _ = self;
        if (max_used >= std.math.maxInt(u8)) return error.RegisterOverflow;
        return @intCast(@as(usize, max_used) + 1);
    }

    fn argumentSymbols(self: *Lowerer, function: *const Code.Function) Error![]const Code.Symbol {
        const first: usize = function.parameter_start;
        const last = std.math.add(usize, first, function.parameter_count) catch return error.InvalidCode;
        if (last > self.code.parameters.len) return error.InvalidCode;
        const out = self.output_allocator.alloc(Code.Symbol, function.parameter_count) catch
            return error.OutOfMemory;
        errdefer self.output_allocator.free(out);
        for (self.code.parameters[first..last], 0..) |binding, index| {
            const binding_index = @intFromEnum(binding);
            if (binding_index >= self.code.bindings.len) return error.InvalidCode;
            out[index] = self.code.bindings[binding_index].name;
        }
        return out;
    }

    fn captureSymbols(self: *Lowerer, function: *const Code.Function) Error![]const Code.Symbol {
        const first: usize = function.capture_start;
        const last = std.math.add(usize, first, function.capture_count) catch return error.InvalidCode;
        if (last > self.code.captures.len) return error.InvalidCode;
        const out = self.output_allocator.alloc(Code.Symbol, function.capture_count) catch
            return error.OutOfMemory;
        errdefer self.output_allocator.free(out);
        for (self.code.captures[first..last], 0..) |binding, index| {
            const binding_index = @intFromEnum(binding);
            if (binding_index >= self.code.bindings.len) return error.InvalidCode;
            out[index] = self.code.bindings[binding_index].name;
        }
        return out;
    }
    fn bindingValue(self: *const Lowerer, function: Code.FunctionId, binding_id: Code.BindingId) Error!Code.ValueId {
        const binding_index = @intFromEnum(binding_id);
        if (binding_index >= self.code.bindings.len) return error.InvalidCode;
        const binding = self.code.bindings[binding_index];
        if (binding.function == function) return binding.value;
        const function_info = self.code.function(function) orelse return error.InvalidCode;
        const first: usize = function_info.capture_start;
        const last = std.math.add(usize, first, function_info.capture_count) catch
            return error.InvalidCode;
        if (last > self.code.captures.len or last > self.code.capture_values.len) {
            return error.InvalidCode;
        }
        for (self.code.captures[first..last], 0..) |captured, index| {
            if (captured == binding_id) return self.code.capture_values[first + index];
        }
        return error.InvalidCode;
    }

    fn emitMutableParameterFrame(self: *Lowerer, state: *LowerState) Error!void {
        const function = self.code.function(state.function) orelse return error.InvalidCode;
        const first: usize = function.parameter_start;
        const last = std.math.add(usize, first, function.parameter_count) catch return error.InvalidCode;
        if (last > self.code.parameters.len) return error.InvalidCode;

        var mutable_count: u16 = 0;
        for (self.code.parameters[first..last]) |binding| {
            const index = @intFromEnum(binding);
            if (index >= self.code.bindings.len) return error.InvalidCode;
            if (!self.code.bindings[index].mutable) continue;
            if (mutable_count == std.math.maxInt(u16)) return error.Unsupported;
            mutable_count += 1;
        }
        if (mutable_count == 0) return;

        const ns_reg = try state.allocReg();
        try state.append(regvm.Inst.make(
            .ns_push,
            (@as(u24, ns_reg) << 16) | mutable_count,
        ));
        for (self.code.parameters[first..last]) |binding| {
            const binding_index = @intFromEnum(binding);
            const info = self.code.bindings[binding_index];
            if (!info.mutable) continue;
            const source = state.binding_regs[binding_index] orelse return error.InvalidCode;
            const symbol = self.resolve.symbolIndex(self.resolve.userdata, info.name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Unsupported,
            };
            try state.append(regvm.Inst.make(
                .set,
                (@as(u24, source) << 16) | symbol,
            ));
        }
    }

    fn assignFixedRegisters(self: *Lowerer, state: *LowerState) Error!void {
        const function = self.code.function(state.function) orelse return error.InvalidCode;
        const parameter_first: usize = function.parameter_start;
        const parameter_last = std.math.add(usize, parameter_first, function.parameter_count) catch
            return error.InvalidCode;
        const capture_first: usize = function.capture_start;
        const capture_last = std.math.add(usize, capture_first, function.capture_count) catch
            return error.InvalidCode;
        if (parameter_last > self.code.parameters.len) return error.InvalidCode;
        if (capture_last > self.code.captures.len) return error.InvalidCode;
        if (capture_last > self.code.capture_values.len) return error.InvalidCode;
        const fixed_count = std.math.add(usize, function.parameter_count, function.capture_count) catch
            return error.RegisterOverflow;
        if (fixed_count >= std.math.maxInt(u8)) return error.RegisterOverflow;

        state.allocator.free.setRangeValue(.{
            .start = 1,
            .end = fixed_count + 1,
        }, false);
        state.allocator.max_used = @intCast(fixed_count);
        for (self.code.parameters[parameter_first..parameter_last], 0..) |binding, index| {
            const binding_index = @intFromEnum(binding);
            if (binding_index >= self.code.bindings.len) return error.InvalidCode;
            const value = self.code.bindings[binding_index].value;
            if (value == .invalid) return error.InvalidCode;
            const reg: u8 = @intCast(index + 1);
            try state.assignValue(value, reg);
            state.binding_regs[binding_index] = reg;
            state.fixed_regs.set(reg);
        }
        for (self.code.captures[capture_first..capture_last], 0..) |binding, index| {
            const binding_index = @intFromEnum(binding);
            if (binding_index >= self.code.bindings.len) return error.InvalidCode;
            const reg: u8 = @intCast(@as(usize, function.parameter_count) + index + 1);
            const capture_value = self.code.capture_values[capture_first + index];
            try state.assignValue(capture_value, reg);
            state.binding_regs[binding_index] = reg;
            state.fixed_regs.set(reg);
        }
        for (state.blocks) |block_id| {
            const block_index = @intFromEnum(block_id);
            if (block_index >= self.code.blocks.len) return error.InvalidCode;
            const block = self.code.blocks[block_index];
            const first: usize = block.param_start;
            const last = std.math.add(usize, first, block.param_count) catch return error.InvalidCode;
            if (last > self.code.block_parameters.len) return error.InvalidCode;
            for (self.code.block_parameters[first..last]) |value| {
                const reg = try state.allocReg();
                try state.assignValue(value, reg);
            }
        }
    }

    fn backedges(self: *Lowerer, state: *const LowerState, block: Code.Block) [3]?usize {
        var targets: [3]?Code.BlockId = .{ null, null, null };
        switch (block.terminator) {
            .jump => |edge| targets[0] = edge.target,
            .branch => |branch| {
                targets[0] = branch.then_edge.target;
                targets[1] = branch.else_edge.target;
            },
            else => {},
        }
        if (block.handler != .invalid) targets[2] = self.code.handlers[@intFromEnum(block.handler)].landing;
        var result: [3]?usize = .{ null, null, null };
        const source_position = state.labels[@intFromEnum(block.id)] orelse unreachable;
        for (targets, &result) |target, *position| {
            if (target) |id| {
                const target_position = state.labels[@intFromEnum(id)] orelse unreachable;
                if (target_position <= source_position) position.* = target_position;
            }
        }
        return result;
    }

    fn prepareLoopUses(self: *Lowerer, state: *LowerState) Error!void {
        for (state.blocks, 0..) |block, position| state.labels[@intFromEnum(block)] = position + 1;
        for (state.blocks) |block_id| {
            const block = self.code.blocks[@intFromEnum(block_id)];
            for (self.backedges(state, block)) |target| {
                if (target == null) continue;
                state.definition_positions = try self.scratch_allocator.alloc(usize, self.code.values.len);
                @memset(state.definition_positions orelse unreachable, 1);
                state.use_positions = try self.scratch_allocator.alloc(usize, self.code.values.len);
                @memset(state.use_positions orelse unreachable, 0);
                return;
            }
        }
    }

    fn extendLoopUses(self: *Lowerer, state: *LowerState) Error!void {
        const definitions = state.definition_positions orelse return;
        const uses = state.use_positions orelse unreachable;
        for (state.blocks) |block_id| {
            try self.charge(1);
            const targets = self.backedges(state, self.code.blocks[@intFromEnum(block_id)]);
            if (targets[0] == null and targets[1] == null and targets[2] == null) continue;
            try self.charge(self.code.values.len);
            for (self.code.values, 0..) |owner, index| {
                if (owner != state.function) continue;
                for (targets) |maybe_target| {
                    const target = maybe_target orelse continue;
                    if (definitions[index] > target or uses[index] < target) continue;
                    const value: Code.ValueId = @enumFromInt(@as(u32, @intCast(index)));
                    try state.loop_keeps.append(self.scratch_allocator, .{ .block = block_id, .value = value });
                    state.uses[index] = std.math.add(u32, state.uses[index], 1) catch return error.InvalidCode;
                    break;
                }
            }
        }
    }

    fn computeUses(self: *Lowerer, state: *LowerState) Error!void {
        for (state.blocks, 0..) |block_id, position| {
            state.current_position = position + 1;
            const block_index = @intFromEnum(block_id);
            if (block_index >= self.code.blocks.len) return error.InvalidCode;
            const block = self.code.blocks[block_index];
            if (state.definition_positions) |positions| {
                for (self.code.block_parameters[block.param_start..][0..block.param_count]) |value| {
                    positions[@intFromEnum(value)] = state.current_position;
                }
            }
            const first: usize = block.node_start;
            const last = std.math.add(usize, first, block.node_count) catch return error.InvalidCode;
            if (last > self.code.block_nodes.len) return error.InvalidCode;
            for (self.code.block_nodes[first..last]) |node_id| {
                const node_index = @intFromEnum(node_id);
                if (node_index >= self.code.nodes.len) return error.InvalidCode;
                const node = self.code.nodes[node_index];
                if (state.definition_positions) |positions| {
                    for (0..node.resultCount()) |offset| {
                        positions[@intFromEnum(node.result) + offset] = state.current_position;
                    }
                }
                switch (node.operation) {
                    .global_write => |write| try state.addUse(write.value),
                    .primitive_call => |call| try state.addRangeUses(call.args),
                    .arithmetic => |arith| {
                        if (arith.callee != .invalid) try state.addUse(arith.callee);
                        try state.addUse(arith.left);
                        try state.addUse(arith.right);
                    },
                    .direct_call => |call| try state.addRangeUses(call.args),
                    .dynamic_call => |call| {
                        try state.addUse(call.callee);
                        try state.addRangeUses(call.args);
                    },
                    .make_closure => |closure| try state.addRangeUses(closure.captures),
                    .local_read => |binding| {
                        const value = try self.bindingValue(state.function, binding);
                        try state.addUse(value);
                    },
                    else => {},
                }
            }
            switch (block.terminator) {
                .branch => |branch| {
                    try state.addUse(branch.condition);
                    try state.addRangeUses(branch.then_edge.args);
                    try state.addRangeUses(branch.else_edge.args);
                },
                .jump => |edge| try state.addRangeUses(edge.args),
                .return_values => |values| try state.addRangeUses(values),
                .raise => |value| try state.addUse(value),
                .tail_call => |call| {
                    try state.addUse(call.callee);
                    try state.addRangeUses(call.args);
                },
                .none => {},
            }
        }
    }

    fn emitSource(self: *Lowerer, state: *LowerState, source_index: u32) Error!void {
        _ = self;
        const index: u24 = if (source_index == Code.invalid_index)
            std.math.maxInt(u24)
        else if (source_index > std.math.maxInt(u24))
            return error.Unsupported
        else
            @intCast(source_index);
        try state.append(regvm.Inst.make(.src, index));
    }

    fn lowerBlock(self: *Lowerer, state: *LowerState, block_id: Code.BlockId) Error!void {
        state.current_block = block_id;
        const block_index = @intFromEnum(block_id);
        if (block_index >= self.code.blocks.len) return error.InvalidCode;
        const block = self.code.blocks[block_index];
        const first: usize = block.node_start;
        const last = std.math.add(usize, first, block.node_count) catch return error.InvalidCode;
        if (last > self.code.block_nodes.len) return error.InvalidCode;
        for (self.code.block_nodes[first..last]) |node_id| {
            const node_index = @intFromEnum(node_id);
            if (node_index >= self.code.nodes.len) return error.InvalidCode;
            const node = self.code.nodes[node_index];
            try self.emitSource(state, node.source_index);
            try self.lowerNode(state, node);
        }
        try self.lowerTerminator(state, block.terminator);
        const params_first: usize = block.param_start;
        const params_last = std.math.add(usize, params_first, block.param_count) catch
            return error.InvalidCode;
        if (params_last > self.code.block_parameters.len) return error.InvalidCode;
        for (self.code.block_parameters[params_first..params_last]) |value| {
            const index = @intFromEnum(value);
            if (index < state.uses.len and state.uses[index] == 0) state.release(value);
        }
    }

    fn nodeResultCount(self: *Lowerer, node: Code.Node) Error!u8 {
        const count = node.resultCount();
        if (count == 0) {
            if (node.result != .invalid) return error.InvalidCode;
        } else if (node.result == .invalid) {
            return error.InvalidCode;
        }
        _ = self;
        return count;
    }

    fn lowerNode(self: *Lowerer, state: *LowerState, node: Code.Node) Error!void {
        const result_count = try self.nodeResultCount(node);
        switch (node.operation) {
            .literal, .quote => |value| {
                if (result_count != 1) return error.InvalidCode;
                const rd = try state.allocBlock(1);
                try state.assignResults(node.result, 1, rd);
                const kidx = if (self.options.constant_seeding and value.isNil())
                    @as(u24, 0)
                else if (self.options.constant_seeding and std.meta.eql(value, Value.true))
                    @as(u24, 1)
                else if (self.options.constant_seeding and std.meta.eql(value, Value.false))
                    @as(u24, 2)
                else
                    try state.pushConstant(value);
                if (self.options.small_immediates and value.typ == builtins.type_i64) {
                    const immediate = value.obj.toInt(i64);
                    if (immediate >= std.math.minInt(i16) and immediate <= std.math.maxInt(i16)) {
                        const encoded: u24 = (@as(u24, rd) << 16) |
                            @as(u24, @as(u16, @bitCast(@as(i16, @intCast(immediate)))));
                        try state.append(regvm.Inst.make(.mov_i64, encoded));
                    } else {
                        try state.append(regvm.Inst.make(.load, (@as(u24, rd) << 16) | kidx));
                    }
                } else {
                    try state.append(regvm.Inst.make(.load, (@as(u24, rd) << 16) | kidx));
                }
            },
            .local_read => |binding| {
                if (result_count != 1) return error.InvalidCode;
                const binding_index = @intFromEnum(binding);
                if (binding_index >= state.binding_regs.len) return error.InvalidCode;
                const source_value = try self.bindingValue(state.function, binding);
                if (self.code.bindings[binding_index].mutable) {
                    const rd = try state.allocBlock(1);
                    try state.assignResults(node.result, 1, rd);
                    const symbol = self.resolve.symbolIndex(
                        self.resolve.userdata,
                        self.code.bindings[binding_index].name,
                    ) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.Unsupported,
                    };
                    try state.append(regvm.Inst.make(.lookup, (@as(u24, rd) << 16) | symbol));
                } else {
                    const source = if (state.binding_regs[binding_index]) |register|
                        register
                    else
                        try state.regFor(source_value);
                    const source_index = try state.valueIndex(source_value);
                    const can_alias = state.uses[source_index] == 1 and
                        !state.valueIsLiveAtOtherIndex(source_index, source);
                    if (can_alias) {
                        try state.assignResults(node.result, 1, source);
                    } else {
                        const rd = try state.allocBlock(1);
                        try state.assignResults(node.result, 1, rd);
                        if (rd != source) {
                            try state.append(regvm.Inst.make(.mov_reg, (@as(u24, rd) << 16) | source));
                        }
                    }
                }
                state.release(source_value);
            },
            .global_read => |cell| {
                if (result_count != 1) return error.InvalidCode;
                const cell_index = @intFromEnum(cell);
                if (cell_index >= self.code.globals.len) return error.InvalidCode;
                const rd = try state.allocBlock(1);
                try state.assignResults(node.result, 1, rd);
                const index = self.resolve.symbolIndex(
                    self.resolve.userdata,
                    self.code.globals[cell_index].name,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.Unsupported,
                };
                try state.append(regvm.Inst.make(.lookup, (@as(u24, rd) << 16) | index));
            },
            .global_write => |write| {
                if (result_count != 0) return error.InvalidCode;
                const cell_index = @intFromEnum(write.cell);
                if (cell_index >= self.code.globals.len) return error.InvalidCode;
                const source = try state.regFor(write.value);
                const index = self.resolve.symbolIndex(
                    self.resolve.userdata,
                    self.code.globals[cell_index].name,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.Unsupported,
                };
                try state.append(regvm.Inst.make(
                    if (write.assign_existing) .set_existing else .set,
                    (@as(u24, source) << 16) | index,
                ));
                state.release(write.value);
            },
            .primitive_call => |call| try self.lowerPrimitive(state, node.result, result_count, call),
            .arithmetic => |arith| try self.lowerArithmetic(state, node.result, result_count, arith),
            .direct_call => |call| try self.lowerDirectCall(state, node.result, result_count, call),
            .dynamic_call => |call| try self.lowerDynamicCall(state, node.result, result_count, call),
            .make_closure => |closure| try self.lowerClosure(state, node.result, result_count, closure),
            .try_begin => |handler| {
                if (result_count != 0) return error.InvalidCode;
                try self.lowerTryBegin(state, handler);
            },
            .try_end => {
                if (result_count != 0) return error.InvalidCode;
                try state.append(regvm.Inst.make(.end_try, 0));
            },
            .ns_push => |count| {
                if (result_count != 1) return error.InvalidCode;
                const rd = try state.allocBlock(1);
                try state.assignResults(node.result, 1, rd);
                try state.append(regvm.Inst.make(.ns_push, (@as(u24, rd) << 16) | count));
            },
            .ns_pop => {
                if (result_count != 0) return error.InvalidCode;
                try state.append(regvm.Inst.make(.ns_pop, 0));
            },
        }
        if (result_count != 0) {
            const first = @intFromEnum(node.result);
            for (0..result_count) |offset| {
                const index = first + offset;
                if (index < state.uses.len and state.uses[index] == 0) {
                    state.release(@as(Code.ValueId, @enumFromInt(@as(u32, @intCast(index)))));
                }
            }
        }
    }

    fn lowerPrimitive(
        self: *Lowerer,
        state: *LowerState,
        result: Code.ValueId,
        result_count: u8,
        call: Code.PrimitiveCall,
    ) Error!void {
        if (result_count != 1 or call.result_count != 1) return error.Unsupported;
        if (call.tail) return error.InvalidCode;
        const args = try state.range(call.args);
        const target = self.resolve.primitive(self.resolve.userdata, call.primitive) orelse
            return error.Unsupported;
        const nargs = std.math.add(usize, args.len, 1) catch return error.RegisterOverflow;
        const rd = try state.allocBlock(nargs);
        try state.assignResults(result, 1, rd);
        if (target.index == null) {
            const constant = try state.pushConstant(target.value);
            try state.append(regvm.Inst.make(.load, (@as(u24, rd) << 16) | constant));
        }
        for (args, 0..) |argument, index| {
            const source = try state.regFor(argument);
            const destination: u8 = @intCast(@as(usize, rd) + 1 + index);
            if (source != destination) {
                try state.append(regvm.Inst.make(.mov_reg, (@as(u24, destination) << 16) | source));
            }
            state.release(argument);
        }
        if (target.index) |index| {
            const opcode: regvm.Opcode = switch (args.len) {
                0 => .call_builtin_0,
                1 => .call_builtin_1,
                2 => .call_builtin_2,
                3 => .call_builtin_3,
                else => .call_builtin_ext,
            };
            try state.append(regvm.Inst.make(opcode, (@as(u24, index) << 8) | rd));
            if (opcode == .call_builtin_ext) {
                try state.append(regvm.Formats.extensionWord(@intCast(args.len)));
            }
        } else {
            const payload = (@as(u24, rd) << 16) | (@as(u24, @intCast(nargs)) << 8);
            try state.append(regvm.Inst.make(.call, payload));
        }
        self.freeWindowTail(state, rd, nargs, 1);
    }

    fn lowerArithmetic(
        self: *Lowerer,
        state: *LowerState,
        result: Code.ValueId,
        result_count: u8,
        arith: Code.Arithmetic,
    ) Error!void {
        if (result_count != 1) return error.Unsupported;
        if (arith.tail) return error.InvalidCode;
        const callee_is_present = arith.callee != .invalid;
        if (!self.options.arith_fast_path) {
            if (callee_is_present) {
                try self.emitCallValues(
                    state,
                    arith.callee,
                    &.{ arith.left, arith.right },
                    result,
                    1,
                    false,
                    .invalid,
                );
            } else {
                try self.emitGeneratedArithmetic(
                    state,
                    result,
                    arith,
                    genericArithmeticOpcode(arith.op),
                );
            }
            return;
        }

        const opcode = self.arithmeticOpcode(arith) orelse genericArithmeticOpcode(arith.op);
        if (callee_is_present) {
            try self.emitGuardedArithmetic(state, result, arith, opcode);
        } else {
            try self.emitGeneratedArithmetic(state, result, arith, opcode);
        }
    }

    fn genericArithmeticOpcode(op: Code.ArithOp) regvm.Opcode {
        return switch (op) {
            .add => .generic_add,
            .sub => .generic_sub,
            .mul => .generic_mul,
            .div => .generic_div,
            .equal => .generic_eq,
            .less => .generic_lt,
            .greater => .generic_gt,
        };
    }

    fn arithmeticOpcode(self: *Lowerer, arith: Code.Arithmetic) ?regvm.Opcode {
        const same = arith.left_types == arith.right_types;
        const i64_types = (@as(u64, 1) << @intFromEnum(builtins.type_i64));
        const f64_types = (@as(u64, 1) << @intFromEnum(builtins.type_f64));
        if (same and arith.left_types == i64_types) {
            return switch (arith.op) {
                .add => .add_i64,
                .sub => .sub_i64,
                .mul => .mul_i64,
                .div => .div_i64,
                .equal => .eq_i64,
                .less => .lt_i64,
                .greater => .gt_i64,
            };
        }
        if (same and arith.left_types == f64_types) {
            return switch (arith.op) {
                .add => .add_f64,
                .sub => .sub_f64,
                .mul => .mul_f64,
                .div => .div_f64,
                .equal => .eq_f64,
                .less => .lt_f64,
                .greater => .gt_f64,
            };
        }
        if (!self.options.speculative_arith) return null;
        if (tsSingle(arith.left_types)) return arithOpcodeForType(arith.op, @ctz(arith.left_types));
        if (tsSingle(arith.right_types)) return arithOpcodeForType(arith.op, @ctz(arith.right_types));
        return arithOpcodeForType(arith.op, @intFromEnum(builtins.type_i64));
    }

    fn emitGeneratedArithmetic(
        self: *Lowerer,
        state: *LowerState,
        result: Code.ValueId,
        arith: Code.Arithmetic,
        opcode: regvm.Opcode,
    ) Error!void {
        _ = self;
        if (arith.tail) return error.InvalidCode;
        const left = try state.regFor(arith.left);
        const right = try state.regFor(arith.right);
        const left_index = try state.valueIndex(arith.left);
        const right_index = try state.valueIndex(arith.right);
        const left_can_alias = state.uses[left_index] == 1 and
            !state.valueIsLiveAtOtherIndex(left_index, left);
        const right_can_alias = state.uses[right_index] == 1 and
            !state.valueIsLiveAtOtherIndex(right_index, right);
        const rd = if (left_can_alias)
            left
        else if (right_can_alias)
            right
        else
            try state.allocBlock(1);
        try state.assignResults(result, 1, rd);
        state.release(arith.left);
        state.release(arith.right);
        const payload = (@as(u24, rd) << 16) | (@as(u24, left) << 8) | right;
        try state.append(regvm.Inst.make(opcode, payload));
    }

    fn emitGuardedArithmetic(
        self: *Lowerer,
        state: *LowerState,
        result: Code.ValueId,
        arith: Code.Arithmetic,
        opcode: regvm.Opcode,
    ) Error!void {
        if (arith.tail) return error.InvalidCode;
        if (arith.expected_callee.isNil()) return error.InvalidCode;
        const expected_index = try state.pushConstant(arith.expected_callee);
        if (expected_index > std.math.maxInt(u16)) return error.Unsupported;
        const callee = try state.regFor(arith.callee);
        const left = try state.regFor(arith.left);
        const right = try state.regFor(arith.right);
        const args = [_]Code.ValueId{ arith.left, arith.right };
        const reused_window = try state.reusableCallWindow(arith.callee, &args);
        const rd = reused_window orelse try state.allocBlock(3);
        try state.assignResults(result, 1, rd);
        if (reused_window == null) {
            try self.emitStage(state, rd, callee);
            try self.emitStage(state, rd + 1, left);
            try self.emitStage(state, rd + 2, right);
        }
        state.release(arith.callee);
        state.release(arith.left);
        state.release(arith.right);

        const guard_pos = state.buf.items.len;
        const guard_payload = (@as(u24, rd) << 16) | @as(u24, @intCast(expected_index));
        try state.append(regvm.Inst.make(.guard_callee, guard_payload));
        try state.append(regvm.Formats.extensionWord(0));
        try state.append(regvm.Inst.make(opcode, (@as(u24, rd) << 16) |
            (@as(u24, rd + 1) << 8) | (rd + 2)));
        if (self.options.cold_arithmetic_fallbacks) {
            try state.arithmetic_fallbacks.append(self.scratch_allocator, .{
                .guard = guard_pos,
                .continuation = state.buf.items.len,
                .register = rd,
            });
        } else {
            const jump_pos = state.buf.items.len;
            try state.append(regvm.Inst.make(.jmp, 0));
            const slow_start = state.buf.items.len;
            try state.append(regvm.Inst.make(.call, (@as(u24, rd) << 16) | (@as(u24, 3) << 8)));
            try self.patchGuard(state, guard_pos, slow_start);
            try self.patchRelativeJump(state, jump_pos, state.buf.items.len);
        }
        if (reused_window == null) self.freeWindowTail(state, rd, 3, 1);
    }

    /// Cold calls return to the instruction after their guarded arithmetic.
    /// The guard preserves the staged call window and the current source index.
    fn emitArithmeticFallbacks(self: *Lowerer, state: *LowerState) Error!void {
        for (state.arithmetic_fallbacks.items) |fallback| {
            const slow_start = state.buf.items.len;
            try state.append(regvm.Inst.make(
                .call,
                (@as(u24, fallback.register) << 16) | (@as(u24, 3) << 8),
            ));
            const jump_pos = state.buf.items.len;
            try state.append(regvm.Inst.make(.jmp, 0));
            try self.patchGuard(state, fallback.guard, slow_start);
            try self.patchRelativeJump(state, jump_pos, fallback.continuation);
        }
    }

    fn lowerDynamicCall(
        self: *Lowerer,
        state: *LowerState,
        result: Code.ValueId,
        result_count: u8,
        call: Code.Call,
    ) Error!void {
        if (result_count != call.result_count) return error.InvalidCode;
        if (call.tail) return error.InvalidCode;
        try self.emitCallValues(
            state,
            call.callee,
            try state.range(call.args),
            result,
            result_count,
            false,
            call.self_target,
        );
    }

    fn lowerDirectCall(
        self: *Lowerer,
        state: *LowerState,
        result: Code.ValueId,
        result_count: u8,
        call: Code.DirectCall,
    ) Error!void {
        if (result_count != call.result_count) return error.InvalidCode;
        const target_index = @intFromEnum(call.function);
        if (target_index >= self.code.functions.len) return error.InvalidCode;
        const target = self.code.functions[target_index];
        const args = try state.range(call.args);
        const top_level: Code.FunctionId = @enumFromInt(0);
        if (call.function == state.function and state.function != top_level) {
            if (self.options.self_call and result_count == 1) {
                try self.emitDirectSelfCall(state, args, result);
            } else {
                try self.emitCurrentClosureCall(state, args, result, result_count);
            }
            return;
        }
        if (target.capture_count != 0) return error.Unsupported;
        try self.emitMaterializedCall(
            state,
            call.function,
            args,
            result,
            result_count,
            false,
        );
    }

    fn emitCallValues(
        self: *Lowerer,
        state: *LowerState,
        callee: Code.ValueId,
        args: []const Code.ValueId,
        result: Code.ValueId,
        result_count: u8,
        tail: bool,
        self_target: Code.FunctionId,
    ) Error!void {
        if (result_count == 0) return error.InvalidCode;
        const top_level: Code.FunctionId = @enumFromInt(0);
        try self.emitCallWindow(
            state,
            callee,
            args,
            result,
            result_count,
            tail,
            self_target != .invalid and
                self.options.self_call and
                result_count == 1 and
                state.function != top_level,
        );
        state.release(callee);
    }

    fn emitMaterializedCall(
        self: *Lowerer,
        state: *LowerState,
        function: Code.FunctionId,
        args: []const Code.ValueId,
        result: Code.ValueId,
        result_count: u8,
        tail: bool,
    ) Error!void {
        if (result_count == 0) return error.InvalidCode;
        const nargs = std.math.add(usize, args.len, 1) catch return error.RegisterOverflow;
        const width = @max(nargs, @as(usize, result_count));
        const rd = try state.allocBlock(width);
        try state.assignResults(result, result_count, rd);
        try self.emitClosureSite(state, rd, function, &.{});
        for (args, 0..) |argument, index| {
            const source = try state.regFor(argument);
            const destination: u8 = @intCast(@as(usize, rd) + 1 + index);
            try self.emitStage(state, destination, source);
            state.release(argument);
        }
        try self.appendCallOpcode(state, rd, nargs, result_count, tail, false);
        if (tail) {
            self.freeWindow(state, rd, width);
        } else {
            self.freeWindowTail(state, rd, width, result_count);
        }
    }

    fn emitDirectSelfCall(
        self: *Lowerer,
        state: *LowerState,
        args: []const Code.ValueId,
        result: Code.ValueId,
    ) Error!void {
        const nargs = std.math.add(usize, args.len, 1) catch return error.RegisterOverflow;
        const rd = try state.allocBlock(nargs);
        try state.assignResults(result, 1, rd);
        for (args, 0..) |argument, index| {
            const source = try state.regFor(argument);
            const destination: u8 = @intCast(@as(usize, rd) + 1 + index);
            try self.emitStage(state, destination, source);
            state.release(argument);
        }
        try self.appendCallOpcode(state, rd, nargs, 1, false, true);
        self.freeWindowTail(state, rd, nargs, 1);
    }

    fn emitCurrentClosureCall(
        self: *Lowerer,
        state: *LowerState,
        args: []const Code.ValueId,
        result: Code.ValueId,
        result_count: u8,
    ) Error!void {
        const nargs = std.math.add(usize, args.len, 1) catch return error.RegisterOverflow;
        const width = @max(nargs, @as(usize, result_count));
        const rd = try state.allocBlock(width);
        try state.assignResults(result, result_count, rd);
        try state.append(regvm.Inst.make(.get_self, @as(u24, rd) << 16));
        for (args, 0..) |argument, index| {
            const source = try state.regFor(argument);
            const destination: u8 = @intCast(@as(usize, rd) + 1 + index);
            try self.emitStage(state, destination, source);
            state.release(argument);
        }
        try self.appendCallOpcode(state, rd, nargs, result_count, false, false);
        self.freeWindowTail(state, rd, width, result_count);
    }

    fn emitCallWindow(
        self: *Lowerer,
        state: *LowerState,
        callee: Code.ValueId,
        args: []const Code.ValueId,
        result: Code.ValueId,
        result_count: u8,
        tail: bool,
        guarded_self: bool,
    ) Error!void {
        const callee_reg = try state.regFor(callee);
        const nargs = std.math.add(usize, args.len, 1) catch return error.RegisterOverflow;
        const width = @max(nargs, @as(usize, result_count));
        const reused_window = if (tail or (result != .invalid and result_count == 1))
            try state.reusableCallWindow(callee, args)
        else
            null;
        const rd = reused_window orelse try state.allocBlock(width);
        if (result != .invalid) try state.assignResults(result, result_count, rd);
        if (reused_window == null) {
            try self.emitStage(state, rd, callee_reg);
            for (args, 0..) |argument, index| {
                const source = try state.regFor(argument);
                const destination: u8 = @intCast(@as(usize, rd) + 1 + index);
                try self.emitStage(state, destination, source);
            }
        }
        for (args) |argument| state.release(argument);
        if (guarded_self) {
            try self.emitGuardedSelfCall(state, rd, nargs, tail);
        } else {
            try self.appendCallOpcode(state, rd, nargs, result_count, tail, false);
        }
        if (reused_window == null) {
            if (tail) {
                self.freeWindow(state, rd, width);
            } else {
                self.freeWindowTail(state, rd, width, result_count);
            }
        }
    }

    fn appendCallOpcode(
        self: *Lowerer,
        state: *LowerState,
        rd: u8,
        nargs: usize,
        result_count: u8,
        tail: bool,
        self_call: bool,
    ) Error!void {
        _ = self;
        if (nargs == 0 or nargs > std.math.maxInt(u8)) return error.RegisterOverflow;
        const arg_count: u8 = @intCast(nargs);
        if (result_count == 1) {
            const opcode: regvm.Opcode = if (self_call)
                (if (tail) .tail_self_call else .self_call)
            else
                (if (tail) .tail_call else .call);
            try state.append(regvm.Inst.make(opcode, (@as(u24, rd) << 16) | (@as(u24, arg_count) << 8)));
        } else {
            const opcode: regvm.Opcode = if (tail) .tail_call_multi else .call_multi;
            try state.append(regvm.Inst.make(opcode, (@as(u24, rd) << 16) |
                (@as(u24, arg_count) << 8) | result_count));
        }
    }

    fn emitGuardedSelfCall(self: *Lowerer, state: *LowerState, rd: u8, nargs: usize, tail: bool) Error!void {
        if (nargs == 0 or nargs > std.math.maxInt(u8)) return error.RegisterOverflow;
        const guard_pos = state.buf.items.len;
        try state.append(regvm.Inst.make(.guard_self, @as(u24, rd) << 16));
        try state.append(regvm.Formats.extensionWord(0));
        try self.appendCallOpcode(state, rd, nargs, 1, tail, true);
        if (!tail) {
            const jump_pos = state.buf.items.len;
            try state.append(regvm.Inst.make(.jmp, 0));
            const slow_start = state.buf.items.len;
            try self.appendCallOpcode(state, rd, nargs, 1, false, false);
            const after_slow = state.buf.items.len;
            try self.patchGuard(state, guard_pos, slow_start);
            try self.patchRelativeJump(state, jump_pos, after_slow);
        } else {
            const slow_start = state.buf.items.len;
            try self.appendCallOpcode(state, rd, nargs, 1, true, false);
            try self.patchGuard(state, guard_pos, slow_start);
        }
    }

    fn emitStage(self: *Lowerer, state: *LowerState, destination: u8, source: u8) Error!void {
        _ = self;
        if (destination == source) return;
        try state.append(regvm.Inst.make(.mov_reg, (@as(u24, destination) << 16) | source));
    }

    fn isSelfTailClosure(
        self: *const Lowerer,
        state: *const LowerState,
        result: Code.ValueId,
        closure: Code.MakeClosure,
    ) Error!bool {
        const function = self.code.function(state.function) orelse return error.InvalidCode;
        if (function.module_entry or closure.function != state.function) return false;
        const block_index = @intFromEnum(state.current_block);
        if (block_index >= self.code.blocks.len) return error.InvalidCode;
        const call = switch (self.code.blocks[block_index].terminator) {
            .tail_call => |tail_call| tail_call,
            else => return false,
        };
        if (call.callee != result or call.self_target != state.function) return false;
        const result_index = @intFromEnum(result);
        if (result_index >= state.uses.len or state.uses[result_index] != 1) return false;
        const captures = try state.range(closure.captures);
        const capture_start: usize = function.capture_start;
        const capture_end = std.math.add(usize, capture_start, function.capture_count) catch
            return error.InvalidCode;
        if (capture_end > self.code.capture_values.len or captures.len != function.capture_count) {
            return false;
        }
        for (captures, self.code.capture_values[capture_start..capture_end]) |capture, expected| {
            if (capture != expected) return false;
        }
        return true;
    }

    fn lowerClosure(
        self: *Lowerer,
        state: *LowerState,
        result: Code.ValueId,
        result_count: u8,
        closure: Code.MakeClosure,
    ) Error!void {
        if (result_count != 1) return error.InvalidCode;
        const child_index = @intFromEnum(closure.function);
        if (child_index >= self.fns.len) return error.InvalidCode;
        const captures = try state.range(closure.captures);
        const child = self.code.functions[child_index];
        if (captures.len != child.capture_count) return error.InvalidCode;
        const self_tail = try self.isSelfTailClosure(state, result, closure);
        var alias_reg: ?u8 = null;
        for (captures) |capture| {
            const capture_index = try state.valueIndex(capture);
            if (state.uses[capture_index] != 1) continue;
            const source = try state.regFor(capture);
            if (state.valueIsLiveAtOtherIndex(capture_index, source)) continue;
            alias_reg = source;
            break;
        }
        const rd = alias_reg orelse try state.allocBlock(1);
        try state.assignResults(result, 1, rd);
        // A sole-use self-tail closure has no observable identity; reuse the
        // executing closure to avoid allocating on every recursive iteration.
        if (self_tail) {
            try state.append(regvm.Inst.make(.get_self, @as(u24, rd) << 16));
        } else {
            try self.emitClosureSite(state, rd, closure.function, captures);
        }
        for (captures) |capture| state.release(capture);
    }

    fn emitClosureSite(
        self: *Lowerer,
        state: *LowerState,
        destination: u8,
        function: Code.FunctionId,
        captures: []const Code.ValueId,
    ) Error!void {
        if (@intFromEnum(function) >= self.fns.len) return error.InvalidCode;
        if (state.closure_sites.items.len > std.math.maxInt(u16)) return error.Unsupported;
        if (captures.len > std.math.maxInt(u8)) return error.Unsupported;
        const index: u16 = @intCast(state.closure_sites.items.len);
        const start = state.capture_regs.items.len;
        if (start > std.math.maxInt(u32) - captures.len) return error.Unsupported;
        for (captures) |capture| {
            try state.capture_regs.append(self.scratch_allocator, try state.regFor(capture));
        }
        try state.closure_sites.append(self.scratch_allocator, .{
            .function = function,
            .capture_start = @intCast(start),
            .capture_count = @intCast(captures.len),
        });
        try state.append(regvm.Inst.make(.make_closure, (@as(u24, destination) << 16) | index));
    }

    fn lowerTryBegin(self: *Lowerer, state: *LowerState, handler_id: Code.HandlerId) Error!void {
        const handler_index = @intFromEnum(handler_id);
        if (handler_index >= self.code.handlers.len) return error.InvalidCode;
        const handler = self.code.handlers[handler_index];
        if (handler.function != state.function) return error.InvalidCode;
        const exception = try state.regFor(handler.exception);
        const position = state.buf.items.len;
        try state.append(regvm.Inst.make(.@"try", @as(u24, exception) << 16));
        state.patches.append(self.scratch_allocator, .{
            .pos = position,
            .target = handler.landing,
            .kind = .try_begin,
            .register = exception,
        }) catch return error.OutOfMemory;
    }

    fn lowerTerminator(self: *Lowerer, state: *LowerState, term: Code.Terminator) Error!void {
        switch (term) {
            .none => return error.InvalidCode,
            .jump => |edge| {
                try self.emitEdgeMoves(state, edge);
                const position = state.buf.items.len;
                try state.append(regvm.Inst.make(.jmp, 0));
                try self.addPatch(state, position, edge.target, .jmp, 0);
            },
            .branch => |branch| try self.emitBranch(state, branch),
            .return_values => |values| {
                const function = self.code.function(state.function) orelse return error.InvalidCode;
                const operands = try state.range(values);
                if (operands.len != function.result_count or operands.len == 0) return error.InvalidCode;
                if (operands.len == 1) {
                    const reg = try state.regFor(operands[0]);
                    const opcode: regvm.Opcode = if (function.module_entry)
                        .stop
                    else
                        .ret;
                    try state.append(regvm.Inst.make(opcode, @as(u24, reg) << 16));
                    state.release(operands[0]);
                } else {
                    try self.emitMultiReturn(state, operands);
                }
            },
            .raise => |value| {
                const reg = try state.regFor(value);
                try state.append(regvm.Inst.make(.raise, @as(u24, reg) << 16));
                state.release(value);
            },
            .tail_call => |call| {
                const function = self.code.function(state.function) orelse return error.InvalidCode;
                if (call.result_count != function.result_count) return error.InvalidCode;
                try self.emitCallValues(
                    state,
                    call.callee,
                    try state.range(call.args),
                    .invalid,
                    call.result_count,
                    true,
                    call.self_target,
                );
            },
        }
    }

    fn emitMultiReturn(self: *Lowerer, state: *LowerState, operands: []const Code.ValueId) Error!void {
        const count = operands.len;
        if (count > std.math.maxInt(u8)) return error.RegisterOverflow;
        var direct_base: ?u8 = null;
        const first_reg = try state.regFor(operands[0]);
        if (@as(u16, first_reg) + @as(u16, @intCast(count)) <= std.math.maxInt(u8)) {
            var contiguous = true;
            for (operands, 0..) |operand, index| {
                if (try state.regFor(operand) != @as(u8, @intCast(@as(usize, first_reg) + index))) {
                    contiguous = false;
                    break;
                }
            }
            if (contiguous) direct_base = first_reg;
        }
        const base = direct_base orelse try state.allocBlock(count);
        if (direct_base == null) {
            for (operands, 0..) |operand, index| {
                const source = try state.regFor(operand);
                try self.emitStage(state, @intCast(@as(usize, base) + index), source);
            }
        }
        try state.append(regvm.Inst.make(.ret_multi, (@as(u24, base) << 16) | @as(u24, @intCast(count))));
        for (operands) |operand| state.release(operand);
        if (direct_base == null) self.freeWindow(state, base, count);
    }

    fn emitEdgeMoves(self: *Lowerer, state: *LowerState, edge: Code.Edge) Error!void {
        const target_index = @intFromEnum(edge.target);
        if (target_index >= self.code.blocks.len) return error.InvalidCode;
        const target = self.code.blocks[target_index];
        const args = try state.range(edge.args);
        if (args.len != target.param_count) return error.InvalidCode;
        if (args.len > 256) return error.RegisterOverflow;
        const first: usize = target.param_start;
        const last = std.math.add(usize, first, target.param_count) catch return error.InvalidCode;
        if (last > self.code.block_parameters.len) return error.InvalidCode;
        var moves: [256]Move = undefined;
        var move_count: usize = 0;
        for (args, 0..) |argument, index| {
            const source = try state.regFor(argument);
            const destination = try state.regFor(self.code.block_parameters[first + index]);
            if (source == destination) continue;
            moves[move_count] = .{ .source = source, .destination = destination };
            move_count += 1;
        }
        // Save every source that is also a destination before writing any
        // destination. This is a bounded parallel-copy implementation and
        // handles swaps and loop back-edges without clobbering values.
        for (0..move_count) |index| {
            var source_is_destination = false;
            for (0..move_count) |other| {
                if (moves[other].destination == moves[index].source) {
                    source_is_destination = true;
                    break;
                }
            }
            if (!source_is_destination) continue;
            const temporary = try state.allocReg();
            try state.append(regvm.Inst.make(.mov_reg, (@as(u24, temporary) << 16) | moves[index].source));
            moves[index].temporary = temporary;
        }
        for (moves[0..move_count]) |move| {
            const source = move.temporary orelse move.source;
            try state.append(regvm.Inst.make(.mov_reg, (@as(u24, move.destination) << 16) | source));
        }
        for (0..move_count) |index| {
            if (moves[index].temporary) |temporary| state.allocator.freeReg(temporary);
        }
        for (args) |argument| state.release(argument);
    }

    fn emitBranch(self: *Lowerer, state: *LowerState, branch: Code.Branch) Error!void {
        const condition = try state.regFor(branch.condition);
        const then_index = @intFromEnum(branch.then_edge.target);
        const else_index = @intFromEnum(branch.else_edge.target);
        if (then_index >= self.code.blocks.len or else_index >= self.code.blocks.len) return error.InvalidCode;
        const then_target = self.code.blocks[then_index];
        const else_target = self.code.blocks[else_index];
        if (then_target.param_count == 0 and else_target.param_count == 0) {
            const branch_pos = state.buf.items.len;
            try state.append(regvm.Inst.make(.br, @as(u24, condition) << 16));
            try self.addPatch(state, branch_pos, branch.then_edge.target, .br, condition);
            try self.emitEdgeMoves(state, branch.else_edge);
            const jump_pos = state.buf.items.len;
            try state.append(regvm.Inst.make(.jmp, 0));
            try self.addPatch(state, jump_pos, branch.else_edge.target, .jmp, 0);
            state.release(branch.condition);
            return;
        }
        const condition_copy = try state.allocReg();
        try state.append(regvm.Inst.make(.mov_reg, (@as(u24, condition_copy) << 16) | condition));
        const branch_pos = state.buf.items.len;
        try state.append(regvm.Inst.make(.br, @as(u24, condition_copy) << 16));
        const jump_pos = state.buf.items.len;
        try state.append(regvm.Inst.make(.jmp, 0));
        const then_trampoline = state.buf.items.len;
        try self.emitEdgeMoves(state, branch.then_edge);
        const then_jump = state.buf.items.len;
        try state.append(regvm.Inst.make(.jmp, 0));
        const else_trampoline = state.buf.items.len;
        try self.emitEdgeMoves(state, branch.else_edge);
        const else_jump = state.buf.items.len;
        try state.append(regvm.Inst.make(.jmp, 0));
        try self.patchBranchOffset(state, branch_pos, then_trampoline);
        try self.patchRelativeJump(state, jump_pos, else_trampoline);
        try self.addPatch(state, then_jump, branch.then_edge.target, .jmp, 0);
        try self.addPatch(state, else_jump, branch.else_edge.target, .jmp, 0);
        state.allocator.freeReg(condition_copy);
        state.release(branch.condition);
    }

    fn addPatch(
        self: *Lowerer,
        state: *LowerState,
        position: usize,
        target: Code.BlockId,
        kind: PatchKind,
        register: u8,
    ) Error!void {
        _ = self;
        state.patches.append(state.lowerer.scratch_allocator, .{
            .pos = position,
            .target = target,
            .kind = kind,
            .register = register,
        }) catch return error.OutOfMemory;
    }

    fn patch(self: *Lowerer, state: *LowerState) Error!void {
        _ = self;
        for (state.patches.items) |entry| {
            const target_index = @intFromEnum(entry.target);
            if (target_index >= state.labels.len) return error.InvalidCode;
            const target = state.labels[target_index] orelse return error.InvalidCode;
            const offset = @as(isize, @intCast(target)) - @as(isize, @intCast(entry.pos)) - 1;
            switch (entry.kind) {
                .jmp => {
                    if (offset < std.math.minInt(i24) or offset > std.math.maxInt(i24)) return error.Unsupported;
                    state.buf.items[entry.pos] = regvm.Inst.make(.jmp, @as(u24, @bitCast(@as(i24, @intCast(offset)))));
                },
                .br => {
                    if (offset < std.math.minInt(i16) or offset > std.math.maxInt(i16)) return error.Unsupported;
                    state.buf.items[entry.pos] = regvm.Inst.make(.br, (@as(u24, entry.register) << 16) |
                        @as(u24, @as(u16, @bitCast(@as(i16, @intCast(offset))))));
                },
                .try_begin => {
                    if (offset < std.math.minInt(i16) or offset > std.math.maxInt(i16)) return error.Unsupported;
                    state.buf.items[entry.pos] = regvm.Inst.make(.@"try", (@as(u24, entry.register) << 16) |
                        @as(u24, @as(u16, @bitCast(@as(i16, @intCast(offset))))));
                },
            }
        }
    }

    fn patchGuard(self: *Lowerer, state: *LowerState, guard_pos: usize, slow_start: usize) Error!void {
        _ = self;
        if (slow_start < guard_pos + 2) return error.InvalidCode;
        const offset = slow_start - (guard_pos + 2);
        if (offset > std.math.maxInt(u32)) return error.Unsupported;
        state.buf.items[guard_pos + 1] = regvm.Formats.extensionWord(@intCast(offset));
    }

    fn patchRelativeJump(self: *Lowerer, state: *LowerState, jump_pos: usize, target: usize) Error!void {
        _ = self;
        const target_index = std.math.cast(isize, target) orelse return error.Unsupported;
        const origin = std.math.cast(isize, jump_pos) orelse return error.Unsupported;
        const offset = target_index - origin - 1;
        if (offset < std.math.minInt(i24) or offset > std.math.maxInt(i24)) return error.Unsupported;
        state.buf.items[jump_pos] = regvm.Inst.make(.jmp, @as(u24, @bitCast(@as(i24, @intCast(offset)))));
    }

    fn patchBranchOffset(self: *Lowerer, state: *LowerState, branch_pos: usize, target: usize) Error!void {
        _ = self;
        if (target <= branch_pos) return error.Unsupported;
        const offset = target - branch_pos - 1;
        if (offset > @as(usize, @intCast(std.math.maxInt(i16)))) return error.Unsupported;
        const predicate = regvm.Formats.slot(state.buf.items[branch_pos].payload);
        state.buf.items[branch_pos] = regvm.Inst.make(.br, (@as(u24, predicate) << 16) |
            @as(u24, @as(u16, @intCast(offset))));
    }

    fn freeWindow(self: *Lowerer, state: *LowerState, base: u8, count: usize) void {
        _ = self;
        for (0..count) |offset| {
            const register: u8 = @intCast(@as(usize, base) + offset);
            if (state.fixed_regs.isSet(register)) continue;
            if (!state.allocator.free.isSet(register)) state.allocator.freeReg(register);
        }
    }

    fn freeWindowTail(self: *Lowerer, state: *LowerState, base: u8, width: usize, result_count: u8) void {
        if (width <= result_count) return;
        self.freeWindow(state, @intCast(@as(usize, base) + result_count), width - result_count);
    }
};

fn tsSingle(types: u64) bool {
    return @popCount(types) == 1;
}

fn arithOpcodeForType(op: Code.ArithOp, type_index: u64) ?regvm.Opcode {
    if (type_index == @intFromEnum(builtins.type_i64)) {
        return switch (op) {
            .add => .add_i64,
            .sub => .sub_i64,
            .mul => .mul_i64,
            .div => .div_i64,
            .equal => .eq_i64,
            .less => .lt_i64,
            .greater => .gt_i64,
        };
    }
    if (type_index == @intFromEnum(builtins.type_f64)) {
        return switch (op) {
            .add => .add_f64,
            .sub => .sub_f64,
            .mul => .mul_f64,
            .div => .div_f64,
            .equal => .eq_f64,
            .less => .lt_f64,
            .greater => .gt_f64,
        };
    }
    return null;
}

const CopyMap = struct {
    source: [256]u8 = [_]u8{0} ** 256,
    valid: [256]bool = [_]bool{false} ** 256,

    fn resolve(self: *const CopyMap, register: u8) u8 {
        return if (self.valid[register]) self.source[register] else register;
    }

    fn invalidate(self: *CopyMap, register: u8) void {
        for (0..256) |index| {
            if (self.valid[index] and self.source[index] == register) self.valid[index] = false;
        }
        self.valid[register] = false;
    }

    fn record(self: *CopyMap, destination: u8, source: u8) void {
        self.source[destination] = source;
        self.valid[destination] = true;
    }

    fn reset(self: *CopyMap) void {
        @memset(&self.valid, false);
    }
};

fn registerBit(register: u8) u256 {
    return @as(u256, 1) << @intCast(register);
}

fn copyPropagateCallsInvalidate(
    ir: []regvm.Inst,
    index: usize,
    copies: *CopyMap,
) void {
    const inst = ir[index];
    switch (inst.opcode) {
        .call, .tail_call, .self_call, .tail_self_call => {
            const rd = regvm.Formats.rdNargsFlags(inst.payload)[0];
            copies.invalidate(rd);
        },
        .call_builtin_0,
        .call_builtin_1,
        .call_builtin_2,
        .call_builtin_3,
        .call_builtin_ext,
        => copies.invalidate(regvm.Formats.builtinIndexBase(inst.payload)[1]),
        .call_multi, .tail_call_multi => {
            const fields = regvm.Formats.rdNargsFlags(inst.payload);
            const rd = fields[0];
            const result_count = fields[2];
            if (regvm.registerRangeMask(rd, result_count)) |mask| {
                var remaining = mask;
                while (remaining != 0) {
                    const register: u8 = @intCast(@ctz(remaining));
                    copies.invalidate(register);
                    remaining &= remaining - 1;
                }
            } else {
                copies.reset();
            }
        },
        else => {},
    }
}

/// Copy propagation over instruction boundaries. Guards remain barriers
/// because their extension words are part of the control edge.
pub fn copyPropagate(
    scratch: Allocator,
    ir: []regvm.Inst,
    closure_sites: []const ClosureSite,
    capture_regs: []u8,
    context: ?*const EvalContext,
) Error![]regvm.Inst {
    if (context) |ctx| try ctx.chargeWork(ir.len, 8, .code);
    if (ir.len == 0) return ir;
    // Validate multiword boundaries before mutating the instruction stream.
    const boundaries = try scratch.alloc(bool, ir.len);
    defer scratch.free(boundaries);
    @memset(boundaries, false);
    var scan: usize = 0;
    while (scan < ir.len) {
        const inst = ir[scan];
        if (inst.opcode == .guard_callee or inst.opcode == .guard_self) return ir;
        const size = regvm.instructionSize(inst.opcode);
        if (size > ir.len - scan) return ir;
        if (inst.opcode == .call_builtin_ext and !regvm.registerAccessAt(ir, scan).valid) {
            return ir;
        }
        if (inst.opcode == .make_closure) {
            const index = regvm.Formats.rdAndSidx(inst.payload)[1];
            if (index >= closure_sites.len) return ir;
            if (closure_sites[index].captures(capture_regs) == null) return ir;
        }
        boundaries[scan] = true;
        scan += size;
    }
    // The passes mutate capture values, not the validated range metadata.
    const targets = try scratch.alloc(bool, ir.len);
    defer scratch.free(targets);
    @memset(targets, false);
    const live = try scratch.alloc(u256, ir.len);
    defer scratch.free(live);
    @memset(live, 0);
    const dead = try scratch.alloc(bool, ir.len);
    defer scratch.free(dead);
    @memset(dead, false);
    const new_index = try scratch.alloc(usize, ir.len);
    defer scratch.free(new_index);
    @memset(new_index, 0);
    const old_index = try scratch.alloc(usize, ir.len);
    defer scratch.free(old_index);
    @memset(old_index, 0);

    scan = 0;
    while (scan < ir.len) : (scan += regvm.instructionSize(ir[scan].opcode)) {
        const inst = ir[scan];
        const index = scan;
        switch (inst.opcode) {
            .br, .brn => {
                const offset = regvm.Formats.rdOffset(inst.payload)[1];
                const target = @as(isize, @intCast(index)) + 1 + @as(isize, offset);
                if (target < 0 or target >= ir.len or target <= index) return ir;
                if (!boundaries[@intCast(target)]) return ir;
                targets[@intCast(target)] = true;
            },
            .jmp => {
                const offset = regvm.Formats.imm24(inst.payload);
                const target = @as(isize, @intCast(index)) + 1 + @as(isize, offset);
                if (target < 0 or target >= ir.len or target <= index) return ir;
                if (!boundaries[@intCast(target)]) return ir;
                targets[@intCast(target)] = true;
            },
            .@"try" => {
                const offset_u = regvm.Formats.rdAndSidx(inst.payload)[1];
                const target = @as(isize, @intCast(index)) + 1 +
                    @as(isize, @as(i16, @bitCast(offset_u)));
                if (target < 0 or target >= ir.len or target <= index) return ir;
                if (!boundaries[@intCast(target)]) return ir;
                targets[@intCast(target)] = true;
            },
            else => {},
        }
    }

    var copies: CopyMap = .{};
    scan = 0;
    while (scan < ir.len) {
        const index = scan;
        const inst = &ir[scan];
        scan += regvm.instructionSize(inst.opcode);
        if (targets[index]) copies.reset();
        if (regvm.isArithmetic(inst.opcode)) {
            const rd, const left, const right = regvm.Formats.rdRs1Rs2(inst.payload);
            inst.payload = (@as(u24, rd) << 16) |
                (@as(u24, copies.resolve(left)) << 8) | copies.resolve(right);
            copies.invalidate(rd);
            continue;
        }
        switch (inst.opcode) {
            .mov_reg => {
                const rd, const source_u = regvm.Formats.rdAndSidx(inst.payload);
                const source = copies.resolve(@truncate(source_u));
                inst.payload = (@as(u24, rd) << 16) | source;
                copies.invalidate(rd);
                copies.record(rd, source);
            },
            .set, .set_existing => {
                const source, const symbol = regvm.Formats.rdAndSidx(inst.payload);
                inst.payload = (@as(u24, copies.resolve(source)) << 16) | symbol;
            },
            .call,
            .tail_call,
            .call_builtin_0,
            .call_builtin_1,
            .call_builtin_2,
            .call_builtin_3,
            .call_builtin_ext,
            .self_call,
            .tail_self_call,
            .call_multi,
            .tail_call_multi,
            => copyPropagateCallsInvalidate(ir, index, &copies),
            .make_closure => {
                const rd, const site_index = regvm.Formats.rdAndSidx(inst.payload);
                const site = closure_sites[site_index];
                const captures = capture_regs[site.capture_start..][0..site.capture_count];
                for (captures, 0..) |source, offset| {
                    capture_regs[site.capture_start + offset] = copies.resolve(source);
                }
                copies.invalidate(rd);
            },
            .mov_i64, .load, .ns_push, .lookup, .lookup_val, .get_self => copies.invalidate(
                regvm.Formats.slot(inst.payload),
            ),
            .raise => copies.reset(),
            .@"try" => copies.reset(),
            .src, .end_try, .nop, .start, .enter, .jmp, .br, .brn, .stop, .ret, .ret_multi, .ns_pop => {},
            else => copies.reset(),
        }
    }

    var carried: u256 = 0;
    var index = ir.len;
    while (index > 0) {
        index -= 1;
        if (!boundaries[index]) continue;
        const inst = ir[index];
        var out = carried;
        switch (inst.opcode) {
            .br, .brn => {
                const offset = regvm.Formats.rdOffset(inst.payload)[1];
                const target = @as(isize, @intCast(index)) + 1 + @as(isize, offset);
                if (target <= @as(isize, @intCast(index)) or target >= ir.len) return ir;
                out |= live[@intCast(target)];
            },
            .jmp => {
                const offset = regvm.Formats.imm24(inst.payload);
                const target = @as(isize, @intCast(index)) + 1 + @as(isize, offset);
                if (target <= @as(isize, @intCast(index)) or target >= ir.len) return ir;
                out = live[@intCast(target)];
            },
            .@"try" => {
                const offset_u = regvm.Formats.rdAndSidx(inst.payload)[1];
                const target = @as(isize, @intCast(index)) + 1 +
                    @as(isize, @as(i16, @bitCast(offset_u)));
                if (target <= @as(isize, @intCast(index)) or target >= ir.len) return ir;
                out |= live[@intCast(target)] & ~registerBit(regvm.Formats.slot(inst.payload));
            },
            .stop, .ret, .ret_multi, .raise, .tail_call, .tail_call_multi, .tail_self_call => out = 0,
            else => {},
        }
        if (inst.opcode == .mov_reg) {
            const destination, const source_u = regvm.Formats.rdAndSidx(inst.payload);
            const source: u8 = @truncate(source_u);
            if (destination == source or (out & registerBit(destination)) == 0) dead[index] = true;
        }
        var input = out;
        if (regvm.isArithmetic(inst.opcode)) {
            const rd, const left, const right = regvm.Formats.rdRs1Rs2(inst.payload);
            input &= ~registerBit(rd);
            input |= registerBit(left) | registerBit(right);
        } else switch (inst.opcode) {
            .mov_reg => {
                const rd, const source_u = regvm.Formats.rdAndSidx(inst.payload);
                const source: u8 = @truncate(source_u);
                input &= ~registerBit(rd);
                input |= registerBit(source);
            },
            .set, .set_existing => {
                const source, _ = regvm.Formats.rdAndSidx(inst.payload);
                input |= registerBit(source);
            },
            .make_closure => {
                const rd, const site_index = regvm.Formats.rdAndSidx(inst.payload);
                input &= ~registerBit(rd);
                const site = closure_sites[site_index];
                for (capture_regs[site.capture_start..][0..site.capture_count]) |source| {
                    input |= registerBit(source);
                }
            },
            .mov_i64, .load, .ns_push, .lookup, .lookup_val, .get_self => input &= ~registerBit(
                regvm.Formats.slot(inst.payload),
            ),
            .call, .tail_call => {
                const rd, const nargs, _ = regvm.Formats.rdNargsFlags(inst.payload);
                input &= ~registerBit(rd);
                for (0..nargs) |offset| input |= registerBit(rd + @as(u8, @intCast(offset)));
            },
            .self_call, .tail_self_call => {
                const rd, const nargs, _ = regvm.Formats.rdNargsFlags(inst.payload);
                input &= ~registerBit(rd);
                var offset: u8 = 1;
                while (offset < nargs) : (offset += 1) input |= registerBit(rd + offset);
            },
            .call_builtin_0,
            .call_builtin_1,
            .call_builtin_2,
            .call_builtin_3,
            .call_builtin_ext,
            => {
                const access = regvm.registerAccessAt(ir, index);
                if (!access.valid) return ir;
                input = (input & ~access.writes) | access.reads;
            },
            .call_multi, .tail_call_multi => {
                const rd, const nargs, const result_count = regvm.Formats.rdNargsFlags(inst.payload);
                if (regvm.registerRangeMask(rd, result_count)) |mask| input &= ~mask else return ir;
                for (0..nargs) |offset| input |= registerBit(rd + @as(u8, @intCast(offset)));
            },
            .br, .brn, .stop, .ret => input |= registerBit(regvm.Formats.slot(inst.payload)),
            .ret_multi => {
                const rd = regvm.Formats.slot(inst.payload);
                const count: u8 = @truncate(inst.payload);
                if (regvm.registerRangeMask(rd, count)) |mask| input |= mask else return ir;
            },
            .raise => input |= registerBit(regvm.Formats.slot(inst.payload)),
            .nop, .start, .enter, .jmp, .src, .end_try, .@"try", .ns_pop => {},
            else => input = std.math.maxInt(u256),
        }
        live[index] = input;
        carried = input;
    }

    var destination: usize = 0;
    for (ir, 0..) |_, old| {
        new_index[old] = destination;
        if (!dead[old]) {
            old_index[destination] = old;
            destination += 1;
        }
    }
    if (destination == ir.len) return ir;
    var write_index: usize = 0;
    for (ir, 0..) |inst, old| {
        if (dead[old]) continue;
        ir[write_index] = inst;
        write_index += 1;
    }
    for (0..destination) |new| {
        const old = old_index[new];
        const inst = &ir[new];
        switch (inst.opcode) {
            .br, .brn, .@"try" => {
                const register, const offset = regvm.Formats.rdOffset(inst.payload);
                const target = @as(isize, @intCast(old)) + 1 + @as(isize, offset);
                const shifted = new_index[@intCast(target)];
                const new_offset: i16 = @intCast(@as(isize, @intCast(shifted)) - @as(isize, @intCast(new)) - 1);
                inst.payload = (@as(u24, register) << 16) | @as(u24, @as(u16, @bitCast(new_offset)));
            },
            .jmp => {
                const offset = regvm.Formats.imm24(inst.payload);
                const target = @as(isize, @intCast(old)) + 1 + @as(isize, offset);
                const shifted = new_index[@intCast(target)];
                const new_offset: i24 = @intCast(@as(isize, @intCast(shifted)) - @as(isize, @intCast(new)) - 1);
                inst.payload = @as(u24, @bitCast(new_offset));
            },
            else => {},
        }
    }
    return ir[0..destination];
}

fn flagReadIfUnwritten(must: u32, register: u8, mask: *u32) void {
    if (register >= 32) return;
    const bit = @as(u32, 1) << @as(u5, @intCast(register));
    if ((must & bit) == 0) mask.* |= bit;
}

/// Compute the conservative zero-before-read mask for one closure body.
pub fn computeZeroMask(
    scratch: Allocator,
    ir: []const regvm.Inst,
    nregs: u8,
    argc: usize,
    ncap: usize,
    closure_sites: []const ClosureSite,
    capture_regs: []const u8,
    context: ?*const EvalContext,
) Error!u32 {
    if (context) |ctx| try ctx.chargeWork(ir.len, 1, .code);
    const conservative = std.math.maxInt(u32);
    if (ir.len == 0 or nregs == 0) return conservative;
    const seeded_count = std.math.add(usize, argc, ncap) catch return conservative;
    const seeded_end = std.math.add(usize, seeded_count, 1) catch return conservative;
    if (seeded_end > nregs) return conservative;

    // An extension is not an instruction start, so no control edge may enter it.
    const boundaries = try scratch.alloc(bool, ir.len);
    defer scratch.free(boundaries);
    @memset(boundaries, false);
    var scan: usize = 0;
    while (scan < ir.len) {
        boundaries[scan] = true;
        const size: usize = regvm.instructionSize(ir[scan].opcode);
        if (!regvm.registerAccessAt(ir, scan).valid) return conservative;
        if (ir[scan].opcode == .make_closure) {
            const site_index = regvm.Formats.rdAndSidx(ir[scan].payload)[1];
            if (site_index >= closure_sites.len or
                closure_sites[site_index].captures(capture_regs) == null)
            {
                return conservative;
            }
        }
        scan = std.math.add(usize, scan, size) catch return conservative;
        if (scan > ir.len) return conservative;
    }

    const must_in = scratch.alloc(u32, ir.len) catch return conservative;
    defer scratch.free(must_in);
    @memset(must_in, conservative);
    const reachable = scratch.alloc(bool, ir.len) catch return conservative;
    defer scratch.free(reachable);
    @memset(reachable, false);

    var seeded: u32 = 0;
    for (1..seeded_end) |register| {
        if (register < 32) seeded |= @as(u32, 1) << @as(u5, @intCast(register));
    }
    must_in[0] = seeded;
    reachable[0] = true;

    var mask: u32 = 0;
    // Every edge only adds reachability or removes bits from must_in, so this
    // monotone solver reaches a fixed point even when a branch targets an
    // earlier instruction.
    while (true) {
        if (context) |ctx| try ctx.chargeWork(ir.len, 1, .code);
        var changed = false;
        var index: usize = 0;
        while (index < ir.len) {
            const inst = ir[index];
            const size: usize = regvm.instructionSize(inst.opcode);
            const next = std.math.add(usize, index, size) catch return conservative;
            if (next > ir.len) return conservative;
            if (!reachable[index]) {
                index = next;
                continue;
            }

            const must = must_in[index];
            var access = regvm.registerAccessAt(ir, index);
            if (inst.opcode == .make_closure) {
                const site_index = regvm.Formats.rdAndSidx(inst.payload)[1];
                if (site_index >= closure_sites.len) return conservative;
                const captures = closure_sites[site_index].captures(capture_regs) orelse
                    return conservative;
                for (captures) |source| access.reads |= registerBit(source);
            }
            if (!access.valid) return conservative;
            var reads: u32 = @truncate(access.reads);
            while (reads != 0) {
                const register: u8 = @ctz(reads);
                flagReadIfUnwritten(must, register, &mask);
                reads &= reads - 1;
            }
            const must_out = must | @as(u32, @truncate(access.writes));

            if (!access.terminal and inst.opcode != .jmp) {
                if (next >= ir.len or !boundaries[next]) return conservative;
                if (!reachable[next]) {
                    reachable[next] = true;
                    changed = true;
                }
                const joined = must_in[next] & must_out;
                if (joined != must_in[next]) {
                    must_in[next] = joined;
                    changed = true;
                }
            }

            switch (inst.opcode) {
                .br, .brn => {
                    const offset = regvm.Formats.rdOffset(inst.payload)[1];
                    const target = @as(isize, @intCast(index)) + 1 + @as(isize, offset);
                    if (target < 0 or target >= @as(isize, @intCast(ir.len))) {
                        return conservative;
                    }
                    const target_index: usize = @intCast(target);
                    if (!boundaries[target_index]) return conservative;
                    if (!reachable[target_index]) {
                        reachable[target_index] = true;
                        changed = true;
                    }
                    const joined = must_in[target_index] & must_out;
                    if (joined != must_in[target_index]) {
                        must_in[target_index] = joined;
                        changed = true;
                    }
                },
                .jmp => {
                    const offset = regvm.Formats.imm24(inst.payload);
                    const target = @as(isize, @intCast(index)) + 1 + @as(isize, offset);
                    if (target < 0 or target >= @as(isize, @intCast(ir.len))) {
                        return conservative;
                    }
                    const target_index: usize = @intCast(target);
                    if (!boundaries[target_index]) return conservative;
                    if (!reachable[target_index]) {
                        reachable[target_index] = true;
                        changed = true;
                    }
                    const joined = must_in[target_index] & must_out;
                    if (joined != must_in[target_index]) {
                        must_in[target_index] = joined;
                        changed = true;
                    }
                },
                .@"try" => {
                    const offset_u = regvm.Formats.rdAndSidx(inst.payload)[1];
                    const target = @as(isize, @intCast(index)) + 1 +
                        @as(isize, @as(i16, @bitCast(offset_u)));
                    if (target < 0 or target >= @as(isize, @intCast(ir.len))) {
                        return conservative;
                    }
                    const target_index: usize = @intCast(target);
                    if (!boundaries[target_index]) return conservative;
                    if (!reachable[target_index]) {
                        reachable[target_index] = true;
                        changed = true;
                    }
                    const exceptional_out = must_out | @as(u32, @truncate(access.exceptional_writes));
                    const joined = must_in[target_index] & exceptional_out;
                    if (joined != must_in[target_index]) {
                        must_in[target_index] = joined;
                        changed = true;
                    }
                },
                .guard_callee, .guard_self => {
                    if (size != 2 or next >= ir.len) return conservative;
                    const offset = regvm.Formats.extension(ir[index + 1]);
                    const target = std.math.add(usize, next, @as(usize, offset)) catch
                        return conservative;
                    if (target >= ir.len or !boundaries[target]) return conservative;
                    if (!reachable[target]) {
                        reachable[target] = true;
                        changed = true;
                    }
                    const joined = must_in[target] & must_out;
                    if (joined != must_in[target]) {
                        must_in[target] = joined;
                        changed = true;
                    }
                },
                else => {},
            }
            index = next;
        }
        if (!changed) break;
    }

    if (nregs < 32) mask &= (@as(u32, 1) << @as(u5, @intCast(nregs))) - 1;
    return mask;
}

pub fn lower(
    output_allocator: Allocator,
    scratch_allocator: Allocator,
    code: *const Code.Code,
    resolve: ResolveContext,
    options: Options,
) Error!RegProgram {
    var lowerer = Lowerer.init(output_allocator, scratch_allocator, code, resolve, options);
    return lowerer.lower();
}

test "copy propagation declines malformed capture metadata before changing inputs" {
    const original = [_]regvm.Inst{
        regvm.Inst.make(.mov_reg, 1 << 16),
        regvm.Inst.make(.make_closure, 2 << 16),
        regvm.Inst.make(.make_closure, (3 << 16) | 1),
        regvm.Inst.make(.ret, 2 << 16),
    };
    var ir = original;
    var capture_regs = [_]u8{1};
    const sites = [_]ClosureSite{
        .{ .function = @enumFromInt(0), .capture_start = 0, .capture_count = 1 },
        .{ .function = @enumFromInt(0), .capture_start = 1, .capture_count = 1 },
    };
    const result = try copyPropagate(std.testing.allocator, &ir, &sites, &capture_regs, null);
    try std.testing.expectEqualSlices(regvm.Inst, &original, result);
    try std.testing.expectEqualSlices(u8, &.{1}, &capture_regs);
}

test "copy propagation removes dead moves without splitting extended intrinsic calls" {
    var ir = [_]regvm.Inst{
        .make(.mov_reg, 9 << 16),
        .make(.jmp, 1),
        .make(.mov_reg, 8 << 16),
        .make(.call_builtin_ext, (551 << 8) | 1),
        regvm.Formats.extensionWord(4),
        .make(.stop, 1 << 16),
    };
    const optimized = try copyPropagate(std.testing.allocator, &ir, &.{}, &.{}, null);
    try std.testing.expectEqualSlices(regvm.Inst, &.{
        .make(.jmp, 0),
        .make(.call_builtin_ext, (551 << 8) | 1),
        regvm.Formats.extensionWord(4),
        .make(.stop, 1 << 16),
    }, optimized);
    try validateBytecode(std.testing.allocator, optimized, 10, 0, &.{}, &.{});
}

test "zero mask distinguishes initialized and uninitialized extended intrinsic arguments" {
    const ir = [_]regvm.Inst{
        .make(.start, 0),
        .make(.mov_i64, 2 << 16),
        .make(.call_builtin_ext, (300 << 8) | 1),
        regvm.Formats.extensionWord(4),
        .make(.stop, 1 << 16),
    };
    try std.testing.expectEqual(
        @as(u32, (1 << 3) | (1 << 4) | (1 << 5)),
        try computeZeroMask(std.testing.allocator, &ir, 6, 0, 0, &.{}, &.{}, null),
    );
    const zero = [_]regvm.Inst{
        .make(.call_builtin_0, (300 << 8) | 1),
        .make(.stop, 1 << 16),
    };
    try std.testing.expectEqual(
        @as(u32, 0),
        try computeZeroMask(std.testing.allocator, &zero, 2, 0, 0, &.{}, &.{}, null),
    );
    const malformed = [_]regvm.Inst{
        .make(.call_builtin_ext, (300 << 8) | 1),
        regvm.Formats.extensionWord(0x104),
        .make(.stop, 1 << 16),
    };
    try std.testing.expectEqual(
        std.math.maxInt(u32),
        try computeZeroMask(std.testing.allocator, &malformed, 6, 0, 0, &.{}, &.{}, null),
    );
}

test "lowered primitive calls encode all arities with full-width intrinsic IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const Callbacks = struct {
        fn symbolIndex(_: *anyopaque, _: Code.Symbol) anyerror!u16 {
            return 0;
        }

        fn primitive(raw: *anyopaque, _: PrimitiveId) ?PrimitiveTarget {
            return @as(*PrimitiveTarget, @ptrCast(@alignCast(raw))).*;
        }
    };
    var target: PrimitiveTarget = .{ .index = 551, .value = .nil };
    const resolve: ResolveContext = .{
        .userdata = &target,
        .symbolIndex = Callbacks.symbolIndex,
        .primitive = Callbacks.primitive,
    };

    for (0..6) |argument_count| {
        target.index = if (argument_count == 5) std.math.maxInt(u16) else 551;
        var builder = Code.Builder.init(allocator, null);
        const function = try builder.addFunction(null, .{});
        const block = try builder.addBlock(function);
        var arguments: [5]Code.ValueId = undefined;
        for (arguments[0..argument_count], 0..) |*argument, index| {
            argument.* = try builder.addNode(
                function,
                block,
                .{ .literal = Value.i64(@intCast(index + 1)) },
                .{},
            );
        }
        const result = try builder.addNode(function, block, .{ .primitive_call = .{
            .primitive = PrimitiveId.fromIndex(0),
            .args = try builder.addOperands(arguments[0..argument_count]),
        } }, .{});
        try builder.setTerminator(block, .{
            .return_values = try builder.addOperands(&.{result}),
        });
        const code = try builder.finish(allocator);

        for ([_]bool{ false, true }) |optimize| {
            const program = try lower(allocator, allocator, code, resolve, .{
                .copy_propagation = optimize,
            });
            var calls: usize = 0;
            var pc: usize = 0;
            while (pc < program.ir.len) {
                const inst = program.ir[pc];
                switch (inst.opcode) {
                    .call_builtin_0,
                    .call_builtin_1,
                    .call_builtin_2,
                    .call_builtin_3,
                    .call_builtin_ext,
                    => {
                        const decoded = try regvm.decodeBuiltin(program.ir, pc);
                        try std.testing.expectEqual(target.index.?, decoded.index);
                        try std.testing.expectEqual(
                            @as(u8, @intCast(argument_count)),
                            decoded.argc,
                        );
                        try std.testing.expect(@as(u16, decoded.base) + 1 + decoded.argc <= program.nregs);
                        try std.testing.expectEqual(
                            if (argument_count < 4) @as(u8, 1) else @as(u8, 2),
                            decoded.size,
                        );
                        calls += 1;
                    },
                    else => {},
                }
                pc += regvm.instructionSize(inst.opcode);
            }
            try std.testing.expectEqual(@as(usize, 1), calls);
        }
    }
}

test "global reads observe run-time rebinding" {
    const Runtime = @import("Runtime.zig");
    const Reader = @import("Reader.zig");
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // Both reads through `site` must observe the latest procedure.
    // Repeated reads through `frozen` retain the same value.
    const source =
        \\(begin
        \\  (defn (site) (begin (target) (target)))
        \\  (defn (swap) (begin (set! target (fn () 99)) 0))
        \\  (defn (frozen) (+ stable stable))
        \\  (def target (fn () 1))
        \\  (def stable 5)
        \\  (let ((before (site)))
        \\    (begin
        \\      (swap)
        \\      (+ (* before 10000)
        \\         (+ (* (site) 100)
        \\            (+ (frozen) (frozen)))))))
    ;
    const forms = try Reader.readAll(rt.store, source);
    const program = try rt.compileData(rt.root_ns, forms, null);
    const Object = @TypeOf(Value.nil.obj);
    const stack = try std.testing.allocator.alloc(
        Object,
        Runtime.frame_size + @as(usize, program.nregs) * 2,
    );
    defer std.testing.allocator.free(stack);
    @memset(stack, .null);
    var fiber: Runtime.Fiber = .{
        .stack = stack,
        .sp = Runtime.frame_size + @as(usize, program.nregs) * 2,
        .ip = program.ir.ptr,
        .ir = program.ir,
        .nregs = program.nregs,
        .consts = program.constants,
        .fns = program.fns,
        .ns = rt.root_ns,
    };
    // 1 before the rebinding and 99 after it; `stable` contributes 5 + 5.
    try std.testing.expectEqual(Value.i64(10000 + 9900 + 10 + 10), try rt.runToCompletion(rt.root_ns, &fiber));
}

test "global reads in untaken branches remain unevaluated" {
    const Runtime = @import("Runtime.zig");
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try std.testing.expectEqual(Value.i64(42), try rt.evalString(
        "(begin (defn (lazy-read flag) (if flag missing-lazy-name 42)) (lazy-read #f))",
    ));
    try std.testing.expectError(error.Unbound, rt.evalString("(lazy-read #t)"));
}

test "a failed global read preserves preceding effects" {
    const Runtime = @import("Runtime.zig");
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    _ = try rt.evalString(
        "(begin (def read-effect 0) (defn (ordered-read) (begin (set! read-effect 7) missing-ordered-name)))",
    );
    try std.testing.expectError(error.Unbound, rt.evalString("(ordered-read)"));
    try std.testing.expectEqual(Value.i64(7), try rt.evalString("read-effect"));
}

test "guarded arithmetic fallback rejoins nested branches and handlers" {
    const Runtime = @import("Runtime.zig");
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    _ = try rt.evalString(
        "(defn (guarded-branches x) (if (< x 0) (* (+ x 1) 2) (* (+ (+ x 2) 3) 4)))",
    );
    try std.testing.expectEqual(Value.i64(36), try rt.evalString("(guarded-branches 4)"));
    try std.testing.expectEqual(Value.i64(-2), try rt.evalString("(guarded-branches -2)"));
    _ = try rt.evalString("(set! + (fn (a b) (- a b)))");
    try std.testing.expectEqual(Value.i64(-4), try rt.evalString("(guarded-branches 4)"));
    try std.testing.expectEqual(Value.i64(-6), try rt.evalString("(guarded-branches -2)"));
    _ = try rt.evalString("(set! + (fn (a b) (raise 91)))");
    try std.testing.expectEqual(Value.i64(91), try rt.evalString(
        "(guard (raised (#t raised)) (guarded-branches 4))",
    ));
}

test "immutable register aliases survive overlapping call windows" {
    const Runtime = @import("Runtime.zig");
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try std.testing.expectEqual(Value.i64(70), try rt.evalString(
        "(begin (defn (twice x) (+ x x)) (defn (reuse x) (+ (* x x) (+ (twice x) x))) (reuse 7))",
    ));
}
