# REPL inline suggestions — round-1 parallel contract (C2)

**Author:** subagent C2ReplCompletion
**Pair:** C1SuggestionUi owns the TUI popup side (`suggestion-ui-contract.md`). This file is the REPL side — the implementer builds the feature from THIS + C1's popup contract + notui `src/` + `skript-embed-contract.md` + `skript-repl-improvements.md` only. **The implementer does NOT re-read skript.**

> ⚠️ **Cross-contract coupling (read first).** When this file was written, `notes/research/suggestion-ui-contract.md` did not yet exist (C1 writes it in parallel). This contract therefore assumes C1's popup surface:
> - a component `component.Suggestions` with `fn draw(buf, x, y, now) !u16` returning columns consumed, a `selected: usize` field, and `candidates: []const []const u8`;
> - the `Region` gains `pub fn setHeight(self: *Region, new_height: u16) !void` (a `resize(self.width, new_height)` wrapper, per `region.zig:155-162`).
> **If C1's contract differs, C1's contract wins for the popup/Region surface; this file's sections 3-4 specify only how the REPL calls them.** Reconcile names before implementing.

**Versions ground-truth:** skript `0.0.0`; notui `0.0.0`; zig 0.16.0. All skript/notui claims below cite file:line.

---

## 0. Feature summary

While the user types a symbol at the prompt and the eval worker is idle (`worker == null`), a candidate list appears BELOW the input line. `↑`/`↓` navigate the selection, `Tab` accepts the highlighted candidate (replacing the in-progress token and moving the cursor past it), `Esc` dismisses without accepting, and typing/`Enter`/backspace that empties the token refreshes or dismisses the popup. The region band grows from 2 rows to `2 + shown_rows` while the popup is open. Completion reads the runtime's root namespace — **main thread only, never while an eval is in flight.**

---

## 1. Candidate source

### 1.1 The completion function

Port skript's `completionCandidates` verbatim (skript `src/repl.zig:468-489`). The REPL-side wrapper:

```zig
/// Completion candidates: every binding in root_ns whose name starts with
/// `prefix` (case-sensitive) plus the builtin special forms, sorted for a
/// stable Tab order. The returned LIST is allocated from `alloc`; the
/// candidate STRING contents are borrowed (interned store symbols + the
/// static builtin_keywords array) and stay valid for the runtime's life.
/// MAIN THREAD ONLY: the caller MUST hold worker == null (§1.4).
fn candidates(rt: *skript.Runtime, alloc: std.mem.Allocator, prefix: []const u8) []const []const u8 {
    const ns_ptr = rt.root_ns.obj.toRef().deref(skript.Namespace);   // Runtime.zig:51 root_ns: Value
    const root_map: *skript.HashMapNamespace = @ptrCast(@alignCast(ns_ptr.data));
    var out: std.ArrayList([]const u8) = .empty;
    var it = root_map.bindings.iterator();                            // data.zig:296-299 HashMapNamespace.bindings
    while (it.next()) |kv| {
        const name: []const u8 = kv.key_ptr.*.*;
        if (std.mem.startsWith(u8, name, prefix)) out.append(alloc, name) catch break;
    }
    for (builtin_keywords) |kw| {
        if (std.mem.startsWith(u8, kw, prefix)) out.append(alloc, kw) catch break;
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
```

### 1.2 Ownership / allocator

- **The outer `[]const []const u8` list is allocated** from the allocator argument. The candidate **string contents are NOT allocated** — they are pointers into the store's interned symbol pool (the `Sym` double-deref at `repl.zig:477`) and the static `builtin_keywords` array.
- In this REPL, pass the app arena `aa` (the same allocator backing `line`, history, scrollback — `skript_repl.zig` `var aa = arena.allocator()`). The arena lives for the whole session, so **no per-frame free is needed** and the returned slices stay valid until exit. This matches the existing "never freed until exit" pattern (`skript_repl.zig` doc comment at the `var arena` block). Do NOT introduce a second arena or a per-key free.
- Recompute-and-replace each keystroke (below) leaks the prior list into the arena; that is accepted and consistent with the file's existing arena-append style. If a tight bound is ever wanted, allocate from a small transient arena, but that is NOT required for this round.

### 1.3 builtin_keywords source: replicate, do NOT import

`builtin_keywords` is a **private** `const` in skript (`repl.zig:461-463`), not exported, so it MUST be replicated as a local const in the REPL:

```zig
/// Special forms handled by the reader/compiler (NOT bound in root_ns) —
/// skript repl.zig:461-463 keeps an identical private list; `else`/`and`/
/// `or`/`not`/`nil`/`instance`/`method` are prelude bindings and come from
/// the namespace iteration.
const builtin_keywords = [_][]const u8{
    "begin", "case", "def", "defn", "fn", "if", "lambda", "let", "quote", "set!",
};
```

This list is byte-for-byte identical to the REPL's existing `special_forms` (`skript_repl.zig` const block near the top). Reuse/alias that existing const (rename or `const builtin_keywords = special_forms;`) rather than duplicating ten strings twice — the implementer's choice, but there must be exactly ONE list in the file.

### 1.4 Reachability + threading rule

- `skript.Namespace` and `skript.HashMapNamespace` are exported at the package root (`root.zig:75-76`). `rt.root_ns` is a public `Value` field (`Runtime.zig:51`). The REPL already holds `*skript.Runtime` (`skript_repl.zig` `var rt`), so the whole access path (`root_ns.obj.toRef().deref(Namespace)` → `ns_ptr.data` cast → `.bindings.iterator()`) is reachable from the embedding with zero new skript API. The identical deref pattern is already used in skript's own runtime (`Runtime.zig:235-237`) and its REPL (`repl.zig:470-475`).
- **Threading (hard rule):** per the embed contract §5 the runtime is single-owner — the eval **worker** owns it during each eval; the main thread touches only the result slot (`skript_repl.zig` `var slot`/`worker`, embed-contract §5.1 "No overlap … the Runtime is single-owner"). Completion iterates `root_ns` bindings, so it MUST run on the **main thread only, and only while `worker == null`** (no eval in flight). The improvement contract §8 states the deferred recipe's condition: "run it only while `worker == null`". Guard the call site with an assert:
  ```zig
  // in the key-dispatch path, before recomputing candidates:
  std.debug.assert(worker == null);   // completion reads root_ns; never during an eval
  ```
  The worker never recomputes candidates, so there is never concurrent `root_ns` access.

---

## 2. Current-token detection

The "token being typed" is the symbol prefix at the cursor: scan the buffered line backwards from `cursor` to the last token delimiter.

### 2.1 Delimiter set (exact)

```zig
/// A completion token terminator: whitespace, the reader grouping
/// punctuation, a colon, or a quote. A symbol never spans one of these,
/// so scanning back to the last one yields the prefix being typed.
fn isCompletionDelim(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or switch (c) {
        '(', ')', '[', ']', '{', '}', ':', '"', '\'' => true,
        else => false,
    };
}
```

(Equivalent and acceptable: `std.ascii.isWhitespace(c) or c == ':'` on top of the existing `isDelim` helper `skript_repl.zig` — `isDelim` already covers `()[]{}` and the quotes. Whichever, the effective terminator set MUST contain at least the required space/tab/`()` /`[]`/`{}`/`:`/quote. `:` is deliberately a terminator so a `:keyword` literal never completes against symbol names.)

### 2.2 The prefix rule

```zig
/// The in-progress symbol prefix at `cursor`. Empty when the cursor is at
/// a token boundary or the token can't be a symbol (number / string), in
/// which case NO popup should show.
fn tokenAtCursor(line: []const u8, cursor: usize) []const u8 {
    var start = cursor;
    while (start > 0 and !isCompletionDelim(line[start - 1])) start -= 1;
    const tok = line[start..cursor];
    if (tok.len == 0) return "";
    if (isDigit(tok[0])) return "";        // number literal → no symbol completion
    return tok;
}
```

- Scan `line.items[0..cursor]` backward from `cursor` (byte index, the existing cursor model — `skript_repl.zig` `var cursor: usize`), stopping at the first byte satisfying `isCompletionDelim`. The prefix is `[start..cursor]`. No forward scan is needed — the cursor sits at the end of the in-progress token by construction (every editing action that inserts at the cursor moves it forward; see §3).
- **Multi-line safety:** `\n` is a delimiter, so a token never spans a continuation line. For consistency with `drawBand`'s active-line slicing this is equivalent to scanning `active[0..cur]`; use `line.items[0..cursor]` directly since the `\n` terminator already handles the split.

### 2.3 Edge cases (exact)

| Condition | Result |
|---|---|
| prefix empty (`tok.len == 0`) — cursor at space, after an opener, after `:`, at line start | **no popup** |
| prefix starts with a digit (`isDigit`) — number literal like `1.5`, `42` | **no popup** |
| prefix starts with a quote — impossible by construction (`"`/`'` are delimiters, scan stops before them) | n/a |
| prefix matches ≥1 binding/special form | popup shows the sorted matches |
| prefix matches nothing | **no popup** (`candidates.len == 0` → dismiss) |

---

## 3. Trigger + lifecycle + keymap

### 3.1 State

Add one piece of state to the main loop:

```zig
/// Open-suggestion popup state. candidates is arena-owned (§1.2), replaced
/// wholesale on every recompute. shown == candidates.len once open.
var sugg: ?notui.component.Suggestions = null;   // .candidates, .selected
```

`selected` starts at `0` each time the popup opens. `sugg` is `null` when dismissed.

### 3.2 When to recompute (the trigger)

Every **idle** key press — that is, every `key_press` event handled while `worker == null` — runs the following AFTER the key has mutated `line`/`cursor` (text insert, backspace, delete, arrow, history load, kill, etc.), i.e. at the tail of the `.key_press` arm:

```zig
// Recompute the popup for the post-key token (idle only).
if (worker == null) {
    const prefix = tokenAtCursor(line.items, cursor);
    const cands = if (prefix.len == 0) "" else candidates(rt, aa, prefix);
    if (cands.len == 0) {
        // Dismiss.
        if (sugg != null) { sugg = null; try setBandHeight(region, base_height); }
    } else {
        const s = if (sugg) |s0| s0 else .{ .candidates = cands, .selected = 0 };
        s.candidates = cands;
        if (s.selected >= cands.len) s.selected = 0;      // guard after a recompute shrank the list
        sugg = s;
        try setBandHeight(region, base_height + @min(cands.len, max_rows));  // §4
    }
}
```

- The recompute runs on **every idle keypress**, including navigation/control keys — so the popup always tracks the token under the cursor even after `Left`/`Right`/backspace move it. Cheap: one `root_ns` bindings iteration, done only when idle.
- **While `worker != null`** (eval in flight) the recompute is skipped entirely; if the popup was open when Enter fired, Enter dismisses it (§3.4). Never read `root_ns` during an eval.

### 3.3 Keymap and dispatch position

The popup keys slot into the existing `.key_press` switch **BEFORE the generic text-insert fallback** (`insertKeyText`) and, for `↑`/`↓`, **before the history `Key.up`/`Key.down` arms** (so an open popup navigates candidates, not history). Exact placement:

| Key | Popup state | Action |
|---|---|---|
| `Key.up` | popup open | `sugg.selected = (sugg.selected + cands.len - 1) % cands.len` (wrap up) — **do NOT touch history** |
| `Key.up` | popup closed | existing history arm (unchanged) |
| `Key.down` | popup open | `sugg.selected = (sugg.selected + 1) % cands.len` (wrap down) — **do NOT touch history** |
| `Key.down` | popup closed | existing history arm (unchanged) |
| `Key.tab` | popup open | **accept**: replace the current token with the candidate, move cursor to its end, dismiss (§3.4); **do not fall through to text insert** |
| `Key.tab` | popup closed | falls through to text insert (`insertKeyText` inserts `\t`) — unchanged behavior |
| `Key.escape` | popup open | dismiss without accepting (§3.4); do NOT clear the line |
| `Key.escape` | popup closed | existing ignore arm (unchanged) |
| `Key.enter` | popup open | dismiss, then normal Enter handling (§3.4) |
| any text/backspace/delete/nav key | popup open | mutate line as usual, then the §3.2 recompute (refresh or dismisses) |

**Dispatch order** (must precede history + insert):
```zig
} else if (sugg != null and k.matches(Key.tab, .{})) {
    try acceptSuggestion(aa, &line, &cursor, sugg.?, rt, &region);   // §3.4, then dismiss
} else if (sugg != null and k.matches(Key.escape, .{})) {
    sugg = null; try setBandHeight(region, base_height);             // dismiss
} else if (sugg != null and k.matches(Key.up, .{})) {
    sugg.?.selected = (sugg.?.selected + sugg.?.candidates.len - 1) % sugg.?.candidates.len;
} else if (sugg != null and k.matches(Key.down, .{})) {
    sugg.?.selected = (sugg.?.selected + 1) % sugg.?.candidates.len;
} else if (sugg != null and k.matches(Key.enter, .{})) {
    sugg = null; try setBandHeight(region, base_height);             // dismiss, then Enter → §3.4
    // fall through to the existing handleEnter path
} else if (isCtrlC(k)) { … existing … } else if (… existing movement/keymap …) {
} else { try insertKeyText(aa, &line, &cursor, k); }
```
`Tab`/`Esc`/`Enter` are new arms and must come before the generic fallback; `Up`/`Down` must come before their history arms (both already `return`/`else-if` without fallthrough). `Esc` currently has an explicit ignore arm (`skript_repl.zig` `k.matches(Key.escape, .{})` → "Ignore.") — insert the popup Esc arm before it.

### 3.4 Accept / dismiss transitions

**Accept (Tab):**
```zig
/// Replace the current token with the highlighted candidate and move the
/// cursor to its end, then dismiss the popup.
fn acceptSuggestion(
    aa: std.mem.Allocator,
    line: *std.ArrayList(u8),
    cursor: *usize,
    s: notui.component.Suggestions,
    region: *Region,
) !void {
    const cand = s.candidates[s.selected];
    // Re-derive the token range exactly as tokenAtCursor (§2.2).
    var start = cursor.*;
    while (start > 0 and !isCompletionDelim(line.items[start - 1])) start -= 1;
    line.items.len = start;                                   // drop the partial token
    try line.insertSlice(aa, start, cand);                    // splice in the candidate
    cursor.* = start + cand.len;                              // cursor past the accepted symbol
    // (dismiss handled by the caller: sugg = null + setBandHeight)
}
```

**Dismiss (Esc / Enter / empty-prefix recompute / typing that no longer matches):** `sugg = null; try setBandHeight(region, base_height);`. On Enter the dismissal happens before the existing `handleEnter` path runs (which submits or continues multi-line). On accept the same. Esc leaves `line` untouched.

**Re-render:** after any accept/dismiss, the next `drawBand`/`region.render` tick paints the shrunk band (§4). No explicit `renderFull` is required — `setHeight` sets `width_dirty` (region.zig strategy-2 full redraw) so the shrink clears the rows the popup used.

---

## 4. Band integration

The REPL's `Region` is created with a fixed height 2 (`skript_repl.zig` `var region = try Region.init(gpa, .{ .height = 2 })`). With the popup open the band must grow. Use C1's `Region.setHeight` (assumed wrapper over `resize(self.width, h)` → region.zig:155-162, which sets `width_dirty` and triggers a full repaint of exactly `h` rows).

### 4.1 Heights

```zig
const base_height: u16 = 2;            // input row + status row (today's layout)
const max_rows: u16 = 8;               // cap the popup so a 2-row band doesn't balloon past the screen
```
- Popup open with `N` candidates: **region height = `base_height + min(N, max_rows)`** — row 0 = input, rows 1..=min(N,max_rows) = candidate rows, row `1+min(N,max_rows)` = status row.
- `shown_rows = min(N, max_rows)`; the `Suggestions` component renders the first `max_rows` candidates (selection scrolls within the window — C1's responsibility).

### 4.2 setHeight calls (the only places the band height changes)

1. **Show / refresh while open:** after the §3.2 recompute produces a non-empty list, `try region.setHeight(base_height + @min(cands.len, max_rows));` (already in §3.2; if `max_rows` is already met it's a no-op resize, safe).
2. **Dismiss (Esc / Enter / accept / empty recompute):** `try region.setHeight(base_height);` (restores the 2-row band).
3. The existing winsize resize path keeps `region.height` as-is (`try region.resize(wsz.cols, region.height)` — `skript_repl.zig` twice) — it must keep the CURRENT height (which may be >2 when the popup is open), not a hardcoded 2. **No change needed; verify the existing calls pass `region.height`.**

### 4.3 drawBand changes

`drawBand` (`skript_repl.zig` `fn drawBand`) currently paints row 0 (prompt + cursor-split line) and row 1 (status). With the popup open:

```zig
// After the existing row-0 input render and BEFORE the status row:
var y: u16 = 1;
if (sugg) |s| {
    // Popup rows aligned under the cursor column.
    _ = try s.draw(&region.cur, prompt_x + cursor_col, y, now);   // C1 component: rows 1..shown_rows
    y += @intCast(@min(s.candidates.len, max_rows));
}
// Status row moves DOWN to `y` (was row 1; now N+1 when the popup is open).
if (busy) {
    _ = try spinner.draw(&region.cur, 0, y, now);
} else if (last_eval_ms) |ms| { … draw "done in {d}ms" at (0, y) … }
else { _ = try region.cur.draw(.{}, if (multiline) cont_status else idle_status, 0, y); }
```

- **Popup x:** align under the cursor's display column. `drawBand` already computes `x` after the prompt + left-of-cursor segments; capture that column (`prompt_x` offset plus the width of `active[0..cur]`) and pass it as the popup's `x` so the list sits under the typed symbol.
- **Popup y:** row 1 (the first candidate), i.e. directly below the input line — matching the feature's "below the input line" requirement.
- **Status row:** moves from row 1 to row `1 + shown_rows` (the band bottom). The `Suggestions.draw` consumes rows `1..=shown_rows`; the status draw uses `y = 1 + shown_rows`.
- The popup render must NOT disturb the row-0 input or the scrollback. `region.cur.clear()` at the top of `drawBand` already resets the buffer each frame; `Suggestions.draw` writes into `region.cur` like the existing draws.

### 4.4 Popup width

Candidates are plain symbol/keyword names (short). Let the `Suggestions` component size its own width from the widest candidate (C1's contract) or cap at `region.width`; the REPL only supplies the candidate slices and the anchor `(x, y)`.

---

## 5. Test / verification plan

Drive via the harness PTY (`hub send` keys/text) exactly as the improvement contract §9.2 does. All assertions are visual on the band + region rows.

1. **Popup appears for a symbol prefix.** Type `(defn (add1 x) (+ x 1))` + Enter (so `add1` is bound in root_ns), then type `(add ` — assert a sorted candidate list appears BELOW the input line containing `add1` (and any prelude symbol starting `add`), rows 1.. shown.
2. **Tab accepts.** With the popup open, press Tab — assert the line becomes `(add1 ` (the partial `add` replaced, cursor moved to the end of `add1`), the popup is dismissed, the band is back to 2 rows, and the status hint returns to row 1.
3. **↑/↓ navigate.** Open the popup with ≥2 candidates (e.g. type `def` → `def`, `defn`). Press ↓ then Tab — assert the SECOND candidate was inserted; reopen, press ↑ from the top (wraps) then Tab — the last candidate inserted. Also assert that while the popup is open, ↓/↑ do NOT walk history (the line is unchanged by navigation alone).
4. **Esc dismisses without accepting.** Open a popup, press Esc — assert the line is unchanged (`add` still there), popup gone, band back to 2 rows.
5. **Dismiss on Enter / typing.** Open a popup, press Enter — popup gone and the line submits (or continues multi-line per paren balance); the popup must not interfere. Open again and type a char that kills the match (e.g. after `add` type `x` → no candidate starts `addx`) — popup dismisses. Type backspace to empty the token — popup dismisses.
6. **Backspace updates the token.** With `add1` visible under `add`, backspace once (token `ad`) — popup refreshes to `ad…` matches (or dismisses if none); the band height re-settles.
7. **No popup for numbers / delimiters.** Type `4` then `4.` then `(` — assert NO popup (empty/number token). Type `:foo` — NO popup (`:` is a delimiter).
8. **No popup while eval in flight.** Submit a slow eval (e.g. `(fib 25)`); while the spinner is busy (worker != null), type `add` — assert NO popup appears (recompute skipped), and no crash/corruption. After it completes, typing `add` again shows the popup.
9. **Piped path unaffected.** Pipe stdin (non-TTY) → one plain hint line, exit 0 (`runPlain`); no popup code runs.
10. **Gate:** `zig build` and the house example gate pass (same wiring as improvement-contract §9).
11. **Multi-line.** During a continuation (unbalanced paren, `cont_prompt` active), type a symbol → popup shows under the ACTIVE line and accepts into the active line; the embedded `\n` never joins two tokens.

---

## 6. Open questions for the orchestrator (max 3)

1. **Popup max_rows.** I propose capping the popup at `max_rows = 8` rows so a 2-row band grows to at most 10 and never balloons past a short terminal; with more matches the window scrolls (C1). Confirm the cap, or should the popup grow unbounded to `min(N, terminal_height - 2)`?
2. **`builtin_keywords` reuse.** The list is byte-identical to the REPL's existing `special_forms`. I default to ONE const (alias). Confirm that renaming the existing const / aliasing is acceptable to the reviewer (avoids a two-list drift risk).
3. **Recompute on every idle keypress vs. only text keys.** I recompute after EVERY idle key (including Left/Right/backspace) so the popup tracks the cursor. This re-iterates `root_ns` on navigation too. Acceptable (cheap, idle-only), or restrict recompute to keys that actually change the token?
