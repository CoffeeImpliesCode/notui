# skript REPL dogfood — round-2 improvement contract (A1)

**Author:** research subagent A1ReplImprovements
**Target:** implementer reworks `examples/skript_repl.zig` (the v1 dogfood REPL, ~850 lines) from THIS file + notui `src/` + `notes/research/skript-embed-contract.md` only. **The implementer does NOT re-read skript.** Every skript/zigzag claim below is grounded in the cited file:line; pull exact code from those locations only if a verbatim shape is needed.
**Versions ground-truth:** skript `0.0.0` (embed contract); notui `0.0.0`; zig 0.16.0.
**Scope:** a focused round on the v1 REPL's concrete gaps. Not a rewrite. The 2-row `Region` band layout, `.line` scrollback, history ring, fd-capture, keyword scanner, and `runtime.stdout` handling from the embed contract are all KEPT as-is. Only the gaps listed in §1 are touched.

> **Author's measured timing (regvm vs stack) — the contract's central factual claim.** I ran skript's own bench on the cached build (`~/projects/skript/zig-out/bin/skript-bench`, source `src/bench.zig:13-89`):
> ```
> (+ 1 2): stack=41us  reg=1074us
> (let ((x 5) (y 10)) (+ x y)): stack=92us reg=1040us
> (defn fib (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (fib 10): stack=10968us reg=1070us
> ```
> **Measured.** regvm is ~10× faster on the compute-heavy recursion (fib 10: 1.07ms vs 10.97ms) but pays a ~1ms fixed dispatch/await floor on trivial forms (1074us vs 41us) — the floor is `awaitProcess`'s 1ms poll cadence + scheduler dispatch, and is **imperceptible in the REPL** because the eval already runs off the UI thread on a worker. skript's own source confirms the stack VM "runs out of the fixed store heap beyond ~fib(17)" (Runtime.zig:8566) — a real v1 failure mode the regvm path removes.

---

## 1. Gap list vs the v1 REPL

The v1 REPL already does correctly (KEEP — do not regress): keyword highlighting (`scanQuery`), `hangIndent` multi-line pretty-tensor answers (`formatAnswer`), fd-capture (`OutputCapture`/`ownLibOut`/`libPreview`), 100-entry history ring, busy-spinner status, `q`/Ctrl+D quit, `runtime.stdout` landmine fix (embed-contract addendum), non-TTY `runPlain` degradation.

Concrete gaps, ordered by impact:

| # | Gap | Today (v1) | Improvement |
|---|-----|-----------|-------------|
| G1 | **No cursor / no editing** | input is append-only (`appendKeyText` pushes to `line.items` end); backspace pops the last codepoint; no Left/Right/Home/End, no Delete, no mid-line insert, no word movement, no kill commands | Full cursor + editing keymap (§3) |
| G2 | **No multi-line input** | Enter always submits; a multi-line form is untypeable | Paren/brace/bracket-aware Enter → continuation (§4) |
| G3 | **Slow / legacy eval** | worker runs `Runtime.init` (stack VM) + `read`/`evalNode`; stack VM OOMs on deep recursion (fib>17) | regvm fast path `spawnEval`+`awaitProcess` with stack-VM fallback; init with `Runtime.initRegvm` (§2) |
| G4 | **No meta commands** | only `q`(empty)/Ctrl+D quit | `:help`, `:quit`/`:q` (§5) |
| G5 | **No answer guard** | a huge pretty answer floods the scrollback | byte + line caps with a truncation marker (§6) |
| G6 | **No elapsed-time report** | the spinner animates but gives no feedback on how long an eval took | status-band "done in {d}ms" (§7) |

`(b) multi-line answers` from the improvement surface is **already satisfied** by v1 `formatAnswer` (embed-contract §4 `hangIndent` recipe) — no work. `(e) Tab completion` and `undo` are **OUT** (see §8).

---

## 2. G3 — fast eval via the register VM (regvm path)

### 2.1 Runtime init
Swap the runtime construction from the stack-VM default to the regvm engine, matching skript's own REPL (`repl.zig:551-554` chooses `Runtime.initRegvm` when `repl_use_regvm`):

```zig
var rt = try skript.Runtime.initRegvm(gpa, io);   // was: skript.Runtime.init(gpa, io)
defer rt.deinit();
```

`initRegvm` (`Runtime.zig:100-102`) initializes identically to `init` but loads the prelude through the register VM (`initInternal` `.regvm` arm, `Runtime.zig:200-213`). Everything else (store, root_ns, `rt.stdout` assignment, single-owner threading) is unchanged. Do NOT switch on a flag — this REPL is regvm-only.

### 2.2 Worker eval restructure (threaded-worker notes)
Keep the worker-thread + atomic result-slot architecture from v1 (embed-contract §5.1). Change only the eval step inside `evalWorker`. Exact shape:

```zig
/// regvm fast path with a stack-VM fallback for non-compilable forms.
/// Port of skript repl.zig evalRegvmForm (:252-255): spawnEval compiles on
/// THIS (worker) thread, enqueues a cooperative process on the scheduler's
/// permanent runner, and awaitProcess parks this worker polling the process's
/// future (Runtime.zig:4489-4504). Fallback: if the form is not regvm-
/// compilable (error.Unimplemented — skript bench.zig:40), evaluate the
/// parse-gate node with evalNode (stack VM), exactly like the v1 path.
fn evalFast(rt: *skript.Runtime, query: []const u8, node: skript.AstNodeRef) !skript.Value {
    const proc = rt.spawnEval(query) catch |e| switch (e) {
        error.Unimplemented => return rt.evalNode(rt.root_ns, node),
        else => return e,
    };
    return rt.awaitProcess(proc);
}
```

and in `evalWorker`, keep the two-phase parse-gate (unchanged from v1, preserves correct "Parser error" vs "Eval error" labels) but route the eval through `evalFast`:

```zig
const node = ctx.rt.read(ctx.query, .Expression) catch |e| blk: {
    phase = .parse;
    answer = std.fmt.allocPrint(aa, "Parser error: {any}", .{e}) catch "Parser error";
    break :blk null;
};
if (node) |n| {
    const v: ?skript.Value = evalFast(ctx.rt, ctx.query, n) catch |e| blk: {
        phase = .eval;
        answer = std.fmt.allocPrint(aa, "Eval error: {any}", .{e}) catch "Eval error";
        break :blk null;
    };
    if (v) |val| answer = formatAnswer(aa, ctx.rt, val);
}
```

### 2.3 Who runs what (threading map)
- **Parse gate** `rt.read(query, .Expression)` — worker thread (unchanged from v1).
- **`spawnEval(query)`** — compiles on the **worker** thread ("ON THE HOST for direct host spawns", Runtime.zig:4247-4248). It calls `Reader.readAll(self.store, src)` then `analyzeRegData` (Runtime.zig:4251-4252) and enqueues a cooperative process on the scheduler's **permanent runner thread** (Runtime.zig:4290-4297 dispatch when `runner_active` is clear), publishing a `FutureObj`.
- **`awaitProcess(proc)`** — **blocks the worker thread**, polling `pollProcess` (the `FutureObj.done` atomic) with a 1ms `std.Io.sleep` (Runtime.zig:4490-4500). The **runner thread** executes the process's register VM bytecode concurrently.
- **Main thread** — touches ONLY the result slot (polling `slot.ready`), never the runtime. The single-owner rule (embed-contract §5) is preserved: exactly one host thread (the worker) is inside the runtime at a time; the runner is the runtime's own internal thread and is exempt, exactly as in skript's own REPL.

### 2.4 fd-capture interaction
The eval now runs on the runner thread while the worker blocks in `awaitProcess`. fd redirection is process-wide (`dup2` affects all threads), so the runner's fd-1/2 writes land in the capture pipe. The existing worker-side flow is correct and unchanged: `capture.begin()` before the eval, `capture.end(aa)` after `awaitProcess` returns — by then the process's future is done, so all its writes have drained; restore the fds first, then drain (embed-contract §6). **No change to `OutputCapture`.**

### 2.5 Error modes (regvm path)
- `spawnEval` returns `skript.Error` for **parse/compile** failures (`Reader.readAll`/`analyzeRegData`), except `error.Unimplemented` when the form isn't regvm-compilable — that one falls back to `evalNode` (§2.2) so it still evaluates, not errors.
- `awaitProcess` returns `skript.Error` for **eval** failures; a crashed process publishes `Value.err(...)` which `pollProcess` unwraps into the Zig error (Runtime.zig:4511-4513), so `try` behaves like a normal eval failure.
- A successful parse gate (`read`) does NOT guarantee `spawnEval` succeeds (compile can still fail) — hence the fallback. After the fallback's `evalNode`, errors are labeled "Eval error", matching v1 semantics.

### 2.6 Namespace persistence (regvm path)
`spawnEval` binds defs into `root_ns` ("binding defs into root_ns", Runtime.zig:4204; `spawnEvalWithNs(src, root_ns, null)` Runtime.zig:4208-4209). skript's own test pins the REPL repro — "two defs in separate submissions, then a lookup in a third" (Runtime.zig:7365-7369). So `(defn (add1 x) …)` then `(add1 5.0)` in two separate submissions yields `6.0`, exactly like the v1 stack path. Verify in §9.

---

## 3. G1 — cursor + input editing

### 3.1 State
Add a byte-indexed cursor to the input loop:

```zig
var cursor: usize = 0;   // byte index into line.items
```

The existing `line: std.ArrayList(u8)` stays the backing buffer. All edits operate **at the cursor**, not append-only. The cursor is a BYTE index; every operation must stay on UTF-8 codepoint boundaries (see helpers below).

### 3.2 Keymap (exact, ported from zigzag `TextInput.handleKey`, text_input.zig:164-231)

| Key (notui `Key`) | Action |
|---|---|
| `Key.left` | cursor back one codepoint (v1 has no such arm; add it) |
| `Key.right` | cursor forward one codepoint |
| `Key.home` | cursor = 0 |
| `Key.end` | cursor = line.items.len |
| `k.matches(Key.left, .{ .alt = true })` | move word left (Alt+Left) |
| `k.matches(Key.right, .{ .alt = true })` | move word right (Alt+Right) |
| `k.matches('a', .{ .ctrl = true })` | cursor = 0 (Ctrl+A) |
| `k.matches('e', .{ .ctrl = true })` | cursor = line.len (Ctrl+E) |
| `k.matches('k', .{ .ctrl = true })` | kill to end: `line.items.len = cursor` (Ctrl+K) |
| `k.matches('u', .{ .ctrl = true })` | kill to start: delete `[0..cursor]`, cursor = 0 (Ctrl+U) |
| `k.matches('w', .{ .ctrl = true })` | delete word backward (Ctrl+W) |
| `k.matches(Key.backspace, .{})` | delete codepoint before cursor |
| `k.matches(Key.delete, .{})` | delete codepoint at cursor (NEW arm) |
| any text key (`appendKeyText` result) | **insert** at cursor, cursor += inserted bytes |

**Ordering rule** (match zigzag): check `alt`-modifier arms first, then `ctrl`-modifier arms (both `return` after handling), then the plain keys. Alt+Left/Right and Ctrl+… never fall through to text insertion. Home/End keys and `Key.delete` are PUA codepoints (`Key.zig:57356/57357/57349`) with `.text == null`, so `appendKeyText` already emits nothing for them — but the new explicit arms must come BEFORE the generic text-insert fallback in the key switch.

### 3.3 Edit helpers (port zigzag word semantics exactly)
Byte-codepoint helpers:

```zig
/// UTF-8 sequence length of the codepoint starting at buf[i].
fn utf8SeqLen(buf: []const u8, i: usize) usize {
    return std.unicode.utf8ByteSequenceLength(buf[i]) catch 1;
}
/// Byte index of the codepoint boundary before `cursor`.
fn prevCodepoint(buf: []const u8, cursor: usize) usize {
    if (cursor == 0) return 0;
    var p = cursor - 1;
    while (p > 0 and (buf[p] & 0xC0) == 0x80) p -= 1;
    return p;
}
```

Word movement / kill — port verbatim from zigzag (`moveCursorWordLeft` text_input.zig:374-386, `moveCursorWordRight` :388-401, `deleteWordBackward` :340-351) onto the byte cursor:

```zig
fn moveWordLeft(buf: []const u8, cursor: usize) usize {
    var c = cursor;
    while (c > 0 and buf[c - 1] == ' ') c -= 1;        // skip trailing spaces
    while (c > 0 and buf[c - 1] != ' ') c -= 1;        // skip word chars
    return c;
}
fn moveWordRight(buf: []const u8, cursor: usize) usize {
    var c = cursor;
    while (c < buf.len and buf[c] != ' ') c += 1;      // skip word chars
    while (c < buf.len and buf[c] == ' ') c += 1;      // skip spaces
    return c;
}
```

`deleteWordBackward`: delete `[moveWordLeft(buf, cursor)..cursor]`, set cursor to the new start. (zigzag's per-codepoint `deleteBackward` loop is equivalent to one slice delete; a single `std.mem.copyForwards` shift + `shrinkRetainingCapacity` is fine and cheaper.)

Insert at cursor: `line.insertSlice(aa, cursor, text) catch {}; cursor += text.len;` (ArrayList supports `insertSlice`). Kill-to-end: `line.items.len = cursor;`. Kill-to-start: `std.mem.copyForwards(line.items[0..], line.items[cursor..]); line.items.len -= cursor; cursor = 0;` (port of text_input.zig:188-193).

**Backspace/Delete must remove whole codepoints** (delete `[prevCodepoint..cursor]` / `[cursor..cursor+utf8SeqLen]`), not single bytes — matches the v1 `popCodepoint` intent, now cursor-aware.

### 3.4 History interaction
Up/Down already load an entry into `line` (`History.load`); set `cursor = line.items.len` after loading (and after `line.clearRetainingCapacity()` for the down-at-new-line arm). A history entry recalled mid-editing discards the in-progress cursor position (accepted — the whole line is replaced).

### 3.5 Cursor rendering in the band
Replace the single `scanQuery(line.items)` pass in `drawBand` (v1) with a three-piece render around the cursor so the cursor cell is visible (reverse video). The existing `region.cur.draw(style, text, x, y)` returns columns consumed; the prompt is drawn first:

```zig
region.cur.clear();
var x = try region.cur.draw(.{}, prompt_text, 0, 0);
const cur_style: Style = .{ .attrs = .{ .reverse = true } };   // reverse-video block

// Left of cursor.
for (scanQuery(aa, line.items[0..cursor])) |seg|
    x += try region.cur.draw(seg.style, seg.text, x, 0);

if (cursor < line.items.len) {
    const clen = utf8SeqLen(line.items, cursor);
    const cell = line.items[cursor .. cursor + clen];
    _ = try region.cur.draw(cur_style, cell, x, 0);
    x += notui.width.strWidth(cell);
    for (scanQuery(aa, line.items[cursor + clen ..])) |seg|
        _ = try region.cur.draw(seg.style, seg.text, x, 0);
} else {
    _ = try region.cur.draw(cur_style, " ", x, 0);      // block cursor at EOL
}
// status row (row 1): unchanged (spinner while busy, else hint / elapsed-time §7).
```

`notui.width.strWidth` and `notui.width.truncate` are already used by v1; `Style.attrs.reverse` is supported (`style.zig:28`). This keeps the 2-row band fixed; the active line may overflow the row width — the existing behavior draws it (no wrap), acceptable for v1→v2 (see open question Q3). **Undo is OUT** (zigzag's TextInput has no undo; §8).

---

## 4. G2 — multi-line input (paren/brace/bracket-aware Enter)

### 4.1 Balance detection
skript exports the lexer at the package root (`root.zig:63-67`: `pub const Token`, `TokenKind`, `Cursor`, `lex`). The lexer already skips line/block comments and string bodies internally (`Token.lex` Token.zig:108; `lexString` errors on an unterminated string Token.zig:390; `skipBlockComment` errors on EOF Token.zig:220), so a token-walk depth scan is complete and robust:

```zig
/// True when `src` is a complete expression (balanced delimiters, no
/// unterminated string/comment). False = incomplete → continue input.
/// Uses the skript lexer, which skips comments/strings internally.
fn isComplete(src: []const u8) bool {
    var c: skript.Cursor = .{ .src = src };
    var depth: i32 = 0;
    while (true) {
        const tok = skript.lex(&c) catch return false;   // unterminated string/comment → incomplete
        switch (tok.kind) {
            .lparen, .lbracket, .lbrace, .map_marker => depth += 1, // :{ is a grouping opener
            .rparen, .rbracket, .rbrace => depth -= 1,
            .eof => return depth <= 0,                    // negative = overclosed → submit (reader will error)
            else => {},
        }
    }
}
```

Token kinds are `skript.TokenKind` (`Token.zig:80-90`). `map_marker` (`:{`) counts as an opener; a bare `:` keyword does not. This matches the reader's own completeness rules: `readForm` errors on a bare `.eof` (Reader.zig:122), unbalanced maps/tensors error on `.eof` (Reader.zig:188, 213). Rationale: `skript.lex` is already exported, so no new skript dependency and no hand-rolled re-scan (unlike the existing `scanQuery`, which is a *styling* scanner and must stay as-is for rendering).

### 4.2 Enter behavior
The `line` buffer now holds the FULL pending input and MAY contain embedded `'\n'`. On Enter with a non-busy worker:

```zig
const trimmed = std.mem.trim(u8, line.items, " \n\r\t");
if (trimmed.len == 0) return;                       // empty: nothing to do (matches v1)
if (!isComplete(line.items)) {                      // unbalanced → continue input
    try line.append(aa, '\n');
    cursor = line.items.len;
    return;
}
try submit(...);                                    // existing submit; clears line + cursor
```

`submit` must now clear BOTH `line` and `cursor` (set `cursor = 0`) after spawning the worker. `appendEntry` already splits the query by `'\n'` before chunking (v1), so a multi-line submission renders correctly with no change.

### 4.3 Continuation rendering
`drawBand` renders only the ACTIVE line — the text after the last `'\n'` in `line` (this is also required by §3.5, which renders `[0..cursor]`/cursor/`[cursor..]`; with an embedded `'\n'` in the buffer, only scan the ACTIVE slice). Add a continuation prompt when the buffer spans multiple lines:

```zig
const cont_prompt = "    · ";   // continuation indent+marker, width-stable
const active = if (std.mem.lastIndexOfScalar(u8, line.items, '\n')) |nl|
    line.items[nl + 1 ..] else line.items;
const prompt = if (std.mem.indexOfScalar(u8, line.items, '\n') != null) cont_prompt else prompt_text;
// draw `prompt` then the cursor-split of `active` (adjust the §3.5 slice boundaries
// to `active` relative to a `cursor` clamped into active's range).
```

Clamp the cursor into the active line when a continuation `'\n'` is appended (§4.2 sets it to end anyway). When the buffer is mid-continuation, the idle status-band hint (§7) shows `multiline: Enter to continue`. This keeps the 2-row band fixed; it does NOT grow to preview prior continuation lines (see open question Q3).

---

## 5. G4 — meta commands

Handle leading-`:` commands BEFORE the eval path, in the key-handling for Enter (and on every text commit, only at the prompt when the whole line starts with `:`). If `trimmed` starts with `':'`, dispatch:

| Command | Action |
|---|---|
| `:help` | append the keybinding list (below) as `.line` rows to the scrollback above the band; do NOT eval; do not add to history |
| `:quit`, `:q` | set a `quit = true` flag; break the main loop (same path as Ctrl+D / `q`-on-empty) |
| `:clear` | clear `line` and `cursor` only (a no-op equivalent to Ctrl+C) — cheap, consistent |
| anything else | evaluate it normally (e.g. `:` is a keyword; `:foo` is a valid keyword literal — do NOT shadow legitimate keyword input) |

Dispatch rule: a command is recognized ONLY when `trimmed.len >= 2`, `trimmed[0] == ':'`, and `trimmed` matches a known command EXACTLY; otherwise it evaluates normally. This avoids breaking keyword literals. Only known commands are special-cased. `:help` content (one row per line, append as `.line`):

```
skript repl keys: Enter eval · Enter(unbalanced) continue line
·/↓ history · ^C clear line · ^D/q/:quit quit · Left/Right move
· Alt+Left/Right word · Home/End or ^A/^E line ends · ^K kill→end
· ^U kill→start · ^W delete word · Del delete fwd · Backspace del
```

---

## 6. G5 — answer guard (truncate very long answers)

Two caps, both cheap:
- **Byte cap** in the worker, right after `formatAnswer` — truncate the published `answer` to `max_answer_bytes = 16 * 1024` with a trailing `"\n… (truncated)"` marker (reuse the `ownLibOut` truncation idiom):
  ```zig
  const max_answer_bytes: usize = 16 * 1024;
  if (answer.len > max_answer_bytes) {
      answer = std.fmt.allocPrint(aa, "{s}… (truncated)", .{answer[0..max_answer_bytes]}) catch answer[0..max_answer_bytes];
  }
  ```
- **Line cap** in `appendEntry`, while iterating answer lines: stop after `max_answer_lines = 200` rows and append one muted marker row `"… (truncated: N lines)"`. Implement as a counter in the existing answer-line loop; when the counter reaches the cap, append the marker (muted via `lib_style`/`pushStyle`) and `break`.

Rationale: a huge pretty tensor (or a wide `(begin …)` returning a giant structure) would otherwise balloon the scrollback and drag the region anchor accounting. The caps make one noisy answer bounded.

---

## 7. G6 — elapsed-time report

Small, optional-but-cheap: report how long an eval took on the status band after completion.

- In the main loop, record `var eval_start: ?std.Io.Timestamp = null;` set in `submit` (after spawning the worker) — or simpler, capture `now` at the top of `pollSlot` when a fresh result is consumed.
- `pollSlot`: when it joins a worker with a fresh result, compute `const elapsed = std.Io.Timestamp.now(io, .awake).nanoseconds - eval_start_ns;` and store `last_eval_ms: ?u64` (div by `std.time.ns_per_ms`).
- `drawBand`: in the idle branch (not busy), if `last_eval_ms` is set, draw `"done in {d}ms"` in place of the idle hint until the next input key clears it (reset `last_eval_ms = null` on any editing key). Example row-1 content: `evaluating⠋` (busy) / `done in 3ms` (just completed) / default `idle_status` hint (otherwise).
- This is the one feedback mechanism the v1 lacks beyond the spinner, and directly supports the §9 timing comparison. Keep it to one status-band string — do not add a right-side stats panel (that's OUT, §8).

---

## 8. OUT — explicitly not in this round

| Item | One-line reason |
|---|---|
| Tab completion (G-surf e) | skript's symbol scan IS cheap (`completionCandidates`, repl.zig:469-489, iterates `root_ns` bindings + `builtin_keywords`), but a floating completion popup (skript uses `zz.overlayAt`, repl.zig:848-860) and a main-thread namespace read racing the eval worker outweigh the value for a focused round. **Recipe is documented above; revisit in a later round** (run it only while `worker == null`). |
| Undo / kill-ring / Ctrl+Y | zigzag `TextInput` has no undo and no yank — porting one means inventing a history stack the reference implementation doesn't have. Out. |
| Boxed per-query history (`Query.render` boxes) | v1's plain `.line` scrollback was already accepted in embed-contract §9 Q3; boxing is heavier to chunk. Out. |
| Live tree-sitter input highlighting | notui doesn't wire the tree-sitter engine (embed-contract §7); the hand-rolled scanner stays. Out. |
| Right-pane runtime stats / fibers panel (`storeStats`, `fibersPanel`) | heavy, full-pane UI beyond a 2-row band; not part of this REPL's layout. Out. |
| Ctrl+C → quit | skript's own repl quits on Ctrl+C (`classifyKey` repl.zig:598) but the embed contract §8 mandates Ctrl+C clears the line and never hard-quits. **Keep v1 behavior** (clear line). |
| Multi-line band growth (preview all pending lines) | keeps the 2-row `Region` fixed; only the active line renders (see open question Q3). |

---

## 9. Test / verification plan

Build/wiring: unchanged from the embed contract (§1.2, §1.3) — `link_libc = true`, `use_llvm = true`, fake `emcc` on PATH for the gate. `initRegvm` does not change the build wiring.

### 9.1 Timing comparison — old vs new eval path (the G3 acceptance gate)
1. **Scripted, reproducible:** run skript's own bench for the factual engine claim — `cd ~/projects/skript && ./zig-out/bin/skript-bench` and confirm regvm ≤ stack on the fib program (`(defn fib …) (fib 10)`: measured 1070us reg vs 10968us stack). This pins the ~10× claim; the REPL inherits it.
2. **In-REPL perception:** in a PTY, submit `(defn (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))` then `(fib 25)`. Assert: the spinner appears, the status band reports a small `done in …ms`, and the answer `242785 (i64)` returns. Confirm the worker-thread + `Runtime.initRegvm` combination keeps the UI responsive (spinner animates while the runner computes — it must not freeze).
3. **Stack-VM OOM regression is gone:** submit `(fib 20)` — v1's stack VM runs out of the fixed store heap beyond ~fib(17) (Runtime.zig:8566); the regvm path must return the value, not an OOM/eval error.

### 9.2 PTY scenarios (drive via the harness `hub send` keys/text)
- **Editing (G1):** type `(defn f` then: `Left`×3 → cursor back 3 codepoints; `Right` → forward; `Ctrl+A` then `Ctrl+E` → line ends; `Alt+Right` → word jump; `Ctrl+U` → clears to start; retype `(defn f ` + `Ctrl+K` → kills to end; `Ctrl+W` → deletes the word; `Backspace` deletes a codepoint; `Delete` forward deletes a codepoint; insert mid-line by `Left` to the middle then typing. Assert the visible cursor cell (reverse-video block) tracks each move and the band re-renders.
- **Multi-line (G2):** type `(defn (add1 x` then Enter → the band switches to the continuation prompt and does NOT submit; type `) (+ x 1))` then Enter → submits the whole buffer; history Up recalls the multi-line entry; answer `…` (a closure / defn returns). Then a balanced `(+ 1 2)` still submits on one Enter. Then an overclosed `)` submits and yields `Parser error: UnexpectedToken` (negative-depth path, §4.1).
- **Meta (G4):** `:help` appends the key rows; `:quit` and `:q` each exit; `:foo` evaluates as a keyword literal (not a command).
- **Answer guard (G5):** eval a big tensor or a form returning a very long value and assert the truncation marker and the `… (truncated: N lines)` row appear, and that scrollback stays bounded.
- **Error phases (regvm, §2.5):** unbalanced/`(` → `Parser error`; `(nope)` → `Eval error`; a regvm-non-compilable construct → still evaluates via the fallback (no spurious error).
- **Persistence (§2.6):** `(defn (add1 x) (+ x 1))` then `(add1 5.0)` → `6.0` (proves root_ns binding across separate `spawnEval` calls on the regvm path).
- **fd-capture unchanged:** a form that `(print …)` still renders its captured output muted under the answer, and the TUI is not glitched.
- **History/quit (regression):** Up/Down history, Ctrl+C clears, Ctrl+D quits, `q`-on-empty quits.
- **Non-TTY:** piped stdin → one plain hint line, exit 0 (v1 `runPlain` unchanged).
- **Gate:** `zig build` and the house example gate pass with `PATH=/tmp/notui-fakebin:$PATH`.

---

## 10. Open questions for the orchestrator (max 3)

1. **Ctrl+C semantics.** The embed contract §8 mandates Ctrl+C clears the line (never hard-quit), which v1 follows; skript's own REPL quits on Ctrl+C (`repl.zig:598`). I default to **keep clear-line**. Confirm or override.
2. **Elapsed-time report (§7) placement.** I propose a status-band `done in {d}ms` suffix that reverts on the next keypress. Confirm it's wanted at all, and accept the status-band placement (vs a muted suffix on the answer row, which changes scrollback).
3. **Multi-line rendering (§4.3).** Keep the fixed 2-row band that renders only the ACTIVE continuation line (my default), or let the input band grow to preview all pending lines (heavier — needs dynamic region resize and cursor row mapping)? Default: fixed 2-row.
