//! Bounded output staging: the backpressure seam between the renderer
//! and the terminal (roadmap B1).
//!
//! One fixed byte buffer sits in front of the transport. Everything an
//! interactive frame produces — the paint envelope, the mode diff, the
//! title, the band repaint, a history batch — is staged in that buffer
//! first, so a frame reaches the terminal as ONE contiguous write
//! attempt instead of a dribble of small writes. Bytes the transport
//! has not accepted yet are *pending*: they stay in the buffer, memory
//! is bounded by `Options.capacity` for the whole session, and the next
//! drain resumes exactly where the last one stopped. A short write
//! loses nothing, and a would-block transport consumes nothing.
//!
//! Backpressure: while `pending() >= watermark` the App must NOT
//! compose another frame (`canCompose` is false). It drains, keeps
//! reading input, and retries the frame later. Nothing is ever dropped,
//! so committed history cannot disappear because a reader was slow.
//!
//! Failure discipline: a frame that does not fit the remaining space
//! fails ATOMICALLY. The staging writer reports `error.WriteFailed`
//! (never a zero-progress short write, which would spin `writeAll`),
//! sets `frameOverflowed`, and the caller reports
//! `error.FrameTooLarge` after `abortFrame` has rolled the staged bytes
//! back. The queue — and every piece of frame state behind it — is
//! exactly what it was before the frame started.
//!
//! Copy discipline: the only compaction is the one at `beginFrame`
//! (slide pending bytes to the front when the free tail is smaller than
//! half the live bytes). Drains never copy.

const std = @import("std");
const posix = std.posix;

pub const OutputQueue = struct {
    pub const Options = struct {
        /// Hard bound on staged bytes: pending output plus the frame
        /// being composed. Allocated once, never resized.
        capacity: usize = 256 * 1024,
        /// Composition watermark. `canCompose` is false while pending
        /// output reaches it, which is the backpressure signal. It is
        /// also the headroom guarantee: a frame that starts below the
        /// watermark always has `capacity - watermark` bytes of room
        /// after `beginFrame`.
        watermark: usize = 128 * 1024,
    };

    /// Composition refused: staged output already sits at the
    /// watermark. The caller must drain and retry; nothing was lost.
    pub const Backpressure = error{OutputBackpressure};
    /// The frame exceeded the declared capacity. Nothing was staged.
    pub const Overflow = error{FrameTooLarge};
    pub const WriteError = error{WriteFailed};

    gpa: std.mem.Allocator,
    /// The whole session's output budget, in one allocation.
    buf: []u8,
    /// Composition watermark (see `Options.watermark`).
    watermark: usize,
    /// `buf[start..end)` is pending: staged, not yet accepted.
    start: usize = 0,
    end: usize = 0,
    /// `end` when the current frame started; `abortFrame` restores it.
    frame_start: usize = 0,
    /// The current frame needed more room than the queue had.
    overflowed: bool = false,
    /// Largest pending count ever seen (bench + backpressure telemetry).
    peak_pending: usize = 0,
    /// Total bytes accepted by transports (bench).
    total_written: usize = 0,
    /// The staging writer. `beginFrame` re-points its buffer at the
    /// free tail, so use the queue through a stable pointer after
    /// `init` (the same rule as `Tty`).
    w: std.Io.Writer = undefined,

    pub fn init(gpa: std.mem.Allocator, opts: Options) !OutputQueue {
        std.debug.assert(opts.capacity > 1);
        std.debug.assert(opts.watermark < opts.capacity);
        const buf = try gpa.alloc(u8, opts.capacity);
        errdefer gpa.free(buf);
        return .{
            .gpa = gpa,
            .buf = buf,
            .watermark = opts.watermark,
            .w = .{
                .vtable = &.{
                    .drain = stageDrain,
                    .rebase = noRebase,
                    .flush = std.Io.Writer.noopFlush,
                },
                .buffer = buf[0..],
            },
        };
    }

    pub fn deinit(self: *OutputQueue) void {
        self.gpa.free(self.buf);
        self.* = undefined;
    }

    /// Start staging a frame. The staging writer is valid until
    /// `commitFrame`/`abortFrame`; bytes written to it land at the
    /// queue's tail, behind whatever is still pending.
    pub fn beginFrame(self: *OutputQueue) void {
        // The one compaction point. Slide the live bytes to the front
        // when the free tail has shrunk below half of what is pending;
        // a frame is far bigger than the worst-case slide, so the copy
        // is paid once per frame instead of once per write.
        if (self.start > 0 and self.buf.len - self.end < (self.buf.len - self.start) / 2) {
            const live = self.pending();
            std.mem.copyForwards(u8, self.buf[0..live], self.buf[self.start..self.end]);
            self.start = 0;
            self.end = live;
        }
        self.frame_start = self.end;
        self.w.buffer = self.buf[self.end..];
        self.w.end = 0;
        self.overflowed = false;
    }

    /// Publish the staged frame as pending output.
    pub fn commitFrame(self: *OutputQueue) void {
        self.end += self.w.end;
        self.w.end = 0;
        self.peak_pending = @max(self.peak_pending, self.pending());
    }

    /// Drop the staged frame: pending bytes, overflow flag and every
    /// other piece of queue state are exactly what they were before
    /// `beginFrame`.
    pub fn abortFrame(self: *OutputQueue) void {
        self.w.end = 0;
        self.end = self.frame_start;
        self.overflowed = false;
    }

    /// True when the frame needed more room than the queue had. The
    /// frame is incomplete; call `abortFrame` and report
    /// `error.FrameTooLarge` to the caller.
    pub fn frameOverflowed(self: *const OutputQueue) bool {
        return self.overflowed;
    }

    /// Bytes staged but not yet accepted by a transport.
    pub fn pending(self: *const OutputQueue) usize {
        return self.end - self.start;
    }

    /// Free bytes at the tail: the room one more frame may occupy.
    pub fn space(self: *const OutputQueue) usize {
        return self.buf.len - self.end;
    }

    /// False once pending output reaches the watermark: the terminal is
    /// not draining, so composing another frame would grow memory
    /// without bound. Drain and retry instead.
    pub fn canCompose(self: *const OutputQueue) bool {
        return self.pending() < self.watermark;
    }

    /// `canCompose`, or `error.OutputBackpressure`. Callers use this to
    /// fail before they touch the frame buffers.
    pub fn compose(self: *const OutputQueue) Backpressure!void {
        if (!self.canCompose()) return error.OutputBackpressure;
    }

    /// The staging writer for the frame in progress.
    pub fn writer(self: *OutputQueue) *std.Io.Writer {
        return &self.w;
    }

    /// One nonblocking transport attempt. `sink` must expose
    /// `tryWrite(bytes: []const u8) error{WriteFailed}!usize`: a single
    /// write attempt returning the accepted byte count, 0 when the
    /// transport would block. Returns the accepted count: a short write
    /// leaves the remainder pending, in order, and the next drain
    /// continues with it. A fully drained queue compacts to the start
    /// of the buffer.
    pub fn drain(self: *OutputQueue, sink: anytype) WriteError!usize {
        if (self.start == self.end) return 0;
        const taken = try sink.tryWrite(self.buf[self.start..self.end]);
        std.debug.assert(taken <= self.pending());
        self.start += taken;
        self.total_written += taken;
        if (self.start == self.end) {
            self.start = 0;
            self.end = 0;
        }
        return taken;
    }

    /// Block until every pending byte is accepted. For teardown and for
    /// the piped (non-TTY) path, where there is no interactive loop to
    /// retry on. Short writes are resumed here too.
    ///
    /// A writer that accepts nothing is a failed write, not a reason to
    /// spin: `error.WriteFailed` leaves the bytes pending so the caller
    /// can decide, and the loop always makes progress or fails.
    pub fn drainAll(self: *OutputQueue, w: *std.Io.Writer) WriteError!void {
        while (self.start != self.end) {
            const taken = try w.write(self.buf[self.start..self.end]);
            if (taken == 0) return error.WriteFailed;
            self.start += taken;
            self.total_written += taken;
        }
        self.start = 0;
        self.end = 0;
    }

    /// Staging writer drain: the leading slices of `data` are consumed
    /// once, the final element is the pattern and is consumed `splat`
    /// times (per the `std.Io.Writer` vtable contract). When the frame
    /// needs more room than the queue has, the stage fails atomically
    /// with `error.WriteFailed` — a short return would let `writeAll`
    /// spin on a zero-progress drain.
    fn stageDrain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        std.debug.assert(data.len > 0);
        const self: *OutputQueue = @fieldParentPtr("w", w);
        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |chunk| {
            if (stageBytes(w, chunk) != chunk.len) {
                self.overflowed = true;
                return error.WriteFailed;
            }
            consumed += chunk.len;
        }
        const pattern = data[data.len - 1];
        var copies: usize = splat;
        while (copies > 0) : (copies -= 1) {
            if (stageBytes(w, pattern) != pattern.len) {
                self.overflowed = true;
                return error.WriteFailed;
            }
            consumed += pattern.len;
        }
        return consumed;
    }

    /// Copy what fits into the writer's free tail; the count returned
    /// is what the caller can account for.
    fn stageBytes(w: *std.Io.Writer, bytes: []const u8) usize {
        const room = w.buffer.len - w.end;
        const n = @min(room, bytes.len);
        if (n > 0) {
            @memcpy(w.buffer[w.end..][0..n], bytes[0..n]);
            w.end += n;
        }
        return n;
    }

    /// The queue never reclaims space through a rebase mid-frame: the
    /// frame must fail atomically, not be pushed out in pieces.
    fn noRebase(_: *std.Io.Writer, _: usize, _: usize) std.Io.Writer.Error!void {}
};

/// A nonblocking byte sink behind a vtable. The App, the bench and the
/// tests substitute their own without a terminal; `Tty.tryWrite` is
/// the production implementation (`tryWriteFd`).
///
/// `tryWrite` performs ONE write attempt: the number of accepted
/// bytes, or 0 when the transport would block. Short writes and
/// would-block are the same contract — the caller keeps the remainder
/// queued. Only `error.WriteFailed` is a real failure.
pub const Transport = struct {
    ctx: *anyopaque,
    try_write: *const fn (ctx: *anyopaque, bytes: []const u8) OutputQueue.WriteError!usize,

    pub fn tryWrite(self: Transport, bytes: []const u8) OutputQueue.WriteError!usize {
        return self.try_write(self.ctx, bytes);
    }

    /// Wrap any `sink: *T` exposing
    /// `tryWrite([]const u8) error{WriteFailed}!usize`.
    pub fn from(sink: anytype) Transport {
        const T = std.meta.Child(@TypeOf(sink));
        return .{
            .ctx = @ptrCast(sink),
            .try_write = struct {
                fn call(ctx: *anyopaque, bytes: []const u8) OutputQueue.WriteError!usize {
                    const p: *T = @ptrCast(@alignCast(ctx));
                    return p.tryWrite(bytes);
                }
            }.call,
        };
    }
};

/// One nonblocking write attempt on an open descriptor. `WouldBlock`
/// is 0 bytes (the caller keeps its frame queued); every other failure
/// is `error.WriteFailed`. The descriptor must have been opened
/// `O_NONBLOCK` — a blocking descriptor would block the loop, which is
/// exactly what this queue exists to prevent.
pub fn tryWriteFd(io: std.Io, fd: std.Io.File, bytes: []const u8) OutputQueue.WriteError!usize {
    return std.Io.File.writeStreaming(fd, io, "", &.{bytes}, 1) catch |err| switch (err) {
        error.WouldBlock => 0,
        else => error.WriteFailed,
    };
}

test {
    std.testing.refAllDecls(@This());
}

const testing = std.testing;

/// A transport that accepts at most `chunk` bytes per attempt and
/// records every call: `calls` proves the one-submit-per-frame
/// property, `block` simulates a reader that stopped draining.
const FakeSink = struct {
    /// Everything the transport accepted, in order.
    buf: [8192]u8 = undefined,
    len: usize = 0,
    /// Max bytes accepted per attempt (short write).
    chunk: usize = std.math.maxInt(usize),
    /// The reader stopped draining: every attempt would block.
    block: bool = false,
    /// Number of write attempts (one submit per frame is the goal).
    calls: usize = 0,
    /// Bytes offered across all attempts.
    offered: usize = 0,

    fn tryWrite(self: *FakeSink, bytes: []const u8) OutputQueue.WriteError!usize {
        self.calls += 1;
        self.offered += bytes.len;
        if (self.block) return 0;
        const n = @min(bytes.len, self.chunk);
        std.debug.assert(self.len + n <= self.buf.len);
        @memcpy(self.buf[self.len..][0..n], bytes[0..n]);
        self.len += n;
        return n;
    }

    fn deliveredBytes(self: *const FakeSink) []const u8 {
        return self.buf[0..self.len];
    }
};

/// A real nonblocking pipe: the slow-reader gate. The transport is a
/// genuine fd, so the WouldBlock comes from the kernel, not a counter.
const PipeSink = struct {
    /// Write end — the transport writes here.
    write: std.Io.File,
    /// Read end — the slow reader drains this when it decides to.
    read: std.Io.File,

    fn init() !PipeSink {
        const fds = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true });
        return .{
            .write = .{ .handle = fds[1], .flags = .{ .nonblocking = true } },
            .read = .{ .handle = fds[0], .flags = .{ .nonblocking = true } },
        };
    }

    fn deinit(self: *PipeSink) void {
        self.write.close(testing.io);
        self.read.close(testing.io);
    }

    fn tryWrite(self: *PipeSink, bytes: []const u8) OutputQueue.WriteError!usize {
        return tryWriteFd(testing.io, self.write, bytes);
    }
};

/// Stage one frame's bytes, failing the way the App does.
fn stage(q: *OutputQueue, bytes: []const u8) !void {
    q.beginFrame();
    q.writer().writeAll(bytes) catch {
        q.abortFrame();
        return error.FrameTooLarge;
    };
    try testing.expect(!q.frameOverflowed());
    q.commitFrame();
}

test "output: a frame is submitted to the transport in one write" {
    var q = try OutputQueue.init(testing.allocator, .{ .capacity = 4096, .watermark = 2048 });
    defer q.deinit();
    var sink = FakeSink{};

    const frame = "\x1b[?2026h\rhello\r\x1b[?2026l";
    try stage(&q, frame);
    try testing.expectEqual(frame.len, q.pending());

    const taken = try q.drain(&sink);
    try testing.expectEqual(frame.len, taken);
    try testing.expectEqual(@as(usize, 1), sink.calls); // one submit
    try testing.expectEqualStrings("\x1b[?2026h\rhello\r\x1b[?2026l", sink.deliveredBytes());
    try testing.expectEqual(@as(usize, 0), q.pending());
    try testing.expectEqual(@as(usize, 0), try q.drain(&sink)); // empty: no syscall
    try testing.expectEqual(@as(usize, 1), sink.calls);
}

test "output: a short write keeps the remainder pending, in order" {
    var q = try OutputQueue.init(testing.allocator, .{ .capacity = 4096, .watermark = 2048 });
    defer q.deinit();
    var sink = FakeSink{ .chunk = 3 };

    try stage(&q, "abcdefgh");
    try testing.expectEqual(@as(usize, 3), try q.drain(&sink));
    try testing.expectEqual(@as(usize, 5), q.pending());
    try testing.expectEqualStrings("abc", sink.deliveredBytes());

    // The next attempts continue where the last stopped; nothing is
    // rewritten and nothing is dropped.
    try testing.expectEqual(@as(usize, 3), try q.drain(&sink));
    try testing.expectEqual(@as(usize, 2), q.pending());
    try testing.expectEqual(@as(usize, 2), try q.drain(&sink));
    try testing.expectEqual(@as(usize, 0), q.pending());
    try testing.expectEqualStrings("abcdefgh", sink.deliveredBytes());
}

test "output: a blocked transport consumes nothing and keeps the frame" {
    var q = try OutputQueue.init(testing.allocator, .{ .capacity = 4096, .watermark = 2048 });
    defer q.deinit();
    var sink = FakeSink{};

    try stage(&q, "frame-bytes");
    sink.block = true;
    try testing.expectEqual(@as(usize, 0), try q.drain(&sink));
    try testing.expectEqual(@as(usize, 11), q.pending());
    try testing.expectEqualStrings("", sink.deliveredBytes());

    sink.block = false;
    _ = try q.drain(&sink);
    try testing.expectEqualStrings("frame-bytes", sink.deliveredBytes());
}

test "output: composition refuses above the watermark and resumes after a drain" {
    var q = try OutputQueue.init(testing.allocator, .{ .capacity = 64, .watermark = 16 });
    defer q.deinit();
    var sink = FakeSink{ .block = true };

    try stage(&q, "0123456789abcdef"); // 16 bytes pending == watermark
    try testing.expect(!q.canCompose());
    try testing.expectError(error.OutputBackpressure, q.compose());
    // The refusal happens before any frame state is touched: the staged
    // bytes are still exactly the ones already pending.
    try testing.expectEqual(@as(usize, 16), q.pending());

    // Refused again while blocked: the queue cannot grow past its
    // capacity, which is the memory bound a slow reader needs.
    try testing.expectEqual(@as(usize, 0), try q.drain(&sink));
    try testing.expect(!q.canCompose());

    sink.block = false;
    try testing.expectEqual(@as(usize, 16), try q.drain(&sink));
    try testing.expect(q.canCompose());
    try q.compose();
    try testing.expectEqual(@as(usize, 0), q.pending());
}
test "output: an oversized frame fails atomically, nothing staged" {
    var q = try OutputQueue.init(testing.allocator, .{ .capacity = 32, .watermark = 16 });
    defer q.deinit();
    var sink = FakeSink{};

    try stage(&q, "kept");
    q.beginFrame();
    // The staging writer reports the failure instead of truncating or
    // spinning on a zero-progress drain.
    try testing.expectError(
        error.WriteFailed,
        q.writer().writeAll("0123456789012345678901234567890123456789"),
    );
    try testing.expect(q.frameOverflowed());
    // The pending bytes and their length are unchanged: the incomplete
    // frame never reached the transport.
    try testing.expectEqual(@as(usize, 4), q.pending());
    _ = try q.drain(&sink);
    try testing.expectEqualStrings("kept", sink.deliveredBytes());
}

test "output: a full queue fails the write instead of reporting no progress" {
    var q = try OutputQueue.init(testing.allocator, .{ .capacity = 8, .watermark = 4 });
    defer q.deinit();
    var sink = FakeSink{};

    // A frame that exactly fills the buffer stages; the next byte
    // cannot.
    try stage(&q, "12345678");
    q.beginFrame();
    try testing.expectError(error.WriteFailed, q.writer().writeByte('9'));
    try testing.expect(q.frameOverflowed());
    q.abortFrame();
    try testing.expectEqual(@as(usize, 0), q.space());
    _ = try q.drain(&sink);
    try testing.expectEqualStrings("12345678", sink.deliveredBytes());
}

test "output: the staging writer honours the splat contract" {
    var q = try OutputQueue.init(testing.allocator, .{ .capacity = 4096, .watermark = 2048 });
    defer q.deinit();
    var sink = FakeSink{};

    q.beginFrame();
    // Larger than the internal room? No: a plain splat write must land
    // the pattern `splat` times plus the leading slices.
    _ = try q.writer().writeSplat(&.{ "ab", "cd" }, 3);
    _ = try q.writer().writeSplat(&.{"="}, 4);
    try testing.expect(!q.frameOverflowed());
    q.commitFrame();
    _ = try q.drain(&sink);
    // "ab" once, then "cd" splatted three times, then four "=".
    try testing.expectEqualStrings("abcdcdcd====", sink.deliveredBytes());
}

test "output: a splat that outruns the queue fails instead of truncating" {
    var q = try OutputQueue.init(testing.allocator, .{ .capacity = 16, .watermark = 8 });
    defer q.deinit();
    var sink = FakeSink{};

    try testing.expectError(error.WriteFailed, q.writer().writeSplat(&.{"x"}, 32));
    try testing.expect(q.frameOverflowed());
    q.abortFrame();
    _ = try q.drain(&sink);
    try testing.expectEqualStrings("", sink.deliveredBytes());
}

test "output: the frame is compacted once, at beginFrame, then composing works again" {
    // A watermark close to the capacity lets the tail run out while
    // plenty of room sits in front of the pending bytes: compaction has
    // to happen at the frame boundary, or the next frame is refused for
    // the wrong reason.
    var q = try OutputQueue.init(testing.allocator, .{ .capacity = 64, .watermark = 56 });
    defer q.deinit();
    var sink = FakeSink{ .chunk = 1 };

    const chunk = "y" ** 20;
    try stage(&q, chunk);
    try stage(&q, chunk);
    try stage(&q, chunk);
    try testing.expectEqual(@as(usize, 60), q.pending());
    try testing.expect(!q.canCompose()); // 60 >= watermark

    // Short writes creep the pending window toward the front of the
    // buffer while the tail stays exhausted.
    for (0..8) |_| _ = try q.drain(&sink);
    try testing.expectEqual(@as(usize, 52), q.pending());
    try testing.expect(q.canCompose());

    // The next frame compacts instead of failing: the queue had room
    // all along.
    try stage(&q, "next-frame");
    try testing.expectEqual(@as(usize, 62), q.pending());
    while (q.pending() > 0) _ = try q.drain(&sink);
    try testing.expectEqualStrings("y" ** 60 ++ "next-frame", sink.deliveredBytes());
}

test "output: peak pending and total written track the session" {
    var q = try OutputQueue.init(testing.allocator, .{ .capacity = 64, .watermark = 32 });
    defer q.deinit();
    var sink = FakeSink{ .chunk = 2 };

    try stage(&q, "abcdef");
    _ = try q.drain(&sink);
    try stage(&q, "ghij");
    _ = try q.drain(&sink);
    while (q.pending() > 0) _ = try q.drain(&sink);
    try testing.expectEqual(@as(usize, 8), q.peak_pending);
    try testing.expectEqual(@as(usize, 10), q.total_written);
    try testing.expectEqualStrings("abcdefghij", sink.deliveredBytes());
}

test "output: drainAll blocks out the remainder through a plain writer" {
    var q = try OutputQueue.init(testing.allocator, .{ .capacity = 64, .watermark = 32 });
    defer q.deinit();
    var sink = FakeSink{ .chunk = 2 };
    try stage(&q, "abcdef");
    _ = try q.drain(&sink);

    var out: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try q.drainAll(&w);
    try testing.expectEqual(@as(usize, 0), q.pending());
    try testing.expectEqualStrings("cdef", w.buffered());
}

test "output: a slow reader defers frames and memory stays bounded" {
    // The reader never touches the pipe, so the kernel pipe buffer
    // (64 KiB by default) fills and the transport blocks. The queue is
    // then the ONLY memory that grows, and it stops at its declared
    // capacity: frames defer, they do not vanish.
    var q = try OutputQueue.init(testing.allocator, .{
        .capacity = 64 * 1024,
        .watermark = 32 * 1024,
    });
    defer q.deinit();
    var sink = try PipeSink.init();
    defer sink.deinit();

    const frame = "x" ** 4096;
    var composed: usize = 0;
    var blocked = false;
    while (q.canCompose()) {
        try stage(&q, frame);
        composed += 1;
        _ = try q.drain(&sink);
        if (!q.canCompose()) {
            blocked = true;
            // Backpressure: the next frame is refused, not dropped.
            try testing.expectError(error.OutputBackpressure, q.compose());
        }
    }

    try testing.expect(blocked);
    try testing.expect(composed > 1);
    // The bound holds: pending never exceeds capacity, and the peak is
    // the watermark plus at most the frame that crossed it.
    try testing.expect(q.pending() <= q.buf.len);
    try testing.expect(q.peak_pending <= q.watermark + frame.len);

    // The reader drains: every deferred frame arrives, in order, byte
    // for byte, so a slow reader costs latency and never history. The
    // loop runs until a full round moves nothing: the queue drains
    // first, then whatever the reader frees is counted.
    var buf: [4096]u8 = undefined;
    var delivered: usize = 0;
    var rounds: usize = 0;
    while (rounds < 4096) : (rounds += 1) {
        const wrote = try q.drain(&sink);
        const got = sink.read.readStreaming(testing.io, &.{&buf}) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        for (buf[0..got]) |c| try testing.expectEqual(@as(u8, 'x'), c);
        delivered += got;
        if (wrote == 0 and got == 0) break;
    }
    try testing.expectEqual(@as(usize, 0), q.pending());
    try testing.expectEqual(composed * frame.len, delivered);
}
