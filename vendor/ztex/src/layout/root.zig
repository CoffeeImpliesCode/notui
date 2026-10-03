//! ztex.layout — atom tree → superflat box tree → draw list.
//!
//! Usable on its own: give it any `atom.Ast` (from ztex.parse or hand-built)
//! plus a root node index, and it produces an SVG-style `draw.DrawList`.
//!
//! The two stages are separate: `ztex.layout.layout.layout` builds the box
//! pool, and `ztex.layout.draw.flatten` turns a box pool into primitives.
//! `render` below runs both and frees the box pool, which is why it is the
//! entry point a consumer normally wants.
//!
//! Nothing here reads a font file or a `std.Io`: `render` measures from the
//! bundled static tables via `metrics.default`. The font-backed pipeline is
//! `ztex.Context`, which supplies a `metrics.FontMetrics` of its own.

const std = @import("std");
const atom = @import("ztex.atom");

/// `ztex.layout.metrics`: the bundled metric tables and `FontMetrics`.
pub const metrics = @import("metrics.zig");

/// `ztex.layout.box`: the superflat box pool the layout pass fills.
pub const box = @import("box.zig");

/// `ztex.layout.draw`: the draw model, re-exported at the layout root.
pub const draw = @import("draw.zig");

/// `ztex.layout.layout`: the layout pass itself.
pub const layout = @import("layout.zig");

/// TeX math style; an alias of `ztex.atom.MathStyle`, so a style value is
/// the same type in a parser node's `data` and in a layout call.
pub const Style = layout.Style;

/// Lay out the atom tree rooted at `root` and flatten it to a draw list,
/// measured from the bundled static tables via `metrics.default`.
///
/// The returned `DrawList`'s `Text.bytes` alias `ast.src` — or the draw
/// list's own glyph arena for a synthesized glyph — so `ast.src` must
/// outlive the draw list, which the caller releases with `deinit`. `root`
/// must index a node in `ast`, and `size_pt` is the base font size in
/// points. Nothing is read from the file system and no `std.Io` is needed.
///
/// On `error.OutOfMemory` or `error.InvalidTable` the box pool is released
/// and no draw list is returned, so nothing partial survives.
pub fn render(
    gpa: std.mem.Allocator,
    ast: *const atom.Ast,
    root: u32,
    size_pt: f32,
) !draw.DrawList {
    var list = box.BoxList.init(gpa);
    defer list.deinit();
    // Pre-reserve a safe over-bound: a single node can emit more boxes than
    // itself (1 scripted op node → 3 boxes; 1 text node → N grapheme boxes),
    // so reserve 2× nodes for the pools plus one per node for the reusable
    // placement scratch. These are capacity-only hints; they remove the
    // geometric realloc/copy churn in BoxList.create without touching any
    // geometry. Under-reserving is graceful (the pool grows on demand).
    try list.boxes.ensureTotalCapacity(gpa, ast.nodes.items.len);
    try list.childrefs.ensureTotalCapacity(gpa, ast.nodes.items.len);
    try list.scratch.ensureTotalCapacity(gpa, ast.nodes.items.len);
    const root_box = try layout.layout(&list, ast, root, &metrics.default, .display, size_pt, .italic);
    var out = draw.DrawList.init(gpa);
    errdefer out.deinit();
    // Capacity-only hint: flatten emits at most one draw per box, and boxes
    // can exceed nodes (see above).
    try out.items.ensureTotalCapacity(gpa, ast.nodes.items.len);
    try draw.flatten(&list, root_box, ast.src, 0, 0, &out);
    const rb = list.get(root_box);
    out.width = rb.width;
    out.height = rb.height;
    out.depth = rb.depth;
    return out;
}

// ── tests ────────────────────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "render: a single char yields one text primitive" {
    var ast = atom.Ast.init(testing.allocator, "x");
    defer ast.deinit();
    try ast.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    _ = try ast.createLeaf(.char, 0, 1, 0); // node 0: a char leaf
    var out = try render(testing.allocator, &ast, 0, 20);
    defer out.deinit();
    try testing.expectEqual(@as(usize, 1), out.len());
    try testing.expectEqualStrings("𝑥", out.items.items[0].text.bytes);
    try testing.expectEqual(@as(f32, 20), out.items.items[0].text.size);
}
