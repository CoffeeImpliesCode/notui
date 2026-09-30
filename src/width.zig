//! width.zig — the zg seam.
//!
//! Sole zg import site in the library (plan §0 grep-gate, architecture §2):
//! every `@import("zg")`, `@import("DisplayWidth")`, and
//! `@import("Graphemes")` lives in this file. Everything else gets width
//! and grapheme knowledge through the functions below.

const std = @import("std");

const zg = @import("zg");
const DisplayWidth = @import("DisplayWidth");
const Graphemes = @import("Graphemes");

/// Display width of `str` in terminal cells. Delegates to zg DisplayWidth.
pub fn strWidth(str: []const u8) usize {
    return DisplayWidth.strWidth(str);
}

/// Display width of one grapheme cluster `gc` in terminal cells.
/// Delegates to zg DisplayWidth.
pub fn graphemeWidth(gc: []const u8) isize {
    return DisplayWidth.graphemeWidth(gc);
}

/// Wrap `str` to `columns` cells: a word is pushed to the next line when
/// the remaining space on the current line would drop to `threshold` or
/// below. Delegates to zg DisplayWidth. Caller frees the returned slice.
pub fn wrap(
    allocator: std.mem.Allocator,
    str: []const u8,
    columns: usize,
    threshold: usize,
) ![]u8 {
    // zg's wrap indexes `items.len - 1` on an empty result, which panics
    // on empty input; hand the empty string back instead.
    if (str.len == 0) return allocator.dupe(u8, "");
    return DisplayWidth.wrap(allocator, str, columns, threshold);
}

/// Byte length of the FIRST grapheme cluster in `str`; 0 for empty input.
///
/// Parser seam (plan T2.3): parser.zig must know how many bytes a single
/// grapheme occupies in ground-state input, but the grep-gate seals zg
/// imports to this module — the parser asks here instead of importing
/// Graphemes itself.
pub fn firstGraphemeLen(str: []const u8) usize {
    var iter = Graphemes.iterator(str);
    const g = iter.next() orelse return 0;
    return g.bytes(str).len;
}

/// Simple (single-codepoint) uppercase mapping for `cp`. Delegates to
/// zg LetterCasing, whose tables are comptime-generated: no allocation
/// and no runtime case-data loading. Codepoints whose full mapping
/// expands to several codepoints (ß → SS) have no simple mapping and
/// come back unchanged.
pub fn toUpper(cp: u21) u21 {
    return zg.letter_casing.toUpper(cp);
}

/// Truncate `str` to at most `columns` terminal cells, cutting only at
/// grapheme boundaries. Never errors on width: returns the longest prefix
/// that fits, possibly empty. Caller frees the returned slice.
pub fn truncate(
    allocator: std.mem.Allocator,
    str: []const u8,
    columns: usize,
) ![]u8 {
    var width: usize = 0;
    var end: usize = 0;

    // zg's iterator hands out a contiguous partition of `str`: the
    // first cluster starts at 0 and each one starts where the last
    // ended, so the running sum of cluster lengths is the end offset
    // of the cluster just read. `end` stays usize throughout, and zg's
    // u32 offsets never have to be widened.
    var iter = Graphemes.iterator(str);
    while (iter.next()) |g| {
        const gc = g.bytes(str);
        const w = DisplayWidth.graphemeWidth(gc);
        // Zero-width (combining marks) and negative-width (control)
        // clusters never advance the column; keep them glued on.
        if (w <= 0) {
            end += gc.len;
            continue;
        }
        const wu: usize = @intCast(w);
        if (width + wu > columns) break;
        width += wu;
        end += gc.len;
    }

    return allocator.dupe(u8, str[0..end]);
}

// ── zg smoke tests, moved from src/root.zig (T0.1) ─────────

test "width: ascii, emoji, grapheme (zg DisplayWidth)" {
    try std.testing.expectEqual(@as(usize, 5), strWidth("Hello"));
    try std.testing.expectEqual(@as(usize, 8), strWidth("Hello 😊"));
    try std.testing.expectEqual(@as(isize, 2), graphemeWidth("👨‍🌾"));
}

test "graphemes: combining mark joins base (zg Graphemes)" {
    const src = "He\u{301}";
    var iter = Graphemes.iterator(src);
    try std.testing.expect(iter.next().?.len == 1);
    const base_plus_mark = iter.next().?;
    try std.testing.expect(base_plus_mark.len == 3);
    try std.testing.expectEqualStrings("e\u{301}", base_plus_mark.bytes(src));
    try std.testing.expect(iter.next() == null);
}

// ── strWidth ─────────────────────────────────

test "strWidth: ascii" {
    try std.testing.expectEqual(@as(usize, 5), strWidth("Hello"));
}

test "strWidth: emoji" {
    try std.testing.expectEqual(@as(usize, 8), strWidth("Hello 😊"));
}

test "strWidth: ZWJ family is one wide grapheme" {
    try std.testing.expectEqual(@as(usize, 2), strWidth("👨‍🌾"));
    try std.testing.expectEqual(@as(usize, 2), strWidth("👩‍🔬"));
}

// ── graphemeWidth ────────────────────────────────

test "graphemeWidth: ZWJ family" {
    try std.testing.expectEqual(@as(isize, 2), graphemeWidth("👨‍🌾"));
}

test "graphemeWidth: combining mark cluster" {
    try std.testing.expectEqual(@as(isize, 1), graphemeWidth("e\u{301}"));
}

// ── wrap ───────────────────────────────────

test "wrap: word crossing threshold wraps" {
    const allocator = std.testing.allocator;
    const input = "The quick brown fox\r\njumped over the lazy dog!";
    const got = try wrap(allocator, input, 10, 3);
    defer allocator.free(got);
    try std.testing.expectEqualStrings("The quick \nbrown fox \njumped \nover the \nlazy dog!", got);
}

test "wrap: long unbreakable word stays on one line" {
    const allocator = std.testing.allocator;
    const got = try wrap(allocator, "supercalifragilistic", 10, 1);
    defer allocator.free(got);
    try std.testing.expectEqualStrings("supercalifragilistic", got);
}

test "wrap: empty input" {
    const allocator = std.testing.allocator;
    const got = try wrap(allocator, "", 10, 1);
    defer allocator.free(got);
    try std.testing.expectEqualStrings("", got);
}

// ── truncate ─────────────────────────────────

test "truncate: fits verbatim" {
    const allocator = std.testing.allocator;
    const got = try truncate(allocator, "Hello 😊", 8);
    defer allocator.free(got);
    try std.testing.expectEqualStrings("Hello 😊", got);
}

test "truncate: cuts at grapheme boundary, never mid-bytes" {
    const allocator = std.testing.allocator;
    const got = try truncate(allocator, "👨‍🌾x", 2);
    defer allocator.free(got);
    try std.testing.expectEqualStrings("👨‍🌾", got);
}

test "truncate: over-wide first grapheme yields empty" {
    const allocator = std.testing.allocator;
    const got = try truncate(allocator, "👨‍🌾x", 1);
    defer allocator.free(got);
    try std.testing.expectEqualStrings("", got);
}

test "truncate: combining mark stays glued to its base" {
    const allocator = std.testing.allocator;
    const got = try truncate(allocator, "e\u{301}x", 1);
    defer allocator.free(got);
    try std.testing.expectEqualStrings("e\u{301}", got);
}

test "truncate: never errors for any input" {
    const allocator = std.testing.allocator;
    const empty = try truncate(allocator, "", 5);
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);

    const zero = try truncate(allocator, "abc", 0);
    defer allocator.free(zero);
    try std.testing.expectEqualStrings("", zero);

    const roomy = try truncate(allocator, "zz", 100);
    defer allocator.free(roomy);
    try std.testing.expectEqualStrings("zz", roomy);
}

// ── firstGraphemeLen (parser seam) ─────────────────────────

test "firstGraphemeLen: vectors" {
    try std.testing.expectEqual(@as(usize, 0), firstGraphemeLen(""));
    try std.testing.expectEqual(@as(usize, 1), firstGraphemeLen("Hello"));
    // Base + combining acute accent is one cluster: 1 + 2 bytes.
    try std.testing.expectEqual(@as(usize, 3), firstGraphemeLen("e\u{301}x"));
    // ZWJ family: U+1F468 (4) + ZWJ (3) + U+1F33E (4) = 11 bytes.
    try std.testing.expectEqual(@as(usize, 11), firstGraphemeLen("👨‍🌾x"));
}

// ── toUpper (case seam) ───────────────────────

test "toUpper: unicode simple mapping, unmapped codepoints unchanged" {
    try std.testing.expectEqual(@as(u21, 'A'), toUpper('a'));
    try std.testing.expectEqual(@as(u21, 'Z'), toUpper('z'));
    // Latin-1, dotless i, Greek final sigma, Cyrillic.
    try std.testing.expectEqual(@as(u21, 0x00C4), toUpper(0x00E4)); // ä → Ä
    try std.testing.expectEqual(@as(u21, 0x0049), toUpper(0x0131)); // ı → I
    try std.testing.expectEqual(@as(u21, 0x03A3), toUpper(0x03C2)); // ς → Σ
    try std.testing.expectEqual(@as(u21, 0x042B), toUpper(0x044B)); // ы → Ы
    // No simple uppercase: the full mapping is ß → SS, which is three
    // codepoints wide and cannot name one Key.
    try std.testing.expectEqual(@as(u21, 0x00DF), toUpper(0x00DF));
    // No case at all.
    try std.testing.expectEqual(@as(u21, '1'), toUpper('1'));
    try std.testing.expectEqual(@as(u21, '+'), toUpper('+'));
}
