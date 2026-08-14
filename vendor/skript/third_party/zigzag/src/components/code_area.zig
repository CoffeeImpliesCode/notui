//! Multi-line text area component.
//! Provides text editing with multiple lines, cursor navigation, and scrolling.

const std = @import("std");
const Writer = std.Io.Writer;
const keys = @import("../input/keys.zig");
const style_mod = @import("../style/style.zig");
const Color = @import("../style/color.zig").Color;
const unicode = @import("../unicode.zig");

pub const CodeArea = struct {
    /// A styled byte range over the buffer text (as returned by getValue).
    /// Ranges must be sorted by `start` and non-overlapping; `end` is exclusive.
    pub const StyleRange = struct {
        start: usize,
        end: usize,
        style: style_mod.Style,
    };

    /// Completion candidate provider. `ctx` is an opaque embedder context
    /// (the REPL passes its runtime + arena); `prefix` is the identifier
    /// immediately left of the cursor at query time. Returns the matching
    /// candidates (case-sensitive prefix match), borrowed — they must
    /// remain valid until the popup closes or the next query. The popup
    /// shows whenever at least one candidate is returned.
    pub const CompletionProvider = struct {
        ctx: *const anyopaque,
        candidates: *const fn (ctx: *const anyopaque, prefix: []const u8) []const []const u8,
    };

    allocator: std.mem.Allocator,

    // Content
    lines: std.array_list.Managed(std.array_list.Managed(u8)),

    // Cursor position
    cursor_row: usize,
    cursor_col: usize,

    // Viewport
    viewport_row: usize,
    viewport_col: usize,
    width: u16,
    height: u16,

    // Appearance
    placeholder: []const u8,
    line_numbers: bool,
    word_wrap: bool,

    // Styling
    text_style: style_mod.Style,
    cursor_style: style_mod.Style,
    line_number_style: style_mod.Style,
    placeholder_style: style_mod.Style,

    // Query styling (byte ranges over the buffer text, sorted, non-overlapping)
    styles: []const StyleRange = &.{},

    // State
    focused: bool,

    // Limits
    max_lines: ?usize,
    max_cols: ?usize,
    char_limit: ?usize,

    // Auto-pair editing
    /// When true, typing an opening bracket inserts the matching closing
    /// bracket with the cursor between them; typing a closing bracket
    /// skips over an identical one right of the cursor; backspace
    /// collapses an empty bracket pair. Set to false for plain
    /// TextArea behavior.
    auto_pairs: bool = true,

    // Completion popup
    /// Candidate provider hook; null disables completion. Candidates are
    /// borrowed (they must stay valid until the popup closes or the next
    /// query), so embedders allocate them from a long-lived arena.
    completion_provider: ?CompletionProvider = null,
    /// Candidates of the active popup (borrowed; see completion_provider).
    completion_candidates: []const []const u8 = &.{},
    /// Index of the highlighted candidate.
    completion_selection: usize = 0,
    /// Set when the user pressed Tab to actively pick a candidate; Space
    /// accepts ONLY then. Without a Tab the popup is passive and Space
    /// types a literal space (normal input).
    completion_tabbed: bool = false,
    /// Byte offset of the completed word's start in the cursor line.
    completion_prefix_start: usize = 0,
    /// Minimum identifier-prefix length before the popup triggers (typing
    /// fewer chars shows nothing; the candidates need a real prefix).
    completion_min_prefix: u8 = 2,

    const WrappedSegment = struct {
        start: usize,
        end: usize,
        is_last: bool,
    };

    const WrappedRow = struct {
        line_idx: usize,
        start: usize,
        end: usize,
        is_first_segment: bool,
    };

    const CursorWrappedSegment = struct {
        current_start: usize,
        current_end: usize,
        prev_start: ?usize,
        is_last: bool,
    };

    pub fn init(allocator: std.mem.Allocator) CodeArea {
        var self: CodeArea = .{
            .allocator = allocator,
            .lines = .init(allocator),
            .cursor_row = 0,
            .cursor_col = 0,
            .viewport_row = 0,
            .viewport_col = 0,
            .width = 80,
            .height = 10,
            .placeholder = "",
            .line_numbers = false,
            .word_wrap = false,
            .text_style = blk: {
                var s = style_mod.Style{};
                s = s.inline_style(true);
                break :blk s;
            },
            .cursor_style = blk: {
                var s = style_mod.Style{};
                s = s.reverse(true);
                s = s.inline_style(true);
                break :blk s;
            },
            .line_number_style = blk: {
                var s = style_mod.Style{};
                s = s.fg(.gray(12));
                s = s.inline_style(true);
                break :blk s;
            },
            .placeholder_style = blk: {
                var s = style_mod.Style{};
                s = s.fg(.gray(12));
                s = s.inline_style(true);
                break :blk s;
            },
            .styles = &.{},
            .focused = true,
            .max_lines = null,
            .max_cols = null,
            .char_limit = null,
        };
        // OOM on the initial empty line: keep the empty buffer (the view
        // degrades gracefully to no lines).
        self.lines.append(std.array_list.Managed(u8).init(allocator)) catch self.lines.clearRetainingCapacity();
        return self;
    }

    pub fn deinit(self: *CodeArea) void {
        for (self.lines.items) |*line| {
            line.deinit();
        }
        self.lines.deinit();
        self.* = undefined;
    }

    /// Set the content
    pub fn setValue(self: *CodeArea, text: []const u8) !void {
        // A content reset invalidates the completed word position.
        self.hideCompletion();

        // Clear existing lines
        for (self.lines.items) |*line| {
            line.deinit();
        }
        self.lines.clearRetainingCapacity();

        // Parse lines
        var iter = std.mem.splitScalar(u8, text, '\n');
        while (iter.next()) |line_text| {
            var line = std.array_list.Managed(u8).init(self.allocator);
            try line.appendSlice(line_text);
            try self.lines.append(line);
        }

        if (self.lines.items.len == 0) {
            try self.lines.append(std.array_list.Managed(u8).init(self.allocator));
        }

        // Reset cursor
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.viewport_row = 0;
    }

    /// Get the content as a string
    pub fn getValue(self: *const CodeArea, allocator: std.mem.Allocator) ![]const u8 {
        var result: std.array_list.Managed(u8) = .init(allocator);

        for (self.lines.items, 0..) |line, i| {
            if (i > 0) try result.append('\n');
            try result.appendSlice(line.items);
        }

        return result.toOwnedSlice();
    }

    /// Get total character count
    pub fn charCount(self: *const CodeArea) usize {
        var count: usize = 0;
        for (self.lines.items, 0..) |line, i| {
            if (i > 0) count += 1; // Newline
            count += line.items.len;
        }
        return count;
    }

    /// Get line count
    pub fn lineCount(self: *const CodeArea) usize {
        return self.lines.items.len;
    }

    /// Set dimensions
    pub fn setSize(self: *CodeArea, width: u16, height: u16) void {
        self.width = width;
        self.height = height;
        self.ensureVisible();
    }

    /// Focus the text area
    pub fn focus(self: *CodeArea) void {
        self.focused = true;
    }

    /// Blur the text area
    pub fn blur(self: *CodeArea) void {
        self.focused = false;
    }

    /// Set query-styling ranges.
    /// Ranges use byte offsets into the buffer text (as returned by getValue),
    /// must be sorted by `start`, and must not overlap. `end` is exclusive.
    /// The slice is borrowed, not copied.
    pub fn setStyles(self: *CodeArea, styles: []const StyleRange) void {
        self.styles = styles;
    }

    /// Handle key event
    pub fn handleKey(self: *CodeArea, key: keys.KeyEvent) void {
        if (!self.focused) return;

        // Completion popup keys. Tab cycles the selection, Space accepts
        // (no literal space), Esc cancels. The REPL translates .tab/.space
        // to char events (kitty keyboard protocol), so the char forms are
        // accepted too. Any other key dismisses the popup and processes
        // normally — the trigger below then re-queries when the key typed
        // an identifier character.
        if (self.completionActive()) {
            switch (key.key) {
                .tab => {
                    self.cycleCompletion();
                    return;
                },
                .space => {
                    if (self.completion_tabbed) {
                        self.acceptCompletion();
                        return;
                    }
                    // No Tab pressed: Space is normal text input — fall
                    // through to insert the space; the popup hides below.
                },
                .escape => {
                    self.hideCompletion();
                    return;
                },
                .char => |c| {
                    if (c == '\t') {
                        self.cycleCompletion();
                        return;
                    }
                    if (c == ' ') {
                        if (self.completion_tabbed) {
                            self.acceptCompletion();
                            return;
                        }
                        // Fall through: literal space, popup hides below.
                    }
                },
                else => {},
            }
            self.hideCompletion();
        }

        if (key.modifiers.ctrl) {
            switch (key.key) {
                .char => |c| switch (c) {
                    'a' => self.cursor_col = 0, // Home
                    'e' => self.cursor_col = self.currentLine().items.len, // End
                    'k' => self.killToEndOfLine(), // Kill line
                    'u' => self.killToStartOfLine(), // Kill to start
                    'd' => self.deleteLine(), // Delete line
                    else => {},
                },
                else => {},
            }
            return;
        }

        switch (key.key) {
            .char => |c| self.insertCharAuto(c),
            .paste => |text| self.insertText(text),
            .enter => self.insertNewline(),
            .backspace => self.deleteBackward(),
            .delete => self.deleteForward(),
            .up => self.moveCursorUp(),
            .down => self.moveCursorDown(),
            .left => self.moveCursorLeft(),
            .right => self.moveCursorRight(),
            .home => self.cursor_col = 0,
            .end => self.cursor_col = self.currentLine().items.len,
            .page_up => self.pageUp(),
            .page_down => self.pageDown(),
            .tab => self.insertTab(),
            else => {},
        }

        self.ensureVisible();

        // Completion trigger: typing an identifier character queries the
        // provider for the word immediately left of the cursor. Ctrl is
        // impossible here (handled above); alt/super-modified chars are
        // not identifier typing.
        if (self.completion_provider) |provider| {
            if (!key.modifiers.alt and !key.modifiers.super) {
                switch (key.key) {
                    .char => |c| if (isCompletionChar(c)) self.refreshCompletion(provider),
                    else => {},
                }
            }
        }
    }

    // --- Completion ---------------------------------------------------------

    /// True while the completion popup is visible.
    pub fn completionActive(self: *const CodeArea) bool {
        return self.completion_provider != null and self.completion_candidates.len > 0;
    }

    /// Dismiss the popup (keeps the text untouched).
    fn hideCompletion(self: *CodeArea) void {
        self.completion_candidates = &.{};
        self.completion_selection = 0;
        self.completion_tabbed = false;
    }

    /// Query the provider for the word immediately left of the cursor and
    /// show the popup when at least one candidate matches. The word is the
    /// maximal run of identifier characters ending at the cursor.
    fn refreshCompletion(self: *CodeArea, provider: CompletionProvider) void {
        const line = self.currentLine().items;
        const cursor = @min(self.cursor_col, line.len);
        var start = cursor;
        while (start > 0 and isCompletionChar(line[start - 1])) start -= 1;
        if (start == cursor or cursor - start < self.completion_min_prefix) {
            self.hideCompletion();
            return;
        }
        const candidates = provider.candidates(provider.ctx, line[start..cursor]);
        if (candidates.len == 0) {
            self.hideCompletion();
            return;
        }
        self.completion_candidates = candidates;
        self.completion_selection = 0;
        self.completion_tabbed = false;
        self.completion_prefix_start = start;
    }

    /// Move the selection to the next candidate (wrapping around).
    fn cycleCompletion(self: *CodeArea) void {
        if (self.completion_candidates.len <= 1) {
            self.completion_tabbed = true;
            return;
        }
        if (self.completion_tabbed) {
            // Already picking: advance to the next candidate (wraps).
            self.completion_selection = (self.completion_selection + 1) % self.completion_candidates.len;
        } else {
            // First Tab: select the FIRST candidate (it is not highlighted
            // until now, so the first candidate is reachable with Tab+Space).
            self.completion_tabbed = true;
            self.completion_selection = 0;
        }
    }

    /// Accept the selected candidate: replace the word under the cursor
    /// with it and close the popup; the cursor lands at the candidate's
    /// end.
    fn acceptCompletion(self: *CodeArea) void {
        if (self.completion_selection >= self.completion_candidates.len) {
            self.hideCompletion();
            return;
        }
        const candidate = self.completion_candidates[self.completion_selection];
        const line = self.currentLine();
        const start = @min(self.completion_prefix_start, line.items.len);
        const end = @max(start, @min(self.cursor_col, line.items.len));
        line.replaceRange(start, end - start, candidate) catch {
            self.hideCompletion();
            return;
        };
        self.cursor_col = start + candidate.len;
        // Accepting also inserts the literal space — the common case is
        // completing the word and continuing to type the next one.
        self.insertChar(' ');
        self.hideCompletion();
        self.ensureVisible();
    }

    /// True for characters that can appear in a symbol name: ASCII
    /// alphanumerics plus the skript symbol characters. Words are built
    /// from these (see refreshCompletion).
    fn isCompletionChar(c: u21) bool {
        if (c >= 128) return false;
        const b: u8 = @intCast(c);
        if (std.ascii.isAlphanumeric(b)) return true;
        return switch (b) {
            '-', '_', '?', '!', '*', '/', '<', '>', '=', '+', '.', ':' => true,
            else => false,
        };
    }

    fn currentLine(self: *CodeArea) *std.array_list.Managed(u8) {
        return &self.lines.items[self.cursor_row];
    }

    fn insertChar(self: *CodeArea, c: u21) void {
        // Check char limit
        if (self.char_limit) |limit| {
            if (self.charCount() >= limit) return;
        }

        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(c, &buf) catch return;

        const line = self.currentLine();
        const pos = @min(self.cursor_col, line.items.len);
        line.insertSlice(pos, buf[0..len]) catch return;
        self.cursor_col = pos + len;
    }

    /// The closing bracket matching an opening bracket, or null.
    fn matchingClose(open: u8) ?u8 {
        return switch (open) {
            '(' => ')',
            '[' => ']',
            '{' => '}',
            else => null,
        };
    }

    /// Insert a character with auto-pair behavior (see `auto_pairs`):
    /// an opening bracket inserts its matching closing bracket with the
    /// cursor between them; a closing bracket skips over an identical
    /// one immediately right of the cursor instead of inserting a
    /// duplicate. Falls back to plain insertion otherwise.
    fn insertCharAuto(self: *CodeArea, c: u21) void {
        if (self.auto_pairs) {
            switch (c) {
                '(', '[', '{' => {
                    const close: u21 = switch (c) {
                        '(' => ')',
                        '[' => ']',
                        '{' => '}',
                        else => unreachable,
                    };
                    self.insertPair(c, close);
                    return;
                },
                ')', ']', '}' => {
                    const line = self.currentLine();
                    if (self.cursor_col < line.items.len and line.items[self.cursor_col] == c) {
                        self.cursor_col += 1;
                        return;
                    }
                },
                else => {},
            }
        }
        self.insertChar(c);
    }

    /// Insert an opening/closing bracket pair with the cursor between them.
    fn insertPair(self: *CodeArea, open: u21, close: u21) void {
        // Reserve room for both characters; otherwise insert the opening
        // bracket alone via the plain path.
        if (self.char_limit) |limit| {
            if (self.charCount() + 2 > limit) {
                self.insertChar(open);
                return;
            }
        }

        const line = self.currentLine();
        const pos = @min(self.cursor_col, line.items.len);

        var open_buf: [4]u8 = undefined;
        const open_len = std.unicode.utf8Encode(open, &open_buf) catch return;
        var close_buf: [4]u8 = undefined;
        const close_len = std.unicode.utf8Encode(close, &close_buf) catch return;

        line.insertSlice(pos, open_buf[0..open_len]) catch return;
        line.insertSlice(pos + open_len, close_buf[0..close_len]) catch return;
        self.cursor_col = pos + open_len;
    }

    fn insertText(self: *CodeArea, text: []const u8) void {
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '\r') {
                self.insertNewline();
                if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
                i += 1;
                continue;
            }
            if (text[i] == '\n') {
                self.insertNewline();
                i += 1;
                continue;
            }

            const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
                self.insertChar(text[i]);
                i += 1;
                continue;
            };
            if (i + len > text.len) {
                self.insertChar(text[i]);
                i += 1;
                continue;
            }

            const codepoint = decodeSlice(text[i .. i + len]) catch {
                self.insertChar(text[i]);
                i += 1;
                continue;
            };
            self.insertChar(codepoint);
            i += len;
        }
    }

    fn insertNewline(self: *CodeArea) void {
        if (self.max_lines) |max| {
            if (self.lines.items.len >= max) return;
        }

        self.clampCursorToLineBoundary();
        const line = self.currentLine();
        const rest = line.items[self.cursor_col..];

        // Create new line with rest of content
        var new_line = std.array_list.Managed(u8).init(self.allocator);
        new_line.appendSlice(rest) catch return;

        // Truncate current line
        line.shrinkRetainingCapacity(self.cursor_col);

        // Insert new line
        self.lines.insert(self.cursor_row + 1, new_line) catch return;

        self.cursor_row += 1;
        self.cursor_col = 0;
    }

    fn insertTab(self: *CodeArea) void {
        // Insert spaces for tab
        for (0..4) |_| {
            self.insertChar(' ');
        }
    }

    fn deleteBackward(self: *CodeArea) void {
        // Collapse an empty bracket pair: when the cursor sits between a
        // matching open/close pair, backspace deletes both characters.
        if (self.auto_pairs and self.cursor_col > 0) {
            const line = self.currentLine();
            if (self.cursor_col < line.items.len) {
                if (matchingClose(line.items[self.cursor_col - 1])) |expected| {
                    if (expected == line.items[self.cursor_col]) {
                        _ = line.orderedRemove(self.cursor_col);
                        _ = line.orderedRemove(self.cursor_col - 1);
                        self.cursor_col -= 1;
                        return;
                    }
                }
            }
        }

        if (self.cursor_col > 0) {
            // Delete character before cursor
            const line = self.currentLine();
            var pos = self.cursor_col - 1;

            // Find start of UTF-8 sequence
            while (pos > 0 and (line.items[pos] & 0xC0) == 0x80) {
                pos -= 1;
            }

            const len = self.cursor_col - pos;
            for (0..len) |_| {
                _ = line.orderedRemove(pos);
            }
            self.cursor_col = pos;
        } else if (self.cursor_row > 0) {
            // Join with previous line
            const current = self.lines.orderedRemove(self.cursor_row);
            self.cursor_row -= 1;
            const prev_line = self.currentLine();
            self.cursor_col = prev_line.items.len;
            prev_line.appendSlice(current.items) catch return;
            @constCast(&current).deinit();
        }
    }

    fn deleteForward(self: *CodeArea) void {
        const line = self.currentLine();
        self.clampCursorToLineBoundary();
        if (self.cursor_col < line.items.len) {
            // Delete character at cursor
            const byte_len = std.unicode.utf8ByteSequenceLength(line.items[self.cursor_col]) catch 1;
            for (0..byte_len) |_| {
                if (self.cursor_col < line.items.len) {
                    _ = line.orderedRemove(self.cursor_col);
                }
            }
        } else if (self.cursor_row < self.lines.items.len - 1) {
            // Join with next line
            const next = self.lines.orderedRemove(self.cursor_row + 1);
            line.appendSlice(next.items) catch return;
            @constCast(&next).deinit();
        }
    }

    fn killToEndOfLine(self: *CodeArea) void {
        self.clampCursorToLineBoundary();
        const line = self.currentLine();
        line.shrinkRetainingCapacity(self.cursor_col);
    }

    fn killToStartOfLine(self: *CodeArea) void {
        self.clampCursorToLineBoundary();
        const line = self.currentLine();
        @memmove(line.items[0..], line.items[self.cursor_col..]);
        line.shrinkRetainingCapacity(line.items.len - self.cursor_col);
        self.cursor_col = 0;
    }

    fn deleteLine(self: *CodeArea) void {
        if (self.lines.items.len > 1) {
            var removed = self.lines.orderedRemove(self.cursor_row);
            removed.deinit();
            if (self.cursor_row >= self.lines.items.len) {
                self.cursor_row = self.lines.items.len - 1;
            }
            self.cursor_col = @min(self.cursor_col, self.currentLine().items.len);
            self.clampCursorToLineBoundary();
        } else {
            self.currentLine().clearRetainingCapacity();
            self.cursor_col = 0;
        }
    }

    fn moveCursorUp(self: *CodeArea) void {
        if (self.word_wrap) {
            const max_width = self.textWidth();
            const line = self.currentLine().items;
            const segment = self.findCursorWrappedSegment(line, max_width);
            const target_col = displayWidthInRange(line, segment.current_start, self.cursor_col, max_width);

            if (segment.prev_start) |prev_start| {
                const prev = wrappedSegmentAt(line, max_width, prev_start);
                self.cursor_col = byteOffsetForDisplayCol(line, prev.start, prev.end, target_col, max_width);
                return;
            }

            if (self.cursor_row > 0) {
                self.cursor_row -= 1;
                const prev_line = self.currentLine().items;
                const prev_start = lastWrappedSegmentStart(prev_line, max_width);
                const prev = wrappedSegmentAt(prev_line, max_width, prev_start);
                self.cursor_col = byteOffsetForDisplayCol(prev_line, prev.start, prev.end, target_col, max_width);
            }
            return;
        }

        if (self.cursor_row > 0) {
            self.cursor_row -= 1;
            self.cursor_col = @min(self.cursor_col, self.currentLine().items.len);
            self.clampCursorToLineBoundary();
        }
    }

    fn moveCursorDown(self: *CodeArea) void {
        if (self.word_wrap) {
            const max_width = self.textWidth();
            const line = self.currentLine().items;
            const segment = self.findCursorWrappedSegment(line, max_width);
            const target_col = displayWidthInRange(line, segment.current_start, self.cursor_col, max_width);

            if (!segment.is_last) {
                const next = wrappedSegmentAt(line, max_width, segment.current_end);
                self.cursor_col = byteOffsetForDisplayCol(line, next.start, next.end, target_col, max_width);
                return;
            }

            if (self.cursor_row < self.lines.items.len - 1) {
                self.cursor_row += 1;
                const next_line = self.currentLine().items;
                const next = wrappedSegmentAt(next_line, max_width, 0);
                self.cursor_col = byteOffsetForDisplayCol(next_line, next.start, next.end, target_col, max_width);
            }
            return;
        }

        if (self.cursor_row < self.lines.items.len - 1) {
            self.cursor_row += 1;
            self.cursor_col = @min(self.cursor_col, self.currentLine().items.len);
            self.clampCursorToLineBoundary();
        }
    }

    fn moveCursorLeft(self: *CodeArea) void {
        self.clampCursorToLineBoundary();
        if (self.cursor_col > 0) {
            self.cursor_col -= 1;
            // Handle UTF-8 continuation bytes
            const line = self.currentLine();
            while (self.cursor_col > 0 and (line.items[self.cursor_col] & 0xC0) == 0x80) {
                self.cursor_col -= 1;
            }
        } else if (self.cursor_row > 0) {
            self.cursor_row -= 1;
            self.cursor_col = self.currentLine().items.len;
        }
    }

    fn moveCursorRight(self: *CodeArea) void {
        const line = self.currentLine();
        self.clampCursorToLineBoundary();
        if (self.cursor_col < line.items.len) {
            const byte_len = std.unicode.utf8ByteSequenceLength(line.items[self.cursor_col]) catch 1;
            self.cursor_col = @min(self.cursor_col + byte_len, line.items.len);
        } else if (self.cursor_row < self.lines.items.len - 1) {
            self.cursor_row += 1;
            self.cursor_col = 0;
        }
    }

    fn pageUp(self: *CodeArea) void {
        if (self.word_wrap) {
            for (0..@max(@as(usize, 1), @as(usize, self.height))) |_| {
                self.moveCursorUp();
            }
            return;
        }

        if (self.cursor_row >= self.height) {
            self.cursor_row -= self.height;
        } else {
            self.cursor_row = 0;
        }
        self.cursor_col = @min(self.cursor_col, self.currentLine().items.len);
        self.clampCursorToLineBoundary();
    }

    fn pageDown(self: *CodeArea) void {
        if (self.word_wrap) {
            for (0..@max(@as(usize, 1), @as(usize, self.height))) |_| {
                self.moveCursorDown();
            }
            return;
        }

        if (self.cursor_row + self.height < self.lines.items.len) {
            self.cursor_row += self.height;
        } else {
            self.cursor_row = self.lines.items.len - 1;
        }
        self.cursor_col = @min(self.cursor_col, self.currentLine().items.len);
        self.clampCursorToLineBoundary();
    }

    fn ensureVisible(self: *CodeArea) void {
        const visible_rows: usize = @max(@as(usize, 1), @as(usize, self.height));

        if (self.word_wrap) {
            const cursor_visual_row = self.cursorVisualRow(self.textWidth());
            if (cursor_visual_row < self.viewport_row) {
                self.viewport_row = cursor_visual_row;
            } else if (cursor_visual_row >= self.viewport_row + visible_rows) {
                self.viewport_row = cursor_visual_row - visible_rows + 1;
            }
            self.viewport_col = 0;
            return;
        }

        // Vertical scrolling
        if (self.cursor_row < self.viewport_row) {
            self.viewport_row = self.cursor_row;
        } else if (self.cursor_row >= self.viewport_row + visible_rows) {
            self.viewport_row = self.cursor_row - visible_rows + 1;
        }

        // Horizontal scrolling using display columns
        const effective_width = self.width -| (if (self.line_numbers) @as(u16, 5) else 0);
        const display_col = self.cursorDisplayCol();
        if (display_col < self.viewport_col) {
            self.viewport_col = display_col;
        } else if (display_col >= self.viewport_col + effective_width) {
            self.viewport_col = display_col - effective_width + 1;
        }
    }

    /// Cursor column in terminal cells (display width), 0-indexed.
    pub fn cursorDisplayColumn(self: *const CodeArea) usize {
        return self.cursorDisplayCol();
    }

    /// Render the text area
    pub fn view(self: *const CodeArea, allocator: std.mem.Allocator) ![]const u8 {
        var result: Writer.Allocating = .init(allocator);
        const writer = &result.writer;

        const line_num_width: usize = if (self.line_numbers) 5 else 0;
        const text_width = self.width -| @as(u16, @intCast(line_num_width));

        // Check for empty content
        const is_empty = self.lines.items.len == 1 and self.lines.items[0].items.len == 0;

        if (self.word_wrap) {
            for (0..self.height) |row| {
                if (row > 0) try writer.writeByte('\n');

                const visual_row = self.viewport_row + row;
                const wrapped_row = self.wrappedRowAt(visual_row, text_width);

                // Line numbers (only on first wrapped segment of a physical line)
                if (self.line_numbers) {
                    if (wrapped_row) |r| {
                        if (r.is_first_segment) {
                            const num_str = try std.fmt.allocPrint(allocator, "{d:>4} ", .{r.line_idx + 1});
                            defer allocator.free(num_str);
                            const styled = try self.line_number_style.render(allocator, num_str);
                            defer allocator.free(styled);
                            try writer.writeAll(styled);
                        } else {
                            try writer.writeAll("     ");
                        }
                    } else {
                        try writer.writeAll("     ");
                    }
                }

                if (wrapped_row) |r| {
                    const line = self.lines.items[r.line_idx];

                    // Show placeholder on first empty line
                    if (is_empty and r.line_idx == 0 and r.is_first_segment and self.placeholder.len > 0) {
                        try self.renderPlaceholder(allocator, writer, text_width);
                        continue;
                    }

                    try self.renderWrappedLineSegment(
                        allocator,
                        writer,
                        line.items,
                        r.line_idx,
                        r.start,
                        r.end,
                        text_width,
                    );
                } else {
                    for (0..text_width) |_| {
                        try writer.writeByte(' ');
                    }
                }
            }

            return result.toOwnedSlice();
        }

        for (0..self.height) |row| {
            if (row > 0) try writer.writeByte('\n');

            const line_idx = self.viewport_row + row;

            // Line numbers
            if (self.line_numbers) {
                if (line_idx < self.lines.items.len) {
                    const num_str = try std.fmt.allocPrint(allocator, "{d:>4} ", .{line_idx + 1});
                    defer allocator.free(num_str);
                    const styled = try self.line_number_style.render(allocator, num_str);
                    defer allocator.free(styled);
                    try writer.writeAll(styled);
                } else {
                    try writer.writeAll("     ");
                }
            }

            if (line_idx < self.lines.items.len) {
                const line = self.lines.items[line_idx];

                // Show placeholder on first empty line
                if (is_empty and line_idx == 0 and self.placeholder.len > 0) {
                    try self.renderPlaceholder(allocator, writer, text_width);
                    continue;
                }

                // Render line content with cursor
                try self.renderLine(allocator, writer, line.items, line_idx, text_width);
            } else {
                // Pad empty rows to full width
                var i: usize = 0;
                while (i < text_width) : (i += 1) {
                    try writer.writeByte(' ');
                }
            }
        }
        return result.toOwnedSlice();
    }

    /// Maximum candidates shown in the completion popup; the rest becomes
    /// a "… N more" line.
    const completion_max_visible: usize = 8;

    /// The completion popup as a framed string (bordered candidate list with
    /// the Tab-selected candidate in reverse video). Null when no popup is
    /// active. The EMBEDDER floats this over its layout at
    /// completionAnchor() — the popup is not part of the text-area view.
    pub fn completionPopup(self: *const CodeArea, allocator: std.mem.Allocator) !?[]const u8 {
        const candidates = self.completion_candidates;
        if (candidates.len == 0) return null;

        // Inner width: widest visible candidate, capped so the framed
        // popup fits the text area (one border char per side).
        const max_inner = @as(usize, self.width) -| 2;
        const shown = @min(candidates.len, completion_max_visible);

        var body: Writer.Allocating = .init(allocator);
        const body_writer = &body.writer;
        for (candidates[0..shown], 0..) |c, i| {
            if (i > 0) try body_writer.writeByte('\n');
            const line_text = try truncateToWidth(allocator, c, max_inner);
            defer allocator.free(line_text);
            const styled = if (self.completion_tabbed and i == self.completion_selection)
                try self.cursor_style.render(allocator, line_text)
            else
                try self.text_style.render(allocator, line_text);
            try body_writer.writeAll(styled);
        }
        if (candidates.len > shown) {
            try body_writer.writeByte('\n');
            const more = try std.fmt.allocPrint(allocator, "… {d} more", .{candidates.len - shown});
            defer allocator.free(more);
            const line_text = try truncateToWidth(allocator, more, max_inner);
            defer allocator.free(line_text);
            const styled = try self.text_style.render(allocator, line_text);
            try body_writer.writeAll(styled);
        }

        var box: style_mod.Style = .{};
        box = box.borderAll(.rounded);
        box = box.borderForeground(.gray(8));
        return @as(?[]const u8, try box.render(allocator, body.written()));
    }

    /// Where the popup should float: the START of the completed word's cell
    /// position within the text area (row 0 = first text line; col = display
    /// column of the prefix's first character).
    pub fn completionAnchor(self: *const CodeArea) struct { row: usize, col: usize } {
        const line = self.lines.items[self.cursor_row];
        const cursor = @min(self.cursor_col, line.items.len);
        const start = @min(self.completion_prefix_start, cursor);
        var display_col: usize = 0;
        var byte_idx: usize = 0;
        while (byte_idx < start) {
            const byte_len = std.unicode.utf8ByteSequenceLength(line.items[byte_idx]) catch 1;
            if (byte_idx + byte_len <= line.items.len) {
                const cp = decodeSlice(line.items[byte_idx..][0..byte_len]) catch {
                    byte_idx += 1;
                    display_col += 1;
                    continue;
                };
                display_col += unicode.charWidth(cp);
            }
            byte_idx += byte_len;
        }
        return .{ .row = self.cursor_row, .col = display_col };
    }

    /// Copy `text`, truncated to at most `max_width` display columns; an
    /// ellipsis is appended when it fits. Always allocates (caller frees).
    fn truncateToWidth(allocator: std.mem.Allocator, text: []const u8, max_width: usize) ![]const u8 {
        if (max_width == 0) return allocator.dupe(u8, "");
        var width: usize = 0;
        var end: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            const byte_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (i + byte_len > text.len) break;
            const cp = decodeSlice(text[i .. i + byte_len]) catch {
                if (width + 1 > max_width) break;
                width += 1;
                i += 1;
                end = i;
                continue;
            };
            const cw = unicode.charWidth(cp);
            if (width + cw > max_width) break;
            width += cw;
            i += byte_len;
            end = i;
        }
        if (end == text.len) return allocator.dupe(u8, text);
        if (width + 1 <= max_width) {
            const out = try allocator.alloc(u8, end + 3);
            @memcpy(out[0..end], text[0..end]);
            @memcpy(out[end..][0..3], "\xE2\x80\xA6");
            return out;
        }
        return allocator.dupe(u8, text[0..end]);
    }

    fn renderPlaceholder(self: *const CodeArea, allocator: std.mem.Allocator, writer: *Writer, max_width: u16) !void {
        const width_limit: usize = max_width;
        if (width_limit == 0) return;

        var rendered_width: usize = 0;
        var byte_idx: usize = 0;
        while (byte_idx < self.placeholder.len and rendered_width < width_limit) {
            const byte_len = std.unicode.utf8ByteSequenceLength(self.placeholder[byte_idx]) catch 1;
            if (byte_idx + byte_len > self.placeholder.len) break;
            const char_slice = self.placeholder[byte_idx..][0..byte_len];

            const cp = decodeSlice(char_slice) catch {
                byte_idx += 1;
                rendered_width += 1;
                continue;
            };
            const cw = wrapDisplayWidth(unicode.charWidth(cp), width_limit);
            if (rendered_width + cw > width_limit) break;

            const styled = try self.placeholder_style.render(allocator, char_slice);
            defer allocator.free(styled);
            try writer.writeAll(styled);
            byte_idx += byte_len;
            rendered_width += cw;
        }

        while (rendered_width < width_limit) {
            try writer.writeByte(' ');
            rendered_width += 1;
        }
    }

    fn renderWrappedLineSegment(
        self: *const CodeArea,
        allocator: std.mem.Allocator,
        writer: *Writer,
        line: []const u8,
        line_idx: usize,
        start: usize,
        end: usize,
        max_width: u16,
    ) !void {
        const is_cursor_line = line_idx == self.cursor_row;
        const line_offset = self.bufferOffsetOfLine(line_idx);
        var range_idx: usize = 0;
        const width_limit: usize = max_width;

        if (width_limit == 0) return;

        var rendered_width: usize = 0;
        var byte_idx = start;
        while (byte_idx < end and rendered_width < width_limit) {
            const is_cursor = is_cursor_line and self.focused and byte_idx == self.cursor_col;

            const byte_len = std.unicode.utf8ByteSequenceLength(line[byte_idx]) catch 1;
            if (byte_idx + byte_len > line.len) break;
            const char_slice = line[byte_idx..][0..byte_len];

            const cp = decodeSlice(char_slice) catch {
                byte_idx += 1;
                rendered_width += 1;
                continue;
            };
            const cw = wrapDisplayWidth(unicode.charWidth(cp), width_limit);
            if (rendered_width + cw > width_limit) break;

            if (is_cursor) {
                const styled = try self.cursor_style.render(allocator, char_slice);
                defer allocator.free(styled);
                try writer.writeAll(styled);
            } else if (self.styleForOffset(line_offset + byte_idx, &range_idx)) |style| {
                const styled = try style.render(allocator, char_slice);
                defer allocator.free(styled);
                try writer.writeAll(styled);
            } else {
                const styled = try self.text_style.render(allocator, char_slice);
                defer allocator.free(styled);
                try writer.writeAll(styled);
            }

            byte_idx += byte_len;
            rendered_width += cw;
        }

        // Cursor at segment end
        if (is_cursor_line and self.focused and self.cursor_col == end and
            end == line.len and rendered_width < width_limit)
        {
            const styled = try self.cursor_style.render(allocator, " ");
            defer allocator.free(styled);
            try writer.writeAll(styled);
            rendered_width += 1;
        }

        while (rendered_width < width_limit) {
            try writer.writeByte(' ');
            rendered_width += 1;
        }
    }

    fn renderLine(
        self: *const CodeArea,
        allocator: std.mem.Allocator,
        writer: *Writer,
        line: []const u8,
        line_idx: usize,
        max_width: u16,
    ) !void {
        const is_cursor_line = line_idx == self.cursor_row;
        const line_offset = self.bufferOffsetOfLine(line_idx);
        var range_idx: usize = 0;

        // Apply horizontal scroll
        var col: usize = 0;
        var byte_idx: usize = 0;

        // Skip to viewport_col (using display columns)
        while (col < self.viewport_col and byte_idx < line.len) {
            const byte_len = std.unicode.utf8ByteSequenceLength(line[byte_idx]) catch 1;
            if (byte_idx + byte_len <= line.len) {
                const cp = decodeSlice(line[byte_idx..][0..byte_len]) catch {
                    byte_idx += 1;
                    col += 1;
                    continue;
                };
                col += unicode.charWidth(cp);
            }
            byte_idx += byte_len;
        }

        // Render visible portion
        var rendered_width: usize = 0;
        while (byte_idx < line.len and rendered_width < max_width) {
            const is_cursor = is_cursor_line and self.focused and byte_idx == self.cursor_col;

            const byte_len = std.unicode.utf8ByteSequenceLength(line[byte_idx]) catch 1;
            if (byte_idx + byte_len > line.len) break;
            const char_slice = line[byte_idx..][0..byte_len];

            const cp = decodeSlice(line[byte_idx..][0..byte_len]) catch {
                byte_idx += 1;
                rendered_width += 1;
                continue;
            };
            const cw = unicode.charWidth(cp);

            // Wide char won't fit — stop
            if (rendered_width + cw > max_width) break;

            if (is_cursor) {
                const styled = try self.cursor_style.render(allocator, char_slice);
                defer allocator.free(styled);
                try writer.writeAll(styled);
            } else if (self.styleForOffset(line_offset + byte_idx, &range_idx)) |style| {
                const styled = try style.render(allocator, char_slice);
                defer allocator.free(styled);
                try writer.writeAll(styled);
            } else {
                const styled = try self.text_style.render(allocator, char_slice);
                defer allocator.free(styled);
                try writer.writeAll(styled);
            }

            byte_idx += byte_len;
            col += cw;
            rendered_width += cw;
        }

        // Cursor at end of line
        if (is_cursor_line and self.focused and byte_idx == self.cursor_col and rendered_width < max_width) {
            const styled = try self.cursor_style.render(allocator, " ");
            defer allocator.free(styled);
            try writer.writeAll(styled);
            rendered_width += 1;
        }

        // Pad remaining width
        while (rendered_width < max_width) {
            try writer.writeByte(' ');
            rendered_width += 1;
        }
    }

    /// Byte offset of the start of a line in the buffer text
    /// (lines joined by '\n' as produced by getValue).
    fn bufferOffsetOfLine(self: *const CodeArea, line_idx: usize) usize {
        var offset: usize = 0;
        for (self.lines.items[0..line_idx]) |line| {
            offset += line.items.len + 1; // +1 for the newline
        }
        return offset;
    }

    /// Find the style range covering `offset` in the buffer text, advancing
    /// `range_idx` monotonically. Ranges must be sorted and non-overlapping
    /// (the caller's contract); `end` is exclusive.
    fn styleForOffset(self: *const CodeArea, offset: usize, range_idx: *usize) ?style_mod.Style {
        while (range_idx.* < self.styles.len and self.styles[range_idx.*].end <= offset) {
            range_idx.* += 1;
        }
        if (range_idx.* < self.styles.len) {
            const range = self.styles[range_idx.*];
            if (offset >= range.start and offset < range.end) return range.style;
        }
        return null;
    }

    /// Convert byte-offset cursor_col to display column width.
    fn cursorDisplayCol(self: *const CodeArea) usize {
        const line = self.lines.items[self.cursor_row];
        var display_col: usize = 0;
        var byte_idx: usize = 0;
        while (byte_idx < self.cursor_col and byte_idx < line.items.len) {
            const byte_len = std.unicode.utf8ByteSequenceLength(line.items[byte_idx]) catch 1;
            if (byte_idx + byte_len <= line.items.len) {
                const cp = decodeSlice(line.items[byte_idx..][0..byte_len]) catch {
                    byte_idx += 1;
                    display_col += 1;
                    continue;
                };
                display_col += unicode.charWidth(cp);
            }
            byte_idx += byte_len;
        }
        return display_col;
    }

    fn textWidth(self: *const CodeArea) usize {
        const line_num_width: usize = if (self.line_numbers) 5 else 0;
        return self.width -| @as(u16, @intCast(line_num_width));
    }

    fn cursorVisualRow(self: *const CodeArea, max_width: usize) usize {
        var row: usize = 0;
        for (0..self.cursor_row) |idx| {
            row += wrappedRowCount(self.lines.items[idx].items, max_width);
        }
        row += wrappedRowIndexForCursor(self.lines.items[self.cursor_row].items, self.cursor_col, max_width);
        return row;
    }

    fn wrappedRowAt(self: *const CodeArea, visual_row: usize, max_width: u16) ?WrappedRow {
        var row_index: usize = 0;
        const width: usize = max_width;

        for (self.lines.items, 0..) |line, line_idx| {
            const line_bytes = line.items;
            if (line_bytes.len == 0) {
                if (row_index == visual_row) {
                    return .{
                        .line_idx = line_idx,
                        .start = 0,
                        .end = 0,
                        .is_first_segment = true,
                    };
                }
                row_index += 1;
                continue;
            }

            var segment_start: usize = 0;
            var first = true;
            while (true) {
                const segment = wrappedSegmentAt(line_bytes, width, segment_start);
                if (row_index == visual_row) {
                    return .{
                        .line_idx = line_idx,
                        .start = segment.start,
                        .end = segment.end,
                        .is_first_segment = first,
                    };
                }

                row_index += 1;
                if (segment.is_last) break;
                segment_start = segment.end;
                first = false;
            }
        }
        return null;
    }

    fn findCursorWrappedSegment(self: *const CodeArea, line: []const u8, max_width: usize) CursorWrappedSegment {
        const clamped_cursor = clampToUtf8Boundary(line, self.cursor_col);
        var segment_start: usize = 0;
        var prev_start: ?usize = null;
        while (true) {
            const segment = wrappedSegmentAt(line, max_width, segment_start);
            if (clamped_cursor < segment.end or segment.is_last) {
                return .{
                    .current_start = segment.start,
                    .current_end = segment.end,
                    .prev_start = prev_start,
                    .is_last = segment.is_last,
                };
            }

            if (segment.is_last) break;
            prev_start = segment_start;
            segment_start = segment.end;
        }

        return .{
            .current_start = 0,
            .current_end = line.len,
            .prev_start = null,
            .is_last = true,
        };
    }

    fn wrappedRowCount(line: []const u8, max_width: usize) usize {
        if (line.len == 0) return 1;
        if (max_width == 0) return 1;

        var count: usize = 0;
        var segment_start: usize = 0;
        while (true) {
            const segment = wrappedSegmentAt(line, max_width, segment_start);
            count += 1;
            if (segment.is_last) break;
            segment_start = segment.end;
        }
        return count;
    }

    fn wrappedRowIndexForCursor(line: []const u8, cursor_col: usize, max_width: usize) usize {
        if (line.len == 0) return 0;
        if (max_width == 0) return 0;

        const clamped_cursor = clampToUtf8Boundary(line, cursor_col);
        var index: usize = 0;
        var segment_start: usize = 0;
        while (true) {
            const segment = wrappedSegmentAt(line, max_width, segment_start);
            if (clamped_cursor < segment.end or segment.is_last) return index;
            if (segment.is_last) return index;
            index += 1;
            segment_start = segment.end;
        }
    }

    fn lastWrappedSegmentStart(line: []const u8, max_width: usize) usize {
        if (line.len == 0 or max_width == 0) return 0;
        var segment_start: usize = 0;
        while (true) {
            const segment = wrappedSegmentAt(line, max_width, segment_start);
            if (segment.is_last) return segment_start;
            segment_start = segment.end;
        }
    }

    fn wrappedSegmentAt(line: []const u8, max_width: usize, start: usize) WrappedSegment {
        if (line.len == 0 or max_width == 0 or start >= line.len) {
            return .{
                .start = @min(start, line.len),
                .end = @min(start, line.len),
                .is_last = true,
            };
        }

        var i = start;
        var segment_width: usize = 0;

        while (i < line.len) {
            const byte_len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
            if (i + byte_len > line.len) break;

            const cp = decodeSlice(line[i..][0..byte_len]) catch {
                if (segment_width > 0 and segment_width + 1 > max_width) break;
                segment_width += 1;
                i += 1;
                continue;
            };

            const char_width = wrapDisplayWidth(unicode.charWidth(cp), max_width);
            if (segment_width > 0 and segment_width + char_width > max_width) break;

            segment_width += char_width;
            i += byte_len;
        }

        return .{
            .start = start,
            .end = i,
            .is_last = i >= line.len,
        };
    }

    fn displayWidthInRange(line: []const u8, start: usize, end: usize, max_width: usize) usize {
        if (max_width == 0) return 0;
        const clamped_end = clampToUtf8Boundary(line, @min(end, line.len));
        var width: usize = 0;
        var i = @min(start, clamped_end);
        while (i < clamped_end) {
            const byte_len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
            if (i + byte_len > line.len) break;
            const cp = decodeSlice(line[i..][0..byte_len]) catch {
                width += 1;
                i += 1;
                continue;
            };
            width += wrapDisplayWidth(unicode.charWidth(cp), max_width);
            i += byte_len;
        }
        return width;
    }

    /// Decode a 1-4 byte UTF-8 slice, per Zig 0.16's fixed-array utf8Decode2/3/4
    /// API (utf8Decode is deprecated).
    fn decodeSlice(bytes: []const u8) !u21 {
        return switch (bytes.len) {
            1 => bytes[0],
            2 => std.unicode.utf8Decode2(bytes[0..2].*),
            3 => std.unicode.utf8Decode3(bytes[0..3].*),
            4 => std.unicode.utf8Decode4(bytes[0..4].*),
            else => error.InvalidUtf8,
        };
    }

    fn byteOffsetForDisplayCol(line: []const u8, start: usize, end: usize, target_col: usize, max_width: usize) usize {
        if (max_width == 0) return @min(start, line.len);

        const clamped_start = clampToUtf8Boundary(line, @min(start, line.len));
        const clamped_end = clampToUtf8Boundary(line, @min(end, line.len));
        var col: usize = 0;
        var i = clamped_start;
        while (i < clamped_end) {
            if (col >= target_col) return i;

            const byte_len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
            if (i + byte_len > line.len) break;
            const cp = decodeSlice(line[i..][0..byte_len]) catch {
                if (col + 1 > target_col) return i;
                col += 1;
                i += 1;
                continue;
            };

            const char_width = wrapDisplayWidth(unicode.charWidth(cp), max_width);
            if (col + char_width > target_col) return i;

            col += char_width;
            i += byte_len;
        }
        return clamped_end;
    }

    fn wrapDisplayWidth(char_width: usize, max_width: usize) usize {
        if (max_width == 0) return 0;
        if (char_width == 0) return 0;
        return @min(char_width, max_width);
    }

    fn clampCursorToLineBoundary(self: *CodeArea) void {
        const line = self.currentLine();
        self.cursor_col = clampToUtf8Boundary(line.items, self.cursor_col);
    }

    fn clampToUtf8Boundary(line: []const u8, pos: usize) usize {
        var clamped = @min(pos, line.len);
        while (clamped > 0 and clamped < line.len and (line[clamped] & 0xC0) == 0x80) {
            clamped -= 1;
        }
        return clamped;
    }
};
