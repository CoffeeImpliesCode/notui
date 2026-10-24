const std = @import("std");
const skript = @import("root.zig");
const Code = @import("code.zig");
const Bind = @import("bind.zig");
const Heap = @import("EvalHeap.zig");
const Context = @import("EvalContext.zig");
const Primitive = @import("primitive.zig");
const Value = skript.Value;
const Object = skript.Object;
const Error = skript.Error;
const b = skript.builtins;
pub const Model = @import("EvalModel.zig");
const Domain = @import("eval_domain.zig");

pub const Unknown = Domain.Unknown;

pub const Slot = Domain.Slot;

pub const Path = struct {
    parent: ?u32,
    condition: Slot,
    selected: bool,
};

pub const Invocation = union(enum) {
    primitive: struct { id: Primitive.PrimitiveId, revision: u64 },
    call: *const Slot,
};

pub const Effect = struct {
    invocation: Invocation,
    effects: Primitive.EffectSet,
    arguments: []const Slot,
    path: ?u32,
    model: ?Context.Version,
    result: Slot,
};

const Layout = struct {
    code: *const Code.Code,
    slots: []u32,
    counts: []u32,
};

const Namespace = struct {
    value: Value,
    parent: ?usize,
    source: Value,
    ready: bool = false,
};

const BindingKey = struct {
    namespace: usize,
    symbol: Code.Symbol,
};
/// Provenance for evaluator-cached source imports. Model hooks may observe
/// values they imported themselves but never outer evaluation state.
const SourceCacheEntry = struct {
    hook_imported: bool = false,
};
const Closure = struct {
    value: Value,
    code: *const Code.Code,
    function: Code.FunctionId,
    namespace: usize,
    captures: []const Slot,
};

const Handler = struct {
    id: Code.HandlerId,
    namespace: usize,
};

const Frame = struct {
    // SAFETY: push assigns closure before any frame operation reads it.
    closure: Closure = undefined,
    // SAFETY: push assigns layout before any frame operation reads it.
    layout: *const Layout = undefined,
    block: Code.BlockId = .invalid,
    cursor: usize = 0,
    namespace: usize = 0,
    destination: Code.ValueId = .invalid,
    result_count: u8 = 1,
    slots: std.ArrayList(Slot) = .empty,
    transfer: std.ArrayList(Slot) = .empty,
    handlers: std.ArrayList(Handler) = .empty,

    fn get(self: *const Frame, id: Code.ValueId) Error!Slot {
        const raw = @backingInt(id);
        if (raw >= self.layout.code.values.len) return error.InvalidCode;
        if (self.layout.code.values[raw] != self.closure.function) return error.InvalidCode;
        const value = self.slots.items[self.layout.slots[raw]];
        if (value == .empty) return error.InvalidCode;
        return value;
    }

    fn set(self: *Frame, id: Code.ValueId, value: Slot) Error!void {
        const raw = @backingInt(id);
        if (raw >= self.layout.code.values.len) return error.InvalidCode;
        if (self.layout.code.values[raw] != self.closure.function) return error.InvalidCode;
        self.slots.items[self.layout.slots[raw]] = value;
    }
};

const Failure = struct {
    signal: Error,
    payload: Slot,
};

const Snapshot = struct {
    frames: std.ArrayList(Frame),
    active_frames: usize,
    bindings: std.AutoHashMapUnmanaged(BindingKey, Slot),
    source_cache: std.AutoHashMapUnmanaged(BindingKey, SourceCacheEntry),
    path: ?u32,
    speculating: bool,
    state_unknown: bool,
    failure: ?Failure,
};

pub const Evaluation = struct {
    session: *Session,
    result: Slot,

    pub fn deinit(self: Evaluation) void {
        self.session.destroy();
    }

    pub fn effects(self: Evaluation) []const Effect {
        return self.session.effects.items;
    }

    pub fn paths(self: Evaluation) []const Path {
        return self.session.paths.items;
    }

    pub fn hasDeferred(self: Evaluation) bool {
        return self.session.has_deferred;
    }

    pub fn exportValue(self: Evaluation) Error!Value {
        if (self.hasDeferred()) return error.Unsupported;
        return self.exportData(try self.result.requireKnown());
    }

    pub fn exportData(self: Evaluation, value: Value) Error!Value {
        if (value.typ == b.type_closure or value.typ == b.type_namespace) return error.Unsupported;
        return self.session.heap.exportValue(self.session.parent, value);
    }
};

pub fn apply(context: *Context, namespace: Value, callable: Value, args: []const Value) Error!Value {
    const result = try evaluate(context, namespace, callable, args);
    defer result.deinit();
    return result.exportValue();
}

pub fn evaluate(context: *Context, namespace: Value, callable: Value, args: []const Value) Error!Evaluation {
    return evaluateWithModel(context, namespace, callable, args, null);
}

pub fn evaluateWithModel(
    context: *Context,
    namespace: Value,
    callable: Value,
    args: []const Value,
    model: ?Model,
) Error!Evaluation {
    if (model) |selected| {
        try selected.validate(context);
    } else if (context.model != null) return error.Denied;
    const session = try Session.create(context);
    errdefer session.destroy();
    const scope = session.context.activate();
    defer scope.deinit();
    if (model) |selected| try session.setModel(selected);
    const target = try session.importValue(callable);
    const imported = try session.arena.allocator().alloc(Slot, args.len);
    for (args, imported) |argument, *out| out.* = try session.lift(try session.importValue(argument));
    const ns = try session.importNamespace(namespace);
    const result = session.call(ns, target, imported) catch |err| {
        try context.check();
        return err;
    };
    return .{ .session = session, .result = result };
}

pub fn evalString(context: *Context, source: []const u8) Error!Value {
    if (context.model != null) return error.Denied;
    const session = try Session.create(context);
    defer session.destroy();
    const scope = session.context.activate();
    defer scope.deinit();
    const namespace = try session.importNamespace(context.runtime.root_ns);
    const result = try session.source(namespace, source);
    const evaluation: Evaluation = .{ .session = session, .result = result };
    return (try evaluation.exportValue()).unwrapError();
}

const Session = struct {
    parent: *Context,
    heap: *Heap,
    context: Context,
    arena: std.heap.ArenaAllocator,
    layouts: std.AutoHashMapUnmanaged(*const Code.Code, *Layout) = .empty,
    code_owners: std.ArrayListUnmanaged(*const anyopaque) = .empty,
    namespaces: std.ArrayList(Namespace) = .empty,
    namespace_sources: std.AutoHashMapUnmanaged(Object, usize) = .empty,
    namespace_handles: std.AutoHashMapUnmanaged(Object, usize) = .empty,
    closures: std.AutoHashMapUnmanaged(Object, Closure) = .empty,
    registered_primitives: std.AutoHashMapUnmanaged(Object, Primitive.PrimitiveId) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    active_frames: usize = 0,
    effects: std.ArrayList(Effect) = .empty,
    has_deferred: bool = false,
    paths: std.ArrayList(Path) = .empty,
    bindings: std.AutoHashMapUnmanaged(BindingKey, Slot) = .empty,
    source_cache: std.AutoHashMapUnmanaged(BindingKey, SourceCacheEntry) = .empty,
    path: ?u32 = null,
    speculating: bool = false,
    state_unknown: bool = false,
    fork_depth: u32 = 0,
    next_unknown: u32 = 0,
    model: ?Model = null,
    model_active: bool = false,
    model_scope_start: usize = 0,
    suppress_primitive_model: bool = false,
    unknown_callback: bool = false,
    pending_failure: ?Failure = null,

    fn create(parent: *Context) Error!*Session {
        try parent.check();
        if (parent.mode == .concrete or parent.lease == null) return error.Denied;
        const self = parent.scratch.create(Session) catch |err| {
            try parent.check();
            return err;
        };
        errdefer parent.scratch.destroy(self);
        const heap = Heap.init(parent) catch |err| switch (@as(anyerror, err)) {
            error.AccessDenied, error.PermissionDenied => return error.Denied,
            error.Unexpected,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.LockedMemoryLimitExceeded,
            error.MemoryMappingNotSupported,
            error.MappingAlreadyExists,
            => return error.Unsupported,
            error.EmptyName,
            error.MissingImplementation,
            error.DuplicateName,
            error.DuplicatePrimitiveId,
            error.InvalidPrimitiveId,
            error.InvalidEffects,
            error.InvalidRevision,
            error.VersionOverflow,
            error.IdOverflow,
            => return error.InvalidCode,
            else => |remaining| return @errorCast(remaining),
        };
        errdefer heap.deinit();
        self.* = .{
            .parent = parent,
            .heap = heap,
            .context = heap.runtime.context().*,
            .arena = .init(parent.scratch),
        };
        errdefer self.arena.deinit();
        if (ancestorSession(parent)) |ancestor| {
            try self.code_owners.appendSlice(
                self.arena.allocator(),
                ancestor.code_owners.items,
            );
        }
        try self.addCodeOwner(parent.runtime);
        try self.addCodeOwner(heap.runtime);
        self.context.identity = parent.identity;
        self.context.depth = parent.depth;
        self.context.registry = parent.registry;
        self.context.lease = &heap.lease;
        self.context.scratch = heap.account.allocator();
        self.context.scratch_base = heap.account.base;
        self.context.execution = .metered;
        self.context.mode = .concrete;
        self.context.effects = .{
            .state_read = parent.effects.state_read,
            .state_write = parent.effects.state_write,
        };
        self.context.allow_suspend = false;
        self.context.reentry = .{
            .state = self,
            .apply = bridgeApply,
            .source = bridgeSource,
            .lookup = bridgeLookup,
        };
        return self;
    }

    fn setModel(self: *Session, source_model: Model) Error!void {
        var private_model = source_model;
        inline for (.{ "lift_literal", "invoke_primitive", "decide_branch", "join" }) |name| {
            @field(private_model, name) = try self.importValue(@field(source_model, name));
        }
        self.model = private_model;
        self.context.model = private_model.version;
    }

    fn callHook(self: *Session, hook: Value, args: []const Value) Error!Value {
        if (args.len > 2) return error.ArityMismatch;
        const callable = try self.closure(hook);
        const previous_context = self.context;
        const previous_active = self.model_active;
        const previous_start = self.model_scope_start;
        const previous_speculating = self.speculating;
        self.context = try self.context.enter(.code);
        self.context.execution = .pure_limited;
        self.context.effects = .{ .state_read = previous_context.effects.state_read };
        self.context.allow_suspend = false;
        self.model_active = true;
        self.model_scope_start = self.namespaces.items.len;
        self.speculating = false;
        defer {
            self.context = previous_context;
            self.model_active = previous_active;
            self.model_scope_start = previous_start;
            self.speculating = previous_speculating;
        }
        const scope = self.context.activate();
        defer scope.deinit();
        var slots: [2]Slot = undefined;
        for (args, slots[0..args.len]) |value, *out| out.* = .{ .known = value };
        return (try (try self.call(callable.namespace, hook, slots[0..args.len])).requireKnown()).unwrapError();
    }

    fn keyword(self: *Session, text: []const u8) Error!Value {
        try self.charge(text.len + 1);
        return Value.keyword(try self.heap.runtime.store.getsym(text));
    }

    fn makeList(self: *Session, values: []const Value) Error!Value {
        return skript.intrinsics.list.list(&self.context, .nil, .nil, values);
    }

    fn slotDatum(self: *Session, slot: Slot) Error!Value {
        return switch (slot) {
            .known => |value| self.makeList(&.{ try self.keyword("known"), value }),
            .unknown => |value| self.makeList(&.{
                try self.keyword("unknown"),
                try Model.encodeUnknown(&self.context, value),
            }),
            .empty => error.InvalidCode,
        };
    }

    fn modelSlot(self: *Session, value: Value) Error!?Slot {
        if (isKeyword(value, "default")) return null;
        if (value.typ != b.type_cons) return error.TypeMismatch;
        const first = value.obj.toRef().deref([2]Value).*;
        if (first[1].typ != b.type_cons) return error.ArityMismatch;
        const second = first[1].obj.toRef().deref([2]Value).*;
        if (!second[1].isNil()) return error.ArityMismatch;
        if (isKeyword(first[0], "known")) return .{ .known = second[0] };
        if (!isKeyword(first[0], "unknown")) return error.TypeMismatch;
        return .{
            .unknown = try Model.decodeUnknown(
                &self.context,
                self.arena.allocator(),
                second[0],
                try self.unknownIdentity(),
            ),
        };
    }

    fn lift(self: *Session, value: Value) Error!Slot {
        if (self.model) |model| {
            if (!self.model_active) {
                if (try self.modelSlot(try self.callHook(model.lift_literal, &.{value}))) |result| return result;
            }
        }
        return .{ .known = value };
    }

    fn primitiveDatum(self: *Session, spec: *const Primitive.Spec) Error!Value {
        const name = try skript.intrinsics.string.storeString(&self.context, spec.stable_name);
        var effect_names: [@typeInfo(Context.EffectDecisionTable).@"struct".field_names.len]Value = undefined;
        var count: usize = 0;
        inline for (@typeInfo(Context.EffectDecisionTable).@"struct".field_names) |field_name| {
            if (@field(spec.effects, field_name)) {
                effect_names[count] = try self.keyword(field_name);
                count += 1;
            }
        }
        const values = [_]Value{
            try self.keyword("id"),       Value.i64(@backingInt(spec.id)),
            try self.keyword("revision"), Value.init(b.type_u64, @fromBackingInt(@intCast(spec.implementation_revision))),
            try self.keyword("name"),     name,
            try self.keyword("effects"),  try self.makeList(effect_names[0..count]),
        };
        return skript.intrinsics.map.create(&self.context, .nil, .nil, &values);
    }

    fn modelPrimitive(self: *Session, spec: *const Primitive.Spec, args: []const Slot) Error!?Slot {
        const model = self.model orelse return null;
        if (!model.authorizes(self.parent, spec.effects)) return null;
        try self.charge(args.len + 1);
        const arguments = try self.arena.allocator().alloc(Value, args.len);
        for (args, arguments) |value, *out| out.* = try self.slotDatum(value);
        const hook_args = [_]Value{ try self.primitiveDatum(spec), try self.makeList(arguments) };
        const result = try self.modelSlot(try self.callHook(model.invoke_primitive, &hook_args)) orelse return null;
        // Conditional-receive values arrive as unknown hook results; offer
        // them to lift-literal (as slot data) so literal policies observe
        // them exactly like imports. :default keeps the original slot.
        if (result == .unknown) {
            if (try self.modelSlot(try self.callHook(model.lift_literal, &.{try self.slotDatum(result)}))) |lifted| {
                try self.recordEffect(spec, args, lifted, model.version);
                return lifted;
            }
        }
        try self.recordEffect(spec, args, result, model.version);
        return result;
    }

    fn branchDecision(self: *Session, condition: Slot) Error!?bool {
        if (self.model) |model| {
            if (!self.model_active) {
                const value = try self.callHook(model.decide_branch, &.{try self.slotDatum(condition)});
                if (isKeyword(value, "both")) return null;
                if (value.typ == b.type_bool) return value.obj.toBool();
                if (!isKeyword(value, "default")) return error.TypeMismatch;
            }
        }
        if (condition == .unknown) {
            const typ = condition.unknown.typ orelse return null;
            if (typ == b.type_nil) return false;
            return if (typ == b.type_bool) null else true;
        }
        return (try condition.requireKnown()).isTruthy();
    }

    fn destroy(self: *Session) void {
        const allocator = self.parent.scratch;
        self.arena.deinit();
        self.heap.deinit();
        allocator.destroy(self);
    }

    fn charge(self: *Session, count: usize) Error!void {
        try self.context.chargeWork(@intCast(count), 1, .code);
    }

    fn unknownIdentity(self: *Session) Error!u32 {
        if (self.next_unknown == std.math.maxInt(u32)) {
            const budget = self.context.budget() orelse return error.Denied;
            return budget.overflow(.nodes, .code);
        }
        const identity = self.next_unknown;
        self.next_unknown += 1;
        return identity;
    }

    fn unknown(self: *Session, typ: ?Object) Error!Slot {
        try self.context.charge(.{ .work = 1, .nodes = 1 }, .code);
        return .{ .unknown = .{ .identity = try self.unknownIdentity(), .typ = typ } };
    }

    fn addCodeOwner(self: *Session, runtime: *skript.Runtime) Error!void {
        const owner: *const anyopaque = runtime;
        for (self.code_owners.items) |candidate| {
            if (candidate == owner) return;
        }
        try self.code_owners.append(self.arena.allocator(), owner);
    }

    fn ownsCode(self: *const Session, owner: ?*const anyopaque) bool {
        const candidate = owner orelse return false;
        for (self.code_owners.items) |verified| {
            if (verified == candidate) return true;
        }
        return false;
    }

    fn getLayout(self: *Session, code: *const Code.Code) Error!*const Layout {
        if (self.layouts.get(code)) |layout| return layout;
        if (!self.ownsCode(code.owner)) return error.InvalidCode;
        const allocator = self.arena.allocator();
        try code.validate(allocator, &self.context);
        try self.charge(code.values.len + code.functions.len);
        const layout = try allocator.create(Layout);
        layout.* = .{
            .code = code,
            .slots = try allocator.alloc(u32, code.values.len),
            .counts = try allocator.alloc(u32, code.functions.len),
        };
        @memset(layout.counts, 0);
        for (code.values, layout.slots) |function, *slot| {
            const index = @backingInt(function);
            slot.* = layout.counts[index];
            layout.counts[index] += 1;
        }
        try self.layouts.put(allocator, code, layout);
        return layout;
    }
    fn importValue(self: *Session, value: Value) Error!Value {
        if (value.typ == b.type_namespace) {
            const id = try self.importNamespace(value);
            return self.namespaces.items[id].value;
        }
        const result = try self.heap.importValue(self.parent, value);
        if (value.typ == b.type_closure) {
            const imported = if (self.closures.contains(result.obj)) result else blk: {
                const original = value.obj.toRef().deref(skript.data.Closure);
                break :blk (try self.rememberClosure(result, original)).value;
            };
            try self.rememberRegisteredClosure(value, imported);
            return imported;
        }
        return result;
    }

    fn rememberRegisteredClosure(self: *Session, original: Value, value: Value) Error!void {
        if (original.typ != b.type_closure) return;
        for (self.context.registry.specs) |*spec| {
            switch (spec.invoke) {
                .native => {},
                .closure => |registered| {
                    if (registered.obj != original.obj) continue;
                    try self.registered_primitives.put(
                        self.arena.allocator(),
                        value.obj,
                        spec.id,
                    );
                    return;
                },
            }
        }
    }

    fn registeredPrimitive(self: *const Session, value: Value) ?*const Primitive.Spec {
        const id = self.registered_primitives.get(value.obj) orelse return null;
        return self.context.registry.spec(id);
    }

    fn rememberClosure(self: *Session, value: Value, original: *const skript.data.Closure) Error!Closure {
        const private = value.obj.toRef().deref(skript.data.Closure);
        const code = private.code orelse return error.Unsupported;
        const namespace = try self.importNamespace(original.parent_ns);
        const captures = try self.arena.allocator().alloc(Slot, private.captures.len);
        for (private.captures, captures) |capture, *out| out.* = .{ .known = capture };
        const record: Closure = .{
            .value = value,
            .code = code,
            .function = private.function_id,
            .namespace = namespace,
            .captures = captures,
        };
        try self.closures.put(self.arena.allocator(), value.obj, record);
        private.parent_ns = self.namespaces.items[namespace].value;
        return record;
    }

    fn closure(self: *Session, value: Value) Error!Closure {
        if (value.typ != b.type_closure) return error.TypeMismatch;
        if (self.closures.get(value.obj)) |entry| return entry;
        var iterator = self.heap.import_objects.iterator();
        while (iterator.next()) |entry| {
            try self.charge(1);
            if (entry.value_ptr.typ != b.type_closure or entry.value_ptr.obj != value.obj) continue;
            const original = entry.key_ptr.object.toRef().deref(skript.data.Closure);
            const record = try self.rememberClosure(value, original);
            try self.rememberRegisteredClosure(Value.closure(entry.key_ptr.object), value);
            return record;
        }
        return error.Unsupported;
    }

    fn newNamespace(self: *Session, parent: ?usize, source_value: Value) Error!usize {
        const runtime = self.heap.runtime;
        const ref = try runtime.store.create(skript.Namespace);
        ref.deref(skript.Namespace).* = skript.HashMapNamespace.vtable;
        const map = try runtime.static.create(skript.HashMapNamespace);
        const parent_value = if (parent) |id| self.namespaces.items[id].value else Value.nil;
        map.* = try skript.HashMapNamespace.init(runtime.static, parent_value);
        ref.deref(skript.Namespace).data = @ptrCast(map);
        const value = Value.namespace(ref.toObject());
        runtime.ownNamespace(value);
        const index = self.namespaces.items.len;
        try self.namespaces.append(self.arena.allocator(), .{
            .value = value,
            .parent = parent,
            .source = source_value,
            .ready = source_value.isNil(),
        });
        try self.namespace_handles.put(self.arena.allocator(), value.obj, index);
        return index;
    }

    fn importNamespace(self: *Session, value: Value) Error!usize {
        if (value.typ != b.type_namespace) return error.TypeMismatch;
        if (self.namespace_handles.get(value.obj)) |id| return id;
        if (self.namespace_sources.get(value.obj)) |id| {
            if (!self.namespaces.items[id].ready) return error.Unsupported;
            return id;
        }
        const budget = self.context.budget() orelse return error.Denied;
        try budget.checkDepth(@intCast(self.namespaces.items.len + 1), .code);
        const table = value.obj.toRef().deref(skript.Namespace);
        if (!isBuiltinNamespace(table)) return error.Denied;
        const index = try self.newNamespace(null, value);
        try self.namespace_sources.put(self.arena.allocator(), value.obj, index);
        const parent_value = table.parent(self.parent.runtime, table, value.obj);
        if (parent_value.typ == b.type_namespace) {
            const parent = try self.importNamespace(parent_value);
            self.namespaces.items[index].parent = parent;
            const private_table = self.namespaces.items[index].value.obj.toRef().deref(skript.Namespace);
            const map: *skript.HashMapNamespace = @ptrCast(@alignCast(private_table.data));
            map.parent = self.namespaces.items[parent].value;
        }
        self.namespaces.items[index].ready = true;
        return index;
    }

    fn restrictedSourceRead(self: *Session, namespace: Value, symbol: Code.Symbol) Error!Value {
        // Hook-triggered imports land in shared evaluation state, so they are
        // capability-checked under the outer authority, not the hook sandbox.
        // Hook cache isolation is enforced separately in refreshSourceCache
        // via SourceCacheEntry provenance.
        var source_context = if (self.model_active) self.parent.* else self.context;
        source_context.runtime = self.parent.runtime;
        source_context.reentry = null;
        const scope = source_context.activate();
        defer scope.deinit();
        return self.parent.runtime.restrictedNamespaceRead(&source_context, namespace, symbol);
    }

    fn readQualifiedSource(self: *Session, start: usize, name: Code.Symbol) Error!?Slot {
        const source_name = try self.parent.runtime.store.getsym(name.*);
        var cursor: ?usize = start;
        while (cursor) |id| {
            const namespace = self.namespaces.items[id];
            if (!namespace.source.isNil()) {
                const value = self.restrictedSourceRead(namespace.source, source_name) catch |err| {
                    if (err == error.Unbound) {
                        cursor = namespace.parent;
                        continue;
                    }
                    return err;
                };
                return .{ .known = try self.importValue(value) };
            }
            cursor = namespace.parent;
        }
        return null;
    }

    /// Values a model hook may observe through the import cache even when the
    /// outer evaluation cached them first. Mirrors the type exemption in
    /// Runtime.restrictedNamespaceRead: code never carries observable data.
    fn isHookVisibleCode(value: Value) bool {
        return switch (value.typ) {
            b.type_intrinsic, b.type_method, b.type_type, b.type_closure => true,
            else => false,
        };
    }

    fn refreshSourceCache(
        self: *Session,
        id: usize,
        name: Code.Symbol,
        key: BindingKey,
        cached: Slot,
    ) Error!Slot {
        const entry = self.source_cache.get(key) orelse return cached;
        const namespace = self.namespaces.items[id];
        if (namespace.source.isNil()) return error.Denied;
        const source_name = try self.parent.runtime.store.getsym(name.*);
        var pre_read: ?Value = null;
        // Model hooks must not observe outer evaluation state through the
        // import cache; values the hook imported itself stay visible. Code is
        // exempt: callables, methods, intrinsics, and types stay readable
        // under any capability (see restrictedNamespaceRead), so a hook may
        // reuse outer-cached operators while outer data stays denied.
        if (self.model_active and !entry.hook_imported) {
            const probe = try self.restrictedSourceRead(namespace.source, source_name);
            if (!isHookVisibleCode(probe)) return error.Denied;
            pre_read = probe;
        }
        const source_value = pre_read orelse try self.restrictedSourceRead(namespace.source, source_name);
        const cached_value = try cached.requireKnown();
        if (source_value.typ == cached_value.typ and source_value.obj == cached_value.obj) {
            return cached;
        }
        const imported = try self.importValue(source_value);
        try self.writeNamespace(id, name, .{ .known = imported });
        try self.source_cache.put(self.arena.allocator(), key, .{ .hook_imported = self.model_active });
        return .{ .known = imported };
    }

    fn readNamespace(self: *Session, start: usize, name: Code.Symbol) Error!Slot {
        if (self.state_unknown) return self.unknown(null);
        if (try self.heap.runtime.splitQualified(name)) |qualified| {
            const alias = self.readNamespace(start, qualified.alias) catch |err| {
                if (err == error.Denied) {
                    if (try self.readQualifiedSource(start, name)) |value| return value;
                }
                return err;
            };
            if (alias == .unknown) return self.unknown(null);
            const value = try alias.requireKnown();
            if (value.typ != b.type_namespace) return error.TypeMismatch;
            const id = self.namespace_handles.get(value.obj) orelse return error.Denied;
            return self.readNamespace(id, qualified.name);
        }
        if (std.mem.startsWith(u8, name.*, "@")) {
            const plain = name.*[1..];
            try self.charge(self.context.registry.specs.len);
            if (self.context.registry.find(plain)) |spec| {
                return .{ .known = switch (spec.invoke) {
                    .native => |function| Value.intrinsic(function),
                    .closure => |value| try self.importValue(value),
                } };
            }
            if (self.parent.runtime.constants.get(plain)) |value| return .{ .known = try self.importValue(value) };
            return error.Unbound;
        }
        const private_name = try self.heap.runtime.store.getsym(name.*);
        var cursor: ?usize = start;
        while (cursor) |id| {
            try self.charge(1);
            const namespace = self.namespaces.items[id];
            const key: BindingKey = .{ .namespace = id, .symbol = private_name };
            if (self.bindings.get(key)) |value| {
                return self.refreshSourceCache(id, name, key, value);
            }
            const table = namespace.value.obj.toRef().deref(skript.Namespace);
            if (table.contains(self.heap.runtime, table, namespace.value.obj, private_name)) {
                const value: Slot = .{ .known = try table.get(
                    self.heap.runtime,
                    table,
                    namespace.value.obj,
                    private_name,
                ).unwrapError() };
                return self.refreshSourceCache(id, name, key, value);
            }
            if (!namespace.source.isNil()) {
                const source_table = namespace.source.obj.toRef().deref(skript.Namespace);
                const parent_scope = self.parent.activate();
                const source_name = self.parent.runtime.store.getsym(name.*) catch |err| {
                    parent_scope.deinit();
                    return err;
                };
                const present = source_table.contains(
                    self.parent.runtime,
                    source_table,
                    namespace.source.obj,
                    source_name,
                );
                const raw = if (present)
                    source_table.get(self.parent.runtime, source_table, namespace.source.obj, source_name)
                else
                    Value.nil;
                parent_scope.deinit();
                if (present) {
                    _ = try self.restrictedSourceRead(namespace.source, source_name);
                    const value = try self.importValue(try raw.unwrapError());
                    try self.writeNamespace(id, name, .{ .known = value });
                    try self.source_cache.put(self.arena.allocator(), key, .{ .hook_imported = self.model_active });
                    return .{ .known = value };
                }
            }
            cursor = namespace.parent;
        }
        return error.Unbound;
    }

    fn writeNamespace(self: *Session, id: usize, name: Code.Symbol, value: Slot) Error!void {
        try self.charge(name.*.len + 1);
        const symbol = try self.heap.runtime.store.getsym(name.*);
        if (value == .empty) return error.InvalidCode;
        const key: BindingKey = .{ .namespace = id, .symbol = symbol };
        _ = self.source_cache.remove(key);
        if (self.speculating or value == .unknown) {
            try self.bindings.put(self.arena.allocator(), key, value);
            return;
        }
        if (self.bindings.remove(key)) std.debug.assert(!self.bindings.contains(key));
        try self.heap.runtime.nsBind(self.namespaces.items[id].value, symbol, value.known);
    }

    fn push(
        self: *Session,
        target: Closure,
        args: []const Slot,
        destination: Code.ValueId,
        count: u8,
        tail: bool,
    ) Error!void {
        const info = target.code.function(target.function) orelse return error.InvalidCode;
        if (info.has_rest) return error.Unsupported;
        if (args.len != info.parameter_count or target.captures.len != info.capture_count) return error.ArityMismatch;
        if (count != info.result_count) return error.ArityMismatch;
        const layout = try self.getLayout(target.code);
        if (tail and self.active_frames == 0) return error.InvalidCode;
        const index = if (tail) self.active_frames - 1 else self.active_frames;
        const budget = self.context.budget() orelse return error.Denied;
        try budget.checkDepth(@intCast(self.context.depth + index + 1), .code);
        if (index == self.frames.items.len) try self.frames.append(self.arena.allocator(), .{});
        var frame = &self.frames.items[index];
        const saved_destination = if (tail) frame.destination else destination;
        const saved_count = if (tail) frame.result_count else count;
        try frame.slots.resize(self.arena.allocator(), layout.counts[@backingInt(target.function)]);
        try self.charge(frame.slots.items.len + args.len + target.captures.len);
        @memset(frame.slots.items, .empty);
        frame.closure = target;
        frame.layout = layout;
        frame.block = target.code.function_blocks[info.block_start];
        frame.cursor = 0;
        frame.namespace = target.namespace;
        frame.destination = saved_destination;
        frame.result_count = saved_count;
        frame.handlers.clearRetainingCapacity();
        for (args, 0..) |arg, i| {
            const parameter = target.code.parameters[info.parameter_start + i];
            try frame.set(target.code.bindings[@backingInt(parameter)].value, arg);
        }
        for (target.captures, 0..) |capture, i| {
            try frame.set(
                target.code.capture_values[info.capture_start + i],
                capture,
            );
        }
        if (!tail) self.active_frames += 1;
    }

    fn binding(self: *Session, frame_index: usize, id: Code.BindingId) Error!Slot {
        const frame = &self.frames.items[frame_index];
        const code = frame.closure.code;
        const entry = code.bindings[@backingInt(id)];
        if (entry.function == frame.closure.function) return frame.get(entry.value);
        const function = code.function(frame.closure.function) orelse return error.InvalidCode;
        for (code.captures[function.capture_start..][0..function.capture_count], 0..) |capture, i| {
            try self.charge(1);
            if (capture == id) return frame.get(code.capture_values[function.capture_start + i]);
        }
        return error.InvalidCode;
    }

    fn operands(self: *Session, frame_index: usize, range: Code.OperandRange) Error![]const Slot {
        try self.charge(range.len);
        var frame = &self.frames.items[frame_index];
        try frame.transfer.resize(self.arena.allocator(), range.len);
        const values = frame.closure.code.operands[range.start..][0..range.len];
        for (values, frame.transfer.items) |id, *out| out.* = try frame.get(id);
        return frame.transfer.items;
    }

    fn makeClosure(
        self: *Session,
        code: *const Code.Code,
        function: Code.FunctionId,
        namespace: usize,
        captures: []const Slot,
    ) Error!Value {
        const info = code.function(function) orelse return error.InvalidCode;
        const runtime = self.heap.runtime;
        const ref = try runtime.store.create(skript.data.Closure);
        // Retain the final rest binding name; Code keeps the call semantics.
        const names = try runtime.static.alloc(Code.Symbol, info.parameter_count);
        for (names, 0..) |*name, i| {
            name.* = code.bindings[
                @backingInt(code.parameters[info.parameter_start + i])
            ].name;
        }
        ref.deref(skript.data.Closure).* = .{
            .parent_ns = self.namespaces.items[namespace].value,
            .arglist = names,
            .code = code,
            .function_id = function,
            .result_count = info.result_count,
            .source = info.source_value,
            .source_ref = info.source,
        };
        const value = Value.closure(ref.toObject());
        try self.closures.put(self.arena.allocator(), value.obj, .{
            .value = value,
            .code = code,
            .function = function,
            .namespace = namespace,
            .captures = try self.arena.allocator().dupe(Slot, captures),
        });
        return value;
    }

    fn deferredPrimitive(self: *Session, spec: *const Primitive.Spec, args: []const Slot) Error!Slot {
        if (spec.effects.state_write or spec.effects.unknown) self.state_unknown = true;
        const result = try self.unknown(null);
        try self.recordEffect(spec, args, result, null);
        return result;
    }

    fn recordEffect(
        self: *Session,
        spec: *const Primitive.Spec,
        args: []const Slot,
        result: Slot,
        model: ?Context.Version,
    ) Error!void {
        return self.appendEffect(
            .{ .primitive = .{ .id = spec.id, .revision = spec.implementation_revision } },
            spec.effects,
            args,
            result,
            model,
        );
    }

    fn deferredCall(self: *Session, callee: Slot, args: []const Slot) Error!Slot {
        if (self.model_active) return error.Denied;
        const saved = try self.arena.allocator().create(Slot);
        saved.* = callee;
        const result = try self.unknown(null);
        self.state_unknown = true;
        try self.appendEffect(.{ .call = saved }, .{ .unknown = true }, args, result, null);
        return result;
    }

    fn appendEffect(
        self: *Session,
        invocation: Invocation,
        effects: Primitive.EffectSet,
        args: []const Slot,
        result: Slot,
        model: ?Context.Version,
    ) Error!void {
        try self.charge(args.len + 1);
        try self.context.charge(.{ .nodes = 1 }, .code);
        if (model == null) self.has_deferred = true;

        var root_count: usize = 0;
        switch (invocation) {
            .primitive => {},
            .call => |invoked| switch (invoked.*) {
                .known => root_count += 1,
                .unknown => {},
                .empty => return error.InvalidCode,
            },
        }
        for (args) |argument| switch (argument) {
            .known => root_count += 1,
            .unknown => {},
            .empty => return error.InvalidCode,
        };
        switch (result) {
            .known => root_count += 1,
            .unknown => {},
            .empty => return error.InvalidCode,
        }

        const allocator = self.arena.allocator();
        const roots = try allocator.alloc(Value, root_count);
        const copied = try allocator.alloc(Value, root_count);
        const argument_roots = try allocator.alloc(?usize, args.len);
        var root_index: usize = 0;
        var invocation_root: ?usize = null;
        switch (invocation) {
            .primitive => {},
            .call => |invoked| switch (invoked.*) {
                .known => {
                    invocation_root = root_index;
                    roots[root_index] = invoked.known;
                    root_index += 1;
                },
                .unknown => {},
                .empty => unreachable,
            },
        }
        for (args, argument_roots) |argument, *root| switch (argument) {
            .known => {
                root.* = root_index;
                roots[root_index] = argument.known;
                root_index += 1;
            },
            .unknown => root.* = null,
            .empty => unreachable,
        };
        var result_root: ?usize = null;
        switch (result) {
            .known => {
                result_root = root_index;
                roots[root_index] = result.known;
                root_index += 1;
            },
            .unknown => {},
            .empty => unreachable,
        }
        std.debug.assert(root_index == root_count);
        try self.heap.snapshotValues(&self.context, roots, copied);

        const copied_arguments = try allocator.alloc(Slot, args.len);
        for (args, argument_roots, copied_arguments) |argument, root, *out| {
            out.* = switch (argument) {
                .known => .{ .known = copied[root orelse return error.InvalidCode] },
                .unknown => argument,
                .empty => unreachable,
            };
        }
        const copied_result: Slot = switch (result) {
            .known => .{ .known = copied[result_root orelse return error.InvalidCode] },
            .unknown => result,
            .empty => unreachable,
        };
        var copied_invocation = invocation;
        switch (invocation) {
            .primitive => {},
            .call => |invoked| {
                const copied_call = try allocator.create(Slot);
                copied_call.* = switch (invoked.*) {
                    .known => .{ .known = copied[invocation_root orelse return error.InvalidCode] },
                    .unknown => invoked.*,
                    .empty => unreachable,
                };
                copied_invocation = .{ .call = copied_call };
            },
        }
        try self.effects.append(allocator, .{
            .invocation = copied_invocation,
            .effects = effects,
            .path = self.path,
            .arguments = copied_arguments,
            .model = model,
            .result = copied_result,
        });
    }

    fn native(self: *Session, namespace: usize, spec: *const Primitive.Spec, args: []const Slot) Error!Slot {
        if (!self.model_active and !self.suppress_primitive_model) {
            if (try self.modelPrimitive(spec, args)) |result| return result;
        }
        const effect = spec.effects;
        if (self.model_active and
            (effect.io or effect.clock or effect.random or effect.process or effect.module or
                effect.ffi or effect.dynamic_loader or effect.host or effect.unknown or effect.state_write))
            return error.Denied;
        if (self.speculating and effect.state_write) {
            self.state_unknown = true;
            return self.deferredPrimitive(spec, args);
        }
        if (self.state_unknown and effect.state_read) return self.deferredPrimitive(spec, args);
        if (effect.io or effect.clock or effect.random or effect.process or effect.module or
            effect.ffi or effect.dynamic_loader or effect.host or effect.unknown)
            return self.deferredPrimitive(spec, args);
        if (args.len == 2 and (args[0] == .unknown or args[1] == .unknown)) {
            if (try Domain.primitive(&self.context, spec, args, try self.unknownIdentity())) |result| {
                if (result == .unknown) try self.recordEffect(spec, args, result, null);
                return result;
            }
        }
        for (args) |argument| if (argument == .empty) return error.InvalidCode;
        switch (spec.invoke) {
            .closure => |value| {
                const authorization = self.context.authorize(spec) catch |err| {
                    if (err == error.Denied and !self.model_active) return self.deferredPrimitive(spec, args);
                    return err;
                };
                var credit = switch (authorization) {
                    .invoke => |reservation| reservation,
                    .model => return self.deferredPrimitive(spec, args),
                };
                var context = try self.context.forPrimitive(&credit);
                context.in_native = true;
                const scope = context.activate();
                defer scope.deinit();
                return self.invokeClosurePrimitive(value, args, &context);
            },
            .native => |function| {
                var converted: ValueArguments = .{};
                defer converted.deinit(self.context.scratch);
                const values = converted.init(.values, &self.context, args) catch |err| {
                    if (err == error.Unsupported and !self.model_active) {
                        return self.deferredPrimitive(spec, args);
                    }
                    return err;
                };
                const authorization = self.context.authorize(spec) catch |err| {
                    if (err == error.Denied and !self.model_active) return self.deferredPrimitive(spec, args);
                    return err;
                };
                var credit = switch (authorization) {
                    .invoke => |reservation| reservation,
                    .model => return self.deferredPrimitive(spec, args),
                };
                var context = try self.context.forPrimitive(&credit);
                context.in_native = true;
                const scope = context.activate();
                defer scope.deinit();
                self.pending_failure = null;
                const previous_unknown = self.unknown_callback;
                self.unknown_callback = false;
                defer self.unknown_callback = previous_unknown;
                const result = function(
                    &context,
                    self.namespaces.items[namespace].value,
                    Value.intrinsic(function),
                    values,
                ) catch |err| {
                    try context.check();
                    if (err == error.Unsupported and self.unknown_callback) {
                        self.state_unknown = true;
                        return self.deferredPrimitive(spec, args);
                    }
                    if (err == error.WouldBlock) return error.Denied;
                    return err;
                };
                self.pending_failure = null;
                try context.check();
                return .{ .known = result };
            },
        }
    }

    fn invokeClosurePrimitive(
        self: *Session,
        value: Value,
        args: []const Slot,
        context: *Context,
    ) Error!Slot {
        const target = try self.importValue(value);
        const closure_info = try self.closure(target);
        const previous_context = self.context;
        self.context = context.*;
        defer self.context = previous_context;
        const base = self.active_frames;
        const previous_unknown = self.unknown_callback;
        self.unknown_callback = false;
        defer self.unknown_callback = previous_unknown;
        self.pending_failure = null;
        self.push(closure_info, args, .invalid, 1, false) catch |err| {
            try context.check();
            return err;
        };
        const result = self.run(base) catch |err| {
            try context.check();
            return err;
        };
        try context.check();
        return result;
    }

    const PreparedCall = struct {
        target: ?Value,
        callee: Slot,
        args: []const Slot,
    };

    const ForwardedApply = struct { callee: Slot, args: []const Slot };

    /// Retain abstract prefix arguments while expanding a concrete final list.
    /// An unknown spread cannot be flattened; the original call stays deferred.
    fn expandApply(self: *Session, args: []const Slot) Error!?ForwardedApply {
        if (args.len < 2) return error.ArityMismatch;
        const spread = switch (args[args.len - 1]) {
            .known => |value| value,
            .unknown => return null,
            .empty => return error.InvalidCode,
        };
        var inline_storage: [32]Value = undefined;
        var expanded = try skript.intrinsics.list.expandApplyArguments(
            &self.context,
            &.{ .nil, spread },
            &inline_storage,
        );
        defer expanded.deinit();
        const positional_count = args.len - 2;
        const count = std.math.add(usize, positional_count, expanded.values.len) catch return error.Unsupported;
        try self.charge(positional_count);
        const forwarded = try self.arena.allocator().alloc(Slot, count);
        @memcpy(forwarded[0..positional_count], args[1 .. args.len - 1]);
        for (expanded.values, forwarded[positional_count..]) |value, *out| out.* = .{ .known = value };
        return .{ .callee = args[0], .args = forwarded };
    }

    fn prepareCall(self: *Session, initial_callee: Slot, initial_args: []const Slot) Error!PreparedCall {
        var callee = initial_callee;
        var args = initial_args;
        for (0..128) |_| {
            const target = (try self.resolveCall(callee, args)) orelse
                return .{ .target = null, .callee = callee, .args = args };
            if (target.typ != b.type_intrinsic or target.obj == .null or
                target.obj.toPtr(skript.FuncPtr) != &skript.intrinsics.list.apply)
            {
                return .{ .target = target, .callee = callee, .args = args };
            }
            const id = self.context.registry.idForNative(&skript.intrinsics.list.apply) orelse return error.Denied;
            const spec = self.context.registry.spec(id) orelse return error.Denied;
            switch (spec.invoke) {
                .native => |function| {
                    if (function != &skript.intrinsics.list.apply) return error.Denied;
                },
                .closure => return error.Denied,
            }
            switch (try self.context.authorize(spec)) {
                .invoke => {},
                .model => return error.Denied,
            }
            const expanded = try self.expandApply(args) orelse
                return .{ .target = null, .callee = callee, .args = args };
            callee = expanded.callee;
            args = expanded.args;
        }
        return error.Unsupported;
    }

    fn resolve(self: *Session, callable: Value, args: []const Slot) Error!Value {
        var target = callable;
        for (0..128) |_| {
            try self.charge(1);
            switch (target.typ) {
                b.type_method => {
                    var converted: ValueArguments = .{};
                    defer converted.deinit(self.context.scratch);
                    const values = try converted.init(.types, &self.context, args);
                    target = try target.obj.toRef().deref(skript.data.Method).get(self.heap.runtime, values);
                },
                b.type_type => {
                    target = self.heap.runtime.typePtrFromObj(target.obj).apply;
                    if (target.isNil()) return error.Unimplemented;
                },
                else => return target,
            }
        }
        return error.Unsupported;
    }

    fn resolveCall(self: *Session, callee: Slot, args: []const Slot) Error!?Value {
        if (callee == .unknown) return null;
        return self.resolve(try callee.requireKnown(), args) catch |err| {
            if (err == error.Unsupported) {
                for (args) |argument| if (argument == .unknown) return null;
            }
            return err;
        };
    }

    fn immediate(self: *Session, namespace: usize, target: Value, args: []const Slot) Error!Slot {
        switch (target.typ) {
            b.type_intrinsic => {
                const id = self.context.registry.idForNative(
                    target.obj.toPtr(skript.FuncPtr),
                ) orelse return error.Denied;
                const spec = self.context.registry.spec(id) orelse return error.Denied;
                return self.native(namespace, spec, args);
            },
            b.type_closure => {
                const spec = self.registeredPrimitive(target) orelse return error.Unimplemented;
                return self.native(namespace, spec, args);
            },
            b.type_keyword => {
                if (args.len != 1) return error.ArityMismatch;
                if (args[0] == .unknown) return self.deferredCall(.{ .known = target }, args);
                const value = try args[0].requireKnown();
                if (value.typ != b.type_namespace) return error.TypeMismatch;
                const id = self.namespace_handles.get(value.obj) orelse return error.Denied;
                return self.readNamespace(id, target.obj.toPtr(Code.Symbol));
            },
            b.type_ffifunc => return error.Denied,
            else => return error.Unimplemented,
        }
    }

    fn call(self: *Session, namespace: usize, callable: Value, args: []const Slot) Error!Slot {
        self.pending_failure = null;
        const prepared = try self.prepareCall(.{ .known = callable }, args);
        const target = prepared.target orelse return self.deferredCall(prepared.callee, prepared.args);
        if (target.typ != b.type_closure) return self.immediate(namespace, target, prepared.args);
        if (self.registeredPrimitive(target)) |spec| return self.native(namespace, spec, prepared.args);
        const closure_info = try self.closure(target);
        const base = self.active_frames;
        try self.push(closure_info, prepared.args, .invalid, 1, false);
        return self.run(base);
    }

    fn dispatch(
        self: *Session,
        frame_index: usize,
        callee: Slot,
        args: []const Slot,
        destination: Code.ValueId,
        count: u8,
        tail: bool,
    ) Error!void {
        const prepared = try self.prepareCall(callee, args);
        const target = prepared.target orelse {
            const result = try self.deferredCall(prepared.callee, prepared.args);
            for (0..count) |i| {
                const value = if (i == 0) result else try self.unknown(null);
                try self.frames.items[frame_index].set(@fromBackingInt(@intCast(@backingInt(destination) + i)), value);
            }
            return;
        };
        const forwarded = prepared.args;
        const namespace = self.frames.items[frame_index].namespace;
        if (target.typ == b.type_closure) {
            const info = try self.closure(target);
            if (self.registeredPrimitive(target)) |spec| {
                if (count != 1) return error.Unsupported;
                const result = try self.native(namespace, spec, forwarded);
                try self.frames.items[frame_index].set(destination, result);
                return;
            }
            try self.push(info, forwarded, destination, count, tail);
            return;
        }
        if (count != 1) return error.Unsupported;
        const result = try self.immediate(namespace, target, forwarded);
        try self.frames.items[frame_index].set(destination, result);
    }

    fn execute(self: *Session, index: usize, node: Code.Node) Error!void {
        const code = self.frames.items[index].closure.code;
        switch (node.operation) {
            .literal, .quote => |value| {
                const imported = if (code.owner == @as(?*const anyopaque, self.heap.runtime))
                    value
                else
                    try self.importValue(value);
                const lifted = try self.lift(imported);
                try self.frames.items[index].set(node.result, lifted);
            },
            .local_read => |id| {
                const value = try self.binding(index, id);
                try self.frames.items[index].set(node.result, value);
            },
            .global_read => |id| {
                const value = try self.readNamespace(
                    self.frames.items[index].namespace,
                    code.globals[@backingInt(id)].name,
                );
                try self.frames.items[index].set(node.result, value);
            },
            .global_write => |write| {
                if (write.assign_existing) return error.Unsupported;
                const namespace = self.frames.items[index].namespace;
                if (self.model_active and namespace < self.model_scope_start) return error.Denied;
                try self.writeNamespace(
                    namespace,
                    code.globals[@backingInt(write.cell)].name,
                    try self.frames.items[index].get(write.value),
                );
            },
            .primitive_call => |call_info| {
                const spec = self.context.registry.spec(call_info.primitive) orelse return error.Denied;
                const args = try self.operands(index, call_info.args);
                switch (spec.invoke) {
                    .native => |function| try self.dispatch(
                        index,
                        .{ .known = Value.intrinsic(function) },
                        args,
                        node.result,
                        call_info.result_count,
                        call_info.tail,
                    ),
                    .closure => {
                        if (call_info.result_count != 1) return error.Unsupported;
                        const result = try self.native(
                            self.frames.items[index].namespace,
                            spec,
                            args,
                        );
                        try self.frames.items[index].set(node.result, result);
                    },
                }
            },
            .dynamic_call => |call_info| try self.dispatch(
                index,
                try self.frames.items[index].get(call_info.callee),
                try self.operands(index, call_info.args),
                node.result,
                call_info.result_count,
                call_info.tail,
            ),
            .direct_call => |call_info| {
                const info = code.function(call_info.function) orelse return error.InvalidCode;
                const captures = try self.arena.allocator().alloc(Slot, info.capture_count);
                for (captures, 0..) |*out, i| out.* = try self.binding(index, code.captures[info.capture_start + i]);
                const value = try self.makeClosure(
                    code,
                    call_info.function,
                    self.frames.items[index].namespace,
                    captures,
                );
                try self.dispatch(
                    index,
                    .{ .known = value },
                    try self.operands(index, call_info.args),
                    node.result,
                    call_info.result_count,
                    false,
                );
            },
            .arithmetic => |arith| {
                const callee = if (arith.callee != .invalid)
                    try self.frames.items[index].get(arith.callee)
                else
                    Slot{ .known = try self.importValue(arith.expected_callee) };
                const args = [_]Slot{
                    try self.frames.items[index].get(arith.left),
                    try self.frames.items[index].get(arith.right),
                };
                if (try self.modelArithmetic(callee, &args)) |value| {
                    try self.frames.items[index].set(node.result, value);
                    return;
                }
                if (try self.abstractArithmetic(code, arith, callee, &args)) |value| {
                    try self.frames.items[index].set(node.result, value);
                    return;
                }
                const previous = self.suppress_primitive_model;
                self.suppress_primitive_model = true;
                defer self.suppress_primitive_model = previous;
                try self.dispatch(index, callee, &args, node.result, 1, arith.tail);
            },
            .make_closure => |make| {
                const value = try self.makeClosure(
                    code,
                    make.function,
                    self.frames.items[index].namespace,
                    try self.operands(index, make.captures),
                );
                try self.frames.items[index].set(node.result, .{ .known = value });
            },
            .try_begin => |handler| try self.frames.items[index].handlers.append(
                self.arena.allocator(),
                .{ .id = handler, .namespace = self.frames.items[index].namespace },
            ),
            .try_end => {
                if (self.frames.items[index].handlers.pop() == null) return error.InvalidCode;
            },
            .ns_push => {
                const id = try self.newNamespace(self.frames.items[index].namespace, .nil);
                self.frames.items[index].namespace = id;
                try self.frames.items[index].set(node.result, .{ .known = self.namespaces.items[id].value });
            },
            .ns_pop => self.frames.items[index].namespace =
                self.namespaces.items[self.frames.items[index].namespace].parent orelse return error.InvalidCode,
        }
    }

    fn jump(self: *Session, index: usize, edge: Code.Edge) Error!void {
        const args = try self.operands(index, edge.args);
        var frame = &self.frames.items[index];
        const block = frame.closure.code.blocks[@backingInt(edge.target)];
        if (args.len != block.param_count) return error.InvalidCode;
        for (frame.closure.code.block_parameters[block.param_start..][0..block.param_count], args) |id, value| {
            try frame.set(id, value);
        }
        frame.block = edge.target;
        frame.cursor = 0;
    }

    fn fail(self: *Session, base: usize, payload: Slot, signal: Error) Error!?Slot {
        self.pending_failure = null;
        // Terminal allocation failures stay outside catch handlers: surfacing
        // them as error values would let (try … (catch …)) swallow OOM.
        if (signal == error.OutOfMemory) return signal;
        while (self.active_frames > base) {
            if (self.active_frames == 0) return error.InvalidCode;
            var frame = &self.frames.items[self.active_frames - 1];
            if (frame.handlers.pop()) |saved| {
                const handler = frame.closure.code.handlers[@backingInt(saved.id)];
                frame.namespace = saved.namespace;
                frame.block = handler.landing;
                frame.cursor = 0;
                try frame.set(handler.exception, payload);
                return null;
            }
            self.active_frames -= 1;
        }
        self.pending_failure = .{ .signal = signal, .payload = payload };
        if (signal != error.Raised and payload == .known and payload.known.typ == b.type_error) return payload;
        return .{ .known = Value.err(signal) };
    }

    fn captureState(self: *const Session) Snapshot {
        return .{
            .frames = self.frames,
            .active_frames = self.active_frames,
            .bindings = self.bindings,
            .source_cache = self.source_cache,
            .path = self.path,
            .speculating = self.speculating,
            .state_unknown = self.state_unknown,
            .failure = self.pending_failure,
        };
    }

    fn restore(self: *Session, snapshot: Snapshot) void {
        self.frames = snapshot.frames;
        self.active_frames = snapshot.active_frames;
        self.bindings = snapshot.bindings;
        self.source_cache = snapshot.source_cache;
        self.path = snapshot.path;
        self.speculating = snapshot.speculating;
        self.state_unknown = snapshot.state_unknown;
        self.pending_failure = snapshot.failure;
    }

    fn copySnapshot(self: *Session) Error!Snapshot {
        const allocator = self.arena.allocator();
        try self.charge(self.active_frames + self.bindings.count() + self.source_cache.count());
        var snapshot = self.captureState();
        snapshot.frames = try .initCapacity(allocator, self.active_frames);
        snapshot.bindings = try self.bindings.clone(allocator);
        snapshot.source_cache = try self.source_cache.clone(allocator);
        for (self.frames.items[0..self.active_frames]) |frame| {
            try self.charge(frame.slots.items.len + frame.handlers.items.len);
            var copied = frame;
            copied.slots = .fromOwnedSlice(try allocator.dupe(Slot, frame.slots.items));
            copied.handlers = .fromOwnedSlice(try allocator.dupe(Handler, frame.handlers.items));
            copied.transfer = .empty;
            snapshot.frames.appendAssumeCapacity(copied);
        }
        return snapshot;
    }

    fn branchPath(self: *Session, condition: Slot, selected: bool) Error!u32 {
        const budget = self.context.budget() orelse return error.Denied;
        if (self.paths.items.len == std.math.maxInt(u32)) return budget.overflow(.paths, .code);
        const id: u32 = @intCast(self.paths.items.len);
        try self.paths.append(
            self.arena.allocator(),
            .{ .parent = self.path, .condition = condition, .selected = selected },
        );
        return id;
    }

    fn modelArithmetic(self: *Session, callee: Slot, args: []const Slot) Error!?Slot {
        if (self.model == null or self.model_active or self.suppress_primitive_model) return null;
        const target = (try self.resolveCall(callee, args)) orelse return null;
        const spec = switch (target.typ) {
            b.type_intrinsic => blk: {
                const id = self.context.registry.idForNative(
                    target.obj.toPtr(skript.FuncPtr),
                ) orelse return error.Denied;
                break :blk self.context.registry.spec(id) orelse return error.Denied;
            },
            b.type_closure => blk: {
                if (self.registeredPrimitive(target)) |spec| break :blk spec;
                // Method instances arrive via table copies without primitive
                // registration, so bound arithmetic would bypass the model
                // while explicit primitive calls consult it. Heal through the
                // import-object scan (which registers what it finds) so both
                // paths consult the model exactly once. Only a genuinely
                // unknown closure bypasses the model; allocation and budget
                // failures propagate instead of silently skipping the hook.
                _ = self.closure(target) catch |err| switch (err) {
                    error.Unsupported => break :blk self.registeredPrimitive(target) orelse return null,
                    else => return err,
                };
                break :blk self.registeredPrimitive(target) orelse return null;
            },
            else => return null,
        };
        return self.modelPrimitive(spec, args);
    }

    fn abstractArithmetic(
        self: *Session,
        code: *const Code.Code,
        arith: Code.Arithmetic,
        callee: Slot,
        args: []const Slot,
    ) Error!?Slot {
        std.debug.assert(args.len == 2);
        if (args[0] != .unknown and args[1] != .unknown) return null;
        if (callee != .known or arith.expected_callee.isNil()) return null;
        const expected = if (code.owner == @as(?*const anyopaque, self.heap.runtime))
            arith.expected_callee
        else
            try self.importValue(arith.expected_callee);
        if (expected.typ != b.type_method or !std.meta.eql(expected, callee.known)) return null;
        if (!expected.obj.toRef().deref(skript.data.Method).locked) return null;
        const result = Domain.arithmetic(
            &self.context,
            arith.op,
            args[0],
            args[1],
            try self.unknownIdentity(),
        ) catch |err| {
            if (err == error.Unsupported) return null;
            return err;
        };
        if (result == .unknown) {
            const target = try self.resolve(callee.known, args);
            if (target.typ != b.type_intrinsic) return error.Denied;
            const id = self.context.registry.idForNative(target.obj.toPtr(skript.FuncPtr)) orelse return error.Denied;
            const spec = self.context.registry.spec(id) orelse return error.Denied;
            try self.recordEffect(spec, args, result, null);
        }
        return result;
    }

    fn join(self: *Session, left: Slot, right: Slot) Error!Slot {
        if (left == .empty or right == .empty) return self.unknown(null);
        if (self.model) |model| {
            if (!self.model_active) {
                const args = [_]Value{ try self.slotDatum(left), try self.slotDatum(right) };
                if (try self.modelSlot(try self.callHook(model.join, &args))) |result| return result;
            }
        }
        return Domain.join(self.arena.allocator(), &self.context, left, right, try self.unknownIdentity());
    }

    fn branchBinding(self: *Session, state: Snapshot, key: BindingKey) Error!Slot {
        if (state.bindings.get(key)) |value| return value;
        return self.readNamespace(key.namespace, key.symbol) catch |err| switch (err) {
            error.Unbound => .empty,
            else => return err,
        };
    }

    fn mergeBindings(self: *Session, left: Snapshot, right: Snapshot) Error!void {
        const allocator = self.arena.allocator();
        var merged = try self.bindings.clone(allocator);
        var first = left.bindings.iterator();
        while (first.next()) |entry| {
            try self.charge(1);
            const other = try self.branchBinding(right, entry.key_ptr.*);
            try merged.put(allocator, entry.key_ptr.*, try self.join(entry.value_ptr.*, other));
        }
        var second = right.bindings.iterator();
        while (second.next()) |entry| {
            try self.charge(1);
            if (left.bindings.contains(entry.key_ptr.*)) continue;
            const other = try self.branchBinding(left, entry.key_ptr.*);
            try merged.put(allocator, entry.key_ptr.*, try self.join(other, entry.value_ptr.*));
        }
        var merged_source_cache = try self.source_cache.clone(allocator);
        var left_source_cache = left.source_cache.iterator();
        while (left_source_cache.next()) |entry| {
            const previous = merged_source_cache.get(entry.key_ptr.*);
            try merged_source_cache.put(allocator, entry.key_ptr.*, .{
                .hook_imported = (if (previous) |found| found.hook_imported else false) or
                    entry.value_ptr.*.hook_imported,
            });
        }
        var right_source_cache = right.source_cache.iterator();
        while (right_source_cache.next()) |entry| {
            const previous = merged_source_cache.get(entry.key_ptr.*);
            try merged_source_cache.put(allocator, entry.key_ptr.*, .{
                .hook_imported = (if (previous) |found| found.hook_imported else false) or
                    entry.value_ptr.*.hook_imported,
            });
        }
        self.bindings = merged;
        self.source_cache = merged_source_cache;
    }

    fn explore(self: *Session, base: usize, index: usize, branch: Code.Branch, condition: Slot) Error!Slot {
        try self.context.charge(.{ .work = 2, .nodes = 2, .paths = 2 }, .code);
        const budget = self.context.budget() orelse return error.Denied;
        self.fork_depth = std.math.add(u32, self.fork_depth, 1) catch return budget.overflow(.depth, .code);
        defer self.fork_depth -= 1;
        const frame_depth = std.math.add(
            u32,
            self.context.depth,
            @intCast(self.active_frames),
        ) catch return budget.overflow(.depth, .code);
        const depth = std.math.add(u32, frame_depth, self.fork_depth) catch return budget.overflow(.depth, .code);
        try budget.checkDepth(depth, .code);
        const original = self.captureState();
        errdefer self.restore(original);
        self.restore(try self.copySnapshot());
        self.speculating = true;
        self.path = try self.branchPath(condition, true);
        try self.jump(index, branch.then_edge);
        const left_value = try self.run(base);
        const left = self.captureState();
        self.restore(original);
        self.restore(try self.copySnapshot());
        self.speculating = true;
        self.path = try self.branchPath(condition, false);
        try self.jump(index, branch.else_edge);
        const right_value = try self.run(base);
        const right = self.captureState();
        self.restore(original);
        self.active_frames = base;
        self.state_unknown = original.state_unknown or left.state_unknown or right.state_unknown;
        try self.mergeBindings(left, right);
        if (left.failure) |left_failure| {
            if (right.failure) |right_failure| {
                if (left_failure.signal == right_failure.signal) {
                    const payload = try self.join(left_failure.payload, right_failure.payload);
                    self.pending_failure = .{ .signal = left_failure.signal, .payload = payload };
                    return .{ .known = Value.err(left_failure.signal) };
                }
            }
        }
        return self.join(left_value, right_value);
    }

    fn finish(self: *Session, base: usize, index: usize, range: Code.OperandRange) Error!?Slot {
        const values = try self.operands(index, range);
        const destination = self.frames.items[index].destination;
        const count = self.frames.items[index].result_count;
        if (values.len != count) return error.ArityMismatch;
        self.active_frames -= 1;
        if (self.active_frames == base) {
            if (values.len != 1) return error.Unsupported;
            return values[0];
        }
        if (self.active_frames == 0) return error.InvalidCode;
        for (values, 0..) |value, i| {
            try self.frames.items[self.active_frames - 1].set(
                @fromBackingInt(@intCast(@backingInt(destination) + i)),
                value,
            );
        }
        return null;
    }

    fn run(self: *Session, base: usize) Error!Slot {
        errdefer self.active_frames = base;
        while (self.active_frames > base) {
            try self.charge(1);
            const result = self.step(base) catch |err| {
                try self.context.check();
                const failure = self.pending_failure;
                const payload = if (failure != null and failure.?.signal == err)
                    failure.?.payload
                else
                    Slot{ .known = Value.err(err) };
                if (try self.fail(base, payload, err)) |value| return value;
                continue;
            };
            if (result) |value| return value;
        }
        return error.InvalidCode;
    }

    fn step(self: *Session, base: usize) Error!?Slot {
        if (self.active_frames == 0) return error.InvalidCode;
        const index = self.active_frames - 1;
        const frame = self.frames.items[index];
        const block = frame.closure.code.blocks[@backingInt(frame.block)];
        if (frame.cursor < block.node_count) {
            const id = frame.closure.code.block_nodes[block.node_start + frame.cursor];
            self.frames.items[index].cursor += 1;
            try self.execute(index, frame.closure.code.nodes[@backingInt(id)]);
            return null;
        }
        switch (block.terminator) {
            .none => return error.InvalidCode,
            .jump => |edge| try self.jump(index, edge),
            .branch => |branch| {
                const condition = try frame.get(branch.condition);
                const selected = try self.branchDecision(condition);
                if (selected == null) return try self.explore(base, index, branch, condition);
                try self.jump(index, if (selected.?) branch.then_edge else branch.else_edge);
            },
            .return_values => |range| return self.finish(base, index, range),
            .raise => |id| return self.fail(base, try frame.get(id), error.Raised),
            .tail_call => |call_info| {
                const prepared = try self.prepareCall(
                    try frame.get(call_info.callee),
                    try self.operands(index, call_info.args),
                );
                // SAFETY: every non-tail branch assigns result before frame completion.
                var result: Slot = undefined;
                if (prepared.target) |known| {
                    if (known.typ == b.type_closure) {
                        const info = try self.closure(known);
                        if (self.registeredPrimitive(known)) |spec| {
                            if (call_info.result_count != 1) return error.Unsupported;
                            result = try self.native(frame.namespace, spec, prepared.args);
                        } else {
                            try self.push(
                                info,
                                prepared.args,
                                frame.destination,
                                call_info.result_count,
                                true,
                            );
                            return null;
                        }
                    } else {
                        if (call_info.result_count != 1) return error.Unsupported;
                        result = try self.immediate(frame.namespace, known, prepared.args);
                    }
                } else {
                    if (call_info.result_count != 1) return error.Unsupported;
                    result = try self.deferredCall(prepared.callee, prepared.args);
                }
                self.active_frames -= 1;
                if (self.active_frames == base) return result;
                if (self.active_frames == 0) return error.InvalidCode;
                try self.frames.items[self.active_frames - 1].set(frame.destination, result);
            },
        }
        return null;
    }

    fn source(self: *Session, namespace: usize, text: []const u8) Error!Slot {
        const parsed = try skript.Reader.readUnit(
            self.heap.runtime.store,
            text,
            .{ .retention = self.heap.runtime.source_retention },
        );
        const code = try Bind.bind(
            self.arena.allocator(),
            self.heap.runtime,
            self.namespaces.items[namespace].value,
            parsed.datum,
            null,
        );
        const value = try self.makeClosure(code, @fromBackingInt(@intCast(0)), namespace, &.{});
        return self.call(namespace, value, &.{});
    }
};

fn ancestorSession(context: *const Context) ?*Session {
    const reentry = context.reentry orelse return null;
    if (reentry.apply != bridgeApply) return null;
    if (reentry.source != bridgeSource) return null;
    if (reentry.lookup != bridgeLookup) return null;
    return @ptrCast(@alignCast(reentry.state));
}

const ValueArguments = struct {
    // SAFETY: init overwrites every small entry before returning its slice.
    small: [8]Value = undefined,
    allocated: []Value = &.{},

    fn init(
        self: *ValueArguments,
        comptime contents: enum { values, types },
        context: *Context,
        args: []const Slot,
    ) Error![]Value {
        try context.chargeWork(args.len, 1, .code);
        for (args) |argument| switch (argument) {
            .known => {},
            .unknown => |unknown| if (contents == .values or unknown.typ == null) return error.Unsupported,
            .empty => return error.InvalidCode,
        };
        const values = if (args.len <= self.small.len) self.small[0..args.len] else allocate: {
            self.allocated = try context.scratch.alloc(Value, args.len);
            break :allocate self.allocated;
        };
        for (args, values) |argument, *out| out.* = switch (argument) {
            .known => |value| value,
            // Method lookup reads type tags only. These payloads never reach invocation.
            .unknown => |unknown| Value.init(
                unknown.typ orelse return error.Unsupported,
                .null,
            ),
            .empty => unreachable,
        };
        return values;
    }

    fn deinit(self: *ValueArguments, allocator: std.mem.Allocator) void {
        allocator.free(self.allocated);
        self.* = undefined;
    }
};

fn isKeyword(value: Value, text: []const u8) bool {
    return value.typ == b.type_keyword and std.mem.eql(u8, value.obj.toPtr(Code.Symbol).*, text);
}

fn isBuiltinNamespace(table: *const skript.Namespace) bool {
    inline for (.{ skript.HashMapNamespace.vtable, skript.SmallNamespace.vtable }) |known| {
        if (table.get == known.get and table.set == known.set and table.bind == known.bind and
            table.unbind == known.unbind and table.contains == known.contains and
            table.parent == known.parent) return true;
    }
    return false;
}

fn bridgeApply(
    state: *anyopaque,
    context: *Context,
    namespace: Value,
    callable: Value,
    args: []const Value,
) Error!Value {
    const self: *Session = @ptrCast(@alignCast(state));
    if (context.runtime != self.heap.runtime) return error.Denied;
    const id = self.namespace_handles.get(namespace.obj) orelse return error.Denied;
    const previous = self.context;
    self.context = try context.enter(.code);
    defer self.context = previous;
    const scope = self.context.activate();
    defer scope.deinit();
    var small: [8]Slot = undefined;
    const slots = if (args.len <= small.len) small[0..args.len] else try context.scratch.alloc(Slot, args.len);
    defer if (args.len > small.len) context.scratch.free(slots);
    try self.charge(args.len);
    for (args, slots) |argument, *out| out.* = .{ .known = argument };
    const result = try self.call(id, callable, slots);
    if (self.pending_failure) |failure| return failure.signal;
    if (result == .unknown) self.unknown_callback = true;
    return result.requireKnown();
}

fn bridgeSource(state: *anyopaque, context: *Context, source: []const u8) Error!Value {
    const self: *Session = @ptrCast(@alignCast(state));
    if (context.runtime != self.heap.runtime or self.active_frames == 0) return error.Denied;
    const namespace = self.frames.items[self.active_frames - 1].namespace;
    const previous = self.context;
    self.context = try context.enter(.code);
    defer self.context = previous;
    const scope = self.context.activate();
    defer scope.deinit();
    self.pending_failure = null;
    const result = try self.source(namespace, source);
    if (result == .unknown) self.unknown_callback = true;
    return (try result.requireKnown()).unwrapError();
}

fn bridgeLookup(state: *anyopaque, context: *Context, namespace: Value, name: Code.Symbol) Error!Value {
    const self: *Session = @ptrCast(@alignCast(state));
    if (context.runtime != self.heap.runtime) return error.Denied;
    const id = self.namespace_handles.get(namespace.obj) orelse return error.Denied;
    const previous = self.context;
    self.context = try context.enter(.code);
    defer self.context = previous;
    const scope = self.context.activate();
    defer scope.deinit();
    self.pending_failure = null;
    const result = try self.readNamespace(id, name);
    if (result == .unknown) self.unknown_callback = true;
    return result.requireKnown();
}

const TestEnvironment = struct {
    // SAFETY: init assigns each field before any test operation reads it.
    runtime: *skript.Runtime = undefined,
    // SAFETY: init assigns each field before any test operation reads it.
    ledger: Context.Budget = undefined,
    // SAFETY: init assigns each field before any test operation reads it.
    lease: Context.Budget.Lease = undefined,
    // SAFETY: init assigns each field before any test operation reads it.
    account: Context.Budget.AccountAllocator = undefined,
    // SAFETY: init assigns each field before any test operation reads it.
    context: Context = undefined,
    // SAFETY: init assigns each field before any test operation reads it.
    output: [128]u8 = undefined,
    // SAFETY: init assigns each field before any test operation reads it.
    writer: std.Io.Writer = undefined,

    fn init(self: *TestEnvironment, mode: Context.Mode) !void {
        self.runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
        errdefer self.runtime.deinit();
        self.ledger = Context.Budget.init(std.testing.io, 7100, .{
            .work = 10000000,
            .bytes = 256 * 1024 * 1024,
        });
        self.lease = try Context.Budget.Lease.root(&self.ledger, 10000000);
        self.account = Context.Budget.AccountAllocator.init(std.testing.allocator, &self.lease, .code);
        self.writer = .fixed(&self.output);
        self.context = try Context.limited(
            self.runtime,
            self.runtime.intrinsics.registryVersion(),
            &self.account,
            .{ .writer = &self.writer, .bounded_memory = true },
            .{ .mode = mode, .effects = .{ .state_read = .allow, .state_write = .allow } },
        );
    }

    fn deinit(self: *TestEnvironment) void {
        self.runtime.deinit();
        self.* = undefined;
    }
};

test "modeled apply forwards proper lists at top level and inside closures" {
    var environment: TestEnvironment = .{};
    try environment.init(.dry);
    defer environment.deinit();
    const runtime = environment.runtime;
    const plus = try runtime.evalString("@i64.add");
    const spread = try skript.intrinsics.list.list(runtime.context(), .nil, .nil, &.{Value.i64(4)});
    const top = try evaluate(
        &environment.context,
        runtime.root_ns,
        Value.intrinsic(&skript.intrinsics.list.apply),
        &.{ plus, Value.i64(3), spread },
    );
    defer top.deinit();
    try std.testing.expectEqual(Value.i64(7), try top.exportValue());
    const closure = try runtime.evalString("(fn () (apply @i64.add 3 (list 4)))");
    const nested = try evaluate(&environment.context, runtime.root_ns, closure, &.{});
    defer nested.deinit();
    try std.testing.expectEqual(Value.i64(7), try nested.exportValue());
}

test "modeled apply rejects improper spreads and preserves target effects" {
    var environment: TestEnvironment = .{};
    try environment.init(.dry);
    defer environment.deinit();
    const runtime = environment.runtime;
    const plus = try runtime.evalString("@i64.add");
    try std.testing.expectError(
        error.ArityMismatch,
        evaluate(&environment.context, runtime.root_ns, Value.intrinsic(&skript.intrinsics.list.apply), &.{plus}),
    );
    try std.testing.expectError(
        error.TypeMismatch,
        evaluate(
            &environment.context,
            runtime.root_ns,
            Value.intrinsic(&skript.intrinsics.list.apply),
            &.{ plus, Value.i64(2) },
        ),
    );
    const body = try runtime.evalString("(fn () (apply @write (list \"deferred output\")))");
    const result = try evaluate(&environment.context, runtime.root_ns, body, &.{});
    defer result.deinit();
    try std.testing.expect(result.hasDeferred());
    try std.testing.expectEqual(@as(usize, 1), result.effects().len);
    const effect = result.effects()[0];
    const primitive = switch (effect.invocation) {
        .primitive => |invocation| invocation,
        .call => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("write", environment.context.registry.spec(primitive.id).?.stable_name);
    try std.testing.expectEqual(@as(usize, 1), effect.arguments.len);
    try std.testing.expectEqual(@as(usize, 0), environment.writer.buffered().len);
}

test "unknown modeled apply spread keeps target and unknown effects without running it" {
    var environment: TestEnvironment = .{};
    try environment.init(.abstract);
    defer environment.deinit();
    const runtime = environment.runtime;
    const model: Model = .{
        .version = .{ .id = 913, .revision = 1 },
        .lift_literal = try runtime.evalString(
            "(fn (value) (if (int? value) (if (= value 17) (list :unknown nil) :default) :default))",
        ),
        .invoke_primitive = try runtime.evalString("(fn (primitive arguments) :default)"),
        .decide_branch = try runtime.evalString("(fn (condition) :default)"),
        .join = try runtime.evalString("(fn (left right) :default)"),
    };
    environment.context.model = model.version;
    const callable = try runtime.evalString("(fn (spread) (apply @write spread))");
    const result = try evaluateWithModel(&environment.context, runtime.root_ns, callable, &.{Value.i64(17)}, model);
    defer result.deinit();
    try std.testing.expect(result.hasDeferred());
    try std.testing.expectError(error.Unsupported, result.exportValue());
    try std.testing.expectEqual(@as(usize, 1), result.effects().len);
    const effect = result.effects()[0];
    try std.testing.expect(effect.effects.unknown);
    const invoked = switch (effect.invocation) {
        .call => |target| target.*,
        .primitive => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        Value.intrinsic(&skript.intrinsics.list.apply),
        try invoked.requireKnown(),
    );
    try std.testing.expectEqual(@as(usize, 2), effect.arguments.len);
    try std.testing.expectEqual(try runtime.evalString("@write"), try effect.arguments[0].requireKnown());
    try std.testing.expect(effect.arguments[1] == .unknown);
    try std.testing.expectEqual(@as(usize, 0), environment.writer.buffered().len);
}

test "alternate evaluation denies direct parent and qualified source scalars" {
    var environment: TestEnvironment = .{};
    try environment.init(.dry);
    defer environment.deinit();
    const runtime = environment.runtime;
    try runtime.nsBind(
        runtime.root_ns,
        try runtime.store.getsym("eval-policy-secret"),
        Value.i64(17),
    );
    try runtime.nsBind(
        runtime.root_ns,
        try runtime.store.getsym("eval-policy-bag"),
        runtime.root_ns,
    );
    environment.context.effects.state_read = .deny;
    for ([_][]const u8{
        "(fn () eval-policy-secret)",
        "(fn () (let ((local 1)) eval-policy-secret))",
        "(fn () eval-policy-bag/eval-policy-secret)",
    }) |source| {
        const callable = try runtime.evalString(source);
        const result = try evaluate(
            &environment.context,
            runtime.root_ns,
            callable,
            &.{},
        );
        defer result.deinit();
        const exported = try result.exportValue();
        try std.testing.expectError(error.Denied, exported.unwrapError());
    }
}

test "alternate evaluation permits callable and type source bindings" {
    var environment: TestEnvironment = .{};
    try environment.init(.dry);
    defer environment.deinit();
    const runtime = environment.runtime;
    const allowed = try runtime.evalString("(fn () 42)");
    try runtime.nsBind(
        runtime.root_ns,
        try runtime.store.getsym("eval-policy-callable"),
        allowed,
    );
    try runtime.nsBind(
        runtime.root_ns,
        try runtime.store.getsym("eval-policy-type"),
        Value.typeValue(b.type_i64),
    );
    try runtime.nsBind(
        runtime.root_ns,
        try runtime.store.getsym("eval-policy-bag"),
        runtime.root_ns,
    );
    environment.context.effects.state_read = .deny;
    for ([_]struct { source: []const u8, expected: Value }{
        .{ .source = "(fn () (eval-policy-callable))", .expected = Value.i64(42) },
        .{
            .source = "(fn () (eval-policy-bag/eval-policy-callable))",
            .expected = Value.i64(42),
        },
        .{ .source = "(fn () eval-policy-type)", .expected = Value.typeValue(b.type_i64) },
    }) |case| {
        const callable = try runtime.evalString(case.source);
        const result = try evaluate(
            &environment.context,
            runtime.root_ns,
            callable,
            &.{},
        );
        defer result.deinit();
        try std.testing.expectEqual(case.expected, try result.exportValue());
    }
}

test "alternate evaluation permits evaluator-owned overlays" {
    var environment: TestEnvironment = .{};
    try environment.init(.dry);
    defer environment.deinit();
    const runtime = environment.runtime;
    environment.context.effects.state_read = .deny;
    environment.context.effects.state_write = .deny;
    const callable = try runtime.evalString(
        "(fn () (def eval-policy-overlay 23) eval-policy-overlay)",
    );
    const result = try evaluate(
        &environment.context,
        runtime.root_ns,
        callable,
        &.{},
    );
    defer result.deinit();
    try std.testing.expectEqual(Value.i64(23), try result.exportValue());
}

test "evaluator model hooks cannot read cached source scalars" {
    var environment: TestEnvironment = .{};
    try environment.init(.abstract);
    defer environment.deinit();
    const runtime = environment.runtime;
    try runtime.nsBind(
        runtime.root_ns,
        try runtime.store.getsym("eval-policy-model-secret"),
        Value.i64(41),
    );
    const model: Model = .{
        .version = .{ .id = 96, .revision = 1 },
        .lift_literal = try runtime.evalString("(fn (value) :default)"),
        .invoke_primitive = try runtime.evalString(
            "(fn (primitive arguments) (list :known eval-policy-model-secret))",
        ),
        .decide_branch = try runtime.evalString("(fn (condition) :default)"),
        .join = try runtime.evalString("(fn (left right) :default)"),
    };
    environment.context.model = model.version;
    environment.context.effects.state_read = .allow;
    const callable = try runtime.evalString(
        "(fn () (+ eval-policy-model-secret 1))",
    );
    const result = try evaluateWithModel(
        &environment.context,
        runtime.root_ns,
        callable,
        &.{},
        model,
    );
    defer result.deinit();
    const exported = try result.exportValue();
    try std.testing.expectError(error.Denied, exported.unwrapError());
}

test "alternate evaluation cannot catch terminal allocation failure" {
    const Native = struct {
        fn invoke(
            _: *Context,
            _: Value,
            _: Value,
            _: []const Value,
        ) Error!Value {
            return error.OutOfMemory;
        }
    };
    var environment: TestEnvironment = .{};
    try environment.init(.dry);
    defer environment.deinit();
    const runtime = environment.runtime;
    environment.context.registry = try runtime.intrinsics.publish(&.{.{
        .stable_name = "test.evaluator-oom",
        .invoke = Primitive.Invocation.nativePtr(&Native.invoke),
        .effects = .none,
        .callbacks = .none,
        .resources = .{ .fixed = .{} },
        .suspension = .never,
    }});
    const callable = try runtime.evalString(
        "(fn () (try (@test.evaluator-oom) (catch failure 99)))",
    );
    try std.testing.expectError(
        error.OutOfMemory,
        evaluate(&environment.context, runtime.root_ns, callable, &.{}),
    );
}

test "alternate evaluation preserves denied argument state reads" {
    var environment: TestEnvironment = .{};
    try environment.init(.dry);
    defer environment.deinit();
    const runtime = environment.runtime;
    const callable = try runtime.evalString("(fn (m) (map-get m :secret))");
    const input = try runtime.evalString("(hash-map :secret 17)");
    environment.context.effects.state_read = .deny;
    const result = try evaluate(&environment.context, runtime.root_ns, callable, &.{input});
    defer result.deinit();
    try std.testing.expect(result.result == .unknown);
    try std.testing.expect(result.hasDeferred());
    try std.testing.expectError(error.Unsupported, result.exportValue());
}

test "evaluator model hooks preserve denied argument state reads" {
    var environment: TestEnvironment = .{};
    try environment.init(.abstract);
    defer environment.deinit();
    const runtime = environment.runtime;
    const model: Model = .{
        .version = .{ .id = 94, .revision = 1 },
        .lift_literal = try runtime.evalString(
            "(fn (value) (list :known (map-get value :secret)))",
        ),
        .invoke_primitive = try runtime.evalString("(fn (primitive arguments) :default)"),
        .decide_branch = try runtime.evalString("(fn (condition) :default)"),
        .join = try runtime.evalString("(fn (left right) :default)"),
    };
    environment.context.model = model.version;
    environment.context.effects.state_read = .deny;
    const callable = try runtime.evalString("(fn (m) m)");
    const input = try runtime.evalString("(hash-map :secret 17)");
    if (evaluateWithModel(&environment.context, runtime.root_ns, callable, &.{input}, model)) |result| {
        defer result.deinit();
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.Denied, err);
    }
}

test "alternate evaluation preserves qualified and intrinsic lookup" {
    var environment: TestEnvironment = .{};
    try environment.init(.dry);
    defer environment.deinit();
    const runtime = environment.runtime;
    try runtime.nsBind(runtime.root_ns, try runtime.store.getsym("bag"), runtime.root_ns);
    try runtime.nsBind(runtime.root_ns, try runtime.store.getsym("counter"), Value.i64(7));
    const callable = try runtime.evalString("(fn () (@i64.add bag/counter 5))");
    const result = try evaluate(&environment.context, runtime.root_ns, callable, &.{});
    defer result.deinit();
    try std.testing.expectEqual(Value.i64(12), try (try result.exportValue()).unwrapError());
}

test "alternate evaluation explores both unknown outcomes without output" {
    var environment: TestEnvironment = .{};
    try environment.init(.dry);
    defer environment.deinit();
    const runtime = environment.runtime;
    const callable = try runtime.evalString("(fn () (if (@receive) (@write \"enabled\") (@write \"disabled\")))");
    const result = try evaluate(&environment.context, runtime.root_ns, callable, &.{});
    defer result.deinit();
    try std.testing.expect(result.result == .unknown);
    try std.testing.expectEqual(@as(usize, 3), result.effects().len);
    try std.testing.expectEqualStrings(
        "enabled",
        std.mem.sliceTo(result.effects()[1].arguments[0].known.obj.toPtr([*:0]u8), 0),
    );
    try std.testing.expectEqualStrings(
        "disabled",
        std.mem.sliceTo(result.effects()[2].arguments[0].known.obj.toPtr([*:0]u8), 0),
    );
    try std.testing.expectEqual(@as(?u32, null), result.effects()[0].path);
    const enabled_path = result.paths()[
        result.effects()[1].path orelse
            return error.TestUnexpectedResult
    ];
    const disabled_path = result.paths()[
        result.effects()[2].path orelse
            return error.TestUnexpectedResult
    ];
    try std.testing.expect(enabled_path.selected);
    try std.testing.expect(!disabled_path.selected);
    try std.testing.expectEqual(enabled_path.condition.unknown.identity, disabled_path.condition.unknown.identity);
    try std.testing.expectEqual(enabled_path.parent, disabled_path.parent);
    try std.testing.expectEqual(@as(usize, 0), environment.writer.buffered().len);
}

test "alternate evaluation keeps uncaught raises as failures" {
    var environment: TestEnvironment = .{};
    try environment.init(.dry);
    defer environment.deinit();
    const runtime = environment.runtime;
    const callable = try runtime.evalString("(fn () (raise \"boom\"))");
    const result = try evaluate(&environment.context, runtime.root_ns, callable, &.{});
    defer result.deinit();
    try std.testing.expectError(error.Raised, (try result.exportValue()).unwrapError());
}

test "alternate evaluation restores handlers through nested calls" {
    var environment: TestEnvironment = .{};
    try environment.init(.dry);
    defer environment.deinit();
    const runtime = environment.runtime;
    const callable = try runtime.evalString(
        "(fn () (try ((fn () (raise 5))) (catch payload (+ payload 2))))",
    );
    const result = try evaluate(&environment.context, runtime.root_ns, callable, &.{});
    defer result.deinit();
    try std.testing.expectEqual(Value.i64(7), try (try result.exportValue()).unwrapError());
}

test "alternate evaluation cannot catch unknown path exhaustion" {
    var environment: TestEnvironment = .{};
    try environment.init(.abstract);
    defer environment.deinit();
    environment.ledger.limits.paths = 1;
    environment.ledger.remaining.paths = 1;
    const runtime = environment.runtime;
    const callable = try runtime.evalString(
        "(fn () (try (if (@receive) 3 5) (catch failure 99)))",
    );
    try std.testing.expectError(
        error.Exhausted,
        evaluate(&environment.context, runtime.root_ns, callable, &.{}),
    );
    const report = environment.ledger.report() orelse return error.TestExpectedExhaustion;
    try std.testing.expectEqual(Context.Budget.Resource.paths, report.resource);
    try std.testing.expectEqual(Context.Budget.Backend.code, report.backend);
}

test "Skript evaluator model lifts values and models a conditional receive" {
    var environment: TestEnvironment = .{};
    try environment.init(.abstract);
    defer environment.deinit();
    const runtime = environment.runtime;
    const receive_id_entry = environment.context.registry.find("receive") orelse
        return error.TestUnexpectedResult;
    const receive_id = receive_id_entry.id;
    try runtime.nsBind(runtime.root_ns, try runtime.store.getsym("receive-id"), Value.i64(@backingInt(receive_id)));
    const model: Model = .{
        .version = .{ .id = 71, .revision = 3 },
        .lift_literal = try runtime.evalString("(fn (value) (if (number? value) (list :known (+ value 10)) :default))"),
        .invoke_primitive = try runtime.evalString(
            "(fn (primitive arguments) (if (= (map-get primitive :id) receive-id) (list :unknown @Bool) :default))",
        ),
        .decide_branch = try runtime.evalString("(fn (condition) :both)"),
        .join = try runtime.evalString("(fn (left right) :default)"),
    };
    environment.context.model = model.version;
    environment.context.effects = .{
        .state_read = .allow,
        .state_write = .{ .model = model.version },
        .process = .{ .model = model.version },
        .clock = .{ .model = model.version },
    };
    const callable = try runtime.evalString("(fn () (if (@receive) (+ 1 2) (+ 2 1)))");
    const result = try evaluateWithModel(&environment.context, runtime.root_ns, callable, &.{}, model);
    defer result.deinit();
    try std.testing.expectEqual(Value.i64(23), try (try result.exportValue()).unwrapError());
    try std.testing.expectEqual(model.version, result.effects()[0].model.?);
    try std.testing.expectEqual(@as(?Object, b.type_bool), result.effects()[0].result.unknown.typ);
    try std.testing.expectEqual(@as(usize, 0), environment.writer.buffered().len);
}

test "evaluator primitive models see bound and explicit arithmetic alike" {
    var environment: TestEnvironment = .{};
    try environment.init(.abstract);
    defer environment.deinit();
    const runtime = environment.runtime;
    const add_id = environment.context.registry.find("f64.add") orelse
        return error.TestUnexpectedResult;
    try runtime.nsBind(
        runtime.root_ns,
        try runtime.store.getsym("modeled-add"),
        Value.i64(@backingInt(add_id.id)),
    );
    const model: Model = .{
        .version = .{ .id = 95, .revision = 1 },
        .lift_literal = try runtime.evalString("(fn (value) (if (f64? value) (list :unknown @f64) :default))"),
        .invoke_primitive = try runtime.evalString(
            "(fn (primitive arguments) (if (= (map-get primitive :id) modeled-add) (list :known 41.0) :default))",
        ),
        .decide_branch = try runtime.evalString("(fn (condition) :default)"),
        .join = try runtime.evalString("(fn (left right) :default)"),
    };
    environment.context.model = model.version;
    for ([_][]const u8{ "(fn (x) (+ x 1.0))", "(fn (x) (@f64.add x 1.0))" }) |source| {
        const callable = try runtime.evalString(source);
        const result = try evaluateWithModel(&environment.context, runtime.root_ns, callable, &.{.f64(2.0)}, model);
        defer result.deinit();
        try std.testing.expectEqual(Value.f64(41.0), try (try result.exportValue()).unwrapError());
    }
}

test "alternate evaluation reenters pure native callbacks" {
    var environment: TestEnvironment = .{};
    try environment.init(.dry);
    defer environment.deinit();
    const callable = try environment.runtime.evalString("(fn () (fold (list 1 2 3) (fn (a b) (+ a b))))");
    const result = try evaluate(&environment.context, environment.runtime.root_ns, callable, &.{});
    defer result.deinit();
    try std.testing.expectEqual(Value.i64(6), try result.exportValue());
}

test "alternate evaluation unwinds raised callback payloads" {
    var environment: TestEnvironment = .{};
    try environment.init(.dry);
    defer environment.deinit();
    const callable = try environment.runtime.evalString(
        "(fn () (try (fold (list 1 2) (fn (a b) (raise 7))) (catch payload (+ payload 1))))",
    );
    const result = try evaluate(&environment.context, environment.runtime.root_ns, callable, &.{});
    defer result.deinit();
    try std.testing.expectEqual(Value.i64(8), try result.exportValue());
}

test "abstract evaluation joins exact integer branch ranges" {
    var environment: TestEnvironment = .{};
    try environment.init(.abstract);
    defer environment.deinit();
    const callable = try environment.runtime.evalString(
        "(fn () (if (@receive) 9007199254740993 9007199254740995))",
    );
    const result = try evaluate(&environment.context, environment.runtime.root_ns, callable, &.{});
    defer result.deinit();
    try std.testing.expect(result.result == .unknown);
    try std.testing.expectEqual(
        @as(?Domain.I64Range, .{ .lower = 9007199254740993, .upper = 9007199254740995 }),
        result.result.unknown.i64_range,
    );
}

test "abstract arithmetic preserves unknown input identity" {
    var environment: TestEnvironment = .{};
    try environment.init(.abstract);
    defer environment.deinit();
    const runtime = environment.runtime;
    const Native = struct {
        fn invoke(ctx: *Context, _: Value, _: Value, args: []const Value) Error!Value {
            if (args.len != 0) return error.ArityMismatch;
            return ctx.runtime.evalString("(= eval-probe-x eval-probe-x)");
        }
    };
    environment.context.registry = try runtime.intrinsics.publish(&.{.{
        .stable_name = "test.source-reentry",
        .invoke = Primitive.Invocation.nativePtr(&Native.invoke),
        .effects = .{ .state_read = true },
        .callbacks = .unknown,
        .resources = .native,
        .suspension = .never,
    }});
    const model: Model = .{
        .version = .{ .id = 82, .revision = 1 },
        .lift_literal = try runtime.evalString("(fn (value) (if (int? value) (list :unknown @i64) :default))"),
        .invoke_primitive = try runtime.evalString("(fn (primitive arguments) :default)"),
        .decide_branch = try runtime.evalString("(fn (condition) :default)"),
        .join = try runtime.evalString("(fn (left right) :default)"),
    };
    const callable = try runtime.evalString("(fn (x) (= x x))");
    const result = try evaluateWithModel(&environment.context, runtime.root_ns, callable, &.{Value.i64(3)}, model);
    defer result.deinit();
    try std.testing.expectEqual(Value.true, try result.exportValue());
    const reentrant = try runtime.evalString("(fn (x) (def eval-probe-x x) (@test.source-reentry))");
    const nested = try evaluateWithModel(&environment.context, runtime.root_ns, reentrant, &.{Value.i64(3)}, model);
    defer nested.deinit();
    try std.testing.expectEqual(Value.true, try (try nested.exportValue()).unwrapError());
}

test "alternate evaluation does not export a value past deferred work" {
    var environment: TestEnvironment = .{};
    try environment.init(.dry);
    defer environment.deinit();
    const callable = try environment.runtime.evalString("(fn () (@receive) 7)");
    const result = try evaluate(&environment.context, environment.runtime.root_ns, callable, &.{});
    defer result.deinit();
    try std.testing.expectError(error.Unsupported, result.exportValue());
}

test "alternate evaluation retains opaque calls and invalidates unknown writes" {
    var environment: TestEnvironment = .{};
    try environment.init(.dry);
    defer environment.deinit();
    const callable = try environment.runtime.evalString(
        "(def eval-opaque-global 9) (fn () (let ((operation (@receive))) (operation 1) eval-opaque-global))",
    );
    const result = try evaluate(&environment.context, environment.runtime.root_ns, callable, &.{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.effects().len);
    try std.testing.expect(result.effects()[1].effects.unknown);
    try std.testing.expect(result.result == .unknown);
    try std.testing.expectError(error.Unsupported, result.exportValue());
    try std.testing.expectEqual(@as(usize, 0), environment.writer.buffered().len);
}

test "alternate evaluation rejects executable values nested in data" {
    var environment: TestEnvironment = .{};
    try environment.init(.dry);
    defer environment.deinit();
    const runtime = environment.runtime;
    const callable = try runtime.evalString("(fn () (list (fn () 42)))");
    const result = try evaluate(
        &environment.context,
        runtime.root_ns,
        callable,
        &.{},
    );
    defer result.deinit();
    try std.testing.expectError(error.Unsupported, result.exportValue());
    try std.testing.expectError(
        error.TypeMismatch,
        runtime.evalString(
            "(def eval-escaped-report " ++
                "(evaluate (fn () (list (fn () 42))) nil :dry)) " ++
                "(def eval-escaped (fst (map-get eval-escaped-report :value))) " ++
                "(eval-escaped)",
        ),
    );
}

test "registered closure primitives cross the evaluator policy boundary" {
    var environment: TestEnvironment = .{};
    try environment.init(.dry);
    defer environment.deinit();
    const runtime = environment.runtime;
    const implementation = try runtime.evalString("(fn () 1)");
    const registry = try runtime.intrinsics.publish(&.{.{
        .stable_name = "test.modeled",
        .invoke = Primitive.Invocation.closureValue(implementation),
        .effects = .{ .io = true },
        .callbacks = .none,
        .resources = .{ .bounded = .{ .work = 7 } },
        .suspension = .never,
    }});
    environment.context.registry = registry;
    const model: Model = .{
        .version = .{ .id = 93, .revision = 1 },
        .lift_literal = try runtime.evalString("(fn (value) :default)"),
        .invoke_primitive = try runtime.evalString(
            "(fn (primitive arguments) " ++
                "(if (= (map-get primitive :name) \"test.modeled\") " ++
                "(list :known 17) :default))",
        ),
        .decide_branch = try runtime.evalString("(fn (condition) :default)"),
        .join = try runtime.evalString("(fn (left right) :default)"),
    };
    environment.context.model = model.version;
    environment.context.effects.io = .{ .model = model.version };
    const callable = try runtime.evalString("(fn () (@test.modeled))");
    const modeled = try evaluateWithModel(
        &environment.context,
        runtime.root_ns,
        callable,
        &.{},
        model,
    );
    defer modeled.deinit();
    try std.testing.expectEqual(Value.i64(17), try modeled.exportValue());
    try std.testing.expectEqual(@as(usize, 1), modeled.effects().len);
    try std.testing.expectEqual(model.version, modeled.effects()[0].model.?);
    switch (modeled.effects()[0].invocation) {
        .primitive => |invocation| {
            try std.testing.expectEqual(registry.find("test.modeled").?.id, invocation.id);
        },
        .call => return error.TestExpectedPrimitiveEffect,
    }
    const dynamic_callable = try runtime.evalString(
        "(fn () (let ((operation @test.modeled)) (operation)))",
    );
    const dynamic = try evaluateWithModel(
        &environment.context,
        runtime.root_ns,
        dynamic_callable,
        &.{},
        model,
    );
    defer dynamic.deinit();
    try std.testing.expectEqual(Value.i64(17), try dynamic.exportValue());

    environment.context.model = null;
    environment.context.effects.io = .deny;
    const deferred = try evaluate(
        &environment.context,
        runtime.root_ns,
        callable,
        &.{},
    );
    defer deferred.deinit();
    try std.testing.expect(deferred.result == .unknown);
    try std.testing.expect(deferred.hasDeferred());
    try std.testing.expectEqual(@as(usize, 1), deferred.effects().len);
}

test "nested evaluation accepts verified ancestor Code only" {
    var environment: TestEnvironment = .{};
    try environment.init(.dry);
    defer environment.deinit();
    const runtime = environment.runtime;
    try std.testing.expectEqual(
        Value.i64(42),
        try runtime.evalString(
            "(map-get (map-get " ++
                "(evaluate (fn () (evaluate (fn () 42) nil :dry)) nil :dry) " ++
                ":value) :value)",
        ),
    );
    try std.testing.expectEqual(
        Value.i64(43),
        try runtime.evalString(
            "(map-get (map-get " ++
                "(evaluate (fn () " ++
                "(let ((captured 43)) (evaluate (fn () captured) nil :dry))) " ++
                "nil :dry) :value) :value)",
        ),
    );

    const foreign = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer foreign.deinit();
    const foreign_callable = try foreign.evalString("(fn () 99)");
    try std.testing.expectError(
        error.InvalidCode,
        evaluate(
            &environment.context,
            runtime.root_ns,
            foreign_callable,
            &.{},
        ),
    );
}

test "effect records retain immutable aliased value snapshots" {
    const runtime = try skript.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    _ = try runtime.evalString(
        "(def eval-snapshot-model " ++
            "(hash-map :id 93 :revision 1 " ++
            ":lift-literal (fn (value) :default) " ++
            ":invoke-primitive (fn (primitive arguments) " ++
            "(if (= (map-get primitive :name) \"write\") " ++
            "(list :known 17) :default)) " ++
            ":decide-branch (fn (condition) :default) " ++
            ":join (fn (left right) :default))) " ++
            "(def eval-snapshot-report " ++
            "(evaluate (fn () " ++
            "(let ((m (hash-map :k 1))) (@write m) (map-set! m :k 2))) " ++
            "nil :dry eval-snapshot-model))",
    );
    try std.testing.expectEqual(
        Value.i64(1),
        try runtime.evalString(
            "(map-get (map-get " ++
                "(fst (map-get (fst (map-get eval-snapshot-report :effects)) " ++
                ":arguments)) :value) :k)",
        ),
    );

    _ = try runtime.evalString(
        "(def eval-alias-model " ++
            "(hash-map :id 94 :revision 1 " ++
            ":lift-literal (fn (value) :default) " ++
            ":invoke-primitive (fn (primitive arguments) " ++
            "(if (= (map-get primitive :name) \"write\") " ++
            "(list :known (fst (rst (fst arguments)))) :default)) " ++
            ":decide-branch (fn (condition) :default) " ++
            ":join (fn (left right) :default))) " ++
            "(def eval-alias-report " ++
            "(evaluate (fn () " ++
            "(let ((m (hash-map :k 1))) " ++
            "(let ((modeled (@write m))) " ++
            "(map-set! m :k 2) (map-set! modeled :k 3)))) " ++
            "nil :dry eval-alias-model)) " ++
            "(def eval-alias-effect (fst (map-get eval-alias-report :effects))) " ++
            "(def eval-alias-argument " ++
            "(map-get (fst (map-get eval-alias-effect :arguments)) :value)) " ++
            "(def eval-alias-result " ++
            "(map-get (map-get eval-alias-effect :result) :value))",
    );
    try std.testing.expectEqual(
        Value.i64(1),
        try runtime.evalString("(map-get eval-alias-argument :k)"),
    );
    try std.testing.expectEqual(
        Value.i64(1),
        try runtime.evalString("(map-get eval-alias-result :k)"),
    );
}

test "alternate evaluators reject variadic closure calls but preserve fixed arity" {
    for ([_]Context.Mode{ .dry, .abstract }) |mode| {
        var environment: TestEnvironment = .{};
        try environment.init(mode);
        defer environment.deinit();
        const runtime = environment.runtime;
        const fixed = try runtime.evalString("(fn (value) value)");
        const fixed_result = try evaluate(
            &environment.context,
            runtime.root_ns,
            fixed,
            &.{Value.i64(41)},
        );
        defer fixed_result.deinit();
        try std.testing.expectEqual(Value.i64(41), try fixed_result.exportValue());
        try std.testing.expectError(
            error.ArityMismatch,
            evaluate(&environment.context, runtime.root_ns, fixed, &.{ Value.i64(41), Value.i64(42) }),
        );

        const variadic = try runtime.evalString("(fn (head . rest) rest)");
        try std.testing.expectError(
            error.Unsupported,
            evaluate(&environment.context, runtime.root_ns, variadic, &.{Value.i64(1)}),
        );
        try std.testing.expectError(
            error.Unsupported,
            evaluate(&environment.context, runtime.root_ns, variadic, &.{ Value.i64(1), Value.i64(2) }),
        );
        try std.testing.expectError(
            error.Unsupported,
            evaluate(
                &environment.context,
                runtime.root_ns,
                variadic,
                &.{ Value.i64(1), Value.i64(2), Value.i64(3) },
            ),
        );
    }
}
