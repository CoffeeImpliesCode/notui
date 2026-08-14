//! Region-owned immutable mathematical expression DAGs.
//!
//! Expr is mathematical data. It is not Reader syntax, executable Code, or a
//! numeric automatic-differentiation representation. A Region owns flat storage
//! for published nodes and gives callers checked, bounded read views.

const std = @import("std");
const EvalContext = @import("EvalContext.zig");
const Primitive = @import("primitive.zig");
const Store = @import("Store.zig");

const Allocator = std.mem.Allocator;
const PrimitiveId = Primitive.PrimitiveId;
const hasher_type = std.hash.Fnv1a_64;

/// Errors returned by this module. Context quota errors are part of this set so
/// callers can distinguish terminal exhaustion from malformed expressions.
pub const Error = error{
    OutOfMemory,
    Exhausted,
    Denied,
    Unsupported,
    WriteFailed,
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
};
/// Resolve a Runtime-owned context during Region initialization. The resolved
/// context is used only for validation and initial allocation accounting.
pub const ContextResolver = *const fn (*const anyopaque) *EvalContext;

/// A process-local node identity. Node IDs are meaningful only in their Region.
pub const NodeId = enum(u32) {
    invalid = std.math.maxInt(u32),
    _,

    pub fn fromIndex(offset: usize) Error!NodeId {
        if (offset >= std.math.maxInt(u32)) return error.LimitExceeded;
        return @enumFromInt(@as(u32, @intCast(offset)));
    }

    pub fn index(self: NodeId) usize {
        return @intCast(@intFromEnum(self));
    }

    pub fn isValid(self: NodeId) bool {
        return self != .invalid;
    }
};

/// A copied name in a Region's flat name-byte storage.
pub const NameId = enum(u32) {
    invalid = std.math.maxInt(u32),
    _,

    pub fn fromIndex(offset: usize) Error!NameId {
        if (offset >= std.math.maxInt(u32)) return error.LimitExceeded;
        return @enumFromInt(@as(u32, @intCast(offset)));
    }

    pub fn index(self: NameId) usize {
        return @intCast(@intFromEnum(self));
    }

    pub fn isValid(self: NameId) bool {
        return self != .invalid;
    }
};

/// A compact range into one of the Region's flat side arrays.
pub const Range = struct {
    start: u32 = 0,
    len: u32 = 0,

    pub fn init(start: usize, len: usize) Error!Range {
        const start_u32 = std.math.cast(u32, start) orelse return error.LimitExceeded;
        const len_u32 = std.math.cast(u32, len) orelse return error.LimitExceeded;
        _ = std.math.add(u32, start_u32, len_u32) catch return error.LimitExceeded;
        return .{ .start = start_u32, .len = len_u32 };
    }

    pub fn end(self: Range) usize {
        return @as(usize, self.start) + @as(usize, self.len);
    }

    pub fn isEmpty(self: Range) bool {
        return self.len == 0;
    }
};

pub const LabelRange = Range;
pub const ShapeRange = Range;

/// Caller-selected identity for one expression region. Zero is invalid.
pub const RegionId = enum(u64) {
    invalid = 0,
    _,

    pub fn fromInt(value: u64) Error!RegionId {
        if (value == 0) return error.InvalidIdentity;
        return @enumFromInt(value);
    }

    pub fn isValid(self: RegionId) bool {
        return self != .invalid;
    }
};

pub const RegionIdentity = RegionId;

/// Stable identity of a free variable. Display names are deliberately absent.
pub const FreeVarId = struct {
    region: RegionId,
    local: u32,

    pub fn isValid(self: FreeVarId) bool {
        return self.region.isValid() and self.local != 0 and self.local != std.math.maxInt(u32);
    }

    pub fn eql(lhs: FreeVarId, rhs: FreeVarId) bool {
        return lhs.region == rhs.region and lhs.local == rhs.local;
    }
};

pub const FreeVariableId = FreeVarId;

pub const Domain = enum {
    unknown,
    real,
    signed_integer,
    unsigned_integer,
    boolean,
    structured,
};

pub const DType = enum {
    f16,
    f32,
    f64,
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
    boolean,
    unknown,
};

/// Raw scalar payload. Floating values are stored as bits, not numeric values,
/// so NaN payloads and signed zero survive interning and snapshots.
pub const Scalar = union(enum) {
    f64_bits: u64,
    f32_bits: u32,
    signed: i64,
    unsigned: u64,
    boolean: bool,

    pub fn fromF64(value: f64) Scalar {
        return .{ .f64_bits = @bitCast(value) };
    }

    pub fn fromF32(value: f32) Scalar {
        return .{ .f32_bits = @bitCast(value) };
    }

    pub fn eql(lhs: Scalar, rhs: Scalar) bool {
        if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
        return switch (lhs) {
            .f64_bits => |bits| switch (rhs) {
                .f64_bits => |other| bits == other,
                else => false,
            },
            .f32_bits => |bits| switch (rhs) {
                .f32_bits => |other| bits == other,
                else => false,
            },
            .signed => |value| switch (rhs) {
                .signed => |other| value == other,
                else => false,
            },
            .unsigned => |value| switch (rhs) {
                .unsigned => |other| value == other,
                else => false,
            },
            .boolean => |value| switch (rhs) {
                .boolean => |other| value == other,
                else => false,
            },
        };
    }

    pub fn isZero(self: Scalar) bool {
        return switch (self) {
            .f64_bits => |bits| @as(f64, @bitCast(bits)) == 0.0,
            .f32_bits => |bits| @as(f32, @bitCast(bits)) == 0.0,
            .signed => |value| value == 0,
            .unsigned => |value| value == 0,
            .boolean => |value| !value,
        };
    }

    pub fn isFinite(self: Scalar) bool {
        return switch (self) {
            .f64_bits => |bits| std.math.isFinite(@as(f64, @bitCast(bits))),
            .f32_bits => |bits| std.math.isFinite(@as(f32, @bitCast(bits))),
            else => true,
        };
    }

    pub fn zeroFor(domain: Domain) Scalar {
        return switch (domain) {
            .real => Scalar.fromF64(0.0),
            .signed_integer => .{ .signed = 0 },
            .unsigned_integer => .{ .unsigned = 0 },
            .boolean => .{ .boolean = false },
            else => Scalar.fromF64(0.0),
        };
    }

    pub fn oneFor(domain: Domain) Scalar {
        return switch (domain) {
            .real => Scalar.fromF64(1.0),
            .signed_integer => .{ .signed = 1 },
            .unsigned_integer => .{ .unsigned = 1 },
            .boolean => .{ .boolean = true },
            else => Scalar.fromF64(1.0),
        };
    }
};

pub const ScalarLiteral = Scalar;

pub const SourceOrigin = struct {
    unit: u64,
    node: u32,
};

pub const Origin = union(enum) {
    none,
    source: SourceOrigin,
    generated: struct { identity: u64 },
};

pub const PrimitiveIdentity = struct {
    primitive: PrimitiveId,
    registry_revision: u64,
    implementation_revision: u64 = 0,
    rule_revision: u64 = 0,

    pub fn isValid(self: PrimitiveIdentity) bool {
        return self.primitive.isValid();
    }

    pub fn eql(lhs: PrimitiveIdentity, rhs: PrimitiveIdentity) bool {
        return lhs.primitive == rhs.primitive and
            lhs.registry_revision == rhs.registry_revision and
            lhs.implementation_revision == rhs.implementation_revision and
            lhs.rule_revision == rhs.rule_revision;
    }
};

pub const OpaqueIdentity = struct {
    id: u64,
    revision: u64,

    pub fn isValid(self: OpaqueIdentity) bool {
        return self.id != 0 and self.revision != 0;
    }

    pub fn eql(lhs: OpaqueIdentity, rhs: OpaqueIdentity) bool {
        return lhs.id == rhs.id and lhs.revision == rhs.revision;
    }
};

pub const EffectKnowledge = enum {
    known_none,
    known,
    unknown,
};

pub const Linearity = enum {
    linear,
    nonlinear,
    unknown,
};

pub const Assumptions = enum {
    none,
    finite,
    nonzero,
    finite_nonzero,
};

pub const StaticAtomKind = enum {
    nil,
    symbol,
    keyword,
    string,
};

pub const StaticAtomNode = struct {
    kind: StaticAtomKind,
    name: NameId,
};

pub const NodeTag = enum {
    scalar,
    static_atom,
    free_variable,
    primitive_call,
    conditional,
    opaque_call,
    list,
    map,
    tensor,
    record,
};

pub const ScalarNode = struct {
    value: Scalar,
    domain: Domain,
};

pub const StaticAtomSpec = struct {
    kind: StaticAtomKind,
    bytes: []const u8 = &.{},
    origin: Origin = .none,
};

pub const StaticAtomNodeSpec = StaticAtomSpec;

pub const FreeVariableNode = struct {
    identity: FreeVarId,
    name: NameId,
    domain: Domain,
    assumptions: Assumptions,
};

pub const PrimitiveCallNode = struct {
    identity: PrimitiveIdentity,
    arguments: Range,
    domain: Domain,
};

pub const ConditionalNode = struct {
    predicate: NodeId,
    then_branch: NodeId,
    else_branch: NodeId,
    arguments: Range,
    domain: Domain,
};

pub const OpaqueCallNode = struct {
    identity: OpaqueIdentity,
    display_label: NameId,
    arguments: Range,
    domain: Domain,
    effects: EffectKnowledge,
    linearity: Linearity,
};

pub const ListNode = struct {
    elements: Range,
    domain: Domain,
};

pub const MapNode = struct {
    labels: LabelRange,
    values: Range,
    domain: Domain,
};

pub const TensorNode = struct {
    dtype: DType,
    shape: ShapeRange,
    elements: Range,
    domain: Domain,
};

pub const RecordNode = struct {
    type_label: NameId,
    fields: LabelRange,
    values: Range,
    domain: Domain,
};

pub const NodeKind = union(NodeTag) {
    scalar: ScalarNode,
    static_atom: StaticAtomNode,
    free_variable: FreeVariableNode,
    primitive_call: PrimitiveCallNode,
    conditional: ConditionalNode,
    opaque_call: OpaqueCallNode,
    list: ListNode,
    map: MapNode,
    tensor: TensorNode,
    record: RecordNode,
};

/// One fully published node. `hash_next` is private implementation linkage;
/// callers must use checked readers instead of retaining storage pointers.
pub const Node = struct {
    id: NodeId,
    kind: NodeKind,
    origin: Origin = .none,
    hash: u64 = 0,
    hash_next: NodeId = .invalid,

    pub fn effectKnowledge(self: Node) EffectKnowledge {
        return switch (self.kind) {
            .opaque_call => |call| call.effects,
            else => .known_none,
        };
    }

    pub fn linearity(self: Node) Linearity {
        return switch (self.kind) {
            .opaque_call => |call| call.linearity,
            else => .nonlinear,
        };
    }
};

pub const ScalarSpec = struct {
    value: Scalar,
    domain: Domain = .unknown,
    origin: Origin = .none,
};

pub const FreeVariableSpec = struct {
    identity: FreeVarId,
    name: []const u8,
    domain: Domain = .real,
    assumptions: Assumptions = .none,
    origin: Origin = .none,
};

pub const PrimitiveCallSpec = struct {
    identity: PrimitiveIdentity,
    arguments: []const NodeId,
    domain: Domain = .unknown,
    origin: Origin = .none,
};

pub const ConditionalSpec = struct {
    predicate: NodeId,
    then_branch: NodeId,
    else_branch: NodeId,
    domain: Domain = .unknown,
    origin: Origin = .none,
};

pub const OpaqueCallSpec = struct {
    identity: OpaqueIdentity,
    display_label: []const u8 = "opaque",
    arguments: []const NodeId,
    domain: Domain = .unknown,
    effects: EffectKnowledge = .unknown,
    linearity: Linearity = .unknown,
    origin: Origin = .none,
};

pub const ListSpec = struct {
    elements: []const NodeId,
    domain: Domain = .structured,
    origin: Origin = .none,
};

pub const MapSpec = struct {
    labels: []const []const u8,
    values: []const NodeId,
    domain: Domain = .structured,
    origin: Origin = .none,
};

pub const TensorSpec = struct {
    dtype: DType,
    shape: []const u32,
    elements: []const NodeId,
    domain: Domain = .structured,
    origin: Origin = .none,
};

pub const RecordSpec = struct {
    type_label: []const u8,
    field_labels: []const []const u8,
    fields: []const NodeId,
    domain: Domain = .structured,
    origin: Origin = .none,
};

pub const NodeSpec = union(NodeTag) {
    scalar: ScalarSpec,
    static_atom: StaticAtomSpec,
    free_variable: FreeVariableSpec,
    primitive_call: PrimitiveCallSpec,
    conditional: ConditionalSpec,
    opaque_call: OpaqueCallSpec,
    list: ListSpec,
    map: MapSpec,
    tensor: TensorSpec,
    record: RecordSpec,
};

pub const Limits = struct {
    max_nodes: usize = 1_048_576,
    max_edges: usize = 4_194_304,
    max_names: usize = 1_048_576,
    max_labels: usize = 1_048_576,
    max_name_bytes: usize = 16 * 1024 * 1024,
    max_shape_dimensions: usize = 1_048_576,
    max_depth: usize = 16_384,
};
pub const RegionOptions = struct {
    identity: RegionId,
    limits: Limits = .{},
};

pub const Options = RegionOptions;

pub const RewritePolicy = enum {
    formal_real,
    strict_ieee,
};

pub const DispatchRewriteOperators = struct {
    primitive: PrimitiveIdentity,
    add: i64,
    multiply: i64,
    divide: i64,
    zero_like: i64,
    one_like: i64,
    coerce_tangent: i64,
    realize_tangent: i64,
};

pub const RewriteOperators = struct {
    multiply: ?PrimitiveIdentity = null,
    divide: ?PrimitiveIdentity = null,
    dispatch: ?DispatchRewriteOperators = null,
};

pub const RewriteLimits = struct {
    max_nodes: usize = 16_384,
    max_edges: usize = 4_194_304,
    max_rule_steps: usize = 1_024,
    max_passes: usize = 8,
};

pub const Facts = struct {
    finite: bool = false,
    nonzero: bool = false,
    positive: bool = false,
};

pub const FactQuery = *const fn (
    ?*const EvalContext,
    NodeId,
    Node,
    *const anyopaque,
) Error!Facts;

pub const FactsProvider = struct {
    context: *const anyopaque,
    query: FactQuery,
};

pub const RewriteView = struct {
    id: NodeId,
    node: Node,
};

pub const RewriteBuilder = struct {
    region: *Region,
    context: ?*const EvalContext,
    max_new_nodes: usize = 16_384,
    new_nodes: usize = 0,

    pub fn intern(self: *RewriteBuilder, spec: NodeSpec) Error!NodeId {
        if (self.new_nodes >= self.max_new_nodes) return error.RewriteLimit;
        self.new_nodes += 1;
        return self.region.intern(self.context, spec);
    }

    pub fn node(self: *const RewriteBuilder, id: NodeId) Error!Node {
        const control = self.region.control orelse return error.Expired;
        try control.validateContext(self.context);
        try charge(self.region.effectiveContext(self.context), 1, 0);
        var reader = try control.acquireReader();
        defer reader.deinit();
        return checkedNodeInStorage(reader.storage, id);
    }
};

pub const RewriteCallback = *const fn (
    ?*const EvalContext,
    *RewriteBuilder,
    RewriteView,
    *const anyopaque,
) Error!?NodeId;

pub const CustomRule = struct {
    context: *const anyopaque,
    apply: RewriteCallback,
};

pub const RewriteOptions = struct {
    policy: RewritePolicy = .strict_ieee,
    operators: RewriteOperators = .{},
    facts: ?FactsProvider = null,
    custom: ?CustomRule = null,
    limits: RewriteLimits = .{},
};

const NameRef = struct {
    start: u32,
    len: u32,
};

const Storage = struct {
    allocator: Allocator,
    limits: Limits,
    nodes: std.ArrayList(Node) = .empty,
    edges: std.ArrayList(NodeId) = .empty,
    labels: std.ArrayList(NameId) = .empty,
    names: std.ArrayList(u8) = .empty,
    name_refs: std.ArrayList(NameRef) = .empty,
    shapes: std.ArrayList(u32) = .empty,
    hash_heads: std.AutoHashMapUnmanaged(u64, NodeId) = .empty,

    fn init(allocator: Allocator, limits: Limits) Storage {
        return .{ .allocator = allocator, .limits = limits };
    }

    fn deinit(self: *Storage) void {
        self.hash_heads.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        self.labels.deinit(self.allocator);
        self.names.deinit(self.allocator);
        self.name_refs.deinit(self.allocator);
        self.shapes.deinit(self.allocator);
        self.* = undefined;
    }
};

const control_open: u8 = 0;
const control_closed: u8 = 1;

/// Stable lifetime state. The reclaimable Storage pointer is atomic and is
/// never dereferenced by a handle until its state and reader lease are checked.
const Control = struct {
    allocator: Allocator,
    identity: RegionId,
    limits: Limits,
    owner_runtime: ?usize = null,
    storage: std.atomic.Value(?*Storage),
    state: std.atomic.Value(u8) = .init(control_open),
    references: std.atomic.Value(u32) = .init(1),
    readers: std.atomic.Value(u32) = .init(0),
    next_free_local: std.atomic.Value(u32) = .init(1),

    fn context(self: *const Control) ?*const EvalContext {
        const owner_runtime = self.owner_runtime orelse return null;
        const active = EvalContext.active orelse return null;
        if (@intFromPtr(active.runtime) != owner_runtime) return null;
        return active;
    }
    fn validateContext(self: *const Control, supplied_context: ?*const EvalContext) Error!void {
        const owner_runtime = self.owner_runtime orelse return;
        const supplied = supplied_context orelse EvalContext.active orelse return;
        if (@intFromPtr(supplied.runtime) != owner_runtime) return error.Denied;
    }

    fn retain(self: *Control) bool {
        var old = self.references.load(.acquire);
        while (old != 0 and old != std.math.maxInt(u32)) {
            if (self.references.cmpxchgWeak(old, old + 1, .acq_rel, .acquire) == null) {
                return true;
            }
            old = self.references.load(.acquire);
        }
        return false;
    }

    fn release(self: *Control) void {
        const old = self.references.fetchSub(1, .acq_rel);
        std.debug.assert(old != 0);
        if (old == 1) {
            self.reclaimStorage();
            self.allocator.destroy(self);
        }
    }

    fn close(self: *Control) void {
        if (self.state.cmpxchgStrong(control_open, control_closed, .acq_rel, .acquire) == null) {
            self.reclaimStorage();
        }
    }

    fn reclaimStorage(self: *Control) void {
        if (self.state.load(.acquire) != control_closed) return;
        if (self.readers.load(.acquire) != 0) return;
        const storage = self.storage.load(.acquire) orelse return;
        if (self.storage.cmpxchgStrong(storage, null, .acq_rel, .acquire) != null) return;
        storage.deinit();
        self.allocator.destroy(storage);
    }

    fn acquireReader(self: *Control) Error!Reader {
        if (!self.retain()) return error.Expired;
        if (self.state.load(.acquire) != control_open) {
            self.release();
            return error.Expired;
        }
        const old_readers = self.readers.fetchAdd(1, .acq_rel);
        if (old_readers == std.math.maxInt(u32)) {
            _ = self.readers.fetchSub(1, .acq_rel);
            self.release();
            return error.LimitExceeded;
        }
        if (self.state.load(.acquire) != control_open) {
            _ = self.readers.fetchSub(1, .acq_rel);
            self.reclaimStorage();
            self.release();
            return error.Expired;
        }
        const storage = self.storage.load(.acquire) orelse {
            _ = self.readers.fetchSub(1, .acq_rel);
            self.release();
            return error.Expired;
        };
        return .{
            .control = self,
            .storage = storage,
            .active = true,
        };
    }

    fn releaseReader(self: *Control) void {
        const old_readers = self.readers.fetchSub(1, .acq_rel);
        std.debug.assert(old_readers != 0);
        if (old_readers == 1) self.reclaimStorage();
        self.release();
    }
};

/// A checked read lease. It keeps the reclaimable arrays alive until deinit.
pub const Reader = struct {
    control: *Control,
    storage: *Storage,
    active: bool,

    pub fn deinit(self: *Reader) void {
        if (!self.active) return;
        self.active = false;
        self.control.releaseReader();
    }

    pub fn node(self: *const Reader, id: NodeId) Error!Node {
        if (!self.active) return error.Expired;
        return checkedNodeInStorage(self.storage, id);
    }

    pub fn name(self: *const Reader, id: NameId) Error![]const u8 {
        if (!self.active) return error.Expired;
        return nameBytes(self.storage, id);
    }

    pub fn label(self: *const Reader, labels: LabelRange, index: usize) Error![]const u8 {
        if (!self.active) return error.Expired;
        const label_id = try labelId(self.storage, labels, index);
        return nameBytes(self.storage, label_id);
    }

    pub fn operands(self: *const Reader, node_value: Node) Error![]const NodeId {
        if (!self.active) return error.Expired;
        const range = nodeOperandsRange(node_value) orelse return &.{};
        return edgesSlice(self.storage, range);
    }

    pub fn shape(self: *const Reader, dimensions: ShapeRange) Error![]const u32 {
        if (!self.active) return error.Expired;
        return shapeSlice(self.storage, dimensions);
    }
};

/// An owned, bounded snapshot. It does not retain the Region or its arrays.
pub const Snapshot = struct {
    allocator: Allocator,
    storage: Storage,
    root_id: NodeId,
    active: bool = true,

    pub fn deinit(self: *Snapshot) void {
        if (!self.active) return;
        self.active = false;
        self.storage.deinit();
    }

    pub fn root(self: *const Snapshot) NodeId {
        return self.root_id;
    }

    pub fn nodeCount(self: *const Snapshot) usize {
        return if (self.active) self.storage.nodes.items.len else 0;
    }

    pub fn node(self: *const Snapshot, id: NodeId) Error!Node {
        if (!self.active) return error.Expired;
        return checkedNodeInStorage(&self.storage, id);
    }

    pub fn name(self: *const Snapshot, id: NameId) Error![]const u8 {
        if (!self.active) return error.Expired;
        return nameBytes(&self.storage, id);
    }

    pub fn label(self: *const Snapshot, labels: LabelRange, index: usize) Error![]const u8 {
        if (!self.active) return error.Expired;
        return nameBytes(&self.storage, try labelId(&self.storage, labels, index));
    }

    pub fn operands(self: *const Snapshot, node_value: Node) Error![]const NodeId {
        if (!self.active) return error.Expired;
        const range = nodeOperandsRange(node_value) orelse return &.{};
        return edgesSlice(&self.storage, range);
    }

    pub fn shape(self: *const Snapshot, dimensions: ShapeRange) Error![]const u32 {
        if (!self.active) return error.Expired;
        return shapeSlice(&self.storage, dimensions);
    }
};

/// A stable node reference. Handles keep only the control object alive after
/// close; storage is reclaimed as soon as no Reader remains.
pub const Handle = struct {
    control: *Control,
    node_id: NodeId,
    active: bool,

    pub fn deinit(self: *Handle) void {
        if (!self.active) return;
        self.active = false;
        self.control.release();
    }

    pub fn nodeId(self: *const Handle) NodeId {
        return self.node_id;
    }

    pub fn isExpired(self: *const Handle) bool {
        return !self.active or self.control.state.load(.acquire) != control_open;
    }

    pub fn acquire(self: *const Handle, context: ?*const EvalContext) Error!Reader {
        try self.control.validateContext(context);
        const active_context = context orelse self.control.context();
        try charge(active_context, 1, 0);
        if (!self.active) return error.Expired;
        if (self.control.state.load(.acquire) != control_open) return error.Expired;
        const reader = try self.control.acquireReader();
        const node = checkedNodeInStorage(reader.storage, self.node_id) catch |err| {
            var mutable_reader = reader;
            mutable_reader.deinit();
            return err;
        };
        std.debug.assert(node.id == self.node_id);
        return reader;
    }

    pub fn snapshot(
        self: *const Handle,
        allocator: Allocator,
        context: ?*const EvalContext,
        limits: Limits,
    ) Error!Snapshot {
        const active_context = context orelse self.control.context();
        const reader = try self.acquire(active_context);
        defer {
            var mutable_reader = reader;
            mutable_reader.deinit();
        }
        return snapshotFromStorage(allocator, reader.storage, self.node_id, active_context, limits);
    }
};

/// An owning expression region. Writers are single-threaded; readers use the
/// lifetime protocol above and may run concurrently with close.
pub const Region = struct {
    allocator: Allocator,
    control: ?*Control,

    pub fn init(
        allocator: Allocator,
        context: ?*const EvalContext,
        options: RegionOptions,
    ) Error!Region {
        return initOwned(allocator, null, null, context, options);
    }

    /// Initialize a region with an owner runtime identity resolved once.
    /// The resolver must not return a stack-local context.
    pub fn initOwned(
        allocator: Allocator,
        owner: ?*const anyopaque,
        resolve_context: ?ContextResolver,
        context: ?*const EvalContext,
        options: RegionOptions,
    ) Error!Region {
        if ((owner == null) != (resolve_context == null)) return error.InvalidRegion;
        if (!options.identity.isValid()) return error.InvalidIdentity;
        if (options.limits.max_nodes == 0) return error.LimitExceeded;
        if (options.limits.max_nodes >= std.math.maxInt(u32)) return error.LimitExceeded;
        if (options.limits.max_edges >= std.math.maxInt(u32)) return error.LimitExceeded;
        if (options.limits.max_names >= std.math.maxInt(u32)) return error.LimitExceeded;
        if (options.limits.max_labels >= std.math.maxInt(u32)) return error.LimitExceeded;
        if (options.limits.max_shape_dimensions >= std.math.maxInt(u32)) return error.LimitExceeded;
        if (options.limits.max_name_bytes >= std.math.maxInt(u32)) return error.LimitExceeded;

        const owner_context: ?*const EvalContext = if (owner) |token|
            if (resolve_context) |resolve| resolve(token) else unreachable
        else
            null;
        const owner_runtime: ?usize = if (owner_context) |resolved|
            @intFromPtr(resolved.runtime)
        else
            null;
        const lineage_context = context orelse EvalContext.active;
        if (lineage_context) |active| {
            if (owner_runtime) |runtime| {
                if (@intFromPtr(active.runtime) != runtime) return error.Denied;
            }
        }
        const active_context: ?*const EvalContext =
            context orelse if (owner_runtime != null) lineage_context else owner_context;
        var accounting = AccountingAllocator.init(allocator, active_context);
        const storage = accounting.allocator().create(Storage) catch |err| {
            return mapAllocationError(&accounting, err);
        };
        errdefer allocator.destroy(storage);
        storage.* = Storage.init(allocator, options.limits);

        const control = accounting.allocator().create(Control) catch |err| {
            return mapAllocationError(&accounting, err);
        };
        errdefer allocator.destroy(control);
        control.* = .{
            .allocator = allocator,
            .identity = options.identity,
            .limits = options.limits,
            .owner_runtime = owner_runtime,
            .storage = .init(storage),
        };
        return .{
            .allocator = allocator,
            .control = control,
        };
    }

    pub fn close(self: *Region) void {
        if (self.control) |control| control.close();
    }

    pub fn deinit(self: *Region) void {
        const control = self.control orelse return;
        control.close();
        self.control = null;
        control.release();
    }

    pub fn isClosed(self: *const Region) bool {
        const control = self.control orelse return true;
        return control.state.load(.acquire) != control_open;
    }

    pub fn identity(self: *const Region) RegionId {
        return (self.control orelse return .invalid).identity;
    }

    pub fn freshVariable(
        self: *Region,
        context: ?*const EvalContext,
        display_name: []const u8,
        domain: Domain,
        assumptions: Assumptions,
    ) Error!NodeId {
        const control = try self.openControl();
        try control.validateContext(context);
        try charge(self.effectiveContext(context), 1, 0);
        const local = try allocateFreeLocal(control);
        const variable_identity: FreeVarId = .{ .region = control.identity, .local = local };
        return self.intern(context, .{ .free_variable = .{
            .identity = variable_identity,
            .name = display_name,
            .domain = domain,
            .assumptions = assumptions,
        } });
    }

    pub fn intern(self: *Region, context: ?*const EvalContext, spec: NodeSpec) Error!NodeId {
        const control = try self.openControl();
        try control.validateContext(context);
        const active_context = self.effectiveContext(context);
        try charge(active_context, 1, 1);
        const storage = control.storage.load(.acquire) orelse return error.Expired;
        try validateSpecLimits(spec, storage.limits);
        try validateNodeSpec(storage, spec, storage.limits);
        const hash = hashNodeSpec(storage, spec);
        if (findMatchingNode(storage, hash, spec)) |existing| return existing;

        // Copy caller slices before Region allocation. This also handles
        // callers that build a new node from this Region's own views.
        var scratch_accounting = AccountingAllocator.init(self.allocator, active_context);
        var scratch_arena = std.heap.ArenaAllocator.init(scratch_accounting.allocator());
        defer scratch_arena.deinit();
        const owned = copyNodeSpec(scratch_arena.allocator(), spec) catch |err| {
            if (err == error.OutOfMemory) {
                return mapAllocationError(&scratch_accounting, err);
            }
            return err;
        };
        return self.internOwned(active_context, storage, owned);
    }

    pub fn checkedNode(self: *const Region, id: NodeId) Error!Node {
        const control = self.control orelse return error.Expired;
        try control.validateContext(null);
        try charge(control.context(), 1, 0);
        var reader = try control.acquireReader();
        defer reader.deinit();
        return checkedNodeInStorage(reader.storage, id);
    }

    pub fn acquire(self: *const Region, context: ?*const EvalContext) Error!Reader {
        const control = self.control orelse return error.Expired;
        try control.validateContext(context);
        try charge(context orelse control.context(), 1, 0);
        return control.acquireReader();
    }

    pub fn handle(self: *const Region, context: ?*const EvalContext, id: NodeId) Error!Handle {
        const control = self.control orelse return error.Expired;
        const active_context = context orelse control.context();
        try control.validateContext(context);
        try charge(active_context, 1, 0);
        if (control.state.load(.acquire) != control_open) return error.Expired;
        if (!control.retain()) return error.Expired;
        errdefer control.release();
        if (control.state.load(.acquire) != control_open) return error.Expired;
        var reader = try control.acquireReader();
        defer reader.deinit();
        const node = try checkedNodeInStorage(reader.storage, id);
        std.debug.assert(node.id == id);
        return .{ .control = control, .node_id = id, .active = true };
    }

    pub fn rewrite(
        self: *Region,
        context: ?*const EvalContext,
        input: *const Handle,
        options: RewriteOptions,
    ) Error!Handle {
        const control = try self.openControl();
        try control.validateContext(context);
        if (!input.active or input.control != control) return error.InvalidHandle;
        if (input.isExpired()) return error.Expired;
        const active_context = self.effectiveContext(context);
        try charge(active_context, 1, 1);
        var storage_reader = try control.acquireReader();
        defer storage_reader.deinit();

        var builder: RewriteBuilder = .{
            .region = self,
            .context = active_context,
            .max_new_nodes = options.limits.max_nodes,
        };
        var root_id = input.node_id;
        if (options.limits.max_passes == 0) return error.RewriteLimit;

        const traversal_limits: Limits = .{
            .max_nodes = @min(options.limits.max_nodes, self.controlLimits().max_nodes),
            .max_edges = @min(options.limits.max_edges, self.controlLimits().max_edges),
            .max_names = self.controlLimits().max_names,
            .max_labels = self.controlLimits().max_labels,
            .max_name_bytes = self.controlLimits().max_name_bytes,
            .max_shape_dimensions = self.controlLimits().max_shape_dimensions,
            .max_depth = self.controlLimits().max_depth,
        };

        var pass: usize = 0;
        while (pass < options.limits.max_passes) : (pass += 1) {
            try charge(active_context, 1, 0);
            const previous_root = root_id;
            if (options.custom) |custom| {
                root_id = try resolveCustomChain(
                    active_context,
                    &builder,
                    control,
                    root_id,
                    custom,
                    options.limits,
                );
            }

            const storage = storage_reader.storage;
            var order = try collectPostorder(
                self.allocator,
                storage,
                root_id,
                traversal_limits,
                active_context,
            );
            defer order.deinit(self.allocator);

            var memo: std.AutoHashMapUnmanaged(u32, NodeId) = .empty;
            defer memo.deinit(self.allocator);
            try memo.ensureTotalCapacity(
                self.allocator,
                std.math.cast(u32, order.items.len) orelse return error.LimitExceeded,
            );

            for (order.items) |source_id| {
                if (options.custom == null or source_id != root_id) {
                    if (options.custom) |custom| {
                        const replacement = try resolveCustomChain(
                            active_context,
                            &builder,
                            control,
                            source_id,
                            custom,
                            options.limits,
                        );
                        if (replacement != source_id) {
                            const replacement_result = memo.get(@intFromEnum(replacement)) orelse replacement;
                            memo.putAssumeCapacity(@intFromEnum(source_id), replacement_result);
                            continue;
                        }
                    }
                }

                const source_node = try checkedNodeInStorage(storage, source_id);
                const rewritten = try rewriteNode(
                    self,
                    active_context,
                    storage,
                    source_node,
                    &memo,
                    &builder,
                    options,
                );
                memo.putAssumeCapacity(@intFromEnum(source_id), rewritten);
            }
            root_id = memo.get(@intFromEnum(root_id)) orelse return error.InvalidNode;
            if (root_id == previous_root) break;
        }
        return self.handle(active_context, root_id);
    }

    fn controlLimits(self: *const Region) Limits {
        return (self.control orelse return .{}).limits;
    }

    fn effectiveContext(self: *const Region, context: ?*const EvalContext) ?*const EvalContext {
        if (context) |active| return active;
        const control = self.control orelse return null;
        return control.context();
    }

    fn openControl(self: *const Region) Error!*Control {
        const control = self.control orelse return error.Expired;
        if (control.state.load(.acquire) != control_open) return error.Closed;
        if (control.storage.load(.acquire) == null) return error.Expired;
        return control;
    }

    fn internOwned(
        self: *Region,
        context: ?*const EvalContext,
        storage: *Storage,
        spec: NodeSpec,
    ) Error!NodeId {
        const hash = hashNodeSpec(storage, spec);
        const edge_count = specEdgeCount(spec);
        const label_count = specLabelCount(spec);
        const shape_count = specShapeCount(spec);
        const name_count = specNameCount(spec);
        const name_bytes = specNameBytes(spec);
        try reserveStorage(
            storage,
            self.allocator,
            context,
            1,
            edge_count,
            label_count,
            name_count,
            name_bytes,
            shape_count,
            storage.hash_heads.get(hash) == null,
        );

        const id = try NodeId.fromIndex(storage.nodes.items.len);
        const kind = buildNodeKind(storage, spec);
        storage.nodes.appendAssumeCapacity(.{
            .id = id,
            .kind = kind,
            .origin = specOrigin(spec),
            .hash = hash,
            .hash_next = storage.hash_heads.get(hash) orelse .invalid,
        });
        if (storage.hash_heads.getPtr(hash)) |head| {
            head.* = id;
        } else {
            storage.hash_heads.putAssumeCapacity(hash, id);
        }
        return id;
    }
};

fn charge(context: ?*const EvalContext, work: u64, nodes: u64) Error!void {
    if (context) |active| {
        try active.check();
        try active.charge(.{ .work = work, .nodes = nodes }, .transform);
    }
}

const AccountingAllocator = struct {
    base: Allocator,
    context: ?*const EvalContext,
    budget_failed: bool = false,

    const Reservation = struct {
        budget: *EvalContext.Budget,
        credit: ?*EvalContext.Reservation,
        credit_bytes: u64,
        credit_objects: u64,
        bytes: u64,
        objects: u64,

        fn cancel(self: Reservation) void {
            self.budget.cancelAllocation(
                self.bytes - self.credit_bytes,
                self.objects - self.credit_objects,
            );
            if (self.credit) |credit| {
                credit.bytes += self.credit_bytes;
                credit.objects += self.credit_objects;
            }
        }
    };

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn init(base: Allocator, context: ?*const EvalContext) AccountingAllocator {
        return .{ .base = base, .context = context };
    }

    fn allocator(self: *AccountingAllocator) Allocator {
        const context = self.context orelse return self.base;
        if (context.budget() == null) return self.base;
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn activate(self: *AccountingAllocator) ?EvalContext.Scope {
        const context = self.context orelse return null;
        return (@constCast(context)).activate();
    }

    fn isContextAllocator(self: *const AccountingAllocator) bool {
        const context = self.context orelse return false;
        return self.base.ptr == context.scratch.ptr and self.base.vtable == context.scratch.vtable;
    }

    fn needsManualAccounting(self: *AccountingAllocator) bool {
        if (self.activate()) |scope| {
            defer scope.deinit();
            return !self.isContextAllocator() and !Store.allocatorAccountsCurrentContext(self.base);
        }
        return !self.isContextAllocator() and !Store.allocatorAccountsCurrentContext(self.base);
    }

    fn markBudgetFailure(self: *AccountingAllocator) void {
        if (self.context) |context| {
            if (context.budget()) |budget| {
                if (budget.isExhausted()) self.budget_failed = true;
            }
        }
    }

    fn reserve(self: *AccountingAllocator, bytes: usize, objects: u64) ?Reservation {
        const context = self.context orelse return null;
        const budget = context.budget() orelse return null;
        const bytes_u64 = std.math.cast(u64, bytes) orelse return null;
        const credit = context.reservation;
        const credit_bytes = if (credit) |value| @min(bytes_u64, value.bytes) else 0;
        const credit_objects = if (credit) |value| @min(objects, value.objects) else 0;
        context.chargeAllocation(bytes_u64, objects, .transform) catch {
            self.budget_failed = true;
            return null;
        };
        return .{
            .budget = budget,
            .credit = credit,
            .credit_bytes = credit_bytes,
            .credit_objects = credit_objects,
            .bytes = bytes_u64,
            .objects = objects,
        };
    }

    fn rawAlloc(
        self: *AccountingAllocator,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        if (self.activate()) |scope| {
            defer scope.deinit();
            const result = self.base.rawAlloc(len, alignment, return_address);
            if (result == null) self.markBudgetFailure();
            return result;
        }
        const result = self.base.rawAlloc(len, alignment, return_address);
        if (result == null) self.markBudgetFailure();
        return result;
    }

    fn rawResize(
        self: *AccountingAllocator,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        if (self.activate()) |scope| {
            defer scope.deinit();
            const result = self.base.rawResize(memory, alignment, new_len, return_address);
            if (!result) self.markBudgetFailure();
            return result;
        }
        const result = self.base.rawResize(memory, alignment, new_len, return_address);
        if (!result) self.markBudgetFailure();
        return result;
    }

    fn rawRemap(
        self: *AccountingAllocator,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        if (self.activate()) |scope| {
            defer scope.deinit();
            const result = self.base.rawRemap(memory, alignment, new_len, return_address);
            if (result == null) self.markBudgetFailure();
            return result;
        }
        const result = self.base.rawRemap(memory, alignment, new_len, return_address);
        if (result == null) self.markBudgetFailure();
        return result;
    }

    fn alloc(
        raw: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *AccountingAllocator = @ptrCast(@alignCast(raw));
        var reservation: ?Reservation = null;
        if (self.needsManualAccounting()) {
            reservation = self.reserve(len, 1) orelse return null;
        }
        return self.rawAlloc(len, alignment, return_address) orelse {
            if (reservation) |claim| claim.cancel();
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
        const self: *AccountingAllocator = @ptrCast(@alignCast(raw));
        const growth = new_len -| memory.len;
        var reservation: ?Reservation = null;
        if (growth > 0 and self.needsManualAccounting()) {
            reservation = self.reserve(growth, 0) orelse return false;
        }
        if (self.rawResize(memory, alignment, new_len, return_address)) return true;
        if (reservation) |claim| claim.cancel();
        return false;
    }

    fn remap(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *AccountingAllocator = @ptrCast(@alignCast(raw));
        var reservation: ?Reservation = null;
        if (self.needsManualAccounting()) {
            reservation = self.reserve(new_len, 1) orelse return null;
        }
        return self.rawRemap(memory, alignment, new_len, return_address) orelse {
            if (reservation) |claim| claim.cancel();
            return null;
        };
    }

    fn free(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *AccountingAllocator = @ptrCast(@alignCast(raw));
        self.base.rawFree(memory, alignment, return_address);
    }
};

fn mapAllocationError(accounting: *const AccountingAllocator, err: Error) Error {
    if (err == error.OutOfMemory and accounting.budget_failed) return error.Exhausted;
    return err;
}

fn ensureUnusedCapacity(
    allocator: Allocator,
    context: ?*const EvalContext,
    list: anytype,
    additional: usize,
) Error!void {
    var accounting = AccountingAllocator.init(allocator, context);
    try ensureCapacity(&accounting, list, additional);
}

fn ensureCapacity(
    accounting: *AccountingAllocator,
    list: anytype,
    additional: usize,
) Error!void {
    list.ensureUnusedCapacity(accounting.allocator(), additional) catch |err| {
        return mapAllocationError(accounting, err);
    };
}

fn allocateFreeLocal(control: *Control) Error!u32 {
    var old = control.next_free_local.load(.acquire);
    while (old != 0 and old != std.math.maxInt(u32)) {
        if (control.next_free_local.cmpxchgWeak(old, old + 1, .acq_rel, .acquire) == null) {
            return old;
        }
        old = control.next_free_local.load(.acquire);
    }
    return error.LimitExceeded;
}
fn specOrigin(spec: NodeSpec) Origin {
    return switch (spec) {
        .scalar => |value| value.origin,
        .static_atom => |value| value.origin,
        .free_variable => |value| value.origin,
        .primitive_call => |value| value.origin,
        .conditional => |value| value.origin,
        .opaque_call => |value| value.origin,
        .list => |value| value.origin,
        .map => |value| value.origin,
        .tensor => |value| value.origin,
        .record => |value| value.origin,
    };
}

fn specEdgeCount(spec: NodeSpec) usize {
    return switch (spec) {
        .scalar, .static_atom, .free_variable => 0,
        .primitive_call => |value| value.arguments.len,
        .conditional => 3,
        .opaque_call => |value| value.arguments.len,
        .list => |value| value.elements.len,
        .map => |value| value.values.len,
        .tensor => |value| value.elements.len,
        .record => |value| value.fields.len,
    };
}

fn specLabelCount(spec: NodeSpec) usize {
    return switch (spec) {
        .map => |value| value.labels.len,
        .record => |value| value.field_labels.len,
        else => 0,
    };
}

fn specShapeCount(spec: NodeSpec) usize {
    return switch (spec) {
        .tensor => |value| value.shape.len,
        else => 0,
    };
}

fn specNameCount(spec: NodeSpec) usize {
    return switch (spec) {
        .static_atom, .free_variable, .opaque_call => 1,
        .map => |value| value.labels.len,
        .record => |value| (std.math.add(usize, value.field_labels.len, 1) catch std.math.maxInt(usize)),
        else => 0,
    };
}

fn specNameBytes(spec: NodeSpec) usize {
    var total: usize = 0;
    switch (spec) {
        .static_atom => |value| total = value.bytes.len,
        .free_variable => |value| total = value.name.len,
        .opaque_call => |value| total = value.display_label.len,
        .map => |value| {
            for (value.labels) |label| {
                total = std.math.add(usize, total, label.len) catch std.math.maxInt(usize);
            }
        },
        .record => |value| {
            total = value.type_label.len;
            for (value.field_labels) |label| {
                total = std.math.add(usize, total, label.len) catch std.math.maxInt(usize);
            }
        },
        else => {},
    }
    return total;
}

fn reserveStorage(
    storage: *Storage,
    allocator: Allocator,
    context: ?*const EvalContext,
    node_count: usize,
    edge_count: usize,
    label_count: usize,
    name_count: usize,
    name_bytes: usize,
    shape_count: usize,
    new_hash: bool,
) Error!void {
    if (node_count > storage.limits.max_nodes -| storage.nodes.items.len) return error.LimitExceeded;
    if (edge_count > storage.limits.max_edges -| storage.edges.items.len) return error.LimitExceeded;
    if (label_count > storage.limits.max_labels -| storage.labels.items.len) return error.LimitExceeded;
    if (name_count > storage.limits.max_names -| storage.name_refs.items.len) return error.LimitExceeded;
    if (name_bytes > storage.limits.max_name_bytes -| storage.names.items.len) return error.LimitExceeded;
    if (shape_count > storage.limits.max_shape_dimensions -| storage.shapes.items.len) return error.LimitExceeded;

    try ensureUnusedCapacity(allocator, context, &storage.nodes, node_count);
    try ensureUnusedCapacity(allocator, context, &storage.edges, edge_count);
    try ensureUnusedCapacity(allocator, context, &storage.labels, label_count);
    try ensureUnusedCapacity(allocator, context, &storage.name_refs, name_count);
    try ensureUnusedCapacity(allocator, context, &storage.names, name_bytes);
    try ensureUnusedCapacity(allocator, context, &storage.shapes, shape_count);
    if (new_hash) {
        var accounting = AccountingAllocator.init(allocator, context);
        const have = std.math.cast(u32, storage.hash_heads.count()) orelse return error.LimitExceeded;
        const want = std.math.add(u32, have, 1) catch return error.LimitExceeded;
        storage.hash_heads.ensureTotalCapacity(accounting.allocator(), want) catch |err| {
            return mapAllocationError(&accounting, err);
        };
    }
}

fn validateNodeSpec(storage: *const Storage, spec: NodeSpec, limits: Limits) Error!void {
    if (specNameBytes(spec) > limits.max_name_bytes) return error.LimitExceeded;
    switch (spec) {
        .scalar, .static_atom => {},
        .free_variable => |value| {
            if (!value.identity.isValid()) return error.InvalidIdentity;
        },
        .primitive_call => |value| {
            if (!value.identity.primitive.isValid()) return error.InvalidIdentity;
            try validateChildren(storage, value.arguments, limits.max_edges);
        },
        .conditional => |value| {
            try validateChildren(
                storage,
                &.{ value.predicate, value.then_branch, value.else_branch },
                limits.max_edges,
            );
        },
        .opaque_call => |value| {
            if (!value.identity.isValid()) return error.InvalidIdentity;
            try validateChildren(storage, value.arguments, limits.max_edges);
        },
        .list => |value| try validateChildren(storage, value.elements, limits.max_edges),
        .map => |value| {
            if (value.labels.len != value.values.len) return error.InvalidShape;
            if (value.labels.len > limits.max_labels) return error.LimitExceeded;
            try validateChildren(storage, value.values, limits.max_edges);
        },
        .tensor => |value| {
            if (value.shape.len > limits.max_shape_dimensions) return error.LimitExceeded;
            try validateChildren(storage, value.elements, limits.max_edges);
            const element_count = tensorElementCount(value.shape) orelse return error.InvalidShape;
            if (element_count != value.elements.len) return error.InvalidShape;
        },
        .record => |value| {
            if (value.field_labels.len != value.fields.len) return error.InvalidShape;
            if (value.field_labels.len > limits.max_labels) return error.LimitExceeded;
            try validateChildren(storage, value.fields, limits.max_edges);
        },
    }
}

fn validateChildren(storage: *const Storage, children: []const NodeId, max_edges: usize) Error!void {
    if (children.len > max_edges) return error.LimitExceeded;
    for (children) |child| {
        if (!child.isValid()) return error.InvalidNode;
        if (child.index() >= storage.nodes.items.len) return error.InvalidNode;
    }
}

fn tensorElementCount(shape: []const u32) ?usize {
    var total: usize = 1;
    for (shape) |dimension| {
        const product = @mulWithOverflow(total, @as(usize, dimension));
        if (product[1] != 0) return null;
        total = product[0];
    }
    return total;
}

fn buildNodeKind(storage: *Storage, spec: NodeSpec) NodeKind {
    return switch (spec) {
        .scalar => |value| .{ .scalar = .{ .value = value.value, .domain = value.domain } },
        .static_atom => |value| .{ .static_atom = .{
            .kind = value.kind,
            .name = appendNameAssume(storage, value.bytes),
        } },
        .free_variable => |value| .{ .free_variable = .{
            .identity = value.identity,
            .name = appendNameAssume(storage, value.name),
            .domain = value.domain,
            .assumptions = value.assumptions,
        } },
        .primitive_call => |value| .{ .primitive_call = .{
            .identity = value.identity,
            .arguments = appendEdgesAssume(storage, value.arguments),
            .domain = value.domain,
        } },
        .conditional => |value| .{ .conditional = .{
            .predicate = value.predicate,
            .then_branch = value.then_branch,
            .else_branch = value.else_branch,
            .arguments = appendEdgesAssume(storage, &.{ value.predicate, value.then_branch, value.else_branch }),
            .domain = value.domain,
        } },
        .opaque_call => |value| .{ .opaque_call = .{
            .identity = value.identity,
            .display_label = appendNameAssume(storage, value.display_label),
            .arguments = appendEdgesAssume(storage, value.arguments),
            .domain = value.domain,
            .effects = value.effects,
            .linearity = value.linearity,
        } },
        .list => |value| .{ .list = .{
            .elements = appendEdgesAssume(storage, value.elements),
            .domain = value.domain,
        } },
        .map => |value| .{ .map = .{
            .labels = appendLabelsAssume(storage, value.labels),
            .values = appendEdgesAssume(storage, value.values),
            .domain = value.domain,
        } },
        .tensor => |value| .{ .tensor = .{
            .dtype = value.dtype,
            .shape = appendShapeAssume(storage, value.shape),
            .elements = appendEdgesAssume(storage, value.elements),
            .domain = value.domain,
        } },
        .record => |value| .{ .record = .{
            .type_label = appendNameAssume(storage, value.type_label),
            .fields = appendLabelsAssume(storage, value.field_labels),
            .values = appendEdgesAssume(storage, value.fields),
            .domain = value.domain,
        } },
    };
}

fn appendNameAssume(storage: *Storage, bytes: []const u8) NameId {
    const start = storage.names.items.len;
    const id: NameId = @enumFromInt(storage.name_refs.items.len);
    storage.names.appendSliceAssumeCapacity(bytes);
    storage.name_refs.appendAssumeCapacity(.{
        .start = @intCast(start),
        .len = @intCast(bytes.len),
    });
    return id;
}

fn appendEdgesAssume(storage: *Storage, children: []const NodeId) Range {
    const range: Range = .{
        .start = @intCast(storage.edges.items.len),
        .len = @intCast(children.len),
    };
    storage.edges.appendSliceAssumeCapacity(children);
    return range;
}

fn appendLabelsAssume(storage: *Storage, labels: []const []const u8) LabelRange {
    const range: LabelRange = .{
        .start = @intCast(storage.labels.items.len),
        .len = @intCast(labels.len),
    };
    for (labels) |label| storage.labels.appendAssumeCapacity(appendNameAssume(storage, label));
    return range;
}

fn appendShapeAssume(storage: *Storage, shape: []const u32) ShapeRange {
    const range: ShapeRange = .{
        .start = @intCast(storage.shapes.items.len),
        .len = @intCast(shape.len),
    };
    storage.shapes.appendSliceAssumeCapacity(shape);
    return range;
}

fn findMatchingNode(storage: *const Storage, hash: u64, spec: NodeSpec) ?NodeId {
    var candidate = storage.hash_heads.get(hash) orelse return null;
    var steps: usize = 0;
    while (candidate != .invalid and steps < storage.nodes.items.len) : (steps += 1) {
        const node = checkedNodeInStorage(storage, candidate) catch return null;
        if (node.hash == hash and nodeMatchesSpec(storage, node, spec)) return candidate;
        candidate = node.hash_next;
    }
    return null;
}

fn validateSpecLimits(spec: NodeSpec, limits: Limits) Error!void {
    if (specEdgeCount(spec) > limits.max_edges) return error.LimitExceeded;
    if (specLabelCount(spec) > limits.max_labels) return error.LimitExceeded;
    if (specNameCount(spec) > limits.max_names) return error.LimitExceeded;
    if (specShapeCount(spec) > limits.max_shape_dimensions) return error.LimitExceeded;
    if (specNameBytes(spec) > limits.max_name_bytes) return error.LimitExceeded;
    switch (spec) {
        .map => |value| if (value.labels.len != value.values.len) return error.InvalidShape,
        .record => |value| if (value.field_labels.len != value.fields.len) return error.InvalidShape,
        .tensor => |value| {
            const count = tensorElementCount(value.shape) orelse return error.InvalidShape;
            if (count != value.elements.len) return error.InvalidShape;
        },
        else => {},
    }
}

fn nodeMatchesSpec(storage: *const Storage, node: Node, spec: NodeSpec) bool {
    if (!std.meta.eql(node.origin, specOrigin(spec))) return false;
    return switch (spec) {
        .scalar => |value| switch (node.kind) {
            .scalar => |candidate| candidate.domain == value.domain and candidate.value.eql(value.value),
            else => false,
        },
        .static_atom => |value| switch (node.kind) {
            .static_atom => |candidate| candidate.kind == value.kind and
                nameEqual(storage, candidate.name, value.bytes),
            else => false,
        },
        .free_variable => |value| switch (node.kind) {
            .free_variable => |candidate| candidate.domain == value.domain and
                candidate.assumptions == value.assumptions and candidate.identity.eql(value.identity),
            else => false,
        },
        .primitive_call => |value| switch (node.kind) {
            .primitive_call => |candidate| candidate.domain == value.domain and
                candidate.identity.eql(value.identity) and edgesEqual(storage, candidate.arguments, value.arguments),
            else => false,
        },
        .conditional => |value| switch (node.kind) {
            .conditional => |candidate| candidate.domain == value.domain and
                candidate.predicate == value.predicate and
                candidate.then_branch == value.then_branch and
                candidate.else_branch == value.else_branch,
            else => false,
        },
        .opaque_call => |value| switch (node.kind) {
            .opaque_call => |candidate| candidate.domain == value.domain and
                candidate.identity.id == value.identity.id and
                candidate.identity.revision == value.identity.revision and
                candidate.effects == value.effects and candidate.linearity == value.linearity and
                edgesEqual(storage, candidate.arguments, value.arguments),
            else => false,
        },
        .list => |value| switch (node.kind) {
            .list => |candidate| candidate.domain == value.domain and
                edgesEqual(storage, candidate.elements, value.elements),
            else => false,
        },
        .map => |value| switch (node.kind) {
            .map => |candidate| candidate.domain == value.domain and
                labelsEqual(storage, candidate.labels, value.labels) and
                edgesEqual(storage, candidate.values, value.values),
            else => false,
        },
        .tensor => |value| switch (node.kind) {
            .tensor => |candidate| candidate.domain == value.domain and candidate.dtype == value.dtype and
                shapeEqual(storage, candidate.shape, value.shape) and
                edgesEqual(storage, candidate.elements, value.elements),
            else => false,
        },
        .record => |value| switch (node.kind) {
            .record => |candidate| candidate.domain == value.domain and
                nameEqual(storage, candidate.type_label, value.type_label) and
                labelsEqual(storage, candidate.fields, value.field_labels) and
                edgesEqual(storage, candidate.values, value.fields),
            else => false,
        },
    };
}

fn edgesEqual(storage: *const Storage, range: Range, values: []const NodeId) bool {
    const slice = edgesSlice(storage, range) catch return false;
    return std.mem.eql(NodeId, slice, values);
}

fn labelsEqual(storage: *const Storage, range: LabelRange, values: []const []const u8) bool {
    if (range.len != values.len) return false;
    const first: usize = range.start;
    const last = range.end();
    if (last > storage.labels.items.len) return false;
    for (storage.labels.items[first..last], values) |label_id, value| {
        if (!nameEqual(storage, label_id, value)) return false;
    }
    return true;
}

fn shapeEqual(storage: *const Storage, range: ShapeRange, values: []const u32) bool {
    const slice = shapeSlice(storage, range) catch return false;
    return std.mem.eql(u32, slice, values);
}

fn nameEqual(storage: *const Storage, id: NameId, value: []const u8) bool {
    const existing = nameBytes(storage, id) catch return false;
    return std.mem.eql(u8, existing, value);
}

fn hashNodeSpec(storage: *const Storage, spec: NodeSpec) u64 {
    var hasher = hasher_type.init();
    hashU8(&hasher, @intFromEnum(std.meta.activeTag(spec)));
    hashOrigin(&hasher, specOrigin(spec));
    switch (spec) {
        .scalar => |value| {
            hashU8(&hasher, @intFromEnum(value.domain));
            hashScalar(&hasher, value.value);
        },
        .static_atom => |value| {
            hashU8(&hasher, @intFromEnum(value.kind));
            hashBytes(&hasher, value.bytes);
        },
        .free_variable => |value| {
            hashU64(&hasher, @intFromEnum(value.identity.region));
            hashU32(&hasher, value.identity.local);
            hashU8(&hasher, @intFromEnum(value.domain));
            hashU8(&hasher, @intFromEnum(value.assumptions));
        },
        .primitive_call => |value| {
            hashPrimitive(&hasher, value.identity);
            hashU8(&hasher, @intFromEnum(value.domain));
            hashNodeIds(&hasher, value.arguments);
        },
        .conditional => |value| {
            hashU8(&hasher, @intFromEnum(value.domain));
            hashU32(&hasher, @intFromEnum(value.predicate));
            hashU32(&hasher, @intFromEnum(value.then_branch));
            hashU32(&hasher, @intFromEnum(value.else_branch));
        },
        .opaque_call => |value| {
            hashU64(&hasher, value.identity.id);
            hashU64(&hasher, value.identity.revision);
            hashU8(&hasher, @intFromEnum(value.domain));
            hashU8(&hasher, @intFromEnum(value.effects));
            hashU8(&hasher, @intFromEnum(value.linearity));
            hashNodeIds(&hasher, value.arguments);
        },
        .list => |value| {
            hashU8(&hasher, @intFromEnum(value.domain));
            hashNodeIds(&hasher, value.elements);
        },
        .map => |value| {
            hashU8(&hasher, @intFromEnum(value.domain));
            hashLabels(&hasher, value.labels);
            hashNodeIds(&hasher, value.values);
        },
        .tensor => |value| {
            hashU8(&hasher, @intFromEnum(value.dtype));
            hashU8(&hasher, @intFromEnum(value.domain));
            hashU32s(&hasher, value.shape);
            hashNodeIds(&hasher, value.elements);
        },
        .record => |value| {
            hashU8(&hasher, @intFromEnum(value.domain));
            hashBytes(&hasher, value.type_label);
            hashLabels(&hasher, value.field_labels);
            hashNodeIds(&hasher, value.fields);
        },
    }
    _ = storage;
    return hasher.final();
}

fn hashPrimitive(hasher: *hasher_type, identity: PrimitiveIdentity) void {
    hashU32(hasher, identity.primitive.index());
    hashU64(hasher, identity.registry_revision);
    hashU64(hasher, identity.implementation_revision);
    hashU64(hasher, identity.rule_revision);
}

fn hashScalar(hasher: *hasher_type, value: Scalar) void {
    hashU8(hasher, @intFromEnum(std.meta.activeTag(value)));
    switch (value) {
        .f64_bits => |bits| hashU64(hasher, bits),
        .f32_bits => |bits| hashU32(hasher, bits),
        .signed => |number| hashU64(hasher, @bitCast(number)),
        .unsigned => |number| hashU64(hasher, number),
        .boolean => |boolean| hashU8(hasher, @intFromBool(boolean)),
    }
}

fn hashNodeIds(hasher: *hasher_type, values: []const NodeId) void {
    hashU64(hasher, @intCast(values.len));
    for (values) |value| hashU32(hasher, @intFromEnum(value));
}

fn hashU32s(hasher: *hasher_type, values: []const u32) void {
    hashU64(hasher, @intCast(values.len));
    for (values) |value| hashU32(hasher, value);
}

fn hashLabels(hasher: *hasher_type, values: []const []const u8) void {
    hashU64(hasher, @intCast(values.len));
    for (values) |value| {
        hashU64(hasher, @intCast(value.len));
        hashBytes(hasher, value);
    }
}

fn hashOrigin(hasher: *hasher_type, origin: Origin) void {
    hashU8(hasher, @intFromEnum(std.meta.activeTag(origin)));
    switch (origin) {
        .none => {},
        .source => |source| {
            hashU64(hasher, source.unit);
            hashU32(hasher, source.node);
        },
        .generated => |generated| hashU64(hasher, generated.identity),
    }
}

fn hashBytes(hasher: *hasher_type, bytes: []const u8) void {
    hashU64(hasher, @intCast(bytes.len));
    hasher.update(bytes);
}

fn hashU8(hasher: *hasher_type, value: u8) void {
    hasher.update(&.{value});
}

fn hashU32(hasher: *hasher_type, value: u32) void {
    var bytes = value;
    hasher.update(std.mem.asBytes(&bytes));
}

fn hashU64(hasher: *hasher_type, value: u64) void {
    var bytes = value;
    hasher.update(std.mem.asBytes(&bytes));
}

fn checkedNodeInStorage(storage: *const Storage, id: NodeId) Error!Node {
    if (!id.isValid()) return error.InvalidNode;
    const index = id.index();
    if (index >= storage.nodes.items.len) return error.InvalidNode;
    const node = storage.nodes.items[index];
    if (node.id != id) return error.InvalidNode;
    return node;
}

fn nameBytes(storage: *const Storage, id: NameId) Error![]const u8 {
    if (id == .invalid) return error.InvalidNode;
    const index = id.index();
    if (index >= storage.name_refs.items.len) return error.InvalidNode;
    const reference = storage.name_refs.items[index];
    const end = std.math.add(usize, @as(usize, reference.start), @as(usize, reference.len)) catch
        return error.InvalidNode;
    if (end > storage.names.items.len) return error.InvalidNode;
    return storage.names.items[@as(usize, reference.start)..end];
}

fn labelId(storage: *const Storage, labels: LabelRange, index: usize) Error!NameId {
    if (index >= labels.len) return error.InvalidNode;
    const position = std.math.add(usize, @as(usize, labels.start), index) catch return error.InvalidNode;
    if (position >= storage.labels.items.len) return error.InvalidNode;
    return storage.labels.items[position];
}

fn edgesSlice(storage: *const Storage, range: Range) Error![]const NodeId {
    const end = range.end();
    if (end > storage.edges.items.len) return error.InvalidNode;
    return storage.edges.items[@as(usize, range.start)..end];
}

fn shapeSlice(storage: *const Storage, range: ShapeRange) Error![]const u32 {
    const end = range.end();
    if (end > storage.shapes.items.len) return error.InvalidShape;
    return storage.shapes.items[@as(usize, range.start)..end];
}

fn nodeOperandsRange(node: Node) ?Range {
    return switch (node.kind) {
        .primitive_call => |value| value.arguments,
        .conditional => |value| value.arguments,
        .opaque_call => |value| value.arguments,
        .list => |value| value.elements,
        .map => |value| value.values,
        .tensor => |value| value.elements,
        .record => |value| value.values,
        .scalar, .static_atom, .free_variable => null,
    };
}

fn nodeChildrenRange(node: Node) Range {
    return nodeOperandsRange(node) orelse .{};
}

fn copyNodeSpec(allocator: Allocator, spec: NodeSpec) Error!NodeSpec {
    return switch (spec) {
        .scalar => |value| .{ .scalar = value },
        .static_atom => |value| .{ .static_atom = .{
            .kind = value.kind,
            .bytes = try allocator.dupe(u8, value.bytes),
            .origin = value.origin,
        } },
        .free_variable => |value| .{ .free_variable = .{
            .identity = value.identity,
            .name = try allocator.dupe(u8, value.name),
            .domain = value.domain,
            .assumptions = value.assumptions,
            .origin = value.origin,
        } },
        .primitive_call => |value| .{ .primitive_call = .{
            .identity = value.identity,
            .arguments = try allocator.dupe(NodeId, value.arguments),
            .domain = value.domain,
            .origin = value.origin,
        } },
        .conditional => |value| .{ .conditional = .{
            .predicate = value.predicate,
            .then_branch = value.then_branch,
            .else_branch = value.else_branch,
            .domain = value.domain,
            .origin = value.origin,
        } },
        .opaque_call => |value| .{ .opaque_call = .{
            .identity = value.identity,
            .display_label = try allocator.dupe(u8, value.display_label),
            .arguments = try allocator.dupe(NodeId, value.arguments),
            .domain = value.domain,
            .effects = value.effects,
            .linearity = value.linearity,
            .origin = value.origin,
        } },
        .list => |value| .{ .list = .{
            .elements = try allocator.dupe(NodeId, value.elements),
            .domain = value.domain,
            .origin = value.origin,
        } },
        .map => |value| .{ .map = .{
            .labels = try copyLabels(allocator, value.labels),
            .values = try allocator.dupe(NodeId, value.values),
            .domain = value.domain,
            .origin = value.origin,
        } },
        .tensor => |value| .{ .tensor = .{
            .dtype = value.dtype,
            .shape = try allocator.dupe(u32, value.shape),
            .elements = try allocator.dupe(NodeId, value.elements),
            .domain = value.domain,
            .origin = value.origin,
        } },
        .record => |value| .{ .record = .{
            .type_label = try allocator.dupe(u8, value.type_label),
            .field_labels = try copyLabels(allocator, value.field_labels),
            .fields = try allocator.dupe(NodeId, value.fields),
            .domain = value.domain,
            .origin = value.origin,
        } },
    };
}

fn copyLabels(allocator: Allocator, labels: []const []const u8) Error![]const []const u8 {
    const result = try allocator.alloc([]const u8, labels.len);
    for (labels, 0..) |label, index| result[index] = try allocator.dupe(u8, label);
    return result;
}

fn collectPostorder(
    allocator: Allocator,
    storage: *const Storage,
    root: NodeId,
    limits: Limits,
    context: ?*const EvalContext,
) Error!std.ArrayList(NodeId) {
    _ = try checkedNodeInStorage(storage, root);
    if (limits.max_nodes == 0) return error.LimitExceeded;

    var order: std.ArrayList(NodeId) = .empty;
    errdefer order.deinit(allocator);
    var frames: std.ArrayList(VisitFrame) = .empty;
    defer frames.deinit(allocator);
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(allocator);

    try seen.put(allocator, @intFromEnum(root), {});
    try frames.append(allocator, .{ .id = root, .next_child = 0 });
    var edge_count: usize = 0;

    while (frames.items.len != 0) {
        try charge(context, 1, 1);
        if (frames.items.len > limits.max_depth) return error.LimitExceeded;
        const frame_index = frames.items.len - 1;
        const frame = &frames.items[frame_index];
        const node = try checkedNodeInStorage(storage, frame.id);
        const children = nodeChildrenRange(node);
        if (frame.next_child < children.len) {
            const child_position = std.math.add(usize, @as(usize, children.start), frame.next_child) catch
                return error.InvalidNode;
            if (child_position >= storage.edges.items.len) return error.InvalidNode;
            if (edge_count >= limits.max_edges) return error.LimitExceeded;
            edge_count += 1;
            const child = storage.edges.items[child_position];
            frame.next_child += 1;
            if (seen.contains(@intFromEnum(child))) continue;
            if (seen.count() >= limits.max_nodes) return error.LimitExceeded;
            try seen.put(allocator, @intFromEnum(child), {});
            try frames.append(allocator, .{ .id = child, .next_child = 0 });
        } else {
            const completed_id = frame.id;
            _ = frames.pop();
            try order.append(allocator, completed_id);
        }
    }
    return order;
}

const VisitFrame = struct {
    id: NodeId,
    next_child: u32,
};

fn snapshotFromStorage(
    allocator: Allocator,
    source: *const Storage,
    root: NodeId,
    context: ?*const EvalContext,
    limits: Limits,
) Error!Snapshot {
    var accounting = AccountingAllocator.init(allocator, context);
    const work_allocator = accounting.allocator();
    var order = collectPostorder(work_allocator, source, root, limits, context) catch |err| {
        if (err == error.OutOfMemory) return mapAllocationError(&accounting, err);
        return err;
    };
    defer order.deinit(work_allocator);

    var result: Snapshot = .{
        .allocator = allocator,
        .storage = Storage.init(allocator, limits),
        .root_id = .invalid,
    };
    errdefer result.deinit();

    var mapping: std.AutoHashMapUnmanaged(u32, NodeId) = .empty;
    defer mapping.deinit(work_allocator);
    mapping.ensureTotalCapacity(work_allocator, std.math.cast(u32, order.items.len) orelse
        return error.InvalidNode) catch |err| {
        return mapAllocationError(&accounting, err);
    };
    try ensureCapacity(&accounting, &result.storage.nodes, order.items.len);

    for (order.items, 0..) |source_id, index| {
        const local_id = try NodeId.fromIndex(index);
        mapping.putAssumeCapacity(@intFromEnum(source_id), local_id);
    }

    for (order.items, 0..) |source_id, index| {
        try charge(context, 1, 1);
        const source_node = try checkedNodeInStorage(source, source_id);
        const local_id: NodeId = @enumFromInt(@as(u32, @intCast(index)));
        const copied = try cloneNodeToStorage(
            source,
            source_node,
            local_id,
            &mapping,
            &result.storage,
            &accounting,
        );
        result.storage.nodes.appendAssumeCapacity(copied);
    }
    result.root_id = mapping.get(@intFromEnum(root)) orelse return error.InvalidNode;
    return result;
}
fn cloneNodeToStorage(
    source: *const Storage,
    source_node: Node,
    local_id: NodeId,
    mapping: *const std.AutoHashMapUnmanaged(u32, NodeId),
    destination: *Storage,
    accounting: *AccountingAllocator,
) Error!Node {
    const kind: NodeKind = switch (source_node.kind) {
        .scalar => |value| .{ .scalar = value },
        .static_atom => |value| .{ .static_atom = .{
            .kind = value.kind,
            .name = try copyNameToStorage(source, value.name, destination, accounting),
        } },
        .free_variable => |value| .{ .free_variable = .{
            .identity = value.identity,
            .name = try copyNameToStorage(source, value.name, destination, accounting),
            .domain = value.domain,
            .assumptions = value.assumptions,
        } },
        .primitive_call => |value| .{ .primitive_call = .{
            .identity = value.identity,
            .arguments = try cloneEdges(source, value.arguments, mapping, destination, accounting),
            .domain = value.domain,
        } },
        .conditional => |value| .{ .conditional = .{
            .predicate = mapping.get(@intFromEnum(value.predicate)) orelse return error.InvalidNode,
            .then_branch = mapping.get(@intFromEnum(value.then_branch)) orelse return error.InvalidNode,
            .else_branch = mapping.get(@intFromEnum(value.else_branch)) orelse return error.InvalidNode,
            .arguments = try cloneEdges(source, value.arguments, mapping, destination, accounting),
            .domain = value.domain,
        } },
        .opaque_call => |value| .{ .opaque_call = .{
            .identity = value.identity,
            .display_label = try copyNameToStorage(source, value.display_label, destination, accounting),
            .arguments = try cloneEdges(source, value.arguments, mapping, destination, accounting),
            .domain = value.domain,
            .effects = value.effects,
            .linearity = value.linearity,
        } },
        .list => |value| .{ .list = .{
            .elements = try cloneEdges(source, value.elements, mapping, destination, accounting),
            .domain = value.domain,
        } },
        .map => |value| .{ .map = .{
            .labels = try cloneLabels(source, value.labels, destination, accounting),
            .values = try cloneEdges(source, value.values, mapping, destination, accounting),
            .domain = value.domain,
        } },
        .tensor => |value| .{ .tensor = .{
            .dtype = value.dtype,
            .shape = try cloneShape(source, value.shape, destination, accounting),
            .elements = try cloneEdges(source, value.elements, mapping, destination, accounting),
            .domain = value.domain,
        } },
        .record => |value| .{ .record = .{
            .type_label = try copyNameToStorage(source, value.type_label, destination, accounting),
            .fields = try cloneLabels(source, value.fields, destination, accounting),
            .values = try cloneEdges(source, value.values, mapping, destination, accounting),
            .domain = value.domain,
        } },
    };
    return .{ .id = local_id, .kind = kind, .origin = source_node.origin };
}

fn copyNameToStorage(
    source: *const Storage,
    id: NameId,
    destination: *Storage,
    accounting: *AccountingAllocator,
) Error!NameId {
    return appendName(destination, try nameBytes(source, id), accounting);
}

fn appendName(
    storage: *Storage,
    bytes: []const u8,
    accounting: *AccountingAllocator,
) Error!NameId {
    if (storage.name_refs.items.len >= storage.limits.max_names) return error.LimitExceeded;
    if (bytes.len > storage.limits.max_name_bytes -| storage.names.items.len) return error.LimitExceeded;
    try ensureCapacity(accounting, &storage.names, bytes.len);
    try ensureCapacity(accounting, &storage.name_refs, 1);
    return appendNameAssume(storage, bytes);
}

fn cloneEdges(
    source: *const Storage,
    range: Range,
    mapping: *const std.AutoHashMapUnmanaged(u32, NodeId),
    destination: *Storage,
    accounting: *AccountingAllocator,
) Error!Range {
    const values = try edgesSlice(source, range);
    if (values.len > destination.limits.max_edges -| destination.edges.items.len) return error.LimitExceeded;
    try ensureCapacity(accounting, &destination.edges, values.len);
    const result: Range = .{ .start = @intCast(destination.edges.items.len), .len = @intCast(values.len) };
    for (values) |value| {
        destination.edges.appendAssumeCapacity(
            mapping.get(@intFromEnum(value)) orelse return error.InvalidNode,
        );
    }
    return result;
}

fn cloneLabels(
    source: *const Storage,
    range: LabelRange,
    destination: *Storage,
    accounting: *AccountingAllocator,
) Error!LabelRange {
    const first: usize = range.start;
    const last = range.end();
    if (last > source.labels.items.len) return error.InvalidNode;
    if (range.len > destination.limits.max_labels -| destination.labels.items.len) return error.LimitExceeded;
    const label_count: usize = range.len;
    try ensureCapacity(accounting, &destination.labels, label_count);
    const result: LabelRange = .{ .start = @intCast(destination.labels.items.len), .len = range.len };
    for (source.labels.items[first..last]) |label| {
        destination.labels.appendAssumeCapacity(try copyNameToStorage(source, label, destination, accounting));
    }
    return result;
}

fn cloneShape(
    source: *const Storage,
    range: ShapeRange,
    destination: *Storage,
    accounting: *AccountingAllocator,
) Error!ShapeRange {
    const values = try shapeSlice(source, range);
    if (values.len > destination.limits.max_shape_dimensions -| destination.shapes.items.len) {
        return error.LimitExceeded;
    }
    try ensureCapacity(accounting, &destination.shapes, values.len);
    const result: ShapeRange = .{ .start = @intCast(destination.shapes.items.len), .len = @intCast(values.len) };
    destination.shapes.appendSliceAssumeCapacity(values);
    return result;
}

fn resolveCustomChain(
    context: ?*const EvalContext,
    builder: *RewriteBuilder,
    control: *Control,
    start: NodeId,
    custom: CustomRule,
    limits: RewriteLimits,
) Error!NodeId {
    var current = start;
    var steps: usize = 0;
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(builder.region.allocator);

    while (true) {
        if (steps >= limits.max_rule_steps) return error.RewriteLimit;
        steps += 1;
        try charge(context, 1, 0);
        if (seen.contains(@intFromEnum(current))) return error.RewriteCycle;
        try seen.put(builder.region.allocator, @intFromEnum(current), {});
        const node_value = try checkedNodeInStorage(
            control.storage.load(.acquire) orelse return error.Expired,
            current,
        );
        const replacement = try custom.apply(
            context,
            builder,
            .{ .id = current, .node = node_value },
            custom.context,
        );
        const next = replacement orelse return current;
        if (!next.isValid()) return error.InvalidNode;
        _ = try checkedNodeInStorage(control.storage.load(.acquire) orelse return error.Expired, next);
        if (next == current) return current;
        current = next;
    }
}

const RewriteOperation = enum {
    add,
    multiply,
    divide,
    zero_like,
    one_like,
    coerce_tangent,
    realize_tangent,
};

const RewriteMatch = struct {
    operation: RewriteOperation,
    operand_start: usize,
    dispatch: bool,
};

fn rewriteOperationArity(operation: RewriteOperation) usize {
    return switch (operation) {
        .add, .multiply, .divide, .coerce_tangent, .realize_tangent => 2,
        .zero_like, .one_like => 1,
    };
}

fn scalarI64(storage: *const Storage, id: NodeId) ?i64 {
    const node = checkedNodeInStorage(storage, id) catch return null;
    return switch (node.kind) {
        .scalar => |scalar| switch (scalar.value) {
            .signed => |value| if (scalar.domain == .signed_integer) value else null,
            else => null,
        },
        else => null,
    };
}

fn dispatchOperation(dispatch: DispatchRewriteOperators, tag: i64) ?RewriteOperation {
    if (tag == dispatch.add) return .add;
    if (tag == dispatch.multiply) return .multiply;
    if (tag == dispatch.divide) return .divide;
    if (tag == dispatch.zero_like) return .zero_like;
    if (tag == dispatch.one_like) return .one_like;
    if (tag == dispatch.coerce_tangent) return .coerce_tangent;
    if (tag == dispatch.realize_tangent) return .realize_tangent;
    return null;
}

fn matchRewriteOperator(
    storage: *const Storage,
    call: PrimitiveCallNode,
    arguments: []const NodeId,
    operators: RewriteOperators,
) ?RewriteMatch {
    if (operators.dispatch) |dispatch| {
        if (call.identity.eql(dispatch.primitive) and arguments.len > 0) {
            if (scalarI64(storage, arguments[0])) |tag| {
                if (dispatchOperation(dispatch, tag)) |operation| {
                    if (arguments.len == rewriteOperationArity(operation) + 1) {
                        return .{
                            .operation = operation,
                            .operand_start = 1,
                            .dispatch = true,
                        };
                    }
                }
            }
        }
    }
    if (operators.multiply) |multiply| {
        if (call.identity.eql(multiply) and arguments.len == 2) {
            return .{ .operation = .multiply, .operand_start = 0, .dispatch = false };
        }
    }
    if (operators.divide) |divide| {
        if (call.identity.eql(divide) and arguments.len == 2) {
            return .{ .operation = .divide, .operand_start = 0, .dispatch = false };
        }
    }
    return null;
}

fn nodeDomain(storage: *const Storage, id: NodeId) ?Domain {
    const node = checkedNodeInStorage(storage, id) catch return null;
    return switch (node.kind) {
        .scalar => |scalar| scalar.domain,
        .free_variable => |variable| variable.domain,
        .primitive_call => |call| call.domain,
        .conditional => |conditional| conditional.domain,
        .opaque_call => |call| call.domain,
        .list => |list| list.domain,
        .map => |map| map.domain,
        .tensor => |tensor| tensor.domain,
        .record => |record| record.domain,
        .static_atom => null,
    };
}

fn identityOperand(
    storage: *const Storage,
    operand: NodeId,
    result_domain: Domain,
) ?NodeId {
    const operand_domain = nodeDomain(storage, operand) orelse return null;
    if (operand_domain != result_domain) return null;
    return operand;
}

fn scalarZero(storage: *const Storage, id: NodeId) bool {
    const node = checkedNodeInStorage(storage, id) catch return false;
    return switch (node.kind) {
        .scalar => |scalar| switch (scalar.domain) {
            .real, .signed_integer, .unsigned_integer => scalar.value.isZero(),
            else => false,
        },
        else => false,
    };
}

fn staticNil(storage: *const Storage, id: NodeId) bool {
    const node = checkedNodeInStorage(storage, id) catch return false;
    return switch (node.kind) {
        .static_atom => |atom| atom.kind == .nil,
        else => false,
    };
}

fn scalarOne(storage: *const Storage, id: NodeId) bool {
    const node = checkedNodeInStorage(storage, id) catch return false;
    return switch (node.kind) {
        .scalar => |scalar| switch (scalar.domain) {
            .real, .signed_integer, .unsigned_integer => switch (scalar.value) {
                .f64_bits => |bits| @as(f64, @bitCast(bits)) == 1.0,
                .f32_bits => |bits| @as(f32, @bitCast(bits)) == 1.0,
                .signed => |value| value == 1,
                .unsigned => |value| value == 1,
                .boolean => false,
            },
            else => false,
        },
        else => false,
    };
}

fn internDomainScalar(
    builder: *RewriteBuilder,
    source_node: Node,
    domain: Domain,
    one: bool,
) Error!NodeId {
    return builder.intern(.{ .scalar = .{
        .value = if (one) Scalar.oneFor(domain) else Scalar.zeroFor(domain),
        .domain = domain,
        .origin = source_node.origin,
    } });
}

fn internScalarInDomain(
    builder: *RewriteBuilder,
    source_node: Node,
    value: Scalar,
    domain: Domain,
) Error!NodeId {
    return builder.intern(.{ .scalar = .{
        .value = value,
        .domain = domain,
        .origin = source_node.origin,
    } });
}

fn duplicateAdditionMultiply(
    builder: *RewriteBuilder,
    source_node: Node,
    call: PrimitiveCallNode,
    match: RewriteMatch,
    operators: RewriteOperators,
    operand: NodeId,
) Error!?NodeId {
    if (!match.dispatch) return null;
    const dispatch = operators.dispatch orelse return null;
    const factor = try internScalarInDomain(
        builder,
        source_node,
        Scalar.fromF64(2.0),
        call.domain,
    );
    const tag = try builder.intern(.{ .scalar = .{
        .value = .{ .signed = dispatch.multiply },
        .domain = .signed_integer,
        .origin = source_node.origin,
    } });
    const arguments = [_]NodeId{ tag, factor, operand };
    const value = try builder.intern(.{ .primitive_call = .{
        .identity = dispatch.primitive,
        .arguments = &arguments,
        .domain = call.domain,
        .origin = source_node.origin,
    } });
    return value;
}

fn rewriteMatchedOperator(
    builder: *RewriteBuilder,
    context: ?*const EvalContext,
    storage: *const Storage,
    source_node: Node,
    call: PrimitiveCallNode,
    original_operands: []const NodeId,
    rewritten_operands: []const NodeId,
    match: RewriteMatch,
    options: RewriteOptions,
) Error!?NodeId {
    if (call.domain != .real) return null;
    switch (match.operation) {
        .multiply => {
            if (options.policy != .formal_real) return null;
            const left_zero = scalarZero(storage, rewritten_operands[0]);
            const right_zero = scalarZero(storage, rewritten_operands[1]);
            if (left_zero or right_zero) {
                if (left_zero) {
                    if (identityOperand(storage, rewritten_operands[0], call.domain)) |operand| {
                        return operand;
                    }
                }
                if (right_zero) {
                    if (identityOperand(storage, rewritten_operands[1], call.domain)) |operand| {
                        return operand;
                    }
                }
                return try internDomainScalar(builder, source_node, call.domain, false);
            }
            if (scalarOne(storage, rewritten_operands[0])) {
                return identityOperand(storage, rewritten_operands[1], call.domain);
            }
            if (scalarOne(storage, rewritten_operands[1])) {
                return identityOperand(storage, rewritten_operands[0], call.domain);
            }
        },
        .add => {
            if (options.policy != .formal_real) return null;
            if (scalarZero(storage, rewritten_operands[0])) {
                return identityOperand(storage, rewritten_operands[1], call.domain);
            }
            if (scalarZero(storage, rewritten_operands[1])) {
                return identityOperand(storage, rewritten_operands[0], call.domain);
            }
            if (rewritten_operands[0] == rewritten_operands[1]) {
                return duplicateAdditionMultiply(
                    builder,
                    source_node,
                    call,
                    match,
                    options.operators,
                    rewritten_operands[0],
                );
            }
        },
        .divide => {
            if (options.policy == .formal_real) {
                if (scalarOne(storage, rewritten_operands[1])) {
                    if (identityOperand(storage, rewritten_operands[0], call.domain)) |operand| {
                        return operand;
                    }
                    if (scalarZero(storage, rewritten_operands[0])) {
                        return try internDomainScalar(builder, source_node, call.domain, false);
                    }
                }
            }
            if (original_operands[0] != original_operands[1]) return null;
            if (rewritten_operands[0] != rewritten_operands[1]) return null;
            var facts = inferredFacts(storage, original_operands[0]);
            if (options.facts) |provider| {
                const queried = try provider.query(
                    context,
                    original_operands[0],
                    try checkedNodeInStorage(storage, original_operands[0]),
                    provider.context,
                );
                facts.finite = facts.finite or queried.finite;
                facts.nonzero = facts.nonzero or queried.nonzero;
                facts.positive = facts.positive or queried.positive;
            }
            const allowed = switch (options.policy) {
                .formal_real => facts.nonzero,
                .strict_ieee => facts.nonzero and facts.finite,
            };
            if (allowed) {
                return try internDomainScalar(builder, source_node, call.domain, true);
            }
        },
        .zero_like, .one_like => {
            if (options.policy != .formal_real) return null;
            const operand_domain = nodeDomain(storage, rewritten_operands[0]) orelse return null;
            if (operand_domain != call.domain) return null;
            return try internDomainScalar(
                builder,
                source_node,
                call.domain,
                match.operation == .one_like,
            );
        },
        .coerce_tangent, .realize_tangent => {
            if (options.policy != .formal_real) return null;
            const primal_domain = nodeDomain(storage, rewritten_operands[0]) orelse return null;
            if (primal_domain != call.domain) return null;
            if (match.operation == .realize_tangent and
                staticNil(storage, rewritten_operands[1]))
            {
                return try internDomainScalar(builder, source_node, call.domain, false);
            }
            const tangent_domain = nodeDomain(storage, rewritten_operands[1]) orelse return null;
            if (tangent_domain != call.domain) return null;
            return rewritten_operands[1];
        },
    }
    return null;
}

fn rewriteNode(
    region: *Region,
    context: ?*const EvalContext,
    storage: *const Storage,
    source_node: Node,
    memo: *const std.AutoHashMapUnmanaged(u32, NodeId),
    builder: *RewriteBuilder,
    options: RewriteOptions,
) Error!NodeId {
    switch (source_node.kind) {
        .scalar => return source_node.id,
        .static_atom => return source_node.id,
        .free_variable => return source_node.id,
        .primitive_call => |call| {
            var arguments: std.ArrayList(NodeId) = .empty;
            defer arguments.deinit(region.allocator);
            const original_arguments = try edgesSlice(storage, call.arguments);
            try arguments.ensureTotalCapacity(region.allocator, original_arguments.len);
            var changed = false;
            for (original_arguments) |argument| {
                const mapped = memo.get(@intFromEnum(argument)) orelse argument;
                arguments.appendAssumeCapacity(mapped);
                if (mapped != argument) changed = true;
            }

            if (matchRewriteOperator(storage, call, original_arguments, options.operators)) |match| {
                const original_operands = original_arguments[match.operand_start..];
                const rewritten_operands = arguments.items[match.operand_start..];
                if (try rewriteMatchedOperator(
                    builder,
                    context,
                    storage,
                    source_node,
                    call,
                    original_operands,
                    rewritten_operands,
                    match,
                    options,
                )) |replacement| {
                    return replacement;
                }
            }

            if (!changed) return source_node.id;
            return builder.intern(.{ .primitive_call = .{
                .identity = call.identity,
                .arguments = arguments.items,
                .domain = call.domain,
                .origin = source_node.origin,
            } });
        },
        .conditional => |conditional| {
            return rewriteStructuredNode(region, context, storage, source_node, conditional.arguments, memo);
        },
        .opaque_call => |call| {
            return rewriteStructuredNode(region, context, storage, source_node, call.arguments, memo);
        },
        .list => |list| {
            return rewriteStructuredNode(region, context, storage, source_node, list.elements, memo);
        },
        .map => |map| {
            return rewriteStructuredNode(region, context, storage, source_node, map.values, memo);
        },
        .tensor => |tensor| {
            return rewriteStructuredNode(region, context, storage, source_node, tensor.elements, memo);
        },
        .record => |record| {
            return rewriteStructuredNode(region, context, storage, source_node, record.values, memo);
        },
    }
}

fn rewriteStructuredNode(
    region: *Region,
    context: ?*const EvalContext,
    storage: *const Storage,
    source_node: Node,
    range: Range,
    memo: *const std.AutoHashMapUnmanaged(u32, NodeId),
) Error!NodeId {
    const original = try edgesSlice(storage, range);
    var mapped: std.ArrayList(NodeId) = .empty;
    defer mapped.deinit(region.allocator);
    try mapped.ensureTotalCapacity(region.allocator, original.len);
    var changed = false;
    for (original) |child| {
        const next = memo.get(@intFromEnum(child)) orelse child;
        mapped.appendAssumeCapacity(next);
        if (next != child) changed = true;
    }
    if (!changed) return source_node.id;

    var scratch_arena = std.heap.ArenaAllocator.init(region.allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();
    return switch (source_node.kind) {
        .conditional => |conditional| blk: {
            if (mapped.items.len != 3) return error.InvalidNode;
            break :blk region.intern(context, .{ .conditional = .{
                .predicate = mapped.items[0],
                .then_branch = mapped.items[1],
                .else_branch = mapped.items[2],
                .domain = conditional.domain,
                .origin = source_node.origin,
            } });
        },
        .opaque_call => |call| blk: {
            const display_label = try scratch.dupe(u8, try nameBytes(storage, call.display_label));
            break :blk region.intern(context, .{ .opaque_call = .{
                .identity = call.identity,
                .display_label = display_label,
                .arguments = mapped.items,
                .domain = call.domain,
                .effects = call.effects,
                .linearity = call.linearity,
                .origin = source_node.origin,
            } });
        },
        .list => |list| region.intern(context, .{ .list = .{
            .elements = mapped.items,
            .domain = list.domain,
            .origin = source_node.origin,
        } }),
        .map => |map| blk: {
            const labels = try labelsAsText(scratch, storage, map.labels);
            break :blk region.intern(context, .{ .map = .{
                .labels = labels,
                .values = mapped.items,
                .domain = map.domain,
                .origin = source_node.origin,
            } });
        },
        .tensor => |tensor| blk: {
            const shape = try scratch.dupe(u32, try shapeSlice(storage, tensor.shape));
            break :blk region.intern(context, .{ .tensor = .{
                .dtype = tensor.dtype,
                .shape = shape,
                .elements = mapped.items,
                .domain = tensor.domain,
                .origin = source_node.origin,
            } });
        },
        .record => |record| blk: {
            const type_label = try scratch.dupe(u8, try nameBytes(storage, record.type_label));
            const labels = try labelsAsText(scratch, storage, record.fields);
            break :blk region.intern(context, .{ .record = .{
                .type_label = type_label,
                .field_labels = labels,
                .fields = mapped.items,
                .domain = record.domain,
                .origin = source_node.origin,
            } });
        },
        else => error.InvalidNode,
    };
}

fn labelsAsText(allocator: Allocator, storage: *const Storage, range: LabelRange) Error![]const []const u8 {
    const first: usize = range.start;
    const last = range.end();
    if (last > storage.labels.items.len) return error.InvalidNode;
    const label_count: usize = range.len;
    const result = try allocator.alloc([]const u8, label_count);
    for (storage.labels.items[first..last], 0..) |label, index| {
        result[index] = try allocator.dupe(u8, try nameBytes(storage, label));
    }
    return result;
}

fn inferredFacts(storage: *const Storage, id: NodeId) Facts {
    const node = checkedNodeInStorage(storage, id) catch return .{};
    return switch (node.kind) {
        .scalar => |scalar| .{ .finite = scalar.value.isFinite(), .nonzero = !scalar.value.isZero() },
        .free_variable => |variable| switch (variable.assumptions) {
            .none => .{},
            .finite => .{ .finite = true },
            .nonzero => .{ .nonzero = true },
            .finite_nonzero => .{ .finite = true, .nonzero = true },
        },
        else => .{},
    };
}
const TestRuntime = @import("Runtime.zig");

const ExprTestContext = struct {
    ledger: EvalContext.Budget,
    lease: EvalContext.Budget.Lease,
    account: EvalContext.Budget.AccountAllocator,
    output_bytes: [64]u8,
    writer: std.Io.Writer,
    context: EvalContext,

    fn init(
        self: *ExprTestContext,
        runtime: *TestRuntime,
        bytes: u64,
        objects: u64,
    ) !void {
        const limits: EvalContext.Budget.Limits = .{
            .work = 100_000_000,
            .bytes = bytes,
            .objects = objects,
            .nodes = 100_000_000,
        };
        self.ledger = EvalContext.Budget.init(runtime.io, 8_001, limits);
        self.lease = try EvalContext.Budget.Lease.root(&self.ledger, limits.work);
        self.account = EvalContext.Budget.AccountAllocator.init(
            std.testing.allocator,
            &self.lease,
            .transform,
        );
        self.writer = .fixed(&self.output_bytes);
        self.context = try EvalContext.limited(
            runtime,
            runtime.intrinsics.registryVersion(),
            &self.account,
            .{ .writer = &self.writer, .bounded_memory = true },
            .{},
        );
    }
};

const TestAllocationProbe = struct {
    base: Allocator,
    bytes: u64 = 0,
    objects: u64 = 0,

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *TestAllocationProbe) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(
        raw: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *TestAllocationProbe = @ptrCast(@alignCast(raw));
        const result = self.base.rawAlloc(len, alignment, return_address) orelse return null;
        self.bytes += @intCast(len);
        self.objects += 1;
        return result;
    }

    fn resize(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *TestAllocationProbe = @ptrCast(@alignCast(raw));
        if (!self.base.rawResize(memory, alignment, new_len, return_address)) return false;
        self.bytes += @intCast(new_len -| memory.len);
        return true;
    }

    fn remap(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *TestAllocationProbe = @ptrCast(@alignCast(raw));
        const result = self.base.rawRemap(
            memory,
            alignment,
            new_len,
            return_address,
        ) orelse return null;
        self.bytes += @intCast(new_len);
        self.objects += 1;
        return result;
    }

    fn free(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *TestAllocationProbe = @ptrCast(@alignCast(raw));
        self.base.rawFree(memory, alignment, return_address);
    }
};

const TestOwnerResolver = struct {
    fallback: *EvalContext,
    calls: usize = 0,

    fn resolve(raw: *const anyopaque) *EvalContext {
        const self: *TestOwnerResolver = @ptrCast(@alignCast(@constCast(raw)));
        self.calls += 1;
        return self.fallback;
    }
};

fn testSnapshotRoot(region: *Region) Error!NodeId {
    const left = try region.intern(null, .{ .scalar = .{
        .value = .{ .signed = 1 },
        .domain = .signed_integer,
    } });
    const right = try region.intern(null, .{ .scalar = .{
        .value = .{ .signed = 2 },
        .domain = .signed_integer,
    } });
    const tensor = try region.intern(null, .{ .tensor = .{
        .dtype = .i64,
        .shape = &.{2},
        .elements = &.{ left, right },
    } });
    return region.intern(null, .{ .record = .{
        .type_label = "Pair",
        .field_labels = &.{"values"},
        .fields = &.{tensor},
    } });
}

fn testPrimitive(index: u32, rule_revision: u64) PrimitiveIdentity {
    return .{
        .primitive = PrimitiveId.fromIndex(index),
        .registry_revision = 7,
        .implementation_revision = 3,
        .rule_revision = rule_revision,
    };
}

fn testDispatchOperators(primitive: PrimitiveIdentity) DispatchRewriteOperators {
    return .{
        .primitive = primitive,
        .add = 0,
        .multiply = 2,
        .divide = 3,
        .zero_like = 24,
        .one_like = 25,
        .coerce_tangent = 26,
        .realize_tangent = 27,
    };
}

fn testDispatchCall(
    region: *Region,
    operators: DispatchRewriteOperators,
    tag: i64,
    operands: []const NodeId,
    domain: Domain,
) Error!NodeId {
    if (operands.len > 2) return error.InvalidNode;
    const tag_node = try region.intern(null, .{ .scalar = .{
        .value = .{ .signed = tag },
        .domain = .signed_integer,
    } });
    var arguments: [3]NodeId = undefined;
    arguments[0] = tag_node;
    @memcpy(arguments[1 .. operands.len + 1], operands);
    return region.intern(null, .{ .primitive_call = .{
        .identity = operators.primitive,
        .arguments = arguments[0 .. operands.len + 1],
        .domain = domain,
    } });
}

test "account-backed region initialization charges each allocation once" {
    const runtime = try TestRuntime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    var metered: ExprTestContext = undefined;
    try metered.init(runtime, 1024 * 1024, 1024);

    const before = metered.ledger.snapshot();
    var region = try Region.init(
        runtime.gpa,
        &metered.context,
        .{ .identity = @enumFromInt(61) },
    );
    defer region.deinit();
    const after = metered.ledger.snapshot();

    try std.testing.expectEqual(
        @as(u64, @intCast(@sizeOf(Storage) + @sizeOf(Control))),
        after.consumed.bytes - before.consumed.bytes,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        after.consumed.objects - before.consumed.objects,
    );
}

test "repeated intern does not consume allocation budget" {
    const runtime = try TestRuntime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    var metered: ExprTestContext = undefined;
    try metered.init(runtime, 1024 * 1024, 1024);
    var region = try Region.init(
        runtime.gpa,
        &metered.context,
        .{ .identity = @enumFromInt(62) },
    );
    defer region.deinit();

    const first = try region.intern(&metered.context, .{ .static_atom = .{
        .kind = .symbol,
        .bytes = "shared",
    } });
    const after_first = metered.ledger.snapshot();
    const second = try region.intern(&metered.context, .{ .static_atom = .{
        .kind = .symbol,
        .bytes = "shared",
    } });
    const after_second = metered.ledger.snapshot();

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(after_first.consumed.bytes, after_second.consumed.bytes);
    try std.testing.expectEqual(after_first.consumed.objects, after_second.consumed.objects);
}

test "unaccounted region allocator charges actual capacity allocations" {
    const runtime = try TestRuntime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    var metered: ExprTestContext = undefined;
    try metered.init(runtime, 16 * 1024 * 1024, 16 * 1024);
    var probe: TestAllocationProbe = .{ .base = std.testing.allocator };
    const before = metered.ledger.snapshot();
    var region = try Region.init(
        probe.allocator(),
        &metered.context,
        .{ .identity = @enumFromInt(63) },
    );
    defer region.deinit();

    const successor = testPrimitive(18, 1);
    var root = try region.intern(&metered.context, .{ .scalar = .{
        .value = .{ .signed = 0 },
        .domain = .signed_integer,
    } });
    for (0..32) |_| {
        root = try region.intern(&metered.context, .{ .primitive_call = .{
            .identity = successor,
            .arguments = &.{root},
            .domain = .signed_integer,
        } });
    }
    try std.testing.expect(root.isValid());

    const after = metered.ledger.snapshot();
    try std.testing.expectEqual(
        probe.bytes,
        after.consumed.bytes - before.consumed.bytes,
    );
    try std.testing.expectEqual(
        probe.objects,
        after.consumed.objects - before.consumed.objects,
    );
}

test "snapshot charges persistent and temporary allocations against limits" {
    var source_region = try Region.init(
        std.testing.allocator,
        null,
        .{ .identity = @enumFromInt(64) },
    );
    defer source_region.deinit();
    const root = try testSnapshotRoot(&source_region);
    var handle = try source_region.handle(null, root);
    defer handle.deinit();

    const runtime = try TestRuntime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    var measured: ExprTestContext = undefined;
    try measured.init(runtime, 16 * 1024 * 1024, 16 * 1024);
    var probe: TestAllocationProbe = .{ .base = std.testing.allocator };
    var snapshot = try handle.snapshot(
        probe.allocator(),
        &measured.context,
        .{},
    );
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 4), snapshot.nodeCount());
    const footprint = measured.ledger.snapshot().consumed;
    try std.testing.expect(footprint.bytes > 0);
    try std.testing.expect(footprint.objects > 0);
    try std.testing.expectEqual(probe.bytes, footprint.bytes);
    try std.testing.expectEqual(probe.objects, footprint.objects);

    var byte_limited: ExprTestContext = undefined;
    try byte_limited.init(runtime, footprint.bytes - 1, std.math.maxInt(u64));
    var byte_probe: TestAllocationProbe = .{ .base = std.testing.allocator };
    try std.testing.expectError(
        error.Exhausted,
        handle.snapshot(byte_probe.allocator(), &byte_limited.context, .{}),
    );
    try std.testing.expectEqual(
        EvalContext.Budget.Resource.bytes,
        byte_limited.ledger.report().?.resource,
    );

    var object_limited: ExprTestContext = undefined;
    try object_limited.init(runtime, std.math.maxInt(u64), footprint.objects - 1);
    var object_probe: TestAllocationProbe = .{ .base = std.testing.allocator };
    try std.testing.expectError(
        error.Exhausted,
        handle.snapshot(object_probe.allocator(), &object_limited.context, .{}),
    );
    try std.testing.expectEqual(
        EvalContext.Budget.Resource.objects,
        object_limited.ledger.report().?.resource,
    );
}

test "postorder traversal enforces edge limit independently of node limit" {
    var region = try Region.init(
        std.testing.allocator,
        null,
        .{ .identity = @enumFromInt(65) },
    );
    defer region.deinit();
    const left = try region.intern(null, .{ .scalar = .{
        .value = .{ .signed = 1 },
        .domain = .signed_integer,
    } });
    const right = try region.intern(null, .{ .scalar = .{
        .value = .{ .signed = 2 },
        .domain = .signed_integer,
    } });
    const root = try region.intern(null, .{ .list = .{
        .elements = &.{ left, right },
    } });
    var reader = try region.acquire(null);
    defer reader.deinit();

    try std.testing.expectError(
        error.LimitExceeded,
        collectPostorder(
            std.testing.allocator,
            reader.storage,
            root,
            .{ .max_nodes = 16, .max_edges = 1 },
            null,
        ),
    );
}

test "owned regions resolve immutable runtime identity only at initialization" {
    const runtime = try TestRuntime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    var metered: ExprTestContext = undefined;
    try metered.init(runtime, 1024 * 1024, 1024);
    var fallback = EvalContext.trusted(
        std.testing.allocator,
        runtime,
        runtime.intrinsics.registryVersion(),
        .{ .writer = &metered.writer },
    );
    var owner: TestOwnerResolver = .{ .fallback = &fallback };
    var region = try Region.initOwned(
        std.testing.allocator,
        &owner,
        &TestOwnerResolver.resolve,
        &metered.context,
        .{ .identity = @enumFromInt(66) },
    );
    defer region.deinit();

    const id = try region.intern(null, .{ .scalar = .{
        .value = .{ .signed = 1 },
        .domain = .signed_integer,
    } });
    _ = try region.checkedNode(id);
    try std.testing.expectEqual(@as(usize, 1), owner.calls);
}

test "owned region rejects a foreign runtime before allocation debit" {
    const owner_runtime = try TestRuntime.init(std.testing.allocator, std.testing.io);
    defer owner_runtime.deinit();
    const foreign_runtime = try TestRuntime.init(std.testing.allocator, std.testing.io);
    defer foreign_runtime.deinit();
    var foreign: ExprTestContext = undefined;
    try foreign.init(foreign_runtime, 1024 * 1024, 1024);
    var owner: TestOwnerResolver = .{ .fallback = owner_runtime.context() };
    const before = foreign.ledger.snapshot();

    try std.testing.expectError(
        error.Denied,
        Region.initOwned(
            std.testing.allocator,
            &owner,
            &TestOwnerResolver.resolve,
            &foreign.context,
            .{ .identity = @enumFromInt(67) },
        ),
    );
    const after = foreign.ledger.snapshot();
    try std.testing.expectEqual(before.consumed.bytes, after.consumed.bytes);
    try std.testing.expectEqual(before.consumed.objects, after.consumed.objects);
    var region = try Region.initOwned(
        std.testing.allocator,
        &owner,
        &TestOwnerResolver.resolve,
        owner_runtime.context(),
        .{ .identity = @enumFromInt(69) },
    );
    defer region.deinit();
    const foreign_scope = foreign.context.activate();
    defer foreign_scope.deinit();
    const active_before = foreign.ledger.snapshot();
    try std.testing.expectError(
        error.Denied,
        region.intern(null, .{ .scalar = .{
            .value = .{ .signed = 3 },
            .domain = .signed_integer,
        } }),
    );
    const active_after = foreign.ledger.snapshot();
    try std.testing.expectEqual(active_before.consumed.bytes, active_after.consumed.bytes);
    try std.testing.expectEqual(active_before.consumed.objects, active_after.consumed.objects);
}

test "standalone regions accept explicit contexts from different runtimes" {
    const first_runtime = try TestRuntime.init(std.testing.allocator, std.testing.io);
    defer first_runtime.deinit();
    const second_runtime = try TestRuntime.init(std.testing.allocator, std.testing.io);
    defer second_runtime.deinit();
    var region = try Region.init(
        std.testing.allocator,
        first_runtime.context(),
        .{ .identity = @enumFromInt(68) },
    );
    defer region.deinit();

    const id = try region.intern(second_runtime.context(), .{ .scalar = .{
        .value = .{ .signed = 9 },
        .domain = .signed_integer,
    } });
    try std.testing.expectEqual(
        @as(i64, 9),
        (try region.checkedNode(id)).kind.scalar.value.signed,
    );
}

test "same-spelled free variables remain distinct while labels remain static" {
    var region = try Region.init(std.testing.allocator, null, .{ .identity = @enumFromInt(41) });
    defer region.deinit();

    const first = try region.freshVariable(null, "x", .real, .none);
    const second = try region.freshVariable(null, "x", .real, .none);
    try std.testing.expect(first != second);

    const value = try region.intern(null, .{ .scalar = .{
        .value = Scalar.fromF64(2.0),
        .domain = .real,
    } });
    const record_a = try region.intern(null, .{ .record = .{
        .type_label = "Point",
        .field_labels = &.{"x"},
        .fields = &.{value},
    } });
    const record_b = try region.intern(null, .{ .record = .{
        .type_label = "Point",
        .field_labels = &.{"x"},
        .fields = &.{value},
    } });
    try std.testing.expectEqual(record_a, record_b);

    var reader = try region.acquire(null);
    defer reader.deinit();
    const first_node = try reader.node(first);
    const second_node = try reader.node(second);
    try std.testing.expectEqual(NodeTag.free_variable, std.meta.activeTag(first_node.kind));
    try std.testing.expectEqual(NodeTag.free_variable, std.meta.activeTag(second_node.kind));
    try std.testing.expect(first_node.kind.free_variable.identity.local !=
        second_node.kind.free_variable.identity.local);
    try std.testing.expectEqualStrings("x", try reader.name(first_node.kind.free_variable.name));
    try std.testing.expectEqualStrings("x", try reader.name(second_node.kind.free_variable.name));

    const record_node = try reader.node(record_a);
    try std.testing.expectEqual(NodeTag.record, std.meta.activeTag(record_node.kind));
    try std.testing.expectEqualStrings("Point", try reader.name(record_node.kind.record.type_label));
    try std.testing.expectEqualStrings("x", try reader.label(record_node.kind.record.fields, 0));
}

test "hash consing checks identities revisions origins and complete equality" {
    var region = try Region.init(std.testing.allocator, null, .{ .identity = @enumFromInt(42) });
    defer region.deinit();

    const x = try region.freshVariable(null, "x", .real, .none);
    const key = testPrimitive(2, 11);
    const shared_a = try region.intern(null, .{ .primitive_call = .{
        .identity = key,
        .arguments = &.{ x, x },
        .domain = .real,
    } });
    const shared_b = try region.intern(null, .{ .primitive_call = .{
        .identity = key,
        .arguments = &.{ x, x },
        .domain = .real,
    } });
    try std.testing.expectEqual(shared_a, shared_b);

    const revised = try region.intern(null, .{ .primitive_call = .{
        .identity = testPrimitive(2, 12),
        .arguments = &.{ x, x },
        .domain = .real,
    } });
    try std.testing.expect(shared_a != revised);

    const source_a: Origin = .{ .source = .{ .unit = 8, .node = 13 } };
    const source_b: Origin = .{ .source = .{ .unit = 8, .node = 14 } };
    const literal_a = try region.intern(null, .{ .scalar = .{
        .value = .{ .signed = 5 },
        .domain = .signed_integer,
        .origin = source_a,
    } });
    const literal_b = try region.intern(null, .{ .scalar = .{
        .value = .{ .signed = 5 },
        .domain = .signed_integer,
        .origin = source_b,
    } });
    try std.testing.expect(literal_a != literal_b);

    var reader = try region.acquire(null);
    defer reader.deinit();
    try std.testing.expectEqualDeep(source_a, (try reader.node(literal_a)).origin);
    try std.testing.expectEqualDeep(source_b, (try reader.node(literal_b)).origin);
}

test "region copies names labels shapes and opaque call metadata" {
    var region = try Region.init(std.testing.allocator, null, .{ .identity = @enumFromInt(43) });
    defer region.deinit();

    var variable_name = [_]u8{ 'a', 'l', 'p', 'h', 'a' };
    var opaque_name = [_]u8{ 'c', 'a', 'l', 'l' };
    var field_name = [_]u8{ 'v', 'a', 'l', 'u', 'e' };
    var shape = [_]u32{ 2, 1 };

    const variable = try region.freshVariable(null, &variable_name, .real, .none);
    const opaque_call = try region.intern(null, .{ .opaque_call = .{
        .identity = .{ .id = 91, .revision = 4 },
        .display_label = &opaque_name,
        .arguments = &.{variable},
        .domain = .real,
    } });
    const tensor = try region.intern(null, .{ .tensor = .{
        .dtype = .f64,
        .shape = &shape,
        .elements = &.{ variable, opaque_call },
    } });
    const record = try region.intern(null, .{ .record = .{
        .type_label = "Box",
        .field_labels = &.{&field_name},
        .fields = &.{tensor},
    } });

    @memset(&variable_name, 'x');
    @memset(&opaque_name, 'x');
    @memset(&field_name, 'x');
    shape = .{ 9, 9 };

    var handle = try region.handle(null, record);
    defer handle.deinit();
    var snapshot = try handle.snapshot(std.testing.allocator, null, .{});
    defer snapshot.deinit();

    const record_node = try snapshot.node(snapshot.root());
    try std.testing.expectEqualStrings("Box", try snapshot.name(record_node.kind.record.type_label));
    try std.testing.expectEqualStrings("value", try snapshot.label(record_node.kind.record.fields, 0));
    const tensor_id = (try snapshot.operands(record_node))[0];
    const tensor_node = try snapshot.node(tensor_id);
    try std.testing.expectEqual(DType.f64, tensor_node.kind.tensor.dtype);
    try std.testing.expectEqualSlices(u32, &.{ 2, 1 }, try snapshot.shape(tensor_node.kind.tensor.shape));
    const tensor_elements = try snapshot.operands(tensor_node);
    const variable_node = try snapshot.node(tensor_elements[0]);
    const opaque_node = try snapshot.node(tensor_elements[1]);
    try std.testing.expectEqualStrings("alpha", try snapshot.name(variable_node.kind.free_variable.name));
    try std.testing.expectEqualStrings("call", try snapshot.name(opaque_node.kind.opaque_call.display_label));
    try std.testing.expectEqual(EffectKnowledge.unknown, opaque_node.effectKnowledge());
    try std.testing.expectEqual(Linearity.unknown, opaque_node.linearity());
}

test "floating literals preserve NaN payloads and signed zero" {
    var region = try Region.init(std.testing.allocator, null, .{ .identity = @enumFromInt(44) });
    defer region.deinit();

    const nan_a_bits: u64 = 0x7ff8_0000_0000_0041;
    const nan_b_bits: u64 = 0x7ff8_0000_0000_0042;
    const nan_a = try region.intern(null, .{ .scalar = .{ .value = .{ .f64_bits = nan_a_bits }, .domain = .real } });
    const nan_a_shared = try region.intern(null, .{
        .scalar = .{
            .value = .{ .f64_bits = nan_a_bits },
            .domain = .real,
        },
    });
    const nan_b = try region.intern(null, .{ .scalar = .{ .value = .{ .f64_bits = nan_b_bits }, .domain = .real } });
    const positive_zero = try region.intern(null, .{ .scalar = .{ .value = Scalar.fromF64(0.0), .domain = .real } });
    const negative_zero = try region.intern(null, .{ .scalar = .{ .value = Scalar.fromF64(-0.0), .domain = .real } });

    try std.testing.expectEqual(nan_a, nan_a_shared);
    try std.testing.expect(nan_a != nan_b);
    try std.testing.expect(positive_zero != negative_zero);

    var reader = try region.acquire(null);
    defer reader.deinit();
    try std.testing.expectEqual(nan_a_bits, (try reader.node(nan_a)).kind.scalar.value.f64_bits);
    try std.testing.expectEqual(nan_b_bits, (try reader.node(nan_b)).kind.scalar.value.f64_bits);
    try std.testing.expectEqual(
        @as(u64, 0x8000_0000_0000_0000),
        (try reader.node(negative_zero)).kind.scalar.value.f64_bits,
    );
}

test "strict IEEE rewrites preserve zero NaN and unknown division" {
    var region = try Region.init(std.testing.allocator, null, .{ .identity = @enumFromInt(45) });
    defer region.deinit();

    const multiply = testPrimitive(3, 1);
    const divide = testPrimitive(4, 1);
    const zero = try region.intern(null, .{ .scalar = .{ .value = Scalar.fromF64(0.0), .domain = .real } });
    const nan = try region.intern(null, .{
        .scalar = .{
            .value = .{ .f64_bits = 0x7ff8_0000_0000_0061 },
            .domain = .real,
        },
    });
    const variable = try region.freshVariable(null, "x", .real, .none);
    const zero_times_nan = try region.intern(null, .{
        .primitive_call = .{
            .identity = multiply,
            .arguments = &.{ zero, nan },
            .domain = .real,
        },
    });
    const quotient = try region.intern(null, .{
        .primitive_call = .{
            .identity = divide,
            .arguments = &.{ variable, variable },
            .domain = .real,
        },
    });

    var product_handle = try region.handle(null, zero_times_nan);
    defer product_handle.deinit();
    var strict_product = try region.rewrite(
        null,
        &product_handle,
        .{
            .policy = .strict_ieee,
            .operators = .{ .multiply = multiply, .divide = divide },
        },
    );
    defer strict_product.deinit();
    try std.testing.expectEqual(zero_times_nan, strict_product.nodeId());

    var formal_product = try region.rewrite(
        null,
        &product_handle,
        .{
            .policy = .formal_real,
            .operators = .{ .multiply = multiply, .divide = divide },
        },
    );
    defer formal_product.deinit();
    try std.testing.expectEqual(zero, formal_product.nodeId());

    var quotient_handle = try region.handle(null, quotient);
    defer quotient_handle.deinit();
    var strict_quotient = try region.rewrite(
        null,
        &quotient_handle,
        .{
            .policy = .strict_ieee,
            .operators = .{ .multiply = multiply, .divide = divide },
        },
    );
    defer strict_quotient.deinit();
    try std.testing.expectEqual(quotient, strict_quotient.nodeId());
}
const NonzeroFact = struct {
    target: NodeId,

    fn query(_: ?*const EvalContext, node_id: NodeId, _: Node, raw: *const anyopaque) Error!Facts {
        const self: *const NonzeroFact = @ptrCast(@alignCast(raw));
        if (node_id == self.target) return .{ .finite = true, .nonzero = true };
        return .{};
    }
};

test "division rewrite requires explicit nonzero and finite facts" {
    var region = try Region.init(std.testing.allocator, null, .{ .identity = @enumFromInt(46) });
    defer region.deinit();

    const divide = testPrimitive(4, 1);
    const variable = try region.freshVariable(null, "x", .real, .none);
    const quotient = try region.intern(null, .{
        .primitive_call = .{
            .identity = divide,
            .arguments = &.{ variable, variable },
            .domain = .real,
        },
    });
    var quotient_handle = try region.handle(null, quotient);
    defer quotient_handle.deinit();

    const fact: NonzeroFact = .{ .target = variable };
    var rewritten = try region.rewrite(null, &quotient_handle, .{
        .policy = .strict_ieee,
        .operators = .{ .divide = divide },
        .facts = .{ .context = &fact, .query = &NonzeroFact.query },
    });
    defer rewritten.deinit();

    var reader = try rewritten.acquire(null);
    defer reader.deinit();
    const result = try reader.node(rewritten.nodeId());
    try std.testing.expectEqual(NodeTag.scalar, std.meta.activeTag(result.kind));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 1.0))), result.kind.scalar.value.f64_bits);
}

test "formal real constants preserve primitive call result domains" {
    var region = try Region.init(
        std.testing.allocator,
        null,
        .{ .identity = @enumFromInt(54) },
    );
    defer region.deinit();

    const multiply = testPrimitive(10, 1);
    const divide = testPrimitive(11, 1);
    const integer_zero = try region.intern(null, .{ .scalar = .{
        .value = .{ .signed = 0 },
        .domain = .signed_integer,
    } });
    const integer_one = try region.intern(null, .{ .scalar = .{
        .value = .{ .signed = 1 },
        .domain = .signed_integer,
    } });
    const variable = try region.freshVariable(null, "x", .real, .finite_nonzero);
    const product = try region.intern(null, .{ .primitive_call = .{
        .identity = multiply,
        .arguments = &.{ integer_zero, variable },
        .domain = .real,
    } });
    const zero_quotient = try region.intern(null, .{ .primitive_call = .{
        .identity = divide,
        .arguments = &.{ integer_zero, integer_one },
        .domain = .real,
    } });
    const self_quotient = try region.intern(null, .{ .primitive_call = .{
        .identity = divide,
        .arguments = &.{ integer_one, integer_one },
        .domain = .real,
    } });
    const unit_quotient = try region.intern(null, .{ .primitive_call = .{
        .identity = divide,
        .arguments = &.{ variable, integer_one },
        .domain = .real,
    } });

    {
        var reader = try region.acquire(null);
        defer reader.deinit();
        try std.testing.expectEqual(
            Domain.real,
            (try reader.node(product)).kind.primitive_call.domain,
        );
        try std.testing.expectEqual(
            Domain.real,
            (try reader.node(zero_quotient)).kind.primitive_call.domain,
        );
        try std.testing.expectEqual(
            Domain.real,
            (try reader.node(self_quotient)).kind.primitive_call.domain,
        );
    }

    const scalar_cases = [_]struct {
        root: NodeId,
        expected: Scalar,
    }{
        .{ .root = product, .expected = Scalar.fromF64(0.0) },
        .{ .root = zero_quotient, .expected = Scalar.fromF64(0.0) },
        .{ .root = self_quotient, .expected = Scalar.fromF64(1.0) },
    };
    for (scalar_cases) |case| {
        var handle = try region.handle(null, case.root);
        defer handle.deinit();
        var rewritten = try region.rewrite(null, &handle, .{
            .policy = .formal_real,
            .operators = .{ .multiply = multiply, .divide = divide },
        });
        defer rewritten.deinit();
        try std.testing.expect(rewritten.nodeId() != integer_zero);
        try std.testing.expect(rewritten.nodeId() != integer_one);

        var reader = try rewritten.acquire(null);
        defer reader.deinit();
        const result = try reader.node(rewritten.nodeId());
        try std.testing.expectEqual(NodeTag.scalar, std.meta.activeTag(result.kind));
        try std.testing.expectEqual(Domain.real, result.kind.scalar.domain);
        try std.testing.expect(result.kind.scalar.value.eql(case.expected));
    }

    var unit_handle = try region.handle(null, unit_quotient);
    defer unit_handle.deinit();
    var unit_result = try region.rewrite(null, &unit_handle, .{
        .policy = .formal_real,
        .operators = .{ .divide = divide },
    });
    defer unit_result.deinit();
    try std.testing.expectEqual(variable, unit_result.nodeId());
}

test "strict IEEE keeps formal dispatch identities observable" {
    var region = try Region.init(
        std.testing.allocator,
        null,
        .{ .identity = @enumFromInt(55) },
    );
    defer region.deinit();

    const dispatch = testDispatchOperators(testPrimitive(12, 1));
    const positive_zero = try region.intern(null, .{ .scalar = .{
        .value = Scalar.fromF64(0.0),
        .domain = .real,
    } });
    const negative_zero = try region.intern(null, .{ .scalar = .{
        .value = Scalar.fromF64(-0.0),
        .domain = .real,
    } });
    const nan = try region.intern(null, .{ .scalar = .{
        .value = .{ .f64_bits = 0x7ff8_0000_0000_0062 },
        .domain = .real,
    } });
    const nil = try region.intern(null, .{ .static_atom = .{
        .kind = .nil,
    } });
    const one = try region.intern(null, .{ .scalar = .{
        .value = Scalar.fromF64(1.0),
        .domain = .real,
    } });
    const infinity = try region.intern(null, .{ .scalar = .{
        .value = Scalar.fromF64(std.math.inf(f64)),
        .domain = .real,
    } });
    const unknown = try region.freshVariable(null, "u", .real, .none);
    const roots = [_]NodeId{
        try testDispatchCall(
            &region,
            dispatch,
            dispatch.add,
            &.{ negative_zero, positive_zero },
            .real,
        ),
        try testDispatchCall(
            &region,
            dispatch,
            dispatch.multiply,
            &.{ positive_zero, infinity },
            .real,
        ),
        try testDispatchCall(
            &region,
            dispatch,
            dispatch.multiply,
            &.{ positive_zero, nan },
            .real,
        ),
        try testDispatchCall(
            &region,
            dispatch,
            dispatch.divide,
            &.{ negative_zero, one },
            .real,
        ),
        try testDispatchCall(
            &region,
            dispatch,
            dispatch.divide,
            &.{ unknown, unknown },
            .real,
        ),
        try testDispatchCall(
            &region,
            dispatch,
            dispatch.realize_tangent,
            &.{ unknown, nil },
            .real,
        ),
        try testDispatchCall(
            &region,
            dispatch,
            dispatch.zero_like,
            &.{unknown},
            .real,
        ),
    };

    for (roots) |root| {
        var handle = try region.handle(null, root);
        defer handle.deinit();
        var rewritten = try region.rewrite(null, &handle, .{
            .policy = .strict_ieee,
            .operators = .{ .dispatch = dispatch },
        });
        defer rewritten.deinit();
        try std.testing.expectEqual(root, rewritten.nodeId());
    }
}

test "formal dispatch rewrites canonical square derivative and converges" {
    var region = try Region.init(
        std.testing.allocator,
        null,
        .{ .identity = @enumFromInt(56) },
    );
    defer region.deinit();

    const dispatch = testDispatchOperators(testPrimitive(13, 1));
    const variable = try region.freshVariable(null, "x", .real, .none);
    const one = try testDispatchCall(
        &region,
        dispatch,
        dispatch.one_like,
        &.{variable},
        .real,
    );
    const realized_one = try testDispatchCall(
        &region,
        dispatch,
        dispatch.realize_tangent,
        &.{ variable, one },
        .real,
    );
    const coerced_one = try testDispatchCall(
        &region,
        dispatch,
        dispatch.coerce_tangent,
        &.{ variable, realized_one },
        .real,
    );
    const first_product = try testDispatchCall(
        &region,
        dispatch,
        dispatch.multiply,
        &.{ coerced_one, variable },
        .real,
    );
    const second_product = try testDispatchCall(
        &region,
        dispatch,
        dispatch.multiply,
        &.{ variable, one },
        .real,
    );
    const sum = try testDispatchCall(
        &region,
        dispatch,
        dispatch.add,
        &.{ first_product, second_product },
        .real,
    );
    const derivative = try testDispatchCall(
        &region,
        dispatch,
        dispatch.realize_tangent,
        &.{ variable, sum },
        .real,
    );
    var handle = try region.handle(null, derivative);
    defer handle.deinit();
    var rewritten = try region.rewrite(null, &handle, .{
        .policy = .formal_real,
        .operators = .{ .dispatch = dispatch },
        .limits = .{
            .max_nodes = 32,
            .max_edges = 64,
            .max_rule_steps = 16,
            .max_passes = 2,
        },
    });
    defer rewritten.deinit();

    {
        var reader = try rewritten.acquire(null);
        defer reader.deinit();
        const result = try reader.node(rewritten.nodeId());
        try std.testing.expectEqual(NodeTag.primitive_call, std.meta.activeTag(result.kind));
        try std.testing.expect(result.kind.primitive_call.identity.eql(dispatch.primitive));
        try std.testing.expectEqual(Domain.real, result.kind.primitive_call.domain);
        const arguments = try reader.operands(result);
        try std.testing.expectEqual(@as(usize, 3), arguments.len);
        const tag = try reader.node(arguments[0]);
        try std.testing.expectEqual(dispatch.multiply, tag.kind.scalar.value.signed);
        try std.testing.expectEqual(Domain.signed_integer, tag.kind.scalar.domain);
        const factor = try reader.node(arguments[1]);
        try std.testing.expectEqual(
            @as(u64, @bitCast(@as(f64, 2.0))),
            factor.kind.scalar.value.f64_bits,
        );
        try std.testing.expectEqual(Domain.real, factor.kind.scalar.domain);
        try std.testing.expectEqual(variable, arguments[2]);
    }

    var stable = try region.rewrite(null, &rewritten, .{
        .policy = .formal_real,
        .operators = .{ .dispatch = dispatch },
        .limits = .{
            .max_nodes = 8,
            .max_edges = 8,
            .max_rule_steps = 8,
            .max_passes = 1,
        },
    });
    defer stable.deinit();
    try std.testing.expectEqual(rewritten.nodeId(), stable.nodeId());
}

const RewriteInsertProduct = struct {
    marker: NodeId,
    product: NodeId,

    fn apply(_: ?*const EvalContext, _: *RewriteBuilder, view: RewriteView, raw: *const anyopaque) Error!?NodeId {
        const self: *const RewriteInsertProduct = @ptrCast(@alignCast(raw));
        if (view.id == self.marker) return self.product;
        return null;
    }
};

test "rewrite performs multiple bounded traversal passes" {
    var region = try Region.init(
        std.testing.allocator,
        null,
        .{ .identity = @enumFromInt(58) },
    );
    defer region.deinit();

    const dispatch = testDispatchOperators(testPrimitive(16, 1));
    const variable = try region.freshVariable(null, "x", .real, .none);
    const one = try region.intern(null, .{ .scalar = .{
        .value = Scalar.fromF64(1.0),
        .domain = .real,
    } });
    const marker = try region.intern(null, .{ .scalar = .{
        .value = Scalar.fromF64(3.0),
        .domain = .real,
    } });
    const product = try testDispatchCall(
        &region,
        dispatch,
        dispatch.multiply,
        &.{ one, variable },
        .real,
    );
    const root = try region.intern(null, .{ .list = .{ .elements = &.{marker} } });
    var input = try region.handle(null, root);
    defer input.deinit();
    const custom: RewriteInsertProduct = .{ .marker = marker, .product = product };

    var one_pass = try region.rewrite(null, &input, .{
        .policy = .formal_real,
        .custom = .{ .context = &custom, .apply = &RewriteInsertProduct.apply },
        .operators = .{ .dispatch = dispatch },
        .limits = .{
            .max_nodes = 64,
            .max_edges = 64,
            .max_rule_steps = 16,
            .max_passes = 1,
        },
    });
    defer one_pass.deinit();
    {
        var reader = try one_pass.acquire(null);
        defer reader.deinit();
        const list = try reader.node(one_pass.nodeId());
        const elements = try reader.operands(list);
        try std.testing.expectEqual(@as(usize, 1), elements.len);
        try std.testing.expectEqual(product, elements[0]);
    }

    var two_passes = try region.rewrite(null, &input, .{
        .policy = .formal_real,
        .custom = .{ .context = &custom, .apply = &RewriteInsertProduct.apply },
        .operators = .{ .dispatch = dispatch },
        .limits = .{
            .max_nodes = 64,
            .max_edges = 64,
            .max_rule_steps = 16,
            .max_passes = 2,
        },
    });
    defer two_passes.deinit();
    {
        var reader = try two_passes.acquire(null);
        defer reader.deinit();
        const list = try reader.node(two_passes.nodeId());
        const elements = try reader.operands(list);
        try std.testing.expectEqual(@as(usize, 1), elements.len);
        try std.testing.expectEqual(variable, elements[0]);
    }
}

test "dispatch rewrite matching requires primitive tag and arity" {
    var region = try Region.init(
        std.testing.allocator,
        null,
        .{ .identity = @enumFromInt(57) },
    );
    defer region.deinit();

    const dispatch = testDispatchOperators(testPrimitive(14, 1));
    const other = testDispatchOperators(testPrimitive(15, 1));
    const zero = try region.intern(null, .{ .scalar = .{
        .value = Scalar.fromF64(0.0),
        .domain = .real,
    } });
    const variable = try region.freshVariable(null, "x", .real, .none);
    const roots = [_]NodeId{
        try testDispatchCall(
            &region,
            other,
            other.multiply,
            &.{ zero, variable },
            .real,
        ),
        try testDispatchCall(
            &region,
            dispatch,
            999,
            &.{ zero, variable },
            .real,
        ),
        try testDispatchCall(
            &region,
            dispatch,
            dispatch.multiply,
            &.{zero},
            .real,
        ),
    };

    for (roots) |root| {
        var handle = try region.handle(null, root);
        defer handle.deinit();
        var rewritten = try region.rewrite(null, &handle, .{
            .policy = .formal_real,
            .operators = .{ .dispatch = dispatch },
        });
        defer rewritten.deinit();
        try std.testing.expectEqual(root, rewritten.nodeId());
    }
}

const RewriteCycle = struct {
    first: NodeId,
    second: NodeId,

    fn apply(_: ?*const EvalContext, _: *RewriteBuilder, view: RewriteView, raw: *const anyopaque) Error!?NodeId {
        const self: *const RewriteCycle = @ptrCast(@alignCast(raw));
        if (view.id == self.first) return self.second;
        if (view.id == self.second) return self.first;
        return null;
    }
};

test "custom rewrite cycles stop at the explicit fixed point bound" {
    var region = try Region.init(std.testing.allocator, null, .{ .identity = @enumFromInt(47) });
    defer region.deinit();

    const first = try region.intern(null, .{ .scalar = .{ .value = .{ .signed = 1 }, .domain = .signed_integer } });
    const second = try region.intern(null, .{ .scalar = .{ .value = .{ .signed = 2 }, .domain = .signed_integer } });
    var handle = try region.handle(null, first);
    defer handle.deinit();
    const cycle: RewriteCycle = .{ .first = first, .second = second };

    try std.testing.expectError(error.RewriteCycle, region.rewrite(null, &handle, .{
        .policy = .formal_real,
        .custom = .{ .context = &cycle, .apply = &RewriteCycle.apply },
        .limits = .{ .max_nodes = 16, .max_edges = 16, .max_rule_steps = 8 },
    }));
}

test "region quotas reject growth without corrupting published nodes" {
    var region = try Region.init(std.testing.allocator, null, .{
        .identity = @enumFromInt(48),
        .limits = .{
            .max_nodes = 1,
            .max_edges = 4,
            .max_labels = 4,
            .max_names = 4,
            .max_name_bytes = 8,
            .max_shape_dimensions = 4,
        },
    });
    defer region.deinit();

    const first = try region.intern(null, .{ .scalar = .{ .value = .{ .signed = 1 }, .domain = .signed_integer } });
    try std.testing.expectError(
        error.LimitExceeded,
        region.intern(null, .{
            .scalar = .{
                .value = .{ .signed = 2 },
                .domain = .signed_integer,
            },
        }),
    );
    var reader = try region.acquire(null);
    defer reader.deinit();
    try std.testing.expectEqual(@as(i64, 1), (try reader.node(first)).kind.scalar.value.signed);
}

test "closing rejects acquisitions while active readers finish safely" {
    var region = try Region.init(std.testing.allocator, null, .{ .identity = @enumFromInt(50) });
    const value = try region.intern(null, .{ .scalar = .{ .value = .{ .signed = 17 }, .domain = .signed_integer } });
    var handle = try region.handle(null, value);
    var reader = try handle.acquire(null);

    region.deinit();
    try std.testing.expect(handle.isExpired());
    try std.testing.expectError(error.Expired, handle.acquire(null));
    try std.testing.expectEqual(@as(i64, 17), (try reader.node(value)).kind.scalar.value.signed);

    reader.deinit();
    try std.testing.expectError(error.Expired, handle.acquire(null));
    handle.deinit();
}

test "list map tensor and record nodes expose structured metadata" {
    var region = try Region.init(std.testing.allocator, null, .{ .identity = @enumFromInt(51) });
    defer region.deinit();

    const one = try region.intern(null, .{ .scalar = .{ .value = Scalar.fromF64(1.0), .domain = .real } });
    const two = try region.intern(null, .{ .scalar = .{ .value = Scalar.fromF64(2.0), .domain = .real } });
    const list = try region.intern(null, .{ .list = .{ .elements = &.{ one, two } } });
    const map = try region.intern(null, .{ .map = .{ .labels = &.{ "left", "right" }, .values = &.{ one, two } } });
    const tensor = try region.intern(null, .{
        .tensor = .{
            .dtype = .f64,
            .shape = &.{2},
            .elements = &.{ one, two },
        },
    });
    const record = try region.intern(null, .{
        .record = .{
            .type_label = "Pair",
            .field_labels = &.{ "items", "lookup", "array" },
            .fields = &.{ list, map, tensor },
        },
    });

    var reader = try region.acquire(null);
    defer reader.deinit();
    const record_node = try reader.node(record);
    try std.testing.expectEqualStrings("Pair", try reader.name(record_node.kind.record.type_label));
    try std.testing.expectEqualStrings("items", try reader.label(record_node.kind.record.fields, 0));
    try std.testing.expectEqualStrings("lookup", try reader.label(record_node.kind.record.fields, 1));
    try std.testing.expectEqualStrings("array", try reader.label(record_node.kind.record.fields, 2));
    try std.testing.expectEqualSlices(NodeId, &.{ list, map, tensor }, try reader.operands(record_node));

    const map_node = try reader.node(map);
    try std.testing.expectEqualStrings("left", try reader.label(map_node.kind.map.labels, 0));
    try std.testing.expectEqualStrings("right", try reader.label(map_node.kind.map.labels, 1));
    const tensor_node = try reader.node(tensor);
    try std.testing.expectEqual(DType.f64, tensor_node.kind.tensor.dtype);
    try std.testing.expectEqualSlices(u32, &.{2}, try reader.shape(tensor_node.kind.tensor.shape));
}

test "conditional nodes preserve branches through snapshots and rewrites" {
    var region = try Region.init(std.testing.allocator, null, .{ .identity = @enumFromInt(53) });
    defer region.deinit();

    const multiply = testPrimitive(9, 1);
    const predicate = try region.intern(null, .{ .scalar = .{ .value = .{ .boolean = true }, .domain = .boolean } });
    const zero = try region.intern(null, .{ .scalar = .{ .value = Scalar.fromF64(0.0), .domain = .real } });
    const one = try region.intern(null, .{ .scalar = .{ .value = Scalar.fromF64(1.0), .domain = .real } });
    const product = try region.intern(null, .{
        .primitive_call = .{
            .identity = multiply,
            .arguments = &.{ zero, one },
            .domain = .real,
        },
    });
    const conditional = try region.intern(null, .{ .conditional = .{
        .predicate = predicate,
        .then_branch = product,
        .else_branch = one,
        .domain = .real,
    } });

    var source_reader = try region.acquire(null);
    defer source_reader.deinit();
    const source_node = try source_reader.node(conditional);
    try std.testing.expectEqual(NodeTag.conditional, std.meta.activeTag(source_node.kind));
    try std.testing.expectEqualSlices(NodeId, &.{ predicate, product, one }, try source_reader.operands(source_node));

    var handle = try region.handle(null, conditional);
    defer handle.deinit();
    var snapshot = try handle.snapshot(std.testing.allocator, null, .{});
    defer snapshot.deinit();
    const copied = try snapshot.node(snapshot.root());
    try std.testing.expectEqual(NodeTag.conditional, std.meta.activeTag(copied.kind));
    try std.testing.expectEqual(@as(usize, 3), (try snapshot.operands(copied)).len);

    var rewritten = try region.rewrite(null, &handle, .{
        .policy = .formal_real,
        .operators = .{ .multiply = multiply },
    });
    defer rewritten.deinit();
    var rewritten_reader = try rewritten.acquire(null);
    defer rewritten_reader.deinit();
    const rewritten_node = try rewritten_reader.node(rewritten.nodeId());
    try std.testing.expectEqual(NodeTag.conditional, std.meta.activeTag(rewritten_node.kind));
    try std.testing.expectEqual(zero, rewritten_node.kind.conditional.then_branch);
}

test "bounded snapshot traverses a 16384 node chain iteratively" {
    var region = try Region.init(std.testing.allocator, null, .{
        .identity = @enumFromInt(52),
        .limits = .{
            .max_nodes = 16_384,
            .max_edges = 16_383,
            .max_names = 8,
            .max_labels = 1,
            .max_name_bytes = 16,
            .max_shape_dimensions = 1,
        },
    });
    defer region.deinit();

    const successor = testPrimitive(8, 1);
    var root = try region.freshVariable(null, "root", .real, .none);
    var count: u32 = 1;
    while (count < 16_384) : (count += 1) {
        root = try region.intern(null, .{
            .primitive_call = .{
                .identity = successor,
                .arguments = &.{root},
                .domain = .real,
            },
        });
    }

    var handle = try region.handle(null, root);
    defer handle.deinit();
    var snapshot = try handle.snapshot(std.testing.allocator, null, .{
        .max_nodes = 16_384,
        .max_edges = 16_383,
        .max_names = 8,
        .max_labels = 1,
        .max_name_bytes = 16,
        .max_shape_dimensions = 1,
    });
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 16_384), snapshot.nodeCount());
    try std.testing.expectEqual(NodeTag.primitive_call, std.meta.activeTag((try snapshot.node(snapshot.root())).kind));
}
