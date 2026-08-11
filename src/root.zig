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

test "width: ascii, emoji, grapheme (zg DisplayWidth)" {
    const DisplayWidth = @import("DisplayWidth");
    try std.testing.expectEqual(@as(usize, 5), DisplayWidth.strWidth("Hello"));
    try std.testing.expectEqual(@as(usize, 8), DisplayWidth.strWidth("Hello 😊"));
    try std.testing.expectEqual(@as(isize, 2), DisplayWidth.graphemeWidth("👨‍🌾"));
}

test "graphemes: combining mark joins base (zg Graphemes)" {
    const Graphemes = @import("Graphemes");
    const src = "He\u{301}";
    var iter = Graphemes.iterator(src);
    try std.testing.expect(iter.next().?.len == 1);
    const base_plus_mark = iter.next().?;
    try std.testing.expect(base_plus_mark.len == 3);
    try std.testing.expectEqualStrings("e\u{301}", base_plus_mark.bytes(src));
    try std.testing.expect(iter.next() == null);
}
