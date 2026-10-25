# notui

Inline-first terminal UI primitives for Zig. Experimental.

notui provides a grapheme-aware cell buffer, an inline `Region` renderer,
an Elm-style app loop, editors, selection components, Markdown, diffs, and tool cards.
It draws in the terminal's main buffer and preserves scrollback.

## Requirements

- Zig 0.17.0.
- Native POSIX descriptors for terminal input, raw mode, and pipe capture.
- A live `std.Io` provider for I/O operations.
- A kitty-graphics terminal for interactive image and formula examples.

[zg](https://codeberg.org/atman/zg) supplies Unicode 18 text data through `src/width.zig`.
The dependency is pinned to upstream PR #108 for Zig 0.17 compatibility.
Skript and ztex are vendored. Skript is an example dependency, not a toolkit export.
Pure drawing and formula operations do not open a terminal.

## Build and test

```sh
zig build
zig build test
zig build check
zig build test-repl
zig build test-formula
zig build docs
zig build bench
```

The default build installs `notui` and the examples under `zig-out/bin/`.
`check` compiles toolkit, REPL, and formula test paths.
`docs` writes each registered module under `zig-out/docs/<module>/`.
The benchmark reports frame timing, output bytes, and allocations.
It defaults to fast optimization unless an optimization mode is supplied.

## Examples

```sh
zig build run-example-spinner
zig build run-example-prompt
zig build run-example-statusline
zig build run-example-framework_counter
zig build run-example-kitty_image
zig build run-example-kitty_image_showcase
zig build run-example-bounded_smoke
zig build run-example-agent_demo
zig build run-skript-repl
zig build run-formula-tui
```

Use `q` or Ctrl+C to exit the spinner. The prompt submits text with Enter.
The framework counter demonstrates model updates, timer messages, and drawing.
Piped input selects plain output where the example supports it:

```sh
zig build run-example-statusline < /dev/null
zig build run-example-agent_demo -- --script
```

The formula example accepts `--algo sweep|fast` and `--bench N` in plain mode.
[FAST_COVERAGE.md](FAST_COVERAGE.md) describes the row rasterizer.

## Package use

Add notui as a dependency, then import the module in your build:

```zig
const dep = b.dependency("notui", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("notui", dep.module("notui"));
```

| Module | Purpose |
|---|---|
| `notui` | Terminal toolkit |
| `ztex` | Formula parsing, layout, SVG output, and font context |
| `ztex.atom` | Formula AST and payload codecs |
| `ztex.parse` | Parser and diagnostics |
| `ztex.layout` | Metrics-driven draw lists |
| `ztex.svg` | SVG serialization |

Register each additional import explicitly. Module import tables are not transitive.

`App(Model)` expects public `Msg`, `init`, `update`, and `view` declarations.
`Model.init(gpa)` returns `{ model, cmd }`. Construct the app with `init()`
or `initWithOptions(options)`, install an event-to-message filter, and call `run(io, gpa)`.
`update(model, msg, ctx)` returns `Cmd(Msg)`. `view(model, ctx)` returns `View(Model)`.
Optional `Model.deinit(self, gpa)` releases model resources.
See [examples/framework_counter.zig](examples/framework_counter.zig).

## Rendering and ownership

- Draw into `Region.cur`, then render the diff. Idle frames emit no bytes.
  `Region.exit` parks below the band and leaves its final frame in scrollback.
- `Region.resize(columns, terminal_rows, logical_band_height)` separates viewport and band sizes.
  Route cursor-position replies through `Region.applyCpr` before absolute image placement.
- Width reflow defaults to `.rewrapping`. Declare `.none` for terminals that never rewrap.
  Cleanup of returned retired rows waits for a fresh cursor-position reply.
- Paints use optional DEC 2026 synchronized output and leave autowrap enabled.
  Erasure stays within the band. The renderer does not emit screen-wide ED2 or ED3.
- `HistoryBatch { id, rows, kind }` uses monotonic ids and explicit acknowledgements.
  A replay supplies the complete logical ledger. The application decides when content is final.
- `OutputQueue` retains short writes and `WouldBlock` bytes in order.
  Stop composition when `canCompose` is false. Oversized frames fail without truncation.
- One-byte ASCII cells store text by value. Other graphemes and hyperlinks borrow caller bytes.
  Keep them valid through emission. `Region.prev` owns graphemes but borrows hyperlinks.
- `Text` and `Suggestions` require separate caller-owned scratch lists for concurrent components.
  Drawn cell text must remain valid until rendering consumes it.
- Reader event text borrows scratch until the next read. Copy events that must survive it.
  Direct parser paste results use the supplied optional allocator.
- Timer commands carry explicit messages. References in those messages remain caller-owned.
  `View` uses `Model.DrawError` when declared, otherwise the allocator error set.
- Manual terminal loops must select `width.setMode(.grapheme)` when DEC 2027 is active,
  otherwise `.codepoint`, before layout. Concurrent terminals cannot use different width modes.
- `ztex.Context.init(gpa, io)` borrows both arguments through disposal.
  Cached external font faces must remain at a stable address, alive, and unchanged.

Owning declarations document error sets, callback restrictions, and slice invalidation.
Do not copy storage owners as independent resources.

## Layout and development

`src/` contains toolkit modules and tests. `examples/` contains terminal programs and capture recipes.
`bench/` contains the render benchmark. `vendor/` contains the formula engine and Lisp runtime.

The optional devenv shell supplies terminal capture tools and fonts.
Set `NOTUI_SCRATCH_ROOT`, or `HOST_SCRATCH_ROOT`, to local scratch storage before entering it.
The shell stores caches there and links `zig-pkg` to its package directory.
`cross-test.profile.sh` selects Linux x86-64, x86, AArch64, and PowerPC64 tests.
Non-native execution requires the corresponding QEMU user-mode runner.

## License

MIT, see [LICENSE](LICENSE). Third-party components keep their own licenses: see THIRD_PARTY_NOTICES.md.
