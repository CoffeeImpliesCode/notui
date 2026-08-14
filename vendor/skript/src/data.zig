const std = @import("std");
const Allocator = std.mem.Allocator;
const Map = std.AutoHashMap;
const log = std.log.scoped(.Data);

const skript = @import("root.zig");
const SourceUnit = @import("SourceUnit.zig");
const Value = skript.Value;
const Object = skript.Object;
const Runtime = skript.Runtime;
const Sym = skript.Sym;
const ErrorValue = Value;
const Error = skript.Error;
const regvm = @import("regvm.zig");
const BoundCode = @import("code.zig");

/// Maximum content bytes accepted for string and bytevector map keys. This
/// also bounds content-equality probes made through `MapKey.Context` directly.
pub const map_key_bytes_max: usize = 1_048_576;

/// A map key uses the same type tag and payload as a scalar Value. String and
/// bytevector entries cache their content hash after bounded validation by
/// `intrinsics.map.keyOf`.
pub const MapKey = struct {
    /// The key value's runtime type tag.
    typ: u8,
    /// The scalar payload, interned symbol pointer, string pointer, or ByteVector reference.
    obj: Object,
    /// Content hash for string and bytevector keys; ignored for other tags.
    cached_hash: u64 = 0,
    /// Tagged references for cloned content; nil for non-owning lookup keys.
    /// Excluded from hash/eql so equivalent external keys find stored entries.
    owned_ref: skript.Store.Ref = .nil,
    owned_data_ref: skript.Store.Ref = .nil,

    /// Hash/eql context for `std.HashMap(MapKey, V, MapKey.Context, …)`.
    pub const Context = struct {
        pub fn hash(_: Context, key: MapKey) u64 {
            if (hasContentHash(key.typ)) return key.cached_hash;
            return std.hash.Wyhash.hash(key.typ, std.mem.asBytes(&key.obj));
        }

        pub fn eql(_: Context, a: MapKey, b: MapKey) bool {
            if (a.typ != b.typ) return false;
            if (a.typ == @as(u8, @intCast(@intFromEnum(skript.builtins.type_string)))) {
                return stringKeyEql(a.obj, b.obj);
            }
            if (a.typ == @as(u8, @intCast(@intFromEnum(skript.builtins.type_bytevector)))) {
                return byteVectorKeyEql(a.obj, b.obj);
            }
            return a.obj == b.obj;
        }
    };
};
/// Shared allocation types keep Store.Ref's checked type token consistent across modules.
pub const RuntimeMap = std.HashMap(
    MapKey,
    Value,
    MapKey.Context,
    std.hash_map.default_max_load_percentage,
);

/// Store-resident map descriptor. The hash table uses the runtime's accounted
/// host allocator and is released by the Store finalizer.
pub const MapHolder = struct {
    map: *RuntimeMap,
    allocator: Allocator,
};

pub fn traceMapHolder(
    data: *const anyopaque,
    extent: usize,
    visitor: *skript.Store.MarkVisitor,
) anyerror!void {
    if (extent != 1) return error.InvalidRef;
    const holder: *const MapHolder = @ptrCast(@alignCast(data));
    var entries = holder.map.iterator();
    while (entries.next()) |entry| {
        const key = entry.key_ptr.*;
        try visitor.visit(key.owned_ref);
        try visitor.visit(key.owned_data_ref);
        try visitor.visitValue(Value.init(@enumFromInt(key.typ), key.obj));
        try visitor.visitValue(entry.value_ptr.*);
    }
}

pub fn finalizeMapHolder(data: *anyopaque, extent: usize) void {
    std.debug.assert(extent == 1);
    const holder: *MapHolder = @ptrCast(@alignCast(data));
    holder.map.deinit();
    holder.allocator.destroy(holder.map);
}

fn hasContentHash(typ: u8) bool {
    return typ == @as(u8, @intCast(@intFromEnum(skript.builtins.type_string))) or
        typ == @as(u8, @intCast(@intFromEnum(skript.builtins.type_bytevector)));
}

fn stringKeyEql(a: Object, b: Object) bool {
    const a_bytes = a.toPtr([*:0]const u8);
    const b_bytes = b.toPtr([*:0]const u8);
    var index: usize = 0;
    while (index <= map_key_bytes_max) : (index += 1) {
        const a_byte = a_bytes[index];
        const b_byte = b_bytes[index];
        if (a_byte != b_byte) return false;
        if (a_byte == 0) return true;
    }
    return false;
}

fn byteVectorKeyEql(a: Object, b: Object) bool {
    const a_bytes = a.toRef().deref(Value.ByteVector).bytes;
    const b_bytes = b.toRef().deref(Value.ByteVector).bytes;
    if (a_bytes.len > map_key_bytes_max or b_bytes.len > map_key_bytes_max) return false;
    return std.mem.eql(u8, a_bytes, b_bytes);
}

/// Runtime type descriptor with meta-type, name, and method slots.
pub const Type = struct {
    /// This `Type`'s type (Ref)
    meta: Object,
    /// This `Type`'s name (Sym pointer)
    name: Object,
    show: Value = .nil,
    display: Value = .nil,
    apply: Value = .nil,
};

/// The source tree can be copied without its Reader side table. Keep the
/// location as immutable scalars and a string Value so imported errors retain
/// their original occurrence even after the source Runtime is destroyed.
pub const ErrorSite = struct {
    source: Value = .nil,
    idx: u32 = 0,
    line: u32 = 0,
    col: u32 = 0,
    file: Value = .nil,
};

/// A captured Skript call frame, innermost first in ErrorObj.frames.
pub const ErrorFrame = struct {
    site: ErrorSite = .{},
    name: ?Sym = null,
};

/// A rich error value retains its original failing source, named call frames,
/// and the raw payload of an uncaught user raise. A plain Value.err(e) keeps
/// the bare ErrorObject enum instead of a Store reference.
pub const ErrorObj = struct {
    err: skript.Error,
    site: ErrorSite = .{},
    raised: Value = .nil,
    frames: []const ErrorFrame = &.{},
};

/// Validation for generated code. The Runtime owns the context for the
/// closure's lifetime. Argument guards also run on VM and callback entries.
pub const ClosureGuard = struct {
    context: *const anyopaque,
    check: *const fn (*Runtime, *const anyopaque) Error!void,
    check_arguments: ?*const fn (*Runtime, *const anyopaque, []const Value) Error!void = null,
    trace: ?*const fn (*const anyopaque, *skript.Store.MarkVisitor) anyerror!void = null,
    /// Acquire one invocation's lease after all checks and exact arity pass.
    /// `release` must be set whenever `acquire` is set, and vice versa.
    acquire: ?*const fn (*Runtime, *const anyopaque) Error!void = null,
    /// Release one successful invocation lease exactly once.
    release: ?*const fn (*Runtime, *const anyopaque) void = null,
};

/// A function closure with captured namespace, params, body, and optional bytecode.
pub const Closure = struct {
    parent_ns: Value,
    arglist: []const Sym,
    /// The source tree of the closure's DEFINING FORM as reader data: the
    /// `(fn (ARGS...) BODY...)` form whose DFS preorder enumeration the
    /// `src` pseudoinstruction indexes. Every register-compiled closure
    /// carries it; host-built closures leave it .nil.
    source: Value = .nil,
    /// Stable provenance of the original defining-form occurrence.
    source_ref: SourceUnit.Ref = .{},
    /// Register VM bytecode for this function.
    ir: []regvm.Inst = &.{},
    /// Per-function constant table, indexed by the `load` opcode's kidx.
    constants: []const Value = &.{},
    /// Register count for frame allocation (nregs = max_used + 1).
    nregs: u8 = 0,
    /// Source closures return one value; generated internal closures can return slots.
    result_count: u8 = 1,
    /// Per-closure register zero-mask for the KNOWN-callee self-call path
    /// (self_call/tail_self_call): bit r set == R[r] must be nil on entry
    /// because the body may READ r before WRITING it. Computed once at
    /// compile time from the body's final reg_ir (see Runtime.computeZeroMask);
    /// bit 0 covers the r0 nil-set — when clear, the callee provably writes
    /// r0 before reading it, so the caller skips the nil-set too. All-ones is
    /// the safe default: host-built closures without the analysis
    /// keep the old zero-everything behavior. Registers >= 32 cannot be
    /// represented in a u32 mask and are always zeroed by the caller.
    // SAFETY: a cleared bit means "zeroing skipped" — if the analysis ever
    // mis-proved a read-before-write, the callee would read a stale caller
    // register. computeZeroMask is deliberately conservative (any uncertain
    // register keeps its bit); the parity corpus pins the equivalence.
    zero_mask: u32 = 0xFFFF_FFFF,
    /// Lifted free-variable names, in the same order as `captures`.
    /// Register-compiled closures use this metadata to preserve lexical
    /// identity when generated derivative closures are rebuilt.
    capture_syms: []const Sym = &.{},
    /// Lifted free variables, materialized at make_closure time from the
    /// ENCLOSING frame's registers and copied into this closure's own
    /// capture slots R[argc+1..] on .call. Empty for functions with no captures.
    captures: []const Value = &.{},
    /// VM-created closures keep up to two captures in the closure allocation.
    /// Other producers may still supply an independently owned capture slice.
    inline_captures: [2]Value = @splat(.nil),
    /// Runtime-owned validation for generated code and specialization assumptions.
    guard: ?*const ClosureGuard = null,
    /// The immutable semantic code owner and function identity. These fields
    /// are independent from captures and remain valid for generated closures.
    code: ?*const BoundCode.Code = null,
    function_id: BoundCode.FunctionId = .invalid,
    /// Assigned on first AD use; separates environments sharing one function.
    environment_id: u64 = 0,
    /// The shared per-program function table this closure's body was compiled
    /// against (FnTableEntry index space, read by nested make_closure). A
    /// normal `.call` inherits it from the caller's fiber, but a spawned
    /// process has no caller fiber, so spawnClosure reads it from here.
    fns: []const Runtime.FnTableEntry = &.{},
};

/// Multi-method dispatcher using argument type hash for dispatch.
pub const Method = struct {
    /// Zero denotes an unpublished method. Immutable snapshots retain identity.
    id: u64 = 0,
    /// Changes after each successful instance write or lock transition.
    revision: u64 = 1,
    resolved: Map(u64, Value),

    /// Core (builtin arithmetic/comparison) dispatch is non-overridable:
    /// once a method is locked, `instance` refuses any registration whose
    /// type spec is entirely builtin types. This makes the compiler's
    /// native arith fast path (add_i64, generic_* -> direct op) sound — the
    /// native op can never diverge from the method dispatch, because the
    /// dispatch cannot change.
    locked: bool = false,

    /// Hash over object handles only (ignoring types).
    pub inline fn ohash(args: []const Value) u64 {
        var hash = std.hash.Fnv1a_64.init();
        for (args) |a| hash.update(&std.mem.toBytes(a.obj));
        return hash.final();
    }

    /// Hash over types only (ignoring object values). Used for method dispatch.
    pub inline fn thash(args: []const Value) u64 {
        var hash = std.hash.Fnv1a_64.init();
        for (args) |a| hash.update(&std.mem.toBytes(a.typ));
        return hash.final();
    }

    /// Dispatch misses are expected errors. Log them at DEBUG, then return
    /// ArityMismatch without flooding test output.
    fn logMiss(rt: *Runtime, args: []const Value) Error {
        var buf: [256]u8 = undefined;
        var len: usize = 0;
        for (args, 0..) |a, i| {
            const tag: u64 = @intFromEnum(a.typ);
            const name = if (tag <= skript.builtins.type_last_idx)
                rt.predefined_types.items[@as(usize, @intCast(tag))].name.toPtr(Sym).*
            else
                a.typ.toRef().deref(skript.Type).name.toPtr(Sym).*;
            const separator_len: usize = if (i == 0) 0 else 2;
            if (separator_len > buf.len - len or name.len > buf.len - len - separator_len) {
                if (buf.len - len >= 3) {
                    @memcpy(buf[len..][0..3], "...");
                    len += 3;
                }
                break;
            }
            if (i != 0) {
                buf[len] = ',';
                buf[len + 1] = ' ';
                len += 2;
            }
            @memcpy(buf[len..][0..name.len], name);
            len += name.len;
        }
        log.debug("get: no instance for ({s})", .{buf[0..len]});
        return error.ArityMismatch;
    }

    pub fn get(self: *Method, rt: *Runtime, args: []const Value) Error!Value {
        const context = rt.context();
        try context.chargeWork(@as(u64, self.resolved.capacity()) + 1, 2, .native);
        try context.chargeWork(@intCast(args.len), 4, .native);
        const hash = thash(args);
        if (self.resolved.get(hash)) |f| return f;
        // Numeric coercion fallback (core-improvements 02 §1.2): mixed-type
        // numeric calls coerce to the promotion-lattice join (§1.3) and
        // re-lookup. Same-type calls always hit the first lookup, so the hot
        // path is untouched; non-numeric or empty arg lists have no join and
        // miss exactly as before. Every numeric arg coerces to `join` (the
        // join is ≥ each arg in the lattice), so the coerced type hash is n
        // copies of the join tag — values are never materialized: the caller
        // applies the resolved instance to the ORIGINAL args, and the
        // instance self-coerces (makeWrapper for int/float, coerceBuiltin
        // inside the complex ops).
        if (args.len == 0) return logMiss(rt, args);
        const join = skript.intrinsics.numericJoin(args) orelse return logMiss(rt, args);
        var all_join = true;
        for (args) |a| all_join = all_join and a.typ == join;
        // all_join: every arg already had the join type, so the re-lookup is
        // the already-missed first lookup — no instance exists at the join
        // (e.g. `<` on complex: join computes, ordering instance does not).
        if (all_join) return logMiss(rt, args);
        var join_hash = std.hash.Fnv1a_64.init();
        for (args) |_| join_hash.update(&std.mem.toBytes(join));
        return self.resolved.get(join_hash.final()) orelse logMiss(rt, args);
    }

    /// Register method `func` for the given type signature `spec`.
    pub fn put(self: *Method, spec: []const Value, func: Value) Error!void {
        for (spec) |s| std.debug.assert(s.isType());
        const hash = ohash(spec);
        if (self.revision == std.math.maxInt(u64)) return error.Unsupported;
        if (self.resolved.getPtr(hash)) |entry| {
            entry.* = func;
        } else {
            try self.resolved.ensureUnusedCapacity(1);
            self.resolved.putAssumeCapacityNoClobber(hash, func);
        }
        self.revision += 1;
    }
};

/// VTable for namespace operations. Each implementation publishes its own
/// `vtable` constant via `makeVtable`.
pub const Namespace = extern struct {
    data: *anyopaque,
    owner_context_id: u64 = 0,
    get: *const fn (rt: *Runtime, table: *Namespace, this: Object, binding: Sym) callconv(.c) ErrorValue,
    set: *const fn (rt: *Runtime, table: *Namespace, this: Object, binding: Sym, value: Value) callconv(.c) ErrorValue,
    bind: *const fn (rt: *Runtime, table: *Namespace, this: Object, binding: Sym, value: Value) callconv(.c) ErrorValue,
    unbind: *const fn (rt: *Runtime, table: *Namespace, this: Object, binding: Sym) callconv(.c) ErrorValue,
    contains: *const fn (rt: *Runtime, table: *Namespace, this: Object, binding: Sym) callconv(.c) bool,
    parent: *const fn (rt: *Runtime, table: *Namespace, this: Object) callconv(.c) Value,

    /// Generate a vtable for a concrete namespace type.
    fn makeVtable(comptime T: type) Namespace {
        return .{
            // SAFETY: set before use by the calling code that allocates the Namespace.
            .data = undefined,
            .get = struct {
                fn impl(rt: *Runtime, table: *Namespace, _: Object, binding: Sym) callconv(.c) ErrorValue {
                    const ns: *T = @ptrCast(@alignCast(table.data));
                    return ns.get(rt, binding) catch |e| .err(e);
                }
            }.impl,
            .set = struct {
                fn impl(_: *Runtime, table: *Namespace, _: Object, binding: Sym, value: Value) callconv(.c) ErrorValue {
                    const ns: *T = @ptrCast(@alignCast(table.data));
                    ns.set(binding, value) catch |e| return .err(e);
                    return .nil;
                }
            }.impl,
            .bind = struct {
                fn impl(_: *Runtime, table: *Namespace, _: Object, binding: Sym, value: Value) callconv(.c) ErrorValue {
                    const ns: *T = @ptrCast(@alignCast(table.data));
                    const Ret = @typeInfo(@TypeOf(T.bind)).@"fn".return_type.?;
                    // SmallNamespace.bind returns error{Full}. It is not in skript.Error
                    if (comptime @typeInfo(Ret) == .error_union and
                        @typeInfo(Ret).error_union.error_set == error{Full})
                    {
                        ns.bind(binding, value) catch return .err(error.Unimplemented);
                    } else {
                        ns.bind(binding, value) catch |e| return .err(e);
                    }
                    return .nil;
                }
            }.impl,
            .unbind = struct {
                fn impl(_: *Runtime, table: *Namespace, _: Object, binding: Sym) callconv(.c) ErrorValue {
                    const ns: *T = @ptrCast(@alignCast(table.data));
                    const Ret = @typeInfo(@TypeOf(T.unbind)).@"fn".return_type.?;
                    if (comptime Ret == void) {
                        ns.unbind(binding);
                    } else if (comptime @typeInfo(Ret) == .error_union) {
                        _ = ns.unbind(binding) catch |err| return .err(err);
                    } else {
                        _ = ns.unbind(binding);
                    }
                    return .nil;
                }
            }.impl,
            .contains = struct {
                fn impl(_: *Runtime, table: *Namespace, _: Object, binding: Sym) callconv(.c) bool {
                    const ns: *T = @ptrCast(@alignCast(table.data));
                    if (comptime @hasDecl(T, "contains")) {
                        return ns.contains(binding);
                    } else {
                        return ns.bindings.contains(binding);
                    }
                }
            }.impl,
            .parent = struct {
                fn impl(_: *Runtime, table: *Namespace, _: Object) callconv(.c) Value {
                    const ns: *T = @ptrCast(@alignCast(table.data));
                    return ns.parent;
                }
            }.impl,
        };
    }
};

/// Bounded, allocation-free memo of cells a single builtin namespace owns.
///
/// Invariants (the whole soundness argument lives here):
///
///  * An entry is written ONLY from a successful own-cell read of that exact
///    key (`HashMapNamespace.bindings.get` / the `SmallNamespace` SIMD
///    scan), so a live entry always names a cell the namespace currently
///    owns and the value it stores is the value the resolver would read now.
///    Entries for names that resolve through an import edge, through a
///    parent, or through an `@`-intrinsic are never written: the memo only
///    ever describes the FIRST level of a lookup, so a memo hit is
///    byte-for-byte the answer the uncached walk produces at that level and
///    the walk stops exactly where it did before.
///  * Every mutation that can change or remove an existing cell drops that
///    key's entry (`set`, the update path of `bind`, `unbind`). Inserting a
///    NEW key needs no drop: it cannot alter another key's cell, and a live
///    entry already proves the key exists, so no `putAssumeCapacityNoClobber`
///    can target it. Bulk writers that only insert therefore need no hook.
///  * Because a live entry always mirrors a currently reachable cell, its
///    `Value` is reachable from the traced `bindings` map / `values` array and
///    its `Sym` from the Store symbol arena, which is never swept. The memo
///    therefore holds no untraced Store edge and needs no GC hook: there is no
///    state that can outlive a collection.
///  * Storage is a fixed array inside the namespace. No lookup allocates, and
///    a colliding key simply overwrites the slot.
///  * Direct-mapped on the interned symbol address, so two distinct names
///    can share a slot; the `sym` equality check rejects the collision.
pub fn BindingMemo(comptime count: usize) type {
    comptime std.debug.assert(count > 0 and std.math.isPowerOfTwo(count));
    return struct {
        const Entry = struct {
            sym: Sym = undefined,
            value: Value = .{},
            live: bool = false,
        };
        entries: [count]Entry = @splat(.{}),

        /// `Sym` is `*[]const u8`, so the pointer is 8-byte aligned; drop the
        /// low bits to spread interned names over the slots.
        inline fn slotOf(binding: Sym) usize {
            return (@intFromPtr(binding) >> 3) & (count - 1);
        }

        /// The cached cell for `binding`, or null when this name is not
        /// memoized. A hit is exactly `owner owns binding with this value`.
        pub inline fn peek(self: *const @This(), binding: Sym) ?Value {
            const entry = self.entries[slotOf(binding)];
            if (!entry.live or entry.sym != binding) return null;
            return entry.value;
        }

        pub inline fn put(self: *@This(), binding: Sym, value: Value) void {
            self.entries[slotOf(binding)] = .{ .sym = binding, .value = value, .live = true };
        }

        /// Drop the entry for `binding`. Other names keep theirs: they
        /// resolve in this namespace alone and this write cannot move them.
        pub inline fn forget(self: *@This(), binding: Sym) void {
            const index = slotOf(binding);
            if (self.entries[index].live and self.entries[index].sym == binding) {
                self.entries[index].live = false;
            }
        }

        pub fn clear(self: *@This()) void {
            for (&self.entries) |*entry| entry.live = false;
        }
    };
}

/// Fixed-capacity namespace (16 entries) using SIMD-accelerated lookups.
/// Beyond `size` bindings, producers fall back to a HashMapNamespace (the
/// cap-removal tranche): bindClosureArgs, the regvm/stack `.ns_push` arms and
/// evalNode .Let all thread the binding count and allocate the hash-map kind
/// when it exceeds `size`. The vtable's error{Full} → Unimplemented mapping
/// stays as a safety net.
pub const SmallNamespace = struct {
    pub const size = 16;
    pub const vtable: Namespace = Namespace.makeVtable(SmallNamespace);
    bindings: @Vector(size, u64) = @splat(0),
    values: [size]Value = @splat(.{}),
    parent: Value = .nil,
    /// Own-cell memo, consulted by the register-VM symbol read. Two slots
    /// cover the hot shape (the closure's own name plus one captured let)
    /// without growing every pushed namespace for a rare third key.
    memo: BindingMemo(2) = .{},

    pub inline fn get(self: *SmallNamespace, rt: *Runtime, binding: Sym) error{Unbound}!Value {
        // @-names resolve ONLY to intrinsics/constants, never a local binding
        // or the parent — mirror HashMapNamespace.get exactly, so a let-bound
        // or def'd @name behaves identically across the two namespace kinds
        // (a SmallNamespace that resolved a local @name would diverge from a
        // HashMapNamespace, which returns Unbound for any @name not in the
        // intrinsic/constant tables).
        if (std.mem.startsWith(u8, binding.*, "@")) {
            const span = binding.*[1..];
            if (rt.intrinsics.get(span)) |v| return v;
            if (rt.constants.get(span)) |v| return v;
            return error.Unbound;
        }
        const idx = std.simd.firstIndexOfValue(self.bindings, @intFromPtr(binding)) orelse {
            if (self.parent.unwrapNil()) |parent| {
                return rt.nsGet(parent, binding) catch return error.Unbound;
            } else return error.Unbound;
        };
        return self.values[idx];
    }

    pub inline fn set(self: *SmallNamespace, binding: Sym, value: Value) error{Unbound}!void {
        const idx = std.simd.firstIndexOfValue(self.bindings, @intFromPtr(binding)) orelse return error.Unbound;
        self.memo.forget(binding);
        self.values[idx] = value;
    }

    /// Add a new binding or update existing. Fails with Full if table is full.
    pub inline fn bind(self: *SmallNamespace, binding: Sym, value: Value) error{Full}!void {
        self.set(binding, value) catch {
            const idx = std.simd.firstIndexOfValue(self.bindings, 0) orelse return error.Full;
            var span: [size]u64 = self.bindings;
            span[idx] = @intFromPtr(binding);
            self.bindings = span;
            self.values[idx] = value;
        };
    }

    pub inline fn unbind(self: *SmallNamespace, binding: Sym) void {
        // firstIndexOfValue returns the fitting index type for the lane count
        // (u3 at size 8, u4 at size 16) — infer it, never hard-code a width.
        const idx = std.simd.firstIndexOfValue(self.bindings, @intFromPtr(binding)) orelse return;
        self.memo.forget(binding);
        var span: [size]u64 = self.bindings;
        span[idx] = 0;
        self.bindings = span;
        self.values[idx] = .{};
    }

    /// Memoized own-cell read. A hit is exactly the SIMD scan's answer; see
    /// `BindingMemo` for why that equivalence holds.
    pub inline fn peekCell(self: *const SmallNamespace, binding: Sym) ?Value {
        return self.memo.peek(binding);
    }

    /// Record that this namespace owns `binding` with `value`. Call only
    /// with the result of a successful SIMD scan of that same key.
    pub inline fn rememberCell(self: *SmallNamespace, binding: Sym, value: Value) void {
        self.memo.put(binding, value);
    }

    /// Check if `binding` exists in this namespace (not checking parent).
    pub inline fn contains(self: *SmallNamespace, binding: Sym) bool {
        return if (std.simd.firstIndexOfValue(self.bindings, @intFromPtr(binding))) |_| true else false;
    }
};

/// Hash-map-backed namespace. Supports arbitrary capacity and `@`-prefixed
/// intrinsic lookup. Used for the root namespace and user-created namespaces.
pub const HashMapNamespace = struct {
    const SMap = std.AutoHashMap(Sym, Value);
    pub const vtable: Namespace = Namespace.makeVtable(HashMapNamespace);
    bindings: *SMap,
    imports: std.AutoHashMapUnmanaged(Sym, ExportNamespace.Source) = .empty,
    parent: Value,
    /// Own-cell memo, consulted by the register-VM symbol read. Four slots
    /// cover the root-namespace hot set (an operator plus the loop-invariant
    /// globals a body keeps re-reading) without touching the map layout.
    memo: BindingMemo(4) = .{},

    /// Create a HashMapNamespace with an empty map and given parent.
    pub fn init(alloc: Allocator, parent: Value) !HashMapNamespace {
        const map = try alloc.create(SMap);
        map.* = .init(alloc);
        return .{
            .bindings = map,
            .parent = parent,
        };
    }

    /// Free the hashmap and destroy self.
    pub fn deinit(self: *HashMapNamespace, alloc: Allocator) void {
        self.bindings.deinit();
        alloc.destroy(self.bindings);
        self.memo.clear();
        self.imports.deinit(alloc);
        self.* = undefined;
    }

    /// Look up `binding`. Checks `@name` intrinsics/constants, then local bindings,
    /// then falls back to parent.
    pub inline fn get(self: *HashMapNamespace, rt: *Runtime, binding: Sym) Error!Value {
        if (std.mem.startsWith(u8, binding.*, "@")) {
            const span = binding.*[1..];
            if (rt.intrinsics.get(span)) |v| return v;
            if (rt.constants.get(span)) |v| return v;
            return error.Unbound;
        }
        if (self.bindings.get(binding)) |v| return v;
        if (self.imports.get(binding)) |source| return source.read(rt);
        if (self.parent.typ == skript.builtins.type_namespace) {
            const ns_ptr = self.parent.obj.toRef().deref(Namespace);
            return ns_ptr.get(rt, ns_ptr, self.parent.obj, binding);
        }
        return error.Unbound;
    }

    pub fn set(self: *HashMapNamespace, binding: Sym, val: Value) Error!void {
        if (self.imports.contains(binding)) return error.Denied;
        const bdg = self.bindings.getPtr(binding);
        if (bdg) |v| {
            self.memo.forget(binding);
            v.* = val;
        } else return error.Unbound;
    }

    /// Add or update a binding.
    pub fn bind(self: *HashMapNamespace, binding: Sym, val: Value) Error!void {
        if (self.imports.contains(binding)) return error.Denied;
        if (self.bindings.getPtr(binding)) |entry| {
            self.memo.forget(binding);
            entry.* = val;
            return;
        }
        try self.bindings.ensureUnusedCapacity(1);
        self.bindings.putAssumeCapacityNoClobber(binding, val);
    }

    /// Remove a binding and return its previous value.
    pub fn unbind(self: *HashMapNamespace, binding: Sym) Error!?Value {
        if (self.imports.contains(binding)) return error.Denied;
        const removed = self.bindings.fetchRemove(binding) orelse return null;
        self.memo.forget(binding);
        return removed.value;
    }

    pub fn contains(self: *HashMapNamespace, binding: Sym) bool {
        return self.bindings.contains(binding) or self.imports.contains(binding);
    }

    /// Memoized own-cell read. A hit is exactly `bindings.get`'s answer; see
    /// `BindingMemo` for why that equivalence holds.
    pub inline fn peekCell(self: *const HashMapNamespace, binding: Sym) ?Value {
        return self.memo.peek(binding);
    }

    /// Record that this namespace owns `binding` with `value`. Call only
    /// with the result of a successful `bindings.get` of that same key.
    pub inline fn rememberCell(self: *HashMapNamespace, binding: Sym, value: Value) void {
        self.memo.put(binding, value);
    }
};

/// Public module namespace: external names map to live source cells. Its
/// parent is nil, so neither private names nor prelude names leak.
pub const ExportNamespace = struct {
    pub const vtable: Namespace = Namespace.makeVtable(ExportNamespace);

    pub const Source = struct {
        namespace: Value,
        name: Sym,

        /// Resolve import/reexport edges with a fixed limit before reading a
        /// concrete cell. Direct host reads cannot recurse on a malformed cycle.
        pub fn read(self: Source, rt: *Runtime) Error!Value {
            var current = self;
            for (0..1024) |_| {
                if (current.namespace.typ != skript.builtins.type_namespace) return error.InvalidCode;
                const table = current.namespace.obj.toRef().deref(Namespace);
                if (table.get == ExportNamespace.vtable.get) {
                    const view: *const ExportNamespace = @ptrCast(@alignCast(table.data));
                    current = view.names.get(current.name) orelse return error.Unbound;
                } else if (table.get == HashMapNamespace.vtable.get) {
                    const map: *const HashMapNamespace = @ptrCast(@alignCast(table.data));
                    if (map.bindings.contains(current.name)) {
                        return rt.nsGet(current.namespace, current.name);
                    }
                    current = map.imports.get(current.name) orelse return error.Unbound;
                } else return error.InvalidCode;
            }
            return error.Unsupported;
        }
    };

    names: std.AutoHashMap(Sym, Source),
    private: Value,
    parent: Value = .nil,

    pub fn init(allocator: Allocator, private: Value) ExportNamespace {
        return .{ .names = .init(allocator), .private = private };
    }

    pub fn contains(self: *ExportNamespace, binding: Sym) bool {
        return self.names.contains(binding);
    }

    pub fn get(self: *ExportNamespace, rt: *Runtime, binding: Sym) Error!Value {
        const source = self.names.get(binding) orelse return error.Unbound;
        return source.read(rt);
    }

    pub fn set(_: *ExportNamespace, _: Sym, _: Value) Error!void {
        return error.Denied;
    }

    pub fn bind(_: *ExportNamespace, _: Sym, _: Value) Error!void {
        return error.Denied;
    }

    pub fn unbind(_: *ExportNamespace, _: Sym) Error!void {
        return error.Denied;
    }
};

test "hash namespace unbind removes only the requested binding and returns its value" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    var namespace = try HashMapNamespace.init(std.testing.allocator, .nil);
    defer namespace.deinit(std.testing.allocator);
    const removed = try runtime.store.getsym("removed");
    const retained = try runtime.store.getsym("retained");
    try namespace.bind(removed, .i64(17));
    try namespace.bind(retained, .i64(23));

    try std.testing.expectEqual(@as(?Value, .i64(17)), try namespace.unbind(removed));
    try std.testing.expectError(error.Unbound, namespace.get(runtime, removed));
    try std.testing.expectEqual(Value.i64(23), try namespace.get(runtime, retained));
    try std.testing.expectEqual(@as(?Value, null), try namespace.unbind(removed));
}

test "Method.get reports a long missing signature without writing past its diagnostic buffer" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    var method: Method = .{ .resolved = .init(runtime.static) };
    const args = [_]Value{.i64(7)} ** 300;
    try std.testing.expectError(error.ArityMismatch, method.get(runtime, &args));
}

test "export aliases and selected imports read the live source and reject writes" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const source = try runtime.store.getsym("source");
    const public = try runtime.store.getsym("public");
    const local = try runtime.store.getsym("local");
    try runtime.nsBind(runtime.root_ns, source, .i64(7));

    var exported = ExportNamespace.init(std.testing.allocator, runtime.root_ns);
    defer exported.names.deinit();
    try exported.names.put(public, .{ .namespace = runtime.root_ns, .name = source });
    try std.testing.expect(exported.contains(public));
    try std.testing.expect(!exported.contains(source));
    try std.testing.expectEqual(Value.i64(7), try exported.get(runtime, public));

    var namespace = try HashMapNamespace.init(std.testing.allocator, .nil);
    defer namespace.deinit(std.testing.allocator);
    try namespace.imports.put(std.testing.allocator, local, .{
        .namespace = runtime.root_ns,
        .name = source,
    });
    try std.testing.expect(namespace.contains(local));
    try std.testing.expectEqual(Value.i64(7), try namespace.get(runtime, local));
    try runtime.nsSet(runtime.root_ns, source, .i64(8));
    try std.testing.expectEqual(Value.i64(8), try exported.get(runtime, public));
    try std.testing.expectEqual(Value.i64(8), try namespace.get(runtime, local));
    try std.testing.expectError(error.Denied, namespace.set(local, .i64(9)));
    try std.testing.expectError(error.Denied, namespace.bind(local, .i64(9)));
    try std.testing.expectError(error.Denied, namespace.unbind(local));
    try std.testing.expectError(error.Denied, exported.bind(public, .i64(9)));
}

test "bind updates an existing hash-map cell instead of inserting a duplicate" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const name = try runtime.store.getsym("rebind-existing");

    var namespace = try HashMapNamespace.init(std.testing.allocator, .nil);
    defer namespace.deinit(std.testing.allocator);
    try namespace.bind(name, .i64(1));
    try namespace.bind(name, .i64(2));
    // A second bind of a live name is an update: one entry, the new value.
    try std.testing.expectEqual(@as(usize, 1), namespace.bindings.count());
    try std.testing.expectEqual(Value.i64(2), try namespace.get(runtime, name));
    // An unbind must remove that entry, not one of two copies.
    try std.testing.expectEqual(Value.i64(2), (try namespace.unbind(name)).?);
    try std.testing.expect(!namespace.contains(name));
}

test "bind records the lane of a new small-namespace key" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const name = try runtime.store.getsym("small-bind");
    const other = try runtime.store.getsym("small-bind-other");

    var namespace = SmallNamespace{ .parent = runtime.root_ns };
    try namespace.bind(name, .i64(7));
    try std.testing.expect(namespace.contains(name));
    try std.testing.expectEqual(Value.i64(7), try namespace.get(runtime, name));

    try namespace.bind(other, .i64(8));
    try std.testing.expectEqual(Value.i64(7), try namespace.get(runtime, name));
    try std.testing.expectEqual(Value.i64(8), try namespace.get(runtime, other));

    // Both keys must be individually addressable, and rebinding one must not
    // disturb the other.
    try namespace.bind(name, .i64(9));
    try std.testing.expectEqual(Value.i64(9), try namespace.get(runtime, name));
    try std.testing.expectEqual(Value.i64(8), try namespace.get(runtime, other));
}

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
        std.testing.refAllDecls(Method);
        std.testing.refAllDecls(Namespace);
        std.testing.refAllDecls(SmallNamespace);
        std.testing.refAllDecls(HashMapNamespace);
    }
}

test "Method.get: numeric coercion fallback" {
    var rt = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    const expect = std.testing.expect;
    const expectError = std.testing.expectError;
    const b = skript.builtins;
    const i64_t = Value.typeValue(b.type_i64);
    const f64_t = Value.typeValue(b.type_f64);
    const c32_t = Value.typeValue(b.type_c32);

    var m: Method = .{ .resolved = .init(rt.static) };
    try m.put(&.{ i64_t, i64_t }, Value.intrinsic(&skript.intrinsics.int.i64_add));
    try m.put(&.{ f64_t, f64_t }, Value.intrinsic(&skript.intrinsics.float.f64_add));
    try m.put(&.{ c32_t, c32_t }, Value.intrinsic(&skript.intrinsics.complex.c32_add));

    // Same-type calls hit the first lookup unchanged.
    try expect(std.meta.eql(Value.intrinsic(&skript.intrinsics.int.i64_add), try m.get(rt, &.{ .i64(1), .i64(2) })));
    // Mixed i64+f64 joins to f64 and resolves the @f64.add instance.
    try expect(std.meta.eql(
        Value.intrinsic(&skript.intrinsics.float.f64_add),
        try m.get(rt, &.{ .i64(1), .f64(2.0) }),
    ));
    // Mixed i64+c32 joins to c32 and resolves the @c32.add instance.
    try expect(std.meta.eql(
        Value.intrinsic(&skript.intrinsics.complex.c32_add),
        try m.get(rt, &.{ .i64(1), .c32(.{ 2, 3 }) }),
    ));

    // No join (non-numeric operand) → unchanged miss.
    try expectError(error.ArityMismatch, m.get(rt, &.{ .i64(1), .true }));
    // Empty arg list → miss.
    try expectError(error.ArityMismatch, m.get(rt, &.{}));
    // all_join guard: every arg already at the join, no instance exists
    // (here: (f64 f64) DOES exist — so use a method with no instances).
    var empty: Method = .{ .resolved = .init(rt.static) };
    try expectError(error.ArityMismatch, empty.get(rt, &.{ .f64(1.0), .f64(2.0) }));
    // 3-ary: no instance at any join (the numeric ops are 2-ary) → miss.
    try expectError(error.ArityMismatch, m.get(rt, &.{ .i64(1), .f64(2.0), .i64(3) }));
    // Mixed signedness same-width ints join to the next-wider signed:
    // (i8, u8) → i16. Register an i16 instance to observe the join.
    var m16: Method = .{ .resolved = .init(rt.static) };
    const i16_t = Value.typeValue(b.type_i16);
    try m16.put(&.{ i16_t, i16_t }, Value.intrinsic(&skript.intrinsics.int.i16_add));
    try expect(std.meta.eql(
        Value.intrinsic(&skript.intrinsics.int.i16_add),
        try m16.get(rt, &.{ .i8(100), .u8(200) }),
    ));
}
