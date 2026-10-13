//! Live terminal capability detection: sequential queries whose replies are
//! decoded through the parser, plus small DECRPM and DA1 splitters. No
//! terminfo database, and nothing cached between sessions.
//!
//! Detection is best-effort by design. A query that times out or is never
//! answered leaves its feature off and is not an error, because a terminal
//! that answers nothing is a terminal an app must still run on. The one thing
//! that is unconditional is the cleanup: `Capabilities.restore` disables every
//! mode a session may have enabled, including the kitty keyboard push that
//! detection always sends.
//!
//! `detect` takes the terminal as `anytype` so a scripted fake can drive it in
//! tests; it needs `io`, `fd`, `read` and `writer`, which `Tty` provides. The
//! queries go out through the writer, the replies are polled with
//! `posix.poll` on the descriptor and read from it, and the deadline is
//! measured on `io` — so the implementation behind `io` must own a real
//! descriptor, and cancelling the surrounding `Io` does not interrupt the
//! polls.
//!
//! The allocator passed to `detect` owns every clipboard payload a reply may
//! decode. Payloads no query asked for are released before the call returns.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Event = @import("event.zig").Event;
const Capability = @import("event.zig").Capability;
const ColorProfile = @import("color.zig").ColorProfile;

/// Parser is declared privately in parser.zig (`const Parser = @This()`);
/// the file type is reached by using the import in a type position.
const Parser = @import("Parser.zig");

/// Per-query deadline in milliseconds.
const query_timeout_ms: u64 = 250;

/// What the terminal answered when it was asked. Every field defaults to
/// false, and a query that times out or fails leaves its feature off: a
/// capability is claimed only on a reply that actually arrived.
///
/// `color` is the exception to the "off means false" reading: it names a
/// profile, and the default is the one every terminal can render.
pub const Capabilities = struct {
    /// The color profile to render with. `.truecolor` only when a DA1 or
    /// OSC 11 reply reported truecolor support; `.ansi256` otherwise.
    color: ColorProfile = .ansi256,
    /// Whether the terminal answered the kitty keyboard push (`CSI > 1 u`).
    kitty_keyboard: bool = false,
    /// Whether the terminal answered the kitty graphics probe with an
    /// accepted response; an error response leaves it off.
    kitty_graphics: bool = false,
    /// Truecolor by cell size (sixel pixels). Never queried yet, so it stays
    /// false until a probe is added.
    sgr_pixels: bool = false,
    /// Whether bracketed paste is enabled. Never queried yet: bracketed-paste
    /// tags are consumed and their bytes arrive as ordinary keys.
    bracketed_paste: bool = false,
    /// Whether synchronized output (DEC 2026) is supported. Decides whether an
    /// interactive session wraps each frame in the envelope.
    sync_output: bool = false,
    /// Whether the terminal reported the unicode-core mode (DEC 2027) as
    /// supported. Recorded, never consulted: every toolkit width measurement
    /// goes through zg's Unicode 16 tables (`src/width.zig`), so this reports
    /// the mode and never selects a legacy-width renderer.
    unicode_core: bool = false,
    /// Whether 24-bit color was reported, by DA1 param 24 or by an OSC 11
    /// background reply.
    rgb: bool = false,
    /// Whether focus reporting is enabled. Never queried yet.
    focus_events: bool = false,

    /// Write the disable sequence for every terminal mode a session may have
    /// turned on, returning the terminal to its pre-session state.
    ///
    /// Unconditional: each sequence is a no-op where the mode was never on,
    /// and the kitty keyboard push `detect` always sends must always be
    /// popped — a missed reply would otherwise leave that mode enabled. Call
    /// it after `Region.exit` and before `Tty.restore`.
    ///
    /// `w` stays the caller's; the writes stop at the first failure with
    /// whatever the writer reports, leaving the rest of the cleanup unwritten.
    pub fn restore(self: *const Capabilities, w: anytype) !void {
        _ = self;
        try w.writeAll("\x1b[<u"); // kitty keyboard: pop
        try w.writeAll("\x1b[?2004l"); // bracketed paste: off
        try w.writeAll("\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l"); // mouse: off
        try w.writeAll("\x1b[?1004l"); // focus events: off
        try w.writeAll("\x1b[?2026l"); // synchronized output: off
        try w.writeAll("\x1b[?2027l"); // unicode core: off
        try w.writeAll("\x1b[?25h"); // cursor: show (idempotent with Region.exit)
    }

    /// Ask the terminal what it supports and return what it answered: the
    /// primary device attributes, synchronized output, unicode core, the
    /// kitty keyboard, kitty graphics and the OSC 11 background, in that order,
    /// each with its own deadline (`query_timeout_ms`, 250 ms).
    ///
    /// `tty` is duck-typed and must provide `io`, `fd`, `reader`-free `read`
    /// and `writer`; `Tty` satisfies it. Queries are written through `tty`'s
    /// writer, replies are polled with `posix.poll` on `tty.fd.handle` and
    /// read with `tty.read`, and the deadline is measured on `tty.io`. An
    /// implementation whose `io` owns no real descriptor cannot drive
    /// detection, and a cancelation request does not interrupt the polls: the
    /// call ends on its own deadlines, at most six of them.
    ///
    /// `alloc` owns every clipboard payload the replies may decode; the ones
    /// no query asked for are released before the call returns. `parser`
    /// keeps its decode scratch for the whole call, so it must live as long.
    ///
    /// A query that times out or gets no reply leaves its feature off and is
    /// not an error. Only a failed query write propagates. The kitty keyboard
    /// push is sent even when its reply is missed, which is why `restore` pops
    /// it unconditionally.
    pub fn detect(alloc: std.mem.Allocator, tty: anytype, parser: *Parser) !Capabilities {
        return detectWithTimeout(alloc, tty, parser, query_timeout_ms);
    }
};

/// What the current query window is waiting for.
const ScanKind = enum {
    /// Primary DA reply: CSI ? Pm c — params extracted by the splitter.
    da1,
    /// DECRPM reply: CSI ? {mode} ; {pm} $ y — splitter extracts pm.
    decrpm,
    /// Kitty keyboard reply: CSI > flags ; … u — decoded via parser.parse.
    kitty,
    /// Kitty graphics probe reply: APC G i=9931 ; OK ST — decoded via parser.parse.
    kitty_graphics,
    /// OSC 11 reply: OSC 11 ; spec ST — decoded via parser.parse.
    osc11,
};

/// The outcome of one query window.
const ScanResult = union(enum) {
    /// DA1 reply params ("1;2;4;6;22;24"), null when no reply arrived.
    da1: ?[]const u8,
    /// DECRPM reply value (pm 1-3 ⇒ set), null when no reply arrived.
    decrpm: ?bool,
    /// Kitty keyboard cap reply seen.
    kitty: bool,
    /// Kitty graphics cap reply seen.
    kitty_graphics: bool,
    /// OSC 11 color report seen.
    osc11: bool,
};

fn detectWithTimeout(alloc: std.mem.Allocator, tty: anytype, parser: *Parser, timeout_ms: u64) !Capabilities {
    var caps: Capabilities = .{};

    // 1. Primary DA: truecolor (param 24) sets `rgb`. The sixel param (4) is
    //    left unmatched, because no capability here claims sixel.
    ttyDrainInput(tty);
    {
        const r = try queryScan(.da1, 0, alloc, tty, parser, "\x1b[c", timeout_ms);
        switch (r) {
            .da1 => |params| {
                if (params) |p| {
                    if (primaryDeviceAttributesHasParam(p, 24)) caps.rgb = true;
                }
            },
            else => {},
        }
    }

    // 2. Synchronized output (?2026).
    ttyDrainInput(tty);
    {
        const r = try queryScan(.decrpm, 2026, alloc, tty, parser, "\x1b[?2026$p", timeout_ms);
        switch (r) {
            .decrpm => |supported| caps.sync_output = supported orelse false,
            else => {},
        }
    }

    // 3. Unicode core (?2027) — recorded; no toolkit width depends on it.
    ttyDrainInput(tty);
    {
        const r = try queryScan(.decrpm, 2027, alloc, tty, parser, "\x1b[?2027$p", timeout_ms);
        switch (r) {
            .decrpm => |supported| caps.unicode_core = supported orelse false,
            else => {},
        }
    }

    // 4. Kitty keyboard — push form CSI > 1 u (the mode stays enabled).
    //    The reply CSI > flags ; event_flags ; mods u decodes through the
    //    parser as Event.cap.
    ttyDrainInput(tty);
    {
        const r = try queryScan(.kitty, 0, alloc, tty, parser, "\x1b[>1u", timeout_ms);
        switch (r) {
            .kitty => |found| caps.kitty_keyboard = found,
            else => {},
        }
    }

    // 5. Kitty graphics — APC-G probe (zigzag queryKittyGraphicsSupport).
    //    The reply ESC _ G i=9931 ; OK ST decodes through the parser as
    //    Event.cap.
    ttyDrainInput(tty);
    {
        const r = try queryScan(
            .kitty_graphics,
            0,
            alloc,
            tty,
            parser,
            "\x1b_Ga=q,i=9931,s=1,v=1,t=d,f=24;AAAA\x1b\\",
            timeout_ms,
        );
        switch (r) {
            .kitty_graphics => |found| caps.kitty_graphics = found,
            else => {},
        }
    }

    // 6. RGB via the OSC 11 background query; the color_report reply is
    //    decoded through the parser.
    ttyDrainInput(tty);
    {
        const r = try queryScan(.osc11, 0, alloc, tty, parser, "\x1b]11;?\x1b\\", timeout_ms);
        switch (r) {
            .osc11 => |found| {
                if (found) caps.rgb = true;
            },
            else => {},
        }
    }

    if (caps.rgb) caps.color = .truecolor;
    return caps;
}

/// Write `query`, then poll/read with a per-query deadline until the
/// expected reply decodes or the deadline elapses. Never errors for a
/// failed or timed-out query — the caller sees the feature off.
fn queryScan(
    comptime kind: ScanKind,
    comptime mode: u16,
    alloc: std.mem.Allocator,
    tty: anytype,
    parser: *Parser,
    query: []const u8,
    timeout_ms: u64,
) !ScanResult {
    const w = tty.writer();
    try w.writeAll(query);
    try w.flush();

    var collected: [1024]u8 = undefined;
    var collected_len: usize = 0;
    const start = std.Io.Clock.Timestamp.now(tty.io, .boot);
    // The first poll runs whatever the clock says: a reply already waiting
    // when the window opens belongs to this query, even when the process was
    // descheduled past the deadline between the write and the first read.
    var first = true;
    while (first or withinDeadline(tty.io, start, timeout_ms)) : (first = false) {
        var pollfds = [_]posix.pollfd{
            .{ .fd = tty.fd.handle, .events = posix.POLL.IN, .revents = 0 },
        };
        const pr = posix.poll(&pollfds, 30) catch 0;
        if (pr == 0 or (pollfds[0].revents & posix.POLL.IN) == 0) continue;

        var chunk: [128]u8 = undefined;
        const n = tty.read(&chunk) catch 0;
        if (n == 0) continue;
        const copy_len = @min(n, collected.len - collected_len);
        if (copy_len > 0) {
            @memcpy(collected[collected_len .. collected_len + copy_len], chunk[0..copy_len]);
            collected_len += copy_len;
        }
        const bytes = collected[0..collected_len];

        switch (kind) {
            .da1 => {
                if (parsePrimaryDeviceAttributes(bytes)) |params| return .{ .da1 = params };
            },
            .decrpm => {
                if (parseDecrpmReply(bytes, mode)) |supported| return .{ .decrpm = supported };
            },
            .kitty => {
                if (scanCapEvent(alloc, bytes, parser, .kitty_keyboard)) return .{ .kitty = true };
            },
            .kitty_graphics => {
                if (scanCapEvent(alloc, bytes, parser, .kitty_graphics)) return .{ .kitty_graphics = true };
            },
            .osc11 => {
                if (scanOsc11Report(alloc, bytes, parser)) return .{ .osc11 = true };
            },
        }
    }
    return switch (kind) {
        .da1 => .{ .da1 = null },
        .decrpm => .{ .decrpm = null },
        .kitty => .{ .kitty = false },
        .kitty_graphics => .{ .kitty_graphics = false },
        .osc11 => .{ .osc11 = false },
    };
}

/// Decode a capability reply through the parser: the kitty keyboard reply
/// (`CSI > flags ; … u`) and the kitty graphics reply both parse as
/// `Event.cap`.
///
/// A terminal may answer a capability query with anything at all, including
/// a clipboard payload. The parser allocated that payload from `alloc`, and
/// this scanner does not hand it to anyone, so it releases it here rather
/// than letting the session leak it.
fn scanCapEvent(alloc: std.mem.Allocator, bytes: []const u8, parser: *Parser, want: Capability) bool {
    if (bytes.len == 0) return false;
    const result = parser.parse(bytes, alloc) catch return false;
    const ev = result.event orelse return false;
    if (ev == .cap and ev.cap == want) return true;
    releaseIgnoredPayload(alloc, ev);
    return false;
}

/// Decode an OSC 11 background-color reply through the parser: it parses as
/// `Event.color_report` with kind `osc11`. An unexpected event is released
/// exactly as in `scanCapEvent`.
fn scanOsc11Report(alloc: std.mem.Allocator, bytes: []const u8, parser: *Parser) bool {
    if (bytes.len == 0) return false;
    const result = parser.parse(bytes, alloc) catch return false;
    const ev = result.event orelse return false;
    if (ev == .color_report and ev.color_report.kind == .osc11) return true;
    releaseIgnoredPayload(alloc, ev);
    return false;
}

/// Give back the memory of an event a query did not ask for. Only a clipboard
/// payload owns anything, and the parser allocated it from `alloc` — the same
/// allocator the caller handed to `detect`.
fn releaseIgnoredPayload(alloc: std.mem.Allocator, ev: Event) void {
    switch (ev) {
        .paste => |text| alloc.free(text),
        else => {},
    }
}

/// True while `timeout_ms` has not elapsed since `start` (zigzag
/// withinDeadline pattern).
fn withinDeadline(io: std.Io, start: std.Io.Clock.Timestamp, timeout_ms: u64) bool {
    const elapsed_ns = start.untilNow(io).raw.nanoseconds;
    const deadline_ns: i96 = @as(i96, @intCast(timeout_ms)) * std.time.ns_per_ms;
    return elapsed_ns < deadline_ns;
}

/// Discard any pending input so stale replies do not alias into the next
/// query window (zigzag drainInput pattern).
fn ttyDrainInput(tty: anytype) void {
    var buf: [128]u8 = undefined;
    while (true) {
        var pollfds = [_]posix.pollfd{
            .{ .fd = tty.fd.handle, .events = posix.POLL.IN, .revents = 0 },
        };
        const pr = posix.poll(&pollfds, 0) catch return;
        if (pr == 0 or (pollfds[0].revents & posix.POLL.IN) == 0) return;
        const n = tty.read(&buf) catch return;
        if (n == 0) return;
    }
}

/// Split the first Primary DA (DA1) reply params from `bytes`. Reply form:
/// CSI ? Pm c (the '?' is optional). Returns the param list, e.g.
/// "1;2;4;6;22;24", or null when no complete DA1 reply is present.
fn parsePrimaryDeviceAttributes(bytes: []const u8) ?[]const u8 {
    const prefix = "\x1b[";
    var search_from: usize = 0;
    while (search_from < bytes.len) {
        const start = std.mem.indexOfPos(u8, bytes, search_from, prefix) orelse return null;
        var i = start + prefix.len;
        if (i < bytes.len and bytes[i] == '?') i += 1;
        const params_start = i;
        while (i < bytes.len and ((bytes[i] >= '0' and bytes[i] <= '9') or bytes[i] == ';')) : (i += 1) {}
        if (i >= bytes.len) return null;
        if (bytes[i] == 'c' and i > params_start) {
            return bytes[params_start..i];
        }
        search_from = start + 1;
    }
    return null;
}

/// True when the DA1 param list contains `needle`.
fn primaryDeviceAttributesHasParam(params: []const u8, needle: u16) bool {
    var it = std.mem.splitScalar(u8, params, ';');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const value = std.fmt.parseInt(u16, part, 10) catch continue;
        if (value == needle) return true;
    }
    return false;
}

/// Parse a DECRPM reply for `mode` (CSI ? {mode} ; {pm} $ y). Returns
/// whether the mode is set (pm != 0), or null when no complete reply is
/// present (generalized zigzag parseMode2027Response).
fn parseDecrpmReply(bytes: []const u8, mode: u16) ?bool {
    var prefix_buf: [16]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "\x1b[?{d};", .{mode}) catch return null;
    var search_from: usize = 0;
    while (search_from < bytes.len) {
        const start = std.mem.indexOfPos(u8, bytes, search_from, prefix) orelse return null;
        var i = start + prefix.len;
        var param: usize = 0;
        var saw_digit = false;
        while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') : (i += 1) {
            saw_digit = true;
            param = param * 10 + (bytes[i] - '0');
        }
        if (!saw_digit) {
            search_from = start + 1;
            continue;
        }
        if (i + 1 < bytes.len and bytes[i] == '$' and bytes[i + 1] == 'y') {
            // DECRPM values: 0 not recognized, 1 set, 2 reset, 3 set
            // permanently, 4 reset permanently. Only 1 and 3 are "on".
            return param == 1 or param == 3;
        }
        search_from = start + 1;
    }
    return null;
}

test {
    std.testing.refAllDecls(@This());
}

test "caps: parseDecrpmReply vectors" {
    try std.testing.expectEqual(@as(?bool, true), parseDecrpmReply("\x1b[?2026;1$y", 2026));
    try std.testing.expectEqual(@as(?bool, false), parseDecrpmReply("\x1b[?2026;0$y", 2026));
    try std.testing.expectEqual(@as(?bool, false), parseDecrpmReply("\x1b[?2026;2$y", 2026));
    try std.testing.expectEqual(@as(?bool, true), parseDecrpmReply("\x1b[?2026;3$y", 2026));
    try std.testing.expectEqual(@as(?bool, false), parseDecrpmReply("\x1b[?2026;4$y", 2026));
    try std.testing.expectEqual(@as(?bool, true), parseDecrpmReply("\x1b[?2027;1$y", 2027));
    // incomplete / absent replies
    try std.testing.expectEqual(@as(?bool, null), parseDecrpmReply("", 2026));
    try std.testing.expectEqual(@as(?bool, null), parseDecrpmReply("\x1b[?2026", 2026));
    try std.testing.expectEqual(@as(?bool, null), parseDecrpmReply("\x1b[?2026;1$", 2026));
    // wrong mode must not match
    try std.testing.expectEqual(@as(?bool, null), parseDecrpmReply("\x1b[?1004;1$y", 2026));
    // a later reply in the same byte stream still matches
    try std.testing.expectEqual(@as(?bool, true), parseDecrpmReply("\x1b[?2027;1$y\x1b[?2026;1$y", 2026));
}

test "caps: DA1 param extraction" {
    try std.testing.expectEqualStrings("1;2;4;6;22;24", parsePrimaryDeviceAttributes("\x1b[?1;2;4;6;22;24c").?);
    try std.testing.expectEqualStrings("62;4;22;24", parsePrimaryDeviceAttributes("\x1b[?62;4;22;24c").?);
    try std.testing.expectEqualStrings("1;2", parsePrimaryDeviceAttributes("\x1b[1;2c").?);

    try std.testing.expect(parsePrimaryDeviceAttributes("hello") == null);
    try std.testing.expect(parsePrimaryDeviceAttributes("\x1b[") == null);
    try std.testing.expect(parsePrimaryDeviceAttributes("\x1b[1;2") == null); // no final c

    try std.testing.expect(primaryDeviceAttributesHasParam("1;2;4;6;22;24", 24));
    try std.testing.expect(primaryDeviceAttributesHasParam("1;2;4;6;22;24", 4));
    try std.testing.expect(!primaryDeviceAttributesHasParam("1;2;6", 24));
    try std.testing.expect(!primaryDeviceAttributesHasParam("", 24));
}

test "caps: parser decodes OSC 11 reply as color_report (rgbFromSpec integration)" {
    var parser: Parser = .{};
    const input = "\x1b]11;rgb:aaaa/bbbb/cccc\x1b\\";
    const result = try parser.parse(input, std.testing.allocator);
    try std.testing.expect(result.event != null);
    if (result.event) |e| {
        try std.testing.expect(e == .color_report);
        try std.testing.expect(e.color_report.kind == .osc11);
        try std.testing.expectEqual(@as(u8, 0xaa), e.color_report.value[0]);
        try std.testing.expectEqual(@as(u8, 0xbb), e.color_report.value[1]);
        try std.testing.expectEqual(@as(u8, 0xcc), e.color_report.value[2]);
    }
}

test "caps: restore emits the full unconditional cleanup" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const w = &out.writer;

    // Nothing detected → still the full set (kitty pop is unconditional:
    // the push always went out, so the pop always must).
    var c: Capabilities = .{};
    try c.restore(w);
    try std.testing.expectEqualStrings(
        "\x1b[<u" ++
            "\x1b[?2004l" ++
            "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l" ++
            "\x1b[?1004l" ++
            "\x1b[?2026l" ++
            "\x1b[?2027l" ++
            "\x1b[?25h",
        out.written(),
    );
}

test "caps: detect assembles capabilities from scripted replies" {
    const io = std.testing.io;
    var parser: Parser = .{};
    const script = [_][]const u8{
        "\x1b[?1;2;4;6;22;24c", // DA1 — truecolor param 24
        "\x1b[?2026;1$y", // sync supported
        "\x1b[?2027;0$y", // unicode core NOT supported
        "\x1b[>1;1;0u", // kitty keyboard reply
        "\x1b_Gi=9931;OK\x1b\\", // kitty graphics reply
        "\x1b]11;rgb:aaaa/bbbb/cccc\x1b\\", // OSC 11 background
    };
    var fake: FakeTty = undefined;
    try fake.init(io, &script);
    defer fake.deinit();

    const caps = try Capabilities.detect(std.testing.allocator, &fake, &parser);
    try std.testing.expect(caps.rgb);
    try std.testing.expectEqual(ColorProfile.truecolor, caps.color);
    try std.testing.expect(caps.sync_output);
    try std.testing.expect(!caps.unicode_core);
    try std.testing.expect(caps.kitty_keyboard);
    try std.testing.expect(caps.kitty_graphics);
    // not queried in v0 — stay off
    try std.testing.expect(!caps.sgr_pixels);
    try std.testing.expect(!caps.bracketed_paste);
    try std.testing.expect(!caps.focus_events);

    // queries were written in order, one per reply
    try std.testing.expectEqualStrings(
        "\x1b[c\x1b[?2026$p\x1b[?2027$p\x1b[>1u\x1b_Ga=q,i=9931,s=1,v=1,t=d,f=24;AAAA\x1b\\\x1b]11;?\x1b\\",
        fake.queryLog(),
    );
}

test "caps: detect reads each DECRPM reply into its own capability" {
    const io = std.testing.io;
    var parser: Parser = .{};
    const script = [_][]const u8{
        "\x1b[?1;2;4;6;22;24c",
        "\x1b[?2026;0$y",
        "\x1b[?2027;1$y",
        "\x1b[>1;1;0u",
        "\x1b_Gi=9931;OK\x1b\\",
        "\x1b]11;rgb:aaaa/bbbb/cccc\x1b\\",
    };
    var fake: FakeTty = undefined;
    try fake.init(io, &script);
    defer fake.deinit();

    const caps = try Capabilities.detect(std.testing.allocator, &fake, &parser);
    try std.testing.expect(!caps.sync_output);
    try std.testing.expect(caps.unicode_core);
}

test "caps: kitty-graphics error reply leaves the cap off" {
    const io = std.testing.io;
    var parser: Parser = .{};
    const script = [_][]const u8{
        "\x1b[?1;2;4;6;22;24c",
        "\x1b[?2026;1$y",
        "\x1b[?2027;1$y",
        "\x1b[>1;1;0u",
        "\x1b_Gi=9931;ENOENT:bad\x1b\\", // probe error → not supported
        "\x1b]11;rgb:aaaa/bbbb/cccc\x1b\\",
    };
    var fake: FakeTty = undefined;
    try fake.init(io, &script);
    defer fake.deinit();

    const caps = try detectWithTimeout(std.testing.allocator, &fake, &parser, 20);
    try std.testing.expect(!caps.kitty_graphics);
    // the other replies still decode
    try std.testing.expect(caps.kitty_keyboard);
    try std.testing.expect(caps.rgb);
}

test "caps: a stray clipboard payload in a query window is released" {
    const io = std.testing.io;
    var parser: Parser = .{};
    // A terminal may answer a capability query with anything, including an
    // OSC 52 paste. The parser allocates the decoded payload from the
    // allocator `detect` was given, and no query asked for it, so it must be
    // released: `std.testing.allocator` reports the leak at the end of this
    // test if it is not.
    const script = [_][]const u8{
        "\x1b[?1;2;4;6;22;24c",
        "\x1b[?2026;1$y",
        "\x1b[?2027;1$y",
        "\x1b]52;c;b3NjNTIgcGFzdGU=\x1b\\", // stray payload, kitty-keyboard window
        "\x1b_Gi=9931;ENOENT:bad\x1b\\",
        "\x1b]52;c;b3NjNTIgcGFzdGU=\x1b\\", // stray payload, OSC 11 window
    };
    var fake: FakeTty = undefined;
    try fake.init(io, &script);
    defer fake.deinit();

    const caps = try detectWithTimeout(std.testing.allocator, &fake, &parser, 20);
    // Neither window read the payload as its own reply.
    try std.testing.expect(!caps.kitty_keyboard);
    try std.testing.expectEqual(ColorProfile.truecolor, caps.color);
}

test "caps: a reply waiting when the window opens is read past the deadline" {
    const io = std.testing.io;
    var parser: Parser = .{};
    // The fake writes each reply as its query goes out, so every reply is
    // already waiting. A zero deadline stands in for a process descheduled
    // between the write and the first poll (seen under qemu-user on a busy
    // host): the window must still read what is there.
    const script = [_][]const u8{
        "\x1b[?1;2;4;6;22;24c",
        "\x1b[?2026;1$y",
        "\x1b[?2027;1$y",
        "\x1b[>1;1;0u",
        "\x1b_Gi=9931;OK\x1b\\",
        "\x1b]11;rgb:aaaa/bbbb/cccc\x1b\\",
    };
    var fake: FakeTty = undefined;
    try fake.init(io, &script);
    defer fake.deinit();

    const caps = try detectWithTimeout(std.testing.allocator, &fake, &parser, 0);
    try std.testing.expectEqual(ColorProfile.truecolor, caps.color);
    try std.testing.expect(caps.sync_output);
    try std.testing.expect(caps.unicode_core);
    try std.testing.expect(caps.kitty_keyboard);
    try std.testing.expect(caps.kitty_graphics);
}

test "caps: timed-out queries leave defaults, no hang" {
    const io = std.testing.io;
    var parser: Parser = .{};
    const script: [0][]const u8 = .{}; // the terminal never replies
    var fake: FakeTty = undefined;
    try fake.init(io, &script);
    defer fake.deinit();

    const caps = try detectWithTimeout(std.testing.allocator, &fake, &parser, 20);
    try std.testing.expect(!caps.rgb);
    try std.testing.expectEqual(ColorProfile.ansi256, caps.color);
    try std.testing.expect(!caps.sync_output);
    try std.testing.expect(!caps.unicode_core);
    try std.testing.expect(!caps.kitty_keyboard);
    try std.testing.expect(!caps.kitty_graphics);
}

// ── scripted fake tty ────────────────────────────

/// A fake tty driven by a reply script: each query byte burst drained
/// through the writer triggers the next canned reply, written into a real
/// pipe so detect's poll/read path is exercised end to end. Headless-safe
/// (a pipe, not a terminal).
const FakeTty = struct {
    io: std.Io,
    fd: std.Io.File, // pipe read end — detect polls/reads this
    pipe_w: std.Io.File, // pipe write end — scripted replies land here
    replies: []const []const u8,
    reply_idx: usize = 0,
    fw: FakeWriter = undefined,
    query_log: [256]u8 = undefined,
    query_log_len: usize = 0,

    fn init(self: *FakeTty, io: std.Io, replies: []const []const u8) !void {
        if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
        var fds: [2]i32 = undefined;
        const rc = std.os.linux.pipe(&fds);
        if (std.posix.errno(rc) != .SUCCESS) return error.PipeFailed;
        self.* = .{
            .io = io,
            .fd = .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
            .pipe_w = .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
            .replies = replies,
        };
        // self-referential: the writer must point at the caller's stable
        // address, so init runs in place
        self.fw.init(self);
    }

    fn deinit(self: *FakeTty) void {
        self.fd.close(self.io);
        self.pipe_w.close(self.io);
        self.* = undefined;
    }

    fn writer(self: *FakeTty) *std.Io.Writer {
        return &self.fw.w;
    }

    fn read(self: *FakeTty, buf: []u8) !usize {
        const n = try self.fd.readStreaming(self.io, &.{buf});
        return n;
    }

    fn queryLog(self: *const FakeTty) []const u8 {
        return self.query_log[0..self.query_log_len];
    }
};

/// Writer for the fake: captures query bytes into the log and writes the
/// next scripted reply into the pipe (the terminal's behavior: query in,
/// reply out). Unbuffered — every write reaches `drain` immediately.
const FakeWriter = struct {
    tty: *FakeTty,
    w: std.Io.Writer = undefined,

    fn init(self: *FakeWriter, tty: *FakeTty) void {
        self.tty = tty;
        self.w = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *FakeWriter = @fieldParentPtr("w", w);
        const tty = self.tty;
        for (data) |d| {
            const copy_len = @min(d.len, tty.query_log.len - tty.query_log_len);
            if (copy_len > 0) {
                @memcpy(tty.query_log[tty.query_log_len .. tty.query_log_len + copy_len], d[0..copy_len]);
                tty.query_log_len += copy_len;
            }
        }
        if (tty.reply_idx < tty.replies.len) {
            const reply = tty.replies[tty.reply_idx];
            tty.pipe_w.writeStreamingAll(tty.io, reply) catch return error.WriteFailed;
            tty.reply_idx += 1;
        }
        return std.Io.Writer.countSplat(data, splat);
    }
};
