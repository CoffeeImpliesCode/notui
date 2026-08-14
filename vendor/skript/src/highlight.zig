//! Tree-sitter based syntax highlighting for Skript source.
//!
//! This is the shared highlight engine: the REPL history renderer
//! (repl.zig) and the CodeArea highlighter (third_party/zigzag) consume
//! the same capture ranges. The engine itself is zigzag-free.
//!
//! The Skript grammar comes from the sibling tree-sitter-skript checkout
//! (src/parser.c, compiled and linked by build.zig; queries/highlights.scm
//! is embedded at build time as the generated `highlight_query` module),
//! and the tree-sitter runtime is the system shared libtree-sitter. All C
//! entry points are declared here.
//!
//! Tree-sitter 0.26 does not evaluate query predicates (`#eq?`, `#match?`,
//! …) in the C core — the host must do it. The engine implements the
//! standard predicate set on top of a small regex matcher.
//!
//! SAFETY: a tree-sitter Parser is not thread-safe. The engine must only
//! be used from one thread — the REPL host thread (Query.submit). The
//! scheduler runner thread never touches it.

const std = @import("std");

/// A syntax token kind. Shared vocabulary between the REPL renderer and
/// the CodeArea highlighter; consumers map it to their own styles.
pub const Capture = enum {
    keyword,
    string,
    comment,
    number,
    constant,
    function,
    operator,
    punctuation,
    builtin,
    plain,
};

/// One highlighted span of source. Byte offsets into the buffer that was
/// parsed; ranges are sorted by start and never overlap.
pub const Range = struct {
    start: usize,
    end: usize,
    capture: Capture,
};

/// The grammar's highlight query, embedded at compile time: build.zig
/// reads the sibling checkout's queries/highlights.scm and generates this
/// module (a source @embedFile cannot reach outside the package root).
const highlights_scm = @import("highlight_query").highlights_scm;

/// Language entry point exported by the tree-sitter-skript grammar.
extern fn tree_sitter_skript() callconv(.c) *const anyopaque;

// --- Tree-sitter C ABI (libtree-sitter 0.26) ---

const Parser = opaque {};
const Tree = opaque {};
const Query = opaque {};
const QueryCursor = opaque {};

const Node = extern struct {
    context: [4]u32,
    id: *const anyopaque,
    tree: *const Tree,
};

const QueryCapture = extern struct {
    node: Node,
    index: u32,
};

const QueryMatch = extern struct {
    id: u32,
    pattern_index: u16,
    capture_count: u16,
    captures: [*c]const QueryCapture,
};

const PredicateStepType = enum(c_uint) {
    done = 0,
    capture,
    string,
};

const PredicateStep = extern struct {
    type: PredicateStepType,
    value_id: u32,
};

const QueryError = enum(c_int) {
    none = 0,
    syntax,
    node_type,
    field,
    capture,
    structure,
    language,
};

extern fn ts_parser_new() ?*Parser;
extern fn ts_parser_delete(self: *Parser) void;
extern fn ts_parser_set_language(self: *Parser, language: *const anyopaque) bool;
extern fn ts_parser_parse_string_encoding(
    self: *Parser,
    old_tree: ?*const Tree,
    string: [*]const u8,
    length: u32,
    encoding: u32,
) ?*Tree;
extern fn ts_tree_delete(self: *Tree) void;
extern fn ts_tree_root_node(self: *const Tree) Node;
extern fn ts_node_start_byte(self: Node) u32;
extern fn ts_node_end_byte(self: Node) u32;
extern fn ts_node_is_error(self: Node) bool;
extern fn ts_query_new(
    language: *const anyopaque,
    source: [*]const u8,
    source_len: u32,
    error_offset: *u32,
    error_type: *QueryError,
) ?*Query;
extern fn ts_query_delete(self: *Query) void;
extern fn ts_query_capture_name_for_id(self: *const Query, index: u32, length: *u32) [*c]const u8;
extern fn ts_query_string_value_for_id(self: *const Query, index: u32, length: *u32) [*c]const u8;
extern fn ts_query_predicates_for_pattern(
    self: *const Query,
    pattern_index: u32,
    step_count: *u32,
) [*c]const PredicateStep;
extern fn ts_query_cursor_new() ?*QueryCursor;
extern fn ts_query_cursor_delete(self: *QueryCursor) void;
extern fn ts_query_cursor_exec(self: *QueryCursor, query: *const Query, node: Node) void;
extern fn ts_query_cursor_next_capture(self: *QueryCursor, match: *QueryMatch, capture_index: *u32) bool;

/// The highlighting engine: one Parser, one Query, one reusable
/// QueryCursor. Initialize once at REPL startup; deinit at shutdown.
pub const Engine = struct {
    parser: *Parser,
    query: *Query,
    cursor: *QueryCursor,

    /// Build the parser, assign the Skript language and compile the
    /// embedded highlights query.
    pub fn init() !Engine {
        const parser = ts_parser_new() orelse return error.ParserInitFailed;
        errdefer ts_parser_delete(parser);
        const language = tree_sitter_skript();
        if (!ts_parser_set_language(parser, language)) return error.IncompatibleLanguage;
        var error_offset: u32 = 0;
        var error_type: QueryError = .none;
        const query = ts_query_new(
            language,
            highlights_scm.ptr,
            @intCast(highlights_scm.len),
            &error_offset,
            &error_type,
        ) orelse return error.QueryInitFailed;
        errdefer ts_query_delete(query);
        const cursor = ts_query_cursor_new() orelse return error.CursorInitFailed;
        return .{ .parser = parser, .query = query, .cursor = cursor };
    }

    pub fn deinit(self: *Engine) void {
        ts_query_cursor_delete(self.cursor);
        ts_query_delete(self.query);
        ts_parser_delete(self.parser);
        self.* = undefined;
    }

    /// Parse `src` and run the highlights query, returning one Range per
    /// captured node (ERROR nodes map to .plain). Captures whose pattern
    /// fails its predicates are dropped. The result is sorted by start
    /// offset and non-overlapping: when several patterns capture the same
    /// node, the most specific capture wins.
    pub fn ranges(
        self: *Engine,
        allocator: std.mem.Allocator,
        src: []const u8,
    ) ![]const Range {
        const tree = ts_parser_parse_string_encoding(
            self.parser,
            null,
            src.ptr,
            @intCast(src.len),
            0, // UTF8
        ) orelse return error.ParseFailed;
        defer ts_tree_delete(tree);

        ts_query_cursor_exec(self.cursor, self.query, ts_tree_root_node(tree));

        var out: std.ArrayList(Range) = .empty;
        // SAFETY: tree-sitter writes match before returning true from next_capture.
        var match: QueryMatch = undefined;
        var capture_index: u32 = 0;
        while (ts_query_cursor_next_capture(self.cursor, &match, &capture_index)) {
            const capture = match.captures[capture_index];
            if (!predicatesPass(self, match, src)) continue;
            const node = capture.node;
            var name_len: u32 = 0;
            const name_ptr = ts_query_capture_name_for_id(self.query, capture.index, &name_len);
            const name = if (name_ptr) |p| p[0..name_len] else "";
            const capture_kind: Capture = if (ts_node_is_error(node))
                .plain
            else
                captureForName(name);
            try out.append(allocator, .{
                .start = ts_node_start_byte(node),
                .end = ts_node_end_byte(node),
                .capture = capture_kind,
            });
        }

        // Sort: earliest first; on equal starts the more specific capture
        // (higher priority) and the longer span come first, so the
        // overlap filter below keeps the best match.
        std.mem.sort(Range, out.items, {}, lessThan);
        var kept: usize = 0;
        var last_end: usize = 0;
        for (out.items) |r| {
            if (kept > 0 and r.start < last_end) continue;
            out.items[kept] = r;
            kept += 1;
            last_end = r.end;
        }
        out.shrinkRetainingCapacity(kept);
        return out.toOwnedSlice(allocator);
    }

    /// Evaluate every predicate of `match`'s pattern against the match's
    /// captures (host-side, as tree-sitter 0.26 requires). An unknown
    /// predicate name fails the match (conservative: drop the capture).
    fn predicatesPass(self: *Engine, match: QueryMatch, src: []const u8) bool {
        var step_count: u32 = 0;
        const steps = ts_query_predicates_for_pattern(self.query, match.pattern_index, &step_count);
        if (step_count == 0) return true;
        const slice = steps[0..step_count];
        var i: usize = 0;
        while (i < slice.len) {
            // Predicate name: first step, always a string (e.g. "eq?").
            if (slice[i].type != .string) return false;
            const name = self.stringValue(slice[i].value_id) orelse return false;
            i += 1;
            // Arguments until the Done sentinel.
            var args_buf: [8]Arg = undefined;
            var arg_count: usize = 0;
            while (i < slice.len and slice[i].type != .done) : (i += 1) {
                if (arg_count >= args_buf.len) return false;
                const step = slice[i];
                switch (step.type) {
                    .capture => {
                        const node = captureNodeForId(match, step.value_id) orelse return false;
                        args_buf[arg_count] = .{ .text = nodeText(node, src) };
                    },
                    .string => {
                        const v = self.stringValue(step.value_id) orelse return false;
                        args_buf[arg_count] = .{ .text = v };
                    },
                    .done => unreachable,
                }
                arg_count += 1;
            }
            if (i >= slice.len) return false; // unterminated predicate
            i += 1; // consume Done
            const args = args_buf[0..arg_count];
            if (!evalPredicate(name, args)) return false;
        }
        return true;
    }

    fn stringValue(self: *Engine, id: u32) ?[]const u8 {
        var len: u32 = 0;
        const p = ts_query_string_value_for_id(self.query, id, &len);
        return if (p) |ptr| ptr[0..len] else null;
    }
};

const Arg = struct {
    text: []const u8,
};

/// The node captured with the given capture id within this match.
fn captureNodeForId(match: QueryMatch, capture_id: u32) ?Node {
    const caps = match.captures[0..match.capture_count];
    for (caps) |c| {
        if (c.index == capture_id) return c.node;
    }
    return null;
}

fn nodeText(node: Node, src: []const u8) []const u8 {
    return src[ts_node_start_byte(node)..ts_node_end_byte(node)];
}

/// Evaluate one predicate (name + resolved arguments) per tree-sitter's
/// standard host-side set. "match?"/"not-match?" use the minimal regex
/// matcher; unknown names fail (drop the capture).
fn evalPredicate(name: []const u8, args: []const Arg) bool {
    if (std.mem.eql(u8, name, "eq?")) {
        return args.len == 2 and std.mem.eql(u8, args[0].text, args[1].text);
    }
    if (std.mem.eql(u8, name, "not-eq?")) {
        return args.len == 2 and !std.mem.eql(u8, args[0].text, args[1].text);
    }
    if (std.mem.eql(u8, name, "match?")) {
        return args.len == 2 and rxMatch(args[1].text, args[0].text);
    }
    if (std.mem.eql(u8, name, "not-match?")) {
        return args.len == 2 and !rxMatch(args[1].text, args[0].text);
    }
    if (std.mem.eql(u8, name, "any-of?")) {
        if (args.len < 2) return false;
        for (args[1..]) |s| {
            if (std.mem.eql(u8, args[0].text, s.text)) return true;
        }
        return false;
    }
    if (std.mem.eql(u8, name, "not-any-of?")) {
        if (args.len < 2) return false;
        for (args[1..]) |s| {
            if (std.mem.eql(u8, args[0].text, s.text)) return true;
        }
        return false;
    }
    return false;
}

fn lessThan(_: void, a: Range, b: Range) bool {
    if (a.start != b.start) return a.start < b.start;
    const pa = priority(a.capture);
    const pb = priority(b.capture);
    if (pa != pb) return pa > pb;
    return a.end > b.end;
}

/// Specificity of a capture kind, used to break ties when several
/// patterns captured the same node.
fn priority(capture: Capture) u8 {
    return switch (capture) {
        .keyword => 7,
        // @function.builtin specializes the generic @function head.
        .builtin => 6,
        .function => 5,
        .string, .comment, .number, .constant => 4,
        .operator => 3,
        .punctuation => 2,
        .plain => 0,
    };
}

/// Map a capture name (e.g. "keyword.conditional", "function.call",
/// "punctuation.bracket", "string.special.symbol") onto the shared
/// Capture enum. The primary name decides; the dotted suffix is
/// informational. Unknown names (variables, errors, …) map to .plain.
fn captureForName(name: []const u8) Capture {
    if (std.mem.startsWith(u8, name, "keyword")) return .keyword;
    if (std.mem.startsWith(u8, name, "string")) return .string;
    if (std.mem.startsWith(u8, name, "comment")) return .comment;
    if (std.mem.startsWith(u8, name, "number")) return .number;
    // Booleans (#t/#f) are constants.
    if (std.mem.startsWith(u8, name, "constant") or std.mem.startsWith(u8, name, "boolean"))
        return .constant;
    // @function.builtin (builtin heads, @-intrinsics) specializes the
    // generic @function head capture; the longer prefix must win.
    if (std.mem.startsWith(u8, name, "function.builtin")) return .builtin;
    if (std.mem.startsWith(u8, name, "function")) return .function;
    if (std.mem.startsWith(u8, name, "operator")) return .operator;
    if (std.mem.startsWith(u8, name, "punctuation")) return .punctuation;
    if (std.mem.startsWith(u8, name, "builtin")) return .builtin;
    return .plain;
}

// --- Minimal regex matcher for query predicates ---
//
// Tree-sitter 0.26 evaluates `#match?` predicates host-side; zig 0.16's
// std has no regex engine, so this implements the subset query authors
// actually use: literal characters, '.', character classes (negation,
// ranges, escapes, the \d \w \s shorthands), quantifiers '+', '*', '?',
// and '^'/'$' anchors. No groups, alternation, or backreferences. This
// covers the grammar's highlights.scm and the usual tree-sitter query
// predicates.

const ClassBitmap = struct {
    set: [32]u8 = [_]u8{0} ** 32, // 256 bits

    fn has(self: *const ClassBitmap, c: u8) bool {
        return (self.set[c >> 3] >> @intCast(c & 7)) & 1 == 1;
    }

    fn add(self: *ClassBitmap, c: u8) void {
        self.set[c >> 3] |= @as(u8, 1) << @intCast(c & 7);
    }
};

/// Max distinct end positions a sub-expression can produce for one start
/// position (node texts in queries are short identifiers; 128 is ample).
const max_ends = 128;

/// Match `pattern` against `text` with search semantics (unanchored
/// unless the pattern is anchored with '^'/'$'), mirroring how
/// tree-sitter's `#match?` regex behaves on node text. Alternation
/// returns every possible end position, so the trailing '$' is decided
/// by set membership — ordered-alternation prefixes (">" vs ">=", "def"
/// vs "defn") resolve correctly.
fn rxMatch(pattern: []const u8, text: []const u8) bool {
    const anchored_start = pattern.len > 0 and pattern[0] == '^';
    const body = if (anchored_start) pattern[1..] else pattern;
    const anchored_end = body.len > 0 and body[body.len - 1] == '$';
    const body_no_end = if (anchored_end) body[0 .. body.len - 1] else body;

    var start: usize = 0;
    while (true) {
        var ends_buf: [max_ends]usize = undefined;
        const n = matchEnds(body_no_end, 0, body_no_end.len, text, start, &ends_buf);
        if (n > 0) {
            if (!anchored_end) return true;
            for (ends_buf[0..n]) |e| {
                if (e == text.len) return true;
            }
        }
        if (anchored_start or start == text.len) return false;
        start += 1;
    }
}

/// Fill `out` with every text position at which pattern[start..end] can
/// end, given it must start at `t`. Returns the count written.
fn matchEnds(
    pattern: []const u8,
    start: usize,
    end: usize,
    text: []const u8,
    t: usize,
    out: []usize,
) usize {
    if (start >= end) return addEnd(out, t, 0);

    // Alternation: if the range contains a '|' outside any group, the
    // result is the union of every alternative's end positions. (The
    // trailing '$' anchor is then decided by set membership, so ordered
    // alternatives with shared prefixes — ">" vs ">=", "def" vs "defn" —
    // resolve correctly.)
    var scan_depth: usize = 0;
    var si = start;
    while (si < end) : (si += 1) {
        switch (pattern[si]) {
            '\\' => {
                si += 1; // escaped char: skip both bytes
            },
            '(' => scan_depth += 1,
            ')' => {
                if (scan_depth > 0) scan_depth -= 1;
            },
            '|' => if (scan_depth == 0) {
                var out_n: usize = 0;
                var alt_start = start;
                var alt_end = start;
                while (alt_end <= end) : (alt_end += 1) {
                    if (alt_end == end or pattern[alt_end] == '|') {
                        out_n = unionEnds(pattern, alt_start, alt_end, text, t, out, out_n);
                        alt_start = alt_end + 1;
                    }
                }
                return out_n;
            },
            else => {},
        }
    }

    // Parse one atom: a group (...), a [...] class, an escaped char, or
    // a single literal/'.'.
    var atom_end: usize = 0;
    var is_group = false;
    if (pattern[start] == '(') {
        is_group = true;
        var depth: usize = 1;
        atom_end = start + 1;
        while (atom_end < end and depth > 0) : (atom_end += 1) {
            if (pattern[atom_end] == '(') depth += 1;
            if (pattern[atom_end] == ')') depth -= 1;
        }
    } else if (pattern[start] == '[') {
        atom_end = start + 1;
        while (atom_end < end and pattern[atom_end] != ']') atom_end += 1;
        atom_end += 1; // include the ']'
    } else if (pattern[start] == '\\') {
        atom_end = start + 2;
    } else {
        atom_end = start + 1;
    }
    var rest = atom_end;
    var quantifier: u8 = 0;
    if (rest < end) {
        const q = pattern[rest];
        if (q == '+' or q == '*' or q == '?') {
            quantifier = q;
            rest += 1;
        }
    }

    // End positions after this atom, starting from t.
    var after: [max_ends]usize = undefined;
    var after_n: usize = 0;
    if (is_group) {
        const g_start = start + 1;
        const g_end = atom_end -| 1;
        if (quantifier == 0) {
            after_n = matchEnds(pattern, g_start, g_end, text, t, &after);
        } else {
            after_n = repeatGroupEnds(pattern, g_start, g_end, text, t, quantifier, &after);
        }
    } else if (quantifier == 0) {
        if (t < text.len and atomMatch(pattern, start, atom_end, text[t])) {
            after_n = addEnd(&after, t + 1, 0);
        }
    } else {
        after_n = repeatCharEnds(pattern, start, atom_end, text, t, quantifier, &after);
    }

    // Chain the remainder of the sequence from every `after` position.
    var out_n: usize = 0;
    for (after[0..after_n]) |a| {
        out_n = unionEnds(pattern, rest, end, text, a, out, out_n);
    }
    return out_n;
}

/// End positions after matching the group pattern[g_start..g_end] between
/// 0 (or 1 for '+') and the maximum number of times from `t`.
fn repeatGroupEnds(
    pattern: []const u8,
    g_start: usize,
    g_end: usize,
    text: []const u8,
    t: usize,
    quantifier: u8,
    out: []usize,
) usize {
    var reachable: [max_ends]usize = undefined;
    var n = addEnd(&reachable, t, 0);
    var frontier = reachable[0..n];
    while (frontier.len > 0) {
        var next: [max_ends]usize = undefined;
        var next_n: usize = 0;
        for (frontier) |p| {
            var ends: [max_ends]usize = undefined;
            const en = matchEnds(pattern, g_start, g_end, text, p, &ends);
            for (ends[0..en]) |e| {
                if (e == p) continue; // zero-width repetition
                next_n = addEnd(&next, e, next_n);
            }
        }
        for (next[0..next_n]) |e| n = addEnd(&reachable, e, n);
        frontier = next[0..next_n];
    }
    const min: usize = if (quantifier == '+') 1 else 0;
    if (min == 0) return n;
    // '+': drop the zero-repetition position (t itself).
    var out_n: usize = 0;
    for (reachable[0..n]) |e| {
        if (e != t) out_n = addEnd(out, e, out_n);
    }
    return out_n;
}

/// End positions after matching a single-character atom repeated between
/// 0 (or 1 for '+') and the maximum run length from `t`.
fn repeatCharEnds(
    pattern: []const u8,
    atom_start: usize,
    atom_end: usize,
    text: []const u8,
    t: usize,
    quantifier: u8,
    out: []usize,
) usize {
    var run: usize = 0;
    while (t + run < text.len and atomMatch(pattern, atom_start, atom_end, text[t + run])) run += 1;
    const min: usize = if (quantifier == '+') 1 else 0;
    var n: usize = 0;
    var k = run;
    while (k >= min) : (k -= 1) {
        n = addEnd(out, t + k, n);
        if (k == min) break;
    }
    return n;
}

/// Match a single unquantified atom (a [...] class, an escaped char,
/// '.', or a literal) against `c`.
fn atomMatch(pattern: []const u8, p: usize, atom_end: usize, c: u8) bool {
    if (pattern[p] == '[') return classMatch(pattern[p..atom_end], c);
    if (pattern[p] == '.') return true;
    if (pattern[p] == '\\') return p + 1 < atom_end and pattern[p + 1] == c;
    return pattern[p] == c;
}

/// Append `end` to `out[0..n]` if absent; returns the new count.
fn addEnd(out: []usize, end: usize, n: usize) usize {
    if (n >= out.len) return n;
    for (out[0..n]) |e| {
        if (e == end) return n;
    }
    out[n] = end;
    return n + 1;
}

/// Union of the end positions of pattern[rest..end] from `t` into `out`.
fn unionEnds(
    pattern: []const u8,
    rest: usize,
    end: usize,
    text: []const u8,
    t: usize,
    out: []usize,
    n: usize,
) usize {
    var buf: [max_ends]usize = undefined;
    const en = matchEnds(pattern, rest, end, text, t, &buf);
    var out_n = n;
    for (buf[0..en]) |e| out_n = addEnd(out, e, out_n);
    return out_n;
}

fn classMatch(class: []const u8, c: u8) bool {
    std.debug.assert(class.len >= 2);
    std.debug.assert(class[0] == '[');
    std.debug.assert(class[class.len - 1] == ']');
    var bitmap: ClassBitmap = .{};
    var i: usize = 1;
    const negated = class[i] == '^';
    if (negated) i += 1;
    while (i < class.len - 1) {
        if (class[i] == '\\') {
            // Escaped char or shorthand (\d \w \s); a shorthand adds its
            // whole set and consumes no literal.
            if (i + 1 < class.len - 1 and shorthandClass(&bitmap, class[i + 1])) {
                i += 2;
                continue;
            }
            if (i + 1 < class.len - 1) {
                bitmap.add(class[i + 1]);
                i += 2;
                continue;
            }
            bitmap.add(class[i]);
            i += 1;
            continue;
        }
        const lo = class[i];
        i += 1;
        if (i + 1 < class.len - 1 and class[i] == '-' and class[i + 1] != ']') {
            i += 1;
            // SAFETY: either branch assigns hi before addRange reads it.
            var hi: u8 = undefined;
            if (class[i] == '\\' and i + 1 < class.len - 1) {
                hi = class[i + 1];
                i += 2;
            } else {
                hi = class[i];
                i += 1;
            }
            addRange(&bitmap, lo, hi);
            continue;
        }
        bitmap.add(lo);
    }
    const in = bitmap.has(c);
    return if (negated) !in else in;
}

fn addRange(bitmap: *ClassBitmap, lo0: u8, hi0: u8) void {
    const lo = @min(lo0, hi0);
    const hi = @max(lo0, hi0);
    var v = lo;
    while (true) : (v += 1) {
        bitmap.add(v);
        if (v == hi) break;
    }
}

/// Add the \d \w \s shorthands to the bitmap. Returns false for a plain
/// escaped char (\. \- \\ …), which the caller treats as a literal.
fn shorthandClass(bitmap: *ClassBitmap, c: u8) bool {
    switch (c) {
        'd' => {
            for ('0'..'9' + 1) |v| bitmap.add(@intCast(v));
            return true;
        },
        'w' => {
            for ('0'..'9' + 1) |v| bitmap.add(@intCast(v));
            for ('a'..'z' + 1) |v| bitmap.add(@intCast(v));
            for ('A'..'Z' + 1) |v| bitmap.add(@intCast(v));
            bitmap.add('_');
            return true;
        },
        's' => {
            for ([_]u8{ ' ', '\t', '\n', '\r', 0x0b, 0x0c }) |v| bitmap.add(v);
            return true;
        },
        else => return false,
    }
}
