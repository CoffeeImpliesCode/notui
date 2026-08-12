//! Raw-mode terminal: /dev/tty input, std.Io output, SIGWINCH resize
//! flag, panic-restore global.
//!
//! Adapted from zigzag `terminal/platform/posix.zig` (raw mode, isTty,
//! SIGWINCH flag, poll) and libvaxis `tty.zig` (winsize, panic-restore
//! global, /dev/tty open). zigzag's fd-based state is replaced with the
//! §5 std.Io-threaded handle; the notifyWinsize callback registry is
//! dropped — v0 uses one atomic flag (the single sanctioned global, plan
//! §0). Windows paths are not copied (deferred to v1).

const std = @import("std");
const posix = std.posix;
const Winsize = @import("event.zig").Winsize;

/// SIGWINCH resize flag — the single sanctioned global (plan §0), set by
/// the signal handler, drained by `Tty.checkResize`.
var resize_signaled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Whether the SIGWINCH handler is installed (one Tty at a time in v0).
var handler_installed: bool = false;

/// Global tty instance for panic restore. Not guaranteed to work with
/// multiple Tty instances under one compilation unit, but better than
/// nothing (libvaxis pattern). `makeRaw` keeps the copy's termios in
/// sync so a panic handler can restore even when raw mode is entered
/// after init.
pub var global_tty: ?Tty = null;

pub const Tty = struct {
    /// The Io the tty is threaded onto (output, clock).
    io: std.Io,
    /// The /dev/tty file descriptor (input, termios, ioctl).
    fd: std.Io.File,

    /// Original termios captured by makeRaw; restored by restore/deinit.
    original_termios: ?posix.termios = null,
    in_raw_mode: bool = false,

    /// Streaming writer over `fd`, built lazily on the first `writer()`
    /// call so the internal buffer lives at the instance's stable address
    /// (init returns by value).
    tty_writer: ?std.Io.File.Writer = null,
    write_buf: [4096]u8 = undefined,

    /// Open /dev/tty for input and install the SIGWINCH handler. Raw mode
    /// is NOT entered — call `makeRaw` explicitly (event-loop order:
    /// init → makeRaw → Caps.detect).
    pub fn init(io: std.Io) !Tty {
        var f = try std.Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write });
        errdefer f.close(io);

        if (!handler_installed) {
            const handler: posix.Sigaction = .{
                .handler = .{ .handler = handleWinch },
                .mask = posix.sigemptyset(),
                .flags = 0,
            };
            posix.sigaction(posix.SIG.WINCH, &handler, null);
            handler_installed = true;
        }

        const self: Tty = .{
            .io = io,
            .fd = f,
        };
        global_tty = self;
        return self;
    }

    /// Restore the terminal, uninstall the signal handler, close /dev/tty.
    pub fn deinit(self: *Tty) void {
        if (global_tty) |*g| {
            if (g.fd.handle == self.fd.handle) global_tty = null;
        }
        self.restore();
        resetSignalHandler();
        self.fd.close(self.io);
        self.* = undefined;
    }

    /// Check if a file descriptor is a tty by probing for terminal window
    /// size (TIOCGWINSZ ioctl — only granted to terminal devices; replaces
    /// posix.isatty, removed in Zig 0.16).
    pub fn isTty(fd: posix.fd_t) bool {
        var wsz: posix.winsize = undefined;
        return posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&wsz)) == 0;
    }

    /// Enter raw mode: save the original termios, apply `rawTermios`.
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

    /// Restore the original termios captured by makeRaw. Idempotent.
    pub fn restore(self: *Tty) void {
        if (!self.in_raw_mode) return;
        if (self.original_termios) |termios| {
            posix.tcsetattr(self.fd.handle, .FLUSH, termios) catch |err| {
                std.log.scoped(.notui_tty).err("couldn't restore terminal: {}", .{err});
            };
        }
        self.in_raw_mode = false;
    }

    /// Window size via TIOCGWINSZ. On ioctl error (or a zero-sized
    /// report) falls back to 80x24 — graceful, never a hard throw for
    /// width (plan §8.8).
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

    /// True when a SIGWINCH arrived since the last check (atomic flag
    /// swap; no threads in v0).
    pub fn checkResize(self: *Tty) bool {
        _ = self;
        return resize_signaled.swap(false, .acquire);
    }

    /// The buffered output writer. Created once against the instance's
    /// internal buffer; the instance must not move afterwards.
    pub fn writer(self: *Tty) *std.Io.Writer {
        if (self.tty_writer == null) {
            self.tty_writer = self.fd.writerStreaming(self.io, self.write_buf[0..]);
        }
        return &self.tty_writer.?.interface;
    }

    /// Blocking read from the tty.
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

    /// Reset the SIGWINCH handler to its default (libvaxis
    /// resetSignalHandlerLocked pattern).
    fn resetSignalHandler() void {
        if (!handler_installed) return;
        handler_installed = false;
        const act: posix.Sigaction = .{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.WINCH, &act, null);
    }
};

test {
    std.testing.refAllDecls(@This());
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

    const master = std.Io.Dir.openFileAbsolute(io, "/dev/ptmx", .{ .mode = .read_write }) catch return;
    defer master.close(io);

    var unlock: c_int = 0;
    if (posix.errno(posix.system.ioctl(master.handle, posix.T.IOCSPTLCK, @intFromPtr(&unlock))) != .SUCCESS) return;

    var ptn: c_uint = 0;
    if (posix.errno(posix.system.ioctl(master.handle, posix.T.IOCGPTN, @intFromPtr(&ptn))) != .SUCCESS) return;

    var pts_path_buf: [32]u8 = undefined;
    const pts_path = std.fmt.bufPrint(&pts_path_buf, "/dev/pts/{d}", .{ptn}) catch return;
    const slave = std.Io.Dir.openFileAbsolute(io, pts_path, .{ .mode = .read_write }) catch return;
    defer slave.close(io);

    var tty: Tty = .{ .io = io, .fd = slave };
    const before = posix.tcgetattr(slave.handle) catch return;

    try tty.makeRaw();
    const during = posix.tcgetattr(slave.handle) catch return;
    try std.testing.expect(!during.lflag.ECHO);
    try std.testing.expect(!during.lflag.ICANON);
    try std.testing.expect(!during.lflag.ISIG);
    try std.testing.expect(!during.lflag.IEXTEN);
    try std.testing.expect(!during.iflag.IXON);
    try std.testing.expectEqual(@as(u8, 0), during.cc[@intFromEnum(posix.V.MIN)]);
    try std.testing.expectEqual(@as(u8, 1), during.cc[@intFromEnum(posix.V.TIME)]);

    tty.restore();
    const after = posix.tcgetattr(slave.handle) catch return;
    try std.testing.expectEqual(before.iflag, after.iflag);
    try std.testing.expectEqual(before.oflag, after.oflag);
    try std.testing.expectEqual(before.cflag, after.cflag);
    try std.testing.expectEqual(before.lflag, after.lflag);
    try std.testing.expectEqual(before.cc, after.cc);
}
