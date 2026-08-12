# skript embedding contract — non-blocking REPL on notui

**Author:** research subagent A1SkriptContract
**Target:** implementer builds `examples/skript_repl.zig` from THIS file + notui `src/` only.
**Versions ground-truth:** skript `0.0.0` (build.zig.zon fingerprint `0x2cf1ccfb80bef1f4`, min zig 0.16.0); notui `0.0.0`.
**Verification basis:** skript `build.zig`, `src/root.zig`, `src/Runtime.zig`, `src/repl.zig`, `src/highlight.zig`, `src/Token.zig`, `src/Value.zig`, `src/builtin.zig`, `src/intrinsics/print.zig`; notui `build.zig`, `build.zig.zon`, `src/root.zig`, `notes/architecture.md` §5, `examples/prompt.zig`.

> The implementer reads ONLY this file and notui `src/`. Every claim below is grounded in the cited skript source; do not re-read skript.

---

## 1. Dependency wiring (build.zig.zon + build.zig)

### 1.1 skript as a path dependency

Add to notui `build.zig.zon` `.dependencies`:

```zig
.skript = .{ .path = "../../skript" },   // adjust path to the sibling checkout
```

`skript/build.zig.zon` declares `.paths = .{ "build.zig", "build.zig.zon", "src", "web" }`, so the fetch pulls those. (Alternatively use a `git+` URL pinned by hash; a `.path` dep is simplest for a sibling checkout.)

### 1.2 Fetch note — which of skript's deps get pulled (LIBRARY module only)

When Zig runs skript's `build.zig` to build the **library module**, it materializes skript's dependencies that the module tree references:

- **`tracy` (REQUIRED, git URL fetch).** `skript/src/root.zig:3` does `pub const tracy_impl = @import("tracy_impl")`; `Runtime.zig` imports `@import("tracy")`. skript's `mod` unconditionally wires both `.tracy` and `.tracy_impl` (enabled/disabled), so the tracy dependency MUST be fetched (`git+https://codeberg.org/CoffeeImpliesCode/tracy_zig#b2ea5bf…`). Your build therefore needs network/cache access to codeberg the first time.
- **`libffi` (LAZY, default-ON for your target).** skript `build.zig` resolves it only via `b.lazyDependency("libffi", …)` inside `if (platform.ffiSupported(target.result) and libffi_enabled)`. On `x86_64-linux` `ffiSupported` is true and `enable_libffi` defaults true, so the static `ffi` artifact is fetched and linked by default. To skip it, pass the build option to the dependency: `b.dependency("skript", .{ .target = …, .optimize = …, .enable_libffi = false })`. Optional; leaving it on is fine.
- **`zigzag` / `zemscripten` (NOT required for the LIBRARY).** `zigzag` is a path dep (`third_party/zigzag`) imported ONLY by skript's `exe`/`bench` root modules, and `zemscripten` is web-only. The library module never imports them, so they are not fetched for your use.

### 1.3 build.zig module wiring (consumer)

You do NOT re-wire skript's internal imports (`platform`, `options`, `tracy`, `tracy_impl`). skript's `build.zig` calls `b.addModule("skript", …)` with all of them already connected; `b.dependency(...).module("skript")` hands you the fully-wired module. Consumer wiring:

```zig
const skript_dep = b.dependency("skript", .{ .target = target, .optimize = optimize });
const skript_mod = skript_dep.module("skript");

const repl_exe = b.addExecutable(.{
    .name = "skript-repl",
    .root_module = b.createModule(.{
        .root_source_file = b.path("examples/skript_repl.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,          // REQUIRED: fd-capture extern block (§6)
        .imports = &.{
            .{ .name = "notui", .module = notui_mod },   // existing notui module
            .{ .name = "skript", .module = skript_mod },
        },
    }),
});
repl_exe.root_module.use_llvm = true; // tracy needs LLVM debug info (skript main.zig rationale)
```

- **`link_libc = true`** on the EXAMPLE root module is REQUIRED for the `extern "c" pipe/dup/dup2/read/close` fd-capture (§6). The skript library module itself does NOT set `link_libc` and builds without it; you only need libc in your example.
- **`use_llvm = true`**: skript forces `use_llvm` on its own lib/exe "because the tracy client's stack capture and symbolication depend on LLVM-emitted debug info". Mirror it on the example so the tracy client behaves.
- Add a `run-example` step for `skript-repl` matching the existing examples pattern in notui `build.zig` (`b.step("run-example-…", …)` + `b.addRunArtifact`).

---

## 2. Runtime lifecycle

```zig
const Runtime = skript.Runtime;

var rt = try Runtime.init(gpa, io);   // gpa: std.mem.Allocator, io: std.Io
defer rt.deinit();
```

- **`pub fn init(gpa: Allocator, io: std.Io) !*Runtime`** (`Runtime.zig`) returns a HEAP-allocated `*Runtime` (`gpa.create`). Pass the app's `init.gpa` and `init.io` (the same `std.Io` the notui loop uses). Init loads the prelude through the stack VM, builds the store, registers builtins/intrinsics — do it once at startup, before the TUI loop. Cost is bounded but non-trivial; never init per-query.
- **`pub fn deinit(self: *Runtime) void`** frees the arena/store and **drains scheduler runner threads** (marks shutdown, sets the event, awaits each runner). Never call `deinit()` while a worker thread (§5) is inside the runtime — finish/park the worker and join it first, then deinit. Quitting mid-eval may block until the in-flight eval yields (skript's cooperative scheduler; same as skript's own REPL — accepted for v1).
- Public fields the REPL touches directly: `rt.root_ns` (`Value`), `rt.predefined_types` (`[]*Type`, indexed by type tag). `root.zig` also exports `builtins` and `intrinsics` (see §4).

---

## 3. evalString contract

```zig
pub fn evalString(self: *Runtime, src: []const u8) Error!Value
```

- Implementation (`Runtime.zig:5432`): `const node = try self.read(src, .Expression); return self.evalNode(self.root_ns, node);`
- **Namespace persistence:** YES. Every call evaluates against the same `root_ns`, so `def`/`defn` from earlier calls are visible later. Proven by the root.zig test "cross-query namespace persistence (REPL pattern)" (`(defn (add1 x) …)` then `(add1 5.0)` → `6.0`). This is exactly the REPL pattern.
- **Errors:** returns `skript.Error` (a flat error set: `UnexpectedToken, MalformedAst, Unbound, TypeMismatch, ArityMismatch, StackOverflow, OutOfMemory, Unsupported, …`, see `root.zig` `pub const Error`).
- **Parse vs eval distinction:** `evalString` does NOT distinguish phases. To label errors correctly, mirror `repl.zig` `Query.submit` — do the two-step yourself:

```zig
const node = rt.read(query, .Expression) catch |e|
    return .{ .phase = .parse, .e = e };
const v = rt.evalNode(rt.root_ns, node) catch |e|
    return .{ .phase = .eval, .e = e };
return .{ .ok = v };
```

Then render the label `"Parser error: {any}"` / `"Eval error: {any}"` (`std.fmt.allocPrint("{s}: {any}", .{ label, er.e })`). `query` = `std.mem.trimEnd(u8, q, " \n\r\t")`.

- **`Value` shape** (`Value.zig`): `extern struct { typ: Object, obj: Object }`. `.typ` is an `Object` enum whose integer value is the builtin type index (used in §4). `.obj` encodes immediates or a store ref. Read-only use of a finished `Value` is fine; the bytes it points into live in the runtime arena (stable until `deinit`).

---

## 4. Value printing recipe

Copy this shape exactly from `repl.zig` `Query.submit` (the `{f}` formatter is `intrinsics.print.FormatValue`, exported from `root.zig` as `intrinsics`; `builtins` is also exported):

```zig
const res = /* Value from §3 (ok branch) */;
const tag_val: u64 = @intFromEnum(res.typ);
const typ_ptr: *skript.Type = if (tag_val <= skript.builtins.type_last_idx)
    rt.predefined_types.items[@as(usize, @intCast(tag_val))]
else
    res.typ.toRef().deref(skript.Type);
const answer0 = std.fmt.allocPrint(alloc, "{f} ({s})", .{
    skript.intrinsics.print.FormatValue{ .value = res, .runtime = rt, .pretty = true },
    typ_ptr.name.toPtr(skript.Sym).*,
}) catch "OoM";
```

- `{f}` uses `FormatValue` (`intrinsics/print.zig:104`): `struct { value: Value, runtime: *Runtime, pretty: bool = false, raw_strings: bool = false }`. `.pretty = true` makes tensors render in the classical aligned multi-line matrix layout (REPL answers). The `({s})` suffix is the value's type NAME via the `typ_ptr.name` symbol — the exact `"{f} ({s})"` answer format skript's REPL uses.
- **Multi-line hanging indent:** if `answer0` contains `'\n'` (pretty tensors), re-indent every line after the first by the DISPLAY WIDTH of the `" ⇒ "` prefix (see `repl.zig` `hangIndent`). Use notui's width seam: `const w = notui.width.strWidth(" ⇒ ");` then for each line past the first emit `'\n'` + `w` spaces. (notui is the width authority — do NOT use byte length; `⇒` is a wide glyph.)
- The final answer line a REPL shows is `"{query}\n ⇒ {answer}"`; query styling/boxing is optional (§8).

---

## 5. Non-blocking threading contract

**Rule: the `*Runtime` is used by exactly ONE thread at a time.** The notui main thread must NOT call any skript API while an eval is in flight. All eval (compile + run + format the answer into owned bytes) happens off the UI thread; the main loop only reads a published result.

### 5.1 Primary: worker `std.Thread` + mutex-guarded result slot (full eval off the UI thread)

- On Enter with a non-empty, non-busy line: copy the trimmed query into the app arena, spawn a `std.Thread` whose fn:
  1. runs the §3 two-step (`read` + `evalNode`) — all `Runtime` access happens here;
  2. formats the answer (§4) into **arena/owned `[]u8`** (so the main thread never dereferences runtime memory);
  3. stores `{ phase: enum { ok, parse, eval }, answer: []const u8, lib_out: []const u8 }` into the slot under a `std.Thread.Mutex` (or a single `std.atomic.Value` flag + mutex'd payload);
  4. joins/self-terminates.
- **Main loop each tick** (after `reader.nextTimeout(tick_ms)` returns `null`): lock the slot; if it holds a fresh result, `region.append` the query + answer lines (§8), clear the slot, and set `busy = false`. Then keep rendering (spinner turns while `busy`).
- **No overlap:** if `busy` is true, ignore further Enter (or queue at most one pending query; do not spawn a second worker). Only one eval at a time — the Runtime is single-owner.
- The worker must be joinable and joined before `rt.deinit()`.

### 5.2 Alternative (lighter, native): skript's scheduler + `pollProcess`

skript ships a non-blocking eval path that runs the process on its OWN internal runner thread — no manual worker needed:

```zig
const proc = try rt.spawnEval(src);            // compile happens on the CALLING thread (fast), then enqueue
// main loop each tick:
if (rt.pollProcess(proc)) |res| {               // ?Error!Value — null while running; non-blocking (atomic future)
    const v = try res;                          // or catch → eval error
    /* format + append; may now spawnEval the next query */
}
```

- `spawnEval` compiles synchronously on the calling (UI) thread; `pollProcess` reads a `future_obj`/`done` atomic pair — safe to call from the main loop while the runner thread executes. Same single-Runtime-at-a-time rule applies: while a process runs, the main thread calls only `pollProcess`.
- Trade-off vs §5.1: compile runs on the UI thread (a huge query can briefly stall the frame); §5.1 offloads everything. Pick §5.1 unless you want the smaller code surface.

### 5.3 Caveats

- **No thread-unsafe global in the skript runtime** breaks single-thread-at-a-time: `Runtime` state is instance-owned (arena, symbol pool, root_ns, scheduler). The only REPL globals in skript's `repl.zig` (`repl_use_regvm`, `hl_engine`) are host-thread-only and not part of the library. The tree-sitter engine is not thread-safe but you are NOT using it (§7).
- **fd-capture is process-wide** (§6): `dup2` on fd 1/2 affects all threads. In §5.1 run `begin`/`end` inside the worker around the eval; in §5.2 around the `spawnEval`/`pollProcess` drain. notui renders through `Tty.writer` (its own fd, not fd 1/2), so redirecting 1/2 does not corrupt the region.

---

## 6. fd-capture recipe

Why: a form's libraries write raw bytes to the process's fd 1/2. Without redirection those interleave with the TUI's escape sequences and glitch the region. Captured output is rendered muted under the answer.

Quote the extern block verbatim from `repl.zig` (this is why `link_libc = true` is required):

```zig
const libc = struct {
    extern "c" fn pipe(fds: *[2]std.posix.fd_t) c_int;
    extern "c" fn dup(fd: std.posix.fd_t) c_int;
    extern "c" fn dup2(old_fd: std.posix.fd_t, new_fd: std.posix.fd_t) c_int;
    extern "c" fn close(fd: std.posix.fd_t) c_int;
    extern "c" fn read(fd: std.posix.fd_t, buf: [*]u8, n: usize) isize;
};
```

Flow (mirror `repl.zig` `OutputCapture`):
1. **begin:** `pipe(&fds)`; `saved[0]=dup(STDOUT_FILENO)`, `saved[1]=dup(STDERR_FILENO)`; `dup2(pipe[1], STDOUT_FILENO)` and `dup2(pipe[1], STDERR_FILENO)`; close `pipe[1]`. Any failure → restore and evaluate WITHOUT capture (best-effort; a capture failure never aborts the eval).
2. Run the eval (§3).
3. **end:** FIRST restore `dup2(saved[0], STDOUT_FILENO)` / `dup2(saved[1], STDERR_FILENO)` and close the saved fds (a straggling write then lands on the terminal, not the pipe), THEN drain `read(pipe[0], buf, …)` into arena memory until `<= 0`; close `pipe[0]`.

Post-process captured bytes (mirror `ownLibOut`): strip ANSI escape sequences (a colored library must not corrupt the TUI) and cap at ~8192 bytes; truncate with a trailing `"\n… (truncated)"`. Cap the RENDER at 5 lines + a `"… N more captured line{s}"` suffix (mirror `libPreview`; if ≤5 lines show all, stripping one trailing newline).

---

## 7. Highlighting decision — HAND-ROLLED

`highlight.zig` is **NOT exported from `root.zig`** (grep of `src/root.zig` finds no `pub const highlight`). `repl.zig` imports it directly (`@import("highlight.zig")`), but that file requires the build-time `highlight_query` module, the system shared `libtree-sitter`, a C-compiled grammar from the sibling `tree-sitter-skript` checkout, and libc — none of which your REPL wires. **Implement your own lightweight keyword scanner.**

- Use the shared **Capture palette** from `highlight.zig` (vocabulary, not code): `keyword, string, comment, number, constant, function, operator, punctuation, builtin, plain`. Map to notui `Style` colors; `plain`/`punctuation` render unstyled.
- **Lexer reality (from `Token.zig`):** comments are consumed by the lexer and emit NO token kind (`;` line comments, `#|…|#` nested block comments, `#!` shebang at offset 0 are skipped in `skipWhitespaceAndComments`/`skipBlockComment`). So a scanner built on `Token.lex` can never see comments — your hand-rolled scanner must detect them itself. `Token.Kind` values you can use for structure: `lparen, rparen, lbracket, rbracket, lbrace, rbrace, period, quote, identifier, keyword (":foo"), map_marker (":{"), number, string, datum_comment ("#;"), null, eof`.
- Minimum useful coloring (match skript's special-form set + reader):
  - **string** — text between `"` (respect `\` escapes);
  - **number** — integer/float/complex/scientific/radix literals;
  - **comment** — `;` to EOL, and nested `#|…|#`;
  - **keyword literal** — `:name` (including `:{` map marker);
  - **special-form keyword** — `begin, case, def, defn, fn, if, lambda, let, quote, set!` (these are compiler special forms; the prelude binds the rest);
  - **symbol/identifier + punctuation** — everything else (parens/braces/brackets/operators like `+`, `<` as plain/punctuation).
- Optional: line-number prefix + fixed indentation so styled and plain render identically (see `repl.zig` `highlightQuery`).
- A full engine is out of scope; plain (unstyled) input must still render and eval correctly.

---

## 8. History + keybindings spec (mirror `examples/prompt.zig`)

**Layout:** a 2-row `Region` (`Region.init(gpa, .{ .height = 2 })`). Row 0 = the input band (prompt prefix + echoed typed text); row 1 = status line (busy spinner while an eval runs, idle prompt otherwise). Scrollback ABOVE the band: each completed submission appends its query + answer via `region.append(.{ .line = … })`. Chunk every over-wide `.line` with `notui.width.truncate(aa, text, region.width)` so each entry occupies exactly one row (a wrapped `.line` would drift the region's anchor accounting — prompt.zig `pushLine`).

**Input loop** (exact prompt.zig skeleton — copy it):
- `reader.nextTimeout(tick_ms)` with `tick_ms = 100`; `if (ev) |e| switch (e)`; `null` = the tick used to poll the result slot (§5) and re-render the spinner.
- Key text **must be copied** into the app arena before the next read (`Key.text` is valid only until the next `Reader.next` — the §3 lifetime contract in `architecture.md`).
- **`Key.matches(Key.enter, .{})`** → submit the line (§3/§5); clear the line.
- **`Key.backspace`** → remove the last UTF-8 codepoint (`popCodepoint` pattern).
- **`ctrl+c`** → clear the line (a NORMAL key event — never hard-quit). Accept both decodings: `k.matches(Key.ctrl_c, .{}) or k.matches('c', .{ .ctrl = true })`.
- **`ctrl+d`** → quit. Prompt.zig defines `const ctrl_d: u21 = 0x04;` and `isCtrlD(k) = k.matches(ctrl_d, .{}) or k.matches('d', .{ .ctrl = true })`.
- **`q`** on an EMPTY line → quit (`k.matches('q', .{}) and line.len == 0`).
- **`Key.escape`** → ignore.
- **Up / Down arrows** → navigate an in-memory history ring of prior submitted queries (NEW — prompt.zig has no history; the REPL needs it). Preload the input band with the selected entry. Bound to a fixed ring size (e.g. 100).
- **`winsize`** event and `tty.checkResize()` → `region.resize(wsz.cols, 2)`.
- Every frame: redraw the 2-row band (`region.cur.clear(); draw input at (0,0); draw status/spinner at (0,1);`), then `region.render(w); try w.flush();`
- On exit: `region.exit(w); try caps.restore(w); try w.flush();`
- `Tty.init` → `makeRaw` → detect caps → run loop → `restore`. Set `pub const panic = std.debug.FullPanic(…)` that calls `notui.tty.restoreTerminal()` first (prompt.zig pattern — raw/hidden-cursor terminal forces a hard reset on panic).
- Non-TTY degradation: if `!Tty.isTty(stdin)`, print one plain line (no interactive sequences) and exit (prompt.zig `runPlain`).
- **Busy guard:** while a worker is evaluating (§5), Enter does not submit; the status line shows the spinner so the user knows.

---

## 9. Open questions for the orchestrator

1. **libffi build dep:** default-on for `x86_64-linux` means the skript dependency pulls and statically links libffi (git fetch). Should the example pass `.enable_libffi = false` to keep the build lean, or accept the default? (Affects §1.2 fetch surface.)
2. **Threading choice:** worker `std.Thread` + mutex slot (§5.1, full eval off the UI thread) vs native `spawnEval`+`pollProcess` (§5.2, smaller code but compile on the UI thread). Which should be the shipped implementation?
3. **History rendering:** plain per-line `.line` scrollback with an `" ⇒ answer"` continuation (chunked per width) as specified here, or boxed per-query blocks like skript's `Query.render`? The boxed look is nicer but heavier to chunk; confirm the line-based default is acceptable.

## 10. Addendum (from the dogfood implementation)

- **rt.stdout landmine**: skript `Runtime.init` heap-creates the Runtime WITHOUT
  zeroing; `stdout: ?*std.Io.Writer = null` is debug-fill (0xaa) in Debug
  builds. Any host that does not set `rt.stdout` crashes with a GP on
  display/write. The dogfood REPL sets it to an unbuffered fd-1 writer
  (mirrors skript's own repl.zig). Set it before first eval.
- **emcc**: skript's build.zig runs its Emscripten web section
  UNCONDITIONALLY at build() time and panics without `emcc` on PATH. The web
  step never executes for non-wasm targets — a dummy executable named `emcc`
  on PATH (e.g. `touch /tmp/notui-fakebin/emcc`) satisfies it. The house
  gate runs with `PATH=/tmp/notui-fakebin:$PATH`.
