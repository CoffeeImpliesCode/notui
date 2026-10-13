//! Terminal display width, grapheme segmentation, wrapping and truncation.
//!
//! This is the `notui` toolkit's only `zg`, `DisplayWidth`, and `Graphemes` importer.
//! Other toolkit namespaces use the functions below. The separate `ztex` modules
//! have their own Unicode imports.
//! Drawing uses a process-wide mode selected before layout with `setMode`; its
//! default is Unicode graphemes. Semantic key/edit segmentation is independent.
//!
//! `wrap` and `truncate` allocate their result with the caller's allocator
//! and hand ownership to the caller; the other functions allocate nothing.

const std = @import("std");

const zg = @import("zg");
const DisplayWidth = @import("DisplayWidth");
const Graphemes = @import("Graphemes");

/// Terminal cell segmentation and width policy.
pub const Mode = enum {
    /// Default: Unicode grapheme clusters, for terminals with DEC 2027 enabled.
    grapheme,
    /// One spacing codepoint plus following zero-width codepoints, as in wcwidth terminals.
    codepoint,
};

var mode: Mode = .grapheme;

/// Select the process-wide drawing policy before measuring or constructing cell grids.
/// The default is `.grapheme`; App selects it from terminal capabilities at startup.
/// Change only while no drawing or measurement is running, and discard existing grids
/// before using a different mode. Concurrent terminals with different policies are unsupported.
/// Semantic grapheme segmentation (`firstGraphemeLen`, Parser and editing motion) is unchanged.
pub fn setMode(selected: Mode) void {
    mode = selected;
}

/// Current process-wide drawing policy; allocates nothing.
pub fn getMode() Mode {
    return mode;
}

const Codepoint = struct { code: u21, len: usize };

fn firstCodepoint(str: []const u8) ?Codepoint {
    if (str.len == 0) return null;
    const len = std.unicode.utf8ByteSequenceLength(str[0]) catch return null;
    if (len > str.len) return null;
    return .{ .code = std.unicode.utf8Decode(str[0..len]) catch return null, .len = len };
}

fn codepointWidth(cp: u21) isize {
    // zg widens regional indicators for grapheme flags. Legacy terminals render
    // each indicator as one cell; pairing them must not widen each half.
    if (cp >= 0x1f1e6 and cp <= 0x1f1ff) return 1;
    return DisplayWidth.codePointWidth(cp);
}

fn codepointStrWidth(str: []const u8) isize {
    var total: isize = 0;
    var off: usize = 0;
    while (off < str.len) {
        const cp = firstCodepoint(str[off..]) orelse break;
        total += codepointWidth(cp.code);
        off += cp.len;
    }
    return total;
}

fn isControl(cp: u21) bool {
    return cp < 0x20 or (cp >= 0x7f and cp <= 0x9f);
}

/// Byte length of the first terminal cell cluster, or 0 for empty/invalid input.
/// In `.codepoint` mode, trailing combining marks, ZWJ and variation selectors
/// stay on their spacing codepoint; the next spacing codepoint starts a new cell.
/// In `.grapheme` mode this is `firstGraphemeLen`. Allocates and retains nothing.
pub fn firstCellLen(str: []const u8) usize {
    if (asciiSingle(str)) return 1;
    if (mode == .grapheme) return firstGraphemeLen(str);
    const first = firstCodepoint(str) orelse return 0;
    if (isControl(first.code)) return first.len;
    var end = first.len;
    while (end < str.len) {
        const next = firstCodepoint(str[end..]) orelse break;
        if (isControl(next.code) or codepointWidth(next.code) != 0) break;
        end += next.len;
    }
    return end;
}

/// The terminal cell clusters of a string with their widths, under the
/// selected mode: `firstCellLen` and `graphemeWidth` applied cluster after
/// cluster, but in grapheme mode one segmenter walks the string, so each
/// codepoint is decoded and classified once instead of per call.
pub const CellIterator = struct {
    str: []const u8,
    off: usize = 0,
    graphemes: ?Graphemes.Iterator,

    /// One cluster: `str[offset..][0..len]`, `width` as `graphemeWidth`.
    pub const Cluster = struct { offset: usize, len: usize, width: isize };

    pub fn init(str: []const u8) CellIterator {
        return .{
            .str = str,
            .graphemes = if (mode == .grapheme) Graphemes.iterator(str) else null,
        };
    }

    /// The next cluster, or null at the end (or at input the segmenter
    /// cannot advance over, as `firstCellLen` returning 0).
    pub fn next(self: *CellIterator) ?Cluster {
        if (self.graphemes) |*it| {
            const g = it.next() orelse return null;
            const gc = self.str[g.offset..][0..g.len];
            return .{ .offset = g.offset, .len = g.len, .width = clusterWidth(gc) };
        }
        if (self.off >= self.str.len) return null;
        const len = firstCellLen(self.str[self.off..]);
        if (len == 0) return null;
        const at = self.off;
        self.off += len;
        return .{ .offset = at, .len = len, .width = graphemeWidth(self.str[at..][0..len]) };
    }

    /// `DisplayWidth.graphemeWidth` without its second decode for the
    /// common one-codepoint cluster, whose width is the codepoint's.
    fn clusterWidth(gc: []const u8) isize {
        if (gc.len == 1 and isPrintableAscii(gc[0])) return 1;
        if (firstCodepoint(gc)) |cp| {
            if (cp.len == gc.len) return DisplayWidth.codePointWidth(cp.code);
        }
        return DisplayWidth.graphemeWidth(gc);
    }
};

/// A cell cluster that needs no segmenter: one codepoint from `simple_ranges`
/// followed by the end of input, an ASCII byte, or another such codepoint.
/// Those codepoints have Grapheme_Cluster_Break and Indic_Conjunct_Break
/// `Other` and a nonzero width, so no rule joins them to a neighbour of the
/// same kind or to ASCII: the cluster is the codepoint alone in both modes,
/// and its width is the codepoint's. Returns null when that cannot be shown
/// from the first two codepoints; `firstCellLen` then decides.
pub fn simpleCluster(str: []const u8) ?CellIterator.Cluster {
    const cp = decodeBmp(str) orelse return null;
    if (!isSimple(cp.code)) return null;
    const rest = str[cp.len..];
    if (rest.len > 0 and rest[0] >= 0x80) {
        const next = decodeBmp(rest) orelse return null;
        if (!isSimple(next.code)) return null;
    }
    return .{ .offset = 0, .len = cp.len, .width = DisplayWidth.codePointWidth(cp.code) };
}

/// Script blocks whose codepoints never join a cluster (see `simpleCluster`;
/// a test checks every codepoint against zg's tables). Combining blocks and
/// the few joining or zero-width codepoints inside these blocks are left out.
const simple_ranges = [_][2]u21{
    .{ 0x00C0, 0x024F }, // Latin-1 letters, Latin Extended-A and -B
    .{ 0x0370, 0x0377 }, // Greek
    .{ 0x037A, 0x037F },
    .{ 0x0384, 0x03FF },
    .{ 0x0400, 0x0482 }, // Cyrillic, up to its combining marks
    .{ 0x048A, 0x04FF },
    .{ 0x2010, 0x2027 }, // General punctuation: dashes, quotes, bullets, ellipsis
    .{ 0x2030, 0x205E },
    .{ 0x2190, 0x21FF }, // Arrows
    .{ 0x2500, 0x25FF }, // Box drawing, block elements, geometric shapes
    .{ 0x3041, 0x3096 }, // Hiragana, without the combining voicing marks
    .{ 0x30A1, 0x30FF }, // Katakana
    .{ 0x4E00, 0x9FFF }, // CJK unified ideographs
    .{ 0xFF01, 0xFF60 }, // Fullwidth forms
};

/// `simple_ranges` as one bit per BMP codepoint (8 KiB): a lookup is one
/// load and a shift, whatever the block.
const simple_bits: [0x10000 / 64]u64 = blk: {
    @setEvalBranchQuota(200_000);
    var bits: [0x10000 / 64]u64 = @splat(0);
    for (simple_ranges) |r| {
        for (r[0]..r[1] + 1) |cp| bits[cp / 64] |= @as(u64, 1) << @intCast(cp % 64);
    }
    break :blk bits;
};

fn isSimple(cp: u21) bool {
    return cp < 0x10000 and simple_bits[cp >> 6] >> @intCast(cp & 63) & 1 != 0;
}

/// A two- or three-byte UTF-8 sequence (U+0080..U+FFFF, no surrogates),
/// or null for anything else, including malformed input.
fn decodeBmp(str: []const u8) ?Codepoint {
    if (str.len < 2 or str[1] & 0xC0 != 0x80) return null;
    const b0 = str[0];
    if (b0 & 0xE0 == 0xC0) {
        const cp = @as(u21, b0 & 0x1F) << 6 | (str[1] & 0x3F);
        return if (cp >= 0x80) .{ .code = cp, .len = 2 } else null;
    }
    if (b0 & 0xF0 != 0xE0 or str.len < 3 or str[2] & 0xC0 != 0x80) return null;
    const cp = @as(u21, b0 & 0x0F) << 12 | @as(u21, str[1] & 0x3F) << 6 | (str[2] & 0x3F);
    if (cp < 0x800 or (cp >= 0xD800 and cp <= 0xDFFF)) return null;
    return .{ .code = cp, .len = 3 };
}

/// Display width of `str` in terminal cells under the selected drawing policy.
pub fn strWidth(str: []const u8) usize {
    if (allPrintableAscii(str)) return str.len;
    if (mode == .codepoint) return @intCast(@max(0, codepointStrWidth(str)));
    return DisplayWidth.strWidth(str);
}

/// Display width of `gc` under the selected drawing policy. In `.codepoint`
/// mode this sums codepoint widths; use `firstCellLen` to segment drawable cells.
/// Zero-width marks consume no cells; negative widths represent controls.
pub fn graphemeWidth(gc: []const u8) isize {
    if (gc.len == 1 and isPrintableAscii(gc[0])) return 1;
    if (mode == .codepoint) return codepointStrWidth(gc);
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
    if (asciiSingle(str)) return 1;
    var iter = Graphemes.iterator(str);
    const g = iter.next() orelse return 0;
    return g.bytes(str).len;
}

/// Printable ASCII (U+0020..U+007E): one cell, one byte, one codepoint.
inline fn isPrintableAscii(b: u8) bool {
    return b >= 0x20 and b < 0x7f;
}

/// Whether `str` starts with a printable ASCII byte that is a cell cluster on
/// its own in both modes: one byte, one column. No ASCII byte extends a
/// cluster (Extend, ZWJ, SpacingMark and Prepend are all non-ASCII, and the
/// CR LF pair starts with a control), so an ASCII successor or the end of
/// input ends it. Drawing loops call this before the general segmenter.
pub inline fn asciiSingle(str: []const u8) bool {
    return str.len > 0 and isPrintableAscii(str[0]) and (str.len == 1 or str[1] < 0x80);
}

/// Whether every byte of `str` is printable ASCII, so its width is its length.
fn allPrintableAscii(str: []const u8) bool {
    return printableAsciiPrefix(str) == str.len;
}

/// Length of the longest prefix of `str` whose bytes are all printable ASCII.
/// Scans 32 bytes per step: a printable byte is one with `b - 0x20 < 0x5f`
/// (wrapping), so one compare per lane tests the whole range.
pub fn printableAsciiPrefix(str: []const u8) usize {
    const lanes = 32;
    const V = @Vector(lanes, u8);
    var i: usize = 0;
    while (i + lanes <= str.len) : (i += lanes) {
        const v: V = str[i..][0..lanes].*;
        const ok = (v -% @as(V, @splat(0x20))) < @as(V, @splat(0x5f));
        const bad: u32 = ~@as(u32, @bitCast(ok));
        if (bad != 0) return i + @ctz(bad);
    }
    while (i < str.len and isPrintableAscii(str[i])) i += 1;
    return i;
}

/// Number of leading bytes of `str` that are each a one-cell cluster on
/// their own (see `asciiSingle`): the printable ASCII prefix, less its last
/// byte when a non-ASCII codepoint follows that could extend it. One from
/// `simple_ranges` never extends anything, so the byte stays.
pub fn asciiSingleRun(str: []const u8) usize {
    const n = printableAsciiPrefix(str);
    if (n > 0 and n < str.len and str[n] >= 0x80) {
        const next = decodeBmp(str[n..]) orelse return n - 1;
        if (!isSimple(next.code)) return n - 1;
    }
    return n;
}

/// Simple (single-codepoint) uppercase mapping for `cp`. Codepoints whose
/// full mapping expands to several codepoints (ß → SS) have no simple
/// mapping and come back unchanged.
pub fn toUpper(cp: u21) u21 {
    return zg.letter_casing.toUpper(cp);
}

/// Byte length of the longest prefix of `str` that fits `columns` terminal cells.
///
/// The prefix ends at a terminal cell-cluster boundary under the selected mode.
/// Zero-width and control clusters consume no cells; an over-wide first cell yields an empty prefix.
/// Allocates nothing and retains no storage. The caller slices its own borrowed `str`.
pub fn fitPrefixLen(str: []const u8, columns: usize) usize {
    if (allPrintableAscii(str)) return @min(str.len, columns);
    var width: usize = 0;
    var end: usize = 0;
    var off: usize = 0;
    while (off < str.len) {
        const len = firstCellLen(str[off..]);
        if (len == 0) break;
        const gc = str[off..][0..len];
        off += len;
        const w = graphemeWidth(gc);
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
/// terminal cell-cluster boundaries under the selected mode; possibly empty.
///
/// Zero-width and control clusters stay glued to the cluster they follow and
/// advance no column. A cell cluster wider than `columns` ends the prefix, so
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

test "codepoint mode: widths match xterm.js measured marker columns" {
    setMode(.codepoint);
    defer setMode(.grapheme);
    const samples = [_][]const u8{
        "👩‍💻",
        "👍🏽",
        "❤️",
        "☺️",
        "🇩🇪",
        "e\u{301}",
        "日本",
        "#️⃣",
    };
    const widths = [_]usize{ 4, 4, 1, 1, 2, 1, 4, 1 };
    for (samples, widths) |text, expected| {
        try std.testing.expectEqual(expected, strWidth(text));
        try std.testing.expectEqual(@as(isize, @intCast(expected)), graphemeWidth(text));
    }
}

test "codepoint mode: cell segmentation retains zero-width suffixes" {
    setMode(.codepoint);
    defer setMode(.grapheme);
    const samples = [_][]const u8{
        "👩‍💻",
        "👍🏽",
        "❤️",
        "☺️",
        "🇩🇪",
        "e\u{301}",
        "日本",
        "#️⃣",
    };
    const first = [_][]const u8{
        "👩‍",
        "👍",
        "❤️",
        "☺️",
        "🇩",
        "e\u{301}",
        "日",
        "#️⃣",
    };
    for (samples, first) |text, expected| {
        try std.testing.expectEqualStrings(expected, text[0..firstCellLen(text)]);
    }
    try std.testing.expectEqual(@as(usize, 0), firstCellLen(""));
    try std.testing.expectEqual(@as(usize, 0), firstCellLen("\xff"));
    try std.testing.expectEqual(@as(usize, 0), firstCellLen("\xf0"));
    // Zero-width control bytes must remain separate so draw/sanitizers can drop them.
    try std.testing.expectEqual(@as(usize, 1), firstCellLen("a\nb"));
    try std.testing.expectEqual(@as(usize, 1), firstCellLen("\n\u{301}"));
    // Key text and semantic editing must still see the complete Unicode grapheme.
    try std.testing.expectEqual(@as(usize, "👩‍💻".len), firstGraphemeLen("👩‍💻x"));
}

test "codepoint mode: prefix truncation and wrapping use cell budgets" {
    setMode(.codepoint);
    defer setMode(.grapheme);
    const text = "👩‍💻x";
    try std.testing.expectEqualStrings("👩‍", text[0..fitPrefixLen(text, 2)]);
    try std.testing.expectEqualStrings("👩‍💻", text[0..fitPrefixLen(text, 4)]);
    const truncated = try truncate(std.testing.allocator, text, 2);
    defer std.testing.allocator.free(truncated);
    try std.testing.expectEqualStrings("👩‍", truncated);
    const wrapped = try wrap(std.testing.allocator, "👩‍💻 x", 4, 0);
    defer std.testing.allocator.free(wrapped);
    try std.testing.expectEqualStrings("👩‍💻\nx", wrapped);
}

test "ascii fast path: agrees with zg for every printable byte and successor" {
    const saved = getMode();
    defer setMode(saved);
    // Every printable ASCII byte followed by every ASCII byte, a combining
    // acute, a ZWJ and nothing: the shortcut must give zg's answer.
    const tails = [_][]const u8{ "\u{301}", "\u{200d}x", "" };
    var buf: [8]u8 = undefined;
    var b: u8 = 0x20;
    while (b < 0x7f) : (b += 1) {
        buf[0] = b;
        var next: u8 = 0;
        while (next < 0x80) : (next += 1) {
            buf[1] = next;
            var iter = Graphemes.iterator(buf[0..2]);
            const zg_len = iter.next().?.bytes(buf[0..2]).len;
            try std.testing.expectEqual(zg_len, firstGraphemeLen(buf[0..2]));
        }
        for (tails) |tail| {
            @memcpy(buf[1..][0..tail.len], tail);
            const s = buf[0 .. 1 + tail.len];
            var iter = Graphemes.iterator(s);
            const zg_len = iter.next().?.bytes(s).len;
            try std.testing.expectEqual(zg_len, firstGraphemeLen(s));
            setMode(.grapheme);
            try std.testing.expectEqual(zg_len, firstCellLen(s));
            try std.testing.expectEqual(DisplayWidth.strWidth(s), strWidth(s));
        }
        try std.testing.expectEqual(DisplayWidth.graphemeWidth(buf[0..1]), graphemeWidth(buf[0..1]));
    }
}

test "ascii run: the vector scan stops at the first unprintable byte at any offset" {
    // Lengths around the 32-byte step, a stopper at every position, and
    // stoppers at both range edges and above ASCII.
    var buf: [80]u8 = undefined;
    for ([_]u8{ 0x1f, 0x7f, 0x80, 0xff, 0x00 }) |stop| {
        for (0..buf.len + 1) |len| {
            for (0..len + 1) |at| {
                @memset(buf[0..len], 'a');
                buf[len -| 1] = '~';
                if (len > 0) buf[0] = ' ';
                if (at < len) buf[at] = stop;
                const want = if (at < len) at else len;
                try std.testing.expectEqual(want, printableAsciiPrefix(buf[0..len]));
            }
        }
    }
    // A non-ASCII codepoint may extend the last ASCII byte, so the run gives
    // it up, unless the codepoint is a simple one that extends nothing.
    try std.testing.expectEqual(@as(usize, 1), asciiSingleRun("ae\u{301}"));
    try std.testing.expectEqual(@as(usize, 3), asciiSingleRun("abc"));
    try std.testing.expectEqual(@as(usize, 2), asciiSingleRun("ab\x01"));
    try std.testing.expectEqual(@as(usize, 0), asciiSingleRun("\u{301}"));
    for ([_][]const u8{ "ab日", "a ─", "x→", "zé", "q\u{600}" }) |s| {
        const n = asciiSingleRun(s);
        var off: usize = 0;
        while (off < n) : (off += 1) try std.testing.expectEqual(@as(usize, 1), firstCellLen(s[off..]));
    }
    try std.testing.expectEqual(@as(usize, 2), asciiSingleRun("ab日"));
}

test "cell iterator: one walk agrees with firstCellLen and graphemeWidth per cluster" {
    const saved = getMode();
    defer setMode(saved);
    const corpus = [_][]const u8{
        "日本語テスト ──┌─┬─┐",
        "e\u{301}o\u{308} a\u{30A}",
        "👨‍🌾x👩‍💻\u{fe0f}",
        "🇩🇪🇫🇷🇺",
        "\u{1100}\u{1161}\u{11a8}가",
        "\u{600}a\u{600}\u{600}b",
        "a\r\nb\x01\u{85}",
        "\u{301}\u{200d}",
        "☺\u{fe0e}☺\u{fe0f}👍\u{1f3fd}",
    };
    for ([_]Mode{ .grapheme, .codepoint }) |m| {
        setMode(m);
        for (corpus) |s| {
            var it = CellIterator.init(s);
            var off: usize = 0;
            while (it.next()) |c| {
                const len = firstCellLen(s[off..]);
                try std.testing.expectEqual(off, c.offset);
                try std.testing.expectEqual(len, c.len);
                try std.testing.expectEqual(graphemeWidth(s[off..][0..len]), c.width);
                off += len;
            }
            try std.testing.expectEqual(s.len, off);
        }
    }
}

test "simple cluster: every simple codepoint is a non-joining, spacing one in zg's tables" {
    for (simple_ranges) |r| {
        var cp = r[0];
        while (cp <= r[1]) : (cp += 1) {
            try std.testing.expectEqual(Graphemes.Gbp.none, Graphemes.gbp(cp));
            try std.testing.expectEqual(Graphemes.Indic.none, Graphemes.indic(cp));
            try std.testing.expect(DisplayWidth.codePointWidth(cp) >= 1);
            try std.testing.expectEqual(DisplayWidth.codePointWidth(cp), codepointWidth(cp));
        }
    }
}

test "simple cluster: agrees with firstCellLen and graphemeWidth wherever it answers" {
    const saved = getMode();
    defer setMode(saved);
    const corpus = [_][]const u8{
        "日本語テスト ──┌─┬─┐│└─┴─┘",
        "Ünïcödé “quotes” — → ←…",
        "é\u{301}ß\u{200d}x",
        "が\u{3099}カ",
        "‼\u{fe0f}▶\u{fe0f}◀",
        "ąā\u{1f3fd}Ω\u{483}",
        "\u{d7ff}\u{c0}\x01",
        "\xc3\x28\xe2\x82",
    };
    var answered: usize = 0;
    for ([_]Mode{ .grapheme, .codepoint }) |m| {
        setMode(m);
        for (corpus) |s| {
            for (0..s.len) |off| {
                const c = simpleCluster(s[off..]) orelse continue;
                answered += 1;
                try std.testing.expectEqual(firstCellLen(s[off..]), c.len);
                try std.testing.expectEqual(graphemeWidth(s[off..][0..c.len]), c.width);
            }
        }
    }
    try std.testing.expect(answered > 40); // the fast path really ran
}
