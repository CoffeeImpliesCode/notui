//! Input: poll the terminal, assemble split sequences, decode one event.
//!
//! `Reader` polls the tty descriptor, reads up to `read_buf_len` bytes per
//! poll, prepends the tail it held back from the previous read, decodes one
//! `Event` with `Parser.parse`, and holds the trailing incomplete bytes so a
//! sequence split across reads reassembles instead of leaking its tail into
//! the stream as literal characters.
//!
//! Everything is fixed-size: no allocation happens in the input path, so the
//! reader adds no allocator dependency and no per-event cost.
//!
//! Two bounds are real and both fail closed, never by degrading into
//! keypresses:
//!
//! * An assembled sequence that fills the buffer and still has no terminator
//!   cannot ever be decoded. The reader drops it and ignores every byte up to
//!   its terminator, so no payload byte of an oversized sequence is ever
//!   delivered as a key. Input resumes at the first event after the
//!   terminator.
//! * The clipboard decode arena is sized for the buffer: a complete OSC 52
//!   sequence has to fit the 512-byte assembly buffer to be decoded at all,
//!   and its base64 payload decodes to well under the 512 bytes the arena
//!   holds. The two bounds cannot disagree, so the arena is not a limit a
//!   caller has to reason about.
//!
//! Borrowed results: a `key_press`'s `Key.text` and a `paste` point into the
//! reader's own scratch and are valid only until the next call to `next` or
//! `nextTimeout`. Copy them into memory the caller owns before returning from
//! the frame that received them.
//!
//! `io` is used for the buffered descriptor reads; readiness itself is a
//! native `posix.poll` on the tty's descriptor, and a bare ESC is resolved by
//! a zero-timeout poll. A `std.Io` implementation that does not own a real
//! descriptor cannot drive this reader, and a cancelation request does not
//! interrupt the poll: the wait ends at its own timeout.

const std = @import("std");
const posix = std.posix;
const Event = @import("event.zig").Event;
const Key = @import("Key.zig");
const Parser = @import("Parser.zig");
const Tty = @import("tty.zig").Tty;

/// Bytes read per poll.
const read_buf_len = 256;
/// The fixed assembly and hold-back capacity. A sequence that fills it and
/// still has no terminator is dropped whole: see the module contract.
const buf_len = 512;

/// What ends a sequence the reader is discarding.
const DiscardKind = enum {
    /// An OSC: `ESC \` (ST) or BEL. BEL terminates an OSC only, so a BEL
    /// inside another string is payload and not the end of it.
    osc,
    /// A DCS, APC, PM or SOS string: `ESC \` (ST) and nothing else.
    control_string,
    /// A CSI or SS3 parameter run: any byte in `0x40..=0x7E`.
    final_byte,

    /// The kind of sequence `bytes`, the tail of one too large to assemble,
    /// belongs to. A tail that does not start with a recognized introducer is
    /// treated as a parameter run: the reader drops bytes until one looks
    /// final, and never decodes anything in between.
    fn of(bytes: []const u8) DiscardKind {
        if (bytes.len >= 2 and bytes[0] == 0x1b) {
            return switch (bytes[1]) {
                ']' => .osc,
                'P', '_', '^', 'X', '|' => .control_string,
                else => .final_byte,
            };
        }
        return .final_byte;
    }
};

/// The bytes being dropped while the reader waits for one sequence's
/// terminator.
const Discard = struct {
    kind: DiscardKind,
    /// An `ESC` at the end of the bytes already dropped, so an `ESC \`
    /// terminator split across two reads is still recognised.
    after_escape: bool = false,

    /// Drop `bytes` as part of the discarded sequence and report how many of
    /// them the terminator ends: null while the sequence is still open, in
    /// which case every byte is dropped. A count is the terminator's own
    /// position plus one, so the caller keeps everything after it — input that
    /// arrived in the same read is ordinary input again, not part of the
    /// discarded payload.
    fn scan(self: *Discard, bytes: []const u8) ?usize {
        switch (self.kind) {
            .osc, .control_string => {
                for (bytes, 0..) |b, i| {
                    if (self.after_escape) {
                        if (b == '\\') return i + 1;
                        self.after_escape = b == 0x1b;
                    } else {
                        self.after_escape = b == 0x1b;
                    }
                    // BEL ends an OSC; inside any other string it is payload.
                    if (b == 0x07 and self.kind == .osc) return i + 1;
                }
            },
            .final_byte => {
                for (bytes, 0..) |b, i| {
                    if (b >= 0x40 and b <= 0x7e) return i + 1;
                }
            },
        }
        return null;
    }
};

/// Decodes one event at a time from a terminal's input.
///
/// The reader owns its own scratch and allocates nothing: it holds the tty by
/// pointer, and that tty must outlive it. Everything a decoded event borrows —
/// `Key.text`, a clipboard payload — points into this value and is invalidated
/// by the next `next` or `nextTimeout` call. One reader belongs to one thread;
/// it has no lock and takes none.
///
/// It must also stay at one address once it has been used. The clipboard arena
/// is created over `paste_buf`, which is a field of this value, so a reader
/// moved or copied after a decode would hand the parser an arena over the old
/// copy's buffer. Give it a stable home — a field of a longer-lived value, or
/// an allocation — before the first call.
pub const Reader = struct {
    /// The tty this reader pulls input from. The reader is the only user of
    /// the tty read path. Borrowed: the tty must outlive the reader.
    tty: *Tty,

    /// The decoder. Its `buf` scratch lives here, so text a CSI field decodes
    /// points into the reader and survives until the next call.
    parser: Parser = .{},

    /// The assembly area: the held tail prepended to each fresh read.
    scratch: [buf_len]u8 = undefined,
    /// Bytes held back from previous reads — an incomplete escape, control
    /// string or UTF-8 tail, and/or complete-but-unparsed leftover —
    /// prepended to the next read. Cleared when a sequence is discarded.
    pending: [buf_len]u8 = undefined,
    pending_len: usize = 0,

    /// The fixed arena clipboard payloads decode into, reset before each
    /// parse. A decoded payload borrows it and dies at the next parse. It is
    /// sized so that every sequence the reader can assemble also decodes: the
    /// assembly bound is what limits a payload, not this buffer.
    paste_buf: [buf_len]u8 = undefined,
    paste_fba: std.heap.FixedBufferAllocator = undefined,
    paste_ready: bool = false,

    /// Set while the bytes of one over-long sequence are being dropped; null
    /// while the reader is decoding normally.
    discard: ?Discard = null,

    /// The outcome of decoding one assembled buffer.
    const DecodeOutcome = union(enum) {
        event: Event,
        /// The parser needs more bytes; everything is held in `pending`.
        incomplete,
        /// An eventless sequence was consumed; leftover held in `pending`.
        consumed,
    };

    /// A reader over `tty`, which must outlive it.
    ///
    /// `init` returns by value, so the result must reach its final home before
    /// the first `next` or `nextTimeout`; see the address-stability rule on the
    /// type.
    pub fn init(tty: *Tty) Reader {
        return .{ .tty = tty };
    }

    /// The next event, blocking until one arrives or the input ends.
    ///
    /// `error.EndOfStream` when the input ended with no event left; anything
    /// the descriptor read or the parser reports propagates unchanged.
    ///
    /// EOF is final for this descriptor. Later calls keep reporting it rather than
    /// resuming a discarded sequence or exposing its payload as key events.
    ///
    /// Ctrl+C arrives as an ordinary `key_press`: this library never quits by
    /// itself. Everything the returned event borrows is valid until the next
    /// call.
    pub fn next(self: *Reader) !Event {
        return (try self.nextTimeout(-1)) orelse return error.EndOfStream;
    }

    /// The next event, waiting at most `timeout_ms` milliseconds.
    /// `timeout_ms` of -1 waits indefinitely, 0 polls once.
    ///
    /// Returns null when the wait expired with no event, without consuming
    /// input: bytes held from a previous read survive the timeout, so a
    /// sequence split across a frame boundary still reassembles. While an
    /// over-long sequence is being discarded the same holds — a timeout
    /// returns null and the discard keeps dropping.
    ///
    /// `error.EndOfStream` and any read or parse failure mean the same as in `next`.
    /// Everything the returned event borrows is valid until the next call.
    pub fn nextTimeout(self: *Reader, timeout_ms: i32) !?Event {
        while (true) {
            // Bytes of one over-long sequence are being dropped: wait, drop,
            // and watch for its terminator. Nothing here is decoded, so no
            // payload byte can reach the caller as a key.
            if (self.discard) |*d| {
                if (!try self.pollFd(timeout_ms)) return null;
                var chunk: [read_buf_len]u8 = undefined;
                const n = try self.tty.read(&chunk);
                if (n == 0) {
                    // The input ended inside a discarded sequence: there is
                    // nothing left to resynchronize on.
                    self.discard = null;
                    return error.EndOfStream;
                }
                if (d.scan(chunk[0..n])) |used| {
                    // The terminator ended the discarded sequence. Bytes after
                    // it arrived in the same read and are ordinary input, so
                    // they go back to the decoder instead of being dropped.
                    self.discard = null;
                    const rest = chunk[used..n];
                    self.pending_len = rest.len;
                    @memcpy(self.pending[0..rest.len], rest);
                }
                continue;
            }

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
            const max_fresh = @min(fresh.len, self.scratch.len - self.pending_len);
            if (max_fresh == 0) {
                // The held tail fills the assembly buffer and still has no
                // terminator, so it can never reassemble. Drop the whole
                // sequence and every byte up to its terminator: keeping its
                // prefix would decode the rest of its payload as keys.
                self.beginDiscard();
                continue;
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

    /// Give up on the sequence held in `pending`: it fills the fixed
    /// assembly buffer and cannot ever complete. Drop it and everything up
    /// to its terminator, then carry on reading the stream behind it.
    fn beginDiscard(self: *Reader) void {
        const kind = DiscardKind.of(self.pending[0..self.pending_len]);
        std.log.scoped(.notui_input).warn(
            "input sequence exceeded {d} bytes and was dropped; its bytes " ++
                "are ignored until the terminator",
            .{self.pending.len},
        );
        self.discard = .{ .kind = kind };
        self.pending_len = 0;
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

test "input: an over-long sequence drops its payload instead of typing it" {
    var pipe = try Pipe.init();
    defer pipe.deinit();
    var tty = pipe.tty();
    var reader = Reader.init(&tty);

    // A clipboard payload far larger than the fixed assembly buffer, with no
    // terminator yet: the sequence can never be assembled.
    const head = "\x1b]52;c;";
    var seq: [head.len + 1024]u8 = undefined;
    @memcpy(seq[0..head.len], head[0..]);
    @memset(seq[head.len..], 'p');
    try pipe.write(&seq);

    // Not one of those bytes arrives as a keypress; the reader is holding
    // nothing and offering nothing.
    try testing.expectEqual(@as(?Event, null), try reader.nextTimeout(50));
    try testing.expect(reader.discard != null);

    // The rest of the payload, then the terminator: all of it is dropped, and
    // the reader stops discarding only at the terminator.
    try pipe.write(&seq);
    try pipe.write("\x1b\\");
    try testing.expectEqual(@as(?Event, null), try reader.nextTimeout(100));
    try testing.expect(reader.discard == null);

    // The next real key is delivered normally.
    try pipe.write("z");
    try expectKeyPress((try reader.nextTimeout(100)).?, 'z', .{});
}

test "input: an over-long parameter run is dropped up to its final byte" {
    var pipe = try Pipe.init();
    defer pipe.deinit();
    var tty = pipe.tty();
    var reader = Reader.init(&tty);

    // A CSI introducer followed by parameters and no final byte: the reader
    // cannot know where the run ends, so it drops bytes until one is final.
    var params: [600]u8 = undefined;
    params[0] = 0x1b;
    params[1] = '[';
    @memset(params[2..], ';');
    try pipe.write(&params);
    try testing.expectEqual(@as(?Event, null), try reader.nextTimeout(50));
    try testing.expect(reader.discard != null);

    // The final byte ends the discarded sequence. It is consumed rather than
    // decoded, and input resumes behind it.
    try pipe.write("m");
    try testing.expectEqual(@as(?Event, null), try reader.nextTimeout(100));
    try testing.expect(reader.discard == null);
    try pipe.write("z");
    try expectKeyPress((try reader.nextTimeout(100)).?, 'z', .{});
}

test "input: a discarded sequence ends at the end of the input" {
    var pipe = try Pipe.init();
    defer pipe.deinit();
    var tty = pipe.tty();
    var reader = Reader.init(&tty);

    // A payload with no terminator, and then the writer closes: there is
    // nothing left to resynchronize on, and the reader says so instead of
    // hanging on a terminator that will never arrive.
    const head = "\x1b]52;c;";
    var seq: [head.len + 600]u8 = undefined;
    @memcpy(seq[0..head.len], head[0..]);
    @memset(seq[head.len..], 'p');
    try pipe.write(&seq);
    try testing.expectEqual(@as(?Event, null), try reader.nextTimeout(50));
    pipe.closeWrite();
    try testing.expectError(error.EndOfStream, reader.next());

    // The residue contract, observed instead of inspected: the end of input
    // is final. Both entry points keep reporting it — the reader does not
    // resume the discard and wait on a terminator that will never arrive, and
    // no byte of the dropped payload comes back as a key.
    try testing.expectError(error.EndOfStream, reader.next());
    try testing.expectError(error.EndOfStream, reader.nextTimeout(10));
}

test "input: input arriving with the terminator is not discarded with it" {
    var pipe = try Pipe.init();
    defer pipe.deinit();
    var tty = pipe.tty();
    var reader = Reader.init(&tty);

    // Put the reader into a discard with a control string already open.
    const head = "\x1b]52;c;";
    var seq: [head.len + 600]u8 = undefined;
    @memcpy(seq[0..head.len], head[0..]);
    @memset(seq[head.len..], 'p');
    try pipe.write(&seq);
    try testing.expectEqual(@as(?Event, null), try reader.nextTimeout(50));
    try testing.expect(reader.discard != null);

    // The terminator and a real key arrive in one read. Only the bytes up to
    // the terminator belong to the discarded sequence; the key behind it is
    // ordinary input and must still be delivered.
    try pipe.write("\x1b\\z");
    try expectKeyPress((try reader.nextTimeout(100)).?, 'z', .{});
    try testing.expect(reader.discard == null);
}

test "input: a BEL inside a control string is payload, not its terminator" {
    var pipe = try Pipe.init();
    defer pipe.deinit();
    var tty = pipe.tty();
    var reader = Reader.init(&tty);

    // An APC string longer than the assembly buffer. BEL ends an OSC and
    // nothing else, so a BEL in this payload must not be mistaken for the
    // end of the sequence and release the payload behind it as keys.
    const head = "\x1b_Gi=9931;";
    var seq: [head.len + 1024]u8 = undefined;
    @memcpy(seq[0..head.len], head[0..]);
    @memset(seq[head.len..], 'p');
    seq[700] = 0x07; // past the assembly buffer, so the discard sees it
    try pipe.write(&seq);
    try testing.expectEqual(@as(?Event, null), try reader.nextTimeout(50));
    try testing.expect(reader.discard != null);

    // The reader is still discarding after the BEL, so this key is dropped
    // with the payload it arrived inside of.
    try pipe.write("z");
    try testing.expectEqual(@as(?Event, null), try reader.nextTimeout(50));
    try testing.expect(reader.discard != null);

    // ST really does end it, and input resumes.
    try pipe.write("\x1b\\");
    try testing.expectEqual(@as(?Event, null), try reader.nextTimeout(100));
    try testing.expect(reader.discard == null);
    try pipe.write("z");
    try expectKeyPress((try reader.nextTimeout(100)).?, 'z', .{});
}
