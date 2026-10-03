//! The decoded-input surface: what `Parser` produces and an application
//! switches on.
//!
//! Every tag is self-contained — no tag borrows from the parser's input —
//! except `paste`, whose ownership depends on which route produced it (see
//! `Event.paste`).

pub const Key = @import("Key.zig");
pub const Mouse = @import("Mouse.zig");
pub const Color = @import("color.zig").Color;

/// A cursor position report (CSI `row`;`col` R), 1-indexed per the DEC
/// convention: the top-left cell is `row = 1`, `col = 1`.
pub const Pos = struct {
    row: u16,
    col: u16,
};

/// The screen size in cells, with the pixel size when the terminal reports
/// one. `x_pixel` and `y_pixel` are 0 when it does not.
pub const Winsize = struct {
    rows: u16,
    cols: u16,
    x_pixel: u16,
    y_pixel: u16,
};

/// A terminal capability confirmed by a live query reply, rather than
/// assumed from an environment variable.
///
/// Declared here rather than in `caps` so the parser does not depend on it.
pub const Capability = enum {
    /// Progressive enhancement keys (the CSI `u` form).
    kitty_keyboard,
    /// The APC-G graphics protocol answered an `i=9931` query.
    kitty_graphics,
    /// Mouse position in pixels (SGR 1016).
    sgr_pixels,
    /// Bracketed paste wrapping (CSI 2004).
    bracketed_paste,
    /// Synchronized output (CSI 2026).
    sync_output,
    /// Unicode Core version reporting (CSI 2027).
    unicode_core,
    /// Direct colour (SGR `38;2`).
    rgb,
    /// Focus change reporting (CSI 1004).
    focus_events,
};

/// One decoded input event. Nothing in the union borrows the parser's input
/// buffer, so an event may outlive the bytes it was decoded from; the two
/// borrowed payloads a caller has to respect are `Key.text` (valid until the
/// next `Parser.parse`) and the `paste` bytes.
pub const Event = union(enum) {
    /// A key went down. `Key.text`, when set, borrows the parser's scratch
    /// buffer or its input; see `Key.text`.
    key_press: Key,
    /// A key came up; only reported when the terminal has key-event
    /// reporting enabled.
    key_release: Key,
    mouse: Mouse,
    /// The terminal gained input focus.
    focus_in,
    /// The terminal lost input focus.
    focus_out,
    /// The clipboard contents (OSC 52), base64-decoded.
    ///
    /// Ownership depends on who called `parse`. Through `Parser.parse` with a
    /// caller-supplied allocator, the bytes are allocated from that allocator
    /// and the receiver owns them and must free them with the same allocator.
    /// Through `input.Reader`, the allocator is a fixed buffer the reader
    /// reuses per read: the bytes borrow it, must NOT be freed, and are only
    /// valid until the next `next` or `nextTimeout` call.
    paste: []const u8,
    /// The terminal's answer to an OSC 4, 10, 11 or 12 colour query.
    color_report: Color.Report,
    /// The screen changed size, reported in-band by the terminal.
    winsize: Winsize,
    /// A cursor position report, the answer to a `CSI 6n` query.
    cpr: Pos,
    /// A terminal capability confirmed by a query reply.
    cap: Capability,
};

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
