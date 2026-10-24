const std = @import("std");
const skript = @import("root.zig");
const Runtime = skript.Runtime;

/// 32-bit fixed-width instruction: 8-bit opcode + 24-bit payload.
/// Payload interpretation depends on opcode (I/K/S/N/B/Z format families).
pub const Inst = packed struct(u32) {
    payload: u24 = 0,
    opcode: Opcode = .nop,

    pub fn make(opcode: Opcode, payload: u24) Inst {
        return .{ .opcode = opcode, .payload = payload };
    }
};

/// Opcode map — 8-bit (256 max). Organized by format family.
pub const Opcode = enum(u8) {
    // ---- Control (I-format: i24 immediate offset) ----
    nop = 0x00,
    start = 0x01,
    /// stop rd  (S-format: slot = top-level result register)
    stop = 0x02,
    /// enter nlocals:u8  (S-format: slot:u8)
    enter = 0x03,
    /// ret rd — return one value from rd.
    ret = 0x04,
    /// jmp offset:i24   (I-format)
    jmp = 0x05,
    /// br rd, off:i16  (B-format: slot + sign-extended offset; jump when getReg(rd) truthy)
    br = 0x06,
    /// brn rd, off:i16  (B-format: slot + sign-extended offset; jump when getReg(rd) falsy)
    brn = 0x07,
    /// src idx:u24 — source marker (K-format: 24-bit payload). The payload is
    /// the DFS preorder index of the next compiled expression's node within
    /// the CURRENT function's source tree (Closure.source). evalReg records
    /// it so an error attaches the failing node's index (design directive 3).
    src = 0x08,
    /// try exn_rd, off:i16 — push a catch-state frame onto the fiber's
    /// exception stack; `off` is the handler block address relative to the
    /// instruction AFTER this one (like br/brn). The handler receives the
    /// error payload in R[exn_rd]. (`.@"try"` — `try` is a Zig keyword.)
    @"try" = 0x09,
    /// end_try — pop the catch-state frame pushed by the enclosing .try
    /// (fall-through path: no error was raised inside the body).
    end_try = 0x0A,
    /// raise rd — store R[rd] as the fiber's raised payload and unwind
    /// (error.Raised). Never returns normally.
    raise = 0x0B,
    /// ret_multi rd, nresults — return consecutive values from
    /// R[rd..rd+nresults). Payload high8=rd, low8=nresults.
    ret_multi = 0x0C,

    // ---- Constants & Moves ----
    /// mov rd, slot:s24       (move register from slot)
    mov_reg = 0x10,
    /// mov rd, imm:i24        (small immediate)  (I-format)
    mov_i64 = 0x11,
    /// load rd, kidx:u16      (constant table index into fib.consts)  (N-format: rd + kidx)
    load = 0x14,
    /// make_closure rd, site:u16 — capture layout in the executing function's
    /// cold closure-site table (N-format: rd + site).
    make_closure = 0x18,
    /// ns_push rd, count:u16 — create a fresh namespace (parent = current
    /// fib.ns), save the OLD fib.ns on the fiber stack, switch fib.ns to the
    /// new one, and store the new ns Value in rd. `count` = the number of
    /// bindings the matching `.set`s will make: the handler picks a
    /// SmallNamespace (SIMD fast path) when count <= SmallNamespace.size,
    /// else a HashMapNamespace (no cap).  (N-format: rd + count)
    ns_push = 0x19,
    /// ns_pop — restore fib.ns from the Value saved by ns_push (no operands)
    ns_pop = 0x1A,

    // ---- Lookup / Set (N-format: rd:u8 + sidx:u16) ----
    /// lookup rd, sidx — resolve symbol into rd
    lookup = 0x20,
    /// set sidx, rs — store register into symbol binding
    set = 0x21,
    /// lookup_val rd, sidx — get symbol's value binding
    lookup_val = 0x22,

    /// set_existing sidx, rs — update the nearest existing namespace binding.
    set_existing = 0x23,
    // ---- Call (Z-format: rd:u8 + nargs:u8 + flags/result-count:u8) ----
    /// call rd, func_rd, arity — rd is the result and the callee register.
    call = 0x30,
    tail_call = 0x31,
    /// 0x32 was the old 8-bit-index call_builtin encoding and is invalid.
    /// self_call rd, nargs — guarded dispatch through the executing closure.
    /// R[rd] is the dead callee slot, arguments occupy R[rd+1..], and the
    /// single result overwrites rd.
    self_call = 0x33,
    tail_self_call = 0x34,
    /// get_self rd — copy the current executing closure into rd.
    get_self = 0x39,
    /// Two-word guard. Word 0 high8=callee register, low16=expected constant
    /// index. Word 1 is an unsigned forward offset from the word after the
    /// guard to the ordinary-call slow path.
    guard_callee = 0x35,
    /// Two-word guard against the current frame closure. Word 0 high8=callee
    /// register. Word 1 uses the same slow-path offset as guard_callee.
    guard_self = 0x36,
    /// Multi-result closure call. Payload high8=destination base,
    /// middle8=argument count INCLUDING callee, low8=result count.
    call_multi = 0x37,
    tail_call_multi = 0x38,

    /// Direct intrinsic: index:u16 in payload bits 23..8, base:u8 in 7..0.
    /// The fixed forms encode argc in the opcode; ext uses one raw word whose
    /// low byte is argc (at least 4) and whose upper 24 bits must be zero.
    call_builtin_0 = 0x3A,
    call_builtin_1 = 0x3B,
    call_builtin_2 = 0x3C,
    call_builtin_3 = 0x3D,
    call_builtin_ext = 0x3E,
    // ---- Generic arithmetic (quickening targets) ----
    generic_add = 0x40,
    generic_sub = 0x41,
    generic_mul = 0x42,
    generic_div = 0x43,
    generic_eq = 0x44,
    generic_lt = 0x45,
    generic_not = 0x46,
    generic_gt = 0x47,

    // ---- Specialized arithmetic (3-address: rd, rs1, rs2 each 8-bit) ----
    // Encoding: bits 23..16 = rd, 15..8 = rs1, 7..0 = rs2
    add_i8 = 0x50,
    add_i16 = 0x51,
    add_i32 = 0x52,
    add_i64 = 0x53,
    add_u8 = 0x54,
    add_u16 = 0x55,
    add_u32 = 0x56,
    add_u64 = 0x57,
    add_f16 = 0x58,
    add_f32 = 0x59,
    add_f64 = 0x5A,
    add_c64 = 0x5B,
    sub_i8 = 0x5C,
    sub_i16 = 0x5D,
    sub_i32 = 0x5E,
    sub_i64 = 0x5F,
    sub_u8 = 0x60,
    sub_u16 = 0x61,
    sub_u32 = 0x62,
    sub_u64 = 0x63,
    sub_f16 = 0x64,
    sub_f32 = 0x65,
    sub_f64 = 0x66,
    sub_c64 = 0x67,
    mul_i8 = 0x68,
    mul_i16 = 0x69,
    mul_i32 = 0x6A,
    mul_i64 = 0x6B,
    mul_u8 = 0x6C,
    mul_u16 = 0x6D,
    mul_u32 = 0x6E,
    mul_u64 = 0x6F,
    mul_f16 = 0x70,
    mul_f32 = 0x71,
    mul_f64 = 0x72,
    mul_c64 = 0x73,
    div_i8 = 0x74,
    div_i16 = 0x75,
    div_i32 = 0x76,
    div_i64 = 0x77,
    div_u8 = 0x78,
    div_u16 = 0x79,
    div_u32 = 0x7A,
    div_u64 = 0x7B,
    div_f16 = 0x7C,
    div_f32 = 0x7D,
    div_f64 = 0x7E,
    div_c64 = 0x7F,

    eq_i8 = 0x80,
    eq_i16 = 0x81,
    eq_i32 = 0x82,
    eq_i64 = 0x83,
    eq_u8 = 0x84,
    eq_u16 = 0x85,
    eq_u32 = 0x86,
    eq_u64 = 0x87,
    eq_f16 = 0x88,
    eq_f32 = 0x89,
    eq_f64 = 0x8A,
    eq_c64 = 0x8B,

    lt_i8 = 0x8C,
    lt_i16 = 0x8D,
    lt_i32 = 0x8E,
    lt_i64 = 0x8F,
    lt_u8 = 0x90,
    lt_u16 = 0x91,
    lt_u32 = 0x92,
    lt_u64 = 0x93,
    lt_f16 = 0x94,
    lt_f32 = 0x95,
    lt_f64 = 0x96,

    // Only the two arith types the binder's fast path admits (i64, f64) get
    // a specialized form; the narrower lt_* encodings above are retained for
    // decode compatibility but are never emitted.
    gt_i64 = 0x97,
    gt_f64 = 0x98,

    // ---- Reserved ranges ----
    // 0xB0-0xBF: superinstructions
    // 0xC0-0xCF: IC (inline cache) primitives
    // 0xD0-0xDF: debug
    // 0xE0-0xEF: user extension
    // 0xF0-0xFF: system
    _,
};

/// Operand format helpers — decode payload fields by opcode format family.
pub const Formats = struct {
    /// I-format: 24-bit signed immediate/offset
    pub fn imm24(payload: u24) i24 {
        return @bitCast(payload);
    }

    /// S-format: single 8-bit slot/register field in upper 8 bits
    pub fn slot(payload: u24) u8 {
        return @truncate(payload >> 16);
    }

    /// K-format: 24-bit constant table index
    pub fn constIdx(payload: u24) u24 {
        return payload;
    }

    /// N-format: rd(8) + sidx(16)
    pub fn rdAndSidx(payload: u24) struct { u8, u16 } {
        return .{ @truncate(payload >> 16), @truncate(payload) };
    }

    /// Z-format: rd(8) + nargs(8) + flags(8)
    pub fn rdNargsFlags(payload: u24) struct { u8, u8, u8 } {
        return .{
            @truncate(payload >> 16),
            @truncate(payload >> 8),
            @truncate(payload),
        };
    }

    /// Direct intrinsic payload: intrinsic table index:u16 + result base:u8.
    pub fn builtinIndexBase(payload: u24) struct { u16, u8 } {
        return .{ @truncate(payload >> 8), @truncate(payload) };
    }

    /// The raw u32 stored in a multi-word instruction's extension word.
    pub fn extension(word: Inst) u32 {
        return @bitCast(word);
    }

    /// Build a raw extension word without assigning it an opcode meaning.
    pub fn extensionWord(value: u32) Inst {
        return @bitCast(value);
    }

    /// 3-address: rd(8) + rs1(8) + rs2(8)
    pub fn rdRs1Rs2(payload: u24) struct { u8, u8, u8 } {
        return .{
            @truncate(payload >> 16),
            @truncate(payload >> 8),
            @truncate(payload),
        };
    }

    /// B-format: rd(8) + off(16, sign-extended). Used by br/brn.
    pub fn rdOffset(payload: u24) struct { u8, i16 } {
        return .{
            @truncate(payload >> 16),
            @bitCast(@as(u16, @truncate(payload))),
        };
    }
};

/// Register access metadata for one decoded instruction. Exceptional writes
/// occur only on the unwind edge and must not kill fall-through liveness.
pub const RegisterAccess = struct {
    reads: u256 = 0,
    writes: u256 = 0,
    exceptional_writes: u256 = 0,
    terminal: bool = false,
    valid: bool = true,

    fn conservative() RegisterAccess {
        return .{
            .reads = std.math.maxInt(u256),
            .writes = std.math.maxInt(u256),
            .exceptional_writes = std.math.maxInt(u256),
            .valid = false,
        };
    }
};

pub const BuiltinCall = struct {
    index: u16,
    base: u8,
    argc: u8,
    size: u8,
};

/// Decode a direct intrinsic only at an instruction boundary.
pub fn decodeBuiltin(ir: []const Inst, pc: usize) error{InvalidCode}!BuiltinCall {
    if (pc >= ir.len) return error.InvalidCode;
    const inst = ir[pc];
    const argc: u8 = switch (inst.opcode) {
        .call_builtin_0 => 0,
        .call_builtin_1 => 1,
        .call_builtin_2 => 2,
        .call_builtin_3 => 3,
        .call_builtin_ext => blk: {
            if (pc + 1 >= ir.len) return error.InvalidCode;
            const word = Formats.extension(ir[pc + 1]);
            if (word > std.math.maxInt(u8)) return error.InvalidCode;
            const count: u8 = @intCast(word);
            if (count < 4) return error.InvalidCode;
            break :blk count;
        },
        else => return error.InvalidCode,
    };
    const intrinsic_index, const base = Formats.builtinIndexBase(inst.payload);
    return .{
        .index = intrinsic_index,
        .base = base,
        .argc = argc,
        .size = instructionSize(inst.opcode),
    };
}

/// Encoded size in Inst words. Guards and extended calls own a raw second word.
pub fn instructionSize(opcode: Opcode) u8 {
    return switch (opcode) {
        .guard_callee, .guard_self, .call_builtin_ext => 2,
        else => 1,
    };
}

/// Bit mask for a bounded consecutive register range.
pub fn registerRangeMask(base: u8, count: u8) ?u256 {
    if (count == 0) return 0;
    const end = @as(u16, base) + @as(u16, count);
    if (end > 256) return null;
    const right: u8 = @intCast(256 - @as(u16, count));
    const low = @as(u256, std.math.maxInt(u256)) >> right;
    return low << @intCast(base);
}

fn registerBit(register: u8) u256 {
    return @as(u256, 1) << @intCast(register);
}

fn callAccess(base: u8, argument_count: u8, result_count: u8, reads_callee: bool) RegisterAccess {
    const arguments = registerRangeMask(base, argument_count) orelse
        return .conservative();
    const results = registerRangeMask(base, result_count) orelse
        return .conservative();
    return .{
        .reads = if (reads_callee) arguments else arguments & ~registerBit(base),
        .writes = results,
    };
}

fn builtinAccess(call: BuiltinCall) RegisterAccess {
    const reads: u256 = if (call.argc == 0)
        0
    else blk: {
        const first = @as(u16, call.base) + 1;
        if (first > std.math.maxInt(u8)) return .conservative();
        break :blk registerRangeMask(@intCast(first), call.argc) orelse return .conservative();
    };
    return .{ .reads = reads, .writes = registerBit(call.base) };
}

/// Decode multiword register windows without interpreting extension words as opcodes.
pub fn registerAccessAt(ir: []const Inst, index: usize) RegisterAccess {
    if (index >= ir.len) return .conservative();
    return switch (ir[index].opcode) {
        .call_builtin_0,
        .call_builtin_1,
        .call_builtin_2,
        .call_builtin_3,
        .call_builtin_ext,
        => builtinAccess(decodeBuiltin(ir, index) catch return .conservative()),
        else => registerAccess(ir[index]),
    };
}

/// Exact register reads and writes for one instruction. Unknown opcodes and
/// malformed register windows are conservative barriers.
pub fn registerAccess(inst: Inst) RegisterAccess {
    if (isArithmetic(inst.opcode)) {
        const rd, const left, const right = Formats.rdRs1Rs2(inst.payload);
        return .{
            .reads = registerBit(left) | registerBit(right),
            .writes = registerBit(rd),
        };
    }
    return switch (inst.opcode) {
        .nop, .start, .enter, .jmp, .src, .end_try, .ns_pop => .{},
        .stop, .ret, .raise, .br, .brn => .{
            .reads = registerBit(Formats.slot(inst.payload)),
            .terminal = inst.opcode == .stop or inst.opcode == .ret or
                inst.opcode == .raise,
        },
        .ret_multi => blk: {
            const source = Formats.slot(inst.payload);
            const count: u8 = @truncate(inst.payload);
            const reads = registerRangeMask(source, count) orelse return RegisterAccess.conservative();
            break :blk .{
                .reads = reads,
                .terminal = true,
            };
        },
        .mov_reg => blk: {
            const rd, const source = Formats.rdAndSidx(inst.payload);
            break :blk .{
                .reads = registerBit(@truncate(source)),
                .writes = registerBit(rd),
            };
        },
        .mov_i64, .load, .make_closure, .ns_push, .lookup, .lookup_val, .get_self => .{
            .writes = registerBit(Formats.slot(inst.payload)),
        },
        .set, .set_existing => .{ .reads = registerBit(Formats.slot(inst.payload)) },
        .@"try" => .{
            .exceptional_writes = registerBit(Formats.slot(inst.payload)),
        },
        .call, .tail_call => blk: {
            const base, const argument_count, const flags = Formats.rdNargsFlags(inst.payload);
            _ = flags;
            var access = callAccess(base, argument_count, 1, true);
            access.terminal = inst.opcode == .tail_call;
            break :blk access;
        },
        .self_call, .tail_self_call => blk: {
            const base, const argument_count, const flags = Formats.rdNargsFlags(inst.payload);
            _ = flags;
            var access = callAccess(base, argument_count, 1, false);
            access.terminal = inst.opcode == .tail_self_call;
            break :blk access;
        },
        .call_builtin_0, .call_builtin_1, .call_builtin_2, .call_builtin_3 => |opcode| blk: {
            const intrinsic_index, const base = Formats.builtinIndexBase(inst.payload);
            break :blk builtinAccess(.{
                .index = intrinsic_index,
                .base = base,
                .argc = @backingInt(opcode) - @backingInt(Opcode.call_builtin_0),
                .size = 1,
            });
        },
        .call_builtin_ext => .conservative(),
        .call_multi, .tail_call_multi => blk: {
            const base, const argument_count, const result_count =
                Formats.rdNargsFlags(inst.payload);
            const tail = inst.opcode == .tail_call_multi;
            var access = callAccess(base, argument_count, if (tail) 0 else result_count, true);
            access.terminal = tail;
            break :blk access;
        },
        .guard_callee, .guard_self => .{
            .reads = registerBit(Formats.slot(inst.payload)),
        },
        else => .conservative(),
    };
}

/// True for every generic or specialized three-register arithmetic opcode.
/// The bounds track the generic block (0x40-0x47) and the specialized block
/// (0x50-0x98); a new opcode outside them silently degrades
/// `registerAccess` to `conservative` and the VM rejects the instruction.
pub fn isArithmetic(opcode: Opcode) bool {
    const raw = @backingInt(opcode);
    return (raw >= 0x40 and raw <= 0x47) or (raw >= 0x50 and raw <= 0x98);
}

/// Format one register VM instruction for debugging.
pub fn formatRegInst(w: *std.Io.Writer, ip: [*]const Inst, rt: *Runtime) std.Io.Writer.Error!?usize {
    const inst = ip[0];
    _ = rt;
    try w.print("{s} ", .{@tagName(inst.opcode)});
    switch (inst.opcode) {
        .nop, .start => {},
        .stop => try w.print("r{}", .{Formats.slot(inst.payload)}),
        .enter => try w.print("{}", .{Formats.slot(inst.payload)}),
        .ret => try w.print("r{}", .{Formats.slot(inst.payload)}),
        .ret_multi => try w.print("r{}, nresults={}", .{
            Formats.slot(inst.payload),
            @as(u8, @truncate(inst.payload)),
        }),
        .jmp => try w.print("{}", .{Formats.imm24(inst.payload)}),
        .src => try w.print("{}", .{inst.payload}),
        .@"try" => {
            const rd, const off_u = Formats.rdAndSidx(inst.payload);
            try w.print("r{}, {}", .{ rd, @as(i16, @bitCast(off_u)) });
        },
        .end_try => try w.print("-", .{}),
        .raise => try w.print("r{}", .{Formats.slot(inst.payload)}),
        .br, .brn => {
            const rd, const off = Formats.rdOffset(inst.payload);
            try w.print("r{}, {}", .{ rd, off });
        },
        .mov_i64 => {
            const rd, const immediate = Formats.rdOffset(inst.payload);
            try w.print("r{}, {}", .{ rd, immediate });
        },
        .mov_reg => {
            const rd, const rs = Formats.rdAndSidx(inst.payload);
            try w.print("r{}, r{}", .{ rd, rs });
        },
        .load => {
            const rd, const kidx = Formats.rdAndSidx(inst.payload);
            try w.print("r{}, #{}", .{ rd, kidx });
        },
        .make_closure => {
            const rd, const site = Formats.rdAndSidx(inst.payload);
            try w.print("r{}, site#{}", .{ rd, site });
        },
        .ns_push => try w.print("r{}", .{Formats.slot(inst.payload)}),
        .ns_pop => try w.print("-", .{}),
        .lookup, .lookup_val => {
            const rd, const sidx = Formats.rdAndSidx(inst.payload);
            try w.print("r{}, {}", .{ rd, sidx });
        },
        .set, .set_existing => {
            const rs, const sidx = Formats.rdAndSidx(inst.payload);
            try w.print("r{}, sym#{}", .{ rs, sidx });
        },
        .call, .tail_call, .self_call, .tail_self_call => {
            const rd, const nargs, const flags = Formats.rdNargsFlags(inst.payload);
            try w.print("r{}, nargs={}, flags={}", .{ rd, nargs, flags });
        },
        .get_self => try w.print("r{}", .{Formats.slot(inst.payload)}),
        .call_multi, .tail_call_multi => {
            const rd, const nargs, const result_count =
                Formats.rdNargsFlags(inst.payload);
            try w.print(
                "r{}, nargs={}, nresults={}",
                .{ rd, nargs, result_count },
            );
        },
        .guard_callee => {
            const callee, const expected = Formats.rdAndSidx(inst.payload);
            try w.print(
                "r{}, expected=#{}, slow=+{}",
                .{ callee, expected, Formats.extension(ip[1]) },
            );
        },
        .guard_self => try w.print(
            "r{}, slow=+{}",
            .{ Formats.slot(inst.payload), Formats.extension(ip[1]) },
        ),
        .call_builtin_0,
        .call_builtin_1,
        .call_builtin_2,
        .call_builtin_3,
        .call_builtin_ext,
        => {
            const intrinsic_index, const base = Formats.builtinIndexBase(inst.payload);
            const argc: u8 = switch (inst.opcode) {
                .call_builtin_0 => 0,
                .call_builtin_1 => 1,
                .call_builtin_2 => 2,
                .call_builtin_3 => 3,
                .call_builtin_ext => @truncate(Formats.extension(ip[1])),
                else => unreachable,
            };
            try w.print("r{}, nargs={}, intrinsic={}", .{ base, argc, intrinsic_index });
        },
        else => if (isArithmetic(inst.opcode))
            try printArith(w, inst)
        else
            try w.print("<unknown opcode {x}>", .{@backingInt(inst.opcode)}),
    }
    return instructionSize(inst.opcode);
}

/// Print the shared 3-address operand decode (rd, rs1, rs2) used by the
/// generic and specialized arithmetic opcodes.
fn printArith(w: *std.Io.Writer, inst: Inst) std.Io.Writer.Error!void {
    const rd, const rs1, const rs2 = Formats.rdRs1Rs2(inst.payload);
    try w.print("r{}, r{}, r{}", .{ rd, rs1, rs2 });
}

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(Inst);
        std.testing.refAllDecls(Opcode);
        std.testing.refAllDecls(Formats);
        std.testing.refAllDecls(RegisterAccess);
    }
}

test "disassembly decodes signed immediates and specialized arithmetic operands" {
    const cases = [_]struct { instruction: Inst, text: []const u8 }{
        .{ .instruction = Inst.make(.mov_i64, (255 << 16) | 0x8000), .text = "mov_i64 r255, -32768" },
        .{ .instruction = Inst.make(.mov_i64, (7 << 16) | 0x7fff), .text = "mov_i64 r7, 32767" },
        .{ .instruction = Inst.make(.sub_f64, (9 << 16) | (4 << 8) | 2), .text = "sub_f64 r9, r4, r2" },
        .{ .instruction = Inst.make(.mul_i64, (9 << 16) | (4 << 8) | 2), .text = "mul_i64 r9, r4, r2" },
    };
    for (cases) |case| {
        var buffer: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        const ir = [_]Inst{case.instruction};
        try std.testing.expectEqual(@as(?usize, 1), try formatRegInst(&writer, &ir, undefined));
        try std.testing.expectEqualStrings(case.text, writer.buffered());
    }
}

test "direct intrinsic words decode every arity and full table indices" {
    const cases = [_]struct { opcode: Opcode, argc: u8, size: u8 }{
        .{ .opcode = .call_builtin_0, .argc = 0, .size = 1 },
        .{ .opcode = .call_builtin_1, .argc = 1, .size = 1 },
        .{ .opcode = .call_builtin_2, .argc = 2, .size = 1 },
        .{ .opcode = .call_builtin_3, .argc = 3, .size = 1 },
        .{ .opcode = .call_builtin_ext, .argc = 4, .size = 2 },
    };
    for (cases) |case| {
        const first = Inst.make(case.opcode, (300 << 8) | 7);
        const ir = [_]Inst{ first, Formats.extensionWord(case.argc) };
        try std.testing.expectEqual(
            (@as(u32, @backingInt(case.opcode)) << 24) | (300 << 8) | 7,
            @as(u32, @bitCast(first)),
        );
        const call = try decodeBuiltin(&ir, 0);
        try std.testing.expectEqual(@as(u16, 300), call.index);
        try std.testing.expectEqual(@as(u8, 7), call.base);
        try std.testing.expectEqual(case.argc, call.argc);
        try std.testing.expectEqual(case.size, call.size);
        try std.testing.expectEqual(case.size, instructionSize(case.opcode));
    }
    try std.testing.expectError(error.InvalidCode, decodeBuiltin(
        &.{Inst.make(@fromBackingInt(@intCast(0x32)), 0)},
        0,
    ));
}

test "direct intrinsic extension rejects truncation and noncanonical counts" {
    const first = Inst.make(.call_builtin_ext, (65535 << 8) | 1);
    try std.testing.expectError(error.InvalidCode, decodeBuiltin(&.{first}, 0));
    for ([_]u32{ 0, 1, 2, 3, 0x10004, 0xFF000004 }) |word| {
        const ir = [_]Inst{ first, Formats.extensionWord(word) };
        try std.testing.expectError(error.InvalidCode, decodeBuiltin(&ir, 0));
        try std.testing.expect(!registerAccessAt(&ir, 0).valid);
    }
    try std.testing.expectError(error.InvalidCode, decodeBuiltin(&.{}, 0));
}

test "direct intrinsic register access reads only arguments and writes the result" {
    const one = [_]Inst{Inst.make(.call_builtin_0, (512 << 8) | 7)};
    const zero_access = registerAccessAt(&one, 0);
    try std.testing.expect(zero_access.valid);
    try std.testing.expectEqual(@as(u256, 0), zero_access.reads);
    try std.testing.expectEqual(@as(u256, 1) << 7, zero_access.writes);

    const five = [_]Inst{
        Inst.make(.call_builtin_ext, (65535 << 8) | 249),
        Formats.extensionWord(5),
    };
    const access = registerAccessAt(&five, 0);
    try std.testing.expect(access.valid);
    try std.testing.expectEqual(@as(u256, 0x1F) << 250, access.reads);
    try std.testing.expectEqual(@as(u256, 1) << 249, access.writes);
    try std.testing.expect(!registerAccess(five[0]).valid);
    try std.testing.expect(!registerAccessAt(
        &.{ Inst.make(.call_builtin_ext, 254), Formats.extensionWord(4) },
        0,
    ).valid);
}

test "direct intrinsic disassembly consumes the extension as one instruction" {
    const ir = [_]Inst{
        Inst.make(.call_builtin_ext, (551 << 8) | 9),
        Formats.extensionWord(4),
    };
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try std.testing.expectEqual(@as(?usize, 2), try formatRegInst(
        &writer,
        ir[0..].ptr,
        undefined,
    ));
    try std.testing.expectEqualStrings(
        "call_builtin_ext r9, nargs=4, intrinsic=551",
        writer.buffered(),
    );
}
