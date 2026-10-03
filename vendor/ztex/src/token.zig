//! ztex.token — lexical tokens with byte spans into the source.
//!
//! Provenance design: the lexer pre-tokenizes the whole source into a flat
//! token table. Every token carries a byte span into the original source.
//! Atoms reference token ranges; boxes and drawables carry resolved byte
//! spans. So any output drawable maps back to its input text in O(1).
//!
//! This module owns nothing: `Token` is a value and `Span` two offsets.
//! Both types are re-exported from `ztex.atom`, which is the import route a
//! consumer needs; this file is the shared definition behind that re-export.

const std = @import("std");

/// Lexical token kind.
pub const Tag = enum(u8) {
    /// an ordinary character/codepoint (`x`, digits, `+`, `[`, `]`, utf-8…)
    char,
    /// a control sequence `\name`; the name is `src[start+1..end]`
    command,
    /// `{` — opens a group the parser reads as one child atom
    l_group,
    /// `}` — closes the innermost group; at top level it is an error
    r_group,
    /// `^` — the superscript marker; the atom after it is the superscript
    sup,
    /// `_` — the subscript marker; the atom after it is the subscript
    sub,
};

/// A lexed token and its byte range. `start` and `end` are offsets into the
/// formula source the lexer was given, so a `Token` borrows nothing — it
/// stores only offsets — and stays readable after the source is gone.
pub const Token = struct {
    tag: Tag,
    /// byte offset of the first byte of this token in the source
    start: u32,
    /// byte offset just past the last byte of this token in the source
    end: u32,
};

/// The half-open byte range `[start, end)` into the original source: the
/// universal provenance currency, source → token → atom → box → drawable.
/// `end` may equal `start` for a position rather than a range, which is how
/// "the error is here" is expressed at end of input.
pub const Span = struct {
    start: u32,
    end: u32,

    /// The number of bytes covered, `end - start`. `end` must not be below
    /// `start`; a span built from out-of-order offsets is out of contract.
    pub fn len(self: Span) usize {
        return self.end - self.start;
    }
};

test {
    std.testing.refAllDecls(@This());
}
