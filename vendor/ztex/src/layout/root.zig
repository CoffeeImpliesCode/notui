//! ztex.layout — atom tree → superflat box tree → draw list.
//!
//! Usable on its own: give it any `atom.Ast` (from ztex.parse or hand-built)
//! plus a root node index, and it produces an SVG-style `draw.DrawList`.

const std = @import("std");
const atom = @import("ztex.atom");

pub const metrics = @import("metrics.zig");
pub const box = @import("box.zig");
pub const draw = @import("draw.zig");
pub const layout = @import("layout.zig");

pub const Style = layout.Style;

/// Lay out an atom tree and flatten it to a draw list.
///
/// The returned `DrawList`'s `text` primitives alias `ast.src`, so the source
/// (and ast) must outlive the draw list. The box pool is scratch and freed.
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
