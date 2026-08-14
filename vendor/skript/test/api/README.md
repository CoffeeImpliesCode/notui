# API corpus

The API corpus contains small self-checking Skript programs. Each program runs through the native interpreter. API programs print one dot for each passing check and finish with `ALL-OK`. A non-zero exit status or a missing `ALL-OK` marker fails the gate.

## Canonical runner

Build the native CLI, then run its argument checks and the API, demo, and optimization-parity corpus:

```sh
direnv allow
direnv exec . zig build
direnv exec . bash test/api/run.sh zig-out/bin/skript
```

`test/api/run.sh` requires exactly one executable CLI path. It checks the CLI path, the `timeout` command, and `timeout --kill-after` support before it starts. It applies a deadline to every child process.

The runner executes 9 API programs, 8 demos, and `test/regvm-parity.sh`. The parity script compares each of its 200 cases with and without `--no-bytecode-opts`.

Twelve CLI checks cover usage and help, invalid options and duplicate inputs, file and stdin input, supported flags, literal paths after `--`, Skript source/call-frame diagnostics, and uncaught raised payloads. The summary reports these separately as `cli_checks`; `total` remains the 18 API, demo, and parity jobs.

On a native default build, `zig build test` invokes this runner. The full `test` step requires the CLI. `zig build test -Dcli=false` fails with an explicit missing-CLI error. Use `test-unit`, `test-compile`, or `check` with `-Dcli=false` for library-only work.

`zig build test-fast` runs the installed test artifact directly. It does not replace the CLI corpus gate.

## API programs

| File | Coverage |
|---|---|
| `autodiff.pt` | Forward-sweep and reverse AD contracts, including map projections/constructors, tensor callbacks, exact integer values, limits, selector/handle errors, and stale dependency guards. |
| `strings.pt` | String construction, comparison, search, replacement, splitting, joining, trimming, conversion, formatting, and UTF-8 operations. |
| `collections.pt` | Cons lists, maps, collection operations, composition, and tensor dispatch. |
| `tensors.pt` | Tensor construction, indexing, transforms, reductions, selection, binary operations, and modular integer dot overflow. |
| `numerics.pt` | Numeric tower operations, mixed numeric types, signedness, wrapping, complex values, predicates, and conversions. |
| `semantics.pt` | Control flow, equality, bindings, functions, closures, recursion, and tail calls. |
| `io.pt` | Immutable bytevector construction, predicates, length, indexing, and empty values. Host-I/O edge cases use injected readers and temporary files in unit tests. |
| `processes.pt` | Process creation, mailboxes, selective receive, timeouts, liveness, raw and system-error exit reasons, and concurrent work. |
| `errors.pt` | Raising, catching, guards, error values, source spans, rethrow-preserved tracebacks, and spawned-process isolation. |

The API corpus currently includes 9 programs. The `autodiff.pt` program covers AD boundaries with self-checking assertions.

## Demo programs

The runner executes these 8 programs:

`hello.pt`, `tensors.pt`, `processes.pt`, `collections.pt`, `types.pt`, `control.pt`, `vector-math.pt`, and `numerics.pt`.

Demo output is observational. Demos do not need the `ALL-OK` marker.

## Runtime-probe verification — 2026-09-26

After the runtime-probe fixes, `zig build check`, `zig build`, and
`zig fmt --check src build.zig` passed. `zig build test-fast` passed
**938/938** unit tests. `zig build test` passed all 9 API programs,
8 demos, the 200-case parity job, and **12/12** CLI checks
(`total=18`, `failures=0`). The four changed API programs each returned
`ALL-OK` in a direct native CLI run. See [`TRIAGE.md`](../../TRIAGE.md)
for the resolved probe cases.

## Review-regression verification — 2026-09-27

The later review pass added closed-handle collection, non-finite reverse
zero-product, nested predicate-fiber, copied-error-metadata, and
desugared-span regressions. `zig build check`, `zig build web`, and the
native house `gate` (formatting, build, tests, AST checks, Ziglint, zlint,
zbc) passed. `zig build test-fast` passed **941/941** unit tests. The
runner passed 18 API/demo/parity jobs and 12 CLI checks with zero failures.

## Earlier native gate — 2026-09-26

After the host-`eval` correction, `zig build check` and the native house
`gate` passed. The gate covered formatting, build, 932 native unit tests,
AST checks, Ziglint, zlint, and zbc. The CLI runner passed 9 API programs,
8 demos, one 200-case optimizer-parity runner, and 10 CLI checks, with
zero failures. ReleaseFast and the web build also passed. The composed
native CLI smoke printed `PHASE11-SMOKE-OK` and exited with status zero.
See [`TRIAGE.md`](../../TRIAGE.md) for current browser evidence and open
Phase 11 speed gates.

## Historical runner scope — 2026-09-13

On that date, `zig build test` and `zig build test-fast` passed. The native
suite contained 753 tests. The CLI runner passed 8 API programs, 8 demos,
one 200-case optimization-parity runner, and 10 CLI checks, with zero
failures. All 73 source files also passed the four local analyzers at that
time. These results do not establish a current repo-wide house gate.
See [`TRIAGE.md`](../../TRIAGE.md) for analyzer commands and scope.

## Known gaps

- `(c64 x)` remains a documented TIER-3 gap. `numerics.pt` records this as a comment, not a live assertion.

## API critique

`docs/api-critique.md` contains the consolidated review of the shipped core surface. It records findings by corpus area with file and line evidence.
