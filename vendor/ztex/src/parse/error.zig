//! ztex.parse.error — parse-failure context (kind + span + message).
//!
//! Lexer and parser error-return sites are bare error-set values
//! (`error.Xxx`) with no position. Threading a `?*Info` out-param through
//! `lex`/`parse` lets clients pretty-print the failure: what went wrong, the
//! byte span of the offending input when there is one, and a TeX-style
//! message. The error VALUES are unchanged (`expectError` still sees
//! `error.Xxx`); `Info` is filled only when a caller passes a non-null
//! pointer, and only on a path that returns an error.
//!
//! `Info` names every error `ztex.parse.parse` can return, so a caller that
//! checks the error tag never has to guess whether the out-param holds
//! anything. A caller that reads `Info` must still know WHICH error it
//! received: a failure after the parse stage — layout, or the caller's own
//! work — leaves the out-param untouched, because only the parse stage
//! writes it.

const std = @import("std");
const atom = @import("ztex.atom");

/// The failure kinds, one per member of `ztex.parse.Error`. Every kind maps
/// to exactly one error value, so a site can record an `Info` and return the
/// same bare error it returned before (error-value compatibility is
/// load-bearing for `expectError` tests).
pub const Kind = enum {
    /// Allocation failed inside the lexer, the parser, or the pool they
    /// append to. Attributable to no byte range, so `Info.span` is `null` on
    /// this kind — the only kind for which that is true. It corresponds to
    /// `error.OutOfMemory`, which is also reachable from stages that do NOT
    /// write `Info` (`ztex.layout.render`, a caller's own work), so a caller
    /// that mixes a parse stage with another fallible stage must check the
    /// error tag rather than assume a written `Info` came from the parse.
    out_of_memory,
    dangling_escape,
    invalid_utf8,
    unexpected_r_group,
    /// A `^` or `_` token with no base to attach to — nothing precedes it
    /// that could take the script. `Info.span` covers the marker itself.
    unexpected_script,
    /// A `^` on a base that already has a superscript, or a `_` on a base
    /// that already has a subscript; TeX's double script. A prime also
    /// lands here, because a prime fills the superscript slot.
    double_script,
    unknown_command,
    missing_argument,
    /// A `^` or `_` field with nothing after the marker: the input ends
    /// where the script should start. `Info.span` is the zero-width
    /// position where the field was expected.
    missing_script,
    unclosed_group,
    unexpected_middle,
    unknown_environment,
    mismatched_end,
    unclosed_environment,
    /// Row nesting deeper than the parser's recursion guard
    /// (`ztex.parse.parser.max_row_depth`). `Error.StackOverflow` is returned
    /// rather than overflowing the call stack; the span is the token the
    /// parser stopped at, which is where the excess nesting begins.
    depth_exceeded,
};

/// Parse-failure context, written by `ztex.parse.lexer.lex`,
/// `ztex.parse.parser.Parser.parse` and `ztex.parse.parse` — and by nothing
/// else — only on a path that returns an error, and only when the caller
/// passed a non-null out-param. On success the out-param is untouched, so a
/// caller that reuses one `Info` across calls reads only what the call that
/// failed wrote.
pub const Info = struct {
    /// What went wrong. Every kind here corresponds to exactly one member of
    /// `ztex.parse.Error`, so a caller can map a received error onto it.
    kind: Kind,
    /// Byte span of the offending input into the source, or `null` when the
    /// failure is attributable to no byte range. A non-null span is
    /// zero-width at end of source when the error is "expected X but hit end
    /// of input" (e.g. `\frac{a}` — the missing denominator's position), so
    /// `span.end == span.start` means "here", not "nothing".
    span: ?atom.Span,

    /// A concrete TeX-style message for this kind.
    pub fn message(self: Info) []const u8 {
        return switch (self.kind) {
            .out_of_memory => "Out of memory",
            .dangling_escape => "Dangling escape",
            .invalid_utf8 => "Invalid UTF-8",
            .unexpected_r_group => "Unexpected '}'",
            .unexpected_script => "Unexpected script",
            .double_script => "Double script",
            .unknown_command => "Unknown command",
            .missing_argument => "Missing argument",
            .missing_script => "Missing script",
            .unclosed_group => "Unclosed group",
            .unexpected_middle => "Unexpected \\middle",
            .unknown_environment => "Unknown environment",
            .mismatched_end => "Mismatched \\end",
            .unclosed_environment => "Unclosed environment",
            .depth_exceeded => "Nesting too deep",
        };
    }
};

/// 1-based (line, column) of byte `offset` in `src`. Column counts BYTES
/// from the line start (sufficient for a caret under ASCII math input;
/// for multi-byte input the caret may sit mid-codepoint). `offset` is
/// clamped to `src.len`, so an offset past the end names end of input.
pub fn lineCol(src: []const u8, offset: usize) struct { line: usize, col: usize } {
    const o = @min(offset, src.len);
    var line: usize = 1;
    var line_start: usize = 0;
    for (src[0..o], 0..) |b, i| {
        if (b == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    return .{ .line = line, .col = o - line_start + 1 };
}

/// The source line containing byte `offset`, with a trailing `\r` trimmed
/// (so a CRLF-terminated line prints clean). The result borrows `src`.
/// Empty source yields ""; `offset` is clamped to `src.len`.
pub fn sourceLine(src: []const u8, offset: usize) []const u8 {
    const o = @min(offset, src.len);
    var start = o;
    while (start > 0 and src[start - 1] != '\n') start -= 1;
    var end = o;
    while (end < src.len and src[end] != '\n') end += 1;
    var line = src[start..end];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    return line;
}

// ── tests ────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "error: lineCol is 1-based per line" {
    const src = "ab\ncde\r\nf";
    // 'd' at offset 4: line 2, byte col 2
    const lc = lineCol(src, 4);
    try testing.expectEqual(@as(usize, 2), lc.line);
    try testing.expectEqual(@as(usize, 2), lc.col);
    try testing.expectEqual(@as(usize, 1), lineCol(src, 0).line);
    try testing.expectEqual(@as(usize, 1), lineCol(src, 0).col);
    // EOF is on the last line, one past its last byte
    const eof = lineCol(src, src.len);
    try testing.expectEqual(@as(usize, 3), eof.line);
    try testing.expectEqual(@as(usize, 2), eof.col);
    // an offset past EOF clamps to EOF
    try testing.expectEqual(eof.line, lineCol(src, src.len + 10).line);
    try testing.expectEqual(eof.col, lineCol(src, src.len + 10).col);
}

test "error: sourceLine returns the containing line, CR trimmed" {
    const src = "ab\ncde\r\nf";
    try testing.expectEqualStrings("ab", sourceLine(src, 0));
    try testing.expectEqualStrings("cde", sourceLine(src, 4)); // \r trimmed
    try testing.expectEqualStrings("f", sourceLine(src, 8));
    try testing.expectEqualStrings("", sourceLine("", 0));
}
