//! kitty_image_showcase: an extensive kitty-graphics demo — a 4-row
//! inline band exercising images WITH text, animation, and scrolling.
//!
//! Row 0 — a text line plus a MOVING image: a 12x12 RGBA ball (a
//! procedurally generated filled circle) bouncing horizontally across
//! the row width, re-placed at a new column every tick (~100 ms).
//! Re-placing the same (id, placement) pair is the animation
//! mechanism (`a=p` moves the placement to the cursor; `c`/`r` span
//! it in cells — here 2x1).
//!
//! Row 1 — a FLIP-BOOK: 6 pre-transmitted 12x12 RGBA frames of a
//! rotating 4-point star (ids 100..105); each tick places the current
//! frame id into a fixed placement slot (500), cycling — animation via
//! placement swap, no accumulation.
//!
//! Row 2 — a GALLERY: two 8x8 RGBA sprites (a red square and a blue
//! square) placed at cols 1 and 13 (4x1 cells) with text drawn
//! between and around them — text+image interleaving in one band row.
//!
//! Row 3 — status: a spinning base-ui Spinner plus "images: ON" or
//! "images: unsupported".
//!
//! SCROLLING: every 15 ticks a timestamped "scroll line N …" is queued
//! via `region.append(.line)` (print-above), marching the band down one
//! row per append. Every sprite — ball, star, gallery — is re-placed at
//! the current anchor each tick so they stay glued to the band
//! (placements are cell-anchored, and the band text moves by repaint,
//! not by terminal scroll — a placement left alone would detach).
//! Placements are emitted only while `region.anchorRow()` is non-zero:
//! the anchor is 0 until a CPR reply measures it, and again after every
//! geometry change until the next reply.
//! Appends stop when the band bottom reaches the last screen row: the
//! region's repaint model cannot write past the bottom without the
//! terminal scrolling mid-paint and garbling the band.
//!
//! Transmit/place/delete only happen when `caps.kitty_graphics` is set
//! (interactive implied); otherwise the same 4 text rows render with the
//! "unsupported" hint and no image bytes. On quit (q / Ctrl+C):
//! `region.exit` → `caps.restore` → delete ALL images (`delete(w, null)`)
//! → flush.
//!
//! Piped / non-TTY stdin degrades to one plain 4-row frame (architecture
//! §4.8): the tty is never touched and no image sequences are emitted —
//! the piped run prints exactly one frame and exits 0.

const std = @import("std");
const notui = @import("notui");

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

/// Loop pacing: nextTimeout returns null on timeout, advancing one tick
/// (the animation + scroll cadence).
const tick_ms: i32 = 100;

/// Band height in terminal rows: the four rows the showcase owns.
const band_height: u16 = 4;

/// A scroll line is appended above the band every this many ticks.
const scroll_every_ticks: u32 = 15;

/// Cache ids. The flip-book owns a contiguous block 100..105; the
/// remaining ids are explicit so `place` can address each image.
const star_id_base: u32 = 100;
const star_frame_count: u32 = 6;
const ball_id: u32 = 200;
const square_red_id: u32 = 300;
const square_blue_id: u32 = 301;

/// Fixed cell (col 12, 1-indexed) the flip-book cycles at.
const star_col: u32 = 12;

// ── frame generation (pure Zig, comptime, no deps) ─────────────

/// The bouncing ball: a 12x12 filled orange circle, shaded darker toward
/// the rim, with a small specular highlight at the top-left. 576 bytes —
/// a single-chunk transmit.
const ball_w: u32 = 12;
const ball_h: u32 = 12;
const ball_rgba = blk: {
    @setEvalBranchQuota(10_000);
    var px: [ball_w * ball_h * 4]u8 = undefined;
    const center: f64 = @as(f64, @floatFromInt(ball_w - 1)) / 2.0; // 5.5
    const radius: f64 = 5.0;
    for (0..ball_h) |y| {
        for (0..ball_w) |x| {
            const i = (y * ball_w + x) * 4;
            const dx: f64 = @as(f64, @floatFromInt(x)) + 0.5 - center;
            const dy: f64 = @as(f64, @floatFromInt(y)) + 0.5 - center;
            const d = @sqrt(dx * dx + dy * dy);
            if (d > radius) {
                px[i + 0] = 0;
                px[i + 1] = 0;
                px[i + 2] = 0;
                px[i + 3] = 0;
                continue;
            }
            const depth = 1.0 - 0.35 * (d / radius);
            const hx: f64 = @as(f64, @floatFromInt(x)) + 0.5 - 3.5;
            const hy: f64 = @as(f64, @floatFromInt(y)) + 0.5 - 3.5;
            const highlight: f64 = if (hx * hx + hy * hy <= 1.5 * 1.5) 1.0 else 0.0;
            px[i + 0] = @intFromFloat(@min(255.0 * depth + 90.0 * highlight, 255.0));
            px[i + 1] = @intFromFloat(@min(140.0 * depth + 70.0 * highlight, 255.0));
            px[i + 2] = @intFromFloat(@min(30.0 * depth + 50.0 * highlight, 255.0));
            px[i + 3] = 0xff;
        }
    }
    break :blk px;
};

/// The flip-book: 6 frames of a rotating 4-point star. Each pixel is
/// inside when the rotated astroid holds: `sqrt(|x'|) + sqrt(|y'|) <=
/// sqrt(R)`, with (x', y') the pixel rotated by `frame * 15°`. The
/// 4-point star has 90° symmetry, so 6 × 15° = 90° cycles seamlessly.
const star_w: u32 = 12;
const star_h: u32 = 12;
const star_frames = blk: {
    @setEvalBranchQuota(50_000);
    var frames: [star_frame_count][star_w * star_h * 4]u8 = undefined;
    const center: f64 = 5.5;
    const radius: f64 = 5.0;
    for (0..star_frame_count) |f| {
        const theta: f64 = @as(f64, @floatFromInt(f)) * (std.math.pi / 6.0);
        const cos_t = @cos(theta);
        const sin_t = @sin(theta);
        const px = &frames[f];
        for (0..star_h) |y| {
            for (0..star_w) |x| {
                const i = (y * star_w + x) * 4;
                const dx: f64 = @as(f64, @floatFromInt(x)) + 0.5 - center;
                const dy: f64 = @as(f64, @floatFromInt(y)) + 0.5 - center;
                const rx = dx * cos_t - dy * sin_t;
                const ry = dx * sin_t + dy * cos_t;
                if (@sqrt(@abs(rx)) + @sqrt(@abs(ry)) <= @sqrt(radius)) {
                    px[i + 0] = 0x30;
                    px[i + 1] = 0xff;
                    px[i + 2] = 0x90;
                    px[i + 3] = 0xff;
                } else {
                    px[i + 0] = 0;
                    px[i + 1] = 0;
                    px[i + 2] = 0;
                    px[i + 3] = 0;
                }
            }
        }
    }
    break :blk frames;
};

/// The gallery sprites: solid 8x8 red and blue squares (256 bytes each).
const square_red = squareFrame(0xff, 0x00, 0x00);
const square_blue = squareFrame(0x00, 0x00, 0xff);

fn squareFrame(r: u8, g: u8, b: u8) [8 * 8 * 4]u8 {
    var px: [8 * 8 * 4]u8 = undefined;
    for (0..px.len / 4) |i| {
        px[i * 4 + 0] = r;
        px[i * 4 + 1] = g;
        px[i * 4 + 2] = b;
        px[i * 4 + 3] = 0xff;
    }
    return px;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // Non-TTY degradation: when stdin is not a terminal, skip the tty
    // entirely (Tty.init opens /dev/tty, which is wrong and can fail
    // without a controlling terminal) and print one plain frame.
    if (!Tty.isTty(std.posix.STDIN_FILENO)) {
        return runPlain(gpa, io);
    }

    var tty = try Tty.init(io);
    defer tty.deinit();
    try tty.makeRaw();
    defer tty.restore();

    var parser: notui.parser = .{};
    const caps = try notui.caps.Capabilities.detect(gpa, &tty, &parser);

    var region = try Region.init(gpa, .{ .height = band_height });
    defer region.deinit();

    // Size the band to the terminal before the first frame.
    const ws = try tty.getWinsize();
    try region.resize(ws.cols, ws.rows, band_height);

    const w = tty.writer();

    // Transmit every image once (transmits are position-independent).
    // Placements need the band's ABSOLUTE screen rows, which are only
    // known once a CPR reply has measured them (`region.anchorRow()`,
    // see the `.cpr` arm below): `region.placeAt` CUP's to the absolute
    // cell, places, then parks back at the band bottom. Every sprite is
    // re-placed each tick (cell-anchored placements would detach from
    // the band otherwise — the band text moves by repaint, not terminal
    // scroll), keeping them glued to the band.
    if (caps.kitty_graphics) {
        try transmitAll(w);
        try w.flush();
    }

    var reader = Reader.init(&tty);

    // Animation + scroll state. `screen_rows` caps the scroll appends:
    // the region's repaint model paints the band exactly `height` rows
    // from the cursor and cannot write past the last screen row (a
    // bottom write scrolls mid-paint, garbling the band), so appends
    // stop once the band bottom reaches the bottom of the screen.
    var screen_rows: u32 = ws.rows;
    var tick: u32 = 0;
    var scroll_n: u32 = 0;
    var ball_col: u32 = 0;
    var ball_dir: i32 = 1;
    var frame_index: u32 = 0;
    var spinner: notui.component.Spinner = .{
        .label = if (caps.kitty_graphics) "images: ON" else "images: unsupported",
    };

    while (true) {
        const ev = reader.nextTimeout(tick_ms) catch break;
        if (ev) |e| switch (e) {
            .key_press => |k| {
                // Ctrl+C arrives as a normal key event (raw mode: ISIG
                // off); the app decides to quit. Its decoding depends on
                // the terminal protocol: kitty CSI-u reports the control
                // char itself (0x03); legacy ground state maps byte 0x03
                // to 'c' + ctrl. Check both forms.
                if (isCtrlC(k)) break;
                if (k.matches('q', .{})) break;
            },
            .cpr => |pos| {
                // Every reply answers a post-paint query: the cursor
                // parks at the band bottom, so `applyCpr` maps the
                // reply back to the band top. First and later replies
                // take this same path — each one re-measures the anchor
                // from scratch.
                try region.applyCpr(pos.row, pos.col);
            },
            .winsize => |wsz| {
                screen_rows = wsz.rows;
                try region.resize(wsz.cols, wsz.rows, band_height);
            },
            else => {},
        };

        // SIGWINCH: re-measure and rebuild the band.
        if (tty.checkResize()) {
            const wsz = try tty.getWinsize();
            screen_rows = wsz.rows;
            try region.resize(wsz.cols, wsz.rows, band_height);
            region.repaintAll();
        }

        // The moving ball: bounce horizontally across the row width.
        const max_col: u32 = region.width -| 1;
        if (ball_dir > 0) {
            if (ball_col >= max_col) ball_dir = -1 else ball_col += 1;
        } else {
            if (ball_col == 0) ball_dir = 1 else ball_col -= 1;
        }

        // The flip-book: advance to the next star frame.
        frame_index = (frame_index + 1) % star_frame_count;

        // Every ~15 ticks push a timestamped line above the band,
        // marching it down one row (print-above) — until the band
        // bottom reaches the last screen row, where further appends
        // would scroll the terminal mid-paint and garble the band. The
        // `.line` slice points into `line_buf`, alive through the
        // render that flushes the append queue this same iteration. The
        // bound is read off a MEASURED band top only: `anchorRow()` is
        // 0 while the anchor is unknown or invalidated, and treating
        // that as "band at row 0" would keep appending.
        var line_buf: [64]u8 = undefined;
        if (tick % scroll_every_ticks == 0 and region.anchorRow() > 0 and
            region.anchorRow() + band_height <= screen_rows)
        {
            scroll_n += 1;
            try region.append(.{ .line = scrollLine(io, &line_buf, scroll_n, region.width) });
        }

        try drawBand(io, &region, &spinner);

        try region.render(w);
        if (caps.kitty_graphics and region.anchorRow() > 0) {
            // Re-place = animation: `region.placeAt` CUP's to the
            // absolute cell (current anchor + band row), places, then
            // parks back — the images stay glued to the band as append
            // lines march it down (placements are cell-anchored, so a
            // placement left alone would detach: the band text moves
            // by repaint, not by terminal scroll). Placement ids make
            // re-placing move the existing placement instead of
            // stacking a new one (the ball and the gallery squares
            // reuse their image ids; the flip-book cycles frame ids
            // into fixed slot 500). The guard skips every placement
            // while the anchor is unknown or invalidated — a stale
            // absolute row would land the sprites off the band — and
            // the next measured anchor re-places them all.
            try region.placeAt(w, 0, ball_col + 1, .{
                .id = ball_id,
                .placement = ball_id,
                .size = .{ .width = 2, .height = 1 },
            });
            try region.placeAt(w, 1, star_col, .{
                .id = star_id_base + frame_index,
                .placement = 500,
                .size = .{ .width = 2, .height = 1 },
            });
            try region.placeAt(w, 2, 1, .{
                .id = square_red_id,
                .placement = square_red_id,
                .size = .{ .width = 4, .height = 1 },
            });
            try region.placeAt(w, 2, 13, .{
                .id = square_blue_id,
                .placement = square_blue_id,
                .size = .{ .width = 4, .height = 1 },
            });
        }

        try w.flush();
        tick += 1;
    }

    // Park the cursor below the band; the last frame stays in the
    // transcript (nothing is cleared). Then disable the terminal modes
    // detect() enabled and drop every transmitted image (`null` = all).
    try region.exit(w);
    try caps.restore(w);
    if (caps.kitty_graphics) try notui.image.kitty.delete(w, null);
    try w.flush();
}

/// Transmit every frame once into the kitty cache: the 6 flip-book star
/// frames (ids 100..105), the ball (200), and the two gallery squares
/// (300/301). All payloads are small enough for single-chunk transmits.
fn transmitAll(w: anytype) !void {
    for (0..star_frame_count) |f| {
        try notui.image.kitty.transmit(w, .{
            .format = .rgba,
            .width = star_w,
            .height = star_h,
            .id = star_id_base + @as(u32, @intCast(f)),
        }, &star_frames[f]);
    }
    try notui.image.kitty.transmit(w, .{
        .format = .rgba,
        .width = ball_w,
        .height = ball_h,
        .id = ball_id,
    }, &ball_rgba);
    try notui.image.kitty.transmit(w, .{
        .format = .rgba,
        .width = 8,
        .height = 8,
        .id = square_red_id,
    }, &square_red);
    try notui.image.kitty.transmit(w, .{
        .format = .rgba,
        .width = 8,
        .height = 8,
        .id = square_blue_id,
    }, &square_blue);
}

/// Paint the 4-row band. Row 0: title text (the ball is a placement, not
/// buffer content — it moves over this text). Row 1: flip-book label.
/// Row 2: gallery — sprites placed at cols 0 and 12, "A"/"B" between and
/// after them, and a caption flowing under the sprites (text+image
/// interleaving: the placed sprites render above the buffer text at
/// their cells). Row 3: the spinner + status label.
fn drawBand(io: std.Io, region: *Region, spinner: *notui.component.Spinner) !void {
    region.cur.clear();
    _ = try region.cur.draw(.{}, "kitty showcase — [q]uit", 0, 0);
    _ = try region.cur.draw(.{}, "flip-book:", 0, 1);
    _ = try region.cur.draw(.{}, "A", 2, 2);
    _ = try region.cur.draw(.{}, "B", 14, 2);
    _ = try region.cur.draw(.{}, "gallery — red & blue 8x8 sprites, text between and around", 4, 2);
    const now = std.Io.Timestamp.now(io, .awake);
    _ = try spinner.draw(&region.cur, 0, 3, now);
}

/// Format one scrollback line: "scroll line N HH:MM:SS" (wall clock via
/// the `.real` clock). ASCII-only so truncating at the region width is
/// byte-safe — the `.line` then occupies exactly one terminal row.
/// Truncated to `width` columns (guards a very narrow terminal).
fn scrollLine(io: std.Io, buf: []u8, n: u32, width: u16) []const u8 {
    const secs: u64 = @intCast(std.Io.Timestamp.now(io, .real).toSeconds());
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const ds = es.getDaySeconds();
    const line = std.fmt.bufPrint(buf, "scroll line {d} {d:0>2}:{d:0>2}:{d:0>2}", .{
        n,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch return "";
    const cols: usize = width;
    return line[0..@min(line.len, cols)];
}

/// True for a ctrl+c keypress in either decoding: kitty CSI-u reports
/// the control character itself (0x03); the legacy ground-state path
/// maps byte 0x03 to 'c' + ctrl (parser.zig parseGround, libvaxis
/// convention). The examples must accept both.
fn isCtrlC(k: Key) bool {
    return k.matches(Key.ctrl_c, .{}) or k.matches('c', .{ .ctrl = true });
}

/// One plain frame, no interactive sequences: the 4 text rows of the
/// band without any image bytes (piped run).
fn runPlain(gpa: std.mem.Allocator, io: std.Io) !void {
    var region = try Region.init(gpa, .{
        .height = band_height,
        .append_lines = false,
        .interactive = false,
    });
    defer region.deinit();

    var spinner: notui.component.Spinner = .{ .label = "images: unsupported" };
    try drawBand(io, &region, &spinner);

    var buf: [1024]u8 = undefined;
    var fw = std.Io.File.stdout().writerStreaming(io, &buf);
    const w = &fw.interface;
    try region.render(w);
    try region.exit(w);
    try w.flush();
}
