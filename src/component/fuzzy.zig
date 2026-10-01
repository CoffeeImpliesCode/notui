//! fuzzy.zig — subsequence matching over grapheme clusters.
//!
//! A completion popup ranks candidates by asking two questions: is the
//! needle a subsequence of the candidate, and how good is that match?
//! This module answers both with no dependency of its own, no
//! allocator, and no byte-oriented shortcut. The walk steps one
//! GRAPHEME at a time (the cluster byte length comes from the `width`
//! seam, the single place zg is reachable), and case folding goes
//! through that same seam (`Width.toUpper`, the Unicode 16 simple
//! mapping), so `Bär` matches the needle `bär` and a codepoint is never
//! half-compared.
//!
//! Allocation-free by construction: no function here takes an
//! allocator, and `Score` names its match positions in a fixed array.
//! The bound is `max_needle` graphemes of needle — one position per
//! needle grapheme, so the needle is what caps the result. A longer
//! needle reports `error.NeedleTooLong` instead of truncating quietly;
//! an interactive query is never that long.

const std = @import("std");
const Width = @import("../width.zig");

/// Longest needle a `Score` can name, in GRAPHEMES: a match has one
/// position per needle grapheme, so the needle bounds the result.
pub const max_needle: usize = 32;

/// The failure `score` and `needleGraphemes` report.
pub const Error = error{
    /// The needle is longer than `max_needle` graphemes, so no
    /// allocation-free result can name it.
    NeedleTooLong,
};

/// Matching knobs. The case flag is explicit so a caller that wants an
/// exact comparison opts out rather than inheriting folding.
pub const Options = struct {
    /// Case-insensitive: both sides fold per codepoint through
    /// `Width.toUpper`, so non-ASCII folds by its Unicode simple
    /// mapping rather than by an ASCII byte hack. Defaults to true.
    fold_case: bool = true,
};

/// The four ranking keys, compared in this order. Each field below
/// carries its rule name and the direction that wins.
pub const Rank = struct {
    /// Rule 1 (run): needle graphemes matched immediately after their
    /// predecessor. MORE wins — a consecutive run beats a scatter.
    adjacent: usize,
    /// Rule 2 (anchor): 1 when the first matched grapheme starts a
    /// word — the string start, or right after `/`, `-`, `_`, `.`, or
    /// a space. MORE wins — an anchored hit beats a mid-word one.
    anchored: u8,
    /// Rule 3 (earliest): haystack grapheme index of the first match.
    /// SMALLER wins — an earlier hit beats a later one.
    first: usize,
    /// Rule 4 (shortest): haystack grapheme count. SMALLER wins — the
    /// shorter haystack beats the longer one.
    haystack: usize,

    /// True when `self` outranks `other`. The rules apply in the
    /// documented order, stopping at the first difference (run, then
    /// anchor, then earliest, then shortest).
    pub fn betterThan(self: Rank, other: Rank) bool {
        if (self.adjacent != other.adjacent) return self.adjacent > other.adjacent;
        if (self.anchored != other.anchored) return self.anchored > other.anchored;
        if (self.first != other.first) return self.first < other.first;
        return self.haystack < other.haystack;
    }
};

/// A successful match. `positions[0..len]` are indices into the
/// HAYSTACK's GRAPHEME sequence — never byte offsets — strictly
/// ascending, one per needle grapheme; the rest of the array is
/// zero-filled so a caller can never read poison.
pub const Score = struct {
    /// Matched haystack grapheme indices, ascending.
    positions: [max_needle]usize = @splat(0),
    /// Entries valid in `positions`; equals the needle's grapheme
    /// count.
    len: u8 = 0,
    /// The four ranking keys for this match.
    rank: Rank = .{ .adjacent = 0, .anchored = 0, .first = 0, .haystack = 0 },
};

/// The score an empty needle yields: every haystack matches, no
/// positions, and a zero rank, so an empty query ties every candidate
/// and keeps the caller's own order.
pub const empty_needle: Score = .{};

/// Match `needle` against `haystack`, both valid UTF-8 (the assumption
/// the width seam already makes).
///
/// The walk reports the HIGHEST-RANKING alignment, not the leftmost
/// occurrence of each needle grapheme: `Score.positions` name the
/// clusters the four `Rank` rules select, so a later contiguous run
/// beats an earlier scatter (rule 1). Alignments that tie on the rules
/// resolve to the leftmost one, so the result is deterministic.
///
/// The search carries two states per needle prefix length: the best
/// alignment that ended at the haystack cluster just before the walk,
/// and the best that ended earlier. Both are needed, and both carry
/// their own positions: only the first earns rule 1's adjacency bonus,
/// while a contiguous run further right must stay reachable from the
/// second. The frontier is a fixed stack array of `2 × (max_needle + 1)`
/// cells, so the walk is heap-free and polynomial — O(haystack
/// clusters × needle graphemes) cell updates, each copying at most
/// `max_needle` positions. Returns null when the needle is not a
/// subsequence of the haystack, and `error.NeedleTooLong` when the
/// needle exceeds `max_needle` graphemes (a property of the needle
/// alone: the error does not depend on whether it would have matched).
pub fn score(haystack: []const u8, needle: []const u8, options: Options) Error!?Score {
    if (needle.len == 0) return empty_needle;

    // Byte offsets of the needle's graphemes: `starts[k]` is where the
    // k-th one begins and `starts[n]` is the needle's end. One walk
    // bounds the needle, then the matching pass reuses the offsets.
    var starts: [max_needle + 1]usize = undefined;
    const needle_graphemes = try graphemeStarts(&starts, needle);

    // The frontier, one cell per needle prefix length in each of two
    // classes: `on` ends at the cluster the walk just left, `off` ends
    // anywhere before it. Only `on` earns an adjacency bonus, so the
    // classes stay disjoint and a gap is never scored as a run.
    var on: [max_needle + 1]Cell = undefined;
    var off: [max_needle + 1]Cell = undefined;
    for (0..needle_graphemes + 1) |j| {
        on[j].valid = false;
        off[j].valid = false;
    }

    var h_off: usize = 0;
    var h_i: usize = 0;
    var prev_off: usize = 0; // byte offset of the previous haystack cluster
    var prev_len: usize = 0; // and that cluster's byte length
    while (h_off < haystack.len) {
        const h_len = Width.firstGraphemeLen(haystack[h_off..]);
        if (h_len == 0) break; // unreachable: a non-empty slice has a cluster
        const cluster = haystack[h_off..][0..h_len];
        // Rule 2: this cluster opens a word when it opens the haystack
        // or follows one of the boundary characters.
        const anchored_here: u8 = if (h_i == 0)
            1
        else
            @intFromBool(isWordBoundary(haystack[prev_off..][0..prev_len]));

        // Descending: cells below j still hold the previous cluster's
        // row when cell j reads them, so one frontier suffices.
        var j: usize = needle_graphemes;
        while (j > 0) : (j -= 1) {
            // An alignment that ended at the previous cluster becomes a
            // gap source from this cluster on — but not before, or a
            // run would lose its adjacency bonus to itself.
            if (on[j].valid and (!off[j].valid or better(&on[j], 0, &off[j], 0, j))) {
                carry(&off[j], &on[j], j);
            }
            on[j].valid = false; // this cluster may fill it below
            if (!clustersMatch(cluster, needle[starts[j - 1]..starts[j]], options.fold_case)) {
                continue;
            }
            if (j == 1) {
                // The base: one grapheme, with nothing to be adjacent to.
                on[1].valid = true;
                on[1].adjacent = 0;
                on[1].anchored = anchored_here;
                on[1].positions[0] = h_i;
                continue;
            }
            const run = &on[j - 1];
            const gap = &off[j - 1];
            if (run.valid and !(gap.valid and better(gap, 0, run, 1, j - 1))) {
                extend(&on[j], run, j, h_i, 1);
            } else if (gap.valid) {
                extend(&on[j], gap, j, h_i, 0);
            }
        }

        prev_off = h_off;
        prev_len = h_len;
        h_off += h_len;
        h_i += 1;
    }

    // The winner is the better of the two classes for the whole needle:
    // `on` ends at the last cluster, `off` ends anywhere before it.
    var best: *const Cell = &off[needle_graphemes];
    if (on[needle_graphemes].valid and
        (!best.valid or better(&on[needle_graphemes], 0, best, 0, needle_graphemes)))
    {
        best = &on[needle_graphemes];
    }
    if (!best.valid) return null; // the needle outlives the haystack

    var positions: [max_needle]usize = @splat(0);
    @memcpy(positions[0..needle_graphemes], best.positions[0..needle_graphemes]);
    return .{
        .positions = positions,
        .len = @intCast(needle_graphemes),
        .rank = .{
            .adjacent = best.adjacent,
            .anchored = best.anchored,
            .first = best.positions[0],
            .haystack = h_i,
        },
    };
}

/// One frontier cell: the best alignment of a needle prefix of a fixed
/// length that ends in the cell's haystack-cluster class. `positions`
/// holds the matched cluster indices ascending, so `positions[0]` is
/// rule 3's key and the vector itself breaks a full tie.
const Cell = struct {
    /// False while no alignment of the prefix reaches this cell; the
    /// other fields are then unread.
    valid: bool,
    /// Rule 1 total: matched pairs that follow their predecessor directly.
    adjacent: u8,
    /// Rule 2 total: whether the first matched grapheme opens a word.
    anchored: u8,
    /// Matched haystack grapheme indices, ascending.
    positions: [max_needle]usize,
};

/// True when the candidate built from `a` outranks the one built from
/// `b` for the same needle prefix of `len` graphemes, where the bonuses
/// are the rule 1 +1 a run earns at the match that follows. Ties fall
/// to the leftmost position vector, which makes the walk deterministic.
fn better(a: *const Cell, a_bonus: u8, b: *const Cell, b_bonus: u8, len: usize) bool {
    const a_adjacent: usize = @as(usize, a.adjacent) + a_bonus;
    const b_adjacent: usize = @as(usize, b.adjacent) + b_bonus;
    if (a_adjacent != b_adjacent) return a_adjacent > b_adjacent;
    if (a.anchored != b.anchored) return a.anchored > b.anchored;
    return std.mem.order(usize, a.positions[0..len], b.positions[0..len]) == .lt;
}

/// Store `src`'s alignment of a `len`-grapheme needle prefix in `dst`.
fn carry(dst: *Cell, src: *const Cell, len: usize) void {
    dst.valid = true;
    dst.adjacent = src.adjacent;
    dst.anchored = src.anchored;
    @memcpy(dst.positions[0..len], src.positions[0..len]);
}

/// Record `h_i` as the match of the needle's `len`-th grapheme in `dst`,
/// extending `src`'s alignment of the first `len - 1` graphemes.
/// `bonus` is rule 1's +1 when `h_i` follows `src`'s last match directly.
fn extend(dst: *Cell, src: *const Cell, len: usize, h_i: usize, bonus: u8) void {
    dst.valid = true;
    dst.adjacent = src.adjacent + bonus;
    dst.anchored = src.anchored;
    @memcpy(dst.positions[0 .. len - 1], src.positions[0 .. len - 1]);
    dst.positions[len - 1] = h_i;
}

/// Fill `starts[0..n+1]` with the byte offsets of `needle`'s graphemes
/// (`starts[k]` is where the k-th begins, `starts[n]` is the needle's
/// end) and return n. `error.NeedleTooLong` when the needle does not
/// fit `max_needle` graphemes.
fn graphemeStarts(starts: *[max_needle + 1]usize, needle: []const u8) Error!usize {
    starts[0] = 0;
    var n: usize = 0;
    while (n < max_needle) {
        const len = Width.firstGraphemeLen(needle[starts[n]..]);
        if (len == 0) break; // unreachable: a non-empty slice has a cluster
        starts[n + 1] = starts[n] + len;
        n += 1;
    }
    if (starts[n] != needle.len) return error.NeedleTooLong;
    return n;
}

/// Grapheme count of `needle`, or `error.NeedleTooLong` when it exceeds
/// `max_needle`. `score` applies the same bound; this is that check on
/// its own, for a caller that must reject a query before it has a
/// haystack (the suggestion list validates ahead of its pool, so the
/// failure does not depend on the item list).
pub fn needleGraphemes(needle: []const u8) Error!usize {
    var starts: [max_needle + 1]usize = undefined;
    return graphemeStarts(&starts, needle);
}

/// True for the one-grapheme characters that end a word (rule 2's
/// boundary set: string start is handled by the caller).
fn isWordBoundary(cluster: []const u8) bool {
    if (cluster.len != 1) return false;
    return switch (cluster[0]) {
        '/', '-', '_', '.', ' ' => true,
        else => false,
    };
}

/// True when haystack cluster `h` and needle cluster `n` are the same
/// cluster. With `fold_case` both sides fold per codepoint through the
/// `Width.toUpper` seam, so `ä` matches `Ä` by the Unicode simple
/// mapping; without it the comparison is exact. Neither side is split:
/// a needle grapheme matches a whole haystack grapheme or nothing, so
/// `e` never matches the `e` inside an `e` + combining-acute cluster.
fn clustersMatch(h: []const u8, n: []const u8, fold_case: bool) bool {
    if (h.len == n.len and std.mem.eql(u8, h, n)) return true; // exact, folded or not
    if (!fold_case) return false;
    var hi = std.unicode.Utf8View.initUnchecked(h).iterator();
    var ni = std.unicode.Utf8View.initUnchecked(n).iterator();
    while (hi.nextCodepoint()) |hc| {
        const nc = ni.nextCodepoint() orelse return false;
        if (Width.toUpper(hc) != Width.toUpper(nc)) return false;
    }
    return ni.nextCodepoint() == null;
}

test {
    std.testing.refAllDecls(@This());
}

test "fuzzy: a needle that is not a subsequence returns null" {
    try std.testing.expect((try score("abc", "zq", .{})) == null);
    // Order matters: a subsequence keeps the needle's order.
    try std.testing.expect((try score("ab", "ba", .{})) == null);
    // A needle longer than the haystack can never be a subsequence.
    try std.testing.expect((try score("ab", "abc", .{})) == null);
    try std.testing.expect((try score("", "a", .{})) == null);
}

test "fuzzy: an empty needle matches everything with a zero score" {
    for ([_][]const u8{ "abc", "", "Bär 🚀" }) |haystack| {
        const got = (try score(haystack, "", .{})).?;
        try std.testing.expectEqual(@as(u8, 0), got.len);
        try std.testing.expectEqual(@as(usize, 0), got.rank.adjacent);
        try std.testing.expectEqual(@as(u8, 0), got.rank.anchored);
        try std.testing.expectEqual(@as(usize, 0), got.rank.first);
        try std.testing.expectEqual(@as(usize, 0), got.rank.haystack);
        try std.testing.expectEqual(empty_needle, got);
    }
    // The fold flag cannot change an empty needle's verdict.
    try std.testing.expectEqual(empty_needle, (try score("abc", "", .{ .fold_case = false })).?);
}

test "fuzzy: rule 1 (run) — a consecutive run outranks a scatter" {
    const run = (try score("xab", "ab", .{})).?;
    const scatter = (try score("a-b", "ab", .{})).?;
    try std.testing.expectEqual(@as(usize, 1), run.rank.adjacent);
    try std.testing.expectEqual(@as(usize, 0), scatter.rank.adjacent);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, run.positions[0..run.len]);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, scatter.positions[0..scatter.len]);
    // The run wins even though the scatter is anchored and starts
    // earlier — rule 1 is checked first.
    try std.testing.expect(run.rank.betterThan(scatter.rank));
    try std.testing.expect(!scatter.rank.betterThan(run.rank));
}

test "fuzzy: rule 2 (anchor) — a word start outranks mid-word" {
    const anchored = (try score("/ab", "ab", .{})).?; // after '/'
    const mid_word = (try score("zab", "ab", .{})).?; // after 'z'
    // Same run length, same first index, same haystack length: only
    // the boundary decides.
    try std.testing.expectEqual(anchored.rank.adjacent, mid_word.rank.adjacent);
    try std.testing.expectEqual(anchored.rank.first, mid_word.rank.first);
    try std.testing.expectEqual(anchored.rank.haystack, mid_word.rank.haystack);
    try std.testing.expectEqual(@as(u8, 1), anchored.rank.anchored);
    try std.testing.expectEqual(@as(u8, 0), mid_word.rank.anchored);
    try std.testing.expect(anchored.rank.betterThan(mid_word.rank));
}

test "fuzzy: rule 3 (earliest) — an earlier first match outranks a later one" {
    const early = (try score("ab---", "ab", .{})).?;
    const late = (try score("---ab", "ab", .{})).?; // '-' is a boundary too
    try std.testing.expectEqual(early.rank.adjacent, late.rank.adjacent);
    try std.testing.expectEqual(early.rank.anchored, late.rank.anchored);
    try std.testing.expectEqual(early.rank.haystack, late.rank.haystack);
    try std.testing.expectEqual(@as(usize, 0), early.rank.first);
    try std.testing.expectEqual(@as(usize, 3), late.rank.first);
    try std.testing.expect(early.rank.betterThan(late.rank));
}

test "fuzzy: rule 4 (shortest) — the shorter haystack outranks the longer" {
    const short = (try score("ab", "ab", .{})).?;
    const long = (try score("ab----", "ab", .{})).?;
    try std.testing.expectEqual(short.rank.adjacent, long.rank.adjacent);
    try std.testing.expectEqual(short.rank.anchored, long.rank.anchored);
    try std.testing.expectEqual(short.rank.first, long.rank.first);
    try std.testing.expectEqual(@as(usize, 2), short.rank.haystack);
    try std.testing.expectEqual(@as(usize, 6), long.rank.haystack);
    try std.testing.expect(short.rank.betterThan(long.rank));
}

test "fuzzy: every boundary character of rule 2 anchors a match" {
    // String start, then each documented boundary before the hit.
    for ([_][]const u8{ "ab", "/ab", "-ab", "_ab", ".ab", " ab" }) |haystack| {
        const got = (try score(haystack, "ab", .{})).?;
        try std.testing.expectEqual(@as(u8, 1), got.rank.anchored);
    }
    const other = (try score("xab", "ab", .{})).?;
    try std.testing.expectEqual(@as(u8, 0), other.rank.anchored);
}

test "fuzzy: positions are grapheme indices, not byte offsets" {
    const haystack = "a😊b";
    const s = (try score(haystack, "ab", .{})).?;
    try std.testing.expectEqual(@as(u8, 2), s.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, s.positions[0..s.len]);
    // The emoji is one grapheme (4 bytes, 2 columns), so 'b' sits at
    // grapheme 2 but byte 5: index 2 can only be a grapheme index.
    try std.testing.expectEqual(@as(isize, 2), Width.graphemeWidth("😊"));
    try std.testing.expectEqual(@as(usize, 6), haystack.len);
    try std.testing.expectEqual(@as(u8, 'b'), haystack[5]);
}

test "fuzzy: an emoji cluster matches whole and positions stay grapheme-based" {
    const s = (try score("🚀rocket", "et", .{})).?;
    // r o c k e t -> graphemes 1..6 behind the rocket.
    try std.testing.expectEqualSlices(usize, &.{ 5, 6 }, s.positions[0..s.len]);
    try std.testing.expectEqual(@as(usize, 1), s.rank.adjacent);
    try std.testing.expectEqual(@as(usize, 7), s.rank.haystack);
    // The rocket is not 'r': a needle grapheme never matches part of a
    // cluster.
    try std.testing.expect((try score("🚀", "r", .{})) == null);
}

test "fuzzy: a needle grapheme matches a whole cluster, never part of one" {
    const combined = "e\u{301}x"; // e + combining acute, then x
    const at_x = (try score(combined, "x", .{})).?;
    try std.testing.expectEqualSlices(usize, &.{1}, at_x.positions[0..at_x.len]);
    const whole = (try score(combined, "e\u{301}", .{})).?;
    try std.testing.expectEqualSlices(usize, &.{0}, whole.positions[0..whole.len]);
    // 'e' alone is not the first cluster, and the cluster after it is
    // 'x': no match.
    try std.testing.expect((try score(combined, "e", .{})) == null);
}

test "fuzzy: non-ASCII folds through the seam, and the flag opts out" {
    const folded = (try score("Bär", "bä", .{})).?;
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, folded.positions[0..folded.len]);
    try std.testing.expectEqual(@as(usize, 1), folded.rank.adjacent);
    // Same input, exact comparison: 'B' is not 'b'.
    try std.testing.expect((try score("Bär", "bä", .{ .fold_case = false })) == null);
    // Uppercase needle against lowercase haystack, and the reverse.
    const upper_needle = (try score("bär", "BÄ", .{})).?;
    try std.testing.expectEqual(@as(u8, 2), upper_needle.len);
}

test "fuzzy: the greedy pass reports the leftmost alignment" {
    const s = (try score("abcabc", "abc", .{})).?;
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, s.positions[0..s.len]);
    try std.testing.expectEqual(@as(usize, 2), s.rank.adjacent);
    try std.testing.expectEqual(@as(u8, 1), s.rank.anchored);
    try std.testing.expectEqual(@as(usize, 0), s.rank.first);
}

test "fuzzy: exactly max_needle graphemes is legal, one more errors" {
    const at_bound: [max_needle]u8 = @splat('a');
    const past_bound: [max_needle + 1]u8 = @splat('a');
    const haystack: [max_needle + 1]u8 = @splat('a');

    // The bound check on its own counts clusters, not bytes.
    try std.testing.expectEqual(@as(usize, 0), try needleGraphemes(""));
    try std.testing.expectEqual(@as(usize, 2), try needleGraphemes("ä😊"));
    try std.testing.expectEqual(@as(usize, max_needle), try needleGraphemes(&at_bound));
    try std.testing.expectError(error.NeedleTooLong, needleGraphemes(&past_bound));

    const got = (try score(&haystack, &at_bound, .{})).?;
    try std.testing.expectEqual(@as(u8, max_needle), got.len);
    try std.testing.expectEqual(@as(usize, max_needle - 1), got.rank.adjacent);

    try std.testing.expectError(error.NeedleTooLong, score(&haystack, &past_bound, .{}));
    // The bound is the needle's alone: an over-long needle errors even
    // when it could not have matched.
    try std.testing.expectError(error.NeedleTooLong, score("ab", &past_bound, .{}));
}
