//! ztex.parse.error — parse-error context (kind + span + message).
//!
//! Lexer/parser error-return sites are bare error-set values (`error.Xxx`)
//! with no position. Threading an `?*Info` out-param through `lex`/`parse`
//! lets clients pretty-print the failure: the kind, the byte span of the
//! offending input, and a TeX-style message. The error VALUES are unchanged
//! (tests still `expectError` them); `Info` is only filled when a caller
//! passes a non-null pointer, and only immediately before the matching
//! error is returned.

const std = @import("std");
const atom = @import("ztex.atom");

/// The failure kinds, one per lexer/parser error-set member. Each parser
/// kind maps to exactly one error value in the parser's `fail` helper (the
/// lexer's two kinds are returned directly at their sites), so a site can
/// record an `Info` and return the SAME bare error it returned before
/// (error-value compatibility is load-bearing for `expectError` tests).
pub const Kind = enum {
    dangling_escape,
    invalid_utf8,
    unexpected_r_group,
    unexpected_script,
    double_script,
    unknown_command,
    missing_argument,
    missing_script,
    unclosed_group,
    unexpected_middle,
    unknown_environment,
    mismatched_end,
    unclosed_environment,
};

/// Parse-error context filled by `lex`/`parse` when the caller passes a
/// non-null `err_info` out-param. On success the out-param is untouched.
pub const Info = struct {
    kind: Kind,
    /// Byte span of the offending input into the source. Zero-width at end
    /// of source when the error is "expected X but hit end of input"
    /// (e.g. `\frac{a}` — the missing denominator's position).
    span: atom.Span,

    /// A concrete TeX-style message for this kind.
    pub fn message(self: Info) []const u8 {
        return switch (self.kind) {
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
        };
    }
};

/// 1-based (line, column) of byte `offset` in `src`. Column counts BYTES
/// from the line start (sufficient for a caret under ASCII math input;
/// for multi-byte input the caret may sit mid-codepoint).
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
/// (so a CRLF-terminated line prints clean). Empty source yields "".
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
