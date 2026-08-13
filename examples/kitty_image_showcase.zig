//! kitty_image_showcase: an extensive kitty-graphics demo — a 4-row
//! inline band exercising images WITH text, animation, and scrolling.
//!
//! Row 0 — a text line plus a MOVING image: a 12x12 RGBA ball (a
//! procedurally generated filled circle) bouncing horizontally across
//! the row width, re-placed at a new column every tick (~100 ms).
//! Re-placing the same id is the animation mechanism (`a=p` moves the
//! placement; `size` scales it in pixels).
//!
//! Row 1 — a FLIP-BOOK: 6 pre-transmitted 12x12 RGBA frames of a
//! rotating 4-point star (ids 100..105); each tick places the current
//! frame id at a fixed cell, cycling — animation via placement swap.
//!
//! Row 2 — a STATIC GALLERY: two 8x8 RGBA sprites (a red square and a
//! blue square) placed at cols 0 and 12 with text drawn between and
//! around them ("A", "B", and a caption flowing under the sprites) —
//! text+image interleaving in one band row.
//!
//! Row 3 — status: a spinning base-ui Spinner plus "images: ON" or
//! "images: unsupported".
//!
//! SCROLLING: every 15 ticks a timestamped "scroll line N …" is queued
//! via `region.append(.line)`, so the band — and the images placed in
//! it — scroll up into the terminal scrollback (kitty placements scroll
//! with their cells). The animated ball + star are re-placed at the band
//! rows every tick, keeping them glued to the band; the gallery sprites
//! are placed once and ride the scroll with their cells.
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

/// A scroll line is appended above the band every this many ticks.
const scroll_every_ticks: u32 = 15;

/// Cache ids. The flip-book owns a contiguous block 100..105; the
/// remaining ids are explicit so `place` can address each image.
const star_id_base: u32 = 100;
const star_frame_count: u32 = 6;
const ball_id: u32 = 200;
const square_red_id: u32 = 300;
const square_blue_id: u32 = 301;

/// Fixed cell (row 1) the flip-book cycles at.
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

    var region = try Region.init(gpa, .{ .height = 4 });
    defer region.deinit();

    // Size the band to the terminal before the first frame.
    const ws = try tty.getWinsize();
    try region.resize(ws.cols, region.height);

    const w = tty.writer();

    // Transmit every image once (transmits are position-independent).
    // Placements need the band's ABSOLUTE screen rows, which are only
    // known once the first CPR reply anchors the band (see the `.cpr`
    // arm below): the gallery is placed once at `anchorRow() + 2` and
    // rides the scroll with its cells; the animated ball and star are
    // re-placed at `anchorRow() + <band row>` every tick, keeping them
    // glued to the band.
    if (caps.kitty_graphics) {
        try transmitAll(w);
        try w.flush();
    }

    var reader = Reader.init(&tty);

    // Animation + scroll state.
    var tick: u32 = 0;
    var scroll_n: u32 = 0;
    var ball_col: u32 = 0;
    var ball_dir: i32 = 1;
    var frame_index: u32 = 0;
    // The band's absolute top row is unknown until the FIRST CPR reply
    // (the query fires before the first paint; see `.cpr` below). No
    // placements are emitted before that — a tick or two at most.
    var anchor_known: bool = false;
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
                if (!anchor_known) {
                    // The FIRST reply answers the query emitted at the
                    // first render start, BEFORE the first paint — the
                    // cursor then sat at the pre-frame row. The
                    // region's bookkeeping already holds every shift
                    // applied since (CNL reservation + any appends
                    // flushed), so applyFirstCpr re-anchors exactly.
                    // Anchor it, then place the one-shot gallery at its
                    // absolute row (it rides the scroll with its
                    // cells).
                    region.applyFirstCpr(pos.row);
                    anchor_known = true;
                    if (caps.kitty_graphics) {
                        try notui.image.kitty.place(w, .{
                            .id = square_red_id,
                            .col = 0,
                            .row = region.anchorRow() + 2,
                            .size = .{ .width = 8, .height = 8 },
                        });
                        try notui.image.kitty.place(w, .{
                            .id = square_blue_id,
                            .col = 12,
                            .row = region.anchorRow() + 2,
                            .size = .{ .width = 8, .height = 8 },
                        });
                    }
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

        // The moving ball: bounce horizontally across the row width.
        const max_col: u32 = region.width -| 1;
        if (ball_dir > 0) {
            if (ball_col >= max_col) ball_dir = -1 else ball_col += 1;
        } else {
            if (ball_col == 0) ball_dir = 1 else ball_col -= 1;
        }

        // The flip-book: advance to the next star frame.
        frame_index = (frame_index + 1) % star_frame_count;

        // Every ~15 ticks push a timestamped line above the band: the
        // band — and its placed images — scroll up into scrollback with
        // it (kitty placements scroll with their cells). The `.line`
        // slice points into `line_buf`, alive through the render that
        // flushes the append queue this same iteration.
        if (tick % scroll_every_ticks == 0) {
            scroll_n += 1;
            var line_buf: [64]u8 = undefined;
            try region.append(.{ .line = scrollLine(io, &line_buf, scroll_n, region.width) });
        }

        try drawBand(io, &region, &spinner);

        if (caps.kitty_graphics and anchor_known) {
            // Re-place = animation: the same id at a new col (ball) or a
            // new frame id at a fixed cell (flip-book). Absolute rows:
            // the CURRENT anchor + the band row, so the images stay
            // glued to the band as append lines scroll it up.
            try notui.image.kitty.place(w, .{
                .id = ball_id,
                .col = ball_col,
                .row = region.anchorRow() + 0,
                .size = .{ .width = ball_w, .height = ball_h },
            });
            try notui.image.kitty.place(w, .{
                .id = star_id_base + frame_index,
                .col = star_col,
                .row = region.anchorRow() + 1,
                .size = .{ .width = star_w, .height = star_h },
            });
        }

        try region.render(w);
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
        .height = 4,
        .append_lines = false,
        .sync_output = false,
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
