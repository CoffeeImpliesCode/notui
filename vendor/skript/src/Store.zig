const std = @import("std");
const tracy = @import("tracy");
const builtin = @import("builtin");
const Budget = @import("Budget.zig");
const MemAllocator = std.mem.Allocator;
const skript = @import("root.zig");
const Sym = skript.Sym;

/// 8-byte minimum alignment wrapper around the store's base allocator.
/// emmalloc (wasm32) can return 4-aligned blocks for small sizes, but the
/// Ref tagged-pointer scheme (3 low tag bits) requires every Store
/// allocation to be 8-aligned — the SlocTable/cons cells were landing
/// 4-aligned on wasm32 and tripping the unsafeTaggedRef assert at boot.
/// On hosts whose allocator already honours 8-byte alignment this is a
/// pass-through (requested alignment is lifted to at least 8).
const Align8 = struct {
    parent: MemAllocator,

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Align8 = @ptrCast(@alignCast(ctx));
        return self.parent.rawAlloc(len, lift(alignment), ret_addr);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Align8 = @ptrCast(@alignCast(ctx));
        return self.parent.rawResize(memory, lift(alignment), new_len, ret_addr);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Align8 = @ptrCast(@alignCast(ctx));
        return self.parent.rawRemap(memory, lift(alignment), new_len, ret_addr);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Align8 = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(memory, lift(alignment), ret_addr);
    }
    inline fn lift(a: std.mem.Alignment) std.mem.Alignment {
        return if (a.compare(.lt, .@"8")) .@"8" else a;
    }
    fn allocator(self: *Align8) MemAllocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
};

pub const ref_shift = 3;

pub const TraceFn = *const fn (*const anyopaque, usize, *MarkVisitor) anyerror!void;
pub const FinalizeFn = *const fn (*anyopaque, usize) void;
pub const AllocationType = struct {
    type_token: *const anyopaque,
    trace: TraceFn,
    item_size: usize,
    finalize: ?FinalizeFn = null,
};

pub const Header = extern struct {
    /// A Store edge, or foreign lifetime-owned metadata when marked as such.
    meta: Ref = .nil,
    allocation_type: ?*const AllocationType = null,
    extent: usize = 0,
    tag: u16 = 0,
    _pad: [6]u8 = @splat(0),
};

pub const header_size = @sizeOf(Header);

comptime {
    if (header_size % 8 != 0) @compileError("Header size must be 8-byte aligned");
}

pub const Ref = packed struct(u64) {
    meta: u3 = 0,
    ptr: u45 = 0,
    tag: u16 = 0,

    pub const nil: Ref = .{};

    /// Create a Ref from a raw pointer. No tag tracking (tag = 0).
    /// Must only be used when the *T was obtained from a Ref originally
    /// and the Ref has been discarded. Prefer holding onto the original Ref.
    pub fn unsafeTaggedRef(ptr: anytype) Ref {
        const a = @intFromPtr(ptr);
        std.debug.assert(a & 0x7 == 0);
        return .{ .ptr = @truncate(a >> ref_shift) };
    }

    pub fn fromAddr(ptr: anytype, tag: u16) Ref {
        const a = @intFromPtr(ptr);
        std.debug.assert(a & 0x7 == 0);
        return .{ .ptr = @truncate(a >> ref_shift), .tag = tag };
    }

    /// This metadata belongs to an arena that outlives this Store.
    /// It is not a collectible Store edge and must never be a root.
    pub fn foreignMetadata(ptr: anytype) Ref {
        var ref = unsafeTaggedRef(ptr);
        ref.meta = 1;
        return ref;
    }

    pub fn isForeignMetadata(self: Ref) bool {
        return self.meta == 1 and self.tag == 0 and self.ptr != 0;
    }

    pub fn address(self: Ref) usize {
        return @as(usize, @intCast(self.ptr)) << ref_shift;
    }

    /// Dereference a tagged Store allocation with type and generation checks.
    /// Untagged pointers require a separate owner/lifetime guarantee. Use
    /// Store.derefChecked at host boundaries to reject foreign pointers safely.
    pub fn deref(self: Ref, comptime T: type) *T {
        std.debug.assert(!self.isNull());
        if (self.tag != 0) {
            const header: *const Header = @ptrFromInt(self.address() - header_size);
            const descriptor = header.allocation_type orelse @panic("Ref.deref: invalid allocation");
            if (descriptor.type_token != typeToken(T)) @panic("Ref.deref: type mismatch");
            if (header.tag != self.tag) @panic("Ref.deref: stale allocation");
        }
        return @ptrFromInt(self.address());
    }

    pub fn isNull(self: Ref) bool {
        return @as(u64, @bitCast(self)) == 0;
    }

    pub fn toObject(self: Ref) Object {
        return @fromBackingInt(@intCast(@as(u64, @bitCast(self))));
    }

    pub fn bits(self: Ref) u64 {
        return @bitCast(self);
    }
};
pub fn TypedSlice(comptime T: type) type {
    return struct {
        ref: Ref,
        slice: []T,
    };
}

fn typeToken(comptime T: type) *const anyopaque {
    const Token = struct {
        var value: u8 = @truncate(@sizeOf(T));
    };
    return @ptrCast(&Token.value);
}

pub const MarkVisitor = struct {
    pub const GuardTraceFn = *const fn (*const anyopaque, *MarkVisitor) anyerror!void;
    pub const max_guard_depth = 64;
    const GuardFrame = struct {
        trace: GuardTraceFn,
        context: *const anyopaque,
    };

    store: *Store,
    pending: *std.ArrayList(Ref),
    guard_frames: [max_guard_depth]GuardFrame = undefined,
    guard_depth: usize = 0,

    pub fn visit(self: *MarkVisitor, reference: Ref) anyerror!void {
        try self.store.queueMark(self.pending, reference);
    }

    pub fn visitValue(self: *MarkVisitor, value: skript.Value) anyerror!void {
        try traceRuntimeValue(&value, self);
    }

    /// Resolve an interior pointer and verify its entire typed payload span.
    pub fn visitSpan(self: *MarkVisitor, address: usize, bytes: usize) anyerror!void {
        try self.store.queueAddressMark(self.pending, address, bytes);
    }

    pub fn visitAddress(self: *MarkVisitor, address: usize) anyerror!void {
        try self.visitSpan(address, 1);
    }

    /// Visit a guard's declared Store edges with bounded, cycle-checked recursion.
    pub fn visitGuard(
        self: *MarkVisitor,
        trace: GuardTraceFn,
        context: *const anyopaque,
    ) anyerror!void {
        for (self.guard_frames[0..self.guard_depth]) |frame| {
            if (frame.trace == trace and frame.context == context) {
                return error.UntracedAllocation;
            }
        }
        if (self.guard_depth == max_guard_depth) return error.UntracedAllocation;

        self.guard_frames[self.guard_depth] = .{ .trace = trace, .context = context };
        self.guard_depth += 1;
        defer self.guard_depth -= 1;
        try trace(context, self);
    }
};

pub const Root = struct {
    ref: Ref = .nil,
    next: ?*Root = null,
    store: ?*Store = null,

    pub fn init(ref: Ref) Root {
        return .{ .ref = ref };
    }
};

pub const RootTraceFn = *const fn (*anyopaque, *MarkVisitor) anyerror!void;
pub const RootProvider = struct {
    context: *anyopaque,
    trace: RootTraceFn,
    next: ?*RootProvider = null,
    store: ?*Store = null,
};
/// The caller guarantees that every Store mutator is stopped while this token is used.
pub const StoppedWorld = struct { store: *Store };

pub const Object = enum(u64) {
    null = 0,
    _,
    pub fn fromRef(ref: Ref) Object {
        return @fromBackingInt(@intCast(@as(u64, @bitCast(ref))));
    }
    pub fn toRef(self: Object) Ref {
        std.debug.assert(self != .null);
        return @bitCast(@as(u64, @backingInt(self)));
    }
    pub fn unwrapNull(self: Object) ?Object {
        return if (self == .null) null else self;
    }
    pub fn from(val: anytype) Object {
        const t = comptime @TypeOf(val);
        return switch (@typeInfo(t)) {
            .@"enum" => @fromBackingInt(@intCast(@as(u64, @intCast(@backingInt(val))))),
            .int => |info| @fromBackingInt(@intCast(@as(u64, @as(@Int(.unsigned, info.bits), @bitCast(val))))),
            else => @fromBackingInt(@intCast(@as(u64, @bitCast(val)))),
        };
    }
    pub fn as(self: Object, comptime T: type) T {
        return @bitCast(@as(u64, @backingInt(self)));
    }
    pub fn fromError(e: skript.Error) Object {
        return @fromBackingInt(@intCast(@backingInt(ErrorObject.fromError(e))));
    }
    pub fn toError(self: Object) skript.Error {
        return (@as(ErrorObject, @fromBackingInt(@intCast(@backingInt(self))))).toError();
    }
    pub fn fromPtr(ptr: anytype) Object {
        return @fromBackingInt(@intCast(@intFromPtr(ptr)));
    }
    pub fn toPtr(self: Object, comptime Ptr: type) Ptr {
        std.debug.assert(self != .null);
        return @ptrFromInt(@as(usize, @intCast(@backingInt(self))));
    }
    pub fn fromInt(idx: anytype) Object {
        return @fromBackingInt(@intCast(idx));
    }
    pub fn toInt(self: Object, comptime Int: type) Int {
        const raw: u64 = @backingInt(self);
        const u = @Int(.unsigned, @bitSizeOf(Int));
        const t: u = @truncate(raw);
        if (@as(u64, t) != raw) @panic("toInt: illegal read");
        return @bitCast(t);
    }
    pub fn fromf16(v: f16) Object {
        return Object.from([4]f16{ v, 0, 0, 0 });
    }
    pub fn tof16(self: Object) f16 {
        return self.as([4]f16)[0];
    }
    pub fn fromf64(v: f64) Object {
        return Object.from(v);
    }
    pub fn tof64(self: Object) f64 {
        return self.as(f64);
    }
    pub fn fromf32(v: f32) Object {
        return Object.from([2]f32{ v, 0 });
    }
    pub fn tof32(self: Object) f32 {
        return self.as([2]f32)[0];
    }
    pub fn fromBool(v: bool) Object {
        return @fromBackingInt(@intCast(@intFromBool(v)));
    }
    pub fn toBool(self: Object) bool {
        return @backingInt(self) != 0;
    }
};

pub const ErrorObject = enum(u64) {
    Unsupported,
    Assertion,
    TypeMismatch,
    Unimplemented,
    UnexpectedToken,
    OutOfMemory,
    Unbound,
    UninitializedBinding,
    WriteFailed,
    StackOverflow,
    ArityMismatch,
    InvalidSelector,
    MalformedAst,
    InvalidCode,
    StackUnderflow,
    WouldBlock,
    CircularLoad,
    Raised,
    Exit,
    Denied,
    Exhausted,
    InvalidRegion,
    InvalidHandle,
    InvalidNode,
    InvalidIdentity,
    InvalidShape,
    Closed,
    Expired,
    LimitExceeded,
    RewriteCycle,
    RewriteLimit,
    pub fn fromError(e: skript.Error) ErrorObject {
        inline for (@typeInfo(ErrorObject).@"enum".field_names) |name| {
            if (e == @field(skript.Error, name)) return @field(ErrorObject, name);
        }
        unreachable;
    }
    pub fn toError(self: ErrorObject) skript.Error {
        inline for (@typeInfo(ErrorObject).@"enum".field_names) |name| {
            if (self == @field(ErrorObject, name)) return @field(skript.Error, name);
        }
        unreachable;
    }
};

pub const Color = enum(u3) { white, grey, black, forwarding };
pub const BarrierFn = *const fn (*Store, *u64, u64, u64) void;
pub const Stats = struct {
    heap_reserved: u64,
    heap_committed: u64,
    heap_used: u64,
    folio_count: u32,
    live_objects: u32,
    gc_cycles: u32,
    last_gc_ns: u64,
    raw_allocations: u64,
    symbol_count: u32,
};
pub const Folio = struct {
    // A separate typed bitmap prevents the collector from reading raw slot bytes.
    bitmap: u64 align(8) = std.math.maxInt(u64),
    typed_bitmap: u64 align(8) = 0,
    next: ?*Folio = null,
    class: u8 = 0,
    free_listed: bool = false,

    comptime {
        if (@sizeOf(Folio) % 8 != 0) @compileError("Folio size must be 8-aligned");
    }
};

const LargeKind = enum { free, reserved, raw, typed };
const LargeObj = struct {
    next: ?*LargeObj,
    ptr: []u8,
    capacity: usize,
    alignment: usize,
    payload_address: usize = 0,
    kind: LargeKind = .free,
};
const FolioSlot = struct {
    folio: *Folio,
    index: usize,
    start: usize,
    offset: usize,
};
const AllocatedBytes = struct {
    ptr: *anyopaque,
    folio: ?*Folio,
};
const LocatedAllocation = union(enum) {
    folio: FolioSlot,
    large: *LargeObj,
};
const Allocation = struct {
    header: *Header,
    location: LocatedAllocation,
};
const supports_mmap = builtin.os.tag != .windows and !builtin.cpu.arch.isWasm();
const heap_size = 2 << 30;
const max_size_classes = 12;
const slots_per_folio = 64;
const size_classes: [max_size_classes]u16 = .{ 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384 };
fn classForSize(s: usize) usize {
    // Size classes are powers of 2 from 8 to 16384.
    // ceil(log2(s)) gives the bit index. Subtract 3 (log2(8)) for the class.
    // s == 0: no allocation needed, but still route to smallest class for callers.
    if (s == 0) return 0;
    const log2 = std.math.log2_int_ceil(usize, s);
    const idx = log2 -| 3;
    return if (idx >= max_size_classes) max_size_classes else idx;
}

fn allocationType(
    comptime T: type,
    comptime trace: TraceFn,
    comptime finalize: ?FinalizeFn,
) *const AllocationType {
    const Descriptor = struct {
        const value: AllocationType = .{
            .type_token = typeToken(T),
            .trace = trace,
            .item_size = @sizeOf(T),
            .finalize = finalize,
        };
    };
    return &Descriptor.value;
}

fn defaultTrace(comptime T: type) TraceFn {
    const Tracer = struct {
        fn trace(data: *const anyopaque, extent: usize, visitor: *MarkVisitor) anyerror!void {
            const values: [*]const T = @ptrCast(@alignCast(data));
            for (0..extent) |index| try traceValue(T, &values[index], visitor);
        }
    };
    return &Tracer.trace;
}

fn hasTraceEdges(comptime T: type) bool {
    if (T == Ref or T == skript.Value or T == Object) return true;
    if (T == skript.Sym) return false;
    if (comptime skript.intrinsics.ffi_enabled) {
        if (T == skript.intrinsics.ffi.Function) return true;
    }

    return switch (@typeInfo(T)) {
        .array => |info| hasTraceEdges(info.child),
        .@"struct" => |info| blk: {
            inline for (info.field_types, info.field_attrs) |field_type, attrs| {
                if (!attrs.@"comptime" and hasTraceEdges(field_type)) break :blk true;
            }
            break :blk false;
        },
        .optional => |info| hasTraceEdges(info.child),
        .@"union" => |info| blk: {
            inline for (info.field_types) |field_type| {
                if (hasTraceEdges(field_type)) break :blk true;
            }
            break :blk false;
        },
        .pointer => true,
        .error_union => true,
        else => false,
    };
}

fn traceValue(comptime T: type, value: *const T, visitor: *MarkVisitor) anyerror!void {
    if (T == Ref) {
        try visitor.visit(value.*);
        return;
    }
    if (T == skript.Value) {
        try traceRuntimeValue(value, visitor);
        return;
    }
    if (T == Object) return error.UntracedAllocation;
    if (T == skript.Sym) return;
    if (T == skript.data.Type) {
        try traceTypeDescriptors(
            @ptrCast(value),
            1,
            visitor,
        );
        return;
    }
    if (T == skript.data.Closure) {
        try traceClosures(@ptrCast(value), 1, visitor);
        return;
    }
    if (T == skript.data.Namespace) {
        try traceNamespaces(@ptrCast(value), 1, visitor);
        return;
    }
    if (T == skript.data.Method) {
        try traceMethods(@ptrCast(value), 1, visitor);
        return;
    }
    if (T == skript.scheduler.FutureObj) {
        try traceFutures(@ptrCast(value), 1, visitor);
        return;
    }
    if (T == skript.Runtime.FnTableEntry) {
        try traceFunctionEntries(@ptrCast(value), 1, visitor);
        return;
    }
    if (comptime skript.intrinsics.ffi_enabled) {
        if (T == skript.intrinsics.ffi.Function) {
            try traceForeignFunctions(@ptrCast(value), 1, visitor);
            return;
        }
    }

    switch (@typeInfo(T)) {
        .void, .bool, .int, .float, .@"enum", .@"fn" => return,
        .array => |info| {
            if (comptime !hasTraceEdges(info.child)) return;
            for (0..info.len) |index| {
                try traceValue(info.child, &value.*[index], visitor);
            }
        },
        .@"struct" => |info| {
            if (info.layout == .@"packed") return error.UntracedAllocation;
            inline for (info.field_names, info.field_types, info.field_attrs) |name, field_type, attrs| {
                if (!attrs.@"comptime" and hasTraceEdges(field_type)) {
                    try traceValue(field_type, &@field(value.*, name), visitor);
                }
            }
        },
        .optional => |info| {
            if (value.*) |*payload| try traceValue(info.child, payload, visitor);
        },
        .@"union" => |info| {
            if (info.tag_type) |Tag| {
                const active = std.meta.activeTag(value.*);
                inline for (info.field_names, info.field_types) |name, field_type| {
                    if (active == @field(Tag, name) and hasTraceEdges(field_type)) {
                        try traceValue(field_type, &@field(value.*, name), visitor);
                    }
                }
            } else {
                return error.UntracedAllocation;
            }
        },
        .pointer => |info| switch (info.size) {
            .slice => {
                const slice = value.*;
                if (slice.len == 0) return;
                try visitor.store.queueAddressMark(
                    visitor.pending,
                    @intFromPtr(slice.ptr),
                    std.math.mul(usize, slice.len, @sizeOf(info.child)) catch
                        return error.InvalidRef,
                );
                if (comptime hasTraceEdges(info.child)) {
                    for (slice) |*item| try traceValue(info.child, item, visitor);
                }
            },
            else => return error.UntracedAllocation,
        },
        .error_union => return error.UntracedAllocation,
        else => return error.UntracedAllocation,
    }
}

fn traceTypeObject(object: Object, visitor: *MarkVisitor) anyerror!void {
    if (@backingInt(object) <= skript.builtins.type_last_idx) return;
    try visitor.visit(object.toRef());
}

fn traceTypeDescriptors(
    data: *const anyopaque,
    extent: usize,
    visitor: *MarkVisitor,
) anyerror!void {
    const descriptors: [*]const skript.data.Type = @ptrCast(@alignCast(data));
    for (0..extent) |index| {
        const descriptor = descriptors[index];
        try traceTypeObject(descriptor.meta, visitor);
        try visitor.visitValue(descriptor.show);
        try visitor.visitValue(descriptor.display);
        try visitor.visitValue(descriptor.apply);
    }
}

fn traceValueSlice(values: []const skript.Value, visitor: *MarkVisitor) anyerror!void {
    try traceOptionalStoreBacking(
        @intFromPtr(values.ptr),
        values.len,
        @sizeOf(skript.Value),
        visitor,
    );
    for (values) |value| try visitor.visitValue(value);
}

fn traceFunctionEntry(entry: skript.Runtime.FnTableEntry, visitor: *MarkVisitor) anyerror!void {
    try visitor.visitValue(entry.source);
    try visitor.visitValue(entry.body);
    try traceValueSlice(entry.constants, visitor);
    try traceOptionalStoreBacking(
        @intFromPtr(entry.arglist.ptr),
        entry.arglist.len,
        @sizeOf(skript.Code.Symbol),
        visitor,
    );
    try traceOptionalStoreBacking(
        @intFromPtr(entry.capture_syms.ptr),
        entry.capture_syms.len,
        @sizeOf(skript.Code.Symbol),
        visitor,
    );
    try traceOptionalStoreBacking(
        @intFromPtr(entry.ir.ptr),
        entry.ir.len,
        @sizeOf(skript.regvm.Inst),
        visitor,
    );
    try traceOptionalStoreBacking(
        @intFromPtr(entry.closure_sites.ptr),
        entry.closure_sites.len,
        @sizeOf(@TypeOf(entry.closure_sites[0])),
        visitor,
    );
    try traceOptionalStoreBacking(
        @intFromPtr(entry.capture_regs.ptr),
        entry.capture_regs.len,
        @sizeOf(u8),
        visitor,
    );
}

fn traceFunctionEntries(
    data: *const anyopaque,
    extent: usize,
    visitor: *MarkVisitor,
) anyerror!void {
    const entries: [*]const skript.Runtime.FnTableEntry = @ptrCast(@alignCast(data));
    for (0..extent) |index| try traceFunctionEntry(entries[index], visitor);
}

fn traceClosures(
    data: *const anyopaque,
    extent: usize,
    visitor: *MarkVisitor,
) anyerror!void {
    const closures: [*]const skript.data.Closure = @ptrCast(@alignCast(data));
    for (0..extent) |index| {
        const closure = closures[index];
        try visitor.visitValue(closure.parent_ns);
        try visitor.visitValue(closure.source);
        try traceValueSlice(closure.constants, visitor);
        try traceValueSlice(closure.captures, visitor);
        try traceOptionalStoreBacking(
            @intFromPtr(closure.arglist.ptr),
            closure.arglist.len,
            @sizeOf(skript.Sym),
            visitor,
        );
        try traceOptionalStoreBacking(
            @intFromPtr(closure.capture_syms.ptr),
            closure.capture_syms.len,
            @sizeOf(skript.Sym),
            visitor,
        );
        try traceOptionalStoreBacking(
            @intFromPtr(closure.ir.ptr),
            closure.ir.len,
            @sizeOf(skript.regvm.Inst),
            visitor,
        );
        try traceOptionalStoreBacking(
            @intFromPtr(closure.fns.ptr),
            closure.fns.len,
            @sizeOf(skript.Runtime.FnTableEntry),
            visitor,
        );
        for (closure.fns) |entry| try traceFunctionEntry(entry, visitor);
        if (closure.guard) |guard| {
            try traceOptionalStoreBacking(@intFromPtr(guard), 1, @sizeOf(skript.data.ClosureGuard), visitor);
            const trace = guard.trace orelse return error.UntracedAllocation;
            try visitor.visitGuard(trace, guard.context);
        }
    }
}

fn traceNamespaces(
    data: *const anyopaque,
    extent: usize,
    visitor: *MarkVisitor,
) anyerror!void {
    const namespaces: [*]const skript.data.Namespace = @ptrCast(@alignCast(data));
    for (0..extent) |index| {
        const namespace = namespaces[index];
        if (namespace.get == skript.HashMapNamespace.vtable.get) {
            const state: *const skript.HashMapNamespace =
                @ptrCast(@alignCast(namespace.data));
            try traceOptionalStoreBacking(@intFromPtr(state), 1, @sizeOf(skript.HashMapNamespace), visitor);
            try traceOptionalStoreBacking(
                @intFromPtr(state.bindings),
                1,
                @sizeOf(@TypeOf(state.bindings.*)),
                visitor,
            );
            try visitor.visitValue(state.parent);
            var iterator = state.bindings.iterator();
            while (iterator.next()) |entry| try visitor.visitValue(entry.value_ptr.*);
            var imported = state.imports.valueIterator();
            while (imported.next()) |source| try visitor.visitValue(source.namespace);
        } else if (namespace.get == skript.SmallNamespace.vtable.get) {
            const state: *const skript.SmallNamespace =
                @ptrCast(@alignCast(namespace.data));
            try traceOptionalStoreBacking(@intFromPtr(state), 1, @sizeOf(skript.SmallNamespace), visitor);
            try visitor.visitValue(state.parent);
            for (state.values) |value| try visitor.visitValue(value);
        } else if (namespace.get == skript.data.ExportNamespace.vtable.get) {
            const state: *const skript.data.ExportNamespace =
                @ptrCast(@alignCast(namespace.data));
            try traceOptionalStoreBacking(@intFromPtr(state), 1, @sizeOf(skript.data.ExportNamespace), visitor);
            try visitor.visitValue(state.private);
            try visitor.visitValue(state.parent);
            var exported = state.names.valueIterator();
            while (exported.next()) |source| try visitor.visitValue(source.namespace);
        } else {
            return error.UntracedAllocation;
        }
    }
}

fn traceMethods(
    data: *const anyopaque,
    extent: usize,
    visitor: *MarkVisitor,
) anyerror!void {
    const methods: [*]const skript.data.Method = @ptrCast(@alignCast(data));
    for (0..extent) |index| {
        var iterator = methods[index].resolved.iterator();
        while (iterator.next()) |entry| try visitor.visitValue(entry.value_ptr.*);
    }
}

fn traceFutures(
    data: *const anyopaque,
    extent: usize,
    visitor: *MarkVisitor,
) anyerror!void {
    const futures: [*]const skript.scheduler.FutureObj = @ptrCast(@alignCast(data));
    for (0..extent) |index| {
        try visitor.visitValue(futures[index].result);
    }
}

fn traceForeignFunctions(
    data: *const anyopaque,
    extent: usize,
    visitor: *MarkVisitor,
) anyerror!void {
    const functions: [*]const skript.intrinsics.ffi.Function = @ptrCast(@alignCast(data));
    for (0..extent) |index| {
        const function = functions[index];
        try visitor.visitValue(function.ret);
        if (function.library_symbol) |symbol| try visitor.visitAddress(@intFromPtr(symbol));
        if (function.next_plan) |next| {
            try visitor.visitAddress(@intFromPtr(next));
        }
    }
}

fn traceOptionalStoreBacking(
    address: usize,
    count: usize,
    item_size: usize,
    visitor: *MarkVisitor,
) anyerror!void {
    const bytes = std.math.mul(usize, count, item_size) catch return error.InvalidRef;
    if (bytes == 0) return;
    visitor.store.queueAddressMark(visitor.pending, address, bytes) catch |err| switch (err) {
        error.ForeignReference => {},
        else => return err,
    };
}

fn rejectStoreOwnedHostAddress(address: usize, visitor: *MarkVisitor) anyerror!void {
    _ = visitor.store.addressReference(address, 1) catch |err| switch (err) {
        error.ForeignReference => return,
        else => return err,
    };
    return error.InvalidRef;
}

fn traceRuntimeValue(value: *const skript.Value, visitor: *MarkVisitor) anyerror!void {
    const b = skript.builtins;
    if (@backingInt(value.typ) == b.type_last_idx + 1 and value.obj == .null) return;
    try traceTypeObject(value.typ, visitor);
    switch (value.typ) {
        b.type_nil => if (value.obj != .null) return error.UntracedAllocation,
        b.type_bool => if (@backingInt(value.obj) > 1) return error.UntracedAllocation,
        b.type_i8,
        b.type_i16,
        b.type_i32,
        b.type_i64,
        b.type_u8,
        b.type_u16,
        b.type_u32,
        b.type_u64,
        b.type_f8,
        b.type_f16,
        b.type_f32,
        b.type_f64,
        b.type_c8,
        b.type_c16,
        b.type_c32,
        b.type_cvoid,
        b.type_cbool,
        b.type_cint,
        b.type_cuint,
        b.type_cfloat,
        b.type_cdouble,
        b.type_expr,
        => {},
        // These pointer payloads belong to host arenas, code, or processes.
        b.type_ast,
        b.type_intrinsic,
        b.type_keyword,
        b.type_pid,
        b.type_symbol,
        => {
            if (value.obj == .null) return error.InvalidRef;
            const address = std.math.cast(usize, @backingInt(value.obj)) orelse return error.InvalidRef;
            try rejectStoreOwnedHostAddress(address, visitor);
        },
        b.type_opaque => {
            if (value.obj == .null) return;
            const reference = value.obj.toRef();
            if (reference.tag != 0) {
                try visitor.visit(reference);
            } else {
                const address = std.math.cast(usize, @backingInt(value.obj)) orelse return error.InvalidRef;
                try traceOptionalStoreBacking(
                    address,
                    1,
                    1,
                    visitor,
                );
            }
        },
        b.type_error => if (skript.Value.errorPayloadIsRef(value.obj)) {
            try visitor.visit(value.obj.toRef());
        },
        b.type_string => {
            if (value.obj == .null) return error.InvalidRef;
            // Strings may be backed by Store bytes or by a Runtime/host owner.
            const address = std.math.cast(usize, @backingInt(value.obj)) orelse return error.InvalidRef;
            try traceOptionalStoreBacking(
                address,
                1,
                1,
                visitor,
            );
        },
        b.type_type => try traceTypeObject(value.obj, visitor),
        b.type_cons,
        b.type_c64,
        b.type_bytevector,
        b.type_closure,
        b.type_method,
        b.type_namespace,
        b.type_map,
        b.type_tensor,
        b.type_ffifunc,
        => {
            if (value.obj == .null) return error.InvalidRef;
            try visitor.visit(value.obj.toRef());
        },
        else => return error.UntracedAllocation,
    }
}

pub const Config = struct {
    /// Mmap platforms (native): the max heap, reserved lazily (NORESERVE —
    /// only touched pages are backed).
    heap_size: u64 = heap_size,
    /// Non-mmap platforms (wasm, tests): the max heap, allocated upfront —
    /// these platforms always allocate the full max heap. Hosts with real
    /// workloads (e.g. the web build) pass a larger value.
    max_heap_size: u64 = 1024 * 1024,
    /// Maximum retained raw backing storage across this Store and its adapters.
    retained_bytes: ?u64 = null,
};

pub const Store = @This();
pub const AccountKind = enum { backing, values, both };

const RetainedFailure = struct {
    limit: u64,
    available: u64,
};

const RetainedClaim = union(enum) {
    acquired,
    failed: RetainedFailure,
};

align8: Align8,
align8_sym: Align8,
raw_host: MemAllocator,
mem: MemAllocator,
backing_account: AccountAllocator,
accounted_account: AccountAllocator,
heap_account: AccountAllocator,
sym_account: AccountAllocator,
heap: []u8 = &.{},
color_bitmap: []u8 = &.{},
heap_brk: usize = 0,
folios: std.ArrayList(*Folio) = .empty,
folio_free_lists: [max_size_classes]?*Folio = @splat(null),
active_folios: [max_size_classes]std.atomic.Value(usize) = @splat(.init(0)),
large_head: ?*LargeObj = null,
folio_count: u32 = 0,
raw_allocation_count: std.atomic.Value(usize) = .init(0),
roots: ?*Root = null,
root_providers: ?*RootProvider = null,
root_mutex: std.Io.Mutex = .init,
folio_mutex: std.Io.Mutex = .init,
large_mutex: std.Io.Mutex = .init,
barrier_fn: BarrierFn = &noopBarrier,
gc_active: bool = false,
last_gc_ns: u64 = 0,
gc_cycle_count: u32 = 0,
live_obj_count: std.atomic.Value(u32) = .init(0),
sym_arena: *std.heap.ArenaAllocator,
sym_alloc: MemAllocator,
sym_lookup: std.StringHashMap(Sym),
sym_arena_initialized: bool = false,
sym_lookup_initialized: bool = false,
/// The Io handle (for the sym map mutex). The symbol interning map is
/// mutated by the host's compile and the runner's eval concurrently, so
/// getsym is mutex-guarded.
// SAFETY: assigned in init() before any getsym call; the Store is never
// used before init returns.
io: std.Io = undefined,
sym_mutex: std.Io.Mutex = .init,
retained_mutex: std.Io.Mutex = .init,
retained_limit: ?u64 = null,
retained_used: u64 = 0,
heap_committed: std.atomic.Value(usize) = .init(0),
using_mmap: bool = false,
/// Monotonic SourceUnit identity counter. It is guarded by `sym_mutex`.
source_id_next: u64 = 0,
/// Zero is reserved for methods that have not been published.
method_id_next: u64 = 1,
/// Monotonically increasing allocation tag for debug UAF detection.
alloc_tag: u16 = 0,
/// Single-threaded mode skips atomic barriers in alloc hot path.
thread_safe: bool = true,

pub const AccountAllocator = struct {
    pub const Kind = AccountKind;
    store: *Store,
    base: MemAllocator,
    backend: Budget.Backend,
    kind: Kind,

    const Reservation = struct {
        account: *AccountAllocator,
        budget: ?*Budget,
        credit_reservation: ?*skript.EvalContext.Reservation,
        credit_bytes: u64,
        credit_objects: u64,
        bytes: u64,
        objects: u64,
        retained: u64,

        fn cancel(self: Reservation) void {
            if (self.retained > 0) self.account.store.releaseRetained(self.retained);
            if (self.budget) |budget| {
                budget.cancelAllocation(
                    self.bytes - self.credit_bytes,
                    self.objects - self.credit_objects,
                );
            }
            if (self.credit_reservation) |credit| {
                credit.bytes += self.credit_bytes;
                credit.objects += self.credit_objects;
            }
        }
    };

    const vtable: MemAllocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    pub fn init(
        owner: *Store,
        base: MemAllocator,
        backend: Budget.Backend,
        kind: AccountKind,
    ) AccountAllocator {
        std.debug.assert(base.vtable != &vtable);
        return .{ .store = owner, .base = base, .backend = backend, .kind = kind };
    }

    pub fn allocator(self: *AccountAllocator) MemAllocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn accountsValues(self: *const AccountAllocator) bool {
        return self.kind == .values or self.kind == .both;
    }

    fn accountsBacking(self: *const AccountAllocator) bool {
        return self.kind == .backing or self.kind == .both;
    }
    fn reserve(self: *AccountAllocator, bytes: usize, objects: u64) ?Reservation {
        const bytes_u64 = std.math.cast(u64, bytes) orelse return null;
        const context = skript.EvalContext.currentForStore(self.store);
        const active_budget = if (context) |active| active.budget() else null;
        var budget: ?*Budget = null;
        var credit_reservation: ?*skript.EvalContext.Reservation = null;
        var credit_bytes: u64 = 0;
        var credit_objects: u64 = 0;
        if (self.accountsValues()) {
            if (context) |active| {
                budget = active_budget;
                if (active.reservation) |credit| {
                    credit_reservation = credit;
                    credit_bytes = @min(bytes_u64, credit.bytes);
                    credit_objects = @min(objects, credit.objects);
                }
                active.chargeAllocation(bytes_u64, objects, self.backend) catch return null;
            }
        }
        if (!self.accountsBacking()) {
            return .{
                .account = self,
                .budget = budget,
                .credit_reservation = credit_reservation,
                .credit_bytes = credit_bytes,
                .credit_objects = credit_objects,
                .bytes = bytes_u64,
                .objects = objects,
                .retained = 0,
            };
        }
        switch (self.store.claimRetained(bytes_u64)) {
            .acquired => return .{
                .account = self,
                .budget = budget,
                .credit_reservation = credit_reservation,
                .credit_bytes = credit_bytes,
                .credit_objects = credit_objects,
                .bytes = bytes_u64,
                .objects = objects,
                .retained = bytes_u64,
            },
            .failed => |failure| {
                const provisional = Reservation{
                    .account = self,
                    .budget = budget,
                    .credit_reservation = credit_reservation,
                    .credit_bytes = credit_bytes,
                    .credit_objects = credit_objects,
                    .bytes = bytes_u64,
                    .objects = objects,
                    .retained = 0,
                };
                provisional.cancel();
                if (active_budget) |ledger| {
                    switch (ledger.failRetained(
                        failure.limit,
                        failure.available,
                        bytes_u64,
                        self.backend,
                    )) {
                        error.Exhausted => return null,
                    }
                }
                return null;
            },
        }
    }

    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *AccountAllocator = @ptrCast(@alignCast(raw));
        const reservation = self.reserve(len, 1) orelse return null;
        return self.base.rawAlloc(len, alignment, return_address) orelse {
            reservation.cancel();
            return null;
        };
    }
    fn resize(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *AccountAllocator = @ptrCast(@alignCast(raw));
        const growth = new_len -| memory.len;
        const shrink = memory.len -| new_len;
        const reservation = self.reserve(growth, 0) orelse return false;
        if (self.base.rawResize(memory, alignment, new_len, return_address)) {
            if (self.accountsBacking() and shrink > 0) {
                self.store.releaseRetained(@intCast(shrink));
            }
            return true;
        }
        reservation.cancel();
        return false;
    }

    fn remap(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *AccountAllocator = @ptrCast(@alignCast(raw));
        const reservation = self.reserve(new_len, 1) orelse return null;
        const replacement = self.base.rawRemap(memory, alignment, new_len, return_address) orelse {
            reservation.cancel();
            return null;
        };
        if (self.accountsBacking()) {
            self.store.releaseRetained(@intCast(memory.len));
        }
        return replacement;
    }

    fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *AccountAllocator = @ptrCast(@alignCast(raw));
        self.base.rawFree(memory, alignment, return_address);
        if (self.accountsBacking()) self.store.releaseRetained(@intCast(memory.len));
    }
};

/// Report whether this allocator directly charges the caller's value budget.
pub fn allocatorAccountsValues(alloc: MemAllocator) bool {
    if (alloc.vtable != &AccountAllocator.vtable) return false;
    const account: *const AccountAllocator = @ptrCast(@alignCast(alloc.ptr));
    return account.accountsValues();
}

/// Report whether the current context will charge this allocator's values.
pub fn allocatorAccountsCurrentContext(alloc: MemAllocator) bool {
    if (!allocatorAccountsValues(alloc)) return false;
    const account: *const AccountAllocator = @ptrCast(@alignCast(alloc.ptr));
    return skript.EvalContext.currentForStore(account.store) != null;
}

pub fn init(base_alloc: MemAllocator, io: std.Io, cfg: Config) !*Store {
    const self = try base_alloc.create(Store);
    self.* = .{
        .align8 = .{ .parent = self.backingAllocator() },
        // SAFETY: initialized after the symbol arena, before symbol allocation.
        .align8_sym = undefined,
        .raw_host = base_alloc,
        .mem = self.align8.allocator(),
        .backing_account = AccountAllocator.init(self, base_alloc, .native, .backing),
        .accounted_account = AccountAllocator.init(self, base_alloc, .native, .both),
        .heap_account = AccountAllocator.init(self, self.rawAllocator(), .native, .values),
        .sym_account = AccountAllocator.init(self, self.align8_sym.allocator(), .native, .values),
        // SAFETY: assigned before sym_arena_initialized permits cleanup.
        .sym_arena = undefined,
        .sym_alloc = self.sym_account.allocator(),
        // SAFETY: assigned before sym_lookup_initialized permits cleanup.
        .sym_lookup = undefined,
        .io = io,
        .retained_limit = cfg.retained_bytes,
        .using_mmap = supports_mmap and !builtin.is_test,
        .thread_safe = !builtin.is_test and !builtin.cpu.arch.isWasm(),
    };
    errdefer {
        if (self.sym_lookup_initialized) {
            self.sym_lookup.deinit();
        }
        if (self.sym_arena_initialized) {
            self.sym_arena.deinit();
            self.backingAllocator().destroy(self.sym_arena);
        }
        self.folios.deinit(self.backingAllocator());
        if (self.color_bitmap.len > 0) {
            if (supports_mmap and self.using_mmap) {
                self.unmap(self.color_bitmap);
            } else {
                self.mem.free(self.color_bitmap);
            }
        }
        if (self.heap.len > 0) {
            if (supports_mmap and self.using_mmap) {
                self.unmap(self.heap);
            } else {
                self.mem.free(self.heap);
            }
        }
        self.raw_host.destroy(self);
    }

    if (supports_mmap and self.using_mmap) {
        const heap_len = std.math.cast(usize, cfg.heap_size) orelse return error.OutOfMemory;
        const bitmap_words = std.math.mul(usize, heap_len / 8, 2) catch return error.OutOfMemory;
        const bitmap_len = std.math.add(usize, bitmap_words, 7) catch return error.OutOfMemory;
        const map_flags = blk: {
            var flags: std.posix.system.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
            if (@hasField(@TypeOf(flags), "NORESERVE")) {
                flags.NORESERVE = true;
            }
            break :blk flags;
        };
        try self.retainRaw(heap_len, .native);
        self.heap = std.posix.mmap(
            null,
            heap_len,
            .{ .READ = true, .WRITE = true },
            map_flags,
            -1,
            0,
        ) catch |err| {
            self.releaseRetained(heap_len);
            return err;
        };
        try self.retainRaw(bitmap_len / 8, .native);
        self.color_bitmap = std.posix.mmap(
            null,
            bitmap_len / 8,
            .{ .READ = true, .WRITE = true },
            map_flags,
            -1,
            0,
        ) catch |err| {
            self.releaseRetained(bitmap_len / 8);
            return err;
        };
    } else {
        const heap_len = std.math.cast(usize, cfg.max_heap_size) orelse return error.OutOfMemory;
        const bitmap_words = std.math.mul(usize, heap_len / 8, 2) catch return error.OutOfMemory;
        const bitmap_len = std.math.add(usize, bitmap_words, 7) catch return error.OutOfMemory;
        self.heap = try self.mem.alloc(u8, heap_len);
        self.color_bitmap = try self.mem.alloc(u8, bitmap_len / 8);
    }

    self.sym_arena = try self.backingAllocator().create(std.heap.ArenaAllocator);
    self.sym_arena_initialized = true;
    self.sym_arena.* = .init(self.backingAllocator());
    self.align8_sym = .{ .parent = self.sym_arena.allocator() };
    self.sym_lookup = .init(self.sym_alloc);
    self.sym_lookup_initialized = true;
    return self;
}

pub fn initDefault(alloc: MemAllocator, io: std.Io) !*Store {
    return init(alloc, io, .{});
}
pub fn backingAllocator(self: *Store) MemAllocator {
    return self.backing_account.allocator();
}

pub fn accountedAllocator(self: *Store) MemAllocator {
    return self.accounted_account.allocator();
}

fn rawAllocator(self: *Store) MemAllocator {
    const Impl = struct {
        fn alloc(
            ctx: *anyopaque,
            len: usize,
            alignment: std.mem.Alignment,
            _: usize,
        ) ?[*]u8 {
            const owner: *Store = @ptrCast(@alignCast(ctx));
            const alignment_bytes = alignment.toByteUnits();
            if (alignment_bytes > std.math.maxInt(u29)) return null;
            const allocated = owner.allocBytes(len, @intCast(alignment_bytes)) catch return null;
            owner.noteRawAllocation(allocated.ptr);
            return @ptrCast(allocated.ptr);
        }

        fn free(ctx: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
            const owner: *Store = @ptrCast(@alignCast(ctx));
            owner.freeRawAllocation(memory.ptr);
        }

        fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
            return false;
        }

        fn remap(
            _: *anyopaque,
            _: []u8,
            _: std.mem.Alignment,
            _: usize,
            _: usize,
        ) ?[*]u8 {
            return null;
        }
    };
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = Impl.alloc,
            .free = Impl.free,
            .resize = Impl.resize,
            .remap = Impl.remap,
        },
    };
}

fn claimRetained(self: *Store, bytes: u64) RetainedClaim {
    self.retained_mutex.lockUncancelable(self.io);
    defer self.retained_mutex.unlock(self.io);
    if (self.retained_limit) |limit| {
        if (self.retained_used > limit) {
            std.debug.assert(false);
            return .{ .failed = .{ .limit = limit, .available = 0 } };
        }
        if (bytes > limit - self.retained_used) {
            return .{ .failed = .{
                .limit = limit,
                .available = limit - self.retained_used,
            } };
        }
    } else {
        const next = std.math.add(u64, self.retained_used, bytes) catch {
            return .{ .failed = .{
                .limit = std.math.maxInt(u64),
                .available = std.math.maxInt(u64) - self.retained_used,
            } };
        };
        self.retained_used = next;
        return .acquired;
    }
    self.retained_used += bytes;
    return .acquired;
}

fn releaseRetained(self: *Store, bytes: u64) void {
    if (bytes == 0) return;
    self.retained_mutex.lockUncancelable(self.io);
    defer self.retained_mutex.unlock(self.io);
    std.debug.assert(bytes <= self.retained_used);
    self.retained_used -= bytes;
}

fn retainRaw(self: *Store, bytes: usize, backend: Budget.Backend) !void {
    switch (self.claimRetained(@intCast(bytes))) {
        .acquired => {},
        .failed => |failure| {
            if (skript.EvalContext.currentForStore(self)) |context| {
                if (context.budget()) |budget| {
                    return budget.failRetained(
                        failure.limit,
                        failure.available,
                        @intCast(bytes),
                        backend,
                    );
                }
            }
            return error.OutOfMemory;
        },
    }
}

fn unmap(self: *Store, memory: []u8) void {
    if (memory.len == 0) return;
    if (comptime supports_mmap) {
        const pg = comptime std.heap.page_size_min;
        std.debug.assert(@intFromPtr(memory.ptr) % pg == 0);
        const ptr: [*]align(pg) u8 = @alignCast(memory.ptr);
        std.posix.munmap(ptr[0..memory.len]);
    }
    self.releaseRetained(@intCast(memory.len));
}

pub fn retainedBytes(self: *Store) u64 {
    self.retained_mutex.lockUncancelable(self.io);
    defer self.retained_mutex.unlock(self.io);
    return self.retained_used;
}

pub fn deinit(self: *Store) void {
    finalizeLiveAllocations(self);
    self.sym_lookup.deinit();
    self.sym_arena.deinit();
    self.backingAllocator().destroy(self.sym_arena);
    self.folios.deinit(self.backingAllocator());

    if (supports_mmap and self.using_mmap) {
        self.unmap(self.heap);
        self.unmap(self.color_bitmap);
    } else {
        if (self.heap.len > 0) self.mem.free(self.heap);
        if (self.color_bitmap.len > 0) self.mem.free(self.color_bitmap);
    }

    const raw_host = self.raw_host;
    self.* = undefined;
    raw_host.destroy(self);
}

/// Allocate a header-backed value in an explicitly owned arena.
/// The caller must keep the arena alive for every borrow of the returned Ref.
/// Store collection rejects this Ref because its owner is outside the Store.
pub fn createOwned(comptime T: type, allocator_arg: MemAllocator) error{OutOfMemory}!Ref {
    const alignment = comptime @max(8, @alignOf(T));
    const offset = comptime std.mem.alignForward(usize, header_size, alignment);
    const size = std.math.add(usize, offset, @sizeOf(T)) catch return error.OutOfMemory;
    const bytes = try allocator_arg.alignedAlloc(
        u8,
        comptime std.mem.Alignment.fromByteUnits(alignment),
        size,
    );
    const payload: *T = @ptrCast(@alignCast(bytes.ptr + offset));
    const header: *Header = @ptrCast(@alignCast(bytes.ptr + offset - header_size));
    header.* = .{
        .meta = .nil,
        .allocation_type = allocationType(T, defaultTrace(T), null),
        .extent = 1,
    };
    return Ref.fromAddr(payload, 0);
}

pub fn create(self: *Store, comptime T: type) !Ref {
    return self.createTyped(T, defaultTrace(T), null, 1, @sizeOf(T));
}

/// Allocate a typed object with an explicit trace for pointer-bearing fields.
pub fn createTraced(self: *Store, comptime T: type, comptime trace: TraceFn) !Ref {
    return self.createTyped(T, trace, null, 1, @sizeOf(T));
}

/// Allocate an object whose external resources are released once on sweep or Store.deinit.
/// Finalizers must not re-enter Store collection or root registration. Callers must release
/// resources themselves when they discard an unpublished allocation.
pub fn createManaged(
    self: *Store,
    comptime T: type,
    comptime trace: TraceFn,
    comptime finalize: FinalizeFn,
) !Ref {
    return self.createTyped(T, trace, finalize, 1, @sizeOf(T));
}

pub fn allocSlice(
    self: *Store,
    comptime T: type,
    count: usize,
) !TypedSlice(T) {
    return self.allocSliceWithTrace(T, defaultTrace(T), count);
}

/// Allocate a typed slice with an explicit trace for pointer-bearing elements.
pub fn allocSliceTraced(
    self: *Store,
    comptime T: type,
    comptime trace: TraceFn,
    count: usize,
) !TypedSlice(T) {
    return self.allocSliceWithTrace(T, trace, count);
}

fn allocSliceWithTrace(
    self: *Store,
    comptime T: type,
    comptime trace: TraceFn,
    count: usize,
) !TypedSlice(T) {
    if (count == 0) return .{ .ref = .nil, .slice = &.{} };
    const body_size = std.math.mul(usize, count, @sizeOf(T)) catch return error.OutOfMemory;
    const reference = try self.createTyped(T, trace, null, count, body_size);
    const pointer: [*]T = @ptrCast(reference.deref(T));
    return .{ .ref = reference, .slice = pointer[0..count] };
}

fn createTyped(
    self: *Store,
    comptime T: type,
    comptime trace: TraceFn,
    comptime finalize: ?FinalizeFn,
    extent: usize,
    body_size: usize,
) !Ref {
    const z_create = tracy.Zone.begin(.{ .name = "store-create", .src = @src() });
    defer z_create.end();
    if (self.live_obj_count.load(.acquire) == std.math.maxInt(u32)) {
        return self.allocationError();
    }

    const alignment = @max(8, @alignOf(T));
    const object_offset = std.mem.alignForward(usize, header_size, alignment);
    const size = std.math.add(usize, object_offset, body_size) catch return error.OutOfMemory;
    const aligned = std.math.cast(u29, alignment) orelse return error.OutOfMemory;
    const reservation = self.heap_account.reserve(size, 1) orelse return self.allocationError();
    const allocated = self.allocBytes(size, aligned) catch |err| {
        reservation.cancel();
        return err;
    };
    const raw = allocated.ptr;

    const payload_address = @intFromPtr(raw) + object_offset;
    const payload: *T = @ptrFromInt(payload_address);
    const header: *Header = @ptrFromInt(payload_address - header_size);
    const tag = self.nextTag();
    header.* = .{
        .meta = .nil,
        .allocation_type = allocationType(T, trace, finalize),
        .extent = extent,
        .tag = tag,
    };
    self.recordTypedAllocation(allocated, payload_address);
    _ = self.live_obj_count.fetchAdd(1, .acq_rel);
    return Ref.fromAddr(payload, tag);
}

fn nextTag(self: *Store) u16 {
    while (true) {
        const tag = if (self.thread_safe) blk: {
            const old = @atomicRmw(u16, &self.alloc_tag, .Add, 1, .monotonic);
            break :blk old +% 1;
        } else blk: {
            self.alloc_tag +%= 1;
            break :blk self.alloc_tag;
        };
        if (tag != 0) return tag;
    }
}

pub fn store(self: *Store, comptime T: type, ptr: *T, val: T) void {
    if (self.gc_active) {
        const n = @sizeOf(T) / 8;
        const slots: [*]u64 = @ptrCast(@alignCast(ptr));
        const old: [*]const u64 = @ptrCast(@alignCast(ptr));
        const new_vals: [*]const u64 = @ptrCast(@alignCast(&val));
        for (0..n) |i| {
            self.barrier_fn(self, &slots[i], old[i], new_vals[i]);
        }
    }
    ptr.* = val;
}
pub fn load(self: *Store, comptime T: type, ptr: *const T) T {
    _ = self;
    return ptr.*;
}
/// Return the Store's raw allocator. Blocks are reusable after allocator.free,
/// but any outstanding block makes collect fail with RawAllocationPresent.
/// Raw blocks are never traced because Allocator does not carry an element type.
pub fn allocator(self: *Store) MemAllocator {
    return self.heap_account.allocator();
}

fn allocationError(self: *Store) skript.Error {
    if (skript.EvalContext.currentForStore(self)) |context| {
        if (context.budget()) |budget| {
            if (budget.isExhausted()) return error.Exhausted;
        }
    }
    return error.OutOfMemory;
}

/// Allocate the next Store-scoped SourceUnit identity without wrapping.
pub fn allocSourceId(self: *Store) !u32 {
    self.sym_mutex.lockUncancelable(self.io);
    defer self.sym_mutex.unlock(self.io);
    const max_id: u64 = std.math.maxInt(u32);
    if (self.source_id_next > max_id) return error.Unsupported;
    const result: u32 = @intCast(self.source_id_next);
    self.source_id_next += 1;
    return result;
}

pub fn allocMethodId(self: *Store) error{Unsupported}!u64 {
    self.sym_mutex.lockUncancelable(self.io);
    defer self.sym_mutex.unlock(self.io);
    if (self.method_id_next == std.math.maxInt(u64)) return error.Unsupported;
    const id = self.method_id_next;
    self.method_id_next += 1;
    return id;
}

pub fn getsym(self: *Store, str: []const u8) skript.Error!Sym {
    self.sym_mutex.lockUncancelable(self.io);
    defer self.sym_mutex.unlock(self.io);
    // Intern by an OWNED duplicate (sym_alloc), never by the caller's slice:
    // transient sources (REPL frame-arena query strings, reused every frame)
    // would leave a dangling map key whose content hash silently diverges
    // once the memory is reused — the same name then interns to TWO
    // different Syms, and pointer-keyed namespaces (root_ns) lose the
    // binding: "(def a 1)" answers 1 but a later "(+ a 1)" gets Unbound.
    if (self.sym_lookup.get(str)) |existing| return existing;
    const owned = self.sym_alloc.dupe(u8, str) catch |err| {
        if (err == error.OutOfMemory) return self.allocationError();
        return err;
    };
    const p = self.sym_alloc.create([]const u8) catch |err| {
        if (err == error.OutOfMemory) return self.allocationError();
        return err;
    };
    p.* = owned;
    const gop = self.sym_lookup.getOrPut(owned) catch |err| {
        if (err == error.OutOfMemory) return self.allocationError();
        return err;
    };
    if (gop.found_existing) return gop.value_ptr.*;
    gop.value_ptr.* = p;
    return p;
}

/// Create an explicit proof token after all Store mutators have stopped.
/// This does not stop the Runtime; the caller must synchronize its mutators.
pub fn assumeStopped(self: *Store) StoppedWorld {
    return .{ .store = self };
}

pub fn registerRoot(self: *Store, root: *Root) error{AlreadyRegistered}!void {
    self.root_mutex.lockUncancelable(self.io);
    defer self.root_mutex.unlock(self.io);
    if (root.store != null) return error.AlreadyRegistered;
    root.next = self.roots;
    root.store = self;
    self.roots = root;
}

pub fn unregisterRoot(self: *Store, root: *Root) error{NotRegistered}!void {
    self.root_mutex.lockUncancelable(self.io);
    defer self.root_mutex.unlock(self.io);
    if (root.store != self) return error.NotRegistered;
    var cursor = &self.roots;
    while (cursor.*) |current| {
        if (current == root) {
            cursor.* = current.next;
            current.next = null;
            current.store = null;
            return;
        }
        cursor = &current.next;
    }
    return error.NotRegistered;
}

pub fn registerRootProvider(
    self: *Store,
    provider: *RootProvider,
) error{AlreadyRegistered}!void {
    self.root_mutex.lockUncancelable(self.io);
    defer self.root_mutex.unlock(self.io);
    if (provider.store != null) return error.AlreadyRegistered;
    provider.next = self.root_providers;
    provider.store = self;
    self.root_providers = provider;
}

pub fn unregisterRootProvider(
    self: *Store,
    provider: *RootProvider,
) error{NotRegistered}!void {
    self.root_mutex.lockUncancelable(self.io);
    defer self.root_mutex.unlock(self.io);
    if (provider.store != self) return error.NotRegistered;
    var cursor = &self.root_providers;
    while (cursor.*) |current| {
        if (current == provider) {
            cursor.* = current.next;
            current.next = null;
            current.store = null;
            return;
        }
        cursor = &current.next;
    }
    return error.NotRegistered;
}

pub fn derefChecked(self: *Store, comptime T: type, reference: Ref) anyerror!*T {
    const allocation = try self.findAllocation(reference);
    const descriptor = allocation.header.allocation_type orelse return error.InvalidRef;
    if (descriptor.type_token != typeToken(T)) return error.TypeMismatch;
    if (reference.tag != 0 and allocation.header.tag != reference.tag) {
        return error.InvalidRef;
    }
    return @ptrFromInt(reference.address());
}

/// Release one typed allocation before it escapes to a Value, root, or
/// another allocation. The caller owns the sole reference; children and
/// external resources must be released separately. A zero-length slice has
/// no allocation and may pass Ref.nil.
pub fn discardUnpublished(self: *Store, reference: Ref) anyerror!void {
    if (reference.isNull()) return;
    if (reference.tag == 0) return error.InvalidRef;
    const allocation = try self.findAllocation(reference);
    switch (allocation.location) {
        .folio => |slot| {
            self.folio_mutex.lockUncancelable(self.io);
            defer self.folio_mutex.unlock(self.io);
            const mask = @as(u64, 1) << @intCast(slot.index);
            allocation.header.* = .{};
            const was_typed = if (self.thread_safe and comptime @bitSizeOf(usize) >= 64)
                @atomicRmw(u64, &slot.folio.typed_bitmap, .And, ~mask, .acq_rel)
            else blk: {
                const old = slot.folio.typed_bitmap;
                slot.folio.typed_bitmap &= ~mask;
                break :blk old;
            };
            std.debug.assert(was_typed & mask != 0);
            const was_free = if (self.thread_safe and comptime @bitSizeOf(usize) >= 64)
                @atomicRmw(u64, &slot.folio.bitmap, .Or, mask, .acq_rel)
            else blk: {
                const old = slot.folio.bitmap;
                slot.folio.bitmap |= mask;
                break :blk old;
            };
            std.debug.assert(was_free & mask == 0);
            const class: usize = slot.folio.class;
            const active = self.active_folios[class].load(.acquire);
            if (active != @intFromPtr(slot.folio) and !slot.folio.free_listed) {
                slot.folio.next = self.folio_free_lists[class];
                self.folio_free_lists[class] = slot.folio;
                slot.folio.free_listed = true;
            }
        },
        .large => |large| {
            self.large_mutex.lockUncancelable(self.io);
            defer self.large_mutex.unlock(self.io);
            if (large.kind != .typed or large.payload_address != reference.address()) {
                return error.InvalidRef;
            }
            allocation.header.* = .{};
            large.payload_address = 0;
            large.kind = .free;
        },
    }
    const previous = self.live_obj_count.fetchSub(1, .acq_rel);
    std.debug.assert(previous != 0);
}

/// Collect only while every mutator is stopped and root providers are stable.
/// Raw allocator blocks and unknown/foreign edges fail closed without sweeping.
pub fn collect(self: *Store, stopped: StoppedWorld) anyerror!void {
    if (stopped.store != self) return error.InvalidStopToken;
    if (self.raw_allocation_count.load(.acquire) != 0) return error.RawAllocationPresent;

    self.root_mutex.lockUncancelable(self.io);
    defer self.root_mutex.unlock(self.io);
    const start_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
    var pending: std.ArrayList(Ref) = .empty;
    defer pending.deinit(self.backingAllocator());
    var visitor: MarkVisitor = .{ .store = self, .pending = &pending };

    self.clearMarks();
    var root = self.roots;
    while (root) |current| : (root = current.next) {
        try visitor.visit(current.ref);
    }
    var provider = self.root_providers;
    while (provider) |current| : (provider = current.next) {
        try current.trace(current.context, &visitor);
    }

    var pending_index: usize = 0;
    while (pending_index < pending.items.len) : (pending_index += 1) {
        const reference = pending.items[pending_index];
        const allocation = try self.findAllocation(reference);
        const header = allocation.header;
        if (self.colorAt(reference.address()) != .grey) continue;
        if (header.meta.meta == 0) {
            try visitor.visit(header.meta);
        } else if (!header.meta.isForeignMetadata()) {
            return error.InvalidRef;
        }
        const descriptor = header.allocation_type orelse return error.InvalidRef;
        try descriptor.trace(
            @ptrFromInt(reference.address()),
            header.extent,
            &visitor,
        );
        self.setColor(reference.address(), .black);
    }

    self.sweep();
    self.gc_cycle_count +%= 1;
    const finish_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
    self.last_gc_ns = if (finish_ns > start_ns) @intCast(finish_ns - start_ns) else 0;
}

fn queueAddressMark(
    self: *Store,
    pending: *std.ArrayList(Ref),
    address: usize,
    byte_count: usize,
) anyerror!void {
    if (byte_count == 0) return;
    const reference = try self.addressReference(address, byte_count);
    try self.queueMark(pending, reference);
}

fn addressReference(self: *Store, address: usize, byte_count: usize) anyerror!Ref {
    const heap_base = @intFromPtr(self.heap.ptr);
    if (address < heap_base) {
        if (byte_count > heap_base - address) return error.InvalidRef;
        return error.ForeignReference;
    }
    const heap_offset = address - heap_base;
    if (heap_offset >= self.heap.len) return error.ForeignReference;
    if (byte_count > self.heap.len - heap_offset) return error.InvalidRef;
    if (self.findFolioSlot(address)) |slot| {
        const mask = @as(u64, 1) << @intCast(slot.index);
        const free_bitmap = if (self.thread_safe and comptime @bitSizeOf(usize) >= 64)
            @atomicLoad(u64, &slot.folio.bitmap, .acquire)
        else
            slot.folio.bitmap;
        const typed_bitmap = if (self.thread_safe and comptime @bitSizeOf(usize) >= 64)
            @atomicLoad(u64, &slot.folio.typed_bitmap, .acquire)
        else
            slot.folio.typed_bitmap;
        if (free_bitmap & mask != 0 or typed_bitmap & mask == 0) return error.InvalidRef;

        const header: *Header = @ptrFromInt(slot.start);
        const descriptor = header.allocation_type orelse return error.InvalidRef;
        if (header.tag == 0) return error.InvalidRef;
        const payload_address = slot.start + header_size;
        const body_size = std.math.mul(usize, header.extent, descriptor.item_size) catch
            return error.InvalidRef;
        const slot_size: usize = size_classes[slot.folio.class];
        if (body_size > slot_size - header_size) return error.InvalidRef;
        if (address < payload_address) return error.InvalidRef;
        const offset = address - payload_address;
        if (offset >= body_size) return error.InvalidRef;
        if (byte_count > body_size - offset) return error.InvalidRef;
        return Ref.fromAddr(@as(*anyopaque, @ptrFromInt(payload_address)), header.tag);
    }

    self.large_mutex.lockUncancelable(self.io);
    defer self.large_mutex.unlock(self.io);
    var large = self.large_head;
    while (large) |current| : (large = current.next) {
        const allocation_begin = @intFromPtr(current.ptr.ptr);
        const allocation_size = current.ptr.len;
        if (address < allocation_begin or address - allocation_begin >= allocation_size) {
            continue;
        }
        if (current.kind != .typed or current.payload_address == 0) return error.InvalidRef;
        const header: *Header = @ptrFromInt(current.payload_address - header_size);
        const descriptor = header.allocation_type orelse return error.InvalidRef;
        if (header.tag == 0) return error.InvalidRef;
        const body_size = std.math.mul(usize, header.extent, descriptor.item_size) catch
            return error.InvalidRef;
        if (current.payload_address < allocation_begin) return error.InvalidRef;
        const payload_offset = current.payload_address - allocation_begin;
        if (payload_offset > allocation_size or body_size > allocation_size - payload_offset) {
            return error.InvalidRef;
        }
        if (address < current.payload_address) return error.InvalidRef;
        const offset = address - current.payload_address;
        if (offset >= body_size) return error.InvalidRef;
        if (byte_count > body_size - offset) return error.InvalidRef;
        return Ref.fromAddr(
            @as(*anyopaque, @ptrFromInt(current.payload_address)),
            header.tag,
        );
    }

    return error.InvalidRef;
}

fn queueMark(self: *Store, pending: *std.ArrayList(Ref), reference: Ref) anyerror!void {
    if (reference.isNull()) return;
    const allocation = try self.findAllocation(reference);
    if (reference.tag != 0 and allocation.header.tag != reference.tag) {
        return error.InvalidRef;
    }
    if (self.colorAt(reference.address()) != .white) return;
    self.setColor(reference.address(), .grey);
    try pending.append(self.backingAllocator(), reference);
}

fn clearMarks(self: *Store) void {
    for (self.folios.items) |folio| {
        const slot_size = size_classes[folio.class];
        var typed = folio.typed_bitmap;
        while (typed != 0) {
            const index: usize = @ctz(typed);
            typed &= typed - 1;
            const address = @intFromPtr(folio) + @sizeOf(Folio) +
                index * slot_size + header_size;
            self.setColor(address, .white);
        }
    }
    var large = self.large_head;
    while (large) |current| : (large = current.next) {
        if (current.kind == .typed) self.setColor(current.payload_address, .white);
    }
}
fn finalizeSweptAllocation(header: *const Header, payload_address: usize) void {
    const descriptor = header.allocation_type orelse unreachable;
    if (descriptor.finalize) |finalize| {
        finalize(@ptrFromInt(payload_address), header.extent);
    }
}

fn finalizeLiveAllocations(self: *Store) void {
    for (self.folios.items) |folio| {
        var typed = folio.typed_bitmap;
        while (typed != 0) {
            const index: usize = @ctz(typed);
            typed &= typed - 1;
            const payload_address = @intFromPtr(folio) + @sizeOf(Folio) +
                index * size_classes[folio.class] + header_size;
            const header: *const Header = @ptrFromInt(payload_address - header_size);
            finalizeSweptAllocation(header, payload_address);
        }
    }

    var large = self.large_head;
    while (large) |current| : (large = current.next) {
        if (current.kind != .typed) continue;
        const header: *const Header = @ptrFromInt(current.payload_address - header_size);
        finalizeSweptAllocation(header, current.payload_address);
    }
}

fn sweep(self: *Store) void {
    for (&self.active_folios) |*active| active.store(0, .release);
    self.folio_free_lists = @splat(null);
    for (self.folios.items) |folio| {
        folio.free_listed = false;
        const class: usize = folio.class;
        const slot_size: usize = size_classes[class];
        var typed = folio.typed_bitmap;
        while (typed != 0) {
            const index: usize = @ctz(typed);
            const mask = @as(u64, 1) << @intCast(index);
            typed &= ~mask;
            const payload_address = @intFromPtr(folio) + @sizeOf(Folio) +
                index * slot_size + header_size;
            if (self.colorAt(payload_address) == .black) {
                self.setColor(payload_address, .white);
                continue;
            }

            const header: *Header = @ptrFromInt(payload_address - header_size);
            finalizeSweptAllocation(header, payload_address);
            header.* = .{};
            folio.typed_bitmap &= ~mask;
            folio.bitmap |= mask;
            _ = self.live_obj_count.fetchSub(1, .acq_rel);
        }
        if (folio.bitmap != 0) {
            folio.next = self.folio_free_lists[class];
            self.folio_free_lists[class] = folio;
            folio.free_listed = true;
        } else {
            folio.next = null;
        }
    }

    var large = self.large_head;
    while (large) |current| : (large = current.next) {
        if (current.kind != .typed) continue;
        if (self.colorAt(current.payload_address) == .black) {
            self.setColor(current.payload_address, .white);
            continue;
        }
        const header: *Header = @ptrFromInt(current.payload_address - header_size);
        finalizeSweptAllocation(header, current.payload_address);
        header.* = .{};
        current.payload_address = 0;
        current.kind = .free;
        _ = self.live_obj_count.fetchSub(1, .acq_rel);
    }
}

pub fn stats(self: *Store) Stats {
    return .{
        .heap_reserved = if (self.using_mmap) self.heap.len else 0,
        .heap_committed = self.heap_committed.load(.acquire),
        .heap_used = if (self.thread_safe)
            @atomicLoad(usize, &self.heap_brk, .acquire)
        else
            self.heap_brk,
        .folio_count = self.folio_count,
        .live_objects = self.live_obj_count.load(.acquire),
        .gc_cycles = self.gc_cycle_count,
        .last_gc_ns = self.last_gc_ns,
        .raw_allocations = @intCast(self.raw_allocation_count.load(.acquire)),
        .symbol_count = @intCast(self.sym_lookup.count()),
    };
}

fn findFolioSlotUnlocked(self: *Store, address: usize) ?FolioSlot {
    var lower: usize = 0;
    var upper = self.folios.items.len;
    while (lower < upper) {
        const middle = lower + (upper - lower) / 2;
        const folio = self.folios.items[middle];
        const slot_begin = @intFromPtr(folio) + @sizeOf(Folio);
        const class: usize = folio.class;
        const slot_size: usize = size_classes[class];
        const slot_end = slot_begin + slot_size * slots_per_folio;
        if (address < slot_begin) {
            upper = middle;
        } else if (address >= slot_end) {
            lower = middle + 1;
        } else {
            const offset = address - slot_begin;
            const index = offset / slot_size;
            return .{
                .folio = folio,
                .index = index,
                .start = slot_begin + index * slot_size,
                .offset = offset % slot_size,
            };
        }
    }
    return null;
}

fn findFolioSlot(self: *Store, address: usize) ?FolioSlot {
    self.folio_mutex.lockUncancelable(self.io);
    defer self.folio_mutex.unlock(self.io);
    return self.findFolioSlotUnlocked(address);
}

fn findAllocation(self: *Store, reference: Ref) anyerror!Allocation {
    if (reference.isNull()) return error.InvalidRef;
    if (reference.meta != 0) return error.InvalidRef;
    const address = reference.address();
    if (self.findFolioSlot(address)) |slot| {
        if (slot.offset != header_size) return error.InvalidRef;
        const mask = @as(u64, 1) << @intCast(slot.index);
        const free_bitmap = if (self.thread_safe and comptime @bitSizeOf(usize) >= 64)
            @atomicLoad(u64, &slot.folio.bitmap, .acquire)
        else
            slot.folio.bitmap;
        const typed_bitmap = if (self.thread_safe and comptime @bitSizeOf(usize) >= 64)
            @atomicLoad(u64, &slot.folio.typed_bitmap, .acquire)
        else
            slot.folio.typed_bitmap;
        if (free_bitmap & mask != 0) return error.InvalidRef;
        if (typed_bitmap & mask == 0) return error.InvalidRef;
        const header: *Header = @ptrFromInt(slot.start);
        if (header.allocation_type == null) return error.InvalidRef;
        if (reference.tag != 0 and header.tag != reference.tag) return error.InvalidRef;
        return .{ .header = header, .location = .{ .folio = slot } };
    }

    self.large_mutex.lockUncancelable(self.io);
    defer self.large_mutex.unlock(self.io);
    var large = self.large_head;
    while (large) |current| : (large = current.next) {
        if (current.kind != .typed or current.payload_address != address) continue;
        const header: *Header = @ptrFromInt(address - header_size);
        if (header.allocation_type == null) return error.InvalidRef;
        if (reference.tag != 0 and header.tag != reference.tag) return error.InvalidRef;
        return .{ .header = header, .location = .{ .large = current } };
    }
    const heap_base = @intFromPtr(self.heap.ptr);
    if (address < heap_base or address - heap_base >= self.heap.len) {
        return error.ForeignReference;
    }
    return error.InvalidRef;
}

fn recordTypedAllocation(self: *Store, allocated: AllocatedBytes, payload_address: usize) void {
    const address = @intFromPtr(allocated.ptr);
    if (allocated.folio) |folio| {
        const first = @intFromPtr(folio) + @sizeOf(Folio);
        const slot_size: usize = size_classes[folio.class];
        std.debug.assert(address >= first);
        const offset = address - first;
        std.debug.assert(offset % slot_size == 0);
        const index = offset / slot_size;
        std.debug.assert(index < slots_per_folio);
        const mask = @as(u64, 1) << @intCast(index);
        if (self.thread_safe and comptime @bitSizeOf(usize) >= 64) {
            _ = @atomicRmw(u64, &folio.typed_bitmap, .Or, mask, .release);
        } else {
            folio.typed_bitmap |= mask;
        }
        return;
    }
    self.large_mutex.lockUncancelable(self.io);
    defer self.large_mutex.unlock(self.io);
    var large = self.large_head;
    while (large) |current| : (large = current.next) {
        if (@intFromPtr(current.ptr.ptr) == address and current.kind == .reserved) {
            current.kind = .typed;
            current.payload_address = payload_address;
            return;
        }
    }
    unreachable;
}

fn noteRawAllocation(self: *Store, raw: *anyopaque) void {
    const address = @intFromPtr(raw);
    var found = self.findFolioSlot(address) != null;
    if (!found) {
        self.large_mutex.lockUncancelable(self.io);
        defer self.large_mutex.unlock(self.io);
        var large = self.large_head;
        while (large) |current| : (large = current.next) {
            if (@intFromPtr(current.ptr.ptr) == address and current.kind == .reserved) {
                current.kind = .raw;
                found = true;
                break;
            }
        }
    }
    std.debug.assert(found);
    _ = self.raw_allocation_count.fetchAdd(1, .acq_rel);
}

fn freeRawAllocation(self: *Store, raw: [*]u8) void {
    const address = @intFromPtr(raw);
    if (self.findFolioSlot(address)) |slot| {
        std.debug.assert(slot.offset == 0);
        const mask = @as(u64, 1) << @intCast(slot.index);
        const typed_bitmap = if (self.thread_safe and comptime @bitSizeOf(usize) >= 64)
            @atomicLoad(u64, &slot.folio.typed_bitmap, .acquire)
        else
            slot.folio.typed_bitmap;
        std.debug.assert(typed_bitmap & mask == 0);
        const previous = if (self.thread_safe and comptime @bitSizeOf(usize) >= 64)
            @atomicRmw(u64, &slot.folio.bitmap, .Or, mask, .acq_rel)
        else blk: {
            const old = slot.folio.bitmap;
            slot.folio.bitmap |= mask;
            break :blk old;
        };
        std.debug.assert(previous & mask == 0);
        self.folio_mutex.lockUncancelable(self.io);
        defer self.folio_mutex.unlock(self.io);
        const class: usize = slot.folio.class;
        const active = self.active_folios[class].load(.acquire);
        if (active != @intFromPtr(slot.folio) and !slot.folio.free_listed) {
            slot.folio.next = self.folio_free_lists[class];
            self.folio_free_lists[class] = slot.folio;
            slot.folio.free_listed = true;
        }
    } else {
        self.large_mutex.lockUncancelable(self.io);
        defer self.large_mutex.unlock(self.io);
        var found = false;
        var large = self.large_head;
        while (large) |current| : (large = current.next) {
            if (@intFromPtr(current.ptr.ptr) == address and current.kind == .raw) {
                current.kind = .free;
                current.payload_address = 0;
                found = true;
                break;
            }
        }
        std.debug.assert(found);
    }
    const previous_count = self.raw_allocation_count.fetchSub(1, .acq_rel);
    std.debug.assert(previous_count != 0);
}

fn colorAt(self: *Store, address: usize) Color {
    const relative = address - @intFromPtr(self.heap.ptr);
    const unit = relative / 8;
    const byte_index = unit / 4;
    const shift: u3 = @intCast((unit % 4) * 2);
    return @fromBackingInt(@intCast((self.color_bitmap[byte_index] >> shift) & 3));
}

fn setColor(self: *Store, address: usize, color: Color) void {
    const relative = address - @intFromPtr(self.heap.ptr);
    const unit = relative / 8;
    const byte_index = unit / 4;
    const shift: u3 = @intCast((unit % 4) * 2);
    const mask: u8 = @as(u8, 3) << shift;
    self.color_bitmap[byte_index] =
        (self.color_bitmap[byte_index] & ~mask) | (@as(u8, @backingInt(color)) << shift);
}

fn allocBytes(self: *Store, size: usize, alignment: u29) !AllocatedBytes {
    const z_alloc = tracy.Zone.begin(.{ .name = "store-alloc", .src = @src() });
    defer z_alloc.end();
    const class = classForSize(size);
    if (class >= max_size_classes or alignment > 8) {
        return .{ .ptr = try self.allocLarge(size, alignment), .folio = null };
    }

    const active_address = self.active_folios[class].load(.acquire);
    if (active_address != 0) {
        const active: *Folio = @ptrFromInt(active_address);
        if (self.allocFromFolio(active, class)) |allocation| {
            return .{ .ptr = allocation, .folio = active };
        }
    }

    self.folio_mutex.lockUncancelable(self.io);
    defer self.folio_mutex.unlock(self.io);
    const rechecked_address = self.active_folios[class].load(.acquire);
    if (rechecked_address != 0) {
        const active: *Folio = @ptrFromInt(rechecked_address);
        if (self.allocFromFolio(active, class)) |allocation| {
            return .{ .ptr = allocation, .folio = active };
        }
    }
    while (self.folio_free_lists[class]) |folio| {
        self.folio_free_lists[class] = folio.next;
        folio.next = null;
        folio.free_listed = false;
        if (self.allocFromFolio(folio, class)) |allocation| {
            self.active_folios[class].store(@intFromPtr(folio), .release);
            return .{ .ptr = allocation, .folio = folio };
        }
    }

    const folio = try self.acquireFolio(class);
    const allocation = self.allocFromFolio(folio, class);
    std.debug.assert(allocation != null);
    self.active_folios[class].store(@intFromPtr(folio), .release);
    return .{ .ptr = allocation.?, .folio = folio };
}

fn allocFromFolio(self: *Store, folio: *Folio, class: usize) ?*anyopaque {
    while (true) {
        const bm = if (self.thread_safe and comptime @bitSizeOf(usize) >= 64)
            @atomicLoad(u64, &folio.bitmap, .acquire)
        else
            folio.bitmap;
        if (bm == 0) return null;
        const fb = @ctz(bm);
        const new_bm = bm & ~(@as(u64, 1) << @intCast(fb));
        if (self.thread_safe and comptime @bitSizeOf(usize) >= 64) {
            // CAS, not load-then-store: two threads racing for the same
            // first-free bit must not both take the slot (TOCTOU).
            if (@cmpxchgWeak(u64, &folio.bitmap, bm, new_bm, .acq_rel, .acquire)) |_| continue;
        } else {
            folio.bitmap = new_bm;
        }
        return @ptrFromInt(@intFromPtr(folio) + @sizeOf(Folio) + @as(usize, fb) * size_classes[class]);
    }
}

fn reserveHeap(self: *Store, bytes: usize) error{OutOfMemory}!usize {
    if (self.thread_safe) {
        while (true) {
            const old = @atomicLoad(usize, &self.heap_brk, .acquire);
            if (old > self.heap.len or bytes > self.heap.len - old) return error.OutOfMemory;
            if (@cmpxchgWeak(usize, &self.heap_brk, old, old + bytes, .acq_rel, .acquire) == null) {
                return old;
            }
        }
    }
    const old = self.heap_brk;
    if (old > self.heap.len or bytes > self.heap.len - old) return error.OutOfMemory;
    self.heap_brk = old + bytes;
    return old;
}

fn acquireFolio(self: *Store, class: usize) !*Folio {
    if (self.folio_count == std.math.maxInt(u32)) return error.OutOfMemory;
    try self.folios.ensureUnusedCapacity(self.backingAllocator(), 1);
    const slot_bytes = std.math.mul(
        usize,
        @as(usize, size_classes[class]),
        slots_per_folio,
    ) catch return error.OutOfMemory;
    const total = std.math.add(usize, @sizeOf(Folio), slot_bytes) catch return error.OutOfMemory;
    const rounded = std.math.add(usize, total, 4095) catch return error.OutOfMemory;
    const bytes = rounded & ~@as(usize, 4095);
    const committed = bytes;
    const brk = try self.reserveHeap(bytes);
    const folio: *Folio = @ptrCast(@alignCast(&self.heap[brk]));
    folio.* = .{ .class = @intCast(class) };
    self.folios.appendAssumeCapacity(folio);
    self.folio_count += 1;
    _ = self.heap_committed.fetchAdd(committed, .acq_rel);
    return folio;
}

fn allocLarge(self: *Store, size: usize, alignment: u29) !*anyopaque {
    self.large_mutex.lockUncancelable(self.io);
    defer self.large_mutex.unlock(self.io);
    var current = self.large_head;
    while (current) |large| : (current = large.next) {
        if (large.kind != .free or large.capacity < size) continue;
        if (@intFromPtr(large.ptr.ptr) % alignment != 0) continue;
        const data: [*]u8 = @ptrCast(large.ptr.ptr);
        large.ptr = data[0..size];
        large.alignment = alignment;
        large.kind = .reserved;
        return @ptrCast(large.ptr.ptr);
    }

    const total = std.math.add(usize, @sizeOf(LargeObj), size) catch return error.OutOfMemory;
    const with_alignment = std.math.add(usize, total, alignment - 1) catch {
        return error.OutOfMemory;
    };
    const rounded = std.math.add(usize, with_alignment, 4095) catch return error.OutOfMemory;
    const bytes = rounded & ~@as(usize, 4095);
    const committed = bytes;
    const brk = try self.reserveHeap(bytes);
    const large: *LargeObj = @ptrCast(@alignCast(&self.heap[brk]));
    const data_start = std.mem.alignForward(
        usize,
        brk + @sizeOf(LargeObj),
        alignment,
    );
    const end = brk + bytes;
    const capacity = end - data_start;
    std.debug.assert(size <= capacity);
    large.* = .{
        .next = self.large_head,
        .ptr = self.heap[data_start .. data_start + size],
        .capacity = capacity,
        .alignment = alignment,
        .kind = .reserved,
    };
    self.large_head = large;
    _ = self.heap_committed.fetchAdd(committed, .acq_rel);
    return @ptrCast(&self.heap[data_start]);
}

fn noopBarrier(_: *Store, _: *u64, _: u64, _: u64) void {}
fn traceTestRoot(context: *anyopaque, visitor: *MarkVisitor) anyerror!void {
    const reference: *const Ref = @ptrCast(@alignCast(context));
    try visitor.visit(reference.*);
}
const ExplicitTraceNode = struct {
    child: Ref,
    foreign: *u8,
};

fn traceExplicitTraceNode(
    data: *const anyopaque,
    extent: usize,
    visitor: *MarkVisitor,
) anyerror!void {
    const nodes: [*]const ExplicitTraceNode = @ptrCast(@alignCast(data));
    for (0..extent) |index| try visitor.visit(nodes[index].child);
}

const ValueRootContext = struct {
    value: skript.Value,
};

const AddressRootContext = struct {
    address: usize,
};

fn traceTestValueRoot(context: *anyopaque, visitor: *MarkVisitor) anyerror!void {
    const root: *const ValueRootContext = @ptrCast(@alignCast(context));
    try visitor.visitValue(root.value);
}

fn traceTestAddressRoot(context: *anyopaque, visitor: *MarkVisitor) anyerror!void {
    const root: *const AddressRootContext = @ptrCast(@alignCast(context));
    try visitor.visitAddress(root.address);
}
const GuardTraceNode = struct {
    next: ?*const GuardTraceNode = null,
};

const GuardTraceRoot = struct {
    node: *const GuardTraceNode,
};

fn traceTestGuardNode(context: *const anyopaque, visitor: *MarkVisitor) anyerror!void {
    const node: *const GuardTraceNode = @ptrCast(@alignCast(context));
    if (node.next) |next| try visitor.visitGuard(&traceTestGuardNode, next);
}

fn traceTestGuardRoot(context: *anyopaque, visitor: *MarkVisitor) anyerror!void {
    const root: *const GuardTraceRoot = @ptrCast(@alignCast(context));
    try visitor.visitGuard(&traceTestGuardNode, root.node);
}

const FinalizerProbe = struct {
    calls: *std.atomic.Value(u32),
};

fn traceFinalizerProbe(
    _: *const anyopaque,
    _: usize,
    _: *MarkVisitor,
) anyerror!void {}

fn finalizeProbe(data: *anyopaque, _: usize) void {
    const probe: *FinalizerProbe = @ptrCast(@alignCast(data));
    _ = probe.calls.fetchAdd(1, .monotonic);
}
const LargeFinalizerProbe = struct {
    calls: *std.atomic.Value(u32),
    payload: [20_000]u8,
};

fn finalizeLargeProbe(data: *anyopaque, _: usize) void {
    const probe: *LargeFinalizerProbe = @ptrCast(@alignCast(data));
    _ = probe.calls.fetchAdd(1, .monotonic);
}

fn checkTestClosureGuard(_: *skript.Runtime, _: *const anyopaque) skript.Error!void {}

test "collect follows type, closure capture, and constant Value edges" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();

    const captured_cell = try gc_store.create([2]skript.Value);
    captured_cell.deref([2]skript.Value).* = .{ .i64(1), .nil };
    const constant_cell = try gc_store.create([2]skript.Value);
    constant_cell.deref([2]skript.Value).* = .{ .i64(2), .nil };

    const captures = try gc_store.allocSlice(skript.Value, 1);
    captures.slice[0] = .cons(captured_cell.toObject());
    const constants = try gc_store.allocSlice(skript.Value, 1);
    constants.slice[0] = .cons(constant_cell.toObject());

    const closure_ref = try gc_store.create(skript.data.Closure);
    closure_ref.deref(skript.data.Closure).* = .{
        .parent_ns = .nil,
        .arglist = &.{},
        .captures = captures.slice,
        .constants = constants.slice,
    };

    const type_ref = try gc_store.create(skript.data.Type);
    type_ref.deref(skript.data.Type).* = .{
        .meta = skript.builtins.type_type,
        .name = .null,
        .apply = .closure(closure_ref.toObject()),
    };

    var root_value: ValueRootContext = .{
        .value = .typeValue(type_ref.toObject()),
    };
    var provider: RootProvider = .{
        .context = &root_value,
        .trace = traceTestValueRoot,
    };
    try gc_store.registerRootProvider(&provider);
    defer gc_store.unregisterRootProvider(&provider) catch unreachable;

    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 6), gc_store.stats().live_objects);
    try std.testing.expectEqual(
        @as(i64, 1),
        (try gc_store.derefChecked([2]skript.Value, captured_cell))[0].obj.toInt(i64),
    );
    try std.testing.expectEqual(
        @as(i64, 2),
        (try gc_store.derefChecked([2]skript.Value, constant_cell))[0].obj.toInt(i64),
    );

    root_value.value = .nil;
    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 0), gc_store.stats().live_objects);
}

test "rich error snapshots keep raised payloads and call-frame sources alive" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();

    const origin = try gc_store.create([2]skript.Value);
    origin.deref([2]skript.Value).* = .{ .i64(11), .nil };
    const caller = try gc_store.create([2]skript.Value);
    caller.deref([2]skript.Value).* = .{ .i64(22), .nil };
    const payload = try gc_store.create([2]skript.Value);
    payload.deref([2]skript.Value).* = .{ .i64(33), .nil };
    const frames = try gc_store.allocSlice(skript.data.ErrorFrame, 1);
    frames.slice[0] = .{ .site = .{ .source = .cons(caller.toObject()), .idx = 3 } };
    var root_value: ValueRootContext = .{ .value = skript.Value.errWithDetails(
        gc_store,
        error.TypeMismatch,
        .{ .source = .cons(origin.toObject()), .idx = 2 },
        .cons(payload.toObject()),
        frames.slice,
    ) };
    var provider: RootProvider = .{ .context = &root_value, .trace = traceTestValueRoot };
    try gc_store.registerRootProvider(&provider);
    defer gc_store.unregisterRootProvider(&provider) catch unreachable;

    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 5), gc_store.stats().live_objects);
    const site = root_value.value.errorSite();
    try std.testing.expectEqual(@as(u32, 2), site.idx);
    const frame_source = root_value.value.errorFrames()[0].site.source;
    const raised_source = root_value.value.errorRaised();
    const origin_cells = try gc_store.derefChecked([2]skript.Value, site.source.obj.toRef());
    const frame_cells = try gc_store.derefChecked([2]skript.Value, frame_source.obj.toRef());
    const raised_cells = try gc_store.derefChecked([2]skript.Value, raised_source.obj.toRef());
    try std.testing.expectEqual(@as(i64, 11), origin_cells[0].obj.toInt(i64));
    try std.testing.expectEqual(@as(i64, 22), frame_cells[0].obj.toInt(i64));
    try std.testing.expectEqual(@as(i64, 33), raised_cells[0].obj.toInt(i64));

    root_value.value = .nil;
    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 0), gc_store.stats().live_objects);
}

test "collect fails closed for a guarded closure without a trace callback" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();

    var guard_context: u8 = 1;
    const guard: skript.data.ClosureGuard = .{
        .context = &guard_context,
        .check = checkTestClosureGuard,
    };
    const closure = try gc_store.create(skript.data.Closure);
    closure.deref(skript.data.Closure).* = .{
        .parent_ns = .nil,
        .arglist = &.{},
        .guard = &guard,
    };
    const unrelated = try gc_store.create(u64);
    unrelated.deref(u64).* = 37;
    var root_value: ValueRootContext = .{ .value = .closure(closure.toObject()) };
    var provider: RootProvider = .{
        .context = &root_value,
        .trace = traceTestValueRoot,
    };
    try gc_store.registerRootProvider(&provider);
    defer gc_store.unregisterRootProvider(&provider) catch unreachable;

    try std.testing.expectError(
        error.UntracedAllocation,
        gc_store.collect(gc_store.assumeStopped()),
    );
    try std.testing.expectEqual(@as(u32, 2), gc_store.stats().live_objects);
    try std.testing.expectEqual(@as(u64, 37), (try gc_store.derefChecked(u64, unrelated)).*);
}

test "visitGuard rejects cyclic and over-deep guard chains without sweeping" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();

    const unrelated = try gc_store.create(u64);
    unrelated.deref(u64).* = 43;
    var deep_chain: [MarkVisitor.max_guard_depth + 1]GuardTraceNode = undefined;
    for (&deep_chain, 0..) |*node, index| {
        node.next = if (index + 1 < deep_chain.len) &deep_chain[index + 1] else null;
    }
    var root_context: GuardTraceRoot = .{ .node = &deep_chain[0] };
    var provider: RootProvider = .{
        .context = &root_context,
        .trace = traceTestGuardRoot,
    };
    try gc_store.registerRootProvider(&provider);
    defer gc_store.unregisterRootProvider(&provider) catch unreachable;

    try std.testing.expectError(
        error.UntracedAllocation,
        gc_store.collect(gc_store.assumeStopped()),
    );
    try std.testing.expectEqual(@as(u32, 1), gc_store.stats().live_objects);

    var cycle = [_]GuardTraceNode{ .{}, .{} };
    cycle[0].next = &cycle[1];
    cycle[1].next = &cycle[0];
    root_context.node = &cycle[0];
    try std.testing.expectError(
        error.UntracedAllocation,
        gc_store.collect(gc_store.assumeStopped()),
    );
    try std.testing.expectEqual(@as(u64, 43), (try gc_store.derefChecked(u64, unrelated)).*);
}

test "collect traces Store-backed SmallNamespace and HashMapNamespace values" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();

    const small_child = try gc_store.create([2]skript.Value);
    small_child.deref([2]skript.Value).* = .{ .i64(11), .nil };
    const map_child = try gc_store.create([2]skript.Value);
    map_child.deref([2]skript.Value).* = .{ .i64(22), .nil };

    var small_state = try std.testing.allocator.create(skript.SmallNamespace);
    defer std.testing.allocator.destroy(small_state);
    small_state.* = .{};
    small_state.bindings[0] = @intFromPtr(try gc_store.getsym("small-root"));
    small_state.values[0] = .cons(small_child.toObject());

    var map_state = try skript.HashMapNamespace.init(std.testing.allocator, .nil);
    defer map_state.deinit(std.testing.allocator);
    try map_state.bind(try gc_store.getsym("map-root"), .cons(map_child.toObject()));

    const small_ref = try gc_store.create(skript.Namespace);
    small_ref.deref(skript.Namespace).* = skript.SmallNamespace.vtable;
    small_ref.deref(skript.Namespace).data = @ptrCast(small_state);

    const map_ref = try gc_store.create(skript.Namespace);
    map_ref.deref(skript.Namespace).* = skript.HashMapNamespace.vtable;
    map_ref.deref(skript.Namespace).data = @ptrCast(&map_state);

    var small_root: ValueRootContext = .{ .value = .namespace(small_ref.toObject()) };
    var small_provider: RootProvider = .{
        .context = &small_root,
        .trace = traceTestValueRoot,
    };
    try gc_store.registerRootProvider(&small_provider);
    defer gc_store.unregisterRootProvider(&small_provider) catch unreachable;

    var map_root: ValueRootContext = .{ .value = .namespace(map_ref.toObject()) };
    var map_provider: RootProvider = .{
        .context = &map_root,
        .trace = traceTestValueRoot,
    };
    try gc_store.registerRootProvider(&map_provider);
    defer gc_store.unregisterRootProvider(&map_provider) catch unreachable;

    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 4), gc_store.stats().live_objects);
    try std.testing.expectEqual(
        @as(i64, 11),
        (try gc_store.derefChecked([2]skript.Value, small_child))[0].obj.toInt(i64),
    );
    try std.testing.expectEqual(
        @as(i64, 22),
        (try gc_store.derefChecked([2]skript.Value, map_child))[0].obj.toInt(i64),
    );

    small_root.value = .nil;
    map_root.value = .nil;
    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 0), gc_store.stats().live_objects);
}

test "visitAddress traces interior pointers in small and large typed allocations" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();

    const small = try gc_store.allocSlice(u64, 8);
    const large = try gc_store.allocSlice(u8, 20_000);
    small.slice[0] = 41;
    large.slice[10_000] = 13;
    var small_root: AddressRootContext = .{ .address = small.ref.address() + @sizeOf(u64) };
    var small_provider: RootProvider = .{
        .context = &small_root,
        .trace = traceTestAddressRoot,
    };
    try gc_store.registerRootProvider(&small_provider);
    defer gc_store.unregisterRootProvider(&small_provider) catch unreachable;

    var large_root: AddressRootContext = .{ .address = large.ref.address() + 10_000 };
    var large_provider: RootProvider = .{
        .context = &large_root,
        .trace = traceTestAddressRoot,
    };
    try gc_store.registerRootProvider(&large_provider);
    defer gc_store.unregisterRootProvider(&large_provider) catch unreachable;

    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 2), gc_store.stats().live_objects);
    try std.testing.expectEqual(@as(u64, 41), (try gc_store.derefChecked(u64, small.ref)).*);
    try std.testing.expectEqual(@as(u8, 13), large.slice[10_000]);
}

test "visitAddress rejects headers, slice bounds, and foreign addresses before sweep" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();

    const reachable = try gc_store.create(u64);
    reachable.deref(u64).* = 31;
    const discarded = try gc_store.allocSlice(u8, 1);
    discarded.slice[0] = 7;

    var valid_root = Root.init(reachable);
    try gc_store.registerRoot(&valid_root);
    defer gc_store.unregisterRoot(&valid_root) catch unreachable;

    var bad_root: AddressRootContext = .{
        .address = discarded.ref.address() - 1,
    };
    var provider: RootProvider = .{
        .context = &bad_root,
        .trace = traceTestAddressRoot,
    };
    try gc_store.registerRootProvider(&provider);
    defer if (provider.store != null) gc_store.unregisterRootProvider(&provider) catch unreachable;

    try std.testing.expectError(
        error.InvalidRef,
        gc_store.collect(gc_store.assumeStopped()),
    );
    try std.testing.expectEqual(@as(u32, 2), gc_store.stats().live_objects);
    try std.testing.expectEqual(
        @as(u8, 7),
        (try gc_store.derefChecked(u8, discarded.ref)).*,
    );

    bad_root.address = discarded.ref.address() + discarded.slice.len;
    try std.testing.expectError(
        error.InvalidRef,
        gc_store.collect(gc_store.assumeStopped()),
    );
    try std.testing.expectEqual(@as(u32, 2), gc_store.stats().live_objects);

    var external: u8 = 9;
    bad_root.address = @intFromPtr(&external);
    try std.testing.expectError(
        error.ForeignReference,
        gc_store.collect(gc_store.assumeStopped()),
    );
    try std.testing.expectEqual(@as(u32, 2), gc_store.stats().live_objects);
    try std.testing.expectEqual(@as(u64, 31), (try gc_store.derefChecked(u64, reachable)).*);

    try gc_store.unregisterRootProvider(&provider);
    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 1), gc_store.stats().live_objects);
}

test "managed finalizers run once for swept small and large allocations" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();

    var finalizer_calls: std.atomic.Value(u32) = .init(0);
    const managed_ref = try gc_store.createManaged(
        FinalizerProbe,
        traceFinalizerProbe,
        finalizeProbe,
    );
    managed_ref.deref(FinalizerProbe).* = .{ .calls = &finalizer_calls };
    const large_ref = try gc_store.createManaged(
        LargeFinalizerProbe,
        traceFinalizerProbe,
        finalizeLargeProbe,
    );
    large_ref.deref(LargeFinalizerProbe).* = .{
        .calls = &finalizer_calls,
        .payload = undefined,
    };

    var root = Root.init(managed_ref);
    try gc_store.registerRoot(&root);
    defer gc_store.unregisterRoot(&root) catch unreachable;
    var large_root = Root.init(large_ref);
    try gc_store.registerRoot(&large_root);
    defer gc_store.unregisterRoot(&large_root) catch unreachable;

    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 0), finalizer_calls.load(.monotonic));

    root.ref = .nil;
    large_root.ref = .nil;
    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 2), finalizer_calls.load(.monotonic));

    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 2), finalizer_calls.load(.monotonic));
}

test "Store.deinit finalizes live managed allocations of every size class" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    var deinitialized = false;
    defer {
        if (!deinitialized) gc_store.deinit();
    }

    var finalizer_calls: std.atomic.Value(u32) = .init(0);
    const small = try gc_store.createManaged(
        FinalizerProbe,
        traceFinalizerProbe,
        finalizeProbe,
    );
    small.deref(FinalizerProbe).* = .{ .calls = &finalizer_calls };
    const large = try gc_store.createManaged(
        LargeFinalizerProbe,
        traceFinalizerProbe,
        finalizeLargeProbe,
    );
    large.deref(LargeFinalizerProbe).* = .{
        .calls = &finalizer_calls,
        .payload = undefined,
    };

    gc_store.deinit();
    deinitialized = true;
    try std.testing.expectEqual(@as(u32, 2), finalizer_calls.load(.monotonic));
}

test "collect rejects a stale Value Ref without sweeping live allocations" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();

    const retained = try gc_store.create(u64);
    retained.deref(u64).* = 13;
    const stale = try gc_store.create([2]skript.Value);
    try gc_store.discardUnpublished(stale);

    var retained_root = Root.init(retained);
    try gc_store.registerRoot(&retained_root);
    defer gc_store.unregisterRoot(&retained_root) catch unreachable;

    var stale_root: ValueRootContext = .{ .value = .cons(stale.toObject()) };
    var provider: RootProvider = .{
        .context = &stale_root,
        .trace = traceTestValueRoot,
    };
    try gc_store.registerRootProvider(&provider);
    defer gc_store.unregisterRootProvider(&provider) catch unreachable;

    try std.testing.expectError(
        error.InvalidRef,
        gc_store.collect(gc_store.assumeStopped()),
    );
    try std.testing.expectEqual(@as(u32, 1), gc_store.stats().live_objects);
    try std.testing.expectEqual(@as(u64, 13), (try gc_store.derefChecked(u64, retained)).*);
}
test "force analysis" {
    comptime {
        std.testing.refAllDecls(@This());
        std.testing.refAllDecls(Store);
        std.testing.refAllDecls(Object);
        std.testing.refAllDecls(ErrorObject);
        std.testing.refAllDecls(Ref);
    }
}
test "getsym allocates symbols after init" {
    const s = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer s.deinit();

    const alpha = try s.getsym("alpha");
    const beta = try s.getsym("beta");
    try std.testing.expect(alpha != beta);
    try std.testing.expectEqualStrings("alpha", alpha.*);
    try std.testing.expectEqualStrings("beta", beta.*);
}

test "getsym interns transient sources stably" {
    var s = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer s.deinit();

    // Regression: getsym used to key the intern map by the CALLER's slice.
    // A transient source (a REPL frame-arena query string, reused every
    // frame) left a dangling key whose content hash silently diverged once
    // the memory was reused — the same name then interned to TWO different
    // Syms, and pointer-keyed namespaces lost bindings: "(def a 1)" bound
    // one 'a' but "(+ a 1)" looked up another -> Unbound. The map must be
    // keyed by owned duplicates, so two DIFFERENT slices with the same
    // content always intern to the SAME Sym.
    var buf_a: [16]u8 = undefined;
    var buf_b: [16]u8 = undefined;
    const s1 = std.fmt.bufPrint(&buf_a, "{s}", .{"alpha"}) catch unreachable;
    const s2 = std.fmt.bufPrint(&buf_b, "{s}", .{"alpha"}) catch unreachable;
    const sym1 = try s.getsym(s1);
    // Simulate frame-arena reuse: clobber the first buffer's memory.
    @memset(buf_a[0..], 'x');
    const sym2 = try s.getsym(s2);
    try std.testing.expect(sym1 == sym2);
    // The content stays intact through the owned duplicate.
    try std.testing.expectEqualStrings("alpha", sym1.*);
}

test "init/deinit" {
    const s = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer s.deinit();
}
test "create i32" {
    const s = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer s.deinit();
    const ref = try s.create(i32);
    ref.deref(i32).* = 42;
    try std.testing.expectEqual(@as(i32, 42), ref.deref(i32).*);
}
test "allocSlice" {
    const s = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer s.deinit();
    const result = try s.allocSlice(u8, 5);
    @memcpy(result.slice, "hello");
    try std.testing.expectEqualSlices(u8, "hello", result.slice);
}
test "folio acquisition beyond size-class 6 does not overflow" {
    // Regression: `size_classes[class] * slots_per_folio` was computed in
    // u16, overflowing for class >= 7 (1024 * 64 = 65536 > 65535). Any
    // >= 800-byte allocation (e.g. (iota 100)) panicked in acquireFolio.
    // Exercise a large folio size class and the direct allocation path.
    const s = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer s.deinit();
    const buf = try s.allocator().alloc(u64, 800);
    @memset(buf, @bitCast(@as(i64, 7)));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, 7))), buf[799]);
    const buf2 = try s.allocator().alloc(u64, 20000); // > 16384 -> allocLarge
    @memset(buf2, @bitCast(@as(i64, 9)));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, 9))), buf2[19999]);
}

test "failed heap growth preserves room for later small allocations" {
    const s = try Store.init(std.testing.allocator, std.testing.io, .{ .max_heap_size = 8192 });
    defer s.deinit();
    try std.testing.expectError(error.OutOfMemory, s.create([32768]u8));
    try std.testing.expectError(error.OutOfMemory, s.create([32768]u8));
    try std.testing.expectEqual(@as(u64, 0), s.stats().heap_used);
    _ = try s.create(u64);
    try std.testing.expect(s.stats().heap_used <= 8192);
}

test "Store allocation tags never use the untracked zero tag" {
    const s = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer s.deinit();
    s.alloc_tag = std.math.maxInt(u16);
    const ref = try s.create(u64);
    try std.testing.expectEqual(@as(u16, 1), ref.tag);
}
test "folio slots preserve distinct large allocations" {
    const s = try Store.init(std.testing.allocator, std.testing.io, .{
        .max_heap_size = 4 * 1024 * 1024,
    });
    defer s.deinit();
    var buffers: [slots_per_folio + 1][]u8 = undefined;
    for (&buffers, 0..) |*buffer, index| {
        buffer.* = try s.allocator().alloc(u8, size_classes[max_size_classes - 1]);
        @memset(buffer.*, @intCast(index));
    }
    for (buffers, 0..) |buffer, index| {
        try std.testing.expect(std.mem.allEqual(u8, buffer, @intCast(index)));
    }
}
test "distinct addresses" {
    const s = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer s.deinit();
    const a = try s.create(u64);
    const b = try s.create(u64);
    a.deref(u64).* = 10;
    b.deref(u64).* = 20;
    try std.testing.expect(a.address() != b.address());
}
test "getsym" {
    const s = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer s.deinit();
    try std.testing.expectEqualStrings("h", (try s.getsym("h")).*);
}
test "Ref round-trip" {
    const s = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer s.deinit();
    const ref = try s.create(i32);
    ref.deref(i32).* = 42;
    try std.testing.expectEqual(ref.address(), @intFromPtr(ref.deref(i32)));
}
test "store/load" {
    const s = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer s.deinit();
    const ref = try s.create(u64);
    const ptr = ref.deref(u64);
    s.store(u64, ptr, 42);
    try std.testing.expectEqual(@as(u64, 42), s.load(u64, ptr));
}
test "Object" {
    try std.testing.expectEqual(@as(f64, 3.14), Object.fromf64(3.14).tof64());
    try std.testing.expect(Object.fromBool(true).toBool());
}
test "Ref unsafeTaggedRef" {
    var d align(8) = @as(i32, 42);
    const r = Ref.unsafeTaggedRef(&d);
    try std.testing.expect(!r.isNull());
    try std.testing.expectEqual(@as(usize, @intFromPtr(&d)), r.address());
}
test "SourceUnit ids are monotonic and checked before wrapping" {
    const s = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer s.deinit();

    s.source_id_next = std.math.maxInt(u32) - 1;
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32) - 1), try s.allocSourceId());
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), try s.allocSourceId());
    try std.testing.expectError(error.Unsupported, s.allocSourceId());
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u32)) + 1, s.source_id_next);
}

test "retained adapter reclaims backing storage only after raw free" {
    const owner = try Store.init(std.testing.allocator, std.testing.io, .{
        .max_heap_size = 4096,
    });
    defer owner.deinit();

    const baseline = owner.retainedBytes();
    owner.retained_limit = baseline + 8;
    const accounted = owner.accountedAllocator();
    const bytes = try accounted.alloc(u8, 8);
    try std.testing.expectEqual(baseline + 8, owner.retainedBytes());
    accounted.free(bytes);
    try std.testing.expectEqual(baseline, owner.retainedBytes());
}

test "retained adapter cancels provisional claim after raw allocation failure" {
    const owner = try Store.init(std.testing.allocator, std.testing.io, .{
        .max_heap_size = 4096,
    });
    defer owner.deinit();

    var storage: [8]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var account = AccountAllocator.init(owner, fixed.allocator(), .native, .both);
    const accounted = account.allocator();
    const first = try accounted.alloc(u8, 8);
    defer accounted.free(first);
    const retained = owner.retainedBytes();
    try std.testing.expectError(error.OutOfMemory, accounted.alloc(u8, 1));
    try std.testing.expectEqual(retained, owner.retainedBytes());
}

test "retained cap rejects symbol interning without panicking" {
    const owner = try Store.init(std.testing.allocator, std.testing.io, .{
        .max_heap_size = 4096,
    });
    defer owner.deinit();

    owner.retained_limit = owner.retainedBytes();
    try std.testing.expectError(error.OutOfMemory, owner.getsym("quota-symbol"));
}

test "retained cap failure cleans partial Store initialization" {
    try std.testing.expectError(
        error.OutOfMemory,
        Store.init(std.testing.allocator, std.testing.io, .{
            .max_heap_size = 4096,
            .retained_bytes = 0,
        }),
    );
}

test "collect retains typed children of explicitly rooted allocations" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();

    const Pair = struct { child: Ref };
    const child = try gc_store.create(u64);
    child.deref(u64).* = 42;
    const parent = try gc_store.create(Pair);
    parent.deref(Pair).* = .{ .child = child };
    var root = Root.init(parent);
    try gc_store.registerRoot(&root);
    defer gc_store.unregisterRoot(&root) catch unreachable;

    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 2), gc_store.stats().live_objects);
    try std.testing.expectEqual(@as(u64, 42), (try gc_store.derefChecked(u64, child)).*);
}

test "collect reclaims unreachable typed cycles and reuses their folio slots" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();

    const Node = struct { next: Ref };
    const left = try gc_store.create(Node);
    const right = try gc_store.create(Node);
    left.deref(Node).* = .{ .next = right };
    right.deref(Node).* = .{ .next = left };
    const heap_used = gc_store.stats().heap_used;

    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 0), gc_store.stats().live_objects);
    const after_first = gc_store.stats().heap_used;
    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 0), gc_store.stats().live_objects);
    try std.testing.expectEqual(after_first, gc_store.stats().heap_used);

    const reused = try gc_store.create(Node);
    try std.testing.expect(reused.address() == left.address() or
        reused.address() == right.address());
    try std.testing.expectError(error.InvalidRef, gc_store.derefChecked(Node, left));
    try std.testing.expectEqual(heap_used, gc_store.stats().heap_used);
}

test "allocSlice extent traces each typed Ref element" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();

    const child = try gc_store.create(u64);
    child.deref(u64).* = 42;
    const children = try gc_store.allocSlice(Ref, 2);
    children.slice[0] = child;
    children.slice[1] = .nil;
    var root = Root.init(children.ref);
    try gc_store.registerRoot(&root);
    defer gc_store.unregisterRoot(&root) catch unreachable;

    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 2), gc_store.stats().live_objects);
    try std.testing.expectEqual(@as(u64, 42), (try gc_store.derefChecked(u64, child)).*);
}

test "collect follows tagged Value cells and reclaims an unreachable list cycle" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();
    const first = try gc_store.create([2]skript.Value);
    const second = try gc_store.create([2]skript.Value);
    first.deref([2]skript.Value).* = .{ .i64(4), .cons(second.toObject()) };
    second.deref([2]skript.Value).* = .{ .false, .cons(first.toObject()) };
    var root = Root.init(first);
    try gc_store.registerRoot(&root);
    defer gc_store.unregisterRoot(&root) catch unreachable;

    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 2), gc_store.stats().live_objects);
    try std.testing.expectEqual(
        skript.Value.false,
        (try gc_store.derefChecked([2]skript.Value, second))[0],
    );

    root.ref = .nil;
    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 0), gc_store.stats().live_objects);
}

test "collect treats the uninitialized binding marker as an immediate" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();

    const marker = skript.Value.init(
        Object.fromInt(skript.builtins.type_last_idx + 1),
        .null,
    );
    const holder = try gc_store.create([2]skript.Value);
    holder.deref([2]skript.Value).* = .{ marker, .nil };
    var root = Root.init(holder);
    try gc_store.registerRoot(&root);
    defer gc_store.unregisterRoot(&root) catch unreachable;

    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 1), gc_store.stats().live_objects);
    try std.testing.expectEqual(marker, (try gc_store.derefChecked([2]skript.Value, holder))[0]);

    root.ref = .nil;
    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 0), gc_store.stats().live_objects);
}

test "collect ignores foreign opaque handles and reclaims unrooted allocations" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();
    var external: u8 = 3;
    const unrelated = try gc_store.create(u64);
    unrelated.deref(u64).* = 11;
    const holder = try gc_store.create([2]skript.Value);
    holder.deref([2]skript.Value).* = .{
        .opaq(Object.fromPtr(&external)),
        .nil,
    };
    var root = Root.init(holder);
    try gc_store.registerRoot(&root);
    defer gc_store.unregisterRoot(&root) catch unreachable;

    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 1), gc_store.stats().live_objects);
    try std.testing.expectError(error.InvalidRef, gc_store.derefChecked(u64, unrelated));
    try std.testing.expectEqual(@as(u8, 3), external);
}

test "collect follows Store-backed strings and skips host-owned string bytes" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();

    const backing = try gc_store.allocSlice(u8, 4);
    @memcpy(backing.slice, "stor");
    var external: u8 = 99;
    const holder = try gc_store.create([2]skript.Value);
    holder.deref([2]skript.Value).* = .{
        .string(Object.fromPtr(backing.slice.ptr + 1)),
        .string(Object.fromPtr(&external)),
    };
    var root = Root.init(holder);
    try gc_store.registerRoot(&root);
    defer gc_store.unregisterRoot(&root) catch unreachable;

    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 2), gc_store.stats().live_objects);
    _ = try gc_store.derefChecked(u8, backing.ref);
    try std.testing.expectEqual(@as(u8, 't'), backing.slice[1]);
    try std.testing.expectEqual(@as(u8, 99), external);

    root.ref = .nil;
    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 0), gc_store.stats().live_objects);
}

test "collect marks Store-backed opaque references" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();

    const resource = try gc_store.create(u64);
    resource.deref(u64).* = 29;
    var root_value: ValueRootContext = .{ .value = .opaq(resource.toObject()) };
    var provider: RootProvider = .{
        .context = &root_value,
        .trace = traceTestValueRoot,
    };
    try gc_store.registerRootProvider(&provider);
    defer gc_store.unregisterRootProvider(&provider) catch unreachable;

    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 1), gc_store.stats().live_objects);
    try std.testing.expectEqual(@as(u64, 29), (try gc_store.derefChecked(u64, resource)).*);
}

test "collect rejects stale opaque Store references before sweeping" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();

    const retained = try gc_store.create(u64);
    retained.deref(u64).* = 17;
    const stale = try gc_store.create(u64);
    try gc_store.discardUnpublished(stale);
    var retained_root = Root.init(retained);
    try gc_store.registerRoot(&retained_root);
    defer gc_store.unregisterRoot(&retained_root) catch unreachable;
    var stale_root: ValueRootContext = .{ .value = .opaq(stale.toObject()) };
    var provider: RootProvider = .{
        .context = &stale_root,
        .trace = traceTestValueRoot,
    };
    try gc_store.registerRootProvider(&provider);
    defer gc_store.unregisterRootProvider(&provider) catch unreachable;

    try std.testing.expectError(
        error.InvalidRef,
        gc_store.collect(gc_store.assumeStopped()),
    );
    try std.testing.expectEqual(@as(u32, 1), gc_store.stats().live_objects);
    try std.testing.expectEqual(@as(u64, 17), (try gc_store.derefChecked(u64, retained)).*);
}

test "collect validates host-owned Value pointers and rejects Store addresses" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();

    var external: u64 = 23;
    var symbol_bytes: []const u8 = "host-symbol";
    const host_symbol: skript.Sym = &symbol_bytes;
    var root_value: ValueRootContext = .{ .value = .pid(Object.fromPtr(&external)) };
    var provider: RootProvider = .{
        .context = &root_value,
        .trace = traceTestValueRoot,
    };
    try gc_store.registerRootProvider(&provider);
    defer gc_store.unregisterRootProvider(&provider) catch unreachable;

    try gc_store.collect(gc_store.assumeStopped());
    root_value.value = .init(skript.builtins.type_ast, Object.fromPtr(&external));
    try gc_store.collect(gc_store.assumeStopped());
    root_value.value = skript.Value.symbol(host_symbol);
    try gc_store.collect(gc_store.assumeStopped());
    root_value.value = skript.Value.keyword(host_symbol);
    try gc_store.collect(gc_store.assumeStopped());
    const intrinsic: skript.FuncPtr = @ptrCast(&skript.Value.isNil);
    root_value.value = skript.Value.intrinsic(intrinsic);
    try gc_store.collect(gc_store.assumeStopped());
    root_value.value = .init(skript.builtins.type_cstring, Object.fromPtr(&external));
    try std.testing.expectError(
        error.UntracedAllocation,
        gc_store.collect(gc_store.assumeStopped()),
    );
    try std.testing.expectEqual(@as(u32, 0), gc_store.stats().live_objects);

    const store_payload = try gc_store.create(u64);
    store_payload.deref(u64).* = 41;
    inline for (.{
        skript.builtins.type_ast,
        skript.builtins.type_intrinsic,
        skript.builtins.type_keyword,
        skript.builtins.type_pid,
        skript.builtins.type_symbol,
    }) |tag| {
        root_value.value = .init(tag, Object.fromPtr(store_payload.deref(u64)));
        try std.testing.expectError(
            error.InvalidRef,
            gc_store.collect(gc_store.assumeStopped()),
        );
    }
    try std.testing.expectEqual(@as(u32, 1), gc_store.stats().live_objects);
    try std.testing.expectEqual(@as(u64, 41), (try gc_store.derefChecked(u64, store_payload)).*);
}

test "Header.meta is a traced Store edge" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();

    const owner = try gc_store.create(u64);
    const metadata = try gc_store.create(u32);
    metadata.deref(u32).* = 7;
    const header: *Header = @ptrFromInt(owner.address() - header_size);
    header.meta = metadata;
    var root = Root.init(owner);
    try gc_store.registerRoot(&root);
    defer gc_store.unregisterRoot(&root) catch unreachable;

    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 2), gc_store.stats().live_objects);
    try std.testing.expectEqual(@as(u32, 7), (try gc_store.derefChecked(u32, metadata)).*);
}

test "derefChecked rejects a mismatched Ref type" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();

    const reference = try gc_store.create(u32);
    try std.testing.expectError(error.TypeMismatch, gc_store.derefChecked(u64, reference));
    try std.testing.expectEqual(
        @as(usize, reference.address()),
        @intFromPtr(try gc_store.derefChecked(u32, reference)),
    );
}

test "collect refuses a foreign root without dereferencing it" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();

    var foreign align(8) = @as(u64, 7);
    var root = Root.init(Ref.unsafeTaggedRef(&foreign));
    try gc_store.registerRoot(&root);
    defer gc_store.unregisterRoot(&root) catch unreachable;

    try std.testing.expectError(error.ForeignReference, gc_store.collect(gc_store.assumeStopped()));
    try std.testing.expectEqual(@as(u32, 0), gc_store.stats().live_objects);
}

test "large typed allocations are swept and their extents reused" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();

    const buffer = try gc_store.allocSlice(u8, 20_000);
    const initial_address = buffer.ref.address();
    const heap_used = gc_store.stats().heap_used;
    var root = Root.init(buffer.ref);
    try gc_store.registerRoot(&root);
    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 1), gc_store.stats().live_objects);
    try gc_store.unregisterRoot(&root);

    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 0), gc_store.stats().live_objects);
    const reused = try gc_store.allocSlice(u8, 20_000);
    try std.testing.expectEqual(initial_address, reused.ref.address());
    try std.testing.expectEqual(heap_used, gc_store.stats().heap_used);
}

test "collect ignores foreign source metadata while retaining typed children" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();
    const Child = struct { reference: Ref };
    var source_table align(8) = @as(u64, 19);
    const leaf = try gc_store.create(u32);
    leaf.deref(u32).* = 42;
    const parent = try gc_store.create(Child);
    parent.deref(Child).* = .{ .reference = leaf };
    const header: *Header = @ptrFromInt(parent.address() - header_size);
    header.meta = Ref.foreignMetadata(&source_table);
    var root = Root.init(parent);
    try gc_store.registerRoot(&root);
    defer gc_store.unregisterRoot(&root) catch unreachable;

    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 2), gc_store.stats().live_objects);
    try std.testing.expectEqual(@as(u32, 42), (try gc_store.derefChecked(u32, leaf)).*);
    try std.testing.expect(header.meta.isForeignMetadata());
}

test "collect preserves a rooted Reader list with arena-owned source locations" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();
    const forms = try skript.Reader.readAll(gc_store, "(1 2)");
    var root = Root.init(forms.obj.toRef());
    try gc_store.registerRoot(&root);
    defer gc_store.unregisterRoot(&root) catch unreachable;
    const before = gc_store.stats().live_objects;

    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(before, gc_store.stats().live_objects);
    const source = skript.Reader.sourceRef(forms.obj.toRef().deref([2]skript.Value)[0]);
    try std.testing.expect(source.unit != null);
    try std.testing.expect(source.unit.?.store == gc_store);
}

test "raw allocator blocks refuse collection until freed and are reusable" {
    const gc_store = try Store.init(std.testing.allocator, std.testing.io, .{
        .max_heap_size = 8192,
    });
    defer gc_store.deinit();

    const raw = try gc_store.allocator().alloc(u8, 8);
    const address = @intFromPtr(raw.ptr);
    try std.testing.expectError(error.RawAllocationPresent, gc_store.collect(gc_store.assumeStopped()));
    gc_store.allocator().free(raw);
    try gc_store.collect(gc_store.assumeStopped());

    const reused = try gc_store.allocator().alloc(u8, 8);
    try std.testing.expectEqual(address, @intFromPtr(reused.ptr));
    gc_store.allocator().free(reused);
}

test "sweep restores terminal folio allocation capacity" {
    const slot_bytes = @as(usize, size_classes[classForSize(header_size + @sizeOf(u64))]) * slots_per_folio;
    const single_folio_bytes = std.mem.alignForward(usize, @sizeOf(Folio) + slot_bytes, 4096);
    const gc_store = try Store.init(std.testing.allocator, std.testing.io, .{
        .max_heap_size = single_folio_bytes,
    });
    defer gc_store.deinit();

    var references: [slots_per_folio]Ref = undefined;
    for (&references) |*reference| reference.* = try gc_store.create(u64);
    const heap_used = gc_store.stats().heap_used;
    try std.testing.expectError(error.OutOfMemory, gc_store.create(u64));

    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 0), gc_store.stats().live_objects);
    for (&references) |*reference| reference.* = try gc_store.create(u64);
    try std.testing.expectEqual(@as(u32, slots_per_folio), gc_store.stats().live_objects);
    try std.testing.expectEqual(heap_used, gc_store.stats().heap_used);
    try std.testing.expectError(error.OutOfMemory, gc_store.create(u64));
}
test "registered root providers retain and release their references" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();

    const child = try gc_store.create(u32);
    child.deref(u32).* = 9;
    var external_root = child;
    var provider: RootProvider = .{
        .context = &external_root,
        .trace = traceTestRoot,
    };
    try gc_store.registerRootProvider(&provider);
    defer gc_store.unregisterRootProvider(&provider) catch unreachable;

    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 1), gc_store.stats().live_objects);
    try std.testing.expectEqual(@as(u32, 9), (try gc_store.derefChecked(u32, child)).*);

    external_root = .nil;
    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 0), gc_store.stats().live_objects);
}

test "unsupported pointer fields refuse collection without a partial sweep" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();

    const Holder = struct { foreign: *u8 };
    var external: u8 = 3;
    const unreachable_object = try gc_store.create(u64);
    unreachable_object.deref(u64).* = 11;
    const holder = try gc_store.create(Holder);
    holder.deref(Holder).* = .{ .foreign = &external };
    var root = Root.init(holder);
    try gc_store.registerRoot(&root);
    defer gc_store.unregisterRoot(&root) catch unreachable;

    try std.testing.expectError(
        error.UntracedAllocation,
        gc_store.collect(gc_store.assumeStopped()),
    );
    try std.testing.expectEqual(@as(u32, 2), gc_store.stats().live_objects);
    try std.testing.expectEqual(@as(u64, 11), (try gc_store.derefChecked(u64, unreachable_object)).*);

    root.ref = .nil;
    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 0), gc_store.stats().live_objects);
}

test "collect rejects createOwned refs without reading their headers" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const foreign = try Store.createOwned(u64, arena.allocator());
    var root = Root.init(foreign);
    try gc_store.registerRoot(&root);
    defer gc_store.unregisterRoot(&root) catch unreachable;

    try std.testing.expectError(
        error.ForeignReference,
        gc_store.collect(gc_store.assumeStopped()),
    );
}
test "createTraced descriptors visit only declared typed references" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();

    var foreign: u8 = 3;
    const child = try gc_store.create(u64);
    child.deref(u64).* = 17;
    const parent = try gc_store.createTraced(ExplicitTraceNode, traceExplicitTraceNode);
    parent.deref(ExplicitTraceNode).* = .{ .child = child, .foreign = &foreign };
    var root = Root.init(parent);
    try gc_store.registerRoot(&root);
    defer gc_store.unregisterRoot(&root) catch unreachable;

    try gc_store.collect(gc_store.assumeStopped());
    try std.testing.expectEqual(@as(u32, 2), gc_store.stats().live_objects);
    try std.testing.expectEqual(@as(u64, 17), (try gc_store.derefChecked(u64, child)).*);
}

test "discardUnpublished releases unexposed folio and large allocations" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();

    const small = try gc_store.create(u32);
    const small_address = small.address();
    try gc_store.discardUnpublished(small);
    try std.testing.expectEqual(@as(u32, 0), gc_store.stats().live_objects);
    try std.testing.expectError(error.InvalidRef, gc_store.derefChecked(u32, small));
    const reused_small = try gc_store.create(u32);
    try std.testing.expectEqual(small_address, reused_small.address());
    try std.testing.expectError(error.InvalidRef, gc_store.derefChecked(u32, small));

    const large = try gc_store.allocSlice(u8, 20_000);
    const large_address = large.ref.address();
    try gc_store.discardUnpublished(large.ref);
    try std.testing.expectEqual(@as(u32, 1), gc_store.stats().live_objects);
    try std.testing.expectError(error.InvalidRef, gc_store.derefChecked(u8, large.ref));
    const reused_large = try gc_store.allocSlice(u8, 20_000);
    try std.testing.expectEqual(large_address, reused_large.ref.address());
    try std.testing.expectError(error.InvalidRef, gc_store.derefChecked(u8, large.ref));
}

test "discardUnpublished refuses foreign and untagged references" {
    const gc_store = try Store.initDefault(std.testing.allocator, std.testing.io);
    defer gc_store.deinit();
    var foreign align(8) = @as(u64, 17);
    try std.testing.expectError(
        error.InvalidRef,
        gc_store.discardUnpublished(Ref.unsafeTaggedRef(&foreign)),
    );
    try std.testing.expectError(
        error.ForeignReference,
        gc_store.discardUnpublished(Ref.fromAddr(&foreign, 1)),
    );
    try gc_store.discardUnpublished(.nil);
}
