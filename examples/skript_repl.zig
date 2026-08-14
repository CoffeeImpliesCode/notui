//! Skript REPL: a non-blocking Lisp REPL on notui (skript embed contract).
//!
//! Layout: a 2-row Region. Row 0 is the input band (continuation prompt
//! for multi-line forms, otherwise the main prompt + live
//! keyword-highlighted typing with a reverse-video cursor block); row 1
//! is the status band (base-ui Spinner while an eval runs, "done in
//! {d}ms" after a completed eval, a keybinding hint otherwise). While the
//! user types a symbol and the eval worker is idle, a sorted candidate
//! popup (base-ui Suggestions) appears below the input aligned under the
//! cursor column: the band grows to `base_height + shown` rows and the
//! status band moves down. Tab accepts the highlighted candidate, ↑/↓
//! navigate (not history), Esc dismisses. Completed
//! submissions append above the band as plain `.line` scrollback rows:
//! the query (keyword-styled), the `⇒ answer (Type)` line, and muted
//! captured library output (capped at 5 lines + "N more captured").
//! Answers are guarded: 16 KiB byte cap + 200-row line cap (§6).
//!
//! The skript runtime (`Runtime.init`, register VM) is initialized once and
//! used by exactly ONE thread at a time: each submission copies the query
//! into the app arena and spawns a worker `std.Thread` that compiles +
//! evals + formats the answer entirely off the UI thread, capturing the
//! form's fd 1/2 writes into a pipe (libc extern block — the example
//! links libc). The worker evaluates via `spawnEval` + `awaitProcess`
//! (the scheduler's own runner thread executes the bytecode). The worker
//! publishes into a result slot; the main loop polls
//! the slot each tick and keeps rendering (the spinner animates while
//! busy). Enter is ignored while a submission is in flight; paren-aware
//! Enter continues multi-line input; Up/Down navigate a 100-entry history
//! ring; `:help`/`:quit`/`:q`/`:clear` are exact-match meta commands;
//! Ctrl+C clears the line; Ctrl+D quits (q quits only on an empty line).
//! Quitting mid-eval joins the worker first — skript's cooperative
//! scheduler drains, then the runtime deinits.
//!
//! Non-TTY stdin degrades to one plain hint line, exit 0 (no tty
//! interaction, no interactive sequences).

const std = @import("std");
const notui = @import("notui");
const skript = @import("skript");

/// Restore the terminal on panic: defers never run for a panicking
/// process, and a raw/hidden-cursor terminal is what forces a hard reset.
pub const panic = std.debug.FullPanic(struct {
    pub fn call(msg: []const u8, ra: ?usize) noreturn {
        notui.tty.restoreTerminal();
        std.debug.defaultPanic(msg, ra);
    }
}.call);

/// Skript's own REPL silences its debug traces (main.zig sets .warn); the
/// example follows suit so prelude-init logs don't pollute the terminal
/// before the first frame (they would otherwise also be fd-captured and
/// shown muted under every answer).
pub const std_options: std.Options = .{ .log_level = .warn };

const Tty = notui.tty.Tty;
const Region = notui.region.Region;
const Key = notui.key;
const Reader = notui.input.Reader;
const Style = notui.style.Style;

/// The prompt prefix drawn in the input band.
const prompt_text = "skript> ";

/// The answer prefix: a wide arrow, so continuation indents are measured
/// by display width (not byte length).
const answer_prefix = " ⇒ ";

/// Status-band hint shown while idle.
const idle_status = "Enter: eval · ↑/↓: history · ^C: clear (quit while eval) · ^D/q: quit";

/// Continuation prompt (row 0) when the pending buffer spans lines (§4.3).
const cont_prompt = "    · ";

/// Status-band hint shown while a multi-line form is mid-continuation.
const cont_status = "multiline: Enter to continue";

/// Band geometry for the inline-suggestion popup (§4): the band is 2 rows
/// (input + status) and grows to `base_height + shown` while the popup is
/// open, capped at `max_rows` candidate rows (an 8-row popup keeps a
/// 2-row band at 10 rows, never ballooning past a short terminal).
const base_height: u16 = 2;
const max_rows: u16 = 8;

/// Answer guard caps (§6): a huge pretty answer is truncated at 16 KiB
/// (worker side) and at 200 scrollback rows (append side).
const max_answer_bytes: usize = 16 * 1024;
const max_answer_lines: usize = 200;

/// `:help` content: one scrollback `.line` row per binding group (§5).
const help_rows = [_][]const u8{
    "skript repl keys: Enter eval · Enter(unbalanced) continue line",
    "·/↓ history · ^C clear (quit while eval) · ^D/q/:quit quit · Left/Right move",
    "· Alt+Left/Right word · Home/End or ^A/^E line ends · ^K kill→end",
    "· ^U kill→start · ^W delete word · Del delete fwd · Backspace del",
};

/// One plain line printed when stdin is not a terminal (runPlain).
const hint_plain = "skript repl (notui example): interactive terminal required";

/// Ctrl+D, the app's quit key (Key defines only ctrl_c among the ASCII
/// control chars).
const ctrl_d: u21 = 0x04;

/// Loop pacing: nextTimeout returns null on timeout, advancing one tick.
const tick_ms: i32 = 100;

/// History ring bound (contract §8).
const history_cap: usize = 100;

/// SGR reset, appended after styled scrollback rows.
const reset_sgr = "\x1b[0m";

// ── highlight palette (contract §7: Capture vocabulary) ──────────────
// string / number / comment / keyword literal / special form / constant;
// symbols, operators, punctuation and plain text render unstyled.
const string_style: Style = .{ .fg = .{ .ansi = .green } };
const number_style: Style = .{ .fg = .{ .ansi = .yellow } };
const comment_style: Style = .{ .fg = .{ .ansi = .bright_black } };
const keyword_style: Style = .{ .fg = .{ .ansi = .cyan } };
const special_style: Style = .{ .fg = .{ .ansi = .blue } };
const constant_style: Style = .{ .fg = .{ .ansi = .magenta } };
/// Muted library output (fd-capture preview).
const lib_style: Style = .{ .fg = .{ .ansi = .bright_black } };

/// Compiler special forms (the prelude binds the rest).
const special_forms = [_][]const u8{
    "begin",  "case", "def",   "defn", "fn", "if",
    "lambda", "let",  "quote", "set!",
};

/// Completion keywords: an alias of `special_forms` (the reader/compiler
/// special forms are NOT bound in root_ns — skript repl.zig:461-463 keeps
/// the identical private list; `else`/`and`/`or`/`not`/`nil`/`instance`/
/// `method` are prelude bindings and come from the namespace iteration).
/// One list only, to avoid drift.
const builtin_keywords = special_forms;

/// extern "c" fd plumbing for OutputCapture (skript contract §6 — this is
/// why the example links libc). Verbatim from skript's repl.zig.
const libc = struct {
    extern "c" fn pipe(fds: *[2]std.posix.fd_t) c_int;
    extern "c" fn dup(fd: std.posix.fd_t) c_int;
    extern "c" fn dup2(old_fd: std.posix.fd_t, new_fd: std.posix.fd_t) c_int;
    extern "c" fn close(fd: std.posix.fd_t) c_int;
    extern "c" fn read(fd: std.posix.fd_t, buf: [*]u8, n: usize) isize;
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // Non-TTY degradation: skip the tty entirely (Tty.init opens /dev/tty,
    // which is wrong and can fail without a controlling terminal) and
    // print one plain hint line.
    if (!Tty.isTty(std.posix.STDIN_FILENO)) {
        return runPlain(io);
    }

    var tty = try Tty.init(io);
    defer tty.deinit();
    try tty.makeRaw();
    defer tty.restore();

    var parser: notui.parser = .{};
    const caps = try notui.caps.Capabilities.detect(gpa, &tty, &parser);

    var region = try Region.init(gpa, .{ .height = 2 });
    defer region.deinit();

    const ws = try tty.getWinsize();
    try region.resize(ws.cols, region.height);

    // App arena: the typed line, worker results, history entries and the
    // styled scrollback rows all live here for the whole session. Arena
    // memory is never freed until exit, so slices published by the worker
    // stay valid until the main thread has appended them.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    // The skript runtime: init once (prelude + builtins + store), then
    // single-thread-at-a-time — the worker owns it during each eval, the
    // main thread only polls the result slot. deinit() drains the runtime's
    // scheduler runners, so the worker is joined first (below).
    var rt = try skript.Runtime.init(gpa, io);
    defer rt.deinit();

    // `display`/`write` route through `rt.stdout`. skript's hosts must set
    // it: `Runtime.init` heap-creates the Runtime and does NOT zero the
    // struct, so the `= null` default is debug-fill (0xaa) garbage in
    // Debug builds — the null check would pass and dereference it. Mirror
    // skript's repl.zig: an UNBUFFERED writer on fd 1, so a form's output
    // lands in the worker's capture pipe while it evaluates (and on the
    // real stdout otherwise). The writer outlives every worker (joined
    // before rt.deinit) and the runtime.
    var stdout_file_writer = std.Io.File.stdout().writer(io, &.{});
    rt.stdout = &stdout_file_writer.interface;

    var line: std.ArrayList(u8) = .empty;
    var cursor: usize = 0; // byte index into line.items (§3.1)
    var history: History = .{};
    var slot: ResultSlot = .{};
    var worker: ?std.Thread = null;
    var spinner: notui.component.Spinner = .{ .label = "evaluating" };
    // Open inline-suggestion popup state; null when dismissed. candidates
    // is arena-owned (replaced wholesale on every recompute — the arena
    // never frees, matching the session-lifetime slice pattern) and
    // selected starts at 0 each time the popup opens.
    var sugg: ?notui.component.Suggestions = null;
    // §7: eval start timestamp (set in submit) and the last completed
    // eval's duration in ms (status band; cleared on the next keypress).
    var eval_start: std.Io.Timestamp = .fromNanoseconds(0);
    var last_eval_ms: ?u64 = null;

    var reader = Reader.init(&tty);
    const w = tty.writer();

    while (true) {
        const ev = reader.nextTimeout(tick_ms) catch break;
        if (ev) |e| switch (e) {
            .key_press => |k| {
                // Any key clears the "done in …ms" status (§7).
                last_eval_ms = null;
                // A Tab-accept dismisses the popup and suppresses the tail
                // recompute: the accepted symbol itself is a prefix match,
                // so re-filtering would re-open the popup on the spot.
                var accepted: bool = false;
                if (isCtrlC(k)) {
                    if (worker != null) {
                        // ^C during an in-flight eval quits (skript's own
                        // REPL convention); the join below blocks until
                        // the cooperative VM finishes. At the prompt, ^C
                        // clears the line (readline convention).
                        break;
                    }
                    // Normal key event: clear the line, keep running
                    // (embed contract §8: ctrl+c never hard-quits).
                    line.clearRetainingCapacity();
                    cursor = 0;
                } else if (isCtrlD(k)) {
                    break; // ctrl+d always quits (even mid-eval)
                } else if (k.matches('q', .{}) and
                    std.mem.trim(u8, line.items, " \t").len == 0)
                {
                    break; // `q` quits on an empty (or whitespace-only) line
                } else if (k.matches(Key.enter, .{})) {
                    // An open popup dismisses BEFORE Enter's normal path
                    // (submit or multi-line continuation) runs.
                    if (sugg != null) {
                        sugg = null;
                        try region.setHeight(base_height);
                    }
                    // Meta commands / multi-line continuation / submit
                    // (§4-§5); ignored while a submission is in flight.
                    if (try handleEnter(
                        aa,
                        io,
                        &region,
                        &line,
                        &cursor,
                        &history,
                        &slot,
                        &worker,
                        rt,
                        &eval_start,
                    )) break;
                } else if (sugg != null and k.matches(Key.tab, .{})) {
                    // Accept the highlighted candidate (popup only; a
                    // closed popup falls through to the text insert).
                    try acceptSuggestion(aa, &line, &cursor, sugg.?);
                    sugg = null;
                    try region.setHeight(base_height);
                    accepted = true;
                } else if (sugg != null and k.matches(Key.escape, .{})) {
                    sugg = null; // dismiss without accepting (line untouched)
                    try region.setHeight(base_height);
                } else if (sugg != null and k.matches(Key.up, .{})) {
                    // Navigate candidates (wrap), NOT history.
                    sugg.?.selected = (sugg.?.selected + sugg.?.candidates.len - 1) % sugg.?.candidates.len;
                } else if (sugg != null and k.matches(Key.down, .{})) {
                    sugg.?.selected = (sugg.?.selected + 1) % sugg.?.candidates.len;
                } else if (k.matches(Key.up, .{})) {
                    history.up(aa, &line);
                    cursor = line.items.len;
                } else if (k.matches(Key.down, .{})) {
                    history.down(aa, &line);
                    cursor = line.items.len;
                } else if (k.matches(Key.left, .{ .alt = true })) {
                    cursor = moveWordLeft(line.items, cursor);
                } else if (k.matches(Key.right, .{ .alt = true })) {
                    cursor = moveWordRight(line.items, cursor);
                } else if (k.matches('a', .{ .ctrl = true })) {
                    cursor = 0; // Ctrl+A: line start
                } else if (k.matches('e', .{ .ctrl = true })) {
                    cursor = line.items.len; // Ctrl+E: line end
                } else if (k.matches('k', .{ .ctrl = true })) {
                    line.items.len = cursor; // Ctrl+K: kill to end
                } else if (k.matches('u', .{ .ctrl = true })) {
                    // Ctrl+U: kill to start.
                    std.mem.copyForwards(u8, line.items[0..], line.items[cursor..]);
                    line.items.len -= cursor;
                    cursor = 0;
                } else if (k.matches('w', .{ .ctrl = true })) {
                    // Ctrl+W: delete the word before the cursor.
                    const start = moveWordLeft(line.items, cursor);
                    std.mem.copyForwards(u8, line.items[start..], line.items[cursor..]);
                    line.items.len -= cursor - start;
                    cursor = start;
                } else if (k.matches(Key.left, .{})) {
                    cursor = prevCodepoint(line.items, cursor);
                } else if (k.matches(Key.right, .{})) {
                    if (cursor < line.items.len) cursor += utf8SeqLen(line.items, cursor);
                } else if (k.matches(Key.home, .{})) {
                    cursor = 0;
                } else if (k.matches(Key.end, .{})) {
                    cursor = line.items.len;
                } else if (k.matches(Key.backspace, .{})) {
                    // Delete the codepoint BEFORE the cursor.
                    const start = prevCodepoint(line.items, cursor);
                    std.mem.copyForwards(u8, line.items[start..], line.items[cursor..]);
                    line.items.len -= cursor - start;
                    cursor = start;
                } else if (k.matches(Key.delete, .{})) {
                    // Delete the codepoint AT the cursor (forward).
                    if (cursor < line.items.len) {
                        const clen = utf8SeqLen(line.items, cursor);
                        std.mem.copyForwards(u8, line.items[cursor..], line.items[cursor + clen ..]);
                        line.items.len -= clen;
                    }
                } else if (k.matches(Key.escape, .{})) {
                    // Ignore.
                } else {
                    try insertKeyText(aa, &line, &cursor, k);
                }

                // Recompute the popup for the post-key token (idle only):
                // every idle keypress re-filters, so the popup tracks the
                // token under the cursor after text, nav and kill keys.
                // Never while an eval is in flight — completion reads
                // root_ns, and the worker owns the runtime during an eval.
                if (worker == null and !accepted) {
                    std.debug.assert(worker == null);
                    const prefix = tokenAtCursor(line.items, cursor);
                    const cands = if (prefix.len == 0) &.{} else candidates(aa, rt, prefix);
                    if (cands.len == 0) {
                        // Zero matches (empty/number token, or a prefix
                        // nothing starts with): dismiss.
                        if (sugg != null) {
                            sugg = null;
                            try region.setHeight(base_height);
                        }
                    } else {
                        var s = if (sugg) |s0|
                            s0
                        else
                            notui.component.Suggestions{ .candidates = cands, .selected = 0, .max_rows = max_rows };
                        s.candidates = cands;
                        if (s.selected >= cands.len) s.selected = 0; // recompute shrank the list
                        sugg = s;
                        try region.setHeight(base_height + @as(u16, @intCast(@min(cands.len, @as(usize, max_rows)))));
                    }
                }
            },
            .winsize => |wsz| try region.resize(wsz.cols, region.height),
            // The reply to the region's own CPR query (first render,
            // resize, reanchor): correct the bookkeeping anchor so an
            // external fd-1/fd-2 write can't leave the band drifted.
            .cpr => |pos| try region.applyCpr(pos.row, pos.col),
            else => {},
        };

        if (tty.checkResize()) {
            const wsz = try tty.getWinsize();
            try region.resize(wsz.cols, region.height);
        }

        // Poll the eval slot; append the finished submission when ready.
        const now = std.Io.Timestamp.now(io, .awake);
        try pollSlot(aa, &region, &slot, &worker, &eval_start, &last_eval_ms, now);

        try drawBand(aa, &region, line.items, cursor, sugg, &spinner, worker != null, now, last_eval_ms);
        try region.render(w);
        try w.flush();
    }

    // Wait for any in-flight eval before tearing down: the worker is the
    // runtime's sole owner while it runs; quitting mid-eval blocks until
    // skript's cooperative scheduler yields (accepted for v1).
    if (worker) |t| t.join();
    try region.exit(w);
    try caps.restore(w); // disable kitty keyboard — leave the user's terminal clean
    try w.flush();
}

// ── eval worker + result slot (contract §5.1) ─────────────────────

/// Submission outcome phase; the answer string already carries the
/// "Parser error:" / "Eval error:" label, the phase is kept for the slot
/// contract's shape.
const Phase = enum { none, ok, parse, eval };

/// SPSC result slot. `std.Thread.Mutex` was removed in Zig 0.16, so the
/// handoff uses the contract's sanctioned alternative: an atomic ready
/// flag with release/acquire ordering. The worker writes the payload,
/// then `ready.store(true, .release)`; the main thread observes with
/// `ready.load(.acquire)`, so every payload write is visible after the
/// load. Only the main thread resets the flag, and only after joining the
/// worker — there is never concurrent access.
const ResultSlot = struct {
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    query: []const u8 = "",
    answer: []const u8 = "",
    lib_out: []const u8 = "",
    phase: Phase = .none,
};

const WorkerCtx = struct {
    rt: *skript.Runtime,
    query: []const u8,
    aa: std.mem.Allocator,
    slot: *ResultSlot,
};

/// Worker thread body: compile + eval + format the answer entirely off
/// the UI thread, capturing the form's fd 1/2 writes. All results are
/// allocated from the app arena, so the main thread never dereferences
/// runtime memory.
fn evalWorker(ctx: *WorkerCtx) void {
    const aa = ctx.aa;

    // Redirect the form's fd 1/2 writes into a pipe (best-effort: a
    // capture failure evaluates normally). notui renders through the tty's
    // own fd, so the redirect never corrupts the region.
    var capture: OutputCapture = .{};
    const cap_ok = if (capture.begin()) |_| true else |_| false;

    // Eval: regvm via the Reader. spawnEval parses with Reader.readAll
    // (which desugars tensor/map literals `[2 5]` → `(tensor 2 5)` /
    // `:{...}` → `(map ...)`) then compiles on the regvm. Parse/compile
    // errors surface from spawnEval → "Parser error"; eval errors from
    // awaitProcess → "Eval error". NO AST parse gate: rt.read/Ast.create
    // is MORE restrictive than the Reader and rejects reader-valid
    // constructs (e.g. `[2 5]` → error.Unimplemented), which is why a
    // tensor literal worked in skript's CLI (Reader path) but failed here.
    var phase: Phase = .ok;
    var answer: []const u8 = "OoM";
    const proc = ctx.rt.spawnEval(ctx.query) catch |e| blk: {
        phase = .parse;
        answer = std.fmt.allocPrint(aa, "Parser error: {any}", .{e}) catch "Parser error";
        break :blk null;
    };
    if (proc) |p| {
        const res = ctx.rt.awaitProcess(p) catch |e| blk: {
            phase = .eval;
            answer = std.fmt.allocPrint(aa, "Eval error: {any}", .{e}) catch "Eval error";
            break :blk null;
        };
        if (res) |val| answer = formatAnswer(aa, ctx.rt, val);
    }
    // Answer guard, byte cap (§6): a huge pretty answer (giant tensor,
    // giant structure) is truncated so it cannot balloon the scrollback.
    if (answer.len > max_answer_bytes) {
        answer = std.fmt.allocPrint(aa, "{s}\n… (truncated)", .{
            answer[0..max_answer_bytes],
        }) catch answer[0..max_answer_bytes];
    }

    // Restore the fds FIRST (a straggling write then lands on the
    // terminal, not the pipe), then drain and own the captured bytes.
    const lib_out = if (cap_ok) ownLibOut(aa, capture.end(aa)) else "";

    // Publish: payload first, then the release store publishes it.
    ctx.slot.query = ctx.query;
    ctx.slot.answer = answer;
    ctx.slot.lib_out = lib_out;
    ctx.slot.phase = phase;
    ctx.slot.ready.store(true, .release);
}

/// Submit the typed line: copy it into the arena, spawn the eval worker,
/// record history. Enter is ignored while a submission is in flight —
/// the runtime is single-owner and only one eval runs at a time.
fn submit(
    aa: std.mem.Allocator,
    io: std.Io,
    line: *std.ArrayList(u8),
    cursor: *usize,
    history: *History,
    slot: *ResultSlot,
    worker: *?std.Thread,
    rt: *skript.Runtime,
    eval_start: *std.Io.Timestamp,
) !void {
    const trimmed = std.mem.trim(u8, line.items, " \n\r\t");
    if (trimmed.len == 0) return;
    if (worker.* != null) return;

    const query = try aa.dupe(u8, trimmed);
    const ctx = try aa.create(WorkerCtx);
    ctx.* = .{ .rt = rt, .query = query, .aa = aa, .slot = slot };
    worker.* = try std.Thread.spawn(.{}, evalWorker, .{ctx});
    try history.push(aa, query);
    eval_start.* = std.Io.Timestamp.now(io, .awake);
    line.clearRetainingCapacity();
    cursor.* = 0;
}

/// Main-loop tick: if the slot holds a fresh result, join the worker,
/// reset the slot, and append the query + answer + lib rows above the
/// band.
fn pollSlot(
    aa: std.mem.Allocator,
    region: *Region,
    slot: *ResultSlot,
    worker: *?std.Thread,
    eval_start: *std.Io.Timestamp,
    last_eval_ms: *?u64,
    now: std.Io.Timestamp,
) !void {
    if (!slot.ready.load(.acquire)) return;
    if (worker.*) |t| t.join();
    worker.* = null;

    // §7: elapsed time from spawn to result consumption, in ms.
    const elapsed_ns = now.nanoseconds - eval_start.nanoseconds;
    last_eval_ms.* = @intCast(@max(elapsed_ns, 0) / std.time.ns_per_ms);

    const query = slot.query;
    const answer = slot.answer;
    const lib_out = slot.lib_out;
    slot.ready.store(false, .release); // reset for the next submission

    try appendEntry(aa, region, query, answer, lib_out);
}

// ── Enter handling: meta commands + multi-line (§4-§5) ────────────

/// Handle Enter: meta-command dispatch, then multi-line continuation,
/// then submit. Returns true when a `:quit`/`:q` requested exit.
fn handleEnter(
    aa: std.mem.Allocator,
    io: std.Io,
    region: *Region,
    line: *std.ArrayList(u8),
    cursor: *usize,
    history: *History,
    slot: *ResultSlot,
    worker: *?std.Thread,
    rt: *skript.Runtime,
    eval_start: *std.Io.Timestamp,
) !bool {
    const trimmed = std.mem.trim(u8, line.items, " \n\r\t");
    if (trimmed.len == 0) return false; // empty: nothing to do (matches v1)
    switch (try dispatchMeta(region, line, cursor, trimmed)) {
        .quit => return true,
        .handled => return false,
        .not_command => {},
    }
    if (!isComplete(line.items)) {
        // Unbalanced delimiters / unterminated string: continue input.
        try line.append(aa, '\n');
        cursor.* = line.items.len;
        return false;
    }
    try submit(aa, io, line, cursor, history, slot, worker, rt, eval_start);
    return false;
}

/// Outcome of a meta-command dispatch attempt.
const MetaOutcome = enum { not_command, handled, quit };

/// Handle leading-`:` commands. Exact-match only (§5): a command is
/// recognized when the trimmed line starts with ':' and equals a known
/// command; anything else (bare ':', `:foo` keyword literals) evaluates
/// normally and is never shadowed.
fn dispatchMeta(
    region: *Region,
    line: *std.ArrayList(u8),
    cursor: *usize,
    trimmed: []const u8,
) !MetaOutcome {
    if (trimmed.len < 2 or trimmed[0] != ':') return .not_command;
    if (std.mem.eql(u8, trimmed, ":help")) {
        for (help_rows) |row| try region.append(.{ .line = row });
        return .handled;
    }
    if (std.mem.eql(u8, trimmed, ":quit") or std.mem.eql(u8, trimmed, ":q")) return .quit;
    if (std.mem.eql(u8, trimmed, ":clear")) {
        line.clearRetainingCapacity();
        cursor.* = 0;
        return .handled;
    }
    return .not_command;
}

/// True when `src` is a complete expression: balanced delimiters and no
/// unterminated string/comment. False = incomplete → continue input.
/// The skript lexer skips comments/strings internally, so a token-walk
/// depth scan is complete and robust; a lex error (unterminated string
/// or block comment) means the input is still incomplete (§4.1).
fn isComplete(src: []const u8) bool {
    var c: skript.Cursor = .{ .src = src };
    var depth: i32 = 0;
    while (true) {
        const tok = skript.lex(&c) catch return false;
        switch (tok.kind) {
            .lparen, .lbracket, .lbrace, .map_marker => depth += 1, // :{ is a grouping opener
            .rparen, .rbracket, .rbrace => depth -= 1,
            .eof => return depth <= 0, // negative = overclosed → submit (reader errors)
            else => {},
        }
    }
}

// ── scrollback appends (contract §8 / D3: plain per-line, no boxes) ────

/// Append one completed submission above the band: the query (chunked at
/// the region width, keyword-styled per chunk), the " ⇒ answer" line(s),
/// and the muted captured library output (capped preview). Every `.line`
/// occupies exactly one terminal row — over-wide text is chunked, and
/// embedded `\n` is split first so the region's anchor accounting stays
/// exact.
fn appendEntry(
    aa: std.mem.Allocator,
    region: *Region,
    query: []const u8,
    answer: []const u8,
    lib_out: []const u8,
) !void {
    // Query rows. A pasted query can contain newlines; split them first.
    var q_lines = std.mem.splitScalar(u8, query, '\n');
    while (q_lines.next()) |qline| {
        var rest = qline;
        while (rest.len > 0) {
            const chunk = try notui.width.truncate(aa, rest, region.width);
            if (chunk.len == 0) break; // a single over-wide grapheme: drop
            const segs = try scanQuery(aa, chunk);
            try region.append(.{ .line = try styleLine(aa, segs) });
            rest = rest[chunk.len..];
        }
    }
    // Answer rows: " ⇒ " prefix on the first chunk; the answer is already
    // hanging-indented for its own newlines (formatAnswer). Line cap (§6):
    // at most max_answer_lines rows, then one muted marker row.
    var total_a_lines: usize = 1;
    for (answer) |c| {
        if (c == '\n') total_a_lines += 1;
    }
    var a_lines = std.mem.splitScalar(u8, answer, '\n');
    var first_a = true;
    var shown_a_lines: usize = 0;
    while (a_lines.next()) |aline| {
        if (shown_a_lines >= max_answer_lines) {
            const hidden = total_a_lines - shown_a_lines;
            var row: std.ArrayList(u8) = .empty;
            try pushStyle(aa, &row, lib_style);
            try row.print(aa, "… (truncated: {d} lines)", .{hidden});
            try row.appendSlice(aa, reset_sgr);
            try pushLine(aa, region, row.items);
            break;
        }
        var rest = aline;
        var first_chunk = true;
        while (rest.len > 0) {
            const prefix = if (first_a and first_chunk) answer_prefix else "";
            const avail = region.width -| @as(u16, @intCast(notui.width.strWidth(prefix)));
            const chunk = try notui.width.truncate(aa, rest, avail);
            if (chunk.len == 0) break;
            var row: std.ArrayList(u8) = .empty;
            try row.appendSlice(aa, prefix);
            try row.appendSlice(aa, chunk);
            try region.append(.{ .line = row.items });
            rest = rest[chunk.len..];
            first_chunk = false;
        }
        if (first_chunk and first_a) try region.append(.{ .line = answer_prefix });
        first_a = false;
        shown_a_lines += 1;
    }
    // Muted library output rows (fd-capture preview, ≤ 5 lines).
    if (lib_out.len > 0) {
        const preview = try libPreview(aa, lib_out);
        var it = std.mem.splitScalar(u8, preview, '\n');
        while (it.next()) |l| {
            var row: std.ArrayList(u8) = .empty;
            try pushStyle(aa, &row, lib_style);
            try row.appendSlice(aa, l);
            try row.appendSlice(aa, reset_sgr);
            try pushLine(aa, region, row.items);
        }
    }
}

/// Queue `text` as `.line` rows split at the region width so each
/// occupies exactly one terminal row (prompt.zig pushLine pattern). The
/// caller has already styled `text`; width is measured on the PLAIN text.
fn pushLine(aa: std.mem.Allocator, region: *Region, text: []const u8) !void {
    var rest = text;
    while (rest.len > 0) {
        const chunk = try notui.width.truncate(aa, rest, region.width);
        if (chunk.len == 0) break; // a single over-wide grapheme: drop
        try region.append(.{ .line = chunk });
        rest = rest[chunk.len..];
    }
}

// ── answer formatting (contract §4, skript repl.zig Query.submit) ─────

/// Format a finished Value as "value (TypeName)" via skript's pretty
/// formatter, with a hanging indent for multi-line (tensor) answers
/// aligned under the " ⇒ " prefix by display width.
fn formatAnswer(aa: std.mem.Allocator, rt: *skript.Runtime, res: skript.Value) []const u8 {
    const tag_val: u64 = @intFromEnum(res.typ);
    const typ_ptr: *const skript.Type = if (tag_val <= skript.builtins.type_last_idx)
        rt.predefined_types.items[@as(usize, @intCast(tag_val))]
    else
        res.typ.toRef().deref(skript.Type);
    const answer0 = std.fmt.allocPrint(aa, "{f} ({s})", .{
        skript.intrinsics.print.FormatValue{ .value = res, .runtime = rt, .pretty = true },
        typ_ptr.name.toPtr(skript.Sym).*,
    }) catch "OoM";
    if (std.mem.indexOfScalar(u8, answer0, '\n') == null) return answer0;
    const indent_w = notui.width.strWidth(answer_prefix);
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, answer0, '\n');
    var first = true;
    while (lines.next()) |al| {
        if (!first) {
            out.append(aa, '\n') catch return answer0;
            var n: usize = 0;
            while (n < indent_w) : (n += 1) out.append(aa, ' ') catch return answer0;
        }
        out.appendSlice(aa, al) catch return answer0;
        first = false;
    }
    return out.toOwnedSlice(aa) catch answer0;
}

// ── fd capture (contract §6, ported from skript repl.zig) ─────────────

/// Redirect the process's fd 1/2 into a pipe while a form evaluates, so a
/// library's raw stdout/stderr lands in the scrollback (muted) instead of
/// glitching the TUI. Process-wide, but notui renders through the tty's
/// own fd, so the redirect is invisible to the region. Best-effort: a
/// capture failure never aborts the eval.
const OutputCapture = struct {
    pipe: [2]std.posix.fd_t = .{ -1, -1 },
    saved: [2]std.posix.fd_t = .{ -1, -1 },
    active: bool = false,

    fn begin(self: *OutputCapture) !void {
        if (libc.pipe(&self.pipe) != 0) return error.PipeFailed;
        self.saved[0] = libc.dup(std.posix.STDOUT_FILENO);
        self.saved[1] = libc.dup(std.posix.STDERR_FILENO);
        if (self.saved[0] < 0 or self.saved[1] < 0) {
            _ = libc.close(self.pipe[0]);
            _ = libc.close(self.pipe[1]);
            if (self.saved[0] >= 0) _ = libc.close(self.saved[0]);
            if (self.saved[1] >= 0) _ = libc.close(self.saved[1]);
            return error.DupFailed;
        }
        if (libc.dup2(self.pipe[1], std.posix.STDOUT_FILENO) < 0 or
            libc.dup2(self.pipe[1], std.posix.STDERR_FILENO) < 0)
        {
            _ = libc.close(self.pipe[0]);
            _ = libc.close(self.pipe[1]);
            _ = libc.close(self.saved[0]);
            _ = libc.close(self.saved[1]);
            return error.Dup2Failed;
        }
        _ = libc.close(self.pipe[1]);
        self.pipe[1] = -1;
        self.active = true;
    }

    /// Restore the fds FIRST (a straggling write then lands on the
    /// terminal, not the pipe), then drain the pipe into arena memory.
    fn end(self: *OutputCapture, aa: std.mem.Allocator) []const u8 {
        std.debug.assert(self.active);
        _ = libc.dup2(self.saved[0], std.posix.STDOUT_FILENO);
        _ = libc.dup2(self.saved[1], std.posix.STDERR_FILENO);
        _ = libc.close(self.saved[0]);
        _ = libc.close(self.saved[1]);
        self.active = false;
        var out: std.ArrayList(u8) = .empty;
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = libc.read(self.pipe[0], &chunk, chunk.len);
            if (n <= 0) break;
            out.appendSlice(aa, chunk[0..@intCast(n)]) catch break;
        }
        _ = libc.close(self.pipe[0]);
        self.pipe[0] = -1;
        return out.toOwnedSlice(aa) catch "";
    }
};

/// Own the captured bytes: strip ANSI escape sequences (a colored
/// library must not corrupt the TUI) and cap at 8192 bytes.
fn ownLibOut(aa: std.mem.Allocator, raw: []const u8) []const u8 {
    const max_bytes: usize = 8192;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len and out.items.len < max_bytes) : (i += 1) {
        if (raw[i] == 0x1b) {
            // Skip one CSI/OSC sequence: ESC [ … letter, or ESC ] … BEL.
            i += 1;
            while (i < raw.len and raw[i] != 0x07 and !isAsciiAlpha(raw[i])) : (i += 1) {}
            continue;
        }
        out.append(aa, raw[i]) catch break;
    }
    if (i < raw.len) {
        out.appendSlice(aa, "\n… (truncated)") catch |err| std.mem.doNotOptimizeAway(@intFromError(err));
    }
    return out.toOwnedSlice(aa) catch "";
}

/// Cap the captured lib output shown in the scrollback: first 5 lines
/// plus a "… N more captured line(s)" suffix.
fn libPreview(aa: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const max_lines = 5;
    var end: usize = 0;
    var line_count: usize = 0;
    while (line_count < max_lines) : (line_count += 1) {
        const nl = std.mem.findScalarPos(u8, raw, end, '\n') orelse {
            // Fewer lines than the cap: show everything (strip a trailing NL).
            return if (raw.len > 0 and raw[raw.len - 1] == '\n') raw[0 .. raw.len - 1] else raw;
        };
        end = nl + 1;
    }
    var rest: usize = 0;
    var pos = end;
    while (std.mem.findScalarPos(u8, raw, pos, '\n')) |nl| {
        rest += 1;
        pos = nl + 1;
    }
    if (rest == 0) return raw;
    return std.fmt.allocPrint(aa, "{s}… {d} more captured line{s}", .{
        raw[0..end],
        rest,
        if (rest == 1) "" else "s",
    });
}

fn isAsciiAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

// ── keyword scanner (contract §7: hand-rolled, no tree-sitter) ────────

/// One styled text run of the scanned input line.
const ScanSeg = struct {
    text: []const u8,
    style: Style,
};

/// Scan `src` into styled segments: strings, numbers, comments (`;` and
/// nested `#|…|#`), keyword literals (`:name`, `:{`), special forms and
/// constants; everything else (identifiers, operators, punctuation,
/// whitespace) collapses into unstyled runs. The lexer swallows comments,
/// so this scanner detects them itself.
fn scanQuery(aa: std.mem.Allocator, src: []const u8) ![]const ScanSeg {
    var segs: std.ArrayList(ScanSeg) = .empty;
    var i: usize = 0;
    var plain_start: usize = 0;

    while (i < src.len) {
        const c = src[i];
        if (c == ';') {
            const start = i;
            while (i < src.len and src[i] != '\n') i += 1;
            try flushPlain(aa, &segs, src, plain_start, start);
            try segs.append(aa, .{ .text = src[start..i], .style = comment_style });
            plain_start = i;
        } else if (c == '#' and i + 1 < src.len and src[i + 1] == '|') {
            // Nested block comment (#| … |#).
            const start = i;
            var depth: usize = 1;
            i += 2;
            while (i < src.len and depth > 0) {
                if (src[i] == '#' and i + 1 < src.len and src[i + 1] == '|') {
                    depth += 1;
                    i += 2;
                } else if (src[i] == '|' and i + 1 < src.len and src[i + 1] == '#') {
                    depth -= 1;
                    i += 2;
                } else {
                    i += 1;
                }
            }
            try flushPlain(aa, &segs, src, plain_start, start);
            try segs.append(aa, .{ .text = src[start..i], .style = comment_style });
            plain_start = i;
        } else if (c == '"') {
            // String literal; backslash escapes the next byte. The escape
            // skip is bounded: a trailing backslash (nothing after it)
            // advances to the line end instead of past src.len.
            const start = i;
            i += 1;
            while (i < src.len) {
                if (src[i] == '\\' and i + 1 < src.len) {
                    i += 2;
                } else if (src[i] == '"') {
                    i += 1;
                    break;
                } else {
                    i += 1;
                }
            }
            try flushPlain(aa, &segs, src, plain_start, start);
            try segs.append(aa, .{ .text = src[start..i], .style = string_style });
            plain_start = i;
        } else if (c == ':') {
            // Keyword literal (:name) and the :{ map marker.
            const start = i;
            i += 1;
            while (i < src.len and !isDelim(src[i]) and src[i] != '{') i += 1;
            try flushPlain(aa, &segs, src, plain_start, start);
            try segs.append(aa, .{ .text = src[start..i], .style = keyword_style });
            plain_start = i;
        } else if (isDigit(c)) {
            // Integer / float / scientific / radix literals.
            const start = i;
            while (i < src.len and (isAlnum(src[i]) or src[i] == '.' or src[i] == '_')) i += 1;
            try flushPlain(aa, &segs, src, plain_start, start);
            try segs.append(aa, .{ .text = src[start..i], .style = number_style });
            plain_start = i;
        } else if (isIdentStart(c)) {
            const start = i;
            while (i < src.len and !isDelim(src[i])) i += 1;
            const word = src[start..i];
            const style = if (isSpecialForm(word))
                special_style
            else if (isConstant(word))
                constant_style
            else
                Style{};
            if (!style.eql(.{})) {
                try flushPlain(aa, &segs, src, plain_start, start);
                try segs.append(aa, .{ .text = word, .style = style });
                plain_start = i;
            }
            // Plain identifiers stay inside the plain run: [plain_start, i)
            // already covers them, so no segment split is needed.
        } else {
            i += 1; // whitespace / punctuation: the plain run grows
        }
    }
    try flushPlain(aa, &segs, src, plain_start, src.len);
    return segs.toOwnedSlice(aa);
}

/// Emit the current unstyled run as one segment, if non-empty.
fn flushPlain(
    aa: std.mem.Allocator,
    segs: *std.ArrayList(ScanSeg),
    src: []const u8,
    start: usize,
    end: usize,
) !void {
    if (end > start) try segs.append(aa, .{ .text = src[start..end], .style = .{} });
}

fn isSpecialForm(word: []const u8) bool {
    for (special_forms) |sf| {
        if (std.mem.eql(u8, word, sf)) return true;
    }
    return false;
}

fn isConstant(word: []const u8) bool {
    return std.mem.eql(u8, word, "nil") or
        std.mem.eql(u8, word, "true") or
        std.mem.eql(u8, word, "false");
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isAlnum(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
}

/// Symbol / identifier start: letters plus the operator characters skript
/// binds in the prelude (`+`, `<`, …).
fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or switch (c) {
        '+', '-', '*', '/', '<', '>', '=', '!', '?', '_', '$', '%', '&', '~', '^' => true,
        else => false,
    };
}

/// Token delimiters: whitespace and the reader punctuation.
fn isDelim(c: u8) bool {
    return std.ascii.isWhitespace(c) or switch (c) {
        '(', ')', '[', ']', '{', '}', '"', '\'', ',', '`', ';' => true,
        else => false,
    };
}

// ── SGR styling helpers ─────────────────────────────

/// Append the SGR sequence for `style` (foreground-only; a default or
/// `.default` color emits the reset). Scrollback `.line` rows pass
/// through the region verbatim, so the sequences render — and the
/// region's post-flush full repaint resets tracked styles afterward.
fn pushStyle(aa: std.mem.Allocator, out: *std.ArrayList(u8), style: Style) !void {
    if (style.fg) |fg| {
        switch (fg) {
            .default => try out.appendSlice(aa, reset_sgr),
            .ansi => |ac| try out.print(aa, "\x1b[{d}m", .{ac.fgCode()}),
            .ansi256 => |idx| try out.print(aa, "\x1b[38;5;{d}m", .{idx}),
            .rgb => |rgb| try out.print(aa, "\x1b[38;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b }),
        }
    } else {
        try out.appendSlice(aa, reset_sgr);
    }
}

/// SGR-wrap one segment list into a single line: unstyled segments pass
/// through raw, styled segments get a push + reset.
fn styleLine(aa: std.mem.Allocator, segs: []const ScanSeg) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (segs) |seg| {
        if (seg.style.eql(.{})) {
            try out.appendSlice(aa, seg.text);
        } else {
            try pushStyle(aa, &out, seg.style);
            try out.appendSlice(aa, seg.text);
            try out.appendSlice(aa, reset_sgr);
        }
    }
    return out.toOwnedSlice(aa);
}

// ── inline suggestions: candidates + token detection ───────────────

/// Completion candidates: every binding in root_ns whose name starts with
/// `prefix` (case-sensitive) plus the builtin special forms, sorted for a
/// stable Tab order. The returned LIST is allocated from `alloc`; the
/// candidate STRING contents are borrowed (interned store symbols + the
/// static builtin_keywords array) and stay valid for the runtime's life.
/// MAIN THREAD ONLY: the caller MUST hold worker == null (§1.4).
fn candidates(alloc: std.mem.Allocator, rt: *skript.Runtime, prefix: []const u8) []const []const u8 {
    const ns_ptr = rt.root_ns.obj.toRef().deref(skript.Namespace);
    const root_map: *skript.HashMapNamespace = @ptrCast(@alignCast(ns_ptr.data));
    var out: std.ArrayList([]const u8) = .empty;
    var it = root_map.bindings.iterator();
    while (it.next()) |kv| {
        const name: []const u8 = kv.key_ptr.*.*;
        if (std.mem.startsWith(u8, name, prefix)) out.append(alloc, name) catch break;
    }
    for (builtin_keywords) |kw| {
        if (std.mem.startsWith(u8, kw, prefix)) out.append(alloc, kw) catch break;
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    // Arena-backed: toOwnedSlice transfers the backing array to the arena
    // (the caller frees nothing — the arena resets each frame); on OOM
    // degrade to no candidates, consistent with the append catches above.
    return out.toOwnedSlice(alloc) catch return &.{};
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// A completion token terminator: whitespace, the reader grouping
/// punctuation, a colon, or a quote. A symbol never spans one of these,
/// so scanning back to the last one yields the prefix being typed. `:` is
/// deliberately a terminator so a `:keyword` literal never completes
/// against symbol names.
fn isCompletionDelim(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or switch (c) {
        '(', ')', '[', ']', '{', '}', ':', '"', '\'' => true,
        else => false,
    };
}

/// The in-progress symbol prefix at `cursor`. Empty when the cursor is at
/// a token boundary or the token can't be a symbol (number / string), in
/// which case NO popup should show. Scans `line.items[0..cursor]`; the
/// `\n` delimiter already handles multi-line continuation safety.
fn tokenAtCursor(line: []const u8, cursor: usize) []const u8 {
    var start = cursor;
    while (start > 0 and !isCompletionDelim(line[start - 1])) start -= 1;
    const tok = line[start..cursor];
    if (tok.len == 0) return "";
    if (isDigit(tok[0])) return ""; // number literal → no symbol completion
    return tok;
}

/// Replace the current token with the highlighted candidate and move the
/// cursor to its end. Dismissal (sugg = null + setHeight) is the caller's
/// job.
fn acceptSuggestion(
    aa: std.mem.Allocator,
    line: *std.ArrayList(u8),
    cursor: *usize,
    s: notui.component.Suggestions,
) !void {
    const cand = s.candidates[s.selected];
    // Re-derive the token range exactly as tokenAtCursor (§2.2).
    var start = cursor.*;
    while (start > 0 and !isCompletionDelim(line.items[start - 1])) start -= 1;
    line.items.len = start; // drop the partial token
    try line.insertSlice(aa, start, cand); // splice in the candidate
    cursor.* = start + cand.len; // cursor past the accepted symbol
}

// ── band drawing ───────────────────────────────

/// Paint the band: row 0 = continuation prompt (when the pending buffer
/// spans lines) or the main prompt, then the ACTIVE line with a
/// reverse-video cursor block; rows 1..shown = the open suggestion popup
/// aligned under the cursor column (base-ui Suggestions); the status row
/// (busy spinner, "done in {d}ms" after a completed eval (§7), or the
/// idle hint) sits at `1 + shown` — row 1 when the popup is closed.
fn drawBand(
    aa: std.mem.Allocator,
    region: *Region,
    line: []const u8,
    cursor: usize,
    sugg: ?notui.component.Suggestions,
    spinner: *notui.component.Spinner,
    busy: bool,
    now: std.Io.Timestamp,
    last_eval_ms: ?u64,
) !void {
    region.cur.clear();
    // Only the ACTIVE continuation line renders (§4.3); the pending
    // buffer may contain embedded '\n' from continuation Enters.
    const active_off = if (std.mem.findScalarLast(u8, line, '\n')) |nl| nl + 1 else 0;
    const active = line[active_off..];
    const multiline = std.mem.indexOfScalar(u8, line, '\n') != null;
    const prompt = if (multiline) cont_prompt else prompt_text;
    // The cursor is a byte index into the whole buffer; clamp it into
    // the active line's range so the slice boundaries stay valid.
    const cur = std.math.clamp(cursor, active_off, line.len) - active_off;

    var x = try region.cur.draw(.{}, prompt, 0, 0);
    const prompt_col = x;
    const cur_style: Style = .{ .attrs = .{ .reverse = true } }; // reverse-video block

    // Left of the cursor.
    const left_segs = try scanQuery(aa, active[0..cur]);
    for (left_segs) |seg| x += try region.cur.draw(seg.style, seg.text, x, 0);
    // The TOKEN-START column (the popup's anchor): the first column of the
    // word being completed. Scan back to the completion delimiter, then
    // measure the display width of everything before it — so the popup
    // starts at the word's beginning and STAYS there while the cursor
    // moves within the word (typing more chars, or Left/Right through it).
    var token_start: usize = cur;
    while (token_start > 0 and !isCompletionDelim(active[token_start - 1])) token_start -= 1;
    const token_col: u16 = prompt_col + @as(u16, @intCast(notui.width.strWidth(active[0..token_start])));

    if (cur < active.len) {
        // Cursor sits ON a codepoint: reverse-video it, then the rest.
        const clen = utf8SeqLen(active, cur);
        const cell = active[cur .. cur + clen];
        _ = try region.cur.draw(cur_style, cell, x, 0);
        x += @as(u16, @intCast(notui.width.strWidth(cell)));
        const right_segs = try scanQuery(aa, active[cur + clen ..]);
        for (right_segs) |seg| _ = try region.cur.draw(seg.style, seg.text, x, 0);
    } else {
        _ = try region.cur.draw(cur_style, " ", x, 0); // block cursor at EOL
    }

    // Popup rows (1..shown) under the cursor column; the status row moves
    // down to `y` (1 + shown when open, 1 otherwise).
    var y: u16 = 1;
    if (sugg) |s0| {
        var s = s0; // draw takes *Suggestions; the payload is copied out of the const optional
        // Anchor under the TOKEN START (not the cursor): the list begins
        // where the completed word begins, clamped to the band width.
        const popup_x: u16 = @min(token_col, region.width);
        y += try s.draw(aa, &region.cur, popup_x, y, now);
    }

    if (busy) {
        _ = try spinner.draw(&region.cur, 0, y, now);
    } else if (last_eval_ms) |ms| {
        var buf: [48]u8 = undefined;
        const done = std.fmt.bufPrint(&buf, "done in {d}ms", .{ms}) catch idle_status;
        _ = try region.cur.draw(.{}, done, 0, y);
    } else {
        _ = try region.cur.draw(.{}, if (multiline) cont_status else idle_status, 0, y);
    }
}

// ── history ring (contract §8) ──────────────────────────

/// In-memory ring of prior submitted queries for Up/Down navigation.
/// Entries are arena-duped query slices, never freed (the ring trims by
/// dropping references at the front).
const History = struct {
    entries: std.ArrayList([]const u8) = .empty,
    /// Navigation position: `entries.len` = the "new line" (no Up yet).
    pos: usize = 0,

    fn push(self: *History, aa: std.mem.Allocator, query: []const u8) !void {
        try self.entries.append(aa, query);
        if (self.entries.items.len > history_cap) {
            _ = self.entries.orderedRemove(0);
        }
        self.pos = self.entries.items.len;
    }

    fn up(self: *History, aa: std.mem.Allocator, line: *std.ArrayList(u8)) void {
        if (self.entries.items.len == 0 or self.pos == 0) return;
        self.pos -= 1;
        self.load(aa, line, self.pos);
    }

    fn down(self: *History, aa: std.mem.Allocator, line: *std.ArrayList(u8)) void {
        if (self.entries.items.len == 0) return;
        if (self.pos >= self.entries.items.len) return; // already at the new line
        self.pos += 1;
        if (self.pos == self.entries.items.len) {
            line.clearRetainingCapacity();
        } else {
            self.load(aa, line, self.pos);
        }
    }

    fn load(self: *History, aa: std.mem.Allocator, line: *std.ArrayList(u8), idx: usize) void {
        line.clearRetainingCapacity();
        line.appendSlice(aa, self.entries.items[idx]) catch |err| std.mem.doNotOptimizeAway(@intFromError(err));
    }
};

// ── input helpers (prompt.zig patterns) ───────────────────────

/// True for a ctrl+c keypress in either decoding: kitty CSI-u reports
/// the control character itself (0x03); the legacy ground-state path
/// maps byte 0x03 to 'c' + ctrl. The examples must accept both.
fn isCtrlC(k: Key) bool {
    return k.matches(Key.ctrl_c, .{}) or k.matches('c', .{ .ctrl = true });
}

/// Same for ctrl+d (0x04 → 'd' + ctrl in legacy ground state).
fn isCtrlD(k: Key) bool {
    return k.matches(ctrl_d, .{}) or k.matches('d', .{ .ctrl = true });
}

/// Copy the key's text into the app arena and INSERT it at the cursor
/// (§3.2), with automatic matching-bracket insertion: typing `(` inserts
/// `()` with the cursor between; typing `)` when the auto-inserted `)` is
/// already at the cursor skips over it instead of duplicating. Only for a
/// single typed char (pastes insert verbatim). The §3 lifetime contract
/// applies: `Key.text` is valid only until the next read.
fn insertKeyText(aa: std.mem.Allocator, line: *std.ArrayList(u8), cursor: *usize, k: Key) !void {
    var text_buf: [4]u8 = undefined;
    const text: []const u8 = if (k.text) |t|
        t
    else blk: {
        const cp = k.codepoint;
        if (cp < 0x20 or cp == 0x7F or (cp >= 0xE000 and cp <= 0xF8FF) or cp > 0x10FFFF) return;
        const n = try std.unicode.utf8Encode(cp, &text_buf);
        break :blk text_buf[0..n];
    };

    // Automatic matching-bracket insertion (single typed char only).
    if (text.len == 1) {
        const c = text[0];
        if (closerFor(c)) |close| {
            // Opener: insert the pair, cursor between the brackets.
            try line.insertSlice(aa, cursor.*, &[_]u8{ c, close });
            cursor.* += 1;
            return;
        }
        // Closer typed when the auto-inserted closer is already at the
        // cursor: skip over it (no duplicate).
        if ((c == ')' or c == ']' or c == '}') and cursor.* < line.items.len and
            line.items[cursor.*] == c)
        {
            cursor.* += 1;
            return;
        }
    }

    try line.insertSlice(aa, cursor.*, text);
    cursor.* += text.len;
}

/// The closing delimiter paired with an opening bracket, or null.
fn closerFor(opener: u8) ?u8 {
    return switch (opener) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        else => null,
    };
}

// ── cursor helpers (§3.3, zigzag TextInput semantics) ────────────────

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

/// Byte index of the start of the word before `cursor` (skip trailing
/// spaces, then word chars).
fn moveWordLeft(buf: []const u8, cursor: usize) usize {
    var c = cursor;
    while (c > 0 and buf[c - 1] == ' ') c -= 1;
    while (c > 0 and buf[c - 1] != ' ') c -= 1;
    return c;
}

/// Byte index after the word at `cursor` (skip word chars, then spaces).
fn moveWordRight(buf: []const u8, cursor: usize) usize {
    var c = cursor;
    while (c < buf.len and buf[c] != ' ') c += 1;
    while (c < buf.len and buf[c] == ' ') c += 1;
    return c;
}

/// One plain hint line, no interactive sequences (piped run).
fn runPlain(io: std.Io) !void {
    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io, hint_plain);
    try stdout.writeStreamingAll(io, "\n");
}
