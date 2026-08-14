//! Tokenize input source code.
//! Tokens are similar in syntax to other lisps, such as Scheme, Clojure or Racket.
//! Token kinds:
//!     - strings: `"..."`
//!     - numbers: `123`, `123.45`
//!     - identifiers: `foo`, `bar-baz`, `dynamic-library:open`, `+`, `<`, `#t`
//!     - groupings: `(`, `)`, `[`, `]`, `{`, `}`
//!
//!  strings:
//!     - delimited by `"` characters, with `\` used to escape the following char
//!
//!  numbers:
//!     - integers: `123`
//!     - floats: `123.45`
//!
//!  identifiers:
//!     - start with any non-numeric, non-delimiter character
//!     - continue until whitespace or delimiter `(){}[];`
//!     - dotted paths like `foo.bar` are a single identifier token
//!     - `#t`, `#f` are identifiers
//!     - comparison operators like `<`, `>`, `=` are identifiers
//!
//!  groupings:
//!     - `(`, `)`: S-expressions / function calls
//!     - `[`, `]`: tensor literals (reader desugars `[e ...]` to `(stack e ...)`)
//!     - `{`, `}`: infix expressions or maps (disambiguated at parser level)
//!     - `:{`: map literal marker (reader desugars `:{ :k v ... }` to `(hash-map :k v ...)`)
//!
//!  comments:
//!     - `;` starts a line comment, runs to end of line
//!     - `#!` at the start of the file is a shebang line (also runs to end of line)

const std = @import("std");
const skript = @import("root.zig");
const Error = skript.Error;
const Token = @This();

pub const Cursor = struct {
    src: []const u8,
    line: u16 = 1,
    col: u16 = 1,
    offset: usize = 0,

    /// Advance `count` characters, tracking line/col.
    pub inline fn eat(self: *Cursor, count: usize) void {
        for (0..count) |_| {
            const curr = self.src[self.offset];
            switch (curr) {
                ' ', '\t', '\r' => {
                    self.col += 1;
                    self.offset += 1;
                },
                '\n' => {
                    self.line += 1;
                    self.col = 1;
                    self.offset += 1;
                },
                else => {
                    self.col += 1;
                    self.offset += 1;
                },
            }
        }
    }

    /// Peek at the next non-whitespace character without consuming it.
    /// Returns `null` at end of input.
    pub fn peekNonWhitespace(self: *const Cursor) ?u8 {
        var i: usize = 0;
        while (self.offset + i < self.src.len) {
            switch (self.src[self.offset + i]) {
                ' ', '\t', '\r', '\n' => i += 1,
                else => return self.src[self.offset + i],
            }
        }
        return null;
    }
};

pub const Kind = enum(u8) {
    null,
    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace,
    rbrace,
    period,
    quote,
    identifier,
    keyword,
    map_marker,
    number,
    string,
    datum_comment,
    eof,
};
pub const Index = skript.Index(@This(), u32);

start: u32 = 0,
end: u32 = 0,
line: u16 = 0,
col: u16 = 0,
kind: Kind = .null,

/// Top-level lexer: skip whitespace, line comments, and shebangs,
/// then dispatch to a specialized function for each token kind.
pub fn lex(c: *Cursor) Error!Token {
    try skipWhitespaceAndComments(c);
    if (c.offset >= c.src.len) {
        return token(c, c, .eof);
    }

    const curr = c.src[c.offset];
    switch (curr) {
        '(', ')', '{', '}', '[', ']', '.' => {
            const start = c.*;
            c.eat(1);
            const kind: Kind = switch (curr) {
                '(' => .lparen,
                ')' => .rparen,
                '{' => .lbrace,
                '}' => .rbrace,
                '[' => .lbracket,
                ']' => .rbracket,
                '.' => .period,
                else => unreachable,
            };
            return token(&start, c, kind);
        },
        39 => {
            const start = c.*;
            c.eat(1);
            return token(&start, c, .quote);
        },
        '0'...'9' => return lexNumber(c),
        'i', 'n' => {
            if (try matchSpecialFloat(c)) |tok| return tok;
            return lexIdentifier(c);
        },
        '-', '+' => {
            if (c.offset + 1 < c.src.len) {
                const next = c.src[c.offset + 1];
                if (isDigit(next) or next == 'i' or next == 'n') return lexNumber(c);
            }
            return lexIdentifier(c);
        },
        '"' => return lexString(c),
        '#' => {
            if (c.offset + 1 < c.src.len) {
                switch (c.src[c.offset + 1]) {
                    ';' => {
                        const start = c.*;
                        c.eat(2);
                        return token(&start, c, .datum_comment);
                    },
                    '|' => {
                        try skipBlockComment(c);
                        return lex(c);
                    },
                    'b', 'o', 'd', 'x' => return lexRadixNumber(c),
                    else => {},
                }
            }
            return lexIdentifier(c);
        },
        ':' => {
            // `:{` starts a map literal marker. Anything else after ':' stays
            // a keyword token (`:foo`); `:` followed by a delimiter or EOF
            // lexes as a zero-width keyword, which the reader rejects.
            if (c.offset + 1 < c.src.len and c.src[c.offset + 1] == '{') {
                const start = c.*;
                c.eat(2); // consume ':{'
                return token(&start, c, .map_marker);
            }
            return lexKeyword(c);
        },
        else => return lexIdentifier(c),
    }
}

/// Skip whitespace, line comments (`;`...`\n`), and an optional leading shebang.
/// Shebang (`#!`) is only recognized at offset 0.
/// A `#` past the first line always starts an identifier.
fn skipWhitespaceAndComments(c: *Cursor) Error!void {
    while (c.offset < c.src.len) {
        switch (c.src[c.offset]) {
            ' ', '\t', '\r', '\n' => c.eat(1),
            ';' => skipToEndOfLine(c),
            '#' => {
                if (c.offset == 0 and c.offset + 1 < c.src.len and c.src[c.offset + 1] == '!') {
                    skipToEndOfLine(c);
                } else {
                    return; // '#' starts an identifier
                }
            },
            else => return,
        }
    }
}

/// Consume characters until (and including) the next newline.
/// If no newline is found, consumes to end of input.
fn skipToEndOfLine(c: *Cursor) void {
    while (c.offset < c.src.len) {
        if (c.src[c.offset] == '\n') {
            c.eat(1);
            return;
        }
        c.eat(1);
    }
}

/// Skip a nested block comment: #| ... |#.
/// Depth tracks nesting so #| #| inner |# outer |# is handled correctly.
fn skipBlockComment(c: *Cursor) Error!void {
    c.eat(2); // consume opening #|
    var depth: u32 = 1;
    while (depth > 0) {
        if (c.offset + 1 >= c.src.len) return error.UnexpectedToken;
        if (c.src[c.offset] == '#' and c.src[c.offset + 1] == '|') {
            depth += 1;
            c.eat(2);
        } else if (c.src[c.offset] == '|' and c.src[c.offset + 1] == '#') {
            depth -= 1;
            c.eat(2);
        } else {
            c.eat(1);
        }
    }
}

/// Read an identifier. Starts with any non-delimiter character.
/// Continues until whitespace or one of `()"{}[];`.
/// `.` is not a delimiter, so qualified names like `foo.bar` are one token.
/// `"` IS a delimiter — `foo"bar"` tokenizes as `foo` + `"bar"`.
fn lexKeyword(c: *Cursor) Error!Token {
    // Skip the leading ':', then lex the identifier portion.
    c.eat(1);
    const start = c.*;
    while (c.offset < c.src.len) {
        switch (c.src[c.offset]) {
            ' ', '\t', '\r', '\n', '(', ')', '{', '}', '[', ']', ';', '"' => {
                return token(&start, c, .keyword);
            },
            else => c.eat(1),
        }
    }
    return token(&start, c, .keyword);
}

fn lexIdentifier(c: *Cursor) Error!Token {
    const start = c.*;
    c.eat(1);
    while (c.offset < c.src.len) {
        switch (c.src[c.offset]) {
            ' ', '\t', '\r', '\n', '(', ')', '{', '}', '[', ']', ';', '"' => {
                return token(&start, c, .identifier);
            },
            else => c.eat(1),
        }
    }
    return token(&start, c, .identifier);
}

/// Read a numeric literal. Supports integers, floats, and scientific notation.
/// The next character after a number must be whitespace, delimiter, or EOF.
fn lexNumber(c: *Cursor) Error!Token {
    const start = c.*;
    c.eat(1); // consume first char (digit, sign, i, or n)

    // Special float: [sign] inf.0 or [sign] nan.0
    if (matchSpecialFloatAfterSign(c)) {
        c.eat(5);
        // Check for complex suffix: inf.0+2.0i
        if (c.offset < c.src.len and (c.src[c.offset] == '+' or c.src[c.offset] == '-')) {
            const saved = .{ .offset = c.offset, .col = c.col };
            c.eat(1);
            if (c.offset < c.src.len and isDigit(c.src[c.offset])) {
                while (c.offset < c.src.len and isDigit(c.src[c.offset])) c.eat(1);
                if (c.offset < c.src.len and c.src[c.offset] == '.') {
                    c.eat(1);
                    while (c.offset < c.src.len and isDigit(c.src[c.offset])) c.eat(1);
                }
                if (c.offset < c.src.len and c.src[c.offset] == 'i') {
                    c.eat(1);
                    return token(&start, c, .number);
                }
            }
            c.offset = saved.offset;
            c.col = saved.col;
        }
        return token(&start, c, .number);
    }

    // Regular number: digits...
    while (c.offset < c.src.len and isDigit(c.src[c.offset])) {
        c.eat(1);
    }
    if (c.offset < c.src.len and c.src[c.offset] == '.') {
        c.eat(1);
        if (c.offset >= c.src.len or !isDigit(c.src[c.offset])) {
            return error.UnexpectedToken;
        }
        while (c.offset < c.src.len and isDigit(c.src[c.offset])) {
            c.eat(1);
        }
    }
    // Scientific notation: optional exponent e/E followed by optional sign and digits
    if (c.offset < c.src.len and (c.src[c.offset] == 'e' or c.src[c.offset] == 'E')) {
        c.eat(1);
        if (c.offset < c.src.len and (c.src[c.offset] == '+' or c.src[c.offset] == '-')) {
            c.eat(1);
        }
        if (c.offset >= c.src.len or !isDigit(c.src[c.offset])) {
            return error.UnexpectedToken;
        }
        while (c.offset < c.src.len and isDigit(c.src[c.offset])) {
            c.eat(1);
        }
    }
    // Complex literal: real±imagi or imagi
    if (c.offset < c.src.len and c.src[c.offset] == 'i') {
        c.eat(1);
        return token(&start, c, .number);
    }
    if (c.offset < c.src.len and (c.src[c.offset] == '+' or c.src[c.offset] == '-')) {
        const saved = .{ .offset = c.offset, .col = c.col };
        c.eat(1); // consume the sign
        if (c.offset < c.src.len and isDigit(c.src[c.offset])) {
            while (c.offset < c.src.len and isDigit(c.src[c.offset])) {
                c.eat(1);
            }
            if (c.offset < c.src.len and c.src[c.offset] == '.') {
                c.eat(1);
                while (c.offset < c.src.len and isDigit(c.src[c.offset])) {
                    c.eat(1);
                }
            }
            // Scientific notation in imaginary part: e.g. 4e-3i
            if (c.offset < c.src.len and (c.src[c.offset] == 'e' or c.src[c.offset] == 'E')) {
                c.eat(1);
                if (c.offset < c.src.len and (c.src[c.offset] == '+' or c.src[c.offset] == '-')) {
                    c.eat(1);
                }
                if (c.offset >= c.src.len or !isDigit(c.src[c.offset])) {
                    c.offset = saved.offset;
                    c.col = saved.col;
                } else {
                    while (c.offset < c.src.len and isDigit(c.src[c.offset])) {
                        c.eat(1);
                    }
                }
            }
            if (c.offset < c.src.len and c.src[c.offset] == 'i') {
                c.eat(1);
                return token(&start, c, .number);
            }
        }
        c.offset = saved.offset; // backtrack — not a complex literal
        c.col = saved.col;
    }
    // Number must be followed by whitespace, a grouping delimiter, or EOF.
    if (c.offset < c.src.len) {
        switch (c.src[c.offset]) {
            ' ', '\t', '\r', '\n', '(', ')', '{', '}', '[', ']', ';' => {},
            else => return error.UnexpectedToken,
        }
    }
    return token(&start, c, .number);
}

/// Read a string literal. Ends at matching `"`. `\` escapes the next character.
fn lexString(c: *Cursor) Error!Token {
    const start = c.*;
    c.eat(1); // consume opening quote
    while (c.offset < c.src.len) {
        switch (c.src[c.offset]) {
            '"' => {
                c.eat(1);
                return token(&start, c, .string);
            },
            '\\' => {
                c.eat(1);
                if (c.offset < c.src.len) c.eat(1); // skip escaped char
            },
            else => c.eat(1),
        }
    }
    return error.UnexpectedToken; // unterminated string
}

fn isDigit(ch: u8) bool {
    return switch (ch) {
        '0'...'9' => true,
        else => false,
    };
}

/// Check if cursor points at the start of a special float: inf.0 or nan.0.
fn matchSpecialFloat(c: *Cursor) Error!?Token {
    if (c.offset + 5 > c.src.len) return null;
    if (std.mem.eql(u8, c.src[c.offset .. c.offset + 5], "inf.0")) {
        const start = c.*;
        c.eat(5);
        return token(&start, c, .number);
    }
    if (std.mem.eql(u8, c.src[c.offset .. c.offset + 5], "nan.0")) {
        const start = c.*;
        c.eat(5);
        return token(&start, c, .number);
    }
    return null;
}

/// Check after consuming a sign whether the rest is a special float: inf.0 or nan.0.
fn matchSpecialFloatAfterSign(c: *Cursor) bool {
    if (c.offset + 5 > c.src.len) return false;
    return std.mem.eql(u8, c.src[c.offset .. c.offset + 5], "inf.0") or
        std.mem.eql(u8, c.src[c.offset .. c.offset + 5], "nan.0");
}

/// Lex a radix-prefixed integer: #b, #o, #d, #x followed by digits in that base.
fn lexRadixNumber(c: *Cursor) Error!Token {
    const start = c.*;
    c.eat(2); // consume # and prefix char
    if (c.offset >= c.src.len) return error.UnexpectedToken;

    // Defensive: offset is >= 2 here (eat(2) advanced past '#' + prefix), but
    // never index src[offset - 1] when offset could be 0.
    if (c.offset == 0) return error.UnexpectedToken;
    const prefix = c.src[c.offset - 1];
    const digitOk = struct {
        fn ok(ch: u8, p: u8) bool {
            return switch (p) {
                'b' => ch == '0' or ch == '1',
                'o' => switch (ch) {
                    '0'...'7' => true,
                    else => false,
                },
                'd' => switch (ch) {
                    '0'...'9' => true,
                    else => false,
                },
                'x' => switch (ch) {
                    '0'...'9', 'a'...'f', 'A'...'F' => true,
                    else => false,
                },
                else => false,
            };
        }
    }.ok;

    if (!digitOk(c.src[c.offset], prefix)) return error.UnexpectedToken;
    while (c.offset < c.src.len and digitOk(c.src[c.offset], prefix)) {
        c.eat(1);
    }
    return token(&start, c, .number);
}

fn token(start: *const Cursor, end: *const Cursor, kind: Kind) Token {
    return .{
        .line = start.line,
        .col = @intCast(start.col),
        .start = @intCast(start.offset),
        .end = @intCast(end.offset),
        .kind = kind,
    };
}

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
        std.testing.refAllDecls(Cursor);
        std.testing.refAllDecls(Kind);
    }
}

// ---- tests ---- //

fn lexAll(src: []const u8) ![]Token {
    var list = std.ArrayList(Token).empty;
    errdefer list.deinit(std.testing.allocator);

    var c: Cursor = .{ .src = src };
    while (true) {
        const tok = try lex(&c);
        try list.append(std.testing.allocator, tok);
        if (tok.kind == .eof) break;
    }
    return list.toOwnedSlice(std.testing.allocator);
}

test "single-char tokens" {
    const toks = try lexAll("()[]{}.");
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 8), toks.len); // 7 tokens + eof
    try std.testing.expectEqual(Kind.lparen, toks[0].kind);
    try std.testing.expectEqual(Kind.rparen, toks[1].kind);
    try std.testing.expectEqual(Kind.lbracket, toks[2].kind);
    try std.testing.expectEqual(Kind.rbracket, toks[3].kind);
    try std.testing.expectEqual(Kind.lbrace, toks[4].kind);
    try std.testing.expectEqual(Kind.rbrace, toks[5].kind);
    try std.testing.expectEqual(Kind.period, toks[6].kind);
    try std.testing.expectEqual(Kind.eof, toks[7].kind);
}

test "simple identifier" {
    const toks = try lexAll("hello");
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 2), toks.len);
    try std.testing.expectEqual(Kind.identifier, toks[0].kind);
    try std.testing.expectEqual(@as(u32, 0), toks[0].start);
    try std.testing.expectEqual(@as(u32, 5), toks[0].end);
    try std.testing.expectEqual(Kind.eof, toks[1].kind);
}

test "map marker :{" {
    const toks = try lexAll(":{:x 1}");
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 5), toks.len);
    try std.testing.expectEqual(Kind.map_marker, toks[0].kind);
    try std.testing.expectEqual(@as(u32, 0), toks[0].start);
    try std.testing.expectEqual(@as(u32, 2), toks[0].end);
    try std.testing.expectEqual(Kind.keyword, toks[1].kind);
    try std.testing.expectEqual(Kind.number, toks[2].kind);
    try std.testing.expectEqual(Kind.rbrace, toks[3].kind);
    try std.testing.expectEqual(Kind.eof, toks[4].kind);
}

test "colon not followed by brace stays a keyword" {
    // Only `:{` is the map marker. `:[` lexes as a zero-width keyword (the
    // reader rejects it) followed by a bracket — NOT a marker.
    const toks = try lexAll(":[");
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 3), toks.len);
    try std.testing.expectEqual(Kind.keyword, toks[0].kind);
    try std.testing.expectEqual(@as(u32, 1), toks[0].start);
    try std.testing.expectEqual(@as(u32, 1), toks[0].end); // zero-width
    try std.testing.expectEqual(Kind.lbracket, toks[1].kind);
}

test "dotted identifier" {
    const toks = try lexAll("foo.bar.baz");
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 2), toks.len);
    try std.testing.expectEqual(Kind.identifier, toks[0].kind);
    try std.testing.expectEqual(@as(u32, 0), toks[0].start);
    try std.testing.expectEqual(@as(u32, 11), toks[0].end);
}

test "symbol identifiers" {
    const toks = try lexAll("+ < =");
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 4), toks.len);
    try std.testing.expectEqual(Kind.identifier, toks[0].kind);
    try std.testing.expectEqual(Kind.identifier, toks[1].kind);
    try std.testing.expectEqual(Kind.identifier, toks[2].kind);
}

test "hash-prefixed identifiers" {
    const toks = try lexAll("#t #f #:keyword");
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 4), toks.len);
    try std.testing.expectEqual(Kind.identifier, toks[0].kind);
    try std.testing.expectEqual(Kind.identifier, toks[1].kind);
    try std.testing.expectEqual(Kind.identifier, toks[2].kind);
}

test "integer" {
    const toks = try lexAll("42");
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 2), toks.len);
    try std.testing.expectEqual(Kind.number, toks[0].kind);
    try std.testing.expectEqual(@as(u32, 0), toks[0].start);
    try std.testing.expectEqual(@as(u32, 2), toks[0].end);
}

test "float" {
    const toks = try lexAll("3.14");
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 2), toks.len);
    try std.testing.expectEqual(Kind.number, toks[0].kind);
    try std.testing.expectEqual(@as(u32, 0), toks[0].start);
    try std.testing.expectEqual(@as(u32, 4), toks[0].end);
}

test "multiple digits in mantissa" {
    const toks = try lexAll("3.14159");
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 2), toks.len);
    try std.testing.expectEqual(Kind.number, toks[0].kind);
    try std.testing.expectEqual(@as(u32, 0), toks[0].start);
    try std.testing.expectEqual(@as(u32, 7), toks[0].end);
}

test "string" {
    const toks = try lexAll("\"hello\"");
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 2), toks.len);
    try std.testing.expectEqual(Kind.string, toks[0].kind);
    try std.testing.expectEqual(@as(u32, 0), toks[0].start);
    try std.testing.expectEqual(@as(u32, 7), toks[0].end);
}

test "string with escape" {
    const toks = try lexAll("\"hello\\\"world\"");
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 2), toks.len);
    try std.testing.expectEqual(Kind.string, toks[0].kind);
    try std.testing.expectEqual(@as(u32, 0), toks[0].start);
    try std.testing.expectEqual(@as(u32, 14), toks[0].end);
}

test "empty string" {
    const toks = try lexAll("\"\"");
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 2), toks.len);
    try std.testing.expectEqual(Kind.string, toks[0].kind);
    try std.testing.expectEqual(@as(u32, 0), toks[0].start);
    try std.testing.expectEqual(@as(u32, 2), toks[0].end);
}

test "line comment is skipped" {
    const toks = try lexAll("; this is a comment\n42");
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 2), toks.len);
    try std.testing.expectEqual(Kind.number, toks[0].kind);
}

test "line comment at end of input" {
    const toks = try lexAll("; just a comment");
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 1), toks.len);
    try std.testing.expectEqual(Kind.eof, toks[0].kind);
}

test "shebang at start of file" {
    const toks = try lexAll("#!/usr/bin/env skript\n(+ 1 2)");
    defer std.testing.allocator.free(toks);

    // Tokens: lparen, '+', '1', '2', rparen, eof
    try std.testing.expectEqual(Kind.lparen, toks[0].kind);
    try std.testing.expectEqual(Kind.identifier, toks[1].kind);
    try std.testing.expectEqual(Kind.number, toks[2].kind);
    try std.testing.expectEqual(Kind.number, toks[3].kind);
    try std.testing.expectEqual(Kind.rparen, toks[4].kind);
    try std.testing.expectEqual(Kind.eof, toks[5].kind);
}

test "shebang only at start, not mid-file" {
    const toks = try lexAll("(#!not-a-shebang)");
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 4), toks.len);
    try std.testing.expectEqual(Kind.lparen, toks[0].kind);
    try std.testing.expectEqual(Kind.identifier, toks[1].kind); // '#!not-a-shebang' is an identifier
    try std.testing.expectEqual(Kind.rparen, toks[2].kind);
    try std.testing.expectEqual(Kind.eof, toks[3].kind);
}

test "whitespace between tokens" {
    const toks = try lexAll("(  1\n\n 2 )");
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 5), toks.len);
    try std.testing.expectEqual(Kind.lparen, toks[0].kind);
    try std.testing.expectEqual(Kind.number, toks[1].kind);
    try std.testing.expectEqual(Kind.number, toks[2].kind);
    try std.testing.expectEqual(Kind.rparen, toks[3].kind);
    try std.testing.expectEqual(Kind.eof, toks[4].kind);
}

test "empty input" {
    const toks = try lexAll("");
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 1), toks.len);
    try std.testing.expectEqual(Kind.eof, toks[0].kind);
}

test "only whitespace" {
    const toks = try lexAll("   \n  \t \r ");
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 1), toks.len);
    try std.testing.expectEqual(Kind.eof, toks[0].kind);
}

test "unterminated string error" {
    var c: Cursor = .{ .src = "\"hello" };
    const res = lex(&c);
    try std.testing.expectError(error.UnexpectedToken, res);
}

test "number with trailing dot error" {
    var c: Cursor = .{ .src = "42." };
    const res = lex(&c);
    try std.testing.expectError(error.UnexpectedToken, res);
}

test "number followed by string without whitespace errors" {
    var c: Cursor = .{ .src = "42\"hello\"" };
    const res = lex(&c);
    try std.testing.expectError(error.UnexpectedToken, res);
}

test "number followed by identifier must have whitespace" {
    var c: Cursor = .{ .src = "42abc" };
    const res = lex(&c);
    try std.testing.expectError(error.UnexpectedToken, res);
}

test "number followed by delimiter is fine" {
    const toks = try lexAll("123)");
    defer std.testing.allocator.free(toks);
    try std.testing.expectEqual(@as(usize, 3), toks.len);
    try std.testing.expectEqual(Kind.number, toks[0].kind);
    try std.testing.expectEqual(Kind.rparen, toks[1].kind);
}

test "identifier followed by string with no whitespace splits cleanly" {
    // `"` is a delimiter for identifiers, so `foobar"str"` cleanly splits
    // into identifier `foobar` + string `"str"`. No error needed.
    const toks = try lexAll("foobar\"str\"");
    defer std.testing.allocator.free(toks);
    try std.testing.expectEqual(@as(usize, 3), toks.len);
    try std.testing.expectEqual(Kind.identifier, toks[0].kind);
    try std.testing.expectEqual(Kind.string, toks[1].kind);
    try std.testing.expectEqual(Kind.eof, toks[2].kind);
}

test "string after identifier with space is fine" {
    const toks = try lexAll("foo \"str\"");
    defer std.testing.allocator.free(toks);
    try std.testing.expectEqual(@as(usize, 3), toks.len);
    try std.testing.expectEqual(Kind.identifier, toks[0].kind);
    try std.testing.expectEqual(Kind.string, toks[1].kind);
}

test "line and column tracking" {
    const toks = try lexAll("(\n  42\n)");
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(Kind.lparen, toks[0].kind);
    try std.testing.expectEqual(@as(u16, 1), toks[0].line);
    try std.testing.expectEqual(@as(u16, 1), toks[0].col);

    try std.testing.expectEqual(Kind.number, toks[1].kind);
    try std.testing.expectEqual(@as(u16, 2), toks[1].line);
    try std.testing.expectEqual(@as(u16, 3), toks[1].col);

    try std.testing.expectEqual(Kind.rparen, toks[2].kind);
    try std.testing.expectEqual(@as(u16, 3), toks[2].line);
}

test "token spans" {
    // Just test that consecutive tokens have sensible start/end positions
    const toks = try lexAll("(abc 123 4.5)");
    defer std.testing.allocator.free(toks);

    // Tokens: lparen(0,1), identifier(1,4), number(5,8), number(9,12), rparen(12,13), eof(13,13)
    try std.testing.expectEqual(Kind.lparen, toks[0].kind);
    try std.testing.expectEqual(@as(u32, 0), toks[0].start);
    try std.testing.expectEqual(@as(u32, 1), toks[0].end);

    try std.testing.expectEqual(Kind.identifier, toks[1].kind);
    try std.testing.expectEqual(@as(u32, 1), toks[1].start);
    try std.testing.expectEqual(@as(u32, 4), toks[1].end);

    try std.testing.expectEqual(Kind.number, toks[2].kind);
    try std.testing.expectEqual(@as(u32, 5), toks[2].start);
    try std.testing.expectEqual(@as(u32, 8), toks[2].end);

    try std.testing.expectEqual(Kind.number, toks[3].kind);
    try std.testing.expectEqual(@as(u32, 9), toks[3].start);
    try std.testing.expectEqual(@as(u32, 12), toks[3].end);

    try std.testing.expectEqual(Kind.rparen, toks[4].kind);
    try std.testing.expectEqual(@as(u32, 12), toks[4].start);
    try std.testing.expectEqual(@as(u32, 13), toks[4].end);
}

test "identifier with delimiter stops before delimiter" {
    const toks = try lexAll("foo(bar)");
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 5), toks.len);
    try std.testing.expectEqual(Kind.identifier, toks[0].kind); // "foo"
    try std.testing.expectEqual(@as(u32, 0), toks[0].start);
    try std.testing.expectEqual(@as(u32, 3), toks[0].end);
    try std.testing.expectEqual(Kind.lparen, toks[1].kind);
    try std.testing.expectEqual(Kind.identifier, toks[2].kind); // "bar"
    try std.testing.expectEqual(Kind.rparen, toks[3].kind);
}

test "identifier after comment" {
    const toks = try lexAll("; comment\nhello");
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 2), toks.len);
    try std.testing.expectEqual(Kind.identifier, toks[0].kind);
    try std.testing.expectEqual(@as(u32, 10), toks[0].start);
}

test "number immediately followed by delimiter" {
    const toks = try lexAll("123)");
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 3), toks.len);
    try std.testing.expectEqual(Kind.number, toks[0].kind);
    try std.testing.expectEqual(@as(u32, 0), toks[0].start);
    try std.testing.expectEqual(@as(u32, 3), toks[0].end);
    try std.testing.expectEqual(Kind.rparen, toks[1].kind);
}

test "peekNonWhitespace" {
    const c: Cursor = .{ .src = "   x" };
    try std.testing.expectEqual(@as(u8, 'x'), c.peekNonWhitespace().?);

    const cursor2: Cursor = .{ .src = "" };
    try std.testing.expectEqual(@as(?u8, null), cursor2.peekNonWhitespace());

    const cursor3: Cursor = .{ .src = "   " };
    try std.testing.expectEqual(@as(?u8, null), cursor3.peekNonWhitespace());
}

test "multiple tokens on one line" {
    const toks = try lexAll("(+ 1 2)");
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 6), toks.len);
    try std.testing.expectEqual(Kind.lparen, toks[0].kind);
    try std.testing.expectEqual(Kind.identifier, toks[1].kind); // "+"
    try std.testing.expectEqual(Kind.number, toks[2].kind); // "1"
    try std.testing.expectEqual(Kind.number, toks[3].kind); // "2"
    try std.testing.expectEqual(Kind.rparen, toks[4].kind);
    try std.testing.expectEqual(Kind.eof, toks[5].kind);
}

test "identifier with leading hash only at non-start position" {
    // # without ! at start of file is an identifier
    const toks = try lexAll("#not-shebang");
    defer std.testing.allocator.free(toks);

    try std.testing.expectEqual(@as(usize, 2), toks.len);
    try std.testing.expectEqual(Kind.identifier, toks[0].kind);
    try std.testing.expectEqual(@as(u32, 0), toks[0].start);
    try std.testing.expectEqual(@as(u32, 12), toks[0].end);
}
