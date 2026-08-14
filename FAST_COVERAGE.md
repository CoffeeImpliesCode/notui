# Fast row-intersection coverage algorithm

Implementation instructions for a faster alternative to the analytic sweep in
`src/coverage.zig`. The current `coverageRow` invokes the full analytic sweep
for every pixel of every row and every curve piece. The alternative exploits
the sweep's structure: a monotonic piece's contribution to a row is a STEP —
zero on one side of its x-extent, `sign(dy) × y-span` on the other — and only
the extent pixels need the analytic invocation.

## Context (read `src/coverage.zig` first)

- `QuadCurve { p0, p1, p2: [2]f32 }` — quadratic bezier, Y-up, pixel-window
  space (curves are pre-scaled/translated by the caller).
- `monotonicize(curve) -> MonoSplit { pieces: [4]QuadCurve, n }` — splits each
  quadratic at its x/y extrema; every piece is monotonic in x AND y. This is
  the algorithm's prerequisite: a monotonic piece crosses a horizontal
  pixel-center line exactly once.
- `scanlineSweepScalar(offset_x, offset_y, c) f32` — the exact per-pixel
  signed-area value for a 1×1 window at `(offset_x, offset_y)`. Its
  "entirely-left" branch returns `(v_max_y - v_min_y) * size_x` with the sign
  built into the v_min/v_max ordering (v_min is the lower y, v_max the upper,
  regardless of travel direction) — i.e. exactly `sign(dy) × (the piece's
  y-span inside the window)` for a window whose x-range lies entirely right of
  the piece. Summed over a closed contour these steps give the winding
  number, which IS the coverage for fully-covered pixels.
- `scanlineSweepVec(comptime L, offset_xs: @Vector(L, f32), offset_y, c)` — the
  same sweep with per-lane x offsets; bit-identical to the scalar. Reuse it
  for the extent-pixel lane renders.

## The algorithm

```
pub fn coverageRowFast(curves: []const QuadCurve, y: f32, x_start: f32, out: []f32) void
```

Per row `y` (the window covers `[y, y+1)`; `out` covers pixels
`[x_start, x_start + out.len)`):

1. **Monotonicize** every curve (reuse `monotonicize`); sweep the pieces, not
   the raw curves.
2. **Hit test** (SIMD-able): a piece overlaps the row when its y-range
   `[y_lo, y_hi] = [min(p0.y, p2.y), max(p0.y, p2.y)]` intersects `[y, y+1)`:
   skip if `y_hi <= y or y_lo >= y + 1`. For hits compute:
   - `span = min(y + 1, y_hi) - max(y, y_lo)` — the piece's y-overlap with the
     row (1.0 for pieces that cross the whole row; smaller for pieces whose
     y-range lies partially inside it).
   - `dir = sign(p2.y - p0.y)` — the sweep's sign convention.
   - **x-extent**: the piece's x-range within the row's y-slice.
     `t_lo = clamp(intersectMonotonic(qa_y, p0.y, p1.y, p2.y, y), 0, 1)`,
     `t_hi = clamp(intersectMonotonic(qa_y, p0.y, p1.y, p2.y, y + 1), 0, 1)`
     (qa_y as in the sweep: `p0.y + p2.y - 2*p1.y`), then
     `x_lo = evalBez.x(p0, p1, p2, t_lo)`, `x_hi = evalBez.x(p0, p1, p2, t_hi)`,
     `extent = [min(x_lo, x_hi), max(x_lo, x_hi)]`.
3. **Step array** (the "0 on one side, 1 on the other"): a difference array
   `diff[0 .. out.len + 1]` zeroed. For each hit piece, the pixels strictly
   right of its extent get `dir * span`:
   `idx = @floor(extent_max) - x_start + 1` (as an index into `out`);
   - `idx <= 0` → `diff[0] += dir * span` (the extent is left of the window:
     every pixel in `out` gets the step);
   - `0 < idx <= out.len` → `diff[idx] += dir * span`;
   - `idx > out.len` → skip (the extent is right of the window).
   Then the prefix sum: `out[i] = out[i-1] + diff[i]` for `i` in `0..out.len`.
4. **Corrections** (the fractional pixels): for each hit piece, for every
   pixel `p` in `[floor(extent_min), ceil(extent_max)]` intersected with
   `[x_start, x_start + out.len)`:
   `out[p - x_start] += scanlineSweepScalar(p, y, piece)`.
   No double count: the piece's own diff sits at `floor(extent_max) + 1`, so
   the step sum at the extent pixels excludes it; the sweep value replaces
   the (zero) step contribution at exactly those pixels. Multiple pieces with
   overlapping extents are additive.
5. **Clamp** every `out[i]` to `[0, 1]` (same as `coverageRow`).

## Why it is correct

For a monotonic piece and a pixel window whose x-range lies entirely right of
the piece's x-extent in that row, the sweep returns exactly
`sign(dy) × (the piece's y-span inside the window)` — the "entirely-left"
shortcut. That is the step value `dir * span`. For a window entirely left of
the extent the sweep returns 0. Only the extent pixels (where the piece
crosses the window) need the analytic value; `scanlineSweepScalar` is exact
there. The per-contour sum of the steps equals the winding number, which is
the coverage — identical to what `coverageRow` accumulates, only with
`O(hits × extent_width)` sweeps instead of `O(pieces × row_width)`.

## Edge cases (all must be handled)

- **Partial-overlap pieces** (y-range inside the row, e.g. a horizontal-ish
  stroke cap): `span < 1` — the step is `dir * span`, NOT ±1. The extent
  pixels still get the exact sweep.
- **Extent exactly on a pixel boundary**: floor/ceil semantics per the
  formulas above; the step's diff index is `floor(extent_max) + 1` so the
  boundary pixel is corrected, not stepped.
- **Wide extents** (steep curves): sweep every pixel of
  `[floor(extent_min), ceil(extent_max)]` — usually 1–2 pixels, bounded by
  the curve's deviation in the row.
- **Extents outside the window**: the diff clamp rules in step 3.
- **No hits / empty rows**: `out` stays zero (the clamp is a no-op).
- **Multiple crossings in one pixel**: corrections are additive; each piece's
  own diff is excluded from its extent pixels by construction.
- **out.len == 1**: the diff array is `[2]f32`; all indices still apply.

## SIMD (per the design goal)

- **Hit test**: batch the pieces' `(y_lo, y_hi)` in `@Vector(lanes, f32)`;
  the overlap mask filters the pieces into a small fixed stack array (no
  allocation). The pieces array is bounded: `≤ 4 × curves.len` — size a
  stack buffer for the practical glyph case and fall back to the scalar
  loop when the count exceeds it.
- **Corrections**: collect the extent pixels' x-offsets into a
  `@Vector(lanes, f32)` and call the existing `scanlineSweepVec(lanes, xs, y,
  piece)` per piece — one vector call per piece with hits instead of one
  scalar call per extent pixel.
- The diff/prefix pass is sequential (vectorizing the prefix is optional and
  only pays for very wide rows).

## Tests (prove fast == sweep)

Add inline tests in `src/coverage.zig`:

1. The existing shapes (unit square, hole 'o', parabola, vertical line):
   `coverageRowFast` must equal `coverageRow` within `1e-4` on every pixel
   (bit-exactness is NOT required — the addition order differs).
2. Property: the existing random-curve generator (incl. the forced
   non-monotonic kind), random rows and windows: fast == sweep within 1e-4.
3. Boundary cases: a piece whose extent lands exactly on an integer x;
   a partial-overlap piece (span < 1); a row with zero hits; a window that
   clips the extent (diff clamps).
4. The λ glyph curves (or any real glyph): fast == sweep on every row.

## Integration (the cmdline switch)

- `src/coverage.zig`: add `pub fn coverageRowFast` next to `coverageRow`
  (same signature, same zero-allocation discipline). Keep everything else.
- `examples/formula_tui.zig`: add a `--algo fast|sweep` argument (default
  `sweep`) for the piped path — threaded through `runPlain` → `rasterize` →
  `drawText`, which picks `coverage.coverageRowFast` vs `coverage.coverageRow`
  at the call site. The `--bench N` mode already prints parse/render
  averages; `--bench N --algo fast` is the comparison harness.
- The interactive path keeps the default (`sweep`) — the switch is
  cmdline-only.

## Acceptance

- All tests green; fast == sweep within 1e-4 everywhere.
- `zig build -Doptimize=ReleaseSafe` + `--bench 300 <Euler-Lagrange> --algo
  fast` reports a render average at or below the sweep's (the goal is
  measurably fewer analytic invocations: measure and report both).
- `zig fmt`, zbc/ziglint clean; full gate green.

## Measured (2026-08-15, i7-9750H, zig 0.16.0)

Unit bench (`src/_covbench.zig`, λ glyph: 29 curves / 116 pieces, 15 rows ×
100k iters; wide: 6 glyph copies = 174 curves / 696 pieces > `batch_cap`,
exercising the scalar fallback):

| config | sweep ns/row | fast ns/row | ratio |
|---|---|---|---|
| ReleaseSafe, narrow λ | 1128 | 935 | 0.83 |
| ReleaseSafe, wide 6×λ | 23387 | 5602 | 0.24 |
| ReleaseFast, narrow λ | 1106 | 938 | 0.85 |
| ReleaseFast, wide 6×λ | 23800 | 5579 | 0.23 |

App-level (`zig build -Doptimize=ReleaseSafe` + `--bench 300 --algo`):
sweep render 0.052 ms, fast 0.064 ms (fast 0.87×, after the safety fix;
before the fix fast was 0.121 ms — 2.3× worse than sweep).

### ReleaseSafe codegen pathology (why the fix exists)

With runtime-safety checks on, `coverageRowFast` was ~6× SLOWER per row than
`coverageRow` (6.0 µs vs 1.1 µs on the λ fixture at ReleaseSafe); at
ReleaseFast the same source ran 0.94 µs and won. Bisected with probe
variants:

- removing the corrections block, the prefix-sum, or the vector hit-test each
  moved ≤ 10 % — no single subsystem was the cost;
- `@setRuntimeSafety(false)` inside `addPiece` alone: no effect (the inline
  fn's checks are decided at the call site);
- `@setRuntimeSafety(false)` across the whole row function: 988 ns/row —
  the full 6× recovered.

Cause: ReleaseSafe emits a cold panic edge (bounds check +
`integerPartOutOfBounds` → `unreachable`) at every checked cast, and those
blocks inside the giant inlined `addPiece → scanlineSweepVec(4)` monolith
break the backend's optimization (block-count/inlining/spill heuristics).
Every index in the kernel is guarded by an adjacent explicit comparison —
the checks are unreachable by construction — so the function now carries a
scoped `@setRuntimeSafety(false)` with a comment enumerating the guards
(`out.len ≤ diff_cap`, `curves.len > batch_cap / 4`, `mono.n ≤ 4`, the
pre-clamped `@intFromFloat` inputs). All library code outside this kernel
keeps its checks; `zig build test` and the examples run with checks on.
