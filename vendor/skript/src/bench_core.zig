const std = @import("std");
const builtin = @import("builtin");
const skript = @import("skript");

const Object = skript.Object;
const Runtime = skript.Runtime;
const EvalContext = skript.EvalContext;
const Value = skript.Value;
const Expr = skript.Expr;
const TensorHolder = skript.intrinsics.tensor.TensorHolder;

const closure_form =
    "((fn (base x) (let ((x 100)) ((fn (y) (+ base (+ x y))) 1))) 2 3)";
const closure_2_forms = closure_form ++ "\n" ++ closure_form;
const closure_4_forms = closure_2_forms ++ "\n" ++ closure_2_forms;
const closure_8_forms = closure_4_forms ++ "\n" ++ closure_4_forms;
const closure_16_forms = closure_8_forms ++ "\n" ++ closure_8_forms;
const closure_32_forms = closure_16_forms ++ "\n" ++ closure_16_forms;

const i64_branch_source =
    \\(defn (i64-branch-loop n acc)
    \\  (if (= n 0)
    \\      acc
    \\      (if (< n 2048)
    \\          (i64-branch-loop (- n 1) (+ acc 3))
    \\          (i64-branch-loop (- n 1) (+ acc 2)))))
    \\(i64-branch-loop 4096 0)
;

const f64_branch_source =
    \\(defn (f64-branch-loop n acc)
    \\  (if (= n 0)
    \\      acc
    \\      (if (< n 2048)
    \\          (f64-branch-loop (- n 1) (+ acc 0.5))
    \\          (f64-branch-loop (- n 1) (+ acc 1.25)))))
    \\(f64-branch-loop 4096 0.0)
;

const tail_calls_source =
    \\(defn (tail-sum n acc)
    \\  (if (= n 0) acc (tail-sum (- n 1) (+ acc n))))
    \\(tail-sum 200000 0)
;

const dynamic_method_source =
    \\(def dynamic-add (fn (x y) (+ x y)))
    \\(dynamic-add 40 2.5)
;

const tensor_64_source =
    \\(def to-f64 (fn (x) (+ x 1.0)))
    \\(def square (fn (x) (* x x)))
    \\(def add-values (fn (a b) (+ a b)))
    \\(def tensor-values (map (iota 64) to-f64))
    \\(def tensor-squares (map tensor-values square))
    \\(def tensor-shaped (reshape tensor-squares [8 8]))
    \\(fold (fold tensor-shaped 0 add-values) add-values)
;

const tensor_4096_source =
    \\(def to-f64 (fn (x) (+ x 1.0)))
    \\(def square (fn (x) (* x x)))
    \\(def add-values (fn (a b) (+ a b)))
    \\(def tensor-values (map (iota 4096) to-f64))
    \\(def tensor-squares (map tensor-values square))
    \\(def tensor-shaped (reshape tensor-squares [64 64]))
    \\(fold (fold tensor-shaped 0 add-values) add-values)
;

const tensor_65536_source =
    \\(def to-f64 (fn (x) (+ x 1.0)))
    \\(def square (fn (x) (* x x)))
    \\(def add-values (fn (a b) (+ a b)))
    \\(def tensor-values (map (iota 65536) to-f64))
    \\(def tensor-squares (map tensor-values square))
    \\(def tensor-shaped (reshape tensor-squares [256 256]))
    \\(fold (fold tensor-shaped 0 add-values) add-values)
;

const ad_jvp_square_source = "((deriv (fn (x) (* x x))) 3.0)";
const symbolic_square_source =
    \\(def symbolic-x (symbolic-var 'x))
    \\(def symbolic-square (symbolic (fn (x) (* x x)) symbolic-x))
    \\((compile-expr symbolic-square symbolic-x) 3.0)
;
const syntax_error_source = "[1 2";

const Oracle = union(enum) {
    integer: i64,
    float: f64,
};

const Case = struct {
    name: []const u8,
    source: []const u8,
    oracle: Oracle,
    metered: bool = false,
};

const measured_cases = [_]Case{
    .{ .name = "closure_forms_1", .source = closure_form, .oracle = .{ .integer = 103 } },
    .{ .name = "closure_forms_8", .source = closure_8_forms, .oracle = .{ .integer = 103 } },
    .{ .name = "closure_forms_32", .source = closure_32_forms, .oracle = .{ .integer = 103 } },
    .{ .name = "scalar_i64_branch", .source = i64_branch_source, .oracle = .{ .integer = 10_239 } },
    .{
        .name = "scalar_i64_branch_metered",
        .source = i64_branch_source,
        .oracle = .{ .integer = 10_239 },
        .metered = true,
    },
    .{ .name = "scalar_f64_branch", .source = f64_branch_source, .oracle = .{ .float = 3_584.75 } },
    .{ .name = "tail_calls_200000", .source = tail_calls_source, .oracle = .{ .integer = 20_000_100_000 } },
    .{ .name = "dynamic_method_fallback", .source = dynamic_method_source, .oracle = .{ .float = 42.5 } },
    .{ .name = "tensor_sumsq_64", .source = tensor_64_source, .oracle = .{ .float = 89_440.0 } },
    .{ .name = "tensor_sumsq_4096", .source = tensor_4096_source, .oracle = .{ .float = 22_914_881_536.0 } },
    .{ .name = "tensor_sumsq_65536", .source = tensor_65536_source, .oracle = .{ .float = 93_827_139_731_456.0 } },
    .{ .name = "ad_jvp_square", .source = ad_jvp_square_source, .oracle = .{ .float = 6.0 } },
    .{ .name = "symbolic_square", .source = symbolic_square_source, .oracle = .{ .float = 9.0 } },
};

const StructuredExprCase = struct {
    name: []const u8,
    node_count: usize,
    source_descriptor: []const u8,
};

const structured_expr_cases = [_]StructuredExprCase{
    .{
        .name = "structured_expr_32",
        .node_count = 32,
        .source_descriptor = "host Expr Region/rewrite/snapshot structured DAG; nodes=32",
    },
    .{
        .name = "structured_expr_1024",
        .node_count = 1_024,
        .source_descriptor = "host Expr Region/rewrite/snapshot structured DAG; nodes=1024",
    },
    .{
        .name = "structured_expr_16384",
        .node_count = 16_384,
        .source_descriptor = "host Expr Region/rewrite/snapshot structured DAG; nodes=16384",
    },
};

const reverse_tensor_loss_source = "(fn (x) (dot x x))";

const ReverseTensorCase = struct {
    name: []const u8,
    element_count: usize,
    source_descriptor: []const u8,
};

const reverse_tensor_cases = [_]ReverseTensorCase{
    .{
        .name = "tensor_reverse_sumsq_64",
        .element_count = 64,
        .source_descriptor = reverse_tensor_loss_source ++ "; input=f64[64]:1..64",
    },
    .{
        .name = "tensor_reverse_sumsq_4096",
        .element_count = 4_096,
        .source_descriptor = reverse_tensor_loss_source ++ "; input=f64[4096]:1..4096",
    },
    .{
        .name = "tensor_reverse_sumsq_65536",
        .element_count = 65_536,
        .source_descriptor = reverse_tensor_loss_source ++ "; input=f64[65536]:1..65536",
    },
};

const PhaseAllocationStats = struct {
    request_count: u64,
    requested_bytes: u64,
    retained_bytes: u64,
    peak_retained_bytes: u64,
};

const CountingAllocator = struct {
    parent: std.mem.Allocator,
    request_count: u64 = 0,
    requested_bytes: u64 = 0,
    retained_bytes: u64 = 0,
    phase_request_count_start: u64 = 0,
    phase_requested_bytes_start: u64 = 0,
    phase_peak_retained_bytes: u64 = 0,

    fn init(parent: std.mem.Allocator) CountingAllocator {
        return .{ .parent = parent };
    }

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = allocate,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn beginPhase(self: *CountingAllocator) void {
        self.phase_request_count_start = self.request_count;
        self.phase_requested_bytes_start = self.requested_bytes;
        self.phase_peak_retained_bytes = self.retained_bytes;
    }

    fn phaseStats(self: *const CountingAllocator) PhaseAllocationStats {
        std.debug.assert(self.request_count >= self.phase_request_count_start);
        std.debug.assert(self.requested_bytes >= self.phase_requested_bytes_start);
        return .{
            .request_count = self.request_count - self.phase_request_count_start,
            .requested_bytes = self.requested_bytes - self.phase_requested_bytes_start,
            .retained_bytes = self.retained_bytes,
            .peak_retained_bytes = self.phase_peak_retained_bytes,
        };
    }

    fn recordRequest(self: *CountingAllocator, bytes: usize) void {
        const bytes_u64: u64 = @intCast(bytes);
        std.debug.assert(self.request_count < std.math.maxInt(u64));
        std.debug.assert(self.requested_bytes <= std.math.maxInt(u64) - bytes_u64);
        self.request_count += 1;
        self.requested_bytes += bytes_u64;
    }

    fn updateRetained(self: *CountingAllocator, old_bytes: usize, new_bytes: usize) void {
        const old_u64: u64 = @intCast(old_bytes);
        const new_u64: u64 = @intCast(new_bytes);
        if (new_u64 >= old_u64) {
            const growth = new_u64 - old_u64;
            std.debug.assert(self.retained_bytes <= std.math.maxInt(u64) - growth);
            self.retained_bytes += growth;
            self.phase_peak_retained_bytes = @max(
                self.phase_peak_retained_bytes,
                self.retained_bytes,
            );
        } else {
            const reduction = old_u64 - new_u64;
            std.debug.assert(self.retained_bytes >= reduction);
            self.retained_bytes -= reduction;
        }
    }

    fn allocate(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.recordRequest(len);
        const result = self.parent.rawAlloc(len, alignment, return_address);
        if (result != null) self.updateRetained(0, len);
        return result;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.recordRequest(new_len);
        const resized = self.parent.rawResize(memory, alignment, new_len, return_address);
        if (resized) self.updateRetained(memory.len, new_len);
        return resized;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.recordRequest(new_len);
        const result = self.parent.rawRemap(memory, alignment, new_len, return_address);
        if (result != null) self.updateRetained(memory.len, new_len);
        return result;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.parent.rawFree(memory, alignment, return_address);
        self.updateRetained(memory.len, 0);
    }
};

const BytecodeStats = struct {
    instruction_count: u64,
    bytes: u64,
};

const MeasurementSnapshot = struct {
    heap_used_bytes: u64,
    store_heap_committed_bytes: u64,
    store_heap_reserved_bytes: u64,
    store_live_objects: u64,
    store_folio_count: u64,
    store_symbol_count: u64,
    runtime_static_arena_retained_capacity_bytes: u64,
    store_sym_arena_retained_capacity_bytes: u64,
    allocator_phase_request_count: u64,
    allocator_phase_requested_bytes: u64,
    allocator_retained_bytes: u64,
    allocator_phase_peak_retained_bytes: u64,
};

const Timing = struct {
    init_ns: u64,
    elapsed_ns: u64,
    compile_ns: u64,
    execute_ns: u64,
};

const Row = struct {
    status: []const u8 = "ok",
    build_mode: []const u8 = @tagName(builtin.mode),
    case: []const u8,
    phase: []const u8,
    init_ns: u64,
    elapsed_ns: u64,
    compile_ns: u64,
    execute_ns: u64,
    bytecode_bytes: u64,
    heap_used_bytes: u64,
    source_sha256: []const u8,
    oracle_ok: bool,
    bytecode_instruction_count: u64,
    store_heap_committed_bytes: u64,
    store_heap_reserved_bytes: u64,
    store_live_objects: u64,
    store_folio_count: u64,
    store_symbol_count: u64,
    runtime_static_arena_retained_capacity_bytes: u64,
    store_sym_arena_retained_capacity_bytes: u64,
    allocator_phase_request_count: u64,
    allocator_phase_requested_bytes: u64,
    allocator_retained_bytes: u64,
    allocator_phase_peak_retained_bytes: u64,
    expected_error: ?[]const u8 = null,
    observed_error: ?[]const u8 = null,
};

const Execution = struct {
    value: Value,
    stack: []Object,
};

const TimedExecution = struct {
    execution: Execution,
    started: std.Io.Timestamp,
    finished: std.Io.Timestamp,
};

const MeteredExecutionContext = struct {
    budget: EvalContext.Budget,
    lease: EvalContext.Budget.Lease,
    account: EvalContext.Budget.AccountAllocator,
    output_bytes: [64]u8,
    output_writer: std.Io.Writer,
    context: EvalContext,

    fn init(self: *MeteredExecutionContext, runtime: *Runtime, lineage_id: u64) !void {
        const limits: EvalContext.Budget.Limits = .{
            .work = 1_000_000_000,
            .bytes = 64 * 1024 * 1024,
            .objects = 1_000_000,
            .nodes = 1_000_000,
            .output = 64,
            .processes = 1_024,
            .paths = 1_024,
            .depth = 1_024,
        };
        self.budget = EvalContext.Budget.init(runtime.io, lineage_id, limits);
        self.lease = try EvalContext.Budget.Lease.root(&self.budget, limits.work);
        self.account = EvalContext.Budget.AccountAllocator.init(
            runtime.gpa,
            &self.lease,
            .regvm,
        );
        self.output_writer = std.Io.Writer.fixed(&self.output_bytes);
        self.context = try EvalContext.limited(
            runtime,
            runtime.intrinsics.registryVersion(),
            &self.account,
            .{ .writer = &self.output_writer, .bounded_memory = true },
            .{
                .effects = .{
                    .state_read = .allow,
                    .state_write = .allow,
                },
            },
        );
    }
};

const StructuredExpression = struct {
    region: Expr.Region,
    handle: Expr.Handle,
};

const StructuredSummary = struct {
    node_count: u64 = 0,
    node_id_sum: u64 = 0,
    edge_count: u64 = 0,
    scalar_count: u64 = 0,
    static_atom_count: u64 = 0,
    list_count: u64 = 0,
    map_count: u64 = 0,
    tensor_count: u64 = 0,
    record_count: u64 = 0,
    scalar_sum: f64 = 0.0,
    structure_ok: bool = true,
};

const ReverseExecution = struct {
    primal: Value,
    gradient: Value,
    pullback: Value,
};

pub fn run(
    parent_gpa: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
) !void {
    for (measured_cases) |case| {
        try runMeasuredCase(parent_gpa, io, output, case, 0);
    }
    for (structured_expr_cases) |case| {
        try runStructuredExprCase(parent_gpa, io, output, case);
    }
    for (reverse_tensor_cases) |case| {
        try runReverseTensorCase(parent_gpa, io, output, case);
    }
    try runExpectedSyntaxError(parent_gpa, io, output);
}

/// Run one named measured workload without the reverse-AD suite. Useful when
/// profiling a short scalar or tensor-primal case in isolation.
pub fn runCase(
    parent_gpa: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    name: []const u8,
    profile_repeats: usize,
) !void {
    for (measured_cases) |case| {
        if (!std.mem.eql(u8, case.name, name)) continue;
        return runMeasuredCase(parent_gpa, io, output, case, profile_repeats);
    }
    return error.UnknownCase;
}

fn runMeasuredCase(
    parent_gpa: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    case: Case,
    profile_repeats: usize,
) !void {
    var counting_allocator = CountingAllocator.init(parent_gpa);
    counting_allocator.beginPhase();

    const cold_started = std.Io.Timestamp.now(io, .awake);
    const runtime = try Runtime.init(counting_allocator.allocator(), io);
    defer runtime.deinit();

    const compile_started = std.Io.Timestamp.now(io, .awake);
    const forms = try skript.Reader.readAll(runtime.store, case.source);
    const program = try runtime.compileData(runtime.root_ns, forms, null);
    const compile_finished = std.Io.Timestamp.now(io, .awake);
    const bytecode = try bytecodeStats(program);
    const stack = try runtime.static.alloc(Object, stackSize(program));
    const cold_timed = try executeProgramTimed(
        io,
        runtime,
        program,
        stack,
        case.metered,
        90_000,
    );
    const cold_execution = cold_timed.execution;
    const cold_finished = cold_timed.finished;

    const cold_oracle_ok = oracleMatches(cold_execution.value, case.oracle);
    const cold_snapshot = measurementSnapshot(runtime, &counting_allocator);
    const source_sha256 = sourceSha256(case.source);
    try emitRow(output, makeRow(
        case.name,
        "cold",
        .{
            .init_ns = try elapsedNs(cold_started, compile_started),
            .elapsed_ns = try elapsedNs(cold_started, cold_finished),
            .compile_ns = try elapsedNs(compile_started, compile_finished),
            .execute_ns = try elapsedNs(cold_timed.started, cold_finished),
        },
        bytecode,
        cold_snapshot,
        source_sha256[0..],
        cold_oracle_ok,
    ));
    if (!cold_oracle_ok) return error.OracleMismatch;

    counting_allocator.beginPhase();
    const warm_timed = try executeProgramTimed(
        io,
        runtime,
        program,
        cold_execution.stack,
        case.metered,
        90_001,
    );
    const warm_execution = warm_timed.execution;
    const warm_oracle_ok = oracleMatches(warm_execution.value, case.oracle);
    const warm_snapshot = measurementSnapshot(runtime, &counting_allocator);
    try emitRow(output, makeRow(
        case.name,
        "warm",
        .{
            .init_ns = 0,
            .elapsed_ns = try elapsedNs(warm_timed.started, warm_timed.finished),
            .compile_ns = 0,
            .execute_ns = try elapsedNs(warm_timed.started, warm_timed.finished),
        },
        bytecode,
        warm_snapshot,
        source_sha256[0..],
        warm_oracle_ok,
    ));
    if (!warm_oracle_ok) return error.OracleMismatch;
    if (profile_repeats == 0) return;
    var last: Value = .nil;
    for (0..profile_repeats) |_| {
        const repeat = try executeProgramTimed(io, runtime, program, warm_execution.stack, case.metered, 90_002);
        last = repeat.execution.value;
    }
    if (!oracleMatches(last, case.oracle)) return error.OracleMismatch;
}

fn executeProgramTimed(
    io: std.Io,
    runtime: *Runtime,
    program: Runtime.RegProgram,
    stack: []Object,
    metered: bool,
    lineage_id: u64,
) !TimedExecution {
    if (metered) {
        // SAFETY: init writes every field before limited.context is read below.
        var limited: MeteredExecutionContext = undefined;
        try limited.init(runtime, lineage_id);
        const scope = limited.context.activate();
        defer scope.deinit();
        const started = std.Io.Timestamp.now(io, .awake);
        const execution = try executeProgram(runtime, program, stack);
        const finished = std.Io.Timestamp.now(io, .awake);
        return .{ .execution = execution, .started = started, .finished = finished };
    }

    const started = std.Io.Timestamp.now(io, .awake);
    const execution = try executeProgram(runtime, program, stack);
    const finished = std.Io.Timestamp.now(io, .awake);
    return .{ .execution = execution, .started = started, .finished = finished };
}

fn runStructuredExprCase(
    parent_gpa: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    case: StructuredExprCase,
) !void {
    var counting_allocator = CountingAllocator.init(parent_gpa);
    counting_allocator.beginPhase();

    const cold_started = std.Io.Timestamp.now(io, .awake);
    const runtime = try Runtime.init(counting_allocator.allocator(), io);
    defer runtime.deinit();

    const compile_started = std.Io.Timestamp.now(io, .awake);
    var expression = try buildStructuredExpr(runtime, case.node_count);
    defer {
        expression.handle.deinit();
        expression.region.deinit();
    }
    const compile_finished = std.Io.Timestamp.now(io, .awake);

    const execute_started = std.Io.Timestamp.now(io, .awake);
    const cold_summary = try executeStructuredExpr(runtime, &expression, case.node_count);
    const cold_finished = std.Io.Timestamp.now(io, .awake);
    const cold_oracle_ok = structuredOracleMatches(cold_summary, case.node_count);
    const cold_snapshot = measurementSnapshot(runtime, &counting_allocator);
    const source_sha256 = sourceSha256(case.source_descriptor);
    const no_bytecode: BytecodeStats = .{ .instruction_count = 0, .bytes = 0 };
    try emitRow(output, makeRow(
        case.name,
        "cold",
        .{
            .init_ns = try elapsedNs(cold_started, compile_started),
            .elapsed_ns = try elapsedNs(cold_started, cold_finished),
            .compile_ns = try elapsedNs(compile_started, compile_finished),
            .execute_ns = try elapsedNs(execute_started, cold_finished),
        },
        no_bytecode,
        cold_snapshot,
        source_sha256[0..],
        cold_oracle_ok,
    ));
    if (!cold_oracle_ok) return error.OracleMismatch;

    counting_allocator.beginPhase();
    const warm_started = std.Io.Timestamp.now(io, .awake);
    const warm_summary = try executeStructuredExpr(runtime, &expression, case.node_count);
    const warm_finished = std.Io.Timestamp.now(io, .awake);
    const warm_oracle_ok = structuredOracleMatches(warm_summary, case.node_count);
    const warm_snapshot = measurementSnapshot(runtime, &counting_allocator);
    try emitRow(output, makeRow(
        case.name,
        "warm",
        .{
            .init_ns = 0,
            .elapsed_ns = try elapsedNs(warm_started, warm_finished),
            .compile_ns = 0,
            .execute_ns = try elapsedNs(warm_started, warm_finished),
        },
        no_bytecode,
        warm_snapshot,
        source_sha256[0..],
        warm_oracle_ok,
    ));
    if (!warm_oracle_ok) return error.OracleMismatch;
}

fn structuredEdgeCount(node_count: usize) usize {
    std.debug.assert(node_count >= 5);
    return node_count * 2 - 3;
}

fn structuredExprLimits(node_count: usize) Expr.Limits {
    return .{
        .max_nodes = node_count,
        .max_edges = structuredEdgeCount(node_count),
        .max_names = 8,
        .max_labels = 6,
        .max_name_bytes = 64,
        .max_shape_dimensions = 1,
        .max_depth = 4,
    };
}

fn buildStructuredExpr(runtime: *Runtime, node_count: usize) !StructuredExpression {
    std.debug.assert(node_count >= 5);
    const context = runtime.context();
    var region = try Expr.Region.init(
        runtime.gpa,
        context,
        .{
            .identity = try Expr.RegionId.fromInt(@intCast(node_count)),
            .limits = structuredExprLimits(node_count),
        },
    );
    errdefer region.deinit();

    const quoted_label = try region.intern(context, .{ .static_atom = .{
        .kind = .symbol,
        .bytes = "quoted-label",
    } });
    const scalar_count = node_count - 5;
    const scalar_nodes = try runtime.gpa.alloc(Expr.NodeId, scalar_count);
    defer runtime.gpa.free(scalar_nodes);
    for (scalar_nodes, 0..) |*node, index| {
        const value: f64 = @floatFromInt(index + 1);
        node.* = try region.intern(context, .{ .scalar = .{
            .value = Expr.Scalar.fromF64(value),
            .domain = .real,
        } });
    }

    const list_elements = try runtime.gpa.alloc(Expr.NodeId, scalar_count + 1);
    defer runtime.gpa.free(list_elements);
    list_elements[0] = quoted_label;
    @memcpy(list_elements[1..], scalar_nodes);
    const list = try region.intern(context, .{ .list = .{
        .elements = list_elements,
    } });
    const map = try region.intern(context, .{ .map = .{
        .labels = &.{ "'quoted-label", ":items" },
        .values = &.{ quoted_label, list },
    } });
    const tensor_shape = [_]u32{@intCast(scalar_count)};
    const tensor = try region.intern(context, .{ .tensor = .{
        .dtype = .f64,
        .shape = &tensor_shape,
        .elements = scalar_nodes,
    } });
    const root = try region.intern(context, .{ .record = .{
        .type_label = "Bundle",
        .field_labels = &.{ "items", "lookup", "array", "quoted" },
        .fields = &.{ list, map, tensor, quoted_label },
    } });
    var handle = try region.handle(context, root);
    errdefer handle.deinit();
    return .{ .region = region, .handle = handle };
}

fn executeStructuredExpr(
    runtime: *Runtime,
    expression: *StructuredExpression,
    node_count: usize,
) !StructuredSummary {
    const context = runtime.context();
    var rewritten = try expression.region.rewrite(context, &expression.handle, .{
        .policy = .strict_ieee,
        .limits = .{
            .max_nodes = node_count,
            .max_edges = structuredEdgeCount(node_count),
            .max_rule_steps = 1,
            .max_passes = 1,
        },
    });
    defer rewritten.deinit();
    var snapshot = try rewritten.snapshot(
        runtime.gpa,
        context,
        structuredExprLimits(node_count),
    );
    defer snapshot.deinit();

    var summary: StructuredSummary = .{
        .structure_ok = rewritten.nodeId() == expression.handle.nodeId(),
    };
    summary.node_count = @intCast(snapshot.nodeCount());
    for (0..snapshot.nodeCount()) |index| {
        const id = try Expr.NodeId.fromIndex(index);
        const node = try snapshot.node(id);
        summary.structure_ok = summary.structure_ok and node.id == id;
        summary.node_id_sum += @as(u64, @backingInt(node.id));
        summary.edge_count += @intCast((try snapshot.operands(node)).len);
        switch (node.kind) {
            .scalar => |scalar| {
                summary.scalar_count += 1;
                switch (scalar.value) {
                    .f64_bits => |bits| {
                        summary.scalar_sum += @as(f64, @bitCast(bits));
                    },
                    else => summary.structure_ok = false,
                }
            },
            .static_atom => summary.static_atom_count += 1,
            .list => summary.list_count += 1,
            .map => summary.map_count += 1,
            .tensor => summary.tensor_count += 1,
            .record => summary.record_count += 1,
            else => summary.structure_ok = false,
        }
    }
    summary.structure_ok = summary.structure_ok and
        try structuredSnapshotMatchesLayout(&snapshot, node_count);
    return summary;
}

fn structuredSnapshotMatchesLayout(
    snapshot: *const Expr.Snapshot,
    node_count: usize,
) !bool {
    if (snapshot.nodeCount() != node_count) return false;
    const scalar_count = node_count - 5;
    const root_node = try snapshot.node(snapshot.root());
    const record = switch (root_node.kind) {
        .record => |value| value,
        else => return false,
    };
    if (!std.mem.eql(u8, try snapshot.name(record.type_label), "Bundle")) return false;
    const record_labels = [_][]const u8{ "items", "lookup", "array", "quoted" };
    for (record_labels, 0..) |expected, index| {
        if (!std.mem.eql(u8, try snapshot.label(record.fields, index), expected)) {
            return false;
        }
    }
    const record_fields = try snapshot.operands(root_node);
    if (record_fields.len != record_labels.len) return false;

    const list_node = try snapshot.node(record_fields[0]);
    const list = switch (list_node.kind) {
        .list => |value| value,
        else => return false,
    };
    if (list.domain != .structured) return false;
    const list_elements = try snapshot.operands(list_node);
    if (list_elements.len != scalar_count + 1) return false;

    const map_node = try snapshot.node(record_fields[1]);
    const map = switch (map_node.kind) {
        .map => |value| value,
        else => return false,
    };
    if (map.domain != .structured) return false;
    if (!std.mem.eql(u8, try snapshot.label(map.labels, 0), "'quoted-label")) {
        return false;
    }
    if (!std.mem.eql(u8, try snapshot.label(map.labels, 1), ":items")) return false;
    const map_values = try snapshot.operands(map_node);
    if (map_values.len != 2) return false;
    if (map_values[0] != record_fields[3] or map_values[1] != record_fields[0]) {
        return false;
    }

    const tensor_node = try snapshot.node(record_fields[2]);
    const tensor = switch (tensor_node.kind) {
        .tensor => |value| value,
        else => return false,
    };
    if (tensor.domain != .structured or tensor.dtype != .f64) return false;
    const tensor_shape = try snapshot.shape(tensor.shape);
    if (tensor_shape.len != 1 or @as(usize, @intCast(tensor_shape[0])) != scalar_count) return false;
    const tensor_elements = try snapshot.operands(tensor_node);
    if (!std.mem.eql(Expr.NodeId, list_elements[1..], tensor_elements)) return false;
    if (list_elements[0] != record_fields[3]) return false;

    const quoted_node = try snapshot.node(record_fields[3]);
    const quoted = switch (quoted_node.kind) {
        .static_atom => |value| value,
        else => return false,
    };
    if (quoted.kind != .symbol) return false;
    return std.mem.eql(u8, try snapshot.name(quoted.name), "quoted-label");
}

fn triangular(value: u64) u64 {
    return value * (value + 1) / 2;
}

fn structuredOracleMatches(summary: StructuredSummary, node_count: usize) bool {
    const node_count_u64: u64 = @intCast(node_count);
    const scalar_count = node_count_u64 - 5;
    return summary.structure_ok and
        summary.node_count == node_count_u64 and
        summary.node_id_sum == triangular(node_count_u64 - 1) and
        summary.edge_count == @as(u64, @intCast(structuredEdgeCount(node_count))) and
        summary.scalar_count == scalar_count and
        summary.static_atom_count == 1 and
        summary.list_count == 1 and
        summary.map_count == 1 and
        summary.tensor_count == 1 and
        summary.record_count == 1 and
        summary.scalar_sum == @as(f64, @floatFromInt(triangular(scalar_count)));
}

fn runReverseTensorCase(
    parent_gpa: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    case: ReverseTensorCase,
) !void {
    var counting_allocator = CountingAllocator.init(parent_gpa);
    counting_allocator.beginPhase();

    const cold_started = std.Io.Timestamp.now(io, .awake);
    const runtime = try Runtime.init(counting_allocator.allocator(), io);
    defer runtime.deinit();

    const compile_started = std.Io.Timestamp.now(io, .awake);
    const forms = try skript.Reader.readAll(runtime.store, reverse_tensor_loss_source);
    const program = try runtime.compileData(runtime.root_ns, forms, null);
    const bytecode = try bytecodeStats(program);
    const stack = try runtime.static.alloc(Object, stackSize(program));
    const compiled_execution = try executeProgram(runtime, program, stack);
    const loss = try compiled_execution.value.unwrapError();
    if (loss.typ != skript.builtins.type_closure) return error.TypeMismatch;
    const compile_finished = std.Io.Timestamp.now(io, .awake);

    const input = try makeReverseTensorInput(runtime, case.element_count);
    var pullback_workspace = Runtime.CallWorkspace.init(runtime.gpa);
    defer pullback_workspace.deinit();

    const execute_started = std.Io.Timestamp.now(io, .awake);
    const cold_execution = try executeReverseTensor(
        runtime,
        loss,
        input,
        &pullback_workspace,
    );
    const cold_finished = std.Io.Timestamp.now(io, .awake);
    const cold_oracle_ok = reverseTensorOracleMatches(cold_execution, case.element_count);
    const cold_snapshot = measurementSnapshot(runtime, &counting_allocator);
    try closeReversePullback(runtime, cold_execution.pullback);
    const source_sha256 = sourceSha256(case.source_descriptor);
    try emitRow(output, makeRow(
        case.name,
        "cold",
        .{
            .init_ns = try elapsedNs(cold_started, compile_started),
            .elapsed_ns = try elapsedNs(cold_started, cold_finished),
            .compile_ns = try elapsedNs(compile_started, compile_finished),
            .execute_ns = try elapsedNs(execute_started, cold_finished),
        },
        bytecode,
        cold_snapshot,
        source_sha256[0..],
        cold_oracle_ok,
    ));
    if (!cold_oracle_ok) return error.OracleMismatch;

    counting_allocator.beginPhase();
    const warm_started = std.Io.Timestamp.now(io, .awake);
    const warm_execution = try executeReverseTensor(
        runtime,
        loss,
        input,
        &pullback_workspace,
    );
    const warm_finished = std.Io.Timestamp.now(io, .awake);
    const warm_oracle_ok = reverseTensorOracleMatches(warm_execution, case.element_count);
    const warm_snapshot = measurementSnapshot(runtime, &counting_allocator);
    try closeReversePullback(runtime, warm_execution.pullback);
    try emitRow(output, makeRow(
        case.name,
        "warm",
        .{
            .init_ns = 0,
            .elapsed_ns = try elapsedNs(warm_started, warm_finished),
            .compile_ns = 0,
            .execute_ns = try elapsedNs(warm_started, warm_finished),
        },
        bytecode,
        warm_snapshot,
        source_sha256[0..],
        warm_oracle_ok,
    ));
    if (!warm_oracle_ok) return error.OracleMismatch;
}

fn makeReverseTensorInput(runtime: *Runtime, element_count: usize) !Value {
    const elements = try runtime.gpa.alloc(Value, element_count);
    defer runtime.gpa.free(elements);
    for (elements, 0..) |*element, index| {
        element.* = .f64(@floatFromInt(index + 1));
    }
    return skript.intrinsics.tensor.create(
        runtime.context(),
        .nil,
        .nil,
        elements,
    );
}

fn executeReverseTensor(
    runtime: *Runtime,
    loss: Value,
    input: Value,
    workspace: *Runtime.CallWorkspace,
) !ReverseExecution {
    const context = runtime.context();
    const pair = try skript.intrinsics.ad_reverse.vjp(
        context,
        runtime.root_ns,
        .nil,
        &.{ loss, input },
    );
    const primal_value = try skript.intrinsics.list.fst(
        context,
        .nil,
        .nil,
        &.{pair},
    );
    const rest = try skript.intrinsics.list.rst(context, .nil, .nil, &.{pair});
    const pullback_value = try skript.intrinsics.list.fst(
        context,
        .nil,
        .nil,
        &.{rest},
    );
    const primal = try primal_value.unwrapError();
    const pullback = try pullback_value.unwrapError();
    var outputs: [1]Value = undefined;
    try workspace.apply(context, pullback, &.{Value.f64(1.0)}, &outputs);
    return .{
        .primal = primal,
        .gradient = try outputs[0].unwrapError(),
        .pullback = pullback,
    };
}

fn closeReversePullback(runtime: *Runtime, pullback: Value) !void {
    const closed = try skript.intrinsics.ad_reverse.closeLinear(
        runtime.context(),
        .nil,
        .nil,
        &.{pullback},
    );
    if (!std.meta.eql(closed, Value.true)) return error.InvalidCode;
}

fn expectedSumSquares(element_count: usize) f64 {
    const count: u64 = @intCast(element_count);
    const total = count * (count + 1) * (2 * count + 1) / 6;
    return @floatFromInt(total);
}

fn reverseTensorOracleMatches(
    execution: ReverseExecution,
    element_count: usize,
) bool {
    if (execution.primal.typ != skript.builtins.type_f64) return false;
    if (execution.primal.obj.tof64() != expectedSumSquares(element_count)) return false;
    if (execution.gradient.typ != skript.builtins.type_tensor) return false;
    if (execution.gradient.obj == .null) return false;
    const gradient = execution.gradient.obj.toRef().deref(TensorHolder);
    if (gradient.inner != .f64 or gradient.rank != 1) return false;
    if (gradient.shape.len != 1 or @as(usize, @intCast(gradient.shape[0])) != element_count) return false;
    if (gradient.data.len != element_count) return false;

    var gradient_sum: f64 = 0.0;
    for (gradient.data, 0..) |word, index| {
        const expected: f64 = 2.0 * @as(f64, @floatFromInt(index + 1));
        const actual: f64 = @bitCast(word);
        if (actual != expected) return false;
        gradient_sum += actual;
    }
    const count: u64 = @intCast(element_count);
    return gradient_sum == @as(f64, @floatFromInt(count * (count + 1)));
}

fn runExpectedSyntaxError(
    parent_gpa: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
) !void {
    var counting_allocator = CountingAllocator.init(parent_gpa);
    counting_allocator.beginPhase();

    const cold_started = std.Io.Timestamp.now(io, .awake);
    const runtime = try Runtime.init(counting_allocator.allocator(), io);
    defer runtime.deinit();

    const compile_started = std.Io.Timestamp.now(io, .awake);
    const read_result = skript.Reader.readAll(runtime.store, syntax_error_source);
    const compile_finished = std.Io.Timestamp.now(io, .awake);

    var observed_error: ?[]const u8 = null;
    if (read_result) |_| {
        observed_error = null;
    } else |err| {
        observed_error = @errorName(err);
    }
    const oracle_ok = if (observed_error) |name|
        std.mem.eql(u8, name, "UnexpectedToken")
    else
        false;

    const snapshot = measurementSnapshot(runtime, &counting_allocator);
    const source_sha256 = sourceSha256(syntax_error_source);
    var row = makeRow(
        "syntax_error_unbalanced_tensor",
        "cold",
        .{
            .init_ns = try elapsedNs(cold_started, compile_started),
            .elapsed_ns = try elapsedNs(cold_started, compile_finished),
            .compile_ns = try elapsedNs(compile_started, compile_finished),
            .execute_ns = 0,
        },
        .{ .instruction_count = 0, .bytes = 0 },
        snapshot,
        &source_sha256,
        oracle_ok,
    );
    row.expected_error = "UnexpectedToken";
    row.observed_error = observed_error;
    try emitRow(output, row);
    if (!oracle_ok) return error.OracleMismatch;
}

fn executeProgram(
    runtime: *Runtime,
    program: Runtime.RegProgram,
    stack: []Object,
) !Execution {
    @memset(stack, .null);
    var fiber: Runtime.Fiber = .{
        .stack = stack,
        .sp = Runtime.frame_size + @as(usize, program.nregs) * 2,
        .ip = program.ir.ptr,
        .ir = program.ir,
        .nregs = program.nregs,
        .consts = program.constants,
        .fns = program.fns,
        .ns = runtime.root_ns,
    };
    const value = try runtime.runToCompletion(runtime.root_ns, &fiber);
    return .{ .value = value, .stack = fiber.stack };
}

fn stackSize(program: Runtime.RegProgram) usize {
    return Runtime.frame_size + @as(usize, program.nregs) * 2;
}

fn bytecodeStats(program: Runtime.RegProgram) !BytecodeStats {
    var instruction_count: u64 = @intCast(program.ir.len);
    for (program.fns) |function| {
        if (function.ir.ptr == program.ir.ptr and function.ir.len == program.ir.len) continue;
        instruction_count = try std.math.add(
            u64,
            instruction_count,
            @as(u64, @intCast(function.ir.len)),
        );
    }
    return .{
        .instruction_count = instruction_count,
        .bytes = try std.math.mul(
            u64,
            instruction_count,
            @as(u64, @sizeOf(skript.regvm.Inst)),
        ),
    };
}

fn oracleMatches(value: Value, oracle: Oracle) bool {
    return switch (oracle) {
        .integer => |expected| value.typ == skript.builtins.type_i64 and
            value.obj.toInt(i64) == expected,
        .float => |expected| value.typ == skript.builtins.type_f64 and
            value.obj.tof64() == expected,
    };
}

fn elapsedNs(started: std.Io.Timestamp, finished: std.Io.Timestamp) !u64 {
    if (finished.nanoseconds < started.nanoseconds) return error.NonMonotonicClock;
    return @intCast(finished.nanoseconds - started.nanoseconds);
}

fn sourceSha256(source: []const u8) [64]u8 {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(source, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn measurementSnapshot(
    runtime: *Runtime,
    counting_allocator: *const CountingAllocator,
) MeasurementSnapshot {
    const store_stats = runtime.store.stats();
    const allocation_stats = counting_allocator.phaseStats();
    return .{
        .heap_used_bytes = store_stats.heap_used,
        .store_heap_committed_bytes = store_stats.heap_committed,
        .store_heap_reserved_bytes = store_stats.heap_reserved,
        .store_live_objects = store_stats.live_objects,
        .store_folio_count = store_stats.folio_count,
        .store_symbol_count = store_stats.symbol_count,
        .runtime_static_arena_retained_capacity_bytes = @intCast(
            runtime.static_arena.queryCapacity(),
        ),
        .store_sym_arena_retained_capacity_bytes = @intCast(
            runtime.store.sym_arena.queryCapacity(),
        ),
        .allocator_phase_request_count = allocation_stats.request_count,
        .allocator_phase_requested_bytes = allocation_stats.requested_bytes,
        .allocator_retained_bytes = allocation_stats.retained_bytes,
        .allocator_phase_peak_retained_bytes = allocation_stats.peak_retained_bytes,
    };
}

fn makeRow(
    case_name: []const u8,
    phase: []const u8,
    timing: Timing,
    bytecode: BytecodeStats,
    snapshot: MeasurementSnapshot,
    source_sha256: []const u8,
    oracle_ok: bool,
) Row {
    return .{
        .case = case_name,
        .phase = phase,
        .init_ns = timing.init_ns,
        .elapsed_ns = timing.elapsed_ns,
        .compile_ns = timing.compile_ns,
        .execute_ns = timing.execute_ns,
        .bytecode_bytes = bytecode.bytes,
        .heap_used_bytes = snapshot.heap_used_bytes,
        .source_sha256 = source_sha256,
        .oracle_ok = oracle_ok,
        .bytecode_instruction_count = bytecode.instruction_count,
        .store_heap_committed_bytes = snapshot.store_heap_committed_bytes,
        .store_heap_reserved_bytes = snapshot.store_heap_reserved_bytes,
        .store_live_objects = snapshot.store_live_objects,
        .store_folio_count = snapshot.store_folio_count,
        .store_symbol_count = snapshot.store_symbol_count,
        .runtime_static_arena_retained_capacity_bytes = snapshot.runtime_static_arena_retained_capacity_bytes,
        .store_sym_arena_retained_capacity_bytes = snapshot.store_sym_arena_retained_capacity_bytes,
        .allocator_phase_request_count = snapshot.allocator_phase_request_count,
        .allocator_phase_requested_bytes = snapshot.allocator_phase_requested_bytes,
        .allocator_retained_bytes = snapshot.allocator_retained_bytes,
        .allocator_phase_peak_retained_bytes = snapshot.allocator_phase_peak_retained_bytes,
    };
}

fn emitRow(output: *std.Io.Writer, row: Row) !void {
    try std.json.Stringify.value(
        row,
        .{ .emit_null_optional_fields = false },
        output,
    );
    try output.writeByte('\n');
}
