//! Text: a styled, width-aware single- or multi-line text component
//! (baseui-contract.md §4.2). Truncates at grapheme boundaries with an
//! optional ellipsis marker, wraps to a column budget drawing one row
//! per line, and aligns left/center/right within the available width
//! (single-line mode). `draw` never allocates beyond the caller-owned
//! `scratch` list (the contract §3 borrow model): the caller passes the
//! allocator that owns (or will own) the scratch's memory.

const std = @import("std");
const Buffer = @import("../buffer.zig").Buffer;
const Style = @import("../style.zig").Style;
const Width = @import("../width.zig");
const Clock = @import("component.zig").Clock;

/// Shared zero-config scratch. It is only written when a default-
/// configured Text truncates or wraps (single-threaded UI; callers that
/// care pass their own scratch and allocator).
var default_scratch: std.ArrayList(u8) = .empty;

pub const Text = struct {
    text: []const u8 = "",
    style: Style = .{},
    /// Truncation marker appended when the text didn't fit; null = no
    /// marker.
    ellipsis: ?[]const u8 = "…",
    /// True: wrap to `wrap_width` (0 => available width), drawing one
    /// row per line. False: single line, truncated.
    wrap: bool = false,
    wrap_width: u16 = 0, // 0 => avail (buf.width - x)
    /// Horizontal alignment within the available width (single-line
    /// mode only; wrap mode ignores it). `@"align"` — `align` is a Zig
    /// keyword, so the contract's field name is escaped (baseui-
    /// improvements.md §2.3).
    @"align": enum { left, center, right } = .left,
    /// Caller-owned scratch for wrap/truncate output (the borrow model).
    scratch: *std.ArrayList(u8) = &default_scratch,

    /// Text never animates; `advance` is always false.
    pub fn advance(self: *Text, now: Clock) bool {
        _ = self;
        _ = now;
        return false;
    }

    /// Draw `text` at (x, y). `alloc` backs `scratch` — pass the
    /// allocator that owns (or will own) the scratch's memory, and keep
    /// it the same on every call. Returns the columns consumed (widest
    /// row when wrapping); never errors for width.
    pub fn draw(self: *Text, alloc: std.mem.Allocator, buf: *Buffer, x: u16, y: u16, now: Clock) !u16 {
        _ = now; // static component; nothing to advance
        const avail: usize = buf.width -| x;
        if (self.text.len == 0 or avail == 0 or y >= buf.height) return 0;

        if (!self.wrap) {
            const s = try self.fit(alloc, avail);
            if (self.@"align" == .left) return buf.draw(self.style, s, x, y);
            // Align within the available width; `w <= avail` by
            // construction (fit already truncated), so no underflow.
            // The consumed columns stay `w` either way.
            const w = Width.strWidth(s);
            const x0: u16 = @intCast(x + switch (self.@"align") {
                .left => 0,
                .center => (avail - w) / 2,
                .right => avail - w,
            });
            return buf.draw(self.style, s, x0, y);
        }

        const ww: usize = if (self.wrap_width == 0) avail else self.wrap_width;
        const wrapped = try Width.wrap(alloc, self.text, ww, 1);
        defer alloc.free(wrapped);

        // Cells borrow their graphemes, so the wrapped lines must live
        // past this call: copy them into the caller-owned scratch (the
        // borrow model, baseui-contract.md §3), then swap an over-wide
        // last line for its ellipsized form — all before drawing.
        self.scratch.clearRetainingCapacity();
        try self.scratch.appendSlice(alloc, wrapped);

        var last_start: usize = 0;
        {
            var find = std.mem.splitScalar(u8, self.scratch.items, '\n');
            while (find.next()) |line| last_start = self.scratch.items.len - line.len;
        }
        const last = self.scratch.items[last_start..];
        if (Width.strWidth(last) > avail) {
            self.scratch.items.len = last_start; // drop the old last line
            _ = try self.appendFit(alloc, last, avail);
        }

        var widest: u16 = 0;
        var row: u16 = 0;
        var lines = std.mem.splitScalar(u8, self.scratch.items, '\n');
        while (lines.next()) |line| {
            if (y + row >= buf.height) break;
            widest = @max(widest, try buf.draw(self.style, line, x, y + row));
            row += 1;
        }
        return widest;
    }

    /// Resolve the display string for `self.text` in `avail` columns:
    /// borrowed as-is when it fits, else truncated (with the ellipsis
    /// marker) into `scratch`.
    fn fit(self: *Text, alloc: std.mem.Allocator, avail: usize) ![]const u8 {
        return self.fitSlice(alloc, self.text, avail);
    }

    /// Same as `fit` for an arbitrary string (used for wrapped lines).
    fn fitSlice(self: *Text, alloc: std.mem.Allocator, s: []const u8, avail: usize) ![]const u8 {
        if (Width.strWidth(s) <= avail) return s;
        self.scratch.clearRetainingCapacity();
        return self.appendFit(alloc, s, avail);
    }

    /// Append the truncation of `s` (with the ellipsis marker) to the
    /// end of `scratch`, returning the appended slice. The caller keeps
    /// any earlier scratch content (wrap mode) or clears first (truncate
    /// mode).
    fn appendFit(self: *Text, alloc: std.mem.Allocator, s: []const u8, avail: usize) ![]const u8 {
        const e = self.ellipsis orelse "";
        const budget = avail -| Width.strWidth(e);
        const t = try Width.truncate(alloc, s, budget);
        defer alloc.free(t);
        const start = self.scratch.items.len;
        try self.scratch.appendSlice(alloc, t);
        try self.scratch.appendSlice(alloc, e);
        return self.scratch.items[start..];
    }
};

test {
    std.testing.refAllDecls(@This());
}

/// Fixed-buffer writer for golden tests (same pattern as src/buffer.zig).
const TestWriter = struct {
    buf: [1024]u8 = undefined,
    w: std.Io.Writer = undefined,

    fn init(self: *TestWriter) void {
        self.w = .fixed(&self.buf);
    }
};

const test_alloc = std.testing.allocator;

/// Concatenate one row's graphemes into `out` for test assertions
/// (wide continuations emit nothing, matching the renderer).
fn rowStr(buf: *const Buffer, y: usize, out: []u8) []const u8 {
    var n: usize = 0;
    var x: usize = 0;
    while (x < buf.width) : (x += 1) {
        const cell = buf.get(@intCast(x), @intCast(y));
        if (cell.wide or cell.grapheme.len == 0) continue;
        @memcpy(out[n..][0..cell.grapheme.len], cell.grapheme);
        n += cell.grapheme.len;
    }
    return out[0..n];
}

test "text: fitting text is borrowed, scratch untouched" {
    var scratch: std.ArrayList(u8) = .empty;
    var t: Text = .{ .text = "Hello", .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 10, 1);
    defer buf.deinit();

    const consumed = try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 5), consumed);
    try std.testing.expectEqual(@as(usize, 0), scratch.items.len); // no allocation
    try std.testing.expectEqualStrings("H", buf.get(0, 0).grapheme);
    try std.testing.expectEqualStrings("o", buf.get(4, 0).grapheme);
}

test "text: truncates at a grapheme boundary with ellipsis" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var t: Text = .{ .text = "Hello 😊", .scratch = &scratch }; // width 8
    var buf = try Buffer.init(test_alloc, 5, 1);
    defer buf.deinit();

    const consumed = try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 5), consumed);
    // budget = 5 - 1 (ellipsis) = 4 -> "Hell" + "…"
    var rowbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Hell…", rowStr(&buf, 0, &rowbuf));
    try std.testing.expectEqualStrings("Hell…", scratch.items);
}

test "text: wide grapheme is never split mid-bytes" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var t: Text = .{ .text = "👨‍🌾xx", .scratch = &scratch }; // width 4
    var buf = try Buffer.init(test_alloc, 3, 1);
    defer buf.deinit();

    const consumed = try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 3), consumed);
    // budget = 3 - 1 = 2 -> the full family, never half its bytes.
    var rowbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("👨‍🌾…", rowStr(&buf, 0, &rowbuf));
}

test "text: ellipsis null appends no marker" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var t: Text = .{ .text = "abcdef", .ellipsis = null, .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 4, 1);
    defer buf.deinit();

    const consumed = try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 4), consumed);
    var rowbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("abcd", rowStr(&buf, 0, &rowbuf));
}

test "text: wrap draws each line at an increasing row" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var t: Text = .{ .text = "The quick brown fox", .wrap = true, .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 10, 3);
    defer buf.deinit();

    const consumed = try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 10), consumed); // widest row
    var rowbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("The quick ", rowStr(&buf, 0, &rowbuf));
    try std.testing.expectEqualStrings("brown fox ", rowStr(&buf, 1, &rowbuf));
    try std.testing.expect(buf.get(0, 2).eql(.{})); // nothing on row 2
}

test "text: last wrapped line gets the ellipsis when over-wide" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var t: Text = .{ .text = "abc supercalifragilistic", .wrap = true, .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 10, 3);
    defer buf.deinit();

    const consumed = try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 10), consumed);
    var rowbuf: [64]u8 = undefined;
    // The 24-wide unbreakable word stays whole on one line; it overflows
    // `avail`, so the single wrapped line gets the ellipsis treatment.
    try std.testing.expectEqualStrings("abc super…", rowStr(&buf, 0, &rowbuf));
    try std.testing.expect(buf.get(0, 1).eql(.{})); // only one row drawn
}

test "text: styled cells carry the component style" {
    var t: Text = .{ .text = "Hi", .style = .{ .fg = .{ .ansi = .red } } };
    var buf = try Buffer.init(test_alloc, 4, 1);
    defer buf.deinit();
    _ = try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expect(buf.get(0, 0).style.fg.?.eql(.{ .ansi = .red }));

    var tw: TestWriter = .{};
    tw.init();
    try buf.renderAll(&tw.w);
    try std.testing.expectEqualStrings("\r\x1b[K\x1b[31mHi\x1b[0m", tw.w.buffered());
}

test "text: no allocation when the text fits" {
    var failing = std.testing.FailingAllocator.init(test_alloc, .{ .fail_index = 0 });
    const alloc = failing.allocator();
    var scratch: std.ArrayList(u8) = .empty;
    var t: Text = .{ .text = "short", .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 10, 1);
    defer buf.deinit();

    _ = try t.draw(alloc, &buf, 0, 0, .fromNanoseconds(0)); // must not fail
    try std.testing.expectEqual(@as(usize, 0), scratch.items.len);
}

test "text: truncation allocates through the caller allocator" {
    var failing = std.testing.FailingAllocator.init(test_alloc, .{ .fail_index = 0 });
    const alloc = failing.allocator();
    var scratch: std.ArrayList(u8) = .empty;
    var t: Text = .{ .text = "a much longer string", .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 5, 1);
    defer buf.deinit();

    try std.testing.expectError(error.OutOfMemory, t.draw(alloc, &buf, 0, 0, .fromNanoseconds(0)));
}

test "text: empty text draws nothing" {
    var t: Text = .{};
    var buf = try Buffer.init(test_alloc, 6, 1);
    defer buf.deinit();
    try std.testing.expectEqual(@as(u16, 0), try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0)));
    try std.testing.expect(buf.get(0, 0).eql(.{}));
}

test "text: right alignment places the last glyph at x + avail - 1" {
    var t: Text = .{ .text = "Hi", .@"align" = .right };
    var buf = try Buffer.init(test_alloc, 10, 1);
    defer buf.deinit();
    const consumed = try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqual(@as(u16, 2), consumed);
    try std.testing.expectEqualStrings("H", buf.get(8, 0).grapheme);
    try std.testing.expectEqualStrings("i", buf.get(9, 0).grapheme);
    try std.testing.expect(buf.get(0, 0).eql(.{})); // leading gap empty
}

test "text: center alignment centers within the available width" {
    var t: Text = .{ .text = "Hi", .@"align" = .center };
    var buf = try Buffer.init(test_alloc, 10, 1);
    defer buf.deinit();
    _ = try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqualStrings("H", buf.get(4, 0).grapheme); // (10-2)/2
    try std.testing.expectEqualStrings("i", buf.get(5, 0).grapheme);
}

test "text: left alignment is unchanged" {
    var t: Text = .{ .text = "Hi" };
    var buf = try Buffer.init(test_alloc, 10, 1);
    defer buf.deinit();
    _ = try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqualStrings("H", buf.get(0, 0).grapheme);
}

test "text: truncated text aligns at x" {
    // The fitted string fills `avail`, so every alignment computes
    // x0 = x (no room to shift into).
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var t: Text = .{ .text = "a very long line", .@"align" = .right, .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 8, 1);
    defer buf.deinit();
    _ = try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqualStrings("a", buf.get(0, 0).grapheme);

    var t2: Text = .{ .text = "a very long line", .@"align" = .center, .scratch = &scratch };
    var buf2 = try Buffer.init(test_alloc, 8, 1);
    defer buf2.deinit();
    _ = try t2.draw(test_alloc, &buf2, 0, 0, .fromNanoseconds(0));
    try std.testing.expectEqualStrings("a", buf2.get(0, 0).grapheme);
}

test "text: wrap mode ignores alignment" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(test_alloc);
    var t: Text = .{ .text = "The quick brown fox", .wrap = true, .@"align" = .right, .scratch = &scratch };
    var buf = try Buffer.init(test_alloc, 10, 3);
    defer buf.deinit();
    _ = try t.draw(test_alloc, &buf, 0, 0, .fromNanoseconds(0));
    var rowbuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("The quick ", rowStr(&buf, 0, &rowbuf)); // starts at x
}
