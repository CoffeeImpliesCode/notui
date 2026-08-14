const std = @import("std");
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;
const List = std.ArrayList;
const log = std.log.scoped(.Runtime);

const skript = @import("root.zig");
const tracy = @import("tracy");
const Store = skript.Store;
const Ref = Store.Ref;
const Error = skript.Error;
const Value = skript.Value;
const Object = skript.Object;

const Sym = skript.Sym;
const Type = skript.Type;
const Namespace = skript.Namespace;
const HashMapNamespace = skript.HashMapNamespace;
const SmallNamespace = skript.SmallNamespace;
const ExportNamespace = skript.data.ExportNamespace;

const Ast = skript.Ast;
const AstNodeRef = skript.AstNodeRef;
const SourceUnit = @import("SourceUnit.zig");
const Closure = skript.data.Closure;
const ClosureGuard = skript.data.ClosureGuard;
const FuncPtr = skript.FuncPtr;

const intrin = skript.intrinsics;
const Intrinsics = @import("intrinsics.zig").Intrinsics;
const regvm = @import("regvm.zig");
const Bind = @import("bind.zig");
const Code = @import("code.zig");
const AdEffects = @import("ad_effects.zig");

const RegLower = @import("reg_lower.zig");
const PrimitiveId = skript.PrimitiveId;
const EvalContext = skript.EvalContext;
const sched_mod = @import("scheduler.zig");
const mod_reg = @import("modules.zig");
const StoreGcRoots = @import("runtime/store_gc_roots.zig");
const SourceInspection = @import("runtime/source_inspection.zig");

const prelude = @embedFile("prelude.pt");

pub const b = @import("builtin.zig");
pub const AdCache = @import("intrinsics/ad.zig").AdCache;

/// Compiler-only marker stored in recursive-binding cells before initialization.
/// Its tag is outside the builtin range and cannot be constructed by Skript code.
pub const uninitialized_binding_marker: Value =
    Value.init(Object.fromInt(b.type_last_idx + 1), .null);

const Linearize = @import("autodiff/linearize.zig");
const Symbolic = @import("intrinsics/symbolic.zig");

const Runtime = @This();

pub const Dependency = struct {
    cell_id: u64,
    revision: u64,
    value: Value,
    method_id: u64 = 0,
    method_revision: u64 = 0,
};

pub const CodeIdentity = struct {
    id: u32,
    revision: u64,
};

const DependencyKey = struct { namespace: Object, binding: Sym };
const DependencyCell = struct {
    id: u64,
    revision: u64 = 1,
    value: Value,
    valid: bool = true,
};

static_arena: Arena,
static: Allocator,
gpa: Allocator,
host_allocator: Allocator,
static_account: Store.AccountAllocator,
trusted_context: EvalContext,
fallback_stdout: std.Io.File.Writer,
io: std.Io,
stdin_reader: ?*std.Io.Reader = null,
stdout: ?*std.Io.Writer = null,

asts: List(*Ast),
/// Bound Code is arena-owned and can be inspected for the Runtime lifetime.
/// Every lowered owner retains its Value literals and Reader source data.
compiled_codes: List(*const Code.Code),

store: *Store,
/// Registered Runtime-held graph roots. The Store calls this only while
/// collection owns the scheduler mutex and the host has stopped its mutators.
gc_roots: Store.RootProvider,
host_root_count: usize,
root_ns: Value,
/// Prelude-only namespace snapshot: the parent of every module namespace,
/// taken right after the prelude eval (before any user code runs). Modules
/// must not see main/importer defs; bindings a module adds locally shadow
/// this snapshot without touching it.
prelude_ns: Value = .nil,
/// Phase D: the module registry (canonical path → entry). Guarded by the
/// scheduler mutex; entries are arena-owned and never freed.
modules: mod_reg.ModuleRegistry = .{},
symbolic_state: ?Symbolic.State = null,
linearization_state: Linearize.State,
ad_cache: AdCache,
tree_registry: skript.autodiff_tree.RegistryOwner,
space_registry: skript.autodiff_space.RegistryOwner,
ad_rules: ?skript.autodiff_rules.RegistryOwner,
intrinsics: Intrinsics,
constants: std.StaticStringMap(Value),
predefined_types: List(*const Type),
symbol_pool: List(SymbolEntry),
symbol_indices: std.AutoHashMapUnmanaged(Sym, u16),
symbol_pool_mutex: std.Io.Mutex = .init,
/// Linked FFI call plans are released before Store-owned function nodes.
ffi_plan_head: ?*anyopaque = null,
ffi_plan_mutex: std.Io.Mutex = .init,
/// Runtime-owned dynamic libraries are released after the runners drain.
dynlib_head: ?*anyopaque = null,
dynlib_list_mutex: std.Io.Mutex = .init,
/// Phase B: the cooperative process scheduler (ready queue, pid counter).
/// Host-only state: the runner drains it, but only after the host enqueues
/// and while the host is parked in await.
scheduler: sched_mod.Scheduler,
/// Register-VM optimization switches. All are enabled by default.
/// `--no-bytecode-opts` sets `global = false` to disable every optimization.
compiler_opts: CompilerOpts = .{},
/// Recursion depth guard for the tree-walking evaluator/compilers: deeply
/// nested input must error, not overflow the call stack (zbc
/// recursive-parse class; parsers guard at max_parse_depth).
source_retention: SourceUnit.Retention,
next_code_id: u32 = 1,
next_code_revision: u64 = 1,
dependency_cells: std.AutoHashMapUnmanaged(DependencyKey, DependencyCell) = .empty,
next_dependency_id: u64 = 1,
next_evaluation_id: u64 = 1,
const max_recursion_depth: u32 = 1024;
/// Logical VM depth is separately checked by EvalContext. A trusted host has
/// no depth ledger, so also cap recursive inline fibers on the native stack
/// (including the 1 MiB Wasm stack); VM tail calls do not enter this path.
const max_inline_eval_depth: u8 = 16;
threadlocal var inline_eval_depth: u8 = 0;

/// A nested VM invocation temporarily owns errors from its native callbacks.
const ActiveFiber = struct {
    runtime: *Runtime,
    fiber: *Fiber,
};
threadlocal var active_fiber: ?ActiveFiber = null;

const SymbolEntry = struct {
    symbol: Sym,
    window_safe: bool,
    /// `splitQualified` would return a split for this name. Cached at intern
    /// time so a VM symbol read skips the per-lookup `/` scan.
    may_split: bool,
};

/// Host-owned Values held across collections must be registered in stable
/// storage. Do not move this struct until unregisterValueRoot returns.
pub const ValueRoot = struct {
    value: Value = .nil,
    provider: Store.RootProvider = .{
        .context = undefined,
        .trace = trace,
    },

    fn trace(root_context: *anyopaque, visitor: *Store.MarkVisitor) anyerror!void {
        const root: *ValueRoot = @ptrCast(@alignCast(root_context));
        try visitor.visitValue(root.value);
    }
};

/// The host must stop its own Store mutators before registering a Value.
/// A raw returned Value remains a borrow until it is registered.
pub fn registerValueRoot(self: *Runtime, root: *ValueRoot, value: Value) !void {
    if (root.provider.store != null) return error.AlreadyRegistered;
    root.provider.context = root;
    root.value = value;
    try self.store.registerRootProvider(&root.provider);
    self.host_root_count += 1;
}

pub fn unregisterValueRoot(self: *Runtime, root: *ValueRoot) !void {
    try self.store.unregisterRootProvider(&root.provider);
    std.debug.assert(self.host_root_count > 0);
    self.host_root_count -= 1;
    root.value = .nil;
}

/// Return the Runtime-wide symbol index. Repeated compilations reuse the same
/// slot rather than exhausting the VM's u16 operand for identical names.
pub fn pushSymbol(self: *Runtime, sym: Sym) !u16 {
    self.symbol_pool_mutex.lockUncancelable(self.io);
    defer self.symbol_pool_mutex.unlock(self.io);
    if (self.symbol_indices.get(sym)) |index| return index;
    const idx = self.symbol_pool.items.len;
    if (idx > std.math.maxInt(u16)) return error.LimitExceeded;
    const text = sym.*;
    // An @-name never splits; all other slash-bearing names leave the window.
    const window_safe = text.len == 0 or text[0] == '@' or
        std.mem.findScalar(u8, text, '/') == null;
    // `splitQualified` accepts exactly one interior slash. Record the answer so
    // the VM symbol-read path never rescans the name.
    const may_split = blk: {
        if (text.len == 0 or text[0] == '@') break :blk false;
        const first_slash = std.mem.findScalar(u8, text, '/') orelse break :blk false;
        if (first_slash == 0 or first_slash == text.len - 1) break :blk false;
        break :blk std.mem.findScalar(u8, text[first_slash + 1 ..], '/') == null;
    };
    try self.symbol_pool.append(self.static, .{
        .symbol = sym,
        .window_safe = window_safe,
        .may_split = may_split,
    });
    errdefer self.symbol_pool.items.len -= 1;
    try self.symbol_indices.put(self.static, sym, @intCast(idx));
    return @intCast(idx);
}

/// Allocate a unique Runtime-owned identity for immutable semantic Code.
pub fn allocCodeIdentity(self: *Runtime) Error!CodeIdentity {
    if (self.next_code_id == std.math.maxInt(u32)) return error.Unsupported;
    if (self.next_code_revision == std.math.maxInt(u64)) return error.Unsupported;
    const identity: CodeIdentity = .{
        .id = self.next_code_id,
        .revision = self.next_code_revision,
    };
    self.next_code_id += 1;
    self.next_code_revision += 1;
    return identity;
}

pub fn allocEvaluationIdentity(self: *Runtime) error{Unsupported}!u64 {
    if (self.next_evaluation_id == std.math.maxInt(u64)) return error.Unsupported;
    const identity = self.next_evaluation_id;
    self.next_evaluation_id += 1;
    return identity;
}

pub fn ownNamespace(self: *Runtime, namespace: Value) void {
    std.debug.assert(namespace.typ == b.type_namespace);
    namespace.obj.toRef().deref(Namespace).owner_context_id = self.context().identity;
}

/// Initialize a Runtime: create store, register builtins and intrinsics,
/// load the prelude through the register VM. Fails if prelude parsing or memory
/// allocation fails.
pub fn init(gpa: Allocator, io: std.Io) !*Runtime {
    return initInternal(gpa, io, .{});
}

/// Like `init` but with a caller-specified Store configuration — used by
/// hosts on targets without mmap (e.g. the web build) to allocate a larger
/// max store heap than the test default.
pub fn initWithConfig(gpa: Allocator, io: std.Io, store_cfg: skript.Store.Config) !*Runtime {
    return initInternal(gpa, io, store_cfg);
}

fn initInternal(gpa: Allocator, io: std.Io, store_cfg: skript.Store.Config) !*Runtime {
    const this = try gpa.create(Runtime);
    errdefer gpa.destroy(this);
    this.store = try Store.init(gpa, io, store_cfg);
    errdefer this.store.deinit();
    this.gc_roots = .{ .context = this, .trace = StoreGcRoots.traceRuntimeRoots };
    this.host_root_count = 0;
    this.gpa = this.store.accountedAllocator();
    this.linearization_state = .init(this.gpa);
    errdefer this.linearization_state.deinit();
    this.tree_registry = try skript.autodiff_tree.RegistryOwner.init(this.gpa);
    errdefer this.tree_registry.deinit();
    this.space_registry = try skript.autodiff_space.RegistryOwner.init(this.gpa);
    errdefer this.space_registry.deinit();
    this.host_allocator = gpa;
    this.io = io;
    this.static_arena = .init(this.store.backingAllocator());
    errdefer this.static_arena.deinit();
    this.static_account = .init(this.store, this.static_arena.allocator(), .code, .values);
    this.static = this.static_account.allocator();
    this.symbolic_state = try Symbolic.State.init(this);
    errdefer if (this.symbolic_state) |*state| state.deinit();
    this.asts = .empty;
    this.compiled_codes = .empty;
    this.prelude_ns = .nil;

    this.next_code_id = 1;
    this.next_code_revision = 1;
    this.dependency_cells = .empty;
    this.next_dependency_id = 1;
    this.next_evaluation_id = 1;
    this.source_retention = .full;
    // stdio writers must be nulled explicitly (hosts assign them after init;
    // a garbage rt.stdout made printf/display pick a dangling writer in tests).
    this.stdin_reader = null;
    this.stdout = null;
    this.fallback_stdout = std.Io.File.stdout().writer(io, &.{});
    this.scheduler = sched_mod.Scheduler.init(this.gpa);
    errdefer this.scheduler.deinit();
    this.modules = .{};
    this.ad_cache = .{};
    this.ad_rules = null;
    this.ffi_plan_head = null;
    this.ffi_plan_mutex = .init;
    this.dynlib_head = null;
    this.dynlib_list_mutex = .init;
    errdefer if (comptime intrin.ffi_enabled) intrin.ffi.deinitRuntimePlans(this);
    // gpa.create does not zero and does not apply field defaults; compiler_opts
    // must be set explicitly (default .{} = every optimization on).
    this.compiler_opts = .{};
    this.predefined_types = .empty;
    try this.predefined_types.resize(this.static, b.type_last_idx + 1);

    const types = try b.initBuiltinTypes(this.store);
    for (types, 0..) |ptr, idx| {
        this.predefined_types.items[idx] = ptr;
    }

    const root_ns_ref = try this.store.create(Namespace);
    const root_ns_obj = root_ns_ref.toObject();
    this.store.store(Namespace, root_ns_ref.deref(Namespace), HashMapNamespace.vtable);
    const hashmap = try this.static.create(HashMapNamespace);
    root_ns_ref.deref(Namespace).data = @ptrCast(hashmap);
    hashmap.* = try HashMapNamespace.init(this.static, .nil);
    // hashmap.* = .namespace(root_ns_obj);
    this.root_ns = .namespace(root_ns_obj);
    // Constructor names are permanent root bindings. The prelude must not
    // redefine them, and every namespace write path rejects later changes.
    try hashmap.bind(try this.store.getsym("f64"), Value.typeValue(b.type_f64));
    try hashmap.bind(try this.store.getsym("i64"), Value.typeValue(b.type_i64));

    this.symbol_pool = .empty;
    this.symbol_indices = .empty;
    this.symbol_pool_mutex = .init;

    this.intrinsics = try Intrinsics.init(this.static);
    this.trusted_context = EvalContext.trusted(this.gpa, this, this.intrinsics.registryVersion(), .{
        .writer = &this.fallback_stdout.interface,
    });
    this.constants = try std.StaticStringMap(Value).init([_]struct { []const u8, Value }{
        .{ "nil", Value.nil },
        .{ "true", .bool(true) },
        .{ "false", .bool(false) },
        .{ "Type", .typeValue(b.type_type) },
        .{ "Error", .typeValue(b.type_error) },
        .{ "Bool", .typeValue(b.type_bool) },
        .{ "f8", .typeValue(b.type_f8) },
        .{ "f16", .typeValue(b.type_f16) },
        .{ "f32", .typeValue(b.type_f32) },
        .{ "f64", .typeValue(b.type_f64) },
        .{ "i8", .typeValue(b.type_i8) },
        .{ "i16", .typeValue(b.type_i16) },
        .{ "i32", .typeValue(b.type_i32) },
        .{ "i64", .typeValue(b.type_i64) },
        .{ "u8", .typeValue(b.type_u8) },
        .{ "u16", .typeValue(b.type_u16) },
        .{ "u32", .typeValue(b.type_u32) },
        .{ "u64", .typeValue(b.type_u64) },
        .{ "pid", .typeValue(b.type_pid) },
        .{ "c8", .typeValue(b.type_c8) },
        .{ "c16", .typeValue(b.type_c16) },
        .{ "c32", .typeValue(b.type_c32) },
        .{ "c64", .typeValue(b.type_c64) },
        .{ "Symbol", .typeValue(b.type_symbol) },
        .{ "String", .typeValue(b.type_string) },
        .{ "Opaque", .typeValue(b.type_opaque) },
        .{ "Nil", .typeValue(b.type_nil) },
        .{ "Keyword", .typeValue(b.type_keyword) },
        .{ "Tensor", .typeValue(b.type_tensor) },
        .{ "ByteVector", .typeValue(b.type_bytevector) },
        .{ "ffi:enabled?", if (intrin.ffi_enabled) .true else .false },
        .{ "dynamic-library:enabled?", if (intrin.dynlib_enabled) .true else .false },
        .{ "c:void", .typeValue(b.type_cvoid) },
        .{ "c:string", .typeValue(b.type_cstring) },
        .{ "c:int", .typeValue(b.type_cint) },
        .{ "c:uint", .typeValue(b.type_cuint) },
        .{ "c:float", .typeValue(b.type_cfloat) },
        .{ "c:double", .typeValue(b.type_cdouble) },
        .{ "c:bool", .typeValue(b.type_cbool) },
        .{ "f16.pi", .f16(std.math.pi) },
        .{ "f16.tau", .f16(std.math.tau) },
        .{ "f16.pi/2", .f16(std.math.pi / 2.0) },
        .{ "f32.pi", .f32(std.math.pi) },
        .{ "f32.tau", .f32(std.math.tau) },
        .{ "f32.pi/2", .f32(std.math.pi / 2.0) },
        .{ "f64.pi", .f64(std.math.pi) },
        .{ "f64.tau", .f64(std.math.tau) },
        .{ "f64.pi/2", .f64(std.math.pi / 2.0) },
    }, this.static);

    const prelude_unit = try skript.Reader.readUnit(
        this.store,
        prelude,
        .{ .retention = this.source_retention, .file = "prelude.pt" },
    );
    const forms = prelude_unit.datum;
    // Compile the prelude (read as DATA by the Reader) to register bytecode
    // and run it on a fresh Fiber. The stack buffer lives in the runtime arena;
    // evalReg grows it on demand.
    const prog = try this.compileData(this.root_ns, forms, null);
    const stack = try this.static.alloc(Object, frame_size + @as(usize, prog.nregs) * 2);
    @memset(stack, .null);
    var fib: Fiber = .{
        .stack = stack,
        .sp = frame_size + @as(usize, prog.nregs) * 2,
        .ip = prog.ir.ptr,
        .ir = prog.ir,
        .nregs = prog.nregs,
        .consts = prog.constants,
        .fns = prog.fns,
        .ns = this.root_ns,
    };
    _ = try this.runToCompletion(this.root_ns, &fib);

    // Snapshot the prelude bindings into a fresh namespace with no parent:
    // the parent of every module namespace (clean isolation — modules never
    // see main/importer defs, which land in root_ns AFTER this point). The
    // snapshot is taken once, here, before any user code runs; a module that
    // redefines a prelude name shadows the snapshot locally without touching
    // it.
    {
        const prelude_ns_ref = try this.store.create(Namespace);
        const prelude_ns_obj = prelude_ns_ref.toObject();
        this.store.store(Namespace, prelude_ns_ref.deref(Namespace), HashMapNamespace.vtable);
        const prelude_map = try this.static.create(HashMapNamespace);
        prelude_ns_ref.deref(Namespace).data = @ptrCast(prelude_map);
        prelude_map.* = try HashMapNamespace.init(this.static, .nil);
        const root_ns_ptr = this.root_ns.obj.toRef().deref(Namespace);
        const root_map: *HashMapNamespace = @ptrCast(@alignCast(root_ns_ptr.data));
        var it = root_map.bindings.iterator();
        while (it.next()) |kv| {
            try prelude_map.bindings.put(kv.key_ptr.*, kv.value_ptr.*);
        }
        this.prelude_ns = .namespace(prelude_ns_obj);
    }
    this.store.registerRootProvider(&this.gc_roots) catch unreachable;

    return this;
}

/// Free all runtime resources: ASTs, store, arena. Invalidates everything
/// created from this runtime.
pub fn deinit(self: *Runtime) void {
    std.debug.assert(self.host_root_count == 0);
    for (self.asts.items) |ast| {
        ast.destroy();
    }
    // Stop the runners BEFORE freeing anything: mark shutdown, wake the
    // parked ones, and await each dispatched runner. A runner exits at its
    // next loop top or idle wake; the await returns only after that, so no
    // worker touches the arena/store memory freed below.
    self.scheduler.shutdown.store(true, .release);
    self.scheduler.event.set(self.io);
    for (self.scheduler.runners.items) |*f| {
        // A runner's error is its TARGET's eval error, already surfaced to
        // the awaiter through awaitProcess/pollProcess — log at debug, not
        // err (the crash tests would otherwise flag expected crashes).
        _ = f.await(self.io) catch |err| blk: {
            std.log.scoped(.scheduler).debug("runner drain: {s}", .{@errorName(err)});
            break :blk skript.Value.nil;
        };
    }
    // self.store.get(self.root_ns.obj, HashMapNamespace).deinit(self.gpa);
    // A process may be cancelled or never dispatched before teardown. Once
    // runners have drained, every remaining fiber can be retired directly.
    for (self.scheduler.processes.items) |process| {
        self.releaseFiberGuards(&process.fib);
    }
    if (comptime intrin.ffi_enabled) intrin.ffi.deinitRuntimePlans(self);
    if (comptime intrin.dynlib_enabled) intrin.dynlib.deinitRuntimeLibraries(self);
    self.scheduler.deinit();
    self.ad_cache.deinit(self.gpa);
    if (self.ad_rules) |*rules| rules.deinit();
    self.dependency_cells.deinit(self.static);
    self.space_registry.deinit();
    self.tree_registry.deinit();
    if (self.symbolic_state) |*state| state.deinit();
    self.linearization_state.deinit();
    self.store.unregisterRootProvider(&self.gc_roots) catch unreachable;
    self.static_arena.deinit();
    self.store.deinit();
    const gpa = self.host_allocator;
    defer gpa.destroy(self);
    self.* = undefined;
}

/// Collect at the host's stopped-mutator safepoint.
pub const collect = StoreGcRoots.collect;

/// Parse `src` into an AST. Source is copied into the arena. The returned
/// node ref is valid until deinit. `toplevel = .File` for multi-form input,
/// `.Expression` for a single form.
pub fn read(self: *Runtime, src: []const u8, toplevel: skript.Ast.Node.Tag) Error!AstNodeRef {
    const owned_src = try self.static.dupe(u8, src);
    const ast = try Ast.create(self.static, owned_src, toplevel);
    try self.asts.append(self.static, ast);
    return ast.root_node;
}

/// One entry of the shared per-program function table. The canonical shape
/// lives in RegLower; this alias keeps the VM and Fiber APIs stable.
pub const FnTableEntry = RegLower.FnTableEntry;

/// Catch-state frame pushed by `.try`. The unwind restores the complete
/// execution context, including source and instruction bounds.
const ExnFrame = struct {
    sp: usize,
    fp: usize,
    ap: usize,
    ns: Value,
    consts: []const Value,
    fns: []const FnTableEntry,
    current_closure: ?*Closure,
    active_guard: ?*const skript.data.ClosureGuard,
    ir: []const regvm.Inst,
    nregs: u8,
    src_idx: u32,
    call_depth: u32,
    handler_ip: [*]const regvm.Inst,
    exn_rd: u8,
};
/// Register-VM optimization switches. `global` disables all optional
/// lowering optimizations when false. The remaining fields are retained as
/// stable host configuration; RegLower consumes the fields it implements.
pub const CompilerOpts = struct {
    global: bool = true,
    arith_fast_path: bool = true,
    speculative_arith: bool = true,
    case_eq_specialize: bool = true,
    type_joins: bool = true,
    type_narrowing: bool = true,
    let_binding_types: bool = true,
    small_immediates: bool = true,
    constant_seeding: bool = true,
    copy_propagation: bool = true,
    self_call: bool = true,
    self_call_zero_mask: bool = true,
    /// Layout of the cold arithmetic operand sequence in lowered code.
    cold_arithmetic_fallbacks: bool = true,
    /// Bounded per-namespace cell memo consulted by the register-VM symbol
    /// read. Pure lookup acceleration: no opcode, no lowering, and no change
    /// to what a read resolves, only to how the owning cell is found.
    namespace_lookup_cache: bool = true,
    /// Route same-function immutable `let` and definition bindings to the
    /// register that already holds the value. False restores the namespace
    /// read; `--no-bytecode-opts` turns it off.
    let_binding_registers: bool = true,

    pub fn allOff() CompilerOpts {
        return .{
            .global = false,
            .arith_fast_path = false,
            .speculative_arith = false,
            .case_eq_specialize = false,
            .type_joins = false,
            .type_narrowing = false,
            .let_binding_types = false,
            .small_immediates = false,
            .constant_seeding = false,
            .copy_propagation = false,
            .self_call = false,
            .self_call_zero_mask = false,
            .cold_arithmetic_fallbacks = false,
            .namespace_lookup_cache = false,
            .let_binding_registers = false,
        };
    }

    pub fn effective(self: CompilerOpts) CompilerOpts {
        return if (self.global) self else allOff();
    }
};

/// Result of direct lowering of one immutable Code owner.
pub const RegProgram = RegLower.RegProgram;

pub fn compileData(self: *Runtime, ns: Value, forms: Value, module_path: ?[]const u8) Error!RegProgram {
    const scope = self.context().activate();
    defer scope.deinit();
    var scratch_arena = Arena.init(self.gpa);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();
    const code = try Bind.bind(scratch, self, ns, forms, module_path);
    return self.lowerCode(scratch, code);
}

/// Lower Runtime-owned semantic code through the same path as source programs.
pub fn lowerCode(self: *Runtime, scratch: Allocator, code: *const Code.Code) Error!RegProgram {
    const scope = self.context().activate();
    defer scope.deinit();
    if (code.owner != @as(?*const anyopaque, self)) return error.InvalidCode;
    const options = self.compiler_opts.effective();
    const resolve: RegLower.ResolveContext = .{
        .userdata = self,
        .context = self.context(),
        .symbolIndex = struct {
            fn call(ptr: *anyopaque, symbol: Code.Symbol) anyerror!u16 {
                return @as(*Runtime, @ptrCast(@alignCast(ptr))).pushSymbol(symbol);
            }
        }.call,
        .primitive = struct {
            fn call(ptr: *anyopaque, primitive: PrimitiveId) ?RegLower.PrimitiveTarget {
                const rt: *Runtime = @ptrCast(@alignCast(ptr));
                const spec = rt.intrinsics.registry.current().spec(primitive) orelse return null;
                const value = switch (spec.invoke) {
                    .native => |native| Value.intrinsic(native),
                    .closure => |closure| closure,
                };
                const index = if (rt.intrinsics.indexForPrimitiveId(primitive)) |intrinsic|
                    @intFromEnum(intrinsic)
                else
                    std.math.maxInt(u16);
                return .{ .value = value, .index = if (index == std.math.maxInt(u16)) null else index };
            }
        }.call,
    };
    const program = RegLower.lower(self.static, scratch, code, resolve, .{
        .small_immediates = options.small_immediates,
        .constant_seeding = options.constant_seeding,
        .arith_fast_path = options.arith_fast_path,
        .speculative_arith = options.speculative_arith,
        .cold_arithmetic_fallbacks = options.cold_arithmetic_fallbacks,
        .copy_propagation = options.copy_propagation,
        .self_call = options.self_call,
        .self_call_zero_mask = options.self_call_zero_mask,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Exhausted => return error.Exhausted,
        error.InvalidCode => return error.InvalidCode,
        error.RegisterOverflow, error.Unsupported => return error.Unsupported,
    };
    try self.compiled_codes.append(self.static, code);
    return program;
}

/// Locate a reader node by DFS preorder index.
pub const dfsNodeAt = SourceInspection.dfsNodeAt;
/// Locate the source span of a reader node.
pub const dfsNodeLocation = SourceInspection.dfsNodeLocation;
/// Export the defining source text of a closure.
pub const inspectSourceText = SourceInspection.inspectSourceText;
/// Export a detached copy of a closure's defining datum.
pub const inspectSourceDatum = SourceInspection.inspectSourceDatum;
/// Export a bounded semantic-code view of a closure.
pub const inspectBoundCode = SourceInspection.inspectBoundCode;

/// this uses the predefined_types array. For user-defined types, it derefs the heap Ref.
pub inline fn typePtrFromObj(self: *Runtime, obj: Object) *const skript.data.Type {
    const idx = @intFromEnum(obj);
    return if (idx <= b.type_last_idx)
        self.predefined_types.items[@as(usize, @intCast(idx))]
    else
        obj.toRef().deref(skript.data.Type);
}

/// Why evalReg returned before `.stop`: the scheduler resumes by calling
/// evalReg again with the same fiber (the continuation is fully in
/// Fiber). An error return of evalReg itself is a crash, not a
/// suspension — the fiber is not resumable from that state.
pub const EvalStatus = union(enum) {
    done, // .stop executed; result in fib.getReg(0)
    yielded, // budget exhausted — re-dispatch
    suspended: Suspension,
};

pub const Suspension = enum { waiting_io };

/// Return the VM fiber executing on this thread for this runtime, if any.
pub fn activeFiber(self: *Runtime) ?*Fiber {
    const active = active_fiber orelse return null;
    return if (active.runtime == self) active.fiber else null;
}

/// Register-mode bytecode evaluator. Runs the dispatch loop until `.stop`
/// (`.done`), the instruction budget is exhausted (`.yielded` — the caller
/// resumes by calling evalReg again with the same fiber), a blocking
/// intrinsic signals `error.WouldBlock` (`.suspended`), or an error occurs.
/// `budget` counts dispatched instructions; pass `std.math.maxInt(u32)` to
/// disable yielding.
///
/// Errors-as-values (design directive 1): evalReg itself does NOT propagate
/// skript-level Zig errors — it converts them to error VALUES. The dispatch
/// loop (`evalRegDispatch`) surfaces the Zig error; this wrapper:
///   - re-propagates error.WouldBlock (suspension), error.Exit (terminal),
///     and error.OutOfMemory (cannot build a value);
///   - with an active .try (fib.exn_stack non-empty), pops the top
///     catch-state frame, restores the .try-time fiber state, delivers the
///     payload to R[exn_rd] (the raised value for error.Raised, a rich error
///     VALUE with source location otherwise), and re-dispatches at the
///     handler;
///   - otherwise completes the process: r0 = the error VALUE (with the
///     failing node's source location) and `.done` — the scheduler publishes
///     it and the host's pollProcess unwraps the anyerror payload, so host
pub fn evalReg(self: *Runtime, start_ns: Value, fib: *Fiber, budget: u32) Error!EvalStatus {
    var current = self.context().*;
    current.vm_depth = &fib.call_depth;
    const ctx = &current;
    const scope = ctx.activate();
    defer scope.deinit();
    const previous_fiber = active_fiber;
    active_fiber = .{ .runtime = self, .fiber = fib };
    defer active_fiber = previous_fiber;
    errdefer |failure| {
        // A blocking result is resumable and must retain its lease. Every
        // other error terminates this fiber and retires its active leases.
        if (failure != error.WouldBlock) self.releaseFiberGuards(fib);
    }
    try ctx.check();
    try checkVmDepth(ctx, fib, 0);
    var budget_left = budget;
    while (true) {
        const status = self.evalRegDispatch(start_ns, fib, budget_left) catch |err| {
            try ctx.check();
            // Suspension/termination/allocation failure are not error values.
            if (err == error.WouldBlock or err == error.Exit or err == error.OutOfMemory or err == error.Exhausted) {
                // Zig 0.16 needs an explicit union for captured errdefer returns.
                return @as(Error!EvalStatus, err);
            }
            // A callback can return a rich error from a nested VM fiber.
            // Preserve that error rather than attributing it to this caller.
            const inherited: ?Value = if (fib.pending_error.typ == b.type_error and
                fib.pending_error.errorCode() == err)
                fib.pending_error
            else
                null;
            fib.pending_error = .nil;
            fib.clearPendingApply();
            // An active .try: unwind to its handler.
            if (fib.exn_stack.pop()) |frame| {
                const payload: Value = if (err == error.Raised)
                    fib.raised
                else
                    inherited orelse self.errorValue(err, fib);
                try ctx.check();
                self.releaseFramesUntil(fib, frame.fp);
                fib.sp = frame.sp;
                fib.fp = frame.fp;
                fib.ap = frame.ap;
                fib.ns = frame.ns;
                fib.consts = frame.consts;
                fib.fns = frame.fns;
                fib.current_closure = frame.current_closure;
                fib.active_guard = frame.active_guard;
                fib.ir = frame.ir;
                fib.nregs = frame.nregs;
                fib.src_idx = frame.src_idx;
                fib.call_depth = frame.call_depth;
                fib.setReg(frame.exn_rd, payload);
                fib.raised = .nil;
                fib.ip = frame.handler_ip;
                // The error path consumed an untracked slice of the quantum;
                // charge each caught error one budget unit so a tight
                // raise/catch loop still yields.
                if (budget_left == 0) return .yielded;
                budget_left -= 1;
                continue;
            }
            // Uncaught: the process completes with the error VALUE in r0
            // (the .done reader materializes it; the runner publishes it).
            // fib.raised is left intact — the runner copies it to
            // Process.raised (the uncaught (raise X) payload).
            const payload = inherited orelse self.errorValue(err, fib);
            try ctx.check();
            fib.setReg(0, payload);
            self.releaseFiberGuards(fib);
            return .done;
        };
        try ctx.check();
        return status;
    }
}

fn checkVmDepth(ctx: *const EvalContext, fib: *const Fiber, additional: u32) Error!void {
    const ledger = ctx.budget() orelse return;
    const depth: u64 = @as(u64, ctx.depth) + fib.call_depth + additional;
    if (depth > std.math.maxInt(u32)) return ledger.overflow(.depth, .regvm);
    try ledger.checkDepth(@intCast(depth), .regvm);
}

fn validRegisterMask(nregs: u8) u256 {
    return regvm.registerRangeMask(0, nregs) orelse 0;
}

fn validateInstructionPointer(fib: *const Fiber, inst: regvm.Inst) Error!void {
    const ir = fib.activeIr();
    if (ir.len == 0) return;
    const base = @intFromPtr(ir.ptr);
    const ip = @intFromPtr(fib.ip);
    const bytes = std.math.mul(usize, ir.len, @sizeOf(regvm.Inst)) catch return error.InvalidCode;
    const end = std.math.add(usize, base, bytes) catch return error.InvalidCode;
    if (ip < base or ip >= end or (ip - base) % @sizeOf(regvm.Inst) != 0) {
        return error.InvalidCode;
    }
    const index = (ip - base) / @sizeOf(regvm.Inst);
    const size: usize = regvm.instructionSize(inst.opcode);
    if (inst.opcode == .call_builtin_ext) {
        _ = try regvm.decodeBuiltin(ir, index);
    }
    if (size > ir.len - index) return error.InvalidCode;
}

fn hasVerifiedProgram(fib: *const Fiber) bool {
    const index = if (fib.current_closure) |closure| @intFromEnum(closure.function_id) else 0;
    if (index >= fib.fns.len) return false;
    const entry = &fib.fns[index];
    return entry.verified and entry.ir.ptr == fib.ir.ptr and entry.ir.len == fib.ir.len and entry.nregs == fib.nregs;
}

fn validateInstruction(fib: *const Fiber, inst: regvm.Inst) Error!void {
    try validateInstructionPointer(fib, inst);
    const ir = fib.activeIr();
    const single = [1]regvm.Inst{inst};
    const code = if (ir.len == 0) single[0..] else ir;
    const index = if (ir.len == 0) 0 else (@intFromPtr(fib.ip) - @intFromPtr(ir.ptr)) / @sizeOf(regvm.Inst);
    const access = regvm.registerAccessAt(code, index);
    if (!access.valid) return error.InvalidCode;
    const mask = validRegisterMask(fib.activeNregs());
    if (((access.reads | access.writes | access.exceptional_writes) & ~mask) != 0) {
        return error.InvalidCode;
    }
}

fn jumpRelative(fib: *Fiber, offset: i64) Error!void {
    const ir = fib.activeIr();
    if (ir.len == 0) {
        const base = @intFromPtr(fib.ip);
        const delta = offset * @as(i64, @intCast(@sizeOf(regvm.Inst)));
        if (delta < 0) {
            const magnitude: usize = @intCast(-delta);
            fib.ip = @ptrFromInt(base -| magnitude);
        } else {
            fib.ip = @ptrFromInt(base +| @as(usize, @intCast(delta)));
        }
        return;
    }
    const base = @intFromPtr(ir.ptr);
    const ip = @intFromPtr(fib.ip);
    if (ip < base or (ip - base) % @sizeOf(regvm.Inst) != 0) return error.InvalidCode;
    const next: i64 = @intCast((ip - base) / @sizeOf(regvm.Inst));
    const target = next + offset;
    if (target < 0 or target >= @as(i64, @intCast(ir.len))) return error.InvalidCode;
    fib.ip = ir.ptr + @as(usize, @intCast(target));
}

fn instructionStart(ir: []const regvm.Inst, target: usize) bool {
    var index: usize = 0;
    while (index < target) {
        const size = regvm.instructionSize(ir[index].opcode);
        if (size > ir.len - index) return false;
        if (ir[index].opcode == .call_builtin_ext) {
            _ = regvm.decodeBuiltin(ir, index) catch return false;
        }
        index += size;
    }
    return index == target;
}

fn validateInstructionAddress(fib: *const Fiber) Error!void {
    const ir = fib.activeIr();
    if (ir.len == 0) return;
    const base = @intFromPtr(ir.ptr);
    const ip = @intFromPtr(fib.ip);
    const bytes = std.math.mul(usize, ir.len, @sizeOf(regvm.Inst)) catch return error.InvalidCode;
    const end = std.math.add(usize, base, bytes) catch return error.InvalidCode;
    if (ip < base or ip >= end or (ip - base) % @sizeOf(regvm.Inst) != 0) {
        return error.InvalidCode;
    }
    if (!hasVerifiedProgram(fib) and
        !instructionStart(ir, (ip - base) / @sizeOf(regvm.Inst))) return error.InvalidCode;
}

fn returnFrame(self: *Runtime, fib: *Fiber, source: u8, count: u8) Error!void {
    if (count == 0) return error.InvalidCode;
    const source_mask = regvm.registerRangeMask(source, count) orelse return error.InvalidCode;
    const active_mask = validRegisterMask(fib.activeNregs());
    if ((source_mask & ~active_mask) != 0) return error.InvalidCode;
    const old_fp = fib.fp;
    const frame_end = std.math.add(usize, fib.fp, frame_size) catch return error.InvalidCode;
    if (frame_end > fib.stack.len) return error.InvalidCode;
    const frame_ptr: *const FrameReg = @ptrCast(fib.stack[fib.fp..].ptr);
    const frame = frame_ptr.*;
    if (frame.result_count != count or frame.ret_addr == null) return error.InvalidCode;
    if (frame.prev_sp > fib.stack.len or frame.prev_fp > frame.prev_sp) return error.InvalidCode;
    if (frame.guard) |guard| try validateClosureGuard(guard);
    if (fib.active_guard != frame.guard) return error.InvalidCode;

    const destination_mask = regvm.registerRangeMask(frame.ret_reg, count) orelse
        return error.InvalidCode;

    var values: [256]Value = undefined;
    for (0..count) |offset| {
        values[offset] = fib.getReg(@intCast(@as(usize, source) + offset));
    }

    // All fields and return values are copied before release. A guard may
    // reclaim residual storage, so no active frame data is read afterward.
    if (frame.guard) |guard| self.releaseClosureGuard(guard);
    fib.active_guard = frame.prev_guard;
    fib.sp = frame.prev_sp;
    fib.ap = frame.prev_ap;
    fib.fp = frame.prev_fp;
    fib.ip = frame.ret_addr.?;
    fib.consts = frame.consts;
    fib.ns = frame.ns;
    fib.fns = frame.prev_fns;
    fib.current_closure = frame.prev_closure;
    fib.ir = frame.prev_ir;
    fib.nregs = frame.prev_nregs;
    fib.src_idx = frame.prev_src_idx;
    fib.call_depth -|= 1;
    while (fib.exn_stack.items.len > 0 and
        fib.exn_stack.items[fib.exn_stack.items.len - 1].fp == old_fp)
    {
        _ = fib.exn_stack.pop();
    }
    if ((destination_mask & ~validRegisterMask(fib.activeNregs())) != 0) return error.InvalidCode;
    for (0..count) |offset| {
        fib.setReg(@intCast(@as(usize, frame.ret_reg) + offset), values[offset]);
    }
}

const VmCallStatus = enum { entered, completed, suspended };

fn isCanonicalApply(func: Value) bool {
    return func.typ == b.type_intrinsic and func.obj.toPtr(FuncPtr) == &intrin.list.apply;
}

/// Apply's wrapper authorization is checked once, before flattening. The
/// resolved target is then authorized by the normal in-fiber call path.
fn authorizeVmApply(self: *Runtime) Error!void {
    const ctx = self.context();
    try ctx.check();
    if (ctx.isUnrestricted()) return;
    const native: FuncPtr = &intrin.list.apply;
    const id = ctx.registry.idForNative(native) orelse return error.Denied;
    const spec = ctx.registry.spec(id) orelse return error.Denied;
    switch (try ctx.authorize(spec)) {
        .invoke => {},
        .model => return error.Unsupported,
    }
}

fn expandedVmApply(ctx: *EvalContext, args: []const Value) Error!PendingApply {
    var inline_values: [32]Value = undefined;
    var expanded = try intrin.list.expandApplyArguments(ctx, args, &inline_values);
    errdefer expanded.deinit();
    var pending: PendingApply = .{
        .target = expanded.target,
        .count = expanded.values.len,
        .owned = expanded.owned,
        .allocator = expanded.allocator,
    };
    if (expanded.owned.len == 0) {
        @memcpy(pending.inline_values[0..expanded.values.len], expanded.values);
    }
    expanded.owned = &.{};
    return pending;
}

fn dispatchVmCall(
    self: *Runtime,
    start_ns: Value,
    fib: *Fiber,
    ctx: *EvalContext,
    raw_func: Value,
    raw_args: []const Value,
    rd: u8,
    result_count: u8,
    tail: bool,
    op_ip: [*]const regvm.Inst,
    storage: []Value,
    native_object: Value,
    borrowed: bool,
) Error!VmCallStatus {
    var suspended = false;
    defer if (!suspended) fib.clearPendingApply();

    var func = if (fib.pending_apply) |pending| pending.target else raw_func;
    var args: []const Value = if (fib.pending_apply) |*pending| pending.args() else raw_args;
    var object = if (fib.pending_apply != null) func else native_object;
    for (0..max_recursion_depth) |_| {
        if (isCanonicalApply(func)) {
            if (result_count != 1) return error.Unsupported;
            try self.authorizeVmApply();
            const expanded = try expandedVmApply(ctx, args);
            fib.clearPendingApply();
            fib.pending_apply = expanded;
            func = fib.pending_apply.?.target;
            args = (&fib.pending_apply.?).args();
            object = func;
            continue;
        }
        if ((func.typ == b.type_closure or func.typ == b.type_method) and Symbolic.hasExpr(args)) {
            if (result_count != 1) return error.Unsupported;
            // Symbolic callbacks may re-enter and grow the register stack.
            const symbolic_args: []const Value = if (fib.pending_apply == null and borrowed) blk: {
                @memcpy(storage[0..args.len], args);
                break :blk storage[0..args.len];
            } else args;
            fib.setReg(rd, try Symbolic.apply(ctx, start_ns, func, symbolic_args));
            return .completed;
        }
        switch (func.typ) {
            b.type_method => {
                if (result_count != 1) return error.Unsupported;
                try ctx.charge(.{ .work = 1 }, .regvm);
                const method = func.obj.toRef().deref(skript.data.Method);
                func = try method.get(self, args);
                object = func;
            },
            b.type_type => {
                if (result_count != 1) return error.Unsupported;
                try ctx.charge(.{ .work = 1 }, .regvm);
                func = self.typePtrFromObj(func.obj).apply;
                if (func.isNil()) return error.Unimplemented;
                object = func;
            },
            b.type_closure => {
                const closure = func.obj.toRef().deref(Closure);
                try self.checkClosureGuard(closure, args);
                if (result_count != closure.result_count) return error.InvalidCode;
                if (tail) {
                    try self.replaceVmClosure(ctx, fib, closure, args, rd, result_count, storage, borrowed and
                        fib.pending_apply == null);
                } else {
                    try self.enterVmClosure(ctx, fib, closure, args, rd, result_count, storage, borrowed and
                        fib.pending_apply == null);
                }
                return .entered;
            },
            b.type_intrinsic => {
                if (result_count != 1) return error.Unsupported;
                const native = func.obj.toPtr(FuncPtr);
                const value = self.invokeNative(native, fib.ns, object, args) catch |err| switch (err) {
                    error.WouldBlock => {
                        fib.ip = op_ip;
                        suspended = true;
                        return .suspended;
                    },
                    else => return err,
                };
                fib.setReg(rd, value);
                return .completed;
            },
            b.type_ffifunc => {
                if (result_count != 1) return error.Unsupported;
                fib.setReg(rd, try intrin.ffi.invoke(ctx, func, args));
                return .completed;
            },
            b.type_keyword => {
                if (result_count != 1) return error.Unsupported;
                if (args.len != 1) return error.ArityMismatch;
                if (args[0].typ != b.type_namespace) return error.TypeMismatch;
                fib.setReg(rd, try self.nsGet(args[0], func.obj.toPtr(Sym)));
                return .completed;
            },
            else => return error.Unimplemented,
        }
    }
    return error.Unsupported;
}

fn enterVmClosure(
    self: *Runtime,
    ctx: *EvalContext,
    fib: *Fiber,
    closure: *Closure,
    args: []const Value,
    rd: u8,
    result_count: u8,
    storage: []Value,
    borrowed: bool,
) Error!void {
    var call_args = try prepareClosureArgs(ctx, closure, args, storage);
    try checkVmDepth(ctx, fib, 1);
    if (fib.call_depth == std.math.maxInt(u32)) return error.Unsupported;
    const frame_objects = frame_size + @as(usize, closure.nregs) * 2;
    if (fib.sp + frame_objects > fib.stack.len) {
        if (borrowed and call_args.ptr == args.ptr) {
            @memcpy(storage[0..call_args.len], call_args);
            call_args = storage[0..call_args.len];
        }
        const old_len = fib.stack.len;
        var new_len = old_len * 2;
        if (new_len < fib.sp + frame_objects) new_len = fib.sp + frame_objects;
        const grown = try (fib.stack_allocator orelse self.static).realloc(fib.stack, new_len);
        @memset(grown[old_len..], .null);
        fib.stack = grown;
    }
    fib.call_depth += 1;
    const acquired_guard = self.acquireClosureGuard(closure) catch |err| {
        fib.call_depth -= 1;
        return err;
    };
    const frame: FrameReg = .{
        .prev_ap = fib.ap,
        .prev_fp = fib.fp,
        .prev_sp = fib.sp,
        .consts = fib.consts,
        .ns = fib.ns,
        .prev_fns = fib.fns,
        .ret_reg = rd,
        .result_count = result_count,
        .ret_addr = fib.ip,
        .guard = acquired_guard,
        .prev_guard = fib.active_guard,
        .prev_closure = fib.current_closure,
        .prev_nregs = fib.nregs,
        .prev_ir = fib.ir,
        .prev_src_idx = fib.src_idx,
    };
    const frame_ptr: *FrameReg = @ptrCast(&fib.stack[fib.sp]);
    frame_ptr.* = frame;
    fib.active_guard = acquired_guard;
    fib.ap = fib.fp + frame_size + @as(usize, rd) * 2;
    fib.fp = fib.sp;
    fib.sp += frame_objects;
    for (call_args, 0..) |argument, i| {
        fib.setReg(@intCast(1 + i), argument);
    }
    for (closure.captures, 0..) |capture, i| {
        fib.setReg(@intCast(closure.arglist.len + 1 + i), capture);
    }
    fib.setReg(0, .nil);
    for (closure.arglist.len + 1 + closure.captures.len..closure.nregs) |reg| {
        fib.setReg(@intCast(reg), .nil);
    }
    fib.consts = closure.constants;
    fib.ns = closure.parent_ns;
    fib.fns = closure.fns;
    fib.current_closure = closure;
    fib.ir = closure.ir;
    fib.nregs = closure.nregs;
    fib.src_idx = 0;
    fib.ip = closure.ir.ptr;
}

fn replaceVmClosure(
    self: *Runtime,
    ctx: *EvalContext,
    fib: *Fiber,
    closure: *Closure,
    args: []const Value,
    rd: u8,
    result_count: u8,
    storage: []Value,
    borrowed: bool,
) Error!void {
    var call_args = try prepareClosureArgs(ctx, closure, args, storage);
    if (fib.fp > fib.stack.len or frame_size > fib.stack.len - fib.fp) return error.InvalidCode;
    const old_frame_ptr: *const FrameReg = @ptrCast(fib.stack[fib.fp..].ptr);
    if (old_frame_ptr.ret_addr == null) return error.InvalidCode;
    const retired_guard = old_frame_ptr.guard;
    const retired_result_count = old_frame_ptr.result_count;
    const frame_objects = frame_size + @as(usize, closure.nregs) * 2;
    if (fib.fp + frame_objects > fib.stack.len) {
        if (borrowed and call_args.ptr == args.ptr) {
            @memcpy(storage[0..call_args.len], call_args);
            call_args = storage[0..call_args.len];
        }
        const old_len = fib.stack.len;
        var new_len = old_len * 2;
        if (new_len < fib.fp + frame_objects) new_len = fib.fp + frame_objects;
        const grown = try (fib.stack_allocator orelse self.static).realloc(fib.stack, new_len);
        @memset(grown[old_len..], .null);
        fib.stack = grown;
    }
    if (retired_result_count != result_count or fib.active_guard != retired_guard) return error.InvalidCode;
    const acquired_guard = try self.acquireClosureGuard(closure);
    const new_frame_ptr: *FrameReg = @ptrCast(&fib.stack[fib.fp]);
    new_frame_ptr.guard = acquired_guard;
    fib.active_guard = acquired_guard;
    fib.ap = fib.fp + frame_size + @as(usize, rd) * 2;
    fib.sp = fib.fp + frame_objects;
    for (call_args, 0..) |argument, i| {
        fib.setReg(@intCast(1 + i), argument);
    }
    for (closure.captures, 0..) |capture, i| {
        fib.setReg(@intCast(closure.arglist.len + 1 + i), capture);
    }
    fib.setReg(0, .nil);
    for (closure.arglist.len + 1 + closure.captures.len..closure.nregs) |reg| {
        fib.setReg(@intCast(reg), .nil);
    }
    fib.consts = closure.constants;
    fib.ns = closure.parent_ns;
    fib.fns = closure.fns;
    fib.current_closure = closure;
    fib.ir = closure.ir;
    fib.nregs = closure.nregs;
    fib.src_idx = 0;
    fib.ip = closure.ir.ptr;
    if (retired_guard) |guard| self.releaseClosureGuard(guard);
}
/// Build an immutable error snapshot before the VM unwinds its call frames.
/// Source Values in the Store-backed frame slice are traced with the error.
fn errorValue(self: *Runtime, err: Error, fib: *Fiber) Value {
    const src: Value = if (fib.current_closure) |cl| cl.source else .nil;
    const site = self.captureErrorSite(src, fib.src_idx);
    var cursor: ErrorFrameCursor = .{
        .closure = fib.current_closure,
        .src_idx = fib.src_idx,
        .fp = fib.fp,
    };
    var count: usize = 0;
    while (cursor.closure != null) {
        count += 1;
        advanceErrorFrame(fib, &cursor);
    }
    const captured = self.store.allocSlice(skript.data.ErrorFrame, count) catch
        return Value.errWithDetails(self.store, err, site, fib.raised, &.{});
    cursor = .{ .closure = fib.current_closure, .src_idx = fib.src_idx, .fp = fib.fp };
    for (captured.slice) |*item| {
        const closure = cursor.closure.?;
        const name: ?Sym = if (closure.code) |code| blk: {
            const function = code.function(closure.function_id) orelse break :blk null;
            break :blk function.name;
        } else null;
        item.* = .{
            .site = self.captureErrorSite(closure.source, cursor.src_idx),
            .name = name,
        };
        advanceErrorFrame(fib, &cursor);
    }
    return Value.errWithDetails(self.store, err, site, fib.raised, captured.slice);
}

fn captureErrorSite(self: *Runtime, source: Value, idx: u32) skript.data.ErrorSite {
    var site: skript.data.ErrorSite = .{ .source = source, .idx = idx };
    if (!source.isNil()) {
        if (self.dfsNodeLocation(source, idx)) |loc| {
            site.line = loc.line;
            site.col = loc.col;
            if (loc.file) |file| site.file = .string(.fromPtr(file));
        }
    }
    return site;
}

const ErrorFrameCursor = struct {
    closure: ?*Closure,
    src_idx: u32,
    fp: usize,
};

fn advanceErrorFrame(fib: *const Fiber, cursor: *ErrorFrameCursor) void {
    if (cursor.fp > fib.stack.len or fib.stack.len - cursor.fp < frame_size) {
        cursor.closure = null;
        return;
    }
    const frame: *const FrameReg = @ptrCast(@alignCast(fib.stack[cursor.fp..].ptr));
    if (frame.ret_addr == null or frame.prev_fp >= cursor.fp) {
        cursor.closure = null;
        return;
    }
    cursor.closure = frame.prev_closure;
    cursor.src_idx = frame.prev_src_idx;
    cursor.fp = frame.prev_fp;
}

/// Only verified, VM-local instructions may keep the lineage lock. The
/// common unconditional case needs one byte-table probe, not a second switch.
fn canKeepRegvmBudgetLock(
    self: *Runtime,
    ctx: *const EvalContext,
    fib: *const Fiber,
    inst: regvm.Inst,
) bool {
    const always_safe = comptime blk: {
        var entries: [256]bool = @splat(false);
        for ([_]regvm.Opcode{
            .nop,     .start,   .enter,   .src,          .mov_reg,    .mov_i64,  .load,
            .jmp,     .br,      .brn,     .guard_callee, .guard_self, .get_self, .ns_pop,
            .end_try, .add_i64, .sub_i64, .mul_i64,      .eq_i64,     .lt_i64,   .gt_i64,
            .add_f64, .sub_f64, .mul_f64, .eq_f64,       .lt_f64,     .gt_f64,
        }) |op| entries[@intFromEnum(op)] = true;
        break :blk entries;
    };
    if (always_safe[@intFromEnum(inst.opcode)]) return true;
    if (inst.opcode == .lookup or inst.opcode == .lookup_val) {
        if (ctx.reentry != null or fib.ns.typ != b.type_namespace) return false;
        const destination, const sidx = regvm.Formats.rdAndSidx(inst.payload);
        _ = destination;
        if (@as(usize, sidx) >= self.symbol_pool.items.len) return false;
        // Qualified reads can intern sub-symbols; only safe names keep the lock.
        return self.symbol_pool.items[sidx].window_safe;
    }
    if (inst.opcode != .tail_self_call) return false;
    if (ctx.registry.closure_specs.count() != 0) return false;
    const closure = fib.current_closure orelse return false;
    if (closure.guard != null or fib.active_guard != null or closure.result_count != 1) return false;
    const shape = closureCallShape(closure) catch return false;
    const destination, const nargs, const flags = regvm.Formats.rdNargsFlags(inst.payload);
    _ = destination;
    _ = flags;
    if (nargs == 0 or shape.has_rest or shape.fixed_count != @as(usize, nargs - 1)) return false;
    if (fib.fp > fib.stack.len or frame_size > fib.stack.len - fib.fp) return false;
    const old_frame: *const FrameReg = @ptrCast(fib.stack[fib.fp..].ptr);
    if (old_frame.guard != null or old_frame.ret_addr == null) return false;
    const frame_objects = frame_size + @as(usize, closure.nregs) * 2;
    return frame_objects <= fib.stack.len - fib.fp;
}

/// Select metering once per dispatch quantum. The unmetered loop has no
/// budget branch in its per-instruction path.
fn evalRegDispatch(self: *Runtime, start_ns: Value, fib: *Fiber, budget: u32) Error!EvalStatus {
    const eval_context = self.context();
    if (eval_context.lease != null) {
        return self.evalRegDispatchMode(true, start_ns, fib, budget, eval_context);
    }
    return self.evalRegDispatchMode(false, start_ns, fib, budget, eval_context);
}

fn evalRegDispatchMode(
    self: *Runtime,
    comptime metered: bool,
    start_ns: Value,
    fib: *Fiber,
    budget: u32,
    eval_context: *EvalContext,
) Error!EvalStatus {
    // Hot dispatch loop: runtime safety (bounds/overflow checks on every
    // register access and stack write) is the dominant per-instruction cost.
    // The compiler guarantees register indices < nregs and the explicit
    // growth checks below keep the stack in bounds — a safety panic here
    // would only fire on a compiler bug, which Debug builds of the COMPILER
    // catch long before this loop runs.
    @setRuntimeSafety(false);
    const z_evalreg = tracy.Zone.begin(.{ .name = "evalReg", .src = @src() });
    defer z_evalreg.end();
    var budget_left = budget;
    const lease = eval_context.lease;
    try validateInstructionAddress(fib);
    var verified = hasVerifiedProgram(fib);
    var work_window: ?EvalContext.Budget.Lease.RegvmWindow = null;
    defer if (work_window) |*window| window.deinit();
    while (true) {
        // Quantum accounting: yield BEFORE consuming the next instruction.
        if (budget_left == 0) return .yielded;
        // Reuse only verified instructions. Unverified code must still debit
        // before validating its address.
        const peeked_inst: regvm.Inst = if (comptime metered)
            (if (verified) fib.ip[0] else .{})
        else
            .{};
        if (comptime metered) {
            if (verified and self.canKeepRegvmBudgetLock(eval_context, fib, peeked_inst)) {
                if (work_window == null) work_window = lease.?.lockRegvm();
                if (work_window) |*window| try window.charge();
            } else {
                if (work_window) |*window| {
                    const err = window.deinitAndCharge();
                    work_window = null;
                    try err;
                } else {
                    try lease.?.chargeRegvmInstruction();
                }
            }
        }
        budget_left -= 1;
        // Rewind to this address when a blocking intrinsic suspends.
        const op_ip = fib.ip;
        if (!verified) try validateInstructionAddress(fib);
        const inst = if (comptime metered)
            (if (verified) peeked_inst else fib.ip[0])
        else
            fib.ip[0];
        if (!verified) try validateInstruction(fib, inst);
        fib.ip += 1;
        switch (inst.opcode) {
            .stop => {
                // .stop rd — the top-level result register. The ABI reads the
                // result from r0 after .done, so materialize it there (a no-op
                // when rd = 0: the value already is r0).
                const rd = regvm.Formats.slot(inst.payload);
                if (rd != 0) fib.setReg(0, fib.getReg(rd));
                self.releaseFiberGuards(fib);
                break;
            },
            .start, .nop => {},

            .src => {
                // Source marker: the DFS preorder index of the next compiled
                // expression's node within the current function's source tree
                // (Closure.source). Recorded so an error in this expression
                // maps back to the source (design directive 3).
                fib.src_idx = inst.payload;
            },
            .@"try" => {
                const rd, const off_u = regvm.Formats.rdAndSidx(inst.payload);
                // Snapshot the complete catch state. The handler offset is
                // relative to the instruction after `.try`.
                const after_try = fib.ip;
                try jumpRelative(fib, @as(i64, @as(i16, @bitCast(off_u))));
                const handler_ip = fib.ip;
                fib.ip = after_try;
                try fib.exn_stack.append(fib.stack_allocator orelse self.static, .{
                    .sp = fib.sp,
                    .fp = fib.fp,
                    .ap = fib.ap,
                    .ns = fib.ns,
                    .consts = fib.consts,
                    .fns = fib.fns,
                    .active_guard = fib.active_guard,
                    .current_closure = fib.current_closure,
                    .ir = fib.ir,
                    .nregs = fib.nregs,
                    .src_idx = fib.src_idx,
                    .call_depth = fib.call_depth,
                    .handler_ip = handler_ip,
                    .exn_rd = rd,
                });
            },
            .end_try => {
                // Fall-through path: the try body completed without an
                // error — pop the catch-state frame.
                if (fib.exn_stack.items.len == 0) return error.StackUnderflow;
                _ = fib.exn_stack.pop();
            },
            .raise => {
                // Store the payload and unwind. The evalReg wrapper delivers
                // it to the innermost .try handler (or completes the process
                // with error.Raised, payload preserved in fib.raised).
                const payload = fib.getReg(regvm.Formats.slot(inst.payload));
                if (payload.typ == b.type_error) {
                    fib.pending_error = payload;
                    fib.raised = if (payload.errorCode() == error.Raised)
                        payload.errorRaised()
                    else
                        .nil;
                    return payload.errorCode();
                }
                fib.raised = payload;
                return error.Raised;
            },

            .enter => {
                const nlocals = regvm.Formats.slot(inst.payload);
                _ = nlocals;
            },
            .ret => {
                if (@as(u8, @truncate(inst.payload)) != 0) return error.InvalidCode;
                try self.returnFrame(fib, regvm.Formats.slot(inst.payload), 1);
                verified = hasVerifiedProgram(fib);
            },
            .ret_multi => {
                const count: u8 = @truncate(inst.payload);
                if (count <= 1) return error.InvalidCode;
                try self.returnFrame(fib, regvm.Formats.slot(inst.payload), count);
                verified = hasVerifiedProgram(fib);
            },

            .mov_i64 => {
                const rd, const imm_raw = regvm.Formats.rdAndSidx(inst.payload);
                // imm16 payload — sign-extend to i64 (a u16 bitcast would make
                // negatives read as large positives).
                fib.setReg(rd, Value.i64(@as(i16, @bitCast(@as(u16, @truncate(imm_raw))))));
            },
            .load => {
                const rd, const kidx = regvm.Formats.rdAndSidx(inst.payload);
                if (@as(usize, kidx) >= fib.consts.len) return error.InvalidCode;
                fib.setReg(rd, fib.consts[kidx]);
            },
            .make_closure => {
                const rd, const site_index = regvm.Formats.rdAndSidx(inst.payload);
                const caller_index = if (fib.current_closure) |closure| @intFromEnum(closure.function_id) else 0;
                if (caller_index >= fib.fns.len) return error.InvalidCode;
                const caller = fib.fns[caller_index];
                if (site_index >= caller.closure_sites.len) return error.InvalidCode;
                const site = caller.closure_sites[site_index];
                const captures = site.captures(caller.capture_regs) orelse return error.InvalidCode;
                const target_index = @intFromEnum(site.function);
                if (target_index >= fib.fns.len) return error.InvalidCode;
                const ft = fib.fns[target_index];
                if (captures.len != ft.capture_syms.len) return error.InvalidCode;
                for (captures) |source| {
                    if (source >= fib.activeNregs()) return error.InvalidCode;
                }
                const inherited_guard: ?*const ClosureGuard = if (fib.current_closure) |parent| blk: {
                    if (parent.guard) |guard| break :blk try self.inheritClosureGuard(guard);
                    break :blk null;
                } else null;
                const ref = try self.store.create(Closure);
                const closure = ref.deref(Closure);
                // The Store header is already typed. Keep small capture sets
                // in this allocation; larger sets retain their own typed slice.
                const captured: []Value = if (captures.len <= closure.inline_captures.len)
                    closure.inline_captures[0..captures.len]
                else
                    (try self.store.allocSlice(Value, captures.len)).slice;
                self.store.store(Closure, closure, .{
                    .parent_ns = fib.ns,
                    .arglist = ft.arglist,
                    .capture_syms = ft.capture_syms,
                    .code = ft.code,
                    .function_id = ft.function,
                    // Carry the shared function table with the closure: a
                    // normal .call inherits fns from the caller's fiber, but a
                    // spawned process has no caller fiber (see spawnClosure).
                    .fns = fib.fns,
                    .captures = captured,
                    .source = ft.source,
                    .source_ref = ft.source_ref,
                    .ir = ft.ir,
                    .constants = ft.constants,
                    .nregs = ft.nregs,
                    .result_count = ft.result_count,
                    .zero_mask = ft.zero_mask,
                    .guard = inherited_guard,
                });
                // Lift from the enclosing frame before publishing this
                // closure in a register that the program can observe.
                for (captured, captures) |*slot, src| {
                    slot.* = fib.getReg(src);
                }
                fib.setReg(rd, .closure(ref.toObject()));
            },
            .ns_push => {
                const rd = regvm.Formats.slot(inst.payload);
                const count: u16 = @truncate(inst.payload); // low 16 bits
                // Mirror evalNode .Let: a fresh namespace, parent = fib.ns.
                // The compiler encodes the binding count: up to
                // SmallNamespace.size bindings use the SIMD fast path, more
                // fall back to a HashMapNamespace (no cap).
                const ns_ref = try self.store.create(Namespace);
                const ns_obj = ns_ref.toObject();
                const new_ns = Value.namespace(ns_obj);
                if (count > SmallNamespace.size) {
                    self.store.store(Namespace, ns_ref.deref(Namespace), HashMapNamespace.vtable);
                    const map = try self.static.create(HashMapNamespace);
                    map.* = try HashMapNamespace.init(self.static, fib.ns);
                    ns_ref.deref(Namespace).data = @ptrCast(map);
                } else {
                    self.store.store(Namespace, ns_ref.deref(Namespace), SmallNamespace.vtable);
                    const small = try self.static.create(SmallNamespace);
                    small.* = SmallNamespace{ .parent = fib.ns };
                    ns_ref.deref(Namespace).data = @ptrCast(small);
                }
                self.ownNamespace(new_ns);
                // Save the old ns on the fiber stack (grow on demand, like .call).
                if (fib.sp + 2 > fib.stack.len) {
                    const old_len = fib.stack.len;
                    var new_len = old_len * 2;
                    if (new_len < fib.sp + 2) new_len = fib.sp + 2;
                    const grown = try (fib.stack_allocator orelse self.static).realloc(fib.stack, new_len);
                    @memset(grown[old_len..], .null);
                    fib.stack = grown;
                }
                fib.stack[fib.sp] = fib.ns.typ;
                fib.stack[fib.sp + 1] = fib.ns.obj;
                fib.sp += 2;
                fib.ns = new_ns;
                fib.setReg(rd, new_ns);
            },
            .ns_pop => {
                // Release-mode guard: a compiler mispair must error, not OOB.
                if (fib.sp == 0 or fib.sp == 1) return error.StackUnderflow;
                const pair = fib.stack[fib.sp - 2 .. fib.sp];
                fib.ns = .{ .typ = pair[0], .obj = pair[1] };
                fib.sp -= 2;
            },
            .mov_reg => {
                const rd, const rs16 = regvm.Formats.rdAndSidx(inst.payload);
                const rs: u8 = @truncate(rs16);
                fib.setReg(rd, fib.getReg(rs));
            },

            .lookup, .lookup_val => {
                const rd, const sidx = regvm.Formats.rdAndSidx(inst.payload);
                if (@as(usize, sidx) >= self.symbol_pool.items.len) return error.InvalidCode;
                const entry = self.symbol_pool.items[sidx];
                const sym = entry.symbol;
                if (comptime metered) {
                    if (work_window) |*window| {
                        fib.setReg(rd, try self.restrictedNamespaceReadWithWindow(
                            eval_context,
                            fib.ns,
                            sym,
                            window,
                        ));
                        continue;
                    }
                }
                fib.setReg(rd, try self.nsGetSplit(fib.ns, sym, entry.may_split));
            },
            .set, .set_existing => {
                const rs, const sidx = regvm.Formats.rdAndSidx(inst.payload);
                if (@as(usize, sidx) >= self.symbol_pool.items.len) return error.InvalidCode;
                const sym = self.symbol_pool.items[sidx].symbol;
                const value = fib.getReg(@truncate(rs));
                if (inst.opcode == .set_existing) {
                    try self.nsAssign(fib.ns, sym, value);
                } else {
                    try self.nsBind(fib.ns, sym, value);
                }
            },

            .get_self => {
                const rd = regvm.Formats.slot(inst.payload);
                const cl = fib.current_closure orelse return error.InvalidCode;
                const ref = Ref.unsafeTaggedRef(cl);
                fib.setReg(rd, .closure(ref.toObject()));
            },

            .call, .call_multi => {
                const z_opcall = tracy.Zone.begin(.{ .name = "op-call", .src = @src() });
                defer z_opcall.end();
                const rd, const nargs, const encoded = regvm.Formats.rdNargsFlags(inst.payload);
                const result_count: u8 = if (inst.opcode == .call) 1 else encoded;
                if (inst.opcode == .call_multi and result_count <= 1) return error.InvalidCode;
                const args_len = if (nargs > 0) nargs - 1 else return error.InvalidCode;
                const func = fib.getReg(rd);
                var buf: [256]Value = undefined;
                const borrow_args = func.typ == b.type_closure and
                    func.obj.toRef().deref(Closure).guard == null;
                const args: []const Value = if (fib.pending_apply != null)
                    &.{}
                else if (borrow_args)
                    fib.registerArgs(rd, args_len)
                else blk: {
                    const copied = buf[0..args_len];
                    for (copied, 0..) |*item, i| {
                        item.* = fib.getReg(@intCast(@as(usize, rd) + 1 + i));
                    }
                    break :blk copied;
                };
                switch (try self.dispatchVmCall(
                    start_ns,
                    fib,
                    eval_context,
                    func,
                    args,
                    rd,
                    result_count,
                    false,
                    op_ip,
                    buf[0..],
                    func,
                    borrow_args,
                )) {
                    .entered => verified = hasVerifiedProgram(fib),
                    .completed => {},
                    .suspended => return .{ .suspended = .waiting_io },
                }
            },

            .tail_call, .tail_call_multi => {
                const rd, const nargs, const encoded = regvm.Formats.rdNargsFlags(inst.payload);
                const result_count: u8 = if (inst.opcode == .tail_call) 1 else encoded;
                if (inst.opcode == .tail_call_multi and result_count <= 1) return error.InvalidCode;
                const args_len = if (nargs > 0) nargs - 1 else return error.InvalidCode;
                const func = fib.getReg(rd);
                var buf: [256]Value = undefined;
                const borrow_args = func.typ == b.type_closure and
                    func.obj.toRef().deref(Closure).guard == null;
                const args: []const Value = if (fib.pending_apply != null)
                    &.{}
                else if (borrow_args)
                    fib.registerArgs(rd, args_len)
                else blk: {
                    const copied = buf[0..args_len];
                    for (copied, 0..) |*item, i| {
                        item.* = fib.getReg(@intCast(@as(usize, rd) + 1 + i));
                    }
                    break :blk copied;
                };
                switch (try self.dispatchVmCall(
                    start_ns,
                    fib,
                    eval_context,
                    func,
                    args,
                    rd,
                    result_count,
                    true,
                    op_ip,
                    buf[0..],
                    func,
                    borrow_args,
                )) {
                    .entered => verified = hasVerifiedProgram(fib),
                    .completed => {
                        try self.returnFrame(fib, rd, result_count);
                        verified = hasVerifiedProgram(fib);
                    },
                    .suspended => return .{ .suspended = .waiting_io },
                }
            },

            .self_call => {
                // self_call rd, nargs — dispatch the EXECUTING closure
                // (fib.current_closure) with args from R[rd+1..rd+nargs-1].
                // The window has NO func slot: R[rd] is the dead base and
                // receives the result (the callee's .ret writes
                // frame.ret_reg = rd, matching .call). Avoids the namespace
                // lookup and dynamic callee dispatch; the callee's lexical
                // namespace is still restored after any local bindings.
                const rd, const nargs, const _flags = regvm.Formats.rdNargsFlags(inst.payload);
                _ = _flags;
                const cl_ptr = fib.current_closure orelse return error.InvalidCode;
                if (cl_ptr.result_count != 1) return error.InvalidCode;
                var buf: [256]Value = undefined;
                const args_len = if (nargs > 0) nargs - 1 else return error.InvalidCode;
                const args: []const Value = if (cl_ptr.guard == null)
                    fib.registerArgs(rd, args_len)
                else blk: {
                    const copied = buf[0..args_len];
                    for (0..args_len) |i| {
                        copied[i] = fib.getReg(@intCast(@as(usize, rd) + 1 + i));
                    }
                    break :blk copied;
                };
                try self.checkClosureGuard(cl_ptr, args);
                var call_args = try prepareClosureArgs(eval_context, cl_ptr, args, buf[0..]);
                // Validate depth and reserve the stack before acquiring a
                // lease. A failed grow cannot leak a callback acquisition.
                try checkVmDepth(eval_context, fib, 1);
                if (fib.call_depth == std.math.maxInt(u32)) return error.Unsupported;
                const frame_objects = frame_size + @as(usize, cl_ptr.nregs) * 2;
                if (fib.sp + frame_objects > fib.stack.len) {
                    if (cl_ptr.guard == null and call_args.ptr == args.ptr) {
                        @memcpy(buf[0..call_args.len], call_args);
                        call_args = buf[0..call_args.len];
                    }
                    // Grow the caller-allocated stack, doubling.
                    const old_len = fib.stack.len;
                    var new_len = old_len * 2;
                    if (new_len < fib.sp + frame_objects) new_len = fib.sp + frame_objects;
                    const grown = try (fib.stack_allocator orelse self.static).realloc(fib.stack, new_len);
                    @memset(grown[old_len..], .null);
                    fib.stack = grown;
                }
                fib.call_depth += 1;
                const acquired_guard = self.acquireClosureGuard(cl_ptr) catch |err| {
                    fib.call_depth -= 1;
                    return err;
                };
                const frame: FrameReg = .{
                    .prev_ap = fib.ap,
                    .prev_fp = fib.fp,
                    .prev_sp = fib.sp,
                    .consts = fib.consts,
                    .ns = fib.ns,
                    .prev_fns = fib.fns,
                    .ret_reg = rd,
                    .result_count = 1,
                    .ret_addr = fib.ip,
                    .guard = acquired_guard,
                    .prev_guard = fib.active_guard,
                    .prev_closure = fib.current_closure,
                    .prev_nregs = fib.nregs,
                    .prev_ir = fib.ir,
                    .prev_src_idx = fib.src_idx,
                };
                const frame_ptr: *FrameReg = @ptrCast(&fib.stack[fib.sp]);
                frame_ptr.* = frame;
                fib.active_guard = acquired_guard;
                // Switch to the callee frame; register indices below are
                // callee-relative. ap formula identical to .call.
                fib.ap = fib.fp + frame_size + @as(usize, rd) * 2;
                fib.fp = fib.sp;
                fib.sp += frame_objects;
                // Copy normalized parameters before the lifted captures.
                for (call_args, 0..) |argument, i| {
                    fib.setReg(@intCast(1 + i), argument);
                }
                for (cl_ptr.captures, 0..) |cap, i| {
                    fib.setReg(@intCast(cl_ptr.arglist.len + 1 + i), cap);
                }
                // Masked zeroing: nil only the registers the callee may READ
                // before WRITING (bit r of its per-closure zero_mask; bit 0 =
                // the r0 nil-set, skipped when the callee provably writes r0
                // first). Registers >= 32 are outside the u32 mask's coverage
                // and are always zeroed. Normalized parameters and captures
                // are already written, so the conservative all-ones mask for
                // unanalyzed closures does not zero them.
                const first_temp = cl_ptr.arglist.len + 1 + cl_ptr.captures.len;
                var zmask = cl_ptr.zero_mask;
                if (cl_ptr.nregs < 32) zmask &= (@as(u32, 1) << @as(u5, @intCast(cl_ptr.nregs))) - 1;
                while (zmask != 0) {
                    const zreg: u8 = @ctz(zmask);
                    if (zreg == 0 or @as(usize, zreg) >= first_temp) fib.setReg(zreg, .nil);
                    zmask &= zmask - 1;
                }
                if (cl_ptr.nregs > 32) {
                    const hi_from: usize = @max(first_temp, 32);
                    for (hi_from..cl_ptr.nregs) |reg| fib.setReg(@intCast(reg), .nil);
                }
                fib.consts = cl_ptr.constants;
                fib.ns = cl_ptr.parent_ns;
                fib.fns = cl_ptr.fns;
                fib.current_closure = cl_ptr;
                fib.ir = cl_ptr.ir;
                fib.nregs = cl_ptr.nregs;
                fib.src_idx = 0;
                fib.ip = cl_ptr.ir.ptr;
                verified = hasVerifiedProgram(fib);
            },

            .tail_self_call => {
                // tail_self_call rd, nargs — the self-call in tail position:
                // replace the CURRENT frame in place (like .tail_call) and
                // jump back into the executing closure's own code. The
                // callee's .ret returns to the ORIGINAL caller, so every
                // frame field — prev_*, the restore consts/ns, ret_reg,
                // ret_addr, prev_closure — is inherited from the frame
                // already sitting at fib.fp.
                const rd, const nargs, const _flags = regvm.Formats.rdNargsFlags(inst.payload);
                _ = _flags;
                const cl_ptr = fib.current_closure orelse return error.InvalidCode;
                if (cl_ptr.result_count != 1) return error.InvalidCode;
                var buf: [256]Value = undefined;
                const args_len = if (nargs > 0) nargs - 1 else return error.InvalidCode;
                const args: []const Value = if (cl_ptr.guard == null)
                    fib.registerArgs(rd, args_len)
                else blk: {
                    const copied = buf[0..args_len];
                    for (0..args_len) |i| {
                        copied[i] = fib.getReg(@intCast(@as(usize, rd) + 1 + i));
                    }
                    break :blk copied;
                };
                try self.checkClosureGuard(cl_ptr, args);
                // A locked self-tail already passed fixed-arity and no-rest checks.
                const prechecked = if (comptime metered) work_window != null else false;
                var call_args = if (prechecked)
                    args
                else
                    try prepareClosureArgs(eval_context, cl_ptr, args, buf[0..]);
                if (fib.fp > fib.stack.len or frame_size > fib.stack.len - fib.fp) return error.InvalidCode;
                const old_frame_ptr: *const FrameReg = @ptrCast(fib.stack[fib.fp..].ptr);
                if (old_frame_ptr.ret_addr == null) return error.InvalidCode;
                const retired_guard = old_frame_ptr.guard;
                const retired_result_count = old_frame_ptr.result_count;
                const frame_objects = frame_size + @as(usize, cl_ptr.nregs) * 2;
                if (fib.fp + frame_objects > fib.stack.len) {
                    if (cl_ptr.guard == null and call_args.ptr == args.ptr) {
                        @memcpy(buf[0..call_args.len], call_args);
                        call_args = buf[0..call_args.len];
                    }
                    // The replaced frame may be smaller than the callee needs
                    // — grow the stack, doubling.
                    const old_len = fib.stack.len;
                    var new_len = old_len * 2;
                    if (new_len < fib.fp + frame_objects) new_len = fib.fp + frame_objects;
                    const grown = try (fib.stack_allocator orelse self.static).realloc(fib.stack, new_len);
                    @memset(grown[old_len..], .null);
                    fib.stack = grown;
                }
                // The original caller's restoration fields remain in place.
                if (retired_result_count != 1) return error.InvalidCode;
                if (fib.active_guard != retired_guard) return error.InvalidCode;
                const acquired_guard = try self.acquireClosureGuard(cl_ptr);
                // Guard is the only frame field that belongs to this
                // invocation; preserve all fields needed by the caller's ret.
                const new_frame_ptr: *FrameReg = @ptrCast(&fib.stack[fib.fp]);
                new_frame_ptr.guard = acquired_guard;
                fib.active_guard = acquired_guard;
                // This frame's registers become the callee's; ap = the staged
                // arg base (R[rd] slot of THIS frame, same formula as .call).
                // fp does NOT change.
                fib.ap = fib.fp + frame_size + @as(usize, rd) * 2;
                // The callee's frame extent replaces the old one (NOT sp +=
                // frame_objects — the old frame may be larger or smaller).
                fib.sp = fib.fp + frame_objects;
                // Copy normalized parameters before the lifted captures.
                for (call_args, 0..) |argument, i| {
                    fib.setReg(@intCast(1 + i), argument);
                }
                for (cl_ptr.captures, 0..) |cap, i| {
                    fib.setReg(@intCast(cl_ptr.arglist.len + 1 + i), cap);
                }
                // Masked zeroing: see the self_call arm — nil only the
                // registers the callee may READ before WRITING (zero_mask
                // bits; bit 0 = the r0 nil-set), never the just-copied
                // args/captures, always registers >= 32.
                const first_temp = cl_ptr.arglist.len + 1 + cl_ptr.captures.len;
                var zmask = cl_ptr.zero_mask;
                if (cl_ptr.nregs < 32) zmask &= (@as(u32, 1) << @as(u5, @intCast(cl_ptr.nregs))) - 1;
                while (zmask != 0) {
                    const zreg: u8 = @ctz(zmask);
                    if (zreg == 0 or @as(usize, zreg) >= first_temp) fib.setReg(zreg, .nil);
                    zmask &= zmask - 1;
                }
                fib.consts = cl_ptr.constants;
                fib.ns = cl_ptr.parent_ns;
                fib.fns = cl_ptr.fns;
                fib.current_closure = cl_ptr;
                fib.ir = cl_ptr.ir;
                fib.nregs = cl_ptr.nregs;
                fib.src_idx = 0;
                fib.ip = cl_ptr.ir.ptr;
                // Retire the replaced invocation only after every callee
                // register, frame field, and code pointer is staged.
                if (retired_guard) |guard| self.releaseClosureGuard(guard);
                verified = hasVerifiedProgram(fib);
            },

            .call_builtin_0, .call_builtin_1, .call_builtin_2, .call_builtin_3, .call_builtin_ext => {
                const ir = fib.activeIr();
                const single = [1]regvm.Inst{inst};
                const code = if (ir.len == 0) single[0..] else ir;
                const index = if (ir.len == 0) 0 else (@intFromPtr(op_ip) - @intFromPtr(ir.ptr)) / @sizeOf(regvm.Inst);
                const builtin = try regvm.decodeBuiltin(code, index);
                if (builtin.index >= self.intrinsics.funcs.len) return error.InvalidCode;
                fib.ip += builtin.size - 1;
                const func = Value.intrinsic(self.intrinsics.funcs[builtin.index]);
                var buf: [256]Value = undefined;
                const args = buf[0..builtin.argc];
                if (fib.pending_apply == null) {
                    for (args, 0..) |*item, i| {
                        item.* = fib.getReg(@intCast(@as(usize, builtin.base) + 1 + i));
                    }
                }
                switch (try self.dispatchVmCall(
                    start_ns,
                    fib,
                    eval_context,
                    func,
                    args,
                    builtin.base,
                    1,
                    false,
                    op_ip,
                    buf[0..],
                    .nil,
                    false,
                )) {
                    .entered => verified = hasVerifiedProgram(fib),
                    .completed => {},
                    .suspended => return .{ .suspended = .waiting_io },
                }
            },

            .br => {
                const rd, const off = regvm.Formats.rdOffset(inst.payload);
                if (Value.isTruthy(fib.getReg(rd))) try jumpRelative(fib, off);
            },

            .brn => {
                const rd, const off = regvm.Formats.rdOffset(inst.payload);
                if (!Value.isTruthy(fib.getReg(rd))) try jumpRelative(fib, off);
            },

            .jmp => {
                const raw = regvm.Formats.imm24(inst.payload);
                try jumpRelative(fib, raw);
            },

            // Generic arithmetic — fall back to apply
            .guard_callee => {
                const callee, const expected_index = regvm.Formats.rdAndSidx(inst.payload);
                const extension = regvm.Formats.extension(fib.ip[0]);
                fib.ip += 1;
                if (@as(usize, expected_index) >= fib.consts.len) return error.InvalidCode;
                const actual = fib.getReg(callee);
                const expected = fib.consts[expected_index];
                if (actual.typ != expected.typ or actual.obj != expected.obj) {
                    try jumpRelative(fib, @intCast(extension));
                }
            },

            .guard_self => {
                const callee = regvm.Formats.slot(inst.payload);
                const extension = regvm.Formats.extension(fib.ip[0]);
                fib.ip += 1;
                const cl = fib.current_closure orelse return error.InvalidCode;
                const expected = Ref.unsafeTaggedRef(cl).toObject();
                const actual = fib.getReg(callee);
                if (actual.typ != b.type_closure or actual.obj != expected) {
                    try jumpRelative(fib, @intCast(extension));
                }
            },

            inline .generic_add,
            .generic_sub,
            .generic_mul,
            .generic_div,
            .generic_eq,
            .generic_lt,
            .generic_gt,
            => |op| {
                const rd, const rs1, const rs2 = regvm.Formats.rdRs1Rs2(inst.payload);
                try self.arithFallback(fib, rd, arithOpNameOf(op), fib.getReg(rs1), fib.getReg(rs2));
            },

            // Specialized arithmetic (3-address rd, rs1, rs2): add/sub/mul/
            // div/eq/lt for i64/f64. Each opcode is valid ONLY when both
            // operands carry its expected type — the compiler emits it either
            // with proof (provable type tracking) or speculatively as a BET
            // (speculative_arith, from a sibling literal or i64). The runtime
            // type guard makes the speculative emission sound: on a mismatch
            // the fallback re-dispatches through the generic method path,
            // reproducing the exact pre-fast-path semantics (ArityMismatch on
            // mixed types, and the non-overridable core — data.zig `locked` —
            // pins the fallback to the builtin). c64 deliberately has NO
            // specialized handler — it stays on the generic path (the
            // compiler never emits it here).
            inline .add_i64, .sub_i64, .mul_i64, .div_i64, .eq_i64, .lt_i64, .gt_i64 => |op| {
                try guardedArith(
                    self,
                    fib,
                    op,
                    inst.payload,
                    b.type_i64,
                    &work_window,
                );
            },
            inline .add_f64, .sub_f64, .mul_f64, .div_f64, .eq_f64, .lt_f64, .gt_f64 => |op| {
                try guardedArith(
                    self,
                    fib,
                    op,
                    inst.payload,
                    b.type_f64,
                    &work_window,
                );
            },

            else => return error.InvalidCode,
        }
    }
    return .done;
}

/// Run a fiber to completion. Only the host uses this (REPL, eval tests):
/// process fibers go through the scheduler, which handles suspensions.
pub fn runToCompletion(self: *Runtime, start_ns: Value, fib: *Fiber) Error!Value {
    errdefer |err| {
        if (err != error.WouldBlock) self.releaseFiberGuards(fib);
    }
    while (true) switch (try self.evalReg(start_ns, fib, std.math.maxInt(u32))) {
        .done => return fib.getReg(0),
        .yielded => continue,
        .suspended => return error.Unimplemented,
    };
}

/// Compile `src` and spawn a cooperative process that evaluates it through
/// the register VM on the scheduler runner, binding defs into root_ns.
/// Returns the Process immediately; the caller awaits it with awaitProcess
/// (or polls with pollProcess). Parse/compile errors surface here (the
/// future is for EVAL errors). See spawnEvalWithNs for the full contract.
pub fn spawnEval(self: *Runtime, src: []const u8) Error!*sched_mod.Process {
    return self.spawnEvalWithNs(src, self.root_ns, null);
}

/// Compile `src` and spawn a cooperative process that evaluates it through
/// the register VM on the scheduler runner. `ns` is the fiber's RUNTIME
/// binding target (root_ns for host spawns, a fresh module namespace for
/// loads — top-level defs land there); the compile itself still resolves
/// against root_ns (the prelude — the module's own ns is only the runtime
/// binding target). `module_path` is the process's module path (arena-duped
/// into rt.static), used by the load intrinsic for path resolution and
/// cycle detection. Returns the Process immediately; the caller awaits it
/// with awaitProcess (or polls with pollProcess). Parse/compile errors
/// surface here (the future is for EVAL errors).
///
/// The process and its fiber stack are allocated from the runtime arena
/// (the same owner evalReg's stack growth uses — see scheduler.zig), so they
/// live until the runtime is deinitialized.
///
/// The program is compiled into the static arena. The spawn path serializes
/// parsing and compilation with other spawned evaluations under the scheduler
/// mutex, then releases it before publishing the process.
pub fn spawnEvalWithNs(
    self: *Runtime,
    src: []const u8,
    ns: skript.Value,
    module_path: ?[]const u8,
) Error!*sched_mod.Process {
    return self.spawnEvalWithNsContext(self.context(), src, ns, module_path);
}

pub fn spawnEvalWithNsContext(
    self: *Runtime,
    ctx: *EvalContext,
    src: []const u8,
    ns: Value,
    module_path: ?[]const u8,
) Error!*sched_mod.Process {
    if (ctx.runtime != self) return error.Denied;
    if (ctx.mode != .concrete) return error.Unsupported;
    var process_context = try ctx.enter(.scheduler);
    const scope = process_context.activate();
    defer scope.deinit();
    try process_context.charge(.{ .work = 1, .processes = 1 }, .scheduler);
    return self.spawnEvalWithNsActive(src, ns, module_path) catch |err| {
        try process_context.check();
        return err;
    };
}

pub fn spawnEvalFormWithNsContext(
    self: *Runtime,
    ctx: *EvalContext,
    form: Value,
    ns: Value,
) Error!*sched_mod.Process {
    if (ctx.runtime != self) return error.Denied;
    if (ctx.mode != .concrete) return error.Unsupported;
    var process_context = try ctx.enter(.scheduler);
    const scope = process_context.activate();
    defer scope.deinit();
    try process_context.charge(.{ .work = 1, .processes = 1 }, .scheduler);
    return self.spawnEvalFormWithNsActive(form, ns) catch |err| {
        try process_context.check();
        return err;
    };
}

pub fn evalDatumWithContext(
    self: *Runtime,
    ctx: *EvalContext,
    form: Value,
    explicit_ns: ?Value,
) Error!Value {
    if (ctx.runtime != self) return error.Denied;
    try ctx.check();
    if (ctx.mode != .concrete or ctx.execution != .trusted or
        ctx.effects.state_read != .allow or ctx.effects.state_write != .allow or
        ctx.effects.io != .allow or ctx.effects.process != .allow or
        ctx.effects.module != .allow or ctx.effects.host != .allow or
        ctx.effects.unknown != .allow)
    {
        return error.Denied;
    }

    if (explicit_ns) |ns| {
        if (ns.typ != b.type_namespace) return error.TypeMismatch;
    }
    const caller = sched_mod.current_process;
    const target_ns = explicit_ns orelse if (caller) |process| process.fib.ns else self.root_ns;

    // A native callback may execute while its scheduled caller already owns
    // pending_eval. It cannot suspend or consume that caller's continuation.
    if (caller) |process| {
        if (!ctx.native_reentry) {
            if (process.fib.pending_eval) |child| {
                if (!child.completed.load(.acquire)) return error.WouldBlock;
                self.scheduler.mutex.lockUncancelable(self.io);
                defer self.scheduler.mutex.unlock(self.io);
                self.scheduler.clearWaitEdgesLocked(process);
                process.fib.pending_eval = null;
                return child.result;
            }

            const child = try self.spawnEvalFormWithNsContext(ctx, form, target_ns);
            process.fib.pending_eval = child;
            self.scheduler.mutex.lockUncancelable(self.io);
            defer self.scheduler.mutex.unlock(self.io);
            if (child.completed.load(.acquire)) {
                process.fib.pending_eval = null;
                return child.result;
            }
            if (try self.scheduler.hasWaitPathLocked(ctx, child, process)) {
                process.fib.pending_eval = null;
                return error.CircularLoad;
            }
            try self.scheduler.addWaitEdgesLocked(self.static, process, &.{child});
            return error.WouldBlock;
        }
    }
    return self.evalDatumInline(ctx, form, target_ns);
}

/// Evaluate one datum on this call stack. The caller's context owns the
/// budget and depth lineage; the local fiber owns its guard leases. No process
/// or continuation is published, even when a scheduler process is in scope.
fn evalDatumInline(self: *Runtime, ctx: *EvalContext, form: Value, ns: Value) Error!Value {
    if (inline_eval_depth >= max_inline_eval_depth) return error.StackOverflow;
    inline_eval_depth += 1;
    defer inline_eval_depth -= 1;

    var nested = try ctx.enter(.regvm);
    nested.allow_suspend = false;
    const scope = nested.activate();
    defer scope.deinit();
    // The datum still consumes the same evaluation/process quota as the
    // scheduled path, without creating a scheduler process.
    try nested.charge(.{ .work = 1, .processes = 1 }, .regvm);
    const prog = self.compileEvalForm(form, ns) catch |err| {
        try nested.check();
        return err;
    };
    const stack = try self.static.alloc(Object, frame_size + @as(usize, prog.nregs) * 2);
    @memset(stack, .null);
    var fib: Fiber = .{
        .stack = stack,
        .sp = frame_size + @as(usize, prog.nregs) * 2,
        .ip = prog.ir.ptr,
        .ir = prog.ir,
        .nregs = prog.nregs,
        .consts = prog.constants,
        .fns = prog.fns,
        .ns = ns,
    };
    // runToCompletion preserves guards on WouldBlock for resumable callers;
    // this local fiber is never resumable and must retire every guard.
    defer self.releaseFiberGuards(&fib);
    const result = self.runToCompletion(ns, &fib) catch |err| {
        try nested.check();
        return err;
    };
    try nested.check();
    return result;
}

fn spawnEvalWithNsActive(
    self: *Runtime,
    src: []const u8,
    ns: Value,
    module_path: ?[]const u8,
) Error!*sched_mod.Process {
    // Serialize parsing and compilation with other spawned evaluations.
    // Release the mutex before publishProcess acquires it to register and enqueue.
    const prog = blk: {
        self.scheduler.mutex.lockUncancelable(self.io);
        defer self.scheduler.mutex.unlock(self.io);
        const parsed = try skript.Reader.readUnit(
            self.store,
            src,
            .{ .retention = self.source_retention, .file = module_path },
        );
        break :blk try self.compileData(ns, parsed.datum, module_path);
    };
    return self.spawnProgramWithNsActive(prog, ns, module_path);
}

fn spawnEvalFormWithNsActive(
    self: *Runtime,
    form: Value,
    ns: Value,
) Error!*sched_mod.Process {
    return self.spawnProgramWithNsActive(try self.compileEvalForm(form, ns), ns, null);
}

fn compileEvalForm(self: *Runtime, form: Value, ns: Value) Error!RegProgram {
    self.scheduler.mutex.lockUncancelable(self.io);
    defer self.scheduler.mutex.unlock(self.io);
    const cell = try self.store.create([2]Value);
    cell.deref([2]Value).* = .{ form, .nil };
    return self.compileData(ns, .cons(cell.toObject()), null);
}

fn spawnProgramWithNsActive(
    self: *Runtime,
    prog: RegProgram,
    ns: Value,
    module_path: ?[]const u8,
) Error!*sched_mod.Process {
    // Allocate the Process and its fiber stack from the runtime arena —
    // identical construction to main.zig's regvm path.
    const proc = try self.static.create(sched_mod.Process);
    const stack = try self.static.alloc(Object, frame_size + @as(usize, prog.nregs) * 2);
    @memset(stack, .null);
    const pid = self.scheduler.next_pid.fetchAdd(1, .monotonic);
    // SAFETY: io_future stays null unless this spawn dispatches the runner
    // below; the runner never touches proc.io_future, and the host assigns
    // it before any awaitProcess/pollProcess can observe the process.
    proc.* = .{
        .pid = pid,
        .fib = .{
            .stack = stack,
            .sp = frame_size + @as(usize, prog.nregs) * 2,
            .ip = prog.ir.ptr,
            .ir = prog.ir,
            .nregs = prog.nregs,
            .consts = prog.constants,
            .fns = prog.fns,
            .ns = ns,
        },
    };
    try self.prepareProcessContext(proc);
    if (module_path) |p| proc.module_path = try self.static.dupe(u8, p);
    try self.publishProcess(proc);
    return proc;
}

fn publishProcess(self: *Runtime, proc: *sched_mod.Process) Error!void {
    const ref = try self.store.create(sched_mod.FutureObj);
    const future = ref.deref(sched_mod.FutureObj);
    self.store.store(sched_mod.FutureObj, future, .{
        .done = .init(false),
        .result = .nil,
        .io_future = null,
    });
    var runner_index: ?usize = null;
    {
        self.scheduler.mutex.lockUncancelable(self.io);
        defer self.scheduler.mutex.unlock(self.io);
        const start_runner = !self.scheduler.runner_active.load(.acquire);
        if (start_runner) try self.scheduler.runners.ensureUnusedCapacity(self.gpa, 1);
        try self.scheduler.registerLocked(self.gpa, proc);
        self.scheduler.enqueueLocked(proc);
        proc.future_obj.store(future, .release);
        if (start_runner) {
            runner_index = self.scheduler.runners.items.len;
            // SAFETY: assigned below before publication returns and teardown can start.
            self.scheduler.runners.appendAssumeCapacity(undefined);
            self.scheduler.runner_active.store(true, .release);
        }
    }
    self.scheduler.event.set(self.io);
    if (runner_index) |index| {
        const task = self.io.concurrent(sched_mod.runOne, .{ self, &self.scheduler, proc }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => self.io.async(sched_mod.runOne, .{ self, &self.scheduler, proc }),
        };
        proc.io_future = task;
        future.io_future = &proc.io_future.?;
        self.scheduler.mutex.lockUncancelable(self.io);
        defer self.scheduler.mutex.unlock(self.io);
        self.scheduler.runners.items[index] = task;
    }
}

/// Register the main module in the module registry before its process runs.
/// The main module keeps root_ns as its namespace (existing behavior — defs
/// stay REPL-visible); when the main process completes, the load intrinsic's
/// transition code turns this entry loaded with ns = root_ns (see W3's
/// contract). Called by main.zig before awaitProcess. The path is arena-duped
/// into rt.static; the registry never frees it.
pub fn registerMainModule(self: *Runtime, path: []const u8, proc: *sched_mod.Process) !void {
    const owned = try self.static.dupe(u8, path);
    self.scheduler.mutex.lockUncancelable(self.io);
    defer self.scheduler.mutex.unlock(self.io);
    // Find-or-insert; an entry for the main module should not pre-exist, but
    // if it does (re-registration), overwrite it wholesale.
    const entry = try self.modules.insertLocked(self.static, owned, proc);
    entry.* = .{
        .path = owned,
        .status = .loading,
        .process = proc,
    };
}

/// Spawn a process running an EXISTING compiled closure (the `spawn`
/// intrinsic path). The fiber starts INSIDE the closure body with the same
/// frame shape the .call arm builds for a callee: a FrameReg at the base of
/// the stack, with captured values after normalized parameter slots and
/// remaining registers zeroed. A zero-prefix rest closure starts with nil in
/// its rest slot. The body's terminating `.ret` resumes at a
/// `.stop` trampoline (a separate arena allocation — stable across stack
/// growth) and halts the fiber with `.done`.
///
/// Everything else mirrors spawnEval: process + fiber stack from the runtime
/// arena, scheduler registration + enqueue, a dispatched runner (so
/// awaitProcess works on spawned processes), and a published FutureObj (so
/// pollProcess works too).
fn prepareProcessContext(self: *Runtime, process: *sched_mod.Process) Error!void {
    const parent = self.context();
    process.eval_context = try parent.enter(.scheduler);
    const child = &process.eval_context.?;
    child.allow_suspend = parent.allow_suspend;
    if (parent.lease) |lease| {
        process.lease = try lease.child(std.math.maxInt(u64));
        child.lease = &process.lease.?;
        process.scratch_account = .init(parent.scratch_base, child.lease.?, .scheduler);
        child.scratch = process.scratch_account.?.allocator();
    }
}

pub fn spawnClosure(self: *Runtime, fn_val: Value) Error!*sched_mod.Process {
    const ctx = self.context();
    const scope = ctx.activate();
    defer scope.deinit();
    try ctx.check();
    try ctx.charge(.{ .work = 1, .processes = 1 }, .scheduler);
    if (fn_val.typ != b.type_closure) return error.TypeMismatch;
    const cl = fn_val.obj.toRef().deref(Closure);
    try self.checkClosureGuard(cl, &.{});
    if (cl.result_count != 1) return error.Unsupported;
    if (cl.ir.len == 0) return error.Unimplemented;
    var initial_args_storage: [256]Value = undefined;
    const initial_args = try prepareClosureArgs(ctx, cl, &.{}, &initial_args_storage);

    const proc = try self.static.create(sched_mod.Process);
    const frame_objects = frame_size + @as(usize, cl.nregs) * 2;
    // One extra callee frame's worth of headroom so a single nested call or
    // ns_push on the first run does not force a realloc.
    const stack = try self.static.alloc(Object, frame_objects * 2);
    @memset(stack, .null);
    const pid = self.scheduler.next_pid.fetchAdd(1, .monotonic);

    // The initial frame, exactly as .call lays out a callee frame; on the
    // body's .ret the fiber resumes at the .stop trampoline and halts.
    const stop_inst = try self.static.create(regvm.Inst);
    stop_inst.* = regvm.Inst.make(.stop, 0);
    const frame: FrameReg = .{
        .prev_ap = 0,
        .prev_fp = 0,
        .prev_sp = frame_objects,
        .consts = cl.constants,
        .ns = cl.parent_ns,
        .prev_fns = &.{},
        .ret_reg = 0,
        .result_count = 1,
        .ret_addr = @ptrCast(stop_inst),
        .guard = null,
        .prev_guard = null,
        .prev_closure = null,
        .prev_nregs = 0,
        .prev_ir = &.{},
        .prev_src_idx = 0,
    };
    const frame_ptr: *FrameReg = @ptrCast(&stack[0]);
    frame_ptr.* = frame;

    proc.* = .{
        .pid = pid,
        .fib = .{
            .stack = stack,
            .sp = frame_objects,
            .ip = cl.ir.ptr,
            .ir = cl.ir,
            .nregs = cl.nregs,
            .consts = cl.constants,
            .fns = cl.fns,
            .ns = cl.parent_ns,
            .current_closure = cl,
            .call_depth = 1,
        },
        .io_future = null,
    };
    try self.prepareProcessContext(proc);
    // Stage normalized parameters and captured environment in their register
    // slots. A zero-prefix rest closure receives nil in its rest slot.
    for (initial_args, 0..) |argument, i| {
        proc.fib.setReg(@intCast(i + 1), argument);
    }
    for (cl.captures, 0..) |cap, i| {
        proc.fib.setReg(@intCast(cl.arglist.len + 1 + i), cap);
    }
    proc.fib.setReg(0, .nil);
    for (cl.arglist.len + 1 + cl.captures.len..cl.nregs) |reg| {
        proc.fib.setReg(@intCast(reg), .nil);
    }
    const acquired_guard = try self.acquireClosureGuard(cl);
    frame_ptr.guard = acquired_guard;
    proc.fib.active_guard = acquired_guard;
    // Ownership transfers to the scheduler only after publication. Any
    // failure before then must release the freshly acquired lease.
    errdefer self.releaseFiberGuards(&proc.fib);

    try self.publishProcess(proc);
    return proc;
}

/// Block until `proc` completes, returning its result or its eval error.
/// The runner publishes every completion through the FutureObj, so the host
/// observes it by polling (briefly parking on the scheduler event between
/// polls — the runner's done arm sets it). The Io future is NOT awaited
/// here: the deinit drain consumes each runner task exactly once. Must not
/// be called concurrently with another awaitProcess/spawnEval on the same
/// runtime.
pub fn awaitProcess(self: *Runtime, proc: *sched_mod.Process) Error!Value {
    while (true) {
        if (self.pollProcess(proc)) |v| return v;
        // Not done yet: park on the CLOCK, never on the scheduler event —
        // the runner is its only waiter (it resets it before parking, and
        // std.Io.Event.reset assumes no pending wait; a second waiter could
        // hit the .unset unreachable trap). The 1ms cadence keeps the
        // completion latency bounded.
        std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(1), .awake) catch |err| switch (err) {
            error.Canceled => return error.Unimplemented, // no cancellation in v1
        };
    }
}

/// Non-blocking completion check: the result once the process's FutureObj is
/// published and done, or null while it is still running (or its future_obj
/// has not been published yet — only possible before spawnEval returns).
pub fn pollProcess(self: *Runtime, proc: *sched_mod.Process) ?Error!Value {
    _ = self;
    const obj = proc.future_obj.load(.acquire) orelse return null;
    if (!obj.done.load(.acquire)) return null;
    // Surface a process failure as a Zig error, not a printed error value.
    return obj.result.unwrapError();
}

/// Arithmetic families that share same-type specialized execution.
const ArithFamily = enum { add, sub, mul, eq };

fn arithFamily(op: regvm.Opcode) ?ArithFamily {
    return switch (op) {
        .add_i64, .add_f64 => .add,
        .sub_i64, .sub_f64 => .sub,
        .mul_i64, .mul_f64 => .mul,
        .eq_i64, .eq_f64 => .eq,
        else => null,
    };
}

/// Integer-family tag test: the builtin tags are laid out with the family
/// base in bits 2+ and the size in the low 2 bits.
fn isIntTag(t: Object) bool {
    const tag = @intFromEnum(t);
    return (tag & skript.builtins.type_int_mask) == skript.builtins.type_int or
        (tag & skript.builtins.type_uint_mask) == skript.builtins.type_uint;
}

/// Integer arithmetic wraps at the operand width T and tags the result with T.
fn intBinOp(comptime T: type, fam: ArithFamily, a: Value, b_val: Value) Value {
    const x = a.obj.toInt(T);
    const y = b_val.obj.toInt(T);
    if (fam == .eq) return Value.bool(x == y);
    const r = switch (fam) {
        .add => x +% y,
        .sub => x -% y,
        .mul => x *% y,
        .eq => unreachable,
    };
    return switch (T) {
        i8 => Value.i8(r),
        i16 => Value.i16(r),
        i32 => Value.i32(r),
        i64 => Value.i64(r),
        u8 => Value.u8(r),
        u16 => Value.u16(r),
        u32 => Value.u32(r),
        u64 => Value.u64(r),
        else => unreachable,
    };
}

/// Float arithmetic (f16/f32/f64) — no overflow; eq keeps IEEE NaN != NaN.
fn floatBinOp(comptime T: type, fam: ArithFamily, a: Value, b_val: Value) Value {
    const x = if (T == f16) a.obj.tof16() else if (T == f32) a.obj.tof32() else a.obj.tof64();
    const y = if (T == f16) b_val.obj.tof16() else if (T == f32) b_val.obj.tof32() else b_val.obj.tof64();
    if (fam == .eq) return Value.bool(x == y);
    return switch (T) {
        f16 => Value.f16(switch (fam) {
            .add => x + y,
            .sub => x - y,
            .mul => x * y,
            .eq => unreachable,
        }),
        f32 => Value.f32(switch (fam) {
            .add => x + y,
            .sub => x - y,
            .mul => x * y,
            .eq => unreachable,
        }),
        f64 => Value.f64(switch (fam) {
            .add => x + y,
            .sub => x - y,
            .mul => x * y,
            .eq => unreachable,
        }),
        else => unreachable,
    };
}

/// Execute one arm of the speculative chain. `typ` is the runtime operand
/// type (both operands carry it). add/sub/mul wrap for every integer width
/// and tag the result with `typ`; f16/f32/f64 are IEEE. A PLAIN switch (not
/// inline): jump table, one arm per type with the comptime type spelled out.
inline fn execArithTyped(fib: *Fiber, fam: ArithFamily, rd: u8, a: Value, b_val: Value, typ: Object) void {
    const z_arith = tracy.Zone.begin(.{ .name = "op-arith", .src = @src() });
    defer z_arith.end();
    switch (typ) {
        b.type_i8 => fib.setReg(rd, intBinOp(i8, fam, a, b_val)),
        b.type_i16 => fib.setReg(rd, intBinOp(i16, fam, a, b_val)),
        b.type_i32 => fib.setReg(rd, intBinOp(i32, fam, a, b_val)),
        b.type_i64 => fib.setReg(rd, intBinOp(i64, fam, a, b_val)),
        b.type_u8 => fib.setReg(rd, intBinOp(u8, fam, a, b_val)),
        b.type_u16 => fib.setReg(rd, intBinOp(u16, fam, a, b_val)),
        b.type_u32 => fib.setReg(rd, intBinOp(u32, fam, a, b_val)),
        b.type_u64 => fib.setReg(rd, intBinOp(u64, fam, a, b_val)),
        b.type_f16 => fib.setReg(rd, floatBinOp(f16, fam, a, b_val)),
        b.type_f32 => fib.setReg(rd, floatBinOp(f32, fam, a, b_val)),
        b.type_f64 => fib.setReg(rd, floatBinOp(f64, fam, a, b_val)),
        else => unreachable,
    }
}

/// Runtime guard for specialized arithmetic opcodes. Add, subtract, multiply,
/// and equality may use sibling same-type numeric implementations. The i64
/// bet checks integer pairs, then f64 pairs; the f64 bet checks f64, f32, f16,
/// then integer pairs. Other operands use generic method dispatch, preserving
/// numeric coercion and type errors. Each typed path matches its builtin's
/// wrapping integer or IEEE floating-point behavior. Keep this inline so the
/// common bet-hit path remains inside the dispatch switch.
inline fn guardedArith(
    self: *Runtime,
    fib: *Fiber,
    op: regvm.Opcode,
    payload: u24,
    expected: Object,
    work_window: *?EvalContext.Budget.Lease.RegvmWindow,
) Error!void {
    const rd, const rs1, const rs2 = regvm.Formats.rdRs1Rs2(payload);
    const val_a = fib.getReg(rs1);
    const val_b = fib.getReg(rs2);
    const matched_type = val_a.typ == expected and val_b.typ == expected;
    if (!matched_type) {
        // Alternate numeric types can stay local, but generic fallback can
        // allocate or re-enter. Release before choosing either path.
        if (work_window.*) |*window| {
            window.deinit();
            work_window.* = null;
        }
    }
    if (arithFamily(op)) |fam| {
        if (matched_type) {
            // Bet hit: the exact pre-chain cost (2 compares + dispatch).
            execArithTyped(fib, fam, rd, val_a, val_b, expected);
        } else if (expected == b.type_i64) {
            if (isIntTag(val_a.typ) and val_a.typ == val_b.typ) {
                execArithTyped(fib, fam, rd, val_a, val_b, val_a.typ);
            } else if (val_a.typ == b.type_f64 and val_b.typ == b.type_f64) {
                execArithTyped(fib, fam, rd, val_a, val_b, b.type_f64);
            } else {
                try self.arithFallback(fib, rd, arithOpNameOf(op), val_a, val_b);
            }
        } else {
            if (val_a.typ == b.type_f64 and val_b.typ == b.type_f64) {
                execArithTyped(fib, fam, rd, val_a, val_b, b.type_f64);
            } else if (val_a.typ == b.type_f32 and val_b.typ == b.type_f32) {
                execArithTyped(fib, fam, rd, val_a, val_b, b.type_f32);
            } else if (val_a.typ == b.type_f16 and val_b.typ == b.type_f16) {
                execArithTyped(fib, fam, rd, val_a, val_b, b.type_f16);
            } else if (isIntTag(val_a.typ) and val_a.typ == val_b.typ) {
                execArithTyped(fib, fam, rd, val_a, val_b, val_a.typ);
            } else {
                try self.arithFallback(fib, rd, arithOpNameOf(op), val_a, val_b);
            }
        }
        return;
    }
    // div/lt: unchanged single-type guard (not in the chain).
    if (matched_type) {
        try execArithOp(fib, op, rd, rs1, rs2);
    } else {
        try self.arithFallback(fib, rd, arithOpNameOf(op), val_a, val_b);
    }
}

/// The operator name for a specialized arith opcode, for the generic
/// fallback dispatch.
fn arithOpNameOf(op: regvm.Opcode) []const u8 {
    return switch (op) {
        .generic_add, .add_i64, .add_f64 => "+",
        .generic_sub, .sub_i64, .sub_f64 => "-",
        .generic_mul, .mul_i64, .mul_f64 => "*",
        .generic_div, .div_i64, .div_f64 => "/",
        .generic_eq, .eq_i64, .eq_f64 => "=",
        .generic_lt, .lt_i64, .lt_f64 => "<",
        .generic_gt, .gt_i64, .gt_f64 => ">",
        else => unreachable,
    };
}

/// The generic fallback for arithmetic: re-dispatch the operator by name
/// through the runtime method path, exactly like the generic_* opcodes.
/// Used by the generic_* handlers AND by the guarded specialized handlers
/// on a runtime type mismatch (the speculative bet missed), so both paths
/// share one implementation. The non-overridable core (data.zig `locked`)
/// keeps this resolution pinned to the builtin method.
fn arithFallback(self: *Runtime, fib: *Fiber, rd: u8, op_name: []const u8, a: Value, b_val: Value) Error!void {
    const op_sym = try self.store.getsym(op_name);
    const op_func = try self.nsGet(self.root_ns, op_sym);
    fib.setReg(rd, try self.apply(self.root_ns, op_func, &.{ a, b_val }));
}

/// Execute specialized division and less-than opcodes. Integer division
/// truncates toward zero and reports zero-divisor and signed-overflow errors.
fn execArithOp(fib: *Fiber, op: regvm.Opcode, rd: u8, rs1: u8, rs2: u8) Error!void {
    const z_arith = tracy.Zone.begin(.{ .name = "op-arith", .src = @src() });
    defer z_arith.end();
    switch (op) {
        .div_f64 => {
            const val_a = fib.getReg(rs1).obj.tof64();
            const val_b = fib.getReg(rs2).obj.tof64();
            fib.setReg(rd, Value.f64(val_a / val_b));
        },
        .div_i64 => {
            const val_a = fib.getReg(rs1).obj.toInt(i64);
            const val_b = fib.getReg(rs2).obj.toInt(i64);
            if (val_b == 0) return error.TypeMismatch;
            if (val_a == std.math.minInt(i64) and val_b == -1) return error.Unsupported;
            fib.setReg(rd, Value.i64(@divTrunc(val_a, val_b)));
        },
        .lt_f64 => {
            const val_a = fib.getReg(rs1).obj.tof64();
            const val_b = fib.getReg(rs2).obj.tof64();
            fib.setReg(rd, Value.bool(val_a < val_b));
        },
        .lt_i64 => {
            const val_a = fib.getReg(rs1).obj.toInt(i64);
            const val_b = fib.getReg(rs2).obj.toInt(i64);
            fib.setReg(rd, Value.bool(val_a < val_b));
        },
        .gt_f64 => {
            // NaN on either side yields false, matching `@f64.gt` and so the
            // pre-fast-path method dispatch. NOT `val_b < val_a`: that swaps
            // which operand's NaN-ness is observed and is only equivalent on
            // totally ordered values.
            const val_a = fib.getReg(rs1).obj.tof64();
            const val_b = fib.getReg(rs2).obj.tof64();
            fib.setReg(rd, Value.bool(val_a > val_b));
        },
        .gt_i64 => {
            // i64 is totally ordered, so `>` could be spelled `val_b < val_a`;
            // written directly to match the operand order on the wire.
            const val_a = fib.getReg(rs1).obj.toInt(i64);
            const val_b = fib.getReg(rs2).obj.toInt(i64);
            fib.setReg(rd, Value.bool(val_a > val_b));
        },
        else => unreachable,
    }
}

pub fn isSealedName(name: Sym) bool {
    return std.mem.eql(u8, name.*, "f64") or std.mem.eql(u8, name.*, "i64");
}

pub fn isQualified(sym: Sym) bool {
    const text = sym.*;
    if (text.len == 0 or text[0] == '@') return false;
    const first_slash = std.mem.findScalar(u8, text, '/') orelse return false;
    if (first_slash == 0 or first_slash == text.len - 1) return false;
    if (std.mem.findScalar(u8, text[first_slash + 1 ..], '/') != null) return false;
    return true;
}

pub fn splitQualified(self: *Runtime, sym: Sym) Error!?struct { alias: Sym, name: Sym } {
    const text = sym.*;
    if (text.len == 0 or text[0] == '@') return null;
    const first_slash = std.mem.findScalar(u8, text, '/') orelse return null;
    if (first_slash == 0 or first_slash == text.len - 1) return null;
    if (std.mem.findScalar(u8, text[first_slash + 1 ..], '/') != null) return null;
    return .{
        .alias = try self.store.getsym(text[0..first_slash]),
        .name = try self.store.getsym(text[first_slash + 1 ..]),
    };
}

fn isUninitializedCellMarker(value: Value) bool {
    return value.typ == uninitialized_binding_marker.typ and
        value.obj == uninitialized_binding_marker.obj;
}

fn namespaceCellValue(value: Value) Error!Value {
    if (isUninitializedCellMarker(value)) return error.UninitializedBinding;
    return value;
}

/// Build a read-only, live view of a finished module's declared bindings.
/// Caller holds the scheduler lock and publishes the result atomically.
pub fn moduleExportView(self: *Runtime, process: *const sched_mod.Process) Error!Value {
    if (process.module_path == null or process.fib.ns.typ != b.type_namespace) {
        return error.InvalidCode;
    }
    const private = process.fib.ns;
    const source = private.obj.toRef().deref(Namespace);
    if (source.get != HashMapNamespace.vtable.get or process.exported.items.len > 1024) {
        return error.InvalidCode;
    }
    const private_map: *const HashMapNamespace = @ptrCast(@alignCast(source.data));
    const state = try self.static.create(ExportNamespace);
    state.* = ExportNamespace.init(self.static, private);
    try state.names.ensureUnusedCapacity(@intCast(process.exported.items.len));
    for (process.exported.items) |entry| {
        try self.context().chargeWork(@intCast(entry.external.*.len + 1), 1, .regvm);
        if (state.names.contains(entry.external)) return error.NameConflict;
        const exported: ExportNamespace.Source = switch (entry.source) {
            .local => |local| blk: {
                if (!private_map.bindings.contains(local)) return error.Unbound;
                break :blk .{ .namespace = private, .name = local };
            },
            .reexport => |via| blk: {
                const alias = private_map.bindings.get(via.alias) orelse return error.Unbound;
                if (alias.typ != b.type_namespace) return error.TypeMismatch;
                const public = alias.obj.toRef().deref(Namespace);
                if (public.get != ExportNamespace.vtable.get or
                    !public.contains(self, public, alias.obj, via.public)) return error.Unbound;
                break :blk .{ .namespace = alias, .name = via.public };
            },
        };
        state.names.putAssumeCapacityNoClobber(entry.external, exported);
    }

    const reference = try self.store.create(Namespace);
    self.store.store(Namespace, reference.deref(Namespace), ExportNamespace.vtable);
    reference.deref(Namespace).data = @ptrCast(state);
    return .namespace(reference.toObject());
}

/// Resolve `binding` in `ns`. `may_split` is the intern-time answer to "would
/// `splitQualified` split this name?"; passing false skips the `/` scan that
/// dominates a hot symbol read. Callers without a pool entry pass true.
pub fn nsGet(self: *Runtime, ns: Value, binding: Sym) Error!Value {
    return self.nsGetSplit(ns, binding, true);
}
fn nsGetSplit(self: *Runtime, ns: Value, binding: Sym, may_split: bool) Error!Value {
    return self.nsGetSplitDepth(ns, binding, may_split, 0);
}

fn nsGetSplitDepth(self: *Runtime, ns: Value, binding: Sym, may_split: bool, depth: u32) Error!Value {
    log.debug("nsGet {s}", .{binding.*});
    if (depth >= max_recursion_depth) return error.Unsupported;
    std.debug.assert(ns.typ == b.type_namespace);
    const ctx = self.context();
    if (ctx.reentry) |entry| {
        const value = try entry.lookup(entry.state, ctx, ns, binding);
        return namespaceCellValue(value);
    }
    if (!ctx.isUnrestricted()) return self.restrictedNamespaceRead(ctx, ns, binding);
    if (may_split) {
        if (try self.splitQualified(binding)) |q| {
            const alias_val = try self.nsGetSplitDepth(ns, q.alias, true, depth + 1);
            if (alias_val.typ != b.type_namespace) return error.TypeMismatch;
            return self.nsGetSplitDepth(alias_val, q.name, true, depth + 1);
        }
    }
    const ns_ptr = ns.obj.toRef().deref(Namespace);
    if (std.mem.startsWith(u8, binding.*, "@")) {
        return namespaceCellValue(try ns_ptr.get(self, ns_ptr, ns.obj, binding).unwrapError());
    }
    if (!builtinNamespace(ns_ptr)) {
        if (ns_ptr.contains(self, ns_ptr, ns.obj, binding)) {
            return namespaceCellValue(ns_ptr.get(self, ns_ptr, ns.obj, binding));
        }
        return namespaceCellValue(try ns_ptr.get(self, ns_ptr, ns.obj, binding).unwrapError());
    }
    // The own-cell memo is a pure lookup accelerator: it records a cell this
    // namespace already owns, so a hit is byte-identical to the scan below
    // and the walk still stops at exactly the same level, charging the same
    // work. Reentry, restricted contexts, and qualified names all returned
    // above, and an import edge or a parent is only consulted after a miss,
    // so none of those paths can be served — or skipped — by a memo entry.
    const use_cell_memo = self.compiler_opts.global and self.compiler_opts.namespace_lookup_cache;
    var cursor = ns;
    var table = ns_ptr;
    var known_builtin = true;
    for (depth..max_recursion_depth) |_| {
        try ctx.charge(.{ .work = 1 }, .regvm);
        if (!known_builtin) {
            if (table.contains(self, table, cursor.obj, binding)) {
                return namespaceCellValue(table.get(self, table, cursor.obj, binding));
            }
            return namespaceCellValue(try table.get(self, table, cursor.obj, binding).unwrapError());
        }

        if (table.get == HashMapNamespace.vtable.get) {
            const map: *const HashMapNamespace = @ptrCast(@alignCast(table.data));
            if (use_cell_memo) {
                if (map.peekCell(binding)) |value| return namespaceCellValue(value);
            }
            if (map.bindings.get(binding)) |value| {
                if (use_cell_memo) @constCast(map).rememberCell(binding, value);
                return namespaceCellValue(value);
            }
            if (map.imports.get(binding)) |imported| {
                return self.nsGetSplitDepth(imported.namespace, imported.name, true, depth + 1);
            }
            cursor = map.parent;
        } else if (table.get == SmallNamespace.vtable.get) {
            const small: *const SmallNamespace = @ptrCast(@alignCast(table.data));
            if (use_cell_memo) {
                if (small.peekCell(binding)) |value| return namespaceCellValue(value);
            }
            if (std.simd.firstIndexOfValue(small.bindings, @intFromPtr(binding))) |index| {
                const value = small.values[index];
                if (use_cell_memo) @constCast(small).rememberCell(binding, value);
                return namespaceCellValue(value);
            }
            cursor = small.parent;
        } else if (table.get == ExportNamespace.vtable.get) {
            const view: *const ExportNamespace = @ptrCast(@alignCast(table.data));
            const source = view.names.get(binding) orelse return error.Unbound;
            return namespaceCellValue(try source.read(self));
        } else return error.InvalidCode;
        if (cursor.typ != b.type_namespace) return error.Unbound;
        table = cursor.obj.toRef().deref(Namespace);
        // Classify each parent once; a foreign vtable keeps its own get and
        // contains behavior even when it is nested under a builtin table.
        known_builtin = builtinNamespace(table);
    }
    return error.Unbound;
}

pub fn restrictedNamespaceRead(self: *Runtime, ctx: *EvalContext, ns: Value, binding: Sym) Error!Value {
    return self.restrictedNamespaceReadWithWindow(ctx, ns, binding, null);
}

fn restrictedNamespaceReadWithWindow(
    self: *Runtime,
    ctx: *EvalContext,
    ns: Value,
    binding: Sym,
    work_window: ?*EvalContext.Budget.Lease.RegvmWindow,
) Error!Value {
    // A live window already checked the lineage and excludes sibling charges.
    if (work_window == null) try ctx.check();
    // The VM passes a window only for an unqualified, verified builtin read.
    // Qualified names can intern sub-symbols and must run outside the lock.
    const resolved = if (work_window) |window|
        self.resolveUnqualifiedDependency(ctx, ns, binding, 0, window) catch |err| {
            return if (err == error.Unsupported) error.Denied else err;
        }
    else blk: {
        const dependency = self.resolveDependency(ns, binding, 0) catch |err| {
            return if (err == error.Unsupported) error.Denied else err;
        };
        break :blk ResolvedNamespaceRead{
            .namespace = dependency.key.namespace,
            .binding = dependency.key.binding,
            .value = dependency.value,
        };
    };
    if (resolved.namespace == .null) return resolved.value;
    const owner = resolved.namespace.toRef().deref(Namespace).owner_context_id;
    if (ctx.identity != 0 and owner == ctx.identity) return resolved.value;
    if (ctx.execution != .pure_limited and ctx.effects.state_read == .allow) return resolved.value;
    return switch (resolved.value.typ) {
        b.type_intrinsic, b.type_method, b.type_type, b.type_closure => resolved.value,
        else => error.Denied,
    };
}

const BuiltinNamespaceKind = enum { hash, small, export_view };

fn builtinNamespaceKind(table: *const Namespace) ?BuiltinNamespaceKind {
    inline for (
        .{ HashMapNamespace.vtable, SmallNamespace.vtable, ExportNamespace.vtable },
        .{ BuiltinNamespaceKind.hash, .small, .export_view },
    ) |known, kind| {
        if (table.get == known.get and table.set == known.set and
            table.bind == known.bind and table.unbind == known.unbind and
            table.contains == known.contains and table.parent == known.parent) return kind;
    }
    return null;
}

fn builtinNamespace(table: *const Namespace) bool {
    return builtinNamespaceKind(table) != null;
}

fn authorizeNamespaceWrite(self: *Runtime, table: *const Namespace) Error!void {
    const ctx = self.context();
    try ctx.check();
    if (table.get == ExportNamespace.vtable.get) return error.Denied;
    if (ctx.isUnrestricted()) return;
    if (!builtinNamespace(table)) return error.Denied;
    if (ctx.identity != 0 and table.owner_context_id == ctx.identity) return;
    if (ctx.execution == .pure_limited or ctx.effects.state_write != .allow) return error.Denied;
}

/// Read an actual namespace cell without invoking foreign namespace vtables.
pub fn readDependency(self: *Runtime, ns: Value, binding: Sym) Error!Dependency {
    const resolved = try self.resolveDependency(ns, binding, 0);
    const entry = try self.dependency_cells.getOrPut(self.static, resolved.key);
    if (!entry.found_existing) {
        if (self.next_dependency_id == std.math.maxInt(u64)) {
            std.debug.assert(self.dependency_cells.remove(resolved.key));
            return error.Unsupported;
        }
        entry.value_ptr.* = .{ .id = self.next_dependency_id, .value = resolved.value };
        self.next_dependency_id += 1;
    }
    const cell = entry.value_ptr;
    if (cell.value.typ != resolved.value.typ or cell.value.obj != resolved.value.obj) {
        advanceDependency(cell);
        cell.value = resolved.value;
    }
    if (!cell.valid) return error.Unsupported;
    var result: Dependency = .{
        .cell_id = cell.id,
        .revision = cell.revision,
        .value = resolved.value,
    };
    if (resolved.value.typ == b.type_method) {
        const method = resolved.value.obj.toRef().deref(skript.data.Method);
        result.method_id = method.id;
        result.method_revision = method.revision;
    }
    return result;
}

pub fn validateDependency(self: *Runtime, ns: Value, binding: Sym, expected: Dependency) bool {
    const current = self.readDependency(ns, binding) catch return false;
    return current.cell_id == expected.cell_id and
        current.revision == expected.revision and
        current.method_id == expected.method_id and
        current.method_revision == expected.method_revision;
}

const ResolvedNamespaceRead = struct { namespace: Object, binding: Sym, value: Value };
const ResolvedDependency = struct { key: DependencyKey, value: Value };

fn resolveDependency(self: *Runtime, ns: Value, binding: Sym, depth: u32) Error!ResolvedDependency {
    if (depth >= max_recursion_depth) return error.Unsupported;
    if (ns.typ != b.type_namespace) return error.TypeMismatch;
    if (try self.splitQualified(binding)) |qualified| {
        const alias = try self.resolveDependency(ns, qualified.alias, depth + 1);
        return self.resolveDependency(alias.value, qualified.name, depth + 1);
    }
    const resolved = try self.resolveUnqualifiedDependency(self.context(), ns, binding, depth, null);
    return .{
        .key = .{ .namespace = resolved.namespace, .binding = resolved.binding },
        .value = resolved.value,
    };
}

fn resolveUnqualifiedDependency(
    self: *Runtime,
    ctx: *const EvalContext,
    ns: Value,
    binding: Sym,
    depth: u32,
    work_window: ?*EvalContext.Budget.Lease.RegvmWindow,
) Error!ResolvedNamespaceRead {
    // Keep one resolver body, but remove the nullable-window branch from each parent visit.
    if (work_window) |window| {
        return self.resolveUnqualifiedDependencyMode(true, ctx, ns, binding, depth, window);
    }
    return self.resolveUnqualifiedDependencyMode(false, ctx, ns, binding, depth, {});
}

fn resolveUnqualifiedDependencyMode(
    self: *Runtime,
    comptime locked: bool,
    ctx: *const EvalContext,
    ns: Value,
    binding: Sym,
    depth: u32,
    work_window: if (locked) *EvalContext.Budget.Lease.RegvmWindow else void,
) Error!ResolvedNamespaceRead {
    if (depth >= max_recursion_depth) return error.Unsupported;
    if (ns.typ != b.type_namespace) return error.TypeMismatch;
    if (std.mem.startsWith(u8, binding.*, "@")) {
        const name = binding.*[1..];
        const value = self.intrinsics.get(name) orelse self.constants.get(name) orelse return error.Unbound;
        return .{ .namespace = .null, .binding = binding, .value = value };
    }
    var cursor = ns;
    for (depth..max_recursion_depth) |_| {
        if (cursor.typ != b.type_namespace) {
            if (comptime locked) {
                try work_window.charge();
            } else {
                try ctx.charge(.{ .work = 1 }, .regvm);
            }
            return error.Unbound;
        }
        const table = cursor.obj.toRef().deref(Namespace);
        // Check the full vtable before direct access or a locked namespace debit.
        const kind = builtinNamespaceKind(table) orelse {
            if (comptime locked) {
                try work_window.charge();
            } else {
                try ctx.charge(.{ .work = 1 }, .regvm);
            }
            return error.Unsupported;
        };
        if (comptime locked) {
            try work_window.chargeNamespaceAccess(namespaceAccessWork(table, false));
        } else if (ctx.lease) |lease| {
            const access_work = namespaceAccessWork(table, false);
            try lease.chargeSequentialWork(&.{ 1, access_work }, .regvm);
        }
        const local: ?Value = switch (kind) {
            .hash => blk: {
                const map: *const HashMapNamespace = @ptrCast(@alignCast(table.data));
                if (map.bindings.get(binding)) |value| break :blk value;
                if (map.imports.get(binding)) |imported| {
                    return self.resolveUnqualifiedDependencyMode(
                        locked,
                        ctx,
                        imported.namespace,
                        imported.name,
                        depth + 1,
                        work_window,
                    );
                }
                break :blk null;
            },
            .small => blk: {
                const small: *const SmallNamespace = @ptrCast(@alignCast(table.data));
                const index = std.simd.firstIndexOfValue(small.bindings, @intFromPtr(binding)) orelse break :blk null;
                break :blk small.values[index];
            },
            .export_view => blk: {
                const view: *const ExportNamespace = @ptrCast(@alignCast(table.data));
                if (view.names.get(binding)) |source| {
                    return self.resolveUnqualifiedDependencyMode(
                        locked,
                        ctx,
                        source.namespace,
                        source.name,
                        depth + 1,
                        work_window,
                    );
                }
                break :blk null;
            },
        };
        if (local) |value| {
            return .{
                .namespace = cursor.obj,
                .binding = binding,
                .value = try namespaceCellValue(value),
            };
        }
        cursor = switch (kind) {
            .hash => @as(*const HashMapNamespace, @ptrCast(@alignCast(table.data))).parent,
            .small => @as(*const SmallNamespace, @ptrCast(@alignCast(table.data))).parent,
            .export_view => @as(*const ExportNamespace, @ptrCast(@alignCast(table.data))).parent,
        };
    }
    return error.Unsupported;
}

fn advanceDependency(cell: *DependencyCell) void {
    if (cell.revision == std.math.maxInt(u64)) {
        cell.valid = false;
    } else {
        cell.revision += 1;
    }
}

fn dependencyWritten(self: *Runtime, ns: Value, binding: Sym, value: Value) void {
    if (self.dependency_cells.count() == 0) return;
    const key: DependencyKey = .{ .namespace = ns.obj, .binding = binding };
    if (self.dependency_cells.getPtr(key)) |cell| {
        advanceDependency(cell);
        cell.value = value;
    }
}

pub fn nsSet(self: *Runtime, ns: Value, binding: Sym, value: Value) Error!void {
    log.debug("nsSet {any} {s}", .{ ns, binding.* });
    if (isSealedName(binding)) return error.Denied;
    std.debug.assert(ns.typ == b.type_namespace);
    const ns_ptr = ns.obj.toRef().deref(Namespace);
    try self.authorizeNamespaceWrite(ns_ptr);
    try chargeNamespaceAccess(self.context(), ns_ptr, false);
    const result = ns_ptr.set(self, ns_ptr, ns.obj, binding, value);
    if (result.typ == b.type_error) return result.errorCode();
    self.dependencyWritten(ns, binding, value);
}

/// Update the nearest namespace cell that already binds `binding`.
pub fn nsAssign(self: *Runtime, ns: Value, binding: Sym, value: Value) Error!void {
    if (ns.typ != b.type_namespace) return error.TypeMismatch;
    if (std.mem.startsWith(u8, binding.*, "@")) return error.Unbound;
    if (isSealedName(binding)) return error.Denied;
    if (try self.splitQualified(binding)) |qualified| {
        const alias = try self.nsGet(ns, qualified.alias);
        if (alias.typ != b.type_namespace) return error.TypeMismatch;
        return self.nsAssign(alias, qualified.name, value);
    }

    var cursor = ns;
    for (0..max_recursion_depth) |_| {
        try self.context().charge(.{ .work = 1 }, .regvm);
        if (cursor.typ != b.type_namespace) return error.Unbound;
        const table = cursor.obj.toRef().deref(Namespace);
        if (table.contains(self, table, cursor.obj, binding)) {
            return self.nsSet(cursor, binding, value);
        }
        cursor = table.parent(self, table, cursor.obj);
    }
    return error.Unsupported;
}

pub fn nsBind(self: *Runtime, ns: Value, binding: Sym, value: Value) Error!void {
    std.debug.assert(ns.typ == b.type_namespace);
    if (isSealedName(binding)) return error.Denied;
    const ns_ptr = ns.obj.toRef().deref(Namespace);
    try self.authorizeNamespaceWrite(ns_ptr);
    try chargeNamespaceAccess(self.context(), ns_ptr, true);
    _ = try ns_ptr.bind(self, ns_ptr, ns.obj, binding, value).unwrapError();
    self.dependencyWritten(ns, binding, value);
}

pub fn nsUnbind(self: *Runtime, ns: Value, binding: Sym) Error!void {
    std.debug.assert(ns.typ == b.type_namespace);
    if (isSealedName(binding)) return error.Denied;
    const ns_ptr = ns.obj.toRef().deref(Namespace);
    try self.authorizeNamespaceWrite(ns_ptr);
    try chargeNamespaceAccess(self.context(), ns_ptr, false);
    _ = try ns_ptr.unbind(self, ns_ptr, ns.obj, binding).unwrapError();
    self.dependencyWritten(ns, binding, .nil);
}

pub fn nsContains(self: *Runtime, ns: Value, binding: Sym) bool {
    std.debug.assert(ns.typ == b.type_namespace);
    const ns_ptr = ns.obj.toRef().deref(Namespace);
    return ns_ptr.contains(self, ns_ptr, ns.obj, binding);
}

fn namespaceAccessWork(table: *const Namespace, growing: bool) u64 {
    if (table.get == HashMapNamespace.vtable.get) {
        const namespace: *const HashMapNamespace = @ptrCast(@alignCast(table.data));
        const bound = @as(u64, @max(namespace.bindings.capacity(), namespace.imports.capacity())) + 1;
        return bound * (if (growing) bound else 2);
    } else {
        return @typeInfo(@FieldType(SmallNamespace, "bindings")).vector.len;
    }
}

fn chargeNamespaceAccess(ctx: *const EvalContext, table: *const Namespace, growing: bool) Error!void {
    if (ctx.lease == null) return;
    const work = namespaceAccessWork(table, growing);
    try ctx.chargeWork(work, 1, .regvm);
}

const ClosureCallShape = struct {
    fixed_count: usize,
    has_rest: bool,
};

fn closureCallShape(closure: *const Closure) Error!ClosureCallShape {
    if (closure.code) |code| {
        const function = code.function(closure.function_id) orelse return error.InvalidCode;
        const parameter_count = std.math.cast(usize, function.parameter_count) orelse return error.InvalidCode;
        if (parameter_count != closure.arglist.len) return error.InvalidCode;
        if (function.has_rest) {
            if (parameter_count == 0) return error.InvalidCode;
            return .{ .fixed_count = parameter_count - 1, .has_rest = true };
        }
    }
    return .{ .fixed_count = closure.arglist.len, .has_rest = false };
}

fn prepareClosureArgs(
    ctx: *EvalContext,
    closure: *const Closure,
    args: []const Value,
    storage: []Value,
) Error![]const Value {
    const shape = try closureCallShape(closure);
    if (args.len < shape.fixed_count or (!shape.has_rest and args.len != shape.fixed_count)) {
        return error.ArityMismatch;
    }
    if (!shape.has_rest) return args;
    if (storage.len < closure.arglist.len) return error.InvalidCode;

    const rest_count = args.len - shape.fixed_count;
    try ctx.chargeWork(
        std.math.cast(u64, rest_count) orelse return error.Unsupported,
        1,
        .regvm,
    );
    var rest: Value = .nil;
    var index = args.len;
    while (index > shape.fixed_count) {
        index -= 1;
        const cell = try ctx.runtime.store.create([2]Value);
        ctx.runtime.store.store([2]Value, cell.deref([2]Value), .{ args[index], rest });
        rest = .cons(cell.toObject());
    }
    storage[shape.fixed_count] = rest;
    if (storage.ptr != args.ptr) @memcpy(storage[0..shape.fixed_count], args[0..shape.fixed_count]);
    return storage[0..closure.arglist.len];
}

pub fn bindClosureArgs(self: *Runtime, closure: *Closure, args: []const Value) Error!Value {
    var call_args_storage: [256]Value = undefined;
    const call_args = try prepareClosureArgs(self.context(), closure, args, &call_args_storage);
    const ns_ref = try self.store.create(Namespace);
    const ns_obj = ns_ref.toObject();
    const res_ns = Value.namespace(ns_obj);
    const arglist = closure.arglist;

    if (arglist.len > SmallNamespace.size) {
        self.store.store(Namespace, ns_ref.deref(Namespace), HashMapNamespace.vtable);
        const map = try self.static.create(HashMapNamespace);
        map.* = try HashMapNamespace.init(self.static, closure.parent_ns);
        ns_ref.deref(Namespace).data = @ptrCast(map);
        self.ownNamespace(res_ns);
        for (arglist, 0..) |sym, index| {
            try self.nsBind(res_ns, sym, call_args[index]);
        }
        return res_ns;
    }

    self.store.store(Namespace, ns_ref.deref(Namespace), SmallNamespace.vtable);
    const small = try self.static.create(SmallNamespace);
    small.* = SmallNamespace{ .parent = closure.parent_ns };
    ns_ref.deref(Namespace).data = @ptrCast(small);
    self.ownNamespace(res_ns);
    // Direct lane writes are safe: the struct literal above reset the whole
    // namespace, so no memo entry exists yet, and every later mutation of
    // these cells goes through `set`/`bind`/`unbind`, which retire it.
    small.bindings = @splat(0);
    inline for (0..SmallNamespace.size) |index| {
        if (index < arglist.len) small.bindings[index] = @intFromPtr(arglist[index]);
    }
    for (arglist, 0..) |_, index| {
        small.values[index] = call_args[index];
    }
    return res_ns;
}

/// Reusable register storage for native kernels and host calls.
/// Returned values belong to the Runtime; no tuple is allocated for results.
pub const CallWorkspace = struct {
    allocator: Allocator,
    stack: []Object = &.{},
    exceptions: List(ExnFrame) = .empty,
    busy: bool = false,

    pub fn init(allocator: Allocator) CallWorkspace {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CallWorkspace) void {
        std.debug.assert(!self.busy);
        self.allocator.free(self.stack);
        self.exceptions.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn apply(
        self: *CallWorkspace,
        ctx: *EvalContext,
        callable: Value,
        args: []const Value,
        outputs: []Value,
    ) Error!void {
        if (ctx.mode != .concrete or ctx.reentry != null) return error.Unsupported;
        if (callable.typ != b.type_closure) return error.TypeMismatch;
        var call_context = try ctx.enter(.regvm);
        call_context.allow_suspend = false;
        const scope = call_context.activate();
        defer scope.deinit();
        try call_context.chargeWork(args.len, 1, .regvm);
        self.run(&call_context, callable.obj.toRef().deref(Closure), args, outputs) catch |err| {
            try call_context.check();
            return err;
        };
        try call_context.check();
    }

    fn run(
        self: *CallWorkspace,
        ctx: *EvalContext,
        closure: *Closure,
        args: []const Value,
        outputs: []Value,
    ) Error!void {
        if (self.busy) return error.Denied;
        if (outputs.len == 0 or outputs.len != closure.result_count) return error.ArityMismatch;
        if (closure.ir.len == 0 or closure.nregs == 0) return error.InvalidCode;
        if (closure.arglist.len + closure.captures.len + 1 > closure.nregs) return error.InvalidCode;
        try ctx.runtime.checkClosureGuard(closure, args);
        var call_args_storage: [256]Value = undefined;
        const call_args = try prepareClosureArgs(ctx, closure, args, &call_args_storage);
        const count = @max(@as(usize, closure.nregs), outputs.len);
        const frame_objects = frame_size + count * 2;
        if (self.stack.len < frame_objects * 2) {
            self.stack = try self.allocator.realloc(self.stack, frame_objects * 2);
        }
        const acquired_guard = try ctx.runtime.acquireClosureGuard(closure);
        self.busy = true;
        defer self.busy = false;
        const stop = regvm.Inst.make(.stop, 0);
        var fiber = self.prepareFiber(closure, call_args, frame_objects, &stop, acquired_guard);
        defer {
            self.stack = fiber.stack;
            self.exceptions = fiber.exn_stack;
            self.exceptions.clearRetainingCapacity();
        }
        defer ctx.runtime.releaseFiberGuards(&fiber);
        while (true) switch (try ctx.runtime.evalReg(fiber.ns, &fiber, std.math.maxInt(u32))) {
            .done => {
                for (outputs, 0..) |*output, index| output.* = fiber.getReg(@intCast(index));
                return;
            },
            .yielded => continue,
            .suspended => return error.WouldBlock,
        };
    }

    fn prepareFiber(
        self: *CallWorkspace,
        closure: *Closure,
        args: []const Value,
        frame_objects: usize,
        stop: *const regvm.Inst,
        guard: ?*const ClosureGuard,
    ) Fiber {
        const frame: FrameReg = .{
            .prev_ap = 0,
            .prev_fp = 0,
            .prev_sp = frame_objects,
            .consts = closure.constants,
            .ns = closure.parent_ns,
            .prev_fns = &.{},
            .ret_reg = 0,
            .result_count = closure.result_count,
            .ret_addr = @ptrCast(stop),
            .guard = guard,
            .prev_guard = null,
            .prev_closure = null,
            .prev_nregs = @intCast((frame_objects - frame_size) / 2),
            .prev_ir = &.{},
            .prev_src_idx = 0,
        };
        @as(*FrameReg, @ptrCast(self.stack.ptr)).* = frame;
        var fiber: Fiber = .{
            .stack = self.stack,
            .stack_allocator = self.allocator,
            .exn_stack = self.exceptions,
            .sp = frame_objects,
            .ip = closure.ir.ptr,
            .ir = closure.ir,
            .nregs = closure.nregs,
            .consts = closure.constants,
            .fns = closure.fns,
            .ns = closure.parent_ns,
            .current_closure = closure,
            .active_guard = guard,
            .call_depth = 1,
        };
        fiber.setReg(0, .nil);
        for (args, 0..) |argument, index| fiber.setReg(@intCast(index + 1), argument);
        for (closure.captures, 0..) |capture, index| {
            fiber.setReg(@intCast(closure.arglist.len + index + 1), capture);
        }
        for (closure.arglist.len + closure.captures.len + 1..closure.nregs) |index| {
            fiber.setReg(@intCast(index), .nil);
        }
        return fiber;
    }
};

fn runClosure(self: *Runtime, closure: *Closure, args: []const Value) Error!Value {
    if (closure.result_count != 1) return error.Unsupported;
    var workspace = CallWorkspace.init(self.context().scratch);
    defer workspace.deinit();
    var outputs: [1]Value = undefined;
    try workspace.run(self.context(), closure, args, &outputs);
    return outputs[0];
}

pub fn applyResultsWithContext(
    self: *Runtime,
    ctx: *EvalContext,
    callable: Value,
    args: []const Value,
    outputs: []Value,
) Error!void {
    if (ctx.runtime != self) return error.Denied;
    var workspace = CallWorkspace.init(ctx.scratch);
    defer workspace.deinit();
    try workspace.apply(ctx, callable, args, outputs);
}

/// Reject closure guards with mismatched acquire and release callbacks.
pub fn validateClosureGuard(guard: *const ClosureGuard) Error!void {
    const has_acquire = guard.acquire != null;
    const has_release = guard.release != null;
    if (has_acquire != has_release) return error.InvalidCode;
}

fn acquireClosureGuard(self: *Runtime, closure: *const Closure) Error!?*const ClosureGuard {
    const guard = closure.guard orelse return null;
    try validateClosureGuard(guard);
    if (guard.acquire) |acquire| {
        try acquire(self, guard.context);
        return guard;
    }
    return null;
}

/// Release a guard after validation, including during VM unwind.
pub fn releaseClosureGuard(self: *Runtime, guard: *const ClosureGuard) void {
    // Invalid pairs are rejected before acquisition. Keep terminal cleanup
    // defensive for host-built fibers that may carry malformed metadata.
    if (guard.acquire == null and guard.release == null) return;
    if (guard.acquire == null or guard.release == null) return;
    if (guard.release) |release| release(self, guard.context);
}

pub fn inheritClosureGuard(self: *Runtime, parent: *const ClosureGuard) Error!*const ClosureGuard {
    try validateClosureGuard(parent);
    if (parent.check_arguments == null) return parent;
    const inherited = try self.static.create(ClosureGuard);
    inherited.* = .{
        .context = parent.context,
        .check = parent.check,
        // Nested make_closure has its own argument list. Preserve the
        // parent's non-argument check and lifecycle only.
        .check_arguments = null,
        .trace = parent.trace,
        .acquire = parent.acquire,
        .release = parent.release,
    };
    return inherited;
}
fn releaseFramesUntil(self: *Runtime, fib: *Fiber, target_fp: usize) void {
    while (fib.current_closure != null and fib.fp != target_fp) {
        if (fib.fp > fib.stack.len or frame_size > fib.stack.len - fib.fp) {
            if (fib.active_guard) |guard| self.releaseClosureGuard(guard);
            fib.active_guard = null;
            fib.current_closure = null;
            return;
        }
        const frame: *const FrameReg = @ptrCast(fib.stack[fib.fp..].ptr);
        const guard = fib.active_guard orelse frame.guard;
        if (guard) |held| self.releaseClosureGuard(held);
        fib.active_guard = frame.prev_guard;
        fib.current_closure = frame.prev_closure;
        fib.fp = frame.prev_fp;
    }
}

/// Release every invocation lease owned by a terminal or cancelled fiber.
/// This method is intentionally idempotent: scheduler completion and runtime
/// teardown can both observe the same process.
pub fn releaseFiberGuards(self: *Runtime, fib: *Fiber) void {
    fib.clearPendingApply();
    if (fib.guards_released) return;
    var guard = fib.active_guard;
    var closure = fib.current_closure;
    var fp = fib.fp;
    while (true) {
        if (closure == null) {
            if (guard) |held| self.releaseClosureGuard(held);
            break;
        }
        if (fp > fib.stack.len or frame_size > fib.stack.len - fp) {
            if (guard) |held| self.releaseClosureGuard(held);
            break;
        }
        const frame: *const FrameReg = @ptrCast(fib.stack[fp..].ptr);
        const current = guard orelse frame.guard;
        if (current) |held| self.releaseClosureGuard(held);
        guard = frame.prev_guard;
        closure = frame.prev_closure;
        fp = frame.prev_fp;
    }
    fib.guards_released = true;
}

fn checkClosureGuard(self: *Runtime, closure: *const Closure, args: []const Value) Error!void {
    const ctx = self.context();
    try ctx.check();
    if (ctx.registry.closure_specs.count() != 0 and !ctx.isUnrestricted()) {
        const header: *const Store.Header = @ptrFromInt(@intFromPtr(closure) - Store.header_size);
        const reference = Store.Ref.fromAddr(closure, header.tag);
        if (ctx.registry.closureSpec(reference)) |spec| {
            switch (try ctx.authorize(spec)) {
                .invoke => {},
                .model => return error.Unsupported,
            }
        }
    }
    if (closure.guard) |guard| {
        try validateClosureGuard(guard);
        try guard.check(self, guard.context);
        if (guard.check_arguments) |check_arguments| try check_arguments(self, guard.context, args);
    }
}

pub fn context(self: *Runtime) *EvalContext {
    if (EvalContext.active) |active| {
        if (active.runtime == self) return active;
    }
    self.trusted_context.registry = self.intrinsics.registryVersion();
    self.trusted_context.output.writer = self.stdout orelse &self.fallback_stdout.interface;
    return &self.trusted_context;
}

fn invokeNative(self: *Runtime, native: FuncPtr, ns: Value, object: Value, args: []const Value) Error!Value {
    const ctx = self.context();
    try ctx.check();
    if (Symbolic.hasExpr(args)) {
        const callable = Value.intrinsic(native);
        if (Symbolic.accepts(ctx, callable)) return Symbolic.apply(ctx, ns, callable, args);
    }
    const was_native = ctx.in_native;
    ctx.in_native = true;
    defer ctx.in_native = was_native;
    if (ctx.isUnrestricted()) return native(ctx, ns, object, args) catch |err| {
        if (err == error.WouldBlock and ctx.native_reentry) return error.Denied;
        return err;
    };
    const id = ctx.registry.idForNative(native) orelse return error.Denied;
    const spec = ctx.registry.spec(id) orelse return error.Denied;
    const authorization = try ctx.authorize(spec);
    var reservation = switch (authorization) {
        .invoke => |credit| credit,
        .model => return error.Unsupported,
    };
    // Apply's target is routed through ordinary callable dispatch, which
    // checks its own policy. The generic callback preflight is AD-purity
    // validation and would reject allowed effectful or suspending targets.
    if (ctx.execution != .trusted and native != &intrin.list.apply) {
        try self.preflightNativeCallback(ns, spec.callbacks, args);
    }
    var call_context = try ctx.forPrimitive(&reservation);
    call_context.in_native = true;
    const scope = call_context.activate();
    defer scope.deinit();
    const result = native(&call_context, ns, object, args) catch |err| {
        try call_context.check();
        if (err == error.WouldBlock and !reservation.allow_suspend) return error.Denied;
        return err;
    };
    try call_context.check();
    return result;
}

fn preflightNativeCallback(
    self: *Runtime,
    ns: Value,
    callback: skript.Primitive.Callback,
    args: []const Value,
) Error!void {
    const index: usize = switch (callback) {
        .none => return,
        .argument => |index| index,
        .last => if (args.len == 0) return else args.len - 1,
        .collection_fold => if (args.len == 0) return else args.len - 1,
        .unknown, .type_hook => return error.Denied,
    };
    if (index >= args.len) return;
    const value = args[index];
    switch (value.typ) {
        b.type_closure, b.type_intrinsic, b.type_method, b.type_type, b.type_ffifunc => {},
        else => return,
    }
    try AdEffects.preflight(self, ns, value);
}

pub fn applyWithContext(self: *Runtime, ctx: *EvalContext, ns: Value, func: Value, args: []const Value) Error!Value {
    return self.applyWithContextWorkspace(ctx, ns, func, args, null);
}

/// Reuse one VM frame buffer across native tensor callbacks without changing
/// symbolic dispatch, effect policy, or budget accounting.
pub fn applyWithWorkspace(
    self: *Runtime,
    ctx: *EvalContext,
    ns: Value,
    func: Value,
    args: []const Value,
    workspace: *CallWorkspace,
) Error!Value {
    return self.applyWithContextWorkspace(ctx, ns, func, args, workspace);
}

fn applyWithContextWorkspace(
    self: *Runtime,
    ctx: *EvalContext,
    ns: Value,
    func: Value,
    args: []const Value,
    workspace: ?*CallWorkspace,
) Error!Value {
    if (ctx.runtime != self) return error.Denied;
    if (ctx.reentry) |entry| return entry.apply(entry.state, ctx, ns, func, args);
    if (ctx.mode != .concrete) return skript.Evaluator.apply(ctx, ns, func, args);
    var call_context = try ctx.enter(.regvm);
    const scope = call_context.activate();
    defer scope.deinit();
    try call_context.chargeWork(args.len, 1, .regvm);
    const result = self.applyActiveInWorkspace(&call_context, ns, func, args, workspace) catch |err| {
        try call_context.check();
        return err;
    };
    try call_context.check();
    return result;
}

fn applyActiveInWorkspace(
    self: *Runtime,
    ctx: *EvalContext,
    ns: Value,
    func: Value,
    args: []const Value,
    workspace: ?*CallWorkspace,
) Error!Value {
    if (workspace) |shared| {
        if (func.typ == b.type_closure and !Symbolic.hasExpr(args)) {
            const closure = func.obj.toRef().deref(Closure);
            if (closure.result_count != 1) return error.Unsupported;
            var outputs: [1]Value = undefined;
            try shared.run(ctx, closure, args, &outputs);
            return outputs[0];
        }
    }
    return self.applyActive(ns, func, args);
}

pub fn apply(self: *Runtime, ns: Value, func: Value, args: []const Value) Error!Value {
    return self.applyWithContext(self.context(), ns, func, args);
}

fn applyActive(self: *Runtime, ns: Value, func: Value, args: []const Value) Error!Value {
    if ((func.typ == b.type_closure or func.typ == b.type_method) and Symbolic.hasExpr(args)) {
        return Symbolic.apply(self.context(), ns, func, args);
    }
    log.debug(
        "Applying value type={} to {} arguments",
        .{ @intFromEnum(func.typ), args.len },
    );
    var res: Value = .nil;
    defer log.debug("Apply returned value type={}", .{@intFromEnum(res.typ)});
    switch (func.typ) {
        b.type_closure => {
            const cl_ptr = func.obj.toRef().deref(Closure);
            res = try self.runClosure(cl_ptr, args);
        },
        b.type_intrinsic => {
            const z_intr = tracy.Zone.begin(.{ .name = "apply-intrinsic", .src = @src() });
            defer z_intr.end();
            res = try self.invokeNative(func.obj.toPtr(FuncPtr), ns, func, args);
        },
        b.type_ffifunc => {
            res = try intrin.ffi.invoke(self.context(), func, args);
        },
        b.type_type => {
            const type_ptr = self.typePtrFromObj(func.obj);
            const apply_fn = type_ptr.apply;
            if (apply_fn.isNil()) return error.Unimplemented;
            res = try self.apply(ns, apply_fn, args);
        },
        b.type_method => {
            const method_ptr = func.obj.toRef().deref(skript.data.Method);
            const dispatched = try method_ptr.get(self, args);
            res = try self.apply(ns, dispatched, args);
        },
        b.type_keyword => {
            // Keyword-as-getter: (:sym NS) — exactly one argument. The stack
            // VM's evalNode .Call routes through apply.
            if (args.len != 1) return error.ArityMismatch;
            if (args[0].typ != b.type_namespace) return error.TypeMismatch;
            const kw_sym = func.obj.toPtr(Sym);
            res = try self.nsGet(args[0], kw_sym);
        },
        else => return error.Unimplemented,
    }
    return res;
}
/// Parse and evaluate `src` through the register VM.
pub fn evalString(self: *Runtime, src: []const u8) Error!Value {
    return self.evalStringWithContext(self.context(), src);
}

pub fn evalStringWithContext(self: *Runtime, ctx: *EvalContext, src: []const u8) Error!Value {
    if (ctx.runtime != self) return error.Denied;
    if (ctx.reentry) |entry| return entry.source(entry.state, ctx, src);
    if (ctx.mode != .concrete) return skript.Evaluator.evalString(ctx, src);
    var call_context = try ctx.enter(.reader);
    const scope = call_context.activate();
    defer scope.deinit();
    return self.evalStringActive(src) catch |err| {
        try call_context.check();
        return err;
    };
}

fn evalStringActive(self: *Runtime, src: []const u8) Error!Value {
    const parsed = try skript.Reader.readUnit(
        self.store,
        src,
        .{ .retention = self.source_retention },
    );
    const forms = parsed.datum;
    const prog = try self.compileData(self.root_ns, forms, null);
    const stack = try self.static.alloc(Object, frame_size + @as(usize, prog.nregs) * 2);
    @memset(stack, .null);
    var fib: Fiber = .{
        .stack = stack,
        .sp = frame_size + @as(usize, prog.nregs) * 2,
        .ip = prog.ir.ptr,
        .ir = prog.ir,
        .nregs = prog.nregs,
        .consts = prog.constants,
        .fns = prog.fns,
        .ns = self.root_ns,
    };
    const res = try self.runToCompletion(self.root_ns, &fib);
    if (res.typ == b.type_error) {
        return res.errorCode();
    }
    return res;
}

const GuardLifecycleProbe = struct {
    open: bool = true,
    deny_acquire: bool = false,
    users: u32 = 0,
    checks: u32 = 0,
    argument_checks: u32 = 0,
    acquire_attempts: u32 = 0,
    acquires: u32 = 0,
    releases: u32 = 0,
    double_releases: u32 = 0,
    max_users: u32 = 0,
    saw_held: bool = false,
    saw_released: bool = false,
    reclaimed: bool = false,
    expected_arguments: ?usize = null,

    fn mutable(guard_context: *const anyopaque) *GuardLifecycleProbe {
        return @ptrCast(@alignCast(@constCast(guard_context)));
    }

    fn check(_: *Runtime, guard_context: *const anyopaque) Error!void {
        const probe = mutable(guard_context);
        probe.checks += 1;
        if (!probe.open) return error.Expired;
    }

    fn checkArguments(
        _: *Runtime,
        guard_context: *const anyopaque,
        arguments: []const Value,
    ) Error!void {
        const probe = mutable(guard_context);
        probe.argument_checks += 1;
        if (probe.expected_arguments) |expected| {
            if (arguments.len != expected) return error.ArityMismatch;
        }
    }

    fn acquire(_: *Runtime, guard_context: *const anyopaque) Error!void {
        const probe = mutable(guard_context);
        probe.acquire_attempts += 1;
        if (probe.deny_acquire) return error.Denied;
        if (!probe.open) return error.Expired;
        probe.users += 1;
        probe.acquires += 1;
        probe.max_users = @max(probe.max_users, probe.users);
    }

    fn release(_: *Runtime, guard_context: *const anyopaque) void {
        const probe = mutable(guard_context);
        if (probe.users == 0) {
            probe.double_releases += 1;
            return;
        }
        probe.users -= 1;
        probe.releases += 1;
        if (!probe.open and probe.users == 0) probe.reclaimed = true;
    }

    fn guard(self: *GuardLifecycleProbe) skript.data.ClosureGuard {
        return .{
            .context = self,
            .check = &check,
            .check_arguments = &checkArguments,
            .acquire = &acquire,
            .release = &release,
        };
    }
};

fn guardTestProbe(arguments: []const Value, index: usize) Error!*GuardLifecycleProbe {
    if (arguments.len <= index) return error.ArityMismatch;
    if (arguments[index].typ != b.type_opaque) return error.TypeMismatch;
    return arguments[index].obj.toPtr(*GuardLifecycleProbe);
}

fn guardTestClose(
    _: *EvalContext,
    _: Value,
    _: Value,
    arguments: []const Value,
) Error!Value {
    if (arguments.len != 1) return error.ArityMismatch;
    const probe = try guardTestProbe(arguments, 0);
    probe.saw_held = probe.users == 1 and probe.releases == 0;
    probe.open = false;
    return .i64(7);
}

fn guardTestObserveHeld(
    _: *EvalContext,
    _: Value,
    _: Value,
    arguments: []const Value,
) Error!Value {
    if (arguments.len != 1) return error.ArityMismatch;
    const probe = try guardTestProbe(arguments, 0);
    probe.saw_held = probe.saw_held or probe.users == 1;
    return .i64(11);
}

fn guardTestObserveReleased(
    _: *EvalContext,
    _: Value,
    _: Value,
    arguments: []const Value,
) Error!Value {
    if (arguments.len != 1) return error.ArityMismatch;
    const probe = try guardTestProbe(arguments, 0);
    probe.saw_released = probe.users == 0 and probe.acquires == probe.releases;
    return .true;
}

fn guardTestObserveTail(
    _: *EvalContext,
    _: Value,
    _: Value,
    arguments: []const Value,
) Error!Value {
    if (arguments.len != 2) return error.ArityMismatch;
    const retired = try guardTestProbe(arguments, 0);
    const active = try guardTestProbe(arguments, 1);
    retired.saw_released = retired.users == 0 and retired.releases == 1;
    active.saw_held = active.users == 1 and active.releases == 0;
    return .i64(13);
}

fn guardTestFail(
    _: *EvalContext,
    _: Value,
    _: Value,
    _: []const Value,
) Error!Value {
    return error.TypeMismatch;
}

fn bindGuardTestValue(runtime: *Runtime, name: []const u8, value: Value) Error!void {
    try runtime.nsBind(runtime.root_ns, try runtime.store.getsym(name), value);
}

fn attachGuard(value: Value, guard: *const skript.data.ClosureGuard) *Closure {
    std.debug.assert(value.typ == b.type_closure);
    const closure = value.obj.toRef().deref(Closure);
    closure.guard = guard;
    return closure;
}

test "closure guard: held close, repeat calls, and denied acquire balance" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();

    var held_probe: GuardLifecycleProbe = .{};
    var held_guard = held_probe.guard();
    try bindGuardTestValue(runtime, "guard-test-close", .intrinsic(&guardTestClose));
    try bindGuardTestValue(runtime, "guard-test-held", .opaq(.fromPtr(&held_probe)));
    const held_value = try runtime.evalString(
        "(fn () (guard-test-close guard-test-held))",
    );
    _ = attachGuard(held_value, &held_guard);

    try std.testing.expectEqual(
        Value.i64(7),
        try runtime.apply(runtime.root_ns, held_value, &.{}),
    );
    try std.testing.expect(held_probe.saw_held);
    try std.testing.expect(!held_probe.open);
    try std.testing.expect(held_probe.reclaimed);
    try std.testing.expectEqual(@as(u32, 1), held_probe.acquires);
    try std.testing.expectEqual(@as(u32, 1), held_probe.releases);
    try std.testing.expectEqual(@as(u32, 0), held_probe.users);
    try std.testing.expectError(
        error.Expired,
        runtime.apply(runtime.root_ns, held_value, &.{}),
    );
    try std.testing.expectEqual(@as(u32, 1), held_probe.acquire_attempts);

    var repeat_probe: GuardLifecycleProbe = .{};
    var repeat_guard = repeat_probe.guard();
    const repeat_value = try runtime.evalString("(fn (x) (+ x 1))");
    _ = attachGuard(repeat_value, &repeat_guard);
    try std.testing.expectEqual(
        Value.i64(2),
        try runtime.apply(runtime.root_ns, repeat_value, &.{Value.i64(1)}),
    );
    try std.testing.expectEqual(
        Value.i64(3),
        try runtime.apply(runtime.root_ns, repeat_value, &.{Value.i64(2)}),
    );
    try std.testing.expectEqual(@as(u32, 2), repeat_probe.acquires);
    try std.testing.expectEqual(@as(u32, 2), repeat_probe.releases);
    try std.testing.expectEqual(@as(u32, 0), repeat_probe.users);
    try std.testing.expectEqual(@as(u32, 0), repeat_probe.double_releases);

    try std.testing.expectError(
        error.ArityMismatch,
        runtime.apply(runtime.root_ns, repeat_value, &.{}),
    );
    try std.testing.expectEqual(@as(u32, 2), repeat_probe.acquire_attempts);

    repeat_probe.deny_acquire = true;
    try std.testing.expectError(
        error.Denied,
        runtime.apply(runtime.root_ns, repeat_value, &.{Value.i64(3)}),
    );
    try std.testing.expectEqual(@as(u32, 3), repeat_probe.acquire_attempts);
    try std.testing.expectEqual(@as(u32, 2), repeat_probe.acquires);
    try std.testing.expectEqual(@as(u32, 2), repeat_probe.releases);
    try std.testing.expectEqual(@as(u32, 0), repeat_probe.users);
}

test "closure guard: nested closures inherit lifecycle but not argument checks" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();

    var probe: GuardLifecycleProbe = .{ .expected_arguments = 0 };
    var guard = probe.guard();
    const outer = try runtime.evalString("(fn () (fn (x) x))");
    _ = attachGuard(outer, &guard);

    const nested = try runtime.apply(runtime.root_ns, outer, &.{});
    try std.testing.expectEqual(
        Value.i64(19),
        try runtime.apply(runtime.root_ns, nested, &.{Value.i64(19)}),
    );
    try std.testing.expectEqual(@as(u32, 2), probe.checks);
    try std.testing.expectEqual(@as(u32, 1), probe.argument_checks);
    try std.testing.expectEqual(@as(u32, 2), probe.acquires);
    try std.testing.expectEqual(@as(u32, 2), probe.releases);
    try std.testing.expectEqual(@as(u32, 0), probe.users);
    try std.testing.expectEqual(@as(u32, 0), probe.double_releases);
}

test "closure guard: ordinary and self tail replacement retire invocations" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();

    var outer_probe: GuardLifecycleProbe = .{};
    var target_probe: GuardLifecycleProbe = .{};
    var outer_guard = outer_probe.guard();
    var target_guard = target_probe.guard();
    try bindGuardTestValue(runtime, "guard-test-tail-state", .intrinsic(&guardTestObserveTail));
    try bindGuardTestValue(runtime, "guard-test-outer", .opaq(.fromPtr(&outer_probe)));
    try bindGuardTestValue(runtime, "guard-test-target", .opaq(.fromPtr(&target_probe)));

    const target = try runtime.evalString(
        "(fn () (guard-test-tail-state guard-test-outer guard-test-target))",
    );
    _ = attachGuard(target, &target_guard);
    try bindGuardTestValue(runtime, "guard-test-tail-target", target);
    const outer = try runtime.evalString("(fn () (guard-test-tail-target))");
    _ = attachGuard(outer, &outer_guard);

    try std.testing.expectEqual(
        Value.i64(13),
        try runtime.apply(runtime.root_ns, outer, &.{}),
    );
    try std.testing.expect(outer_probe.saw_released);
    try std.testing.expect(target_probe.saw_held);
    try std.testing.expectEqual(@as(u32, 1), outer_probe.acquires);
    try std.testing.expectEqual(@as(u32, 1), outer_probe.releases);
    try std.testing.expectEqual(@as(u32, 1), target_probe.acquires);
    try std.testing.expectEqual(@as(u32, 1), target_probe.releases);

    var self_probe: GuardLifecycleProbe = .{};
    var self_guard = self_probe.guard();
    try bindGuardTestValue(runtime, "guard-test-self", .opaq(.fromPtr(&self_probe)));
    try bindGuardTestValue(runtime, "guard-test-held-state", .intrinsic(&guardTestObserveHeld));
    _ = try runtime.evalString(
        "(defn (guard-test-countdown n) " ++
            "(if (= n 0) (guard-test-held-state guard-test-self) " ++
            "(guard-test-countdown (- n 1))))",
    );
    const recursive = try runtime.nsGet(
        runtime.root_ns,
        try runtime.store.getsym("guard-test-countdown"),
    );
    _ = attachGuard(recursive, &self_guard);
    try std.testing.expectEqual(
        Value.i64(11),
        try runtime.apply(runtime.root_ns, recursive, &.{Value.i64(4)}),
    );
    try std.testing.expect(self_probe.saw_held);
    try std.testing.expectEqual(@as(u32, 5), self_probe.acquires);
    try std.testing.expectEqual(@as(u32, 5), self_probe.releases);
    try std.testing.expectEqual(@as(u32, 0), self_probe.users);
    try std.testing.expectEqual(@as(u32, 0), self_probe.double_releases);
}

test "closure guard: exception unwind and native failure retire exact frames" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();

    try bindGuardTestValue(
        runtime,
        "guard-test-observe-released",
        .intrinsic(&guardTestObserveReleased),
    );
    try bindGuardTestValue(
        runtime,
        "guard-test-observe-held",
        .intrinsic(&guardTestObserveHeld),
    );
    try bindGuardTestValue(runtime, "guard-test-fail", .intrinsic(&guardTestFail));

    var inner_probe: GuardLifecycleProbe = .{};
    var inner_guard = inner_probe.guard();
    try bindGuardTestValue(runtime, "guard-test-inner-probe", .opaq(.fromPtr(&inner_probe)));
    const inner = try runtime.evalString("(fn () (raise 7))");
    _ = attachGuard(inner, &inner_guard);
    try bindGuardTestValue(runtime, "guard-test-inner", inner);
    const catcher = try runtime.evalString(
        "(fn () (try (guard-test-inner) " ++
            "(fn (e) (guard-test-observe-released guard-test-inner-probe))))",
    );
    try std.testing.expectEqual(
        Value.true,
        try runtime.apply(runtime.root_ns, catcher, &.{}),
    );
    try std.testing.expect(inner_probe.saw_released);
    try std.testing.expectEqual(@as(u32, 1), inner_probe.acquires);
    try std.testing.expectEqual(@as(u32, 1), inner_probe.releases);

    var catch_probe: GuardLifecycleProbe = .{};
    var catch_guard = catch_probe.guard();
    try bindGuardTestValue(runtime, "guard-test-catch-probe", .opaq(.fromPtr(&catch_probe)));
    const catches_self = try runtime.evalString(
        "(fn () (try (raise 7) " ++
            "(fn (e) (guard-test-observe-held guard-test-catch-probe))))",
    );
    _ = attachGuard(catches_self, &catch_guard);
    try std.testing.expectEqual(
        Value.i64(11),
        try runtime.apply(runtime.root_ns, catches_self, &.{}),
    );
    try std.testing.expect(catch_probe.saw_held);
    try std.testing.expectEqual(catch_probe.acquires, catch_probe.releases);
    try std.testing.expectEqual(@as(u32, 0), catch_probe.users);
    try std.testing.expectEqual(@as(u32, 0), catch_probe.double_releases);

    var failure_probe: GuardLifecycleProbe = .{};
    var failure_guard = failure_probe.guard();
    const fails = try runtime.evalString("(fn () (guard-test-fail))");
    _ = attachGuard(fails, &failure_guard);
    const failure = try runtime.apply(runtime.root_ns, fails, &.{});
    try std.testing.expectError(error.TypeMismatch, failure.unwrapError());
    try std.testing.expectEqual(@as(u32, 1), failure_probe.acquires);
    try std.testing.expectEqual(@as(u32, 1), failure_probe.releases);
    try std.testing.expectEqual(@as(u32, 0), failure_probe.users);
}

test "closure guard: invalid pairs and cancellation cannot leak or double release" {
    var runtime_live = true;
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer {
        if (runtime_live) runtime.deinit();
    }

    var invalid_probe: GuardLifecycleProbe = .{};
    var invalid_guard = invalid_probe.guard();
    invalid_guard.release = null;
    const invalid = try runtime.evalString("(fn () 1)");
    _ = attachGuard(invalid, &invalid_guard);
    try std.testing.expectError(
        error.InvalidCode,
        runtime.apply(runtime.root_ns, invalid, &.{}),
    );
    try std.testing.expectEqual(@as(u32, 0), invalid_probe.checks);
    try std.testing.expectEqual(@as(u32, 0), invalid_probe.acquire_attempts);
    try std.testing.expectEqual(@as(u32, 0), invalid_probe.releases);

    var cancel_probe: GuardLifecycleProbe = .{};
    var cancel_guard = cancel_probe.guard();
    const canceled = try runtime.evalString("(fn () 1)");
    const canceled_closure = attachGuard(canceled, &cancel_guard);
    try runtime.checkClosureGuard(canceled_closure, &.{});
    const acquired = try runtime.acquireClosureGuard(canceled_closure);

    var stack: [frame_size + 2]Object = @splat(.null);
    const stop = regvm.Inst.make(.stop, 0);
    @as(*FrameReg, @ptrCast(&stack)).* = .{
        .prev_ap = 0,
        .prev_fp = 0,
        .prev_sp = stack.len,
        .consts = &.{},
        .ns = runtime.root_ns,
        .prev_fns = &.{},
        .ret_reg = 0,
        .result_count = 1,
        .ret_addr = @ptrCast(&stop),
        .guard = acquired,
        .prev_closure = null,
        .prev_guard = null,
        .prev_nregs = 0,
        .prev_ir = &.{},
        .prev_src_idx = 0,
    };
    const process = try runtime.static.create(sched_mod.Process);
    process.* = .{
        .pid = 999,
        .fib = .{
            .stack = &stack,
            .sp = stack.len,
            .ip = canceled_closure.ir.ptr,
            .ir = canceled_closure.ir,
            .nregs = canceled_closure.nregs,
            .consts = canceled_closure.constants,
            .fns = canceled_closure.fns,
            .ns = canceled_closure.parent_ns,
            .current_closure = canceled_closure,
            .active_guard = acquired,
            .call_depth = 1,
        },
    };
    runtime.scheduler.mutex.lockUncancelable(runtime.io);
    try runtime.scheduler.registerLocked(runtime.gpa, process);
    runtime.scheduler.mutex.unlock(runtime.io);
    cancel_probe.open = false;

    runtime.deinit();
    runtime_live = false;
    try std.testing.expect(cancel_probe.reclaimed);
    try std.testing.expectEqual(@as(u32, 1), cancel_probe.acquires);
    try std.testing.expectEqual(@as(u32, 1), cancel_probe.releases);
    try std.testing.expectEqual(@as(u32, 0), cancel_probe.users);
    try std.testing.expectEqual(@as(u32, 0), cancel_probe.double_releases);
}

test "evalString evaluates through the register VM" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    const io = threaded.io();
    const rt = try init(std.testing.allocator, io);
    defer rt.deinit();
    const res = try rt.evalString("(+ 1 2)");
    try std.testing.expect(res.typ == b.type_i64);
    const v = res.obj.toInt(i64);
    try std.testing.expectEqual(@as(i64, 3), v);
}

test "bound code inspection rejects a closed linearization region" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const source = try rt.evalString("(fn (x) x)");
    const primal = try rt.evalString("(list 1.0 2.0)");
    const result = try Linearize.linearize(rt.context(), source, &.{primal});
    defer result.region.deinit();
    const linear = result.linear.obj.toRef().deref(Closure);

    result.region.close();
    try std.testing.expectError(error.Expired, rt.inspectBoundCode(linear, 16384));
}

test "source inspection owns input and excludes unrelated forms" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const original = "(def secret 42) (fn (x) (+ x 1))";
    var input: [64]u8 = undefined;
    @memcpy(input[0..original.len], original);
    const closure_value = try rt.evalString(input[0..original.len]);
    const closure = closure_value.obj.toRef().deref(Closure);
    @memset(input[0..original.len], 'x');

    const text = try rt.inspectSourceText(closure, 65536);
    try std.testing.expectEqualStrings(
        "(fn (x) (+ x 1))",
        std.mem.sliceTo(text.obj.toPtr([*]u8), 0),
    );
    try std.testing.expectEqual(
        Value.i64(3),
        try rt.apply(rt.root_ns, closure_value, &.{Value.i64(2)}),
    );
}

test "one function can close over different values at different sites" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var builder = Code.Builder.init(rt.static, rt.context());
    const identity = try rt.allocCodeIdentity();
    builder.id = identity.id;
    builder.revision = identity.revision;
    const main_function = try builder.addFunction(null, .{});
    builder.functions.items[@intFromEnum(main_function)].module_entry = true;
    const main_block = try builder.addBlock(main_function);
    const two = try builder.addNode(main_function, main_block, .{ .literal = Value.i64(2) }, .{});
    const five = try builder.addNode(main_function, main_block, .{ .literal = Value.i64(5) }, .{});
    const binding = try builder.addBinding(main_function, try rt.store.getsym("captured"), .let, .{});
    builder.bindings.items[@intFromEnum(binding)].value = two;
    const child = try builder.addFunction(null, .{});
    const child_block = try builder.addBlock(child);
    const capture = try builder.addCapture(child, binding);
    try builder.setTerminator(child_block, .{ .return_values = try builder.addOperands(&.{capture}) });
    const a = try builder.addNode(main_function, main_block, .{ .make_closure = .{
        .function = child,
        .captures = try builder.addOperands(&.{two}),
    } }, .{});
    const b_closure = try builder.addNode(main_function, main_block, .{ .make_closure = .{
        .function = child,
        .captures = try builder.addOperands(&.{five}),
    } }, .{});
    const a_result = try builder.addNode(main_function, main_block, .{ .dynamic_call = .{ .callee = a } }, .{});
    const b_result = try builder.addNode(main_function, main_block, .{ .dynamic_call = .{ .callee = b_closure } }, .{});
    const sum = try builder.addNode(main_function, main_block, .{ .arithmetic = .{
        .op = .add,
        .left = a_result,
        .right = b_result,
    } }, .{});
    try builder.setTerminator(main_block, .{ .return_values = try builder.addOperands(&.{sum}) });
    const code = try builder.finish(std.testing.allocator);
    code.owner = rt;
    const program = try rt.lowerCode(std.testing.allocator, code);
    const stack = try rt.static.alloc(Object, frame_size + @as(usize, program.nregs) * 2);
    @memset(stack, .null);
    var fiber: Fiber = .{
        .stack = stack,
        .sp = stack.len,
        .ip = program.ir.ptr,
        .ir = program.ir,
        .nregs = program.nregs,
        .consts = program.constants,
        .fns = program.fns,
        .ns = rt.root_ns,
    };
    try std.testing.expectEqual(Value.i64(7), try rt.runToCompletion(rt.root_ns, &fiber));
}

test "bound multi-result tail calls preserve every returned value" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var builder = Code.Builder.init(rt.static, rt.context());
    const identity = try rt.allocCodeIdentity();
    builder.id = identity.id;
    builder.revision = identity.revision;
    const main_function = try builder.addFunction(null, .{});
    builder.functions.items[@intFromEnum(main_function)].module_entry = true;
    const main_block = try builder.addBlock(main_function);
    const pair_function = try builder.addFunction(null, .{});
    builder.functions.items[@intFromEnum(pair_function)].result_count = 2;
    const pair_block = try builder.addBlock(pair_function);
    const two = try builder.addNode(pair_function, pair_block, .{ .literal = Value.i64(2) }, .{});
    const five = try builder.addNode(pair_function, pair_block, .{ .literal = Value.i64(5) }, .{});
    try builder.setTerminator(pair_block, .{ .return_values = try builder.addOperands(&.{ two, five }) });
    const wrapper = try builder.addFunction(null, .{});
    builder.functions.items[@intFromEnum(wrapper)].result_count = 2;
    const wrapper_block = try builder.addBlock(wrapper);
    const pair = try builder.addNode(wrapper, wrapper_block, .{ .make_closure = .{ .function = pair_function } }, .{});
    try builder.setTerminator(wrapper_block, .{ .tail_call = .{ .callee = pair, .result_count = 2 } });
    const callee = try builder.addNode(main_function, main_block, .{ .make_closure = .{ .function = wrapper } }, .{});
    const first = try builder.addNode(main_function, main_block, .{ .dynamic_call = .{
        .callee = callee,
        .result_count = 2,
    } }, .{});
    const second: Code.ValueId = @enumFromInt(@intFromEnum(first) + 1);
    const sum = try builder.addNode(main_function, main_block, .{ .arithmetic = .{
        .op = .add,
        .left = first,
        .right = second,
    } }, .{});
    try builder.setTerminator(main_block, .{ .return_values = try builder.addOperands(&.{sum}) });
    const code = try builder.finish(std.testing.allocator);
    code.owner = rt;
    const program = try rt.lowerCode(std.testing.allocator, code);
    const stack = try rt.static.alloc(Object, frame_size + @as(usize, program.nregs) * 2);
    @memset(stack, .null);
    var fiber: Fiber = .{
        .stack = stack,
        .sp = stack.len,
        .ip = program.ir.ptr,
        .ir = program.ir,
        .nregs = program.nregs,
        .consts = program.constants,
        .fns = program.fns,
        .ns = rt.root_ns,
    };
    const result = try rt.runToCompletion(rt.root_ns, &fiber);
    try std.testing.expectEqual(Value.i64(7), try result.unwrapError());
    const lowered = program.fns[@intFromEnum(pair_function)];
    const reference = try rt.store.create(Closure);
    reference.deref(Closure).* = .{
        .parent_ns = rt.root_ns,
        .arglist = lowered.arglist,
        .code = code,
        .function_id = pair_function,
        .ir = lowered.ir,
        .constants = lowered.constants,
        .nregs = lowered.nregs,
        .result_count = lowered.result_count,
        .zero_mask = lowered.zero_mask,
        .fns = program.fns,
    };
    const callable = Value.closure(reference.toObject());
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var workspace = CallWorkspace.init(failing.allocator());
    defer workspace.deinit();
    var outputs: [2]Value = undefined;
    try workspace.apply(rt.context(), callable, &.{}, &outputs);
    try std.testing.expectEqualSlices(Value, &.{ Value.i64(2), Value.i64(5) }, &outputs);
    failing.fail_index = failing.alloc_index;
    try workspace.apply(rt.context(), callable, &.{}, &outputs);
    try std.testing.expectEqualSlices(Value, &.{ Value.i64(2), Value.i64(5) }, &outputs);
    try std.testing.expectError(error.ArityMismatch, workspace.apply(rt.context(), callable, &.{}, outputs[0..1]));
}

test "datum-only source retention permits datum but denies text" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    rt.source_retention = .datum_only;

    const closure_value = try rt.evalString("(fn (x) (+ x 1))");
    const closure = closure_value.obj.toRef().deref(Closure);
    try std.testing.expectError(error.Unsupported, rt.inspectSourceText(closure, 65536));
    const datum = try rt.inspectSourceDatum(closure, 16384);
    try std.testing.expectEqual(b.type_cons, datum.typ);
    try std.testing.expectEqual(
        Value.i64(3),
        try rt.apply(rt.root_ns, closure_value, &.{Value.i64(2)}),
    );
}

test "none source retention keeps closure execution but denies inspection" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    rt.source_retention = .none;

    const closure_value = try rt.evalString("(fn (x) (+ x 1))");
    const closure = closure_value.obj.toRef().deref(Closure);
    try std.testing.expectEqual(
        Value.i64(3),
        try rt.apply(rt.root_ns, closure_value, &.{Value.i64(2)}),
    );
    try std.testing.expectError(error.Unsupported, rt.inspectSourceText(closure, 65536));
    try std.testing.expectError(error.Unsupported, rt.inspectSourceDatum(closure, 16384));
}

test "apply completes a closure after multiple VM quanta" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    _ = try rt.evalString(
        "(defn (countdown n) (if (= n 0) 0 (countdown (- n 1))))",
    );
    const callback = try rt.evalString(
        "(fn (x) (begin (countdown 20000) (* x x)))",
    );
    const result = try rt.apply(
        rt.root_ns,
        callback,
        &.{Value.f64(3.0)},
    );
    try std.testing.expectEqual(b.type_f64, result.typ);
    try std.testing.expectApproxEqAbs(@as(f64, 9.0), result.obj.tof64(), 1e-6);
}

/// Saved frame for the register VM, pushed on `.call` and popped on `.ret`.
/// Plain struct, NOT extern: slice fields are not valid in extern structs.
pub const FrameReg = struct {
    prev_ap: usize,
    prev_fp: usize,
    prev_sp: usize,
    consts: []const Value,
    ns: Value,
    prev_fns: []const FnTableEntry,
    ret_reg: u8,
    result_count: u8,
    ret_addr: ?[*]const regvm.Inst,
    guard: ?*const skript.data.ClosureGuard = null,
    prev_guard: ?*const skript.data.ClosureGuard = null,
    prev_closure: ?*Closure,
    prev_nregs: u8,
    prev_ir: []const regvm.Inst,
    prev_src_idx: u32,
    _pad: if (@sizeOf(usize) == 4) [4]u8 else [0]u8 = if (@sizeOf(usize) == 4) [_]u8{ 0, 0, 0, 0 } else [_]u8{},
};

comptime {
    if (@sizeOf(FrameReg) % @sizeOf(Object) != 0) {
        @compileError("FrameReg size must be a multiple of Object size");
    }
}

/// Number of Object slots a FrameReg occupies. A register R[i] lives at
/// stack[fp + frame_size + i*2] (typ at slot, obj at slot+1).
pub const frame_size = @sizeOf(FrameReg) / @sizeOf(Object);

/// Arguments retained across a native suspension of canonical `@apply`.
/// Small calls stay in the fiber; large calls own one expanded slice.
const PendingApply = struct {
    target: Value,
    count: usize,
    inline_values: [32]Value = undefined,
    owned: []Value = &.{},
    allocator: Allocator,

    pub fn args(self: *const PendingApply) []const Value {
        return if (self.owned.len != 0) self.owned else self.inline_values[0..self.count];
    }

    fn deinit(self: *PendingApply) void {
        if (self.owned.len != 0) self.allocator.free(self.owned);
        self.* = undefined;
    }
};

/// Register-mode fiber. Registers are stack slots:
/// R[i] = stack[fp + frame_size + i*2].
pub const Fiber = struct {
    stack: []Object,
    stack_allocator: ?Allocator = null,
    ap: usize = 0,
    sp: usize = 0,
    fp: usize = 0,
    ip: [*]const regvm.Inst,
    /// The active instruction slice, when known. Host-built fibers may leave
    /// this empty; runtime-created fibers always set it.
    ir: []const regvm.Inst = &.{},
    /// The active frame's register count, when known. Zero means infer it from
    /// the closure/function table or the current stack extent.
    nregs: u8 = 0,
    consts: []const Value = &.{},
    fns: []const FnTableEntry = &.{},
    ns: Value = .nil,
    pending_eval: ?*sched_mod.Process = null,
    pending_apply: ?PendingApply = null,
    current_closure: ?*Closure = null,
    active_guard: ?*const skript.data.ClosureGuard = null,
    /// Set once terminal teardown has released every invocation lease.
    guards_released: bool = false,
    raised: Value = .nil,
    /// A rich error returned by a nested native callback or rethrown by
    /// `(raise ERROR)`; consumed before unwinding to the next handler.
    pending_error: Value = .nil,
    exn_stack: List(ExnFrame) = .empty,
    src_idx: u32 = 0,
    call_depth: u32 = 0,

    /// Cleared on every call from the `defer` in `dispatchVmCall`, so the
    /// already-empty case is the hot one. `self.pending_apply = null`
    /// assigns a 576-byte `PendingApply` (its `inline_values` array is 512
    /// of that), and assigning an optional's null materialises the whole
    /// payload — so the unconditional form zeroed 576 bytes on every single
    /// call. Measured at 14-55% of total runtime across the bench ports.
    /// `pending_apply` is only ever set by canonical `@apply` expansion and
    /// symbolic callbacks, so the guard almost always wins.
    fn clearPendingApply(self: *Fiber) void {
        if (self.pending_apply == null) return;
        self.pending_apply.?.deinit();
        self.pending_apply = null;
    }

    pub fn activeNregs(self: *const Fiber) u8 {
        if (self.nregs != 0) return self.nregs;
        if (self.current_closure) |cl| {
            if (cl.nregs != 0) return cl.nregs;
        }
        if (self.fns.len != 0 and self.fns[0].nregs != 0) return self.fns[0].nregs;
        if (self.sp < self.fp + frame_size) return 0;
        const count = (self.sp - (self.fp + frame_size)) / 2;
        return @intCast(@min(count, @as(usize, std.math.maxInt(u8))));
    }

    pub fn activeIr(self: *const Fiber) []const regvm.Inst {
        if (self.ir.len != 0) return self.ir;
        if (self.current_closure) |cl| {
            if (cl.ir.len != 0) return cl.ir;
        }
        if (self.fns.len != 0) return self.fns[0].ir;
        return &.{};
    }

    /// Borrow the packed argument registers until this fiber's stack grows.
    fn registerArgs(self: *const Fiber, rd: u8, count: usize) []const Value {
        @setRuntimeSafety(false);
        comptime {
            std.debug.assert(@sizeOf(Value) == 2 * @sizeOf(Object));
            std.debug.assert(@alignOf(Value) == @alignOf(Object));
        }
        const slot = self.fp + frame_size + (@as(usize, rd) + 1) * 2;
        const values: [*]const Value = @ptrCast(self.stack.ptr + slot);
        return values[0..count];
    }

    pub fn getReg(self: *const Fiber, reg: u8) Value {
        @setRuntimeSafety(false);
        const slot = self.fp + frame_size + @as(usize, reg) * 2;
        return .{ .typ = self.stack[slot], .obj = self.stack[slot + 1] };
    }

    pub fn setReg(self: *Fiber, reg: u8, val: Value) void {
        @setRuntimeSafety(false);
        const slot = self.fp + frame_size + @as(usize, reg) * 2;
        self.stack[slot] = val.typ;
        self.stack[slot + 1] = val.obj;
    }
};

test "regvm: init loads the prelude without error" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // A prelude-defined binding (def and @bool.and) must resolve through nsGet
    // after the compiled prelude ran.
    const and_sym = try rt.store.getsym("and");
    const and_val = try rt.nsGet(rt.root_ns, and_sym);
    try std.testing.expectEqual(b.type_intrinsic, and_val.typ);
}

test "namespace reads preserve initialized Error Values and nil" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const nil_sym = try rt.store.getsym("phase1-error-value-nil");
    try rt.nsBind(rt.root_ns, nil_sym, .nil);
    try std.testing.expectEqual(Value.nil, try rt.nsGet(rt.root_ns, nil_sym));

    const plain_error = Value.err(error.UninitializedBinding);
    const plain_error_sym = try rt.store.getsym("phase1-plain-error-value");
    try rt.nsBind(rt.root_ns, plain_error_sym, plain_error);
    try std.testing.expectEqual(plain_error, try rt.nsGet(rt.root_ns, plain_error_sym));

    const rich_error = Value.errWith(rt.store, error.TypeMismatch, .nil, 0);
    const rich_error_sym = try rt.store.getsym("phase1-rich-error-value");
    try rt.nsBind(rt.root_ns, rich_error_sym, rich_error);
    try std.testing.expectEqual(rich_error, try rt.nsGet(rt.root_ns, rich_error_sym));
}

test "regvm: prelude defn call runs through compileData + evalReg" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // `avg` is a prelude defn (nested ifs over @f64.avg/@f32.avg/@f16.avg);
    // calling it must dispatch through the compiled closure path.
    const forms = try skript.Reader.readAll(rt.store, "(avg (list 1.0 2.0 3.0 4.0))");
    const prog = try rt.compileData(rt.root_ns, forms, null);
    const stack = try std.testing.allocator.alloc(Object, frame_size + @as(usize, prog.nregs) * 2);
    defer std.testing.allocator.free(stack);
    @memset(stack, .null);
    var fib: Fiber = .{
        .stack = stack,
        // sp starts one past the top-level register window (see main.zig).
        .sp = frame_size + @as(usize, prog.nregs) * 2,
        .ip = prog.ir.ptr,
        .ir = prog.ir,
        .nregs = prog.nregs,
        .consts = prog.constants,
        .fns = prog.fns,
        .ns = rt.root_ns,
    };
    try std.testing.expectEqual(Value.f64(2.5), try rt.runToCompletion(rt.root_ns, &fib));
}

test "regvm: negative immediates sign-extend; top-level nested closure calls" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // (a) mov_i64 carries an imm16 payload — negatives must sign-extend and
    // values >= 2^16 must take the constant path (regression: i24 encode
    // corrupted the rd field, u16 decode dropped the sign).
    const forms_a = try skript.Reader.readAll(rt.store, "(+ 9000000 1) (- 0 5) (+ -7 3)");
    const prog_a = try rt.compileData(rt.root_ns, forms_a, null);
    const stack_a = try std.testing.allocator.alloc(Object, frame_size + @as(usize, prog_a.nregs) * 2);
    defer std.testing.allocator.free(stack_a);
    @memset(stack_a, .null);
    var fib_a: Fiber = .{
        .stack = stack_a,
        .sp = frame_size + @as(usize, prog_a.nregs) * 2,
        .ip = prog_a.ir.ptr,
        .ir = prog_a.ir,
        .nregs = prog_a.nregs,
        .consts = prog_a.constants,
        .fns = prog_a.fns,
        .ns = rt.root_ns,
    };
    try std.testing.expectEqual(Value.i64(-4), try rt.runToCompletion(rt.root_ns, &fib_a));

    // (b) the top-level fiber's sp starts one past its register window, so a
    // compiled closure call used AS an argument must not push its frame over
    // the caller's staged registers (regression: sp = 0 overlapped them).
    const forms_b = try skript.Reader.readAll(rt.store, "(defn (id x) x) (id (id 5))");
    const prog_b = try rt.compileData(rt.root_ns, forms_b, null);
    const stack_b = try std.testing.allocator.alloc(Object, frame_size + @as(usize, prog_b.nregs) * 2);
    defer std.testing.allocator.free(stack_b);
    @memset(stack_b, .null);
    var fib_b: Fiber = .{
        .stack = stack_b,
        .sp = frame_size + @as(usize, prog_b.nregs) * 2,
        .ip = prog_b.ir.ptr,
        .ir = prog_b.ir,
        .nregs = prog_b.nregs,
        .consts = prog_b.constants,
        .fns = prog_b.fns,
        .ns = rt.root_ns,
    };
    try std.testing.expectEqual(Value.i64(5), try rt.runToCompletion(rt.root_ns, &fib_b));
}

test "regvm: compileData + evalReg of (+ 1 2)" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const forms = try skript.Reader.readAll(rt.store, "(+ 1 2)");
    const prog = try rt.compileData(rt.root_ns, forms, null);
    const stack = try std.testing.allocator.alloc(Object, frame_size + @as(usize, prog.nregs) * 2);
    defer std.testing.allocator.free(stack);
    @memset(stack, .null);
    var fib: Fiber = .{
        .stack = stack,
        // sp starts one past the top-level register window (see main.zig).
        .sp = frame_size + @as(usize, prog.nregs) * 2,
        .ip = prog.ir.ptr,
        .ir = prog.ir,
        .nregs = prog.nregs,
        .consts = prog.constants,
        .ns = rt.root_ns,
    };
    try std.testing.expectEqual(Value.i64(3), try rt.runToCompletion(rt.root_ns, &fib));
}

/// Run one specialized arith instruction (rd=0, rs1=1, rs2=2) seeded with
/// the given Values, then .stop. Exercises the guardedArith chain directly —
/// the typed constructors are not callable from source, so registers are
/// seeded by hand.
fn chainFiber(rt: *Runtime, op: regvm.Opcode, a: Value, b_val: Value) !Value {
    const payload = (@as(u24, 0) << 16) | (@as(u24, 1) << 8) | @as(u24, 2);
    const ir = [_]regvm.Inst{
        .make(op, payload),
        .make(.stop, 0),
    };
    const stack = try std.testing.allocator.alloc(Object, frame_size + 3 * 2);
    defer std.testing.allocator.free(stack);
    @memset(stack, .null);
    var fib: Fiber = .{
        .stack = stack,
        .sp = frame_size + 3 * 2,
        .ip = &ir,
        .ir = &ir,
        .nregs = 3,
        .ns = rt.root_ns,
    };
    fib.setReg(1, a);
    fib.setReg(2, b_val);
    _ = try rt.runToCompletion(rt.root_ns, &fib);
    return fib.getReg(0);
}

test "regvm: speculative arith chain (add/sub/mul/eq)" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // addi chain (bet i64): int-pair first — wraps and tags the operand width.
    try std.testing.expectEqual(Value.u8(0), try chainFiber(rt, .add_i64, Value.u8(255), Value.u8(1)));
    try std.testing.expectEqual(Value.u8(144), try chainFiber(rt, .mul_i64, Value.u8(200), Value.u8(2)));
    try std.testing.expectEqual(Value.i8(-1), try chainFiber(rt, .sub_i64, Value.i8(0), Value.i8(1)));
    // i64 overflow now WRAPS on the native arm (exploration decision).
    try std.testing.expectEqual(
        Value.i64(std.math.minInt(i64)),
        try chainFiber(rt, .add_i64, Value.i64(std.math.maxInt(i64)), Value.i64(1)),
    );
    // addi chain: f64 data through an i64 bet -> the f64 arm.
    try std.testing.expectEqual(Value.f64(4.0), try chainFiber(rt, .add_i64, Value.f64(1.5), Value.f64(2.5)));
    try std.testing.expectEqual(Value.f64(3.75), try chainFiber(rt, .mul_i64, Value.f64(1.5), Value.f64(2.5)));
    // eq: per-width ints; NaN != NaN preserved.
    try std.testing.expectEqual(Value.true, try chainFiber(rt, .eq_i64, Value.u16(5), Value.u16(5)));
    try std.testing.expectEqual(Value.false, try chainFiber(rt, .eq_i64, Value.u16(5), Value.u16(6)));
    try std.testing.expectEqual(
        Value.false,
        try chainFiber(rt, .eq_i64, Value.f64(std.math.nan(f64)), Value.f64(std.math.nan(f64))),
    );

    // addf chain (bet f64): f64 -> f32 -> f16 -> int-pair.
    try std.testing.expectEqual(Value.f64(4.0), try chainFiber(rt, .add_f64, Value.f64(1.5), Value.f64(2.5)));
    try std.testing.expectEqual(Value.f32(3.5), try chainFiber(rt, .add_f64, Value.f32(1.5), Value.f32(2.0)));
    try std.testing.expectEqual(Value.f16(3.5), try chainFiber(rt, .add_f64, Value.f16(1.5), Value.f16(2.0)));
    try std.testing.expectEqual(Value.u32(5), try chainFiber(rt, .add_f64, Value.u32(2), Value.u32(3)));

    // Mixed types fall through both arms -> generic dispatch, where the
    // coercion fallback joins i64+f64 to f64 and runs @f64.add.
    try std.testing.expectEqual(Value.f64(3.0), try chainFiber(rt, .add_i64, Value.i64(1), Value.f64(2.0)));
}

test "regvm: defn + call runs through the compiled path" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const forms = try skript.Reader.readAll(rt.store, "(defn (add a b) (+ a b)) (add 1 2)");
    const prog = try rt.compileData(rt.root_ns, forms, null);
    const stack = try std.testing.allocator.alloc(Object, frame_size + @as(usize, prog.nregs) * 2);
    defer std.testing.allocator.free(stack);
    @memset(stack, .null);
    var fib: Fiber = .{
        .stack = stack,
        // sp starts one past the top-level register window (see main.zig).
        .sp = frame_size + @as(usize, prog.nregs) * 2,
        .ip = prog.ir.ptr,
        .ir = prog.ir,
        .nregs = prog.nregs,
        .consts = prog.constants,
        .fns = prog.fns,
        .ns = rt.root_ns,
    };
    try std.testing.expectEqual(Value.i64(3), try rt.runToCompletion(rt.root_ns, &fib));
}

test "regvm: nested fn captures enclosing param through closure conversion" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // The nested fn's free `x` resolves to the enclosing compiled frame's
    // parameter register (R[1]); the walk must NOT lift it into outer.
    const forms = try skript.Reader.readAll(rt.store, "(defn (outer x) ((fn (y) (+ x y)) 3)) (outer 2)");
    const prog = try rt.compileData(rt.root_ns, forms, null);
    const stack = try std.testing.allocator.alloc(Object, frame_size + @as(usize, prog.nregs) * 2);
    defer std.testing.allocator.free(stack);
    @memset(stack, .null);
    var fib: Fiber = .{
        .stack = stack,
        // sp starts one past the top-level register window (see main.zig).
        .sp = frame_size + @as(usize, prog.nregs) * 2,
        .ip = prog.ir.ptr,
        .ir = prog.ir,
        .nregs = prog.nregs,
        .consts = prog.constants,
        .fns = prog.fns,
        .ns = rt.root_ns,
    };
    try std.testing.expectEqual(Value.i64(5), try rt.runToCompletion(rt.root_ns, &fib));
}

test "captured values survive collection with short and long environments" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const short = try rt.evalString(
        "((fn (a b) (fn () (+ (fst a) (fst b)))) (list 20) (list 22))",
    );
    var short_root: ValueRoot = .{};
    try rt.registerValueRoot(&short_root, short);
    defer rt.unregisterValueRoot(&short_root) catch unreachable;

    const long = try rt.evalString(
        "((fn (a b c) (fn () (+ (fst a) (+ (fst b) (fst c))))) " ++
            "(list 10) (list 20) (list 12))",
    );
    var long_root: ValueRoot = .{};
    try rt.registerValueRoot(&long_root, long);
    defer rt.unregisterValueRoot(&long_root) catch unreachable;

    try rt.collect();
    try std.testing.expectEqual(Value.i64(42), try rt.apply(rt.root_ns, short_root.value, &.{}));
    try std.testing.expectEqual(Value.i64(42), try rt.apply(rt.root_ns, long_root.value, &.{}));
}

test "regvm: transitive and let-shadowed closure captures" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // Helper: run one program and expect an i64 result.
    const run = struct {
        fn go(rt_: *Runtime, src: []const u8, expected: i64) !void {
            const forms = try skript.Reader.readAll(rt_.store, src);
            const prog = try rt_.compileData(rt_.root_ns, forms, null);
            const stack = try std.testing.allocator.alloc(Object, frame_size + @as(usize, prog.nregs) * 2);
            defer std.testing.allocator.free(stack);
            @memset(stack, .null);
            var fib: Fiber = .{
                .stack = stack,
                .ip = prog.ir.ptr,
                .ir = prog.ir,
                .nregs = prog.nregs,
                .consts = prog.constants,
                .fns = prog.fns,
                .ns = rt_.root_ns,
            };
            try std.testing.expectEqual(Value.i64(expected), try rt_.runToCompletion(rt_.root_ns, &fib));
        }
    }.go;

    // Transitive: middle captures x (outer's R[1]); inner captures x (middle's
    // capture slot R[2]) and y (middle's param R[1]). 2-arg nested + because
    // the `+` method has no 3-arg instances (pre-existing arity limit).
    try run(rt, "(defn (outer x) ((fn (y) ((fn (z) (+ (+ x y) z)) 1)) 2)) (outer 3)", 6);

    // Let shadowing: x is bound by the let, so the inner fn's x must resolve
    // via the ns chain (parent_ns = let ns) instead of being lifted.
    try run(rt, "(defn (o x) (let ((x 100)) ((fn (y) (+ x y)) 1))) (o 2)", 101);

    // Global not frozen: g is not provably an enclosing register, so it is
    // NOT lifted; the closure resolves it dynamically at call time.
    try run(rt, "(def g 1) (defn (f ) (fn () g)) (def h (f)) (def g 2) (h)", 2);

    // Mixed: x lifted (enclosing param), y via ns (let-bound). 2-arg nested +
    // (same arity-limit reason as above).
    try run(rt, "(defn (outer x) (let ((y 10)) ((fn (z) (+ (+ x y) z)) 1))) (outer 2)", 13);

    // Nested fn args shadow: the inner x is its own param, not a capture.
    try run(rt, "(defn (o x) ((fn (x) x) 5)) (o 1)", 5);
}

test "regvm: let evaluates through the compiled path" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const forms = try skript.Reader.readAll(rt.store, "(let ((x 5) (y 10)) (+ x y))");
    const prog = try rt.compileData(rt.root_ns, forms, null);
    const stack = try std.testing.allocator.alloc(Object, frame_size + @as(usize, prog.nregs) * 2);
    defer std.testing.allocator.free(stack);
    @memset(stack, .null);
    var fib: Fiber = .{
        .stack = stack,
        // sp starts one past the top-level register window (see main.zig).
        .sp = frame_size + @as(usize, prog.nregs) * 2,
        .ip = prog.ir.ptr,
        .ir = prog.ir,
        .nregs = prog.nregs,
        .consts = prog.constants,
        .ns = rt.root_ns,
    };
    try std.testing.expectEqual(Value.i64(15), try rt.runToCompletion(rt.root_ns, &fib));
}

test "regvm: case matches a key through the compiled path" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const forms = try skript.Reader.readAll(rt.store, "(case 1 ((1) \"one\") ((2) \"two\") (else \"other\"))");
    const prog = try rt.compileData(rt.root_ns, forms, null);
    const stack = try std.testing.allocator.alloc(Object, frame_size + @as(usize, prog.nregs) * 2);
    defer std.testing.allocator.free(stack);
    @memset(stack, .null);
    var fib: Fiber = .{
        .stack = stack,
        // sp starts one past the top-level register window (see main.zig).
        .sp = frame_size + @as(usize, prog.nregs) * 2,
        .ip = prog.ir.ptr,
        .ir = prog.ir,
        .nregs = prog.nregs,
        .consts = prog.constants,
        .ns = rt.root_ns,
    };
    const res = try rt.runToCompletion(rt.root_ns, &fib);
    try std.testing.expect(res.typ == b.type_string);
    const s = res.obj.toPtr([*]u8);
    try std.testing.expectEqualStrings("one", std.mem.sliceTo(s, 0));
}

test "regvm: recursive calls and deep tail calls preserve results" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try regvm_type_track.run(
        rt,
        "(defn (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 20)",
        Value.i64(6765),
    );
    try regvm_type_track.run(rt, "(defn (loop n) (if (< n 1) n (loop (- n 1)))) (loop 100000)", Value.i64(0));

    // A self-call AFTER a normal nested call: (F 5) calls G (a .call frame
    // whose .ret must restore current_closure to F) and THEN self-calls —
    // a lost restore would dispatch G instead of F and return garbage
    // (515 = 105+104+103+102+101+0).
    try regvm_type_track.run(
        rt,
        "(defn (G x) (+ x 100)) (defn (F n) (if (= n 0) 0 (+ (G n) (F (- n 1))))) (F 5)",
        Value.i64(515),
    );
}

test "regvm: self-call is disabled for rebound and shadowed names" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // F is bound TWICE at top level (double defn) → NOT self-call eligible:
    // (h 3) must resolve the body's (F ...) through the namespace chain to
    // the second definition (42), not
    // self-recursion of the first. (0 would mean the self-call fired.)
    const rebind = "(defn (F n) (if (= n 0) 0 (F (- n 1)))) (def h F) (defn (F n) 42) (h 3)";
    try regvm_type_track.run(rt, rebind, Value.i64(42));
    // Stack-VM parity (evalString reads ONE form at a time): the rebound F
    // resolves identically through the namespace chain.
    _ = try rt.evalString("(defn (F n) (if (= n 0) 0 (F (- n 1))))");
    _ = try rt.evalString("(def h F)");
    _ = try rt.evalString("(defn (F n) 42)");
    try std.testing.expectEqual(Value.i64(42), try rt.evalString("(h 3)"));

    // A parameter named F shadows the global: (F 5) calls the ARGUMENT, not
    // self — a (wrongly emitted) self-call here would recurse forever
    // instead of returning 42.
    try regvm_type_track.run(rt, "(defn (F F) (F 5)) (F (fn (x) 42))", Value.i64(42));

    // A let-bound F shadows the global the same way: the body's (F n)
    // resolves through the let namespace, not to the executing closure.
    try regvm_type_track.run(rt, "(defn (F n) (let ((F (fn (x) 42))) (F n))) (F 1)", Value.i64(42));

    // A def of F WITHIN F's body rebinds the name: the call after it must
    // dispatch the rebound value (the guard's within-body suffix check) —
    // a self-call here would recurse forever instead of returning 42.
    try regvm_type_track.run(rt, "(defn (F n) (def F (fn (x) 42)) (F 1)) (F 3)", Value.i64(42));
}

test "regvm zero-mask: RegLower.computeZeroMask is conservative on hand-built IR" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const zm = struct {
        fn go(rt_: *Runtime, ir: []const regvm.Inst, nregs: u8, argc: usize, ncap: usize) RegLower.Error!u32 {
            return RegLower.computeZeroMask(rt_.gpa, ir, nregs, argc, ncap, &.{}, &.{}, rt_.context());
        }
    }.go;

    // (a) Write-before-read: r5 is written (mov_i64) before the mov_reg
    // reads it → bit 5 clear. r1 is a caller-written param, so its read as
    // the FIRST instruction is safe (the prologue copied the arg in).
    const a_ir = [_]regvm.Inst{
        regvm.Inst.make(.mov_reg, (@as(u24, 3) << 16) | @as(u24, 1)), // mov r3, r1
        regvm.Inst.make(.mov_i64, (@as(u24, 5) << 16)), // mov_i64 r5, 0
        regvm.Inst.make(.mov_reg, (@as(u24, 4) << 16) | @as(u24, 5)), // mov r4, r5
        regvm.Inst.make(.ret, @as(u24, 4) << 16), // ret r4
    };
    try std.testing.expectEqual(@as(u32, 0), try zm(rt, &a_ir, 6, 1, 0));

    // (b) Read-before-write: r5's first access is the mov_reg SOURCE → bit 5
    // set (the general case stays safe).
    const b_ir = [_]regvm.Inst{
        regvm.Inst.make(.mov_reg, (@as(u24, 3) << 16) | @as(u24, 5)), // mov r3, r5 ← read, never written
        regvm.Inst.make(.ret, @as(u24, 3) << 16),
    };
    try std.testing.expectEqual(@as(u32, 1) << 5, try zm(rt, &b_ir, 6, 1, 0));

    // (c) Branch-skip hazard: r5's first access in PROGRAM ORDER is the
    // mov_i64, but the brn can jump past it and r5 is read at the target —
    // a naive first-access-wins scan would wrongly clear the bit. The
    // must-definition join catches it: bit 5 must be set. (r2 is written on
    // both paths, so the final ret is safe.)
    const c_ir = [_]regvm.Inst{
        regvm.Inst.make(.mov_reg, (@as(u24, 2) << 16) | @as(u24, 1)), // mov r2, r1 (pred)
        regvm.Inst.make(.brn, (@as(u24, 2) << 16) | @as(u24, 2)), // brn r2, +2 → 4
        regvm.Inst.make(.mov_i64, (@as(u24, 5) << 16)), // mov_i64 r5, 1 (skippable write)
        regvm.Inst.make(.jmp, 1), // jmp +1 → 5
        regvm.Inst.make(.mov_reg, (@as(u24, 3) << 16) | @as(u24, 5)), // mov r3, r5 ← read without the write
        regvm.Inst.make(.ret, @as(u24, 2) << 16), // ret r2
    };
    try std.testing.expectEqual(@as(u32, 1) << 5, try zm(rt, &c_ir, 6, 1, 0));

    // (d) If-join: r0 is written by BOTH arms → the join read is safe, bit 0
    // clear — the r0 nil-set is skipped with no false positive.
    const d_ir = [_]regvm.Inst{
        regvm.Inst.make(.mov_i64, (@as(u24, 5) << 16)), // mov_i64 r5, 1 (then)
        regvm.Inst.make(.jmp, 1), // jmp +1 → 3
        regvm.Inst.make(.mov_i64, (@as(u24, 5) << 16)), // mov_i64 r5, 2 (else)
        regvm.Inst.make(.mov_reg, (@as(u24, 0) << 16) | @as(u24, 5)), // mov r0, r5 (join)
        regvm.Inst.make(.ret, 0), // ret r0
    };
    try std.testing.expectEqual(@as(u32, 0), try zm(rt, &d_ir, 6, 0, 0));

    // (e) Captures are caller-written (R[2..argc+1+ncap] seeded): a body
    // reading its capture first needs no zero.
    const e_ir = [_]regvm.Inst{
        regvm.Inst.make(.mov_reg, (@as(u24, 3) << 16) | @as(u24, 2)), // mov r3, r2 (capture read)
        regvm.Inst.make(.ret, @as(u24, 3) << 16),
    };
    try std.testing.expectEqual(@as(u32, 0), try zm(rt, &e_ir, 4, 1, 1));
}

test "regvm zero-mask: masked self-calls compute identical values" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // fib through the frame-per-call self-call path with mask 0 (zeroing
    // fully skipped); loop through tail_self_call TCO.
    try regvm_type_track.run(
        rt,
        "(defn (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 20)",
        Value.i64(6765),
    );
    try regvm_type_track.run(
        rt,
        "(defn (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 25)",
        Value.i64(75025),
    );
    try regvm_type_track.run(rt, "(defn (loop n) (if (< n 1) n (loop (- n 1)))) (loop 100000)", Value.i64(0));

    // Separate evalString calls retain definitions in the same runtime.
    _ = try rt.evalString("(defn (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))");
    try std.testing.expectEqual(Value.i64(55), try rt.evalString("(fib 10)"));
    _ = try rt.evalString("(defn (loop n) (if (< n 1) n (loop (- n 1))))");
    try std.testing.expectEqual(Value.i64(0), try rt.evalString("(loop 100)"));

    // Mask ON (skipped zeroing) vs mask OFF (all-ones, the old behavior):
    // every self-recursive program must produce the identical result — the
    // masked zeroing is behavior-preserving.
    const onoff = struct {
        fn go(rt_: *Runtime, src: []const u8, expected: Value) !void {
            rt_.compiler_opts.self_call_zero_mask = true;
            const on_val = try regvm_type_track.exec(rt_, src);
            rt_.compiler_opts.self_call_zero_mask = false;
            const off_val = try regvm_type_track.exec(rt_, src);
            try std.testing.expectEqual(expected, on_val);
            try std.testing.expectEqual(off_val, on_val);
            rt_.compiler_opts.self_call_zero_mask = true;
        }
    }.go;

    try onoff(rt, "(defn (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 20)", Value.i64(6765));
    try onoff(rt, "(defn (fact n) (if (< n 1) 1 (* n (fact (- n 1))))) (fact 10)", Value.i64(3628800));
    try onoff(rt, "(defn (loop n) (if (< n 1) n (loop (- n 1)))) (loop 50000)", Value.i64(0));
    try onoff(rt, "(defn (acc n a) (if (< n 1) a (acc (- n 1) (+ a n)))) (acc 1000 0)", Value.i64(500500));
    try onoff(
        rt,
        "(defn (even? n) (if (= n 0) 1 (odd? (- n 1)))) (defn (odd? n) (if (= n 0) 0 (even? (- n 1)))) (even? 100)",
        Value.i64(1),
    );
    try onoff(rt, "(defn (g x) (if (i64? x) (+ x 1) x)) (g 41)", Value.i64(42));
}

test "regvm: tail calls reuse the current frame (TCO)" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // Helper: run one program and expect an exact result Value.
    const run = struct {
        fn go(rt_: *Runtime, src: []const u8, expected: Value) !void {
            const forms = try skript.Reader.readAll(rt_.store, src);
            const prog = try rt_.compileData(rt_.root_ns, forms, null);
            const stack = try std.testing.allocator.alloc(Object, frame_size + @as(usize, prog.nregs) * 2);
            defer std.testing.allocator.free(stack);
            @memset(stack, .null);
            var fib: Fiber = .{
                .stack = stack,
                // sp starts one past the top-level register window (see main.zig).
                .sp = frame_size + @as(usize, prog.nregs) * 2,
                .ip = prog.ir.ptr,
                .ir = prog.ir,
                .nregs = prog.nregs,
                .consts = prog.constants,
                .fns = prog.fns,
                .ns = rt_.root_ns,
            };
            try std.testing.expectEqual(expected, try rt_.runToCompletion(rt_.root_ns, &fib));
        }
    }.go;

    // Self tail recursion: 100000 iterations with ONE frame. A frame-per-call
    // implementation would need ~35MB of stack and seconds here.
    try run(rt, "(defn (loop n) (if (< n 1) n (loop (- n 1)))) (loop 100000)", Value.i64(0));

    // Non-tail recursion is unchanged.
    try run(rt, "(defn (fact n) (if (< n 2) 1 (* n (fact (- n 1))))) (fact 10)", Value.i64(3628800));

    // Mutual tail recursion across two functions. (#t/#f are the language's
    // bool literals; `true`/`false` are unbound symbols, see Reader.zig.)
    const mutual_trampoline =
        "(defn (even? n) (if (= n 0) #t (odd? (- n 1)))) " ++
        "(defn (odd? n) (if (= n 0) #f (even? (- n 1)))) (even? 100000)";
    try run(rt, mutual_trampoline, Value.bool(true));

    // Arity-2 tail call passing a parameter through.
    try run(rt, "(defn (loop x n) (if (< n 1) x (loop x (- n 1)))) (loop 7 100000)", Value.i64(7));

    // Overlapping self-tail arguments rotate through the same register frame.
    try run(
        rt,
        "(defn (rotate n a b c) (if (= n 0) (+ (* a 100) (+ (* b 10) c)) " ++
            "(rotate (- n 1) b c a))) (rotate 8 1 2 3)",
        Value.i64(312),
    );

    // A rest parameter is rebuilt before self-tail arguments overwrite the
    // original register window.
    try run(
        rt,
        "(defn (rest-loop n . xs) (if (= n 0) xs (rest-loop (- n 1) n 42))) " ++
            "(equal? (rest-loop 1 7 8) (list 1 42))",
        Value.true,
    );

    // A tail callee may need a wider frame than its caller's register window.
    try run(
        rt,
        "(defn (wide a b c d e f g h) (+ a (+ b (+ c (+ d (+ e (+ f (+ g h)))))))) " ++
            "(defn (narrow x) (wide x 1 2 3 4 5 6 7)) (narrow 8)",
        Value.i64(36),
    );

    // Tail call in ONE branch of an if, literal in the other: the join-point
    // epilogue must still run for the literal path.
    try run(rt, "(defn (f n) (if (< n 1) 0 (f (- n 1)))) (f 50000)", Value.i64(0));

    // After a tail-call chain the ORIGINAL caller's constant table must be
    // restored: the top-level load of 9000000 (const idx 3) must NOT read
    // loop's table, where idx 3 is the branch constant 42 (regression: the
    // replaced frame must inherit the old frame's consts, not the current
    // function's).
    try run(rt, "(defn (loop n) (if (< n 1) 42 (loop (- n 1)))) (loop 100000) (+ 9000000 1)", Value.i64(9000001));
}

test "apply forwards a proper argument list without changing call errors" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try std.testing.expectEqual(Value.i64(5), try rt.evalString("(apply @i64.add (list 2 3))"));
    try std.testing.expectEqual(Value.true, try rt.evalString(
        "(equal? (apply @list 1 (list 2 3)) (list 1 2 3))",
    ));
    try std.testing.expectEqual(Value.nil, try rt.evalString("(apply (fn args args) nil)"));
    try std.testing.expectError(error.TypeMismatch, rt.evalString("(apply @i64.add (cons 2 3))"));
    try std.testing.expectError(error.ArityMismatch, rt.evalString("(apply @i64.add nil)"));
}

test "apply handles large rest lists, method and type calls, and nested forwarding" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try std.testing.expectEqual(Value.i64(300), try rt.evalString(
        "(apply (fn xs (length xs)) (range 300))",
    ));
    try std.testing.expectEqual(Value.i64(5), try rt.evalString(
        "(apply + (list 2 3))",
    ));
    try std.testing.expectEqual(Value.i64(9), try rt.evalString(
        "(apply i64 (list 9))",
    ));
    try std.testing.expectEqual(Value.i64(5), try rt.evalString(
        "(apply @apply (list @i64.add (list 2 3)))",
    ));
    try std.testing.expectEqual(Value.i64(5), try rt.evalString(
        "(let ((forward @apply)) (forward @i64.add (list 2 3)))",
    ));
    try std.testing.expectEqual(Value.i64(7), try rt.evalString(
        "(let ((apply (fn (f xs) 7))) (apply @i64.add (list 2 3)))",
    ));
}

test "tail apply retains its continuation and native apply resumes" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try std.testing.expectEqual(Value.i64(0), try rt.evalString(
        "(defn (countdown n) (if (< n 1) 0 (apply countdown (list (- n 1))))) (countdown 1000)",
    ));
    const native = try rt.spawnEval("(apply sleep (list 1)) 42");
    try std.testing.expectEqual(Value.i64(42), try rt.awaitProcess(native));
    const closure = try rt.spawnEval("(apply (fn (n) (sleep n) (+ n 1)) (list 1))");
    try std.testing.expectEqual(Value.i64(2), try rt.awaitProcess(closure));
}

test "regvm: tail call arity underflow errors like .call" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // (f) passes 0 args for f's 1 param — the tail call must fail BEFORE the
    // frame is replaced, leaving the fiber in a consistent state.
    const forms = try skript.Reader.readAll(rt.store, "(defn (f x) (if (< x 1) 0 (f))) (f 5)");
    const prog = try rt.compileData(rt.root_ns, forms, null);
    const stack = try std.testing.allocator.alloc(Object, frame_size + @as(usize, prog.nregs) * 2);
    defer std.testing.allocator.free(stack);
    @memset(stack, .null);
    var fib: Fiber = .{
        .stack = stack,
        .sp = frame_size + @as(usize, prog.nregs) * 2,
        .ip = prog.ir.ptr,
        .ir = prog.ir,
        .nregs = prog.nregs,
        .consts = prog.constants,
        .fns = prog.fns,
        .ns = rt.root_ns,
    };
    try std.testing.expectEqual(.done, try rt.evalReg(rt.root_ns, &fib, std.math.maxInt(u32)));
    // Errors-as-values: the uncaught error completes the fiber with an error
    // VALUE in r0 (host code recovers the Zig error via unwrapError).
    const res = fib.getReg(0);
    try std.testing.expectEqual(b.type_error, res.typ);
    try std.testing.expectEqual(error.ArityMismatch, res.errorCode());
}

test "raise/try/catch/guard: error system battery" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // (try (raise "boom") (fn (e) ...)) — the payload is the raised value.
    const caught = try rt.evalString("(try (raise \"boom\") (fn (e) (list \"caught\" e)))");
    try std.testing.expectEqual(b.type_cons, caught.typ);
    const ccell = caught.obj.toRef().deref([2]Value);
    try std.testing.expectEqualStrings("caught", std.mem.sliceTo(ccell[0].obj.toPtr([*]u8), 0));
    try std.testing.expectEqualStrings(
        "boom",
        std.mem.sliceTo(ccell[1].obj.toRef().deref([2]Value)[0].obj.toPtr([*]u8), 0),
    );

    // No raise: the body value is the try's value.
    try std.testing.expectEqual(Value.i64(3), try rt.evalString("(try (+ 1 2) (fn (e) 99))"));
    // The payload is a value.
    try std.testing.expectEqual(Value.i64(43), try rt.evalString("(try (raise 42) (fn (e) (+ e 1)))"));
    // catch sugar.
    const handled = try rt.evalString("(try (raise \"x\") (catch e (list \"handled\" e)))");
    try std.testing.expectEqual(b.type_cons, handled.typ);
    try std.testing.expectEqualStrings(
        "handled",
        std.mem.sliceTo(handled.obj.toRef().deref([2]Value)[0].obj.toPtr([*]u8), 0),
    );
    // Nesting: a handler raise propagates to the enclosing try.
    try std.testing.expectEqual(
        Value.i64(2),
        try rt.evalString("(try (try (raise 1) (fn (e) (raise (+ e 1)))) (fn (e) e))"),
    );
    // Nested try inside a handler.
    try std.testing.expectEqual(
        Value.i64(3),
        try rt.evalString("(try (raise 1) (fn (e) (try (raise 2) (fn (e2) (+ e e2)))))"),
    );
    // try catches SYSTEM errors as error values (05 §5.4).
    try std.testing.expectEqual(Value.true, try rt.evalString("(try (fst 42) (catch e (is-instance-of? @Error e)))"));
    // A handler raise propagates: the process records error.Raised + payload.
    const raise2 = try rt.spawnEval("(try (raise \"x\") (catch e (raise \"y\")))");
    try std.testing.expectError(error.Raised, rt.awaitProcess(raise2));
    try std.testing.expectEqual(b.type_string, raise2.raised.typ);
    try std.testing.expectEqualStrings("y", std.mem.sliceTo(raise2.raised.obj.toPtr([*]u8), 0));
    // guard with an else clause.
    const guard_res = try rt.evalString("(guard (e (else (list \"err\" e))) (raise \"oops\"))");
    try std.testing.expectEqual(b.type_cons, guard_res.typ);
    try std.testing.expectEqualStrings(
        "err",
        std.mem.sliceTo(guard_res.obj.toRef().deref([2]Value)[0].obj.toPtr([*]u8), 0),
    );
    // guard re-raises when no clause matches (no else): the process records
    // error.Raised with the payload preserved.
    const g2 = try rt.spawnEval("(guard (e ((string? e) :string)) (raise 7))");
    try std.testing.expectError(error.Raised, rt.awaitProcess(g2));
    // guard catches SYSTEM errors as error values: fst on a non-cons.
    try std.testing.expectEqual(
        Value.true,
        try rt.evalString("(guard (e (else (is-instance-of? @Error e))) (fst 42))"),
    );
    // An uncaught raise inside a spawned process: the process dies with
    // error.Raised and the payload recorded in proc.raised.
    const sp = try rt.spawnEval("(def p (spawn (fn () (raise 5)))) p");
    const pid_val = try rt.awaitProcess(sp);
    const proc = pid_val.obj.toPtr(*sched_mod.Process);
    try std.testing.expectError(error.Raised, rt.awaitProcess(proc));
    try std.testing.expectEqual(Value.i64(5), proc.raised);
    // Direct: an uncaught raise in evalString returns error.Raised (the unwrapError contract).
    try std.testing.expectError(error.Raised, rt.evalString("(raise \"boom\")"));
    // error? recognizes a caught error VALUE: a system error (fst on a
    // non-cons) is delivered to the handler as an error value. (A bare
    // (raise X) propagates before error? can run, and a caught raise binds
    // the raw payload — error? on that payload would be #f.)
    try std.testing.expectEqual(Value.true, try rt.evalString("(error? (try (fst 42) (fn (e) e)))"));
}

test "compiled errors identify the failing source occurrence" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const forms = try skript.Reader.readAll(rt.store, "(defn (f x) (+ x 1)) (f 5)");
    const prog = try rt.compileData(rt.root_ns, forms, null);
    const stack = try std.testing.allocator.alloc(Object, frame_size + @as(usize, prog.nregs) * 2);
    defer std.testing.allocator.free(stack);
    @memset(stack, .null);
    var fib: Fiber = .{
        .stack = stack,
        .sp = frame_size + @as(usize, prog.nregs) * 2,
        .ip = prog.ir.ptr,
        .ir = prog.ir,
        .nregs = prog.nregs,
        .consts = prog.constants,
        .fns = prog.fns,
        .ns = rt.root_ns,
    };
    try std.testing.expectEqual(Value.i64(6), try rt.runToCompletion(rt.root_ns, &fib));

    // An error INSIDE the compiled function yields the error value with the
    // failing node's DFS index; the node maps back to the source tree.
    const eforms = try skript.Reader.readAll(rt.store, "(defn (g x) (nope x)) (g 1)");
    const eprog = try rt.compileData(rt.root_ns, eforms, null);
    const estack = try std.testing.allocator.alloc(Object, frame_size + @as(usize, eprog.nregs) * 2);
    defer std.testing.allocator.free(estack);
    @memset(estack, .null);
    var efib: Fiber = .{
        .stack = estack,
        .sp = frame_size + @as(usize, eprog.nregs) * 2,
        .ip = eprog.ir.ptr,
        .ir = eprog.ir,
        .nregs = eprog.nregs,
        .consts = eprog.constants,
        .fns = eprog.fns,
        .ns = rt.root_ns,
    };
    const err_val = try rt.runToCompletion(rt.root_ns, &efib);
    try std.testing.expectEqual(b.type_error, err_val.typ);
    const src, const idx = err_val.errorLocation();
    try std.testing.expect(src.typ == b.type_cons);
    const node = rt.dfsNodeAt(src, idx);
    try std.testing.expectEqual(b.type_symbol, node.typ);
    try std.testing.expectEqualStrings("nope", node.obj.toPtr(Sym).*);
}

test "error values: error?/error-name and rich payload round-trip" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try std.testing.expectEqual(Value.true, try rt.evalString("(error? (try (fst 42) (fn (e) e)))"));
    try std.testing.expectEqual(Value.false, try rt.evalString("(error? 42)"));
    const name = try rt.evalString("(error-name (try (fst 42) (fn (e) e)))");
    try std.testing.expectEqualStrings("TypeMismatch", std.mem.sliceTo(name.obj.toPtr([*]u8), 0));
    // The prelude error alias raises.
    const raised = try rt.evalString("(try (error \"bad arg\") (catch e e))");
    try std.testing.expectEqualStrings("bad arg", std.mem.sliceTo(raised.obj.toPtr([*]u8), 0));
}

test "Phase C: spawn/send/receive roundtrip through closure capture" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // The top-level def returns the parent's pid. The parent spawns a child
    // that sends 99 back to it (`parent` resolves through the namespace), then
    // suspends on receive; the child's send re-enqueues it and the
    // re-dispatched receive returns 99. Exercises closure creation in the
    // spawned fiber (nested make_closure via the closure's fns table), child
    // spawn, send, the event wake, and receive re-dispatch.
    const src =
        \\(def parent (spawn (fn () (let ((child (spawn (fn () (send parent 99))))) (receive)))))
    ;
    const top = try rt.spawnEval(src);
    const pid_val = try rt.awaitProcess(top);
    try std.testing.expect(Value.isPid(pid_val));
    const parent = pid_val.obj.toPtr(*sched_mod.Process);
    try std.testing.expectEqual(Value.i64(99), try rt.awaitProcess(parent));
}

test "Phase C: host send wakes a parked runner (event.set path)" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // The spawned process suspends on receive; its runner parks on the
    // scheduler event. The HOST delivers the message through the pub send
    // intrinsic — the enqueue + event.set() un-parks the runner and the
    // re-dispatched receive returns the message.
    const top = try rt.spawnEval("(spawn (fn () (receive)))");
    const pid_val = try rt.awaitProcess(top);
    try std.testing.expect(Value.isPid(pid_val));
    const proc = pid_val.obj.toPtr(*sched_mod.Process);
    try std.testing.expectEqual(
        Value.i64(99),
        try intrin.process.send(rt.context(), .nil, .nil, &.{ pid_val, Value.i64(99) }),
    );
    // Bounded poll instead of awaitProcess: a lost event.set would make the
    // await hang forever. The send path completes in milliseconds — 200
    // iterations x 10ms gives a 2s budget before failing the test.
    var waited: u32 = 0;
    const res = while (waited < 200) : (waited += 1) {
        if (rt.pollProcess(proc)) |v| break (try v);
        std.Io.sleep(rt.io, std.Io.Duration.fromMilliseconds(10), .awake) catch |err| switch (err) {
            error.Canceled => return error.Unimplemented, // no cancellation in v1
        };
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(Value.i64(99), res);
}

test "Phase C: sleep suspends through the deadline path" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // (sleep 5) sets an absolute deadline and suspends; the runner's idle
    // path parks until the deadline, then re-enqueues the process and the
    // re-dispatched sleep returns nil; the body then yields 42. The
    // wall-clock lower bound catches a no-op/busy-wait sleep, which would
    // complete in ~1ms instead of the full 5ms.
    const started = std.Io.Clock.awake.now(rt.io).nanoseconds;
    const top = try rt.spawnEval("(spawn (fn () (sleep 5) 42))");
    const pid_val = try rt.awaitProcess(top);
    try std.testing.expect(Value.isPid(pid_val));
    const proc = pid_val.obj.toPtr(*sched_mod.Process);
    try std.testing.expectEqual(Value.i64(42), try rt.awaitProcess(proc));
    try std.testing.expect(proc.completed.load(.acquire));
    const elapsed_ns = std.Io.Clock.awake.now(rt.io).nanoseconds - started;
    const elapsed_ms: i64 = @intCast(@divTrunc(elapsed_ns, std.time.ns_per_ms));
    try std.testing.expect(elapsed_ms >= 3);
}

test "Phase C: alive? tracks process completion" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const top = try rt.spawnEval("(spawn (fn () 42))");
    const pid_val = try rt.awaitProcess(top);
    try std.testing.expect(Value.isPid(pid_val));
    const proc = pid_val.obj.toPtr(*sched_mod.Process);
    // The runner may already have completed the spawned process by the
    // time we hold the pid; accept either state before awaiting.
    if (!proc.completed.load(.acquire)) {
        try std.testing.expectEqual(Value.i64(42), try rt.awaitProcess(proc));
    }
    try std.testing.expect(proc.completed.load(.acquire));
    try std.testing.expect(!(try intrin.process.@"alive?"(rt.context(), .nil, .nil, &.{pid_val})).obj.toBool());
}

test "Phase C: selective receive scans without consuming non-matches" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // The child sends 1, 2, 3. The parent selects 2 with a predicate; the
    // non-matching 1 and 3 must stay in the mailbox (1 is the next receive).
    const src =
        \\(def parent (spawn (fn () (let ((me (self))) (begin
        \\  (def c (spawn (fn () (send me 1) (send me 2) (send me 3) 0)))
        \\  (receive (fn (m) (= m 2)))
        \\  (receive))))))
    ;
    const top = try rt.spawnEval(src);
    const pid_val = try rt.awaitProcess(top);
    try std.testing.expect(Value.isPid(pid_val));
    const parent = pid_val.obj.toPtr(*sched_mod.Process);
    // The begin evaluates to the LAST form: the second receive, which must
    // see the still-queued 1 (FIFO order preserved past the selective pop).
    try std.testing.expectEqual(Value.i64(1), try rt.awaitProcess(parent));
}

test "Phase C: receive timeout returns the timeout-sentinel" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // No 9 ever arrives; (receive pred 50) must give up after ~50ms and
    // return the timeout-sentinel (an opaque value, distinct from any
    // message).
    const top = try rt.spawnEval("(spawn (fn () (receive (fn (m) (= m 9)) 50)))");
    const pid_val = try rt.awaitProcess(top);
    try std.testing.expect(Value.isPid(pid_val));
    const proc = pid_val.obj.toPtr(*sched_mod.Process);
    const res = try rt.awaitProcess(proc);
    try std.testing.expect(std.meta.eql(res, skript.intrinsics.process.timeoutSentinelValue()));
}

test "Phase C: receive timeout delivers a matching message when it arrives" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // The message arrives inside the window (the sender sleeps 5ms first):
    // the selective receive must return it, not time out.
    const src =
        \\(def parent (spawn (fn () (let ((me (self))) (begin
        \\  (def c (spawn (fn () (sleep 5) (send me 7))))
        \\  (receive (fn (m) (= m 7)) 200))))))
    ;
    const top = try rt.spawnEval(src);
    const pid_val = try rt.awaitProcess(top);
    const parent = pid_val.obj.toPtr(*sched_mod.Process);
    try std.testing.expectEqual(Value.i64(7), try rt.awaitProcess(parent));
}

test "Phase C: a child crash does not take down the scheduler" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // c2 crashes (unbound symbol); c1 still delivers 99 and the parent's
    // receive completes. The crash arm marks c2 crashed and the runner keeps
    // draining — the parent's await must not hang.
    const src =
        \\(def parent (spawn (fn () (let ((me (self))) (begin
        \\  (def c1 (spawn (fn () (send me 99))))
        \\  (def c2 (spawn (fn () (nope 1))))
        \\  (receive))))))
    ;
    const top = try rt.spawnEval(src);
    const pid_val = try rt.awaitProcess(top);
    const parent = pid_val.obj.toPtr(*sched_mod.Process);
    try std.testing.expectEqual(Value.i64(99), try rt.awaitProcess(parent));
}

test "Phase C: pid equality via the = method" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const top = try rt.spawnEval("(def p (spawn (fn () 1))) (= p p)");
    try std.testing.expectEqual(Value.true, try rt.awaitProcess(top));
}

test "equality is total over symbols and keywords (interned identity)" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // Keywords and symbols are interned, so `=`/`!=` is object identity.
    const same_kw = try rt.spawnEval("(= :a :a)");
    try std.testing.expectEqual(Value.true, try rt.awaitProcess(same_kw));
    const diff_kw = try rt.spawnEval("(= :a :b)");
    try std.testing.expectEqual(Value.false, try rt.awaitProcess(diff_kw));
    const same_sym = try rt.spawnEval("(= (quote a) (quote a))");
    try std.testing.expectEqual(Value.true, try rt.awaitProcess(same_sym));
    const ne_kw = try rt.spawnEval("(!= :a :b)");
    try std.testing.expectEqual(Value.true, try rt.awaitProcess(ne_kw));
    const ne_sym = try rt.spawnEval("(!= (quote a) (quote b))");
    try std.testing.expectEqual(Value.true, try rt.awaitProcess(ne_sym));

    // Identity holds across separate internings: the same spelling is one Sym.
    const interned = try rt.spawnEval("(let ((x :status)) (= x :status))");
    try std.testing.expectEqual(Value.true, try rt.awaitProcess(interned));

    // Mixed types stay a method miss, consistent with (= 1 "a").
    const mixed = try rt.spawnEval("(= :a (quote a))");
    try std.testing.expectError(error.ArityMismatch, rt.awaitProcess(mixed));
}

test "arith fast path is disabled when the operator head is shadowed" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // A let-shadow, a parameter, or a nested-closure capture of + must
    // dispatch the override, not the prelude builtin. Before the fix the
    // arith fast path missed these (it checked only redefined + root_ns) and
    // the specialized opcode returned the builtin result (3) instead of 42.
    const let_shadow = try rt.spawnEval("(let ((+ (fn (a b) 42))) (+ 1 2))");
    try std.testing.expectEqual(Value.i64(42), try rt.awaitProcess(let_shadow));
    const param_shadow = try rt.spawnEval("(defn (f +) (+ 1 2)) (f (fn (a b) 42))");
    try std.testing.expectEqual(Value.i64(42), try rt.awaitProcess(param_shadow));
    // A nested closure created inside a shadowing let: the closure resolves +
    // through its parent_ns (the let ns), so the fast path must not specialize
    // it. The nested fn's ctx now inherits the enclosing let's shadow set.
    const nested_closure = try rt.spawnEval("(let ((+ (fn (a b) 42))) ((fn (x) (+ x 2)) 1))");
    try std.testing.expectEqual(Value.i64(42), try rt.awaitProcess(nested_closure));
    const nested_in_defn = try rt.spawnEval("(defn (f x) (let ((+ (fn (a b) 42))) (+ x 2))) (f 1)");
    try std.testing.expectEqual(Value.i64(42), try rt.awaitProcess(nested_in_defn));

    // The builtin fast path is intact when nothing shadows the operator.
    const plain = try rt.spawnEval("(defn (g x) (+ x 1)) (g 5)");
    try std.testing.expectEqual(Value.i64(6), try rt.awaitProcess(plain));
}

test "@-names resolve only to intrinsics/constants, never a local binding" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // A let-bound @name must NOT resolve locally — it is a reserved prefix
    // that means intrinsic/constant only (mirroring HashMapNamespace at the
    // root). SmallNamespace used to resolve it, diverging from the root.
    const let_at = try rt.spawnEval("(let ((@foo 5)) @foo)");
    try std.testing.expectError(error.Unbound, rt.awaitProcess(let_at));

    // The real intrinsics still resolve through a let (SmallNamespace) scope.
    const through_let = try rt.spawnEval("(let ((x 1)) @true)");
    try std.testing.expectEqual(Value.true, try rt.awaitProcess(through_let));
}

test "f64 and i64 stay canonical across source and host namespace writes" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try std.testing.expectEqual(Value.i64(9), try rt.evalString("(i64 9)"));
    try std.testing.expectEqual(Value.f64(9.0), try rt.evalString("(f64 9)"));
    try std.testing.expectError(error.MalformedAst, rt.evalString("(def f64 (fn (x) x))"));
    try std.testing.expectError(error.MalformedAst, rt.evalString("(set! i64 42)"));
    try std.testing.expectError(error.MalformedAst, rt.evalString("(let ((i64 42)) i64)"));
    try std.testing.expectError(error.MalformedAst, rt.evalString("(fn (f64) f64)"));

    const f64_sym = try rt.store.getsym("f64");
    const i64_sym = try rt.store.getsym("i64");
    try std.testing.expectError(error.Denied, rt.nsBind(rt.root_ns, f64_sym, .i64(1)));
    try std.testing.expectError(error.Denied, rt.nsSet(rt.root_ns, i64_sym, .i64(1)));
    try std.testing.expectError(error.Denied, rt.nsAssign(rt.root_ns, i64_sym, .i64(1)));
    try std.testing.expectError(error.Denied, rt.nsUnbind(rt.root_ns, f64_sym));
    try std.testing.expectEqual(Value.typeValue(b.type_f64), try rt.nsGet(rt.root_ns, f64_sym));
}

test "Phase C: target crash propagates as the Zig error" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // The host's awaitProcess must surface a crashed target as an ERROR
    // (not a printed error value): the CLI's nonzero exit depends on it.
    const top = try rt.spawnEval("(nope 1)");
    try std.testing.expectError(error.Unbound, rt.awaitProcess(top));
}

test "Phase C: pollProcess before completion returns null, value after" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const top = try rt.spawnEval("(def p (spawn (fn () (sleep 30) 42)))");
    const pid_val = try rt.awaitProcess(top);
    const proc = pid_val.obj.toPtr(*sched_mod.Process);
    // The child sleeps 30ms; the runner parks until the deadline, so the
    // poll immediately after the parent's completion is deterministically
    // null (the child cannot have finished).
    try std.testing.expect(rt.pollProcess(proc) == null);
    try std.testing.expectEqual(Value.i64(42), try rt.awaitProcess(proc));
    // After the await, the poll reports the value.
    try std.testing.expectEqual(Value.i64(42), try rt.pollProcess(proc).?);
}

test "Phase C: one runner services back-to-back spawns" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // The first spawn dispatches the runner; the second must NOT dispatch a
    // second one — the active runner services the queue. Both complete.
    const a = try rt.spawnEval("(sleep 5) 11");
    const b_proc = try rt.spawnEval("(sleep 10) 22");
    try std.testing.expectEqual(Value.i64(11), try rt.awaitProcess(a));
    try std.testing.expectEqual(Value.i64(22), try rt.awaitProcess(b_proc));
    // Exactly ONE runner was ever dispatched (a broken dispatch guard would
    // show up as a second entry here) and it is still alive.
    try std.testing.expectEqual(@as(usize, 1), rt.scheduler.runners.items.len);
    try std.testing.expect(rt.scheduler.runner_active.load(.acquire));
}

test "Phase C: receive timeout-only form and negative sleep" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // (receive MS): timeout-only front pop; no message -> :timeout.
    const a = try rt.spawnEval("(spawn (fn () (receive 30)))");
    const pid_a = try rt.awaitProcess(a);
    const res = try rt.awaitProcess(pid_a.obj.toPtr(*sched_mod.Process));
    try std.testing.expect(std.meta.eql(res, skript.intrinsics.process.timeoutSentinelValue()));

    // (sleep -5) clamps to 0: the process must still complete with 42.
    const b_proc = try rt.spawnEval("(spawn (fn () (sleep -5) 42))");
    const pid_b = try rt.awaitProcess(b_proc);
    try std.testing.expectEqual(Value.i64(42), try rt.awaitProcess(pid_b.obj.toPtr(*sched_mod.Process)));
}

test "Phase C: process intrinsic type and arity errors" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const cases = [_]struct { src: []const u8, err: anyerror }{
        .{ .src = "(send 42 1)", .err = error.TypeMismatch }, // non-pid target
        .{ .src = "(spawn 42)", .err = error.TypeMismatch }, // non-closure
        .{ .src = "(alive? 42)", .err = error.TypeMismatch }, // non-pid
        .{ .src = "(self 1)", .err = error.ArityMismatch }, // arity
        .{ .src = "(send 1)", .err = error.ArityMismatch }, // arity
        .{ .src = "(receive 1 2)", .err = error.ArityMismatch }, // i64 first arg + second
        .{ .src = "(receive x 1 2)", .err = error.Unbound }, // too many args, x unbound
    };
    for (cases) |c| {
        const top = try rt.spawnEval(c.src);
        try std.testing.expectError(c.err, rt.awaitProcess(top));
    }
}
test "Phase C: receive re-suspends on an early non-matching wake" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // c1 delivers 1 at ~5ms (no match); the receive must re-suspend with its
    // original deadline, not re-arm it, and time out at ~30ms even though a
    // second message (2, at 40ms) arrives after. (Not discriminating: a
    // re-armed 35ms deadline also precedes the 40ms arrival — kept as the
    // basic re-suspend sanity check.) Then the matching variant: a 9 arriving
    // inside the window is returned.
    const src =
        \\(def parent (spawn (fn () (let ((me (self))) (begin
        \\  (def c1 (spawn (fn () (sleep 5) (send me 1))))
        \\  (def c2 (spawn (fn () (sleep 40) (send me 2))))
        \\  (receive (fn (m) (= m 9)) 30))))))
    ;
    const top = try rt.spawnEval(src);
    const pid_val = try rt.awaitProcess(top);
    const parent = pid_val.obj.toPtr(*sched_mod.Process);
    const res = try rt.awaitProcess(parent);
    try std.testing.expect(std.meta.eql(res, skript.intrinsics.process.timeoutSentinelValue()));

    // Matching variant: the 9 arrives at 20ms, inside the 30ms window.
    const src2 =
        \\(def parent (spawn (fn () (let ((me (self))) (begin
        \\  (def c1 (spawn (fn () (sleep 5) (send me 1))))
        \\  (def c9 (spawn (fn () (sleep 20) (send me 9))))
        \\  (receive (fn (m) (= m 9)) 50))))))
    ;
    const top2 = try rt.spawnEval(src2);
    const pid2 = try rt.awaitProcess(top2);
    try std.testing.expectEqual(Value.i64(9), try rt.awaitProcess(pid2.obj.toPtr(*sched_mod.Process)));

    // Discriminating variant: the non-matching 1 arrives at ~90ms — the
    // re-suspend must keep the ORIGINAL deadline (t0+100ms), not re-arm it
    // to t0+190ms — and the matching 9 arrives at ~150ms, AFTER the original
    // deadline but BEFORE a re-armed one. Correct code times out at 100ms
    // (timeout-sentinel); a re-armed deadline would still be live when the 9 arrives
    // and would return it. The detection band is ~90ms wide (the 9 must not
    // land inside the original 100ms window, where both codes return it).
    const src3 =
        \\(def parent (spawn (fn () (let ((me (self))) (begin
        \\  (def c1 (spawn (fn () (sleep 90) (send me 1))))
        \\  (def c9 (spawn (fn () (sleep 150) (send me 9))))
        \\  (receive (fn (m) (= m 9)) 100))))))
    ;
    const top3 = try rt.spawnEval(src3);
    const pid3 = try rt.awaitProcess(top3);
    const res3 = try rt.awaitProcess(pid3.obj.toPtr(*sched_mod.Process));
    try std.testing.expect(std.meta.eql(res3, skript.intrinsics.process.timeoutSentinelValue()));
}

test "Phase C: mailboxes are isolated per process" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // a and b each have their own collector; interleaved sends land only in
    // the right mailbox. Each relays its FIRST received value to the top;
    // the second values (2, 20) must stay in their own mailboxes — the top's
    // third receive times out, proving no cross-delivery.
    const src =
        \\(def top (self))
        \\(def a (spawn (fn () (let ((me (self))) (begin
        \\  (def ca (spawn (fn () (send me 1) (send me 2))))
        \\  (send top (receive)))))))
        \\(def b (spawn (fn () (let ((me (self))) (begin
        \\  (def cb (spawn (fn () (send me 10) (send me 20))))
        \\  (send top (receive)))))))
        \\(begin (receive) (receive) (receive (fn (m) #t) 100))
    ;
    const top = try rt.spawnEval(src);
    const res = try rt.awaitProcess(top);
    // The begin's last form: the timed receive -> :timeout (nothing else
    // ever reached the top's mailbox).
    try std.testing.expect(std.meta.eql(res, skript.intrinsics.process.timeoutSentinelValue()));
}

test "Phase C: three-deep spawn chain delivers to the top" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const src =
        \\(def me (self))
        \\(def a (spawn (fn () (begin
        \\  (def b (spawn (fn () (begin
        \\    (def c (spawn (fn () (send me 7))))
        \\    6))))
        \\  5))))
        \\(receive (fn (m) #t) 2000)
    ;
    const top = try rt.spawnEval(src);
    try std.testing.expectEqual(Value.i64(7), try rt.awaitProcess(top));
}

test "Phase C: deep non-tail recursion grows the fiber stack in a process" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const src =
        \\(def top (self))
        \\(def p (spawn (fn () (let ((me (self))) (begin
        \\  (defn (deep n) (if (= n 0) 0 (+ 1 (deep (- n 1)))))
        \\  (send top (deep 10000)))))))
        \\(receive (fn (m) #t) 5000)
    ;
    const top = try rt.spawnEval(src);
    try std.testing.expectEqual(Value.i64(10000), try rt.awaitProcess(top));
}

test "Phase C: predicate crash crashes the receiver, scheduler survives" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // The pred calls an unbound symbol -> the RECEIVING process crashes; the
    // top-level still completes (the runner continues).
    const src =
        \\(def me (self))
        \\(def parent (spawn (fn () (let ((me (self))) (begin
        \\  (def c (spawn (fn () (send me 5))))
        \\  (receive (fn (m) (nope))))))))
        \\(begin (send me 0) parent)
    ;
    const top = try rt.spawnEval(src);
    const pid_val = try rt.awaitProcess(top);
    const parent = pid_val.obj.toPtr(*sched_mod.Process);
    try std.testing.expectError(error.Unbound, rt.awaitProcess(parent));
}

test "Phase C: intrinsic predicate receives a string message" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // (receive symbol) — the @symbol intrinsic (makeSymbol) is arity-1, so it
    // works as a predicate; the string message "hi" satisfies it.
    const src =
        \\(def me (self))
        \\(def parent (spawn (fn () (let ((me (self))) (begin
        \\  (def c (spawn (fn () (send me "hi"))))
        \\  (receive symbol))))))
    ;
    const top = try rt.spawnEval(src);
    const pid_val = try rt.awaitProcess(top);
    const parent = pid_val.obj.toPtr(*sched_mod.Process);
    const res = try rt.awaitProcess(parent);
    try std.testing.expect(std.meta.eql(res.typ, skript.builtins.type_string));
}

test "Phase C: timeout of zero fires immediately" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const top = try rt.spawnEval("(spawn (fn () (receive (fn (m) (= m 1)) 0)))");
    const pid_val = try rt.awaitProcess(top);
    const res = try rt.awaitProcess(pid_val.obj.toPtr(*sched_mod.Process));
    try std.testing.expect(std.meta.eql(res, skript.intrinsics.process.timeoutSentinelValue()));
}

test "Phase C: awaitProcess is idempotent" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const top = try rt.spawnEval("(spawn (fn () 42))");
    const pid_val = try rt.awaitProcess(top);
    const proc = pid_val.obj.toPtr(*sched_mod.Process);
    try std.testing.expectEqual(Value.i64(42), try rt.awaitProcess(proc));
    // The poll does not consume: a second await returns the same value.
    try std.testing.expectEqual(Value.i64(42), try rt.awaitProcess(proc));
}

test "Phase C: message type round-trips (string, cons, f64, bool)" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const src =
        \\(def top (self))
        \\(def parent (spawn (fn () (let ((me (self))) (begin
        \\  (def c (spawn (fn () (send me "s") (send me (list 1 2)) (send me 3.5) (send me #t))))
        \\  (send top (list (receive) (receive) (receive) (receive))))))))
    ;
    const top = try rt.spawnEval(src);
    const pid_val = try rt.awaitProcess(top);
    const parent = pid_val.obj.toPtr(*sched_mod.Process);
    const res = try rt.awaitProcess(parent);
    // The relayed list holds all four messages IN ORDER — assert each.
    try std.testing.expect(std.meta.eql(res.typ, skript.builtins.type_cons));
    const c1 = res.obj.toRef().deref([2]Value);
    try std.testing.expect(std.meta.eql(c1[0].typ, skript.builtins.type_string));
    try std.testing.expectEqualStrings("s", c1[0].obj.toPtr([*]u8)[0..1]);
    const c2 = c1[1].obj.toRef().deref([2]Value);
    try std.testing.expect(std.meta.eql(c2[0].typ, skript.builtins.type_cons)); // (1 2)
    const c3 = c2[1].obj.toRef().deref([2]Value);
    try std.testing.expect(std.meta.eql(c3[0].typ, skript.builtins.type_f64));
    try std.testing.expectEqual(@as(f64, 3.5), c3[0].obj.tof64());
    const c4 = c3[1].obj.toRef().deref([2]Value);
    try std.testing.expect(std.meta.eql(c4[0].typ, skript.builtins.type_bool));
    try std.testing.expect(c4[0].obj.toBool());
    try std.testing.expect(std.meta.eql(c4[1].typ, skript.builtins.type_nil));
}

test "Phase C: a send does not interrupt a sleep" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // The child sleeps 300ms; w delivers a message at ~50ms, WHILE the child
    // is parked in the sleep. The sleep must NOT abort early (regression: the
    // resume path used to clear the deadline unconditionally) — the send
    // wakes the child, which re-suspends with its deadline intact, wakes at
    // ~300ms, then receives the waiting message. The elapsed wall time must
    // be >= the full sleep. (An immediate top-level send would land while the
    // child is still queued and never exercise the resume path.)
    const src =
        \\(def top (self))
        \\(def p (spawn (fn () (let ((me (self))) (begin
        \\  (sleep 300)
        \\  (send top (receive)))))))
        \\(def w (spawn (fn () (sleep 50) (send p 7))))
        \\(receive (fn (m) #t) 2000)
    ;
    const started = std.Io.Clock.awake.now(rt.io).nanoseconds;
    const top = try rt.spawnEval(src);
    try std.testing.expectEqual(Value.i64(7), try rt.awaitProcess(top));
    const elapsed_ns = std.Io.Clock.awake.now(rt.io).nanoseconds - started;
    const elapsed: i64 = @intCast(@divTrunc(elapsed_ns, std.time.ns_per_ms));
    // An interrupted sleep would return in ~60ms; a full sleep in ~300ms.
    try std.testing.expect(elapsed >= 250);
}

test "Phase C: alive? is false after a crash" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const top = try rt.spawnEval("(def p (spawn (fn () (nope 1))))");
    const pid_val = try rt.awaitProcess(top);
    const proc = pid_val.obj.toPtr(*sched_mod.Process);
    try std.testing.expectError(error.Unbound, rt.awaitProcess(proc));
    try std.testing.expect(!(try intrin.process.@"alive?"(rt.context(), .nil, .nil, &.{pid_val})).obj.toBool());
}

test "Phase C: spawnEval surfaces parse errors" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try std.testing.expectError(error.UnexpectedToken, rt.spawnEval("(def"));
}

test "Phase C: empty source evaluates to nil" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const top = try rt.spawnEval("");
    try std.testing.expect(Value.isNil(try rt.awaitProcess(top)));
}

test "Phase C: two runtimes are isolated" {
    var rt1 = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt1.deinit();
    var rt2 = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt2.deinit();

    const a = try rt1.spawnEval("(sleep 5) 11");
    const b2 = try rt2.spawnEval("(sleep 10) 22");
    try std.testing.expectEqual(Value.i64(11), try rt1.awaitProcess(a));
    try std.testing.expectEqual(Value.i64(22), try rt2.awaitProcess(b2));
}

test "Phase C: self-send then selective receive" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // The self-send delivers without a wake (the sender is the running
    // process); the selective receive then scans it out.
    const src =
        \\(def top (self))
        \\(def p (spawn (fn () (send (self) 3) (send top (receive (fn (m) (= m 3)))))))
        \\(receive (fn (m) #t) 2000)
    ;
    const top = try rt.spawnEval(src);
    try std.testing.expectEqual(Value.i64(3), try rt.awaitProcess(top));
}

test "Phase C: runner re-dispatch after a target crash" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // The first target crashes -> the runner exits (runner_active false);
    // the next spawn must dispatch a fresh runner, and the drain must
    // consume BOTH runner futures at deinit. completeProcess stores the
    // error BEFORE runner_active.store(false), so the host can observe the
    // crash while the runner is still winding down — spin briefly for the
    // exit store before asserting.
    const a = try rt.spawnEval("(nope 1)");
    try std.testing.expectError(error.Unbound, rt.awaitProcess(a));
    var spins: u32 = 0;
    while (rt.scheduler.runner_active.load(.acquire) and spins < 100) : (spins += 1) {
        std.Io.sleep(rt.io, std.Io.Duration.fromMilliseconds(1), .awake) catch |err| switch (err) {
            error.Canceled => return error.Unimplemented, // no cancellation in v1
        };
    }
    try std.testing.expect(!rt.scheduler.runner_active.load(.acquire));
    const b2 = try rt.spawnEval("(sleep 5) 33");
    try std.testing.expectEqual(Value.i64(33), try rt.awaitProcess(b2));
    // Two runner futures were ever dispatched; the deinit drain consumes
    // both (a missed drain surfaces as a deinit leak/allocator error).
    try std.testing.expectEqual(@as(usize, 2), rt.scheduler.runners.items.len);
}

test "Phase C: selective receive under 50-sender load" {
    // 52-process stress workload: the default 1 MiB test-mode store cap is
    // exhausted by the grown prelude + compiled programs (OutOfMemory kills
    // the collector, stranding senders). Bump this test's heap only.
    var rt = try Runtime.initWithConfig(std.testing.allocator, std.testing.io, .{
        .max_heap_size = 64 * 1024 * 1024,
    });
    defer rt.deinit();

    // 50 senders deliver 1..50; the collector selectively pulls the value
    // 25 (only it matches), then drains the remaining 49 (their sum is
    // 1+..+50 - 25 = 1250).
    const src =
        \\(def top (self))
        \\(def coll (spawn (fn () (let ((me (self))) (begin
        \\  (defn (spawn-n n) (if (= n 0) 0 (begin (def p (spawn (fn () (send me n)))) (spawn-n (- n 1)))))
        \\  (spawn-n 50)
        \\  (def picked (receive (fn (m) (= m 25))))
        \\  (defn (drain n acc) (if (= n 0) acc (drain (- n 1) (+ acc (receive)))))
        \\  (send top (list picked (drain 49 0))))))))
        \\(receive (fn (m) #t) 5000)
    ;
    const top = try rt.spawnEval(src);
    const res = try rt.awaitProcess(top);
    // The relayed list: (25 1250) — check the fst and the second element.
    try std.testing.expect(std.meta.eql(res.typ, skript.builtins.type_cons));
    const cell = res.obj.toRef().deref([2]Value);
    try std.testing.expectEqual(Value.i64(25), cell[0]);
    const rest = cell[1].obj.toRef().deref([2]Value);
    try std.testing.expectEqual(Value.i64(1250), rest[0]);
}

test "Phase C: keyword message round-trip" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // A real :timeout keyword as a MESSAGE value survives delivery — and,
    // since the receive-timeout is now the opaque sentinel (not a keyword),
    // a genuine :timeout message round-trips as type_keyword, provably
    // distinct from a receive timeout.
    const src =
        \\(def top (self))
        \\(def parent (spawn (fn () (let ((me (self))) (begin
        \\  (def c (spawn (fn () (send me :timeout))))
        \\  (send top (receive)))))))
        \\(receive (fn (m) #t) 2000)
    ;
    const top = try rt.spawnEval(src);
    const res = try rt.awaitProcess(top);
    try std.testing.expect(std.meta.eql(res.typ, skript.builtins.type_keyword));
    try std.testing.expectEqualStrings("timeout", res.obj.toPtr(Sym).*);
}

test "native receive predicates reject suspension without consuming mail" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const top = try rt.spawnEval(
        \\(send (self) 7)
        \\(def failure (try
        \\  (receive (fn (m) (begin (sleep 3000) (= m 7))) 200)
        \\  (catch e (error-name e))))
        \\(list failure (receive))
    );
    const result = try rt.awaitProcess(top);
    const first = result.obj.toRef().deref([2]Value);
    try std.testing.expectEqual(b.type_string, first[0].typ);
    try std.testing.expectEqualStrings("Denied", std.mem.span(first[0].obj.toPtr([*:0]const u8)));
    const second = first[1].obj.toRef().deref([2]Value);
    try std.testing.expectEqual(Value.i64(7), second[0]);
}

test "actors spawned from native callbacks own independent continuations" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const top = try rt.spawnEval(
        \\(def top (self))
        \\(def children (map (list 1) (fn (x)
        \\  (spawn (fn () (send top (receive)))))))
        \\(send (fst children) 42)
        \\(receive)
    );
    try std.testing.expectEqual(Value.i64(42), try rt.awaitProcess(top));
}

// --- Phase D: module system ---
// Module files load once per canonical path, each in its own process; the
// caller suspends until the load completes and receives the module ns.
// Access is keyword-as-getter: (:sym NS).

/// Phase D helper: a unique temp dir for module files, removed on deinit.
/// `write` returns the CANONICAL absolute path of the written file — the load
/// intrinsic registers modules under realpath'd keys, so the tests use the
/// canonical path for both the `(load ...)` string and registry assertions.
const ModuleTmp = struct {
    dir: []u8, // absolute path, allocator-owned
    alloc: Allocator,
    var seq: std.atomic.Value(u32) = .init(0);

    fn init(alloc: Allocator, io: std.Io) !ModuleTmp {
        const n = seq.fetchAdd(1, .monotonic);
        const nanos = std.Io.Clock.awake.now(io).nanoseconds;
        const dir = try std.fmt.allocPrint(alloc, "/tmp/skript-modules-{d}-{d}", .{ nanos, n });
        errdefer alloc.free(dir);
        try std.Io.Dir.cwd().createDirPath(io, dir);
        return .{ .dir = dir, .alloc = alloc };
    }

    fn deinit(self: *ModuleTmp, io: std.Io) void {
        // Best-effort cleanup: a failed deleteTree (e.g. the temp dir was
        // already gone) must not panic the test run — the dir is in /tmp.
        // (deleteTree's error set has no FileNotFound member.)
        std.Io.Dir.cwd().deleteTree(io, self.dir) catch |err| switch (err) {
            error.Unexpected => {},
            else => std.log.warn("module test cleanup: {s} {s}", .{ @errorName(err), self.dir }),
        };
        self.alloc.free(self.dir);
        self.* = undefined;
    }

    /// Write a module file (subdirs auto-created); returns the canonical
    /// absolute path (allocator-owned — the caller frees it).
    fn write(self: *ModuleTmp, io: std.Io, name: []const u8, src: []const u8) ![:0]u8 {
        const joined = try std.fs.path.join(self.alloc, &.{ self.dir, name });
        defer self.alloc.free(joined);
        if (std.fs.path.dirname(joined)) |parent| {
            if (parent.len > self.dir.len) try std.Io.Dir.cwd().createDirPath(io, parent);
        }
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = joined, .data = src });
        return std.Io.Dir.cwd().realPathFileAlloc(io, joined, self.alloc);
    }
};

/// Phase D helper: `(load "<path>")` source with the path embedded.
/// Backslashes are DOUBLED so the path round-trips the reader's string
/// escapes verbatim: the reader treats `\` as an escape (`\t` → TAB,
/// `\s` → `s`), so a RAW Windows path (`Z:\tmp\lib.sk`) embedded verbatim
/// reaches the intrinsic mangled and fails the file read (BadPathName →
/// Unsupported via the intrinsic's error mapping). POSIX paths have no `\`
/// and pass through unchanged.
fn loadSrc(alloc: Allocator, path: []const u8) ![]u8 {
    const escaped = try escapePath(alloc, path);
    defer alloc.free(escaped);
    return std.fmt.allocPrint(alloc, "(load \"{s}\")", .{escaped});
}

/// Double every backslash in `path` (a plain copy when there are none).
fn escapePath(alloc: Allocator, path: []const u8) ![]u8 {
    if (std.mem.findScalar(u8, path, '\\') == null) return alloc.dupe(u8, path);
    var out = try std.ArrayList(u8).initCapacity(alloc, path.len +| 1);
    errdefer out.deinit(alloc);
    for (path) |ch| {
        if (ch == '\\') try out.append(alloc, '\\');
        try out.append(alloc, ch);
    }
    return out.toOwnedSlice(alloc);
}

/// `(def m (load "<path>")) <body>` — the common Phase D shape, with the
/// path embedded via escapePath (see loadSrc).
fn loadDefSrc(alloc: Allocator, path: []const u8, body: []const u8) ![]u8 {
    const escaped = try escapePath(alloc, path);
    defer alloc.free(escaped);
    return std.fmt.allocPrint(alloc, "(def m (load \"{s}\")) {s}", .{ escaped, body });
}

test "Phase D: load-once identity — repeat loads return the same namespace" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    const lib = try tmp.write(rt.io, "lib.sk", "(def x 42) (export x)");
    defer std.testing.allocator.free(lib);

    // Two loads of the same canonical path return type_namespace values that
    // are IDENTICAL (the registry returns the SAME stored Value on the hit).
    const src = try loadSrc(std.testing.allocator, lib);
    defer std.testing.allocator.free(src);
    const p1 = try rt.spawnEval(src);
    const ns1 = try rt.awaitProcess(p1);
    try std.testing.expect(std.meta.eql(ns1.typ, skript.builtins.type_namespace));
    const p2 = try rt.spawnEval(src);
    const ns2 = try rt.awaitProcess(p2);
    try std.testing.expect(std.meta.eql(ns2.typ, skript.builtins.type_namespace));
    try std.testing.expect(std.meta.eql(ns1, ns2));

    // The getter on the loaded namespace returns the module's binding.
    const getter_src = try loadDefSrc(std.testing.allocator, lib, "(:x m)");
    defer std.testing.allocator.free(getter_src);
    const p3 = try rt.spawnEval(getter_src);
    try std.testing.expectEqual(Value.i64(42), try rt.awaitProcess(p3));

    // Exactly ONE registry entry for the path, loaded.
    rt.scheduler.mutex.lockUncancelable(rt.io);
    defer rt.scheduler.mutex.unlock(rt.io);
    var count: usize = 0;
    for (rt.modules.entries.items) |entry| {
        if (std.mem.eql(u8, entry.path, lib)) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    const entry = rt.modules.findLocked(lib) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(mod_reg.Status.loaded, entry.status);
}

test "module exports hide private and prelude cells while preserving live assignments" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    const lib = try tmp.write(rt.io, "exports.pt", "(export public change) (def secret 7) (def public 2) " ++
        "(defn (change n) (set! public n) public)");
    defer std.testing.allocator.free(lib);
    const source = try loadSrc(std.testing.allocator, lib);
    defer std.testing.allocator.free(source);
    const loaded = try rt.spawnEval(source);
    const view = try rt.awaitProcess(loaded);
    const public = try rt.store.getsym("public");
    try std.testing.expectEqual(Value.i64(2), try rt.nsGet(view, public));
    try std.testing.expectError(error.Unbound, rt.nsGet(view, try rt.store.getsym("secret")));
    try std.testing.expectError(error.Unbound, rt.nsGet(view, try rt.store.getsym("i64")));
    try std.testing.expectError(error.Denied, rt.nsSet(view, public, .i64(99)));
    try std.testing.expectError(error.Denied, rt.nsBind(view, try rt.store.getsym("injected"), .i64(1)));
    try std.testing.expectError(error.Denied, rt.nsUnbind(view, public));

    const call = try loadDefSrc(std.testing.allocator, lib, "(begin ((:change m) 9) (:public m))");
    defer std.testing.allocator.free(call);
    const caller = try rt.spawnEval(call);
    try std.testing.expectEqual(Value.i64(9), try rt.awaitProcess(caller));
    try std.testing.expectEqual(Value.i64(9), try rt.nsGet(view, public));
}

test "module exports and selected imports preserve stored Error values" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    const lib = try tmp.write(rt.io, "errors.pt", "(export fault) (def fault (try (fst 1) (catch e e))) 0");
    defer std.testing.allocator.free(lib);
    const load_source = try loadSrc(std.testing.allocator, lib);
    defer std.testing.allocator.free(load_source);
    const view = try rt.awaitProcess(try rt.spawnEval(load_source));
    const stored = try rt.nsGet(view, try rt.store.getsym("fault"));
    try std.testing.expectEqual(b.type_error, stored.typ);
    try std.testing.expectEqual(error.TypeMismatch, stored.errorCode());

    const main_path = try tmp.write(rt.io, "main.pt", "");
    defer std.testing.allocator.free(main_path);
    const user = try rt.spawnEvalWithNs(
        "(use (errors :as errs :refer ((fault forwarded)))) " ++
            "(list (error? errs/fault) (error? (:fault errs)) (error? forwarded))",
        rt.root_ns,
        main_path,
    );
    const results = try rt.awaitProcess(user);
    const first = results.obj.toRef().deref([2]Value);
    try std.testing.expectEqual(Value.true, first[0]);
    const second = first[1].obj.toRef().deref([2]Value);
    try std.testing.expectEqual(Value.true, second[0]);
    try std.testing.expectEqual(Value.true, second[1].obj.toRef().deref([2]Value)[0]);
}

test "missing module exports fail before publication and remain failed" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    const lib = try tmp.write(rt.io, "missing-export.pt", "(export absent) (def available 1)");
    defer std.testing.allocator.free(lib);
    const source = try loadSrc(std.testing.allocator, lib);
    defer std.testing.allocator.free(source);
    const first = try rt.spawnEval(source);
    try std.testing.expectError(error.Unbound, rt.awaitProcess(first));
    const second = try rt.spawnEval(source);
    try std.testing.expectError(error.Unbound, rt.awaitProcess(second));
    rt.scheduler.mutex.lockUncancelable(rt.io);
    defer rt.scheduler.mutex.unlock(rt.io);
    const entry = rt.modules.findLocked(lib) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(mod_reg.Status.failed, entry.status);
    try std.testing.expect(entry.ns.isNil());
}

test "module load rejects an incomplete cached entry" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);
    const path = try tmp.write(rt.io, "incomplete.pt", "(def x 1)");
    defer std.testing.allocator.free(path);
    {
        rt.scheduler.mutex.lockUncancelable(rt.io);
        defer rt.scheduler.mutex.unlock(rt.io);
        _ = try rt.modules.insertLocked(rt.static, path, null);
    }
    const source = try loadSrc(std.testing.allocator, path);
    defer std.testing.allocator.free(source);
    const process = try rt.spawnEval(source);
    try std.testing.expectError(error.InvalidCode, rt.awaitProcess(process));
}

test "Phase D: load gates on completion; defs visible via getter; main ns clean" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    const lib = try tmp.write(rt.io, "lib.sk", "(def x 42) (export x)");
    defer std.testing.allocator.free(lib);

    // The load returns the module's namespace and blocks until the module
    // process completes: the def is visible through the getter immediately.
    const src = try loadDefSrc(std.testing.allocator, lib, "(:x m)");
    defer std.testing.allocator.free(src);
    const top = try rt.spawnEval(src);
    try std.testing.expectEqual(Value.i64(42), try rt.awaitProcess(top));

    // Hygiene on the MAIN side: the module's top-level `x` must NOT leak
    // into root_ns (the module binds into its own fresh namespace).
    const x_sym = try rt.store.getsym("x");
    try std.testing.expectError(error.Unbound, rt.nsGet(rt.root_ns, x_sym));
}

test "Phase D: module hygiene — importer defs invisible, prelude visible" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    // lib.sk references `secret`, which ONLY the importer defines: the module
    // ns chain (module ns → prelude snapshot) must not see the importer's
    // root_ns def, so the module process crashes with Unbound and the loader
    // crashes with the SAME error (crash isolation composes).
    const lib_bad = try tmp.write(rt.io, "lib_bad.sk", "(+ secret 1)");
    defer std.testing.allocator.free(lib_bad);
    const importer_esc = try escapePath(std.testing.allocator, lib_bad);
    defer std.testing.allocator.free(importer_esc);
    const importer_src =
        try std.fmt.allocPrint(std.testing.allocator, "(def secret 99) (load \"{s}\")", .{importer_esc});
    defer std.testing.allocator.free(importer_src);
    const top = try rt.spawnEval(importer_src);
    try std.testing.expectError(error.Unbound, rt.awaitProcess(top));

    // Positive control: the module CAN see the prelude ((+ 1 2) resolves).
    const lib_ok = try tmp.write(rt.io, "lib_ok.sk", "(def y (+ 1 2)) (export y)");
    defer std.testing.allocator.free(lib_ok);
    const ok_src = try loadDefSrc(std.testing.allocator, lib_ok, "(:y m)");
    defer std.testing.allocator.free(ok_src);
    const ok_top = try rt.spawnEval(ok_src);
    try std.testing.expectEqual(Value.i64(3), try rt.awaitProcess(ok_top));
}

test "Phase D: nested loads — module reaches another module's ns through a closure" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    // a.sk loads b.sk (relative to a.sk's own dir) and exposes a closure that
    // reads b's ns through a.sk's captured binding; main reaches B's ns via
    // A's. The getter retrieves the closure; calling it returns 7.
    const b_path = try tmp.write(rt.io, "b.sk", "(def x 7) (export x)");
    defer std.testing.allocator.free(b_path);
    const a_src = try std.fmt.allocPrint(
        std.testing.allocator,
        "(def m (load \"b.sk\")) (def get-b (fn () (:x m))) (export get-b)",
        .{},
    );
    defer std.testing.allocator.free(a_src);
    const a = try tmp.write(rt.io, "a.sk", a_src);
    defer std.testing.allocator.free(a);
    const main_src = try loadDefSrc(std.testing.allocator, a, "((:get-b m))");
    defer std.testing.allocator.free(main_src);
    const top = try rt.spawnEval(main_src);
    try std.testing.expectEqual(Value.i64(7), try rt.awaitProcess(top));
}

test "Phase D: module closure with nested fn — cross-program .call switches fib.fns" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    // mod.sk exposes a closure whose body contains a nested fn literal: the
    // body compiles to a make_closure op indexing mod's OWN function table.
    // When MAIN's process calls it, the evalReg .call arm must switch
    // fib.fns to the callee's table — otherwise the nested make_closure
    // indexes the caller's table with mod's absolute ftidx (OOB → GPF).
    // The fn literal is defined-and-called inline so the chain lands on 1.
    const mod = try tmp.write(rt.io, "mod.sk", "(defn (outer ) ((fn () 1))) (export outer)");
    defer std.testing.allocator.free(mod);
    const main_src = try loadDefSrc(std.testing.allocator, mod, "((:outer m))");
    defer std.testing.allocator.free(main_src);
    const top = try rt.spawnEval(main_src);
    try std.testing.expectEqual(Value.i64(1), try rt.awaitProcess(top));
}

test "Phase D: module closure calls another module's closure — cross-program x2" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    // b.sk's closure body contains a nested fn; a.sk's closure body does too
    // AND calls b's closure through a captured binding. Main's process → a's
    // closure → b's closure: TWO cross-program .call hops, each needing its
    // own fib.fns switch (and .tail_call/ret discipline) so every nested
    // make_closure indexes the table of the program it was compiled in.
    // The fn literals are defined-and-called inline (((fn () ...))) so the
    // chain lands on the value 42.
    const b_path = try tmp.write(rt.io, "b.sk", "(defn (get-cl ) ((fn () 42))) (export get-cl)");
    defer std.testing.allocator.free(b_path);
    const a_src = try std.fmt.allocPrint(
        std.testing.allocator,
        "(def m (load \"b.sk\")) (defn (outer ) ((fn () ((:get-cl m))))) (export outer)",
        .{},
    );
    defer std.testing.allocator.free(a_src);
    const a = try tmp.write(rt.io, "a.sk", a_src);
    defer std.testing.allocator.free(a);
    const main_src = try loadDefSrc(std.testing.allocator, a, "((:outer m))");
    defer std.testing.allocator.free(main_src);
    const top = try rt.spawnEval(main_src);
    try std.testing.expectEqual(Value.i64(42), try rt.awaitProcess(top));
}

test "Phase D: module spawner closure with nested spawn body — spawn + receive completes" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    // The full end-to-end repro: a module closure whose nested fn is the
    // body of a spawned process. The nested make_closure inside the module
    // closure body must resolve against the module's own function table;
    // the spawned process then sends :done back and the closure's receive
    // completes.
    const mod = try tmp.write(
        rt.io,
        "mod.sk",
        "(defn (spawner ) (let ((me (self))) (begin " ++
            "(spawn (fn () (begin (sleep 10) (send me :done)))) " ++
            "(receive)))) (export spawner)",
    );
    defer std.testing.allocator.free(mod);
    const main_src = try loadDefSrc(std.testing.allocator, mod, "((:spawner m))");
    defer std.testing.allocator.free(main_src);
    const top = try rt.spawnEval(main_src);
    const res = try rt.awaitProcess(top);
    try std.testing.expect(std.meta.eql(res.typ, skript.builtins.type_keyword));
    try std.testing.expectEqualStrings("done", res.obj.toPtr(Sym).*);
}

test "Phase D: diamond — shared module evaluated once, both loaders see the same ns" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    // A → C → E and A → D → E: E is loaded twice, but only ONE process runs
    // it and both C and D receive the SAME namespace value (identity).
    const e = try tmp.write(rt.io, "e.sk", "(def x 5) (export x)");
    defer std.testing.allocator.free(e);
    const c_src = "(def e-ns (load \"e.sk\")) (export e-ns)";
    const d_src = "(def e-ns (load \"e.sk\")) (export e-ns)";
    const c = try tmp.write(rt.io, "c.sk", c_src);
    defer std.testing.allocator.free(c);
    const d = try tmp.write(rt.io, "d.sk", d_src);
    defer std.testing.allocator.free(d);
    const a_src = "(def c-ns (load \"c.sk\")) (def d-ns (load \"d.sk\")) (export c-ns d-ns)";
    const a = try tmp.write(rt.io, "a.sk", a_src);
    defer std.testing.allocator.free(a);
    const main_src = try loadSrc(std.testing.allocator, a);
    defer std.testing.allocator.free(main_src);
    const top = try rt.spawnEval(main_src);
    const a_ns = try rt.awaitProcess(top);
    try std.testing.expect(std.meta.eql(a_ns.typ, skript.builtins.type_namespace));

    // Host-side: C's e-ns and D's e-ns are the SAME value.
    const c_ns = try rt.nsGet(a_ns, try rt.store.getsym("c-ns"));
    const d_ns = try rt.nsGet(a_ns, try rt.store.getsym("d-ns"));
    const e1 = try rt.nsGet(c_ns, try rt.store.getsym("e-ns"));
    const e2 = try rt.nsGet(d_ns, try rt.store.getsym("e-ns"));
    try std.testing.expect(std.meta.eql(e1, e2));
    try std.testing.expect(std.meta.eql(e1.typ, skript.builtins.type_namespace));

    // Registry: exactly ONE entry for e.sk, loaded.
    rt.scheduler.mutex.lockUncancelable(rt.io);
    defer rt.scheduler.mutex.unlock(rt.io);
    var e_count: usize = 0;
    for (rt.modules.entries.items) |entry| {
        if (std.mem.eql(u8, entry.path, e)) e_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), e_count);
    const e_entry = rt.modules.findLocked(e) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(mod_reg.Status.loaded, e_entry.status);
}

test "Phase D: load cycle A→B→A crashes the loader with error.CircularLoad" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    const a = try tmp.write(rt.io, "a.sk", "(load \"b.sk\")");
    defer std.testing.allocator.free(a);
    const b_path = try tmp.write(rt.io, "b.sk", "(load \"a.sk\")");
    defer std.testing.allocator.free(b_path);
    const main_src = try loadSrc(std.testing.allocator, a);
    defer std.testing.allocator.free(main_src);
    const top = try rt.spawnEval(main_src);
    // Scheduler wait-graph reachability detects the cycle; the module and
    // loader both crash with CircularLoad.
    try std.testing.expectError(error.CircularLoad, rt.awaitProcess(top));
}

test "Phase D: module crash propagates to the loader; failed module stays failed" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    // bad.sk crashes with TypeMismatch ((fst 1) type-asserts a cons; there is
    // no `car` in this prelude — fst is the equivalent accessor).
    const bad = try tmp.write(rt.io, "bad.sk", "(fst 1)");
    defer std.testing.allocator.free(bad);
    const src = try loadSrc(std.testing.allocator, bad);
    defer std.testing.allocator.free(src);
    const top = try rt.spawnEval(src);
    try std.testing.expectError(error.TypeMismatch, rt.awaitProcess(top));

    // A failed module STAYS failed: a second load reproduces the same error
    // (the registry records the crash and re-surfaces it).
    const top2 = try rt.spawnEval(src);
    try std.testing.expectError(error.TypeMismatch, rt.awaitProcess(top2));

    // Registry: the entry is marked failed.
    rt.scheduler.mutex.lockUncancelable(rt.io);
    defer rt.scheduler.mutex.unlock(rt.io);
    const entry = rt.modules.findLocked(bad) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(mod_reg.Status.failed, entry.status);
}

test "Phase D: missing module file maps to error.Unbound" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // The intrinsic maps FileNotFound onto Unbound (no file error in the
    // skript.Error set); the loader crashes with it.
    const top = try rt.spawnEval("(load \"/nonexistent/nope.sk\")");
    try std.testing.expectError(error.Unbound, rt.awaitProcess(top));
}

test "Phase D: relative load resolution uses the module's own dir" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    // main.sk lives in a SUBDIR and loads "lib.sk" by bare name: the intrinsic
    // resolves against dirname(main.sk's module_path) — the subdir — NOT the
    // process cwd (where no lib.sk exists).
    const lib = try tmp.write(rt.io, "sub/lib.sk", "(def x 42) (export x)");
    defer std.testing.allocator.free(lib);
    const main_path = try tmp.write(rt.io, "sub/main.sk", "(def m (load \"lib.sk\")) (:x m)");
    defer std.testing.allocator.free(main_path);
    const top = try rt.spawnEvalWithNs("(def m (load \"lib.sk\")) (:x m)", rt.root_ns, main_path);
    try std.testing.expectEqual(Value.i64(42), try rt.awaitProcess(top));

    // The resolved file is the subdir's lib.sk (registry key == its canonical
    // path), proving dirname(module_path) resolution, not cwd.
    rt.scheduler.mutex.lockUncancelable(rt.io);
    defer rt.scheduler.mutex.unlock(rt.io);
    const entry = rt.modules.findLocked(lib) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(mod_reg.Status.loaded, entry.status);
}

test "Phase D: keyword-getter (:sym ns) — value, Unbound, TypeMismatch" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    const lib = try tmp.write(rt.io, "lib.sk", "(def x 42) (export x)");
    defer std.testing.allocator.free(lib);

    // (:x m) → 42 (bound binding).
    const ok_src = try loadDefSrc(std.testing.allocator, lib, "(:x m)");
    defer std.testing.allocator.free(ok_src);
    const p_ok = try rt.spawnEval(ok_src);
    try std.testing.expectEqual(Value.i64(42), try rt.awaitProcess(p_ok));

    // (:missing m) → nsGet miss → Unbound crashes the loader.
    const miss_src = try loadDefSrc(std.testing.allocator, lib, "(:missing m)");
    defer std.testing.allocator.free(miss_src);
    const p_miss = try rt.spawnEval(miss_src);
    try std.testing.expectError(error.Unbound, rt.awaitProcess(p_miss));

    // (:x 42) → the argument is not a namespace → TypeMismatch.
    const tm_src = try loadDefSrc(std.testing.allocator, lib, "(:x 42)");
    defer std.testing.allocator.free(tm_src);
    const p_tm = try rt.spawnEval(tm_src);
    try std.testing.expectError(error.TypeMismatch, rt.awaitProcess(p_tm));
}

test "Phase D: registered main-module cycle → error.CircularLoad" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    // The MAIN module (registered in the registry, status=loading) loads
    // a.sk, which loads "main.sk" back. The registry finds the loading module;
    // scheduler wait-graph reachability reports the cycle.
    const main_path = try tmp.write(rt.io, "main.sk", "(load \"a.sk\")");
    defer std.testing.allocator.free(main_path);
    const a_path = try tmp.write(rt.io, "a.sk", "(load \"main.sk\")");
    defer std.testing.allocator.free(a_path);
    const main_proc = try rt.spawnEvalWithNs("(load \"a.sk\")", rt.root_ns, main_path);
    try rt.registerMainModule(main_path, main_proc);
    try std.testing.expectError(error.CircularLoad, rt.awaitProcess(main_proc));
}

test "Phase D: REPL-shaped load (no module_path) resolves against cwd" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    const lib = try tmp.write(rt.io, "lib.sk", "(def x 42) (export x)");
    defer std.testing.allocator.free(lib);
    // An anonymous spawnEval has no module_path: the intrinsic resolves the
    // path against the process cwd. Build a cwd-relative path to lib.sk.
    const cwd = try std.process.currentPathAlloc(rt.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const rel = try std.fs.path.relative(std.testing.allocator, cwd, null, cwd, lib);
    defer std.testing.allocator.free(rel);
    const src = try loadDefSrc(std.testing.allocator, rel, "(:x m)");
    defer std.testing.allocator.free(src);
    const top = try rt.spawnEval(src);
    try std.testing.expectEqual(Value.i64(42), try rt.awaitProcess(top));
}

test "Phase D: absolute-path load works from a module_path'd process" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    // Regression: resolveCanonical joined an absolute argument onto the
    // caller's base dir ("base//abs") — absolute loads from any process WITH
    // a module_path failed with Unbound. An absolute arg must be used
    // verbatim, from the main process AND from inside a loaded module.
    const lib = try tmp.write(rt.io, "sub/lib.sk", "(def x 42) (export x)");
    defer std.testing.allocator.free(lib);
    // Main process with a module_path (as main.zig sets it).
    const main_path = try tmp.write(rt.io, "main.sk", "");
    defer std.testing.allocator.free(main_path);
    const main_src = try loadDefSrc(std.testing.allocator, lib, "(:x m)");
    defer std.testing.allocator.free(main_src);
    const top = try rt.spawnEvalWithNs(main_src, rt.root_ns, main_path);
    try std.testing.expectEqual(Value.i64(42), try rt.awaitProcess(top));

    // Inside a loaded module too: mod.sk loads lib.sk by absolute path.
    const mod_src = try loadDefSrc(std.testing.allocator, lib, "(def get-x (fn () (:x m))) (export get-x)");
    defer std.testing.allocator.free(mod_src);
    const mod_path = try tmp.write(rt.io, "mod.sk", mod_src);
    defer std.testing.allocator.free(mod_path);
    const top2_src = try loadDefSrc(std.testing.allocator, mod_path, "((:get-x m))");
    defer std.testing.allocator.free(top2_src);
    const top2 = try rt.spawnEval(top2_src);
    try std.testing.expectEqual(Value.i64(42), try rt.awaitProcess(top2));
}

// --- Phase AD: automatic differentiation ---

test "Phase AD: named helper calls never silently zero" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const helper = try rt.spawnEval(
        \\(defn (square x) (* x x))
        \\((deriv (fn (x) (square x))) 3.0)
    );
    const helper_result = try rt.awaitProcess(helper);
    try std.testing.expectEqual(skript.builtins.type_f64, helper_result.typ);
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), helper_result.obj.tof64(), 1e-6);
}

test "Phase AD: captured closures retain derivative captures" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const captured = try rt.spawnEval(
        \\(defn (make-scale a) (fn (x) (* a x)))
        \\(def scale (make-scale 2.0))
        \\((deriv scale) 3.0)
    );
    const captured_result = try rt.awaitProcess(captured);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), captured_result.obj.tof64(), 1e-6);
}

test "Phase AD: active non-symbol callees never silently zero" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const proc = try rt.spawnEval(
        "((deriv (fn (x) ((fn (y) (* y y)) x))) 3.0)",
    );
    const result = try rt.awaitProcess(proc);
    try std.testing.expectEqual(Value.f64(6.0), result);
}

test "Phase AD: lexical let shadowing keeps outer parameter inactive" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const proc = try rt.spawnEval(
        "((deriv (fn (x) (let ((x 4.0)) (* x x)))) 3.0)",
    );
    const result = try rt.awaitProcess(proc);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.obj.tof64(), 1e-6);
}

test "Phase AD: active impure and missing primitive rules are unsupported" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const impure = try rt.spawnEval("(deriv (fn (x) (println x)))");
    try std.testing.expectError(error.Unsupported, rt.awaitProcess(impure));

    const missing_rule = try rt.spawnEval("(deriv @f64.hypot)");
    try std.testing.expectError(error.Unsupported, rt.awaitProcess(missing_rule));
}

test "Phase AD: jvp closure consumes its final runtime seed" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const primal_proc = try rt.spawnEval("(fn (x) (* x x))");
    const primal = try rt.awaitProcess(primal_proc);
    const pushforward = try intrin.ad.jvpClosure(rt.context(), primal, 0);
    var results: [2]Value = undefined;
    try rt.applyResultsWithContext(
        rt.context(),
        pushforward,
        &.{ Value.f64(3.0), Value.f64(4.0) },
        &results,
    );
    try std.testing.expectEqual(Value.f64(9.0), results[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 24.0), results[1].obj.tof64(), 1e-6);
}

test "Phase AD: method differentiation does not reuse stale instances" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const proc = try rt.spawnEval(
        \\(def m (method))
        \\(instance m f64 (fn (x) (* x x)))
        \\(def d1 (deriv m))
        \\(instance m f64 (fn (x) (* 3.0 x)))
        \\(def d2 (deriv m))
        \\(list (d1 2.0) (d2 2.0))
    );
    const result = try rt.awaitProcess(proc);
    const first = result.obj.toRef().deref([2]Value);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), first[0].obj.tof64(), 1e-6);
    const second = first[1].obj.toRef().deref([2]Value);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), second[0].obj.tof64(), 1e-6);
}

test "Phase AD: cond transforms all clauses beyond the old fixed buffer" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const proc = try rt.spawnEval(
        \\((deriv (fn (x) (cond
        \\  (#f 1.0)
        \\  (#f 2.0)
        \\  (#f 3.0)
        \\  (#f 4.0)
        \\  (#f 5.0)
        \\  (#f 6.0)
        \\  (#f 7.0)
        \\  (#f 8.0)
        \\  (#f 9.0)
        \\  (#f 10.0)
        \\  (#f 11.0)
        \\  (#f 12.0)
        \\  (#f 13.0)
        \\  (#f 14.0)
        \\  (#f 15.0)
        \\  (#f 16.0)
        \\  (#f 17.0)
        \\  (#f 18.0)
        \\  (#f 19.0)
        \\  (#f 20.0)
        \\  (#f 21.0)
        \\  (#f 22.0)
        \\  (#f 23.0)
        \\  (#f 24.0)
        \\  (#f 25.0)
        \\  (#f 26.0)
        \\  (#f 27.0)
        \\  (#f 28.0)
        \\  (#f 29.0)
        \\  (#f 30.0)
        \\  (#f 31.0)
        \\  (#f 32.0)
        \\  (else (* x x))))) 3.0)
    );
    const result = try rt.awaitProcess(proc);
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), result.obj.tof64(), 1e-6);
}

test "Phase AD: polynomial central-difference oracle comparison" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const poly = struct {
        fn eval(x: f64) f64 {
            return (x * x * x) - (3.0 * x * x) + (2.0 * x) - 5.0;
        }
    }.eval;

    const h: f64 = 1e-6;
    const x: f64 = 2.5;
    const oracle = (poly(x + h) - poly(x - h)) / (2.0 * h);

    const src =
        \\(def p (fn (x) (- (+ (- (* (* x x) x) (* 3.0 (* x x))) (* 2.0 x)) 5.0)))
        \\((deriv p) 2.5)
    ;
    const proc = try rt.spawnEval(src);
    const res = try rt.awaitProcess(proc);
    try std.testing.expect(std.meta.eql(res.typ, skript.builtins.type_f64));
    try std.testing.expect(@abs(res.obj.tof64() - oracle) <= 1e-5);
}

test "Phase AD: transcendental sin+exp composition oracle comparison" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const trans = struct {
        fn eval(x: f64) f64 {
            return @exp(@sin(x));
        }
    }.eval;

    const h: f64 = 1e-6;
    const x: f64 = 1.0;
    const oracle = (trans(x + h) - trans(x - h)) / (2.0 * h);

    const src =
        \\(def f (fn (x) (exp (sin x))))
        \\((deriv f) 1.0)
    ;
    const proc = try rt.spawnEval(src);
    const res = try rt.awaitProcess(proc);
    try std.testing.expect(std.meta.eql(res.typ, skript.builtins.type_f64));
    try std.testing.expect(@abs(res.obj.tof64() - oracle) <= 1e-5);
}

test "Phase AD: piecewise if-branch oracle comparison at +/- 2.0" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const pw = struct {
        fn eval(x: f64) f64 {
            if (x > 0.0) {
                return x * x;
            } else {
                return 3.0 * x;
            }
        }
    }.eval;

    const h: f64 = 1e-6;
    const x_pos: f64 = 2.0;
    const oracle_pos = (pw(x_pos + h) - pw(x_pos - h)) / (2.0 * h);

    const x_neg: f64 = -2.0;
    const oracle_neg = (pw(x_neg + h) - pw(x_neg - h)) / (2.0 * h);

    const src_pos =
        \\(def f (fn (x) (if (> x 0.0) (* x x) (* 3.0 x))))
        \\((deriv f) 2.0)
    ;
    const proc_pos = try rt.spawnEval(src_pos);
    const res_pos = try rt.awaitProcess(proc_pos);
    try std.testing.expect(std.meta.eql(res_pos.typ, skript.builtins.type_f64));
    try std.testing.expect(@abs(res_pos.obj.tof64() - oracle_pos) <= 1e-5);

    const src_neg = "((deriv f) -2.0)";
    const proc_neg = try rt.spawnEval(src_neg);
    const res_neg = try rt.awaitProcess(proc_neg);
    try std.testing.expect(std.meta.eql(res_neg.typ, skript.builtins.type_f64));
    try std.testing.expect(@abs(res_neg.obj.tof64() - oracle_neg) <= 1e-5);
}

test "Phase AD: memo identity — repeat (deriv f) returns identical closure Value" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const p1 = try rt.spawnEval("(def f (fn (x) (* x x))) (deriv f)");
    const d1 = try rt.awaitProcess(p1);
    const p2 = try rt.spawnEval("(deriv f)");
    const d2 = try rt.awaitProcess(p2);

    try std.testing.expect(std.meta.eql(d1, d2));
    try std.testing.expectEqual(d1.typ, d2.typ);
    try std.testing.expectEqual(d1.obj, d2.obj);
}

test "Phase AD: error conditions — non-callable, out-of-bounds, arity" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const p_num = try rt.spawnEval("(deriv 42)");
    try std.testing.expectError(error.TypeMismatch, rt.awaitProcess(p_num));

    const p_str = try rt.spawnEval("(deriv \"hello\")");
    try std.testing.expectError(error.TypeMismatch, rt.awaitProcess(p_str));

    const p_oob = try rt.spawnEval("(deriv (fn (x y) (+ x y)) 5)");
    try std.testing.expectError(error.InvalidSelector, rt.awaitProcess(p_oob));

    const p_unknown_sym = try rt.spawnEval("(deriv (fn (x y) (+ x y)) 'z)");
    try std.testing.expectError(error.InvalidSelector, rt.awaitProcess(p_unknown_sym));

    const p_no_args = try rt.spawnEval("(deriv)");
    try std.testing.expectError(error.ArityMismatch, rt.awaitProcess(p_no_args));

    const p_too_many = try rt.spawnEval("(deriv (fn (x) x) 0 1)");
    try std.testing.expectError(error.ArityMismatch, rt.awaitProcess(p_too_many));
}

test "Phase AD: direct intrinsic differentiation and higher orders" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // D(sin)(0) = cos(0) = 1.0
    const p1 = try rt.spawnEval("((deriv sin) 0.0)");
    const v1 = try rt.awaitProcess(p1);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), v1.obj.tof64(), 1e-6);

    // D(cos)(0) = -sin(0) = 0.0
    const p2 = try rt.spawnEval("((deriv cos) 0.0)");
    const v2 = try rt.awaitProcess(p2);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), v2.obj.tof64(), 1e-6);

    // D(exp)(0) = exp(0) = 1.0
    const p3 = try rt.spawnEval("((deriv exp) 0.0)");
    const v3 = try rt.awaitProcess(p3);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), v3.obj.tof64(), 1e-6);

    // D^4(sin)(0) = sin(0) = 0.0
    const p4 = try rt.spawnEval("((deriv (deriv (deriv (deriv sin)))) 0.0)");
    const v4 = try rt.awaitProcess(p4);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), v4.obj.tof64(), 1e-6);
}

test "Phase AD: multi-argument partial derivatives and mixed partials" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // f(x, y) = x^2 * y + y^2
    // df/dx = 2*x*y, at (2.0, 3.0) -> 12.0
    const p1 = try rt.spawnEval("((deriv (fn (x y) (+ (* (* x x) y) (* y y))) 0) 2.0 3.0)");
    const v1 = try rt.awaitProcess(p1);
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), v1.obj.tof64(), 1e-6);

    // df/dy = x^2 + 2*y, at (2.0, 3.0) -> 4 + 6 = 10.0
    const p2 = try rt.spawnEval("((deriv (fn (x y) (+ (* (* x x) y) (* y y))) 1) 2.0 3.0)");
    const v2 = try rt.awaitProcess(p2);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), v2.obj.tof64(), 1e-6);

    // df/dy using parameter name symbol 'y
    const p3 = try rt.spawnEval("((deriv (fn (x y) (+ (* (* x x) y) (* y y))) 'y) 2.0 3.0)");
    const v3 = try rt.awaitProcess(p3);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), v3.obj.tof64(), 1e-6);

    // d^2f / (dy dx) = 2*x, at (2.0, 3.0) -> 4.0
    const p4 = try rt.spawnEval("((deriv (deriv (fn (x y) (+ (* (* x x) y) (* y y))) 0) 1) 2.0 3.0)");
    const v4 = try rt.awaitProcess(p4);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), v4.obj.tof64(), 1e-6);
}

test "Phase AD: broader transcendental and algebraic rules" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // d/dx (x^3) at 2.0 = 3 * 2^2 = 12.0
    const p1 = try rt.spawnEval("((deriv (fn (x) (pow x 3.0))) 2.0)");
    const v1 = try rt.awaitProcess(p1);
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), v1.obj.tof64(), 1e-6);

    // d/dx (sqrt(x)) at 4.0 = 1 / (2 * sqrt(4)) = 0.25
    const p2 = try rt.spawnEval("((deriv (fn (x) (sqrt x))) 4.0)");
    const v2 = try rt.awaitProcess(p2);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), v2.obj.tof64(), 1e-6);

    // d/dx (tan(x)) at 0.0 = 1.0
    const p3 = try rt.spawnEval("((deriv (fn (x) (tan x))) 0.0)");
    const v3 = try rt.awaitProcess(p3);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), v3.obj.tof64(), 1e-6);

    // d/dx (abs(x)) at 5.0 = 1.0, at -5.0 = -1.0
    const p4 = try rt.spawnEval("((deriv (fn (x) (abs x))) 5.0)");
    const v4 = try rt.awaitProcess(p4);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), v4.obj.tof64(), 1e-6);

    const p5 = try rt.spawnEval("((deriv (fn (x) (abs x))) -5.0)");
    const v5 = try rt.awaitProcess(p5);
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), v5.obj.tof64(), 1e-6);
}
test "Phase AD: vector gradient of multivariate polynomial" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // f(x, y) = x^2 * y + y^2
    // grad f(2.0, 3.0) = [2xy, x^2 + 2y] = [12.0, 10.0]
    const p1 = try rt.spawnEval("((gradient (fn (x y) (+ (* (* x x) y) (* y y)))) 2.0 3.0)");
    const v1 = try rt.awaitProcess(p1);
    try std.testing.expectEqual(skript.builtins.type_cons, v1.typ);
    const c1 = v1.obj.toRef().deref([2]Value);
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), c1[0].obj.tof64(), 1e-6);
    const c2 = c1[1].obj.toRef().deref([2]Value);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), c2[0].obj.tof64(), 1e-6);
}

test "Phase AD: value-and-gradient on scalar and multi-arg functions" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // Single arg: f(x) = x^2, (value-and-gradient f 3.0) -> (cons 9.0 6.0)
    const p1 = try rt.spawnEval("((value-and-gradient (fn (x) (* x x))) 3.0)");
    const v1 = try rt.awaitProcess(p1);
    try std.testing.expectEqual(skript.builtins.type_cons, v1.typ);
    const cell1 = v1.obj.toRef().deref([2]Value);
    try std.testing.expectApproxEqAbs(@as(f64, 9.0), cell1[0].obj.tof64(), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), cell1[1].obj.tof64(), 1e-6);

    // Multi arg: f(x, y) = x^2 * y + y^2, at (2.0, 3.0) -> (cons 21.0 (list 12.0 10.0))
    const p2 = try rt.spawnEval("((value-and-gradient (fn (x y) (+ (* (* x x) y) (* y y)))) 2.0 3.0)");
    const v2 = try rt.awaitProcess(p2);
    try std.testing.expectEqual(skript.builtins.type_cons, v2.typ);
    const cell2 = v2.obj.toRef().deref([2]Value);
    try std.testing.expectApproxEqAbs(@as(f64, 21.0), cell2[0].obj.tof64(), 1e-6);
    const g_list = cell2[1].obj.toRef().deref([2]Value);
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), g_list[0].obj.tof64(), 1e-6);
    const g_next = g_list[1].obj.toRef().deref([2]Value);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), g_next[0].obj.tof64(), 1e-6);
}

test "Phase AD: vector gradient on Rosenbrock optimization benchmark" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // Rosenbrock: f(x, y) = (1 - x)^2 + 100 * (y - x^2)^2
    // At optimum (1.0, 1.0): grad f = [0.0, 0.0]
    const p1 = try rt.spawnEval(
        comptime "(def rosen (fn (x y) (+ (* (- 1.0 x) (- 1.0 x)) (* 100.0 (* " ++
            "(- y (* x x)) (- y (* x x))))))) ((gradient rosen) 1.0 1.0)",
    );
    const v1 = try rt.awaitProcess(p1);
    try std.testing.expectEqual(skript.builtins.type_cons, v1.typ);
    const c1 = v1.obj.toRef().deref([2]Value);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), c1[0].obj.tof64(), 1e-6);
    const c2 = c1[1].obj.toRef().deref([2]Value);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), c2[0].obj.tof64(), 1e-6);

    // At (0.0, 0.0): grad f = [-2.0, 0.0]
    const p2 = try rt.spawnEval("((gradient rosen) 0.0 0.0)");
    const v2 = try rt.awaitProcess(p2);
    try std.testing.expectEqual(skript.builtins.type_cons, v2.typ);
    const c3 = v2.obj.toRef().deref([2]Value);
    try std.testing.expectApproxEqAbs(@as(f64, -2.0), c3[0].obj.tof64(), 1e-6);
    const c4 = c3[1].obj.toRef().deref([2]Value);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), c4[0].obj.tof64(), 1e-6);
}
test "Phase AD: tensor construction and tensor-get elementwise autodiff" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // d/dx (tensor-get (stack (* x x) (* 2.0 x)) 0) at 3.0 -> 2*x = 6.0
    const p1 = try rt.spawnEval("((deriv (fn (x) (tensor-get (stack (* x x) (* 2.0 x)) 0))) 3.0)");
    const v1 = try rt.awaitProcess(p1);
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), v1.obj.tof64(), 1e-6);

    // d/dx (tensor-get [(* x x) (* 2.0 x)] 1) at 3.0 -> 2.0
    const p2 = try rt.spawnEval("((deriv (fn (x) (tensor-get [(* x x) (* 2.0 x)] 1))) 3.0)");
    const v2 = try rt.awaitProcess(p2);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), v2.obj.tof64(), 1e-6);
}

test "Phase AD: pytree pair and list destructuring autodiff" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // Pair: f(x) = fst (cons (* x x) (* 2.0 x)) at 3.0 -> 6.0
    const p1 = try rt.spawnEval("((deriv (fn (x) (fst (cons (* x x) (* 2.0 x))))) 3.0)");
    const v1 = try rt.awaitProcess(p1);
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), v1.obj.tof64(), 1e-6);

    // List: f(x) = fst (rst (list (* x x) (* 5.0 x) (* 2.0 x))) at 3.0 -> 5.0
    const p2 = try rt.spawnEval("((deriv (fn (x) (fst (rst (list (* x x) (* 5.0 x) (* 2.0 x)))))) 3.0)");
    const v2 = try rt.awaitProcess(p2);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), v2.obj.tof64(), 1e-6);
}

test "Phase AD: pytree hash-map field access autodiff" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // Map: f(x) = map-get {:a (* x x) :b (* 3.0 x)} :a at 4.0 -> 8.0
    const p1 = try rt.spawnEval("((deriv (fn (x) (map-get (hash-map :a (* x x) :b (* 3.0 x)) :a))) 4.0)");
    const v1 = try rt.awaitProcess(p1);
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), v1.obj.tof64(), 1e-6);

    // Map: f(x) = map-get {:a (* x x) :b (* 3.0 x)} :b at 4.0 -> 3.0
    const p2 = try rt.spawnEval("((deriv (fn (x) (map-get (hash-map :a (* x x) :b (* 3.0 x)) :b))) 4.0)");
    const v2 = try rt.awaitProcess(p2);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), v2.obj.tof64(), 1e-6);
}
// --- Phase U: Clojure-style modules (use ...) ---

test "Phase U: default alias (use lib) -> lib/x" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    const lib = try tmp.write(rt.io, "lib.pt", "(def x 42) (export x)");
    defer std.testing.allocator.free(lib);

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ tmp.dir, "main.pt" });
    defer std.testing.allocator.free(main_path);

    const top = try rt.spawnEvalWithNs("(use lib) lib/x", rt.root_ns, main_path);
    try std.testing.expectEqual(Value.i64(42), try rt.awaitProcess(top));
}

test "Phase U: custom alias (use (lib :as mylib)) -> mylib/x" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    const lib = try tmp.write(rt.io, "lib.pt", "(def x 42) (export x)");
    defer std.testing.allocator.free(lib);

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ tmp.dir, "main.pt" });
    defer std.testing.allocator.free(main_path);

    const top = try rt.spawnEvalWithNs("(use (lib :as mylib)) mylib/x", rt.root_ns, main_path);
    try std.testing.expectEqual(Value.i64(42), try rt.awaitProcess(top));
}

test "Phase U: n-ary use (use a b) both bound" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    const a = try tmp.write(rt.io, "a.pt", "(def x 10) (export x)");
    defer std.testing.allocator.free(a);
    const b_file = try tmp.write(rt.io, "b.pt", "(def y 20) (export y)");
    defer std.testing.allocator.free(b_file);

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ tmp.dir, "main.pt" });
    defer std.testing.allocator.free(main_path);

    const top = try rt.spawnEvalWithNs("(use a b) (+ a/x b/y)", rt.root_ns, main_path);
    try std.testing.expectEqual(Value.i64(30), try rt.awaitProcess(top));
}

test "Phase U: sequential uses coalesced into one use-multi call" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    const a = try tmp.write(rt.io, "a.pt", "(def x 10) (export x)");
    defer std.testing.allocator.free(a);
    const b_file = try tmp.write(rt.io, "b.pt", "(def y 20) (export y)");
    defer std.testing.allocator.free(b_file);

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ tmp.dir, "main.pt" });
    defer std.testing.allocator.free(main_path);

    const top = try rt.spawnEvalWithNs("(use a) (use b) (def y (+ a/x b/y)) y", rt.root_ns, main_path);
    try std.testing.expectEqual(Value.i64(30), try rt.awaitProcess(top));

    rt.scheduler.mutex.lockUncancelable(rt.io);
    defer rt.scheduler.mutex.unlock(rt.io);
    try std.testing.expectEqual(@as(usize, 2), rt.modules.entries.items.len);
}

test "Phase U: folder module multiple files sorted combine" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    // Scramble write order: write b.pt before a.pt
    const b_file = try tmp.write(rt.io, "mypkg/b.pt", "(def second-val (+ first-val 50)) (export second-val)");
    defer std.testing.allocator.free(b_file);
    const a = try tmp.write(rt.io, "mypkg/a.pt", "(def first-val 100)");
    defer std.testing.allocator.free(a);

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ tmp.dir, "main.pt" });
    defer std.testing.allocator.free(main_path);

    const top = try rt.spawnEvalWithNs("(use mypkg) mypkg/second-val", rt.root_ns, main_path);
    try std.testing.expectEqual(Value.i64(150), try rt.awaitProcess(top));

    rt.scheduler.mutex.lockUncancelable(rt.io);
    defer rt.scheduler.mutex.unlock(rt.io);
    try std.testing.expectEqual(@as(usize, 1), rt.modules.entries.items.len);
}

test "Phase U: no-regressions — division, unqualified def, unknown alias, bind rejection, fn body, cycle" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    const main_path = try std.fs.path.join(std.testing.allocator, &.{ tmp.dir, "main.pt" });
    defer std.testing.allocator.free(main_path);

    // Division intact
    const div_proc = try rt.spawnEval("(/ 6 3)");
    try std.testing.expectEqual(Value.i64(2), try rt.awaitProcess(div_proc));

    // Unqualified def/lookup
    const def_proc = try rt.spawnEval("(def x 5) x");
    try std.testing.expectEqual(Value.i64(5), try rt.awaitProcess(def_proc));

    // Unknown alias zz/x -> Unbound
    const unk_proc = try rt.spawnEval("zz/x");
    try std.testing.expectError(error.Unbound, rt.awaitProcess(unk_proc));

    // Qualified bind site rejection
    try std.testing.expectError(error.MalformedAst, rt.spawnEval("(def a/b 1)"));

    // `use` is top-level syntax and cannot run inside a closure.
    try std.testing.expectError(error.MalformedAst, rt.spawnEval("(defn (f) (use a)) (f)"));

    // Missing module (use nosuch) -> Unbound
    try std.testing.expectError(error.Unbound, rt.spawnEvalWithNs("(use nosuch)", rt.root_ns, main_path));

    // Circular use cycle A <-> B -> CircularLoad
    const cyc_a = try tmp.write(rt.io, "cyc_a.pt", "(use cyc_b) (def val 1) (export val)");
    defer std.testing.allocator.free(cyc_a);
    const cyc_b = try tmp.write(rt.io, "cyc_b.pt", "(use cyc_a) (def val 2) (export val)");
    defer std.testing.allocator.free(cyc_b);

    const cyc_top = try rt.spawnEvalWithNs("(use cyc_a) cyc_a/val", rt.root_ns, main_path);
    try std.testing.expectError(error.CircularLoad, rt.awaitProcess(cyc_top));
}

test "Phase C: defs persist across spawnEval submissions (REPL namespace)" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    // Each REPL submission is a fresh process whose fiber starts with
    // fib.ns = root_ns; a top-level def binds root_ns, so later submissions
    // see it. Regression for a reported REPL failure ("(def a 40) then
    // (+ a 1) -> a is unbound").
    const p1 = try rt.spawnEval("(def a 40)");
    _ = try rt.awaitProcess(p1);
    const p2 = try rt.spawnEval("(+ a 1)");
    try std.testing.expectEqual(Value.i64(41), try rt.awaitProcess(p2));
    // Closures defined in an earlier submission capture root_ns and keep
    // working across submissions too.
    const p3 = try rt.spawnEval("(defn (inc-a ) (+ a 1))");
    _ = try rt.awaitProcess(p3);
    const p4 = try rt.spawnEval("(inc-a)");
    try std.testing.expectEqual(Value.i64(41), try rt.awaitProcess(p4));
    // Redefinition in a later submission is visible to the next one.
    const p5 = try rt.spawnEval("(def a 100)");
    _ = try rt.awaitProcess(p5);
    const p6 = try rt.spawnEval("(+ a 1)");
    try std.testing.expectEqual(Value.i64(101), try rt.awaitProcess(p6));
}

test "Phase C: multiple defs persist across spawnEval submissions" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    // The user-visible REPL repro: two defs in separate submissions, then a
    // lookup in a third. (The REPL-only failure mode — dangling interned
    // symbol keys from frame-arena sources — is covered by the getsym test
    // in Store.zig; this pins the language-level contract.)
    _ = try rt.awaitProcess(try rt.spawnEval("(def a 1)"));
    _ = try rt.awaitProcess(try rt.spawnEval("(def b 2)"));
    const res = try rt.awaitProcess(try rt.spawnEval("(+ a b)"));
    try std.testing.expectEqual(Value.i64(3), res);
}

// --- regvm type-tracking tests ---
// regvm type tracking: branch joins, flow-sensitive narrowing, let-binding
// types, and the soundness regressions that pin them. These tests assert the
// EXACT opcodes the compiler must emit (the type-tracking compiler changes
// land in the COMPILER section above); the runtime assertions double-check
// that specialization never changes observable results. A generic `+` on a
// string raises the method-miss error (probed: "get: no instance for
// (core.string, core.i64)") which surfaces as error.ArityMismatch.
// ---

/// Helpers for the type-tracking tests below. Each test builds its own
/// runtime; the fiber shape matches the other regvm tests in this file.
const regvm_type_track = struct {
    /// Compile `src` and run it to completion on a fresh top-level fiber.
    fn exec(rt_: *Runtime, src: []const u8) !Value {
        const forms = try skript.Reader.readAll(rt_.store, src);
        const prog = try rt_.compileData(rt_.root_ns, forms, null);
        const stack = try std.testing.allocator.alloc(Object, frame_size + @as(usize, prog.nregs) * 2);
        defer std.testing.allocator.free(stack);
        @memset(stack, .null);
        var fib: Fiber = .{
            .stack = stack,
            .sp = frame_size + @as(usize, prog.nregs) * 2,
            .ip = prog.ir.ptr,
            .ir = prog.ir,
            .nregs = prog.nregs,
            .consts = prog.constants,
            .fns = prog.fns,
            .ns = rt_.root_ns,
        };
        return rt_.runToCompletion(rt_.root_ns, &fib);
    }

    /// Compile `src`, run it, and assert the exact result Value.
    fn run(rt_: *Runtime, src: []const u8, expected: Value) !void {
        try std.testing.expectEqual(expected, try exec(rt_, src));
    }

    /// Compile `src`; the program must fail with `err` — either a compile
    /// phase Zig error or a runtime error VALUE's anyerror payload
    /// (errors-as-values channel).
    fn runErr(rt_: *Runtime, src: []const u8, err: anyerror) !void {
        const res = exec(rt_, src) catch |e| {
            try std.testing.expectEqual(err, e);
            return;
        };
        if (res.typ != b.type_error) return error.TestUnexpectedResult;
        try std.testing.expectEqual(err, res.errorCode());
    }

    /// Compile `src`; the result must be a keyword named `expected`.
    fn runKw(rt_: *Runtime, src: []const u8, expected: []const u8) !void {
        const res = try exec(rt_, src);
        try std.testing.expect(std.meta.eql(res.typ, skript.builtins.type_keyword));
        try std.testing.expectEqualStrings(expected, res.obj.toPtr(Sym).*);
    }

    /// Compile `src`; the result must be a string equal to `expected`.
    fn runStr(rt_: *Runtime, src: []const u8, expected: []const u8) !void {
        const res = try exec(rt_, src);
        try std.testing.expect(std.meta.eql(res.typ, skript.builtins.type_string));
        try std.testing.expectEqualStrings(expected, std.mem.sliceTo(res.obj.toPtr([*]u8), 0));
    }
};

test "bound branch joins preserve selected values and nil" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try regvm_type_track.run(rt, "(+ (if #t 1 2) 3)", Value.i64(4));
    try regvm_type_track.run(rt, "(+ (case 2 ((1) 10) ((2) 20) (else 0)) 1)", Value.i64(21));
    try std.testing.expect(Value.isNil(try regvm_type_track.exec(rt, "(case 2 ((1) 10))")));
}

// --- C4 TIER-1: semantics & control flow ---
// Ported from docs/core-improvements/01-semantics-control.md (items 9, 1, 10,
// 11). Truthiness is nil-or-#f falsy (the spec's headline says "only nil";
// its cond/when/unless battery and the acceptance criteria keep #f falsy —
// see Value.isTruthy). `defn` tests use the repo's (defn (name args) ...)
// syntax (regvm compiler does not support (defn name (args) ...)).

test "C4 TIER-1: nil-or-#f truthiness on the register VM" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try regvm_type_track.run(rt, "(if nil 1 2)", Value.i64(2));
    try regvm_type_track.run(rt, "(if #f 1 2)", Value.i64(2));
    try regvm_type_track.run(rt, "(if 0 1 2)", Value.i64(1)); // CHANGED: 0 truthy
    try regvm_type_track.run(rt, "(if 0.0 1 2)", Value.i64(1)); // CHANGED: +0.0 truthy
    try regvm_type_track.run(rt, "(if -0.0 1 2)", Value.i64(1)); // consistent with +0.0 now
    try regvm_type_track.run(rt, "(if \"\" 1 2)", Value.i64(1)); // empty string truthy
    try regvm_type_track.run(rt, "(if 42 1 2)", Value.i64(1));
    try regvm_type_track.run(rt, "(if (list 1) 1 2)", Value.i64(1));
    // (list) IS nil — falsy.
    try regvm_type_track.run(rt, "(if (list) 1 2)", Value.i64(2));
    // The nil-or-#f rule joins cleanly through regIf's brn.
    try regvm_type_track.run(rt, "(if (if 0 1 2) 10 20)", Value.i64(10));

    // Tree-walker parity (evalString reads one form at a time).
    try std.testing.expectEqual(Value.i64(1), try rt.evalString("(if 0 1 2)"));
    try std.testing.expectEqual(Value.i64(2), try rt.evalString("(if nil 1 2)"));
    try std.testing.expectEqual(Value.i64(2), try rt.evalString("(if #f 1 2)"));
    try std.testing.expectEqual(Value.i64(1), try rt.evalString("(if 0.0 1 2)"));
}

test "C4 TIER-1: cond on the register VM" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try regvm_type_track.runStr(rt, "(cond ((> 3 2) \"big\") (else \"small\"))", "big");
    try regvm_type_track.run(rt, "(cond ((= 1 2) 10) ((= 2 2) 20) (else 30))", Value.i64(20));
    try regvm_type_track.run(rt, "(cond (#f 1) (#f 2))", Value.nil); // no match, no else
    try regvm_type_track.run(rt, "(cond (#f 1) (#t 2))", Value.i64(2));
    try regvm_type_track.run(rt, "(cond (#f 1) (else 3))", Value.i64(3));
    try regvm_type_track.run(rt, "(cond ((= 1 1)))", Value.true); // bare clause returns test value
    try regvm_type_track.run(rt, "(cond (else 5))", Value.i64(5));
    try regvm_type_track.run(rt, "(cond ((= 1 1) 1 2 3))", Value.i64(3)); // multi-form body
    // 0 is truthy — the first clause matches.
    try regvm_type_track.runStr(rt, "(cond (0 \"zero\") (else \"other\"))", "zero");
    // Tail recursion through cond (else body is a tail call).
    try regvm_type_track.run(rt, "(defn (f x) (cond ((= x 0) 0) (else (f (- x 1))))) (f 3)", Value.i64(0));
    // A bare clause in the middle: falsy falls through, truthy returns the test.
    try regvm_type_track.run(rt, "(cond (#f) (#t))", Value.true);
    try regvm_type_track.run(rt, "(cond ((= 1 2)) (else 7))", Value.i64(7));
    // Zero clauses → nil (acceptance); else misplaced or bodiless → error.
    try regvm_type_track.run(rt, "(cond)", Value.nil);
    try regvm_type_track.runErr(rt, "(cond (else 1) (#t 2))", error.Unimplemented);
    try regvm_type_track.runErr(rt, "(cond (else))", error.Unimplemented);
}

test "C4 TIER-1: when and unless on the register VM" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try regvm_type_track.run(rt, "(when #t 1 2 3)", Value.i64(3));
    try regvm_type_track.run(rt, "(when #f 1 2 3)", Value.nil);
    try regvm_type_track.run(rt, "(unless #f 7)", Value.i64(7));
    try regvm_type_track.run(rt, "(unless #t 7)", Value.nil);
    try regvm_type_track.run(rt, "(when 0 5)", Value.i64(5)); // 0 truthy
    try regvm_type_track.run(rt, "(when #t)", Value.nil); // empty body: evaluate T, return null
    try regvm_type_track.run(rt, "(unless #f)", Value.nil);
    // Tail position: countdown recurses through unless's body.
    try regvm_type_track.run(rt, "(defn (countdown n) (unless (= n 0) (countdown (- n 1)))) (countdown 5)", Value.nil);
    // Nested-predicate r0 edge: the empty body must be nil, not the stale r0.
    try regvm_type_track.run(rt, "(if (if 1 2 3) (begin) 9)", Value.nil);
}

test "C4 TIER-1: string =/!= and deep equal?" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try regvm_type_track.run(rt, "(= \"a\" \"a\")", Value.true);
    try regvm_type_track.run(rt, "(= \"a\" \"b\")", Value.false);
    try regvm_type_track.run(rt, "(= \"\" \"\")", Value.true);
    try regvm_type_track.run(rt, "(!= \"a\" \"b\")", Value.true);
    try regvm_type_track.run(rt, "(!= \"a\" \"a\")", Value.false);
    // Mixed types stay ArityMismatch (method dispatch is same-type only).
    try regvm_type_track.runErr(rt, "(= \"a\" 1)", error.ArityMismatch);

    try regvm_type_track.run(rt, "(equal? \"a\" \"a\")", Value.true);
    try regvm_type_track.run(rt, "(equal? (list 1 2 3) (list 1 2 3))", Value.true);
    try regvm_type_track.run(rt, "(equal? (list 1 (list 2 3)) (list 1 (list 2 3)))", Value.true);
    try regvm_type_track.run(rt, "(equal? (list 1 2) (list 1 3))", Value.false);
    try regvm_type_track.run(rt, "(equal? nil nil)", Value.true);
    try regvm_type_track.run(rt, "(equal? 0 0.0)", Value.false); // different types
    try regvm_type_track.run(rt, "(equal? 1 1)", Value.true);
    try regvm_type_track.run(rt, "(equal? \"a\" 'a)", Value.false); // string vs symbol
    try regvm_type_track.run(rt, "(equal? (fn (x) x) (fn (x) x))", Value.false); // closures by identity
    try regvm_type_track.run(rt, "(equal? 'a 'a)", Value.true);
    try regvm_type_track.run(rt, "(equal? (cons 1 2) (cons 1 2))", Value.true); // improper list
    try regvm_type_track.run(rt, "(equal? 3+4i 3+4i)", Value.true); // complex component-wise
    try regvm_type_track.run(rt, "(equal? 3+4i 3+5i)", Value.false);
    try regvm_type_track.run(rt, "(equal? +0.0 -0.0)", Value.true); // IEEE eq semantics
}

test "C4 TIER-1: no 8-arg cap (16-slot fast path + hash-map fallback)" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // 9-arg defn on the register VM (register-window call — no namespace).
    const f9 = "(defn (f9 a1 a2 a3 a4 a5 a6 a7 a8 a9) (list a1 a2 a3 a4 a5 a6 a7 a8 a9)) (f9 1 2 3 4 5 6 7 8 9)";
    const l9 = try regvm_type_track.exec(rt, f9);
    try std.testing.expect(Value.isCons(l9));

    // 17-arg defn on the register VM (register-window call — no namespace,
    // u8 nargs ceiling only).
    const r17 = try regvm_type_track.exec(
        rt,
        comptime "(defn (r17 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16 a17) (list a1 a2 a3 a4 a5 a6 " ++
            "a7 a8 a9 a10 a11 a12 a13 a14 a15 a16 a17)) (r17 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17)",
    );
    try std.testing.expect(Value.isCons(r17));

    // 17-arg defn (beyond SmallNamespace.size): bindClosureArgs hash fallback
    // on the tree-walker path (evalString reads one form at a time).
    const f17_def = comptime "(defn (f17 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16 a17) " ++
        "(list a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16 a17))";
    _ = try rt.evalString(f17_def);
    const l17 = try rt.evalString("(f17 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17)");
    try std.testing.expect(Value.isCons(l17));

    // 9-binding let: SmallNamespace fast path (9 <= 16).
    const let9 = try regvm_type_track.exec(
        rt,
        "(let ((a1 1) (a2 2) (a3 3) (a4 4) (a5 5) (a6 6) (a7 7) (a8 8) (a9 9)) (list a1 a2 a3 a4 a5 a6 a7 a8 a9))",
    );
    try std.testing.expect(Value.isCons(let9));
    // 17-binding let: regvm ns_push hash fallback (count 17 > 16).
    const let17 = try regvm_type_track.exec(
        rt,
        comptime "(let ((a1 1) (a2 2) (a3 3) (a4 4) (a5 5) (a6 6) (a7 7) " ++
            "(a8 8) (a9 9) (a10 10) (a11 11) (a12 12) (a13 13) " ++
            "(a14 14) (a15 15) (a16 16) (a17 17)) (list a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16 a17))",
    );
    try std.testing.expect(Value.isCons(let17));

    // 9-arg closure closing over its 9 params.
    const mk = comptime "(defn (mk a1 a2 a3 a4 a5 a6 a7 a8 a9) (fn () (list a1 " ++
        "a2 a3 a4 a5 a6 a7 a8 a9))) ((mk 1 2 3 4 5 6 7 8 9))";
    const lmk = try regvm_type_track.exec(rt, mk);
    try std.testing.expect(Value.isCons(lmk));

    // Nested 9-binding let in tail position.
    try regvm_type_track.run(
        rt,
        "(defn (g) (let ((x1 1) (x2 2) (x3 3) (x4 4) (x5 5) (x6 6) (x7 7) (x8 8) (x9 9)) x9)) (g)",
        Value.i64(9),
    );

    // Tree-walker 17-binding let (evalNode .Let hash fallback).
    const let17_tw = try rt.evalString(
        comptime "(let ((a1 1) (a2 2) (a3 3) (a4 4) (a5 5) (a6 6) (a7 7) (a8 8) (a9 9) (a10 " ++
            "10) (a11 11) (a12 12) (a13 13) (a14 14) (a15 15) (a16 16) (a17 17)) a17)",
    );
    try std.testing.expectEqual(Value.i64(17), let17_tw);
}

test "register VM supports rest arguments across host and spawned calls" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const pair_rest = try rt.evalString("(fn (first . rest) (list first rest))");
    const expected = try rt.evalString("(list 1 (list 2 3))");
    const equal = try rt.nsGet(rt.root_ns, try rt.store.getsym("equal?"));
    const applied = try rt.apply(
        rt.root_ns,
        pair_rest,
        &.{ Value.i64(1), Value.i64(2), Value.i64(3) },
    );
    try std.testing.expectEqual(Value.true, try rt.apply(rt.root_ns, equal, &.{ applied, expected }));

    var workspace = CallWorkspace.init(std.testing.allocator);
    defer workspace.deinit();
    var outputs: [1]Value = undefined;
    try workspace.apply(
        rt.context(),
        pair_rest,
        &.{ Value.i64(1), Value.i64(2), Value.i64(3) },
        &outputs,
    );
    try std.testing.expectEqual(Value.true, try rt.apply(rt.root_ns, equal, &.{ outputs[0], expected }));
    try std.testing.expectError(error.ArityMismatch, workspace.apply(
        rt.context(),
        pair_rest,
        &.{},
        &outputs,
    ));

    const zero_rest = try rt.evalString("(fn rest rest)");
    const process = try rt.spawnClosure(zero_rest);
    try std.testing.expectEqual(Value.nil, try rt.awaitProcess(process));
    try std.testing.expectError(error.ArityMismatch, rt.spawnClosure(pair_rest));
}

test "letrec rejects malformed bindings and function parameters" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try regvm_type_track.runErr(rt, "(letrec ((x)) x)", error.MalformedAst);
    try regvm_type_track.runErr(rt, "(letrec ((1 2)) 0)", error.MalformedAst);
    try regvm_type_track.runErr(rt, "(fn (x . 7) x)", error.MalformedAst);
}

test "bound type predicates preserve branch values" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try regvm_type_track.run(rt, "(defn (f x) (if (i64? x) (+ x 1) (+ x 2))) (f 5)", Value.i64(6));
    try regvm_type_track.run(rt, "(defn (g x) (if (f64? x) (+ x 0.5) 0)) (g 1.5)", Value.f64(2.0));
    try regvm_type_track.run(rt, "(defn (h x) (+ (if (i64? x) x 0) 1)) (h 5)", Value.i64(6));
    try regvm_type_track.run(rt, "(defn (h x) (+ (if (i64? x) x 0) 1)) (h \"s\")", Value.i64(1));
}

test "bound case keys preserve matched and unmatched values" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try regvm_type_track.run(rt, "(defn (f x) (case x ((1) (+ x 1)) (else 0))) (f 1)", Value.i64(2));
    try regvm_type_track.run(rt, "(defn (f x) (case x ((1) (+ x 1)) (else 0))) (f 5)", Value.i64(0));
    try regvm_type_track.run(rt, "(defn (g x) (case x ((1 2) (+ x 1)) (else 0))) (g 2)", Value.i64(3));
    try regvm_type_track.run(rt, "(defn (h x) (case x ((1 \"a\") (+ x 1)) (else 0))) (h 1)", Value.i64(2));
    try regvm_type_track.run(rt, "(defn (j x) (case x ((1) 0) (else (+ x 1)))) (j 5)", Value.i64(6));
}

test "bound let bindings preserve values and errors" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try regvm_type_track.runErr(rt, "(let ((x \"s\")) (+ x 1))", error.ArityMismatch);

    try regvm_type_track.run(rt, "(let ((x 5)) (+ x 1))", Value.i64(6));
    try regvm_type_track.run(rt, "(defn (f x) (let ((x 5)) (+ x 1))) (f 9)", Value.i64(6));
    try regvm_type_track.runStr(rt, "(let ((x \"s\")) x)", "s");
}

test "bound let shadow defeats enclosing type predicate" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try regvm_type_track.runErr(
        rt,
        "(defn (f x) (if (i64? x) (let ((x \"s\")) (+ x 1)) 0)) (f 1)",
        error.ArityMismatch,
    );
    try regvm_type_track.run(rt, "(defn (f x) (if (i64? x) (let ((x \"s\")) (+ x 1)) 0)) (f \"s\")", Value.i64(0));
}

test "bound def invalidates earlier type facts" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try regvm_type_track.runStr(rt, "(defn (f x) (if (i64? x) (begin (def x \"s\") x) 0)) (f 1)", "s");
    try regvm_type_track.run(rt, "(defn (f x) (if (i64? x) (begin (def x \"s\") x) 0)) (f \"s\")", Value.i64(0));
}

test "regvm type tracking soundness: narrowing never changes runtime results" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // The narrowing is compile-time bookkeeping only: with an i64 argument the
    // true branch returns the value unchanged, and with any other type the
    // else branch returns :no. A compiler bug that narrowed the ELSE branch
    // (or miscompiled the then-branch) would change one of these results.
    try regvm_type_track.run(rt, "(defn (f x) (if (i64? x) x :no)) (f 1)", Value.i64(1));
    try regvm_type_track.runKw(rt, "(defn (f x) (if (i64? x) x :no)) (f \"s\")", "no");
    try regvm_type_track.runKw(rt, "(defn (f x) (if (i64? x) x :no)) (f 1.5)", "no");
}

test "disabled compiler optimizations preserve results and errors" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    rt.compiler_opts.global = false;

    const src = "(defn (f x) (if (i64? x) (+ x 1) (case x ((1) (+ x 2)) (else 0))))";
    try regvm_type_track.run(rt, src ++ " (f 1)", Value.i64(2));
    try regvm_type_track.runErr(rt, "(defn (g x) (+ x 1)) (g \"s\")", error.ArityMismatch);
}

test "disabled arithmetic fast path preserves case selection" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    rt.compiler_opts.arith_fast_path = false;

    const src = "(defn (f x) (if (i64? x) (case x ((1) (+ x 2)) (else 0)) 0))";
    try regvm_type_track.run(rt, src ++ " (f 1)", Value.i64(3));
}

test "core arith ops are non-overridable" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    // The prelude locks the arith/comparison methods: re-registering a
    // builtin signature for `+` is refused with error.Unsupported.
    const over = try rt.spawnEval("(instance + i64 i64 (fn (a b) 42))");
    try std.testing.expectError(error.Unsupported, rt.awaitProcess(over));
    // Core dispatch is intact.
    const ok = try rt.spawnEval("(+ 1 2)");
    try std.testing.expectEqual(Value.i64(3), try rt.awaitProcess(ok));
    // A NON-core method (a math function, not locked) is still overridable.
    const math = try rt.spawnEval("(instance max i64 i64 (fn (a b) 7)) (max 1 2)");
    try std.testing.expectEqual(Value.i64(7), try rt.awaitProcess(math));
}

// ---
// SPECULATIVE arith (compiler_opts.speculative_arith): when on, an
// UNPROVABLE 2-operand arith/comparison (+ - * / = <) compiles to a
// BEST-EFFORT specialized opcode — a BET on the single-typed operand's type
// (op1 first, else op2), defaulting to i64 when neither is single. The
// evalReg handler type-guards every specialized opcode: operands matching
// the opcode's expected type take the native fast path, anything else falls
// back to the generic method dispatch (the same apply path the generic_*
// opcodes use). The bet must be invisible: results are byte-identical to
// speculative_arith = off for every program, and a wrong bet (a string or
// f64 argument through an i64 bet) raises the same method-miss error the
// generic dispatch raises — never garbage from an unguarded toInt.
// ---
const speculative_arith = struct {
    /// Run `src` twice on the same runtime — once with speculative_arith on,
    /// once off — and assert both runs produce the IDENTICAL outcome (same
    /// result Value or same error). The bet is a pure fast path: no program
    /// may observe a difference. Restores the flag to on before returning.
    fn runEq(rt_: *Runtime, src: []const u8) !void {
        rt_.compiler_opts.speculative_arith = true;
        const on_val = regvm_type_track.exec(rt_, src) catch |on_err| {
            // ON errored (a genuine Zig error): OFF must raise the SAME
            // error.
            rt_.compiler_opts.speculative_arith = false;
            defer rt_.compiler_opts.speculative_arith = true;
            try std.testing.expectError(on_err, regvm_type_track.exec(rt_, src));
            return;
        };
        rt_.compiler_opts.speculative_arith = false;
        defer rt_.compiler_opts.speculative_arith = true;
        // ON succeeded (a value or an error VALUE): OFF must match. Error
        // values are store objects (fresh refs per run) — compare the
        // anyerror payload; success values compare as before.
        const off_val = try regvm_type_track.exec(rt_, src);
        if (on_val.typ == b.type_error or off_val.typ == b.type_error) {
            try std.testing.expectEqual(on_val.errorCode(), off_val.errorCode());
        } else {
            try std.testing.expectEqual(on_val, off_val);
        }
    }
};

test "regvm speculative arith runtime: native fast path and guard fallback" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // (a) the bet is right: both runtime operands match the bet type -> the
    // native specialized opcode runs and returns the exact value.
    try regvm_type_track.run(rt, "(defn (f x) (+ x 1)) (f 2)", Value.i64(3));
    try regvm_type_track.run(rt, "(defn (g x) (+ x 1.5)) (g 2.5)", Value.f64(4.0));

    // (b) the bet is wrong at runtime: the guard fires and falls back to the
    // generic dispatch, which now coerces the mixed pair (i64+f64 → f64) and
    // returns the coerced result instead of the pre-change method miss.
    try regvm_type_track.run(rt, "(defn (f x) (+ x 1)) (f 2.5)", Value.f64(3.5));
    try regvm_type_track.run(rt, "(defn (g x) (+ x 1.5)) (g 2)", Value.f64(3.5));

    // (c) value-equality: both fallback cases behave identically with
    // speculative_arith off (the guard is a pure fast path).
    rt.compiler_opts.speculative_arith = false;
    try regvm_type_track.run(rt, "(defn (f x) (+ x 1)) (f 2.5)", Value.f64(3.5));
    try regvm_type_track.run(rt, "(defn (g x) (+ x 1.5)) (g 2)", Value.f64(3.5));
}

test "regvm speculative arith: on/off value-equality across a program battery" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // Every program is run twice — speculative_arith on and off — and must
    // produce the identical outcome (same value or same error). Covers i64
    // arith, f64 arith, both-unknown defaults, wrong bets that fall back to
    // a valid SAME-TYPE dispatch, mixed-type method misses, comparisons
    // (= and <), nested arith, and string arguments.
    // i64 bets (correct at runtime):
    try speculative_arith.runEq(rt, "(defn (f x) (+ x 1)) (f 2)");
    try speculative_arith.runEq(rt, "(defn (s x) (- x 3)) (s 9)");
    try speculative_arith.runEq(rt, "(defn (m x) (* x 4)) (m 5)");
    try speculative_arith.runEq(rt, "(defn (d x) (/ x 2)) (d 7)");
    // f64 bets (correct at runtime):
    try speculative_arith.runEq(rt, "(defn (g x) (+ x 1.5)) (g 2.5)");
    try speculative_arith.runEq(rt, "(defn (g x) (- x 0.5)) (g 1.5)");
    try speculative_arith.runEq(rt, "(defn (g x) (* x 2.0)) (g 1.5)");
    try speculative_arith.runEq(rt, "(defn (g x) (/ x 2.0)) (g 5.0)");
    // default-i64 bet (both operands unknown):
    try speculative_arith.runEq(rt, "(defn (h x y) (+ x y)) (h 1 2)");
    // wrong bet that falls back to a valid SAME-TYPE dispatch: the guard
    // sends (1.5 2.5) through the generic "+", which finds the f64 instance.
    try speculative_arith.runEq(rt, "(defn (h x y) (+ x y)) (h 1.5 2.5)");
    // mixed types -> method-miss either way:
    try speculative_arith.runEq(rt, "(defn (f x) (+ x 1)) (f 2.5)");
    try speculative_arith.runEq(rt, "(defn (g x) (+ x 1.5)) (g 2)");
    try speculative_arith.runEq(rt, "(defn (h x y) (+ x y)) (h 1 2.5)");
    try speculative_arith.runEq(rt, "(defn (s x) (- x 1)) (s 2.5)");
    try speculative_arith.runEq(rt, "(defn (m x) (* x 1)) (m 2.5)");
    try speculative_arith.runEq(rt, "(defn (d x) (/ x 1)) (d 2.5)");
    // comparisons:
    try speculative_arith.runEq(rt, "(defn (lt x) (< x 5)) (lt 3)");
    try speculative_arith.runEq(rt, "(defn (lt x) (< x 5)) (lt 9)");
    try speculative_arith.runEq(rt, "(defn (lt x) (< x 5)) (lt 3.5)");
    try speculative_arith.runEq(rt, "(defn (e x) (= x 5)) (e 5)");
    try speculative_arith.runEq(rt, "(defn (e x) (= x 5)) (e 6)");
    try speculative_arith.runEq(rt, "(defn (e x) (= x 5)) (e 5.0)");
    try speculative_arith.runEq(rt, "(defn (e x) (= x 5)) (e \"s\")");
    // nested arith (the bet's ts_unknown result flows into the outer +):
    try speculative_arith.runEq(rt, "(defn (n x) (+ (+ x 1) 2)) (n 3)");
    try speculative_arith.runEq(rt, "(defn (n x) (+ (+ x 1) 2)) (n 3.5)");
    try speculative_arith.runEq(rt, "(defn (n x) (+ (* x 2) 1)) (n 3)");
    // string arguments (guard safety):
    try speculative_arith.runEq(rt, "(defn (f x) (+ x 1)) (f \"s\")");
    try speculative_arith.runEq(rt, "(defn (g x) (+ x 1.5)) (g \"s\")");
}

test "regvm speculative arith guard: wrong-type operand falls back, never garbage" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try regvm_type_track.runErr(rt, "(defn (f x) (+ x 1)) (f \"s\")", error.ArityMismatch);

    // Same for every bet opcode family: sub/mul/div/lt/eq with a string arg
    // must error, never produce garbage; a mismatched NUMERIC operand now
    // coerces at dispatch (i64+f64 → f64) instead of erroring.
    try regvm_type_track.runErr(rt, "(defn (s x) (- x 1)) (s \"s\")", error.ArityMismatch);
    try regvm_type_track.runErr(rt, "(defn (m x) (* x 1)) (m \"s\")", error.ArityMismatch);
    try regvm_type_track.runErr(rt, "(defn (d x) (/ x 1)) (d \"s\")", error.ArityMismatch);
    try regvm_type_track.run(rt, "(defn (d x) (/ x 1)) (d 2.5)", Value.f64(2.5));
    try regvm_type_track.runErr(rt, "(defn (lt x) (< x 1)) (lt \"s\")", error.ArityMismatch);
    try regvm_type_track.runErr(rt, "(defn (e x) (= x 1)) (e \"s\")", error.ArityMismatch);

    // Value-equality with speculative_arith off: the same outcomes, no
    // crash — the guard reproduces the non-speculative path exactly.
    rt.compiler_opts.speculative_arith = false;
    try regvm_type_track.runErr(rt, "(defn (f x) (+ x 1)) (f \"s\")", error.ArityMismatch);
    try regvm_type_track.run(rt, "(defn (d x) (/ x 1)) (d 2.5)", Value.f64(2.5));
}

test "regvm specialized i64 division reports zero and signed overflow" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try regvm_type_track.runErr(rt, "(defn (d x) (/ x 0)) (d 1)", error.TypeMismatch);
    try regvm_type_track.runErr(
        rt,
        "(defn (d x) (/ x -1)) (d -9223372036854775808)",
        error.Unsupported,
    );
}

test "regvm speculative arith: comparison bets (lt/eq) emit, run, and fall back" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try regvm_type_track.run(rt, "(defn (lt x) (< x 5)) (lt 3)", Value.true);
    try regvm_type_track.run(rt, "(defn (lt x) (< x 5)) (lt 9)", Value.false);

    // (c) (lt 3.5): the guard fires (f64 vs the bet i64) and falls back to
    // the generic "<" dispatch, which coerces (i64+f64 → f64): 3.5 < 5.0 ->
    // #t, identical to speculative_arith = off.
    rt.compiler_opts.speculative_arith = false;
    try regvm_type_track.run(rt, "(defn (lt x) (< x 5)) (lt 3.5)", Value.true);
    rt.compiler_opts.speculative_arith = true;
    try regvm_type_track.run(rt, "(defn (lt x) (< x 5)) (lt 3.5)", Value.true);

    try regvm_type_track.run(rt, "(defn (e x) (= x 5)) (e 5)", Value.true);
    try regvm_type_track.run(rt, "(defn (e x) (= x 5)) (e 6)", Value.false);
    try speculative_arith.runEq(rt, "(defn (e x) (= x 5)) (e 5.0)");
}

test "regvm ABI value-equality: default == --no-bytecode-opts" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // Battery under the DEFAULT config (copy-prop on): exact values.
    try regvm_type_track.run(rt, "(+ 1 2)", Value.i64(3));
    try regvm_type_track.run(rt, "(if (< 1 2) 3 4)", Value.i64(3));
    try regvm_type_track.run(rt, "(if (> 1 2) 3 4)", Value.i64(4));
    try regvm_type_track.runKw(rt, "(case 2 ((1) :one) ((2) :two) (else :other))", "two");
    try regvm_type_track.runKw(rt, "(case 1 ((1 2) :twelve) (else :other))", "twelve");
    try std.testing.expect(Value.isNil(try regvm_type_track.exec(rt, "(case 9 ((1) :one) ((2) :two))")));
    try regvm_type_track.run(
        rt,
        "(defn (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 20)",
        Value.i64(6765),
    );

    // Identical under --no-bytecode-opts (every optimization off, including
    // copy_propagation via allOff()).
    rt.compiler_opts.global = false;
    try regvm_type_track.run(rt, "(+ 1 2)", Value.i64(3));
    try regvm_type_track.run(rt, "(if (< 1 2) 3 4)", Value.i64(3));
    try regvm_type_track.run(rt, "(if (> 1 2) 3 4)", Value.i64(4));
    try regvm_type_track.runKw(rt, "(case 2 ((1) :one) ((2) :two) (else :other))", "two");
    try regvm_type_track.runKw(rt, "(case 1 ((1 2) :twelve) (else :other))", "twelve");
    try std.testing.expect(Value.isNil(try regvm_type_track.exec(rt, "(case 9 ((1) :one) ((2) :two))")));
    try regvm_type_track.run(
        rt,
        "(defn (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 20)",
        Value.i64(6765),
    );
    rt.compiler_opts.global = true;

    // Secondary runtime probe: same programs through clean instance.
    var srt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer srt.deinit();
    try std.testing.expectEqual(Value.i64(3), try srt.evalString("(+ 1 2)"));
    try std.testing.expectEqual(Value.i64(3), try srt.evalString("(if (< 1 2) 3 4)"));
    try std.testing.expectEqual(Value.i64(4), try srt.evalString("(if (> 1 2) 3 4)"));
    _ = try srt.evalString("(defn (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))");
    try std.testing.expectEqual(Value.i64(610), try srt.evalString("(fib 15)"));
}

/// Copy-prop value-equality helper: run `src` with copy_propagation ON and
/// OFF and assert the IDENTICAL outcome (same Value or same error). The pass
/// is a pure cleanup — no program may observe a difference. Restores the
/// flag to on before returning.
const copy_prop_eq = struct {
    fn run(rt_: *Runtime, src: []const u8) !void {
        rt_.compiler_opts.copy_propagation = true;
        const on_val = regvm_type_track.exec(rt_, src) catch |on_err| {
            // ON errored (a genuine Zig error — allocation etc.): OFF must
            // raise the SAME error.
            rt_.compiler_opts.copy_propagation = false;
            defer rt_.compiler_opts.copy_propagation = true;
            try std.testing.expectError(on_err, regvm_type_track.exec(rt_, src));
            return;
        };
        rt_.compiler_opts.copy_propagation = false;
        defer rt_.compiler_opts.copy_propagation = true;
        // ON succeeded (a value or an error VALUE): OFF must match. Error
        // values are store objects (two runs allocate different refs), so
        // compare the anyerror payload; success values compare as before.
        const off_val = try regvm_type_track.exec(rt_, src);
        if (on_val.typ == b.type_error or off_val.typ == b.type_error) {
            try std.testing.expectEqual(on_val.errorCode(), off_val.errorCode());
        } else {
            try std.testing.expectEqual(on_val, off_val);
        }
    }
};

test "regvm copy-prop value-equality: identical results/errors on and off" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // Param-read folding (the pass's bread and butter).
    try copy_prop_eq.run(rt, "(defn (f x) (+ x 1)) (f 2)");
    // Branch predicates fed by a param read (the (if (< x 3) ...) case).
    try copy_prop_eq.run(rt, "(defn (g x) (if (< x 3) x 0)) (g 5)");
    try copy_prop_eq.run(rt, "(defn (g x) (if (< x 3) x 0)) (g 1)");
    // Recursion + nested calls (staging movs into the call window must not
    // be disturbed).
    try copy_prop_eq.run(rt, "(defn (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 20)");
    // case with multiple clauses + multi-key + no-else (nil join).
    try copy_prop_eq.run(rt, "(defn (c x) (case x ((1) :one) ((2) :two) (else :other))) (c 2)");
    try copy_prop_eq.run(rt, "(defn (c x) (case x ((1 2) :twelve) (else :other))) (c 1)");
    try copy_prop_eq.run(rt, "(defn (c x) (case x ((1) :one) ((2) :two))) (c 9)");
}

test "regvm copy-prop safety: method-miss errors unchanged on and off" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // The pass must not change runtime behavior: a string through (+ x 1)
    // raises the SAME method-miss error with copy-prop on and off. (The
    // arith bet's guard falls back to the generic dispatch either way; the
    // folded param read changes nothing observable.)
    rt.compiler_opts.copy_propagation = true;
    try regvm_type_track.runErr(rt, "(defn (f x) (+ x 1)) (f \"s\")", error.ArityMismatch);
    rt.compiler_opts.copy_propagation = false;
    try regvm_type_track.runErr(rt, "(defn (f x) (+ x 1)) (f \"s\")", error.ArityMismatch);
    rt.compiler_opts.copy_propagation = true;

    // Same for the if-predicate path.
    try copy_prop_eq.run(rt, "(defn (g x) (if (< x 3) x 0)) (g \"s\")");
    try copy_prop_eq.run(rt, "(defn (c x) (case x ((1) :one) ((2) :two) (else :other))) (c \"s\")");
}

test "bound call windows preserve expression and parameter arguments" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try regvm_type_track.run(rt, "(defn (g x y) (+ x y)) (defn (h a b) (g (+ a b) (- a b))) (h 7 2)", Value.i64(14));
    try regvm_type_track.run(
        rt,
        "(defn (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (defn (k n) (fib (- n 1))) (k 5)",
        Value.i64(3),
    );
    try regvm_type_track.run(rt, "(defn (apply2 f x) (f x)) (apply2 (fn (y) (+ y 1)) 41)", Value.i64(42));
}

test "bound if and case arms preserve selected values" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try regvm_type_track.run(rt, "(defn (g x) (if (< x 3) x 0)) (g 1)", Value.i64(1));
    try regvm_type_track.run(rt, "(defn (g x) (if (< x 3) x 0)) (g 5)", Value.i64(0));
    try regvm_type_track.run(rt, "(defn (g2 x) (if (< x 3) 1 2)) (g2 1)", Value.i64(1));
    try regvm_type_track.run(rt, "(defn (g2 x) (if (< x 3) 1 2)) (g2 5)", Value.i64(2));
    try regvm_type_track.runKw(rt, "(defn (c x) (case x ((1 2) :twelve) (else :other))) (c 1)", "twelve");
    try regvm_type_track.runKw(rt, "(defn (c x) (case x ((1 2) :twelve) (else :other))) (c 2)", "twelve");
    try regvm_type_track.runKw(rt, "(defn (c x) (case x ((1 2) :twelve) (else :other))) (c 9)", "other");
}

test "bound call arms preserve results across joins" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try regvm_type_track.run(
        rt,
        "(defn (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) " ++
            "(defn (gcall x) (if (< x 3) (fib x) 0)) (gcall 1)",
        Value.i64(1),
    );
    try regvm_type_track.run(
        rt,
        "(defn (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) " ++
            "(defn (gcall x) (if (< x 3) (fib x) 0)) (gcall 5)",
        Value.i64(0),
    );
    try regvm_type_track.run(
        rt,
        "(defn (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) " ++
            "(defn (ccall x) (case x ((1) (fib x)) (else :other))) (ccall 1)",
        Value.i64(1),
    );
    try regvm_type_track.runKw(
        rt,
        "(defn (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) " ++
            "(defn (ccall x) (case x ((1) (fib x)) (else :other))) (ccall 2)",
        "other",
    );
}

test "bound recursive calls preserve live values" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const src = "(defn (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))";
    try regvm_type_track.run(rt, src ++ " (fib 20)", Value.i64(6765));
    try regvm_type_track.run(rt, src ++ " (fib 1)", Value.i64(1));
}

test "bound nested call windows do not clobber live values" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try regvm_type_track.runErr(
        rt,
        "(defn (g x y) (+ x y)) (defn (h a b c) (g (+ a b c) a)) (h 1 2 3)",
        error.ArityMismatch,
    );

    // Same fallback shape with a defined 3-arg callee: the collision is
    // exercised at compile time and the runtime value is exactly right (a
    // clobbering window would return garbage).
    const src = "(defn (f3 a b c) (+ (+ a b) c)) (defn (g x y) (+ x y)) (defn (h a b c) (g (f3 a b c) a))";
    try regvm_type_track.run(rt, src ++ " (h 1 2 3)", Value.i64(7));
    try regvm_type_track.run(rt, src ++ " (h 10 20 30)", Value.i64(70));

    // The same shape through the process path (spawnEval + awaitProcess).
    const proc = try rt.spawnEval(src ++ " (h 4 5 6)");
    try std.testing.expectEqual(Value.i64(19), try rt.awaitProcess(proc));
}

test "regvm target-reg value-equality: default == --no-bytecode-opts" {
    var rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    // Battery under the DEFAULT config (target mechanism always on).
    try regvm_type_track.run(rt, "(+ 1 2)", Value.i64(3));
    try regvm_type_track.run(rt, "(if (< 1 2) 3 4)", Value.i64(3));
    try regvm_type_track.run(rt, "(if (> 1 2) 3 4)", Value.i64(4));
    try regvm_type_track.runKw(rt, "(case 2 ((1) :one) ((2) :two) (else :other))", "two");
    try regvm_type_track.runKw(rt, "(case 1 ((1 2) :twelve) (else :other))", "twelve");
    try std.testing.expect(Value.isNil(try regvm_type_track.exec(rt, "(case 9 ((1) :one) ((2) :two))")));
    try regvm_type_track.run(rt, "((fn (x) (x 1)) (fn (y) y))", Value.i64(1));
    try regvm_type_track.run(
        rt,
        "(defn (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 20)",
        Value.i64(6765),
    );
    try regvm_type_track.runErr(rt, "(defn (f x) (+ x 1)) (f \"s\")", error.ArityMismatch);

    // Identical under --no-bytecode-opts: global=false turns every gate off
    // via allOff() (the target mechanism is NOT gated — it stays on), so the
    // values cannot change.
    rt.compiler_opts.global = false;
    try regvm_type_track.run(rt, "(+ 1 2)", Value.i64(3));
    try regvm_type_track.run(rt, "(if (< 1 2) 3 4)", Value.i64(3));
    try regvm_type_track.run(rt, "(if (> 1 2) 3 4)", Value.i64(4));
    try regvm_type_track.runKw(rt, "(case 2 ((1) :one) ((2) :two) (else :other))", "two");
    try regvm_type_track.runKw(rt, "(case 1 ((1 2) :twelve) (else :other))", "twelve");
    try std.testing.expect(Value.isNil(try regvm_type_track.exec(rt, "(case 9 ((1) :one) ((2) :two))")));
    try regvm_type_track.run(rt, "((fn (x) (x 1)) (fn (y) y))", Value.i64(1));
    try regvm_type_track.run(
        rt,
        "(defn (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 20)",
        Value.i64(6765),
    );
    try regvm_type_track.runErr(rt, "(defn (f x) (+ x 1)) (f \"s\")", error.ArityMismatch);
    rt.compiler_opts.global = true;

    // Secondary runtime probe: same programs through clean instance.
    var srt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer srt.deinit();
    try std.testing.expectEqual(Value.i64(3), try srt.evalString("(+ 1 2)"));
    try std.testing.expectEqual(Value.i64(3), try srt.evalString("(if (< 1 2) 3 4)"));
    try std.testing.expectEqual(Value.i64(4), try srt.evalString("(if (> 1 2) 3 4)"));
    try std.testing.expectEqual(Value.i64(1), try srt.evalString("((fn (x) (x 1)) (fn (y) y))"));
    _ = try srt.evalString("(defn (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))");
    try std.testing.expectEqual(Value.i64(610), try srt.evalString("(fib 15)"));
    // Direct evaluation preserves the method-miss error.
    _ = try srt.evalString("(defn (f x) (+ x 1))");
    try std.testing.expectError(error.ArityMismatch, srt.evalString("(f \"s\")"));
}

test "bound redefinitions preserve values read before the write" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    try std.testing.expectEqual(Value.i64(1), try rt.evalString("(let ((x 1) (before x)) (def x 2) before)"));
    try std.testing.expectEqual(Value.i64(2), try rt.evalString("(let ((x 1)) (def x 2) x)"));
}

test "restored canonical methods permit fresh AD but invalidate held derivatives" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const held = try rt.evalString("(deriv (fn (x) (sin x)))");
    _ = try rt.evalString(
        "(instance sin f64 (fn (x) (* x x))) (instance sin f64 @f64.sin)",
    );
    const fresh = try rt.evalString("(deriv (fn (x) (sin x)))");
    try std.testing.expectEqual(Value.f64(1), try rt.apply(rt.root_ns, fresh, &.{Value.f64(0)}));
    try std.testing.expectError(error.Unsupported, rt.apply(rt.root_ns, held, &.{Value.f64(0)}));
}

test "bound loops preserve invariant callees across backedges" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var builder = Code.Builder.init(rt.static, rt.context());
    const identity = try rt.allocCodeIdentity();
    builder.id = identity.id;
    builder.revision = identity.revision;
    const main_function = try builder.addFunction(null, .{});
    builder.functions.items[@intFromEnum(main_function)].module_entry = true;
    const entry = try builder.addBlock(main_function);
    const loop = try builder.addBlock(main_function);
    const body = try builder.addBlock(main_function);
    const exit = try builder.addBlock(main_function);
    const remaining = try builder.addBlockParam(loop, main_function);
    const initial = try builder.addNode(main_function, entry, .{ .literal = Value.i64(3) }, .{});
    const zero = try builder.addNode(main_function, entry, .{ .literal = Value.i64(0) }, .{});
    const callback = try builder.addFunction(null, .{});
    const callback_block = try builder.addBlock(callback);
    const one = try builder.addNode(callback, callback_block, .{ .literal = Value.i64(1) }, .{});
    try builder.setTerminator(callback_block, .{ .return_values = try builder.addOperands(&.{one}) });
    const callee = try builder.addNode(main_function, entry, .{ .make_closure = .{ .function = callback } }, .{});
    try builder.setTerminator(entry, .{ .jump = .{ .target = loop, .args = try builder.addOperands(&.{initial}) } });
    const done = try builder.addNode(main_function, loop, .{ .arithmetic = .{
        .op = .equal,
        .left = remaining,
        .right = zero,
    } }, .{});
    try builder.setTerminator(loop, .{ .branch = .{
        .condition = done,
        .then_edge = .{ .target = exit },
        .else_edge = .{ .target = body },
    } });
    const step = try builder.addNode(main_function, body, .{ .dynamic_call = .{ .callee = callee } }, .{});
    const next = try builder.addNode(main_function, body, .{ .arithmetic = .{
        .op = .sub,
        .left = remaining,
        .right = step,
    } }, .{});
    try builder.setTerminator(body, .{ .jump = .{ .target = loop, .args = try builder.addOperands(&.{next}) } });
    try builder.setTerminator(exit, .{ .return_values = try builder.addOperands(&.{remaining}) });
    const code = try builder.finish(std.testing.allocator);
    code.owner = rt;
    const program = try rt.lowerCode(std.testing.allocator, code);
    const stack = try rt.static.alloc(Object, frame_size + @as(usize, program.nregs) * 2);
    @memset(stack, .null);
    var fiber: Fiber = .{
        .stack = stack,
        .sp = stack.len,
        .ip = program.ir.ptr,
        .ir = program.ir,
        .nregs = program.nregs,
        .consts = program.constants,
        .fns = program.fns,
        .ns = rt.root_ns,
    };
    try std.testing.expectEqual(EvalStatus.done, try rt.evalReg(rt.root_ns, &fiber, 1024));
    try std.testing.expectEqual(Value.i64(0), try fiber.getReg(0).unwrapError());
}

test "let reads observe writes through captured closures" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    try std.testing.expectEqual(
        Value.i64(2),
        try rt.evalString("(let ((x 1)) (begin ((fn () (def x 2))) x))"),
    );
}

test "unselected handlers cannot shadow parameter bindings" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    try std.testing.expectEqual(
        Value.i64(10),
        try rt.evalString("(defn (f x) (try 1 (catch e (def x 2))) x) (f 10)"),
    );
}

test "copy propagation preserves exception landing offsets" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const source = "(defn (f x) (try (begin x x x (raise :bad)) (catch e 42))) (f 1)";
    try std.testing.expectEqual(Value.i64(42), try rt.evalString(source));
    rt.compiler_opts.global = false;
    try std.testing.expectEqual(Value.i64(42), try rt.evalString(source));
}

test "qualified names cannot become lexical bindings" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    try std.testing.expectError(error.MalformedAst, rt.evalString("(fn (lib/x) lib/x)"));
    try std.testing.expectError(error.MalformedAst, rt.evalString("(let ((lib/x 1)) lib/x)"));
    try std.testing.expectError(error.MalformedAst, rt.evalString("(try 1 (catch lib/e lib/e))"));
    try std.testing.expectError(error.MalformedAst, rt.evalString("(guard (lib/e (else 1)) 2)"));
}

test "held derivatives reject changed transitive predicate effects before execution" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const derivative = try rt.evalString(
        "(def effect-state (hash-map :runs 0)) " ++
            "(def leaf (fn () #t)) (def pred (fn () (leaf))) " ++
            "(deriv (fn (x) (if (pred) (* x x) x)))",
    );
    try std.testing.expectEqual(Value.f64(6), try rt.apply(rt.root_ns, derivative, &.{Value.f64(3)}));
    _ = try rt.evalString("(def leaf (fn () (map-set! effect-state :runs 1) #t))");
    try std.testing.expectError(error.Unsupported, rt.apply(rt.root_ns, derivative, &.{Value.f64(3)}));
    try std.testing.expectEqual(Value.i64(0), try rt.evalString("(map-get effect-state :runs)"));
}

test "held derivatives guard captured predicate method revisions" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const derivative = try rt.evalString(
        "(def effect-state (hash-map :runs 0)) " ++
            "(def predicate (method)) (instance predicate f64 (fn (x) #t)) " ++
            "(deriv ((fn (p) (fn (x) (if (p x) (* x x) x))) predicate))",
    );
    try std.testing.expectEqual(Value.f64(6), try rt.apply(rt.root_ns, derivative, &.{Value.f64(3)}));
    _ = try rt.evalString("(instance predicate f64 (fn (x) (map-set! effect-state :runs 1) #t))");
    try std.testing.expectError(error.Unsupported, rt.apply(rt.root_ns, derivative, &.{Value.f64(3)}));
    try std.testing.expectEqual(Value.i64(0), try rt.evalString("(map-get effect-state :runs)"));
}

const ContextTest = struct {
    const Budget = EvalContext.Budget;

    ledger: Budget,
    lease: Budget.Lease,
    account: Budget.AccountAllocator,
    output_bytes: [1024]u8,
    writer: std.Io.Writer,
    ctx: EvalContext,

    fn init(
        self: *ContextTest,
        rt: *Runtime,
        limits: Budget.Limits,
        options: EvalContext.LimitedOptions,
    ) !void {
        self.ledger = Budget.init(rt.io, 1, limits);
        self.lease = try Budget.Lease.root(&self.ledger, limits.work);
        self.account = Budget.AccountAllocator.init(std.testing.allocator, &self.lease, .native);
        self.writer = .fixed(&self.output_bytes);
        self.ctx = try EvalContext.limited(rt, rt.intrinsics.registryVersion(), &self.account, .{
            .writer = &self.writer,
            .bounded_memory = true,
        }, options);
    }

    fn invoke(self: *ContextTest, callable: Value, args: []const Value) Error!Value {
        return (try self.ctx.apply(self.ctx.runtime.root_ns, callable, args)).unwrapError();
    }

    fn awaitProcess(self: *ContextTest, process: *sched_mod.Process) !Value {
        for (0..2000) |_| {
            if (self.ctx.runtime.pollProcess(process)) |result| return result;
            try std.Io.sleep(self.ctx.runtime.io, .fromMilliseconds(1), .awake);
        }
        return error.TestUnexpectedResult;
    }

    const actor_options: EvalContext.LimitedOptions = .{
        .effects = .{ .state_read = .allow, .state_write = .allow, .process = .allow, .clock = .allow },
        .allow_suspend = true,
    };
};

test "limited qualified lookup resolves a namespace alias" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const binding = try rt.store.getsym("value");
    var local: SmallNamespace = .{};
    try local.bind(binding, .i64(41));
    const ref = try rt.store.create(Namespace);
    rt.store.store(Namespace, ref.deref(Namespace), SmallNamespace.vtable);
    ref.deref(Namespace).data = @ptrCast(&local);
    try rt.nsBind(rt.root_ns, try rt.store.getsym("qualified_alias"), .namespace(ref.toObject()));
    const reader = try rt.evalString("(fn () qualified_alias/value)");

    var limited: ContextTest = undefined;
    try limited.init(rt, .{ .work = 100_000 }, .{ .effects = .{ .state_read = .allow } });
    try std.testing.expectEqual(Value.i64(41), try limited.invoke(reader, &.{}));
}

test "locked namespace reads debit each known parent before access" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    _ = try rt.evalString("(def budget-read 41)");
    const binding = try rt.store.getsym("budget-read");
    var local: SmallNamespace = .{ .parent = rt.root_ns };
    const ref = try rt.store.create(Namespace);
    rt.store.store(Namespace, ref.deref(Namespace), SmallNamespace.vtable);
    ref.deref(Namespace).data = @ptrCast(&local);
    const child = Value.namespace(ref.toObject());
    const root_table = rt.root_ns.obj.toRef().deref(Namespace);
    const root_work = namespaceAccessWork(root_table, false);
    const total_work: u64 = 1 + 1 + SmallNamespace.size + 1 + root_work;

    var enough: ContextTest = undefined;
    try enough.init(rt, .{ .work = total_work }, .{ .effects = .{ .state_read = .allow } });
    {
        const scope = enough.ctx.activate();
        defer scope.deinit();
        var window = enough.lease.lockRegvm();
        defer window.deinit();
        try window.charge();
        try std.testing.expectEqual(
            Value.i64(41),
            try rt.restrictedNamespaceReadWithWindow(&enough.ctx, child, binding, &window),
        );
    }
    try std.testing.expectEqual(total_work, enough.ledger.snapshot().consumed.work);

    var short: ContextTest = undefined;
    try short.init(rt, .{ .work = total_work - 1 }, .{ .effects = .{ .state_read = .allow } });
    {
        const scope = short.ctx.activate();
        defer scope.deinit();
        var window = short.lease.lockRegvm();
        defer window.deinit();
        try window.charge();
        try std.testing.expectError(
            error.Exhausted,
            rt.restrictedNamespaceReadWithWindow(&short.ctx, child, binding, &window),
        );
    }
    const failure = short.ledger.report() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(EvalContext.Budget.Reason.quota, failure.reason);
    try std.testing.expectEqual(root_work - 1, failure.available);
    try std.testing.expectEqual(@as(?u64, root_work), failure.requested);
    try std.testing.expectEqual(total_work - 1 - failure.available, failure.consumed.work);
}

test "locked namespace reads reject foreign vtables before their callbacks" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const binding = try rt.store.getsym("foreign-read");
    const Probe = struct {
        const Self = @This();
        calls: u32 = 0,

        fn get(_: *Runtime, table: *Namespace, _: Object, _: Sym) callconv(.c) Value {
            const state: *Self = @ptrCast(@alignCast(table.data));
            state.calls += 1;
            return Value.i64(9);
        }
    };
    var probe: Probe = .{};
    const ref = try rt.store.create(Namespace);
    rt.store.store(Namespace, ref.deref(Namespace), SmallNamespace.vtable);
    ref.deref(Namespace).data = @ptrCast(&probe);
    ref.deref(Namespace).get = Probe.get;
    const foreign = Value.namespace(ref.toObject());

    var limited: ContextTest = undefined;
    try limited.init(rt, .{ .work = 2 }, .{ .effects = .{ .state_read = .allow } });
    {
        const scope = limited.ctx.activate();
        defer scope.deinit();
        var window = limited.lease.lockRegvm();
        defer window.deinit();
        try window.charge();
        try std.testing.expectError(
            error.Denied,
            rt.restrictedNamespaceReadWithWindow(&limited.ctx, foreign, binding, &window),
        );
    }
    try std.testing.expectEqual(@as(u32, 0), probe.calls);
    try std.testing.expectEqual(@as(u64, 2), limited.ledger.snapshot().consumed.work);
}

test "limited work exhaustion bypasses language catch and leaves trusted entry usable" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const loop = try rt.evalString(
        "(defn (spin n) (spin n)) (fn () (try (spin 0) (catch e 7)))",
    );
    var limited: ContextTest = undefined;
    try limited.init(rt, .{ .work = 512 }, .{});
    try std.testing.expectError(error.Exhausted, limited.invoke(loop, &.{}));
    const first = limited.ledger.report() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(EvalContext.Budget.Resource.work, first.resource);
    try std.testing.expectEqual(EvalContext.Budget.Backend.regvm, first.backend);
    try std.testing.expectError(error.Exhausted, limited.invoke(loop, &.{}));
    const repeated = limited.ledger.report() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualDeep(first, repeated);
    try std.testing.expectEqual(Value.i64(42), try rt.evalString("(+ 20 22)"));
}

test "limited branch execution spends its exact instruction budget before return" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const callable = try rt.evalString("(fn (n) (if (= n 0) (+ 20 22) (+ 30 12)))");
    var measured: ContextTest = undefined;
    try measured.init(rt, .{ .work = 100_000 }, .{});
    try std.testing.expectEqual(Value.i64(42), try measured.invoke(callable, &.{Value.i64(0)}));
    const spent = measured.ledger.snapshot().consumed.work;
    try std.testing.expect(spent > 1);

    var exact: ContextTest = undefined;
    try exact.init(rt, .{ .work = spent }, .{});
    try std.testing.expectEqual(Value.i64(42), try exact.invoke(callable, &.{Value.i64(0)}));
    try std.testing.expectEqual(spent, exact.ledger.snapshot().consumed.work);

    var short: ContextTest = undefined;
    try short.init(rt, .{ .work = spent - 1 }, .{});
    try std.testing.expectError(error.Exhausted, short.invoke(callable, &.{Value.i64(0)}));
    try std.testing.expectEqual(EvalContext.Budget.Resource.work, short.ledger.report().?.resource);
}

test "limited non-tail calls exhaust depth before growing an unbounded VM stack" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const recursive = try rt.evalString("(defn (dive n) (+ 1 (dive n))) dive");
    var limited: ContextTest = undefined;
    try limited.init(rt, .{ .work = 100000, .depth = 8 }, .{});
    try std.testing.expectError(error.Exhausted, limited.invoke(recursive, &.{Value.i64(0)}));
    try std.testing.expectEqual(EvalContext.Budget.Resource.depth, limited.ledger.report().?.resource);
}

test "pure limited namespaces permit private bindings but reject external state" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const read_state = try rt.evalString("(def external 1) (fn () external)");
    const write_state = try rt.evalString("(fn () (def external 2))");
    const local_state = try rt.evalString("(fn () (let ((x 1)) (def x 4) x))");
    var limited: ContextTest = undefined;
    try limited.init(rt, .{ .work = 100000 }, .{ .pure = true });
    try std.testing.expectEqual(Value.i64(4), try limited.invoke(local_state, &.{}));
    try std.testing.expectError(error.Denied, limited.invoke(read_state, &.{}));
    try std.testing.expectError(error.Denied, limited.invoke(write_state, &.{}));
    try std.testing.expectEqual(Value.i64(1), try rt.evalString("external"));
}

test "limited output rejects live display and refuses bytes before writing" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const display = try rt.evalString("(fn () (display \"blocked\"))");
    var limited: ContextTest = undefined;
    try limited.init(rt, .{ .work = 100000, .output = 2 }, .{ .effects = .{ .io = .allow } });
    rt.stdout = &limited.writer;
    try std.testing.expectError(error.Denied, limited.invoke(display, &.{}));
    try std.testing.expectEqualStrings("", limited.writer.buffered());
    try limited.ctx.writeAll("ok");
    try std.testing.expectError(error.Exhausted, limited.ctx.writeAll("!"));
    try std.testing.expectEqualStrings("ok", limited.writer.buffered());
    try std.testing.expectEqual(EvalContext.Budget.Resource.output, limited.ledger.report().?.resource);
}

test "limited symbol allocation fails terminally without corrupting the interner" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const input = try rt.evalString("\"new-budget-symbol\"");
    const make_symbol = Value.intrinsic(&intrin.misc.makeSymbol);
    var limited: ContextTest = undefined;
    try limited.init(rt, .{ .work = 100000, .bytes = 1 }, .{});
    try std.testing.expectError(error.Exhausted, limited.invoke(make_symbol, &.{input}));
    try std.testing.expectEqual(EvalContext.Budget.Resource.bytes, limited.ledger.report().?.resource);
    const symbol = try rt.apply(rt.root_ns, make_symbol, &.{input});
    try std.testing.expectEqualStrings("new-budget-symbol", symbol.obj.toPtr(Sym).*);
}

test "repeated compilation reuses symbol operands past the u16 append limit" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const initial_count = rt.symbol_pool.items.len;
    const sym = try rt.store.getsym("shared-operand");
    const expected = try rt.pushSymbol(sym);
    for (0..std.math.maxInt(u16) + 2) |_| {
        try std.testing.expectEqual(expected, try rt.pushSymbol(sym));
    }
    try std.testing.expectEqual(initial_count + 1, rt.symbol_pool.items.len);
}

test "limited tensor kernels charge bulk work before execution" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const tensor = try rt.evalString("(iota 4096)");
    var limited: ContextTest = undefined;
    try limited.init(rt, .{ .work = 128 }, .{ .effects = .{ .state_read = .allow } });
    try std.testing.expectError(error.Exhausted, limited.invoke(
        Value.intrinsic(&intrin.tensor.dot),
        &.{ tensor, tensor },
    ));
    try std.testing.expectEqual(EvalContext.Budget.Resource.work, limited.ledger.report().?.resource);
    try std.testing.expectEqual(EvalContext.Budget.Backend.native, limited.ledger.report().?.backend);
}

test "limited tensor callbacks consume the caller lineage without refueling" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const input = try rt.evalString("(iota 200)");
    const callback = try rt.evalString("(fn (x) (+ x 1))");
    const mapper = try rt.evalString("map");
    var limited: ContextTest = undefined;
    try limited.init(rt, .{ .work = 100000 }, .{ .effects = .{ .state_read = .allow } });
    try std.testing.expectError(error.Exhausted, limited.invoke(mapper, &.{ input, callback }));
    try std.testing.expectEqual(EvalContext.Budget.Resource.work, limited.ledger.report().?.resource);
    const result = try rt.apply(rt.root_ns, mapper, &.{ input, callback });
    const output = result.obj.toRef().deref(intrin.tensor.TensorHolder);
    try std.testing.expectEqual(@as(u64, 200), output.data[199]);
}

test "limited evaluation charges reader work before parsing" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var limited: ContextTest = undefined;
    try limited.init(rt, .{ .work = 1 }, .{});
    try std.testing.expectError(error.Exhausted, rt.evalStringWithContext(&limited.ctx, "(+ 1 2)"));
    try std.testing.expectEqual(EvalContext.Budget.Backend.reader, limited.ledger.report().?.backend);
}

test "limited actor children retain allowed suspension with sufficient budget" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const receiver = try rt.evalString("(fn () (receive))");
    var limited: ContextTest = undefined;
    try limited.init(rt, .{ .work = 100000 }, ContextTest.actor_options);
    const pid = try limited.invoke(Value.intrinsic(&intrin.process.spawn), &.{receiver});
    const process = pid.obj.toPtr(*sched_mod.Process);
    try std.testing.expectEqual(Value.i64(42), try rt.apply(
        rt.root_ns,
        Value.intrinsic(&intrin.process.send),
        &.{ pid, Value.i64(42) },
    ));
    try std.testing.expectEqual(Value.i64(42), try limited.awaitProcess(process));
}

test "limited actor apply forwards a suspending native call" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const callback = try rt.evalString("(fn () (apply sleep (list 2)) 42)");
    var limited: ContextTest = undefined;
    try limited.init(rt, .{ .work = 100000 }, ContextTest.actor_options);
    const pid = try limited.invoke(Value.intrinsic(&intrin.process.spawn), &.{callback});
    try std.testing.expectEqual(Value.i64(42), try limited.awaitProcess(pid.obj.toPtr(*sched_mod.Process)));
}

test "limited actor exhaustion cancels waiting siblings but not another lineage" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const receiver = try rt.evalString("(fn () (receive))");
    const spawner = try rt.evalString("(fn () (receive) (spawn (fn () 7)))");
    var limited: ContextTest = undefined;
    try limited.init(rt, .{ .work = 100000, .processes = 2 }, ContextTest.actor_options);
    const spawn = Value.intrinsic(&intrin.process.spawn);
    const waiting = try limited.invoke(spawn, &.{receiver});
    const active = try limited.invoke(spawn, &.{spawner});
    try std.testing.expectEqual(Value.true, try rt.apply(
        rt.root_ns,
        Value.intrinsic(&intrin.process.send),
        &.{ active, Value.true },
    ));
    try std.testing.expectError(error.Exhausted, limited.awaitProcess(active.obj.toPtr(*sched_mod.Process)));
    try std.testing.expectError(error.Exhausted, limited.awaitProcess(waiting.obj.toPtr(*sched_mod.Process)));
    try std.testing.expectEqual(EvalContext.Budget.Resource.processes, limited.ledger.report().?.resource);
    const independent = try rt.spawnEval("(+ 20 22)");
    try std.testing.expectEqual(Value.i64(42), try limited.awaitProcess(independent));
}

test "non-tail let restores namespace depth before the following tail call" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    try std.testing.expectEqual(Value.i64(42), try rt.evalString(
        "((fn (f) (let () 1) (f)) (fn () 42))",
    ));
}

test "limited gradient wrappers retain registered callback identity" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const gradient = try rt.evalString("(gradient (fn (x) (* x x)))");
    const value_gradient = try rt.evalString("(value-and-gradient (fn (x) (* x x)))");
    var limited: ContextTest = undefined;
    try limited.init(rt, .{ .work = 2000000 }, .{ .effects = .{ .state_read = .allow } });
    try std.testing.expectEqual(Value.f64(6), try limited.invoke(gradient, &.{Value.f64(3)}));
    const result = try limited.invoke(value_gradient, &.{Value.f64(3)});
    try std.testing.expectEqual(b.type_cons, result.typ);
    const pair = result.obj.toRef().deref([2]Value);
    try std.testing.expectEqual(Value.f64(9), pair[0]);
    try std.testing.expectEqual(Value.f64(6), pair[1]);
}

test "limited string search charges the sentinel scan even for an empty needle" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const bytes = try rt.store.sym_alloc.allocSentinel(u8, 4096, 0);
    @memset(bytes, 'x');
    const haystack = Value.string(.fromPtr(bytes.ptr));
    const needle = try rt.evalString("\"\"");
    var limited: ContextTest = undefined;
    try limited.init(rt, .{ .work = 128 }, .{});
    try std.testing.expectError(error.Exhausted, limited.invoke(
        Value.intrinsic(&intrin.string.find),
        &.{ haystack, needle },
    ));
    try std.testing.expectEqual(EvalContext.Budget.Resource.work, limited.ledger.report().?.resource);
}

test "limited native equality enforces recursive depth independently of work" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var left = Value.i64(1);
    var right = Value.i64(1);
    for (0..64) |_| {
        const a = try rt.store.create([2]Value);
        const b_ref = try rt.store.create([2]Value);
        rt.store.store([2]Value, a.deref([2]Value), .{ left, .nil });
        rt.store.store([2]Value, b_ref.deref([2]Value), .{ right, .nil });
        left = Value.cons(a.toObject());
        right = Value.cons(b_ref.toObject());
    }
    var limited: ContextTest = undefined;
    try limited.init(rt, .{ .work = 100000, .depth = 8 }, .{});
    try std.testing.expectError(error.Exhausted, limited.invoke(
        Value.intrinsic(&intrin.equal.equal),
        &.{ left, right },
    ));
    try std.testing.expectEqual(EvalContext.Budget.Resource.depth, limited.ledger.report().?.resource);
}

test "limited map updates avoid allocation and failed growth cannot publish a key" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const map = try rt.evalString("(hash-map :a 1 :b 2 :c 3 :d 4 :e 5 :f 6)");
    const existing = try rt.evalString(":a");
    const missing = try rt.evalString(":g");
    const setter = Value.intrinsic(&intrin.map.set);
    const getter = Value.intrinsic(&intrin.map.get);
    var limited: ContextTest = undefined;
    try limited.init(rt, .{ .work = 100000, .bytes = 0 }, .{
        .effects = .{ .state_read = .allow, .state_write = .allow },
    });
    try std.testing.expectEqual(Value.i64(1), try limited.invoke(setter, &.{ map, existing, Value.i64(42) }));
    try std.testing.expectEqual(Value.i64(42), try rt.apply(rt.root_ns, getter, &.{ map, existing }));
    try std.testing.expectError(error.Exhausted, limited.invoke(setter, &.{ map, missing, Value.i64(7) }));
    try std.testing.expectEqual(Value.nil, try rt.apply(rt.root_ns, getter, &.{ map, missing }));
    try std.testing.expectEqual(Value.i64(42), try rt.apply(rt.root_ns, getter, &.{ map, existing }));
}

test "dry evaluation computes against isolated mutable arguments" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const source = try rt.evalString("(hash-map :k 1)");
    const function = try rt.evalString(
        "(fn (shared) (begin (map-set! shared :k 7) (map-get shared :k)))",
    );
    var limited: ContextTest = undefined;
    try limited.init(rt, .{ .work = 50000000, .bytes = 128 * 1024 * 1024 }, .{
        .mode = .dry,
        .effects = .{ .state_read = .allow, .state_write = .allow },
    });
    try std.testing.expectEqual(Value.i64(7), try limited.invoke(function, &.{source}));
    const keyword = try rt.evalString(":k");
    try std.testing.expectEqual(Value.i64(1), try rt.apply(
        rt.root_ns,
        Value.intrinsic(&intrin.map.get),
        &.{ source, keyword },
    ));
}

test "nsAssign updates the nearest existing binding and never creates one" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const child_ref = try rt.store.create(Namespace);
    const child_obj = child_ref.toObject();
    const child = Value.namespace(child_obj);
    rt.store.store(Namespace, child_ref.deref(Namespace), HashMapNamespace.vtable);
    const child_map = try rt.static.create(HashMapNamespace);
    child_map.* = try HashMapNamespace.init(rt.static, rt.root_ns);
    child_ref.deref(Namespace).data = @ptrCast(child_map);
    rt.ownNamespace(child);

    const shadowed = try rt.store.getsym("phase1-ns-assign-shadowed");
    const inherited = try rt.store.getsym("phase1-ns-assign-inherited");
    const missing = try rt.store.getsym("phase1-ns-assign-missing");
    try rt.nsBind(rt.root_ns, shadowed, Value.i64(1));
    try rt.nsBind(child, shadowed, Value.i64(2));
    try rt.nsBind(rt.root_ns, inherited, Value.i64(3));

    try rt.nsAssign(child, shadowed, Value.i64(4));
    try std.testing.expectEqual(Value.i64(4), try rt.nsGet(child, shadowed));
    try std.testing.expectEqual(Value.i64(1), try rt.nsGet(rt.root_ns, shadowed));

    try rt.nsAssign(child, inherited, Value.i64(5));
    try std.testing.expectEqual(Value.i64(5), try rt.nsGet(rt.root_ns, inherited));
    try std.testing.expectError(error.Unbound, rt.nsAssign(child, missing, Value.i64(6)));
    try std.testing.expectError(error.Unbound, rt.nsGet(child, missing));
}

test "datum eval rejects non-concrete and non-namespace contexts" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    var trusted = rt.context().*;
    try std.testing.expectError(
        error.TypeMismatch,
        rt.evalDatumWithContext(&trusted, .nil, Value.i64(1)),
    );

    var limited: ContextTest = undefined;
    try limited.init(rt, .{ .work = 1000 }, .{
        .mode = .dry,
        .effects = EvalContext.EffectDecisionTable.trusted(),
    });
    try std.testing.expectError(error.Denied, rt.evalDatumWithContext(&limited.ctx, .nil, null));
}

test "datum eval compiles one form rather than treating call operands as forms" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const call = try rt.spawnEval("(eval '(+ 1 2))");
    try std.testing.expectEqual(Value.i64(3), try rt.awaitProcess(call));
    const scoped = try rt.spawnEval("(let ((x 4)) (eval '(+ x 3)))");
    try std.testing.expectEqual(Value.i64(7), try rt.awaitProcess(scoped));
}

test "host datum eval compiles one form and returns runtime error values" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    try std.testing.expectEqual(Value.i64(9), try rt.evalString(
        "((fn (evaluate) (evaluate '(+ 4 5))) eval)",
    ));
    const form = try rt.evalString("'(+ 1 2)");
    try std.testing.expectEqual(Value.i64(3), try rt.evalDatumWithContext(rt.context(), form, null));

    const unbound = try rt.evalString("'(missing-host-datum-binding 1)");
    const failure = try rt.evalDatumWithContext(rt.context(), unbound, null);
    try std.testing.expectEqual(b.type_error, failure.typ);
    try std.testing.expectEqual(error.Unbound, failure.errorCode());
}

test "host datum eval inherits root namespace and evaluates nested datums" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    _ = try rt.evalString("(def host-datum-root 4)");
    try std.testing.expectEqual(Value.i64(9), try rt.evalString(
        "(eval '(eval '(+ host-datum-root 5)))",
    ));
    try std.testing.expectError(error.Denied, rt.evalString("(eval '(sleep 1))"));
}

test "recursive host datum eval refuses before exhausting the native stack" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    _ = try rt.evalString("(def host-datum-loop '(eval host-datum-loop))");
    try std.testing.expectError(error.StackOverflow, rt.evalString("(eval host-datum-loop)"));
    try std.testing.expectEqual(Value.i64(5), try rt.evalString("(eval '(+ 2 3))"));
}

test "native callback eval rejects module suspension before publishing or replaying" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    const path = try tmp.write(rt.io, "blocked-eval-load.pt", "(export answer) (def answer 7)");
    defer std.testing.allocator.free(path);
    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\(def load-tries (hash-map :n 0))
        \\(def requested-module "{s}")
        \\(list (error-name (fst (eval '(map (list 1) (fn (x)
        \\  (map-set! load-tries :n (+ (map-get load-tries :n) 1))
        \\  (eval (list 'load requested-module)))))))
        \\  (eval '(+ 40 2))
        \\  (map-get load-tries :n))
    , .{path});
    defer std.testing.allocator.free(source);
    const caller = try rt.spawnEval(source);
    const result = try rt.awaitProcess(caller);
    try std.testing.expectEqual(b.type_cons, result.typ);
    const first = result.obj.toRef().deref([2]Value);
    try std.testing.expectEqual(b.type_string, first[0].typ);
    try std.testing.expectEqualStrings("Denied", std.mem.span(first[0].obj.toPtr([*:0]const u8)));
    try std.testing.expectEqual(b.type_cons, first[1].typ);
    const second = first[1].obj.toRef().deref([2]Value);
    try std.testing.expectEqual(Value.i64(42), second[0]);
    try std.testing.expectEqual(b.type_cons, second[1].typ);
    const third = second[1].obj.toRef().deref([2]Value);
    try std.testing.expectEqual(Value.i64(1), third[0]);

    rt.scheduler.mutex.lockUncancelable(rt.io);
    defer rt.scheduler.mutex.unlock(rt.io);
    try std.testing.expect(rt.modules.findLocked(path) == null);
}

test "native callback eval refuses uncached use-multi without an alias or module" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    const path = try tmp.write(rt.io, "blocked-eval-use.pt", "(export answer) (def answer 7)");
    defer std.testing.allocator.free(path);
    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\(def blocked-module-path "{s}")
        \\(list (error-name (fst (map (list 1) (fn (x)
        \\  (eval (list '@use-multi (list 'quote (list blocked-module-path 'blocked nil))))))))
        \\  (eval '(+ 40 2)))
    , .{path});
    defer std.testing.allocator.free(source);
    const caller = try rt.spawnEval(source);
    const result = try rt.awaitProcess(caller);
    try std.testing.expectEqual(b.type_cons, result.typ);
    const first = result.obj.toRef().deref([2]Value);
    try std.testing.expectEqual(b.type_string, first[0].typ);
    try std.testing.expectEqualStrings("Denied", std.mem.span(first[0].obj.toPtr([*:0]const u8)));
    try std.testing.expectEqual(b.type_cons, first[1].typ);
    const second = first[1].obj.toRef().deref([2]Value);
    try std.testing.expectEqual(Value.i64(42), second[0]);
    try std.testing.expectError(error.Unbound, rt.nsGet(rt.root_ns, try rt.store.getsym("blocked")));

    rt.scheduler.mutex.lockUncancelable(rt.io);
    defer rt.scheduler.mutex.unlock(rt.io);
    try std.testing.expect(rt.modules.findLocked(path) == null);
}

test "native callback eval reads a completed module without waiting" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    const path = try tmp.write(rt.io, "cached-eval-load.pt", "(export answer) (def answer 7)");
    defer std.testing.allocator.free(path);
    const load_source = try loadSrc(std.testing.allocator, path);
    defer std.testing.allocator.free(load_source);
    const module = try rt.spawnEval(load_source);
    const exports = try rt.awaitProcess(module);

    const escaped_path = try escapePath(std.testing.allocator, path);
    defer std.testing.allocator.free(escaped_path);
    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\(def cached-module-path "{s}")
        \\(list (fst (eval '(map (list 1) (fn (x) (eval (list 'load cached-module-path))))))
        \\      (eval '(+ 40 2)))
    , .{escaped_path});
    defer std.testing.allocator.free(source);
    const caller = try rt.spawnEval(source);
    const result = try rt.awaitProcess(caller);
    try std.testing.expectEqual(b.type_cons, result.typ);
    const first = result.obj.toRef().deref([2]Value);
    try std.testing.expectEqual(exports, first[0]);
    try std.testing.expectEqual(b.type_cons, first[1].typ);
    const second = first[1].obj.toRef().deref([2]Value);
    try std.testing.expectEqual(Value.i64(42), second[0]);
}

test "host datum eval uses explicit read-only module export namespace" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var tmp = try ModuleTmp.init(std.testing.allocator, rt.io);
    defer tmp.deinit(rt.io);

    const path = try tmp.write(rt.io, "eval-export.pt", "(export public) (def private 7) (def public 42)");
    defer std.testing.allocator.free(path);
    const source = try loadSrc(std.testing.allocator, path);
    defer std.testing.allocator.free(source);
    const module = try rt.spawnEval(source);
    const exports = try rt.awaitProcess(module);

    const visible = try rt.evalString("'public");
    try std.testing.expectEqual(Value.i64(42), try rt.evalDatumWithContext(rt.context(), visible, exports));
    const define = try rt.evalString("'(def public 9)");
    const denied = try rt.evalDatumWithContext(rt.context(), define, exports);
    try std.testing.expectEqual(b.type_error, denied.typ);
    try std.testing.expectEqual(error.Denied, denied.errorCode());
    try std.testing.expectEqual(Value.i64(42), try rt.nsGet(exports, try rt.store.getsym("public")));
}

test "host nested datum eval charges its caller depth and process budget" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const form = try rt.evalString("'(eval '(+ 2 3))");
    const Budget = EvalContext.Budget;

    const no_process_limits: Budget.Limits = .{ .work = 100_000, .processes = 0 };
    var no_process_budget = Budget.init(rt.io, 1, no_process_limits);
    var no_process_lease = try Budget.Lease.root(&no_process_budget, no_process_limits.work);
    var eval_context = rt.context().*;
    eval_context.lease = &no_process_lease;
    try std.testing.expectError(error.Exhausted, rt.evalDatumWithContext(&eval_context, form, null));
    try std.testing.expectEqual(Budget.Resource.processes, no_process_budget.report().?.resource);

    const depth_limits: Budget.Limits = .{ .work = 100_000, .depth = 16 };
    var depth_budget = Budget.init(rt.io, 2, depth_limits);
    var depth_lease = try Budget.Lease.root(&depth_budget, depth_limits.work);
    eval_context.lease = &depth_lease;
    // The outer datum and its eval intrinsic fit; the nested datum does not.
    eval_context.depth = 14;
    try std.testing.expectError(error.Exhausted, rt.evalDatumWithContext(&eval_context, form, null));
    try std.testing.expectEqual(Budget.Resource.depth, depth_budget.report().?.resource);
    try std.testing.expectEqual(Budget.Backend.regvm, depth_budget.report().?.backend);
}

test "runtime collection preserves a host-registered Value until release" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const cell = try rt.store.create([2]Value);
    cell.deref([2]Value).* = .{ Value.i64(7), .nil };
    {
        var root: ValueRoot = .{};
        try rt.registerValueRoot(&root, .cons(cell.toObject()));
        defer rt.unregisterValueRoot(&root) catch unreachable;
        try rt.collect();
        try std.testing.expectEqual(Value.i64(7), cell.deref([2]Value)[0]);
    }
    try rt.collect();
    try std.testing.expectError(error.InvalidRef, rt.store.derefChecked([2]Value, cell));
}

test "runtime collection rejects an active evaluation and succeeds after it exits" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    {
        const scope = rt.context().activate();
        defer scope.deinit();
        try std.testing.expectError(error.Busy, rt.collect());
    }
    try rt.collect();
}

test "intrinsic dependency cells remain valid across runtime collection" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const name = try rt.store.getsym("@f64.add");
    const dependency = try rt.readDependency(rt.root_ns, name);
    try rt.collect();
    try std.testing.expect(rt.validateDependency(rt.root_ns, name, dependency));
    try std.testing.expectEqual(Value.f64(5), try rt.apply(
        rt.root_ns,
        dependency.value,
        &.{ Value.f64(2), Value.f64(3) },
    ));
}

test "runtime collection retains namespace and scheduler process results" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();

    const proc = try rt.spawnEval("(def gc-kept (list 11 12)) gc-kept");
    const result = try rt.awaitProcess(proc);
    var root: ValueRoot = .{};
    try rt.registerValueRoot(&root, result);
    defer rt.unregisterValueRoot(&root) catch unreachable;
    try rt.collect();
    try std.testing.expectEqual(Value.i64(11), try rt.evalString("(fst gc-kept)"));
    try std.testing.expectEqual(Value.i64(12), try rt.evalString("(fst (rst gc-kept))"));
}

test "registered closure authorization preserves tagged identity in limited calls" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const registered = try rt.evalString("(fn () 9)");
    const ordinary = try rt.evalString("(fn () 10)");
    _ = try rt.intrinsics.publish(&.{.{
        .stable_name = "gc-metered-registered-closure",
        .invoke = .{ .closure = registered },
        .effects = .{ .io = true },
        .callbacks = .none,
        .resources = .{ .fixed = .{} },
        .suspension = .never,
    }});

    var limited: ContextTest = undefined;
    try limited.init(rt, .{ .work = 100_000 }, .{});
    try std.testing.expectError(error.Denied, limited.invoke(registered, &.{}));
    try std.testing.expectEqual(Value.i64(10), try limited.invoke(ordinary, &.{}));
    try rt.collect();
    try std.testing.expectEqual(Value.i64(9), try rt.apply(rt.root_ns, registered, &.{}));
}

test "compiled closure source remains inspectable across collection" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const closure = try rt.evalString("(fn (x) (+ x 1))");
    var root: ValueRoot = .{};
    try rt.registerValueRoot(&root, closure);
    defer rt.unregisterValueRoot(&root) catch unreachable;
    try rt.collect();

    const text = try rt.inspectSourceText(closure.obj.toRef().deref(Closure), 65536);
    try std.testing.expectEqualStrings(
        "(fn (x) (+ x 1))",
        std.mem.sliceTo(text.obj.toPtr([*]u8), 0),
    );
}

// ---------------------------------------------------------------------------
// Namespace cell memo (`CompilerOpts.namespace_lookup_cache`)
//
// A memo entry only ever records a cell the namespace already owns, so every
// test below has to show the same answer the uncached resolver gives once a
// name is warmed and then changed from every side that can change it.
// ---------------------------------------------------------------------------

/// A hash namespace allocated the way the runtime allocates its own, so GC
/// tracing covers it (and therefore its memo) exactly as in production.
fn memoTestHashNamespace(rt: *Runtime) anyerror!Value {
    const ref = try rt.store.create(Namespace);
    rt.store.store(Namespace, ref.deref(Namespace), HashMapNamespace.vtable);
    const map = try rt.static.create(HashMapNamespace);
    map.* = try HashMapNamespace.init(rt.static, rt.root_ns);
    ref.deref(Namespace).data = @ptrCast(map);
    const ns = Value.namespace(ref.toObject());
    rt.ownNamespace(ns);
    return ns;
}

/// A host native that rewrites a warmed root-namespace cell from inside an
/// evaluation, between the two reads that must disagree.
const MemoHostRewrite = struct {
    var runtime: *Runtime = undefined;
    var name: Sym = undefined;
    var calls: u32 = 0;

    fn invoke(_: *EvalContext, _: Value, _: Value, _: []const Value) Error!Value {
        calls += 1;
        try runtime.nsSet(runtime.root_ns, name, .i64(2));
        return .nil;
    }
};

test "cell memo follows a host native callback that rewrites a warmed binding" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const name = try rt.store.getsym("memo-native-target");
    try rt.nsBind(rt.root_ns, name, .i64(1));
    try std.testing.expectEqual(Value.i64(1), try rt.nsGet(rt.root_ns, name));

    MemoHostRewrite.runtime = rt;
    MemoHostRewrite.name = name;
    MemoHostRewrite.calls = 0;
    _ = try rt.intrinsics.publish(&.{.{
        .stable_name = "test.memo.rewrite",
        .invoke = skript.Primitive.Invocation.nativePtr(&MemoHostRewrite.invoke),
        .effects = .none,
        .callbacks = .none,
        .resources = .{ .fixed = .{} },
        .suspension = .never,
    }});
    _ = try rt.apply(rt.root_ns, Value.intrinsic(&MemoHostRewrite.invoke), &.{});
    try std.testing.expectEqual(@as(u32, 1), MemoHostRewrite.calls);

    try std.testing.expectEqual(Value.i64(2), try rt.nsGet(rt.root_ns, name));
    try std.testing.expectEqual(Value.i64(2), try rt.nsGet(rt.root_ns, name));
    // The uncached resolver must agree on the value the memo now reports.
    rt.compiler_opts.namespace_lookup_cache = false;
    try std.testing.expectEqual(Value.i64(2), try rt.nsGet(rt.root_ns, name));
    rt.compiler_opts.namespace_lookup_cache = true;
    try std.testing.expectEqual(Value.i64(2), try rt.nsGet(rt.root_ns, name));
}

test "cell memo follows a direct concrete namespace write and removal" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const name = try rt.store.getsym("memo-direct");
    try rt.nsBind(rt.root_ns, name, .i64(1));
    try std.testing.expectEqual(Value.i64(1), try rt.nsGet(rt.root_ns, name));

    // Bypass the Runtime API and drive the concrete namespace directly.
    const table = rt.root_ns.obj.toRef().deref(Namespace);
    try std.testing.expectEqual(HashMapNamespace.vtable.get, table.get);
    const map: *HashMapNamespace = @ptrCast(@alignCast(table.data));
    try map.set(name, .i64(2));
    try std.testing.expectEqual(Value.i64(2), try rt.nsGet(rt.root_ns, name));
    try map.bind(name, .i64(3));
    try std.testing.expectEqual(Value.i64(3), try rt.nsGet(rt.root_ns, name));
    _ = try map.unbind(name);
    try std.testing.expectError(error.Unbound, rt.nsGet(rt.root_ns, name));
}

test "parent-chain cell memo survives a nearer shadow and its removal" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const parent_ns = try memoTestHashNamespace(rt);
    const child_ref = try rt.store.create(Namespace);
    rt.store.store(Namespace, child_ref.deref(Namespace), SmallNamespace.vtable);
    const child = try rt.static.create(SmallNamespace);
    child.* = SmallNamespace{ .parent = parent_ns };
    child_ref.deref(Namespace).data = @ptrCast(child);
    const child_ns = Value.namespace(child_ref.toObject());
    rt.ownNamespace(child_ns);

    const name = try rt.store.getsym("memo-shadow");
    try rt.nsBind(parent_ns, name, .i64(10));
    try std.testing.expectEqual(Value.i64(10), try rt.nsGet(child_ns, name));
    // A nearer binding must win even though the parent's cell is memoized.
    try rt.nsBind(child_ns, name, .i64(20));
    try std.testing.expectEqual(Value.i64(20), try rt.nsGet(child_ns, name));
    // Removing the shadow falls back to the still-memoized parent cell.
    try rt.nsUnbind(child_ns, name);
    try std.testing.expectEqual(Value.i64(10), try rt.nsGet(child_ns, name));
    // Removing the parent cell retires the memoized name for good.
    try rt.nsUnbind(parent_ns, name);
    try std.testing.expectError(error.Unbound, rt.nsGet(child_ns, name));
    try std.testing.expectError(error.Unbound, rt.nsGet(parent_ns, name));
}

test "a rebound closure name is the one the next call runs" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const ns = try memoTestHashNamespace(rt);
    const name = try rt.store.getsym("memo-closure");
    const first = try rt.evalString("(fn () 1)");
    const second = try rt.evalString("(fn () 2)");
    try rt.nsBind(ns, name, first);
    try std.testing.expectEqual(
        Value.i64(1),
        try rt.apply(rt.root_ns, try rt.nsGet(ns, name), &.{}),
    );
    try rt.nsSet(ns, name, second);
    try std.testing.expectEqual(
        Value.i64(2),
        try rt.apply(rt.root_ns, try rt.nsGet(ns, name), &.{}),
    );
    try rt.nsUnbind(ns, name);
    try std.testing.expectError(error.Unbound, rt.nsGet(ns, name));
}

test "a memoized cell never outlives the value its namespace actually holds" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const ns = try memoTestHashNamespace(rt);
    var ns_root: ValueRoot = .{};
    try rt.registerValueRoot(&ns_root, ns);
    defer rt.unregisterValueRoot(&ns_root) catch unreachable;

    const name = try rt.store.getsym("memo-gc");
    const first = try rt.evalString("(list 1 2 3)");
    try rt.nsBind(ns, name, first);
    try std.testing.expectEqual(first, try rt.nsGet(ns, name));
    // A live entry mirrors a traced cell, so it survives collection intact.
    try rt.collect();
    try std.testing.expectEqual(first, try rt.nsGet(ns, name));

    const second = try rt.evalString("(list 4 5 6)");
    var second_root: ValueRoot = .{};
    try rt.registerValueRoot(&second_root, second);
    defer rt.unregisterValueRoot(&second_root) catch unreachable;
    try rt.nsSet(ns, name, second);
    // `first` is now unreachable; the replaced cell must not come back even
    // once the collector has actually reused its memory.
    try rt.collect();
    const current = try rt.nsGet(ns, name);
    try std.testing.expectEqual(second, current);
    try std.testing.expect(current.obj != first.obj);
}

test "an uninitialized cell still raises UninitializedBinding when memoized" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const ns = try memoTestHashNamespace(rt);
    const name = try rt.store.getsym("memo-uninit");
    try rt.nsBind(ns, name, uninitialized_binding_marker);
    try std.testing.expectError(error.UninitializedBinding, rt.nsGet(ns, name));
    try std.testing.expectError(error.UninitializedBinding, rt.nsGet(ns, name));
    // Initializing the cell must be visible on the very next read.
    try rt.nsSet(ns, name, .i64(4));
    try std.testing.expectEqual(Value.i64(4), try rt.nsGet(ns, name));
    try rt.nsSet(ns, name, uninitialized_binding_marker);
    try std.testing.expectError(error.UninitializedBinding, rt.nsGet(ns, name));
}

var memo_foreign_reads: u32 = 0;

/// A `get` that is NOT the built-in implementation, installed on a real
/// SmallNamespace so `contains` stays valid and the only foreign part is the
/// read itself.
fn memoForeignGet(_: *Runtime, table: *Namespace, _: Object, _: Sym) callconv(.c) Value {
    memo_foreign_reads += 1;
    const small: *SmallNamespace = @ptrCast(@alignCast(table.data));
    std.debug.assert(small.parent.typ == b.type_namespace);
    return .i64(7);
}

test "a foreign namespace vtable is still called on every lookup" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const name = try rt.store.getsym("memo-foreign");
    try rt.nsBind(rt.root_ns, name, .i64(1));
    // Warm the built-in root cell so a stale entry exists on a real namespace.
    try std.testing.expectEqual(Value.i64(1), try rt.nsGet(rt.root_ns, name));

    const ref = try rt.store.create(Namespace);
    rt.store.store(Namespace, ref.deref(Namespace), SmallNamespace.vtable);
    const state = try rt.static.create(SmallNamespace);
    state.* = SmallNamespace{ .parent = rt.root_ns };
    ref.deref(Namespace).data = @ptrCast(state);
    ref.deref(Namespace).get = memoForeignGet;
    const foreign = Value.namespace(ref.toObject());
    rt.ownNamespace(foreign);

    memo_foreign_reads = 0;
    try std.testing.expectEqual(Value.i64(7), try rt.nsGet(foreign, name));
    try std.testing.expectEqual(Value.i64(7), try rt.nsGet(foreign, name));
    try std.testing.expectEqual(@as(u32, 2), memo_foreign_reads);
}

var memo_reentry_lookups: u32 = 0;

fn memoReentryLookup(_: *anyopaque, _: *EvalContext, _: Value, _: Sym) Error!Value {
    memo_reentry_lookups += 1;
    return .i64(99);
}

fn memoReentryUnused(_: *anyopaque, _: *EvalContext, _: Value, _: Value, _: []const Value) Error!Value {
    unreachable;
}

fn memoReentryUnusedSource(_: *anyopaque, _: *EvalContext, _: []const u8) Error!Value {
    unreachable;
}

test "a reentrant lookup never reads the cell memo" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const name = try rt.store.getsym("memo-reentry");
    try rt.nsBind(rt.root_ns, name, .i64(1));
    try std.testing.expectEqual(Value.i64(1), try rt.nsGet(rt.root_ns, name));

    var hook_state: u8 = 0;
    memo_reentry_lookups = 0;
    rt.trusted_context.reentry = .{
        .state = @ptrCast(&hook_state),
        .apply = memoReentryUnused,
        .source = memoReentryUnusedSource,
        .lookup = memoReentryLookup,
    };
    try std.testing.expectEqual(Value.i64(99), try rt.nsGet(rt.root_ns, name));
    try std.testing.expectEqual(@as(u32, 1), memo_reentry_lookups);
    // The memo was neither read nor retired by the reentrant read.
    rt.trusted_context.reentry = null;
    try std.testing.expectEqual(Value.i64(1), try rt.nsGet(rt.root_ns, name));
}

test "restricted reads keep their permissions after a warmed unrestricted cell" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    _ = try rt.evalString("(def memo-restricted 1)");
    // Warm the cell through the unrestricted resolver, then compile the
    // reader that a pure-limited evaluation will run.
    try std.testing.expectEqual(Value.i64(1), try rt.evalString("memo-restricted"));
    const read_state = try rt.evalString("(fn () memo-restricted)");
    var limited: ContextTest = undefined;
    try limited.init(rt, .{ .work = 100000 }, .{ .pure = true });
    try std.testing.expectError(error.Denied, limited.invoke(read_state, &.{}));
    // Identical verdict with a cold cell: the memo changed no permission.
    rt.compiler_opts.namespace_lookup_cache = false;
    try std.testing.expectError(error.Denied, limited.invoke(read_state, &.{}));
    rt.compiler_opts.namespace_lookup_cache = true;
    try std.testing.expectEqual(Value.i64(1), try rt.evalString("memo-restricted"));
}

test "cell memo is value-equivalent to the uncached resolver on a self-recursive program" {
    for ([_]bool{ true, false }) |cache_on| {
        const rt = try Runtime.init(std.testing.allocator, std.testing.io);
        defer rt.deinit();
        rt.compiler_opts.namespace_lookup_cache = cache_on;
        _ = try rt.evalString(
            \\(def memo-outer 3)
            \\(defn (memo-step n acc)
            \\  (if (> n 0) (memo-step (- n 1) (+ acc memo-outer)) acc))
            \\(def memo-run (fn () (memo-step 4 0)))
        );
        try std.testing.expectEqual(Value.i64(12), try rt.evalString("(memo-run)"));
        // Rebinding a loop-invariant global must reach the next call.
        _ = try rt.evalString("(def memo-outer 5)");
        try std.testing.expectEqual(Value.i64(20), try rt.evalString("(memo-run)"));
        // Rebinding the entry closure must reach the next call too.
        _ = try rt.evalString("(def memo-run (fn () 0))");
        try std.testing.expectEqual(Value.i64(0), try rt.evalString("(memo-run)"));
    }
}
