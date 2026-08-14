//! ztex — LaTeX math parsing + layout → SVG-style draw list.
//!
//! Facade over two independently usable modules:
//! - `ztex.parse` — LaTeX source → superflat atom tree
//! - `ztex.layout` — atom tree + font metrics → box tree → draw list

const std = @import("std");

pub const atom = @import("ztex.atom");
pub const parse = @import("ztex.parse");
pub const layout = @import("ztex.layout");
pub const draw = layout.draw;
pub const svg = @import("ztex.svg");
pub const context = @import("context.zig");

/// Font-backed rendering context: owns a FontContext and a FontMetrics
/// wired to it — "initialize once, render many" (see context.zig).
pub const Context = context.Context;

/// Full pipeline: LaTeX source → draw list (SVG-style primitives).
///
/// The returned `DrawList`'s `text` primitives alias `src`, so `src` must
/// outlive the draw list. `size_pt` is the base font size in points.
pub fn render(gpa: std.mem.Allocator, src: []const u8, size_pt: f32) !draw.DrawList {
    var ast = try parse.parse(gpa, src);
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
    var out = try render(testing.allocator, src, 20);
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
    var out = try render(testing.allocator, src, 10);
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
    var out = try render(testing.allocator, src, 10);
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
