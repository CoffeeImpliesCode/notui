const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const List = std.ArrayList;
const skript = @import("root.zig");
const Cursor = skript.Cursor;
const Token = skript.Token;
const TokenIndex = skript.TokenIndex;
const Error = skript.Error;

/// Maximum recursive-descent nesting depth. Inputs nested deeper than this
/// return `error.StackOverflow` instead of overflowing the C stack.
const max_parse_depth: u32 = 4096;

/// Recursive-descent parser for the Skript language. Produces a tree of `Node`s
/// from a token stream.
const Ast = @This();

/// An AST node: tagged with a `Tag`, spanning a range of tokens, and containing
/// zero or more child nodes.
pub const Node = struct {
    pub const Index = skript.Index(Node, u32);
    pub const Tag = enum(u8) {
        null,
        File,
        Expression,
        Literal,
        Binding,
        Call,
        Number,
        String,
        Def,
        Defn,
        FnDef,
        IfExpr,
        Case,
        Begin,
        Quote,
        Let,
        Keyword,
    };

    first_token: TokenIndex = .null,
    first_child: Index = .null,
    num_tokens: u32 = 0,
    num_children: u16 = 0,
    tag: Tag = .null,

    pub fn childIndex(self: *Node, child_idx: Index.IndexType) Node.Index {
        std.debug.assert(child_idx < self.num_children);
        std.debug.assert(self.first_child.index != Index.null.index);
        return self.first_child.offset(child_idx);
    }

    /// Get a pointer to a child. Requires `child_idx < num_children`.
    pub fn child(self: *Node, ast: *Ast, child_idx: Index.IndexType) *Node {
        const index = self.childIndex(child_idx);
        std.debug.assert(index.index < ast.nodes.items.len);
        return &ast.nodes.items[index.index];
    }

    /// Iterate over child nodes as `NodeRef`s.
    pub fn children(self: *Node, ast: *Ast) NodeSliceIterator {
        const start = if (self.num_children > 0) self.first_child.index else 0;
        const end = if (self.num_children > 0) start + self.num_children else 0;
        return .{
            .ast = ast,
            .first_index = self.first_child,
            .slice = ast.nodes.items[start..end],
        };
    }
};

/// A reference to an AST node with convenience accessors.
pub const NodeRef = struct {
    ptr: *Node,
    ast: *Ast,
    idx: Node.Index,

    /// Get the nth child as a NodeRef.
    pub fn child(self: NodeRef, child_idx: usize) NodeRef {
        const child_ptr = self.ptr.child(self.ast, @intCast(child_idx));
        const idx = self.ptr.childIndex(@intCast(child_idx));
        return .{ .ptr = child_ptr, .idx = idx, .ast = self.ast };
    }

    /// Source text spanned by this node (from first token to last).
    pub fn span(self: NodeRef) []const u8 {
        const toks = self.tokens();
        return self.ast.src[toks[0].start..toks[toks.len - 1].end];
    }

    /// The DFS preorder index of this node within the subtree rooted at
    /// `root` (0 = the root itself). Preorder visits a node, then its
    /// children in order — the same enumeration as the regvm `src`
    /// pseudoinstruction over reader data (children = elements; atoms have
    /// no children), so an Ast node's index is directly comparable to a
    /// reader-tree index for the same source shape (design directive 3).
    pub fn dfsIndex(self: NodeRef, root: NodeRef) u32 {
        var index: u32 = 0;
        var found = false;
        root.dfsWalk(&index, &found, self);
        return index;
    }

    fn dfsWalk(self: NodeRef, index: *u32, found: *bool, target: NodeRef) void {
        if (found.*) return;
        if (self.ptr == target.ptr) {
            found.* = true;
            return;
        }
        index.* += 1;
        var it = self.children();
        while (it.next()) |c| c.dfsWalk(index, found, target);
    }

    /// Iterate over child nodes.
    pub fn children(self: NodeRef) NodeSliceIterator {
        return self.ptr.children(self.ast);
    }

    /// The tokens that make up this node.
    pub fn tokens(self: NodeRef) []Token {
        return self.ast.tokens.items[self.ptr.first_token.index .. self.ptr.first_token.index + self.ptr.num_tokens];
    }
};

/// Iterator over a node's children. Produced by `NodeRef.children()`.
pub const NodeSliceIterator = struct {
    ast: *Ast,
    first_index: Node.Index,
    slice: []Node,
    offset: usize = 0,

    /// Advance to the next child, returning null when exhausted.
    pub fn next(self: *NodeSliceIterator) ?NodeRef {
        if (self.offset >= self.slice.len) return null;
        const val: NodeRef = .{
            .ast = self.ast,
            .idx = self.first_index.offset(@intCast(self.offset)),
            .ptr = &self.slice[self.offset],
        };
        self.offset += 1;
        return val;
    }
};

alloc: Allocator,
tokens: List(Token),
nodes: List(Node),
toplevel: Node.Tag,
root_node: NodeRef,
src: []const u8,
depth: u32,

/// Parse `source` into an AST. `toplevel` determines the root node type:
/// `.File` for a sequence of forms, `.Expression` for a single form.
pub fn create(alloc: Allocator, source: []const u8, toplevel: Node.Tag) !*Ast {
    const self = try alloc.create(Ast);
    self.* = Ast{
        .alloc = alloc,
        .nodes = try List(Node).initCapacity(alloc, source.len / 2),
        .tokens = try List(Token).initCapacity(alloc, source.len / 2),
        .src = source,
        // SAFETY: overwritten after pushNodes
        .root_node = .{ .ast = undefined, .idx = .null, .ptr = undefined },
        .toplevel = toplevel,
        .depth = 0,
    };
    try self.nodes.append(alloc, .{}); // append null node at start
    try self.tokens.append(alloc, .{}); // append null token at start

    // Pre-lex all tokens once, then parse from the token array.
    {
        var c: Cursor = .{ .src = source };
        while (c.offset < source.len) {
            const tok = try Token.lex(&c);
            try self.tokens.append(alloc, tok);
            c.offset = tok.end;
        }
    }
    // Append sentinel EOF token so peek past end still returns EOF.
    try self.tokens.append(alloc, .{
        .kind = .eof,
        .line = 0,
        .col = 0,
        .start = @intCast(source.len),
        .end = @intCast(source.len),
    });

    var pos: usize = 1; // skip null token at index 0
    const root = root: switch (toplevel) {
        .File => break :root try self.parseFile(&pos),
        .Expression => break :root try self.parseExpression(&pos),
        else => return error.Unsupported,
    };
    const root_node_idx = try self.pushNodes(&.{root});

    // node pointers are now stable
    self.root_node = self.getNode(root_node_idx);
    return self;
}

/// Free all AST memory.
pub fn destroy(self: *Ast) void {
    self.nodes.deinit(self.alloc);
    self.tokens.deinit(self.alloc);
    self.alloc.destroy(self);
}

// pub fn sourceInfoByIndex(self: *Ast, node_idx: Node.Index) v.SourceInfo {
//     const this_node = self.getNode(node_idx);
//     const start = self.tokens.items[@intCast(this_node.first_token)];
//     const last = self.tokens.items[@intCast(this_node.first_token)..][@intCast(this_node.num_tokens - 1)];

/// Get a NodeRef for the node at index `idx`.
pub fn getNode(self: *Ast, idx: Node.Index) NodeRef {
    return .{
        .ast = self,
        // SAFETY: .ptr is undefined in the null/error return path. Caller must check .valid().
        .ptr = idx.getMut(self.nodes.items) orelse return .{ .ast = self, .ptr = undefined, .idx = idx },
        .idx = idx,
    };
}

/// Iterate over the children of `node`. Equivalent to `node.children()`.
pub fn iterChildren(self: *Ast, node: *Node) NodeSliceIterator {
    return .{
        .ast = self,
        .first_index = node.first_child,
        .slice = self.getChildren(node),
    };
}

/// Get the raw child node slice for `node`.
pub fn getChildren(self: *Ast, node: *Node) []Node {
    return self.nodes.items[node.first_child.index..node.first_child.offset(node.num_children).index];
}

/// Get the raw child node slice for the node at index `idx`.
pub fn getChildrenByIndex(self: *Ast, idx: Node.Index) []Node {
    const this = self.getNode(idx);
    return self.getChildren(this.ptr);
}

/// Get a pointer to the token at index `idx`.
pub fn getToken(self: *Ast, idx: Token.Index) *Token {
    return &self.tokens.items[idx.index];
}

/// Return the token at the current position without advancing.
fn currentToken(self: *Ast, pos: *usize) Error!Token {
    const idx = pos.*;
    if (idx >= self.tokens.items.len) return self.tokens.items[self.tokens.items.len - 1];
    return self.tokens.items[idx];
}

/// Return the current token position as an index. Used to delimit node token spans.
fn nextTokenIndex(self: *Ast, pos: *usize) Token.Index {
    _ = self;
    return .{ .index = @intCast(pos.*) };
}

/// Return the token `n` positions ahead without advancing.
fn peek(self: *Ast, pos: *usize, n: usize) Error!Token {
    const idx = pos.* + n;
    if (idx >= self.tokens.items.len) return self.tokens.items[self.tokens.items.len - 1];
    return self.tokens.items[idx];
}

/// Consume tokens matching `expected` in sequence. Returns the index of the last
/// consumed token. Fails with `error.UnexpectedToken` on the first mismatch.
fn eatExpected(self: *Ast, pos: *usize, expected: []const Token.Kind) Error!Token.Index {
    var last_idx: Token.Index = .null;
    for (expected) |exp| {
        const current = try self.currentToken(pos);
        const current_idx = try self.consume(pos, 1);
        if (current.kind != exp) {
            return error.UnexpectedToken;
        }
        last_idx = current_idx;
    }
    return last_idx;
}

/// Advance the token position by `n` and return the index of the last consumed token.
fn consume(_: *Ast, pos: *usize, n: usize) Error!Token.Index {
    pos.* += n;
    return .{ .index = @intCast(pos.* - 1) };
}

/// Construct a `Node` from a tag, token span, and children. Children are appended
/// to the flat node array.
fn createNode(
    self: *Ast,
    tag: Node.Tag,
    token_start: Token.Index,
    token_end: Token.Index,
    children: []const Node,
) !Node {
    return .{
        .tag = tag,
        .first_token = token_start,
        .num_tokens = token_end.index - token_start.index,
        .first_child = try self.pushNodes(children),
        .num_children = @intCast(children.len),
    };
}

/// Append child nodes to `self.nodes`. Returns the index of the first appended node.
fn pushNodes(self: *Ast, nodes: []const Node) !Node.Index {
    if (nodes.len == 0) return .null;
    const idx: u32 = @intCast(self.nodes.items.len);
    try self.nodes.appendSlice(self.alloc, nodes);
    return .fromInt(idx);
}

// ---- PARSERS ----

/// Parse all forms from cursor until EOF as a `.File` node. Top-level entry point
/// for multi-form input.
fn parseFile(self: *Ast, pos: *usize) Error!Node {
    const start = self.nextTokenIndex(pos);
    var cache = List(Node).empty;
    defer cache.deinit(self.alloc);

    while ((try self.peek(pos, 0)).kind != .eof) {
        const elem = try self.parseExpression(pos);
        try cache.append(self.alloc, elem);
    }

    return self.createNode(.File, start, self.nextTokenIndex(pos), cache.items);
}

/// True when the parser has not nested deeper than `max_parse_depth`.
fn isSafeToRecurse(self: *Ast) bool {
    return self.depth <= max_parse_depth;
}

/// Parse one S-expression. Dispatches on the first token: special forms
/// (`def`/`defn`/`if`/`fn`/`case`) get their own parser. Otherwise falls through
/// to `parseCall` (for lists) or `parseAtom` (for identifiers/numbers/strings).
fn parseExpression(self: *Ast, pos: *usize) Error!Node {
    self.depth += 1;
    defer self.depth -= 1;
    if (!self.isSafeToRecurse()) return error.StackOverflow;
    switch ((try self.peek(pos, 0)).kind) {
        .lparen => {
            const arg0 = try self.peek(pos, 1);
            const str = self.src[arg0.start..arg0.end];
            switch (arg0.kind) {
                .identifier => {
                    if (std.mem.eql(u8, str, "def")) {
                        return self.parseDef(pos);
                    } else if (std.mem.eql(u8, str, "defn")) {
                        return self.parseDefn(pos);
                    } else if (std.mem.eql(u8, str, "if")) {
                        return self.parseIf(pos);
                    } else if (std.mem.eql(u8, str, "fn")) {
                        return self.parseFn(pos);
                    } else if (std.mem.eql(u8, str, "case")) {
                        return self.parseCase(pos);
                    } else if (std.mem.eql(u8, str, "begin")) {
                        return self.parseBegin(pos);
                    } else if (std.mem.eql(u8, str, "cond")) {
                        return self.parseCond(pos);
                    } else if (std.mem.eql(u8, str, "let")) {
                        return self.parseLet(pos);
                    } else if (std.mem.eql(u8, str, "quote")) {
                        return self.parseQuote(pos);
                    } else return self.parseCall(pos);
                },
                else => return self.parseCall(pos),
            }
        },
        .identifier, .number, .string, .keyword => return self.parseAtom(pos),
        .quote => {
            const start = self.nextTokenIndex(pos);
            _ = try self.eatExpected(pos, &.{.quote});
            const quoted = try self.parseExpression(pos);
            return self.createNode(.Quote, start, self.nextTokenIndex(pos), &.{quoted});
        },
        .map_marker => {
            // `:{ :k v ... }` map literals desugar to `(hash-map :k v ...)` at the
            // READER level (Reader.readMap) and work on the regvm path
            // (readAll → analyzeData). This stack-VM AST front-end cannot
            // synthesize the constant `hash-map` head: `.Binding` nodes resolve
            // by source span and the input contains no "hash-map" text. Rejected
            // until a constant-symbol node exists.
            return error.Unimplemented;
        },
        .lbracket => {
            // `[ e ... ]` tensor literals desugar to `(stack e ...)` at the
            // READER level (Reader.readTensor); same synthetic-head
            // limitation as the .map_marker arm above.
            return error.Unimplemented;
        },
        else => return error.Unimplemented,
    }
}

/// Parse `(def <binding> <body>)`. Returns a `.Def` node with two children
/// (the binding symbol and the body expression).
fn parseDef(self: *Ast, pos: *usize) Error!Node {
    const start = self.nextTokenIndex(pos);
    _ = try self.eatExpected(pos, &.{ .lparen, .identifier });
    const binding = try self.parseAtom(pos);
    const body = try self.parseExpression(pos);
    _ = try self.eatExpected(pos, &.{.rparen});
    return self.createNode(.Def, start, self.nextTokenIndex(pos), &.{ binding, body });
}

/// Parse `(if <pred> <consequence> <alternative>)` — the alternative is
/// optional (R7RS 2-arg form; a missing alternative defaults to nil).
/// Returns a `.IfExpr` node with two or three children.
fn parseIf(self: *Ast, pos: *usize) Error!Node {
    const start = self.nextTokenIndex(pos);
    _ = try self.eatExpected(pos, &.{ .lparen, .identifier });
    const pred = try self.parseExpression(pos);
    const cons = try self.parseExpression(pos);
    const alt = if ((try self.peek(pos, 0)).kind != .rparen) try self.parseExpression(pos) else null;
    _ = try self.eatExpected(pos, &.{.rparen});
    if (alt) |a| {
        return self.createNode(.IfExpr, start, self.nextTokenIndex(pos), &.{ pred, cons, a });
    }
    return self.createNode(.IfExpr, start, self.nextTokenIndex(pos), &.{ pred, cons });
}

/// Parse `(case <discriminant> ((keys...) <body>) ... ((else) <body>))`.
/// Returns a `.Case` node. Children layout is:
/// [discriminant, keys_1, body_1, keys_2, body_2, ..., else_atom, else_body].
fn parseCase(self: *Ast, pos: *usize) Error!Node {
    const start = self.nextTokenIndex(pos);
    _ = try self.eatExpected(pos, &.{ .lparen, .identifier }); // consume (case

    const disc = try self.parseExpression(pos);

    // SAFETY: backing buffer for ArrayList, len starts at 0
    var arr: [128]Node = undefined;
    var cache = List(Node).initBuffer(&arr);
    cache.appendAssumeCapacity(disc);

    while ((try self.peek(pos, 0)).kind != .rparen) {
        _ = try self.eatExpected(pos, &.{.lparen});
        const first = try self.peek(pos, 0);

        if (first.kind == .identifier and std.mem.eql(u8, self.src[first.start..first.end], "else")) {
            // else clause
            const else_node = try self.parseAtom(pos);
            const body = try self.parseExpression(pos);
            _ = try self.eatExpected(pos, &.{.rparen});
            cache.appendAssumeCapacity(else_node);
            cache.appendAssumeCapacity(body);
        } else if (first.kind == .lparen) {
            // key list
            _ = try self.eatExpected(pos, &.{.lparen});
            const keys_start = self.nextTokenIndex(pos);
            var key_buf: [32]Node = undefined;
            var key_cache = List(Node).initBuffer(&key_buf);
            while ((try self.peek(pos, 0)).kind != .rparen) {
                key_cache.appendAssumeCapacity(try self.parseExpression(pos));
            }
            const keys = try self.createNode(.Begin, keys_start, self.nextTokenIndex(pos), key_cache.items);
            _ = try self.eatExpected(pos, &.{.rparen});
            const body = try self.parseExpression(pos);
            _ = try self.eatExpected(pos, &.{.rparen}); // close clause
            cache.appendAssumeCapacity(keys);
            cache.appendAssumeCapacity(body);
        } else {
            return error.UnexpectedToken;
        }
    }
    _ = try self.eatExpected(pos, &.{.rparen});

    return self.createNode(.Case, start, self.nextTokenIndex(pos), cache.items);
}

/// Parse `(defn (<name> <args>...) <body>...)` — the name lives inside the
/// param list. Normalizes to a `.Defn` node with three children: binding
/// symbol, args list node, and body begin-block.
fn parseDefn(self: *Ast, pos: *usize) Error!Node {
    const start = self.nextTokenIndex(pos);
    _ = try self.eatExpected(pos, &.{ .lparen, .identifier }); // consume ( defn

    var arr: [64]Node = undefined;
    // `(defn (name a b) ...)` — name lives inside the param list.
    _ = try self.eatExpected(pos, &.{.lparen});
    const binding = try self.parseAtom(pos);

    const args_start = self.nextTokenIndex(pos);
    // SAFETY: backing buffer for ArrayList, len starts at 0
    var args_cache = List(Node).initBuffer(&arr);
    while ((try self.peek(pos, 0)).kind != .rparen) {
        args_cache.appendAssumeCapacity(try self.parseAtom(pos));
    }
    const args = try self.createNode(.null, args_start, self.nextTokenIndex(pos), args_cache.items);
    _ = try self.eatExpected(pos, &.{.rparen});

    const body_start = self.nextTokenIndex(pos);
    var body_cache = List(Node).initBuffer(&arr);
    while ((try self.peek(pos, 0)).kind != .rparen) {
        body_cache.appendAssumeCapacity(try self.parseExpression(pos));
    }

    const body = try self.createNode(.Begin, body_start, self.nextTokenIndex(pos), body_cache.items);
    _ = try self.eatExpected(pos, &.{.rparen});

    return self.createNode(.Defn, start, self.nextTokenIndex(pos), &.{ binding, args, body });
}

/// Parse `(fn (<args>...) <body>)`. Returns a `.FnDef` node with two children:
/// the args list node and the body expression.
fn parseFn(self: *Ast, pos: *usize) Error!Node {
    const start = self.nextTokenIndex(pos);
    _ = try self.eatExpected(pos, &.{ .lparen, .identifier, .lparen });

    const args_start = self.nextTokenIndex(pos);
    // SAFETY: backing buffer for ArrayList, len starts at 0
    var arr: [64]Node = undefined;
    var args_cache = List(Node).initBuffer(&arr);
    while ((try self.peek(pos, 0)).kind != .rparen) {
        args_cache.appendAssumeCapacity(try self.parseAtom(pos));
    }
    const args = try self.createNode(.null, args_start, self.nextTokenIndex(pos), args_cache.items);
    _ = try self.eatExpected(pos, &.{.rparen});

    const body_start = self.nextTokenIndex(pos);
    var body_cache = List(Node).initBuffer(&arr);
    while ((try self.peek(pos, 0)).kind != .rparen) {
        body_cache.appendAssumeCapacity(try self.parseExpression(pos));
    }
    const body = try self.createNode(.Begin, body_start, self.nextTokenIndex(pos), body_cache.items);
    _ = try self.eatExpected(pos, &.{.rparen});

    return self.createNode(.FnDef, start, self.nextTokenIndex(pos), &.{ args, body });
}

/// Parse `(begin <expr>...)`. Evaluates each expression in order, returns the
/// value of the last expression. Returns `.Begin` node.
fn parseBegin(self: *Ast, pos: *usize) Error!Node {
    const start = self.nextTokenIndex(pos);
    _ = try self.eatExpected(pos, &.{ .lparen, .identifier });

    // SAFETY: backing buffer for ArrayList, len starts at 0
    var arr: [64]Node = undefined;
    var cache = List(Node).initBuffer(&arr);
    while ((try self.peek(pos, 0)).kind != .rparen) {
        cache.appendAssumeCapacity(try self.parseExpression(pos));
    }
    const body = try self.createNode(.Begin, start, self.nextTokenIndex(pos), cache.items);
    _ = try self.eatExpected(pos, &.{.rparen});
    return body;
}

/// Parse `(let ((name val) ...) <body>)`. Returns a `.Let` node with children:
/// [name1, val1, name2, val2, ..., body]. All bindings are sequential (let*).
fn parseLet(self: *Ast, pos: *usize) Error!Node {
    const start = self.nextTokenIndex(pos);
    _ = try self.eatExpected(pos, &.{ .lparen, .identifier, .lparen });

    var arr: [64]Node = undefined;
    var cache = List(Node).initBuffer(&arr);

    while ((try self.peek(pos, 0)).kind != .rparen) {
        _ = try self.eatExpected(pos, &.{.lparen});
        const name = try self.parseAtom(pos);
        const val = try self.parseExpression(pos);
        _ = try self.eatExpected(pos, &.{.rparen});
        cache.appendAssumeCapacity(name);
        cache.appendAssumeCapacity(val);
    }
    _ = try self.eatExpected(pos, &.{.rparen});

    const body = try self.parseExpression(pos);
    _ = try self.eatExpected(pos, &.{.rparen});
    cache.appendAssumeCapacity(body);
    return self.createNode(.Let, start, self.nextTokenIndex(pos), cache.items);
}

/// Parse `(cond <pred> <cons> ...)`. Lowers to nested `if` expressions:
/// `(cond p1 c1 p2 c2 p3) => (if p1 c1 (if p2 c2 p3))`.
/// The last clause should use `#t` as predicate for a default branch.
fn parseCond(self: *Ast, pos: *usize) Error!Node {
    const start = self.nextTokenIndex(pos);
    _ = try self.eatExpected(pos, &.{ .lparen, .identifier });

    // SAFETY: backing buffers for clause pairs — MUST be separate
    var arr_a: [64]Node = undefined;
    var arr_b: [64]Node = undefined;
    var preds = List(Node).initBuffer(&arr_a);
    var conseqs = List(Node).initBuffer(&arr_b);

    while ((try self.peek(pos, 0)).kind != .rparen) {
        preds.appendAssumeCapacity(try self.parseExpression(pos));
        conseqs.appendAssumeCapacity(try self.parseExpression(pos));
    }
    _ = try self.eatExpected(pos, &.{.rparen});

    if (preds.items.len == 0) return error.Unimplemented;
    // preds/conseqs are appended in pairs, so len > 0 here whenever preds is.
    if (conseqs.items.len == 0) return error.Unimplemented;

    // Build nested if from right to left
    var result = conseqs.items[conseqs.items.len - 1];
    var i: usize = conseqs.items.len - 1;
    while (i > 0) {
        i -= 1;
        const if_node = try self.createNode(
            .IfExpr,
            start,
            self.nextTokenIndex(pos),
            &.{ preds.items[i], conseqs.items[i], result },
        );
        // SAFETY: result may dangle after createNode if arena resizes,
        // but the arena is append-only so addresses are stable.
        result = if_node;
    }
    return result;
}

/// Parse `(quote <expr>)`. Returns a `.Quote` node with one child.
fn parseQuote(self: *Ast, pos: *usize) Error!Node {
    const start = self.nextTokenIndex(pos);
    _ = try self.eatExpected(pos, &.{ .lparen, .identifier });
    const quoted = try self.parseExpression(pos);
    _ = try self.eatExpected(pos, &.{.rparen});
    return self.createNode(.Quote, start, self.nextTokenIndex(pos), &.{quoted});
}

/// Parse `(<func> <args>...)`. Returns a `.Call` node with the function as the
/// first child and arguments as subsequent children. An empty list `()` is the
/// empty form: it returns an empty `.Begin` node so it evaluates to nil
/// (same node shape an empty `(begin)` produces).
fn parseCall(self: *Ast, pos: *usize) Error!Node {
    const start = self.nextTokenIndex(pos);
    // SAFETY: backing buffer for ArrayList, len starts at 0
    var buf: [32]Node = undefined;
    var cache = List(Node).initBuffer(&buf);

    _ = try self.eatExpected(pos, &.{.lparen});
    while ((try self.peek(pos, 0)).kind != .rparen) {
        cache.appendAssumeCapacity(try self.parseExpression(pos));
    }
    _ = try self.eatExpected(pos, &.{.rparen});
    if (cache.items.len == 0) {
        return self.createNode(.Begin, start, self.nextTokenIndex(pos), &.{});
    }
    return self.createNode(.Call, start, self.nextTokenIndex(pos), cache.items);
}

/// Parse a single token that must be an identifier, number, or string.
/// Returns `.Binding`, `.Number`, or `.String` node respectively.
fn parseAtom(self: *Ast, pos: *usize) Error!Node {
    const start = self.nextTokenIndex(pos);
    const tok = try self.currentToken(pos);
    _ = try self.eatExpected(pos, &.{tok.kind});
    switch (tok.kind) {
        .identifier => return self.createNode(.Binding, start, self.nextTokenIndex(pos), &.{}),
        .number => return self.createNode(.Number, start, self.nextTokenIndex(pos), &.{}),
        .string => return self.createNode(.String, start, self.nextTokenIndex(pos), &.{}),
        .keyword => return self.createNode(.Keyword, start, self.nextTokenIndex(pos), &.{}),
        else => return error.UnexpectedToken,
    }
}

/// Print an AST subtree to `w`, one node per line with indentation and up to
/// 5 token spans.
pub fn printAst(
    allocator: Allocator,
    current: NodeRef,
    indent: usize,
    w: *Writer,
) (Allocator.Error || Writer.Error)!void {
    var stack: List(NodeSliceIterator) = .empty;
    defer stack.deinit(allocator);
    var node = current;
    var visited: usize = 0;
    traversal: while (visited < current.ast.nodes.items.len) : (visited += 1) {
        try printAstLine(node, indent + stack.items.len, w);
        var children = node.children();
        if (children.next()) |child| {
            try stack.append(allocator, children);
            node = child;
            continue;
        }
        try w.flush();
        while (stack.items.len > 0) {
            const parent = &stack.items[stack.items.len - 1];
            if (parent.next()) |sibling| {
                node = sibling;
                continue :traversal;
            }
            stack.items.len -= 1;
            try w.flush();
        }
        return;
    }
    unreachable;
}

fn printAstLine(current: NodeRef, indent: usize, w: *Writer) Writer.Error!void {
    for (0..indent) |_| try w.writeAll("  ");
    try w.print("{s} ", .{@tagName(current.ptr.tag)});
    const toks = current.tokens();
    for (toks[0..@min(toks.len, 5)]) |tok| {
        const span = current.ast.src[tok.start..tok.end];
        try w.print("`{s}` ", .{span});
    }
    if (toks.len > 5) try w.print("...", .{});
    try w.print("\n", .{});
}

test "printAst preserves indentation sibling order and token truncation" {
    const ast = try Ast.create(std.testing.allocator, "(foo 1 2 3 4 5)", .Expression);
    defer ast.destroy();
    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try printAst(std.testing.allocator, ast.root_node, 1, &output.writer);

    try std.testing.expectEqualStrings(
        "  Call `(` `foo` `1` `2` `3` ...\n" ++
            "    Binding `foo` \n" ++
            "    Number `1` \n" ++
            "    Number `2` \n" ++
            "    Number `3` \n" ++
            "    Number `4` \n" ++
            "    Number `5` \n",
        output.written(),
    );
}

test "printAst handles deep trees on a bounded thread stack" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const depth = 4096;
    const ast = try Ast.create(std.testing.allocator, "0", .Expression);
    defer ast.destroy();
    try ast.nodes.resize(std.testing.allocator, depth + 1);
    for (ast.nodes.items[1..], 1..) |*node, index| {
        node.* = .{
            .tag = .Begin,
            .first_token = .{ .index = 0 },
            .first_child = if (index < depth) .{ .index = @intCast(index + 1) } else .null,
            .num_children = @intFromBool(index < depth),
        };
    }
    ast.root_node = ast.getNode(.{ .index = 1 });
    var output: Writer.Discarding = .init(&.{});
    var result: anyerror!void = error.TestUnexpectedResult;
    const Worker = struct {
        fn run(allocator: Allocator, root: NodeRef, writer: *Writer, status: *anyerror!void) void {
            status.* = printAst(allocator, root, 0, writer);
        }
    };
    const worker = try std.Thread.spawn(
        .{ .stack_size = 512 * 1024 },
        Worker.run,
        .{ std.testing.allocator, ast.root_node, &output.writer, &result },
    );
    worker.join();
    try result;
    try std.testing.expectEqual(@as(u64, depth * (depth - 1 + 7)), output.fullCount());
}

test "dfsIndex enumerates nodes in DFS preorder" {
    // (fn (x) (+ x 1)) — FnDef(0) args(1) x(2) Begin(3) Call(4) +(5) x(6)
    // 1(7). The DFS preorder index matches the regvm `src` pseudoinstruction
    // enumeration over the reader tree for the same shape.
    const ast = try Ast.create(std.testing.allocator, "(fn (x) (+ x 1))", .Expression);
    defer ast.destroy();
    const root = ast.root_node;
    const args = root.child(0);
    const body = root.child(1);
    const call = body.child(0);
    try std.testing.expectEqual(@as(u32, 0), root.dfsIndex(root));
    try std.testing.expectEqual(@as(u32, 1), args.dfsIndex(root));
    try std.testing.expectEqual(@as(u32, 2), args.child(0).dfsIndex(root));
    try std.testing.expectEqual(@as(u32, 3), body.dfsIndex(root));
    try std.testing.expectEqual(@as(u32, 4), call.dfsIndex(root));
    try std.testing.expectEqual(@as(u32, 5), call.child(0).dfsIndex(root));
    try std.testing.expectEqual(@as(u32, 6), call.child(1).dfsIndex(root));
    try std.testing.expectEqual(@as(u32, 7), call.child(2).dfsIndex(root));
    // The span of a node resolves its source text.
    try std.testing.expectEqualStrings("(+ x 1)", call.span());
}

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
        std.testing.refAllDecls(Ast);
        std.testing.refAllDecls(Node);
    }
}
