//! ztex.parse — LaTeX math source → superflat atom tree.
//!
//! Usable on its own: `parse(gpa, src, err_info)` returns an `atom.Ast` you
//! can inspect or feed to `ztex.layout`. The `Ast` borrows `src`, so the
//! source outlives it; one `ast.deinit()` releases it.
//!
//! This module lexes and parses only. It reads no font, allocates no
//! process-wide state, and needs no `std.Io`: an `error.OutOfMemory` is the
//! only failure that comes from the allocator rather than from the input.

const std = @import("std");
const atom = @import("ztex.atom");

/// `ztex.parse.lexer`: the tokenizer, for callers that lex without parsing.
pub const lexer = @import("lexer.zig");

/// `ztex.parse.parser`: the recursive-descent parser over a token table.
pub const parser = @import("parser.zig");

/// `ztex.parse.error`: the failure kinds, `Info`, and the position helpers.
pub const err = @import("error.zig");

/// Parse-error context (kind + optional span + message); see `err.Info`.
pub const Info = err.Info;

/// The parse-failure kinds, one per member of `Error`; see `err.Kind`.
pub const Kind = err.Kind;

/// Everything `parse` can return: the lexer's and parser's positioned
/// failures plus `error.OutOfMemory`. Each member corresponds to exactly one
/// `Kind`, which is what lets `err_info` be filled on every error path.
pub const Error = lexer.Error || parser.Error;

/// Pre-lex and parse `src` into an atom tree.
///
/// The returned `Ast` is the caller's: release it with `ast.deinit()`.
/// `ast.src` aliases the caller's `src` (never copied), and every span in
/// the tree points into it, so `src` must outlive the `Ast`.
///
/// `err_info` (when non-null) must stay writable for the whole call. It is
/// filled before EVERY error this returns — a positioned failure records the
/// offending byte span, and `error.OutOfMemory` records
/// `Kind.out_of_memory` with a `null` span — and left untouched on success.
/// That guarantee is per call to this function: a later stage the caller
/// runs (layout, rasterizing, its own work) shares `error.OutOfMemory` with
/// the parse stage and does NOT write the out-param, so a caller mixing
/// stages must branch on the error tag rather than on "was it written".
///
/// On error the `Ast` is released before returning, so nothing partial
/// survives; the tokens emitted before the failure do not.
pub fn parse(gpa: std.mem.Allocator, src: []const u8, err_info: ?*Info) Error!atom.Ast {
    var ast = atom.Ast.init(gpa, src);
    errdefer ast.deinit();
    parseInto(&ast, src, err_info) catch |failure| {
        switch (failure) {
            error.OutOfMemory => if (err_info) |info| {
                info.* = .{ .kind = .out_of_memory, .span = null };
            },
            else => {},
        }
        return failure;
    };
    return ast;
}

fn parseInto(ast: *atom.Ast, src: []const u8, err_info: ?*Info) Error!void {
    // pre-lex capacity heuristic: tokens ≈ src.len/4 (capacity-only, the
    // ArrayList grows past it if the input is denser)
    try ast.reserve(src.len / 4, src.len / 2);
    try lexer.lex(ast, err_info);
    // Exact node-pool bound: every tree has nodes = 2·treesize − 1 and
    // treesize ≤ tokens + 1, so 2·(tokens + 1) caps the pool. Reserve it so
    // parsing never reallocates (capacity-only, no shrink).
    try ast.nodes.ensureTotalCapacity(ast.gpa, 2 * (ast.tokens.items.len + 1));
    var p = parser.Parser.init(ast.gpa, src, ast.tokens.items, err_info);
    ast.root = try p.parse(ast);
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
    try testing.expectEqual(@as(u32, 0), info.span.?.start);
    try testing.expectEqual(@as(u32, 10), info.span.?.end);
}

test "parse: dangling escape is an error with kind and span" {
    var err_info: Info = undefined;
    try testing.expectError(error.DanglingEscape, parse(testing.allocator, "abc\\", &err_info));
    const info = err_info;
    try testing.expectEqual(Kind.dangling_escape, info.kind);
    // the span covers the dangling backslash itself
    try testing.expectEqual(@as(u32, 3), info.span.?.start);
    try testing.expectEqual(@as(u32, 4), info.span.?.end);
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
    try testing.expectEqual(@as(u32, 8), info.span.?.start);
    try testing.expectEqual(@as(u32, 8), info.span.?.end);
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
    try testing.expectEqual(@as(u32, 11), info.span.?.start); // the stray }
    try testing.expectEqual(@as(u32, 12), info.span.?.end);
}

test "parse: unclosed left-right points at the \\left command" {
    var err_info: Info = undefined;
    try testing.expectError(error.UnclosedGroup, parse(testing.allocator, "\\left(", &err_info));
    const info = err_info;
    try testing.expectEqual(Kind.unclosed_group, info.kind);
    try testing.expectEqual(@as(u32, 0), info.span.?.start); // the \left command
    try testing.expectEqual(@as(u32, 5), info.span.?.end);
}

test "parse: pretty-print helpers resolve a real error position" {
    const src = "x + y\n\\frac{1}{2}}\nz";
    var err_info: Info = undefined;
    try testing.expectError(error.UnexpectedRGroup, parse(testing.allocator, src, &err_info));
    const info = err_info;
    try testing.expectEqual(Kind.unexpected_r_group, info.kind);
    const span = info.span.?;
    const lc = err.lineCol(src, span.start);
    try testing.expectEqual(@as(usize, 2), lc.line);
    try testing.expectEqual(@as(usize, 12), lc.col); // the stray } is byte 12 of line 2
    try testing.expectEqualStrings("\\frac{1}{2}}", err.sourceLine(src, span.start));
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
    try testing.expectEqual(@as(u32, @backingInt(atom.CharStyle.bold)), st.data);
}

test "parse: thin space command" {
    var ast = try parse(testing.allocator, "\\,", null);
    defer ast.deinit();
    const sp = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.space, sp.tag);
    try testing.expectApproxEqAbs(@as(f32, 0.166), atom.fixedToEm(sp.data), 0.001);
}

test "parse: the depth guard records its own kind and span, not a stale one" {
    // The guard used to return `error.StackOverflow` without touching
    // `err_info`, so a caller reusing one `Info` read the PREVIOUS parse's
    // failure and pointed the caret at unrelated input.
    var err_info: Info = .{ .kind = .unknown_command, .span = .{ .start = 3, .end = 7 } };
    var src: [parser.max_row_depth + 8]u8 = undefined;
    @memset(&src, '{');
    try testing.expectError(
        error.StackOverflow,
        parse(testing.allocator, &src, &err_info),
    );
    try testing.expectEqual(Kind.depth_exceeded, err_info.kind);
    const span = err_info.span.?;
    // The span names a token of THIS input, not the earlier sentinel.
    try testing.expect(span.start <= span.end);
    try testing.expect(span.start < src.len);
    try testing.expect(span.end <= src.len);
    try testing.expectEqualStrings("Nesting too deep", err_info.message());
}

test "parse: an allocation failure records out_of_memory with no span" {
    // Every error `parse` returns must write the out-param, or a caller
    // that trusts it reads whatever was there before.
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var err_info: Info = .{ .kind = .unknown_command, .span = .{ .start = 3, .end = 7 } };
    try testing.expectError(
        error.OutOfMemory,
        parse(failing.allocator(), "x+1", &err_info),
    );
    try testing.expectEqual(Kind.out_of_memory, err_info.kind);
    try testing.expectEqual(@as(?atom.Span, null), err_info.span);
    try testing.expectEqualStrings("Out of memory", err_info.message());
}

test "parse: success leaves the out-param untouched" {
    var err_info: Info = .{ .kind = .unknown_command, .span = .{ .start = 3, .end = 7 } };
    var ast = try parse(testing.allocator, "x+1", &err_info);
    defer ast.deinit();
    try testing.expectEqual(Kind.unknown_command, err_info.kind);
    try testing.expectEqual(@as(u32, 3), err_info.span.?.start);
}
