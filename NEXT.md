# Open work

The plan lives in [`ROADMAP.md`](ROADMAP.md): phases F (measurement), B
(frame-pipeline correctness), C (scrollback ledger), D (input and widgets),
E (content rendering), A (provenance), each item with its evidence and the
check that closes it. This file holds the small, repo-local items that are not
on the roadmap.

## Non-ASCII key text synthesis in the parser

**Decided and implemented.** The parser's "no text reported" fallback now
synthesizes `text` for any printable scalar, not just ASCII, and
`shifted_codepoint` is set only for ASCII.

The split follows what each field means. `text` is "what the key typed", and
`Key.matchText` already case-folds through the zg seam, so a non-ASCII
layout's shift+letter had to reach it or no declared binding could ever
match. `isTextCodepoint` admits every scalar that is not a control, a
surrogate, a noncharacter, a private-use codepoint (kitty encodes `f1`,
`home` and the rest there) or `Key.multicodepoint`. The upper form comes
from `width.toUpper`, so an expansion like ß → SS degrades to the codepoint
itself instead of a truncated byte.

`shifted_codepoint` names the codepoint shift produces *on this layout*,
which is the terminal's to report. Inventing it from a case mapping would
claim a shifted key the layout may not have, so a non-ASCII key gets none.

Three decoder regressions cover it: shift+U+00E4 synthesizes `Ä` and
matches through `matchText` with no shifted codepoint; `Key.home` in the
private use area gets no text; ctrl+U+0061, a C0 modifier shortcut, gets
none either.

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

`zig-gate` reported one `error(` finding in this run, and it was real:
`expandTabs` sized its buffer with `line.len + 8`, which wraps when a line
is within eight bytes of `maxInt(usize)` and would under-allocate for the
spaces a tab expands to. It is now `line.len +| 8`. The remaining zbc
output is warnings — chiefly `index-minus-one-without-zero-guard`, the same
unproved-index walk, on indexes the surrounding code already proves
non-empty.
