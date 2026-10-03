//! Real-glyph test fixture: the U+03BB (λ) outline from the vendored
//! Latin Modern Math face (vendor/ztex/src/fonts/lmmath.zig), extracted
//! with the font.zig glyphOutline path (CFF charstrings flattened to
//! quadratics). Em units, Y-up, unitsPerEm = 1000; contours are
//! consecutive runs (p2[i] == p0[i + 1]); winding is the CFF CCW
//! convention.
//!
//! The local `QuadCurve` is `extern` and declares the same fields as
//! `coverage.QuadCurve`, in the same order and of the same types, so the
//! two hold identical bytes: tests reuse the array through a `bytesAsSlice`
//! cast, the same reinterpretation `examples/formula_tui.zig` `drawText`
//! performs on live outlines, and `src/coverage.zig` checks that layout at
//! compile time.

/// Byte-compatible with `coverage.QuadCurve`: `extern`, the three fields in
/// `p0`, `p1`, `p2` order, no padding between them.
pub const QuadCurve = extern struct {
    /// Curve start, `[x, y]`.
    p0: [2]f32,
    /// Steer point, `[x, y]`.
    p1: [2]f32,
    /// Curve end, `[x, y]`.
    p2: [2]f32,
};

/// LM Math U+03BB gid 4189, 29 curves.
pub const curves = [_]QuadCurve{
    .{ .p0 = .{ 563, -1 }, .p1 = .{ 562.9375, 1.15625 }, .p2 = .{ 561, 3.125 } },
    .{ .p0 = .{ 561, 3.125 }, .p1 = .{ 559.0625, 5.09375 }, .p2 = .{ 556, 8 } },
    .{ .p0 = .{ 556, 8 }, .p1 = .{ 546.46875, 16.21875 }, .p2 = .{ 538.625, 27.625 } },
    .{ .p0 = .{ 538.625, 27.625 }, .p1 = .{ 530.78125, 39.03125 }, .p2 = .{ 522, 54 } },
    .{ .p0 = .{ 522, 54 }, .p1 = .{ 348.5, 338.5 }, .p2 = .{ 175, 623 } },
    .{ .p0 = .{ 175, 623 }, .p1 = .{ 147.75, 665.5 }, .p2 = .{ 110, 680.25 } },
    .{ .p0 = .{ 110, 680.25 }, .p1 = .{ 72.25, 695 }, .p2 = .{ 36, 694 } },
    .{ .p0 = .{ 36, 694 }, .p1 = .{ 31.53125, 694.34375 }, .p2 = .{ 25.375, 692.625 } },
    .{ .p0 = .{ 25.375, 692.625 }, .p1 = .{ 19.21875, 690.90625 }, .p2 = .{ 20, 683 } },
    .{ .p0 = .{ 20, 683 }, .p1 = .{ 22.0625, 677.125 }, .p2 = .{ 26.75, 675 } },
    .{ .p0 = .{ 26.75, 675 }, .p1 = .{ 31.4375, 672.875 }, .p2 = .{ 32, 673 } },
    .{ .p0 = .{ 32, 673 }, .p1 = .{ 55.6875, 670.4375 }, .p2 = .{ 71.5, 656.25 } },
    .{ .p0 = .{ 71.5, 656.25 }, .p1 = .{ 87.3125, 642.0625 }, .p2 = .{ 117, 593 } },
    .{ .p0 = .{ 117, 593 }, .p1 = .{ 199.5, 457 }, .p2 = .{ 282, 321 } },
    .{ .p0 = .{ 282, 321 }, .p1 = .{ 178, 184 }, .p2 = .{ 74, 47 } },
    .{ .p0 = .{ 74, 47 }, .p1 = .{ 67.1875, 38.40625 }, .p2 = .{ 64.5, 31.875 } },
    .{ .p0 = .{ 64.5, 31.875 }, .p1 = .{ 61.8125, 25.34375 }, .p2 = .{ 64, 16 } },
    .{ .p0 = .{ 64, 16 }, .p1 = .{ 67.4375, 3.03125 }, .p2 = .{ 78, -4.875 } },
    .{ .p0 = .{ 78, -4.875 }, .p1 = .{ 88.5625, -12.78125 }, .p2 = .{ 101, -13 } },
    .{ .p0 = .{ 101, -13 }, .p1 = .{ 112.78125, -12.625 }, .p2 = .{ 119.125, -6.25 } },
    .{ .p0 = .{ 119.125, -6.25 }, .p1 = .{ 125.46875, 0.125 }, .p2 = .{ 129, 8 } },
    .{ .p0 = .{ 129, 8 }, .p1 = .{ 214, 150 }, .p2 = .{ 299, 292 } },
    .{ .p0 = .{ 299, 292 }, .p1 = .{ 351.9375, 207.6875 }, .p2 = .{ 403.75, 120.75 } },
    .{ .p0 = .{ 403.75, 120.75 }, .p1 = .{ 455.5625, 33.8125 }, .p2 = .{ 474, 11 } },
    .{ .p0 = .{ 474, 11 }, .p1 = .{ 489.59375, -4.8125 }, .p2 = .{ 501.625, -8.25 } },
    .{ .p0 = .{ 501.625, -8.25 }, .p1 = .{ 513.65625, -11.6875 }, .p2 = .{ 533, -11 } },
    .{ .p0 = .{ 533, -11 }, .p1 = .{ 544, -11 }, .p2 = .{ 555, -11 } },
    .{ .p0 = .{ 555, -11 }, .p1 = .{ 561.5, -10 }, .p2 = .{ 562.75, -6.75 } },
    .{ .p0 = .{ 562.75, -6.75 }, .p1 = .{ 564, -3.5 }, .p2 = .{ 563, -1 } },
};
