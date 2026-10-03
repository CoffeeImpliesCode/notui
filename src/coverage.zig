//! Scanline coverage rasterization for quadratic bezier outlines.
//!
//! `coverageRow` sweeps every curve against a row of 1x1 pixel windows with
//! its lower-left corner at `(x_start + i, y)`, in Y-up space, and returns
//! each pixel's covered fraction clamped to `[0, 1]`. Signed area fills the
//! interior to the RIGHT of travel, which in Y-up is a clockwise outer
//! contour; a PostScript or CFF outline wound counter-clockwise has to be
//! reversed by the caller first.
//!
//! A row of pixels shares one `y` and differs only in `x`, so a row is swept
//! `lanes`-wide as an `@Vector` of x-offsets, with the per-curve scalars
//! hoisted and the per-lane conditionals branchless `@select`s. The vector
//! path produces bit-identical results to the scalar one.
//!
//! Both entry points allocate nothing and take no ownership; `out` is
//! caller-owned and is fully overwritten.

const std = @import("std");
const testing = std.testing;

/// A quadratic bezier control polygon in Y-up space: the curve starts at
/// `p0`, is steered by `p1`, and ends at `p2`.
///
/// Every field is an `[x, y]` pair in that order, the three sit back to
/// back in the `p0`, `p1`, `p2` declaration order with no padding between
/// them, and the struct is `extern`, so that layout is fixed: it is the C
/// layout of three `[2]f32` pairs. A caller holding those same bytes — a
/// font outline, or a `3 x [2]f32` array — may read them as
/// `[]const QuadCurve` with no copy, provided its own declaration is the
/// same fixed layout; check that at the cast.
pub const QuadCurve = extern struct {
    /// Curve start, `[x, y]`.
    p0: [2]f32,
    /// Steer point, `[x, y]`.
    p1: [2]f32,
    /// Curve end, `[x, y]`.
    p2: [2]f32,
};

/// The result of `monotonicize`.
pub const MonoSplit = struct {
    /// `pieces[0..n]` holds the split, in travel order and each piece's
    /// direction preserved; the entries past `n` are undefined.
    pieces: [4]QuadCurve,
    /// How many entries of `pieces` are live; 1 to 4.
    n: u8,
};

/// SIMD lane count for `coverageRow`.
const lanes: usize = 16;

const size_x: f32 = 1.0;
const size_y: f32 = 1.0;

// ── scalar/vector shared arithmetic ────────────────────────
// Both cores call the same generic helpers (T = f32 or a vector of f32),
// so every expression is bit-identical across paths.

inline fn zeroOf(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .float => @as(T, 0.0),
        .vector => @splat(0.0),
        else => unreachable,
    };
}

inline fn oneOf(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .float => @as(T, 1.0),
        .vector => @splat(1.0),
        else => unreachable,
    };
}

/// Broadcast a scalar to T (identity when T is a scalar).
inline fn fromF32(comptime T: type, x: f32) T {
    return switch (@typeInfo(T)) {
        .float => x,
        .vector => @splat(x),
        else => unreachable,
    };
}

/// `if (pred) a else b`; branchless `@select` for vector T.
inline fn sel(comptime T: type, pred: anytype, a: T, b: T) T {
    return switch (@typeInfo(T)) {
        .float => if (pred) a else b,
        .vector => @select(@typeInfo(T).vector.child, pred, a, b),
        else => unreachable,
    };
}

/// Clamp to [0, 1]; same expression in both paths.
inline fn clamp01(comptime T: type, x: T) T {
    return @max(@min(x, oneOf(T)), zeroOf(T));
}

/// GLSL `sign`: +1, -1, or 0.
inline fn sign(comptime T: type, x: T) T {
    const zero = zeroOf(T);
    return sel(T, x > zero, oneOf(T), sel(T, x < zero, -oneOf(T), zero));
}

/// Quadratic bezier value at t (GLSL evalBez).
inline fn evalBez(comptime T: type, p0: T, p1: T, p2: T, t: T) T {
    const two = fromF32(T, 2.0);
    const mt = oneOf(T) - t;
    return mt * mt * p0 + two * mt * t * p1 + t * t * p2;
}

/// ∫_0^t x(s) y'(s) ds for the quadratic bezier: the exact right-edge
/// rule area between the curve and a vertical line. With
/// a = c0 - 2 c1 + c2, b = 2 (c1 - c0), c = c0 for each axis:
/// F(t) = (a_x a_y / 2) t⁴ + (a_x b_y + 2 a_y b_x) t³ / 3
///      + (b_x b_y + 2 a_y c_x) t² / 2 + b_y c_x t.
inline fn bezIntX(comptime T: type, x0: T, x1: T, x2: T, y0: T, y1: T, y2: T, t: T) T {
    const two = fromF32(T, 2.0);
    const ax = x0 - two * x1 + x2;
    const bx = two * (x1 - x0);
    const ay = y0 - two * y1 + y2;
    const by = two * (y1 - y0);
    const t2 = t * t;
    const t3 = t2 * t;
    const t4 = t3 * t;
    const term4 = (ax * ay * fromF32(T, 0.5)) * t4;
    const term3 = ((ax * by + two * ay * bx) * fromF32(T, 1.0 / 3.0)) * t3;
    const term2 = ((bx * by + two * ay * x0) * fromF32(T, 0.5)) * t2;
    const term1 = (by * x0) * t;
    return term4 + term3 + term2 + term1;
}

/// Monotonic-root intersection (GLSL intersectMonotonic): linear when
/// |qa| < 1e-10, else the quadratic root with sign(c2 - c0).
inline fn intersectMonotonic(comptime T: type, qa: T, c0: T, c1: T, c2: T, target: T) T {
    const two = fromF32(T, 2.0);
    const four = fromF32(T, 4.0);
    const half = fromF32(T, 0.5);
    const qb = two * (c1 - c0);
    const lin = sel(T, @abs(qb) < fromF32(T, 1e-10), zeroOf(T), (target - c0) / qb);
    const qc = c0 - target;
    const d = qb * qb - four * qa * qc;
    const sqrt_d = sel(T, d < zeroOf(T), zeroOf(T), @sqrt(d));
    const inv_2a = half / qa;
    const quad = -qb * inv_2a + sign(T, c2 - c0) * sqrt_d * inv_2a;
    // Linear branch when the quadratic term is negligible RELATIVE to the
    // linear coefficient. The quad formula is (sd - qb) * inv_2a, which
    // cancels catastrophically in f32 when qa is small (a curve that is
    // exactly linear in the coordinate — the λ's foot line has
    // qa_y = -4e-7 in f32): the absolute 1e-10 floor (the reference's)
    // sends it down the quad path, sd rounds to qb, and the roots come
    // out 0/1 — the curve's coverage smears across the whole row.
    const near_linear = @abs(qa) < fromF32(T, 1e-3) * @abs(qb) + fromF32(T, 1e-10);
    return sel(T, near_linear, lin, quad);
}

/// The horizontal-line case of the sweep: `a >= c` returns `d`, else
/// `b <= c` returns `1 - d`, else the monotonic root at `c`.
inline fn hCheck(comptime T: type, qa: T, c0: T, c1: T, c2: T, a: T, b: T, c: f32, d: f32) T {
    const cc = fromF32(T, c);
    const dd = fromF32(T, d);
    return sel(
        T,
        a >= cc,
        dd,
        sel(T, b <= cc, oneOf(T) - dd, intersectMonotonic(T, qa, c0, c1, c2, cc)),
    );
}

// ── monotonic splitting ────────────────────────────
// The intersection helpers solve ONE root per coordinate, which is exact
// only when the quadratic is monotonic in x and y over its span. Glyph
// curves routinely turn inside a pixel (non-monotonic quadratics), so
// every curve is split at its coordinate extrema before sweeping.

/// Split a quadratic at parameter t (de Casteljau); both pieces keep the
/// curve's direction (p0 -> p2 order).
fn splitAt(curve: QuadCurve, t: f32) [2]QuadCurve {
    const mt = 1.0 - t;
    const p0 = curve.p0;
    const p1 = curve.p1;
    const p2 = curve.p2;
    const left_p1 = [2]f32{ p0[0] * mt + p1[0] * t, p0[1] * mt + p1[1] * t };
    const left_p2 = [2]f32{
        p0[0] * mt * mt + 2.0 * p1[0] * mt * t + p2[0] * t * t,
        p0[1] * mt * mt + 2.0 * p1[1] * mt * t + p2[1] * t * t,
    };
    const right_p1 = [2]f32{ p1[0] * mt + p2[0] * t, p1[1] * mt + p2[1] * t };
    return .{
        .{ .p0 = p0, .p1 = left_p1, .p2 = left_p2 },
        .{ .p0 = left_p2, .p1 = right_p1, .p2 = p2 },
    };
}

/// The parameter in (0, 1) where the quadratic coordinate (c0, c1, c2)
/// is stationary, else null. qa = c0 - 2 c1 + c2 is the quadratic
/// coefficient (c2 is implicit in it); the derivative
/// 2(1-t)(c1-c0) + 2t(c2-c1) vanishes at t = (c0 - c1) / qa.
/// Two precision floors: |qa| < 1e-3 means the coordinate deviates less
/// than 1.25e-4 from its chord (a turn below the sweep's precision — no
/// split), and extrema within 1e-4 of a boundary are snapped to it
/// (after a split at the exact vertex, f32 rounding can leave the vertex
/// marginally inside a half; the t-error is amplified by 1/|qa|).
fn extremumT(qa: f32, c0: f32, c1: f32) ?f32 {
    if (@abs(qa) < 1e-3) return null;
    const t = (c0 - c1) / qa;
    if (t > 1e-4 and t < 1.0 - 1e-4) return t;
    return null;
}

/// Append `piece` to `pieces`, splitting it at its y-extremum first (if
/// any); returns the new count.
fn appendMonoPiece(pieces: *[4]QuadCurve, n: u8, piece: QuadCurve) u8 {
    const qa_y = piece.p0[1] - 2.0 * piece.p1[1] + piece.p2[1];
    if (extremumT(qa_y, piece.p0[1], piece.p1[1])) |t| {
        const parts = splitAt(piece, t);
        pieces[n] = parts[0];
        pieces[n + 1] = parts[1];
        return n + 2;
    }
    pieces[n] = piece;
    return n + 1;
}

/// Splits `curve` into pieces that are each monotonic in both x and y, which
/// is what makes the single-root intersections in the sweep exact.
///
/// A curve that turns inside a pixel window is split at each interior
/// coordinate extremum, so the result is one piece when `curve` is already
/// monotonic and at most 4 otherwise. Direction (`p0` to `p2`) is preserved
/// and consecutive pieces share their split point exactly, so the pieces
/// together trace the original curve.
///
/// A turn shallower than the sweep's precision is not split, so a piece can
/// keep an extremum whose coordinate deviates from its chord by a fraction
/// too small to affect the result.
pub fn monotonicize(curve: QuadCurve) MonoSplit {
    var result: MonoSplit = undefined;
    result.n = 0;
    const qa_x = curve.p0[0] - 2.0 * curve.p1[0] + curve.p2[0];
    if (extremumT(qa_x, curve.p0[0], curve.p1[0])) |t| {
        const parts = splitAt(curve, t);
        result.n = appendMonoPiece(&result.pieces, result.n, parts[0]);
        result.n = appendMonoPiece(&result.pieces, result.n, parts[1]);
    } else {
        result.n = appendMonoPiece(&result.pieces, result.n, curve);
    }
    return result;
}

// ── scalar core (reference) ───────────────────────────

/// Per-pixel sweep of one curve against the 1x1 window at
/// (offset_x, offset_y). The reference implementation; the vector core
/// must reproduce it bit-for-bit per lane.
fn scanlineSweepScalar(offset_x: f32, offset_y: f32, c: QuadCurve) f32 {
    const p0 = c.p0;
    const p1 = c.p1;
    const p2 = c.p2;
    if (@max(p0[1], p2[1]) <= offset_y or @min(p0[1], p2[1]) >= offset_y + size_y) return 0;

    const dx = p2[0] - p0[0];
    const dy = p2[1] - p0[1];
    const q0 = [2]f32{ p0[0] - offset_x, p0[1] - offset_y };
    const q1 = [2]f32{ p1[0] - offset_x, p1[1] - offset_y };
    const q2 = [2]f32{ p2[0] - offset_x, p2[1] - offset_y };

    // Vertical-line fast path. The strip between the edge and the window's
    // right edge is CLIPPED to the window (`max(q0[0], 0)`): an edge left
    // of the window covers the whole window, never the region beyond it —
    // without the clip, a closed contour's vertical edges smear their area
    // into every window right of them (phantom full-width rows).
    if (q0[0] == q1[0] and q0[0] == q2[0]) {
        if (q0[0] >= size_x) return 0;
        const top = @min(@max(q0[1], q2[1]), size_y);
        const bottom = @max(@min(q0[1], q2[1]), 0);
        return sign(f32, dy) * (size_x - @max(q0[0], 0)) * (top - bottom);
    }

    // Y-intersections.
    const qa_y = q0[1] + q2[1] - 2.0 * q1[1];
    const bt = intersectMonotonic(f32, qa_y, q0[1], q1[1], q2[1], 0);
    const tt = intersectMonotonic(f32, qa_y, q0[1], q1[1], q2[1], size_y);
    const v_min_t = if (dy > 0) bt else tt;
    const v_max_t = if (dy > 0) tt else bt;
    const v_min_t_c = clamp01(f32, v_min_t);
    const v_max_t_c = clamp01(f32, v_max_t);
    const v_min_x = evalBez(f32, q0[0], q1[0], q2[0], v_min_t_c);
    const v_min_y = evalBez(f32, q0[1], q1[1], q2[1], v_min_t_c);
    const v_max_x = evalBez(f32, q0[0], q1[0], q2[0], v_max_t_c);
    const v_max_y = evalBez(f32, q0[1], q1[1], q2[1], v_max_t_c);

    // Curve entirely left of the window, or entirely right of it.
    if (@max(v_min_x, v_max_x) <= 0) return (v_max_y - v_min_y) * size_x;
    if (@min(v_min_x, v_max_x) >= size_x) return 0;

    // X-intersections.
    const qa_x = q0[0] + q2[0] - 2.0 * q1[0];
    const h_min_t = if (dx > 0)
        hCheck(f32, qa_x, q0[0], q1[0], q2[0], q0[0], q2[0], 0, 0)
    else
        hCheck(f32, qa_x, q0[0], q1[0], q2[0], q2[0], q0[0], size_x, 1);
    const h_max_t = if (dx > 0)
        hCheck(f32, qa_x, q0[0], q1[0], q2[0], q0[0], q2[0], size_x, 0)
    else
        hCheck(f32, qa_x, q0[0], q1[0], q2[0], q2[0], q0[0], 0, 1);

    const min_t = clamp01(f32, @max(v_min_t, h_min_t));
    const max_t = clamp01(f32, @min(v_max_t, h_max_t));
    if (min_t >= max_t) return 0;

    const q0y = if (v_min_t >= h_min_t) v_min_y else evalBez(f32, q0[1], q1[1], q2[1], min_t);
    const q1y = if (v_max_t <= h_max_t) v_max_y else evalBez(f32, q0[1], q1[1], q2[1], max_t);

    var area: f32 = 0;
    if (min_t > 0 and dx > 0) {
        const h = if (dy > 0) q0y - @max(0, q0[1]) else @min(size_y, q0[1]) - q0y;
        area += sign(f32, dy) * h * size_x;
    }
    if (max_t < 1 and dx < 0) {
        const h = if (dy > 0) @min(size_y, q2[1]) - q1y else q1y - @max(0, q2[1]);
        area += sign(f32, dy) * h * size_x;
    }
    const h_trap = q1y - q0y;
    const f_max = bezIntX(f32, q0[0], q1[0], q2[0], q0[1], q1[1], q2[1], max_t);
    const f_min = bezIntX(f32, q0[0], q1[0], q2[0], q0[1], q1[1], q2[1], min_t);
    // Exact ∫_{min_t}^{max_t} (size_x - x(t)) y'(t) dt. The secant
    // trapezoid (size_x - (q0x+q1x)/2) * h_trap is exact only for
    // straight edges; the closed form also integrates the quadratic
    // deviation, which the trapezoid systematically under-counts.
    area += size_x * h_trap - (f_max - f_min);
    return area;
}

// ── vector core (SIMD row) ───────────────────────────

/// Row sweep: the same algorithm with a per-lane x offset. Per-curve
/// constants are computed once as scalars and broadcast; per-lane
/// conditionals compute both sides and `@select`. Bit-identical to
/// `scanlineSweepScalar` per lane.
fn scanlineSweepVec(
    comptime lane_count: usize,
    offset_xs: @Vector(lane_count, f32),
    offset_y: f32,
    c: QuadCurve,
) @Vector(lane_count, f32) {
    const Vec = @Vector(lane_count, f32);
    const zero: Vec = zeroOf(Vec);
    const one: Vec = oneOf(Vec);
    const p0 = c.p0;
    const p1 = c.p1;
    const p2 = c.p2;

    // Per-curve scalars, computed once.
    const dx = p2[0] - p0[0];
    const dy = p2[1] - p0[1];
    const y_disjoint = @max(p0[1], p2[1]) <= offset_y or @min(p0[1], p2[1]) >= offset_y + size_y;

    // Shifted control points: x per-lane, y per-curve.
    const x0: Vec = fromF32(Vec, p0[0]) - offset_xs;
    const x1: Vec = fromF32(Vec, p1[0]) - offset_xs;
    const x2: Vec = fromF32(Vec, p2[0]) - offset_xs;
    const y0 = p0[1] - offset_y;
    const y1 = p1[1] - offset_y;
    const y2 = p2[1] - offset_y;

    // Vertical-line fast path. The predicate is uniform across lanes but
    // is computed per-lane on shifted x's to mirror the scalar exactly.
    const vertical = (x0 == x1) & (x0 == x2);
    const vert_h = @min(@max(y0, y2), size_y) - @max(@min(y0, y2), 0);
    const vert_valid = x0 < one;
    // The strip between the edge and the window's right edge is clipped to
    // the window (mirrors the scalar fast path — see scanlineSweepScalar).
    const vert_formula: Vec = (fromF32(Vec, sign(f32, dy)) * (one - @max(x0, zero))) * fromF32(Vec, vert_h);
    const vert_result = sel(Vec, vert_valid, vert_formula, zero);

    // Y-intersections.
    const qa_y = y0 + y2 - 2.0 * y1;
    const bt = intersectMonotonic(f32, qa_y, y0, y1, y2, 0);
    const tt = intersectMonotonic(f32, qa_y, y0, y1, y2, size_y);
    const v_min_t = if (dy > 0) bt else tt;
    const v_max_t = if (dy > 0) tt else bt;
    const v_min_t_c = clamp01(f32, v_min_t);
    const v_max_t_c = clamp01(f32, v_max_t);
    const v_min_x: Vec = evalBez(Vec, x0, x1, x2, fromF32(Vec, v_min_t_c));
    const v_max_x: Vec = evalBez(Vec, x0, x1, x2, fromF32(Vec, v_max_t_c));
    const v_min_y = evalBez(f32, y0, y1, y2, v_min_t_c);
    const v_max_y = evalBez(f32, y0, y1, y2, v_max_t_c);

    // Curve entirely left of the window, or entirely right of it.
    const left_out = @max(v_min_x, v_max_x) <= zero;
    const right_out = @min(v_min_x, v_max_x) >= fromF32(Vec, size_x);
    const left_val: Vec = fromF32(Vec, (v_max_y - v_min_y) * size_x);

    // X-intersections.
    const qa_x: Vec = x0 + x2 - fromF32(Vec, 2.0) * x1;
    const h_min_t = if (dx > 0)
        hCheck(Vec, qa_x, x0, x1, x2, x0, x2, 0, 0)
    else
        hCheck(Vec, qa_x, x0, x1, x2, x2, x0, size_x, 1);
    const h_max_t = if (dx > 0)
        hCheck(Vec, qa_x, x0, x1, x2, x0, x2, size_x, 0)
    else
        hCheck(Vec, qa_x, x0, x1, x2, x2, x0, 0, 1);

    const v_min_t_s: Vec = fromF32(Vec, v_min_t);
    const v_max_t_s: Vec = fromF32(Vec, v_max_t);
    const min_t = clamp01(Vec, @max(v_min_t_s, h_min_t));
    const max_t = clamp01(Vec, @min(v_max_t_s, h_max_t));
    const overlap = min_t < max_t;

    const q0y = sel(
        Vec,
        v_min_t_s >= h_min_t,
        fromF32(Vec, v_min_y),
        evalBez(Vec, fromF32(Vec, y0), fromF32(Vec, y1), fromF32(Vec, y2), min_t),
    );
    const q1y = sel(
        Vec,
        v_max_t_s <= h_max_t,
        fromF32(Vec, v_max_y),
        evalBez(Vec, fromF32(Vec, y0), fromF32(Vec, y1), fromF32(Vec, y2), max_t),
    );

    // Side-rectangle terms. The dx/dy sign choices are per-curve
    // constants, so they are uniform scalar branches; the per-lane
    // t-clamps select branchlessly.
    const h1 = if (dy > 0)
        q0y - @max(zero, fromF32(Vec, y0))
    else
        @min(one, fromF32(Vec, y0)) - q0y;
    const add1 = fromF32(Vec, sign(f32, dy)) * h1 * one;
    var area: Vec = zero;
    if (dx > 0) area = sel(Vec, min_t > zero, zero + add1, zero);
    const h2 = if (dy > 0)
        @min(one, fromF32(Vec, y2)) - q1y
    else
        q1y - @max(zero, fromF32(Vec, y2));
    const add2 = fromF32(Vec, sign(f32, dy)) * h2 * one;
    if (dx < 0) area = sel(Vec, max_t < one, area + add2, area);
    const h_trap = q1y - q0y;
    const f_max = bezIntX(Vec, x0, x1, x2, fromF32(Vec, y0), fromF32(Vec, y1), fromF32(Vec, y2), max_t);
    const f_min = bezIntX(Vec, x0, x1, x2, fromF32(Vec, y0), fromF32(Vec, y1), fromF32(Vec, y2), min_t);
    // Exact ∫_{min_t}^{max_t} (size_x - x(t)) y'(t) dt, mirroring the
    // scalar core: the secant trapezoid under-counts curved edges.
    area += fromF32(Vec, size_x) * h_trap - (f_max - f_min);

    const general = sel(
        Vec,
        left_out,
        left_val,
        sel(Vec, right_out, zero, sel(Vec, overlap, area, zero)),
    );
    const vertical_or_general = sel(Vec, vertical, vert_result, general);
    // The y-window early-out is a per-curve constant: a uniform return.
    if (y_disjoint) return zero;
    return vertical_or_general;
}

// ── public row API ───────────────────────────────

/// Sweep `curves` into one row of pixel coverage.
///
/// `out[i]` is the covered fraction of the window with its lower-left corner
/// at `(x_start + i, y)`, summed over every curve and clamped to `[0, 1]`.
/// Every entry of `out` is overwritten, and an empty `out` is a no-op, so a
/// caller may pass any length including 0. `curves` is read-only and not
/// retained.
///
/// Every curve is swept as `monotonicize` pieces, because a curve that turns
/// inside a pixel window breaks the single-root intersections the sweep
/// relies on. Curves whose control hull misses the row's y-window are skipped
/// once for the whole row; the rest are swept `lanes` pixels at a time, the
/// last chunk partially filled.
pub fn coverageRow(curves: []const QuadCurve, y: f32, x_start: f32, out: []f32) void {
    @memset(out, 0);
    for (curves) |c| {
        // Row-level early-out: the y-window is disjoint from the curve.
        // The control point can bulge far beyond the endpoints (a
        // non-monotonic y), so bound by all three control points — a
        // bezier lies in its control hull.
        const y_hi = @max(c.p0[1], @max(c.p1[1], c.p2[1]));
        const y_lo = @min(c.p0[1], @min(c.p1[1], c.p2[1]));
        if (y_hi <= y or y_lo >= y + size_y) continue;
        // Non-monotonic quadratics (a curve doubling back inside a pixel
        // window) make the single-root intersections wrong: sweep the
        // monotonic pieces instead. Fixed [4] stack array — no allocation.
        const mono = monotonicize(c);
        var pi: u8 = 0;
        while (pi < mono.n) : (pi += 1) {
            const piece = mono.pieces[pi];
            var i: usize = 0;
            while (i < out.len) : (i += lanes) {
                const n = @min(lanes, out.len - i);
                var offsets: [lanes]f32 = undefined;
                var k: usize = 0;
                while (k < n) : (k += 1) {
                    offsets[k] = x_start + @as(f32, @floatCast(@as(f64, @floatFromInt(i + k))));
                }
                // Defined fill for the discarded tail lanes.
                while (k < lanes) : (k += 1) {
                    if (n > 0) offsets[k] = offsets[n - 1];
                }
                const row: [lanes]f32 = scanlineSweepVec(lanes, offsets, y, piece);
                k = 0;
                while (k < n) : (k += 1) {
                    out[i + k] += row[k];
                }
            }
        }
    }
    for (out) |*v| {
        v.* = clamp01(f32, v.*);
    }
}

// ── fast row (step + corrections) ─────────────────────

/// Piece batch for the SIMD hit test: 128 × 24 B = 3 KB of stack. The
/// practical glyph case is ≤ 32 curves × 4 pieces; larger sets fall back
/// to a scalar piece loop with identical math.
const batch_cap = 128;

/// Max row width for the stack difference array (2049 × 4 B = 8 KB of
/// stack). Wider rows fall back to `coverageRow` — the exact sweep, the
/// zero-alloc bound on the stack diff.
const diff_cap = 2048;

/// Clamped float-to-index cast: `f` pulled into `[0, hi]` and converted to
/// a pixel index. The clamp is what keeps the cast in range for the
/// pathological extents `f` and `hi` can hold before the caller's float
/// compares narrow them.
inline fn clampedIndex(f: f32, hi: f32) usize {
    return @intFromFloat(std.math.clamp(f, 0.0, hi));
}

/// One hit piece's row contribution: the `dir * span` STEP for every
/// pixel entirely right of the piece's x-extent (a single difference-array
/// add at i_step), plus the exact analytic sweep value for the few pixels
/// whose 1x1 windows overlap that extent (written straight into `out`).
/// The caller has already hit-tested the piece against the row's y-window.
inline fn addPiece(diff: []f32, out: []f32, piece: QuadCurve, y: f32, x_start: f32) void {
    const p0 = piece.p0;
    const p1 = piece.p1;
    const p2 = piece.p2;

    // The piece's y-span INSIDE the row's y-slice, from the same clamped
    // intersection params the sweep uses: the sweep's entirely-left
    // branch returns (v_max_y - v_min_y) with v_min_y/v_max_y evaluated
    // AT these t's — reproducing it bit-identically makes the step exact
    // even for pieces with an interior y-extremum below the monotonicize
    // split floor (|qa| < 1e-3, deviation up to 2.5e-4: the endpoint
    // span min(y+1, y_hi) - max(y, y_lo) misses the bulge).
    const qa_y = p0[1] + p2[1] - 2.0 * p1[1];
    const t_lo = clamp01(f32, intersectMonotonic(f32, qa_y, p0[1], p1[1], p2[1], y));
    const t_hi = clamp01(f32, intersectMonotonic(f32, qa_y, p0[1], p1[1], p2[1], y + 1.0));
    // evalBez at the clamped bounds is exactly the endpoint value
    // (evalBez(…, 0) == p0, evalBez(…, 1) == p2, bit-identical — the
    // sweep evaluates at the same clamped t's, so the shortcut never
    // diverges). Full-row-crossing pieces clamp both ends (t_lo == 0,
    // t_hi == 1): all four evals collapse to endpoints — the dominant
    // case in dense glyph rows.
    const y_at_lo = if (t_lo == 0.0) p0[1] else evalBez(f32, p0[1], p1[1], p2[1], t_lo);
    const y_at_hi = if (t_hi == 1.0) p2[1] else evalBez(f32, p0[1], p1[1], p2[1], t_hi);
    const dir = sign(f32, p2[1] - p0[1]);
    const step_val = dir * (y_at_hi - y_at_lo);

    // The piece's x-extent inside the row's y-slice: the two y-window
    // intersection parameters (clamped), evaluated in x.
    const x_lo = if (t_lo == 0.0) p0[0] else evalBez(f32, p0[0], p1[0], p2[0], t_lo);
    const x_hi = if (t_hi == 1.0) p2[0] else evalBez(f32, p0[0], p1[0], p2[0], t_hi);
    const extent_min = @min(x_lo, x_hi);
    const extent_max = @max(x_lo, x_hi);

    // Step. Pixel i's window is [x_start + i, x_start + i + 1); the sweep
    // returns dir * span exactly when x_start + i >= extent_max, i.e.
    // i >= i_step. @ceil partitions exactly — the sweep's `<=` includes
    // the touch, so the extent_max-integer pixel is stepped too.
    //
    // The corrections are capped at i_step - 1 rather than run through
    // ceil(extent_max): a pixel at ceil(extent_max) would then take BOTH the
    // step and a correction that computes the same dir * span, double-counting
    // every non-integer extent. Capping keeps the integer boundaries exact
    // and the fractional x_start values correct.
    const i_step = @ceil(extent_max - x_start);
    // coverageRowFast falls back above diff_cap, so out.len is small
    // enough for the f32 conversion to be exact.
    const out_len_f: f32 = @floatFromInt(@min(out.len, diff_cap));
    if (i_step <= 0) {
        diff[0] += step_val; // extent left of the whole window
    } else if (i_step <= out_len_f) {
        const i_step_i: usize = clampedIndex(i_step, out_len_f);
        diff[i_step_i] += step_val;
    }
    // else: extent right of the whole window — nothing to step.

    // Corrections: pixels whose windows overlap the extent get the exact
    // sweep value. The usual extent is 1–2 pixels: scalar sweeps there —
    // a 16-lane scanlineSweepVec costs ~15 vector ops regardless of how
    // many lanes are live, so per-piece vector calls lose to scalar
    // branches (the sweep path's per-piece vector call is the whole cost
    // fast must beat). Wide extents (shallow, near-horizontal pieces)
    // still use the vector path — one call amortizes over many pixels.
    // clampedIndex clamps before the cast, so pathological extents cannot
    // overflow it; the p_lo > p_hi guard covers i_step <= 0 (p_hi
    // negative) and extents right of the window (p_lo past the end).
    const p_lo_f = @max(@floor(extent_min - x_start), 0.0);
    const p_hi_f = @min(i_step - 1.0, out_len_f - 1.0);
    if (p_lo_f > p_hi_f) return;
    const p_lo: usize = clampedIndex(p_lo_f, out_len_f - 1.0);
    const p_hi: usize = clampedIndex(p_hi_f, out_len_f - 1.0);
    // One @Vector(4) sweep call per chunk: a 4-wide register runs the
    // whole general path in ~half the ops of the 16-lane call (and the
    // scalar path serializes the same math with branchy sqrts — ~3x more
    // cycles for the usual 1-2 extent pixels).
    var i: usize = p_lo;
    while (i <= p_hi) : (i += 4) {
        const n = @min(4, p_hi - i + 1);
        var offsets: [4]f32 = undefined;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            offsets[k] = x_start + @as(f32, @floatCast(@as(f64, @floatFromInt(i + k))));
        }
        // Defined fill for the discarded tail lanes.
        while (k < 4) : (k += 1) {
            if (n > 0) offsets[k] = offsets[n - 1];
        }
        const row: [4]f32 = scanlineSweepVec(4, offsets, y, piece);
        k = 0;
        while (k < n) : (k += 1) {
            out[i + k] += row[k];
        }
    }
}

/// `coverageRow` through a faster row-intersection scheme, with the same
/// result up to floating-point accumulation order.
///
/// A monotonic piece contributes a STEP to a row — zero left of its x-extent
/// and `sign(dy) × y-span` right of it — and only the one or two pixels its
/// extent overlaps need the analytic sweep. The sweep's entirely-left branch
/// is exactly that step, so the difference array's prefix sum reproduces it,
/// and `scanlineSweepVec` supplies the extent pixels. Each piece's step sits
/// past its own corrected pixels, so nothing is counted twice, and pieces
/// add.
///
/// Pieces are hit-tested against the row's y-window in `lanes`-wide vectors;
/// more than `batch_cap / 4` curves (32) take a scalar loop with the same
/// math, and a row wider than `diff_cap` falls back to `coverageRow`
/// outright. Like `coverageRow` this overwrites every entry of `out`,
/// accepts an empty `out`, allocates nothing and retains nothing.
pub fn coverageRowFast(curves: []const QuadCurve, y: f32, x_start: f32, out: []f32) void {
    // Runtime checks are off for this kernel alone. The panic blocks a
    // checked cast or slice would leave inlined code distort optimization
    // enough to cost more than the scheme saves, and every index below is
    // unreachable by construction because an adjacent explicit comparison
    // already excludes it:
    //   - diff has out.len + 1 entries: the branch above rejects
    //     out.len > diff_cap, so the addition cannot wrap;
    //   - batch[n_pieces]: n_pieces <= curves.len * 4 <= batch_cap, because
    //     the fallback below compares against batch_cap / 4 by division,
    //     so the threshold itself cannot overflow;
    //   - mono.pieces[0..n]: monotonicize yields at most 4;
    //   - diff[i_step_i] and the correction pixel range: clampedIndex clamps
    //     before the cast, and the float comparisons in addPiece narrow the
    //     value into its clamp range first.
    //
    // The published contract — any `out.len`, no allocation — is unaffected;
    // every other function in the package keeps its checks.
    @setRuntimeSafety(false);
    if (out.len > diff_cap) {
        coverageRow(curves, y, x_start, out);
        return;
    }
    @memset(out, 0);
    var diff: [diff_cap + 1]f32 = undefined;
    // Only the live slice (out.len + 1 entries) is zeroed — rows are
    // typically ~10 px, and clearing the whole 2049-entry stack array per
    // row would dominate the raster cost.
    const diff_view = diff[0 .. out.len + 1];
    @memset(diff_view, 0);

    if (curves.len > batch_cap / 4) {
        // Scalar fallback for very large curve sets: identical math, one
        // monotonicized piece at a time.
        for (curves) |c| {
            // Curve-level early-out (mirrors coverageRow): the control
            // hull bounds the curve, so a disjoint hull skips the whole
            // monotonicize + piece loop.
            const c_y_hi = @max(c.p0[1], @max(c.p1[1], c.p2[1]));
            const c_y_lo = @min(c.p0[1], @min(c.p1[1], c.p2[1]));
            if (c_y_hi <= y or c_y_lo >= y + size_y) continue;
            const mono = monotonicize(c);
            var pi: u8 = 0;
            while (pi < mono.n) : (pi += 1) {
                const piece = mono.pieces[pi];
                const y_lo = @min(piece.p0[1], piece.p2[1]);
                const y_hi = @max(piece.p0[1], piece.p2[1]);
                if (y_hi <= y or y_lo >= y + 1.0) continue;
                addPiece(diff_view, out, piece, y, x_start);
            }
        }
    } else {
        // Batch path: monotonicize the surviving curves once, then SIMD
        // hit-test the (y_lo, y_hi) endpoint bounds in `lanes`-wide
        // vectors. The test is identical to scanlineSweepScalar's
        // disjoint early-out.
        var batch: [batch_cap]QuadCurve = undefined;
        var n_pieces: usize = 0;
        for (curves) |c| {
            const c_y_hi = @max(c.p0[1], @max(c.p1[1], c.p2[1]));
            const c_y_lo = @min(c.p0[1], @min(c.p1[1], c.p2[1]));
            if (c_y_hi <= y or c_y_lo >= y + size_y) continue;
            const mono = monotonicize(c);
            for (mono.pieces[0..mono.n]) |piece| {
                batch[n_pieces] = piece;
                n_pieces += 1;
            }
        }
        const y_splat = fromF32(@Vector(lanes, f32), y);
        const y1_splat = fromF32(@Vector(lanes, f32), y + 1.0);
        var pi: usize = 0;
        while (pi < n_pieces) : (pi += lanes) {
            const m = @min(lanes, n_pieces - pi);
            // Tail lanes are filled with non-matching bounds so the mask
            // never selects them. Vectors are built from arrays (element
            // writes need comptime indices in 0.16).
            var y_lo_arr: [lanes]f32 = @splat(1e30);
            var y_hi_arr: [lanes]f32 = @splat(-1e30);
            for (0..m) |k| {
                const piece = batch[pi + k];
                y_lo_arr[k] = @min(piece.p0[1], piece.p2[1]);
                y_hi_arr[k] = @max(piece.p0[1], piece.p2[1]);
            }
            const y_lo_vec: @Vector(lanes, f32) = y_lo_arr;
            const y_hi_vec: @Vector(lanes, f32) = y_hi_arr;
            const mask: @Vector(lanes, bool) = (y_hi_vec > y_splat) & (y_lo_vec < y1_splat);
            const mask_arr: [lanes]bool = mask;
            for (0..m) |k| {
                if (mask_arr[k]) addPiece(diff_view, out, batch[pi + k], y, x_start);
            }
        }
    }

    // Prefix-sum the steps into the corrections, then clamp to [0, 1].
    // diff[out.len] only ever holds the i_step == out.len add — the
    // prefix loop never consumes it.
    var acc: f32 = 0;
    for (out, 0..) |*v, i| {
        acc += diff[i];
        v.* = clamp01(f32, v.* + acc);
    }
}

// ── tests ─────────────────────────────────

/// xorshift32 PRNG for the property tests.
fn xorshift32(state: *u32) u32 {
    var s = state.*;
    s ^= s << 13;
    s ^= s >> 17;
    s ^= s << 5;
    state.* = s;
    return s;
}

/// Uniform f32 in [lo, hi).
fn randF32(state: *u32, lo: f32, hi: f32) f32 {
    const u = xorshift32(state);
    const t = @as(f32, @floatCast(@as(f64, @floatFromInt(u >> 8)))) / @as(f32, 0x0100_0000);
    return lo + (hi - lo) * t;
}

/// A coordinate strictly outside [lo, hi]: used as a control-point
/// coordinate it forces an interior extremum in that axis.
fn outside(state: *u32, lo: f32, hi: f32) f32 {
    const lo2 = @min(lo, hi);
    const hi2 = @max(lo, hi);
    return if (xorshift32(state) & 1 == 0)
        hi2 + randF32(state, 0.1, 2.0)
    else
        lo2 - randF32(state, 0.1, 2.0);
}

/// Random curve; `kind` rotates through vertical / straight / horizontal
/// / general / non-monotonic to exercise every branch of the sweep. The
/// non-monotonic kind puts p1 strictly outside the p0/p2 x- and y-ranges
/// so the curve turns in both coordinates (monotonicize must split it).
fn randCurve(state: *u32, kind: u32) QuadCurve {
    const x0 = randF32(state, -2, 3);
    const x1 = randF32(state, -2, 3);
    const x2 = randF32(state, -2, 3);
    const y0 = randF32(state, -1.5, 2.5);
    const y1 = randF32(state, -1.5, 2.5);
    const y2 = randF32(state, -1.5, 2.5);
    return switch (kind % 5) {
        0 => .{ .p0 = .{ x0, y0 }, .p1 = .{ x0, y1 }, .p2 = .{ x0, y2 } },
        1 => .{ .p0 = .{ x0, y0 }, .p1 = .{ 0.5 * (x0 + x2), 0.5 * (y0 + y2) }, .p2 = .{ x2, y2 } },
        2 => .{ .p0 = .{ x0, y0 }, .p1 = .{ x1, y0 }, .p2 = .{ x2, y0 } },
        3 => .{ .p0 = .{ x0, y0 }, .p1 = .{ x1, y1 }, .p2 = .{ x2, y2 } },
        else => .{
            .p0 = .{ x0, y0 },
            .p1 = .{ outside(state, x0, x2), outside(state, y0, y2) },
            .p2 = .{ x2, y2 },
        },
    };
}

test "coverageRow and coverageRowFast accept an empty row" {
    // The published contract is "any `out.len`", so a caller with no pixels
    // to write gets a no-op rather than a panic or a partial write.
    const curves = [_]QuadCurve{
        .{ .p0 = .{ 0, 0 }, .p1 = .{ 0, 0.5 }, .p2 = .{ 0, 1 } },
        .{ .p0 = .{ 0, 1 }, .p1 = .{ 0.5, 1 }, .p2 = .{ 1, 1 } },
    };
    var empty: [0]f32 = .{};
    coverageRow(&curves, 0.5, 0, &empty);
    coverageRowFast(&curves, 0.5, 0, &empty);
}

test "unit square outline row" {
    // Closed unit square [0,1]^2, interior to the right of travel. At
    // scanline y = 0.5 the square covers the window's lower half
    // ([0.5, 1) of [0.5, 1.5)), so the LOCAL coverage is 0.5 in column 0
    // (the square's span) and 0 beyond it. The vertical fast path clips
    // its strip to the window: an edge left of the window covers the
    // whole window (never the region beyond it), so the left/right edge
    // strips cancel outside the square. The row is [0.5, 0, 0, 0].
    const curves = [_]QuadCurve{
        .{ .p0 = .{ 0, 0 }, .p1 = .{ 0, 0.5 }, .p2 = .{ 0, 1 } },
        .{ .p0 = .{ 0, 1 }, .p1 = .{ 0.5, 1 }, .p2 = .{ 1, 1 } },
        .{ .p0 = .{ 1, 1 }, .p1 = .{ 1, 0.5 }, .p2 = .{ 1, 0 } },
        .{ .p0 = .{ 1, 0 }, .p1 = .{ 0.5, 0 }, .p2 = .{ 0, 0 } },
    };
    var out: [4]f32 = undefined;
    coverageRow(&curves, 0.5, 0, &out);
    const expected = [_]f32{ 0.5, 0, 0, 0 };
    for (expected, out) |e, a| {
        try testing.expectApproxEqAbs(e, a, 1e-6);
    }
}

test "vertical line fast path" {
    // A vertical edge at x = 0.5 spanning the pixel window y in
    // [0.5, 1.5] sweeps the half of the pixel to its right: 0.5. The
    // fast path extends (1 - x0) * h to the right of the edge, so the
    // remaining pixels saturate at the [0, 1] clamp.
    const curve: QuadCurve = .{ .p0 = .{ 0.5, 0.5 }, .p1 = .{ 0.5, 1 }, .p2 = .{ 0.5, 1.5 } };
    var out: [4]f32 = undefined;
    coverageRow(&[_]QuadCurve{curve}, 0.5, 0, &out);
    try testing.expectApproxEqAbs(0.5, out[0], 1e-6);
    try testing.expectApproxEqAbs(1.0, out[1], 1e-6);
    try testing.expectApproxEqAbs(1.0, out[2], 1e-6);
    try testing.expectApproxEqAbs(1.0, out[3], 1e-6);
}

test "triangle coverage matches analytic band area" {
    // Closed triangle (0,0)-(1,0)-(0.5,1), interior to the right of
    // travel; the slanted edges take the general (non-vertical) path.
    // Scanline y = 0.25: the band [0.25, 1.25] cuts the triangle at
    // height 0.75, analytic area integral(1 - y, y = 0.25..1) = 0.28125.
    // The whole cross-section (x in [0.125, 0.875]) lies in pixel 0.
    const curves = [_]QuadCurve{
        .{ .p0 = .{ 0, 0 }, .p1 = .{ 0.25, 0.5 }, .p2 = .{ 0.5, 1 } },
        .{ .p0 = .{ 0.5, 1 }, .p1 = .{ 0.75, 0.5 }, .p2 = .{ 1, 0 } },
        .{ .p0 = .{ 1, 0 }, .p1 = .{ 0.5, 0 }, .p2 = .{ 0, 0 } },
    };
    var out: [8]f32 = undefined;
    coverageRow(&curves, 0.25, 0, &out);
    var sum: f32 = 0;
    for (out) |v| sum += v;
    // ∫_{0.25}^{1} (1 - y) dy = 0.75 - 0.46875 = 0.28125 (exact in f32).
    const analytic: f32 = 0.28125;
    try testing.expectApproxEqAbs(analytic, sum, 1e-5);
    try testing.expectApproxEqAbs(analytic, out[0], 1e-5);
    for (out[1..]) |v| {
        try testing.expectApproxEqAbs(0, v, 1e-6);
    }
}

test "scalar and vector sweeps are bit-identical" {
    var state: u32 = 0x9E3779B9;
    var it: usize = 0;
    while (it < 512) : (it += 1) {
        const c = randCurve(&state, xorshift32(&state));
        const oy = randF32(&state, -1, 1);
        const x_start = randF32(&state, -2, 2);
        var offsets: [lanes]f32 = undefined;
        for (0..lanes) |k| {
            offsets[k] = x_start + @as(f32, @floatCast(@as(f64, @floatFromInt(k))));
        }
        // Raw curve (every branch, including the non-monotonic kinds)...
        const v: [lanes]f32 = scanlineSweepVec(lanes, offsets, oy, c);
        for (0..lanes) |k| {
            const s = scanlineSweepScalar(offsets[k], oy, c);
            try testing.expectEqual(@as(u32, @bitCast(s)), @as(u32, @bitCast(v[k])));
        }
        // ...and each monotonic piece (the exact coverageRow path).
        const mono = monotonicize(c);
        for (mono.pieces[0..mono.n]) |piece| {
            const vp: [lanes]f32 = scanlineSweepVec(lanes, offsets, oy, piece);
            for (0..lanes) |k| {
                const s = scanlineSweepScalar(offsets[k], oy, piece);
                try testing.expectEqual(@as(u32, @bitCast(s)), @as(u32, @bitCast(vp[k])));
            }
        }
    }
}

test "coverageRow matches per-pixel scalar accumulation" {
    var state: u32 = 0xABCD1234;
    var curves: [24]QuadCurve = undefined;
    for (&curves, 0..) |*c, k| {
        c.* = randCurve(&state, @intCast(k));
    }
    const y = randF32(&state, -1, 1);
    const x_start = randF32(&state, -2, 1);
    // 13 pixels exercises the 8-lane tail; the reference accumulates the
    // monotonic pieces in the same order as coverageRow (which now
    // splits every curve), so the bits must match.
    const n = 13;
    var expected: [n]f32 = undefined;
    for (0..n) |i| {
        var acc: f32 = 0;
        for (curves) |c| {
            const mono = monotonicize(c);
            for (mono.pieces[0..mono.n]) |piece| {
                acc += scanlineSweepScalar(
                    x_start + @as(f32, @floatCast(@as(f64, @floatFromInt(i)))),
                    y,
                    piece,
                );
            }
        }
        expected[i] = clamp01(f32, acc);
    }
    var out: [n]f32 = undefined;
    coverageRow(&curves, y, x_start, &out);
    for (expected, out) |e, a| {
        try testing.expectEqual(@as(u32, @bitCast(e)), @as(u32, @bitCast(a)));
    }
    // Single-pixel row (tail-only chunk).
    var single: [1]f32 = undefined;
    coverageRow(&curves, y, x_start, &single);
    try testing.expectEqual(@as(u32, @bitCast(expected[0])), @as(u32, @bitCast(single[0])));
}

test "monotonicize keeps monotonic curves single, splits the rest" {
    // Straight-line quadratics (midpoint control points) and the
    // vertical/horizontal branches have no interior extrema: splitting
    // is a no-op (n = 1, the curve returned unchanged).
    const monotonic = [_]QuadCurve{
        .{ .p0 = .{ 0, 0 }, .p1 = .{ 0, 0.5 }, .p2 = .{ 0, 1 } },
        .{ .p0 = .{ 0, 1 }, .p1 = .{ 0.5, 1 }, .p2 = .{ 1, 1 } },
        .{ .p0 = .{ 1, 1 }, .p1 = .{ 1, 0.5 }, .p2 = .{ 1, 0 } },
        .{ .p0 = .{ 1, 0 }, .p1 = .{ 0.5, 0 }, .p2 = .{ 0, 0 } },
        .{ .p0 = .{ 0.5, 0.5 }, .p1 = .{ 0.5, 1 }, .p2 = .{ 0.5, 1.5 } },
        .{ .p0 = .{ 0, 0 }, .p1 = .{ 0.25, 0.5 }, .p2 = .{ 0.5, 1 } },
    };
    for (monotonic) |c| {
        const m = monotonicize(c);
        try testing.expectEqual(@as(u8, 1), m.n);
        try testing.expectEqual(c.p0, m.pieces[0].p0);
        try testing.expectEqual(c.p1, m.pieces[0].p1);
        try testing.expectEqual(c.p2, m.pieces[0].p2);
    }
    // The arch y = 4x(1-x) turns in y at t = 0.5: 2 pieces, direction
    // preserved, split point shared exactly.
    const arch: QuadCurve = .{ .p0 = .{ 0, 0 }, .p1 = .{ 0.5, 2 }, .p2 = .{ 1, 0 } };
    const m = monotonicize(arch);
    try testing.expectEqual(@as(u8, 2), m.n);
    try testing.expectEqual(arch.p0, m.pieces[0].p0);
    try testing.expectEqual(arch.p2, m.pieces[1].p2);
    try testing.expectEqual(m.pieces[0].p2, m.pieces[1].p0);
}

test "forced non-monotonic curves split into monotonic pieces" {
    var state: u32 = 0xC0FFEE;
    var it: usize = 0;
    while (it < 256) : (it += 1) {
        const c = randCurve(&state, 4);
        const m = monotonicize(c);
        try testing.expect(m.n >= 2);
        try testing.expect(m.n <= 4);
        try testing.expectEqual(c.p0, m.pieces[0].p0);
        try testing.expectEqual(c.p2, m.pieces[m.n - 1].p2);
        // Every piece must be monotonic in x and y. The check is
        // geometric, not parametric: a split at the exact vertex can
        // leave the vertex marginally inside a half (f32 rounding, with
        // the t-error amplified by 1/|qa| on nearly-straight pieces),
        // but then the coordinate's deviation from its chord,
        // |qa| t(1-t)/2, is far below 2e-4 — the sweep's precision.
        for (m.pieces[0..m.n]) |p| {
            const qa_x = p.p0[0] - 2.0 * p.p1[0] + p.p2[0];
            if (extremumT(qa_x, p.p0[0], p.p1[0])) |t| {
                try testing.expect(@abs(qa_x) * t * (1.0 - t) * 0.5 < 2e-4);
            }
            const qa_y = p.p0[1] - 2.0 * p.p1[1] + p.p2[1];
            if (extremumT(qa_y, p.p0[1], p.p1[1])) |t| {
                try testing.expect(@abs(qa_y) * t * (1.0 - t) * 0.5 < 2e-4);
            }
        }
    }
}

test "winding: interior to the right (CW in Y-up) fills, CCW clamps to 0" {
    // The sweep sums signed area with the interior to the RIGHT of
    // travel: in Y-up that is a clockwise outer contour. Font outlines
    // in the PostScript/CFF convention (outer CCW) are reversed by the
    // caller (formula_tui.zig) before reaching coverageRow — this test
    // pins the sweep's convention end to end.
    // CW square (0,0)->(0,2)->(2,2)->(2,0): the pixel window
    // [0.5, 1.5]^2 lies strictly inside, so coverage = 1.
    const cw = [_]QuadCurve{
        .{ .p0 = .{ 0, 0 }, .p1 = .{ 0, 1 }, .p2 = .{ 0, 2 } },
        .{ .p0 = .{ 0, 2 }, .p1 = .{ 1, 2 }, .p2 = .{ 2, 2 } },
        .{ .p0 = .{ 2, 2 }, .p1 = .{ 2, 1 }, .p2 = .{ 2, 0 } },
        .{ .p0 = .{ 2, 0 }, .p1 = .{ 1, 0 }, .p2 = .{ 0, 0 } },
    };
    var out: [1]f32 = undefined;
    coverageRow(&cw, 0.5, 0.5, &out);
    try testing.expectApproxEqAbs(1.0, out[0], 1e-6);
    // Reverse order (CCW, interior left): negative signed area clamps
    // to 0 — the window lies outside the filled region.
    const ccw = [_]QuadCurve{
        .{ .p0 = .{ 0, 0 }, .p1 = .{ 1, 0 }, .p2 = .{ 2, 0 } },
        .{ .p0 = .{ 2, 0 }, .p1 = .{ 2, 1 }, .p2 = .{ 2, 2 } },
        .{ .p0 = .{ 2, 2 }, .p1 = .{ 1, 2 }, .p2 = .{ 0, 2 } },
        .{ .p0 = .{ 0, 2 }, .p1 = .{ 0, 1 }, .p2 = .{ 0, 0 } },
    };
    coverageRow(&ccw, 0.5, 0.5, &out);
    try testing.expectApproxEqAbs(0.0, out[0], 1e-6);
}

test "winding: hole contour punches out the 'o'-glyph shape" {
    // The 'o'-glyph test shape: outer CW square plus inner CCW square.
    // The ring window [0, 1] x [1.5, 2.5] sits fully inside the outer
    // square and clear of the hole: coverage 1. The window
    // [1.5, 2.5]^2 sits fully inside the hole: the opposite winding
    // cancels the outer fill, coverage 0.
    const outer = [_]QuadCurve{
        .{ .p0 = .{ 0, 0 }, .p1 = .{ 0, 2 }, .p2 = .{ 0, 4 } },
        .{ .p0 = .{ 0, 4 }, .p1 = .{ 2, 4 }, .p2 = .{ 4, 4 } },
        .{ .p0 = .{ 4, 4 }, .p1 = .{ 4, 2 }, .p2 = .{ 4, 0 } },
        .{ .p0 = .{ 4, 0 }, .p1 = .{ 2, 0 }, .p2 = .{ 0, 0 } },
    };
    const hole = [_]QuadCurve{
        .{ .p0 = .{ 1, 1 }, .p1 = .{ 2, 1 }, .p2 = .{ 3, 1 } },
        .{ .p0 = .{ 3, 1 }, .p1 = .{ 3, 2 }, .p2 = .{ 3, 3 } },
        .{ .p0 = .{ 3, 3 }, .p1 = .{ 2, 3 }, .p2 = .{ 1, 3 } },
        .{ .p0 = .{ 1, 3 }, .p1 = .{ 1, 2 }, .p2 = .{ 1, 1 } },
    };
    const curves = outer ++ hole;
    var ring: [1]f32 = undefined;
    coverageRow(&curves, 1.5, 0, &ring);
    try testing.expectApproxEqAbs(1.0, ring[0], 1e-6);
    var center: [1]f32 = undefined;
    coverageRow(&curves, 1.5, 1.5, &center);
    try testing.expectApproxEqAbs(0.0, center[0], 1e-6);
}

test "non-monotonic parabola: exact coverage only after splitting" {
    // The arch y = 4x(1-x) drawn as the quadratic (0,0)->(0.5,2)->(1,0)
    // turns in y at t = 0.5. Sweeping the raw curve collapses both
    // y-intersections to t = 0.5 (the non-monotonic single-root bug):
    // the sweep returns 0.0 for every row. Splitting at the extremum
    // yields two monotonic pieces; the exact area under the arch in the
    // window [0, 1] x [y, y+1] is ∫_y^1 √(1-u) du = (2/3)(1-y)^(3/2):
    //   y = 0.5  -> √2/6 ≈ 0.235702
    //   y = 0.75 -> 1/12 ≈ 0.083333
    // The y = 0.5 assertion is the one that fails without splitting
    // (raw sweep: 0.0 vs 0.235702).
    const arch: QuadCurve = .{ .p0 = .{ 0, 0 }, .p1 = .{ 0.5, 2 }, .p2 = .{ 1, 0 } };
    const base: QuadCurve = .{ .p0 = .{ 1, 0 }, .p1 = .{ 0.5, 0 }, .p2 = .{ 0, 0 } };
    const curves = [_]QuadCurve{ base, arch };
    var out: [4]f32 = undefined;
    coverageRow(&curves, 0.5, 0, &out);
    try testing.expectApproxEqAbs(0.235702, out[0], 1e-4);
    coverageRow(&curves, 0.75, 0, &out);
    try testing.expectApproxEqAbs(0.083333, out[0], 1e-4);
}

// ── coverageRowFast tests ─────────────────────────

/// `coverageRowFast` must equal `coverageRow` on [y, y + 1) ×
/// [x_start, x_start + n) within 1e-4 (the accumulation order differs,
/// so exact bits are not required).
fn expectFastEqSweep(curves: []const QuadCurve, y: f32, x_start: f32, n: usize) !void {
    var fast: [64]f32 = undefined;
    var sweep: [64]f32 = undefined;
    try testing.expect(n <= fast.len);
    coverageRowFast(curves, y, x_start, fast[0..n]);
    coverageRow(curves, y, x_start, sweep[0..n]);
    for (fast[0..n], sweep[0..n]) |a, e| {
        try testing.expectApproxEqAbs(e, a, 1e-4);
    }
}

/// `expectFastEqSweep` for every integer row in [y0, y1].
fn expectRowsEq(curves: []const QuadCurve, y0: i64, y1: i64, x_start: f32, n: usize) !void {
    // Test rows are single-digit; the bound keeps the f32 conversion
    // exact instead of silently rounding an absurd row index.
    const max_row: i64 = 1 << 20;
    var y: i64 = y0;
    while (y <= y1) : (y += 1) {
        try expectFastEqSweep(curves, @floatFromInt(@max(@min(y, max_row), -max_row)), x_start, n);
    }
}

test "coverageRowFast == coverageRow on the fixed shapes" {
    // Unit square outline (from "unit square outline row"): y in [0, 1].
    const square = [_]QuadCurve{
        .{ .p0 = .{ 0, 0 }, .p1 = .{ 0, 0.5 }, .p2 = .{ 0, 1 } },
        .{ .p0 = .{ 0, 1 }, .p1 = .{ 0.5, 1 }, .p2 = .{ 1, 1 } },
        .{ .p0 = .{ 1, 1 }, .p1 = .{ 1, 0.5 }, .p2 = .{ 1, 0 } },
        .{ .p0 = .{ 1, 0 }, .p1 = .{ 0.5, 0 }, .p2 = .{ 0, 0 } },
    };
    // Main window: x-range [0, 1] plus margin. Offset windows: x_start
    // shifted ±1. Clip window: well right of the shape, small len.
    try expectRowsEq(&square, -1, 2, -1, 4);
    try expectRowsEq(&square, -1, 2, 0, 4);
    try expectRowsEq(&square, -1, 2, -2, 4);
    try expectRowsEq(&square, -1, 2, 2, 2);

    // The 'o' shape: outer CW square plus inner CCW hole (from the
    // "winding: hole contour" test): y and x in [0, 4].
    const outer = [_]QuadCurve{
        .{ .p0 = .{ 0, 0 }, .p1 = .{ 0, 2 }, .p2 = .{ 0, 4 } },
        .{ .p0 = .{ 0, 4 }, .p1 = .{ 2, 4 }, .p2 = .{ 4, 4 } },
        .{ .p0 = .{ 4, 4 }, .p1 = .{ 4, 2 }, .p2 = .{ 4, 0 } },
        .{ .p0 = .{ 4, 0 }, .p1 = .{ 2, 0 }, .p2 = .{ 0, 0 } },
    };
    const hole = [_]QuadCurve{
        .{ .p0 = .{ 1, 1 }, .p1 = .{ 2, 1 }, .p2 = .{ 3, 1 } },
        .{ .p0 = .{ 3, 1 }, .p1 = .{ 3, 2 }, .p2 = .{ 3, 3 } },
        .{ .p0 = .{ 3, 3 }, .p1 = .{ 2, 3 }, .p2 = .{ 1, 3 } },
        .{ .p0 = .{ 1, 3 }, .p1 = .{ 1, 2 }, .p2 = .{ 1, 1 } },
    };
    const o_shape = outer ++ hole;
    try expectRowsEq(&o_shape, -1, 5, -1, 6);
    try expectRowsEq(&o_shape, -1, 5, 0, 6);
    try expectRowsEq(&o_shape, -1, 5, -2, 6);
    try expectRowsEq(&o_shape, -1, 5, 4.5, 2);

    // The parabola arch plus its base (from "non-monotonic parabola"): y
    // in [0, 2] — monotonicize splits the arch at its extremum.
    const arch: QuadCurve = .{ .p0 = .{ 0, 0 }, .p1 = .{ 0.5, 2 }, .p2 = .{ 1, 0 } };
    const base: QuadCurve = .{ .p0 = .{ 1, 0 }, .p1 = .{ 0.5, 0 }, .p2 = .{ 0, 0 } };
    const parabola = [_]QuadCurve{ base, arch };
    try expectRowsEq(&parabola, -1, 3, -1, 4);
    try expectRowsEq(&parabola, -1, 3, 0, 4);
    try expectRowsEq(&parabola, -1, 3, -2, 4);
    try expectRowsEq(&parabola, -1, 3, 2, 2);

    // The vertical line (from "vertical line fast path"): x = 0.5,
    // y in [0.5, 1.5].
    const vertical: QuadCurve = .{ .p0 = .{ 0.5, 0.5 }, .p1 = .{ 0.5, 1 }, .p2 = .{ 0.5, 1.5 } };
    try expectRowsEq(&[_]QuadCurve{vertical}, -1, 2, -1, 4);
    try expectRowsEq(&[_]QuadCurve{vertical}, -1, 2, 0, 4);
    try expectRowsEq(&[_]QuadCurve{vertical}, -1, 2, -2, 4);
    try expectRowsEq(&[_]QuadCurve{vertical}, -1, 2, 2, 2);
}

test "coverageRowFast == coverageRow property" {
    var state: u32 = 0x9E3779B9;
    var curves: [24]QuadCurve = undefined;
    var it: usize = 0;
    while (it < 2000) : (it += 1) {
        const n = 1 + xorshift32(&state) % 24;
        for (curves[0..n], 0..) |*c, k| {
            c.* = randCurve(&state, @intCast(k)); // kind cycles 0..4
        }
        const y = randF32(&state, -1, 1);
        const x_start = randF32(&state, -2, 1);
        // [1, 17] covers the 16-lane tail chunk in the corrections.
        const len = 1 + xorshift32(&state) % 17;
        var fast: [17]f32 = undefined;
        var sweep: [17]f32 = undefined;
        coverageRowFast(curves[0..n], y, x_start, fast[0..len]);
        coverageRow(curves[0..n], y, x_start, sweep[0..len]);
        for (fast[0..len], sweep[0..len]) |a, e| {
            try testing.expectApproxEqAbs(e, a, 1e-4);
        }
    }
    // Wide window: out.len = 64 exercises the multi-chunk correction
    // loops (and stays under diff_cap, so no fallback).
    var wide_fast: [64]f32 = undefined;
    var wide_sweep: [64]f32 = undefined;
    for (&curves, 0..) |*c, k| {
        c.* = randCurve(&state, @intCast(k));
    }
    const wy = randF32(&state, -1, 1);
    const wx = randF32(&state, -2, 1);
    coverageRowFast(&curves, wy, wx, &wide_fast);
    coverageRow(&curves, wy, wx, &wide_sweep);
    for (wide_fast, wide_sweep) |a, e| {
        try testing.expectApproxEqAbs(e, a, 1e-4);
    }
    // Fractional x_start: the ceil-index scheme must stay exact for
    // windows not aligned to integer pixel boundaries.
    var frac_fast: [17]f32 = undefined;
    var frac_sweep: [17]f32 = undefined;
    const flen = 1 + xorshift32(&state) % 17;
    const fy = randF32(&state, -1, 1);
    coverageRowFast(&curves, fy, 0.3, frac_fast[0..flen]);
    coverageRow(&curves, fy, 0.3, frac_sweep[0..flen]);
    for (frac_fast[0..flen], frac_sweep[0..flen]) |a, e| {
        try testing.expectApproxEqAbs(e, a, 1e-4);
    }
    // Scalar fallback path: 40 curves × 4 pieces > batch_cap (128).
    var big: [40]QuadCurve = undefined;
    for (&big, 0..) |*c, k| {
        c.* = randCurve(&state, @intCast(k));
    }
    var big_fast: [17]f32 = undefined;
    var big_sweep: [17]f32 = undefined;
    const blen = 1 + xorshift32(&state) % 17;
    const by = randF32(&state, -1, 1);
    const bx = randF32(&state, -2, 1);
    coverageRowFast(&big, by, bx, big_fast[0..blen]);
    coverageRow(&big, by, bx, big_sweep[0..blen]);
    for (big_fast[0..blen], big_sweep[0..blen]) |a, e| {
        try testing.expectApproxEqAbs(e, a, 1e-4);
    }
}

test "fast boundary: extent ends exactly on an integer x" {
    // A vertical line at x = 2.0 spanning the row: extent_max == 2.0 is
    // an integer pixel boundary. Pixel 2's window starts AT the line, so
    // the sweep's entirely-left test (`<=` includes the touch) returns
    // dir * span there; the step at diff[i_step = 2] delivers exactly
    // that, and pixels >= 3 get the same step.
    const curve: QuadCurve = .{ .p0 = .{ 2, 0.4 }, .p1 = .{ 2, 1 }, .p2 = .{ 2, 1.6 } };
    var fast: [6]f32 = undefined;
    var sweep: [6]f32 = undefined;
    coverageRowFast(&[_]QuadCurve{curve}, 0.5, 0, &fast);
    coverageRow(&[_]QuadCurve{curve}, 0.5, 0, &sweep);
    for (fast, sweep) |a, e| {
        try testing.expectApproxEqAbs(e, a, 1e-4);
    }
    // dir * span = +1 * (min(1.5, 1.6) - max(0.5, 0.4)) = 1.0.
    try testing.expectApproxEqAbs(0.0, fast[0], 1e-6);
    try testing.expectApproxEqAbs(0.0, fast[1], 1e-6);
    try testing.expectApproxEqAbs(1.0, fast[2], 1e-6);
    try testing.expectApproxEqAbs(1.0, fast[3], 1e-6);
}

test "fast boundary: partial-overlap piece (span < 1)" {
    // A piece whose y-range [0.7, 0.9] lies fully inside the row window
    // [0.5, 1.5): span = 0.9 - 0.7 = 0.2 < 1, so the step is dir * span,
    // not ±1. The x-extent spans the row (x 0.5..4.5), so pixels 0..4
    // are corrected with the exact sweep value and pixel 5 gets the pure
    // step 0.2 (dir = +1).
    const curve: QuadCurve = .{ .p0 = .{ 0.5, 0.7 }, .p1 = .{ 2.5, 0.9 }, .p2 = .{ 4.5, 0.9 } };
    var fast: [6]f32 = undefined;
    var sweep: [6]f32 = undefined;
    coverageRowFast(&[_]QuadCurve{curve}, 0.5, 0, &fast);
    coverageRow(&[_]QuadCurve{curve}, 0.5, 0, &sweep);
    for (fast, sweep) |a, e| {
        try testing.expectApproxEqAbs(e, a, 1e-4);
    }
    // Pixel 5 lies entirely right of extent_max = 4.5: dir * span = 0.2.
    try testing.expectApproxEqAbs(0.2, fast[5], 1e-6);
}

test "fast boundary: row with zero hits" {
    // Curves whose y-ranges lie entirely below and above the row
    // [0.5, 1.5): no piece intersects the window, out stays all zeros.
    const curves = [_]QuadCurve{
        .{ .p0 = .{ 0, -5 }, .p1 = .{ 0.5, -4 }, .p2 = .{ 1, -3 } },
        .{ .p0 = .{ 0, 5 }, .p1 = .{ 0.5, 6 }, .p2 = .{ 1, 7 } },
        .{ .p0 = .{ 2, -3 }, .p1 = .{ 2, -2 }, .p2 = .{ 2, -1 } },
    };
    var out: [8]f32 = undefined;
    coverageRowFast(&curves, 0.5, 0, &out);
    for (out) |v| {
        try testing.expectApproxEqAbs(0.0, v, 0.0);
    }
    var sweep: [8]f32 = undefined;
    coverageRow(&curves, 0.5, 0, &sweep);
    for (out, sweep) |a, e| {
        try testing.expectApproxEqAbs(e, a, 0.0);
    }
}

test "fast boundary: window clipping the extent" {
    // Extent right of the window: a vertical line at x = 10, window
    // [0, 3) — i_step = 10 > out.len, so step and corrections both skip.
    const right: QuadCurve = .{ .p0 = .{ 10, 0 }, .p1 = .{ 10, 1 }, .p2 = .{ 10, 2 } };
    var out: [3]f32 = undefined;
    coverageRowFast(&[_]QuadCurve{right}, 0.5, 0, &out);
    for (out) |v| {
        try testing.expectApproxEqAbs(0.0, v, 0.0);
    }
    var sweep: [3]f32 = undefined;
    coverageRow(&[_]QuadCurve{right}, 0.5, 0, &sweep);
    for (out, sweep) |a, e| {
        try testing.expectApproxEqAbs(e, a, 1e-4);
    }

    // Extent left of the window: a vertical line at x = -2 — i_step <= 0,
    // diff[0] steps the whole window: every pixel gets dir * span = 1.
    const left: QuadCurve = .{ .p0 = .{ -2, 0 }, .p1 = .{ -2, 1 }, .p2 = .{ -2, 2 } };
    coverageRowFast(&[_]QuadCurve{left}, 0.5, 0, &out);
    for (out) |v| {
        try testing.expectApproxEqAbs(1.0, v, 1e-6);
    }
    coverageRow(&[_]QuadCurve{left}, 0.5, 0, &sweep);
    for (out, sweep) |a, e| {
        try testing.expectApproxEqAbs(e, a, 1e-4);
    }
}

test "fast boundary: out.len == 1" {
    // Single-pixel rows: the diff array is [2]f32 and every branch still
    // applies. Parabola at y = 0.5 (area 0.235702), the unit square at
    // y = 0.5 (0.5), and a vertical line at the window's left edge (1.0).
    const arch: QuadCurve = .{ .p0 = .{ 0, 0 }, .p1 = .{ 0.5, 2 }, .p2 = .{ 1, 0 } };
    const base: QuadCurve = .{ .p0 = .{ 1, 0 }, .p1 = .{ 0.5, 0 }, .p2 = .{ 0, 0 } };
    const parabola = [_]QuadCurve{ base, arch };
    var out: [1]f32 = undefined;
    var sweep: [1]f32 = undefined;
    coverageRowFast(&parabola, 0.5, 0, &out);
    try testing.expectApproxEqAbs(0.235702, out[0], 1e-4);
    coverageRow(&parabola, 0.5, 0, &sweep);
    try testing.expectApproxEqAbs(sweep[0], out[0], 1e-4);

    const square = [_]QuadCurve{
        .{ .p0 = .{ 0, 0 }, .p1 = .{ 0, 0.5 }, .p2 = .{ 0, 1 } },
        .{ .p0 = .{ 0, 1 }, .p1 = .{ 0.5, 1 }, .p2 = .{ 1, 1 } },
        .{ .p0 = .{ 1, 1 }, .p1 = .{ 1, 0.5 }, .p2 = .{ 1, 0 } },
        .{ .p0 = .{ 1, 0 }, .p1 = .{ 0.5, 0 }, .p2 = .{ 0, 0 } },
    };
    coverageRowFast(&square, 0.5, 0, &out);
    try testing.expectApproxEqAbs(0.5, out[0], 1e-6);
    coverageRow(&square, 0.5, 0, &sweep);
    try testing.expectApproxEqAbs(sweep[0], out[0], 1e-4);

    const vertical: QuadCurve = .{ .p0 = .{ 0.5, 0.5 }, .p1 = .{ 0.5, 1 }, .p2 = .{ 0.5, 1.5 } };
    coverageRowFast(&[_]QuadCurve{vertical}, 0.5, 0.5, &out);
    try testing.expectApproxEqAbs(1.0, out[0], 1e-6);
    coverageRow(&[_]QuadCurve{vertical}, 0.5, 0.5, &sweep);
    try testing.expectApproxEqAbs(sweep[0], out[0], 1e-4);
}

test "coverageRowFast == coverageRow on the lambda glyph" {
    const fixture = @import("lambda_fixture.zig");
    // The cast below reads the fixture's bytes as `QuadCurve`. That is only
    // the same data while both declarations are the same fixed layout, so
    // state that here: extern, three `[2]f32` fields named and ordered
    // `p0`, `p1`, `p2`, one total size. A declaration that changes any of
    // it stops the compile instead of silently reinterpreting the bytes.
    comptime {
        const declared = @typeInfo(fixture.QuadCurve).@"struct";
        const here = @typeInfo(QuadCurve).@"struct";
        std.debug.assert(declared.layout == .@"extern" and here.layout == .@"extern");
        std.debug.assert(@sizeOf(fixture.QuadCurve) == @sizeOf(QuadCurve));
        std.debug.assert(declared.fields.len == here.fields.len);
        for (declared.fields, here.fields) |d, h| {
            std.debug.assert(std.mem.eql(u8, d.name, h.name));
            std.debug.assert(d.type == h.type);
        }
    }
    const src: []const QuadCurve = std.mem.bytesAsSlice(
        QuadCurve,
        std.mem.sliceAsBytes(&fixture.curves),
    );
    // The sweep fills interior-to-the-right (CW in Y-up); the fixture is
    // wound CCW (the CFF convention), so reverse the single contour run
    // and swap each curve's endpoints — exactly like the real rasterizer
    // (examples/formula_tui.zig) — before transforming.
    var curves: [fixture.curves.len]QuadCurve = undefined;
    for (src, 0..) |_, k| {
        const r = src[src.len - 1 - k];
        curves[k] = .{ .p0 = r.p2, .p1 = r.p1, .p2 = r.p0 };
    }
    // Pixel scale like the rasterizer: 12 pt at 96 dpi over a 1000-unit
    // em, translated so the glyph lands at non-negative coordinates.
    const scale = 12.0 * (96.0 / 72.0) / 1000.0;
    var min_x: f32 = std.math.inf(f32);
    var max_x: f32 = -std.math.inf(f32);
    var min_y: f32 = std.math.inf(f32);
    var max_y: f32 = -std.math.inf(f32);
    for (&curves) |*c| {
        for ([_]*[2]f32{ &c.p0, &c.p1, &c.p2 }) |p| {
            p[0] = p[0] * scale + 3.0;
            p[1] = p[1] * scale + 5.0;
            min_x = @min(min_x, p[0]);
            max_x = @max(max_x, p[0]);
            min_y = @min(min_y, p[1]);
            max_y = @max(max_y, p[1]);
        }
    }
    const x0: i64 = @intFromFloat(@floor(min_x));
    const x1: i64 = @intFromFloat(@ceil(max_x));
    const n: usize = @intCast(x1 - x0);
    const x_start: f32 = @floatFromInt(x0);
    try testing.expect(n > 0);
    var fast: [64]f32 = undefined;
    var sweep: [64]f32 = undefined;
    try testing.expect(n <= fast.len);
    // Every integer row covering the ink bbox, plus one above and below.
    var wy: i64 = @as(i64, @intFromFloat(@floor(min_y))) - 1;
    const wy_end: i64 = @as(i64, @intFromFloat(@floor(max_y))) + 1;
    while (wy <= wy_end) : (wy += 1) {
        const y: f32 = @floatFromInt(wy);
        coverageRowFast(&curves, y, x_start, fast[0..n]);
        coverageRow(&curves, y, x_start, sweep[0..n]);
        for (fast[0..n], sweep[0..n]) |a, e| {
            try testing.expectApproxEqAbs(e, a, 1e-4);
        }
    }
}
