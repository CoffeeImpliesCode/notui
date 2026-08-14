# Formula TUI: LaTeX → coverage → kitty graphics (2026-08-14)

Build a LaTeX formula TUI in notui: type LaTeX, render it as an image in
an inline band via kitty graphics. Engine: ztex, VENDORED into
`vendor/ztex` (a snapshot — the upstream checkout is owned by another
agent; all changes are local).

## Pipeline

```
input (LaTeX text)
  → ztex.render(gpa, src, size_pt)        vendor/ztex facade
  → DrawList { text / rect / line }       absolute coords, baseline (x,y), pt
  → rasterizer                            per drawable:
      text  → face(style) → glyph id → glyf outline (quadratic, em, Y-up)
              → scale em→px → coverage (SIMD, row-parallel) → alpha
      rect  → direct fill
      line  → 1px fill (v1)
  → RGBA bitmap (bounds = DrawList w × (height+depth), dpi 96 → px)
  → notui.image.kitty transmit (a=t) + Region.placeAt
  → band below the input prompt
```

## Contract

```zig
// vendor/ztex/src/font.zig (extended — NEW)
pub const QuadCurve = struct { p0: [2]f32, p1: [2]f32, p2: [2]f32 };
pub const Outline = struct { gpa: std.mem.Allocator, curves: []QuadCurve };
pub fn glyphOutline(self: *FontFace, gpa: std.mem.Allocator, gid: u32) !Outline
// em units, Y-up; contours are consecutive runs (no explicit list needed
// for coverage: the sweep sums signed area over all curves)
```

```zig
// src/coverage.zig (NEW — pure std, own QuadCurve, no ztex import)
pub const QuadCurve = struct { p0: [2]f32, p1: [2]f32, p2: [2]f32 };
/// coverage of a row: for each pixel x in [x_start, x_start+out.len),
/// sum scanlineSweep over all curves; clamp [0,1]. Vectorized: a row of
/// N pixels in parallel via @Vector (generic SIMD).
pub fn coverageRow(curves: []const QuadCurve, y: f32, x_start: f32, out: []f32) void;
```

## Coverage algorithm (ported from nogui `shaders/sweep.frag`)

Per pixel (size = 1×1 window at (offset.x, offset.y)) and per quadratic
`(p0,p1,p2)` (Y-up, FreeType space — y grows up):

- Early-outs (per curve, per row — scalar): vertical-line fast path;
  y-window disjoint.
- X intersection params h_min_t/h_max_t, v_min_t/v_max_t via
  `intersectMonotonic(qa, c0, c1, c2, target)` (quadratic root; linear
  when |qa| < 1e-10; the §8.3 `1.0 - h_check.w` fix).
- min_t/max_t clamp; area = trapezoid term `(size.x - (q0.x+q1.x)/2) *
  (q1.y-q0.y)` plus the side-rectangle terms; `sign(delta.y)` applied.
- Sum over curves; clamp [0,1] → coverage.

The per-pixel input is ONLY `offset.x` → a row of N pixels vectorizes as
`@Vector(N, f32)` of x-offsets: per-curve scalar pre-checks, then
vectorized x-math (`@select` for the branches), accumulate; the scalar
and vector paths must be bit-identical (test).

## Faces (v1: roman only — quadratic)

- lmroman_regular / lmroman_italic: TTF (glyf) ✓
- lmmath: OTF/CFF (cubic) ✗ — v1 formulas avoid lmmath-only glyphs
  (∑ √ ∫ …); fraction/script formulas are all-roman + rect rules.

## Demo behavior

- Prompt line (notui Reader, line editing) + 4-row band below.
- Enter → render the typed LaTeX → transmit + placeAt into the band.
- Default formula on start; q quits; Ctrl+C clears the line.
- Errors (parse/unknown command) print a hint line, keep the band.

## Files

- `vendor/ztex/src/font.zig` — glyf outline extraction (B1)
- `src/coverage.zig` — SIMD coverage rasterizer (B2)
- `examples/formula_tui.zig` — demo (B3, after B1+B2)
- `build.zig`/`build.zig.zon` — vendored ztex modules + example (done)
