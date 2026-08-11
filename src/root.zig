//! notui library root.

const std = @import("std");

/// Package version, mirrored from build.zig.zon.
pub const version = "0.0.0";

test {
    std.testing.refAllDecls(@This());
}

test "version: non-empty and semver-shaped" {
    try std.testing.expect(version.len > 0);
    try std.testing.expectEqual(@as(u8, '0'), version[0]);
}
