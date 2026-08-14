//! Classical Lisp reader: token stream → s-expression (cons-cell data).
//!
//! Uses the pre-existing lexer (Token.zig) to produce proper lists of cons
//! cells, atoms (numbers, strings, booleans), and symbols.  Unlike the AST
//! parser (Ast.zig), the reader does *not* know about special forms — every
//! list is just a chain of cons cells.
//!
//! Grammar:
//!   form   = atom | list | map | tensor | quote-form
//!   atom   = integer | float | complex | string | symbol | keyword
//!   list   = '(' form* ['.' form] ')'
//!   map    = ':{' keyword form* '}'      → desugars to (hash-map :k v ...)
//!   tensor = '[' form* ']'               → desugars to (stack e1 e2 ...)
//!   quote  = '\'' form

const std = @import("std");

const skript = @import("root.zig");
const SourceUnit = @import("SourceUnit.zig");
const Store = skript.Store;
const Ref = Store.Ref;
const Value = skript.Value;
const Error = skript.Error;
const EvalContext = skript.EvalContext;
const Cursor = skript.Token.Cursor;
const Token = skript.Token;
const Sym = skript.Sym;
const header_size = Store.header_size;
const Header = Store.Header;

pub const Options = struct {
    mode: enum { one, all } = .all,
    retention: SourceUnit.Retention = .full,
    file: ?[]const u8 = null,
};

pub const Parsed = struct {
    unit: *const SourceUnit,
    datum: Value,
};

/// Maximum reader nesting depth (readForm ↔ readList mutual recursion). Inputs
/// nested deeper than this return `error.StackOverflow` instead of overflowing
/// the C stack.
const max_parse_depth: u32 = 4096;

/// Source-location metadata for a reader-produced object. Locations do NOT
/// live in the Store heap: every cell the reader builds carries a side-table
/// pointer (see SlocTable) in its header `meta` instead of a per-element
/// store allocation — per-element sloc cells doubled the store cost of every
/// read and blew the test-mode heap cap on the prelude.
pub const SourceLocation = struct {
    src: ?[*]const u8 = null,
    file: ?[*:0]const u8 = null,
    line: u32 = 0,
    col: u32 = 0,
    span: ?SourceUnit.Span = null,
    source_ref: SourceUnit.Ref = .{},
};

/// One side-table entry: the store address and source occurrence it carries.
pub const SlocEntry = struct {
    cell: usize,
    sloc: SourceLocation,
};

/// The per-read source-location side table. Arena-resident and immutable after
/// the read completes. Entries are sorted by store address.
pub const SlocTable = struct {
    entries: []const SlocEntry = &.{},
};

/// Resolve the recorded location of the store cell at `addr` within `table`,
/// or null when the cell carries none (a synthetic cell whose copied meta
/// names the table but whose address is not in it).
pub fn lookupCell(table: *const SlocTable, addr: usize) ?*const SourceLocation {
    var lo: usize = 0;
    var hi: usize = table.entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const entry = &table.entries[mid];
        if (entry.cell < addr) {
            lo = mid + 1;
        } else if (entry.cell > addr) {
            hi = mid;
        } else {
            return &entry.sloc;
        }
    }
    return null;
}

pub const Reader = @This();

store: *Store,
src: []const u8,
cursor: Cursor,
tok: Token = .{},
depth: u32 = 0,
context: ?*EvalContext = null,
/// Side-table entries accumulated during this read (Store.sym_alloc arena).
sloc_entries: std.ArrayListUnmanaged(SlocEntry) = .empty,
retention: SourceUnit.Retention = .full,
file: ?[:0]const u8 = null,
node_entries: std.ArrayListUnmanaged(SourceUnit.Node) = .empty,
last_node: SourceUnit.NodeId = .none,
last_end: u32 = 0,
/// The arena-resident side table; created on first use, frozen by
/// finalizeSlocTable before the read result is returned.
sloc_table: ?*SlocTable = null,

fn chargeWork(self: *const Reader, count: usize) Error!void {
    if (self.context) |context| {
        try context.check();
        try context.chargeWork(@intCast(count), 1, .reader);
    }
}

fn chargeNodes(self: *const Reader, count: usize) Error!void {
    if (self.context) |context| {
        try context.check();
        const count_u64: u64 = @intCast(count);
        try context.charge(.{ .work = count_u64, .nodes = count_u64 }, .reader);
    }
}

fn checkDepth(self: *const Reader) Error!void {
    const context = self.context orelse return;
    const budget = context.budget() orelse return;
    const depth = self.depth;
    try budget.checkDepth(depth, .reader);
}

pub fn readUnit(store: *Store, source: []const u8, options: Options) Error!Parsed {
    if (source.len > @as(usize, std.math.maxInt(u32))) return error.Unsupported;
    const context = EvalContext.currentForStore(store);
    if (context) |active| {
        try active.check();
        // Lexing, token decoding, escape handling, and optional source copying
        // each scan no more than the retained input.
        try active.chargeWork(@intCast(source.len), 4, .reader);
        if (options.file) |file| {
            try active.chargeWork(@intCast(file.len), 1, .reader);
        }
    }

    const parse_source = if (options.retention == .full)
        try store.sym_alloc.dupe(u8, source)
    else
        source;
    const owned_file: ?[:0]const u8 = if (options.file) |file|
        try store.sym_alloc.dupeSentinel(u8, file, 0)
    else
        null;

    var reader: Reader = .{
        .store = store,
        .context = context,
        .src = parse_source,
        .cursor = .{ .src = parse_source },
        .retention = options.retention,
        .file = owned_file,
    };
    try reader.next();

    const datum = switch (options.mode) {
        .one => if (reader.tok.kind == .eof) Value.nil else try reader.readForm(),
        .all => blk: {
            var first: ?Value = null;
            var last: ?Value = null;
            while (reader.tok.kind != .eof) {
                try reader.chargeWork(1);
                const form_sloc = try reader.curSourceLocation();
                const form = try reader.readForm();
                try reader.chargeNodes(1);
                const ref = try store.create([2]Value);
                const cell = Value.cons(ref.toObject());
                ref.deref([2]Value).* = .{ form, .nil };
                try reader.recordCell(ref.address(), form_sloc, .none);
                if (first == null) {
                    first = cell;
                } else {
                    const previous = last orelse unreachable;
                    previous.obj.toRef().deref([2]Value)[1] = cell;
                }
                last = cell;
            }
            break :blk first orelse Value.nil;
        },
    };

    const source_id = try store.allocSourceId();
    const unit = try store.sym_alloc.create(SourceUnit);
    const keep_nodes = options.retention != .none;
    if (options.retention == .datum_only) {
        try reader.chargeWork(reader.node_entries.items.len);
        for (reader.node_entries.items) |*node| node.span = null;
    }
    unit.* = .{
        .id = @enumFromInt(source_id),
        .retention = options.retention,
        .bytes = if (options.retention == .full) parse_source else null,
        .datum = if (options.retention == .none) Value.nil else datum,
        .nodes = if (keep_nodes) reader.node_entries.items else &.{},
        .file = owned_file,
        .store = store,
    };
    if (reader.sloc_table != null) {
        try reader.chargeWork(reader.sloc_entries.items.len);
        for (reader.sloc_entries.items) |*entry| {
            if (entry.sloc.source_ref.node != .none and keep_nodes) {
                entry.sloc.source_ref.unit = unit;
            } else {
                entry.sloc.source_ref = .{};
            }
        }
        if (options.retention != .full) {
            try reader.chargeWork(reader.sloc_entries.items.len);
            for (reader.sloc_entries.items) |*entry| {
                entry.sloc.src = null;
                entry.sloc.span = null;
            }
        }
    }
    try reader.finalizeSlocTable();

    return .{ .unit = unit, .datum = datum };
}

/// Read the first form from `src`, or nil at EOF. Classical Lisp `read`.
pub fn read(store: *Store, source: []const u8) Error!Value {
    return (try readUnit(store, source, .{ .mode = .one })).datum;
}

/// Read all forms from `src` into a proper list, or nil at EOF.
pub fn readAll(store: *Store, source: []const u8) Error!Value {
    return (try readUnit(store, source, .{ .mode = .all })).datum;
}

/// Return the occurrence reference associated with a Reader-produced cons.
pub fn sourceRef(value: Value) SourceUnit.Ref {
    if (value.typ != skript.builtins.type_cons) return .{};
    const located = storedSloc(value) orelse return .{};
    return located.sloc.source_ref;
}

/// Record `sloc` for the store cell at `addr` and associate it with a source
/// occurrence. Synthetic cells pass `.none` and therefore have no ref.
fn recordCell(
    self: *Reader,
    addr: usize,
    sloc: SourceLocation,
    node_id: SourceUnit.NodeId,
) Error!void {
    try self.chargeWork(1);
    if (self.sloc_table == null) {
        const tbl = try self.store.sym_alloc.create(SlocTable);
        tbl.* = .{};
        self.sloc_table = tbl;
    }
    var location = sloc;
    if (node_id != .none) location.source_ref.node = node_id;
    try self.sloc_entries.append(self.store.sym_alloc, .{ .cell = addr, .sloc = location });
    const hdr: *Header = @ptrFromInt(addr - header_size);
    const table = self.sloc_table orelse unreachable;
    hdr.meta = Ref.foreignMetadata(table);
}

fn appendNode(
    self: *Reader,
    parent: SourceUnit.NodeId,
    span: ?SourceUnit.Span,
    datum: Value,
) Error!SourceUnit.NodeId {
    try self.chargeNodes(1);
    if (self.node_entries.items.len >= @as(usize, std.math.maxInt(u32))) return error.Unsupported;
    const node_id: SourceUnit.NodeId = @enumFromInt(@as(u32, @intCast(self.node_entries.items.len)));
    try self.node_entries.append(self.store.sym_alloc, .{
        .parent = parent,
        .span = span,
        .datum = datum,
    });
    return node_id;
}

fn updateNode(
    self: *Reader,
    node_id: SourceUnit.NodeId,
    span: ?SourceUnit.Span,
    datum: Value,
) void {
    if (node_id == .none) return;
    const index: usize = @intCast(@intFromEnum(node_id));
    self.node_entries.items[index].span = span;
    self.node_entries.items[index].datum = datum;
}

fn sourceSpan(
    self: *const Reader,
    start: u32,
    end: u32,
    line: u32,
    col: u32,
) ?SourceUnit.Span {
    if (self.retention != .full) return null;
    return .{ .start = start, .end = end, .line = line, .col = col };
}

/// Freeze the side table: point the table at the collected entries. The
/// arena owns the buffer, so it never moves again (the Reader dies after the
/// read); no-op when the read produced no cells.
fn finalizeSlocTable(self: *Reader) Error!void {
    const tbl = self.sloc_table orelse return;
    if (self.context) |context| {
        const entry_count = self.sloc_entries.items.len;
        const level_count = if (entry_count <= 1)
            @as(u64, 1)
        else
            @as(u64, @intCast(std.math.log2_int_ceil(usize, entry_count))) + 1;
        try context.chargeWork(@intCast(entry_count), level_count, .reader);
    }
    std.mem.sort(SlocEntry, self.sloc_entries.items, {}, struct {
        fn lessThan(_: void, lhs: SlocEntry, rhs: SlocEntry) bool {
            return lhs.cell < rhs.cell;
        }
    }.lessThan);
    tbl.entries = self.sloc_entries.items;
}

/// Read a single form (atom or list).
/// True when the reader has not nested deeper than `max_parse_depth`.
fn isSafeToRecurse(self: *Reader) bool {
    return self.depth <= max_parse_depth;
}
const Form = struct {
    value: Value,
    node: SourceUnit.NodeId,
};

pub fn readForm(self: *Reader) Error!Value {
    return (try self.readFormNode(.none)).value;
}

fn readFormNode(self: *Reader, parent: SourceUnit.NodeId) Error!Form {
    self.depth += 1;
    defer self.depth -= 1;
    if (!self.isSafeToRecurse()) return error.StackOverflow;
    try self.checkDepth();
    try self.chargeWork(1);

    switch (self.tok.kind) {
        .lparen => return self.readList(parent),
        .map_marker => return self.readMap(parent),
        .lbracket => return self.readTensor(parent),
        .datum_comment => {
            try self.next();
            const nodes_before = self.node_entries.items.len;
            const entries_before = self.sloc_entries.items.len;
            _ = try self.readFormNode(parent);
            self.node_entries.items = self.node_entries.items[0..nodes_before];
            self.sloc_entries.items = self.sloc_entries.items[0..entries_before];
            return self.readFormNode(parent);
        },
        .quote => {
            const quote_token = self.tok;
            const quote_sloc = try self.curSourceLocation();
            const quote_node = try self.appendNode(
                parent,
                self.sourceSpan(
                    quote_token.start,
                    quote_token.end,
                    quote_token.line,
                    quote_token.col,
                ),
                .nil,
            );
            try self.next();
            const quoted_sloc = try self.curSourceLocation();
            const quoted = try self.readFormNode(quote_node);
            const head_entry = self.sloc_entries.items.len;
            const value = try self.cons2(
                try self.mkSymbol("quote"),
                quoted.value,
                quote_sloc,
                quoted_sloc,
            );
            self.sloc_entries.items[head_entry].sloc.span = self.sourceSpan(
                quote_token.start,
                self.last_end,
                quote_token.line,
                quote_token.col,
            );
            self.last_node = .none;
            self.updateNode(
                quote_node,
                self.sourceSpan(
                    quote_token.start,
                    self.last_end,
                    quote_token.line,
                    quote_token.col,
                ),
                value,
            );
            return .{ .value = value, .node = .none };
        },
        .identifier, .number, .string, .keyword => return self.readAtom(parent),
        .rparen, .eof => return error.UnexpectedToken,
        else => return error.Unimplemented,
    }
}

/// Read '(' form* ['.' form] ')'.
fn readList(self: *Reader, parent: SourceUnit.NodeId) Error!Form {
    const open = self.tok;
    const sloc = try self.curSourceLocation();
    const node = try self.appendNode(
        parent,
        self.sourceSpan(open.start, open.end, open.line, open.col),
        .nil,
    );
    try self.next();

    if (self.tok.kind == .rparen) {
        const close = self.tok;
        try self.next();
        self.last_end = close.end;
        self.updateNode(
            node,
            self.sourceSpan(open.start, close.end, open.line, open.col),
            .nil,
        );
        self.last_node = node;
        return .{ .value = .nil, .node = node };
    }

    var first: ?Value = null;
    var last: ?Value = null;
    var head_entry: ?usize = null;
    while (self.tok.kind != .rparen and self.tok.kind != .period) {
        try self.chargeWork(1);
        const elem_sloc = try self.curSourceLocation();
        const form = try self.readFormNode(node);
        if (head_entry == null) head_entry = self.sloc_entries.items.len;
        try self.appendChain(&first, &last, form.value, elem_sloc, form.node);
    }

    if (self.tok.kind == .period) {
        try self.next();
        const cdr_form = try self.readFormNode(node);
        if (last) |last_cell| {
            last_cell.obj.toRef().deref([2]Value)[1] = cdr_form.value;
        } else {
            return error.UnexpectedToken;
        }
        if (self.tok.kind != .rparen) return error.UnexpectedToken;
    }

    const close = self.tok;
    if (close.kind != .rparen) return error.UnexpectedToken;
    try self.next();
    const value = first orelse return error.UnexpectedToken;
    self.last_end = close.end;
    var list_sloc = sloc;
    list_sloc.span = self.sourceSpan(open.start, close.end, open.line, open.col);
    if (head_entry) |entry| {
        list_sloc.source_ref.node = node;
        self.sloc_entries.items[entry].sloc = list_sloc;
    }
    self.updateNode(
        node,
        self.sourceSpan(open.start, close.end, open.line, open.col),
        value,
    );
    self.last_node = node;
    return .{ .value = value, .node = node };
}

/// Read `:{ :k v ... }` and desugar to `(hash-map :k v ...)`.
fn readMap(self: *Reader, parent: SourceUnit.NodeId) Error!Form {
    const marker = self.tok;
    const sloc = try self.curSourceLocation();
    const node = try self.appendNode(
        parent,
        self.sourceSpan(marker.start, marker.end, marker.line, marker.col),
        .nil,
    );
    try self.next();

    var first: ?Value = null;
    var last: ?Value = null;
    var index: usize = 0;
    while (true) {
        try self.chargeWork(1);
        if (self.tok.kind == .rbrace) break;
        if (self.tok.kind == .eof) return error.UnexpectedToken;
        const elem_sloc = try self.curSourceLocation();
        const elem = try self.readFormNode(node);
        if (index % 2 == 0 and elem.value.typ != skript.builtins.type_keyword) {
            return error.UnexpectedToken;
        }
        try self.appendChain(&first, &last, elem.value, elem_sloc, elem.node);
        index += 1;
    }
    if (index % 2 != 0) return error.UnexpectedToken;
    const close = self.tok;
    try self.next();
    const head_entry = self.sloc_entries.items.len;
    const value = try self.prependHead(try self.mkSymbol("hash-map"), first, sloc);
    self.sloc_entries.items[head_entry].sloc.span =
        self.sourceSpan(marker.start, close.end, marker.line, marker.col);
    self.last_end = close.end;
    self.updateNode(
        node,
        self.sourceSpan(marker.start, close.end, marker.line, marker.col),
        value,
    );
    return .{ .value = value, .node = .none };
}

/// Read `[ e1 e2 ... ]` and desugar to `(stack e1 e2 ...)`.
fn readTensor(self: *Reader, parent: SourceUnit.NodeId) Error!Form {
    const marker = self.tok;
    const sloc = try self.curSourceLocation();
    const node = try self.appendNode(
        parent,
        self.sourceSpan(marker.start, marker.end, marker.line, marker.col),
        .nil,
    );
    try self.next();

    var first: ?Value = null;
    var last: ?Value = null;
    while (true) {
        try self.chargeWork(1);
        if (self.tok.kind == .rbracket) break;
        if (self.tok.kind == .eof) return error.UnexpectedToken;
        const elem_sloc = try self.curSourceLocation();
        const elem = try self.readFormNode(node);
        try self.appendChain(&first, &last, elem.value, elem_sloc, elem.node);
    }
    const close = self.tok;
    try self.next();
    const head_entry = self.sloc_entries.items.len;
    const value = try self.prependHead(try self.mkSymbol("stack"), first, sloc);
    self.sloc_entries.items[head_entry].sloc.span =
        self.sourceSpan(marker.start, close.end, marker.line, marker.col);
    self.last_end = close.end;
    self.updateNode(
        node,
        self.sourceSpan(marker.start, close.end, marker.line, marker.col),
        value,
    );
    return .{ .value = value, .node = .none };
}

/// Allocate a cons cell holding `form` and append it to a chain.
fn appendChain(
    self: *Reader,
    first: *?Value,
    last: *?Value,
    form: Value,
    sloc: SourceLocation,
    node_id: SourceUnit.NodeId,
) Error!void {
    try self.chargeNodes(1);
    const ref = try self.store.create([2]Value);
    const cell = Value.cons(ref.toObject());
    var element_sloc = sloc;
    if (element_sloc.span) |span| {
        element_sloc.span = .{
            .start = span.start,
            .end = self.last_end,
            .line = span.line,
            .col = span.col,
        };
    }
    try self.recordCell(ref.address(), element_sloc, node_id);
    ref.deref([2]Value).* = .{ form, .nil };

    if (last.*) |last_cell| {
        last_cell.obj.toRef().deref([2]Value)[1] = cell;
    } else {
        first.* = cell;
    }
    last.* = cell;
}

/// Create a synthetic head cons cell for map, tensor, or quote expansion.
fn prependHead(self: *Reader, head: Value, chain: ?Value, sloc: SourceLocation) Error!Value {
    try self.chargeNodes(1);
    const ref = try self.store.create([2]Value);
    const cell = Value.cons(ref.toObject());
    try self.recordCell(ref.address(), sloc, .none);
    ref.deref([2]Value).* = .{ head, chain orelse .nil };
    return cell;
}

/// Read a number, string, keyword, or symbol.
fn readAtom(self: *Reader, parent: SourceUnit.NodeId) Error!Form {
    const token = self.tok;
    const sloc = try self.curSourceLocation();
    const span = self.tokSpan();
    const val = switch (self.tok.kind) {
        .number => try parseNumber(span, self.store),
        .string => try parseString(span, self.store),
        .keyword => blk: {
            if (span.len == 0) return error.UnexpectedToken;
            break :blk Value.keyword(try self.store.getsym(span));
        },
        .identifier => blk: {
            if (std.mem.eql(u8, span, "#t")) break :blk Value.true;
            if (std.mem.eql(u8, span, "#f")) break :blk Value.false;
            if (std.mem.eql(u8, span, "nil")) break :blk Value.nil;
            break :blk try self.mkSymbol(span);
        },
        else => return error.UnexpectedToken,
    };
    try self.next();
    const start = if (token.kind == .keyword) token.start - 1 else token.start;
    const node = try self.appendNode(
        parent,
        self.sourceSpan(start, token.end, token.line, sloc.col),
        val,
    );
    self.last_node = node;
    self.last_end = token.end;
    var atom_sloc = sloc;
    atom_sloc.span = self.sourceSpan(start, token.end, token.line, sloc.col);
    if (isStoreBacked(val)) try self.attachMeta(val, atom_sloc, node);
    return .{ .value = val, .node = node };
}

/// Advance the cursor and read the next token.
fn next(self: *Reader) Error!void {
    self.tok = try Token.lex(&self.cursor);
    self.cursor.offset = self.tok.end;
}

/// Return the source span of the current token.
fn tokSpan(self: *Reader) []const u8 {
    return self.src[self.tok.start..self.tok.end];
}

/// Build a SourceLocation for the current token position.
fn curSourceLocation(self: *Reader) Error!SourceLocation {
    const start = if (self.tok.kind == .keyword) self.tok.start - 1 else self.tok.start;
    const col = if (self.tok.kind == .keyword) self.tok.col - 1 else self.tok.col;
    return .{
        .src = if (self.retention == .full) self.src.ptr else null,
        .file = if (self.file) |file| file.ptr else null,
        .line = self.tok.line,
        .col = col,
        .span = self.sourceSpan(start, self.tok.end, self.tok.line, col),
    };
}

/// Create a symbol Value for the given string.
fn mkSymbol(self: *Reader, name: []const u8) Error!Value {
    return .symbol(try self.store.getsym(name));
}

/// Create a proper list of two elements. Both cells are synthetic wrappers.
fn cons2(
    self: *Reader,
    a: Value,
    b: Value,
    sloc: SourceLocation,
    inner_sloc: SourceLocation,
) Error!Value {
    try self.chargeNodes(2);
    const ref = try self.store.create([2]Value);
    const cell = Value.cons(ref.toObject());
    try self.recordCell(ref.address(), sloc, .none);

    const inner_ref = try self.store.create([2]Value);
    const inner = Value.cons(inner_ref.toObject());
    inner_ref.deref([2]Value).* = .{ b, .nil };
    try self.recordCell(inner_ref.address(), inner_sloc, .none);

    ref.deref([2]Value).* = .{ a, inner };
    return cell;
}

// ---- header / meta helpers ---- //

/// True when the value's payload is a Store reference (has a header).
fn isStoreBacked(val: Value) bool {
    return switch (val.typ) {
        skript.builtins.type_cons,
        skript.builtins.type_c64,
        skript.builtins.type_closure,
        skript.builtins.type_method,
        skript.builtins.type_namespace,
        skript.builtins.type_opaque,
        skript.builtins.type_ffifunc,
        => true,
        else => false,
    };
}

const LocatedSloc = struct {
    table: *const SlocTable,
    sloc: *const SourceLocation,
};

/// Find a Reader value's own side-table entry; copied metadata alone is not a location.
fn storedSloc(value: Value) ?LocatedSloc {
    if (!isStoreBacked(value)) return null;
    const ref = value.obj.toRef();
    const header: *Header = @ptrFromInt(ref.address() - header_size);
    if (header.meta.isNull()) return null;
    const table: *const SlocTable = header.meta.deref(SlocTable);
    const sloc = lookupCell(table, ref.address()) orelse return null;
    return .{ .table = table, .sloc = sloc };
}

fn intrinsicSloc(ctx: *EvalContext, value: Value) Error!?*const SourceLocation {
    const located = storedSloc(value) orelse return null;
    const level_count = if (located.table.entries.len <= 1)
        @as(u64, 1)
    else
        @as(u64, @intCast(std.math.log2_int_ceil(usize, located.table.entries.len))) + 1;
    try ctx.chargeWork(level_count, 1, .reader);
    return located.sloc;
}

/// Record `sloc` as the source location of a store-backed value.
fn attachMeta(
    self: *Reader,
    val: Value,
    sloc: SourceLocation,
    node_id: SourceUnit.NodeId,
) Error!void {
    try self.recordCell(val.obj.toRef().address(), sloc, node_id);
}

// ---- number / string parsing ---- //

/// Parse a numeric literal span into a Value (i64, f64, or c64).
fn parseNumber(span: []const u8, store: *Store) Error!Value {
    // Special IEEE floats
    if (std.mem.eql(u8, span, "+inf.0")) return .f64(std.math.inf(f64));
    if (std.mem.eql(u8, span, "-inf.0")) return .f64(-std.math.inf(f64));
    if (std.mem.eql(u8, span, "inf.0")) return .f64(std.math.inf(f64));
    if (std.mem.eql(u8, span, "+nan.0")) return .f64(std.math.nan(f64));
    if (std.mem.eql(u8, span, "-nan.0")) return .f64(-std.math.nan(f64));
    if (std.mem.eql(u8, span, "nan.0")) return .f64(std.math.nan(f64));
    // Complex special float: +inf.0+2.0i
    if (span.len > 6 and span[span.len - 1] == 'i') {
        if (std.mem.startsWith(u8, span, "+inf.0") or std.mem.startsWith(u8, span, "-inf.0") or
            std.mem.startsWith(u8, span, "inf.0") or
            std.mem.startsWith(u8, span, "+nan.0") or std.mem.startsWith(u8, span, "-nan.0") or
            std.mem.startsWith(u8, span, "nan.0"))
        {
            const has_sign = span[0] == '+' or span[0] == '-';
            const split = if (has_sign) @as(usize, 6) else 5;
            const real_str = span[0..split];
            const imag_str = span[split .. span.len - 1]; // strip trailing 'i'
            const real = if (std.mem.indexOf(u8, real_str, "nan") != null)
                std.math.nan(f64)
            else
                std.math.inf(f64);
            const real_val = if (real_str[0] == '-') -real else real;
            const imag = std.fmt.parseFloat(f64, imag_str) catch return error.Unimplemented;
            const ref = try store.create([2]f64);
            const ptr = ref.deref([2]f64);
            store.store([2]f64, ptr, .{ real_val, imag });
            return .c64(ref.toObject());
        }
    }
    // Radix-prefixed integers: #b, #o, #d, #x
    if (span.len >= 3 and span[0] == '#') {
        const radix: u8 = switch (span[1]) {
            'b' => 2,
            'o' => 8,
            'd' => 10,
            'x' => 16,
            else => 0,
        };
        if (radix != 0) {
            const val = std.fmt.parseInt(i64, span[2..], radix) catch return error.Unimplemented;
            return .i64(val);
        }
    }
    if (span.len > 0 and span[span.len - 1] == 'i') {
        const without_i = span[0 .. span.len - 1];
        const sep_idx = brk: {
            var i: usize = 1;
            while (i < without_i.len) : (i += 1) {
                if (without_i[i] == '+' or without_i[i] == '-') break :brk i;
            }
            break :brk without_i.len;
        };
        var real: f64 = 0;
        var imag: f64 = 0;
        if (sep_idx < without_i.len) {
            real = std.fmt.parseFloat(f64, without_i[0..sep_idx]) catch return error.Unimplemented;
            imag = std.fmt.parseFloat(f64, without_i[sep_idx..]) catch return error.Unimplemented;
        } else {
            imag = std.fmt.parseFloat(f64, without_i) catch return error.Unimplemented;
        }
        const ref = try store.create([2]f64);
        const ptr = ref.deref([2]f64);
        store.store([2]f64, ptr, .{ real, imag });
        return .c64(ref.toObject());
    } else if (std.mem.indexOfAny(u8, span, ".eE") != null) {
        return .f64(std.fmt.parseFloat(f64, span) catch return error.Unimplemented);
    } else {
        const val = std.fmt.parseInt(i64, span, 0) catch return error.Unimplemented;
        return .i64(val);
    }
}

/// Process escape sequences in a string literal.
fn processStringEscapes(inner: []const u8, out: ?[]u8) Error!usize {
    var i: usize = 0;
    var j: usize = 0;
    while (i < inner.len) {
        if (inner[i] == '\\') {
            i += 1;
            if (i < inner.len) {
                switch (inner[i]) {
                    'n', 't', 'r', '\\', '"' => {
                        if (out) |o| o[j] = switch (inner[i]) {
                            'n' => 0x0a,
                            't' => 0x09,
                            'r' => 0x0d,
                            '\\' => 0x5c,
                            '"' => 0x22,
                            else => unreachable,
                        };
                    },
                    'x' => {
                        i += 1;
                        if (inner.len - i < 2) return error.UnexpectedToken;
                        const byte = std.fmt.parseInt(u8, inner[i .. i + 2], 16) catch return error.UnexpectedToken;
                        if (byte == 0) return error.UnexpectedToken;
                        if (out) |o| o[j] = byte;
                        j += 1;
                        i += 2;
                        continue;
                    },
                    'u' => {
                        i += 2;
                        const hex_start = i;
                        while (i < inner.len and inner[i] != '}') : (i += 1) {}
                        const hex = inner[hex_start..i];
                        if (hex.len == 0 or i >= inner.len or inner[i] != '}') return error.UnexpectedToken;
                        i += 1;
                        const cp = std.fmt.parseInt(u32, hex, 16) catch return error.UnexpectedToken;
                        if (cp == 0) return error.UnexpectedToken;
                        if (cp > 0x10FFFF) return error.Unimplemented;
                        if (out) |o| {
                            const buf = o[j..];
                            j += std.unicode.utf8Encode(@as(u21, @intCast(cp)), buf) catch return error.Unimplemented;
                        } else {
                            j += std.unicode.utf8CodepointSequenceLength(
                                @as(u21, @intCast(cp)),
                            ) catch return error.Unimplemented;
                        }
                        continue;
                    },
                    else => {
                        if (out) |o| o[j] = inner[i];
                    },
                }
                j += 1;
                i += 1;
            }
        } else {
            if (inner[i] == 0) return error.UnexpectedToken;
            if (out) |o| o[j] = inner[i];
            j += 1;
            i += 1;
        }
    }
    return j;
}
/// Parse a string literal span into a Value.
fn parseString(span: []const u8, store: *Store) Error!Value {
    const inner = span[1 .. span.len - 1];
    const final_len = try processStringEscapes(inner, null);
    const out = try store.sym_alloc.allocSentinel(u8, final_len, 0);
    _ = try processStringEscapes(inner, out[0..final_len]);
    return .string(.fromPtr(out.ptr));
}

// ---- intrinsic ---- //

/// `@read` intrinsic: (read string) → s-expression.
/// Parses the string as Skript source text and returns the first form.
pub fn readIntrinsic(
    ctx: *EvalContext,
    _: Value,
    _: Value,
    args: []const Value,
) Error!Value {
    try skript.intrinsics.arityAssert(args, 1);
    try skript.intrinsics.typeAssert(args[0], skript.builtins.type_string);

    const rt = ctx.runtime;
    const ptr = args[0].obj.toPtr([*:0]const u8);
    const src = try ctx.stringBytes(ptr, std.math.maxInt(usize), .reader);
    const parsed = try readUnit(
        rt.store,
        src,
        .{ .mode = .one, .retention = rt.source_retention },
    );
    return parsed.datum;
}

/// `@source-location` intrinsic: (source-location value) → ((line . L) (col . C)) | nil.
pub fn sourceLocationIntrinsic(
    ctx: *EvalContext,
    _: Value,
    _: Value,
    args: []const Value,
) Error!Value {
    try skript.intrinsics.arityAssert(args, 1);
    const sloc = try intrinsicSloc(ctx, args[0]) orelse return .nil;
    return buildLocAlist(ctx, sloc.*);
}

/// `@source-span` intrinsic: (source-span value) → ((start . B) (end . E) (file . F)) | nil.
pub fn sourceSpanIntrinsic(
    ctx: *EvalContext,
    _: Value,
    _: Value,
    args: []const Value,
) Error!Value {
    try skript.intrinsics.arityAssert(args, 1);
    const sloc = try intrinsicSloc(ctx, args[0]) orelse return .nil;
    return buildSpanAlist(ctx, sloc.*);
}

/// Build ((line . L) (col . C)) as a proper list of dotted pairs.
pub fn buildLocAlist(ctx: *EvalContext, sloc: SourceLocation) Error!Value {
    const store = ctx.runtime.store;
    try ctx.charge(.{ .work = 4, .nodes = 4 }, .reader);
    const line_sym = try store.getsym("line");
    const col_sym = try store.getsym("col");

    // (col . C)
    const col_ref = try store.create([2]Value);
    const col_pair = Value.cons(col_ref.toObject());
    col_ref.deref([2]Value).* = .{ .symbol(col_sym), .i64(sloc.col) };

    // (line . L)
    const line_ref = try store.create([2]Value);
    const line_pair = Value.cons(line_ref.toObject());
    line_ref.deref([2]Value).* = .{ .symbol(line_sym), .i64(sloc.line) };

    // ((line . L) (col . C))
    const outer_ref = try store.create([2]Value);
    const outer = Value.cons(outer_ref.toObject());
    const inner_ref = try store.create([2]Value);
    const inner = Value.cons(inner_ref.toObject());
    outer_ref.deref([2]Value).* = .{ line_pair, inner };
    inner_ref.deref([2]Value).* = .{ col_pair, .nil };

    return outer;
}

/// Build ((start . B) (end . E) (file . F)), or nil without a retained span.
fn buildSpanAlist(ctx: *EvalContext, sloc: SourceLocation) Error!Value {
    const span = sloc.span orelse return .nil;
    const store = ctx.runtime.store;
    try ctx.charge(.{ .work = 6, .nodes = 6 }, .reader);
    const start_sym = try store.getsym("start");
    const end_sym = try store.getsym("end");
    const file_sym = try store.getsym("file");

    const start_ref = try store.create([2]Value);
    const start_pair = Value.cons(start_ref.toObject());
    start_ref.deref([2]Value).* = .{ .symbol(start_sym), .i64(span.start) };

    const end_ref = try store.create([2]Value);
    const end_pair = Value.cons(end_ref.toObject());
    end_ref.deref([2]Value).* = .{ .symbol(end_sym), .i64(span.end) };

    const file_ref = try store.create([2]Value);
    const file_pair = Value.cons(file_ref.toObject());
    const file_value: Value = if (sloc.file) |file| .string(.fromPtr(file)) else .nil;
    file_ref.deref([2]Value).* = .{ .symbol(file_sym), file_value };

    const outer_ref = try store.create([2]Value);
    const outer = Value.cons(outer_ref.toObject());
    const middle_ref = try store.create([2]Value);
    const middle = Value.cons(middle_ref.toObject());
    const inner_ref = try store.create([2]Value);
    const inner = Value.cons(inner_ref.toObject());
    outer_ref.deref([2]Value).* = .{ start_pair, middle };
    middle_ref.deref([2]Value).* = .{ end_pair, inner };
    inner_ref.deref([2]Value).* = .{ file_pair, .nil };
    return outer;
}

// ---- tests ---- //

const t = std.testing;

const ReadResult = struct {
    store: *Store,
    value: Value,
};

fn readOne(src: []const u8) !ReadResult {
    var store = try Store.initDefault(t.allocator, std.testing.io);
    errdefer store.deinit();
    const parsed = try readUnit(store, src, .{ .mode = .one });
    return .{ .store = store, .value = parsed.datum };
}

fn readAllT(src: []const u8) !ReadResult {
    var store = try Store.initDefault(t.allocator, std.testing.io);
    errdefer store.deinit();
    const parsed = try readUnit(store, src, .{ .mode = .all });
    return .{ .store = store, .value = parsed.datum };
}

fn expectCons(val: Value) !void {
    try t.expectEqual(skript.builtins.type_cons, val.typ);
}

/// Assert that reading `src` fails with `expected`. Deinits the store on the
/// (unexpected) success path so the test allocator sees no leaks.
fn expectReadError(src: []const u8, expected: anyerror) !void {
    const res = readOne(src);
    if (res) |rr| {
        rr.store.deinit();
        return error.TestUnexpectedResult;
    } else |e| {
        try t.expectEqual(expected, e);
    }
}

fn car(val: Value) Value {
    const ref = val.obj.toRef();
    return ref.deref([2]Value)[0];
}

fn cdr(val: Value) Value {
    const ref = val.obj.toRef();
    return ref.deref([2]Value)[1];
}

test "source-span exposes exclusive byte offsets and retained file" {
    const runtime = try skript.Runtime.init(t.allocator, std.testing.io);
    defer runtime.deinit();
    const parsed = try readUnit(runtime.store, " (x)", .{
        .mode = .one,
        .file = "probe.pt",
    });
    const span = try sourceSpanIntrinsic(runtime.context(), .nil, .nil, &.{parsed.datum});
    try expectCons(span);
    try t.expectEqualStrings("start", car(car(span)).obj.toPtr(Sym).*);
    try t.expectEqual(Value.i64(1), cdr(car(span)));
    const second = cdr(span);
    try t.expectEqualStrings("end", car(car(second)).obj.toPtr(Sym).*);
    try t.expectEqual(Value.i64(4), cdr(car(second)));
    const third = cdr(second);
    try t.expectEqualStrings("file", car(car(third)).obj.toPtr(Sym).*);
    try t.expectEqualStrings("probe.pt", std.mem.span(cdr(car(third)).obj.toPtr([*:0]const u8)));

    const datum_only = try readUnit(runtime.store, "(x)", .{
        .mode = .one,
        .retention = .datum_only,
    });
    try t.expectEqual(Value.nil, try sourceSpanIntrinsic(runtime.context(), .nil, .nil, &.{datum_only.datum}));
}

test "desugared reader forms retain their complete source span" {
    const runtime = try skript.Runtime.init(t.allocator, std.testing.io);
    defer runtime.deinit();
    for ([_][]const u8{ "[1 2]", ":{:x 1}", "'x" }) |source| {
        const parsed = try readUnit(runtime.store, source, .{ .mode = .one });
        const span = try sourceSpanIntrinsic(runtime.context(), .nil, .nil, &.{parsed.datum});
        try expectCons(span);
        try t.expectEqual(Value.i64(0), cdr(car(span)));
        try t.expectEqual(Value.i64(@intCast(source.len)), cdr(car(cdr(span))));
    }
}

test "integer literal" {
    const rr = try readOne("42");
    defer rr.store.deinit();
    try t.expectEqual(skript.builtins.type_i64, rr.value.typ);
    try t.expectEqual(@as(i64, 42), rr.value.obj.toInt(i64));
}

test "float literal" {
    const rr = try readOne("3.14");
    defer rr.store.deinit();
    try t.expectEqual(skript.builtins.type_f64, rr.value.typ);
}

test "complex literal" {
    const rr = try readOne("1+2i");
    defer rr.store.deinit();
    try t.expectEqual(skript.builtins.type_c64, rr.value.typ);
    const parts = rr.value.obj.toRef().deref([2]f64);
    try t.expectEqual(@as(f64, 1.0), parts[0]);
    try t.expectEqual(@as(f64, 2.0), parts[1]);
}

test "string literal" {
    const rr = try readOne("\"hello\"");
    defer rr.store.deinit();
    try t.expectEqual(skript.builtins.type_string, rr.value.typ);
}

test "string literals reject embedded NUL" {
    try expectReadError("\"a\\x00b\"", error.UnexpectedToken);
    try expectReadError("\"a\\u{0}b\"", error.UnexpectedToken);
    try expectReadError("\"a\x00b\"", error.UnexpectedToken);
}

test "symbol" {
    const rr = try readOne("foo");
    defer rr.store.deinit();
    try t.expectEqual(skript.builtins.type_symbol, rr.value.typ);
}

test "empty list" {
    const rr = try readOne("()");
    defer rr.store.deinit();
    try t.expectEqual(skript.builtins.type_nil, rr.value.typ);
}

test "simple list" {
    const rr = try readOne("(1 2 3)");
    defer rr.store.deinit();
    const val = rr.value;
    try expectCons(val);
    try t.expectEqual(skript.builtins.type_i64, car(val).typ);
    try t.expectEqual(@as(i64, 1), car(val).obj.toInt(i64));

    const rest1 = cdr(val);
    try expectCons(rest1);
    try t.expectEqual(@as(i64, 2), car(rest1).obj.toInt(i64));

    const rest2 = cdr(rest1);
    try expectCons(rest2);
    try t.expectEqual(@as(i64, 3), car(rest2).obj.toInt(i64));

    try t.expectEqual(skript.builtins.type_nil, cdr(rest2).typ);
}

test "nested list" {
    const rr = try readOne("((a) b)");
    defer rr.store.deinit();
    const val = rr.value;
    try expectCons(val);
    try expectCons(car(val));
    try t.expectEqual(skript.builtins.type_symbol, car(car(val)).typ);

    const rest = cdr(val);
    try expectCons(rest);
    try t.expectEqual(skript.builtins.type_symbol, car(rest).typ);
    try t.expectEqual(skript.builtins.type_nil, cdr(rest).typ);
}

test "dotted pair" {
    const rr = try readOne("(a . b)");
    defer rr.store.deinit();
    const val = rr.value;
    try expectCons(val);
    try t.expectEqual(skript.builtins.type_symbol, car(val).typ);
    try t.expectEqual(skript.builtins.type_symbol, cdr(val).typ);
}

test "quote shorthand" {
    const rr = try readOne("'x");
    defer rr.store.deinit();
    const val = rr.value;
    try expectCons(val);
    try t.expectEqual(skript.builtins.type_symbol, car(val).typ);
}

test "multiple forms" {
    const rr = try readAllT("1 2 3");
    defer rr.store.deinit();
    const val = rr.value;
    try expectCons(val);
    try t.expectEqual(@as(i64, 1), car(val).obj.toInt(i64));
    try expectCons(cdr(val));
    try t.expectEqual(@as(i64, 2), car(cdr(val)).obj.toInt(i64));
    try expectCons(cdr(cdr(val)));
    try t.expectEqual(@as(i64, 3), car(cdr(cdr(val))).obj.toInt(i64));
    try t.expectEqual(skript.builtins.type_nil, cdr(cdr(cdr(val))).typ);
}

test "map literal desugars to (hash-map :k v ...)" {
    const rr = try readOne(":{:x 1 :y 2}");
    defer rr.store.deinit();
    const val = rr.value;
    try expectCons(val);
    // head symbol `hash-map`
    try t.expectEqual(skript.builtins.type_symbol, car(val).typ);
    try t.expect(std.mem.eql(u8, car(val).obj.toPtr(Sym).*, "hash-map"));
    // :x
    const pair1 = cdr(val);
    try expectCons(pair1);
    try t.expectEqual(skript.builtins.type_keyword, car(pair1).typ);
    // Keyword Syms intern WITHOUT the leading ':' (the keyword token span
    // excludes it): `:x` interns as "x".
    try t.expectEqual(try rr.store.getsym("x"), car(pair1).obj.toPtr(Sym));
    // 1
    const rest1 = cdr(pair1);
    try expectCons(rest1);
    try t.expectEqual(skript.builtins.type_i64, car(rest1).typ);
    try t.expectEqual(@as(i64, 1), car(rest1).obj.toInt(i64));
    // :y
    const pair2 = cdr(rest1);
    try expectCons(pair2);
    try t.expectEqual(skript.builtins.type_keyword, car(pair2).typ);
    try t.expectEqual(try rr.store.getsym("y"), car(pair2).obj.toPtr(Sym));
    // 2
    const rest2 = cdr(pair2);
    try expectCons(rest2);
    try t.expectEqual(skript.builtins.type_i64, car(rest2).typ);
    try t.expectEqual(@as(i64, 2), car(rest2).obj.toInt(i64));
    try t.expectEqual(skript.builtins.type_nil, cdr(rest2).typ);
}

test "empty map literal desugars to (hash-map)" {
    const rr = try readOne(":{}");
    defer rr.store.deinit();
    const val = rr.value;
    try expectCons(val);
    try t.expectEqual(skript.builtins.type_symbol, car(val).typ);
    try t.expect(std.mem.eql(u8, car(val).obj.toPtr(Sym).*, "hash-map"));
    try t.expectEqual(skript.builtins.type_nil, cdr(val).typ);
}

test "map literal with non-keyword key errors" {
    try expectReadError(":{1 :x}", error.UnexpectedToken);
}

test "map literal with odd element count errors" {
    try expectReadError(":{:x 1 :y", error.UnexpectedToken);
}

test "unbalanced map literal errors" {
    try expectReadError(":{:x 1", error.UnexpectedToken);
}

test "bare lbrace is not a map literal" {
    // Only `:{` starts a map; a bare `{` stays unsupported.
    try expectReadError("{1 :x}", error.Unimplemented);
}

test "tensor literal desugars to (stack ...)" {
    const rr = try readOne("[1 2 3]");
    defer rr.store.deinit();
    const val = rr.value;
    try expectCons(val);
    // head symbol `stack`
    try t.expectEqual(skript.builtins.type_symbol, car(val).typ);
    try t.expect(std.mem.eql(u8, car(val).obj.toPtr(Sym).*, "stack"));
    try t.expectEqual(@as(i64, 1), car(cdr(val)).obj.toInt(i64));
    try t.expectEqual(@as(i64, 2), car(cdr(cdr(val))).obj.toInt(i64));
    try t.expectEqual(@as(i64, 3), car(cdr(cdr(cdr(val)))).obj.toInt(i64));
    try t.expectEqual(skript.builtins.type_nil, cdr(cdr(cdr(cdr(val)))).typ);
}

test "nested tensor literals nest (stack ...) forms" {
    const rr = try readOne("[[1 2] [3 4]]");
    defer rr.store.deinit();
    const val = rr.value;
    try expectCons(val);
    try t.expectEqual(skript.builtins.type_symbol, car(val).typ);
    try t.expect(std.mem.eql(u8, car(val).obj.toPtr(Sym).*, "stack"));
    // inner (stack 1 2)
    const inner1 = car(cdr(val));
    try expectCons(inner1);
    try t.expectEqual(skript.builtins.type_symbol, car(inner1).typ);
    try t.expect(std.mem.eql(u8, car(inner1).obj.toPtr(Sym).*, "stack"));
    try t.expectEqual(@as(i64, 1), car(cdr(inner1)).obj.toInt(i64));
    try t.expectEqual(@as(i64, 2), car(cdr(cdr(inner1))).obj.toInt(i64));
    // inner (stack 3 4)
    const inner2 = car(cdr(cdr(val)));
    try expectCons(inner2);
    try t.expectEqual(skript.builtins.type_symbol, car(inner2).typ);
    try t.expect(std.mem.eql(u8, car(inner2).obj.toPtr(Sym).*, "stack"));
    try t.expectEqual(@as(i64, 3), car(cdr(inner2)).obj.toInt(i64));
    try t.expectEqual(@as(i64, 4), car(cdr(cdr(inner2))).obj.toInt(i64));
}

test "empty tensor literal desugars to (stack)" {
    const rr = try readOne("[]");
    defer rr.store.deinit();
    const val = rr.value;
    try expectCons(val);
    try t.expectEqual(skript.builtins.type_symbol, car(val).typ);
    try t.expect(std.mem.eql(u8, car(val).obj.toPtr(Sym).*, "stack"));
    try t.expectEqual(skript.builtins.type_nil, cdr(val).typ);
}

test "unbalanced tensor literal errors" {
    try expectReadError("[1 2", error.UnexpectedToken);
}

test "colon followed by delimiter is not a map marker" {
    // `:[` lexes as a zero-width keyword + lbracket (only `:{` is a marker),
    // so `:[ :x` fails; `:(x` and a bare `:` likewise.
    try expectReadError(":[ :x", error.UnexpectedToken);
    try expectReadError(":(x", error.UnexpectedToken);
    try expectReadError(":", error.UnexpectedToken);
}

test "defn form (reader doesn't care about semantics)" {
    const rr = try readOne("(defn (f x) (+ x 1))");
    defer rr.store.deinit();
    const val = rr.value;
    try expectCons(val);
    try t.expectEqual(skript.builtins.type_symbol, car(val).typ);
}

test "comment is skipped" {
    const rr = try readOne("; comment\n42");
    defer rr.store.deinit();
    try t.expectEqual(skript.builtins.type_i64, rr.value.typ);
    try t.expectEqual(@as(i64, 42), rr.value.obj.toInt(i64));
}

test "#t literal" {
    const rr = try readOne("#t");
    defer rr.store.deinit();
    try t.expectEqual(Value.true, rr.value);
}

test "#f literal" {
    const rr = try readOne("#f");
    defer rr.store.deinit();
    try t.expectEqual(Value.false, rr.value);
}

test "null literal" {
    const rr = try readOne("nil");
    defer rr.store.deinit();
    try t.expectEqual(Value.nil, rr.value);
}

test "quote #t returns boolean, not symbol" {
    const rr = try readOne("'#t");
    defer rr.store.deinit();
    try expectCons(rr.value);
    try t.expectEqual(Value.true, car(cdr(rr.value)));
}

test "source location on cons cell" {
    const rr = try readOne("(a)");
    defer rr.store.deinit();
    const val = rr.value;
    try expectCons(val);
    const sloc = cellSloc(val);
    try t.expect(sloc.src != null);
    try t.expectEqual(@as(u32, 1), sloc.line);
}

/// The SourceLocation of a reader-produced cons cell, resolved through the
/// side table: the header meta names the table, the address finds the entry
/// (assumed present — the cell was reader-built).
fn cellSloc(val: Value) SourceLocation {
    return (storedSloc(val) orelse unreachable).sloc.*;
}

test "read retains source after caller overwrites input" {
    const original = "(alpha\n beta)";
    var source: [original.len]u8 = undefined;
    @memcpy(source[0..], original);

    var store = try Store.initDefault(t.allocator, std.testing.io);
    defer store.deinit();
    const value = try read(store, source[0..]);
    @memset(source[0..], 'x');

    const sloc = cellSloc(cdr(value));
    try t.expectEqualStrings(original, sloc.src.?[0..original.len]);
    try t.expectEqual(@as(u32, 2), sloc.line);
    try t.expectEqual(@as(u32, 2), sloc.col);
}

test "readAll retains source after caller overwrites input" {
    const original = "(first)\n  (second)";
    var source: [original.len]u8 = undefined;
    @memcpy(source[0..], original);

    var store = try Store.initDefault(t.allocator, std.testing.io);
    defer store.deinit();
    const forms = try readAll(store, source[0..]);
    @memset(source[0..], 'x');

    const first_sloc = cellSloc(car(forms));
    try t.expectEqualStrings(original, first_sloc.src.?[0..original.len]);
    try t.expectEqual(@as(u32, 1), first_sloc.line);
    try t.expectEqual(@as(u32, 1), first_sloc.col);

    const second_sloc = cellSloc(car(cdr(forms)));
    try t.expectEqualStrings(original, second_sloc.src.?[0..original.len]);
    try t.expectEqual(@as(u32, 2), second_sloc.line);
    try t.expectEqual(@as(u32, 3), second_sloc.col);
}

test "readUnit retention redacts source without borrowing caller bytes" {
    const original = "(alpha beta)";
    var source: [original.len]u8 = undefined;
    @memcpy(source[0..], original);

    var store = try Store.initDefault(t.allocator, std.testing.io);
    defer store.deinit();
    const datum_only = try readUnit(store, source[0..], .{
        .mode = .one,
        .retention = .datum_only,
    });
    const datum_only_ref = sourceRef(datum_only.datum);
    try t.expect(datum_only.unit.bytes == null);
    try t.expectError(error.Unsupported, SourceUnit.text(datum_only_ref, 128));
    try t.expect(cellSloc(datum_only.datum).src == null);
    try t.expect(cellSloc(datum_only.datum).span == null);

    const none = try readUnit(store, source[0..], .{
        .mode = .one,
        .retention = .none,
    });
    try t.expect(none.unit.bytes == null);
    try t.expect(std.meta.eql(none.unit.datum, Value.nil));
    try t.expect(sourceRef(none.datum).unit == null);
    try t.expect(cellSloc(none.datum).src == null);
    try t.expect(cellSloc(none.datum).span == null);
}

test "equal atom occurrences retain distinct source node identities" {
    var store = try Store.initDefault(t.allocator, std.testing.io);
    defer store.deinit();
    const parsed = try readUnit(store, "(x x)", .{ .mode = .one });
    const value = parsed.datum;
    // The second element cell resolves the second occurrence through its ref
    // (the first cell carries the list's own location by design).
    const second = sourceRef(cdr(value));
    try t.expect(second.unit == parsed.unit);
    try t.expect(second.node != .none);
    try t.expectEqualStrings("x", try SourceUnit.text(second, 8));
    // Both equal atoms own distinct occurrence nodes with exact spans.
    var first_atom: ?SourceUnit.NodeId = null;
    var count: usize = 0;
    for (parsed.unit.nodes, 0..) |node, index| {
        if (node.span == null) continue;
        if (node.datum.typ != skript.builtins.type_symbol) continue;
        count += 1;
        const ref: SourceUnit.Ref = .{
            .unit = parsed.unit,
            .node = @enumFromInt(@as(u32, @intCast(index))),
        };
        try t.expectEqualStrings("x", try SourceUnit.text(ref, 8));
        if (first_atom == null) first_atom = ref.node;
    }
    try t.expectEqual(@as(usize, 2), count);
    try t.expect(first_atom.? != second.node);
}

test "source nodes use exclusive spans through quote map and tensor syntax" {
    var store = try Store.initDefault(t.allocator, std.testing.io);
    defer store.deinit();
    const parsed = try readUnit(store, "'x :{:k 1} [2 3]", .{ .mode = .all });
    var saw_quote = false;
    var saw_map = false;
    var saw_tensor = false;
    for (parsed.unit.nodes, 0..) |node, index| {
        if (node.span == null) continue;
        const ref: SourceUnit.Ref = .{
            .unit = parsed.unit,
            .node = @enumFromInt(@as(u32, @intCast(index))),
        };
        const text = SourceUnit.text(ref, 64) catch continue;
        if (std.mem.eql(u8, text, "'x")) saw_quote = true;
        if (std.mem.eql(u8, text, ":{:k 1}")) saw_map = true;
        if (std.mem.eql(u8, text, "[2 3]")) saw_tensor = true;
    }
    try t.expect(saw_quote);
    try t.expect(saw_map);
    try t.expect(saw_tensor);
}

test "per-element source locations: multiline list" {
    const rr = try readOne("(a\n b\n c)");
    defer rr.store.deinit();
    const val = rr.value;
    // The first cell carries the LIST's location (the opening paren).
    try t.expectEqual(@as(u32, 1), cellSloc(val).line);
    try t.expectEqual(@as(u32, 1), cellSloc(val).col);
    // Each later element's cell carries the ELEMENT's own start.
    const b_cell = cdr(val);
    try t.expectEqual(@as(u32, 2), cellSloc(b_cell).line);
    try t.expectEqual(@as(u32, 2), cellSloc(b_cell).col);
    const c_cell = cdr(b_cell);
    try t.expectEqual(@as(u32, 3), cellSloc(c_cell).line);
    try t.expectEqual(@as(u32, 2), cellSloc(c_cell).col);
}

test "per-element source locations: dotted pair and quote" {
    const rr = try readOne("(a . b)");
    defer rr.store.deinit();
    const val = rr.value;
    try t.expectEqual(@as(u32, 1), cellSloc(val).col);
    // The dotted tail is an atom — the list cell's location stands for it.
    try t.expectEqual(skript.builtins.type_symbol, cdr(val).typ);

    const qr = try readOne("'x");
    defer qr.store.deinit();
    const q = qr.value;
    try t.expectEqual(@as(u32, 1), cellSloc(q).col); // the quote mark
    // The quoted datum's own start rides on the inner cell.
    const inner = cdr(q);
    try t.expectEqual(@as(u32, 2), cellSloc(inner).col);
}

test "per-element source locations: map and tensor literals" {
    const rr = try readOne(":{:x 1 :y 2}");
    defer rr.store.deinit();
    const val = rr.value;
    // Head cell: the `:{` marker.
    try t.expectEqual(@as(u32, 1), cellSloc(val).col);
    // :x starts at col 3 (after `:{`), its value 1 at col 6, :y at col 8.
    const x_cell = cdr(val);
    try t.expectEqual(@as(u32, 3), cellSloc(x_cell).col);
    const v1_cell = cdr(x_cell);
    try t.expectEqual(@as(u32, 6), cellSloc(v1_cell).col);
    const y_cell = cdr(v1_cell);
    try t.expectEqual(@as(u32, 8), cellSloc(y_cell).col);

    const tr = try readOne("[1 2 3]");
    defer tr.store.deinit();
    const tv = tr.value;
    try t.expectEqual(@as(u32, 1), cellSloc(tv).col); // the `[` marker
    const e1 = cdr(tv);
    try t.expectEqual(@as(u32, 2), cellSloc(e1).col); // 1
    const e2 = cdr(e1);
    try t.expectEqual(@as(u32, 4), cellSloc(e2).col); // 2
}

test "datum comment skips one form" {
    const rr = try readOne("#;skipped 42");
    defer rr.store.deinit();
    try t.expectEqual(skript.builtins.type_i64, rr.value.typ);
    try t.expectEqual(@as(i64, 42), rr.value.obj.toInt(i64));
}

test "datum comment skips nested list" {
    const rr = try readOne("#;(a (b c)) 99");
    defer rr.store.deinit();
    try t.expectEqual(skript.builtins.type_i64, rr.value.typ);
    try t.expectEqual(@as(i64, 99), rr.value.obj.toInt(i64));
}

test "datum comment at top of list" {
    const rr = try readOne("(#;a b)");
    defer rr.store.deinit();
    try expectCons(rr.value);
    // #;a is skipped. List is just (b)
    try t.expectEqual(skript.builtins.type_symbol, car(rr.value).typ);
    // cdr should be nil (end of list)
    try t.expect(std.meta.eql(cdr(rr.value), Value.nil));
}

test "radix binary" {
    const rr = try readOne("#b1010");
    defer rr.store.deinit();
    try t.expectEqual(@as(i64, 10), rr.value.obj.toInt(i64));
}

test "radix octal" {
    const rr = try readOne("#o777");
    defer rr.store.deinit();
    try t.expectEqual(@as(i64, 511), rr.value.obj.toInt(i64));
}

test "radix decimal" {
    const rr = try readOne("#d42");
    defer rr.store.deinit();
    try t.expectEqual(@as(i64, 42), rr.value.obj.toInt(i64));
}

test "radix hex" {
    const rr = try readOne("#xFF");
    defer rr.store.deinit();
    try t.expectEqual(@as(i64, 255), rr.value.obj.toInt(i64));
}

test "radix hex lowercase" {
    const rr = try readOne("#xdead");
    defer rr.store.deinit();
    try t.expectEqual(@as(i64, 0xDEAD), rr.value.obj.toInt(i64));
}

test "block comment skipped" {
    const rr = try readOne("#| this is a comment |# 42");
    defer rr.store.deinit();
    try t.expectEqual(@as(i64, 42), rr.value.obj.toInt(i64));
}

test "nested block comment" {
    const rr = try readOne("#| outer #| inner |# still outer |# 99");
    defer rr.store.deinit();
    try t.expectEqual(@as(i64, 99), rr.value.obj.toInt(i64));
}

test "block comment inside list" {
    const rr = try readOne("(a #| skip me |# b)");
    defer rr.store.deinit();
    try expectCons(rr.value);
    try t.expectEqual(skript.builtins.type_symbol, car(rr.value).typ);
    try t.expectEqual(skript.builtins.type_symbol, car(cdr(rr.value)).typ);
}

test "special float +inf.0" {
    const rr = try readOne("+inf.0");
    defer rr.store.deinit();
    try t.expectEqual(std.math.inf(f64), rr.value.obj.tof64());
}

test "special float -inf.0" {
    const rr = try readOne("-inf.0");
    defer rr.store.deinit();
    try t.expectEqual(-std.math.inf(f64), rr.value.obj.tof64());
}

test "special float nan.0" {
    const rr = try readOne("+nan.0");
    defer rr.store.deinit();
    try t.expect(std.math.isNan(rr.value.obj.tof64()));
}

test "special float complex" {
    const rr = try readOne("+inf.0+2.0i");
    defer rr.store.deinit();
    try t.expectEqual(skript.builtins.type_c64, rr.value.typ);
    const parts = rr.value.obj.toRef().deref([2]f64);
    try t.expectEqual(std.math.inf(f64), parts[0]);
    try t.expectEqual(@as(f64, 2.0), parts[1]);
}

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
        std.testing.refAllDecls(Reader);
        std.testing.refAllDecls(SourceLocation);
    }
}
