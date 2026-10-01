//! View(Model): the declarative frame (framework-contract.md §4), plus
//! the signature hash used for the idle-frame skip and the only-on-change
//! mode-diff helper.
//!
//! The frame is NOT a string-lines description: it is a `draw` callback
//! that composes base-ui components into the frame `Buffer` (the shipped
//! Region diff renderer, region.zig scanChanges — idle frames emit zero
//! bytes). The `View` carries the declarative WHAT (modes, band height,
//! title); the `draw` callback paints the HOW.

const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Context = @import("context.zig").Context;
const emit = @import("emit.zig");
const Cmd = @import("command.zig").Cmd;

/// The per-frame declaration of WHAT to render and which terminal modes
/// the app wants. `view` returns one of these; the App diffs it against
/// the previous frame and renders only when something changed.
pub fn View(comptime Model: type) type {
    return struct {
        /// Paint the frame into `buf` (the active frame Buffer —
        /// `&ctx.region.cur` inline). Compose base-ui components via
        /// their `draw(buf, x, y, now)` with
        /// `now = std.Io.Timestamp.now(ctx.io, .awake)` (component.zig:27)
        /// and/or raw `Buffer.draw` (buffer.zig:128). Advance animation
        /// with component `advance(now)` and set
        /// `ctx.render_requested = true` when the frame moved so the App
        /// repaints (the spinner pattern). `model` is `*Model` (mutable)
        /// precisely so components can advance to `now` in draw.
        draw: *const fn (model: *Model, ctx: *Context, buf: *Buffer) anyerror!void,
        /// Request SGR 1006 mouse reporting for this frame (diffed;
        /// enabled on change, disabled on exit via caps.restore,
        /// caps.zig:58).
        mouse: bool = false,
        /// Hide the cursor while rendering (default true; shown on exit).
        hide_cursor: bool = true,
        /// The app staged scrollback-above content this frame (via
        /// `ctx.appendAbove` or `Cmd.println`); force a render so the
        /// region flushes the append queue above the band (region.render
        /// auto-flushes, region.zig appendQueue; this flag guarantees a
        /// render when the band itself is unchanged).
        print_above: bool = false,
        /// Desired region band height; 0 = keep the current height. A
        /// nonzero value applies `Region.setHeight` (dynamic bands: the
        /// REPL popup grows the band via setHeight,
        /// skript_repl.zig:257/366).
        height: u16 = 0,
        /// Terminal title to set when non-null (also settable via
        /// Cmd.set_title).
        title: ?[]const u8 = null,
    };
}

/// The terminal modes currently active. `App` owns one instance and feeds
/// it to `applyModeDiff` on every rendered frame.
pub const Modes = struct {
    /// Whether SGR 1006 mouse reporting is on.
    mouse: bool = false,
    /// Whether the cursor is hidden.
    hide_cursor: bool = true,
};

/// Apply the per-frame mode diff, emitting a sequence ONLY when a mode
/// changed (bubbletea-style, framework-contract.md §5.3):
///
/// - `mouse`: `CSI ?1006h + ?1000h` on, `CSI ?1006l + ?1000l` off.
/// - `hide_cursor`: `emit.hideCursor`/`emit.showCursor`.
///
/// Returns whether any sequence was emitted (a mode actually changed).
pub fn applyModeDiff(view: anytype, w: anytype, current: *Modes) !bool {
    var changed = false;

    if (view.mouse != current.mouse) {
        if (view.mouse) {
            try w.writeAll("\x1b[?1006h\x1b[?1000h");
        } else {
            try w.writeAll("\x1b[?1006l\x1b[?1000l");
        }
        current.mouse = view.mouse;
        changed = true;
    }
    if (view.hide_cursor != current.hide_cursor) {
        if (view.hide_cursor) {
            try emit.hideCursor(w);
        } else {
            try emit.showCursor(w);
        }
        current.hide_cursor = view.hide_cursor;
        changed = true;
    }
    return changed;
}

/// A cheap signature of the declarative part of a View (draw fn pointer +
/// mode flags + height + title pointer value). Used to skip a frame whose
/// declaration is identical to the last (the "whole-View hash skip"); the
/// Region's own diff (region.zig scanChanges, zero-byte idle frames) is
/// the correctness backstop for content. Not a content hash.
pub fn signature(view: anytype) u64 {
    var h = std.hash.Wyhash.init(0);
    const draw_ptr = @intFromPtr(view.draw);
    h.update(std.mem.asBytes(&draw_ptr));
    h.update(std.mem.asBytes(&view.mouse));
    h.update(std.mem.asBytes(&view.hide_cursor));
    h.update(std.mem.asBytes(&view.print_above));
    h.update(std.mem.asBytes(&view.height));
    const title_ptr: usize = if (view.title) |t| @intFromPtr(t.ptr) else 0;
    h.update(std.mem.asBytes(&title_ptr));
    return h.final();
}

test {
    std.testing.refAllDecls(@This());
}

const testing = std.testing;

const TestModel = struct {
    pub const Msg = union(enum) { tick };
    fn init(_: std.mem.Allocator) !TestModel {
        return .{};
    }
    fn update(_: *TestModel, _: Msg, _: *Context) !Cmd(Msg) {
        return .none;
    }
    pub fn view(_: *const TestModel, _: *Context) View(TestModel) {
        return .{ .draw = &drawA };
    }
    fn drawA(_: *TestModel, _: *Context, _: *Buffer) anyerror!void {}
    fn drawB(_: *TestModel, _: *Context, _: *Buffer) anyerror!void {}
};

/// Fixed-buffer writer for golden tests (emit.zig TestWriter pattern).
const TestWriter = struct {
    buf: [256]u8 = undefined,
    w: std.Io.Writer = undefined,

    fn init(self: *TestWriter) void {
        self.w = .fixed(&self.buf);
    }
    fn reset(self: *TestWriter) void {
        self.w = .fixed(&self.buf);
    }
};

test "view: mode changes emit once and stable modes emit nothing" {
    var tw: TestWriter = .{};
    tw.init();
    var modes: Modes = .{};

    // mouse on: emitted once.
    try testing.expect(try applyModeDiff(View(TestModel){ .draw = &TestModel.drawA, .mouse = true }, &tw.w, &modes));
    try testing.expectEqualStrings("\x1b[?1006h\x1b[?1000h", tw.w.buffered());

    // mouse already on: nothing.
    tw.reset();
    try testing.expect(!try applyModeDiff(View(TestModel){ .draw = &TestModel.drawA, .mouse = true }, &tw.w, &modes));
    try testing.expectEqualStrings("", tw.w.buffered());

    // mouse off: emitted.
    tw.reset();
    try testing.expect(try applyModeDiff(View(TestModel){ .draw = &TestModel.drawA }, &tw.w, &modes));
    try testing.expectEqualStrings("\x1b[?1006l\x1b[?1000l", tw.w.buffered());

    // hide_cursor false (show): emitted.
    tw.reset();
    try testing.expect(try applyModeDiff(
        View(TestModel){ .draw = &TestModel.drawA, .hide_cursor = false },
        &tw.w,
        &modes,
    ));
    try testing.expectEqualStrings("\x1b[?25h", tw.w.buffered());

    // back to hidden: emitted.
    tw.reset();
    try testing.expect(try applyModeDiff(View(TestModel){ .draw = &TestModel.drawA }, &tw.w, &modes));
    try testing.expectEqualStrings("\x1b[?25l", tw.w.buffered());

    // inline→inline with every mode stable: nothing.
    tw.reset();
    try testing.expect(!try applyModeDiff(View(TestModel){ .draw = &TestModel.drawA }, &tw.w, &modes));
    try testing.expectEqualStrings("", tw.w.buffered());
}
