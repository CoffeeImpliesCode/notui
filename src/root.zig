//! Inline-first terminal UI toolkit for native Zig 0.16 consumers.
//!
//! Register the package's `notui` module, then import this root. Its namespaces expose
//! drawing primitives, components, the app loop, and explicit testing/inspection helpers.
//! `app.App(Model)` owns terminal lifecycle; `buffer.Buffer` and `region.Region` let a
//! caller own its loop and transport. Initialize storage owners, register one `deinit`,
//! draw borrowed text, and render before releasing those borrows.
//!
//! This root does not publish a C ABI or transitively expose dependency import names.
//! Formula rendering is a separate registered family: `ztex`, `ztex.atom`, `ztex.parse`,
//! `ztex.layout`, and `ztex.svg`. Pure drawing is transport-independent; terminal,
//! input, and capture helpers require native POSIX descriptors and a compatible live `Io`.

const std = @import("std");

/// Package version, mirrored from build.zig.zon.
pub const version = "0.1.0";

/// The zg seam — the only module allowed to import zg.
pub const width = @import("width.zig");

pub const color = @import("color.zig");
pub const style = @import("style.zig");
pub const cell = @import("cell.zig");
pub const emit = @import("emit.zig");
pub const event = @import("event.zig");
pub const key = @import("Key.zig");
pub const mouse = @import("Mouse.zig");
pub const parser = @import("Parser.zig");
pub const tty = @import("tty.zig");
pub const caps = @import("caps.zig");
pub const coverage = @import("coverage.zig");
pub const image = @import("image.zig");
pub const buffer = @import("buffer.zig");
pub const region = @import("region.zig");
pub const input = @import("input.zig");
pub const component = @import("component/root.zig");
pub const context = @import("context.zig");
pub const command = @import("command.zig");
pub const view = @import("view.zig");
pub const app = @import("app.zig");
pub const keybindings = @import("keybindings.zig");
pub const markdown = @import("markdown.zig");
pub const theme = @import("theme.zig");
pub const watchdog = @import("watchdog.zig");
pub const debug_server = @import("debug_server.zig");
pub const frame_testing = @import("testing/frame.zig");
pub const output = @import("output.zig");
pub const transcript = @import("transcript.zig");

test {
    _ = @import("testing/native_resize.zig");
    std.testing.refAllDecls(@This());
}
