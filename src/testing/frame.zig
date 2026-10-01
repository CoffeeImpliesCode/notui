//! Golden-frame harness: drive the real render pipeline headless.
//!
//! A `Harness` owns two `std.Io` pipes — scripted input (a `feed` writer
//! end plus the read end an input decoder pulls from) and captured output
//! (a write end the renderer emits frames into, plus a read end the harness
//! drains). No pty, no `/dev/tty`, no raw mode: the whole pipeline runs
//! against ordinary pipes, so it works in a unit test or a bench step.
//!
//! A `Session` wires a `Region` to the harness: `feed` bytes go through the
//! real `Parser` (via `Reader`, so split sequences reassemble), decoded
//! events reach the model, the model draws into the region band, and the
//! region renders through the output pipe. Every render's bytes are
//! captured as a frame, so a test asserts an EXACT byte stream.
//!
//! ```
//! var session = try Session.init(testing.io, testing.allocator, .{ .region = .{ .height = 1 } });
//! defer session.deinit();
//! const bytes = try session.run(&model, &[_]Step{.{ .input = "hi", .frames = 1 }});
//! try testing.expectEqualStrings("\x1b..", bytes);
//! ```
//!
//! `App(Model)` is deliberately NOT driven here. `App` renders through its
//! own `Tty.writer()` and reads through the same `Tty` fd, so it needs a
//! duplex socketpair plus its private `startTty`/`processInit` wiring; the
//! two-pipe harness cannot stand in for that. `Region` + `Parser` + `Buffer`
//! is the driven path (ROADMAP F1), and `Harness.inputTty()` hands out the
//! input side for a caller that wants to wire its own loop.
//!
//! Record mode (`Harness.recordToDir`) writes each frame's bytes to
//! `<dir>/frame-NNNN.escape` so a golden can be regenerated deliberately.
//! An existing golden is NEVER overwritten silently: the file is created
//! with `O_EXCL` and an existing one fails with `error.GoldenExists` unless
//! the recorder was opened with `RecordOptions.overwrite = true`.
//!
//! Both pipes are non-blocking and neither side assumes a pipe capacity:
//! the output sink drains its read end whenever the write end fills (so a
//! frame larger than the kernel's capacity is captured whole), `feed`
//! refuses to block (`error.InputFull`), and `Session.run` feeds scripted
//! input in chunks it decodes between. Nothing here can hang.
//!
//! Frame path allocation: the pipes are fds, and the capture buffer plus
//! the frame index are the harness's own — `Session.init` pre-reserves
//! both, so up to 64 frames / 4 KiB of output allocates nothing per frame.

const std = @import("std");
const posix = std.posix;

const Buffer = @import("../buffer.zig").Buffer;
const Region = @import("../region.zig").Region;
const Event = @import("../event.zig").Event;
const Pos = @import("../event.zig").Pos;
const Key = @import("../Key.zig");
const Tty = @import("../tty.zig").Tty;
const Reader = @import("../input.zig").Reader;

/// A `std.Io.File` view over a raw descriptor (the repo's fd-backed
/// `Tty`/`Reader` test pattern).
fn fdFile(fd: posix.fd_t) std.Io.File {
    return .{ .handle = fd, .flags = .{ .nonblocking = true } };
}

/// Everything the harness itself can fail with: pipe and file errors from
/// the captures plus the record-mode refusals. Concretely declared — never
/// `anyerror`.
pub const Error = std.mem.Allocator.Error ||
    std.Io.Threaded.PipeError ||
    std.Io.Writer.Error ||
    std.Io.File.Writer.Error ||
    std.Io.File.OpenError ||
    std.Io.Dir.OpenError ||
    std.Io.Dir.CreateDirPathError ||
    std.Io.Dir.ReadFileAllocError ||
    posix.PollError ||
    posix.ReadError ||
    error{
        /// A golden file already exists and the recorder was opened
        /// without `overwrite` — a golden is never clobbered silently.
        GoldenExists,
        /// A record-mode call ran without `recordToDir` first.
        NotRecording,
        /// A generated golden name did not fit its formatting buffer.
        NameTooLong,
        /// `feed` was handed more bytes than the input pipe had room for.
        /// The harness never blocks; drain the input side (render a frame)
        /// and feed the rest.
        InputFull,
    };

/// The output writer the driven renderer writes frames to.
///
/// A plain file writer blocks once the pipe fills, and a frame can exceed
/// the kernel's pipe capacity (64 KiB by default on Linux, less under a
/// conservative budget; a 200x60 band already emits ~12 KiB). This sink
/// owns a NON-BLOCKING write end instead: whenever the pipe is full it
/// drains the read end into the capture and keeps writing, so a frame of
/// any size is captured whole and nothing can deadlock.
const Sink = struct {
    io: std.Io,
    /// Write end (non-blocking).
    out: std.Io.File,
    /// Read end (non-blocking), drained into `captured`.
    in: std.Io.File,
    gpa: std.mem.Allocator,
    captured: *std.ArrayListUnmanaged(u8),
    /// The real failure behind a `WriteFailed` reported to the renderer (an
    /// allocation failure while capturing, or a pipe error); null while
    /// healthy.
    err: ?Error = null,
    buffer: [4096]u8 = undefined,
    interface: std.Io.Writer = undefined,

    fn start(
        io: std.Io,
        out: std.Io.File,
        in: std.Io.File,
        gpa: std.mem.Allocator,
        captured: *std.ArrayListUnmanaged(u8),
    ) Sink {
        return .{
            .io = io,
            .out = out,
            .in = in,
            .gpa = gpa,
            .captured = captured,
            .interface = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
        };
    }

    /// Wire `buffer` into the interface and hand out the writer. The sink
    /// must already live at its final address (it self-references).
    fn attach(self: *Sink) *std.Io.Writer {
        self.interface.buffer = self.buffer[0..];
        return &self.interface;
    }

    /// Move every byte waiting in the pipe into the capture. Never blocks:
    /// `WouldBlock` means the pipe is empty.
    fn absorb(self: *Sink) Error!void {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = posix.read(self.in.handle, &buf) catch |err| switch (err) {
                error.WouldBlock => return,
                else => |e| return e,
            };
            // Zero means the write end closed: nothing more is coming. The
            // harness holds it for the whole session, so this is defensive.
            if (n == 0) return;
            try self.captured.appendSlice(self.gpa, buf[0..n]);
        }
    }

    /// Write every byte, draining the read end whenever the pipe is full.
    fn writeAll(self: *Sink, bytes: []const u8) std.Io.Writer.Error!usize {
        var off: usize = 0;
        while (off < bytes.len) {
            const one = [_][]const u8{bytes[off..]};
            const file = self.out;
            const io = self.io;
            const sent = std.Io.File.writeStreaming(file, io, &.{}, one[0..], 1);
            const n = sent catch |err| switch (err) {
                error.WouldBlock => {
                    const before = self.captured.items.len;
                    self.absorb() catch |e| {
                        self.err = e;
                        return error.WriteFailed;
                    };
                    // A full pipe always has bytes to read, so draining it
                    // makes progress. No progress means nothing can ever
                    // drain it again (the read end is gone): fail rather
                    // than spin on a full pipe forever.
                    if (self.captured.items.len == before) {
                        self.err = error.BrokenPipe;
                        return error.WriteFailed;
                    }
                    continue;
                },
                else => |e| {
                    self.err = e;
                    return error.WriteFailed;
                },
            };
            // A non-empty write never returns zero on a pipe; treat it as a
            // broken transport rather than spinning on `off`.
            if (n == 0) {
                self.err = error.BrokenPipe;
                return error.WriteFailed;
            }
            off += n;
        }
        return bytes.len;
    }

    /// Consume the writer's buffer, then each slice of `data`, then the last
    /// slice repeated `splat` times (zero when `splat` is zero). Everything
    /// is always written, so the writer's buffer is empty on return.
    fn drain(
        io_w: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *Sink = @alignCast(@fieldParentPtr("interface", io_w));
        const header = io_w.buffered();
        var total: usize = 0;
        total += try self.writeAll(header);
        for (data, 0..) |slice, idx| {
            // With `splat == 0` the last slice is the pattern, not payload.
            if (idx == data.len - 1 and splat == 0) continue;
            total += try self.writeAll(slice);
        }
        if (splat != 0) {
            const pattern = data[data.len - 1];
            var i: usize = 1; // already written once above
            while (i < splat) : (i += 1) total += try self.writeAll(pattern);
        }
        io_w.end = 0;
        return total - header.len;
    }
};

/// The two-pipe capture rig. Construct it, then either drive it by hand
/// (`feed`, `writer`, `outputBytes`) or hand it to a `Session`.
pub const Harness = struct {
    pub const RecordOptions = struct {
        /// Rewrite existing golden files. When false (the default) an
        /// existing golden fails with `error.GoldenExists`.
        overwrite: bool = false,
        /// Create the directory hierarchy when it does not exist.
        create: bool = true,
    };

    io: std.Io,
    gpa: std.mem.Allocator,

    /// Scripted terminal input: `feed` writes `in_w`, the driven input side
    /// reads `in_r`.
    in_r: std.Io.File,
    in_w: std.Io.File,
    /// Captured terminal output: the driven renderer writes `out_w` through
    /// `writer`, and the harness drains `out_r` into `captured`.
    out_r: std.Io.File,
    out_w: std.Io.File,

    /// Every byte drained from the output pipe so far.
    captured: std.ArrayListUnmanaged(u8) = .empty,

    /// Built on the first `writer()` call. It self-references its buffer,
    /// so the harness must not move afterwards (the `Tty.writer` rule).
    sink: ?Sink = null,

    /// Record mode: the open golden directory, the next frame index, and
    /// whether existing goldens may be rewritten.
    record_dir: ?std.Io.Dir = null,
    record_overwrite: bool = false,
    record_index: usize = 0,

    /// Create both pipes, non-blocking (`O_NONBLOCK`) and close-on-exec.
    /// Neither side may block, so nothing here can deadlock on a full pipe.
    pub fn init(io: std.Io, gpa: std.mem.Allocator) Error!Harness {
        const flags: posix.O = .{ .NONBLOCK = true, .CLOEXEC = true };
        const in_fds = try std.Io.Threaded.pipe2(flags);
        errdefer closeBoth(io, in_fds);
        const out_fds = try std.Io.Threaded.pipe2(flags);
        errdefer closeBoth(io, out_fds);
        return .{
            .io = io,
            .gpa = gpa,
            .in_r = fdFile(in_fds[0]),
            .in_w = fdFile(in_fds[1]),
            .out_r = fdFile(out_fds[0]),
            .out_w = fdFile(out_fds[1]),
        };
    }

    /// Close the pipes, the golden directory, and the capture.
    pub fn deinit(self: *Harness) void {
        if (self.record_dir) |d| d.close(self.io);
        self.captured.deinit(self.gpa);
        self.in_r.close(self.io);
        self.in_w.close(self.io);
        self.out_r.close(self.io);
        self.out_w.close(self.io);
        self.* = undefined;
    }

    /// Write raw terminal input bytes for the driven side to decode.
    ///
    /// Bounded, never blocking: the pipe write end is non-blocking, so a
    /// feed larger than the pipe's free space is refused with
    /// `error.InputFull` instead of stalling. A refused feed may have
    /// written a prefix, so drain the input side (render a frame, or read
    /// it) and feed the rest; `Session.run` does all of this for a
    /// scripted step of any size.
    pub fn feed(self: *Harness, bytes: []const u8) Error!void {
        if (bytes.len == 0) return;
        self.in_w.writeStreamingAll(self.io, bytes) catch |err| switch (err) {
            error.WouldBlock => return error.InputFull,
            else => return err,
        };
    }

    /// A `Tty` view over the input pipe's read end, for a `Reader` or a
    /// hand-wired loop. Non-owning: never `Tty.deinit` it (the harness owns
    /// the fd). `/dev/tty` is never opened and no signal handler is
    /// installed, so this is headless.
    pub fn inputTty(self: *Harness) Tty {
        return .{ .io = self.io, .fd = self.in_r };
    }

    /// The writer the driven renderer writes frames to. Built once; do not
    /// move the harness afterwards.
    pub fn writer(self: *Harness) *std.Io.Writer {
        if (self.sink == null) {
            self.sink = Sink.start(self.io, self.out_w, self.out_r, self.gpa, &self.captured);
        }
        return self.sink.?.attach();
    }

    /// The failure behind the last `WriteFailed` this sink reported to the
    /// renderer (an allocation failure while capturing, or a pipe error);
    /// null when the writer is healthy.
    pub fn sinkError(self: *const Harness) ?Error {
        const sink = self.sink orelse return null;
        return sink.err;
    }

    /// Flush buffered frame bytes into the output pipe, drain the pipe into
    /// the capture, and surface any failure the sink recorded.
    pub fn flush(self: *Harness) Error!void {
        try self.writer().flush();
        const sink = &self.sink.?;
        try sink.absorb();
        if (sink.err) |e| return e;
    }

    /// Everything the driven code has written so far. Flushes and drains
    /// first; the slice lives until the next frame appends bytes.
    pub fn outputBytes(self: *Harness) Error![]const u8 {
        try self.flush();
        return self.captured.items;
    }

    /// An owned copy of `outputBytes`, for a caller that must hold the
    /// stream across further frames. Caller frees.
    pub fn takeOutput(self: *Harness) Error![]u8 {
        try self.flush();
        return self.gpa.dupe(u8, self.captured.items);
    }

    /// Drop the captured bytes (draining first so nothing is lost).
    pub fn clear(self: *Harness) Error!void {
        try self.flush();
        self.captured.clearRetainingCapacity();
    }

    /// True while record mode is active.
    pub fn recording(self: *const Harness) bool {
        return self.record_dir != null;
    }

    /// Enter record mode: `recordFrame` writes `<path>/frame-NNNN.escape`.
    /// Re-opening resets the frame index, so re-recording an existing
    /// golden fails with `error.GoldenExists` unless `overwrite` is set.
    pub fn recordToDir(self: *Harness, path: []const u8, opts: RecordOptions) Error!void {
        if (self.record_dir) |d| d.close(self.io);
        self.record_dir = null;
        self.record_index = 0;
        self.record_overwrite = opts.overwrite;
        const cwd = std.Io.Dir.cwd();
        if (opts.create) try cwd.createDirPath(self.io, path);
        self.record_dir = try cwd.openDir(self.io, path, .{});
    }

    /// Leave record mode.
    pub fn stopRecording(self: *Harness) void {
        if (self.record_dir) |d| d.close(self.io);
        self.record_dir = null;
    }

    /// Write one frame's bytes to `<dir>/frame-NNNN.escape` and advance the
    /// index. Refuses to clobber an existing golden unless the recorder was
    /// opened with `overwrite`.
    pub fn recordFrame(self: *Harness, bytes: []const u8) Error!void {
        var name_buf: [48]u8 = undefined;
        const name = std.fmt.bufPrint(
            &name_buf,
            "frame-{d:0>4}.escape",
            .{self.record_index},
        ) catch return error.NameTooLong;
        self.record_index += 1;
        return self.recordNamed(name, bytes);
    }

    /// Write `bytes` to `<dir>/<name>`; `error.GoldenExists` when the file
    /// is already there and `overwrite` is off.
    pub fn recordNamed(self: *Harness, name: []const u8, bytes: []const u8) Error!void {
        const dir = self.record_dir orelse return error.NotRecording;
        var file = dir.createFile(self.io, name, .{
            .truncate = self.record_overwrite,
            .exclusive = !self.record_overwrite,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => return error.GoldenExists,
            else => return err,
        };
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, bytes);
    }

    /// Read a recorded golden back, for a test that compares a live frame
    /// against it. Caller owns the result.
    pub fn readGolden(
        self: *Harness,
        name: []const u8,
        gpa: std.mem.Allocator,
    ) Error![]u8 {
        const dir = self.record_dir orelse return error.NotRecording;
        return dir.readFileAlloc(self.io, name, gpa, .limited(1 << 20));
    }

    fn closeBoth(io: std.Io, fds: [2]posix.fd_t) void {
        fdFile(fds[0]).close(io);
        fdFile(fds[1]).close(io);
    }
};

/// One scripted step: raw input bytes, then a number of frames.
pub const Step = struct {
    /// Raw terminal input bytes fed before the step's frames.
    input: []const u8 = "",
    /// Frames to render for this step. Each frame pumps every available
    /// input event, draws once, and renders once.
    frames: u32 = 1,
};

/// A `Region` driven end to end through a `Harness`.
///
/// Self-referential (the lazily built sink and `Reader` point into the
/// session), so a session must not be copied or moved after its first
/// `frame`. Build it in place: `var session = try Session.init(...)`.
pub const Session = struct {
    /// Input bytes per `feed` inside `run`. Small enough to fit any pipe
    /// capacity, so a scripted step of any size is fed in bounded pieces.
    const feed_chunk = 1024;

    pub const Options = struct {
        /// Terminal columns the band is captured at — the width the golden
        /// bytes are written against.
        width: u16 = 80,
        /// The band's own options, handed to `Region.init` verbatim.
        /// Carrying the type instead of mirroring its fields keeps this
        /// harness out of lockstep with `Region.Options` changes.
        region: Region.Options = .{ .height = 3 },
        /// Answer the region's CPR query with this position. Null leaves
        /// the query unanswered. A real terminal always answers, so the
        /// bytes a session captures are the terminal's view only with a
        /// reply configured.
        cpr: ?Pos = null,
    };

    /// Byte span of one rendered frame inside the harness capture.
    pub const Frame = struct { start: usize, end: usize };

    gpa: std.mem.Allocator,
    opts: Options,

    harness: Harness,
    region: Region,

    /// The input pipe's read end as a `Tty` view (never `Tty.init`: no
    /// `/dev/tty`, no raw mode, no signal handlers). Non-owning.
    input_tty: Tty,
    /// Built on first use so the self-reference points at the caller's
    /// storage rather than at the temporary `init` returned.
    reader: ?Reader = null,

    /// Byte span of every rendered frame, into the harness capture.
    frames: std.ArrayListUnmanaged(Frame) = .empty,

    /// Create the harness, the region (sized to `opts`), and the frame
    /// index. The capture and the index are pre-reserved, so a session
    /// allocates nothing per frame until it outgrows 64 frames or 4 KiB.
    pub fn init(io: std.Io, gpa: std.mem.Allocator, opts: Options) Error!Session {
        std.debug.assert(opts.region.height >= 1);
        var harness = try Harness.init(io, gpa);
        errdefer harness.deinit();
        var region = try Region.init(gpa, opts.region);
        errdefer region.deinit();
        try region.resize(opts.width, opts.region.height);
        var frames: std.ArrayListUnmanaged(Frame) = .empty;
        errdefer frames.deinit(gpa);
        try frames.ensureTotalCapacity(gpa, 64);
        try harness.captured.ensureTotalCapacity(gpa, 4096);
        return .{
            .gpa = gpa,
            .opts = opts,
            .harness = harness,
            .region = region,
            .input_tty = harness.inputTty(),
            .frames = frames,
        };
    }

    /// Tear down the frames, the region, the pipes, and the capture.
    pub fn deinit(self: *Session) void {
        self.frames.deinit(self.gpa);
        self.region.deinit();
        self.harness.deinit();
        self.* = undefined;
    }

    /// Render one frame: pump every available input event into `model`,
    /// draw, render through the output pipe, and return this frame's bytes.
    /// The slice points into the capture and is invalidated by the next
    /// frame that appends bytes (`frameBytes` re-derives it).
    ///
    /// `model` is duck-typed and must expose:
    ///   `pub fn onEvent(self: *Model, ev: Event) !void`
    ///   `pub fn draw(self: *Model, buf: *Buffer) !void`
    pub fn frame(self: *Session, model: anytype) ![]const u8 {
        try self.pump(model);
        try model.draw(&self.region.cur);
        const bytes = try self.renderCapture();
        try self.answerCpr(bytes);
        return bytes;
    }

    /// Run a scripted list of steps and return the whole captured stream.
    pub fn run(self: *Session, model: anytype, steps: []const Step) ![]const u8 {
        for (steps) |step| {
            try self.feedInput(step.input, model);
            var i: u32 = 0;
            while (i < step.frames) : (i += 1) _ = try self.frame(model);
        }
        return self.output();
    }

    /// Drive `Region.exit` through the harness (cursor show, autowrap on,
    /// sync close, transcript park) and capture its bytes as a frame.
    pub fn exit(self: *Session) ![]const u8 {
        const start = self.harness.captured.items.len;
        try self.region.exit(self.harness.writer());
        return self.capture(start);
    }

    /// Everything captured so far, after flushing pending frame bytes.
    pub fn output(self: *Session) Error![]const u8 {
        return self.harness.outputBytes();
    }

    /// The bytes frame `index` (0-based) emitted, or null when out of
    /// range. Index-based because a later frame can grow the capture and
    /// move earlier bytes.
    pub fn frameBytes(self: *const Session, index: usize) ?[]const u8 {
        if (index >= self.frames.items.len) return null;
        const f = self.frames.items[index];
        return self.harness.captured.items[f.start..f.end];
    }

    /// Record mode: every captured frame is also written to
    /// `<path>/frame-NNNN.escape`. See `Harness.recordToDir`.
    pub fn recordToDir(self: *Session, path: []const u8, opts: Harness.RecordOptions) Error!void {
        return self.harness.recordToDir(path, opts);
    }

    /// Feed scripted input in pipe-sized pieces and decode between them, so
    /// a step larger than the pipe capacity still runs: every `feed` fits,
    /// and every read happens before the next write. Events therefore reach
    /// `model` in order, before the frame that draws them.
    fn feedInput(self: *Session, bytes: []const u8, model: anytype) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const end = @min(off + feed_chunk, bytes.len);
            try self.harness.feed(bytes[off..end]);
            off = end;
            try self.pump(model);
        }
    }

    /// Render the region, then close the frame: flush, index the span, and
    /// mirror it to the recorder when one is open.
    fn renderCapture(self: *Session) ![]const u8 {
        const start = self.harness.captured.items.len;
        try self.region.render(self.harness.writer());
        return self.capture(start);
    }

    fn capture(self: *Session, start: usize) ![]const u8 {
        try self.harness.flush();
        const end = self.harness.captured.items.len;
        try self.frames.append(self.gpa, .{ .start = start, .end = end });
        const bytes = self.harness.captured.items[start..end];
        if (self.harness.recording()) try self.harness.recordFrame(bytes);
        return bytes;
    }

    /// Decode every input event currently available and dispatch it.
    fn pump(self: *Session, model: anytype) !void {
        const reader = self.readerPtr();
        while (true) {
            const ev = reader.nextTimeout(0) catch |err| switch (err) {
                // The input pipe is non-blocking: `WouldBlock` means
                // nothing is waiting and `EndOfStream` means the feed end
                // closed. Either way, this pump has nothing more to do.
                error.WouldBlock, error.EndOfStream => return,
                else => return err,
            };
            const e = ev orelse return;
            try self.dispatch(e, model);
        }
    }

    /// Route one decoded event. The region's own protocol replies — a CPR
    /// answer, a resize report — are consumed here, exactly as `App` does;
    /// everything else reaches the model.
    fn dispatch(self: *Session, ev: Event, model: anytype) !void {
        switch (ev) {
            .cpr => |pos| {
                if (self.region.anchor_row == 0) {
                    self.region.applyFirstCpr(pos.row);
                } else {
                    try self.region.applyCpr(pos.row, pos.col);
                }
            },
            .winsize => |ws| try self.region.resize(ws.cols, self.region.height),
            else => try model.onEvent(ev),
        }
    }

    /// Answer the region's CPR query by feeding the reply back into the
    /// input pipe, so the session closes the loop the way a terminal does.
    fn answerCpr(self: *Session, frame_bytes: []const u8) !void {
        const pos = self.opts.cpr orelse return;
        if (std.mem.indexOf(u8, frame_bytes, "\x1b[6n") == null) return;
        var buf: [32]u8 = undefined;
        // Two u16 fields: at most 14 bytes, so the buffer cannot overflow.
        const fmt = "\x1b[{d};{d}R";
        const reply = std.fmt.bufPrint(&buf, fmt, .{ pos.row, pos.col }) catch unreachable;
        try self.harness.feed(reply);
    }

    fn readerPtr(self: *Session) *Reader {
        if (self.reader == null) self.reader = Reader.init(&self.input_tty);
        return &self.reader.?;
    }
};

test {
    std.testing.refAllDecls(@This());
}

// ── tests ─────────────────────────────────────────

const testing = std.testing;

/// A model that accumulates printable key presses and draws the text.
const EchoModel = struct {
    text: [32]u8 = undefined,
    len: usize = 0,

    fn onEvent(self: *EchoModel, ev: Event) !void {
        switch (ev) {
            .key_press => |k| {
                if (k.codepoint >= 0x20 and k.codepoint < 0x7f) {
                    self.text[self.len] = @intCast(k.codepoint);
                    self.len += 1;
                }
            },
            else => {},
        }
    }

    fn draw(self: *EchoModel, buf: *Buffer) !void {
        _ = try buf.draw(.{}, self.text[0..self.len], 0, 0);
    }
};

/// A model that counts decoded keys instead of buffering them, for the
/// oversized-input script (a fixed 32-byte buffer cannot take 64 KiB).
const ProbeModel = struct {
    keys: usize = 0,

    fn onEvent(self: *ProbeModel, ev: Event) !void {
        switch (ev) {
            .key_press => self.keys += 1,
            else => {},
        }
    }

    fn draw(self: *ProbeModel, buf: *Buffer) !void {
        // The row reflects the events decoded, so the drawn frame is a
        // function of the state the model actually received.
        _ = try buf.draw(.{}, if (self.keys > 0) "p" else "-", 0, 0);
    }
};

test "frame: a scripted session emits an exact byte stream" {
    var session = try Session.init(testing.io, testing.allocator, .{
        .width = 8,
        .region = .{ .height = 1, .append_lines = false, .interactive = true, .sync_output = true },
    });
    defer session.deinit();
    var model: EchoModel = .{};

    // "hi" travels the pipe → Parser → model → Buffer → Region → pipe.
    const first = try session.run(&model, &[_]Step{.{ .input = "hi", .frames = 1 }});
    try testing.expectEqual(@as(usize, 2), model.len);
    try testing.expectEqualStrings(
        "\x1b[?2026h\x1b[?25l\x1b[?7l\x1b[6n\rhi\r\x1b[?7h\x1b[?2026l",
        first,
    );

    const closed = try session.exit();
    try testing.expectEqualStrings("\x1b[?25h\x1b[?7h\x1b[?2026l\r\n\r", closed);
    try testing.expectEqual(@as(usize, 2), session.frames.items.len);

    // The two captured frames tile the session stream exactly.
    const all = try session.output();
    try testing.expectEqualStrings(
        "\x1b[?2026h\x1b[?25l\x1b[?7l\x1b[6n\rhi\r\x1b[?7h\x1b[?2026l" ++
            "\x1b[?25h\x1b[?7h\x1b[?2026l\r\n\r",
        all,
    );
    try testing.expectEqualStrings(all[0..session.frames.items[0].end], session.frameBytes(0).?);
    try testing.expectEqualStrings(all[session.frames.items[1].start..], session.frameBytes(1).?);
    try testing.expect(session.frameBytes(2) == null);
}

test "frame: a frame that changed nothing writes nothing" {
    var session = try Session.init(testing.io, testing.allocator, .{
        .width = 8,
        .region = .{ .height = 2, .append_lines = false, .interactive = true, .sync_output = true },
    });
    defer session.deinit();
    var model: EchoModel = .{};

    const first = try session.run(&model, &[_]Step{.{ .input = "hi", .frames = 1 }});
    try testing.expectEqualStrings(
        "\x1b[?2026h\x1b[?25l\x1b[?7l\x1b[6n\rhi\r\n\r\x1b[?7h\x1b[?2026l",
        first,
    );

    // No input, no mutation: the second render must append zero bytes —
    // envelope included, so a hidden-cursor frame stages nothing.
    _ = try session.frame(&model);
    try testing.expectEqual(@as(usize, 2), session.frames.items.len);
    try testing.expectEqualStrings("", session.frameBytes(1).?);

    // The whole stream is still exactly the first frame.
    const all = try session.output();
    try testing.expectEqual(session.frames.items[0].end, all.len);
    try testing.expectEqualStrings(
        "\x1b[?2026h\x1b[?25l\x1b[?7l\x1b[6n\rhi\r\n\r\x1b[?7h\x1b[?2026l",
        all,
    );

    // A later frame re-wraps but does NOT re-hide the cursor: the hide is
    // a transition byte, emitted once, not per frame.
    try session.harness.feed("!");
    const third = try session.frame(&model);
    try testing.expect(std.mem.startsWith(u8, third, "\x1b[?2026h\x1b[?7l"));
    try testing.expect(std.mem.endsWith(u8, third, "\x1b[?7h\x1b[?2026l"));
    try testing.expect(std.mem.indexOf(u8, third, "\x1b[?25l") == null);
    try testing.expect(std.mem.indexOf(u8, third, "hi!") != null);
}

test "frame: the harness answers a CPR query with the configured position" {
    var session = try Session.init(testing.io, testing.allocator, .{
        .width = 8,
        .region = .{ .height = 2, .append_lines = false },
        .cpr = .{ .row = 9, .col = 1 },
    });
    defer session.deinit();
    var model: EchoModel = .{};

    _ = try session.run(&model, &[_]Step{.{ .input = "h", .frames = 1 }});
    try testing.expectEqual(@as(u16, 0), session.region.anchor_row);

    // The reply waits in the input pipe; the next frame's pump applies it.
    _ = try session.frame(&model);
    try testing.expectEqual(@as(u16, 9), session.region.anchor_row);
    // The CPR reply is the region's own protocol: the model never sees it.
    try testing.expectEqual(@as(usize, 1), model.len);
}

test "frame: a frame larger than the pipe capacity is captured whole" {
    // 400 rows of 201 bytes is ~80 KiB, above any Linux pipe capacity
    // (8 KiB..64 KiB by default). A sink that assumed the pipe could hold
    // a frame would block here forever; this one drains as it writes.
    const width = 200;
    const height = 400;
    var session = try Session.init(testing.io, testing.allocator, .{
        .width = width,
        .region = .{ .height = height, .append_lines = false, .interactive = false },
    });
    defer session.deinit();
    var model: EchoModel = .{};

    const bytes = try session.run(&model, &[_]Step{.{ .input = "hi", .frames = 1 }});
    try testing.expectEqual(height * (width + 1), bytes.len);
    try testing.expectEqualStrings("hi" ++ " " ** (width - 2) ++ "\n", bytes[0 .. width + 1]);
    // Every remaining row is blank: full-width spaces then a newline.
    var at: usize = width + 1;
    while (at < bytes.len) : (at += width + 1) {
        for (bytes[at..][0..width]) |b| try testing.expectEqual(@as(u8, ' '), b);
        try testing.expectEqual(@as(u8, '\n'), bytes[at + width]);
    }
    try testing.expect(session.harness.sinkError() == null);
}

test "frame: feed refuses to block when the input pipe fills" {
    var harness = try Harness.init(testing.io, testing.allocator);
    defer harness.deinit();

    // Fill the input pipe without reading it. A blocking write would hang
    // the test run; `feed` must fail instead. 4 MiB is above any pipe
    // capacity a Linux host hands out by default.
    var chunk: [64 * 1024]u8 = undefined;
    @memset(&chunk, 'x');
    var fed: usize = 0;
    var refused = false;
    while (fed < 4 * 1024 * 1024) : (fed += chunk.len) {
        harness.feed(&chunk) catch |err| {
            try testing.expectEqual(error.InputFull, err);
            refused = true;
            break;
        };
    }
    try testing.expect(refused);
}

test "frame: a scripted input larger than the pipe capacity still runs" {
    // 64 KiB of keystrokes: `run` must feed it in bounded pieces, decoding
    // between them, rather than blocking on a full input pipe.
    var input: [64 * 1024]u8 = undefined;
    for (input[0..], 0..) |*b, i| b.* = @intCast('a' + (i % 26));

    var session = try Session.init(testing.io, testing.allocator, .{
        .width = 8,
        .region = .{ .height = 1, .append_lines = false, .interactive = false },
    });
    defer session.deinit();
    var model: ProbeModel = .{};

    // Every keystroke round-tripped through the input pipe, and the frame
    // the model drew reflects the events it received.
    const bytes = try session.run(&model, &[_]Step{.{ .input = input[0..], .frames = 1 }});
    try testing.expectEqual(input.len, model.keys);
    try testing.expectEqualStrings("p       \n", bytes);
}

test "frame: recordToDir writes each frame and never clobbers a golden" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});

    var session = try Session.init(testing.io, testing.allocator, .{
        .width = 8,
        .region = .{ .height = 1, .append_lines = false },
    });
    defer session.deinit();
    var model: EchoModel = .{};

    try session.recordToDir(path, .{});
    _ = try session.run(&model, &[_]Step{.{ .input = "hi", .frames = 1 }});

    // The recorded golden is the frame, byte for byte.
    const golden = try session.harness.readGolden("frame-0000.escape", testing.allocator);
    defer testing.allocator.free(golden);
    try testing.expectEqualStrings(session.frameBytes(0).?, golden);

    // Re-recording frame 0000 is refused — a golden is never clobbered
    // silently — and only an explicit overwrite rewrites it.
    try session.recordToDir(path, .{});
    try testing.expectError(error.GoldenExists, session.frame(&model));
    const kept = try session.harness.readGolden("frame-0000.escape", testing.allocator);
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings(golden, kept);

    try session.recordToDir(path, .{ .overwrite = true });
    try session.harness.recordNamed("frame-0000.escape", "regenerated");
    const rewritten = try session.harness.readGolden("frame-0000.escape", testing.allocator);
    defer testing.allocator.free(rewritten);
    try testing.expectEqualStrings("regenerated", rewritten);

    // Leaving record mode stops the mirroring.
    session.harness.stopRecording();
    try testing.expect(!session.harness.recording());
    try testing.expectError(error.NotRecording, session.harness.recordFrame("x"));
}

test "frame: the raw harness drains, snapshots, clears, and feeds input" {
    var harness = try Harness.init(testing.io, testing.allocator);
    defer harness.deinit();
    var region = try Region.init(testing.allocator, .{
        .height = 1,
        .append_lines = false,
        .interactive = true,
        .sync_output = true,
    });
    defer region.deinit();
    try region.resize(8, 1);
    _ = try region.cur.draw(.{}, "hi", 0, 0);

    // The driven renderer writes through the pipe; the harness drains it.
    try region.render(harness.writer());
    const first = try harness.outputBytes();
    try testing.expect(std.mem.endsWith(u8, first, "\x1b[?7h\x1b[?2026l"));

    const snapshot = try harness.takeOutput();
    defer testing.allocator.free(snapshot);
    try testing.expectEqualStrings(first, snapshot);

    try harness.clear();
    try testing.expectEqual(@as(usize, 0), (try harness.outputBytes()).len);

    // Scripted input lands in the input pipe for a hand-wired decoder.
    try harness.feed("\x1b[A");
    var input_tty = harness.inputTty();
    var reader = Reader.init(&input_tty);
    const ev = (try reader.nextTimeout(100)) orelse return error.TestUnexpectedResult;
    switch (ev) {
        .key_press => |k| try testing.expectEqual(Key.up, k.codepoint),
        else => return error.TestUnexpectedResult,
    }
}

test "frame: the plain (non-interactive) path emits one unwrapped frame" {
    var session = try Session.init(testing.io, testing.allocator, .{
        .width = 4,
        // `sync_output` is deliberately true: `interactive` is the only
        // envelope gate, so a supported DEC 2026 must still produce zero
        // escape bytes on the piped path.
        .region = .{
            .height = 1,
            .append_lines = false,
            .interactive = false,
            .sync_output = true,
        },
    });
    defer session.deinit();
    var model: EchoModel = .{};

    const first = try session.run(&model, &[_]Step{.{ .input = "hi", .frames = 1 }});
    // The piped path carries no envelope at all: no sync wrap, no cursor
    // or autowrap switches, no CPR, no CNL. Blank cells are written as
    // spaces (a pipe has no cursor state for CUF) and rows end in `\n`.
    try testing.expect(std.mem.indexOf(u8, first, "\x1b") == null);
    try testing.expectEqualStrings("hi  \n", first);

    // The plain frame was the only output: later frames and the exit park
    // stay silent.
    const idle = try session.frame(&model);
    try testing.expectEqualStrings("", idle);
    const closed = try session.exit();
    try testing.expectEqualStrings("", closed);
}
