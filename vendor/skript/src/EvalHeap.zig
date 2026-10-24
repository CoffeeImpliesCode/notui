const std = @import("std");
const skript = @import("root.zig");

const Allocator = std.mem.Allocator;
const Value = skript.Value;
const Object = skript.Object;
const Sym = skript.Sym;
const Runtime = skript.Runtime;
const EvalContext = skript.EvalContext;
const Store = skript.Store;
const FuncPtr = skript.FuncPtr;
const Budget = @import("Budget.zig");
const Closure = skript.data.Closure;
const Method = skript.data.Method;
const ErrorObj = skript.data.ErrorObj;
const Map = skript.data.RuntimeMap;
const MapHolder = skript.data.MapHolder;
const TensorMod = @import("intrinsics/tensor.zig");
const TensorHolder = TensorMod.TensorHolder;
const InnerType = TensorMod.InnerType;

const EvalHeap = @This();
pub const Heap = EvalHeap;
pub const Error = skript.Error;
pub const InitError = Error ||
    @typeInfo(@typeInfo(@TypeOf(Runtime.initWithConfig)).@"fn".return_type.?).error_union.error_set;

/// Private evaluator state. The Runtime owns every object reachable from
/// `runtime`; the caller owns the budget lineage and the base allocator.
runtime: *Runtime,
parent_runtime: *Runtime,
budget: *Budget,
allocation_allocator: Allocator,
account: Budget.AccountAllocator,
lease: Budget.Lease,
output_storage: []u8,
output_writer: std.Io.Writer,
import_objects: ObjectMap,
import_u32_slices: U32SliceMap,
import_tensors: TensorMemo,
export_tensors: TensorMemo,
runtime_roots: Store.RootProvider,
parent_roots: Store.RootProvider,

const IdentityKey = struct {
    runtime_identity: u64,
    object: Object,
};

const ObjectMap = std.AutoHashMap(IdentityKey, Value);
const U32SliceCopy = struct {
    slice: []u32,
    ref: Store.Ref,
};
const U32SliceMap = std.AutoHashMap(*const anyopaque, U32SliceCopy);

const TensorTransfer = struct {
    source_runtime: *Runtime,
    destination_runtime: *Runtime,

    fn eql(self: TensorTransfer, other: TensorTransfer) bool {
        if (self.source_runtime != other.source_runtime) return false;
        return self.destination_runtime == other.destination_runtime;
    }
};

const ByteRange = struct {
    start: usize,
    end: usize,

    fn init(source: []const u64) Error!ByteRange {
        const size_bytes = std.math.mul(
            usize,
            source.len,
            @sizeOf(u64),
        ) catch return error.Unsupported;
        const start = @intFromPtr(source.ptr);
        const end = std.math.add(usize, start, size_bytes) catch
            return error.Unsupported;
        return .{ .start = start, .end = end };
    }

    fn overlaps(self: ByteRange, other: ByteRange) bool {
        return self.start < other.end and other.start < self.end;
    }

    fn contains(self: ByteRange, other: ByteRange) bool {
        if (self.start > other.start) return false;
        return other.end <= self.end;
    }

    fn elementCount(self: ByteRange) Error!usize {
        if (self.start > self.end) return error.Unsupported;
        const size_bytes = self.end - self.start;
        if (size_bytes % @sizeOf(u64) != 0) return error.Unsupported;
        return @divExact(size_bytes, @sizeOf(u64));
    }
};

const ElementBounds = struct {
    start: usize,
    end: usize,
};

fn elementBounds(
    container: ByteRange,
    target: ByteRange,
    element_count: usize,
) Error!ElementBounds {
    if (!container.contains(target)) return error.Unsupported;
    if (try container.elementCount() != element_count) return error.Unsupported;

    const start_bytes = target.start - container.start;
    const end_bytes = target.end - container.start;
    if (start_bytes % @sizeOf(u64) != 0) return error.Unsupported;
    if (end_bytes % @sizeOf(u64) != 0) return error.Unsupported;
    const start = @divExact(start_bytes, @sizeOf(u64));
    const end = @divExact(end_bytes, @sizeOf(u64));
    if (start > end) return error.Unsupported;
    if (end > element_count) return error.Unsupported;
    return .{ .start = start, .end = end };
}

const TensorBacking = struct {
    transfer: TensorTransfer,
    inner: InnerType,
    source: ByteRange,
    destination: []u64,
    ref: Store.Ref,

    fn slice(self: TensorBacking, source: ByteRange) Error![]u64 {
        const bounds = try elementBounds(
            self.source,
            source,
            self.destination.len,
        );
        return self.destination[bounds.start..bounds.end];
    }
};

const TensorSource = struct {
    transfer: TensorTransfer,
    inner: InnerType,
    range: ByteRange,
};

const TensorDataCopy = struct {
    data: []u64,
    ref: Store.Ref,
    source: ?TensorSource,
};

const TensorBinding = struct {
    source: TensorSource,
    holder: *TensorHolder,
    holder_ref: Store.Ref,
};

fn chargeTensorScan(
    context: *EvalContext,
    count: usize,
    backend: Budget.Backend,
) Error!void {
    const work = std.math.cast(u64, count) orelse return error.Unsupported;
    try context.chargeWork(work, 1, backend);
}

const TensorMemo = struct {
    // A backing interval owns private words for one source/destination pair.
    // Bindings let a later enlargement retarget every already-copied view.
    allocator: Allocator,
    backings: std.ArrayListUnmanaged(TensorBacking) = .empty,
    bindings: std.ArrayListUnmanaged(TensorBinding) = .empty,

    fn init(allocator: Allocator) TensorMemo {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *TensorMemo) void {
        self.backings.deinit(self.allocator);
        self.bindings.deinit(self.allocator);
        self.* = undefined;
    }

    fn commit(
        self: *TensorMemo,
        staged_backings: []const TensorBacking,
        staged_bindings: []const TensorBinding,
        context: *EvalContext,
        backend: Budget.Backend,
    ) Error!void {
        const existing_backing_scan_count = std.math.mul(
            usize,
            staged_backings.len,
            self.backings.items.len,
        ) catch return error.Unsupported;
        var staged_pair_product: usize = 0;
        if (staged_backings.len >= 2) {
            staged_pair_product = std.math.mul(
                usize,
                staged_backings.len,
                staged_backings.len - 1,
            ) catch return error.Unsupported;
        }
        const staged_backing_scan_count = std.math.add(
            usize,
            existing_backing_scan_count,
            @divExact(staged_pair_product, 2),
        ) catch return error.Unsupported;
        const binding_scan_count = std.math.mul(
            usize,
            staged_backings.len,
            self.bindings.items.len,
        ) catch return error.Unsupported;
        const staged_backing_iteration_count = std.math.mul(
            usize,
            staged_backings.len,
            2,
        ) catch return error.Unsupported;
        var commit_work_count = std.math.add(
            usize,
            staged_backing_scan_count,
            binding_scan_count,
        ) catch return error.Unsupported;
        commit_work_count = std.math.add(
            usize,
            commit_work_count,
            staged_backing_iteration_count,
        ) catch return error.Unsupported;
        commit_work_count = std.math.add(
            usize,
            commit_work_count,
            staged_bindings.len,
        ) catch return error.Unsupported;
        try chargeTensorScan(context, commit_work_count, backend);

        for (staged_backings) |backing| {
            var index: usize = 0;
            while (index < self.backings.items.len) {
                const existing = self.backings.items[index];
                if (!existing.transfer.eql(backing.transfer)) {
                    index += 1;
                    continue;
                }
                if (!existing.source.overlaps(backing.source)) {
                    index += 1;
                    continue;
                }
                std.debug.assert(existing.inner == backing.inner);
                std.debug.assert(backing.source.contains(existing.source));
                _ = self.backings.swapRemove(index);
            }
            self.backings.appendAssumeCapacity(backing);
        }

        for (staged_backings) |backing| {
            for (self.bindings.items) |binding| {
                if (!binding.source.transfer.eql(backing.transfer)) continue;
                if (binding.source.inner != backing.inner) continue;
                if (!backing.source.contains(binding.source.range)) continue;
                const data = try backing.slice(binding.source.range);
                binding.holder.data = data;
                binding.holder.data_ref = backing.ref;
            }
        }

        for (staged_bindings) |binding| {
            self.bindings.appendAssumeCapacity(binding);
        }
    }
};
fn traceTensorMemoRoots(memo: *const TensorMemo, visitor: *Store.MarkVisitor) anyerror!void {
    for (memo.backings.items) |backing| try visitor.visit(backing.ref);
    for (memo.bindings.items) |binding| try visitor.visit(binding.holder_ref);
}

fn traceRuntimeHeapRoots(context: *anyopaque, visitor: *Store.MarkVisitor) anyerror!void {
    const heap: *Heap = @ptrCast(@alignCast(context));
    var imported_values = heap.import_objects.valueIterator();
    while (imported_values.next()) |value| try visitor.visitValue(value.*);
    var copied_shapes = heap.import_u32_slices.valueIterator();
    while (copied_shapes.next()) |copy| try visitor.visit(copy.ref);
    try traceTensorMemoRoots(&heap.import_tensors, visitor);
}

fn traceParentHeapRoots(context: *anyopaque, visitor: *Store.MarkVisitor) anyerror!void {
    const heap: *Heap = @ptrCast(@alignCast(context));
    try traceTensorMemoRoots(&heap.export_tensors, visitor);
}

const Transaction = struct {
    objects: *ObjectMap,
    u32_slices: *U32SliceMap,
    tensor_memo: *TensorMemo,
    object_keys: std.ArrayListUnmanaged(IdentityKey) = .empty,
    u32_keys: std.ArrayListUnmanaged(*const anyopaque) = .empty,
    tensor_backings: std.ArrayListUnmanaged(TensorBacking) = .empty,
    tensor_bindings: std.ArrayListUnmanaged(TensorBinding) = .empty,
    allocator: Allocator,

    fn init(
        allocator: Allocator,
        objects: *ObjectMap,
        u32_slices: *U32SliceMap,
        tensor_memo: *TensorMemo,
    ) Transaction {
        return .{
            .objects = objects,
            .u32_slices = u32_slices,
            .tensor_memo = tensor_memo,
            .allocator = allocator,
        };
    }

    fn deinit(self: *Transaction) void {
        self.object_keys.deinit(self.allocator);
        self.u32_keys.deinit(self.allocator);
        self.tensor_backings.deinit(self.allocator);
        self.tensor_bindings.deinit(self.allocator);
        self.* = undefined;
    }

    fn clear(self: *Transaction) void {
        self.object_keys.clearRetainingCapacity();
        self.u32_keys.clearRetainingCapacity();
        self.tensor_backings.clearRetainingCapacity();
        self.tensor_bindings.clearRetainingCapacity();
    }

    fn commit(
        self: *Transaction,
        context: *EvalContext,
        backend: Budget.Backend,
    ) Error!void {
        try self.tensor_memo.commit(
            self.tensor_backings.items,
            self.tensor_bindings.items,
            context,
            backend,
        );
        self.clear();
    }

    fn stageTensorBacking(
        self: *Transaction,
        backing: TensorBacking,
        context: *EvalContext,
        backend: Budget.Backend,
    ) Error!void {
        const backing_scan_count = std.math.mul(
            usize,
            self.tensor_backings.items.len,
            2,
        ) catch return error.Unsupported;
        const scan_count = std.math.add(
            usize,
            backing_scan_count,
            self.tensor_bindings.items.len,
        ) catch return error.Unsupported;
        try chargeTensorScan(context, scan_count, backend);

        for (self.tensor_backings.items) |existing| {
            if (!existing.transfer.eql(backing.transfer)) continue;
            if (!existing.source.overlaps(backing.source)) continue;
            if (existing.inner != backing.inner) return error.Unsupported;
            if (!backing.source.contains(existing.source)) {
                return error.Unsupported;
            }
        }

        const staged_count = std.math.add(
            usize,
            self.tensor_backings.items.len,
            1,
        ) catch return error.Unsupported;
        try self.tensor_backings.ensureUnusedCapacity(self.allocator, 1);
        try self.tensor_memo.backings.ensureUnusedCapacity(
            self.tensor_memo.allocator,
            staged_count,
        );

        for (self.tensor_bindings.items) |binding| {
            if (!binding.source.transfer.eql(backing.transfer)) continue;
            if (!binding.source.range.overlaps(backing.source)) continue;
            if (binding.source.inner != backing.inner) {
                return error.Unsupported;
            }
            if (!backing.source.contains(binding.source.range)) {
                return error.Unsupported;
            }
            binding.holder.data = try backing.slice(binding.source.range);
        }

        var index: usize = 0;
        while (index < self.tensor_backings.items.len) {
            const existing = self.tensor_backings.items[index];
            if (!existing.transfer.eql(backing.transfer) or
                !existing.source.overlaps(backing.source))
            {
                index += 1;
                continue;
            }
            _ = self.tensor_backings.swapRemove(index);
        }
        self.tensor_backings.appendAssumeCapacity(backing);
    }

    fn rollback(self: *Transaction) void {
        for (self.object_keys.items) |key| {
            std.debug.assert(self.objects.remove(key));
        }
        for (self.u32_keys.items) |key| {
            std.debug.assert(self.u32_slices.remove(key));
        }
        self.clear();
    }

    fn logObject(self: *Transaction, key: IdentityKey) Allocator.Error!void {
        return self.object_keys.append(self.allocator, key);
    }

    fn logU32(
        self: *Transaction,
        key: *const anyopaque,
    ) Allocator.Error!void {
        return self.u32_keys.append(self.allocator, key);
    }

    fn stageTensorBinding(
        self: *Transaction,
        binding: TensorBinding,
    ) Error!void {
        if (try binding.source.range.elementCount() != binding.holder.data.len) {
            return error.Unsupported;
        }
        const staged_count = std.math.add(
            usize,
            self.tensor_bindings.items.len,
            1,
        ) catch return error.Unsupported;
        try self.tensor_bindings.ensureUnusedCapacity(self.allocator, 1);
        try self.tensor_memo.bindings.ensureUnusedCapacity(
            self.tensor_memo.allocator,
            staged_count,
        );
        self.tensor_bindings.appendAssumeCapacity(binding);
    }
};

const Copier = struct {
    src_ctx: *EvalContext,
    dst_ctx: *EvalContext,
    charge_ctx: *EvalContext,
    objects: *ObjectMap,
    u32_slices: *U32SliceMap,
    transaction: *Transaction,
    backend: Budget.Backend,
    allow_closures: bool,
    preserve_unsupported: bool,

    fn init(
        src_ctx: *EvalContext,
        dst_ctx: *EvalContext,
        charge_ctx: *EvalContext,
        objects: *ObjectMap,
        u32_slices: *U32SliceMap,
        transaction: *Transaction,
        backend: Budget.Backend,
        allow_closures: bool,
        preserve_unsupported: bool,
    ) Copier {
        return .{
            .src_ctx = src_ctx,
            .dst_ctx = dst_ctx,
            .charge_ctx = charge_ctx,
            .objects = objects,
            .u32_slices = u32_slices,
            .transaction = transaction,
            .backend = backend,
            .allow_closures = allow_closures,
            .preserve_unsupported = preserve_unsupported,
        };
    }

    fn sourceIdentity(self: *const Copier) u64 {
        return @intCast(@intFromPtr(self.src_ctx.runtime));
    }

    fn tensorTransfer(self: *const Copier) TensorTransfer {
        return .{
            .source_runtime = self.src_ctx.runtime,
            .destination_runtime = self.dst_ctx.runtime,
        };
    }
    fn chargeWork(self: *Copier, count: u64, cost: u64) Error!void {
        // Import/export scans debit the SUPPLIED lineage so limited callers
        // observe Exhausted; the private heap lease never absorbs them.
        try self.charge_ctx.chargeWork(count, cost, self.backend);
    }

    fn checkDepth(self: *Copier, depth: u32) Error!void {
        try self.src_ctx.check();
        try self.dst_ctx.check();
        try self.charge_ctx.check();
        if (self.charge_ctx.budget()) |ledger| try ledger.checkDepth(depth, self.backend);
    }

    fn memoObject(self: *Copier, key: IdentityKey, value: Value) Allocator.Error!void {
        if (self.objects.get(key) != null) return;
        try self.objects.put(key, value);
        self.transaction.logObject(key) catch |err| {
            std.debug.assert(self.objects.remove(key));
            return err;
        };
    }

    fn memoU32(self: *Copier, key: *const anyopaque, value: U32SliceCopy) Allocator.Error!void {
        if (self.u32_slices.get(key) != null) return;
        try self.u32_slices.put(key, value);
        self.transaction.logU32(key) catch |err| {
            std.debug.assert(self.u32_slices.remove(key));
            return err;
        };
    }

    fn copy(self: *Copier, value: Value, depth: u32) Error!Value {
        return self.copyKnown(value, depth) catch |err| {
            if (err == error.Unsupported and self.canPreserveUnsupported(value)) return value;
            return err;
        };
    }

    fn canPreserveUnsupported(self: *const Copier, value: Value) bool {
        if (!self.preserve_unsupported) return false;
        if (value.typ == skript.builtins.type_cons or
            value.typ == skript.builtins.type_map or
            value.typ == skript.builtins.type_tensor or
            value.typ == skript.builtins.type_error or
            value.typ == skript.builtins.type_method)
        {
            return false;
        }
        if (value.typ == skript.builtins.type_type) {
            return @backingInt(value.obj) > skript.builtins.type_last_idx;
        }
        return true;
    }

    fn copyKnown(self: *Copier, value: Value, depth: u32) Error!Value {
        try self.checkDepth(depth);
        try self.charge_ctx.charge(.{ .work = 1, .nodes = 1 }, self.backend);

        const typ = value.typ;
        if (typ == skript.builtins.type_nil or
            typ == skript.builtins.type_bool or
            typ == skript.builtins.type_f8 or
            typ == skript.builtins.type_f16 or
            typ == skript.builtins.type_f32 or
            typ == skript.builtins.type_f64 or
            typ == skript.builtins.type_u8 or
            typ == skript.builtins.type_u16 or
            typ == skript.builtins.type_u32 or
            typ == skript.builtins.type_u64 or
            typ == skript.builtins.type_i8 or
            typ == skript.builtins.type_i16 or
            typ == skript.builtins.type_i32 or
            typ == skript.builtins.type_i64 or
            typ == skript.builtins.type_c8 or
            typ == skript.builtins.type_c16 or
            typ == skript.builtins.type_c32)
        {
            return value;
        }

        if (typ == skript.builtins.type_c64) return self.copyC64(value);
        if (typ == skript.builtins.type_type) return self.copyType(value);
        if (typ == skript.builtins.type_symbol or typ == skript.builtins.type_keyword) {
            return self.copySymValue(value);
        }
        if (typ == skript.builtins.type_string) return self.copyString(value);
        if (typ == skript.builtins.type_bytevector) return self.copyByteVector(value);
        if (typ == skript.builtins.type_intrinsic) return self.copyIntrinsic(value);
        if (typ == skript.builtins.type_map) return self.copyMap(value, depth);
        if (typ == skript.builtins.type_cons) return self.copyCons(value, depth);
        if (typ == skript.builtins.type_closure) {
            if (!self.allow_closures) return error.Unsupported;
            return self.copyClosure(value, depth);
        }
        if (typ == skript.builtins.type_tensor) return self.copyTensor(value, depth);
        if (typ == skript.builtins.type_error) return self.copyError(value, depth);
        if (typ == skript.builtins.type_method) return self.copyMethod(value, depth);
        return error.Unsupported;
    }

    fn copyC64(self: *Copier, value: Value) Error!Value {
        const key: IdentityKey = .{ .runtime_identity = self.sourceIdentity(), .object = value.obj };
        if (self.objects.get(key)) |memoized| return memoized;

        const src = value.obj.toRef().deref([2]f64);
        const dst_ref = try self.dst_ctx.runtime.store.create([2]f64);
        dst_ref.deref([2]f64).* = src.*;
        const result = Value.c64(dst_ref.toObject());
        try self.memoObject(key, result);
        return result;
    }
    fn copyByteVector(self: *Copier, value: Value) Error!Value {
        const key: IdentityKey = .{ .runtime_identity = self.sourceIdentity(), .object = value.obj };
        if (self.objects.get(key)) |memoized| return memoized;

        const bytes = try value.byteVectorBytes();
        try self.chargeWork(@intCast(bytes.len), 1);
        const allocation = try self.dst_ctx.runtime.store.allocSlice(u8, bytes.len);
        @memcpy(allocation.slice, bytes);
        const holder = try self.dst_ctx.runtime.store.create(Value.ByteVector);
        self.dst_ctx.runtime.store.store(Value.ByteVector, holder.deref(Value.ByteVector), .{
            .bytes = allocation.slice,
        });
        const result = Value.byteVector(holder.toObject());
        try self.memoObject(key, result);
        return result;
    }

    fn copyType(_: *Copier, value: Value) Error!Value {
        // Built-in type descriptors are immutable process-independent tags.
        // Custom descriptors can contain arbitrary callable metadata and have
        // no portable field schema, so they are deliberately rejected.
        return if (@backingInt(value.obj) <= skript.builtins.type_last_idx)
            value
        else
            error.Unsupported;
    }

    fn internSym(self: *Copier, text: []const u8) Error!Sym {
        try self.chargeWork(@intCast(text.len), 1);
        return self.dst_ctx.runtime.store.getsym(text);
    }

    fn copySymValue(self: *Copier, value: Value) Error!Value {
        const sym = value.obj.toPtr(Sym);
        const dst_sym = try self.internSym(sym.*);
        return if (value.typ == skript.builtins.type_symbol)
            Value.symbol(dst_sym)
        else
            Value.keyword(dst_sym);
    }

    fn copyString(self: *Copier, value: Value) Error!Value {
        const src_ptr: [*:0]const u8 = value.obj.toPtr([*:0]const u8);
        const dst_ptr = try self.copyStringPtr(src_ptr);
        return Value.string(Object.fromPtr(dst_ptr));
    }

    fn copyStringPtr(self: *Copier, src_ptr: [*:0]const u8) Error![*:0]const u8 {
        const source_obj = Object.fromPtr(src_ptr);
        const key: IdentityKey = .{ .runtime_identity = self.sourceIdentity(), .object = source_obj };
        if (self.objects.get(key)) |memoized| {
            return memoized.obj.toPtr([*:0]const u8);
        }

        const text = try self.src_ctx.stringBytes(
            src_ptr,
            std.math.maxInt(usize),
            self.backend,
        );
        try self.chargeWork(@intCast(text.len), 1);

        const allocation = try self.dst_ctx.runtime.store.allocSlice(u8, text.len + 1);
        @memcpy(allocation.slice[0..text.len], text);
        allocation.slice[text.len] = 0;
        const dst_ptr: [*:0]const u8 = @ptrCast(allocation.slice.ptr);
        const result = Value.string(Object.fromPtr(dst_ptr));
        try self.memoObject(key, result);
        return dst_ptr;
    }

    fn copyIntrinsic(self: *Copier, value: Value) Error!Value {
        const native_ptr: FuncPtr = value.obj.toPtr(FuncPtr);
        const src_id = self.src_ctx.registry.idForNative(native_ptr) orelse return error.Unsupported;
        const src_spec = self.src_ctx.registry.spec(src_id) orelse return error.Unsupported;
        const dst_spec = self.dst_ctx.registry.find(src_spec.stable_name) orelse return error.Unsupported;
        if (!src_spec.sameSemantics(dst_spec.*)) return error.Unsupported;
        return switch (dst_spec.invoke) {
            .native => |ptr| Value.intrinsic(ptr),
            .closure => error.Unsupported,
        };
    }

    fn copyCons(self: *Copier, value: Value, depth: u32) Error!Value {
        const key: IdentityKey = .{ .runtime_identity = self.sourceIdentity(), .object = value.obj };
        if (self.objects.get(key)) |memoized| return memoized;

        const dst_ref = try self.dst_ctx.runtime.store.create([2]Value);
        const dst_cell = dst_ref.deref([2]Value);
        dst_cell.* = .{ .nil, .nil };
        const result = Value.cons(dst_ref.toObject());
        try self.memoObject(key, result);

        const src_cell = value.obj.toRef().deref([2]Value);
        const next_depth = std.math.add(u32, depth, 1) catch return error.Unsupported;
        dst_cell[0] = try self.copy(src_cell[0], next_depth);
        dst_cell[1] = try self.copy(src_cell[1], next_depth);
        return result;
    }

    fn copyMap(self: *Copier, value: Value, depth: u32) Error!Value {
        const key: IdentityKey = .{ .runtime_identity = self.sourceIdentity(), .object = value.obj };
        if (self.objects.get(key)) |memoized| return memoized;

        const src_map = value.obj.toRef().deref(MapHolder).map;
        const alloc = self.dst_ctx.runtime.store.backingAllocator();
        const dst_map = try alloc.create(Map);
        dst_map.* = Map.init(alloc);
        errdefer {
            dst_map.deinit();
            alloc.destroy(dst_map);
        }
        const dst_holder_ref = try self.dst_ctx.runtime.store.createManaged(
            MapHolder,
            skript.data.traceMapHolder,
            skript.data.finalizeMapHolder,
        );
        errdefer self.dst_ctx.runtime.store.discardUnpublished(dst_holder_ref) catch unreachable;
        dst_holder_ref.deref(MapHolder).* = .{ .map = dst_map, .allocator = alloc };

        const result = Value.init(skript.builtins.type_map, dst_holder_ref.toObject());
        try self.memoObject(key, result);

        const next_depth = std.math.add(u32, depth, 1) catch return error.Unsupported;
        var iterator = src_map.iterator();
        while (iterator.next()) |entry| {
            const copied_key = try self.copy(skript.intrinsics.map.keyValue(entry.key_ptr.*), next_depth);
            const copied_value = try self.copy(entry.value_ptr.*, next_depth);
            try dst_map.ensureUnusedCapacity(1);
            dst_map.putAssumeCapacity(try skript.intrinsics.map.keyOf(self.dst_ctx, copied_key), copied_value);
        }
        return result;
    }

    fn copyTensor(self: *Copier, value: Value, depth: u32) Error!Value {
        const key: IdentityKey = .{
            .runtime_identity = self.sourceIdentity(),
            .object = value.obj,
        };
        if (self.objects.get(key)) |memoized| return memoized;

        const source_holder = value.obj.toRef().deref(TensorHolder);
        const shape_len = source_holder.shape.len;
        const data_len = source_holder.data.len;
        if (source_holder.rank == 0 or source_holder.rank != shape_len) return error.Unsupported;
        var product: usize = 1;
        for (source_holder.shape) |dimension| {
            product = std.math.mul(
                usize,
                product,
                @intCast(dimension),
            ) catch return error.Unsupported;
        }
        if (product != data_len) return error.Unsupported;
        if (source_holder.inner == .empty and data_len != 0) return error.Unsupported;

        const element_count = std.math.add(usize, shape_len, data_len) catch return error.Unsupported;
        try self.chargeWork(@intCast(element_count), 1);
        const destination_shape = try self.copyU32Slice(source_holder.shape);
        const data_copy = try self.copyTensorData(source_holder.data, source_holder.inner);

        const destination_ref = try self.dst_ctx.runtime.store.createTraced(
            TensorHolder,
            TensorMod.traceTensorHolder,
        );
        const destination_holder = destination_ref.deref(TensorHolder);
        destination_holder.* = .{
            .inner = source_holder.inner,
            .rank = source_holder.rank,
            .shape = destination_shape.slice,
            .data = data_copy.data,
            .shape_ref = destination_shape.ref,
            .data_ref = data_copy.ref,
        };
        if (data_copy.source) |source| {
            try self.transaction.stageTensorBinding(.{
                .source = source,
                .holder = destination_holder,
                .holder_ref = destination_ref,
            });
        }

        const result = Value.tensor(destination_ref.toObject());
        try self.memoObject(key, result);
        _ = depth;
        return result;
    }

    fn copyU32Slice(self: *Copier, source: []u32) Error!U32SliceCopy {
        if (source.len == 0) return .{ .slice = &.{}, .ref = .nil };
        const source_ptr: *const anyopaque = @ptrCast(source.ptr);
        if (self.u32_slices.get(source_ptr)) |memoized| {
            if (memoized.slice.len != source.len) return error.Unsupported;
            return memoized;
        }
        const allocation = try self.dst_ctx.runtime.store.allocSlice(u32, source.len);
        @memcpy(allocation.slice, source);
        const result: U32SliceCopy = .{ .slice = allocation.slice, .ref = allocation.ref };
        try self.memoU32(source_ptr, result);
        return result;
    }

    fn copyTensorData(
        self: *Copier,
        source: []u64,
        inner: InnerType,
    ) Error!TensorDataCopy {
        if (source.len == 0) {
            return .{ .data = &.{}, .ref = .nil, .source = null };
        }
        if (inner == .empty) return error.Unsupported;

        const tensor_source: TensorSource = .{
            .transfer = self.tensorTransfer(),
            .inner = inner,
            .range = try ByteRange.init(source),
        };
        var source_range = tensor_source.range;

        try chargeTensorScan(
            self.charge_ctx,
            self.transaction.tensor_memo.backings.items.len,
            self.backend,
        );
        for (self.transaction.tensor_memo.backings.items) |backing| {
            if (!backing.transfer.eql(tensor_source.transfer)) continue;
            if (!backing.source.overlaps(tensor_source.range)) continue;
            if (backing.inner != inner) return error.Unsupported;
            source_range.start = @min(source_range.start, backing.source.start);
            source_range.end = @max(source_range.end, backing.source.end);
        }
        try chargeTensorScan(
            self.charge_ctx,
            self.transaction.tensor_backings.items.len,
            self.backend,
        );
        for (self.transaction.tensor_backings.items) |backing| {
            if (!backing.transfer.eql(tensor_source.transfer)) continue;
            if (!backing.source.overlaps(tensor_source.range)) continue;
            if (backing.inner != inner) return error.Unsupported;
            source_range.start = @min(source_range.start, backing.source.start);
            source_range.end = @max(source_range.end, backing.source.end);
        }

        try chargeTensorScan(
            self.charge_ctx,
            self.transaction.tensor_memo.backings.items.len,
            self.backend,
        );
        for (self.transaction.tensor_memo.backings.items) |backing| {
            if (!backing.transfer.eql(tensor_source.transfer)) continue;
            if (backing.inner != inner) continue;
            if (!backing.source.contains(source_range)) continue;
            return .{
                .data = try backing.slice(tensor_source.range),
                .ref = backing.ref,
                .source = tensor_source,
            };
        }
        try chargeTensorScan(
            self.charge_ctx,
            self.transaction.tensor_backings.items.len,
            self.backend,
        );
        for (self.transaction.tensor_backings.items) |backing| {
            if (!backing.transfer.eql(tensor_source.transfer)) continue;
            if (backing.inner != inner) continue;
            if (!backing.source.contains(source_range)) continue;
            return .{
                .data = try backing.slice(tensor_source.range),
                .ref = backing.ref,
                .source = tensor_source,
            };
        }

        const allocation = try self.dst_ctx.runtime.store.allocSlice(
            u64,
            try source_range.elementCount(),
        );
        const replacement: TensorBacking = .{
            .transfer = tensor_source.transfer,
            .inner = inner,
            .source = source_range,
            .destination = allocation.slice,
            .ref = allocation.ref,
        };
        try self.copyExistingTensorData(replacement);
        try self.copyUnseenTensorData(source, tensor_source, replacement);
        const result_data = try replacement.slice(tensor_source.range);
        try self.transaction.stageTensorBacking(
            replacement,
            self.charge_ctx,
            self.backend,
        );
        return .{ .data = result_data, .ref = replacement.ref, .source = tensor_source };
    }

    fn copyExistingTensorData(
        self: *Copier,
        replacement: TensorBacking,
    ) Error!void {
        try chargeTensorScan(
            self.charge_ctx,
            self.transaction.tensor_memo.backings.items.len,
            self.backend,
        );
        for (self.transaction.tensor_memo.backings.items) |backing| {
            try self.copyExistingTensorBacking(replacement, backing);
        }
        try chargeTensorScan(
            self.charge_ctx,
            self.transaction.tensor_backings.items.len,
            self.backend,
        );
        for (self.transaction.tensor_backings.items) |backing| {
            try self.copyExistingTensorBacking(replacement, backing);
        }
    }

    fn copyExistingTensorBacking(
        _: *Copier,
        replacement: TensorBacking,
        existing: TensorBacking,
    ) Error!void {
        if (!existing.transfer.eql(replacement.transfer)) return;
        if (!existing.source.overlaps(replacement.source)) return;
        if (existing.inner != replacement.inner) return error.Unsupported;
        if (!replacement.source.contains(existing.source)) {
            return error.Unsupported;
        }
        const source_data = try existing.slice(existing.source);
        const destination_data = try replacement.slice(existing.source);
        @memcpy(destination_data, source_data);
    }

    fn copyUnseenTensorData(
        self: *Copier,
        source: []const u64,
        tensor_source: TensorSource,
        replacement: TensorBacking,
    ) Error!void {
        const backing_count = std.math.add(
            usize,
            self.transaction.tensor_memo.backings.items.len,
            self.transaction.tensor_backings.items.len,
        ) catch return error.Unsupported;
        const step_count = std.math.mul(
            usize,
            backing_count,
            2,
        ) catch return error.Unsupported;
        const step_limit = std.math.add(
            usize,
            step_count,
            1,
        ) catch return error.Unsupported;

        var cursor = tensor_source.range.start;
        var steps: usize = 0;
        while (cursor < tensor_source.range.end) {
            steps = std.math.add(usize, steps, 1) catch
                return error.Unsupported;
            if (steps > step_limit) return error.Unsupported;

            var covered_end = cursor;
            var next_start = tensor_source.range.end;
            try self.tensorCoverage(
                self.transaction.tensor_memo.backings.items,
                tensor_source,
                cursor,
                &covered_end,
                &next_start,
            );
            try self.tensorCoverage(
                self.transaction.tensor_backings.items,
                tensor_source,
                cursor,
                &covered_end,
                &next_start,
            );

            if (covered_end > cursor) {
                cursor = @min(covered_end, tensor_source.range.end);
                continue;
            }
            if (next_start <= cursor) return error.Unsupported;
            const gap: ByteRange = .{
                .start = cursor,
                .end = next_start,
            };
            try self.copyTensorSourceRange(
                source,
                tensor_source,
                replacement,
                gap,
            );
            cursor = next_start;
        }
    }

    fn tensorCoverage(
        self: *Copier,
        backings: []const TensorBacking,
        tensor_source: TensorSource,
        cursor: usize,
        covered_end: *usize,
        next_start: *usize,
    ) Error!void {
        try chargeTensorScan(self.charge_ctx, backings.len, self.backend);
        for (backings) |backing| {
            if (!backing.transfer.eql(tensor_source.transfer)) continue;
            if (backing.inner != tensor_source.inner) continue;
            if (!backing.source.overlaps(tensor_source.range)) continue;
            if (backing.source.start <= cursor) {
                if (cursor < backing.source.end) {
                    covered_end.* = @max(covered_end.*, backing.source.end);
                }
                continue;
            }
            next_start.* = @min(next_start.*, backing.source.start);
        }
    }

    fn copyTensorSourceRange(
        self: *Copier,
        source: []const u64,
        tensor_source: TensorSource,
        replacement: TensorBacking,
        range: ByteRange,
    ) Error!void {
        const source_bounds = try elementBounds(
            tensor_source.range,
            range,
            source.len,
        );
        const destination = try replacement.slice(range);
        const input = source[source_bounds.start..source_bounds.end];
        switch (tensor_source.inner) {
            .i64, .f64 => @memcpy(destination, input),
            .empty => return error.Unsupported,
            .symbol, .keyword => for (input, destination) |word, *output| {
                const source_symbol: Sym = @ptrFromInt(
                    @as(usize, @intCast(word)),
                );
                const destination_symbol = try self.internSym(
                    source_symbol.*,
                );
                output.* = @intCast(@intFromPtr(destination_symbol));
            },
            .string => for (input, destination) |word, *output| {
                const source_string: [*:0]const u8 = @ptrFromInt(
                    @as(usize, @intCast(word)),
                );
                const destination_string = try self.copyStringPtr(
                    source_string,
                );
                output.* = @intCast(@intFromPtr(destination_string));
            },
        }
    }

    fn copyError(self: *Copier, value: Value, depth: u32) Error!Value {
        if (!Value.errorPayloadIsRef(value.obj)) return value;
        const key: IdentityKey = .{ .runtime_identity = self.sourceIdentity(), .object = value.obj };
        if (self.objects.get(key)) |memoized| return memoized;

        const source_error = value.obj.toRef().deref(ErrorObj);
        const dst_ref = try self.dst_ctx.runtime.store.create(ErrorObj);
        const dst = dst_ref.deref(ErrorObj);
        dst.* = .{ .err = source_error.err, .site = .{
            .idx = source_error.site.idx,
            .line = source_error.site.line,
            .col = source_error.site.col,
        } };
        const result = Value.init(skript.builtins.type_error, dst_ref.toObject());
        try self.memoObject(key, result);
        const next_depth = std.math.add(u32, depth, 1) catch return error.Unsupported;
        dst.site.source = try self.copy(source_error.site.source, next_depth);
        dst.site.file = try self.copy(source_error.site.file, next_depth);
        dst.raised = try self.copy(source_error.raised, next_depth);
        const frames = try self.dst_ctx.runtime.store.allocSlice(skript.data.ErrorFrame, source_error.frames.len);
        dst.frames = frames.slice;
        for (source_error.frames, frames.slice) |source_frame, *frame| {
            frame.* = .{
                .site = .{
                    .idx = source_frame.site.idx,
                    .line = source_frame.site.line,
                    .col = source_frame.site.col,
                },
                .name = if (source_frame.name) |name| try self.internSym(name.*) else null,
            };
            frame.site.source = try self.copy(source_frame.site.source, next_depth);
            frame.site.file = try self.copy(source_frame.site.file, next_depth);
        }
        return result;
    }

    fn copyClosure(self: *Copier, value: Value, depth: u32) Error!Value {
        const key: IdentityKey = .{ .runtime_identity = self.sourceIdentity(), .object = value.obj };
        if (self.objects.get(key)) |memoized| return memoized;

        const source = value.obj.toRef().deref(Closure);
        const code = source.code orelse return error.Unsupported;
        if (code.function(source.function_id) == null) return error.Unsupported;
        if (source.guard != null) return error.Unsupported;
        if (source.capture_syms.len != source.captures.len) return error.Unsupported;

        const dst_ref = try self.dst_ctx.runtime.store.create(Closure);
        const arg_alloc = try self.dst_ctx.runtime.store.allocSlice(Sym, source.arglist.len);
        const capture_sym_alloc = try self.dst_ctx.runtime.store.allocSlice(
            Sym,
            source.capture_syms.len,
        );
        const captures = try self.dst_ctx.runtime.store.allocSlice(Value, source.captures.len);
        @memset(captures.slice, .nil);

        for (source.arglist, 0..) |sym, index| arg_alloc.slice[index] = try self.internSym(sym.*);
        for (source.capture_syms, 0..) |sym, index| capture_sym_alloc.slice[index] = try self.internSym(sym.*);

        dst_ref.deref(Closure).* = .{
            .parent_ns = .nil,
            .arglist = arg_alloc.slice,
            .source = .nil,
            .source_ref = .{},
            .ir = &.{},
            .constants = &.{},
            .nregs = source.nregs,
            .result_count = source.result_count,
            .zero_mask = source.zero_mask,
            .capture_syms = capture_sym_alloc.slice,
            .captures = captures.slice,
            .guard = null,
            .code = code,
            .function_id = source.function_id,
            .environment_id = 0,
            .fns = &.{},
        };
        const result = Value.closure(dst_ref.toObject());
        try self.memoObject(key, result);

        const next_depth = std.math.add(u32, depth, 1) catch return error.Unsupported;
        for (source.captures, 0..) |capture, index| captures.slice[index] = try self.copy(capture, next_depth);
        return result;
    }

    fn copyMethod(self: *Copier, value: Value, depth: u32) Error!Value {
        const key: IdentityKey = .{ .runtime_identity = self.sourceIdentity(), .object = value.obj };
        if (self.objects.get(key)) |memoized| return memoized;

        const source = value.obj.toRef().deref(Method);
        const destination_ref = try self.dst_ctx.runtime.store.create(Method);
        const destination = destination_ref.deref(Method);
        destination.* = .{
            .id = source.id,
            .revision = source.revision,
            .resolved = std.AutoHashMap(u64, Value).init(self.dst_ctx.runtime.static),
            .locked = true,
        };
        const result = Value.method(destination_ref.toObject());
        try self.memoObject(key, result);

        const next_depth = std.math.add(u32, depth, 1) catch return error.Unsupported;
        var iterator = source.resolved.iterator();
        while (iterator.next()) |entry| {
            try self.chargeWork(1, 2);
            const function = try self.copy(entry.value_ptr.*, next_depth);
            try destination.resolved.ensureUnusedCapacity(1);
            destination.resolved.putAssumeCapacity(entry.key_ptr.*, function);
        }
        return result;
    }
};

pub fn init(parent: *EvalContext) InitError!*Heap {
    try parent.check();
    const parent_lease = parent.lease orelse return error.Denied;
    const budget = parent_lease.budget;
    const allocation_allocator = parent.scratch;
    const base_allocator = parent.scratch_base;

    const heap = allocation_allocator.create(Heap) catch |err| {
        try parent.check();
        return err;
    };
    errdefer allocation_allocator.destroy(heap);
    heap.* = undefined;
    heap.allocation_allocator = allocation_allocator;
    heap.parent_runtime = parent.runtime;

    const lease_limit = @min(parent_lease.remaining_work, 100_000_000);
    heap.lease = try parent_lease.child(lease_limit);
    heap.budget = budget;
    heap.account = Budget.AccountAllocator.init(base_allocator, &heap.lease, .transform);
    heap.output_storage = heap.account.allocator().alloc(u8, 64 * 1024) catch |err| {
        try parent.check();
        return err;
    };
    heap.output_writer = std.Io.Writer.fixed(heap.output_storage);
    heap.import_objects = ObjectMap.init(allocation_allocator);
    heap.import_u32_slices = U32SliceMap.init(allocation_allocator);
    heap.import_tensors = TensorMemo.init(allocation_allocator);
    heap.export_tensors = TensorMemo.init(allocation_allocator);
    heap.runtime_roots = .{ .context = heap, .trace = traceRuntimeHeapRoots };
    heap.parent_roots = .{ .context = heap, .trace = traceParentHeapRoots };

    errdefer heap.import_objects.deinit();
    errdefer heap.import_u32_slices.deinit();
    errdefer heap.import_tensors.deinit();
    errdefer heap.export_tensors.deinit();
    errdefer heap.account.allocator().free(heap.output_storage);

    const store_config: Store.Config = .{
        .heap_size = 4 * 1024 * 1024,
        .max_heap_size = 1024 * 1024,
        .retained_bytes = budget.snapshot().available.bytes,
    };
    heap.runtime = Runtime.initWithConfig(
        heap.account.allocator(),
        parent.runtime.io,
        store_config,
    ) catch |err| {
        try parent.check();
        return err;
    };
    errdefer heap.runtime.deinit();
    heap.runtime.stdout = &heap.output_writer;
    heap.runtime.store.registerRootProvider(&heap.runtime_roots) catch {
        try parent.check();
        return error.Unsupported;
    };
    errdefer heap.runtime.store.unregisterRootProvider(&heap.runtime_roots) catch unreachable;
    parent.runtime.store.registerRootProvider(&heap.parent_roots) catch {
        try parent.check();
        return error.Unsupported;
    };
    errdefer parent.runtime.store.unregisterRootProvider(&heap.parent_roots) catch unreachable;
    return heap;
}

pub fn deinit(self: *Heap) void {
    const allocation_allocator = self.allocation_allocator;
    self.parent_runtime.store.unregisterRootProvider(&self.parent_roots) catch unreachable;
    self.runtime.store.unregisterRootProvider(&self.runtime_roots) catch unreachable;
    self.import_objects.deinit();
    self.import_u32_slices.deinit();
    self.import_tensors.deinit();
    self.export_tensors.deinit();
    self.runtime.deinit();
    self.account.allocator().free(self.output_storage);
    allocation_allocator.destroy(self);
}

pub fn importValue(self: *Heap, context: *EvalContext, value: Value) Error!Value {
    try context.check();
    try self.checkOwner(context);

    var target_context = self.runtime.context().*;
    target_context.lease = &self.lease;
    target_context.scratch = self.account.allocator();
    target_context.scratch_base = self.account.base;
    target_context.mode = context.mode;
    target_context.effects = context.effects;

    var transaction = Transaction.init(
        context.scratch,
        &self.import_objects,
        &self.import_u32_slices,
        &self.import_tensors,
    );
    defer transaction.deinit();
    var copier = Copier.init(
        context,
        &target_context,
        context,
        &self.import_objects,
        &self.import_u32_slices,
        &transaction,
        .transform,
        true,
        false,
    );
    const scope = target_context.activate();
    defer scope.deinit();

    const result = copier.copy(value, 0) catch |err| {
        transaction.rollback();
        if (err == error.OutOfMemory) try context.check();
        return err;
    };
    transaction.commit(context, .transform) catch |err| {
        transaction.rollback();
        return err;
    };
    return result;
}

pub fn exportValue(self: *Heap, parent: *EvalContext, value: Value) Error!Value {
    try parent.check();
    try self.checkOwner(parent);

    var source_context = self.runtime.context().*;
    source_context.lease = &self.lease;
    source_context.scratch = self.account.allocator();
    source_context.scratch_base = self.account.base;

    var objects = ObjectMap.init(parent.scratch);
    var u32_slices = U32SliceMap.init(parent.scratch);
    defer objects.deinit();
    defer u32_slices.deinit();

    var transaction = Transaction.init(
        parent.scratch,
        &objects,
        &u32_slices,
        &self.export_tensors,
    );
    defer transaction.deinit();
    var copier = Copier.init(
        &source_context,
        parent,
        parent,
        &objects,
        &u32_slices,
        &transaction,
        .transform,
        false,
        false,
    );
    const scope = parent.activate();
    defer scope.deinit();

    const result = copier.copy(value, 0) catch |err| {
        transaction.rollback();
        if (err == error.OutOfMemory) try parent.check();
        return err;
    };
    transaction.commit(parent, .transform) catch |err| {
        transaction.rollback();
        return err;
    };
    return result;
}

/// Copy event values inside the private runtime before recording them.
/// One copier preserves aliases between all roots in the event snapshot.
pub fn snapshotValues(
    self: *Heap,
    context: *EvalContext,
    source: []const Value,
    destination: []Value,
) Error!void {
    if (source.len != destination.len) return error.InvalidCode;
    try context.check();
    try self.checkOwner(context);

    var objects = ObjectMap.init(context.scratch);
    defer objects.deinit();
    var u32_slices = U32SliceMap.init(context.scratch);
    defer u32_slices.deinit();
    var tensor_memo = TensorMemo.init(context.scratch);
    defer tensor_memo.deinit();
    var transaction = Transaction.init(
        context.scratch,
        &objects,
        &u32_slices,
        &tensor_memo,
    );
    defer transaction.deinit();
    var copier = Copier.init(
        context,
        context,
        context,
        &objects,
        &u32_slices,
        &transaction,
        .transform,
        true,
        true,
    );
    const scope = context.activate();
    defer scope.deinit();

    for (source, destination) |value, *out| {
        out.* = copier.copy(value, 0) catch |err| {
            transaction.rollback();
            if (err == error.OutOfMemory) try context.check();
            return err;
        };
    }
    transaction.commit(context, .transform) catch |err| {
        transaction.rollback();
        return err;
    };
}

fn checkOwner(self: *Heap, context: *EvalContext) Error!void {
    const context_budget = context.budget() orelse return error.Denied;
    if (context_budget != self.budget) return error.Denied;
    if (context_budget.isExhausted()) return error.Exhausted;
}

fn testTensorWithBuffers(
    store: *Store,
    inner: InnerType,
    shape: Store.TypedSlice(u32),
    data: Store.TypedSlice(u64),
) !Value {
    const ref = try store.createTraced(TensorHolder, TensorMod.traceTensorHolder);
    ref.deref(TensorHolder).* = .{
        .inner = inner,
        .rank = @intCast(shape.slice.len),
        .shape = shape.slice,
        .data = data.slice,
        .shape_ref = shape.ref,
        .data_ref = data.ref,
    };
    return Value.tensor(ref.toObject());
}

fn testTensorWithShape(
    store: *Store,
    inner: InnerType,
    shape: []const u32,
    data: Store.TypedSlice(u64),
) !Value {
    const allocation = try store.allocSlice(u32, shape.len);
    errdefer store.discardUnpublished(allocation.ref) catch unreachable;
    @memcpy(allocation.slice, shape);
    return testTensorWithBuffers(store, inner, allocation, data);
}

fn testTensorUsingShape(
    store: *Store,
    inner: InnerType,
    shape: Store.TypedSlice(u32),
    words: []const u64,
) !Value {
    const data = try store.allocSlice(u64, words.len);
    errdefer store.discardUnpublished(data.ref) catch unreachable;
    @memcpy(data.slice, words);
    return testTensorWithBuffers(store, inner, shape, data);
}

fn testTensorFromWords(
    store: *Store,
    inner: InnerType,
    shape: []const u32,
    words: []const u64,
) !Value {
    const data = try store.allocSlice(u64, words.len);
    errdefer store.discardUnpublished(data.ref) catch unreachable;
    @memcpy(data.slice, words);
    return testTensorWithShape(store, inner, shape, data);
}

fn testTensorView(
    store: *Store,
    inner: InnerType,
    shape: []const u32,
    backing: Store.TypedSlice(u64),
    start: usize,
    end: usize,
) !Value {
    const shape_allocation = try testTensorShape(store, shape);
    errdefer store.discardUnpublished(shape_allocation.ref) catch unreachable;
    return testTensorWithBuffers(store, inner, shape_allocation, .{
        .ref = backing.ref,
        .slice = backing.slice[start..end],
    });
}

fn testTensorShape(store: *Store, dimensions: []const u32) !Store.TypedSlice(u32) {
    const allocation = try store.allocSlice(u32, dimensions.len);
    @memcpy(allocation.slice, dimensions);
    return allocation;
}

const TestValueRoots = struct {
    runtime: *Runtime,
    roots: [8]Runtime.ValueRoot = @splat(.{}),
    len: usize = 0,

    fn init(runtime: *Runtime) TestValueRoots {
        return .{ .runtime = runtime };
    }

    fn add(self: *TestValueRoots, value: Value) !void {
        if (self.len == self.roots.len) return error.TestUnexpectedResult;
        try self.runtime.registerValueRoot(&self.roots[self.len], value);
        self.len += 1;
    }

    fn deinit(self: *TestValueRoots) void {
        while (self.len > 0) {
            self.len -= 1;
            self.runtime.unregisterValueRoot(&self.roots[self.len]) catch unreachable;
        }
        self.* = undefined;
    }
};

test "EvalHeap: cycles, map isolation, tensor aliases, error origins, output, and export lifetime" {
    const testing = std.testing;
    const ErrorOrigin = struct {
        const Self = @This();
        line: Value,
        frame_line: Value,
        file: []const u8,
        function: []const u8,

        fn field(alist: Value, key: []const u8) !Value {
            var cursor = alist;
            while (!cursor.isNil()) {
                if (cursor.typ != skript.builtins.type_cons) return error.TestUnexpectedResult;
                const cell = cursor.obj.toRef().deref([2]Value).*;
                if (cell[0].typ != skript.builtins.type_cons) return error.TestUnexpectedResult;
                const entry = cell[0].obj.toRef().deref([2]Value).*;
                if (entry[0].typ != skript.builtins.type_symbol) return error.TestUnexpectedResult;
                if (std.mem.eql(u8, entry[0].obj.toPtr(Sym).*, key)) return entry[1];
                cursor = cell[1];
            }
            return error.TestUnexpectedResult;
        }

        fn observe(ctx: *EvalContext, value: Value) !Self {
            const location = try skript.intrinsics.misc.errorLocation(ctx, .nil, .nil, &.{value});
            const trace = try skript.intrinsics.misc.errorTrace(ctx, .nil, .nil, &.{value});
            try std.testing.expectEqual(skript.builtins.type_cons, location.typ);
            try std.testing.expectEqual(skript.builtins.type_cons, trace.typ);
            const frame = trace.obj.toRef().deref([2]Value)[0];
            const line = try field(location, "line");
            const frame_line = try field(frame, "line");
            const file = try field(frame, "file");
            const function = try field(frame, "function");
            try std.testing.expectEqual(skript.builtins.type_i64, line.typ);
            try std.testing.expectEqual(skript.builtins.type_i64, frame_line.typ);
            try std.testing.expectEqual(skript.builtins.type_string, file.typ);
            try std.testing.expectEqual(skript.builtins.type_string, function.typ);
            return .{
                .line = line,
                .frame_line = frame_line,
                .file = std.mem.span(file.obj.toPtr([*:0]const u8)),
                .function = std.mem.span(function.obj.toPtr([*:0]const u8)),
            };
        }

        fn expectSame(expected: Self, actual: Self) !void {
            try std.testing.expectEqual(expected.line, actual.line);
            try std.testing.expectEqual(expected.frame_line, actual.frame_line);
            try std.testing.expectEqualStrings(expected.file, actual.file);
            try std.testing.expectEqualStrings(expected.function, actual.function);
        }
    };
    const rt = try Runtime.init(testing.allocator, testing.io);
    defer rt.deinit();

    var ledger = Budget.init(testing.io, 1001, .{
        .work = 10_000_000,
        .bytes = 128 * 1024 * 1024,
        .objects = 1_000_000,
        .nodes = 1_000_000,
    });
    var lease = try Budget.Lease.root(&ledger, 5_000_000);
    var account = Budget.AccountAllocator.init(testing.allocator, &lease, .native);
    var output_bytes: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_bytes);
    var context = try EvalContext.limited(
        rt,
        rt.intrinsics.registryVersion(),
        &account,
        .{ .writer = &writer, .bounded_memory = true },
        .{},
    );

    const definition = try skript.Reader.readUnit(
        rt.store,
        "\n(defn (heap-clone-leaf) (fst 42))",
        .{ .mode = .one, .file = "heap-error.pt" },
    );
    _ = try rt.evalDatumWithContext(rt.context(), definition.datum, null);
    const caught = try skript.Reader.readUnit(
        rt.store,
        "\n(try (heap-clone-leaf) (catch e e))",
        .{ .mode = .one, .file = "heap-error.pt" },
    );
    const original_error = try rt.evalDatumWithContext(rt.context(), caught.datum, null);
    try testing.expectEqual(skript.builtins.type_error, original_error.typ);
    const original_origin = try ErrorOrigin.observe(&context, original_error);
    try testing.expectEqual(Value.i64(2), original_origin.line);
    try testing.expect(original_origin.frame_line.obj.toInt(i64) > 0);
    try testing.expectEqualStrings("heap-error.pt", original_origin.file);
    try testing.expectEqualStrings("heap-clone-leaf", original_origin.function);

    const heap = try Heap.init(&context);
    var heap_open = true;
    defer if (heap_open) heap.deinit();

    const source_ref = try rt.store.create([2]Value);
    source_ref.deref([2]Value).* = .{ .i64(7), Value.cons(source_ref.toObject()) };
    const source_cycle = Value.cons(source_ref.toObject());
    const private_cycle = try heap.importValue(&context, source_cycle);
    const private_cell = private_cycle.obj.toRef().deref([2]Value);
    try testing.expectEqual(private_cycle.obj, private_cell[1].obj);

    const key = Value.symbol(try rt.store.getsym("k"));
    const keyword = Value.keyword(try rt.store.getsym("k"));
    const string_key = try rt.evalString("\"map-copy-key\"");
    const source_map = try skript.intrinsics.map.create(&context, .nil, .nil, &.{
        key,
        .i64(10),
        keyword,
        .i64(20),
        string_key,
        .i64(30),
    });
    const private_map = try heap.importValue(&context, source_map);
    const private_key = try heap.importValue(&context, key);
    const private_keyword = try heap.importValue(&context, keyword);
    const private_string = try heap.importValue(&context, string_key);
    try testing.expect(string_key.obj != private_string.obj);
    const private_error = try heap.importValue(&context, original_error);
    var private_context = heap.runtime.context().*;
    private_context.lease = &heap.lease;
    private_context.scratch = heap.account.allocator();
    private_context.scratch_base = heap.account.base;
    const private_scope = private_context.activate();
    defer private_scope.deinit();
    try ErrorOrigin.expectSame(original_origin, try ErrorOrigin.observe(&private_context, private_error));
    _ = try skript.intrinsics.map.set(
        &private_context,
        .nil,
        .nil,
        &.{ private_map, private_key, .i64(99) },
    );
    const source_map_key = try skript.intrinsics.map.keyOf(&context, key);
    const source_map_value = source_map.obj.toRef().deref(MapHolder).map.get(source_map_key) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 10), source_map_value.obj.toInt(i64));
    const private_keyword_key = try skript.intrinsics.map.keyOf(&private_context, private_keyword);
    try testing.expect(private_map.obj.toRef().deref(MapHolder).map.contains(private_keyword_key));
    try testing.expectEqual(
        Value.i64(30),
        try skript.intrinsics.map.get(&private_context, .nil, .nil, &.{ private_map, private_string }),
    );

    const raw_bytes = try rt.store.allocSlice(u8, 3);
    @memcpy(raw_bytes.slice, &[_]u8{ 0, 255, 7 });
    const bytes_ref = try rt.store.create(Value.ByteVector);
    rt.store.store(Value.ByteVector, bytes_ref.deref(Value.ByteVector), .{ .bytes = raw_bytes.slice });
    const bytevector = Value.byteVector(bytes_ref.toObject());
    const private_bytes = try heap.importValue(&context, bytevector);
    try testing.expect(bytevector.obj != private_bytes.obj);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 7 }, try private_bytes.byteVectorBytes());

    const shared_shape = try rt.store.allocSlice(u32, 1);
    shared_shape.slice[0] = 2;
    const shared_data = rt.store.allocSlice(u64, 2) catch |err| {
        rt.store.discardUnpublished(shared_shape.ref) catch unreachable;
        return err;
    };
    shared_data.slice[0] = @bitCast(@as(i64, 1));
    shared_data.slice[1] = @bitCast(@as(i64, 2));
    const tensor_a = testTensorWithBuffers(rt.store, .i64, shared_shape, shared_data) catch |err| {
        rt.store.discardUnpublished(shared_data.ref) catch unreachable;
        rt.store.discardUnpublished(shared_shape.ref) catch unreachable;
        return err;
    };
    const tensor_b = try testTensorWithBuffers(rt.store, .i64, shared_shape, shared_data);
    const tensor_tail_ref = try rt.store.create([2]Value);
    tensor_tail_ref.deref([2]Value).* = .{
        tensor_b,
        .nil,
    };
    const tensor_pair_ref = try rt.store.create([2]Value);
    tensor_pair_ref.deref([2]Value).* = .{
        tensor_a,
        Value.cons(tensor_tail_ref.toObject()),
    };
    const private_pair = try heap.importValue(&context, Value.cons(tensor_pair_ref.toObject()));
    const private_a = private_pair.obj.toRef().deref([2]Value)[0].obj.toRef().deref(TensorHolder);
    const private_b = private_pair.obj.toRef().deref([2]Value)[1].obj.toRef().deref([2]Value)[0]
        .obj.toRef().deref(TensorHolder);
    private_a.data[0] = @bitCast(@as(i64, 99));
    try testing.expectEqual(@as(i64, 99), @as(i64, @bitCast(private_b.data[0])));
    try testing.expectEqual(@as(i64, 1), @as(i64, @bitCast(shared_data.slice[0])));

    try heap.runtime.context().writeAll("private");
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);

    const exported_cycle = try heap.exportValue(&context, private_cycle);
    const exported_error = try heap.exportValue(&context, private_error);
    heap.deinit();
    heap_open = false;
    const parent_scope = context.activate();
    defer parent_scope.deinit();
    const exported_cell = exported_cycle.obj.toRef().deref([2]Value);
    try testing.expectEqual(exported_cycle.obj, exported_cell[1].obj);
    try ErrorOrigin.expectSame(original_origin, try ErrorOrigin.observe(&context, exported_error));
}

test "EvalHeap: rejects host capabilities and unsupported custom types" {
    const testing = std.testing;
    const rt = try Runtime.init(testing.allocator, testing.io);
    defer rt.deinit();
    var ledger = Budget.init(testing.io, 1002, .{
        .work = 10_000_000,
        .bytes = 128 * 1024 * 1024,
        .objects = 1_000_000,
    });
    var lease = try Budget.Lease.root(&ledger, 5_000_000);
    var account = Budget.AccountAllocator.init(testing.allocator, &lease, .transform);
    var output: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var context = try EvalContext.limited(
        rt,
        rt.intrinsics.registryVersion(),
        &account,
        .{ .writer = &writer, .bounded_memory = true },
        .{},
    );
    const heap = try Heap.init(&context);
    defer heap.deinit();
    try testing.expectError(error.Unsupported, heap.importValue(&context, Value.opaq(.null)));
    try testing.expectError(error.Unsupported, heap.importValue(&context, Value.namespace(.null)));
}

test "EvalHeap: allocator failure is not terminal quota exhaustion" {
    const rt = try Runtime.init(std.testing.allocator, std.testing.io);
    defer rt.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var ledger = Budget.init(std.testing.io, 1003, .{ .work = 10000, .bytes = 1024 * 1024, .objects = 100 });
    var lease = try Budget.Lease.root(&ledger, 10000);
    var account = Budget.AccountAllocator.init(failing.allocator(), &lease, .transform);
    var bytes: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var context = try EvalContext.limited(
        rt,
        rt.intrinsics.registryVersion(),
        &account,
        .{ .writer = &writer, .bounded_memory = true },
        .{},
    );
    try std.testing.expectError(error.OutOfMemory, Heap.init(&context));
    try std.testing.expect(!ledger.isExhausted());
}

test "EvalHeap: quota denial reports terminal heap allocation" {
    const testing = std.testing;
    const rt = try Runtime.init(testing.allocator, testing.io);
    defer rt.deinit();

    var ledger = Budget.init(testing.io, 1004, .{
        .work = 10_000,
        .bytes = @sizeOf(Heap) - 1,
        .objects = 100,
    });
    var lease = try Budget.Lease.root(&ledger, 10_000);
    var account = Budget.AccountAllocator.init(testing.allocator, &lease, .transform);
    var output: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var context = try EvalContext.limited(
        rt,
        rt.intrinsics.registryVersion(),
        &account,
        .{ .writer = &writer, .bounded_memory = true },
        .{},
    );

    try testing.expectError(error.Exhausted, Heap.init(&context));
    const report = ledger.report() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Budget.Reason.quota, report.reason);
    const heap_size: u64 = @intCast(@sizeOf(Heap));
    try testing.expectEqual(@as(?u64, heap_size), report.requested);
}

test "EvalHeap: failed import rolls back and permits a retry" {
    const testing = std.testing;
    const rt = try Runtime.init(testing.allocator, testing.io);
    defer rt.deinit();

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var ledger = Budget.init(testing.io, 1005, .{
        .work = 10_000_000,
        .bytes = 128 * 1024 * 1024,
        .objects = 1_000_000,
        .nodes = 1_000_000,
    });
    var lease = try Budget.Lease.root(&ledger, 5_000_000);
    var account = Budget.AccountAllocator.init(failing.allocator(), &lease, .transform);
    var output: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var context = try EvalContext.limited(
        rt,
        rt.intrinsics.registryVersion(),
        &account,
        .{ .writer = &writer, .bounded_memory = true },
        .{},
    );
    const heap = try Heap.init(&context);
    defer heap.deinit();

    const source_ref = try rt.store.create([2]Value);
    source_ref.deref([2]Value).* = .{ .i64(7), .nil };
    const source = Value.cons(source_ref.toObject());

    failing.fail_index = failing.alloc_index + 1;
    try testing.expectError(error.OutOfMemory, heap.importValue(&context, source));
    try testing.expect(!ledger.isExhausted());

    failing.fail_index = std.math.maxInt(usize);
    const retried = try heap.importValue(&context, source);
    const retried_cell = retried.obj.toRef().deref([2]Value);
    try testing.expectEqual(Value.i64(7), retried_cell[0]);
    try testing.expectEqual(Value.nil, retried_cell[1]);
}

test "EvalHeap: overlapping views keep aliases across separate imports" {
    const testing = std.testing;
    const rt = try Runtime.init(testing.allocator, testing.io);
    defer rt.deinit();
    var ledger = Budget.init(testing.io, 1006, .{
        .work = 10_000_000,
        .bytes = 128 * 1024 * 1024,
    });
    var lease = try Budget.Lease.root(&ledger, 10_000_000);
    var account = Budget.AccountAllocator.init(
        testing.allocator,
        &lease,
        .transform,
    );
    var output: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var context = try EvalContext.limited(
        rt,
        rt.intrinsics.registryVersion(),
        &account,
        .{ .writer = &writer, .bounded_memory = true },
        .{},
    );
    const heap = try Heap.init(&context);
    defer heap.deinit();

    const backing = try rt.store.allocSlice(u64, 4);
    backing.slice[0] = 1;
    backing.slice[1] = 2;
    backing.slice[2] = 3;
    backing.slice[3] = 4;
    const full_shape = try testTensorShape(rt.store, &.{4});
    var full_shape_unowned = true;
    errdefer if (full_shape_unowned) {
        rt.store.discardUnpublished(full_shape.ref) catch unreachable;
    };
    const full_value = try testTensorWithBuffers(rt.store, .i64, full_shape, backing);
    full_shape_unowned = false;
    const same_shape_value = try testTensorUsingShape(
        rt.store,
        .i64,
        full_shape,
        &.{ 5, 6, 7, 8 },
    );
    const view_value = try testTensorView(rt.store, .i64, &.{2}, backing, 1, 3);
    var source_roots = TestValueRoots.init(rt);
    defer source_roots.deinit();
    try source_roots.add(full_value);
    try source_roots.add(view_value);
    try source_roots.add(same_shape_value);

    try rt.collect();
    const private_view_value = try heap.importValue(&context, view_value);
    const private_view = private_view_value.obj.toRef().deref(TensorHolder);
    const first_private_backing_ref = private_view.data_ref;
    private_view.data[0] = 77;
    try heap.runtime.collect();
    try rt.collect();
    try testing.expectEqual(@as(u64, 77), private_view.data[0]);
    try testing.expectEqual(@as(u64, 2), backing.slice[1]);

    const private_full_value = try heap.importValue(&context, full_value);
    const private_full = private_full_value.obj.toRef().deref(TensorHolder);
    try heap.runtime.collect();
    try testing.expectError(
        error.InvalidRef,
        heap.runtime.store.derefChecked(u64, first_private_backing_ref),
    );

    try testing.expectEqual(@as(u64, 77), private_full.data[1]);
    try testing.expectEqual(
        @intFromPtr(private_full.data.ptr + 1),
        @intFromPtr(private_view.data.ptr),
    );
    private_full.data[2] = 88;
    try testing.expectEqual(@as(u64, 88), private_view.data[1]);
    try testing.expectEqual(@as(u64, 2), backing.slice[1]);
    try testing.expectEqual(@as(u64, 3), backing.slice[2]);

    const private_same_value = try heap.importValue(&context, same_shape_value);
    const private_same = private_same_value.obj.toRef().deref(TensorHolder);
    try heap.runtime.collect();
    try testing.expectEqual(
        @intFromPtr(private_full.shape.ptr),
        @intFromPtr(private_same.shape.ptr),
    );
    try testing.expect(
        @intFromPtr(private_full.data.ptr) !=
            @intFromPtr(private_same.data.ptr),
    );
    private_same.data[1] = 99;
    try testing.expectEqual(@as(u64, 77), private_full.data[1]);

    const conflicting_value = try testTensorView(
        rt.store,
        .f64,
        &.{2},
        backing,
        1,
        3,
    );
    try source_roots.add(conflicting_value);

    try testing.expectError(
        error.Unsupported,
        heap.importValue(&context, conflicting_value),
    );
    try testing.expectEqual(@as(u64, 77), private_full.data[1]);
}

test "EvalHeap: tensor backing scans consume import work budget" {
    const testing = std.testing;
    const rt = try Runtime.init(testing.allocator, testing.io);
    defer rt.deinit();
    // Heap.init loads a full inner prelude (~195k work under exact
    // attribution, deterministic); per-import scans cost ~600 work growing
    // superlinearly as memos grow. Size the budget past init so the import
    // loop below is what exhausts it: assertions (exhausted, >=32 imports,
    // resource=work) still pin per-import scan charging.
    var ledger = Budget.init(testing.io, 1009, .{
        .work = 300_000,
        .bytes = 128 * 1024 * 1024,
        .objects = 1_000_000,
        .nodes = 1_000_000,
    });
    var lease = try Budget.Lease.root(&ledger, 300_000);
    var account = Budget.AccountAllocator.init(
        testing.allocator,
        &lease,
        .transform,
    );
    var output: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var context = try EvalContext.limited(
        rt,
        rt.intrinsics.registryVersion(),
        &account,
        .{ .writer = &writer, .bounded_memory = true },
        .{},
    );
    const heap = try Heap.init(&context);
    defer heap.deinit();

    var imported_count: usize = 0;
    var exhausted = false;
    for (0..256) |index| {
        const word: u64 = @intCast(index);
        const source_value = try testTensorFromWords(
            rt.store,
            .i64,
            &.{1},
            &.{word},
        );
        _ = heap.importValue(&context, source_value) catch |err| {
            try testing.expectEqual(error.Exhausted, err);
            exhausted = true;
            break;
        };
        imported_count += 1;
    }

    try testing.expect(exhausted);
    try testing.expect(imported_count >= 32);
    const report = ledger.report() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Budget.Resource.work, report.resource);
}

test "EvalHeap: separate exports preserve overlapping tensor aliases" {
    const testing = std.testing;
    const rt = try Runtime.init(testing.allocator, testing.io);
    defer rt.deinit();
    var ledger = Budget.init(testing.io, 1007, .{
        .work = 10_000_000,
        .bytes = 128 * 1024 * 1024,
    });
    var lease = try Budget.Lease.root(&ledger, 10_000_000);
    var account = Budget.AccountAllocator.init(
        testing.allocator,
        &lease,
        .transform,
    );
    var output: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var context = try EvalContext.limited(
        rt,
        rt.intrinsics.registryVersion(),
        &account,
        .{ .writer = &writer, .bounded_memory = true },
        .{},
    );
    const heap = try Heap.init(&context);
    var heap_open = true;
    defer if (heap_open) heap.deinit();

    const backing = try heap.runtime.store.allocSlice(u64, 4);
    backing.slice[0] = 1;
    backing.slice[1] = 2;
    backing.slice[2] = 3;
    backing.slice[3] = 4;
    const full_value = try testTensorView(
        heap.runtime.store,
        .i64,
        &.{4},
        backing,
        0,
        4,
    );
    const view_value = try testTensorView(
        heap.runtime.store,
        .i64,
        &.{2},
        backing,
        1,
        3,
    );
    var private_roots = TestValueRoots.init(heap.runtime);
    var private_roots_open = true;
    defer if (private_roots_open) private_roots.deinit();
    try private_roots.add(full_value);
    try private_roots.add(view_value);
    try heap.runtime.collect();

    const exported_view_value = try heap.exportValue(&context, view_value);
    const exported_view_ref = exported_view_value.obj.toRef();
    const exported_view = exported_view_ref.deref(TensorHolder);
    const view_shape_ref = exported_view.shape_ref;
    const first_backing_ref = exported_view.data_ref;
    try rt.collect();
    try testing.expectEqual(@as(u64, 2), exported_view.data[0]);
    try testing.expectEqual(@as(u64, 3), exported_view.data[1]);
    _ = try rt.store.derefChecked(u64, first_backing_ref);
    _ = try rt.store.derefChecked(u32, view_shape_ref);
    exported_view.data[0] = 77;

    const exported_full_value = try heap.exportValue(&context, full_value);
    const exported_full_ref = exported_full_value.obj.toRef();
    const exported_full = exported_full_ref.deref(TensorHolder);
    const full_shape_ref = exported_full.shape_ref;
    const enlarged_backing_ref = exported_full.data_ref;
    try rt.collect();
    try testing.expectError(
        error.InvalidRef,
        rt.store.derefChecked(u64, first_backing_ref),
    );
    try testing.expectEqual(@as(u64, 77), exported_full.data[1]);
    try testing.expectEqual(
        @intFromPtr(exported_full.data.ptr + 1),
        @intFromPtr(exported_view.data.ptr),
    );
    exported_full.data[2] = 88;
    try testing.expectEqual(@as(u64, 88), exported_view.data[1]);
    try testing.expectEqual(@as(u64, 2), backing.slice[1]);
    try testing.expectEqual(@as(u64, 3), backing.slice[2]);
    _ = try rt.store.derefChecked(TensorHolder, exported_view_ref);
    _ = try rt.store.derefChecked(TensorHolder, exported_full_ref);
    _ = try rt.store.derefChecked(u64, enlarged_backing_ref);
    _ = try rt.store.derefChecked(u32, full_shape_ref);

    private_roots.deinit();
    private_roots_open = false;
    heap.deinit();
    heap_open = false;
    try rt.collect();
    try testing.expectError(
        error.InvalidRef,
        rt.store.derefChecked(TensorHolder, exported_view_ref),
    );
    try testing.expectError(
        error.InvalidRef,
        rt.store.derefChecked(TensorHolder, exported_full_ref),
    );
    try testing.expectError(
        error.InvalidRef,
        rt.store.derefChecked(u64, enlarged_backing_ref),
    );
    try testing.expectError(
        error.InvalidRef,
        rt.store.derefChecked(u32, view_shape_ref),
    );
    try testing.expectError(
        error.InvalidRef,
        rt.store.derefChecked(u32, full_shape_ref),
    );
}

test "EvalHeap: failed tensor enlargement preserves published aliases" {
    const testing = std.testing;
    const rt = try Runtime.init(testing.allocator, testing.io);
    defer rt.deinit();
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var ledger = Budget.init(testing.io, 1008, .{
        .work = 10_000_000,
        .bytes = 128 * 1024 * 1024,
        .objects = 1_000_000,
        .nodes = 1_000_000,
    });
    var lease = try Budget.Lease.root(&ledger, 5_000_000);
    var account = Budget.AccountAllocator.init(
        failing.allocator(),
        &lease,
        .transform,
    );
    var output: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var context = try EvalContext.limited(
        rt,
        rt.intrinsics.registryVersion(),
        &account,
        .{ .writer = &writer, .bounded_memory = true },
        .{},
    );
    const heap = try Heap.init(&context);
    defer heap.deinit();

    const backing = try rt.store.allocSlice(u64, 3);
    backing.slice[0] = 1;
    backing.slice[1] = 2;
    backing.slice[2] = 3;
    const right_value = try testTensorView(rt.store, .i64, &.{2}, backing, 1, 3);
    const left_value = try testTensorView(rt.store, .i64, &.{2}, backing, 0, 2);
    var source_roots = TestValueRoots.init(rt);
    defer source_roots.deinit();
    try source_roots.add(right_value);
    try source_roots.add(left_value);
    try rt.collect();

    const private_right = (try heap.importValue(&context, right_value))
        .obj.toRef().deref(TensorHolder);

    private_right.data[0] = 77;
    const published_pointer = @intFromPtr(private_right.data.ptr);

    // Fill the memo so this import must request backing metadata after copying
    // an enlarged interval. The allocator failure must leave published views intact.
    while (heap.import_tensors.backings.items.len < heap.import_tensors.backings.capacity) {
        const filler_backing = try rt.store.allocSlice(u64, 1);
        filler_backing.slice[0] = 11;
        const filler = try testTensorView(rt.store, .i64, &.{1}, filler_backing, 0, 1);
        _ = try heap.importValue(&context, filler);
    }
    failing.fail_index = failing.alloc_index;

    try testing.expectError(
        error.OutOfMemory,
        heap.importValue(&context, left_value),
    );
    try testing.expect(!ledger.isExhausted());
    failing.fail_index = std.math.maxInt(usize);
    try heap.runtime.collect();
    try testing.expectEqual(
        published_pointer,
        @intFromPtr(private_right.data.ptr),
    );
    try testing.expectEqual(@as(u64, 77), private_right.data[0]);
    try testing.expectEqual(@as(u64, 2), backing.slice[1]);

    const private_left = (try heap.importValue(&context, left_value))
        .obj.toRef().deref(TensorHolder);
    try heap.runtime.collect();
    try testing.expectEqual(@as(u64, 77), private_left.data[1]);
    try testing.expectEqual(
        @intFromPtr(private_left.data.ptr + 1),
        @intFromPtr(private_right.data.ptr),
    );
}
