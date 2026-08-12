//! Input event types: the payloads the parser decodes and apps switch on.
//! Adapted from libvaxis event.zig: `cpr` replaces the out-of-band shift+F3
//! CPR decode trick (architecture §3), the eight individual `cap_*` tags
//! collapse into one `cap: Capability`, and paste_start/paste_end/mouse_leave/
//! color_scheme are dropped (not in architecture §5).

pub const Key = @import("Key.zig");
pub const Mouse = @import("Mouse.zig");
pub const Color = @import("color.zig").Color;

/// The terminal's cursor position, 1-indexed per the DEC CPR convention.
/// Decoded from a Cursor Position Report reply (CSI {row};{col} R).
pub const Pos = struct {
    row: u16,
    col: u16,
};

/// The size of the terminal screen
pub const Winsize = struct {
    rows: u16,
    cols: u16,
    x_pixel: u16,
    y_pixel: u16,
};

/// A terminal capability discovered from a live query reply. Defined here
/// (not in caps.zig) to keep the import DAG acyclic: parser → event,
/// caps → parser + event.
pub const Capability = enum {
    kitty_keyboard,
    sgr_pixels,
    bracketed_paste,
    sync_output,
    unicode_core,
    rgb,
    focus_events,
};

/// The events that notui emits from decoded input
pub const Event = union(enum) {
    key_press: Key,
    key_release: Key,
    mouse: Mouse,
    focus_in,
    focus_out,
    paste: []const u8, // osc 52 paste, caller must free
    color_report: Color.Report, // osc 4, 10, 11, 12 response
    winsize: Winsize,

    // the inline-anchoring divergence: a CPR reply is its own event
    cpr: Pos,

    // discovered terminal capabilities
    cap: Capability,
};

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
