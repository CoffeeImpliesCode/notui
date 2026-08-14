//! ztex.parse — LaTeX math source → superflat atom tree.
//!
//! Usable on its own: `parse(gpa, src)` returns an `atom.Ast` you can inspect
//! or feed to `ztex.layout`.

const std = @import("std");
const atom = @import("ztex.atom");

pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");

pub const Error = lexer.Error || parser.Error;

/// Pre-lex and parse `src` into an atom tree. Caller owns the Ast: free with
/// `ast.deinit()`. `ast.src` aliases the caller's `src` (never copied).
pub fn parse(gpa: std.mem.Allocator, src: []const u8) Error!atom.Ast {
    var ast = atom.Ast.init(gpa, src);
    errdefer ast.deinit();
    // pre-lex capacity heuristic: tokens ≈ src.len/4 (capacity-only, the
    // ArrayList grows past it if the input is denser)
    try ast.reserve(src.len / 4, src.len / 2);
    try lexer.lex(&ast);
    // Exact node-pool bound: every tree has nodes = 2·treesize − 1 and
    // treesize ≤ tokens + 1, so 2·(tokens + 1) caps the pool. Reserve it so
    // parsing never reallocates (capacity-only, no shrink).
    try ast.nodes.ensureTotalCapacity(gpa, 2 * (ast.tokens.items.len + 1));
    var p = parser.Parser.init(gpa, src, ast.tokens.items);
    ast.root = try p.parse(&ast);
    return ast;
}

// ── tests ────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "parse: full pipeline, x+1 becomes 3-char row" {
    var ast = try parse(testing.allocator, "x+1");
    defer ast.deinit();
    try testing.expectEqual(@as(usize, 3), ast.tokens.items.len);
    const root = ast.node(ast.root);
    try testing.expectEqual(.row, root.tag);
    try testing.expectEqual(@as(u16, 3), root.num_children);
}

test "parse: frac with scripts" {
    var ast = try parse(testing.allocator, "\\frac{1}{2}+x^2");
    defer ast.deinit();
    // root row: [fraction, char, script]
    try testing.expectEqual(@as(u16, 3), ast.node(ast.root).num_children);
    const frac = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.fraction, frac.tag);
    const script = ast.node(ast.child(ast.root, 2));
    try testing.expectEqual(.script, script.tag);
}

test "parse: unknown command is an error" {
    try testing.expectError(error.UnknownCommand, parse(testing.allocator, "\\nosuchcmd{x}"));
}

test "parse: dangling escape is an error" {
    try testing.expectError(error.DanglingEscape, parse(testing.allocator, "abc\\"));
}

test "parse: atop fraction has no rule line" {
    var ast = try parse(testing.allocator, "\\atop{1}{2}");
    defer ast.deinit();
    const frac = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.fraction, frac.tag);
    try testing.expectEqual(@as(u32, 0), frac.data);
}

test "parse: text command" {
    var ast = try parse(testing.allocator, "\\text{ab}");
    defer ast.deinit();
    try testing.expectEqual(.text, ast.node(ast.child(ast.root, 0)).tag);
}

test "parse: bold style command" {
    var ast = try parse(testing.allocator, "\\mathbf{y}");
    defer ast.deinit();
    const st = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.styled, st.tag);
    try testing.expectEqual(@as(u32, @intFromEnum(atom.CharStyle.bold)), st.data);
}

test "parse: thin space command" {
    var ast = try parse(testing.allocator, "\\,");
    defer ast.deinit();
    const sp = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.space, sp.tag);
    try testing.expectApproxEqAbs(@as(f32, 0.166), atom.fixedToEm(sp.data), 0.001);
}
