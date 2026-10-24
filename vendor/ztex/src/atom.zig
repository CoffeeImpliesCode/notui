//! ztex.atom — superflat LaTeX atom (AST).
//!
//! The whole tree is one flat array of fixed-size AoS nodes; child links are
//! contiguous index runs; source provenance is via a parallel token table
//! with byte offsets. No pointers, no pointer chasing, no per-node
//! allocation.
//!
//! Duplication protocol: a parent's `createNode` re-appends copies of its
//! immediate children immediately before itself, so a node's child run is
//! always contiguous. Each subtree appears in the pool more than once; only
//! the root-reachable chain is the tree.
//!
//! This module types the tree, the `Node.data` codecs, and the `Ast`
//! pool with its builders and readers. `ztex.parse` fills an `Ast` and
//! `ztex.layout` consumes one, and `Ast.init` with `pushToken`,
//! `createLeaf` and `createNode` build one for a caller that does its own.
//! An `Ast` borrows its `src` and owns its two pools, so the source must
//! outlive it and one `deinit` releases it.
//!
//! Every `Node.data` field is an opaque `u32` here, read through what its
//! tag names. A bit-packed tag names one of the inline codecs below; every
//! other tag names its `data` domain in that variant's own comment under
//! `Tag`. A decoder needs no write access to the node.

const std = @import("std");
const token = @import("token.zig");

/// Lexical token kind; the re-exported `ztex.token.Tag`.
pub const TokenTag = token.Tag;

/// A lexed token with its byte span; the re-exported `ztex.token.Token`.
pub const Token = token.Token;

/// A half-open byte range `[start, end)` into the source; the re-exported
/// `ztex.token.Span`. Re-exported so consumers need only `ztex.atom`.
pub const Span = token.Span;

/// The zero-width span at offset 0, used where a node spans no tokens and
/// `Ast.span` cannot name a range.
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

/// Which big operator an `.op` node's `data` names. Layout renders it at the
/// large display size and turns its scripts into over/under limits in display
/// style, beside the base otherwise.
///
/// Each tag is the TeX command without its backslash — `\sum`, `\int`,
/// `\prod`, `\coprod`, `\bigcup`, `\bigcap`, `\bigsqcup`, `\oint` — and
/// layout maps it to the display codepoint it draws (∫, ∮, ∐ and so on). The
/// ordinal is the `data` encoding, so the order is part of the contract.
pub const BigOp = enum(u8) {
    /// `\sum` — n-ary summation, drawn ∑.
    sum,
    /// `\int` — n-ary integral, drawn ∫.
    int,
    /// `\prod` — n-ary product, drawn ∏.
    prod,
    /// `\coprod` — n-ary coproduct, drawn ∐.
    coprod,
    /// `\bigcup` — n-ary union, drawn ⋃.
    bigcup,
    /// `\bigcap` — n-ary intersection, drawn ⋂.
    bigcap,
    /// `\bigsqcup` — n-ary square union, drawn ⨆.
    bigsqcup,
    /// `\oint` — n-ary contour integral, drawn ∮.
    oint,
};

/// TeX math style; `ztex.layout.Style` is an alias of this, so the parser
/// can pack a forced style into a `fraction` node's `data` or a
/// `.mathstyle` node's `data` without a layout import. The ordinal is part of
/// both encodings, so the four values keep these numbers.
pub const MathStyle = enum(u8) {
    /// Display: a formula set on its own line, at the current font size.
    display = 0,
    /// Text: a formula set inline inside running text, with the tighter gaps
    /// that implies.
    text = 1,
    /// Script: the style, size and gaps of a superscript or subscript.
    script = 2,
    /// Script-script: the same for a script of a script.
    script_script = 3,
};

/// Math environment kinds, packed into an `.env` node's `data` low bits.
/// The ordinals are the encoding, so they keep these numbers.
pub const EnvKind = enum(u8) {
    /// `matrix`: a bare array of rows, no delimiters.
    matrix = 0,
    /// `pmatrix`: rows wrapped in parentheses.
    pmatrix = 1,
    /// `bmatrix`: rows wrapped in square brackets.
    bmatrix = 2,
    /// `Bmatrix`: rows wrapped in curly braces.
    Bmatrix = 3,
    /// `vmatrix`: rows wrapped in a single vertical bar.
    vmatrix = 4,
    /// `Vmatrix`: rows wrapped in a double vertical bar.
    Vmatrix = 5,
    /// `cases`: a two-column brace, the second column set in text style.
    cases = 6,
    /// `aligned`: points that align on the `&` separators, no delimiters.
    aligned = 7,
    /// `array`: an environment that takes an explicit column spec — the only
    /// kind for which `envSpecCount` is non-zero.
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
    /// Bits 0-3 of `data`; the mask leaves room for every `EnvKind`.
    pub const kind_mask: u32 = 0xF;
    /// Bit offset of the packed colspec length.
    pub const count_shift: u5 = 4;
    /// Bit offset of column 0's colspec nibble.
    pub const col_shift: u5 = 8;
    /// Mask isolating one colspec nibble; 4-7 are not assigned by `envData`.
    pub const col_nibble: u32 = 0xF;
    /// Left-aligned column (`l`).
    pub const col_l: u32 = 0;
    /// Centered column (`c`; also the reading for an unassigned nibble).
    pub const col_c: u32 = 1;
    /// Right-aligned column (`r`).
    pub const col_r: u32 = 2;
    /// Vertical rule drawn before this column (`|`).
    pub const col_rule: u32 = 3;
    /// Colspec columns the packed field can hold: 6 nibbles fill bits 8-31,
    /// so `envColSpec` names no column at or beyond this index.
    pub const max_spec_cols: usize = 6;
};

/// The environment kind of an `.env` node.
///
/// `data` must name an `EnvKind` in bits 0-3 — every `envData` result does,
/// and so does every node `ztex.parse` builds. A `data` whose low nibble is
/// 9-15 names no environment and traps in a checked build mode.
pub inline fn envKind(data: u32) EnvKind {
    return @fromBackingInt(@intCast(data & EnvBits.kind_mask));
}

/// Number of array colspec nibbles `data` claims, 0-15 from bits 4-7.
///
/// `envData` never writes above `EnvBits.max_spec_cols`; a hand-built `data`
/// may claim more, and `envColSpec` then answers `null` for the columns past
/// the six nibbles the field actually holds.
pub inline fn envSpecCount(data: u32) usize {
    return (data >> EnvBits.count_shift) & 0xF;
}

/// The packed colspec nibble for column `i`, or `null` when `data` carries
/// no nibble for it — beyond the packed count, at or past
/// `EnvBits.max_spec_cols`, or for a non-`array` environment (which packs no
/// colspec). A `null` means "no spec for this column"; callers align such a
/// column centered.
pub inline fn envColSpec(data: u32, i: usize) ?u32 {
    if (i >= envSpecCount(data)) return null;
    if (i >= EnvBits.max_spec_cols) return null;
    return (data >> (EnvBits.col_shift + @as(u5, @intCast(4 * i)))) & EnvBits.col_nibble;
}

/// Pack an `.env` node's `data` from the kind and the array colspec (a byte
/// string of l/c/r/| chars; any other char counts as centered). `colspec`
/// is truncated to `EnvBits.max_spec_cols` columns, and the packed count is
/// the truncated length — so a longer spec decodes as "no spec" past column
/// 5, and `envColSpec` answers `null` there.
pub inline fn envData(kind: EnvKind, colspec: []const u8) u32 {
    var data: u32 = @backingInt(kind);
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

/// Presence bits stored in a `script` node's `data`: at least one of a
/// superscript or subscript is attached.
pub const ScriptBits = struct {
    /// The base carries a `^` superscript.
    pub const sup: u32 = 1 << 0;
    /// The base carries a `_` subscript.
    pub const sub: u32 = 1 << 1;
};

/// Bit layout of a `fraction` node's `data`: bit 0 = rule line (\frac vs
/// \atop), bits 1-4 = forced math-style code (0 = none, else MathStyle + 1),
/// bit 5 = \cfrac's parts-at-display-style flag, bits 6-21 = \genfrac's
/// explicit rule thickness (pt, Q8.8 fixed point; 0 = none — use the font's
/// rule_thickness or \atop's no rule). A plain \frac/\atop keeps data 0/1 —
/// byte-identical to the pre-feature encoding.
pub const FractionBits = struct {
    /// The fraction draws a rule line (\frac as against \atop).
    pub const line: u32 = 1 << 0;
    /// Bit offset of the forced math-style code.
    pub const forced_shift: u5 = 1;
    /// Mask isolating the forced math-style code: 0 = unset, otherwise
    /// `@intFromEnum(MathStyle) + 1`, so 1-4 name the four styles.
    pub const forced_mask: u32 = 0xF;
    /// \cfrac lays both parts out in display style.
    pub const parts_display: u32 = 1 << 5;
    /// \genfrac's explicit rule thickness in bits 6-21 (Q8.8 fixed point:
    /// 1/256 pt resolution). Zero means "no explicit thickness":
    /// \frac/\atop use the font's rule_thickness (or no rule).
    pub const thick_shift: u5 = 6;
    /// Mask isolating the Q8.8 thickness, 0-65535.
    pub const thick_mask: u32 = 0xFFFF;
    /// Largest thickness the packed field holds: `thick_mask` in Q8.8,
    /// 255.99609375 pt. `fracThicknessBits` clamps a larger request here.
    pub const thick_max_pt: f32 = @as(f32, @floatFromInt(thick_mask)) / 256.0;
};

/// Encode fraction `data` from the line flag, the optional forced style
/// (\dfrac → .display, \tfrac → .text), and \cfrac's parts-at-display flag.
/// The thickness bits are left at 0; `fracThicknessBits` ORs them in.
pub inline fn fracData(line: bool, forced: ?MathStyle, parts_display: bool) u32 {
    const code: u32 = if (forced) |f| @as(u32, @backingInt(f)) + 1 else 0;
    return @intFromBool(line) |
        (code << FractionBits.forced_shift) |
        (@as(u32, @intFromBool(parts_display)) << 5);
}

/// Whether the fraction draws a rule line (\frac \dfrac \tfrac \cfrac).
pub inline fn fracLine(data: u32) bool {
    return data & FractionBits.line != 0;
}

/// The forced style of a \dfrac/\tfrac/\cfrac fraction; `null` when the
/// fraction carries none — a plain \frac/\atop, and also a code naming no
/// `MathStyle`, which no `fracData` result produces.
pub inline fn fracForcedStyle(data: u32) ?MathStyle {
    const code = (data >> FractionBits.forced_shift) & FractionBits.forced_mask;
    if (code == 0) return null;
    if (code > @typeInfo(MathStyle).@"enum".field_names.len) return null;
    return @fromBackingInt(@intCast(code - 1));
}

/// \cfrac flag: lay out BOTH parts in display style (amsmath's continued
/// fraction), on top of the display-style gaps.
pub inline fn fracPartsDisplay(data: u32) bool {
    return data & FractionBits.parts_display != 0;
}

/// Encode a \genfrac rule thickness (pt) as Q8.8 in the thick bits; 0 for
/// "no explicit thickness". `pt` is clamped in points to
/// `[0, FractionBits.thick_max_pt]` before the conversion, so a request
/// outside the field — `1e10`, or `std.math.inf(f32)` — saturates at the
/// bound instead of overflowing the integer cast, and a negative value or a
/// NaN encodes 0. A non-rule genfrac (\atop-style) carries thickness 0 like
/// a plain \frac/\atop.
pub inline fn fracThicknessBits(pt: f32) u32 {
    if (std.math.isNan(pt)) return 0;
    const clamped = @min(@max(pt, 0.0), FractionBits.thick_max_pt);
    const q: u32 = @intFromFloat(@round(clamped * 256.0));
    return (q << FractionBits.thick_shift) &
        (FractionBits.thick_mask << FractionBits.thick_shift);
}

/// The \genfrac rule thickness in pt (absolute TeX dimension — layout does
/// NOT scale it with the font size); 0 when the fraction has no explicit
/// thickness (plain \frac/\atop, or a 0pt genfrac). Total: every bit
/// pattern decodes, the range being `[0, FractionBits.thick_max_pt]`.
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

/// Atom (node) tag. `Node.data` is tag-specific. A bit-packed tag names
/// its inline codec — `ScriptBits` for `.script`, `FractionBits` for
/// `.fraction`, `LimitsBits` for `.op`/`.opname`, `EnvBits` for `.env` —
/// and every other tag names its `data` domain in that variant's own
/// comment below.
pub const Tag = enum(u8) {
    /// a sequence of sibling atoms; children = the atoms in order. `data` 0
    /// is an ordinary row: what `ztex.parse` emits for plain source, and
    /// the only value a caller builds. A nonzero `data` is reserved
    /// parser/layout metadata, and this module names no codec for it.
    /// `ztex.layout` builds a construct only from the markers it handles,
    /// so a nonzero value promises no layout of its own. A caller must not
    /// manufacture one, nor read one as a domain of its own.
    row,
    /// `{ ... }`; exactly 1 child
    group,
    /// a glyph; leaf. The codepoint is re-read from the source span when
    /// `data` is 0 — and `data` holds an explicit codepoint instead when
    /// the parser synthesizes the glyph from a command (`\alpha`, `\cdot`,
    /// an environment delimiter, an operator word's letters) or a caller
    /// builds the leaf directly. The effective font style comes from the
    /// nearest enclosing `styled` node.
    char,
    /// `base^sup_sub`; children[0]=base, [1]=sup, [2]=sub (null if absent)
    script,
    /// `\frac{num}{den}` / `\atop`; children[0]=num, [1]=den; data: line flag
    fraction,
    /// horizontal space (\, \; \quad); leaf; data: width_em as Q16.16 — the
    /// `emToFixed`/`fixedToEm` codec, not an ordinal
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
    /// delimiters to cover the inner's height. `data` 0 is that
    /// auto-sizing pair; 1-4 is a `\big \Big \bigg \Bigg` ladder level, whose
    /// node carries a SINGLE delimiter child and no inner for
    /// `ztex.layout` to size by that entry.
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

/// A flat, fixed-size AST node. A node stores indices only; the pool is the
/// `Ast`, and a node value copied out of it stays valid as long as the pool
/// is. Reads are bounds-checked by the pool, so an index a caller did not
/// get from `createNode`/`createLeaf`/`child` is out of contract.
pub const Node = struct {
    tag: Tag,
    /// index of the first token this node spans (into Ast.tokens)
    first_token: u32,
    /// number of tokens this node spans
    num_tokens: u32,
    /// index of the first child (into Ast.nodes); `null_node` = null/leaf
    first_child: u32,
    /// number of children in the contiguous run starting at `first_child`
    num_children: u16,
    /// tag-specific payload, read through the codec the `Tag` names
    data: u32,
};

/// Sentinel "no child / no node" index, valid for `Node.first_child` and for
/// any index a caller may hold to mean "absent".
pub const null_node: u32 = 0;

/// Encode a width-in-em as Q16.16 fixed point (for `space` node data).
/// `em` must lie in the signed Q16.16 range, `[-32768, 32767.99998]`; the
/// parser only ever encodes glue below 1em. A value outside it traps in a
/// checked build mode.
pub inline fn emToFixed(em: f32) u32 {
    return @bitCast(@as(i32, @intFromFloat(em * 65536.0)));
}

/// Decode a Q16.16 fixed-point width-in-em back to f32. Total: the sign bit
/// is the Q16.16 sign, so the range is the encoding's own.
pub inline fn fixedToEm(v: u32) f32 {
    return @floatCast(@as(f64, @floatFromInt(@as(i32, @bitCast(v)))) / 65536.0);
}

/// The superflat AST: source + parallel token table + flat node pool.
///
/// `Ast` owns `tokens` and `nodes` and allocates them from the `gpa` given
/// to `init`; `src` is borrowed, never copied, so it must outlive the `Ast`
/// and every `Span` taken from one. Copying an `Ast` copies both pool
/// handles, not the pools, so a copy is not a second owner and must not be
/// `deinit`'d separately — exactly one `deinit` per `init`. The pool is
/// append-only, so a `Node` copied out of `node` stays valid until then.
///
/// Appending invalidates previously returned indices only in the sense that
/// they now name more siblings; every index already handed out keeps
/// naming its own node. A stable address is not part of the contract: take
/// indices, not pointers.
pub const Ast = struct {
    /// Allocator for `tokens` and `nodes`; the caller owns it and outlives
    /// the `Ast`.
    gpa: std.mem.Allocator,
    /// The formula bytes; borrowed from the caller, never copied.
    src: []const u8,
    /// Lexed tokens, parallel to `src`.
    tokens: std.ArrayList(token.Token) = .empty,
    /// Node pool, in the duplication order `createNode` writes.
    nodes: std.ArrayList(Node) = .empty,
    /// index of the root node (the whole formula), set by the parser
    root: u32 = 0,

    /// Create an empty Ast over `src`, with no tokens and no nodes. The
    /// caller must pre-lex into `tokens` before parsing (see
    /// `ztex.parse.lexer`).
    pub fn init(gpa: std.mem.Allocator, src: []const u8) Ast {
        return .{ .gpa = gpa, .src = src };
    }

    /// Release `tokens` and `nodes`. `gpa` and `src` are not released. The
    /// Ast and every index and span taken from it are invalid afterward, and
    /// a second call is a double free.
    pub fn deinit(self: *Ast) void {
        self.tokens.deinit(self.gpa);
        self.nodes.deinit(self.gpa);
        self.* = undefined;
    }

    /// Preallocate the token table and the node pool. Capacity-only: a later
    /// append past either reservation still succeeds by growing. On error the
    /// reservation that already succeeded stands; the `Ast` stays usable.
    pub fn reserve(self: *Ast, token_count: usize, node_count: usize) !void {
        try self.tokens.ensureTotalCapacity(self.gpa, token_count);
        try self.nodes.ensureTotalCapacity(self.gpa, node_count);
    }

    /// Append a token and return nothing; the new token's index is
    /// `tokens.items.len - 1` afterwards. On `error.OutOfMemory` the token
    /// table is unchanged.
    pub fn pushToken(self: *Ast, t: token.Token) !void {
        try self.tokens.append(self.gpa, t);
    }

    /// Append a single node and return its index. On `error.OutOfMemory`
    /// nothing is appended, so the returned index is not produced.
    pub fn pushNode(self: *Ast, n: Node) !u32 {
        const idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.gpa, n);
        return idx;
    }

    /// Append a contiguous run of nodes and return the index of the first;
    /// index `i` of `ns` lands at `first + i`. On `error.OutOfMemory`
    /// nothing is appended.
    pub fn pushNodes(self: *Ast, ns: []const Node) !u32 {
        const first: u32 = @intCast(self.nodes.items.len);
        try self.nodes.appendSlice(self.gpa, ns);
        return first;
    }

    /// Create a node with a contiguous child run: copies `children` into the
    /// pool, then appends the parent pointing at that run.
    ///
    /// `children` are COPIES, not links — the caller's originals stay
    /// independent, and this is what lets each subtree appear in the pool
    /// more than once. `first_token`/`num_tokens` are the token range the
    /// parser has already consumed for this node.
    ///
    /// The two appends fail independently, and the pool is append-only
    /// with no truncation, so `error.OutOfMemory` leaves one of two
    /// residues: a failure of the child-run copy leaves the pool
    /// unchanged, while a failure of the parent append leaves the copied
    /// `children` run in `nodes` with no parent index produced.
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

    /// Create a leaf node (no children) and return its index.
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

    /// A copy of node `idx`. `idx` must be below `nodes.items.len`; the pool
    /// index is out of contract otherwise.
    pub fn node(self: *const Ast, idx: u32) Node {
        return self.nodes.items[idx];
    }

    /// The `i`-th child index of node `idx`. `i` must be below that node's
    /// `num_children`; nothing here range-checks it.
    pub fn child(self: *const Ast, idx: u32, i: usize) u32 {
        const n = self.node(idx);
        return n.first_child + @as(u32, @intCast(i));
    }

    /// Byte span of a node in the source, via its token range.
    ///
    /// O(1): `src[tokens[first].start .. tokens[last].end]`. A node with no
    /// tokens yields `null_span` — the answer is "no range", which is also
    /// what offset 0 with zero width would have named, so a caller that
    /// highlights `null_span` highlights nothing.
    ///
    /// The node's token range must lie inside the table: `first_token +
    /// num_tokens` may not exceed `tokens.items.len`. Both token ends are
    /// read unchecked, so an out-of-table range is out of contract.
    pub fn span(self: *const Ast, idx: u32) token.Span {
        const n = self.node(idx);
        if (n.num_tokens == 0) return null_span;
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
    // The run is contiguous and in order: c1's copy lands at first_child and
    // c2's immediately after, each keeping its own token range.
    try testing.expectEqual(@as(u32, 0), a.node(rn.first_child).first_token);
    try testing.expectEqual(@as(u32, 2), a.node(rn.first_child + 1).first_token);
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

test "atom: genfrac thickness saturates instead of overflowing the cast" {
    // 1e10 * 256 does not fit in u32: the clamp must happen in points,
    // before the conversion, or the cast overflows a checked build mode.
    const huge = fracThicknessBits(1e10);
    try testing.expectEqual(
        FractionBits.thick_mask << FractionBits.thick_shift,
        huge,
    );
    try testing.expectApproxEqAbs(
        FractionBits.thick_max_pt,
        fracThickness(huge),
        1e-3,
    );
    // an infinity has no position in [0, thick_max_pt] either: same bound
    try testing.expectEqual(huge, fracThicknessBits(std.math.inf(f32)));
    try testing.expectEqual(huge, fracThicknessBits(FractionBits.thick_max_pt));
    // a NaN has none at all, and reads as "no explicit thickness"
    try testing.expectEqual(@as(u32, 0), fracThicknessBits(std.math.nan(f32)));
}

test "atom: packed decoders answer null past their field" {
    // A hand-built `data` claiming 15 packed colspec columns: only six
    // nibbles exist, so column 6 and beyond name nothing.
    const data = (@as(u32, 15) << EnvBits.count_shift) | @backingInt(EnvKind.array);
    try testing.expectEqual(@as(usize, 15), envSpecCount(data));
    try testing.expectEqual(@as(?u32, EnvBits.col_l), envColSpec(data, 0));
    try testing.expectEqual(@as(?u32, null), envColSpec(data, EnvBits.max_spec_cols));
    try testing.expectEqual(@as(?u32, null), envColSpec(data, 14));
    // A forced-style code naming no MathStyle reads as "not forced", the
    // same answer as the unset code 0.
    const bad_code: u32 = 7 << FractionBits.forced_shift;
    try testing.expectEqual(@as(?MathStyle, null), fracForcedStyle(bad_code));
}
