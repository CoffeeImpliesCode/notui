//! ztex.parse.parser — token table → superflat atom pool (recursive descent).
//!
//! Walks the pre-lexed token table once, appending flat `atom.Node`s to the
//! Ast's pool via the duplication protocol (children copied as values before
//! their parent), so every node's child run is contiguous. Each node records
//! its token range for O(1) source-provenance.

const std = @import("std");
const atom = @import("ztex.atom");
const lexer = @import("lexer.zig");
const parse_err = @import("error.zig");

/// Everything the parser can return: `error.OutOfMemory` from the `Ast`
/// plus the input failures below. Each corresponds to exactly one
/// `ztex.parse.Kind`, so `Parser.err_info` is filled on every path.
///
/// The lexer's two input failures are not here — they come from `ztex.parse.lex`
/// and are unioned into `ztex.parse.Error`.
pub const Error = std.mem.Allocator.Error || error{
    UnexpectedRGroup,
    UnexpectedScript,
    DoubleScript,
    UnknownCommand,
    MissingArgument,
    MissingScript,
    UnclosedGroup,
    /// \middle outside \left...\right (TeX: "You can't use \middle in math
    /// mode"; it needs the enclosing fence's required size).
    UnexpectedMiddle,
    /// \begin with an unknown environment name (TeX: "Environment xxx
    /// undefined").
    UnknownEnvironment,
    /// \end{NAME} whose name does not match the \begin{NAME}.
    MismatchedEnd,
    /// \begin{...} never closed by \end{...} (or \end missing its name).
    UnclosedEnvironment,
    /// Row nesting deeper than `max_row_depth`. The recursion guard returns
    /// this instead of overflowing the call stack, so the guard is a
    /// published bound on accepted input rather than a crash.
    StackOverflow,
};

/// Deepest row nesting `parse` accepts, counted in nested `parseRow` calls
/// (groups, scripts, style scopes, \left...\right interiors). Input nested
/// one level deeper fails with `Error.StackOverflow` and an `Info` of kind
/// `Kind.depth_exceeded`.
pub const max_row_depth: u32 = 256;

/// Opcode for each supported command name; `cmd_map` returns one of these and
/// `parseCommand`'s switch applies the command's effect.
const Command = enum {
    space_comma,
    space_semicolon,
    space_bang,
    quad,
    qquad,
    frac,
    /// \dfrac: \frac forced to display style (display gaps, parts one level
    /// down from display)
    frac_display,
    /// \tfrac: \frac forced to text style (text gaps, script-size parts)
    frac_text,
    /// \cfrac: display-style continued fraction — display gaps AND both
    /// parts set in display style (amsmath: \frac{\displaystyle..}{\displaystyle..})
    cfrac,
    atop,
    /// \binom{num}{den} = \genfrac{(}{)}{0pt}{}{num}{den}: a ruleless
    /// fraction inside \left( \right) parens (auto-sized by the variant
    /// ladder)
    binom,
    /// \genfrac{left}{right}{thick}{style}{num}{den}: the generalized
    /// fraction — explicit delimiters (possibly empty), rule thickness
    /// (0pt = \atop-style no rule), forced style (0=display 1=text
    /// 2=script 3=scriptscript, empty = current), numerator, denominator
    genfrac,
    text,
    style_roman,
    /// \operatorname{...} / \operatorname*{...}: amsmath's declarable
    /// operator name — a \mathop whose content is the braced group set in
    /// upright roman (unstarred = nolimits, starred = displaylimits).
    operatorname,
    style_bold,
    style_bb,
    style_cal,
    style_frak,
    style_sans,
    style_mono,
    cdot,
    op_sum,
    op_int,
    op_prod,
    op_coprod,
    op_bigcup,
    op_bigcap,
    op_bigsqcup,
    op_oint,
    /// an operator word (\sin \lim \log ...): roman styled run of the name
    opname,
    /// \left ... \right delimited construct
    left,
    /// a stray \right (extra, outside any \left)
    right,
    /// \big \Big \bigg \Bigg: a delimiter at a FIXED ladder level
    /// (1..4); the parsed result is a `.left` node with a single
    /// delimiter child and `data` = the level.
    big,
    Big,
    bigg,
    Bigg,
    /// \middle <delim> inside \left...\right: a delimiter sized like the
    /// enclosing pair.
    middle,
    /// \limits / \nolimits / \displaylimits: consumed by parseScripts
    /// between a base and its scripts, setting the limits override bit on
    /// the preceding op/opname atom; as standalone atoms they become a
    /// zero-width space
    limits,
    nolimits,
    displaylimits,
    /// \sqrt[degree]{radicand}: surd char + radicand row
    sqrt,
    /// \dot \hat \bar \vec \ddot \tilde: an accent row (children
    /// [base, accent-mark char]; data = accent_row_data)
    dot,
    hat,
    bar,
    vec,
    ddot,
    tilde,
    /// \overline{x} / \underline{x}: a `.overline` atom (children
    /// [content]; data = 0 over / 1 under)
    overline,
    underline,
    /// \mathchoice{D}{T}{S}{SS}: a `.mathchoice` atom (children = the four
    /// style branches [D, T, S, SS]); layout picks the branch matching the
    /// current math style and forces the branch's own style
    mathchoice,
    /// \not<relation>: a negation PREFIX — the following atom/group gets a
    /// diagonal slash. Emits the pre-composed glyph when one exists (see
    /// `not_cp_map`), else a `not_row_data` row whose layout overlays the
    /// U+0338 combining long solidus overlay.
    not,
    /// \substack{...}: a script-size multi-line stack for limits (children
    /// = the \\-separated line rows; a `.substack` atom)
    substack,
    /// \pmod{n} / \pod{n}: amsmath's parenthesized mod — a composed row
    /// ['(', (roman "mod" + 6mu space, for \pmod), arg, ')'] with the
    /// style-dependent leading \mkern (18mu display / 8mu otherwise)
    pmod,
    pod,
    /// \bmod: amsmath's binary mod — a row ['5mu space, roman "mod" word,
    /// 5mu space'] (the \mskip-\medmuskip\mkern5mu dance around the
    /// \mathbin{mod} nets to 5mu on each side; see bmod()).
    bmod,
    /// \mod{arg}: amsmath's display-style mod — a row [roman "mod" word,
    /// 6mu space, arg] with a style-dependent leading \mkern (18mu display /
    /// 12mu otherwise; see mod()).
    mod,
    /// \begin{env}...\end{env}: a math environment (matrix family, cases,
    /// aligned, array) — parsed by parseBegin into a `.env` atom.
    begin,
};

/// Comptime command table keyed by the exact command names (no backslash).
/// std.StaticStringMap sorts the keys by length at comptime: `getIndex`
/// rejects unknown lengths O(1) and scans only the equal-length bucket with
/// byte equality — no length off-by-one is possible because the compiler
/// derives key lengths from the literal strings.
const cmd_map = std.StaticStringMap(Command).initComptime(&[_]struct { []const u8, Command }{
    .{ ",", .space_comma },
    .{ ";", .space_semicolon },
    .{ "!", .space_bang },
    .{ "quad", .quad },
    .{ "qquad", .qquad },
    .{ "frac", .frac },
    .{ "dfrac", .frac_display },
    .{ "tfrac", .frac_text },
    .{ "cfrac", .cfrac },
    .{ "atop", .atop },
    .{ "binom", .binom },
    .{ "genfrac", .genfrac },
    .{ "text", .text },
    .{ "mathrm", .style_roman },
    .{ "operatorname", .operatorname },
    .{ "mathbf", .style_bold },
    .{ "mathbb", .style_bb },
    .{ "mathcal", .style_cal },
    .{ "mathfrak", .style_frak },
    .{ "mathsf", .style_sans },
    .{ "mathtt", .style_mono },
    .{ "cdot", .cdot },
    .{ "sum", .op_sum },
    .{ "int", .op_int },
    .{ "prod", .op_prod },
    .{ "coprod", .op_coprod },
    .{ "bigcup", .op_bigcup },
    .{ "bigcap", .op_bigcap },
    .{ "bigsqcup", .op_bigsqcup },
    .{ "oint", .op_oint },
    .{ "left", .left },
    .{ "right", .right },
    .{ "big", .big },
    .{ "Big", .Big },
    .{ "bigg", .bigg },
    .{ "Bigg", .Bigg },
    .{ "middle", .middle },
    .{ "limits", .limits },
    .{ "nolimits", .nolimits },
    .{ "displaylimits", .displaylimits },
    .{ "sqrt", .sqrt },
    // accents: a combining mark over the following atom/group
    .{ "dot", .dot },
    .{ "hat", .hat },
    .{ "bar", .bar },
    .{ "vec", .vec },
    .{ "ddot", .ddot },
    .{ "tilde", .tilde },
    // a rule over / under the following atom/group
    .{ "overline", .overline },
    .{ "underline", .underline },
    // the four-style choice primitive: pick the branch matching the
    // current math style, forced to the branch's own style
    .{ "mathchoice", .mathchoice },
    // a negation slash through the following atom/group
    .{ "not", .not },
    // a script-size multi-line stack for limits; the parenthesized mod
    .{ "substack", .substack },
    .{ "pmod", .pmod },
    .{ "pod", .pod },
    .{ "begin", .begin },
    // operator names → roman words (\sin x, \lim_{...}); see opname()
    .{ "sin", .opname },
    .{ "cos", .opname },
    .{ "tan", .opname },
    .{ "cot", .opname },
    .{ "sec", .opname },
    .{ "csc", .opname },
    .{ "arcsin", .opname },
    .{ "arccos", .opname },
    .{ "arctan", .opname },
    .{ "sinh", .opname },
    .{ "cosh", .opname },
    .{ "tanh", .opname },
    .{ "coth", .opname },
    .{ "sech", .opname },
    .{ "csch", .opname },
    .{ "arcsec", .opname },
    .{ "arccsc", .opname },
    .{ "log", .opname },
    .{ "ln", .opname },
    .{ "lg", .opname },
    .{ "exp", .opname },
    .{ "lim", .opname },
    .{ "limsup", .opname },
    .{ "liminf", .opname },
    .{ "max", .opname },
    .{ "min", .opname },
    .{ "sup", .opname },
    .{ "inf", .opname },
    .{ "arg", .opname },
    .{ "ker", .opname },
    .{ "dim", .opname },
    .{ "det", .opname },
    .{ "gcd", .opname },
    .{ "Pr", .opname },
    .{ "hom", .opname },
    .{ "deg", .opname },
    // \mod and \bmod are NOT \mathop words: \mod takes an argument and a
    // style-dependent leading \mkern, \bmod is a \mathbin with 5mu kerns
    // (see bmod()/mod()).
    .{ "mod", .mod },
    .{ "bmod", .bmod },
});

/// \displaystyle \textstyle \scriptstyle \scriptscriptstyle → forced math
/// styles. A style switch applies to the REST OF THE CURRENT GROUP (TeX
/// mathlist semantics), so parseRow and parseScriptArg intercept the command
/// name directly and wrap the remaining atoms in a `.mathstyle` node;
/// parseCommand never sees these names.
const mathstyle_map = std.StaticStringMap(atom.MathStyle).initComptime(&[_]struct { []const u8, atom.MathStyle }{
    .{ "displaystyle", .display },
    .{ "textstyle", .text },
    .{ "scriptstyle", .script },
    .{ "scriptscriptstyle", .script_script },
});

/// Greek, relations, arrows, binary ops, and misc symbols: command name →
/// Unicode codepoint. Each maps to a `.char` leaf carrying the codepoint in
/// its `data` (same mechanism as \cdot), so layout resolves the glyph, the
/// role (roleOfCp), and the metrics. `\atop \over \choose` are NOT here:
/// they are infix row-level commands intercepted by parseRow.
const symbol_map = std.StaticStringMap(u21).initComptime(&[_]struct { []const u8, u21 }{
    // Greek lowercase (U+03B1..U+03C9 + variants). \epsilon and \varepsilon
    // follow unicode-math (XeTeX reference emits \varepsilon → U+03B5, the
    // ROUNDED epsilon; \epsilon → U+03F5, the lunate) — the OPPOSITE of
    // classic Computer-Modern TeX. Verified against the XeTeX reference
    // render of \frac{\rho}{\varepsilon_0}: \varepsilon → U+1D700 (rounded
    // math-italic), while the old mapping emitted U+1D716 (lunate).
    .{ "alpha", 0x03B1 },
    .{ "beta", 0x03B2 },
    .{ "gamma", 0x03B3 },
    .{ "delta", 0x03B4 },
    .{ "epsilon", 0x03F5 },
    .{ "varepsilon", 0x03B5 },
    .{ "zeta", 0x03B6 },
    .{ "eta", 0x03B7 },
    .{ "theta", 0x03B8 },
    .{ "vartheta", 0x03D1 },
    .{ "iota", 0x03B9 },
    .{ "kappa", 0x03BA },
    .{ "lambda", 0x03BB },
    .{ "mu", 0x03BC },
    .{ "nu", 0x03BD },
    .{ "xi", 0x03BE },
    .{ "pi", 0x03C0 },
    .{ "varpi", 0x03D6 },
    .{ "rho", 0x03C1 },
    .{ "varrho", 0x03F1 },
    .{ "sigma", 0x03C3 },
    .{ "varsigma", 0x03C2 },
    .{ "tau", 0x03C4 },
    .{ "upsilon", 0x03C5 },
    .{ "phi", 0x03C6 },
    .{ "varphi", 0x03D5 },
    .{ "chi", 0x03C7 },
    .{ "psi", 0x03C8 },
    .{ "omega", 0x03C9 },
    // Greek uppercase
    .{ "Gamma", 0x0393 },
    .{ "Delta", 0x0394 },
    .{ "Theta", 0x0398 },
    .{ "Lambda", 0x039B },
    .{ "Xi", 0x039E },
    .{ "Pi", 0x03A0 },
    .{ "Sigma", 0x03A3 },
    .{ "Upsilon", 0x03A5 },
    .{ "Phi", 0x03A6 },
    .{ "Psi", 0x03A8 },
    .{ "Omega", 0x03A9 },
    // Relations
    .{ "leq", 0x2264 },
    .{ "le", 0x2264 },
    .{ "leqq", 0x2266 },
    .{ "geq", 0x2265 },
    .{ "ge", 0x2265 },
    .{ "geqq", 0x2267 },
    .{ "neq", 0x2260 },
    .{ "ne", 0x2260 },
    .{ "in", 0x2208 },
    .{ "ni", 0x220B },
    .{ "notin", 0x2209 },
    // pre-composed negated relations (unicode-math codepoints; every one is
    // in LM Math's cmap, verified with fontTools)
    .{ "nleq", 0x2270 },
    .{ "ngeq", 0x2271 },
    .{ "nsubseteq", 0x2288 },
    .{ "nsupseteq", 0x2289 },
    .{ "nmid", 0x2224 },
    .{ "nparallel", 0x2226 },
    .{ "nprec", 0x2280 },
    .{ "nsucc", 0x2281 },
    .{ "npreceq", 0x22E0 },
    .{ "nsucceq", 0x22E1 },
    .{ "nsim", 0x2241 },
    .{ "ncong", 0x2247 },
    .{ "napprox", 0x2249 },
    .{ "subset", 0x2282 },
    .{ "supset", 0x2283 },
    .{ "subseteq", 0x2286 },
    .{ "supseteq", 0x2287 },
    .{ "sim", 0x223C },
    .{ "simeq", 0x2243 },
    .{ "cong", 0x2245 },
    .{ "approx", 0x2248 },
    .{ "propto", 0x221D },
    .{ "equiv", 0x2261 },
    .{ "ll", 0x226A },
    .{ "gg", 0x226B },
    .{ "prec", 0x227A },
    .{ "succ", 0x227B },
    .{ "preceq", 0x2AAF },
    .{ "succeq", 0x2AB0 },
    .{ "vdash", 0x22A2 },
    .{ "dashv", 0x22A3 },
    .{ "perp", 0x22A5 },
    .{ "parallel", 0x2225 },
    .{ "mid", 0x2223 },
    .{ "asymp", 0x224D },
    .{ "doteq", 0x2250 },
    .{ "models", 0x22A8 },
    .{ "bowtie", 0x22C8 },
    .{ "frown", 0x2322 },
    .{ "smile", 0x2323 },
    // Arrows
    .{ "leftarrow", 0x2190 },
    .{ "rightarrow", 0x2192 },
    .{ "to", 0x2192 },
    .{ "leftrightarrow", 0x2194 },
    .{ "Leftarrow", 0x21D0 },
    .{ "Rightarrow", 0x21D2 },
    .{ "implies", 0x21D2 },
    .{ "impliedby", 0x21D0 },
    .{ "Leftrightarrow", 0x21D4 },
    .{ "iff", 0x21D4 },
    .{ "uparrow", 0x2191 },
    .{ "downarrow", 0x2193 },
    .{ "updownarrow", 0x2195 },
    .{ "Uparrow", 0x21D1 },
    .{ "Downarrow", 0x21D3 },
    .{ "Updownarrow", 0x21D5 },
    .{ "mapsto", 0x21A6 },
    .{ "longmapsto", 0x27FC },
    .{ "nearrow", 0x2197 },
    .{ "searrow", 0x2198 },
    .{ "swarrow", 0x2199 },
    .{ "nwarrow", 0x2196 },
    .{ "hookleftarrow", 0x21A9 },
    .{ "hookrightarrow", 0x21AA },
    .{ "leftharpoonup", 0x21BC },
    .{ "leftharpoondown", 0x21BD },
    .{ "rightharpoonup", 0x21C0 },
    .{ "rightharpoondown", 0x21C1 },
    // Binary ops
    .{ "pm", 0x00B1 },
    .{ "mp", 0x2213 },
    .{ "times", 0x00D7 },
    .{ "div", 0x00F7 },
    .{ "ast", 0x2217 },
    .{ "star", 0x22C6 },
    .{ "circ", 0x2218 },
    .{ "bullet", 0x2219 },
    .{ "oplus", 0x2295 },
    .{ "ominus", 0x2296 },
    .{ "otimes", 0x2297 },
    .{ "oslash", 0x2298 },
    .{ "odot", 0x2299 },
    .{ "wedge", 0x2227 },
    .{ "vee", 0x2228 },
    .{ "land", 0x2227 },
    .{ "lor", 0x2228 },
    .{ "cup", 0x222A },
    .{ "cap", 0x2229 },
    .{ "sqcup", 0x2294 },
    .{ "sqcap", 0x2293 },
    .{ "setminus", 0x2216 },
    .{ "dagger", 0x2020 },
    .{ "ddagger", 0x2021 },
    .{ "diamond", 0x22C4 },
    .{ "wr", 0x2240 },
    .{ "uplus", 0x228E },
    .{ "amalg", 0x2A3F },
    .{ "triangleleft", 0x25C3 },
    .{ "triangleright", 0x25B9 },
    .{ "bigcirc", 0x25CB },
    // Misc symbols
    .{ "infty", 0x221E },
    .{ "partial", 0x2202 },
    .{ "nabla", 0x2207 },
    .{ "prime", 0x2032 },
    .{ "ldots", 0x2026 },
    .{ "cdots", 0x22EF },
    .{ "vdots", 0x22EE },
    .{ "ddots", 0x22F1 },
    .{ "ell", 0x2113 },
    .{ "Re", 0x211C },
    .{ "Im", 0x2111 },
    .{ "wp", 0x2118 },
    .{ "aleph", 0x2135 },
    .{ "forall", 0x2200 },
    .{ "exists", 0x2203 },
    .{ "neg", 0x00AC },
    .{ "lnot", 0x00AC },
    .{ "top", 0x22A4 },
    .{ "bot", 0x22A5 },
    .{ "emptyset", 0x2205 },
    .{ "varnothing", 0x2205 },
    .{ "angle", 0x2220 },
    .{ "triangle", 0x25B3 },
    .{ "square", 0x25A1 },
    .{ "surd", 0x221A },
    .{ "clubsuit", 0x2663 },
    .{ "diamondsuit", 0x2662 },
    .{ "heartsuit", 0x2661 },
    .{ "spadesuit", 0x2660 },
    .{ "backslash", 0x2216 },
    .{ "lbrace", 0x7B },
    .{ "rbrace", 0x7D },
    .{ "vert", 0x7C },
    .{ "Vert", 0x2016 },
    .{ "langle", 0x27E8 },
    .{ "rangle", 0x27E9 },
    .{ "lfloor", 0x230A },
    .{ "rfloor", 0x230B },
    .{ "lceil", 0x2308 },
    .{ "rceil", 0x2309 },
    .{ "therefore", 0x2234 },
    .{ "because", 0x2235 },
    .{ "colon", 0x3A },
    .{ "hbar", 0x210F },
    .{ "imath", 0x0131 },
    .{ "jmath", 0x0237 },
});

/// Delimiter commands accepted after \left / \right → codepoint.
const delim_map = std.StaticStringMap(u21).initComptime(&[_]struct { []const u8, u21 }{
    .{ "{", 0x7B },
    .{ "}", 0x7D },
    .{ "langle", 0x27E8 },
    .{ "rangle", 0x27E9 },
    .{ "lfloor", 0x230A },
    .{ "rfloor", 0x230B },
    .{ "lceil", 0x2308 },
    .{ "rceil", 0x2309 },
    .{ "lbrace", 0x7B },
    .{ "rbrace", 0x7D },
    .{ "vert", 0x7C },
    .{ "Vert", 0x2016 },
    .{ "|", 0x2016 }, // \|
    .{ "backslash", 0x2216 },
    .{ "\\", 0x2216 }, // \\
    .{ "/", 0x2F },
});

/// The `data` a \sqrt row node carries so layout routes it through
/// layoutSqrt (stretchy radical + vinculum) instead of the ordinary row
/// path. Ordinary parseRow rows always carry data 0, so this is unambiguous.
const sqrt_row_data: u32 = 1;

/// The `data` an accent row node carries so layout routes it through
/// layoutAccent (base + combining mark) instead of the ordinary row path.
const accent_row_data: u32 = 2;

/// Bit 21 of a \middle delimiter char leaf's `data`: the low 21 bits hold
/// the delimiter's codepoint (delimiterCp/layoutChar read only those via
/// @truncate), bit 21 marks the leaf as a \middle delimiter — layout sizes
/// it with the enclosing \left...\right pair's required ink instead of
/// rendering it at the base size. Mirrored in layout.zig (middle_marker).
const middle_marker: u32 = 1 << 21;

/// The `data` a \not row node carries (children [base]) so layout routes it
/// through layoutNot — the base relation with the U+0338 overlay slash —
/// instead of the ordinary row path. Ordinary parseRow rows always carry
/// data 0, so this is unambiguous.
const not_row_data: u32 = 3;

/// The `data` a \pmod row node carries (children ['(', roman "mod" word,
/// 6mu space, arg, ')']) so layout routes it through layoutPmod — the
/// style-dependent leading \mkern (18mu display / 8mu otherwise) plus the
/// fixed \mkern6mu mod-n gap — instead of the ordinary row path.
const pmod_row_data: u32 = 4;

/// The `data` a \pod row node carries (children ['(', arg, ')']): the
/// parenthesized argument WITHOUT the "mod" word (layoutPmod still applies
/// the leading \mkern).
const pod_row_data: u32 = 5;

/// The `data` a \bmod row node carries (children [5mu space, roman "mod"
/// word, 5mu space]) so layout routes it through layoutBmod — the pieces
/// placed back to back with the two 5mu kerns (amsmath's \bmod dance
/// \mskip-\medmuskip\mkern5mu\mathbin{mod}\penalty900\mkern5mu
/// \mskip-\medmuskip nets to 5mu on each side once the ord↔bin glue is
/// summed) — instead of the ordinary row path.
const bmod_row_data: u32 = 6;

/// The `data` a \mod row node carries (children [roman "mod" word, 6mu
/// space, arg]) so layout routes it through layoutMod — the
/// style-dependent leading \mkern (18mu display / 12mu otherwise) plus the
/// fixed \mkern6mu mod-arg gap — instead of the ordinary row path.
const mod_row_data: u32 = 7;

/// Relation codepoint → its pre-composed negated form, for \not<relation>.
/// unicode-math's \not command uses the pre-composed glyph when one exists
/// (verified against the XeTeX reference: \not\in → U+2209, \not\leq →
/// U+2270, \not= → U+2260, \not\subset → U+2284, \not\simeq → U+2244 — all
/// single glyphs), so ztex emits the same codepoint; relations without a
/// pre-composed form fall back to the U+0338 overlay row (layoutNot). Every
/// target is in LM Math's cmap (verified with fontTools), and every target
/// has a row in the layout metric table, so the emitted char resolves.
/// Sorted by `cp` for the linear scan; matches unicode-math-table.tex.
const not_cp_map = [_]struct { cp: u21, neg: u21 }{
    .{ .cp = 0x3C, .neg = 0x226E }, // < → ≮ \nless
    .{ .cp = 0x3D, .neg = 0x2260 }, // = → ≠ \neq
    .{ .cp = 0x3E, .neg = 0x226F }, // > → ≯ \ngtr
    .{ .cp = 0x2208, .neg = 0x2209 }, // ∈ → ∉ \notin
    .{ .cp = 0x220B, .neg = 0x220C }, // ∋ → ∌ \notni
    .{ .cp = 0x2223, .neg = 0x2224 }, // ∣ → ∤ \nmid
    .{ .cp = 0x2225, .neg = 0x2226 }, // ∥ → ∦ \nparallel
    .{ .cp = 0x223C, .neg = 0x2241 }, // ∼ → ≁ \nsim
    .{ .cp = 0x2243, .neg = 0x2244 }, // ≃ → ≄ \nsimeq
    .{ .cp = 0x2245, .neg = 0x2247 }, // ≅ → ≇ \ncong
    .{ .cp = 0x2248, .neg = 0x2249 }, // ≈ → ≉ \napprox
    .{ .cp = 0x224D, .neg = 0x226D }, // ≍ → ≭ \nasymp
    .{ .cp = 0x2261, .neg = 0x2262 }, // ≡ → ≢ \nequiv
    .{ .cp = 0x2264, .neg = 0x2270 }, // ≤ → ≰ \nleq
    .{ .cp = 0x2265, .neg = 0x2271 }, // ≥ → ≱ \ngeq
    .{ .cp = 0x227A, .neg = 0x2280 }, // ≺ → ⊀ \nprec
    .{ .cp = 0x227B, .neg = 0x2281 }, // ≻ → ⊁ \nsucc
    .{ .cp = 0x2282, .neg = 0x2284 }, // ⊂ → ⊄ \nsubset
    .{ .cp = 0x2283, .neg = 0x2285 }, // ⊃ → ⊅ \nsupset
    .{ .cp = 0x2286, .neg = 0x2288 }, // ⊆ → ⊈ \nsubseteq
    .{ .cp = 0x2287, .neg = 0x2289 }, // ⊇ → ⊉ \nsupseteq
    .{ .cp = 0x22A2, .neg = 0x22AC }, // ⊢ → ⊬ \nvdash
    .{ .cp = 0x2AAF, .neg = 0x22E0 }, // ⪯ → ⋠ \npreceq
    .{ .cp = 0x2AB0, .neg = 0x22E1 }, // ⪰ → ⋡ \nsucceq
};

/// Recursive-descent parser over a flat token table.
///
/// A `Parser` borrows `src` and `tokens` and allocates every node it appends
/// from `gpa`; it owns no node itself — the `atom.Ast` passed to `parse` does.
/// It holds the caller's `err_info` pointer for the duration of `parse` and
/// never retains it. One `Parser` parses one token table into one `Ast`; it
/// is not reusable for a second input, and it is not safe to share across
/// threads.
pub const Parser = struct {
    /// Allocator for every node the parser appends to the `Ast`.
    gpa: std.mem.Allocator,
    /// The formula bytes; borrowed, used to place zero-width spans at EOF.
    src: []const u8,
    /// The pre-lexed token table; borrowed for the whole parse.
    tokens: []const atom.Token,
    /// Index of the next token to consume; `tokens.len` means end of input.
    pos: usize = 0,
    /// 1 while parsing the interior of a \left ... \right pair (parseRow in
    /// .delimited mode): \middle is only valid there (TeX). parseLeftRight
    /// increments before the interior and decrements after.
    delim_depth: u32 = 0,
    /// parseRow nesting depth; the depth counter doubles as the stack
    /// guard, bounded by `max_row_depth`.
    row_depth: u32 = 0,
    /// Caller-provided parse-error context, borrowed for as long as this
    /// parser lives. `parse` fills it (when non-null) before EVERY error it
    /// returns — kind + offending span for an input failure, and
    /// `Kind.out_of_memory` with a `null` span for an allocation failure —
    /// and leaves it untouched on success. Nothing else writes it.
    err_info: ?*parse_err.Info = null,

    /// Safe to recurse one more parseRow level (zbc stack guard).
    fn isSafeToRecurse(self: *const Parser) bool {
        return self.row_depth < max_row_depth;
    }

    /// A parser over `tokens`, writing failure context into `err_info` when
    /// it is non-null. `src` and `tokens` are borrowed and must outlive the
    /// parse; `err_info` must stay writable for the whole `parse` call.
    ///
    /// The returned parser has not consumed anything; call `parse` with the
    /// `atom.Ast` its nodes go into.
    pub fn init(
        gpa: std.mem.Allocator,
        src: []const u8,
        tokens: []const atom.Token,
        err_info: ?*parse_err.Info,
    ) Parser {
        return .{ .gpa = gpa, .src = src, .tokens = tokens, .err_info = err_info };
    }

    fn atEnd(self: *const Parser) bool {
        return self.pos >= self.tokens.len;
    }

    fn peek(self: *const Parser) ?atom.Token {
        if (self.atEnd()) return null;
        return self.tokens[self.pos];
    }

    fn advance(self: *Parser) ?atom.Token {
        if (self.atEnd()) return null;
        const t = self.tokens[self.pos];
        self.pos += 1;
        return t;
    }

    /// Fill the caller's Info (when provided) with a kind + optional span.
    fn setErr(self: *Parser, kind: parse_err.Kind, span: ?atom.Span) void {
        if (self.err_info) |info| info.* = .{ .kind = kind, .span = span };
    }

    /// Record the error context and return the matching error-set value.
    /// Every positioned error-return site goes through here, so the error
    /// VALUES are unchanged (`expectError` still sees error.Xxx) and the Info
    /// is always filled before the caller's `catch` observes the failure.
    /// This switch is the whole kind→error mapping; `.dangling_escape` and
    /// `.invalid_utf8` are lexer-only and `.out_of_memory` is the caller's,
    /// so none of the three can reach here.
    fn fail(self: *Parser, kind: parse_err.Kind, span: atom.Span) Error {
        self.setErr(kind, span);
        return switch (kind) {
            .unexpected_r_group => error.UnexpectedRGroup,
            .unexpected_script => error.UnexpectedScript,
            .double_script => error.DoubleScript,
            .unknown_command => error.UnknownCommand,
            .missing_argument => error.MissingArgument,
            .missing_script => error.MissingScript,
            .unclosed_group => error.UnclosedGroup,
            .unexpected_middle => error.UnexpectedMiddle,
            .unknown_environment => error.UnknownEnvironment,
            .mismatched_end => error.MismatchedEnd,
            .unclosed_environment => error.UnclosedEnvironment,
            .depth_exceeded => error.StackOverflow,
            .out_of_memory, .dangling_escape, .invalid_utf8 => unreachable,
        };
    }

    /// Span of the token at `pos`, or a zero-width span at end of source
    /// (for "expected X but hit end of input" errors).
    fn spanAt(self: *const Parser, pos: usize) atom.Span {
        if (pos < self.tokens.len) {
            const t = self.tokens[pos];
            return .{ .start = t.start, .end = t.end };
        }
        const end: u32 = @intCast(self.src.len);
        return .{ .start = end, .end = end };
    }

    /// Span of the CURRENT token (or zero-width at EOF).
    fn curSpan(self: *const Parser) atom.Span {
        return self.spanAt(self.pos);
    }

    /// Span of a token value (from peek/advance).
    fn spanOf(t: atom.Token) atom.Span {
        return .{ .start = t.start, .end = t.end };
    }

    /// Parse the whole token table into a row atom, appending every node to
    /// `ast`, and return the root node's index.
    ///
    /// `err_info` (when non-null) is filled before EVERY error this returns:
    /// an input failure records its kind and the offending token's byte span,
    /// and `error.OutOfMemory` records `Kind.out_of_memory` with a `null`
    /// span. On success the out-param is untouched. This is the low-level
    /// route, so it makes the same guarantee `ztex.parse.parse` does: a
    /// direct caller can trust the out-param after any error without a
    /// wrapper.
    ///
    /// The `Ast` is the caller's and nothing partial is cleaned up here: on
    /// error the nodes appended before the failure stay in `ast.nodes`, and
    /// `ast.root` is left as it was. The caller decides whether to keep or
    /// `deinit` them.
    pub fn parse(self: *Parser, ast: *atom.Ast) Error!u32 {
        const root = self.parseRow(ast, .top) catch |err| switch (err) {
            error.OutOfMemory => {
                self.setErr(.out_of_memory, null);
                return error.OutOfMemory;
            },
            else => |e| return e,
        };
        if (!self.atEnd()) return self.fail(.unexpected_r_group, self.curSpan());
        return root;
    }

    const RowMode = enum {
        /// end of input
        top,
        /// `}` (not consumed)
        group,
        /// `\right` (not consumed) or `}` — the interior of \left ... \right
        delimited,
        /// `\\` (not consumed) or `}` — ONE LINE of a \substack: parseRow
        /// stops at the line separator or the closing brace, so each line
        /// becomes its own row.
        substack_line,
        /// ONE CELL of a \begin{env} body: parseRow stops at `&` (char),
        /// `\\` (command), `\end` (command), or `}` (not consumed), so the
        /// env parser can split rows on `\\` and cells on `&`.
        env_cell,
    };

    /// Parse atoms until end-of-input (.top), `}` (.group, not consumed), or
    /// `\right` (.delimited, not consumed).
    ///
    /// Infix generalized fractions: `\atop \over \choose` split the row —
    /// everything before the delimiter becomes the numerator, everything
    /// after it (to the row's end) the denominator, and the whole row is
    /// returned as a fraction node (TeX: `{a \atop b}`). A second delimiter
    /// is ambiguous (TeX: "you need another { and }") and errors.
    fn parseRow(self: *Parser, ast: *atom.Ast, mode: RowMode) Error!u32 {
        // The guard reports through `fail` like every other positioned
        // failure, so the caller's Info names this input rather than
        // whatever the previous call left there.
        if (!self.isSafeToRecurse()) return self.fail(.depth_exceeded, self.curSpan());
        self.row_depth += 1;
        defer self.row_depth -= 1;
        const start_tok: u32 = @intCast(self.pos);
        var last_tok: u32 = start_tok;
        // Collect each child's node value, then copy the whole run
        // contiguously via createNode (duplication protocol), so the row's
        // children land in one block at [first_child, first_child+count).
        var children: std.ArrayList(atom.Node) = .empty;
        defer children.deinit(self.gpa);
        // Pre-reserve from the remaining token count so dense rows do not
        // realloc while collecting children (capacity-only; the list grows
        // past this when atoms span fewer than 2 tokens).
        try children.ensureTotalCapacity(self.gpa, (self.tokens.len - self.pos) / 2 + 1);
        // Infix fraction state: set when \atop/\over/\choose splits the row.
        var frac_line: ?bool = null; // true = rule (\over), false = \atop/\choose
        var frac_choose = false;
        var frac_tok: u32 = undefined; // the delimiter command's token
        var frac_split: usize = 0; // children index where the denominator begins
        var num_end_tok: u32 = start_tok; // last numerator token (span anchor)
        while (self.peek()) |t| {
            switch (t.tag) {
                .r_group => {
                    if (mode == .top) return self.fail(.unexpected_r_group, spanOf(t));
                    break;
                },
                .sup, .sub => return self.fail(.unexpected_script, spanOf(t)),
                .command => {
                    const nm = self.src[t.start + 1 .. t.end];
                    if (mode == .delimited and std.mem.eql(u8, nm, "right")) break;
                    // \\ ends a \substack line (each line is parsed as its
                    // own row in .substack_line mode). Elsewhere \\ stays
                    // an UnknownCommand error, exactly as before.
                    if (mode == .substack_line and std.mem.eql(u8, nm, "\\")) break;
                    // `\end` and `\\` end an environment cell (the env body
                    // parser splits rows on `\\` and expects `\end` to
                    // close the environment; neither is consumed here).
                    if (mode == .env_cell and std.mem.eql(u8, nm, "\\")) break;
                    if (mode == .env_cell and std.mem.eql(u8, nm, "end")) break;
                    // A style switch forces the style for the REST of the
                    // row (TeX rest-of-group semantics): consume the
                    // command, parse the remaining atoms as a sub-row, wrap
                    // that row in a `.mathstyle` node, and stop the loop —
                    // the rest is inside the wrapper. `\displaystyle a \over
                    // b` correctly wraps the whole infix fraction.
                    if (mathstyle_map.get(nm)) |ms| {
                        const cmd_tok: u32 = @intCast(self.pos);
                        _ = self.advance();
                        const rest = try self.parseRow(ast, mode);
                        const rn = ast.node(rest);
                        const num_tokens = (rn.first_token + rn.num_tokens) - cmd_tok;
                        const children_one = [_]atom.Node{rn};
                        const node = try ast.createNode(
                            .mathstyle,

                            cmd_tok,

                            num_tokens,

                            &children_one,

                            @intFromEnum(ms),
                        );
                        const cn = ast.node(node);
                        try children.append(self.gpa, cn);
                        last_tok = cn.first_token + cn.num_tokens;
                        break; // the rest of the row is consumed
                    }
                    if (std.mem.eql(u8, nm, "atop") or
                        std.mem.eql(u8, nm, "over") or
                        std.mem.eql(u8, nm, "choose"))
                    {
                        if (frac_line != null) return self.fail(.missing_argument, spanOf(t));
                        frac_tok = @intCast(self.pos);
                        _ = self.advance(); // consume the delimiter command
                        frac_line = std.mem.eql(u8, nm, "over");
                        frac_choose = std.mem.eql(u8, nm, "choose");
                        frac_split = children.items.len;
                        num_end_tok = last_tok;
                        continue;
                    }
                    const child = try self.parseAtom(ast);
                    const cn = ast.node(child);
                    try children.append(self.gpa, cn);
                    last_tok = cn.first_token + cn.num_tokens;
                },
                else => {
                    // `&` ends an environment cell (column separator; the
                    // env body parser consumes it and starts the next
                    // cell). Outside an environment `&` is an ordinary
                    // char atom.
                    if (mode == .env_cell and t.tag == .char and self.src[t.start] == '&') break;
                    const child = try self.parseAtom(ast);
                    const cn = ast.node(child);
                    try children.append(self.gpa, cn);
                    last_tok = cn.first_token + cn.num_tokens;
                },
            }
        }
        const num_tokens = last_tok - start_tok;
        if (frac_line) |line| {
            const num = try ast.createNode(.row, start_tok, num_end_tok - start_tok, children.items[0..frac_split], 0);
            const den = try ast.createNode(.row, num_end_tok, last_tok - num_end_tok, children.items[frac_split..], 0);
            const nn = ast.node(num);
            const dn = ast.node(den);
            const frac_children = [_]atom.Node{ nn, dn };
            const frac = try ast.createNode(.fraction, start_tok, num_tokens, &frac_children, @intFromBool(line));
            const result: u32 = if (!frac_choose) frac else blk: {
                // \choose = \atop wrapped in parentheses
                const open = try ast.createLeaf(.char, frac_tok, 1, 0x28);
                const close = try ast.createLeaf(.char, frac_tok, 1, 0x29);
                const fn_ = ast.node(frac);
                const choose_children = [_]atom.Node{ ast.node(open), fn_, ast.node(close) };
                break :blk try ast.createNode(.row, start_tok, num_tokens, &choose_children, 0);
            };
            // Inside a group the whole content IS the fraction (`{a \atop b}`);
            // at top level the root stays a row per ztex's root convention.
            if (mode != .top) return result;
            const rn = ast.node(result);
            const wrap = [_]atom.Node{rn};
            return ast.createNode(.row, start_tok, num_tokens, &wrap, 0);
        }
        return ast.createNode(.row, start_tok, num_tokens, children.items, 0);
    }

    /// Parse one atom (base + optional scripts + trailing primes).
    ///
    /// `'` after an atom is TeX's prime (mathcode 0x8000): a superscript
    /// U+2032. Consecutive primes accumulate into one superscript: `''` →
    /// U+2033 (double prime), `'''`+ → U+2034. The wrap happens AFTER
    /// parseScripts so `x_1'` keeps its subscript and gains the prime
    /// superscript (TeX: a noad carries both), while `x'^2` still errors
    /// (DoubleScript — TeX's "Double superscript") because the `^2` is left
    /// as a row-leading script.
    ///
    /// A trailing prime on an ALREADY-SCRIPTED atom merges into the SAME
    /// script node (TeX: `f_2'` is one noad with sub 2 AND sup ′, so the
    /// prime raises by the char-nucleus sup1 floor, not by the script
    /// box's height − supdrop). A script that already has a superscript
    /// (`x^2'`, `x_2^3'`) errors — TeX's "Double superscript". The
    /// merge rewrites the script node with children [base, prime, sub]
    /// (superflat contiguity: the new node is a fresh pool entry).
    fn parseAtom(self: *Parser, ast: *atom.Ast) Error!u32 {
        const base = try self.parseSingleAtom(ast);
        const result = try self.parseScripts(ast, base);
        var prime_count: usize = 0;
        const first_prime_tok: u32 = @intCast(self.pos);
        while (self.peek()) |t| {
            if (t.tag != .char) break;
            if (self.src[t.start] != '\'') break;
            prime_count += 1;
            _ = self.advance();
        }
        if (prime_count == 0) return result;
        const cp: u21 = if (prime_count == 1) 0x2032 else if (prime_count == 2) 0x2033 else 0x2034;
        const prime = try ast.createLeaf(.char, first_prime_tok, @intCast(prime_count), cp);
        const rn = ast.node(result);
        const pn = ast.node(prime);
        if (rn.tag == .script) {
            // Merge into the existing script: [base, sup?, sub?] — a prime
            // fills the sup slot. A sup already present is TeX's double
            // superscript.
            if ((rn.data & atom.ScriptBits.sup) != 0)
                return self.fail(.double_script, self.curSpan());
            const sb = ast.child(result, 0);
            const sub = ast.child(result, rn.num_children - 1);
            const children = [_]atom.Node{ ast.node(sb), pn, ast.node(sub) };
            const num_tokens = (first_prime_tok + @as(u32, @intCast(prime_count))) -
                ast.node(sb).first_token;
            return ast.createNode(
                .script,
                ast.node(sb).first_token,
                num_tokens,
                &children,
                atom.ScriptBits.sup | atom.ScriptBits.sub,
            );
        }
        const children = [_]atom.Node{ rn, pn };
        const num_tokens = (first_prime_tok + @as(u32, @intCast(prime_count))) - rn.first_token;
        return ast.createNode(.script, rn.first_token, num_tokens, &children, atom.ScriptBits.sup);
    }

    /// Parse exactly one base atom (no scripts).
    fn parseSingleAtom(self: *Parser, ast: *atom.Ast) Error!u32 {
        const t = self.advance() orelse return self.fail(.missing_script, self.spanAt(self.pos));
        return switch (t.tag) {
            .char => self.makeChar(ast),
            .l_group => self.parseGroup(ast),
            .command => blk: {
                const name = self.src[t.start + 1 .. t.end];
                break :blk self.parseCommand(ast, name);
            },
            .r_group => self.fail(.unexpected_r_group, spanOf(t)),
            .sup, .sub => self.fail(.unexpected_script, spanOf(t)),
        };
    }

    /// Parse `{ ... }` as a transparent group atom.
    fn parseGroup(self: *Parser, ast: *atom.Ast) Error!u32 {
        const open_tok: u32 = @intCast(self.pos - 1);
        const inner = try self.parseRow(ast, .group);
        // Unclosed group: point at the group's opening brace.
        _ = self.advance() orelse
            return self.fail(.unclosed_group, self.spanAt(open_tok)); // consume }
        const inode = ast.node(inner);
        const num_tokens = (inode.first_token + inode.num_tokens) - open_tok + 1;
        const children = [_]atom.Node{ast.node(inner)};
        return ast.createNode(.group, open_tok, num_tokens, &children, 0);
    }

    /// Attach `^`/`_` scripts to `base`.
    ///
    /// `data` carries presence bits (ScriptBits.sup/sub) so layout does not
    /// misread a sub-only script (children are [base, sup?, sub?]).
    fn parseScripts(self: *Parser, ast: *atom.Ast, base: u32) Error!u32 {
        var sup: ?u32 = null;
        var sub: ?u32 = null;
        const base_node = ast.node(base);
        var last_tok = base_node.first_token + base_node.num_tokens;
        while (self.peek()) |t| {
            // \limits / \nolimits / \displaylimits between a base and its
            // scripts (`\int\limits_0^1`) set the limits-override bits on
            // the PRECEDING op/opname atom: \limits forces over/under in
            // display AND text styles, \nolimits forces beside scripts in
            // every style, \displaylimits restores the op's default. The
            // bits ride in the base node's `data` high bits (atom.LimitsBits)
            // and are copied with the base into any script node; the layout
            // consults them. On a non-op base TeX errors ("Limit controls
            // must follow a math operator"); ztex consumes it as a no-op.
            if (t.tag == .command) {
                const nm = self.src[t.start + 1 .. t.end];
                if (std.mem.eql(u8, nm, "limits") or
                    std.mem.eql(u8, nm, "nolimits") or
                    std.mem.eql(u8, nm, "displaylimits"))
                {
                    _ = self.advance();
                    const bt = ast.node(base).tag;
                    if (bt == .op or bt == .opname) {
                        const bits: u32 = if (std.mem.eql(u8, nm, "limits"))
                            atom.LimitsBits.force
                        else if (std.mem.eql(u8, nm, "nolimits"))
                            atom.LimitsBits.force_beside
                        else
                            0;
                        ast.nodes.items[base].data =
                            (ast.nodes.items[base].data & ~atom.LimitsBits.mask) | bits;
                    }
                    continue;
                }
            }
            if (t.tag == .sup) {
                if (sup != null) return self.fail(.double_script, spanOf(t));
                _ = self.advance();
                sup = try self.parseScriptArg(ast);
                last_tok = endOf(ast, sup.?);
            } else if (t.tag == .sub) {
                if (sub != null) return self.fail(.double_script, spanOf(t));
                _ = self.advance();
                sub = try self.parseScriptArg(ast);
                last_tok = endOf(ast, sub.?);
            } else break;
        }
        if (sup == null and sub == null) return base;
        var children: std.ArrayList(atom.Node) = .empty;
        defer children.deinit(self.gpa);
        try children.append(self.gpa, ast.node(base));
        if (sup) |s| try children.append(self.gpa, ast.node(s));
        if (sub) |s| try children.append(self.gpa, ast.node(s));
        const num_tokens = last_tok - base_node.first_token;
        const data = (@as(u32, @intFromBool(sup != null)) * atom.ScriptBits.sup) |
            (@as(u32, @intFromBool(sub != null)) * atom.ScriptBits.sub);
        return ast.createNode(.script, base_node.first_token, num_tokens, children.items, data);
    }

    /// The content of one script: a single atom, or a braced group.
    fn parseScriptArg(self: *Parser, ast: *atom.Ast) Error!u32 {
        // Missing script: point at the position where the field was expected.
        const t = self.peek() orelse return self.fail(.missing_script, self.spanAt(self.pos));
        if (t.tag == .l_group) {
            _ = self.advance(); // consume `{` before parseGroup
            return self.parseGroup(ast);
        }
        // An UNBRACED script field may open with a style switch
        // (`x^{\displaystyle 2}`... without braces: `x^\displaystyle 2`):
        // the field is its own implicit group, so the switch forces the
        // style for the field's single atom (TeX: the field ends after one
        // atom — the rest of the outer row is unaffected).
        if (t.tag == .command) {
            if (mathstyle_map.get(self.src[t.start + 1 .. t.end])) |ms| {
                const cmd_tok: u32 = @intCast(self.pos);
                _ = self.advance();
                const rest = try self.parseSingleAtom(ast);
                const rn = ast.node(rest);
                const num_tokens = (rn.first_token + rn.num_tokens) - cmd_tok;
                const children = [_]atom.Node{ast.node(rest)};
                return ast.createNode(.mathstyle, cmd_tok, num_tokens, &children, @intFromEnum(ms));
            }
        }
        return self.parseSingleAtom(ast);
    }

    /// A required braced argument; returns the inner atom.
    fn parseRequiredArg(self: *Parser, ast: *atom.Ast) Error!u32 {
        const open_tok: u32 = @intCast(self.pos);
        const t = self.peek() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        if (t.tag != .l_group) return self.fail(.missing_argument, spanOf(t));
        _ = self.advance();
        const inner = try self.parseRow(ast, .group);
        // Unclosed group: point at the argument's opening brace.
        _ = self.advance() orelse return self.fail(.unclosed_group, self.spanAt(open_tok));
        return inner;
    }

    fn endOf(ast: *atom.Ast, node_idx: u32) u32 {
        const n = ast.node(node_idx);
        return n.first_token + n.num_tokens;
    }

    fn parseCommand(self: *Parser, ast: *atom.Ast, name: []const u8) Error!u32 {
        const cmd_tok: u32 = @intCast(self.pos - 1);
        const cmd = cmd_map.get(name) orelse {
            // Single-glyph symbols (\alpha, \leq, \infty, ...): a char leaf
            // whose data carries the codepoint, exactly like \cdot.
            if (symbol_map.get(name)) |cp| return self.symbol(ast, cmd_tok, cp);
            return self.fail(.unknown_command, self.spanAt(cmd_tok));
        };
        return switch (cmd) {
            .space_comma => self.space(ast, cmd_tok, 0.166),
            .space_semicolon => self.space(ast, cmd_tok, 0.277),
            .space_bang => self.space(ast, cmd_tok, -0.166),
            .quad => self.space(ast, cmd_tok, 1.0),
            .qquad => self.space(ast, cmd_tok, 2.0),
            .frac => blk: {
                const num = try self.parseRequiredArg(ast);
                const den = try self.parseRequiredArg(ast);
                break :blk self.fraction(ast, cmd_tok, num, den, true, null, false);
            },
            .frac_display => blk: {
                const num = try self.parseRequiredArg(ast);
                const den = try self.parseRequiredArg(ast);
                break :blk self.fraction(ast, cmd_tok, num, den, true, .display, false);
            },
            .frac_text => blk: {
                const num = try self.parseRequiredArg(ast);
                const den = try self.parseRequiredArg(ast);
                break :blk self.fraction(ast, cmd_tok, num, den, true, .text, false);
            },
            .cfrac => blk: {
                const num = try self.parseRequiredArg(ast);
                const den = try self.parseRequiredArg(ast);
                break :blk self.fraction(ast, cmd_tok, num, den, true, .display, true);
            },
            .atop => blk: {
                const num = try self.parseRequiredArg(ast);
                const den = try self.parseRequiredArg(ast);
                break :blk self.fraction(ast, cmd_tok, num, den, false, null, false);
            },
            .binom => blk: {
                const num = try self.parseRequiredArg(ast);
                const den = try self.parseRequiredArg(ast);
                break :blk self.binom(ast, cmd_tok, num, den);
            },
            .genfrac => blk: {
                const ld = try self.parseGenfracDelim();
                const rd = try self.parseGenfracDelim();
                const thick = try self.parseGenfracThickness();
                const gstyle = try self.parseGenfracStyle();
                const num = try self.parseRequiredArg(ast);
                const den = try self.parseRequiredArg(ast);
                break :blk self.genfrac(ast, cmd_tok, ld, rd, thick, gstyle, num, den);
            },
            .text => self.text(ast, cmd_tok),
            .operatorname => self.operatorname(ast, cmd_tok),
            .style_roman => self.style(ast, cmd_tok, .roman),
            .style_bold => self.style(ast, cmd_tok, .bold),
            .style_bb => self.style(ast, cmd_tok, .bb),
            .style_cal => self.style(ast, cmd_tok, .cal),
            .style_frak => self.style(ast, cmd_tok, .frak),
            .style_sans => self.style(ast, cmd_tok, .sans),
            .style_mono => self.style(ast, cmd_tok, .mono),
            .cdot => self.cdot(ast, cmd_tok),
            .op_sum => self.op(ast, cmd_tok, .sum),
            .op_int => self.op(ast, cmd_tok, .int),
            .op_prod => self.op(ast, cmd_tok, .prod),
            .op_coprod => self.op(ast, cmd_tok, .coprod),
            .op_bigcup => self.op(ast, cmd_tok, .bigcup),
            .op_bigcap => self.op(ast, cmd_tok, .bigcap),
            .op_bigsqcup => self.op(ast, cmd_tok, .bigsqcup),
            .op_oint => self.op(ast, cmd_tok, .oint),
            .opname => self.opname(ast, cmd_tok, name),
            .left => self.parseLeftRight(ast, cmd_tok),
            .right => self.fail(.unexpected_r_group, self.spanAt(cmd_tok)),
            .big => self.fixedDelim(ast, cmd_tok, 1),
            .Big => self.fixedDelim(ast, cmd_tok, 2),
            .bigg => self.fixedDelim(ast, cmd_tok, 3),
            .Bigg => self.fixedDelim(ast, cmd_tok, 4),
            .middle => self.middle(ast, cmd_tok),
            .limits => self.space(ast, cmd_tok, 0),
            .nolimits => self.space(ast, cmd_tok, 0),
            .displaylimits => self.space(ast, cmd_tok, 0),
            .sqrt => self.sqrt(ast, cmd_tok),
            .dot => self.accent(ast, cmd_tok, 0x0307), // combining dot above
            .hat => self.accent(ast, cmd_tok, 0x0302), // combining circumflex
            .bar => self.accent(ast, cmd_tok, 0x0304), // combining macron
            .vec => self.accent(ast, cmd_tok, 0x20D7), // combining right arrow above
            .ddot => self.accent(ast, cmd_tok, 0x0308), // combining diaeresis
            .tilde => self.accent(ast, cmd_tok, 0x0303), // combining tilde
            .overline => self.overunder(ast, cmd_tok, false),
            .underline => self.overunder(ast, cmd_tok, true),
            .mathchoice => self.mathchoice(ast, cmd_tok),
            .not => self.not(ast, cmd_tok),
            .substack => self.substack(ast, cmd_tok),
            .pmod => self.pmod(ast, cmd_tok, true),
            .pod => self.pmod(ast, cmd_tok, false),
            .bmod => self.bmod(ast, cmd_tok),
            .mod => self.mod(ast, cmd_tok),
            .begin => self.parseBegin(ast, cmd_tok),
        };
    }

    fn makeChar(self: *Parser, ast: *atom.Ast) Error!u32 {
        const tok: u32 = @intCast(self.pos - 1);
        return ast.createLeaf(.char, tok, 1, 0);
    }
    /// \cdot → a char atom at U+22C5. The source span holds "\cdot", so the
    /// codepoint override rides in the node's `data` (nonzero = explicit cp);
    /// layout reads it for the glyph, the role, and marks the box synthetic.
    fn cdot(_: *Parser, ast: *atom.Ast, cmd_tok: u32) Error!u32 {
        return ast.createLeaf(.char, cmd_tok, 1, 0x22C5);
    }
    /// A single-glyph command (\alpha, \leq, \infty, \to, ...): a char leaf
    /// with the codepoint override in `data`, like \cdot.
    fn symbol(_: *Parser, ast: *atom.Ast, cmd_tok: u32, cp: u21) Error!u32 {
        return ast.createLeaf(.char, cmd_tok, 1, cp);
    }
    /// An operator name (\sin, \lim, \log, ...): the name's letters become
    /// char leaves (each carrying its ASCII codepoint in `data`) grouped in a
    /// row wrapped by an `.opname` node (roman word). Scripts then attach to
    /// the opname node (`\sin^2 x`, `\lim_{x \to 0}`), and layout routes the
    /// LIMIT-TAKING words (\lim \max \min ... — see `limitOpName`) through the
    /// big-op limits path in display style, so `\lim_{x \to 0}` puts "x→0"
    /// UNDER the word, centered, exactly like `\sum` limits. All leaves share
    /// the command token's span, so provenance stays exact and the synthetic
    /// flag keeps flatten from aliasing the "\sin" source text.
    fn opname(self: *Parser, ast: *atom.Ast, cmd_tok: u32, name: []const u8) Error!u32 {
        var letters: std.ArrayList(atom.Node) = .empty;
        defer letters.deinit(self.gpa);
        for (name) |b| {
            const c = try ast.createLeaf(.char, cmd_tok, 1, b);
            try letters.append(self.gpa, ast.node(c));
        }
        const word = try ast.createNode(.row, cmd_tok, 1, letters.items, 0);
        const wn = ast.node(word);
        const child = [_]atom.Node{wn};
        const limits = @intFromBool(limitOpName(name));
        return ast.createNode(.opname, cmd_tok, 1, &child, limits);
    }
    /// Whether an operator name takes display-style limits in TeX. TeX's
    /// fontmath.ltx defines only these as \mathop with limits by default
    /// (display style: scripts over/under, centered); the trig/log words
    /// (\sin \cos \tan \log \ln \exp ...) are \mathop\nolimits — their
    /// scripts stay beside as regular sub/superscripts (\sin^2 x), and
    /// \mod/\bmod are not ops at all.
    fn limitOpName(name: []const u8) bool {
        const limit_names = std.StaticStringMap(void).initComptime(&[_]struct { []const u8, void }{
            .{ "lim", {} },
            .{ "limsup", {} },
            .{ "liminf", {} },
            .{ "max", {} },
            .{ "min", {} },
            .{ "sup", {} },
            .{ "inf", {} },
            .{ "det", {} },
            .{ "gcd", {} },
            .{ "Pr", {} },
            .{ "arg", {} },
            .{ "ker", {} },
            .{ "dim", {} },
            .{ "hom", {} },
            .{ "deg", {} },
        });
        return limit_names.has(name);
    }
    /// \operatorname{...} / \operatorname*{...}: amsmath's declarable
    /// operator name — a \mathop whose content is the braced group set in
    /// upright roman (amsopn.sty: \qopname → \mathop{\operator@font #3}
    /// followed by \nolimits@ for the unstarred form, \displaylimits for
    /// the starred). The result is an `.opname` atom whose child row is the
    /// parsed braced content (laid out roman by the layout, OP role — thin
    /// glue to ord/op/inner, none to open — plus the limits machinery):
    /// `data` 0 = nolimits (scripts attach beside the word, like \sin^2),
    /// `data` 1 = displaylimits (over/under limits centered on the word in
    /// display style, like \lim; beside in text style). The `*` is a LaTeX
    /// macro suffix — the lexer emits it as a separate `*` char token
    /// (whitespace between name and `*` is skipped, so `\operatorname *` is
    /// the starred form exactly like TeX's \@ifstar); it is consumed here
    /// and never rendered. The content parses as a normal math row, so `\,
    /// \mathrm{...}` etc. work inside and literal whitespace follows math
    /// mode (ignored — measured: XeTeX and KaTeX both drop it; amsopn sets
    /// mathcodes so only `'` `*` `.` `/` `:` become ordinary chars).
    fn operatorname(self: *Parser, ast: *atom.Ast, cmd_tok: u32) Error!u32 {
        var limits: u32 = 0;
        if (self.peek()) |t| {
            if (t.tag == .char and self.src[t.start] == '*') {
                limits = 1;
                _ = self.advance(); // consume the star suffix
            }
        }
        const inner = try self.parseRequiredArg(ast);
        const inode = ast.node(inner);
        // The span covers the command (and the `*`, if any) through the end
        // of the braced content — provenance stays exact.
        const num_tokens = (inode.first_token + inode.num_tokens) - cmd_tok;
        const children = [_]atom.Node{ast.node(inner)};
        return ast.createNode(.opname, cmd_tok, num_tokens, &children, limits);
    }

    fn space(_: *Parser, ast: *atom.Ast, cmd_tok: u32, em: f32) Error!u32 {
        return ast.createLeaf(.space, cmd_tok, 1, atom.emToFixed(em));
    }

    fn op(_: *Parser, ast: *atom.Ast, cmd_tok: u32, which: atom.BigOp) Error!u32 {
        return ast.createLeaf(.op, cmd_tok, 1, @intFromEnum(which));
    }

    fn style(self: *Parser, ast: *atom.Ast, cmd_tok: u32, s: atom.CharStyle) Error!u32 {
        const inner = try self.parseRequiredArg(ast);
        const inode = ast.node(inner);
        const num_tokens = (inode.first_token + inode.num_tokens) - cmd_tok;
        const children = [_]atom.Node{ast.node(inner)};
        return ast.createNode(.styled, cmd_tok, num_tokens, &children, @intFromEnum(s));
    }

    /// `\frac` (line, no force), `\dfrac`/`\tfrac` (line + forced style), or
    /// `\cfrac` (line + forced display + parts-at-display). The `data` packs
    /// line bit + forced-style code + parts flag via atom.fracData; a plain
    /// `\frac` keeps data 0/1 (byte-identical to the pre-feature encoding).
    fn fraction(
        _: *Parser,
        ast: *atom.Ast,
        cmd_tok: u32,
        num: u32,
        den: u32,
        line: bool,
        forced: ?atom.MathStyle,
        parts_display: bool,
    ) Error!u32 {
        const nn = ast.node(num);
        const dn = ast.node(den);
        const num_tokens = (dn.first_token + dn.num_tokens) - cmd_tok;
        const children = [_]atom.Node{ nn, dn };
        return ast.createNode(.fraction, cmd_tok, num_tokens, &children, atom.fracData(line, forced, parts_display));
    }

    /// \binom{num}{den} = \genfrac{(}{)}{0pt}{}{num}{den}: a ruleless
    /// fraction (\atop gaps, no rule) inside \left( \right) parens that the
    /// variant ladder auto-sizes to cover the fraction — a `.left` node of
    /// [open '(', fraction, close ')'], exactly the parseLeftRight shape
    /// (data 0), so layout stretches the parens and the whole construct sits
    /// on the fraction's baseline (TeX: \binom is a delimiter-wrapped atop,
    /// NOT centered on the axis like \frac). The style is NOT forced: both
    /// references leave \binom's style empty (XeTeX amsmath \genfrac with an
    /// empty style arg relaxes to the current style; KaTeX \binom size
    /// "auto") — at 36pt display the parts render at display size, measured
    /// against the XeTeX reference. The paren leaves are synthetic (the
    /// source holds \binom, not parentheses), like \choose's.
    fn binom(self: *Parser, ast: *atom.Ast, cmd_tok: u32, num: u32, den: u32) Error!u32 {
        const frac = try self.fraction(ast, cmd_tok, num, den, false, null, false);
        const fn_ = ast.node(frac);
        const open = try ast.createLeaf(.char, cmd_tok, 1, 0x28);
        const close = try ast.createLeaf(.char, cmd_tok, 1, 0x29);
        const children = [_]atom.Node{ ast.node(open), fn_, ast.node(close) };
        const num_tokens = (ast.node(den).first_token + ast.node(den).num_tokens) - cmd_tok;
        return ast.createNode(.left, cmd_tok, num_tokens, &children, 0);
    }

    /// \genfrac{left}{right}{thick}{style}{num}{den}: a fraction with
    /// explicit delimiters (empty groups contribute none — `\genfrac{}{}
    /// {0pt}{}{a}{b}` == \atop), an explicit rule thickness (0pt → no rule,
    /// \atop-style; > 0pt → a rule of EXACTLY that thickness, a TeX
    /// dimension that does NOT scale with the font size), and a forced style
    /// (the 4th arg). With at least one delimiter the result is a `.left`
    /// node like \binom/\left..\right, so the delimiters auto-size to the
    /// fraction and the construct sits on the fraction's baseline; with no
    /// delimiters it is a bare `.fraction`.
    ///
    /// Style mapping follows BOTH references (XeTeX amsmath \@mathstyle and
    /// KaTeX stylArray — verified empirically at 36pt): "" → current style
    /// (no force), "0" → \displaystyle, "1" → \textstyle, "2" →
    /// \scriptstyle, anything else → \scriptscriptstyle. (The spec draft's
    /// "(0=text, 1=display)" is inverted vs amsmath/KaTeX; the references
    /// win — \genfrac{(}{)}{0.8pt}{1}{x}{y} renders script-size parts at
    /// display, measured in XeTeX.)
    fn genfrac(
        self: *Parser,
        ast: *atom.Ast,
        cmd_tok: u32,
        ld: ?Delimiter,
        rd: ?Delimiter,
        thick_pt: f32,
        forced: ?atom.MathStyle,
        num: u32,
        den: u32,
    ) Error!u32 {
        const line = thick_pt > 0;
        var data = atom.fracData(line, forced, false);
        if (line) data |= atom.fracThicknessBits(thick_pt);
        const nn = ast.node(num);
        const dn = ast.node(den);
        const num_tokens = (dn.first_token + dn.num_tokens) - cmd_tok;
        const children = [_]atom.Node{ nn, dn };
        const frac = try ast.createNode(.fraction, cmd_tok, num_tokens, &children, data);
        if (ld == null and rd == null) return frac;
        const fn_ = ast.node(frac);
        var fence_children: std.ArrayList(atom.Node) = .empty;
        defer fence_children.deinit(self.gpa);
        if (ld) |d| {
            const c = try ast.createLeaf(.char, d.tok, 1, d.cp);
            try fence_children.append(self.gpa, ast.node(c));
        }
        try fence_children.append(self.gpa, fn_);
        if (rd) |d| {
            const c = try ast.createLeaf(.char, d.tok, 1, d.cp);
            try fence_children.append(self.gpa, ast.node(c));
        }
        return ast.createNode(.left, cmd_tok, num_tokens, fence_children.items, 0);
    }

    /// One \genfrac delimiter argument: a braced group holding either
    /// nothing, one delimiter char, or one delimiter command (`\lbrace`).
    /// Reuses the \left/\right delimiter set (parseDelimiter); an empty
    /// group yields null (no delimiter). `\genfrac{...}{.}...` — a `.` —
    /// also yields null, like `\left.`.
    fn parseGenfracDelim(self: *Parser) Error!?Delimiter {
        const t = self.peek() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        if (t.tag != .l_group) return self.fail(.missing_argument, spanOf(t));
        _ = self.advance(); // consume {
        const n = self.peek() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        if (n.tag == .r_group) {
            _ = self.advance(); // consume }
            return null;
        }
        const d = try self.parseDelimiter();
        const c = self.peek() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        if (c.tag != .r_group) return self.fail(.missing_argument, spanOf(c));
        _ = self.advance(); // consume }
        return d;
    }

    /// A \genfrac rule-thickness argument: a braced TeX dimension like
    /// `0pt`, `1pt`, `0.8pt` (or empty → 0). The lexer splits it into char
    /// tokens, so the bytes are re-read from the token spans. Only `pt`
    /// units are accepted (a bare number means pt); negative thicknesses
    /// clamp to 0 (no rule).
    fn parseGenfracThickness(self: *Parser) Error!f32 {
        const t = self.peek() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        if (t.tag != .l_group) return self.fail(.missing_argument, spanOf(t));
        const open_tok: u32 = @intCast(self.pos);
        _ = self.advance(); // consume {
        const start: u32 = @intCast(self.pos);
        while (self.peek()) |c| {
            if (c.tag == .r_group) break;
            _ = self.advance();
        }
        const c = self.peek() orelse return self.fail(.unclosed_group, self.spanAt(open_tok));
        if (c.tag != .r_group) return self.fail(.unclosed_group, self.spanAt(open_tok));
        const end: u32 = @intCast(self.pos);
        _ = self.advance(); // consume }
        if (end <= start) return 0;
        const first = self.tokens[start].start;
        const last = self.tokens[end - 1].end;
        var txt = self.src[first..last];
        if (txt.len >= 2 and std.mem.eql(u8, txt[txt.len - 2 ..], "pt")) txt = txt[0 .. txt.len - 2];
        if (txt.len == 0) return 0;
        // The span covers the unparseable dimension text.
        const bad: atom.Span = .{ .start = first, .end = last };
        const v = std.fmt.parseFloat(f32, txt) catch return self.fail(.missing_argument, bad);
        return @max(v, 0);
    }

    /// A \genfrac style argument: a braced digit (or empty → no force).
    /// Mapping (see genfrac): 0 → display, 1 → text, 2 → script, anything
    /// else → scriptscript (amsmath's \ifcase fall-through).
    fn parseGenfracStyle(self: *Parser) Error!?atom.MathStyle {
        const t = self.peek() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        if (t.tag != .l_group) return self.fail(.missing_argument, spanOf(t));
        _ = self.advance(); // consume {
        const n = self.peek() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        if (n.tag == .r_group) {
            _ = self.advance(); // consume }
            return null;
        }
        if (n.tag != .char) return self.fail(.missing_argument, spanOf(n));
        const ch = self.src[n.start];
        _ = self.advance();
        const c = self.peek() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        if (c.tag != .r_group) return self.fail(.missing_argument, spanOf(c));
        _ = self.advance(); // consume }
        return switch (ch) {
            '0' => .display,
            '1' => .text,
            '2' => .script,
            else => .script_script,
        };
    }

    /// `\mathchoice{D}{T}{S}{SS}` — TeX's four-style choice primitive: four
    /// required braced arguments (the display/text/script/scriptscript
    /// branches). The result is a `.mathchoice` atom whose children are the
    /// four branches in order; layout picks the branch matching the current
    /// math style and lays it out with the branch's own style forced. The
    /// span covers the command through the last branch's closing brace.
    fn mathchoice(self: *Parser, ast: *atom.Ast, cmd_tok: u32) Error!u32 {
        const d = try self.parseRequiredArg(ast);
        const t = try self.parseRequiredArg(ast);
        const s = try self.parseRequiredArg(ast);
        const ss = try self.parseRequiredArg(ast);
        const dn = ast.node(d);
        const tn = ast.node(t);
        const sn = ast.node(s);
        const ssn = ast.node(ss);
        const num_tokens = (ssn.first_token + ssn.num_tokens) - cmd_tok;
        const children = [_]atom.Node{ dn, tn, sn, ssn };
        return ast.createNode(.mathchoice, cmd_tok, num_tokens, &children, 0);
    }

    fn text(self: *Parser, ast: *atom.Ast, _: u32) Error!u32 {
        const open = self.advance() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        if (open.tag != .l_group) return self.fail(.missing_argument, spanOf(open));
        const open_tok: u32 = @intCast(self.pos - 1);
        var depth: u32 = 1;
        var close_tok: u32 = undefined;
        while (depth > 0) {
            // Unclosed \text group: point at its opening brace.
            const t = self.advance() orelse return self.fail(.unclosed_group, self.spanAt(open_tok));
            if (t.tag == .l_group) {
                depth += 1;
            } else if (t.tag == .r_group) {
                depth -= 1;
                if (depth == 0) close_tok = @intCast(self.pos - 1);
            }
        }
        const num_tokens = close_tok - open_tok + 1;
        return ast.createLeaf(.text, open_tok, num_tokens, @intFromEnum(atom.CharStyle.roman));
    }

    /// \sqrt[degree]{radicand} → a row of the surd (U+221A, with the optional
    /// degree as a superscript) followed by the radicand, marked with
    /// `sqrt_row_data` in the row's `data` so layout routes it through
    /// layoutSqrt (stretchy radical + vinculum) instead of the ordinary row
    /// path (which would draw the surd as a plain base-size glyph).
    fn sqrt(self: *Parser, ast: *atom.Ast, cmd_tok: u32) Error!u32 {
        var degree: ?u32 = null;
        if (self.peek()) |t| {
            if (t.tag == .char and self.src[t.start] == '[') {
                _ = self.advance(); // consume `[`
                degree = try self.parseUntilRBracket(ast);
                const close = self.advance() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
                if (close.tag != .char or self.src[close.start] != ']')
                    return self.fail(.missing_argument, spanOf(close));
            }
        }
        const radicand = try self.parseRequiredArg(ast);
        const surd = try ast.createLeaf(.char, cmd_tok, 1, 0x221A);
        var children: std.ArrayList(atom.Node) = .empty;
        defer children.deinit(self.gpa);
        if (degree) |d| {
            const dn = ast.node(d);
            const sn = ast.node(surd);
            const deg_span = (dn.first_token + dn.num_tokens) - sn.first_token;
            const sc = try ast.createNode(.script, sn.first_token, deg_span, &.{ sn, dn }, atom.ScriptBits.sup);
            try children.append(self.gpa, ast.node(sc));
        } else {
            try children.append(self.gpa, ast.node(surd));
        }
        const rn = ast.node(radicand);
        try children.append(self.gpa, rn);
        const num_tokens = (rn.first_token + rn.num_tokens) - cmd_tok;
        // data = sqrt_row_data marks this row as a \sqrt construct; layout
        // routes it through layoutSqrt (stretchy radical + vinculum).
        return ast.createNode(.row, cmd_tok, num_tokens, children.items, sqrt_row_data);
    }

    /// \dot{q} \hat x \vec{v} ...: the accent applies to ONE following atom
    /// or braced group. The result is an accent row (data =
    /// accent_row_data) of [base, mark]: the base atom and a char leaf
    /// carrying the combining-mark codepoint in `data` (like \cdot), so
    /// layout resolves the glyph and marks the box synthetic. Scripts after
    /// the accent (`\dot q^2`) attach to the whole accent row via the usual
    /// parseAtom path — exactly TeX's mathaccent behavior.
    fn accent(self: *Parser, ast: *atom.Ast, cmd_tok: u32, cp: u21) Error!u32 {
        const base = try self.parseScriptArg(ast); // single atom or group
        const bn = ast.node(base);
        const mark = try ast.createLeaf(.char, cmd_tok, 1, cp);
        const mn = ast.node(mark);
        const children = [_]atom.Node{ bn, mn };
        const num_tokens = (bn.first_token + bn.num_tokens) - cmd_tok;
        return ast.createNode(.row, cmd_tok, num_tokens, &children, accent_row_data);
    }

    /// \not<relation> — the negation prefix (a diagonal slash through the
    /// following atom/group). Matches unicode-math's \not command: when the
    /// base is a single relation glyph with a pre-composed negated form in
    /// `not_cp_map`, the result is that glyph (a char leaf carrying the
    /// codepoint in `data`, like \cdot — layout marks it synthetic because
    /// the drawn glyph differs from the "\not\leq" source bytes); otherwise
    /// the result is a `not_row_data` row of [base], whose layout overlays
    /// the U+0338 combining long solidus overlay exactly like XeTeX's
    /// \mathaccentoverlay placement (see layoutNot). The span covers
    /// `\not` through the base so provenance stays exact. Scripts after the
    /// negation (`\not\leq^2`) attach to the result via the usual
    /// parseAtom path.
    fn not(self: *Parser, ast: *atom.Ast, cmd_tok: u32) Error!u32 {
        const base = try self.parseScriptArg(ast); // single atom or group
        const bn = ast.node(base);
        const num_tokens = (bn.first_token + bn.num_tokens) - cmd_tok;
        // Unwrap transparent wrappers to the underlying single atom: \not{a}
        // negates the GROUP's content, but a braced single glyph ({=}) is
        // still TeX's one-noad case — the pre-composed form applies (the
        // XeTeX reference renders \not{=} → ≠ and \not{\leq} → ≰). A group
        // wraps its row, so single-child rows are descended too; multi-child
        // groups ({ab}) keep the overlay path (XeTeX anchors that slash to
        // the group's FIRST character — layoutNot's first-char rule).
        var u = base;
        while (true) {
            const n = ast.node(u);
            const transparent = n.tag == .group or n.tag == .styled or n.tag == .mathstyle;
            if (!transparent and !(n.tag == .row and n.num_children == 1)) break;
            if (n.num_children == 0) break;
            u = ast.child(u, 0);
        }
        const un = ast.node(u);
        if (un.tag == .char) {
            const cp: u21 = if (un.data != 0) @truncate(un.data) else blk: {
                const sp = ast.span(u);
                break :blk if (sp.end - sp.start == 1) self.src[sp.start] else 0;
            };
            for (not_cp_map) |e| {
                if (e.cp == cp) {
                    // Pre-composed glyph: a char leaf like \cdot (the
                    // codepoint rides in `data`; layout marks it synthetic).
                    return ast.createLeaf(.char, cmd_tok, num_tokens, e.neg);
                }
            }
        }
        // Overlay: a row marked `not_row_data`, children [base].
        const children = [_]atom.Node{ast.node(base)};
        return ast.createNode(.row, cmd_tok, num_tokens, &children, not_row_data);
    }

    /// \overline{x} / \underline{x}: a rule over/under ONE following atom or
    /// braced group (TeX: the argument is a math field — `\overline x` is
    /// the overline of x, `\overline{xy}` of the group). The node is a
    /// `.overline` atom whose data = 0 over / 1 under, so layout draws the
    /// rule (rect, rule_thickness thick) above/below the content at a
    /// clearance of 3·rule_thickness, spanning exactly the content's width.
    /// Scripts after it (`\overline{x}^2`) attach to the whole overline via
    /// the usual parseAtom path.
    fn overunder(self: *Parser, ast: *atom.Ast, cmd_tok: u32, under: bool) Error!u32 {
        const base = try self.parseScriptArg(ast); // single atom or group
        const bn = ast.node(base);
        const num_tokens = (bn.first_token + bn.num_tokens) - cmd_tok;
        const children = [_]atom.Node{ast.node(base)};
        return ast.createNode(.overline, cmd_tok, num_tokens, &children, @intFromBool(under));
    }

    /// \substack{a \\ b \\ c}: amsmath's script-size multi-line stack for
    /// limits (`\sum_{\substack{i=1 \\ j=2}} x_i x_j`). The braced content
    /// is split on `\\` into lines, each parsed as its own row in
    /// .substack_line mode (so `\\` and `}` end a line; scripts, infix
    /// fractions and style switches inside a line behave exactly as in a
    /// normal row). The lines become the children of a `.substack` atom;
    /// layout stacks them at script size, centered, with the TeX \subarray
    /// baseline gaps. Scripts after the stack (`\substack{...}^2`) attach
    /// via the usual parseAtom path, like any base.
    fn substack(self: *Parser, ast: *atom.Ast, cmd_tok: u32) Error!u32 {
        const t = self.peek() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        if (t.tag != .l_group) return self.fail(.missing_argument, spanOf(t));
        const open_tok: u32 = @intCast(self.pos);
        _ = self.advance(); // consume `{`
        var lines: std.ArrayList(atom.Node) = .empty;
        defer lines.deinit(self.gpa);
        var close_tok: u32 = cmd_tok;
        while (true) {
            const line = try self.parseRow(ast, .substack_line);
            const ln = ast.node(line);
            try lines.append(self.gpa, ln);
            // Unclosed substack: point at its opening brace.
            const nxt = self.peek() orelse return self.fail(.unclosed_group, self.spanAt(open_tok));
            if (nxt.tag == .r_group) {
                close_tok = @intCast(self.pos);
                _ = self.advance(); // consume `}`
                break;
            }
            // Otherwise the next token is the `\\` line separator (parseRow
            // stopped right at it).
            if (nxt.tag != .command or !std.mem.eql(u8, self.src[nxt.start + 1 .. nxt.end], "\\"))
                return self.fail(.unclosed_group, spanOf(nxt));
            _ = self.advance(); // consume `\\`
        }
        const num_tokens = (close_tok + 1) - cmd_tok;
        return ast.createNode(.substack, cmd_tok, num_tokens, lines.items, 0);
    }

    /// \begin{env}...\end{env}: parse the environment name (`{name}` or
    /// bare letters), the array colspec (for \begin{array}{...}), then the
    /// body — rows split on `\\` (also `\\[dimen]`), cells split on `&` —
    /// until the matching `\end{NAME}`. The result is a `.env` node whose
    /// children are [open?, row1, ..., rowN, close?]: the delimiter char
    /// leaves (pmatrix/bmatrix/Bmatrix/vmatrix/Vmatrix/cases — codepoints
    /// in `data`, like \cdot) around the row atoms. Each row is a `.row`
    /// whose children are the cell atoms; the cells are parsed by parseRow
    /// in `.env_cell` mode, so nested environments, groups, scripts and
    /// \left..\right inside a cell all work.
    fn parseBegin(self: *Parser, ast: *atom.Ast, begin_tok: u32) Error!u32 {
        const name = try self.parseEnvName(ast);
        const kind = env_kind_map.get(name) orelse {
            // The offending input is the environment name itself.
            const start: u32 = @intCast(@intFromPtr(name.ptr) - @intFromPtr(self.src.ptr));
            const span: atom.Span = .{ .start = start, .end = start + @as(u32, @intCast(name.len)) };
            return self.fail(.unknown_environment, span);
        };
        var colspec: []const u8 = "";
        if (kind == .array) colspec = try self.parseColspec(ast);
        var children: std.ArrayList(atom.Node) = .empty;
        defer children.deinit(self.gpa);
        // The delimiter char leaves around the rows (pmatrix → ( ), ...);
        // the char leaf data carries the codepoint (layout marks synthetic).
        if (envOpenDelim(kind)) |cp| {
            const leaf = try ast.createLeaf(.char, begin_tok, 1, cp);
            try children.append(self.gpa, ast.node(leaf));
        }
        var rows = try self.parseEnvBody(ast);
        defer rows.deinit(self.gpa);
        for (rows.items) |r| try children.append(self.gpa, r);
        if (envCloseDelim(kind)) |cp| {
            const leaf = try ast.createLeaf(.char, begin_tok, 1, cp);
            try children.append(self.gpa, ast.node(leaf));
        }
        // Expect the matching `\end` and verify the name.
        const t = self.advance() orelse return self.fail(.unclosed_environment, self.spanAt(self.pos));
        if (t.tag != .command or !std.mem.eql(u8, self.src[t.start + 1 .. t.end], "end"))
            return self.fail(.unclosed_environment, spanOf(t));
        const end_name = try self.parseEnvName(ast);
        if (!std.mem.eql(u8, end_name, name)) {
            // The offending input is the mismatched \end name.
            const start: u32 = @intCast(@intFromPtr(end_name.ptr) - @intFromPtr(self.src.ptr));
            const span: atom.Span = .{ .start = start, .end = start + @as(u32, @intCast(end_name.len)) };
            return self.fail(.mismatched_end, span);
        }
        const num_tokens = @as(u32, @intCast(self.pos)) - begin_tok;
        return ast.createNode(.env, begin_tok, num_tokens, children.items, atom.envData(kind, colspec));
    }

    /// The environment body: rows split on `\\` (an optional `[dimen]` row
    /// gap is consumed and discarded), cells split on `&`. Each cell is a
    /// row parsed in `.env_cell` mode (which stops at `&`, `\\`, `\end`,
    /// `}`). Returns the row nodes — the children of the `.env` node.
    fn parseEnvBody(self: *Parser, ast: *atom.Ast) Error!std.ArrayList(atom.Node) {
        var rows: std.ArrayList(atom.Node) = .empty;
        errdefer rows.deinit(self.gpa);
        var cells: std.ArrayList(atom.Node) = .empty;
        defer cells.deinit(self.gpa);
        while (true) {
            const cell = try self.parseRow(ast, .env_cell);
            try cells.append(self.gpa, ast.node(cell));
            const nxt = self.peek();
            if (nxt == null) return self.fail(.unclosed_environment, self.spanAt(self.pos)); // no \end
            const t = nxt.?;
            switch (t.tag) {
                .r_group => return self.fail(.unexpected_r_group, spanOf(t)), // stray } in the body
                .char => {
                    // `&` starts the next cell; anything else is a stray
                    // char parseRow left unparsed.
                    if (self.src[t.start] != '&') return self.fail(.unexpected_r_group, spanOf(t));
                    _ = self.advance(); // consume `&`
                },
                .command => {
                    const nm = self.src[t.start + 1 .. t.end];
                    if (std.mem.eql(u8, nm, "end")) {
                        // \end closes the environment: finalize the current
                        // row only if it has cells (a trailing `\\` before
                        // \end does not add an empty row — TeX's \crcr is
                        // absorbed after an explicit \cr).
                        if (cells.items.len > 0) try self.finishEnvRow(ast, &rows, &cells);
                        return rows;
                    }
                    if (std.mem.eql(u8, nm, "\\")) {
                        _ = self.advance(); // consume `\\`
                        // Optional `[dimen]` row gap after `\\` is consumed
                        // (its value is not modeled; the strut gap governs).
                        if (self.peek()) |d| {
                            if (d.tag == .char and self.src[d.start] == '[') {
                                _ = self.advance();
                                while (self.peek()) |c| {
                                    if (c.tag == .char and self.src[c.start] == ']') break;
                                    _ = self.advance();
                                }
                                const close = self.advance() orelse
                                    return self.fail(.missing_argument, self.spanAt(self.pos));
                                if (close.tag != .char or self.src[close.start] != ']')
                                    return self.fail(.missing_argument, spanOf(close));
                            }
                        }
                        try self.finishEnvRow(ast, &rows, &cells);
                        continue;
                    }
                    return self.fail(.unexpected_r_group, spanOf(t));
                },
                else => return self.fail(.unexpected_r_group, spanOf(t)),
            }
        }
    }

    /// Wrap the collected cells of the current row into a `.row` node and
    /// append it to the env's rows.
    fn finishEnvRow(
        self: *Parser,
        ast: *atom.Ast,
        rows: *std.ArrayList(atom.Node),
        cells: *std.ArrayList(atom.Node),
    ) Error!void {
        const first = cells.items[0];
        const last = cells.items[cells.items.len - 1];
        const num_tokens = (last.first_token + last.num_tokens) - first.first_token;
        const row = try ast.createNode(.row, first.first_token, num_tokens, cells.items, 0);
        try rows.append(self.gpa, ast.node(row));
        cells.clearRetainingCapacity();
    }

    /// The environment name after \begin/\end: `{name}` or bare letters
    /// (`\begin matrix`). Returns the name bytes (a slice of the source).
    fn parseEnvName(self: *Parser, _: *atom.Ast) Error![]const u8 {
        const t = self.peek() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        var start_tok: u32 = undefined;
        var end_tok: u32 = undefined;
        if (t.tag == .l_group) {
            const open_tok: u32 = @intCast(self.pos);
            _ = self.advance(); // consume `{`
            start_tok = @intCast(self.pos);
            while (self.peek()) |c| {
                if (c.tag != .char) break;
                _ = self.advance();
            }
            end_tok = @intCast(self.pos);
            const close = self.advance() orelse return self.fail(.unclosed_group, self.spanAt(open_tok));
            if (close.tag != .r_group) return self.fail(.missing_argument, spanOf(close));
        } else if (t.tag == .char and isEnvNameChar(self.src[t.start])) {
            start_tok = @intCast(self.pos);
            while (self.peek()) |c| {
                if (c.tag != .char or !isEnvNameChar(self.src[c.start])) break;
                _ = self.advance();
            }
            end_tok = @intCast(self.pos);
        } else {
            return self.fail(.missing_argument, spanOf(t));
        }
        if (end_tok <= start_tok) return self.fail(.missing_argument, spanOf(t)); // empty name
        const st = self.tokens[start_tok];
        const et = self.tokens[end_tok - 1];
        return self.src[st.start..et.end];
    }

    /// The array column spec: a required braced string of l/c/r/| chars
    /// (`\begin{array}{l|r}`). Returns the bytes between the braces.
    fn parseColspec(self: *Parser, _: *atom.Ast) Error![]const u8 {
        const t = self.advance() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        if (t.tag != .l_group) return self.fail(.missing_argument, spanOf(t));
        const open_tok: u32 = @intCast(self.pos - 1);
        const start_tok: u32 = @intCast(self.pos);
        while (self.peek()) |c| {
            if (c.tag != .char) break;
            _ = self.advance();
        }
        const end_tok: u32 = @intCast(self.pos);
        const close = self.advance() orelse return self.fail(.unclosed_group, self.spanAt(open_tok));
        if (close.tag != .r_group) return self.fail(.missing_argument, spanOf(close));
        if (end_tok <= start_tok) return self.fail(.missing_argument, spanOf(t));
        const st = self.tokens[start_tok];
        const et = self.tokens[end_tok - 1];
        return self.src[st.start..et.end];
    }

    /// \pmod{n} / \pod{n}: amsmath's parenthesized-mod constructs (the
    /// " (mod n)" after a congruence). amsmath.sty:
    ///   \pod#1{\allowbreak \if@display\mkern18mu\else\mkern8mu\fi (#1)}
    ///   \pmod#1{\pod{{\operator@font mod}\mkern6mu#1}}
    /// so \pmod = leading \mkern + '(' + roman "mod" + 6mu + arg + ')' and
    /// \pod = the same without the word. The parse result is a row marked
    /// pmod_row_data / pod_row_data whose children are
    /// ['(', (opname "mod", 6mu space leaf, for \pmod), arg, ')'] — the
    /// synthesized glyphs (parens, letters) carry their codepoints in
    /// `data` and share the command token's span, so layout marks them
    /// synthetic. layoutPmod applies the style-dependent leading \mkern
    /// (18mu display / 8mu otherwise) and places the pieces back to back
    /// (every inter-atom glue in the composition is zero in TeX).
    fn pmod(self: *Parser, ast: *atom.Ast, cmd_tok: u32, with_mod: bool) Error!u32 {
        const arg = try self.parseScriptArg(ast); // single atom or braced group
        const an = ast.node(arg);
        var children: std.ArrayList(atom.Node) = .empty;
        defer children.deinit(self.gpa);
        const open = try ast.createLeaf(.char, cmd_tok, 1, 0x28); // (
        try children.append(self.gpa, ast.node(open));
        if (with_mod) {
            // the roman "mod" word (the same opname mechanism as \sin):
            // letters with ASCII codepoints in data, laid out roman
            const word = try self.opname(ast, cmd_tok, "mod");
            try children.append(self.gpa, ast.node(word));
            // \mkern6mu between the word and the argument (6/18 em)
            const gap = try ast.createLeaf(.space, cmd_tok, 1, atom.emToFixed(6.0 / 18.0));
            try children.append(self.gpa, ast.node(gap));
        }
        try children.append(self.gpa, an);
        const close = try ast.createLeaf(.char, cmd_tok, 1, 0x29); // )
        try children.append(self.gpa, ast.node(close));
        const num_tokens = (an.first_token + an.num_tokens) - cmd_tok;
        return ast.createNode(.row, cmd_tok, num_tokens, children.items, if (with_mod) pmod_row_data else pod_row_data);
    }

    /// \bmod: amsmath's binary mod. amsmath.sty:
    ///   \def\bmod{\mskip-\medmuskip\mkern5mu\mathbin{\operator@font mod}
    ///             \penalty900\mkern5mu\mskip-\medmuskip}
    /// The ord↔bin glue TeX inserts around the \mathbin (4mu medmuskip) is
    /// cancelled by the two \mskip-\medmuskip kerns, so the NET spacing is
    /// exactly 5mu before and after the roman "mod" word (measured on the
    /// XeTeX reference: `a \bmod 2` at 30pt has 8.334pt = 5mu on each
    /// side). The parse result is a row marked bmod_row_data whose children
    /// are [5mu space, opname "mod", 5mu space]; the row's role is ord (the
    /// space leaves are ord), so layoutRow adds no inter-atom glue around
    /// it and layoutBmod places the three pieces back to back.
    fn bmod(self: *Parser, ast: *atom.Ast, cmd_tok: u32) Error!u32 {
        const word = try self.opname(ast, cmd_tok, "mod");
        const gap = try ast.createLeaf(.space, cmd_tok, 1, atom.emToFixed(5.0 / 18.0));
        const wn = ast.node(word);
        const gn = ast.node(gap);
        const children = [_]atom.Node{ gn, wn, gn };
        return ast.createNode(.row, cmd_tok, 1, &children, bmod_row_data);
    }

    /// \mod{arg}: amsmath's mod with its argument. amsmath.sty:
    ///   \def\mod#1{\allowbreak \if@display\mkern18mu\else\mkern12mu\fi
    ///              {\operator@font mod}\,\,#1}
    /// so \mod = a style-dependent leading \mkern (18mu in display math,
    /// 12mu in text/script/scriptscript — KaTeX's \mathchoice agrees:
    /// 18mu display / 12mu otherwise) + the roman "mod" word + TWO thin
    /// spaces (\, \, = 6mu) + the argument. The parse result is a row
    /// marked mod_row_data whose children are [opname "mod", 6mu space,
    /// arg]; layoutMod applies the leading \mkern and places the pieces
    /// back to back (the composition's inter-atom glues are all zero in
    /// TeX). The row's left role is forced to ord (the leading \mkern is
    /// not a noad — TeX's first atom of the construct is the ord "mod"
    /// group, so the preceding atom gets NO glue).
    fn mod(self: *Parser, ast: *atom.Ast, cmd_tok: u32) Error!u32 {
        const arg = try self.parseScriptArg(ast); // single atom or braced group
        const an = ast.node(arg);
        const word = try self.opname(ast, cmd_tok, "mod");
        // \,\,\! — the two thin spaces between the word and the argument
        // (6/18 em, exactly like \pmod's \mkern6mu).
        const gap = try ast.createLeaf(.space, cmd_tok, 1, atom.emToFixed(6.0 / 18.0));
        const children = [_]atom.Node{ ast.node(word), ast.node(gap), an };
        const num_tokens = (an.first_token + an.num_tokens) - cmd_tok;
        return ast.createNode(.row, cmd_tok, num_tokens, &children, mod_row_data);
    }

    /// Parse the \sqrt[n] degree: atoms until a `]` char at this row level.
    fn parseUntilRBracket(self: *Parser, ast: *atom.Ast) Error!u32 {
        const start_tok: u32 = @intCast(self.pos);
        var last_tok: u32 = start_tok;
        var children: std.ArrayList(atom.Node) = .empty;
        defer children.deinit(self.gpa);
        while (self.peek()) |t| {
            if (t.tag == .char and self.src[t.start] == ']') break;
            const child = try self.parseAtom(ast);
            const cn = ast.node(child);
            try children.append(self.gpa, cn);
            last_tok = cn.first_token + cn.num_tokens;
        }
        return ast.createNode(.row, start_tok, last_tok - start_tok, children.items, 0);
    }

    /// \big \Big \bigg \Bigg <delim> → a `.left` node of a SINGLE delimiter
    /// child (no inner, no \right) with `data` = the size level 1..4. TeX
    /// (amsmath \bBigg@) makes these \left<delim>\vcenter to n·\big@size{}
    /// \right.; XeTeX+unicode-math draws the SAME MATH-ladder variant at
    /// every size — measured 10/14/24/36pt: \big → parenleft.v1 (ink
    /// 1.094em), \Big → .v4 (1.792em), \bigg → .v6 (2.392em), \Bigg → .v7
    /// (2.990em) — because \big@size scales with the current size. Layout
    /// boxes the delimiter by the fixed ladder entry at the base font size,
    /// axis-centered like \left..\right. `\big.` (null delimiter, like
    /// `\left.`) contributes nothing — a zero-width space, exactly TeX's
    /// empty \big. with nulldelimiterspace 0.
    fn fixedDelim(self: *Parser, ast: *atom.Ast, cmd_tok: u32, level: u32) Error!u32 {
        const d = try self.parseDelimiter();
        if (d == null) return self.space(ast, cmd_tok, 0);
        const dd = d.?;
        const leaf = try ast.createLeaf(.char, dd.tok, 1, dd.cp);
        const children = [_]atom.Node{ast.node(leaf)};
        const num_tokens = (dd.tok + 1) - cmd_tok;
        return ast.createNode(.left, cmd_tok, num_tokens, &children, level);
    }

    /// \middle <delim> — valid only between \left and \right (TeX: "You
    /// can't use \middle in math mode" outside; it needs the enclosing
    /// pair's required size). The delimiter becomes a char leaf whose `data`
    /// packs (middle_marker << 21) | cp: layout's leftRole classifies it
    /// CLOSE (measured: NO glue around the \middle| in the XeTeX reference
    /// of `\left\{ x \middle| \frac{x}{2} \in S \right\}`), layoutRow emits
    /// a zero-width placeholder box, and layoutLeftRight rewrites it with
    /// the fence's required ink applied to the delimiter's OWN variant
    /// ladder (\middle| at 36pt = divides.v3 — the |'s smallest variant
    /// covering the same req the { fence resolved). `\middle.` renders
    /// nothing, like `\big.`.
    fn middle(self: *Parser, ast: *atom.Ast, cmd_tok: u32) Error!u32 {
        if (self.delim_depth == 0) return self.fail(.unexpected_middle, self.spanAt(cmd_tok));
        const d = try self.parseDelimiter();
        if (d == null) return self.space(ast, cmd_tok, 0);
        const dd = d.?;
        return ast.createLeaf(.char, dd.tok, 1, middle_marker | dd.cp);
    }

    /// \left <delim> ... \right <delim> → a `.left` node of [open, inner,
    /// close]: the two delimiter chars around the parsed interior. Layout
    /// stretches the delimiters to cover the inner's height (TeX delimiter
    /// sizing), so \left( \frac{a}{b} \right) shows parens spanning the
    /// fraction. `\left.` and `\right.` (null delimiters) contribute no char.
    fn parseLeftRight(self: *Parser, ast: *atom.Ast, left_tok: u32) Error!u32 {
        const open = try self.parseDelimiter();
        self.delim_depth += 1;
        errdefer self.delim_depth -= 1;
        const inner = try self.parseRow(ast, .delimited);
        // expect the matching \right — checked while the pair is still
        // "open" (delim_depth 1), so an error here unwinds via the
        // errdefer and the depth is NOT double-decremented. An unclosed
        // \left points at the \left command itself (nothing was consumed
        // after the opening delimiter), or at whatever stands in place of
        // \right.
        const t = self.peek() orelse return self.fail(.unclosed_group, self.spanAt(left_tok));
        if (t.tag != .command or !std.mem.eql(u8, self.src[t.start + 1 .. t.end], "right"))
            return self.fail(.unclosed_group, spanOf(t));
        self.delim_depth -= 1;
        _ = self.advance(); // consume \right
        const close = try self.parseDelimiter();
        var children: std.ArrayList(atom.Node) = .empty;
        defer children.deinit(self.gpa);
        if (open) |d| {
            const c = try ast.createLeaf(.char, d.tok, 1, d.cp);
            try children.append(self.gpa, ast.node(c));
        }
        try children.append(self.gpa, ast.node(inner));
        if (close) |d| {
            const c = try ast.createLeaf(.char, d.tok, 1, d.cp);
            try children.append(self.gpa, ast.node(c));
        }
        // pos sits just past the closing delimiter token
        const num_tokens = @as(u32, @intCast(self.pos)) - left_tok;
        return ast.createNode(.left, left_tok, num_tokens, children.items, 0);
    }

    /// Consume one delimiter after \left/\right; null for `\left.` / `\right.`.
    fn parseDelimiter(self: *Parser) Error!?Delimiter {
        const t = self.advance() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        const tok: u32 = @intCast(self.pos - 1);
        return switch (t.tag) {
            .char => switch (self.src[t.start]) {
                '.' => null,
                '(', ')', '[', ']', '|' => .{ .cp = self.src[t.start], .tok = tok },
                else => self.fail(.missing_argument, spanOf(t)),
            },
            .command => blk: {
                const cp = delim_map.get(self.src[t.start + 1 .. t.end]) orelse
                    return self.fail(.missing_argument, spanOf(t));
                break :blk .{ .cp = cp, .tok = tok };
            },
            else => self.fail(.missing_argument, spanOf(t)),
        };
    }
};

/// A delimiter consumed by \left/\right: codepoint + its token index.
const Delimiter = struct {
    cp: u21,
    tok: u32,
};

/// Environment name → kind, for \begin{env}. matrix/pmatrix/bmatrix/
/// Bmatrix/vmatrix/Vmatrix/cases/aligned are amsmath environments; array is
/// LaTeX's array. Unknown names error (UnknownEnvironment).
const env_kind_map = std.StaticStringMap(atom.EnvKind).initComptime(&[_]struct { []const u8, atom.EnvKind }{
    .{ "matrix", .matrix },
    .{ "pmatrix", .pmatrix },
    .{ "bmatrix", .bmatrix },
    .{ "Bmatrix", .Bmatrix },
    .{ "vmatrix", .vmatrix },
    .{ "Vmatrix", .Vmatrix },
    .{ "cases", .cases },
    .{ "aligned", .aligned },
    .{ "array", .array },
});

/// The delimiter char before the rows of an env (like \left), or null.
/// pmatrix ( ), bmatrix [ ], Bmatrix { }, vmatrix | |, Vmatrix ‖ ‖
/// (\lVert/\rVert — U+2016, which has a variant ladder), cases {.
fn envOpenDelim(kind: atom.EnvKind) ?u21 {
    return switch (kind) {
        .pmatrix => 0x28,
        .bmatrix => 0x5B,
        .Bmatrix => 0x7B,
        .vmatrix => 0x7C,
        .Vmatrix => 0x2016,
        .cases => 0x7B,
        else => null,
    };
}

/// The delimiter char after the rows of an env (like \right), or null.
fn envCloseDelim(kind: atom.EnvKind) ?u21 {
    return switch (kind) {
        .pmatrix => 0x29,
        .bmatrix => 0x5D,
        .Bmatrix => 0x7D,
        .vmatrix => 0x7C,
        .Vmatrix => 0x2016,
        else => null,
    };
}

/// ASCII letters only — environment names are letter runs.
fn isEnvNameChar(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z');
}

// ── tests ────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

/// Lex + parse `src`, returning the populated Ast (caller must deinit).
fn parseSrc(gpa: std.mem.Allocator, src: []const u8) !atom.Ast {
    var ast = atom.Ast.init(gpa, src);
    errdefer ast.deinit();
    try lexer.lex(&ast, null);
    var p = Parser.init(gpa, src, ast.tokens.items, null);
    ast.root = try p.parse(&ast);
    return ast;
}

test "parser: the direct route records the depth guard over a stale kind" {
    // `Parser` is published through `ztex.parse.parser`, so a consumer can
    // drive it without the `ztex.parse.parse` wrapper. It has to keep the
    // same guarantee, or this caller reads the previous parse's failure.
    var src: [max_row_depth + 8]u8 = undefined;
    @memset(&src, '{');
    var ast = atom.Ast.init(testing.allocator, &src);
    defer ast.deinit();
    try lexer.lex(&ast, null);

    var err_info: parse_err.Info = .{
        .kind = .unexpected_r_group,
        .span = .{ .start = 2, .end = 3 },
    };
    var p = Parser.init(testing.allocator, &src, ast.tokens.items, &err_info);
    try testing.expectError(error.StackOverflow, p.parse(&ast));
    try testing.expectEqual(parse_err.Kind.depth_exceeded, err_info.kind);
    const span = err_info.span.?;
    try testing.expect(span.start < src.len);
    try testing.expect(span.end <= src.len);
}

test "parser: the direct route fills Info on its own allocation failure" {
    var ast = atom.Ast.init(testing.allocator, "x+1");
    defer ast.deinit();
    try lexer.lex(&ast, null);

    // The Ast owns the tokens, so only the parser's own node allocations
    // fail here; the first of them is parseRow's child reserve.
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var err_info: parse_err.Info = .{
        .kind = .unexpected_r_group,
        .span = .{ .start = 2, .end = 3 },
    };
    var p = Parser.init(failing.allocator(), ast.src, ast.tokens.items, &err_info);
    try testing.expectError(error.OutOfMemory, p.parse(&ast));
    try testing.expectEqual(parse_err.Kind.out_of_memory, err_info.kind);
    try testing.expectEqual(@as(?atom.Span, null), err_info.span);
    try testing.expectEqualStrings("Out of memory", err_info.message());
}

test "parser: empty source yields an empty row" {
    var ast = try parseSrc(testing.allocator, "");
    defer ast.deinit();
    try testing.expectEqual(@as(usize, 1), ast.nodes.items.len);
    try testing.expectEqual(.row, ast.node(0).tag);
}

test "parser: chars become a row of char atoms" {
    var ast = try parseSrc(testing.allocator, "x+1");
    defer ast.deinit();
    const root = ast.node(ast.root);
    try testing.expectEqual(.row, root.tag);
    try testing.expectEqual(@as(u16, 3), root.num_children);
    try testing.expectEqual(.char, ast.node(ast.child(ast.root, 0)).tag);
    try testing.expectEqual(.char, ast.node(ast.child(ast.root, 2)).tag);
}

test "parser: script wraps base with sup and sub" {
    var ast = try parseSrc(testing.allocator, "x^2_3");
    defer ast.deinit();
    // root row → [script]
    const script = ast.child(ast.root, 0);
    const sn = ast.node(script);
    try testing.expectEqual(.script, sn.tag);
    try testing.expectEqual(@as(u16, 3), sn.num_children);
    try testing.expectEqual(.char, ast.node(ast.child(script, 0)).tag);
    try testing.expectEqual(.char, ast.node(ast.child(script, 1)).tag);
    try testing.expectEqual(.char, ast.node(ast.child(script, 2)).tag);
}

test "parser: big operator becomes an op leaf" {
    var ast = try parseSrc(testing.allocator, "\\sum");
    defer ast.deinit();
    const op = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.op, op.tag);
}

test "parser: \\limits sets the force bit on the preceding op" {
    var ast = try parseSrc(testing.allocator, "\\int\\limits_0^1");
    defer ast.deinit();
    // root row → [script]; children [op, sub, sup]
    const script = ast.child(ast.root, 0);
    const op = ast.node(ast.child(script, 0));
    try testing.expectEqual(.op, op.tag);
    try testing.expectEqual(atom.LimitsBits.force, op.data & atom.LimitsBits.force);
    try testing.expectEqual(@as(u32, 0), op.data & atom.LimitsBits.force_beside);
    // the BigOp enum still decodes from the masked data
    try testing.expectEqual(atom.BigOp.int, @as(atom.BigOp, @enumFromInt(op.data & atom.LimitsBits.value_mask)));
}

test "parser: \\nolimits sets the force-beside bit on the preceding op" {
    var ast = try parseSrc(testing.allocator, "\\sum\\nolimits_{i=1}^{n} x_i");
    defer ast.deinit();
    const script = ast.child(ast.root, 0);
    const op = ast.node(ast.child(script, 0));
    try testing.expectEqual(.op, op.tag);
    try testing.expectEqual(atom.LimitsBits.force_beside, op.data & atom.LimitsBits.force_beside);
    try testing.expectEqual(@as(u32, 0), op.data & atom.LimitsBits.force);
    try testing.expectEqual(atom.BigOp.sum, @as(atom.BigOp, @enumFromInt(op.data & atom.LimitsBits.value_mask)));
}

test "parser: \\displaylimits restores the op default (no override bits)" {
    var ast = try parseSrc(testing.allocator, "\\int\\displaylimits_0^1");
    defer ast.deinit();
    const script = ast.child(ast.root, 0);
    const op = ast.node(ast.child(script, 0));
    try testing.expectEqual(.op, op.tag);
    try testing.expectEqual(@as(u32, 0), op.data & atom.LimitsBits.mask);
}

test "parser: last limits command wins on a repeated override" {
    var ast = try parseSrc(testing.allocator, "\\int\\nolimits\\limits_0^1");
    defer ast.deinit();
    const script = ast.child(ast.root, 0);
    const op = ast.node(ast.child(script, 0));
    try testing.expectEqual(atom.LimitsBits.force, op.data & atom.LimitsBits.force);
}

test "parser: \\limits sets the force bit on an operator word" {
    var ast = try parseSrc(testing.allocator, "\\lim\\limits_{x\\to 0}");
    defer ast.deinit();
    const script = ast.child(ast.root, 0);
    const opn = ast.node(ast.child(script, 0));
    try testing.expectEqual(.opname, opn.tag);
    try testing.expectEqual(atom.LimitsBits.force, opn.data & atom.LimitsBits.force);
}

test "parser: \\operatorname is an opname word with nolimits data" {
    var ast = try parseSrc(testing.allocator, "\\operatorname{tr}");
    defer ast.deinit();
    // root row → [opname]; the braced content is the opname's single child.
    const opn = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.opname, opn.tag);
    try testing.expectEqual(@as(u32, 0), opn.data); // unstarred = \nolimits
    try testing.expectEqual(@as(u16, 1), opn.num_children);
    // child is a row of the content's chars
    const row_idx = ast.child(ast.child(ast.root, 0), 0);
    try testing.expectEqual(.row, ast.node(row_idx).tag);
    try testing.expectEqual(@as(u16, 2), ast.node(row_idx).num_children);
    try testing.expectEqual(.char, ast.node(ast.child(row_idx, 1)).tag);
}

test "parser: \\operatorname* consumes the star and sets limits data" {
    var ast = try parseSrc(testing.allocator, "\\operatorname*{arg\\,max}");
    defer ast.deinit();
    // root row → [opname] — the `*` is a macro suffix, never an atom.
    try testing.expectEqual(@as(u16, 1), ast.node(ast.root).num_children);
    const opn = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.opname, opn.tag);
    try testing.expectEqual(@as(u32, 1), opn.data & atom.LimitsBits.value_mask); // \displaylimits
    // content row: a r g \, m a x → the \, is a space atom in the row
    const row_idx = ast.child(ast.child(ast.root, 0), 0);
    try testing.expectEqual(.row, ast.node(row_idx).tag);
    try testing.expectEqual(@as(u16, 7), ast.node(row_idx).num_children);
    try testing.expectEqual(.space, ast.node(ast.child(row_idx, 3)).tag); // the \,
}

test "parser: \\operatorname* with whitespace before the star is starred" {
    var ast = try parseSrc(testing.allocator, "\\operatorname * {x}");
    defer ast.deinit();
    const opn = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.opname, opn.tag);
    try testing.expectEqual(@as(u32, 1), opn.data & atom.LimitsBits.value_mask);
    try testing.expectEqual(@as(u16, 1), ast.node(ast.root).num_children);
}

test "parser: scripts attach to an \\operatorname base" {
    var ast = try parseSrc(testing.allocator, "\\operatorname{tr}^2");
    defer ast.deinit();
    const script = ast.child(ast.root, 0);
    try testing.expectEqual(.script, ast.node(script).tag);
    const base = ast.node(ast.child(script, 0));
    try testing.expectEqual(.opname, base.tag);
    try testing.expectEqual(@as(u32, 0), base.data); // beside scripts by default
    const sup = ast.node(ast.child(script, 1));
    try testing.expectEqual(.char, sup.tag);
}

test "parser: \\operatorname without an argument is an error" {
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\operatorname"));
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\operatorname*"));
}

test "parser: sub-only script records SUB bit, not SUP" {
    var ast = try parseSrc(testing.allocator, "x_2");
    defer ast.deinit();
    const script = ast.child(ast.root, 0);
    const sn = ast.node(script);
    try testing.expectEqual(.script, sn.tag);
    try testing.expect(sn.data & atom.ScriptBits.sub != 0);
    try testing.expect(sn.data & atom.ScriptBits.sup == 0);
    try testing.expectEqual(@as(u16, 2), sn.num_children); // base + sub
}

test "parser: double script is an error" {
    try testing.expectError(error.DoubleScript, parseSrc(testing.allocator, "x^2^3"));
}

test "parser: atop produces a fraction with line=false" {
    var ast = try parseSrc(testing.allocator, "\\atop{a}{b}");
    defer ast.deinit();
    const frac = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.fraction, frac.tag);
    try testing.expectEqual(@as(u32, 0), frac.data); // line = false
    try testing.expectEqual(@as(u16, 2), frac.num_children);
}

test "parser: binom is a left-wrapped ruleless fraction with parens" {
    var ast = try parseSrc(testing.allocator, "\\binom{n}{k}");
    defer ast.deinit();
    const left = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.left, left.tag);
    try testing.expectEqual(@as(u32, 0), left.data); // fence path, not \big
    try testing.expectEqual(@as(u16, 3), left.num_children);
    // [open '(', fraction, close ')'] — the parens are synthetic char leaves
    const open = ast.node(ast.child(ast.child(ast.root, 0), 0));
    try testing.expectEqual(.char, open.tag);
    try testing.expectEqual(@as(u32, 0x28), open.data);
    const frac = ast.node(ast.child(ast.child(ast.root, 0), 1));
    try testing.expectEqual(.fraction, frac.tag);
    try testing.expect(!atom.fracLine(frac.data)); // no rule (\atop-style)
    try testing.expectEqual(null, atom.fracForcedStyle(frac.data)); // current style
    try testing.expectEqual(@as(f32, 0), atom.fracThickness(frac.data));
    const close = ast.node(ast.child(ast.child(ast.root, 0), 2));
    try testing.expectEqual(.char, close.tag);
    try testing.expectEqual(@as(u32, 0x29), close.data);
}

test "parser: genfrac with empty delims and 0pt is a bare atop fraction" {
    var ast = try parseSrc(testing.allocator, "\\genfrac{}{}{0pt}{}{a}{b}");
    defer ast.deinit();
    const frac = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.fraction, frac.tag);
    try testing.expectEqual(@as(u32, 0), frac.data); // exactly \atop's encoding
}

test "parser: genfrac explicit thickness sets line + thickness bits" {
    var ast = try parseSrc(testing.allocator, "\\genfrac{}{}{1pt}{}{a}{b}");
    defer ast.deinit();
    const frac = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.fraction, frac.tag);
    try testing.expect(atom.fracLine(frac.data));
    try testing.expectApproxEqAbs(@as(f32, 1), atom.fracThickness(frac.data), 1e-3);
    try testing.expectEqual(null, atom.fracForcedStyle(frac.data));
}

test "parser: genfrac style argument maps like amsmath/KaTeX" {
    const cases = [_]struct { src: []const u8, forced: ?atom.MathStyle }{
        // "" → current style; 0 → display; 1 → text; 2 → script; else → scriptscript
        .{ .src = "\\genfrac{}{}{0pt}{}{a}{b}", .forced = null },
        .{ .src = "\\genfrac{}{}{0pt}{0}{a}{b}", .forced = .display },
        .{ .src = "\\genfrac{}{}{0pt}{1}{a}{b}", .forced = .text },
        .{ .src = "\\genfrac{}{}{0pt}{2}{a}{b}", .forced = .script },
        .{ .src = "\\genfrac{}{}{0pt}{3}{a}{b}", .forced = .script_script },
        .{ .src = "\\genfrac{}{}{0pt}{x}{a}{b}", .forced = .script_script },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const frac = ast.node(ast.child(ast.root, 0));
        try testing.expectEqual(.fraction, frac.tag);
        try testing.expectEqual(c.forced, atom.fracForcedStyle(frac.data));
    }
}

test "parser: genfrac delimiters wrap the fraction in a left fence" {
    var ast = try parseSrc(testing.allocator, "\\genfrac{[}{]}{0pt}{}{a}{b}");
    defer ast.deinit();
    const left = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.left, left.tag);
    try testing.expectEqual(@as(u16, 3), left.num_children);
    const open = ast.node(ast.child(ast.child(ast.root, 0), 0));
    try testing.expectEqual(.char, open.tag);
    try testing.expectEqual(@as(u32, 0x5B), open.data);
    const frac = ast.node(ast.child(ast.child(ast.root, 0), 1));
    try testing.expectEqual(.fraction, frac.tag);
    try testing.expect(!atom.fracLine(frac.data));
    // a command delimiter (\lbrace) and a non-0.8pt thickness + style 1
    var b = try parseSrc(testing.allocator, "\\genfrac{\\lbrace}{\\rbrace}{0.8pt}{1}{x}{y}");
    defer b.deinit();
    const bl = b.node(b.child(b.root, 0));
    try testing.expectEqual(.left, bl.tag);
    const bopen = b.node(b.child(b.child(b.root, 0), 0));
    try testing.expectEqual(@as(u32, 0x7B), bopen.data);
    const bfrac = b.node(b.child(b.child(b.root, 0), 1));
    try testing.expect(atom.fracLine(bfrac.data));
    try testing.expectApproxEqAbs(@as(f32, 0.8), atom.fracThickness(bfrac.data), 1e-3);
    try testing.expectEqual(atom.MathStyle.text, atom.fracForcedStyle(bfrac.data));
}

test "parser: genfrac dot delimiters and missing args" {
    // \genfrac{.}{.} → null delimiters (like \left.), bare fraction
    var ast = try parseSrc(testing.allocator, "\\genfrac{.}{.}{0pt}{}{a}{b}");
    defer ast.deinit();
    try testing.expectEqual(.fraction, ast.node(ast.child(ast.root, 0)).tag);
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\genfrac{}{}{0pt}{}{a}"));
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\genfrac{}{}{abc}{}{a}{b}"));
}

test "parser: dfrac/tfrac/cfrac carry forced-style fraction data" {
    const cases = [_]struct {
        src: []const u8,
        line: bool,
        forced: ?atom.MathStyle,
        parts_display: bool,
    }{
        .{ .src = "\\dfrac{1}{2}", .line = true, .forced = .display, .parts_display = false },
        .{ .src = "\\tfrac{1}{2}", .line = true, .forced = .text, .parts_display = false },
        .{ .src = "\\cfrac{1}{2}", .line = true, .forced = .display, .parts_display = true },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const frac = ast.node(ast.child(ast.root, 0));
        try testing.expectEqual(.fraction, frac.tag);
        try testing.expectEqual(c.line, atom.fracLine(frac.data));
        try testing.expectEqual(c.forced, atom.fracForcedStyle(frac.data));
        try testing.expectEqual(c.parts_display, atom.fracPartsDisplay(frac.data));
    }
    // a plain \frac keeps the legacy data encoding (0/1)
    var ast = try parseSrc(testing.allocator, "\\frac{1}{2}");
    defer ast.deinit();
    const frac = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(@as(u32, 1), frac.data);
    try testing.expectEqual(null, atom.fracForcedStyle(frac.data));
}

test "parser: style switches wrap the rest of the group in mathstyle" {
    var ast = try parseSrc(testing.allocator, "\\displaystyle x y");
    defer ast.deinit();
    const root = ast.node(ast.root);
    try testing.expectEqual(@as(u16, 1), root.num_children);
    const ms = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.mathstyle, ms.tag);
    try testing.expectEqual(@as(u32, @intFromEnum(atom.MathStyle.display)), ms.data);
    // the wrapped child is a row of BOTH atoms (rest-of-group semantics)
    const inner = ast.node(ast.child(ast.child(ast.root, 0), 0));
    try testing.expectEqual(.row, inner.tag);
    try testing.expectEqual(@as(u16, 2), inner.num_children);
}

test "parser: textstyle sum keeps limits inside the wrapper" {
    var ast = try parseSrc(testing.allocator, "\\textstyle \\sum_{i=1}^{n} x_i");
    defer ast.deinit();
    const ms = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.mathstyle, ms.tag);
    try testing.expectEqual(@as(u32, @intFromEnum(atom.MathStyle.text)), ms.data);
    const inner = ast.node(ast.child(ast.child(ast.root, 0), 0));
    try testing.expectEqual(.row, inner.tag);
    try testing.expectEqual(@as(u16, 2), inner.num_children); // \sum_{i=1}^{n}, x_i
    const scripted_sum = ast.node(ast.child(ast.child(ast.child(ast.root, 0), 0), 0));
    try testing.expectEqual(.script, scripted_sum.tag);
    const sum_base = ast.node(ast.child(ast.child(ast.child(ast.child(ast.root, 0), 0), 0), 0));
    try testing.expectEqual(.op, sum_base.tag);
}

test "parser: braced style switch in a script field wraps the group's row" {
    var ast = try parseSrc(testing.allocator, "x^{\\displaystyle 2}");
    defer ast.deinit();
    const script = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.script, script.tag);
    // the braced field is a group → its row → the mathstyle wrapper
    const sup = ast.node(ast.child(ast.child(ast.root, 0), 1));
    try testing.expectEqual(.group, sup.tag);
    const inner_row = ast.node(ast.child(ast.child(ast.child(ast.root, 0), 1), 0));
    try testing.expectEqual(.row, inner_row.tag);
    const ms = ast.node(ast.child(ast.child(ast.child(ast.child(ast.root, 0), 1), 0), 0));
    try testing.expectEqual(.mathstyle, ms.tag);
    try testing.expectEqual(@as(u32, @intFromEnum(atom.MathStyle.display)), ms.data);
}

test "parser: unbraced style switch in a script field wraps the single atom" {
    var ast = try parseSrc(testing.allocator, "x^\\displaystyle 2");
    defer ast.deinit();
    const script = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.script, script.tag);
    const sup = ast.node(ast.child(ast.child(ast.root, 0), 1));
    try testing.expectEqual(.mathstyle, sup.tag);
    try testing.expectEqual(@as(u32, @intFromEnum(atom.MathStyle.display)), sup.data);
    // the wrapped child is the single atom '2' (the rest of the row is outside)
    const inner = ast.node(ast.child(ast.child(ast.child(ast.root, 0), 1), 0));
    try testing.expectEqual(.char, inner.tag);
}

test "parser: empty braced style switch parses as an empty mathstyle group" {
    var ast = try parseSrc(testing.allocator, "\\frac{\\displaystyle}{b}");
    defer ast.deinit();
    const frac = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.fraction, frac.tag);
    // parseRequiredArg returns the inner row (no group wrapper)
    const num_row = ast.node(ast.child(ast.child(ast.root, 0), 0));
    try testing.expectEqual(.row, num_row.tag);
    const ms = ast.node(ast.child(ast.child(ast.child(ast.root, 0), 0), 0));
    try testing.expectEqual(.mathstyle, ms.tag);
    try testing.expectEqual(@as(u32, @intFromEnum(atom.MathStyle.display)), ms.data);
}

test "parser: horizontal space commands carry em widths" {
    const cases = [_]struct { src: []const u8, em: f32 }{
        .{ .src = "\\,", .em = 0.166 },
        .{ .src = "\\;", .em = 0.277 },
        .{ .src = "\\quad", .em = 1.0 },
        .{ .src = "\\qquad", .em = 2.0 },
        .{ .src = "\\!", .em = -0.166 },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const sp = ast.node(ast.child(ast.root, 0));
        try testing.expectEqual(.space, sp.tag);
        try testing.expectApproxEqAbs(c.em, atom.fixedToEm(sp.data), 0.001);
    }
}

test "parser: text becomes a roman text leaf" {
    var ast = try parseSrc(testing.allocator, "\\text{hi}");
    defer ast.deinit();
    const txt = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.text, txt.tag);
    try testing.expectEqual(@as(u32, @intFromEnum(atom.CharStyle.roman)), txt.data);
}

test "parser: style commands set CharStyle data" {
    const cases = [_]struct { src: []const u8, style: atom.CharStyle }{
        .{ .src = "\\mathrm{x}", .style = .roman },
        .{ .src = "\\mathbf{x}", .style = .bold },
        .{ .src = "\\mathbb{x}", .style = .bb },
        .{ .src = "\\mathcal{x}", .style = .cal },
        .{ .src = "\\mathfrak{x}", .style = .frak },
        .{ .src = "\\mathsf{x}", .style = .sans },
        .{ .src = "\\mathtt{x}", .style = .mono },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const st = ast.node(ast.child(ast.root, 0));
        try testing.expectEqual(.styled, st.tag);
        try testing.expectEqual(@as(u32, @intFromEnum(c.style)), st.data);
        try testing.expectEqual(@as(u16, 1), st.num_children);
    }
}

test "parser: sup-only script records SUP bit" {
    var ast = try parseSrc(testing.allocator, "x^2");
    defer ast.deinit();
    const script = ast.child(ast.root, 0);
    const sn = ast.node(script);
    try testing.expectEqual(.script, sn.tag);
    try testing.expect(sn.data & atom.ScriptBits.sup != 0);
    try testing.expect(sn.data & atom.ScriptBits.sub == 0);
    try testing.expectEqual(@as(u16, 2), sn.num_children); // base + sup
    try testing.expectEqual(.char, ast.node(ast.child(script, 1)).tag);
}

test "parser: braced superscript becomes a group child" {
    var ast = try parseSrc(testing.allocator, "x^{ab}");
    defer ast.deinit();
    const script = ast.child(ast.root, 0);
    const sn = ast.node(script);
    try testing.expectEqual(.script, sn.tag);
    try testing.expect(sn.data & atom.ScriptBits.sup != 0);
    try testing.expectEqual(@as(u16, 2), sn.num_children);
    try testing.expectEqual(.group, ast.node(ast.child(script, 1)).tag);
}

test "parser: all error paths are reported" {
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\frac{1}"));
    try testing.expectError(error.MissingScript, parseSrc(testing.allocator, "x^"));
    try testing.expectError(error.UnclosedGroup, parseSrc(testing.allocator, "\\frac{1}{2"));
    try testing.expectError(error.UnexpectedRGroup, parseSrc(testing.allocator, "x}"));
    try testing.expectError(error.UnexpectedScript, parseSrc(testing.allocator, "^x"));
    try testing.expectError(error.DoubleScript, parseSrc(testing.allocator, "x^2^3"));
}

test "parser: not resolves pre-composed negations to their codepoints" {
    // \not\in → ∉, \not\leq → ≰, \not= → ≠, \not\subset → ⊄, \not\simeq →
    // ≄ — the XeTeX+unicode-math reference renders all five as single
    // pre-composed glyphs, so ztex emits the same codepoints.
    const cases = [_]struct { src: []const u8, cp: u21 }{
        .{ .src = "\\not\\in", .cp = 0x2209 },
        .{ .src = "\\not\\leq", .cp = 0x2270 },
        .{ .src = "\\not=", .cp = 0x2260 },
        .{ .src = "\\not\\subset", .cp = 0x2284 },
        .{ .src = "\\not\\simeq", .cp = 0x2244 },
        .{ .src = "\\not\\ge", .cp = 0x2271 },
        .{ .src = "\\not\\equiv", .cp = 0x2262 },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const ch = ast.node(ast.child(ast.root, 0));
        try testing.expectEqual(.char, ch.tag);
        try testing.expectEqual(c.cp, @as(u21, @truncate(ch.data)));
        // the span covers \not + the relation
        try testing.expectEqual(@as(u32, 2), ch.num_tokens);
    }
}

test "parser: not on a relation without a pre-composed form emits the overlay row" {
    // \not\smile has no pre-composed negation in unicode-math/LM Math, so
    // the result is the U+0338-overlay row (children [base]).
    var ast = try parseSrc(testing.allocator, "\\not\\smile");
    defer ast.deinit();
    const row = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.row, row.tag);
    try testing.expectEqual(not_row_data, row.data);
    try testing.expectEqual(@as(u16, 1), row.num_children);
    try testing.expectEqual(.char, ast.node(ast.child(ast.child(ast.root, 0), 0)).tag);
}

test "parser: not on a plain char and a braced group" {
    // \not x → overlay row (no pre-composed form for x); \not{=} still
    // resolves the pre-composed ≠ through the transparent group.
    var ast = try parseSrc(testing.allocator, "\\not x");
    defer ast.deinit();
    const row = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.row, row.tag);
    try testing.expectEqual(not_row_data, row.data);
    var ast2 = try parseSrc(testing.allocator, "\\not{=}");
    defer ast2.deinit();
    const ch = ast2.node(ast2.child(ast2.root, 0));
    try testing.expectEqual(.char, ch.tag);
    try testing.expectEqual(@as(u21, 0x2260), @as(u21, @truncate(ch.data)));
}

test "parser: pre-composed negation commands emit their codepoints" {
    const cases = [_]struct { src: []const u8, cp: u21 }{
        .{ .src = "\\nleq", .cp = 0x2270 },
        .{ .src = "\\ngeq", .cp = 0x2271 },
        .{ .src = "\\nsubseteq", .cp = 0x2288 },
        .{ .src = "\\nsupseteq", .cp = 0x2289 },
        .{ .src = "\\nmid", .cp = 0x2224 },
        .{ .src = "\\nparallel", .cp = 0x2226 },
        .{ .src = "\\nprec", .cp = 0x2280 },
        .{ .src = "\\nsucc", .cp = 0x2281 },
        .{ .src = "\\npreceq", .cp = 0x22E0 },
        .{ .src = "\\nsucceq", .cp = 0x22E1 },
        .{ .src = "\\nsim", .cp = 0x2241 },
        .{ .src = "\\ncong", .cp = 0x2247 },
        .{ .src = "\\napprox", .cp = 0x2249 },
        .{ .src = "\\neq", .cp = 0x2260 },
        .{ .src = "\\notin", .cp = 0x2209 },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const ch = ast.node(ast.child(ast.root, 0));
        try testing.expectEqual(.char, ch.tag);
        try testing.expectEqual(c.cp, @as(u21, @truncate(ch.data)));
    }
}

test "parser: big family emits single-delimiter .left nodes with level data" {
    const cases = [_]struct { src: []const u8, level: u32, cp: u21 }{
        .{ .src = "\\big(", .level = 1, .cp = 0x28 },
        .{ .src = "\\Big[", .level = 2, .cp = 0x5B },
        .{ .src = "\\bigg\\{", .level = 3, .cp = 0x7B },
        .{ .src = "\\Bigg\\langle", .level = 4, .cp = 0x27E8 },
        .{ .src = "\\big\\vert", .level = 1, .cp = 0x7C },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const left = ast.node(ast.child(ast.root, 0));
        try testing.expectEqual(.left, left.tag);
        try testing.expectEqual(c.level, left.data);
        try testing.expectEqual(@as(u16, 1), left.num_children);
        const d = ast.node(ast.child(ast.child(ast.root, 0), 0));
        try testing.expectEqual(.char, d.tag);
        try testing.expectEqual(c.cp, @as(u21, @truncate(d.data)));
    }
}

test "parser: big with a null delimiter renders nothing" {
    var ast = try parseSrc(testing.allocator, "\\big.");
    defer ast.deinit();
    const sp = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.space, sp.tag);
    try testing.expectEqual(@as(u32, 0), sp.data); // zero width
}

test "parser: middle inside left-right packs marker plus codepoint" {
    var ast = try parseSrc(testing.allocator, "\\left\\{ x \\middle| \\frac{x}{2} \\in S \\right\\}");
    defer ast.deinit();
    const left = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.left, left.tag);
    try testing.expectEqual(@as(u32, 0), left.data);
    try testing.expectEqual(@as(u16, 3), left.num_children); // [open, inner, close]
    // the inner row holds [x, middle|, frac, ∈, S]; the middle leaf carries
    // (middle_marker | 0x7C) in its data
    const inner = ast.child(ast.child(ast.root, 0), 1);
    const inode = ast.node(inner);
    const mid = ast.node(ast.child(inner, 1));
    try testing.expectEqual(.char, mid.tag);
    try testing.expectEqual(@as(u21, 0x7C), @as(u21, @truncate(mid.data)));
    try testing.expect(mid.data & middle_marker != 0);
    _ = inode;
}

test "parser: middle outside left-right errors" {
    try testing.expectError(error.UnexpectedMiddle, parseSrc(testing.allocator, "\\middle|"));
    try testing.expectError(error.UnexpectedMiddle, parseSrc(testing.allocator, "x \\middle| y"));
}

test "parser: plain left-right keeps open/inner/close structure" {
    var ast = try parseSrc(testing.allocator, "\\left( \\frac{a}{b} \\right)");
    defer ast.deinit();
    const left = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.left, left.tag);
    try testing.expectEqual(@as(u32, 0), left.data); // auto-sizing fence, not a \big level
    try testing.expectEqual(@as(u16, 3), left.num_children); // [open, inner, close]
    try testing.expectEqual(.char, ast.node(ast.child(ast.child(ast.root, 0), 0)).tag);
    try testing.expectEqual(.row, ast.node(ast.child(ast.child(ast.root, 0), 1)).tag);
    try testing.expectEqual(.char, ast.node(ast.child(ast.child(ast.root, 0), 2)).tag);
}

test "parser: middle inside a braced group within the pair is accepted" {
    var ast = try parseSrc(testing.allocator, "\\left( {a \\middle| b} \\right)");
    defer ast.deinit();
    const left = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.left, left.tag);
    // the pair's inner row holds the group; the group wraps its own inner
    // row [a, middle|, b]
    const inner = ast.child(ast.child(ast.root, 0), 1);
    const grp = ast.node(ast.child(inner, 0));
    try testing.expectEqual(.group, grp.tag);
    const grow = ast.child(ast.child(inner, 0), 0);
    const mid = ast.node(ast.child(grow, 1));
    try testing.expect(mid.data & middle_marker != 0);
}

test "parser: substack splits the braced content on double backslash" {
    var ast = try parseSrc(testing.allocator, "\\substack{i=1 \\\\ j=2}");
    defer ast.deinit();
    const st = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.substack, st.tag);
    // two line children, each a row of three atoms (i, =, 1 / j, =, 2)
    try testing.expectEqual(@as(u16, 2), st.num_children);
    for (0..2) |i| {
        const line = ast.node(ast.child(ast.child(ast.root, 0), i));
        try testing.expectEqual(.row, line.tag);
        try testing.expectEqual(@as(u16, 3), line.num_children);
        try testing.expectEqual(.char, ast.node(ast.child(ast.child(ast.child(ast.root, 0), i), 0)).tag);
    }
}

test "parser: substack allows scripts and trailing separators" {
    // \substack{a^2 \\} → two lines, the second empty
    var ast = try parseSrc(testing.allocator, "\\substack{a^2 \\\\}");
    defer ast.deinit();
    const st = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.substack, st.tag);
    try testing.expectEqual(@as(u16, 2), st.num_children);
    const first = ast.node(ast.child(ast.child(ast.root, 0), 0));
    try testing.expectEqual(.row, first.tag);
    try testing.expectEqual(@as(u16, 1), first.num_children); // the script atom
    try testing.expectEqual(.script, ast.node(ast.child(ast.child(ast.child(ast.root, 0), 0), 0)).tag);
    const second = ast.node(ast.child(ast.child(ast.root, 0), 1));
    try testing.expectEqual(@as(u16, 0), second.num_children); // empty line
}

test "parser: substack requires a braced argument" {
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\substack"));
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\substack a"));
}

test "parser: pmod composes parens, roman mod word, 6mu space and arg" {
    var ast = try parseSrc(testing.allocator, "a \\equiv b \\pmod{n}");
    defer ast.deinit();
    // root row [a, ≡, b, pmod-row]
    const row = ast.node(ast.child(ast.root, 3));
    try testing.expectEqual(.row, row.tag);
    try testing.expectEqual(pmod_row_data, row.data);
    try testing.expectEqual(@as(u16, 5), row.num_children); // (, mod, 6mu, n, )
    const open = ast.node(ast.child(ast.child(ast.root, 3), 0));
    try testing.expectEqual(.char, open.tag);
    try testing.expectEqual(@as(u21, 0x28), @as(u21, @truncate(open.data))); // (
    const word = ast.node(ast.child(ast.child(ast.root, 3), 1));
    try testing.expectEqual(.opname, word.tag);
    const gap = ast.node(ast.child(ast.child(ast.root, 3), 2));
    try testing.expectEqual(.space, gap.tag);
    try testing.expectApproxEqAbs(@as(f32, 6.0 / 18.0), atom.fixedToEm(gap.data), 0.001); // \mkern6mu
    const close = ast.node(ast.child(ast.child(ast.root, 3), 4));
    try testing.expectEqual(.char, close.tag);
    try testing.expectEqual(@as(u21, 0x29), @as(u21, @truncate(close.data))); // )
}

test "parser: pod omits the mod word" {
    var ast = try parseSrc(testing.allocator, "a \\pod{n}");
    defer ast.deinit();
    const row = ast.node(ast.child(ast.root, 1));
    try testing.expectEqual(.row, row.tag);
    try testing.expectEqual(pod_row_data, row.data);
    try testing.expectEqual(@as(u16, 3), row.num_children); // (, n, )
}

test "parser: \\begin{pmatrix} builds an env with delimiters and rows" {
    var ast = try parseSrc(testing.allocator, "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}");
    defer ast.deinit();
    // root row → [env]
    const env = ast.child(ast.root, 0);
    const en = ast.node(env);
    try testing.expectEqual(.env, en.tag);
    // children: [open '(', row1, row2, close ')']
    try testing.expectEqual(@as(u16, 4), en.num_children);
    try testing.expectEqual(.char, ast.node(ast.child(env, 0)).tag);
    try testing.expectEqual(.row, ast.node(ast.child(env, 1)).tag);
    try testing.expectEqual(.row, ast.node(ast.child(env, 2)).tag);
    try testing.expectEqual(.char, ast.node(ast.child(env, 3)).tag);
    try testing.expectEqual(atom.EnvKind.pmatrix, atom.envKind(en.data));
    // each row has two cell rows (cells are parsed as rows)
    try testing.expectEqual(@as(u16, 2), ast.node(ast.child(env, 1)).num_children);
    try testing.expectEqual(@as(u16, 2), ast.node(ast.child(env, 2)).num_children);
    // the delimiter codepoints ride in data
    try testing.expectEqual(@as(u32, 0x28), ast.node(ast.child(env, 0)).data);
    try testing.expectEqual(@as(u32, 0x29), ast.node(ast.child(env, 3)).data);
}

test "parser: array packs the colspec and rules skip column slots" {
    var ast = try parseSrc(testing.allocator, "\\begin{array}{l|r} a & b \\end{array}");
    defer ast.deinit();
    const env = ast.child(ast.root, 0);
    const en = ast.node(env);
    try testing.expectEqual(.env, en.tag);
    try testing.expectEqual(atom.EnvKind.array, atom.envKind(en.data));
    // spec [l, rule, r]: col 0 → l, col 1 → r, rule before col 1
    try testing.expectEqual(@as(usize, 3), atom.envSpecCount(en.data));
    try testing.expectEqual(@as(?u32, atom.EnvBits.col_l), atom.envColSpec(en.data, 0));
    try testing.expectEqual(@as(?u32, atom.EnvBits.col_rule), atom.envColSpec(en.data, 1));
    try testing.expectEqual(@as(?u32, atom.EnvBits.col_r), atom.envColSpec(en.data, 2));
}

test "parser: env errors" {
    try testing.expectError(error.UnknownEnvironment, parseSrc(testing.allocator, "\\begin{foo} x \\end{foo}"));
    try testing.expectError(error.MismatchedEnd, parseSrc(testing.allocator, "\\begin{pmatrix} a \\end{bmatrix}"));
    try testing.expectError(error.UnclosedEnvironment, parseSrc(testing.allocator, "\\begin{pmatrix} a"));
}

test "parser: & outside an environment is an ordinary char" {
    var ast = try parseSrc(testing.allocator, "a & b");
    defer ast.deinit();
    const root = ast.node(ast.root);
    try testing.expectEqual(@as(u16, 3), root.num_children);
    try testing.expectEqual(.char, ast.node(ast.child(ast.root, 1)).tag);
}
