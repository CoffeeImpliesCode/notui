//! Coverage rasterization for quadratic bezier outlines.
//!
//! Port of nogui `shaders/sweep.frag`: analytic quadratic-bezier
//! scanline coverage. Each pixel window is 1x1 with its lower-left
//! corner at (offset.x, offset.y), in Y-up space (FreeType convention).
//!
//! Two correctness fixes over the reference: every curve is split at its
//! coordinate extrema before sweeping (the single-root intersection is
//! exact only for monotonic quadratics), and the area term integrates
//! the quadratic exactly instead of the secant trapezoid, which
//! under-counts curved edges by their deviation from the chord.
//!
//! A row of pixels shares the same y and differs only in x, so the row
//! is swept in parallel as an `@Vector` of x-offsets: per-curve scalars
//! (y-bounds, vertical-line test, delta signs) are hoisted and computed
//! once; per-lane conditionals are branchless `@select`s. The vector
//! path is bit-identical to the scalar reference (tested).

const std = @import("std");
const testing = std.testing;

/// A quadratic bezier in Y-up space; the shape contract shared with the
/// font-outline side (B1). Declared here independently — no ztex import.
pub const QuadCurve = struct {
    p0: [2]f32,
    p1: [2]f32,
    p2: [2]f32,
};

/// SIMD lane count for `coverageRow`.
const lanes: usize = 8;

const size_x: f32 = 1.0;
const size_y: f32 = 1.0;

// ── scalar/vector shared arithmetic ────────────────────────
// Both cores call the same generic helpers (T = f32 or @Vector(L, f32))
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

/// Horizontal check (§8.3 h_check): a >= c -> d; else b <= c -> 1 - d;
/// else the monotonic root at c.
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

/// Up to 4 monotonic-in-x-and-y pieces of one quadratic (fixed [4] stack
/// array, no allocation).
pub const MonoSplit = struct {
    pieces: [4]QuadCurve,
    n: u8,
};

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

/// Split a quadratic at its x-extremum (if any) and then each piece at
/// its y-extremum (if any): every returned piece is monotonic in both x
/// and y, so the single-root intersections in the sweep are exact.
/// Direction (p0 -> p2) is preserved; at most 4 pieces.
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
    comptime L: usize,
    offset_xs: @Vector(L, f32),
    offset_y: f32,
    c: QuadCurve,
) @Vector(L, f32) {
    const vec = @Vector(L, f32);
    const zero: vec = zeroOf(vec);
    const one: vec = oneOf(vec);
    const p0 = c.p0;
    const p1 = c.p1;
    const p2 = c.p2;

    // Per-curve scalars, computed once.
    const dx = p2[0] - p0[0];
    const dy = p2[1] - p0[1];
    const y_disjoint = @max(p0[1], p2[1]) <= offset_y or @min(p0[1], p2[1]) >= offset_y + size_y;

    // Shifted control points: x per-lane, y per-curve.
    const x0: vec = fromF32(vec, p0[0]) - offset_xs;
    const x1: vec = fromF32(vec, p1[0]) - offset_xs;
    const x2: vec = fromF32(vec, p2[0]) - offset_xs;
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
    const vert_formula: vec = (fromF32(vec, sign(f32, dy)) * (one - @max(x0, zero))) * fromF32(vec, vert_h);
    const vert_result = sel(vec, vert_valid, vert_formula, zero);

    // Y-intersections.
    const qa_y = y0 + y2 - 2.0 * y1;
    const bt = intersectMonotonic(f32, qa_y, y0, y1, y2, 0);
    const tt = intersectMonotonic(f32, qa_y, y0, y1, y2, size_y);
    const v_min_t = if (dy > 0) bt else tt;
    const v_max_t = if (dy > 0) tt else bt;
    const v_min_t_c = clamp01(f32, v_min_t);
    const v_max_t_c = clamp01(f32, v_max_t);
    const v_min_x: vec = evalBez(vec, x0, x1, x2, fromF32(vec, v_min_t_c));
    const v_max_x: vec = evalBez(vec, x0, x1, x2, fromF32(vec, v_max_t_c));
    const v_min_y = evalBez(f32, y0, y1, y2, v_min_t_c);
    const v_max_y = evalBez(f32, y0, y1, y2, v_max_t_c);

    // Curve entirely left of the window, or entirely right of it.
    const left_out = @max(v_min_x, v_max_x) <= zero;
    const right_out = @min(v_min_x, v_max_x) >= fromF32(vec, size_x);
    const left_val: vec = fromF32(vec, (v_max_y - v_min_y) * size_x);

    // X-intersections.
    const qa_x: vec = x0 + x2 - fromF32(vec, 2.0) * x1;
    const h_min_t = if (dx > 0)
        hCheck(vec, qa_x, x0, x1, x2, x0, x2, 0, 0)
    else
        hCheck(vec, qa_x, x0, x1, x2, x2, x0, size_x, 1);
    const h_max_t = if (dx > 0)
        hCheck(vec, qa_x, x0, x1, x2, x0, x2, size_x, 0)
    else
        hCheck(vec, qa_x, x0, x1, x2, x2, x0, 0, 1);

    const v_min_t_s: vec = fromF32(vec, v_min_t);
    const v_max_t_s: vec = fromF32(vec, v_max_t);
    const min_t = clamp01(vec, @max(v_min_t_s, h_min_t));
    const max_t = clamp01(vec, @min(v_max_t_s, h_max_t));
    const overlap = min_t < max_t;

    const q0y = sel(
        vec,
        v_min_t_s >= h_min_t,
        fromF32(vec, v_min_y),
        evalBez(vec, fromF32(vec, y0), fromF32(vec, y1), fromF32(vec, y2), min_t),
    );
    const q1y = sel(
        vec,
        v_max_t_s <= h_max_t,
        fromF32(vec, v_max_y),
        evalBez(vec, fromF32(vec, y0), fromF32(vec, y1), fromF32(vec, y2), max_t),
    );

    // Side-rectangle terms. The dx/dy sign choices are per-curve
    // constants, so they are uniform scalar branches; the per-lane
    // t-clamps select branchlessly.
    const h1 = if (dy > 0)
        q0y - @max(zero, fromF32(vec, y0))
    else
        @min(one, fromF32(vec, y0)) - q0y;
    const add1 = fromF32(vec, sign(f32, dy)) * h1 * one;
    var area: vec = zero;
    if (dx > 0) area = sel(vec, min_t > zero, zero + add1, zero);
    const h2 = if (dy > 0)
        @min(one, fromF32(vec, y2)) - q1y
    else
        q1y - @max(zero, fromF32(vec, y2));
    const add2 = fromF32(vec, sign(f32, dy)) * h2 * one;
    if (dx < 0) area = sel(vec, max_t < one, area + add2, area);
    const h_trap = q1y - q0y;
    const f_max = bezIntX(vec, x0, x1, x2, fromF32(vec, y0), fromF32(vec, y1), fromF32(vec, y2), max_t);
    const f_min = bezIntX(vec, x0, x1, x2, fromF32(vec, y0), fromF32(vec, y1), fromF32(vec, y2), min_t);
    // Exact ∫_{min_t}^{max_t} (size_x - x(t)) y'(t) dt, mirroring the
    // scalar core: the secant trapezoid under-counts curved edges.
    area += fromF32(vec, size_x) * h_trap - (f_max - f_min);

    const general = sel(
        vec,
        left_out,
        left_val,
        sel(vec, right_out, zero, sel(vec, overlap, area, zero)),
    );
    const vertical_or_general = sel(vec, vertical, vert_result, general);
    // The y-window early-out is a per-curve constant: a uniform return.
    if (y_disjoint) return zero;
    return vertical_or_general;
}

// ── public row API ───────────────────────────────

/// Sum the sweep over every curve for a row of pixels at
/// [x_start, x_start + out.len) x [y, y + 1), clamped to [0, 1].
/// Every curve is swept as monotonic pieces (a curve turning inside a
/// pixel window breaks the single-root intersections). Signed area
/// fills the interior to the RIGHT of travel (CW in Y-up); callers
/// feeding PostScript/CFF outlines (outer CCW) reverse contours first.
/// Curves disjoint from the y-window are skipped once for the whole row;
/// the rest are swept in `lanes`-wide vectors (the tail uses a partial
/// vector). out.len >= 1.
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
