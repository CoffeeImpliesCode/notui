//! Terminal display width, grapheme segmentation, wrapping and truncation.
//!
//! This is the `notui` toolkit's only `zg`, `DisplayWidth`, and `Graphemes` importer.
//! Other toolkit namespaces use the functions below. The separate `ztex` modules
//! have their own Unicode imports.
//!
//! `wrap` and `truncate` allocate their result with the caller's allocator
//! and hand ownership to the caller; the other functions allocate nothing.

const std = @import("std");

const zg = @import("zg");
const DisplayWidth = @import("DisplayWidth");
const Graphemes = @import("Graphemes");

/// Display width of `str` in terminal cells: the sum of its grapheme widths.
pub fn strWidth(str: []const u8) usize {
    return DisplayWidth.strWidth(str);
}

/// Display width of one grapheme cluster `gc` in terminal cells: 0 for a
/// combining mark, 2 for a wide or emoji grapheme, negative for a control.
pub fn graphemeWidth(gc: []const u8) isize {
    return DisplayWidth.graphemeWidth(gc);
}

/// Wrap words to `columns` cells, except that an over-wide word keeps its own line.
///
/// Runs of ASCII space, tab, CR and LF are one separator; input line breaks do not
/// force output breaks. A word that would overflow the current line starts the next.
/// A word and its fitting trailing space close a line when at most `threshold` cells
/// remain. Interior trailing spaces are preserved only where they fit; the final line
/// has no trailing separator. With zero columns, each word takes its own line.
///
/// Input without words returns an owned empty slice. Free the result with `allocator`.
/// Allocation failure returns no result and releases partial output.
pub fn wrap(
    allocator: std.mem.Allocator,
    str: []const u8,
    columns: usize,
    threshold: usize,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var line_width: usize = 0;
    var words = std.mem.tokenizeAny(u8, str, " \t\r\n");
    while (words.next()) |word| {
        const word_width = strWidth(word);
        if (line_width > 0 and word_width > columns -| line_width) {
            try out.append(allocator, '\n');
            line_width = 0;
        }
        try out.appendSlice(allocator, word);
        line_width += word_width;
        if (line_width < columns) {
            try out.append(allocator, ' ');
            line_width += 1;
        }
        if (line_width >= columns or columns - line_width <= threshold) {
            try out.append(allocator, '\n');
            line_width = 0;
        }
    }

    if (out.items.len > 0 and out.items[out.items.len - 1] == '\n') {
        _ = out.pop();
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        _ = out.pop();
    }
    return out.toOwnedSlice(allocator);
}

/// Byte length of the FIRST grapheme cluster in `str`; 0 for empty input.
///
/// `Parser` needs this to know how many bytes one ground-state key occupies.
pub fn firstGraphemeLen(str: []const u8) usize {
    var iter = Graphemes.iterator(str);
    const g = iter.next() orelse return 0;
    return g.bytes(str).len;
}

/// Simple (single-codepoint) uppercase mapping for `cp`. Codepoints whose
/// full mapping expands to several codepoints (ß → SS) have no simple
/// mapping and come back unchanged.
pub fn toUpper(cp: u21) u21 {
    return zg.letter_casing.toUpper(cp);
}

/// Byte length of the longest prefix of `str` that fits `columns` terminal cells.
///
/// The prefix ends at a grapheme boundary. Zero-width and control clusters do not
/// consume cells. A first grapheme wider than the budget yields an empty prefix.
/// Allocates nothing and retains no storage. The caller slices its own borrowed `str`.
pub fn fitPrefixLen(str: []const u8, columns: usize) usize {
    var width: usize = 0;
    var end: usize = 0;
    var iter = Graphemes.iterator(str);
    while (iter.next()) |g| {
        const gc = g.bytes(str);
        const w = DisplayWidth.graphemeWidth(gc);
        if (w <= 0) {
            end += gc.len;
            continue;
        }
        const wu: usize = @intCast(w);
        if (width + wu > columns) break;
        width += wu;
        end += gc.len;
    }
    return end;
}

/// The longest prefix of `str` that fits in `columns` cells, cut only at
/// grapheme boundaries; possibly empty.
///
/// Zero-width and control clusters stay glued to the cluster they follow and
/// advance no column. A grapheme wider than `columns` ends the prefix, so
/// the result is never wider than `columns`. The caller owns the returned
/// slice and frees it with `allocator`.
pub fn truncate(
    allocator: std.mem.Allocator,
    str: []const u8,
    columns: usize,
) ![]u8 {
    return allocator.dupe(u8, str[0..fitPrefixLen(str, columns)]);
}

// ── strWidth ─────────────────────────────────

test "strWidth: ascii and emoji add up" {
    try std.testing.expectEqual(@as(usize, 5), strWidth("Hello"));
    try std.testing.expectEqual(@as(usize, 8), strWidth("Hello 😊"));
}

test "strWidth: a ZWJ sequence is one wide grapheme, not its parts" {
    try std.testing.expectEqual(@as(usize, 2), strWidth("👨‍🌾"));
    try std.testing.expectEqual(@as(usize, 2), strWidth("👩‍🔬"));
}

test "strWidth: a combining mark adds no cell" {
    try std.testing.expectEqual(@as(usize, 1), strWidth("e\u{301}"));
}

// ── graphemeWidth ────────────────────────────────

test "graphemeWidth: wide, combining and control clusters" {
    try std.testing.expectEqual(@as(isize, 2), graphemeWidth("👨‍🌾"));
    try std.testing.expectEqual(@as(isize, 1), graphemeWidth("e\u{301}"));
    try std.testing.expectEqual(@as(isize, 1), graphemeWidth("a"));
}

// ── wrap ───────────────────────────────────

test "wrap: a word that would land on the threshold starts a new line" {
    const allocator = std.testing.allocator;
    const input = "The quick brown fox\r\njumped over the lazy dog!";
    const got = try wrap(allocator, input, 10, 3);
    defer allocator.free(got);
    try std.testing.expectEqualStrings("The quick \nbrown fox \njumped \nover the \nlazy dog!", got);
}

test "wrap: an over-wide word keeps its own line" {
    const allocator = std.testing.allocator;
    const got = try wrap(allocator, "supercalifragilistic", 10, 1);
    defer allocator.free(got);
    try std.testing.expectEqualStrings("supercalifragilistic", got);
}

test "wrap: input with no words returns an owned empty result" {
    const allocator = std.testing.allocator;
    // Separators alone leave nothing to lay out: the result must still be a
    // slice the caller can free, not a panic on an empty build-up buffer.
    for ([_][]const u8{ "", " ", "   ", "\r\n", " \t ", "\n\n\r" }) |input| {
        const got = try wrap(allocator, input, 10, 1);
        defer allocator.free(got);
        try std.testing.expectEqualStrings("", got);
    }
}

test "wrap: runs of separators collapse and never start a line" {
    const allocator = std.testing.allocator;
    const got = try wrap(allocator, "  one   two  ", 40, 1);
    defer allocator.free(got);
    try std.testing.expectEqualStrings("one two", got);
}

test "wrap: no produced line is wider than columns" {
    const allocator = std.testing.allocator;
    const input = "alpha beta gamma delta epsilon zeta eta theta";
    for (1..12) |columns| {
        const got = try wrap(allocator, input, columns, 0);
        defer allocator.free(got);
        var lines = std.mem.splitScalar(u8, got, '\n');
        while (lines.next()) |line| {
            // A single word wider than the line is never broken, so the
            // bound only holds for lines that fit by construction.
            if (std.mem.indexOfScalar(u8, line, ' ') == null) continue;
            try std.testing.expect(strWidth(line) <= columns);
        }
    }
}

// ── fitPrefixLen ──────────────────────────────

test "fitPrefixLen: cuts only at grapheme boundaries" {
    // The result is a BYTE range the caller slices itself, so what the
    // contract claims is the borrowed text, not a byte count that only
    // happens to equal a cell count for ASCII.
    const emoji = "Hello \u{1f60a}!";
    try std.testing.expectEqualStrings("Hello", emoji[0..fitPrefixLen(emoji, 5)]);
    // "Hello " is 6 columns, and the 2-cell emoji only fits an 8-column
    // budget. It is never split.
    try std.testing.expectEqualStrings("Hello ", emoji[0..fitPrefixLen(emoji, 7)]);
    try std.testing.expectEqualStrings("Hello \u{1f60a}", emoji[0..fitPrefixLen(emoji, 8)]);
    // A cluster wider than the whole budget yields the empty prefix.
    try std.testing.expectEqualStrings("", "\u{1f60a}"[0..fitPrefixLen("\u{1f60a}", 1)]);
    try std.testing.expectEqualStrings("", "abc"[0..fitPrefixLen("abc", 0)]);
    try std.testing.expectEqualStrings("", ""[0..fitPrefixLen("", 5)]);
}

test "fitPrefixLen: never spends more than the budget" {
    // A ZWJ sequence is one 2-cell cluster, so two of them fill a
    // 4-column budget and a third would not fit.
    const zwj = "\u{1f468}\u{200d}\u{1f33e}xx";
    try std.testing.expectEqualStrings("\u{1f468}\u{200d}\u{1f33e}", zwj[0..fitPrefixLen(zwj, 2)]);
    try std.testing.expectEqualStrings("\u{1f468}\u{200d}\u{1f33e}x", zwj[0..fitPrefixLen(zwj, 3)]);
    // A combining mark rides along on the cell it follows, spending
    // none of its own, so the base still fits a 1-column budget.
    const combining = "e\u{301}x";
    try std.testing.expectEqualStrings("e\u{301}", combining[0..fitPrefixLen(combining, 1)]);

    const samples = [_][]const u8{
        "Hello \u{1f60a}!",
        "\u{1f468}\u{200d}\u{1f33e}xx",
        "e\u{301}x",
        "abc",
    };
    for (samples) |s| {
        for (0..10) |budget| {
            const prefix = s[0..fitPrefixLen(s, budget)];
            try std.testing.expect(strWidth(prefix) <= budget);
        }
    }
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

test "truncate: never errors on any width" {
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

test "firstGraphemeLen: one ground-state key's byte length" {
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
