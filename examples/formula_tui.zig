//! formula_tui: LaTeX → ztex draw list → SIMD coverage rasterizer →
//! kitty graphics, interactive.
//!
//! A 4-row band below the prompt: row 0 is the "formula N> " input line
//! (region text), row 1 the live formula preview (a kitty image at native
//! pixel size — it may overflow the band vertically, overlays are fine).
//! Every keystroke re-renders the typed LaTeX through the vendored ztex
//! facade, rasterizes the draw list with the SIMD coverage sweep
//! (src/coverage.zig), and re-transmits the bitmap under a FIXED image id
//! (the kitty spec: re-transmitting an id deletes the old image +
//! placements, so transmit + re-place is the whole update). Enter commits
//! the formula — keeps the display, clears the line, bumps the prompt
//! — while an invalid formula on Enter draws a one-line hint and
//! keeps the input. Parse errors while typing also draw the hint below
//! the preview (the last good preview stays displayed); empty input
//! keeps the last good preview and shows no error. Line editing: Left/Right
//! move the cursor by codepoint, Home/End (or ^A/^E) jump to the line
//! ends, Backspace deletes before the cursor, Delete forward, ^K/^U/^W
//! kill to end / to start / the word before the cursor. q on an empty
//! line / Ctrl+D quit; Ctrl+C clears the line; PageUp/PageDown zoom
//! 12..48pt (the +/- glyphs are input text, so the nav keys stand in).
//! Non-TTY
//! stdin degrades to one plain frame: the default formula rasterized and
//! dumped as a PPM (the piped verification path — no tty, no kitty).
//!
//! Rasterizer coordinates mirror vendor/ztex/src/svg.zig: the draw list
//! is baseline-anchored (ascent negative), offset down by `height` so
//! content lands at non-negative rows, then pt→px at 96 dpi. Glyph
//! outlines (em, Y-up) scale per-drawable by its own size and translate
//! to the baseline; the coverage sweep's 1x1 windows at integer offsets
//! (window wy covers Y-up [wy, wy+1), i.e. bitmap row height-1-wy) are
//! fed the flipped row index — the convention coverage.zig's tests use.

const std = @import("std");
const notui = @import("notui");
const ztex = @import("ztex");
const coverage = notui.coverage;

/// Restore the terminal on panic: defers never run for a panicking
/// process, and a raw/hidden-cursor/kitty-mode terminal is what forces a
/// hard reset. Re-raises the default panic after cleanup.
pub const panic = std.debug.FullPanic(struct {
    pub fn call(msg: []const u8, ra: ?usize) noreturn {
        notui.tty.restoreTerminal();
        std.debug.defaultPanic(msg, ra);
    }
}.call);

const Tty = notui.tty.Tty;
const Region = notui.region.Region;
const Key = notui.key;
const Reader = notui.input.Reader;

/// Kitty image cache id: fixed so a re-transmit replaces the old image
/// and its placement, and place/delete can address it.
const formula_id: u32 = 7000;
/// Region band height in terminal rows.
const band_height: u16 = 4;
/// Band row of the formula preview image (0-based within the band).
const preview_row: u32 = 1;
/// Band row of the one-line error hint (below the preview).
const hint_row: u16 = 2;
/// The formula rendered on startup and kept on display while the input
/// is empty.
const default_formula = "\\lambda";
const default_size_pt: f32 = 12;
const min_size_pt: f32 = 12;
const max_size_pt: f32 = 48;
const size_step_pt: f32 = 2;
/// Loop pacing: nextTimeout returns null on timeout, redrawing the band.
const tick_ms: i32 = 100;
/// Points → pixels at 96 dpi (the rasterizer's resolution).
const pt_px: f32 = 96.0 / 72.0;
/// The text cursor marker drawn after the typed line.
const cursor_marker = "█";
/// Ctrl+D, the app's quit key (Key defines only ctrl_c among the ASCII
/// control chars).
const ctrl_d: u21 = 0x04;

/// A rasterized formula: RGBA pixels with WHITE RGB everywhere and the
/// per-pixel coverage in the alpha channel (0 = fully transparent, 1 =
/// fully inked, fractional at AA edges). The terminal's own background
/// shows through the transparent pixels.
const Bitmap = struct {
    data: []u8,
    width: u32,
    height: u32,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // Debug args (piped path): `--ascii [formula]` prints the coverage
    // grid of the rendered formula as an ASCII value map instead of a
    // PPM — the pixel-level debug view.
    var it = std.process.Args.Iterator.init(init.minimal.args);
    defer it.deinit();
    _ = it.next(); // argv[0]: the program name
    var src_arg: ?[]const u8 = null;
    var ascii = false;
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--ascii")) {
            ascii = true;
        } else if (src_arg == null) {
            src_arg = a;
        }
    }

    // Font context: owns the embedded LM faces (CFF outlines served by
    // glyphOutline) — "init once, render many".
    var ctx = try ztex.Context.init(gpa);
    defer ctx.deinit();

    // Non-TTY degradation: one plain frame (PPM or ASCII dump), no tty.
    if (!Tty.isTty(std.posix.STDIN_FILENO)) {
        return runPlain(gpa, io, &ctx, src_arg orelse default_formula, ascii);
    }

    var tty = try Tty.init(io);
    defer tty.deinit();
    try tty.makeRaw();
    defer tty.restore();

    var parser: notui.parser = .{};
    const caps = try notui.caps.Capabilities.detect(gpa, &tty, &parser);
    const kitty = caps.kitty_graphics;

    var region = try Region.init(gpa, .{ .height = band_height });
    defer region.deinit();

    // Size the band to the terminal before the first frame.
    const ws = try tty.getWinsize();
    try region.resize(ws.cols, region.height);

    // App-owned arena: the typed line and the committed source live here
    // for the whole session — the draw list aliases the source, and
    // arena appends never move, so those slices stay valid.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    // The line being typed (grows in the arena); `cursor` is the byte
    // offset of the edit caret (always on a utf-8 sequence boundary).
    var line: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    var formula_n: u32 = 1;
    var committed: []const u8 = default_formula;
    var size_pt: f32 = default_size_pt;
    // The band's absolute top row is unknown until the FIRST CPR reply
    // (the query fires before the first paint; see the `.cpr` arm).
    var anchor_known: bool = false;
    // A bitmap is currently transmitted (the last good preview). False
    // while the current input fails to parse — the old image stays.
    var preview_ok: bool = false;
    var hint: ?[]const u8 = null;
    var hint_buf: [128]u8 = undefined;
    // The offending input span of the current parse error (valid when
    // `hint` is set); the input line renders it red.
    var err_span: ztex.atom.Span = .{ .start = 0, .end = 0 };
    // Last preview stage timings (parse + render), drawn grey
    // right-aligned on the hint row.
    var stats: PreviewStats = .{};

    var reader = Reader.init(&tty);
    const w = tty.writer();

    // Default formula: render + transmit up front (position-independent);
    // the placement waits for the first CPR reply to anchor the band.
    preview_ok = preview(gpa, &ctx, default_formula, size_pt, kitty, w, &hint, &hint_buf, &err_span, &stats);
    try w.flush();

    while (true) {
        const ev = reader.nextTimeout(tick_ms) catch break;
        if (ev) |e| switch (e) {
            .key_press => |k| {
                if (isCtrlC(k)) {
                    // Normal key event: clear the line, keep running. The
                    // last committed formula stays displayed (empty input
                    // → no re-render, no delete).
                    line.clearRetainingCapacity();
                    cursor = 0;
                    hint = null;
                } else if (isCtrlD(k)) {
                    break; // ctrl+d always quits
                } else if (k.matches('q', .{}) and line.items.len == 0) {
                    break; // `q` quits only on an empty line — else text
                } else if (k.matches(Key.enter, .{})) {
                    if (line.items.len > 0) {
                        var info: ztex.parse.Info = undefined;
                        const result = updatePreview(gpa, &ctx, line.items, size_pt, kitty, w, &info, &stats);
                        if (result) |_| {
                            // Commit: the displayed formula stays, a fresh
                            // prompt starts.
                            preview_ok = true;
                            formula_n += 1;
                            committed = try aa.dupe(u8, line.items);
                            line.clearRetainingCapacity();
                            cursor = 0;
                            hint = null;
                        } else |err| {
                            // Invalid: do NOT commit, do NOT clear — draw
                            // a one-line hint, keep the prompt as-is.
                            preview_ok = false;
                            formatErr(&hint, &hint_buf, err, &info, line.items, &err_span);
                        }
                    }
                } else if (k.matches(Key.left, .{})) {
                    // Move the cursor one codepoint left (no edit).
                    cursor = prevCodepoint(line.items, cursor);
                } else if (k.matches(Key.right, .{})) {
                    // Move the cursor one codepoint right (no edit).
                    if (cursor < line.items.len) {
                        cursor += utf8SeqLen(line.items, cursor);
                    }
                } else if (k.matches(Key.home, .{}) or isCtrl(k, 0x01, 'a')) {
                    cursor = 0; // Home / ^A: line start
                } else if (k.matches(Key.end, .{}) or isCtrl(k, 0x05, 'e')) {
                    cursor = line.items.len; // End / ^E: line end
                } else if (isCtrl(k, 0x0B, 'k')) {
                    // ^K: kill to end of line (from the cursor).
                    line.shrinkRetainingCapacity(cursor);
                    hint = null;
                    if (line.items.len > 0) {
                        preview_ok = preview(gpa, &ctx, line.items, size_pt, kitty, w, &hint, &hint_buf, &err_span, &stats);
                    }
                } else if (isCtrl(k, 0x15, 'u')) {
                    // ^U: kill to start of line (up to the cursor).
                    if (cursor > 0) {
                        const tail = line.items[cursor..];
                        @memmove(line.items[0..tail.len], tail);
                        line.shrinkRetainingCapacity(line.items.len - cursor);
                    }
                    cursor = 0;
                    hint = null;
                    if (line.items.len > 0) {
                        preview_ok = preview(gpa, &ctx, line.items, size_pt, kitty, w, &hint, &hint_buf, &err_span, &stats);
                    }
                } else if (isCtrl(k, 0x17, 'w')) {
                    // ^W: delete the whitespace-delimited word before the
                    // cursor.
                    const start = wordStart(line.items, cursor);
                    if (start < cursor) {
                        const tail = line.items[cursor..];
                        @memmove(line.items[start .. start + tail.len], tail);
                        line.shrinkRetainingCapacity(line.items.len - (cursor - start));
                        cursor = start;
                        hint = null;
                        if (line.items.len > 0) {
                            preview_ok = preview(gpa, &ctx, line.items, size_pt, kitty, w, &hint, &hint_buf, &err_span, &stats);
                        }
                    }
                } else if (k.matches(Key.backspace, .{})) {
                    // Delete the codepoint BEFORE the cursor.
                    const start = prevCodepoint(line.items, cursor);
                    if (start < cursor) {
                        const tail = line.items[cursor..];
                        @memmove(line.items[start .. start + tail.len], tail);
                        line.shrinkRetainingCapacity(line.items.len - (cursor - start));
                        cursor = start;
                        hint = null;
                        if (line.items.len > 0) {
                            preview_ok = preview(gpa, &ctx, line.items, size_pt, kitty, w, &hint, &hint_buf, &err_span, &stats);
                        }
                    }
                } else if (k.matches(Key.delete, .{})) {
                    // Delete the codepoint AT the cursor (forward).
                    if (cursor < line.items.len) {
                        const clen = utf8SeqLen(line.items, cursor);
                        const tail = line.items[cursor + clen ..];
                        @memmove(line.items[cursor .. cursor + tail.len], tail);
                        line.shrinkRetainingCapacity(line.items.len - clen);
                        hint = null;
                        if (line.items.len > 0) {
                            preview_ok = preview(gpa, &ctx, line.items, size_pt, kitty, w, &hint, &hint_buf, &err_span, &stats);
                        }
                    }
                } else if (k.matches(Key.escape, .{})) {
                    // Ignore.
                } else if (k.matches(Key.page_up, .{})) {
                    // Zoom in. PageUp/PageDown stand in for +/- (both are
                    // input text); re-render the current or committed src.
                    size_pt = @min(max_size_pt, size_pt + size_step_pt);
                    preview_ok = preview(
                        gpa,
                        &ctx,
                        previewSrc(line.items, committed),
                        size_pt,
                        kitty,
                        w,
                        &hint,
                        &hint_buf,
                        &err_span,
                        &stats,
                    );
                } else if (k.matches(Key.page_down, .{})) {
                    size_pt = @max(min_size_pt, size_pt - size_step_pt);
                    preview_ok = preview(
                        gpa,
                        &ctx,
                        previewSrc(line.items, committed),
                        size_pt,
                        kitty,
                        w,
                        &hint,
                        &hint_buf,
                        &err_span,
                        &stats,
                    );
                } else if (k.matches(Key.f1, .{})) {
                    // Debug: dump the current preview's coverage grid as
                    // an ASCII value map to stderr (F1; see asciiDump).
                    const dbg_src = previewSrc(line.items, committed);
                    if (dbg_src.len > 0) {
                        var dbg_dl = try ztex.render(gpa, dbg_src, size_pt, null);
                        defer dbg_dl.deinit();
                        if (dbg_dl.width > 0) {
                            const dbg_bmp = try rasterize(gpa, &ctx, &dbg_dl);
                            defer gpa.free(dbg_bmp.data);
                            asciiDump(&dbg_bmp);
                        }
                    }
                } else {
                    // Live preview: re-render on every keystroke. On a
                    // parse error the last good preview stays displayed
                    // and the error line appears below it (hint row).
                    try insertKeyText(aa, &line, &cursor, k);
                    hint = null;
                    if (line.items.len > 0) {
                        preview_ok = preview(gpa, &ctx, line.items, size_pt, kitty, w, &hint, &hint_buf, &err_span, &stats);
                    }
                }
            },
            .cpr => |pos| {
                if (!anchor_known) {
                    // The FIRST reply answers the query emitted at the
                    // first render start, BEFORE the first paint; the
                    // region bookkeeping holds every shift applied since
                    // (the CNL reservation), so applyFirstCpr re-anchors.
                    region.applyFirstCpr(pos.row);
                    anchor_known = true;
                } else {
                    // Steady-state: the cursor parks at the band bottom
                    // after every frame, so the bottom-based correction
                    // applies.
                    try region.applyCpr(pos.row, pos.col);
                }
            },
            .winsize => |wsz| try region.resize(wsz.cols, region.height),
            else => {},
        };

        // SIGWINCH: re-measure and rebuild the band.
        if (tty.checkResize()) {
            const wsz = try tty.getWinsize();
            try region.resize(wsz.cols, region.height);
        }

        // Frame: prompt + typed line + cursor marker (band row 0), the
        // hint (band row 2), and the preview image re-placed every tick
        // — cheap, and it keeps the image glued to the anchor.
        region.cur.clear();
        var prompt_buf: [32]u8 = undefined;
        const prompt = std.fmt.bufPrint(&prompt_buf, "formula {d}> ", .{formula_n}) catch
            "formula> ";
        const caret = @min(cursor, line.items.len);
        var col = try region.cur.draw(.{}, prompt, 0, 0);
        const err_active = hint != null and line.items.len > 0;
        col += try drawInput(&region.cur, col, 0, 0, line.items[0..caret], err_active, err_span);
        col += try region.cur.draw(.{}, cursor_marker, col, 0);
        _ = try drawInput(&region.cur, col, 0, caret, line.items[caret..], err_active, err_span);
        if (hint) |h| _ = try region.cur.draw(.{}, h, 0, hint_row);
        // Stage timings, grey, right-aligned on the same row (the error
        // hint, when present, occupies the left).
        var timing_buf: [64]u8 = undefined;
        const timing = std.fmt.bufPrint(
            &timing_buf,
            "parse {d:.2}ms render {d:.2}ms",
            .{ stats.parse_ms, stats.render_ms },
        ) catch "";
        const tl = @as(u16, @intCast(timing.len));
        if (tl < region.width) {
            _ = try region.cur.draw(
                .{ .fg = .bright_black },
                timing,
                region.width - tl,
                hint_row,
            );
        }
        try region.render(w);
        if (kitty and anchor_known and preview_ok) {
            try region.placeAt(w, preview_row, 1, .{
                .id = formula_id,
                .placement = formula_id,
            });
        }
        try w.flush();
    }

    // Park the cursor below the band (the last frame stays in the
    // transcript), then disable the modes detect() enabled and drop the
    // transmitted image.
    try region.exit(w);
    try caps.restore(w);
    if (kitty) try notui.image.kitty.delete(w, formula_id);
    try w.flush();
}

/// Last preview stage timings (milliseconds), shown grey right-aligned on
/// the hint row below the preview.
const PreviewStats = struct {
    parse_ms: f32 = 0,
    render_ms: f32 = 0,
};

/// Monotonic clock in nanoseconds (std.time.Timer was removed in 0.16;
/// the low-level clock_gettime syscall — the ztex bench pattern).
fn monoNs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Milliseconds since `t0` (nanoseconds from `monoNs`).
fn msSince(t0: u64) f32 {
    return @floatCast(@as(f64, @floatFromInt(monoNs() - t0)) / 1e6);
}

/// Render `src` at `size_pt` through the ztex facade, rasterize the draw
/// list, and transmit the bitmap under `formula_id`. A re-transmit
/// replaces the previous image and its placement (kitty spec) — the
/// caller re-places after. `src` must outlive the draw list (the render
/// aliases it); the rasterizer reads it during this call only.
///
/// Returns `EmptyFormula` for blank layouts (no ink), and the parse/
/// layout error for invalid LaTeX — callers keep the last good preview.
/// On a parse error `err_info` (when non-null) is filled with the kind +
/// offending span (ztex.parse.Info). `stats` receives the parse (ztex
/// render) and render (rasterize) durations; on a parse error the render
/// stage keeps its previous value.
fn updatePreview(
    gpa: std.mem.Allocator,
    ctx: *const ztex.Context,
    src: []const u8,
    size_pt: f32,
    kitty: bool,
    w: anytype,
    err_info: ?*ztex.parse.Info,
    stats: *PreviewStats,
) !void {
    if (!kitty) return;
    const t0 = monoNs();
    var dl = ztex.render(gpa, src, size_pt, err_info) catch |err| {
        stats.parse_ms = msSince(t0);
        return err;
    };
    stats.parse_ms = msSince(t0);
    defer dl.deinit();
    if (dl.width <= 0) return error.EmptyFormula;
    const t1 = monoNs();
    const bmp = rasterize(gpa, ctx, &dl) catch |err| {
        stats.render_ms = msSince(t1);
        return err;
    };
    stats.render_ms = msSince(t1);
    defer gpa.free(bmp.data);
    try notui.image.kitty.transmit(w, .{
        .format = .rgba,
        .width = bmp.width,
        .height = bmp.height,
        .id = formula_id,
    }, bmp.data);
}

/// The ztex parse errors (the lexer/parser kinds that fill `Info`).
/// `formatErr` reads the Info only for these — other errors (layout,
/// allocation) leave it untouched.
fn isParseError(err: anyerror) bool {
    return switch (err) {
        error.DanglingEscape,
        error.InvalidUtf8,
        error.UnexpectedRGroup,
        error.UnexpectedScript,
        error.DoubleScript,
        error.UnknownCommand,
        error.MissingArgument,
        error.MissingScript,
        error.UnclosedGroup,
        error.UnexpectedMiddle,
        error.UnknownEnvironment,
        error.MismatchedEnd,
        error.UnclosedEnvironment,
        error.StackOverflow,
        => true,
        else => false,
    };
}

/// Draw `text` — a slice of the input line at absolute byte offset `off` —
/// with the error span (when `active`) rendered red; everything else in
/// the default style. Used for the two caret-split halves of the line.
fn drawInput(
    cur: *notui.buffer.Buffer,
    x: u16,
    y: u16,
    off: usize,
    text: []const u8,
    active: bool,
    span: ztex.atom.Span,
) !u16 {
    if (!active) return cur.draw(.{}, text, x, y);
    const lo = @max(span.start, off);
    const hi = @min(span.end, off + text.len);
    if (hi <= lo) return cur.draw(.{}, text, x, y);
    // draw() returns the relative width; track the absolute column.
    var cx = x;
    cx += try cur.draw(.{}, text[0 .. lo - off], cx, y);
    cx += try cur.draw(.{ .fg = .red }, text[lo - off .. hi - off], cx, y);
    cx += try cur.draw(.{}, text[hi - off ..], cx, y);
    return cx - x;
}

/// Render `err` into `hint` (a one-line band message): the ztex parse
/// errors show the TeX-style message + 1-based line:col of the offending
/// span; anything else falls back to the bare error name. `err_span`
/// receives the offending span (for the red input-line marking).
fn formatErr(
    hint: *?[]const u8,
    hint_buf: []u8,
    err: anyerror,
    info: *const ztex.parse.Info,
    src: []const u8,
    err_span: *ztex.atom.Span,
) void {
    if (isParseError(err)) {
        err_span.* = info.span;
        // 1-based line:col of the span start (formulas are single-line in
        // practice, but the computation is general).
        var line: u32 = 1;
        var col: u32 = 1;
        const start = @min(info.span.start, src.len);
        for (src[0..start]) |b| {
            if (b == '\n') {
                line += 1;
                col = 1;
            } else {
                col += 1;
            }
        }
        hint.* = std.fmt.bufPrint(
            hint_buf,
            "{s} at {d}:{d}",
            .{ info.message(), line, col },
        ) catch null;
        return;
    }
    hint.* = std.fmt.bufPrint(hint_buf, "latex error: {s}", .{@errorName(err)}) catch null;
}

/// `updatePreview` as a predicate for the live-preview paths: true when a
/// fresh bitmap is on screen. On any error the last good preview stays
/// displayed and `hint` gets the error (rendered below the preview at
/// `hint_row`); on success the hint clears.
fn preview(
    gpa: std.mem.Allocator,
    ctx: *const ztex.Context,
    src: []const u8,
    size_pt: f32,
    kitty: bool,
    w: anytype,
    hint: *?[]const u8,
    hint_buf: []u8,
    err_span: *ztex.atom.Span,
    stats: *PreviewStats,
) bool {
    var info: ztex.parse.Info = undefined;
    updatePreview(gpa, ctx, src, size_pt, kitty, w, &info, stats) catch |err| {
        formatErr(hint, hint_buf, err, &info, src, err_span);
        return false;
    };
    hint.* = null;
    return true;
}

/// Rasterize a draw list into a white-on-transparent RGBA bitmap sized to the
/// layout bounds (width × (height+depth), pt→px at 96 dpi — the svg.zig
/// viewBox convention without the browser padding).
fn rasterize(
    gpa: std.mem.Allocator,
    ctx: *const ztex.Context,
    dl: *ztex.draw.DrawList,
) !Bitmap {
    const width: u32 = @intFromFloat(@ceil(dl.width * pt_px));
    const height: u32 = @intFromFloat(@ceil((dl.height + dl.depth) * pt_px));
    if (width == 0 or height == 0) return error.EmptyFormula;
    const data = try gpa.alloc(u8, @as(usize, width) * @as(usize, height) * 4);
    errdefer gpa.free(data);
    // White RGB everywhere, alpha 0 (transparent): drawables only ever
    // touch the alpha channel, so the terminal's background shows through
    // the un-inked pixels.
    var px: usize = 0;
    while (px < data.len) : (px += 4) {
        data[px] = 0xFF;
        data[px + 1] = 0xFF;
        data[px + 2] = 0xFF;
        data[px + 3] = 0;
    }

    for (dl.items.items) |d| {
        switch (d) {
            .text => |t| try drawText(gpa, ctx, dl, data, width, height, t),
            .rect => |r| fillInk(
                data,
                width,
                height,
                r.x * pt_px,
                (r.x + r.w) * pt_px,
                (r.y + dl.height) * pt_px,
                (r.y + r.h + dl.height) * pt_px,
            ),
            .line => |l| {
                // v1: stroke the segment as its AABB inflated by half the
                // stroke width — LM formulas rarely emit lines.
                const half = 0.5 * l.width;
                fillInk(
                    data,
                    width,
                    height,
                    (@min(l.x0, l.x1) - half) * pt_px,
                    (@max(l.x0, l.x1) + half) * pt_px,
                    (@max(l.y0, l.y1) + half + dl.height) * pt_px,
                    (@min(l.y0, l.y1) - half + dl.height) * pt_px,
                );
            },
        }
    }
    return .{ .data = data, .width = width, .height = height };
}

/// Rasterize one glyph: decode its utf-8 codepoint, pull the quadratic
/// outline from the style's face, scale em→px by the drawable's own size
/// and translate to the absolute bitmap baseline, then sweep the coverage
/// rows in its pixel bbox and write the coverage into the alpha channel
/// (white RGB, per-pixel transparency — the terminal background shows).
/// Skips glyphs the face cannot serve (missing cmap entry, empty glyph).
fn drawText(
    gpa: std.mem.Allocator,
    ctx: *const ztex.Context,
    dl: *ztex.draw.DrawList,
    data: []u8,
    width: u32,
    height: u32,
    t: ztex.draw.Text,
) !void {
    const cp: u21 = blk: {
        if (t.bytes.len == 1) break :blk t.bytes[0];
        if (t.bytes.len == 2) break :blk std.unicode.utf8Decode2(t.bytes[0..2].*) catch return;
        if (t.bytes.len == 3) break :blk std.unicode.utf8Decode3(t.bytes[0..3].*) catch return;
        if (t.bytes.len == 4) break :blk std.unicode.utf8Decode4(t.bytes[0..4].*) catch return;
        return;
    };
    // v1 face scope: math-italic glyphs come from the LM Math face
    // (U+1D465 etc. — LM Roman Italic's cmap lacks them); every other
    // style maps to the regular LM Roman face (an upright fallback for
    // bold/bb/cal/frak/sans/mono).
    const face = switch (t.style) {
        .italic => ctx.fonts.mathFace(),
        else => ctx.fonts.romanFace(false),
    };
    const gid = face.glyphIndex(cp) orelse return;
    var outline = try face.glyphOutline(gpa, gid);
    defer outline.deinit();
    if (outline.curves.items.len == 0) return;

    // The coverage sweep accumulates signed area with the interior to the
    // RIGHT of travel (CW in Y-up), but the LM faces wind CCW (interior
    // left, the CFF convention) — without normalization every glyph would
    // sweep negative and clamp to nothing. Contours are consecutive runs
    // (p2[i] == p0[i+1]); reverse each run and swap each curve's endpoints.
    var run_start: usize = 0;
    var i: usize = 0;
    while (i < outline.curves.items.len) : (i += 1) {
        const at_end = i + 1 == outline.curves.items.len;
        const boundary = !at_end and (outline.curves.items[i].p2[0] !=
            outline.curves.items[i + 1].p0[0] or outline.curves.items[i].p2[1] !=
            outline.curves.items[i + 1].p0[1]);
        if (!at_end and !boundary) continue;
        // Reverse run [run_start, i] inclusive, swapping p0/p2 per curve.
        var lo = run_start;
        var hi = i;
        while (lo < hi) : ({
            lo += 1;
            hi -= 1;
        }) {
            const tmp = outline.curves.items[lo];
            outline.curves.items[lo] = .{
                .p0 = outline.curves.items[hi].p2,
                .p1 = outline.curves.items[hi].p1,
                .p2 = outline.curves.items[hi].p0,
            };
            outline.curves.items[hi] = .{ .p0 = tmp.p2, .p1 = tmp.p1, .p2 = tmp.p0 };
        }
        if (lo == hi) {
            const c = outline.curves.items[lo];
            outline.curves.items[lo] = .{ .p0 = c.p2, .p1 = c.p1, .p2 = c.p0 };
        }
        run_start = i + 1;
    }

    const gscale = t.size * pt_px / @as(f32, @floatCast(@as(f64, @floatFromInt(face.unitsPerEm()))));
    const ox = t.x * pt_px;
    const h_f: f32 = @floatFromInt(height);
    // Sweep-space baseline: the sweep is Y-up with 1x1 windows at
    // integer offsets (window wy covers [wy, wy+1) = bitmap row
    // height-1-wy), so the top-down baseline row `baseline` flips to
    // `h_f - baseline` and glyph em y (Y-up) ADDS from there.
    const ybase = h_f - (t.y + dl.height) * pt_px;

    // Transform the outline in place into the sweep's coordinate space:
    // x is the bitmap column, y the Y-up window offset (both in window
    // units). Track the ink bbox (windows + columns) as we go.
    var min_x: f32 = std.math.inf(f32);
    var max_x: f32 = -std.math.inf(f32);
    var min_y: f32 = std.math.inf(f32);
    var max_y: f32 = -std.math.inf(f32);
    for (outline.curves.items) |*c| {
        const points = [_]*[2]f32{ &c.p0, &c.p1, &c.p2 };
        for (points) |p| {
            const fx = ox + p[0] * gscale;
            const fy = ybase + p[1] * gscale;
            p[0] = fx;
            p[1] = fy;
            min_x = @min(min_x, fx);
            max_x = @max(max_x, fx);
            min_y = @min(min_y, fy);
            max_y = @max(max_y, fy);
        }
    }

    // Clamp the window and column spans to the bitmap (glyph ink may
    // overflow the layout bounds).
    const h_i: i64 = @intCast(height);
    var wy0: i64 = @intFromFloat(@floor(min_y));
    var wy1: i64 = @intFromFloat(@floor(max_y));
    if (wy0 >= h_i or wy1 < 0) return;
    wy0 = @max(wy0, 0);
    wy1 = @min(wy1, h_i - 1);

    var cx0: i64 = @intFromFloat(@floor(min_x));
    var cx1: i64 = @intFromFloat(@ceil(max_x));
    cx0 = @max(cx0, 0);
    cx1 = @min(cx1, @as(i64, @intCast(width)));
    if (cx1 <= cx0) return;
    const ncols: usize = @intCast(cx1 - cx0);
    const row_buf = try dl.glyph_arena.allocator().alloc(f32, ncols);
    // Structurally identical to coverage.QuadCurve (3x [2]f32) — reuse
    // the transformed array without copying.
    const cov_curves: []const coverage.QuadCurve =
        std.mem.bytesAsSlice(coverage.QuadCurve, std.mem.sliceAsBytes(outline.curves.items));

    var wy = wy0;
    while (wy <= wy1) : (wy += 1) {
        coverage.coverageRow(cov_curves, @floatFromInt(wy), @floatFromInt(cx0), row_buf);
        const row: usize = @intCast(h_i - 1 - wy);
        for (row_buf, 0..) |c, k| {
            if (c <= 0.0) continue;
            // RGB is already white; the alpha channel carries the
            // coverage (SRC-OVER of white over white = max alpha).
            const a: u8 = @intFromFloat(@round(c * 255.0));
            const idx = (row * @as(usize, width) + @as(usize, @intCast(cx0)) + k) * 4;
            data[idx + 3] = @max(data[idx + 3], a);
        }
    }
}

/// Fill the pixel span [x0f, x1f) × [y0f, y1f) (top-down floats, clamped
/// to the bitmap) with fully-inked pixels (alpha 255; RGB stays white) —
/// fraction bars, rules, lines.
fn fillInk(data: []u8, width: u32, height: u32, x0f: f32, x1f: f32, y0f: f32, y1f: f32) void {
    const c0: i64 = @max(@as(i64, @intFromFloat(@floor(x0f))), 0);
    const c1: i64 = @min(@as(i64, @intFromFloat(@ceil(x1f))), @as(i64, @intCast(width)));
    const r0: i64 = @max(@as(i64, @intFromFloat(@floor(y0f))), 0);
    const r1: i64 = @min(@as(i64, @intFromFloat(@ceil(y1f))), @as(i64, @intCast(height)));
    var r = r0;
    while (r < r1) : (r += 1) {
        var c = c0;
        while (c < c1) : (c += 1) {
            const idx = (@as(usize, @intCast(r)) * @as(usize, width) + @as(usize, @intCast(c))) * 4;
            data[idx + 3] = 0xFF;
        }
    }
}

/// Print the bitmap's alpha channel as an ASCII value map to stderr:
/// one digit per pixel (0 = fully transparent .. 9 = fully inked), one
/// line per bitmap row, top-down — the pixel-level debug view.
fn asciiDump(bmp: *const Bitmap) void {
    var row: usize = 0;
    while (row < bmp.height) : (row += 1) {
        var line: [256]u8 = undefined;
        var n: usize = 0;
        var col: usize = 0;
        while (col < bmp.width and n + 1 < line.len) : (col += 1) {
            const a = bmp.data[(row * bmp.width + col) * 4 + 3];
            line[n] = '0' + @as(u8, @intCast((@as(u32, a) * 10) / 256));
            n += 1;
        }
        std.debug.print("{s}\n", .{line[0..n]});
    }
}

/// The source to re-render: the typed line when non-empty (live preview),
/// else the last committed formula (kept on display).
fn previewSrc(line: []const u8, committed: []const u8) []const u8 {
    return if (line.len > 0) line else committed;
}

/// True for a ctrl+c keypress in either decoding.
fn isCtrlC(k: Key) bool {
    return isCtrl(k, Key.ctrl_c, 'c');
}

/// Same for ctrl+d (0x04 → 'd' + ctrl in legacy ground state).
fn isCtrlD(k: Key) bool {
    return isCtrl(k, ctrl_d, 'd');
}

/// Insert the key's text at the cursor — the §3 lifetime contract:
/// `Key.text` is valid only until the next read, so it must be copied
/// before that. Keys without text (control chars, PUA function /
/// navigation keys, the multicodepoint marker) produce nothing.
fn insertKeyText(aa: std.mem.Allocator, line: *std.ArrayList(u8), cursor: *usize, k: Key) !void {
    var text_buf: [4]u8 = undefined;
    const text: []const u8 = if (k.text) |t|
        t
    else blk: {
        const cp = k.codepoint;
        if (cp < 0x20 or cp == 0x7F or (cp >= 0xE000 and cp <= 0xF8FF) or cp > 0x10FFFF) return;
        const n = try std.unicode.utf8Encode(cp, &text_buf);
        break :blk text_buf[0..n];
    };
    try line.insertSlice(aa, cursor.*, text);
    cursor.* += text.len;
}

// ── cursor helpers (zigzag/skript_repl TextInput semantics) ─────────

/// UTF-8 sequence length of the codepoint starting at buf[i].
fn utf8SeqLen(buf: []const u8, i: usize) usize {
    return std.unicode.utf8ByteSequenceLength(buf[i]) catch 1;
}

/// Byte index of the codepoint BEFORE `cursor` (walks back over
/// continuation bytes; never splits a utf-8 sequence).
fn prevCodepoint(buf: []const u8, cursor: usize) usize {
    if (cursor == 0) return 0;
    var p = cursor - 1;
    while (p > 0 and (buf[p] & 0xC0) == 0x80) p -= 1;
    return p;
}

/// Byte index of the start of the whitespace-delimited word before
/// `cursor` (skip whitespace, then word chars).
fn wordStart(buf: []const u8, cursor: usize) usize {
    var c = cursor;
    while (c > 0 and std.ascii.isWhitespace(buf[c - 1])) c -= 1;
    while (c > 0 and !std.ascii.isWhitespace(buf[c - 1])) c -= 1;
    return c;
}

/// True for a control-key press in either decoding: kitty CSI-u reports
/// the control character itself; the legacy ground-state path maps the
/// byte to the letter + ctrl (parser.zig parseGround, libvaxis
/// convention). The examples must accept both.
fn isCtrl(k: Key, cp: u21, letter: u8) bool {
    return k.matches(cp, .{}) or k.matches(letter, .{ .ctrl = true });
}

/// One plain frame, no interactive sequences: the default formula
/// rasterized and dumped as a P6 PPM to stdout, then a one-line summary
/// (drawable counts + pixel size) — the piped verification path.
fn runPlain(gpa: std.mem.Allocator, io: std.Io, ctx: *const ztex.Context, src: []const u8, ascii: bool) !void {
    var dl = try ztex.render(gpa, src, default_size_pt, null);
    defer dl.deinit();
    const bmp = try rasterize(gpa, ctx, &dl);
    defer gpa.free(bmp.data);

    // ASCII debug view: the coverage grid as digit values (0 = fully
    // transparent .. 9 = fully inked), one line per bitmap row, top-down.
    if (ascii) {
        asciiDump(&bmp);
        return;
    }

    var texts: usize = 0;
    var rects: usize = 0;
    var lines: usize = 0;
    for (dl.items.items) |d| switch (d) {
        .text => texts += 1,
        .rect => rects += 1,
        .line => lines += 1,
    };

    // Piped-path self-check (stderr, not the PPM stream): the raster must
    // contain BOTH inked (alpha > 0) and transparent (alpha == 0) pixels
    // — a sanity gate that the coverage isn't inverted or empty.
    var ink_px: usize = 0;
    var clear_px: usize = 0;
    var i: usize = 0;
    while (i < bmp.data.len) : (i += 4) {
        if (bmp.data[i + 3] > 0) ink_px += 1 else clear_px += 1;
    }
    const ok = ink_px > 0 and clear_px > 0;
    std.debug.print("formula self-check: ink={d} transparent={d} — {s}\n", .{
        ink_px, clear_px, if (ok) "ok (both present)" else "MISSING INK OR TRANSPARENCY",
    });

    const stdout = std.Io.File.stdout();
    var header: [64]u8 = undefined;
    const hdr = try std.fmt.bufPrint(&header, "P6\n{d} {d}\n255\n", .{ bmp.width, bmp.height });
    try stdout.writeStreamingAll(io, hdr);

    // PPM has no alpha: dump the ALPHA channel as grayscale (coverage*255,
    // fully transparent = black) — the P6 payload.
    const rgb = try gpa.alloc(u8, @as(usize, bmp.width) * @as(usize, bmp.height) * 3);
    defer gpa.free(rgb);
    const ww: usize = bmp.width;
    const hh: usize = bmp.height;
    for (0..hh) |r| {
        for (0..ww) |c| {
            const s = (r * ww + c) * 4;
            const d = (r * ww + c) * 3;
            rgb[d + 0] = bmp.data[s + 3];
            rgb[d + 1] = bmp.data[s + 3];
            rgb[d + 2] = bmp.data[s + 3];
        }
    }
    try stdout.writeStreamingAll(io, rgb);

    var summary: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(
        &summary,
        "formula {s}: {d} text, {d} rect, {d} line; {d}x{d} px\n",
        .{ src, texts, rects, lines, bmp.width, bmp.height },
    );
    try stdout.writeStreamingAll(io, msg);
}
