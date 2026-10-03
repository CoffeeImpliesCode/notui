//! framework_counter: a minimal Elm-style counter demo for the
//! App(Model) framework.
//!
//! Demonstrates the framework contract: the `Msg`/`init`/`update`/`view`
//! model shape with `init` returning `{ model, cmd }` (the init-armed
//! `every` drives the spinner with no input), `setFilter` + `run`
//! wiring, base-ui `Text` + `Spinner` + `StatusBar` composed into the
//! frame via `View.draw`, the inline default mode, and the
//! Ctrl+C-routed-as-Msg quit convention (`q` and `^C` both produce
//! `.quit` — the library never hard-quits).
//!
//! Run with: zig build run-example-framework_counter

const std = @import("std");
const notui = @import("notui");

const Context = notui.context.Context;
const View = notui.view.View;
const Cmd = notui.command.Cmd;
const Buffer = notui.buffer.Buffer;
const Event = notui.event.Event;
const Key = notui.key;
const component = notui.component;

/// The counter model: an Elm-shaped state machine. The framework calls
/// `init` once, `update` per message, and `view` per rendered frame.
pub const Model = struct {
    pub const Msg = union(enum) { tick, inc, dec, quit };
    pub const DrawError = std.mem.Allocator.Error || error{NoSpaceLeft};

    count: i64 = 0,
    busy: bool = false,
    spinner: component.Spinner = .{ .label = "working" },
    scratch: std.ArrayList(u8) = .empty, // Text truncation scratch (borrow model)
    count_text: [96]u8 = undefined,

    /// Elm init: the framework (`start`) builds the model via this call
    /// and runs the returned Cmd through the same path as queued msgs —
    /// the init-armed `every` starts the periodic timer immediately, so
    /// the spinner animates with no input.
    pub fn init(allocator: std.mem.Allocator) !struct { model: Model, cmd: Cmd(Msg) } {
        _ = allocator;
        return .{ .model = .{}, .cmd = .{ .every = .{ .interval_ms = 200, .msg = .tick } } };
    }

    /// Release the model-owned text scratch once, after the framework stops rendering.
    pub fn deinit(self: *Model, gpa: std.mem.Allocator) void {
        self.scratch.deinit(gpa);
        self.* = undefined;
    }

    /// The message reducer. `inc`/`dec` edit the counter; `quit` stops
    /// the loop; `tick` (the framework's periodic message, driven by the
    /// `every` Cmd) toggles the busy demo flag and keeps the timer armed
    /// so the spinner animates with no input.
    pub fn update(self: *Model, msg: Msg, ctx: *Context) !Cmd(Msg) {
        switch (msg) {
            .inc => self.count += 1,
            .dec => self.count -= 1,
            .quit => return .quit,
            .tick => {
                self.busy = !self.busy; // demo toggle; the spinner animates
                if (self.busy) ctx.render_requested = true;
                return .{ .every = .{ .interval_ms = 200, .msg = .tick } };
            },
        }
        return .none;
    }

    /// The declarative frame: what to render and which terminal modes
    /// the app wants. The framework diffs this against the previous
    /// frame and renders only when something changed.
    pub fn view(self: *const Model, ctx: *Context) View(Model) {
        _ = self;
        _ = ctx;
        return .{
            .draw = draw,
            .height = 3,
            .title = "notui counter",
        };
    }

    /// Paint the frame: a Text line (the count + keys hint), a Spinner,
    /// and a StatusBar row. Components advance to `now` on draw.
    fn draw(model: *Model, ctx: *Context, buf: *Buffer) !void {
        const now = std.Io.Timestamp.now(ctx.io, .awake);
        var count_txt: component.Text = .{
            .style = .{ .fg = .{ .ansi = .cyan } },
            .scratch = &model.scratch, // model-owned, gpa-backed (borrow model)
        };
        count_txt.text = try std.fmt.bufPrint(
            &model.count_text,
            "count: {d}   [i]nc [d]ec [q]uit",
            .{model.count},
        );
        _ = try count_txt.draw(ctx.allocator, buf, 0, 0, now); // Text row
        _ = try model.spinner.draw(buf, 0, 1, now); // Spinner row
        var bar: component.StatusBar = .{
            .left = &.{.{ .text = "counter", .style = .{ .fg = .{ .ansi = .green } } }},
            .right = &.{.{ .text = "inline mode", .style = .{} }},
        };
        _ = try bar.draw(buf, 0, 2, now); // StatusBar row
    }
};

pub fn main(init: std.process.Init) !void {
    var app = notui.app.App(Model).init();
    app.setFilter(&filter);
    try app.run(init.io, init.gpa);
}

/// Event → Msg: route keys to messages. Ctrl+C arrives as a normal
/// key_press (Key.ctrl_c) and maps to `.quit` — the library never
/// hard-quits. Unmatched events are dropped.
fn filter(_: *Context, ev: Event) ?Model.Msg {
    return switch (ev) {
        .key_press => |k| {
            if (k.matches('q', .{})) return .quit;
            if (k.matches('i', .{})) return .inc;
            if (k.matches('d', .{})) return .dec;
            // ^C arrives either as the raw control byte (Key.ctrl_c) or,
            // via the xterm encoding (Parser.zig), as 'c' + ctrl mod —
            // both map to .quit (spinner.zig:89 convention).
            if (k.matches(Key.ctrl_c, .{}) or k.matches('c', .{ .ctrl = true })) return .quit;
            return null;
        },
        else => null,
    };
}
