//! A read-only frame snapshot over TCP, so a bench or an external tool can
//! inspect a live loop without a pty.
//!
//! The protocol is one line: send a line whose first word is `GET`, read one
//! JSON line back. `publish` copies the newest frame into a fixed ring in
//! constant time and allocates nothing, so it is safe to call from the loop
//! thread while a background task answers clients.
//!
//! Every operation takes the `std.Io` it needs rather than holding one: `start`
//! binds and spawns on the `io` it is given, and `stop` cancels and joins the
//! serving task on the `io` it is given. That `io` must stay valid until `stop`
//! returns. Cancelling elsewhere does not reach this endpoint: `stop` is the
//! only way to end serving, and it is safe to call more than once.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const Watchdog = @import("watchdog.zig").Watchdog;

/// One frame's state. Fixed size, so the server can copy it into the ring
/// without allocating and a caller may publish a stack value.
pub const Snapshot = struct {
    /// Capacity of `status`, in bytes.
    pub const status_capacity = 64;

    /// Frame number, stamped by the publisher (a driver counts from 0).
    frame: u64 = 0,
    /// Monotonic instant the frame was published, in nanoseconds
    /// (`std.Io.Timestamp.nanoseconds`).
    at_ns: i96 = 0,
    /// Frame geometry.
    rows: u16 = 0,
    cols: u16 = 0,
    /// Cells the frame changed, i.e. the render damage.
    dirty_cells: u32 = 0,
    /// Short status text (tool, mode, error kind), NUL padded.
    status: [status_capacity]u8 = @splat(0),

    /// Copy `text` into `status`, truncated at `status_capacity` bytes. The
    /// tail is cleared, so a shorter text never inherits a longer one.
    pub fn setStatus(self: *Snapshot, text: []const u8) void {
        const n = @min(text.len, status_capacity);
        @memcpy(self.status[0..n], text[0..n]);
        @memset(self.status[n..], 0);
    }

    /// The status text: bytes up to the first NUL, borrowed from `self`.
    pub fn statusText(self: *const Snapshot) []const u8 {
        return std.mem.sliceTo(&self.status, 0);
    }
};

/// Write the protocol's single-line JSON body for `snap`, newline included:
/// `{"frame":..,"at_ns":..,"rows":..,"cols":..,"dirty_cells":..,"status":".."}`.
/// Never allocates. `status` is escaped, so the body stays one JSON line.
pub fn writeSnapshotLine(w: *Io.Writer, snap: Snapshot) Io.Writer.Error!void {
    return w.print(
        "{{\"frame\":{d},\"at_ns\":{d},\"rows\":{d},\"cols\":{d}," ++
            "\"dirty_cells\":{d},\"status\":{f}}}\n",
        .{
            snap.frame,
            snap.at_ns,
            snap.rows,
            snap.cols,
            snap.dirty_cells,
            JsonString{ .text = snap.statusText() },
        },
    );
}

/// JSON string quoting: escapes `"`, `\`, and every C0 byte as `\u00xx`.
/// Bytes >= 0x20 pass through, so multi-byte UTF-8 survives verbatim.
/// `format` is reached from `std.Io.Writer`'s `{f}` path, so it stays
/// `pub` and the type is part of this module's API: a caller writing
/// JSON gets the same escaping as the snapshot line.
pub const JsonString = struct {
    /// The bytes to quote, borrowed for the duration of the `format` call.
    text: []const u8,

    pub fn format(self: JsonString, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeByte('"');
        for (self.text) |b| switch (b) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            0...0x1f => try w.print("\\u00{x:0>2}", .{b}),
            else => try w.writeByte(b),
        };
        try w.writeByte('"');
    }
};

/// A tiny test-and-test-and-set spin lock. Zig 0.16 has no `std.Thread.Mutex`
/// (only `std.Io.Mutex`, which would force an `io` parameter into `publish`),
/// and the locked section here is one bounded struct copy: the uncontended
/// path is one atomic swap, and a contended `publish` spins for at most the
/// length of that copy.
const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        while (self.locked.swap(true, .acquire)) {
            while (self.locked.load(.monotonic)) std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

/// A read-only inspector endpoint for a live loop. `publish` copies a frame
/// into a fixed ring (`ring_capacity`); a background task accepts one TCP
/// connection at a time and answers it with the newest frame. Serving is off
/// until `start`, and `publish` works without a listener.
pub const Server = struct {
    /// Frames retained for inspection; the oldest frame is dropped once a new
    /// one arrives at capacity. 64 frames are about one second at 60 Hz.
    pub const ring_capacity = 64;
    /// Socket read/write buffer. It bounds one request line: a longer line is
    /// rejected, never buffered. Responses stream through it as they are
    /// written.
    pub const io_buffer_capacity = 256;

    /// Parsing the address or allocating the ring failed.
    pub const InitError = net.IpAddress.ParseLiteralError || std.mem.Allocator.Error;
    /// Binding, listening, or spawning the serving task failed.
    pub const StartError = net.IpAddress.ListenError || Io.ConcurrentError || error{AlreadyStarted};

    /// The allocator the ring was taken from; stored, never released here.
    gpa: std.mem.Allocator,
    /// The parsed address `start` binds. Kept so a restart rebinds the same
    /// endpoint, port 0 included.
    address: net.IpAddress,
    /// The bound listener while serving; null before `start` and after `stop`.
    listener: ?net.Server = null,
    /// The group running the serving task. `stop` cancels and joins it.
    task: Io.Group = .init,
    /// Set by `stop` before it cancels the task. A cancelation point inside
    /// the in-flight read or write reports a plain client error, so the task
    /// consults this flag to tell "stop" from "the client left".
    stopping: std.atomic.Value(bool) = .init(false),
    /// Guards the ring and its counters. Held for one bounded struct copy, so
    /// `publish` stays allocation-free; it is not a general-purpose lock and
    /// must not be taken by anything else.
    mutex: SpinLock = .{},
    /// The frame ring, allocated by `init` and freed by `deinit`. Every
    /// element is a fixed-size value, so publishing copies and never
    /// allocates.
    ring: []Snapshot,
    /// Index in `ring` of the oldest retained frame.
    start_index: usize = 0,
    /// How many slots `ring` holds frames in, at most `ring_capacity`.
    retained: usize = 0,
    /// How many frames have been published since `init`, including the ones
    /// the ring has already dropped.
    published: u64 = 0,

    /// Parse `address` (`"127.0.0.1:0"` for an ephemeral loopback port) and
    /// allocate the frame ring. Does not touch the network; `start` binds.
    /// The server borrows `gpa` until `deinit`.
    pub fn init(gpa: std.mem.Allocator, address: []const u8) InitError!Server {
        const ring = try gpa.alloc(Snapshot, ring_capacity);
        errdefer gpa.free(ring);
        return .{ .gpa = gpa, .address = try net.IpAddress.parseLiteral(address), .ring = ring };
    }

    /// Free the ring. `stop` must have joined the serving task first.
    /// Debug and ReleaseSafe assert that precondition; ReleaseFast and ReleaseSmall
    /// do not validate it. The server is unusable afterward; disposal is exactly once.
    pub fn deinit(self: *Server) void {
        std.debug.assert(self.listener == null);
        self.gpa.free(self.ring);
        self.* = undefined;
    }

    /// Bind and listen on `address`, then serve in the background. Never
    /// blocks the caller; the serving task answers one connection at a time
    /// and a client that connects without sending holds it until `stop`.
    /// A server may be started again after `stop`.
    pub fn start(self: *Server, io: Io) StartError!void {
        if (self.listener != null) return error.AlreadyStarted;
        self.stopping.store(false, .release);
        const listener = try self.address.listen(io, .{});
        errdefer listener.socket.close(io);
        try self.task.concurrent(io, serveLoop, .{ io, self, listener });
        self.listener = listener;
    }

    /// Cancel the serving task, wait for it, and close the listener.
    /// Idempotent, never fails, safe in `defer` — declare `defer self.stop(io)`
    /// after `defer self.deinit()` so `deinit` runs last.
    pub fn stop(self: *Server, io: Io) void {
        self.stopping.store(true, .release);
        self.task.cancel(io);
        self.task.await(io) catch |err| switch (err) {
            // Expected: `cancel` above asked the serving task to stop, and
            // the task was parked in `accept` or in a socket read.
            error.Canceled => {},
        };
        if (self.listener) |*listener| {
            listener.deinit(io);
            self.listener = null;
        }
    }

    /// Publish one frame: O(1) and allocation-free, it copies `snapshot` into
    /// the ring under a short lock and never touches the socket. Safe before
    /// `start` and after `stop`.
    pub fn publish(self: *Server, snapshot: Snapshot) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.ring[(self.start_index + self.retained) % ring_capacity] = snapshot;
        if (self.retained == ring_capacity) {
            self.start_index = (self.start_index + 1) % ring_capacity;
        } else {
            self.retained += 1;
        }
        self.published += 1;
    }

    /// Frames still retained (at most `ring_capacity`).
    pub fn len(self: *Server) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.retained;
    }

    /// The `i`-th retained frame, 0 = oldest; null when `i` was dropped.
    pub fn at(self: *Server, i: usize) ?Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (i >= self.retained) return null;
        return self.ring[(self.start_index + i) % ring_capacity];
    }

    /// The newest retained frame; null before the first `publish`.
    pub fn latest(self: *Server) ?Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.retained == 0) return null;
        return self.ring[(self.start_index + self.retained - 1) % ring_capacity];
    }

    /// Total frames published since `init`.
    pub fn publishedCount(self: *Server) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.published;
    }

    /// The TCP port the listener bound; 0 before `start` and after `stop`.
    pub fn boundPort(self: *const Server) u16 {
        const listener = self.listener orelse return 0;
        return listener.socket.address.getPort();
    }

    /// The background task: accept one connection at a time and answer it.
    /// Returns when `stop` cancels it or the listener dies.
    fn serveLoop(io: Io, self: *Server, listener_in: net.Server) Io.Cancelable!void {
        // The task uses its own copy, so `stop` can clear `self.listener`
        // without racing this loop.
        var listener = listener_in;
        var read_buffer: [io_buffer_capacity]u8 = undefined;
        var write_buffer: [io_buffer_capacity]u8 = undefined;
        while (true) {
            const stream = listener.accept(io) catch |err| switch (err) {
                // `stop` cancelled this task while it waited, or the
                // listener was closed; the endpoint is done either way.
                error.Canceled, error.SocketNotListening => return,
                // A queued client disconnected before it was accepted; the
                // listener is still healthy.
                error.ConnectionAborted => continue,
                // Any other accept failure is fatal for the endpoint: stop
                // serving rather than spin on a broken listener.
                else => return,
            };
            defer stream.close(io);
            self.answer(io, stream, &read_buffer, &write_buffer) catch |err| switch (err) {
                error.ClientGone => {
                    // A cancelation point in the read or write consumed the
                    // cancelation request, so consult `stopping` to tell a
                    // forced stop from a client that simply left.
                    if (self.stopping.load(.acquire)) return;
                    continue;
                },
                error.Canceled => return,
            };
        }
    }

    const AnswerError = error{ClientGone} || Io.Cancelable;

    /// One request/response exchange. `error.ClientGone` means the exchange
    /// could not be completed: the peer closed, or the request line exceeded
    /// `io_buffer_capacity` (answered with `ERR request-too-long`).
    fn answer(
        self: *Server,
        io: Io,
        stream: net.Stream,
        read_buffer: []u8,
        write_buffer: []u8,
    ) AnswerError!void {
        var reader = stream.reader(io, read_buffer);
        var writer = stream.writer(io, write_buffer);
        const w = &writer.interface;

        const request = reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                try reply(w, "ERR request-too-long\n");
                return error.ClientGone;
            },
            error.EndOfStream, error.ReadFailed => return error.ClientGone,
        };

        // The first word of the request line; `GET`, `GET /frame`, and
        // `GET /frame HTTP/1.1` (from a CRLF client) all request the frame.
        const verb = std.mem.trim(u8, std.mem.sliceTo(request, ' '), " \t\r");
        if (!std.mem.eql(u8, verb, "GET")) {
            try reply(w, "ERR unknown-request\n");
        } else if (self.latest()) |snap| {
            writeSnapshotLine(w, snap) catch return error.ClientGone;
            w.flush() catch return error.ClientGone;
        } else {
            try reply(w, "ERR no-frame\n");
        }

        // Tell the client the line is complete; the caller's close ends it.
        stream.shutdown(io, .send) catch |err| switch (err) {
            // The peer is gone; the close below still reclaims the socket.
            error.ConnectionAborted,
            error.ConnectionResetByPeer,
            error.SystemResources,
            error.SocketUnconnected,
            error.NetworkDown,
            error.Unexpected,
            => {},
            error.Canceled => return error.Canceled,
        };
    }

    /// Write `line` and flush it; `error.ClientGone` when the peer is gone.
    fn reply(w: *Io.Writer, line: []const u8) AnswerError!void {
        w.writeAll(line) catch return error.ClientGone;
        w.flush() catch return error.ClientGone;
    }
};

/// Headless live-loop driver: runs `frame` at a fixed cadence with no
/// terminal and publishes every frame to `server`, so a bench can drive a real
/// loop and inspect it over TCP. The driver pings `watchdog` each iteration and
/// stops with `error.WatchdogTripped` when a frame or the inter-frame sleep
/// overruns the budget.
pub const Driver = struct {
    /// The endpoint frames are published to; it may or may not be started.
    server: *Server,
    /// Target interval between frames, in nanoseconds (0 = as fast as
    /// possible; each iteration still reaches a cancelation point).
    interval_ns: u64 = 16 * std.time.ns_per_ms,
    /// Stop after this many frames; 0 runs until cancelled.
    frames: u64 = 0,
    /// Liveness guard; it must outlast one frame plus `interval_ns`.
    watchdog: Watchdog = .{},
    /// Frames published so far (one `server.publish` per frame).
    count: u64 = 0,

    /// `error.Canceled` is the normal way out of an unbounded loop;
    /// `error.WatchdogTripped` means the loop overran its budget and the
    /// guilty frame is the last one published.
    pub const RunError = Io.Cancelable || error{WatchdogTripped};

    /// Run the loop. `frame` is called once per iteration with `ctx` and
    /// returns that frame's snapshot: the driver stamps `frame`, `at_ns`, and
    /// publishes it, the callback owns the rest. `frame` must be a function
    /// or function pointer; pass state through `ctx`. A callback that can
    /// fail (an App's headless render, say) records the failure in `ctx` and
    /// returns a snapshot describing it: `run` only ever stops on
    /// `error.Canceled` or a watchdog trip.
    /// The callback runs synchronously on the calling thread before publication.
    /// Keep `ctx` and anything it references live through `run`. It must not reenter
    /// this driver or dispose its server. `Server.publish` remains safe, but any
    /// callback publication is an additional snapshot, not the driver's one frame.
    pub fn run(self: *Driver, io: Io, ctx: anytype, frame: anytype) RunError!void {
        while (self.frames == 0 or self.count < self.frames) {
            // The loop is alive: a frame begins.
            self.watchdog.ping(.now(io, .awake));
            var snap: Snapshot = @call(.auto, frame, .{ctx});
            const frame_end = std.Io.Timestamp.now(io, .awake);
            snap.frame = self.count;
            snap.at_ns = frame_end.nanoseconds;
            self.server.publish(snap);
            self.count += 1;
            // A frame callback that blocked (a stuck probe, a reader) shows
            // up here: the frame is published, and the ping is older than the
            // budget, so the loop stops with the guilty frame in the ring.
            if (self.watchdog.tripped(frame_end)) return error.WatchdogTripped;
            // The loop is alive: it is about to idle until the next frame.
            self.watchdog.ping(frame_end);
            try Io.sleep(io, .fromNanoseconds(self.interval_ns), .awake);
            // An inter-frame sleep that overran (a blocked reader stalling
            // the loop) shows up here.
            if (self.watchdog.tripped(.now(io, .awake))) return error.WatchdogTripped;
        }
    }

    /// Frames published by this driver since initialization, across `run` calls:
    /// one driver `server.publish` per frame; callback publications are not counted.
    pub fn frameCount(self: *const Driver) u64 {
        return self.count;
    }
};

test {
    std.testing.refAllDecls(@This());
}

const testing = std.testing;

test "snapshot: status is NUL padded, truncating at its capacity" {
    var snap: Snapshot = .{};
    try testing.expectEqual(@as(usize, 0), snap.statusText().len);

    snap.setStatus("idle");
    try testing.expectEqualStrings("idle", snap.statusText());
    try testing.expectEqual(@as(usize, 4), snap.statusText().len);

    const exact = "x" ** Snapshot.status_capacity;
    snap.setStatus(exact);
    try testing.expectEqual(@as(usize, Snapshot.status_capacity), snap.statusText().len);

    // A shorter text must clear the tail of a longer one.
    snap.setStatus("run");
    try testing.expectEqualStrings("run", snap.statusText());
}

test "snapshot: a status longer than the capacity truncates" {
    var snap: Snapshot = .{};
    snap.setStatus("y" ** (Snapshot.status_capacity + 3));
    try testing.expectEqual(@as(usize, Snapshot.status_capacity), snap.statusText().len);
    try testing.expectEqual(@as(u8, 'y'), snap.status[Snapshot.status_capacity - 1]);
}

test "protocol: the response line is one escaped JSON line" {
    var snap: Snapshot = .{ .frame = 7, .at_ns = 1234, .rows = 24, .cols = 80, .dirty_cells = 3 };
    snap.setStatus("idle");
    var buf: [io_response_capacity]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    try writeSnapshotLine(&w, snap);
    try testing.expectEqualStrings(
        "{\"frame\":7,\"at_ns\":1234,\"rows\":24,\"cols\":80," ++
            "\"dirty_cells\":3,\"status\":\"idle\"}\n",
        w.buffered(),
    );

    // A status carrying quotes, a backslash, and control bytes must not break
    // the line: it stays a single line of valid JSON.
    var tricky: Snapshot = .{ .frame = 1 };
    tricky.setStatus("a\"b\\c\x07\n");
    var tbuf: [io_response_capacity]u8 = undefined;
    var tw = Io.Writer.fixed(&tbuf);
    try writeSnapshotLine(&tw, tricky);
    const line = tw.buffered();
    try testing.expectEqualStrings(
        "{\"frame\":1,\"at_ns\":0,\"rows\":0,\"cols\":0,\"dirty_cells\":0," ++
            "\"status\":\"a\\\"b\\\\c\\u0007\\u000a\"}\n",
        line,
    );
    for (line[0 .. line.len - 1]) |b| {
        try testing.expect(b >= 0x20); // no raw control byte inside the line
    }
    try testing.expectEqual(@as(u8, '\n'), line[line.len - 1]);
}

/// Room for the longest line `writeSnapshotLine` can emit: a full status of
/// control bytes expands to six bytes each.
const io_response_capacity = 160 + 6 * Snapshot.status_capacity;

test "server: latest is null and len is zero before the first publish" {
    var server = try Server.init(testing.allocator, "127.0.0.1:0");
    defer server.deinit();
    try testing.expect(server.latest() == null);
    try testing.expectEqual(@as(usize, 0), server.len());
    try testing.expect(server.at(0) == null);
    try testing.expectEqual(@as(u64, 0), server.publishedCount());
    try testing.expectEqual(@as(u16, 0), server.boundPort());
}

test "server: the ring keeps the newest frames and drops the oldest" {
    var server = try Server.init(testing.allocator, "127.0.0.1:0");
    defer server.deinit();

    for (0..3) |i| server.publish(.{ .frame = i });
    try testing.expectEqual(@as(usize, 3), server.len());
    try testing.expectEqual(@as(u64, 0), server.at(0).?.frame);
    try testing.expectEqual(@as(u64, 2), server.latest().?.frame);
    try testing.expect(server.at(3) == null); // stale index

    // Overflow the ring: the oldest frames fall out, the bound holds.
    for (3..Server.ring_capacity + 2) |i| server.publish(.{ .frame = i });
    try testing.expectEqual(@as(usize, Server.ring_capacity), server.len());
    try testing.expectEqual(@as(u64, 2), server.at(0).?.frame);
    try testing.expectEqual(@as(u64, Server.ring_capacity + 1), server.latest().?.frame);
    try testing.expectEqual(@as(u64, Server.ring_capacity + 2), server.publishedCount());
}

test "server: init rejects malformed addresses" {
    try testing.expectError(error.InvalidAddress, Server.init(testing.allocator, "not-an-address"));
    try testing.expectError(error.InvalidPort, Server.init(testing.allocator, "127.0.0.1:70000"));

    var server = try Server.init(testing.allocator, "127.0.0.1:0");
    defer server.deinit();
    try testing.expectEqual(@as(u16, 0), server.address.getPort());
}

test "server: serves the published snapshot over a loopback socket" {
    var server = try Server.init(testing.allocator, "127.0.0.1:0");
    defer server.deinit();
    var snap: Snapshot = .{ .frame = 7, .rows = 24, .cols = 80, .dirty_cells = 12 };
    snap.setStatus("bench");
    server.publish(snap);

    try server.start(testing.io);
    defer server.stop(testing.io);
    const port = server.boundPort();
    try testing.expect(port != 0);

    // `GET` returns the newest frame as one JSON line.
    try expectResponse(port, "GET /frame HTTP/1.1\r\n", "{\"frame\":7,\"at_ns\":0," ++
        "\"rows\":24,\"cols\":80,\"dirty_cells\":12,\"status\":\"bench\"}");

    // A newer publish is what the next connection sees.
    var newer: Snapshot = .{ .frame = 8 };
    newer.setStatus("after");
    server.publish(newer);
    try expectResponse(port, "GET\n", "{\"frame\":8,\"at_ns\":0,\"rows\":0,\"cols\":0," ++
        "\"dirty_cells\":0,\"status\":\"after\"}");

    // Any other first word is refused, and the endpoint keeps serving.
    try expectResponse(port, "POST /\n", "ERR unknown-request");
    try expectResponse(port, "GET\n", "{\"frame\":8,\"at_ns\":0,\"rows\":0,\"cols\":0," ++
        "\"dirty_cells\":0,\"status\":\"after\"}");

    server.stop(testing.io);
    try testing.expectEqual(@as(u16, 0), server.boundPort());
    // A closed listener refuses new connections.
    const addr = try net.IpAddress.parse("127.0.0.1", port);
    const refused = addr.connect(testing.io, .{ .mode = .stream });
    try testing.expectError(error.ConnectionRefused, refused);

    // `publish` keeps working without a listener, and `stop` is idempotent
    // (the `defer` above runs it a second time).
    server.publish(.{ .frame = 99 });
    try testing.expectEqual(@as(u64, 99), server.latest().?.frame);
}

test "server: answers ERR no-frame before the first publish" {
    var server = try Server.init(testing.allocator, "127.0.0.1:0");
    defer server.deinit();
    defer server.stop(testing.io);
    try server.start(testing.io);

    try expectResponse(server.boundPort(), "GET\n", "ERR no-frame");
}

test "server: a client that leaves mid-request does not kill the endpoint" {
    var server = try Server.init(testing.allocator, "127.0.0.1:0");
    defer server.deinit();
    defer server.stop(testing.io);
    try server.start(testing.io);
    const port = server.boundPort();

    // Connect and vanish without sending a line: the serving task sees the
    // end of the stream and must keep accepting.
    const rude = try (try net.IpAddress.parse("127.0.0.1", port)).connect(
        testing.io,
        .{ .mode = .stream },
    );
    rude.close(testing.io);

    try expectResponse(port, "GET\n", "ERR no-frame");
}

test "server: rejects a request line longer than its buffer" {
    var server = try Server.init(testing.allocator, "127.0.0.1:0");
    defer server.deinit();
    defer server.stop(testing.io);
    server.publish(.{ .frame = 1 });
    try server.start(testing.io);
    const port = server.boundPort();
    const addr = try net.IpAddress.parse("127.0.0.1", port);

    // One line longer than the reader buffer, with no newline in it.
    const stream = try addr.connect(testing.io, .{ .mode = .stream });
    defer stream.close(testing.io);
    var text: [2 * Server.io_buffer_capacity + 1]u8 = undefined;
    @memset(&text, 'x');
    text[text.len - 1] = '\n';
    var wbuf: [Server.io_buffer_capacity]u8 = undefined;
    var writer = stream.writer(testing.io, &wbuf);
    try writer.interface.writeAll(&text);
    try writer.interface.flush();
    var rbuf: [Server.io_buffer_capacity]u8 = undefined;
    var reader = stream.reader(testing.io, &rbuf);
    const line = try reader.interface.takeDelimiterExclusive('\n');
    try testing.expectEqualStrings("ERR request-too-long", line);

    // The endpoint survives the oversized request.
    try expectResponse(port, "GET\n", "{\"frame\":1,\"at_ns\":0,\"rows\":0,\"cols\":0," ++
        "\"dirty_cells\":0,\"status\":\"\"}");
}

test "server: the endpoint serves a headless loop's published frames" {
    var server = try Server.init(testing.allocator, "127.0.0.1:0");
    defer server.deinit();
    defer server.stop(testing.io);
    try server.start(testing.io);
    const port = server.boundPort();

    // A real headless loop: three frames, one millisecond apart, on the real
    // monotonic clock.
    var source: TestFrame = .{};
    var driver: Driver = .{
        .server = &server,
        .interval_ns = std.time.ns_per_ms,
        .frames = 3,
    };
    try driver.run(testing.io, &source, TestFrame.next);
    try testing.expectEqual(@as(u64, 3), driver.frameCount());

    // The endpoint serves the loop's last frame, with the driver's stamped
    // frame number and clock reading (not a hand-made snapshot).
    var buffer: [Server.io_buffer_capacity]u8 = undefined;
    const line = try requestLine(port, "GET /frame\n", &buffer);
    try testing.expectEqual(@as(u64, 2), try parsedFrame(line));
    try testing.expect(std.mem.indexOf(u8, line, "\"rows\":6") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"dirty_cells\":4") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"status\":\"ok\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"at_ns\":0") == null); // stamped
}

test "server: a client reads frames while the headless loop is running" {
    var server = try Server.init(testing.allocator, "127.0.0.1:0");
    defer server.deinit();
    defer server.stop(testing.io);
    try server.start(testing.io);
    const port = server.boundPort();

    var source: TestFrame = .{};
    var driver: Driver = .{
        .server = &server,
        .interval_ns = std.time.ns_per_ms,
        .frames = 0, // until cancelled
    };
    var future = try testing.io.concurrent(Drive.drive, .{ &driver, &source });
    defer {
        future.cancel(testing.io) catch |err| switch (err) {
            error.Canceled => {},
        };
    }

    // Wait for the loop to publish, then read it mid-run.
    var spins: usize = 0;
    while (server.publishedCount() < 2 and spins < 2000) : (spins += 1) {
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expect(server.publishedCount() >= 2);

    var buffer: [Server.io_buffer_capacity]u8 = undefined;
    const line = try requestLine(port, "GET\n", &buffer);
    // The frame read over TCP is one this run published.
    try testing.expect(try parsedFrame(line) < driver.frameCount());
    try testing.expect(std.mem.indexOf(u8, line, "\"status\":\"ok\"") != null);
}

/// The `frame` field of a response line: the number after `"frame":`.
fn parsedFrame(line: []const u8) !u64 {
    const key = "\"frame\":";
    const key_at = std.mem.indexOf(u8, line, key) orelse return error.MissingFrame;
    const rest = line[key_at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ',') orelse return rest.len;
    return std.fmt.parseInt(u64, rest[0..end], 10);
}

/// Connect to `port`, send `request`, and read one response line into
/// `buffer` (returned as a slice of it).
fn requestLine(port: u16, request: []const u8, buffer: []u8) ![]const u8 {
    const addr = try net.IpAddress.parse("127.0.0.1", port);
    const stream = try addr.connect(testing.io, .{ .mode = .stream });
    defer stream.close(testing.io);

    var wbuf: [Server.io_buffer_capacity]u8 = undefined;
    var writer = stream.writer(testing.io, &wbuf);
    try writer.interface.writeAll(request);
    try writer.interface.flush();

    var reader = stream.reader(testing.io, buffer);
    return reader.interface.takeDelimiterExclusive('\n');
}

/// Connect to `port`, send `request`, and expect one response line.
fn expectResponse(port: u16, request: []const u8, expected: []const u8) !void {
    var buffer: [Server.io_buffer_capacity]u8 = undefined;
    const line = try requestLine(port, request, &buffer);
    try testing.expectEqualStrings(expected, line);
}

/// A snapshot source for the driver tests: fills every field the driver does
/// not stamp, so the passthrough is observable.
const TestFrame = struct {
    rows: u16 = 6,
    cols: u16 = 30,
    dirty_cells: u32 = 4,

    fn next(self: *TestFrame) Snapshot {
        var snap: Snapshot = .{
            .rows = self.rows,
            .cols = self.cols,
            .dirty_cells = self.dirty_cells,
        };
        snap.setStatus("ok");
        return snap;
    }
};

test "driver: a bounded headless loop publishes every frame" {
    var server = try Server.init(testing.allocator, "127.0.0.1:0");
    defer server.deinit();
    var source: TestFrame = .{};
    var driver: Driver = .{ .server = &server, .interval_ns = 0, .frames = 3 };

    try driver.run(testing.io, &source, TestFrame.next);

    try testing.expectEqual(@as(u64, 3), driver.frameCount());
    try testing.expectEqual(@as(usize, 3), server.len());
    try testing.expectEqual(@as(u64, 0), server.at(0).?.frame);
    const last = server.latest().?;
    try testing.expectEqual(@as(u64, 2), last.frame);
    try testing.expectEqual(@as(u16, 6), last.rows);
    try testing.expectEqual(@as(u16, 30), last.cols);
    try testing.expectEqual(@as(u32, 4), last.dirty_cells);
    try testing.expectEqualStrings("ok", last.statusText());
    try testing.expect(last.at_ns != 0);
    // The loop pings its watchdog and stays inside the budget.
    try testing.expect(driver.watchdog.armed());
    try testing.expect(!driver.watchdog.tripped(.now(testing.io, .awake)));
}

/// A frame callback that blocks longer than the watchdog budget.
fn slowFrame(ctx: *TestFrame) Snapshot {
    const budget_blowing = std.Io.Duration.fromNanoseconds(2 * std.time.ns_per_ms);
    std.Io.sleep(testing.io, budget_blowing, .awake) catch |err| switch (err) {
        // Nothing cancels this test's own sleep; its only error is Canceled.
        error.Canceled => {},
    };
    return ctx.next();
}

test "driver: a frame that overruns the budget trips the watchdog" {
    var server = try Server.init(testing.allocator, "127.0.0.1:0");
    defer server.deinit();
    var source: TestFrame = .{};
    var driver: Driver = .{
        .server = &server,
        .interval_ns = 0,
        .frames = 1,
        .watchdog = Watchdog.init(1), // one nanosecond: any real frame overruns
    };

    try testing.expectError(error.WatchdogTripped, driver.run(testing.io, &source, slowFrame));
    // The guilty frame is published and counted, so an inspector can still
    // see the frame that overran; the loop then stops.
    try testing.expectEqual(@as(u64, 1), driver.frameCount());
    try testing.expectEqual(@as(usize, 1), server.len());
    try testing.expectEqual(@as(u64, 0), server.latest().?.frame);
}

test "driver: an unbounded loop stops when cancelled" {
    var server = try Server.init(testing.allocator, "127.0.0.1:0");
    defer server.deinit();
    var source: TestFrame = .{};
    var driver: Driver = .{
        .server = &server,
        .interval_ns = std.time.ns_per_ms,
        .frames = 0, // run until cancelled
    };

    var future = try testing.io.concurrent(Drive.drive, .{ &driver, &source });
    try testing.io.sleep(.fromNanoseconds(20 * std.time.ns_per_ms), .awake);
    defer {
        // Cancel even if the loop stopped on its own, so the future is
        // always reaped.
        future.cancel(testing.io) catch |err| switch (err) {
            error.Canceled => {},
        };
    }
    try testing.expect(driver.frameCount() >= 1);
    try testing.expect(server.len() >= 1);
}

/// `Driver.run` wrapper with the shape `Io.concurrent` requires.
const Drive = struct {
    fn drive(driver: *Driver, ctx: *TestFrame) Io.Cancelable!void {
        driver.run(testing.io, ctx, TestFrame.next) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // The budget is the 2 s default here, so a trip means the test
            // itself is broken; fail loudly rather than mask it as a cancel.
            error.WatchdogTripped => std.debug.panic("driver tripped its watchdog", .{}),
        };
    }
};
