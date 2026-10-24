//! ztex.layout — atom tree → superflat box tree (TeX layout).
//!
//! A pure function: (atom tree + FontMetrics + style) → box pool. Each box
//! carries its dimensions and the source byte span of the atom it came from,
//! preserving provenance end to end.
//!
//! Everything lands in the caller-owned `BoxList`, which this module
//! appends to and never frees; `ztex.layout.draw.flatten` reads the result.
//! Measuring through a wired `FontMetrics` writes that metrics' font cache,
//! so a layout run is single-threaded per metrics instance.

const std = @import("std");
const zg = @import("zg");
const atom = @import("ztex.atom");
const metrics = @import("metrics.zig");
const box = @import("box.zig");
const DisplayWidth = @import("DisplayWidth");
const Graphemes = @import("Graphemes");

/// TeX math style; drives script size, fraction gaps, and spacing.
/// Aliased to the atom's MathStyle so the parser can pack a forced style
/// into a `fraction` node's `data` or a `.mathstyle` node's `data`.
pub const Style = atom.MathStyle;

/// What a layout pass can return: `error.OutOfMemory` from the box pool and
/// `error.InvalidTable` from a delimiter table the bundled metrics cannot
/// satisfy. Neither leaves a usable partial tree — the caller frees the
/// `BoxList` and discards it.
pub const Error = std.mem.Allocator.Error || error{InvalidTable};

/// The `data` a \sqrt row node carries (set by the parser): children
/// [surd char (optionally wrapped in a script node holding the root index),
/// radicand]. layoutInner routes such rows through layoutSqrt — the
/// stretchy-radical construction — instead of the ordinary row path.
const sqrt_row_data: u32 = 1;

/// The `data` an accent row node carries (set by the parser): children
/// [base, accent-mark char]. layoutInner routes such rows through
/// layoutAccent — base + combining mark above — instead of the ordinary
/// row path.
const accent_row_data: u32 = 2;

/// \big-family ladder indexes. A `.left` node whose `data` is a level 1..4
/// (\big \Big \bigg \Bigg) carries a SINGLE delimiter child and no inner;
/// layoutLeftRight boxes the delimiter by this ladder entry at the base
/// font size. Measured XeTeX+unicode-math at 10/14/24/36pt: \big →
/// parenleft.v1 (ink 1.094em), \Big → .v4 (1.792em), \bigg → .v6 (2.392em),
/// \Bigg → .v7 (2.990em) — amsmath's \bBigg@ \vcenter height scales with
/// the current size, so the SAME variant is picked at every size. Index 0
/// unused.
const big_ladder_idx = [_]u8{ 0, 1, 4, 6, 7 };

/// Ink target (em) per \big level for delimiters WITHOUT a variant ladder
/// (| \| / \\ fall back to the continuous scaled-base glyph sized so its
/// ink reaches the target).
const big_target_ink = [_]f32{ 0, 1.094, 1.792, 2.392, 2.990 };

/// Bit 21 of a \middle delimiter char leaf's `data` (the low 21 bits hold
/// the codepoint — delimiterCp/layoutChar read only those via @truncate).
/// Mirrors the parser's marker. layoutRow emits such leaves as zero-width
/// placeholder boxes; layoutLeftRight rewrites them in place with the
/// fence's required ink (applied to the delimiter's OWN variant ladder).
const middle_marker: u32 = 1 << 21;

/// The `data` a \not row node carries (set by the parser): children
/// [base]. layoutInner routes such rows through layoutNot — the base
/// relation with the U+0338 overlay slash — instead of the ordinary row
/// path.
const not_row_data: u32 = 3;

/// The `data` a \pmod row node carries (set by the parser): children ['(',
/// roman "mod" word, 6mu space, arg, ')']. layoutInner routes such rows
/// through layoutPmod — the style-dependent leading \mkern (18mu display /
/// 8mu otherwise) plus the fixed \mkern6mu mod-n gap — instead of the
/// ordinary row path.
const pmod_row_data: u32 = 4;

/// The `data` a \pod row node carries (set by the parser): children ['(',
/// arg, ')'] — the parenthesized argument without the "mod" word.
const pod_row_data: u32 = 5;

/// Lay out the atom tree rooted at `idx` into the box pool, and return the
/// index of its root box.
///
/// `idx` must index a node in `ast`, which is borrowed for the call.
/// `size_pt` is the current font size in points and `style` the current math
/// style; `current_style` is the effective font style inherited from
/// enclosing `styled` atoms, `.italic` for ordinary math. Boxes are appended
/// to `list`, so an index the caller already holds keeps naming its own box.
///
/// `fm` is borrowed for the call and may be written through — a wired
/// `FontMetrics` caches during a lookup — so it must not be used
/// concurrently from another thread. `ast` is read-only: nothing is
/// appended to it. The boxes appended to `list` survive the call; the
/// environment path's transient per-cell, per-row and per-column lists
/// are allocated from `list.gpa` and released before `layout` returns.
/// Nothing is read from the file system.
///
/// On any error the boxes already appended stay in `list`; the returned
/// index is not produced, so a caller that needs an all-or-nothing result
/// discards the pool.
pub fn layout(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    current_style: atom.CharStyle,
) Error!u32 {
    return layoutInner(list, ast, idx, fm, style, size_pt, current_style, false);
}

/// Internal layout carrying the TeX "cramped" style bit (tex.web: odd math
/// styles). Cramped contexts (fraction denominators, subscripts) select sup3
/// for the superscript raise floor instead of sup1/sup2. The public layout()
/// entry always starts uncramped; the flag propagates through rows, groups,
/// styled atoms and nested fractions/scripts.
fn layoutInner(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    current_style: atom.CharStyle,
    cramped: bool,
) Error!u32 {
    const n = ast.node(idx);
    return switch (n.tag) {
        .char => layoutChar(list, ast, idx, fm, size_pt, current_style),
        .row => if (n.data == sqrt_row_data)
            layoutSqrt(list, ast, idx, fm, style, size_pt, current_style)
        else if (n.data == accent_row_data)
            layoutAccent(list, ast, idx, fm, style, size_pt, current_style, cramped)
        else if (n.data == not_row_data)
            layoutNot(list, ast, idx, fm, style, size_pt, current_style, cramped)
        else if (n.data == pmod_row_data or n.data == pod_row_data)
            layoutPmod(list, ast, idx, fm, style, size_pt, current_style, cramped)
        else
            layoutRow(list, ast, idx, fm, style, size_pt, current_style, cramped),
        .group => layoutInner(
            list,
            ast,
            ast.child(idx, 0),
            fm,
            style,
            size_pt,
            current_style,
            cramped,
        ),
        .styled => layoutInner(
            list,
            ast,
            ast.child(idx, 0),
            fm,
            style,
            size_pt,
            @fromBackingInt(@intCast(n.data)),
            cramped,
        ),
        // A forced math style (\displaystyle \textstyle \scriptstyle
        // \scriptscriptstyle): the content lays out with the FORCED style
        // at the style-ratio-adjusted size (TeX: the style determines the
        // font size — \displaystyle in a script grows the content back to
        // the text size, \scriptstyle in display shrinks it), and the
        // cramped bit clears (forced styles are uncramped — the classic
        // escape from a denominator's cramped textstyle).
        .mathstyle => blk: {
            const ms: Style = @fromBackingInt(@intCast(n.data));
            const gl = fm.glue(fm);
            break :blk layoutInner(
                list,
                ast,
                ast.child(idx, 0),
                fm,
                ms,
                size_pt * (styleScale(gl, ms) / styleScale(gl, style)),
                current_style,
                false,
            );
        },
        // An operator word: the letters row, always roman (like \mathrm).
        .opname => layoutInner(
            list,
            ast,
            ast.child(idx, 0),
            fm,
            style,
            size_pt,
            .roman,
            cramped,
        ),
        .left => layoutLeftRight(list, ast, idx, fm, style, size_pt, current_style, cramped),
        .script => layoutScript(list, ast, idx, fm, style, size_pt, current_style, cramped),
        .fraction => layoutFraction(list, ast, idx, fm, style, size_pt, current_style, cramped),
        .space => layoutSpace(list, ast, idx, fm, style, size_pt),
        .text => layoutText(list, ast, idx, fm, size_pt),
        .op => layoutOp(list, ast, idx, style, size_pt),
        .overline => layoutOverUnder(list, ast, idx, fm, style, size_pt, current_style, cramped),
        .mathchoice => layoutMathChoice(list, ast, idx, fm, style, size_pt, current_style),
        // \substack: the script-size multi-line stack (children = the
        // lines). The lines are always \scriptstyle (uncramped), so no
        // cramped bit is needed.
        .substack => layoutSubstack(list, ast, idx, fm, style, size_pt, current_style),
        // \begin{env}...\end{env} (matrix family, cases, aligned, array).
        .env => layoutEnv(list, ast, idx, fm, style, size_pt, current_style, cramped),
    };
}

/// Unwrap transparent .group/.styled wrappers to the underlying atom. TeX
/// attaches scripts to the LAST noad of a braced mlist ({x}^2 ≡ x^2, {\int}^2
/// attaches to the ∫), while a braced LIST becomes a box; ztex's transparent
/// groups reproduce the single-noad case, so the unwrapped tag classifies a
/// base or script content as TeX would.
fn unwrapAtom(ast: *const atom.Ast, idx: u32) u32 {
    var i = idx;
    while (true) {
        const n = ast.node(i);
        if (n.tag != .group and n.tag != .styled and n.tag != .mathstyle) return i;
        if (n.num_children == 0) return i;
        i = ast.child(i, 0);
    }
}

/// Superscript/subscript FLOORS from the math-symbol font (family 2) at the
/// CURRENT style's size. With XeTeX+unicode-math these are the Latin-Modern-
/// Math MATH-table constants, read at the current size and scaled LINEARLY
/// (measured x^{y^2} at script size: sup raise 2.541pt = 3.63 × 0.7 — the
/// optically scaled cmsy7/cmsy5 values 4.311/4.036 are CM-only). So one
/// 10pt-base set serves every style; layout scales by size/10 via s().
const SymParams = struct {
    sup1: f32,
    sup2: f32,
    sup3: f32,
    sub1: f32,
    sub2: f32,
};

const sym_lm: SymParams = .{
    .sup1 = 3.63, // SuperscriptShiftUp
    .sup2 = 3.63, // SuperscriptShiftUp (no display/text distinction)
    .sup3 = 2.89, // SuperscriptShiftUpCramped
    .sub1 = 2.47, // SubscriptShiftDown
    .sub2 = 2.47, // SubscriptShiftDown (no separate "with superscript" const)
};

fn symFor(_: Style) SymParams {
    return sym_lm;
}

/// TeX atom class for inter-atom spacing (tex.web math_spacing; MicroTeX
/// AtomType). Composite atoms report the class of their first/last child;
/// delimiter-less fractions are `ord` (tex.web: fraction_noad → ord_noad,
/// verified against XeTeX), scripted atoms are `ord` (MicroTeX ScriptsAtom);
/// `inner` is reserved for \left..\right constructs (not yet modeled).
const Role = enum(u8) {
    ord,
    op,
    bin,
    rel,
    open,
    close,
    punct,
    inner,
};

/// Inter-atom glue table, the exact TeX rule (tex.web §799, the 64-digit
/// math_spacing string "0234..." — verified empirically against XeTeX
/// \showbox). Indexed [left role][right role]; each entry packs 4 nibbles:
/// display, text, script, scriptscript glue units (0 none, 1 thin, 2 med,
/// 3 thick).
///
/// Digits decode to nibbles: '1' = conditional thin (display/text only),
/// '2' = thin in ALL styles, '3'/'4' = med/thick (display/text only), '*' =
/// impossible (bin is demoted before it fires). So med/thick AND the
/// conditional thins (ord→inner, punct→*, close→inner, inner→ord, …) are
/// SUPPRESSED in script/scriptscript styles — measured: the subscript `i=1`
/// has NO glue, while `a∑` in a script keeps thin (1.3657pt at 7pt, using the
/// script symbol font's quad). Only ord↔op and close→op keep thin in scripts.
const glue_table = blk: {
    const rows = [_][8]u16{
        .{ 0x0000, 0x1111, 0x2200, 0x3300, 0x0000, 0x0000, 0x0000, 0x1100 }, // ord
        .{ 0x1111, 0x1111, 0x0000, 0x3300, 0x0000, 0x0000, 0x0000, 0x1100 }, // op
        .{ 0x2200, 0x2200, 0x0000, 0x0000, 0x2200, 0x0000, 0x0000, 0x2200 }, // bin
        .{ 0x3300, 0x3300, 0x0000, 0x0000, 0x3300, 0x0000, 0x0000, 0x3300 }, // rel
        .{ 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000 }, // open
        .{ 0x0000, 0x1111, 0x2200, 0x3300, 0x0000, 0x0000, 0x0000, 0x1100 }, // close
        .{ 0x1100, 0x1100, 0x0000, 0x1100, 0x1100, 0x1100, 0x1100, 0x1100 }, // punct
        .{ 0x1100, 0x1111, 0x2200, 0x3300, 0x1100, 0x0000, 0x1100, 0x1100 }, // inner
    };
    var t: [8][8][4]u8 = undefined;
    for (rows, 0..) |row, l| {
        for (row, 0..) |v, r| {
            t[l][r] = .{
                @intCast((v >> 12) & 0xF), // display
                @intCast((v >> 8) & 0xF), // text
                @intCast((v >> 4) & 0xF), // script
                @intCast(v & 0xF), // scriptscript
            };
        }
    }
    break :blk t;
};

/// TeX class of a raw codepoint, matching MicroTeX's symbol types
/// (tex_symbols.res.cpp: bin = + - ± × ÷ · ∗ ∘ ∙ ∩ ∪ ∧ ∨ ⊕ ⊖ ⊗ ⊘ ⊙ ∖ ≀ ⊎
/// ⊓ ⊔ ⋆ ◇ ⋁ ⋀ † ‡ ◃ ▹ ○ ⨿ etc, rel = = < > : ≤ ≥ ≠ ≡ ≺ ≻ ⊆ ⊇ ∈ ∉ ∋ →
/// rel adds: arrows, ∝ ∣ ∥ ⊥ ⊢ ⊨ ≪ ≫ ⊑ ⊒ ⋈ etc,
/// open/close = ( [ { ⟨ ⌈ ⌊ / ) ] }, punct = , ;, big-op codepoints = op).
fn roleOfCp(cp: u21) Role {
    const bin = [_]u21{
        0x2B,   0x2D,   0x2212, 0x2213, 0x00B1, 0x00D7, 0x00F7, 0x22C5, 0x2217,
        0x2218, 0x2219, 0x2229, 0x222A, 0x2227, 0x2228, 0x2295, 0x2296, 0x2297,
        0x2298, 0x2299, 0x22C2, 0x22C3, 0x2020, 0x2021, 0x2216, 0x2240, 0x228E,
        0x2293, 0x2294, 0x22C4, 0x22C6, 0x25B9, 0x25C3, 0x25CB, 0x2A3F, 0x00B7,
    };
    const rel = [_]u21{
        0x3D,   0x3C,   0x3E,   0x3A,   0x2260, 0x2261, 0x2262, 0x2264, 0x2265,
        0x2266, 0x2267, 0x2243, 0x2244, 0x2245, 0x2246, 0x2247, 0x2248, 0x2249,
        0x223C, 0x2241, 0x2282, 0x2283, 0x2284, 0x2285, 0x2286, 0x2287, 0x2288,
        0x2289, 0x2208, 0x2209, 0x220B, 0x220C, 0x227A, 0x227B, 0x2280, 0x2281,
        0x226D, 0x226E, 0x226F, 0x2270, 0x2271, 0x22E0, 0x22E1, 0x22AC, 0x2190,
        0x2192, 0x2194, 0x21D0, 0x21D2, 0x21D4, 0x2A7D, 0x2A7E, 0x2191, 0x2193,
        0x2195, 0x2196, 0x2197, 0x2198, 0x2199, 0x21A6, 0x21A9, 0x21AA, 0x21BC,
        0x21BD, 0x21C0, 0x21C1, 0x21D1, 0x21D3, 0x21D5, 0x221D, 0x2223, 0x2224,
        0x2225, 0x2226, 0x2234, 0x2235, 0x224D, 0x2250, 0x226A, 0x226B, 0x2291,
        0x2292, 0x22A2, 0x22A3, 0x22A5, 0x22A8, 0x22C8, 0x2322, 0x2323, 0x27F5,
        0x27F6, 0x27F7, 0x27F8, 0x27F9, 0x27FA, 0x2AAF, 0x2AB0,
    };
    const open = [_]u21{ 0x28, 0x5B, 0x7B, 0x27E8, 0x2308, 0x230A };
    const close = [_]u21{ 0x29, 0x5D, 0x7D, 0x27E9, 0x2309, 0x230B };
    const punct = [_]u21{ 0x2C, 0x3B };
    const ops = [_]u21{
        0x2211, 0x220F, 0x222B, 0x2210, 0x222E, 0x2A06, 0x22C0, 0x22C1,
        0x2A00, 0x2A01, 0x2A02, 0x2A04, 0x2A05,
    };
    if (std.mem.indexOfScalar(u21, &bin, cp) != null) return .bin;
    if (std.mem.indexOfScalar(u21, &rel, cp) != null) return .rel;
    if (std.mem.indexOfScalar(u21, &open, cp) != null) return .open;
    if (std.mem.indexOfScalar(u21, &close, cp) != null) return .close;
    if (std.mem.indexOfScalar(u21, &punct, cp) != null) return .punct;
    if (std.mem.indexOfScalar(u21, &ops, cp) != null) return .op;
    return .ord;
}

/// First codepoint of the atom's source span (0 for empty spans). A char
/// atom whose `data` carries an explicit codepoint override (parser \cdot)
/// reports that instead of the source bytes.
fn nodeCp(ast: *const atom.Ast, idx: u32) u21 {
    const n = ast.node(idx);
    if (n.data != 0) return @truncate(n.data);
    const sp = ast.span(idx);
    return firstCodepoint(ast.src[sp.start..sp.end]);
}

/// Left class of an atom: composite atoms report their first child.
/// A scripted big operator keeps the op class (TeX: an op_noad with
/// scripts is still an op), so inter-atom glue around \sum_{...} is
/// computed with the op role (thin before/after, not ord's none).
fn leftRole(ast: *const atom.Ast, idx: u32) Role {
    const n = ast.node(idx);
    return switch (n.tag) {
        // A \middle delimiter is TeX's "middle" atom; measured XeTeX of
        // `\left\{ x \middle| \frac{x}{2} \in S \right\}` shows NO glue
        // around the | — class close gives exactly that (ord→close and
        // close→ord are both 0, like the reference).
        .char => if (n.data & middle_marker != 0) .close else roleOfCp(nodeCp(ast, idx)),
        .op => .op,
        // A delimiter-less \over/\atop fraction is an ORD noad in TeX
        // (tex.web §14981: fraction_noad falls through to t := ord_noad),
        // measured: `{x\over n} x` has NO glue, `{x\over n} + y` gets med.
        // Only \left..\right constructs are inner.
        .fraction => .ord,
        .group, .styled, .mathstyle, .row => if (n.num_children == 0) .ord else leftRole(ast, ast.child(idx, 0)),
        // Operator words are TeX \mathop atoms — role OP — so the inter-atom
        // glue around them is the op spacing: \sin x gets a thin space
        // (op→ord thin, matching XeTeX: sin and x separated by 3/18 em).
        .opname => .op,
        // \left..\right is an inner atom: thin glue to ord/punct neighbors.
        // A \big/\Big/\bigg/\Bigg node (data = level 1..4) is amsmath's
        // \bBigg@ \box — a BOX atom, class ORD (XeTeX \showbox of `\Big[ x
        // \Big]` has NO glue around the brackets; measured). Only the real
        // \left..\right fences are inner.
        .left => if (n.data != 0) .ord else .inner,
        // \overline/\underline is an ord noad in TeX (over_noad/under_noad
        // are ordinary), so the inter-atom glue around it is ord spacing.
        .overline => .ord,
        // \mathchoice resolves to its chosen branch at layout time (the
        // branch's own atoms enter the list, per TeX math_choice); ztex
        // classifies the node ord, like a fraction/overline box. Branch
        // contents are normally ord (fractions, letters); exotic bin/rel
        // branches lose their glue — documented simplification.
        .mathchoice => .ord,
        // \substack is a box (amsmath \subarray = \vcenter of an \ialign):
        // class ORD, like any box atom.
        .substack => .ord,
        // A \begin{env} with delimiters (pmatrix ... cases) is amsmath's
        // \left...\right fence — class INNER (thin glue to ord/punct).
        // Delimiter-less envs (matrix, aligned, array) are \vcenter boxes —
        // class ORD (measured XeTeX: no glue around a bare matrix).
        .env => if (envHasDelims(ast, idx)) .inner else .ord,
        // A scripted base keeps the base's class: a scripted big operator OR
        // operator word (\sum_{...}, \sin^2 x, \lim_{x\to0}) is still an op.
        .script => if (n.num_children > 0) blk: {
            const base = unwrapAtom(ast, ast.child(idx, 0));
            const bt = ast.node(base).tag;
            break :blk if (bt == .op or bt == .opname) .op else .ord;
        } else .ord,
        .text, .space => .ord,
    };
}

/// Right class of an atom: composite atoms report their last child.
fn rightRole(ast: *const atom.Ast, idx: u32) Role {
    const n = ast.node(idx);
    return switch (n.tag) {
        .char => if (n.data & middle_marker != 0) .close else roleOfCp(nodeCp(ast, idx)),
        .op => .op,
        .fraction => .ord,
        .group, .styled, .mathstyle, .row => blk: {
            if (n.num_children == 0) break :blk .ord;
            break :blk rightRole(ast, ast.child(idx, n.num_children - 1));
        },
        // Operator words are \mathop atoms: OP role (see leftRole).
        .opname => .op,
        // \left..\right is an inner atom (thin glue to ord/punct); a
        // \big-family node (data = level) is a \box — class ORD (measured
        // XeTeX: no glue around \Big[ x \Big]).
        .left => if (n.data != 0) .ord else .inner,
        // \overline/\underline is an ord noad (see leftRole).
        .overline => .ord,
        // \mathchoice is an ord atom (see leftRole).
        .mathchoice => .ord,
        // \substack is a box (see leftRole).
        .substack => .ord,
        // \begin{env}: inner when it has delimiters, ord otherwise (see
        // leftRole).
        .env => if (envHasDelims(ast, idx)) .inner else .ord,
        .script => if (n.num_children > 0) blk: {
            const base = unwrapAtom(ast, ast.child(idx, 0));
            const bt = ast.node(base).tag;
            break :blk if (bt == .op or bt == .opname) .op else .ord;
        } else .ord,
        .text, .space => .ord,
    };
}

/// Glue units → em fractions: thin 3/18, med 4/18, thick 5/18 (MicroTeX
/// glue.cpp _glueTypes); index 0 (no space) yields 0.
const glue_em: [4]f32 = .{ 0, 3, 4, 5 };

/// Mu-unit quad (in em) of the symbol font (family 2) at the current style.
/// TeX computes 1mu = quad/18 from \scriptfont2 etc. (tex.web §13864).
/// With XeTeX+unicode-math the Latin-Modern-Math quad is 1em at EVERY size
/// (measured: script-size \, = 3/18 × 6.9738 = 1.162pt and \; = 5/18 ×
/// 6.9738 = 1.937pt on x^{1\,1}/x^{1\;1} — the old cmsy7 quad 1.170641em
/// (1.3657pt thin) is a Computer-Modern value that does not apply to LM).
inline fn quadEm(_: Style) f32 {
    return 1.0;
}

/// Glue units (0-3) between two adjacent atoms in the current style.
fn glueUnits(l: Role, r: Role, style: Style) u8 {
    const i: usize = @backingInt(l);
    const j: usize = @backingInt(r);
    return glue_table[i][j][@backingInt(style)];
}

/// Scale a 10pt-base metric to the current size.
inline fn s(v: f32, size_pt: f32) f32 {
    return v * (size_pt / 10.0);
}

/// Size scale of a math style relative to the text size (TeX: D/T use the
/// text font, S the script font, SS the scriptscript font). A forced-style
/// wrapper/fraction rescales its content by target/current — \scriptstyle
/// in display shrinks to script size, \displaystyle in a script grows back
/// to the text size (root-relative sizing, the same ladder layoutScript
/// uses). A plain atom keeps target == current, ratio 1.0, so existing
/// output is untouched.
inline fn styleScale(gl: metrics.GlueParams, st: Style) f32 {
    return switch (st) {
        .display, .text => 1.0,
        .script => gl.scriptfactor,
        .script_script => gl.scriptscriptfactor,
    };
}

/// Decode the first codepoint of `bytes` with zg's DFA decoder (ASCII fast
/// path; no view/iterator setup). Empty or malformed UTF-8 yields 0,
/// matching the previous `Utf8View.init(...) catch null` fallback: zg
/// substitutes U+FFFD (len 1) for malformed sequences, which we fold back to
/// 0 — a genuine U+FFFD (EF BF BD) decodes with len 3 and is kept.
inline fn firstCodepoint(bytes: []const u8) u21 {
    if (bytes.len == 0) return 0;
    if (bytes[0] < 0x80) return bytes[0];
    var cursor: zg.code_point.uoffset = 0;
    const d = zg.code_point.decodeAtCursor(bytes, &cursor) orelse return 0;
    return if (d.code == 0xfffd and d.len == 1) 0 else d.code;
}

/// Map a codepoint to its math-italic form via the Unicode Math
/// Alphanumeric Symbols block (U+1D400–U+1D7FF): each style series is a
/// CONTIGUOUS RUN, so the mapping is arithmetic — a handful of range
/// checks + offsets, NOT a per-character table. Series for math-italic:
///
///   Latin capital A–Z (U+0041..005A) → U+1D434..U+1D44D (off = cp − 'A')
///   Latin small a–z   (U+0061..007A) → U+1D44E..U+1D467 (off = cp − 'a')
///   Greek small α–ω   (U+03B1..03C9) → U+1D6FC..U+1D714 (off = cp − U+03B1)
///   Greek variants    (U+03F5 ϵ, U+03D1 ϑ, U+03F1 ϱ, U+03D5 ϕ, U+03D6 ϖ)
///                      → their Unicode compat slots U+1D716/U+1D717/
///                        U+1D71A/U+1D719/U+1D71B (all in LM Math's cmap,
///                        verified with fontTools; the font-cmap validation
///                        in the callers keeps the base cp if one is not)
///   ∂ U+2202 → U+1D715 (math-italic partial, the Math Alphanumeric Symbols
///                      slot): the XeTeX+unicode-math reference emits
///                      U+1D715 for \partial — measured `\frac{\partial
///                      L}{\partial \dot{q}}` ref render (u1D715 glyph,
///                      advance 0.531em vs the upright 0.586em — a DIFFERENT
///                      glyph). Systematic companion to the letter mapping:
///                      math style renders the math-italic form, roman
///                      (\mathrm{\partial}) keeps U+2202.
///
/// Notes:
///  · U+1D455 (math-italic h) is UNASSIGNED in Unicode and absent from LM
///    Math; the math-italic h is U+210E ℎ (Planck constant) — exactly what
///    XeTeX+unicode-math emits for `$h$` (verified).
///  · ς U+03C2 (final sigma) sits INSIDE the α–ω run, so the series covers
///    it (→ U+1D70D).
///  · Greek CAPITALS are deliberately NOT mapped: unicode-math's TeX-style
///    math keeps uppercase Greek upright — the XeTeX+unicode-math reference
///    emits `\Gamma` → U+0393 (probe-verified), so `\Gamma(x)` stays
///    upright. The U+1D6E2..U+1D6FA series (off = cp − U+0391) belongs to
///    a future \varGamma/\mathit-capitals path.
///
/// Only `.italic` (default math variables) maps: roman (\text, \mathrm,
/// \sin) and bold stay upright ASCII — the callers gate on style.
inline fn mathItalic(cp: u21) ?u21 {
    if (cp >= 0x41 and cp <= 0x5A) return cp - 0x41 + 0x1D434;
    if (cp >= 0x61 and cp <= 0x7A) return if (cp == 0x68) 0x210E else cp - 0x61 + 0x1D44E;
    if (cp >= 0x3B1 and cp <= 0x3C9) return cp - 0x3B1 + 0x1D6FC;
    return switch (cp) {
        0x3F5 => 0x1D716, // ϵ lunate epsilon → math-italic epsilon symbol
        0x3D1 => 0x1D717, // ϑ theta symbol
        0x3F1 => 0x1D71A, // ϱ rho symbol
        0x3D5 => 0x1D719, // ϕ phi symbol
        0x3D6 => 0x1D71B, // ϖ pi symbol
        0x2202 => 0x1D715, // ∂ → math-italic partial (unicode-math emits U+1D715)
        else => null,
    };
}

fn layoutChar(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    size_pt: f32,
    cstyle: atom.CharStyle,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    // A nonzero `data` overrides the codepoint (parser \cdot → U+22C5); the
    // glyph then has no matching source bytes, so it must be marked
    // synthetic for flatten to dupe instead of aliasing "\cdot".
    const cp: u21 = if (n.data != 0) @truncate(n.data) else firstCodepoint(ast.src[span.start..span.end]);
    // Math-italic letters/Greek map to their U+1D4xx/U+1D6xx codepoints
    // (series arithmetic, see mathItalic) so the box carries the TRUE
    // math-italic form — the LM Math advance and the slanted drawn glyph —
    // instead of the upright letter (unicode-math reference: `$x$` →
    // U+1D465, `\alpha` → U+1D6FC). The mapped cp is validated against the
    // ACTIVE metric source before emitting: a wired font's cmap (font
    // first, so a font without the math-italic glyph keeps the base), or
    // the static table when no font is wired (it covers the U+1D4xx Latin
    // series but not the U+1D6xx Greek series — those fall back to the
    // base cp gracefully). A mapped box is marked synthetic (its utf-8 no
    // longer equals the source bytes) so flatten dupes it into the arena.
    var mcp: u21 = cp;
    // `-` is TeX's \mathbin{-}: unicode-math maps the math hyphen to the
    // FULL-WIDTH MINUS SIGN U+2212 (the XeTeX reference emits U+2212 for
    // `-x^2` and `-\infty`). The raw U+002D hyphen-minus in LM Math is a
    // SHORT hyphen (ink 0.245em tall, 0.265em wide vs the minus 0.666em
    // wide) — the "your - sign is too short" defect. The box then takes
    // the U+2212 advance (7.78pt at 10pt vs 3.33pt) and the drawn glyph.
    // \text runs bypass layoutChar (layoutText reads the source directly),
    // so `\text{a-b}` keeps the text hyphen, exactly like XeTeX.
    if (cp == 0x2D) mcp = 0x2212;
    if (cstyle == .italic) {
        if (mathItalic(cp)) |m| {
            if (metrics.hasGlyph(fm, m, cstyle)) mcp = m;
        }
    }
    // Size-aware lookup: script/scriptscript sizes use the real optically
    // scaled cmr7/cmmi7/cmsy7 (resp. cmr5/...) metrics (values in the same
    // 10pt-base convention, so the s() scaling below lands on true points);
    // any other size uses the 10pt table (linear scaling). When the mapped
    // cp has no metric (a font without the math-italic glyphs), fall back
    // to the ASCII letter's entry — the static table keeps the U+0078 etc.
    // rows, so the no-font path still works.
    const g = metrics.glyphAt(fm, mcp, cstyle, size_pt) orelse
        metrics.glyphAt(fm, cp, cstyle, size_pt) orelse
        fm.glyphEstimate(fm, cp, cstyle);
    // Box height/depth by the DRAWN Latin-Modern-Math ink (em × drawn
    // size), not the cmr10/cmmi10 metric h/d: the metric box describes the
    // Computer-Modern design while the ink is what the SVG draws, and it
    // pokes past the metric box (∫ sup '1' 9.32pt of ink in a 9.02pt box
    // at 14pt) — clipping the frame. Width stays the metric advance.
    const ink = metrics.glyphInk(mcp);
    const box_idx = try list.create(
        .char,
        s(g.width, size_pt),
        ink.asc * size_pt,
        ink.desc * size_pt,
        &.{},
        mcp,
        cstyle,
        size_pt,
        span,
    );
    if (n.data != 0 or mcp != cp) list.boxes.items[box_idx].synthetic = true;
    return box_idx;
}

/// \dot \hat \bar \vec \ddot \tilde (a row marked `accent_row_data`;
/// children [base, accent-mark char]): lays out the base normally, then
/// draws the combining mark as a separate char box AT THE BASE SIZE on the
/// SAME baseline as the base, centered over it. The mark is ZERO-WIDTH (the
/// LM Math hmtx advance of every combining mark is 0, measured with
/// fontTools) — it never widens the box, exactly TeX's zero-width accents.
/// The mark's ink pokes above the base box, so the result box HEIGHT grows
/// to bound it (TeX: an accent noad's height is max(base, accent)); width
/// and depth stay the base's.
///
/// Placement facts (measured on latinmodern-math.otf 2.005 and the XeTeX
/// reference render at 10pt):
///   · LM Math draws every combining mark's ink 0.554–0.746em ABOVE its own
///     baseline (the marks live at the top of the em box) and 0.106–0.416em
///     tall. On the SAME baseline as an x-height base (ink top 0.442em) the
///     mark's ink bottom (0.521em) lands ~x_height/4 (0.108em) above the
///     base ink top — the font's own accent design. XeTeX places \dot{q}'s
///     dot at the base baseline (measured: every glyph, mark included, sits
///     on y = 7.427), so the mark baseline is NOT raised.
///   · every mark's ink is centered at −0.264em from the glyph origin (the
///     marks are designed to combine with a PRECEDING glyph), so the origin
///     is placed at the base's MATH-table MathTopAccentAttachment + 0.264em
///     (XeTeX's accent rule with unicode-math — the attachment point of the
///     slanted base's TOP, right of the ink center; measured \dot{q} at
///     40pt: dot ink at q_origin + 0.349em = u1D45E's attachment vs the
///     base ink center 0.246em).
/// The SVG emits the mark as a separate <text> with the standalone combining
/// char; the PIL critique raster and the geometric verifier draw it at the
/// positioned baseline from the real LM Math outlines, so the mark lands
/// exactly where this box says. A BROWSER may compose the standalone
/// combining char differently (small mark at its baseline) — acceptable;
/// the positioned box is the correct geometry. (Limitation: accents over
/// TALL bases — fractions, big operators — are not raised to clear the
/// base; the mark overlaps tall ink. TeX raises the accent via
/// AccentBaseHeight; out of scope for this minimal pass.)
fn layoutAccent(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
) !u32 {
    const span = ast.span(idx);
    const base = try layoutInner(list, ast, ast.child(idx, 0), fm, style, size_pt, cstyle, cramped);
    const bb = list.get(base);

    // The mark: a char box at the base size (XeTeX draws the mark at the
    // base's font size), zero advance, boxed by the drawn LM Math ink
    // (glyphInk). It uses the MATH font family (.italic) so the PIL
    // rasterizer and the browser pick the LM Math face, which carries the
    // combining marks (the roman text face does not).
    const accent_size = size_pt;
    const mark_atom = ast.node(ast.child(idx, 1));
    const mark_cp: u21 = @truncate(mark_atom.data);
    const ink = metrics.glyphInk(mark_cp);
    const mark = try list.create(
        .char,
        0, // combining marks are zero-advance in LM Math
        ink.asc * accent_size,
        ink.desc * accent_size,
        &.{},
        mark_cp,
        .italic,
        accent_size,
        span,
    );
    // The mark's utf-8 (the combining char) does not match the source span
    // ("\dot"), so flatten must dupe it into the arena instead of aliasing.
    list.boxes.items[mark].synthetic = true;

    // Horizontal: XeTeX+unicode-math places the mark's attachment point (the
    // combining marks draw their ink at −0.264em from the glyph origin — its
    // MathTopAccentAttachment) on the BASE's MATH-table MathTopAccentAttachment
    // — the slanted base's TOP, right of the ink center. So the mark origin
    // sits (attachment + 0.264) × accent_size right of the base origin.
    // Measured `\dot{q}` at 40pt: the reference dot ink lands at q_origin +
    // 0.349em = u1D45E's attachment, 0.103em right of the q ink center
    // (0.246em); the old box-center placement put it LEFT of the ink center
    // (0.223em). Bases without a row (composites, unmeasured glyphs) fall
    // back to centering on the base box. Vertical: the mark stays on the
    // base's baseline (XeTeX reference; the font's ink height does the rest).
    // The base's drawn glyph: the LAST char box inside the base. A braced
    // base ({q}, the common case) is a group → row hbox whose cp is 0, so
    // the MATH attachment must come from its inner char (TeX places the
    // accent over the box with the last character's skew — the XeTeX MATH
    // attachment of the same glyph; a plain atom base is already the char).
    // Descend only through rows (hbox), never into vboxes/scripts (accents
    // over those already fall back to centering — the tall-base limitation).
    var attach_cp: u21 = 0;
    var char_x: f32 = 0;
    {
        var cur = base;
        var xoff: f32 = 0;
        while (true) {
            const b = list.get(cur);
            if (b.kind == .char) {
                attach_cp = b.cp;
                char_x = xoff;
                break;
            }
            const ch = list.children(cur);
            if (b.kind != .hbox or ch.len == 0) break;
            const last = ch[ch.len - 1];
            xoff += last.x_shift;
            cur = last.idx;
        }
    }
    const attach = if (attach_cp != 0) metrics.accentAttach(attach_cp) else null;
    const x = if (attach) |a|
        char_x + (a + 0.264) * accent_size
    else
        bb.width / 2 + 0.264 * accent_size;

    // Vertical: the mark sits on the base's baseline UNLESS the base's ink
    // is taller than AccentBaseHeight (LM Math MATH-table: 0.45em), when
    // the mark is RAISED so its ink bottom clears the base's ink top — the
    // XeTeX+unicode-math rule (measured \hat{H} at 36pt: hat ink bottom
    // 0.819em = H ink top 0.683em + (0.587 natural bottom − 0.45)em; a
    // 13-base probe: clearance 0.1368em constant for every tall base,
    // natural position for short ones; \dot{q} — q ink top 0.442em — stays
    // unraised, exactly as before). Without the raise the \hat{H} hat ink
    // (bottom 0.587em) overlapped the H ink (top 0.683em) — the merge.
    const base_ink_top = if (attach_cp != 0) metrics.glyphInk(attach_cp).asc else null;
    const accent_base_height = 0.45; // LM Math AccentBaseHeight, em
    const raise = if (base_ink_top) |t| @max(0.0, t - accent_base_height) * accent_size else 0.0;

    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    try list.scratch.append(list.gpa, .{ .idx = base, .x_shift = 0, .shift = 0 });
    try list.scratch.append(list.gpa, .{ .idx = mark, .x_shift = x, .shift = -raise });
    // Width/depth stay the base's (the accent is zero-width); the height
    // grows to bound the raised mark's ink above the row baseline.
    return list.create(
        .hbox,
        bb.width,
        @max(bb.height, raise + ink.asc * accent_size),
        bb.depth,
        list.scratch.items[saved_len..],
        0,
        cstyle,
        0,
        span,
    );
}

/// \not<relation> (a row marked `not_row_data`; children [base]): lays the
/// base relation out normally, then overlays the U+0338 COMBINING LONG
/// SOLIDUS OVERLAY — the same glyph XeTeX+unicode-math draws for \not's
/// overlay fallback (\notaccent) — as a zero-width char box at the base
/// size, positioned exactly like XeTeX's \mathaccentoverlay placement
/// (xetex.web make_math_accent, measured on 20 XeTeX overlay renders at
/// 10pt/24.88pt):
///
///   Horizontal: XeTeX anchors the slash to the FIRST character inside the
///   base box (the accent's placement uses the base's MATH-table top-accent
///   attachment, or half the character's advance when it has none) and
///   lands the slash's own attachment (U+0338: −0.263em — its ink center)
///   on that anchor, so the slash origin sits (anchor + 0.264) × size right
///   of the base origin. Measured (all within 0.001em): \not y origin
///   +0.567em (attachment 0.304), \not\smile +0.763em (half 0.5em),
///   \not\bowtie +0.574em (0.311 → half 0.311), \not\top +0.652em (half
///   0.389), \not{ab} +0.550em (FIRST char a's attachment 0.287),
///   \not{xy} +0.592em (x's attachment 0.329), \not{\le x} +0.652em (half
///   of ≤'s advance 0.389), \not{\nabla x} +0.679em (half 0.4165).
///   Vertical: the vlist [slash, kern −δ, base] with δ = min(base_height,
///   AccentBaseHeight 0.45em) puts the slash's ink BOTTOM at max(0,
///   h − 0.45em) above the baseline; with the slash's own ink desc 0.25em
///   that raises the slash baseline by max(0.25em, h − 0.20em), where h is
///   the FIRST character's height (measured: smile/frown/y/q 0.250, bowtie
///   0.305, cup 0.404, top 0.464, nabla 0.483, \not\perp 0.484, {ab}/{xy}
///   0.250 via a/x, {\nabla x} 0.483 — every one within 0.009em). Bases
///   with no char inside (fractions, scripts) fall back to the base box's
///   half-width and height.
///   The slash box is ZERO-WIDTH (LM Math hmtx advance of combining marks
///   is 0) and synthetic (its utf-8 ≠ the "\not" source bytes), so flatten
///   dupes it into the arena like the accent marks. Result box: width and
///   depth stay the base's (the slash never pokes below the baseline —
///   raise ≥ 0.25em); the height grows to bound the slash's ink above.
fn layoutNot(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
) !u32 {
    const span = ast.span(idx);
    const base = try layoutInner(
        list,
        ast,
        ast.child(idx, 0),
        fm,
        style,
        size_pt,
        cstyle,
        cramped,
    );
    const bb = list.get(base);

    // The slash: U+0338, drawn at the base size, zero advance, boxed by
    // its drawn LM Math ink (asc 0.75em / desc 0.25em, measured with
    // fontTools: ink x[−0.458, −0.069], y[−0.25, +0.75] — a diagonal
    // across the em box, angle ≈ 68.7° from horizontal, which is exactly
    // the slash XeTeX draws for \not's overlay fallback).
    const ink = metrics.glyphInk(0x0338);
    const slash = try list.create(
        .char,
        0, // combining marks are zero-advance in LM Math
        ink.asc * size_pt,
        ink.desc * size_pt,
        &.{},
        0x0338,
        .italic, // the MATH font carries the combining overlay
        size_pt,
        span,
    );
    // The slash's utf-8 (U+0338) does not match the source span ("\not"),
    // so flatten must dupe it into the arena instead of aliasing.
    list.boxes.items[slash].synthetic = true;

    // XeTeX anchors the overlay to the FIRST character of the base box
    // (measured above). Descend hboxes to that char, accumulating the
    // horizontal offset; the char's attachment (or half its advance) and
    // its box height drive the placement. A bare char base is found at
    // depth 0; a braced group {≤ x} anchors on the ≤. Bases without a char
    // (fractions, scripts, empty groups) fall back to the whole box.
    var attach_cp: u21 = 0;
    var char_x: f32 = 0;
    var char_w: f32 = 0;
    var char_h: f32 = 0;
    {
        var cur = base;
        var xoff: f32 = 0;
        while (true) {
            const b = list.get(cur);
            if (b.kind == .char) {
                attach_cp = b.cp;
                char_x = xoff;
                char_w = b.width;
                char_h = b.height;
                break;
            }
            const ch = list.children(cur);
            if (b.kind != .hbox or ch.len == 0) break;
            const first = ch[0];
            xoff += first.x_shift;
            cur = first.idx;
        }
    }
    const anchor_w = if (attach_cp != 0) char_w else bb.width;
    const anchor_h = if (attach_cp != 0) char_h else bb.height;
    const attach = if (attach_cp != 0) metrics.accentAttach(attach_cp) else null;
    const x = if (attach) |a|
        char_x + (a + 0.264) * size_pt
    else
        char_x + anchor_w / 2 + 0.264 * size_pt;

    // Vertical: raise the slash baseline by max(0.25em, h − 0.20em), where
    // 0.25em = the slash's ink desc (= the LM Math axis height) and 0.20em
    // = AccentBaseHeight − axis (0.45 − 0.25) — XeTeX's overlay vlist
    // [accent, kern −min(h, 0.45em), base], measured above. The 0.25/0.20
    // em fractions enter as 10pt-base metrics (2.5pt / 2.0pt), scaled by
    // s() like every other em parameter in this file.
    const raise = @max(s(2.5, size_pt), anchor_h - s(2.0, size_pt));

    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    try list.scratch.append(list.gpa, .{ .idx = base, .x_shift = 0, .shift = 0 });
    try list.scratch.append(list.gpa, .{ .idx = slash, .x_shift = x, .shift = -raise });
    // Width/depth stay the base's (the slash's ink bottom is at or above
    // the baseline — raise ≥ 0.25em); the height grows to bound the
    // slash's ink above the row baseline.
    return list.create(
        .hbox,
        bb.width,
        @max(bb.height, raise + ink.asc * size_pt),
        bb.depth,
        list.scratch.items[saved_len..],
        0,
        cstyle,
        0,
        span,
    );
}

/// \overline{x} / \underline{x} (a `.overline` atom; data = 0 over / 1
/// under): lay out the content, then draw a rule of thickness rt =
/// rule_thickness (TeX's default_rule_thickness) at a clearance of 3·rt
/// from the content's box edge, spanning exactly the content width. This
/// is tex.web's overbar/make_over and make_under verbatim:
///
///   \overline: vlist [kern rt, rule rt, kern 3·rt, content] → box height
///     grows by 5·rt (rt of air above the rule), depth unchanged; the
///     rule's bottom edge sits at height(content) + 3·rt. The content is
///     laid out CRAMPED (make_over's cramped_style), squeezing scripts.
///   \underline: vlist [content, kern 3·rt, rule rt] → box depth grows by
///     4·rt, height unchanged; the rule's top edge sits at
///     depth(content) + 3·rt below the baseline. The content keeps the
///     current (uncramped) style (make_under's clean_box at cur_style).
///
/// Measured against the XeTeX reference (unicode-math, 36pt): the rule is
/// 0.04em thick and its inner edge sits 0.120em = 3·0.04em from the
/// content ink (LM Math hmtx height/depth == the drawn ink, so the
/// ink-based boxes place the rule exactly like TeX's font-metric boxes).
fn layoutOverUnder(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    const under = n.data != 0;
    const gl = fm.glue(fm);
    const rt = s(gl.rule_thickness, size_pt);
    // \overline lays its content out CRAMPED (tex.web make_over:
    // cramped_style(cur_style)); \underline keeps the current style
    // (make_under: clean_box at cur_style).
    const content_cramped = if (under) cramped else true;
    const content = try layoutInner(
        list,
        ast,
        ast.child(idx, 0),
        fm,
        style,
        size_pt,
        cstyle,
        content_cramped,
    );
    const cb = list.get(content);

    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    try list.scratch.append(list.gpa, .{ .idx = content, .x_shift = 0, .shift = 0 });
    if (under) {
        // Rule centered at depth + 3·rt + rt/2 BELOW the baseline (its own
        // height = depth = rt/2 spans [depth + 3·rt, depth + 4·rt]); the
        // box depth grows by 4·rt, the height stays the content's.
        const rule = try list.createLeaf(.rule, cb.width, rt / 2, rt / 2, span);
        try list.scratch.append(list.gpa, .{ .idx = rule, .x_shift = 0, .shift = cb.depth + 3 * rt + rt / 2 });
        return list.create(
            .hbox,
            cb.width,
            cb.height,
            cb.depth + 4 * rt,
            list.scratch.items[saved_len..],
            0,
            cstyle,
            0,
            span,
        );
    }
    // Rule centered at height + 3·rt + rt/2 ABOVE the baseline (spans
    // [height + 3·rt, height + 4·rt]); the box height grows by 5·rt — the
    // extra rt is TeX's leading kern, so the rule is NOT at the box top.
    const rule = try list.createLeaf(.rule, cb.width, rt / 2, rt / 2, span);
    try list.scratch.append(list.gpa, .{ .idx = rule, .x_shift = 0, .shift = -(cb.height + 3 * rt + rt / 2) });
    return list.create(
        .hbox,
        cb.width,
        cb.height + 5 * rt,
        cb.depth,
        list.scratch.items[saved_len..],
        0,
        cstyle,
        0,
        span,
    );
}

fn layoutRow(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    const gl = fm.glue(fm);
    var x: f32 = 0;
    var height: f32 = 0;
    var depth: f32 = 0;
    var prev_role: ?Role = null;
    var prev_is_space = false;
    for (0..n.num_children) |i| {
        const child_idx = ast.child(idx, i);
        const child_atom = ast.node(child_idx);
        // TeX: a bin atom is demoted to ord at the start of a list, after
        // bin/op/rel/open/punct, or before rel/close/punct (TeXBook p.170;
        // MicroTeX RowAtom::changeToOrd).
        var role = leftRole(ast, child_idx);
        if (role == .bin) {
            const demote_prev = if (prev_role) |pr|
                pr == .bin or pr == .op or pr == .rel or pr == .open or pr == .punct
            else
                true;
            const demote_next = if (i + 1 < n.num_children) blk: {
                const nr = leftRole(ast, ast.child(idx, i + 1));
                break :blk nr == .rel or nr == .close or nr == .punct;
            } else true;
            if (demote_prev or demote_next) role = .ord;
        }
        // Inter-atom glue (TeXBook p.181), suppressed around explicit spaces
        // and between no-glue pairs.
        if (i > 0 and !prev_is_space and child_atom.tag != .space) {
            if (prev_role) |pr| {
                const units = glueUnits(pr, role, style);
                if (units != 0) {
                    const w = glue_em[units] * size_pt * quadEm(style) / 18.0;
                    const g = try list.createLeaf(.glue, w, 0, 0, span);
                    try list.scratch.append(list.gpa, .{ .idx = g, .x_shift = x, .shift = 0 });
                    x += w;
                }
            }
        }
        // A \middle delimiter: a zero-width placeholder box. The enclosing
        // \left...\right's layoutLeftRight computes the fence's required ink
        // from the inner content (the placeholder contributes nothing) and
        // then rewrites this box in place to the fence-sized delimiter — the
        // delimiter's OWN smallest MATH variant covering the same req.
        const child_box = if (child_atom.tag == .char and (child_atom.data & middle_marker) != 0) blk: {
            const mn = ast.node(child_idx);
            const mcp: u21 = @truncate(mn.data);
            const ph = try list.create(.char, 0, 0, 0, &.{}, mcp, cstyle, size_pt, span);
            // The delimiter glyph does not match the "\middle..." source
            // bytes, so flatten must dupe it into the arena, not alias.
            list.boxes.items[ph].synthetic = true;
            break :blk ph;
        } else try layoutInner(
            list,
            ast,
            child_idx,
            fm,
            style,
            size_pt,
            cstyle,
            cramped,
        );
        const cb = list.get(child_box);
        // A BARE big operator is axis-centered: make_op sets the op box's
        // shift_amount to (h−d)/2 − axis in EVERY style (TeXbook rule 13b).
        // The box's h/d are the DRAWN glyph's ink extents (bigOpInk × drawn
        // size), so this shift puts the ink CENTER on the math axis — the
        // old cmex10 hang-below box placed the LMMath glyph's baseline where
        // the cmex glyph's baseline should be, riding 0.75–1.1em too high
        // (top-clipped). The row absorbs the shift into its height/depth so
        // the operand stays on the baseline (the row of `\int x` is
        // h=13.61 d=8.61 at 10pt, x on the baseline).
        const op_shift: f32 = if (ast.node(unwrapAtom(ast, child_idx)).tag == .op)
            (cb.height - cb.depth) / 2 - s(gl.axis_height, size_pt)
        else
            0;
        try list.scratch.append(list.gpa, .{ .idx = child_box, .x_shift = x, .shift = op_shift });
        x += cb.width;
        // Post-op italic-correction tail: TeX appends the operator's
        // italic correction to the advance before the next atom (TeXbook
        // p.170; measured post-∫ advance 16.15pt = box + ic + thin — ztex
        // was 6.65pt short).
        x += opTailIc(ast, child_idx, fm, style, size_pt);
        height = @max(height, cb.height - op_shift);
        depth = @max(depth, cb.depth + op_shift);
        prev_role = if (child_atom.tag == .char) role else rightRole(ast, child_idx);
        prev_is_space = child_atom.tag == .space;
    }
    return list.create(.hbox, x, height, depth, list.scratch.items[saved_len..], 0, cstyle, 0, span);
}

/// \substack{a \\ b \\ c} (atom `.substack`, children = the line rows):
/// amsmath's script-size multi-line stack for limits. Each line lays out
/// at \scriptstyle (one level down from display/text; the root-relative
/// ladder grows the lines back to the script size from deeper styles), is
/// centered horizontally in the stack, and the lines stack vertically with
/// the TeX \subarray gaps (amsmath.sty, the XeTeX/OT-math branch):
///
///     \baselineskip = \Umathstacknumup + \Umathstackdenomdown (script size)
///     \lineskip     = \Umathstackvgap (script size)
///     \lineskiplimit = \lineskip
///
/// with Latin Modern Math's MATH-table constants StackTopShiftUp 0.444em,
/// StackBottomShiftDown 0.345em, StackGapMin 0.120em at the SCRIPT size —
/// baseline-to-baseline = max(0.789·script, d_prev + h_next + 0.120·script),
/// measured against the XeTeX reference of
/// \sum_{\substack{i=1 \\ j=1}}^{n} x_i x_j at 36pt: the lines separate by
/// exactly d_prev + h_next + vgap (20.08pt; the 0.789·script nominal
/// baselineskip 19.88pt loses to the digit-height lines), and the stack's
/// line-1 baseline lands at op_bottom + max(bigop2, bigop4 − stack_h) +
/// stack_h — i.e. the reported stack box is the RAW stack (height = line
/// 1's height, depth = the last line's depth below line 1's baseline), NOT
/// the amsmath \vcenter'd (H−D)/2 ± axis box: the measured reference
/// placement under a display ∑ matches the raw box exactly (38.92pt vs
/// 38.85pt measured) while the vcenter model would sit 3.9pt higher. The
/// depth folds in the full stack (last line's baseline + depth) so the box
/// bounds every line's ink.
fn layoutSubstack(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    const gl = fm.glue(fm);
    // amsmath \subarray: every cell is $\m@th\scriptstyle##$ — the lines
    // are ALWAYS script style. The size follows the root-relative ladder:
    // display/text → script size (×0.7), script → unchanged (the limits
    // path already passes the script size), scriptscript → back up to the
    // script size (0.7/0.5), exactly a forced \scriptstyle.
    const s_size = size_pt * (styleScale(gl, .script) / styleScale(gl, style));
    const baselineskip = (0.444 + 0.345) * s_size; // StackTopShiftUp + StackBottomShiftDown
    const lineskip = 0.120 * s_size; // StackGapMin

    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    var max_w: f32 = 0;
    var h1: f32 = 0;
    var y_last: f32 = 0; // last line's baseline below line 1's baseline
    var d_last: f32 = 0;
    var prev_d: f32 = 0;
    var y: f32 = 0;
    for (0..n.num_children) |i| {
        const line = try layoutInner(list, ast, ast.child(idx, i), fm, .script, s_size, cstyle, false);
        const lb = list.get(line);
        if (i > 0) {
            // baseline separation: max(nominal baselineskip, prev depth +
            // this height + \lineskiplimit), the TeX \baselineskip rule
            y += @max(baselineskip, prev_d + lb.height + lineskip);
        }
        // Record the placement; x-centering is applied once the max width
        // is known, so store the raw line box and patch the x_shift below.
        try list.scratch.append(list.gpa, .{ .idx = line, .x_shift = 0, .shift = y });
        max_w = @max(max_w, lb.width);
        if (i == 0) h1 = lb.height;
        y_last = y;
        d_last = lb.depth;
        prev_d = lb.depth;
    }
    // Center each line horizontally in the stack box.
    for (list.scratch.items[saved_len..]) |*cr| {
        const b = list.get(cr.idx);
        cr.x_shift = (max_w - b.width) / 2;
    }
    return list.create(.hbox, max_w, h1, y_last + d_last, list.scratch.items[saved_len..], 0, cstyle, 0, span);
}

/// \pmod{n} / \pod{n} (a row marked pmod_row_data / pod_row_data; children
/// ['(', (opname "mod", 6mu space, for \pmod), arg, ')']): amsmath's
/// parenthesized mod — amsmath.sty:
///
///     \pod#1{\allowbreak \if@display\mkern18mu\else\mkern8mu\fi (#1)}
///     \pmod#1{\pod{{\operator@font mod}\mkern6mu#1}}
///
/// The leading \mkern is style-dependent: 18mu (1em) in display math,
/// 8mu (8/18 em) in text/script/scriptscript (the \if@display is a MATH
/// MODE check — inline $\displaystyle ...$ still gets 8mu, verified on
/// the XeTeX reference at 36pt: b→( gap = b advance + 8mu). The rest is
/// placed back to back with NO inter-atom glue: every pair in the
/// composition (kern–(, (–mod, mod–6mu, 6mu–arg, arg–)) has zero glue in
/// the TeX table, and TeX's \mkern suppresses any letter kern across it —
/// so the pieces are simply laid at their advances with the two explicit
/// kerns. The 6mu mod-n gap is a plain 6/18-em space leaf. The "mod" word
/// is the ordinary opname mechanism (roman letters, no kerning), so it
/// matches the KaTeX reference at every size (KaTeX_Main m/o/d/n advances
/// equal ztex's cmr10 table) and the XeTeX reference at sizes ≤12pt; at
/// larger sizes XeTeX's fontspec optical-size selection swaps the roman
/// text font to LMRoman17 (measured m 0.772/o 0.459/d 0.511em vs the
/// 0.833/0.5/0.556 cmr values), a pre-existing ztex-vs-XeTeX gap that
/// affects ALL roman rendering (\mathrm, \operatorname, opnames), not just
/// \pmod.
fn layoutPmod(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    const kern_leading = if (style == .display) size_pt else (8.0 / 18.0) * size_pt;
    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    const lead = try list.createLeaf(.glue, kern_leading, 0, 0, span);
    try list.scratch.append(list.gpa, .{ .idx = lead, .x_shift = 0, .shift = 0 });
    var x = kern_leading;
    var height: f32 = 0;
    var depth: f32 = 0;
    for (0..n.num_children) |i| {
        const cb = try layoutInner(list, ast, ast.child(idx, i), fm, style, size_pt, cstyle, cramped);
        const b = list.get(cb);
        try list.scratch.append(list.gpa, .{ .idx = cb, .x_shift = x, .shift = 0 });
        x += b.width;
        height = @max(height, b.height);
        depth = @max(depth, b.depth);
    }
    return list.create(.hbox, x, height, depth, list.scratch.items[saved_len..], 0, cstyle, 0, span);
}

/// The italic correction (in em of the glyph's font-size) that
/// XeTeX+unicode-math appends after a character in a math list — read from
/// the MathItalicsCorrectionInfo table of latinmodern-math.otf 2.005
/// (fontTools). TeX adds a char's italic correction to the width when it
/// ends a math list (tex.web math_trans), so an \halign CELL's width is
/// advance + IC of its last char — measured on the XeTeX reference: the
/// pmatrix column 2 box is 10 + max(b 4.29 + 0.14, d 5.20 + 0.24) = 15.44pt
/// at 10pt, and the aligned left column is right-aligned to
/// max(a 5.29 + 0, d 5.20 + 0.24) = 5.44pt. The static metrics table's
/// italic corrections are Computer-Modern values (b/d = 0), which would
/// shrink the columns by 0.14/0.24pt at 10pt (0.5/0.86pt at 36pt) — so the
/// env layout reads the LM Math ICs from this table. Glyphs without an
/// entry (a, x, digits except 7, relations, big ops) have IC 0.
const env_ic_table = [_]struct { cp: u21, ic: f32 }{
    .{ .cp = 0x0037, .ic = 0.0130 },
    .{ .cp = 0x0052, .ic = 0.0240 },
    .{ .cp = 0x0056, .ic = 0.0080 },
    .{ .cp = 0x0057, .ic = 0.0090 },
    .{ .cp = 0x0058, .ic = 0.0040 },
    .{ .cp = 0x0059, .ic = 0.0160 },
    .{ .cp = 0x005B, .ic = 0.0060 },
    .{ .cp = 0x005E, .ic = 0.0330 },
    .{ .cp = 0x005F, .ic = 0.0280 },
    .{ .cp = 0x0061, .ic = 0.0110 },
    .{ .cp = 0x0066, .ic = 0.0790 },
    .{ .cp = 0x0067, .ic = 0.0130 },
    .{ .cp = 0x0068, .ic = 0.0070 },
    .{ .cp = 0x006B, .ic = 0.0110 },
    .{ .cp = 0x006C, .ic = 0.0050 },
    .{ .cp = 0x006D, .ic = 0.0080 },
    .{ .cp = 0x006E, .ic = 0.0070 },
    .{ .cp = 0x0071, .ic = 0.0270 },
    .{ .cp = 0x0075, .ic = 0.0070 },
    .{ .cp = 0x0076, .ic = 0.0080 },
    .{ .cp = 0x0077, .ic = 0.0090 },
    .{ .cp = 0x0078, .ic = 0.0160 },
    .{ .cp = 0x0079, .ic = 0.0080 },
    .{ .cp = 0x007E, .ic = 0.0270 },
    .{ .cp = 0x1D435, .ic = 0.0250 },
    .{ .cp = 0x1D436, .ic = 0.0730 },
    .{ .cp = 0x1D437, .ic = 0.0040 },
    .{ .cp = 0x1D438, .ic = 0.0540 },
    .{ .cp = 0x1D439, .ic = 0.1340 },
    .{ .cp = 0x1D43B, .ic = 0.0780 },
    .{ .cp = 0x1D43C, .ic = 0.0850 },
    .{ .cp = 0x1D43D, .ic = 0.1060 },
    .{ .cp = 0x1D43E, .ic = 0.0680 },
    .{ .cp = 0x1D440, .ic = 0.1020 },
    .{ .cp = 0x1D441, .ic = 0.1060 },
    .{ .cp = 0x1D442, .ic = 0.0050 },
    .{ .cp = 0x1D443, .ic = 0.1400 },
    .{ .cp = 0x1D445, .ic = 0.0240 },
    .{ .cp = 0x1D446, .ic = 0.0600 },
    .{ .cp = 0x1D447, .ic = 0.1480 },
    .{ .cp = 0x1D448, .ic = 0.1050 },
    .{ .cp = 0x1D449, .ic = 0.2140 },
    .{ .cp = 0x1D44A, .ic = 0.1320 },
    .{ .cp = 0x1D44B, .ic = 0.0510 },
    .{ .cp = 0x1D44C, .ic = 0.2090 },
    .{ .cp = 0x1D44D, .ic = 0.0680 },
    .{ .cp = 0x1D44F, .ic = 0.0140 },
    .{ .cp = 0x1D450, .ic = 0.0250 },
    .{ .cp = 0x1D451, .ic = 0.0240 },
    .{ .cp = 0x1D453, .ic = 0.0900 },
    .{ .cp = 0x1D454, .ic = 0.0250 },
    .{ .cp = 0x1D457, .ic = 0.0130 },
    .{ .cp = 0x1D458, .ic = 0.0150 },
    .{ .cp = 0x1D45C, .ic = 0.0120 },
    .{ .cp = 0x1D45D, .ic = 0.0150 },
    .{ .cp = 0x1D45E, .ic = 0.0340 },
    .{ .cp = 0x1D45F, .ic = 0.0130 },
    .{ .cp = 0x1D463, .ic = 0.0110 },
    .{ .cp = 0x1D464, .ic = 0.0030 },
    .{ .cp = 0x1D466, .ic = 0.0280 },
    .{ .cp = 0x1D467, .ic = 0.0300 },
    .{ .cp = 0x1D6E3, .ic = 0.0250 },
    .{ .cp = 0x1D6E4, .ic = 0.1340 },
    .{ .cp = 0x1D6E6, .ic = 0.0540 },
    .{ .cp = 0x1D6E7, .ic = 0.0680 },
    .{ .cp = 0x1D6E8, .ic = 0.0780 },
    .{ .cp = 0x1D6E9, .ic = 0.0050 },
    .{ .cp = 0x1D6EA, .ic = 0.0850 },
    .{ .cp = 0x1D6EB, .ic = 0.0680 },
    .{ .cp = 0x1D6ED, .ic = 0.1020 },
    .{ .cp = 0x1D6EE, .ic = 0.1060 },
    .{ .cp = 0x1D6EF, .ic = 0.0630 },
    .{ .cp = 0x1D6F0, .ic = 0.0050 },
    .{ .cp = 0x1D6F1, .ic = 0.0770 },
    .{ .cp = 0x1D6F2, .ic = 0.1400 },
    .{ .cp = 0x1D6F3, .ic = 0.0050 },
    .{ .cp = 0x1D6F4, .ic = 0.0540 },
    .{ .cp = 0x1D6F5, .ic = 0.1480 },
    .{ .cp = 0x1D6F6, .ic = 0.1460 },
    .{ .cp = 0x1D6F7, .ic = 0.0040 },
    .{ .cp = 0x1D6F8, .ic = 0.0510 },
    .{ .cp = 0x1D6F9, .ic = 0.1090 },
    .{ .cp = 0x1D6FA, .ic = 0.0420 },
    .{ .cp = 0x1D6FD, .ic = 0.0360 },
    .{ .cp = 0x1D6FE, .ic = 0.0530 },
    .{ .cp = 0x1D6FF, .ic = 0.0360 },
    .{ .cp = 0x1D701, .ic = 0.0640 },
    .{ .cp = 0x1D702, .ic = 0.0270 },
    .{ .cp = 0x1D703, .ic = 0.0140 },
    .{ .cp = 0x1D708, .ic = 0.0580 },
    .{ .cp = 0x1D709, .ic = 0.0360 },
    .{ .cp = 0x1D70A, .ic = 0.0120 },
    .{ .cp = 0x1D70B, .ic = 0.0250 },
    .{ .cp = 0x1D70C, .ic = 0.0130 },
    .{ .cp = 0x1D70D, .ic = 0.0740 },
    .{ .cp = 0x1D70E, .ic = 0.0240 },
    .{ .cp = 0x1D70F, .ic = 0.1020 },
    .{ .cp = 0x1D710, .ic = 0.0120 },
    .{ .cp = 0x1D713, .ic = 0.0120 },
    .{ .cp = 0x1D714, .ic = 0.0100 },
    .{ .cp = 0x1D715, .ic = 0.0630 },
    .{ .cp = 0x1D719, .ic = 0.0050 },
    .{ .cp = 0x1D71A, .ic = 0.0130 },
    .{ .cp = 0x1D71B, .ic = 0.0170 },
    .{ .cp = 0x1D7D5, .ic = 0.0110 },
};

/// The LM Math italic correction (em) of a drawn codepoint; 0 when the
/// glyph has no MATH-table entry.
fn envIc(cp: u21) f32 {
    var lo: usize = 0;
    var hi: usize = env_ic_table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (env_ic_table[mid].cp < cp) lo = mid + 1 else hi = mid;
    }
    if (lo < env_ic_table.len and env_ic_table[lo].cp == cp) return env_ic_table[lo].ic;
    return 0;
}

/// Whether an `.env` node carries delimiter children (the pmatrix family
/// and cases). The parser stores the open/close delimiter char leaves as
/// the first/last children; delimiter-less envs (matrix, aligned, array)
/// are plain \vcenter boxes.
fn envHasDelims(ast: *const atom.Ast, idx: u32) bool {
    const n = ast.node(idx);
    return n.num_children > 0 and ast.node(n.first_child).tag == .char;
}

/// The italic correction (in pt at the current size) XeTeX appends after a
/// cell's LAST character. The env's column widths and the aligned/right
/// alignments measure it (see layoutEnv): resolve the cell's last atom,
/// map it to the DRAWN codepoint the way layoutChar does (math-italic
/// letters, - → U+2212), and read the LM Math IC (env_ic_table).
fn cellTrailingIc(
    ast: *const atom.Ast,
    cell: u32,
    fm: *const metrics.FontMetrics,
    cstyle: atom.CharStyle,
    size_pt: f32,
) f32 {
    // Walk to the LAST atom: transparent wrappers and rows report their
    // last child; a group's content is the cell's only child; a scripted
    // cell ends in its last script's content.
    var u = cell;
    while (true) {
        const c = ast.node(u);
        switch (c.tag) {
            .group, .styled, .mathstyle => {
                if (c.num_children == 0) return 0;
                u = ast.child(u, 0);
            },
            .row, .left, .script => {
                if (c.num_children == 0) return 0;
                u = ast.child(u, c.num_children - 1);
            },
            else => break,
        }
    }
    const n = ast.node(u);
    if (n.tag != .char) return 0;
    const sp = ast.span(u);
    var cp: u21 = if (n.data != 0) @truncate(n.data) else firstCodepoint(ast.src[sp.start..sp.end]);
    if (cp == 0x2D) cp = 0x2212;
    if (cstyle == .italic) {
        if (mathItalic(cp)) |m| {
            if (metrics.hasGlyph(fm, m, cstyle)) cp = m;
        }
    }
    const ic = envIc(cp);
    return if (ic == 0) 0 else ic * size_pt;
}

/// \begin{env}...\end{env} (atom `.env`; children [open?, row1..rowN,
/// close?], each row a `.row` of cell atoms): the matrix family (matrix /
/// pmatrix / bmatrix / Bmatrix / vmatrix / Vmatrix), cases, aligned and
/// array. Every geometry constant below was verified against the
/// XeTeX+unicode-math reference (\showbox at 10pt plus per-glyph extraction
/// at 36pt):
///   · CELLS lay out at the current style/size. cases forces its SECOND
///     column to text style (per the feature spec; TeX's \array sets ALL
///     cells in $...$ text style — a nuance that only shows in
///     style-sensitive cells like fractions).
///   · COLUMN WIDTH = max over rows of (cell box width + the last char's
///     italic correction) — XeTeX appends the MATH-table IC of a cell's
///     last char (measured: pmatrix col2 = 10 + max(b 4.29+0.14,
///     d 5.20+0.24) = 15.44pt at 10pt; the aligned left column is
///     right-aligned to max(a 5.29+0, d 5.20+0.24) = 5.44pt). The ICs come
///     from env_ic_table (the static metrics table's ICs are CM values).
///   · COLUMNS are \halign columns `\hskip\arraycolsep \hfil cell \hfil
///     \hskip\arraycolsep` — \arraycolsep = 5pt FIXED on each side of
///     every column box, boxes adjacent (tabskip 0), so the
///     content-to-content gap is 2·arraycolsep = 10pt. amsmath's
///     \hskip -\arraycolsep around the matrix cancels the outer pads:
///     measured content-to-content 10pt, delimiters flush against the
///     array (the pmatrix `a` sits exactly at the paren box's right edge).
///     array applies the packed colspec: l/c/r alignment, and `|` draws a
///     \vrule of \arrayrulewidth = 0.4pt centered at the column boundary,
///     spanning the row's strut extent (each row carries its own rule —
///     TeX's template puts the vrule inside every row's column box, so the
///     overlapping rules read as one continuous line). cases uses
///     \arraycolsep = 0 with a \quad (1em) between columns (the @{\quad}
///     preamble puts it INSIDE the column width, measured 10pt at 10pt).
///     aligned builds \hfil\strut cell \tabskip0 / cell \hfil: the left
///     parts right-aligned to the max left width, the right parts
///     left-aligned, adjacent (the \minalignsep trailing tabskip is
///     cancelled by \math@cr@@@aligned's \kern-\alignsep@ — the "10pt"
///     gap between a and = is the THICK rel glue inside the right part).
///   · ROWS get a strut of 0.7/0.3 \baselineskip (1.2× the current size;
///     ×\arraystretch 1.2 for cases). matrix/array/cases stack rows
///     DIRECTLY (LaTeX \@array zeroes \baselineskip/\lineskip — the strut
///     forces the baseline distance = \baselineskip, measured 12pt at
///     10pt, 43.2pt at 36pt). aligned \openup\jot's the interline:
///     baselineskip+3pt, limit 3pt, lineskip 4pt — measured 3pt gap at
///     both sizes.
///   · the whole array is \vcenter'd (its vertical center sits on the math
///     axis — TeX \vcenter shift (h−d)/2 − axis, measured (14.5−9.5)/2 =
///     axis at 10pt); the pmatrix-family delimiters box via the variant
///     ladder like \left..\right (layoutDelimChar), req from the array's
///     extent — the 2×2 letter matrix resolves parenleft.v6 at 10pt,
///     exactly the reference \showbox (h 14.46, d 9.46).
fn layoutEnv(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    const kind = atom.envKind(n.data);
    const gl = fm.glue(fm);
    const axis = s(gl.axis_height, size_pt);

    // Row/column geometry parameters (see the doc comment; values measured
    // against the XeTeX reference at 10pt and 36pt).
    const acs: f32 = if (kind == .cases) 0 else 5.0; // \arraycolsep (fixed pt)
    const stretch: f32 = if (kind == .cases) 1.2 else 1.0; // \arraystretch
    const bs = 1.2 * size_pt; // \baselineskip (LaTeX normalsize ratio)
    const strut_h = 0.7 * bs * stretch;
    const strut_d = 0.3 * bs * stretch;
    const quad = size_pt; // 1em, the cases column gap

    // Children: [open?, row1..rowN, close?] — the delimiter char leaves
    // (tag .char) bracket the row atoms (tag .row).
    var row_first: u32 = 0;
    var row_count: u32 = n.num_children;
    var open_idx: ?u32 = null;
    var close_idx: ?u32 = null;
    if (n.num_children > 0 and ast.node(n.first_child).tag == .char) {
        open_idx = n.first_child;
        row_first = 1;
        row_count -= 1;
    }
    if (row_count > 0 and ast.node(n.first_child + row_first + row_count - 1).tag == .char) {
        close_idx = n.first_child + row_first + row_count - 1;
        row_count -= 1;
    }
    const nrows = row_count;

    // 1. Lay out every cell. Each cell records its box plus its TeX width
    // (box width + the last char's italic correction — what \halign
    // measures the columns by).
    const Cell = struct { box: u32, w: f32, h: f32, d: f32 };
    var cells: std.ArrayList(Cell) = .empty;
    defer cells.deinit(list.gpa);
    var row_start: std.ArrayList(u32) = .empty;
    defer row_start.deinit(list.gpa);
    var ncols: usize = 0;
    for (0..nrows) |r| {
        const row_node = ast.node(n.first_child + row_first + @as(u32, @intCast(r)));
        try row_start.append(list.gpa, @intCast(cells.items.len));
        for (0..row_node.num_children) |ci| {
            const child = row_node.first_child + @as(u32, @intCast(ci));
            // cases: the SECOND column is set in text style (feature spec).
            const cell_style: Style = if (kind == .cases and ci >= 1) .text else style;
            const box_idx = try layoutInner(list, ast, child, fm, cell_style, size_pt, cstyle, cramped);
            const b = list.get(box_idx);
            const ic = cellTrailingIc(ast, child, fm, cstyle, size_pt);
            try cells.append(list.gpa, .{ .box = box_idx, .w = b.width + ic, .h = b.height, .d = b.depth });
        }
        ncols = @max(ncols, row_node.num_children);
    }
    if (ncols == 0) {
        // An empty environment: a zero box (delimiters still drawn at the
        // base variant — TeX renders \begin{pmatrix}\end{pmatrix} as a
        // pair of base-size parens).
        const saved_len = list.scratch.items.len;
        defer list.scratch.items.len = saved_len;
        var x: f32 = 0;
        var height: f32 = 0;
        var depth: f32 = 0;
        if (open_idx) |o| {
            const ob = try layoutDelimChar(list, ast, o, fm, axis / size_pt, size_pt, cstyle);
            const b = list.get(ob);
            const sh = (b.height - b.depth) / 2 - axis;
            try list.scratch.append(list.gpa, .{ .idx = ob, .x_shift = x, .shift = sh });
            x += b.width;
            height = @max(height, b.height - sh);
            depth = @max(depth, b.depth + sh);
        }
        if (close_idx) |c| {
            const cb = try layoutDelimChar(list, ast, c, fm, axis / size_pt, size_pt, cstyle);
            const b = list.get(cb);
            const sh = (b.height - b.depth) / 2 - axis;
            try list.scratch.append(list.gpa, .{ .idx = cb, .x_shift = x, .shift = sh });
            x += b.width;
            height = @max(height, b.height - sh);
            depth = @max(depth, b.depth + sh);
        }
        return list.create(.hbox, x, height, depth, list.scratch.items[saved_len..], 0, cstyle, 0, span);
    }

    // 2. Column widths = max cell width per column.
    var col_w: std.ArrayList(f32) = .empty;
    defer col_w.deinit(list.gpa);
    try col_w.appendNTimes(list.gpa, 0, ncols);
    for (0..nrows) |r| {
        const start = row_start.items[r];
        const end = if (r + 1 < nrows) row_start.items[r + 1] else @as(u32, @intCast(cells.items.len));
        for (start..end) |ci| {
            const c = ci - start;
            col_w.items[c] = @max(col_w.items[c], cells.items[ci].w);
        }
    }
    // cases: the \quad lives INSIDE every non-last column's width (the
    // @{\quad} preamble), so the array advance includes it.
    if (kind == .cases) {
        for (0..ncols - 1) |c| col_w.items[c] += quad;
    }

    // 3. Row boxes: the strut forces each row to at least 0.7/0.3
    // \baselineskip; rows stack directly (matrix/array/cases) or with the
    // \openup\jot interline algorithm (aligned).
    var row_h: std.ArrayList(f32) = .empty;
    defer row_h.deinit(list.gpa);
    var row_d: std.ArrayList(f32) = .empty;
    defer row_d.deinit(list.gpa);
    for (0..nrows) |r| {
        const start = row_start.items[r];
        const end = if (r + 1 < nrows) row_start.items[r + 1] else @as(u32, @intCast(cells.items.len));
        var h: f32 = 0;
        var d: f32 = 0;
        for (cells.items[start..end]) |cl| {
            h = @max(h, cl.h);
            d = @max(d, cl.d);
        }
        try row_h.append(list.gpa, @max(strut_h, h));
        try row_d.append(list.gpa, @max(strut_d, d));
    }
    const bs_jot = bs + 3.0; // \openup\jot for aligned
    var row_shift: std.ArrayList(f32) = .empty;
    defer row_shift.deinit(list.gpa);
    try row_shift.append(list.gpa, 0);
    for (1..nrows) |r| {
        var gap: f32 = bs_jot - (row_h.items[r - 1] + row_d.items[r]);
        if (kind == .aligned) {
            if (gap < 3.0) gap = 4.0; // \lineskiplimit 3, \lineskip 4
        } else {
            gap = 0;
        }
        try row_shift.append(list.gpa, row_shift.items[r - 1] - (row_h.items[r - 1] + row_d.items[r] + gap));
    }
    var h_nat: f32 = 0;
    var d_nat: f32 = 0;
    for (0..nrows) |r| {
        h_nat = @max(h_nat, row_shift.items[r] + row_h.items[r]);
        d_nat = @max(d_nat, -(row_shift.items[r] - row_d.items[r]));
    }
    // \vcenter: the array's vertical center lands on the math axis.
    const shift_s = axis - (h_nat - d_nat) / 2;
    const arr_h = h_nat + shift_s;
    const arr_d = d_nat - shift_s;

    // 4. Column x origins (content-area starts) and the array advance.
    // matrix/array: [acs][content][acs] boxes, adjacent → content x_i =
    // acs + Σ_{j<i} (2·acs + W_j). cases: [content][quad] — content x_i =
    // Σ_{j<i} W_j (quad included in the widths). aligned: [content]
    // adjacent — x_0 = 0, x_1 = W_0.
    var col_origin: std.ArrayList(f32) = .empty;
    defer col_origin.deinit(list.gpa);
    var x: f32 = 0;
    if (kind == .aligned) {
        for (0..ncols) |c| {
            try col_origin.append(list.gpa, x);
            x += col_w.items[c];
        }
    } else if (kind == .cases) {
        for (0..ncols) |c| {
            try col_origin.append(list.gpa, x);
            x += col_w.items[c];
        }
    } else {
        for (0..ncols) |c| {
            try col_origin.append(list.gpa, x + acs);
            x += 2 * acs + col_w.items[c];
        }
    }
    const arr_w = x;

    // 5. Build the array vbox: per row, the row hbox places each cell at
    // its column x + alignment offset; array `|` rules (and a leading
    // rule) are drawn in every row at the boundary, spanning the row's
    // strut extent. The row hbox width = the array width (the \halign
    // stretches every row), and the array vbox stacks the rows with the
    // \vcenter shift.
    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    var array_children: std.ArrayList(box.ChildRef) = .empty;
    defer array_children.deinit(list.gpa);
    for (0..nrows) |r| {
        const start = row_start.items[r];
        const end = if (r + 1 < nrows) row_start.items[r + 1] else @as(u32, @intCast(cells.items.len));
        const row_saved = list.scratch.items.len;
        var row_children: std.ArrayList(box.ChildRef) = .empty;
        defer row_children.deinit(list.gpa);
        for (start..end) |ci| {
            const c = ci - start;
            const cl = cells.items[ci];
            // Alignment within the column: matrix family centered; array
            // per the packed colspec (default centered); cases left;
            // aligned: col 0 right, the rest left.
            const off: f32 = if (kind == .aligned)
                (if (c == 0) col_w.items[0] - cl.w else 0)
            else if (kind == .cases)
                0
            else blk: {
                const spec = if (kind == .array) atom.envColSpec(n.data, c) else null;
                const mode = spec orelse atom.EnvBits.col_c;
                break :blk switch (mode) {
                    atom.EnvBits.col_l => 0,
                    atom.EnvBits.col_r => col_w.items[c] - cl.w,
                    else => (col_w.items[c] - cl.w) / 2,
                };
            };
            try row_children.append(list.gpa, .{ .idx = cl.box, .x_shift = col_origin.items[c] + off, .shift = 0 });
        }
        // array colspec `|` rules: a rule BEFORE column c (nibble 3 at
        // position c) sits at the boundary between column c−1 and c — the
        // column-box boundary at Σ_{j<c}(2·acs + W_j) (acs for the
        // leading edge); a leading rule (position 0) sits at the array's
        // left edge. Every row carries its own rule (TeX's template), so
        // the overlapping rules read as one continuous line spanning the
        // array.
        if (kind == .array) {
            for (0..ncols) |c| {
                const spec = atom.envColSpec(n.data, c) orelse continue;
                if (spec != atom.EnvBits.col_rule) continue;
                const bx: f32 = if (c == 0) 0 else x_origin: {
                    var bx_: f32 = 0;
                    for (0..c) |j| bx_ += 2 * acs + col_w.items[j];
                    break :x_origin bx_ + acs;
                };
                const rule = try list.createLeaf(.rule, 0.4, row_h.items[r], row_d.items[r], span);
                try row_children.append(list.gpa, .{ .idx = rule, .x_shift = bx - 0.2, .shift = 0 });
            }
        }
        const row_box = try list.create(
            .hbox,
            arr_w,
            row_h.items[r],
            row_d.items[r],
            row_children.items,
            0,
            cstyle,
            0,
            span,
        );
        try array_children.append(list.gpa, .{ .idx = row_box, .x_shift = 0, .shift = row_shift.items[r] + shift_s });
        list.scratch.items.len = row_saved;
    }
    const arr_box = try list.create(.vbox, arr_w, arr_h, arr_d, array_children.items, 0, cstyle, 0, span);

    // 6. The env box: [open, array, close] with the delimiters sized by
    // the variant ladder from the array's extent (like \left..\right) and
    // axis-centered; the array sits flush between them (the amsmath
    // -\arraycolsep pads cancel the array's edge pads, measured 0pt).
    const delta = @max(arr_h - axis, arr_d + axis);
    const minh_pt = @max(2 * delta * 0.901, 2 * delta - 0.1 * size_pt);
    const req_em = minh_pt / size_pt;
    const h_saved = list.scratch.items.len;
    defer list.scratch.items.len = h_saved;
    var bx: f32 = 0;
    var height: f32 = arr_h;
    var depth: f32 = arr_d;
    if (open_idx) |o| {
        const ob = try layoutDelimChar(list, ast, o, fm, req_em, size_pt, cstyle);
        const b = list.get(ob);
        const sh = (b.height - b.depth) / 2 - axis;
        try list.scratch.append(list.gpa, .{ .idx = ob, .x_shift = bx, .shift = sh });
        bx += b.width;
        height = @max(height, b.height - sh);
        depth = @max(depth, b.depth + sh);
    }
    try list.scratch.append(list.gpa, .{ .idx = arr_box, .x_shift = bx, .shift = 0 });
    bx += arr_w;
    if (close_idx) |c| {
        const cb = try layoutDelimChar(list, ast, c, fm, req_em, size_pt, cstyle);
        const b = list.get(cb);
        const sh = (b.height - b.depth) / 2 - axis;
        try list.scratch.append(list.gpa, .{ .idx = cb, .x_shift = bx, .shift = sh });
        bx += b.width;
        height = @max(height, b.height - sh);
        depth = @max(depth, b.depth + sh);
    }
    return list.create(.hbox, bx, height, depth, list.scratch.items[h_saved..], 0, cstyle, 0, span);
}

/// \left <delim> ... \right <delim> (atom `.left`, children [open?, inner,
/// close?]): lays out the inner row, then sizes the two delimiter glyphs
/// from their MATH-table size-VARIANT ladder (parenleft.v1..v7 etc.) so the
/// chosen variant's INK covers the inner's extent, and centers the variant
/// on the math axis — TeX make_delim, verified against XeTeX+unicode-math:
/// `\left( \frac{\partial L}{\partial \dot{q}} \right)` renders parens AT
/// THE BASE FONT SIZE using the variant glyphs (the ref draws parenleft.v6
/// — ink span 2.392em — at 39.85pt ≈ base size), with the content centered
/// between the variant boxes (measured: the fraction ink center sits 1.4pt
/// off the visible paren-gap center at 40pt, vs 20.6pt when the parens were
/// scaled to 101.3pt).
///   · required delimiter ink height (TeX make_delim — tex.web §1114,
///     MicroTeX FencedAtom): with δ = max(h − a, d + a),
///     ink ≥ max(2·δ·901/1000, 2·δ − shortfall), shortfall = 0.1em;
///   · pick the SMALLEST variant whose ink (asc + desc) covers it (the
///     LARGEST when none does — TeX's "exceed if it can't match"); the
///     ladder's base entry covers a plain \left(x\right), byte-identical
///     to the un-stretched render;
///   · the delimiter BOX is the variant's hmtx advance × size and the
///     variant's ink asc/desc × size, at the BASE font size — no font-size
///     scaling (scaling the base glyph thickens its stroke linearly; the
///     variants keep a constant stroke at any size). The SVG emits the
///     base delimiter char at the base font-size; the rasterizer resolves
///     the variant from the MATH table (FixParenVariants);
///   · delimiters without a variant ladder (e.g. \left\backslash) fall back
///     to the old continuous scaled-base path (layoutScaledChar); | \| /
///     now have ladders (divides/parallel/slash), so they pick real
///     variants too;
///   · \big \Big \bigg \Bigg (a `.left` node with a SINGLE delimiter child,
///     data = level 1..4) box the delimiter by the FIXED ladder entry
///     (layoutDelimLevel); \middle leaves inside the inner get rewritten
///     with the fence's size (sizeMiddleDelims).
fn layoutLeftRight(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    const gl = fm.glue(fm);
    const axis = s(gl.axis_height, size_pt);

    // Children: [open?, inner, close?] — the delimiter leaves are `.char`,
    // the inner is the row parsed between \left and \right. `\left.` /
    // `\right.` (null delimiters) contribute no char. A \big/\Big/\bigg/
    // \Bigg node (data = level 1..4) has ONLY a single delimiter child and
    // no inner — a fixed ladder variant, not a stretched fence.
    var open_idx: ?u32 = null;
    var inner_idx: ?u32 = null;
    var close_idx: ?u32 = null;
    for (0..n.num_children) |i| {
        const c = ast.child(idx, i);
        if (ast.node(c).tag == .char) {
            if (inner_idx == null) open_idx = c else close_idx = c;
        } else inner_idx = c;
    }
    // Fixed-size delimiters: the \big family at its ladder level, centered
    // on the math axis (the reference draws \big( at parenleft.v1 with the
    // variant ink center ON the axis — measured 36pt above=0.297em /
    // below=0.797em of the baseline, exactly the v1 ink extents).
    if (inner_idx == null) {
        const level = n.data; // 1..4 (\big \Big \bigg \Bigg)
        const saved_len = list.scratch.items.len;
        defer list.scratch.items.len = saved_len;
        var x: f32 = 0;
        var height: f32 = 0;
        var depth: f32 = 0;
        if (open_idx) |o| {
            const ob = try layoutDelimLevel(list, ast, o, fm, level, size_pt, cstyle);
            const b = list.get(ob);
            const shift = (b.height - b.depth) / 2 - axis;
            try list.scratch.append(list.gpa, .{ .idx = ob, .x_shift = 0, .shift = shift });
            x += b.width;
            height = @max(height, b.height - shift);
            depth = @max(depth, b.depth + shift);
        }
        return list.create(.hbox, x, height, depth, list.scratch.items[saved_len..], 0, cstyle, 0, span);
    }

    const inner = try layoutInner(list, ast, inner_idx.?, fm, style, size_pt, cstyle, cramped);
    const ib = list.get(inner);

    // Required delimiter ink height (TeX make_delim — tex.web §1114 as
    // transcribed by MicroTeX FencedAtom): with δ = max(h − a, d + a) the
    // delimiter ink must be ≥ max(2·δ·901/1000, 2·δ − shortfall), shortfall
    // = 0.1em (TeX \delimitershortfall). Verified against the XeTeX ref of
    // `\left( \frac{\partial L}{\partial \dot{q}} \right)` at 40pt: this
    // floor is 87.0pt → parenleft.v6 (2.392em ink) — the exact variant the
    // reference draws (measured ink span 2.392em at its drawn size).
    const delta = @max(ib.height - axis, ib.depth + axis);
    const minh_pt = @max(2 * delta * 0.901, 2 * delta - 0.1 * size_pt);
    const req_em = minh_pt / size_pt;

    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    var x: f32 = 0;
    var height: f32 = ib.height;
    var depth: f32 = ib.depth;
    // The FENCE delimiter boxes (chosen by req_em above), used to size any
    // \middle delimiters: TeXBook p.291 — "\middle gives a delimiter that is
    // as tall as the delimiters that \left and \right produce", so the
    // middle req comes from the FENCE's own box, NOT the content (measured
    // XeTeX `\left\{ x \middle| \frac{x}{2} \in S \right\}` at 36pt: the {
    // resolves braceleft.v4 (box 41.40/23.40) and the \middle| resolves
    // divides.v3 (ink 1.734em) — δ = max(41.40−9, 23.40+9) = 32.40 → req
    // 1.70em → v3; the content-derived req 1.772em would wrongly pick v4).
    var fence_asc: f32 = 0;
    var fence_desc: f32 = 0;
    // Each delimiter is centered on the math axis (baseline shift
    // (h−d)/2 − axis, the same axis formula as big-op glyphs; for the LM
    // variants asc−desc = 0.5em, so the shift is 0.25·size − axis = 0 — the
    // variant ink center sits ON the axis like the reference).
    if (open_idx) |o| {
        const ob = try layoutDelimChar(list, ast, o, fm, req_em, size_pt, cstyle);
        const b = list.get(ob);
        fence_asc = b.height;
        fence_desc = b.depth;
        const shift = (b.height - b.depth) / 2 - axis;
        try list.scratch.append(list.gpa, .{ .idx = ob, .x_shift = x, .shift = shift });
        x += b.width;
        height = @max(height, b.height - shift);
        depth = @max(depth, b.depth + shift);
    }
    // \middle delimiters inside the inner: rewrite their zero-width
    // placeholder boxes in place with a req derived from the FENCE box (or
    // the content req when the pair has no delimiters — \left. ... \right.),
    // applied to the delimiter's OWN ladder. The returned extents bound the
    // hbox so the frame covers the middle's ink too.
    var mid_req_em = req_em;
    if (fence_asc > 0) {
        const fdelta = @max(fence_asc - axis, fence_desc + axis);
        mid_req_em = @max(2 * fdelta * 0.901, 2 * fdelta - 0.1 * size_pt) / size_pt;
    }
    const mid_ext = try sizeMiddleDelims(list, ast, inner, fm, mid_req_em, size_pt, cstyle);
    height = @max(height, mid_ext.asc_pt);
    depth = @max(depth, mid_ext.desc_pt);

    try list.scratch.append(list.gpa, .{ .idx = inner, .x_shift = x, .shift = 0 });
    x += ib.width;
    if (close_idx) |c| {
        const cb = try layoutDelimChar(list, ast, c, fm, req_em, size_pt, cstyle);
        const b = list.get(cb);
        const shift = (b.height - b.depth) / 2 - axis;
        try list.scratch.append(list.gpa, .{ .idx = cb, .x_shift = x, .shift = shift });
        x += b.width;
        height = @max(height, b.height - shift);
        depth = @max(depth, b.depth + shift);
    }
    return list.create(.hbox, x, height, depth, list.scratch.items[saved_len..], 0, cstyle, 0, span);
}

/// A \left/\right delimiter char box: the SMALLEST MATH size-variant whose
/// ink (asc + desc) covers the required height `req_em` (the largest when
/// none does), boxed at the BASE font size by the variant's hmtx advance and
/// ink extents — no font-size scaling. The drawn glyph stays the base
/// delimiter char at the base size (the rasterizer resolves the variant from
/// the MATH table). Codepoints without a variant ladder (e.g. \left|) fall
/// back to the continuous scaled-base path (layoutScaledChar) with the same
/// extent floors as the old layoutLeftRight.
fn layoutDelimChar(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    req_em: f32,
    size_pt: f32,
    cstyle: atom.CharStyle,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    const cp = delimiterCp(ast, idx);
    if (metrics.delimVariants(cp)) |ladder| {
        if (ladder.len > 0) {
            var best = ladder[ladder.len - 1];
            for (ladder) |v| {
                if (v.asc + v.desc >= req_em) {
                    best = v;
                    break;
                }
            }
            const box_idx = try list.create(
                .char,
                best.adv * size_pt,
                best.asc * size_pt,
                best.desc * size_pt,
                &.{},
                cp,
                cstyle,
                size_pt,
                span,
            );
            if (n.data != 0) list.boxes.items[box_idx].synthetic = true;
            return box_idx;
        }
        // Unreachable: variant ladders are fixed-size arrays (never empty).
        return error.InvalidTable;
    }
    // No variant ladder: continuous scaled base glyph (previous behavior;
    // req_em × size / (2·half) = the old max(total_need/(2·half),
    // (h−axis)/half, (d+axis)/half) floor).
    const ink = metrics.glyphInk(cp);
    const half = (ink.asc + ink.desc) / 2;
    const del_size = @max(size_pt, req_em * size_pt / (2 * half));
    return layoutScaledChar(list, ast, idx, fm, del_size, cstyle);
}

/// The codepoint a delimiter char leaf renders (node data override or the
/// source byte), like layoutChar.
fn delimiterCp(ast: *const atom.Ast, idx: u32) u21 {
    const n = ast.node(idx);
    if (n.data != 0) return @truncate(n.data);
    const sp = ast.span(idx);
    return firstCodepoint(ast.src[sp.start..sp.end]);
}

/// layoutChar's char-box construction at an explicit drawn size — the
/// \left/\right delimiters are the normal LM Math glyphs drawn larger (the
/// font's parens scale linearly; no composite extension parts are needed).
fn layoutScaledChar(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    glyph_size: f32,
    cstyle: atom.CharStyle,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    const cp: u21 = if (n.data != 0) @truncate(n.data) else firstCodepoint(ast.src[span.start..span.end]);
    const g = metrics.glyphAt(fm, cp, cstyle, glyph_size) orelse
        fm.glyphEstimate(fm, cp, cstyle);
    const ink = metrics.glyphInk(cp);
    const box_idx = try list.create(
        .char,
        s(g.width, glyph_size),
        ink.asc * glyph_size,
        ink.desc * glyph_size,
        &.{},
        cp,
        cstyle,
        glyph_size,
        span,
    );
    if (n.data != 0) list.boxes.items[box_idx].synthetic = true;
    return box_idx;
}

/// A \big/\Big/\bigg/\Bigg delimiter box: the FIXED ladder entry
/// `big_ladder_idx[level]` boxed at the base font size by its hmtx advance
/// and ink extents — the same box layoutDelimChar produces for a stretched
/// \left..\right delimiter, but at a fixed level instead of a required
/// height (measured XeTeX+unicode-math picks the SAME variant at 10/14/24/
/// 36pt because amsmath's \bBigg@ vcenter height scales with the size).
/// Codepoints without a variant ladder fall back to the continuous
/// scaled-base path sized so the glyph's ink reaches the level's target
/// (big_target_ink[level]).
fn layoutDelimLevel(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    level: u32,
    size_pt: f32,
    cstyle: atom.CharStyle,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    const cp = delimiterCp(ast, idx);
    if (metrics.delimVariants(cp)) |ladder| {
        const best = ladder[big_ladder_idx[level]];
        const box_idx = try list.create(
            .char,
            best.adv * size_pt,
            best.asc * size_pt,
            best.desc * size_pt,
            &.{},
            cp,
            cstyle,
            size_pt,
            span,
        );
        if (n.data != 0) list.boxes.items[box_idx].synthetic = true;
        return box_idx;
    }
    // No variant ladder: scaled base glyph whose ink reaches the level's
    // target height (like layoutDelimChar's no-ladder fallback).
    const ink = metrics.glyphInk(cp);
    const half = (ink.asc + ink.desc) / 2;
    const gs = @max(size_pt, big_target_ink[level] * size_pt / (2 * half));
    return layoutScaledChar(list, ast, idx, fm, gs, cstyle);
}

/// Rewrite every \middle placeholder box inside `idx`'s subtree in place:
/// the zero-width box becomes the delimiter's SMALLEST MATH variant whose
/// ink covers the fence's required height `req_em` (the largest when none
/// does), boxed at the base font size — the exact rule layoutDelimChar
/// applies to the fence delimiters, but to the \middle delimiter's OWN
/// ladder (XeTeX `\left\{ x \middle| \frac{x}{2} \in S \right\}` at 36pt:
/// braceleft.v4 for the fence, divides.v3 for the |). Delimiters without a
/// ladder fall back to the continuous scaled-base path. Returns the largest
/// ink extents among the sized middles (the fence hbox bounds them; the
/// inner row box keeps its pre-middle dims — only the frame matters).
fn sizeMiddleDelims(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    req_em: f32,
    size_pt: f32,
    cstyle: atom.CharStyle,
) !struct { asc_pt: f32, desc_pt: f32 } {
    const b = &list.boxes.items[idx];
    if (b.kind == .char) {
        // A \middle placeholder: zero-width AND zero-height, delimiter cp.
        if (b.width == 0 and b.height == 0 and b.depth == 0 and b.cp != 0) {
            if (metrics.delimVariants(b.cp)) |ladder| {
                if (ladder.len > 0) {
                    var best = ladder[ladder.len - 1];
                    for (ladder) |v| {
                        if (v.asc + v.desc >= req_em) {
                            best = v;
                            break;
                        }
                    }
                    b.width = best.adv * size_pt;
                    b.height = best.asc * size_pt;
                    b.depth = best.desc * size_pt;
                    b.size = size_pt;
                }
            } else {
                // No ladder: continuous scaled base (layoutDelimChar's
                // no-ladder fallback, with the same extent floor).
                const ink = metrics.glyphInk(b.cp);
                const half = (ink.asc + ink.desc) / 2;
                const gs = @max(size_pt, req_em * size_pt / (2 * half));
                const g = metrics.glyphAt(fm, b.cp, b.style, gs) orelse
                    fm.glyphEstimate(fm, b.cp, b.style);
                b.width = s(g.width, gs);
                b.height = ink.asc * gs;
                b.depth = ink.desc * gs;
                b.size = gs;
            }
            return .{ .asc_pt = b.height, .desc_pt = b.depth };
        }
        return .{ .asc_pt = 0, .desc_pt = 0 };
    }
    var asc: f32 = 0;
    var desc: f32 = 0;
    for (list.children(idx)) |cr| {
        const r = try sizeMiddleDelims(list, ast, cr.idx, fm, req_em, size_pt, cstyle);
        asc = @max(asc, r.asc_pt);
        desc = @max(desc, r.desc_pt);
    }
    return .{ .asc_pt = asc, .desc_pt = desc };
}

/// \sqrt (a row marked `sqrt_row_data`; children [surd, radicand]): the TeX
/// radical construction — a stretchy U+221A glyph whose ink covers the
/// radicand's extent, plus the vinculum rule (the overbar) spanning the
/// radicand's width at the top. Matches XeTeX+unicode-math+LM Math
/// (make_radical reading the MATH-table gaps) and KaTeX:
///   · radicand set in cramped style (same size);
///   · clearance clr = RadicalDisplayStyleVerticalGap 0.148em in
///     display/text, RadicalVerticalGap 0.05em in script/scriptscript (the
///     classic rule-11 values θ + x_height/4 and 5θ/4 give the same numbers
///     for LM: 0.04 + 0.108 = 0.148, 1.25 × 0.04 = 0.05);
///   · vinculum: a rule of thickness θ = rule_thickness at height H + clr,
///     spanning exactly the radicand's width (measured XeTeX `\sqrt{x^2+1}`:
///     the rule runs from the radicand's left edge to its right edge);
///   · the radical glyph is the LM base U+221A (ink 0.040/0.960 em) drawn at
///     a scaled font-size gs ≥ size, anchored so its ink TOP (the hook tip,
///     0.04·gs above its own baseline) sits at the vinculum's top
///     (H + clr + θ) — the bar then descends gs − (H + clr + θ) below the
///     baseline, covering the radicand's depth (XeTeX's assembled radical
///     covers the same span; for shallow radicands gs clamps to the text
///     size and the bar overhangs below the baseline like the reference).
///   · \sqrt[n]{x}: the degree is set at 0.5×size (measured XeTeX: the root
///     index '3' draws at 4.98pt at 10pt), its bottom raised to
///     rule_top − 0.4·gs (RadicalDegreeBottomRaisePercent = 60 of the
///     radical's ink height), its left edge 0.278em (RadicalKernBeforeDegree
///     of the degree size) right of the radical bar.
fn layoutSqrt(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
) !u32 {
    const span = ast.span(idx);
    const gl = fm.glue(fm);
    const rt = s(gl.rule_thickness, size_pt);
    const clr: f32 = if (style == .display or style == .text) 0.148 * size_pt else 0.05 * size_pt;

    // children: [surd, radicand]; a degree wraps the surd in a script node
    // (parser: \sqrt[n]{x} → script[surd, degree] with the SUP bit).
    const surd_child = ast.child(idx, 0);
    const radicand_child = ast.child(idx, 1);
    var surd_leaf = surd_child;
    var degree: ?u32 = null;
    if (ast.node(surd_child).tag == .script) {
        surd_leaf = ast.child(surd_child, 0);
        degree = ast.child(surd_child, 1);
    }

    const radicand = try layoutInner(list, ast, radicand_child, fm, style, size_pt, cstyle, true);
    const rb = list.get(radicand);
    const H = rb.height;
    const D = rb.depth;

    // Drawn size of the radical glyph: its 1.0em ink must cover the
    // radicand's full extent plus clearance and rule, never smaller than the
    // current text size (XeTeX draws shallow radicands with a text-size
    // radical whose bar overhangs below the baseline).
    const gs = @max(H + D + clr + rt, size_pt);
    // TeX make_radical's clearance adjustment: when the radical glyph's ink
    // depth exceeds the radicand's extent below the rule, half the excess is
    // added to the clearance, raising the vinculum. Measured XeTeX
    // `\sqrt{x}` at 10pt: the rule bottom sits 0.327em above the radicand
    // (not the nominal 0.148em gap) — exactly this adjustment (0.96·gs =
    // 9.56pt depth vs a 5.99pt need → clr 1.474 + 3.57/2 = 3.26 → rule
    // bottom at 7.66pt, matching XeTeX to 0.005pt).
    const delta = @max(0.0, 0.96 * gs - (H + D + clr));
    const clr2 = clr + delta / 2;
    const rule_top = H + clr2 + rt;
    const surd = try layoutScaledChar(list, ast, surd_leaf, fm, gs, cstyle);
    const sb = list.get(surd);
    // Anchor: the glyph's ink top (0.04·gs above its baseline) at the
    // vinculum's top; shift is the glyph baseline's height above the row
    // baseline (positive shift = down, so up is negative).
    const glyph_baseline = rule_top - 0.04 * gs;
    const shift = -glyph_baseline;

    const radicand_x = sb.width; // the glyph advance; the radicand starts here
    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    try list.scratch.append(list.gpa, .{ .idx = surd, .x_shift = 0, .shift = shift });
    try list.scratch.append(list.gpa, .{ .idx = radicand, .x_shift = radicand_x, .shift = 0 });
    // Vinculum: a rule of thickness rt centered at H + clr2 + rt/2, spanning
    // exactly the radicand's width (measured XeTeX: the rule runs from the
    // radicand's left edge to its right edge; the hook connects it to the bar).
    const rule = try list.createLeaf(.rule, rb.width, rt / 2, rt / 2, span);
    try list.scratch.append(list.gpa, .{ .idx = rule, .x_shift = radicand_x, .shift = -(H + clr2 + rt / 2) });
    var height = rule_top;
    var width = radicand_x + rb.width;
    if (degree) |d| {
        // Root index at 0.5×size (XeTeX measured), bottom raised to
        // rule_top − 0.4·gs, left edge 0.278·deg_size right of the bar.
        const deg_size = 0.5 * size_pt;
        const db = try layoutInner(list, ast, d, fm, .script_script, deg_size, cstyle, true);
        const gb = list.get(db);
        const deg_x = 0.073 * gs + 0.278 * deg_size;
        const bottom = rule_top - 0.4 * gs;
        try list.scratch.append(list.gpa, .{ .idx = db, .x_shift = deg_x, .shift = -(bottom + gb.depth) });
        height = @max(height, bottom + gb.height + gb.depth);
        width = @max(width, deg_x + gb.width);
    }
    return list.create(
        .hbox,
        width,
        height,
        @max(D, gs - rule_top),
        list.scratch.items[saved_len..],
        0,
        cstyle,
        0,
        span,
    );
}

/// Italic-correction advance appended after a big-op atom (see layoutRow).
/// TeX appends the op's italic correction as a kern when the op has no
/// subscript (tex.web mlist_to_hlist: "if math_type(subscr)=empty and
/// delta≠0 then append new_kern(delta)"). With XeTeX+unicode-math the
/// measured post-op advances at 10pt are:
///   display \int x:   x at 11.606pt = 0.665em box + 0.334em + thin
///                     (the display .v1 variant advance 0.999em MINUS the
///                     base advance — measured bare \displaystyle\int x);
///   display \sum x:   x at 16.040pt = 1.444em box + thin (no tail);
///   text \int x:      x at 8.285pt = 0.665em box + thin (no tail).
/// So only a bare DISPLAY nolimits op (∫/∮) carries the variant-advance
/// tail; everything else — including every scripted op (the script box
/// already attaches at the variant advance) — has none. The old
/// base-ic tail (3.32pt for every ∫) over-counted text and under-counted
/// display by the variant-vs-base advance difference.
fn opTailIc(
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
) f32 {
    _ = fm;
    const n = ast.node(idx);
    if (n.tag == .op) {
        if (style != .display) return 0;
        // \limits on a bare display op: the limits vbox takes over, so no
        // beside italic tail (TeX appends delta only when the op is NOT
        // limits). \displaylimits/\nolimits keep the default/beside tail.
        if ((n.data & atom.LimitsBits.mask) == atom.LimitsBits.force) return 0;
        const op: atom.BigOp = @fromBackingInt(@intCast(n.data & atom.LimitsBits.value_mask));
        if (bigOpLimits(op)) return 0;
        const base_adv = bigOpInk(op, false).advance;
        const disp_adv = bigOpInk(op, true).disp_advance;
        return s((disp_adv - base_adv) * 10.0, size_pt);
    }
    return 0;
}

fn layoutScript(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    const has_sup = (n.data & atom.ScriptBits.sup) != 0;
    const has_sub = (n.data & atom.ScriptBits.sub) != 0;
    // children are [base, sup?, sub?]; sub-only → sub is child 1
    const base_idx = ast.child(idx, 0);
    const sup_idx = if (has_sup) ast.child(idx, 1) else null;
    const sub_idx = if (has_sub) (if (has_sup) ast.child(idx, 2) else ast.child(idx, 1)) else null;
    const base_u = unwrapAtom(ast, base_idx);
    const base_u_atom = ast.node(base_u);
    const is_op_base = base_u_atom.tag == .op;

    // Limits decision. \limits / \nolimits / \displaylimits set override
    // bits on the op/opname node's data (atom.LimitsBits); they win over
    // the per-op default:
    //   \limits        → over/under in display AND text styles (TeX applies
    //                    \limits in both), e.g. \int\limits_0^1 x;
    //   \nolimits      → beside scripts in every style, e.g.
    //                    \sum\nolimits_{i=1}^{n} x_i;
    //   \displaylimits → the op's default (big-op family → limits in
    //                    display style; int family → beside; operator words
    //                    → limits only for the limit-taking set).
    // Otherwise: big operators and limit-taking operator words (\lim \max
    // \min ...; parser tags them with a nonzero opname data) take
    // over/under limits in display style only — \lim_{x \to 0} puts "x→0"
    // under the word, centered, the TeX \mathop-with-limits behavior
    // (XeTeX: the under-limit row sits max(bigop2, bigop4 − sub.height)
    // below the word, centered on it). \int/\oint default to \intop\nolimits
    // (fontmath.ltx): beside scripts in every style.
    const op_bits = base_u_atom.data & atom.LimitsBits.mask;
    const forced_limits = op_bits == atom.LimitsBits.force;
    const forced_beside = op_bits == atom.LimitsBits.force_beside;
    const default_limits = if (base_u_atom.tag == .op)
        bigOpLimits(@fromBackingInt(@intCast(base_u_atom.data & atom.LimitsBits.value_mask)))
    else if (base_u_atom.tag == .opname)
        (base_u_atom.data & atom.LimitsBits.value_mask) != 0
    else
        false;
    if (!forced_beside and (forced_limits or (style == .display and default_limits))) {
        const base = try layoutInner(list, ast, base_idx, fm, style, size_pt, cstyle, cramped);
        return layoutOpLimits(list, ast, base, sup_idx, sub_idx, fm, size_pt, span, cramped);
    }

    const base = try layoutInner(list, ast, base_idx, fm, style, size_pt, cstyle, cramped);
    const bb = list.get(base);
    const gl = fm.glue(fm);

    // Scripts are set one style level down (tex.web sup_style/sub_style).
    // The SIZES are root-relative, not multiplicative: 10pt → 7pt → 5pt
    // (XeTeX \showbox: the 2 in x_{y^2} and the 3 in x_{y_{2_3}} are both
    // cmr/m/n/5 — a script of a scriptscript stays scriptscript). So the
    // size step depends on the CURRENT level: display/text → size×0.7,
    // script → size×(0.5/0.7), scriptscript → size×1.0. The old
    // size×factor formula double-applied the factor (7×0.5 = 3.5pt).
    const s_style: Style = if (style == .display or style == .text) .script else .script_script;
    const s_size = switch (style) {
        .display, .text => size_pt * gl.scriptfactor,
        .script => size_pt * (gl.scriptscriptfactor / gl.scriptfactor),
        .script_script => size_pt,
    };
    const x_height = s(gl.x_height, size_pt);
    const rt = s(gl.rule_thickness, size_pt);
    // Script horizontal placement (TeX make_scripts, tex.web): the
    // superscript starts at the base's right edge plus the base's italic
    // correction, the subscript at the base's right edge — no leading
    // SCRIPT_SPACE (measured: x^2 / x_2 scripts sit at exactly w_base,
    // ztex's 0.5pt gap put them 0.52pt too far right). TeX's scriptspace
    // (0.5pt) instead pads AFTER the script box, so the box width includes
    // it (measured x^2 → '+' advance).
    var sup_ic: f32 = 0;
    var sub_ic: f32 = 0;
    if (bb.kind == .char) {
        if (is_op_base) {
            // A big operator's beside scripts attach at the op's ADVANCE,
            // with the SUBSCRIPT pulled back by the italic correction
            // (measured with XeTeX+unicode-math at 10pt):
            //   text \int_0^1:   sup at 0.665em (base advance, NO ic),
            //                     sub at 0.665 − 0.332 = 0.333em
            //   display \int_0^1: sup at 0.999em (the .v1 display-variant
            //                     advance), sub at 0.999 − 0.591 = 0.408em
            //                     (the .v1 MathItalicsCorrection).
            // The text ∑ (ic 0) puts both scripts at the advance 1.056em.
            // The old "sup at box + ic" convention matched the display ∫
            // only because 0.665 + 0.332 ≈ 0.999.
            const op: atom.BigOp = @fromBackingInt(@intCast(base_u_atom.data & atom.LimitsBits.value_mask));
            const ink = bigOpInk(op, style == .display);
            if (style == .display and !bigOpLimits(op)) {
                const base_adv = bigOpInk(op, false).advance;
                // display-variant advance − base advance (0.334em for ∫)
                const attach = (ink.disp_advance - base_adv) * 10.0;
                sup_ic = s(attach, size_pt);
                // variant advance − variant italic − base advance
                sub_ic = s(attach - ink.ic, size_pt);
            } else {
                sub_ic = -s(ink.ic, size_pt);
            }
        } else {
            // Ordinary char bases: the italic correction scales with the
            // current size like the letter font itself. XeTeX's OT math
            // folds a per-letter slant into the char box (measured x box
            // 0.572em at 10pt vs the 0.528em hmtx advance — the box carries
            // the italic); the superscript lands at the box edge plus this
            // correction (measured x^2 sup at 5.719pt = box 5.28 + 0.44).
            // Our box keeps the raw advance, so the sup gap approximates
            // the slant with the table italic correction.
            const g = metrics.glyphAt(fm, bb.cp, bb.style, size_pt) orelse
                fm.glyphEstimate(fm, bb.cp, bb.style);
            sup_ic = s(g.italic_correction, size_pt);
        }
    }
    const sup_gap = sup_ic;
    const sub_gap = sub_ic;
    const script_space = 0.5; // TeX \scriptspace: fixed 0.5pt, not em-scaled

    // A scripted big operator with BESIDE scripts is axis-centered at EVERY
    // style: make_op sets the op box's shift_amount to (h−d)/2 − axis for
    // any op (display \intop\nolimits keeps it, text and script ops too).
    // The script raises/drops below are computed from the SHIFTED
    // dimensions (height − shift, depth + shift) — exactly what tex.web
    // make_scripts sees after hpack absorbs the box's shift_amount. The box
    // h/d are the drawn glyph's ink (bigOpInk × size_pt), so at 10pt a
    // display ∫ (gs 10) gives base_h 8.05 / base_d 3.06 and the shift
    // (8.05−3.06)/2 − 2.5 ≈ 0 — the ink center sits on the math axis at
    // every style, the XeTeX-LMMath \showbox numbers.
    const axis = s(gl.axis_height, size_pt);
    const base_shift = if (is_op_base) (bb.height - bb.depth) / 2 - axis else 0;
    const base_h = bb.height - base_shift; // shifted top above the row baseline
    const base_d = bb.depth + base_shift; // shifted bottom below the row baseline

    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    try list.scratch.append(list.gpa, .{ .idx = base, .x_shift = 0, .shift = base_shift });
    var width = bb.width;
    var height = base_h;
    var depth = base_d;

    // TeX make_scripts: a CHAR nucleus (incl. ligatures, \mathbf) starts
    // shift_up/shift_down at 0 — only the sup1|sup2|sup3 / sub1|sub2 and
    // x-height floors apply (verified: b^2 sup = sup2 3.62892, NOT
    // 6.94445 − sup_drop). A BOX nucleus (op, fraction, braced list,
    // \left..\right) starts from height − sup_drop / depth + sub_drop with
    // the SCRIPT-SIZE symbol font's parameters: cmsy7's sup_drop is
    // 2.4722pt (tftopl SUPDROP 0.353171 em × 7) and cmsy5's is 2.47223 —
    // NOT the 10pt 3.86108 (audit-scripts residual #3; the audit's
    // "2.88889" is cmsy10's SUP3, not sup_drop).
    const base_is_char = base_u_atom.tag == .char;
    // sup_drop/sub_drop for a BOX base (op, fraction, braced list,
    // \left..\right): TeX reads \fontdimen20/21 of family 2; XeTeX+LM uses
    // the MATH-table baseline-drop constants at the SCRIPT size — measured
    // \int_0^1 sup raise 11.860 = base_h 13.611 − 1.75 and sub drop 10.008 =
    // base_d 8.611 + 1.40 at 10pt (display ∫ drawn with the .v1 display
    // variant: asc 1.361em, desc 0.861em), and the text-style ∫/∑ probes
    // confirm the same drops (6.301 = 8.051 − 1.75, 5.749 = 7.501 − 1.75).
    // SuperscriptBaselineDropMax 0.25em / SubscriptBaselineDropMin 0.20em,
    // evaluated at the script size (× 0.7), so the 10pt-base values are
    // 1.75/1.40 and they scale with size_pt like the other em-relative
    // parameters. The old constants 2.4722/0.5 (cmsy7 supdrop/subdrop)
    // left the ∫ scripts ~1.2pt too tight at 10pt.
    const supdrop = s(1.75, size_pt);
    const subdrop = s(1.4, size_pt);
    const sym = symFor(style);

    // Superscript raise: max(shift_up0, sup1|sup2|sup3, sup.depth +
    // x_height/4) with the floor from the CURRENT style's symbol font
    // (sup3 in cramped styles — fraction denominators, subscripts).
    var sup: ?u32 = null;
    var sup_depth: f32 = 0;
    var sup_op_shift: f32 = 0;
    var shift_up: f32 = 0;
    if (sup_idx != null) {
        // sup_style: cramped iff the current style is cramped.
        const sc = try layoutInner(list, ast, sup_idx.?, fm, s_style, s_size, cstyle, cramped);
        const sb = list.get(sc);
        sup = sc;
        // A bare op as the script content carries its own axis shift (make_op,
        // axis at the script size); fold it in so the glyph hangs off the
        // shifted box and the floors measure the shifted dimensions.
        if (ast.node(unwrapAtom(ast, sup_idx.?)).tag == .op) {
            sup_op_shift = (sb.height - sb.depth) / 2 - s(gl.axis_height, s_size);
        }
        sup_depth = sb.depth + sup_op_shift;
        // Superscript floor: KaTeX's sup1 (0.413em) for OPERATOR WORDS —
        // the measured \sin^2/\cos^2 placement; sup1|sup2|sup3 from the
        // current style's symbol font otherwise (sup3 in cramped styles).
        const is_opname_base = base_u_atom.tag == .opname;
        const sup_floor: f32 = if (is_opname_base)
            s(4.13, size_pt) // KaTeX fontMetrics sup1 (display floor)
        else if (cramped) s(sym.sup3, size_pt) else if (style == .display)
            s(sym.sup1, size_pt)
        else
            s(sym.sup2, size_pt);
        // Raise above the base: TeX's height − sup_drop for a BOX base, but
        // OPERATOR WORDS use KaTeX's rule — word_height − (supDrop at the
        // script size: 0.353em × 0.7 = 0.2471em) — which lands on the
        // 0.413em floor for x-height words, so \sin^2 and \cos^2 raise the
        // '2' to nearly the same height. TeX's height − sup_drop let the
        // dot of the 'i' in \sin dominate (17.36pt at 36pt vs KaTeX 15.15)
        // while \cos^2 fell to the 13.07pt sup2 floor (KaTeX 14.87) — the
        // "different heights & offsets" defect. Measured at 36pt vs KaTeX:
        // sin^2 raise 14.87pt (Δ 0.28), cos^2 14.87pt (Δ 0.00).
        const sup_base: f32 = if (base_is_char) 0 else if (is_opname_base)
            base_h - s(2.471, size_pt)
        else
            base_h - supdrop;
        shift_up = @max(@max(sup_base, sup_floor), sup_depth + x_height / 4);
    }
    // Subscript drop: max(shift_down0, sub1|sub2, sub.height − 0.8·x_height
    // for sub-only). sub2 when both scripts are present; the sub content is
    // always cramped (sub_style = smaller + cramped).
    var sub: ?u32 = null;
    var sub_height: f32 = 0;
    var sub_op_shift: f32 = 0;
    var shift_down: f32 = 0;
    if (sub_idx != null) {
        const sc = try layoutInner(list, ast, sub_idx.?, fm, s_style, s_size, cstyle, true);
        const sb = list.get(sc);
        sub = sc;
        if (ast.node(unwrapAtom(ast, sub_idx.?)).tag == .op) {
            sub_op_shift = (sb.height - sb.depth) / 2 - s(gl.axis_height, s_size);
        }
        sub_height = sb.height - sub_op_shift;
        const sub_base: f32 = if (base_is_char) 0 else base_d + subdrop;
        if (sup_idx != null) {
            shift_down = @max(sub_base, s(sym.sub2, size_pt));
        } else {
            shift_down = @max(
                @max(sub_base, s(sym.sub1, size_pt)),
                sub_height - 0.8 * x_height,
            );
        }
    }
    // When both scripts are present, keep at least 4·rule-thickness between
    // the superscript bottom and the subscript top (XeTeX make_scripts).
    // TeX LOWERs the subscript to gain the clearance (not raising the
    // superscript), then — ONLY inside the guard — applies the 0.8·x-height
    // refinement (raise sup by psi, lower sub by psi). Verified on x_i^j:
    // shift_up 4.80555, shift_down 2.7875, final interspace = 4·rt.
    if (sup != null and sub != null) {
        const interspace = shift_up - sup_depth + shift_down - sub_height;
        if (interspace < 4 * rt) {
            shift_down += 4 * rt - interspace;
            const psi = 0.8 * x_height - (shift_up - sup_depth);
            if (psi > 0) {
                shift_up += psi;
                shift_down -= psi;
            }
        }
    }
    if (sup) |supb| {
        const sb = list.get(supb);
        try list.scratch.append(list.gpa, .{
            .idx = supb,
            .x_shift = bb.width + sup_gap,
            .shift = -(shift_up - sup_op_shift),
        });
        width = @max(width, bb.width + sup_gap + sb.width + script_space);
        height = @max(height, shift_up + (sb.height - sup_op_shift));
    }
    if (sub) |subb| {
        const sb = list.get(subb);
        try list.scratch.append(list.gpa, .{
            .idx = subb,
            .x_shift = bb.width + sub_gap,
            .shift = shift_down + sub_op_shift,
        });
        width = @max(width, bb.width + sub_gap + sb.width + script_space);
        depth = @max(depth, shift_down + (sb.depth + sub_op_shift));
    }
    return list.create(
        .script,
        width,
        height,
        depth,
        list.scratch.items[saved_len..],
        0,
        cstyle,
        0,
        span,
    );
}

/// A big operator with limits: a vbox with the operator centered on the
/// axis, the superscript above and the subscript below. Gaps follow the
/// TeX big-op parameters (MicroTeX BigOperatorAtom::createLimits):
/// under-gap k = max(bigop2, bigop4 − sub.height), over-gap kern =
/// max(bigop1, bigop3 − over.depth), bigop5 outer padding.
fn layoutOpLimits(
    list: *box.BoxList,
    ast: *const atom.Ast,
    base: u32,
    sup_idx: ?u32,
    sub_idx: ?u32,
    fm: *const metrics.FontMetrics,
    size_pt: f32,
    span: atom.Span,
    cramped: bool,
) !u32 {
    const bb = list.get(base);
    const gl = fm.glue(fm);
    // The big-op spacing params are the OpenType MATH-table constants of the
    // math font (UpperLimitGapMin 0.20em, LowerLimitGapMin 0.167em,
    // UpperLimitBaselineRiseMin 0.111em, LowerLimitBaselineDropMax 0.60em,
    // all ×10 for the 10pt base) — em-relative, so they scale LINEARLY with
    // size_pt (measured on `\sum_{i=1}^{n} x_i` in XeTeX+unicode-math: the
    // over-limit kern is 2.02pt at 10pt, 4.05pt at 20pt, 9.71pt at 48pt —
    // exactly bigop1 × size/10; the old cmex10 fontdimens were fixed at the
    // 10pt design size for every math size, but with Latin Modern Math the
    // limits gaps come from the MATH table and scale). The axis (family 2)
    // scales normally. The op's ITALIC correction is also em-relative
    // (XeTeX-LM: post-∫ kern 3.32pt at 10pt, 6.64pt at 20pt).

    // TeX skews the two limit rows horizontally (tex.web make_op limits
    // construction): the over-limit shifts right by half the operator's
    // italic correction, the under-limit left by the same amount. Measured
    // ∫ stagger 1.66pt = half the LM italic correction (0.332em × 10 / 2);
    // ∑ has no italic, so its limits stay centered (verified: ∑ limits are
    // centered on the display box to 0.05pt).
    const axis = s(gl.axis_height, size_pt);
    const bigop5 = gl.bigop_spacing5;
    const delta = if (metrics.displayOp(bb.cp)) |dop| s(dop.ic, size_pt) else 0;

    // A big-operator GLYPH is centered on the axis (MicroTeX
    // SymbolAtom::createBox big-op branch: y-down shift = (h−d)/2 − axis; the
    // ink box is built axis-centered, so the shift is small). An OPERATOR
    // WORD base (a row box, e.g. "lim") stays on the baseline: XeTeX
    // \showbox of `\lim_{x\to 0} x` places the "lim" row at shift 0 inside
    // the limits vbox — the word ink center sits ~(h−d)/2 above the baseline
    // while the under-limit hangs below, so the vbox shift clamps to 0.
    const op_shift = if (bb.kind == .char) (bb.height - bb.depth) / 2 - axis else 0;
    const op_top = op_shift - bb.height;
    const op_bottom = op_shift + bb.depth;

    const s_style: Style = .script;
    const s_size = size_pt * gl.scriptfactor;

    var sup_box: ?u32 = null;
    var sup_w: f32 = 0;
    var sup_h: f32 = 0;
    var sup_d: f32 = 0;
    if (sup_idx) |c| {
        // sup_style: cramped iff the base style is cramped.
        const b = try layoutInner(list, ast, c, fm, s_style, s_size, .italic, cramped);
        const gb = list.get(b);
        sup_box = b;
        sup_w = gb.width;
        sup_h = gb.height;
        sup_d = gb.depth;
    }
    var sub_box: ?u32 = null;
    var sub_w: f32 = 0;
    var sub_h: f32 = 0;
    var sub_d: f32 = 0;
    if (sub_idx) |c| {
        // sub_style is always cramped.
        const b = try layoutInner(list, ast, c, fm, s_style, s_size, .italic, true);
        const gb = list.get(b);
        sub_box = b;
        sub_w = gb.width;
        sub_h = gb.height;
        sub_d = gb.depth;
    }
    const vbox_w = @max(@max(bb.width, sup_w), sub_w);

    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    var height = -op_top;
    var depth = op_bottom;
    if (sup_box) |supb| {
        const kern = @max(s(gl.bigop_spacing1, size_pt), s(gl.bigop_spacing3, size_pt) - sup_d);
        try list.scratch.append(list.gpa, .{
            .idx = supb,
            .x_shift = (vbox_w - sup_w) / 2 + delta / 2,
            .shift = op_top - kern - sup_d,
        });
        height = -op_top + kern + sup_h + sup_d + bigop5;
    }
    try list.scratch.append(list.gpa, .{
        .idx = base,
        .x_shift = (vbox_w - bb.width) / 2,
        .shift = op_shift,
    });
    if (sub_box) |subb| {
        const k = @max(s(gl.bigop_spacing2, size_pt), s(gl.bigop_spacing4, size_pt) - sub_h);
        try list.scratch.append(list.gpa, .{
            .idx = subb,
            .x_shift = (vbox_w - sub_w) / 2 - delta / 2,
            .shift = op_bottom + k + sub_h,
        });
        depth = op_bottom + k + sub_h + sub_d + bigop5;
    }
    return list.create(.vbox, vbox_w, height, depth, list.scratch.items[saved_len..], 0, .italic, 0, span);
}

/// The Unicode codepoint rendered for a big operator.
fn bigOpCodepoint(op: atom.BigOp) u21 {
    return switch (op) {
        .sum => 0x2211, // ∑
        .int => 0x222B, // ∫
        .prod => 0x220F, // ∏
        .coprod => 0x2210, // ∐
        .bigcup => 0x22C3, // ⋃
        .bigcap => 0x22C2, // ⋂
        .bigsqcup => 0x2A06, // ⨆
        .oint => 0x222E, // ∮
    };
}

/// Whether a big operator takes display-style over/under limits. TeX's
/// fontmath.ltx defines the integral family as \intop\nolimits, so \int and
/// \oint keep their scripts beside as script-size sub/superscripts even in
/// display style; only \sum \prod \coprod \bigcup \bigcap \bigsqcup stack
/// limits over/under.
fn bigOpLimits(op: atom.BigOp) bool {
    return switch (op) {
        .sum, .prod, .coprod, .bigcup, .bigcap, .bigsqcup => true,
        .int, .oint => false,
    };
}

/// The drawn glyph's ink extents of a big operator, in em of the glyph's
/// font-size (measured with fontTools on latinmodern-math.otf 2.005).
/// Latin Modern Math draws every big op AXIS-CENTERED — ∑/∏/∐ ink
/// +0.750/−0.250em, ∫/∮ +0.805/−0.306em, ⋂ +0.772/−0.250, ⋃ +0.750/−0.272,
/// ⨆ +0.764/−0.264 (the font MATH axis is 0.250em) — unlike cmex10 whose
/// glyphs hang almost entirely below the baseline. The big-op BOX takes
/// its WIDTH from the hmtx ADVANCE (below) and its height/depth from this
/// ink, at the drawn glyph size,
/// so the viewBox bounds the real ink, the (h−d)/2 − axis shift every parent
/// applies centers the ink on the math axis (the ink center is
/// (asc−desc)/2 = 0.25em above the glyph baseline, the axis is 0.25em of
/// size_pt, so display ∑/∫ land within ±0.5·gs of the axis with NOTHING
/// clipped; XeTeX-LMMath \showbox confirms: text-style ∫ shift ≈ 0), and
/// the advance/limits/side-script geometry all measure from the true ink
/// width (the old cmex10 width under-sized the box ~1.8×: limits centered
/// on a stub, the next atom overlapped the ink, the frame clipped).
/// Widths are the LATIN-MODERN-MATH hmtx ADVANCE in em of the drawn glyph
/// (measured with fontTools: ∑ 1.056, ∏/∐ 0.944, ⋃/⋂/⨆ 0.833, ∫/∮ 0.665),
/// not the ink-bbox width (∑ 0.943, ∫ 0.553) — the advance is what the
/// rendered glyph occupies, so the box advance matches the drawn ∑/∫
/// exactly.
///
/// DISPLAY style uses the font's display variants (the MATH-table
/// MathGlyphVariantRecords XeTeX selects for display operators — measured
/// from the embedded XeTeX render: display ∑ ink +0.95/−0.45em, advance
/// 1.444em; display ∫ ink +1.361/−0.861em). The limits ops (∑ ∏ ∐ ⋃ ⋂ ⨆)
/// take the variant's FULL box (advance 1.444/1.278/1.111em — verified:
/// the following term in \sum_{i=1}^{n} x_i sits at 1.444em + thin, and the
/// over/under limits center on that box). The nolimits ops (∫ ∮) keep the
/// BASE advance for the horizontal script placement and the row advance
/// (measured: \int_0^1 sup at 0.665em + ic, row advance 0.665 + ic + scripts
/// + thin), but the box HEIGHT/DEPTH come from the display variant (so the
/// beside-script drops measure from the drawn glyph: \int_0^1 sup raise
/// 11.860 = 1.361×10 − 1.75, sub drop 10.008 = 0.861×10 + 1.40).
const BigOpInk = struct {
    advance: f32,
    /// Display-variant hmtx advance (em). For limits ops it equals
    /// `advance` (the box takes the variant advance); for the nolimits ∫/∮
    /// the ROW box keeps the base advance while the beside scripts attach
    /// at the variant advance (measured \int_0^1 sup at 0.999em).
    disp_advance: f32,
    asc: f32,
    desc: f32,
    /// MathItalicsCorrection (pt at 10pt): base glyph ic (∫ 3.32) in text
    /// style, display-variant ic (∫ .v1 5.91) in display style.
    ic: f32,
};
fn bigOpInk(op: atom.BigOp, display: bool) BigOpInk {
    const base = switch (op) {
        .sum => BigOpInk{
            .advance = 1.056,
            .disp_advance = 1.056,
            .asc = 0.750,
            .desc = 0.250,
            .ic = 0,
        }, // U+2211 ∑
        .prod => BigOpInk{
            .advance = 0.944,
            .disp_advance = 0.944,
            .asc = 0.750,
            .desc = 0.250,
            .ic = 0,
        }, // U+220F ∏
        .coprod => BigOpInk{
            .advance = 0.944,
            .disp_advance = 0.944,
            .asc = 0.750,
            .desc = 0.250,
            .ic = 0,
        }, // U+2210 ∐
        .bigcup => BigOpInk{
            .advance = 0.833,
            .disp_advance = 0.833,
            .asc = 0.750,
            .desc = 0.272,
            .ic = 0,
        }, // U+22C3 ⋃
        .bigcap => BigOpInk{
            .advance = 0.833,
            .disp_advance = 0.833,
            .asc = 0.772,
            .desc = 0.250,
            .ic = 0,
        }, // U+22C2 ⋂
        .bigsqcup => BigOpInk{
            .advance = 0.833,
            .disp_advance = 0.833,
            .asc = 0.764,
            .desc = 0.264,
            .ic = 0,
        }, // U+2A06 ⨆
        .int => BigOpInk{
            .advance = 0.665,
            .disp_advance = 0.665,
            .asc = 0.805,
            .desc = 0.306,
            .ic = 3.32,
        }, // U+222B ∫
        .oint => BigOpInk{
            .advance = 0.665,
            .disp_advance = 0.665,
            .asc = 0.805,
            .desc = 0.306,
            .ic = 3.32,
        }, // U+222E ∮
    };
    if (!display) return base;
    // Display variants (summation.v1, integral.v1, ... — hmtx advances and
    // ink measured with fontTools; the ink matches the embedded XeTeX
    // render within 0.001em; the .v1 MathItalicsCorrection values are
    // 0 for the limits ops and 0.591em for ∫/∮).
    return switch (op) {
        .sum => BigOpInk{ .advance = 1.444, .disp_advance = 1.444, .asc = 0.950, .desc = 0.450, .ic = 0 },
        .prod => BigOpInk{ .advance = 1.278, .disp_advance = 1.278, .asc = 0.950, .desc = 0.450, .ic = 0 },
        .coprod => BigOpInk{ .advance = 1.278, .disp_advance = 1.278, .asc = 0.950, .desc = 0.450, .ic = 0 },
        .bigcup => BigOpInk{ .advance = 1.111, .disp_advance = 1.111, .asc = 0.917, .desc = 0.439, .ic = 0 },
        .bigcap => BigOpInk{ .advance = 1.111, .disp_advance = 1.111, .asc = 0.939, .desc = 0.417, .ic = 0 },
        .bigsqcup => BigOpInk{ .advance = 1.111, .disp_advance = 1.111, .asc = 0.936, .desc = 0.436, .ic = 0 },
        // ∫/∮ nolimits: the row box keeps the base advance (measured: the
        // scripted \int_0^1 row advances by 0.665em + scripts, and the bare
        // \int x by 0.665 + 0.334 + thin) but the box height/depth and the
        // beside-script attachment come from the display variant: the sup
        // lands at the variant ADVANCE (0.999em — measured \int_0^1 sup at
        // 9.988pt) and the sub at variant advance − variant italic
        // (0.408em — measured \int_0^1 sub at 4.078pt).
        .int => BigOpInk{ .advance = 0.665, .disp_advance = 0.999, .asc = 1.361, .desc = 0.861, .ic = 5.91 },
        .oint => BigOpInk{ .advance = 0.665, .disp_advance = 0.999, .asc = 1.361, .desc = 0.861, .ic = 5.91 },
    };
}

/// A big operator glyph: a char box at the operator codepoint, BOXED BY THE
/// DRAWN FONT'S INK (bigOpInk × drawn size) — the box WIDTH is the hmtx
/// ADVANCE and the height/depth the ink asc/desc, so the box bounds exactly
/// what the glyph occupies horizontally and what is drawn vertically. The
/// old cmex10 width (∑ 14.44448, ∫ 5.55557, unscaled design values)
/// under-sized the box ~1.8×, so the over-limit centered on a stub instead
/// of the ink, the next atom overlapped the ∑, the viewBox clipped, and the
/// ∫ side-script sat on top of the ink. The bigop spacing/limits gaps still
/// come from cmex10: those are spacing facts, independent of the drawn
/// glyph. In display style the BOX takes the font's display-variant extents
/// (bigOpInk display branch — ∑ advance 1.444em, ink 0.950/0.450; ∫ keeps
/// the base advance 0.665em with the variant ink 1.361/0.861), so the
/// over/under-limit kerns and the beside-script drops measure from the XeTeX
/// reference geometry. The BOX is what the limits/scripts/advance geometry
/// (and every parent shift) is computed from, and it stays AT DESIGN (the
/// variant extents × size_pt) in every style.
///
/// The DRAWN glyph is a second, independent knob: the SVG <text> draws the
/// cmap BASE glyph at font-size `size` (always AT DESIGN — size_pt in every
/// style), while XeTeX draws the MATH-table display VARIANT (summation.v1,
/// integral.v1, …) — a taller, proportionally different glyph (∫ base aspect
/// 0.498 vs .v1 0.399). Round 2 drew the base glyph at a scaled font-size
/// (variant ink height ÷ base ink height: ∑ 1.4, ∫ 2.0) to match the HEIGHT,
/// but a single font-size scalar cannot match width too: the ∫ came out ~25%
/// too wide at the height-matched scale and overlapped its beside scripts.
/// Round 3 keeps the drawn size AT DESIGN (reverted) and lets the critique
/// PIL rasterizer resolve the actual .v1 variant glyph (fontTools MATH table
/// → patched-font PUA → PIL) so the drawn ink matches the reference in width
/// AND height (∑ 63.9×67.2, ∫ 42.6×106.7 vs ref 63.65×66.97, 42.42×106.24 at
/// 48pt). The box/limits geometry is untouched, so the frame margin
/// (0.35 × the largest drawn size, svg.zig) bounds the variant ink (the box
/// equals the variant extents × size_pt in display style).
fn layoutOp(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    style: Style,
    size_pt: f32,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    const op: atom.BigOp = @fromBackingInt(@intCast(n.data & atom.LimitsBits.value_mask));
    const cp = bigOpCodepoint(op);
    const display = style == .display;
    const ink = bigOpInk(op, display);
    // Box AT DESIGN: display ops box by the display-variant extents, all
    // other styles by the base extents, always × size_pt. The limits kerns,
    // beside-script drops and the row advance all measure from this box and
    // are byte-identical to round 1 (verified ≤0.2pt vs XeTeX).
    const box_w = ink.advance * size_pt;
    const box_h = ink.asc * size_pt;
    const box_d = ink.desc * size_pt;
    // DRAWN size: every style draws the glyph at the current size (XeTeX
    // selects the MATH-table display VARIANT for display big-ops, so the
    // SVG's base glyph at design size is shorter than the box; the critique
    // rasterizer resolves the .v1 variant itself and draws it at THIS size,
    // landing exactly on the box — see scripts/critique.py). Round 2 scaled
    // this font-size (1.4x/2.0x) to fake the variant height; a single scalar
    // cannot match both dims (the ∫ base aspect 0.498 vs .v1 0.399), so the
    // size stays AT DESIGN and the variant is drawn directly.
    const glyph_size = size_pt;
    const box_idx = try list.create(
        .char,
        box_w,
        box_h,
        box_d,
        &.{},
        cp,
        .italic,
        glyph_size,
        span,
    );
    // The glyph is synthesized: its utf-8 does not match the source span
    // (e.g. \sum → ∑), so flatten must dupe it instead of aliasing src.
    list.boxes.items[box_idx].synthetic = true;
    return box_idx;
}

/// \mathchoice{D}{T}{S}{SS} — TeX's four-style choice primitive: the branch
/// matching the CURRENT math style (display→0, text→1, script→2,
/// scriptscript→3; the cramped bit is dropped — TeX math_choice chooses by
/// the style class) is laid out with the branch's OWN style FORCED — the
/// same forcing \displaystyle/\dfrac use (FeatStyleSwitches: branch i is set
/// at style i), so the D branch renders at the display size even inside a
/// script (a \mathchoice{\frac{1}{2}}{x}{y}{z} under \sum's scripts keeps
/// its full-size display fraction), and the chosen branch is always
/// UNCramped (TeX sets the branch's style to its non-cramped class, so a
/// choice in a denominator raises the branch's scripts by sup2, not sup3).
/// The size follows the style level root-relative like the .mathstyle
/// wrapper: size_pt × styleScale(branch)/styleScale(current). The other
/// three branches are never laid out — the box is the chosen branch's box
/// (its content span rides along, so provenance stays exact).
fn layoutMathChoice(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
) !u32 {
    const branch: Style = style; // branch i is set at style i
    const child = ast.child(idx, @backingInt(branch));
    const gl = fm.glue(fm);
    return layoutInner(
        list,
        ast,
        child,
        fm,
        branch,
        size_pt * (styleScale(gl, branch) / styleScale(gl, style)),
        cstyle,
        false, // forced styles are uncramped (like \displaystyle)
    );
}

fn layoutFraction(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    const line = atom.fracLine(n.data);
    const gl = fm.glue(fm);

    // Forced style (\dfrac \tfrac) and \cfrac's parts-at-display flag:
    //   \dfrac = \frac in DISPLAY style (amsmath \genfrac style 0),
    //   \tfrac = \frac in TEXT style (style 2),
    //   \cfrac = display gaps AND both parts in display style (amsmath's
    //            \frac{\displaystyle{num}}{\displaystyle{den}}).
    // The effective style drives gap selection (num1/denom1 vs num2/denom2)
    // and the part-style ladder; the effective size follows the STYLE LEVEL
    // (target scale / current scale — styleScale), so \dfrac inside a
    // script renders at display size with text-size parts, exactly TeX's
    // style-force semantics (the style determines the font size). A plain
    // \frac/\atop has no forced style: eff = current, ratio 1.0, so every
    // existing path is byte-identical.
    const forced = atom.fracForcedStyle(n.data);
    const parts_display = atom.fracPartsDisplay(n.data);
    const eff_style: Style = forced orelse style;
    const eff_size = size_pt * (styleScale(gl, eff_style) / styleScale(gl, style));
    const axis = s(gl.axis_height, eff_size);
    // \genfrac's explicit rule thickness: an absolute TeX dimension (a
    // \genfrac{}{}{1pt} rule stays 1pt at every size, unlike \frac's
    // font-relative rule_thickness which scales with the size — measured
    // XeTeX: \frac rule 1.4345pt vs \genfrac 1pt rule 0.9963pt at 36pt, the
    // same absolute value as at 10pt). 0 for plain \frac/\atop and for a
    // 0pt genfrac (which is \atop-style: no rule at all).
    const thick = atom.fracThickness(n.data);
    const rt = if (thick > 0) thick else s(gl.rule_thickness, eff_size);

    // Numerator and denominator are set one style level down (MicroTeX
    // FractionAtom::createBox → env.numStyle()/dnomStyle()): display → text,
    // text → script, script/scriptscript → scriptscript. \cfrac instead
    // sets BOTH parts in display style.
    const part_style: Style = if (parts_display)
        .display
    else if (eff_style == .display) .text else if (eff_style == .text) .script else .script_script;
    const part_scale = switch (part_style) {
        .display, .text => 1.0,
        .script => gl.scriptfactor,
        .script_script => gl.scriptscriptfactor,
    };
    const part_size = eff_size * part_scale;

    // Numerator and denominator are set one style level down (tex.web
    // num_style/denom_style). The NUMERATOR inherits the cramped bit
    // (num_style: cramped iff the current style is cramped); the
    // DENOMINATOR is always cramped (denom_style: smaller + cramped) —
    // verified: display \frac{x^2}{y^2} raises the numerator sup by sup2
    // (3.62892) but the denominator sup by sup3 (2.88889). \cfrac's parts
    // are explicit \displaystyle fields (amsmath), so BOTH are uncramped.
    const part_cramped = !parts_display;
    const num = try layoutInner(
        list,
        ast,
        ast.child(idx, 0),
        fm,
        part_style,
        part_size,
        cstyle,
        cramped and part_cramped,
    );
    const den = try layoutInner(
        list,
        ast,
        ast.child(idx, 1),
        fm,
        part_style,
        part_size,
        cstyle,
        part_cramped,
    );
    const nb = list.get(num);
    const db = list.get(den);

    const vbox_w = @max(nb.width, db.width);

    // Gap parameters and clearance (MicroTeX FractionAtom::createBox),
    // selected by the EFFECTIVE style (forced for \dfrac/\tfrac/\cfrac):
    // display → num1/denom1 with clearance 3·rt (rule) or 7·drt (\atop);
    // text/script → num2/denom2 (num3 for \atop) with clearance rt (3·drt).
    var shift_up: f32 = undefined;
    var shift_down: f32 = undefined;
    var clr: f32 = undefined;
    if (eff_style == .display) {
        shift_up = s(gl.num1, eff_size);
        shift_down = s(gl.denom1, eff_size);
        clr = if (line) 3 * rt else 7 * rt;
    } else {
        shift_down = s(gl.denom2, eff_size);
        if (line) {
            shift_up = s(gl.num2, eff_size);
            clr = rt;
        } else {
            shift_up = s(gl.num3, eff_size);
            clr = 3 * rt;
        }
    }

    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    var num_shift: f32 = undefined;
    var den_shift: f32 = undefined;
    if (line) {
        // Rule is centered on the axis; enforce the clearance on both sides
        // by raising the shift amounts (MicroTeX kern1/kern2 adjustment).
        const delta = rt / 2;
        const kern1 = shift_up - nb.depth - (axis + delta);
        const kern2 = (axis - delta) - (db.height - shift_down);
        if (kern1 < clr) shift_up += clr - kern1;
        if (kern2 < clr) shift_down += clr - kern2;
        num_shift = -shift_up;
        den_shift = shift_down;
    } else {
        // \atop: split any clearance deficit evenly between both parts.
        const kern = shift_up - nb.depth - (db.height - shift_down);
        const delta = (clr - kern) / 2;
        if (delta > 0) {
            shift_up += delta;
            shift_down += delta;
        }
        num_shift = -shift_up;
        den_shift = shift_down;
    }
    const height = shift_up + nb.height;
    const depth = shift_down + db.depth;

    // TeX wraps a delimiter-less generalized fraction (\over, \atop) in two
    // null-delimiter boxes of width \nulldelimiterspace (measured \showbox:
    // the row box is hbox{pad 1.2, vbox max(num,den), pad 1.2} — 11.44455pt
    // for a 9.04456pt vbox at 10pt). The pads are FIXED 1.2pt, unscaled in
    // script styles (measured at 5pt). We keep the superflat model by folding
    // the pads into the vbox: widen it by 2·pad and shift every child 1.2pt
    // right (the rule spans only the inner max(num,den) width).
    const pad: f32 = 1.2; // TeX \nulldelimiterspace
    const box_w = vbox_w + 2 * pad;

    try list.scratch.append(list.gpa, .{ .idx = num, .x_shift = pad + (vbox_w - nb.width) / 2, .shift = num_shift });
    if (line) {
        const rule = try list.createLeaf(.rule, vbox_w, rt / 2, rt / 2, span);
        // The rule sits on the math axis, `axis` above the vbox baseline
        // (MicroTeX FractionAtom stacks it at the axis; the old shift=0 put
        // it on the baseline, floating the numerator and letting the
        // denominator punch through the bar). The clearance math above
        // already measures kern1/kern2 from the axis, so only the rule's own
        // placement needed fixing.
        try list.scratch.append(list.gpa, .{ .idx = rule, .x_shift = pad, .shift = -axis });
    }
    try list.scratch.append(list.gpa, .{ .idx = den, .x_shift = pad + (vbox_w - db.width) / 2, .shift = den_shift });

    return list.create(.vbox, box_w, height, depth, list.scratch.items[saved_len..], 0, cstyle, 0, span);
}

fn layoutSpace(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    _: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    // Mu-unit spaces (\, \; \!) and quads are measured against the SYMBOL
    // font's quad at the current style (tex.web: 1mu = quad/18 of family 2;
    // \quad = 18mu). cmsy7's quad is 1.170641em, cmsy5's 1.472241em — a
    // thin space in a script is 3/18×1.170641×7 = 1.3657pt, not 1.1667
    // (measured via XeTeX \showbox on x^{a\,b}: glue 1.36574pt).
    const em = atom.fixedToEm(n.data); // Q16.16 width in em
    const width = em * size_pt * quadEm(style);
    return list.createLeaf(.glue, width, 0, 0, span);
}

fn layoutText(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    size_pt: f32,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    const tstyle: atom.CharStyle = @fromBackingInt(@intCast(n.data));
    // strip the surrounding braces: text bytes are span.start+1 .. span.end-1
    const inner = ast.src[span.start + 1 .. span.end - 1];

    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    var x: f32 = 0;
    var height: f32 = 0;
    var depth: f32 = 0;
    var it = Graphemes.iterator(inner);
    while (it.next()) |g| {
        const bytes = g.bytes(inner);
        const off = @intFromPtr(bytes.ptr) - @intFromPtr(inner.ptr);
        const gstart: u32 = @intCast(span.start + 1 + off);
        const gend: u32 = @intCast(gstart + bytes.len);
        const cp = firstCodepoint(bytes);
        // Math-italic letters/Greek map to U+1D4xx/U+1D6xx like layoutChar
        // (validated against the active metric source); \text/\mathrm runs
        // are `.roman` so they stay upright ASCII.
        var mcp: u21 = cp;
        if (tstyle == .italic) {
            if (mathItalic(cp)) |m| {
                if (metrics.hasGlyph(fm, m, tstyle)) mcp = m;
            }
        }
        var w: f32 = undefined;
        if (metrics.glyphAt(fm, mcp, tstyle, size_pt)) |gm| {
            w = s(gm.width, size_pt);
        } else if (metrics.glyphAt(fm, cp, tstyle, size_pt)) |gm| {
            w = s(gm.width, size_pt);
        } else {
            const cells: u8 = @intCast(DisplayWidth.strWidth(bytes));
            w = @as(f32, @floatFromInt(cells)) * size_pt;
        }
        // Box height/depth by the DRAWN ink (see layoutChar); unknown
        // glyphs get the font design bound 0.750/0.250 via glyphInk.
        const ink = metrics.glyphInk(mcp);
        const cbox = try list.create(
            .char,
            w,
            ink.asc * size_pt,
            ink.desc * size_pt,
            &.{},
            mcp,
            tstyle,
            size_pt,
            .{ .start = gstart, .end = gend },
        );
        if (mcp != cp) list.boxes.items[cbox].synthetic = true;
        try list.scratch.append(list.gpa, .{ .idx = cbox, .x_shift = x, .shift = 0 });
        x += w;
        height = @max(height, ink.asc * size_pt);
        depth = @max(depth, ink.desc * size_pt);
    }
    return list.create(.hbox, x, height, depth, list.scratch.items[saved_len..], 0, tstyle, 0, span);
}

// ── tests ────────────────

const testing = std.testing;
const fm_default = metrics.default;

test {
    testing.refAllDecls(@This());
}

test "layout: group is transparent (no own box)" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "x");
    defer a.deinit();
    // hand-build: char 'x' wrapped in a group
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    const c = try a.createLeaf(.char, 0, 1, 0); // spans token 0
    const g = try a.createNode(.group, 0, 1, &.{a.node(c)}, 0);
    const b = try layout(&list, &a, g, &fm_default, .text, 10, .italic);
    try testing.expectEqual(.char, list.get(b).kind);
}

test "layout: space becomes a glue box of em width" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "\\,");
    defer a.deinit();
    try a.pushToken(.{ .tag = .command, .start = 0, .end = 2 });
    const sp = try a.createLeaf(.space, 0, 0, f32ToFixed(0.166));
    const b = try layout(&list, &a, sp, &fm_default, .text, 10, .italic);
    const bb = list.get(b);
    try testing.expectEqual(.glue, bb.kind);
    try testing.expectApproxEqAbs(@as(f32, 1.66), bb.width, 0.01);
}

fn f32ToFixed(v: f32) u32 {
    return @bitCast(@as(i32, @intFromFloat(v * 65536.0)));
}

test "layout: sub-only script places subscript below base (F1)" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "x_2");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .sub, .start = 1, .end = 2 });
    try a.pushToken(.{ .tag = .char, .start = 2, .end = 3 });
    const base = try a.createLeaf(.char, 0, 1, 0);
    const sub = try a.createLeaf(.char, 2, 1, 0);
    const children = [_]atom.Node{ a.node(base), a.node(sub) };
    const script = try a.createNode(.script, 0, 3, &children, atom.ScriptBits.sub);
    const b = try layout(&list, &a, script, &fm_default, .text, 10, .italic);
    const sb = list.get(b);
    try testing.expectEqual(.script, sb.kind);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 2), ch.len);
    // subscript must shift DOWN (positive shift), never up
    try testing.expect(ch[1].shift > 0);
}

test "layout: big operator limits in display style become a vbox" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "ab");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .char, .start = 1, .end = 2 });
    const op = try a.createLeaf(.op, 0, 0, @backingInt(atom.BigOp.sum));
    const sup = try a.createLeaf(.char, 0, 1, 0); // 'a'
    const sub = try a.createLeaf(.char, 1, 1, 0); // 'b'
    const children = [_]atom.Node{ a.node(op), a.node(sup), a.node(sub) };
    const script = try a.createNode(.script, 0, 2, &children, atom.ScriptBits.sup | atom.ScriptBits.sub);
    const b = try layout(&list, &a, script, &fm_default, .display, 10, .italic);
    const sb = list.get(b);
    try testing.expectEqual(.vbox, sb.kind);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 3), ch.len);
    // children order: [sup, op, sub]; sup above (negative shift), sub below
    try testing.expect(ch[0].shift < 0);
    // display ∑ box is the drawn LM-Math ink extents at gs=1.4*10 (h=10.5, d=3.5)
    // centered on the math axis (2.5pt above baseline): the ∑ ink box at
    // design size 10pt (h=7.5, d=2.5) gives shift = (h−d)/2 − axis = 0
    try testing.expectApproxEqAbs(@as(f32, 0.0), ch[1].shift, 0.001);
    try testing.expect(ch[2].shift > 0);
}

test "layout: big operator beside scripts in text style is a script box" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "ab");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .char, .start = 1, .end = 2 });
    const op = try a.createLeaf(.op, 0, 0, @backingInt(atom.BigOp.sum));
    const sup = try a.createLeaf(.char, 0, 1, 0);
    const children = [_]atom.Node{ a.node(op), a.node(sup) };
    const script = try a.createNode(.script, 0, 1, &children, atom.ScriptBits.sup);
    const b = try layout(&list, &a, script, &fm_default, .text, 10, .italic);
    try testing.expectEqual(.script, list.get(b).kind);
}

test "layout: \\limits forces over/under in TEXT style (TeX applies \\limits in both)" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "ab");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .char, .start = 1, .end = 2 });
    const op = try a.createLeaf(.op, 0, 0, @backingInt(atom.BigOp.sum) | atom.LimitsBits.force);
    const sub = try a.createLeaf(.char, 1, 1, 0);
    const children = [_]atom.Node{ a.node(op), a.node(sub) };
    const script = try a.createNode(.script, 0, 2, &children, atom.ScriptBits.sub);
    const b = try layout(&list, &a, script, &fm_default, .text, 10, .italic);
    const sb = list.get(b);
    // text style + \limits → the limits vbox, NOT a beside script box
    try testing.expectEqual(.vbox, sb.kind);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 2), ch.len);
    // children [op, sub]: the subscript hangs BELOW (positive shift)
    try testing.expect(ch[1].shift > 0);
}

test "layout: \\nolimits forces beside scripts in DISPLAY style" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "ab");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .char, .start = 1, .end = 2 });
    const op = try a.createLeaf(.op, 0, 0, @backingInt(atom.BigOp.sum) | atom.LimitsBits.force_beside);
    const sup = try a.createLeaf(.char, 0, 1, 0);
    const children = [_]atom.Node{ a.node(op), a.node(sup) };
    const script = try a.createNode(.script, 0, 1, &children, atom.ScriptBits.sup);
    const b = try layout(&list, &a, script, &fm_default, .display, 10, .italic);
    // display ∑ default is limits → a vbox; \nolimits forces a beside script box
    try testing.expectEqual(.script, list.get(b).kind);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 2), ch.len);
    // the superscript sits to the RIGHT of the base (positive x)
    try testing.expect(ch[1].x_shift > 0);
}

test "layout: \\limits on \\int in display style becomes a limits vbox" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "ab");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .char, .start = 1, .end = 2 });
    const op = try a.createLeaf(.op, 0, 0, @backingInt(atom.BigOp.int) | atom.LimitsBits.force);
    const sub = try a.createLeaf(.char, 1, 1, 0);
    const children = [_]atom.Node{ a.node(op), a.node(sub) };
    const script = try a.createNode(.script, 0, 2, &children, atom.ScriptBits.sub);
    const b = try layout(&list, &a, script, &fm_default, .display, 10, .italic);
    // display ∫ default is nolimits (beside); \limits forces the vbox
    try testing.expectEqual(.vbox, list.get(b).kind);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 2), ch.len);
    // the under-limit hangs BELOW the ∫ (positive shift)
    try testing.expect(ch[1].shift > 0);
}

test "layout: \\limits on an operator word in text style is a limits vbox" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "lim");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    const l = try a.createLeaf(.char, 0, 1, 'l');
    const i = try a.createLeaf(.char, 0, 1, 'i');
    const m = try a.createLeaf(.char, 0, 1, 'm');
    const word = try a.createNode(.row, 0, 1, &.{ a.node(l), a.node(i), a.node(m) }, 0);
    const opn = try a.createNode(.opname, 0, 1, &.{a.node(word)}, atom.LimitsBits.force);
    const sub = try a.createLeaf(.char, 0, 1, 0);
    const children = [_]atom.Node{ a.node(opn), a.node(sub) };
    const script = try a.createNode(.script, 0, 1, &children, atom.ScriptBits.sub);
    const b = try layout(&list, &a, script, &fm_default, .text, 10, .italic);
    // \lim defaults to beside in text style; \limits forces "x→0" UNDER the
    // word even in text style → a vbox with the sub below
    try testing.expectEqual(.vbox, list.get(b).kind);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 2), ch.len);
    try testing.expect(ch[1].shift > 0);
}

test "layout: text yields one char box per grapheme" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "{abc}");
    defer a.deinit();
    try a.pushToken(.{ .tag = .l_group, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .char, .start = 1, .end = 2 });
    try a.pushToken(.{ .tag = .char, .start = 2, .end = 3 });
    try a.pushToken(.{ .tag = .char, .start = 3, .end = 4 });
    try a.pushToken(.{ .tag = .r_group, .start = 4, .end = 5 });
    const t = try a.createLeaf(.text, 0, 5, @backingInt(atom.CharStyle.roman));
    const b = try layout(&list, &a, t, &fm_default, .text, 10, .italic);
    const tb = list.get(b);
    try testing.expectEqual(.hbox, tb.kind);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 3), ch.len);
    for (ch) |cr| try testing.expectEqual(.char, list.get(cr.idx).kind);
    // a+b+c at 10pt with LM Math roman advances (5.0 + 5.56 + 4.44)
    try testing.expectApproxEqAbs(@as(f32, 15.0), tb.width, 0.01);
}

test "layout: text with a CJK char uses the DisplayWidth fallback" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "{界}");
    defer a.deinit();
    try a.pushToken(.{ .tag = .l_group, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .char, .start = 1, .end = 4 });
    try a.pushToken(.{ .tag = .r_group, .start = 4, .end = 5 });
    const t = try a.createLeaf(.text, 0, 3, @backingInt(atom.CharStyle.roman));
    const b = try layout(&list, &a, t, &fm_default, .text, 10, .italic);
    const tb = list.get(b);
    try testing.expectEqual(.hbox, tb.kind);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 1), ch.len);
    const cb = list.get(ch[0].idx);
    try testing.expectEqual(.char, cb.kind);
    // fallback dims: h = 0.75*size (ink asc), d = 0.25*size (ink desc),
    // w = DisplayWidth*size
    try testing.expectApproxEqAbs(@as(f32, 7.5), cb.height, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 2.5), cb.depth, 0.01);
    const dw: f32 = @floatFromInt(DisplayWidth.strWidth("界"));
    try testing.expectApproxEqAbs(dw * 10.0, cb.width, 0.01);
}

test "layout: styled wraps a char with the declared style" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "x");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    const c = try a.createLeaf(.char, 0, 1, 0);
    const st = try a.createNode(.styled, 0, 1, &.{a.node(c)}, @backingInt(atom.CharStyle.roman));
    const b = try layout(&list, &a, st, &fm_default, .text, 10, .italic);
    const cb = list.get(b);
    try testing.expectEqual(.char, cb.kind);
    try testing.expectEqual(atom.CharStyle.roman, cb.style);
}

test "layout: atop fraction is a vbox with no rule child" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "ab");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .char, .start = 1, .end = 2 });
    const num = try a.createLeaf(.char, 0, 1, 0);
    const den = try a.createLeaf(.char, 1, 1, 0);
    const frac = try a.createNode(
        .fraction,
        0,
        2,
        &.{ a.node(num), a.node(den) },
        atom.fracData(false, null, false), // atop: no rule line
    );
    const b = try layout(&list, &a, frac, &fm_default, .text, 10, .italic);
    const fb = list.get(b);
    try testing.expectEqual(.vbox, fb.kind);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 2), ch.len);
    for (ch) |cr| try testing.expectEqual(.char, list.get(cr.idx).kind);
}

test "layout: dfrac in a script context renders at display size (text-size parts)" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "12");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .char, .start = 1, .end = 2 });
    const num = try a.createLeaf(.char, 0, 1, 0);
    const den = try a.createLeaf(.char, 1, 1, 0);
    const frac = try a.createNode(
        .fraction,
        0,
        2,
        &.{ a.node(num), a.node(den) },
        atom.fracData(true, .display, false),
    );
    // laid out in a SCRIPT context (7pt): \dfrac forces display → the parts
    // jump back to the text size (10pt) with display gaps (num1/denom1).
    const b = try layout(&list, &a, frac, &fm_default, .script, 7, .italic);
    const fb = list.get(b);
    try testing.expectEqual(.vbox, fb.kind);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 3), ch.len); // num, rule, den
    const nb = list.get(ch[0].idx);
    try testing.expectEqual(.char, nb.kind);
    // part at 10pt (text size), NOT the plain-fraction 7×0.5 = 3.5pt
    try testing.expectApproxEqAbs(@as(f32, 10.0), nb.size, 0.01);
    // the rule sits on the axis at the effective (10pt) scale
    try testing.expectApproxEqAbs(@as(f32, -2.5), ch[1].shift, 0.01);
    // display fraction at 10pt: num1 (6.765) above the axis, denom1 (6.8595) below
    try testing.expectApproxEqAbs(@as(f32, 6.765 + nb.height), fb.height, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 6.8595 + list.get(ch[2].idx).depth), fb.depth, 0.01);
}

test "layout: tfrac in display keeps text gaps and script-size parts" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "12");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .char, .start = 1, .end = 2 });
    const num = try a.createLeaf(.char, 0, 1, 0);
    const den = try a.createLeaf(.char, 1, 1, 0);
    const frac = try a.createNode(.fraction, 0, 2, &.{ a.node(num), a.node(den) }, atom.fracData(true, .text, false));
    const b = try layout(&list, &a, frac, &fm_default, .display, 10, .italic);
    const fb = list.get(b);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 3), ch.len);
    // \tfrac parts are script-size (7pt), not the display \frac's 10pt
    try testing.expectApproxEqAbs(@as(f32, 7.0), list.get(ch[0].idx).size, 0.01);
    // text gaps: num2 (3.9373) not num1 (6.765)
    try testing.expectApproxEqAbs(@as(f32, 3.9373 + list.get(ch[0].idx).height), fb.height, 0.01);
}

test "layout: cfrac sets both parts in display style (uncramped, display gaps)" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "12");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .char, .start = 1, .end = 2 });
    const num = try a.createLeaf(.char, 0, 1, 0);
    const den = try a.createLeaf(.char, 1, 1, 0);
    const frac = try a.createNode(.fraction, 0, 2, &.{ a.node(num), a.node(den) }, atom.fracData(true, .display, true));
    const b = try layout(&list, &a, frac, &fm_default, .text, 10, .italic);
    const ch = list.children(b);
    // parts in DISPLAY style: same text size but the box carries display
    // style semantics (uncramped; gap params num1/denom1 like display)
    try testing.expectApproxEqAbs(@as(f32, 10.0), list.get(ch[0].idx).size, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 6.765 + list.get(ch[0].idx).height), list.get(b).height, 0.01);
}

test "layout: mathstyle wrapper forces style and rescales size" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "x");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    const c = try a.createLeaf(.char, 0, 1, 0);
    // \scriptstyle in display context: content shrinks to script size (7pt)
    const ms1 = try a.createNode(.mathstyle, 0, 1, &.{a.node(c)}, @backingInt(atom.MathStyle.script));
    const b1 = try layout(&list, &a, ms1, &fm_default, .display, 10, .italic);
    try testing.expectApproxEqAbs(@as(f32, 7.0), list.get(b1).size, 0.01);
    // \displaystyle in a script context: content grows back to text size (10pt)
    const ms2 = try a.createNode(.mathstyle, 0, 1, &.{a.node(c)}, @backingInt(atom.MathStyle.display));
    const b2 = try layout(&list, &a, ms2, &fm_default, .script, 7, .italic);
    try testing.expectApproxEqAbs(@as(f32, 10.0), list.get(b2).size, 0.01);
}

test "layout: unknown codepoint falls back to glyph estimate" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "😀"); // U+1F600, 4 bytes
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 4 });
    const c = try a.createLeaf(.char, 0, 1, 0);
    const b = try layout(&list, &a, c, &fm_default, .text, 10, .italic);
    const cb = list.get(b);
    try testing.expectEqual(.char, cb.kind);
    try testing.expect(cb.width > 0);
    // glyphEstimate at 10pt: 0.5em wide, 0.7em tall, 0.2em deep
    try testing.expectApproxEqAbs(@as(f32, 5.0), cb.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 7.5), cb.height, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 2.5), cb.depth, 0.01);
}

test "layout: math-italic maps against the static table (Latin yes, Greek no)" {
    // The systematic math-italic mapping (mathItalic) is validated against
    // the ACTIVE metric source. With the bundled tables (fm_default, no
    // font), a mapped codepoint is only emitted when the static table
    // carries it: the tables cover the U+1D4xx Latin series (and U+210E)
    // but NOT the U+1D6xx Greek series, so `x` maps to U+1D465 while
    // `\alpha` keeps its base U+03B1 — the graceful static fallback.
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();

    var a1 = atom.Ast.init(testing.allocator, "x");
    defer a1.deinit();
    try a1.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    const c1 = try a1.createLeaf(.char, 0, 1, 0);
    const b1 = try layout(&list, &a1, c1, &fm_default, .text, 10, .italic);
    try testing.expectEqual(@as(u21, 0x1D465), list.get(b1).cp);

    var a2 = atom.Ast.init(testing.allocator, "α"); // U+03B1, like \alpha
    defer a2.deinit();
    try a2.pushToken(.{ .tag = .char, .start = 0, .end = 2 });
    const c2 = try a2.createLeaf(.char, 0, 1, 0x03B1);
    const b2 = try layout(&list, &a2, c2, &fm_default, .text, 10, .italic);
    try testing.expectEqual(@as(u21, 0x03B1), list.get(b2).cp);
}
