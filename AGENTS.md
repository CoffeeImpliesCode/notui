# notui

Zig 0.16 project (house scaffold). Purpose TBD — initialized to the same
conventions as `~/projects/{noapi, nogui, skript, wayland}`.

## Stack

- **Language**: Zig 0.16 (module API, `std.Io`, Juicy Main)
- **Sole dep**: zg (Unicode 16: width, graphemes, text) — vendored elsewhere
  is hand-copied from zigzag/libvaxis (see notes/research/zig-foundations.md)
- **VCS**: jj — DO NOT USE GIT COMMANDS
- **Dev env**: devenv + direnv (`.envrc` → `use devenv`)
- **Linting**: zlint (`zlint.json` rules) + `zig fmt --check`
- **Toolchain**: `zig` from devenv (nixpkgs 0.16)
- **Lint/analyze tools**: prefer the locally built versions (`~/.local/bin/zlint`, `~/tools/ziglint`, `~/tools/zbc`, `~/tools/zcov`) over devenv's nixpkgs ones — they may be patched for this setup.

## Structure

```
build.zig          # build graph: notui module → exe → run/test steps
build.zig.zon      # package manifest (fingerprint, paths)
devenv.nix         # nix dev environment (zig, zig-zlint, pkg-config)
.envrc             # direnv → devenv hook
AGENTS.md          # this file
src/
├── main.zig       # executable entry (std.process.Init)
└── root.zig       # library root + unit tests
notes/             # design research, comparisons, transcripts
```

## Conventions

- Tiger style: explicit allocators, no hidden allocations, `defer`/`errdefer`
  cleanup, named `gpa`/`arena` allocator params
- Zig 0.16 idioms only: `std.Io` threaded through I/O, unmanaged containers
  with explicit allocator args, `.empty` decl literals, `@import("root")`
- Error sets explicit; no `anyerror` leaks; no `_ =` discards
- `zig fmt` before finishing any change; lines ≤ 100 columns
- Unit tests live next to code in `src/`; run via `zig build test`
- No backwards compatibility: delete dead code, change directly

## Development

- Use tools, always use `edit`/`write` for file changes — NEVER patch files
  with inline python/perl/sed/awk scripts, heredocs, or `echo >` redirection
- Read with `read`, search with `grep`/`glob`; shell is for builds/tests and
  one-shot fact queries only
- NEVER use web_* tools (broken) — for web search use the local server at
  `localhost:4444`; prefer reading primary sources directly
- Delegate aggressively: many small subagents over few big ones; give full
  instructions; assume subagents are dumb
- Parallelize: N independent files → N workers

## Commands

```bash
direnv allow        # enter devenv shell (first time / after devenv.nix edits)
zig build           # Debug build → zig-out/bin/notui
zig build run       # build + run
zig build test      # unit tests
zig fmt --check .   # formatting gate
zlint               # lint (prefer ~/.local/bin/zlint; devenv nixpkgs is fallback)
gate                # all quality gates (zig-gate): fmt --check, build, test, ast-check, ziglint, zlint; zbc by default (advisory; strict via ZBC_STRICT=1); optional `--cov`; exit 1 on issues
jj st               # working-copy status (never git)
```
