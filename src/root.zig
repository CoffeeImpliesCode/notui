//! notui library root.

const std = @import("std");

/// Package version, mirrored from build.zig.zon.
pub const version = "0.0.0";

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
// base-ui presentation layer: components compose against any Buffer.
pub const component = @import("component/root.zig");
// app-framework layer. app.zig re-exports App/View/Cmd/Context.
pub const context = @import("context.zig");
pub const command = @import("command.zig");
pub const view = @import("view.zig");
pub const app = @import("app.zig");

test {
    std.testing.refAllDecls(@This());
}
