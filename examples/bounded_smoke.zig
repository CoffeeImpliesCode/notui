//! Bounded-region smoke fixture: the declared native retention capacity
//! driven through the real terminal consequences it promises.
//!
//! The other end of this binary is examples/bounded_resize.js; this file
//! is deliberately the smallest app that can be judged against a bounded
//! scrollback, and it adds nothing the region does not already own:
//!
//! - `--terminal-scrollback-rows=N` becomes
//!   `Region.TerminalReflow .{.non_cursor_rows = .{.scrollback_rows = N}}`
//!   — the capacity the driver declares on the tab it types into, read
//!   back from that tab's own `window.term.options.scrollback` before the
//!   launch. `N = 0` is a real case: a terminal that keeps no scrollback.
//! - `--prehistory=N` prints N `PNN` rows ABOVE the region before it ever
//!   renders, so the rows the region must leave alone are already in the
//!   buffer when its first frame is drawn.
//! - Two owned rows: a 131-column input line (55 ASCII columns then 38
//!   width-two glyphs) and a one-cell `T` status row. The band opens two
//!   rows tall and is clipped to one before the first keypress, which is
//!   the one row the driver then takes through a physical height cycle.
//! - `g` commits 98 `hNN` history rows through `Region.append`; `q` exits.
//!
//! Every keypress repaints the owned status row, so a driver wait can see
//! the frame its own input caused. The only screen clear is the fixture
//! setup above, which happens before the region exists: a Region never
//! clears rows it does not own, and neither may the app that wraps it.
//!
//! Run with: zig build run-bounded-smoke — it parks on the owned row
//! until `q`; examples/bounded_resize.js is what drives it under ttyd.

const std = @import("std");
const notui = @import("notui");

const Region = notui.region.Region;

/// Restore the terminal on panic: defers never run for a panicking
/// process, and a raw terminal is what forces a hard reset. Re-raises the
/// default panic after the cleanup.
pub const panic = std.debug.FullPanic(struct {
    pub fn call(msg: []const u8, ra: ?usize) noreturn {
        notui.tty.restoreTerminal();
        std.debug.defaultPanic(msg, ra);
    }
}.call);

/// The band opens with both owned rows visible…
const open_height: u16 = 2;
/// …and is clipped to the status row alone before the first keypress.
const clipped_height: u16 = 1;

/// The owned input row: 55 ASCII columns + 38 width-two glyphs = 131
/// columns, so it wraps and clips in every geometry the driver fits.
const input_row = &(@as([55]u8, @splat('a')) ++ @as([114]u8, @bitCast(@as([38][3]u8, @splat("界".*)))));

/// The owned status row, one cell, redrawn on every keypress.
const status_row = "T";

/// Committed history, printed by `g`: `h00`..`h97`, the markers the
/// driver counts over the whole buffer after the height restore. Short
/// enough that a 100-row capacity keeps them all and a 0-row capacity
/// keeps none.
const history_rows: usize = 98;
const history = blk: {
    var lines: [history_rows][3]u8 = undefined;
    for (&lines, 0..) |*line, i| {
        line.* = .{ 'h', '0' + @as(u8, @intCast(i / 10)), '0' + @as(u8, @intCast(i % 10)) };
    }
    break :blk lines;
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    defer args.deinit();
    _ = args.next();
    var capacity: u32 = 100;
    var prehistory: u32 = 0;
    while (args.next()) |arg| {
        const cap_arg = "--terminal-scrollback-rows=";
        const pre_arg = "--prehistory=";
        if (std.mem.startsWith(u8, arg, cap_arg)) {
            capacity = try std.fmt.parseInt(u32, arg[cap_arg.len..], 10);
        } else if (std.mem.startsWith(u8, arg, pre_arg)) {
            prehistory = try std.fmt.parseInt(u32, arg[pre_arg.len..], 10);
        } else return error.InvalidArgument;
    }

    var tty = try notui.tty.Tty.init(io);
    defer tty.deinit();
    try tty.makeRaw();
    defer tty.restore();
    const w = tty.writer();

    // Fixture setup only, and only before the region owns a row: the
    // prehistory markers have to be in the buffer before the first frame.
    try w.writeAll("\x1b[H\x1b[2J\x1b[3J");
    for (0..prehistory) |i| try w.print("P{d:0>2}\r\n", .{i});

    var region = try Region.init(gpa, .{
        .height = open_height,
        .terminal_reflow = .{ .non_cursor_rows = .{ .scrollback_rows = capacity } },
    });
    defer region.deinit();
    const first = try tty.getWinsize();
    try region.resize(first.cols, first.rows, open_height);
    _ = try region.cur.draw(.{}, input_row, 0, 0);
    _ = try region.cur.draw(.{}, status_row, 0, 1);
    try region.render(w);
    try w.flush();

    // The one-row clip: the input row retires into the region's own
    // retention, and the driver measures what is still of it after a
    // width reflow, a partial erase and the height restore.
    try region.setHeight(clipped_height);
    region.cur.clear();
    _ = try region.cur.draw(.{}, status_row, 0, 0);
    try region.render(w);
    try w.flush();

    var reader = notui.input.Reader.init(&tty);
    while (true) {
        if (tty.checkResize()) {
            const ws = try tty.getWinsize();
            try region.resize(ws.cols, ws.rows, clipped_height);
            region.repaintAll();
        }
        if (try reader.nextTimeout(50)) |event| switch (event) {
            .cpr => |pos| try region.applyCpr(pos.row, pos.col),
            .winsize => |ws| try region.resize(ws.cols, ws.rows, clipped_height),
            .key_press => |key| {
                if (key.matches('q', .{})) break;
                if (key.matches('g', .{})) {
                    for (&history) |*line| try region.append(.{ .line = line });
                }
            },
            else => {},
        };
        region.cur.clear();
        _ = try region.cur.draw(.{}, status_row, 0, 0);
        try region.render(w);
        try w.flush();
    }
    try region.exit(w);
    try w.flush();
}
