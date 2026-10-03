//! The declarative frame: which terminal modes a frame wants, and the callback
//! that paints it.
//!
//! `View` is not a string-lines description. It carries the declarative WHAT
//! (modes, band height, title) plus a `draw` callback that composes components
//! into the frame `Buffer`; `App` diffs the declaration against the previous
//! frame and paints only when it changed, with the Region's own cell diff as
//! the correctness backstop for content.

const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Context = @import("context.zig").Context;
const emit = @import("emit.zig");

/// What one frame declares and how it paints itself, for a `Model` whose
/// `view` returns it. The value is borrowed: it points at the model's state
/// and at `draw`, and holds no ownership.
pub fn View(comptime Model: type) type {
    return struct {
        /// The closed error set `draw` may return: the model's own
        /// `DrawError` when it declares one, otherwise
        /// `std.mem.Allocator.Error`.
        ///
        /// A `draw` that only allocates may leave its error set inferred and
        /// it coerces here. A `draw` that returns anything else must declare
        /// `pub const DrawError` on the model and propagate those errors. The
        /// declaration is checked where it is read: it must be an error set,
        /// and it must not be `anyerror` — declaring the catch-all would
        /// restore exactly what this field exists to close, so it is a
        /// compile error rather than a silently broader contract.
        pub const DrawError = blk: {
            if (!@hasDecl(Model, "DrawError")) break :blk std.mem.Allocator.Error;
            const Declared = Model.DrawError;
            if (Declared == anyerror) @compileError(
                "Model.DrawError must be a closed error set, not anyerror: " ++
                    "name the errors paint can return",
            );
            if (@typeInfo(Declared) != .error_set) @compileError(
                "Model.DrawError must be an error set, for example " ++
                    "`std.mem.Allocator.Error || error{NoGlyph}`",
            );
            break :blk Declared;
        };

        /// Paint the frame into `buf`, the active frame `Buffer`. Compose
        /// components through their own draw callbacks and raw `Buffer.draw`;
        /// advance animation with a component `advance`, and set
        /// `ctx.render_requested = true` when the frame moved so the App
        /// repaints.
        ///
        /// `model` is a mutable pointer so components can advance to the
        /// current instant while they paint. `ctx` and `buf` are the session's
        /// live frame state; neither may be retained past the call.
        ///
        /// The cells drawn into `buf` borrow the text they were given, so every
        /// slice must stay alive and unchanged from the `Buffer.draw` call
        /// until the frame has been rendered. Memory the model owns, a
        /// component's own storage and a string literal all satisfy that;
        /// `ctx.frame_arena` is one option, not the only one.
        /// `ctx.scratch_arena` does not: it is reset at the top of every frame,
        /// so a cell holding one of its slices would read recycled memory on
        /// the next paint.
        ///
        /// Runs synchronously on the loop thread, after updates and band-height changes,
        /// while the frame is staged. It must not reenter the App session or block on
        /// input.
        ///
        /// A failed `draw` aborts staging; none of this frame is published.
        /// The error reaches the caller. A caller driving `tick` or `frameHeadless`
        /// may retry; `run` returns it and tears down the session.
        draw: *const fn (model: *Model, ctx: *Context, buf: *Buffer) DrawError!void,
        /// Request SGR 1006 mouse reporting for this frame. Diffed against
        /// the previous frame; the terminal is restored on exit regardless.
        mouse: bool = false,
        /// Hide the cursor while rendering. Default true; the cursor is shown
        /// again when the session ends.
        hide_cursor: bool = true,
        /// The app staged scrollback content this frame (through
        /// `Context.appendAbove` or `Cmd.println`). Forces a render so the
        /// region flushes above the band even when the band itself did not
        /// change.
        print_above: bool = false,
        /// Desired band height in rows; 0 keeps the current height. A nonzero
        /// value that differs from the region's height applies
        /// `Region.setHeight` before the frame is painted.
        height: u16 = 0,
        /// Terminal title to write (OSC 0) as part of this frame's single
        /// write. `null` writes nothing; `Cmd.set_title` sets one outside a
        /// frame. The bytes are borrowed until the frame is staged.
        title: ?[]const u8 = null,
    };
}

/// The terminal modes currently active. `App` owns one instance and feeds it
/// to `applyModeDiff` on every rendered frame; an application driving the
/// renderer itself owns the instance that tracks what the terminal was told.
pub const Modes = struct {
    /// Whether SGR 1006 mouse reporting is on.
    mouse: bool = false,
    /// Whether the cursor is hidden. Defaults to hidden, matching
    /// `View.hide_cursor`.
    hide_cursor: bool = true,
};

/// Emit a mode sequence into `w` only for the modes `view` disagrees with
/// `current` on, then advance `current`. `mouse` writes `CSI ?1006h ?1000h`
/// to enable and `CSI ?1006l ?1000l` to disable; `hide_cursor` writes
/// `emit.hideCursor` or `emit.showCursor`. Returns whether any sequence was
/// emitted, which is true exactly when `current` changed.
///
/// `w` stays owned by the caller. On a write failure the modes already
/// written stand; the caller decides whether to retry them.
///
/// `view` is duck-typed (`anytype`): any struct carrying `mouse` and
/// `hide_cursor` works, including a plain `View(Model)`.
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

/// A cheap signature of the declarative part of `view`: the `draw` function
/// pointer, both mode flags, `print_above`, `height` and the address of the
/// title. Two frames with the same signature declare the same frame, so the
/// second can be skipped. It is not a content hash: drawn text that changes
/// under a stable signature is invisible here, which is why `render_requested`
/// and the Region's own cell diff are the real repaint triggers.
///
/// `view` is duck-typed (`anytype`): it must carry those fields.
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

/// A model whose paint only allocates, so the default `DrawError` covers it.
const TestModel = struct {
    fn drawA(_: *TestModel, _: *Context, buf: *Buffer) !void {
        _ = try buf.draw(.{}, "a", 0, 0);
    }
};

/// Fixed-buffer writer for golden tests; the App composes its frames through
/// the same writer interface.
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
