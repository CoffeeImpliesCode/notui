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
//! captured as a frame: the capture is exact, and what a test pins in it
//! is the script contract — what went out, where in the frame, and how
//! often — rather than a frozen copy of a frame's bytes.
//!
//! ```
//! var session = try Session.init(testing.allocator, testing.io, .{ .region = .{ .height = 1 } });
//! defer session.deinit();
//! const bytes = try session.run(&model, &[_]Step{.{ .input = "hi", .frames = 1 }});
//! try testing.expect(std.mem.indexOf(u8, bytes, "hi") != null);
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
//! refuses to block (`error.InputFull`), and `Session.run` feeds scripted input in chunks
//! it decodes between. Model callbacks and caller I/O providers can still block.
//!
//! Frame path allocation: the pipes are fds, and the capture buffer plus
//! the frame index are the harness's own — `Session.init` pre-reserves
//! both, so up to 64 frames / 4 KiB of output allocates nothing per frame.
//!
//! Reach through `@import("notui").frame_testing`. Initialize the harness or session,
//! register one `deinit`, then capture or run scripted frames. Native POSIX pipes and
//! fd-based reads require a compatible live `Io`; this is not a portable simulated backend.

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
        /// The pipe could not accept all input. An unspecified prefix may have been written;
        /// abort the harness rather than guessing a retry offset.
        InputFull,
    };

/// The output writer the driven renderer writes frames to.
///
/// A plain file writer blocks once the pipe fills, and a frame can exceed
/// the kernel's pipe capacity (64 KiB by default on Linux, less under a
/// conservative budget; a 200x60 band already emits ~12 KiB). This sink
/// owns a NON-BLOCKING write end instead: whenever the pipe is full it
/// drains the read end into the capture and keeps writing, so a frame of
/// any size is captured without a blocking pipe write. The harness, not this view, owns
/// the descriptors, allocator, I/O provider, and capture list. Keep them live and stable.
/// Fields are read-only except through the harness; copies alias the same capture.
const Sink = struct {
    io: std.Io,
    /// Write end (non-blocking).
    out: std.Io.File,
    /// Read end (non-blocking), drained into `captured`.
    in: std.Io.File,
    gpa: std.mem.Allocator,
    captured: *std.ArrayList(u8),
    /// The real failure behind a `WriteFailed` reported to the renderer (an
    /// allocation failure while capturing, or a pipe error); null while
    /// healthy.
    err: ?Error = null,
    buffer: [4096]u8 = undefined,
    interface: std.Io.Writer = undefined,

    fn start(
        gpa: std.mem.Allocator,
        io: std.Io,
        out: std.Io.File,
        in: std.Io.File,
        captured: *std.ArrayList(u8),
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
    ///
    /// `data` is non-empty by the vtable contract (`std.Io.Writer`:
    /// "`data.len` must be nonzero"), so indexing its last slice — the
    /// splat pattern — is in bounds, and the loop below needs no guard of
    /// its own.
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
/// One owner closes the pipes and disposes capture storage through the stored `gpa`.
/// Keep `gpa` and `io` live until then. Copies are not independent owners; after the
/// first writer call, keep its address fixed until disposal. Use serially without reentry.
/// Reachable fields are read-only ownership state, not independently disposable handles.
pub const Harness = struct {
    /// Filesystem recording policy. Defaults create missing directories but preserve
    /// existing files; overwrite must be selected explicitly for deliberate regeneration.
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
    captured: std.ArrayList(u8) = .empty,

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
    /// Failure closes every successfully opened descriptor; no partially initialized owner escapes.
    pub fn init(gpa: std.mem.Allocator, io: std.Io) Error!Harness {
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
    /// Invalidates all capture, writer, and input views. Repeated disposal is invalid.
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
    /// written an unspecified prefix; do not retry the whole input or guess its suffix.
    /// Abort this harness on failure. Use `Session.run` for chunked scripted input.
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
    /// The view and any Reader using it must not outlive the harness.
    pub fn inputTty(self: *Harness) Tty {
        return .{ .io = self.io, .fd = self.in_r };
    }

    /// The writer the driven renderer writes frames to. Built once; do not
    /// move the harness afterwards.
    pub fn writer(self: *Harness) *std.Io.Writer {
        if (self.sink == null) {
            self.sink = Sink.start(self.gpa, self.io, self.out_w, self.out_r, &self.captured);
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

    /// An independent copy of the captured stream; free with this harness's stored `gpa`.
    /// Capture may grow before an error; no result allocation escapes on failure.
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
    /// Synchronous filesystem work may block or return `error.Canceled`. An error leaves
    /// recording disabled; a directory may have been created. `path` is not retained.
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
    /// Advances the index even if recording fails; the attempted file may contain a prefix.
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
    /// `name` is relative to the recording directory and follows native path rules.
    /// Synchronous I/O may block or return `error.Canceled`; other write errors can leave
    /// a created/truncated file containing a prefix. Neither `name` nor `bytes` is retained.
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
    /// Free with the supplied `gpa`. Reads at most 1 MiB; filesystem errors and
    /// `error.Canceled` return no owned result. `name` is borrowed only during this call.
    pub fn readGolden(
        self: *Harness,
        gpa: std.mem.Allocator,
        name: []const u8,
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
/// Input is borrowed only during `run`; the default performs one frame with no new input.
pub const Step = struct {
    /// Raw terminal input bytes fed before the step's frames.
    input: []const u8 = "",
    /// Frames to render for this step. Each frame pumps every available
    /// input event, draws once, and renders once.
    frames: u32 = 1,
};

/// The CPR query, as it goes on the wire: the Region emits it AFTER the
/// frame has painted and parked, and never while a reply is outstanding,
/// because the reply is untagged and two questions could not be told
/// apart. The harness both recognises it in a frame's bytes (the only
/// evidence a query went out — `Region` publishes no query state to poll)
/// and, in its tests, pins WHERE in a frame it landed and how many times
/// it was asked. The exact bytes of a frame belong to the Region; a
/// harness that froze them would turn every change to the paint into a
/// change to the script contract.
const cpr_query = "\x1b[6n";

/// A `Region` driven end to end through a `Harness`.
///
/// Self-referential (the lazily built sink and `Reader` point into the
/// session), so a session must not be copied or moved after its first
/// `frame`. Build it in place: `var session = try Session.init(...)`.
/// Initialization releases all partial owners on failure. Keep the stored allocator and
/// I/O provider live until one `deinit`; copies share ownership and cannot be disposed twice.
/// Use on one thread without model/writer reentry. State fields are read-only; drawing
/// into `region.cur` is allowed through the model callback. Returned capture views expire
/// on capture mutation or disposal; frame indices survive append growth.
pub const Session = struct {
    /// Input bytes per `feed` inside `run`. Small enough to fit any pipe
    /// capacity, so a scripted step of any size is fed in bounded pieces.
    const feed_chunk = 1024;

    /// Native capture geometry. Defaults assume an 80-column, three-row interactive band.
    /// Initial `region.height >= 1` is a caller precondition in all optimization modes.
    pub const Options = struct {
        /// Terminal columns the band is captured at — the width the golden
        /// bytes are written against.
        width: u16 = 80,
        /// The band's own options, handed to `Region.init` verbatim.
        /// Carrying the type instead of mirroring its fields keeps this
        /// harness out of lockstep with `Region.Options` changes.
        region: Region.Options = .{ .height = 3 },
        /// Answer the region's own CPR query with this position. Null
        /// leaves every query unanswered. A real terminal always answers,
        /// so the bytes a session captures are the terminal's view only
        /// with a reply configured. Both fields are `u16`, so a reply is
        /// at most 14 bytes and never exhausts the formatter's buffer.
        ///
        /// The reply is fed back the way a terminal sends one — after the
        /// frame that asked, into the input pipe — so it reaches
        /// `applyCpr` on a LATER pump, over the same `Event.cpr` path
        /// `App` uses. That delay is the protocol, not a harness
        /// artifact: the query goes out after the paint and the park, and
        /// only one is ever outstanding, so the answer describes what the
        /// frame that asked left on the screen.
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
    frames: std.ArrayList(Frame) = .empty,

    /// Create the harness, the region (sized to `opts`), and the frame
    /// index. The capture and the index are pre-reserved, so a session
    /// allocates nothing per frame until it outgrows 64 frames or 4 KiB.
    /// The height precondition is debug-asserted, not returned release-mode validation.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: Options) Error!Session {
        std.debug.assert(opts.region.height >= 1);
        var harness = try Harness.init(gpa, io);
        errdefer harness.deinit();
        var region = try Region.init(gpa, opts.region);
        errdefer region.deinit();
        // The session owns the band, not a screen: the declared width
        // and the band's own rows are the whole visible geometry.
        try region.resize(opts.width, opts.region.height, opts.region.height);
        var frames: std.ArrayList(Frame) = .empty;
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
    /// Invalidates all model buffer and capture views; repeated disposal is invalid.
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
    /// Callbacks run synchronously on this thread and may not reenter the session.
    /// `ev`'s slices expire at the next reader call; copy them before returning if retained.
    /// `buf` is a call-borrowed grid; its drawn strings must live until rendering finishes.
    /// Errors propagate without undoing model updates, consumed input, or captured prefixes.
    pub fn frame(self: *Session, model: anytype) ![]const u8 {
        try self.pump(model);
        try model.draw(&self.region.cur);
        const bytes = try self.renderCapture();
        try self.answerCpr(bytes);
        return bytes;
    }

    /// Run a scripted list of steps and return the whole captured stream.
    /// Borrows `steps` and input only during the call; the result borrows the capture.
    /// Uses `frame`'s callback and failure contract. Earlier steps remain applied on error.
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
    /// The returned slice expires on capture mutation or session disposal.
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
            .cpr => |pos| try self.region.applyCpr(pos.row, pos.col),
            // The report carries the terminal's rows; the band keeps its
            // own logical height across the physical change.
            .winsize => |ws| try self.region.resize(ws.cols, ws.rows, self.region.height),
            else => try model.onEvent(ev),
        }
    }

    /// Answer the region's CPR query by feeding the reply back into the
    /// input pipe, so the session closes the loop the way a terminal does.
    ///
    /// The frame's own bytes are the only evidence that a query went out:
    /// `Region` publishes no query state to poll, and while the single
    /// slot is free that is all a frame can owe. The query is emitted
    /// after the paint and the park, so the reply this feeds reaches
    /// `applyCpr` on a LATER pump — the frame that asked never sees its
    /// own answer, exactly as on a terminal that is slow to reply.
    fn answerCpr(self: *Session, frame_bytes: []const u8) !void {
        const pos = self.opts.cpr orelse return;
        if (std.mem.indexOf(u8, frame_bytes, cpr_query) == null) return;
        var buf: [32]u8 = undefined;
        // 32 bytes against a 14-byte worst case (`\x1b[65535;65535R`):
        // the format cannot overflow, so the failure below is a
        // propagation channel, not a tolerated case. A caller that sees
        // `error.NoSpaceLeft` learns the reply changed shape, rather than
        // getting a silently truncated CPR and a corrupted band.
        const reply = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{ pos.row, pos.col });
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

// ── tests ──────────────────────────────────

const testing = std.testing;

/// How many times `needle` occurs in `haystack`, without overlaps.
fn occurrences(haystack: []const u8, needle: []const u8) usize {
    var found: usize = 0;
    var at: usize = 0;
    while (std.mem.findPos(u8, haystack, at, needle)) |hit| {
        found += 1;
        at = hit + needle.len;
    }
    return found;
}

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

test "frame: a scripted session paints once and its frames tile the stream" {
    var session = try Session.init(testing.allocator, testing.io, .{
        .width = 8,
        .region = .{ .height = 1, .append_lines = false, .interactive = true, .sync_output = true },
    });
    defer session.deinit();
    var model: EchoModel = .{};

    // "hi" travels the pipe → Parser → model → Buffer → Region → pipe.
    const first = try session.run(&model, &[_]Step{.{ .input = "hi", .frames = 1 }});
    try testing.expectEqual(@as(usize, 2), model.len);
    // The script reached the screen exactly once: one delivery to the
    // model and one painted copy — not one per frame, not one per row.
    try testing.expectEqual(@as(usize, 1), occurrences(first, "hi"));
    // Exactly one query went out, and it went out AFTER the paint, so it
    // asks about the row the frame parked on. A query ahead of the paint
    // would measure a cursor the frame has yet to move.
    try testing.expectEqual(@as(usize, 1), occurrences(first, cpr_query));
    const painted = std.mem.indexOf(u8, first, "hi").?;
    const asked = std.mem.indexOf(u8, first, cpr_query).?;
    try testing.expect(painted < asked);

    // That query still holds the single slot, so the idle frame after it
    // writes nothing at all — envelope included, and no second query for a
    // terminal that is slow to answer.
    _ = try session.frame(&model);

    const closed = try session.exit();
    // Exit gives back what the frame envelope took — cursor, autowrap,
    // sync — and parks below the band. It asks nothing.
    try testing.expectEqual(@as(usize, 1), occurrences(closed, "\x1b[?25h"));
    try testing.expectEqual(@as(usize, 1), occurrences(closed, "\x1b[?7h"));
    try testing.expectEqual(@as(usize, 1), occurrences(closed, "\x1b[?2026l"));
    try testing.expectEqual(@as(usize, 0), occurrences(closed, cpr_query));
    try testing.expect(std.mem.endsWith(u8, closed, "\r\n\r"));

    // Across the paint, the idle frame and the exit the session asked once.
    const all = try session.output();
    try testing.expectEqual(@as(usize, 1), occurrences(all, cpr_query));
    try testing.expectEqual(@as(usize, 1), occurrences(all, "hi"));

    // Three frames — the paint, the idle one, the exit — and they tile the
    // captured stream: contiguous, from the first byte to the last, each
    // index addressing exactly the bytes its own frame emitted.
    try testing.expectEqual(@as(usize, 3), session.frames.items.len);
    try testing.expectEqual(@as(usize, 0), session.frames.items[0].start);
    try testing.expectEqual(session.frames.items[0].end, session.frames.items[1].start);
    try testing.expectEqual(session.frames.items[1].end, session.frames.items[2].start);
    try testing.expectEqual(all.len, session.frames.items[2].end);
    for (session.frames.items, 0..) |span, i| {
        try testing.expectEqualStrings(all[span.start..span.end], session.frameBytes(i).?);
    }
    // A frame that was never rendered has no bytes: the index is the
    // address, not an offset into the capture.
    try testing.expect(session.frameBytes(3) == null);
}

test "frame: a frame that changed nothing writes nothing" {
    var session = try Session.init(testing.allocator, testing.io, .{
        .width = 8,
        .region = .{ .height = 2, .append_lines = false, .interactive = true, .sync_output = true },
    });
    defer session.deinit();
    var model: EchoModel = .{};

    _ = try session.run(&model, &[_]Step{.{ .input = "hi", .frames = 1 }});
    try testing.expectEqual(@as(usize, 2), model.len);

    // No input, no mutation: the second render appends zero bytes —
    // envelope included, so a hidden-cursor frame stages nothing — and the
    // query the first frame asked still holds its slot, unanswered.
    _ = try session.frame(&model);
    try testing.expectEqual(@as(usize, 2), session.frames.items.len);
    try testing.expectEqualStrings("", session.frameBytes(1).?);

    // The idle frame appended nothing at all: the capture is still exactly
    // the span the first frame claimed.
    const all = try session.output();
    try testing.expectEqual(@as(usize, 0), session.frames.items[0].start);
    try testing.expectEqual(session.frames.items[0].end, all.len);

    // A later frame re-wraps but does NOT re-hide the cursor: the hide is
    // a transition byte, emitted once, not per frame.
    try session.harness.feed("!");
    const third = try session.frame(&model);
    try testing.expect(std.mem.startsWith(u8, third, "\x1b[?2026h\x1b[?7h"));
    try testing.expect(std.mem.endsWith(u8, third, "\x1b[?2026l"));
    try testing.expect(std.mem.indexOf(u8, third, "\x1b[?25l") == null);
    try testing.expect(std.mem.indexOf(u8, third, "hi!") != null);
    // A frame that DID change something still does not ask again: one
    // query is outstanding and its reply is untagged.
    try testing.expect(std.mem.indexOf(u8, third, cpr_query) == null);

    // One query for the whole session, and one painted copy of the input.
    const total = try session.output();
    try testing.expectEqual(@as(usize, 1), occurrences(total, cpr_query));
    try testing.expectEqual(@as(usize, 1), occurrences(total, "hi!"));
}

test "frame: a postpaint reply anchors the band without reaching the model" {
    var session = try Session.init(testing.allocator, testing.io, .{
        .width = 8,
        .region = .{ .height = 2, .append_lines = false },
        .cpr = .{ .row = 9, .col = 1 },
    });
    defer session.deinit();
    try session.region.resize(8, 24, 2);
    var model: EchoModel = .{};

    _ = try session.run(&model, &[_]Step{.{ .input = "h", .frames = 1 }});
    try testing.expectEqual(@as(u16, 0), session.region.anchorRow());

    // The reply waits in the input pipe; the next frame's pump applies it.
    _ = try session.frame(&model);
    try testing.expectEqual(@as(u16, 8), session.region.anchorRow());
    // The CPR reply is the region's own protocol: the model never sees it.
    try testing.expectEqual(@as(usize, 1), model.len);
}

test "frame: a reply that lands after the columns moved is discarded" {
    var session = try Session.init(testing.allocator, testing.io, .{
        .width = 8,
        .region = .{ .height = 2, .append_lines = false },
        .cpr = .{ .row = 9, .col = 1 },
    });
    defer session.deinit();
    // A screen the band actually lives in: with only its own rows
    // declared there is no row for a reply to name.
    try session.region.resize(8, 24, 2);
    var model: EchoModel = .{};

    // The first frame paints, asks, and its reply waits in the input pipe
    // — unusable until it is read, never cached from a first measurement.
    _ = try session.run(&model, &[_]Step{.{ .input = "h", .frames = 1 }});
    try testing.expectEqual(@as(u16, 0), session.region.anchorRow());

    // The terminal reports fewer columns while that reply is in flight,
    // so the rows it names are rows the band stopped tracking.
    try session.region.resize(4, 24, 2);
    const repainted = try session.frame(&model);
    // The pump consumed the reply and DISCARDED it: the anchor is still
    // unusable, and the frame that repainted at the new geometry asked
    // exactly once for a measurement of the geometry that is live now.
    try testing.expectEqual(@as(u16, 0), session.region.anchorRow());
    try testing.expectEqual(@as(usize, 1), occurrences(repainted, cpr_query));

    // That fresh reply measures: the terminal still reports row 9 and the
    // band still occupies two rows below it, so the anchor lands on row 8.
    _ = try session.frame(&model);
    try testing.expectEqual(@as(u16, 8), session.region.anchorRow());
    // Neither reply reached the model: both are the region's own protocol.
    try testing.expectEqual(@as(usize, 1), model.len);
}

test "frame: a frame larger than the pipe capacity is captured whole" {
    // 400 rows of 201 bytes is ~80 KiB, above any Linux pipe capacity
    // (8 KiB..64 KiB by default). A sink that assumed the pipe could hold
    // a frame would block here forever; this one drains as it writes.
    const width = 200;
    const height = 400;
    var session = try Session.init(testing.allocator, testing.io, .{
        .width = width,
        .region = .{ .height = height, .append_lines = false, .interactive = false },
    });
    defer session.deinit();
    var model: EchoModel = .{};

    const bytes = try session.run(&model, &[_]Step{.{ .input = "hi", .frames = 1 }});
    try testing.expectEqual(height * (width + 1), bytes.len);
    try testing.expectEqualStrings("hi" ++ @as([width - 2]u8, @splat(' ')) ++ "\n", bytes[0 .. width + 1]);
    // Every remaining row is blank: full-width spaces then a newline.
    var at: usize = width + 1;
    while (at < bytes.len) : (at += width + 1) {
        for (bytes[at..][0..width]) |b| try testing.expectEqual(@as(u8, ' '), b);
        try testing.expectEqual(@as(u8, '\n'), bytes[at + width]);
    }
    try testing.expect(session.harness.sinkError() == null);
}

test "frame: feed refuses to block when the input pipe fills" {
    var harness = try Harness.init(testing.allocator, testing.io);
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

    var session = try Session.init(testing.allocator, testing.io, .{
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

    var session = try Session.init(testing.allocator, testing.io, .{
        .width = 8,
        .region = .{ .height = 1, .append_lines = false },
    });
    defer session.deinit();
    var model: EchoModel = .{};

    try session.recordToDir(path, .{});
    _ = try session.run(&model, &[_]Step{.{ .input = "hi", .frames = 1 }});

    // The recorded golden is the frame, byte for byte.
    const golden = try session.harness.readGolden(testing.allocator, "frame-0000.escape");
    defer testing.allocator.free(golden);
    try testing.expectEqualStrings(session.frameBytes(0).?, golden);

    // Re-recording frame 0000 is refused — a golden is never clobbered
    // silently — and only an explicit overwrite rewrites it.
    try session.recordToDir(path, .{});
    try testing.expectError(error.GoldenExists, session.frame(&model));
    const kept = try session.harness.readGolden(testing.allocator, "frame-0000.escape");
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings(golden, kept);

    try session.recordToDir(path, .{ .overwrite = true });
    try session.harness.recordNamed("frame-0000.escape", "regenerated");
    const rewritten = try session.harness.readGolden(testing.allocator, "frame-0000.escape");
    defer testing.allocator.free(rewritten);
    try testing.expectEqualStrings("regenerated", rewritten);

    // Leaving record mode stops the mirroring.
    session.harness.stopRecording();
    try testing.expect(!session.harness.recording());
    try testing.expectError(error.NotRecording, session.harness.recordFrame("x"));
}

test "frame: the raw harness drains, snapshots, clears, and feeds input" {
    var harness = try Harness.init(testing.allocator, testing.io);
    defer harness.deinit();
    var region = try Region.init(testing.allocator, .{
        .height = 1,
        .append_lines = false,
        .interactive = true,
        .sync_output = true,
    });
    defer region.deinit();
    try region.resize(8, 1, 1);
    _ = try region.cur.draw(.{}, "hi", 0, 0);

    // The driven renderer writes through the pipe; the harness drains it.
    try region.render(harness.writer());
    const first = try harness.outputBytes();
    try testing.expect(std.mem.endsWith(u8, first, "\x1b[?2026l"));

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
    var session = try Session.init(testing.allocator, testing.io, .{
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
