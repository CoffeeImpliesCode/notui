//! ztex.layout.metrics — per-glyph TeX metrics and glue parameters.
//!
//! Bundled static table of LATIN MODERN MATH advance widths at the base font
//! size (10pt), measured with fontTools from latinmodern-math.otf (the font
//! the SVG actually draws; hmtx advance ÷ unitsPerEm × 10, em units × 10).
//! Previously these rows carried Computer-Modern widths transcribed from
//! MicroTeX's font metric tables
//! (src/res/font/{cmr10,cmmi10,cmsy10,cmex10}.def.cpp); the CM advances
//! differ from LM Math (x 0.5715 vs 0.528em, ∑ 1.4444 vs 1.056em, ∫ 0.5556
//! vs 0.665em), so layout advances never matched the rendered glyphs and
//! formulas overflowed the frame. Widths are now the LM Math advance so
//! layout advance == render advance. Height/depth stay the LM Math ink
//! (see `ink_table`); italic corrections and the TeX glue parameters stay
//! the CM values (spacing facts, not render geometry).
//! The static tables need no external font file and answer deterministically,
//! which is what `metrics.default` is; a `FontMetrics` wired to a real font
//! through `FontMetrics.font_glyph` is the caller's own addition and is not
//! covered by that claim.
//!
//! Font selection still follows MicroTeX's "mathnormal" style mapping
//! (tex_param.res.cpp): digits/operators/punctuation → cmr10, Latin letters
//! → cmmi10, roman style (\text, \mathrm) Latin letters → cmr10
//! (table_roman/7/5 — TeX family 0), uppercase Greek → cmr10 (base.def.cpp
//! symbols, TeX slots
//! 161-171; Α/Β are \mathrm A/B → cmmi10 slots 65/66), lowercase Greek →
//! cmmi10 (TeX slots 174-195 of cmmi10_unchanged, which MicroTeX's symbol
//! table points \alpha..\omega at), braces/bar → cmsy10, big operators →
//! cmex10. bin/rel/open/close symbols (arrows, relations, binary ops,
//! delimiters) → cmsy10 (slots 33-63 arrows, 91-126 delimiters, 161-196
//! binops/relations), AMS-only symbols → msam10/msbm10 (∠ ∴ ∵ ≦ ≧ ⩽ ⩾
//! ⊨ ∤ ∦), harpoons/∂/star/triangles/⌢⌣ → cmmi10, ⨅ → stmary10. Symbols
//! TeX composes from parts (≠ ∉ ≢ ≐ ≅ ↦ ↩ ↪ ⋈ ⋯ ″ long arrows) carry the
//! composed box width, noted per row. The WIDTH of every row is now the
//! Latin-Modern-Math advance regardless of which CM font the row maps to;
//! codepoints LM Math does not cover (Ϝ ▹ ◃ ⤒ ⧫, AMS-only, drawn by a
//! fallback font) keep their measured CM width, noted per row.

const std = @import("std");
const atom = @import("ztex.atom");

/// Per-glyph metrics, in points at the base font size (10pt).
pub const Glyph = struct {
    /// Horizontal advance in points at the base size.
    width: f32,
    /// Extent above the baseline in points at the base size.
    height: f32,
    /// Extent below the baseline in points at the base size; non-negative.
    depth: f32,
    /// How far the glyph leans out past its advance in points at the base
    /// size — what a superscript's raise and a script's skew account for.
    italic_correction: f32,
};

/// Drawn-glyph ink extents, in em of the glyph's own font size.
///
/// These are where the ink actually falls, which is narrower than the
/// font's nominal `Glyph` extents. layoutChar and layoutText box every normal
/// glyph by these (× the drawn size), so the box — and the frame or viewBox
/// around it — bounds the ink that is drawn rather than the font's line
/// box. See `glyphInk`.
pub const GlyphInk = struct {
    /// Ink above the baseline, in em of the glyph's font size.
    asc: f32,
    /// Ink below the baseline, in em of the glyph's font size; non-negative.
    desc: f32,
};

/// TeX layout parameters, in points at the base size (10pt). Layout scales
/// every one of them by `size_pt / 10`.
///
/// Values are MicroTeX `tex_param.res.cpp` em values × 10 (plus denom3/sub3
/// and x_height from the standard Computer-Modern parameter set). Each field
/// is one TeX glue parameter, used only by the construction its name names.
/// A caller replacing the table must supply all of them: there are no
/// defaults, and `FontMetrics.glue` is expected to answer for every field.
pub const GlueParams = struct {
    /// Height of the fraction bar's centre above the baseline. Layout centres
    /// a fraction rule, a radical bar and a \overline rule on it, so it is
    /// the one vertical reference every rule aligns to.
    axis_height: f32,
    /// Stroke width of a drawn rule in points: the fraction bar, the radical
    /// bar, the \overline/\underline rule, an array's `|` rule, and the
    /// minimum thickness a \genfrac thickness is not allowed to fall below.
    rule_thickness: f32,
    /// Minimum gap above a numerator, display style.
    num1: f32,
    /// Minimum gap above a numerator, text style (fraction with a rule).
    num2: f32,
    /// Minimum gap above a numerator, script style and for \atop, where the
    /// rule is thinner than the glyphs it separates.
    num3: f32,
    /// Minimum gap below a denominator, display style.
    denom1: f32,
    /// Minimum gap below a denominator, text style.
    denom2: f32,
    /// Minimum gap below a denominator, script style.
    denom3: f32,
    /// Floor for the superscript's baseline raise, display style.
    sup1: f32,
    /// Floor for the superscript's baseline raise, text style.
    sup2: f32,
    /// Floor for the superscript's baseline raise, script style — cramped
    /// contexts use this one instead of sup1/sup2.
    sup3: f32,
    /// Floor for the subscript's baseline drop when only a subscript is
    /// attached to the base.
    sub1: f32,
    /// Floor for the subscript's baseline drop when both scripts are
    /// attached and must clear the superscript.
    sub2: f32,
    /// Floor for the subscript's baseline drop in script style.
    sub3: f32,
    /// How far the superscript's baseline may drop BELOW the base's height;
    /// the effective raise is the larger of "clear the base's ink" and this.
    supdrop: f32,
    /// How far the subscript's baseline may rise ABOVE the base's depth; the
    /// effective drop is the larger of "clear the base's ink" and this.
    subdrop: f32,
    /// Smallest gap left above an over-limit (a big operator's superscript
    /// placed above it).
    bigop_spacing1: f32,
    /// Smallest gap left under an under-limit (a big operator's subscript
    /// placed below it).
    bigop_spacing2: f32,
    /// Largest gap tolerated above an over-limit; a wider gap is closed up
    /// so the script still reads as attached.
    bigop_spacing3: f32,
    /// Largest gap tolerated under an under-limit.
    bigop_spacing4: f32,
    /// Extra padding added above an over-limit and below an under-limit,
    /// beyond the spacing the three fields above bound.
    bigop_spacing5: f32,
    /// Size a display-style formula's scripts are drawn at, as a fraction of
    /// the current size (TeX's `\scriptstyle` factor).
    scriptfactor: f32,
    /// Size a script-style formula's scripts are drawn at, as a fraction of
    /// the current size (TeX's `\scriptscriptstyle` factor).
    scriptscriptfactor: f32,
    /// x-height of the math italic face at the base size, used as the
    /// clearance floor a script must keep from the base's ink.
    x_height: f32,
};

/// Metric lookup interface: four function pointers plus the opaque font they
/// may be wired to, so the bundled static table can be swapped for real
/// fonts.
///
/// A `FontMetrics` is a value, not an owner. Copying it copies the four
/// function pointers and the `font` pointer: a copy ALIASES the same font
/// context and therefore the same mutable caches, so it is not an
/// independent metrics source and must not be deinitialised or torn down
/// separately. Build one, and hand out copies or a `*const` reference.
///
/// Two regimes, told apart by `font`, and they differ in what a caller may do
/// concurrently.
///
/// The bundled `default` has `font == null` and `font_glyph == null`. Its
/// four callbacks are pure functions of the compiled-in tables: they write
/// nothing and allocate nothing, so one `default` may be shared by any number
/// of threads and every copy of it is interchangeable.
///
/// A wired instance — what `ztex.Context` builds — has both set, and its
/// `font_glyph` writes the `FontContext`'s per-(face, codepoint) metric cache
/// through `font` on a miss. That write is unsynchronised, so a wired
/// instance may be read from ONE thread at a time; concurrent `render` calls
/// sharing one `Context` are out of contract. It is still safe to read a
/// wired instance through a `*const`, which is what layout's `fm` parameter
/// is — the pointer is const because the FIELDS are, not because the callee
/// is, and const-casting it to defeat this is a defect.
///
/// Calling convention, common to all four slots. Each is reached through its
/// field and called with the `FontMetrics` it hangs off as the first
/// argument: `self` is borrowed for the duration of that one call and is not
/// retained. Every other argument and every return value is by value, so
/// nothing a callback hands back can dangle — a returned `Glyph` or
/// `GlueParams` is a copy with no borrow in it. `glyph`, `glyphAt` and
/// `hasGlyph` call `font_glyph` only when `font` is non-null; `glue` takes
/// no codepoint or style and returns the whole `GlueParams`, so it is not a
/// `Glyph` producer.
///
/// Threading and reentry. A callback runs on the thread that called its
/// field, inside that call, before the call returns — there is no queue and
/// no cancellation point. It may reenter the same `FontMetrics` it was
/// reached through: the bundled callbacks do not, and a font hook is expected
/// to answer from the font context rather than re-dispatch. Callbacks using a mutable
/// font context must be serialized with every other use of that context; the bundled
/// pure default has no such restriction.
///
/// A callback is a plain function pointer, so the code it names must outlive
/// every `FontMetrics` value that carries it; a `ztex.Context` installs its
/// hook as a module-level function, which outlives the context.
pub const FontMetrics = struct {
    /// The font source behind `font_glyph`, or `null` for the static-table
    /// regime. `ztex.Context` sets it to its own `FontContext`; layout.zig
    /// cannot import font.zig, so the value is opaque here and cast back in
    /// context.zig. The pointee is BORROWED, not owned: this struct never
    /// releases it, and it must stay valid for as long as this `FontMetrics`
    /// is used. A wired instance writes that font's caches during a lookup,
    /// which is why it is single-threaded.
    font: ?*anyopaque = null,
    /// Font-backed glyph lookup consulted before the static tables.
    /// `glyph`, `glyphAt` and `hasGlyph` call it when `font` is non-null; it
    /// returns `null` for a codepoint the face does not map, which is what
    /// lets the fallback chain (font → static table → `glyphEstimate`)
    /// continue. Runs on the calling thread inside the lookup, with `self`
    /// valid only for the call; it may write the font cache `font` points at
    /// and so must not be called concurrently on the same instance.
    /// `null` means no font path at all, whatever `font` says.
    font_glyph: ?*const fn (self: *const FontMetrics, cp: u21, style: atom.CharStyle) ?Glyph = null,
    /// Exact per-glyph metrics for `cp` in `style` at the 10pt base; `null`
    /// when neither the wired font nor the static table has the codepoint.
    /// Required — there is no default.
    glyph: *const fn (self: *const FontMetrics, cp: u21, style: atom.CharStyle) ?Glyph,
    /// Deterministic fallback for any glyph `glyph` does not resolve: an
    /// em-based estimate, never `null`, so layout always has a box. Same
    /// calling convention as `glyph`.
    glyphEstimate: *const fn (self: *const FontMetrics, cp: u21, style: atom.CharStyle) Glyph,
    /// The TeX glue parameters for this style family: a `GlueParams` by
    /// value, every field set. Total and allocation-free, same calling
    /// convention as `glyph` minus the codepoint and style arguments.
    glue: *const fn (self: *const FontMetrics) GlueParams,
};

/// One row of the static metric table: width, height, depth, italic
/// correction, in points at 10pt (em × 10).
const Entry = struct {
    cp: u21,
    w: f32,
    h: f32,
    d: f32,
    ic: f32,
};

/// Static metric table, sorted by `cp` ascending (binary-search invariant).
/// Widths are the Latin-Modern-Math advance (hmtx ÷ unitsPerEm × 10,
/// fontTools on latinmodern-math.otf), so the layout advance matches the
/// rendered glyph; the CM source font per row (cmr10/cmmi10/cmsy10/cmex10,
/// see the header) is retained for provenance only:
///   digits/ops/punct    → cmr10
///   A-Z, a-z            → cmmi10 (mathnormal)
///   braces, |           → cmsy10 (slots 102/103/106)
///   uppercase Greek     → cmr10 (slots 161-171; Α Β = cmmi10 A B)
///   lowercase Greek     → cmmi10 (TeX slots 174-195, \alpha..\omega)
///   big operators       → cmex10 (slots 70/72/80/81/82/83/84/96)
///   math-italic letters → U+1D434..U+1D44D / U+1D44E..U+1D467 (+ U+210E ℎ
///   for h, whose U+1D455 slot is unassigned) carry the LM Math math-italic
///   ADVANCE (the true x = 0.572em vs the upright 0.528em) with the ASCII
///   letter's height/depth/italic-correction. The ASCII rows (U+0041..5A,
///   U+0061..7A) stay: layout maps `.italic` letters to the math-italic cp
///   and falls back to the ASCII entry's metrics when the mapped cp has no
///   row (e.g. a font without the math-italic glyphs).
const table = [_]Entry{
    .{ .cp = 0x21, .w = 2.78, .h = 6.94445, .d = 0, .ic = 0 }, // !
    .{ .cp = 0x23, .w = 8.33, .h = 6.94445, .d = 1.94443, .ic = 0 }, // # \# (cmr10 35)
    .{ .cp = 0x24, .w = 5, .h = 7.5, .d = 0.55555, .ic = 0 }, // $ \$ (cmr10 36)
    .{ .cp = 0x25, .w = 8.33, .h = 7.5, .d = 0.55555, .ic = 0 }, // % \% (cmr10 37)
    .{ .cp = 0x26, .w = 7.78, .h = 6.94445, .d = 0, .ic = 0 }, // & \& (cmr10 38)
    .{ .cp = 0x28, .w = 3.89, .h = 7.5, .d = 2.5, .ic = 0 }, // (
    .{ .cp = 0x29, .w = 3.89, .h = 7.5, .d = 2.5, .ic = 0 }, // )
    .{ .cp = 0x2B, .w = 7.78, .h = 5.83334, .d = 0.83334, .ic = 0 }, // +
    .{ .cp = 0x2C, .w = 2.78, .h = 1.05556, .d = 1.94445, .ic = 0 }, // ,
    .{ .cp = 0x2D, .w = 3.33, .h = 5.83334, .d = 0.83334, .ic = 0 }, // - (cmsy10 minus)
    .{ .cp = 0x2E, .w = 2.78, .h = 1.05556, .d = 0, .ic = 0 }, // .
    .{ .cp = 0x2F, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // /
    .{ .cp = 0x30, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 0
    .{ .cp = 0x31, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 1
    .{ .cp = 0x32, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 2
    .{ .cp = 0x33, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 3
    .{ .cp = 0x34, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 4
    .{ .cp = 0x35, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 5
    .{ .cp = 0x36, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 6
    .{ .cp = 0x37, .w = 5, .h = 6.44444, .d = 0, .ic = 0.13 }, // 7
    .{ .cp = 0x38, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 8
    .{ .cp = 0x39, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 9
    .{ .cp = 0x3A, .w = 2.78, .h = 4.30555, .d = 0, .ic = 0 }, // :
    .{ .cp = 0x3B, .w = 2.78, .h = 4.30555, .d = 1.94445, .ic = 0 }, // ;
    .{ .cp = 0x3C, .w = 7.78, .h = 5.39098, .d = 0.39098, .ic = 0 }, // < (cmmi10)
    .{ .cp = 0x3D, .w = 7.78, .h = 3.66875, .d = -1.33125, .ic = 0 }, // =
    .{ .cp = 0x3E, .w = 7.78, .h = 5.39098, .d = 0.39098, .ic = 0 }, // > (cmmi10)
    .{ .cp = 0x41, .w = 7.5, .h = 6.83332, .d = 0, .ic = 0 }, // A
    .{ .cp = 0x42, .w = 7.08, .h = 6.83332, .d = 0, .ic = 0.50173 }, // B
    .{ .cp = 0x43, .w = 7.22, .h = 6.83332, .d = 0, .ic = 0.715275 }, // C
    .{ .cp = 0x44, .w = 7.64, .h = 6.83332, .d = 0, .ic = 0.27779 }, // D
    .{ .cp = 0x45, .w = 6.81, .h = 6.83332, .d = 0, .ic = 0.57638 }, // E
    .{ .cp = 0x46, .w = 6.53, .h = 6.83332, .d = 0, .ic = 1.3889 }, // F
    .{ .cp = 0x47, .w = 7.85, .h = 6.83332, .d = 0, .ic = 0 }, // G
    .{ .cp = 0x48, .w = 7.5, .h = 6.83332, .d = 0, .ic = 0.81248 }, // H
    .{ .cp = 0x49, .w = 3.61, .h = 6.83332, .d = 0, .ic = 0.78471 }, // I
    .{ .cp = 0x4A, .w = 5.14, .h = 6.83332, .d = 0, .ic = 0.96181 }, // J
    .{ .cp = 0x4B, .w = 7.78, .h = 6.83332, .d = 0, .ic = 0.715275 }, // K
    .{ .cp = 0x4C, .w = 6.25, .h = 6.83332, .d = 0, .ic = 0 }, // L
    .{ .cp = 0x4D, .w = 9.17, .h = 6.83332, .d = 0, .ic = 1.09027 }, // M
    .{ .cp = 0x4E, .w = 7.5, .h = 6.83332, .d = 0, .ic = 1.09027 }, // N
    .{ .cp = 0x4F, .w = 7.78, .h = 6.83332, .d = 0, .ic = 0.27779 }, // O
    .{ .cp = 0x50, .w = 6.81, .h = 6.83332, .d = 0, .ic = 1.3889 }, // P
    .{ .cp = 0x51, .w = 7.78, .h = 6.83332, .d = 1.94445, .ic = 0 }, // Q
    .{ .cp = 0x52, .w = 7.36, .h = 6.83332, .d = 0, .ic = 0.24 }, // R
    .{ .cp = 0x53, .w = 5.56, .h = 6.83332, .d = 0, .ic = 0.57638 }, // S
    .{ .cp = 0x54, .w = 7.22, .h = 6.83332, .d = 0, .ic = 1.3889 }, // T
    .{ .cp = 0x55, .w = 7.5, .h = 6.83332, .d = 0, .ic = 1.09027 }, // U
    .{ .cp = 0x56, .w = 7.5, .h = 6.83332, .d = 0, .ic = 0.08 }, // V
    .{ .cp = 0x57, .w = 10.28, .h = 6.83332, .d = 0, .ic = 0.09 }, // W
    .{ .cp = 0x58, .w = 7.5, .h = 6.83332, .d = 0, .ic = 0.04 }, // X
    .{ .cp = 0x59, .w = 7.5, .h = 6.83332, .d = 0, .ic = 0.16 }, // Y
    .{ .cp = 0x5A, .w = 6.11, .h = 6.83332, .d = 0, .ic = 0.715275 }, // Z
    .{ .cp = 0x5B, .w = 2.78, .h = 7.5, .d = 2.5, .ic = 0.06 }, // [
    .{ .cp = 0x5D, .w = 2.78, .h = 7.5, .d = 2.5, .ic = 0 }, // ]
    .{ .cp = 0x5F, .w = 3.33, .h = 6.67859, .d = 0, .ic = 0.28 }, // _ \_ (cmr10 95)
    .{ .cp = 0x61, .w = 5, .h = 4.30555, .d = 0, .ic = 0.11 }, // a
    .{ .cp = 0x62, .w = 5.56, .h = 6.94445, .d = 0, .ic = 0 }, // b
    .{ .cp = 0x63, .w = 4.44, .h = 4.30555, .d = 0, .ic = 0 }, // c
    .{ .cp = 0x64, .w = 5.56, .h = 6.94445, .d = 0, .ic = 0 }, // d
    .{ .cp = 0x65, .w = 4.44, .h = 4.30555, .d = 0, .ic = 0 }, // e
    .{ .cp = 0x66, .w = 3.06, .h = 6.94445, .d = 1.94445, .ic = 0.79 }, // f
    .{ .cp = 0x67, .w = 5, .h = 4.30555, .d = 1.94445, .ic = 0.13 }, // g
    .{ .cp = 0x68, .w = 5.56, .h = 6.94445, .d = 0, .ic = 0.07 }, // h
    .{ .cp = 0x69, .w = 2.78, .h = 6.59525, .d = 0, .ic = 0 }, // i
    .{ .cp = 0x6A, .w = 3.06, .h = 6.59525, .d = 1.94445, .ic = 0.57243 }, // j
    .{ .cp = 0x6B, .w = 5.28, .h = 6.94445, .d = 0, .ic = 0.11 }, // k
    .{ .cp = 0x6C, .w = 2.78, .h = 6.94445, .d = 0, .ic = 0.05 }, // l
    .{ .cp = 0x6D, .w = 8.33, .h = 4.30555, .d = 0, .ic = 0.08 }, // m
    .{ .cp = 0x6E, .w = 5.56, .h = 4.30555, .d = 0, .ic = 0.07 }, // n
    .{ .cp = 0x6F, .w = 5, .h = 4.30555, .d = 0, .ic = 0 }, // o
    .{ .cp = 0x70, .w = 5.56, .h = 4.30555, .d = 1.94445, .ic = 0 }, // p
    .{ .cp = 0x71, .w = 5.28, .h = 4.30555, .d = 1.94445, .ic = 0.27 }, // q
    .{ .cp = 0x72, .w = 3.92, .h = 4.30555, .d = 0, .ic = 0.27779 }, // r
    .{ .cp = 0x73, .w = 3.94, .h = 4.30555, .d = 0, .ic = 0 }, // s
    .{ .cp = 0x74, .w = 3.89, .h = 6.1508, .d = 0, .ic = 0 }, // t
    .{ .cp = 0x75, .w = 5.56, .h = 4.30555, .d = 0, .ic = 0.07 }, // u
    .{ .cp = 0x76, .w = 5.28, .h = 4.30555, .d = 0, .ic = 0.08 }, // v
    .{ .cp = 0x77, .w = 7.22, .h = 4.30555, .d = 0, .ic = 0.09 }, // w
    .{ .cp = 0x78, .w = 5.28, .h = 4.30555, .d = 0, .ic = 0.16 }, // x
    .{ .cp = 0x79, .w = 5.28, .h = 4.30555, .d = 1.94445, .ic = 0.08 }, // y
    .{ .cp = 0x7A, .w = 4.44, .h = 4.30555, .d = 0, .ic = 0.43981 }, // z
    .{ .cp = 0x7B, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // { (cmsy10)
    .{ .cp = 0x7C, .w = 2.78, .h = 7.5, .d = 2.5, .ic = 0 }, // | (cmsy10)
    .{ .cp = 0x7D, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // } (cmsy10)
    .{ .cp = 0x00A3, .w = 7.5, .h = 6.94444, .d = 0, .ic = 0 }, // £ \pounds (cmti10 36 sterling sign)
    .{ .cp = 0x00A5, .w = 7.5, .h = 6.75, .d = 0, .ic = 0.16 }, // ¥ \yen (msam10 85)
    .{ .cp = 0x00A7, .w = 4.44, .h = 6.94445, .d = 1.94445, .ic = 0 }, // § \S (cmsy10 120)
    .{ .cp = 0x00A9, .w = 6.83, .h = 7.49817, .d = 2.49939, .ic = 0.28 }, // © \copyright (c + OMS circle composite)
    .{ .cp = 0x00AC, .w = 6.67, .h = 4.30555, .d = 0, .ic = 0 }, // ¬ \neg (cmsy10 58)
    .{ .cp = 0x00B1, .w = 7.78, .h = 5.83334, .d = 0.83334, .ic = 0 }, // ± \pm (cmsy10 167)
    .{ .cp = 0x00B6, .w = 6.11, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ¶ \P (cmsy10 123)
    .{ .cp = 0x00B7, .w = 2.78, .h = 2.5, .d = 0, .ic = 0 }, // · middle dot (cmsy10, same as U+22C5 ⋅)
    .{ .cp = 0x00D7, .w = 7.78, .h = 5.83334, .d = 0.83334, .ic = 0 }, // × \times (cmsy10 163)
    .{ .cp = 0x00F0, .w = 5, .h = 6.88889, .d = 0, .ic = 0 }, // ð \eth (msbm10 103)
    .{ .cp = 0x00F7, .w = 7.78, .h = 5.83334, .d = 0.83334, .ic = 0 }, // ÷ \div (cmsy10 165)
    .{ .cp = 0x0131, .w = 2.78, .h = 4.30555, .d = 0, .ic = 0 }, // ı \imath (cmmi10 123)
    .{ .cp = 0x0237, .w = 3.06, .h = 4.30555, .d = 1.94445, .ic = 0 }, // ȷ \jmath (cmmi10 124)
    .{ .cp = 0x391, .w = 7.5, .h = 6.83332, .d = 0, .ic = 0 }, // Α
    .{ .cp = 0x392, .w = 7.08, .h = 6.83332, .d = 0, .ic = 0.50173 }, // Β
    .{ .cp = 0x393, .w = 6.25, .h = 6.83332, .d = 0, .ic = 0 }, // Γ (cmr10 slot 161)
    .{ .cp = 0x394, .w = 8.33, .h = 6.83332, .d = 0, .ic = 0 }, // Δ (cmr10 slot 162)
    .{ .cp = 0x398, .w = 7.78, .h = 6.83332, .d = 0, .ic = 0 }, // Θ (cmr10 slot 163)
    .{ .cp = 0x39B, .w = 6.94, .h = 6.83332, .d = 0, .ic = 0 }, // Λ (cmr10 slot 164)
    .{ .cp = 0x39E, .w = 6.67, .h = 6.83332, .d = 0, .ic = 0 }, // Ξ (cmr10 slot 165)
    .{ .cp = 0x3A0, .w = 7.5, .h = 6.83332, .d = 0, .ic = 0 }, // Π (cmr10 slot 166)
    .{ .cp = 0x3A3, .w = 7.22, .h = 6.83332, .d = 0, .ic = 0 }, // Σ (cmr10 slot 167)
    .{ .cp = 0x3A5, .w = 7.78, .h = 6.83332, .d = 0, .ic = 0 }, // Υ (cmr10 slot 168)
    .{ .cp = 0x3A6, .w = 7.22, .h = 6.83332, .d = 0, .ic = 0 }, // Φ (cmr10 slot 169)
    .{ .cp = 0x3A8, .w = 7.78, .h = 6.83332, .d = 0, .ic = 0 }, // Ψ (cmr10 slot 170)
    .{ .cp = 0x3A9, .w = 7.22, .h = 6.83332, .d = 0, .ic = 0 }, // Ω (cmr10 slot 171)
    .{ .cp = 0x3B1, .w = 6.41, .h = 4.30555, .d = 0, .ic = 0.24 }, // α
    .{ .cp = 0x3B2, .w = 5.58, .h = 6.94445, .d = 1.94445, .ic = 0.52778 }, // β
    .{ .cp = 0x3B3, .w = 5.86, .h = 4.30555, .d = 1.94445, .ic = 0.55555 }, // γ
    .{ .cp = 0x3B4, .w = 4.74, .h = 6.94445, .d = 0, .ic = 0.37847 }, // δ
    .{ .cp = 0x3B5, .w = 5.35, .h = 4.30555, .d = 0, .ic = 0 }, // ε
    .{ .cp = 0x3B6, .w = 5.3, .h = 6.94445, .d = 1.94445, .ic = 0.73784 }, // ζ
    .{ .cp = 0x3B7, .w = 5.3, .h = 4.30555, .d = 1.94445, .ic = 0.35879 }, // η
    .{ .cp = 0x3B8, .w = 4.88, .h = 6.94445, .d = 0, .ic = 0.27779 }, // θ
    .{ .cp = 0x3B9, .w = 3.08, .h = 4.30555, .d = 0, .ic = 0.24 }, // ι
    .{ .cp = 0x3BA, .w = 5.3, .h = 4.30555, .d = 0, .ic = 0.23 }, // κ
    .{ .cp = 0x3BB, .w = 5.37, .h = 6.94445, .d = 0, .ic = 0.54 }, // λ
    .{ .cp = 0x3BC, .w = 5.3, .h = 4.30555, .d = 1.94445, .ic = 0.23 }, // μ
    .{ .cp = 0x3BD, .w = 5.02, .h = 4.30555, .d = 0, .ic = 0.63658 }, // ν
    .{ .cp = 0x3BE, .w = 5.3, .h = 6.94445, .d = 1.94445, .ic = 0.46007 }, // ξ
    .{ .cp = 0x3BF, .w = 5, .h = 4.30555, .d = 0, .ic = 0 }, // ο (cmmi10 111 italic o; CM has no omicron)
    .{ .cp = 0x3C0, .w = 5.86, .h = 4.30555, .d = 0, .ic = 0.35879 }, // π
    .{ .cp = 0x3C1, .w = 4.88, .h = 4.30555, .d = 1.94445, .ic = 0 }, // ρ
    .{ .cp = 0x3C2, .w = 4.74, .h = 4.30555, .d = 0.97223, .ic = 0.7986 }, // ς \varsigma
    .{ .cp = 0x3C3, .w = 5.99, .h = 4.30555, .d = 0, .ic = 0.35879 }, // σ
    .{ .cp = 0x3C4, .w = 5.3, .h = 4.30555, .d = 0, .ic = 1.13195 }, // τ
    .{ .cp = 0x3C5, .w = 5.3, .h = 4.30555, .d = 0, .ic = 0.35879 }, // υ
    .{ .cp = 0x3C6, .w = 6.41, .h = 6.94445, .d = 1.94445, .ic = 0 }, // φ
    .{ .cp = 0x3C7, .w = 6.41, .h = 4.30555, .d = 1.94445, .ic = 0.24 }, // χ
    .{ .cp = 0x3C8, .w = 6.41, .h = 6.94445, .d = 1.94445, .ic = 0.35879 }, // ψ
    .{ .cp = 0x3C9, .w = 6.41, .h = 6.94445, .d = 1.94445, .ic = 0.35879 }, // ω
    .{ .cp = 0x3D1, .w = 5.3, .h = 6.94445, .d = 0, .ic = 0.21 }, // ϑ \vartheta
    .{ .cp = 0x3D5, .w = 6.41, .h = 4.30555, .d = 1.94445, .ic = 0 }, // ϕ \varphi
    .{ .cp = 0x3D6, .w = 8.36, .h = 4.30555, .d = 0, .ic = 0.27779 }, // ϖ \varpi
    .{ .cp = 0x3D8, .w = 7.77781, .h = 5.81665, .d = 0.81665, .ic = 0 }, // Ϝ \digamma (msbm10 122)
    .{ .cp = 0x3F1, .w = 4.88, .h = 4.30555, .d = 1.94445, .ic = 0 }, // ϱ \varrho
    .{ .cp = 0x3F5, .w = 4.14, .h = 4.30555, .d = 0, .ic = 0.35 }, // ϵ \varepsilon
    .{ .cp = 0x2020, .w = 4.44, .h = 6.94445, .d = 1.94445, .ic = 0 }, // † \dagger (cmsy10 121)
    .{ .cp = 0x2021, .w = 4.44, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ‡ \ddagger (cmsy10 122)
    .{ .cp = 0x2026, .w = 8.37, .h = 1.05556, .d = 0, .ic = 0 }, // … \ldots (composite: 3 × \ldotp, cmmi10 58)
    .{ .cp = 0x2032, .w = 3.11, .h = 5.55557, .d = 0, .ic = 0 }, // ′ \prime (cmsy10 48)
    .{ .cp = 0x2033, .w = 5.11, .h = 5.55557, .d = 0, .ic = 0 }, // ″ composite: 2 × \prime
    .{ .cp = 0x2035, .w = 3.11, .h = 5.4986, .d = 0, .ic = 0 }, // ‵ \backprime (msam10 56)
    .{ .cp = 0x210E, .w = 5.76, .h = 6.94445, .d = 0, .ic = 0.07 }, // ℎ
    .{ .cp = 0x210F, .w = 5.76, .h = 6.88889, .d = 0, .ic = 0 }, // ℏ \hbar (msbm10 126)
    .{ .cp = 0x2111, .w = 5.54, .h = 6.94445, .d = 0, .ic = 0.07 }, // ℑ \Im (cmsy10 61)
    .{ .cp = 0x2113, .w = 4.17, .h = 6.94445, .d = 0, .ic = 0.09 }, // ℓ \ell (cmmi10 96)
    .{ .cp = 0x2118, .w = 6.36, .h = 4.30555, .d = 1.94445, .ic = 0 }, // ℘ \wp (cmmi10 125)
    .{ .cp = 0x211C, .w = 8.28, .h = 6.94445, .d = 0, .ic = 0.26 }, // ℜ \Re (cmsy10 60)
    .{ .cp = 0x2127, .w = 7.22, .h = 6.88889, .d = 0, .ic = 0 }, // ℧ \mho (msbm10 102)
    .{ .cp = 0x2135, .w = 6.11, .h = 6.94445, .d = 0, .ic = 0 }, // ℵ \aleph (cmsy10 64)
    .{ .cp = 0x2190, .w = 10, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ← \leftarrow (cmsy10 195)
    .{ .cp = 0x2191, .w = 5, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ↑ \uparrow (cmsy10 34)
    .{ .cp = 0x2192, .w = 10, .h = 3.66875, .d = -1.33125, .ic = 0 }, // → \rightarrow (cmsy10 33)
    .{ .cp = 0x2193, .w = 5, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ↓ \downarrow (cmsy10 35)
    .{ .cp = 0x2194, .w = 10, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ↔ \leftrightarrow (cmsy10 36)
    .{ .cp = 0x2195, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // ↕ \updownarrow (cmsy10 108)
    .{ .cp = 0x2196, .w = 10, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ↖ \nwarrow (cmsy10 45)
    .{ .cp = 0x2197, .w = 10, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ↗ \nearrow (cmsy10 37)
    .{ .cp = 0x2198, .w = 10, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ↘ \searrow (cmsy10 38)
    .{ .cp = 0x2199, .w = 10, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ↙ \swarrow (cmsy10 46)
    .{ .cp = 0x21A3, .w = 11.92, .h = 5.22394, .d = 0.13539, .ic = 0 }, // ↣ \rightarrowtail (msam10 26)
    .{ .cp = 0x21A6, .w = 9.77, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ↦ \mapsto (composite: \mapstochar →)
    .{ .cp = 0x21A9, .w = 9.97, .h = 4.63748, .d = -1.33125, .ic = 0 }, // ↩ \hookleftarrow (← 3\joinrel \rhook)
    .{ .cp = 0x21AA, .w = 9.97, .h = 4.63748, .d = -1.33125, .ic = 0 }, // ↪ \hookrightarrow (\lhook 3\joinrel →)
    .{ .cp = 0x21BC, .w = 10, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ↼ \leftharpoonup (cmmi10 40)
    .{ .cp = 0x21BD, .w = 10.12, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ↽ \leftharpoondown (cmmi10 41)
    .{ .cp = 0x21C0, .w = 10, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ⇀ \rightharpoonup (cmmi10 42)
    .{ .cp = 0x21C1, .w = 10.12, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ⇁ \rightharpoondown (cmmi10 43)
    .{ .cp = 0x21C4, .w = 10.18, .h = 6.75, .d = 1.80801, .ic = 0 }, // ⇄ \rightleftarrows (msam10 29)
    .{ .cp = 0x21D0, .w = 10, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ⇐ \Leftarrow (cmsy10 40)
    .{ .cp = 0x21D1, .w = 6.11, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ⇑ \Uparrow (cmsy10 42)
    .{ .cp = 0x21D2, .w = 10, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ⇒ \Rightarrow (cmsy10 41)
    .{ .cp = 0x21D3, .w = 6.11, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ⇓ \Downarrow (cmsy10 43)
    .{ .cp = 0x21D4, .w = 10, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ⇔ \Leftrightarrow (cmsy10 44)
    .{ .cp = 0x21D5, .w = 6.11, .h = 7.5, .d = 2.5, .ic = 0 }, // ⇕ \Updownarrow (cmsy10 109)
    .{ .cp = 0x2200, .w = 6.66, .h = 6.94445, .d = 0, .ic = 0 }, // ∀ \forall (cmsy10 56)
    .{ .cp = 0x2202, .w = 5.86, .h = 6.94445, .d = 0, .ic = 0.55555 }, // ∂ \partial (cmmi10 64)
    .{ .cp = 0x2203, .w = 5.56, .h = 6.94445, .d = 0, .ic = 0 }, // ∃ \exists (cmsy10 57)
    .{ .cp = 0x2204, .w = 5.56, .h = 6.88889, .d = 0, .ic = 0 }, // ∄ \nexists (msbm10 64)
    .{ .cp = 0x2205, .w = 5, .h = 7.5, .d = 0.55555, .ic = 0 }, // ∅ \emptyset (cmsy10 59)
    .{ .cp = 0x2207, .w = 8.33, .h = 6.83332, .d = 0, .ic = 0 }, // ∇ \nabla (cmsy10 114)
    .{ .cp = 0x2208, .w = 6.67, .h = 5.39098, .d = 0.39098, .ic = 0 }, // ∈ \in (cmsy10 50)
    .{ .cp = 0x2209, .w = 6.67, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ∉ \notin (composite: \not \in)
    .{ .cp = 0x220B, .w = 6.67, .h = 5.39098, .d = 0.39098, .ic = 0 }, // ∋ \ni (cmsy10 51)
    .{ .cp = 0x220C, .w = 6.67, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ∌ \notni (composite: \not \ni)
    .{ .cp = 0x220F, .w = 9.44, .h = 0, .d = 10.00013, .ic = 0 }, // ∏ \prod
    .{ .cp = 0x2210, .w = 9.44, .h = 0, .d = 10.00013, .ic = 0 }, // ∐ \coprod
    .{ .cp = 0x2211, .w = 10.56, .h = 0, .d = 10.00013, .ic = 0 }, // ∑ \sum
    .{ .cp = 0x2212, .w = 7.78, .h = 5.83334, .d = 0.83334, .ic = 0 }, // − minus (cmsy10 161)
    .{ .cp = 0x2213, .w = 7.78, .h = 5.83334, .d = 0.83334, .ic = 0 }, // ∓ \mp (cmsy10 168)
    .{ .cp = 0x2215, .w = 5.68, .h = 6.88889, .d = 1.94443, .ic = 0 }, // ╱ \diagup (msbm10 30)
    .{ .cp = 0x2216, .w = 5.68, .h = 7.5, .d = 2.5, .ic = 0 }, // ∖ \setminus (cmsy10 110)
    .{ .cp = 0x2217, .w = 5, .h = 4.65279, .d = -0.34721, .ic = 0 }, // ∗ \ast (cmsy10 164)
    .{ .cp = 0x2218, .w = 4.12, .h = 4.44446, .d = -0.55554, .ic = 0 }, // ∘ \circ (cmsy10 177)
    .{ .cp = 0x2219, .w = 5, .h = 4.44446, .d = -0.55554, .ic = 0 }, // ∙ \bullet (cmsy10 178)
    .{ .cp = 0x221A, .w = 8.33, .h = 0.39999, .d = 9.60001, .ic = 0 }, // √ \surd (cmsy10 112)
    .{ .cp = 0x221D, .w = 7.78, .h = 4.30555, .d = 0, .ic = 0 }, // ∝ \propto (cmsy10 47)
    .{ .cp = 0x221E, .w = 10, .h = 4.30555, .d = 0, .ic = 0 }, // ∞ \infty (cmsy10 49)
    .{ .cp = 0x2220, .w = 7.78, .h = 6.92241, .d = 0, .ic = 0 }, // ∠ \angle (msam10 92)
    .{ .cp = 0x2221, .w = 7.78, .h = 6.92241, .d = 0, .ic = 0 }, // ∡ \measuredangle (msam10 93)
    .{ .cp = 0x2222, .w = 7.78, .h = 5.22394, .d = 0.35173, .ic = 0 }, // ∢ \sphericalangle (msam10 94)
    .{ .cp = 0x2223, .w = 2.78, .h = 7.5, .d = 2.5, .ic = 0 }, // ∣ \mid (cmsy10 106 \vert)
    .{ .cp = 0x2224, .w = 3.88, .h = 7.41110, .d = 2.51422, .ic = 0 }, // ∤ \nmid (msbm10 45)
    .{ .cp = 0x2225, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // ∥ \parallel (cmsy10 107 \Vert)
    .{ .cp = 0x2226, .w = 5.56, .h = 7.41110, .d = 2.51422, .ic = 0 }, // ∦ \nparallel (msbm10 44)
    .{ .cp = 0x2227, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ∧ \wedge (cmsy10 94)
    .{ .cp = 0x2228, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ∨ \vee (cmsy10 95)
    .{ .cp = 0x2229, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ∩ \cap (cmsy10 92)
    .{ .cp = 0x222A, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ∪ \cup (cmsy10 91)
    .{ .cp = 0x222B, .w = 6.65, .h = 0, .d = 11.11122, .ic = 3.32 }, // ∫ \int
    .{ .cp = 0x222E, .w = 6.65, .h = 0, .d = 11.11122, .ic = 3.32 }, // ∮ \oint
    .{ .cp = 0x2234, .w = 5.16, .h = 6.92241, .d = 0, .ic = 0 }, // ∴ \therefore (msam10 41)
    .{ .cp = 0x2235, .w = 5.16, .h = 6.92241, .d = 0, .ic = 0 }, // ∵ \because (msam10 42)
    .{ .cp = 0x223C, .w = 7.73, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ∼ \sim (cmsy10 187)
    .{ .cp = 0x2240, .w = 2.8, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ≀ \wr (cmsy10 111)
    .{ .cp = 0x2241, .w = 7.73, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ≁ \nsim (msbm10 28)
    .{ .cp = 0x2243, .w = 7.78, .h = 4.63748, .d = -0.36252, .ic = 0 }, // ≃ \simeq (cmsy10 39)
    .{ .cp = 0x2244, .w = 7.78, .h = 6.94444, .d = 1.94443, .ic = 0 }, // ≄ \nsimeq (composite: \not \simeq)
    .{ .cp = 0x2245, .w = 7.78, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ≅ \cong (sim+rule composite)
    .{ .cp = 0x2246, .w = 7.78, .h = 6.94444, .d = 1.94443, .ic = 0 }, // ≆ \simneqq (composite: \not over ≃)
    .{ .cp = 0x2247, .w = 7.78, .h = 7.93829, .d = 3.02742, .ic = 0 }, // ≇ \ncong (msbm10 29)
    .{ .cp = 0x2248, .w = 7.73, .h = 4.83122, .d = -0.16878, .ic = 0 }, // ≈ \approx (cmsy10 188)
    .{ .cp = 0x2249, .w = 7.73, .h = 6.94444, .d = 1.94443, .ic = 0 }, // ≉ \napprox (composite: \not over ≈)
    .{ .cp = 0x224D, .w = 7.78, .h = 4.63748, .d = -0.36252, .ic = 0 }, // ≍ \asymp (cmsy10 179)
    .{ .cp = 0x2250, .w = 7.78, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ≐ \doteq (dot-over-= composite)
    .{ .cp = 0x2260, .w = 7.78, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ≠ \ne (composite: \not over =)
    .{ .cp = 0x2261, .w = 7.78, .h = 4.63748, .d = -0.36252, .ic = 0 }, // ≡ \equiv (cmsy10 180)
    .{ .cp = 0x2262, .w = 7.78, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ≢ \not\equiv (composite: \not over ≡)
    .{ .cp = 0x2264, .w = 7.78, .h = 6.35971, .d = 1.35971, .ic = 0 }, // ≤ \leq (cmsy10 183)
    .{ .cp = 0x2265, .w = 7.78, .h = 6.35971, .d = 1.35971, .ic = 0 }, // ≥ \geq (cmsy10 184)
    .{ .cp = 0x2266, .w = 7.78, .h = 7.55834, .d = 2.55834, .ic = 0 }, // ≦ \leqq (msam10 53)
    .{ .cp = 0x2267, .w = 7.78, .h = 7.55834, .d = 2.55834, .ic = 0 }, // ≧ \geqq (msam10 61)
    .{ .cp = 0x226A, .w = 10, .h = 5.39098, .d = 0.39098, .ic = 0 }, // ≪ \ll (cmsy10 191)
    .{ .cp = 0x226B, .w = 10, .h = 5.39098, .d = 0.39098, .ic = 0 }, // ≫ \gg (cmsy10 192)
    .{ .cp = 0x226D, .w = 7.78, .h = 6.94444, .d = 1.94443, .ic = 0 }, // ≭ \nasymp (composite: \not \asymp)
    .{ .cp = 0x226E, .w = 7.78, .h = 7.05765, .d = 2.05765, .ic = 0 }, // ≮ \nless (msbm10 165)
    .{ .cp = 0x226F, .w = 7.78, .h = 7.05765, .d = 2.05765, .ic = 0 }, // ≯ \ngtr (msbm10 166)
    .{ .cp = 0x2270, .w = 7.78, .h = 7.93829, .d = 3.02742, .ic = 0 }, // ≰ \nleq (msbm10 2)
    .{ .cp = 0x2271, .w = 7.78, .h = 7.93829, .d = 3.02742, .ic = 0 }, // ≱ \ngeq (msbm10 3)
    .{ .cp = 0x227A, .w = 7.78, .h = 5.39098, .d = 0.39098, .ic = 0 }, // ≺ \prec (cmsy10 193)
    .{ .cp = 0x227B, .w = 7.78, .h = 5.39098, .d = 0.39098, .ic = 0 }, // ≻ \succ (cmsy10 194)
    .{ .cp = 0x2280, .w = 7.78, .h = 7.05765, .d = 2.05765, .ic = 0 }, // ⊀ \nprec (msbm10 167)
    .{ .cp = 0x2281, .w = 7.78, .h = 7.05765, .d = 2.05765, .ic = 0 }, // ⊁ \nsucc (msbm10 168)
    .{ .cp = 0x2282, .w = 7.78, .h = 5.39098, .d = 0.39098, .ic = 0 }, // ⊂ \subset (cmsy10 189)
    .{ .cp = 0x2283, .w = 7.78, .h = 5.39098, .d = 0.39098, .ic = 0 }, // ⊃ \supset (cmsy10 190)
    .{ .cp = 0x2284, .w = 7.78, .h = 6.94444, .d = 1.94443, .ic = 0 }, // ⊄ \nsubset (composite: \not \subset)
    .{ .cp = 0x2285, .w = 7.78, .h = 6.94444, .d = 1.94443, .ic = 0 }, // ⊅ \nsupset (composite: \not \supset)
    .{ .cp = 0x2286, .w = 7.78, .h = 6.35971, .d = 1.35971, .ic = 0 }, // ⊆ \subseteq (cmsy10 181)
    .{ .cp = 0x2287, .w = 7.78, .h = 6.35971, .d = 1.35971, .ic = 0 }, // ⊇ \supseteq (cmsy10 182)
    .{ .cp = 0x2288, .w = 7.78, .h = 7.93829, .d = 3.02742, .ic = 0 }, // ⊈ \nsubseteq (msbm10 42)
    .{ .cp = 0x2289, .w = 7.78, .h = 7.93829, .d = 3.02742, .ic = 0 }, // ⊉ \nsupseteq (msbm10 43)
    .{ .cp = 0x228E, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ⊎ \uplus (cmsy10 93)
    .{ .cp = 0x2291, .w = 7.78, .h = 6.35971, .d = 1.35971, .ic = 0 }, // ⊑ \sqsubseteq (cmsy10 118)
    .{ .cp = 0x2292, .w = 7.78, .h = 6.35971, .d = 1.35971, .ic = 0 }, // ⊒ \sqsupseteq (cmsy10 119)
    .{ .cp = 0x2293, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ⊓ \sqcap (cmsy10 117)
    .{ .cp = 0x2294, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ⊔ \sqcup (cmsy10 116)
    .{ .cp = 0x2295, .w = 7.78, .h = 5.83334, .d = 0.83334, .ic = 0 }, // ⊕ \oplus (cmsy10 169)
    .{ .cp = 0x2296, .w = 7.78, .h = 5.83334, .d = 0.83334, .ic = 0 }, // ⊖ \ominus (cmsy10 170)
    .{ .cp = 0x2297, .w = 7.78, .h = 5.83334, .d = 0.83334, .ic = 0 }, // ⊗ \otimes (cmsy10 171)
    .{ .cp = 0x2298, .w = 7.78, .h = 5.83334, .d = 0.83334, .ic = 0 }, // ⊘ \oslash (cmsy10 174)
    .{ .cp = 0x2299, .w = 7.78, .h = 5.83334, .d = 0.83334, .ic = 0 }, // ⊙ \odot (cmsy10 175)
    .{ .cp = 0x22A2, .w = 6.11, .h = 6.94445, .d = 0, .ic = 0 }, // ⊢ \vdash (cmsy10 96)
    .{ .cp = 0x22A3, .w = 6.11, .h = 6.94445, .d = 0, .ic = 0 }, // ⊣ \dashv (cmsy10 97)
    .{ .cp = 0x22A4, .w = 7.78, .h = 6.94445, .d = 0, .ic = 0 }, // ⊤ \top (cmsy10 62)
    .{ .cp = 0x22A5, .w = 7.78, .h = 6.94445, .d = 0, .ic = 0 }, // ⊥ \perp (cmsy10 63)
    .{ .cp = 0x22A8, .w = 6.12, .h = 6.92241, .d = 0, .ic = 0 }, // ⊨ \vDash (msam10 178)
    .{ .cp = 0x22AC, .w = 5.65, .h = 6.88889, .d = 0, .ic = 0 }, // ⊬ \nvdash (msbm10 48)
    .{ .cp = 0x22C0, .w = 8.33, .h = 0, .d = 10.00013, .ic = 0 }, // ⋀ \bigwedge (cmex10 86)
    .{ .cp = 0x22C1, .w = 8.33, .h = 0, .d = 10.00013, .ic = 0 }, // ⋁ \bigvee (cmex10 87)
    .{ .cp = 0x22C2, .w = 8.33, .h = 0, .d = 10.00013, .ic = 0 }, // ⋂ \bigcap
    .{ .cp = 0x22C3, .w = 8.33, .h = 0, .d = 10.00013, .ic = 0 }, // ⋃ \bigcup
    .{ .cp = 0x22C4, .w = 5, .h = 4.44446, .d = -0.55554, .ic = 0.08 }, // ⋄ \diamond (cmsy10 166)
    .{ .cp = 0x22C5, .w = 2.78, .h = 2.5, .d = 0, .ic = 0 }, // ⋅ \cdot (cmsy10 middle dot)
    .{ .cp = 0x22C6, .w = 5, .h = 4.65279, .d = -0.34721, .ic = 0.25 }, // ⋆ \star (cmmi10 63)
    .{ .cp = 0x22C8, .w = 6.23, .h = 4.65279, .d = -0.34721, .ic = 0 }, // ⋈ \bowtie (composite: ▹ \joinrel ◃)
    .{ .cp = 0x22D8, .w = 12.85, .h = 5.4986, .d = 0.35173, .ic = 0 }, // ⋘ \lll (msam10 110)
    .{ .cp = 0x22D9, .w = 12.85, .h = 5.4986, .d = 0.35173, .ic = 0 }, // ⋙ \ggg (msam10 111)
    .{ .cp = 0x22E0, .w = 7.38, .h = 7.93829, .d = 3.02742, .ic = 0 }, // ⋠ \npreceq (msbm10 177)
    .{ .cp = 0x22E1, .w = 7.38, .h = 7.93829, .d = 3.02742, .ic = 0 }, // ⋡ \nsucceq (msbm10 178)
    .{ .cp = 0x22EF, .w = 7.76, .h = 4.44446, .d = -0.55554, .ic = 0 }, // ⋯ \cdots (composite: 3 × cdot)
    .{ .cp = 0x2308, .w = 4.44, .h = 7.5, .d = 2.5, .ic = 0 }, // ⌈ \lceil (cmsy10 100)
    .{ .cp = 0x2309, .w = 4.44, .h = 7.5, .d = 2.5, .ic = 0 }, // ⌉ \rceil (cmsy10 101)
    .{ .cp = 0x230A, .w = 4.44, .h = 7.5, .d = 2.5, .ic = 0 }, // ⌊ \lfloor (cmsy10 98)
    .{ .cp = 0x230B, .w = 4.44, .h = 7.5, .d = 2.5, .ic = 0 }, // ⌋ \rfloor (cmsy10 99)
    .{ .cp = 0x2322, .w = 10, .h = 3.57640, .d = -1.42360, .ic = 0 }, // ⌢ \frown (cmmi10 95)
    .{ .cp = 0x2323, .w = 10, .h = 3.57640, .d = -1.42360, .ic = 0 }, // ⌣ \smile (cmmi10 94)
    .{ .cp = 0x25A0, .w = 7.78, .h = 6.75, .d = 0, .ic = 0 }, // ■ \blacksquare (msam10 4)
    .{ .cp = 0x25A1, .w = 7.78, .h = 6.75, .d = 0, .ic = 0 }, // □ \square (msam10 3)
    .{ .cp = 0x25B3, .w = 9.68, .h = 6.94445, .d = 1.94445, .ic = 0 }, // △ \triangle (cmsy10 52)
    .{ .cp = 0x25B9, .w = 5.00002, .h = 4.65279, .d = -0.34721, .ic = 0 }, // ▹ \triangleright (cmmi10 46)
    .{ .cp = 0x25BD, .w = 9.68, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ▽ \bigtriangledown (cmsy10 53)
    .{ .cp = 0x25C3, .w = 5.00002, .h = 4.65279, .d = -0.34721, .ic = 0 }, // ◃ \triangleleft (cmmi10 47)
    .{ .cp = 0x25CA, .w = 5.72, .h = 6.92241, .d = 1.11112, .ic = 0 }, // ◊ \lozenge (msam10 6)
    .{ .cp = 0x25CB, .w = 7.96, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ○ \bigcirc (cmsy10 176)
    .{ .cp = 0x2660, .w = 7.78, .h = 6.94445, .d = 1.29629, .ic = 0 }, // ♠ \spadesuit (cmsy10 127)
    .{ .cp = 0x2661, .w = 7.78, .h = 6.94445, .d = 1.29629, .ic = 0 }, // ♡ \heartsuit (cmsy10 126)
    .{ .cp = 0x2662, .w = 7.78, .h = 6.94445, .d = 1.29629, .ic = 0 }, // ♢ \diamondsuit (cmsy10 125)
    .{ .cp = 0x2663, .w = 7.78, .h = 6.94445, .d = 1.29629, .ic = 0 }, // ♣ \clubsuit (cmsy10 124)
    .{ .cp = 0x266D, .w = 3.88, .h = 7.5, .d = 0, .ic = 0 }, // ♭ \flat (cmmi10 91)
    .{ .cp = 0x266E, .w = 3.88, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ♮ \natural (cmmi10 92)
    .{ .cp = 0x266F, .w = 3.88, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ♯ \sharp (cmmi10 93)
    .{ .cp = 0x2713, .w = 8.33, .h = 6.92241, .d = 0, .ic = 0 }, // ✓ \checkmark (msam10 88)
    .{ .cp = 0x27E8, .w = 3.89, .h = 7.5, .d = 2.5, .ic = 0 }, // ⟨ \langle (cmsy10 104)
    .{ .cp = 0x27E9, .w = 3.89, .h = 7.5, .d = 2.5, .ic = 0 }, // ⟩ \rangle (cmsy10 105)
    .{ .cp = 0x27F5, .w = 14.63, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ⟵ \longleftarrow (← \joinrel \relbar)
    .{ .cp = 0x27F6, .w = 14.63, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ⟶ \longrightarrow (relbar joinrel)
    .{ .cp = 0x27F7, .w = 14.42, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ⟷ longleftrightarrow (joinrel)
    .{ .cp = 0x27F8, .w = 14.57, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ⟸ \Longleftarrow (⇐ \joinrel \Relbar)
    .{ .cp = 0x27F9, .w = 14.57, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ⟹ \Longrightarrow (Relbar joinrel)
    .{ .cp = 0x27FA, .w = 15.34, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ⟺ \Longleftrightarrow (joinrel)
    .{ .cp = 0x2912, .w = 5.00002, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ⤒ \baruparrow (bar over ↑, cmsy10 34)
    .{ .cp = 0x29EB, .w = 6.66669, .h = 6.92241, .d = 1.11112, .ic = 0 }, // ⧫ \blacklozenge (msam10 7)
    .{ .cp = 0x2A00, .w = 11.11, .h = 0, .d = 10.00013, .ic = 0 }, // ⨀ \bigodot (cmex10 74)
    .{ .cp = 0x2A01, .w = 11.11, .h = 0, .d = 10.00013, .ic = 0 }, // ⨁ \bigoplus (cmex10 76)
    .{ .cp = 0x2A02, .w = 11.11, .h = 0, .d = 10.00013, .ic = 0 }, // ⨂ \bigotimes (cmex10 78)
    .{ .cp = 0x2A04, .w = 8.33, .h = 0, .d = 10.00013, .ic = 0 }, // ⨄ \biguplus (cmex10 85)
    .{ .cp = 0x2A05, .w = 8.33, .h = 0, .d = 10.00013, .ic = 0 }, // ⨅ \bigsqcap (stmary10 132)
    .{ .cp = 0x2A06, .w = 8.33, .h = 0, .d = 10.00013, .ic = 0 }, // ⨆ \bigsqcup
    .{ .cp = 0x2A2F, .w = 7.78, .h = 5.83334, .d = 0.83334, .ic = 0 }, // ⨯ \times (cmsy10 2)
    .{ .cp = 0x2A3F, .w = 7.5, .h = 6.83332, .d = 0, .ic = 0 }, // ⨿ \amalg (cmsy10 113)
    .{ .cp = 0x2A7D, .w = 7.78, .h = 6.36665, .d = 1.36665, .ic = 0 }, // ⩽ \leqslant (msam10 54)
    .{ .cp = 0x2A7E, .w = 7.78, .h = 6.36665, .d = 1.36665, .ic = 0 }, // ⩾ \geqslant (msam10 62)
    .{ .cp = 0x2AAF, .w = 7.78, .h = 6.35971, .d = 1.35971, .ic = 0 }, // ⪯ \preceq (cmsy10 185)
    .{ .cp = 0x2AB0, .w = 7.78, .h = 6.35971, .d = 1.35971, .ic = 0 }, // ⪰ \succeq (cmsy10 186)
    .{ .cp = 0x1D434, .w = 7.5, .h = 6.83332, .d = 0, .ic = 0 }, // 𝐴
    .{ .cp = 0x1D435, .w = 7.59, .h = 6.83332, .d = 0, .ic = 0.50173 }, // 𝐵
    .{ .cp = 0x1D436, .w = 7.15, .h = 6.83332, .d = 0, .ic = 0.715275 }, // 𝐶
    .{ .cp = 0x1D437, .w = 8.28, .h = 6.83332, .d = 0, .ic = 0.27779 }, // 𝐷
    .{ .cp = 0x1D438, .w = 7.38, .h = 6.83332, .d = 0, .ic = 0.57638 }, // 𝐸
    .{ .cp = 0x1D439, .w = 6.43, .h = 6.83332, .d = 0, .ic = 1.3889 }, // 𝐹
    .{ .cp = 0x1D43A, .w = 7.86, .h = 6.83332, .d = 0, .ic = 0 }, // 𝐺
    .{ .cp = 0x1D43B, .w = 8.31, .h = 6.83332, .d = 0, .ic = 0.81248 }, // 𝐻
    .{ .cp = 0x1D43C, .w = 4.4, .h = 6.83332, .d = 0, .ic = 0.78471 }, // 𝐼
    .{ .cp = 0x1D43D, .w = 5.55, .h = 6.83332, .d = 0, .ic = 0.96181 }, // 𝐽
    .{ .cp = 0x1D43E, .w = 8.49, .h = 6.83332, .d = 0, .ic = 0.715275 }, // 𝐾
    .{ .cp = 0x1D43F, .w = 6.81, .h = 6.83332, .d = 0, .ic = 0 }, // 𝐿
    .{ .cp = 0x1D440, .w = 9.7, .h = 6.83332, .d = 0, .ic = 1.09027 }, // 𝑀
    .{ .cp = 0x1D441, .w = 8.03, .h = 6.83332, .d = 0, .ic = 1.09027 }, // 𝑁
    .{ .cp = 0x1D442, .w = 7.63, .h = 6.83332, .d = 0, .ic = 0.27779 }, // 𝑂
    .{ .cp = 0x1D443, .w = 6.42, .h = 6.83332, .d = 0, .ic = 1.3889 }, // 𝑃
    .{ .cp = 0x1D444, .w = 7.91, .h = 6.83332, .d = 1.94445, .ic = 0 }, // 𝑄
    .{ .cp = 0x1D445, .w = 7.59, .h = 6.83332, .d = 0, .ic = 0.24 }, // 𝑅
    .{ .cp = 0x1D446, .w = 6.13, .h = 6.83332, .d = 0, .ic = 0.57638 }, // 𝑆
    .{ .cp = 0x1D447, .w = 5.84, .h = 6.83332, .d = 0, .ic = 1.3889 }, // 𝑇
    .{ .cp = 0x1D448, .w = 6.83, .h = 6.83332, .d = 0, .ic = 1.09027 }, // 𝑈
    .{ .cp = 0x1D449, .w = 5.83, .h = 6.83332, .d = 0, .ic = 0.08 }, // 𝑉
    .{ .cp = 0x1D44A, .w = 9.44, .h = 6.83332, .d = 0, .ic = 0.09 }, // 𝑊
    .{ .cp = 0x1D44B, .w = 8.28, .h = 6.83332, .d = 0, .ic = 0.04 }, // 𝑋
    .{ .cp = 0x1D44C, .w = 5.81, .h = 6.83332, .d = 0, .ic = 0.16 }, // 𝑌
    .{ .cp = 0x1D44D, .w = 6.83, .h = 6.83332, .d = 0, .ic = 0.715275 }, // 𝑍
    .{ .cp = 0x1D44E, .w = 5.29, .h = 4.30555, .d = 0, .ic = 0.11 }, // 𝑎
    .{ .cp = 0x1D44F, .w = 4.29, .h = 6.94445, .d = 0, .ic = 0 }, // 𝑏
    .{ .cp = 0x1D450, .w = 4.33, .h = 4.30555, .d = 0, .ic = 0 }, // 𝑐
    .{ .cp = 0x1D451, .w = 5.2, .h = 6.94445, .d = 0, .ic = 0 }, // 𝑑
    .{ .cp = 0x1D452, .w = 4.66, .h = 4.30555, .d = 0, .ic = 0 }, // 𝑒
    .{ .cp = 0x1D453, .w = 4.9, .h = 6.94445, .d = 1.94445, .ic = 0.79 }, // 𝑓
    .{ .cp = 0x1D454, .w = 4.77, .h = 4.30555, .d = 1.94445, .ic = 0.13 }, // 𝑔
    .{ .cp = 0x1D456, .w = 3.45, .h = 6.59525, .d = 0, .ic = 0 }, // 𝑖
    .{ .cp = 0x1D457, .w = 4.12, .h = 6.59525, .d = 1.94445, .ic = 0.57243 }, // 𝑗
    .{ .cp = 0x1D458, .w = 5.21, .h = 6.94445, .d = 0, .ic = 0.11 }, // 𝑘
    .{ .cp = 0x1D459, .w = 2.98, .h = 6.94445, .d = 0, .ic = 0.05 }, // 𝑙
    .{ .cp = 0x1D45A, .w = 8.78, .h = 4.30555, .d = 0, .ic = 0.08 }, // 𝑚
    .{ .cp = 0x1D45B, .w = 6, .h = 4.30555, .d = 0, .ic = 0.07 }, // 𝑛
    .{ .cp = 0x1D45C, .w = 4.85, .h = 4.30555, .d = 0, .ic = 0 }, // 𝑜
    .{ .cp = 0x1D45D, .w = 5.03, .h = 4.30555, .d = 1.94445, .ic = 0 }, // 𝑝
    .{ .cp = 0x1D45E, .w = 4.46, .h = 4.30555, .d = 1.94445, .ic = 0.27 }, // 𝑞
    .{ .cp = 0x1D45F, .w = 4.51, .h = 4.30555, .d = 0, .ic = 0.27779 }, // 𝑟
    .{ .cp = 0x1D460, .w = 4.69, .h = 4.30555, .d = 0, .ic = 0 }, // 𝑠
    .{ .cp = 0x1D461, .w = 3.61, .h = 6.1508, .d = 0, .ic = 0 }, // 𝑡
    .{ .cp = 0x1D462, .w = 5.72, .h = 4.30555, .d = 0, .ic = 0.07 }, // 𝑢
    .{ .cp = 0x1D463, .w = 4.85, .h = 4.30555, .d = 0, .ic = 0.08 }, // 𝑣
    .{ .cp = 0x1D464, .w = 7.16, .h = 4.30555, .d = 0, .ic = 0.09 }, // 𝑤
    .{ .cp = 0x1D465, .w = 5.72, .h = 4.30555, .d = 0, .ic = 0.16 }, // 𝑥
    .{ .cp = 0x1D466, .w = 4.9, .h = 4.30555, .d = 1.94445, .ic = 0.08 }, // 𝑦
    .{ .cp = 0x1D467, .w = 4.65, .h = 4.30555, .d = 0, .ic = 0.43981 }, // 𝑧
    // Math-italic partial U+1D715 (the math-style form of \partial, mapped
    // by layout.mathItalic like the letters): LM Math advance 0.531em (the
    // upright U+2202 is 0.586em — the DIFFERENT glyph the reference emits),
    // h/d/ic from the U+2202 rows (same cmmi10 design slot).
    .{ .cp = 0x1D715, .w = 5.31, .h = 6.94445, .d = 0, .ic = 0.55555 }, // 𝜕
};

/// Roman-style metrics for Latin letters A-Z a-z, used when `style`
/// is `.roman` (`\text`, `\mathrm`). TeX typesets roman text in family 0 =
/// cmr10; the main `table` stores the math-italic rows for the same
/// codepoints, so roman style must look here instead. Widths are the
/// Latin-Modern-Math advance (same convention as `table`; LM Math has one
/// upright/italic shape, so roman and math share the advance). Transcribed
/// from cmr10 TFM originally (em × 10), sorted by `cp` (binary-search
/// invariant). Glyphs in other styles/roles stay in `table` (digits, ops,
/// punct and uppercase Greek are already cmr10 there).
const table_roman = [_]Entry{
    .{ .cp = 0x0041, .w = 7.5, .h = 6.83332, .d = 0, .ic = 0 }, // A
    .{ .cp = 0x0042, .w = 7.08, .h = 6.83332, .d = 0, .ic = 0 }, // B
    .{ .cp = 0x0043, .w = 7.22, .h = 6.83332, .d = 0, .ic = 0 }, // C
    .{ .cp = 0x0044, .w = 7.64, .h = 6.83332, .d = 0, .ic = 0 }, // D
    .{ .cp = 0x0045, .w = 6.81, .h = 6.83332, .d = 0, .ic = 0 }, // E
    .{ .cp = 0x0046, .w = 6.53, .h = 6.83332, .d = 0, .ic = 0 }, // F
    .{ .cp = 0x0047, .w = 7.85, .h = 6.83332, .d = 0, .ic = 0 }, // G
    .{ .cp = 0x0048, .w = 7.5, .h = 6.83332, .d = 0, .ic = 0 }, // H
    .{ .cp = 0x0049, .w = 3.61, .h = 6.83332, .d = 0, .ic = 0 }, // I
    .{ .cp = 0x004A, .w = 5.14, .h = 6.83332, .d = 0, .ic = 0 }, // J
    .{ .cp = 0x004B, .w = 7.78, .h = 6.83332, .d = 0, .ic = 0 }, // K
    .{ .cp = 0x004C, .w = 6.25, .h = 6.83332, .d = 0, .ic = 0 }, // L
    .{ .cp = 0x004D, .w = 9.17, .h = 6.83332, .d = 0, .ic = 0 }, // M
    .{ .cp = 0x004E, .w = 7.5, .h = 6.83332, .d = 0, .ic = 0 }, // N
    .{ .cp = 0x004F, .w = 7.78, .h = 6.83332, .d = 0, .ic = 0 }, // O
    .{ .cp = 0x0050, .w = 6.81, .h = 6.83332, .d = 0, .ic = 0 }, // P
    .{ .cp = 0x0051, .w = 7.78, .h = 6.83332, .d = 1.94445, .ic = 0 }, // Q
    .{ .cp = 0x0052, .w = 7.36, .h = 6.83332, .d = 0, .ic = 0.24 }, // R
    .{ .cp = 0x0053, .w = 5.56, .h = 6.83332, .d = 0, .ic = 0 }, // S
    .{ .cp = 0x0054, .w = 7.22, .h = 6.83332, .d = 0, .ic = 0 }, // T
    .{ .cp = 0x0055, .w = 7.5, .h = 6.83332, .d = 0, .ic = 0 }, // U
    .{ .cp = 0x0056, .w = 7.5, .h = 6.83332, .d = 0, .ic = 0.08 }, // V
    .{ .cp = 0x0057, .w = 10.28, .h = 6.83332, .d = 0, .ic = 0.09 }, // W
    .{ .cp = 0x0058, .w = 7.5, .h = 6.83332, .d = 0, .ic = 0.04 }, // X
    .{ .cp = 0x0059, .w = 7.5, .h = 6.83332, .d = 0, .ic = 0.16 }, // Y
    .{ .cp = 0x005A, .w = 6.11, .h = 6.83332, .d = 0, .ic = 0 }, // Z
    .{ .cp = 0x0061, .w = 5, .h = 4.30555, .d = 0, .ic = 0.11 }, // a
    .{ .cp = 0x0062, .w = 5.56, .h = 6.94445, .d = 0, .ic = 0 }, // b
    .{ .cp = 0x0063, .w = 4.44, .h = 4.30555, .d = 0, .ic = 0 }, // c
    .{ .cp = 0x0064, .w = 5.56, .h = 6.94445, .d = 0, .ic = 0 }, // d
    .{ .cp = 0x0065, .w = 4.44, .h = 4.30555, .d = 0, .ic = 0 }, // e
    .{ .cp = 0x0066, .w = 3.06, .h = 6.94445, .d = 0, .ic = 0.79 }, // f
    .{ .cp = 0x0067, .w = 5, .h = 4.30555, .d = 1.94445, .ic = 0.13 }, // g
    .{ .cp = 0x0068, .w = 5.56, .h = 6.94445, .d = 0, .ic = 0.07 }, // h
    .{ .cp = 0x0069, .w = 2.78, .h = 6.67859, .d = 0, .ic = 0 }, // i
    .{ .cp = 0x006A, .w = 3.06, .h = 6.67859, .d = 1.94445, .ic = 0 }, // j
    .{ .cp = 0x006B, .w = 5.28, .h = 6.94445, .d = 0, .ic = 0.11 }, // k
    .{ .cp = 0x006C, .w = 2.78, .h = 6.94445, .d = 0, .ic = 0.05 }, // l
    .{ .cp = 0x006D, .w = 8.33, .h = 4.30555, .d = 0, .ic = 0.08 }, // m
    .{ .cp = 0x006E, .w = 5.56, .h = 4.30555, .d = 0, .ic = 0.07 }, // n
    .{ .cp = 0x006F, .w = 5, .h = 4.30555, .d = 0, .ic = 0 }, // o
    .{ .cp = 0x0070, .w = 5.56, .h = 4.30555, .d = 1.94445, .ic = 0 }, // p
    .{ .cp = 0x0071, .w = 5.28, .h = 4.30555, .d = 1.94445, .ic = 0.27 }, // q
    .{ .cp = 0x0072, .w = 3.92, .h = 4.30555, .d = 0, .ic = 0 }, // r
    .{ .cp = 0x0073, .w = 3.94, .h = 4.30555, .d = 0, .ic = 0 }, // s
    .{ .cp = 0x0074, .w = 3.89, .h = 6.1508, .d = 0, .ic = 0 }, // t
    .{ .cp = 0x0075, .w = 5.56, .h = 4.30555, .d = 0, .ic = 0.07 }, // u
    .{ .cp = 0x0076, .w = 5.28, .h = 4.30555, .d = 0, .ic = 0.08 }, // v
    .{ .cp = 0x0077, .w = 7.22, .h = 4.30555, .d = 0, .ic = 0.09 }, // w
    .{ .cp = 0x0078, .w = 5.28, .h = 4.30555, .d = 0, .ic = 0.16 }, // x
    .{ .cp = 0x0079, .w = 5.28, .h = 4.30555, .d = 1.94445, .ic = 0.08 }, // y
    .{ .cp = 0x007A, .w = 4.44, .h = 4.30555, .d = 0, .ic = 0 }, // z
};

/// Script-size metric table (design size 7pt), same convention as `table`:
/// TFM em-relative values x 10, so the layout's `size_pt/10` scaling yields
/// the real 7pt points. LM Math is a single 10pt-design OTF with no optical
/// 7pt variant, so every row carries the same LM Math advance as `table`
/// (em × 10) and the layout's size_pt/10 factor produces exactly LM advance
/// × 0.7 at 7pt — linear scaling replaces the old optical cmr7/cmmi7/cmsy7
/// values, which are kept in history. Sorted by `cp`.
const table7 = [_]Entry{
    .{ .cp = 0x21, .w = 2.78, .h = 6.94445, .d = 0, .ic = 0 }, // !
    .{ .cp = 0x28, .w = 3.89, .h = 7.5, .d = 2.5, .ic = 0 }, // (
    .{ .cp = 0x29, .w = 3.89, .h = 7.5, .d = 2.5, .ic = 0 }, // )
    .{ .cp = 0x2B, .w = 7.78, .h = 6.19049, .d = 1.19049, .ic = 0 }, // +
    .{ .cp = 0x2C, .w = 2.78, .h = 1.1508, .d = 1.94445, .ic = 0 }, // ,
    .{ .cp = 0x2D, .w = 3.33, .h = 6.19049, .d = 1.19049, .ic = 0 }, // - (cmsy10 minus)
    .{ .cp = 0x2E, .w = 2.78, .h = 1.1508, .d = 0, .ic = 0 }, // .
    .{ .cp = 0x2F, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // /
    .{ .cp = 0x30, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 0
    .{ .cp = 0x31, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 1
    .{ .cp = 0x32, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 2
    .{ .cp = 0x33, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 3
    .{ .cp = 0x34, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 4
    .{ .cp = 0x35, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 5
    .{ .cp = 0x36, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 6
    .{ .cp = 0x37, .w = 5, .h = 6.44444, .d = 0, .ic = 0.13 }, // 7
    .{ .cp = 0x38, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 8
    .{ .cp = 0x39, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 9
    .{ .cp = 0x3A, .w = 2.78, .h = 4.30555, .d = 0, .ic = 0 }, // :
    .{ .cp = 0x3B, .w = 2.78, .h = 4.30555, .d = 1.94445, .ic = 0 }, // ;
    .{ .cp = 0x3C, .w = 7.78, .h = 5.75675, .d = 0.75675, .ic = 0 }, // < (cmmi10)
    .{ .cp = 0x3D, .w = 7.78, .h = 3.84079, .d = -1.15921, .ic = 0 }, // =
    .{ .cp = 0x3E, .w = 7.78, .h = 5.75675, .d = 0.75675, .ic = 0 }, // > (cmmi10)
    .{ .cp = 0x41, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0 }, // A
    .{ .cp = 0x42, .w = 7.08, .h = 6.83334, .d = 0, .ic = 0.48684 }, // B
    .{ .cp = 0x43, .w = 7.22, .h = 6.83334, .d = 0, .ic = 0.70038 }, // C
    .{ .cp = 0x44, .w = 7.64, .h = 6.83334, .d = 0, .ic = 0.30755 }, // D
    .{ .cp = 0x45, .w = 6.81, .h = 6.83334, .d = 0, .ic = 0.5496 }, // E
    .{ .cp = 0x46, .w = 6.53, .h = 6.83334, .d = 0, .ic = 1.53771 }, // F
    .{ .cp = 0x47, .w = 7.85, .h = 6.83334, .d = 0, .ic = 0 }, // G
    .{ .cp = 0x48, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0.76486 }, // H
    .{ .cp = 0x49, .w = 3.61, .h = 6.83334, .d = 0, .ic = 0.77728 }, // I
    .{ .cp = 0x4A, .w = 5.14, .h = 6.83334, .d = 0, .ic = 0.94345 }, // J
    .{ .cp = 0x4B, .w = 7.78, .h = 6.83334, .d = 0, .ic = 0.70038 }, // K
    .{ .cp = 0x4C, .w = 6.25, .h = 6.83334, .d = 0, .ic = 0 }, // L
    .{ .cp = 0x4D, .w = 9.17, .h = 6.83334, .d = 0, .ic = 1.07241 }, // M
    .{ .cp = 0x4E, .w = 7.5, .h = 6.83334, .d = 0, .ic = 1.07241 }, // N
    .{ .cp = 0x4F, .w = 7.78, .h = 6.83334, .d = 0, .ic = 0.30755 }, // O
    .{ .cp = 0x50, .w = 6.81, .h = 6.83334, .d = 0, .ic = 1.53771 }, // P
    .{ .cp = 0x51, .w = 7.78, .h = 6.83334, .d = 1.94445, .ic = 0 }, // Q
    .{ .cp = 0x52, .w = 7.36, .h = 6.83334, .d = 0, .ic = 0.24 }, // R
    .{ .cp = 0x53, .w = 5.56, .h = 6.83334, .d = 0, .ic = 0.54662 }, // S
    .{ .cp = 0x54, .w = 7.22, .h = 6.83334, .d = 0, .ic = 1.53771 }, // T
    .{ .cp = 0x55, .w = 7.5, .h = 6.83334, .d = 0, .ic = 1.07241 }, // U
    .{ .cp = 0x56, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0.08 }, // V
    .{ .cp = 0x57, .w = 10.28, .h = 6.83334, .d = 0, .ic = 0.09 }, // W
    .{ .cp = 0x58, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0.04 }, // X
    .{ .cp = 0x59, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0.16 }, // Y
    .{ .cp = 0x5A, .w = 6.11, .h = 6.83334, .d = 0, .ic = 0.70038 }, // Z
    .{ .cp = 0x5B, .w = 2.78, .h = 7.5, .d = 2.5, .ic = 0.06 }, // [
    .{ .cp = 0x5D, .w = 2.78, .h = 7.5, .d = 2.5, .ic = 0 }, // ]
    .{ .cp = 0x61, .w = 5, .h = 4.30555, .d = 0, .ic = 0.11 }, // a
    .{ .cp = 0x62, .w = 5.56, .h = 6.94445, .d = 0, .ic = 0 }, // b
    .{ .cp = 0x63, .w = 4.44, .h = 4.30555, .d = 0, .ic = 0 }, // c
    .{ .cp = 0x64, .w = 5.56, .h = 6.94445, .d = 0, .ic = 0 }, // d
    .{ .cp = 0x65, .w = 4.44, .h = 4.30555, .d = 0, .ic = 0 }, // e
    .{ .cp = 0x66, .w = 3.06, .h = 6.94445, .d = 1.94445, .ic = 0.79 }, // f
    .{ .cp = 0x67, .w = 5, .h = 4.30555, .d = 1.94445, .ic = 0.13 }, // g
    .{ .cp = 0x68, .w = 5.56, .h = 6.94445, .d = 0, .ic = 0.07 }, // h
    .{ .cp = 0x69, .w = 2.78, .h = 6.61706, .d = 0, .ic = 0 }, // i
    .{ .cp = 0x6A, .w = 3.06, .h = 6.61706, .d = 1.94445, .ic = 0.57787 }, // j
    .{ .cp = 0x6B, .w = 5.28, .h = 6.94445, .d = 0, .ic = 0.11 }, // k
    .{ .cp = 0x6C, .w = 2.78, .h = 6.94445, .d = 0, .ic = 0.05 }, // l
    .{ .cp = 0x6D, .w = 8.33, .h = 4.30555, .d = 0, .ic = 0.08 }, // m
    .{ .cp = 0x6E, .w = 5.56, .h = 4.30555, .d = 0, .ic = 0.07 }, // n
    .{ .cp = 0x6F, .w = 5, .h = 4.30555, .d = 0, .ic = 0 }, // o
    .{ .cp = 0x70, .w = 5.56, .h = 4.30555, .d = 1.94445, .ic = 0 }, // p
    .{ .cp = 0x71, .w = 5.28, .h = 4.30555, .d = 1.94445, .ic = 0.27 }, // q
    .{ .cp = 0x72, .w = 3.92, .h = 4.30555, .d = 0, .ic = 0.30755 }, // r
    .{ .cp = 0x73, .w = 3.94, .h = 4.30555, .d = 0, .ic = 0 }, // s
    .{ .cp = 0x74, .w = 3.89, .h = 6.1508, .d = 0, .ic = 0 }, // t
    .{ .cp = 0x75, .w = 5.56, .h = 4.30555, .d = 0, .ic = 0.07 }, // u
    .{ .cp = 0x76, .w = 5.28, .h = 4.30555, .d = 0, .ic = 0.08 }, // v
    .{ .cp = 0x77, .w = 7.22, .h = 4.30555, .d = 0, .ic = 0.09 }, // w
    .{ .cp = 0x78, .w = 5.28, .h = 4.30555, .d = 0, .ic = 0.16 }, // x
    .{ .cp = 0x79, .w = 5.28, .h = 4.30555, .d = 1.94445, .ic = 0.08 }, // y
    .{ .cp = 0x7A, .w = 4.44, .h = 4.30555, .d = 0, .ic = 0.41005 }, // z
    .{ .cp = 0x7B, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // { (cmsy10)
    .{ .cp = 0x7C, .w = 2.78, .h = 7.5, .d = 2.5, .ic = 0 }, // | (cmsy10)
    .{ .cp = 0x7D, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // } (cmsy10)
    .{ .cp = 0x00B1, .w = 7.78, .h = 6.19049, .d = 1.19049, .ic = 0 }, // ± \pm (cmsy10 167)
    .{ .cp = 0x00B7, .w = 2.78, .h = 4.6528, .d = -0.3472, .ic = 0 }, // · middle dot (cmsy10, same as U+22C5 ⋅)
    .{ .cp = 0x00D7, .w = 7.78, .h = 6.19049, .d = 1.19049, .ic = 0 }, // × \times (cmsy10 163)
    .{ .cp = 0x00F7, .w = 7.78, .h = 6.19049, .d = 1.19049, .ic = 0 }, // ÷ \div (cmsy10 165)
    .{ .cp = 0x391, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0 }, // Α
    .{ .cp = 0x392, .w = 7.08, .h = 6.83334, .d = 0, .ic = 0.48684 }, // Β
    .{ .cp = 0x393, .w = 6.25, .h = 6.83334, .d = 0, .ic = 0 }, // Γ (cmr10 slot 161)
    .{ .cp = 0x394, .w = 8.33, .h = 6.83334, .d = 0, .ic = 0 }, // Δ (cmr10 slot 162)
    .{ .cp = 0x398, .w = 7.78, .h = 6.83334, .d = 0, .ic = 0 }, // Θ (cmr10 slot 163)
    .{ .cp = 0x39B, .w = 6.94, .h = 6.83334, .d = 0, .ic = 0 }, // Λ (cmr10 slot 164)
    .{ .cp = 0x3A0, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0 }, // Π (cmr10 slot 166)
    .{ .cp = 0x3A3, .w = 7.22, .h = 6.83334, .d = 0, .ic = 0 }, // Σ (cmr10 slot 167)
    .{ .cp = 0x3A6, .w = 7.22, .h = 6.83334, .d = 0, .ic = 0 }, // Φ (cmr10 slot 169)
    .{ .cp = 0x3A9, .w = 7.22, .h = 6.83334, .d = 0, .ic = 0 }, // Ω (cmr10 slot 171)
    .{ .cp = 0x3B1, .w = 6.41, .h = 4.30555, .d = 0, .ic = 0.24 }, // α
    .{ .cp = 0x3B2, .w = 5.58, .h = 6.94445, .d = 1.94445, .ic = 0.5139 }, // β
    .{ .cp = 0x3B3, .w = 5.86, .h = 4.30555, .d = 1.94445, .ic = 0.61508 }, // γ
    .{ .cp = 0x3B4, .w = 4.74, .h = 6.94445, .d = 0, .ic = 0.3626 }, // δ
    .{ .cp = 0x3B5, .w = 5.35, .h = 4.30555, .d = 0, .ic = 0 }, // ε
    .{ .cp = 0x3B8, .w = 4.88, .h = 6.94445, .d = 0, .ic = 0.30755 }, // θ
    .{ .cp = 0x3BB, .w = 5.37, .h = 6.94445, .d = 0, .ic = 0.54 }, // λ
    .{ .cp = 0x3BC, .w = 5.3, .h = 4.30555, .d = 1.94445, .ic = 0.23 }, // μ
    .{ .cp = 0x3C0, .w = 5.86, .h = 4.30555, .d = 0, .ic = 0.3588 }, // π
    .{ .cp = 0x3C3, .w = 5.99, .h = 4.30555, .d = 0, .ic = 0.3588 }, // σ
    .{ .cp = 0x3C6, .w = 6.41, .h = 6.94445, .d = 1.94445, .ic = 0 }, // φ
    .{ .cp = 0x3C9, .w = 6.41, .h = 4.30555, .d = 0, .ic = 0.3588 }, // ω
    .{ .cp = 0x2020, .w = 4.44, .h = 6.94445, .d = 1.94445, .ic = 0 }, // † \dagger (cmsy10 121)
    .{ .cp = 0x2021, .w = 4.44, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ‡ \ddagger (cmsy10 122)
    .{ .cp = 0x2032, .w = 3.11, .h = 5.55557, .d = 0, .ic = 0 }, // ′ \prime (cmsy10 48)
    .{ .cp = 0x2033, .w = 5.11, .h = 5.55557, .d = 0, .ic = 0 }, // ″ composite: 2 × \prime
    .{ .cp = 0x210E, .w = 5.76, .h = 6.94445, .d = 0, .ic = 0.07 }, // ℎ
    .{ .cp = 0x2190, .w = 10, .h = 3.84079, .d = -1.15921, .ic = 0 }, // ← \leftarrow (cmsy10 195)
    .{ .cp = 0x2191, .w = 5, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ↑ \uparrow (cmsy10 34)
    .{ .cp = 0x2192, .w = 10, .h = 3.84079, .d = -1.15921, .ic = 0 }, // → \rightarrow (cmsy10 33)
    .{ .cp = 0x2193, .w = 5, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ↓ \downarrow (cmsy10 35)
    .{ .cp = 0x2194, .w = 10, .h = 3.84079, .d = -1.15921, .ic = 0 }, // ↔ \leftrightarrow (cmsy10 36)
    .{ .cp = 0x2195, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // ↕ \updownarrow (cmsy10 108)
    .{ .cp = 0x2196, .w = 10, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ↖ \nwarrow (cmsy10 45)
    .{ .cp = 0x2197, .w = 10, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ↗ \nearrow (cmsy10 37)
    .{ .cp = 0x2198, .w = 10, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ↘ \searrow (cmsy10 38)
    .{ .cp = 0x2199, .w = 10, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ↙ \swarrow (cmsy10 46)
    .{ .cp = 0x21A6, .w = 9.77, .h = 3.84079, .d = -1.15921, .ic = 0 }, // ↦ \mapsto (composite: \mapstochar →)
    .{ .cp = 0x21BC, .w = 10, .h = 3.84079, .d = -1.15921, .ic = 0 }, // ↼ \leftharpoonup (cmmi10 40)
    .{ .cp = 0x21BD, .w = 10.12, .h = 3.84079, .d = -1.15921, .ic = 0 }, // ↽ \leftharpoondown (cmmi10 41)
    .{ .cp = 0x21C0, .w = 10, .h = 3.84079, .d = -1.15921, .ic = 0 }, // ⇀ \rightharpoonup (cmmi10 42)
    .{ .cp = 0x21C1, .w = 10.12, .h = 3.84079, .d = -1.15921, .ic = 0 }, // ⇁ \rightharpoondown (cmmi10 43)
    .{ .cp = 0x21D0, .w = 10, .h = 3.84079, .d = -1.15921, .ic = 0 }, // ⇐ \Leftarrow (cmsy10 40)
    .{ .cp = 0x21D1, .w = 6.11, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ⇑ \Uparrow (cmsy10 42)
    .{ .cp = 0x21D2, .w = 10, .h = 3.84079, .d = -1.15921, .ic = 0 }, // ⇒ \Rightarrow (cmsy10 41)
    .{ .cp = 0x21D3, .w = 6.11, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ⇓ \Downarrow (cmsy10 43)
    .{ .cp = 0x21D4, .w = 10, .h = 3.84079, .d = -1.15921, .ic = 0 }, // ⇔ \Leftrightarrow (cmsy10 44)
    .{ .cp = 0x21D5, .w = 6.11, .h = 7.5, .d = 2.5, .ic = 0 }, // ⇕ \Updownarrow (cmsy10 109)
    .{ .cp = 0x2202, .w = 5.86, .h = 6.94445, .d = 0, .ic = 0.61508 }, // ∂ \partial (cmmi10 64)
    .{ .cp = 0x2205, .w = 5, .h = 7.5, .d = 0.55555, .ic = 0 }, // ∅ \emptyset (cmsy10 59)
    .{ .cp = 0x2207, .w = 8.33, .h = 6.83334, .d = 0, .ic = 0 }, // ∇ \nabla (cmsy10 114)
    .{ .cp = 0x2208, .w = 6.67, .h = 5.75675, .d = 0.75675, .ic = 0 }, // ∈ \in (cmsy10 50)
    .{ .cp = 0x2209, .w = 6.67, .h = 5.75675, .d = 0.75675, .ic = 0 }, // ∉ \notin (composite: \not \in)
    .{ .cp = 0x220B, .w = 6.67, .h = 5.75675, .d = 0.75675, .ic = 0 }, // ∋ \ni (cmsy10 51)
    .{ .cp = 0x2212, .w = 7.78, .h = 6.19049, .d = 1.19049, .ic = 0 }, // − minus (cmsy10 161)
    .{ .cp = 0x2213, .w = 7.78, .h = 6.19049, .d = 1.19049, .ic = 0 }, // ∓ \mp (cmsy10 168)
    .{ .cp = 0x2216, .w = 5.68, .h = 7.5, .d = 2.5, .ic = 0 }, // ∖ \setminus (cmsy10 110)
    .{ .cp = 0x2217, .w = 5, .h = 4.65278, .d = -0.34722, .ic = 0 }, // ∗ \ast (cmsy10 164)
    .{ .cp = 0x2218, .w = 4.12, .h = 4.6528, .d = -0.3472, .ic = 0 }, // ∘ \circ (cmsy10 177)
    .{ .cp = 0x2219, .w = 5, .h = 4.6528, .d = -0.3472, .ic = 0 }, // ∙ \bullet (cmsy10 178)
    .{ .cp = 0x221A, .w = 8.33, .h = 0.48571, .d = 9.51429, .ic = 0 }, // √ \surd (cmsy10 112)
    .{ .cp = 0x221D, .w = 7.78, .h = 4.30555, .d = 0, .ic = 0 }, // ∝ \propto (cmsy10 47)
    .{ .cp = 0x221E, .w = 10, .h = 4.30555, .d = 0, .ic = 0 }, // ∞ \infty (cmsy10 49)
    .{ .cp = 0x2223, .w = 2.78, .h = 7.5, .d = 2.5, .ic = 0 }, // ∣ \mid (cmsy10 106 \vert)
    .{ .cp = 0x2225, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // ∥ \parallel (cmsy10 107 \Vert)
    .{ .cp = 0x2227, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ∧ \wedge (cmsy10 94)
    .{ .cp = 0x2228, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ∨ \vee (cmsy10 95)
    .{ .cp = 0x2229, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ∩ \cap (cmsy10 92)
    .{ .cp = 0x222A, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ∪ \cup (cmsy10 91)
    .{ .cp = 0x223C, .w = 7.73, .h = 3.84079, .d = -1.15921, .ic = 0 }, // ∼ \sim (cmsy10 187)
    .{ .cp = 0x2240, .w = 2.8, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ≀ \wr (cmsy10 111)
    .{ .cp = 0x2243, .w = 7.78, .h = 4.93871, .d = -0.06129, .ic = 0 }, // ≃ \simeq (cmsy10 39)
    .{ .cp = 0x2248, .w = 7.73, .h = 5.15828, .d = 0.15828, .ic = 0 }, // ≈ \approx (cmsy10 188)
    .{ .cp = 0x224D, .w = 7.78, .h = 4.93871, .d = -0.06129, .ic = 0 }, // ≍ \asymp (cmsy10 179)
    .{ .cp = 0x2260, .w = 7.78, .h = 3.84079, .d = -1.15921, .ic = 0 }, // ≠ \ne (composite: \not over =)
    .{ .cp = 0x2261, .w = 7.78, .h = 4.93871, .d = -0.06129, .ic = 0 }, // ≡ \equiv (cmsy10 180)
    .{ .cp = 0x2262, .w = 7.78, .h = 4.93871, .d = -0.06129, .ic = 0 }, // ≢ \not\equiv (composite: \not over ≡)
    .{ .cp = 0x2264, .w = 7.78, .h = 6.85469, .d = 1.85469, .ic = 0 }, // ≤ \leq (cmsy10 183)
    .{ .cp = 0x2265, .w = 7.78, .h = 6.85469, .d = 1.85469, .ic = 0 }, // ≥ \geq (cmsy10 184)
    .{ .cp = 0x226A, .w = 10, .h = 5.75675, .d = 0.75675, .ic = 0 }, // ≪ \ll (cmsy10 191)
    .{ .cp = 0x226B, .w = 10, .h = 5.75675, .d = 0.75675, .ic = 0 }, // ≫ \gg (cmsy10 192)
    .{ .cp = 0x227A, .w = 7.78, .h = 5.75675, .d = 0.75675, .ic = 0 }, // ≺ \prec (cmsy10 193)
    .{ .cp = 0x227B, .w = 7.78, .h = 5.75675, .d = 0.75675, .ic = 0 }, // ≻ \succ (cmsy10 194)
    .{ .cp = 0x2282, .w = 7.78, .h = 5.75675, .d = 0.75675, .ic = 0 }, // ⊂ \subset (cmsy10 189)
    .{ .cp = 0x2283, .w = 7.78, .h = 5.75675, .d = 0.75675, .ic = 0 }, // ⊃ \supset (cmsy10 190)
    .{ .cp = 0x2286, .w = 7.78, .h = 6.85469, .d = 1.85469, .ic = 0 }, // ⊆ \subseteq (cmsy10 181)
    .{ .cp = 0x2287, .w = 7.78, .h = 6.85469, .d = 1.85469, .ic = 0 }, // ⊇ \supseteq (cmsy10 182)
    .{ .cp = 0x228E, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ⊎ \uplus (cmsy10 93)
    .{ .cp = 0x2291, .w = 7.78, .h = 6.85469, .d = 1.85469, .ic = 0 }, // ⊑ \sqsubseteq (cmsy10 118)
    .{ .cp = 0x2292, .w = 7.78, .h = 6.85469, .d = 1.85469, .ic = 0 }, // ⊒ \sqsupseteq (cmsy10 119)
    .{ .cp = 0x2293, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ⊓ \sqcap (cmsy10 117)
    .{ .cp = 0x2294, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ⊔ \sqcup (cmsy10 116)
    .{ .cp = 0x2295, .w = 7.78, .h = 6.19049, .d = 1.19049, .ic = 0 }, // ⊕ \oplus (cmsy10 169)
    .{ .cp = 0x2296, .w = 7.78, .h = 6.19049, .d = 1.19049, .ic = 0 }, // ⊖ \ominus (cmsy10 170)
    .{ .cp = 0x2297, .w = 7.78, .h = 6.19049, .d = 1.19049, .ic = 0 }, // ⊗ \otimes (cmsy10 171)
    .{ .cp = 0x2298, .w = 7.78, .h = 6.19049, .d = 1.19049, .ic = 0 }, // ⊘ \oslash (cmsy10 174)
    .{ .cp = 0x2299, .w = 7.78, .h = 6.19049, .d = 1.19049, .ic = 0 }, // ⊙ \odot (cmsy10 175)
    .{ .cp = 0x22A2, .w = 6.11, .h = 6.94445, .d = 0, .ic = 0 }, // ⊢ \vdash (cmsy10 96)
    .{ .cp = 0x22A3, .w = 6.11, .h = 6.94445, .d = 0, .ic = 0 }, // ⊣ \dashv (cmsy10 97)
    .{ .cp = 0x22A5, .w = 7.78, .h = 6.94445, .d = 0, .ic = 0 }, // ⊥ \perp (cmsy10 63)
    .{ .cp = 0x22C4, .w = 5, .h = 4.6528, .d = -0.3472, .ic = 0.08 }, // ⋄ \diamond (cmsy10 166)
    .{ .cp = 0x22C5, .w = 2.78, .h = 4.6528, .d = -0.3472, .ic = 0 }, // ⋅ \cdot (cmsy10 middle dot)
    .{ .cp = 0x22C6, .w = 5, .h = 4.65278, .d = -0.34722, .ic = 0.25 }, // ⋆ \star (cmmi10 63)
    .{ .cp = 0x22EF, .w = 7.76, .h = 4.6528, .d = -0.3472, .ic = 0 }, // ⋯ \cdots (composite: 3 × cdot)
    .{ .cp = 0x2308, .w = 4.44, .h = 7.5, .d = 2.5, .ic = 0 }, // ⌈ \lceil (cmsy10 100)
    .{ .cp = 0x2309, .w = 4.44, .h = 7.5, .d = 2.5, .ic = 0 }, // ⌉ \rceil (cmsy10 101)
    .{ .cp = 0x230A, .w = 4.44, .h = 7.5, .d = 2.5, .ic = 0 }, // ⌊ \lfloor (cmsy10 98)
    .{ .cp = 0x230B, .w = 4.44, .h = 7.5, .d = 2.5, .ic = 0 }, // ⌋ \rfloor (cmsy10 99)
    .{ .cp = 0x2322, .w = 10, .h = 3.5764, .d = -1.4236, .ic = 0 }, // ⌢ \frown (cmmi10 95)
    .{ .cp = 0x2323, .w = 10, .h = 3.5764, .d = -1.4236, .ic = 0 }, // ⌣ \smile (cmmi10 94)
    .{ .cp = 0x25B9, .w = 5.8532, .h = 4.65278, .d = -0.34722, .ic = 0 }, // ▹ \triangleright (cmmi10 46)
    .{ .cp = 0x25C3, .w = 5.8532, .h = 4.65278, .d = -0.34722, .ic = 0 }, // ◃ \triangleleft (cmmi10 47)
    .{ .cp = 0x25CB, .w = 7.96, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ○ \bigcirc (cmsy10 176)
    .{ .cp = 0x27E8, .w = 3.89, .h = 7.5, .d = 2.5, .ic = 0 }, // ⟨ \langle (cmsy10 104)
    .{ .cp = 0x27E9, .w = 3.89, .h = 7.5, .d = 2.5, .ic = 0 }, // ⟩ \rangle (cmsy10 105)
    .{ .cp = 0x2A3F, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0 }, // ⨿ \amalg (cmsy10 113)
    .{ .cp = 0x2AAF, .w = 7.78, .h = 6.85469, .d = 1.85469, .ic = 0 }, // ⪯ \preceq (cmsy10 185)
    .{ .cp = 0x2AB0, .w = 7.78, .h = 6.85469, .d = 1.85469, .ic = 0 }, // ⪰ \succeq (cmsy10 186)
    .{ .cp = 0x1D434, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0 }, // 𝐴
    .{ .cp = 0x1D435, .w = 7.59, .h = 6.83334, .d = 0, .ic = 0.48684 }, // 𝐵
    .{ .cp = 0x1D436, .w = 7.15, .h = 6.83334, .d = 0, .ic = 0.70038 }, // 𝐶
    .{ .cp = 0x1D437, .w = 8.28, .h = 6.83334, .d = 0, .ic = 0.30755 }, // 𝐷
    .{ .cp = 0x1D438, .w = 7.38, .h = 6.83334, .d = 0, .ic = 0.5496 }, // 𝐸
    .{ .cp = 0x1D439, .w = 6.43, .h = 6.83334, .d = 0, .ic = 1.53771 }, // 𝐹
    .{ .cp = 0x1D43A, .w = 7.86, .h = 6.83334, .d = 0, .ic = 0 }, // 𝐺
    .{ .cp = 0x1D43B, .w = 8.31, .h = 6.83334, .d = 0, .ic = 0.76486 }, // 𝐻
    .{ .cp = 0x1D43C, .w = 4.4, .h = 6.83334, .d = 0, .ic = 0.77728 }, // 𝐼
    .{ .cp = 0x1D43D, .w = 5.55, .h = 6.83334, .d = 0, .ic = 0.94345 }, // 𝐽
    .{ .cp = 0x1D43E, .w = 8.49, .h = 6.83334, .d = 0, .ic = 0.70038 }, // 𝐾
    .{ .cp = 0x1D43F, .w = 6.81, .h = 6.83334, .d = 0, .ic = 0 }, // 𝐿
    .{ .cp = 0x1D440, .w = 9.7, .h = 6.83334, .d = 0, .ic = 1.07241 }, // 𝑀
    .{ .cp = 0x1D441, .w = 8.03, .h = 6.83334, .d = 0, .ic = 1.07241 }, // 𝑁
    .{ .cp = 0x1D442, .w = 7.63, .h = 6.83334, .d = 0, .ic = 0.30755 }, // 𝑂
    .{ .cp = 0x1D443, .w = 6.42, .h = 6.83334, .d = 0, .ic = 1.53771 }, // 𝑃
    .{ .cp = 0x1D444, .w = 7.91, .h = 6.83334, .d = 1.94445, .ic = 0 }, // 𝑄
    .{ .cp = 0x1D445, .w = 7.59, .h = 6.83334, .d = 0, .ic = 0.24 }, // 𝑅
    .{ .cp = 0x1D446, .w = 6.13, .h = 6.83334, .d = 0, .ic = 0.54662 }, // 𝑆
    .{ .cp = 0x1D447, .w = 5.84, .h = 6.83334, .d = 0, .ic = 1.53771 }, // 𝑇
    .{ .cp = 0x1D448, .w = 6.83, .h = 6.83334, .d = 0, .ic = 1.07241 }, // 𝑈
    .{ .cp = 0x1D449, .w = 5.83, .h = 6.83334, .d = 0, .ic = 0.08 }, // 𝑉
    .{ .cp = 0x1D44A, .w = 9.44, .h = 6.83334, .d = 0, .ic = 0.09 }, // 𝑊
    .{ .cp = 0x1D44B, .w = 8.28, .h = 6.83334, .d = 0, .ic = 0.04 }, // 𝑋
    .{ .cp = 0x1D44C, .w = 5.81, .h = 6.83334, .d = 0, .ic = 0.16 }, // 𝑌
    .{ .cp = 0x1D44D, .w = 6.83, .h = 6.83334, .d = 0, .ic = 0.70038 }, // 𝑍
    .{ .cp = 0x1D44E, .w = 5.29, .h = 4.30555, .d = 0, .ic = 0.11 }, // 𝑎
    .{ .cp = 0x1D44F, .w = 4.29, .h = 6.94445, .d = 0, .ic = 0 }, // 𝑏
    .{ .cp = 0x1D450, .w = 4.33, .h = 4.30555, .d = 0, .ic = 0 }, // 𝑐
    .{ .cp = 0x1D451, .w = 5.2, .h = 6.94445, .d = 0, .ic = 0 }, // 𝑑
    .{ .cp = 0x1D452, .w = 4.66, .h = 4.30555, .d = 0, .ic = 0 }, // 𝑒
    .{ .cp = 0x1D453, .w = 4.9, .h = 6.94445, .d = 1.94445, .ic = 0.79 }, // 𝑓
    .{ .cp = 0x1D454, .w = 4.77, .h = 4.30555, .d = 1.94445, .ic = 0.13 }, // 𝑔
    .{ .cp = 0x1D456, .w = 3.45, .h = 6.61706, .d = 0, .ic = 0 }, // 𝑖
    .{ .cp = 0x1D457, .w = 4.12, .h = 6.61706, .d = 1.94445, .ic = 0.57787 }, // 𝑗
    .{ .cp = 0x1D458, .w = 5.21, .h = 6.94445, .d = 0, .ic = 0.11 }, // 𝑘
    .{ .cp = 0x1D459, .w = 2.98, .h = 6.94445, .d = 0, .ic = 0.05 }, // 𝑙
    .{ .cp = 0x1D45A, .w = 8.78, .h = 4.30555, .d = 0, .ic = 0.08 }, // 𝑚
    .{ .cp = 0x1D45B, .w = 6, .h = 4.30555, .d = 0, .ic = 0.07 }, // 𝑛
    .{ .cp = 0x1D45C, .w = 4.85, .h = 4.30555, .d = 0, .ic = 0 }, // 𝑜
    .{ .cp = 0x1D45D, .w = 5.03, .h = 4.30555, .d = 1.94445, .ic = 0 }, // 𝑝
    .{ .cp = 0x1D45E, .w = 4.46, .h = 4.30555, .d = 1.94445, .ic = 0.27 }, // 𝑞
    .{ .cp = 0x1D45F, .w = 4.51, .h = 4.30555, .d = 0, .ic = 0.30755 }, // 𝑟
    .{ .cp = 0x1D460, .w = 4.69, .h = 4.30555, .d = 0, .ic = 0 }, // 𝑠
    .{ .cp = 0x1D461, .w = 3.61, .h = 6.1508, .d = 0, .ic = 0 }, // 𝑡
    .{ .cp = 0x1D462, .w = 5.72, .h = 4.30555, .d = 0, .ic = 0.07 }, // 𝑢
    .{ .cp = 0x1D463, .w = 4.85, .h = 4.30555, .d = 0, .ic = 0.08 }, // 𝑣
    .{ .cp = 0x1D464, .w = 7.16, .h = 4.30555, .d = 0, .ic = 0.09 }, // 𝑤
    .{ .cp = 0x1D465, .w = 5.72, .h = 4.30555, .d = 0, .ic = 0.16 }, // 𝑥
    .{ .cp = 0x1D466, .w = 4.9, .h = 4.30555, .d = 1.94445, .ic = 0.08 }, // 𝑦
    .{ .cp = 0x1D467, .w = 4.65, .h = 4.30555, .d = 0, .ic = 0.41005 }, // 𝑧
    .{ .cp = 0x1D715, .w = 5.31, .h = 6.94445, .d = 0, .ic = 0.61508 }, // 𝜕
};

/// Roman-style letters for script size, the roman partner of `table_roman`
/// at the 7pt band (glyphAt picks it when style is `.roman`): LM Math
/// advances (em × 10), scaled linearly at 7pt by the layout.
const table_roman7 = [_]Entry{
    .{ .cp = 0x0041, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0 }, // A
    .{ .cp = 0x0042, .w = 7.08, .h = 6.83334, .d = 0, .ic = 0 }, // B
    .{ .cp = 0x0043, .w = 7.22, .h = 6.83334, .d = 0, .ic = 0 }, // C
    .{ .cp = 0x0044, .w = 7.64, .h = 6.83334, .d = 0, .ic = 0 }, // D
    .{ .cp = 0x0045, .w = 6.81, .h = 6.83334, .d = 0, .ic = 0 }, // E
    .{ .cp = 0x0046, .w = 6.53, .h = 6.83334, .d = 0, .ic = 0 }, // F
    .{ .cp = 0x0047, .w = 7.85, .h = 6.83334, .d = 0, .ic = 0 }, // G
    .{ .cp = 0x0048, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0 }, // H
    .{ .cp = 0x0049, .w = 3.61, .h = 6.83334, .d = 0, .ic = 0 }, // I
    .{ .cp = 0x004A, .w = 5.14, .h = 6.83334, .d = 0, .ic = 0 }, // J
    .{ .cp = 0x004B, .w = 7.78, .h = 6.83334, .d = 0, .ic = 0 }, // K
    .{ .cp = 0x004C, .w = 6.25, .h = 6.83334, .d = 0, .ic = 0 }, // L
    .{ .cp = 0x004D, .w = 9.17, .h = 6.83334, .d = 0, .ic = 0 }, // M
    .{ .cp = 0x004E, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0 }, // N
    .{ .cp = 0x004F, .w = 7.78, .h = 6.83334, .d = 0, .ic = 0 }, // O
    .{ .cp = 0x0050, .w = 6.81, .h = 6.83334, .d = 0, .ic = 0 }, // P
    .{ .cp = 0x0051, .w = 7.78, .h = 6.83334, .d = 1.94445, .ic = 0 }, // Q
    .{ .cp = 0x0052, .w = 7.36, .h = 6.83334, .d = 0, .ic = 0.24 }, // R
    .{ .cp = 0x0053, .w = 5.56, .h = 6.83334, .d = 0, .ic = 0 }, // S
    .{ .cp = 0x0054, .w = 7.22, .h = 6.83334, .d = 0, .ic = 0 }, // T
    .{ .cp = 0x0055, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0 }, // U
    .{ .cp = 0x0056, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0.08 }, // V
    .{ .cp = 0x0057, .w = 10.28, .h = 6.83334, .d = 0, .ic = 0.09 }, // W
    .{ .cp = 0x0058, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0.04 }, // X
    .{ .cp = 0x0059, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0.16 }, // Y
    .{ .cp = 0x005A, .w = 6.11, .h = 6.83334, .d = 0, .ic = 0 }, // Z
    .{ .cp = 0x0061, .w = 5, .h = 4.30555, .d = 0, .ic = 0.11 }, // a
    .{ .cp = 0x0062, .w = 5.56, .h = 6.94445, .d = 0, .ic = 0 }, // b
    .{ .cp = 0x0063, .w = 4.44, .h = 4.30555, .d = 0, .ic = 0 }, // c
    .{ .cp = 0x0064, .w = 5.56, .h = 6.94445, .d = 0, .ic = 0 }, // d
    .{ .cp = 0x0065, .w = 4.44, .h = 4.30555, .d = 0, .ic = 0 }, // e
    .{ .cp = 0x0066, .w = 3.06, .h = 6.94445, .d = 0, .ic = 0.79 }, // f
    .{ .cp = 0x0067, .w = 5, .h = 4.30555, .d = 1.94445, .ic = 0.13 }, // g
    .{ .cp = 0x0068, .w = 5.56, .h = 6.94445, .d = 0, .ic = 0.07 }, // h
    .{ .cp = 0x0069, .w = 2.78, .h = 6.72621, .d = 0, .ic = 0 }, // i
    .{ .cp = 0x006A, .w = 3.06, .h = 6.72621, .d = 1.94445, .ic = 0 }, // j
    .{ .cp = 0x006B, .w = 5.28, .h = 6.94445, .d = 0, .ic = 0.11 }, // k
    .{ .cp = 0x006C, .w = 2.78, .h = 6.94445, .d = 0, .ic = 0.05 }, // l
    .{ .cp = 0x006D, .w = 8.33, .h = 4.30555, .d = 0, .ic = 0.08 }, // m
    .{ .cp = 0x006E, .w = 5.56, .h = 4.30555, .d = 0, .ic = 0.07 }, // n
    .{ .cp = 0x006F, .w = 5, .h = 4.30555, .d = 0, .ic = 0 }, // o
    .{ .cp = 0x0070, .w = 5.56, .h = 4.30555, .d = 1.94445, .ic = 0 }, // p
    .{ .cp = 0x0071, .w = 5.28, .h = 4.30555, .d = 1.94445, .ic = 0.27 }, // q
    .{ .cp = 0x0072, .w = 3.92, .h = 4.30555, .d = 0, .ic = 0 }, // r
    .{ .cp = 0x0073, .w = 3.94, .h = 4.30555, .d = 0, .ic = 0 }, // s
    .{ .cp = 0x0074, .w = 3.89, .h = 6.1508, .d = 0, .ic = 0 }, // t
    .{ .cp = 0x0075, .w = 5.56, .h = 4.30555, .d = 0, .ic = 0.07 }, // u
    .{ .cp = 0x0076, .w = 5.28, .h = 4.30555, .d = 0, .ic = 0.08 }, // v
    .{ .cp = 0x0077, .w = 7.22, .h = 4.30555, .d = 0, .ic = 0.09 }, // w
    .{ .cp = 0x0078, .w = 5.28, .h = 4.30555, .d = 0, .ic = 0.16 }, // x
    .{ .cp = 0x0079, .w = 5.28, .h = 4.30555, .d = 1.94445, .ic = 0.08 }, // y
    .{ .cp = 0x007A, .w = 4.44, .h = 4.30555, .d = 0, .ic = 0 }, // z
};

/// Scriptscript-size metric table (design size 5pt), same convention as
/// `table` (em × 10): LM Math has no optical 5pt variant either, so these
/// rows carry the LM Math advance and the size_pt/10 factor yields LM
/// advance × 0.5 at 5pt (replacing the old optical cmr5/cmmi5/cmsy5).
const table5 = [_]Entry{
    .{ .cp = 0x21, .w = 2.78, .h = 6.94446, .d = 0, .ic = 0 }, // !
    .{ .cp = 0x28, .w = 3.89, .h = 7.5, .d = 2.5, .ic = 0 }, // (
    .{ .cp = 0x29, .w = 3.89, .h = 7.5, .d = 2.5, .ic = 0 }, // )
    .{ .cp = 0x2B, .w = 7.78, .h = 6.66675, .d = 1.66675, .ic = 0 }, // +
    .{ .cp = 0x2C, .w = 2.78, .h = 1.22223, .d = 1.94446, .ic = 0 }, // ,
    .{ .cp = 0x2D, .w = 3.33, .h = 6.66675, .d = 1.66675, .ic = 0 }, // - (cmsy10 minus)
    .{ .cp = 0x2E, .w = 2.78, .h = 1.22223, .d = 0, .ic = 0 }, // .
    .{ .cp = 0x2F, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // /
    .{ .cp = 0x30, .w = 5, .h = 6.44445, .d = 0, .ic = 0 }, // 0
    .{ .cp = 0x31, .w = 5, .h = 6.44445, .d = 0, .ic = 0 }, // 1
    .{ .cp = 0x32, .w = 5, .h = 6.44445, .d = 0, .ic = 0 }, // 2
    .{ .cp = 0x33, .w = 5, .h = 6.44445, .d = 0, .ic = 0 }, // 3
    .{ .cp = 0x34, .w = 5, .h = 6.44445, .d = 0, .ic = 0 }, // 4
    .{ .cp = 0x35, .w = 5, .h = 6.44445, .d = 0, .ic = 0 }, // 5
    .{ .cp = 0x36, .w = 5, .h = 6.44445, .d = 0, .ic = 0 }, // 6
    .{ .cp = 0x37, .w = 5, .h = 6.44445, .d = 0, .ic = 0.13 }, // 7
    .{ .cp = 0x38, .w = 5, .h = 6.44445, .d = 0, .ic = 0 }, // 8
    .{ .cp = 0x39, .w = 5, .h = 6.44445, .d = 0, .ic = 0 }, // 9
    .{ .cp = 0x3A, .w = 2.78, .h = 4.30554, .d = 0, .ic = 0 }, // :
    .{ .cp = 0x3B, .w = 2.78, .h = 4.30554, .d = 1.94446, .ic = 0 }, // ;
    .{ .cp = 0x3C, .w = 7.78, .h = 6.00916, .d = 1.00916, .ic = 0 }, // < (cmmi10)
    .{ .cp = 0x3D, .w = 7.78, .h = 3.96405, .d = -1.03595, .ic = 0 }, // =
    .{ .cp = 0x3E, .w = 7.78, .h = 6.00916, .d = 1.00916, .ic = 0 }, // > (cmmi10)
    .{ .cp = 0x41, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0 }, // A
    .{ .cp = 0x42, .w = 7.08, .h = 6.83334, .d = 0, .ic = 0.46701 }, // B
    .{ .cp = 0x43, .w = 7.22, .h = 6.83334, .d = 0, .ic = 0.68054 }, // C
    .{ .cp = 0x44, .w = 7.64, .h = 6.83334, .d = 0, .ic = 0.34723 }, // D
    .{ .cp = 0x45, .w = 6.81, .h = 6.83334, .d = 0, .ic = 0.51389 }, // E
    .{ .cp = 0x46, .w = 6.53, .h = 6.83334, .d = 0, .ic = 1.73615 }, // F
    .{ .cp = 0x47, .w = 7.85, .h = 6.83334, .d = 0, .ic = 0 }, // G
    .{ .cp = 0x48, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0.74305 }, // H
    .{ .cp = 0x49, .w = 3.61, .h = 6.83334, .d = 0, .ic = 0.76736 }, // I
    .{ .cp = 0x4A, .w = 5.14, .h = 6.83334, .d = 0, .ic = 0.95139 }, // J
    .{ .cp = 0x4B, .w = 7.78, .h = 6.83334, .d = 0, .ic = 0.68054 }, // K
    .{ .cp = 0x4C, .w = 6.25, .h = 6.83334, .d = 0, .ic = 0 }, // L
    .{ .cp = 0x4D, .w = 9.17, .h = 6.83334, .d = 0, .ic = 1.09027 }, // M
    .{ .cp = 0x4E, .w = 7.5, .h = 6.83334, .d = 0, .ic = 1.09027 }, // N
    .{ .cp = 0x4F, .w = 7.78, .h = 6.83334, .d = 0, .ic = 0.34723 }, // O
    .{ .cp = 0x50, .w = 6.81, .h = 6.83334, .d = 0, .ic = 1.73615 }, // P
    .{ .cp = 0x51, .w = 7.78, .h = 6.83334, .d = 1.94446, .ic = 0 }, // Q
    .{ .cp = 0x52, .w = 7.36, .h = 6.83334, .d = 0, .ic = 0.24 }, // R
    .{ .cp = 0x53, .w = 5.56, .h = 6.83334, .d = 0, .ic = 0.50693 }, // S
    .{ .cp = 0x54, .w = 7.22, .h = 6.83334, .d = 0, .ic = 1.73615 }, // T
    .{ .cp = 0x55, .w = 7.5, .h = 6.83334, .d = 0, .ic = 1.09027 }, // U
    .{ .cp = 0x56, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0.08 }, // V
    .{ .cp = 0x57, .w = 10.28, .h = 6.83334, .d = 0, .ic = 0.09 }, // W
    .{ .cp = 0x58, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0.04 }, // X
    .{ .cp = 0x59, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0.16 }, // Y
    .{ .cp = 0x5A, .w = 6.11, .h = 6.83334, .d = 0, .ic = 0.68054 }, // Z
    .{ .cp = 0x5B, .w = 2.78, .h = 7.5, .d = 2.5, .ic = 0.06 }, // [
    .{ .cp = 0x5D, .w = 2.78, .h = 7.5, .d = 2.5, .ic = 0 }, // ]
    .{ .cp = 0x61, .w = 5, .h = 4.30554, .d = 0, .ic = 0.11 }, // a
    .{ .cp = 0x62, .w = 5.56, .h = 6.94446, .d = 0, .ic = 0 }, // b
    .{ .cp = 0x63, .w = 4.44, .h = 4.30554, .d = 0, .ic = 0 }, // c
    .{ .cp = 0x64, .w = 5.56, .h = 6.94446, .d = 0, .ic = 0 }, // d
    .{ .cp = 0x65, .w = 4.44, .h = 4.30554, .d = 0, .ic = 0 }, // e
    .{ .cp = 0x66, .w = 3.06, .h = 6.94446, .d = 1.94446, .ic = 0.79 }, // f
    .{ .cp = 0x67, .w = 5, .h = 4.30554, .d = 1.94446, .ic = 0.13 }, // g
    .{ .cp = 0x68, .w = 5.56, .h = 6.94446, .d = 0, .ic = 0.07 }, // h
    .{ .cp = 0x69, .w = 2.78, .h = 6.66468, .d = 0, .ic = 0 }, // i
    .{ .cp = 0x6A, .w = 3.06, .h = 6.66468, .d = 1.94446, .ic = 0.58978 }, // j
    .{ .cp = 0x6B, .w = 5.28, .h = 6.94446, .d = 0, .ic = 0.11 }, // k
    .{ .cp = 0x6C, .w = 2.78, .h = 6.94446, .d = 0, .ic = 0.05 }, // l
    .{ .cp = 0x6D, .w = 8.33, .h = 4.30554, .d = 0, .ic = 0.08 }, // m
    .{ .cp = 0x6E, .w = 5.56, .h = 4.30554, .d = 0, .ic = 0.07 }, // n
    .{ .cp = 0x6F, .w = 5, .h = 4.30554, .d = 0, .ic = 0 }, // o
    .{ .cp = 0x70, .w = 5.56, .h = 4.30554, .d = 1.94446, .ic = 0 }, // p
    .{ .cp = 0x71, .w = 5.28, .h = 4.30554, .d = 1.94446, .ic = 0.27 }, // q
    .{ .cp = 0x72, .w = 3.92, .h = 4.30554, .d = 0, .ic = 0.34723 }, // r
    .{ .cp = 0x73, .w = 3.94, .h = 4.30554, .d = 0, .ic = 0 }, // s
    .{ .cp = 0x74, .w = 3.89, .h = 6.15079, .d = 0, .ic = 0 }, // t
    .{ .cp = 0x75, .w = 5.56, .h = 4.30554, .d = 0, .ic = 0.07 }, // u
    .{ .cp = 0x76, .w = 5.28, .h = 4.30554, .d = 0, .ic = 0.08 }, // v
    .{ .cp = 0x77, .w = 7.22, .h = 4.30554, .d = 0, .ic = 0.09 }, // w
    .{ .cp = 0x78, .w = 5.28, .h = 4.30554, .d = 0, .ic = 0.16 }, // x
    .{ .cp = 0x79, .w = 5.28, .h = 4.30554, .d = 1.94446, .ic = 0.08 }, // y
    .{ .cp = 0x7A, .w = 4.44, .h = 4.30554, .d = 0, .ic = 0.37036 }, // z
    .{ .cp = 0x7B, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // { (cmsy10)
    .{ .cp = 0x7C, .w = 2.78, .h = 7.5, .d = 2.5, .ic = 0 }, // | (cmsy10)
    .{ .cp = 0x7D, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // } (cmsy10)
    .{ .cp = 0x00B1, .w = 7.78, .h = 6.66675, .d = 1.66675, .ic = 0 }, // ± \pm (cmsy10 167)
    .{ .cp = 0x00B7, .w = 2.78, .h = 4.9306, .d = -0.0694, .ic = 0 }, // · middle dot (cmsy10, same as U+22C5 ⋅)
    .{ .cp = 0x00D7, .w = 7.78, .h = 6.66675, .d = 1.66675, .ic = 0 }, // × \times (cmsy10 163)
    .{ .cp = 0x00F7, .w = 7.78, .h = 6.66675, .d = 1.66675, .ic = 0 }, // ÷ \div (cmsy10 165)
    .{ .cp = 0x391, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0 }, // Α
    .{ .cp = 0x392, .w = 7.08, .h = 6.83334, .d = 0, .ic = 0.46701 }, // Β
    .{ .cp = 0x393, .w = 6.25, .h = 6.79761, .d = 0, .ic = 0 }, // Γ (cmr10 slot 161)
    .{ .cp = 0x394, .w = 8.33, .h = 6.79761, .d = 0, .ic = 0 }, // Δ (cmr10 slot 162)
    .{ .cp = 0x398, .w = 7.78, .h = 6.79761, .d = 0, .ic = 0 }, // Θ (cmr10 slot 163)
    .{ .cp = 0x39B, .w = 6.94, .h = 6.79761, .d = 0, .ic = 0 }, // Λ (cmr10 slot 164)
    .{ .cp = 0x3A0, .w = 7.5, .h = 6.79761, .d = 0, .ic = 0 }, // Π (cmr10 slot 166)
    .{ .cp = 0x3A3, .w = 7.22, .h = 6.79761, .d = 0, .ic = 0 }, // Σ (cmr10 slot 167)
    .{ .cp = 0x3A6, .w = 7.22, .h = 6.79761, .d = 0, .ic = 0 }, // Φ (cmr10 slot 169)
    .{ .cp = 0x3A9, .w = 7.22, .h = 6.79761, .d = 0, .ic = 0 }, // Ω (cmr10 slot 171)
    .{ .cp = 0x3B1, .w = 6.41, .h = 4.30554, .d = 0, .ic = 0.24 }, // α
    .{ .cp = 0x3B2, .w = 5.58, .h = 6.94446, .d = 1.94446, .ic = 0.51389 }, // β
    .{ .cp = 0x3B3, .w = 5.86, .h = 4.30554, .d = 1.94446, .ic = 0.69446 }, // γ
    .{ .cp = 0x3B4, .w = 4.74, .h = 6.94446, .d = 0, .ic = 0.3229 }, // δ
    .{ .cp = 0x3B5, .w = 5.35, .h = 4.30554, .d = 0, .ic = 0 }, // ε
    .{ .cp = 0x3B8, .w = 4.88, .h = 6.94446, .d = 0, .ic = 0.34723 }, // θ
    .{ .cp = 0x3BB, .w = 5.37, .h = 6.94446, .d = 0, .ic = 0.54 }, // λ
    .{ .cp = 0x3BC, .w = 5.3, .h = 4.30554, .d = 1.94446, .ic = 0.23 }, // μ
    .{ .cp = 0x3C0, .w = 5.86, .h = 4.30554, .d = 0, .ic = 0.35879 }, // π
    .{ .cp = 0x3C3, .w = 5.99, .h = 4.30554, .d = 0, .ic = 0.35879 }, // σ
    .{ .cp = 0x3C6, .w = 6.41, .h = 6.94446, .d = 1.94446, .ic = 0 }, // φ
    .{ .cp = 0x3C9, .w = 6.41, .h = 4.30554, .d = 0, .ic = 0.35879 }, // ω
    .{ .cp = 0x2020, .w = 4.44, .h = 6.94446, .d = 1.94446, .ic = 0 }, // † \dagger (cmsy10 121)
    .{ .cp = 0x2021, .w = 4.44, .h = 6.94446, .d = 1.94446, .ic = 0 }, // ‡ \ddagger (cmsy10 122)
    .{ .cp = 0x2032, .w = 3.11, .h = 5.55557, .d = 0, .ic = 0 }, // ′ \prime (cmsy10 48)
    .{ .cp = 0x2033, .w = 5.11, .h = 5.55557, .d = 0, .ic = 0 }, // ″ composite: 2 × \prime
    .{ .cp = 0x210E, .w = 5.76, .h = 6.94446, .d = 0, .ic = 0.07 }, // ℎ
    .{ .cp = 0x2190, .w = 10, .h = 3.96405, .d = -1.03595, .ic = 0 }, // ← \leftarrow (cmsy10 195)
    .{ .cp = 0x2191, .w = 5, .h = 6.94446, .d = 1.94446, .ic = 0 }, // ↑ \uparrow (cmsy10 34)
    .{ .cp = 0x2192, .w = 10, .h = 3.96405, .d = -1.03595, .ic = 0 }, // → \rightarrow (cmsy10 33)
    .{ .cp = 0x2193, .w = 5, .h = 6.94446, .d = 1.94446, .ic = 0 }, // ↓ \downarrow (cmsy10 35)
    .{ .cp = 0x2194, .w = 10, .h = 3.96405, .d = -1.03595, .ic = 0 }, // ↔ \leftrightarrow (cmsy10 36)
    .{ .cp = 0x2195, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // ↕ \updownarrow (cmsy10 108)
    .{ .cp = 0x2196, .w = 10, .h = 6.94446, .d = 1.94446, .ic = 0 }, // ↖ \nwarrow (cmsy10 45)
    .{ .cp = 0x2197, .w = 10, .h = 6.94446, .d = 1.94446, .ic = 0 }, // ↗ \nearrow (cmsy10 37)
    .{ .cp = 0x2198, .w = 10, .h = 6.94446, .d = 1.94446, .ic = 0 }, // ↘ \searrow (cmsy10 38)
    .{ .cp = 0x2199, .w = 10, .h = 6.94446, .d = 1.94446, .ic = 0 }, // ↙ \swarrow (cmsy10 46)
    .{ .cp = 0x21A6, .w = 9.77, .h = 3.96405, .d = -1.03595, .ic = 0 }, // ↦ \mapsto (composite: \mapstochar →)
    .{ .cp = 0x21BC, .w = 10, .h = 3.96405, .d = -1.03595, .ic = 0 }, // ↼ \leftharpoonup (cmmi10 40)
    .{ .cp = 0x21BD, .w = 10.12, .h = 3.96405, .d = -1.03595, .ic = 0 }, // ↽ \leftharpoondown (cmmi10 41)
    .{ .cp = 0x21C0, .w = 10, .h = 3.96405, .d = -1.03595, .ic = 0 }, // ⇀ \rightharpoonup (cmmi10 42)
    .{ .cp = 0x21C1, .w = 10.12, .h = 3.96405, .d = -1.03595, .ic = 0 }, // ⇁ \rightharpoondown (cmmi10 43)
    .{ .cp = 0x21D0, .w = 10, .h = 3.96405, .d = -1.03595, .ic = 0 }, // ⇐ \Leftarrow (cmsy10 40)
    .{ .cp = 0x21D1, .w = 6.11, .h = 6.94446, .d = 1.94446, .ic = 0 }, // ⇑ \Uparrow (cmsy10 42)
    .{ .cp = 0x21D2, .w = 10, .h = 3.96405, .d = -1.03595, .ic = 0 }, // ⇒ \Rightarrow (cmsy10 41)
    .{ .cp = 0x21D3, .w = 6.11, .h = 6.94446, .d = 1.94446, .ic = 0 }, // ⇓ \Downarrow (cmsy10 43)
    .{ .cp = 0x21D4, .w = 10, .h = 3.96405, .d = -1.03595, .ic = 0 }, // ⇔ \Leftrightarrow (cmsy10 44)
    .{ .cp = 0x21D5, .w = 6.11, .h = 7.5, .d = 2.5, .ic = 0 }, // ⇕ \Updownarrow (cmsy10 109)
    .{ .cp = 0x2202, .w = 5.86, .h = 6.94446, .d = 0, .ic = 0.69446 }, // ∂ \partial (cmmi10 64)
    .{ .cp = 0x2205, .w = 5, .h = 7.5, .d = 0.55554, .ic = 0 }, // ∅ \emptyset (cmsy10 59)
    .{ .cp = 0x2207, .w = 8.33, .h = 6.83334, .d = 0, .ic = 0 }, // ∇ \nabla (cmsy10 114)
    .{ .cp = 0x2208, .w = 6.67, .h = 6.00916, .d = 1.00916, .ic = 0 }, // ∈ \in (cmsy10 50)
    .{ .cp = 0x2209, .w = 6.67, .h = 6.00916, .d = 1.00916, .ic = 0 }, // ∉ \notin (composite: \not \in)
    .{ .cp = 0x220B, .w = 6.67, .h = 6.00916, .d = 1.00916, .ic = 0 }, // ∋ \ni (cmsy10 51)
    .{ .cp = 0x2212, .w = 7.78, .h = 6.66675, .d = 1.66675, .ic = 0 }, // − minus (cmsy10 161)
    .{ .cp = 0x2213, .w = 7.78, .h = 6.66675, .d = 1.66675, .ic = 0 }, // ∓ \mp (cmsy10 168)
    .{ .cp = 0x2216, .w = 5.68, .h = 7.5, .d = 2.5, .ic = 0 }, // ∖ \setminus (cmsy10 110)
    .{ .cp = 0x2217, .w = 5, .h = 4.65277, .d = -0.34723, .ic = 0 }, // ∗ \ast (cmsy10 164)
    .{ .cp = 0x2218, .w = 4.12, .h = 4.9306, .d = -0.0694, .ic = 0 }, // ∘ \circ (cmsy10 177)
    .{ .cp = 0x2219, .w = 5, .h = 4.9306, .d = -0.0694, .ic = 0 }, // ∙ \bullet (cmsy10 178)
    .{ .cp = 0x221A, .w = 8.33, .h = 0.56, .d = 9.44, .ic = 0 }, // √ \surd (cmsy10 112)
    .{ .cp = 0x221D, .w = 7.78, .h = 4.30554, .d = 0, .ic = 0 }, // ∝ \propto (cmsy10 47)
    .{ .cp = 0x221E, .w = 10, .h = 4.30554, .d = 0, .ic = 0 }, // ∞ \infty (cmsy10 49)
    .{ .cp = 0x2223, .w = 2.78, .h = 7.5, .d = 2.5, .ic = 0 }, // ∣ \mid (cmsy10 106 \vert)
    .{ .cp = 0x2225, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // ∥ \parallel (cmsy10 107 \Vert)
    .{ .cp = 0x2227, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ∧ \wedge (cmsy10 94)
    .{ .cp = 0x2228, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ∨ \vee (cmsy10 95)
    .{ .cp = 0x2229, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ∩ \cap (cmsy10 92)
    .{ .cp = 0x222A, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ∪ \cup (cmsy10 91)
    .{ .cp = 0x223C, .w = 7.73, .h = 3.96405, .d = -1.03595, .ic = 0 }, // ∼ \sim (cmsy10 187)
    .{ .cp = 0x2240, .w = 2.8, .h = 6.94446, .d = 1.94446, .ic = 0 }, // ≀ \wr (cmsy10 111)
    .{ .cp = 0x2243, .w = 7.78, .h = 5.14807, .d = 0.14807, .ic = 0 }, // ≃ \simeq (cmsy10 39)
    .{ .cp = 0x2248, .w = 7.73, .h = 5.38488, .d = 0.38488, .ic = 0 }, // ≈ \approx (cmsy10 188)
    .{ .cp = 0x224D, .w = 7.78, .h = 5.14807, .d = 0.14807, .ic = 0 }, // ≍ \asymp (cmsy10 179)
    .{ .cp = 0x2260, .w = 7.78, .h = 3.96405, .d = -1.03595, .ic = 0 }, // ≠ \ne (composite: \not over =)
    .{ .cp = 0x2261, .w = 7.78, .h = 5.14807, .d = 0.14807, .ic = 0 }, // ≡ \equiv (cmsy10 180)
    .{ .cp = 0x2262, .w = 7.78, .h = 5.14807, .d = 0.14807, .ic = 0 }, // ≢ \not\equiv (composite: \not over ≡)
    .{ .cp = 0x2264, .w = 7.78, .h = 7.1932, .d = 2.1932, .ic = 0 }, // ≤ \leq (cmsy10 183)
    .{ .cp = 0x2265, .w = 7.78, .h = 7.1932, .d = 2.1932, .ic = 0 }, // ≥ \geq (cmsy10 184)
    .{ .cp = 0x226A, .w = 10, .h = 6.00916, .d = 1.00916, .ic = 0 }, // ≪ \ll (cmsy10 191)
    .{ .cp = 0x226B, .w = 10, .h = 6.00916, .d = 1.00916, .ic = 0 }, // ≫ \gg (cmsy10 192)
    .{ .cp = 0x227A, .w = 7.78, .h = 6.00916, .d = 1.00916, .ic = 0 }, // ≺ \prec (cmsy10 193)
    .{ .cp = 0x227B, .w = 7.78, .h = 6.00916, .d = 1.00916, .ic = 0 }, // ≻ \succ (cmsy10 194)
    .{ .cp = 0x2282, .w = 7.78, .h = 6.00916, .d = 1.00916, .ic = 0 }, // ⊂ \subset (cmsy10 189)
    .{ .cp = 0x2283, .w = 7.78, .h = 6.00916, .d = 1.00916, .ic = 0 }, // ⊃ \supset (cmsy10 190)
    .{ .cp = 0x2286, .w = 7.78, .h = 7.1932, .d = 2.1932, .ic = 0 }, // ⊆ \subseteq (cmsy10 181)
    .{ .cp = 0x2287, .w = 7.78, .h = 7.1932, .d = 2.1932, .ic = 0 }, // ⊇ \supseteq (cmsy10 182)
    .{ .cp = 0x228E, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ⊎ \uplus (cmsy10 93)
    .{ .cp = 0x2291, .w = 7.78, .h = 7.1932, .d = 2.1932, .ic = 0 }, // ⊑ \sqsubseteq (cmsy10 118)
    .{ .cp = 0x2292, .w = 7.78, .h = 7.1932, .d = 2.1932, .ic = 0 }, // ⊒ \sqsupseteq (cmsy10 119)
    .{ .cp = 0x2293, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ⊓ \sqcap (cmsy10 117)
    .{ .cp = 0x2294, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ⊔ \sqcup (cmsy10 116)
    .{ .cp = 0x2295, .w = 7.78, .h = 6.66675, .d = 1.66675, .ic = 0 }, // ⊕ \oplus (cmsy10 169)
    .{ .cp = 0x2296, .w = 7.78, .h = 6.66675, .d = 1.66675, .ic = 0 }, // ⊖ \ominus (cmsy10 170)
    .{ .cp = 0x2297, .w = 7.78, .h = 6.66675, .d = 1.66675, .ic = 0 }, // ⊗ \otimes (cmsy10 171)
    .{ .cp = 0x2298, .w = 7.78, .h = 6.66675, .d = 1.66675, .ic = 0 }, // ⊘ \oslash (cmsy10 174)
    .{ .cp = 0x2299, .w = 7.78, .h = 6.66675, .d = 1.66675, .ic = 0 }, // ⊙ \odot (cmsy10 175)
    .{ .cp = 0x22A2, .w = 6.11, .h = 6.94446, .d = 0, .ic = 0 }, // ⊢ \vdash (cmsy10 96)
    .{ .cp = 0x22A3, .w = 6.11, .h = 6.94446, .d = 0, .ic = 0 }, // ⊣ \dashv (cmsy10 97)
    .{ .cp = 0x22A5, .w = 7.78, .h = 6.94446, .d = 0, .ic = 0 }, // ⊥ \perp (cmsy10 63)
    .{ .cp = 0x22C4, .w = 5, .h = 4.9306, .d = -0.0694, .ic = 0.08 }, // ⋄ \diamond (cmsy10 166)
    .{ .cp = 0x22C5, .w = 2.78, .h = 4.9306, .d = -0.0694, .ic = 0 }, // ⋅ \cdot (cmsy10 middle dot)
    .{ .cp = 0x22C6, .w = 5, .h = 4.65277, .d = -0.34723, .ic = 0.25 }, // ⋆ \star (cmmi10 63)
    .{ .cp = 0x22EF, .w = 7.76, .h = 4.9306, .d = -0.0694, .ic = 0 }, // ⋯ \cdots (composite: 3 × cdot)
    .{ .cp = 0x2308, .w = 4.44, .h = 7.5, .d = 2.5, .ic = 0 }, // ⌈ \lceil (cmsy10 100)
    .{ .cp = 0x2309, .w = 4.44, .h = 7.5, .d = 2.5, .ic = 0 }, // ⌉ \rceil (cmsy10 101)
    .{ .cp = 0x230A, .w = 4.44, .h = 7.5, .d = 2.5, .ic = 0 }, // ⌊ \lfloor (cmsy10 98)
    .{ .cp = 0x230B, .w = 4.44, .h = 7.5, .d = 2.5, .ic = 0 }, // ⌋ \rfloor (cmsy10 99)
    .{ .cp = 0x2322, .w = 10, .h = 3.57638, .d = -1.42362, .ic = 0 }, // ⌢ \frown (cmmi10 95)
    .{ .cp = 0x2323, .w = 10, .h = 3.57638, .d = -1.42362, .ic = 0 }, // ⌣ \smile (cmmi10 94)
    .{ .cp = 0x25B9, .w = 7.3612, .h = 4.65277, .d = -0.34723, .ic = 0 }, // ▹ \triangleright (cmmi10 46)
    .{ .cp = 0x25C3, .w = 7.3612, .h = 4.65277, .d = -0.34723, .ic = 0 }, // ◃ \triangleleft (cmmi10 47)
    .{ .cp = 0x25CB, .w = 7.96, .h = 6.94446, .d = 1.94446, .ic = 0 }, // ○ \bigcirc (cmsy10 176)
    .{ .cp = 0x27E8, .w = 3.89, .h = 7.5, .d = 2.5, .ic = 0 }, // ⟨ \langle (cmsy10 104)
    .{ .cp = 0x27E9, .w = 3.89, .h = 7.5, .d = 2.5, .ic = 0 }, // ⟩ \rangle (cmsy10 105)
    .{ .cp = 0x2A3F, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0 }, // ⨿ \amalg (cmsy10 113)
    .{ .cp = 0x2AAF, .w = 7.78, .h = 7.1932, .d = 2.1932, .ic = 0 }, // ⪯ \preceq (cmsy10 185)
    .{ .cp = 0x2AB0, .w = 7.78, .h = 7.1932, .d = 2.1932, .ic = 0 }, // ⪰ \succeq (cmsy10 186)
    .{ .cp = 0x1D434, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0 }, // 𝐴
    .{ .cp = 0x1D435, .w = 7.59, .h = 6.83334, .d = 0, .ic = 0.46701 }, // 𝐵
    .{ .cp = 0x1D436, .w = 7.15, .h = 6.83334, .d = 0, .ic = 0.68054 }, // 𝐶
    .{ .cp = 0x1D437, .w = 8.28, .h = 6.83334, .d = 0, .ic = 0.34723 }, // 𝐷
    .{ .cp = 0x1D438, .w = 7.38, .h = 6.83334, .d = 0, .ic = 0.51389 }, // 𝐸
    .{ .cp = 0x1D439, .w = 6.43, .h = 6.83334, .d = 0, .ic = 1.73615 }, // 𝐹
    .{ .cp = 0x1D43A, .w = 7.86, .h = 6.83334, .d = 0, .ic = 0 }, // 𝐺
    .{ .cp = 0x1D43B, .w = 8.31, .h = 6.83334, .d = 0, .ic = 0.74305 }, // 𝐻
    .{ .cp = 0x1D43C, .w = 4.4, .h = 6.83334, .d = 0, .ic = 0.76736 }, // 𝐼
    .{ .cp = 0x1D43D, .w = 5.55, .h = 6.83334, .d = 0, .ic = 0.95139 }, // 𝐽
    .{ .cp = 0x1D43E, .w = 8.49, .h = 6.83334, .d = 0, .ic = 0.68054 }, // 𝐾
    .{ .cp = 0x1D43F, .w = 6.81, .h = 6.83334, .d = 0, .ic = 0 }, // 𝐿
    .{ .cp = 0x1D440, .w = 9.7, .h = 6.83334, .d = 0, .ic = 1.09027 }, // 𝑀
    .{ .cp = 0x1D441, .w = 8.03, .h = 6.83334, .d = 0, .ic = 1.09027 }, // 𝑁
    .{ .cp = 0x1D442, .w = 7.63, .h = 6.83334, .d = 0, .ic = 0.34723 }, // 𝑂
    .{ .cp = 0x1D443, .w = 6.42, .h = 6.83334, .d = 0, .ic = 1.73615 }, // 𝑃
    .{ .cp = 0x1D444, .w = 7.91, .h = 6.83334, .d = 1.94446, .ic = 0 }, // 𝑄
    .{ .cp = 0x1D445, .w = 7.59, .h = 6.83334, .d = 0, .ic = 0.24 }, // 𝑅
    .{ .cp = 0x1D446, .w = 6.13, .h = 6.83334, .d = 0, .ic = 0.50693 }, // 𝑆
    .{ .cp = 0x1D447, .w = 5.84, .h = 6.83334, .d = 0, .ic = 1.73615 }, // 𝑇
    .{ .cp = 0x1D448, .w = 6.83, .h = 6.83334, .d = 0, .ic = 1.09027 }, // 𝑈
    .{ .cp = 0x1D449, .w = 5.83, .h = 6.83334, .d = 0, .ic = 0.08 }, // 𝑉
    .{ .cp = 0x1D44A, .w = 9.44, .h = 6.83334, .d = 0, .ic = 0.09 }, // 𝑊
    .{ .cp = 0x1D44B, .w = 8.28, .h = 6.83334, .d = 0, .ic = 0.04 }, // 𝑋
    .{ .cp = 0x1D44C, .w = 5.81, .h = 6.83334, .d = 0, .ic = 0.16 }, // 𝑌
    .{ .cp = 0x1D44D, .w = 6.83, .h = 6.83334, .d = 0, .ic = 0.68054 }, // 𝑍
    .{ .cp = 0x1D44E, .w = 5.29, .h = 4.30554, .d = 0, .ic = 0.11 }, // 𝑎
    .{ .cp = 0x1D44F, .w = 4.29, .h = 6.94446, .d = 0, .ic = 0 }, // 𝑏
    .{ .cp = 0x1D450, .w = 4.33, .h = 4.30554, .d = 0, .ic = 0 }, // 𝑐
    .{ .cp = 0x1D451, .w = 5.2, .h = 6.94446, .d = 0, .ic = 0 }, // 𝑑
    .{ .cp = 0x1D452, .w = 4.66, .h = 4.30554, .d = 0, .ic = 0 }, // 𝑒
    .{ .cp = 0x1D453, .w = 4.9, .h = 6.94446, .d = 1.94446, .ic = 0.79 }, // 𝑓
    .{ .cp = 0x1D454, .w = 4.77, .h = 4.30554, .d = 1.94446, .ic = 0.13 }, // 𝑔
    .{ .cp = 0x1D456, .w = 3.45, .h = 6.66468, .d = 0, .ic = 0 }, // 𝑖
    .{ .cp = 0x1D457, .w = 4.12, .h = 6.66468, .d = 1.94446, .ic = 0.58978 }, // 𝑗
    .{ .cp = 0x1D458, .w = 5.21, .h = 6.94446, .d = 0, .ic = 0.11 }, // 𝑘
    .{ .cp = 0x1D459, .w = 2.98, .h = 6.94446, .d = 0, .ic = 0.05 }, // 𝑙
    .{ .cp = 0x1D45A, .w = 8.78, .h = 4.30554, .d = 0, .ic = 0.08 }, // 𝑚
    .{ .cp = 0x1D45B, .w = 6, .h = 4.30554, .d = 0, .ic = 0.07 }, // 𝑛
    .{ .cp = 0x1D45C, .w = 4.85, .h = 4.30554, .d = 0, .ic = 0 }, // 𝑜
    .{ .cp = 0x1D45D, .w = 5.03, .h = 4.30554, .d = 1.94446, .ic = 0 }, // 𝑝
    .{ .cp = 0x1D45E, .w = 4.46, .h = 4.30554, .d = 1.94446, .ic = 0.27 }, // 𝑞
    .{ .cp = 0x1D45F, .w = 4.51, .h = 4.30554, .d = 0, .ic = 0.34723 }, // 𝑟
    .{ .cp = 0x1D460, .w = 4.69, .h = 4.30554, .d = 0, .ic = 0 }, // 𝑠
    .{ .cp = 0x1D461, .w = 3.61, .h = 6.15079, .d = 0, .ic = 0 }, // 𝑡
    .{ .cp = 0x1D462, .w = 5.72, .h = 4.30554, .d = 0, .ic = 0.07 }, // 𝑢
    .{ .cp = 0x1D463, .w = 4.85, .h = 4.30554, .d = 0, .ic = 0.08 }, // 𝑣
    .{ .cp = 0x1D464, .w = 7.16, .h = 4.30554, .d = 0, .ic = 0.09 }, // 𝑤
    .{ .cp = 0x1D465, .w = 5.72, .h = 4.30554, .d = 0, .ic = 0.16 }, // 𝑥
    .{ .cp = 0x1D466, .w = 4.9, .h = 4.30554, .d = 1.94446, .ic = 0.08 }, // 𝑦
    .{ .cp = 0x1D467, .w = 4.65, .h = 4.30554, .d = 0, .ic = 0.37036 }, // 𝑧
    .{ .cp = 0x1D715, .w = 5.31, .h = 6.94446, .d = 0, .ic = 0.69446 }, // 𝜕
};

/// Roman-style letters for scriptscript size, the roman partner of
/// `table_roman` at the 5pt band (glyphAt picks it when style is `.roman`):
/// LM Math advances (em × 10), scaled linearly at 5pt by the layout.
const table_roman5 = [_]Entry{
    .{ .cp = 0x0041, .w = 7.5, .h = 6.79761, .d = 0, .ic = 0 }, // A
    .{ .cp = 0x0042, .w = 7.08, .h = 6.79761, .d = 0, .ic = 0 }, // B
    .{ .cp = 0x0043, .w = 7.22, .h = 6.79761, .d = 0, .ic = 0 }, // C
    .{ .cp = 0x0044, .w = 7.64, .h = 6.79761, .d = 0, .ic = 0 }, // D
    .{ .cp = 0x0045, .w = 6.81, .h = 6.79761, .d = 0, .ic = 0 }, // E
    .{ .cp = 0x0046, .w = 6.53, .h = 6.79761, .d = 0, .ic = 0 }, // F
    .{ .cp = 0x0047, .w = 7.85, .h = 6.79761, .d = 0, .ic = 0 }, // G
    .{ .cp = 0x0048, .w = 7.5, .h = 6.79761, .d = 0, .ic = 0 }, // H
    .{ .cp = 0x0049, .w = 3.61, .h = 6.79761, .d = 0, .ic = 0 }, // I
    .{ .cp = 0x004A, .w = 5.14, .h = 6.79761, .d = 0, .ic = 0 }, // J
    .{ .cp = 0x004B, .w = 7.78, .h = 6.79761, .d = 0, .ic = 0 }, // K
    .{ .cp = 0x004C, .w = 6.25, .h = 6.79761, .d = 0, .ic = 0 }, // L
    .{ .cp = 0x004D, .w = 9.17, .h = 6.79761, .d = 0, .ic = 0 }, // M
    .{ .cp = 0x004E, .w = 7.5, .h = 6.79761, .d = 0, .ic = 0 }, // N
    .{ .cp = 0x004F, .w = 7.78, .h = 6.79761, .d = 0, .ic = 0 }, // O
    .{ .cp = 0x0050, .w = 6.81, .h = 6.79761, .d = 0, .ic = 0 }, // P
    .{ .cp = 0x0051, .w = 7.78, .h = 6.79761, .d = 1.94446, .ic = 0 }, // Q
    .{ .cp = 0x0052, .w = 7.36, .h = 6.79761, .d = 0, .ic = 0.24 }, // R
    .{ .cp = 0x0053, .w = 5.56, .h = 6.79761, .d = 0, .ic = 0 }, // S
    .{ .cp = 0x0054, .w = 7.22, .h = 6.79761, .d = 0, .ic = 0 }, // T
    .{ .cp = 0x0055, .w = 7.5, .h = 6.79761, .d = 0, .ic = 0 }, // U
    .{ .cp = 0x0056, .w = 7.5, .h = 6.79761, .d = 0, .ic = 0.08 }, // V
    .{ .cp = 0x0057, .w = 10.28, .h = 6.79761, .d = 0, .ic = 0.09 }, // W
    .{ .cp = 0x0058, .w = 7.5, .h = 6.79761, .d = 0, .ic = 0.04 }, // X
    .{ .cp = 0x0059, .w = 7.5, .h = 6.79761, .d = 0, .ic = 0.16 }, // Y
    .{ .cp = 0x005A, .w = 6.11, .h = 6.79761, .d = 0, .ic = 0 }, // Z
    .{ .cp = 0x0061, .w = 5, .h = 4.30554, .d = 0, .ic = 0.11 }, // a
    .{ .cp = 0x0062, .w = 5.56, .h = 6.94446, .d = 0, .ic = 0 }, // b
    .{ .cp = 0x0063, .w = 4.44, .h = 4.30554, .d = 0, .ic = 0 }, // c
    .{ .cp = 0x0064, .w = 5.56, .h = 6.94446, .d = 0, .ic = 0 }, // d
    .{ .cp = 0x0065, .w = 4.44, .h = 4.30554, .d = 0, .ic = 0 }, // e
    .{ .cp = 0x0066, .w = 3.06, .h = 6.94446, .d = 0, .ic = 0.79 }, // f
    .{ .cp = 0x0067, .w = 5, .h = 4.30554, .d = 1.94446, .ic = 0.13 }, // g
    .{ .cp = 0x0068, .w = 5.56, .h = 6.94446, .d = 0, .ic = 0.07 }, // h
    .{ .cp = 0x0069, .w = 2.78, .h = 6.79761, .d = 0, .ic = 0 }, // i
    .{ .cp = 0x006A, .w = 3.06, .h = 6.79761, .d = 1.94446, .ic = 0 }, // j
    .{ .cp = 0x006B, .w = 5.28, .h = 6.94446, .d = 0, .ic = 0.11 }, // k
    .{ .cp = 0x006C, .w = 2.78, .h = 6.94446, .d = 0, .ic = 0.05 }, // l
    .{ .cp = 0x006D, .w = 8.33, .h = 4.30554, .d = 0, .ic = 0.08 }, // m
    .{ .cp = 0x006E, .w = 5.56, .h = 4.30554, .d = 0, .ic = 0.07 }, // n
    .{ .cp = 0x006F, .w = 5, .h = 4.30554, .d = 0, .ic = 0 }, // o
    .{ .cp = 0x0070, .w = 5.56, .h = 4.30554, .d = 1.94446, .ic = 0 }, // p
    .{ .cp = 0x0071, .w = 5.28, .h = 4.30554, .d = 1.94446, .ic = 0.27 }, // q
    .{ .cp = 0x0072, .w = 3.92, .h = 4.30554, .d = 0, .ic = 0 }, // r
    .{ .cp = 0x0073, .w = 3.94, .h = 4.30554, .d = 0, .ic = 0 }, // s
    .{ .cp = 0x0074, .w = 3.89, .h = 6.15079, .d = 0, .ic = 0 }, // t
    .{ .cp = 0x0075, .w = 5.56, .h = 4.30554, .d = 0, .ic = 0.07 }, // u
    .{ .cp = 0x0076, .w = 5.28, .h = 4.30554, .d = 0, .ic = 0.08 }, // v
    .{ .cp = 0x0077, .w = 7.22, .h = 4.30554, .d = 0, .ic = 0.09 }, // w
    .{ .cp = 0x0078, .w = 5.28, .h = 4.30554, .d = 0, .ic = 0.16 }, // x
    .{ .cp = 0x0079, .w = 5.28, .h = 4.30554, .d = 1.94446, .ic = 0.08 }, // y
    .{ .cp = 0x007A, .w = 4.44, .h = 4.30554, .d = 0, .ic = 0 }, // z
};

/// One row of the drawn-ink table: ascent / descent in em of the glyph
/// font-size (drawn size = the size the layout passes to the SVG <text>).
const InkEntry = struct {
    cp: u21,
    a: f32,
    d: f32,
};

/// Drawn-glyph ink extents for every codepoint in the metric tables above,
/// in em of the glyph's font-size, measured with fontTools BoundsPen on
/// latinmodern-math.otf 2.005 (CFF outline bounds, per-mille → em; the
/// big-op rows reproduce the bigOpInk table in layout.zig exactly).
/// Sorted by `cp` (binary-search invariant). layoutChar/layoutText box
/// every normal glyph by this ink × the drawn size, so the box (and the
/// frame/viewBox) bounds the ink that is actually drawn: the cmr10/cmmi10
/// h/d are the Computer-Modern DESIGN box, and the LMMath ink pokes past
/// it for digits (0.666em vs cmr10 0.644em), ascender letters (0.694 vs
/// 0.6944 — a match), descenders (0.205 vs 0.1944), and the
/// delimiters/operators (0.750/0.250 full box). The WIDTH stays the
/// metric-table advance; only height/depth change. Codepoints absent from
/// LMMath (ams-only symbols, CJK, …) get the font's design bound
/// 0.750/0.250 via glyphInk — safe for the browser fallback fonts.
const ink_table = [_]InkEntry{
    .{ .cp = 0x0021, .a = 0.716, .d = 0.000 }, // !
    .{ .cp = 0x0023, .a = 0.694, .d = 0.194 }, // #
    .{ .cp = 0x0024, .a = 0.750, .d = 0.056 }, // $
    .{ .cp = 0x0025, .a = 0.750, .d = 0.056 }, // %
    .{ .cp = 0x0026, .a = 0.716, .d = 0.022 }, // &
    .{ .cp = 0x0028, .a = 0.748, .d = 0.248 }, // (
    .{ .cp = 0x0029, .a = 0.748, .d = 0.248 }, // )
    .{ .cp = 0x002B, .a = 0.583, .d = 0.083 }, // +
    .{ .cp = 0x002C, .a = 0.106, .d = 0.193 }, // ,
    .{ .cp = 0x002D, .a = 0.245, .d = 0.000 }, // -
    .{ .cp = 0x002E, .a = 0.106, .d = 0.000 }, // .
    .{ .cp = 0x002F, .a = 0.750, .d = 0.250 }, // /
    .{ .cp = 0x0030, .a = 0.666, .d = 0.022 }, // 0
    .{ .cp = 0x0031, .a = 0.666, .d = 0.000 }, // 1
    .{ .cp = 0x0032, .a = 0.666, .d = 0.000 }, // 2
    .{ .cp = 0x0033, .a = 0.666, .d = 0.022 }, // 3
    .{ .cp = 0x0034, .a = 0.677, .d = 0.000 }, // 4
    .{ .cp = 0x0035, .a = 0.666, .d = 0.022 }, // 5
    .{ .cp = 0x0036, .a = 0.666, .d = 0.022 }, // 6
    .{ .cp = 0x0037, .a = 0.676, .d = 0.022 }, // 7
    .{ .cp = 0x0038, .a = 0.666, .d = 0.022 }, // 8
    .{ .cp = 0x0039, .a = 0.666, .d = 0.022 }, // 9
    .{ .cp = 0x003A, .a = 0.431, .d = 0.000 }, // :
    .{ .cp = 0x003B, .a = 0.431, .d = 0.193 }, // ;
    .{ .cp = 0x003C, .a = 0.547, .d = 0.047 }, // <
    .{ .cp = 0x003D, .a = 0.367, .d = 0.000 }, // =
    .{ .cp = 0x003E, .a = 0.547, .d = 0.047 }, // >
    .{ .cp = 0x0041, .a = 0.716, .d = 0.000 }, // A
    .{ .cp = 0x0042, .a = 0.683, .d = 0.000 }, // B
    .{ .cp = 0x0043, .a = 0.705, .d = 0.022 }, // C
    .{ .cp = 0x0044, .a = 0.683, .d = 0.000 }, // D
    .{ .cp = 0x0045, .a = 0.680, .d = 0.000 }, // E
    .{ .cp = 0x0046, .a = 0.680, .d = 0.000 }, // F
    .{ .cp = 0x0047, .a = 0.705, .d = 0.022 }, // G
    .{ .cp = 0x0048, .a = 0.683, .d = 0.000 }, // H
    .{ .cp = 0x0049, .a = 0.683, .d = 0.000 }, // I
    .{ .cp = 0x004A, .a = 0.683, .d = 0.022 }, // J
    .{ .cp = 0x004B, .a = 0.683, .d = 0.000 }, // K
    .{ .cp = 0x004C, .a = 0.683, .d = 0.000 }, // L
    .{ .cp = 0x004D, .a = 0.683, .d = 0.000 }, // M
    .{ .cp = 0x004E, .a = 0.683, .d = 0.000 }, // N
    .{ .cp = 0x004F, .a = 0.705, .d = 0.022 }, // O
    .{ .cp = 0x0050, .a = 0.683, .d = 0.000 }, // P
    .{ .cp = 0x0051, .a = 0.705, .d = 0.194 }, // Q
    .{ .cp = 0x0052, .a = 0.683, .d = 0.022 }, // R
    .{ .cp = 0x0053, .a = 0.705, .d = 0.022 }, // S
    .{ .cp = 0x0054, .a = 0.677, .d = 0.000 }, // T
    .{ .cp = 0x0055, .a = 0.683, .d = 0.022 }, // U
    .{ .cp = 0x0056, .a = 0.683, .d = 0.022 }, // V
    .{ .cp = 0x0057, .a = 0.683, .d = 0.022 }, // W
    .{ .cp = 0x0058, .a = 0.683, .d = 0.000 }, // X
    .{ .cp = 0x0059, .a = 0.683, .d = 0.000 }, // Y
    .{ .cp = 0x005A, .a = 0.683, .d = 0.000 }, // Z
    .{ .cp = 0x005B, .a = 0.750, .d = 0.250 }, // [
    .{ .cp = 0x005D, .a = 0.750, .d = 0.250 }, // ]
    .{ .cp = 0x005F, .a = 0.000, .d = 0.140 }, // _
    .{ .cp = 0x0061, .a = 0.448, .d = 0.011 }, // a
    .{ .cp = 0x0062, .a = 0.694, .d = 0.011 }, // b
    .{ .cp = 0x0063, .a = 0.448, .d = 0.011 }, // c
    .{ .cp = 0x0064, .a = 0.694, .d = 0.011 }, // d
    .{ .cp = 0x0065, .a = 0.448, .d = 0.011 }, // e
    .{ .cp = 0x0066, .a = 0.705, .d = 0.000 }, // f
    .{ .cp = 0x0067, .a = 0.453, .d = 0.206 }, // g
    .{ .cp = 0x0068, .a = 0.694, .d = 0.000 }, // h
    .{ .cp = 0x0069, .a = 0.657, .d = 0.000 }, // i
    .{ .cp = 0x006A, .a = 0.657, .d = 0.205 }, // j
    .{ .cp = 0x006B, .a = 0.694, .d = 0.000 }, // k
    .{ .cp = 0x006C, .a = 0.694, .d = 0.000 }, // l
    .{ .cp = 0x006D, .a = 0.442, .d = 0.000 }, // m
    .{ .cp = 0x006E, .a = 0.442, .d = 0.000 }, // n
    .{ .cp = 0x006F, .a = 0.448, .d = 0.011 }, // o
    .{ .cp = 0x0070, .a = 0.442, .d = 0.194 }, // p
    .{ .cp = 0x0071, .a = 0.442, .d = 0.194 }, // q
    .{ .cp = 0x0072, .a = 0.442, .d = 0.000 }, // r
    .{ .cp = 0x0073, .a = 0.448, .d = 0.011 }, // s
    .{ .cp = 0x0074, .a = 0.615, .d = 0.011 }, // t
    .{ .cp = 0x0075, .a = 0.442, .d = 0.011 }, // u
    .{ .cp = 0x0076, .a = 0.431, .d = 0.011 }, // v
    .{ .cp = 0x0077, .a = 0.431, .d = 0.011 }, // w
    .{ .cp = 0x0078, .a = 0.431, .d = 0.000 }, // x
    .{ .cp = 0x0079, .a = 0.431, .d = 0.205 }, // y
    .{ .cp = 0x007A, .a = 0.431, .d = 0.000 }, // z
    .{ .cp = 0x007B, .a = 0.750, .d = 0.250 }, // {
    .{ .cp = 0x007C, .a = 0.750, .d = 0.250 }, // |
    .{ .cp = 0x007D, .a = 0.750, .d = 0.250 }, // }
    .{ .cp = 0x00A3, .a = 0.683, .d = 0.035 }, // £
    .{ .cp = 0x00A5, .a = 0.683, .d = 0.000 }, // ¥
    .{ .cp = 0x00A7, .a = 0.705, .d = 0.205 }, // §
    .{ .cp = 0x00A9, .a = 0.683, .d = 0.000 }, // ©
    .{ .cp = 0x00AC, .a = 0.367, .d = 0.000 }, // ¬
    .{ .cp = 0x00B1, .a = 0.583, .d = 0.084 }, // ±
    .{ .cp = 0x00B6, .a = 0.694, .d = 0.194 }, // ¶
    .{ .cp = 0x00B7, .a = 0.303, .d = 0.000 }, // ·
    .{ .cp = 0x00D7, .a = 0.491, .d = 0.000 }, // ×
    .{ .cp = 0x00F0, .a = 0.695, .d = 0.011 }, // ð
    .{ .cp = 0x00F7, .a = 0.504, .d = 0.004 }, // ÷
    .{ .cp = 0x0131, .a = 0.442, .d = 0.000 }, // ı
    .{ .cp = 0x0237, .a = 0.442, .d = 0.205 }, // ȷ
    .{ .cp = 0x0302, .a = 0.734, .d = 0.000 }, // ̂ \hat (combining circumflex; ink above baseline)
    .{ .cp = 0x0303, .a = 0.746, .d = 0.000 }, // ̃ \tilde (combining tilde)
    .{ .cp = 0x0304, .a = 0.640, .d = 0.000 }, // ̄ \bar (combining macron)
    .{ .cp = 0x0307, .a = 0.677, .d = 0.000 }, // ̇ \dot (combining dot above)
    .{ .cp = 0x0308, .a = 0.672, .d = 0.000 }, // ̈ \ddot (combining diaeresis)
    .{ .cp = 0x0338, .a = 0.750, .d = 0.250 }, // ͸ \not slash (overlay)
    .{ .cp = 0x0391, .a = 0.683, .d = 0.000 }, // Α
    .{ .cp = 0x0392, .a = 0.683, .d = 0.000 }, // Β
    .{ .cp = 0x0393, .a = 0.680, .d = 0.000 }, // Γ
    .{ .cp = 0x0394, .a = 0.716, .d = 0.000 }, // Δ
    .{ .cp = 0x0398, .a = 0.705, .d = 0.022 }, // Θ
    .{ .cp = 0x039B, .a = 0.716, .d = 0.000 }, // Λ
    .{ .cp = 0x039E, .a = 0.677, .d = 0.000 }, // Ξ
    .{ .cp = 0x03A0, .a = 0.680, .d = 0.000 }, // Π
    .{ .cp = 0x03A3, .a = 0.683, .d = 0.000 }, // Σ
    .{ .cp = 0x03A5, .a = 0.705, .d = 0.000 }, // Υ
    .{ .cp = 0x03A6, .a = 0.683, .d = 0.000 }, // Φ
    .{ .cp = 0x03A8, .a = 0.683, .d = 0.000 }, // Ψ
    .{ .cp = 0x03A9, .a = 0.705, .d = 0.000 }, // Ω
    .{ .cp = 0x03B1, .a = 0.442, .d = 0.011 }, // α
    .{ .cp = 0x03B2, .a = 0.706, .d = 0.194 }, // β
    .{ .cp = 0x03B3, .a = 0.442, .d = 0.215 }, // γ
    .{ .cp = 0x03B4, .a = 0.712, .d = 0.011 }, // δ
    .{ .cp = 0x03B5, .a = 0.453, .d = 0.022 }, // ε
    .{ .cp = 0x03B6, .a = 0.697, .d = 0.205 }, // ζ
    .{ .cp = 0x03B7, .a = 0.442, .d = 0.216 }, // η
    .{ .cp = 0x03B8, .a = 0.705, .d = 0.011 }, // θ
    .{ .cp = 0x03B9, .a = 0.442, .d = 0.011 }, // ι
    .{ .cp = 0x03BA, .a = 0.442, .d = 0.011 }, // κ
    .{ .cp = 0x03BB, .a = 0.694, .d = 0.013 }, // λ
    .{ .cp = 0x03BC, .a = 0.442, .d = 0.216 }, // μ
    .{ .cp = 0x03BD, .a = 0.442, .d = 0.000 }, // ν
    .{ .cp = 0x03BE, .a = 0.697, .d = 0.205 }, // ξ
    .{ .cp = 0x03BF, .a = 0.448, .d = 0.011 }, // ο
    .{ .cp = 0x03C0, .a = 0.431, .d = 0.011 }, // π
    .{ .cp = 0x03C1, .a = 0.442, .d = 0.216 }, // ρ
    .{ .cp = 0x03C2, .a = 0.442, .d = 0.108 }, // ς
    .{ .cp = 0x03C3, .a = 0.431, .d = 0.011 }, // σ
    .{ .cp = 0x03C4, .a = 0.431, .d = 0.012 }, // τ
    .{ .cp = 0x03C5, .a = 0.442, .d = 0.011 }, // υ
    .{ .cp = 0x03C6, .a = 0.442, .d = 0.218 }, // φ
    .{ .cp = 0x03C7, .a = 0.442, .d = 0.205 }, // χ
    .{ .cp = 0x03C8, .a = 0.694, .d = 0.205 }, // ψ
    .{ .cp = 0x03C9, .a = 0.442, .d = 0.011 }, // ω
    .{ .cp = 0x03D1, .a = 0.705, .d = 0.011 }, // ϑ
    .{ .cp = 0x03D5, .a = 0.694, .d = 0.205 }, // ϕ
    .{ .cp = 0x03D6, .a = 0.431, .d = 0.011 }, // ϖ
    .{ .cp = 0x03D8, .a = 0.750, .d = 0.250 }, // Ϙ
    .{ .cp = 0x03F1, .a = 0.442, .d = 0.194 }, // ϱ
    .{ .cp = 0x03F5, .a = 0.431, .d = 0.011 }, // ϵ
    .{ .cp = 0x2020, .a = 0.705, .d = 0.216 }, // †
    .{ .cp = 0x2021, .a = 0.705, .d = 0.205 }, // ‡
    .{ .cp = 0x2026, .a = 0.106, .d = 0.000 }, // …
    .{ .cp = 0x2032, .a = 0.748, .d = 0.000 }, // ′
    .{ .cp = 0x2033, .a = 0.748, .d = 0.000 }, // ″
    .{ .cp = 0x2035, .a = 0.748, .d = 0.000 }, // ‵
    .{ .cp = 0x20D7, .a = 0.711, .d = 0.000 }, // ⃗ \vec (combining right arrow above)
    .{ .cp = 0x210E, .a = 0.694, .d = 0.011 }, // ℎ
    .{ .cp = 0x210F, .a = 0.694, .d = 0.011 }, // ℏ
    .{ .cp = 0x2111, .a = 0.686, .d = 0.027 }, // ℑ
    .{ .cp = 0x2113, .a = 0.705, .d = 0.012 }, // ℓ
    .{ .cp = 0x2118, .a = 0.453, .d = 0.216 }, // ℘
    .{ .cp = 0x211C, .a = 0.686, .d = 0.027 }, // ℜ
    .{ .cp = 0x2127, .a = 0.684, .d = 0.021 }, // ℧
    .{ .cp = 0x2135, .a = 0.693, .d = 0.000 }, // ℵ
    .{ .cp = 0x2190, .a = 0.510, .d = 0.010 }, // ←
    .{ .cp = 0x2191, .a = 0.679, .d = 0.203 }, // ↑
    .{ .cp = 0x2192, .a = 0.510, .d = 0.010 }, // →
    .{ .cp = 0x2193, .a = 0.703, .d = 0.179 }, // ↓
    .{ .cp = 0x2194, .a = 0.510, .d = 0.010 }, // ↔
    .{ .cp = 0x2195, .a = 0.757, .d = 0.257 }, // ↕
    .{ .cp = 0x2196, .a = 0.714, .d = 0.203 }, // ↖
    .{ .cp = 0x2197, .a = 0.714, .d = 0.203 }, // ↗
    .{ .cp = 0x2198, .a = 0.703, .d = 0.214 }, // ↘
    .{ .cp = 0x2199, .a = 0.703, .d = 0.214 }, // ↙
    .{ .cp = 0x21A3, .a = 0.510, .d = 0.010 }, // ↣
    .{ .cp = 0x21A6, .a = 0.510, .d = 0.010 }, // ↦
    .{ .cp = 0x21A9, .a = 0.550, .d = 0.010 }, // ↩
    .{ .cp = 0x21AA, .a = 0.550, .d = 0.010 }, // ↪
    .{ .cp = 0x21BC, .a = 0.503, .d = 0.000 }, // ↼
    .{ .cp = 0x21BD, .a = 0.270, .d = 0.003 }, // ↽
    .{ .cp = 0x21C0, .a = 0.503, .d = 0.000 }, // ⇀
    .{ .cp = 0x21C1, .a = 0.270, .d = 0.003 }, // ⇁
    .{ .cp = 0x21C4, .a = 0.672, .d = 0.172 }, // ⇄
    .{ .cp = 0x21D0, .a = 0.520, .d = 0.020 }, // ⇐
    .{ .cp = 0x21D1, .a = 0.676, .d = 0.203 }, // ⇑
    .{ .cp = 0x21D2, .a = 0.520, .d = 0.020 }, // ⇒
    .{ .cp = 0x21D3, .a = 0.703, .d = 0.176 }, // ⇓
    .{ .cp = 0x21D4, .a = 0.520, .d = 0.020 }, // ⇔
    .{ .cp = 0x21D5, .a = 0.728, .d = 0.228 }, // ⇕
    .{ .cp = 0x2200, .a = 0.684, .d = 0.000 }, // ∀
    .{ .cp = 0x2202, .a = 0.716, .d = 0.022 }, // ∂
    .{ .cp = 0x2203, .a = 0.684, .d = 0.000 }, // ∃
    .{ .cp = 0x2204, .a = 0.789, .d = 0.105 }, // ∄
    .{ .cp = 0x2205, .a = 0.772, .d = 0.078 }, // ∅
    .{ .cp = 0x2207, .a = 0.683, .d = 0.033 }, // ∇
    .{ .cp = 0x2208, .a = 0.543, .d = 0.043 }, // ∈
    .{ .cp = 0x2209, .a = 0.730, .d = 0.230 }, // ∉
    .{ .cp = 0x220B, .a = 0.543, .d = 0.043 }, // ∋
    .{ .cp = 0x220C, .a = 0.730, .d = 0.230 }, // ∌
    .{ .cp = 0x220F, .a = 0.750, .d = 0.250 }, // ∏
    .{ .cp = 0x2210, .a = 0.750, .d = 0.250 }, // ∐
    .{ .cp = 0x2211, .a = 0.750, .d = 0.250 }, // ∑
    .{ .cp = 0x2212, .a = 0.270, .d = 0.000 }, // −
    .{ .cp = 0x2213, .a = 0.584, .d = 0.083 }, // ∓
    .{ .cp = 0x2215, .a = 0.603, .d = 0.103 }, // ∕
    .{ .cp = 0x2216, .a = 0.603, .d = 0.103 }, // ∖
    .{ .cp = 0x2217, .a = 0.462, .d = 0.000 }, // ∗
    .{ .cp = 0x2218, .a = 0.400, .d = 0.000 }, // ∘
    .{ .cp = 0x2219, .a = 0.445, .d = 0.000 }, // ∙
    .{ .cp = 0x221A, .a = 0.040, .d = 0.960 }, // √
    .{ .cp = 0x221D, .a = 0.442, .d = 0.011 }, // ∝
    .{ .cp = 0x221E, .a = 0.442, .d = 0.011 }, // ∞
    .{ .cp = 0x2220, .a = 0.724, .d = 0.000 }, // ∠
    .{ .cp = 0x2221, .a = 0.724, .d = 0.109 }, // ∡
    .{ .cp = 0x2222, .a = 0.562, .d = 0.062 }, // ∢
    .{ .cp = 0x2223, .a = 0.750, .d = 0.250 }, // ∣
    .{ .cp = 0x2224, .a = 0.750, .d = 0.250 }, // ∤
    .{ .cp = 0x2225, .a = 0.750, .d = 0.250 }, // ∥
    .{ .cp = 0x2226, .a = 0.750, .d = 0.250 }, // ∦
    .{ .cp = 0x2227, .a = 0.602, .d = 0.020 }, // ∧
    .{ .cp = 0x2228, .a = 0.601, .d = 0.021 }, // ∨
    .{ .cp = 0x2229, .a = 0.604, .d = 0.020 }, // ∩
    .{ .cp = 0x222A, .a = 0.604, .d = 0.020 }, // ∪
    .{ .cp = 0x222B, .a = 0.805, .d = 0.306 }, // ∫
    .{ .cp = 0x222E, .a = 0.805, .d = 0.306 }, // ∮
    .{ .cp = 0x2234, .a = 0.416, .d = 0.000 }, // ∴
    .{ .cp = 0x2235, .a = 0.416, .d = 0.000 }, // ∵
    .{ .cp = 0x223C, .a = 0.366, .d = 0.000 }, // ∼
    .{ .cp = 0x2240, .a = 0.583, .d = 0.083 }, // ≀
    .{ .cp = 0x2241, .a = 0.482, .d = 0.000 }, // ≁
    .{ .cp = 0x2243, .a = 0.468, .d = 0.000 }, // ≃
    .{ .cp = 0x2244, .a = 0.603, .d = 0.103 }, // ≄
    .{ .cp = 0x2245, .a = 0.552, .d = 0.000 }, // ≅
    .{ .cp = 0x2246, .a = 0.614, .d = 0.048 }, // ≆
    .{ .cp = 0x2247, .a = 0.603, .d = 0.103 }, // ≇
    .{ .cp = 0x2248, .a = 0.457, .d = 0.000 }, // ≈
    .{ .cp = 0x2249, .a = 0.603, .d = 0.103 }, // ≉
    .{ .cp = 0x224D, .a = 0.498, .d = 0.000 }, // ≍
    .{ .cp = 0x2250, .a = 0.601, .d = 0.000 }, // ≐
    .{ .cp = 0x2260, .a = 0.730, .d = 0.230 }, // ≠
    .{ .cp = 0x2261, .a = 0.464, .d = 0.000 }, // ≡
    .{ .cp = 0x2262, .a = 0.730, .d = 0.230 }, // ≢
    .{ .cp = 0x2264, .a = 0.631, .d = 0.119 }, // ≤
    .{ .cp = 0x2265, .a = 0.631, .d = 0.119 }, // ≥
    .{ .cp = 0x2266, .a = 0.715, .d = 0.203 }, // ≦
    .{ .cp = 0x2267, .a = 0.715, .d = 0.203 }, // ≧
    .{ .cp = 0x226A, .a = 0.547, .d = 0.047 }, // ≪
    .{ .cp = 0x226B, .a = 0.547, .d = 0.047 }, // ≫
    .{ .cp = 0x226D, .a = 0.730, .d = 0.230 }, // ≭
    .{ .cp = 0x226E, .a = 0.730, .d = 0.230 }, // ≮
    .{ .cp = 0x226F, .a = 0.730, .d = 0.230 }, // ≯
    .{ .cp = 0x2270, .a = 0.730, .d = 0.230 }, // ≰
    .{ .cp = 0x2271, .a = 0.730, .d = 0.230 }, // ≱
    .{ .cp = 0x227A, .a = 0.547, .d = 0.047 }, // ≺
    .{ .cp = 0x227B, .a = 0.547, .d = 0.047 }, // ≻
    .{ .cp = 0x2280, .a = 0.730, .d = 0.230 }, // ⊀
    .{ .cp = 0x2281, .a = 0.730, .d = 0.230 }, // ⊁
    .{ .cp = 0x2282, .a = 0.543, .d = 0.043 }, // ⊂
    .{ .cp = 0x2283, .a = 0.543, .d = 0.043 }, // ⊃
    .{ .cp = 0x2284, .a = 0.730, .d = 0.230 }, // ⊄
    .{ .cp = 0x2285, .a = 0.730, .d = 0.230 }, // ⊅
    .{ .cp = 0x2286, .a = 0.627, .d = 0.127 }, // ⊆
    .{ .cp = 0x2287, .a = 0.627, .d = 0.127 }, // ⊇
    .{ .cp = 0x2288, .a = 0.730, .d = 0.230 }, // ⊈
    .{ .cp = 0x2289, .a = 0.730, .d = 0.230 }, // ⊉
    .{ .cp = 0x228E, .a = 0.604, .d = 0.020 }, // ⊎
    .{ .cp = 0x2291, .a = 0.627, .d = 0.127 }, // ⊑
    .{ .cp = 0x2292, .a = 0.627, .d = 0.127 }, // ⊒
    .{ .cp = 0x2293, .a = 0.604, .d = 0.020 }, // ⊓
    .{ .cp = 0x2294, .a = 0.604, .d = 0.020 }, // ⊔
    .{ .cp = 0x2295, .a = 0.592, .d = 0.092 }, // ⊕
    .{ .cp = 0x2296, .a = 0.592, .d = 0.092 }, // ⊖
    .{ .cp = 0x2297, .a = 0.592, .d = 0.092 }, // ⊗
    .{ .cp = 0x2298, .a = 0.592, .d = 0.092 }, // ⊘
    .{ .cp = 0x2299, .a = 0.592, .d = 0.092 }, // ⊙
    .{ .cp = 0x22A2, .a = 0.684, .d = 0.000 }, // ⊢
    .{ .cp = 0x22A3, .a = 0.684, .d = 0.000 }, // ⊣
    .{ .cp = 0x22A4, .a = 0.664, .d = 0.020 }, // ⊤
    .{ .cp = 0x22A5, .a = 0.684, .d = 0.000 }, // ⊥
    .{ .cp = 0x22A8, .a = 0.684, .d = 0.000 }, // ⊨
    .{ .cp = 0x22AC, .a = 0.684, .d = 0.000 }, // ⊬
    .{ .cp = 0x22C0, .a = 0.750, .d = 0.250 }, // ⋀
    .{ .cp = 0x22C1, .a = 0.764, .d = 0.280 }, // ⋁
    .{ .cp = 0x22C2, .a = 0.772, .d = 0.250 }, // ⋂
    .{ .cp = 0x22C3, .a = 0.750, .d = 0.272 }, // ⋃
    .{ .cp = 0x22C4, .a = 0.480, .d = 0.000 }, // ⋄
    .{ .cp = 0x22C5, .a = 0.303, .d = 0.000 }, // ⋅
    .{ .cp = 0x22C6, .a = 0.486, .d = 0.000 }, // ⋆
    .{ .cp = 0x22C8, .a = 0.505, .d = 0.005 }, // ⋈
    .{ .cp = 0x22D8, .a = 0.547, .d = 0.047 }, // ⋘
    .{ .cp = 0x22D9, .a = 0.547, .d = 0.047 }, // ⋙
    .{ .cp = 0x22E0, .a = 0.730, .d = 0.230 }, // ⋠
    .{ .cp = 0x22E1, .a = 0.730, .d = 0.230 }, // ⋡
    .{ .cp = 0x22EF, .a = 0.445, .d = 0.000 }, // ⋯
    .{ .cp = 0x2308, .a = 0.750, .d = 0.250 }, // ⌈
    .{ .cp = 0x2309, .a = 0.750, .d = 0.250 }, // ⌉
    .{ .cp = 0x230A, .a = 0.750, .d = 0.250 }, // ⌊
    .{ .cp = 0x230B, .a = 0.750, .d = 0.250 }, // ⌋
    .{ .cp = 0x2322, .a = 0.381, .d = 0.000 }, // ⌢
    .{ .cp = 0x2323, .a = 0.371, .d = 0.000 }, // ⌣
    .{ .cp = 0x25A0, .a = 0.583, .d = 0.083 }, // ■
    .{ .cp = 0x25A1, .a = 0.583, .d = 0.083 }, // □
    .{ .cp = 0x25B3, .a = 0.741, .d = 0.005 }, // △
    .{ .cp = 0x25B9, .a = 0.750, .d = 0.250 }, // ▹
    .{ .cp = 0x25BD, .a = 0.505, .d = 0.241 }, // ▽
    .{ .cp = 0x25C3, .a = 0.750, .d = 0.250 }, // ◃
    .{ .cp = 0x25CA, .a = 0.610, .d = 0.110 }, // ◊
    .{ .cp = 0x25CB, .a = 0.592, .d = 0.092 }, // ○
    .{ .cp = 0x2660, .a = 0.727, .d = 0.130 }, // ♠
    .{ .cp = 0x2661, .a = 0.716, .d = 0.033 }, // ♡
    .{ .cp = 0x2662, .a = 0.727, .d = 0.163 }, // ♢
    .{ .cp = 0x2663, .a = 0.727, .d = 0.130 }, // ♣
    .{ .cp = 0x266D, .a = 0.750, .d = 0.022 }, // ♭
    .{ .cp = 0x266E, .a = 0.728, .d = 0.217 }, // ♮
    .{ .cp = 0x266F, .a = 0.716, .d = 0.216 }, // ♯
    .{ .cp = 0x2713, .a = 0.699, .d = 0.027 }, // ✓
    .{ .cp = 0x27E8, .a = 0.750, .d = 0.250 }, // ⟨
    .{ .cp = 0x27E9, .a = 0.750, .d = 0.250 }, // ⟩
    .{ .cp = 0x27F5, .a = 0.510, .d = 0.010 }, // ⟵
    .{ .cp = 0x27F6, .a = 0.510, .d = 0.010 }, // ⟶
    .{ .cp = 0x27F7, .a = 0.510, .d = 0.010 }, // ⟷
    .{ .cp = 0x27F8, .a = 0.520, .d = 0.020 }, // ⟸
    .{ .cp = 0x27F9, .a = 0.520, .d = 0.020 }, // ⟹
    .{ .cp = 0x27FA, .a = 0.520, .d = 0.020 }, // ⟺
    .{ .cp = 0x2912, .a = 0.750, .d = 0.250 }, // ⤒
    .{ .cp = 0x29EB, .a = 0.750, .d = 0.250 }, // ⧫
    .{ .cp = 0x2A00, .a = 0.743, .d = 0.243 }, // ⨀
    .{ .cp = 0x2A01, .a = 0.743, .d = 0.243 }, // ⨁
    .{ .cp = 0x2A02, .a = 0.743, .d = 0.243 }, // ⨂
    .{ .cp = 0x2A04, .a = 0.750, .d = 0.272 }, // ⨄
    .{ .cp = 0x2A05, .a = 0.764, .d = 0.264 }, // ⨅
    .{ .cp = 0x2A06, .a = 0.764, .d = 0.264 }, // ⨆
    .{ .cp = 0x2A2F, .a = 0.496, .d = 0.000 }, // ⨯
    .{ .cp = 0x2A3F, .a = 0.683, .d = 0.000 }, // ⨿
    .{ .cp = 0x2A7D, .a = 0.634, .d = 0.134 }, // ⩽
    .{ .cp = 0x2A7E, .a = 0.634, .d = 0.134 }, // ⩾
    .{ .cp = 0x2AAF, .a = 0.631, .d = 0.119 }, // ⪯
    .{ .cp = 0x2AB0, .a = 0.631, .d = 0.119 }, // ⪰
    .{ .cp = 0x1D434, .a = 0.716, .d = 0.000 }, // 𝐴
    .{ .cp = 0x1D435, .a = 0.683, .d = 0.000 }, // 𝐵
    .{ .cp = 0x1D436, .a = 0.705, .d = 0.022 }, // 𝐶
    .{ .cp = 0x1D437, .a = 0.683, .d = 0.000 }, // 𝐷
    .{ .cp = 0x1D438, .a = 0.680, .d = 0.000 }, // 𝐸
    .{ .cp = 0x1D439, .a = 0.680, .d = 0.000 }, // 𝐹
    .{ .cp = 0x1D43A, .a = 0.705, .d = 0.022 }, // 𝐺
    .{ .cp = 0x1D43B, .a = 0.683, .d = 0.000 }, // 𝐻
    .{ .cp = 0x1D43C, .a = 0.683, .d = 0.000 }, // 𝐼
    .{ .cp = 0x1D43D, .a = 0.683, .d = 0.022 }, // 𝐽
    .{ .cp = 0x1D43E, .a = 0.683, .d = 0.000 }, // 𝐾
    .{ .cp = 0x1D43F, .a = 0.683, .d = 0.000 }, // 𝐿
    .{ .cp = 0x1D440, .a = 0.683, .d = 0.000 }, // 𝑀
    .{ .cp = 0x1D441, .a = 0.683, .d = 0.000 }, // 𝑁
    .{ .cp = 0x1D442, .a = 0.705, .d = 0.022 }, // 𝑂
    .{ .cp = 0x1D443, .a = 0.683, .d = 0.000 }, // 𝑃
    .{ .cp = 0x1D444, .a = 0.705, .d = 0.194 }, // 𝑄
    .{ .cp = 0x1D445, .a = 0.683, .d = 0.022 }, // 𝑅
    .{ .cp = 0x1D446, .a = 0.705, .d = 0.022 }, // 𝑆
    .{ .cp = 0x1D447, .a = 0.677, .d = 0.000 }, // 𝑇
    .{ .cp = 0x1D448, .a = 0.683, .d = 0.022 }, // 𝑈
    .{ .cp = 0x1D449, .a = 0.683, .d = 0.022 }, // 𝑉
    .{ .cp = 0x1D44A, .a = 0.683, .d = 0.022 }, // 𝑊
    .{ .cp = 0x1D44B, .a = 0.683, .d = 0.000 }, // 𝑋
    .{ .cp = 0x1D44C, .a = 0.683, .d = 0.000 }, // 𝑌
    .{ .cp = 0x1D44D, .a = 0.683, .d = 0.000 }, // 𝑍
    .{ .cp = 0x1D44E, .a = 0.442, .d = 0.011 }, // 𝑎
    .{ .cp = 0x1D44F, .a = 0.694, .d = 0.011 }, // 𝑏
    .{ .cp = 0x1D450, .a = 0.442, .d = 0.011 }, // 𝑐
    .{ .cp = 0x1D451, .a = 0.694, .d = 0.011 }, // 𝑑
    .{ .cp = 0x1D452, .a = 0.442, .d = 0.011 }, // 𝑒
    .{ .cp = 0x1D453, .a = 0.705, .d = 0.205 }, // 𝑓
    .{ .cp = 0x1D454, .a = 0.442, .d = 0.205 }, // 𝑔
    .{ .cp = 0x1D456, .a = 0.661, .d = 0.011 }, // 𝑖
    .{ .cp = 0x1D457, .a = 0.661, .d = 0.205 }, // 𝑗
    .{ .cp = 0x1D458, .a = 0.694, .d = 0.011 }, // 𝑘
    .{ .cp = 0x1D459, .a = 0.694, .d = 0.011 }, // 𝑙
    .{ .cp = 0x1D45A, .a = 0.442, .d = 0.011 }, // 𝑚
    .{ .cp = 0x1D45B, .a = 0.442, .d = 0.011 }, // 𝑛
    .{ .cp = 0x1D45C, .a = 0.442, .d = 0.011 }, // 𝑜
    .{ .cp = 0x1D45D, .a = 0.442, .d = 0.194 }, // 𝑝
    .{ .cp = 0x1D45E, .a = 0.442, .d = 0.194 }, // 𝑞
    .{ .cp = 0x1D45F, .a = 0.442, .d = 0.011 }, // 𝑟
    .{ .cp = 0x1D460, .a = 0.442, .d = 0.011 }, // 𝑠
    .{ .cp = 0x1D461, .a = 0.626, .d = 0.011 }, // 𝑡
    .{ .cp = 0x1D462, .a = 0.442, .d = 0.011 }, // 𝑢
    .{ .cp = 0x1D463, .a = 0.442, .d = 0.011 }, // 𝑣
    .{ .cp = 0x1D464, .a = 0.442, .d = 0.011 }, // 𝑤
    .{ .cp = 0x1D465, .a = 0.442, .d = 0.011 }, // 𝑥
    .{ .cp = 0x1D466, .a = 0.442, .d = 0.205 }, // 𝑦
    .{ .cp = 0x1D467, .a = 0.442, .d = 0.011 }, // 𝑧
    // Math-italic Greek (U+1D6FC..U+1D714 α–ω run + variant slots
    // U+1D716/1D717/1D719/1D71A/1D71B), the mapped forms of the parser's
    // \alpha..\omega and \varepsilon \vartheta \varphi \varpi \varrho —
    // measured with fontTools BoundsPen on latinmodern-math.otf (nearly
    // identical extents to the upright Greek rows; LM Math draws the italic
    // forms with slightly slanted, distinct outlines).
    .{ .cp = 0x1D6FC, .a = 0.442, .d = 0.011 }, // 𝛼
    .{ .cp = 0x1D6FD, .a = 0.706, .d = 0.194 }, // 𝛽
    .{ .cp = 0x1D6FE, .a = 0.442, .d = 0.215 }, // 𝛾
    .{ .cp = 0x1D6FF, .a = 0.712, .d = 0.011 }, // 𝛿
    .{ .cp = 0x1D700, .a = 0.453, .d = 0.022 }, // 𝜀
    .{ .cp = 0x1D701, .a = 0.697, .d = 0.205 }, // 𝜁
    .{ .cp = 0x1D702, .a = 0.442, .d = 0.216 }, // 𝜂
    .{ .cp = 0x1D703, .a = 0.705, .d = 0.011 }, // 𝜃
    .{ .cp = 0x1D704, .a = 0.442, .d = 0.011 }, // 𝜄
    .{ .cp = 0x1D705, .a = 0.442, .d = 0.011 }, // 𝜅
    .{ .cp = 0x1D706, .a = 0.694, .d = 0.013 }, // 𝜆
    .{ .cp = 0x1D707, .a = 0.442, .d = 0.216 }, // 𝜇
    .{ .cp = 0x1D708, .a = 0.442, .d = 0.000 }, // 𝜈
    .{ .cp = 0x1D709, .a = 0.697, .d = 0.205 }, // 𝜉
    .{ .cp = 0x1D70A, .a = 0.442, .d = 0.011 }, // 𝜊
    .{ .cp = 0x1D70B, .a = 0.431, .d = 0.011 }, // 𝜋
    .{ .cp = 0x1D70C, .a = 0.442, .d = 0.216 }, // 𝜌
    .{ .cp = 0x1D70D, .a = 0.442, .d = 0.108 }, // 𝜍
    .{ .cp = 0x1D70E, .a = 0.431, .d = 0.011 }, // 𝜎
    .{ .cp = 0x1D70F, .a = 0.431, .d = 0.012 }, // 𝜏
    .{ .cp = 0x1D710, .a = 0.442, .d = 0.011 }, // 𝜐
    .{ .cp = 0x1D711, .a = 0.442, .d = 0.218 }, // 𝜑
    .{ .cp = 0x1D712, .a = 0.442, .d = 0.205 }, // 𝜒
    .{ .cp = 0x1D713, .a = 0.694, .d = 0.205 }, // 𝜓
    .{ .cp = 0x1D714, .a = 0.442, .d = 0.011 }, // 𝜔
    // Math-italic ∂ U+1D715 — the SAME ink extents as the upright U+2202
    // (0.716 asc / 0.022 desc, measured with fontTools: LM Math draws the
    // two forms with identical vertical extents).
    .{ .cp = 0x1D715, .a = 0.716, .d = 0.022 }, // 𝜕
    .{ .cp = 0x1D716, .a = 0.431, .d = 0.011 }, // 𝜖
    .{ .cp = 0x1D717, .a = 0.705, .d = 0.011 }, // 𝜗
    .{ .cp = 0x1D719, .a = 0.694, .d = 0.205 }, // 𝜙
    .{ .cp = 0x1D71A, .a = 0.442, .d = 0.194 }, // 𝜚
    .{ .cp = 0x1D71B, .a = 0.431, .d = 0.011 }, // 𝜛
};

/// Binary search over `tbl` for `cp`.
fn search(tbl: []const Entry, cp: u21) ?Entry {
    var lo: usize = 0;
    var hi: usize = tbl.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (tbl[mid].cp < cp) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo < tbl.len and tbl[lo].cp == cp) return tbl[lo];
    return null;
}

/// True for Latin letters A-Z / a-z — the only codepoints where roman style
/// (`\text`, `\mathrm`) selects different metrics (cmr10 family) than math
/// italic (cmmi10 family). Digits, operators, punctuation and uppercase
/// Greek are already cmr10 in `table`, so style does not change them.
fn isRomanLetter(cp: u21) bool {
    return (cp >= 0x41 and cp <= 0x5A) or (cp >= 0x61 and cp <= 0x7A);
}

/// Metric table for `cp` in `style` at design size `size_pt` (optical band
/// selection). Roman-style Latin letters use the cmr10/cmr7/cmr5 tables;
/// every other codepoint uses the math tables (`table`/`table7`/`table5`).
/// Values are in the same 10pt-base convention (em × 10), so callers keep
/// using `s(v, size_pt)`.
fn tableFor(cp: u21, style: atom.CharStyle, size_pt: f32) []const Entry {
    const band7 = size_pt > 6.4 and size_pt < 7.6;
    const band5 = size_pt > 4.5 and size_pt < 5.5;
    if (isRomanLetter(cp) and style == .roman) {
        return if (band7) &table_roman7 else if (band5) &table_roman5 else &table_roman;
    }
    return if (band7) &table7 else if (band5) &table5 else &table;
}

/// Size-aware glyph lookup: at script (7pt) / scriptscript (5pt) design sizes
/// returns the real optical-scale metrics (cmr7/cmmi7/cmsy7, cmr5/...); at
/// any other size the 10pt `table` (linearly scaled by the layout). Roman
/// style (`\text`/`\mathrm`) letters resolve against the cmr10 family
/// instead of the cmmi10 math-italic rows. Values are in the 10pt-base
/// convention (em × 10), matching `glyph`/`lookupAscii`, so callers keep
/// using `s(v, size_pt)`. Glyphs without a script-size font (ams fonts,
/// cmex, composites) fall back to the 10pt table, i.e. linear scaling — the
/// same behavior as before. When `fm.font` is set, the real font answers
/// first (see `fontGlyph`); the optical bands are irrelevant there — LM is
/// a single 10pt design, so the advance scales linearly with size.
pub fn glyphAt(fm: *const FontMetrics, cp: u21, style: atom.CharStyle, size_pt: f32) ?Glyph {
    if (fontGlyph(fm, cp, style)) |g| return g;
    if (search(tableFor(cp, style, size_pt), cp)) |e| {
        return .{ .width = e.w, .height = e.h, .depth = e.d, .italic_correction = e.ic };
    }
    return null;
}

/// Ink extents of the DRAWN glyph for `cp`, in em of the glyph's font-size
/// (binary search over `ink_table`; the design bound 0.750/0.250 for
/// codepoints absent from the table — the LMMath ascender/descender, safe
/// for the browser's fallback fonts too). layoutChar/layoutText box a
/// normal glyph by `ink × size_pt` instead of the metric-table h/d: the
/// cmr10/cmmi10 h/d describe the Computer-Modern design box, while the
/// Latin-Modern-Math ink is what the SVG actually draws, and it pokes past
/// that box (digits 0.666em vs 0.644em, ∫ sup '1' 9.32pt of ink in a
/// 9.02pt box at 14pt) — the frame/viewBox then clips the ink. The box
/// width stays the metric-table advance; only height/depth change.
pub fn glyphInk(cp: u21) GlyphInk {
    var lo: usize = 0;
    var hi: usize = ink_table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (ink_table[mid].cp < cp) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo < ink_table.len and ink_table[lo].cp == cp) {
        return .{ .asc = ink_table[lo].a, .desc = ink_table[lo].d };
    }
    return .{ .asc = 0.750, .desc = 0.250 };
}

/// One MATH-table vertical size variant of a delimiter (and the base entry):
/// the hmtx ADVANCE and the ink extents, in em of the glyph's font-size.
/// Measured with fontTools on latinmodern-math.otf 2.005 (MathVariants
/// VertGlyphConstruction records + BoundsPen + hmtx). Every LM Math variant
/// keeps its ink CENTER at 0.25em above the baseline (asc − desc = 0.5em),
/// so a variant box placed with shift (asc−desc)/2 − axis sits centered on
/// the math axis exactly like the XeTeX reference.
pub const DelimVariant = struct {
    /// Horizontal advance in em of the glyph's font size — the box width this
    /// variant takes when the delimiter is drawn at the base size.
    adv: f32,
    /// Ink above the baseline in em of the glyph's font size.
    asc: f32,
    /// Ink below the baseline in em of the glyph's font size; non-negative.
    desc: f32,
};

/// Per-delimiter variant ladder: entry [0] is the BASE glyph (the
/// non-stretched size), [1..7] the MATH size variants parenleft.v1..v7 etc.
/// The \left..\right layout picks the SMALLEST entry whose ink height
/// (asc + desc) covers the content and boxes the delimiter by that entry's
/// advance/ink at the BASE font size — the same variant ladder XeTeX draws
/// (XeTeX renders the parens of `\left( \frac{\partial L}{\partial \dot{q}}
/// \right)` at the base size from the variant glyphs; the ref measured the
/// paren ink span 2.392em = parenleft.v6's ink).
const delim_ladder = [_]struct { cp: u21, variants: [8]DelimVariant }{
    .{
        .cp = 0x0028,
        .variants = .{
            .{ .adv = 0.389, .asc = 0.748, .desc = 0.248 }, // ( base
            .{ .adv = 0.422, .asc = 0.797, .desc = 0.297 }, // .v1
            .{ .adv = 0.458, .asc = 0.847, .desc = 0.347 }, // .v2
            .{ .adv = 0.523, .asc = 0.972, .desc = 0.472 }, // .v3
            .{ .adv = 0.597, .asc = 1.146, .desc = 0.646 }, // .v4
            .{ .adv = 0.663, .asc = 1.296, .desc = 0.796 }, // .v5
            .{ .adv = 0.736, .asc = 1.446, .desc = 0.946 }, // .v6
            .{ .adv = 0.875, .asc = 1.745, .desc = 1.245 }, // .v7
        },
    },
    .{
        .cp = 0x0029,
        .variants = .{
            .{ .adv = 0.389, .asc = 0.748, .desc = 0.248 }, // ) base
            .{ .adv = 0.422, .asc = 0.797, .desc = 0.297 }, // .v1
            .{ .adv = 0.458, .asc = 0.847, .desc = 0.347 }, // .v2
            .{ .adv = 0.523, .asc = 0.972, .desc = 0.472 }, // .v3
            .{ .adv = 0.597, .asc = 1.146, .desc = 0.646 }, // .v4
            .{ .adv = 0.663, .asc = 1.296, .desc = 0.796 }, // .v5
            .{ .adv = 0.736, .asc = 1.446, .desc = 0.946 }, // .v6
            .{ .adv = 0.875, .asc = 1.745, .desc = 1.245 }, // .v7
        },
    },
    .{
        .cp = 0x005B,
        .variants = .{
            .{ .adv = 0.278, .asc = 0.750, .desc = 0.250 }, // [ base
            .{ .adv = 0.340, .asc = 0.800, .desc = 0.300 }, // .v1
            .{ .adv = 0.417, .asc = 0.850, .desc = 0.350 }, // .v2
            .{ .adv = 0.444, .asc = 0.975, .desc = 0.475 }, // .v3
            .{ .adv = 0.472, .asc = 1.150, .desc = 0.650 }, // .v4
            .{ .adv = 0.499, .asc = 1.300, .desc = 0.800 }, // .v5
            .{ .adv = 0.528, .asc = 1.450, .desc = 0.950 }, // .v6
            .{ .adv = 0.667, .asc = 1.750, .desc = 1.250 }, // .v7
        },
    },
    .{
        .cp = 0x005D,
        .variants = .{
            .{ .adv = 0.278, .asc = 0.750, .desc = 0.250 }, // ] base
            .{ .adv = 0.340, .asc = 0.800, .desc = 0.300 }, // .v1
            .{ .adv = 0.417, .asc = 0.850, .desc = 0.350 }, // .v2
            .{ .adv = 0.444, .asc = 0.975, .desc = 0.475 }, // .v3
            .{ .adv = 0.472, .asc = 1.150, .desc = 0.650 }, // .v4
            .{ .adv = 0.499, .asc = 1.300, .desc = 0.800 }, // .v5
            .{ .adv = 0.528, .asc = 1.450, .desc = 0.950 }, // .v6
            .{ .adv = 0.667, .asc = 1.750, .desc = 1.250 }, // .v7
        },
    },
    .{
        .cp = 0x007B,
        .variants = .{
            .{ .adv = 0.500, .asc = 0.750, .desc = 0.250 }, // { base
            .{ .adv = 0.540, .asc = 0.800, .desc = 0.300 }, // .v1
            .{ .adv = 0.583, .asc = 0.850, .desc = 0.350 }, // .v2
            .{ .adv = 0.624, .asc = 0.975, .desc = 0.475 }, // .v3
            .{ .adv = 0.667, .asc = 1.150, .desc = 0.650 }, // .v4
            .{ .adv = 0.707, .asc = 1.300, .desc = 0.800 }, // .v5
            .{ .adv = 0.750, .asc = 1.450, .desc = 0.950 }, // .v6
            .{ .adv = 0.902, .asc = 1.750, .desc = 1.250 }, // .v7
        },
    },
    .{
        .cp = 0x007D,
        .variants = .{
            .{ .adv = 0.500, .asc = 0.750, .desc = 0.250 }, // } base
            .{ .adv = 0.540, .asc = 0.800, .desc = 0.300 }, // .v1
            .{ .adv = 0.583, .asc = 0.850, .desc = 0.350 }, // .v2
            .{ .adv = 0.624, .asc = 0.975, .desc = 0.475 }, // .v3
            .{ .adv = 0.667, .asc = 1.150, .desc = 0.650 }, // .v4
            .{ .adv = 0.707, .asc = 1.300, .desc = 0.800 }, // .v5
            .{ .adv = 0.750, .asc = 1.450, .desc = 0.950 }, // .v6
            .{ .adv = 0.902, .asc = 1.750, .desc = 1.250 }, // .v7
        },
    },
    .{
        .cp = 0x27E8,
        .variants = .{
            .{ .adv = 0.389, .asc = 0.750, .desc = 0.250 }, // ⟨ base
            .{ .adv = 0.428, .asc = 0.800, .desc = 0.300 }, // .v1
            .{ .adv = 0.472, .asc = 0.850, .desc = 0.350 }, // .v2
            .{ .adv = 0.537, .asc = 0.975, .desc = 0.475 }, // .v3
            .{ .adv = 0.611, .asc = 1.150, .desc = 0.650 }, // .v4
            .{ .adv = 0.677, .asc = 1.300, .desc = 0.800 }, // .v5
            .{ .adv = 0.750, .asc = 1.450, .desc = 0.950 }, // .v6
            .{ .adv = 0.908, .asc = 1.750, .desc = 1.250 }, // .v7
        },
    },
    .{
        .cp = 0x27E9,
        .variants = .{
            .{ .adv = 0.389, .asc = 0.750, .desc = 0.250 }, // ⟩ base
            .{ .adv = 0.428, .asc = 0.800, .desc = 0.300 }, // .v1
            .{ .adv = 0.472, .asc = 0.850, .desc = 0.350 }, // .v2
            .{ .adv = 0.537, .asc = 0.975, .desc = 0.475 }, // .v3
            .{ .adv = 0.611, .asc = 1.150, .desc = 0.650 }, // .v4
            .{ .adv = 0.677, .asc = 1.300, .desc = 0.800 }, // .v5
            .{ .adv = 0.750, .asc = 1.450, .desc = 0.950 }, // .v6
            .{ .adv = 0.908, .asc = 1.750, .desc = 1.250 }, // .v7
        },
    },
    .{
        .cp = 0x2308,
        .variants = .{
            .{ .adv = 0.444, .asc = 0.750, .desc = 0.250 }, // ⌈ base
            .{ .adv = 0.458, .asc = 0.800, .desc = 0.300 }, // .v1
            .{ .adv = 0.472, .asc = 0.850, .desc = 0.350 }, // .v2
            .{ .adv = 0.499, .asc = 0.975, .desc = 0.475 }, // .v3
            .{ .adv = 0.528, .asc = 1.150, .desc = 0.650 }, // .v4
            .{ .adv = 0.555, .asc = 1.300, .desc = 0.800 }, // .v5
            .{ .adv = 0.583, .asc = 1.450, .desc = 0.950 }, // .v6
            .{ .adv = 0.623, .asc = 1.750, .desc = 1.250 }, // .v7
        },
    },
    .{
        .cp = 0x2309,
        .variants = .{
            .{ .adv = 0.444, .asc = 0.750, .desc = 0.250 }, // ⌉ base
            .{ .adv = 0.458, .asc = 0.800, .desc = 0.300 }, // .v1
            .{ .adv = 0.472, .asc = 0.850, .desc = 0.350 }, // .v2
            .{ .adv = 0.499, .asc = 0.975, .desc = 0.475 }, // .v3
            .{ .adv = 0.528, .asc = 1.150, .desc = 0.650 }, // .v4
            .{ .adv = 0.555, .asc = 1.300, .desc = 0.800 }, // .v5
            .{ .adv = 0.583, .asc = 1.450, .desc = 0.950 }, // .v6
            .{ .adv = 0.623, .asc = 1.750, .desc = 1.250 }, // .v7
        },
    },
    .{
        .cp = 0x230A,
        .variants = .{
            .{ .adv = 0.444, .asc = 0.750, .desc = 0.250 }, // ⌊ base
            .{ .adv = 0.458, .asc = 0.800, .desc = 0.300 }, // .v1
            .{ .adv = 0.472, .asc = 0.850, .desc = 0.350 }, // .v2
            .{ .adv = 0.499, .asc = 0.975, .desc = 0.475 }, // .v3
            .{ .adv = 0.528, .asc = 1.150, .desc = 0.650 }, // .v4
            .{ .adv = 0.555, .asc = 1.300, .desc = 0.800 }, // .v5
            .{ .adv = 0.583, .asc = 1.450, .desc = 0.950 }, // .v6
            .{ .adv = 0.623, .asc = 1.750, .desc = 1.250 }, // .v7
        },
    },
    .{
        .cp = 0x230B,
        .variants = .{
            .{ .adv = 0.444, .asc = 0.750, .desc = 0.250 }, // ⌋ base
            .{ .adv = 0.458, .asc = 0.800, .desc = 0.300 }, // .v1
            .{ .adv = 0.472, .asc = 0.850, .desc = 0.350 }, // .v2
            .{ .adv = 0.499, .asc = 0.975, .desc = 0.475 }, // .v3
            .{ .adv = 0.528, .asc = 1.150, .desc = 0.650 }, // .v4
            .{ .adv = 0.555, .asc = 1.300, .desc = 0.800 }, // .v5
            .{ .adv = 0.583, .asc = 1.450, .desc = 0.950 }, // .v6
            .{ .adv = 0.623, .asc = 1.750, .desc = 1.250 }, // .v7
        },
    },
    .{
        .cp = 0x2223, // ∣ \mid / \middle| — the divides construction
        .variants = .{
            .{ .adv = 0.278, .asc = 0.750, .desc = 0.250 }, // ∣ base
            .{ .adv = 0.278, .asc = 0.851, .desc = 0.351 }, // .v1
            .{ .adv = 0.278, .asc = 0.972, .desc = 0.472 }, // .v2
            .{ .adv = 0.278, .asc = 1.117, .desc = 0.617 }, // .v3
            .{ .adv = 0.278, .asc = 1.292, .desc = 0.792 }, // .v4
            .{ .adv = 0.278, .asc = 1.501, .desc = 1.001 }, // .v5
            .{ .adv = 0.278, .asc = 1.752, .desc = 1.252 }, // .v6
            .{ .adv = 0.278, .asc = 2.053, .desc = 1.553 }, // .v7
        },
    },
    .{
        .cp = 0x007C, // | — \left|, \vert: the bar glyph + divides variants
        .variants = .{
            .{ .adv = 0.278, .asc = 0.750, .desc = 0.250 }, // | base
            .{ .adv = 0.278, .asc = 0.851, .desc = 0.351 }, // .v1
            .{ .adv = 0.278, .asc = 0.972, .desc = 0.472 }, // .v2
            .{ .adv = 0.278, .asc = 1.117, .desc = 0.617 }, // .v3
            .{ .adv = 0.278, .asc = 1.292, .desc = 0.792 }, // .v4
            .{ .adv = 0.278, .asc = 1.501, .desc = 1.001 }, // .v5
            .{ .adv = 0.278, .asc = 1.752, .desc = 1.252 }, // .v6
            .{ .adv = 0.278, .asc = 2.053, .desc = 1.553 }, // .v7
        },
    },
    .{
        .cp = 0x2016, // ‖ — \Vert, \|: the double-vertical-bar construction
        .variants = .{
            .{ .adv = 0.398, .asc = 0.750, .desc = 0.250 }, // ‖ base
            .{ .adv = 0.354, .asc = 0.851, .desc = 0.351 }, // .v1
            .{ .adv = 0.364, .asc = 0.972, .desc = 0.472 }, // .v2
            .{ .adv = 0.372, .asc = 1.117, .desc = 0.617 }, // .v3
            .{ .adv = 0.386, .asc = 1.292, .desc = 0.792 }, // .v4
            .{ .adv = 0.396, .asc = 1.501, .desc = 1.001 }, // .v5
            .{ .adv = 0.410, .asc = 1.752, .desc = 1.252 }, // .v6
            .{ .adv = 0.424, .asc = 2.053, .desc = 1.553 }, // .v7
        },
    },
    .{
        .cp = 0x002F, // / — \left/ (the slash construction)
        .variants = .{
            .{ .adv = 0.500, .asc = 0.750, .desc = 0.250 }, // / base
            .{ .adv = 0.617, .asc = 0.905, .desc = 0.405 }, // .v1
            .{ .adv = 0.768, .asc = 1.108, .desc = 0.608 }, // .v2
            .{ .adv = 0.964, .asc = 1.374, .desc = 0.874 }, // .v3
            .{ .adv = 1.222, .asc = 1.722, .desc = 1.222 }, // .v4
            .{ .adv = 1.557, .asc = 2.179, .desc = 1.679 }, // .v5
            .{ .adv = 1.997, .asc = 2.777, .desc = 2.277 }, // .v6
            .{ .adv = 2.572, .asc = 3.560, .desc = 3.060 }, // .v7
        },
    },
};

/// The MATH size-variant ladder of a delimiter codepoint (( ) [ ] { } ⟨ ⟩
/// ⌈ ⌉ ⌊ ⌋ ∣ | ‖ /), or null when the codepoint is not a table delimiter —
/// the caller then falls back to the continuous scaled-base path (e.g.
/// \left\backslash). The | / ‖ entries let \left| and \middle| pick the
/// REAL divides/parallel/slash variants (measured \middle| at 36pt =
/// divides.v3, ink 1.734em — the |'s smallest variant covering the fence's
/// required ink).
pub fn delimVariants(cp: u21) ?[]const DelimVariant {
    for (delim_ladder, 0..) |entry, i| {
        if (entry.cp == cp) return &delim_ladder[i].variants;
    }
    return null;
}

/// Horizontal position of a glyph's TOP-ACCENT ATTACHMENT point, in em
/// right of the glyph origin — the MATH-table MathTopAccentAttachment
/// (fontTools on latinmodern-math.otf 2.005). XeTeX+unicode-math places an
/// accent so the ACCENT's attachment point (for the combining marks, their
/// ink center at −0.264em) sits on the BASE's attachment point: measured
/// `\dot{q}` ref, dot ink at q_origin + 0.349em = u1D45E's attachment
/// (0.349), NOT the base ink center (0.246) and NOT box center + italic
/// correction (plain TeX's rule — XeTeX uses the MATH table with
/// unicode-math). Rows cover every letter/Greek/symbol form the parser can
/// produce as an accent base (both the base and the math-italic mapped
/// codepoints). Null = no row (composite base, digit absent from the rows
/// below): the layout falls back to centering the accent on the base box.
const accent_attach = [_]struct { cp: u21, a: f32 }{
    .{ .cp = 0x0030, .a = 0.254 }, // 0
    .{ .cp = 0x0031, .a = 0.257 }, // 1
    .{ .cp = 0x0041, .a = 0.375 }, // A
    .{ .cp = 0x0042, .a = 0.256 }, // B
    .{ .cp = 0x0043, .a = 0.507 }, // C
    .{ .cp = 0x0044, .a = 0.243 }, // D
    .{ .cp = 0x0045, .a = 0.315 }, // E
    .{ .cp = 0x0046, .a = 0.308 }, // F
    .{ .cp = 0x0047, .a = 0.507 }, // G
    .{ .cp = 0x0048, .a = 0.375 }, // H
    .{ .cp = 0x0049, .a = 0.181 }, // I
    .{ .cp = 0x004A, .a = 0.317 }, // J
    .{ .cp = 0x004B, .a = 0.378 }, // K
    .{ .cp = 0x004C, .a = 0.193 }, // L
    .{ .cp = 0x004D, .a = 0.458 }, // M
    .{ .cp = 0x004E, .a = 0.375 }, // N
    .{ .cp = 0x004F, .a = 0.388 }, // O
    .{ .cp = 0x0050, .a = 0.250 }, // P
    .{ .cp = 0x0051, .a = 0.388 }, // Q
    .{ .cp = 0x0052, .a = 0.234 }, // R
    .{ .cp = 0x0053, .a = 0.330 }, // S
    .{ .cp = 0x0054, .a = 0.361 }, // T
    .{ .cp = 0x0055, .a = 0.375 }, // U
    .{ .cp = 0x0056, .a = 0.375 }, // V
    .{ .cp = 0x0057, .a = 0.514 }, // W
    .{ .cp = 0x0058, .a = 0.361 }, // X
    .{ .cp = 0x0059, .a = 0.375 }, // Y
    .{ .cp = 0x005A, .a = 0.317 }, // Z
    .{ .cp = 0x0061, .a = 0.214 }, // a
    .{ .cp = 0x0062, .a = 0.100 }, // b
    .{ .cp = 0x0063, .a = 0.249 }, // c
    .{ .cp = 0x0064, .a = 0.377 }, // d
    .{ .cp = 0x0065, .a = 0.236 }, // e
    .{ .cp = 0x0066, .a = 0.262 }, // f
    .{ .cp = 0x0067, .a = 0.332 }, // g
    .{ .cp = 0x0068, .a = 0.104 }, // h
    .{ .cp = 0x0069, .a = 0.138 }, // i
    .{ .cp = 0x006A, .a = 0.156 }, // j
    .{ .cp = 0x006B, .a = 0.100 }, // k
    .{ .cp = 0x006C, .a = 0.105 }, // l
    .{ .cp = 0x006D, .a = 0.350 }, // m
    .{ .cp = 0x006E, .a = 0.211 }, // n
    .{ .cp = 0x006F, .a = 0.249 }, // o
    .{ .cp = 0x0070, .a = 0.202 }, // p
    .{ .cp = 0x0071, .a = 0.318 }, // q
    .{ .cp = 0x0072, .a = 0.181 }, // r
    .{ .cp = 0x0073, .a = 0.232 }, // s
    .{ .cp = 0x0074, .a = 0.161 }, // t
    .{ .cp = 0x0075, .a = 0.245 }, // u
    .{ .cp = 0x0076, .a = 0.264 }, // v
    .{ .cp = 0x0077, .a = 0.361 }, // w
    .{ .cp = 0x0078, .a = 0.258 }, // x
    .{ .cp = 0x0079, .a = 0.264 }, // y
    .{ .cp = 0x007A, .a = 0.226 }, // z
    .{ .cp = 0x0131, .a = 0.139 }, // ı
    .{ .cp = 0x0237, .a = 0.153 }, // ȷ
    .{ .cp = 0x03B1, .a = 0.356 }, // α
    .{ .cp = 0x03B2, .a = 0.280 }, // β
    .{ .cp = 0x03B3, .a = 0.293 }, // γ
    .{ .cp = 0x03B4, .a = 0.232 }, // δ
    .{ .cp = 0x03B5, .a = 0.244 }, // ε
    .{ .cp = 0x03B6, .a = 0.224 }, // ζ
    .{ .cp = 0x03B7, .a = 0.218 }, // η
    .{ .cp = 0x03B8, .a = 0.247 }, // θ
    .{ .cp = 0x03B9, .a = 0.098 }, // ι
    .{ .cp = 0x03BA, .a = 0.247 }, // κ
    .{ .cp = 0x03BB, .a = 0.086 }, // λ
    .{ .cp = 0x03BC, .a = 0.237 }, // μ
    .{ .cp = 0x03BD, .a = 0.209 }, // ν
    .{ .cp = 0x03BE, .a = 0.196 }, // ξ
    .{ .cp = 0x03BF, .a = 0.250 }, // ο
    .{ .cp = 0x03C1, .a = 0.243 }, // ρ
    .{ .cp = 0x03C2, .a = 0.237 }, // ς
    .{ .cp = 0x03C3, .a = 0.300 }, // σ
    .{ .cp = 0x03C4, .a = 0.232 }, // τ
    .{ .cp = 0x03C5, .a = 0.251 }, // υ
    .{ .cp = 0x03C6, .a = 0.302 }, // φ
    .{ .cp = 0x03C7, .a = 0.267 }, // χ
    .{ .cp = 0x03C8, .a = 0.348 }, // ψ
    .{ .cp = 0x03C9, .a = 0.322 }, // ω
    .{ .cp = 0x03D1, .a = 0.291 }, // ϑ
    .{ .cp = 0x03D5, .a = 0.320 }, // ϕ
    .{ .cp = 0x03D6, .a = 0.404 }, // ϖ
    .{ .cp = 0x03F1, .a = 0.249 }, // ϱ
    .{ .cp = 0x03F5, .a = 0.242 }, // ϵ
    .{ .cp = 0x210E, .a = 0.213 }, // ℎ
    .{ .cp = 0x2202, .a = 0.291 }, // ∂ (upright form)
    .{ .cp = 0x1D434, .a = 0.550 }, // 𝐴
    .{ .cp = 0x1D435, .a = 0.420 }, // 𝐵
    .{ .cp = 0x1D436, .a = 0.596 }, // 𝐶
    .{ .cp = 0x1D437, .a = 0.427 }, // 𝐷
    .{ .cp = 0x1D438, .a = 0.483 }, // 𝐸
    .{ .cp = 0x1D439, .a = 0.475 }, // 𝐹
    .{ .cp = 0x1D43A, .a = 0.596 }, // 𝐺
    .{ .cp = 0x1D43B, .a = 0.542 }, // 𝐻
    .{ .cp = 0x1D43C, .a = 0.347 }, // 𝐼
    .{ .cp = 0x1D43D, .a = 0.487 }, // 𝐽
    .{ .cp = 0x1D43E, .a = 0.545 }, // 𝐾
    .{ .cp = 0x1D43F, .a = 0.360 }, // 𝐿
    .{ .cp = 0x1D440, .a = 0.625 }, // 𝑀
    .{ .cp = 0x1D441, .a = 0.542 }, // 𝑁
    .{ .cp = 0x1D442, .a = 0.495 }, // 𝑂
    .{ .cp = 0x1D443, .a = 0.416 }, // 𝑃
    .{ .cp = 0x1D444, .a = 0.495 }, // 𝑄
    .{ .cp = 0x1D445, .a = 0.398 }, // 𝑅
    .{ .cp = 0x1D446, .a = 0.498 }, // 𝑆
    .{ .cp = 0x1D447, .a = 0.398 }, // 𝑇
    .{ .cp = 0x1D448, .a = 0.421 }, // 𝑈
    .{ .cp = 0x1D449, .a = 0.413 }, // 𝑉
    .{ .cp = 0x1D44A, .a = 0.552 }, // 𝑊
    .{ .cp = 0x1D44B, .a = 0.528 }, // 𝑋
    .{ .cp = 0x1D44C, .a = 0.399 }, // 𝑌
    .{ .cp = 0x1D44D, .a = 0.485 }, // 𝑍
    .{ .cp = 0x1D44E, .a = 0.287 }, // 𝑎
    .{ .cp = 0x1D44F, .a = 0.165 }, // 𝑏
    .{ .cp = 0x1D450, .a = 0.317 }, // 𝑐
    .{ .cp = 0x1D451, .a = 0.442 }, // 𝑑
    .{ .cp = 0x1D452, .a = 0.300 }, // 𝑒
    .{ .cp = 0x1D453, .a = 0.464 }, // 𝑓
    .{ .cp = 0x1D454, .a = 0.316 }, // 𝑔
    .{ .cp = 0x1D456, .a = 0.247 }, // 𝑖
    .{ .cp = 0x1D457, .a = 0.359 }, // 𝑗
    .{ .cp = 0x1D458, .a = 0.213 }, // 𝑘
    .{ .cp = 0x1D459, .a = 0.184 }, // 𝑙
    .{ .cp = 0x1D45A, .a = 0.404 }, // 𝑚
    .{ .cp = 0x1D45B, .a = 0.265 }, // 𝑛
    .{ .cp = 0x1D45C, .a = 0.315 }, // 𝑜
    .{ .cp = 0x1D45D, .a = 0.246 }, // 𝑝
    .{ .cp = 0x1D45E, .a = 0.349 }, // 𝑞
    .{ .cp = 0x1D45F, .a = 0.247 }, // 𝑟
    .{ .cp = 0x1D460, .a = 0.296 }, // 𝑠
    .{ .cp = 0x1D461, .a = 0.225 }, // 𝑡
    .{ .cp = 0x1D462, .a = 0.305 }, // 𝑢
    .{ .cp = 0x1D463, .a = 0.294 }, // 𝑣
    .{ .cp = 0x1D464, .a = 0.405 }, // 𝑤
    .{ .cp = 0x1D465, .a = 0.329 }, // 𝑥
    .{ .cp = 0x1D466, .a = 0.304 }, // 𝑦
    .{ .cp = 0x1D467, .a = 0.336 }, // 𝑧
    .{ .cp = 0x1D6FC, .a = 0.392 }, // 𝛼
    .{ .cp = 0x1D6FD, .a = 0.437 }, // 𝛽
    .{ .cp = 0x1D6FE, .a = 0.259 }, // 𝛾
    .{ .cp = 0x1D6FF, .a = 0.335 }, // 𝛿
    .{ .cp = 0x1D700, .a = 0.284 }, // 𝜀
    .{ .cp = 0x1D701, .a = 0.313 }, // 𝜁
    .{ .cp = 0x1D702, .a = 0.272 }, // 𝜂
    .{ .cp = 0x1D703, .a = 0.310 }, // 𝜃
    .{ .cp = 0x1D704, .a = 0.184 }, // 𝜄
    .{ .cp = 0x1D705, .a = 0.331 }, // 𝜅
    .{ .cp = 0x1D706, .a = 0.238 }, // 𝜆
    .{ .cp = 0x1D707, .a = 0.349 }, // 𝜇
    .{ .cp = 0x1D708, .a = 0.297 }, // 𝜈
    .{ .cp = 0x1D709, .a = 0.285 }, // 𝜉
    .{ .cp = 0x1D70A, .a = 0.243 }, // 𝜊
    .{ .cp = 0x1D70B, .a = 0.328 }, // 𝜋
    .{ .cp = 0x1D70C, .a = 0.354 }, // 𝜌
    .{ .cp = 0x1D70D, .a = 0.182 }, // 𝜍
    .{ .cp = 0x1D70E, .a = 0.286 }, // 𝜎
    .{ .cp = 0x1D70F, .a = 0.269 }, // 𝜏
    .{ .cp = 0x1D710, .a = 0.306 }, // 𝜐
    .{ .cp = 0x1D711, .a = 0.355 }, // 𝜑
    .{ .cp = 0x1D712, .a = 0.331 }, // 𝜒
    .{ .cp = 0x1D713, .a = 0.469 }, // 𝜓
    .{ .cp = 0x1D714, .a = 0.345 }, // 𝜔
    .{ .cp = 0x1D715, .a = 0.361 }, // 𝜕 (math-italic ∂)
    .{ .cp = 0x1D716, .a = 0.269 }, // 𝜖
    .{ .cp = 0x1D717, .a = 0.411 }, // 𝜗
    .{ .cp = 0x1D719, .a = 0.423 }, // 𝜙
    .{ .cp = 0x1D71A, .a = 0.361 }, // 𝜚
    .{ .cp = 0x1D71B, .a = 0.453 }, // 𝜛
};

/// The top-accent attachment of an accent base codepoint, in em (null when
/// the codepoint has no row — the layout then centers the accent on the box).
pub fn accentAttach(cp: u21) ?f32 {
    var lo: usize = 0;
    var hi: usize = accent_attach.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (accent_attach[mid].cp < cp) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo < accent_attach.len and accent_attach[lo].cp == cp) return accent_attach[lo].a;
    return null;
}

/// Em size at the base font size (10pt), used by `glyphEstimate`.
const em: f32 = 10.0;

/// Exact per-glyph metrics for `cp` in `style` at the 10pt base; null when
/// neither the real font (if `self.font` is set) nor the static table has
/// the codepoint. Font path first (see `fontGlyph`), then the bundled
/// tables — the fallback chain layout relies on: font → static table →
/// glyphEstimate.
fn glyph(self: *const FontMetrics, cp: u21, style: atom.CharStyle) ?Glyph {
    if (fontGlyph(self, cp, style)) |g| return g;
    return staticGlyph(cp, style);
}

/// Font-backed metrics for `cp` in `style` at the 10pt base, via the
/// `font_glyph` hook context.zig installs. The hook serves the face's
/// cached hmtx advance (FontContext.metrics × 10pt) for width and the
/// face's OWN nominal hhea extents for height/depth — real font data that
/// bounds every glyph the face covers — and returns null for codepoints the
/// face does not map, so `glyph`/`glyphAt` fall through to the static
/// tables and finally to glyphEstimate. Null also when `font` is unset or
/// the hook is missing (the bundled default metrics).
fn fontGlyph(self: *const FontMetrics, cp: u21, style: atom.CharStyle) ?Glyph {
    if (self.font == null) return null;
    const fg = self.font_glyph orelse return null;
    return fg(self, cp, style);
}

/// Static-table lookup at the 10pt base. Binary search over the table
/// selected by `style` (see `tableFor`): roman-style letters come from
/// `table_roman` (cmr10), everything else from `table` (cmmi10 letters,
/// cmsy10/cmr10 symbols). Public so the font hook in context.zig can reuse
/// the rows' italic corrections (LM Math's MATH table is not parsed yet).
pub fn staticGlyph(cp: u21, style: atom.CharStyle) ?Glyph {
    const tbl = tableFor(cp, style, 0);
    var lo: usize = 0;
    var hi: usize = tbl.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (tbl[mid].cp < cp) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo < tbl.len and tbl[lo].cp == cp) {
        const e = tbl[lo];
        return .{
            .width = e.w,
            .height = e.h,
            .depth = e.d,
            .italic_correction = e.ic,
        };
    }
    return null;
}

/// True when the ACTIVE metric source carries a glyph for `cp` in `style`:
/// a wired font's cmap when a font is wired (the `font_glyph` hook returns
/// null for codepoints the face does not map), else the bundled static
/// tables. Layout uses this to validate a mapped math-italic codepoint
/// (U+1D4xx/U+1D6xx) before emitting it: when the source lacks the mapped
/// form, the base codepoint is kept, so the SVG never names a glyph the
/// renderer cannot draw (the static tables cover the U+1D4xx Latin series
/// but not the U+1D6xx Greek series; a loaded font may lack either).
pub fn hasGlyph(fm: *const FontMetrics, cp: u21, style: atom.CharStyle) bool {
    if (fm.font != null) return fontGlyph(fm, cp, style) != null;
    return staticGlyph(cp, style) != null;
}

/// ASCII fast-path lookup table (cp < 128), derived at comptime from the same
/// `table` array as `glyph`, so every entry is bit-identical to what the
/// binary search would return (same width/height/depth/italic values). Slots
/// with no table row stay null.
const ascii_lut = blk: {
    var lut: [128]?Glyph = undefined;
    for (&lut) |*slot| slot.* = null;
    for (table) |e| {
        if (e.cp < 128) {
            lut[e.cp] = .{ .width = e.w, .height = e.h, .depth = e.d, .italic_correction = e.ic };
        }
    }
    break :blk lut;
};

/// Roman-style counterpart of `ascii_lut`, derived from `table_roman`
/// (cmr10 letters). `lookupAscii` uses it when `style` is `.roman`.
const roman_ascii_lut = blk: {
    var lut: [128]?Glyph = undefined;
    for (&lut) |*slot| slot.* = null;
    for (table_roman) |e| {
        if (e.cp < 128) {
            lut[e.cp] = .{ .width = e.w, .height = e.h, .depth = e.d, .italic_correction = e.ic };
        }
    }
    break :blk lut;
};

/// O(1) ASCII glyph lookup for the bundled default metrics: direct table
/// read, no binary search, no indirect call. Returns null unless `fm` is
/// exactly the bundled `default` and `cp < 128` (including ASCII codepoints
/// absent from the table), so callers fall through to `glyph` otherwise.
/// Roman-style letters resolve from `table_roman` (cmr10), everything else
/// from `table`, matching `glyph`/`glyphAt`.
pub fn lookupAscii(fm: *const FontMetrics, cp: u21, style: atom.CharStyle) ?Glyph {
    if (fm != &default) return null;
    if (cp >= 128) return null;
    if (isRomanLetter(cp) and style == .roman) return roman_ascii_lut[cp];
    return ascii_lut[cp];
}

/// Deterministic fallback for any unknown glyph: width 0.5em, height 0.7em,
/// depth 0.2em. Math-italic style adds a small italic correction.
fn glyphEstimate(self: *const FontMetrics, cp: u21, style: atom.CharStyle) Glyph {
    _ = self;
    _ = cp;
    var ic: f32 = 0.0;
    if (style == .italic) ic = 0.2;
    return .{
        .width = 0.5 * em,
        .height = 0.7 * em,
        .depth = 0.2 * em,
        .italic_correction = ic,
    };
}

/// TeX layout parameters at 10pt (MicroTeX tex_param.res.cpp × 10, plus
/// denom3/sub3/x_height from the standard CM set). Layout scales by size/10.
fn glue(self: *const FontMetrics) GlueParams {
    _ = self;
    return .{
        .axis_height = 2.5,
        .rule_thickness = 0.4,
        .num1 = 6.76508,
        .num2 = 3.93732,
        .num3 = 4.43731,
        .denom1 = 6.85951,
        .denom2 = 3.44841,
        .denom3 = 1.63,
        // Latin-Modern-Math MATH-table constants (measured from
        // latinmodern-math.otf with fontTools, em × 10), matching
        // XeTeX+unicode-math. Verified against the XeTeX render at 10pt:
        // x^2 sup raise 3.630 (= sup1, probe), x_i sub drop 2.470
        // (= sub1), x_i^2 sub drop 2.611 (= sub2 + 4·rt clearance).
        // SuperscriptShiftUp = 0.363em, SuperscriptShiftUpCramped =
        // 0.289em, SubscriptShiftDown = 0.247em; bigop1..5 =
        // UpperLimitGapMin 0.20, LowerLimitGapMin 0.167,
        // UpperLimitBaselineRiseMin 0.111, LowerLimitBaselineDropMin 0.60,
        // bigop5 0 (fontspec fd13 = 0pt on the OT math font).
        .sup1 = 3.63,
        .sup2 = 3.63,
        .sup3 = 2.89,
        .sub1 = 2.47,
        .sub2 = 2.47,
        .sub3 = 2.47,
        .supdrop = 1.75, // SuperscriptBaselineDropMax 0.25em × scriptfactor 0.7
        .subdrop = 1.4, // SubscriptBaselineDropMin 0.20em × scriptfactor 0.7
        .bigop_spacing1 = 2.0,
        .bigop_spacing2 = 1.67,
        .bigop_spacing3 = 1.11,
        .bigop_spacing4 = 6.0,
        .bigop_spacing5 = 0.0,
        .scriptfactor = 0.7,
        .scriptscriptfactor = 0.5,
        .x_height = 4.30555,
    };
}

/// Display-variant metrics for a big operator: the cmex10 next-larger
/// character TeX uses in display style (TFM NEXTLARGER chain, verified via
/// tftopl: ∑ O130, ∏ O131, ∐ O141, ∫/∮ O111, ⋂/⋃/⨆ O107), em × 10 at 10pt
/// like `table`. `w` is now the Latin-Modern-Math advance of the drawn
/// display glyph (∑ 10.56, ∏/∐ 9.44, ⋂/⋃/⨆ 8.33, ∫/∮ 6.65), kept for
/// reference and parity with the metric tables; layoutOp boxes the op by
/// bigOpInk (layout.zig) at the drawn size instead. The display glyph is
/// drawn at DESIGN size (1.0× size_pt — unicode-math/XeTeX draws the
/// display big op at its design size, measured ≈9.96pt at 10pt), so this
/// table carries no scale factor; only `ic` is live: the display-limit skew
/// and the post-op italic-correction tail use the Latin-Modern-Math
/// MATH-table italicsCorrection (∫/∮ 0.332em → 3.32 at 10pt, verified in
/// XeTeX-LM \showbox: the post-∫ kern and the limit skew are 3.32pt at 10pt
/// and 6.64pt at 20pt, i.e. it scales with size_pt like the other table ic
/// values). The h/d below are the old cmex10 reference values only.
pub const DisplayOp = struct {
    /// Codepoint drawn in the display-style position of a big operator.
    cp: u21,
    /// Advance of the display glyph at the base size, in points. Reference
    /// value: layoutOp boxes the operator by `bigOpInk` instead.
    w: f32,
    /// Nominal ascent at the base size, in points. Reference value only —
    /// see `w`.
    h: f32,
    /// Nominal descent at the base size, in points; reference value only.
    d: f32,
    /// Latin-Modern-Math MATH-table italic correction in points at the base
    /// size — the live value here, driving the post-operator tail and the
    /// skew of a display-style limit.
    ic: f32,
};

const display_ops = [_]DisplayOp{
    .{ .cp = 0x220F, .w = 9.44, .h = 1.00001, .d = 15.00012, .ic = 0 }, // ∏ O131
    .{ .cp = 0x2210, .w = 9.44, .h = 1.00001, .d = 15.00012, .ic = 0 }, // ∐ O141
    .{ .cp = 0x2211, .w = 10.56, .h = 1.00001, .d = 15.00012, .ic = 0 }, // ∑ O130
    .{ .cp = 0x222B, .w = 6.65, .h = 0, .d = 22.22246, .ic = 3.32 }, // ∫ O111
    .{ .cp = 0x222E, .w = 6.65, .h = 0, .d = 22.22246, .ic = 3.32 }, // ∮ O111
    .{ .cp = 0x22C2, .w = 8.33, .h = 1.00001, .d = 15.00012, .ic = 0 }, // ⋂ O107
    .{ .cp = 0x22C3, .w = 8.33, .h = 1.00001, .d = 15.00012, .ic = 0 }, // ⋃ O107
    .{ .cp = 0x2A06, .w = 8.33, .h = 1.00001, .d = 15.00012, .ic = 0 }, // ⨆ O107
};

/// Display-variant metrics for a big-operator codepoint; null if not one.
pub fn displayOp(cp: u21) ?DisplayOp {
    for (display_ops) |op| {
        if (op.cp == cp) return op;
    }
    return null;
}

/// The bundled metric source: Latin-Modern-Math advance widths at the 10pt
/// base, with no font wired in — the pure static-table regime described on
/// `FontMetrics`.
///
/// It is a `const`, so copying it is free and every copy is interchangeable:
/// lookups allocate nothing and write nothing, which is what makes one
/// instance safe to share across threads. This is the metrics
/// `ztex.layout.render` measures with, and `lookupAscii` recognises this
/// exact value — pointer equality — and only this one.
pub const default: FontMetrics = .{
    .glyph = glyph,
    .glue = glue,
    .glyphEstimate = glyphEstimate,
};

// ── tests ────────────────────────────────

const testing = std.testing;

test "metrics: table is sorted by codepoint" {
    for (table[1..], 0..) |entry, i| {
        try testing.expect(table[i].cp < entry.cp);
    }
}

test "metrics: every bundled glyph resolves with positive extent" {
    for (table) |entry| {
        const g = default.glyph(&default, entry.cp, .italic);
        try testing.expect(g != null);
        if (g) |gg| {
            try testing.expect(gg.width > 0.0);
            // total extent: some glyphs (e.g. '=', big ops) sit above or
            // hang below the baseline, so height alone may be zero
            try testing.expect(gg.height + gg.depth > 0.0);
        }
    }
}

test "metrics: digits letters operators greek are covered" {
    const cps = [_]u21{
        0x30, 0x39, // digits 0 9
        0x61, 0x7A, 0x41, 0x5A, // letters a z A Z
        0x2B, 0x2D, 0x3D, 0x3C,
        0x3E, 0x28, 0x29, 0x5B,
        0x5D, 0x7B, 0x7D,
        0x2F, 0x7C, 0x2C, 0x2E, 0x3B, 0x21, // + - = < > ( ) [ ] { } / | , . ; !
        0x03B1, 0x03C9, 0x0391, 0x03A9, // α ω Α Ω
        0x03B6, 0x03C8, 0x03C2, 0x03D1, 0x039E, 0x03A5, 0x03A8, // ζ ψ ς ϑ Ξ Υ Ψ
        0x0131, 0x0237, 0x210F, 0x2127, 0x00F0, // ı ȷ ℏ ℧ ð
        0x25B3, 0x25BD, 0x25A1, 0x25A0, 0x25CA, 0x29EB, 0x2713, // △ ▽ □ ■ ◊ ⧫ ✓
        0x2660, 0x2661, 0x2662, 0x2663, 0x266D, 0x266E, 0x266F, // suits + music
        0x00A3, 0x00A5, 0x00A7, 0x00A9, 0x00B6, // £ ¥ § © ¶
        0x2221, 0x2222, 0x2035, 0x2204, 0x2241, 0x2246, 0x2247, 0x2249, // ∡ ∢ ‵ ∄ ≁ ≆ ≇ ≉
        0x2270, 0x2271, 0x2288, 0x2289, 0x22D8, 0x22D9, // ≰ ≱ ⊈ ⊉ ⋘ ⋙
        0x21A3, 0x21C4, 0x2215, 0x2A2F, 0x2912, 0x03D8, // ↣ ⇄ ╱ ⨯ ⤒ Ϝ
        0x2211, 0x220F, 0x222B, // ∑ ∏ ∫
    };
    for (cps) |cp| {
        const g = default.glyph(&default, cp, .roman);
        try testing.expect(g != null);
        if (g) |gg| {
            try testing.expect(gg.width > 0.0);
            try testing.expect(gg.height + gg.depth > 0.0);
        }
    }
}

test "metrics: unknown codepoint falls back to estimate" {
    const cp: u21 = 0x1F600;
    try testing.expect(default.glyph(&default, cp, .italic) == null);
    const est = default.glyphEstimate(&default, cp, .italic);
    try testing.expect(est.width > 0.0);
    try testing.expect(est.height > 0.0);
}

test "metrics: glue parameters are positive" {
    const gp = default.glue(&default);
    inline for (@typeInfo(GlueParams).@"struct".field_names) |name| {
        // bigop_spacing5 is 0.0 in Latin Modern Math (the MATH-table
        // big-op padding, measured: fontspec fd13 = 0pt on the OT math
        // font); every other parameter must be strictly positive.
        if (comptime std.mem.eql(u8, name, "bigop_spacing5")) {
            try testing.expectEqual(@as(f32, 0.0), gp.bigop_spacing5);
        } else {
            try testing.expect(@field(gp, name) > 0.0);
        }
    }
}

test "metrics: greek alpha present; operators upright, variables slanted" {
    const alpha = default.glyph(&default, 0x03B1, .italic);
    try testing.expect(alpha != null);
    const plus = default.glyph(&default, 0x2B, .italic) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(f32, 0.0), plus.italic_correction);
    const f = default.glyph(&default, 0x66, .italic) orelse
        return error.TestUnexpectedResult;
    try testing.expect(f.italic_correction > 0.0);
    const est_i = default.glyphEstimate(&default, 0x1F600, .italic);
    const est_r = default.glyphEstimate(&default, 0x1F600, .roman);
    try testing.expect(est_i.italic_correction > 0.0);
    try testing.expectEqual(@as(f32, 0.0), est_r.italic_correction);
}

test "metrics: every roleOfCp math symbol resolves with real CM metrics" {
    // Every codepoint layout.roleOfCp classifies as bin/rel/open/close/
    // punct/op (mirrored here to avoid a metrics → layout import cycle),
    // plus the corpus's common math symbols, must resolve from the table
    // with positive extent — none may fall back to glyphEstimate.
    const bin = [_]u21{
        0x2B,   0x2D,   0x2212, 0x2213, 0x00B1, 0x00D7, 0x00F7, 0x22C5, 0x2217,
        0x2218, 0x2219, 0x2229, 0x222A, 0x2227, 0x2228, 0x2295, 0x2296, 0x2297,
        0x2298, 0x2299, 0x22C2, 0x22C3, 0x2020, 0x2021, 0x2216, 0x2240, 0x228E,
        0x2293, 0x2294, 0x22C4, 0x22C6, 0x25B9, 0x25C3, 0x25CB, 0x2A3F,
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
    // corpus-common math symbols beyond roleOfCp: ∞ ∠ ∇ ∂ √ ′ ″ ∅ ⋯ ·
    const extras = [_]u21{
        0x221E, 0x2220, 0x2207, 0x2202, 0x221A, 0x2032, 0x2033, 0x2205,
        0x22EF, 0x00B7,
    };
    for (bin ++ rel ++ open ++ close ++ punct ++ ops ++ extras) |cp| {
        const g = default.glyph(&default, cp, .roman) orelse
            return error.TestUnexpectedResult;
        try testing.expect(g.width > 0.0);
        try testing.expect(g.height + g.depth > 0.0);
    }
}

test "metrics: corpus relation/bin widths are exact Latin-Modern-Math advances" {
    // Widths (pt at 10pt = em x 10) are the hmtx advances of
    // latinmodern-math.otf (fontTools, unitsPerEm 1000) - the font the SVG
    // actually draws - so layout advance == rendered advance. The old CM
    // widths (cmsy10/cmmi10 slots) differed by up to 0.39em (sum) and are
    // preserved in git history.
    const cases = [_]struct { cp: u21, w: f32 }{
        .{ .cp = 0x2192, .w = 10 }, // -> LM 1em
        .{ .cp = 0x2264, .w = 7.78 }, // <= LM 0.778em
        .{ .cp = 0x2260, .w = 7.78 }, // != LM 0.778em
        .{ .cp = 0x223C, .w = 7.73 }, // ~ LM 0.773em
        .{ .cp = 0x2286, .w = 7.78 }, // subset= LM 0.778em
        .{ .cp = 0x2248, .w = 7.73 }, // ~~ LM 0.773em
        .{ .cp = 0x00B1, .w = 7.78 }, // +- LM 0.778em
        .{ .cp = 0x00B7, .w = 2.78 }, // . LM 0.278em
        .{ .cp = 0x22C5, .w = 2.78 }, // cdot LM 0.278em
        .{ .cp = 0x2208, .w = 6.67 }, // in LM 0.667em
        .{ .cp = 0x2209, .w = 6.67 }, // notin LM 0.667em
        .{ .cp = 0x221E, .w = 10 }, // infty LM 1em
        .{ .cp = 0x221D, .w = 7.78 }, // propto LM 0.778em
        .{ .cp = 0x2220, .w = 7.78 }, // angle LM 0.778em
        .{ .cp = 0x2207, .w = 8.33 }, // nabla LM 0.833em
        .{ .cp = 0x2202, .w = 5.86 }, // partial LM 0.586em
        .{ .cp = 0x221A, .w = 8.33 }, // surd LM 0.833em
        .{ .cp = 0x2032, .w = 3.11 }, // prime LM 0.311em
        .{ .cp = 0x2205, .w = 5 }, // emptyset LM 0.5em
        .{ .cp = 0x2229, .w = 6.67 }, // cap LM 0.667em
        .{ .cp = 0x222A, .w = 6.67 }, // cup LM 0.667em
        .{ .cp = 0x2297, .w = 7.78 }, // otimes LM 0.778em
        .{ .cp = 0x2299, .w = 7.78 }, // odot LM 0.778em
        .{ .cp = 0x2282, .w = 7.78 }, // subset LM 0.778em
        .{ .cp = 0x2283, .w = 7.78 }, // supset LM 0.778em
        .{ .cp = 0x226A, .w = 10 }, // ll LM 1em
        .{ .cp = 0x226B, .w = 10 }, // gg LM 1em
        .{ .cp = 0x22EF, .w = 7.76 }, // cdots LM 0.776em
        .{ .cp = 0x27E8, .w = 3.89 }, // langle LM 0.389em
        .{ .cp = 0x27E9, .w = 3.89 }, // rangle LM 0.389em
        .{ .cp = 0x21A6, .w = 9.77 }, // mapsto LM 0.977em
        .{ .cp = 0x27F6, .w = 14.63 }, // longrightarrow LM 1.463em
    };
    for (cases) |c| {
        const g = default.glyph(&default, c.cp, .roman) orelse
            return error.TestUnexpectedResult;
        try testing.expectApproxEqAbs(c.w, g.width, 0.001);
    }
}

test "metrics: relation/bin symbols beat the glyphEstimate width" {
    // The glyphEstimate fallback width is 0.5em = 5.0pt at 10pt. The real
    // LM Math advances of the corpus's widest symbols are materially
    // different, which is the whole point of the table coverage.
    const cases = [_]u21{
        0x2192, // -> real 10.0 vs 5.0
        0x221E, // infty real 10.0 vs 5.0
        0x2264, // <= real 7.78 vs 5.0
        0x2260, // != real 7.78 vs 5.0
        0x2208, // in real 6.67 vs 5.0
        0x00B1, // +- real 7.78 vs 5.0
        0x2297, // otimes real 7.78 vs 5.0
        0x2282, // subset real 7.78 vs 5.0
    };
    for (cases) |cp| {
        const g = default.glyph(&default, cp, .roman) orelse
            return error.TestUnexpectedResult;
        try testing.expect(g.width > 5.0);
    }
}

test "metrics: remaining glyphEstimate-fallback symbols resolve with real LM Math advances" {
    // Previously missing common symbols that fell back to glyphEstimate's
    // 0.5em = 5.0pt width. Each must now resolve from the table with its
    // exact Latin-Modern-Math advance (em x 10, hmtx / unitsPerEm x 10).
    const cases = [_]struct { cp: u21, w: f32 }{
        .{ .cp = 0x23, .w = 8.33 }, // # LM 0.833em
        .{ .cp = 0x24, .w = 5 }, // $ LM 0.5em
        .{ .cp = 0x25, .w = 8.33 }, // % LM 0.833em
        .{ .cp = 0x26, .w = 7.78 }, // & LM 0.778em
        .{ .cp = 0x5F, .w = 3.33 }, // _ LM 0.333em
        .{ .cp = 0x00AC, .w = 6.67 }, // neg LM 0.667em
        .{ .cp = 0x2026, .w = 8.37 }, // ldots LM 0.837em
        .{ .cp = 0x2111, .w = 5.54 }, // Im LM 0.554em
        .{ .cp = 0x2113, .w = 4.17 }, // ell LM 0.417em
        .{ .cp = 0x2118, .w = 6.36 }, // wp LM 0.636em
        .{ .cp = 0x211C, .w = 8.28 }, // Re LM 0.828em
        .{ .cp = 0x2135, .w = 6.11 }, // aleph LM 0.611em
        .{ .cp = 0x2200, .w = 6.66 }, // forall LM 0.666em
        .{ .cp = 0x2203, .w = 5.56 }, // exists LM 0.556em
        .{ .cp = 0x22A4, .w = 7.78 }, // top LM 0.778em
    };
    for (cases) |c| {
        const g = default.glyph(&default, c.cp, .roman) orelse
            return error.TestUnexpectedResult;
        try testing.expectApproxEqAbs(c.w, g.width, 0.001);
        try testing.expect(g.height + g.depth > 0.0);
    }
    // The wide ones must beat the glyphEstimate 5.0pt width; the narrow
    // ones (\ell 4.17, _ 3.33) are deliberately real, not estimated.
    // ($ is exactly 0.5em = 5.0pt in LM Math, so it is not in this list.)
    const wide = [_]u21{
        0x23,   0x25,   0x26,   0x00AC, 0x2026, 0x2111, 0x2118,
        0x211C, 0x2135, 0x2200, 0x2203, 0x22A4,
    };
    for (wide) |cp| {
        const g = default.glyph(&default, cp, .roman) orelse
            return error.TestUnexpectedResult;
        try testing.expect(g.width > 5.0);
    }
}

test "metrics: the 65 glyphEstimate-gap codepoints resolve with real LM Math advances" {
    // The audit's remaining glyphEstimate fallbacks (F4). Each must resolve
    // with its exact Latin-Modern-Math advance (em x 10 at 10pt,
    // hmtx / unitsPerEm x 10, fontTools on latinmodern-math.otf - replacing
    // the TFM-verified Computer-Modern widths; the codepoints LM Math does
    // not cover - digamma, triangleright/left, baruparrow, blacklozenge -
    // keep their CM widths so the fallback font's advance stays close).
    const cases = [_]struct { cp: u21, w: f32 }{
        .{ .cp = 0x03B6, .w = 5.3 }, // zeta LM 0.53em
        .{ .cp = 0x03B7, .w = 5.3 }, // eta LM 0.53em
        .{ .cp = 0x03B9, .w = 3.08 }, // iota LM 0.308em
        .{ .cp = 0x03BA, .w = 5.3 }, // kappa LM 0.53em
        .{ .cp = 0x03BD, .w = 5.02 }, // nu LM 0.502em
        .{ .cp = 0x03BE, .w = 5.3 }, // xi LM 0.53em
        .{ .cp = 0x03BF, .w = 5 }, // omicron LM 0.5em
        .{ .cp = 0x03C1, .w = 4.88 }, // rho LM 0.488em
        .{ .cp = 0x03C2, .w = 4.74 }, // varsigma LM 0.474em
        .{ .cp = 0x03C4, .w = 5.3 }, // tau LM 0.53em
        .{ .cp = 0x03C5, .w = 5.3 }, // upsilon LM 0.53em
        .{ .cp = 0x03C7, .w = 6.41 }, // chi LM 0.641em
        .{ .cp = 0x03C8, .w = 6.41 }, // psi LM 0.641em
        .{ .cp = 0x03D1, .w = 5.3 }, // vartheta LM 0.53em
        .{ .cp = 0x03D5, .w = 6.41 }, // varphi LM 0.641em
        .{ .cp = 0x03D6, .w = 8.36 }, // varpi LM 0.836em
        .{ .cp = 0x03F1, .w = 4.88 }, // varrho LM 0.488em
        .{ .cp = 0x03F5, .w = 4.14 }, // varepsilon LM 0.414em
        .{ .cp = 0x039E, .w = 6.67 }, // Xi LM 0.667em
        .{ .cp = 0x03A5, .w = 7.78 }, // Upsilon LM 0.778em
        .{ .cp = 0x03A8, .w = 7.78 }, // Psi LM 0.778em
        .{ .cp = 0x03D8, .w = 7.77781 }, // digamma (not in LM Math; CM kept)
        .{ .cp = 0x0131, .w = 2.78 }, // imath LM 0.278em
        .{ .cp = 0x0237, .w = 3.06 }, // jmath LM 0.306em
        .{ .cp = 0x210F, .w = 5.76 }, // hbar LM 0.576em
        .{ .cp = 0x2127, .w = 7.22 }, // mho LM 0.722em
        .{ .cp = 0x00F0, .w = 5 }, // eth LM 0.5em
        .{ .cp = 0x25B3, .w = 9.68 }, // triangle LM 0.968em
        .{ .cp = 0x25BD, .w = 9.68 }, // bigtriangledown LM 0.968em
        .{ .cp = 0x25A1, .w = 7.78 }, // square LM 0.778em
        .{ .cp = 0x25A0, .w = 7.78 }, // blacksquare LM 0.778em
        .{ .cp = 0x25CA, .w = 5.72 }, // lozenge LM 0.572em
        .{ .cp = 0x29EB, .w = 6.66669 }, // blacklozenge (not in LM Math; CM kept)
        .{ .cp = 0x2713, .w = 8.33 }, // checkmark LM 0.833em
        .{ .cp = 0x2660, .w = 7.78 }, // spadesuit LM 0.778em
        .{ .cp = 0x2661, .w = 7.78 }, // heartsuit LM 0.778em
        .{ .cp = 0x2662, .w = 7.78 }, // diamondsuit LM 0.778em
        .{ .cp = 0x2663, .w = 7.78 }, // clubsuit LM 0.778em
        .{ .cp = 0x266D, .w = 3.88 }, // flat LM 0.388em
        .{ .cp = 0x266E, .w = 3.88 }, // natural LM 0.388em
        .{ .cp = 0x266F, .w = 3.88 }, // sharp LM 0.388em
        .{ .cp = 0x00A7, .w = 4.44 }, // S LM 0.444em
        .{ .cp = 0x00B6, .w = 6.11 }, // P LM 0.611em
        .{ .cp = 0x00A3, .w = 7.5 }, // pounds LM 0.75em
        .{ .cp = 0x00A5, .w = 7.5 }, // yen LM 0.75em
        .{ .cp = 0x00A9, .w = 6.83 }, // copyright LM 0.683em
        .{ .cp = 0x2221, .w = 7.78 }, // measuredangle LM 0.778em
        .{ .cp = 0x2222, .w = 7.78 }, // sphericalangle LM 0.778em
        .{ .cp = 0x2035, .w = 3.11 }, // backprime LM 0.311em
        .{ .cp = 0x2204, .w = 5.56 }, // nexists LM 0.556em
        .{ .cp = 0x2241, .w = 7.73 }, // nsim LM 0.773em
        .{ .cp = 0x2246, .w = 7.78 }, // simneqq LM 0.778em
        .{ .cp = 0x2247, .w = 7.78 }, // ncong LM 0.778em
        .{ .cp = 0x2249, .w = 7.73 }, // napprox LM 0.773em
        .{ .cp = 0x2270, .w = 7.78 }, // nleq LM 0.778em
        .{ .cp = 0x2271, .w = 7.78 }, // ngeq LM 0.778em
        .{ .cp = 0x2288, .w = 7.78 }, // nsubseteq LM 0.778em
        .{ .cp = 0x2289, .w = 7.78 }, // nsupseteq LM 0.778em
        .{ .cp = 0x22D8, .w = 12.85 }, // lll LM 1.285em
        .{ .cp = 0x22D9, .w = 12.85 }, // ggg LM 1.285em
        .{ .cp = 0x21A3, .w = 11.92 }, // rightarrowtail LM 1.192em
        .{ .cp = 0x21C4, .w = 10.18 }, // rightleftarrows LM 1.018em
        .{ .cp = 0x2215, .w = 5.68 }, // diagup LM 0.568em
        .{ .cp = 0x2A2F, .w = 7.78 }, // times LM 0.778em
        .{ .cp = 0x2912, .w = 5.00002 }, // baruparrow (not in LM Math; CM kept)
    };
    for (cases) |c| {
        const g = default.glyph(&default, c.cp, .roman) orelse
            return error.TestUnexpectedResult;
        try testing.expectApproxEqAbs(c.w, g.width, 0.001);
        try testing.expect(g.height + g.depth > 0.0);
    }
    // The wide ones must beat the glyphEstimate 5.0pt width (narrow ones -
    // iota 3.08, jmath 3.06, backprime 3.11, flat 3.88 - are deliberately
    // real, not estimated).
    const wide = [_]u21{
        0x03C8, 0x03D6, 0x039E, 0x03A5, 0x03A8, 0x03D8, 0x210F, 0x2127,
        0x25B3, 0x25BD, 0x25A1, 0x25A0, 0x25CA, 0x29EB, 0x2713, 0x2660,
        0x2661, 0x2662, 0x2663, 0x00A3, 0x00A5, 0x00A9, 0x00B6, 0x2221,
        0x2222, 0x2204, 0x2241, 0x2246, 0x2247, 0x2249, 0x2270, 0x2271,
        0x2288, 0x2289, 0x22D8, 0x22D9, 0x21A3, 0x21C4, 0x2215, 0x2A2F,
    };
    for (wide) |cp| {
        const g = default.glyph(&default, cp, .roman) orelse
            return error.TestUnexpectedResult;
        try testing.expect(g.width > 5.0);
    }
}

test "metrics: roman style letters use LM Math advances, roman = italic" {
    // \text/\mathrm are TeX family 0 = cmr10; math (italic) letters are
    // cmmi10. LM Math is a single OTF: the advance of a letter is the same
    // regardless of the style flag (roman/italic is a font-style switch to
    // the same font), so roman and italic rows now agree - the old cmr10 vs
    // cmmi10 split (e.g. 'f' +1.84pt at 10pt) is gone. Widths are the LM
    // advances (em x 10 at 10pt).
    const cases = [_]struct { cp: u21, roman: f32, italic: f32 }{
        .{ .cp = 'a', .roman = 5.0, .italic = 5.0 },
        .{ .cp = 'b', .roman = 5.56, .italic = 5.56 },
        .{ .cp = 'c', .roman = 4.44, .italic = 4.44 },
        .{ .cp = 'f', .roman = 3.06, .italic = 3.06 },
        .{ .cp = 'i', .roman = 2.78, .italic = 2.78 },
        .{ .cp = 'j', .roman = 3.06, .italic = 3.06 },
        .{ .cp = 'h', .roman = 5.56, .italic = 5.56 },
        .{ .cp = 'T', .roman = 7.22, .italic = 7.22 },
        .{ .cp = 'V', .roman = 7.5, .italic = 7.5 },
        .{ .cp = 'W', .roman = 10.28, .italic = 10.28 },
        .{ .cp = 'Y', .roman = 7.5, .italic = 7.5 },
        .{ .cp = 'H', .roman = 7.5, .italic = 7.5 },
        .{ .cp = 'K', .roman = 7.78, .italic = 7.78 },
    };
    for (cases) |c| {
        const r = default.glyph(&default, c.cp, .roman) orelse
            return error.TestUnexpectedResult;
        const i = default.glyph(&default, c.cp, .italic) orelse
            return error.TestUnexpectedResult;
        try testing.expectApproxEqAbs(c.roman, r.width, 0.001);
        try testing.expectApproxEqAbs(c.italic, i.width, 0.001);
    }
    // \mathrm{ab} = LM a+b; "hello" = LM h+e+l+l+o (10.56 and 20.56).
    var ab: f32 = 0;
    for ("ab") |ch| ab += (default.glyph(&default, ch, .roman) orelse
        return error.TestUnexpectedResult).width;
    try testing.expectApproxEqAbs(@as(f32, 10.56), ab, 0.001);
    var hello: f32 = 0;
    for ("hello") |ch| hello += (default.glyph(&default, ch, .roman) orelse
        return error.TestUnexpectedResult).width;
    try testing.expectApproxEqAbs(@as(f32, 20.56), hello, 0.001);
    var hello_italic: f32 = 0;
    for ("hello") |ch| hello_italic += (default.glyph(&default, ch, .italic) orelse
        return error.TestUnexpectedResult).width;
    try testing.expectApproxEqAbs(@as(f32, 20.56), hello_italic, 0.001);
}

test "metrics: roman letters at script sizes scale the LM Math advance" {
    // glyphAt at the 7pt/5pt bands: roman letters resolve against the same
    // LM Math advance (em x 10) and the layout's size_pt/10 factor yields
    // 0.7x/0.5x at 7pt/5pt - LM Math has no optical sizes, so the old
    // cmr7/cmr5 optical values (5.69447 / 6.80567 for 'a') are gone.
    const a7 = glyphAt(&default, 'a', .roman, 7.0) orelse
        return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(@as(f32, 5.0), a7.width, 0.001); // LM a
    const a7i = glyphAt(&default, 'a', .italic, 7.0) orelse
        return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(@as(f32, 5.0), a7i.width, 0.001); // LM a
    const a5 = glyphAt(&default, 'a', .roman, 5.0) orelse
        return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(@as(f32, 5.0), a5.width, 0.001); // LM a
    // lookupAscii fast path agrees with glyph for roman letters.
    const fast = lookupAscii(&default, 'a', .roman) orelse
        return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(@as(f32, 5.0), fast.width, 0.001);
    const fast_i = lookupAscii(&default, 'a', .italic) orelse
        return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(@as(f32, 5.0), fast_i.width, 0.001);
}
