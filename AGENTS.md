# notui

Zig 0.16 inline-first terminal UI toolkit. It provides cell-buffer primitives, base-ui components (spinner, text, gauge, suggestions), and an Elm-style app framework. Apps use the terminal's main buffer and preserve scrollback instead of owning the screen.

## Stack and layout

- Zig 0.16: module API, `std.Io`, Juicy Main. Use `zig` from devenv (nixpkgs 0.16).
- External `zg` provides Unicode 16 width, grapheme, and text support; keep it distinct from local hand-copied zigzag/libvaxis source. `skript` is vendored at `vendor/skript` (the Lisp runtime behind the REPL example) — re-vendor with the `jj file list | rsync` recipe in `build.zig.zon`; do not edit it in place.
- `src/main.zig` is the `std.process.Init` executable entry; `src/root.zig` is the library root and holds unit tests. `build.zig` defines module, executable, run, and test steps.
- Use `jj`, not Git commands.
- Use locally built analysis tools when available: `~/.local/bin/zlint`, `~/tools/ziglint`, `~/tools/zbc`, and `~/tools/zcov`; they may include setup-specific patches.

## Conventions

- Use explicit allocators, named `gpa`/`arena` parameters, and `defer`/`errdefer` cleanup. Avoid hidden allocations.
- Use Zig 0.16 idioms: pass `std.Io` through I/O, pass allocators to unmanaged containers, use `.empty` literals and `@import("root")`.
- Declare error sets; do not leak `anyerror` or discard errors with `_ =`.
- Keep lines within 100 columns. Tests belong next to code in `src/`.
- Do not preserve backward compatibility: remove dead code and update callers directly.

## Environment and commands

`.envrc` loads devenv; `devenv.nix` provides Zig and zlint. Run `direnv allow` on first use or after changing `devenv.nix`.

```bash
zig build           # debug build: zig-out/bin/notui
zig build run       # build and run
zig build test      # unit tests
zig fmt --check .   # format check
zlint               # prefer ~/.local/bin/zlint
gate                # all gates; zbc advisory unless ZBC_STRICT=1; --cov is optional
jj st               # working-copy status
```

`gate` runs format check, build, tests, AST check, ziglint, and zlint; it exits 1 on issues.
