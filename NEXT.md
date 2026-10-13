# Open work

The plan lives in [`ROADMAP.md`](ROADMAP.md): phases F (measurement), B
(frame-pipeline correctness), C (scrollback ledger), D (input and widgets),
E (content rendering), A (provenance), each item with its evidence and the
check that closes it. This file holds the small, repo-local items that are not
on the roadmap.

## Non-ASCII key text synthesis in the parser

**Implemented.** For shift-only CSI u events, the parser preserves explicit
text. Without text, it uses the terminal's reported `shifted_codepoint`.
If neither field exists, it uses `width.toUpper` through the zg seam.
Caps Lock and Num Lock do not disable this fallback.

The parser synthesizes a missing `shifted_codepoint` only for ASCII.
It preserves reported shifted codepoints on every layout.

The fallback excludes C0, DEL, C1, surrogates, private-use areas,
Unicode noncharacters, and values above U+10FFFF. Noncharacters include
U+FDD0–U+FDEF and the last two codepoints of each plane.
The simple uppercase mapping keeps ß unchanged because its full mapping,
SS, needs more than one codepoint.

Decoder regressions cover Unicode text, reported-field precedence,
named keys, modifier shortcuts, and noncharacter and scalar boundaries.

## Reading analyzer reports

`zig-gate` prints the first 30 lines of the zbc report and counts only
`error(` lines, so a warnings-only run reads as "0 potential issue(s)".
zbc selects the project's own non-vendor files — the gate drops vendor
through `GATE_EXCLUDE` — and reports at most one finding per rule per file.
For the full list, run the command in `AGENTS.md`.

Its float↔int rules are a token walk over the cast expression, not dataflow:
a bound that is a file-scope identifier, a unary-minus expression, or a
value derived from an opaque call is "unproved" however correct it is. Write
`std.math.clamp(v, lo, hi)` with local comptime bounds in a value position,
or pass the value through a small helper — as `clampedIndex` does for the
`coverageRowFast` kernel — rather than restating magic numbers.

Whether a diagnostic is a defect is a recorded result, not a judgement call.
[`ANALYZER-TRIAGE.json`](ANALYZER-TRIAGE.json) classifies all 136
occurrences of the `6a09ae304673` tree: 78 false positives, 58 intentional
test assertions, none a confirmed runtime defect. Read that ledger before
treating a new analyzer line as a bug, and extend it rather than re-derive
the site. The classification is source and caller review against documented
premises; it is not a proof that the code is memory-safe, and nothing is
suppressed, so the strict gate stays red.

One zbc `error(` finding was real: `expandTabs` sized its buffer with
`line.len + 8`, which wraps when a line is within eight bytes of `maxInt(usize)`
and would under-allocate for the spaces a tab expands to. It is now
`line.len +| 8` (`src/markdown.zig`). The rest of that run's zbc output was
warnings — chiefly `index-minus-one-without-zero-guard`, the same
unproved-index walk, on indexes the surrounding code already proves
non-empty.

There is no completed current `zbc` verdict: the last serial attempt,
`zbc --jobs=1`, crashed in its binding cache with exit 134. The zbc tables in
`README.md` are per-run historical numbers, not a standing total.
