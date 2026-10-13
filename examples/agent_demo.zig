//! Deterministic coding-agent chat, composed only from the notui consumer module.
//! Enter submits; Ctrl+N splits a line; Up/Down changes input line or completion.
//! Tab completes /commands and @files. Ctrl+G approval, Ctrl+P help popover,
//! Ctrl+O help modal, Ctrl+R / Ctrl+X card ladder, Ctrl+T diff layout, Ctrl+C exit.
//! Editor undo and kill-ring bindings apply to the focused logical input line.
//! --script runs forty numbered turns; --self-test checks token boundaries.
const std = @import("std");
const notui = @import("notui");
const C = notui.component;
const Context = notui.context.Context;
const Buffer = notui.buffer.Buffer;
const Event = notui.event.Event;
const Key = notui.key;
const Style = notui.style.Style;
const Cmd = notui.command.Cmd;
const Theme = notui.theme.Theme;

var scripted = false;
const commands = [_][]const u8{ "/demo", "/stream", "/approve", "/help", "/quit" };
const files = [_][]const u8{
    "@src/region.zig", "@src/component/editor.zig", "@README.md", "@examples/agent_demo.zig",
};
const reply =
    "## Plan: preserve the inline transcript\n\n" ++
    "I checked **ownership**, *Unicode width*, and `Region` history receipts. " ++
    "The editor keeps 世界 and 👩‍💻 aligned with the cursor.\n\n" ++
    "- Keep settled rows in scrollback exactly once.\n" ++
    "- Repaint only the mutable response and input.\n" ++
    "  - Resize while a reply is streaming.\n\n" ++
    "### Proposed change\n\n```zig\n" ++
    "const receipt = try region.writeTranscript(rows);\n" ++
    "try transcript.sealDelta(receipt);\n```\n\n" ++
    "See the [frame contract](https://example.org/frame-contract).\n\n" ++
    "**Result:** ready for review; no network or real tool is executed.\n";
const tool_body =
    "$ zig build test\n" ++
    "Checking Unicode grapheme boundaries...\n" ++
    "Checking row ownership...\n" ++
    "Checking resize 100 -> 50 -> 30 -> 100...\n" ++
    "Checking receipt acknowledgement...\n" ++
    "Checking shell scrollback preservation...\n" ++
    "42 deterministic checks passed.\n" ++
    "Exit status: 0 (scripted demonstration)";
const patch =
    "--- a/src/session.zig\n+++ b/src/session.zig\n" ++
    "@@ -1,3 +1,4 @@\n const title = \"世界 👩‍💻\";\n" ++
    "-const keep_history = false;\n+const keep_history = true;\n" ++
    "+const receipt = try region.writeTranscript(rows);\n return title;\n";
const Action = enum { submit, newline, approval, popover, modal, collapse, expand, layout, quit };

fn tokenEnd(text: []const u8, start: usize) usize {
    var at = start;
    while (at < text.len) {
        at += notui.width.firstGraphemeLen(text[at..]);
        if (std.ascii.isWhitespace(text[at - 1])) break;
    }
    return at;
}

fn diffRows(hunks: []const C.cards.Hunk, layout: C.Diff.Layout) usize {
    var count: usize = 0;
    for (hunks) |hunk| {
        if (hunk.header.len > 0) count += 1;
        var at: usize = 0;
        while (at < hunk.lines.items.len) : (at += 1) {
            count += 1;
            if (layout == .side_by_side and
                hunk.lines.items[at].kind == .deletion and
                at + 1 < hunk.lines.items.len and
                hunk.lines.items[at + 1].kind == .addition)
            {
                at += 1;
            }
        }
    }
    return count;
}

fn selfTest(gpa: std.mem.Allocator) !void {
    const text = "Hello 世界 👩‍💻!\n";
    var at: usize = 0;
    var tokens: usize = 0;
    while (at < text.len) {
        const next = tokenEnd(text, at);
        try std.testing.expect(next > at);
        try std.testing.expect(std.unicode.utf8ValidateSlice(text[0..next]));
        at = next;
        tokens += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), tokens);
    var editor = try C.Editor.init(gpa, .{});
    defer editor.deinit();
    try editor.insert("世界 👩‍💻");
    try editor.killToStart();
    try std.testing.expect(try editor.yank());
    try std.testing.expectEqualStrings("世界 👩‍💻", editor.text());
    try std.testing.expect(try editor.undo());
    try std.testing.expectEqualStrings("", editor.text());
    var hunks: std.ArrayList(C.cards.Hunk) = .empty;
    defer C.cards.deinitHunks(gpa, &hunks);
    try C.cards.parseUnified(gpa, patch, &hunks);
    try std.testing.expectEqual(@as(usize, 6), diffRows(hunks.items, .unified));
    try std.testing.expectEqual(@as(usize, 5), diffRows(hunks.items, .side_by_side));
}

pub const Model = struct {
    pub const Msg = union(enum) { tick, input: Event };
    pub const DrawError = std.mem.Allocator.Error || error{NoSpaceLeft};
    gpa: std.mem.Allocator,
    editors: std.ArrayList(C.Editor) = .empty,
    focused: usize = 0,
    markdown: notui.markdown.Renderer,
    keymap: notui.keybindings.Keymap,
    completion_scratch: std.ArrayList(u8) = .empty,
    matches: [16][]const u8 = undefined,
    completion_index: usize = 0,
    completion_open: bool = false,
    completion_rows: u16 = 0,
    approval: ?C.Select = null,
    pending_submit: bool = false,
    always: bool = false,
    help: enum { none, popover, modal } = .none,
    streaming: bool = false,
    streamed: usize = 0,
    turns: usize = 0,
    script_wait: u8 = 0,
    card_visible: bool = false,
    card: C.Card = .{ .title = "tool: zig build test", .body = tool_body, .preview_lines = 2 },
    hunks: std.ArrayList(C.cards.Hunk) = .empty,
    diff_layout: C.Diff.Layout = .unified,
    title_buf: [96]u8 = undefined,
    spinner: C.Spinner = .{ .label = "assistant streaming" },

    pub fn init(gpa: std.mem.Allocator) !struct { model: Model, cmd: Cmd(Msg) } {
        var model: Model = .{
            .gpa = gpa,
            .markdown = notui.markdown.Renderer.init(gpa),
            .keymap = notui.keybindings.Keymap.init(gpa),
        };
        errdefer model.deinit(gpa);
        try model.addLine();
        try C.cards.parseUnified(gpa, patch, &model.hunks);
        const bindings = .{
            .{ Action.submit, Key.enter, Key.Modifiers{}, "Enter", "send" },
            .{ Action.newline, 'n', Key.Modifiers{ .ctrl = true }, "^N", "newline" },
            .{ Action.approval, 'g', Key.Modifiers{ .ctrl = true }, "^G", "approve" },
            .{ Action.popover, 'p', Key.Modifiers{ .ctrl = true }, "^P", "help" },
            .{ Action.modal, 'o', Key.Modifiers{ .ctrl = true }, "^O", "modal" },
            .{ Action.collapse, 'r', Key.Modifiers{ .ctrl = true }, "^R", "fold" },
            .{ Action.expand, 'x', Key.Modifiers{ .ctrl = true }, "^X", "expand" },
            .{ Action.layout, 't', Key.Modifiers{ .ctrl = true }, "^T", "diff" },
            .{ Action.quit, 'c', Key.Modifiers{ .ctrl = true }, "^C", "exit" },
        };
        inline for (bindings) |binding| try model.keymap.bind(.{
            .action = .fromEnum(binding[0]),
            .chord = &.{.{ .codepoint = binding[1], .mods = binding[2] }},
            .hint = binding[3],
            .description = binding[4],
        });
        return .{
            .model = model,
            .cmd = .{ .every = .{
                .interval_ms = if (scripted) 20 else 70,
                .msg = .tick,
            } },
        };
    }

    pub fn deinit(self: *Model, gpa: std.mem.Allocator) void {
        for (self.editors.items) |*editor| editor.deinit();
        self.editors.deinit(gpa);
        self.markdown.deinit();
        self.keymap.deinit();
        self.completion_scratch.deinit(gpa);
        C.cards.deinitHunks(gpa, &self.hunks);
        self.* = undefined;
    }

    fn addLine(self: *Model) !void {
        var editor = try C.Editor.init(self.gpa, .{ .blink_ns = 0 });
        errdefer editor.deinit();
        try self.editors.append(self.gpa, editor);
        self.focused = self.editors.items.len - 1;
    }

    fn options(ctx: *Context) notui.markdown.Options {
        return .{
            .width = @max(1, ctx.width),
            .heading = Theme.dark.style(.accent, ctx.color_profile),
            .code = Theme.dark.style(.code_bg, ctx.color_profile),
            .marker = Theme.dark.style(.success, ctx.color_profile),
            .link = Theme.dark.style(.accent, ctx.color_profile),
        };
    }

    fn suggestions(self: *Model) C.Suggestions {
        const text = self.editors.items[self.focused].text();
        return .{
            .items = if (text.len > 0 and text[0] == '@') &files else &commands,
            .selected = self.completion_index,
            .scratch = &self.completion_scratch,
            .max_rows = 5,
        };
    }

    fn complete(self: *Model, accept: bool) !void {
        var popup = self.suggestions();
        const text = self.editors.items[self.focused].text();
        const n = popup.setItemsFuzzy(text, &self.matches) catch |err| switch (err) {
            error.NeedleTooLong => 0,
        };
        self.completion_rows = @intCast(@min(5, n));
        if (n == 0) {
            self.completion_open = false;
            return;
        }
        self.completion_index = @min(self.completion_index, n - 1);
        if (accept) {
            const selected = self.matches[self.completion_index];
            try self.editors.items[self.focused].clear();
            try self.editors.items[self.focused].insert(selected);
            self.completion_open = false;
        } else self.completion_open = true;
    }

    fn requestApproval(self: *Model) void {
        self.approval = .{
            .items = &.{ "Yes, this run", "No, deny", "Always allow scripted runs" },
            .width = 38,
        };
    }

    fn commitBuffer(ctx: *Context, buf: *const Buffer) !void {
        var rows: std.ArrayList([]const u8) = .empty;
        defer rows.deinit(ctx.allocator);
        var bytes: std.Io.Writer.Allocating = .init(ctx.allocator);
        defer bytes.deinit();
        for (0..buf.height) |y| {
            bytes.clearRetainingCapacity();
            var end: usize = buf.width;
            while (end > 0) {
                const cell = buf.get(@intCast(end - 1), @intCast(y));
                if (!cell.eql(.{})) break;
                end -= 1;
            }
            var style: Style = .{};
            for (0..end) |x| {
                const cell = buf.get(@intCast(x), @intCast(y));
                if (cell.wide) continue;
                if (!cell.style.eql(style)) {
                    try bytes.writer.writeAll("\x1b[0m");
                    try notui.emit.writeStyleProfile(&bytes.writer, cell.style, ctx.color_profile);
                    style = cell.style;
                }
                try bytes.writer.writeAll(if (cell.grapheme.len == 0) " " else cell.grapheme);
            }
            try bytes.writer.writeAll("\x1b[0m");
            try rows.append(ctx.allocator, try ctx.scratch_arena.dupe(u8, bytes.written()));
        }
        _ = try ctx.region.writeTranscript(rows.items);
        ctx.render_requested = true;
    }

    fn paintMarkdown(block: notui.markdown.Block, buf: *Buffer, start: u16) !void {
        for (block.lines, 0..) |line, i| {
            if (start + i >= buf.height) break;
            var col: u16 = 0;
            for (line.spans) |span| {
                col += try buf.draw(span.style, span.text, col, @intCast(start + i));
            }
        }
    }

    fn commitCards(self: *Model, ctx: *Context) !void {
        if (!self.card_visible) return;
        const card_rows: u16 = @intCast(self.card.rows(ctx.width));
        const diff_rows: u16 = @intCast(diffRows(self.hunks.items, self.diff_layout));
        var buf = try Buffer.init(ctx.allocator, ctx.width, card_rows + diff_rows);
        defer buf.deinit();
        const now = std.Io.Timestamp.now(ctx.io, .awake);
        _ = try self.card.draw(&buf, 0, 0, now);
        var diff: C.Diff = .{ .hunks = self.hunks.items, .layout = self.diff_layout };
        _ = try diff.draw(&buf, 0, card_rows, now);
        try commitBuffer(ctx, &buf);
        self.card_visible = false;
    }

    fn submit(self: *Model, ctx: *Context) !void {
        if (self.streaming) return;
        try self.commitCards(ctx);
        self.turns += 1;
        const label = try std.fmt.allocPrint(ctx.frame_arena, "TURN {d:0>3} user:", .{self.turns});
        try ctx.appendAbove(label);
        for (self.editors.items) |*editor| {
            try ctx.appendAbove(try ctx.frame_arena.dupe(u8, editor.text()));
            try editor.clear();
        }
        while (self.editors.items.len > 1) {
            var editor = self.editors.pop().?;
            editor.deinit();
        }
        self.focused = 0;
        self.completion_open = false;
        self.streamed = 0;
        self.streaming = true;
        self.card.state = .running;
        self.help = .none;
    }

    pub fn update(self: *Model, msg: Msg, ctx: *Context) !Cmd(Msg) {
        switch (msg) {
            .tick => {
                if (self.streaming) {
                    self.streamed = tokenEnd(reply, self.streamed);
                    ctx.render_requested = true;
                    if (self.streamed == reply.len) {
                        const block = try self.markdown.render(reply, options(ctx));
                        var buf = try Buffer.init(
                            ctx.allocator,
                            ctx.width,
                            @intCast(block.lines.len + 1),
                        );
                        defer buf.deinit();
                        const label = try std.fmt.allocPrint(
                            ctx.scratch_arena,
                            "TURN {d:0>3} assistant:",
                            .{self.turns},
                        );
                        _ = try buf.draw(Theme.dark.style(.accent, ctx.color_profile), label, 0, 0);
                        try paintMarkdown(block, &buf, 1);
                        try commitBuffer(ctx, &buf);
                        self.streaming = false;
                        self.card_visible = true;
                        self.card.state = .ok;
                        self.card.rung = 1;
                    }
                } else if (scripted) {
                    self.script_wait +|= 1;
                    if (self.script_wait >= 4) {
                        self.script_wait = 0;
                        if (self.turns == 40) {
                            try self.commitCards(ctx);
                            try ctx.appendAbove("SCRIPT COMPLETE: 40 turns");
                            return .quit;
                        }
                        try self.editors.items[0].insert("/stream scripted 世界 👩‍💻");
                        try self.submit(ctx);
                    }
                }
            },
            .input => |ev| {
                ctx.render_requested = true;
                if (ev == .key_press) {
                    const k = ev.key_press;
                    if (k.matches(Key.ctrl_c, .{}) or k.matches('c', .{ .ctrl = true })) {
                        if (!self.streaming) try self.commitCards(ctx);
                        return .quit;
                    }
                    if (self.approval) |*picker| {
                        _ = try picker.key(ev);
                        if (!picker.open) {
                            const selected = if (picker.confirmed) picker.selected() else null;
                            self.approval = null;
                            if (selected != null and selected.? != 1) {
                                self.always = selected.? == 2;
                                if (self.pending_submit) try self.submit(ctx);
                            }
                            self.pending_submit = false;
                        }
                        return .none;
                    }
                    if (k.matches(Key.escape, .{})) {
                        self.help = .none;
                        self.completion_open = false;
                        return .none;
                    }
                    if (k.matches(Key.tab, .{})) {
                        try self.complete(self.completion_open);
                        return .none;
                    }
                    if (k.matches(Key.up, .{}) or k.matches(Key.down, .{})) {
                        const down = k.matches(Key.down, .{});
                        if (self.completion_open) {
                            if (down) self.completion_index += 1 else self.completion_index -|= 1;
                            try self.complete(false);
                        } else if (down) {
                            self.focused = @min(self.focused + 1, self.editors.items.len - 1);
                        } else self.focused -|= 1;
                        return .none;
                    }
                    if (self.keymap.lookup(k)) |id| {
                        const action: Action = @enumFromInt(id.value);
                        switch (action) {
                            .quit => return .quit,
                            .submit => {
                                if (self.completion_open) {
                                    try self.complete(true);
                                } else {
                                    const text = self.editors.items[0].text();
                                    if (std.mem.eql(u8, text, "/quit")) return .quit;
                                    if (std.mem.eql(u8, text, "/help")) {
                                        self.help = .modal;
                                    } else if (!self.streaming) {
                                        const skip = self.always or
                                            std.mem.startsWith(u8, text, "/stream");
                                        if (skip) {
                                            try self.submit(ctx);
                                        } else {
                                            self.pending_submit = true;
                                            self.requestApproval();
                                        }
                                    }
                                }
                            },
                            .newline => {
                                const editor = &self.editors.items[self.focused];
                                const tail = try ctx.scratch_arena.dupe(
                                    u8,
                                    editor.text()[editor.cursor..],
                                );
                                try editor.killToEnd();
                                const next = self.focused + 1;
                                try self.addLine();
                                var new = self.editors.pop().?;
                                errdefer new.deinit();
                                try new.insert(tail);
                                new.moveHome();
                                try self.editors.insert(self.gpa, next, new);
                                self.focused = next;
                            },
                            .approval => self.requestApproval(),
                            .popover => self.help = if (self.help == .popover) .none else .popover,
                            .modal => self.help = if (self.help == .modal) .none else .modal,
                            .collapse => self.card.collapseLadder(-1),
                            .expand => self.card.collapseLadder(1),
                            .layout => self.diff_layout = if (self.diff_layout == .unified)
                                .side_by_side
                            else
                                .unified,
                        }
                        return .none;
                    }
                    if (k.matches(Key.backspace, .{}) and self.focused > 0 and
                        self.editors.items[self.focused].text().len == 0)
                    {
                        var removed = self.editors.orderedRemove(self.focused);
                        removed.deinit();
                        self.focused -= 1;
                        return .none;
                    }
                }
                if (ev == .paste) {
                    var lines = std.mem.splitScalar(u8, ev.paste, '\n');
                    if (lines.next()) |line| try self.editors.items[self.focused].paste(line);
                    while (lines.next()) |line| {
                        try self.addLine();
                        try self.editors.items[self.focused].paste(line);
                    }
                } else _ = try self.editors.items[self.focused].key(ev);
                if (self.completion_open) try self.complete(false);
            },
        }
        return .none;
    }

    pub fn view(self: *const Model, ctx: *Context) notui.view.View(Model) {
        // Context exposes band height, not viewport height. Region is the public geometry owner.
        const available = @max(3, ctx.region.term_rows);
        const extra: usize = if (self.streaming or self.card_visible) 16 else 0;
        const overlay: usize = if (self.approval != null or self.help != .none) 10 else 0;
        const popup: usize = if (self.completion_open) self.completion_rows else 0;
        const desired = @max(3 + self.editors.items.len + extra + popup, overlay);
        return .{ .draw = draw, .height = @intCast(@min(available, desired)) };
    }

    fn draw(self: *Model, ctx: *Context, buf: *Buffer) DrawError!void {
        const now = std.Io.Timestamp.now(ctx.io, .awake);
        const accent = Theme.dark.style(.accent, ctx.color_profile);
        const dim = Theme.dark.style(.text_dim, ctx.color_profile);
        const input_rows: u16 = @intCast(@min(self.editors.items.len, buf.height -| 3));
        const input_top = buf.height -| (input_rows + 2);
        const title = try std.fmt.bufPrint(
            &self.title_buf,
            "notui agent | turn {d} | {s}",
            .{ self.turns, if (self.streaming) "streaming" else "ready" },
        );
        _ = try buf.draw(accent, title, 0, 0);
        if (self.streaming) {
            const block = try self.markdown.render(reply[0..self.streamed], options(ctx));
            // Limit the markdown view to the space above the input, never paint through it.
            const height = buf.height;
            buf.height = input_top;
            defer buf.height = height;
            try paintMarkdown(block, buf, 1);
        } else if (self.card_visible) {
            const height = buf.height;
            buf.height = input_top;
            defer buf.height = height;
            _ = try self.card.draw(buf, 0, 1, now);
            const card_rows: u16 = @intCast(self.card.rows(buf.width));
            var diff: C.Diff = .{
                .hunks = self.hunks.items,
                .layout = self.diff_layout,
                .look = .{
                    .add = Theme.dark.style(.success, ctx.color_profile),
                    .del = Theme.dark.style(.@"error", ctx.color_profile),
                    .meta = dim,
                },
            };
            _ = try diff.draw(buf, 0, card_rows + 1, now);
        }
        const first = if (self.focused >= input_rows) self.focused + 1 - input_rows else 0;
        for (self.editors.items[first..][0..input_rows], 0..) |*editor, i| {
            const y: u16 = input_top + @as(u16, @intCast(i));
            _ = try buf.draw(accent, if (i + first == self.focused) "> " else "  ", 0, y);
            editor.visible = i + first == self.focused and self.approval == null;
            editor.cursor_style = .{ .attrs = .{ .reverse = editor.visible } };
            _ = try editor.draw(buf, 2, y, now);
        }
        if (self.streaming) {
            self.spinner.style = dim;
            _ = try self.spinner.draw(buf, 0, buf.height -| 2, now);
        } else _ = try buf.draw(
            dim,
            "Tab: /command or @file | ^Z undo | ^U kill | ^Y yank",
            0,
            buf.height -| 2,
        );
        _ = try self.keymap.renderHints(buf, 0, buf.height -| 1, now, .{
            .key_style = accent,
            .desc_style = dim,
        });
        if (self.completion_open) {
            var popup = self.suggestions();
            const text = self.editors.items[self.focused].text();
            _ = popup.setItemsFuzzy(text, &self.matches) catch 0;
            const y = input_top -| @as(u16, @intCast(@min(5, popup.candidates.len)));
            _ = try popup.draw(ctx.allocator, buf, 2, y, now);
        }
        if (self.approval != null) {
            var modal: C.Modal = .{
                .title = "Allow tool run?",
                .body = "zig build test (scripted; no execution)",
                .footer = "Up/Down choose, Enter accept, Esc deny",
                .width = 46,
                .height = 10,
                .title_style = accent,
                .border_style = dim,
            };
            _ = try modal.draw(buf, 0, 0, now);
            const left = (buf.width -| @min(buf.width, modal.width)) / 2;
            const top = (buf.height -| @min(buf.height, modal.height)) / 2;
            self.approval.?.width = @min(38, buf.width -| 4);
            _ = try self.approval.?.draw(buf, left + 2, top + 3, now);
        } else if (self.help == .popover) {
            var popup: C.Popover = .{
                .width = 45,
                .lines = &.{
                    "Editor: ^N split, empty Backspace joins",
                    "^Z undo; ^U/^K kill; ^Y yank; M-Y cycle",
                    "Tab completion; ^R / ^X card ladder",
                    "Esc closes this popover",
                },
                .style = dim,
                .border_style = accent,
            };
            _ = try popup.draw(buf, buf.width -| 45, input_top, now);
        } else if (self.help == .modal) {
            var modal: C.Modal = .{
                .title = "Coding-agent demo controls",
                .body = "Enter submit; ^N new input line; Up/Down input focus\n" ++
                    "Tab completes /commands and @files\n" ++
                    "^G approval; ^P popover; ^T diff layout\n" ++
                    "^R fold; ^X expand; ^Z undo; ^Y yank\n" ++
                    "/stream skips approval; --script runs 40 turns",
                .footer = "Esc closes; Ctrl+C exits",
                .width = 65,
                .height = 10,
                .title_style = accent,
                .border_style = dim,
            };
            _ = try modal.draw(buf, 0, 0, now);
        }
    }
};

fn filter(ctx: *Context, event: Event) ?Model.Msg {
    var ev = event;
    // Input.Reader owns scratch that may be reused before the reducer sees queued messages.
    switch (ev) {
        .key_press => |*key| if (key.text) |text| {
            key.text = ctx.frame_arena.dupe(u8, text) catch return null;
        },
        .paste => |*text| text.* = ctx.frame_arena.dupe(u8, text.*) catch return null,
        else => return null,
    }
    return .{ .input = ev };
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--self-test")) return selfTest(init.gpa);
        if (std.mem.eql(u8, arg, "--script")) scripted = true;
    }
    var app = notui.app.App(Model).initWithOptions(.{
        .fps = 30,
        .terminal_reflow = .{ .non_cursor_rows = .{ .scrollback_rows = 20000 } },
    });
    app.setFilter(&filter);
    try app.run(init.io, init.gpa);
}
