//! Blocking input reader with split-sequence reassembly.
//!
//! The Reader is the only user of the tty read path in the input pipeline:
//! it polls the tty fd, reads up to 256 bytes per poll, prepends any
//! previously held-back tail, decodes one Event with Parser.parse, and
//! holds back the trailing incomplete bytes so a sequence split across
//! reads (kitty CSI-u, OSC, paste) reassembles instead of leaking its tail
//! into the stream as literal characters.
//!
//! Adapted from zigzag `input/keyboard.zig` (`incompleteTailLen` verbatim,
//! split-seq reassembly) and zigzag `terminal/platform/posix.zig`
//! (`readInput` poll). The bare-ESC disambiguation (hold, then one
//! non-blocking poll, then flush as Escape) follows zigzag's program-loop
//! pattern.
//!
//! Lifetime contract (§3): `Key.text` and `paste` slices point into
//! Reader-owned scratch and are valid only until the next `next()` call —
//! apps must copy them into their own arena.

const std = @import("std");
const posix = std.posix;
const Event = @import("event.zig").Event;
const Key = @import("Key.zig");
const Parser = @import("Parser.zig");
const Tty = @import("tty.zig").Tty;

/// Fresh bytes read per poll (vaxis/zigzag 256B read).
const read_buf_len = 256;
/// Fixed assembly/hold-back capacity (§5: fixed 512B pending buffer).
const buf_len = 512;

pub const Reader = struct {
    /// The tty this reader pulls input from. The reader is the only user
    /// of the tty read path.
    tty: *Tty,

    /// Decodes one event from the assembled input (the parser's `buf`
    /// scratch lives here, so `Key.text` from CSI text fields points into
    /// the reader and stays stable across reads).
    parser: Parser = .{},

    /// Assembly area: the held tail prepended to fresh reads (zigzag
    /// `input_buf` pattern).
    scratch: [buf_len]u8 = undefined,
    /// Bytes held back from previous reads — an incomplete escape/CSI/SS3
    /// tail, a truncated UTF-8 sequence, and/or complete-but-unparsed
    /// leftover — prepended to the next read (zigzag `input_pending`
    /// pattern).
    pending: [buf_len]u8 = undefined,
    pending_len: usize = 0,

    /// Fixed arena for OSC 52 paste decode, reset before each parse. The
    /// decoded `paste` slice is valid only until the next `next()` call
    /// (§3); no heap allocation in the input path.
    paste_buf: [buf_len]u8 = undefined,
    paste_fba: std.heap.FixedBufferAllocator = undefined,
    paste_ready: bool = false,

    /// The outcome of decoding one assembled buffer.
    const DecodeOutcome = union(enum) {
        event: Event,
        /// The parser needs more bytes; everything is held in `pending`.
        incomplete,
        /// An eventless sequence was consumed; leftover held in `pending`.
        consumed,
    };

    pub fn init(tty: *Tty) Reader {
        return .{ .tty = tty };
    }

    /// Blocking read of the next event. Ctrl+C arrives as a normal
    /// `key_press` (the library never quits); `Key.text`/`paste` are valid
    /// only until the next call.
    pub fn next(self: *Reader) !Event {
        return (try self.nextTimeout(-1)) orelse return error.EndOfStream;
    }

    /// Read the next event, polling with a deadline. Returns null on
    /// timeout without consuming input; a tail held from a previous read
    /// survives the timeout, so a sequence split across a tick boundary
    /// still reassembles.
    pub fn nextTimeout(self: *Reader, timeout_ms: i32) !?Event {
        while (true) {
            // Complete data already held (leftover from a previous read)
            // decodes without waiting on the tty.
            const held_is_bare_esc = self.pending_len == 1 and self.pending[0] == 0x1b;
            if (self.pending_len > 0 and !held_is_bare_esc) {
                @memcpy(self.scratch[0..self.pending_len], self.pending[0..self.pending_len]);
                const total = self.pending_len;
                self.pending_len = 0;
                switch (try self.decode(self.scratch[0..total])) {
                    .event => |ev| return ev,
                    .consumed => continue,
                    .incomplete => {},
                }
            }

            // A bare ESC held from a previous read is either the start of a
            // sequence (the continuation may already be buffered) or the
            // Escape key itself: one non-blocking poll to disambiguate.
            const grace = self.pending_len == 1 and self.pending[0] == 0x1b;
            if (!(try self.pollFd(if (grace) 0 else timeout_ms))) {
                if (grace) {
                    self.pending_len = 0;
                    return .{ .key_press = .{ .codepoint = Key.escape } };
                }
                return null;
            }

            // Read up to 256 fresh bytes and prepend the held tail.
            var fresh: [read_buf_len]u8 = undefined;
            var max_fresh = @min(fresh.len, self.scratch.len - self.pending_len);
            if (max_fresh == 0) {
                // The held-back data fills the assembly buffer and is still
                // incomplete (an over-long sequence, e.g. a huge OSC 52
                // payload). Drop the oldest bytes so the stream keeps
                // flowing; the sequence cannot reassemble within the fixed
                // buffers (documented graceful degradation).
                @memmove(
                    self.pending[0 .. self.pending_len - fresh.len],
                    self.pending[fresh.len..self.pending_len],
                );
                self.pending_len -= fresh.len;
                max_fresh = @min(fresh.len, self.scratch.len - self.pending_len);
            }
            const n_read = try self.tty.read(fresh[0..max_fresh]);
            if (n_read == 0) {
                // EOF: the write end closed (pipe). Flush a held Escape, else
                // report end of stream.
                if (self.pending_len == 1 and self.pending[0] == 0x1b) {
                    self.pending_len = 0;
                    return .{ .key_press = .{ .codepoint = Key.escape } };
                }
                return error.EndOfStream;
            }

            @memcpy(self.scratch[0..self.pending_len], self.pending[0..self.pending_len]);
            @memcpy(
                self.scratch[self.pending_len .. self.pending_len + n_read],
                fresh[0..n_read],
            );
            const total = self.pending_len + n_read;
            self.pending_len = 0;
            switch (try self.decode(self.scratch[0..total])) {
                .event => |ev| return ev,
                .consumed, .incomplete => continue,
            }
        }
    }

    /// Poll the tty fd for readable input. Returns false on timeout. The
    /// poll restarts on EINTR (posix.poll), so SIGWINCH never breaks the
    /// wait.
    fn pollFd(self: *Reader, timeout_ms: i32) !bool {
        var pollfds = [_]posix.pollfd{.{
            .fd = self.tty.fd.handle,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const n = try posix.poll(&pollfds, timeout_ms);
        return n > 0 and (pollfds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0;
    }

    /// Decode one event from assembled input. Holds back the trailing
    /// incomplete bytes (escape tail and/or truncated UTF-8) into
    /// `pending`, plus any complete-but-unparsed leftover, so the next
    /// call reassembles or continues exactly where this one stopped.
    fn decode(self: *Reader, data: []const u8) !DecodeOutcome {
        if (data.len == 0) return .incomplete;

        // Hold back the incomplete escape/CSI/SS3 tail (zigzag verbatim)
        // and any truncated UTF-8 at the read boundary.
        const esc_tail = incompleteTailLen(data);
        const region_len = data.len - esc_tail;
        const utf8_tail = utf8IncompleteTailLen(data[0..region_len]);
        const hold = esc_tail + utf8_tail;
        const parse_input = data[0 .. data.len - hold];
        self.pending_len = hold;
        if (hold > 0) @memcpy(self.pending[0..hold], data[data.len - hold ..]);

        if (parse_input.len == 0) return .incomplete;

        const result = try self.parser.parse(parse_input, self.pasteAllocator());

        if (result.event) |ev| {
            self.prependToPending(parse_input[result.n..]);
            return .{ .event = ev };
        }
        if (result.n == 0) {
            // Incomplete: the parser needs the whole parse region plus more
            // bytes — hold everything.
            self.prependToPending(parse_input);
            return .incomplete;
        }
        // An eventless sequence was consumed (n > 0): keep the leftover.
        self.prependToPending(parse_input[result.n..]);
        return .consumed;
    }

    /// Prepend `bytes` to the held-back data (before the incomplete tail).
    fn prependToPending(self: *Reader, bytes: []const u8) void {
        if (bytes.len == 0) return;
        std.debug.assert(self.pending_len + bytes.len <= self.pending.len);
        @memmove(
            self.pending[bytes.len .. bytes.len + self.pending_len],
            self.pending[0..self.pending_len],
        );
        @memcpy(self.pending[0..bytes.len], bytes);
        self.pending_len += bytes.len;
    }

    /// The allocator for OSC 52 paste decode: a fixed arena reused per
    /// parse, so the decoded paste lives in the reader until the next call.
    fn pasteAllocator(self: *Reader) std.mem.Allocator {
        if (!self.paste_ready) {
            self.paste_fba = std.heap.FixedBufferAllocator.init(&self.paste_buf);
            self.paste_ready = true;
        } else {
            self.paste_fba.reset();
        }
        return self.paste_fba.allocator();
    }
};

/// Length of an incomplete escape/CSI/SS3 sequence at the END of `data`
/// (0 = the buffer ends on a complete event boundary). Terminal input can
/// split a key sequence across reads (each read is a separate non-blocking
/// read of up to 256 bytes); without holding the incomplete tail back,
/// parse() treats the leading ESC as the escape key and the sequence's
/// remaining bytes leak into the stream as literal characters — a kitty
/// protocol sequence split mid-way would type its own tail into a text
/// area. The caller saves these bytes and prepends them to the next read.
/// Verbatim from zigzag `input/keyboard.zig`.
pub fn incompleteTailLen(data: []const u8) usize {
    // Find the last ESC byte; everything after it is a (possibly
    // incomplete) sequence.
    var i = data.len;
    while (i > 0) {
        i -= 1;
        if (data[i] != 0x1b) continue;
        const tail = data[i..];
        if (tail.len == 1) return 1; // bare ESC: may be a sequence start
        if (tail[1] == '[' or tail[1] == 'O') {
            // CSI / SS3: complete only once a final byte (0x40-0x7E) follows.
            for (tail[2..]) |c| {
                if (c >= 0x40 and c <= 0x7e) return 0;
            }
            return tail.len;
        }
        return 0; // ESC + printable char (Alt+key): complete
    }
    return 0;
}

/// Number of trailing bytes (1..3) that form a possibly-incomplete UTF-8
/// sequence, or 0 when `data` is valid UTF-8 or the invalidity is not a
/// truncation. Used to hold back a multibyte character cut at a read
/// boundary so it reassembles instead of surfacing as InvalidUTF8.
fn utf8IncompleteTailLen(data: []const u8) usize {
    if (std.unicode.utf8ValidateSlice(data)) return 0;
    var k: usize = 1;
    while (k <= 3 and k <= data.len) : (k += 1) {
        if (!std.unicode.utf8ValidateSlice(data[0 .. data.len - k])) continue;
        // The dropped suffix must be a plausible truncated sequence: its
        // first byte must start a sequence longer than the suffix.
        const lead = data[data.len - k];
        const need = std.unicode.utf8ByteSequenceLength(lead) catch continue;
        if (need > k) return k;
    }
    return 0;
}

test {
    std.testing.refAllDecls(@This());
}

// ── test helpers ────────────────────────────────

const testing = std.testing;

/// A pipe-fed fake tty: no terminal required (zigzag custom-I/O pattern).
const Pipe = struct {
    read_fd: posix.fd_t,
    write_fd: posix.fd_t,

    fn init() !Pipe {
        const fds = try std.Io.Threaded.pipe2(.{});
        return .{ .read_fd = fds[0], .write_fd = fds[1] };
    }

    fn deinit(self: *Pipe) void {
        closeFd(self.read_fd);
        closeFd(self.write_fd);
        self.* = undefined;
    }

    /// A Tty whose read fd is the pipe's read end.
    fn tty(self: *const Pipe) Tty {
        return .{
            .io = testing.io,
            .fd = .{ .handle = self.read_fd, .flags = .{ .nonblocking = false } },
        };
    }

    fn write(self: *const Pipe, bytes: []const u8) !void {
        const f: std.Io.File = .{ .handle = self.write_fd, .flags = .{ .nonblocking = false } };
        try f.writeStreamingAll(testing.io, bytes);
    }

    /// Close the write end (EOF for the reader).
    fn closeWrite(self: *Pipe) void {
        closeFd(self.write_fd);
        self.write_fd = -1;
    }

    fn closeFd(fd: posix.fd_t) void {
        if (fd < 0) return;
        const f: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        f.close(testing.io);
    }
};

fn expectKeyPress(ev: Event, codepoint: u21, mods: Key.Modifiers) !void {
    switch (ev) {
        .key_press => |k| {
            try testing.expectEqual(codepoint, k.codepoint);
            try testing.expect(k.mods.eql(mods));
        },
        else => return error.TestUnexpectedResult,
    }
}

// ── unit tests ─────────────────────────────────

test "input: incompleteTailLen edge cases" {
    const vectors = [_]struct { data: []const u8, expected: usize }{
        .{ .data = "", .expected = 0 },
        .{ .data = "abc", .expected = 0 },
        .{ .data = "\x1b", .expected = 1 }, // bare ESC: may start a sequence
        .{ .data = "\x1b\x1b", .expected = 1 }, // all-escape: last ESC alone
        .{ .data = "\x1b\x1b\x1b", .expected = 1 },
        .{ .data = "\x1b[", .expected = 2 }, // CSI prefix, no final byte
        .{ .data = "\x1b[1;5", .expected = 5 },
        .{ .data = "\x1b[1;5u", .expected = 0 }, // full valid sequence
        .{ .data = "\x1bO", .expected = 2 }, // SS3 prefix, no final byte
        .{ .data = "\x1bOA", .expected = 0 },
        .{ .data = "\x1b[200~", .expected = 0 },
        .{ .data = "\x1ba", .expected = 0 }, // ESC + printable (Alt+key)
        .{ .data = "ab\x1b[", .expected = 2 }, // tail after plain text
    };
    for (vectors) |v| {
        try testing.expectEqual(v.expected, incompleteTailLen(v.data));
    }
}

test "input: split kitty seq across two reads reassembles" {
    var pipe = try Pipe.init();
    defer pipe.deinit();
    var tty = pipe.tty();
    var reader = Reader.init(&tty);

    // First read delivers only the CSI prefix.
    try pipe.write("\x1b[");
    try testing.expectEqual(@as(?Event, null), try reader.nextTimeout(100));

    // Second read completes the sequence: one kitty key event, and the
    // prefix never leaks as a literal '['. CSI 1;5 u is kitty key-code 1
    // (the raw codepoint, not the character '1') with the ctrl modifier.
    try pipe.write("1;5u");
    try expectKeyPress((try reader.nextTimeout(100)).?, 1, .{ .ctrl = true });

    try testing.expectEqual(@as(?Event, null), try reader.nextTimeout(20));
}

test "input: blocking next() reassembles a split seq (thread-fed)" {
    var pipe = try Pipe.init();
    defer pipe.deinit();
    var tty = pipe.tty();
    var reader = Reader.init(&tty);

    try pipe.write("\x1b[");
    const wfd = pipe.write_fd;
    const feeder = try std.Thread.spawn(.{}, struct {
        fn run(fd: posix.fd_t) void {
            std.Io.sleep(testing.io, .fromMilliseconds(30), .awake) catch return;
            const f: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
            f.writeStreamingAll(testing.io, "1;5u") catch return;
        }
    }.run, .{wfd});
    defer feeder.join();

    try expectKeyPress(try reader.next(), 1, .{ .ctrl = true });
}

test "input: escape alone vs escape-prefixed" {
    var pipe = try Pipe.init();
    defer pipe.deinit();
    var tty = pipe.tty();
    var reader = Reader.init(&tty);

    // A lone ESC is the Escape key (held, then flushed after a non-blocking
    // grace poll finds no continuation).
    try pipe.write("\x1b");
    try expectKeyPress(try reader.next(), Key.escape, .{});

    // An ESC-prefixed sequence decodes as its event, not as Escape.
    try pipe.write("\x1b[1;5u");
    try expectKeyPress(try reader.next(), 1, .{ .ctrl = true });
}

test "input: multibyte utf-8 cut at the 256B boundary reassembles" {
    var pipe = try Pipe.init();
    defer pipe.deinit();
    var tty = pipe.tty();
    var reader = Reader.init(&tty);

    // First read: 256 bytes ending in the lead byte of a 2-byte character.
    var chunk: [read_buf_len]u8 = undefined;
    @memset(chunk[0..], 'a');
    chunk[chunk.len - 1] = 0xC3; // lead byte of é
    try pipe.write(&chunk);
    for (0..chunk.len - 1) |_| {
        try expectKeyPress(try reader.next(), 'a', .{});
    }

    // Second read completes the character.
    try pipe.write("\xA9");
    const ev = try reader.next();
    switch (ev) {
        .key_press => |k| {
            try testing.expectEqual(@as(u21, 0xE9), k.codepoint);
            try testing.expectEqualStrings("é", k.text orelse return error.TestUnexpectedResult);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "input: paste tail held across reads (OSC 52)" {
    var pipe = try Pipe.init();
    defer pipe.deinit();
    var tty = pipe.tty();
    var reader = Reader.init(&tty);

    // OSC payload without its terminator: held as an incomplete tail.
    try pipe.write("\x1b]52;c;b3NjNTIgcGFzdGU=");
    try testing.expectEqual(@as(?Event, null), try reader.nextTimeout(100));

    // Terminator arrives in a later read: one complete paste event.
    try pipe.write("\x1b\\");
    const ev = (try reader.nextTimeout(100)).?;
    switch (ev) {
        .paste => |text| try testing.expectEqualStrings("osc52 paste", text),
        else => return error.TestUnexpectedResult,
    }
}

test "input: timeout returns null without consuming input" {
    var pipe = try Pipe.init();
    defer pipe.deinit();
    var tty = pipe.tty();
    var reader = Reader.init(&tty);

    try testing.expectEqual(@as(?Event, null), try reader.nextTimeout(50));

    // The input written after the timeout is still delivered in full.
    try pipe.write("x");
    try expectKeyPress((try reader.nextTimeout(100)).?, 'x', .{});
}

test "input: ctrl+c decodes as key_press, never quits" {
    var pipe = try Pipe.init();
    defer pipe.deinit();
    var tty = pipe.tty();
    var reader = Reader.init(&tty);

    // Legacy byte form: 0x03 maps to ctrl+'c'.
    try pipe.write("\x03");
    try expectKeyPress(try reader.next(), 'c', .{ .ctrl = true });

    // Kitty protocol form: the raw codepoint 0x03 with ctrl — this is the
    // shape Key.ctrl_c matches.
    try pipe.write("\x1b[3;5u");
    const ev = try reader.next();
    switch (ev) {
        .key_press => |k| {
            try testing.expectEqual(@as(u21, 0x03), k.codepoint);
            try testing.expect(k.mods.ctrl);
            try testing.expect(k.matches(Key.ctrl_c, .{ .ctrl = true }));
        },
        else => return error.TestUnexpectedResult,
    }
}

test "input: multi-event read preserves every event" {
    var pipe = try Pipe.init();
    defer pipe.deinit();
    var tty = pipe.tty();
    var reader = Reader.init(&tty);

    // Two keypresses in one read: the second must not be dropped.
    try pipe.write("ab");
    try expectKeyPress(try reader.next(), 'a', .{});
    try expectKeyPress(try reader.next(), 'b', .{});
}

test "input: leftover complete bytes before an incomplete tail" {
    var pipe = try Pipe.init();
    defer pipe.deinit();
    var tty = pipe.tty();
    var reader = Reader.init(&tty);

    // Two plain keypresses followed by a partial CSI in a single read.
    try pipe.write("ab\x1b[1;5");
    try expectKeyPress(try reader.next(), 'a', .{});
    try expectKeyPress(try reader.next(), 'b', .{});

    // The tail reassembles once the final byte arrives (kitty key-code 1,
    // ctrl).
    try pipe.write("u");
    try expectKeyPress((try reader.nextTimeout(100)).?, 1, .{ .ctrl = true });
}

test "input: pipe integration — full event sequence" {
    var pipe = try Pipe.init();
    defer pipe.deinit();
    var tty = pipe.tty();
    var reader = Reader.init(&tty);

    // A realistic coalesced batch: plain key, legacy arrow, kitty key,
    // ctrl+c byte.
    try pipe.write("a\x1b[A\x1b[97;5u\x03");
    try expectKeyPress(try reader.next(), 'a', .{});
    try expectKeyPress(try reader.next(), Key.up, .{});
    try expectKeyPress(try reader.next(), 'a', .{ .ctrl = true });
    try expectKeyPress(try reader.next(), 'c', .{ .ctrl = true });
}

test "input: EOF on a closed pipe" {
    var pipe = try Pipe.init();
    defer pipe.deinit();
    var tty = pipe.tty();
    var reader = Reader.init(&tty);

    try pipe.write("a");
    try expectKeyPress(try reader.next(), 'a', .{});
    pipe.closeWrite();
    try testing.expectError(error.EndOfStream, reader.next());
}
