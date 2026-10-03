//! ztex — LaTeX math parsing + layout → SVG-style draw list.
//!
//! Facade over two independently usable modules:
//! - `ztex.parse` — LaTeX source → superflat atom tree
//! - `ztex.layout` — atom tree + font metrics → box tree → draw list
//!
//! `ztex.svg` serializes a draw list to SVG, and `ztex.context` adds the
//! font-backed pipeline. The two pipelines differ in where glyph metrics
//! come from and in what they need from the caller:
//!
//! - `render` below and `ztex.layout.render` measure from the bundled static
//!   Latin-Modern-Math tables. They read no font file and need no `std.Io`.
//! - `Context` measures from real font faces and needs the caller's `std.Io`
//!   at `Context.init`, though `render` itself performs no I/O.
//!
//! Every entry point returns a value the caller owns. A `DrawList` borrows
//! the formula bytes for its `text` primitives, so the source must outlive
//! it; `draw.DrawList.deinit` releases the list and the synthetic glyphs it
//! owns.

const std = @import("std");

/// `ztex.atom`: the superflat AST node types and the `Node.data` codecs.
pub const atom = @import("ztex.atom");

/// `ztex.parse`: lexer + recursive-descent parser.
pub const parse = @import("ztex.parse");

/// `ztex.layout`: metrics, box pool, layout pass, draw list.
pub const layout = @import("ztex.layout");

/// `ztex.layout.draw`: the draw model, re-exported at the top level.
pub const draw = layout.draw;

/// `ztex.svg`: draw list → SVG bytes or file.
pub const svg = @import("ztex.svg");

/// `ztex.context`: the `Context` type, re-exported at the top level.
pub const context = @import("context.zig");

/// Font-backed rendering context: owns a FontContext and a FontMetrics
/// wired to it — "initialize once, render many" (see context.zig).
pub const Context = context.Context;

/// Full pipeline: LaTeX source → draw list (SVG-style primitives), measured
/// from the bundled static metric tables.
///
/// The returned `DrawList`'s `text` primitives alias `src`, or the draw
/// list's own glyph arena for a synthesized glyph such as `\sum`; `src` must
/// outlive the draw list, and the caller releases the draw list with `deinit`.
/// `size_pt` is the base font size in points.
///
/// `err_info` (when non-null) is filled exactly as `ztex.parse.parse` fills
/// it — including `error.OutOfMemory` — and is untouched on success. A
/// layout-stage failure shares `error.OutOfMemory` with the parse stage and
/// leaves the out-param untouched, so a caller that also handles allocation
/// failure must not read it there. On any error nothing is returned and the
/// intermediate atom tree and box pool are released.
///
/// Allocates through `gpa` only; it reads no font file, touches no `std.Io`,
/// and reaches for no process-global state.
pub fn render(
    gpa: std.mem.Allocator,
    src: []const u8,
    size_pt: f32,
    err_info: ?*parse.Info,
) !draw.DrawList {
    var ast = try parse.parse(gpa, src, err_info);
    defer ast.deinit();
    return layout.render(gpa, &ast, ast.root, size_pt);
}

test {
    std.testing.refAllDecls(@This());
}

// ── tests ────────────────

const testing = std.testing;

test "facade: render produces drawables with provenance" {
    const src = "\\frac{1}{2}+x";
    var out = try render(testing.allocator, src, 20, null);
    defer out.deinit();
    try testing.expect(out.len() > 0);
    // the fraction bar is a rect; plus the char/frac text primitives
    var saw_rect = false;
    var saw_text = false;
    for (out.items.items) |d| {
        switch (d) {
            .rect => saw_rect = true,
            .text => saw_text = true,
            .line => {},
        }
    }
    try testing.expect(saw_rect); // fraction rule
    try testing.expect(saw_text); // glyphs
    try testing.expect(out.width > 0);
}

test "facade: frac renders a rect rule and glyphs" {
    const src = "\\frac{1}{2}";
    var out = try render(testing.allocator, src, 10, null);
    defer out.deinit();
    var saw_rect = false;
    var saw_text = false;
    for (out.items.items) |d| {
        switch (d) {
            .rect => saw_rect = true,
            .text => saw_text = true,
            .line => {},
        }
    }
    try testing.expect(saw_rect); // the fraction bar
    try testing.expect(saw_text); // numerator and denominator digits
}

test "facade: text renders glyphs with source spans" {
    const src = "\\text{hi}";
    var out = try render(testing.allocator, src, 10, null);
    defer out.deinit();
    try testing.expectEqual(@as(usize, 2), out.len());
    const t0 = out.items.items[0].text;
    try testing.expectEqualStrings("h", t0.bytes);
    try testing.expectEqual(@as(u32, 6), t0.src_start);
    try testing.expectEqual(@as(u32, 7), t0.src_end);
    const t1 = out.items.items[1].text;
    try testing.expectEqualStrings("i", t1.bytes);
    try testing.expectEqual(@as(u32, 7), t1.src_start);
    try testing.expectEqual(@as(u32, 8), t1.src_end);
}
