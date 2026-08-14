const std = @import("std");

const skript = @import("../root.zig");
const Value = skript.Value;
const Error = skript.Error;
const EvalContext = skript.EvalContext;

const intrin = @import("root.zig");

// Read the complete NUL-terminated bytes of a string Value.
fn valueStringBytes(ctx: *const EvalContext, value: Value) Error![:0]const u8 {
    return ctx.stringBytes(
        value.obj.toPtr([*:0]const u8),
        std.math.maxInt(usize),
        .native,
    );
}

// At most 10,000 structural pairs or map entries are compared per call.
const deep_equal_walk_cap: usize = 10_000;
// A separate step cap includes graph work and pair-table probes.
const deep_equal_work_cap: usize = 100_000;
// Fixed pending storage bounds nested car/map comparisons without recursion.
const deep_equal_pending_cap: usize = 256;
// Bytevector content checks are capped per call and separately metered.
const deep_equal_byte_cap: usize = 1_048_576;
const deep_equal_seen_cap: usize = 10_000;
// Stop pathological hash clusters instead of scanning an unbounded table.
const deep_equal_seen_probe_cap: usize = 64;
const deep_equal_seen_initial_capacity: usize = 32;
const deep_equal_seen_max_capacity: usize = 32_768;

const EqualityBudget = struct {
    work_left: usize = deep_equal_work_cap,
    map_entries_left: usize = deep_equal_walk_cap,
    byte_work_left: usize = deep_equal_byte_cap,
};

const GraphPair = struct {
    a_type: u64,
    b_type: u64,
    a: u64,
    b: u64,
};

const GraphPairSlot = struct {
    pair: GraphPair = .{ .a_type = 0, .b_type = 0, .a = 0, .b = 0 },
    occupied: bool = false,
};

// Seen directed value pairs provide a coinductive rule for cyclic graphs.
const ComparedPairs = struct {
    slots: []GraphPairSlot = &.{},
    len: usize = 0,

    fn deinit(self: *ComparedPairs, allocator: std.mem.Allocator) void {
        if (self.slots.len != 0) allocator.free(self.slots);
        self.* = undefined;
    }

    fn grow(self: *ComparedPairs, rt: *EvalContext, budget: *EqualityBudget) Error!void {
        const capacity = if (self.slots.len == 0)
            deep_equal_seen_initial_capacity
        else
            self.slots.len * 2;
        if (capacity > deep_equal_seen_max_capacity) return error.Unsupported;

        const slots = try rt.scratch.alloc(GraphPairSlot, capacity);
        errdefer rt.scratch.free(slots);
        @memset(slots, .{});

        for (self.slots) |slot| {
            if (!slot.occupied) continue;
            var index = graphPairHash(slot.pair) & (capacity - 1);
            var probes: usize = 0;
            while (slots[index].occupied) {
                if (probes == deep_equal_seen_probe_cap) return error.Unsupported;
                try chargeWalk(rt, budget);
                probes += 1;
                index = (index + 1) & (capacity - 1);
            }
            try chargeWalk(rt, budget);
            slots[index] = slot;
        }

        if (self.slots.len != 0) rt.scratch.free(self.slots);
        self.slots = slots;
    }

    fn containsOrInsert(
        self: *ComparedPairs,
        rt: *EvalContext,
        budget: *EqualityBudget,
        a: Value,
        b: Value,
    ) Error!bool {
        if (self.slots.len == 0 or
            (self.len * 2 >= self.slots.len and self.len < deep_equal_seen_cap))
        {
            try self.grow(rt, budget);
        }

        const pair: GraphPair = .{
            .a_type = @intFromEnum(a.typ),
            .b_type = @intFromEnum(b.typ),
            .a = @intFromEnum(a.obj),
            .b = @intFromEnum(b.obj),
        };
        var index = graphPairHash(pair) & (self.slots.len - 1);
        var probes: usize = 0;
        while (true) {
            if (probes == deep_equal_seen_probe_cap) return error.Unsupported;
            try chargeWalk(rt, budget);
            probes += 1;

            const slot = &self.slots[index];
            if (!slot.occupied) {
                if (self.len == deep_equal_seen_cap) return error.Unsupported;
                slot.* = .{ .pair = pair, .occupied = true };
                self.len += 1;
                return false;
            }
            if (slot.pair.a_type == pair.a_type and
                slot.pair.b_type == pair.b_type and
                slot.pair.a == pair.a and
                slot.pair.b == pair.b) return true;
            index = (index + 1) & (self.slots.len - 1);
        }
    }
};

fn graphPairHash(pair: GraphPair) usize {
    return @truncate(std.hash.Wyhash.hash(0, std.mem.asBytes(&pair)));
}

fn chargeWalk(rt: *EvalContext, budget: *EqualityBudget) Error!void {
    if (budget.work_left == 0) return error.Unsupported;
    budget.work_left -= 1;
    try rt.chargeWork(1, 1, .native);
}

// Numeric equality uses the type's native equality without cross-type coercion.
fn numericEq(a: Value, b: Value) bool {
    return switch (a.typ) {
        skript.builtins.type_i64 => a.obj.toInt(i64) == b.obj.toInt(i64),
        skript.builtins.type_i32 => a.obj.toInt(i32) == b.obj.toInt(i32),
        skript.builtins.type_i16 => a.obj.toInt(i16) == b.obj.toInt(i16),
        skript.builtins.type_i8 => a.obj.toInt(i8) == b.obj.toInt(i8),
        skript.builtins.type_u64 => a.obj.toInt(u64) == b.obj.toInt(u64),
        skript.builtins.type_u32 => a.obj.toInt(u32) == b.obj.toInt(u32),
        skript.builtins.type_u16 => a.obj.toInt(u16) == b.obj.toInt(u16),
        skript.builtins.type_u8 => a.obj.toInt(u8) == b.obj.toInt(u8),
        skript.builtins.type_f64 => a.obj.tof64() == b.obj.tof64(),
        skript.builtins.type_f32 => a.obj.tof32() == b.obj.tof32(),
        skript.builtins.type_f16 => a.obj.tof16() == b.obj.tof16(),
        else => false,
    };
}

/// `(equal? A B)` — deep same-type structural equality.
/// Cross-type operands are always `#f`. Numbers use IEEE equality (+0.0 =
/// -0.0; NaN ≠ NaN). Cons and map comparisons are iterative, cycle-aware, and
/// bounded. Maps compare exact key sets and deeply compare values. Strings and
/// bytevectors compare by content; bytevector scans are capped at 1 MiB per
/// call. Symbols and keywords compare by interning identity; tensors delegate
/// to `@tensor.eq`. Other values compare by object identity.
pub fn equal(rt: *EvalContext, _: Value, _: Value, args: []const Value) Error!Value {
    try intrin.arityAssert(args, 2);
    var budget: EqualityBudget = .{};
    return .bool(try deepEqual(rt, args[0], args[1], &budget));
}

fn deepEqual(rt: *EvalContext, a: Value, b: Value, budget: *EqualityBudget) Error!bool {
    const PendingPair = struct {
        a: Value,
        b: Value,
        car_depth: u16,
        check_depth: bool,
    };
    const MapValues = struct {
        right: intrin.map.EqualityView,
        iterator: intrin.map.EqualityView.Iterator,
        car_depth: u16,
    };
    const WorkItem = union(enum) {
        compare: PendingPair,
        map_values: MapValues,
    };

    var pending: [deep_equal_pending_cap]WorkItem = undefined;
    var pending_len: usize = 1;
    pending[0] = .{ .compare = .{
        .a = a,
        .b = b,
        .car_depth = 0,
        .check_depth = false,
    } };
    var compared: ComparedPairs = .{};
    defer compared.deinit(rt.scratch);
    const base_depth: u64 = @as(u64, rt.depth) +
        (if (rt.vm_depth) |vm_depth| @as(u64, vm_depth.*) else 0);

    while (pending_len > 0) {
        pending_len -= 1;
        switch (pending[pending_len]) {
            .map_values => |continuation| {
                var iterator = continuation.iterator;
                const entry = iterator.next() orelse continue;
                if (budget.map_entries_left == 0) return error.Unsupported;
                budget.map_entries_left -= 1;
                try chargeWalk(rt, budget);
                const value = (try continuation.right.get(rt, entry.key)) orelse return false;
                const child_depth = std.math.add(u16, continuation.car_depth, 1) catch
                    return error.Unsupported;

                if (pending_len > deep_equal_pending_cap - 2) return error.Unsupported;
                pending[pending_len] = .{ .map_values = .{
                    .right = continuation.right,
                    .iterator = iterator,
                    .car_depth = continuation.car_depth,
                } };
                pending[pending_len + 1] = .{ .compare = .{
                    .a = entry.value,
                    .b = value,
                    .car_depth = child_depth,
                    .check_depth = true,
                } };
                pending_len += 2;
            },
            .compare => |pair| {
                if (pair.check_depth) {
                    const depth = base_depth + @as(u64, pair.car_depth);
                    if (depth > std.math.maxInt(u32)) {
                        if (rt.budget()) |ledger| return ledger.overflow(.depth, .native);
                        return error.Unsupported;
                    }
                    if (rt.budget()) |ledger| try ledger.checkDepth(@intCast(depth), .native);
                }
                try chargeWalk(rt, budget);
                if (pair.a.typ != pair.b.typ) return false;

                switch (pair.a.typ) {
                    skript.builtins.type_nil => {},
                    skript.builtins.type_bool => {
                        if (pair.a.obj.toBool() != pair.b.obj.toBool()) return false;
                    },
                    skript.builtins.type_i8,
                    skript.builtins.type_i16,
                    skript.builtins.type_i32,
                    skript.builtins.type_i64,
                    skript.builtins.type_u8,
                    skript.builtins.type_u16,
                    skript.builtins.type_u32,
                    skript.builtins.type_u64,
                    skript.builtins.type_f16,
                    skript.builtins.type_f32,
                    skript.builtins.type_f64,
                    => {
                        if (!numericEq(pair.a, pair.b)) return false;
                    },
                    // f8 is a dead tag (no value can be constructed); payload compare.
                    skript.builtins.type_f8 => {
                        if (pair.a.obj != pair.b.obj) return false;
                    },
                    // Complex equality delegates to its component-wise eq intrinsic.
                    skript.builtins.type_c16 => {
                        const result = try intrin.complex.c16_eq(
                            rt,
                            .nil,
                            .nil,
                            &.{ pair.a, pair.b },
                        );
                        if (!result.obj.toBool()) return false;
                    },
                    skript.builtins.type_c32 => {
                        const result = try intrin.complex.c32_eq(
                            rt,
                            .nil,
                            .nil,
                            &.{ pair.a, pair.b },
                        );
                        if (!result.obj.toBool()) return false;
                    },
                    skript.builtins.type_c64 => {
                        const result = try intrin.complex.c64_eq(
                            rt,
                            .nil,
                            .nil,
                            &.{ pair.a, pair.b },
                        );
                        if (!result.obj.toBool()) return false;
                    },
                    skript.builtins.type_string => {
                        const a_bytes = try valueStringBytes(rt, pair.a);
                        const b_bytes = try valueStringBytes(rt, pair.b);
                        try rt.chargeWork(@intCast(@max(a_bytes.len, b_bytes.len)), 1, .native);
                        if (!std.mem.eql(u8, a_bytes, b_bytes)) return false;
                    },
                    skript.builtins.type_bytevector => {
                        const a_bytes = try pair.a.byteVectorBytes();
                        const b_bytes = try pair.b.byteVectorBytes();
                        if (a_bytes.len != b_bytes.len) return false;
                        if (a_bytes.len > deep_equal_byte_cap or
                            a_bytes.len > budget.byte_work_left)
                        {
                            return error.Unsupported;
                        }
                        budget.byte_work_left -= a_bytes.len;
                        try rt.chargeWork(@intCast(a_bytes.len), 1, .native);
                        if (!std.mem.eql(u8, a_bytes, b_bytes)) return false;
                    },
                    skript.builtins.type_cons => {
                        if (try compared.containsOrInsert(rt, budget, pair.a, pair.b)) continue;
                        try chargeWalk(rt, budget);
                        const a_pair = pair.a.obj.toRef().deref([2]Value).*;
                        const b_pair = pair.b.obj.toRef().deref([2]Value).*;
                        const car_depth = std.math.add(u16, pair.car_depth, 1) catch
                            return error.Unsupported;

                        if (pending_len > deep_equal_pending_cap - 2) return error.Unsupported;
                        pending[pending_len] = .{ .compare = .{
                            .a = a_pair[1],
                            .b = b_pair[1],
                            .car_depth = pair.car_depth,
                            .check_depth = false,
                        } };
                        pending[pending_len + 1] = .{ .compare = .{
                            .a = a_pair[0],
                            .b = b_pair[0],
                            .car_depth = car_depth,
                            .check_depth = true,
                        } };
                        pending_len += 2;
                    },
                    skript.builtins.type_pid => {
                        if (pair.a.obj != pair.b.obj) return false;
                    },
                    skript.builtins.type_tensor => {
                        const result = try intrin.tensor.tensorEq(
                            rt,
                            .nil,
                            .nil,
                            &.{ pair.a, pair.b },
                        );
                        if (!result.obj.toBool()) return false;
                    },
                    skript.builtins.type_map => {
                        if (try compared.containsOrInsert(rt, budget, pair.a, pair.b)) continue;
                        const left = intrin.map.equalityView(pair.a);
                        const right = intrin.map.equalityView(pair.b);
                        if (left.count() != right.count()) return false;
                        if (pending_len >= deep_equal_pending_cap) return error.Unsupported;
                        pending[pending_len] = .{ .map_values = .{
                            .right = right,
                            .iterator = left.iterator(),
                            .car_depth = pair.car_depth,
                        } };
                        pending_len += 1;
                    },
                    // Stored and callable values compare by object identity.
                    else => {
                        if (pair.a.obj != pair.b.obj) return false;
                    },
                }
            },
        }
    }
    return true;
}

test "equal? deep structural equality" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    const io = threaded.io();
    var rt = try skript.Runtime.init(std.testing.allocator, io);
    defer rt.deinit();

    try std.testing.expectEqual(Value.true, try rt.evalString("(equal? \"a\" \"a\")"));
    try std.testing.expectEqual(Value.false, try rt.evalString("(equal? \"a\" \"b\")"));
    try std.testing.expectEqual(Value.true, try rt.evalString("(equal? (list 1 2 3) (list 1 2 3))"));
    try std.testing.expectEqual(Value.true, try rt.evalString("(equal? (list 1 (list 2 3)) (list 1 (list 2 3)))"));
    try std.testing.expectEqual(Value.false, try rt.evalString("(equal? (list 1 2) (list 1 3))"));
    try std.testing.expectEqual(Value.true, try rt.evalString("(equal? nil nil)"));
    try std.testing.expectEqual(Value.false, try rt.evalString("(equal? 0 0.0)"));
    try std.testing.expectEqual(Value.true, try rt.evalString("(equal? 1 1)"));
    try std.testing.expectEqual(Value.false, try rt.evalString("(equal? \"a\" 'a)"));
    try std.testing.expectEqual(Value.false, try rt.evalString("(equal? (fn (x) x) (fn (x) x))"));
    try std.testing.expectEqual(Value.true, try rt.evalString("(equal? 'a 'a)"));
    try std.testing.expectEqual(Value.false, try rt.evalString("(equal? 3+4i 3+5i)"));
    try std.testing.expectEqual(Value.true, try rt.evalString("(equal? (cons 1 2) (cons 1 2))"));
    try std.testing.expectEqual(Value.true, try rt.evalString("(equal? +0.0 -0.0)"));
}

test "equal? matches map key sets independent of insertion order" {
    const rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try std.testing.expectEqual(Value.true, try rt.evalString(
        "(equal? (hash-map 'a 1 :b nil :a 2) (hash-map :a 2 :b nil 'a 1))",
    ));
    try std.testing.expectEqual(Value.true, try rt.evalString(
        "(equal? (hash-map) (hash-map))",
    ));
    try std.testing.expectEqual(Value.true, try rt.evalString(
        "(equal? (hash-map 'a 1 :a 2) (hash-map :a 2 'a 1))",
    ));
    try std.testing.expectEqual(Value.false, try rt.evalString(
        "(equal? (hash-map 'a nil) (hash-map 'b nil))",
    ));
    try std.testing.expectEqual(Value.false, try rt.evalString(
        "(equal? (hash-map 'a nil) (hash-map))",
    ));
    try std.testing.expectEqual(Value.false, try rt.evalString(
        "(equal? (hash-map 'a 1) (hash-map :a 1))",
    ));
}

test "equal? walks nested maps lists and tensors" {
    const rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try std.testing.expectEqual(Value.true, try rt.evalString(
        "(equal? (hash-map :items (list (hash-map 'x (stack 2 3)) 4) :ok #t) " ++
            "(hash-map :ok #t :items (list (hash-map 'x (stack 2 3)) 4)))",
    ));
    try std.testing.expectEqual(Value.false, try rt.evalString(
        "(equal? (hash-map :items (list (stack 2 3))) " ++
            "(hash-map :items (list (stack 2 4))))",
    ));
    try std.testing.expectEqual(Value.true, try rt.evalString(
        "(def equal_shared_list (list 2)) " ++
            "(equal? (list equal_shared_list equal_shared_list) (list (list 2) (list 2)))",
    ));
}

test "equal? preserves numeric equality inside maps" {
    const rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try std.testing.expectEqual(Value.true, try rt.evalString(
        "(= (i32 1) (i64 1))",
    ));
    try std.testing.expectEqual(Value.false, try rt.evalString(
        "(equal? (hash-map :x (i32 1)) (hash-map :x (i64 1)))",
    ));
    try std.testing.expectEqual(Value.true, try rt.evalString(
        "(equal? (hash-map :x +0.0) (hash-map :x -0.0))",
    ));

    const key = Value.keyword(try rt.store.getsym("not-a-number"));
    const nan = Value.f64(std.math.nan(f64));
    const map_value = try intrin.map.create(rt.context(), .nil, .nil, &.{ key, nan });
    try std.testing.expectEqual(
        Value.false,
        try equal(rt.context(), .nil, .nil, &.{ map_value, map_value }),
    );
}

test "equal? compares mutable map cycles and shared aliases" {
    const rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    _ = try rt.evalString("(def equal_cycle_left (hash-map :v (list 1 2)))");
    _ = try rt.evalString("(def equal_cycle_right (hash-map :v (list 1 2)))");
    _ = try rt.evalString("(map-set! equal_cycle_left :self equal_cycle_left)");
    _ = try rt.evalString("(map-set! equal_cycle_right :self equal_cycle_right)");
    try std.testing.expectEqual(Value.true, try rt.evalString(
        "(equal? equal_cycle_left equal_cycle_left)",
    ));
    try std.testing.expectEqual(Value.true, try rt.evalString(
        "(equal? equal_cycle_left equal_cycle_right)",
    ));
    try std.testing.expectEqual(Value.true, try rt.evalString(
        "(equal? (list equal_cycle_left equal_cycle_left) " ++
            "(list equal_cycle_right equal_cycle_right))",
    ));
    _ = try rt.evalString("(map-set! equal_cycle_right :v (list 1 3))");
    try std.testing.expectEqual(Value.false, try rt.evalString(
        "(equal? equal_cycle_left equal_cycle_right)",
    ));
}

test "equal? iterates maps wider than the pending stack" {
    const rt = try skript.Runtime.initWithConfig(
        std.testing.allocator,
        std.testing.io,
        .{ .max_heap_size = 8 * 1024 * 1024 },
    );
    defer rt.deinit();

    const entry_count = deep_equal_pending_cap + 1;
    var left_args: [entry_count * 2]Value = undefined;
    var right_args: [entry_count * 2]Value = undefined;
    var name_buffer: [32]u8 = undefined;
    for (0..entry_count) |index| {
        const name = try std.fmt.bufPrint(&name_buffer, "equal-wide-{d}", .{index});
        const symbol = try rt.store.getsym(name);
        left_args[index * 2] = .symbol(symbol);
        left_args[index * 2 + 1] = .i64(@intCast(index));
        const reversed = entry_count - index - 1;
        right_args[reversed * 2] = .symbol(symbol);
        right_args[reversed * 2 + 1] = .i64(@intCast(index));
    }

    const left = try intrin.map.create(rt.context(), .nil, .nil, &left_args);
    const right = try intrin.map.create(rt.context(), .nil, .nil, &right_args);
    try std.testing.expectEqual(Value.true, try equal(
        rt.context(),
        .nil,
        .nil,
        &.{ left, right },
    ));
}

test "equal? meters map entry comparisons" {
    const rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const a = try rt.store.getsym("equal-meter-a");
    const b = try rt.store.getsym("equal-meter-b");
    const map_value = try intrin.map.create(
        rt.context(),
        .nil,
        .nil,
        &.{ .symbol(a), .i64(1), .symbol(b), .i64(2) },
    );
    var budget = EvalContext.Budget.init(std.testing.io, 1, .{ .work = 4 });
    var lease = try EvalContext.Budget.Lease.root(&budget, 4);
    var context = rt.context().*;
    context.lease = &lease;

    try std.testing.expectError(
        error.Exhausted,
        equal(&context, .nil, .nil, &.{ map_value, map_value }),
    );
    const report = budget.report() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(EvalContext.Budget.Resource.work, report.resource);
}

test "equal? enforces native depth through nested maps" {
    const rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const key = Value.keyword(try rt.store.getsym("equal-depth"));
    var nested: Value = .i64(1);
    for (0..5) |_| {
        nested = try intrin.map.create(
            rt.context(),
            .nil,
            .nil,
            &.{ key, nested },
        );
    }

    var budget = EvalContext.Budget.init(std.testing.io, 1, .{ .work = 10_000, .depth = 2 });
    var lease = try EvalContext.Budget.Lease.root(&budget, 10_000);
    var context = rt.context().*;
    context.lease = &lease;
    try std.testing.expectError(
        error.Exhausted,
        equal(&context, .nil, .nil, &.{ nested, nested }),
    );
    const report = budget.report() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(EvalContext.Budget.Resource.depth, report.resource);
}

test "equal? compares both cdr types before dereferencing" {
    const rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try std.testing.expectEqual(
        Value.false,
        try rt.evalString("(equal? (list 1 2 3) (list 1 2))"),
    );
    try std.testing.expectEqual(
        Value.false,
        try rt.evalString("(equal? (cons 1 (cons 2 nil)) (cons 1 2))"),
    );
    try std.testing.expectEqual(
        Value.false,
        try rt.evalString("(equal? (list (cons 1 (cons 2 nil))) (list (cons 1 2)))"),
    );
    try std.testing.expectEqual(
        Value.true,
        try rt.evalString("(equal? (list (cons 1 2)) (list (cons 1 2)))"),
    );
    try std.testing.expectEqual(
        Value.true,
        try rt.evalString("(equal? (cons 1 (cons 2 3)) (cons 1 (cons 2 3)))"),
    );
}

test "equal? bounds deep cons walks" {
    const rt = try skript.Runtime.initWithConfig(
        std.testing.allocator,
        std.testing.io,
        .{ .max_heap_size = 4 * 1024 * 1024 },
    );
    defer rt.deinit();

    var list = Value.nil;
    for (0..deep_equal_walk_cap + 1) |_| {
        const ref = try rt.store.create([2]Value);
        ref.deref([2]Value).* = .{ .i64(1), list };
        list = .cons(ref.toObject());
    }
    try std.testing.expectError(
        error.Unsupported,
        equal(rt.context(), .nil, .nil, &.{ list, list }),
    );

    var nested = Value.nil;
    for (0..deep_equal_pending_cap + 1) |_| {
        const ref = try rt.store.create([2]Value);
        ref.deref([2]Value).* = .{ nested, .nil };
        nested = .cons(ref.toObject());
    }
    try std.testing.expectError(
        error.Unsupported,
        equal(rt.context(), .nil, .nil, &.{ nested, nested }),
    );
}

test "equal? compares cyclic cons graphs coinductively" {
    const rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const cdr_ref = try rt.store.create([2]Value);
    const cdr_cycle = Value.cons(cdr_ref.toObject());
    cdr_ref.deref([2]Value).* = .{ .i64(1), cdr_cycle };
    const finite = try rt.evalString("(cons 1 nil)");
    try std.testing.expectEqual(
        Value.false,
        try equal(rt.context(), .nil, .nil, &.{ cdr_cycle, finite }),
    );
    try std.testing.expectEqual(
        Value.true,
        try equal(rt.context(), .nil, .nil, &.{ cdr_cycle, cdr_cycle }),
    );

    const other_ref = try rt.store.create([2]Value);
    const other_cycle = Value.cons(other_ref.toObject());
    other_ref.deref([2]Value).* = .{ .i64(1), other_cycle };
    try std.testing.expectEqual(
        Value.true,
        try equal(rt.context(), .nil, .nil, &.{ cdr_cycle, other_cycle }),
    );

    const two_a_ref = try rt.store.create([2]Value);
    const two_b_ref = try rt.store.create([2]Value);
    const two_a = Value.cons(two_a_ref.toObject());
    const two_b = Value.cons(two_b_ref.toObject());
    two_a_ref.deref([2]Value).* = .{ .i64(1), two_b };
    two_b_ref.deref([2]Value).* = .{ .i64(1), two_a };
    try std.testing.expectEqual(
        Value.true,
        try equal(rt.context(), .nil, .nil, &.{ cdr_cycle, two_a }),
    );

    const unequal_ref = try rt.store.create([2]Value);
    const unequal_cycle = Value.cons(unequal_ref.toObject());
    unequal_ref.deref([2]Value).* = .{ .i64(2), unequal_cycle };
    try std.testing.expectEqual(
        Value.false,
        try equal(rt.context(), .nil, .nil, &.{ cdr_cycle, unequal_cycle }),
    );

    const car_ref = try rt.store.create([2]Value);
    const car_cycle = Value.cons(car_ref.toObject());
    car_ref.deref([2]Value).* = .{ car_cycle, .nil };
    try std.testing.expectEqual(
        Value.true,
        try equal(rt.context(), .nil, .nil, &.{ car_cycle, car_cycle }),
    );
}

test "equal? charges work through nested cons" {
    const rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const list = try rt.evalString("(cons 1 nil)");
    var budget = EvalContext.Budget.init(std.testing.io, 1, .{ .work = 3 });
    var lease = try EvalContext.Budget.Lease.root(&budget, 3);
    var context = rt.context().*;
    context.lease = &lease;
    try std.testing.expectError(
        error.Exhausted,
        equal(&context, .nil, .nil, &.{ list, list }),
    );
    const report = budget.report() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(EvalContext.Budget.Resource.work, report.resource);
    try std.testing.expectEqual(@as(u64, 3), report.consumed.work);
}

// Regression test: numeric cross-type coercion returns false.
test "equal? numeric cross-type returns false" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // Cross-type numeric equality returns #f (no coercion).
    try std.testing.expectEqual(Value.false, try rt.evalString("(equal? 1 1.0)"));
    try std.testing.expectEqual(Value.false, try rt.evalString("(equal? 1.0 1)"));
    try std.testing.expectEqual(Value.false, try rt.evalString("(equal? (i32 1) (i64 1))"));
    // Same-type equality works.
    try std.testing.expectEqual(Value.true, try rt.evalString("(equal? 1 1)"));
    try std.testing.expectEqual(Value.true, try rt.evalString("(equal? 1.0 1.0)"));
}

// Float comparison uses IEEE equality for each numeric type.
test "equal? treats signed zero as equal and NaN as unequal" {
    const rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const ctx = rt.context();
    try std.testing.expectEqual(
        Value.true,
        try equal(ctx, .nil, .nil, &.{ Value.f16(0.0), Value.f16(-0.0) }),
    );
    try std.testing.expectEqual(
        Value.true,
        try equal(ctx, .nil, .nil, &.{ Value.f32(0.0), Value.f32(-0.0) }),
    );
    try std.testing.expectEqual(
        Value.false,
        try equal(ctx, .nil, .nil, &.{ Value.f32(std.math.nan(f32)), Value.f32(std.math.nan(f32)) }),
    );
    const nan = Value.f64(std.math.nan(f64));
    try std.testing.expectEqual(Value.false, try equal(ctx, .nil, .nil, &.{ nan, nan }));
}

fn testingByteVector(rt: *skript.Runtime, bytes: []const u8) !Value {
    const allocation = try rt.store.allocSlice(u8, bytes.len);
    @memcpy(allocation.slice, bytes);
    const reference = try rt.store.create(Value.ByteVector);
    rt.store.store(Value.ByteVector, reference.deref(Value.ByteVector), .{
        .bytes = allocation.slice,
    });
    return Value.byteVector(reference.toObject());
}

test "equal? compares bytevectors by bounded byte content" {
    // Keep the oversized payload outside the Store so equality reaches its byte limit.
    const too_long_bytes = try std.testing.allocator.alloc(u8, deep_equal_byte_cap + 1);
    defer std.testing.allocator.free(too_long_bytes);
    @memset(too_long_bytes, 0);

    const rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const bytes = [_]u8{ 0, 255, 7 };
    const first = try testingByteVector(rt, &bytes);
    const second = try testingByteVector(rt, &bytes);
    const different = try testingByteVector(rt, &.{ 0, 255, 8 });
    const empty_first = try testingByteVector(rt, &.{});
    const empty_second = try testingByteVector(rt, &.{});
    const ctx = rt.context();

    try std.testing.expectEqual(Value.true, try equal(ctx, .nil, .nil, &.{ first, second }));
    try std.testing.expectEqual(Value.false, try equal(ctx, .nil, .nil, &.{ first, different }));
    try std.testing.expectEqual(Value.true, try equal(ctx, .nil, .nil, &.{ empty_first, empty_second }));

    const too_long_ref = try rt.store.create(Value.ByteVector);
    rt.store.store(Value.ByteVector, too_long_ref.deref(Value.ByteVector), .{
        .bytes = too_long_bytes,
    });
    const too_long = Value.byteVector(too_long_ref.toObject());
    try std.testing.expectError(
        error.Unsupported,
        equal(ctx, .nil, .nil, &.{ too_long, too_long }),
    );
    var budget = EvalContext.Budget.init(std.testing.io, 8_342, .{ .work = 3 });
    var lease = try EvalContext.Budget.Lease.root(&budget, 3);
    var limited = ctx.*;
    limited.lease = &lease;
    try std.testing.expectError(
        error.Exhausted,
        equal(&limited, .nil, .nil, &.{ first, second }),
    );
}
