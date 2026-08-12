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
pub const key = @import("key.zig");
pub const mouse = @import("mouse.zig");
pub const parser = @import("parser.zig");

test {
    std.testing.refAllDecls(@This());
}

test "version: non-empty and semver-shaped" {
    try std.testing.expect(version.len > 0);
    try std.testing.expectEqual(@as(u8, '0'), version[0]);
}
