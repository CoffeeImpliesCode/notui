const std = @import("std");
const List = std.ArrayList;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const log = std.log.scoped(.REPL);

const skript = @import("skript");

const highlight = @import("highlight.zig");

const zz = @import("zigzag");

/// POSIX fd redirection for capturing library stdout/stderr around a form
/// evaluation. Zig 0.16 exposes pipe/dup/dup2/read only via std.c and not
/// close, so declare the full set here — the project links libc (libffi).
const libc = struct {
    extern "c" fn pipe(fds: *[2]std.posix.fd_t) c_int;
    extern "c" fn dup(fd: std.posix.fd_t) c_int;
    extern "c" fn dup2(old_fd: std.posix.fd_t, new_fd: std.posix.fd_t) c_int;
    extern "c" fn close(fd: std.posix.fd_t) c_int;
    extern "c" fn read(fd: std.posix.fd_t, buf: [*]u8, n: usize) isize;
};

/// Set by appRepl; when false (--repl-no-highlight) the query history and
/// the live input render unstyled and the tree-sitter engine is never
/// initialized.
var repl_use_highlight: bool = true;
/// The shared tree-sitter highlight engine. Null when disabled or when
/// init failed — the CodeView keyword scan remains the history fallback
/// and the input renders plain. Used only from the REPL host thread
/// (Query.submit and the tick handler), never the scheduler runner
/// thread, so the single-threaded Parser is safe.
var hl_engine: ?highlight.Engine = null;

pub fn appRepl(
    gpa: Allocator,
    static: Allocator,
    io: std.Io,
    init: std.process.Init,
    stdout: *Writer,
    use_highlight: bool,
) !void {
    _ = static;
    _ = stdout;
    repl_use_highlight = use_highlight;
    if (repl_use_highlight) {
        hl_engine = highlight.Engine.init() catch |e| blk: {
            log.warn("tree-sitter highlight engine unavailable ({any}); falling back to keyword scan", .{e});
            break :blk null;
        };
    }
    var program = zz.Program(Model).initWithOptions(gpa, io, init.environ_map, .{
        .mouse = true,
        .kitty_keyboard = true,
    });
    defer program.deinit();
    try program.run();
    if (hl_engine) |*eng| eng.deinit();
    hl_engine = null;
}

/// Result of evaluating one REPL query, split by failure phase so the error
/// message matches the pre-capture behavior ("Parser error" vs "Eval error").
const EvalOutcome = union(enum) {
    ok: skript.Value,
    err: struct { phase: enum { parse, eval }, e: skript.Error },
};

const Query = struct {
    q: []const u8,
    a: []const u8,
    /// Raw bytes the evaluated form's libraries wrote to stdout/stderr
    /// (captured via fd redirection around the eval). Rendered muted under
    /// the answer when non-empty.
    lib_out: []const u8 = "",
    /// Tree-sitter styled rendering of the query (ANSI), built once in
    /// submit when the highlight engine produced one. render() prefers it
    /// over `q` (which then holds the CodeView keyword-scan result); when
    /// highlighting is disabled, `q` is the plain query text.
    q_styled: ?[]const u8 = null,

    fn submit(
        static: Allocator,
        arena: Allocator,
        q: []const u8,
        rt: *skript.Runtime,
    ) Query {
        _ = arena;
        const query = std.mem.trimEnd(u8, q, " \n\r\t");
        var q_fmt: zz.Style = .{};
        q_fmt = q_fmt.bg(.gray(8));
        q_fmt.color_whitespace = true;
        // History-side highlighting. Preferred: the tree-sitter engine
        // (q_styled, static-owned). Fallback when it failed to init: the
        // CodeView keyword scan (q_temp, freed after the dupe). With
        // --repl-no-highlight neither runs and `query` itself is stored
        // verbatim, so the history renders plain.
        var q_styled: ?[]const u8 = null;
        var q_temp: ?[]const u8 = null;
        const q_ = if (repl_use_highlight) blk: {
            if (hl_engine) |*eng| {
                if (highlightQuery(static, eng, query)) |styled| {
                    q_styled = styled;
                    break :blk styled;
                } else |_| {}
            }
            var view: zz.components.CodeView = .{
                .source = query,
                .language = .skript,
                .tab_width = 2,
            };
            const rendered = view.view(static);
            q_temp = rendered;
            break :blk rendered;
        } else query;
        defer if (q_temp) |t| static.free(t);
        const q_owned: []const u8 = q_styled orelse (static.dupe(u8, q_) catch "OoM");

        // Capture the form's library stdout/stderr (fd 1/2) so raylib's raw
        // log lines land in the query's lib block instead of corrupting the
        // TUI dashboard. Best-effort: a capture failure evaluates normally.
        var capture: OutputCapture = .{};
        const cap_ok = if (capture.begin()) |_| true else |_| false;

        const outcome = evalOutcome: {
            const v = rt.evalString(query) catch |e|
                break :evalOutcome EvalOutcome{ .err = .{ .phase = .eval, .e = e } };
            break :evalOutcome EvalOutcome{ .ok = v };
        };
        const lib_out = if (cap_ok) ownLibOut(static, capture.end(static)) else &.{};

        const res = switch (outcome) {
            .ok => |v| v,
            .err => |er| {
                const label = switch (er.phase) {
                    .parse => "Parser error",
                    .eval => "Eval error",
                };
                return .{
                    .q = q_owned,
                    .q_styled = q_styled,
                    .a = std.fmt.allocPrint(static, "{s}: {any}", .{ label, er.e }) catch "OoM",
                    .lib_out = lib_out,
                };
            },
        };
        const tag_val: u64 = @intFromEnum(res.typ);
        const typ_ptr: *const skript.Type = if (tag_val <= skript.builtins.type_last_idx)
            rt.predefined_types.items[@as(usize, @intCast(tag_val))]
        else
            res.typ.toRef().deref(skript.Type);
        const answer0 = std.fmt.allocPrint(static, "{f} ({s})", .{
            skript.intrinsics.print.FormatValue{ .value = res, .runtime = rt, .pretty = true },
            typ_ptr.name.toPtr(skript.Sym).*,
        }) catch "OoM";
        // Shape multi-line answers (pretty tensors) with a hanging indent:
        // every line after the first aligns under the "⇒ " prefix. The width
        // comes from zigzag's width-aware measurement — "⇒" is a wide glyph.
        const answer = if (std.mem.indexOfScalar(u8, answer0, '\n') != null)
            hangIndent(static, answer0, " ⇒ ")
        else
            answer0;
        return .{
            .q = q_owned,
            .q_styled = q_styled,
            .a = answer,
            .lib_out = lib_out,
        };
    }

    fn render(self: *const Query, arena: Allocator) ![]const u8 {
        const q = self.q_styled orelse self.q;
        const body = if (self.lib_out.len > 0) blk: {
            var lib_style: zz.Style = .{};
            lib_style = lib_style.fg(.gray(10));
            const lib = lib_style.render(arena, libPreview(arena, self.lib_out) catch self.lib_out) catch self.lib_out;
            break :blk try std.fmt.allocPrint(arena, "{s}\n ⇒ {s}\n\n{s}", .{ q, self.a, lib });
        } else try std.fmt.allocPrint(arena, "{s}\n ⇒ {s}", .{ q, self.a });
        var box: zz.Style = .{};
        box = box.borderAll(.rounded);
        box = box.borderForeground(.gray(8));
        box = box.paddingRight(4).paddingLeft(0).paddingBottom(1);
        const boxed = try box.render(arena, body);
        return boxed;
    }
};

/// Render `src` with the tree-sitter capture ranges mapped onto the
/// CodeView palette (the same styles the keyword-scan fallback uses),
/// prefixed with the CodeView-style line number so the two paths render
/// identically in layout. Allocates from `static` (persistent).
fn highlightQuery(static: Allocator, eng: *highlight.Engine, src: []const u8) ![]const u8 {
    const ranges = try eng.ranges(static, src);
    const cv: zz.components.CodeView = .{ .source = src, .language = .skript };
    var out: Writer.Allocating = .init(static);
    const writer = &out.writer;
    const num_str = try std.fmt.allocPrint(static, "{d:>4} {s} ", .{ 1, cv.line_separator });
    try writer.writeAll(cv.line_number_style.render(static, num_str) catch num_str);
    var pos: usize = 0;
    for (ranges) |r| {
        if (r.start > pos) try writer.writeAll(src[pos..r.start]);
        if (r.capture != .plain and r.end > r.start) {
            const st = captureStyle(r.capture);
            try writer.writeAll(st.render(static, src[r.start..r.end]) catch src[r.start..r.end]);
        } else {
            try writer.writeAll(src[r.start..r.end]);
        }
        pos = r.end;
    }
    if (pos < src.len) try writer.writeAll(src[pos..]);
    return out.written();
}

/// Map a shared highlight capture onto the CodeView default palette — the
/// same styles the keyword-scan fallback uses. Punctuation and plain text
/// render unstyled, matching the keyword-scan behavior. Shared by the
/// history renderer (highlightQuery) and the live input highlighting
/// (Model.refreshInputHighlight).
fn captureStyle(cap: highlight.Capture) zz.Style {
    const cv: zz.components.CodeView = .{};
    return switch (cap) {
        .keyword => cv.keyword_style,
        .string => cv.string_style,
        .comment => cv.comment_style,
        .number => cv.number_style,
        .constant => cv.type_style,
        .function => cv.builtin_style,
        .operator => cv.operator_style,
        .builtin => cv.builtin_style,
        .punctuation, .plain => .{},
    };
}

/// Per-eval capture of library stdout/stderr. The scheduler runs the form's
/// process on a separate permanent runner thread; a C library (raylib) writes
/// its logs to the process's raw fd 1/2 from that thread. Without
/// redirection those bytes interleave with the TUI's escape sequences and
/// glitch the dashboard. begin() dup2's a pipe over both fds; end() restores
/// the originals FIRST (a straggling write then lands on the terminal, not
/// the pipe) and drains the pipe into `arena`-owned memory.
const OutputCapture = struct {
    pipe: [2]std.posix.fd_t = .{ -1, -1 },
    saved: [2]std.posix.fd_t = .{ -1, -1 },
    active: bool = false,

    fn begin(self: *OutputCapture) !void {
        // SAFETY: pipe(2) fills both fds on success (checked below).
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

    /// Drain the captured output. Intentional borrow: the backing buffer is
    /// allocated from the caller's `arena`, which outlives this call; the
    /// caller never frees it individually.
    fn end(self: *OutputCapture, arena: Allocator) []const u8 {
        std.debug.assert(self.active);
        _ = libc.dup2(self.saved[0], std.posix.STDOUT_FILENO);
        _ = libc.dup2(self.saved[1], std.posix.STDERR_FILENO);
        _ = libc.close(self.saved[0]);
        _ = libc.close(self.saved[1]);
        self.active = false;
        var out: List(u8) = .empty;
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = libc.read(self.pipe[0], &chunk, chunk.len);
            if (n <= 0) break;
            out.appendSlice(arena, chunk[0..@intCast(n)]) catch break;
        }
        _ = libc.close(self.pipe[0]);
        self.pipe[0] = -1;
        // Intentional borrow: the caller's arena owns this backing storage and
        // keeps it alive for the returned slice.
        return out.items;
    }
};

/// Shape a multi-line string with a HANGING indent: the first line keeps the
/// given prefix position, every continuation line is indented by the prefix's
/// DISPLAY WIDTH (measured via zigzag's width-aware shaping — "⇒" is a wide
/// glyph, so byte length is wrong). Used for pretty tensor answers so the
/// rows align under the "⇒ " marker in the history box.
/// Intentional borrow: the result is allocated from `static` (the persistent
/// arena) and is never freed individually.
fn hangIndent(static: Allocator, text: []const u8, prefix: []const u8) []const u8 {
    const indent_w = zz.measure.width(prefix);
    var out: List(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) {
            out.append(static, '\n') catch return text;
            for (0..indent_w) |_| out.append(static, ' ') catch return text;
        }
        out.appendSlice(static, line) catch return text;
        first = false;
    }
    // Intentional borrow: static owns the backing storage for the Model lifetime.
    return out.items;
}

/// Cap the captured lib output shown in the history: a library like raylib
/// floods InitWindow with 30+ log lines that would push the query's result
/// out of the viewport. Show the first few lines plus a count of the rest.
fn libPreview(arena: Allocator, raw: []const u8) ![]const u8 {
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
    return std.fmt.allocPrint(arena, "{s}… {d} more captured line{s}", .{
        raw[0..end],
        rest,
        if (rest == 1) "" else "s",
    });
}

/// Own the captured bytes in the persistent arena: strip ANSI escape
/// sequences (a library that colors its output must not corrupt the TUI)
/// and cap the size so one noisy form cannot balloon the history.
/// Intentional borrow: the result is allocated from `static` (the persistent
/// arena) and is never freed individually (also on the truncation path).
fn ownLibOut(static: Allocator, raw: []const u8) []const u8 {
    const max_bytes: usize = 8192;
    var out: List(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len and out.items.len < max_bytes) : (i += 1) {
        if (raw[i] == 0x1b) {
            // Skip one CSI/OSC sequence: ESC [ ... letter, or ESC ] ... BEL.
            i += 1;
            while (i < raw.len and raw[i] != 0x07 and !isAsciiAlpha(raw[i])) : (i += 1) {}
            continue;
        }
        out.append(static, raw[i]) catch break;
    }
    // Intentional borrow: static owns the backing storage for the Model lifetime.
    if (i < raw.len) out.appendSlice(static, "\n… (truncated)") catch return out.items;
    return out.items;
}

const History = struct {
    alloc: Allocator,
    queries: List(Query),
    viewport: zz.Viewport,
    inner_size: u16 = 0,

    fn init(alloc: Allocator, width: u16, height: u16) History {
        var self: History = .{
            .alloc = alloc,
            .queries = .empty,
            .viewport = .init(alloc, width, height),
        };
        self.viewport.setStyle((zz.Style{}).fg(.gray(8)));
        return self;
    }

    fn deinit(self: *History) void {
        self.queries.deinit(self.alloc);
        self.viewport.deinit();
        self.* = undefined;
    }

    fn add(self: *History, q: Query, ctx: *zz.Context) void {
        const qheight = zz.measure.height(q.render(ctx.allocator) catch {
            self.queries.append(self.alloc, q) catch return;
            return;
        });
        self.queries.append(self.alloc, q) catch return;
        const inner = self.renderInner(ctx.allocator) catch return;
        const at_bottom = self.viewport.atBottom();
        self.viewport.setContent(inner) catch return;
        if (at_bottom) self.viewport.scrollDown(qheight);
        self.inner_size = @intCast(zz.measure.height(inner));
    }

    fn setSize(self: *History, width: u16, height: u16) void {
        self.viewport.setSize(width, height);
    }

    fn render(self: *const History, arena: Allocator) ![]const u8 {
        return self.viewport.view(arena);
    }

    fn renderInner(self: *const History, arena: Allocator) ![]const u8 {
        const queries = try arena.alloc([]const u8, self.queries.items.len);
        for (self.queries.items, 0..) |query, idx| {
            queries[idx] = try query.render(arena);
        }

        const items = try zz.joinVertical(arena, queries);
        return items;
    }
};

/// Context handed to the input's completion provider: the runtime whose
/// root namespace supplies the candidates, plus the model arena the
/// candidate list is allocated from (popup lifetimes; freed at deinit).
/// The struct's address is passed as the provider's opaque ctx, so the
/// Model must stay put (zigzag heap-allocates it).
const CompletionCtx = struct {
    rt: *skript.Runtime,
    alloc: std.mem.Allocator,
};

/// Completion candidates for the input popup: every binding in the root
/// namespace whose name starts with `prefix` (case-sensitive), sorted for
/// stable Tab order. Names are borrowed from the runtime's interned symbol
/// Language special forms that are NOT bound in root_ns (the reader/compiler
/// handles them) — complete them too. `else`/`and`/`or`/`not`/`nil`/`instance`/
/// `method` are prelude bindings and come from the namespace iteration.
const builtin_keywords = [_][]const u8{
    "begin", "case", "def", "defn", "fn", "if", "lambda", "let", "quote", "set!",
};

/// Provide completion candidates: the runtime's root-namespace symbols plus
/// the builtin special forms, prefix-filtered and sorted. Symbols live in the
/// store's symbol pool; only the candidate list is allocated, from the model
/// arena.
fn completionCandidates(ctx: *const anyopaque, prefix: []const u8) []const []const u8 {
    const cctx: *const CompletionCtx = @ptrCast(@alignCast(ctx));
    const rt = cctx.rt;
    const ns_ptr = rt.root_ns.obj.toRef().deref(skript.Namespace);
    const root_map: *skript.HashMapNamespace = @ptrCast(@alignCast(ns_ptr.data));
    var out: std.ArrayList([]const u8) = .empty;
    var it = root_map.bindings.iterator();
    while (it.next()) |kv| {
        const name: []const u8 = kv.key_ptr.*.*;
        if (std.mem.startsWith(u8, name, prefix)) {
            out.append(cctx.alloc, name) catch break;
        }
    }
    for (builtin_keywords) |kw| {
        if (std.mem.startsWith(u8, kw, prefix)) {
            out.append(cctx.alloc, kw) catch break;
        }
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    // Intentional borrow: cctx.alloc owns the candidate backing storage.
    return out.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const Model = struct {
    persistent_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    rt: *skript.Runtime,
    input: zz.components.CodeArea,
    history: History,
    split: zz.SplitPane,
    spinner: zz.Spinner,
    exit_message: ?[]const u8 = null,
    /// SAFETY: always assigned in Model.init before any render path runs.
    stdout_file_writer: std.Io.File.Writer,
    /// Input text the live styles apply to (persistent copy; re-parsing is
    /// skipped while the input still equals it).
    /// Height of the rendered input box (border included), tracked so the
    /// floating completion popup can anchor below the input text row.
    input_height: u16 = 0,
    input_hl_text: []const u8 = &.{},
    /// Tick counter for 1 Hz periodic work (spinner); the zz tick fires at
    /// 10 Hz.
    tick_count: u32 = 0,
    /// Persistent StyleRange slice pushed into the CodeArea via setStyles
    /// (the CodeArea borrows it, so it must outlive the frame arena).
    input_hl_styles: []const zz.components.CodeArea.StyleRange = &.{},
    /// Completion provider context for the input (runtime + model arena).
    completion_ctx: CompletionCtx,

    /// Messages: framework-required names for auto-dispatch by zigzag,
    /// plus internal domain messages for explicit sends.
    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        mouse: zz.MouseEvent,
        window_size: zz.msg.WindowSize,
        tick: zz.msg.Tick,
        /// Submit the current text input for evaluation (internal).
        evaluate,
        /// Exit the REPL (internal).
        quit,
    };

    pub fn init(self: *Model, ctx: *zz.Context) zz.Cmd(Msg) {
        self.* = .{
            .persistent_allocator = ctx.persistent_allocator,
            .arena = .init(ctx.persistent_allocator),
            .input = .init(ctx.persistent_allocator),
            .history = .init(ctx.persistent_allocator, 0, 0),
            .split = sp: {
                var sp = zz.SplitPane.init(.horizontal);
                sp.setRatio(0.7);
                sp.min_size = 1;
                break :sp sp;
            },
            .spinner = blk: {
                var s = zz.Spinner.init();
                s.setStyle((zz.Style{}).fg(.cyan));
                break :blk s;
            },
            .rt = skript.Runtime.init(ctx.persistent_allocator, ctx.io) catch |e| {
                self.exit_message =
                    std.fmt.allocPrint(
                        ctx.persistent_allocator,
                        "Error: {any}",
                        .{e},
                    ) catch "Error: <unformattable>";
                return .quit;
            },
            .stdout_file_writer = std.Io.File.stdout().writer(ctx.io, &.{}),
            // SAFETY: assigned immediately below before input can invoke the provider.
            .completion_ctx = undefined,
        };
        self.rt.stdout = &self.stdout_file_writer.interface;
        self.input.placeholder = "Your code here...";
        // Completion candidates come from the runtime's root namespace;
        // the candidate list lives in the model arena (see
        // completionCandidates). The provider's ctx points at
        // self.completion_ctx, which the arena allocator keeps valid for
        // the Model's lifetime.
        self.completion_ctx = .{ .rt = self.rt, .alloc = self.arena.allocator() };
        self.input.completion_provider = .{
            .ctx = @ptrCast(&self.completion_ctx),
            .candidates = completionCandidates,
        };
        self.resizeInputLayout(ctx);
        return .everyMs(100);
    }

    pub fn deinit(self: *Model) void {
        self.input.deinit();
        self.freeInputHighlight();
        self.rt.deinit();
        self.history.deinit();
        if (self.exit_message) |msg| {
            log.debug("{s}\n", .{msg});
            self.persistent_allocator.free(msg);
        }
        self.arena.deinit();
        self.* = undefined;
    }

    /// Translate a raw key event into an action: .none (already handled),
    /// .evaluate, .quit, or .pass_through (forward to input).
    const KeyAction = enum { none, evaluate, quit, pass_through };
    fn classifyKey(k: zz.KeyEvent) KeyAction {
        if (k.eql(.ctrl('c'))) return .quit;
        if (k.key == .escape) return .quit;
        if (k.eql(.{ .key = .enter, .modifiers = .{ .ctrl = true } })) return .evaluate;
        if (k.key == .enter and k.modifiers.any()) return .evaluate;
        return .pass_through;
    }

    /// zigzag's TextArea.handleKey has no arm for `.space`/`.tab`, so those
    /// key events are dropped. The kitty keyboard protocol (enabled by the
    /// REPL, so any kitty/wezterm/foot-style terminal) encodes the space bar
    /// as `.space` while legacy raw bytes arrive as `.char(' ')` — without
    /// this translation, spaces typed in kitty-protocol terminals vanish and
    /// "(def a 40)" submits as "(defa40)" (Unbound). Translate to char
    /// events before handing the key to the TextArea.
    fn translateTextKey(k: zz.KeyEvent) zz.KeyEvent {
        return switch (k.key) {
            .space => .{ .key = .{ .char = ' ' }, .modifiers = k.modifiers, .event_type = k.event_type },
            .tab => .{ .key = .{ .char = '\t' }, .modifiers = k.modifiers, .event_type = k.event_type },
            else => k,
        };
    }

    pub fn update(self: *Model, msg: Msg, ctx: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            // Internal domain messages
            .evaluate => return self.doEvaluate(ctx),
            .quit => return .quit,

            // Framework-dispatched messages
            .key => |k| switch (classifyKey(k)) {
                .evaluate => return self.doEvaluate(ctx),
                .quit => if (k.key == .escape and self.input.completionActive()) {
                    // Escape cancels the completion popup before it can
                    // quit the REPL; the CodeArea hides it and nothing
                    // else happens.
                    ctx.render_requested = true;
                    self.input.handleKey(translateTextKey(k));
                } else {
                    return .quit;
                },
                .pass_through => {
                    ctx.render_requested = true;
                    const was_completing = self.input.completionActive();
                    self.input.handleKey(translateTextKey(k));
                    // The completion popup grows/shrinks the input box;
                    // resize the history viewport so the stack keeps
                    // fitting the pane.
                    if (was_completing != self.input.completionActive()) self.resizeInputLayout(ctx);
                },
                .none => {},
            },
            .mouse => |m| switch (m.button) {
                .wheel_up => {
                    ctx.render_requested = true;
                    self.history.viewport.scrollUp(2);
                },
                .wheel_down => {
                    ctx.render_requested = true;
                    self.history.viewport.scrollDown(2);
                },
                else => {},
            },
            .window_size => |ws| {
                _ = ws;
                ctx.render_requested = true;
                self.resizeInputLayout(ctx);
            },
            .tick => |t| {
                // Advance the spinner at 1 Hz (the only periodic content);
                // everything else renders on the event that changed it.
                self.tick_count +%= 1;
                if (self.tick_count % 10 == 0) {
                    _ = self.spinner.update(t.timestamp);
                    ctx.render_requested = true;
                }
                const hl_before = self.input_hl_text.len;
                self.refreshInputHighlight(ctx.allocator);
                // The tree-sitter styles arrive up to ~100ms after the text
                // (tick-driven); request a render only when they changed.
                if (self.input_hl_text.len != hl_before) ctx.render_requested = true;
            },
        }
        return .none;
    }

    /// Handle an evaluate request: read input, evaluate, add to history.
    fn doEvaluate(self: *Model, ctx: *zz.Context) zz.Cmd(Msg) {
        ctx.render_requested = true;
        const txt = self.input.getValue(ctx.allocator) catch {
            return .none;
        };
        self.input.setValue("") catch |err| log.warn("setValue: {}", .{err});
        // Recompute viewport height after clearing input (height may change)
        self.resizeInputLayout(ctx);

        self.history.add(.submit(self.arena.allocator(), ctx.allocator, txt, self.rt), ctx);
        return .none;
    }

    /// Re-parse the input through the tree-sitter engine on change and push
    /// the styles into the CodeArea. Plain (empty styles) when highlighting
    /// is disabled or the engine is unavailable. Runs on the tick timer
    /// (10 Hz), so a parse happens at most ~100ms after the last edit and
    /// only when the text actually changed. Allocates from the persistent
    /// allocator so the borrowed styles outlive the per-frame arena.
    fn refreshInputHighlight(self: *Model, arena: Allocator) void {
        const txt = self.input.getValue(arena) catch return;
        if (hl_engine == null or !repl_use_highlight) {
            if (self.input_hl_text.len > 0 or self.input_hl_styles.len > 0) {
                self.freeInputHighlight();
                self.input.setStyles(&.{});
            }
            return;
        }
        // Skip re-parsing while the input is unchanged since the last parse.
        if (std.mem.eql(u8, txt, self.input_hl_text)) return;
        self.freeInputHighlight();
        self.input_hl_text = self.persistent_allocator.dupe(u8, txt) catch return;
        if (hl_engine) |*eng| {
            const ranges = eng.ranges(self.persistent_allocator, txt) catch return;
            defer self.persistent_allocator.free(ranges);
            if (ranges.len == 0) {
                self.input.setStyles(&.{});
                return;
            }
            const styles = self.persistent_allocator.alloc(
                zz.components.CodeArea.StyleRange,
                ranges.len,
            ) catch return;
            for (ranges, 0..) |r, i| {
                styles[i] = .{ .start = r.start, .end = r.end, .style = captureStyle(r.capture) };
            }
            self.input_hl_styles = styles;
            self.input.setStyles(styles);
        }
    }

    /// Release the persistent memory behind the input highlight state.
    fn freeInputHighlight(self: *Model) void {
        self.persistent_allocator.free(self.input_hl_text);
        self.persistent_allocator.free(self.input_hl_styles);
        self.input_hl_text = &.{};
        self.input_hl_styles = &.{};
    }

    /// Size the input to the left pane and the history viewport to the
    /// remaining height. The input box grows when the completion popup is
    /// visible, so this re-measures the rendered input each time (same
    /// measurement init does). Cheap enough for key-triggered calls; the
    /// frame arena frees the rendered strings.
    fn resizeInputLayout(self: *Model, ctx: *zz.Context) void {
        var split = self.split;
        split.setSize(ctx.width, ctx.height);
        const sd = split.dims();
        self.input.setSize(sd.a_width -| 2, self.input.height);
        const box = (zz.Style{}).borderAll(.rounded);
        const input_view = self.input.view(ctx.allocator) catch "";
        const rendered_input = box.render(ctx.allocator, input_view) catch "";
        const input_h: u16 = @intCast(zz.measure.height(rendered_input));
        self.input_height = input_h;
        self.history.viewport.setSize(sd.a_width, ctx.height -| input_h);
    }

    /// Render the text input with a border. Only called from view().
    pub fn renderInput(self: *const Model, ctx: *const zz.Context) []const u8 {
        const box = (zz.Style{}).borderAll(.rounded);
        const input = box.render(ctx.allocator, self.input.view(ctx.allocator) catch "error") catch "error";
        return input;
    }

    pub fn view(self: *const Model, ctx: *const zz.Context) []const u8 {
        const input = self.renderInput(ctx);
        const hist = self.history.render(ctx.allocator) catch "error";
        const left_body = zz.joinVertical(ctx.allocator, &.{ hist, input }) catch "error: joinVertical";

        // Compute split widths
        var split = self.split;
        split.setSize(ctx.width, ctx.height);
        const sd = split.dims();

        // Runtime info panel, centered in the right column
        const spinner_text = self.spinner.viewWithTitle(ctx.allocator, "Runtime active") catch "...";
        const stats = storeStats(self.rt.store);
        const fmt_used = formatBytes(ctx.allocator, @intCast(stats.heap_used)) catch "?B";
        const stats_text = std.fmt.allocPrint(
            ctx.allocator,
            "folios: {d}\nallocs: {d}\nmem: {s}\nsyms: {d}",
            .{ stats.folio_count, stats.live_objects, fmt_used, stats.symbol_count },
        ) catch "";
        defer ctx.allocator.free(stats_text);
        // Live process table (the fibers panel): one boxed row per
        // registered process. The outer pane's padded content width is
        // b_width - 6 (1 border + 2 padding each side); the panel box adds
        // 4 to its inner width, so the rows are truncated to b_width - 10
        // for an exact fit.
        const fibers = fibersPanel(ctx.allocator, self.rt, sd.b_width -| 10) catch "fibers: <OoM>";
        const right_content = std.fmt.allocPrint(
            ctx.allocator,
            "\n{s}\n\n{s}\n\n{s}\n",
            .{ spinner_text, stats_text, fibers },
        ) catch "";
        defer ctx.allocator.free(right_content);
        var right_style: zz.Style = .{};
        right_style = right_style.borderAll(.rounded);
        right_style = right_style.borderForeground(.gray(8));
        right_style = right_style.paddingLeft(2).paddingRight(2);
        const raw_right = right_style.render(ctx.allocator, right_content) catch "error";
        const right_pane = zz.place.placeHorizontal(ctx.allocator, sd.b_width, .center, raw_right) catch "error";

        // Build frame manually: left | divider | right, line by line
        var left_lines = std.mem.splitScalar(u8, left_body, '\n');
        var right_lines = std.mem.splitScalar(u8, right_pane, '\n');
        var result: std.ArrayList(u8) = .empty;

        var div_style: zz.Style = .{};
        div_style = div_style.fg(.gray(6));

        var row: usize = 0;
        while (row < ctx.height) : (row += 1) {
            if (row > 0) result.append(ctx.allocator, '\n') catch continue;

            // Left content (truncated + padded to a_width)
            if (left_lines.next()) |line| {
                const clipped = truncLine(ctx.allocator, line, sd.a_width) catch line;
                _ = result.appendSlice(ctx.allocator, clipped) catch continue;
                const lw = zz.measure.width(clipped);
                for (0..sd.a_width -| lw) |_| result.append(ctx.allocator, ' ') catch continue;
            } else {
                for (0..sd.a_width) |_| result.append(ctx.allocator, ' ') catch continue;
            }

            // Divider
            const ch = div_style.render(ctx.allocator, "│") catch "│";
            _ = result.appendSlice(ctx.allocator, ch) catch continue;

            // Right content (truncated + padded to b_width)
            if (right_lines.next()) |line| {
                const clipped = truncLine(ctx.allocator, line, sd.b_width) catch line;
                _ = result.appendSlice(ctx.allocator, clipped) catch continue;
                const rw = zz.measure.width(clipped);
                for (0..sd.b_width -| rw) |_| result.append(ctx.allocator, ' ') catch continue;
            } else {
                for (0..sd.b_width) |_| result.append(ctx.allocator, ' ') catch continue;
            }
        }

        // toOwnedSlice transfers the exact-size backing buffer; the caller
        // (zigzag render loop) consumes it within this frame and the frame
        // arena frees it on the next reset. Returning .items directly would
        // leak capacity tracking for the full allocation.
        const base = result.toOwnedSlice(ctx.allocator) catch return &.{};

        // The completion popup FLOATS over the frame (zigzag cell-based
        // compositing, zz.overlayAt) anchored below the input text row at
        // the cursor column — it is not part of the CodeArea view, so the
        // layout does not grow when it appears.
        if (self.input.completionActive()) {
            if (self.input.completionPopup(ctx.allocator) catch null) |popup| {
                const anchor = self.input.completionAnchor();
                const popup_h = zz.measure.height(popup);
                const input_top = ctx.height -| self.input_height;
                const px = 1 + anchor.col; // box border + cursor column
                var py = input_top + 2 + anchor.row; // below the cursor row
                if (py + popup_h > ctx.height) py = ctx.height -| popup_h;
                return zz.overlayAt(
                    ctx.allocator,
                    base,
                    ctx.width,
                    ctx.height,
                    popup,
                    px,
                    py,
                ) catch base;
            }
        }
        return base;
    }
};

/// Scan the Store's object table and report allocation statistics.
pub fn storeStats(store: *skript.Store) skript.Store.Stats {
    return store.stats();
}

/// True for ASCII letters (used to find the end of an ANSI escape sequence).
fn isAsciiAlpha(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

/// Truncate `line` to at most `max_width` display columns, preserving ANSI codes.
fn truncLine(allocator: std.mem.Allocator, line: []const u8, max_width: usize) ![]const u8 {
    if (zz.measure.width(line) <= max_width)
        return allocator.dupe(u8, line);
    var result: std.ArrayList(u8) = .empty;
    var byte_pos: usize = 0;
    var col: usize = 0;
    while (byte_pos < line.len and col < max_width) {
        const c = line[byte_pos];
        if (c == 0x1b) {
            const esc_start = byte_pos;
            byte_pos += 1;
            while (byte_pos < line.len) {
                if (line[byte_pos] == '[') {
                    byte_pos += 1;
                    while (byte_pos < line.len and !isAsciiAlpha(line[byte_pos])) byte_pos += 1;
                    if (byte_pos < line.len) byte_pos += 1;
                    break;
                } else {
                    byte_pos += 1;
                    break;
                }
            }
            try result.appendSlice(allocator, line[esc_start..byte_pos]);
            continue;
        }
        const byte_len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        if (byte_pos + byte_len <= line.len) {
            const slice = line[byte_pos..][0..byte_len];
            const cp = switch (byte_len) {
                2 => std.unicode.utf8Decode2(slice[0..2].*) catch {
                    try result.append(allocator, c);
                    col += 1;
                    byte_pos += 1;
                    continue;
                },
                3 => std.unicode.utf8Decode3(slice[0..3].*) catch {
                    try result.append(allocator, c);
                    col += 1;
                    byte_pos += 1;
                    continue;
                },
                4 => std.unicode.utf8Decode4(slice[0..4].*) catch {
                    try result.append(allocator, c);
                    col += 1;
                    byte_pos += 1;
                    continue;
                },
                else => @as(u21, c),
            };
            const cw = zz.unicode.charWidth(cp);
            if (col + cw > max_width) break;
            try result.appendSlice(allocator, line[byte_pos..][0..byte_len]);
            col += cw;
            byte_pos += byte_len;
        } else {
            byte_pos += 1;
        }
    }
    try result.appendSlice(allocator, "\x1b[0m");
    return result.toOwnedSlice(allocator);
}

/// Format a byte count in human-readable form (B, KiB, MiB, GiB).
pub fn formatBytes(allocator: std.mem.Allocator, bytes: usize) ![]const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB" };
    var remaining: f64 = @floatFromInt(bytes);
    var unit_idx: usize = 0;
    while (remaining >= 1024.0 and unit_idx < units.len - 1) {
        remaining /= 1024.0;
        unit_idx += 1;
    }
    if (unit_idx == 0) {
        return std.fmt.allocPrint(allocator, "{d:.0} {s}", .{ bytes, units[unit_idx] });
    }
    return std.fmt.allocPrint(allocator, "{d:.1} {s}", .{ remaining, units[unit_idx] });
}

/// Foreground color for a process status in the fibers panel: running =
/// green, crashed = red, done = gray; queued/suspended keep the default.
fn statusColor(status: skript.scheduler.ProcessInfo.Status) zz.Color {
    return switch (status) {
        .running => zz.Color.green,
        .crashed => zz.Color.red,
        .done => zz.Color.gray(8),
        .queued, .suspended => .none,
    };
}

/// One fibers-panel row for a process: `pid {d}  {status} {mailbox:>2}
/// msgs  [{sleep Nms ]{module_path|repl/anon}`. The status is colored and
/// padded to 9 visible columns; the deadline (absolute `.awake`
/// nanoseconds) is rendered as relative ms, clamped at 0. Allocates from
/// `allocator` (the frame arena).
fn fiberLine(
    allocator: std.mem.Allocator,
    info: skript.scheduler.ProcessInfo,
    now_ns: i128,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const prefix = try std.fmt.allocPrint(allocator, "pid {d}  ", .{info.pid});
    defer allocator.free(prefix);
    try buf.appendSlice(allocator, prefix);
    const status = @tagName(info.status);
    const colored = try (zz.Style{}).fg(statusColor(info.status)).render(allocator, status);
    defer allocator.free(colored);
    try buf.appendSlice(allocator, colored);
    // Pad to 9 visible columns (the ANSI codes make byte-length padding
    // useless — the format's `:<9` counts bytes, not display columns).
    for (0..9 -| zz.measure.width(colored)) |_| try buf.append(allocator, ' ');
    const mailbox = try std.fmt.allocPrint(allocator, "{d:>2} msgs", .{info.mailbox});
    defer allocator.free(mailbox);
    try buf.appendSlice(allocator, mailbox);
    if (info.deadline) |d| {
        const rel_ms: i128 = @max(@as(i128, 0), @divTrunc(d - now_ns, std.time.ns_per_ms));
        const sleep = try std.fmt.allocPrint(allocator, "  sleep {d}ms", .{rel_ms});
        defer allocator.free(sleep);
        try buf.appendSlice(allocator, sleep);
    }
    const path = info.module_path orelse "repl/anon";
    try buf.appendSlice(allocator, "  ");
    try buf.appendSlice(allocator, path);
    return buf.toOwnedSlice(allocator);
}

/// Live process table for the right pane: a titled box (`╭─ fibers ─╮`)
/// with one row per registered process, capped at 12 with a trailing
/// '... N more' row. Defensive: an empty registry renders an empty box, a
/// null module_path renders 'repl/anon', every row is truncated to
/// `max_line_width`, and a snapshot failure renders a one-line note. The
/// snapshot and all rows allocate from `allocator` (the frame arena); only
/// the snapshot array itself is freed (its API contract).
fn fibersPanel(
    allocator: std.mem.Allocator,
    rt: *skript.Runtime,
    max_line_width: usize,
) ![]const u8 {
    const snaps = try rt.scheduler.snapshotProcesses(allocator, rt.io, null);
    defer allocator.free(snaps);

    const max_rows: usize = 12;
    const shown = @min(snaps.len, max_rows);
    const now_ns: i128 = @intCast(std.Io.Clock.awake.now(rt.io).nanoseconds);

    // Rows: one per process (capped), then a '... N more' row.
    var rows: std.ArrayList([]const u8) = .empty;
    var inner: usize = " fibers ".len;
    for (snaps[0..shown]) |info| {
        const raw = try fiberLine(allocator, info, now_ns);
        const line = try truncLine(allocator, raw, max_line_width);
        try rows.append(allocator, line);
        inner = @max(inner, zz.measure.width(line));
    }
    if (snaps.len > shown) {
        const more = try std.fmt.allocPrint(allocator, "... {d} more", .{snaps.len - shown});
        const more_trunc = try truncLine(allocator, more, max_line_width);
        try rows.append(allocator, more_trunc);
        inner = @max(inner, zz.measure.width(more_trunc));
    }
    inner = @min(inner, max_line_width);

    // Assemble the titled box. Each row is `│ ` + inner columns + ` │`
    // (inner + 4 wide); the top border fills the same width after the
    // `╭─ fibers ` title (10 chars: "╭", "─", " fibers "), so it needs
    // inner - 7 dashes; the bottom border mirrors the row width.
    var box: std.ArrayList(u8) = .empty;
    try box.appendSlice(allocator, "╭─ fibers ");
    for (0..inner -| (" fibers ".len - 1)) |_| try box.appendSlice(allocator, "─");
    try box.appendSlice(allocator, "╮");
    for (rows.items) |line| {
        try box.append(allocator, '\n');
        try box.appendSlice(allocator, "│ ");
        try box.appendSlice(allocator, line);
        for (0..inner -| zz.measure.width(line)) |_| try box.append(allocator, ' ');
        try box.appendSlice(allocator, " │");
    }
    try box.appendSlice(allocator, "\n╰");
    for (0..inner + 2) |_| try box.appendSlice(allocator, "─");
    try box.appendSlice(allocator, "╯");
    return box.toOwnedSlice(allocator);
}

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
        std.testing.refAllDecls(History);
        std.testing.refAllDecls(Model);
    }
}
