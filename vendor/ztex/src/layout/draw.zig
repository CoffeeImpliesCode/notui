//! ztex.layout.draw — SVG-style draw model + box→draw flattening.
//!
//! The terminal artifact of the pipeline: a flat, painter-ordered list of
//! primitives (`text` / `rect` / `line`) at absolute coordinates. Backend
//! neutral — trivially emitted as SVG or consumed by any renderer.
//!
//! Every primitive carries the byte span (into the original source) of the box
//! it came from, so any output drawable maps back to its input text/tokens in
//! O(1) — the provenance requirement.
//!
//! Coordinates are baseline-anchored: `y` is the baseline, and ascent is
//! negative. `ztex.svg` and the terminal rasterizers flip that convention
//! themselves.

const std = @import("std");
const box = @import("box.zig");
/// `ztex.atom`, re-exported so a `draw` consumer reaches `CharStyle` and
/// `Span` through one import.
pub const atom = @import("ztex.atom");

/// A straight-alpha RGBA colour; each channel 0-255. `a` is 255 unless the
/// caller sets it, and no drawable in this module produces a partial alpha.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
};

/// A drawable primitive.
pub const Draw = union(enum) {
    /// a glyph run at its baseline (x, y)
    text: Text,
    /// a filled rectangle (fraction bars, rules, radical bars)
    rect: Rect,
    /// a stroked line (decorations)
    line: Line,
};

/// One glyph run.
///
/// `bytes` has two owners depending on the box it came from, and the
/// difference decides what must stay alive: a box whose bytes exist in the
/// formula source aliases that source, so the source must outlive this
/// primitive; a box whose glyph was synthesized by layout (a big operator,
/// `\sum` → `∑`) has no source bytes and borrows the owning `DrawList`'s
/// `glyph_arena` instead, so the DRAW LIST must outlive the primitive. The
/// two regimes are not distinguishable from the primitive alone — decide
/// from the draw list's lifetime, which is the safe assumption either way.
/// `src_start`/`src_end` always name the source range the box came from,
/// which for a synthetic glyph is the command that produced it.
pub const Text = struct {
    /// UTF-8 glyph bytes; borrowed as described above, never copied.
    bytes: []const u8,
    /// baseline position in output coordinates
    x: f32,
    y: f32,
    /// font size in points
    size: f32,
    /// effective font style (\text/\mathrm = roman, variables = italic, …)
    style: atom.CharStyle,
    color: Color,
    /// byte offset of the source range this glyph came from
    src_start: u32,
    /// byte offset just past that range
    src_end: u32,
};

/// A filled rectangle spanning `[x, x+w)` × `[y, y+h)` in output
/// coordinates. `src_start`/`src_end` name the source range it came from.
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: Color,
    src_start: u32,
    src_end: u32,
};

/// A stroked segment of `width` points centred on the line from
/// `(x0, y0)` to `(x1, y1)`. `src_start`/`src_end` name the source range it
/// came from.
pub const Line = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    color: Color,
    width: f32,
    src_start: u32,
    src_end: u32,
};

/// The flat, ordered draw list. Painter's order; absolute coordinates.
///
/// A `DrawList` owns its `items` and the `glyph_arena` holding every
/// synthesized glyph a `Text.bytes` slice can point into; `deinit` releases
/// both. The allocator and the formula source are NOT released here — the
/// source is borrowed by most `Text.bytes` and must outlive the list.
/// Copying a `DrawList` copies both handles, not the storage, so a copy is
/// not a second owner and must not be `deinit`'d separately: exactly one
/// `deinit` per `init`.
pub const DrawList = struct {
    /// Allocator for `items` and the glyph arena; owned by the caller.
    gpa: std.mem.Allocator,
    /// The primitives, in painter's order: later entries draw over earlier.
    items: std.ArrayList(Draw) = .empty,
    /// arena for generated glyphs (e.g. big-operator ∑) that have no source
    /// bytes; frees with the draw list
    glyph_arena: std.heap.ArenaAllocator,
    /// Laid-out bounds in points: `width` across, `height` above the
    /// baseline and `depth` below it, so the ink spans
    /// `[0, width] × [-height, depth]` around the origin. Zero until a
    /// renderer fills them in.
    width: f32 = 0,
    height: f32 = 0,
    depth: f32 = 0,

    /// An empty draw list with zero bounds, allocating nothing yet. `gpa`
    /// backs both the item list and the glyph arena and is not released by
    /// `deinit`.
    pub fn init(gpa: std.mem.Allocator) DrawList {
        return .{
            .gpa = gpa,
            .glyph_arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    /// Release the item list and the glyph arena. `gpa` and the borrowed
    /// source are not released. Every primitive and every `Text.bytes` slice
    /// borrowed from the glyph arena is invalid afterward, and a second call
    /// is a double free.
    pub fn deinit(self: *DrawList) void {
        self.items.deinit(self.gpa);
        self.glyph_arena.deinit();
        self.* = undefined;
    }

    /// Append one primitive at the end, so it paints over the ones already
    /// there. Nothing in `d` is copied beyond the struct itself: a `Text`
    /// keeps borrowing whatever its `bytes` pointed at. On
    /// `error.OutOfMemory` nothing is appended.
    pub fn add(self: *DrawList, d: Draw) !void {
        try self.items.append(self.gpa, d);
    }

    /// The number of primitives, the same as `items.items.len`.
    pub fn len(self: *const DrawList) usize {
        return self.items.items.len;
    }
};

const black: Color = .{ .r = 0, .g = 0, .b = 0 };

/// Flatten a box tree into `out` in painter's order.
///
/// `(x, y)` is the root box's reference point (its baseline). Children are
/// placed at `(x + cr.x_shift, y + cr.shift)`, the offsets layout computed,
/// and the recursion stops at `root`'s subtree. `root` must index a box in
/// `list`, and every box's `src_start`/`src_end` must lie inside `src`.
///
/// Every `Text` appended borrows `src` for its bytes, except a synthetic
/// glyph's, which is duplicated into `out.glyph_arena` — see `Text`. `src`
/// must therefore outlive `out`, and `out` must outlive every `Text.bytes`
/// taken from it.
///
/// Primitives emitted before an `error.OutOfMemory` stay in `out`, so a
/// caller that wants an all-or-nothing result discards `out` on error; the
/// glyph arena's allocations survive with it until `out.deinit`.
///
/// Recurses once per box level, so it is bounded by the box tree's depth.
pub fn flatten(
    list: *const box.BoxList,
    root: u32,
    src: []const u8,
    x: f32,
    y: f32,
    out: *DrawList,
) !void {
    const b = list.get(root);
    switch (b.kind) {
        .char => {
            // The drawn glyph is the box's codepoint. Normally its utf-8
            // equals the source span bytes (zero copy); a synthetic box (a
            // big operator like \sum → ∑) has no matching source bytes, so
            // its glyph is duped into the glyph arena. Synthetic is the sole
            // non-alias case — no byte comparison needed.
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(b.cp, &buf) catch 0;
            const bytes = if (b.synthetic)
                try out.glyph_arena.allocator().dupe(u8, buf[0..n])
            else
                src[b.src_start..b.src_end];
            try out.add(.{ .text = .{
                .bytes = bytes,
                .x = x,
                .y = y,
                .size = b.size,
                .style = b.style,
                .color = black,
                .src_start = b.src_start,
                .src_end = b.src_end,
            } });
        },
        .rule => {
            try out.add(.{ .rect = .{
                .x = x,
                .y = y - b.height,
                .w = b.width,
                .h = b.height + b.depth,
                .color = black,
                .src_start = b.src_start,
                .src_end = b.src_end,
            } });
        },
        .glue, .strut => {}, // metrics only; nothing to draw
        .hbox, .vbox, .script => {
            for (list.children(root)) |cr| {
                try flatten(list, cr.idx, src, x + cr.x_shift, y + cr.shift, out);
            }
        },
    }
}

// ── tests ────────────────────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "flatten: char emits text with provenance" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    const src = "x+1";
    const c = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = 0, .end = 1 });
    // tag the char box's cp/size so flatten can build a text primitive
    list.boxes.items[c].size = 10.0;
    list.boxes.items[c].cp = 'x';
    try flatten(&list, c, src, 0, 10, &out);
    try testing.expectEqual(@as(usize, 1), out.len());
    const t = out.items.items[0].text;
    try testing.expectEqualStrings("x", t.bytes);
    try testing.expectEqual(@as(f32, 0), t.x);
    try testing.expectEqual(@as(f32, 10), t.y);
    try testing.expectEqual(@as(f32, 10), t.size);
    try testing.expectEqual(@as(u32, 0), t.src_start);
    try testing.expectEqual(@as(u32, 1), t.src_end);
}

test "flatten: rule emits rect; glue emits nothing" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    const r = try list.createLeaf(.rule, 10.0, 0.2, 0.2, .{ .start = 3, .end = 4 });
    try flatten(&list, r, "x+1", 5, 20, &out);
    try testing.expectEqual(@as(usize, 1), out.len());
    const rect = out.items.items[0].rect;
    try testing.expectEqual(@as(f32, 5), rect.x);
    try testing.expectEqual(@as(f32, 20 - 0.2), rect.y);
    try testing.expectEqual(@as(f32, 10), rect.w);
    try testing.expectEqual(@as(f32, 0.4), rect.h);
    try testing.expectEqual(@as(u32, 3), rect.src_start);
    try testing.expectEqual(@as(u32, 4), rect.src_end);
}

test "flatten: hbox walks children in order" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    const src = "ab";
    const a = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = 0, .end = 1 });
    const b = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = 1, .end = 2 });
    list.boxes.items[a].size = 10.0;
    list.boxes.items[b].size = 10.0;
    list.boxes.items[a].cp = 'a';
    list.boxes.items[b].cp = 'b';
    const children = [_]box.ChildRef{
        .{ .idx = a, .x_shift = 0, .shift = 0 },
        .{ .idx = b, .x_shift = 4.0, .shift = 0 },
    };
    const h = try list.create(.hbox, 8.0, 3.0, 0.5, &children, 0, .italic, 0, .{ .start = 0, .end = 2 });
    try flatten(&list, h, src, 0, 10, &out);
    try testing.expectEqual(@as(usize, 2), out.len());
    try testing.expectEqualStrings("a", out.items.items[0].text.bytes);
    try testing.expectEqualStrings("b", out.items.items[1].text.bytes);
    try testing.expectEqual(@as(f32, 4.0), out.items.items[1].text.x);
}

test "flatten: vbox recurses into children" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    const src = "ab";
    const a = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = 0, .end = 1 });
    const b = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = 1, .end = 2 });
    list.boxes.items[a].size = 10.0;
    list.boxes.items[b].size = 10.0;
    list.boxes.items[a].cp = 'a';
    list.boxes.items[b].cp = 'b';
    const children = [_]box.ChildRef{
        .{ .idx = a, .x_shift = 1.0, .shift = -2.0 },
        .{ .idx = b, .x_shift = 5.0, .shift = 3.0 },
    };
    const v = try list.create(.vbox, 9.0, 6.0, 4.0, &children, 0, .italic, 0, .{ .start = 0, .end = 2 });
    try flatten(&list, v, src, 10, 20, &out);
    try testing.expectEqual(@as(usize, 2), out.len());
    const t0 = out.items.items[0].text;
    try testing.expectEqualStrings("a", t0.bytes);
    try testing.expectEqual(@as(f32, 11), t0.x); // 10 + x_shift 1
    try testing.expectEqual(@as(f32, 18), t0.y); // 20 + shift -2
    const t1 = out.items.items[1].text;
    try testing.expectEqualStrings("b", t1.bytes);
    try testing.expectEqual(@as(f32, 15), t1.x); // 10 + x_shift 5
    try testing.expectEqual(@as(f32, 23), t1.y); // 20 + shift 3
}

test "flatten: script box recurses into base and superscript" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    const src = "x2";
    const base = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = 0, .end = 1 });
    const sup = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = 1, .end = 2 });
    list.boxes.items[base].size = 10.0;
    list.boxes.items[sup].size = 10.0;
    list.boxes.items[base].cp = 'x';
    list.boxes.items[sup].cp = '2';
    const children = [_]box.ChildRef{
        .{ .idx = base, .x_shift = 0, .shift = 0 },
        .{ .idx = sup, .x_shift = 4.0, .shift = -3.0 },
    };
    const s = try list.create(.script, 8.0, 6.0, 0.5, &children, 0, .italic, 0, .{ .start = 0, .end = 2 });
    try flatten(&list, s, src, 0, 10, &out);
    try testing.expectEqual(@as(usize, 2), out.len());
    try testing.expectEqualStrings("x", out.items.items[0].text.bytes);
    try testing.expectEqualStrings("2", out.items.items[1].text.bytes);
    try testing.expectEqual(@as(f32, 4.0), out.items.items[1].text.x);
    try testing.expectEqual(@as(f32, 7.0), out.items.items[1].text.y); // 10 + shift -3
}

test "flatten: strut emits nothing" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    const st = try list.createLeaf(.strut, 2.0, 3.0, 1.0, .{ .start = 0, .end = 1 });
    try flatten(&list, st, "x", 0, 0, &out);
    try testing.expectEqual(@as(usize, 0), out.len());
}
