//! ztex.parse — LaTeX math source → superflat atom tree.
//!
//! Usable on its own: `parse(gpa, src)` returns an `atom.Ast` you can inspect
//! or feed to `ztex.layout`.

const std = @import("std");
const atom = @import("ztex.atom");

pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const err = @import("error.zig");

/// Parse-error context (kind + span + message); see `err.Info`.
pub const Info = err.Info;
/// The parse-error kinds; see `err.Kind`.
pub const Kind = err.Kind;

pub const Error = lexer.Error || parser.Error;

/// Pre-lex and parse `src` into an atom tree. Caller owns the Ast: free with
/// `ast.deinit()`. `ast.src` aliases the caller's `src` (never copied). On
/// a parse error, `err_info` (when non-null) is filled with the kind and the
/// offending byte span before the error is returned; on success it is
/// untouched.
pub fn parse(gpa: std.mem.Allocator, src: []const u8, err_info: ?*Info) Error!atom.Ast {
    var ast = atom.Ast.init(gpa, src);
    errdefer ast.deinit();
    // pre-lex capacity heuristic: tokens ≈ src.len/4 (capacity-only, the
    // ArrayList grows past it if the input is denser)
    try ast.reserve(src.len / 4, src.len / 2);
    try lexer.lex(&ast, err_info);
    // Exact node-pool bound: every tree has nodes = 2·treesize − 1 and
    // treesize ≤ tokens + 1, so 2·(tokens + 1) caps the pool. Reserve it so
    // parsing never reallocates (capacity-only, no shrink).
    try ast.nodes.ensureTotalCapacity(gpa, 2 * (ast.tokens.items.len + 1));
    var p = parser.Parser.init(gpa, src, ast.tokens.items, err_info);
    ast.root = try p.parse(&ast);
    return ast;
}

// ── tests ────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "parse: full pipeline, x+1 becomes 3-char row" {
    var ast = try parse(testing.allocator, "x+1", null);
    defer ast.deinit();
    try testing.expectEqual(@as(usize, 3), ast.tokens.items.len);
    const root = ast.node(ast.root);
    try testing.expectEqual(.row, root.tag);
    try testing.expectEqual(@as(u16, 3), root.num_children);
}

test "parse: frac with scripts" {
    var ast = try parse(testing.allocator, "\\frac{1}{2}+x^2", null);
    defer ast.deinit();
    // root row: [fraction, char, script]
    try testing.expectEqual(@as(u16, 3), ast.node(ast.root).num_children);
    const frac = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.fraction, frac.tag);
    const script = ast.node(ast.child(ast.root, 2));
    try testing.expectEqual(.script, script.tag);
}

test "parse: unknown command is an error with kind and span" {
    var err_info: Info = undefined;
    try testing.expectError(
        error.UnknownCommand,
        parse(testing.allocator, "\\nosuchcmd{x}", &err_info),
    );
    const info = err_info;
    try testing.expectEqual(Kind.unknown_command, info.kind);
    // the span covers exactly the offending command token, "\nosuchcmd"
    try testing.expectEqual(@as(u32, 0), info.span.start);
    try testing.expectEqual(@as(u32, 10), info.span.end);
}

test "parse: dangling escape is an error with kind and span" {
    var err_info: Info = undefined;
    try testing.expectError(error.DanglingEscape, parse(testing.allocator, "abc\\", &err_info));
    const info = err_info;
    try testing.expectEqual(Kind.dangling_escape, info.kind);
    // the span covers the dangling backslash itself
    try testing.expectEqual(@as(u32, 3), info.span.start);
    try testing.expectEqual(@as(u32, 4), info.span.end);
}

test "parse: missing argument points at the end of input" {
    var err_info: Info = undefined;
    // \frac{a} is missing the denominator: the error is a zero-width span
    // at end of source (offset 8), where the argument was expected.
    try testing.expectError(
        error.MissingArgument,
        parse(testing.allocator, "\\frac{a}", &err_info),
    );
    const info = err_info;
    try testing.expectEqual(Kind.missing_argument, info.kind);
    try testing.expectEqual(@as(u32, 8), info.span.start);
    try testing.expectEqual(@as(u32, 8), info.span.end);
    try testing.expectEqualStrings("Missing argument", info.message());
}

test "parse: stray closing brace reports kind and span" {
    var err_info: Info = undefined;
    // the trailing } after a complete \frac is an unexpected r_group
    try testing.expectError(
        error.UnexpectedRGroup,
        parse(testing.allocator, "\\frac{1}{2}}", &err_info),
    );
    const info = err_info;
    try testing.expectEqual(Kind.unexpected_r_group, info.kind);
    try testing.expectEqual(@as(u32, 11), info.span.start); // the stray }
    try testing.expectEqual(@as(u32, 12), info.span.end);
}

test "parse: unclosed left-right points at the \\left command" {
    var err_info: Info = undefined;
    try testing.expectError(error.UnclosedGroup, parse(testing.allocator, "\\left(", &err_info));
    const info = err_info;
    try testing.expectEqual(Kind.unclosed_group, info.kind);
    try testing.expectEqual(@as(u32, 0), info.span.start); // the \left command
    try testing.expectEqual(@as(u32, 5), info.span.end);
}

test "parse: pretty-print helpers resolve a real error position" {
    const src = "x + y\n\\frac{1}{2}}\nz";
    var err_info: Info = undefined;
    try testing.expectError(error.UnexpectedRGroup, parse(testing.allocator, src, &err_info));
    const info = err_info;
    try testing.expectEqual(Kind.unexpected_r_group, info.kind);
    const lc = err.lineCol(src, info.span.start);
    try testing.expectEqual(@as(usize, 2), lc.line);
    try testing.expectEqual(@as(usize, 12), lc.col); // the stray } is byte 12 of line 2
    try testing.expectEqualStrings("\\frac{1}{2}}", err.sourceLine(src, info.span.start));
}

test "parse: atop fraction has no rule line" {
    var ast = try parse(testing.allocator, "\\atop{1}{2}", null);
    defer ast.deinit();
    const frac = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.fraction, frac.tag);
    try testing.expectEqual(@as(u32, 0), frac.data);
}

test "parse: text command" {
    var ast = try parse(testing.allocator, "\\text{ab}", null);
    defer ast.deinit();
    try testing.expectEqual(.text, ast.node(ast.child(ast.root, 0)).tag);
}

test "parse: bold style command" {
    var ast = try parse(testing.allocator, "\\mathbf{y}", null);
    defer ast.deinit();
    const st = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.styled, st.tag);
    try testing.expectEqual(@as(u32, @intFromEnum(atom.CharStyle.bold)), st.data);
}

test "parse: thin space command" {
    var ast = try parse(testing.allocator, "\\,", null);
    defer ast.deinit();
    const sp = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.space, sp.tag);
    try testing.expectApproxEqAbs(@as(f32, 0.166), atom.fixedToEm(sp.data), 0.001);
}
