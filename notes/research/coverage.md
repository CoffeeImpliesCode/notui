# Zig 0.16 Coverage — Verified Path (notui)

Scope: what coverage tooling actually works on this repo today (zig 0.16.0,
nixpkgs, house tools). Empirical investigation on 2026-08-13; every claim is
marked `[MEASURED]` (ran it) or `[INFERRED]` (from sources/notes, not re-run).
No repo files were modified during this investigation (only zig caches).

## Verdict

**zig-cov (house zcov) is the one practical path on 0.16.** It works end to
end on this repo right now: `zig-cov test` exits 0 and prints a per-file
line/block report. kcov 43 also works but is off-PATH and needs manual test-
binary hunting, so it is only a fallback. The earlier foundations claim
("zcov needs 0.17-dev; on 0.16 only kcov via DWARF works") is wrong for
*using* the prebuilt binary — 0.17-dev is only the floor for *building* zcov
from source.

## Verified path (exact commands)

```sh
cd ~/projects/notui

# Plain tests still pass (prerequisite; also what gate step 3 runs)
zig build test                        # [MEASURED] exit 0, 311 tests OK

# Coverage run — the gate's --cov invocation (zig-cov is on PATH)
zig-cov test --exclude=zig-pkg --exclude=vk.zig
```

`[MEASURED]` result of the run above (2026-08-13):

```
zig-cov: running: /nix/store/...zig-0.16.0/bin/zig build test \
  -Dcoverage=true -Dcoverage-rt=~/tools/zcov/zig-out/bin/../lib/zig-cov-rt.o
zig-cov: resolving 20703 PCs from /tmp/zig-cov-*/cache/o/<hash>/test ...
Total   50.2% (2573/5128) lines, 100.0% functions (0/0)
Blocks (exact)  26.5% (1832/6916)
EXIT=0          # ~112 s wall (LLVM-backend build, cold-ish)
```

28 src files reported, per-file lines shown. `zig-cov` runs the build in a
temp cache dir (`/tmp/zig-cov-*`), so the repo tree stays untouched.

Useful variants (documented in `~/tools/zcov/README.md`, `[INFERRED]` from
README — same tool, not re-run):

```sh
zig-cov test --format=lcov --output=coverage.lcov      # Codecov/lcov --genhtml
zig-cov test --format=json | jq '.summary.line_percent'  # CI trend tracking
zig-cov test --format=html --output=coverage.html      # self-contained report
zig-cov test --fail-under=80                           # exit 1 below threshold
zig-cov report <file>.zcov                             # re-report saved runs
```

## Why it works (mechanism, all `[MEASURED]` where noted)

- The repo `build.zig` is already wired for zig-cov (lines 151–156):
  `-Dcoverage` and `-Dcoverage-rt` options; when on, it sets
  `unit_tests.use_llvm = true`, `root_module.fuzz = true` (sancov
  counters + PC table), `link_libc = true` (atexit `.zcov` writer), and
  links `zig-cov-rt.o`.
- The 0.16.0 LLVM backend **does** emit sancov counters (`fuzz=true`):
  the run resolved 20703 PCs from the instrumented test binary.
- `zig-cov` (binary) is installed at `~/.local/bin/zig-cov` → symlink to
  `~/tools/zcov/zig-out/bin/zig-cov`, and it auto-finds the runtime object
  at `~/tools/zcov/zig-out/lib/zig-cov-rt.o` (searches `../lib` relative to
  its real path). `[MEASURED]`: the run linked it without any extra flag.
- The tool is driven by the same `zig` as the repo: `[MEASURED]` the
  instrumented build command printed by zig-cov used the nixpkgs
  `/nix/store/...-zig-0.16.0/bin/zig`; `zig version` → 0.16.0.

## What was tried and what failed

| Attempt | Result | Evidence |
|---|---|---|
| `zig-cov test` (house zcov) | **Works** | `[MEASURED]` exit 0, full report above |
| `kcov` on plain test binary | **Works** (fallback) | `[MEASURED]` kcov 43: all 311 tests ran, report written, exit 0 |
| `which kcov` on PATH | **Not on PATH** | `[MEASURED]` nothing; binary only at `/nix/store/hc6dnj8pn9m4m7l0rdv3c0m405py7z17-kcov-43/bin/kcov` (kcov 43) |
| `which zcov` on PATH | **Not on PATH** | `[MEASURED]` nothing; source at `~/tools/zcov/` |
| Building zcov from source on 0.16 | **Would fail** | `[INFERRED]` from `~/tools/zcov/build.zig.zon`: `minimum_zig_version = "0.17.0-dev.1509+bb296ab9b"` (a floor; 0.16 is older). Not attempted — the prebuilt binary sidesteps this |
| gcov / llvm-cov profraw on 0.16 | Not re-tested | `[INFERRED]` from prior foundations note ("don't work on 0.16"). `llvm-cov` exists at `/run/current-system/sw/bin/llvm-cov` `[MEASURED]` presence only |

Nothing on the zig-cov path failed. The single failure mode worth knowing:
`zig-cov test` on a project whose `build.zig` lacks the `-Dcoverage`
option errors with `invalid option: -Dcoverage` — the gate detects exactly
that string and reports "coverage: skipped".

## The 0.17-dev zcov note (reconciled)

- **Building** zcov from source requires 0.17-dev (`build.zig.zon` floor).
- **Using** the prebuilt binary on a 0.16 project works — measured here.
- The house binary was built 2026-08-06 (`[MEASURED]` mtime on
  `~/tools/zcov/zig-out/bin/zig-cov` and `zig-cov-rt.o`), i.e. from a
  0.17-dev compiler; the binary itself is version-agnostic over the
  projects it drives.
- When 0.17 lands in the house toolchain, rebuild zcov from source so the
  floor and the compiler match; until then, keep the current binary.

## What `gate --cov` does

`[MEASURED]` (read the scripts end to end): `gate` is a nix-store wrapper
that execs `zig-gate` (`~/.local/bin/zig-gate`). With `--cov`, after the
fmt/build/test/ast-check/ziglint/zlint/zbc steps it runs step 8:

```sh
$ZIG_COV test --exclude=zig-pkg --exclude=vk.zig
# ZIG_COV defaults to ~/.local/bin/zig-cov
# ZIG_COV_FAIL_UNDER=<pct> appends --fail-under=<pct>
```

Advisory: it never fails the gate on coverage alone unless
`ZIG_COV_FAIL_UNDER` is set. Skip paths (in order): zig-cov missing;
output contains `invalid option: -Dcoverage` (build.zig not wired — not the
case here); plain `zig build test` fails. Since notui's build.zig is wired
and zig-cov is installed, `gate --cov` runs a real coverage pass.

## Recommended CI shape

`[INFERRED]` (recommendation; not run in CI here):

1. **Weekly coverage run** (or nightly; cheap enough at ~2 min):
   `zig-cov test --format=lcov --output=coverage.lcov --exclude=zig-pkg`
   and archive the artifact; commit/track the JSON summary
   (`--format=json | jq '.summary.line_percent'`) for trend.
2. **Advisory per-PR**: `zig-gate --cov` — already wired; zero extra
   config. Enforce a floor later with `ZIG_COV_FAIL_UNDER=NN` once the
   baseline (50.2% lines today) is accepted.
3. **No kcov in CI**: off-PATH, needs a nix-store path or `nix run`, and
   requires locating the test binary in the cache
   (`find ~/.cache/zig/o -name test -type f | head -1`) — the exact
   fragility the foundations note documented. Keep it as the documented
   fallback only.
4. **When 0.17-dev lands**: rebuild zcov from `~/tools/zcov` (source floor
   matches), keep the same commands.

## Sources

- `~/tools/zcov/` README.md + build.zig.zon + src/build_orchestrator.zig
  (rt discovery at :142–164)
- `~/.local/bin/zig-gate` (coverage step, lines ~150–185)
- `/nix/store/.../bin/gate` → `/nix/store/.../gate-script` ("zig-gate")
- notui `build.zig:151–156` (coverage wiring), `build.zig.zon`
  (`minimum_zig_version = "0.16.0"`)
- Machine: zig 0.16.0 (nixpkgs), kcov 43 in nix store, llvm-cov on PATH
