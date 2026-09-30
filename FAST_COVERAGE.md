# Fast row-intersection coverage

`src/coverage.zig` carries two row rasterizers with one contract. Both fill
`out[p - x_start]` with the signed-area coverage of the 1×1 window
`[x, x+1) × [y, y+1)` over `[x_start, x_start + out.len)`, clamp to `[0, 1]`,
allocate nothing, and sweep `Monotonicize`d pieces (a curve turning inside a
pixel window breaks the single-root intersections).

| function | work per row | selected by |
|----------|--------------|-------------|
| `coverageRow` | the reference analytic sweep: every curve × every pixel in the row | default |
| `coverageRowFast` | one difference-array add per hit piece, exact sweep only on the extent pixels | `--algo fast` |

`coverageRow` stays the definition of correct: `coverageRowFast` is checked
against it, pixel for pixel, by the tests below.

## Why a step is enough

A monotonic piece crosses a horizontal line exactly once, so inside one row
its contribution is a **step**: 0 on one side of its x-extent, and
`sign(dy) × y-span` on the other. The reference sweep already knows that —
its "entirely-left" branch returns `(v_max_y - v_min_y) × size_x`, which is
exactly `sign(dy) × (the piece's y-span inside the window)`. Summed over a
closed contour the steps give the winding number, which is the coverage for
fully-covered pixels.

So the whole row needs the analytic sweep only for the handful of pixels
whose 1×1 window actually overlaps a piece's x-extent — usually one or two
per piece. `coverageRowFast` spends its arithmetic there and makes up the
rest with a difference array.

## The algorithm as implemented

For row `y` writing `out[0..out.len)`:

1. **Curve-level early-out.** The control hull's y-range against the row
   window; a disjoint curve skips `monotonicize` entirely.
2. **Monotonicize** each survivor into ≤ 4 x-and-y-monotonic pieces
   (`monotonicize`).
3. **Hit test** each piece: its endpoint y-range `[y_lo, y_hi]` must meet
   `[y, y+1)`. In the batch path the surviving pieces are collected into a
   fixed 128-entry stack array and hit-tested `lanes`-wide (16) as
   `(y_hi > y) & (y_lo < y + 1)`; tail lanes are filled with non-matching
   bounds so the mask cannot select them. The test is the same disjoint
   early-out `scanlineSweepScalar` applies.
4. **`addPiece`** per hit piece writes two things:
   - the step `dir × span` into `diff` at `i_step = floor(extent_max) -
     x_start + 1` — every pixel entirely right of the extent collects it
     through the prefix sum. `span = min(y+1, y_hi) - max(y, y_lo)`, so a
     piece whose y-range lies inside the row steps by a fraction, not by 1.
     `i_step ≤ 0` (extent left of the window) puts the step at index 0;
     `i_step > out.len` (extent right of the window) drops it.
   - the exact `scanlineSweepVec` values straight into `out` for the pixels
     in `[floor(extent_min), ceil(extent_max)]`. A piece's own step sits at
     `floor(extent_max) + 1`, i.e. past the pixels it corrects, so nothing is
     counted twice and overlapping pieces stay additive.
5. **Prefix sum and clamp.** Only `out.len + 1` of the 2049-entry stack
   `diff` is cleared and consumed — rows are typically ~10 px wide, and
   zeroing the whole array per row would dominate the raster cost.

## Bounds, fallbacks, and the scoped `@setRuntimeSafety`

- `batch_cap = 128`: more than `batch_cap / 4` curves take the scalar piece
  loop — identical math, one piece at a time.
- `diff_cap = 2048`: a wider row has no room for the stack difference
  array and delegates to `coverageRow`.
- `@setRuntimeSafety(false)` covers `coverageRowFast` only. ReleaseSafe
  emits a cold panic edge (bounds check + `integerPartOutOfBounds`) at every
  checked cast, and inlined into the `addPiece → scanlineSweepVec` monolith
  those blocks distort the backend's optimization badly enough to make the
  fast path **6× slower** than the sweep (measured 6.0 µs vs 1.1 µs per row
  on the λ fixture; 0.99 µs vs 1.1 µs with the checks scoped off). Every
  index in the kernel is guarded by an adjacent explicit comparison — the
  checks are unreachable by construction:
  - `out.len ≤ diff_cap` (the fallback branch), so `out.len + 1` cannot wrap;
  - `n_pieces ≤ curves.len × 4 ≤ batch_cap` by the `curves.len > batch_cap / 4`
    fallback (a division, so the threshold cannot overflow either);
  - `mono.pieces[0..n]` with `n ≤ 4`, the `monotonicize` contract;
  - `diff[@intFromFloat(i_step)]` and the correction pixel bounds, both
    pre-clamped by the float compares in `addPiece`.

  All library code outside this kernel keeps its checks; `zig build test`
  and the examples run with checks on everywhere else.

## Switching it on

`examples/formula_tui.zig` takes `--algo sweep|fast` (default `sweep`) for
the piped path, threaded through `runPlain → rasterize → drawText`; the
interactive preview keeps the sweep. `--bench <n>` times `n` parse+render
iterations and prints the averages, which is the comparison harness.

## What the tests pin

In `src/coverage.zig`, `expectFastEqSweep` holds `coverageRowFast` to
`coverageRow` within `1e-4` (the accumulation order differs, so bits are not
required):

- the fixed shapes — unit square, hole `'o'`, parabola, vertical line;
- a property pass over the random-curve generator (vertical / straight /
  horizontal / general / forced non-monotonic kinds) across random rows and
  windows;
- the boundary cases: extent ending exactly on an integer x, a
  partial-overlap piece (`span < 1`), a row with zero hits, a window
  clipping the extent on either side, and `out.len == 1`;
- the real λ glyph fixture (`src/lambda_fixture.zig`), every row.

## Measured

ReleaseSafe, `--bench 300`, this host (2026-09-30). Render average is the
raster cost; parse is ztex and is unaffected by the algorithm.

| formula | sweep render avg | fast render avg | fast min vs sweep min |
|---|---|---|---|
| `\lambda` | 0.023 ms | 0.030 ms | 0.014 vs 0.011 ms |
| `\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}` | 0.506 ms | 0.516 ms | 0.231 vs 0.374 ms |

At app scale the two are within noise on the average — the fast path's win
shows on the minimum for the wide formula, where the row work dominates. The
per-row unit bench that motivated the path (0.83× narrow, 0.24× wide on the
λ fixture and a 6-glyph copy) lived in a throwaway `src/_covbench.zig` that
did not survive; `--bench` above is the reproducible harness, and the
advantage grows with the number of curves per row.