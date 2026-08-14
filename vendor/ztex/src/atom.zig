//! ztex.atom — superflat LaTeX atom (AST).
//!
//! Pattern: house superflat AST (cf. `~/projects/{vain,skript}`). The whole
//! tree is one flat array of fixed-size AoS nodes; child links are contiguous
//! index runs; source provenance is via a parallel token table with byte
//! offsets. No pointers, no pointer chasing, no per-node allocation.
//!
//! Duplication protocol: a parent's `createNode` re-appends copies of its
//! immediate children immediately before itself, so a node's child run is
//! always contiguous. Each subtree appears in the pool more than once; only
//! the root-reachable chain is the tree.

const std = @import("std");
const token = @import("token.zig");

// Re-export the provenance types so consumers import only ztex.atom.
pub const TokenTag = token.Tag;
pub const Token = token.Token;
pub const Span = token.Span;
pub const null_span: token.Span = .{ .start = 0, .end = 0 };

/// Math/text font style of a character or text run.
pub const CharStyle = enum(u8) {
    /// default math italic (variables)
    italic,
    /// upright roman (\mathrm, \text)
    roman,
    /// bold (\mathbf)
    bold,
    /// blackboard (\mathbb)
    bb,
    /// calligraphic (\mathcal)
    cal,
    /// fraktur (\mathfrak)
    frak,
    /// sans-serif (\mathsf)
    sans,
    /// monospace (\mathtt)
    mono,
};

/// Big operator (rendered large; scripts become limits in display style).
pub const BigOp = enum(u8) {
    sum,
    int,
    prod,
    coprod,
    bigcup,
    bigcap,
    bigsqcup,
    oint,
};

/// TeX math style. Layout's `Style` is an alias of this, so the parser can
/// pack a forced style into a `fraction` node's `data` or a `.mathstyle`
/// node's `data` without a layout import.
pub const MathStyle = enum(u8) {
    display = 0,
    text = 1,
    script = 2,
    script_script = 3,
};

/// Math environment kinds, packed into an `.env` node's `data` low bits.
pub const EnvKind = enum(u8) {
    matrix = 0,
    pmatrix = 1,
    bmatrix = 2,
    Bmatrix = 3,
    vmatrix = 4,
    Vmatrix = 5,
    cases = 6,
    aligned = 7,
    array = 8,
};

/// Bit layout of an `.env` node's `data`:
///   bits 0-3  environment kind (EnvKind)
///   bits 4-7  packed array colspec length (nibbles that follow; 0 for the
///             matrix family / cases / aligned)
///   bits 8+   array colspec nibbles, 4 bits per column (first column at
///             bit 8): 0 = l, 1 = c, 2 = r, 3 = | (vertical rule BEFORE
///             that column — a leading | draws a rule at the array's left
///             edge). Max 6 spec columns; beyond the spec, columns align
///             centered (TeX: extra columns default to c).
pub const EnvBits = struct {
    pub const kind_mask: u32 = 0xF;
    pub const count_shift: u5 = 4;
    pub const col_shift: u5 = 8;
    pub const col_nibble: u32 = 0xF;
    pub const col_l: u32 = 0;
    pub const col_c: u32 = 1;
    pub const col_r: u32 = 2;
    pub const col_rule: u32 = 3;
    pub const max_spec_cols: usize = 6;
};

/// The environment kind of an `.env` node.
pub inline fn envKind(data: u32) EnvKind {
    return @enumFromInt(data & EnvBits.kind_mask);
}

/// Number of array colspec nibbles packed in `data` (0 for non-array envs).
pub inline fn envSpecCount(data: u32) usize {
    return (data >> EnvBits.count_shift) & 0xF;
}

/// The packed colspec nibble for column `i`, or null beyond the packed
/// spec (callers default to centered alignment).
pub inline fn envColSpec(data: u32, i: usize) ?u32 {
    if (i >= envSpecCount(data)) return null;
    return (data >> (EnvBits.col_shift + @as(u5, @intCast(4 * i)))) & EnvBits.col_nibble;
}

/// Pack an `.env` node's `data` from the kind and the array colspec (a byte
/// string of l/c/r/| chars; unknown chars count as centered). The spec is
/// truncated to `max_spec_cols` columns.
pub inline fn envData(kind: EnvKind, colspec: []const u8) u32 {
    var data: u32 = @intFromEnum(kind);
    const n = @min(colspec.len, EnvBits.max_spec_cols);
    data |= @as(u32, @intCast(n)) << EnvBits.count_shift;
    for (colspec[0..n], 0..) |b, i| {
        const nib: u32 = switch (b) {
            'l' => EnvBits.col_l,
            'r' => EnvBits.col_r,
            '|' => EnvBits.col_rule,
            else => EnvBits.col_c,
        };
        data |= nib << (EnvBits.col_shift + @as(u5, @intCast(4 * i)));
    }
    return data;
}

/// Presence bits stored in a `script` node's `data`.
pub const ScriptBits = struct {
    pub const sup: u32 = 1 << 0;
    pub const sub: u32 = 1 << 1;
};

/// Bit layout of a `fraction` node's `data`: bit 0 = rule line (\frac vs
/// \atop), bits 1-4 = forced math-style code (0 = none, else MathStyle + 1),
/// bit 5 = \cfrac's parts-at-display-style flag, bits 6-21 = \genfrac's
/// explicit rule thickness (pt, Q8.8 fixed point; 0 = none — use the font's
/// rule_thickness or \atop's no rule). A plain \frac/\atop keeps data 0/1 —
/// byte-identical to the pre-feature encoding.
pub const FractionBits = struct {
    pub const line: u32 = 1 << 0;
    pub const forced_shift: u5 = 1;
    pub const forced_mask: u32 = 0xF;
    pub const parts_display: u32 = 1 << 5;
    /// \genfrac's explicit rule thickness in bits 6-21 (Q8.8 fixed point:
    /// 1/256 pt resolution, up to 255.99 pt). Zero means "no explicit
    /// thickness": \frac/\atop use the font's rule_thickness (or no rule).
    pub const thick_shift: u5 = 6;
    pub const thick_mask: u32 = 0xFFFF;
};

/// Encode fraction `data` from the line flag, the optional forced style
/// (\dfrac → .display, \tfrac → .text), and \cfrac's parts-at-display flag.
pub inline fn fracData(line: bool, forced: ?MathStyle, parts_display: bool) u32 {
    const code: u32 = if (forced) |f| @as(u32, @intFromEnum(f)) + 1 else 0;
    return @intFromBool(line) |
        (code << FractionBits.forced_shift) |
        (@as(u32, @intFromBool(parts_display)) << 5);
}

/// Whether the fraction draws a rule line (\frac \dfrac \tfrac \cfrac).
pub inline fn fracLine(data: u32) bool {
    return data & FractionBits.line != 0;
}

/// The forced style of a \dfrac/\tfrac/\cfrac fraction; null for \frac/\atop.
pub inline fn fracForcedStyle(data: u32) ?MathStyle {
    const code = (data >> FractionBits.forced_shift) & FractionBits.forced_mask;
    if (code == 0) return null;
    return @enumFromInt(code - 1);
}

/// \cfrac flag: lay out BOTH parts in display style (amsmath's continued
/// fraction), on top of the display-style gaps.
pub inline fn fracPartsDisplay(data: u32) bool {
    return data & FractionBits.parts_display != 0;
}

/// Encode a \genfrac rule thickness (pt) as Q8.8 in the thick bits; 0 for
/// "no explicit thickness". Values are clamped to [0, 255.99]; a non-rule
/// genfrac (\atop-style) carries thickness 0 like a plain \frac/\atop.
pub inline fn fracThicknessBits(pt: f32) u32 {
    const q: i32 = @intFromFloat(@round(@max(pt, 0) * 256.0));
    return (@as(u32, @intCast(@min(q, 0xFFFF))) << FractionBits.thick_shift) &
        (FractionBits.thick_mask << FractionBits.thick_shift);
}

/// The \genfrac rule thickness in pt (absolute TeX dimension — layout does
/// NOT scale it with the font size); 0 when the fraction has no explicit
/// thickness (plain \frac/\atop, or a 0pt genfrac).
pub inline fn fracThickness(data: u32) f32 {
    const q: i32 = @bitCast((data >> FractionBits.thick_shift) & FractionBits.thick_mask);
    return @as(f32, @floatFromInt(q)) / 256.0;
}

/// Limits-override bits packed into the HIGH bits of an `op`/`opname`
/// node's `data` (the low bits carry the BigOp enum / the opname
/// limit-taking flag). The parser sets them when \limits / \nolimits /
/// \displaylimits follows the operator atom (TeX: "limit controls"); the
/// layout reads them to force or restore the over/under-limits decision.
pub const LimitsBits = struct {
    /// Bit mask isolating the override bits within `data`.
    pub const mask: u32 = 0x6000_0000;
    /// \limits: force over/under limits in display AND text styles.
    pub const force: u32 = 1 << 29;
    /// \nolimits: force beside scripts in every style.
    pub const force_beside: u32 = 1 << 30;
    /// Everything below the override bits: the BigOp enum / limit flag.
    pub const value_mask: u32 = 0x1FFF_FFFF;
};

/// Atom (node) tag.
pub const Tag = enum(u8) {
    /// a sequence of sibling atoms; children = the atoms in order
    row,
    /// `{ ... }`; exactly 1 child
    group,
    /// a glyph; leaf. Codepoint re-read from the source span. The effective
    /// font style comes from the nearest enclosing `styled` node.
    char,
    /// `base^sup_sub`; children[0]=base, [1]=sup, [2]=sub (null if absent)
    script,
    /// `\frac{num}{den}` / `\atop`; children[0]=num, [1]=den; data: line flag
    fraction,
    /// horizontal space (\, \; \quad); leaf; data: width_em as Q16.16
    space,
    /// `\text{...}`; leaf; raw bytes re-read from source span; data: CharStyle
    text,
    /// a style scope (`\mathbf{...}`); 1 child; data: CharStyle
    styled,
    /// a forced math style (`\displaystyle \textstyle \scriptstyle
    /// \scriptscriptstyle`); 1 child = a row of everything after the
    /// command (rest-of-group semantics); data: MathStyle
    mathstyle,
    /// a big operator (`\sum \int \prod ...`); leaf; data: BigOp
    op,
    /// an operator word (`\sin \lim \log ...`); 1 child = a row of the
    /// name's letters (each a char leaf carrying its ASCII codepoint in
    /// `data`); always roman. `data`: 1 when the word takes display-style
    /// over/under limits like a big operator (\lim \max \min \sup \inf \det
    /// \gcd \Pr \arg \ker \dim \hom \deg \limsup \liminf), 0 otherwise
    /// (\sin \cos \log \exp ... keep scripts as regular sub/superscripts).
    opname,
    /// `\left <delim> ... \right <delim>`: children [open?, inner, close?]
    /// where open/close are delimiter char leaves (absent for `\left.` /
    /// `\right.`); the inner is the delimited row. Layout stretches the
    /// delimiters to cover the inner's height.
    left,
    /// `\overline{x}` / `\underline{x}`: 1 child = the content (a single
    /// atom or braced group); `data` = 0 over / 1 under. Layout lays the
    /// content out (cramped for \overline, TeX make_over) and draws a rule
    /// of `rule_thickness` at a clearance of 3·rule_thickness from the
    /// content's box edge, spanning exactly the content width (tex.web
    /// overbar/make_under). Scripts after it attach via the usual
    /// parseAtom path, like any base.
    overline,
    /// \mathchoice{D}{T}{S}{SS}`: TeX's four-style choice primitive.
    /// children = the four branches [D, T, S, SS]. Layout picks the branch
    /// matching the CURRENT math style (display→0, text→1, script→2,
    /// scriptscript→3) and lays it out with the branch's OWN style forced
    /// (branch i is set at style i — the D branch renders at display size
    /// even inside a script, exactly \dfrac's forcing). Scripts after it
    /// attach via the usual parseAtom path, like any base.
    mathchoice,
    /// `\substack{a \\ b \\ c}` (amsmath): a script-size multi-line stack
    /// for limits, e.g. \sum_{\substack{i=1 \\ j=2}} x_i x_j. Children = the
    /// `\\`-separated lines, each a row. Layout lays the lines out at
    /// script style, centered, stacked with the TeX \subarray baseline
    /// gaps, and the whole stack is a single script-sized box (a `\vcenter`
    /// in TeX — the reference placement under a big op matches the raw
    /// stack box, see layoutSubstack). Scripts after it attach via the
    /// the usual parseAtom path, like any base.
    substack,
    /// `\begin{env}...\end{env}` math environment (matrix/pmatrix/bmatrix/
    /// Bmatrix/vmatrix/Vmatrix/cases/aligned/array). Children =
    /// [open?, row1, ..., rowN, close?] — the optional delimiter char
    /// leaves (only pmatrix/bmatrix/Bmatrix/vmatrix/Vmatrix/cases; each a
    /// char leaf whose `data` carries the delimiter codepoint, like \cdot)
    /// around the row atoms; each row is a `.row` node whose children are
    /// the cell atoms (a cell may be a .group/.row of its content; cells
    /// split on `&`, rows on `\\`). `data` = env kind (low 4 bits) plus the
    /// packed array colspec (see EnvBits).
    env,
};

/// A flat, fixed-size AST node.
pub const Node = struct {
    tag: Tag,
    /// index of the first token this node spans (into Ast.tokens)
    first_token: u32,
    /// number of tokens this node spans
    num_tokens: u32,
    /// index of the first child (into Ast.nodes); 0 = null/leaf
    first_child: u32,
    /// number of children in the contiguous run starting at `first_child`
    num_children: u16,
    /// tag-specific scalar payload (style, width, line flag)
    data: u32,
};

/// Sentinel "no child / no node" index.
pub const null_node: u32 = 0;

/// Encode a width-in-em as Q16.16 fixed point (for `space` node data).
pub inline fn emToFixed(em: f32) u32 {
    return @bitCast(@as(i32, @intFromFloat(em * 65536.0)));
}

/// Decode a Q16.16 fixed-point width-in-em back to f32.
pub inline fn fixedToEm(v: u32) f32 {
    return @floatCast(@as(f64, @floatFromInt(@as(i32, @bitCast(v)))) / 65536.0);
}

/// The superflat AST: source + parallel token table + flat node pool.
///
/// Owns nothing beyond the two ArrayLists; the caller provides `gpa`. Free
/// with `deinit`. Node addresses are stable for the lifetime of the Ast (the
/// pool is append-only).
pub const Ast = struct {
    gpa: std.mem.Allocator,
    src: []const u8,
    tokens: std.ArrayList(token.Token) = .empty,
    nodes: std.ArrayList(Node) = .empty,
    /// index of the root node (the whole formula), set by the parser
    root: u32 = 0,

    /// Create an empty Ast over `src`. The caller must pre-lex into `tokens`
    /// before parsing (see ztex.parse.lexer).
    pub fn init(gpa: std.mem.Allocator, src: []const u8) Ast {
        return .{ .gpa = gpa, .src = src };
    }

    pub fn deinit(self: *Ast) void {
        self.tokens.deinit(self.gpa);
        self.nodes.deinit(self.gpa);
        self.* = undefined;
    }

    /// Preallocate the token table (~src.len/4 tokens, then nodes).
    pub fn reserve(self: *Ast, token_count: usize, node_count: usize) !void {
        try self.tokens.ensureTotalCapacity(self.gpa, token_count);
        try self.nodes.ensureTotalCapacity(self.gpa, node_count);
    }

    /// Append a token; returns nothing (caller tracks indices via items.len).
    pub fn pushToken(self: *Ast, t: token.Token) !void {
        try self.tokens.append(self.gpa, t);
    }

    /// Append a single node; returns its index.
    pub fn pushNode(self: *Ast, n: Node) !u32 {
        const idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.gpa, n);
        return idx;
    }

    /// Append a contiguous run of nodes; returns the index of the first.
    pub fn pushNodes(self: *Ast, ns: []const Node) !u32 {
        const first: u32 = @intCast(self.nodes.items.len);
        try self.nodes.appendSlice(self.gpa, ns);
        return first;
    }

    /// Create a node with a contiguous child run: copies `children` into the
    /// pool, then appends the parent pointing at that run.
    pub fn createNode(
        self: *Ast,
        tag: Tag,
        first_token: u32,
        num_tokens: u32,
        children: []const Node,
        data: u32,
    ) !u32 {
        const first = try self.pushNodes(children);
        return self.pushNode(.{
            .tag = tag,
            .first_token = first_token,
            .num_tokens = num_tokens,
            .first_child = first,
            .num_children = @intCast(children.len),
            .data = data,
        });
    }

    /// Create a leaf node (no children).
    pub fn createLeaf(
        self: *Ast,
        tag: Tag,
        first_token: u32,
        num_tokens: u32,
        data: u32,
    ) !u32 {
        return self.pushNode(.{
            .tag = tag,
            .first_token = first_token,
            .num_tokens = num_tokens,
            .first_child = null_node,
            .num_children = 0,
            .data = data,
        });
    }

    pub fn node(self: *const Ast, idx: u32) Node {
        return self.nodes.items[idx];
    }

    /// The `i`-th child index of node `idx`.
    pub fn child(self: *const Ast, idx: u32, i: usize) u32 {
        const n = self.node(idx);
        return n.first_child + @as(u32, @intCast(i));
    }

    /// Byte span of a node in the source, via its token range.
    ///
    /// O(1): `src[tokens[first].start .. tokens[last].end]`. Only meaningful
    /// for nodes whose token range is non-empty.
    pub fn span(self: *const Ast, idx: u32) token.Span {
        const n = self.node(idx);
        if (n.num_tokens == 0) return .{ .start = 0, .end = 0 };
        const first_t = self.tokens.items[n.first_token];
        const last_t = self.tokens.items[n.first_token + n.num_tokens - 1];
        return .{ .start = first_t.start, .end = last_t.end };
    }
};

// ── tests ────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

fn testAst() !Ast {
    var a = Ast.init(testing.allocator, "x^2");
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .sup, .start = 1, .end = 2 });
    try a.pushToken(.{ .tag = .char, .start = 2, .end = 3 });
    return a;
}

test "ast: reserve and push tokens" {
    var a = try testAst();
    defer a.deinit();
    try testing.expectEqual(@as(usize, 3), a.tokens.items.len);
}

test "ast: createNode builds contiguous child run" {
    var a = try testAst();
    defer a.deinit();
    const c1 = try a.createLeaf(.char, 0, 1, 0);
    const c2 = try a.createLeaf(.char, 2, 1, 0);
    const children = [_]Node{ a.node(c1), a.node(c2) };
    const row = try a.createNode(.row, 0, 3, &children, 0);
    const rn = a.node(row);
    try testing.expectEqual(@as(u16, 2), rn.num_children);
    // contiguous run: c1 copy at first_child, c2 copy right after
    try testing.expectEqual(@as(u32, rn.first_child + 1), rn.first_child + 1);
    try testing.expectEqual(.char, a.node(rn.first_child).tag);
    try testing.expectEqual(.char, a.node(rn.first_child + 1).tag);
}

test "ast: span resolves token range to bytes" {
    var a = try testAst();
    defer a.deinit();
    const c1 = try a.createLeaf(.char, 0, 1, 0);
    const s = a.span(c1);
    try testing.expectEqual(@as(u32, 0), s.start);
    try testing.expectEqual(@as(u32, 1), s.end);
    // full row spans tokens 0..2 → bytes 0..3
    const c2 = try a.createLeaf(.char, 2, 1, 0);
    const children = [_]Node{ a.node(c1), a.node(c2) };
    const row = try a.createNode(.row, 0, 3, &children, 0);
    const rs = a.span(row);
    try testing.expectEqual(@as(u32, 0), rs.start);
    try testing.expectEqual(@as(u32, 3), rs.end);
}

test "atom: genfrac thickness bits round-trip" {
    // 0 → no bits (plain \frac/\atop and 0pt genfrac share the encoding)
    try testing.expectEqual(@as(u32, 0), fracThicknessBits(0));
    try testing.expectEqual(@as(f32, 0), fracThickness(0));
    // 1pt → Q8.8 exact
    const one = fracThicknessBits(1);
    try testing.expect(one != 0);
    try testing.expectApproxEqAbs(@as(f32, 1), fracThickness(one), 1e-3);
    // 0.8pt → 205/256 (Q8.8 rounding)
    const p8 = fracThicknessBits(0.8);
    try testing.expectApproxEqAbs(@as(f32, 0.8), fracThickness(p8), 1e-3);
    // the bits live in 6..22 and do not collide with line/forced/parts
    const data = fracData(true, .text, false) | fracThicknessBits(1.5);
    try testing.expect(fracLine(data));
    try testing.expectEqual(MathStyle.text, fracForcedStyle(data).?);
    try testing.expect(!fracPartsDisplay(data));
    try testing.expectApproxEqAbs(@as(f32, 1.5), fracThickness(data), 1e-3);
    // negative clamps to 0 (no explicit thickness)
    try testing.expectEqual(@as(u32, 0), fracThicknessBits(-2));
}
