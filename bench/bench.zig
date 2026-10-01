//! bench: the notui render-pipeline benchmark (ROADMAP F2).
//!
//! Ten timed cases plus the headless App loop:
//!
//! - `static 80x24` / `static 200x60`: the same content is drawn on every
//!   iteration, so every render after the first must be a no-op (zero
//!   bytes). A non-zero steady-state frame fails the run.
//! - `stream 80x24` / `stream 200x60`: the frame is redrawn, then one row
//!   is replaced with the other of two distinct literals, so exactly one
//!   row changes per iteration and the diff must emit it.
//! - `damage 80x24` / `damage 200x60`: the B4 gate on general content. One
//!   fixed styled row changes on an otherwise identical band, and every
//!   frame is encoded twice over those same pixels — once by the live
//!   `Buffer.renderDiff` and once by the pinned pre-B4 encoder further
//!   down — so the byte reduction is measured, never asserted. The case
//!   fails if the live encoder ever costs more than that baseline.
//! - `styles 80x24`: the style-run frame the B4 change measures — only
//!   the last row damaged, ten style runs of eight cells, two content
//!   sets with identical styles, so the two encoders can only disagree
//!   about the SGR stream. Both byte counts come out of the run itself;
//!   the case fails if the live encoder ever costs more than the pinned
//!   baseline.
//! - `region h1` / `region h4` / `region h24`: an inline `Region` band
//!   cycles through the five frame strategies — diff, forced full redraw,
//!   height grow, height shrink, append flush — plus an idle frame that
//!   must write nothing. Every busy phase is checked against the idle
//!   frame's OWN byte count rather than an assumed floor, and a
//!   violation is counted and reported: the case never ends the run.
//!
//! Then the headless App loop: a real `App(LoopModel)` band rendered twice
//! through `App.frameHeadless`, published frame by frame through the debug
//! server's driver, and read back over a real TCP connection. It prints its
//! own `bench: loop ...` lines instead of a p50/p99 row (two frames have no
//! distribution), with every number read back out of the App's
//! `frame_stats`, the driver, the transport's own byte count, and the JSON
//! line the server sent — which is parsed field by field and compared
//! against the snapshot the loop published.
//!
//! Metrics per case: wall time for N iterations (N sized from a probe so
//! the case runs ~0.5 s), per-iteration min/p50/p99 nanoseconds, bytes
//! emitted per frame (counted by a discarding writer as they are written —
//! frames are never buffered), and allocations per frame (a counting
//! allocator around the buffers under test). Every case checks its own
//! invariants while it runs: a static frame must emit nothing, a changed
//! row must be emitted, a busy region phase must out-write the idle one,
//! and the buffer-level cases must not allocate at all. The buffer cases
//! end the run at the first violation; the region cases count theirs and
//! the run exits non-zero at the end, so one broken phase never costs the
//! other measurements. The loop checks that the driver published every
//! frame, that the App's `written_bytes` equals what the transport was
//! handed, and that the line read back over TCP matches the published
//! snapshot field for field.
//!
//! Timing is the std 0.16 monotonic clock through `std.Io`
//! (`std.Io.Clock.awake`); examples/formula_tui.zig reads the same
//! CLOCK_MONOTONIC source through the raw syscall in its `monoNs` helper
//! (std.time.Timer no longer exists in 0.16). Every sample includes two
//! clock reads, so the harness measures and prints its own overhead.
//!
//! Output is a human table plus one greppable `bench: ...` line per case.

const std = @import("std");
const notui = @import("notui");

const App = notui.app.App;
const Buffer = notui.buffer.Buffer;
const Cell = notui.cell.Cell;
const Cmd = notui.app.Cmd;
const Context = notui.app.Context;
const Region = notui.region.Region;
const Style = notui.style.Style;
const View = notui.app.View;
const Width = notui.width;
const debug_server = notui.debug_server;
const emit = notui.emit;
const net = std.Io.net;
const output = notui.output;
const watchdog = notui.watchdog;

// ── tuning ───────────────────────────────────────

/// Wall-time budget per case, used to size the measured run.
const target_ns: u64 = 500 * std.time.ns_per_ms;
/// Iterations in the sizing probe.
const probe_iters: usize = 64;
/// Bounds on the measured iteration count.
const min_iters: usize = 64;
const max_iters: usize = 1_000_000;
/// Phases in the region case's strategy cycle.
const region_phase_count = 6;

/// The region case's phases, in cycle order. Every printed byte table and
/// every FAIL line names the phase the number belongs to.
const phase_names = [region_phase_count][]const u8{
    "diff", "full", "grow", "shrink", "append", "idle",
};

/// The silent frame every busy phase is measured against.
const idle_phase = region_phase_count - 1;

/// Every error a case can raise: the writer's error, allocation failure,
/// and the invariant violations the bench checks.
const BenchError = std.mem.Allocator.Error || std.Io.Writer.Error || error{
    StaticFrameWroteBytes,
    ChangedRowNotEmitted,
    RegressionVsPreB4,
    PreB4BaselineSilent,
    RenderAllocated,
    /// A region phase broke its byte contract. Counted and reported
    /// while the case runs, raised after every case has been measured.
    RegionInvariantBroken,
    LoopFramesMissing,
    LoopFrameSilent,
    LoopFrameNoDamage,
    LoopPublishCount,
    LoopWrittenBytesMismatch,
    LoopSnapshotRows,
    LoopSnapshotCols,
    LoopSnapshotDirtyCells,
    LoopTcpMalformed,
    LoopTcpFrameCounter,
    LoopTcpRows,
    LoopTcpCols,
    LoopTcpDirtyCells,
    LoopTcpStatus,
    LoopTcpTimestamp,
};

// ── timing ───────────────────────────────────────

/// Monotonic clock in nanoseconds through `std.Io` (Linux CLOCK_MONOTONIC
/// under the default Io implementation — the same source
/// examples/formula_tui.zig reads in its `monoNs` helper).
fn monoNs(io: std.Io) u64 {
    const ns = std.Io.Clock.awake.now(io).toNanoseconds();
    return @intCast(ns);
}

/// Value at `pct` of an ascending slice: index `floor((len - 1) * pct / 100)`.
fn percentile(sorted: []const u64, pct: usize) u64 {
    if (sorted.len == 0) return 0;
    return sorted[@min(sorted.len - 1, (sorted.len - 1) * pct / 100)];
}

// ── measurement devices ──────────────────────────

/// Counting sink: the render pipeline writes into `disc`, which counts
/// every byte and stores none of them.
const Sink = struct {
    buf: [4096]u8 = undefined,
    disc: std.Io.Writer.Discarding = undefined,

    /// Must run in place: the writer borrows `buf` and the vtable recovers
    /// the `Discarding` from the writer's address.
    fn init(self: *Sink) void {
        self.disc = std.Io.Writer.Discarding.init(&self.buf);
    }

    fn writer(self: *Sink) *std.Io.Writer {
        return &self.disc.writer;
    }

    /// Total bytes written so far, buffered bytes included.
    fn count(self: *const Sink) u64 {
        return self.disc.fullCount();
    }
};

/// Forwards to `child` and counts alloc/free calls, so the bench reports
/// allocations per frame instead of assuming them.
const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocs: usize = 0,
    frees: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const mem = self.child.vtable.alloc(self.child.ptr, len, alignment, ret_addr);
        if (mem != null) self.allocs += 1;
        return mem;
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ret_addr);
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.frees += 1;
        self.child.vtable.free(self.child.ptr, memory, alignment, ret_addr);
    }
};

// ── frame content ────────────────────────────────

/// Static rows borrowed by the Buffer (never copied, never mutated), so a
/// frame painted twice compares cell-for-cell equal.
const base_rows = [_][]const u8{
    "+--------------------------------------------------------------------+",
    "| notui bench: static frame content (deterministic, borrowed)        |",
    "| abcdefghijklmnopqrstuvwxyz 0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ    |",
    "| wide: 日本語テスト ─────── box drawing: ┌─┬─┐ │ │ └─┴─┘            |",
    "| combining: e\u{0301} o\u{0308} a\u{030A} n\u{0303} z\u{0301}     |",
    "| progress [####################----------------]  50%   3 of 6      |",
};

/// One style per base row, so the renderers exercise SGR tracking.
const base_styles = [_]Style{
    .{ .attrs = .{ .bold = true } },
    .{},
    .{ .fg = .{ .ansi = .cyan } },
    .{ .fg = .{ .ansi256 = 214 } },
    .{ .fg = .{ .ansi = .green }, .attrs = .{ .dim = true } },
    .{ .bg = .{ .ansi256 = 236 }, .fg = .{ .ansi = .white } },
};

/// Two one-row payloads, one column apart in length; the stream, region
/// and damage cases alternate them so a changed row always differs from
/// its previous content.
const row_a = "row replaced [A] ....................................................";
const row_b = "row replaced [B] .....................................................";

/// Row the damage case changes, held constant so both encoders see one
/// identical, reproducible "mostly-static frame, one styled row differs"
/// delta on every iteration.
const damage_row: u16 = 3;

/// Style of the replaced row in the stream case.
const row_style: Style = .{ .fg = .{ .ansi = .yellow }, .attrs = .{ .bold = true } };
/// Style of the changed row in the region diff phase.
const region_row_style: Style = .{ .fg = .{ .ansi = .green } };

/// One line queued above the band by the region append-flush phase.
const append_line = "bench: appended above the band";

/// Fill every row of `buf` with the base content, deterministically.
/// Wide buffers repeat the row at column 74 so the 200-column case
/// actually spans its width; every row ends with a right-edge marker.
fn paint(buf: *Buffer) BenchError!void {
    for (0..buf.height) |y| {
        const i = y % base_rows.len;
        const col: u16 = @intCast(y);
        _ = try buf.draw(base_styles[i], base_rows[i], 0, col);
        if (buf.width >= 150) {
            _ = try buf.draw(base_styles[(i + 3) % base_styles.len], base_rows[i], 74, col);
        }
        if (buf.width >= 12) {
            _ = try buf.draw(.{ .fg = .{ .ansi = .red } }, "@@@", buf.width - 3, col);
        }
    }
}

// ── pre-B4 baseline encoder ───────────────────────

// The roadmap's B4 gate is "bytes/frame down on a mostly-static frame with
// no pixel change" once `Buffer.renderDiff` gains row-granular early-out
// and an emitted-SGR memo. Comparing against a full repaint would prove
// nothing here: the live encoder already does row damage tracking, so the
// delta that matters is the one between the pre-B4 encoder and the
// optimized one, over the SAME changed pixels.
//
// So the pre-B4 encoder is pinned here, bench-side: the original byte path
// (row scan, `\r` + relative moves + column-1 erase, per-row style memo)
// calling the library's OWN emit helpers for every escape it writes, so the
// baseline emits exactly the SGR formatting the library emitted before the
// optimization. It must NOT be updated when `Buffer.renderDiff` changes —
// that divergence IS the measurement. While the two agree, the reported
// reduction is 0.0%; the day the encoder gets cheaper, this is where the
// bytes-down number appears, on identical pixels.

fn rowEqualPreB4(cur: *const Buffer, prev: *const Buffer, y: usize) bool {
    if (y >= prev.height or cur.width > prev.width) return false;
    for (0..cur.width) |x| {
        if (!cur.cells[y * cur.width + x].eql(prev.cells[y * prev.width + x])) return false;
    }
    return true;
}

/// The pre-B4 `Buffer.renderDiff` byte path: first/last changed row, then
/// for each changed row `\r`, the relative moves down to it, a column-1
/// erase, and its cells with the style memo threaded across the frame.
fn renderDiffPreB4(
    cur: *const Buffer,
    prev: *const Buffer,
    w: *std.Io.Writer,
) BenchError!void {
    var first: ?usize = null;
    var last: usize = 0;
    for (0..cur.height) |y| {
        if (rowEqualPreB4(cur, prev, y)) continue;
        if (first == null) first = y;
        last = y;
    }
    const f = first orelse return; // idle frame: nothing to encode

    var cur_row: usize = 0;
    var tracked: Style = .{};
    var y = f;
    while (y <= last) : (y += 1) {
        if (rowEqualPreB4(cur, prev, y)) continue;
        try w.writeAll("\r");
        var down = y - cur_row;
        while (down > 0) : (down -= 1) try w.writeByte('\n');
        cur_row = y;
        try emit.eraseLine(w);
        try writeRowPreB4(cur, w, y, &tracked);
    }
    // Frame-boundary hygiene, as the library's own encoder.
    if (!tracked.eql(Style{})) try w.writeAll(emit.reset);
}

fn writeRowPreB4(
    cur: *const Buffer,
    w: *std.Io.Writer,
    y: usize,
    tracked: *Style,
) BenchError!void {
    var x: usize = 0;
    var phys_col: usize = 0;
    while (x < cur.width) {
        const cell = cur.cells[y * cur.width + x];
        if (cell.wide or cell.grapheme.len == 0) {
            x += 1;
            continue;
        }
        if (cell.eql(Cell{})) {
            x += 1;
            continue;
        }
        const wg = Width.graphemeWidth(cell.grapheme);
        const wcell: usize = if (wg >= 2) 2 else 1;
        if (x + wcell > cur.width) {
            x += 1;
            continue;
        }
        if (x > phys_col) try w.print(emit.csi ++ "{d}C", .{x - phys_col});
        try writeStylePreB4(w, tracked, cell.style);
        try w.writeAll(cell.grapheme);
        phys_col = x + wcell;
        x += wcell;
    }
}

fn writeStylePreB4(w: *std.Io.Writer, tracked: *Style, style: Style) BenchError!void {
    if (tracked.eql(style)) return;
    if (!tracked.eql(Style{})) try w.writeAll(emit.reset);
    if (!style.eql(Style{})) try emit.writeStyle(w, style);
    tracked.* = style;
}

// ── cases ────────────────────────────────────────

/// Point `prev` at the frame just drawn — the sync every buffer-level case
/// does after its encoder runs.
///
/// The copy is shallow: cells keep borrowing the case's text. That is
/// exactly right while every string a case draws is an immutable literal
/// (`base_rows`, `row_a`/`row_b`, `style_text_*`, `style_plain_row`), since
/// the two buffers then hold the same bytes forever and a row that did not
/// change compares equal.
///
/// A case that draws from an arena, a scratch buffer, or any storage it
/// rewrites in place MUST NOT use this: writing the new frame over those
/// bytes would change `prev` too, the damage test would call the row
/// unchanged, and the frame would never repaint — the bytes-per-frame
/// number would quietly fall instead of failing loudly. Such a case has to
/// own its text the way `Region.syncPrev` does (copy the graphemes into a
/// retained arena and point the cells at the copies), or route the frame
/// through `Region.render` instead.
fn syncPrev(cur: *const Buffer, prev: *Buffer) void {
    @memcpy(prev.cells, cur.cells);
}

/// One `bench: FAIL ...` line, with the numbers this run measured — the
/// evidence for the failure, never a restatement of it.
fn fail(comptime format: []const u8, args: anytype) void {
    std.debug.print("bench: FAIL " ++ format ++ "\n", args);
}

/// Static frame: identical content every iteration, so every render after
/// the first must be a no-op.
///
/// `init` paints the band, encodes one real first frame against the empty
/// previous buffer, then syncs `prev` so the band already matches the
/// terminal. That first frame is the `first_frame_bytes` number: the
/// steady-state frame below must cost nothing at all.
const StaticCase = struct {
    cur: Buffer,
    prev: Buffer,
    first_frame_bytes: u64,
    /// Frames run so far; only labels a FAIL line.
    iter: usize = 0,

    fn init(
        allocator: std.mem.Allocator,
        sink: *Sink,
        width: u16,
        height: u16,
    ) BenchError!StaticCase {
        var cur = try Buffer.init(allocator, width, height);
        errdefer cur.deinit();
        var prev = try Buffer.init(allocator, width, height);
        errdefer prev.deinit();

        try paint(&cur);
        const start = sink.count();
        try cur.renderDiff(&prev, sink.writer());
        const first_frame_bytes = sink.count() - start;
        syncPrev(&cur, &prev);

        return .{ .cur = cur, .prev = prev, .first_frame_bytes = first_frame_bytes };
    }

    fn deinit(self: *StaticCase) void {
        self.cur.deinit();
        self.prev.deinit();
    }

    fn firstFrameBytes(self: *const StaticCase) u64 {
        return self.first_frame_bytes;
    }

    fn run(self: *StaticCase, sink: *Sink) BenchError!u64 {
        const before = sink.count();
        try paint(&self.cur);
        try self.cur.renderDiff(&self.prev, sink.writer());
        syncPrev(&self.cur, &self.prev);
        const bytes = sink.count() - before;
        if (bytes != 0) {
            fail(
                "static {d}x{d} iter={d}: identical frame wrote {d} B",
                .{ self.cur.width, self.cur.height, self.iter, bytes },
            );
            return error.StaticFrameWroteBytes;
        }
        self.iter += 1;
        return bytes;
    }

    fn resetStats(_: *StaticCase) void {}

    fn phaseBytes(_: *const StaticCase) ?[region_phase_count]u64 {
        return null;
    }

    fn refTotalBytes(_: *const StaticCase) u64 {
        return 0;
    }

    /// No phase contract: this case ends the run at the first violation.
    fn violationCounts(_: *const StaticCase) [region_phase_count]usize {
        return .{ 0, 0, 0, 0, 0, 0 };
    }
};

/// Damage case: the B4 gate's measurement. One fixed styled row
/// (`damage_row`) changes per frame on an otherwise identical band, and
/// every iteration encodes the SAME pixels twice — once with the live
/// `Buffer.renderDiff` and once with the pinned pre-B4 encoder. The two
/// byte counts are therefore directly comparable, and the case fails if
/// the live encoder ever gets MORE expensive than the pre-B4 baseline.
///
/// The reduction printed for this case is the encoder difference on
/// identical pixels: 0.0% only while the two encoders agree byte-for-byte,
/// and a real saving once `renderDiff` is cheaper than the baseline — the
/// roadmap's "bytes/frame down on a mostly-static frame".
const DamageCase = struct {
    cur: Buffer,
    prev: Buffer,
    /// Sink for the pinned pre-B4 encoder; owned by `main` so the case
    /// stays movable.
    ref_sink: *Sink,
    ref_bytes: u64 = 0,
    iter: usize = 0,
    first_frame_bytes: u64 = 0,

    fn init(
        allocator: std.mem.Allocator,
        sink: *Sink,
        ref_sink: *Sink,
        width: u16,
        height: u16,
    ) BenchError!DamageCase {
        var cur = try Buffer.init(allocator, width, height);
        errdefer cur.deinit();
        var prev = try Buffer.init(allocator, width, height);
        errdefer prev.deinit();

        try paint(&cur);
        _ = try cur.draw(row_style, row_a, 0, damage_row);
        const start = sink.count();
        try cur.renderDiff(&prev, sink.writer());
        const first_frame_bytes = sink.count() - start;
        syncPrev(&cur, &prev);

        return .{
            .cur = cur,
            .prev = prev,
            .ref_sink = ref_sink,
            // `init` already left `row_a` in the changed row; start at the
            // next payload so the first measured frame really does change
            // that row.
            .iter = 1,
            .first_frame_bytes = first_frame_bytes,
        };
    }

    fn deinit(self: *DamageCase) void {
        self.cur.deinit();
        self.prev.deinit();
    }

    fn firstFrameBytes(self: *const DamageCase) u64 {
        return self.first_frame_bytes;
    }

    fn run(self: *DamageCase, sink: *Sink) BenchError!u64 {
        const text = if (self.iter % 2 == 0) row_a else row_b;
        _ = try self.cur.draw(row_style, text, 0, damage_row);

        const ref_start = self.ref_sink.count();
        try renderDiffPreB4(&self.cur, &self.prev, self.ref_sink.writer());
        const ref = self.ref_sink.count() - ref_start;

        const live_start = sink.count();
        try self.cur.renderDiff(&self.prev, sink.writer());
        const live = sink.count() - live_start;
        syncPrev(&self.cur, &self.prev);

        if (live == 0) {
            fail(
                "damage {d}x{d} iter={d}: changed row emitted nothing",
                .{ self.cur.width, self.cur.height, self.iter },
            );
            return error.ChangedRowNotEmitted;
        }
        if (ref == 0) {
            fail(
                "damage {d}x{d} iter={d}: pre-B4 baseline emitted nothing",
                .{ self.cur.width, self.cur.height, self.iter },
            );
            return error.PreB4BaselineSilent;
        }
        if (live > ref) {
            fail(
                "damage {d}x{d} iter={d}: optimized {d} B over pre-B4 {d} B",
                .{ self.cur.width, self.cur.height, self.iter, live, ref },
            );
            return error.RegressionVsPreB4;
        }
        self.ref_bytes += ref;
        self.iter += 1;
        return live;
    }

    fn resetStats(self: *DamageCase) void {
        self.ref_bytes = 0;
    }

    fn refTotalBytes(self: *const DamageCase) u64 {
        return self.ref_bytes;
    }

    /// No phase contract: this case ends the run at the first violation.
    fn violationCounts(_: *const DamageCase) [region_phase_count]usize {
        return .{ 0, 0, 0, 0, 0, 0 };
    }

    fn phaseBytes(_: *const DamageCase) ?[region_phase_count]u64 {
        return null;
    }
};

/// The style runs of the B4 style frame: 10 contiguous runs of 8 cells
/// that alternate colour changes, attribute toggles on a shared colour,
/// and a final two-colour style. One run is one `draw` call, so the row has
/// no blank cells and no cursor-forward skips — the encoder writes all 80
/// columns of text plus one SGR stream, which is exactly what the B4 change
/// makes cheaper.
const style_runs = [_]Style{
    .{ .fg = .{ .ansi = .red } },
    .{ .fg = .{ .ansi = .red }, .attrs = .{ .bold = true } },
    .{ .fg = .{ .ansi = .red } },
    .{ .fg = .{ .ansi = .blue } },
    .{ .fg = .{ .ansi = .blue }, .attrs = .{ .underline = true } },
    .{ .fg = .{ .ansi = .blue } },
    .{ .fg = .{ .ansi = .green } },
    .{ .fg = .{ .ansi = .green }, .attrs = .{ .bold = true } },
    .{ .fg = .{ .ansi = .green } },
    .{ .fg = .{ .ansi = .cyan }, .bg = .{ .ansi = .blue } },
};

/// Cells per run; 10 runs fill the 80-column band exactly.
const style_cells: u16 = 8;
/// The style frame damages the band's LAST row, so the preamble is
/// `\r` + 23 × `\n` + one erase.
const style_row: u16 = 23;
/// Two content sets with identical styles: the row is genuinely damaged,
/// and the style stream — the only thing the B4 encoder changes — is not.
const style_text_a = "aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffffgggggggghhhhhhhhiiiiiiijjjjjjjj";
const style_text_b = "11111111222222223333333344444444555555556666666677777777888888889999999900000000";
/// The rows above the damaged one: plain text, no background anywhere, so
/// the erase never has to reset a live background first.
const style_plain_row = "notui bench: unchanged row, identical pixels every frame, no styles";

/// Draw the style-run row: 10 contiguous runs of `style_cells` cells.
fn drawStyleRow(buf: *Buffer, text: []const u8, row: u16) BenchError!void {
    inline for (style_runs, 0..) |style, k| {
        const x: u16 = @intCast(k * style_cells);
        _ = try buf.draw(style, text[x..][0..style_cells], x, row);
    }
}

/// The changed-style frame the B4 gate measures: an 80x24 band whose only
/// damaged row is the last one, written as 10 runs of 8 cells that
/// alternate colour and attribute changes. Both encoders see the same
/// pixels every frame, so their difference is the encoder's, not the
/// content's.
///
/// The case measures instead of comparing against a stored expectation:
/// the run prints its own `optimized_bytes/frame` and
/// `pre_b4_bytes/frame` for these pixels, and the reduction between them.
/// It FAILS on its own invariants — the live encoder emitted nothing, the
/// pinned baseline emitted nothing, or the live encoder cost more than
/// the baseline.
const StyleRunCase = struct {
    cur: Buffer,
    prev: Buffer,
    ref_sink: *Sink,
    ref_bytes: u64 = 0,
    iter: usize = 0,
    first_frame_bytes: u64 = 0,

    fn init(
        allocator: std.mem.Allocator,
        sink: *Sink,
        ref_sink: *Sink,
        width: u16,
        height: u16,
    ) BenchError!StyleRunCase {
        var cur = try Buffer.init(allocator, width, height);
        errdefer cur.deinit();
        var prev = try Buffer.init(allocator, width, height);
        errdefer prev.deinit();

        for (0..style_row) |y| {
            _ = try cur.draw(.{}, style_plain_row, 0, @intCast(y));
        }
        try drawStyleRow(&cur, style_text_a, style_row);

        const start = sink.count();
        try cur.renderDiff(&prev, sink.writer());
        const first_frame_bytes = sink.count() - start;
        syncPrev(&cur, &prev);

        return .{
            .cur = cur,
            .prev = prev,
            .ref_sink = ref_sink,
            // `init` left `style_text_a` in the row; start at the other set
            // so the first measured frame really does damage it.
            .iter = 1,
            .first_frame_bytes = first_frame_bytes,
        };
    }

    fn deinit(self: *StyleRunCase) void {
        self.cur.deinit();
        self.prev.deinit();
    }

    fn firstFrameBytes(self: *const StyleRunCase) u64 {
        return self.first_frame_bytes;
    }

    fn run(self: *StyleRunCase, sink: *Sink) BenchError!u64 {
        const text = if (self.iter % 2 == 0) style_text_a else style_text_b;
        try drawStyleRow(&self.cur, text, style_row);

        const ref_start = self.ref_sink.count();
        try renderDiffPreB4(&self.cur, &self.prev, self.ref_sink.writer());
        const ref = self.ref_sink.count() - ref_start;

        const live_start = sink.count();
        try self.cur.renderDiff(&self.prev, sink.writer());
        const live = sink.count() - live_start;
        syncPrev(&self.cur, &self.prev);

        if (live == 0) {
            fail(
                "styles {d}x{d} iter={d}: changed row emitted nothing",
                .{ self.cur.width, self.cur.height, self.iter },
            );
            return error.ChangedRowNotEmitted;
        }
        if (ref == 0) {
            fail(
                "styles {d}x{d} iter={d}: pre-B4 baseline emitted nothing",
                .{ self.cur.width, self.cur.height, self.iter },
            );
            return error.PreB4BaselineSilent;
        }
        if (live > ref) {
            fail(
                "styles {d}x{d} iter={d}: optimized {d} B over pre-B4 {d} B",
                .{ self.cur.width, self.cur.height, self.iter, live, ref },
            );
            return error.RegressionVsPreB4;
        }
        self.ref_bytes += ref;
        self.iter += 1;
        return live;
    }

    fn resetStats(self: *StyleRunCase) void {
        self.ref_bytes = 0;
    }

    fn refTotalBytes(self: *const StyleRunCase) u64 {
        return self.ref_bytes;
    }

    /// No phase contract: this case ends the run at the first violation.
    fn violationCounts(_: *const StyleRunCase) [region_phase_count]usize {
        return .{ 0, 0, 0, 0, 0, 0 };
    }

    fn phaseBytes(_: *const StyleRunCase) ?[region_phase_count]u64 {
        return null;
    }
};

/// Streaming frame: the frame is redrawn, then exactly one row is
/// replaced, so the diff must emit that row's bytes.
const StreamCase = struct {
    cur: Buffer,
    prev: Buffer,
    iter: usize = 0,
    first_frame_bytes: u64 = 0,

    fn init(
        allocator: std.mem.Allocator,
        sink: *Sink,
        width: u16,
        height: u16,
    ) BenchError!StreamCase {
        var cur = try Buffer.init(allocator, width, height);
        errdefer cur.deinit();
        var prev = try Buffer.init(allocator, width, height);
        errdefer prev.deinit();

        try paint(&cur);
        _ = try cur.draw(row_style, row_a, 0, 0);
        const start = sink.count();
        try cur.renderDiff(&prev, sink.writer());
        const first_frame_bytes = sink.count() - start;
        syncPrev(&cur, &prev);

        return .{
            .cur = cur,
            .prev = prev,
            .iter = 1,
            .first_frame_bytes = first_frame_bytes,
        };
    }

    fn deinit(self: *StreamCase) void {
        self.cur.deinit();
        self.prev.deinit();
    }

    fn firstFrameBytes(self: *const StreamCase) u64 {
        return self.first_frame_bytes;
    }

    fn run(self: *StreamCase, sink: *Sink) BenchError!u64 {
        const before = sink.count();
        try paint(&self.cur);

        const height: usize = self.cur.height;
        const row: u16 = @intCast(self.iter % height);
        // Alternate per visit (not per iteration): every revisit of a row
        // writes the other payload, so the row always changes.
        const text = if ((self.iter / height) % 2 == 0) row_a else row_b;
        _ = try self.cur.draw(row_style, text, 0, row);

        try self.cur.renderDiff(&self.prev, sink.writer());
        syncPrev(&self.cur, &self.prev);

        const bytes = sink.count() - before;
        if (bytes == 0) {
            fail(
                "stream {d}x{d} iter={d}: changed row emitted nothing",
                .{ self.cur.width, self.cur.height, self.iter },
            );
            return error.ChangedRowNotEmitted;
        }
        self.iter += 1;
        return bytes;
    }

    fn resetStats(_: *StreamCase) void {}

    fn refTotalBytes(_: *const StreamCase) u64 {
        return 0;
    }

    /// No phase contract: this case ends the run at the first violation.
    fn violationCounts(_: *const StreamCase) [region_phase_count]usize {
        return .{ 0, 0, 0, 0, 0, 0 };
    }

    fn phaseBytes(_: *const StreamCase) ?[region_phase_count]u64 {
        return null;
    }
};

/// Region repaint: an inline band cycles through the five frame
/// strategies plus an idle frame. Phase order per cycle:
///
/// 0. diff: one row changes;
/// 1. forced full redraw (`renderFull`);
/// 2. height grow (`setHeight(base + 1)`);
/// 3. height shrink (`setHeight(base)`);
/// 4. append flush (a queued line, then a full repaint);
/// 5. idle: nothing changed, nothing queued.
///
/// The `first` strategy is encoded by `init` and reported separately; the
/// timed loop starts from an anchored, painted band.
///
/// What the case asserts is what it can OBSERVE, never which strategy the
/// library picked: the idle frame must write exactly zero bytes, and every
/// busy phase must write strictly more bytes than the idle frame beside
/// it. A phase that breaks that contract is counted, not fatal — the case
/// finishes its measurement and the run ends non-zero afterwards, so one
/// broken phase never throws the other numbers away. Phase 1 in
/// particular measures `renderFull`, whatever strategy that routes to;
/// if it ever stops repainting, the byte table says so and the run fails.
const RegionCase = struct {
    region: Region,
    base_height: u16,
    first_frame_bytes: u64 = 0,
    iter: usize = 0,
    bytes: [region_phase_count]u64 = .{ 0, 0, 0, 0, 0, 0 },
    /// Frames per phase that broke the byte contract above.
    violations: [region_phase_count]usize = .{ 0, 0, 0, 0, 0, 0 },
    /// What the most recent idle frame wrote, the floor every busy phase
    /// has to beat. Zero until an idle frame has been measured, which is
    /// exactly what the idle invariant claims about it.
    idle_bytes: u64 = 0,

    fn init(allocator: std.mem.Allocator, sink: *Sink, height: u16) BenchError!RegionCase {
        var region = try Region.init(allocator, .{ .height = height });
        errdefer region.deinit();

        try paint(&region.cur);
        const start = sink.count();
        try region.render(sink.writer());
        const first_frame_bytes = sink.count() - start;

        return .{
            .region = region,
            .base_height = height,
            .first_frame_bytes = first_frame_bytes,
        };
    }

    fn deinit(self: *RegionCase) void {
        self.region.deinit();
    }

    fn firstFrameBytes(self: *const RegionCase) u64 {
        return self.first_frame_bytes;
    }

    fn run(self: *RegionCase, sink: *Sink) BenchError!u64 {
        const before = sink.count();
        const phase = self.iter % region_phase_count;
        const sweep = self.iter / region_phase_count;

        switch (phase) {
            0 => {
                const height: usize = self.region.height;
                const row: u16 = @intCast(sweep % height);
                // Alternate per VISIT of that row, not per sweep: row `r`
                // is revisited every `height` sweeps, so sweep parity
                // alone would repeat the same payload and leave the row
                // unchanged (no damage to report).
                const visits = (sweep - @as(usize, row)) / height;
                const text = if (visits % 2 == 0) row_a else row_b;
                _ = try self.region.cur.draw(region_row_style, text, 0, row);
                try self.region.render(sink.writer());
            },
            1 => try self.region.renderFull(sink.writer()),
            2 => {
                try self.region.setHeight(self.base_height + 1);
                try self.region.render(sink.writer());
            },
            3 => {
                try self.region.setHeight(self.base_height);
                try self.region.render(sink.writer());
            },
            4 => {
                try self.region.append(.{ .line = append_line });
                try self.region.render(sink.writer());
            },
            5 => try self.region.render(sink.writer()),
            else => unreachable,
        }

        const bytes = sink.count() - before;
        self.bytes[phase] += bytes;
        if (phase == idle_phase) {
            // The floor is measured, never assumed: the idle frame sets
            // it, and a non-zero reading is itself a violation.
            self.idle_bytes = bytes;
            if (bytes != 0) self.violations[phase] += 1;
        } else if (bytes <= self.idle_bytes) {
            // A busy phase that writes no more than the idle frame has
            // not caused the traffic the byte table credits it with.
            self.violations[phase] += 1;
        }
        self.iter += 1;
        return bytes;
    }

    fn resetStats(self: *RegionCase) void {
        self.bytes = .{ 0, 0, 0, 0, 0, 0 };
        self.violations = .{ 0, 0, 0, 0, 0, 0 };
    }

    fn refTotalBytes(_: *const RegionCase) u64 {
        return 0;
    }

    fn phaseBytes(self: *const RegionCase) ?[region_phase_count]u64 {
        return self.bytes;
    }

    fn violationCounts(self: *const RegionCase) [region_phase_count]usize {
        return self.violations;
    }
};

// ── headless App loop ─────────────────────────────

// The cases above drive the buffer and the region directly. This one
// drives the REAL app: a live `App(LoopModel)` band, composed and submitted
// by `App.frameHeadless` (the headless seam — `tick` reads input, so it is
// not usable here), published frame by frame through the debug server's
// driver, and read back over a real TCP connection.
//
// The App is assembled from its public fields exactly as `start` would,
// minus the tty: interactive band, output queue, both arenas, the model.
// Every number printed below is read back out of the App and the server —
// `frame_stats` (dirty cells, staged vs written bytes, frame cost), the
// driver's frame count, the transport's write count, and the JSON line the
// server actually sent over the socket.

/// Visual frames the loop case renders: two, so the second one is a real
/// delta frame rather than a repeat of the first paint.
const loop_frames = 2;

/// The band geometry the headless App is given. The snapshot read back
/// over TCP must carry exactly these rows and columns, so they are named
/// once here instead of typed into the assertions.
const loop_rows: u16 = 2;
const loop_columns: u16 = 80;

/// The App's model: a counter, no effects, one draw.
const LoopModel = struct {
    pub const Msg = union(enum) { tick };

    frame: usize = 0,

    pub fn init(_: std.mem.Allocator) !struct { model: LoopModel, cmd: Cmd(LoopModel.Msg) } {
        return .{ .model = .{}, .cmd = .none };
    }

    pub fn update(_: *LoopModel, _: Msg, _: *Context) !Cmd(Msg) {
        return .none;
    }

    pub fn view(_: *const LoopModel, _: *Context) View(LoopModel) {
        return .{ .draw = &draw };
    }

    /// The App's own draw (inferred error set, like the framework example):
    /// the text is allocated in the frame arena, which the frame buffer's
    /// cells then borrow.
    pub fn draw(self: *LoopModel, ctx: *Context, buf: *Buffer) !void {
        const text = try std.fmt.allocPrint(ctx.frame_arena, "frame {d}", .{self.frame});
        _ = try buf.draw(.{}, text, 0, 0);
    }
};

/// Byte-counting transport: the one method the output queue needs from a
/// sink, adapted to the bench's counting sink. `bytes` is a SECOND count
/// of the frame traffic, taken where it is actually handed over, so the
/// App's own `written_bytes` claim has something independent to be
/// checked against.
const LoopSink = struct {
    sink: *Sink,
    calls: usize = 0,
    bytes: usize = 0,

    pub fn tryWrite(self: *LoopSink, bytes: []const u8) error{WriteFailed}!usize {
        self.calls += 1;
        const written = self.sink.writer().write(bytes) catch return error.WriteFailed;
        self.bytes += written;
        return written;
    }
};

/// A live headless App plus the transport its frames drain into.
const LoopCase = struct {
    app: App(LoopModel),
    transport: LoopSink,
    /// What the App measured for each frame, captured as it landed.
    frame_cost_ns: [loop_frames]u64 = .{ 0, 0 },
    /// Bytes `frame_stats.written_bytes` reported for each frame.
    frame_bytes: [loop_frames]usize = .{ 0, 0 },
    /// The same bytes, counted by the transport they were handed to.
    frame_transport: [loop_frames]usize = .{ 0, 0 },
    frame_dirty: [loop_frames]usize = .{ 0, 0 },
    /// The snapshot each frame published exactly as the loop built it;
    /// the driver stamps `frame` and `at_ns` on top of it.
    frame_snapshot: [loop_frames]debug_server.Snapshot = @splat(.{}),

    fn init(allocator: std.mem.Allocator, io: std.Io, sink: *Sink) !LoopCase {
        var app = App(LoopModel).init();
        app.io = io;
        app.gpa = allocator;
        app.region = try Region.init(allocator, .{
            .height = loop_rows,
            .interactive = true,
            .sync_output = true,
        });
        errdefer app.region.?.deinit();
        try app.region.?.resize(loop_columns, loop_rows);
        app.out = try output.OutputQueue.init(allocator, .{});
        errdefer app.out.?.deinit();
        app.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer app.arena.?.deinit();
        app.scratch = std.heap.ArenaAllocator.init(allocator);
        errdefer app.scratch.?.deinit();
        app.running = true;
        app.model = (try LoopModel.init(allocator)).model;
        return .{ .app = app, .transport = .{ .sink = sink } };
    }

    /// One visual frame. The frame number comes from the App's own frame
    /// counter, so the model advances with what the App really composed.
    /// The snapshot is kept as built here: the driver stamps `frame` and
    /// `at_ns` on top, and the TCP read-back is verified against it.
    fn frame(self: *LoopCase) debug_server.Snapshot {
        const composed = self.app.frame_stats.frames;
        const slot: usize = if (composed < loop_frames) @intCast(composed) else loop_frames - 1;
        var snap: debug_server.Snapshot = .{};
        self.app.model.frame = composed;
        const transport_before = self.transport.bytes;

        if (self.app.frameHeadless(output.Transport.from(&self.transport))) |taken| {
            const stats = self.app.frame_stats;
            self.frame_cost_ns[slot] = stats.frame_cost_ns;
            self.frame_bytes[slot] = stats.written_bytes;
            self.frame_transport[slot] = self.transport.bytes - transport_before;
            self.frame_dirty[slot] = stats.dirty_cells;
            snap.rows = self.app.region.?.height;
            snap.cols = self.app.region.?.width;
            snap.dirty_cells = @intCast(stats.dirty_cells);
            if (taken > 0) {
                snap.setStatus("ok");
            } else {
                snap.setStatus("stalled");
            }
        } else |err| {
            snap.setStatus(@errorName(err));
        }
        self.frame_snapshot[slot] = snap;
        return snap;
    }
};

/// Connect to the running debug server, send one request line, and read the
/// single JSON line it answers with.
fn requestFrameLine(io: std.Io, port: u16, buffer: []u8) ![]const u8 {
    const addr = try net.IpAddress.parse("127.0.0.1", port);
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var wbuf: [debug_server.Server.io_buffer_capacity]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    try writer.interface.writeAll("GET /frame\n");
    try writer.interface.flush();

    var reader = stream.reader(io, buffer);
    return reader.interface.takeDelimiterExclusive('\n');
}

/// One snapshot line, parsed field by field. Hand-rolled on purpose: the
/// bench takes no dependency for a single flat line, and the parse borrows
/// `line` — nothing is allocated, in a hot path or out of one.
///
/// The field ORDER is the server's (`writeSnapshotLine`), so a renamed,
/// reordered or dropped field fails the parse instead of comparing
/// nothing and passing.
const TcpSnapshot = struct {
    frame: u64 = 0,
    at_ns: i96 = 0,
    rows: u16 = 0,
    cols: u16 = 0,
    dirty_cells: u32 = 0,
    status: []const u8 = "",

    const ParseError = error{
        MalformedFrameLine,
        EscapedFrameStatus,
    };

    fn parse(line: []const u8) ParseError!TcpSnapshot {
        var scan: Scan = .{ .rest = line };
        var self: TcpSnapshot = .{};
        try scan.literal("{\"frame\":");
        self.frame = try scan.int(u64);
        try scan.literal(",\"at_ns\":");
        self.at_ns = try scan.int(i96);
        try scan.literal(",\"rows\":");
        self.rows = try scan.int(u16);
        try scan.literal(",\"cols\":");
        self.cols = try scan.int(u16);
        try scan.literal(",\"dirty_cells\":");
        self.dirty_cells = try scan.int(u32);
        try scan.literal(",\"status\":");
        self.status = try scan.text();
        try scan.literal("}");
        try scan.end();
        return self;
    }
};

/// Cursor over a snapshot line: literal bytes must match exactly, and a
/// value is either a decimal integer or a quoted string.
const Scan = struct {
    rest: []const u8,

    fn literal(self: *Scan, lit: []const u8) TcpSnapshot.ParseError!void {
        if (!std.mem.startsWith(u8, self.rest, lit)) return error.MalformedFrameLine;
        self.rest = self.rest[lit.len..];
    }

    /// The decimal integer at the cursor, leaving the cursor on the first
    /// byte after it. A field with no digits is a missing field, and a
    /// sign the type cannot hold fails in `parseInt` rather than wrapping.
    fn int(self: *Scan, comptime T: type) TcpSnapshot.ParseError!T {
        const body = self.rest;
        var limit: usize = 0;
        if (limit < body.len and body[limit] == '-') limit += 1;
        const digits_start = limit;
        while (limit < body.len and std.ascii.isDigit(body[limit])) limit += 1;
        if (limit == digits_start) return error.MalformedFrameLine;
        const value = std.fmt.parseInt(T, body[0..limit], 10) catch return error.MalformedFrameLine;
        self.rest = body[limit..];
        return value;
    }

    /// The quoted string at the cursor, borrowed from the line. Every
    /// status the loop publishes is an `@errorName` or a plain literal,
    /// so an escape is a shape this bench does not produce: it fails the
    /// parse loudly instead of comparing an escaped slice to a raw one.
    fn text(self: *Scan) TcpSnapshot.ParseError![]const u8 {
        if (self.rest.len == 0) return error.MalformedFrameLine;
        if (self.rest[0] != '"') return error.MalformedFrameLine;
        const body = self.rest[1..];
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            if (body[i] == '\\') return error.EscapedFrameStatus;
            if (body[i] == '"') {
                self.rest = body[i + 1 ..];
                return body[0..i];
            }
        }
        return error.MalformedFrameLine;
    }

    /// Nothing but line padding left: a trailing `\r` may not hide a field
    /// the loop expects.
    fn end(self: *const Scan) TcpSnapshot.ParseError!void {
        if (std.mem.trim(u8, self.rest, " \t\r\n").len != 0) return error.MalformedFrameLine;
    }
};

/// Render two visual frames through the real App loop, publish them over
/// TCP, read the state back, and print what every layer reported.
fn runLoopCase(
    w: *std.Io.Writer,
    allocator: std.mem.Allocator,
    counter: *CountingAllocator,
    io: std.Io,
    sink: *Sink,
) !void {
    var loop_case = try LoopCase.init(allocator, io, sink);
    defer loop_case.app.deinit();

    var server = try debug_server.Server.init(allocator, "127.0.0.1:0");
    defer server.deinit();
    try server.start(io);
    defer server.stop(io);

    var driver = debug_server.Driver{
        .server = &server,
        .interval_ns = 0,
        .frames = loop_frames,
        .watchdog = watchdog.Watchdog.init(watchdog.default_budget_ns),
    };
    const allocs_before = counter.allocs;
    try driver.run(io, &loop_case, LoopCase.frame);
    const frame_allocs = counter.allocs - allocs_before;

    // The driver published every frame it ran, so the ring the read-back
    // answers from is this run's own last frame.
    if (driver.frameCount() != loop_frames) return error.LoopFramesMissing;
    if (server.publishedCount() != driver.frameCount()) return error.LoopPublishCount;
    for (loop_case.frame_bytes) |bytes| {
        if (bytes == 0) return error.LoopFrameSilent;
    }
    if (loop_case.frame_dirty[0] == 0) return error.LoopFrameNoDamage;
    // Two counts of the same traffic — what the App says it wrote, and
    // what the transport was actually handed. They must agree per frame.
    for (loop_case.frame_bytes, loop_case.frame_transport) |claimed, counted| {
        if (claimed != counted) {
            fail("loop frame: app said {d} B, transport counted {d} B", .{ claimed, counted });
            return error.LoopWrittenBytesMismatch;
        }
    }

    // The snapshot the loop published must describe the App that produced
    // it: the band's live geometry and this frame's measured damage.
    const published: usize = loop_frames - 1;
    const want = loop_case.frame_snapshot[published];
    const region = loop_case.app.region.?;
    if (region.height != loop_rows) return error.LoopSnapshotRows;
    if (region.width != loop_columns) return error.LoopSnapshotCols;
    if (want.rows != region.height) return error.LoopSnapshotRows;
    if (want.cols != region.width) return error.LoopSnapshotCols;
    if (want.dirty_cells != loop_case.frame_dirty[published]) {
        return error.LoopSnapshotDirtyCells;
    }

    var line_buf: [debug_server.Server.io_buffer_capacity]u8 = undefined;
    const line = try requestFrameLine(io, server.boundPort(), &line_buf);
    const tcp = TcpSnapshot.parse(line) catch |err| {
        fail("loop tcp line={s} ({s})", .{ line, @errorName(err) });
        return error.LoopTcpMalformed;
    };
    // Field for field: the line the socket carried must be the snapshot
    // the loop published, under the driver's own frame counter.
    if (tcp.frame != driver.frameCount() - 1) return error.LoopTcpFrameCounter;
    if (tcp.rows != want.rows) return error.LoopTcpRows;
    if (tcp.cols != want.cols) return error.LoopTcpCols;
    if (tcp.dirty_cells != want.dirty_cells) return error.LoopTcpDirtyCells;
    if (!std.mem.eql(u8, tcp.status, want.statusText())) return error.LoopTcpStatus;
    if (tcp.at_ns <= 0) return error.LoopTcpTimestamp;

    try w.print(
        "bench: loop app frames={d} frame_cost_ns={d},{d} bytes={d},{d} dirty_cells={d},{d}\n",
        .{
            driver.frameCount(),
            loop_case.frame_cost_ns[0],
            loop_case.frame_cost_ns[1],
            loop_case.frame_bytes[0],
            loop_case.frame_bytes[1],
            loop_case.frame_dirty[0],
            loop_case.frame_dirty[1],
        },
    );
    try w.print(
        "bench: loop driver frames={d} transport_writes={d} frame_allocs={d} " ++
            "peak_pending={d} deferred_frames={d} published={d}\n",
        .{
            driver.frameCount(),
            loop_case.transport.calls,
            frame_allocs,
            loop_case.app.frame_stats.peak_pending,
            loop_case.app.frame_stats.deferred_frames,
            server.publishedCount(),
        },
    );
    try w.print(
        "bench: loop tcp port={d} frame={d} rows={d} cols={d} dirty_cells={d} " ++
            "written_bytes={d} transport_bytes={d} status={s}\n",
        .{
            server.boundPort(),
            tcp.frame,
            tcp.rows,
            tcp.cols,
            tcp.dirty_cells,
            loop_case.frame_bytes[published],
            loop_case.frame_transport[published],
            tcp.status,
        },
    );
    try w.print("bench: loop tcp line={s}\n", .{line});
}

// ── harness ──────────────────────────────────────

/// One case's numbers.
const CaseResult = struct {
    label: []const u8,
    iterations: usize,
    wall_ns: u64,
    min_ns: u64,
    p50_ns: u64,
    p99_ns: u64,
    total_bytes: u64,
    first_frame_bytes: u64,
    allocs: usize,
    /// Per-phase byte totals, region cases only.
    phase_bytes: ?[region_phase_count]u64,
    /// Frames per phase that broke their byte contract; all zero outside
    /// the region cases, which report instead of ending the run.
    violations: [region_phase_count]usize,
    /// Total bytes the pinned pre-B4 encoder produced for the same
    /// frames; 0 in cases that do not run the baseline.
    ref_total_bytes: u64 = 0,
};

/// The measuring devices shared by every case: the byte-counting sink,
/// the allocation counter, and the per-iteration sample buffer.
const Harness = struct {
    sink: *Sink,
    counter: *CountingAllocator,
    samples: []u64,
};

/// Run `case` through a sizing probe and the measured batch.
///
/// `T` must provide `run(sink)`, `firstFrameBytes()`, `resetStats()`,
/// `refTotalBytes()`, `phaseBytes()` and `violationCounts()`. `h.samples`
/// must hold at least `max_iters` entries. When `zero_alloc` is set, any
/// allocation inside the measured loop fails the run.
fn measure(
    io: std.Io,
    label: []const u8,
    comptime T: type,
    case: *T,
    h: Harness,
    zero_alloc: bool,
) BenchError!CaseResult {
    // The first frame (strategy 1 for the region) was encoded by the
    // case's `init`, which also left the band in its steady state.
    const first_frame_bytes = case.firstFrameBytes();

    var probe: [probe_iters]u64 = undefined;
    for (&probe) |*p| {
        const t0 = monoNs(io);
        _ = try case.run(h.sink);
        p.* = monoNs(io) - t0;
    }
    std.mem.sortUnstable(u64, &probe, {}, std.sort.asc(u64));
    const est_ns = @max(percentile(&probe, 50), 1);
    const budget = std.math.clamp(target_ns / est_ns, @as(u64, min_iters), @as(u64, max_iters));
    const iters: usize = @intCast(budget);

    case.resetStats();
    const allocs_before = h.counter.allocs;
    var total_bytes: u64 = 0;
    const wall_start = monoNs(io);
    for (h.samples[0..iters]) |*s| {
        const t0 = monoNs(io);
        total_bytes += try case.run(h.sink);
        s.* = monoNs(io) - t0;
    }
    const wall_ns = monoNs(io) - wall_start;
    const allocs = h.counter.allocs - allocs_before;
    if (zero_alloc and allocs != 0) return error.RenderAllocated;

    const sorted = h.samples[0..iters];
    std.mem.sortUnstable(u64, sorted, {}, std.sort.asc(u64));
    return .{
        .label = label,
        .iterations = iters,
        .wall_ns = wall_ns,
        .min_ns = sorted[0],
        .p50_ns = percentile(sorted, 50),
        .p99_ns = percentile(sorted, 99),
        .total_bytes = total_bytes,
        .first_frame_bytes = first_frame_bytes,
        .allocs = allocs,
        .phase_bytes = case.phaseBytes(),
        .ref_total_bytes = case.refTotalBytes(),
        .violations = case.violationCounts(),
    };
}

const ClockOverhead = struct { p50_ns: u64, p99_ns: u64 };

/// Per-iteration cost of the timing harness itself: two `Clock.awake`
/// reads around an empty body. Reported so the frame numbers can be read
/// with the floor in mind.
fn clockOverhead(io: std.Io, samples: []u64) ClockOverhead {
    const n = @min(samples.len, 100_000);
    for (samples[0..n]) |*s| {
        const t0 = monoNs(io);
        s.* = monoNs(io) - t0;
    }
    const sorted = samples[0..n];
    std.mem.sortUnstable(u64, sorted, {}, std.sort.asc(u64));
    return .{ .p50_ns = percentile(sorted, 50), .p99_ns = percentile(sorted, 99) };
}

// ── reporting ────────────────────────────────────

/// Print the human table, then one greppable `bench: ...` line per case:
/// the metric line every case gets, the region phase breakdown with its
/// own FAIL lines, and the pre-B4 byte comparison for the cases that run
/// the pinned baseline. Every number below was measured by this run.
fn report(
    w: *std.Io.Writer,
    results: []const CaseResult,
    clock: ClockOverhead,
) std.Io.Writer.Error!void {
    try w.print(
        "bench: notui render pipeline, {d} cases (timing floor: clock p50={d}ns p99={d}ns)\n",
        .{ results.len, clock.p50_ns, clock.p99_ns },
    );
    try w.print("{s:<18} {s:>8} {s:>11} {s:>11} {s:>11} {s:>11} {s:>12} {s:>12}\n", .{
        "case", "iters", "wall_ms", "min_ns", "p50_ns", "p99_ns", "bytes/frame", "allocs/frame",
    });
    for (results) |r| {
        try w.print("{s:<18} {d:>8} {d:>11} {d:>11} {d:>11} {d:>11} {d:>12} {d:>12.3}\n", .{
            r.label,
            r.iterations,
            r.wall_ns / std.time.ns_per_ms,
            r.min_ns,
            r.p50_ns,
            r.p99_ns,
            r.total_bytes / r.iterations,
            @as(f64, @floatFromInt(r.allocs)) / @as(f64, @floatFromInt(r.iterations)),
        });
    }
    try w.writeByte('\n');

    for (results) |r| {
        const per_frame = r.total_bytes / r.iterations;
        const iters_f: f64 = @floatFromInt(r.iterations);
        const allocs_per_frame = @as(f64, @floatFromInt(r.allocs)) / iters_f;
        try w.print(
            "bench: {s} p50={d}ns p99={d}ns bytes/frame={d} min={d}ns iters={d} " ++
                "wall_ms={d} bytes/total={d} first_frame_bytes={d} allocs/frame={d:.3}\n",
            .{
                r.label,
                r.p50_ns,
                r.p99_ns,
                per_frame,
                r.min_ns,
                r.iterations,
                r.wall_ns / std.time.ns_per_ms,
                r.total_bytes,
                r.first_frame_bytes,
                allocs_per_frame,
            },
        );
        if (r.phase_bytes) |pb| {
            try w.print("bench: {s} phase_bytes", .{r.label});
            for (pb, phase_names) |bytes, name| {
                try w.print(" {s}={d}", .{ name, bytes });
            }
            try w.writeByte('\n');
            // A phase that broke its contract reports how many frames
            // broke it, under the byte total it really produced.
            for (r.violations, phase_names, pb) |frames, name, bytes| {
                if (frames == 0) continue;
                try w.print(
                    "bench: FAIL {s} phase={s} frames={d} bytes={d}\n",
                    .{ r.label, name, frames, bytes },
                );
            }
        }
        // Live encoder against the pinned pre-B4 baseline over identical
        // changed pixels: 0.0% while the library encoder is unchanged,
        // and the roadmap's bytes-down number once it is optimized.
        if (r.ref_total_bytes != 0) {
            const ref_bf = r.ref_total_bytes / r.iterations;
            const reduction = reductionPct(per_frame, ref_bf);
            try w.print(
                "bench: bytes {s} optimized_bytes/frame={d} pre_b4_bytes/frame={d} " ++
                    "reduction={d:.1}%\n",
                .{ r.label, per_frame, ref_bf, reduction },
            );
        }
    }
}

/// Percentage by which `part` is smaller than `whole`; 0 when `whole` is
/// 0, so a missing baseline never reports a bogus reduction.
fn reductionPct(part: u64, whole: u64) f64 {
    if (whole == 0) return 0;
    const num = @as(f64, @floatFromInt(whole -| part));
    return 100.0 * num / @as(f64, @floatFromInt(whole));
}

/// Frames that broke a byte contract, summed over every measured case.
/// The run fails on a non-zero total — after the report, never during it.
fn regionViolations(results: []const CaseResult) usize {
    var total: usize = 0;
    for (results) |r| {
        for (r.violations) |frames| total += frames;
    }
    return total;
}

// ── entry point ──────────────────────────────────

/// Measure the render pipeline and print the results. One run, no
/// arguments: every case is self-contained and checks its own invariants,
/// so a broken invariant fails the run — the buffer cases at once, the
/// region cases in the exit code, once every number has been printed.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var out_buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &file_writer.interface;

    var counter = CountingAllocator{ .child = gpa };
    const alloc = counter.allocator();

    var sink: Sink = .{};
    sink.init();

    const samples = try gpa.alloc(u64, max_iters);
    defer gpa.free(samples);

    const h = Harness{ .sink = &sink, .counter = &counter, .samples = samples };
    const clock = clockOverhead(io, samples);

    var results: [12]CaseResult = undefined;
    var n: usize = 0;

    var static80 = try StaticCase.init(alloc, &sink, 80, 24);
    defer static80.deinit();
    results[n] = try measure(io, "static 80x24", StaticCase, &static80, h, true);
    n += 1;

    var static200 = try StaticCase.init(alloc, &sink, 200, 60);
    defer static200.deinit();
    results[n] = try measure(io, "static 200x60", StaticCase, &static200, h, true);
    n += 1;

    var stream80 = try StreamCase.init(alloc, &sink, 80, 24);
    defer stream80.deinit();
    results[n] = try measure(io, "stream 80x24", StreamCase, &stream80, h, true);
    n += 1;

    var stream200 = try StreamCase.init(alloc, &sink, 200, 60);
    defer stream200.deinit();
    results[n] = try measure(io, "stream 200x60", StreamCase, &stream200, h, true);
    n += 1;

    // One fixed styled row changes on an otherwise identical band, and both
    // encoders see those same pixels each frame.
    var ref_sink: Sink = .{};
    ref_sink.init();

    var damage80 = try DamageCase.init(alloc, &sink, &ref_sink, 80, 24);
    defer damage80.deinit();
    results[n] = try measure(io, "damage 80x24", DamageCase, &damage80, h, true);
    n += 1;

    var damage200 = try DamageCase.init(alloc, &sink, &ref_sink, 200, 60);
    defer damage200.deinit();
    results[n] = try measure(io, "damage 200x60", DamageCase, &damage200, h, true);
    n += 1;

    // The style-run frame: 80x24, only the last row damaged, 10 style runs
    // of 8 cells. The same pixels go through both encoders every frame.
    var style80 = try StyleRunCase.init(alloc, &sink, &ref_sink, 80, 24);
    defer style80.deinit();
    results[n] = try measure(io, "styles 80x24", StyleRunCase, &style80, h, true);
    n += 1;

    var region1 = try RegionCase.init(alloc, &sink, 1);
    defer region1.deinit();
    results[n] = try measure(io, "region h1", RegionCase, &region1, h, false);
    n += 1;

    var region4 = try RegionCase.init(alloc, &sink, 4);
    defer region4.deinit();
    results[n] = try measure(io, "region h4", RegionCase, &region4, h, false);
    n += 1;

    var region24 = try RegionCase.init(alloc, &sink, 24);
    defer region24.deinit();
    results[n] = try measure(io, "region h24", RegionCase, &region24, h, false);
    n += 1;

    // The headless App loop: a real App band plus the debug server, with
    // its own greppable lines before the table.
    try runLoopCase(out, alloc, &counter, io, &sink);
    try out.writeByte('\n');

    try report(out, results[0..n], clock);
    try out.flush();

    // The region cases count their violations rather than ending the run,
    // so the failure is raised here — after every number is on screen.
    if (regionViolations(results[0..n]) != 0) return error.RegionInvariantBroken;
}
