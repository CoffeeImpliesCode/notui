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
// buffer.zig lands in P4 (parallel round B) — the re-export line is added
// now so the module root is stable once both phases land.
pub const buffer = @import("buffer.zig");
// region.zig (P5) and input.zig (P6) land in parallel round C — both
// re-export lines are added now so the module root is stable once both
// phases land.
pub const region = @import("region.zig");
pub const input = @import("input.zig");
// base-ui presentation layer (P8) — see notes/research/baseui-contract.md.
pub const component = @import("component/root.zig");
// app-framework layer (P9) — see notes/research/framework-contract.md.
// app.zig re-exports the framework surface (App/Context/View/Cmd).
pub const context = @import("context.zig");
pub const command = @import("command.zig");
pub const view = @import("view.zig");
pub const app = @import("app.zig");

test {
    std.testing.refAllDecls(@This());
}

test "version: non-empty and semver-shaped" {
    try std.testing.expect(version.len > 0);
    try std.testing.expectEqual(@as(u8, '0'), version[0]);
}
