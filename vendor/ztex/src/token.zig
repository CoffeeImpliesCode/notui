//! ztex.token — lexical tokens with byte spans into the source.
//!
//! Provenance design (house superflat pattern, cf. `~/projects/{vain,skript}`):
//! the lexer pre-tokenizes the whole source into a flat token table. Every
//! token carries a byte span into the original source. Atoms reference token
//! ranges; boxes and drawables carry resolved byte spans. So any output
//! drawable maps back to its input text in O(1).

const std = @import("std");

/// Lexical token kind.
pub const Tag = enum(u8) {
    /// an ordinary character/codepoint (`x`, digits, `+`, `[`, `]`, utf-8…)
    char,
    /// a control sequence `\name`; the name is `src[start+1..end]`
    command,
    /// `{`
    l_group,
    /// `}`
    r_group,
    /// `^`
    sup,
    /// `_`
    sub,
};

/// A token plus its byte span into the source.
pub const Token = struct {
    tag: Tag,
    /// byte offset of the first byte of this token in the source
    start: u32,
    /// byte offset just past the last byte of this token in the source
    end: u32,
};

/// A byte span into the original source. The universal provenance currency:
/// source → token → atom → box → drawable.
pub const Span = struct {
    start: u32,
    end: u32,

    pub fn len(self: Span) usize {
        return self.end - self.start;
    }
};

test {
    std.testing.refAllDecls(@This());
}

test "span: length is end minus start" {
    const s: Span = .{ .start = 4, .end = 9 };
    try std.testing.expectEqual(@as(usize, 5), s.len());
}
