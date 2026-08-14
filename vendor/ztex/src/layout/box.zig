//! ztex.layout.box — superflat TeX box model.
//!
//! Same pattern as the atom AST: one flat array of fixed-size boxes, with
//! child placement stored as contiguous index runs in a parallel array. A box
//! carries its own dimensions (width/height/depth) plus a source byte span, so
//! every drawable downstream can map back to input text.
//!
//! Child placement is per-parent, so it lives in `ChildRef` (index + offsets),
//! never in the shared child box. `flatten` positions each child at
//! `(x + cr.x_shift, y + cr.shift)` uniformly.

const std = @import("std");
const atom = @import("ztex.atom");

pub const Kind = enum(u8) {
    /// children laid left→right, baseline-aligned
    hbox,
    /// children stacked vertically (fraction); positioned by shift
    vbox,
    /// a single glyph; leaf
    char,
    /// invisible; metrics only
    glue,
    /// invisible strut; metrics only
    strut,
    /// filled rectangle (fraction bar, rule); leaf
    rule,
    /// base + superscript + subscript overlay
    script,
};

/// Per-parent child placement: which box, and where relative to the parent's
/// reference point (baseline).
pub const ChildRef = struct {
    idx: u32,
    x_shift: f32,
    shift: f32,
};

/// A flat, fixed-size laid-out box.
pub const Box = struct {
    kind: Kind,
    width: f32,
    height: f32,
    depth: f32,
    /// index of the first ChildRef (into BoxList.childrefs); 0 = leaf
    first_child: u32,
    num_children: u16,
    /// char: the glyph codepoint
    cp: u21,
    /// char: effective font style
    style: atom.CharStyle,
    /// char: font size in points
    size: f32,
    // provenance: byte span into the source this box came from
    src_start: u32,
    src_end: u32,
    /// char: true when the glyph is synthesized by layout (big operators,
    /// e.g. \sum → ∑) and has no matching source bytes to alias; false for
    /// every other box, meaning the drawn glyph equals the source span.
    /// Set true only in layout.layoutOp; layoutChar/layoutText boxes take the
    /// default false.
    synthetic: bool = false,
};

pub const null_child: u32 = 0;

/// The flat box pool.
pub const BoxList = struct {
    gpa: std.mem.Allocator,
    boxes: std.ArrayList(Box) = .empty,
    childrefs: std.ArrayList(ChildRef) = .empty,
    /// Reusable per-parent placement buffer. Layout fns save `items.len`,
    /// append their placements, hand the run to `create` (which copies it
    /// into `childrefs`), then restore `items.len` — so recursive reuse
    /// never aliases a live run and the buffer is allocated once.
    scratch: std.ArrayList(ChildRef) = .empty,

    pub fn init(gpa: std.mem.Allocator) BoxList {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *BoxList) void {
        self.boxes.deinit(self.gpa);
        self.childrefs.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn get(self: *const BoxList, idx: u32) Box {
        return self.boxes.items[idx];
    }

    /// ChildRef run of a box (empty for leaves).
    pub fn children(self: *const BoxList, idx: u32) []const ChildRef {
        // Read the fields straight from the pool instead of going through
        // `get` (which copies the whole Box) — one less by-value copy per
        // parent. `get` stays by-value for callers that want a Box.
        const b = &self.boxes.items[idx];
        if (b.num_children == 0) return &.{};
        return self.childrefs.items[b.first_child .. b.first_child + b.num_children];
    }

    /// Append a box with a contiguous run of child placements; returns index.
    pub fn create(
        self: *BoxList,
        kind: Kind,
        width: f32,
        height: f32,
        depth: f32,
        placements: []const ChildRef,
        cp: u21,
        style: atom.CharStyle,
        size: f32,
        span: atom.Span,
    ) !u32 {
        const first: u32 = @intCast(self.childrefs.items.len);
        try self.childrefs.appendSlice(self.gpa, placements);
        const idx: u32 = @intCast(self.boxes.items.len);
        try self.boxes.append(self.gpa, .{
            .kind = kind,
            .width = width,
            .height = height,
            .depth = depth,
            .first_child = first,
            .num_children = @intCast(placements.len),
            .cp = cp,
            .style = style,
            .size = size,
            .src_start = span.start,
            .src_end = span.end,
        });
        return idx;
    }

    /// Append a leaf box (no children).
    pub fn createLeaf(
        self: *BoxList,
        kind: Kind,
        width: f32,
        height: f32,
        depth: f32,
        span: atom.Span,
    ) !u32 {
        return self.create(kind, width, height, depth, &.{}, 0, .italic, 0, span);
    }
};

// ── tests ────────────────────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "boxlist: leaf and parent with child placements" {
    var list = BoxList.init(testing.allocator);
    defer list.deinit();
    const a = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = 0, .end = 1 });
    const b = try list.createLeaf(.char, 5.0, 3.0, 0.5, .{ .start = 1, .end = 2 });
    const children = [_]ChildRef{
        .{ .idx = a, .x_shift = 0, .shift = 0 },
        .{ .idx = b, .x_shift = 4.0, .shift = 0 },
    };
    const h = try list.create(.hbox, 9.0, 3.0, 0.5, &children, 0, .italic, 0, .{ .start = 0, .end = 2 });
    const hb = list.get(h);
    try testing.expectEqual(@as(u16, 2), hb.num_children);
    try testing.expectEqual(@as(f32, 9.0), hb.width);
    const ch = list.children(h);
    try testing.expectEqual(@as(u32, a), ch[0].idx);
    try testing.expectEqual(@as(f32, 4.0), ch[1].x_shift);
    try testing.expectEqual(@as(u32, 0), hb.src_start);
    try testing.expectEqual(@as(u32, 2), hb.src_end);
}

test "boxlist: leaf has empty children" {
    var list = BoxList.init(testing.allocator);
    defer list.deinit();
    const c = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = 0, .end = 1 });
    try testing.expectEqual(@as(usize, 0), list.children(c).len);
}

test "boxlist: NULL_CHILD sentinel is zero" {
    try testing.expectEqual(@as(u32, 0), null_child);
}

test "boxlist: child offsets accumulate through nested parents" {
    var list = BoxList.init(testing.allocator);
    defer list.deinit();
    const a = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = 0, .end = 1 });
    const b = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = 1, .end = 2 });
    const h_children = [_]ChildRef{
        .{ .idx = a, .x_shift = 0, .shift = 0 },
        .{ .idx = b, .x_shift = 4.0, .shift = 0 },
    };
    const h = try list.create(.hbox, 8.0, 3.0, 0.5, &h_children, 0, .italic, 0, .{ .start = 0, .end = 2 });
    const v_children = [_]ChildRef{
        .{ .idx = h, .x_shift = 2.0, .shift = 5.0 },
    };
    const v = try list.create(.vbox, 8.0, 3.0, 0.5, &v_children, 0, .italic, 0, .{ .start = 0, .end = 2 });
    const h_off = list.children(v)[0].x_shift;
    const b_off = list.children(h)[1].x_shift;
    try testing.expectEqual(@as(f32, 2.0), h_off);
    try testing.expectEqual(@as(f32, 4.0), b_off);
    // 'b' sits at the sum of every ancestor x_shift
    try testing.expectApproxEqAbs(@as(f32, 6.0), h_off + b_off, 0.001);
}
