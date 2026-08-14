const std = @import("std");
const Arena = std.heap.ArenaAllocator;
const skript = @import("../root.zig");
const Runtime = @import("../Runtime.zig");
const Store = skript.Store;
const Header = Store.Header;
const header_size = Store.header_size;
const Error = skript.Error;
const Value = skript.Value;
const b = @import("../builtin.zig");
const SourceUnit = @import("../SourceUnit.zig");
const Closure = skript.data.Closure;
const ClosureGuard = skript.data.ClosureGuard;
const CodeView = @import("../code_view.zig");
const validateClosureGuard = Runtime.validateClosureGuard;

fn makeStringVal(self: *Runtime, str: []const u8) Error!Value {
    const out = try self.store.sym_alloc.allocSentinel(u8, str.len, 0);
    @memcpy(out[0..str.len], str);
    return Value.string(.fromPtr(out.ptr));
}

/// The source-location side table of the reader tree `form` belongs to: the
/// table pointer stashed in the cell's header meta (a raw arena pointer, tag
/// 0 — see Reader.SlocTable), or null for cells without one (atoms,
/// host-built values, synthetic compiler cells).
fn slocTableOf(form: Value) ?*const skript.Reader.SlocTable {
    if (form.typ != b.type_cons) return null;
    const hdr: *Header = @ptrFromInt(form.obj.toRef().address() - header_size);
    if (hdr.meta.isNull()) return null;
    return hdr.meta.deref(skript.Reader.SlocTable);
}

/// The location of the store cell at `addr`: its entry in `table`, or
/// `fallback` when the cell carries no recorded location of its own (an
/// atom, or a synthetic cell whose copied meta names the table but whose
/// address is not in it).
fn cellSloc(
    table: ?*const skript.Reader.SlocTable,
    addr: usize,
    fallback: ?*const skript.Reader.SourceLocation,
) ?*const skript.Reader.SourceLocation {
    if (table) |t| {
        if (skript.Reader.lookupCell(t, addr)) |sloc| return sloc;
    }
    return fallback;
}

/// DFS preorder walk over a source tree. `index` counts down; when it
/// reaches zero at a node, `found`/`out`/`out_sloc` receive the node and
/// its source location (the node's own side-table entry when it has one,
/// else the location carried down from the nearest enclosing cell — the
/// reader records every element cell's start).
fn dfsWalk(
    form: Value,
    index: *u32,
    table: ?*const skript.Reader.SlocTable,
    cur_sloc: ?*const skript.Reader.SourceLocation,
    found: *bool,
    out: *Value,
    out_sloc: *?*const skript.Reader.SourceLocation,
) void {
    if (found.*) return;
    if (index.* == 0) {
        found.* = true;
        out.* = form;
        out_sloc.* = if (form.typ == b.type_cons)
            cellSloc(table, form.obj.toRef().address(), cur_sloc)
        else
            cur_sloc;
        return;
    }
    index.* -= 1;
    if (form.typ != b.type_cons) return;
    const ref = form.obj.toRef();
    const cell = ref.deref([2]Value);
    // The list's own location (its opening token) is the fallback for the
    // first element; deeper element cells carry their own entries.
    const first_sloc = cellSloc(table, ref.address(), cur_sloc);
    dfsWalk(cell[0], index, table, first_sloc, found, out, out_sloc);
    var rest = cell[1];
    while (rest.typ == b.type_cons) {
        const rref = rest.obj.toRef();
        const rsloc = cellSloc(table, rref.address(), first_sloc);
        dfsWalk(rref.deref([2]Value)[0], index, table, rsloc, found, out, out_sloc);
        rest = rref.deref([2]Value)[1];
    }
    if (rest.typ != b.type_nil) dfsWalk(rest, index, table, first_sloc, found, out, out_sloc);
}

/// The node of `source` at DFS preorder `index` (.nil when out of range).
/// Public: host error reporting maps closure.source → index → node.
pub fn dfsNodeAt(self: *Runtime, source: Value, index: u32) Value {
    _ = self;
    var remaining = index;
    var found = false;
    var out: Value = .nil;
    var out_sloc: ?*const skript.Reader.SourceLocation = null;
    dfsWalk(source, &remaining, slocTableOf(source), null, &found, &out, &out_sloc);
    return out;
}

/// The source location of the node at DFS preorder `index` within `source`,
/// or null when the node resolves none. The span-resolution hook for the
/// `src` pseudoinstruction: host code walks the closure's source tree, reads
/// the node at the failing index, and renders its span. The returned pointer
/// references the read's arena-resident side table — stable for the
/// runtime's lifetime.
pub fn dfsNodeLocation(self: *Runtime, source: Value, index: u32) ?*const skript.Reader.SourceLocation {
    _ = self;
    var remaining = index;
    var found = false;
    var out: Value = .nil;
    var out_sloc: ?*const skript.Reader.SourceLocation = null;
    dfsWalk(source, &remaining, slocTableOf(source), null, &found, &out, &out_sloc);
    return out_sloc;
}

fn acquireInspectionGuard(self: *Runtime, closure: *const Closure) Error!?*const ClosureGuard {
    const guard = closure.guard orelse return null;
    try validateClosureGuard(guard);
    var acquired = false;
    if (guard.acquire) |acquire| {
        try acquire(self, guard.context);
        acquired = true;
    }
    errdefer if (acquired) self.releaseClosureGuard(guard);
    try guard.check(self, guard.context);
    return if (acquired) guard else null;
}

fn releaseInspectionGuard(self: *Runtime, guard: ?*const ClosureGuard) void {
    if (guard) |held| self.releaseClosureGuard(held);
}
/// Export the exact defining form text for a compiled closure.
pub fn inspectSourceText(
    self: *Runtime,
    closure: *const Closure,
    max_bytes: usize,
) Error!Value {
    const guard = try acquireInspectionGuard(self, closure);
    defer releaseInspectionGuard(self, guard);
    const source_text = try SourceUnit.text(closure.source_ref, max_bytes);
    return makeStringVal(self, source_text);
}

/// Export a detached, bounded copy of a closure's defining datum.
pub fn inspectSourceDatum(
    self: *Runtime,
    closure: *const Closure,
    max_nodes: usize,
) Error!Value {
    const guard = try acquireInspectionGuard(self, closure);
    defer releaseInspectionGuard(self, guard);
    if (closure.source.isNil()) return error.Unsupported;
    if (closure.source_ref.unit) |unit| {
        if (unit.retention == .none) return error.Unsupported;
    }
    var scratch_arena = Arena.init(self.gpa);
    defer scratch_arena.deinit();
    return SourceUnit.snapshot(scratch_arena.allocator(), self.store, closure.source, .{
        .max_bytes = 65536,
        .max_nodes = max_nodes,
        .max_depth = 4096,
    });
}

/// Export detached semantic data, including generated code, without captures.
pub fn inspectBoundCode(self: *Runtime, closure: *const Closure, max_nodes: usize) Error!Value {
    const guard = try acquireInspectionGuard(self, closure);
    defer releaseInspectionGuard(self, guard);
    const code = closure.code orelse return error.Unsupported;
    return CodeView.snapshot(self, code, closure.function_id, .{ .max_nodes = max_nodes });
}
