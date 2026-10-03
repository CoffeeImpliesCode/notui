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
//!
//! This module owns the pool and nothing else: it lays no formula out. A
//! `BoxList` is built by `ztex.layout.layout.layout` or by a caller's own
//! `create`/`createLeaf`, and read by `ztex.layout.draw.flatten`.

const std = @import("std");
const atom = @import("ztex.atom");

/// What a box is: a container that places children, or a leaf that draws or
/// only measures.
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
/// reference point (baseline). Offsets are added to the parent's position as
/// the flatten walk descends, so they are relative, never absolute.
pub const ChildRef = struct {
    /// Index of the child box in the owning `BoxList.boxes`.
    idx: u32,
    /// Horizontal offset from the parent's reference point, in points.
    x_shift: f32,
    /// Vertical offset from the parent's baseline, in points (down positive).
    shift: f32,
};

/// A flat, fixed-size laid-out box. Dimensions are in points at the box's
/// own font size; `height` is above the reference baseline and `depth` below.
/// A `Box` stores indices only, so a copy stays valid while its `BoxList`
/// does, and every index in it came from this pool.
pub const Box = struct {
    kind: Kind,
    /// Advance width in points.
    width: f32,
    /// Extent above the baseline in points.
    height: f32,
    /// Extent below the baseline in points; non-negative.
    depth: f32,
    /// Index of the first ChildRef in BoxList.childrefs; ignored when num_children is zero.
    first_child: u32,
    /// number of children in the contiguous run starting at `first_child`
    num_children: u16,
    /// char: the glyph codepoint
    cp: u21,
    /// char: effective font style
    style: atom.CharStyle,
    /// char: font size in points
    size: f32,
    // provenance: byte span into the source this box came from
    /// byte offset of the source range this box came from
    src_start: u32,
    /// byte offset just past that range; both must lie inside the `src` the
    /// flatten walk is given
    src_end: u32,
    /// char: true when the glyph is synthesized by layout (big operators,
    /// e.g. \sum → ∑) and has no matching source bytes to alias; false for
    /// every other box, meaning the drawn glyph equals the source span.
    /// Set true only in layout.layoutOp; layoutChar/layoutText boxes take the
    /// default false.
    synthetic: bool = false,
};

/// The flat box pool.
///
/// A `BoxList` owns `boxes`, `childrefs` and the reusable `scratch`, and
/// allocates all three from the `gpa` given to `init`; `deinit` releases them
/// and nothing else. Copying a `BoxList` copies the three handles, not the
/// storage, so a copy is not a second owner and must not be `deinit`'d
/// separately: exactly one `deinit` per `init`. Indices are only valid for
/// as long as the list is, and a `Box` or `ChildRef` value read out of one
/// stays readable while it is.
///
/// `create` and `createLeaf` append, so an index handed out earlier keeps
/// naming its own box. The pool is scratch for one layout pass: the three
/// `ztex.layout` entry points that use it free it before returning.
pub const BoxList = struct {
    /// Allocator for all three pools; owned by the caller.
    gpa: std.mem.Allocator,
    /// The boxes, in creation order.
    boxes: std.ArrayList(Box) = .empty,
    /// Child placements, in the contiguous runs `create` wrote.
    childrefs: std.ArrayList(ChildRef) = .empty,
    /// Reusable per-parent placement buffer. Layout fns save `items.len`,
    /// append their placements, hand the run to `create` (which copies it
    /// into `childrefs`), then restore `items.len` — so recursive reuse
    /// never aliases a live run and the buffer is allocated once. Its
    /// contents are meaningful only inside that layout call.
    scratch: std.ArrayList(ChildRef) = .empty,

    /// An empty pool, allocating nothing yet. `gpa` is not released by
    /// `deinit`.
    pub fn init(gpa: std.mem.Allocator) BoxList {
        return .{ .gpa = gpa };
    }

    /// Release all three pools. `gpa` is not released. Every index, `Box`
    /// and `ChildRef` taken from the list is invalid afterward, and a second
    /// call is a double free.
    pub fn deinit(self: *BoxList) void {
        self.boxes.deinit(self.gpa);
        self.childrefs.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
        self.* = undefined;
    }

    /// A copy of box `idx`, which must be below `boxes.items.len`. The copy
    /// is independent of the pool's storage and stays readable until
    /// `deinit`.
    pub fn get(self: *const BoxList, idx: u32) Box {
        return self.boxes.items[idx];
    }

    /// The `ChildRef` run of box `idx`, borrowing the pool; empty for a
    /// leaf. The result is invalidated by the next `create` and by
    /// `deinit`, so read it before laying out the next box.
    pub fn children(self: *const BoxList, idx: u32) []const ChildRef {
        // Read the fields straight from the pool instead of going through
        // `get` (which copies the whole Box) — one less by-value copy per
        // parent. `get` stays by-value for callers that want a Box.
        const b = &self.boxes.items[idx];
        if (b.num_children == 0) return &.{};
        return self.childrefs.items[b.first_child .. b.first_child + b.num_children];
    }

    /// Append a box with a contiguous run of child placements and return its
    /// index. `placements` are COPIED, so the caller's slice need not stay
    /// alive; each entry's `idx` must already name a box in this pool.
    /// `cp`, `style` and `size` describe a `.char` box and are ignored by the
    /// other kinds; `span` must lie inside the source the box came from.
    ///
    /// Both pools are reserved before either is written, so
    /// `error.OutOfMemory` leaves the pool exactly as it was and no index is
    /// produced.
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
        try self.childrefs.ensureUnusedCapacity(self.gpa, placements.len);
        try self.boxes.ensureUnusedCapacity(self.gpa, 1);
        const first: u32 = @intCast(self.childrefs.items.len);
        const idx: u32 = @intCast(self.boxes.items.len);
        self.childrefs.appendSliceAssumeCapacity(placements);
        self.boxes.appendAssumeCapacity(.{
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

    /// Append a box with no children and return its index: `create` with an
    /// empty placement run. The leaf's `cp` is 0, its `style` `.italic` and
    /// its `size` 0, so a `.char` leaf created this way must have its `size`
    /// and `cp` set by the caller before it is read. On
    /// `error.OutOfMemory` nothing is appended.
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
