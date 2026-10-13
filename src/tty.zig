//! The terminal device in raw mode: `/dev/tty` for input and termios, a
//! second descriptor for frame output, SIGWINCH and signal cleanup.
//!
//! Two descriptors, opened independently. `fd` is the read/write `/dev/tty`:
//! it stays blocking and owns the termios, the ioctls and the buffered writer
//! used for capability probes and teardown. `out` is a second, write-only
//! `/dev/tty` opened `O_NONBLOCK`, and it is the frame transport. The split is
//! what keeps the loop nonblocking: a full terminal buffer reports `EAGAIN`
//! and the frame stays queued, while input still reads through the descriptor
//! it has always used.
//!
//! `io` is used for the buffered writes, the reads and the window-size
//! fallback. Termios changes, window size and the readiness checks are native
//! `posix` calls on the stored descriptors, and the signal handlers are
//! process-wide: one tty at a time, one handler per signal. `restoreTerminal`
//! needs neither, because it writes the descriptor directly and is built to be
//! called from a signal handler or a panic hook.
//!
//! Windows and WASI have no `/dev/tty`. There the frame transport is absent
//! and `tryWrite` reports `error.WriteFailed` rather than quietly blocking on
//! a descriptor that cannot be nonblocking.

const std = @import("std");
const builtin = @import("builtin");
const output = @import("output.zig");
const posix = std.posix;
const Winsize = @import("event.zig").Winsize;

/// The terminal device, opened twice: read/write for input and
/// termios, write-only for the nonblocking frame transport.
const tty_path = "/dev/tty";

/// Whether the frame transport can be opened with a real `O_NONBLOCK`.
/// Windows and WASI have no `/dev/tty` at all, and where the open flags
/// cannot carry `O_NONBLOCK` the descriptor would be *blocking* —
/// installing it would make `tryWrite` block the event loop instead of
/// reporting 0 bytes, which is the one failure this seam exists to
/// prevent. There the transport stays absent and `tryWrite` reports
/// `error.WriteFailed` rather than blocking in secret.
const can_open_nonblocking = switch (builtin.os.tag) {
    .windows, .wasi, .plan9 => false,
    else => @hasField(posix.O, "NONBLOCK") and @hasField(posix.O, "ACCMODE"),
};

/// Open `path` write-only and `O_NONBLOCK`. `null` when this platform's
/// open flags cannot express a nonblocking descriptor
/// (`can_open_nonblocking`). Open errors are propagated: a transport
/// that cannot be opened is a failure the caller must see, not a
/// silently blocking fallback.
fn openNonblockingWrite(path: []const u8) !?std.Io.File {
    if (!can_open_nonblocking) return null;
    var flags: posix.O = .{ .ACCMODE = .WRONLY };
    // No controlling-terminal theft on open, no descriptor inherited
    // across an exec, and EAGAIN instead of a block when the terminal
    // buffer is full.
    if (@hasField(posix.O, "NOCTTY")) flags.NOCTTY = true;
    if (@hasField(posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    if (@hasField(posix.O, "NONBLOCK")) flags.NONBLOCK = true;
    const handle = try posix.openat(posix.AT.FDCWD, path, flags, 0);
    return .{ .handle = handle, .flags = .{ .nonblocking = true } };
}

/// Whether the kernel put `fd` in nonblocking mode (`O_NONBLOCK`).
/// False where the platform has no `O_NONBLOCK` bit to ask about.
fn isNonblocking(fd: posix.fd_t) bool {
    if (!@hasField(posix.O, "NONBLOCK")) return false;
    const rc = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    if (posix.errno(rc) != .SUCCESS) return false;
    const flags: usize = @intCast(rc);
    return flags & (@as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK")) != 0;
}

/// Whether `fd` is already closed (`fcntl` reports `EBADF`).
fn isClosed(fd: posix.fd_t) bool {
    return posix.errno(posix.system.fcntl(fd, posix.F.GETFD, @as(usize, 0))) == .BADF;
}

/// ioctl request constants above c_int's range (e.g. IOCSPTLCK, IOCGPTN) break
/// when libc is linked (request becomes c_int); pass the bits via the ABI-safe
/// type for the current mode.
fn ioctlReq(req: u32) if (builtin.link_libc) c_int else u32 {
    return if (builtin.link_libc) @bitCast(req) else req;
}

/// Set by the SIGWINCH handler and drained by `Tty.checkResize`. It is
/// process-wide because the handler is: a signal carries no instance, so one
/// flag records that some terminal in this process resized. A reader that
/// drains it learns only that a resize happened, never which descriptor.
var resize_signaled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Whether the SIGWINCH handler is installed. The handlers are process-wide
/// and installed once; `Tty.deinit` restores the default disposition, so a
/// later session installs them again.
var handler_installed: bool = false;

/// Whether the SIGTERM and SIGINT cleanup handlers are installed, under the
/// same process-wide, install-once rule as `handler_installed`.
var term_signal_cleanup_installed: bool = false;

/// The tty a signal or panic handler restores, or `null` when no session has
/// opened one. `Tty.init` stores a copy here and `makeRaw` keeps its termios in
/// step, and `Tty.deinit` clears it when it owns that same descriptor.
///
/// It is one slot for the whole process, because a signal handler and a panic
/// hook have nothing to carry an instance in. Two `Tty` values open at once
/// therefore share the slot: the last one opened is the one a signal restores.
/// An application that needs two independent terminals must not rely on this
/// slot and must restore each one itself.
pub var global_tty: ?Tty = null;

/// Put the terminal back the way `global_tty` found it: the original termios,
/// then autowrap, the cursor, the kitty keyboard and synchronized output.
///
/// Called by this module's SIGTERM and SIGINT handlers and available to an
/// application as a `panic` override, because neither a kill nor a panic runs
/// a `defer`, and a raw terminal left behind is what forces a manual reset.
///
/// Best-effort and built for that context: it touches only the stored
/// descriptor, reports nothing, and does nothing at all when `global_tty` is
/// null. It does not write the App's own exit sequences, so a session that
/// ends normally still uses `Capabilities.restore`.
pub fn restoreTerminal() void {
    if (global_tty) |*g| {
        if (g.original_termios) |termios| {
            posix.tcsetattr(g.fd.handle, .FLUSH, termios) catch |err| {
                std.mem.doNotOptimizeAway(@intFromError(err));
            };
        }
        // DECAWM first: a kill or a panic lands mid-frame, so wrapping
        // may still be off. It is re-enabled before the cursor is shown
        // and before sync output closes, exactly as the frame epilogue
        // orders them.
        const cleanup = "\x1b[?7h\x1b[?25h\x1b[<u\x1b[?2026l";
        switch (builtin.os.tag) {
            .linux => _ = std.os.linux.write(g.fd.handle, cleanup.ptr, cleanup.len),
            else => {}, // best-effort: no portable raw write in 0.16
        }
    }
}

/// One terminal, opened for input, termios and window size and — where the
/// platform allows it — opened a second time as the nonblocking frame
/// transport.
///
/// A `Tty` owns both descriptors and releases them in `deinit`; it borrows the
/// `io` it was built with, which must stay valid for the `Tty`'s life. Its
/// fields are reachable, so a caller may build one around descriptors it
/// already has (`out` stays null there, which is what makes `tryWrite`
/// refuse rather than fall back to the blocking descriptor).
///
/// `writer` caches a buffered writer inside the value, so a `Tty` must not
/// move once it is in use. The signal handlers and `global_tty` are
/// process-wide, as described at module level: two `Tty` values share one
/// handler and one restore slot.
pub const Tty = struct {
    /// The `std.Io` every buffered read and write on this instance goes
    /// through. Borrowed: it must outlive the `Tty`.
    io: std.Io,
    /// The read/write `/dev/tty`: input, termios and the ioctls. Blocking.
    fd: std.Io.File,

    /// The frame transport: a SECOND, write-only `/dev/tty` opened
    /// `O_NONBLOCK`, so a full terminal buffer reports EAGAIN instead
    /// of stalling the loop. `null` for a caller-built `Tty` (the
    /// `Tty{ .io, .fd }` fixtures that have no terminal to write to)
    /// and on platforms whose open flags cannot carry `O_NONBLOCK`.
    /// Never the same descriptor as `fd`: input stays blocking.
    out: ?std.Io.File = null,

    /// The termios captured by `makeRaw`, restored by `restore` and `deinit`.
    /// Null until `makeRaw` succeeds, and null again after a restore.
    original_termios: ?posix.termios = null,
    /// Whether this instance currently owns a raw-mode terminal. `restore`
    /// clears it; `makeRaw` and `deinit` consult it.
    in_raw_mode: bool = false,
    /// The buffered writer over `fd`, built on the first `writer` call so its
    /// buffer lives at this instance's address rather than a copy's.
    tty_writer: ?std.Io.File.Writer = null,
    /// The storage `tty_writer` buffers into.
    write_buf: [4096]u8 = undefined,

    /// Open `/dev/tty` for input and termios, open the nonblocking frame
    /// transport where the platform allows one, and install the SIGWINCH and
    /// SIGTERM/SIGINT handlers once per process. Raw mode is NOT entered:
    /// call `makeRaw` next, so the order is `init`, `makeRaw`, then capability
    /// detection on an already-raw terminal.
    ///
    /// `io` must stay valid as long as the returned value is used. Open
    /// failures propagate, including a refused frame transport, and nothing
    /// is left open when one does. The returned value is also published in
    /// `global_tty`, so a signal handler can restore it.
    pub fn init(io: std.Io) !Tty {
        var f = try std.Io.Dir.openFileAbsolute(io, tty_path, .{ .mode = .read_write });
        errdefer f.close(io);

        // Opened second and independently: `fd` keeps the blocking
        // behaviour input and the probe/teardown writer depend on.
        const o = try openNonblockingWrite(tty_path);
        errdefer if (o) |file| file.close(io);

        if (!handler_installed) {
            const handler: posix.Sigaction = .{
                .handler = .{ .handler = handleWinch },
                .mask = posix.sigemptyset(),
                .flags = 0,
            };
            posix.sigaction(posix.SIG.WINCH, &handler, null);
            handler_installed = true;
        }

        if (!term_signal_cleanup_installed) {
            const term_handler: posix.Sigaction = .{
                .handler = .{ .handler = handleTermSignal },
                .mask = posix.sigemptyset(),
                .flags = 0,
            };
            posix.sigaction(posix.SIG.TERM, &term_handler, null);
            posix.sigaction(posix.SIG.INT, &term_handler, null);
            term_signal_cleanup_installed = true;
        }

        const self: Tty = .{
            .io = io,
            .fd = f,
            .out = o,
        };
        global_tty = self;
        return self;
    }

    /// Restore the terminal, restore the default disposition of the signal
    /// handlers, and close both descriptors. Releases what `init` took; a
    /// `Tty` built by a caller around its own descriptors has those closed
    /// too, because the value owns them. The value is unusable afterwards.
    pub fn deinit(self: *Tty) void {
        if (global_tty) |*g| {
            if (g.fd.handle == self.fd.handle) global_tty = null;
        }
        self.restore();
        resetSignalHandler();
        self.fd.close(self.io);
        if (self.out) |file| file.close(self.io);
        self.* = undefined;
    }

    /// Whether `fd` is a terminal device, decided by asking it for its window
    /// size: only a terminal answers `TIOCGWINSZ`. False for a file, a pipe,
    /// a socket, and for a descriptor that is not open.
    pub fn isTty(fd: posix.fd_t) bool {
        var wsz: posix.winsize = undefined;
        return posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&wsz)) == 0;
    }

    /// Enter raw mode: capture the current termios and apply the raw form.
    ///
    /// A no-op when the instance is already raw, so it is safe to call twice.
    /// `error.GetAttrFailed` and `error.SetAttrFailed` mean the terminal kept
    /// the state it had; nothing else changed, and a later `restore` is still
    /// a no-op. On success the captured termios also reach `global_tty`, so a
    /// signal or panic handler can put the terminal back.
    pub fn makeRaw(self: *Tty) !void {
        if (self.in_raw_mode) return;
        const orig = posix.tcgetattr(self.fd.handle) catch return error.GetAttrFailed;
        const raw = rawTermios(orig);
        posix.tcsetattr(self.fd.handle, .FLUSH, raw) catch return error.SetAttrFailed;
        self.original_termios = orig;
        self.in_raw_mode = true;
        // Keep the panic-restore copy in sync.
        if (global_tty) |*g| {
            g.original_termios = orig;
            g.in_raw_mode = true;
        }
    }

    /// Put back the termios `makeRaw` captured. Idempotent, and a no-op when
    /// the instance was never raw. A failed `tcsetattr` is logged and leaves
    /// the instance marked as not raw, because retrying the same restore will
    /// not do better.
    pub fn restore(self: *Tty) void {
        if (!self.in_raw_mode) return;
        if (self.original_termios) |termios| {
            posix.tcsetattr(self.fd.handle, .FLUSH, termios) catch |err| {
                std.log.scoped(.notui_tty).err("couldn't restore terminal: {}", .{err});
            };
        }
        self.in_raw_mode = false;
    }

    /// The terminal size from `TIOCGWINSZ`. An ioctl error, or a report with a
    /// zero row or column, falls back to 80x24 with no pixel counts: a caller
    /// always gets a usable band, and the error is not worth failing a frame
    /// over. The result is a snapshot; ask again after a resize.
    pub fn getWinsize(self: *Tty) !Winsize {
        var wsz: posix.winsize = .{
            .row = 0,
            .col = 0,
            .xpixel = 0,
            .ypixel = 0,
        };
        const err = posix.system.ioctl(self.fd.handle, posix.T.IOCGWINSZ, @intFromPtr(&wsz));
        if (posix.errno(err) == .SUCCESS and wsz.row > 0 and wsz.col > 0)
            return .{
                .rows = wsz.row,
                .cols = wsz.col,
                .x_pixel = wsz.xpixel,
                .y_pixel = wsz.ypixel,
            };
        return .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 };
    }

    /// Whether a SIGWINCH arrived since the last check, and clears the flag.
    ///
    /// The flag is process-wide, so a true result means this terminal may
    /// have resized, not that it did: confirm with `getWinsize`.
    pub fn checkResize(self: *Tty) bool {
        _ = self;
        return resize_signaled.swap(false, .acquire);
    }

    /// Record a resize as if SIGWINCH had arrived, so the next `checkResize`
    /// returns true. For callers that learn of a resize some other way, and
    /// for tests that cannot deliver the signal.
    pub fn markResized(self: *Tty) void {
        _ = self;
        resize_signaled.store(true, .release);
    }

    /// One nonblocking frame write: the bytes the terminal accepted,
    /// `0` when it would block. The caller (`OutputQueue.drain`) keeps
    /// the remainder pending, in order, and retries — a short write and
    /// a would-block are the same contract. Writes go to `out`, the
    /// `O_NONBLOCK` write-only descriptor.
    ///
    /// `error.WriteFailed` when there is no transport: a caller-built
    /// `Tty` with `out == null`, or a platform whose open flags cannot
    /// carry `O_NONBLOCK`. It never falls back to `fd` — that
    /// descriptor is blocking, and quietly blocking here is exactly the
    /// stall this method exists to remove.
    pub fn tryWrite(self: *Tty, bytes: []const u8) output.OutputQueue.WriteError!usize {
        const file = self.out orelse return error.WriteFailed;
        return output.tryWriteFd(self.io, file, bytes);
    }

    /// The buffered writer over `fd`, built once against this instance's
    /// internal buffer, so it must not be moved afterwards. The caller flushes
    /// it; nothing here writes on its own, and the writer is the only handle
    /// to `fd`'s write side, which is deliberately not used for frames.
    pub fn writer(self: *Tty) *std.Io.Writer {
        if (self.tty_writer == null) {
            self.tty_writer = self.fd.writerStreaming(self.io, self.write_buf[0..]);
        }
        return &self.tty_writer.?.interface;
    }

    /// Read from `fd` into `buf`, blocking until at least one byte arrives,
    /// and return how many. `0` means the input ended. The descriptor is
    /// blocking by design, so readiness is the caller's to establish before
    /// calling; this is the path `Reader` uses, and a cancelation request does
    /// not interrupt the wait.
    pub fn read(self: *Tty, buf: []u8) !usize {
        const n = try self.fd.readStreaming(self.io, &.{buf});
        return n;
    }

    /// Build the raw-mode termios from the current state: input
    /// processing off (ICANON/ECHO/ISIG/IEXTEN/IXON), output processing
    /// off, 8-bit bytes, MIN=0/TIME=1 (poll with 0.1s timeout). Pure —
    /// unit-testable without a tty.
    fn rawTermios(orig: posix.termios) posix.termios {
        var raw = orig;

        // Input flags: disable various input processing
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;

        // Output flags: disable output processing
        raw.oflag.OPOST = false;

        // Control flags: 8-bit characters
        raw.cflag.CSIZE = .CS8;

        // Local flags: disable echo, canonical mode, signals, extended input
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;

        // Control characters: read with 0.1s timeout
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 1;

        return raw;
    }

    fn handleWinch(_: posix.SIG) callconv(.c) void {
        resize_signaled.store(true, .release);
    }

    /// Async-signal-safe cleanup for SIGTERM/SIGINT: restore the termios
    /// captured by makeRaw and write the minimal mode disables, then exit
    /// with 128+signal. A killed process never runs its defers, so without
    /// this a `kill` leaves the terminal raw with the cursor hidden and
    /// kitty keyboard enabled. Best-effort: tcsetattr/write only touch
    /// async-signal-safe-ish paths, and failure still exits.
    fn handleTermSignal(sig: posix.SIG) callconv(.c) void {
        restoreTerminal();
        std.process.exit(@intCast(128 + @intFromEnum(sig)));
    }

    /// Reset the signal handlers to their defaults (libvaxis
    /// resetSignalHandlerLocked pattern).
    fn resetSignalHandler() void {
        if (handler_installed) {
            handler_installed = false;
            const act: posix.Sigaction = .{
                .handler = .{ .handler = posix.SIG.DFL },
                .mask = posix.sigemptyset(),
                .flags = 0,
            };
            posix.sigaction(posix.SIG.WINCH, &act, null);
        }
        if (term_signal_cleanup_installed) {
            term_signal_cleanup_installed = false;
            const act: posix.Sigaction = .{
                .handler = .{ .handler = posix.SIG.DFL },
                .mask = posix.sigemptyset(),
                .flags = 0,
            };
            posix.sigaction(posix.SIG.TERM, &act, null);
            posix.sigaction(posix.SIG.INT, &act, null);
        }
    }
};

test {
    std.testing.refAllDecls(@This());
}

/// A pipe pair used as the transport plus the reader that decides when
/// to drain it. `NONBLOCK` is the flag the real transport is opened
/// with, so the EAGAIN these tests observe comes from the kernel and
/// not from a counter standing in for it.
const PipePair = struct {
    read: std.Io.File,
    write: std.Io.File,

    fn init(flags: posix.O) !PipePair {
        const fds = try std.Io.Threaded.pipe2(flags);
        const nonblocking = flags.NONBLOCK;
        return .{
            .read = .{ .handle = fds[0], .flags = .{ .nonblocking = nonblocking } },
            .write = .{ .handle = fds[1], .flags = .{ .nonblocking = nonblocking } },
        };
    }

    fn deinit(self: *PipePair) void {
        self.read.close(std.testing.io);
        self.write.close(std.testing.io);
        self.* = undefined;
    }
};

/// A PTY pair opened headlessly. The master stays open for the whole
/// test — a slave whose master vanished reports EIO instead of
/// EAGAIN — and the slave path is kept in the struct so a test can
/// open the transport on it with the production open flags.
const PtyPair = struct {
    master: std.Io.File,
    slave: std.Io.File,
    path_buf: [32]u8 = undefined,
    path_len: usize = 0,

    /// `null` where a PTY cannot be allocated — headless hosts skip
    /// rather than fail.
    fn init(io: std.Io) ?PtyPair {
        const master = std.Io.Dir.openFileAbsolute(io, "/dev/ptmx", .{ .mode = .read_write }) catch
            return null;
        errdefer master.close(io);

        var unlock: c_int = 0;
        if (posix.errno(posix.system.ioctl(
            master.handle,
            ioctlReq(posix.T.IOCSPTLCK),
            @intFromPtr(&unlock),
        )) != .SUCCESS) return null;

        var ptn: c_uint = 0;
        if (posix.errno(posix.system.ioctl(
            master.handle,
            ioctlReq(posix.T.IOCGPTN),
            @intFromPtr(&ptn),
        )) != .SUCCESS) return null;

        // `slave` is assigned only on success: an errdefer here would
        // close an undefined handle on the two bail-outs below.
        var self: PtyPair = .{ .master = master, .slave = undefined };
        const slave_path = std.fmt.bufPrint(self.path_buf[0..], "/dev/pts/{d}", .{ptn}) catch
            return null;
        self.path_len = slave_path.len;
        self.slave = std.Io.Dir.openFileAbsolute(io, slave_path, .{ .mode = .read_write }) catch
            return null;
        return self;
    }

    fn path(self: *const PtyPair) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    fn deinit(self: *PtyPair) void {
        self.slave.close(std.testing.io);
        self.master.close(std.testing.io);
        self.* = undefined;
    }
};

/// A stand-in for the read/write `/dev/tty` in tests that only care
/// about the transport. Opened blocking, exactly as `init` opens it.
fn blockingFile(io: std.Io) !std.Io.File {
    return std.Io.Dir.openFileAbsolute(io, "/dev/null", .{ .mode = .read_write });
}

/// Write `chunk` through `tty` until the transport refuses. `false`
/// means the transport took every byte it was offered, which for a
/// real descriptor nobody drained means the descriptor is blocking.
fn fillUntilBlocked(tty: *Tty, chunk: []const u8) !bool {
    var guard: usize = 0;
    while (guard < 512) : (guard += 1) {
        if (try tty.tryWrite(chunk) == 0) return true;
    }
    return false;
}

test "tty: rawTermios clears input processing, sets MIN/TIME" {
    var orig = std.mem.zeroes(posix.termios);
    // a cooked-state termios
    orig.iflag.BRKINT = true;
    orig.iflag.ICRNL = true;
    orig.iflag.INPCK = true;
    orig.iflag.ISTRIP = true;
    orig.iflag.IXON = true;
    orig.oflag.OPOST = true;
    orig.cflag.CSIZE = .CS7;
    orig.lflag.ECHO = true;
    orig.lflag.ICANON = true;
    orig.lflag.IEXTEN = true;
    orig.lflag.ISIG = true;
    orig.lflag.NOFLSH = true; // must survive — rawTermios copies, not zeroes
    orig.cc[@intFromEnum(posix.V.MIN)] = 17;
    orig.cc[@intFromEnum(posix.V.TIME)] = 0;

    const raw = Tty.rawTermios(orig);

    // input processing off
    try std.testing.expect(!raw.iflag.BRKINT);
    try std.testing.expect(!raw.iflag.ICRNL);
    try std.testing.expect(!raw.iflag.INPCK);
    try std.testing.expect(!raw.iflag.ISTRIP);
    try std.testing.expect(!raw.iflag.IXON);
    // output processing off
    try std.testing.expect(!raw.oflag.OPOST);
    // 8-bit bytes
    try std.testing.expect(raw.cflag.CSIZE == .CS8);
    // local flags off
    try std.testing.expect(!raw.lflag.ECHO);
    try std.testing.expect(!raw.lflag.ICANON);
    try std.testing.expect(!raw.lflag.IEXTEN);
    try std.testing.expect(!raw.lflag.ISIG);
    // untouched fields preserved
    try std.testing.expect(raw.lflag.NOFLSH);
    // MIN=0/TIME=1
    try std.testing.expectEqual(@as(u8, 0), raw.cc[@intFromEnum(posix.V.MIN)]);
    try std.testing.expectEqual(@as(u8, 1), raw.cc[@intFromEnum(posix.V.TIME)]);
}

test "tty: isTty is false for a regular file" {
    const io = std.testing.io;
    const f = try std.Io.Dir.openFileAbsolute(io, "/dev/null", .{ .mode = .read_write });
    defer f.close(io);
    try std.testing.expect(!Tty.isTty(f.handle));
}

test "tty: getWinsize falls back to 80x24 on ioctl error" {
    const io = std.testing.io;
    const f = try std.Io.Dir.openFileAbsolute(io, "/dev/null", .{ .mode = .read_write });
    defer f.close(io);
    var tty: Tty = .{ .io = io, .fd = f };
    const ws = try tty.getWinsize();
    try std.testing.expectEqual(@as(u16, 80), ws.cols);
    try std.testing.expectEqual(@as(u16, 24), ws.rows);
    try std.testing.expectEqual(@as(u16, 0), ws.x_pixel);
    try std.testing.expectEqual(@as(u16, 0), ws.y_pixel);
}

test "tty: checkResize drains the SIGWINCH flag" {
    const io = std.testing.io;
    const f = try std.Io.Dir.openFileAbsolute(io, "/dev/null", .{ .mode = .read_write });
    defer f.close(io);
    var tty: Tty = .{ .io = io, .fd = f };

    _ = resize_signaled.swap(false, .acquire); // clear any prior signal
    try std.testing.expect(!tty.checkResize());
    resize_signaled.store(true, .release);
    try std.testing.expect(tty.checkResize());
    try std.testing.expect(!tty.checkResize()); // drained
}

test "tty: makeRaw/restore round-trip on a real PTY pair" {
    // Skip (not fail) when a PTY cannot be opened — headless-safe.
    const io = std.testing.io;
    var pty = PtyPair.init(io) orelse return;
    defer pty.deinit();

    var tty: Tty = .{ .io = io, .fd = pty.slave };
    const before = posix.tcgetattr(pty.slave.handle) catch return;

    try tty.makeRaw();
    const during = posix.tcgetattr(pty.slave.handle) catch return;
    try std.testing.expect(!during.lflag.ECHO);
    try std.testing.expect(!during.lflag.ICANON);
    try std.testing.expect(!during.lflag.ISIG);
    try std.testing.expect(!during.lflag.IEXTEN);
    try std.testing.expect(!during.iflag.IXON);
    try std.testing.expectEqual(@as(u8, 0), during.cc[@intFromEnum(posix.V.MIN)]);
    try std.testing.expectEqual(@as(u8, 1), during.cc[@intFromEnum(posix.V.TIME)]);

    tty.restore();
    const after = posix.tcgetattr(pty.slave.handle) catch return;
    try std.testing.expectEqual(before.iflag, after.iflag);
    try std.testing.expectEqual(before.oflag, after.oflag);
    try std.testing.expectEqual(before.cflag, after.cflag);
    try std.testing.expectEqual(before.lflag, after.lflag);
    try std.testing.expectEqual(before.cc, after.cc);
}

test "tty: tryWrite without a transport fails instead of falling back to fd" {
    const io = std.testing.io;
    var tty: Tty = .{ .io = io, .fd = try blockingFile(io) };
    defer tty.fd.close(io);

    // `fd` is open for writing and would swallow these bytes, but it is
    // blocking: taking them there is the stall the transport seam
    // exists to prevent, so the refusal is the honest answer.
    try std.testing.expectError(error.WriteFailed, tty.tryWrite("\x1b[?25h"));
}

test "tty: the transport is nonblocking while the input descriptor stays blocking" {
    const io = std.testing.io;
    var input = try PipePair.init(.{}); // blocking, as /dev/tty is
    defer input.deinit();
    var transport = try PipePair.init(.{ .NONBLOCK = true });
    defer transport.deinit();

    var tty: Tty = .{ .io = io, .fd = input.read, .out = transport.write };

    // Two descriptors, and only the transport carries O_NONBLOCK: the
    // read/write descriptor input depends on was never touched.
    try std.testing.expect(tty.fd.handle != tty.out.?.handle);
    try std.testing.expect(!isNonblocking(tty.fd.handle));
    try std.testing.expect(isNonblocking(tty.out.?.handle));

    // Proof the input side is not in nonblocking mode: it reads the
    // byte it was handed instead of failing with EAGAIN.
    try input.write.writeStreamingAll(io, "z");
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try tty.read(&buf));
    try std.testing.expectEqual(@as(u8, 'z'), buf[0]);
}

test "tty: a full pipe transport reports would-block instead of blocking" {
    const io = std.testing.io;
    var transport = try PipePair.init(.{ .NONBLOCK = true });
    defer transport.deinit();
    var tty: Tty = .{ .io = io, .fd = try blockingFile(io), .out = transport.write };
    defer tty.fd.close(io);

    // Nobody drains the read end, so the kernel buffer fills. A
    // blocking descriptor would have parked the loop right here.
    try std.testing.expect(try fillUntilBlocked(&tty, "x" ** 4096));
    // The refusal is repeatable and consumes nothing: the frame is
    // still the caller's to retry.
    try std.testing.expectEqual(@as(usize, 0), try tty.tryWrite("x" ** 4096));
    try std.testing.expectEqual(@as(usize, 0), try tty.tryWrite("x"));
}

test "tty: a full terminal transport reports would-block instead of blocking" {
    const io = std.testing.io;
    var pty = PtyPair.init(io) orelse return; // headless-safe
    defer pty.deinit();

    // Opened through the production helper, so this exercises the real
    // flags against a real terminal instead of a pipe.
    const transport = (try openNonblockingWrite(pty.path())) orelse return;
    defer transport.close(io);
    var tty: Tty = .{ .io = io, .fd = pty.slave, .out = transport };

    // The master end is open but unread, so the tty's output buffer
    // fills and the descriptor reports EAGAIN.
    try std.testing.expect(try fillUntilBlocked(&tty, "x" ** 4096));
    try std.testing.expectEqual(@as(usize, 0), try tty.tryWrite("x" ** 4096));
}

test "tty: a short transport write keeps the frame's bytes in order" {
    const io = std.testing.io;
    var transport = try PipePair.init(.{ .NONBLOCK = true });
    defer transport.deinit();
    var tty: Tty = .{ .io = io, .fd = try blockingFile(io), .out = transport.write };
    defer tty.fd.close(io);

    // 256 KiB: several times a default 64 KiB pipe, so the transport
    // is guaranteed to run dry mid-frame and defer the remainder.
    const frame = "0123456789abcdef" ** 16384;
    var q = try output.OutputQueue.init(std.testing.allocator, .{
        .capacity = frame.len,
        .watermark = 1024,
    });
    defer q.deinit();

    q.beginFrame();
    try q.writer().writeAll(frame);
    try std.testing.expect(!q.frameOverflowed());
    q.commitFrame();
    try std.testing.expectEqual(frame.len, q.pending());

    // Draining without a reader fills the pipe and stops; the rest
    // stays pending rather than being dropped.
    var guard: usize = 0;
    while (try q.drain(&tty) > 0) {
        guard += 1;
        try std.testing.expect(guard < 64);
    }
    try std.testing.expect(q.pending() > 0);

    // The reader drains: every deferred byte arrives exactly once, in
    // order, and the queue empties without anything being rewritten.
    var delivered: usize = 0;
    var buf: [4096]u8 = undefined;
    while (delivered < frame.len) {
        const got = transport.read.readStreaming(io, &.{&buf}) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        if (got == 0) {
            _ = try q.drain(&tty); // first: refill what the reader freed
            continue;
        }
        try std.testing.expectEqualSlices(u8, frame[delivered..][0..got], buf[0..got]);
        delivered += got;
    }
    try std.testing.expectEqual(@as(usize, 0), q.pending());
    try std.testing.expectEqual(frame.len, q.total_written);
}

test "tty: deinit closes the read/write descriptor and the transport" {
    const io = std.testing.io;
    const fds = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true });
    var tty: Tty = .{
        .io = io,
        .fd = .{ .handle = fds[0], .flags = .{ .nonblocking = true } },
        .out = .{ .handle = fds[1], .flags = .{ .nonblocking = true } },
    };
    const read_handle = tty.fd.handle;
    const write_handle = tty.out.?.handle;

    // Ownership is the Tty's: it closes both, the second descriptor
    // included. Nothing else holds them.
    tty.deinit();
    try std.testing.expect(isClosed(read_handle));
    try std.testing.expect(isClosed(write_handle));
}

test "tty: the transport open reports its failure instead of degrading" {
    // ENOTDIR: /dev/null is not a directory. `init` relies on this
    // propagating so it can close the read/write descriptor and leave
    // no half-built Tty behind.
    try std.testing.expectError(error.NotDir, openNonblockingWrite("/dev/null/nope"));
}

test "tty: restoreTerminal re-enables autowrap before the cursor and sync close" {
    if (builtin.os.tag != .linux) return; // the raw cleanup write is Linux-only
    const io = std.testing.io;
    const fds = try std.Io.Threaded.pipe2(.{});
    const reader: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    defer reader.close(io);

    const tty: Tty = .{ .io = io, .fd = .{ .handle = fds[1], .flags = .{ .nonblocking = false } } };
    defer tty.fd.close(io);
    global_tty = tty;
    defer global_tty = null;

    // A kill or a panic lands mid-frame, where DECAWM may still be
    // off. The restore re-enables it first, then shows the cursor,
    // pops the kitty keyboard and closes sync output.
    restoreTerminal();

    var buf: [32]u8 = undefined;
    const n = try reader.readStreaming(io, &.{&buf});
    try std.testing.expectEqualStrings("\x1b[?7h\x1b[?25h\x1b[<u\x1b[?2026l", buf[0..n]);
}
