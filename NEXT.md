# Open work

The plan lives in [`ROADMAP.md`](ROADMAP.md): phases F (measurement), B
(frame-pipeline correctness), C (scrollback ledger), D (input and widgets),
E (content rendering), A (provenance), each item with its evidence and the
check that closes it. This file holds the small, repo-local items that are not
on the roadmap.

## Non-ASCII key text synthesis in the parser

`src/Parser.zig` fills `text` and `shifted_codepoint` for shift+printable
events that arrive with no text, and its "printable" predicate is
`std.ascii.isPrint`, so a non-ASCII layout gets no synthesized text.
`Key.matchText` case-folds through the Unicode mapping (`width.toUpper` in
the zg seam); this is the other half.

Widening "printable" past ASCII changes what `shifted_codepoint` means —
zg categories, `DisplayWidth > 0`, or leaving it to the terminal to report
the text — so it wants a decision, not a patch. Close it with a test that
feeds the decoder a shift+non-ASCII key with no text and asserts the
synthesized `text`.

## Reading `zbc` reports

`zig-gate` prints the first 30 lines of the zbc report and counts only
`error(` lines, so a warnings-only run reads as "0 potential issue(s)".
zbc itself selects the project's own 41 files (vendor trees excluded) and
reports at most one finding per rule per file. For the full list, run the
command in `AGENTS.md`.

Its float↔int rules are a token walk over the cast expression, not dataflow:
a bound that is a file-scope identifier, a unary-minus expression, or a
value derived from an opaque call is "unproved" however correct it is. Write
`std.math.clamp(v, lo, hi)` with local comptime bounds in a value position,
or pass the value through a small helper — as `clampedIndex` does for the
`coverageRowFast` kernel — rather than restating magic numbers.
